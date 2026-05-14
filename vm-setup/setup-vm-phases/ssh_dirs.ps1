$profileRoot = [Environment]::GetFolderPath("UserProfile")
New-Item -ItemType Directory -Path (Join-Path $profileRoot ".ssh") -Force | Out-Null
New-Item -ItemType Directory -Path C:\ProgramData\ssh -Force | Out-Null
Write-Host "[+] SSH dirs created"
if (([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    New-Item -ItemType File -Path C:\ProgramData\ssh\administrators_authorized_keys -Force | Out-Null
}
