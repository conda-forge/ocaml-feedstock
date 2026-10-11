# Load a DLL with plain Win32 LoadLibraryW; print the handle or the last error.
# Usage: load-dll.ps1 <dll-path>
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NativeLoader {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr LoadLibraryW(string path);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool FreeLibrary(IntPtr module);
}
"@

$handle = [NativeLoader]::LoadLibraryW([string]$args[0])
if ($handle -eq [IntPtr]::Zero) {
    Write-Host "load failed $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    exit 1
}
Write-Host "load ok $handle"
$null = [NativeLoader]::FreeLibrary($handle)
exit 0
