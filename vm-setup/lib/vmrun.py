"""Host-side wrapper around `vmrun runProgramInGuest` (VMware Workstation).

VMware analog of vm-setup/lib/qga.py. Drives the guest via the VMware
Tools daemon (vmtoolsd) over the hypervisor's private channel; same
upside as qga: no network listener, no SSH worker to wedge, runs as
the guest user (forge here) once Tools authentication succeeds.

Why a separate library: vmrun has different ergonomics than qga.
  - Auth: every call needs -gu/-gp with the guest username/password
    (forge/forge123). No host-side identity passthrough.
  - Stdout capture: runProgramInGuest does NOT return stdout. The
    common workaround is to redirect program output to a file inside
    the guest then `copyFileFromGuestToHost` to retrieve. This module
    implements that pattern in exec_wait().
  - Sync vs async: runProgramInGuest blocks until the process exits
    unless -noWait is passed. Without -noWait, vmrun's exit code maps
    to the guest program's exit code (lossy at high values but fine
    for 0/1/<255).

Constraints:
  - VMware Tools daemon must be running in the guest. We install it
    in the gold via setup-vm-phases/install_vmware_tools.ps1.
  - vmrun must be on PATH on the host. Ships with VMware Workstation.
"""
from __future__ import annotations

import argparse
import base64
import os
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass


class VmrunError(RuntimeError):
    """vmrun-protocol-level failure (Tools not running, auth bad, etc.).
    Distinct from a successful exec returning a nonzero exit code."""


@dataclass
class ExecResult:
    rc: int
    stdout: str
    stderr: str
    timed_out: bool
    elapsed_s: float


# Path inside the guest where we stage run-and-capture stdout/stderr
# files. Created by install_vmware_tools.ps1 if absent (it's also a
# directory `C:\winforge\` which setup-vm.sh creates first).
_GUEST_CAPTURE_DIR = r"C:\winforge\vmrun-rps"


class VMRun:
    """Thin wrapper around `vmrun runProgramInGuest <vmx> ...`."""

    def __init__(
        self,
        vmx: str,
        *,
        user: str = "forge",
        password: str = "forge123",
    ):
        self.vmx = vmx
        self.user = user
        self.password = password

    # ── primitives ────────────────────────────────────────────────

    def _vmrun(self, *args: str, timeout: float = 30.0) -> subprocess.CompletedProcess:
        cmd = ["vmrun", "-gu", self.user, "-gp", self.password, *args]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)

    # ── public API ────────────────────────────────────────────────

    def ping(self, *, timeout: float = 10.0) -> bool:
        """Probe vmtoolsd reachability. Uses `listProcessesInGuest` as a
        lightweight liveness check (vmrun returns process table without
        spawning anything). Returns True iff exit 0."""
        try:
            p = self._vmrun("listProcessesInGuest", self.vmx, timeout=timeout)
            return p.returncode == 0
        except subprocess.TimeoutExpired:
            return False

    def is_available(self) -> bool:
        return self.ping()

    def exec_wait(
        self,
        argv: list[str],
        *,
        capture: bool = True,
        timeout: float = 60.0,
    ) -> ExecResult:
        """Run argv in the guest synchronously. Returns rc + stdout + stderr.

        If capture=True (default), wraps the argv in cmd.exe redirection
        to write stdout/stderr to a per-call file in the guest, then
        copies it back. Adds ~1s of round-trip overhead per call.

        If capture=False, runs argv directly with no redirection. Faster
        but returns empty stdout/stderr (just exit code).
        """
        if not argv:
            raise ValueError("argv must be non-empty")
        start = time.monotonic()

        if not capture:
            try:
                p = self._vmrun(
                    "runProgramInGuest", self.vmx,
                    "-interactive", *argv,
                    timeout=timeout,
                )
                return ExecResult(
                    rc=p.returncode, stdout="", stderr="",
                    timed_out=False,
                    elapsed_s=round(time.monotonic() - start, 3),
                )
            except subprocess.TimeoutExpired:
                return ExecResult(
                    rc=-1, stdout="", stderr=f"timeout after {timeout}s",
                    timed_out=True,
                    elapsed_s=round(time.monotonic() - start, 3),
                )

        # capture=True: vmrun's runProgramInGuest joins argv into a
        # single command line that Windows parses without honoring our
        # quoting, which means inline `>` / `2>` redirects don't work.
        # Workaround used by every maintained vmrun client: write a
        # batch file to the guest that contains the literal command +
        # redirects, then run `cmd /c <batfile>` (single argv, no
        # quoting). Read the captured stdout/stderr back via
        # copyFileFromGuestToHost.
        token = uuid.uuid4().hex
        guest_out = f"{_GUEST_CAPTURE_DIR}\\out-{token}.txt"
        guest_err = f"{_GUEST_CAPTURE_DIR}\\err-{token}.txt"
        guest_bat = f"{_GUEST_CAPTURE_DIR}\\rps-{token}.bat"

        # Build batch contents. Each argv element gets cmd-quoted only
        # if it contains spaces or special characters; otherwise passed
        # as-is. Redirects go OUTSIDE the quotes so cmd parses them.
        def _bat_quote(s: str) -> str:
            # cmd.exe argument quoting: wrap in "..." if it contains
            # whitespace, double any embedded ".
            if any(c in s for c in (' ', '\t', '&', '|', '<', '>', '^')):
                return '"' + s.replace('"', '""') + '"'
            return s

        bat_cmd = " ".join(_bat_quote(a) for a in argv)
        # @echo off + setlocal so the batch file is quiet and side-effects
        # to env vars don't leak. The redirects happen here, OUTSIDE the
        # quoted command, so cmd's parser sees them as redirects not args.
        bat_body = (
            "@echo off\r\n"
            "setlocal\r\n"
            f'{bat_cmd} > "{guest_out}" 2> "{guest_err}"\r\n'
            "exit /b %ERRORLEVEL%\r\n"
        )

        # Stage the batch file: write locally, copyFileFromHostToGuest.
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".bat", encoding="ascii", delete=False
        ) as tmp:
            tmp.write(bat_body)
            host_bat = tmp.name

        try:
            # Ensure capture dir exists.
            self._vmrun(
                "createDirectoryInGuest", self.vmx, _GUEST_CAPTURE_DIR,
                timeout=10,
            )  # idempotent: errors silently on existing dir
            # Upload the batch file.
            self._vmrun(
                "copyFileFromHostToGuest", self.vmx, host_bat, guest_bat,
                timeout=15,
            )
            # Run the batch file.
            p = self._vmrun(
                "runProgramInGuest", self.vmx,
                "-interactive",
                r"C:\Windows\System32\cmd.exe", "/c", guest_bat,
                timeout=timeout,
            )
            rc = p.returncode
        except subprocess.TimeoutExpired:
            return ExecResult(
                rc=-1, stdout="", stderr=f"timeout after {timeout}s",
                timed_out=True,
                elapsed_s=round(time.monotonic() - start, 3),
            )
        finally:
            try:
                os.unlink(host_bat)
            except OSError:
                pass

        # Pull stdout + stderr back via copyFileFromGuestToHost.
        stdout = self._fetch_guest_file(guest_out)
        stderr = self._fetch_guest_file(guest_err)

        # Best-effort cleanup of the guest capture files.
        for f in (guest_out, guest_err, guest_bat):
            try:
                self._vmrun(
                    "deleteFileInGuest", self.vmx, f,
                    timeout=5,
                )
            except subprocess.TimeoutExpired:
                pass

        return ExecResult(
            rc=rc, stdout=stdout, stderr=stderr,
            timed_out=False,
            elapsed_s=round(time.monotonic() - start, 3),
        )

    def run_powershell(self, script: str, *, timeout: float = 60.0) -> ExecResult:
        """Convenience: run a PowerShell script with stdout/stderr captured.
        Uses -EncodedCommand to ship the script as opaque base64-UTF16LE
        (same robustness guarantee as guest.sh's SSH path)."""
        encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
        return self.exec_wait(
            [
                r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
                "-NoProfile",
                "-EncodedCommand",
                encoded,
            ],
            capture=True,
            timeout=timeout,
        )

    def _fetch_guest_file(self, guest_path: str) -> str:
        """Read a small text file out of the guest via copyFileFromGuestToHost."""
        with tempfile.NamedTemporaryFile(mode="rb", delete=False) as tmp:
            host_path = tmp.name
        try:
            try:
                p = self._vmrun(
                    "copyFileFromGuestToHost", self.vmx,
                    guest_path, host_path,
                    timeout=10,
                )
            except subprocess.TimeoutExpired:
                return ""
            if p.returncode != 0:
                return ""
            with open(host_path, "rb") as fh:
                return fh.read().decode("utf-8", errors="replace")
        finally:
            try:
                os.unlink(host_path)
            except OSError:
                pass


# ── CLI front-end ─────────────────────────────────────────────────

def _cli():
    p = argparse.ArgumentParser(description="vmrun.py — vmrun runProgramInGuest wrapper")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_ping = sub.add_parser("ping", help="probe vmtoolsd reachability; exit 0 on success")
    p_ping.add_argument("vmx")
    p_ping.add_argument("--user", default="forge")
    p_ping.add_argument("--password", default="forge123")

    p_exec = sub.add_parser("exec", help="run a command in the guest (-- argv...)")
    p_exec.add_argument("vmx")
    p_exec.add_argument("--user", default="forge")
    p_exec.add_argument("--password", default="forge123")
    p_exec.add_argument("--timeout", type=float, default=60.0)

    p_ps = sub.add_parser("powershell", help="run PowerShell script from stdin")
    p_ps.add_argument("vmx")
    p_ps.add_argument("--user", default="forge")
    p_ps.add_argument("--password", default="forge123")
    p_ps.add_argument("--timeout", type=float, default=60.0)

    # Same `--` separator trick as qga.py to avoid argparse REMAINDER
    # eating named flags.
    raw = sys.argv[1:]
    sep = raw.index("--") if "--" in raw else None
    if sep is not None:
        flag_args, guest_argv = raw[:sep], raw[sep + 1:]
    else:
        flag_args, guest_argv = raw, []
    args = p.parse_args(flag_args)

    v = VMRun(args.vmx, user=args.user, password=args.password)

    if args.cmd == "ping":
        sys.exit(0 if v.ping() else 1)

    if args.cmd == "exec":
        if not guest_argv:
            sys.stderr.write("exec needs argv (after `--`)\n")
            sys.exit(2)
        try:
            r = v.exec_wait(guest_argv, timeout=args.timeout)
        except VmrunError as e:
            sys.stderr.write(f"vmrun: {e}\n")
            sys.exit(125)
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        sys.exit(r.rc if not r.timed_out else 124)

    if args.cmd == "powershell":
        script = sys.stdin.read()
        try:
            r = v.run_powershell(script, timeout=args.timeout)
        except VmrunError as e:
            sys.stderr.write(f"vmrun: {e}\n")
            sys.exit(125)
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        sys.exit(r.rc if not r.timed_out else 124)


if __name__ == "__main__":
    _cli()
