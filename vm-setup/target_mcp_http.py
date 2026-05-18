"""HTTP relay for DesktopCommanderMCP on the target VM.

Spawns DesktopCommanderMCP (Node.js stdio MCP) and bridges it to
FastMCP streamable-HTTP on port 8200, reachable from the Linux host.

Analogous to run_http.py on the debugger VM (WinDbg MCP on :8100),
but for the target VM — gives the AI direct process + file access
on the machine where PoCs run.

Also registers a native `run_powershell_script` tool alongside the
proxied DC tools — collapses the agent-side write_file +
start_process + read_process_output dance into one call when the
need is "run this PowerShell and give me the output".

Run:
    python target_mcp_http.py --port 8200 --host 0.0.0.0
"""
from __future__ import annotations

import argparse
import logging
import subprocess
import sys
import time
import uuid
from pathlib import Path

NODE   = r"C:\Program Files\nodejs\node.exe"
DCMCP  = r"C:\winforge\node_modules\@wonderwhy-er\desktop-commander\dist\index.js"
LOG_DIR = Path(r"C:\winforge\logs")
RPS_DIR = Path(r"C:\winforge\rps")  # run_powershell_script staging dir


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8200)
    args = parser.parse_args()

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [target-mcp] %(levelname)s %(message)s",
        handlers=[
            logging.FileHandler(str(LOG_DIR / "target-mcp.log"), encoding="utf-8"),
            # Stderr (not stdout): MCP servers reserve stdout for protocol data.
            logging.StreamHandler(sys.stderr),
        ],
    )
    log = logging.getLogger("target-mcp")

    if not Path(DCMCP).exists():
        log.error("DesktopCommanderMCP not found: %s", DCMCP)
        log.error("Run: cd C:\\winforge && npm install @wonderwhy-er/desktop-commander")
        return 1

    log.info("Starting DesktopCommanderMCP HTTP relay on %s:%d", args.host, args.port)
    log.info("  Node: %s", NODE)
    log.info("  DCMCP: %s", DCMCP)

    from fastmcp import Client, FastMCP
    from fastmcp.client.transports import NodeStdioTransport

    # NodeStdioTransport spawns: node <script_path>
    # node_cmd defaults to "node" which must be on PATH.
    transport = NodeStdioTransport(
        script_path=DCMCP,
        node_cmd=NODE,
        log_file=LOG_DIR / "dcmcp-node.log",
    )
    backend = Client(transport)

    # Proxy all tools/resources from the backend over streamable-HTTP.
    proxy = FastMCP.as_proxy(backend, name="WinForge-Target")

    # Register a native `run_powershell_script` tool alongside the proxied
    # DC tools. Use case: the standard `start_process` + `read_process_output`
    # dance plus the bash→Python→JSON→PowerShell quoting hell makes ad-hoc
    # PowerShell painful for an agent. This tool stages a tmp .ps1, invokes
    # it with -NoProfile -ExecutionPolicy Bypass, and returns the merged
    # stdout/stderr + exit code in one round trip.
    RPS_DIR.mkdir(parents=True, exist_ok=True)

    @proxy.tool
    def run_powershell_script(script: str, timeout_s: float = 30.0) -> dict:
        """Run a PowerShell script on the guest and return stdout+stderr+rc.

        Args:
            script: PowerShell source. No quoting gymnastics required.
            timeout_s: Hard timeout (seconds). Capped at 300; default 30.

        Returns:
            {"exit_code": int, "stdout": str, "stderr": str, "timed_out": bool,
             "elapsed_s": float, "script_path": str}
        """
        timeout = max(1.0, min(float(timeout_s), 300.0))
        ps1 = RPS_DIR / f"rps-{uuid.uuid4().hex}.ps1"
        ps1.write_text(script, encoding="utf-8")
        start = time.monotonic()
        try:
            proc = subprocess.run(
                ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ps1)],
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
            return {
                "exit_code": proc.returncode,
                "stdout": proc.stdout,
                "stderr": proc.stderr,
                "timed_out": False,
                "elapsed_s": round(time.monotonic() - start, 3),
                "script_path": str(ps1),
            }
        except subprocess.TimeoutExpired as e:
            def _decode(stream: object) -> str:
                if isinstance(stream, bytes):
                    return stream.decode("utf-8", "replace")
                if isinstance(stream, str):
                    return stream
                return ""

            return {
                "exit_code": -1,
                "stdout": _decode(e.stdout),
                "stderr": _decode(e.stderr),
                "timed_out": True,
                "elapsed_s": round(time.monotonic() - start, 3),
                "script_path": str(ps1),
            }
        finally:
            # Keep the .ps1 on disk on failure for post-mortem; clean only on
            # clean success.
            pass

    log.info("MCP endpoint: http://%s:%d/mcp", args.host, args.port)
    log.info("Native tools: run_powershell_script")
    proxy.run(transport="streamable-http", host=args.host, port=args.port)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
