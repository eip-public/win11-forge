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

# Hard assertion: previous code silently logged success even when Defender
# stayed fully active because Tamper Protection swallowed Set-MpPreference.
# If we reach this line and RTP is still on, the gold is shipping with live
# Defender and PoC binaries will be quarantined silently. Fail loud.
$mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
if ($mp -and $mp.RealTimeProtectionEnabled) {
    throw "Defender RealTimeProtectionEnabled is True at end of disable_security.ps1. WinDefend Start=4 did not take effect (specialize-pass write missing, or this gold predates that change). Investigate before sealing -- the resulting gold will quarantine offensive binaries."
}
Write-Host "[+] Security controls disabled (Defender RTP off; firewall off; UAC off; Windows Update locked)"
