# shellcheck shell=bash
# Shared libvirt cleanup helpers.
#
# virsh_or_warn — wrapper for virsh calls (destroy/undefine/snapshot-delete/
# shutdown/start) that previously had `|| true` masking real failures.
# Tolerates the legitimate "already in target state" cases silently;
# warns to stderr on anything else so the user sees the real libvirt
# error instead of a downstream collision ("domain is already defined", etc.).
#
# Always returns 0 — callers should rely on the warning text, not exit code.
virsh_or_warn() {
    # `out="$(...)"` without an `|| ...` clause would trip the caller's `set -e`
    # the moment virsh exits non-zero — *before* this function can inspect the
    # exit code and decide whether to warn or stay silent. Capture rc via the
    # `|| rc=$?` idiom instead.
    local out rc=0
    out="$(virsh "$@" 2>&1)" || rc=$?
    (( rc == 0 )) && return 0
    case "$out" in
        *"Domain not found"*|*"failed to get domain"*) ;;
        *"is not running"*|*"already inactive"*) ;;
        *"is already active"*|*"already running"*) ;;
        *"no snapshot"*|*"snapshot file does not exist"*) ;;
        *) printf '\033[1;33m[!]\033[0m virsh %s — %s\n' "$*" "${out//$'\n'/ | }" >&2 ;;
    esac
    return 0
}
