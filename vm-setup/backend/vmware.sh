#!/usr/bin/env bash
#
# VMware Workstation backend for the win11-forge lab.
#
# Sourced by setup.sh when WINFORGE_BACKEND=vmware.
#
# Strategy: the gold qcow2 is built once via the KVM install pipeline. Every
# spawn lazily ensures gold.vmdk is up-to-date (auto-converts if the qcow2 is
# newer), takes a base snapshot of the gold .vmx (idempotent), then linked-
# clones target/debugger from that snapshot. MACs are pinned in each clone's
# .vmx so vmnet8's dhcpd hands them the same .100/.101 IPs every time.
#
# Same API as backend/kvm.sh — see that file for the contract.

: "${IMAGES_DIR:?backend/vmware.sh: IMAGES_DIR must be set}"
: "${VM_NAME:?backend/vmware.sh: VM_NAME (gold) must be set}"
: "${VM_SETUP:?backend/vmware.sh: VM_SETUP must be set}"

# ── Backend constants ─────────────────────────────────────────────

# vmnet8 default subnet on Ubuntu installs is 172.16.x.0/24 with the host at .1
# and DHCP range .128-.254 — leaving .100/.101 free for static reservations.
# Detect the subnet from the live interface so we work even if the user has
# customized vmnet8 to a different subnet.
_vmware_detect_vmnet8_subnet() {
    local cidr; cidr="$(ip -br -4 addr show vmnet8 2>/dev/null | awk '{print $3}' | head -1)"
    [[ -z "$cidr" ]] && return 1
    # cidr looks like "172.16.87.1/24" -> echo "172.16.87"
    echo "${cidr%.*/*}"
}
_VMWARE_SUBNET="$(_vmware_detect_vmnet8_subnet)" || _VMWARE_SUBNET="172.16.87"

TARGET_NAME="winforge-target"
DEBUGGER_NAME="winforge-debugger"
TARGET_IP="${_VMWARE_SUBNET}.100"
DEBUGGER_IP="${_VMWARE_SUBNET}.101"
# VMware uses its own OUI (00:50:56:xx:xx:xx) for static MACs; the
# auto-generated range is reserved by vmrun. Pinning these lets vmnet8 dhcpd
# hand out matching .100/.101 reservations.
# shellcheck source=../lib/macs.env
. "$(dirname "${BASH_SOURCE[0]}")/../lib/macs.env"
TARGET_MAC="$VMWARE_TARGET_MAC"
DEBUGGER_MAC="$VMWARE_DEBUGGER_MAC"

VMWARE_DIR="$IMAGES_DIR/vmware"
GOLD_VMX="$VMWARE_DIR/${VM_NAME}-gold/${VM_NAME}-gold.vmx"
GOLD_VMDK="$VMWARE_DIR/${VM_NAME}-gold/${VM_NAME}-gold.vmdk"
GOLD_QCOW2="$IMAGES_DIR/${VM_NAME}-gold.qcow2"
BASE_SNAPSHOT="winforge-base"

backend_name() { echo "vmware"; }

# ── Role -> internal mapping ──────────────────────────────────────

_vmware_role_to_name() {
    case "$1" in
        target)   echo "$TARGET_NAME" ;;
        debugger) echo "$DEBUGGER_NAME" ;;
        *)        echo "backend/vmware.sh: unknown role '$1'" >&2; return 1 ;;
    esac
}

_vmware_role_to_mac() {
    case "$1" in
        target)   echo "$TARGET_MAC" ;;
        debugger) echo "$DEBUGGER_MAC" ;;
    esac
}

_vmware_vmx_path() {
    local name; name="$(_vmware_role_to_name "$1")" || return 1
    echo "$VMWARE_DIR/$name/$name.vmx"
}

# ── Preflight ─────────────────────────────────────────────────────

backend_preflight() {
    command -v vmrun >/dev/null    || { echo "vmrun missing. Install VMware Workstation." >&2; return 1; }
    command -v qemu-img >/dev/null || { echo "qemu-img missing. apt install qemu-utils" >&2; return 1; }
    [[ -x "$VM_SETUP/qcow2-to-vmware.sh" ]] \
        || { echo "$VM_SETUP/qcow2-to-vmware.sh missing or not executable" >&2; return 1; }
    ip -br addr show vmnet8 >/dev/null 2>&1 \
        || { echo "vmnet8 interface not present. Is VMware Workstation set up? sudo vmware-networks --start" >&2; return 1; }

    # Re-detect vmnet8 subnet now that we've confirmed the interface is up.
    # The source-time detection at the top of this file may have hit the
    # hardcoded 172.16.87 fallback if vmnet8 wasn't ready yet — and
    # TARGET_IP/DEBUGGER_IP were frozen against that wrong subnet, pointing
    # future operations at the wrong addresses. Re-check now and patch the
    # globals if they drifted.
    local detected
    if detected="$(_vmware_detect_vmnet8_subnet)" && [[ -n "$detected" && "$detected" != "$_VMWARE_SUBNET" ]]; then
        echo "[*] vmware: vmnet8 subnet is $detected (source-time detection saw '$_VMWARE_SUBNET'; patching)" >&2
        _VMWARE_SUBNET="$detected"
        TARGET_IP="${_VMWARE_SUBNET}.100"
        DEBUGGER_IP="${_VMWARE_SUBNET}.101"
    fi
}

# Verify that the .100/.101 DHCP reservations are present in vmnet8 dhcpd.conf.
# Pinning requires sudo + a daemon restart, so it's done once by
# install-deps.sh (vmware subcommand) — not on every spawn.
backend_ensure_network() {
    local conf=/etc/vmware/vmnet8/dhcpd/dhcpd.conf
    [[ -r "$conf" ]] || { echo "$conf unreadable — VMware dhcpd config missing?" >&2; return 1; }
    local missing=()
    grep -qF "$TARGET_MAC"   "$conf" 2>/dev/null || missing+=("target ($TARGET_MAC -> $TARGET_IP)")
    grep -qF "$DEBUGGER_MAC" "$conf" 2>/dev/null || missing+=("debugger ($DEBUGGER_MAC -> $DEBUGGER_IP)")
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "[!] vmnet8 dhcpd reservations missing: ${missing[*]}" >&2
        echo "    Run once: ./install-deps.sh vmware" >&2
        return 1
    fi
}

_vmware_gui_running() {
    pgrep -u "$(id -u)" -x vmware >/dev/null 2>&1
}

_vmware_require_gui() {
    if _vmware_gui_running; then
        return 0
    fi

    if command -v gtk-launch >/dev/null 2>&1; then
        gtk-launch vmware-workstation >/dev/null 2>&1 || true
        for _ in $(seq 1 10); do
            _vmware_gui_running && return 0
            sleep 1
        done
    fi

    cat >&2 <<EOF
[-] VMware Workstation GUI is not running for user $(id -un).
    Open VMware Workstation in your desktop session, then re-run this command.
    For headless operation, pass --nogui after validating VMware nogui startup on this host.
EOF
    return 1
}

# ── Gold management ───────────────────────────────────────────────

# Convert gold.qcow2 to gold.vmdk if vmdk is missing or older than the qcow2.
# Two guards on the regen path:
#   1. Refuse if gold is running — Workstation holds the vmdk lock and the
#      qemu-img overwrite would fail with an opaque "Could not open" error.
#   2. Delete the base snapshot first — it references the old vmdk content,
#      and overwriting the base under it either breaks the integrity check
#      or (worse) produces clones booting pre-rebuild state. The snapshot
#      is recreated by _vmware_ensure_gold_snapshot on the next provision.
_vmware_ensure_gold_vmdk() {
    [[ -f "$GOLD_QCOW2" ]] || { echo "Gold qcow2 missing: $GOLD_QCOW2" >&2; return 1; }
    if [[ -f "$GOLD_VMDK" ]]; then
        local q v
        q=$(stat -c %Y "$GOLD_QCOW2")
        v=$(stat -c %Y "$GOLD_VMDK")
        if (( v >= q )); then
            return 0
        fi
        echo "[*] gold.vmdk is older than gold.qcow2 — regenerating"
    else
        echo "[*] gold.vmdk missing — generating from $GOLD_QCOW2"
    fi

    if vmrun -T ws list 2>/dev/null | grep -qxF "$GOLD_VMX"; then
        echo "[-] Gold VM is running ($GOLD_VMX) — cannot overwrite locked vmdk." >&2
        echo "    Shut it down in VMware Workstation, then re-run." >&2
        return 1
    fi

    if [[ -f "$GOLD_VMX" ]] \
       && vmrun -T ws listSnapshots "$GOLD_VMX" 2>/dev/null | grep -qx "$BASE_SNAPSHOT"; then
        echo "[*] Removing stale '$BASE_SNAPSHOT' snapshot before vmdk regen"
        vmrun -T ws deleteSnapshot "$GOLD_VMX" "$BASE_SNAPSHOT" >/dev/null 2>&1 || \
            echo "[!] deleteSnapshot failed — stale snapshot delta may linger in gold dir" >&2
    fi

    "$VM_SETUP/qcow2-to-vmware.sh" "${VM_NAME}-gold" "$GOLD_QCOW2" 4096 4 >&2
}

# Take the base snapshot used as the linked-clone source. Idempotent.
_vmware_ensure_gold_snapshot() {
    local snaps; snaps="$(vmrun -T ws listSnapshots "$GOLD_VMX" 2>/dev/null)"
    if echo "$snaps" | grep -qx "$BASE_SNAPSHOT"; then
        return 0
    fi
    echo "[*] Taking gold snapshot '$BASE_SNAPSHOT' (one-time)"
    vmrun -T ws snapshot "$GOLD_VMX" "$BASE_SNAPSHOT" >/dev/null
}

# Patch a freshly-cloned .vmx: pin MAC, memSize, displayName.
_vmware_patch_clone() {
    local vmx="$1" name="$2" mac="$3" ram="$4"
    # Strip any pre-existing ethernet0.* and memSize/displayName lines
    sed -i -E '/^ethernet0\.(generatedAddress|generatedAddressOffset|address|addressType)\s*=/d' "$vmx"
    sed -i -E '/^(memSize|displayName)\s*=/d' "$vmx"
    cat >> "$vmx" <<EOF

# winforge: pinned for predictable IP via vmnet8 dhcpd reservation
ethernet0.addressType = "static"
ethernet0.address = "$mac"
memSize = "$ram"
displayName = "$name"
EOF
}

# ── VM lifecycle ──────────────────────────────────────────────────

vm_provision() {
    local role="$1" ram="$2"
    local name; name="$(_vmware_role_to_name "$role")" || return 1
    local mac;  mac="$(_vmware_role_to_mac "$role")"
    local vmx;  vmx="$(_vmware_vmx_path "$role")"
    local dir;  dir="$VMWARE_DIR/$name"

    _vmware_ensure_gold_vmdk
    _vmware_ensure_gold_snapshot

    # Wipe any prior clone — vmrun deleteVM handles inventory cleanup.
    if [[ -f "$vmx" ]]; then
        vmrun -T ws stop "$vmx" hard >/dev/null 2>&1 || true
        vmrun -T ws deleteVM "$vmx" >/dev/null 2>&1 || true
        rm -rf "$dir"
    fi

    # vmrun clone needs the *destination* directory to NOT exist (creates it).
    vmrun -T ws clone "$GOLD_VMX" "$vmx" linked \
        -snapshot="$BASE_SNAPSHOT" -cloneName="$name" >/dev/null

    _vmware_patch_clone "$vmx" "$name" "$mac" "$ram"
}

vm_start() {
    local role="$1" mode="${2:-nogui}"
    local vmx; vmx="$(_vmware_vmx_path "$role")" || return 1
    [[ "$mode" == "gui" ]] || mode="nogui"
    if [[ "$mode" == "gui" ]]; then
        _vmware_require_gui || return 1
    fi
    vmrun -T ws start "$vmx" "$mode" >/dev/null
}

vm_force_stop() {
    local role="$1"
    local vmx; vmx="$(_vmware_vmx_path "$role")" || return 1
    [[ -f "$vmx" ]] || return 0
    vmrun -T ws stop "$vmx" hard >/dev/null 2>&1 || true
}

vm_undefine() {
    local role="$1"
    local name; name="$(_vmware_role_to_name "$role")" || return 1
    local vmx;  vmx="$(_vmware_vmx_path "$role")"
    local dir;  dir="$VMWARE_DIR/$name"
    if [[ -f "$vmx" ]]; then
        vmrun -T ws stop "$vmx" hard >/dev/null 2>&1 || true
        vmrun -T ws deleteVM "$vmx" >/dev/null 2>&1 || true
    fi
    rm -rf "$dir"
}

vm_state() {
    local role="$1"
    local vmx; vmx="$(_vmware_vmx_path "$role")" || return 1
    if [[ ! -f "$vmx" ]]; then echo "undefined"; return; fi
    if vmrun -T ws list 2>/dev/null | grep -qxF "$vmx"; then
        echo "running"
    else
        echo "stopped"
    fi
}

vm_exists() {
    local role="$1"
    local vmx; vmx="$(_vmware_vmx_path "$role")" || return 1
    [[ -f "$vmx" ]]
}

vm_console_open() {
    local role="$1"
    local vmx; vmx="$(_vmware_vmx_path "$role")" || return 1
    [[ -f "$vmx" ]] || { echo "$role not provisioned" >&2; return 1; }
    # `vmware <vmx>` opens (or focuses) the VM tab in Workstation.
    vmware "$vmx" >/dev/null 2>&1 &
}
