# Security model

win11-forge spins up Windows kernel-debug labs for CVE research. The
VMs it creates are **intentionally insecure** and the MCP endpoints
the lab exposes are intended for trusted-LAN use only. Read this
before exposing the lab host or any of its VMs to anything beyond a
trusted network.

## What the install grants

- `install-deps.sh` runs as root (via `sudo`), adds the invoking user
  to the `libvirt` and `kvm` groups, installs libvirt/qemu and a
  host-side reverse-engineering toolchain (Ghidra, ghidriff, BinExport,
  …), and starts the default libvirt network. After this, any process
  the user runs can talk to libvirt without prompting.
- `setup.sh install` builds the Windows gold image. The gold-image
  bootstrap (`unattend-iso/winforge-bootstrap.ps1`,
  `vm-setup/setup-vm.sh`) **disables Windows Firewall, UAC, and
  Defender** and locks Windows Update so the build stays fixed across
  reboots. Target VMs additionally enable `bcdedit /set testsigning on`
  and `auto-reboot on BSOD`. The gold is not a hardened image — it is
  designed to be a permissive crash-debug target.

## Network exposure

The lab pair runs on a private libvirt or VMware network by default
(`192.168.122.0/24` for KVM, `172.16.236.0/24` for VMware — vmnet8's
auto-configured subnet, varies per host). Those networks are
host-only / NAT'd out of the box, so the lab endpoints are not
reachable from the broader LAN unless the host is bridged or
forwarded.

Endpoints inside the lab network:

- `:8300/mcp/` — **mcp-windbg** (CDB-backed user-mode debugger). Lets
  any caller attach to any process on the target VM and read/write
  memory and registers. **Full code execution on the target as
  SYSTEM.**
- `:8100/mcp` — **WinDbg MCP** (kernel). Lets any caller issue kernel
  debugger commands. **Full kernel read/write/control of the target.**
- `:8200/mcp` and `:8201/mcp` — **DesktopCommander** on target and
  debugger respectively. Generic process execution and file I/O on
  each VM. The `pendingWelcomeOnboarding` prompt-injection in
  upstream DC is silenced at lab spawn (see
  `vm-setup/disable-dc-onboarding.ps1`).
- `KDNET UDP:50000` between target and debugger.

None of these endpoints authenticate. Anyone who can route to the lab
subnet has full control of the VMs.

## Hypervisor-side control plane (qga / vmrun)

In addition to the network endpoints above, the lab uses
**hypervisor-private** channels for orchestration:

- **KVM**: QEMU guest-agent over a virtio-serial channel. The host
  drives the guest via `virsh qemu-agent-command`. No network
  listener, no firewall, no authentication.
- **VMware**: VMware Tools' VIX RPC. The host drives the guest via
  `vmrun runProgramInGuest` with `forge`/`forge123` credentials.

These channels are not exposed on any network port — they are
transport-level (virtio-serial / VMware Tools daemon), reachable only
from a process on the hypervisor host that can talk to the local
libvirt socket / vmrun binary. The threat model is therefore
"anyone on the lab host with `libvirt` group or vmrun access has
full control of the guests" — which is identical to "anyone who
can spawn the lab in the first place." No new exposure beyond
existing host trust.

## Recommended posture

- Keep the libvirt/VMware lab network host-only or NAT'd. Don't bridge
  it to your LAN. Don't port-forward `:8100/8200/8201/8300` off the
  host.
- Reach the MCP endpoints from the host only — either directly (the
  agent runs on the lab host) or over an SSH tunnel to the host.
- Treat the lab host the same way you'd treat any developer
  workstation running an AI agent with broad access: firewall the
  host to `:22` only, SSH-tunnel anything else.
- Don't put production data on the lab host. The Windows VMs run
  arbitrary PoC code; assume their disks are hostile.
- If you need to expose a lab endpoint to a remote operator,
  SSH-tunnel it (`ssh -L 8300:192.168.122.100:8300 host`). Do not put
  the MCP ports on a public interface even temporarily.

## Reporting an issue

There is no private vulnerability-disclosure channel set up for this
project today. If you find a footgun or a behavior that breaks the
"lab network stays private" assumption, open a GitHub issue. Please
don't include a working host or working endpoint in a public issue.
