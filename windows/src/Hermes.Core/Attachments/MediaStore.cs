using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using Hermes.Core.Net;

namespace Hermes.Core.Attachments;

/// One account's chat media on disk (HermesKit/Media/MediaLoader.swift, MediaStore.swift; spec 1x-attachments §8):
/// gateway pictures over GET /api/fs/download with the account's auth (`session_id` only for a relative path), at
/// most 3 downloads at once, written to disk (never buffered in memory) under a ceiling — Largest Attachment for
/// pictures, 512 MB for file previews; https pictures from the public internet only, with no cookies or bearer; your
/// own sends seeded from this PC's copy so the stored row shows the same picture with no download. LRU by bytes, 256 MiB.
public sealed class MediaStore(GatewaySession session, string root)
{
    public const long FileCeiling = 512L << 20;
    public const long MaxTotalBytes = 256L << 20;

    private readonly SemaphoreSlim _slots = new(3, 3);
    private readonly ConcurrentDictionary<string, Lazy<Task<string>>> _flights = new();
    private string AccountKey => session.Account.Key;

    public string Root => root;

    /// The download query (spec §8.2): `session_id` only for a relative path.
    public static List<KeyValuePair<string, string>> DownloadQuery(string path, string profile, string? sessionId)
    {
        var q = new List<KeyValuePair<string, string>> { new("path", path) };
        if (profile.Length > 0) q.Add(new("profile", profile));
        if (!string.IsNullOrEmpty(sessionId) && IsRelative(path)) q.Add(new("session_id", sessionId));
        return q;
    }

    /// Doesn't start with /, ~, file:, \\ or a drive letter.
    public static bool IsRelative(string path)
    {
        if (path.StartsWith('/') || path.StartsWith('~') || path.StartsWith("file:", StringComparison.OrdinalIgnoreCase)
            || path.StartsWith(@"\\")) return false;
        return !(path.Length >= 3 && char.IsAsciiLetter(path[0]) && path[1] == ':' && path[2] is '\\' or '/');
    }

    /// "g|<account>|<profile>|<path>": a gateway path's cache key.
    public string GatewayKey(string profile, string path) => $"g|{AccountKey}|{profile}|{path}";

    private static string Hash(string key) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key))).ToLowerInvariant();

    private string OriginalPath(string key, string name)
    {
        var ext = MediaKinds.Ext(name);
        return Path.Combine(root, "originals", Hash(key) + (ext.Length is > 0 and <= 8 ? "." + ext : ""));
    }

    /// The name a gateway file is kept under (MediaStore.fileName(_:path:)): the name it was opened by, with the path's
    /// own type when that name lacks it. A bot's label ("Demo video" for /…/demo.mp4) or a pin's title otherwise lands
    /// as a file with no type, which nothing opens as a video.
    public static string KeptName(string name, string path)
    {
        var own = MediaKinds.NameOfPath(path, false);
        var trimmed = (name ?? "").Trim();
        if (trimmed.Length == 0) return own;
        var type = MediaKinds.Ext(own);
        if (type.Length == 0 || type.Contains(' ') || MediaKinds.Ext(trimmed) == type) return name!;
        return trimmed + "." + own[(own.LastIndexOf('.') + 1)..];   // the path's own spelling
    }

    private string FilePath(string key, string name) => Path.Combine(root, "files", Hash(key), SafeLocalName(name));

    private static string SafeLocalName(string name)
    {
        var bad = Path.GetInvalidFileNameChars().Concat(['\\', '/', ':', '*', '?', '"', '<', '>', '|']).ToHashSet();
        var s = string.Concat(name.Where(c => !bad.Contains(c) && !char.IsControl(c))).Trim().TrimEnd('.');
        return s.Length == 0 ? "file" : s;
    }

    /// A picture's original on this PC: your own copy, the inline store, the cache, or a download.
    public Task<string> ImageAsync(MessageAttachment a, string profile, string? storedSessionId, CancellationToken ct = default)
    {
        switch (a.Source)
        {
            case AttachmentSource.Local l when File.Exists(l.LocalPath): return Task.FromResult(l.LocalPath);
            case AttachmentSource.Local when a.UploadedPath is { } up: return GatewayImageAsync(up, a.Name, profile, storedSessionId, ct);
            case AttachmentSource.Inline i:
                var inline = InlineMediaStore.PathFor(i.MediaKey);
                return File.Exists(inline) ? Task.FromResult(inline) : Task.FromException<string>(new MediaLoadException(MediaLoadException.Kinds.NotFound));
            case AttachmentSource.Remote r: return RemoteImageAsync(r.Url, ct);
            case AttachmentSource.Gateway g: return GatewayImageAsync(g.Path, a.Name, profile, storedSessionId, ct);
            case AttachmentSource.TooLarge: return Task.FromException<string>(new MediaLoadException(MediaLoadException.Kinds.TooLarge));
            default: return Task.FromException<string>(new MediaLoadException(MediaLoadException.Kinds.Unavailable));
        }
    }

    /// The cached original of a gateway picture, or null (no download).
    public string? CachedImage(string profile, string path)
    {
        var file = OriginalPath(GatewayKey(profile, path), path);
        return File.Exists(file) ? file : null;
    }

    public Task<string> GatewayImageAsync(string path, string name, string profile, string? storedSessionId, CancellationToken ct = default)
    {
        var key = GatewayKey(profile, path);
        var target = OriginalPath(key, path);
        if (File.Exists(target)) { Touch(target); return Task.FromResult(target); }
        return Join(key, () => DownloadAsync(path, profile, storedSessionId, target, AttachmentLimit.Bytes, null, ct));
    }

    /// A file behind a gateway path, downloaded (512 MB ceiling) for a preview or share; progress (received, expected).
    /// `fresh` (MediaLoader.file(fresh:keptOnFailure:)) downloads again even when a copy is kept — a page a bot
    /// rewrites in place — and falls back to the kept copy when that fails, unless `keptOnFailure` is false.
    public async Task<string> GatewayFileAsync(string path, string name, string profile, string? storedSessionId,
        Action<long, long>? progress = null, CancellationToken ct = default, bool fresh = false, bool keptOnFailure = true)
    {
        var key = GatewayKey(profile, path);
        var target = FilePath(key, KeptName(name, path));
        if (fresh && CachedFile(profile, path, name) is { } kept)
        {
            try { return await Join("f|" + key, () => DownloadAsync(path, profile, storedSessionId, target, FileCeiling, progress, ct)); }
            catch (OperationCanceledException) { throw; }
            catch (MediaLoadException) when (keptOnFailure) { return kept; }   // the download left the kept copy whole
        }
        if (CachedFile(profile, path, name) is { } hit) { Touch(hit); return hit; }
        return await Join("f|" + key, () => DownloadAsync(path, profile, storedSessionId, target, FileCeiling, progress, ct));
    }

    /// The kept copy of a gateway file (a picture's original serves too), or null; no download.
    public string? CachedFile(string profile, string path, string name)
    {
        var target = FilePath(GatewayKey(profile, path), KeptName(name, path));
        return File.Exists(target) ? target : CachedImage(profile, path);
    }

    /// A page card's picture's read (PageSnapshots.read): the page from the bot's computer again, since the bot may
    /// have rewritten it; null when it's gone from the gateway; the kept copy when the read fails for any other reason
    /// (null with none).
    public async Task<string?> PagePictureFileAsync(string path, string name, string profile, string? storedSessionId,
        CancellationToken ct = default)
    {
        try { return await GatewayFileAsync(path, name, profile, storedSessionId, null, ct, fresh: true, keptOnFailure: false); }
        catch (MediaLoadException e) when (e.Kind == MediaLoadException.Kinds.NotFound) { return null; }
        catch (MediaLoadException) { return CachedFile(profile, path, name); }
    }

    private Task<string> Join(string key, Func<Task<string>> make)
    {
        var flight = _flights.GetOrAdd(key, _ => new Lazy<Task<string>>(async () =>
        {
            try { return await make(); }
            finally { _flights.TryRemove(key, out Lazy<Task<string>>? _); }
        }));
        return flight.Value;
    }

    private async Task<string> DownloadAsync(string path, string profile, string? sessionId, string target, long ceiling,
        Action<long, long>? progress, CancellationToken ct)
    {
        await _slots.WaitAsync(ct);
        try
        {
            await session.DownloadToFileAsync("/api/fs/download", DownloadQuery(path, profile, sessionId), target, ceiling, progress, ct);
            Trim();
            return target;
        }
        catch (GatewayException e) { throw Map(e); }
        finally { _slots.Release(); }
    }

    public static MediaLoadException Map(GatewayException e) => new(e.Code switch
    {
        "too-large" => MediaLoadException.Kinds.TooLarge,
        "http" => e.Status switch
        {
            404 or 400 or 409 => MediaLoadException.Kinds.NotFound,
            403 => MediaLoadException.Kinds.Forbidden,
            _ => MediaLoadException.Kinds.Unreachable,
        },
        _ => MediaLoadException.Kinds.Unreachable,
    });

    /// Your sent picture or file goes in under its gateway path (spec §6.4 step 7), so the stored row finds it at once.
    public void Seed(string profile, string gatewayPath, string localFile, string name, bool image)
    {
        var key = GatewayKey(profile, gatewayPath);
        var target = image ? OriginalPath(key, gatewayPath) : FilePath(key, name);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(localFile, target, overwrite: true);
            Trim();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    public void Purge()
    {
        try { Directory.Delete(root, recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private static void Touch(string file)
    {
        try { File.SetLastAccessTimeUtc(file, DateTime.UtcNow); File.SetLastWriteTimeUtc(file, DateTime.UtcNow); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// Least recently used first, until the store is under 256 MiB.
    private void Trim()
    {
        try
        {
            if (!Directory.Exists(root)) return;
            var files = new DirectoryInfo(root).EnumerateFiles("*", SearchOption.AllDirectories)
                .Where(f => !f.Name.EndsWith(".partial")).OrderByDescending(f => f.LastWriteTimeUtc).ToList();
            long total = 0;
            foreach (var f in files)
            {
                total += f.Length;
                if (total > MaxTotalBytes) f.Delete();
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    // ------------------------------------------------------------------ remote https pictures (spec §8.4)

    private static readonly HttpClient Public = new(new SocketsHttpHandler
    {
        UseCookies = false, AllowAutoRedirect = false, Credentials = null, MaxConnectionsPerServer = 4,
        ConnectTimeout = TimeSpan.FromSeconds(20),
    }) { Timeout = TimeSpan.FromSeconds(60) };

    private async Task<string> RemoteImageAsync(Uri url, CancellationToken ct)
    {
        var key = "r|" + url.AbsoluteUri;
        var target = OriginalPath(key, url.AbsolutePath);
        if (File.Exists(target)) return target;
        return await Join(key, async () =>
        {
            var current = url;
            for (var hop = 0; hop <= 5; hop++)
            {
                if (!await IsPublicAsync(current, ct)) throw new MediaLoadException(MediaLoadException.Kinds.Forbidden);
                using var req = new HttpRequestMessage(HttpMethod.Get, current);
                req.Headers.Accept.ParseAdd("image/*");
                using var res = await Public.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
                if ((int)res.StatusCode is >= 300 and < 400 && res.Headers.Location is { } next)
                {
                    current = next.IsAbsoluteUri ? next : new Uri(current, next);
                    continue;
                }
                if (!res.IsSuccessStatusCode) throw new MediaLoadException(MediaLoadException.Kinds.NotFound);
                var type = res.Content.Headers.ContentType?.MediaType ?? "";
                if (!type.StartsWith("image/") || type == "image/svg+xml") throw new MediaLoadException(MediaLoadException.Kinds.NotImage);
                if (res.Content.Headers.ContentLength > InlineMediaStore.MaxBytes) throw new MediaLoadException(MediaLoadException.Kinds.TooLarge);
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                var partial = target + ".partial";
                await using (var input = await res.Content.ReadAsStreamAsync(ct))
                await using (var output = File.Create(partial))
                {
                    var buffer = new byte[64 * 1024];
                    long got = 0;
                    int n;
                    while ((n = await input.ReadAsync(buffer, ct)) > 0)
                    {
                        got += n;
                        if (got > InlineMediaStore.MaxBytes) throw new MediaLoadException(MediaLoadException.Kinds.TooLarge);
                        await output.WriteAsync(buffer.AsMemory(0, n), ct);
                    }
                }
                File.Move(partial, target, overwrite: true);
                return target;
            }
            throw new MediaLoadException(MediaLoadException.Kinds.Unreachable);
        });
    }

    /// https only, and a host that resolves only to public addresses (no loopback, private, link-local, CGNAT —
    /// Tailscale —, unique-local, .local or .ts.net): nothing in a message makes this PC fetch a LAN address.
    public static async Task<bool> IsPublicAsync(Uri url, CancellationToken ct = default)
    {
        if (url.Scheme != "https") return false;
        var host = url.IdnHost.TrimEnd('.').ToLowerInvariant();
        if (host is "localhost" || host.EndsWith(".local") || host.EndsWith(".ts.net") || host.EndsWith(".localhost")) return false;
        IPAddress[] addresses;
        if (IPAddress.TryParse(host.Trim('[', ']'), out var literal)) addresses = [literal];
        else
        {
            try { addresses = await Dns.GetHostAddressesAsync(host, ct); }
            catch (SocketException) { return false; }
        }
        return addresses.Length > 0 && addresses.All(IsPublicAddress);
    }

    public static bool IsPublicAddress(IPAddress ip)
    {
        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
        if (IPAddress.IsLoopback(ip)) return false;
        var b = ip.GetAddressBytes();
        if (ip.AddressFamily == AddressFamily.InterNetwork)
            return !(b[0] == 10 || b[0] == 0 || (b[0] == 172 && b[1] is >= 16 and <= 31) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && b[1] is >= 64 and <= 127) || b[0] >= 224);
        return !(ip.IsIPv6LinkLocal || ip.IsIPv6SiteLocal || ip.IsIPv6Multicast || (b[0] & 0xFE) == 0xFC
            || ip.Equals(IPAddress.IPv6None) || ip.Equals(IPAddress.IPv6Any));
    }
}
