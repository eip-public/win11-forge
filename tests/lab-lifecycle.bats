#!/usr/bin/env bats

setup() {
    export REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export TEST_TMP="$BATS_TEST_TMPDIR"
    export PATH="$TEST_TMP/bin:$PATH"
    mkdir -p "$TEST_TMP/bin"
    printf 'stopped\n' > "$TEST_TMP/target.state"
    printf 'stopped\n' > "$TEST_TMP/debugger.state"
    : > "$TEST_TMP/calls.log"

    cat > "$TEST_TMP/bin/virsh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state_file() {
    case "$1" in
        winforge-target) echo "$TEST_TMP/target.state" ;;
        winforge-debugger) echo "$TEST_TMP/debugger.state" ;;
        *) echo "$TEST_TMP/unknown.state" ;;
    esac
}
case "${1:-}" in
    list)
        if [[ "${*:-}" == *"--all"* && "${VIRSH_SCENARIO:-}" == "single_vm_collision" ]]; then
            printf 'winforge-win11-24h2\n'
        fi
        exit 0
        ;;
    dumpxml)
        if [[ "${2:-}" == "winforge-win11-24h2" && "${VIRSH_SCENARIO:-}" == "single_vm_collision" ]]; then
            printf "<domain><devices><interface><mac address='52:54:00:11:11:11'/></interface></devices></domain>\n"
            exit 0
        fi
        exit 1
        ;;
    net-info)
        printf 'Name: default\nActive: yes\n'
        ;;
    net-dumpxml)
        printf "<network><ip><dhcp><host mac='52:54:00:11:11:11' ip='192.168.122.100'/><host mac='52:54:00:22:22:22' ip='192.168.122.101'/></dhcp></ip></network>\n"
        ;;
    net-update)
        printf 'virsh net-update\n' >> "$TEST_TMP/calls.log"
        ;;
    dominfo)
        case "${2:-}" in
            winforge-target|winforge-debugger|winforge-win11-24h2) exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    domstate)
        if [[ "${2:-}" == "winforge-win11-24h2" && "${VIRSH_SCENARIO:-}" == "single_vm_collision" ]]; then
            printf 'running\n'
            exit 0
        fi
        state="$(cat "$(state_file "${2:-}")" 2>/dev/null || printf undefined)"
        case "$state" in
            running) printf 'running\n' ;;
            stopped) printf 'shut off\n' ;;
            *) printf '%s\n' "$state"; exit 1 ;;
        esac
        ;;
    start)
        printf 'virsh start %s\n' "${2:-}" >> "$TEST_TMP/calls.log"
        printf 'running\n' > "$(state_file "${2:-}")"
        ;;
    shutdown)
        printf 'virsh shutdown %s\n' "${2:-}" >> "$TEST_TMP/calls.log"
        printf 'stopped\n' > "$(state_file "${2:-}")"
        ;;
    destroy)
        printf 'virsh destroy %s\n' "${2:-}" >> "$TEST_TMP/calls.log"
        printf 'stopped\n' > "$(state_file "${2:-}")"
        ;;
    *)
        printf 'unexpected virsh command: %s\n' "$*" >&2
        exit 2
        ;;
esac
SH
    chmod +x "$TEST_TMP/bin/virsh"

    cat > "$TEST_TMP/bin/sshpass" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
case "$args" in
    *192.168.122.100*shutdown*)
        printf 'guest shutdown winforge-target\n' >> "$TEST_TMP/calls.log"
        printf 'stopped\n' > "$TEST_TMP/target.state"
        ;;
    *192.168.122.101*shutdown*)
        printf 'guest shutdown winforge-debugger\n' >> "$TEST_TMP/calls.log"
        printf 'stopped\n' > "$TEST_TMP/debugger.state"
        ;;
esac
exit 0
SH
    chmod +x "$TEST_TMP/bin/sshpass"

    cat > "$TEST_TMP/bin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
    chmod +x "$TEST_TMP/bin/timeout"
}

@test "lab start starts existing debugger before target without provisioning" {
    run env WINFORGE_BACKEND=kvm "$REPO_ROOT/setup.sh" lab start

    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_TMP/calls.log")" = $'virsh start winforge-debugger\nvirsh start winforge-target' ]
}

@test "lab stop asks Windows guests to shut down target before debugger" {
    printf 'running\n' > "$TEST_TMP/target.state"
    printf 'running\n' > "$TEST_TMP/debugger.state"

    run env WINFORGE_BACKEND=kvm LAB_STOP_GRACE=5 "$REPO_ROOT/setup.sh" lab stop

    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_TMP/calls.log")" = $'guest shutdown winforge-target\nguest shutdown winforge-debugger' ]
}

@test "lab spawn refuses when the single VM is running on the lab target MAC" {
    run env WINFORGE_BACKEND=kvm VIRSH_SCENARIO=single_vm_collision "$REPO_ROOT/setup.sh" lab spawn

    [ "$status" -ne 0 ]
    [[ "$output" == *"Running domain(s) hold 52:54:00:11:11:11"* ]]
    [[ "$(cat "$TEST_TMP/calls.log")" != *"virsh start"* ]]
}
