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

set -euo pipefail

VM_IP="${1:?usage: $0 <vm-ip> <ssh-key>}"
SSH_KEY="${2:?usage: $0 <vm-ip> <ssh-key>}"
VM_USER="${VM_USER:-forge}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssh_cmd() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=6 \
        -o LogLevel=ERROR "$VM_USER@$VM_IP" "$@"
}

scp_to() {
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=10 -o ServerAliveCountMax=6 \
        -o LogLevel=ERROR "$1" "$VM_USER@$VM_IP:$2"
}

wait_for_ssh() {
    local label="$1" i
    for i in $(seq 1 60); do
        ssh_cmd 'echo ok' >/dev/null 2>&1 && { echo "[+] $label"; return 0; }
        sleep 5
    done
    echo "[-] ${label}: ssh never came back" >&2
    return 1
}

# The debugger VM's IP — kd.exe runs there and target sends KDNET packets to it.
# Passed as third argument; defaults to DEBUGGER_IP env var or a hardcoded fallback.
KDNET_HOST="${3:-${DEBUGGER_IP:-192.168.122.101}}"
KDNET_PORT="${KDNET_PORT:-50000}"
KDNET_KEY="${KDNET_KEY:-1.2.3.4}"

echo "[*] Configuring KDNET on target $VM_IP (debugger=$KDNET_HOST:$KDNET_PORT key=$KDNET_KEY)"
ssh_cmd "cmd /c \"bcdedit /debug on && bcdedit /dbgsettings net hostip:$KDNET_HOST port:$KDNET_PORT key:$KDNET_KEY && bcdedit /set testsigning on\""

# Auto-reboot on BSOD: the supervisor loop restarts kd.exe after each crash,
# and auto-reboot means the target recovers without manual virsh intervention.
echo "[*] Enabling auto-reboot on BSOD + kernel mini-dump"
ssh_cmd 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v AutoReboot /t REG_DWORD /d 1 /f' >/dev/null
ssh_cmd 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v CrashDumpEnabled /t REG_DWORD /d 2 /f' >/dev/null

echo "[*] Rebooting target"
ssh_cmd 'shutdown /r /t 3 /f' >/dev/null 2>&1 || true

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
ssh_cmd 'schtasks /Create /TN TargetDesktopBoot /TR "C:\\Python314\\python.exe C:\\winforge\\target_mcp_http.py" /SC ONSTART /RU SYSTEM /RL HIGHEST /F' >/dev/null
echo "[+] TargetDesktopBoot registered"

echo "[*] Starting TargetDesktopBoot"
ssh_cmd 'schtasks /Run /TN TargetDesktopBoot' >/dev/null

# Wait for HTTP endpoint to be reachable
echo "[*] Waiting for DesktopCommander MCP on :8200..."
for i in $(seq 1 20); do
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

    # Get session ID
    SESSION=$(curl -si -X POST "http://$VM_IP:8200/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"setup","version":"1"}}}' \
        2>/dev/null | grep mcp-session-id | awk '{print $2}' | tr -d '\r')

    dc_set() {
        curl -s -X POST "http://$VM_IP:8200/mcp" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json, text/event-stream" \
            -H "mcp-session-id: $SESSION" \
            -d "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"id\":2,\"params\":{\"name\":\"set_config_value\",\"arguments\":{\"key\":\"$1\",\"value\":$2}}}" \
            >/dev/null 2>&1
    }

    # Clear default blocked commands (includes bcdedit, reg, shutdown, reboot — all needed)
    dc_set "blockedCommands"    "[]"
    # Allow access to the full C: drive
    dc_set "allowedDirectories" "[\"C:\\\\\\\\\"]"
    # Disable telemetry
    dc_set "telemetryEnabled"   "false"
    echo "[+] DesktopCommander configured (blockedCommands cleared, C:\\ allowed, telemetry off)"
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
HAS_MCP_WINDBG=$(ssh_cmd 'if ((Get-Command mcp-windbg -EA SilentlyContinue) -and (Test-Path "C:\Python314\Lib\site-packages\mcp_windbg\prompts\__init__.py")) { "yes" } else { "no" }' 2>/dev/null | tr -d '\r' | tail -1)

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
ssh_cmd 'schtasks /Create /TN TargetMcpWindbgBoot /TR "C:\\Python314\\Scripts\\mcp-windbg.exe --transport streamable-http --host 0.0.0.0 --port 8300" /SC ONSTART /RU SYSTEM /RL HIGHEST /F' >/dev/null
echo "[+] TargetMcpWindbgBoot registered"

echo "[*] Starting TargetMcpWindbgBoot"
ssh_cmd 'schtasks /Run /TN TargetMcpWindbgBoot' >/dev/null

echo "[*] Waiting for mcp-windbg on :8300..."
for i in $(seq 1 20); do
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
