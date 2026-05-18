#!/usr/bin/env bash
# Install host dependencies for win11-forge on Ubuntu/Debian.
#
# Installs libvirt + qemu + helper tools, adds you to the libvirt/kvm
# groups, and starts the default libvirt network. Idempotent.
#
# Usage:
#   ./install-deps.sh          # install everything
#   ./install-deps.sh check    # only verify, don't change anything

set -Eeuo pipefail

TARGET_USER="${SUDO_USER:-$USER}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DIR="$ROOT/vm-images"
ISOS_DIR="$ROOT/isos"
WIN_ISO_NAME="win11-ltsc-24h2.iso"
VIRTIO_ISO_NAME="virtio-win.iso"
WIN_ISO_URL="${WIN_ISO_URL:-https://go.microsoft.com/fwlink/?linkid=2270353}"
VIRTIO_ISO_URL="${VIRTIO_ISO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}"
WINFORGE_SKIP_ISO_DOWNLOAD="${WINFORGE_SKIP_ISO_DOWNLOAD:-0}"

APT_PKGS=(
    acl
    curl
    libvirt-daemon-system
    libvirt-clients
    virtinst
    qemu-system-x86
    qemu-utils
    ovmf
    genisoimage
    sshpass
    python3
    pipx
    openjdk-21-jre-headless
    unzip
)

# Host-side reverse-engineering tooling (drives patch-diff + CDB analysis).
# ghidra is NOT apt-installed — if /opt/ghidra is missing, we warn only
# (user has too many install locations/versions for us to pick one).
PIPX_PKGS=(
    ghidriff
)

# Latest upstream Ghidra Java extension published by google/binexport. Google has
# not published a Ghidra 12.x-specific BinExport release yet; keep this URL
# overrideable so a newer matching build can be dropped in without script edits.
BINEXPORT_URL="${BINEXPORT_URL:-https://github.com/google/binexport/releases/download/v12-20240417-ghidra_11.0.3/BinExport_Ghidra-Java.zip}"
BINEXPORT_CACHE="${BINEXPORT_CACHE:-/opt/ghidra-extensions/BinExport_Ghidra-Java.zip}"

log() { printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
# shellcheck source=vm-setup/lib/log.sh
. "$(dirname "${BASH_SOURCE[0]}")/vm-setup/lib/log.sh"

need_sudo() {
    if [[ $EUID -ne 0 ]]; then
        command -v sudo >/dev/null || die "Must run as root or install sudo."
        SUDO=(sudo)
    else
        SUDO=()
    fi
}

iso_download_disabled() {
    [[ "$WINFORGE_SKIP_ISO_DOWNLOAD" == "1" || "$WINFORGE_SKIP_ISO_DOWNLOAD" == "true" || "$WINFORGE_SKIP_ISO_DOWNLOAD" == "yes" ]]
}

stage_local_iso_if_present() {
    local name="${1:?name required}"
    if [[ ! -f "$IMAGES_DIR/$name" && -f "$ISOS_DIR/$name" ]]; then
        mkdir -p "$IMAGES_DIR"
        mv -v "$ISOS_DIR/$name" "$IMAGES_DIR/$name"
    fi
}

download_iso_if_missing() {
    local name="${1:?name required}" url="${2:?url required}"
    local dest="$IMAGES_DIR/$name"
    local partial="$dest.partial"

    stage_local_iso_if_present "$name"
    [[ -f "$dest" ]] && return 0

    if iso_download_disabled; then
        warn "Missing $dest; ISO download skipped by WINFORGE_SKIP_ISO_DOWNLOAD=$WINFORGE_SKIP_ISO_DOWNLOAD"
        return 0
    fi

    log "Downloading $name"
    log "URL: $url"
    mkdir -p "$IMAGES_DIR"
    curl -fL --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 30 \
        --speed-limit 1024 --speed-time 60 -C - -o "$partial" "$url"
    mv "$partial" "$dest"
}

ensure_iso_assets() {
    log "Ensuring Windows/VirtIO ISOs are staged"
    mkdir -p "$IMAGES_DIR" "$ISOS_DIR"
    download_iso_if_missing "$WIN_ISO_NAME" "$WIN_ISO_URL"
    download_iso_if_missing "$VIRTIO_ISO_NAME" "$VIRTIO_ISO_URL"
    rmdir "$ISOS_DIR" 2>/dev/null || true

    if [[ -f "$IMAGES_DIR/$WIN_ISO_NAME" && -f "$IMAGES_DIR/$VIRTIO_ISO_NAME" ]]; then
        ok "ISOs staged in $IMAGES_DIR"
    elif iso_download_disabled; then
        warn "ISO staging incomplete because downloads are disabled; place missing files in $IMAGES_DIR or unset WINFORGE_SKIP_ISO_DOWNLOAD"
    else
        die "ISO staging incomplete after attempted downloads"
    fi
}

install_binexport_plugin() {
    [[ -d /opt/ghidra ]] || return 0
    [[ ! -d /opt/ghidra/Ghidra/Extensions/BinExport ]] || return 0

    local binexport_zip=""
    if [[ -n "${BINEXPORT_ZIP:-}" ]]; then
        if [[ ! -s "$BINEXPORT_ZIP" ]]; then
            warn "BINEXPORT_ZIP is set but not readable/non-empty: $BINEXPORT_ZIP"
        else
            binexport_zip="$BINEXPORT_ZIP"
        fi
    fi

    if [[ -z "$binexport_zip" ]]; then
        "${SUDO[@]}" install -d -m 0755 "$(dirname "$BINEXPORT_CACHE")"
        if [[ ! -s "$BINEXPORT_CACHE" ]]; then
            local tmp
            tmp="$(mktemp)"
            log "Downloading BinExport Ghidra plugin from $BINEXPORT_URL"
            if curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors "$BINEXPORT_URL" -o "$tmp"; then
                "${SUDO[@]}" install -m 0644 "$tmp" "$BINEXPORT_CACHE"
            else
                rm -f "$tmp"
                warn "BinExport download failed; set BINEXPORT_ZIP=/path/to/BinExport_Ghidra-Java.zip and re-run"
                return 0
            fi
            rm -f "$tmp"
        fi
        binexport_zip="$BINEXPORT_CACHE"
    fi

    log "Installing BinExport Ghidra plugin from $binexport_zip"
    local tmp_extract nested_zip
    tmp_extract="$(mktemp -d)"
    if ! unzip -q -o "$binexport_zip" -d "$tmp_extract"; then
        rm -rf "$tmp_extract"
        warn "BinExport extension install failed"
        return 0
    fi

    # Upstream BinExport_Ghidra-Java.zip is a wrapper containing the real
    # ghidra_*_BinExport.zip extension archive. Local BINEXPORT_ZIP overrides may
    # point to either the wrapper or the inner extension zip.
    if [[ -d "$tmp_extract/BinExport" ]]; then
        "${SUDO[@]}" cp -a "$tmp_extract/BinExport" /opt/ghidra/Ghidra/Extensions/
    else
        nested_zip="$(find "$tmp_extract" -maxdepth 1 -type f -iname '*BinExport*.zip' -print -quit)"
        if [[ -n "$nested_zip" ]]; then
            "${SUDO[@]}" unzip -q -o "$nested_zip" -d /opt/ghidra/Ghidra/Extensions/
        else
            warn "BinExport archive did not contain BinExport/ or a nested BinExport zip"
        fi
    fi
    rm -rf "$tmp_extract"

    if [[ -d /opt/ghidra/Ghidra/Extensions/BinExport ]]; then
        ok "BinExport Ghidra plugin installed"
    else
        warn "BinExport unzip completed but /opt/ghidra/Ghidra/Extensions/BinExport is still missing"
    fi
}

# Configure libvirt's default network with explicit DNS forwarders.
#
# Why: libvirt's stock 'default' network has no <dns><forwarder/></dns>,
# so dnsmasq inherits the host's /etc/resolv.conf. On Ubuntu / Fedora
# with systemd-resolved that file points at the 127.0.0.53 stub, which
# is unreachable from inside the guest. Symptom inside the guest:
#   nslookup community.chocolatey.org -> "DNS request timed out"
# Result: the gold-build's Chocolatey download dies before installing
# anything. Observed on 2026-05-17; the previous gold survived only
# because a manual fix had been applied to the running target VM.
#
# Fix: add 1.1.1.1 + 8.8.8.8 forwarders so the lab subnet's DNS does
# not depend on the host's systemd-resolved configuration. Idempotent.
ensure_libvirt_dns_forwarders() {
    "${SUDO[@]}" virsh net-info default >/dev/null 2>&1 || return 0
    if "${SUDO[@]}" virsh net-dumpxml default | grep -q '<forwarder addr='; then
        ok "libvirt default network already has DNS forwarders"
        return 0
    fi
    log "Adding DNS forwarders (1.1.1.1, 8.8.8.8) to libvirt default network"
    local xml
    xml="$(mktemp)"
    "${SUDO[@]}" virsh net-dumpxml default >"$xml"
    python3 - "$xml" <<'PY'
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
tree = ET.parse(path); root = tree.getroot()
if root.find('dns') is None:
    dns = ET.Element('dns')
    for addr in ('1.1.1.1', '8.8.8.8'):
        ET.SubElement(dns, 'forwarder', {'addr': addr})
    # Insert before the first <ip> so the resulting XML stays canonical.
    for i, child in enumerate(list(root)):
        if child.tag == 'ip':
            root.insert(i, dns); break
    tree.write(path)
PY
    # net-update can't manage <dns>; destroy+define+start is the
    # supported way to swap in a structural change. Domains using the
    # network stay defined; only running guests on the bridge see a
    # momentary blip.
    "${SUDO[@]}" virsh net-destroy default >/dev/null 2>&1 || true
    "${SUDO[@]}" virsh net-define "$xml" >/dev/null
    "${SUDO[@]}" virsh net-start default >/dev/null
    rm -f "$xml"
    ok "libvirt default network restarted with DNS forwarders"
}

_emit_check() {
    # _emit_check <label> <pass|fail> <pass-msg> <fail-msg>
    # Always prints the label + status line. Returns 0 on pass, 1 on fail
    # so the caller can OR into the running tally.
    local label="$1" status="$2" pass_msg="$3" fail_msg="$4"
    printf '  %-40s ' "$label:"
    if [[ "$status" == "pass" ]]; then
        ok "$pass_msg"
        return 0
    fi
    warn "$fail_msg"
    return 1
}

_check_packages() {
    # _check_packages <category-label> <name-of-array...>
    # Iterates an array of names and applies a per-category predicate:
    #   apt   -> dpkg -s
    #   pipx  -> command -v   (pipx installs land in PATH)
    # Returns 1 if any required package is missing.
    local category="$1"
    shift
    local fail=0 p status
    for p in "$@"; do
        case "$category" in
            apt) dpkg -s "$p" >/dev/null 2>&1 && status=pass || status=fail ;;
            pipx) command -v "$p" >/dev/null 2>&1 && status=pass || status=fail ;;
            *) status=fail ;;
        esac
        _emit_check "$category: $p" "$status" "installed" "missing" || fail=1
    done
    return $fail
}

_check_ghidra_artifacts() {
    # /opt/ghidra and the BinExport plugin are *optional* — neither
    # contributes to the running fail tally. ghidriff and BinDiff don't
    # gate the lab; check_mode still emits a status line so the operator
    # can see what's missing.
    [[ -d /opt/ghidra ]] &&
        _emit_check "/opt/ghidra (for ghidriff)" pass "present" "" ||
        _emit_check "/opt/ghidra (for ghidriff)" fail "" "missing (ghidriff needs a Ghidra install)" || true
    [[ -d /opt/ghidra/Ghidra/Extensions/BinExport ]] &&
        _emit_check "Ghidra BinExport plugin" pass "present" "" ||
        _emit_check "Ghidra BinExport plugin" fail "" "missing (needed for BinDiff)" || true
}

_check_isos() {
    # ISOs are downloaded by `install` mode (unless WINFORGE_SKIP_ISO_DOWNLOAD=1),
    # so missing here is informational only — don't bump the fail tally.
    local f
    for f in "$WIN_ISO_NAME" "$VIRTIO_ISO_NAME"; do
        if [[ -f "$IMAGES_DIR/$f" ]]; then
            _emit_check "ISO: $f" pass "present" "" || true
        else
            _emit_check "ISO: $f" fail "" \
                "missing (install mode will download unless WINFORGE_SKIP_ISO_DOWNLOAD=1)" || true
        fi
    done
}

_user_in_group() {
    # _user_in_group <user> <group>
    id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"
}

_libvirt_default_net_active() {
    "${SUDO[@]}" virsh net-info default >/dev/null 2>&1 &&
        [[ "$("${SUDO[@]}" virsh net-info default 2>/dev/null | awk '/^Active:/ {print $2}')" == "yes" ]]
}

_check_libvirt_runtime() {
    # libvirt-side runtime state that install_mode is responsible for:
    # user groups, libvirtd service, default network, libvirt-qemu home
    # ACL. Each is required (fail bumps the tally).
    local fail=0 status

    for grp in libvirt kvm; do
        _user_in_group "$TARGET_USER" "$grp" && status=pass || status=fail
        _emit_check "group: $grp ($TARGET_USER)" "$status" "yes" "no" || fail=1
    done

    systemctl is-active --quiet libvirtd 2>/dev/null && status=pass || status=fail
    _emit_check "libvirtd service" "$status" "active" "inactive" || fail=1

    _libvirt_default_net_active && status=pass || status=fail
    _emit_check "libvirt default network" "$status" "active" "inactive or missing" || fail=1

    local target_home
    target_home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    if [[ -n "$target_home" && -d "$target_home" ]] &&
        getfacl --absolute-names "$target_home" 2>/dev/null | grep -qE '^user:libvirt-qemu:.*x'; then
        status=pass
    else
        status=fail
    fi
    _emit_check "libvirt-qemu ACL on $target_home" "$status" \
        "traverse granted" "missing (VM image access will fail)" || fail=1

    return $fail
}

check_mode() {
    # Orchestrator: walk every dependency category, accumulate the fail
    # bit, exit non-zero if any required check failed. The per-category
    # helpers above are responsible for both the formatting and the
    # required-vs-optional gating.
    local fail=0 status

    [[ -e /dev/kvm ]] && status=pass || status=fail
    _emit_check "/dev/kvm" "$status" "present" "missing (enable VT-x/AMD-V)" || fail=1

    _check_packages "apt" "${APT_PKGS[@]}" || fail=1
    _check_packages "pipx" "${PIPX_PKGS[@]}" || fail=1

    _check_ghidra_artifacts
    _check_isos

    _check_libvirt_runtime || fail=1

    return $fail
}

install_mode() {
    log "Updating apt index"
    "${SUDO[@]}" apt-get update -qq

    log "Installing packages: ${APT_PKGS[*]}"
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PKGS[@]}"

    log "Enabling + starting libvirtd"
    "${SUDO[@]}" systemctl enable --now libvirtd

    local group
    local groups_added=()
    for group in libvirt kvm; do
        if ! id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"; then
            log "Adding $TARGET_USER to group $group"
            "${SUDO[@]}" usermod -aG "$group" "$TARGET_USER"
            groups_added+=("$group")
        fi
    done

    # Ubuntu 24.04 ships /home/<user> as drwxr-x---, which blocks libvirt-qemu
    # (uid 64055) from traversing into the user's $HOME to reach VM images
    # under ~/win11-forge/vm-images. virt-install warns about this but
    # proceeds, then dies with "Cannot access storage file ... Permission
    # denied" once qemu tries to open the qcow2. Grant traverse-only via
    # ACL so other-user permissions stay locked down.
    local target_home
    target_home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    if [[ -n "$target_home" && -d "$target_home" ]] && id libvirt-qemu >/dev/null 2>&1; then
        if ! getfacl --absolute-names "$target_home" 2>/dev/null | grep -qE '^user:libvirt-qemu:.*x'; then
            log "Granting libvirt-qemu traverse ACL on $target_home"
            "${SUDO[@]}" setfacl -m u:libvirt-qemu:x "$target_home"
        fi
    fi

    if [[ ${#PIPX_PKGS[@]} -gt 0 ]]; then
        log "Installing pipx packages system-wide into /opt/pipx: ${PIPX_PKGS[*]}"
        for p in "${PIPX_PKGS[@]}"; do
            if ! command -v "$p" >/dev/null 2>&1; then
                "${SUDO[@]}" env PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install "$p"
            fi
        done
    fi

    install_binexport_plugin

    ensure_iso_assets

    log "Ensuring libvirt default network is up"
    "${SUDO[@]}" virsh net-info default >/dev/null 2>&1 || {
        warn "default network missing; libvirt usually ships it — check 'virsh net-list --all'"
    }
    "${SUDO[@]}" virsh net-autostart default 2>/dev/null || true
    if [[ "$("${SUDO[@]}" virsh net-info default 2>/dev/null | awk '/^Active:/ {print $2}')" != "yes" ]]; then
        "${SUDO[@]}" virsh net-start default || warn "could not start default network"
    fi

    ensure_libvirt_dns_forwarders

    ok "Dependencies installed"
    if [[ ${#groups_added[@]} -gt 0 ]]; then
        printf '\n'
        warn "You were added to: ${groups_added[*]}"
        warn "Log out and back in (or run 'newgrp libvirt') so the new group memberships take effect."
    fi
    printf '\n'
    log "Verifying:"
    check_mode || warn "Some checks failed — review output above"
}

vmware_mode() {
    # Pin the lab pair's MACs to .100/.101 in vmnet8's dhcpd. Idempotent.
    # Required when running the lab under WINFORGE_BACKEND=vmware so the
    # VMs land on predictable IPs (matches the KVM convention).
    command -v vmrun >/dev/null ||
        die "vmrun not found. Install VMware Workstation first."
    [[ -d /etc/vmware/vmnet8 ]] ||
        die "/etc/vmware/vmnet8 missing. Has VMware Workstation completed first-run setup?"

    local conf=/etc/vmware/vmnet8/dhcpd/dhcpd.conf
    [[ -f "$conf" ]] || die "$conf missing"

    local cidr subnet
    cidr="$(ip -br -4 addr show vmnet8 2>/dev/null | awk '{print $3}' | head -1)"
    [[ -n "$cidr" ]] || die "vmnet8 has no IPv4 — sudo vmware-networks --start"
    subnet="${cidr%.*/*}"
    local target_ip="${subnet}.100" debugger_ip="${subnet}.101"
    # shellcheck source=vm-setup/lib/macs.env
    . "$(dirname "${BASH_SOURCE[0]}")/vm-setup/lib/macs.env"
    local target_mac="$VMWARE_TARGET_MAC" debugger_mac="$VMWARE_DEBUGGER_MAC"

    log "vmnet8 subnet: ${subnet}.0/24"
    log "Adding DHCP reservations: target=${target_ip} debugger=${debugger_ip}"

    local marker="# winforge: lab pair MAC pins"
    if grep -qF "$marker" "$conf"; then
        ok "Reservations already present in $conf — skipping edit"
    else
        "${SUDO[@]}" tee -a "$conf" >/dev/null <<EOF

$marker
host winforge-target {
    hardware ethernet $target_mac;
    fixed-address $target_ip;
}
host winforge-debugger {
    hardware ethernet $debugger_mac;
    fixed-address $debugger_ip;
}
EOF
        ok "Reservations appended to $conf"
    fi

    log "Restarting vmware-networks so dhcpd picks up the new reservations"
    "${SUDO[@]}" vmware-networks --stop >/dev/null 2>&1 || true
    "${SUDO[@]}" vmware-networks --start >/dev/null ||
        die "vmware-networks --start failed"
    ok "vmnet8 dhcpd reloaded"

    printf '\n  Verify with:\n'
    printf '    grep -A2 winforge %s\n' "$conf"
    printf '\n  Then run:  WINFORGE_BACKEND=vmware ./setup.sh lab spawn\n\n'
}

need_sudo

case "${1:-install}" in
    install)
        install_mode
        ;;
    check)
        check_mode && ok "All dependencies satisfied" || die "Missing dependencies — run: $0"
        ;;
    vmware)
        vmware_mode
        ;;
    *)
        die "Unknown command: $1 (use: install | check | vmware)"
        ;;
esac
