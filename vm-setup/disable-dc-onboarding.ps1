Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Disable DesktopCommanderMCP's "welcome onboarding" prompt-injection.
#
# DC (@wonderwhy-er/desktop-commander) emits a `[SYSTEM INSTRUCTION]: NEW
# USER ONBOARDING REQUIRED` block as part of normal tool results until the
# `pendingWelcomeOnboarding` flag is false. That block instructs the AI to
# render a menu verbatim and call `get_prompts` with specific IDs -- a real
# prompt-injection vector for any agent driving the lab.
#
# `set_config_value` deliberately refuses to flip `pendingWelcomeOnboarding`
# ("Key … is not configurable via this tool"). We patch the JSON on disk
# instead. DC re-reads its config on each tool call, so the next response
# from the same MCP session is clean.
#
# Idempotent -- running on an already-disabled config is a no-op.

$cfg = "C:\Windows\System32\config\systemprofile\.claude-server-commander\config.json"
if (-not (Test-Path $cfg)) {
    Write-Host "[!] DC config not found at $cfg -- has DC ever run?"
    exit 0
}

$j = Get-Content $cfg -Raw | ConvertFrom-Json
$changed = $false

if ($j.PSObject.Properties.Name -contains 'pendingWelcomeOnboarding' `
        -and $j.pendingWelcomeOnboarding) {
    $j.pendingWelcomeOnboarding = $false
    $changed = $true
}
if ($j.PSObject.Properties.Name -contains 'onboardingState') {
    if ($j.onboardingState.attemptsShown -ne 999) {
        $j.onboardingState.attemptsShown = 999
        $changed = $true
    }
}

if ($changed) {
    $j | ConvertTo-Json -Depth 32 | Set-Content -Path $cfg -Encoding UTF8
    Write-Host "[+] DC onboarding disabled in $cfg"
} else {
    Write-Host "[=] DC onboarding already disabled"
}
