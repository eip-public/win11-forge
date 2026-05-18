# shellcheck shell=bash
# Shared defaults for win11-forge VM provisioning. Profile-specific
# defaults (VM_NAME, VM_RAM) stay in setup.sh / create-vm.sh — the
# gold-build profile differs from standalone create-vm.sh.
#
# := lets environment overrides win at source time; flags override
# env later in each script.

# Single source of truth for MAC addresses.
# shellcheck source=macs.env
. "$(dirname "${BASH_SOURCE[0]}")/macs.env"

: "${VM_CPUS:=4}"
: "${DISK_SIZE:=64G}"
: "${VM_USER:=forge}"
: "${VM_PASS:=forge123}"
: "${VM_IP:=192.168.122.100}"
# The single-VM gold-build VM and the KVM lab target share an identity:
# the lab target is just a fresh overlay on the gold. Same MAC.
: "${VM_MAC:=$KVM_TARGET_MAC}"
