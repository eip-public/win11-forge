Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Install VMware Tools. setup.exe is staged at C:\winforge\vmware-tools\
# by setup-vm.sh (extracted host-side from /usr/lib/vmware/isoimages/windows.iso).
#
# Required end state: VMTools service registered. Service only RUNS under
# the VMware hypervisor (vmtoolsd detects VMware via cpuid at startup);
# on KVM the service stays Stopped after install -- harmless. When the
# gold qcow2 is later booted under VMware (via gold.vmdk), the service
# starts on first boot and vmrun's runProgramInGuest becomes available.
#
# Why install it in the KVM-built gold at all: backend/vmware.sh reuses
# the same gold image (converted to .vmdk). For the VMware backend to
# have a non-SSH guest control plane (the peer of qga on KVM), VMware
# Tools must already be present. Installing it once in the gold avoids
# a per-spawn install round-trip.
#
# Idempotent: re-running setup.exe on an already-installed gold is a no-op.

$stage = "C:\winforge\vmware-tools"
$setup = Join-Path $stage "setup.exe"

# Idempotency: if VMTools is already installed + Automatic, skip the
# setup.exe run entirely. Re-running setup.exe on an already-installed
# system was observed to put the install into Maintenance mode and
# in silent mode this can REMOVE the service instead of repairing,
# leaving the gold worse off than before.
$existing = Get-Service VMTools -EA SilentlyContinue
if ($existing -and $existing.StartType -eq 'Automatic') {
    Write-Host "[=] VMware Tools already installed (service '$($existing.Name)' StartType=$($existing.StartType) Status=$($existing.Status))"
    return
}

if (-not (Test-Path $setup)) {
    throw "missing $setup -- setup-vm.sh should have scp'd it from /usr/lib/vmware/isoimages/windows.iso"
}

Write-Host "[*] Installing VMware Tools from $setup"
# /S = silent; /v passes args to embedded MSI: /qn = no UI, REBOOT=R = suppress.
# Exit 0 = success, 3010 = success+reboot-requested. Anything else is a real error.
$p = Start-Process $setup -ArgumentList '/S','/v','/qn REBOOT=R' -Wait -PassThru
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
    throw "VMware Tools setup.exe failed: exit $($p.ExitCode)"
}

# Confirm the service object exists. Don't assert Running -- vmtoolsd
# only starts when the host is actually VMware. On KVM-built golds the
# service is registered but Stopped; that's the design.
$svc = Get-Service VMTools -EA SilentlyContinue
if (-not $svc) {
    # Some VMware Tools versions name the service differently; check
    # alternates before giving up.
    $svc = Get-Service VMwareToolboxCmd, VMTools, VMware-Tools -EA SilentlyContinue | Select-Object -First 1
}
if (-not $svc) {
    throw "VMware Tools service not registered after setup.exe install -- check %TEMP%\vminst.log"
}
Set-Service $svc.Name -StartupType Automatic
Write-Host "[+] VMware Tools service '$($svc.Name)' registered, startup=Automatic, current=$($svc.Status)"
