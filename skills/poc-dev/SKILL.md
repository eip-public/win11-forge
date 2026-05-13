---
name: poc-dev
description: Stage 4 of the win11-forge CVE pipeline. Using the patch diff and intel brief, write a minimal proof-of-concept that triggers the vulnerability on the target VM. Pick debugger tooling based on vuln family (user-mode service → :8300 mcp-windbg, kernel → :8100 WinDbg MCP). Triggers: user says "write the PoC", "develop an exploit", "try to trigger the bug", or pipeline progresses from diff-analysis / lab-setup to poc-dev.
---

# poc-dev

**Pipeline stage 4 of 8.** Translate the diff analysis into working code that
reliably triggers the vulnerability. Iterate live against the debug-enabled
target using the appropriate MCP. Produces `poc/poc.py` and `poc-dev.md`.

## Inputs
- `lab/<CVE_ID>/intel_brief.md` - attack surface, access requirements
- `lab/<CVE_ID>/diffs/*.ghidriff.md` - the function diff, changed logic
- `lab/<CVE_ID>/lab_setup_report.md` - which MCP endpoints are live
- Lab up with four MCP endpoints (see `skills/lab-setup/SKILL.md`):
  - `http://192.168.122.100:8300/mcp/` — mcp-windbg, user-mode debug (attach, bp, go, step) — trailing slash, plain-JSON
  - `http://192.168.122.101:8100/mcp`   — WinDbg MCP, kernel debug (active after first BugCheck)
  - `http://192.168.122.100:8200/mcp`   — DesktopCommander on target (deploy PoC, run it, read output)
  - `http://192.168.122.101:8201/mcp`   — DesktopCommander on debugger (read kd logs, check state)

## Outputs
- `lab/<CVE_ID>/poc/poc.py` - minimal reproducer (or `.c`, `.ps1`, depending on attack surface)
- `lab/<CVE_ID>/poc-dev.md` - development log: hypotheses tried, breakpoints hit, iteration notes

## Picking your tools by vuln family

Before writing any code, decide which MCPs you'll drive. The choice falls out
of the vuln family (which patch-intel + windows-cve-diff already classified).

| Vuln family | Primary debugger | Attack surface tool | Evidence/verification |
|---|---|---|---|
| **Usermode service EoP/RCE** (spoolsv, mssrch, lsasrv, rpcss, dwm, …) | **:8300 mcp-windbg** — attach to the service, bp on diff-identified symbol, `g`, `k 30` for caller chain | impacket RPC (epmapper bind) **or** ctypes via the public client-side DLL | Event ID 7031, `epmapper` deregistration, `Get-Process` gone, dump at `C:\Windows\MEMORY.DMP` (if Page Heap) |
| **Kernel driver UAF/race** (afd.sys, clfs.sys, csc.sys, win32kfull.sys) | **:8100 WinDbg MCP** — `./setup.sh lab load-mcp` or BugCheck; `bp mod!fn` via `.process /i /r` | `DeviceIoControl` on `\\.\Device` path, or the syscall the driver serves | kd.out.log `!analyze -v`, Driver Verifier `SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION` |
| **Kernel TCP/IP / networking** (tcpip.sys, srv2.sys) | **:8100** | crafted packet from host via scapy; local sockets for some | kd.out.log BugCheck, target auto-reboot |
| **Win32K syscall** (NtGdi*, NtUser*) | **:8100** | ctypes → `NtGdiXxx` / syscall number stub | kd BugCheck |
| **Usermode RCE (file-parse)** (gdiplus, msi, comctl32 consumed via app) | **:8300** attached to the consuming process | drop file + launch viewer via `:8200` start_process | `:8300` catches exception; Event ID 1000 in Application log |
| **Logic / auth bypass** (non-memory-corruption) | **:8300** optional | `:8200` exec of positive + negative test cases | assert observable state diff (tokens, handles, ACLs) |

**Default if you're unsure:** start with `:8300` — live usermode debugging is
the fastest path to "what calls this" regardless of service identity.

## Procedure

### 1. Form a trigger hypothesis from the diff

Read the diff's `Modified` section. For each changed function, ask:
- What input reaches this function? (callers are in `### <func> Calling Diff`)
- What's the new guard the patch adds? That guard failing = the bug condition.
- What observable effect does triggering it have? (crash, handle leak, token swap)

Write the hypothesis as a comment at the top of poc.py before writing any code:
```python
# HYPOTHESIS: Call <vulnerable function> with <specific inputs that exercise Level=N / mode=X>.
# The pre-patch code <does Y with freed/out-of-bounds memory>.
# Expected: crash in <process>.exe heap manager / SYSTEM handle leak / arbitrary write.
```

### 2. Identify the attack interface

The diff names SERVER-SIDE function symbols (what runs inside the vulnerable
process). You almost always have to map those to a CLIENT-FACING interface
(Win32 API, RPC opnum, IOCTL code, syscall number) that an unprivileged
attacker can call.

**Use `:8300` + breakpoints to discover the call chain** (see "Attack-surface
discovery recipe" below). This is faster and more reliable than guessing from
symbol names, especially for service-internal classes (e.g. `CGatherer`,
`CPrintManager`, `CSpoolerServer`) that are never directly CoCreateInstance-able.

| Server-side pattern | Likely client-facing attack interface |
|---|---|
| Service RPC class methods (C++ class impl of a COM dual interface) | Direct RPC via impacket (bind service UUID, call opnum) OR the Win32 wrapper that calls it |
| Kernel driver internal worker | `DeviceIoControl` to the device path (e.g. `\\.\CLFS`, `\\.\AFD`) |
| TCP/IP handler | Raw socket / scapy from host |
| Win32K internal function | `NtGdiXxx` / `NtUserXxx` syscalls, often via `ctypes.windll.win32u` |
| LSASS RPC | Direct RPC via impacket or `ctypes` MSRPC |
| LPC/ALPC | `NtAlpcSendWaitReceivePort` |

### 3. Write the minimal reproducer

Keep the PoC minimal - its only job is to reliably reach the vulnerable code path and cause an observable effect (crash, assertion, log entry). Don't write weaponized primitives yet.

```python
#!/usr/bin/env python3
"""
PoC for CVE-YYYY-NNNNN: <one-line description>
Target: Windows 11 24H2 (26100.XXXX)
Effect: <crash in X / SYSTEM handle leak / etc>
"""
import ctypes, ctypes.wintypes as wt, sys

# Minimal reproducer - trigger only, no exploitation chain
def trigger():
    # ... ctypes calls or subprocess / Win32 API
    pass

if __name__ == "__main__":
    trigger()
    print("[+] trigger fired (check debugger / crash dump)")
```

### 4. Attack-surface discovery recipe (user-mode CVEs)

This is the canonical flow to turn a server-side symbol from the diff into
the client-facing interface you'll call in the PoC.

**Primary MCP: `:8300/mcp/`** (mcp-windbg, CDB-backed user-mode debugger).

```python
import httpx, json, time

URL = "http://192.168.122.100:8300/mcp/"   # NB trailing slash
H   = {"Content-Type":"application/json",
       "Accept":"application/json, text/event-stream"}

# --- session handshake ------------------------------------------------------
r = httpx.post(URL, headers=H, timeout=10,
    json={"jsonrpc":"2.0","id":1,"method":"initialize",
          "params":{"protocolVersion":"2024-11-05","capabilities":{},
                    "clientInfo":{"name":"poc","version":"1"}}})
S = r.headers["mcp-session-id"]
# REQUIRED: unlike our FastMCP-based servers, this one needs the client to
# send 'initialized' before tool calls will dispatch.
httpx.post(URL, headers={**H,"mcp-session-id":S}, timeout=10,
    json={"jsonrpc":"2.0","method":"notifications/initialized"})

def call(tool, args, to=60):
    r = httpx.post(URL, headers={**H,"mcp-session-id":S}, timeout=to,
        json={"jsonrpc":"2.0","id":99,"method":"tools/call",
              "params":{"name":tool,"arguments":args}})
    d = json.loads(r.text)   # plain JSON here, not SSE — do NOT strip 'data:' prefix
    return d["result"]["content"][0]["text"]

# --- attack-surface hunt ----------------------------------------------------
TARGET = "name:SearchIndexer.exe"   # or a spoolsv.exe / lsass.exe / etc.
SYMBOL = "mssrch!CGatherer::OnDataChange"   # from the diff's Modified section

call("open_windbg_local", {"target": TARGET})                                # attach + initial break
call("run_windbg_cmd",    {"local_target": TARGET, "command": f"bp {SYMBOL}"})
print(call("run_windbg_cmd", {"local_target": TARGET, "command": "bl"}))     # confirm resolved

# Run target; 'g' blocks until bp fires or a 30s server-side timeout.
print(call("run_windbg_cmd", {"local_target": TARGET, "command": "g"}, to=35))

# If you see "Breakpoint 0 hit" in the output, capture the caller chain:
print(call("run_windbg_cmd", {"local_target": TARGET, "command": "k 30"}))   # THIS IS THE ANSWER
print(call("run_windbg_cmd", {"local_target": TARGET, "command": "r"}))      # args in RCX/RDX/R8/R9

call("close_windbg_local", {"target": TARGET})   # always clean up
```

The `k 30` output names every caller between your diff symbol and the RPC /
COM / syscall boundary at the top of the stack. Walk from the top: the
first frame inside `KERNELBASE`, `RPCRT4`, `OLEAUT32`, or `combase` is your
attack-surface entry point. The frame in user-mode code above it is the
client-facing API wrapper the attacker calls.

### 4-alt. TypeLib introspection for COM / IDispatch services

Before sinking time into live-bp hunting or Ghidra static xrefs, check
whether the server exposes its surface through a TypeLib. Most
Microsoft-authored COM services register a `*tlb.dll` (search
`C:\Windows\System32\*tlb.dll`, or query the TypeLib GUID from the
Interface registry) that literally enumerates every interface, coclass,
method name, `DispId`, and parameter type. A well-named method whose
identifier tail matches the diff-identified symbol is often a direct
hit (e.g., symbol `C*::put_Foo` ↔ TypeLib `INVOKE_PROPERTYPUT name=Foo`).

Find the TypeLib via the IID we care about:

```powershell
reg query "HKLM\SOFTWARE\Classes\Interface\{<IID>}" /v TypeLib
reg query "HKLM\SOFTWARE\Classes\TypeLib\{<LIBID>}\<VER>\0\win32"
```

Then walk every interface/method via `LoadTypeLibEx` + `ITypeLib::GetTypeInfo` +
`ITypeInfo::GetFuncDesc`. The key fields per function are `invkind`
(`INVOKE_FUNC` / `INVOKE_PROPERTYGET` / `INVOKE_PROPERTYPUT`) and
`memid` — the `DispId` you need to call the method over IDispatch:

```csharp
using System.Runtime.InteropServices.ComTypes;
[DllImport("oleaut32.dll", PreserveSig=false)]
static extern void LoadTypeLibEx(string path, int regkind, out ITypeLib lib);

LoadTypeLibEx(@"C:\Windows\System32\<target>tlb.dll", 0, out var tlb);
for (int i = 0; i < tlb.GetTypeInfoCount(); i++) {
    tlb.GetTypeInfo(i, out var ti);
    tlb.GetDocumentation(i, out var name, out var doc, out var hc, out var hf);
    IntPtr pa; ti.GetTypeAttr(out pa);
    var ta = (TYPEATTR)Marshal.PtrToStructure(pa, typeof(TYPEATTR));
    for (int f = 0; f < ta.cFuncs; f++) {
        IntPtr pf; ti.GetFuncDesc(f, out pf);
        var fd = (FUNCDESC)Marshal.PtrToStructure(pf, typeof(FUNCDESC));
        string[] names = new string[1 + fd.cParams];
        ti.GetNames(fd.memid, names, names.Length, out int cn);
        // names[0] is the method name; fd.memid is the DispId;
        // fd.invkind tells you GET/PUT/FUNC. Log filtered by target name.
        ti.ReleaseFuncDesc(pf);
    }
    ti.ReleaseTypeAttr(pa);
}
```

Run this inside `Add-Type -TypeDefinition` for a one-shot PS tool. Filter
the emitted rows for the diff symbol's trailing identifier — e.g. the
function symbol `CFoo::put_Bar` corresponds to `INVOKE_PROPERTYPUT`
`name=Bar` somewhere in the TypeLib. That interface's IID is your
attack-surface entry; walk up to find the coclass (ProgID lookup in
registry, or enumerate CLSIDs whose `InprocServer32`/`LocalServer32`
matches the service binary) to obtain the CLSID to CoCreate.

For pure-dispatch interfaces (`TKIND_DISPATCH`) you can then call the
method by DispId with `IDispatch::Invoke` (or `Type.InvokeMember` in C#),
without needing a strongly-typed vtable binding.

### 4a. What if the bp never fires?

`g` returns after 30s with no "Breakpoint hit" text? The service isn't
exercising that code path in steady state. Options, in order:

1. **Induce typical activity for the service family.** Use `:8200` to:
   - Spooler: submit a print job via `Add-Printer`/`Out-Printer`
   - Search: touch files in an indexed folder (`$env:USERPROFILE\Documents\*.txt`)
   - WSearch indexer startup: **do NOT bounce WSearch while attached** — stops
     the target permanently. Instead detach, restart the service, re-attach
   - LSASS: trigger an authentication (net use, runas)
   - RPC services: call the suspected opnum from impacket speculatively
2. **Set bp on a known-high-frequency caller.** Walk UP from the diff
   symbol in static Ghidra xrefs, set bp on the closest ancestor that IS
   called during passive operation. Capture its stack. Narrow from there.
3. **Static fallback — Ghidra MCP xref.** If the symbol truly isn't exercised
   at runtime (e.g., only fires on admin-only paths), use the already-loaded
   `lab/<CVE_ID>/ghidra-proj/` project via `mcp__ghidra_headless_mcp__*` tools
   to list xrefs to the symbol, then decompile each caller to find the
   client-facing API. Slower than live-bp but deterministic.
4. **Try a different representative symbol.** If the diff changed 3 functions,
   bp on the one most likely to be called constantly (e.g., `get_X` over
   `put_X`, since reads are usually frequent and writes rare).

### 4b. Deploy the PoC via `:8200` (no SSH quoting)

Once you know the client-facing API, write `lab/<CVE>/poc/poc.py` and push it
to the target:

```python
TARGET_MCP = "http://192.168.122.100:8200/mcp"

# Deploy PoC
with open("lab/<CVE>/poc/poc.py") as f: poc = f.read()
run_tool(TARGET_MCP, "write_file",
         {"path": "C:\\winforge\\poc.py", "content": poc})

# Run and capture output
start = run_tool(TARGET_MCP, "start_process",
                 {"command":"C:\\Python314\\python.exe C:\\winforge\\poc.py",
                  "timeout_ms":30000})
pid = parse_pid(start)   # "Process started with PID <n>"
output = run_tool(TARGET_MCP, "read_process_output",
                  {"pid": pid, "timeout_ms":30000})
```

(Fallback via SSH exists but involves quoting pain; prefer DC.)

### 4c. Watch the bp fire as the PoC runs

With your PoC crafted, keep the `:8300` session live in one terminal, run the
PoC via `:8200` in another. When the bp fires on your crafted call, `k 30`
proves you reached the vulnerable code — trigger confirmed.

```python
# Session A (holds attach + bp)
call("run_windbg_cmd", {"local_target": TARGET, "command": "g"}, to=60)

# Session B (triggers the PoC via :8200)
# ... start_process python C:\winforge\poc.py ...

# Session A returns with the bp-hit stack
print(call("run_windbg_cmd", {"local_target": TARGET, "command": "k 30"}))
print(call("run_windbg_cmd", {"local_target": TARGET, "command": "r"}))
print(call("run_windbg_cmd", {"local_target": TARGET, "command": "dc rcx L20"}))
```

### 4d. Kernel-mode CVEs: use `:8100` instead of `:8300`

For driver UAF/race or syscall bugs (`afd.sys`, `clfs.sys`, `win32kfull.sys`,
…), `:8300` can't help — it's user-mode only. Use the kernel MCP flow:

1. `./setup.sh lab load-mcp` to bring `:8100` online before the first
   BugCheck (see `skills/lab-setup/SKILL.md` for `load-mcp` details).
2. `bp mod!fn` via `run_command`, with the `.process /i /r <eproc>` dance
   if you need a user-mode-process bp inside the kernel context.
3. Run the PoC; the BugCheck auto-breaks kd and triggers `!analyze -v`.

Sample kd MCP call pattern:

```python
import httpx, json

MCP = "http://192.168.122.101:8100/mcp"   # no trailing slash; FastMCP SSE
H = {"Content-Type":"application/json",
     "Accept":"application/json, text/event-stream"}

def get_session():
    r = httpx.post(MCP, headers=H, json={
        "jsonrpc":"2.0","id":1,"method":"initialize",
        "params":{"protocolVersion":"2024-11-05","capabilities":{},
                  "clientInfo":{"name":"poc","version":"1"}}})
    return r.headers["mcp-session-id"]

def run_cmd(S, cmd):
    r = httpx.post(MCP, headers={**H,"mcp-session-id":S}, timeout=60,
        json={"jsonrpc":"2.0","id":1,"method":"tools/call",
              "params":{"name":"run_command","arguments":{"command":cmd}}})
    for line in r.text.splitlines():        # this one IS SSE-wrapped
        if line.startswith("data:"):
            d = json.loads(line[5:].strip())
            return d.get("result",{}).get("content",[{}])[0].get("text","")
    return ""

S = get_session()
run_cmd(S, "bp mod!fn")
# run PoC, wait for BugCheck
print(run_cmd(S, "!analyze -v"))
print(run_cmd(S, "k 20"))
print(run_cmd(S, "r"))
print(run_cmd(S, "dc rcx"))
```

### 4e. Before writing ctypes code — verify the client-side export exists

The diff shows SERVER-SIDE function names. These are often NOT the same as the public Win32 API. Before writing ctypes code, confirm the export exists:

```python
import ctypes
dll = ctypes.WinDLL("target.dll", use_last_error=True)
try:
    fn = dll.FunctionNameW
    print("found:", fn)
except AttributeError:
    print("NOT EXPORTED - find the public API that routes to this server function")
```

If the function isn't exported, you need one of:
- A higher-level public API that marshals to the vulnerable server function (the diff names are server-side; trace up the call chain to find what calls them from the client side)
- Direct RPC via **impacket** if the vulnerable method is exposed as an RPC opnum
- A different code path (COM interface, file format trigger, ioctl)

**For RPC-exposed vulnerabilities**, use impacket rather than a guessed ctypes winspool call:

```python
from impacket.dcerpc.v5 import transport, epm

# INTERFACE_UUID = the service's RPC interface UUID (from the protocol spec or Wireshark)
INTERFACE_UUID = uuidtup_to_bin(("XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX", "1.0"))

# 1. Discover dynamic endpoint via epmapper (works even when \pipe\X is blocked by
#    Windows SMB firewall rules - epmapper is accessible regardless)
binding = epm.hept_map(target_ip, INTERFACE_UUID, protocol='ncacn_ip_tcp')

# 2. Connect with NTLM auth
rpctransport = transport.DCERPCTransportFactory(binding)
rpctransport.set_credentials(username, password, domain)
dce = rpctransport.get_dce_rpc()
dce.set_auth_level(6)   # RPC_C_AUTHN_LEVEL_PKT_PRIVACY
dce.connect()
dce.bind(INTERFACE_UUID)
```

**Named pipe not accessible?** The Windows firewall profile may be fully disabled, but individual SMB-related inbound rules (which control `\pipe\*` access) can remain disabled independently. The dynamic TCP endpoint via epmapper always works - prefer it over named-pipe transport for reliability.

**NDRUNION fields**: when building NDR union structures, always set the `tag` field before the union member, or impacket raises a `KeyError`:
```python
container['ClientInfo']['tag'] = 2       # must come first
container['ClientInfo']['pNotUsed1'] = ptr  # then the union arm
```

### 5. Iterate

Common failure modes and responses:

| Symptom | Likely cause | Fix |
|---|---|---|
| Breakpoint never fires | Wrong function name, wrong process | `!process 0 0 <target>.exe` + `bp <module>+<offset>` |
| Access violation in wrong location | Trigger reached wrong code path | Add intermediate breakpoints to trace |
| Exception immediately on PoC start | Missing COM init or wrong calling convention | Check target's expected input format |
| Target reboots (BSOD) before bp | Kernel crash triggered too early | Kernel dump auto-saved at `C:\Windows\MEMORY.DMP` on target - retrieve it |
| PoC exits cleanly with no effect | Patch is active (feature flag) | Try older build, or check if feature flag `Feature_NNNNN` is controllable |

For each iteration, append to `poc-dev.md`:
```markdown
## Iteration N - <date>
**Hypothesis:** ...
**Breakpoint:** bp `<module>!<function>`
**Result:** hit / not hit
**Stack at hit:** <paste>
**Next action:** ...
```

### 6. Confirm the vulnerability is triggered

Minimum confirmation:
- Breakpoint in the VULNERABLE code path fires (pre-patch code reached)
- Observable side effect: crash (`!analyze -v` on kernel dump shows heap corruption or UAF), or controlled handle/pointer at a predictable offset

Write the trigger in its cleanest form for `poc.py`. Document the exact effect.

## Output: poc-dev.md structure

```markdown
# PoC Development Log: CVE-YYYY-NNNNN

## Hypothesis
<from the diff - what you expect to happen>

## Attack Interface
<which API / RPC / syscall / ioctl>

## PoC Location
poc/poc.py

## Iterations
### Iteration 1
...

## Final State
- Trigger: **confirmed** / in-progress
- Effect: <crash in X at Y / handle leak / etc>
- Reliability: X/10 runs
```

## Lessons from real runs

### Kernel crash evidence comes from kd.out.log, not Event ID 7031

For kernel CVEs, the crash evidence is in the kd.out.log on the debugger VM, not
the Windows System event log. kd.out.log contains the full BugCheck analysis:
bug check code, faulting driver, stack trace, and `!analyze -v` output.

Event ID 7031 ("service terminated unexpectedly") only applies to user-mode service
crashes. For kernel crashes, look for:
- BugCheck code (e.g. `DRIVER_VERIFIER_DETECTED_VIOLATION 0x000000C4`)
- Faulting driver (`SYMBOL_NAME: <driver>+<offset>`)
- Crash stack (`STACK_TEXT: <frames>`)

### Driver Verifier converts silent heap corruption to reliable crashes

For UAF and race condition CVEs (CWE-416, CWE-362), heap corruption is often
silent - the freed memory gets reallocated and overwritten without visible
effects for seconds or minutes. Driver Verifier with Special Pool places a guard
page after every allocation. Any write into freed memory hits the guard page
immediately, triggering an instant BugCheck.

Enable before running the PoC:
```powershell
# On target VM
verifier /flags 0x9 /driver <target_driver.sys>
# 0x1=Special Pool, 0x8=Pool Tracking - effective at next reboot
shutdown /r /t 3 /f
```

Without Driver Verifier, a UAF PoC may need hundreds of attempts before the
corruption manifests as a visible crash. With it, the first successful race
often crashes within seconds.

### Race conditions (AC:H) require sustained pressure and CPU affinity

A high-complexity race condition will not crash on the first attempt. The race
window may be nanoseconds wide. To trigger reliably:

1. **CPU affinity**: Pin each racing thread to a different physical core using
   `SetThreadAffinityMask`. This maximizes concurrent execution by preventing
   the scheduler from serializing threads on the same core.

2. **High thread count**: Use 2x or 4x the number of available CPUs. More threads
   = more concurrent attempts per second.

3. **Sustained duration**: Run for minutes, not seconds. AC:H means the race
   will eventually fire, not that it won't fire.

4. **Combine with Driver Verifier**: Driver Verifier makes the first successful
   race immediately visible instead of silently corrupting memory.

Example pattern for a race condition PoC:
```python
import ctypes, threading, time, os

kernel32 = ctypes.WinDLL("kernel32")

def set_affinity(cpu_id):
    mask = 1 << (cpu_id % os.cpu_count())
    kernel32.SetThreadAffinityMask(kernel32.GetCurrentThread(), mask)

def race_pair(tid, end_time):
    set_affinity(tid)
    while time.monotonic() < end_time:
        # Thread A: create object
        # Thread B: immediately close/free it
        # -> race in refcount management
        pass

threads = [threading.Thread(target=race_pair, args=(i, time.monotonic()+120))
           for i in range(16)]
for t in threads: t.start()
for t in threads: t.join()
```

**PowerShell equivalent (stock Windows, no modules required).** Windows 11
LTSC ships with PS 5.1 which does NOT include the `ThreadJob` module, so
`Start-ThreadJob` is unavailable. Use `[runspacefactory]` directly — it's
built into `System.Management.Automation` and gives true OS threads inside
one `powershell.exe` process:

```powershell
$worker = {
    param([int]$tid, [int]$dur)
    # Thread A or B logic here (e.g. COM call, DeviceIoControl, etc.)
}
$pool = [runspacefactory]::CreateRunspacePool(1, 16)
$pool.ApartmentState = 'MTA'    # required for COM calls from multiple threads
$pool.Open()
$handles = 0..15 | ForEach-Object {
    $ps = [powershell]::Create(); $ps.RunspacePool = $pool
    [void]$ps.AddScript($worker).AddArgument($_).AddArgument(120)
    @{ps=$ps; handle=$ps.BeginInvoke()}
}
foreach ($h in $handles) {
    try { $h.ps.EndInvoke($h.handle) } finally { $h.ps.Dispose() }
}
$pool.Close()
```

Each runspace is a real thread with its own COM apartment — the `MTA`
setting is load-bearing for multi-threaded COM races. Use this when the
PoC must run on stock Windows without any `pip install`.

### MCP availability by lifecycle

| Endpoint | Live after | Notes |
|---|---|---|
| `:8200` DC-target      | `lab spawn` | Always available for PoC deploy/run |
| `:8201` DC-debugger    | `lab spawn` | Always available for reading kd logs |
| `:8300` mcp-windbg     | `lab spawn` | Always available for user-mode attach. One debugger per target process. |
| `:8100` WinDbg kernel  | first BugCheck **or** `./setup.sh lab load-mcp` | `load-mcp` fires `NtSystemDebugControl(SysDbgBreakPoint=6)` → kernel `int 3` → kd catches → pipe + HTTP come up in 15s–3min. Extension persists across target reboots. |

### Screenshot for live VM debugging

Instead of connecting a VNC client, capture the VM screen from the host:

```bash
sudo virsh screenshot <domain_name> /tmp/screenshot.png      # KVM
vmrun -T ws captureScreen <path-to-vmx> /tmp/screenshot.png  # VMware
```

Useful for confirming whether the target is running (Windows desktop), crashed
(BSOD blue screen), or frozen in early boot (black screen). Under VMware, the
Workstation console tab shows the same thing live.

### :8300 mcp-windbg gotchas (CDB-backed)

- **Endpoint path is `/mcp/` with trailing slash** (307 redirect from `/mcp`).
- **Responses are plain JSON**, not SSE-wrapped. Do NOT strip a `data:` prefix.
- **`notifications/initialized` is mandatory** after `initialize` — without it,
  `tools/list` works but `tools/call` hangs.
- **One debugger per process** — Windows rule. If attach fails with "already
  being debugged", a stale CDB is still holding the attach. Kill `cdb.exe`
  on target before retrying; in the happy path `close_windbg_local` handles
  cleanup.
- **Do not restart the target service while attached** — `Restart-Service
  WSearch -Force` with CDB attached kills the debuggee mid-break and the
  lab needs state reset. If you need fresh state, `close_windbg_local` FIRST,
  then restart the service, then re-attach.
- **`g` blocks up to 30s server-side**; subsequent tool calls queue behind
  it until CDB returns to prompt (either on bp hit or timeout). If you need
  to break earlier, use `send_ctrl_break` from another MCP session.
- **bp hit counts persist in the CDB session** — stale entries from a prior
  cycle can confuse diagnosis. Use `bp_captures_clear` equivalents (`bc *`
  via `run_windbg_cmd`) when iterating.

## Sample output

See `lab/<CVE_ID>/poc/poc.py` and `lab/<CVE_ID>/poc-dev.md`.
