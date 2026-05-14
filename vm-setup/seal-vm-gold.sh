#!/usr/bin/env bash
#
# WinForge VM Gold Sealer
#
# Turns a running, reachable VM into a flat gold image only after
# host-side verification passes. Optionally boots from a disposable
# overlay on top of the new gold to prove the baseline is reproducible.
#
# Usage:
#   ./seal-vm-gold.sh --vm winforge-server2019 --ip 192.168.122.186
#   ./seal-vm-gold.sh --vm winforge-win11-24h2 --ip 192.168.122.100 --verify-restore
#

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
IMAGES_DIR="$REPO_ROOT/vm-images"
SETUP_VM="$SCRIPT_DIR/setup-vm.sh"
# shellcheck source=lib/ssh-helpers.sh
. "$SCRIPT_DIR/lib/ssh-helpers.sh"

VM_NAME=""
VM_IP="192.168.122.100"
VM_USER="forge"
VM_PASS="forge123"
SSH_KEY="${REPO_ROOT}/vm-ssh-key"
VERIFY_RESTORE=false
SKIP_SETUP=false
SSH_TIMEOUT_SECONDS="${SSH_TIMEOUT_SECONDS:-600}"
USE_KEY=false
RESTORE_ORIGINAL_SOURCE=""

usage() {
  cat <<'EOF'
Usage:
  seal-vm-gold.sh --vm <name> [--ip <ip>] [--user <user>] [--password <password>] [--ssh-key <path>] [--verify-restore] [--skip-setup]

Options:
  --vm <name>           VM/domain name to seal.
  --ip <ip>             Reachable guest IP address.
  --user <user>         SSH user to use. Default: forge
  --password <pass>     Guest password for SSH bootstrap. Default: forge123
  --ssh-key <path>      SSH private key to prefer when present.
  --verify-restore      Boot from a disposable overlay on the new gold and rerun verification.
  --skip-setup          Skip setup-vm.sh and only run verification + flattening.
  --help                Show this message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)
      VM_NAME="$2"
      shift 2
      ;;
    --ip)
      VM_IP="$2"
      shift 2
      ;;
    --user)
      VM_USER="$2"
      shift 2
      ;;
    --password)
      VM_PASS="$2"
      shift 2
      ;;
    --ssh-key)
      SSH_KEY="$2"
      shift 2
      ;;
    --verify-restore)
      VERIFY_RESTORE=true
      shift
      ;;
    --skip-setup)
      SKIP_SETUP=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "$VM_NAME" ]] || { usage >&2; exit 1; }
[[ -x "$SETUP_VM" ]] || { echo "Missing setup script: $SETUP_VM" >&2; exit 1; }

log() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

ssh_base() {
  # ServerAliveInterval prevents the session hanging indefinitely if the remote
  # stops responding (e.g. during Windows shutdown triggered by request_guest_shutdown).
  if [[ "$USE_KEY" == "true" && -f "$SSH_KEY" ]]; then
    ssh -i "$SSH_KEY" "${SSH_OPTS_COMMON[@]}" \
      -o BatchMode=yes \
      -o ServerAliveInterval=10 -o ServerAliveCountMax=6 \
      -o PreferredAuthentications=publickey -o PasswordAuthentication=no \
      -o KbdInteractiveAuthentication=no "$VM_USER@$VM_IP" "$@"
  else
    sshpass -p "$VM_PASS" ssh "${SSH_OPTS_COMMON[@]}" \
      -o ServerAliveInterval=10 -o ServerAliveCountMax=6 \
      "$VM_USER@$VM_IP" "$@"
  fi
}

scp_base() {
  if [[ "$USE_KEY" == "true" && -f "$SSH_KEY" ]]; then
    scp -i "$SSH_KEY" "${SSH_OPTS_COMMON[@]}" \
      -o BatchMode=yes \
      -o PreferredAuthentications=publickey -o PasswordAuthentication=no \
      -o KbdInteractiveAuthentication=no "$@"
  else
    sshpass -p "$VM_PASS" scp "${SSH_OPTS_COMMON[@]}" "$@"
  fi
}

cleanup_restore_disk() {
  [[ -n "$RESTORE_ORIGINAL_SOURCE" ]] || return 0
  log "Cleaning up restore verification state"
  shutdown_vm || true
  set_vm_disk_source "$RESTORE_ORIGINAL_SOURCE" || true
  RESTORE_ORIGINAL_SOURCE=""
}

on_error() {
  cleanup_restore_disk
}

trap on_error ERR

can_use_key() {
  [[ -f "$SSH_KEY" ]] || return 1
  ssh -i "$SSH_KEY" "${SSH_OPTS_COMMON[@]}" -o BatchMode=yes \
    -o PreferredAuthentications=publickey -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no "$VM_USER@$VM_IP" "echo OK" 2>/dev/null | tr -d '\r' | grep -q '^OK$'
}

wait_for_ssh() {
  local loops=$((SSH_TIMEOUT_SECONDS / 5))
  local i
  for ((i = 1; i <= loops; i++)); do
    if ssh_base "echo OK" 2>/dev/null | tr -d '\r' | grep -q '^OK$'; then
      return 0
    fi
    sleep 5
  done
  return 1
}

read_guest_state() {
  ssh_base "powershell -NoProfile -Command \"if (Test-Path 'C:\\winforge\\ready.json') { try { (Get-Content 'C:\\winforge\\ready.json' -Raw | ConvertFrom-Json).state } catch { 'invalid' } } else { 'missing' }\"" 2>/dev/null | tr -d '\r' | tail -1
}

wait_for_tools_ready() {
  local loops=$((SSH_TIMEOUT_SECONDS / 5))
  local i state
  for ((i = 1; i <= loops; i++)); do
    state="$(read_guest_state)"
    if [[ "$state" == "tools_ready" ]]; then
      return 0
    fi
    if [[ "$state" == "error" ]]; then
      echo "Guest reported error state in C:\\winforge\\ready.json" >&2
      return 1
    fi
    sleep 5
  done
  echo "Timed out waiting for tools_ready in C:\\winforge\\ready.json (last state: ${state:-unknown})" >&2
  return 1
}

domain_disk_source() {
  # Capture virsh output first to avoid SIGPIPE when awk exits early (pipefail).
  local out
  out=$(virsh domblklist "$VM_NAME" 2>/dev/null)
  awk 'NR > 2 && $1 == "sda" { print $2; exit }' <<< "$out"
}

set_vm_disk_source() {
  local disk_path="$1"
  local xml_path
  xml_path="$(mktemp)"
  virsh dumpxml "$VM_NAME" >"$xml_path"
  python3 "$SCRIPT_DIR/lib/set-disk-source.py" "$xml_path" "$disk_path"
  virsh define "$xml_path" >/dev/null
  rm -f "$xml_path"
}

wait_for_vm_off() {
  local i
  for i in $(seq 1 60); do
    if [[ "$(virsh domstate "$VM_NAME" 2>/dev/null | tr -d '\r')" == "shut off" ]]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

request_guest_shutdown() {
  ssh_base "powershell -NoProfile -ExecutionPolicy Bypass -Command \"Start-Process shutdown.exe -ArgumentList '/s','/t','0' -WindowStyle Hidden\"" >/dev/null 2>&1 || \
  ssh_base "cmd /c shutdown /s /t 0" >/dev/null 2>&1 || true
}

shutdown_vm() {
  if [[ "$(virsh domstate "$VM_NAME" 2>/dev/null | tr -d '\r')" == "running" ]]; then
    log "Shutting down $VM_NAME"
    request_guest_shutdown
    sleep 5
    virsh shutdown "$VM_NAME" >/dev/null 2>&1 || true
    if ! wait_for_vm_off; then
      log "Graceful shutdown timed out; forcing $VM_NAME off"
      virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
      wait_for_vm_off || true
    fi
  fi
}

verify_guest() {
  local verify_ps1
  verify_ps1="$(mktemp --suffix=.ps1)"
  cat >"$verify_ps1" <<'EOF'
Write-Host "OS:      $(cmd /c ver 2>&1 | Select-String Version)"
$cdb = Get-Command cdb.exe -EA SilentlyContinue
if ($cdb) { Write-Host "CDB:     $($cdb.Source)" } else { Write-Host "CDB:     NOT FOUND" }
$cl = Get-ChildItem -Path "C:\Program Files*\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe" -EA SilentlyContinue | Select-Object -First 1
if ($cl) { Write-Host "cl.exe:  $($cl.FullName)" } else { Write-Host "cl.exe:  NOT FOUND" }
$py = Get-Command python -EA SilentlyContinue
if ($py) { Write-Host "Python:  $($py.Source)" } else { Write-Host "Python:  NOT FOUND" }
$git = Get-Command git -EA SilentlyContinue
if ($git) { Write-Host "Git:     $($git.Source)" } else { Write-Host "Git:     NOT FOUND" }
Write-Host "SSH:     $(Get-Service sshd | Select-Object -ExpandProperty Status)"
Write-Host "FW:      $(Get-NetFirewallProfile -Name Domain | Select-Object -ExpandProperty Enabled)"
if (-not $cdb -or -not $cl -or -not $py -or -not $git) {
    throw "Guest verification failed: required tool missing"
}
if ((Get-Service sshd).Status -ne "Running") {
    throw "Guest verification failed: sshd is not running"
}
if ((Get-NetFirewallProfile -Name Domain).Enabled) {
    throw "Guest verification failed: domain firewall is enabled"
}
Write-Host "VERIFY_OK"
EOF
  scp_base "$verify_ps1" "$VM_USER@$VM_IP:C:/winforge/verify.ps1"
  rm -f "$verify_ps1"
  local verify_output verify_rc
  set +e
  verify_output="$(ssh_base "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\winforge\\verify.ps1" 2>&1)"
  verify_rc=$?
  set -e
  printf '%s\n' "$verify_output"
  if printf '%s\n' "$verify_output" | tr -d '\r' | grep -q '^VERIFY_OK$'; then
    return 0
  fi
  if [[ "$verify_rc" -eq 0 ]]; then
    return 1
  fi
  return "$verify_rc"
}

verify_guest_with_retry() {
  local attempt
  for attempt in 1 2 3; do
    if verify_guest; then
      return 0
    fi
    log "Guest verification attempt $attempt failed; retrying after SSH settles"
    sleep 10
    wait_for_ssh || true
  done
  return 1
}

GOLD_PATH="$IMAGES_DIR/${VM_NAME}-gold.qcow2"
RESTORE_OVERLAY="$IMAGES_DIR/${VM_NAME}.seal-verify.qcow2"

log "Sealing $VM_NAME at $VM_IP"

if [[ "$SKIP_SETUP" != "true" ]]; then
  log "Running setup-vm.sh before sealing"
  "$SETUP_VM" --ip "$VM_IP" --user "$VM_USER" --password "$VM_PASS" --ssh-key "$SSH_KEY"
fi

if can_use_key; then
  USE_KEY=true
  log "Using SSH key auth for sealing"
else
  log "SSH key auth unavailable for $VM_USER@$VM_IP; using password auth"
fi

log "Waiting for SSH"
wait_for_ssh || { echo "SSH did not become ready on $VM_IP" >&2; exit 1; }

log "Waiting for guest tools_ready state"
wait_for_tools_ready || { echo "Guest did not report tools_ready on $VM_IP" >&2; exit 1; }

log "Running guest verification"
verify_guest_with_retry

ACTIVE_DISK="$(domain_disk_source)"
[[ -n "$ACTIVE_DISK" ]] || { echo "Could not determine active disk source for $VM_NAME" >&2; exit 1; }
log "Active disk source: $ACTIVE_DISK"

log "Starting shutdown before flatten"
shutdown_vm
log "VM state after shutdown: $(virsh domstate "$VM_NAME" 2>/dev/null | tr -d '\r')"

log "Flattening $ACTIVE_DISK to $GOLD_PATH"
# Convert to a temp file first — the working disk may be an overlay backed by
# the old gold, so deleting the gold before converting would break the chain.
gold_tmp="${GOLD_PATH}.tmp"
rm -f "$gold_tmp"
qemu-img convert -O qcow2 "$ACTIVE_DISK" "$gold_tmp"
qemu-img info "$gold_tmp" >/dev/null
mv -f "$gold_tmp" "$GOLD_PATH"
log "Flatten complete: $GOLD_PATH"

if [[ "$VERIFY_RESTORE" == "true" ]]; then
  log "Verifying restore from disposable overlay"
  rm -f "$RESTORE_OVERLAY" "$RESTORE_OVERLAY.tmp"
  qemu-img create -f qcow2 -b "$GOLD_PATH" -F qcow2 "$RESTORE_OVERLAY.tmp" >/dev/null
  mv -f "$RESTORE_OVERLAY.tmp" "$RESTORE_OVERLAY"
  log "Restore overlay ready: $RESTORE_OVERLAY"

  ORIGINAL_SOURCE="$ACTIVE_DISK"
  RESTORE_ORIGINAL_SOURCE="$ORIGINAL_SOURCE"
  log "Switching $VM_NAME disk to restore overlay"
  set_vm_disk_source "$RESTORE_OVERLAY"
  log "Starting $VM_NAME for restore verification"
  virsh start "$VM_NAME" >/dev/null
  log "Waiting for SSH during restore verification"
  wait_for_ssh || { echo "SSH did not return during restore verification" >&2; exit 1; }
  log "Waiting for tools_ready during restore verification"
  wait_for_tools_ready || { echo "Guest did not report tools_ready during restore verification" >&2; exit 1; }
  log "Running guest verification on restore overlay"
  verify_guest_with_retry
  log "Shutting down after restore verification"
  shutdown_vm
  log "Restoring original disk source: $ORIGINAL_SOURCE"
  set_vm_disk_source "$ORIGINAL_SOURCE"
  RESTORE_ORIGINAL_SOURCE=""
  log "Restore verification passed"
fi

log "Gold image ready: $GOLD_PATH"
