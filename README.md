# win11-forge

Standalone CVE → PoC scaffolding environment for Windows kernel and usermode
research. Builds a Windows 11 LTSC 24H2 gold image once, then spawns a
kernel-debug lab pair (target + debugger) in minutes with a live MCP endpoint
for AI-driven analysis.

Fully self-contained — no external repo dependencies.

> **Security note:** the gold image is built with Windows Firewall,
> UAC, and Defender disabled, and the lab MCP endpoints do not
> authenticate. Lab networks are host-only/NAT'd by default; keep them
> that way. Read [`SECURITY.md`](SECURITY.md) before exposing the lab
> host to anything beyond a trusted LAN.

---

## Architecture

```
Linux host (KVM + libvirt, default)         (or VMware Workstation — see "Runtime backend" below)
│
├── gold.qcow2  (build once with ./setup.sh install, ~30-40 min)
│     Windows 11 24H2 + Python + Git + VS Build Tools + WinDbg SDK
│     + Node.js LTS + DesktopCommanderMCP
│     + NadavLor windbgmcpExt.dll + kd_wrapper.py + run_http.py
│     + mcp-windbg (our svnscha fork, vm-setup/third-party/mcp-windbg)
│     + QEMU guest agent (KVM control plane) and VMware Tools (added
│       per-host on first VMware spawn, see vmware.sh)
│
├── winforge-target   (overlay off gold, 192.168.122.100)
│     bcdedit: KDNET debug → debugger:50000, testsigning on, auto-reboot on BSOD
│     target_mcp_http.py (SYSTEM, TargetDesktopBoot scheduled task)
│       └── DesktopCommanderMCP (Node.js stdio) → HTTP :8200/mcp
│             process execution, file I/O, ripgrep search on the PoC machine
│     mcp-windbg (CDB-backed user-mode debug)
│       └── cdb.exe -pn <proc> (on demand) → HTTP :8300/mcp/
│             attach/bp/go/step on live user-mode processes
│
└── winforge-debugger (overlay off gold, 192.168.122.101)
      kd_wrapper.py (SYSTEM, DebuggerBoot scheduled task)
        └── kd.exe (KDNET UDP:50000) → windbgmcpExt.dll
                                     → \\.\pipe\windbgmcp
                                     → run_http.py → HTTP :8100/mcp
      target_mcp_http.py (SYSTEM, DebuggerDesktopBoot scheduled task)
        └── DesktopCommanderMCP (Node.js stdio) → HTTP :8201/mcp
              read kd logs, check process state, edit kd_wrapper.py
```

**Transport:** KDNET over UDP (port 50000) — not serial. Reconnects
automatically on every target reboot. No timing dependency.

**Guest control plane (orchestration):** the lab orchestrator
(`setup.sh lab spawn` and friends) drives the guest via the
hypervisor's private guest-agent channel — **`qga` on KVM** (`virsh
qemu-agent-command`), **`vmrun` on VMware** (VMware Tools' VIX RPC).
Both are non-network, non-authenticated transport-level channels that
sidestep the Windows OpenSSH worker's stdout-wedge failure mode.
SSH remains as a fallback for legacy golds and for bulk file
transfer (qga/vmrun's `guest-file-*` / `copyFile*` are too slow for
multi-MB blobs). See `vm-setup/lib/guest.sh` for the dispatcher.

**MCP endpoints (four):**
- `http://192.168.122.100:8300/mcp/` — **mcp-windbg** (CDB-backed) — **user-mode** debug: attach by PID/name, bp, go, step, read memory/registers/stack. Path ends with `/`. **Primary debugger for user-mode service CVEs.** Up immediately after `lab spawn`.
- `http://192.168.122.101:8100/mcp`  — **WinDbg MCP** (NadavLor ext) — **kernel** debug (`run_command`, `!analyze -v`, kernel bp). Live after first BugCheck or `./setup.sh lab load-mcp`.
- `http://192.168.122.100:8200/mcp`  — **DesktopCommander** on target — deploy PoC, run it, read output (`start_process`, `write_file`, …).
- `http://192.168.122.101:8201/mcp`  — **DesktopCommander** on debugger — read kd logs, edit `kd_wrapper.py`, inspect debugger-side process state.

Pick the debugger endpoint by vuln family: `:8300` for user-mode service
CVEs (spoolsv, mssrch, lsass, rpcss, …), `:8100` for kernel drivers &
post-crash kernel forensics. See `skills/lab-setup/SKILL.md` for the full
decision matrix and `skills/poc-dev/SKILL.md` for the
attack-surface-discovery recipe using `:8300`.

---

## Runtime backend

The kernel-debug lab pair runs under either **KVM/libvirt** (default) or
**VMware Workstation**. Selection is by env var:

```bash
export WINFORGE_BACKEND=vmware   # or unset / =kvm for the default
```

Only `./setup.sh lab *` branches on the backend; the gold build
(`./setup.sh install`) is always KVM — VMware reuses the same
`gold.qcow2` via `vm-setup/qcow2-to-vmware.sh`, which auto-runs if
`gold.vmdk` is missing or stale.

- **KVM**: target at `192.168.122.100`, debugger at `192.168.122.101`
  (pinned via libvirt dnsmasq reservations).
- **VMware**: target at `172.16.87.100`, debugger at `172.16.87.101`
  (pinned via vmnet8 dhcpd reservations; installed once by
  `./install-deps.sh vmware`). Default subnet shown; `setup.sh lab
  status` prints the live values.

Under VMware, `./setup.sh lab spawn` and `./setup.sh lab start` default to
`--gui` so consoles open in Workstation. The script first uses the desktop
launcher (`gtk-launch vmware-workstation`) if Workstation is not already
running, then starts the VM with `vmrun`. If your desktop session blocks that
auto-launch, open VMware Workstation manually from the XFCE panel and rerun the
command. Add `--nogui` for headless after validating nogui startup on your
host. KVM stays headless by default. Both backends accept
`./setup.sh lab console <target|debugger>` to pop a console on demand.

## Quick start

### 1. Clone the repository

```bash
git clone https://github.com/eip-public/win11-forge.git
cd win11-forge
```

### 2. Install host dependencies (once)

```bash
./install-deps.sh          # KVM/libvirt, ghidriff, BinExport, etc.
./install-deps.sh check    # verify
./install-deps.sh vmware   # extra: pin vmnet8 MAC→IP reservations (only if using WINFORGE_BACKEND=vmware)
```

By default `install-deps.sh` also downloads the Windows 11 LTSC and
virtio-win ISOs into `vm-images/` if they're missing. If you want to
provide those ISOs yourself (offline install, internal mirror,
licensed media), set `WINFORGE_SKIP_ISO_DOWNLOAD=1` before running
`install-deps.sh` and stage the files manually as shown in step 3.

### 3. Add Windows ISOs to `vm-images/` (only if you skipped the auto-download)

```bash
# ~4.8 GB — Windows 11 LTSC 24H2
curl -L -o vm-images/win11-ltsc-24h2.iso \
    'https://go.microsoft.com/fwlink/?linkid=2270353'

# ~750 MB — virtio drivers
curl -L -o vm-images/virtio-win.iso \
    'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso'
```

### 4. Build the gold image (once, ~30-40 min)

```bash
./setup.sh install
```

Repacks the source ISO with Microsoft's `cdboot_noprompt.efi` /
`efisys_noprompt.bin` boot blobs (so the install boots without a
keystroke), installs Windows unattended, then runs `setup-vm.sh`
(Python, Git, VS Build Tools, WinDbg SDK, Node.js, DesktopCommanderMCP,
windbg-ext-mcp clone + DLL build, vendored mcp-windbg pip-install,
fastmcp, **QEMU guest agent** for the KVM control plane), plus the
hardening pass that disables firewall / UAC / Defender and locks
Windows Update so the target build stays fixed across reboots. Seals
to a flat gold qcow2 and stashes the gold's NVRAM alongside.

(Under `WINFORGE_BACKEND=vmware`, the first lab spawn additionally
installs **VMware Tools** into the VMware-side gold before the base
snapshot is taken — VMware Tools refuses to install on a KVM gold-
build VM, so this can't be baked into `setup-vm.sh`. Adds ~10 min
to the first VMware spawn on a given host; zero per-spawn overhead
after.)

Subsequent lab spawns take minutes, not hours.

> **Alternate gold source:** `vm-setup/create-vm.sh` also accepts a
> `.vhd` / `.vhdx` (e.g. Microsoft's free Windows 11 dev VHDX —
> `vm-setup/fetch-windev-vhd.sh` downloads it). Auto-detection drives
> the VHD branch, which converts the image to qcow2 and boots it via
> legacy BIOS without going through Windows unattended install. Note:
> the dev VHDX boots into the OOBE / `User` account; SSH and the
> `forge` account aren't pre-configured, so the rest of `./setup.sh
> install` won't run unattended off it — use this path for ad-hoc
> exploration, not the full pipeline.

The installer uses guest-side readiness states instead of fixed sleeps:
`create-vm.sh` waits for the unattended bootstrap to report
`bootstrap_ready`, `setup-vm.sh` writes `tools_ready` only after tool
verification passes, and `seal-vm-gold.sh --verify-restore` boots a
disposable overlay from the new gold and checks for `VERIFY_OK` before
accepting the image. Expensive `setup-vm.sh` phases are resumable: rerunning
the script verifies the installed tool first and skips Chocolatey, Python/Git,
SDK debuggers, VS Build Tools, MCP builds, Node.js, and DesktopCommander when
they are already healthy. The first-boot `WinForgeBootstrap` task is disabled
after `tools_ready` so later gold/lab boots do not overwrite the ready state.

### 5. Spawn the kernel-debug lab

```bash
./setup.sh lab spawn
```

This:
1. Creates two overlays off the gold (target at .100, debugger at .101)
2. Configures KDNET on the target, registers `TargetDesktopBoot` + `DebuggerDesktopBoot`
3. Uploads the latest `kd_wrapper.py`, `run_http.py`, `target_mcp_http.py` to both VMs
4. Starts all SYSTEM scheduled tasks and configures DesktopCommander via API

After spawn, these required MCP endpoints are immediately live. If any of
them fail readiness checks, `lab spawn` exits non-zero instead of reporting a
usable lab:
- `http://192.168.122.100:8200/mcp`  — DesktopCommander on target
- `http://192.168.122.101:8201/mcp`  — DesktopCommander on debugger
- `http://192.168.122.100:8300/mcp/` — mcp-windbg on target (user-mode debug; note trailing slash)

The fourth, `http://192.168.122.101:8100/mcp` (kernel WinDbg), is intentionally
pending until the first BugCheck or `./setup.sh lab load-mcp`.

### 6. Connect kd to the target kernel

After spawn, sync KDNET with the debugger if you need kernel debugging:

```bash
./setup.sh lab wait-kd
```

This reboots the target only if KDNET is not already connected, waits for
target SSH to return, then waits for `kd_wrapper.log` on the debugger to show
the KDNET connection.

Monitor via DesktopCommander (no SSH needed):
```python
# Read kd_wrapper.log directly from the debugger
run_tool("http://192.168.122.101:8201/mcp", "read_file",
         {"path": "C:\\winforge\\logs\\kd_wrapper.log"})
```

WinDbg MCP `http://192.168.122.101:8100/mcp` is live after the first kernel crash.

### 7. (Optional) Load MCP before the first crash

To get MCP active before any crash — for pre-crash breakpoint/heap inspection:

```bash
./setup.sh lab load-mcp
```

This first waits for KDNET via `lab wait-kd`. If the MCP endpoint is already
live, it exits without breaking the target again. Otherwise it calls
`NtSystemDebugControl(SysDbgBreakPoint=6)` on the target as admin. The kernel
fires an `int 3` caught by kd over KDNET. The prompt monitor injects
`.load windbgmcpExt.dll; mcpstart; g` and MCP comes online.

### 8. Use the MCP endpoint

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

---

## Commands

```bash
# Single-VM mode (usermode CVE work, no kernel debug)
./setup.sh install    # build gold from ISO (~2-3 hours, once)
./setup.sh reset      # fresh overlay from gold
./setup.sh start      # boot working disk
./setup.sh stop       # graceful shutdown
./setup.sh status     # disk paths, gold size

# Kernel-debug lab pair (respects $WINFORGE_BACKEND)
./setup.sh lab spawn              # create target + debugger from gold
./setup.sh lab spawn --gui        # + auto-open consoles (VMware default; KVM needs virt-viewer)
./setup.sh lab spawn --nogui      # headless (KVM default)
./setup.sh lab start              # start existing target + debugger without reprovisioning
./setup.sh lab stop               # ask Windows guests to shut down; force after grace period
./setup.sh lab reset              # destroy + respawn fresh overlays
./setup.sh lab status             # active backend, IPs, MCP endpoints
./setup.sh lab destroy            # tear down pair (keeps gold)
./setup.sh lab wait-kd            # reboot target if needed and wait for KDNET
./setup.sh lab load-mcp           # wait for KDNET, then load MCP before first crash
./setup.sh lab console <role>     # open a VM console (role = target | debugger)
```

---

## Layout

```
win11-forge/
├── setup.sh                  # orchestrator — all subcommands
├── install-deps.sh           # host dependency installer/checker
├── vm-setup/
│   ├── create-vm.sh          # virt-install wrapper (ISO or .vhd/.vhdx → running VM)
│   ├── seal-vm-gold.sh       # flatten working disk → gold + verify-restore
│   ├── setup-vm.sh           # post-install tool setup (runs in guest)
│   ├── autounattend.xml      # Windows unattended install answers
│   ├── kd_wrapper.py         # supervisor: keeps kd.exe alive, prompt monitor
│   ├── windbg_mcp_http.py    # HTTP transport shim for :8100 (deployed as run_http.py)
│   ├── kd_break.ps1          # NtSystemDebugControl(6) — used by lab load-mcp
│   ├── target_mcp_http.py    # FastMCP proxy: DesktopCommanderMCP stdio → HTTP :8200/:8201
│   │                         # + native run_powershell_script tool (no quoting tax)
│   ├── setup-desktop-commander.ps1  # writes DesktopCommander config for SYSTEM profile
│   ├── disable-dc-onboarding.ps1    # silences DC's pendingWelcomeOnboarding prompt-injection
│   ├── role-bootstrap-target.sh    # bcdedit KDNET + TargetDesktopBoot task
│   ├── role-bootstrap-debugger.sh  # uploads kd_wrapper+run_http, DebuggerBoot
│   ├── qcow2-to-vmware.sh    # gold.qcow2 → gold.vmdk for the VMware backend
│   ├── repack-iso-noprompt.sh  # rewrites Win11 install ISO to skip the
│   │                           # "Press any key to boot from CD" prompt
│   ├── fetch-isos.sh         # standalone: stage Win11 LTSC + virtio-win ISOs
│   ├── fetch-windev-vhd.sh   # standalone: download Microsoft's Win11 dev .vhdx
│   ├── lib/                  # shared helpers sourced by sibling scripts
│   │   ├── defaults.sh       # VM_USER/VM_PASS/VM_IP/VM_MAC default constants
│   │   ├── macs.env          # single source of truth for VM MAC addresses
│   │   ├── log.sh            # ok/warn/die status helpers
│   │   ├── ssh-helpers.sh    # shared SSH option array
│   │   ├── virsh-helpers.sh  # virsh_or_warn wrapper
│   │   ├── dc-helpers.sh     # DesktopCommander MCP config helpers
│   │   ├── set-disk-source.py# libvirt XML disk-source rewrite
│   │   ├── guest.sh          # transport-agnostic guest_powershell/guest_cmd
│   │   │                     # dispatch: qga (KVM) > vmrun (VMware) > ssh fallback
│   │   ├── qga.py            # host wrapper around virsh qemu-agent-command
│   │   └── vmrun.py          # host wrapper around vmrun runProgramInGuest
│   ├── setup-vm-phases/      # gold-build PowerShell phases launched detached via
│   │   │                     # launch.ps1 + runner.ps1 (avoids Windows OpenSSH stdout wedge)
│   │   ├── install_qga.ps1   # installs vioserial driver + QEMU-GA in KVM gold
│   │   └── install_vmware_tools.ps1  # invoked from backend/vmware.sh (VMware-side gold prep)
│   ├── backend/              # KVM- vs VMware-backend dispatch helpers (kvm.sh, vmware.sh)
│   └── third-party/
│       └── mcp-windbg/       # vendored svnscha/mcp-windbg fork (user-mode :8300)
│                             # see VENDORED.md for our deltas (local-attach support)
├── unattend-iso/             # baked into unattend.iso at build time
│   ├── OpenSSH-Win64.zip
│   ├── SetupComplete.cmd
│   ├── install-winforge-bootstrap.ps1
│   └── winforge-bootstrap.ps1
├── vm-images/                # ISOs + generated qcow2s + NVRAM (gitignored)
│   ├── win11-ltsc-24h2.iso              # source ISO (user-provided)
│   ├── win11-ltsc-24h2-noprompt.iso     # repack with cdboot_noprompt.efi (auto-generated)
│   ├── virtio-win.iso
│   ├── winforge-win11-24h2-gold.qcow2
│   ├── winforge-win11-24h2-gold-OVMF_VARS.fd  # populated NVRAM stash (seal-vm-gold.sh)
│   ├── winforge-target.qcow2         (lab spawn only)
│   ├── winforge-target-OVMF_VARS.fd  (lab spawn only — cloned from gold stash)
│   ├── winforge-debugger.qcow2       (lab spawn only)
│   └── winforge-debugger-OVMF_VARS.fd (lab spawn only — cloned from gold stash)
├── vm-ssh-key[.pub]          # generated on first install run
└── skills/                   # CVE pipeline stage documentation
    ├── patch-intel/          # stage 1: CVE triage
    ├── windows-cve-diff/     # stage 2: binary diff
    ├── lab-setup/            # stage 3: spawn debug environment
    ├── poc-dev/              # stage 4: write PoC
    ├── poc-verify/           # stage 5: verify + collect evidence
    ├── bypass/               # stage 6: mitigation bypass
    ├── qa-check/             # stage 7: quality gate
    └── report/               # stage 8: disclosure writeup
```

---

## Credentials

| Field | Value |
|---|---|
| SSH user | `forge` |
| SSH password | `forge123` |
| SSH key | `vm-ssh-key` (ed25519, generated at first install) |
| Target IP | `192.168.122.100` (DHCP MAC `52:54:00:11:11:11`) |
| Debugger IP | `192.168.122.101` (DHCP MAC `52:54:00:22:22:22`) |
| KDNET port | `50000` |
| KDNET key | `1.2.3.4` |
| WinDbg MCP — kernel (debugger VM) | `http://192.168.122.101:8100/mcp` |
| DesktopCommander MCP (debugger VM) | `http://192.168.122.101:8201/mcp` |
| DesktopCommander MCP (target VM) | `http://192.168.122.100:8200/mcp` |
| mcp-windbg — user-mode (target VM) | `http://192.168.122.100:8300/mcp/` (trailing slash) |

Symbol path set machine-wide: `srv*C:\winforge\symbols*https://msdl.microsoft.com/download/symbols`

---

## CVE pipeline

The `skills/` directory contains SKILL.md files for each stage of the
AI-driven CVE → PoC workflow. Entry point: `skills/windows-cve-diff/SKILL.md`
(patch diff via winbindex + ghidriff).

Golden example outputs in `lab/CVE-2026-33101/` (Print Spooler UAF) and
`lab/CVE-2026-26168/` (AFD race condition).

---

## How kernel debug works

```
kd_wrapper.py (SYSTEM, DebuggerBoot scheduled task)
  ├── starts kd.exe: kd -k net:port=50000,key=1.2.3.4  (no -b, no -c)
  ├── holds kd.exe stdin open via subprocess.PIPE (prevents EOF exit)
  ├── detects KDNET connection via kd.out.log ("Connected to target" or
  │   "KDTARGET: Refreshing KD connection" or "Kernel base = ")
  ├── prompt monitor thread: watches kd.out.log for "kd>" on every break
  │     on first break without pipe: inject .load windbgmcpExt.dll → mcpstart → g
  │     on subsequent breaks with pipe: send g (extension already loaded)
  ├── waits for \\.\pipe\windbgmcp to appear
  └── starts run_http.py (FastMCP streamable-HTTP on 0.0.0.0:8100)

Target reboots automatically after each BSOD (CrashControl AutoReboot=1).
kd reconnects on every reboot. Extension stays loaded — kd.exe never exits.
```

### Why no `-b` flag

`-b` forces a break at KDNET connect. KDNET handshakes before the target's
TCP/IP stack is operational, so the break handshake can't complete — kd hangs
indefinitely waiting. Always use silent attach and let breaks happen naturally
(BugCheck from PoC, or `lab load-mcp` for on-demand break).

### Why no `-c` flag

`-c` fires commands only on the **first** break and never again. The prompt
monitor approach fires on **every** break — BugCheck, `load-mcp`, any
exception — which is essential for a pipeline that runs multiple crash cycles.

### How `lab load-mcp` triggers a break

`lab load-mcp` first calls `lab wait-kd`, which makes sure the debugger has a
KDNET connection before any break is triggered. If
`http://<debugger>:8100/mcp` is already live, `load-mcp` exits without
triggering a second break.

If MCP is not live yet, `kd_break.ps1` calls
`NtSystemDebugControl(SysDbgBreakPoint=6)` on the target as local admin.
`SysDbgBreakPoint=6` is from the `SYSDBG_COMMAND` enum (confirmed by ReactOS
`dbgctrl.c`). The kernel fires `int 3`, kd catches it over KDNET, the prompt
monitor injects the extension, MCP comes online.

**Do NOT use `virsh inject-nmi`** (KVM-only concern) — that sends a hardware
NMI which Windows treats as `NMI_HARDWARE_FAILURE` (BSOD 0x80). The
`NtSystemDebugControl` approach uses the kernel debug protocol, not hardware
interrupts. No equivalent footgun exists under VMware — `vmrun` doesn't
expose NMI injection.

### Why kd_wrapper.py exists

kd.exe exits when its stdin receives EOF. Scheduled tasks close stdin when
the task launcher exits. `kd_wrapper.py` holds the write end of kd's stdin
pipe open indefinitely (`subprocess.PIPE`), auto-restarts kd on crash, and
auto-restarts the HTTP server if it dies without touching kd.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the layout, how to add a
lab-setup component or a skill, where tests live, and the style rules
contributions are expected to follow.

## License

[MIT](LICENSE).
