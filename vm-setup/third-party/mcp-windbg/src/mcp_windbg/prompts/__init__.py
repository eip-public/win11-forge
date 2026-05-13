"""Minimal prompts stub for Win11-Forge vendored mcp-windbg.

Upstream ships a `prompts/` subpackage with dump-triage templates that
`server.py` loads via `load_prompt()` for the MCP `list_prompts` /
`get_prompt` surface. Win11-Forge drives mcp-windbg from the poc-dev /
poc-verify skills (live bp + k + !analyze via `run_windbg_cmd`), not via
the prompts surface, so we stub load_prompt() to return empty content.

If a later Win11-Forge stage needs the real triage prompts, re-vendor
the full `prompts/` subtree from upstream instead of extending this stub.
"""
from typing import Optional


def load_prompt(name: str) -> str:
    """Return an empty prompt body for any requested prompt name.

    server.py calls this only from `get_prompt("dump-triage")`. An empty
    string keeps the MCP handshake valid; agents that want real triage
    prompts should re-vendor the upstream `prompts/` tree.
    """
    return ""
