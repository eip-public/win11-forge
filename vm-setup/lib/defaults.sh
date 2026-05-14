# Shared defaults for win11-forge VM provisioning. Profile-specific
# defaults (VM_NAME, VM_RAM) stay in setup.sh / create-vm.sh — the
# gold-build profile differs from standalone create-vm.sh.
#
# := lets environment overrides win at source time; flags override
# env later in each script.
: "${VM_CPUS:=4}"
: "${DISK_SIZE:=64G}"
: "${VM_USER:=forge}"
: "${VM_PASS:=forge123}"
: "${VM_IP:=192.168.122.100}"
: "${VM_MAC:=52:54:00:11:11:11}"
