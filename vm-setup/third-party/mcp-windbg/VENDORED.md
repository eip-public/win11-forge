# Vendored: svnscha/mcp-windbg

| | |
|---|---|
| Upstream | https://github.com/svnscha/mcp-windbg |
| Vendored | 2026-04-23 (v0.13.0) |
| Purpose  | Win11-Forge's user-mode debugger MCP endpoint (`:8300`) — thin CDB wrapper with clean `bp` / `go` / `k` semantics |

## Win11-forge deltas from upstream

1. **`cdb_session.py`** — `CDBSession.__init__` accepts a new
   `local_attach` arg for attaching to a running local process.
   Formats:
     - `"pid:1234"`   → `cdb -p 1234`
     - `"name:x.exe"` → `cdb -pn x.exe`
     - bare digits are treated as a PID
     - bare strings as an image name
   The "exactly one of {dump_path, remote_connection, local_attach}"
   validation extends to three mutually-exclusive sources.

2. **`server.py`** — two new tools:
     - `open_windbg_local(target, include_stack_trace,
       include_modules, include_threads)` — attach CDB to a local
       live process; emits initial register snapshot.
     - `close_windbg_local(target)` — detach + cleanup.
   Extended `RunWindbgCmdParams` and `SendCtrlBreakParams` with an
   optional `local_target` so `run_windbg_cmd` + `send_ctrl_break`
   route to local-attach sessions too.  Factored a `_session_id()`
   helper handling all three session-source types.

3. **`prompts/__init__.py`** — stub module (not present upstream's
   compiled tree because upstream uses a YAML-backed templates
   directory we didn't vendor). Satisfies `server.py`'s
   `from .prompts import load_prompt` import by returning empty
   prompt bodies. If a future stage needs real triage prompts,
   re-vendor the full `src/mcp_windbg/prompts/` subtree from upstream.

## Not vendored from upstream

- `src/mcp_windbg/tests/dumps/` (7.8 MB example crash dump)
- `src/mcp_windbg/prompts/` — stubbed instead (see the delta below).
  Win11-Forge drives mcp-windbg via `run_windbg_cmd` tool calls, not via
  the MCP `list_prompts` / `get_prompt` surface, so a load_prompt() that
  returns empty strings is functionally equivalent here.
- `uv.lock` (auto-generated)

## How it is launched

Integrated into the gold image + lab-spawn flow:

- **`vm-setup/setup-vm.sh`** tars the vendored source, uploads it, and
  runs `python -m pip install C:\winforge\mcp-windbg-src` as part of
  gold-image build. The CLI lands at `C:\Python314\Scripts\mcp-windbg.exe`.
- **`vm-setup/role-bootstrap-target.sh`** (target-role only) registers a
  `TargetMcpWindbgBoot` scheduled task running
  `mcp-windbg.exe --transport streamable-http --host 0.0.0.0 --port 8300`
  at `SC ONSTART / RU SYSTEM / RL HIGHEST`, then runs it once so
  `:8300/mcp/` is live by the end of `./setup.sh lab spawn`.
- As a safety net, `role-bootstrap-target.sh` detects gold images that
  predate the setup-vm.sh change and does the pip install at spawn
  time — so `lab spawn` against an older gold still brings `:8300` up.

Manual one-shot for testing a local edit (bypassing the task):
```
C:\Python314\Scripts\mcp-windbg.exe --transport streamable-http --host 0.0.0.0 --port 8300
```

## Client-side notes (agents calling `:8300`)

The upstream uses the `mcp` Python package, not FastMCP — subtle
behavioural differences from the other Win11-Forge endpoints:

- Endpoint path is **`/mcp/` with trailing slash** (`/mcp` → 307).
- Responses are **plain JSON**, not SSE-framed — don't strip a
  `data:` prefix.
- After `initialize` the client **must** send a
  `notifications/initialized` message before `tools/call` will
  dispatch (FastMCP handles this implicitly, `mcp` doesn't).
- CDB-level `g` blocks up to 30 s server-side; subsequent tool
  calls queue behind it. Use `send_ctrl_break` to interrupt if
  needed.
- One debugger per target process (Windows rule). `cdb.exe`
  survives if the MCP server crashes — kill any stale `cdb.exe`
  before re-attaching.

See `skills/poc-dev/SKILL.md` for the canonical attack-surface-
discovery recipe and `skills/lab-setup/SKILL.md` for the full
four-MCP decision matrix.

## Upstream contribution

The two deltas are small, clean, and general-purpose (no
Win11-Forge assumptions); worth submitting upstream as a PR.
