# Builds Hermes HQ for Windows into a self-contained folder and a zip you can copy to any Windows 10/11 PC.
# Run on Windows from the repo root:   pwsh windows/scripts/build.ps1 [-Arch x64|arm64]
# An unsigned local MSIX of the folder is a separate, opt-in step: scripts/pack-msix.ps1 -Publish build/HermesHQ-<arch>.
# Needs the .NET 9 SDK (winget install Microsoft.DotNet.SDK.9). Visual Studio is not required for this script.
param([ValidateSet('x64', 'arm64')] [string] $Arch = 'x64')
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

dotnet test HermesHQ.sln --filter "Category!=E2E"
if ($LASTEXITCODE) { throw 'Core tests failed' }

$out = "build/HermesHQ-$Arch"
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
dotnet publish src/HermesHQ.Windows -c Release -r "win-$Arch" -p:Platform=$Arch -o $out
if ($LASTEXITCODE) { throw 'Publish failed' }

$zip = "build/HermesHQ-$Arch.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path "$out/*" -DestinationPath $zip
Write-Host "Built $out\HermesHQ.exe and $zip"
