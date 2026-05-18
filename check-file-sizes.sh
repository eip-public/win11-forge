#!/usr/bin/env bash
# Detect overly large files in the repo.
#
# Two caps are enforced against every git-tracked file:
#
#   - MAX_BYTES   binary-file size cap, defends hard rule 8
#                 ("no surprise vendored binaries" — see CLAUDE.md).
#                 New vendored artifacts must be fetched at install
#                 time with a sha256 check, not committed.
#   - MAX_LINES   text-file line-count cap. Flags source files that
#                 have grown into refactor-me territory. Largest
#                 in-scope file today (setup.sh) is ~920 lines, so
#                 the 1500-line cap leaves ~60% headroom while
#                 catching genuine bloat early.
#
# Out of scope (excluded by path):
#   - lab/**                     per-CVE PoC scratch and ghidriff
#                                outputs; intentionally large
#                                generated artifacts.
#   - vm-setup/third-party/**    vendored upstream forks; their
#                                upstream owns the size policy.
#
# Allowlisted (counted but not failed):
#   - unattend-iso/OpenSSH-Win64.zip   grandfathered Microsoft binary
#                                      (CLAUDE.md hard rule 8).
#
# Exits non-zero if any non-allowlisted file breaches either cap.
# Invoked by .github/workflows/large-files.yml on every push and PR.

set -Eeuo pipefail

MAX_BYTES=$((1 * 1024 * 1024))
MAX_LINES=1500

BYTES_ALLOWLIST=(
    "unattend-iso/OpenSSH-Win64.zip"
)

EXCLUDE_PATHSPECS=(
    ':(exclude)lab/**'
    ':(exclude)vm-setup/third-party/**'
)

is_bytes_allowlisted() {
    local f=$1
    local entry
    for entry in "${BYTES_ALLOWLIST[@]}"; do
        if [[ "$f" == "$entry" ]]; then
            return 0
        fi
    done
    return 1
}

is_binary() {
    # `file --mime` is portable across GNU file (Linux/CI) and BSD file
    # (macOS local dev). `charset=binary` is the standard marker for
    # non-text content. Fall back to "treat as text" if `file` fails
    # so a missing tool doesn't silently skip the line-count check.
    local f=$1
    local mime
    mime=$(file --mime --brief -- "$f" 2>/dev/null || true)
    [[ "$mime" == *"charset=binary"* ]]
}

print_failures() {
    local label=$1
    shift
    if (($# == 0)); then
        return 0
    fi
    printf '\n%s:\n' "$label"
    printf '  %s\n' "$@"
}

main() {
    local repo_root
    repo_root=$(git rev-parse --show-toplevel)
    cd "$repo_root"

    local oversize_bytes=()
    local oversize_lines=()
    local checked=0

    # NUL-delimited so paths with spaces or newlines survive.
    while IFS= read -r -d '' f; do
        # Tracked but deleted/symlink-to-nowhere: skip.
        [[ -f "$f" ]] || continue
        checked=$((checked + 1))

        local sz
        sz=$(wc -c <"$f" | tr -d ' ')
        if ((sz > MAX_BYTES)) && ! is_bytes_allowlisted "$f"; then
            oversize_bytes+=("$(printf '%s (%d bytes, cap %d)' "$f" "$sz" "$MAX_BYTES")")
        fi

        # Line-count cap applies to text files only — binary blobs
        # have meaningless "line counts" (newline-byte frequency).
        if ! is_binary "$f"; then
            local lines
            lines=$(wc -l <"$f" | tr -d ' ')
            if ((lines > MAX_LINES)); then
                oversize_lines+=("$(printf '%s (%d lines, cap %d)' "$f" "$lines" "$MAX_LINES")")
            fi
        fi
    done < <(git ls-files -z -- . "${EXCLUDE_PATHSPECS[@]}")

    local fail=0
    if ((${#oversize_bytes[@]} > 0)); then
        print_failures "Files exceeding ${MAX_BYTES}-byte cap" "${oversize_bytes[@]}"
        fail=1
    fi
    if ((${#oversize_lines[@]} > 0)); then
        print_failures "Files exceeding ${MAX_LINES}-line cap" "${oversize_lines[@]}"
        fail=1
    fi

    if ((fail == 0)); then
        printf 'OK: %d tracked files within size and line-count caps.\n' "$checked"
    else
        printf '\nFAIL: see violations above.\n'
        printf 'If a new binary is unavoidable, fetch it at install time with a\n'
        printf 'sha256 check instead of committing it (CLAUDE.md hard rule 8).\n'
        printf 'If a source file is genuinely growing, prefer splitting it over\n'
        printf 'raising the cap.\n'
    fi
    return "$fail"
}

main "$@"
