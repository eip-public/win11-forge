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
