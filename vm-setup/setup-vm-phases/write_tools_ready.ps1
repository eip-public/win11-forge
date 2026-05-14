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
