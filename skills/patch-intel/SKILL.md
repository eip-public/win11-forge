---
name: patch-intel
description: Stage 1 of the win11-forge CVE pipeline. Given a Microsoft CVE ID, gather full intelligence: MSRC metadata, CVSS/EPSS/KEV signals, attack surface classification, affected Windows versions and build numbers, prior exploitation history, and a go/no-go triage decision. Produces intel_brief.md. Triggers: user provides a Windows CVE and wants triage; user asks "is this exploitable?"; pipeline starts a new CVE run.
---

# patch-intel

**Pipeline stage 1 of 8.** Gather everything publicly known about a Microsoft CVE before touching a binary. The output (intel_brief.md) feeds stages 2–8.

## Inputs
- `CVE_ID` — e.g. `CVE-YYYY-NNNNN`

## Outputs
- `lab/<CVE_ID>/intel_brief.md` — structured triage document

## Procedure

### 1. MSRC API — raw metadata

```bash
CVE=CVE-YYYY-NNNNN
curl -s -L "https://api.msrc.microsoft.com/sug/v2.0/en-US/vulnerability/${CVE}" | python3 -m json.tool > /tmp/msrc.json
```

Extract and record:
- `cveTitle` — the short description
- `description` — full text (often contains root-cause language like "use after free")
- `cweList[]` — CWE IDs (CWE-416=UAF, CWE-787=OOB write, CWE-362=race, CWE-122=heap overflow)
- `tag` — component family ("Windows Print Spooler Components", etc.)
- `releaseDate` — the Patch Tuesday date (= patched build date)
- `exploited` — "Yes"/"No" — if Yes, active exploitation, treat as critical
- `publiclyDisclosed` — "Yes"/"No"
- `baseScore` / `vectorString` — CVSS v3

### 2. Attack surface classification

From `vectorString` (CVSS AV/AC/PR/UI):

| CVSS vector fragment | Meaning for PoC |
|---|---|
| `AV:N` | Network-reachable — no local access needed; highest value |
| `AV:L` | Local — attacker already has code execution on the box |
| `AC:L` | Low complexity — reliable trigger, automation-friendly |
| `AC:H` | High complexity — likely race condition or specific heap state |
| `PR:N` | No privileges required — any user/anonymous |
| `PR:L` | Low privileges required — standard user account |
| `UI:N` | No user interaction — silent |

Classify the attack scenario:
- **Remote pre-auth** (AV:N, PR:N): top priority — weaponizable without a foothold
- **Local EoP** (AV:L, PR:L): useful as second stage after initial access
- **Local EoP, high complexity** (AV:L, AC:H): race condition — harder to automate
- **User-interaction** (UI:R): phishing/file-open path — needs social engineering chain

### 3. Identify target component and binary family

Map `tag` and `description` to a likely binary. Use this table as a starting point (expand as you learn more):

| MSRC tag | Candidate binaries |
|---|---|
| Windows Print Spooler Components | `spoolsv.exe`, `localspl.dll`, `win32spl.dll`, `spoolss.dll` |
| Win32K / GRFX | `win32kbase.sys`, `win32kfull.sys` |
| Windows TCP/IP | `tcpip.sys` |
| Windows Common Log File System | `clfs.sys` |
| Windows Kernel | `ntoskrnl.exe`, check CWE for area |
| Windows CNG / Crypto | `cng.sys`, `ksecdd.sys` |
| Windows LDAP / LSASS | `lsasrv.dll`, `wldap32.dll` |
| Windows Hyper-V | `hvax64.exe`, `hvix64.exe`, `vmswitch.sys` |
| Remote Desktop | `rdpcorets.dll`, `termsrv.dll` |
| SMB / CIFS | `srvnet.sys`, `srv2.sys` |
| Microsoft Windows Search Component | `searchindexer.exe`, `mssrch.dll`, `tquery.dll`, `searchfolder.dll` (all `7.0.26100.x`) |
| Windows Ancillary Function Driver (AFD) / WinSock | `afd.sys` |
| Desktop Window Manager | `dwmcore.dll`, `udwm.dll` |
| Windows UPnP Device Host | `upnphost.dll`, `ssdpsrv.dll` |
| Windows Push Notifications | `wpncore.dll`, `wpnservice.dll`, `wpnuserservice.dll` |

If uncertain, proceed to `windows-cve-diff` with 2–3 candidates; the one with `matched_funcs_with_code_changes_len < 10` is the right one.

### 4. Identify affected builds

Use the MSRC `releaseDate` to determine the patch Patch Tuesday. The vulnerable build is the cumulative update immediately before, patched build is on or after that date.

For Windows 11 24H2, match by the **build number** (`26100`), not the major/minor
prefix. Kernel + most OS binaries ship with `10.0.26100.x`, but component-specific
binaries use their own majors — Search Service is `7.0.26100.x`, Defender is
`4.18.x`, etc. A `^10\.0\.26100\.` regex will silently miss those. Use
`\.26100\.(\d+)` and also emit file size so you can disambiguate x64 vs ARM64:

```bash
curl -s -L 'https://winbindex.m417z.com/data/by_filename_compressed/<FILENAME>.json.gz' \
  | gunzip | python3 -c "
import json, sys, re
d = json.load(sys.stdin)
pat = re.compile(r'\.26100\.(\d+)')  # match build=26100 regardless of major/minor
rows = []
for sha, e in d.items():
    fi = e.get('fileInfo', {})
    m = pat.search(fi.get('version', ''))
    if not m: continue
    build = int(m.group(1))
    ts = fi.get('timestamp', 0); sz = fi.get('virtualSize', 0)
    dates = [ud.get('updateInfo',{}).get('releaseDate','')[:10]
             for wv in e.get('windowsVersions',{}).values()
             for ud in wv.values() if 'releaseDate' in ud.get('updateInfo',{})]
    rows.append((build, ts, sz, dates[0] if dates else '?', sha[:16]))
rows.sort()
for r in rows[-8:]:
    print(f'  build={r[0]:<7} ts={r[1]:<12} size={r[2]:<10} date={r[3]:<12} sha={r[4]}')
"
```

Find the last build before the patch date (vulnerable) and the first on/after
(patched). Each build typically appears twice — one x64 and one ARM64, with
different sizes. Our lab is x64; pick the size you'll confirm with `file`
after download (PE32+ with `x86-64` architecture).

Silent-failure note: if the output is empty, the regex matched nothing. The
most common causes are (a) the binary ships under a different filename on
24H2 (the `by_filename_compressed` index is case- and extension-sensitive),
(b) the binary was dropped from 24H2 entirely, or (c) the version string
doesn't contain `.26100.` (pre-release / insider builds). Try sibling
filenames from the same component family and verify with `curl -I`.

### 5. Check for existing public analysis

Search for:
- CVE ID + "writeup" / "analysis" / "exploit" on GitHub
- CVE ID on exploit-db, packetstorm
- Vendor blogs (Kaspersky, ZDI, ESET, Qualys, Rapid7)
- Twitter/X threads mentioning the CVE ID

If public exploits or writeups exist, note what they reveal about the trigger mechanism — this feeds poc-dev directly.

### 6. Go / no-go triage

Score these criteria:

| Criterion | Go signal |
|---|---|
| CWE type | CWE-416 (UAF), CWE-787 (OOB write), CWE-122 (heap overflow) → memory corruption = PoC feasible |
| Attack vector | AV:L or AV:N, PR:L or PR:N |
| Complexity | AC:L preferred (AC:H = race = harder) |
| Affected versions | 24H2 LTSC — must overlap our lab VM build |
| Prior exploitation | "exploited: Yes" → known-weaponizable |

**Go** if: memory corruption CWE + AV:L + AC:L + Win11 24H2 affected.
**Defer** if: only affects Windows Server or end-of-life builds; CWE is informational (CWE-200).
**Skip** if: no binary patch (e.g. cloud-only fix or configuration change).

## Lessons from real runs

- **Older builds are in scope**: A CVE patched in month X is also present in all older builds of the same `10.0.BBBBB.x` series. If your lab VM runs a build older than the "vulnerable" winbindex reference, the bug still exists — you don't need to deploy the exact diffed binary.
- **Check epmapper for RPC services, not just SMB named pipes**: Windows RPC services register dynamic TCP endpoints via the endpoint mapper even when SMB pipes are inaccessible (e.g. when SMB inbound rules are off). Always try `ncacn_ip_tcp` via epmapper if `\pipe\<service>` is unreachable from the attacker host.
- **MSRC component names map to multiple binaries**: A single MSRC tag ("Windows X Components") may cover several DLLs or EXEs. Diff 2–3 candidates; the one with `matched_funcs_with_code_changes_len < 10` is the right file.

## Output: intel_brief.md structure

```markdown
# Intel Brief: CVE-YYYY-NNNNN

## Summary
<title>, <CVSS score>, <attack scenario one-liner>

## CVE Metadata
- CWE: ...
- CVSS: ... / vectorString: ...
- Released: ...
- Exploited in wild: Yes/No
- Publicly disclosed: Yes/No

## Attack Surface
- Access required: ...
- Complexity: ...
- PoC scenario: ...

## Target Binary
- File: ...
- Component: ...
- Vulnerable build: 10.0.26100.NNNN (date ...)
- Patched build:    10.0.26100.NNNN (date ...)

## Triage Decision
Go / Defer / Skip — reason

## Prior Art
- [links or "none found"]

## Next Step
→ Run windows-cve-diff with <binary> vuln-build vs patch-build
```

## Sample output

See `lab/<CVE_ID>/intel_brief.md` for a worked example.
