$env:Path = "C:\Program Files\nodejs;C:\ProgramData\npm;$env:Path"
Set-Location C:\winforge

# Previous version ran 'npm install ... 2>&1 | Select-Object -Last 5' which
# threw away the real error on failure (e.g. ECONNRESET mid-reify + Windows
# AV file-locks during cleanup gave EPERM rmdir on partial node_modules).
# Show the full output, check $LASTEXITCODE explicitly, and clean any half-
# install before bailing so a retry starts from a clean root.
$entry = "C:\winforge\node_modules\@wonderwhy-er\desktop-commander\dist\index.js"
if (Test-Path $entry) {
    Write-Host "[+] DesktopCommanderMCP already installed: $entry"
    return
}

# Wipe any partial node_modules left from a previous failed reify. Without
# this, npm's own cleanup can re-EPERM if Defender is still holding file
# handles on dist/.
if (Test-Path C:\winforge\node_modules) {
    Write-Host "[*] Removing partial C:\winforge\node_modules from previous attempt"
    Remove-Item -Recurse -Force C:\winforge\node_modules -ErrorAction SilentlyContinue
}
if (Test-Path C:\winforge\package-lock.json) {
    Remove-Item -Force C:\winforge\package-lock.json -ErrorAction SilentlyContinue
}

npm install @wonderwhy-er/desktop-commander --no-fund --no-audit
if ($LASTEXITCODE -ne 0) {
    throw "npm install failed (exit $LASTEXITCODE) -- see C:\Users\forge\AppData\Local\npm-cache\_logs\ for the full debug log"
}

if (-not (Test-Path $entry)) {
    throw "npm install reported success but $entry is missing"
}
Write-Host "[+] DesktopCommanderMCP: $entry"
