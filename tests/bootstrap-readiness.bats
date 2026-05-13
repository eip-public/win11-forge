#!/usr/bin/env bats

setup() {
    export REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export TEST_TMP="$BATS_TEST_TMPDIR"
    export PATH="$TEST_TMP/bin:$PATH"
    mkdir -p "$TEST_TMP/bin"
    : > "$TEST_TMP/calls.log"
    : > "$TEST_TMP/key"

    cat > "$TEST_TMP/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "$TEST_TMP/calls.log"
case "$*" in
    *Get-Command*mcp-windbg*) printf 'yes\r\n' ;;
    *bcdedit*) printf 'debugtype NET\nhostip 192.168.122.101\nport 50000\nkey 1.2.3.4\n' ;;
esac
exit 0
SH
    chmod +x "$TEST_TMP/bin/ssh"

    cat > "$TEST_TMP/bin/scp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'scp %s\n' "$*" >> "$TEST_TMP/calls.log"
exit 0
SH
    chmod +x "$TEST_TMP/bin/scp"

    cat > "$TEST_TMP/bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$TEST_TMP/bin/sleep"

    cat > "$TEST_TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "$TEST_TMP/calls.log"
case "$*" in
    *"-w %{http_code}"*) printf '000' ;;
esac
exit 0
SH
    chmod +x "$TEST_TMP/bin/curl"
}

@test "target bootstrap fails when DesktopCommander MCP does not come up" {
    run env VM_USER=forge "$REPO_ROOT/vm-setup/role-bootstrap-target.sh" 192.168.122.100 "$TEST_TMP/key" 192.168.122.101

    [ "$status" -ne 0 ]
    [[ "$output" == *"DesktopCommander MCP did not come up"* ]]
}

@test "debugger bootstrap fails when DesktopCommander MCP does not come up" {
    run env VM_USER=forge "$REPO_ROOT/vm-setup/role-bootstrap-debugger.sh" 192.168.122.101 "$TEST_TMP/key"

    [ "$status" -ne 0 ]
    [[ "$output" == *"DesktopCommander MCP did not come up on :8201"* ]]
}
