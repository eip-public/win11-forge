---
name: poc-verify
description: Stage 5 of the win11-forge CVE pipeline. Run the PoC from poc-dev end-to-end from a clean VM state, capture definitive evidence (crash dump, WinDbg output, or privilege proof), and verify the impact claim. Triggers: user says "verify the PoC", "confirm it works", "prove the exploit", or pipeline progresses from poc-dev.
---

# poc-verify

**Pipeline stage 5 of 8.** Run the PoC reproducibly from a clean snapshot, capture evidence, verify the stated impact claim, and score reliability. Produces `poc_verification_report.md`.

## Inputs
- `lab/<CVE_ID>/poc/poc.py` (or equivalent)
- `lab/<CVE_ID>/poc-dev.md` - claimed trigger + expected effect
- Lab running (target + debugger pair)

## Outputs
- `lab/<CVE_ID>/poc_verification_report.md`
- `lab/<CVE_ID>/poc/crash_<N>.txt` - WinDbg output per run
- Kernel dump (if applicable): retrieved from target `C:\Windows\MEMORY.DMP`

## Procedure

### 1. Reset to clean state before each run

```bash
cd ~/repos/win11-forge
./setup.sh lab reset   # fresh overlays off gold, ~5min
# Wait for SSH (see lab-setup skill for readiness probes), then deploy PoC
```

Prefer `:8200` over SSH scp for deploy (no quoting pain):

```python
import httpx, json
URL = "http://192.168.122.100:8200/mcp"
# ... initialize as usual ...
write_file(path="C:\\winforge\\poc.py", content=open("lab/<CVE>/poc/poc.py").read())
```

**Always run from a reset state.** Heaps and RPC state from a previous run
can mask or change the bug's behaviour.

### 2. Pick a debugger path, arm it before each run

**Decide by vuln family (same as poc-dev):**

| Vuln family | Debugger | Evidence capture |
|---|---|---|
| **Usermode service crash** | `:8300/mcp/` — attach to service, `sxe av` + `sxe ch`, run PoC, capture `!analyze -v` + `k 30` when broken | Event ID 7031 + epmapper deregistration as corroboration |
| **Kernel BugCheck** | `:8100/mcp` — ensure MCP live via `lab load-mcp` or wait for BugCheck, capture `!analyze -v` + `k 20` + `r` from kd.out.log | Kernel dump at `C:\Windows\MEMORY.DMP` |
| **Usermode silent corruption (UAF w/o immediate crash)** | `:8300` with Page Heap pre-enabled: `gflags /p /enable <proc>.exe /full` then restart service → first UAF fires an instant AV | Page-heap dump + `!analyze -v` |

#### 2a. Usermode (`:8300`) verification flow

```python
import httpx, json
URL = "http://192.168.122.100:8300/mcp/"   # trailing slash
H   = {"Content-Type":"application/json",
       "Accept":"application/json, text/event-stream"}
r = httpx.post(URL, headers=H, timeout=10,
    json={"jsonrpc":"2.0","id":1,"method":"initialize",
          "params":{"protocolVersion":"2024-11-05","capabilities":{},
                    "clientInfo":{"name":"verify","version":"1"}}})
S = r.headers["mcp-session-id"]
httpx.post(URL, headers={**H,"mcp-session-id":S}, timeout=10,
    json={"jsonrpc":"2.0","method":"notifications/initialized"})
def call(tool, args, to=60):
    r = httpx.post(URL, headers={**H,"mcp-session-id":S}, timeout=to,
        json={"jsonrpc":"2.0","id":99,"method":"tools/call",
              "params":{"name":tool,"arguments":args}})
    return json.loads(r.text)["result"]["content"][0]["text"]

T = "name:<service>.exe"
call("open_windbg_local", {"target": T})
# Arm exception handlers FIRST, before any long-running .sympath / .reload or
# `g` that opens a window for unhandled first-chance exceptions to fire. On a
# cold symbol cache, `.reload` downloads PDBs for 30+ seconds — any AV that
# happens in that window hits the default handler and tears down the debuggee.
call("run_windbg_cmd", {"local_target":T, "command":"sxe av"})   # break on access violation
call("run_windbg_cmd", {"local_target":T, "command":"sxe ch"})   # break on heap corruption
# PageHeap / Application Verifier issues a plain int 3 (exception code
# 0x80000003) from verifier!VerifierCaptureContextAndReportStop BEFORE the
# access violation fires. `sxe av` alone will NOT catch it — set a breakpoint
# on the verifier hook too so you capture the full context with heap metadata:
call("run_windbg_cmd", {"local_target":T, "command":
    'bu verifier!VerifierCaptureContextAndReportStop ".echo VERIFIER_STOP ; k 40 ; r"'})
call("run_windbg_cmd", {"local_target":T, "command":"g"}, to=120)   # blocks until AV/HEAP fires

# On break:
crash = call("run_windbg_cmd", {"local_target":T, "command":"!analyze -v"}, to=120)
stack = call("run_windbg_cmd", {"local_target":T, "command":"k 30"})
regs  = call("run_windbg_cmd", {"local_target":T, "command":"r"})
open(f"lab/<CVE>/poc/crash_{run}.txt","w").write(
  f"# Run {run}\n\n## !analyze -v\n{crash}\n\n## Stack\n{stack}\n\n## Regs\n{regs}\n"
)
call("close_windbg_local", {"target": T})
```

**Do NOT restart the service while attached** — it kills the debuggee
mid-break and leaves lab state bad. Detach, restart service, re-attach.

#### 2b. Kernel (`:8100`) verification flow

Ensure `:8100` is live (either PoC will produce the first BugCheck, or run
`./setup.sh lab load-mcp` to bring it up pre-crash). Then:

```python
import httpx, json, pathlib

MCP = "http://192.168.122.101:8100/mcp"
HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",  # required by FastMCP streamable-HTTP
}
RUNS = 5

def get_session() -> str:
    r = httpx.post(MCP, headers=HEADERS, json={
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                   "clientInfo": {"name": "eip-verify", "version": "1.0"}}
    })
    return r.headers["mcp-session-id"]

def cmd(session: str, c: str, timeout: int = 60) -> str:
    r = httpx.post(MCP, headers={**HEADERS, "mcp-session-id": session},
                   json={"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                         "params": {"name": "run_command",
                                    "arguments": {"command": c, "timeout": timeout}}})
    for line in r.text.splitlines():
        if line.startswith("data:"):
            import json
            return json.loads(line[5:].strip()).get("result", {}).get("content", [{}])[0].get("text", "")
    return ""

SESSION = get_session()

# Arm exception capture via kd MCP - kd is already attached to target kernel
cmd(SESSION, "g")                            # ensure target is running
cmd(SESSION, "sxe av")                       # break on access violation
cmd(SESSION, "sxe ch")                       # break on heap corruption
cmd(SESSION, "g")                            # wait for PoC to trigger
```

### 3. Run the PoC and capture output

```bash
ssh -i vm-ssh-key forge@192.168.122.100 'python C:\winforge\poc.py 2>&1'
```

After the PoC fires (or target crashes), dump the debugger state via MCP:
```python
crash_output = cmd(SESSION, "!analyze -v", timeout=120)
stack        = cmd(SESSION, "k 30")
regs         = cmd(SESSION, "r")
pathlib.Path(f"lab/<CVE>/poc/crash_{run}.txt").write_text(
    f"# Run {run}\n\n## !analyze -v\n{crash_output}\n\n## Stack\n{stack}\n\n## Registers\n{regs}\n"
)
```

### 4. Verify the impact claim

| Claimed impact | How to verify |
|---|---|
| DoS / crash | `!analyze -v` shows `CRITICAL_STRUCTURE_CORRUPTION` or heap error; target process (or kernel) restarted |
| Local EoP to SYSTEM | After PoC, run `whoami` or `cmd /c whoami` - expect `nt authority\system` |
| Handle/memory leak | Measure memory or handle count before/after N iterations |
| Information disclosure | Dump leaked bytes; show they contain non-zero kernel/process data |
| RCE | Execute arbitrary command on the target via the exploit |

Check that the claimed `impact` in `intel_brief.md` matches what the PoC actually achieves.

### 5. Score reliability

Run the PoC at least 5 times from clean state. Record:

| Run | Result | Evidence | Notes |
|---|---|---|---|
| 1 | crash | Event ID 7031 / process gone | |
| 2 | crash | ept_s_not_registered | |
| 3 | crash | NOT RUNNING | |
| 4 | crash | Event ID 7031 | |
| 5 | no crash | process still up | |

**Reliability score** = successes / attempts (e.g. 4/5 = 80%).

If reliability < 60%, the trigger is fragile. Note in the report - the PoC is "proof-of-concept only, not production-reliable."

### 5b. Windows event log as hard proof (no debugger needed)

For crash-causing vulnerabilities, Windows Service Control Manager (SCM) logs Event ID 7031 whenever a service crashes:

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; Id=7031} -MaxEvents 10 |
    Where-Object { $_.Message -match '<service_name>' } |
    Select-Object TimeCreated, Message
```

**Event ID 7031 = service terminated unexpectedly** = your trigger caused a crash. This is hard proof without needing CDB at all. Pair it with:
- **Epmapper check**: if the service registered an RPC endpoint and the endpoint vanishes, the service crashed. `epm.hept_map()` raising `ept_s_not_registered` is definitive.
- **Process NOT RUNNING**: `Get-Process <service_process> -EA SilentlyContinue` returning nothing confirms the crash.

### 5c. PID tracking when using page heap

Page heap is applied to processes at launch time. If you restart a service to activate page heap, you MUST get the NEW PID and ensure your debugger (if any) is attached to that PID - not the old one. Always check:

```powershell
& $gflags /p /enable <process>.exe /full
net stop <service>
Start-Sleep 2
net start <service>
Start-Sleep 2
$newPid = (Get-Process <process>).Id
Write-Host "New PID: $newPid"
# Now attach CDB to $newPid, not the old PID
```

### 5d. CDB exception handler race condition

When a page heap guard fires, the process terminates very rapidly. CDB's exception handler commands (`.logclose; q` etc.) may not execute before the process dies, leaving the log incomplete or empty. Mitigations:

- Write a pre-trigger snapshot dump immediately at attach, before `g`: `.dump /ma C:\path\pre_trigger.dmp`
- Use OS-level crash dump collection instead: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\Namespace -> LocalDumps` or WER
- Accept that Event ID 7031 + epmapper check is sufficient proof for DoS, without needing the full CDB analysis log

The WinDbg MCP (when deployed) avoids this race because the session persists independently of the target process lifecycle.

### 6. Validate PoC doesn't work on patched build

Swap to the patched build on target:
```bash
scp -i vm-ssh-key lab/<CVE>/bin-patch-<build>.<ext> \
    forge@192.168.122.100:C:/Windows/System32/<target_binary>
ssh -i vm-ssh-key forge@192.168.122.100 'sc stop <service>; sc start <service>'
```

Run the PoC again. It should **not** crash / should exit cleanly. This confirms the PoC is patch-discriminating, not just a generic crash.

## Python dependency note

Use a project venv - never `pip install` system-wide on Ubuntu/Debian:

```bash
cd lab/<CVE_ID>
python3 -m venv .venv
.venv/bin/pip install impacket
.venv/bin/python poc/poc_rpc.py ...
```

## Kernel CVE verification differs from usermode

For kernel CVEs, the verification evidence comes from the kernel debugger (kd),
not from user-mode tools like page heap or Event ID 7031.

### Crash evidence location

| CVE type | Evidence source | Signal |
|---|---|---|
| Usermode service UAF | Windows event log | Event ID 7031 ("terminated unexpectedly") |
| Usermode RPC | epmapper deregistration | `ept_s_not_registered` |
| Kernel driver UAF/race | kd.out.log on debugger VM | BugCheck code + faulting driver |
| Kernel driver UAF (DV) | kd.out.log | `SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION` |

### Reading kernel crash evidence

After a BugCheck, kd.out.log on the debugger VM contains the full analysis.
Read it via SSH:

```bash
sshpass -p forge123 ssh forge@192.168.122.101 \
  'powershell -Command "Get-Content C:\winforge\logs\kd.out.log | Select-Object -Last 40"'
```

Key fields to extract from `!analyze -v` output:

| Field | Meaning |
|---|---|
| `BUGCHECK_CODE` | The BugCheck type (e.g. `SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION`) |
| `FAULTING_IP` | Instruction that caused the fault |
| `SYMBOL_NAME` | `<driver>+<offset>` - identifies the faulting driver |
| `STACK_TEXT` | Call chain from faulting function back to trigger |
| `Arg1/Arg2/Arg3/Arg4` | Bug-check-specific context (e.g. pool tag, address) |

### MCP is the preferred verification path for kernel CVEs

Once the MCP extension is loaded (after the first crash), use MCP tools for all
subsequent verification rather than reading log files manually:

```python
# Via mcp_session.py after first crash
print(cmd("!analyze -v"))   # full crash analysis
print(cmd("k 20"))          # stack at crash point
print(cmd("r"))             # registers
print(cmd("!pool <addr>"))  # heap state at fault address
```

The MCP session persists across target reboots (kd.exe never exits), so you
can issue analysis commands immediately after each crash without reconnecting.

### Driver Verifier BugCheck codes

When Driver Verifier fires on a UAF or race condition:
- `SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION (0xC1)` - write to freed pool (UAF)
- `DRIVER_VERIFIER_DETECTED_VIOLATION (0xC4)` - pool tag mismatch, double free
- `DRIVER_VERIFIER_DMA_VIOLATION (0xE6)` - DMA constraint violation

The presence of any of these codes, with the target driver in `SYMBOL_NAME`, is
definitive proof that the driver has a memory safety bug triggered by the PoC.

### Reliability measurement for race conditions

For AC:H race conditions, "N/M runs successful" is less meaningful than for
AC:L bugs. Report instead:
- Total race pairs attempted per run
- Duration of each run
- Number of separate runs that produced crashes
- Whether Driver Verifier was active (if yes, note it amplifies the result)

## Output: poc_verification_report.md structure

```markdown
# PoC Verification Report: CVE-YYYY-NNNNN

## Summary
<one-line: "PoC confirmed - triggers heap UAF in <target process> with 80% reliability">

## PoC
- File: poc/poc.py
- Language: Python / C / PowerShell
- Requirements: Local user, Windows 11 24H2

## Test Environment
- Target:    192.168.122.100 (26100.XXXX - pre-patch)
- Debugger:  192.168.122.101
- Gold:      winforge-win11-24h2-gold.qcow2

## Runs
| # | Result | Time | Notes |
|---|---|---|---|
| 1 | CRASH | 0.3s | HEAP_CORRUPTION in `<target process>` |
...

## Impact Verification
- Claimed: Elevation of Privilege to SYSTEM
- Observed: <paste of whoami / crash dump / handle dump>
- Verdict: CONFIRMED / PARTIAL / NOT REPRODUCED

## Patch Discriminator
- Vulnerable build:  CRASHES (confirmed)
- Patched build:     NO CRASH (confirmed)

## Reliability
N/M runs successful (XX%)

## Evidence
- crash_1.txt through crash_N.txt: WinDbg !analyze output
- Kernel dump: <path if captured>

## Notes
<race conditions, timing sensitivity, required heap state, anything an analyst needs to know>
```

## Sample output

See `lab/<CVE_ID>/poc_verification_report.md`.
