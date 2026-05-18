#!/usr/bin/env bash
# Configure a freshly-spawned overlay as the kernel-debug TARGET.
#
# SSH into the VM, enable KDNET kernel debugging (bcdedit /dbgsettings net
# hostip:<debugger-ip> port:50000), enable testsigning, configure auto-reboot
# on BSOD, then reboot. After reboot the kernel sends KDNET UDP packets to
# the debugger VM where kd_wrapper.py is running kd.exe.
#
# Also registers TargetDesktopBoot: DesktopCommanderMCP proxied as HTTP on
# port 8200, giving the AI process/file/search tools on the target VM without
# SSH quoting gymnastics.
#
# Idempotent.
#
# Usage:
#   role-bootstrap-target.sh <vm-ip> <ssh-key> [<debugger-ip>]
#
# Prereqs:
#   - VM is up, SSH reachable, forge user has admin (UAC was disabled in gold).

set -Eeuo pipefail

VM_IP="${1:?usage: $0 <vm-ip> <ssh-key>}"
SSH_KEY="${2:?usage: $0 <vm-ip> <ssh-key>}"
VM_USER="${VM_USER:-forge}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ssh-helpers.sh
. "$SCRIPT_DIR/lib/ssh-helpers.sh"

ssh_cmd() {
    ssh -i "$SSH_KEY" "${SSH_OPTS_COMMON[@]}" \
        -o ServerAliveInterval=10 -o ServerAliveCountMax=6 \
        "$VM_USER@$VM_IP" "$@"
}

scp_to() {
    scp -i "$SSH_KEY" "${SSH_OPTS_COMMON[@]}" \
        -o ServerAliveInterval=10 -o ServerAliveCountMax=6 \
        "$1" "$VM_USER@$VM_IP:$2"
}

# shellcheck source=lib/guest.sh
. "$SCRIPT_DIR/lib/guest.sh"
guest_report_transport

# Wait for SSH to be both reachable AND stable.
#
# Used post-bcdedit-reboot when sshd briefly accepts a connection, then
# fails for tens of seconds (the same "half-up flap" the lab _lab_wait_ssh
# guards against). A single-OK probe used to slip through that window, the
# next scp/ssh then hung. Match the setup.sh _lab_wait_ssh pattern:
#   - bounded per-probe timeout (15 s) — wedged sshd worker becomes a
#     fast failure signal, not a deadlock,
#   - need 3 consecutive OK probes before declaring stable,
#   - 30 min wall budget covers the worst observed cold-boot.
wait_for_ssh() {
    local label="$1"
    local probe_timeout_s="${PROBE_TIMEOUT_S:-15}"
    local stable_ok_required="${WAIT_FOR_SSH_STABLE_OK:-3}"
    local max_wall_s="${WAIT_FOR_SSH_MAX_S:-1800}"
    local consecutive_ok=0 elapsed=0 ok_count=0 fail_count=0
    # `timeout` runs an executable, not a shell function — invoke ssh
    # directly so the timeout actually applies (using ssh_cmd here would
    # silently fail with rc=127 every iteration).
    while ((elapsed < max_wall_s)); do
        if timeout "$probe_timeout_s" \
            ssh -i "$SSH_KEY" "${SSH_OPTS_COMMON[@]}" \
            -o ServerAliveInterval=10 -o ServerAliveCountMax=6 \
            "$VM_USER@$VM_IP" 'echo ok' >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            consecutive_ok=$((consecutive_ok + 1))
            if ((consecutive_ok >= stable_ok_required)); then
                echo "[+] $label (${ok_count} OK / ${fail_count} fail over ${elapsed}s)"
                return 0
            fi
        else
            fail_count=$((fail_count + 1))
            consecutive_ok=0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    echo "[-] ${label}: ssh never stabilised in ${max_wall_s}s (${ok_count} OK / ${fail_count} fail)" >&2
    return 1
}

# Verify a scheduled task actually launched and entered Running state.
# `schtasks /Run` returns 0 the moment the task launcher fires — it doesn't
# tell us whether the action (python.exe, etc.) actually started. If the
# action immediately fails (missing interpreter, port conflict, etc.) the
# task drops back to "Ready" with a non-zero Last Result, and silence here
# leaves the lab looking healthy when it isn't.
# For long-running actions, Status=Running and Last Result=267009 (0x41301
# SCHED_S_TASK_RUNNING) is the healthy state.
verify_schtask_running() {
    local task="$1" max="${2:-10}" status
    for _ in $(seq 1 "$max"); do
        # `|| true` on the assignment: under set -euo pipefail an ssh failure
        # inside $(...) would otherwise kill the caller before this loop's
        # retry/timeout branch can run.
        status=$(ssh_cmd "schtasks /Query /TN \"$task\" /V /FO LIST" 2>/dev/null |
            tr -d '\r' | awk -F: '/^Status:/ {sub(/^[ \t]+/,"",$2); print $2; exit}') || true
        [[ "$status" == "Running" ]] && {
            echo "[+] $task is running"
            return 0
        }
        sleep 1
    done
    echo "[-] $task did not reach Status=Running within ${max}s (last='$status')" >&2
    ssh_cmd "schtasks /Query /TN \"$task\" /V /FO LIST" 2>/dev/null |
        tr -d '\r' | grep -iE "Status|Last Result|Last Run Time" >&2 || true
    return 1
}

# The debugger VM's IP — kd.exe runs there and target sends KDNET packets to it.
# Passed as third argument; defaults to DEBUGGER_IP env var or a hardcoded fallback.
KDNET_HOST="${3:-${DEBUGGER_IP:-192.168.122.101}}"
KDNET_PORT="${KDNET_PORT:-50000}"
KDNET_KEY="${KDNET_KEY:-1.2.3.4}"

echo "[*] Configuring KDNET on target $VM_IP (debugger=$KDNET_HOST:$KDNET_PORT key=$KDNET_KEY)"
guest_powershell "bcdedit /debug on; bcdedit /dbgsettings net hostip:$KDNET_HOST port:$KDNET_PORT key:$KDNET_KEY; bcdedit /set testsigning on"

# Auto-reboot on BSOD: the supervisor loop restarts kd.exe after each crash,
# and auto-reboot means the target recovers without manual virsh intervention.
echo "[*] Enabling auto-reboot on BSOD + kernel mini-dump"
guest_powershell 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v AutoReboot /t REG_DWORD /d 1 /f | Out-Null; reg add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v CrashDumpEnabled /t REG_DWORD /d 2 /f | Out-Null'

echo "[*] Rebooting target"
guest_powershell 'shutdown /r /t 3 /f' >/dev/null 2>&1 || true

sleep 10
wait_for_ssh "target back up after reboot"

# testsigning + KDNET activation can trigger a second reboot cycle.
# Wait for SSH to be stable (not just momentarily up) before proceeding.
echo "[*] Waiting for SSH to stabilise..."
sleep 20
wait_for_ssh "target SSH stable"

echo "[*] Verifying bcdedit state"
ssh_cmd 'cmd /c "bcdedit /dbgsettings"' | grep -E "debugtype|hostip|port|key" || true

# ── DesktopCommanderMCP service (HTTP on :8200) ──────────────────
# Gives the AI direct process/file/search access on the target without
# SSH quoting gymnastics. target_mcp_http.py bridges DesktopCommanderMCP
# stdio → FastMCP streamable-HTTP on 0.0.0.0:8200.

echo "[*] Deploying DesktopCommander HTTP relay"
scp_to "$SCRIPT_DIR/target_mcp_http.py" "C:/winforge/target_mcp_http.py"

echo "[*] Registering TargetDesktopBoot scheduled task"
guest_powershell 'schtasks /Create /TN TargetDesktopBoot /TR "C:\Python314\python.exe C:\winforge\target_mcp_http.py" /SC ONSTART /RU SYSTEM /RL HIGHEST /F' >/dev/null
echo "[+] TargetDesktopBoot registered"

echo "[*] Starting TargetDesktopBoot"
guest_powershell 'schtasks /Run /TN TargetDesktopBoot' >/dev/null
verify_schtask_running TargetDesktopBoot

# Wait for HTTP endpoint to be reachable
echo "[*] Waiting for DesktopCommander MCP on :8200..."
for _ in $(seq 1 20); do
    status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 \
        -X POST "http://$VM_IP:8200/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"setup","version":"1"}}}' \
        2>/dev/null) || true
    [[ "$status" == "200" ]] && break
    sleep 3
done

if [[ "$status" != "200" ]]; then
    echo "[!] DesktopCommander MCP did not come up — check C:\\winforge\\logs\\target-mcp.log"
    exit 1
else
    echo "[+] MCP up — configuring via API"

    # shellcheck source=lib/dc-helpers.sh
    . "$SCRIPT_DIR/lib/dc-helpers.sh"
    # DC_URL is consumed by dc_init / dc_set in dc-helpers.sh
    # shellcheck disable=SC2034
    DC_URL="http://$VM_IP:8200/mcp"
    dc_init

    # Clear default blocked commands (includes bcdedit, reg, shutdown, reboot — all needed)
    dc_set "blockedCommands" "[]"
    # Allow access to the full C: drive
    dc_set "allowedDirectories" "[\"C:\\\\\\\\\"]"
    # Disable telemetry
    dc_set "telemetryEnabled" "false"
    echo "[+] DesktopCommander configured (blockedCommands cleared, C:\\ allowed, telemetry off)"

    # Disable DC's "welcome onboarding" — emits a prompt-injection block
    # in tool results until silenced, and `set_config_value` refuses to
    # flip the key. Patch the on-disk JSON; DC re-reads on next call.
    scp_to "$SCRIPT_DIR/disable-dc-onboarding.ps1" "C:/winforge/disable-dc-onboarding.ps1"
    ssh_cmd 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\winforge\disable-dc-onboarding.ps1'
fi

# ── mcp-windbg HTTP (user-mode debugger MCP on :8300) ─────────────
# CDB-backed live user-mode debugger. The CLI is installed into the gold
# image by setup-vm.sh. If the gold predates that fix, fall back to a
# per-spawn install from the vendored source so `:8300` still comes up.

# Check for BOTH the CLI and the `prompts` submodule. A gold image built
# before the 2026-04-23 vendoring-completeness fix ships an mcp-windbg
# install whose `server.py` imports `from .prompts import load_prompt` —
# the submodule is absent from that vintage, so `mcp-windbg --help` crashes
# with `ModuleNotFoundError`. Detect that and re-install from the current
# vendored source, which now includes the stub module.
# Wrap in `powershell -NoProfile -Command` (same reason as the mcp-windbg
# stop on line ~166) and switch to exit-code signalling so we don't need any
# inner double quotes or variables — both of which the outer powershell-as-
# DefaultShell would otherwise mangle.
if ssh_cmd 'powershell -NoProfile -Command "if ((Get-Command mcp-windbg -EA SilentlyContinue) -and (Test-Path C:\Python314\Lib\site-packages\mcp_windbg\prompts\__init__.py)) { exit 0 } else { exit 1 }"' 2>/dev/null; then
    HAS_MCP_WINDBG=yes
else
    HAS_MCP_WINDBG=no
fi

if [[ "$HAS_MCP_WINDBG" != "yes" ]]; then
    echo "[!] mcp-windbg CLI not installed in gold — falling back to per-spawn install"
    MCP_WINDBG_SRC="$SCRIPT_DIR/third-party/mcp-windbg"
    if [[ -d "$MCP_WINDBG_SRC/src" ]]; then
        TARBALL="$(mktemp /tmp/mcp-windbg-XXXXXX.tar.gz)"
        tar -C "$MCP_WINDBG_SRC" -czf "$TARBALL" pyproject.toml src LICENSE README.md VENDORED.md
        scp_to "$TARBALL" "C:/winforge/mcp-windbg-src.tar.gz"
        rm -f "$TARBALL"
        # Stop any running mcp-windbg first — pip can't overwrite a locked .exe.
        # Wrap explicitly in `powershell -NoProfile -Command` so this line keeps
        # working if Windows OpenSSH DefaultShell ever changes off powershell.
        # Inner `2>$null` was dropped: with powershell as the outer shell it
        # would expand $null inside the `"..."` arg before the inner powershell
        # ran. The outer bash `>/dev/null 2>&1 || true` already suppresses output.
        ssh_cmd 'powershell -NoProfile -Command "schtasks /End /TN TargetMcpWindbgBoot ; Get-Process mcp-windbg -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue"' >/dev/null 2>&1 || true
        ssh_cmd 'powershell -NoProfile -Command "if (Test-Path C:\winforge\mcp-windbg-src) { Remove-Item -Recurse -Force C:\winforge\mcp-windbg-src } ; New-Item -ItemType Directory -Path C:\winforge\mcp-windbg-src | Out-Null ; tar -xzf C:\winforge\mcp-windbg-src.tar.gz -C C:\winforge\mcp-windbg-src ; python -m pip install --quiet --upgrade --force-reinstall --no-deps C:\winforge\mcp-windbg-src"' >/dev/null 2>&1
        echo "[+] mcp-windbg installed on target"
    else
        echo "[!] No vendored source at $MCP_WINDBG_SRC — :8300 cannot come up"
    fi
fi

echo "[*] Registering TargetMcpWindbgBoot scheduled task"
# schtasks /TR takes a single command-line string. The binary path has no
# spaces so we don't need inner \"...\" quoting (that escape confuses schtasks
# — see the TargetDesktopBoot task above for the canonical single-quoted form).
guest_powershell 'schtasks /Create /TN TargetMcpWindbgBoot /TR "C:\Python314\Scripts\mcp-windbg.exe --transport streamable-http --host 0.0.0.0 --port 8300" /SC ONSTART /RU SYSTEM /RL HIGHEST /F' >/dev/null
echo "[+] TargetMcpWindbgBoot registered"

echo "[*] Starting TargetMcpWindbgBoot"
guest_powershell 'schtasks /Run /TN TargetMcpWindbgBoot' >/dev/null
verify_schtask_running TargetMcpWindbgBoot

echo "[*] Waiting for mcp-windbg on :8300..."
for _ in $(seq 1 20); do
    # :8300 requires a session handshake; a bare GET returns 406 or similar.
    # ANY non-000 HTTP code means the listener is up.
    status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 \
        "http://$VM_IP:8300/mcp/" 2>/dev/null) || true
    [[ -n "$status" && "$status" != "000" ]] && break
    sleep 3
done
if [[ -z "$status" || "$status" == "000" ]]; then
    echo "[!] mcp-windbg did not come up on :8300 — check scheduled-task logs"
    exit 1
else
    echo "[+] mcp-windbg up on :8300 (HTTP $status on bare GET; handshake required for use)"
fi

echo "[+] Target configured for KDNET. kd.exe on $KDNET_HOST can connect at any time."
echo "    DesktopCommanderMCP HTTP: http://$VM_IP:8200/mcp (MCP tools for PoC execution)"
echo "    mcp-windbg HTTP:          http://$VM_IP:8300/mcp/ (live user-mode debug, note trailing slash)"
