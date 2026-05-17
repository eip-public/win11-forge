#!/usr/bin/env bash
#
# Repack a Windows install ISO to remove the "Press any key to boot from
# CD or DVD..." prompt that `efi/microsoft/boot/cdboot.efi` shows for a
# few seconds before booting Windows Setup.
#
# Why this exists: on a loaded host, OVMF takes 5–60s to reach that
# prompt, the prompt window itself is ~3s, and there is no firmware-side
# flag to suppress it (the prompt is in Microsoft's signed `cdboot.efi`,
# not in OVMF). The previous workaround — `virsh send-key KEY_ENTER` in
# a loop — kept firing Enters into the Windows installer UI after the
# prompt had cleared, hitting the Cancel button and tripping the
# "Are you sure you want to quit?" dialog.
#
# The fix every maintained Windows-on-Linux pipeline ends up at (Packer
# upstream, kubevirt CDI thread, Proxmox community Ansible playbook,
# William Lam, Microsoft's own UEFI-ISO documentation): swap in the
# no-prompt boot blobs that Microsoft already ships next to the
# prompting ones in the retail ISO:
#
#   efi/microsoft/boot/efisys.bin   <- efisys_noprompt.bin
#   efi/microsoft/boot/cdboot.efi   <- cdboot_noprompt.efi
#
# Both _noprompt files are present in our `vm-images/win11-ltsc-24h2.iso`
# as shipped — no Windows ADK extraction needed.
#
# Output: a repacked ISO that boots Windows Setup with zero keystrokes.
#
# Usage:
#   ./repack-iso-noprompt.sh <src.iso> <dst.iso>
#
# Idempotent — exits 0 with no work if dst.iso is newer than src.iso.

set -Eeuo pipefail

SRC="${1:?usage: $0 <src.iso> <dst.iso>}"
DST="${2:?usage: $0 <src.iso> <dst.iso>}"

[[ -f "$SRC" ]] || { echo "[-] source not found: $SRC" >&2; exit 1; }

# Idempotency: skip the ~30–60s repack if dst is up to date.
if [[ -f "$DST" ]] && [[ "$DST" -nt "$SRC" ]]; then
    echo "[=] $DST is newer than $SRC — repack skipped"
    exit 0
fi

for tool in 7z xorriso isoinfo; do
    command -v "$tool" >/dev/null \
        || { echo "[-] $tool not found in PATH — apt install p7zip-full xorriso genisoimage" >&2; exit 1; }
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "[*] Extracting $SRC into $WORKDIR (~5 GB, ~15s on SSD)"
7z x -o"$WORKDIR" "$SRC" >/dev/null

# Sanity-check: the _noprompt blobs must be present in the source ISO.
# These have shipped in retail Windows ISOs since at least Windows 10, so
# absence indicates either a tampered ISO or an unexpected build.
for f in efi/microsoft/boot/efisys_noprompt.bin efi/microsoft/boot/cdboot_noprompt.efi; do
    [[ -f "$WORKDIR/$f" ]] \
        || { echo "[-] $f missing inside $SRC — is this a real Windows install ISO?" >&2; exit 1; }
done

echo "[*] Activating no-prompt boot blobs (overwriting prompting variants in-place)"
cp -f "$WORKDIR/efi/microsoft/boot/efisys_noprompt.bin" "$WORKDIR/efi/microsoft/boot/efisys.bin"
cp -f "$WORKDIR/efi/microsoft/boot/cdboot_noprompt.efi" "$WORKDIR/efi/microsoft/boot/cdboot.efi"

# Preserve the source volume label — Windows Setup matches on this at
# first boot. Read it from the source so future ISOs (different SKUs,
# different languages) don't silently break.
VOLID=$(isoinfo -d -i "$SRC" 2>/dev/null | awk -F': ' '/^Volume id:/ {print $2; exit}')
VOLID="${VOLID:-CESE_X64FREE_EN-US_DV9}"
echo "[*] Repacking as $DST (volid=$VOLID)"

# Dual El Torito catalog: BIOS (etfsboot.com) + UEFI (efisys_noprompt.bin).
# - iso-level 3: lifts the ISO9660 2 GiB-per-file cap so install.wim
#   (4.2 GiB on Win11 24H2 LTSC) survives the repack. Some mkisofs
#   wrappers also need -allow-limited-size, but xorriso 1.5+ enables
#   large-file support automatically at level 3.
# - hide boot/boot.cat: keeps the boot catalog out of the visible tree.
# - isohybrid-gpt-basdat: makes the image bootable as a USB stick too;
#   harmless when consumed as a CD-ROM.
TMP="${DST}.tmp"
rm -f "$TMP"
xorriso -as mkisofs \
    -iso-level 3 -full-iso9660-filenames \
    -volid "$VOLID" \
    -eltorito-boot boot/etfsboot.com \
        -eltorito-catalog boot/boot.cat \
        -no-emul-boot -boot-load-size 8 -boot-info-table -hide boot/boot.cat \
    -eltorito-alt-boot \
        -e efi/microsoft/boot/efisys_noprompt.bin -no-emul-boot \
    -isohybrid-gpt-basdat \
    -o "$TMP" "$WORKDIR" 2>&1 | tail -3
mv -f "$TMP" "$DST"

# `libvirt-qemu` (the qemu service user) needs read access to ISOs in
# this directory. Don't widen anything else — chmod the file only.
chmod o+r "$DST"

echo "[+] Repacked: $DST ($(du -h "$DST" | awk '{print $1}'))"
