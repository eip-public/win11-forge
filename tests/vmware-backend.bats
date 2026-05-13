#!/usr/bin/env bats

setup() {
    export REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export TEST_TMP="$BATS_TEST_TMPDIR"
    export PATH="$TEST_TMP/bin:$PATH"
    export IMAGES_DIR="$TEST_TMP/images"
    export VM_NAME="winforge-win11-24h2"
    export VM_SETUP="$REPO_ROOT/vm-setup"
    mkdir -p "$TEST_TMP/bin" "$IMAGES_DIR"
    : > "$TEST_TMP/calls.log"

    cat > "$TEST_TMP/bin/vmrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'vmrun %s\n' "$*" >> "$TEST_TMP/calls.log"
SH
    chmod +x "$TEST_TMP/bin/vmrun"

    cat > "$TEST_TMP/bin/pgrep" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'pgrep %s\n' "$*" >> "$TEST_TMP/calls.log"
[[ "${VMWARE_GUI_RUNNING:-0}" == "1" ]]
SH
    chmod +x "$TEST_TMP/bin/pgrep"

    cat > "$TEST_TMP/bin/gtk-launch" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'gtk-launch %s\n' "$*" >> "$TEST_TMP/calls.log"
[[ "${GTK_LAUNCH_SUCCEEDS:-0}" == "1" ]] || exit 1
SH
    chmod +x "$TEST_TMP/bin/gtk-launch"

    cat > "$TEST_TMP/bin/sleep" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'sleep %s\n' "$*" >> "$TEST_TMP/calls.log"
SH
    chmod +x "$TEST_TMP/bin/sleep"
}

@test "vmware gui start tries gtk-launch then fails before vmrun when Workstation GUI does not appear" {
    run bash -c 'source "$REPO_ROOT/vm-setup/backend/vmware.sh"; vm_start target gui'

    [ "$status" -eq 1 ]
    [[ "$output" == *"VMware Workstation GUI is not running"* ]]
    calls="$(cat "$TEST_TMP/calls.log")"
    [[ "$calls" == pgrep* ]]
    [[ "$calls" == *"gtk-launch vmware-workstation"* ]]
    [[ "$calls" != *"vmrun"* ]]
}

@test "vmware gui start launches Workstation with gtk-launch before vmrun" {
    export GTK_LAUNCH_SUCCEEDS=1

    cat > "$TEST_TMP/bin/pgrep" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'pgrep %s\n' "$*" >> "$TEST_TMP/calls.log"
count_file="$TEST_TMP/pgrep-count"
count="$(cat "$count_file" 2>/dev/null || printf 0)"
count=$((count + 1))
printf '%s' "$count" > "$count_file"
(( count >= 2 ))
SH
    chmod +x "$TEST_TMP/bin/pgrep"

    run bash -c 'source "$REPO_ROOT/vm-setup/backend/vmware.sh"; vm_start target gui'

    [ "$status" -eq 0 ]
    calls="$(cat "$TEST_TMP/calls.log")"
    [[ "$calls" == *"gtk-launch vmware-workstation"* ]]
    [[ "$calls" == *"vmrun -T ws start $IMAGES_DIR/vmware/winforge-target/winforge-target.vmx gui"* ]]
}

@test "vmware gui start uses vmrun when Workstation GUI is already running" {
    export VMWARE_GUI_RUNNING=1

    run bash -c 'source "$REPO_ROOT/vm-setup/backend/vmware.sh"; vm_start target gui'

    [ "$status" -eq 0 ]
    calls="$(cat "$TEST_TMP/calls.log")"
    [[ "$calls" == *"pgrep -u"* ]]
    [[ "$calls" == *"vmrun -T ws start $IMAGES_DIR/vmware/winforge-target/winforge-target.vmx gui"* ]]
}

@test "vmware nogui start does not require Workstation GUI" {
    run bash -c 'source "$REPO_ROOT/vm-setup/backend/vmware.sh"; vm_start target nogui'

    [ "$status" -eq 0 ]
    calls="$(cat "$TEST_TMP/calls.log")"
    [[ "$calls" != *"pgrep"* ]]
    [[ "$calls" == *"vmrun -T ws start $IMAGES_DIR/vmware/winforge-target/winforge-target.vmx nogui"* ]]
}
