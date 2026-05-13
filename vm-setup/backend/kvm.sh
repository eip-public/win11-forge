#!/usr/bin/env bash
#
# KVM/libvirt backend for the win11-forge lab.
#
# Sourced by setup.sh when WINFORGE_BACKEND=kvm (the default).
#
# Exposes a small VM-orchestration API the lab spawn/destroy/status flows
# rely on. Single-VM (gold-build) commands in setup.sh still call virsh
# directly — this file is only used by `cmd_lab` and friends.
#
# API:
#   Constants (set at source time):
#     TARGET_NAME, DEBUGGER_NAME       libvirt domain names
#     TARGET_IP,   DEBUGGER_IP         IPs (DHCP-pinned via libvirt dnsmasq)
#     TARGET_MAC,  DEBUGGER_MAC        MACs used for the DHCP reservation
#
#   Functions:
#     backend_name                      echo "kvm"
#     backend_preflight                 check /dev/kvm + libvirt + default network
#     backend_ensure_network            install MAC->IP DHCP reservations (idempotent)
#     vm_provision <role> <ram_mb>      create overlay + define libvirt domain
#     vm_start <role> [gui]             virsh start (gui flag opens virt-viewer)
#     vm_force_stop <role>              virsh destroy (no-op if not running)
#     vm_undefine <role>                virsh undefine + remove overlay/nvram
#     vm_state <role>                   echo running|stopped|undefined
#     vm_exists <role>                  exit 0 if domain defined
#     vm_console_open <role>            launch virt-viewer (best-effort)
#
# `role` is one of: target | debugger.

# Hard requirement: setup.sh sets these before sourcing.
: "${IMAGES_DIR:?backend/kvm.sh: IMAGES_DIR must be set}"
: "${VM_NAME:?backend/kvm.sh: VM_NAME (gold) must be set}"

# ── Backend constants ─────────────────────────────────────────────

TARGET_NAME="winforge-target"
DEBUGGER_NAME="winforge-debugger"
TARGET_IP="192.168.122.100"
DEBUGGER_IP="192.168.122.101"
TARGET_MAC="52:54:00:11:11:11"      # QEMU OUI; libvirt-friendly
DEBUGGER_MAC="52:54:00:22:22:22"

backend_name() { echo "kvm"; }

# Wrapper for "cleanup" virsh calls (destroy/undefine/snapshot-delete) that
# previously had `|| true` masking real failures. Tolerates the few legitimate
# "already in target state" cases (not running, already gone, no snapshots);
# warns to stderr on anything else so the user sees the real libvirt error
# instead of a downstream collision ("domain is already defined", etc.).
# Always returns 0 — callers should rely on the warning text, not exit code.
_kvm_virsh_or_warn() {
    # `out="$(...)"` without an `|| ...` clause would trip the caller's `set -e`
    # the moment virsh exits non-zero — *before* this function can inspect the
    # exit code and decide whether to warn or stay silent. Capture rc via the
    # `|| rc=$?` idiom instead.
    local out rc=0
    out="$(virsh "$@" 2>&1)" || rc=$?
    (( rc == 0 )) && return 0
    case "$out" in
        *"Domain not found"*|*"failed to get domain"*) ;;
        *"is not running"*|*"already inactive"*) ;;
        *"no snapshot"*|*"snapshot file does not exist"*) ;;
        *) printf '\033[1;33m[!]\033[0m kvm: virsh %s — %s\n' "$*" "${out//$'\n'/ | }" >&2 ;;
    esac
    return 0
}

# ── Role -> internal mapping ──────────────────────────────────────

_kvm_role_to_name() {
    case "$1" in
        target)   echo "$TARGET_NAME" ;;
        debugger) echo "$DEBUGGER_NAME" ;;
        *)        echo "backend/kvm.sh: unknown role '$1'" >&2; return 1 ;;
    esac
}

_kvm_role_to_mac() {
    case "$1" in
        target)   echo "$TARGET_MAC" ;;
        debugger) echo "$DEBUGGER_MAC" ;;
    esac
}

# ── Preflight ─────────────────────────────────────────────────────

backend_preflight() {
    [[ -e /dev/kvm ]] || { echo "KVM not available. Enable VT-x/AMD-V or check /dev/kvm perms." >&2; return 1; }
    command -v virsh >/dev/null    || { echo "virsh missing. Run ./install-deps.sh" >&2; return 1; }
    command -v qemu-img >/dev/null || { echo "qemu-img missing. Run ./install-deps.sh" >&2; return 1; }
    virsh net-info default >/dev/null 2>&1 \
        || { echo "libvirt 'default' network missing. sudo virsh net-autostart default && sudo virsh net-start default" >&2; return 1; }
    [[ "$(virsh net-info default 2>/dev/null | awk '/^Active:/ {print $2}')" == "yes" ]] \
        || { echo "libvirt 'default' network inactive. sudo virsh net-start default" >&2; return 1; }
}

# Add MAC->IP reservations to libvirt's default-network dnsmasq.
# Idempotent: skips entries whose MAC is already in the network XML.
backend_ensure_network() {
    local entries=(
        "$TARGET_MAC|$TARGET_IP"
        "$DEBUGGER_MAC|$DEBUGGER_IP"
    )
    local entry mac ip
    for entry in "${entries[@]}"; do
        mac="${entry%%|*}"; ip="${entry##*|}"
        if ! virsh net-dumpxml default | grep -qF "mac='$mac'"; then
            virsh net-update default add ip-dhcp-host \
                "<host mac='$mac' ip='$ip'/>" --live --config >/dev/null 2>&1 \
              || echo "[!] Could not add DHCP reservation for $mac -> $ip (may already exist)" >&2
        fi
    done
}

# ── VM lifecycle ──────────────────────────────────────────────────

vm_provision() {
    local role="$1" ram="$2"
    local vm_name; vm_name="$(_kvm_role_to_name "$role")" || return 1
    local mac;     mac="$(_kvm_role_to_mac "$role")"
    local gold="$IMAGES_DIR/${VM_NAME}-gold.qcow2"
    local overlay="$IMAGES_DIR/${vm_name}.qcow2"
    local nvram="$IMAGES_DIR/${vm_name}-OVMF_VARS.fd"

    [[ -f "$gold" ]] || { echo "No gold at $gold. Run './setup.sh install' first." >&2; return 1; }

    if virsh dominfo "$vm_name" >/dev/null 2>&1; then
        _kvm_virsh_or_warn destroy "$vm_name"
        _kvm_virsh_or_warn undefine "$vm_name" --nvram
    fi

    rm -f "$overlay" "$nvram"
    qemu-img create -f qcow2 -b "$gold" -F qcow2 "$overlay" >/dev/null
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$nvram"

    local xml; xml="$(mktemp)"
    cat >"$xml" <<XML
<domain type='kvm'>
  <name>$vm_name</name>
  <memory unit='MiB'>$ram</memory>
  <currentMemory unit='MiB'>$ram</currentMemory>
  <vcpu placement='static'>4</vcpu>
  <os firmware='efi'>
    <type arch='x86_64' machine='q35'>hvm</type>
    <firmware>
      <feature enabled='no' name='secure-boot'/>
    </firmware>
    <loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE_4M.fd</loader>
    <nvram template='/usr/share/OVMF/OVMF_VARS_4M.fd'>$nvram</nvram>
    <boot dev='hd'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough'/>
  <clock offset='localtime'><timer name='rtc' tickpolicy='catchup'/></clock>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='writeback'/>
      <source file='$overlay'/>
      <target dev='sda' bus='sata'/>
    </disk>
    <interface type='network'>
      <mac address='$mac'/>
      <source network='default'/>
      <model type='e1000e'/>
    </interface>
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>
    <video><model type='virtio'/></video>
    <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
  </devices>
</domain>
XML
    virsh define "$xml" >/dev/null
    rm -f "$xml"
}

vm_start() {
    local role="$1" mode="${2:-nogui}"
    local vm_name; vm_name="$(_kvm_role_to_name "$role")" || return 1
    virsh start "$vm_name" >/dev/null
    if [[ "$mode" == "gui" ]] && command -v virt-viewer >/dev/null 2>&1; then
        virt-viewer --connect qemu:///system "$vm_name" >/dev/null 2>&1 &
    fi
}

vm_force_stop() {
    local role="$1"
    local vm_name; vm_name="$(_kvm_role_to_name "$role")" || return 1
    if virsh dominfo "$vm_name" >/dev/null 2>&1; then
        _kvm_virsh_or_warn destroy "$vm_name"
    fi
}

vm_undefine() {
    local role="$1"
    local vm_name; vm_name="$(_kvm_role_to_name "$role")" || return 1
    if virsh dominfo "$vm_name" >/dev/null 2>&1; then
        _kvm_virsh_or_warn destroy "$vm_name"
        _kvm_virsh_or_warn undefine "$vm_name" --nvram
    fi
    rm -f "$IMAGES_DIR/${vm_name}.qcow2" "$IMAGES_DIR/${vm_name}-OVMF_VARS.fd"
}

vm_state() {
    local role="$1"
    local vm_name; vm_name="$(_kvm_role_to_name "$role")" || return 1
    local s; s="$(virsh domstate "$vm_name" 2>/dev/null)" || { echo "undefined"; return; }
    case "$s" in
        running)    echo "running" ;;
        "shut off") echo "stopped" ;;
        *)
            # paused, pmsuspended, "in shutdown", crashed, etc. Treat as "running"
            # so callers run the destroy/shutdown path (virsh destroy works on any
            # non-stopped state) instead of skipping. Matches vmware.sh's
            # three-value contract: running / stopped / undefined.
            echo "[kvm vm_state] $vm_name in non-canonical state '$s' — treating as running" >&2
            echo "running" ;;
    esac
}

vm_exists() {
    local role="$1"
    local vm_name; vm_name="$(_kvm_role_to_name "$role")" || return 1
    virsh dominfo "$vm_name" >/dev/null 2>&1
}

vm_console_open() {
    local role="$1"
    local vm_name; vm_name="$(_kvm_role_to_name "$role")" || return 1
    if command -v virt-viewer >/dev/null 2>&1; then
        virt-viewer --connect qemu:///system "$vm_name" >/dev/null 2>&1 &
    elif command -v virt-manager >/dev/null 2>&1; then
        virt-manager --connect qemu:///system --show-domain-console "$vm_name" >/dev/null 2>&1 &
    else
        echo "No virt-viewer or virt-manager installed. VNC: $(virsh vncdisplay "$vm_name" 2>/dev/null)" >&2
        return 1
    fi
}
