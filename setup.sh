#!/usr/bin/env bash
# win11-forge: standalone Windows 11 LTSC 24H2 debug VM on KVM/libvirt.
#
# Builds a gold image once, then spawns either a single VM or a kernel-debug
# pair (target + debugger) as overlays off the gold.
#
# Usage:
#   ./setup.sh [install|status|reset|start|stop|destroy|lab <subcmd>]
#
# Subcommands:
#   install      Full build: create VM from ISO, install Windows + debug
#                tools + WinDbg MCP extension, then seal into a flat gold
#                qcow2 (with restore verification).
#   status       Report VM state, IP, disk paths, and gold image.
#   reset        Replace the VM's working disk with a fresh overlay off the
#                gold image, then start it. No reinstall.
#   start        virsh start (boot current disk).
#   stop         Graceful shutdown, force after grace period.
#   destroy      Remove VM definition, working disk, unattend ISO. Keep gold.
#
#   lab spawn    Spawn the kernel-debug pair (target + debugger) via KDNET.
#                MCP loads on first BugCheck: kd prompt monitor injects
#                .load windbgmcpExt.dll; mcpstart; g on every break.
#   lab start    Start an existing lab pair without reprovisioning.
#   lab stop     Ask Windows guests to shut down, force after grace period.
#   lab reset    Destroy + respawn the pair with fresh overlays.
#   lab destroy  Tear down the pair (keeps gold, ISOs, ssh key).
#   lab status   State + IPs of the pair.
#   lab wait-kd  Reboot target if needed, then wait for KDNET connection.
#   lab load-mcp Load MCP BEFORE the first crash for pre-crash debugging.
#                Calls NtSystemDebugControl(SysDbgBreakPoint=6) on the target
#                (kernel int 3 via KDNET). Requires: lab up, target SSH up.
#
# Environment overrides:
#   VM_NAME    libvirt domain name for single-VM mode (default: winforge-win11-24h2)
#   VM_RAM     RAM in MB (default: 8192)
#   VM_CPUS    vCPU count (default: 4)
#   DISK_SIZE  qcow2 size (default: 64G)
#   VM_IP      expected IP (default: 192.168.122.100 — via DHCP host reservation)

set -euo pipefail

# Always target the system libvirtd (not qemu:///session, which is per-user
# and has no default network). If the current shell isn't in the libvirt
# group yet (usermod -aG only takes effect on new logins), re-exec under
# 'sg libvirt' so our child scripts inherit the group membership too.
export LIBVIRT_DEFAULT_URI=qemu:///system
if ! virsh list >/dev/null 2>&1; then
    if getent group libvirt 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | grep -qx "${USER:-$(id -un)}"; then
        exec sg libvirt -c "$(printf '%q ' "$0" "$@")"
    fi
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_SETUP="$ROOT/vm-setup"
UNATTEND_DIR="$ROOT/unattend-iso"
IMAGES_DIR="$ROOT/vm-images"
ISOS_DIR="$ROOT/isos"
SSH_KEY="$ROOT/vm-ssh-key"

# Shared VM defaults (VM_CPUS, DISK_SIZE, VM_USER, VM_PASS, VM_IP, VM_MAC).
# Profile-specific values (VM_NAME, VM_RAM for the gold-build profile) below.
# shellcheck source=vm-setup/lib/defaults.sh
. "$VM_SETUP/lib/defaults.sh"

# Gold-build profile (single-VM, KVM-only — virt-install pipeline).
# WINFORGE_BACKEND only affects the kernel-debug lab pair, not this profile.
VM_NAME="${VM_NAME:-winforge-win11-24h2}"
VM_RAM="${VM_RAM:-8192}"

# Kernel-debug lab backend: kvm (default) or vmware. Sourced below; provides
# vm_provision/start/stop/state, backend_preflight, backend_ensure_network,
# and the constants TARGET_NAME/IP/MAC + DEBUGGER_NAME/IP/MAC.
WINFORGE_BACKEND="${WINFORGE_BACKEND:-kvm}"
case "$WINFORGE_BACKEND" in
    kvm|vmware) ;;
    *) printf '\033[1;31m[-]\033[0m WINFORGE_BACKEND must be kvm or vmware (got: %s)\n' "$WINFORGE_BACKEND" >&2; exit 1 ;;
esac
# shellcheck source=vm-setup/backend/kvm.sh
source "$VM_SETUP/backend/$WINFORGE_BACKEND.sh"

WIN_ISO_NAME="win11-ltsc-24h2.iso"
VIRTIO_ISO_NAME="virtio-win.iso"

# ── logging ────────────────────────────────────────────────────────

log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2; exit 1; }

# ── preflight ──────────────────────────────────────────────────────

preflight() {
    log "Preflight checks"

    [[ -e /dev/kvm ]] || die "KVM not available. Enable VT-x/AMD-V in BIOS or check /dev/kvm perms."

    local missing=()
    for bin in virsh virt-install qemu-img genisoimage sshpass python3 ssh-keygen; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing tools: ${missing[*]}"
        warn "Install with: sudo apt-get install -y libvirt-daemon-system libvirt-clients virtinst qemu-utils genisoimage sshpass"
        die "Install the missing tools and re-run."
    fi

    virsh net-info default >/dev/null 2>&1 || die "libvirt 'default' network missing. Run: sudo virsh net-autostart default && sudo virsh net-start default"
    [[ "$(virsh net-info default 2>/dev/null | awk '/^Active:/ {print $2}')" == "yes" ]] || \
        die "libvirt 'default' network not active. Run: sudo virsh net-start default"

    ensure_dhcp_reservations

    ok "Host ready"
}

# Add the gold MAC -> IP reservation to libvirt's default-network dnsmasq so
# the install/single-VM flow always lands on a predictable IP. The lab path
# adds its own reservations via backend_ensure_network. Idempotent.
ensure_dhcp_reservations() {
    if ! virsh net-dumpxml default | grep -qF "mac='$VM_MAC'"; then
        virsh net-update default add ip-dhcp-host \
            "<host mac='$VM_MAC' ip='$VM_IP'/>" --live --config >/dev/null 2>&1 \
          || warn "Could not add DHCP reservation for $VM_MAC -> $VM_IP (may already exist)"
    fi
}

stage_isos() {
    log "Staging ISOs"
    local f
    for f in "$WIN_ISO_NAME" "$VIRTIO_ISO_NAME"; do
        if [[ ! -f "$IMAGES_DIR/$f" && -f "$ISOS_DIR/$f" ]]; then
            mv -v "$ISOS_DIR/$f" "$IMAGES_DIR/$f"
        fi
    done
    [[ -f "$IMAGES_DIR/$WIN_ISO_NAME"    ]] || die "Missing $IMAGES_DIR/$WIN_ISO_NAME (download from https://go.microsoft.com/fwlink/?linkid=2270353)"
    [[ -f "$IMAGES_DIR/$VIRTIO_ISO_NAME" ]] || die "Missing $IMAGES_DIR/$VIRTIO_ISO_NAME (download from https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso)"

    rmdir "$ISOS_DIR" 2>/dev/null || true
    ok "ISOs staged in $IMAGES_DIR"
}

ensure_ssh_key() {
    if [[ ! -f "$SSH_KEY" ]]; then
        log "Generating SSH key $SSH_KEY"
        ssh-keygen -t ed25519 -f "$SSH_KEY" -N '' -q
    fi
}

# Undefine any stale `winforge-*` libvirt domains that hold VM_MAC, so
# virt-install doesn't refuse with "MAC address is in use". Errors (not
# auto-cleans) if a domain holding the MAC is either currently running or
# doesn't match the winforge-* namespace — those are not our call to kill.
preflight_clean_mac_collisions() {
    local vm state
    local winforge_stale=() foreign=() running=()
    for vm in $(virsh list --all --name 2>/dev/null); do
        [[ -z "$vm" ]] && continue
        virsh dumpxml "$vm" 2>/dev/null | grep -qF "address='$VM_MAC'" || continue
        state="$(virsh domstate "$vm" 2>/dev/null)"
        if [[ "$state" == "running" ]]; then
            running+=("$vm")
        elif [[ "$vm" == winforge-* ]]; then
            winforge_stale+=("$vm")
        else
            foreign+=("$vm")
        fi
    done
    if [[ ${#running[@]} -gt 0 ]]; then
        die "Running domain(s) hold $VM_MAC: ${running[*]}. Stop them first (./setup.sh lab destroy, or virsh destroy <name>)."
    fi
    if [[ ${#foreign[@]} -gt 0 ]]; then
        die "Non-winforge domain(s) hold $VM_MAC: ${foreign[*]}. Refusing to auto-clean — free the MAC before installing."
    fi
    if [[ ${#winforge_stale[@]} -gt 0 ]]; then
        log "Clearing stale winforge-* domains on $VM_MAC: ${winforge_stale[*]}"
        for vm in "${winforge_stale[@]}"; do
            virsh undefine "$vm" --nvram >/dev/null 2>&1 \
                || warn "Failed to undefine $vm (may leave MAC collision)"
        done
        ok "MAC collisions cleared"
    fi
}

preflight_lab_mac_collisions() {
    [[ "$WINFORGE_BACKEND" == "kvm" ]] || return 0

    local vm state
    local running=() foreign=() stale=()
    for vm in $(virsh list --all --name 2>/dev/null); do
        [[ -z "$vm" ]] && continue
        [[ "$vm" == "$TARGET_NAME" || "$vm" == "$DEBUGGER_NAME" ]] && continue
        virsh dumpxml "$vm" 2>/dev/null | grep -Eq "address='($TARGET_MAC|$DEBUGGER_MAC)'" || continue

        state="$(virsh domstate "$vm" 2>/dev/null || echo unknown)"
        if [[ "$state" == "running" ]]; then
            running+=("$vm")
        elif [[ "$vm" == winforge-* ]]; then
            stale+=("$vm")
        else
            foreign+=("$vm")
        fi
    done

    if [[ ${#running[@]} -gt 0 ]]; then
        die "Running domain(s) hold $TARGET_MAC or $DEBUGGER_MAC: ${running[*]}. Stop them first (for the single VM: ./setup.sh stop)."
    fi
    if [[ ${#foreign[@]} -gt 0 ]]; then
        die "Defined non-lab domain(s) hold $TARGET_MAC or $DEBUGGER_MAC: ${foreign[*]}. Undefine or change their MACs before lab spawn."
    fi
    if [[ ${#stale[@]} -gt 0 ]]; then
        log "Clearing stopped winforge-* domain(s) on lab MACs: ${stale[*]}"
        for vm in "${stale[@]}"; do
            virsh undefine "$vm" --nvram >/dev/null 2>&1 \
                || die "Failed to undefine stale domain $vm holding a lab MAC"
        done
    fi
}

# ── subcommands ────────────────────────────────────────────────────

cmd_install() {
    preflight
    preflight_clean_mac_collisions
    stage_isos
    ensure_ssh_key

    log "Running create-vm.sh ($VM_NAME, ${VM_RAM}MB, $VM_CPUS vCPU, $DISK_SIZE disk)"
    "$VM_SETUP/create-vm.sh" \
        --iso "$IMAGES_DIR/$WIN_ISO_NAME" \
        --name "$VM_NAME" \
        --mac "$VM_MAC" \
        --ram "$VM_RAM" \
        --cpus "$VM_CPUS" \
        --disk-size "$DISK_SIZE"

    log "Running seal-vm-gold.sh ($VM_NAME at $VM_IP)"
    # --skip-setup: create-vm.sh already ran setup-vm.sh; no need to rerun.
    "$VM_SETUP/seal-vm-gold.sh" \
        --vm "$VM_NAME" \
        --ip "$VM_IP" \
        --user "$VM_USER" \
        --password "$VM_PASS" \
        --ssh-key "$SSH_KEY" \
        --skip-setup \
        --verify-restore

    ok "Install complete"
    cmd_status
}

cmd_status() {
    printf '\n'
    printf '  VM name       : %s\n' "$VM_NAME"
    printf '  Domain state  : %s\n' "$(virsh domstate "$VM_NAME" 2>/dev/null || echo 'not defined')"
    printf '  IP (static)   : %s\n' "$VM_IP"
    printf '  SSH user/pass : %s / %s\n' "$VM_USER" "$VM_PASS"
    printf '  SSH key       : %s\n' "$SSH_KEY"
    printf '\n'
    printf '  Disks:\n'
    for f in "$IMAGES_DIR/$VM_NAME.qcow2" "$IMAGES_DIR/${VM_NAME}-gold.qcow2" "$IMAGES_DIR/${VM_NAME}.seal-verify.qcow2"; do
        if [[ -f "$f" ]]; then
            printf '    %-60s %s\n' "$(basename "$f")" "$(du -h "$f" | awk '{print $1}')"
        fi
    done
    printf '\n'
    printf '  ISOs:\n'
    for f in "$IMAGES_DIR/$WIN_ISO_NAME" "$IMAGES_DIR/$VIRTIO_ISO_NAME" "$IMAGES_DIR/unattend.iso"; do
        if [[ -f "$f" ]]; then
            printf '    %-60s %s\n' "$(basename "$f")" "$(du -h "$f" | awk '{print $1}')"
        fi
    done
    printf '\n'
    if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
        printf '  virsh vncdisplay: %s\n' "$(virsh vncdisplay "$VM_NAME" 2>/dev/null || echo 'n/a')"
    fi
    printf '\n'
}

cmd_reset() {
    local gold="$IMAGES_DIR/${VM_NAME}-gold.qcow2"
    local working="$IMAGES_DIR/${VM_NAME}.qcow2"
    [[ -f "$gold" ]] || die "No gold image at $gold. Run './setup.sh install' first."

    virsh dominfo "$VM_NAME" >/dev/null 2>&1 || die "VM $VM_NAME not defined. Run './setup.sh install' first."

    log "Shutting down $VM_NAME if running"
    if [[ "$(virsh domstate "$VM_NAME" 2>/dev/null)" == "running" ]]; then
        virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
    fi

    log "Replacing working disk with fresh overlay off gold"
    rm -f "$working"
    qemu-img create -f qcow2 -b "$gold" -F qcow2 "$working" >/dev/null
    ok "Fresh overlay: $working"

    # Rewrite the VM's disk source to point at the new overlay.
    local tmp
    tmp="$(mktemp)"
    virsh dumpxml "$VM_NAME" > "$tmp"
    python3 - "$tmp" "$working" <<'PY'
import sys, xml.etree.ElementTree as ET
path, disk = sys.argv[1], sys.argv[2]
t = ET.parse(path); r = t.getroot()
for d in r.findall("./devices/disk"):
    if d.get("device") != "disk": continue
    s = d.find("source")
    if s is None: raise SystemExit("disk source missing")
    s.set("file", disk); break
else:
    raise SystemExit("disk not found")
t.write(path, encoding="unicode")
PY
    virsh define "$tmp" >/dev/null
    rm -f "$tmp"

    log "Starting $VM_NAME"
    virsh start "$VM_NAME" >/dev/null
    ok "Reset complete. SSH: ssh -i $SSH_KEY $VM_USER@$VM_IP"
}

cmd_start() {
    virsh dominfo "$VM_NAME" >/dev/null 2>&1 || die "VM $VM_NAME not defined."
    virsh start "$VM_NAME" 2>&1 || true
    cmd_status
}

cmd_stop() {
    virsh dominfo "$VM_NAME" >/dev/null 2>&1 || die "VM $VM_NAME not defined."
    log "Graceful shutdown (60s grace)"
    virsh shutdown "$VM_NAME" 2>&1 || true
    local i
    for i in $(seq 1 12); do
        [[ "$(virsh domstate "$VM_NAME" 2>/dev/null)" == "shut off" ]] && { ok "Stopped"; return; }
        sleep 5
    done
    warn "Grace period expired — forcing off"
    virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
    ok "Stopped (forced)"
}

cmd_destroy() {
    log "Destroying $VM_NAME (keeping gold image, ISOs, SSH key)"
    if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
        virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
        for snap in $(virsh snapshot-list "$VM_NAME" --name 2>/dev/null); do
            virsh snapshot-delete "$VM_NAME" "$snap" --metadata 2>/dev/null || true
        done
        virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
    fi
    rm -f "$IMAGES_DIR/${VM_NAME}.qcow2" "$IMAGES_DIR/${VM_NAME}.seal-verify.qcow2" "$IMAGES_DIR/unattend.iso"
    ok "Destroyed"
}

# ── kernel-debug lab (target + debugger pair) ─────────────────────
#
# Lifecycle is delegated to the backend (kvm.sh / vmware.sh) — see those
# files for the per-hypervisor implementation. This file only orchestrates:
# provision, start, run role-bootstrap-*.sh, wait for SSH/HTTP.

_lab_wait_ssh() {
    # `timeout 10` caps each attempt — ConnectTimeout=3 only covers TCP SYN.
    # Without this, one hung post-auth session (observed during Windows first-
    # boot warmup) would deadlock the whole loop, since the `&&` blocks until
    # ssh returns and the sleep never fires.
    local ip="$1" label="$2" i
    for i in $(seq 1 60); do
        timeout 10 sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=3 -o LogLevel=ERROR "$VM_USER@$ip" 'echo ok' >/dev/null 2>&1 \
            && { ok "$label SSH up at $ip"; return 0; }
        sleep 5
    done
    die "$label SSH never came up at $ip"
}

cmd_lab() {
    local sub="${1:-spawn}"; shift 2>/dev/null || true
    # --gui / --nogui flags (consumed by spawn/start/reset; ignored elsewhere).
    # Default: gui for vmware (the user likely picked it *to* see the console);
    # nogui for kvm (headless is the libvirt/virt-manager convention).
    local arg default_gui=0
    [[ "$WINFORGE_BACKEND" == "vmware" ]] && default_gui=1
    LAB_SPAWN_GUI="${LAB_SPAWN_GUI:-$default_gui}"
    local -a rest=()
    for arg in "$@"; do
        case "$arg" in
            --gui)   LAB_SPAWN_GUI=1 ;;
            --nogui) LAB_SPAWN_GUI=0 ;;
            *)       rest+=("$arg") ;;
        esac
    done
    if ((${#rest[@]})); then set -- "${rest[@]}"; else set --; fi
    case "$sub" in
        spawn)     _lab_spawn ;;
        start)     _lab_start ;;
        stop)      _lab_stop ;;
        reset)     _lab_destroy; _lab_spawn ;;
        destroy)   _lab_destroy ;;
        status)    _lab_status ;;
        wait-kd)   _lab_wait_kd ;;
        load-mcp)  _lab_load_mcp ;;
        console)
            local role="${1:-}"
            [[ "$role" == "target" || "$role" == "debugger" ]] \
                || die "lab console <target|debugger>"
            vm_console_open "$role" || die "Could not open console for $role"
            ;;
        *)         die "lab: unknown subcommand '$sub' (try: spawn [--gui|--nogui]|start [--gui|--nogui]|stop|reset [--gui|--nogui]|destroy|status|wait-kd|load-mcp|console <target|debugger>)" ;;
    esac
}

_lab_kd_connected() {
    timeout 10 ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=3 -o LogLevel=ERROR "$VM_USER@$DEBUGGER_IP" \
        'cmd /c findstr /C:"KDNET connected to target" C:\winforge\logs\kd_wrapper.log' \
        >/dev/null 2>&1
}

_lab_wait_kd() {
    log "Checking lab state ($WINFORGE_BACKEND)"
    vm_exists target   || die "$TARGET_NAME not defined. Run: ./setup.sh lab spawn"
    vm_exists debugger || die "$DEBUGGER_NAME not defined"
    [[ "$(vm_state target)"   == "running" ]] || die "Target not running"
    [[ "$(vm_state debugger)" == "running" ]] || die "Debugger not running"

    log "Waiting for debugger SSH..."
    _lab_wait_ssh "$DEBUGGER_IP" "debugger"

    if _lab_kd_connected; then
        ok "KDNET already connected"
        return 0
    fi

    log "KDNET not connected yet; rebooting target so it syncs with kd.exe"
    timeout 10 ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=3 -o LogLevel=ERROR "$VM_USER@$TARGET_IP" \
        'shutdown /r /t 0 /f' >/dev/null 2>&1 || true

    log "Waiting for target SSH after reboot..."
    _lab_wait_ssh "$TARGET_IP" "target"

    log "Waiting for KDNET connection in kd_wrapper.log (up to 180s)..."
    local i
    for i in $(seq 1 60); do
        _lab_kd_connected && { ok "KDNET connected"; return 0; }
        sleep 3
    done

    warn "KDNET did not connect within 180s"
    warn "Check C:\\winforge\\logs\\kd_wrapper.log on $DEBUGGER_IP"
    die "KDNET wait failed"
}

_lab_mcp_http_live() {
    local http_status
    http_status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 \
        -X POST "http://$DEBUGGER_IP:8100/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' \
        2>/dev/null) || true
    [[ "$http_status" == "200" ]]
}

_lab_load_mcp() {
    # Bring WinDbg MCP online BEFORE the first crash.
    #
    # Mechanism: call NtSystemDebugControl(SysDbgBreakPoint=6) on the TARGET as
    # SYSTEM. This fires a kernel int 3 that kd.exe catches over KDNET. The
    # prompt monitor in kd_wrapper.py sees the kd> prompt and injects
    # .load + mcpstart + g. MCP is then live while the target continues running.
    #
    # SysDbgBreakPoint=6 is documented in the SYSDBG_COMMAND enum (ntdoc.m417z.com)
    # and confirmed by ReactOS dbgctrl.c. Requires SeDebugPrivilege (SYSTEM has it).
    #
    # Hypervisor-agnostic: works under any backend that fronts a Windows VM with
    # SSH on $TARGET_IP and a kd.exe waiting on $DEBUGGER_IP:50000.
    #
    # Requires: lab pair running, kd connected, target SSH up.

    log "Checking lab state ($WINFORGE_BACKEND)"
    vm_exists target   || die "$TARGET_NAME not defined. Run: ./setup.sh lab spawn"
    vm_exists debugger || die "$DEBUGGER_NAME not defined"
    [[ "$(vm_state target)"   == "running" ]] || die "Target not running"
    [[ "$(vm_state debugger)" == "running" ]] || die "Debugger not running"

    _lab_wait_kd

    if _lab_mcp_http_live; then
        ok "MCP endpoint already live — no kernel break needed"
        printf '  MCP endpoint: http://%s:%s/mcp\n' "$DEBUGGER_IP" "8100"
        return 0
    fi

    # Verify target SSH is up — kernel must be fully initialized before breaking.
    # timeout 10 around each attempt guards against a hung single session
    # (see _lab_wait_ssh comment for the underlying failure mode).
    log "Waiting for target SSH (confirms kernel fully initialized)..."
    local i ssh_up=false
    for i in $(seq 1 24); do
        timeout 10 sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=3 -o LogLevel=ERROR "$VM_USER@$TARGET_IP" 'echo ok' \
            >/dev/null 2>&1 && { ssh_up=true; break; }
        sleep 5
    done
    $ssh_up || die "Target SSH not up — wait for full boot first"

    # Trigger kernel break via NtSystemDebugControl(SysDbgBreakPoint=6) on the target.
    # Multi-line PowerShell fails over SSH (cmd.exe shell): SCP the script and run it.
    log "Triggering kernel debug break via NtSystemDebugControl on target..."
    sshpass -p "$VM_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR "$ROOT/vm-setup/kd_break.ps1" \
        "$VM_USER@$TARGET_IP:C:/winforge/kd_break.ps1" >/dev/null 2>&1 \
        || die "Failed to SCP kd_break.ps1 to target"
    local break_result
    break_result=$(sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=3 -o ServerAliveCountMax=10 \
        -o ConnectTimeout=10 -o LogLevel=ERROR \
        "$VM_USER@$TARGET_IP" \
        'powershell -NoProfile -ExecutionPolicy Bypass -File C:\winforge\kd_break.ps1' 2>/dev/null)

    if [[ "$break_result" == "OK" ]]; then
        ok "Kernel break fired (NtSystemDebugControl returned STATUS_SUCCESS)"
    else
        warn "NtSystemDebugControl returned: ${break_result:-<no output>}"
        warn "This may mean kd is not attached yet or SeDebugPrivilege is not enabled"
        die "Kernel break failed — check that kd is connected to the target"
    fi

    # Wait for MCP HTTP endpoint — kd_wrapper.py starts it once the pipe appears.
    # Poll the HTTP port directly: more reliable than Test-Path "\\.\pipe\..." which
    # silently returns nothing for the \\.\device namespace in PowerShell.
    #
    # Timing note: the .load + mcpstart sequence can take 2+ minutes from the
    # break to the pipe appearing (extension DLL load is slow on first use, and
    # FastMCP import pulls in a lot of Python). 60s was observed to be too short
    # in practice — bumped to 180s with 3s intervals.
    log "Waiting for MCP HTTP endpoint (up to 180s)..."
    local mcp_up=false
    for i in $(seq 1 60); do
        _lab_mcp_http_live && { mcp_up=true; break; }
        sleep 3
    done

    if $mcp_up; then
        ok "MCP endpoint live — extension loaded and HTTP server running"
        printf '  MCP endpoint: http://%s:%s/mcp\n' "$DEBUGGER_IP" "8100"
        printf '  Target still running — use MCP to set breakpoints before triggering the bug\n'
    else
        warn "MCP endpoint did not come up within 180s"
        warn "Check kd_wrapper.log on $DEBUGGER_IP for errors"
        die "MCP load failed — HTTP endpoint not responding after break"
    fi
}

_lab_spawn() {
    local gui_mode="nogui"
    if [[ "${LAB_SPAWN_GUI:-}" == "1" ]]; then gui_mode="gui"; fi

    backend_preflight  || die "Backend preflight failed ($WINFORGE_BACKEND)"
    backend_ensure_network
    preflight_lab_mac_collisions
    ensure_ssh_key
    [[ -f "$IMAGES_DIR/${VM_NAME}-gold.qcow2" ]] || die "No gold image. Run './setup.sh install' first."

    log "Provisioning $TARGET_NAME (backend=$WINFORGE_BACKEND, ip=$TARGET_IP)"
    vm_provision target   8192
    log "Provisioning $DEBUGGER_NAME (backend=$WINFORGE_BACKEND, ip=$DEBUGGER_IP)"
    vm_provision debugger 4096

    # Ordering rationale:
    # Both VMs get their IPs from MAC-pinned DHCP reservations (libvirt dnsmasq
    # for KVM, vmnet8 dhcpd for VMware) so we know the IP before the VM boots.
    # We start target first, bootstrap it (KDNET bcdedit + reboot), then start
    # the debugger so kd_wrapper.py is running and waiting before target sends
    # its first KDNET sync packet on the next boot.

    log "Starting target ($gui_mode)"
    vm_start target "$gui_mode"
    _lab_wait_ssh "$TARGET_IP" "target"

    log "Configuring target role (KDNET bcdedit, debugger=$DEBUGGER_IP)"
    "$VM_SETUP/role-bootstrap-target.sh" "$TARGET_IP" "$SSH_KEY" "$DEBUGGER_IP"

    log "Starting debugger ($gui_mode)"
    vm_start debugger "$gui_mode"
    _lab_wait_ssh "$DEBUGGER_IP" "debugger"

    log "Configuring debugger role (kd.exe KDNET, MCP HTTP)"
    "$VM_SETUP/role-bootstrap-debugger.sh" "$DEBUGGER_IP" "$SSH_KEY"

    ok "Lab VMs up. Immediate MCP endpoints are live; :8100 comes up after first break (lab load-mcp)."
    printf '  target   : ssh -i %s %s@%s\n' "$SSH_KEY" "$VM_USER" "$TARGET_IP"
    printf '  debugger : ssh -i %s %s@%s\n' "$SSH_KEY" "$VM_USER" "$DEBUGGER_IP"
    printf '\n'
    printf '  Next: wait for KDNET if you need kernel debugging:\n'
    printf '    ./setup.sh lab wait-kd\n'
    printf '\n'
    _lab_mcp_table
}

# Canonical MCP endpoint table — single source of truth for _lab_spawn and
# _lab_status (which previously printed two divergent tables with different
# caveats).
_lab_mcp_table() {
    printf '  MCP (target):   http://%s:8300/mcp/ mcp-windbg (user-mode debug, LIVE after spawn)\n'  "$TARGET_IP"
    printf '  MCP (target):   http://%s:8200/mcp  DesktopCommander\n'                                "$TARGET_IP"
    printf '  MCP (debugger): http://%s:8201/mcp  DesktopCommander\n'                                "$DEBUGGER_IP"
    printf '  MCP (debugger): http://%s:8100/mcp  WinDbg kernel (live after first crash or load-mcp)\n' "$DEBUGGER_IP"
}

_lab_start_role() {
    local role="$1" ip="$2" label="$3" gui_mode="$4"
    vm_exists "$role" || die "$label VM not defined. Run: ./setup.sh lab spawn"
    if [[ "$(vm_state "$role")" == "running" ]]; then
        ok "$label already running"
    else
        log "Starting $label ($gui_mode)"
        vm_start "$role" "$gui_mode"
    fi
    _lab_wait_ssh "$ip" "$label"
}

_lab_start() {
    local gui_mode="nogui"
    if [[ "${LAB_SPAWN_GUI:-}" == "1" ]]; then gui_mode="gui"; fi

    backend_preflight || die "Backend preflight failed ($WINFORGE_BACKEND)"
    _lab_start_role debugger "$DEBUGGER_IP" "debugger" "$gui_mode"
    _lab_start_role target "$TARGET_IP" "target" "$gui_mode"

    ok "Lab VMs started"
    printf '  target   : ssh -i %s %s@%s\n' "$SSH_KEY" "$VM_USER" "$TARGET_IP"
    printf '  debugger : ssh -i %s %s@%s\n' "$SSH_KEY" "$VM_USER" "$DEBUGGER_IP"
    printf '  Next: ./setup.sh lab wait-kd\n'
}

_lab_shutdown_role() {
    local role="$1" ip="$2" label="$3" grace="$4"
    vm_exists "$role" || { warn "$label VM not defined"; return 0; }
    if [[ "$(vm_state "$role")" != "running" ]]; then
        ok "$label already stopped"
        return 0
    fi

    log "Asking $label Windows guest to shut down"
    timeout 15 sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -o LogLevel=ERROR "$VM_USER@$ip" \
        'shutdown /s /t 0 /f' >/dev/null 2>&1 \
        || warn "$label guest shutdown command failed; will force off if it remains running"

    local waited=0
    while (( waited < grace )); do
        [[ "$(vm_state "$role")" != "running" ]] && { ok "$label stopped"; return 0; }
        sleep 5
        waited=$((waited + 5))
    done

    warn "$label did not stop within ${grace}s; forcing off"
    vm_force_stop "$role"
    ok "$label stopped (forced)"
}

_lab_stop() {
    local grace="${LAB_STOP_GRACE:-120}"
    [[ "$grace" =~ ^[0-9]+$ ]] || die "LAB_STOP_GRACE must be a number of seconds"

    log "Stopping lab pair (backend=$WINFORGE_BACKEND, grace=${grace}s)"
    _lab_shutdown_role target "$TARGET_IP" "target" "$grace"
    _lab_shutdown_role debugger "$DEBUGGER_IP" "debugger" "$grace"
    ok "Lab stopped"
}

_lab_destroy() {
    log "Tearing down lab pair (backend=$WINFORGE_BACKEND)"
    vm_undefine target
    vm_undefine debugger
    ok "Lab torn down"
}

_lab_status() {
    printf '\n  Backend: %s\n' "$WINFORGE_BACKEND"
    printf '  Lab VMs:\n'
    printf '    %-28s %-15s %s\n' "$TARGET_NAME"   "$TARGET_IP"   "$(vm_state target   2>/dev/null || echo 'not defined')"
    printf '    %-28s %-15s %s\n' "$DEBUGGER_NAME" "$DEBUGGER_IP" "$(vm_state debugger 2>/dev/null || echo 'not defined')"
    _lab_mcp_table
    printf '  KDNET:          target port 50000, key 1.2.3.4 (kd auto-connects on target boot)\n\n'
}

# ── main ───────────────────────────────────────────────────────────

cmd="${1:-install}"
shift 2>/dev/null || true
case "$cmd" in
    install|status|reset|start|stop|destroy) "cmd_$cmd" ;;
    lab) cmd_lab "$@" ;;
    -h|--help|help)
        # Stop at `set -[E]euo pipefail` — tolerant of an eventual -Eeuo sweep
        # that the audit flagged as missing.
        sed -n '2,/^set -.*euo/p' "$0" | sed 's/^# \?//' | head -n -2
        ;;
    *) die "Unknown subcommand: $cmd (try: install|status|reset|start|stop|destroy|lab <spawn|start|stop|reset|destroy|status>)" ;;
esac
