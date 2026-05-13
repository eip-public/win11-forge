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

import subprocess, os, sys, time, logging, pathlib, threading, signal

# config

KD          = r"C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\kd.exe"
PY          = r"C:\Python314\python.exe"
DLL         = r"C:\winforge\windbg-ext-mcp\extension\build\x64\Release\windbgmcpExt.dll"
HTTP_SCRIPT = r"C:\winforge\windbg-ext-mcp\run_http.py"
LOG_DIR     = pathlib.Path(r"C:\winforge\logs")
# Sentinel: while this file exists, the prompt monitor does NOT auto-inject
# `g` on kd> prompts. Use to hold breaks for synchronous user-mode debugging
# via MCP (set bp, trigger, inspect stack, step, etc). Created/removed by the
# agent as needed; absence = default auto-resume behavior.
HOLD_FLAG   = pathlib.Path(r"C:\winforge\logs\debug-hold.flag")

TRANSPORT         = "net:port=50000,key=1.2.3.4"
HTTP_PORT         = 8100
PIPE_PATH         = r"\\.\pipe\windbgmcp"
CONNECT_TIMEOUT_S = 120   # wait up to 2 min per cycle; supervisor retries automatically
PIPE_TIMEOUT_S    = 120   # wait up to 2 min for pipe after extension injection
HTTP_RESTART_DELAY = 5
KD_RESTART_DELAY  = 3

# logging

LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [wrapper] %(levelname)s %(message)s",
    handlers=[
        logging.FileHandler(str(LOG_DIR / "kd_wrapper.log"), encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("kd_wrapper")

# state

_kd_proc:   subprocess.Popen | None = None
_http_proc: subprocess.Popen | None = None
_kd_log_fh = None
_shutdown   = threading.Event()

def _handle_signal(sig, _):
    log.info(f"Signal {sig} received - shutting down")
    _shutdown.set()

signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT,  _handle_signal)

# helpers

def _stop(proc, name):
    if proc is None or proc.poll() is not None:
        return
    log.info(f"Stopping {name} (pid={proc.pid})")
    try:
        proc.terminate()
        proc.wait(timeout=10)
    except Exception:
        try: proc.kill()
        except Exception: pass


def _pipe_exists():
    return os.path.exists(PIPE_PATH)


def _kd_log_path():
    return str(LOG_DIR / "kd.out.log")


def _start_kd(cycle):
    global _kd_log_fh
    if _kd_log_fh:
        try: _kd_log_fh.close()
        except Exception: pass
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


def _start_http():
    log.info(f"Starting HTTP MCP server on port {HTTP_PORT}")
    try:
        out = open(str(LOG_DIR / "mcp-http.out.log"), "a")
        err = open(str(LOG_DIR / "mcp-http.err.log"), "a")
        return subprocess.Popen(
            [PY, HTTP_SCRIPT, "--port", str(HTTP_PORT), "--host", "0.0.0.0"],
            cwd=str(pathlib.Path(HTTP_SCRIPT).parent),
            stdout=out, stderr=err,
        )
    except Exception as e:
        log.warning(f"_start_http failed: {e}; will retry next iteration")
        return None


def _wait_for_kd_connect(proc, cycle):
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
                with open(_kd_log_path(), "r", encoding="utf-8", errors="replace") as f:
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


def _prompt_monitor(proc, cycle, pipe_ready_event):
    """Background thread: watches kd.out.log for 'kd>' and injects extension commands.

    Fires on EVERY break (BugCheck, NMI, etc.) until the pipe is created.
    After the pipe appears, stops injecting (extension already loaded).
    """
    has_mcp = os.path.isfile(DLL)
    if not has_mcp:
        log.warning(f"[cycle {cycle}] MCP extension DLL not found - sending g on every break")

    last_log_size = 0
    last_prompt_pos = -1
    injected = False

    def send(cmd, delay=1.5):
        try:
            proc.stdin.write((cmd + "\n").encode())
            proc.stdin.flush()
            time.sleep(delay)
        except Exception as e:
            log.warning(f"[cycle {cycle}] stdin write failed: {e}")

    log.info(f"[cycle {cycle}] Prompt monitor started - watching for kd breaks")

    while not _shutdown.is_set() and proc.poll() is None:
        try:
            content = open(_kd_log_path(), "r", encoding="utf-8", errors="replace").read()
        except OSError:
            time.sleep(1)
            continue

        # Find any new kd prompt that appeared since last check
        new_prompt_pos = content.rfind("kd>")
        if new_prompt_pos > last_prompt_pos and "kd>" in content:
            last_prompt_pos = new_prompt_pos
            log.info(f"[cycle {cycle}] kd prompt detected at position {new_prompt_pos}")

            hold = HOLD_FLAG.exists()
            if _pipe_exists():
                if hold:
                    # Agent is doing interactive debug work — do NOT resume.
                    # The agent will clear the flag + issue `g` via MCP when done.
                    log.info(f"[cycle {cycle}] Hold flag present — leaving target at break (pipe)")
                else:
                    # Extension already loaded from a prior break - just resume
                    log.info(f"[cycle {cycle}] Extension already loaded (pipe exists) - sending g")
                    send("g")
            elif has_mcp and not injected:
                # First break (or pipe gone) with extension not loaded - (re)inject now
                log.info(f"[cycle {cycle}] Injecting: .load -> mcpstart{'' if hold else ' -> g'}")
                send(f".load {DLL}", delay=2)
                send("mcpstart", delay=2)
                if hold:
                    log.info(f"[cycle {cycle}] Hold flag present — extension loaded, leaving target at break")
                else:
                    send("g", delay=1)
                injected = True
                log.info(f"[cycle {cycle}] Commands injected - waiting for pipe")
            else:
                # No MCP or already tried - just resume (unless held)
                if hold:
                    log.info(f"[cycle {cycle}] Hold flag present — leaving target at break (fallback)")
                else:
                    send("g")

        # Check if pipe appeared after injection
        if injected and _pipe_exists():
            log.info(f"[cycle {cycle}] Pipe appeared after injection!")
            pipe_ready_event.set()
            # Keep monitoring for subsequent breaks (re-inject if pipe disappears)
            injected = False   # allow re-injection if extension unloads

        time.sleep(0.5)

    log.info(f"[cycle {cycle}] Prompt monitor stopped")


# supervisor loop

def run():
    global _kd_proc, _http_proc
    cycle = 0

    if not os.path.isfile(KD):
        log.error(f"kd.exe not found: {KD}"); sys.exit(1)

    log.info("Supervisor starting")
    log.info(f"  KDNET: {TRANSPORT}")
    log.info(f"  DLL:   {DLL}  (present={os.path.isfile(DLL)})")
    log.info(f"  HTTP:  {HTTP_SCRIPT}")
    log.info("MCP loads on first break: crash, NtSystemDebugControl(6), or any kernel exception")

    while not _shutdown.is_set():
        cycle += 1
        log.info(f"=== Cycle {cycle} starting ===")

        _stop(_http_proc, "HTTP server"); _http_proc = None
        _stop(_kd_proc, "kd.exe");       _kd_proc = None
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
            log.info(f"[cycle {cycle}] Pipe ready - starting HTTP MCP server")
            if _http_proc is None or _http_proc.poll() is not None:
                _http_proc = _start_http()
                if _http_proc is not None:
                    log.info(f"[cycle {cycle}] HTTP server pid: {_http_proc.pid}")
                    log.info(f"[cycle {cycle}] MCP endpoint: http://0.0.0.0:{HTTP_PORT}/mcp")
        else:
            log.info(f"[cycle {cycle}] No pipe yet - waiting for first break to load extension")
            log.info(f"[cycle {cycle}] Trigger: run a PoC (crash) or './setup.sh lab load-mcp' (NtSystemDebugControl)")

        # Monitor until kd exits
        log.info(f"[cycle {cycle}] Monitoring kd.exe (stdin held open)...")
        while not _shutdown.is_set():
            time.sleep(5)

            # Late pipe arrival: if the extension loaded after our initial
            # PIPE_TIMEOUT_S wait (e.g. user triggered `lab load-mcp` several
            # minutes after spawn), start HTTP now. Without this check the
            # pipe_ready_event is set inside the prompt monitor thread but
            # the supervisor has already moved past pipe_ready.wait(), so
            # _start_http() would otherwise never be called.
            if _http_proc is None and _pipe_exists():
                log.info(f"[cycle {cycle}] Pipe appeared late - starting HTTP MCP server")
                _http_proc = _start_http()
                if _http_proc is not None:
                    log.info(f"[cycle {cycle}] HTTP server pid: {_http_proc.pid}")
                    log.info(f"[cycle {cycle}] MCP endpoint: http://0.0.0.0:{HTTP_PORT}/mcp")

            # Restart HTTP if it died but kd is still alive
            if _http_proc is not None and _http_proc.poll() is not None:
                log.warning(f"[cycle {cycle}] HTTP crashed (code={_http_proc.returncode}) - restarting")
                time.sleep(HTTP_RESTART_DELAY)
                if _pipe_exists():
                    _http_proc = _start_http()
                    if _http_proc is not None:
                        log.info(f"[cycle {cycle}] HTTP restarted, pid: {_http_proc.pid}")
                else:
                    _http_proc = None

            if _kd_proc.poll() is not None:
                log.warning(f"[cycle {cycle}] kd.exe exited (code={_kd_proc.returncode}/0x{_kd_proc.returncode & 0xFFFFFFFF:08X})")
                log.info(f"[cycle {cycle}] Target likely BSODed - restarting for next crash")
                break

        if _shutdown.is_set():
            break
        time.sleep(KD_RESTART_DELAY)

    log.info("Supervisor shutting down")
    _stop(_http_proc, "HTTP server")
    _stop(_kd_proc, "kd.exe")


if __name__ == "__main__":
    run()
