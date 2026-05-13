---
name: report
description: Stage 8 of the win11-forge CVE pipeline. Generate the final disclosure-style technical report from all prior stage artifacts. The report is the deliverable — a structured markdown document covering timeline, root cause, PoC, impact, and remediation, ready for internal use, coordinated disclosure, or bug bounty submission. Triggers: user says "write the report", "generate disclosure", "finalize the CVE", or pipeline reaches stage 8.
---

# report

**Pipeline stage 8 of 8.** Synthesise all prior artifacts into a professional technical report. Produces `disclosure.md`.

## Inputs
All artifacts from `lab/<CVE_ID>/`:
- `intel_brief.md`
- `diffs/*.ghidriff.md`
- `poc/poc.py` (or `bypass_poc.py`)
- `poc_verification_report.md`
- `bypass_analysis.md` (if exists)
- `qa-check.md` (must be PASS before reporting)

**Do not write this report if `qa-check.md` is FAIL.** Fix the failing check first.

## Outputs
- `lab/<CVE_ID>/disclosure.md` — final report
- `lab/<CVE_ID>/README.md` — quick-reference card (optional, for internal tracking)

## Procedure

### 1. Check QA gate passed

```bash
# Anchor to the exact Summary heading; grep the whole file for PASS (case-
# insensitive). `head -3` was fragile — the PASS token often lands on line 4+
# as the first sentence of the summary paragraph.
grep -q "^## Summary" lab/<CVE_ID>/qa-check.md && \
  grep -qi PASS lab/<CVE_ID>/qa-check.md || echo "QA not PASS — cannot report"
```

### 2. Draft the disclosure.md

The report follows a standard vulnerability disclosure format. Write it by pulling from each artifact:

```markdown
# CVE-YYYY-NNNNN: <cveTitle>

## Executive Summary

<Two sentences: what the vulnerability is, what an attacker achieves, on which Windows versions.>

**CVSS:** X.X (HIGH/CRITICAL) · `<vectorString>`
**CWE:** <CWE-NNN: Name>
**Affected:** Windows 11 24H2 (10.0.26100.XXXX and earlier)
**Patched:** April 2026 Patch Tuesday (10.0.26100.XXXX)
**Status:** <confirmed exploitable / PoC demonstrated / unreliable>

---

## Vulnerability Details

### Description

<Full technical description of the root cause. Reference the specific function and what it does wrong. Source: diffs/*.ghidriff.md Modified section + intel_brief.md.>

Example:
> `<function>` in `<binary>` (<component>) contains a use-after-free vulnerability.
> When called with `<specific inputs>`, the function calls `<helper>`, which frees
> the `<allocation>` on error. The pre-patch code then writes `<value>` into the freed
> allocation at `+0x<offset>`, creating a dangling pointer.

### Root Cause

<Technical explanation referencing the specific CWE. Explain what the code should have done vs. what it did. Include key decompiled snippet from the diff if it clarifies.>

```c
// Vulnerable (<binary>-<build_vuln>):
<helper_function>(...);
*(<freed_ptr> + 0x<offset>) = <value>;  // BUG: write into freed allocation
return result;

// Patched (<binary>-<build_patch>):
// Added: <identity/bounds/validation check>; write zeroed or skipped on error
if (<guard_condition>) { *slot = 0; return result; }
```

### Affected Versions

| Windows Edition | Build range | Status |
|---|---|---|
| Windows 11 24H2 | 10.0.XXXXX.NNNN and earlier | Vulnerable |
| Windows 11 24H2 | 10.0.XXXXX.MMMM and later | Patched |

*(Expand with other editions based on MSRC `affectedProducts` data.)*

### Attack Scenario

<Who can trigger it, from where, with what access. Match to CVSS vector.>

Example:
> An attacker with a standard local user account can call `<interface>` via `<API/RPC>`.
> No elevated privileges are required. The vulnerability is triggered by a single
> `<call type>` with `<specific parameters>` — no timing constraints, no user interaction.

---

## Proof of Concept

### Environment

- Target: Windows 11 24H2, build 10.0.26100.XXXX
- Test type: local; standard user account `forge`
- Debugger: kd.exe via kernel serial debug

### PoC Code

See `poc/poc.py`.

```python
# Key excerpt (full PoC in poc/poc.py)
<paste the 10-20 most relevant lines>
```

### Evidence

**Crash output (run 1):**
```
<paste from poc/crash_1.txt — key lines from !analyze -v>
```

**Impact demonstration:**
```
<whoami output / crash dump excerpt / handle proof>
```

**Reliability:** N/M runs from clean snapshot (XX%)

**Patch discriminator:** PoC fails cleanly against the patched build (verified).

---

## Patch Analysis

<Summary of what Microsoft changed. Source: diffs/*.ghidriff.md.>

The patch modified `<N> functions` with code changes and added `<M> new functions` (typically WIL feature-gate helpers if Microsoft uses staged rollout). Key changes:
- Added `<new guard/check>` to validate `<invariant>` before the vulnerable write.
- If WIL feature flag present (`Feature_NNNNNNNN`): fix is gated for staged rollout — note which builds have the flag enabled.

The patch was identified by binary-diffing `<binary>` builds `<vuln_build>` (vulnerable) and `<patch_build>` (patched) using ghidriff. `<N>` functions had code changes out of `<total>` total.

---

## Impact

<What a successful attacker achieves. Match to CVSS impact scores (C/I/A).>

A successful exploit:
- Corrupts heap state in `<process>` running as `<service account>`
- With sufficient heap shaping, allows `<primitive>` within the process
- Expected escalation path: `<token impersonation / handle theft / code execution / etc.>`

**Confirmed in testing:** <paste impact from poc_verification_report.md>

---

## Remediation

### Immediate

Apply the relevant cumulative update (KB XXXXXXX — see MSRC advisory for your edition).

### Workaround (if patching not immediately possible)

- If the vulnerable service/feature is not required: `sc stop <service>; sc config <service> start= disabled`
- Restrict access to the vulnerable RPC endpoint or network surface via firewall rules

---

## Timeline

| Date | Event |
|---|---|
| 2026-04-14 | Microsoft Patch Tuesday — CVE-YYYY-NNNNN disclosed and patched |
| <your date> | Binary diff identified modified functions in `<binary>` |
| <your date> | PoC confirmed; impact verified |
| <your date> | This report |

---

## References

- [MSRC Advisory](https://msrc.microsoft.com/update-guide/vulnerability/CVE-YYYY-NNNNN)
- [MITRE](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-YYYY-NNNNN)
- [CWE-416: Use After Free](https://cwe.mitre.org/data/definitions/416.html)
- ghidriff diff: `diffs/<binary>-vuln-...-<binary>-patch-....ghidriff.md`
```

### 3. Write README.md (internal tracking card)

```markdown
# CVE-YYYY-NNNNN — <cveTitle>

| Field | Value |
|---|---|
| Status | confirmed / in-progress |
| CVSS | X.X HIGH |
| Component | `<binary>` (`<component>`) |
| Vuln build | 26100.XXXX |
| Patch build | 26100.XXXX |
| PoC | poc/poc.py |
| Reliability | XX% |
| Gold required | winforge-win11-24h2-gold.qcow2 |
| Report | disclosure.md |
```

### 3b. Be honest about what's confirmed vs theoretical

A report written before actual testing is a hypothesis document, not a disclosure. Clearly distinguish:

| State | Correct wording |
|---|---|
| Crash confirmed by event log | "Denial of Service confirmed — Event ID 7031 × N" |
| Crash confirmed by event log, not exploitation | "DoS confirmed; EoP chain pending heap shaping" |
| Crash not yet triggered | "Hypothesis: UAF write in X; trigger not yet validated" |
| Exploit chain complete | "EoP to SYSTEM confirmed — see poc_verification_report.md" |

Never write "confirmed" in the report unless `poc_verification_report.md` says CONFIRMED for that specific claim. If verification is incomplete, the Status line in the executive summary should say "DoS confirmed; EoP pending" or "trigger confirmed, exploitation chain not yet demonstrated" — not a flat "confirmed exploitable".

### 4. Self-review before finalising

- [ ] Executive summary is < 3 sentences, non-jargon first sentence
- [ ] Root cause section explains the WHY not just the what
- [ ] PoC code excerpt is the cleanest version, no debug noise
- [ ] Patch analysis references the diff output directly (function names, line counts)
- [ ] Impact is precise: "SYSTEM privileges" not "may allow privilege escalation"
- [ ] All file paths in the report are relative to `lab/<CVE>/`
- [ ] Timeline is filled in with real dates

## Sample output

See `lab/<CVE_ID>/disclosure.md`.
