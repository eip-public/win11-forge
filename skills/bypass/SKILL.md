---
name: bypass
description: Stage 6 of the win11-forge CVE pipeline. Analyze mitigations on the target that stand between the confirmed bug trigger and reliable exploitation — CFG, ASLR/KASLR, sandboxing, ACG, SEHOP — and identify bypass approaches. Only run when poc-verify produced a confirmed crash and the next goal is a reliable exploit chain. Triggers: user says "bypass CFG", "get ASLR leak", "bypass the sandbox", "next step after crash confirmed".
---

# bypass

**Pipeline stage 6 of 8 (often skipped for basic PoC delivery).** Analyse mitigations between a confirmed memory-corruption primitive and reliable code execution or privilege gain. Produces `bypass_analysis.md`.

## When to skip this stage

Skip bypass if:
- The confirmed PoC already achieves the stated impact (e.g. EoP to SYSTEM is proven) — go directly to qa-check.
- The goal is "prove the crash" (DoS / CVE triage), not "achieve code execution."
- The CWE is informational (auth bypass, info disclosure) — no memory corruption to exploit.

Run bypass if:
- poc-verify confirmed a crash with arbitrary write / PC control but exploit reliability is < 60%.
- The target has CFG, ACG, or sandbox that prevents direct shellcode.
- A kernel vulnerability needs KASLR bypass before payload delivery.

## Inputs
- `lab/<CVE_ID>/poc_verification_report.md` — confirmed crash + what primitive was obtained
- `lab/<CVE_ID>/poc/poc.py` — current working PoC
- Lab running (target + debugger)

## Outputs
- `lab/<CVE_ID>/poc/bypass_poc.py` — enhanced PoC with mitigation bypasses
- `lab/<CVE_ID>/bypass_analysis.md`

## Procedure

### 1. Enumerate mitigations on the target binary

For **user-mode targets**, use `:8300/mcp/` — attach, then query
DllCharacteristics directly via `run_windbg_cmd`:

```python
T = "name:<target>.exe"
call("open_windbg_local", {"target": T})
print(call("run_windbg_cmd", {"local_target":T, "command":"!dh <target_module> -f"}))
# ProcessMitigationPolicy via WinDbg:
print(call("run_windbg_cmd", {"local_target":T, "command":"!peb"}))
```

For **kernel targets**, use `:8100/mcp` (kernel MCP, post-BugCheck or via
`lab load-mcp`):

```python
cmd("!dh <target_module> -f")    # ASLR, DEP, CFG, NX flags
cmd("!process 0 0 <target>.exe")  # get EPROCESS, PID
cmd(".process /p /r <eprocess>")  # switch context
cmd("!process <PID> 0")           # flags, ACG, ChildImagePolicy
```

Non-debugger mitigation queries via `:8200` (DC MCP on target) without SSH
quoting pain:

```python
start = dc_call("start_process", {"command":
    "powershell -NoProfile -Command \"Get-Process <target> | "
    "ForEach-Object { Get-ProcessMitigation -Id $_.Id } | Format-List\""})
# ... read_process_output, parse ...
```

Avoid the legacy `ssh | powershell | python -c` nested-quoting pattern —
use DC MCP start_process / write_file + start_process instead.

Standard mitigation checklist for Windows usermode:

| Mitigation | Check | Impact |
|---|---|---|
| ASLR | `!dh <module> -f` → DYNAMIC_BASE | Module base randomised each boot |
| KASLR | Kernel addresses in WinDbg vs boot-to-boot | Kernel pool addresses change per boot |
| CFG | `!dh <module> -f` → CF_Guard | Indirect calls validated against bitmap |
| ACG (Code Integrity Guard) | `NtQueryInformationProcess` ProcessMitigationPolicy | No JIT, no RWX pages |
| SEHOP | Enabled by default on Windows ≥ Vista | SEH chain integrity; bypass via overwrite target |
| Sandbox | Process with lowbox token | Restricted API access, no network/file write |
| VBS/HVCI | `bcdedit /enum` on target | Kernel code must be signed; no unsigned driver injection |

### 2. Identify the primitive from the crash

From `poc_verification_report.md` and crash dumps, classify the primitive:

| Crash signature | Primitive |
|---|---|
| WRITE_AV at controlled address | Arbitrary write (where-write-what) |
| READ_AV at controlled address | Arbitrary read (info leak) |
| PC/RIP = junk | Arbitrary code execution (no CFG) |
| Heap corruption detection | Write primitive; need heap shaping |
| BSOD CRITICAL_STRUCTURE_CORRUPTION | Kernel write; KASLR determines target |
| Handle confusion | Logic primitive → type confusion for further read/write |

### 3. Derive bypass strategy

**ASLR bypass** (for usermode, arbitrary write at computed address):
- Find a leak: format string, OOB read, handle reveal, NTDLL offset from SEH pointer
- Use leaked module base to compute target offset
- Common: `NtQuerySystemInformation(SystemModuleInformation)` leaks ntoskrnl base for local attackers (privilege-gated)

**CFG bypass**:
- Corrupt a non-CFG-guarded indirect call (vtable in non-CFG module, function pointer in data section)
- Use a write-what-where to overwrite a CFG-bitmap bit → whitelist target address
- Use a direct call (not indirect) path to reach shellcode — e.g. via `RtlDispatchException` chain with fake CONTEXT

**KASLR bypass**:
- `NtQuerySystemInformation(SystemModuleInformation)` → returns ntoskrnl base for users in `SeDebugPrivilege` (admin-equivalent only)
- Timing sidechannel (speculative execution) — complex
- Known-static pattern scan from MZ header via arbitrary read of kernel memory

**Kernel pool heap shaping** (UAF-to-primitives):
- Spray controlled objects at the free slot's address via `AllocateUserPhysicalPages`, large pool objects, or named pipe buffer spray
- Use `NtQuerySystemInformation` (read-primitive) to find controlled slot
- Standard nt!KTHREAD / nt!EPROCESS structure offset exploitation for token swap

### 4. Implement bypass in bypass_poc.py

Start from `poc.py`, layer the bypass:
1. Leak phase → obtain addresses/offsets
2. Shaping phase → place controlled data at target memory
3. Trigger phase → fire the original vulnerability
4. Post-trigger phase → land execution / complete token swap

Test each phase independently before combining.

### 5. Verify end-to-end

```bash
ssh -i vm-ssh-key forge@192.168.122.100 \
  'python C:\winforge\bypass_poc.py && whoami'
```

Expected output for EoP: `nt authority\system`

## Output: bypass_analysis.md structure

```markdown
# Bypass Analysis: CVE-YYYY-NNNNN

## Confirmed Primitive
<from poc_verification_report — e.g. "arbitrary write via UAF in `<process>` heap at offset +0xXX">

## Mitigations on Target
- ASLR: Yes/No
- KASLR: Yes/No
- CFG: Yes/No on `<target module>`
- ACG: Yes/No
- Sandbox: Yes/No

## Bypass Approach
1. **KASLR** → `<leak method>` (e.g. NtQuerySystemInformation — permitted from low-integrity, returns base addresses)
2. **CFG** → `<bypass approach>` (e.g. non-CFG function pointer in `<module>` data section at discovered base + 0xXXXX)

## Reliability after bypass
N/M runs successful (XX%)

## PoC file
poc/bypass_poc.py
```

## Sample output

See `lab/<CVE_ID>/bypass_analysis.md`.
