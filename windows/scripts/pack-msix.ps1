# [WIN-INSTALL-PACK] Opt-in: makes an UNSIGNED local MSIX from an existing publish folder, then unpacks it and checks it
# against the plan file by file (windows/tools/msix-pack). The normal app and CI stay unpackaged; nothing here signs,
# installs, uploads, or touches a certificate or trust store. An unsigned package doesn't install as is: signing,
# installing and upgrade testing are separate gates that stay open.
#
# Run on Windows from the repo root, after a publish, e.g. after CI's "Build the app" step or scripts/build.ps1:
#   dotnet publish windows/src/HermesHQ.Windows -c Release -r win-x64 -p:Platform=x64 -o windows/build/app
#   pwsh windows/scripts/pack-msix.ps1 -Publish windows/build/app -Arch x64
# Writes windows/build/msix/HermesHQ-<arch>-unsigned.msix and windows/build/msix/work-<arch>/ (manifest, mapping, unpacked).
# MakeAppx comes from the Microsoft.Windows.SDK.BuildTools package the app already restores, else Windows Kits;
# -MakeAppx overrides. Exits non-zero on any failed check or tool failure.
param(
    [Parameter(Mandatory)] [string] $Publish,
    [ValidateSet('x64', 'arm64')] [string] $Arch = 'x64',
    [string] $MakeAppx = ''
)
$ErrorActionPreference = 'Stop'
$windows = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Publish = (Resolve-Path $Publish).Path

if (-not $MakeAppx) {
    # The SDK build tools version HermesHQ.Windows.csproj references (no new package).
    [xml] $proj = Get-Content (Join-Path $windows 'src/HermesHQ.Windows/HermesHQ.Windows.csproj')
    $ver = ($proj.Project.ItemGroup.PackageReference | Where-Object { $_.Include -eq 'Microsoft.Windows.SDK.BuildTools' }).Version
    $nuget = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $HOME '.nuget/packages' }
    $hostArch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'x64' }
    $candidates = @(Get-ChildItem (Join-Path $nuget "microsoft.windows.sdk.buildtools/$ver/bin") -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq $hostArch } | Sort-Object FullName -Descending)
    if (-not $candidates) {
        $candidates = @(Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue |
            Where-Object { $_.Directory.Name -eq $hostArch } | Sort-Object FullName -Descending)
    }
    if (-not $candidates) { throw "makeappx.exe not found (restore windows/src/HermesHQ.Windows first, or pass -MakeAppx)" }
    $MakeAppx = $candidates[0].FullName
}
Write-Host "MakeAppx: $MakeAppx"

$out = Join-Path $windows 'build/msix'
New-Item -ItemType Directory -Force $out | Out-Null
$msix = Join-Path $out "HermesHQ-$Arch-unsigned.msix"
$work = Join-Path $out "work-$Arch"

Push-Location $windows
try {
    dotnet run --project tools/msix-pack -c Release -- pack --publish $Publish --arch $Arch --out $msix --work $work --makeappx $MakeAppx `
        --project (Join-Path $windows 'src/HermesHQ.Windows/HermesHQ.Windows.csproj')
    if ($LASTEXITCODE) { throw "msix-pack failed (exit $LASTEXITCODE)" }
} finally { Pop-Location }

# Belt and braces: the package must carry no signature.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($msix)
try {
    if ($zip.Entries | Where-Object { $_.FullName -eq 'AppxSignature.p7x' }) { throw 'the package is signed; this path makes unsigned packages only' }
} finally { $zip.Dispose() }
Write-Host "Unsigned package checked: $msix. Not signed, not installed, not upgrade-tested."
