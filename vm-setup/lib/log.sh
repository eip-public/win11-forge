# shellcheck shell=bash
# Shared status helpers used by win11-forge bash scripts.
#
# Only the truly-identical helpers (ok/warn/die) live here. Each script
# keeps its own log() because conventions legitimately differ:
#   - setup.sh: timestamped [HH:MM:SS], long-running operations
#   - install-deps.sh / fetch-isos.sh: [*] prefix, one-shot scripts
#   - seal-vm-gold.sh: bracketed timestamp, no colors
# Forcing a single log() would lose intentional per-script convention.
ok() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2
    exit 1
}
