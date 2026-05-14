Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$src = @"
using System;
using System.Runtime.InteropServices;
public class KdBreak {
    [DllImport("ntdll.dll")]
    public static extern int NtSystemDebugControl(
        uint Command, IntPtr InBuf, uint InLen,
        IntPtr OutBuf, uint OutLen, out uint Ret);
}
"@
Add-Type -TypeDefinition $src
$ret = [uint32]0
$s = [KdBreak]::NtSystemDebugControl(6, [IntPtr]::Zero, 0, [IntPtr]::Zero, 0, [ref]$ret)
if ($s -eq 0) { Write-Host "OK" } else { Write-Host ("FAIL:0x" + $s.ToString("X8")) }
