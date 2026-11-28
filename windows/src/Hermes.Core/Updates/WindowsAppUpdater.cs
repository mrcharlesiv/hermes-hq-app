using System.IO.Compression;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hermes.Core.Updates;

public enum UpdateStatus
{
    UpToDate,
    UpdateAvailable,
    Failed,
}

public sealed record WindowsReleaseAsset(string Name, string DownloadUrl, long SizeBytes);

public sealed record WindowsReleaseInfo(
    string Tag,
    Version Version,
    string Name,
    string Notes,
    string HtmlUrl,
    WindowsReleaseAsset ZipAsset,
    WindowsReleaseAsset? ChecksumsAsset,
    DateTimeOffset? PublishedAt);

public sealed record UpdateCheckResult(
    UpdateStatus Status,
    Version CurrentVersion,
    WindowsReleaseInfo? Release,
    string? ErrorMessage = null);

public sealed record StagedWindowsUpdate(
    WindowsReleaseInfo Release,
    string ContentDir,
    string StagingDir);

/// Checks GitHub Releases for newer Windows builds of Hermes HQ, verifies SHA-256 checksums,
/// stages the extracted archive, and builds the self-cleaning PowerShell swap script that
/// replaces the unpackaged install folder after HermesHQ.exe exits and relaunches it.
public static class WindowsAppUpdater
{
    public const string DefaultReleasesApiUrl = "https://api.github.com/repos/mrcharlesiv/hermes-hq-app/releases?per_page=20";
    public const string ReleasesPageUrl = "https://github.com/mrcharlesiv/hermes-hq-app/releases";
    public const string WinTagPrefix = "win-v";
    public const string ChecksumsAssetName = "SHA256SUMS.txt";
    public const string DefaultExeName = "HermesHQ.exe";

    /// Parses a version string such as "0.1.2", "v0.1.2", "win-v0.2.0", or "0.1.2.0" into a
    /// normalized 3-part Version (Major.Minor.Build). Returns 0.0.0 when blank or invalid.
    public static Version ParseVersion(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return new Version(0, 0, 0);
        var text = raw.Trim();
        if (text.StartsWith(WinTagPrefix, StringComparison.OrdinalIgnoreCase))
            text = text[WinTagPrefix.Length..];
        else if (text.StartsWith('v') || text.StartsWith('V'))
            text = text[1..];

        var suffix = text.IndexOfAny(['-', '+']);
        if (suffix >= 0) text = text[..suffix];

        var parts = text.Split('.', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2) return new Version(0, 0, 0);
        if (!int.TryParse(parts[0], out var major) || major < 0) return new Version(0, 0, 0);
        if (!int.TryParse(parts[1], out var minor) || minor < 0) return new Version(0, 0, 0);
        var build = 0;
        if (parts.Length >= 3 && (!int.TryParse(parts[2], out build) || build < 0))
            return new Version(0, 0, 0);
        return new Version(major, minor, build);
    }

    public static Version Normalize(Version version) =>
        new(Math.Max(0, version.Major), Math.Max(0, version.Minor), Math.Max(0, version.Build));

    public static bool IsNewer(Version candidate, Version current) =>
        Normalize(candidate) > Normalize(current);

    public static string ExpectedZipAssetName(Architecture arch) =>
        arch == Architecture.Arm64 ? "HermesHQ-win-arm64.zip" : "HermesHQ-win-x64.zip";

    public static string ArchitectureToken(Architecture arch) =>
        arch == Architecture.Arm64 ? "win-arm64" : "win-x64";

    /// Picks the highest-version published Windows release matching `arch` from GitHub's
    /// `/releases` array (or a single release JSON object).
    public static WindowsReleaseInfo? PickLatestRelease(string releasesJson, Architecture arch, bool includePrereleases = false)
    {
        if (string.IsNullOrWhiteSpace(releasesJson)) return null;
        JsonNode? root;
        try { root = JsonNode.Parse(releasesJson); }
        catch (JsonException) { return null; }

        IEnumerable<JsonObject> items = root switch
        {
            JsonArray arr => arr.OfType<JsonObject>(),
            JsonObject obj => [obj],
            _ => [],
        };

        var exactName = ExpectedZipAssetName(arch);
        var archToken = ArchitectureToken(arch);
        WindowsReleaseInfo? best = null;

        foreach (var item in items)
        {
            if (JsonBool(item, "draft")) continue;
            if (!includePrereleases && JsonBool(item, "prerelease")) continue;

            var tag = JsonStr(item, "tag_name")?.Trim() ?? "";
            var version = ParseVersion(tag);
            if (version == new Version(0, 0, 0)) continue;

            var assets = ParseAssets(item["assets"] as JsonArray);
            var zip = assets.FirstOrDefault(a => string.Equals(a.Name, exactName, StringComparison.OrdinalIgnoreCase))
                      ?? assets.FirstOrDefault(a =>
                          a.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) &&
                          a.Name.Contains(archToken, StringComparison.OrdinalIgnoreCase));
            if (zip == null) continue;

            var checksums = assets.FirstOrDefault(a =>
                string.Equals(a.Name, ChecksumsAssetName, StringComparison.OrdinalIgnoreCase));

            var name = JsonStr(item, "name")?.Trim();
            if (string.IsNullOrEmpty(name)) name = $"Hermes HQ {version.ToString(3)}";
            var notes = JsonStr(item, "body") ?? "";
            var htmlUrl = JsonStr(item, "html_url")?.Trim();
            if (string.IsNullOrEmpty(htmlUrl)) htmlUrl = ReleasesPageUrl;

            DateTimeOffset? publishedAt = null;
            if (JsonStr(item, "published_at") is { Length: > 0 } pubText
                && DateTimeOffset.TryParse(pubText, out var parsedDate))
            {
                publishedAt = parsedDate;
            }

            var candidate = new WindowsReleaseInfo(tag, version, name, notes, htmlUrl, zip, checksums, publishedAt);
            if (best == null || IsNewer(candidate.Version, best.Version))
                best = candidate;
        }

        return best;
    }

    private static bool JsonBool(JsonObject obj, string key) =>
        obj[key] is JsonValue v && v.TryGetValue<bool>(out var b) && b;

    private static string? JsonStr(JsonObject obj, string key) =>
        obj[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    private static List<WindowsReleaseAsset> ParseAssets(JsonArray? array)
    {
        var result = new List<WindowsReleaseAsset>();
        if (array == null) return result;
        foreach (var node in array)
        {
            if (node is not JsonObject obj) continue;
            var name = JsonStr(obj, "name")?.Trim();
            var url = JsonStr(obj, "browser_download_url")?.Trim();
            if (string.IsNullOrEmpty(name) || string.IsNullOrEmpty(url)) continue;
            long size = 0;
            if (obj["size"] is JsonValue sizeVal && sizeVal.TryGetValue<long>(out var parsedSize))
                size = parsedSize;
            result.Add(new WindowsReleaseAsset(name, url, size));
        }
        return result;
    }

    /// Parses a standard SHA256SUMS.txt file (`<64-hex>  <filename>` or `<64-hex> *<filename>`)
    /// and returns the expected lowercase SHA-256 hex digest for `fileName`, or null if absent.
    public static string? ParseChecksumForFile(string checksumsText, string fileName)
    {
        if (string.IsNullOrWhiteSpace(checksumsText) || string.IsNullOrWhiteSpace(fileName))
            return null;
        var targetName = Path.GetFileName(fileName.Trim());
        foreach (var rawLine in checksumsText.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var sep = line.IndexOfAny([' ', '\t']);
            if (sep <= 0) continue;
            var hex = line[..sep].Trim();
            if (!IsHexSha256(hex)) continue;
            var rest = line[(sep + 1)..].Trim().TrimStart('*').Trim();
            if (rest.Length == 0) continue;
            if (string.Equals(Path.GetFileName(rest), targetName, StringComparison.OrdinalIgnoreCase))
                return hex.ToLowerInvariant();
        }
        return null;
    }

    private static bool IsHexSha256(string value)
    {
        if (value.Length != 64) return false;
        foreach (var c in value)
        {
            var ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
            if (!ok) return false;
        }
        return true;
    }

    public static bool VerifyFileSha256(string filePath, string expectedHex)
    {
        if (!File.Exists(filePath) || string.IsNullOrWhiteSpace(expectedHex)) return false;
        var cleanExpected = expectedHex.Trim();
        if (!IsHexSha256(cleanExpected)) return false;
        using var stream = File.OpenRead(filePath);
        var hash = SHA256.HashData(stream);
        var actual = Convert.ToHexString(hash).ToLowerInvariant();
        return string.Equals(actual, cleanExpected, StringComparison.OrdinalIgnoreCase);
    }

    public static bool IsDirectoryWritable(string directoryPath)
    {
        if (string.IsNullOrWhiteSpace(directoryPath) || !Directory.Exists(directoryPath))
            return false;
        var probe = Path.Combine(directoryPath, $".hermes-update-probe-{Guid.NewGuid():N}.tmp");
        try
        {
            using (File.Create(probe)) { }
            File.Delete(probe);
            return true;
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or IOException)
        {
            return false;
        }
    }

    /// Finds the directory inside `extractedDir` that directly contains `HermesHQ.exe`
    /// (supports both flat archives and archives with a single top-level folder).
    public static string ResolveStagedContentRoot(string extractedDir, string exeName = DefaultExeName)
    {
        if (File.Exists(Path.Combine(extractedDir, exeName)))
            return extractedDir;
        var subdirs = Directory.GetDirectories(extractedDir);
        if (subdirs.Length == 1 && File.Exists(Path.Combine(subdirs[0], exeName)))
            return subdirs[0];
        throw new InvalidDataException($"Update archive does not contain {exeName}.");
    }

    /// Generates a self-cleaning PowerShell script that waits for the current HermesHQ process
    /// to exit, copies the staged update over the install folder, relaunches HermesHQ.exe, and
    /// removes the staging directory.
    public static string BuildApplyScript(
        int waitPid,
        string stagedDir,
        string installDir,
        string stagingRoot,
        string exeName = DefaultExeName)
    {
        static string PsQuote(string s) => "'" + s.Replace("'", "''") + "'";

        var sb = new StringBuilder();
        sb.AppendLine("$ErrorActionPreference = 'Stop'");
        sb.AppendLine($"$waitPid = {waitPid}");
        sb.AppendLine($"$stagedDir = {PsQuote(stagedDir)}");
        sb.AppendLine($"$installDir = {PsQuote(installDir)}");
        sb.AppendLine($"$stagingRoot = {PsQuote(stagingRoot)}");
        sb.AppendLine($"$exeName = {PsQuote(exeName)}");
        sb.AppendLine();
        sb.AppendLine("# Wait up to 30 seconds for HermesHQ.exe to exit cleanly");
        sb.AppendLine("for ($i = 0; $i -lt 120; $i++) {");
        sb.AppendLine("    if (-not (Get-Process -Id $waitPid -ErrorAction SilentlyContinue)) { break }");
        sb.AppendLine("    Start-Sleep -Milliseconds 250");
        sb.AppendLine("}");
        sb.AppendLine("Start-Sleep -Milliseconds 350");
        sb.AppendLine();
        sb.AppendLine("# Copy staged files into the install directory with brief retries for releasing handles");
        sb.AppendLine("$copied = $false");
        sb.AppendLine("for ($attempt = 0; $attempt -lt 10 -and -not $copied; $attempt++) {");
        sb.AppendLine("    try {");
        sb.AppendLine("        Copy-Item -Path (Join-Path $stagedDir '*') -Destination $installDir -Recurse -Force");
        sb.AppendLine("        $copied = $true");
        sb.AppendLine("    } catch {");
        sb.AppendLine("        Start-Sleep -Milliseconds 500");
        sb.AppendLine("    }");
        sb.AppendLine("}");
        sb.AppendLine("if (-not $copied) { exit 1 }");
        sb.AppendLine();
        sb.AppendLine("# Relaunch the updated app");
        sb.AppendLine("$exePath = Join-Path $installDir $exeName");
        sb.AppendLine("if (Test-Path $exePath) {");
        sb.AppendLine("    Start-Process -FilePath $exePath -WorkingDirectory $installDir");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("# Clean up temporary staging folder");
        sb.AppendLine("Remove-Item -Path $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue");
        return sb.ToString();
    }

    public static async Task<UpdateCheckResult> CheckForUpdateAsync(
        HttpClient http,
        Version currentVersion,
        Architecture arch,
        string? apiUrl = null,
        CancellationToken ct = default)
    {
        var normalizedCurrent = Normalize(currentVersion);
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, apiUrl ?? DefaultReleasesApiUrl);
            req.Headers.UserAgent.Add(new ProductInfoHeaderValue("HermesHQ-Windows", normalizedCurrent.ToString(3)));
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));

            using var resp = await http.SendAsync(req, HttpCompletionOption.ResponseContentRead, ct);
            if ((int)resp.StatusCode == 404)
                return new UpdateCheckResult(UpdateStatus.UpToDate, normalizedCurrent, null);
            if (!resp.IsSuccessStatusCode)
                return new UpdateCheckResult(UpdateStatus.Failed, normalizedCurrent, null, $"GitHub returned HTTP {(int)resp.StatusCode}.");

            var json = await resp.Content.ReadAsStringAsync(ct);
            var latest = PickLatestRelease(json, arch);
            if (latest == null || !IsNewer(latest.Version, normalizedCurrent))
                return new UpdateCheckResult(UpdateStatus.UpToDate, normalizedCurrent, latest);

            return new UpdateCheckResult(UpdateStatus.UpdateAvailable, normalizedCurrent, latest);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException)
        {
            return new UpdateCheckResult(UpdateStatus.Failed, normalizedCurrent, null, "Couldn’t reach GitHub to check for updates.");
        }
    }

    public static async Task<StagedWindowsUpdate> DownloadAndStageAsync(
        HttpClient http,
        WindowsReleaseInfo release,
        string updatesRoot,
        IProgress<double>? progress = null,
        CancellationToken ct = default)
    {
        var stagingDir = Path.Combine(updatesRoot, release.Version.ToString(3));
        if (Directory.Exists(stagingDir))
            Directory.Delete(stagingDir, recursive: true);
        Directory.CreateDirectory(stagingDir);

        var zipPath = Path.Combine(stagingDir, Path.GetFileName(release.ZipAsset.Name));
        progress?.Report(0.0);

        using (var req = new HttpRequestMessage(HttpMethod.Get, release.ZipAsset.DownloadUrl))
        {
            req.Headers.UserAgent.Add(new ProductInfoHeaderValue("HermesHQ-Windows", release.Version.ToString(3)));
            using var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
            resp.EnsureSuccessStatusCode();

            var totalBytes = resp.Content.Headers.ContentLength ?? release.ZipAsset.SizeBytes;
            await using var remote = await resp.Content.ReadAsStreamAsync(ct);
            await using var local = File.Create(zipPath);
            var buffer = new byte[81920];
            long copied = 0;
            int read;
            while ((read = await remote.ReadAsync(buffer, ct)) > 0)
            {
                await local.WriteAsync(buffer.AsMemory(0, read), ct);
                copied += read;
                if (totalBytes > 0)
                    progress?.Report(Math.Min(0.90, 0.90 * copied / totalBytes));
            }
        }

        if (release.ChecksumsAsset != null)
        {
            progress?.Report(0.92);
            using var sumReq = new HttpRequestMessage(HttpMethod.Get, release.ChecksumsAsset.DownloadUrl);
            sumReq.Headers.UserAgent.Add(new ProductInfoHeaderValue("HermesHQ-Windows", release.Version.ToString(3)));
            using var sumResp = await http.SendAsync(sumReq, HttpCompletionOption.ResponseContentRead, ct);
            sumResp.EnsureSuccessStatusCode();
            var sumsText = await sumResp.Content.ReadAsStringAsync(ct);
            var expected = ParseChecksumForFile(sumsText, release.ZipAsset.Name);
            if (expected == null || !VerifyFileSha256(zipPath, expected))
            {
                try { File.Delete(zipPath); } catch (IOException) { }
                throw new InvalidDataException("Downloaded update failed SHA-256 integrity verification.");
            }
        }

        progress?.Report(0.95);
        var extractDir = Path.Combine(stagingDir, "extracted");
        ZipFile.ExtractToDirectory(zipPath, extractDir, overwriteFiles: true);
        var contentRoot = ResolveStagedContentRoot(extractDir);
        progress?.Report(1.0);
        return new StagedWindowsUpdate(release, contentRoot, stagingDir);
    }
}
