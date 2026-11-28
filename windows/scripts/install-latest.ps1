<#
.SYNOPSIS
Installs or updates Hermes HQ for Windows from the latest GitHub Release.

.DESCRIPTION
Downloads the matching architecture zip (win-x64 or win-arm64) from
mrcharlesiv/hermes-hq-app GitHub Releases, verifies SHA-256 against
SHA256SUMS.txt, installs into %LOCALAPPDATA%\Programs\HermesHQ (so future
in-app updates work without admin rights), and creates a Start Menu shortcut.

.EXAMPLE
irm https://raw.githubusercontent.com/mrcharlesiv/hermes-hq-app/main/windows/scripts/install-latest.ps1 | iex
#>
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\HermesHQ'),
    [string]$Tag = '',
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$repo = 'mrcharlesiv/hermes-hq-app'
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }
$assetName = "HermesHQ-$arch.zip"
$headers = @{
    'User-Agent' = 'HermesHQ-Windows-Installer'
    'Accept'     = 'application/vnd.github+json'
}

Write-Host "Checking GitHub Releases for Hermes HQ ($arch)..."
$releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases?per_page=20" -Headers $headers
if ($releases -isnot [System.Array]) { $releases = @($releases) }

$release = $null
foreach ($r in $releases) {
    if ($r.draft -or $r.prerelease) { continue }
    if ($Tag -and ($r.tag_name -ne $Tag)) { continue }
    $match = $r.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    if ($match) { $release = $r; break }
}

if (-not $release) {
    throw "No published Windows release containing $assetName was found on github.com/$repo/releases."
}

$zipAsset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
$sumAsset = $release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-hq-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
    $zipPath = Join-Path $tempRoot $assetName
    Write-Host "Downloading $($release.tag_name) ($assetName)..."
    Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zipPath -Headers @{ 'User-Agent' = 'HermesHQ-Windows-Installer' }

    if ($sumAsset) {
        Write-Host "Verifying SHA-256 checksum..."
        $sumsText = (Invoke-WebRequest -Uri $sumAsset.browser_download_url -Headers @{ 'User-Agent' = 'HermesHQ-Windows-Installer' }).Content
        $expected = $null
        foreach ($line in ($sumsText -split "`r?`n")) {
            if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+)$') {
                if ([System.IO.Path]::GetFileName($Matches[2].Trim()) -ieq $assetName) {
                    $expected = $Matches[1].ToLowerInvariant()
                    break
                }
            }
        }
        if (-not $expected) { throw "SHA256SUMS.txt did not include an entry for $assetName." }
        $actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "SHA-256 verification failed for $assetName (expected $expected, got $actual)."
        }
    }

    $extractDir = Join-Path $tempRoot 'extracted'
    Write-Host "Extracting..."
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    $sourceDir = $extractDir
    if (-not (Test-Path (Join-Path $sourceDir 'HermesHQ.exe'))) {
        $sub = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
        if ($sub -and (Test-Path (Join-Path $sub.FullName 'HermesHQ.exe'))) {
            $sourceDir = $sub.FullName
        } else {
            throw "Archive did not contain HermesHQ.exe."
        }
    }

    # Close any running HermesHQ instance before replacing files
    $running = Get-Process -Name 'HermesHQ' -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host "Closing running Hermes HQ..."
        $running | ForEach-Object { $_.CloseMainWindow() | Out-Null }
        Start-Sleep -Seconds 2
        Get-Process -Name 'HermesHQ' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Write-Host "Installing to $InstallDir..."
    Copy-Item -Path (Join-Path $sourceDir '*') -Destination $InstallDir -Recurse -Force

    # Create or refresh Start Menu shortcut
    $exePath = Join-Path $InstallDir 'HermesHQ.exe'
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    if (Test-Path $startMenu) {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut((Join-Path $startMenu 'Hermes HQ.lnk'))
        $lnk.TargetPath = $exePath
        $lnk.WorkingDirectory = $InstallDir
        $lnk.Description = 'Hermes HQ'
        $lnk.Save()
    }

    Write-Host "Installed Hermes HQ $($release.tag_name) to $InstallDir."
    if (-not $NoLaunch) {
        Start-Process -FilePath $exePath -WorkingDirectory $InstallDir
    }
}
finally {
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
