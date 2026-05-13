#!/bin/bash
#
# WinForge VM Post-Install Setup
#
# Run after Windows is installed and SSH is accessible.
# Installs: WinDbg/CDB, VS Build Tools, Python, disables firewall/defender/UAC,
# deploys SSH key, sets up CDB daemon.
#
# Usage:
#   ./setup-vm.sh --ip 192.168.122.100 --ssh-key ../vm-ssh-key
#   ./setup-vm.sh --ip 192.168.122.100 --password forge123
#   ./setup-vm.sh --ip 192.168.122.100 --user Administrator --password forge123F

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PHASE0_DIR="$(dirname "$SCRIPT_DIR")"

# Defaults
VM_IP="192.168.122.100"
VM_USER="forge"
VM_PASS="forge123"
SSH_KEY="${PHASE0_DIR}/vm-ssh-key"
USE_KEY=false

wait_for_ssh() {
  local label="${1:-SSH}"
  echo -n "[*] Waiting for ${label}..."
  for _ in $(seq 1 60); do
    if ssh_cmd "echo OK" 2>/dev/null | grep -q OK; then
      echo " connected!"
      return 0
    fi
    echo -n "."
    sleep 5
  done
  echo ""
  echo "[!] Timed out waiting for ${label}"
  return 1
}

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --ip) VM_IP="$2"; shift 2;;
    --user) VM_USER="$2"; shift 2;;
    --ssh-key) SSH_KEY="$2"; shift 2;;  # key path stored, but USE_KEY stays false until deployed
    --password) VM_PASS="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# SSH helper — uses key if available, password otherwise
ssh_cmd() {
  local cmd="$1"
  if [[ "$USE_KEY" == "true" && -f "$SSH_KEY" ]]; then
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=10 "${VM_USER}@${VM_IP}" "$cmd" 2>&1
  else
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=10 "${VM_USER}@${VM_IP}" "$cmd" 2>&1
  fi
}

scp_to() {
  local src="$1" dst="$2"
  if [[ "$USE_KEY" == "true" && -f "$SSH_KEY" ]]; then
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR "$src" "${VM_USER}@${VM_IP}:${dst}" 2>&1
  else
    sshpass -p "$VM_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR "$src" "${VM_USER}@${VM_IP}:${dst}" 2>&1
  fi
}

upload_and_run_ps1() {
  local script_content="$1"
  local script_name="${2:-_setup_step.ps1}"
  local tmp_script
  tmp_script="$(mktemp "/tmp/${script_name}.XXXXXX")"
  printf '%s\n' "$script_content" >"$tmp_script"
  scp_to "$tmp_script" "C:/winforge/$script_name"
  rm -f "$tmp_script"
  ssh_cmd "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\winforge\\$script_name"
}

phase_satisfied() {
  local _marker="$1" verify_ps="$2"
  local script_name="_verify_${_marker}.ps1"
  local tmp_script
  tmp_script="$(mktemp "/tmp/${script_name}.XXXXXX")"
  printf '%s\n' "$verify_ps" >"$tmp_script"
  if ! scp_to "$tmp_script" "C:/winforge/$script_name" >/dev/null; then
    rm -f "$tmp_script"
    return 1
  fi
  rm -f "$tmp_script"
  ssh_cmd "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\winforge\\$script_name" 2>/dev/null |
    tr -d '\r' |
    grep -q '^OK$'
}

mark_phase_done() {
  local marker="$1"
  ssh_cmd "powershell -NoProfile -Command \"\
New-Item -ItemType Directory -Path 'C:\\winforge\\state\\setup-vm' -Force | Out-Null; \
New-Item -ItemType File -Path 'C:\\winforge\\state\\setup-vm\\${marker}.done' -Force | Out-Null\"" >/dev/null
}

run_phase() {
  local marker="$1" label="$2" verify_ps="$3" script_content="$4" script_name="$5"
  if phase_satisfied "$marker" "$verify_ps"; then
    echo "[=] Skipping ${label} (already satisfied)"
    mark_phase_done "$marker"
    return 0
  fi
  echo "[*] ${label}"
  upload_and_run_ps1 "$script_content" "$script_name"
  if phase_satisfied "$marker" "$verify_ps"; then
    mark_phase_done "$marker"
  else
    echo "[-] ${label} did not satisfy verification after install" >&2
    return 1
  fi
}

write_tools_ready() {
  upload_and_run_ps1 '
$root = "C:\winforge"
New-Item -ItemType Directory -Path $root -Force | Out-Null
Get-ScheduledTask -TaskName "WinForgeBootstrap" -ErrorAction SilentlyContinue |
    Stop-ScheduledTask -ErrorAction SilentlyContinue
Get-ScheduledTask -TaskName "WinForgeBootstrap" -ErrorAction SilentlyContinue |
    Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
$ips = @(
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne "127.0.0.1" } |
        Select-Object -ExpandProperty IPAddress
)
$payload = [ordered]@{
    state = "tools_ready"
    phase = "verify"
    message = "WinForge tooling verified"
    timestamp = (Get-Date).ToString("o")
    hostname = $env:COMPUTERNAME
    ips = $ips
}
$payload | ConvertTo-Json -Depth 4 | Set-Content -Path "C:\winforge\ready.json" -Encoding ASCII
' "write_tools_ready.ps1" >/dev/null
}

echo "=== WinForge VM Setup ==="
echo "  IP: $VM_IP"
echo "  User: $VM_USER"
echo ""

# ── Wait for SSH ───────────────────────────────────────────────────

wait_for_ssh "SSH"

# ── Create working directories ─────────────────────────────────────

echo "[*] Creating directories..."
# Bootstrap C:\winforge first (needed before any upload_and_run_ps1 call)
ssh_cmd 'powershell -Command "New-Item -ItemType Directory -Path C:\winforge -Force | Out-Null"' >/dev/null
upload_and_run_ps1 '
foreach ($d in @("C:\winforge","C:\winforge\tools","C:\winforge\targets","C:\winforge\symbols","C:\winforge\patch-work")) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}
Write-Host "[+] Directories created"
' "create_dirs.ps1"

# ── Disable firewall, UAC, Defender ────────────────────────────────

echo "[*] Disabling firewall, UAC, Defender..."
upload_and_run_ps1 '
Set-NetFirewallProfile -All -Enabled False
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 0 /f | Out-Null
Set-MpPreference -DisableRealtimeMonitoring 1 -ErrorAction SilentlyContinue
Set-MpPreference -DisableBehaviorMonitoring 1 -ErrorAction SilentlyContinue
# Freeze the OS build. Without ALL of these, a background Windows Update will
# bump the target past its CVE-vulnerable baseline mid-run and destroy the
# research target — WaaSMedicSvc specifically re-enables wuauserv if only
# that one is disabled.
foreach ($svc in "wuauserv","UsoSvc","BITS") {
    Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service  -Name $svc -Force         -ErrorAction SilentlyContinue
}
# WaaSMedicSvc is ACL-protected against sc config; flip via registry.
reg add "HKLM\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc" /v Start /t REG_DWORD /d 4 /f | Out-Null
foreach ($p in "\Microsoft\Windows\UpdateOrchestrator\", "\Microsoft\Windows\WindowsUpdate\", "\Microsoft\Windows\WaaSMedic\") {
    Get-ScheduledTask -TaskPath $p -ErrorAction SilentlyContinue |
        Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
}
$auKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
New-Item -Path $auKey -Force | Out-Null
Set-ItemProperty -Path $auKey -Name NoAutoUpdate -Type DWord -Value 1 -Force
Set-ItemProperty -Path $auKey -Name AUOptions    -Type DWord -Value 2 -Force
Write-Host "[+] Security controls disabled"
' "disable_security.ps1"

# ── Deploy SSH key ─────────────────────────────────────────────────

if [[ -f "$SSH_KEY" ]]; then
  echo "[*] Deploying SSH key..."
  upload_and_run_ps1 '
$profileRoot = [Environment]::GetFolderPath("UserProfile")
New-Item -ItemType Directory -Path (Join-Path $profileRoot ".ssh") -Force | Out-Null
New-Item -ItemType Directory -Path C:\ProgramData\ssh -Force | Out-Null
Write-Host "[+] SSH dirs created"
if (([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    New-Item -ItemType File -Path C:\ProgramData\ssh\administrators_authorized_keys -Force | Out-Null
}
' "ssh_dirs.ps1"
  scp_to "${SSH_KEY}.pub" "C:/Users/$VM_USER/.ssh/authorized_keys"
  scp_to "${SSH_KEY}.pub" "C:/ProgramData/ssh/administrators_authorized_keys"
  ssh_cmd 'icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant Administrators:F /grant SYSTEM:F' >/dev/null
  USE_KEY=true
  echo "[+] SSH key deployed"
fi

# ── Set symbol path ────────────────────────────────────────────────

echo "[*] Setting symbol path..."
upload_and_run_ps1 '
[System.Environment]::SetEnvironmentVariable("_NT_SYMBOL_PATH", "srv*C:\winforge\symbols*https://msdl.microsoft.com/download/symbols", "Machine")
Write-Host "[+] _NT_SYMBOL_PATH set"
' "set_symbols.ps1"

# ── Install Chocolatey ─────────────────────────────────────────────

CHOCOLATEY_BOOTSTRAP_OUTPUT=""
if phase_satisfied "choco" 'if (Test-Path '\''C:\ProgramData\chocolatey\bin\choco.exe'\'') { Write-Output OK }'; then
  echo "[=] Skipping Chocolatey (already satisfied)"
  mark_phase_done "choco"
else
  echo "[*] Installing Chocolatey..."
  CHOCOLATEY_BOOTSTRAP_OUTPUT=$(upload_and_run_ps1 '
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
iex ((New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
Write-Host "[+] Chocolatey installed"
' "install_choco.ps1")
  printf '%s\n' "$CHOCOLATEY_BOOTSTRAP_OUTPUT"
  mark_phase_done "choco"
fi

if printf '%s\n' "$CHOCOLATEY_BOOTSTRAP_OUTPUT" | tr -d '\r' | grep -Eq 'reboot is required|need to restart this machine prior to using choco'; then
  CHOCO_REBOOT_REQUIRED=true
elif ssh_cmd 'powershell -NoProfile -Command "$choco = \"C:\\ProgramData\\chocolatey\\bin\\choco.exe\"; $rebootPending = (Test-Path \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired\") -or (Test-Path \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending\") -or ($null -ne (Get-ItemProperty -Path \"HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)); if ((Test-Path $choco) -and $rebootPending) { Write-Host REBOOT_REQUIRED }"' 2>/dev/null | tr -d '\r' | grep -q '^REBOOT_REQUIRED$'; then
  CHOCO_REBOOT_REQUIRED=true
else
  CHOCO_REBOOT_REQUIRED=false
fi

if [[ "$CHOCO_REBOOT_REQUIRED" == "true" ]]; then
  echo "[*] Reboot required after Chocolatey bootstrap; rebooting now..."
  ssh_cmd 'shutdown /r /t 5 /f' >/dev/null || true
  sleep 15
  wait_for_ssh "post-reboot SSH"
fi

# ── Install Python, 7zip, Git ─────────────────────────────────────

run_phase "python_git" "Installing Python, 7-Zip, Git" '$py = Get-Command python -EA SilentlyContinue; if (-not $py -and (Test-Path '\''C:\Python314\python.exe'\'')) { $py = Get-Item '\''C:\Python314\python.exe'\'' }; $git = Get-Command git -EA SilentlyContinue; if (-not $git -and (Test-Path '\''C:\Program Files\Git\cmd\git.exe'\'')) { $git = Get-Item '\''C:\Program Files\Git\cmd\git.exe'\'' }; if ($py -and $git) { Write-Output OK }' '
$choco = "C:\ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $choco)) {
    throw "Chocolatey executable not found at $choco"
}
& $choco install python3 -y --no-progress 2>&1 | Select-String "installed|already" | ForEach-Object { Write-Host $_ }
& $choco install 7zip -y --no-progress 2>&1 | Select-String "installed|already" | ForEach-Object { Write-Host $_ }
& $choco install git -y --no-progress 2>&1 | Select-String "installed|already" | ForEach-Object { Write-Host $_ }
$env:Path = "C:\Python314;C:\Program Files\Git\cmd;C:\ProgramData\chocolatey\bin;$env:Path"
$py = Get-Command python -EA SilentlyContinue
if (-not $py -and (Test-Path "C:\Python314\python.exe")) {
    $py = Get-Item "C:\Python314\python.exe"
}
$git = Get-Command git -EA SilentlyContinue
if (-not $git -and (Test-Path "C:\Program Files\Git\cmd\git.exe")) {
    $git = Get-Item "C:\Program Files\Git\cmd\git.exe"
}
if (-not $py -or -not $git) {
    throw "Python and Git must both be installed before setup can continue"
}
Write-Host "[+] Tools installed"
' "install_tools.ps1"

# ── Install Windows SDK Debugging Tools (cdb.exe) ──────────────────

run_phase "sdk_debuggers" "Installing Windows SDK Debugging Tools (WinDbg/CDB)" 'if (Get-ChildItem -Path '\''C:\Program Files*\Windows Kits\10\Debuggers\x64\cdb.exe'\'' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) { Write-Output OK }' '
$sdkUrl = "https://go.microsoft.com/fwlink/?linkid=2272610"
$sdkPath = "C:\winforge\tools\winsdksetup.exe"
Write-Host "[*] Downloading Windows SDK..."
Invoke-WebRequest -Uri $sdkUrl -OutFile $sdkPath -UseBasicParsing
Write-Host "[*] Installing Debugging Tools..."
Start-Process -FilePath $sdkPath -ArgumentList "/features","OptionId.WindowsDesktopDebuggers","/quiet","/norestart" -Wait -NoNewWindow
$cdb = Get-ChildItem -Path "C:\Program Files*\Windows Kits\10\Debuggers\x64\cdb.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cdb) {
    $dir = Split-Path $cdb.FullName
    [System.Environment]::SetEnvironmentVariable("Path", "$($env:Path);$dir", "Machine")
    Write-Host "[+] CDB installed: $($cdb.FullName)"
} else {
    Write-Host "[-] CDB not found after install"
}
' "install_sdk.ps1"

# ── Install VS Build Tools ────────────────────────────────────────

run_phase "vsbt" "Installing VS Build Tools 2022 (this takes a while)" 'if (Get-ChildItem -Path '\''C:\Program Files*\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe'\'' -EA SilentlyContinue | Select-Object -First 1) { Write-Output OK }' '
$url = "https://aka.ms/vs/17/release/vs_BuildTools.exe"
$path = "C:\winforge\tools\vs_BuildTools.exe"
Write-Host "[*] Downloading VS Build Tools..."
Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
Write-Host "[*] Installing C++ workload..."
Start-Process -FilePath $path -ArgumentList "--add","Microsoft.VisualStudio.Workload.VCTools","--add","Microsoft.VisualStudio.Component.VC.ATL","--includeRecommended","--quiet","--wait","--norestart" -Wait -NoNewWindow
$cl = Get-ChildItem -Path "C:\Program Files*\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe" -EA SilentlyContinue | Select-Object -First 1
if ($cl) { Write-Host "[+] cl.exe: $($cl.FullName)" }
else { Write-Host "[-] cl.exe not found" }
' "install_vsbt.ps1"

# ── NadavLor windbg-ext-mcp: extension DLL + Python MCP server ───
# This gets installed into the gold image so BOTH roles (target + debugger)
# have the bits. Only the debugger role actually runs the MCP server at boot;
# that's arranged by role-bootstrap-debugger.sh, not here.

run_phase "windbg_mcp" "Cloning + building NadavLor windbg-ext-mcp" '$dll = Get-ChildItem -Path '\''C:\winforge\windbg-ext-mcp'\'' -Recurse -Filter '\''windbgmcpExt.dll'\'' -EA SilentlyContinue | Select-Object -First 1; & '\''C:\Python314\python.exe'\'' -c '\''import fastmcp, win32pipe'\'' 2>$null; if ($dll -and $LASTEXITCODE -eq 0) { Write-Output OK }' '
$env:Path = "C:\Program Files\Git\cmd;C:\Python314;C:\Python314\Scripts;C:\ProgramData\chocolatey\bin;$env:Path"
$repo = "C:\winforge\windbg-ext-mcp"

if (-not (Test-Path $repo)) {
    git clone https://github.com/NadavLor/windbg-ext-mcp.git $repo *>$null
    if ($LASTEXITCODE -ne 0) { throw "git clone failed ($LASTEXITCODE)" }
}

# Build the extension DLL
$vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
$msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
if (-not (Test-Path $msbuild)) { throw "MSBuild not found (VS Build Tools C++/ATL required)" }

Set-Location $repo
& $msbuild extension\windbgmcpExt.sln /p:Configuration=Release /p:Platform=x64 /v:minimal /nologo 2>&1 | Select-Object -Last 5
if ($LASTEXITCODE -ne 0) { throw "MSBuild failed ($LASTEXITCODE)" }
$dll = Get-ChildItem -Path $repo -Recurse -Filter "windbgmcpExt.dll" -EA SilentlyContinue | Select-Object -First 1
if (-not $dll) { throw "DLL not produced" }
Write-Host ("[+] extension: {0} ({1} bytes)" -f $dll.FullName, $dll.Length)

# Install Python MCP server deps. Skip Poetry (credential-vault issues over
# SSH); install runtime deps directly with pip. The server runs via our
# run_http.py wrapper, not the Poetry entry point.
python -m pip install --quiet "fastmcp>=2.5.1,<3" "pywin32>=310" 2>&1 | Select-Object -Last 3
if ($LASTEXITCODE -ne 0) { throw "pip install failed ($LASTEXITCODE)" }
python -c "import fastmcp, win32pipe; print(fastmcp.__version__)"
' "install_windbg_mcp.ps1"

# Deploy the HTTP transport wrapper (bound to 0.0.0.0:8100/mcp)
echo "[*] Deploying windbg-mcp HTTP wrapper..."
if [[ -f "$SCRIPT_DIR/windbg_mcp_http.py" ]]; then
  scp_to "$SCRIPT_DIR/windbg_mcp_http.py" "C:/winforge/windbg-ext-mcp/run_http.py"
  echo "[+] run_http.py deployed"
else
  echo "[!] windbg_mcp_http.py missing at $SCRIPT_DIR"
fi

# ── Install mcp-windbg (user-mode debugger MCP on :8300) ──────────
# Vendored svnscha/mcp-windbg fork with our local-attach delta (see
# vm-setup/third-party/mcp-windbg/VENDORED.md). Installing here, in the
# gold image, so every lab spawn has the CLI on PATH; the scheduled
# task that actually starts the HTTP listener is registered per-spawn
# by role-bootstrap-target.sh (target role only).

echo "[*] Installing mcp-windbg (vendored fork)..."
MCP_WINDBG_SRC="$SCRIPT_DIR/third-party/mcp-windbg"
if phase_satisfied "mcp_windbg" '$cli = Get-Command mcp-windbg -EA SilentlyContinue; if (-not $cli -and (Test-Path '\''C:\Python314\Scripts\mcp-windbg.exe'\'')) { $cli = Get-Item '\''C:\Python314\Scripts\mcp-windbg.exe'\'' }; if ($cli) { Write-Output OK }'; then
  echo "[=] Skipping mcp-windbg (already satisfied)"
  mark_phase_done "mcp_windbg"
elif [[ -d "$MCP_WINDBG_SRC/src" ]]; then
  TARBALL="$(mktemp /tmp/mcp-windbg-XXXXXX.tar.gz)"
  tar -C "$MCP_WINDBG_SRC" -czf "$TARBALL" pyproject.toml src LICENSE README.md VENDORED.md
  scp_to "$TARBALL" "C:/winforge/mcp-windbg-src.tar.gz"
  rm -f "$TARBALL"
  upload_and_run_ps1 '
if (Test-Path C:\winforge\mcp-windbg-src) { Remove-Item -Recurse -Force C:\winforge\mcp-windbg-src }
New-Item -ItemType Directory -Path C:\winforge\mcp-windbg-src | Out-Null
tar -xzf C:\winforge\mcp-windbg-src.tar.gz -C C:\winforge\mcp-windbg-src
python -m pip install --quiet C:\winforge\mcp-windbg-src 2>&1 | Select-Object -Last 3
if ($LASTEXITCODE -ne 0) { throw "mcp-windbg pip install failed ($LASTEXITCODE)" }
$cli = Get-Command mcp-windbg -EA SilentlyContinue
if (-not $cli) {
    $fallback = "C:\Python314\Scripts\mcp-windbg.exe"
    if (Test-Path $fallback) { $cli = Get-Item $fallback }
}
if (-not $cli) { throw "mcp-windbg CLI missing after install" }
Write-Host ("[+] mcp-windbg installed at " + $cli.Source)
' "install_mcp_windbg.ps1"
  phase_satisfied "mcp_windbg" '$cli = Get-Command mcp-windbg -EA SilentlyContinue; if (-not $cli -and (Test-Path '\''C:\Python314\Scripts\mcp-windbg.exe'\'')) { $cli = Get-Item '\''C:\Python314\Scripts\mcp-windbg.exe'\'' }; if ($cli) { Write-Output OK }' \
    && mark_phase_done "mcp_windbg"
else
  echo "[!] Missing vendored mcp-windbg at $MCP_WINDBG_SRC — :8300 will not come up"
fi

# Deploy kd_wrapper.py — the Python process that starts kd.exe and keeps
# its stdin pipe open so kd never exits (run by DebuggerBoot scheduled task).
echo "[*] Deploying kd_wrapper.py..."
if [[ -f "$SCRIPT_DIR/kd_wrapper.py" ]]; then
  scp_to "$SCRIPT_DIR/kd_wrapper.py" "C:/winforge/kd_wrapper.py"
  echo "[+] kd_wrapper.py deployed"
else
  echo "[!] kd_wrapper.py missing at $SCRIPT_DIR (DebuggerBoot will fail)"
fi

# ── Install Node.js + DesktopCommanderMCP ────────────────────────
# DesktopCommanderMCP runs on the TARGET role as a local MCP server giving
# the AI process/file/search tools on the machine where PoCs execute.
# Installed in the gold so both roles have Node; only the target role starts
# the service (role-bootstrap-target.sh registers TargetDesktopBoot task).

run_phase "nodejs" "Installing Node.js LTS" '$node = Get-Command node -EA SilentlyContinue; if (-not $node -and (Test-Path '\''C:\Program Files\nodejs\node.exe'\'')) { $node = Get-Item '\''C:\Program Files\nodejs\node.exe'\'' }; if ($node) { Write-Output OK }' '
$choco = "C:\ProgramData\chocolatey\bin\choco.exe"
& $choco install nodejs-lts -y --no-progress 2>&1 | Select-String "installed|already" | ForEach-Object { Write-Host $_ }
$node = Get-Command node -EA SilentlyContinue
if (-not $node) { $env:Path = "C:\Program Files\nodejs;$env:Path" }
$node = Get-Command node -EA SilentlyContinue
if ($node) { Write-Host "[+] node: $((node --version 2>&1))" } else { Write-Host "[-] node not found" }
' "install_nodejs.ps1"

run_phase "desktop_commander" "Installing DesktopCommanderMCP" 'if (Test-Path '\''C:\winforge\node_modules\@wonderwhy-er\desktop-commander\dist\index.js'\'') { Write-Output OK }' '
$env:Path = "C:\Program Files\nodejs;C:\ProgramData\npm;$env:Path"
Set-Location C:\winforge
if (-not (Test-Path "C:\winforge\node_modules\@wonderwhy-er\desktop-commander")) {
    npm install @wonderwhy-er/desktop-commander --no-fund --no-audit 2>&1 | Select-Object -Last 5
} else {
    Write-Host "[+] DesktopCommanderMCP already installed"
}
$entry = "C:\winforge\node_modules\@wonderwhy-er\desktop-commander\dist\index.js"
if (Test-Path $entry) { Write-Host "[+] DesktopCommanderMCP: $entry" }
else { Write-Host "[-] DesktopCommanderMCP entry point not found" }
' "install_dcmcp.ps1"

echo "[*] Deploying target_mcp_http.py..."
if [[ -f "$SCRIPT_DIR/target_mcp_http.py" ]]; then
  scp_to "$SCRIPT_DIR/target_mcp_http.py" "C:/winforge/target_mcp_http.py"
  echo "[+] target_mcp_http.py deployed"
else
  echo "[!] target_mcp_http.py missing — TargetDesktopBoot will fail"
fi

# ── Verify installation ───────────────────────────────────────────

echo ""
echo "=== Verification ==="
upload_and_run_ps1 '
Write-Host "OS:      $(cmd /c ver 2>&1 | Select-String Version)"
$cdb = Get-Command cdb.exe -EA SilentlyContinue
if ($cdb) { Write-Host "CDB:     $($cdb.Source)" } else { Write-Host "CDB:     NOT FOUND" }
$cl = Get-ChildItem -Path "C:\Program Files*\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe" -EA SilentlyContinue | Select-Object -First 1
if ($cl) { Write-Host "cl.exe:  $($cl.FullName)" } else { Write-Host "cl.exe:  NOT FOUND" }
$env:Path = "C:\Python314;C:\Program Files\Git\cmd;C:\ProgramData\chocolatey\bin;$env:Path"
$py = Get-Command python -EA SilentlyContinue
if (-not $py -and (Test-Path "C:\Python314\python.exe")) {
    $py = Get-Item "C:\Python314\python.exe"
}
if ($py) { Write-Host "Python:  $($py.Source)" } else { Write-Host "Python:  NOT FOUND" }
$git = Get-Command git -EA SilentlyContinue
if (-not $git -and (Test-Path "C:\Program Files\Git\cmd\git.exe")) {
    $git = Get-Item "C:\Program Files\Git\cmd\git.exe"
}
if ($git) { Write-Host "Git:     $($git.Source)" } else { Write-Host "Git:     NOT FOUND" }
Write-Host "SSH:     $(Get-Service sshd | Select-Object -ExpandProperty Status)"
Write-Host "FW:      $(Get-NetFirewallProfile -Name Domain | Select-Object -ExpandProperty Enabled)"
$dll = Get-ChildItem -Path "C:\winforge\windbg-ext-mcp" -Recurse -Filter "windbgmcpExt.dll" -EA SilentlyContinue | Select-Object -First 1
if ($dll) { Write-Host ("MCP dll: {0}" -f $dll.FullName) } else { Write-Host "MCP dll: NOT FOUND" }
$http = Test-Path "C:\winforge\windbg-ext-mcp\run_http.py"
Write-Host ("MCP http wrapper: {0}" -f $(if ($http) { "present" } else { "NOT FOUND" }))
$env:Path = "C:\Program Files\nodejs;$env:Path"
$node = Get-Command node -EA SilentlyContinue
if ($node) { Write-Host ("Node:    {0} ({1})" -f $node.Source, (node --version 2>&1)) } else { Write-Host "Node:    NOT FOUND" }
$dcmcp = Test-Path "C:\winforge\node_modules\@wonderwhy-er\desktop-commander\dist\index.js"
Write-Host ("DCMCP:   {0}" -f $(if ($dcmcp) { "present" } else { "NOT FOUND" }))
$tmcp = Test-Path "C:\winforge\target_mcp_http.py"
Write-Host ("Target MCP relay: {0}" -f $(if ($tmcp) { "present" } else { "NOT FOUND" }))
if (-not $cdb -or -not $cl -or -not $py -or -not $git -or -not $dll -or -not $http -or -not $node -or -not $dcmcp -or -not $tmcp) {
    throw "Verification failed: required WinForge tools are missing"
}
' "verify.ps1"
write_tools_ready

echo ""
echo "=== Setup complete ==="
echo "  SSH:        ssh -i $SSH_KEY $VM_USER@$VM_IP"
echo "  WinDbg MCP: port 8100 (debugger role, after first crash)"
echo "  Target MCP: port 8200 (target role, after lab spawn)"
echo "  Debugger MCP: port 8201 (debugger role, after lab spawn)"
