$choco = "C:\ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $choco)) {
    throw "Chocolatey executable not found at $choco"
}

# choco install python3 fails with "Unable to resolve dependency vcredist2015"
# under chocolatey 2.7.2 even though vcredist2015 exists on the community repo
# — looks like a regression in 2.7.2's transitive dep resolver. Installing
# vcredist2015 explicitly first satisfies the dep from local cache so python3
# proceeds.
#
# Real exit-code check on each install. The previous version piped output
# through `Select-String "installed|already" | Write-Host` which filtered
# OUT the failure message (`Chocolatey installed 0/1 packages. 1 packages
# failed.`) and never checked $LASTEXITCODE, so a failed choco install
# returned silent success to setup-vm.sh.
function Install-Choco-Package {
    param([string]$Name)
    Write-Host "[*] choco install $Name"
    & $choco install $Name -y --no-progress
    if ($LASTEXITCODE -ne 0) {
        throw "choco install $Name failed (exit $LASTEXITCODE)"
    }
}

Install-Choco-Package vcredist2015
Install-Choco-Package python3
Install-Choco-Package 7zip
Install-Choco-Package git

$env:Path = "C:\Python314;C:\Program Files\Git\cmd;C:\ProgramData\chocolatey\bin;$env:Path"
$py = Get-Command python -EA SilentlyContinue
if (-not $py -and (Test-Path "C:\Python314\python.exe")) {
    $py = Get-Item "C:\Python314\python.exe"
}
$git = Get-Command git -EA SilentlyContinue
if (-not $git -and (Test-Path "C:\Program Files\Git\cmd\git.exe")) {
    $git = Get-Item "C:\Program Files\Git\cmd\git.exe"
}
if (-not $py -or -not $git) {
    throw "Python and Git must both be installed before setup can continue"
}
Write-Host "[+] Tools installed"
