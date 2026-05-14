if (Test-Path C:\winforge\mcp-windbg-src) { Remove-Item -Recurse -Force C:\winforge\mcp-windbg-src }
New-Item -ItemType Directory -Path C:\winforge\mcp-windbg-src | Out-Null
tar -xzf C:\winforge\mcp-windbg-src.tar.gz -C C:\winforge\mcp-windbg-src
python -m pip install --quiet C:\winforge\mcp-windbg-src 2>&1 | Select-Object -Last 3
if ($LASTEXITCODE -ne 0) { throw "mcp-windbg pip install failed ($LASTEXITCODE)" }
$cli = Get-Command mcp-windbg -EA SilentlyContinue
if (-not $cli) {
    $fallback = "C:\Python314\Scripts\mcp-windbg.exe"
    if (Test-Path $fallback) { $cli = Get-Item $fallback }
}
if (-not $cli) { throw "mcp-windbg CLI missing after install" }
Write-Host ("[+] mcp-windbg installed at " + $cli.Source)
