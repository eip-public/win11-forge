# Working in win11-forge

Project-level notes for anyone — human or AI — making changes here.
This file is the source of truth for the conventions the rest of the
repo holds itself to. Read it first.

## What this repo is

A standalone CVE → PoC scaffolding environment for Windows kernel and
usermode research. One bootstrap (`install-deps.sh`) provisions the
Linux lab host; one top-level driver (`setup.sh`) builds a Windows 11
LTSC 24H2 gold image once, then spawns short-lived target/debugger VM
pairs as overlays off the gold for each research session.

It is **not** a hardened image and **not** a public lab. The gold
image is intentionally permissive (firewall/UAC/Defender off,
testsigning on, auto-reboot on BSOD) so that CVE PoCs run cleanly
against a known, debuggable target. The MCP endpoints the lab exposes
do not authenticate; they assume a private lab network. See
`SECURITY.md`.

## Where things live

```
install-deps.sh                 host bootstrap: KVM/libvirt, ghidriff,
                                BinExport, Ghidra, ISOs. Idempotent.
setup.sh                        top-level driver: install (gold build),
                                lab spawn / start / stop / status / ...

unattend-iso/                   Windows unattended-install payload
  SetupComplete.cmd             post-install firstboot hook
  winforge-bootstrap.ps1        runs in audit mode; disables firewall/
                                UAC, sets up firstboot env
  install-winforge-bootstrap.ps1 stages winforge-bootstrap.ps1 into
                                C:\winforge\ during audit-mode install
  OpenSSH-Win64.zip             vendored Microsoft binary (legacy;
                                see below)

vm-setup/                       guest-side install + lab-host helpers
  autounattend.xml              Windows unattended-install answer file
  setup-vm.sh                   inside-VM gold build: WinDbg, VS Build
                                Tools, Python, DC MCP, mcp-windbg,
                                hardening pass
  seal-vm-gold.sh               turns the post-setup VM into the flat
                                gold qcow2
  create-vm.sh                  builds the per-overlay target/debugger;
                                accepts either an ISO or a .vhd/.vhdx
  setup-desktop-commander.ps1   guest DC install
  role-bootstrap-target.sh      target VM role bootstrap: KDNET
                                bcdedit, testsigning, auto-reboot
  role-bootstrap-debugger.sh    debugger VM role bootstrap
  kd_wrapper.py                 SYSTEM-scheduled wrapper that runs
                                kd.exe and exposes an MCP endpoint
  kd_break.ps1                  triggers a kernel break on demand
  target_mcp_http.py            DesktopCommander HTTP shim
  windbg_mcp_http.py            WinDbg MCP HTTP shim
  qcow2-to-vmware.sh            converts gold.qcow2 -> gold.vmdk for
                                VMware backend
  fetch-isos.sh                 standalone fetcher for Win11 LTSC +
                                virtio-win ISOs (mirrors the logic in
                                install-deps.sh)
  fetch-windev-vhd.sh           standalone fetcher for Microsoft's
                                free Windows 11 dev .vhdx (HyperV
                                variant); resolves the aka.ms redirect
  backend/                      KVM-vs-VMware dispatch helpers
  third-party/mcp-windbg/       vendored upstream fork

skills/                         eight-stage pipeline skill set
  patch-intel/      (1)         publicly known intel for the CVE
  windows-cve-diff/ (2)         binary diff of patched vs unpatched
  lab-setup/        (3)         spawn the kernel-debug VM pair
  poc-dev/          (4)         translate diff into working PoC
  poc-verify/       (5)         reproducible run + evidence capture
  bypass/           (6)         optional mitigation/exploitation
  qa-check/         (7)         gate check before final report
  report/           (8)         synthesised disclosure document

lab/CVE-YYYY-NNNNN/             per-CVE working directory; see "Lab
                                files" below for the canonical set.

tests/*.bats                    bats suites covering bootstrap and
                                lab lifecycle
```

## Hard rules

These are the invariants the existing code relies on. Don't break
them.

1. **Lab networks stay private.** KVM uses `192.168.122.0/24`
   (libvirt default), VMware uses `172.16.87.0/24` (`vmnet8`). Both
   are host-only or NAT'd by default. The four MCP endpoints
   (`:8100, :8200, :8201, :8300`) and `KDNET UDP:50000` are
   unauthenticated; **anyone who can route to the lab subnet has full
   target/debugger control.** Do not bridge the lab network, do not
   forward those ports off the host, do not assume the agent's prompt
   is a substitute for network-level isolation.

2. **The gold image is permissive by design.**
   `unattend-iso/winforge-bootstrap.ps1` and `vm-setup/setup-vm.sh`
   disable Windows Firewall, set `EnableLUA=0`, disable Defender, and
   lock Windows Update. `role-bootstrap-target.sh` enables
   `bcdedit /set testsigning on` and auto-reboot on BSOD. These are
   **not bugs**; they are required for clean PoC execution and KDNET
   reattach after BugCheck. Don't "fix" them.

3. **`kd_wrapper.py` holds kd's stdin open on purpose.** kd.exe exits
   when its stdin receives EOF. Scheduled tasks close stdin when the
   task launcher exits. The wrapper holds the write end of kd's stdin
   pipe open indefinitely (`subprocess.PIPE`), auto-restarts kd on
   crash, and auto-restarts the HTTP server independently. Don't
   simplify this to a plain `Start-Process kd.exe`.

4. **No `-b` or `-c` flags to kd in the wrapper.** `kd_wrapper.py`
   intentionally launches kd without `-b` (which causes early-boot
   KDNET timing freezes) and without `-c` (which fires once only).
   Commands are injected via stdin by the prompt monitor thread,
   which fires on every break — BugCheck, NMI, or any other kernel
   exception. Match this pattern if you add new kd-launching paths.

5. **Don't use `virsh inject-nmi` as a generic break mechanism.**
   It sends a hardware NMI; Windows treats that as
   `NMI_HARDWARE_FAILURE` (BSOD 0x80). win11-forge uses
   `NtSystemDebugControl(SysDbgBreakPoint=6)` from `kd_break.ps1`
   instead — that goes through the kernel debug protocol, not a
   hardware interrupt.

6. **KVM and VMware backends are peers.** Every `setup.sh lab *`
   subcommand branches on `WINFORGE_BACKEND`. If you add a new
   subcommand or option to one backend, add the equivalent to the
   other — or explicitly emit "not supported on this backend" and
   exit nonzero. Silent divergence between backends will burn the
   next contributor.

7. **`setup.sh install` is always KVM.** The gold image is built
   under KVM; VMware reuses the same `gold.qcow2` via
   `vm-setup/qcow2-to-vmware.sh`, which auto-runs if `gold.vmdk` is
   missing or stale. Don't reimplement the gold build under VMware.

8. **No surprise vendored binaries.** `unattend-iso/OpenSSH-Win64.zip`
   is the only vendored Microsoft binary today and it is grandfathered
   in. New third-party artifacts should be fetched at install time
   with a sha256 check, not committed.

9. **Lab files follow the eight-stage contract.** Each stage produces
   a fixed filename consumed by the next; the pipeline relies on it.
   See "Lab files" below.

## Lab files

`lab/CVE-YYYY-NNNNN/` is the working directory for one CVE. The
canonical filenames produced by the pipeline:

```
intel_brief.md                   stage 1 output (patch-intel)
diff_analysis.md                 stage 2 output (windows-cve-diff)
lab_setup_report.md              stage 3 output (lab-setup)
poc-dev.md                       stage 4 output (poc-dev)
poc_verification_report.md       stage 5 output (poc-verify)
bypass_analysis.md               stage 6 output (bypass; optional)
qa-check.md                      stage 7 output (qa-check)
disclosure.md                    stage 8 output (report)

msrc.json                        raw MSRC API response (intel-fed)
diffs/<binary>/                  ghidriff working dirs (gzfs/, .log)
```

The pipeline reads its predecessor's filename verbatim. Ad-hoc names
break the next stage's inputs.

## Validation before commit

```bash
shellcheck install-deps.sh setup.sh         # primary entry points
bats tests/bootstrap-readiness.bats         # gold-image readiness
bats tests/kvm-backend.bats                 # KVM lab lifecycle
bats tests/vmware-backend.bats              # VMware lab lifecycle
bats tests/lab-lifecycle.bats               # backend-agnostic
```

Run only the bats suites that touch what you changed; the full set
takes a while.

If you changed anything that affects the gold image
(`unattend-iso/*`, `vm-setup/setup-vm.sh`, the hardening pass),
rebuild the gold and confirm the lab still spawns clean:

```bash
./setup.sh install
./setup.sh lab spawn
./setup.sh lab status
```

### Test rhythm for batched fixes

When working through a backlog of small changes (e.g. an audit pass),
split by what each fix requires to validate:

- **Lab-exercisable** — the fix runs against a spawned lab pair.
  Validate with `./setup.sh lab destroy && ./setup.sh lab spawn` (or
  a more targeted subcommand). Ship one fix per commit, ~5–10 min per
  cycle. Refactors that touch backend-dispatch / role-bootstrap fall
  here too — the spawn cycle re-exercises everything.

- **Gold-build-only** — the fix lives in `unattend-iso/`, `setup-vm.sh`,
  `seal-vm-gold.sh`, `install-winforge-bootstrap.ps1`, or the
  cleanup branches of `create-vm.sh`. Don't try to test these in
  isolation. **Batch them**, then ship the whole batch in a single
  `./setup.sh install` rebuild. One multi-hour gold-rebuild cycle
  validates the batch collectively.

- **Host-install path** — fixes in `install-deps.sh`. Test on a clean
  host or a sandbox; orthogonal to the lab and the gold.

`AUDIT.md` has a "Status tracker" appendix that records which findings
are landed and which are batched for the next gold-rebuild cycle.
Update it as fixes land.

## Style

- `set -Eeuo pipefail` at the top of every bash script.
- PowerShell: `Set-StrictMode -Version Latest` and
  `$ErrorActionPreference = 'Stop'` where the script does anything
  consequential. Many of the `unattend-iso/*.ps1` files intentionally
  don't, because they run inside Windows audit mode where strict mode
  can interact badly with the legacy commands they use. Don't add
  strict mode there without testing the full unattended install.
- Python: target the version the gold image ships (currently 3.x
  system Python). No package-manager assumptions inside guest scripts.
- Comment the *why*, not the *what*. The `vm-setup/` and
  `unattend-iso/` files in particular are full of small workarounds
  for specific Windows behaviors — one line per workaround is the
  norm; long narrative is not.
- No machine-specific paths in skill or doc prose (`/Users/<name>/`,
  `/home/<name>/`). Use `$HOME` and the canonical lab paths.

## Documentation hierarchy

When updating docs:

- `README.md` — high-level intro, architecture, quickstart, runtime
  backend selection, MCP endpoint reference, "Why no -b/-c flag" and
  "Why kd_wrapper.py exists" sections. User-facing.
- `SECURITY.md` — threat-model posture, network exposure, recommended
  posture for any internet-adjacent host.
- `CONTRIBUTING.md` — contributor flow, where tests live, no-new-
  vendored-binaries rule.
- `CLAUDE.md` (this file) — invariants the code holds itself to.
- `skills/<stage>/SKILL.md` — agent-facing procedure for one
  pipeline stage. Terse, imperative, frontmatter-contract.

If a fact lives in two places, the two will drift. Pick the right
home and link from the other.
