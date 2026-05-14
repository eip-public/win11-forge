param(
    [Parameter(Mandatory=$true)][string]$Script,
    [Parameter(Mandatory=$true)][string]$Log,
    [Parameter(Mandatory=$true)][string]$Marker
)
# Runs $Script with ALL output streams redirected to $Log on disk, then
# writes the exit code to $Marker atomically. Designed to run detached
# (via a scheduled task) -- the caller's ssh session never carries
# streaming output, so Windows OpenSSH's worker cannot wedge on stdout.
$ErrorActionPreference = 'Continue'
foreach ($d in @((Split-Path $Log -Parent), (Split-Path $Marker -Parent))) {
    if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
# Remove any stale marker so the caller can tell THIS run from any prior one.
Remove-Item -Path $Marker -Force -ErrorAction SilentlyContinue
# *> redirects ALL streams (stdout/stderr/warning/verbose/debug/info).
& powershell -NoProfile -ExecutionPolicy Bypass -File $Script *> $Log
$rc = $LASTEXITCODE
# Atomic marker write: write to .tmp then rename, so polling never sees
# a partial value.
Set-Content -Path "$Marker.tmp" -Value $rc -Encoding ASCII
Move-Item -Path "$Marker.tmp" -Destination $Marker -Force
