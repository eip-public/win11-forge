---
name: qa-check
description: Stage 7 of the win11-forge CVE pipeline. Verify that all prior stage artifacts are present, consistent, and accurate before generating the final report. Run reproducibility tests, cross-check claims against evidence, confirm patch discriminator. Triggers: user says "QA check", "validate the pipeline", "check before report", or pipeline reaches stage 7.
---

# qa-check

**Pipeline stage 7 of 8.** Gate check before the final report. Verifies artifact completeness, claim consistency, reproducibility, and patch discrimination. Produces `qa-check.md` with pass/fail per criterion.

## Inputs
All prior stage artifacts in `lab/<CVE_ID>/`:
- `intel_brief.md`
- `diffs/*.ghidriff.md`
- `lab_setup_report.md`
- `poc/poc.py` (or `bypass_poc.py`)
- `poc_verification_report.md`
- `bypass_analysis.md` (if applicable)

## Outputs
- `lab/<CVE_ID>/qa-check.md` — pass/fail gate report

## Procedure

Run each check programmatically where possible; document result.

### 1. Artifact completeness

```python
import pathlib, sys

CVE = "CVE-YYYY-NNNNN"
base = pathlib.Path(f"lab/{CVE}")
required = [
    "intel_brief.md",
    "diffs",           # directory
    "poc/poc.py",
    "poc_verification_report.md",
]
missing = [r for r in required if not (base / r).exists()]
if missing:
    print(f"FAIL — missing: {missing}")
    sys.exit(1)
print("PASS — all artifacts present")
```

### 2. Claim consistency cross-check

Read `intel_brief.md` and `poc_verification_report.md` and verify these match:

| From intel_brief | From poc_verification_report | Must match |
|---|---|---|
| Affected versions | Test environment build | Build in scope |
| Impact (EoP → SYSTEM) | Observed impact | Exact match |
| CWE class | Crash signature | UAF ↔ heap corruption, etc. |
| Attack vector (AV:L) | PoC runs locally | Consistent |

Flag any discrepancy as a warning.

### 3. Reproducibility from clean state

Re-run the PoC from a fresh VM reset:

```bash
cd ~/repos/win11-forge
./setup.sh lab reset   # fresh overlays (~5 min)
sleep 30  # wait for SSH
scp -i vm-ssh-key lab/<CVE>/poc/poc.py forge@192.168.122.100:C:/winforge/poc.py
ssh -i vm-ssh-key forge@192.168.122.100 'python C:\winforge\poc.py'
```

Score: if it triggers on 3/3 clean runs → PASS. 2/3 → WARN (note fragility). 0/3 → FAIL.

### 4. Patch discriminator

Deploy the patched binary to the target and re-run:

```bash
scp -i vm-ssh-key lab/<CVE>/bin-patch-*.<ext> forge@192.168.122.100:C:/Windows/System32/<target_binary>
ssh -i vm-ssh-key forge@192.168.122.100 'sc stop <service>; sc start <service>; python C:\winforge\poc.py'
```

Expected: PoC exits cleanly / no crash / no impact.

If the PoC still works on the patched binary: either the wrong binary was patched, the feature flag is not yet enabled on this build, or the PoC is not patch-discriminating (FAIL — do not report as confirmed).

### 5. PoC code review

Quick sanity checks on `poc.py`:

- [ ] No hardcoded addresses (ASLR-sensitive) without a leak phase
- [ ] No dependency on specific heap state from a prior run (should work from cold state)
- [ ] No imports from external URLs or volatile packages (`pip install x` at runtime)
- [ ] Comment explains the trigger mechanism — another engineer can read it without diffs
- [ ] Exit code 0 on success, non-zero on failure

### 6. Diff quality check

From `diffs/*.ghidriff.md`, confirm:

- `matched_funcs_with_code_changes_len` ≤ 10 (clean diff, not noise)
- The modified functions named match what `poc-dev.md` says was targeted
- The diff reasoning in `intel_brief.md` matches what the functions actually do

If the diff showed 0 changes: wrong binary was diffed (FAIL — redo windows-cve-diff with sibling files).

## Output: qa-check.md structure

```markdown
# QA Check: CVE-YYYY-NNNNN

## Summary
PASS / FAIL / WARN — <one line>

## Checks

| Check | Result | Notes |
|---|---|---|
| Artifact completeness | PASS | |
| Claim consistency | PASS | |
| Reproducibility (3 clean runs) | PASS 3/3 | |
| Patch discriminator | PASS | Patched build: no trigger |
| PoC code review | PASS | |
| Diff quality | PASS | 2 funcs changed, match hypothesis |

## Issues / Warnings
<none> or list

## Disposition
Ready for report / Needs rework on: <stage>
```

## Sample output

See `lab/<CVE_ID>/qa-check.md`.
