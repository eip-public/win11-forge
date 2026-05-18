"""
kd_wrapper.py - Production-grade supervisor for kd.exe + WinDbg MCP HTTP server.

Designed for automated CVE pipelines where the target kernel crashes repeatedly.

Responsibilities:
  1. Start kd.exe with KDNET transport, hold stdin open (prevents EOF exit)
  2. Monitor kd.out.log for any break prompt (kd>)
  3. On first break: inject .load + mcpstart + g via stdin
  4. Start HTTP MCP server once the named pipe appears
  5. On kd.exe crash or disconnect: kill HTTP server, restart both automatically
  6. On HTTP server crash: restart it without touching kd.exe
  7. Log everything to C:\\winforge\\logs\\kd_wrapper.log

Break sources handled automatically:
  - BugCheck (kernel crash from PoC)
  - NtSystemDebugControl(SysDbgBreakPoint=6) called from target as SYSTEM
    (used by 'setup.sh lab load-mcp' for pre-crash MCP loading)
  - Any other kernel exception

NOTE: Do NOT use virsh inject-nmi. That sends a hardware NMI which Windows
treats as NMI_HARDWARE_FAILURE and BSODs the target. Use NtSystemDebugControl
from the target side instead — it fires a kernel int 3 caught by kd over KDNET.

Runs as SYSTEM via the DebuggerBoot scheduled task registered by
role-bootstrap-debugger.sh.
"""

import logging
import os
import pathlib
import signal
import subprocess
import sys
import threading
import time
import types
from collections.abc import Callable
from typing import IO

# config

KD = r"C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\kd.exe"
PY = r"C:\Python314\python.exe"
DLL = r"C:\winforge\windbg-ext-mcp\extension\build\x64\Release\windbgmcpExt.dll"
HTTP_SCRIPT = r"C:\winforge\windbg-ext-mcp\run_http.py"
LOG_DIR = pathlib.Path(r"C:\winforge\logs")
# Sentinel: while this file exists, the prompt monitor does NOT auto-inject
# `g` on kd> prompts. Use to hold breaks for synchronous user-mode debugging
# via MCP (set bp, trigger, inspect stack, step, etc). Created/removed by the
# agent as needed; absence = default auto-resume behavior.
HOLD_FLAG = pathlib.Path(r"C:\winforge\logs\debug-hold.flag")

TRANSPORT = "net:port=50000,key=1.2.3.4"
HTTP_PORT = 8100
PIPE_PATH = r"\\.\pipe\windbgmcp"
CONNECT_TIMEOUT_S = 120  # wait up to 2 min per cycle; supervisor retries automatically
PIPE_TIMEOUT_S = 120  # wait up to 2 min for pipe after extension injection
HTTP_RESTART_DELAY = 5
KD_RESTART_DELAY = 3

# logging

LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [wrapper] %(levelname)s %(message)s",
    handlers=[
        logging.FileHandler(str(LOG_DIR / "kd_wrapper.log"), encoding="utf-8"),
        # Stderr (not stdout): MCP-adjacent processes use stdout for protocol data;
        # logs go to stderr so they don't corrupt any stdio channel.
        logging.StreamHandler(sys.stderr),
    ],
)
log = logging.getLogger("kd_wrapper")

# state

_kd_proc: subprocess.Popen | None = None
_http_proc: subprocess.Popen | None = None
_kd_log_fh: IO[str] | None = None
_shutdown = threading.Event()


def _handle_signal(sig: int, _: types.FrameType | None) -> None:
    log.info(f"Signal {sig} received - shutting down")
    _shutdown.set()


signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)

# helpers


def _stop(proc: subprocess.Popen | None, name: str) -> None:
    if proc is None or proc.poll() is not None:
        return
    log.info(f"Stopping {name} (pid={proc.pid})")
    try:
        proc.terminate()
        proc.wait(timeout=10)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def _pipe_exists() -> bool:
    return os.path.exists(PIPE_PATH)


def _kd_log_path() -> str:
    return str(LOG_DIR / "kd.out.log")


def _start_kd(cycle: int) -> subprocess.Popen:
    global _kd_log_fh
    if _kd_log_fh:
        try:
            _kd_log_fh.close()
        except Exception:
            pass
    _kd_log_fh = open(_kd_log_path(), "a", encoding="utf-8", errors="replace")
    log.info(f"[cycle {cycle}] Starting kd.exe: kd -k {TRANSPORT}")
    # No -b (avoids early-boot KDNET timing freeze) and no -c (fires once only).
    # Commands are injected via stdin by the prompt monitor thread, which fires
    # on EVERY break: BugCheck, NMI, or any other kernel exception.
    return subprocess.Popen(
        [KD, "-k", TRANSPORT],
        stdin=subprocess.PIPE,
        stdout=_kd_log_fh.fileno(),
        stderr=_kd_log_fh.fileno(),
        text=False,
    )


def _start_http() -> subprocess.Popen | None:
    log.info(f"Starting HTTP MCP server on port {HTTP_PORT}")
    out = err = None
    try:
        out = open(str(LOG_DIR / "mcp-http.out.log"), "a")
        err = open(str(LOG_DIR / "mcp-http.err.log"), "a")
        return subprocess.Popen(
            [PY, HTTP_SCRIPT, "--port", str(HTTP_PORT), "--host", "0.0.0.0"],
            cwd=str(pathlib.Path(HTTP_SCRIPT).parent),
            stdout=out,
            stderr=err,
        )
    except Exception as e:
        log.warning(f"_start_http failed: {e}; will retry next iteration")
        return None
    finally:
        # subprocess.Popen dup's stdout/stderr into the child; the parent's
        # file objects are no longer needed and would otherwise leak until
        # GC — same Windows GC-determinism issue documented for the prompt
        # monitor at line 184. Close on both success and failure paths.
        for fh in (out, err):
            if fh is not None:
                try:
                    fh.close()
                except Exception:
                    pass


def _wait_for_kd_connect(proc: subprocess.Popen, cycle: int) -> bool:
    deadline = time.monotonic() + CONNECT_TIMEOUT_S
    last_size = 0
    log.info(f"[cycle {cycle}] Waiting for KDNET connection (up to {CONNECT_TIMEOUT_S}s)...")
    while time.monotonic() < deadline and not _shutdown.is_set():
        if proc.poll() is not None:
            log.warning(f"[cycle {cycle}] kd.exe exited before connecting")
            return False
        try:
            sz = os.path.getsize(_kd_log_path())
            if sz > last_size:
                with open(_kd_log_path(), encoding="utf-8", errors="replace") as f:
                    content = f.read()
                # kd outputs different strings depending on whether this is a fresh
                # connection or a reconnect after target reboot:
                #   Fresh:     "Connected to target..."
                #   Reconnect: "KDTARGET: Refreshing KD connection"
                #   Both:      "Kernel base = " appears after the kernel version line
                connected = (
                    "Connected to target" in content
                    or "Kernel Debugger connection established" in content
                    or "KDTARGET: Refreshing KD connection" in content
                    or "Kernel base = " in content
                )
                if connected:
                    log.info(f"[cycle {cycle}] KDNET connected to target")
                    return True
                last_size = sz
        except OSError:
            pass
        time.sleep(1)
    log.warning(f"[cycle {cycle}] Timed out waiting for KDNET connection")
    return False


def _try_open(path: str) -> IO[str] | None:
    """Best-effort open of kd's log file. Returns None on OSError so the
    caller can sleep+retry rather than dying on a transient race with kd's
    writer."""
    try:
        return open(path, encoding="utf-8", errors="replace")
    except OSError:
        return None


def _read_new_chunk(log_fh: IO[str], log_path: str, last_size: int) -> tuple[str, int] | None:
    """Read any bytes appended since `last_size`. Returns
    `(chunk, new_size)` on success (chunk may be empty if nothing grew) or
    None if the file became unreadable so the caller can sleep+retry.
    """
    try:
        current_size = os.path.getsize(log_path)
    except OSError:
        return None
    if current_size <= last_size:
        return "", current_size
    try:
        log_fh.seek(last_size)
        chunk = log_fh.read()
    except OSError:
        return None
    return chunk, current_size


def _make_send(proc: subprocess.Popen, cycle: int) -> Callable[..., None]:
    """Build the kd-stdin write helper used by the prompt monitor.

    Kept as a closure so the prompt monitor and its prompt-handler helper
    can share one logging + error-handling path without threading proc/cycle
    through every call site.
    """

    def send(cmd: str, delay: float = 1.5) -> None:
        if proc.stdin is None:
            log.warning(f"[cycle {cycle}] proc.stdin is None; skipping '{cmd}'")
            return
        try:
            proc.stdin.write((cmd + "\n").encode())
            proc.stdin.flush()
            time.sleep(delay)
        except Exception as e:
            log.warning(f"[cycle {cycle}] stdin write failed: {e}")

    return send


def _handle_kd_prompt(
    *,
    cycle: int,
    has_mcp: bool,
    injected: bool,
    send: Callable[..., None],
) -> bool:
    """Handle one kd> prompt detection. Returns the new `injected` state.

    Decision tree:
      1. pipe already exists       -> extension is loaded; just resume
                                      (or hold the break if HOLD_FLAG set).
      2. has_mcp and not injected  -> first break with extension not loaded;
                                      inject `.load` + `mcpstart`, then
                                      resume unless held.
      3. otherwise                 -> no extension available or already
                                      tried; just resume (unless held).
    """
    hold = HOLD_FLAG.exists()
    if _pipe_exists():
        if hold:
            # Agent is doing interactive debug work — do NOT resume.
            # The agent will clear the flag + issue `g` via MCP when done.
            log.info(f"[cycle {cycle}] Hold flag present — leaving target at break (pipe)")
        else:
            log.info(f"[cycle {cycle}] Extension already loaded (pipe exists) - sending g")
            send("g")
        return injected

    if has_mcp and not injected:
        log.info(f"[cycle {cycle}] Injecting: .load -> mcpstart{'' if hold else ' -> g'}")
        send(f".load {DLL}", delay=2)
        send("mcpstart", delay=2)
        if hold:
            log.info(f"[cycle {cycle}] Hold flag present — extension loaded, leaving target at break")
        else:
            send("g", delay=1)
        log.info(f"[cycle {cycle}] Commands injected - waiting for pipe")
        return True

    if hold:
        log.info(f"[cycle {cycle}] Hold flag present — leaving target at break (fallback)")
    else:
        send("g")
    return injected


def _prompt_monitor(proc: subprocess.Popen, cycle: int, pipe_ready_event: threading.Event) -> None:
    """Background thread: watches kd.out.log for 'kd>' and injects extension commands.

    Fires on EVERY break (BugCheck, NMI, etc.) until the pipe is created.
    After the pipe appears, stops injecting (extension already loaded).
    """
    has_mcp = os.path.isfile(DLL)
    if not has_mcp:
        log.warning(f"[cycle {cycle}] MCP extension DLL not found - sending g on every break")

    # Incremental log reader: open once, seek to last-read offset, only process
    # new bytes. The previous version open()ed and .read() the whole log file
    # on every iteration (twice per second); over a long debug session the log
    # grows to many MB and that becomes a lot of wasted I/O. The anonymous
    # open() also leaked a file handle until GC, which on Windows occasionally
    # collided with kd's writer.
    last_log_size = 0
    carryover = ""  # 2-char tail bridges a "kd>" split across read boundaries
    injected = False

    send = _make_send(proc, cycle)

    log.info(f"[cycle {cycle}] Prompt monitor started - watching for kd breaks")

    log_path = _kd_log_path()
    log_fh = _try_open(log_path)

    # try/finally wrap so log_fh is closed even if an unhandled exception
    # escapes the loop. The body intentionally catches all in-loop failure
    # modes already; this is belt-and-braces for surprises (audit §2).
    try:
        while not _shutdown.is_set() and proc.poll() is None:
            if log_fh is None:
                log_fh = _try_open(log_path)
                if log_fh is None:
                    time.sleep(1)
                    continue

            chunk_read = _read_new_chunk(log_fh, log_path, last_log_size)
            if chunk_read is None:
                time.sleep(1)
                continue
            chunk, last_log_size = chunk_read

            if chunk:
                window = carryover + chunk
                carryover = window[-2:]
                if "kd>" in window:
                    log.info(f"[cycle {cycle}] kd prompt detected")
                    injected = _handle_kd_prompt(cycle=cycle, has_mcp=has_mcp, injected=injected, send=send)

            # Check if pipe appeared after injection
            if injected and _pipe_exists():
                log.info(f"[cycle {cycle}] Pipe appeared after injection!")
                pipe_ready_event.set()
                # Keep monitoring for subsequent breaks (re-inject if pipe disappears)
                injected = False  # allow re-injection if extension unloads

            time.sleep(0.5)
    finally:
        if log_fh is not None:
            try:
                log_fh.close()
            except Exception:
                pass

    log.info(f"[cycle {cycle}] Prompt monitor stopped")


# supervisor loop


def _start_http_if_pipe(cycle: int, label: str) -> None:
    """Start the HTTP MCP server if the pipe is up and we don't already
    have a running shim. `label` is logged so the supervisor can distinguish
    initial vs late-arrival starts.
    """
    global _http_proc
    if _http_proc is not None or not _pipe_exists():
        return
    log.info(f"[cycle {cycle}] {label} - starting HTTP MCP server")
    _http_proc = _start_http()
    if _http_proc is not None:
        log.info(f"[cycle {cycle}] HTTP server pid: {_http_proc.pid}")
        log.info(f"[cycle {cycle}] MCP endpoint: http://0.0.0.0:{HTTP_PORT}/mcp")


def _restart_http_if_crashed(cycle: int) -> None:
    """Restart the HTTP shim if it died while kd is still alive.

    If the pipe disappeared too (extension unloaded), null _http_proc so the
    next iteration's late-arrival check can pick it up cleanly.
    """
    global _http_proc
    if _http_proc is None or _http_proc.poll() is None:
        return
    log.warning(f"[cycle {cycle}] HTTP crashed (code={_http_proc.returncode}) - restarting")
    time.sleep(HTTP_RESTART_DELAY)
    if _pipe_exists():
        _http_proc = _start_http()
        if _http_proc is not None:
            log.info(f"[cycle {cycle}] HTTP restarted, pid: {_http_proc.pid}")
    else:
        _http_proc = None


def _monitor_cycle(cycle: int) -> None:
    """Inner supervisor loop: watch kd until it exits or shutdown is requested.

    Three responsibilities, each delegated to a helper:
      1. Late pipe arrival — start HTTP if the extension loaded after the
         initial PIPE_TIMEOUT_S wait elapsed.
      2. HTTP crash recovery — restart the shim if it died while kd is alive.
      3. kd-exit detection — return so the outer loop rotates to a new cycle.
    """
    assert _kd_proc is not None
    log.info(f"[cycle {cycle}] Monitoring kd.exe (stdin held open)...")
    while not _shutdown.is_set():
        time.sleep(5)
        _start_http_if_pipe(cycle, "Pipe appeared late")
        _restart_http_if_crashed(cycle)

        if _kd_proc.poll() is not None:
            rc = _kd_proc.returncode
            log.warning(f"[cycle {cycle}] kd.exe exited (code={rc}/0x{rc & 0xFFFFFFFF:08X})")
            log.info(f"[cycle {cycle}] Target likely BSODed - restarting for next crash")
            return


def run() -> None:
    global _kd_proc, _http_proc
    cycle = 0

    if not os.path.isfile(KD):
        log.error(f"kd.exe not found: {KD}")
        sys.exit(1)

    log.info("Supervisor starting")
    log.info(f"  KDNET: {TRANSPORT}")
    log.info(f"  DLL:   {DLL}  (present={os.path.isfile(DLL)})")
    log.info(f"  HTTP:  {HTTP_SCRIPT}")
    log.info("MCP loads on first break: crash, NtSystemDebugControl(6), or any kernel exception")

    while not _shutdown.is_set():
        cycle += 1
        log.info(f"=== Cycle {cycle} starting ===")

        _stop(_http_proc, "HTTP server")
        _http_proc = None
        _stop(_kd_proc, "kd.exe")
        _kd_proc = None
        time.sleep(KD_RESTART_DELAY)

        _kd_proc = _start_kd(cycle)
        log.info(f"[cycle {cycle}] kd.exe pid: {_kd_proc.pid}")

        if not _wait_for_kd_connect(_kd_proc, cycle):
            log.warning(f"[cycle {cycle}] No KDNET connection - restarting after delay")
            time.sleep(10)
            continue

        # Start prompt monitor thread - handles all break sources
        pipe_ready = threading.Event()
        monitor = threading.Thread(
            target=_prompt_monitor,
            args=(_kd_proc, cycle, pipe_ready),
            daemon=True,
        )
        monitor.start()

        # Wait for pipe (set by monitor when extension loads on any break)
        pipe_appeared = pipe_ready.wait(timeout=PIPE_TIMEOUT_S)

        if pipe_appeared or _pipe_exists():
            # _http_proc was reset to None at the top of this cycle; the
            # supervisor restarts the HTTP server fresh on every kd cycle.
            _start_http_if_pipe(cycle, "Pipe ready")
        else:
            log.info(f"[cycle {cycle}] No pipe yet - waiting for first break to load extension")
            log.info(
                f"[cycle {cycle}] Trigger: run a PoC (crash) "
                "or './setup.sh lab load-mcp' (NtSystemDebugControl)"
            )

        _monitor_cycle(cycle)

        if _shutdown.is_set():
            break
        time.sleep(KD_RESTART_DELAY)

    log.info("Supervisor shutting down")
    _stop(_http_proc, "HTTP server")
    _stop(_kd_proc, "kd.exe")


if __name__ == "__main__":
    run()
