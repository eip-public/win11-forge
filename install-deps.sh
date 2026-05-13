#!/usr/bin/env bash
# Install host dependencies for win11-forge on Ubuntu/Debian.
#
# Installs libvirt + qemu + helper tools, adds you to the libvirt/kvm
# groups, and starts the default libvirt network. Idempotent.
#
# Usage:
#   ./install-deps.sh          # install everything
#   ./install-deps.sh check    # only verify, don't change anything

set -euo pipefail

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

ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2; exit 1; }
log()  { printf '\033[1;36m[*]\033[0m %s\n' "$*"; }

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
        ${SUDO[@]} install -d -m 0755 "$(dirname "$BINEXPORT_CACHE")"
        if [[ ! -s "$BINEXPORT_CACHE" ]]; then
            local tmp
            tmp="$(mktemp)"
            log "Downloading BinExport Ghidra plugin from $BINEXPORT_URL"
            if curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors "$BINEXPORT_URL" -o "$tmp"; then
                ${SUDO[@]} install -m 0644 "$tmp" "$BINEXPORT_CACHE"
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
        ${SUDO[@]} cp -a "$tmp_extract/BinExport" /opt/ghidra/Ghidra/Extensions/
    else
        nested_zip="$(find "$tmp_extract" -maxdepth 1 -type f -iname '*BinExport*.zip' -print -quit)"
        if [[ -n "$nested_zip" ]]; then
            ${SUDO[@]} unzip -q -o "$nested_zip" -d /opt/ghidra/Ghidra/Extensions/
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

check_mode() {
    local fail=0

    printf '  %-40s ' "/dev/kvm:"
    if [[ -e /dev/kvm ]]; then ok "present"; else warn "missing (enable VT-x/AMD-V)"; fail=1; fi

    local p
    for p in "${APT_PKGS[@]}"; do
        printf '  %-40s ' "apt: $p:"
        if dpkg -s "$p" >/dev/null 2>&1; then
            ok "installed"
        else
            warn "missing"
            fail=1
        fi
    done

    for p in "${PIPX_PKGS[@]}"; do
        printf '  %-40s ' "pipx: $p:"
        if command -v "$p" >/dev/null 2>&1; then
            ok "installed"
        else
            warn "missing"
            fail=1
        fi
    done

    printf '  %-40s ' "/opt/ghidra (for ghidriff):"
    if [[ -d /opt/ghidra ]]; then ok "present"; else warn "missing (ghidriff needs a Ghidra install)"; fi

    printf '  %-40s ' "Ghidra BinExport plugin:"
    if [[ -d /opt/ghidra/Ghidra/Extensions/BinExport ]]; then ok "present"; else warn "missing (needed for BinDiff)"; fi

    printf '  %-40s ' "ISO: $WIN_ISO_NAME:"
    if [[ -f "$IMAGES_DIR/$WIN_ISO_NAME" ]]; then ok "present"; else warn "missing (install mode will download unless WINFORGE_SKIP_ISO_DOWNLOAD=1)"; fi

    printf '  %-40s ' "ISO: $VIRTIO_ISO_NAME:"
    if [[ -f "$IMAGES_DIR/$VIRTIO_ISO_NAME" ]]; then ok "present"; else warn "missing (install mode will download unless WINFORGE_SKIP_ISO_DOWNLOAD=1)"; fi

    printf '  %-40s ' "group: libvirt ($TARGET_USER):"
    if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx libvirt; then ok "yes"; else warn "no"; fail=1; fi

    printf '  %-40s ' "group: kvm ($TARGET_USER):"
    if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx kvm; then ok "yes"; else warn "no"; fail=1; fi

    printf '  %-40s ' "libvirtd service:"
    if systemctl is-active --quiet libvirtd 2>/dev/null; then ok "active"; else warn "inactive"; fail=1; fi

    printf '  %-40s ' "libvirt default network:"
    if ${SUDO[@]} virsh net-info default >/dev/null 2>&1 && \
       [[ "$(${SUDO[@]} virsh net-info default 2>/dev/null | awk '/^Active:/ {print $2}')" == "yes" ]]; then
        ok "active"
    else
        warn "inactive or missing"
        fail=1
    fi

    return $fail
}

install_mode() {
    log "Updating apt index"
    ${SUDO[@]} apt-get update -qq

    log "Installing packages: ${APT_PKGS[*]}"
    ${SUDO[@]} env DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PKGS[@]}"

    log "Enabling + starting libvirtd"
    ${SUDO[@]} systemctl enable --now libvirtd

    local group
    local groups_added=()
    for group in libvirt kvm; do
        if ! id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"; then
            log "Adding $TARGET_USER to group $group"
            ${SUDO[@]} usermod -aG "$group" "$TARGET_USER"
            groups_added+=("$group")
        fi
    done

    if [[ ${#PIPX_PKGS[@]} -gt 0 ]]; then
        log "Installing pipx packages system-wide into /opt/pipx: ${PIPX_PKGS[*]}"
        for p in "${PIPX_PKGS[@]}"; do
            if ! command -v "$p" >/dev/null 2>&1; then
                ${SUDO[@]} env PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install "$p"
            fi
        done
    fi

    install_binexport_plugin

    ensure_iso_assets

    log "Ensuring libvirt default network is up"
    ${SUDO[@]} virsh net-info default >/dev/null 2>&1 || {
        warn "default network missing; libvirt usually ships it — check 'virsh net-list --all'"
    }
    ${SUDO[@]} virsh net-autostart default 2>/dev/null || true
    if [[ "$(${SUDO[@]} virsh net-info default 2>/dev/null | awk '/^Active:/ {print $2}')" != "yes" ]]; then
        ${SUDO[@]} virsh net-start default || warn "could not start default network"
    fi

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
    command -v vmrun >/dev/null \
        || die "vmrun not found. Install VMware Workstation first."
    [[ -d /etc/vmware/vmnet8 ]] \
        || die "/etc/vmware/vmnet8 missing. Has VMware Workstation completed first-run setup?"

    local conf=/etc/vmware/vmnet8/dhcpd/dhcpd.conf
    [[ -f "$conf" ]] || die "$conf missing"

    local cidr subnet
    cidr="$(ip -br -4 addr show vmnet8 2>/dev/null | awk '{print $3}' | head -1)"
    [[ -n "$cidr" ]] || die "vmnet8 has no IPv4 — sudo vmware-networks --start"
    subnet="${cidr%.*/*}"
    local target_ip="${subnet}.100" debugger_ip="${subnet}.101"
    local target_mac="00:50:56:11:11:11" debugger_mac="00:50:56:22:22:22"

    log "vmnet8 subnet: ${subnet}.0/24"
    log "Adding DHCP reservations: target=${target_ip} debugger=${debugger_ip}"

    local marker="# winforge: lab pair MAC pins"
    if grep -qF "$marker" "$conf"; then
        ok "Reservations already present in $conf — skipping edit"
    else
        ${SUDO[@]} tee -a "$conf" >/dev/null <<EOF

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
    ${SUDO[@]} vmware-networks --stop >/dev/null 2>&1 || true
    ${SUDO[@]} vmware-networks --start >/dev/null \
        || die "vmware-networks --start failed"
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
