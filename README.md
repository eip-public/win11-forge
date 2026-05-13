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
├── gold.qcow2  (build once with ./setup.sh install, ~2-3 hours)
│     Windows 11 24H2 + Python + Git + VS Build Tools + WinDbg SDK
│     + Node.js LTS + DesktopCommanderMCP
│     + NadavLor windbgmcpExt.dll + kd_wrapper.py + run_http.py
│     + mcp-windbg (our svnscha fork, vm-setup/third-party/mcp-windbg)
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

### 4. Build the gold image (once, ~2-3 hours)

```bash
./setup.sh install
```

Installs Windows unattended, then runs `setup-vm.sh` (Python, Git, VS Build
Tools, WinDbg SDK, Node.js, DesktopCommanderMCP, windbg-ext-mcp clone + DLL
build, vendored mcp-windbg pip-install, fastmcp), plus the hardening pass
that disables firewall / UAC / Defender and locks Windows Update so the
target build stays fixed across reboots. Seals to a flat gold qcow2.
Subsequent lab spawns take minutes, not hours.

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
│   ├── create-vm.sh          # virt-install wrapper (ISO → running VM)
│   ├── seal-vm-gold.sh       # flatten working disk → gold + verify-restore
│   ├── setup-vm.sh           # post-install tool setup (runs in guest)
│   ├── autounattend.xml      # Windows unattended install answers
│   ├── kd_wrapper.py         # supervisor: keeps kd.exe alive, prompt monitor
│   ├── windbg_mcp_http.py    # HTTP transport shim for :8100 (deployed as run_http.py)
│   ├── kd_break.ps1          # NtSystemDebugControl(6) — used by lab load-mcp
│   ├── target_mcp_http.py    # FastMCP proxy: DesktopCommanderMCP stdio → HTTP :8200/:8201
│   ├── setup-desktop-commander.ps1  # writes DesktopCommander config for SYSTEM profile
│   ├── role-bootstrap-target.sh    # bcdedit KDNET + TargetDesktopBoot task
│   ├── role-bootstrap-debugger.sh  # uploads kd_wrapper+run_http, DebuggerBoot
│   └── third-party/
│       └── mcp-windbg/       # vendored svnscha/mcp-windbg fork (user-mode :8300)
│                             # see VENDORED.md for our deltas (local-attach support)
├── unattend-iso/             # baked into unattend.iso at build time
│   ├── OpenSSH-Win64.zip
│   ├── SetupComplete.cmd
│   ├── install-winforge-bootstrap.ps1
│   └── winforge-bootstrap.ps1
├── vm-images/                # ISOs + generated qcow2s (gitignored)
│   ├── win11-ltsc-24h2.iso
│   ├── virtio-win.iso
│   ├── winforge-win11-24h2-gold.qcow2
│   ├── winforge-target.qcow2         (lab spawn only)
│   └── winforge-debugger.qcow2       (lab spawn only)
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
