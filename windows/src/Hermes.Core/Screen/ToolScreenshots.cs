// [WIN-SCREEN-SHOT-FEED] computer_use and browser screenshots in a tool result (docs/spec/3x-screen.md §5.3), the C#
// twin of the Mac's HermesKit/Screen/ToolScreenshots.swift at 93f984bb1 (the web's `image-zoom.ts` and
// `tool-screenshots.ts`, ported one for one). A live result is a multimodal envelope; a reloaded transcript keeps only
// the text summary, which names the capture by its gateway path. The gateway keeps only its newest 20 captures, so an
// older step's file can be gone: `ScreenshotExpiry` finds that out with one folder listing.
//
// JSONValue is System.Text.Json.Nodes.JsonNode (a JSON null is a C# null, as `isNull` reads it). `Data` answers are the
// UTF-8 text the gateway sent (IScreenRest's string). The Swift actor is a lock around each run between awaits, so a
// check is reentrant at its one await exactly as the actor is.

using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Screen;

/// The gateway's REST with a query (the Swift `GatewayClient.rest(_:_:query:body:)` with no body). Errors are
/// GatewayException ("http" + Status) or the transport's own.
public interface IScreenshotRest
{
    Task<string> RestAsync(string method, string path, IReadOnlyList<KeyValuePair<string, string>> query, CancellationToken ct = default);
}

/// The capture a step shows. `Source` is a gateway path, or a `data:image/…` URL (kept in memory only).
public readonly record struct ToolScreenshot(string Source, bool Expired = false, double? CapturedAt = null)
{
    // `CapturedAt`: when the tool finished, unix seconds (the stored row's time, or the moment the live result
    // arrived). The expiry check needs it: a folder listing older than the capture says nothing about it.

    public bool IsInline => ToolScreenshots.IsInline(Source);
    /// The file's name, for "Open image: <name>".
    public string FileName => ToolScreenshots.FileName(Source);
}

public static class ToolScreenshots
{
    public const string ExpiredNote = "This screenshot has expired: the gateway keeps only its 20 most recent screenshots.";

    public static bool IsScreenshotTool(string? name)
    {
        if (name == null) return false;
        return name.StartsWith("computer_use", StringComparison.Ordinal) || name.StartsWith("browser_", StringComparison.Ordinal);
    }

    /// `data:`, `blob:` and `http(s):` sources are never files on the gateway.
    public static bool IsRemote(string source) =>
        source.StartsWith("data:", StringComparison.OrdinalIgnoreCase) || source.StartsWith("blob:", StringComparison.OrdinalIgnoreCase)
        || source.StartsWith("http:", StringComparison.OrdinalIgnoreCase) || source.StartsWith("https:", StringComparison.OrdinalIgnoreCase);

    public static bool IsInline(string source) => source.StartsWith("data:image/", StringComparison.OrdinalIgnoreCase);

    public static string FileName(string source)
    {
        if (IsRemote(source)) return "screenshot";
        var cut = source.LastIndexOfAny(['/', '\\']);
        return source[(cut + 1)..];
    }

    private static readonly Regex Saved = new(@"screenshot (?:saved to|path:)\s*(\S+\.(?:png|jpe?g|webp))",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// The path a text summary names ("… screenshot saved to <path>"), "" when it names none.
    public static string SavedScreenshot(string text)
    {
        var match = Saved.Match(text);
        return match.Success ? match.Groups[1].Value : "";
    }

    /// The image of a multimodal tool result: an inline `data:image/…`, else the path it names. "" when none.
    public static string MultimodalToolImage(JsonNode? result)
    {
        switch (result)
        {
            case JsonValue value when value.GetValueKind() == JsonValueKind.String:
                return SavedScreenshot(value.GetValue<string>());
            case JsonArray items:
                foreach (var item in items)
                {
                    if (AsText(item) is not { } text) continue;
                    var path = SavedScreenshot(text);
                    if (path.Length > 0) return path;
                }
                return "";
            case JsonObject record:
                foreach (var part in record.Arr("content") ?? [])
                {
                    var value = AsText(part.Get("image_url")) ?? AsText(part.Get("image_url").Get("url"));
                    if (value != null && IsInline(value)) return value;
                }
                if (AsText(record.Get("meta").Get("screenshot_path")) is { } metaPath) return metaPath;
                if (AsText(record.Get("screenshot_path")) is { } ownPath) return ownPath;
                // Swift `record.keys.sorted()`: String order is by Unicode scalars; ordinal UTF-16 agrees for every key
                // outside the surrogate range.
                foreach (var key in record.Select(p => p.Key).Order(StringComparer.Ordinal))
                {
                    if (AsText(record[key]) is not { } text) continue;
                    var path = SavedScreenshot(text);
                    if (path.Length > 0) return path;
                }
                return "";
            default:
                return "";
        }
    }

    /// The screenshot a STORED tool result names: a string is read as JSON when it is one, else as the summary.
    public static string StoredScreenshot(JsonNode? result) =>
        AsText(result) is { } text ? StoredScreenshot(text) : MultimodalToolImage(result);

    public static string StoredScreenshot(string text)
    {
        var trimmed = text.TrimStart(' ', '\n', '\t', '\r');
        if (trimmed.Length > 0 && trimmed[0] is '{' or '[' && ParseJson(text) is JsonObject or JsonArray)
            return MultimodalToolImage(ParseJson(text));
        return SavedScreenshot(text);
    }

    /// A live `tool.complete`: the result's own image, else the path its text or summary names.
    public static string LiveSource(JsonNode? result, string? resultText, string? summary)
    {
        var direct = MultimodalToolImage(result);
        if (direct.Length > 0) return direct;
        if (resultText != null)
        {
            var found = StoredScreenshot(resultText);
            if (found.Length > 0) return found;
        }
        if (summary != null) return StoredScreenshot(summary);
        return "";
    }

    /// The inline picture is kept for a step only below this many characters (a data URL of about 3 MB of picture).
    public const int MaxInlineStep = 4 << 20;

    /// The screenshot a step keeps. DECISION: the gateway path wins over the inline picture when the result carries
    /// both (a chat keeps every step's detail in memory, and a long computer_use run would otherwise hold megabytes
    /// per step); an inline picture is kept only when there is no path and it is not huge.
    public static ToolScreenshot? StepScreenshot(JsonNode? result, string? resultText, string? summary, double? at = null)
    {
        if (StepSource(result, resultText, summary) is not { } shot) return null;
        return shot with { CapturedAt = at };
    }

    private static ToolScreenshot? StepSource(JsonNode? result, string? resultText, string? summary)
    {
        // A stored result is often the JSON text of the envelope.
        if (AsText(result) is { } text && text.FirstOrDefault(c => !char.IsWhiteSpace(c)) == '{' && ParseJson(text) is JsonObject parsed)
            result = parsed;
        var first = LiveSource(result, resultText, summary);
        if (first.Length == 0) return null;
        if (!IsInline(first)) return new ToolScreenshot(first);
        var path = "";
        if (result is JsonObject record)
        {
            var copy = (JsonObject)record.DeepClone();
            copy.Remove("content");
            path = MultimodalToolImage(copy);
        }
        if (path.Length == 0 && resultText != null) path = StoredScreenshot(resultText);
        if (path.Length == 0 && summary != null) path = StoredScreenshot(summary);
        if (path.Length > 0 && !IsInline(path)) return new ToolScreenshot(path);
        return Encoding.UTF8.GetByteCount(first) <= MaxInlineStep ? new ToolScreenshot(first) : null;
    }

    /// The screenshot of a screen tool's result ("" for other tools).
    public static string Restored(string? tool, JsonNode? result) => IsScreenshotTool(tool) ? StoredScreenshot(result) : "";

    /// An expired step's Output: the note, a blank line, then what the gateway stored.
    public static string ExpiredOutput(string? stored) =>
        string.IsNullOrEmpty(stored) ? ExpiredNote : ExpiredNote + "\n\n" + stored;

    /// A folder's file names from `GET /api/fs/list?path=<dir>`; null when the answer is no listing.
    public static IReadOnlySet<string>? NamesInListing(string data)
    {
        var json = ParseJson(data);
        if (json == null) return null;
        if (json.Get("error") is { } error && !(error is JsonValue b && b.GetValueKind() == JsonValueKind.False) && AsText(error) != "")
            return null;
        if (json.Arr("entries") is not { } entries) return null;
        return entries.Select(e => AsText(e.Get("name")) ?? "").ToHashSet(StringComparer.Ordinal);
    }

    // JSONValue's strict reads (`.string` is a string only; `.number` a number only), unlike J's lenient coercions.

    internal static string? AsText(JsonNode? node) =>
        node is JsonValue value && value.GetValueKind() == JsonValueKind.String ? value.GetValue<string>() : null;

    internal static double? AsNumber(JsonNode? node) =>
        node is JsonValue value && value.GetValueKind() == JsonValueKind.Number
            ? double.Parse(value.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture) : null;

    /// `JSONValue.parse`: nil for anything that is not JSON (duplicate keys included, which JsonObject rejects on read).
    internal static JsonNode? ParseJson(string text)
    {
        try
        {
            var node = JsonNode.Parse(text);
            Touch(node);
            return node;
        }
        catch (Exception e) when (e is JsonException or ArgumentException or InvalidOperationException) { return null; }
    }

    private static void Touch(JsonNode? node)
    {
        switch (node)
        {
            case JsonObject o: foreach (var p in o) Touch(p.Value); break;
            case JsonArray a: foreach (var item in a) Touch(item); break;
        }
    }
}

/// Whether the gateway still has a step's screenshot. One per account. The web's rules and numbers: a folder's listing
/// is reused for 60 s, fetched again when it predates the capture by less than a second (so a new screenshot is never
/// called expired), an unreadable or empty listing proves nothing (ask again at most every 30 s), and both tables are
/// bounded (64 listings, 2,000 settled calls).
public sealed class ScreenshotExpiry
{
    public delegate Task<IReadOnlySet<string>?> Lister(string directory);

    public const double ListingLife = 60;
    public const double RetryAfter = 30;
    public const int MaxListings = 64;
    public const int MaxNoted = 2_000;

    private sealed class Listing(double at, Task<IReadOnlySet<string>?> names)
    {
        public double At { get; } = at;
        public Task<IReadOnlySet<string>?> Names { get; } = names;
    }

    private readonly Lister _list;
    private readonly object _gate = new();
    private readonly Dictionary<string, Listing> _listings = new(StringComparer.Ordinal);
    private readonly List<string> _listingOrder = [];
    private readonly Dictionary<string, bool> _noted = new(StringComparer.Ordinal);   // settled calls: true = the file is gone
    private readonly List<string> _notedOrder = [];
    private readonly Dictionary<string, double> _asked = new(StringComparer.Ordinal);
    private readonly List<string> _askedOrder = [];

    public ScreenshotExpiry(Lister list) => _list = list;

    public ScreenshotExpiry(IScreenshotRest client, string? profile)
    {
        _list = async directory =>
        {
            var query = new List<KeyValuePair<string, string>> { new("path", directory) };
            if (!string.IsNullOrEmpty(profile)) query.Add(new("profile", profile));
            string data;
            try { data = await client.RestAsync("GET", "/api/fs/list", query); }
            catch (Exception) { return null; }       // Swift `try?`: any failure is no listing
            return ToolScreenshots.NamesInListing(data);
        };
    }

    /// How much is held (tests: the caps).
    public (int Listings, int Noted, int Asked) Held
    {
        get { lock (_gate) return (_listings.Count, _noted.Count, _asked.Count); }
    }

    /// What an earlier check settled for this call (null: not settled yet).
    public bool? Settled(string toolCallId)
    {
        lock (_gate) return _noted.TryGetValue(toolCallId, out var gone) ? gone : null;
    }

    /// true when the gateway no longer has `path`. `completedAt`: unix seconds (a stored row) or milliseconds (live).
    /// `now`: unix seconds (null: the clock).
    public async Task<bool> CheckAsync(string? toolCallId, string path, double? completedAt, double? now = null)
    {
        var at = now ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        if (string.IsNullOrEmpty(toolCallId) || path.Length == 0 || ToolScreenshots.IsRemote(path)) return false;
        Listing cached;
        string directory, name;
        lock (_gate)
        {
            if (_noted.TryGetValue(toolCallId, out var known)) return known;
            if (_asked.TryGetValue(toolCallId, out var last) && at - last < RetryAfter) return false;
            var slash = path.LastIndexOf('/');
            if (slash <= 0)
            {
                Settle(toolCallId, false);
                return false;
            }
            _asked[toolCallId] = at;
            _askedOrder.Add(toolCallId);
            TrimAsked();
            directory = path[..slash];
            name = path[(slash + 1)..];
            var captured = completedAt is { } c ? (c > 0 ? (c < 1e12 ? c : c / 1000) : at) : at;
            if (_listings.TryGetValue(directory, out var have) && have.At > captured + 1 && at - have.At <= ListingLife)
            {
                cached = have;
            }
            else
            {
                var list = _list;
                var dir = directory;
                cached = new Listing(at, Task.Run(() => list(dir)));      // the Swift unstructured `Task { await list(directory) }`
                _listings[directory] = cached;
                _listingOrder.Remove(directory);
                _listingOrder.Add(directory);
                foreach (var key in _listings.Keys.ToList())
                {
                    if (key != directory && at - _listings[key].At > ListingLife)
                    {
                        _listings.Remove(key);
                        _listingOrder.Remove(key);
                    }
                }
                while (_listings.Count > MaxListings && _listingOrder.Count > 0)
                {
                    var oldest = _listingOrder[0];
                    _listingOrder.RemoveAt(0);
                    _listings.Remove(oldest);
                }
            }
        }
        var names = await cached.Names.ConfigureAwait(false);
        lock (_gate)
        {
            if (names == null || names.Count == 0)
            {
                // An unreadable folder is not kept for the next step to reuse.
                if (names == null && _listings.TryGetValue(directory, out var current) && current.At == cached.At)
                {
                    _listings.Remove(directory);
                    _listingOrder.Remove(directory);
                }
                return false;
            }
            if (_noted.TryGetValue(toolCallId, out var known)) return known;       // settled while the listing was read
            _asked.Remove(toolCallId);
            var gone = !names.Contains(name);
            Settle(toolCallId, gone);
            return gone;
        }
    }

    private void Settle(string id, bool gone)
    {
        if (!_noted.ContainsKey(id)) _notedOrder.Add(id);
        _noted[id] = gone;
        while (_noted.Count > MaxNoted && _notedOrder.Count > 0)
        {
            var oldest = _notedOrder[0];
            _notedOrder.RemoveAt(0);
            _noted.Remove(oldest);
        }
    }

    private void TrimAsked()
    {
        if (_askedOrder.Count > MaxNoted * 2) _askedOrder.RemoveAll(id => !_asked.ContainsKey(id));
        while (_asked.Count > MaxNoted && _askedOrder.Count > 0)
        {
            var oldest = _askedOrder[0];
            _askedOrder.RemoveAt(0);
            _asked.Remove(oldest);
        }
    }
}
