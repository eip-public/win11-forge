---
name: lab-setup
description: Stage 3 of the win11-forge CVE pipeline. Spawn the kernel-debug lab pair (target VM + debugger VM), configure KDNET on the target, start kd_wrapper.py on the debugger, and require the immediate MCP endpoints (:8200, :8201, :8300). The kernel MCP (:8100) comes up after first crash or lab load-mcp. Triggers: user says "set up the lab", "spawn the debug VMs", "start the kernel debug pair", or pipeline progresses from diff-analysis to poc-dev.
---

# lab-setup

**Pipeline stage 3 of 8.** Spin up a fresh target+debugger VM pair, configure
KDNET kernel debugging, and prepare the environment for PoC execution, live
user-mode debugging, and crash capture. Three required MCP endpoints come up
automatically after spawn; the kernel WinDbg MCP comes up after the first
kernel break or `./setup.sh lab load-mcp`.

## Inputs
- Gold image must exist: `vm-images/winforge-win11-24h2-gold.qcow2`
- `lab/<CVE_ID>/intel_brief.md` from patch-intel
- Win11-forge repo at `~/repos/win11-forge/`

## Backend

IPs and console tooling throughout this guide show **KVM defaults**
(`192.168.122.100/.101`). Under `WINFORGE_BACKEND=vmware` the same pair
lives at `172.16.87.100/.101` (detected from vmnet8, pinned via
`./install-deps.sh vmware`). Always run `./setup.sh lab status` at the
start of a session — it prints the active backend and the live IPs.
Everything else (MCP ports, SSH creds, kd_wrapper flow, KDNET transport)
is identical across backends.

VMware GUI mode is the default for `lab spawn` and `lab start`. If VMware
Workstation is not already running, the backend tries the desktop launcher
(`gtk-launch vmware-workstation`) before `vmrun`. If that cannot attach to the
desktop session, open VMware Workstation from the XFCE panel and rerun the lab
command. Use `--nogui` only after validating headless VMware startup on the
host.

## Outputs — four MCP endpoints

| Endpoint | Host | Purpose | Lifecycle |
|---|---|---|---|
| **`:8100/mcp`** (WinDbg kernel) | debugger VM | Kernel debugging via KDNET → target kernel. Used for kernel-mode CVEs (drivers, syscalls, win32k) and post-BugCheck forensics. | Up **after** first kernel break (BugCheck or `./setup.sh lab load-mcp`) |
| **`:8200/mcp`** (DesktopCommander) | target VM | File/process ops on the target: deploy PoC, run it, read output, register-level ops via PowerShell. | Required at spawn |
| **`:8201/mcp`** (DesktopCommander) | debugger VM | File/process ops on the debugger: read kd logs, edit kd_wrapper.py, inspect state. | Required at spawn |
| **`:8300/mcp/`** (mcp-windbg, CDB) | target VM | **Live user-mode debugging.** Attach to a running process by PID/name, set breakpoints, step, read memory/registers/stack. Used for usermode service CVEs (spoolsv, mssrch, lsass, …) and general attack-surface discovery. Mounts at `/mcp/` with trailing slash (not `/mcp`). | Required at spawn |

Plus:
- `winforge-target` VM at `192.168.122.100` — KDNET kernel debug enabled, auto-reboot on BSOD
- `winforge-debugger` VM at `192.168.122.101` — kd_wrapper supervisor running; use `./setup.sh lab wait-kd` to verify KDNET
- `lab/<CVE_ID>/lab_setup_report.md`

## Decision table: which MCP for which job

| You want to… | Use | Tool(s) |
|---|---|---|
| Attach to a running user-mode process and set a bp | `:8300/mcp/` | `open_windbg_local` + `run_windbg_cmd` |
| See what calls a given server-side function | `:8300/mcp/` | bp + `g` + `k 30` |
| Analyze a kernel BugCheck | `:8100/mcp` | `run_command` `!analyze -v` / `k`/ `!process` |
| Set bp inside the kernel or a driver | `:8100/mcp` | `bp mod!fn`, `.process /i /r <eproc>` dance |
| Deploy a PoC to the target and run it | `:8200/mcp` | `write_file` + `start_process` + `read_process_output` |
| Read a log on the debugger (kd.out.log, kd_wrapper.log) | `:8201/mcp` | `read_file` |
| Restart WSearch, touch a file, query WMI | `:8200/mcp` | `start_process` with powershell |

**Rule of thumb:** for **user-mode** CVEs (most Windows services), `:8300`
replaces everything kernel-debug used to do for attack-surface discovery. Keep
`:8100` for actual kernel work and post-crash forensics.

## How it works

```
winforge-target  (192.168.122.100)
  Windows kernel + bcdedit KDNET sends UDP to 192.168.122.101:50000
  Auto-reboots on BSOD (CrashControl\AutoReboot=1)
  Driver Verifier enabled on target driver (optional, recommended for UAF/race)

  target_mcp_http.py (SYSTEM, TargetDesktopBoot scheduled task)
    DesktopCommanderMCP (Node.js stdio) -> HTTP :8200/mcp  [up immediately]
      start_process, read_process_output, interact_with_process
      read_file, write_file, edit_block, list_directory, ripgrep search
    Use for: deploy PoC, run it, read output, edit scripts — no SSH quoting

  mcp-windbg (svnscha fork, CDB-based) [win11-forge vendor + local-attach delta]
    SYSTEM, TargetMcpWindbgBoot scheduled task, ONSTART + ran once by role-bootstrap
    C:\Python314\Scripts\mcp-windbg.exe --transport streamable-http
                                         --host 0.0.0.0 --port 8300
      cdb.exe -pn <proc> (on demand, per session)
      9 tools: open_windbg_local, close_windbg_local, run_windbg_cmd,
               send_ctrl_break, open_windbg_dump, close_windbg_dump,
               open_windbg_remote, close_windbg_remote, list_windbg_dumps
    Use for: live user-mode debugging (attach, bp, go, step, read state).
    Note: endpoint is /mcp/ WITH trailing slash. Responses are plain JSON
    (not SSE-wrapped like the other MCPs).

winforge-debugger (192.168.122.101)
  kd_wrapper.py (SYSTEM, DebuggerBoot scheduled task, never exits)
    kd.exe  <- KDNET UDP:50000 ->  target kernel (silent attach, no boot break)
      On first BugCheck: .load windbgmcpExt.dll; mcpstart; g
      On subsequent crashes: auto-reconnect, extension stays loaded
    run_http.py  ->  http://0.0.0.0:8100/mcp  [up after first crash]
  target_mcp_http.py (SYSTEM, DebuggerDesktopBoot scheduled task)
    DesktopCommanderMCP (Node.js stdio) -> HTTP :8201/mcp  [up immediately]
    Use for: read kd_wrapper.log, check kd.exe state, edit kd_wrapper.py
```

## Critical design decisions

### The target VM is frozen at its gold-image build

`setup-vm.sh` runs a hardening pass as part of initial provisioning that
disables `wuauserv`, `UsoSvc`, `BITS`, flips `WaaSMedicSvc` to `Start=4`
via registry (its ACL rejects `sc config`), disables every scheduled task
under `\Microsoft\Windows\UpdateOrchestrator\` / `WindowsUpdate\` /
`WaaSMedic\`, and writes `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\NoAutoUpdate=1`.
Every fresh overlay off the gold image inherits this. **If you see a
"Please keep your device on. XX% complete" update-apply screen during a
lab run, the gold image predates this hardening — rebuild the gold.**
The rationale is that a mid-run Windows Update can silently bump the
target past the CVE's vulnerable baseline and destroy the research target.

### Gold image build vs. CVE vulnerable build

The gold image is one fixed Windows build. The CVE you're analysing may
target a different build. Two cases:

1. **Gold is older than the patch** (common): the vulnerable code path is
   usually present in the gold's DLL too — the patch only *added* the
   guard. Verify by looking at the ghidriff "Modified" section; if the
   gold's function matches the pre-patch decomp, you can use the gold
   binary as-is. This is the quickest path — no swap needed.
2. **Gold is post-patch** or the CVE-specific code doesn't exist in the
   gold build: swap the specific vulnerable DLL from `lab/<CVE>/bins/`
   into `C:\Windows\System32\` on the target. System DLLs are mmap-loaded
   by many processes and can't be overwritten online; use `MoveFileEx`
   with `MOVEFILE_REPLACE_EXISTING | MOVEFILE_DELAY_UNTIL_REBOOT` (flags
   `0x5`) to schedule the rename for next boot, then reboot. After reboot
   the target runs the vulnerable DLL; re-apply any per-run state
   (PageHeap, service start, etc.).

In both cases, the lab's WU hardening keeps the build stable across
reboots.

### Do NOT use -b (force break at boot)

The `-b` flag tells kd to send a break request immediately on KDNET connection.
The problem: KDNET handshakes complete before the target kernel's network stack
is fully operational. The break handshake requires a two-way exchange, but the
target cannot respond yet. Result: kd shows "Connected to target..." then hangs
indefinitely waiting for acknowledgment. The target appears frozen (black screen).

**Rule: never use `kd.exe -b`.** Always silent-attach.

### kd only processes commands at a break prompt

kd.exe in "target running" mode does NOT process stdin commands. Neither stdin
injection nor `-c` flags execute while the target is running. Commands only run
when kd is at an interactive prompt (after a break).

The correct injection point: BugCheck. When the target kernel panics, the kernel
debug driver automatically breaks into kd. At that break, kd runs the `-c`
commands (`.load dll; mcpstart; g`). The extension then stays loaded across
subsequent reboots because kd.exe never exits.

**Rule: use `-c ".load dll; mcpstart; g"` without `-b`. Commands fire on first BugCheck.**

### kd_wrapper.py is the persistence layer

kd.exe exits on stdin EOF. Any parent process that starts kd.exe and then exits
will cause kd to exit too. `kd_wrapper.py` solves this by holding the stdin pipe
open forever via `subprocess.PIPE`. Additionally the wrapper:
- Auto-restarts kd.exe (and HTTP server) if kd crashes
- Restarts only the HTTP server if HTTP crashes but kd survives
- Detects kd connection via log parsing ("Connected to target")
- Detects MCP readiness via named pipe existence check

**Rule: always run kd through kd_wrapper.py, never directly.**

## Procedure

### 1. Spawn the lab pair

```bash
cd ~/repos/win11-forge
./setup.sh lab spawn
```

This: creates overlays off gold for both VMs, starts them, role-bootstraps
target (KDNET bcdedit + auto-reboot + Driver Verifier optional), starts
kd_wrapper.py on debugger via DebuggerBoot scheduled task.

After spawn, `:8200`, `:8201`, and `:8300` are ready or the spawn fails.
KDNET may still need synchronization; run `./setup.sh lab wait-kd` before
kernel-debug work. The kernel WinDbg MCP at `:8100` is pending until the first
BugCheck or `./setup.sh lab load-mcp`.

### 2. (Optional but recommended for UAF/race CVEs) Enable Driver Verifier

Driver Verifier with Special Pool places a guard page after every allocation
made by the target driver. Any write into a freed allocation immediately
triggers SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION - a crash that would
otherwise be silent heap corruption causing a delayed, unpredictable crash.

```powershell
# On target VM - makes UAF = instant BSOD instead of silent corruption
verifier /flags 0x9 /driver <target_driver.sys>
# Flags: 0x1 = Special Pool, 0x8 = Pool Tracking
shutdown /r /t 3 /f   # Reboot to activate
```

After reboot, kd_wrapper.py auto-reconnects. Verify with:
```
kd.out.log shows: "Driver Verifier: Applied for <driver.sys>, flags 0x9"
```

### 3. (Optional) Load MCP before the first crash for pre-crash debugging

By default, the WinDbg MCP extension loads on the first BugCheck. If you need
MCP active BEFORE any crash (e.g. to set breakpoints on the vulnerable function,
inspect heap layout, or watch the race at the assembly level), use:

```bash
./setup.sh lab load-mcp
```

This first ensures KDNET is connected, then calls
`NtSystemDebugControl(SysDbgBreakPoint=6)` on the target as admin. The kernel
fires an `int 3` that kd catches over KDNET. The prompt monitor detects the
`kd>` prompt and injects `.load dll; mcpstart; g`. The extension loads, MCP
comes online, and `g` resumes the target.

`SysDbgBreakPoint=6` is from the `SYSDBG_COMMAND` enum (ntdoc.m417z.com,
confirmed by ReactOS dbgctrl.c). Requires `SeDebugPrivilege`, which local
admins have by default on Windows.

When to use:
- UAF CVEs where you need to craft heap layout before triggering
- Analyzing kernel state at a specific point before the crash
- Setting breakpoints on vulnerable functions (note: may suppress race conditions
  by slowing execution timing -- see below)

When NOT to use (or use with caution):
- Race conditions (AC:H): breakpoints on the racing code slow execution enough
  to prevent the race from firing. For race CVEs, let the PoC run blind and
  catch the crash analysis via kd after it fires.

### 4. (User-mode CVEs) Attach via `:8300` for live debugging

For user-mode service CVEs, you don't need a kernel break at all — just
attach CDB to the running process via `:8300`. This is the primary path
for attack-surface discovery (what public API reaches a server-side
function identified by the diff).

```python
import httpx, json
URL = "http://192.168.122.100:8300/mcp/"   # NB trailing slash
H = {"Content-Type":"application/json", "Accept":"application/json, text/event-stream"}

r = httpx.post(URL, headers=H, timeout=10,
    json={"jsonrpc":"2.0","id":1,"method":"initialize",
          "params":{"protocolVersion":"2024-11-05","capabilities":{},
                    "clientInfo":{"name":"poc","version":"1"}}})
S = r.headers["mcp-session-id"]
httpx.post(URL, headers={**H,"mcp-session-id":S}, timeout=10,
    json={"jsonrpc":"2.0","method":"notifications/initialized"})   # required handshake

def call(tool, args, to=60):
    r = httpx.post(URL, headers={**H,"mcp-session-id":S}, timeout=to,
        json={"jsonrpc":"2.0","id":99,"method":"tools/call",
              "params":{"name":tool,"arguments":args}})
    d = json.loads(r.text)   # plain JSON, not SSE
    return d["result"]["content"][0]["text"]

T = "name:SearchIndexer.exe"   # or "pid:1234"
print(call("open_windbg_local", {"target": T}))                      # attaches + halts
print(call("run_windbg_cmd",   {"local_target": T, "command": "bp mssrch!CFoo::bar"}))
print(call("run_windbg_cmd",   {"local_target": T, "command": "bl"}))  # confirm resolved
print(call("run_windbg_cmd",   {"local_target": T, "command": "g"}, to=30))  # runs until bp fires or 30s timeout
print(call("run_windbg_cmd",   {"local_target": T, "command": "k 30"}))   # caller stack
print(call("close_windbg_local", {"target": T}))
```

Note the `:8300` conventions that differ from other MCPs:
- endpoint path is `/mcp/` **with trailing slash**
- responses are plain JSON, **not SSE-framed** (don't strip a `data:` prefix)
- after `initialize`, you MUST send `notifications/initialized` before any
  tool call
- a blocking `g` times out after 30s server-side; if the bp doesn't fire
  naturally within that window, the agent needs to **induce activity**
  typical for the service family (create a file the indexer scans, issue
  a COM call, send an RPC, etc.) or escalate to static-xref analysis

### 5. (Kernel CVEs) Run the PoC under :8100 kernel debug

Deploy and run the PoC on the target. The lab is ready to catch the
BugCheck. When it fires:
1. kd auto-breaks in
2. `-c` commands run: `.load dll; mcpstart; g`
3. Named pipe appears
4. HTTP server starts
5. MCP is live at `http://192.168.122.101:8100/mcp`
6. Target auto-reboots (CrashControl)
7. kd reconnects silently for next run
8. Extension stays loaded (kd never exited)

### 6. Verify MCP endpoints

After the first kernel crash, exercise `:8100`:
```bash
SESSION=$(curl -si -X POST http://192.168.122.101:8100/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"eip","version":"1.0"}}}' \
  | grep mcp-session-id | awk '{print $2}' | tr -d '\r')

curl -s -X POST http://192.168.122.101:8100/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "mcp-session-id: $SESSION" \
  -d '{"jsonrpc":"2.0","method":"tools/call","id":2,"params":{"name":"run_command","arguments":{"command":"!analyze -v"}}}'
```

## Lessons from real runs

- **KDNET connects before kernel network is ready**: The KDNET driver initializes
  very early in boot and sends the initial sync packet before the full TCP/IP
  stack is operational. kd can connect immediately, but a forced break (`-b`)
  requires a two-way handshake the target cannot complete yet. Always use silent
  attach and let breaks happen naturally (BugCheck, exception, etc.).

- **"Connected to target" != break-in**: kd shows this message when KDNET
  handshakes, but the target continues running. No commands execute until
  an actual break occurs.

- **kd.out.log parsing**: Watch for "Connected to target" (KDNET connected) vs
  "Kernel Debugger connection established" (full break-in completed). The latter
  includes the target kernel version, base address, and `0: kd>` prompt.

- **Screenshot for debugging** (KVM): `sudo virsh screenshot <domain> /tmp/out.png`
  captures the VM screen without needing a VNC client. Useful for confirming
  whether the target is running, frozen, or showing a BSOD. Under VMware the
  equivalent is `vmrun -T ws captureScreen <path-to-vmx> /tmp/out.png`, or just
  look at the Workstation console tab.

- **KDNET reconnects automatically after BSOD + reboot**: kd stays running (wrapper
  holds stdin). When the target reboots and sends new KDNET packets, kd.exe
  picks them up and reconnects. The prompt monitor re-injects the extension on
  the next break. MCP comes back online automatically.

- **NtSystemDebugControl(SysDbgBreakPoint=6) for on-demand MCP**: Call from the
  target as local admin (SeDebugPrivilege). The kernel fires `int 3` which kd
  catches over KDNET — safe, uses the kernel debug protocol. Implemented in
  `vm-setup/kd_break.ps1`, invoked by `./setup.sh lab load-mcp`.

- **DO NOT use virsh inject-nmi** (KVM-only footgun): `virsh inject-nmi` sends
  a hardware NMI to the VM. Windows treats hardware NMI as `NMI_HARDWARE_FAILURE`
  (BSOD stop code 0x80) — it is NOT intercepted by the KDNET driver as a debug
  break. Result: target crashes and reboots, losing all state. Use
  `NtSystemDebugControl` (via `./setup.sh lab load-mcp`) instead. No equivalent
  anti-pattern exists under VMware — `vmrun` exposes no NMI injection.

- **DO NOT use kd stdin commands to break a running target**: Sending `.break\n`
  or `\x03` (Ctrl+C) to kd's stdin pipe does nothing when the target is running.
  kd only processes stdin commands at a `kd>` break prompt. The correct way to
  force a break is target-side (`NtSystemDebugControl`) or wait for a natural
  BugCheck.

- **MCP HTTP transport requires specific headers**: The FastMCP streamable-HTTP
  transport rejects requests without `Accept: application/json, text/event-stream`.
  Every request also needs the `mcp-session-id` header from the initialize call.

- **Named pipe check for MCP readiness**: `Test-Path "\\.\pipe\windbgmcp"` on
  the debugger VM is the reliable signal that the extension loaded and mcpstart
  ran. Port 8100 may take a few more seconds after the pipe appears.

- **Race condition CVEs need CPU affinity**: For high-complexity (AC:H) race
  conditions, pin racing threads to different CPU cores using SetThreadAffinityMask.
  This maximizes concurrent execution and narrows the scheduler interference.
  Start with THREADS = 2x CPU count.

- **AC:H does not mean it won't crash**: High attack complexity means the trigger
  requires precise timing, not that it's impossible. Driver Verifier + CPU affinity
  + sustained pressure (minutes not seconds) is usually sufficient.

- **`:8300` (CDB user-mode) — only one debugger per process**: Windows allows
  exactly one debugger attach per user-mode process. If a previous CDB died
  without a clean detach, subsequent attaches fail with "process is already
  being debugged" (or time out at 30s). Kill stale `cdb.exe` processes before
  re-attaching; reset via `close_windbg_local` in the happy path.

- **`:8300` can halt services**: When you attach, the target is frozen at the
  current IP. If the service is a system-critical auto-started one (WSearch,
  Spooler, …), nothing it serves makes progress while you're broken in. Run
  `g` and work via bp-and-capture, not long halts, to avoid cascading service
  death.

- **`:8300` and stale captures**: bp hit counts and captured stacks accrue in
  the CDB session; they don't disappear on `close_windbg_local`. If you
  re-attach for another round, your first `bl` already shows the old bps (per
  session id). If you need a truly clean state, ensure the CDB subprocess is
  fully terminated before reopening.

- **`:8300` needs the notifications/initialized handshake**: Unlike our other
  MCPs (built on FastMCP which does this implicitly), the upstream `mcp`
  Python package requires the client to send `{"jsonrpc":"2.0",
  "method":"notifications/initialized"}` after `initialize` before tool calls
  will dispatch. Without it, `tools/list` works but `tools/call` hangs.

## Reset if something went wrong

```bash
./setup.sh lab reset   # destroy pair, respawn fresh overlays
```

After reset, kd_wrapper.py restarts and waits for the next target reboot to
reconnect. No manual steps needed.

## Start/stop existing labs

```bash
./setup.sh lab start   # start existing target + debugger overlays
./setup.sh lab stop    # guest shutdown target, then debugger; force after grace
```

Use `lab start`/`lab stop` when you want to preserve current overlays. Use
`lab reset` when you want fresh overlays off the gold image. Under VMware,
`lab start` defaults to GUI mode and may auto-open Workstation via
`gtk-launch`; if that fails, open Workstation manually and rerun the command.

## Output: lab_setup_report.md structure

```markdown
# Lab Setup Report: CVE-YYYY-NNNNN

## Environment
- Target:    192.168.122.100  (<build> with KDNET, auto-reboot, DV=<flags>)
- Debugger:  192.168.122.101
- SSH key:   ~/repos/win11-forge/vm-ssh-key

## MCP Endpoints
- WinDbg MCP (debugger kernel):  http://192.168.122.101:8100/mcp   (active after first crash)
- DesktopCommander (target):     http://192.168.122.100:8200/mcp   (active now)
- DesktopCommander (debugger):   http://192.168.122.101:8201/mcp   (active now)
- mcp-windbg (target user-mode): http://192.168.122.100:8300/mcp/  (active now — note trailing slash)

## Verification
- Target SSH: OK
- Debugger SSH: OK
- kd_wrapper running: Yes (pid=XXXX)
- kd connected: Yes (log shows "Connected to target")
- Target DesktopCommander :8200: OK (26 tools)
- Debugger DesktopCommander :8201: OK (26 tools)
- mcp-windbg :8300: OK (9 tools; verified open_windbg_local/close_windbg_local present)
- Driver Verifier: <driver.sys> flags 0x9 (or N/A)
- WinDbg MCP :8100: Pending first crash (or Confirmed, session=XXXX)

## Target Binary State
- <target binary> version X.X.X
- Vulnerable: Yes / No

## Notes
<e.g. DV requires reboot; first crash needed before WinDbg MCP is active>
```

## Sample output

See `lab/<CVE_ID>/lab_setup_report.md`.
