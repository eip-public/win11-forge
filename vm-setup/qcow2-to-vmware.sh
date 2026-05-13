#!/bin/bash
#
# Convert a WinForge qcow2 image to a self-contained VMware Workstation VM.
# Non-destructive: original qcow2 is left untouched.
#
# Output: $IMAGES_DIR/vmware/<name>/{<name>.vmdk, <name>.vmx}
#
# Usage:
#   ./qcow2-to-vmware.sh <name> <source.qcow2> [ram_mb] [vcpus]
#
# Notes:
#   - qemu-img flattens any backing chain automatically (-> standalone vmdk).
#   - Disk attached as SATA (storahci is BootStart on Win11; no driver swap needed).
#   - NIC is e1000e (native Win driver). VMware NAT by default.
#   - Firmware is UEFI to match OVMF; secure boot off (matches the lab build).

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <name> <source.qcow2> [ram_mb=4096] [vcpus=4]" >&2
  exit 1
fi

NAME="$1"
SRC="$2"
RAM="${3:-4096}"
VCPUS="${4:-4}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGES_DIR="$(dirname "$SCRIPT_DIR")/vm-images"
OUT_DIR="$IMAGES_DIR/vmware/$NAME"
VMDK="$OUT_DIR/$NAME.vmdk"
VMX="$OUT_DIR/$NAME.vmx"

if [[ ! -f "$SRC" ]]; then
  echo "Source qcow2 not found: $SRC" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

echo "[+] Converting $SRC -> $VMDK (flattens backing chain)"
qemu-img convert -p -f qcow2 -O vmdk -o subformat=monolithicSparse "$SRC" "$VMDK"

echo "[+] Writing $VMX"
cat > "$VMX" <<EOF
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "21"
displayName = "$NAME"
guestOS = "windows11-64"

firmware = "efi"
uefi.secureBoot.enabled = "FALSE"

memSize = "$RAM"
numvcpus = "$VCPUS"
cpuid.coresPerSocket = "$VCPUS"
vhv.enable = "TRUE"

sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.fileName = "$NAME.vmdk"
sata0:0.deviceType = "disk"

sata0:1.present = "TRUE"
sata0:1.deviceType = "cdrom-raw"
sata0:1.startConnected = "FALSE"
sata0:1.autodetect = "TRUE"

# PCIe topology — required so e1000e (and other PCIe devices) can find a slot.
# Without these VMware errors out with "No PCIe slot available for Ethernet0".
pciBridge0.present = "TRUE"
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
pciBridge6.present = "TRUE"
pciBridge6.virtualDev = "pcieRootPort"
pciBridge6.functions = "8"
pciBridge7.present = "TRUE"
pciBridge7.virtualDev = "pcieRootPort"
pciBridge7.functions = "8"

ethernet0.present = "TRUE"
ethernet0.virtualDev = "e1000e"
ethernet0.connectionType = "nat"
ethernet0.addressType = "generated"
ethernet0.pciSlotNumber = "192"

usb.present = "TRUE"
ehci.present = "TRUE"
xhci.present = "TRUE"

sound.present = "FALSE"
floppy0.present = "FALSE"
serial0.present = "FALSE"

tools.syncTime = "TRUE"
tools.upgrade.policy = "manual"

mks.enable3d = "FALSE"
hpet0.present = "TRUE"
vmci0.present = "TRUE"

powerType.powerOff = "soft"
powerType.powerOn = "soft"
powerType.suspend = "soft"
powerType.reset = "soft"
EOF

echo "[+] Done: $OUT_DIR"
echo "    Open in VMware: vmware $VMX"
