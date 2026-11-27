// Watch Browser's last page: the C# twin of HermesKit/Browser/BrowserLastPage.swift (the owner, 2026-11-16: "once it
// was done, I couldn't see it anymore"). A bot's browser closes when the bot is done with it, and the viewer used to go
// blank. The viewer keeps the last frame it drew for each bot and shows it, still, with the time, until that bot opens
// a browser again. One picture per bot, under the account's key; sign-out deletes the account's pictures. Only frames
// this device was shown are kept: nothing is fetched for it.
//
// Windows has no per-file protection class like iOS's, so a picture reaches disk only through an
// IBrowserLastPageProtector (the app's is DPAPI, current user). With none, pictures stay in memory: never plain on disk.
// Nothing here logs: page addresses and titles never reach the diagnostic log.

using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Hermes.Core.Browser;

/// The last page a bot's browser showed on this device: the frame's JPEG as the add-on sent it, the page's size, and
/// where it was.
public sealed class BrowserLastPage : IEquatable<BrowserLastPage>
{
    /// BrowserWire.maxFrameImage: a frame's picture is at most this many bytes.
    public const int MaxImage = 4 * 1024 * 1024;

    /// A last page is kept this long; an older one is deleted on read.
    public static readonly TimeSpan KeptFor = TimeSpan.FromDays(7);

    /// How far ahead of this device's clock a page's time is still believed.
    public static readonly TimeSpan ClockAhead = TimeSpan.FromSeconds(60);

    [JsonConstructor]
    public BrowserLastPage(byte[] jpeg, double width, double height, string? url, string? title, string? sessionId,
                           DateTimeOffset at)
    {
        Jpeg = jpeg ?? [];
        Width = width;
        Height = height;
        Url = url;
        Title = title;
        SessionId = sessionId;
        At = at;
    }

    public byte[] Jpeg { get; }
    public double Width { get; }
    public double Height { get; }
    public string? Url { get; }
    public string? Title { get; }
    /// The chat that drove the browser (`BrowserRow.driver`): a chat-only viewer shows only its own chat's page.
    public string? SessionId { get; }
    /// When the frame was drawn.
    public DateTimeOffset At { get; }

    /// The site, as the address field says it ("shop.example.com"); empty for no address.
    [JsonIgnore]
    public string Host => BrowserLastPageAddress.Host(Url);

    public bool Fresh(DateTimeOffset now) => now - At < KeptFor && At <= now + ClockAhead;

    /// Whether a viewer shows it: the bot's own viewer any page of the bot; another chat of the bot (`chatOnly`) only
    /// a page that chat drove.
    public bool Fits(bool chatOnly, IEnumerable<string> sessionIds)
    {
        if (!chatOnly) return true;
        if (string.IsNullOrEmpty(SessionId)) return false;
        return sessionIds.Contains(SessionId, StringComparer.Ordinal);
    }

    /// The words under the page: "Ivy’s browser has closed. This is the last page it showed, at 9:01 PM."
    /// The day is `zone`'s (the viewer's), the time in `culture`'s short form.
    public static string Caption(string name, DateTimeOffset at, DateTimeOffset now, TimeZoneInfo? zone = null,
                                 CultureInfo? culture = null)
    {
        zone ??= TimeZoneInfo.Local;
        culture ??= CultureInfo.CurrentCulture;
        var local = TimeZoneInfo.ConvertTime(at, zone);
        var today = TimeZoneInfo.ConvertTime(now, zone).Date;
        var time = local.ToString(culture.DateTimeFormat.ShortTimePattern, culture);
        string when;
        if (local.Date == today) when = $"at {time}";
        else if (local.Date == today.AddDays(-1)) when = $"yesterday at {time}";
        else when = $"on {local.ToString("MMM d, yyyy", culture)} at {time}";
        return $"{name}’s browser has closed. This is the last page it showed, {when}.";
    }

    /// The "no browser" states the last page takes the place of: the bot has no browser open and none is on its way.
    /// `ownStatus` is the bot's own browser status from `/bots` (null: not known yet, or an older add-on). A browser
    /// starting or not answering keeps its own words (it shows live in a moment), and so does an add-on that is
    /// switched off (its button is the next step).
    public static bool Replaces(string? ownStatus) =>
        ownStatus is null || !KeepsOwnWords.Contains(ownStatus);

    private static readonly HashSet<string> KeepsOwnWords =
        new(StringComparer.Ordinal) { "ready", "starting", "external", "unknown", "not_responding", "off" };

    public bool Equals(BrowserLastPage? other) =>
        other is not null && Jpeg.AsSpan().SequenceEqual(other.Jpeg) && Width.Equals(other.Width) &&
        Height.Equals(other.Height) && Url == other.Url && Title == other.Title && SessionId == other.SessionId &&
        At.Equals(other.At);

    public override bool Equals(object? obj) => Equals(obj as BrowserLastPage);
    public override int GetHashCode() => HashCode.Combine(Jpeg.Length, Width, Height, Url, Title, SessionId, At);
}

/// The address field's site for a page (BrowserAddress.host): "www." dropped, a port kept, data/blob a local page,
/// about:blank a new tab.
public static class BrowserLastPageAddress
{
    public static string Host(string? url)
    {
        if (string.IsNullOrEmpty(url)) return "";
        var colon = url.IndexOf(':');
        if (colon <= 0 || !IsScheme(url[..colon])) return Prefix(url);
        var scheme = url[..colon].ToLowerInvariant();
        switch (scheme)
        {
            case "data":
            case "blob": return "Local page";
            case "about": return url == "about:blank" ? "New Tab" : Prefix(url);
        }
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.IdnHost)) return Prefix(url);
        var host = uri.Host;
        if (host.StartsWith("www.", StringComparison.Ordinal)) host = host[4..];
        if (!uri.IsDefaultPort || HasExplicitPort(url)) host += ":" + uri.Port.ToString(CultureInfo.InvariantCulture);
        return host.Length == 0 ? Prefix(url) : host;
    }

    private static bool IsScheme(string s) =>
        char.IsAsciiLetter(s[0]) && s.All(c => char.IsAsciiLetterOrDigit(c) || c is '+' or '-' or '.');

    // URLComponents keeps a port that was written even when it is the scheme's default ("https://x:443").
    private static bool HasExplicitPort(string url)
    {
        var start = url.IndexOf("//", StringComparison.Ordinal);
        if (start < 0) return false;
        var rest = url[(start + 2)..];
        var end = rest.IndexOfAny(['/', '?', '#']);
        var authority = end < 0 ? rest : rest[..end];
        var at = authority.LastIndexOf('@');
        if (at >= 0) authority = authority[(at + 1)..];
        var close = authority.LastIndexOf(']');
        var portColon = authority.LastIndexOf(':');
        return portColon > close && portColon < authority.Length - 1;
    }

    private static string Prefix(string url) => url.Length <= 80 ? url : url[..80];
}

/// Seals a last page's bytes before they reach disk and opens them again. The app's is DPAPI (current user); tests use
/// a stand-in. Unprotect returns null for bytes it can't open (another user, a damaged file).
public interface IBrowserLastPageProtector
{
    byte[] Protect(byte[] plain);
    byte[]? Unprotect(byte[] stored);
}

/// The kept pictures, one per bot of each account. Thread-safe. Disk writes go to one serial background queue, at most
/// one per bot every `writeEvery` while frames arrive, and at once on `Flush` (the browser closed, the viewer left).
public sealed class BrowserLastPages
{
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private readonly string _folder;
    private readonly IBrowserLastPageProtector? _protector;
    private readonly TimeSpan _writeEvery;
    private readonly object _gate = new();
    private readonly Dictionary<string, BrowserLastPage> _memory = new(StringComparer.Ordinal);
    private readonly HashSet<string> _dirty = new(StringComparer.Ordinal);
    private readonly Dictionary<string, CancellationTokenSource> _writers = new(StringComparer.Ordinal);
    private readonly object _diskGate = new();
    private Task _disk = Task.CompletedTask;
    /// Bumped by every forget and purge: a disk read that started before one must not bring a picture back.
    private long _epoch;

    /// `folder`: the cache folder ("browser-last-page" under the app's local cache). `protector`: null keeps pictures
    /// in memory only.
    public BrowserLastPages(string folder, IBrowserLastPageProtector? protector, TimeSpan? writeEvery = null)
    {
        _folder = folder;
        _protector = protector;
        _writeEvery = writeEvery ?? TimeSpan.FromSeconds(3);
    }

    /// Whether pictures outlive the app (a protector is there).
    public bool Durable => _protector is not null;

    /// The first 24 hex digits of SHA-256(UTF-8 text): a file or folder name that says nothing of the account or bot.
    public static string Key(string text) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)))[..24];

    private string AccountFolder(string account) => Path.Combine(_folder, Key(account));
    private string FilePath(string account, string profile) => Path.Combine(AccountFolder(account), Key(profile) + ".json");
    private static string Slot(string account, string profile) => account + "\u001F" + profile;

    /// The newest frame of `profile`'s browser: kept in memory now, on disk shortly.
    public void Keep(BrowserLastPage page, string account, string profile)
    {
        if (string.IsNullOrEmpty(account) || string.IsNullOrEmpty(profile) || page.Jpeg.Length == 0 ||
            page.Jpeg.Length > BrowserLastPage.MaxImage) return;
        var slot = Slot(account, profile);
        lock (_gate)
        {
            _memory[slot] = page;
            _dirty.Add(slot);
            if (_writers.ContainsKey(slot)) return;
            var cts = new CancellationTokenSource();
            _writers[slot] = cts;
            _ = WriteLater(account, profile, slot, cts);
        }
    }

    private async Task WriteLater(string account, string profile, string slot, CancellationTokenSource mine)
    {
        try { await Task.Delay(_writeEvery, mine.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) { return; }
        lock (_gate)
        {
            // A flush, forget or purge since then took this writer's place: it has nothing left to do.
            if (!_writers.TryGetValue(slot, out var current) || !ReferenceEquals(current, mine)) return;
            _writers.Remove(slot);
            WriteLocked(account, profile, slot);
        }
        mine.Dispose();
    }

    /// Writes `profile`'s page now if a newer one waits (the browser closed, or the viewer is leaving).
    public void Flush(string account, string profile)
    {
        var slot = Slot(account, profile);
        lock (_gate)
        {
            CancelWriterLocked(slot);
            WriteLocked(account, profile, slot);
        }
    }

    private void WriteLocked(string account, string profile, string slot)
    {
        if (!_dirty.Remove(slot) || !_memory.TryGetValue(slot, out var page)) return;
        if (_protector is null) return; // memory only: nothing plain on disk
        var path = FilePath(account, profile);
        var protector = _protector;
        Enqueue(() =>
        {
            byte[] sealedBytes;
            try { sealedBytes = protector.Protect(JsonSerializer.SerializeToUtf8Bytes(page, Json)); }
            catch (Exception) { return; } // no protection now: the picture stays in memory
            var dir = Path.GetDirectoryName(path)!;
            Directory.CreateDirectory(dir);
            var temp = Path.Combine(dir, "." + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                File.WriteAllBytes(temp, sealedBytes);
                File.Move(temp, path, overwrite: true);
            }
            finally
            {
                if (File.Exists(temp)) File.Delete(temp);
            }
        });
    }

    /// `profile`'s last page, if one is kept and not older than a week.
    public BrowserLastPage? Page(string account, string profile, DateTimeOffset? now = null)
    {
        if (string.IsNullOrEmpty(account) || string.IsNullOrEmpty(profile)) return null;
        var at = now ?? DateTimeOffset.UtcNow;
        var slot = Slot(account, profile);
        lock (_gate)
        {
            if (_memory.TryGetValue(slot, out var kept))
            {
                if (kept.Fresh(at)) return kept;
                ForgetLocked(account, profile, slot);
                return null;
            }
        }
        if (_protector is null) return null;
        long epoch;
        lock (_gate) epoch = _epoch;
        var path = FilePath(account, profile);
        byte[]? stored = null;
        Enqueue(() => { stored = File.Exists(path) ? File.ReadAllBytes(path) : null; }).Wait();
        var page = Decode(stored);
        if (page is null) return null;
        lock (_gate)
        {
            // A newer frame arrived, or the account signed out, while the file was read: memory is the truth.
            if (_memory.TryGetValue(slot, out var newer)) return newer.Fresh(at) ? newer : null;
            if (_epoch != epoch) return null;
            if (!page.Fresh(at))
            {
                ForgetLocked(account, profile, slot);
                return null;
            }
            _memory[slot] = page;
            return page;
        }
    }

    private BrowserLastPage? Decode(byte[]? stored)
    {
        if (stored is null || _protector is null) return null;
        try
        {
            var plain = _protector.Unprotect(stored);
            if (plain is null) return null;
            var page = JsonSerializer.Deserialize<BrowserLastPage>(plain, Json);
            return page is { Jpeg.Length: > 0 and <= BrowserLastPage.MaxImage } ? page : null;
        }
        catch (Exception) { return null; }
    }

    private void ForgetLocked(string account, string profile, string slot)
    {
        _epoch++;
        _memory.Remove(slot);
        _dirty.Remove(slot);
        CancelWriterLocked(slot);
        var path = FilePath(account, profile);
        Enqueue(() => { if (File.Exists(path)) File.Delete(path); });
    }

    /// Sign-out: every picture of the account goes, in memory at once and on disk after any write already queued.
    public void Purge(string account)
    {
        if (string.IsNullOrEmpty(account)) return;
        var prefix = account + "\u001F";
        lock (_gate)
        {
            _epoch++;
            foreach (var slot in _memory.Keys.Concat(_writers.Keys).Concat(_dirty)
                         .Where(s => s.StartsWith(prefix, StringComparison.Ordinal)).ToList())
            {
                _memory.Remove(slot);
                _dirty.Remove(slot);
                CancelWriterLocked(slot);
            }
            var dir = AccountFolder(account);
            Enqueue(() => { if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true); });
        }
    }

    private void CancelWriterLocked(string slot)
    {
        if (!_writers.Remove(slot, out var cts)) return;
        cts.Cancel();
        cts.Dispose();
    }

    /// One serial disk queue: writes, reads and deletes happen in the order they were asked for.
    private Task Enqueue(Action work)
    {
        lock (_diskGate)
        {
            _disk = _disk.ContinueWith(_ =>
            {
                try { work(); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }, CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
            return _disk;
        }
    }

    /// Tests: wait for the disk queue.
    internal void DebugDrain()
    {
        Task last;
        lock (_diskGate) last = _disk;
        last.Wait();
    }

    /// Tests: a relaunched app (memory empty, disk as it is).
    internal void DebugForgetMemory()
    {
        lock (_gate) _memory.Clear();
    }
}
