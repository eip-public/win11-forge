#!/usr/bin/env bash
# Configure a freshly-spawned overlay as the kernel-debug DEBUGGER.
#
# Uploads kd_wrapper.py to the VM, registers it as the DebuggerBoot
# scheduled task (SYSTEM, runs at boot), and starts it immediately.
#
# kd_wrapper.py handles the full debug stack:
#   kd.exe (KDNET transport) → windbgmcpExt.dll → \\pipe\windbgmcp → HTTP :8100
#
# Also registers DebuggerDesktopBoot: DesktopCommanderMCP on port 8201,
# giving the AI process/file/search tools on the debugger VM itself —
# read kd logs, check process state, edit kd_wrapper.py, etc.
#
# Usage:
#   role-bootstrap-debugger.sh <vm-ip> <ssh-key>

set -Eeuo pipefail

VM_IP="${1:?usage: $0 <vm-ip> <ssh-key>}"
SSH_KEY="${2:?usage: $0 <vm-ip> <ssh-key>}"
VM_USER="${VM_USER:-forge}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ServerAliveInterval prevents the SSH session hanging if the remote
# stops responding (e.g. during WinDbg operations or Windows reboots).
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

retry_ssh_cmd() {
    local attempt
    for attempt in $(seq 1 12); do
        ssh_cmd "$@" && return 0
        sleep 5
    done
    return 1
}

retry_scp_to() {
    local src="$1" dst="$2" attempt
    for attempt in $(seq 1 12); do
        scp_to "$src" "$dst" && return 0
        sleep 5
    done
    return 1
}

# Wait for SSH to be both reachable AND stable. See the matching helper
# in role-bootstrap-target.sh for the rationale: a single-OK probe slips
# through the post-reboot half-up flap, the next scp/ssh then hangs.
#   - bounded per-probe timeout (15 s),
#   - need 3 consecutive OK probes before declaring stable,
#   - 30 min wall budget covers cold-boot worst case.
wait_for_ssh() {
    local label="${1:-SSH}"
    local probe_timeout_s="${PROBE_TIMEOUT_S:-15}"
    local stable_ok_required="${WAIT_FOR_SSH_STABLE_OK:-3}"
    local max_wall_s="${WAIT_FOR_SSH_MAX_S:-1800}"
    local consecutive_ok=0 elapsed=0 ok_count=0 fail_count=0
    while (( elapsed < max_wall_s )); do
        if timeout "$probe_timeout_s" ssh_cmd 'echo ok' >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            consecutive_ok=$((consecutive_ok + 1))
            if (( consecutive_ok >= stable_ok_required )); then
                echo "[+] $label ready (${ok_count} OK / ${fail_count} fail over ${elapsed}s)"
                return 0
            fi
        else
            fail_count=$((fail_count + 1))
            consecutive_ok=0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    echo "[-] $label timed out (ssh never stabilised in ${max_wall_s}s, ${ok_count} OK / ${fail_count} fail)" >&2
    return 1
}

# Verify a scheduled task actually launched and entered Running state.
# `schtasks /Run` returns 0 the moment the task launcher fires — it doesn't
# tell us whether the action (python.exe, etc.) actually started. DebuggerBoot
# has no downstream HTTP probe (the wrapper waits for kernel break before
# starting HTTP), so if kd_wrapper.py python-crashes at launch this was the
# only signal we had — and we weren't checking it.
# For long-running actions, Status=Running and Last Result=267009 (0x41301
# SCHED_S_TASK_RUNNING) is the healthy state.
verify_schtask_running() {
    local task="$1" max="${2:-10}" i status
    for i in $(seq 1 "$max"); do
        # `|| true` on the assignment: under set -euo pipefail an ssh failure
        # inside $(...) would otherwise kill the caller before this loop's
        # retry/timeout branch can run.
        status=$(ssh_cmd "schtasks /Query /TN \"$task\" /V /FO LIST" 2>/dev/null \
            | tr -d '\r' | awk -F: '/^Status:/ {sub(/^[ \t]+/,"",$2); print $2; exit}') || true
        [[ "$status" == "Running" ]] && { echo "[+] $task is running"; return 0; }
        sleep 1
    done
    echo "[-] $task did not reach Status=Running within ${max}s (last='$status')" >&2
    ssh_cmd "schtasks /Query /TN \"$task\" /V /FO LIST" 2>/dev/null \
        | tr -d '\r' | grep -iE "Status|Last Result|Last Run Time" >&2 || true
    return 1
}

# shellcheck source=lib/log.sh
. "$SCRIPT_DIR/lib/log.sh"

# With DHCP gold + MAC-based libvirt reservation, debugger arrives at $VM_IP
# directly — no IP reassignment needed.
echo "[*] Debugger IP: $VM_IP (DHCP MAC reservation)"

# ── Upload kd_wrapper.py + run_http.py ─────────────────────────────────
echo "[*] Uploading kd_wrapper.py"
if [[ -f "$SCRIPT_DIR/kd_wrapper.py" ]]; then
    retry_scp_to "$SCRIPT_DIR/kd_wrapper.py" "C:/winforge/kd_wrapper.py"
    ok "kd_wrapper.py deployed to C:\\winforge\\kd_wrapper.py"
else
    warn "kd_wrapper.py not found in $SCRIPT_DIR — DebuggerBoot will fail"
fi

echo "[*] Uploading run_http.py (HTTP transport for MCP)"
if [[ -f "$SCRIPT_DIR/windbg_mcp_http.py" ]]; then
    retry_scp_to "$SCRIPT_DIR/windbg_mcp_http.py" "C:/winforge/windbg-ext-mcp/run_http.py"
    ok "run_http.py deployed to C:\\winforge\\windbg-ext-mcp\\run_http.py"
else
    warn "windbg_mcp_http.py not found in $SCRIPT_DIR — HTTP server will use gold version"
fi

# ── Register + start DebuggerBoot scheduled task ────────────────────────
echo "[*] Registering DebuggerBoot scheduled task"
retry_ssh_cmd 'schtasks /Create /TN DebuggerBoot /TR "C:\\Python314\\python.exe C:\\winforge\\kd_wrapper.py" /SC ONSTART /RU SYSTEM /RL HIGHEST /F' >/dev/null
ok "DebuggerBoot task registered"

echo "[*] Starting DebuggerBoot now"
retry_ssh_cmd 'schtasks /Run /TN DebuggerBoot' >/dev/null
verify_schtask_running DebuggerBoot

# Give the wrapper time to start kd.exe and attempt the KDNET connection.
# The full connection + pipe + HTTP takes up to 5 min after the target boots;
# here we just confirm the wrapper and kd.exe are running.
sleep 8
wait_for_ssh "debugger SSH after DebuggerBoot start"
echo "[*] Probing initial state (tasklist avoids PowerShell/cmd.exe quoting issues)"
# tasklist is a plain cmd.exe command — no PowerShell quoting layers to worry about.
retry_ssh_cmd 'tasklist /FI "IMAGENAME eq kd.exe" /NH /FO CSV' 2>/dev/null || true
retry_ssh_cmd 'tasklist /FI "IMAGENAME eq python.exe" /NH /FO CSV' 2>/dev/null || true

# ── DesktopCommanderMCP on debugger (port 8201) ────────────────────
# Gives the AI file/process tools on the debugger VM itself — read kd logs,
# check kd.exe state, edit kd_wrapper.py mid-session, etc.
# Uses the same target_mcp_http.py relay (port arg controls port).

echo "[*] Uploading target_mcp_http.py for debugger use"
if [[ -f "$SCRIPT_DIR/target_mcp_http.py" ]]; then
    retry_scp_to "$SCRIPT_DIR/target_mcp_http.py" "C:/winforge/target_mcp_http.py"
    ok "target_mcp_http.py deployed"
else
    warn "target_mcp_http.py not found — DebuggerDesktopBoot will fail"
fi

echo "[*] Registering DebuggerDesktopBoot scheduled task (port 8201)"
retry_ssh_cmd 'schtasks /Create /TN DebuggerDesktopBoot /TR "C:\\Python314\\python.exe C:\\winforge\\target_mcp_http.py --port 8201" /SC ONSTART /RU SYSTEM /RL HIGHEST /F' >/dev/null
ok "DebuggerDesktopBoot task registered"

echo "[*] Starting DebuggerDesktopBoot now"
retry_ssh_cmd 'schtasks /Run /TN DebuggerDesktopBoot' >/dev/null
verify_schtask_running DebuggerDesktopBoot

# Wait for HTTP up then configure via API
echo "[*] Waiting for DesktopCommander MCP on :8201..."
status=""
for i in $(seq 1 20); do
    status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 \
        -X POST "http://$VM_IP:8201/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"setup","version":"1"}}}' \
        2>/dev/null) || true
    [[ "$status" == "200" ]] && break
    sleep 3
done

if [[ "$status" == "200" ]]; then
    # shellcheck source=lib/dc-helpers.sh
    . "$SCRIPT_DIR/lib/dc-helpers.sh"
    DC_URL="http://$VM_IP:8201/mcp"
    dc_init
    dc_set "blockedCommands"    "[]"
    dc_set "allowedDirectories" "[\"C:\\\\\\\\\"]"
    dc_set "telemetryEnabled"   "false"
    ok "DesktopCommander configured on debugger (port 8201)"
else
    warn "DesktopCommander MCP did not come up on :8201 — check C:\\winforge\\logs\\target-mcp.log"
    exit 1
fi

echo ""
ok "Debugger bootstrap complete."
echo "    kd_wrapper.py running as SYSTEM — it will connect to the target kernel"
echo "    automatically when the target reboots (KDNET transport, port 50000)."
echo "    WinDbg MCP:       http://$VM_IP:8100/mcp  (up once kd connects + extension loads)"
echo "    DesktopCmd MCP:   http://$VM_IP:8201/mcp  (up now — file/process tools)"
