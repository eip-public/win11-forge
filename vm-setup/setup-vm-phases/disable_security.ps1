Set-NetFirewallProfile -All -Enabled False
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 0 /f | Out-Null
# Defender disable: belt to the specialize-pass autounattend write that set
# WinDefend Start=4 before MsMpEng loaded. Set-MpPreference is silently a
# no-op under Tamper Protection on Win11 IoT LTSC, so it cannot be relied
# on here. Re-disable the service start type defensively in case the gold
# was provisioned without that specialize-pass write.
reg add "HKLM\SYSTEM\CurrentControlSet\Services\WinDefend" /v Start /t REG_DWORD /d 4 /f | Out-Null
# Freeze the OS build. Without ALL of these, a background Windows Update will
# bump the target past its CVE-vulnerable baseline mid-run and destroy the
# research target -- WaaSMedicSvc specifically re-enables wuauserv if only
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

# Win11 LTSC can restore WinDefend before audit mode completes. Tamper
# Protection then blocks the full disable, but permits explicit exclusions.
# Verify every path used for tools, transfers, evidence, and PoC execution.
$labPaths = @(
    "C:\winforge",
    "C:\temp",
    "C:\eip",
    "C:\ProgramData\EIP",
    "C:\Program Files\windbg-mcp"
)
$mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
foreach ($path in $labPaths) {
    Add-MpPreference -ExclusionPath $path -ErrorAction SilentlyContinue
}
$mp = Get-MpComputerStatus -ErrorAction SilentlyContinue

$defenderState = "real-time protection disabled"
$rtpProvenOff = $mp -and ($mp.RealTimeProtectionEnabled -is [bool]) -and ($mp.RealTimeProtectionEnabled -eq $false)
if (-not $rtpProvenOff) {
    $configured = @((Get-MpPreference -ErrorAction SilentlyContinue).ExclusionPath)
    $missing = @($labPaths | Where-Object { $configured -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw "Defender is active or its status is unavailable, and required lab exclusions are missing: $($missing -join ', ')"
    }
    if ($mp -and $mp.RealTimeProtectionEnabled -eq $true) {
        $defenderState = "active with verified lab-path exclusions"
    } else {
        $defenderState = "status unavailable with verified lab-path exclusions"
    }
}
Write-Host "[+] Lab baseline ready (Defender $defenderState; firewall off; UAC off; Windows Update locked)"
