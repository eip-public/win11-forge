#!/usr/bin/env bats

setup() {
    export REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export TEST_TMP="$BATS_TEST_TMPDIR"
    export PATH="$TEST_TMP/bin:$PATH"
    export IMAGES_DIR="$TEST_TMP/images"
    export VM_NAME="winforge-win11-24h2"
    mkdir -p "$TEST_TMP/bin" "$IMAGES_DIR"
    : > "$TEST_TMP/calls.log"
    : > "$IMAGES_DIR/${VM_NAME}-gold.qcow2"

    cat > "$TEST_TMP/bin/virsh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    dominfo)
        printf 'virsh dominfo %s\n' "${2:-}" >> "$TEST_TMP/calls.log"
        exit 0
        ;;
    destroy)
        printf 'virsh destroy %s\n' "${2:-}" >> "$TEST_TMP/calls.log"
        ;;
    undefine)
        printf 'virsh undefine %s %s\n' "${2:-}" "${3:-}" >> "$TEST_TMP/calls.log"
        ;;
    define)
        printf 'virsh define\n' >> "$TEST_TMP/calls.log"
        ;;
    *)
        printf 'unexpected virsh command: %s\n' "$*" >&2
        exit 2
        ;;
esac
SH
    chmod +x "$TEST_TMP/bin/virsh"

    cat > "$TEST_TMP/bin/qemu-img" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'qemu-img %s\n' "$*" >> "$TEST_TMP/calls.log"
touch "${@: -1}"
SH
    chmod +x "$TEST_TMP/bin/qemu-img"

    cat > "$TEST_TMP/bin/cp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'cp %s %s\n' "${1:-}" "${2:-}" >> "$TEST_TMP/calls.log"
touch "${2:-}"
SH
    chmod +x "$TEST_TMP/bin/cp"

    cat > "$TEST_TMP/bin/rm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'rm %s\n' "$*" >> "$TEST_TMP/calls.log"
PATH=/usr/bin:/bin exec /usr/bin/rm "$@"
SH
    chmod +x "$TEST_TMP/bin/rm"
}

@test "kvm vm_provision stops and undefines an existing domain before replacing overlay files" {
    run bash -c 'source "$REPO_ROOT/vm-setup/backend/kvm.sh"; vm_provision target 8192'

    [ "$status" -eq 0 ]
    calls="$(cat "$TEST_TMP/calls.log")"
    [[ "$calls" == *$'virsh dominfo winforge-target\nvirsh destroy winforge-target\nvirsh undefine winforge-target --nvram\nrm -f '* ]]
    [[ "$calls" == *$'rm -f '*$'\nqemu-img create '* ]]
}
