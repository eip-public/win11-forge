Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Install vioserial driver + qemu-ga MSI. These come from virtio-win.iso,
# extracted host-side and scp'd to C:\winforge\virtio-stage\ by setup-vm.sh.
#
# Required end state:
#   - vioserial driver installed (PCI\VEN_1AF4&DEV_1043 → Status: OK)
#   - QEMU Guest Agent service deployed and set to auto-start
#
# The device file (\\.\Global\org.qemu.guest_agent.0) is created at boot,
# not on service start, so this phase exits with the service merely
# "Running" — full guest-ping reachability is validated post-reboot by
# seal-vm-gold.sh's verify pass (or by the lab spawn that boots the
# overlay).

$stage = "C:\winforge\virtio-stage"
$vioSerInf = Join-Path $stage "vioser.inf"
$qgaMsi    = Join-Path $stage "qemu-ga-x86_64.msi"

if (-not (Test-Path $vioSerInf)) { throw "missing $vioSerInf — setup-vm.sh should have scp'd it" }
if (-not (Test-Path $qgaMsi))    { throw "missing $qgaMsi — setup-vm.sh should have scp'd it" }

# vioserial driver (idempotent: pnputil dedupes on identical .inf).
# The PCI device exists from QEMU's virtio-serial-pci device but the
# Windows driver isn't auto-installed via Windows Update with Defender
# locked down. /install applies it to a matching present device.
Write-Host "[*] Installing vioserial driver from $vioSerInf"
pnputil /add-driver $vioSerInf /install
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 259) {  # 259 = no devices updated (already bound)
    throw "pnputil failed: exit $LASTEXITCODE"
}

# qemu-ga MSI (idempotent: msiexec /i on an already-installed package is a no-op).
Write-Host "[*] Installing QEMU Guest Agent from $qgaMsi"
$p = Start-Process msiexec.exe -ArgumentList '/i', $qgaMsi, '/quiet', '/norestart' -Wait -PassThru
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {  # 3010 = success, reboot requested
    throw "msiexec failed: exit $($p.ExitCode)"
}

# Confirm the service object exists. (Running state isn't guaranteed yet
# — the device file may not exist until next boot. --retry-path in the
# service args handles that.)
$svc = Get-Service QEMU-GA -EA SilentlyContinue
if (-not $svc) {
    throw "QEMU-GA service not registered after MSI install — check %TEMP%\MSI*.log"
}
Set-Service QEMU-GA -StartupType Automatic
Write-Host "[+] QEMU-GA service registered, startup=Automatic, current=$($svc.Status)"
