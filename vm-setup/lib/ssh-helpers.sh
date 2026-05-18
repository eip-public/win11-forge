# shellcheck shell=bash
# Common SSH/SCP options used by win11-forge VM provisioning scripts.
# Sourced by setup-vm.sh, seal-vm-gold.sh, role-bootstrap-target.sh,
# role-bootstrap-debugger.sh.
#
# This file holds only the truly-shared options. Each caller keeps its
# own auth strategy (key vs password vs both), timeouts, retry counts,
# and output formatting — those legitimately differ between callers
# and forcing a single helper would lose those differences.
#
# scp accepts -o flags too (passes them through to ssh), so this array
# is valid for both ssh and scp invocations.
# shellcheck disable=SC2034  # consumed by sourcing scripts
SSH_OPTS_COMMON=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
)
