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
  disable-dc-onboarding.ps1     silences DC's pendingWelcomeOnboarding
                                prompt-injection at role-bootstrap time
  role-bootstrap-target.sh      target VM role bootstrap: KDNET
                                bcdedit, testsigning, auto-reboot
  role-bootstrap-debugger.sh    debugger VM role bootstrap
  kd_wrapper.py                 SYSTEM-scheduled wrapper that runs
                                kd.exe and exposes an MCP endpoint
  kd_break.ps1                  triggers a kernel break on demand
  target_mcp_http.py            DesktopCommander HTTP shim, plus
                                native run_powershell_script tool
                                (collapses the write_file +
                                start_process + read_process_output
                                dance into one round trip)
  windbg_mcp_http.py            WinDbg MCP HTTP shim
  qcow2-to-vmware.sh            converts gold.qcow2 -> gold.vmdk for
                                VMware backend
  repack-iso-noprompt.sh        rewrites the Win11 install ISO to
                                skip the "Press any key to boot from
                                CD" prompt (Microsoft's noprompt
                                blobs are already inside the ISO)
  fetch-isos.sh                 standalone fetcher for Win11 LTSC +
                                virtio-win ISOs (mirrors the logic in
                                install-deps.sh)
  fetch-windev-vhd.sh           standalone fetcher for Microsoft's
                                free Windows 11 dev .vhdx (HyperV
                                variant); resolves the aka.ms redirect
  backend/                      KVM-vs-VMware dispatch helpers
  lib/                          shared helpers sourced by the other
                                scripts (ssh-helpers, log, virsh-helpers,
                                dc-helpers, macs.env, defaults.sh,
                                set-disk-source.py, plus the guest
                                control-plane stack: guest.sh
                                transport dispatch, qga.py host
                                wrapper for virsh qemu-agent-command,
                                vmrun.py host wrapper for vmrun
                                runProgramInGuest). One source of truth
                                per shared concern.
  setup-vm-phases/              gold-build PowerShell phase scripts.
                                Launched via launch.ps1 + runner.ps1 as
                                detached Windows scheduled tasks — see
                                rule 10 below for why synchronous SSH
                                doesn't work here. Includes install_qga.ps1
                                (KVM guest agent MSI + vioserial driver)
                                and install_vmware_tools.ps1 (invoked
                                from backend/vmware.sh, NOT setup-vm.sh
                                — see rule 14 for the hypervisor-detect
                                gotcha).
  patches/                       host-side patch files applied during the
                                gold build (git apply --check guard makes
                                each idempotent). e.g.
                                windbg-ext-mcp-surface-errors.patch.
  third-party/mcp-windbg/       vendored upstream fork (patched at build
                                time via patches/ above)

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

15. **`Set-MpPreference -DisableRealtimeMonitoring` is a silent no-op
    under Tamper Protection on Win11 IoT Enterprise LTSC.** TP engages
    once `MsMpEng` first loads; after that, the cmdlet returns success
    without changing live state. The real disable path is a registry
    write — `HKLM\SYSTEM\CurrentControlSet\Services\WinDefend Start=4`
    — applied in the specialize pass of `autounattend.xml` before TP
    loads. `disable_security.ps1` and `winforge-bootstrap.ps1` contain
    a hard assertion (`Get-MpComputerStatus`) that throws if RTP is
    still on after the attempt; do not soften this to a warning.
    Per-spawn belt-and-suspenders in `role-bootstrap-target.sh` add
    `C:\winforge` and `C:\temp` as `ExclusionPath` entries — TP
    permits admin exclusion adds even when it blocks the full disable.
    Don't revert to the old `Set-MpPreference` pattern; it silently
    ships a fully-armed Defender that quarantines PoC binaries at
    runtime.

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

10. **`setup-vm.sh` runs each phase as a detached scheduled task.**
    Long-running PowerShell over SSH wedges Windows OpenSSH — the
    worker stalls on child stdout I/O during heavy installs (msiexec
    MSI extraction, VS Build Tools, etc.). The pattern is:
    `launch.ps1` registers a one-shot task that runs `runner.ps1 -File
    <phase.ps1>`, returns to ssh in ~1s; the bash side polls a marker
    file on the guest via short ssh calls (`upload_and_run_ps1` in
    `setup-vm.sh`). Each ssh call is sub-5s, so sshd cannot wedge on
    streaming output. Match this pattern when adding new phases —
    don't reintroduce long synchronous SSH.

11. **The gold image's NVRAM is preserved alongside `gold.qcow2`.**
    `seal-vm-gold.sh` writes `vm-images/<gold>-gold-OVMF_VARS.fd`
    after the flatten succeeds. `backend/kvm.sh::vm_provision`
    prefers that stash over `/usr/share/OVMF/OVMF_VARS_4M.fd` when
    cloning the per-role NVRAM. Without the stash, a fresh overlay
    boots via OVMF's UEFI HDD fallback to `\EFI\Boot\bootx64.efi` —
    works today but silently fragile across OVMF upgrades and adds
    extra firmware time before Windows starts. If you add a new
    backend, replicate the prefer-stash behavior.

12. **Guest control plane: qga (KVM) / vmrun (VMware) primary, SSH
    fallback.** Lab orchestration (`role-bootstrap-*.sh`,
    `setup.sh::_lab_wait_ssh`) drives the guest via the hypervisor's
    private guest-agent channel — `virsh qemu-agent-command` on
    KVM, `vmrun runProgramInGuest` on VMware. Both sidestep the
    Windows OpenSSH worker's stdout-wedge failure mode. SSH stays
    for bulk file transfer (qga's `guest-file-*` / vmrun's
    `copyFile*` are too slow for multi-MB blobs) and as the
    fallback path on legacy golds. `vm-setup/lib/guest.sh` is the
    single dispatcher — `guest_powershell` / `guest_cmd` /
    `guest_select_transport`. Don't bypass it when shipping
    commands to the guest; bypassing reintroduces both transport
    selection bugs and the quoting bug in rule 13.

13. **SSH-fallback PowerShell goes via `-EncodedCommand` (base64-
    UTF16LE), never `"... -Command \"$script\""`.** The raw quoted
    form mangles embedded quotes the moment `$script` itself
    contains `"..."` (e.g. `schtasks /TR "C:\Python314\python.exe
    C:\winforge\target_mcp_http.py"`) — the inner quote terminates
    PowerShell's `-Command` argument and the script breaks at parse
    time. Caused real role-bootstrap failures on 2026-05-17/18.
    `vm-setup/lib/guest.sh`'s SSH branch handles this correctly via
    `iconv -t utf-16le | base64 -w0`. Don't write `ssh "powershell
    ... -Command \"$x\""` anywhere new.

14. **VMware Tools cannot be installed in the KVM-built gold.** The
    official Microsoft VMware Tools `setup.exe` has a hardcoded
    `VMCheckRequirements()` check that bails with MSI exit 1602
    ("Not inside a VM. Exiting...") on any non-VMware hypervisor.
    `setup-vm.sh` (which always runs on KVM during `./setup.sh
    install`) can't install it. Tools install lives in
    `backend/vmware.sh::_vmware_install_tools_in_gold`, which runs
    once per host on the first VMware lab spawn: boots `gold.vmx`
    under VMware, SSHes in, installs Tools, shuts down, marks
    `vm-images/vmware/<gold>/.tools-installed`, then takes the base
    snapshot. All linked clones inherit. Don't try to "fix" this
    by moving the install to setup-vm.sh — it will fail 1602.

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

## Branch and PR workflow

All changes go through a branch + PR. Never push to `main` directly.

```bash
git checkout -b <area>/<slug>   # e.g. feat/vmware-backend, fix/kd-wrapper-restart, chore/update-deps
# make changes
git add <files>
git commit -m "Short imperative subject"
git push -u origin <area>/<slug>
# open PR for review
```

Use `feat/` for new capability, `fix/` for bugs, `chore/` for maintenance/docs/cleanup, `scripts/` for one-off ops scripts.

## Validation before commit

```bash
# Lint + format — also runs in CI (.github/workflows/lint.yml). Config:
#   - .shellcheckrc      empty of rule suppressions; SC1091 and
#                        SC2148 are handled by narrowly-scoped
#                        annotations (`# shellcheck source=...`
#                        and `# shellcheck shell=bash`) at the
#                        call sites.
#   - pyproject.toml     [tool.ruff] target-version, rule selection,
#                        per-file ignores; excludes vm-setup/third-party
#                        and lab/. [tool.ruff.format] is the Python
#                        formatter (Black-compatible). [tool.mypy]
#                        sets python_version 3.10, files=[vm-setup],
#                        strict-ish warnings, and ignore_missing_imports
#                        for the Windows-only fastmcp / mcp_server
#                        packages.
#   - shfmt v3.13.1      bash formatter; canonical flags are `-i 4 -ci`
#                        (4-space indent, indented switch-case arms).
#   - lizard 1.17        bash cyclomatic-complexity cap at CCN 12
#                        (matches ruff's [tool.ruff.lint.mccabe]
#                        max-complexity for Python).
#   - vulture 2.14       Python dead-code detection. Scope mirrors
#                        ruff/mypy. Config: [tool.vulture] in
#                        pyproject.toml. Complements ruff's F (pyflakes)
#                        rules by catching unused methods/functions
#                        that pyflakes treats as potential external API.
#   - jscpd 4.2.3        Polyglot copy-paste detection (bash, python,
#                        powershell — the three languages in this repo).
#                        Config: .jscpd.json at repo root. minLines /
#                        minTokens skip incidental structural echoes;
#                        `threshold` is the ratchet — set above today's
#                        baseline so CI passes, and lowered as known
#                        duplicates are extracted into vm-setup/lib/.
#                        Patch version is pinned in lockstep across
#                        .github/workflows/lint.yml and CONTRIBUTING.md.
# Use the portable -print0 | xargs -0 form so this works in bash 3.2
# (macOS default) and zsh too — no `mapfile`.
SH_FILES_FIND=( -name '*.sh'
    -not -path './vm-setup/third-party/*'
    -not -path './lab/*' )
find . "${SH_FILES_FIND[@]}" -print0 | xargs -0 shellcheck -x -S warning
find . "${SH_FILES_FIND[@]}" -print0 | xargs -0 shfmt -i 4 -ci -d
lizard --languages bash -C 12 -L 1000 \
    install-deps.sh setup.sh \
    vm-setup/*.sh vm-setup/backend/*.sh vm-setup/lib/*.sh
ruff check
ruff format --check
mypy        # static type check; install with: pip install 'mypy==1.20.*'
vulture     # dead-code detection; install with: pip install 'vulture==2.14'
npx jscpd@4.2.3 .  # copy-paste detection; no install needed beyond npx

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
  `./setup.sh install` rebuild. The ~40 min gold-rebuild cycle
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
- Python: target Python 3.14 (`C:\Python314\python.exe` on the gold —
  that is what Chocolatey's `python3` package installs). No
  package-manager assumptions inside guest scripts.
- Comment the *why*, not the *what*. The `vm-setup/` and
  `unattend-iso/` files in particular are full of small workarounds
  for specific Windows behaviors — one line per workaround is the
  norm; long narrative is not.
- No machine-specific paths in skill or doc prose (`/Users/<name>/`,
  `/home/<name>/`). Use `$HOME` and the canonical lab paths.

## Naming conventions

The conventions below are the canonical reference. Python is
*partially* enforced by ruff's `N` (pep8-naming) rule set —
class/function/argument/local names and mixedCase globals are caught
by CI, but module-level constants being `UPPER_SNAKE_CASE` and the
leading-underscore module-private rule are convention-only and live
in code review. Bash and PowerShell are entirely convention-only.
The existing tree is internally consistent and new code must match.
See `CONTRIBUTING.md` "Naming conventions" for the full rules,
per-bullet [ruff]/[convention] tags, and examples; the summary:

- **Python**: `snake_case` functions/vars, `PascalCase` classes,
  `UPPER_SNAKE_CASE` constants (review-enforced — ruff `N` accepts
  lowercase here), leading `_` for module-private. Unit-bearing
  constants use a suffix: `*_S` seconds, `*_PORT` ports,
  `*_BYTES`/`*_KB` sizes.
- **Bash**: `UPPER_SNAKE_CASE` for env-overridable settings and
  module-level constants (`WINFORGE_BACKEND`, `VM_NAME`, `SCRIPT_DIR`);
  `snake_case` for functions and `local` vars; leading `_` marks a
  file-local helper (`_ssh_probe`, `_lab_wait_ssh`); `kebab-case` for
  script filenames and CLI subcommands.
- **PowerShell**: `Verb-Noun` cmdlet style with approved verbs;
  `PascalCase` variables and parameters; ASCII-only string literals.
- **Lab files**: filenames are fixed by the eight-stage contract (see
  "Lab files" above). Ad-hoc names break the pipeline.

Don't rename existing public identifiers casually — they appear in
documented MCP endpoint paths, lab-file filenames, and the
`WINFORGE_*` env-override surface. Match the convention; don't
re-letter the world.

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
## Handling the automated Claude PR review
It's up to you to decide if the nits are worth it — you have the most context. Act on what
matters (security, correctness, data-loss); use judgment on the rest. Don't blindly apply
every suggestion, and don't chase round-after-round re-review over cosmetics.
