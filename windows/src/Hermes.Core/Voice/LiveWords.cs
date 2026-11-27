using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Voice;

// Port of HermesKit/Voice/LiveWords.swift, LiveWordsTidy.swift, and GatewayWords.swift:
// live incremental speech transcription (on-device Windows Speech or streaming gateway STT),
// filler/punctuation tidying, phonetic WordFixes lesson learning, and gateway streaming STT framing.

public enum LiveWordsSource { None, Device, Gateway }

public enum LiveWordsReadiness { Unavailable, NeedsDownload, Ready }

/// Live transcription state: settled words (committed) + pending hypothesis (still changing).
public sealed record LiveWordsText(string Settled, string Pending)
{
    public static readonly LiveWordsText Empty = new("", "");

    public string Text => string.IsNullOrWhiteSpace(Settled) ? Pending.Trim()
        : string.IsNullOrWhiteSpace(Pending) ? Settled.Trim()
        : $"{Settled.Trim()} {Pending.Trim()}";

    public bool IsEmpty => string.IsNullOrWhiteSpace(Settled) && string.IsNullOrWhiteSpace(Pending);
}

/// Platform or gateway live-word listener fed PCM audio (or running its own mic session).
public interface ILiveWordsListening
{
    LiveWordsSource Source { get; }
    bool IsAvailable { get; }
    event Action<LiveWordsText>? Changed;

    Task<bool> StartAsync(CancellationToken ct = default);
    void FeedPcm(ReadOnlySpan<short> pcm, int sampleRate);
    Task<string> FinishAsync(CancellationToken ct = default);
    void Cancel();
}

// MARK: - Phonetic key (Metaphone-inspired ASCII key for WordFixes matching)

public static class Phonetic
{
    private static readonly Regex NonLetters = new(@"[^a-z]", RegexOptions.CultureInvariant);

    /// Produces a compact phonetic key for English/technical words so "her meez" / "hermies" matches "Hermes".
    public static string Key(string word)
    {
        if (string.IsNullOrWhiteSpace(word)) return "";
        var clean = NonLetters.Replace(word.ToLowerInvariant(), "");
        if (clean.Length == 0) return "";
        if (clean.Length <= 2) return clean;

        var sb = new StringBuilder(clean.Length);
        var i = 0;
        // Silent leading pairs
        if (clean.StartsWith("kn", StringComparison.Ordinal) || clean.StartsWith("gn", StringComparison.Ordinal)
            || clean.StartsWith("pn", StringComparison.Ordinal) || clean.StartsWith("wr", StringComparison.Ordinal))
            i = 1;
        else if (clean.StartsWith("wh", StringComparison.Ordinal))
        {
            sb.Append('w');
            i = 2;
        }
        else if (clean[0] == 'x')
        {
            sb.Append('s');
            i = 1;
        }

        var prev = '\0';
        for (; i < clean.Length; i++)
        {
            var c = clean[i];
            var next = i + 1 < clean.Length ? clean[i + 1] : '\0';
            if (c == prev && c != 'c') continue;
            prev = c;

            switch (c)
            {
                case 'a' or 'e' or 'i' or 'o' or 'u':
                    if (sb.Length == 0) sb.Append(c);
                    break;
                case 'b':
                    if (!(i == clean.Length - 1 && i > 0 && clean[i - 1] == 'm')) sb.Append('b');
                    break;
                case 'c':
                    if (next == 'h') { sb.Append('x'); i++; }
                    else if (next is 'i' or 'e' or 'y') sb.Append('s');
                    else sb.Append('k');
                    break;
                case 'd':
                    if (next == 'g' && i + 2 < clean.Length && clean[i + 2] is 'e' or 'i' or 'y') { sb.Append('j'); i++; }
                    else sb.Append('t');
                    break;
                case 'f': sb.Append('f'); break;
                case 'g':
                    if (next == 'h') { i++; }
                    else if (next is 'e' or 'i' or 'y') sb.Append('j');
                    else sb.Append('k');
                    break;
                case 'h':
                    if (sb.Length == 0 || (next is 'a' or 'e' or 'i' or 'o' or 'u')) sb.Append('h');
                    break;
                case 'j': sb.Append('j'); break;
                case 'k': sb.Append('k'); break;
                case 'l': sb.Append('l'); break;
                case 'm': sb.Append('m'); break;
                case 'n': sb.Append('n'); break;
                case 'p':
                    if (next == 'h') { sb.Append('f'); i++; }
                    else sb.Append('p');
                    break;
                case 'q': sb.Append('k'); break;
                case 'r': sb.Append('r'); break;
                case 's':
                    if (next == 'h') { sb.Append('x'); i++; }
                    else sb.Append('s');
                    break;
                case 't':
                    if (next == 'h') { sb.Append('0'); i++; }
                    else sb.Append('t');
                    break;
                case 'v': sb.Append('f'); break;
                case 'w':
                    if (next is 'a' or 'e' or 'i' or 'o' or 'u') sb.Append('w');
                    break;
                case 'x': sb.Append("ks"); break;
                case 'y':
                    if (next is 'a' or 'e' or 'i' or 'o' or 'u') sb.Append('y');
                    break;
                case 'z': sb.Append('s'); break;
            }
        }
        return sb.Length > 0 ? sb.ToString() : clean;
    }
}

// MARK: - WordFixes (learns user edits in memo review and applies them to future live words)

public sealed record WordFix(
    [property: JsonPropertyName("heard")] string Heard,
    [property: JsonPropertyName("meant")] string Meant,
    [property: JsonPropertyName("uses")] int Uses = 1,
    [property: JsonPropertyName("at")] double LastUsed = 0);

public sealed class WordFixes
{
    public const string StorageKey = "hq.voice.wordFixes";
    public const int Cap = 120;

    private static readonly Regex TokenRe = new(@"[A-Za-z0-9']+|\s+|[^\sA-Za-z0-9']+", RegexOptions.CultureInvariant);

    private readonly IPreferences? _prefs;
    private readonly List<WordFix> _entries = [];
    private readonly object _gate = new();

    public WordFixes(IPreferences? prefs = null)
    {
        _prefs = prefs;
        Load();
    }

    public IReadOnlyList<WordFix> Entries { get { lock (_gate) return [.. _entries]; } }

    /// Compares what Live Words heard against what the user fixed it to, learning single-word substitutions
    /// that share a plausible phonetic or prefix similarity.
    public int Learn(string heard, string meant)
    {
        var a = Words(heard);
        var b = Words(meant);
        if (a.Count == 0 || a.Count != b.Count) return 0;

        var learned = 0;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        lock (_gate)
        {
            for (var i = 0; i < a.Count; i++)
            {
                var h = a[i];
                var m = b[i];
                if (string.Equals(h, m, StringComparison.Ordinal)) continue;
                if (h.Length < 2 || m.Length < 2) continue;
                // Only learn when the correction sounds similar or differs only in casing/spelling.
                var sameCase = string.Equals(h, m, StringComparison.OrdinalIgnoreCase);
                var samePhone = Phonetic.Key(h) == Phonetic.Key(m);
                var closeEdit = EditDistance(h.ToLowerInvariant(), m.ToLowerInvariant()) <= Math.Max(2, h.Length / 2);
                if (!sameCase && !samePhone && !closeEdit) continue;

                var idx = _entries.FindIndex(e => string.Equals(e.Heard, h, StringComparison.OrdinalIgnoreCase));
                if (idx >= 0)
                {
                    var old = _entries[idx];
                    _entries[idx] = new WordFix(h.ToLowerInvariant(), m, old.Uses + 1, now);
                }
                else
                {
                    _entries.Add(new WordFix(h.ToLowerInvariant(), m, 1, now));
                }
                learned++;
            }
            if (learned > 0)
            {
                if (_entries.Count > Cap)
                    _entries.Sort((x, y) => y.LastUsed.CompareTo(x.LastUsed));
                if (_entries.Count > Cap) _entries.RemoveRange(Cap, _entries.Count - Cap);
                SaveLocked();
            }
        }
        return learned;
    }

    public string Apply(string text)
    {
        if (string.IsNullOrEmpty(text)) return text;
        List<WordFix> snapshot;
        lock (_gate)
        {
            if (_entries.Count == 0) return text;
            snapshot = [.. _entries];
        }
        var byExact = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var e in snapshot) byExact[e.Heard] = e.Meant;

        return TokenRe.Replace(text, m =>
        {
            var tok = m.Value;
            if (byExact.TryGetValue(tok, out var replacement)) return replacement;
            return tok;
        });
    }

    public void Clear()
    {
        lock (_gate)
        {
            _entries.Clear();
            _prefs?.Set(StorageKey, null);
        }
    }

    private void Load()
    {
        var raw = _prefs?.Get(StorageKey);
        if (string.IsNullOrWhiteSpace(raw)) return;
        try
        {
            var items = JsonSerializer.Deserialize<List<WordFix>>(raw);
            if (items != null)
            {
                lock (_gate)
                {
                    _entries.Clear();
                    _entries.AddRange(items.Where(e => !string.IsNullOrWhiteSpace(e.Heard) && !string.IsNullOrWhiteSpace(e.Meant)).Take(Cap));
                }
            }
        }
        catch (JsonException) { }
    }

    private void SaveLocked()
    {
        if (_prefs == null) return;
        try { _prefs.Set(StorageKey, JsonSerializer.Serialize(_entries)); }
        catch (JsonException) { }
    }

    private static List<string> Words(string s) =>
        Regex.Matches(s, @"[A-Za-z0-9']+").Select(m => m.Value).ToList();

    internal static int EditDistance(string a, string b)
    {
        var prev = new int[b.Length + 1];
        var curr = new int[b.Length + 1];
        for (var j = 0; j <= b.Length; j++) prev[j] = j;
        for (var i = 1; i <= a.Length; i++)
        {
            curr[0] = i;
            for (var j = 1; j <= b.Length; j++)
            {
                var cost = a[i - 1] == b[j - 1] ? 0 : 1;
                curr[j] = Math.Min(Math.Min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
            }
            (prev, curr) = (curr, prev);
        }
        return prev[b.Length];
    }
}

// MARK: - LiveWordsTidy (filler stripping, stutter dedup, spacing, capitalization)

public static class LiveWordsTidy
{
    private static readonly Regex LeadingFiller = new(@"^(?:(?:uh+|um+|er+|ah+|hmm+|mm+)(?:[,.\s]+|$))+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex InnerFiller = new(@"(?<=\s)(?:uh+|um+|er+|hmm+)(?:,)?(?=\s)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex SpaceBeforePunct = new(@"\s+([,.;:!?])", RegexOptions.CultureInvariant);
    private static readonly Regex MultiSpace = new(@"\s{2,}", RegexOptions.CultureInvariant);
    private static readonly Regex Stutter = new(@"\b(\w+)\s+\1\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static string Tidy(string raw, WordFixes? fixes = null)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "";
        var s = raw.Trim();
        s = LeadingFiller.Replace(s, "");
        s = InnerFiller.Replace(s, "");
        s = Stutter.Replace(s, "$1");
        s = SpaceBeforePunct.Replace(s, "$1");
        s = MultiSpace.Replace(s, " ").Trim();
        if (fixes != null && s.Length > 0) s = fixes.Apply(s);
        if (s.Length > 0 && char.IsLower(s[0])) s = char.ToUpperInvariant(s[0]) + s[1..];
        return s;
    }

    public static LiveWordsText Tidy(LiveWordsText text, WordFixes? fixes = null) =>
        new(Tidy(text.Settled, fixes), fixes != null ? fixes.Apply(text.Pending.Trim()) : text.Pending.Trim());
}

/// Wraps any ILiveWordsListening with LiveWordsTidy + WordFixes.
public sealed class TidiedLiveWords : ILiveWordsListening
{
    private readonly ILiveWordsListening _inner;
    private readonly WordFixes? _fixes;

    public TidiedLiveWords(ILiveWordsListening inner, WordFixes? fixes = null)
    {
        _inner = inner;
        _fixes = fixes;
        _inner.Changed += t => Changed?.Invoke(LiveWordsTidy.Tidy(t, _fixes));
    }

    public LiveWordsSource Source => _inner.Source;
    public bool IsAvailable => _inner.IsAvailable;
    public event Action<LiveWordsText>? Changed;

    public Task<bool> StartAsync(CancellationToken ct = default) => _inner.StartAsync(ct);
    public void FeedPcm(ReadOnlySpan<short> pcm, int sampleRate) => _inner.FeedPcm(pcm, sampleRate);

    public async Task<string> FinishAsync(CancellationToken ct = default) =>
        LiveWordsTidy.Tidy(await _inner.FinishAsync(ct), _fixes);

    public void Cancel() => _inner.Cancel();
}

// MARK: - Gateway streaming live words (GatewayWords.swift)

public enum GatewayWordsStop { Done, Cancel, Silence, Error }

public sealed record GatewayWordsOutcome(string Text, GatewayWordsStop Stop, string? Error = null);

public abstract record GatewayWordsFrame
{
    public sealed record Ready : GatewayWordsFrame;
    public sealed record Partial(string Text) : GatewayWordsFrame;
    public sealed record Final(string Text) : GatewayWordsFrame;
    public sealed record Error(string Message) : GatewayWordsFrame;
    public sealed record Closed(string? Reason) : GatewayWordsFrame;
}

public interface IGatewayWordsSocket : IAsyncDisposable
{
    event Action<GatewayWordsFrame>? FrameReceived;
    Task ConnectAsync(Uri url, string? cookieHeader, string? bearerToken, CancellationToken ct = default);
    Task SendTextAsync(string json, CancellationToken ct = default);
    Task SendBinaryAsync(ReadOnlyMemory<byte> pcm, CancellationToken ct = default);
    Task CloseAsync(CancellationToken ct = default);
}

public static class GatewayWordsWire
{
    public const string SocketPath = "/api/audio/live-stt";

    /// Whether `/api/config` advertises streaming live STT.
    public static bool Offered(JsonNode? config)
    {
        if (config == null) return false;
        var stt = config.Get("stt");
        if (stt.Bool("enabled") == false) return false;
        return stt.Bool("streaming") == true || stt.Bool("live") == true || config.Get("voice").Bool("live_stt") == true;
    }

    public static string StartFrame(int sampleRate = 16000, string? profile = null, string? language = null)
    {
        var obj = new JsonObject
        {
            ["type"] = "start",
            ["sample_rate"] = sampleRate,
            ["encoding"] = "pcm_s16le",
            ["channels"] = 1,
        };
        if (!string.IsNullOrEmpty(profile)) obj["profile"] = profile;
        if (!string.IsNullOrEmpty(language)) obj["language"] = language;
        return obj.ToJsonString();
    }

    public static string AudioFrame(ReadOnlySpan<byte> pcmBytes) =>
        new JsonObject
        {
            ["type"] = "audio",
            ["data"] = Convert.ToBase64String(pcmBytes),
        }.ToJsonString();

    public static string CommitFrame() => new JsonObject { ["type"] = "commit" }.ToJsonString();

    public static string StopFrame() => new JsonObject { ["type"] = "stop" }.ToJsonString();

    public static GatewayWordsFrame? ParseFrame(string json)
    {
        var node = J.Parse(json);
        if (node == null) return null;
        var type = node.Str("type") ?? "";
        return type switch
        {
            "ready" => new GatewayWordsFrame.Ready(),
            "partial" or "interim" or "transcript.delta" => new GatewayWordsFrame.Partial(node.Str("text") ?? node.Str("transcript") ?? ""),
            "final" or "transcript" or "transcript.final" => new GatewayWordsFrame.Final(node.Str("text") ?? node.Str("transcript") ?? ""),
            "error" => new GatewayWordsFrame.Error(node.Str("message") ?? node.Str("detail") ?? node.Str("error") ?? "Streaming transcription failed."),
            _ => null,
        };
    }

    /// Merges a settled transcript with a newly arrived final segment without duplicating overlapping tail/head words.
    public static string Merge(string settled, string segment)
    {
        var a = settled.Trim();
        var b = segment.Trim();
        if (a.Length == 0) return b;
        if (b.Length == 0) return a;
        if (b.StartsWith(a, StringComparison.OrdinalIgnoreCase)) return b;
        var aWords = a.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var bWords = b.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var maxOverlap = Math.Min(aWords.Length, bWords.Length);
        for (var k = maxOverlap; k >= 1; k--)
        {
            var match = true;
            for (var i = 0; i < k; i++)
            {
                if (!string.Equals(aWords[aWords.Length - k + i], bWords[i], StringComparison.OrdinalIgnoreCase))
                {
                    match = false;
                    break;
                }
            }
            if (match)
            {
                var tail = string.Join(" ", bWords.Skip(k));
                return tail.Length == 0 ? a : $"{a} {tail}";
            }
        }
        return $"{a} {b}";
    }
}

/// Remembers per-account whether the gateway supports streaming STT so unsupported gateways aren't retried.
public sealed class GatewayWordsMemory
{
    public static readonly GatewayWordsMemory Shared = new();

    private readonly object _gate = new();
    private readonly Dictionary<string, bool> _supported = [];

    public bool? Known(string accountId) { lock (_gate) return _supported.TryGetValue(accountId, out var v) ? v : null; }
    public void Remember(string accountId, bool supported) { lock (_gate) _supported[accountId] = supported; }
    public void Forget(string accountId) { lock (_gate) _supported.Remove(accountId); }
    public void Clear() { lock (_gate) _supported.Clear(); }
}

/// Streaming live words implementation backed by a gateway WebSocket.
public sealed class GatewayLiveWords : ILiveWordsListening
{
    private readonly Func<CancellationToken, Task<(Uri Url, string? Cookie, string? Bearer)>> _resolveEndpoint;
    private readonly Func<IGatewayWordsSocket> _socketFactory;
    private readonly string? _profile;
    private readonly int _sampleRate;
    private IGatewayWordsSocket? _socket;
    private string _settled = "";
    private string _pending = "";
    private bool _active;

    public GatewayLiveWords(
        Func<CancellationToken, Task<(Uri Url, string? Cookie, string? Bearer)>> resolveEndpoint,
        Func<IGatewayWordsSocket> socketFactory,
        string? profile = null,
        int sampleRate = 16000)
    {
        _resolveEndpoint = resolveEndpoint;
        _socketFactory = socketFactory;
        _profile = profile;
        _sampleRate = sampleRate;
    }

    public LiveWordsSource Source => LiveWordsSource.Gateway;
    public bool IsAvailable => true;
    public event Action<LiveWordsText>? Changed;

    public async Task<bool> StartAsync(CancellationToken ct = default)
    {
        Cancel();
        _settled = "";
        _pending = "";
        try
        {
            var (url, cookie, bearer) = await _resolveEndpoint(ct);
            var socket = _socketFactory();
            socket.FrameReceived += OnFrame;
            await socket.ConnectAsync(url, cookie, bearer, ct);
            await socket.SendTextAsync(GatewayWordsWire.StartFrame(_sampleRate, _profile), ct);
            _socket = socket;
            _active = true;
            return true;
        }
        catch (Exception)
        {
            Cancel();
            return false;
        }
    }

    public void FeedPcm(ReadOnlySpan<short> pcm, int sampleRate)
    {
        if (!_active || _socket is not { } socket || pcm.IsEmpty) return;
        var bytes = new byte[pcm.Length * 2];
        Buffer.BlockCopy(pcm.ToArray(), 0, bytes, 0, bytes.Length);
        _ = SendAudioQuietly(socket, bytes);
    }

    private static async Task SendAudioQuietly(IGatewayWordsSocket socket, byte[] bytes)
    {
        try { await socket.SendBinaryAsync(bytes); } catch (Exception) { }
    }

    public async Task<string> FinishAsync(CancellationToken ct = default)
    {
        _active = false;
        if (_socket is { } socket)
        {
            _socket = null;
            try
            {
                await socket.SendTextAsync(GatewayWordsWire.CommitFrame(), ct);
                await socket.CloseAsync(ct);
            }
            catch (Exception) { }
            finally
            {
                socket.FrameReceived -= OnFrame;
                await socket.DisposeAsync();
            }
        }
        return new LiveWordsText(_settled, _pending).Text;
    }

    public void Cancel()
    {
        _active = false;
        if (_socket is { } socket)
        {
            _socket = null;
            socket.FrameReceived -= OnFrame;
            _ = socket.DisposeAsync();
        }
        _settled = "";
        _pending = "";
    }

    private void OnFrame(GatewayWordsFrame frame)
    {
        switch (frame)
        {
            case GatewayWordsFrame.Partial p:
                _pending = p.Text;
                Changed?.Invoke(new LiveWordsText(_settled, _pending));
                break;
            case GatewayWordsFrame.Final f:
                _settled = GatewayWordsWire.Merge(_settled, f.Text);
                _pending = "";
                Changed?.Invoke(new LiveWordsText(_settled, _pending));
                break;
        }
    }
}
