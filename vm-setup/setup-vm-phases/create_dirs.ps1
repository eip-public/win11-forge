foreach ($d in @("C:\winforge","C:\winforge\tools","C:\winforge\targets","C:\winforge\symbols","C:\winforge\patch-work")) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}
Write-Host "[+] Directories created"
