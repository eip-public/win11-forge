#!/usr/bin/env bash
#
# fetch-windev-vhd.sh — download Microsoft's free Windows 11 dev VHD/VHDX.
#
# Resolves the current aka.ms redirect (Microsoft swaps the underlying file
# every few months), resumes on partial downloads, and optionally unzips
# the archive to expose the bare .vhdx for tools like create-vm.sh.
#
# Usage:
#   fetch-windev-vhd.sh                            # default: HyperV → ./windev/
#   fetch-windev-vhd.sh --dest /data/win11.zip     # write to a specific path
#   fetch-windev-vhd.sh --variant VirtualBox       # different format
#   fetch-windev-vhd.sh --no-unzip                 # leave the .zip alone
#
# Variants (Microsoft's labels): HyperV | VirtualBox | VMware
#   HyperV  → .vhdx inside the zip (use this for qemu-img convert / virt-install)
#   VirtualBox → .ova
#   VMware  → .vmdk / .vmx
#
set -Eeuo pipefail

VARIANT="HyperV"
DEST=""
DO_UNZIP=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant)   VARIANT="$2"; shift 2 ;;
        --dest)      DEST="$2"; shift 2 ;;
        --no-unzip)  DO_UNZIP=0; shift ;;
        -h|--help)
            sed -n '2,/^set -/p' "$0" | sed 's/^# \?//;$d'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$VARIANT" in
    HyperV|VirtualBox|VMware) ;;
    *) echo "Unsupported variant: $VARIANT (expected HyperV|VirtualBox|VMware)" >&2; exit 2 ;;
esac

[[ -n "$DEST" ]] || DEST="./windev/WinDevEval.${VARIANT}.zip"
DEST_DIR="$(dirname "$DEST")"
mkdir -p "$DEST_DIR"

REDIRECT_URL="https://aka.ms/windev_VM_${VARIANT}"
echo "[*] Resolving $REDIRECT_URL …"
REAL_URL="$(curl -sIL "$REDIRECT_URL" | awk -v IGNORECASE=1 '/^location:/{u=$2} END{print u}' | tr -d '\r')"
[[ "$REAL_URL" == https://*microsoft.com/*.zip ]] \
    || { echo "Unexpected redirect target: $REAL_URL" >&2; exit 1; }

EXPECTED_SIZE="$(curl -sIL "$REAL_URL" | awk -v IGNORECASE=1 '/^content-length:/{print $2}' | tail -1 | tr -d '\r')"
echo "    → $REAL_URL"
echo "    expected size: ${EXPECTED_SIZE:-unknown} bytes"

if [[ -f "$DEST" ]]; then
    actual="$(stat -c %s "$DEST" 2>/dev/null || stat -f %z "$DEST")"
    if [[ -n "${EXPECTED_SIZE:-}" && "$actual" == "$EXPECTED_SIZE" ]]; then
        echo "[+] $DEST already complete ($actual bytes); skipping download"
    else
        echo "[*] Resuming partial $DEST ($actual / ${EXPECTED_SIZE:-?} bytes)"
        wget -c -q --show-progress --progress=dot:giga -O "$DEST" "$REAL_URL"
    fi
else
    echo "[*] Downloading to $DEST"
    wget -q --show-progress --progress=dot:giga -O "$DEST" "$REAL_URL"
fi

actual="$(stat -c %s "$DEST" 2>/dev/null || stat -f %z "$DEST")"
if [[ -n "${EXPECTED_SIZE:-}" && "$actual" != "$EXPECTED_SIZE" ]]; then
    echo "[-] Size mismatch: got $actual, expected $EXPECTED_SIZE" >&2
    exit 1
fi
echo "[+] Downloaded $DEST ($actual bytes)"

if (( DO_UNZIP )); then
    echo "[*] Unzipping into $DEST_DIR"
    unzip -o -q "$DEST" -d "$DEST_DIR"
    DISK="$(find "$DEST_DIR" -maxdepth 2 -type f \( -iname '*.vhdx' -o -iname '*.vhd' -o -iname '*.ova' -o -iname '*.vmdk' \) | head -1)"
    [[ -n "$DISK" ]] || { echo "No disk image found after unzip" >&2; exit 1; }
    echo "[+] Disk image: $DISK"
fi
