#!/bin/bash
#
# WinForge VM Creation Script
#
# Creates a Windows 11 QEMU/KVM VM with unattended install.
# Handles the UEFI CD boot prompt issue by monitoring and re-sending keys.
#
# Usage:
#   ./create-vm.sh [--iso PATH] [--name NAME] [--ram 4096] [--cpus 4] [--disk-size 64G]
#
# Prerequisites:
#   - QEMU/KVM + libvirt installed
#   - Windows ISO at vm-images/win11-ltsc.iso (or specify --iso)
#   - VirtIO drivers at vm-images/virtio-win.iso
#   - autounattend.xml configured

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PHASE0_DIR="$(dirname "$SCRIPT_DIR")"
IMAGES_DIR="$PHASE0_DIR/vm-images"

# Defaults
VM_NAME="${VM_NAME:-winforge-dev}"
VM_RAM="${VM_RAM:-4096}"
VM_CPUS="${VM_CPUS:-4}"
DISK_SIZE="${DISK_SIZE:-64G}"
ISO="${ISO:-$IMAGES_DIR/win11-ltsc.iso}"
VIRTIO_ISO="$IMAGES_DIR/virtio-win.iso"
UNATTEND_ISO="$IMAGES_DIR/unattend.iso"
QCOW2="$IMAGES_DIR/${VM_NAME}.qcow2"
SSH_KEY="$PHASE0_DIR/vm-ssh-key"
VM_IP="192.168.122.100"
VNC_PORT=5900
UNATTEND_XML="$SCRIPT_DIR/autounattend.xml"
VM_USER="forge"
VM_PASS="forge123"
# Default MAC pins this VM to 192.168.122.100 via libvirt DHCP host reservation
# that setup.sh adds to the default network. Override --mac for pair spawns
# (e.g. the debugger role uses a different MAC to get .101).
VM_MAC="${VM_MAC:-52:54:00:11:11:11}"

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --iso) ISO="$2"; shift 2;;
    --name) VM_NAME="$2"; QCOW2="$IMAGES_DIR/${VM_NAME}.qcow2"; shift 2;;
    --ram) VM_RAM="$2"; shift 2;;
    --cpus) VM_CPUS="$2"; shift 2;;
    --disk-size) DISK_SIZE="$2"; shift 2;;
    --mac) VM_MAC="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# Detect os-variant from VM name or ISO filename
detect_os_variant() {
  local name="${1,,}"
  if [[ "$name" == *server2025* || "$name" == *srv2025* ]]; then echo "win2k22"
  elif [[ "$name" == *server2022* || "$name" == *srv2022* ]]; then echo "win2k22"
  elif [[ "$name" == *server2019* || "$name" == *srv2019* ]]; then echo "win2k19"
  elif [[ "$name" == *win10* ]]; then echo "win10"
  else echo "win11"
  fi
}
OS_VARIANT=$(detect_os_variant "$VM_NAME-$(basename "$ISO")")

if [[ "$OS_VARIANT" == "win2k22" || "$OS_VARIANT" == "win2k19" ]]; then
  UNATTEND_XML="$SCRIPT_DIR/autounattend-server.xml"
  VM_USER="Administrator"
  VM_PASS="forge123F"
fi

guest_state_via_password() {
  timeout 10 sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=3 -o LogLevel=ERROR "$VM_USER@$VM_IP" \
    "powershell -NoProfile -Command \"if (Test-Path 'C:\\winforge\\ready.json') { try { (Get-Content 'C:\\winforge\\ready.json' -Raw | ConvertFrom-Json).state } catch { 'invalid' } } else { 'missing' }\"" \
    2>/dev/null | tr -d '\r' | tail -1
}

echo "=== WinForge VM Creation ==="
echo "  Name:     $VM_NAME"
echo "  ISO:      $ISO"
echo "  OS:       $OS_VARIANT"
echo "  RAM:      ${VM_RAM}MB"
echo "  CPUs:     $VM_CPUS"
echo "  Disk:     $DISK_SIZE"
echo ""

# ── Detect source type (ISO vs VHD/VHDX) ──────────────────────────

IS_VHD=false
case "${ISO,,}" in
  *.vhd|*.vhdx) IS_VHD=true ;;
  *)
    if file "$ISO" 2>/dev/null | grep -qi "Microsoft Disk Image\|Virtual Server\|Virtual PC"; then
      IS_VHD=true
    fi
    ;;
esac

# ── Preflight checks ──────────────────────────────────────────────

check_file() { [[ -f "$1" ]] || { echo "ERROR: $1 not found"; exit 1; }; }
check_file "$ISO"
if [[ "$IS_VHD" == "false" ]]; then
  check_file "$VIRTIO_ISO"
fi

which virsh >/dev/null 2>&1 || { echo "ERROR: virsh not found. Install libvirt."; exit 1; }
which qemu-img >/dev/null 2>&1 || { echo "ERROR: qemu-img not found. Install qemu-utils."; exit 1; }

if [[ "$IS_VHD" == "true" ]]; then
  echo "[*] VHD detected — will convert to QCOW2 and boot directly (no ISO install)"
fi

# ── Generate SSH key if needed ─────────────────────────────────────

if [[ ! -f "$SSH_KEY" ]]; then
  echo "[*] Generating SSH key..."
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N '' -q
fi

# ── Build unattend ISO (only for ISO installs) ─────────────────────

if [[ "$IS_VHD" == "false" ]]; then
  echo "[*] Building unattend ISO..."
  UNATTEND_DIR="$PHASE0_DIR/unattend-iso"
  UNATTEND_BUILD_DIR=$(mktemp -d)
  cp -a "$UNATTEND_DIR/." "$UNATTEND_BUILD_DIR/"
  cp "$UNATTEND_XML" "$UNATTEND_BUILD_DIR/autounattend.xml"
  rm -f "$UNATTEND_ISO"
  genisoimage -o "$UNATTEND_ISO" -J -r "$UNATTEND_BUILD_DIR/" 2>/dev/null
  rm -rf "$UNATTEND_BUILD_DIR"
fi

# ── Clean up old VM ────────────────────────────────────────────────

if sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  echo "[*] Removing existing VM '$VM_NAME'..."
  sudo virsh destroy "$VM_NAME" 2>/dev/null || true
  # Delete snapshots metadata first
  for snap in $(sudo virsh snapshot-list "$VM_NAME" --name 2>/dev/null); do
    sudo virsh snapshot-delete "$VM_NAME" "$snap" --metadata 2>/dev/null || true
  done
  sudo virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
fi

# ── Create disk ────────────────────────────────────────────────────

if [[ "$IS_VHD" == "true" ]]; then
  echo "[*] Converting VHD to QCOW2 (this may take a few minutes)..."
  rm -f "$QCOW2"
  qemu-img convert -f vpc -O qcow2 "$ISO" "$QCOW2"
  # Resize if the VHD is smaller than requested
  CURRENT_SIZE=$(qemu-img info --output=json "$QCOW2" | python3 -c "import sys,json; print(json.load(sys.stdin)['virtual-size'])" 2>/dev/null || echo 0)
  REQUESTED_BYTES=$(numfmt --from=iec "$DISK_SIZE" 2>/dev/null || echo 0)
  if [[ "$REQUESTED_BYTES" -gt "$CURRENT_SIZE" ]]; then
    qemu-img resize "$QCOW2" "$DISK_SIZE"
    echo "[+] Disk resized to $DISK_SIZE"
  fi
  echo "[+] Converted: $QCOW2"
else
  echo "[*] Creating $DISK_SIZE QCOW2 disk..."
  rm -f "$QCOW2"
  qemu-img create -f qcow2 "$QCOW2" "$DISK_SIZE" >/dev/null
  echo "[+] Created: $QCOW2"
fi

# ── Fix permissions for libvirt-qemu access ────────────────────────
# Walk parent dirs adding o+rx so the qemu user can traverse to the qcow2s.
# Stop at $HOME (not /) — walking past $HOME silently widened world-read
# across the user's home and any sibling files under it.

DIR="$IMAGES_DIR"
while [[ "$DIR" != "/" && "$DIR" != "$HOME" ]]; do
  chmod o+rx "$DIR" 2>/dev/null || true
  DIR=$(dirname "$DIR")
done
chmod o+r "$IMAGES_DIR"/* 2>/dev/null || true

# ── Launch VM ──────────────────────────────────────────────────────

echo "[*] Launching VM..."
if [[ "$IS_VHD" == "true" ]]; then
  # VHDs from Microsoft are MBR (legacy BIOS), not UEFI
  VIRT_INSTALL_LOG=$(mktemp)
  if ! sudo virt-install \
    --check path_in_use=off \
    --name "$VM_NAME" \
    --ram "$VM_RAM" \
    --vcpus "$VM_CPUS" \
    --os-variant "$OS_VARIANT" \
    --disk "path=$QCOW2,format=qcow2,bus=sata,cache=writeback" \
    --network network=default,model=e1000e,mac="$VM_MAC" \
    --graphics vnc,listen=127.0.0.1 \
    --video qxl \
    --boot hd \
    --import \
    --noautoconsole >"$VIRT_INSTALL_LOG" 2>&1; then
    echo "[!] virt-install failed for $VM_NAME"
    tail -n 40 "$VIRT_INSTALL_LOG" || true
    rm -f "$VIRT_INSTALL_LOG"
    exit 1
  fi
  rm -f "$VIRT_INSTALL_LOG"


  echo "[*] VHD imported. Waiting for VM to boot..."
  echo "    VNC available (check: virsh vncdisplay $VM_NAME)"
  echo "    NOTE: VHD images may require manual OOBE setup via VNC"
  echo "          (user/password creation, network config, SSH enabling)"

  MAX_WAIT=300
  ELAPSED=0
  while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    sleep 15
    ELAPSED=$((ELAPSED + 15))
    DHCP_IP=$(sudo virsh net-dhcp-leases default 2>/dev/null | grep -oP '192\.168\.122\.\d+' | head -1)
    TARGET_IP="${DHCP_IP:-$VM_IP}"
    if timeout 10 sshpass -p 'forge123' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o ConnectTimeout=3 -o LogLevel=ERROR "forge@$TARGET_IP" "echo OK" 2>/dev/null | grep -q OK; then
      echo "[+] SSH available at $TARGET_IP!"
      VM_IP="$TARGET_IP"
      break
    fi
    printf "\r    %ds elapsed, waiting for SSH..." "$ELAPSED"
  done
  echo ""
else
  VIRT_INSTALL_LOG=$(mktemp)
  if ! sudo virt-install \
    --check path_in_use=off \
    --name "$VM_NAME" \
    --ram "$VM_RAM" \
    --vcpus "$VM_CPUS" \
    --os-variant "$OS_VARIANT" \
    --disk "path=$QCOW2,format=qcow2,bus=sata,cache=writeback" \
    --cdrom "$ISO" \
    --disk "path=$VIRTIO_ISO,device=cdrom" \
    --disk "path=$UNATTEND_ISO,device=cdrom" \
    --network network=default,model=e1000e,mac="$VM_MAC" \
    --graphics vnc,listen=127.0.0.1 \
    --video qxl \
    --boot uefi \
    --noautoconsole >"$VIRT_INSTALL_LOG" 2>&1; then
    echo "[!] virt-install failed for $VM_NAME"
    tail -n 40 "$VIRT_INSTALL_LOG" || true
    rm -f "$VIRT_INSTALL_LOG"
    exit 1
  fi
  rm -f "$VIRT_INSTALL_LOG"


  # ── Handle CD boot prompt ─────────────────────────────────────────
  # UEFI takes a few seconds before showing "Press any key to boot from CD".
  # Send keys aggressively over a longer window to catch it.

  echo "[*] Sending keypress for CD boot..."
  sleep 2
  for i in $(seq 1 30); do
    sudo virsh send-key "$VM_NAME" KEY_ENTER 2>/dev/null || true
    sleep 0.5
  done

  # ── Monitor install ────────────────────────────────────────────────

  echo "[*] Monitoring Windows install (this takes ~10 minutes)..."
  echo "    VNC available (check: virsh vncdisplay $VM_NAME)"

  PHASE1_DONE=false
  MAX_WAIT=1800
  ELAPSED=0

  while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    sleep 15
    ELAPSED=$((ELAPSED + 15))

    STATE=$(sudo virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")

    if [[ "$STATE" == "shut off" ]]; then
      if [[ "$PHASE1_DONE" == "false" ]]; then
        echo "[+] Phase 1 complete (VM shut off). Starting phase 2..."
        PHASE1_DONE=true
        sudo virsh start "$VM_NAME" 2>/dev/null
      else
        echo "[+] Phase 2 complete (VM shut off). Starting final boot..."
        sudo virsh start "$VM_NAME" 2>/dev/null
      fi
    elif [[ "$STATE" == "running" ]]; then
      # Wait for SSH — IP assigned via DHCP MAC reservation (192.168.122.100).
      # `timeout 10` caps the whole attempt: ConnectTimeout=3 only covers TCP
      # SYN; without an outer timeout, a hung post-auth ssh session (Windows
      # sshd occasionally hangs the first session during first-boot warmup)
      # would deadlock the pipe, the iteration never finishes, and MAX_WAIT
      # cannot fire because $ELAPSED stops advancing. A 39-min hang was
      # observed before this guard was added.
      if timeout 10 sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -o ConnectTimeout=3 -o LogLevel=ERROR "$VM_USER@$VM_IP" "echo OK" 2>/dev/null | grep -q OK; then
        GUEST_STATE="$(guest_state_via_password || true)"
        GUEST_STATE="${GUEST_STATE:-probe_pending}"
        case "$GUEST_STATE" in
          bootstrap_ready|ready)
            echo "[+] Guest bootstrap ready ($GUEST_STATE). Install complete."
            break
            ;;
          error)
            echo "[-] Guest bootstrap reported error. Check C:\\winforge\\bootstrap.log via VNC/SSH."
            exit 1
            ;;
        esac
      fi

      printf "\r    %ds elapsed, domain: %s, guest: %s" "$ELAPSED" "$STATE" "${GUEST_STATE:-waiting}"
    fi
  done
  echo ""

  if [[ $ELAPSED -ge $MAX_WAIT ]]; then
    echo "[-] Timeout waiting for install. Check VNC at :$VNC_PORT"
    exit 1
  fi
fi

echo ""
echo "[+] VM is up. Running post-install setup..."
echo "    IP: $VM_IP"

# ── Post-install setup ─────────────────────────────────────────────

# Run the setup script
"$SCRIPT_DIR/setup-vm.sh" --ip "$VM_IP" --user "$VM_USER" --password "$VM_PASS" --ssh-key "$SSH_KEY"

echo ""
echo "=== VM READY ==="
echo "  Name:    $VM_NAME"
echo "  IP:      $VM_IP"
echo "  SSH:     ssh -i $SSH_KEY $VM_USER@$VM_IP"
echo "  Build:   $(sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$VM_USER@$VM_IP" 'cmd /c ver' 2>/dev/null | tr -d '\r\n')"
