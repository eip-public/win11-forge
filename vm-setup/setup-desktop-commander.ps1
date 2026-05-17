Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pre-seed DesktopCommanderMCP defaultShell before first startup.
# DesktopCommander generates its full config on first run -- we only set defaultShell
# here so it uses powershell.exe from the start. All other settings (blockedCommands,
# allowedDirectories, telemetryEnabled) are set via the MCP set_config_value API
# after the server is up (role-bootstrap-target.sh does this from the Linux host).
#
# Runs in the forge user context (SSH), so writes to forge's USERPROFILE.
# The SYSTEM scheduled task gets its own config auto-generated on first run.

foreach ($base in @("C:\Windows\System32\config\systemprofile", $env:USERPROFILE)) {
    $dir  = Join-Path $base ".claude-server-commander"
    $file = Join-Path $dir "config.json"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if (-not (Test-Path $file)) {
        # Only write if config doesn't exist yet -- don't overwrite a running server's state
        '{"defaultShell":"powershell.exe"}' | Set-Content -Path $file -Encoding UTF8
        Write-Host "[+] Pre-seeded defaultShell in $dir"
    } else {
        Write-Host "[~] Config already exists at $dir (server may be running, skipping)"
    }
}
