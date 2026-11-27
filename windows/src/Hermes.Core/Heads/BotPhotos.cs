using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Hermes.Core.Model;
using Hermes.Core.Net;

namespace Hermes.Core.Heads;

/// What a profile's avatar is (docs/spec/3x-photoheads.md §4.1, HermesKit/Model/BotPicture.swift): a photo someone chose,
/// the app's own 288 × 288 copy of a saved head (the "mirror"), desktop Hermes' 160 × 160 copy of its own face (the
/// "backfill"), nothing, or something no picture can be made from. Only a photo is drawn; anything else shows the head.
public enum PhotoVerdict { None, Mirror, Backfill, Photo, Unreadable }

public static class BotPicture
{
    public const int MirrorSide = 288;
    public const int BackfillSide = 160;
    /// The app-icon corner: a share of the picture's width, never a circle (owner, 2026-10-02).
    public const double CornerShare = 0.2237;

    public sealed record Classified(PhotoVerdict Verdict, string Fingerprint, byte[]? Bytes = null);

    /// §4.1, in order: none → mirror → backfill → photo → unreadable. The bytes decide, never the label on them.
    public static Classified Classify(bool found, string? dataUrl)
    {
        if (!found || string.IsNullOrEmpty(dataUrl)) return new(PhotoVerdict.None, "");
        if (Bytes(dataUrl) is not { Length: > 0 } bytes) return new(PhotoVerdict.Unreadable, "");
        var print = Fingerprint(bytes);
        if (PngSize(bytes) is { } size)
        {
            if (size.Width == MirrorSide && size.Height == MirrorSide) return new(PhotoVerdict.Mirror, print);
            if (size.Width == BackfillSide && size.Height == BackfillSide) return new(PhotoVerdict.Backfill, print);
        }
        return new(PhotoVerdict.Photo, print, bytes);
    }

    /// The bytes behind `data:<type>;base64,<…>` (or bare base64). Null when not base64.
    public static byte[]? Bytes(string dataUrl)
    {
        var text = dataUrl;
        if (text.StartsWith("data:", StringComparison.Ordinal))
        {
            var comma = text.IndexOf(',');
            if (comma < 0 || !text[..comma].EndsWith(";base64", StringComparison.Ordinal)) return null;
            text = text[(comma + 1)..];
        }
        var clean = new string([.. text.Where(c => char.IsAsciiLetterOrDigit(c) || c is '+' or '/' or '=')]);
        try { return Convert.FromBase64String(clean); } catch (FormatException) { return null; }
    }

    /// The first 16 hex characters of the SHA-256 of the bytes.
    public static string Fingerprint(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes).AsSpan(0, 8));

    /// A PNG's width and height from its IHDR, null when the bytes are not a PNG.
    public static (int Width, int Height)? PngSize(byte[] b)
    {
        byte[] sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        if (b.Length < 24 || !b.AsSpan(0, 8).SequenceEqual(sig)) return null;
        int Int(int at) => b[at] << 24 | b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3];
        return (Int(16), Int(20));
    }
}

/// Which bots wear a photo (spec 3x-photoheads §4.2–4.4, BotPhotoStore.swift, simplified): the roster only says whether a
/// profile has an avatar (`has_avatar`), so each avatar is fetched (`profiles.get_asset`), one at a time and 250 ms apart,
/// and fetched again when the bot's `hermes-bots` or `dispatch-head` revision moves. Kept in memory for this account.
/// A failed fetch changes nothing on screen (a bot always has a head).
public sealed class BotPhotos
{
    public static BotPhotos Shared { get; } = new();

    sealed record Entry(PhotoVerdict Verdict, string Fingerprint, int BotsRevision, int HeadRevision, byte[]? Bytes);

    readonly ConcurrentDictionary<string, Entry> _entries = new();
    readonly ConcurrentDictionary<string, (int Bots, int Head)> _queued = new();
    readonly SemaphoreSlim _pump = new(1, 1);
    RpcCall? _rpc;
    int _epoch;

    /// A bot's photo arrived, changed or went: its name.
    public event Action<string>? Changed;

    /// The signed-in account's gateway, or null at sign-out: nothing of the account before is drawn after this.
    public RpcCall? Rpc
    {
        get => _rpc;
        set
        {
            _rpc = value;
            Interlocked.Increment(ref _epoch);
            _entries.Clear();
            _queued.Clear();
        }
    }

    /// The photo's bytes when the bot wears one.
    public byte[]? Photo(string name) => _entries.TryGetValue(name, out var e) && e.Verdict == PhotoVerdict.Photo ? e.Bytes : null;

    /// A roster row (a face is about to be drawn for it): fetch its avatar when it has one that isn't known yet.
    public void Note(Bot bot)
    {
        var name = bot.Name;
        if (!bot.HasAvatar)
        {
            if (_entries.TryRemove(name, out var old) && old.Verdict == PhotoVerdict.Photo) Announce(name);
            return;
        }
        if (_entries.TryGetValue(name, out var e)
            && (e.BotsRevision < 0 ? e.HeadRevision >= bot.HeadRevision : e.BotsRevision == bot.BotsRevision && e.HeadRevision == bot.HeadRevision))
            return;
        if (_rpc == null || !_queued.TryAdd(name, (bot.BotsRevision, bot.HeadRevision))) return;
        _ = PumpAsync(_epoch);
    }

    /// A head was just saved here: the head replaces a photo at once (its desktop copy follows).
    public void HeadSaved(string name, int headRevision = int.MaxValue)
    {
        var had = Photo(name) != null;
        _entries[name] = new Entry(PhotoVerdict.Mirror, "", -1, headRevision, null);
        if (had) Announce(name);
    }

    void Announce(string name)
    {
        Changed?.Invoke(name);
        HeadStore.NotifyChanged(name);
    }

    async Task PumpAsync(int epoch)
    {
        if (!await _pump.WaitAsync(0)) return;
        try
        {
            while (epoch == _epoch && _rpc is { } rpc && _queued.Keys.FirstOrDefault() is { } name && _queued.TryRemove(name, out var revs))
            {
                try
                {
                    var result = await rpc("profiles.get_asset", new JsonObject { ["name"] = name, ["asset"] = "avatar" },
                        TimeSpan.FromSeconds(30), CancellationToken.None);
                    if (epoch != _epoch) return;
                    var found = result["found"] is JsonValue f && f.TryGetValue(out bool b) && b;
                    var c = BotPicture.Classify(found, result.Str("data"));
                    var before = _entries.TryGetValue(name, out var old) ? old : null;
                    _entries[name] = new Entry(c.Verdict, c.Fingerprint, revs.Bots, revs.Head, c.Bytes);
                    if (before?.Fingerprint != c.Fingerprint || before?.Verdict != c.Verdict) Announce(name);
                }
                catch (Exception e) when (e is GatewayException or OperationCanceledException) { }
                await Task.Delay(250);
            }
        }
        finally { _pump.Release(); }
        if (epoch == _epoch && !_queued.IsEmpty) _ = PumpAsync(epoch);
    }
}
