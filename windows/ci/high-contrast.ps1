# [WIN-60] Turns a Windows contrast theme on or off for the signed-in user, on the CI runner only (windows/ci/windows.yml,
# the "Larger text and high contrast" step). SystemParametersInfo SPI_SETHIGHCONTRAST with SPIF_SENDCHANGE and not
# SPIF_UPDATEINIFILE, so nothing is written to the profile; the step turns it off again afterwards. It runs in a process
# of its own (pwsh -File), so a window that doesn't answer the WM_SETTINGCHANGE broadcast can't hang the step:
# the caller waits 60 s at most. Prints one line: "on", "off", "was on" or "failed: <reason>", and exits 0 only on
# "on" / "off" / "was on". Exit 2 is a reported SPI/platform gap; a bad guard/script/invocation is a failure.
[CmdletBinding(PositionalBinding=$false)]
param([Parameter(Mandatory = $true)][ValidateSet("On", "Off", "State")][string]$Turn)
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot/../build/reply-probe/ReplyProbe.exe" guard
if ($LASTEXITCODE -ne 0) { throw 'Refused outside the opted-in desktop proof.' }
$Scheme = 'High Contrast Black'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace HQ {
  public static class Contrast {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct HIGHCONTRAST { public uint cbSize; public uint dwFlags; public IntPtr lpszDefaultScheme; }
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SystemParametersInfoW(uint action, uint param, ref HIGHCONTRAST value, uint winIni);
    const uint SPI_GETHIGHCONTRAST = 0x0042, SPI_SETHIGHCONTRAST = 0x0043, HCF_HIGHCONTRASTON = 0x1, SPIF_SENDCHANGE = 0x2;

    public static bool IsOn() {
      var hc = new HIGHCONTRAST { cbSize = (uint)Marshal.SizeOf(typeof(HIGHCONTRAST)) };
      if (!SystemParametersInfoW(SPI_GETHIGHCONTRAST, hc.cbSize, ref hc, 0))
        throw new InvalidOperationException("SPI_GETHIGHCONTRAST failed (" + Marshal.GetLastWin32Error() + ")");
      return (hc.dwFlags & HCF_HIGHCONTRASTON) != 0;
    }

    public static void Set(bool on, string scheme) {
      var hc = new HIGHCONTRAST { cbSize = (uint)Marshal.SizeOf(typeof(HIGHCONTRAST)) };
      if (!SystemParametersInfoW(SPI_GETHIGHCONTRAST, hc.cbSize, ref hc, 0))
        throw new InvalidOperationException("SPI_GETHIGHCONTRAST failed (" + Marshal.GetLastWin32Error() + ")");
      hc.dwFlags = on ? hc.dwFlags | HCF_HIGHCONTRASTON : hc.dwFlags & ~HCF_HIGHCONTRASTON;
      var name = on ? Marshal.StringToHGlobalUni(scheme) : IntPtr.Zero;
      try {
        hc.lpszDefaultScheme = name;
        if (!SystemParametersInfoW(SPI_SETHIGHCONTRAST, hc.cbSize, ref hc, SPIF_SENDCHANGE))
          throw new InvalidOperationException("SPI_SETHIGHCONTRAST failed (" + Marshal.GetLastWin32Error() + ")");
      } finally { if (name != IntPtr.Zero) Marshal.FreeHGlobal(name); }
      if (IsOn() != on) throw new InvalidOperationException("SPI_SETHIGHCONTRAST returned but the contrast theme is still " + (on ? "off" : "on"));
    }
  }
}
"@

try {
  switch ($Turn) {
    "State" { if ([HQ.Contrast]::IsOn()) { "was on" } else { "off" } }
    "On" { if ([HQ.Contrast]::IsOn()) { "was on" } else { [HQ.Contrast]::Set($true, $Scheme); "on" } }
    "Off" { [HQ.Contrast]::Set($false, $Scheme); "off" }
  }
  exit 0
} catch {
  $why = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
  "failed: $why"
  if ($why -match '^SPI_(GET|SET)HIGHCONTRAST ') { exit 2 }
  exit 1
}
