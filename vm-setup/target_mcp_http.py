"""HTTP relay for DesktopCommanderMCP on the target VM.

Spawns DesktopCommanderMCP (Node.js stdio MCP) and bridges it to
FastMCP streamable-HTTP on port 8200, reachable from the Linux host.

Analogous to run_http.py on the debugger VM (WinDbg MCP on :8100),
but for the target VM — gives the AI direct process + file access
on the machine where PoCs run.

Run:
    python target_mcp_http.py --port 8200 --host 0.0.0.0
"""
from __future__ import annotations

import argparse
import logging
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent

NODE   = r"C:\Program Files\nodejs\node.exe"
DCMCP  = r"C:\winforge\node_modules\@wonderwhy-er\desktop-commander\dist\index.js"
LOG_DIR = Path(r"C:\winforge\logs")


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
            logging.StreamHandler(sys.stdout),
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

    from fastmcp import FastMCP, Client
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

    log.info("MCP endpoint: http://%s:%d/mcp", args.host, args.port)
    proxy.run(transport="streamable-http", host=args.host, port=args.port)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
