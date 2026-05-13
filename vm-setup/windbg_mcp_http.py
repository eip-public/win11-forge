"""
HTTP wrapper for NadavLor/windbg-ext-mcp server.

The upstream server.py hardcodes stdio. This sibling entry-point
reuses the same initialization + tool registration but binds the
FastMCP instance to streamable-http so we can reach it from the
Linux host over the libvirt default network.

Deploy alongside the cloned repo at:
    C:\\winforge\\windbg-ext-mcp\\run_http.py

Run:
    python run_http.py --port 8100 --host 0.0.0.0
"""
from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE / "mcp_server"))

from fastmcp import FastMCP  # noqa: E402
from config import load_environment_config, LOG_LEVEL, LOG_FORMAT  # noqa: E402
from tools import register_all_tools  # noqa: E402
from core.server_initialization import ServerInitializer, InitializationConfig  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="WinDbg MCP server over HTTP")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8100)
    parser.add_argument("--path", default="/mcp")
    args = parser.parse_args()

    load_environment_config()
    logging.basicConfig(level=getattr(logging, LOG_LEVEL), format=LOG_FORMAT)
    log = logging.getLogger("windbg-mcp-http")

    log.info("Initializing WinDbg MCP server (HTTP transport)")
    mcp = FastMCP()
    initializer = ServerInitializer(InitializationConfig())
    initializer.initialize()
    register_all_tools(mcp)
    log.info("Binding streamable-http on %s:%d%s", args.host, args.port, args.path)
    mcp.run(transport="streamable-http", host=args.host, port=args.port, path=args.path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
