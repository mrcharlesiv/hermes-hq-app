using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Hermes.Core.Updates;

namespace Hermes.Core.Tests.Updates;

public class WindowsAppUpdaterTests
{
    [Theory]
    [InlineData("0.1.2", 0, 1, 2)]
    [InlineData("v0.2.5", 0, 2, 5)]
    [InlineData("win-v1.4.9", 1, 4, 9)]
    [InlineData("WIN-V2.0.1-beta.1", 2, 0, 1)]
    [InlineData("0.3", 0, 3, 0)]
    [InlineData("1.2.3.4", 1, 2, 3)]
    [InlineData("", 0, 0, 0)]
    [InlineData("not-a-version", 0, 0, 0)]
    public void ParseVersionHandlesWindowsTagsAndSemver(string raw, int major, int minor, int build)
    {
        Assert.Equal(new Version(major, minor, build), WindowsAppUpdater.ParseVersion(raw));
    }

    [Fact]
    public void IsNewerComparesNormalizedVersions()
    {
        Assert.True(WindowsAppUpdater.IsNewer(new Version(0, 1, 2), new Version(0, 1, 1)));
        Assert.True(WindowsAppUpdater.IsNewer(new Version(0, 2, 0), new Version(0, 1, 9)));
        Assert.False(WindowsAppUpdater.IsNewer(new Version(0, 1, 1), new Version(0, 1, 1)));
        Assert.False(WindowsAppUpdater.IsNewer(new Version(0, 1, 1, 0), new Version(0, 1, 1)));
        Assert.False(WindowsAppUpdater.IsNewer(new Version(0, 1, 0), new Version(0, 1, 1)));
    }

    [Fact]
    public void PickLatestReleaseSelectsHighestMatchingArchAndSkipsDraftsAndPrereleases()
    {
        const string json = """
        [
          {
            "tag_name": "win-v0.3.0",
            "name": "Draft 0.3.0",
            "draft": true,
            "prerelease": false,
            "html_url": "https://github.com/mrcharlesiv/hermes-hq-app/releases/tag/win-v0.3.0",
            "assets": [
              { "name": "HermesHQ-win-x64.zip", "browser_download_url": "https://example.invalid/030-x64.zip", "size": 100 }
            ]
          },
          {
            "tag_name": "win-v0.2.5-rc1",
            "name": "RC 0.2.5",
            "draft": false,
            "prerelease": true,
            "html_url": "https://github.com/mrcharlesiv/hermes-hq-app/releases/tag/win-v0.2.5-rc1",
            "assets": [
              { "name": "HermesHQ-win-x64.zip", "browser_download_url": "https://example.invalid/025-x64.zip", "size": 100 }
            ]
          },
          {
            "tag_name": "ios-v9.9.9",
            "name": "iOS Only",
            "draft": false,
            "prerelease": false,
            "html_url": "https://github.com/mrcharlesiv/hermes-hq-app/releases/tag/ios-v9.9.9",
            "assets": [
              { "name": "HermesHQ-iOS.ipa", "browser_download_url": "https://example.invalid/ios.ipa", "size": 100 }
            ]
          },
          {
            "tag_name": "win-v0.1.2",
            "name": "Hermes HQ Windows 0.1.2",
            "body": "Bug fixes",
            "draft": false,
            "prerelease": false,
            "html_url": "https://github.com/mrcharlesiv/hermes-hq-app/releases/tag/win-v0.1.2",
            "assets": [
              { "name": "HermesHQ-win-x64.zip", "browser_download_url": "https://example.invalid/012-x64.zip", "size": 12345 },
              { "name": "HermesHQ-win-arm64.zip", "browser_download_url": "https://example.invalid/012-arm64.zip", "size": 12000 },
              { "name": "SHA256SUMS.txt", "browser_download_url": "https://example.invalid/SHA256SUMS.txt", "size": 200 }
            ]
          },
          {
            "tag_name": "win-v0.2.0",
            "name": "Hermes HQ Windows 0.2.0",
            "body": "Auto-updater support",
            "draft": false,
            "prerelease": false,
            "html_url": "https://github.com/mrcharlesiv/hermes-hq-app/releases/tag/win-v0.2.0",
            "assets": [
              { "name": "HermesHQ-win-x64.zip", "browser_download_url": "https://example.invalid/020-x64.zip", "size": 22345 },
              { "name": "SHA256SUMS.txt", "browser_download_url": "https://example.invalid/020-SHA256SUMS.txt", "size": 150 }
            ]
          }
        ]
        """;

        var x64 = WindowsAppUpdater.PickLatestRelease(json, Architecture.X64);
        Assert.NotNull(x64);
        Assert.Equal("win-v0.2.0", x64.Tag);
        Assert.Equal(new Version(0, 2, 0), x64.Version);
        Assert.Equal("HermesHQ-win-x64.zip", x64.ZipAsset.Name);
        Assert.Equal("SHA256SUMS.txt", x64.ChecksumsAsset?.Name);

        // ARM64 is only present on 0.1.2, so ARM64 picks 0.1.2 rather than failing on 0.2.0.
        var arm64 = WindowsAppUpdater.PickLatestRelease(json, Architecture.Arm64);
        Assert.NotNull(arm64);
        Assert.Equal("win-v0.1.2", arm64.Tag);
        Assert.Equal("HermesHQ-win-arm64.zip", arm64.ZipAsset.Name);
    }

    [Fact]
    public void ParseChecksumForFileAndVerifySha256()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), "hermes-updater-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDir);
        try
        {
            var zipPath = Path.Combine(tempDir, "HermesHQ-win-x64.zip");
            File.WriteAllBytes(zipPath, "hermes-windows-release-bytes"u8.ToArray());
            var actualHex = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(zipPath))).ToLowerInvariant();

            var sums = $"""
                # Windows checksums
                {actualHex}  dist/HermesHQ-win-x64.zip
                aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa *HermesHQ-win-arm64.zip
                """;

            var parsed = WindowsAppUpdater.ParseChecksumForFile(sums, "HermesHQ-win-x64.zip");
            Assert.Equal(actualHex, parsed);
            Assert.True(WindowsAppUpdater.VerifyFileSha256(zipPath, parsed!));
            Assert.False(WindowsAppUpdater.VerifyFileSha256(zipPath, new string('0', 64)));
            Assert.Null(WindowsAppUpdater.ParseChecksumForFile(sums, "missing.zip"));
        }
        finally
        {
            Directory.Delete(tempDir, recursive: true);
        }
    }

    [Fact]
    public void ResolveStagedContentRootSupportsFlatAndNestedZipAndRejectsMissingExe()
    {
        var root = Path.Combine(Path.GetTempPath(), "hermes-stage-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var flat = Path.Combine(root, "flat");
            Directory.CreateDirectory(flat);
            File.WriteAllText(Path.Combine(flat, "HermesHQ.exe"), "stub");
            Assert.Equal(flat, WindowsAppUpdater.ResolveStagedContentRoot(flat));

            var nested = Path.Combine(root, "nested");
            var inner = Path.Combine(nested, "HermesHQ-win-x64");
            Directory.CreateDirectory(inner);
            File.WriteAllText(Path.Combine(inner, "HermesHQ.exe"), "stub");
            Assert.Equal(inner, WindowsAppUpdater.ResolveStagedContentRoot(nested));

            var empty = Path.Combine(root, "empty");
            Directory.CreateDirectory(empty);
            Assert.Throws<InvalidDataException>(() => WindowsAppUpdater.ResolveStagedContentRoot(empty));

            // Round-trip zip extraction check
            var zipPath = Path.Combine(root, "HermesHQ-win-x64.zip");
            ZipFile.CreateFromDirectory(flat, zipPath);
            var extracted = Path.Combine(root, "extracted");
            ZipFile.ExtractToDirectory(zipPath, extracted);
            Assert.Equal(extracted, WindowsAppUpdater.ResolveStagedContentRoot(extracted));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void BuildApplyScriptEscapesSingleQuotesAndRelaunchesExe()
    {
        var script = WindowsAppUpdater.BuildApplyScript(
            waitPid: 4242,
            stagedDir: @"C:\Users\O'Brien\AppData\Local\HermesHQ\updates\0.2.0\extracted",
            installDir: @"C:\Users\O'Brien\Apps\HermesHQ",
            stagingRoot: @"C:\Users\O'Brien\AppData\Local\HermesHQ\updates\0.2.0");

        Assert.Contains("$waitPid = 4242", script);
        Assert.Contains(@"C:\Users\O''Brien\Apps\HermesHQ", script);
        Assert.Contains("Copy-Item", script);
        Assert.Contains("Start-Process -FilePath $exePath", script);
        Assert.Contains("Remove-Item -Path $stagingRoot", script);
    }

    [Fact]
    public void IsDirectoryWritableDetectsExistingAndMissingFolders()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), "hermes-write-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDir);
        try
        {
            Assert.True(WindowsAppUpdater.IsDirectoryWritable(tempDir));
            Assert.False(WindowsAppUpdater.IsDirectoryWritable(Path.Combine(tempDir, "does-not-exist")));
        }
        finally
        {
            Directory.Delete(tempDir, recursive: true);
        }
    }
}
