$ErrorActionPreference = "Stop"

$Root = "C:\winforge"
$SourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BootstrapScript = Join-Path $Root "winforge-bootstrap.ps1"
$InstallerScript = Join-Path $Root "install-winforge-bootstrap.ps1"
$OpenSshZip = Join-Path $Root "OpenSSH-Win64.zip"
$OpenSshStage = Join-Path $Root "OpenSSH-Win64"
$OpenSshInstallRoot = "C:\Program Files\OpenSSH"
$OpenSshInstallScript = Join-Path $OpenSshInstallRoot "install-sshd.ps1"
$TaskName = "WinForgeBootstrap"
$TaskDescription = "WinForge guest bootstrap"
$BootstrapArgs = "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$BootstrapScript`""

New-Item -ItemType Directory -Path $Root -Force | Out-Null
Copy-Item -Path (Join-Path $SourceRoot "winforge-bootstrap.ps1") -Destination $BootstrapScript -Force
Copy-Item -Path $MyInvocation.MyCommand.Path -Destination $InstallerScript -Force
Copy-Item -Path (Join-Path $SourceRoot "OpenSSH-Win64.zip") -Destination $OpenSshZip -Force

if (-not (Test-Path (Join-Path $OpenSshInstallRoot "sshd.exe"))) {
    Remove-Item -Path $OpenSshStage -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $OpenSshZip -DestinationPath $Root -Force
    New-Item -ItemType Directory -Path $OpenSshInstallRoot -Force | Out-Null
    Copy-Item -Path (Join-Path $OpenSshStage "*") -Destination $OpenSshInstallRoot -Recurse -Force
    # `&` invocation does NOT trigger $ErrorActionPreference=Stop on a non-zero
    # exit code, so check $LASTEXITCODE explicitly. Without this, an install-sshd
    # failure (perms, port collision, etc.) silently flows through to
    # Register-ScheduledTask and the gold image seals with broken SSH — surface
    # is delayed until seal-vm-gold.sh's wait_for_ssh times out much later.
    $sshLog = Join-Path $Root "install-sshd.log"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $OpenSshInstallScript *>&1 |
        Tee-Object -FilePath $sshLog
    if ($LASTEXITCODE -ne 0) {
        throw "install-sshd.ps1 failed with exit $LASTEXITCODE (see $sshLog)"
    }
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $BootstrapArgs
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
$triggers = @(
    (New-ScheduledTaskTrigger -AtStartup)
    (New-ScheduledTaskTrigger -AtLogOn)
)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description $TaskDescription -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
