$ErrorActionPreference = "Stop"

$Root = "C:\winforge"
$ReadyPath = Join-Path $Root "ready.json"
$LogPath = Join-Path $Root "bootstrap.log"
# (formerly $StaticIp/$Gateway/$Dns -- removed; gold image uses DHCP, IPs are
#  pinned per-MAC by libvirt dnsmasq on the host)

New-Item -ItemType Directory -Path $Root -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date).ToString("o"), $Message
    Add-Content -Path $LogPath -Value $line -Encoding ASCII
}

function Write-Ready {
    param(
        [string]$State,
        [string]$Message
    )

    $ips = @(
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne "127.0.0.1" } |
            Select-Object -ExpandProperty IPAddress
    )

    $payload = [ordered]@{
        state = $State
        message = $Message
        timestamp = (Get-Date).ToString("o")
        hostname = $env:COMPUTERNAME
        ips = $ips
    }

    $payload | ConvertTo-Json -Depth 4 | Set-Content -Path $ReadyPath -Encoding ASCII
}

function Ensure-Ssh {
    $service = Get-Service sshd -ErrorAction SilentlyContinue
    if ($service) {
        Set-Service -Name sshd -StartupType Automatic
        Start-Service sshd -ErrorAction SilentlyContinue
    } else {
        throw "sshd service is not installed"
    }

    New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force | Out-Null

    $sshdConfig = "C:\ProgramData\ssh\sshd_config"
    if (Test-Path $sshdConfig) {
        (Get-Content $sshdConfig) `
            -replace "Match Group administrators", "#Match Group administrators" `
            -replace "AuthorizedKeysFile __PROGRAMDATA__", "#AuthorizedKeysFile __PROGRAMDATA__" |
            Set-Content $sshdConfig -Encoding ASCII
    }

    New-NetFirewallRule -Name "OpenSSH-Server" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue | Out-Null
}

function Ensure-NetworkEnabled {
    for ($attempt = 0; $attempt -lt 24; $attempt++) {
        Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Status -eq "Disabled") {
                Enable-NetAdapter -Name $_.Name -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            }
        }

        $upAdapters = @(
            Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq "Up" }
        )
        if ($upAdapters.Count -gt 0) {
            return
        }

        Start-Sleep -Seconds 5
    }

    throw "No active network adapter became available"
}

function Ensure-Baseline {
    cmd /c "netsh advfirewall set allprofiles state off" | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableFirstLogonAnimation /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff" /f | Out-Null
    # Keep the pre-boot disable attempt, but Win11 LTSC can restore WinDefend
    # before this audit-mode task runs. Tamper Protection then blocks the full
    # disable while still permitting explicit lab-path exclusions.
    reg add "HKLM\SYSTEM\CurrentControlSet\Services\WinDefend" /v Start /t REG_DWORD /d 4 /f | Out-Null
    Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue

    $labPaths = @(
        "C:\winforge",
        "C:\temp",
        "C:\eip",
        "C:\ProgramData\EIP",
        "C:\Program Files\windbg-mcp"
    )
    foreach ($path in $labPaths) {
        Add-MpPreference -ExclusionPath $path -ErrorAction SilentlyContinue
    }

    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    $rtpProvenOff = $mp -and ($mp.RealTimeProtectionEnabled -is [bool]) -and ($mp.RealTimeProtectionEnabled -eq $false)
    if ($rtpProvenOff) {
        Write-Log "Defender real-time protection is disabled"
        return
    }

    $configured = @((Get-MpPreference -ErrorAction SilentlyContinue).ExclusionPath)
    $missing = @($labPaths | Where-Object { $configured -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw "Defender is active or its status is unavailable, and required lab exclusions are missing: $($missing -join ', ')"
    }
    if ($mp) {
        Write-Log "Defender remains active; verified required lab-path exclusions"
    } else {
        Write-Log "Defender status unavailable; verified required lab-path exclusions"
    }
}

function Ensure-Dhcp {
    # Gold image uses DHCP so the same image can boot as target OR debugger
    # with different IPs assigned by libvirt dnsmasq via MAC-pinned DHCP host
    # reservations (see setup.sh on the Linux host).
    $upAdapters = @(
        Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq "Up" }
    )
    $upAdapters | ForEach-Object {
        Set-NetIPInterface -InterfaceIndex $_.ifIndex -Dhcp Enabled -AddressFamily IPv4 -ErrorAction SilentlyContinue
        Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
    }
    # Renew lease so an IP is available immediately
    ipconfig /release | Out-Null
    ipconfig /renew  | Out-Null
}

try {
    Write-Log "bootstrap starting"
    Write-Ready -State "bootstrap_configuring" -Message "bootstrap starting"
    Ensure-NetworkEnabled
    Ensure-Ssh
    Ensure-Baseline
    Ensure-Dhcp
    Restart-Service sshd -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText("C:\setup-complete.txt", (Get-Date).ToString("o"))
    Write-Ready -State "bootstrap_ready" -Message "bootstrap complete"
    Write-Log "bootstrap ready"
}
catch {
    $message = $_.Exception.Message
    Write-Log "bootstrap failed: $message"
    Write-Ready -State "error" -Message $message
    throw
}
