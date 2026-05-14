param(
    [Parameter(Mandatory=$true)][string]$Script,
    [Parameter(Mandatory=$true)][string]$Log,
    [Parameter(Mandatory=$true)][string]$Marker,
    [Parameter(Mandatory=$true)][string]$TaskName
)
# Called by the bash side via a short ssh. Registers a one-shot scheduled
# task that runs runner.ps1 with the given args, then starts it. Returns
# in ~1s. The task itself is detached from the ssh session -- sshd has
# nothing to wait on after Start-ScheduledTask returns.
$ErrorActionPreference = 'Stop'

# Idempotent: delete any prior task with the same name. Use the cmdlet
# (NOT schtasks.exe) so -ErrorAction works -- schtasks.exe writes to
# stderr on "not found", which $ErrorActionPreference=Stop would treat
# as a fatal native-command error.
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$runnerPath = Join-Path $PSScriptRoot 'runner.ps1'
$args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath,
    '-Script', $Script, '-Log', $Log, '-Marker', $Marker
) -join ' '

$action    = New-ScheduledTaskAction -Execute 'powershell' -Argument $args
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
# Trigger needs to be some valid time; we never let it fire from the trigger
# itself -- Start-ScheduledTask kicks it off immediately. Use a far-future
# date so the trigger never autonomously fires.
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(10)
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
