#!/usr/bin/env bash
#
# fetch-isos.sh — download the Windows 11 LTSC ISO + virtio-win.iso into vm-images/.
#
# Standalone twin of install-deps.sh's download_iso_if_missing() — same URLs,
# same env overrides, same .partial + atomic-mv pattern — but invokable on its
# own without running the rest of install-deps.sh. Use it to pre-stage ISOs
# on a fresh host or to refresh an outdated copy without re-running the full
# host bootstrap.
#
# Logic deliberately duplicated rather than shared with install-deps.sh; if
# that drifts, sync this script by hand.
#
# Usage:
#   fetch-isos.sh                              # both ISOs into ./vm-images/
#   fetch-isos.sh --dest /data/vm-images       # different output dir
#   fetch-isos.sh --win-only                   # skip virtio
#   fetch-isos.sh --virtio-only                # skip Windows
#   fetch-isos.sh --win-url URL                # override Windows URL
#   fetch-isos.sh --virtio-url URL             # override virtio URL
#
# Environment overrides (same names install-deps.sh honors):
#   WIN_ISO_URL, VIRTIO_ISO_URL, WINFORGE_SKIP_ISO_DOWNLOAD
#
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES_DIR="$ROOT/vm-images"
ISOS_DIR="$ROOT/isos"
WIN_ISO_NAME="win11-ltsc-24h2.iso"
VIRTIO_ISO_NAME="virtio-win.iso"
WIN_ISO_URL="${WIN_ISO_URL:-https://go.microsoft.com/fwlink/?linkid=2270353}"
VIRTIO_ISO_URL="${VIRTIO_ISO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}"
WINFORGE_SKIP_ISO_DOWNLOAD="${WINFORGE_SKIP_ISO_DOWNLOAD:-0}"

FETCH_WIN=1
FETCH_VIRTIO=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest)         IMAGES_DIR="$2"; shift 2 ;;
        --win-only)     FETCH_VIRTIO=0; shift ;;
        --virtio-only)  FETCH_WIN=0; shift ;;
        --win-url)      WIN_ISO_URL="$2"; shift 2 ;;
        --virtio-url)   VIRTIO_ISO_URL="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^set -/p' "$0" | sed 's/^# \?//;$d'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

log()  { printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
# shellcheck source=lib/log.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/log.sh"

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
    [[ -f "$dest" ]] && { ok "$name already present at $dest"; return 0; }

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
    ok "Downloaded $dest"
}

log "Staging ISOs into $IMAGES_DIR"
mkdir -p "$IMAGES_DIR" "$ISOS_DIR"

(( FETCH_WIN ))    && download_iso_if_missing "$WIN_ISO_NAME"    "$WIN_ISO_URL"
(( FETCH_VIRTIO )) && download_iso_if_missing "$VIRTIO_ISO_NAME" "$VIRTIO_ISO_URL"

rmdir "$ISOS_DIR" 2>/dev/null || true

ok "ISO staging done"
ls -lh "$IMAGES_DIR" | grep -E '\.iso$' || true
