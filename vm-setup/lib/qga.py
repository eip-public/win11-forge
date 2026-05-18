"""Host-side wrapper around `virsh qemu-agent-command`.

Provides a small, predictable Python API for the win11-forge lab to drive
its KVM guests via QEMU's guest agent over virtio-serial — bypassing the
SSH stack entirely for short control-plane operations.

Why qga is the win11-forge primary control plane:
  - No network listener on the guest, no auth handshake, no firewall hole.
  - Survives an unhealthy guest network (the SSH-wedge class disappears).
  - Runs as LocalSystem inside the guest by default.

What qga is bad at (still use SSH/scp):
  - Bulk file transfer. `guest-file-{open,write,read,close}` is poll-based
    and base64-encoded — workable for KB-scale files, awful for the multi-MB
    artifacts the lab moves around (gold qcow2 derivatives, mcp-windbg
    tarball, etc.).
  - Anything where you'd want streaming stdout. qga buffers and you poll.

Typical use from bash::

    python3 -c "from vm_setup.lib.qga import QGA; \
        print(QGA('winforge-target').exec_wait(['hostname']).stdout)"

Or import directly from another Python script. The CLI mode is at the
bottom of this file for one-shot use from bash.
"""
from __future__ import annotations

import argparse
import base64
import json
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any, cast


class QGAError(RuntimeError):
    """Raised on virsh/qga protocol-level failures (channel down, command
    blacklisted, etc.). Distinct from a successful exec that returns a
    nonzero exit code (which is reported via ExecResult.rc, not raised)."""


@dataclass
class ExecResult:
    """Outcome of `QGA.exec_wait`. Mirrors subprocess.CompletedProcess —
    `rc` instead of `returncode` to keep call sites short."""
    rc: int
    stdout: str
    stderr: str
    timed_out: bool
    elapsed_s: float


class QGA:
    """Thin wrapper around `virsh qemu-agent-command <domain>`."""

    def __init__(self, domain: str, *, uri: str = "qemu:///system"):
        self.domain = domain
        self.uri = uri

    # ── primitive: send a single QMP-shaped JSON command ──────────

    def _run(self, payload: dict[str, Any], *, virsh_timeout: int = 5) -> dict[str, Any]:
        """Execute one guest-agent command. Returns the decoded JSON body
        (the {"return": ...} envelope from virsh). Raises QGAError if the
        channel isn't there or the command is blacklisted."""
        cmd = [
            "virsh", "-c", self.uri,
            "qemu-agent-command", self.domain,
            json.dumps(payload),
            "--timeout", str(virsh_timeout),
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=virsh_timeout + 5)
        if proc.returncode != 0:
            stderr = (proc.stderr or "").strip()
            raise QGAError(stderr or f"virsh exited {proc.returncode}")
        try:
            return cast(dict[str, Any], json.loads(proc.stdout))
        except json.JSONDecodeError as e:
            raise QGAError(f"non-JSON virsh stdout: {proc.stdout[:200]}") from e

    # ── public API ────────────────────────────────────────────────

    def ping(self, *, virsh_timeout: int = 5) -> bool:
        """Probe the agent. Returns True if guest-ping returns {}."""
        try:
            return self._run({"execute": "guest-ping"}, virsh_timeout=virsh_timeout) == {"return": {}}
        except QGAError:
            return False

    def is_available(self) -> bool:
        """Alias for ping(). Use as a feature-detection gate before
        choosing between qga and SSH transports."""
        return self.ping()

    def exec_async(
        self,
        argv: list[str],
        *,
        capture: bool = True,
        env: list[str] | None = None,
        input_data: bytes | str | None = None,
    ) -> int:
        """Start a guest process and return its pid. Use exec_status() to
        poll for completion. Prefer exec_wait() for synchronous needs."""
        if not argv:
            raise ValueError("argv must be non-empty")
        args: dict[str, Any] = {
            "path": argv[0],
            "arg": argv[1:],
            "capture-output": capture,
        }
        if env is not None:
            args["env"] = env
        if input_data is not None:
            if isinstance(input_data, str):
                input_data = input_data.encode("utf-8")
            args["input-data"] = base64.b64encode(input_data).decode("ascii")
        rv = self._run({"execute": "guest-exec", "arguments": args})
        return int(rv["return"]["pid"])

    def exec_status(self, pid: int) -> dict[str, Any]:
        """Raw guest-exec-status return body. Keys present once exited:
        exited (bool), exitcode (int), signal (int), out-data (base64),
        err-data (base64), out-truncated (bool), err-truncated (bool)."""
        return cast(
            dict[str, Any],
            self._run(
                {"execute": "guest-exec-status", "arguments": {"pid": pid}}
            )["return"],
        )

    def exec_wait(
        self,
        argv: list[str],
        *,
        capture: bool = True,
        env: list[str] | None = None,
        input_data: bytes | str | None = None,
        timeout: float = 60.0,
        poll_interval: float = 0.2,
    ) -> ExecResult:
        """Synchronous run-to-completion. Polls every poll_interval until
        the process exits or timeout elapses. On timeout, the guest
        process continues running — caller can re-poll via exec_status if
        they kept the pid."""
        pid = self.exec_async(argv, capture=capture, env=env, input_data=input_data)
        start = time.monotonic()
        deadline = start + max(0.1, timeout)
        # Backoff: tight at first (most commands finish in <1s), then
        # slower to keep virsh round-trips low.
        interval = poll_interval
        while time.monotonic() < deadline:
            st = self.exec_status(pid)
            if st.get("exited"):
                stdout = (
                    base64.b64decode(st["out-data"]).decode("utf-8", "replace")
                    if "out-data" in st else ""
                )
                stderr = (
                    base64.b64decode(st["err-data"]).decode("utf-8", "replace")
                    if "err-data" in st else ""
                )
                return ExecResult(
                    rc=int(st.get("exitcode", -1)),
                    stdout=stdout,
                    stderr=stderr,
                    timed_out=False,
                    elapsed_s=round(time.monotonic() - start, 3),
                )
            time.sleep(interval)
            interval = min(interval * 1.4, 2.0)
        return ExecResult(
            rc=-1, stdout="", stderr=f"timeout after {timeout}s (pid={pid})",
            timed_out=True, elapsed_s=round(time.monotonic() - start, 3),
        )

    def run_powershell(
        self,
        script: str,
        *,
        timeout: float = 60.0,
    ) -> ExecResult:
        """Convenience: run a PowerShell script via stdin. No file staging,
        no quoting hell. The script is passed as input-data to
        `powershell -NoProfile -Command -`."""
        return self.exec_wait(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "-"],
            input_data=script,
            timeout=timeout,
        )


# ── CLI front-end ─────────────────────────────────────────────────
# Lets bash callers do `python3 lib/qga.py exec <domain> -- cmd args...`
# without writing a Python wrapper for each site. Exit code mirrors the
# guest command's; stdout/stderr are forwarded transparently.

def _cli():
    p = argparse.ArgumentParser(description="qga.py — virsh qemu-agent-command helper")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_ping = sub.add_parser("ping", help="probe qga availability; exit 0 on success")
    p_ping.add_argument("domain")
    p_ping.add_argument("--uri", default="qemu:///system")

    # exec: split on `--` BEFORE argparse sees it, so --timeout 8 doesn't
    # get gobbled into REMAINDER. Convention: everything after `--` is the
    # guest argv. If no `--`, treat the remaining positional as argv[0]+.
    p_exec = sub.add_parser("exec", help="run a command in the guest (-- argv...)")
    p_exec.add_argument("domain")
    p_exec.add_argument("--uri", default="qemu:///system")
    p_exec.add_argument("--timeout", type=float, default=60.0)

    p_ps = sub.add_parser("powershell", help="run PowerShell from stdin")
    p_ps.add_argument("domain")
    p_ps.add_argument("--uri", default="qemu:///system")
    p_ps.add_argument("--timeout", type=float, default=60.0)

    raw = sys.argv[1:]
    sep = raw.index("--") if "--" in raw else None
    if sep is not None:
        flag_args = raw[:sep]
        guest_argv = raw[sep + 1:]
    else:
        flag_args = raw
        guest_argv = []
    args = p.parse_args(flag_args)
    qga = QGA(args.domain, uri=args.uri)

    if args.cmd == "ping":
        ok = qga.ping()
        sys.exit(0 if ok else 1)

    if args.cmd == "exec":
        if not guest_argv:
            sys.stderr.write("exec needs argv (after `--`)\n")
            sys.exit(2)
        try:
            r = qga.exec_wait(guest_argv, timeout=args.timeout)
        except QGAError as e:
            sys.stderr.write(f"qga: {e}\n")
            sys.exit(125)
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        sys.exit(r.rc if not r.timed_out else 124)

    if args.cmd == "powershell":
        script = sys.stdin.read()
        try:
            r = qga.run_powershell(script, timeout=args.timeout)
        except QGAError as e:
            sys.stderr.write(f"qga: {e}\n")
            sys.exit(125)
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        sys.exit(r.rc if not r.timed_out else 124)


if __name__ == "__main__":
    _cli()
