Set-NetFirewallProfile -All -Enabled False
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 0 /f | Out-Null
Set-MpPreference -DisableRealtimeMonitoring 1 -ErrorAction SilentlyContinue
Set-MpPreference -DisableBehaviorMonitoring 1 -ErrorAction SilentlyContinue
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
Write-Host "[+] Security controls disabled"
