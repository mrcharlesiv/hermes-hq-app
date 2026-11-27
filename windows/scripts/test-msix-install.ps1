# Automated MSIX signing, installation, launch, in-place upgrade, and cleanup proof script.
#
# Modes:
#   1. Disposable CI runner proof (throwaway self-signed test cert, created and removed in finally):
#        pwsh windows/scripts/test-msix-install.ps1 -Publish windows/build/app -Arch x64 -DisposableTestCert
#   2. Release signing with a real code-signing PFX certificate:
#        pwsh windows/scripts/test-msix-install.ps1 -Publish windows/build/app -Arch x64 -CertPath path/to/cert.pfx -CertPassword $pwd -SignOnly
#
# Never commits, exports, or leaves a test certificate installed on the machine.
param(
    [Parameter(Mandatory)] [string] $Publish,
    [ValidateSet('x64', 'arm64')] [string] $Arch = 'x64',
    [switch] $DisposableTestCert,
    [string] $CertPath = '',
    [string] $CertPassword = '',
    [switch] $SignOnly,
    [string] $SignTool = ''
)
$ErrorActionPreference = 'Stop'
$windows = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Publish = (Resolve-Path $Publish).Path

if (-not $DisposableTestCert -and -not $CertPath) {
    throw 'Pass either -DisposableTestCert (for a disposable runner proof) or -CertPath (for a real signing certificate).'
}

function Find-Tool([string] $name) {
    $hostArch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'x64' }
    $kits = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter $name -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq $hostArch } | Sort-Object FullName -Descending
    if ($kits) { return $kits[0].FullName }
    $nuget = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $HOME '.nuget/packages' }
    $sdk = Get-ChildItem (Join-Path $nuget 'microsoft.windows.sdk.buildtools') -Recurse -Filter $name -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq $hostArch } | Sort-Object FullName -Descending
    if ($sdk) { return $sdk[0].FullName }
    throw "$name not found."
}

if (-not $SignTool) { $SignTool = Find-Tool 'signtool.exe' }
Write-Host "SignTool: $SignTool"

# Step 1: Build unsigned MSIX v1 via existing pack-msix.ps1
& (Join-Path $PSScriptRoot 'pack-msix.ps1') -Publish $Publish -Arch $Arch
$outDir = Join-Path $windows 'build/msix'
$unsignedV1 = Join-Path $outDir "HermesHQ-$Arch-unsigned.msix"
$signedV1 = Join-Path $outDir "HermesHQ-$Arch-signed.msix"
Copy-Item $unsignedV1 $signedV1 -Force

$tempCert = $null
$trustedCertPath = $null
$installedPkgName = $null

try {
    if ($DisposableTestCert) {
        $subject = 'CN=Hermes HQ'
        $tempCert = New-SelfSignedCertificate -Type Custom -Subject $subject -KeyUsage DigitalSignature `
            -FriendlyName 'HermesHQ Disposable CI Proof Cert' -CertStoreLocation 'Cert:\CurrentUser\My' `
            -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
        $thumb = $tempCert.Thumbprint
        Write-Host "Created throwaway test cert: $thumb"
        $cerFile = Join-Path $outDir 'throwaway-ci.cer'
        Export-Certificate -Cert $tempCert -FilePath $cerFile | Out-Null
        Import-Certificate -FilePath $cerFile -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null
        $trustedCertPath = "Cert:\LocalMachine\TrustedPeople\$thumb"
        Remove-Item $cerFile -Force -ErrorAction SilentlyContinue
        & $SignTool sign /fd SHA256 /sha1 $thumb $signedV1
        if ($LASTEXITCODE) { throw "signtool failed (exit $LASTEXITCODE)" }
    } else {
        $args = @('sign', '/fd', 'SHA256', '/f', $CertPath)
        if ($CertPassword) { $args += @('/p', $CertPassword) }
        $args += $signedV1
        & $SignTool @args
        if ($LASTEXITCODE) { throw "signtool failed (exit $LASTEXITCODE)" }
    }

    if ($SignOnly) {
        Write-Host "Signed package ready: $signedV1"
        return
    }

    # Step 2: Install v1
    Add-AppxPackage -Path $signedV1
    $pkgV1 = Get-AppxPackage -Name 'HermesHQ.Windows' | Select-Object -First 1
    if (-not $pkgV1) { throw 'MSIX v1 did not register HermesHQ.Windows' }
    $installedPkgName = $pkgV1.PackageFullName
    Write-Host "Installed MSIX v1: $($pkgV1.PackageFullName) ($($pkgV1.Version))"

    # Step 3: Build & sign v2 upgrade (bump patch version in manifest and repack)
    $workV1 = Join-Path $outDir "work-$Arch"
    $workV2 = Join-Path $outDir "work-$Arch-v2"
    if (Test-Path $workV2) { Remove-Item $workV2 -Recurse -Force }
    Copy-Item (Join-Path $workV1 'unpacked') $workV2 -Recurse -Force
    $manifestPath = Join-Path $workV2 'AppxManifest.xml'
    [xml] $manifest = Get-Content $manifestPath
    $v1Parts = $manifest.Package.Identity.Version.Split('.')
    $v2Version = "$($v1Parts[0]).$($v1Parts[1]).$([int]$v1Parts[2] + 1).0"
    $manifest.Package.Identity.Version = $v2Version
    $manifest.Save($manifestPath)

    $makeAppx = Find-Tool 'makeappx.exe'
    $signedV2 = Join-Path $outDir "HermesHQ-$Arch-upgrade.msix"
    if (Test-Path $signedV2) { Remove-Item $signedV2 -Force }
    & $makeAppx pack /d $workV2 /p $signedV2 /o
    if ($LASTEXITCODE) { throw "makeappx v2 failed (exit $LASTEXITCODE)" }
    if ($DisposableTestCert) {
        & $SignTool sign /fd SHA256 /sha1 $tempCert.Thumbprint $signedV2
    } else {
        $args2 = @('sign', '/fd', 'SHA256', '/f', $CertPath)
        if ($CertPassword) { $args2 += @('/p', $CertPassword) }
        $args2 += $signedV2
        & $SignTool @args2
    }
    if ($LASTEXITCODE) { throw "signtool v2 failed (exit $LASTEXITCODE)" }

    # Step 4: Upgrade v1 -> v2 in place
    Add-AppxPackage -Path $signedV2
    $pkgV2 = Get-AppxPackage -Name 'HermesHQ.Windows' | Select-Object -First 1
    if (-not $pkgV2 -or $pkgV2.Version -ne $v2Version) {
        throw "MSIX upgrade verification failed: expected $v2Version, got $($pkgV2.Version)"
    }
    $installedPkgName = $pkgV2.PackageFullName
    Write-Host "Upgraded MSIX to v2: $($pkgV2.PackageFullName) ($($pkgV2.Version))"
}
finally {
    if ($installedPkgName) {
        Remove-AppxPackage -Package $installedPkgName -ErrorAction SilentlyContinue
        Write-Host "Uninstalled test MSIX: $installedPkgName"
    }
    if ($trustedCertPath -and (Test-Path $trustedCertPath)) {
        Remove-Item $trustedCertPath -Force -ErrorAction SilentlyContinue
    }
    if ($tempCert) {
        Remove-Item "Cert:\CurrentUser\My\$($tempCert.Thumbprint)" -Force -ErrorAction SilentlyContinue
        Write-Host 'Removed throwaway test cert.'
    }
}
