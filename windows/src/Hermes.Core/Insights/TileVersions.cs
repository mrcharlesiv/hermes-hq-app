using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Jobs;
using Hermes.Core.Kanban;
using Hermes.Core.Net;

namespace Hermes.Core.Insights;

// [tile-versions] A tile's versions (HermesKit/Pages/TileVersions.swift and App/Pages/Artifacts/TileVersionsSheet.swift).
// Each look of a page tile is kept beside it on the bot's computer:
//
//     ~/dashboards/revenue.html                    the tile
//     ~/dashboards/revenue.versions/v1.html …      each version, as the page was
//     ~/dashboards/revenue.versions/versions.json  which there are, what was asked for each, and which one shows now
//
// Preserves the existing read-only API (`TileVersionReader`, 3-arg `TileVersionsModel`, 2-arg `Offer`, 1-arg `Footer`)
// while adding full writable support (`TileVersionStore`, `TileVersionsModel.WritableFor`, `RollBackAsync`, `DesignHash`, `Noting`).

/// How a version came to be (`TileVersion.Kind`).
public enum TileVersionKind { Made, Changed, Outside, First }

/// One version (`TileVersion`): its JSON is the Swift app's Codable form.
public sealed record TileVersion(int Number, double At, TileVersionKind Kind, string? What, string File, string Design)
{
    /// "Version 3".
    public string Title => $"Version {Number}";

    public string KindRaw => Kind switch
    {
        TileVersionKind.Made => "made",
        TileVersionKind.Changed => "changed",
        TileVersionKind.Outside => "outside",
        _ => "first",
    };

    /// The row's second line: what was asked, or how it came to be.
    public string Words
    {
        get
        {
            var asked = (What ?? "").Trim();
            return Kind switch
            {
                TileVersionKind.Made => asked.Length == 0 ? "The tile as it was made" : asked,
                TileVersionKind.Changed => asked.Length == 0 ? "Changed in Tiles" : asked,
                TileVersionKind.Outside => "Changed in a chat",
                _ => "The tile when versions began",
            };
        }
    }

    public JsonObject ToJson()
    {
        var o = new JsonObject
        {
            ["at"] = At,
            ["design"] = Design,
            ["file"] = File,
            ["kind"] = KindRaw,
            ["number"] = Number,
        };
        if (What != null) o["what"] = What;
        return o;
    }
}

/// The tile's versions as kept (`TileVersionList`).
public sealed record TileVersionList(int Current, IReadOnlyList<TileVersion> Versions)
{
    public static readonly TileVersionList Empty = new(0, []);

    /// The version that shows now.
    public TileVersion? Shown => Versions.FirstOrDefault(v => v.Number == Current);

    /// Next version number to assign.
    public int Next => Versions.Count == 0 ? 1 : Versions.Max(v => v.Number) + 1;

    /// Newest first, as Versions lists them (`sorted { $0.number > $1.number }`).
    public IReadOnlyList<TileVersion> NewestFirst => Versions.OrderByDescending(v => v.Number).ToList();

    public string ToJsonString()
    {
        var root = new JsonObject
        {
            ["current"] = Current,
            ["versions"] = new JsonArray([.. Versions.Select(v => (JsonNode)v.ToJson())]),
        };
        return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    /// `versions.json` read as Swift's `JSONDecoder().decode(TileVersionList.self)` reads it: every required key, the
    /// right types and a known kind, else null (the Mac then lists none). Unknown keys are ignored.
    public static TileVersionList? Parse(string text)
    {
        JsonNode? root;
        try { root = JsonNode.Parse(text); }
        catch (JsonException) { return null; }
        if (root is not JsonObject o || Int(o["current"]) is not { } current || o["versions"] is not JsonArray items) return null;
        var versions = new List<TileVersion>();
        foreach (var item in items)
        {
            if (item is not JsonObject v
                || Int(v["number"]) is not { } number
                || Double(v["at"]) is not { } at
                || Str(v["kind"]) is not { } kindName
                || KindOf(kindName) is not { } kind
                || Str(v["file"]) is not { } file
                || Str(v["design"]) is not { } design) return null;
            string? what = null;
            if (v.TryGetPropertyValue("what", out var w) && w != null)
            {
                if (Str(w) is not { } s) return null;
                what = s;
            }
            versions.Add(new TileVersion(number, at, kind, what, file, design));
        }
        return new TileVersionList(current, versions);
    }

    private static TileVersionKind? KindOf(string raw) => raw switch
    {
        "made" => TileVersionKind.Made,
        "changed" => TileVersionKind.Changed,
        "outside" => TileVersionKind.Outside,
        "first" => TileVersionKind.First,
        _ => null,
    };

    private static string? Str(JsonNode? n) =>
        n is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    private static double? Double(JsonNode? n) =>
        n is JsonValue v && v.GetValueKind() == JsonValueKind.Number && v.TryGetValue(out double d) ? d : null;

    /// A whole number (Foundation's decoder also takes 2.0 for an Int; 2.5 fails).
    private static int? Int(JsonNode? n) =>
        Double(n) is { } d && d == Math.Floor(d) && d >= int.MinValue && d <= int.MaxValue ? (int)d : null;
}

/// Where the versions are kept, design hashing, and pure version-list transitions (`TileVersionFiles`).
public static partial class TileVersionFiles
{
    /// The most kept for one tile: the oldest after the first give way.
    public const int Limit = 60;

    /// The folder beside the tile: "~/dashboards/revenue.html" → "~/dashboards/revenue.versions".
    public static string Folder(string tile)
    {
        var slash = tile.LastIndexOf('/');
        var directory = slash < 0 ? "" : tile[..slash];
        if (slash == 0) directory = "/";
        var last = slash < 0 ? tile : tile[(slash + 1)..];
        var dot = last.LastIndexOf('.');
        var stem = dot > 0 ? last[..dot] : last;
        var name = (stem.Length == 0 ? "tile" : stem) + ".versions";
        if (directory.Length == 0) return name;
        return directory.EndsWith('/') ? directory + name : directory + "/" + name;
    }

    public static string IndexPath(string tile) => Folder(tile) + "/versions.json";
    public static string FileName(int number) => $"v{number}.html";
    public static string PathOf(TileVersion version, string tile) => Folder(tile) + "/" + version.File;

    /// The page less its data: `<script type="application/json">` blocks are emptied and runs of whitespace
    /// collapsed to a single space so data refreshes keep the same design hash while layout/code changes differ.
    public static string Design(string html)
    {
        var stripped = JsonScriptRx().Replace(html, "<script type=\"application/json\"></script>");
        return string.Join(' ', stripped.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
    }

    public static string DesignHash(string html) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Design(html)))).ToLowerInvariant()[..20];

    /// The list after seeing the tile's page as `html`: unchanged when the currently shown version has that look,
    /// else with a new version added (keeping the first version and the newest `Limit - 1` after it).
    public static (TileVersionList List, TileVersion? Added) Noting(string html, TileVersionList list,
        TileVersionKind kind, string? what, double? at = null)
    {
        var design = DesignHash(html);
        if (list.Shown is { } shown && shown.Design == design) return (list, null);
        var first = list.Versions.Count == 0;
        var number = list.Next;
        var asked = (what ?? "").Trim();
        var version = new TileVersion(
            number,
            at ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
            first && kind == TileVersionKind.Outside ? TileVersionKind.First : kind,
            asked.Length == 0 ? null : asked.Length > 600 ? asked[..600] : asked,
            FileName(number),
            design);
        var versions = list.Versions.ToList();
        versions.Add(version);
        if (versions.Count > Limit)
        {
            versions.Sort((a, b) => a.Number.CompareTo(b.Number));
            versions = [versions[0], .. versions.Skip(versions.Count - (Limit - 1))];
        }
        return (new TileVersionList(number, versions), version);
    }

    [GeneratedRegex(@"<script\b[^>]*type\s*=\s*[""']?application/json[""']?[^>]*>.*?</script\s*>",
        RegexOptions.IgnoreCase | RegexOptions.Singleline)]
    private static partial Regex JsonScriptRx();
}

/// Why the versions couldn't be read or rolled back (`TileVersionError`).
public static class TileVersionError
{
    public const string Unreadable = "This tile’s page couldn’t be read, or is too large to keep versions of.";
    public const string Missing = "That version’s copy is gone from the bot’s computer.";

    public static string Words(Exception e) => e switch
    {
        TileVersionUnreadable => Unreadable,
        TileVersionMissing => Missing,
        TileVersionRefused r => r.Message,
        _ => KanbanRest.Reason(e),
    };
}

/// The file was too large for a text read, or not text (`TileVersionError.unreadable`).
public sealed class TileVersionUnreadable() : Exception(TileVersionError.Unreadable);

/// The version's copy is gone from the bot's computer (`TileVersionError.missing`).
public sealed class TileVersionMissing() : Exception(TileVersionError.Missing);

/// The gateway refused to write the version (`TileVersionError.refused`).
public sealed class TileVersionRefused(string reason) : Exception(reason);

/// The one read Versions makes on a read-only gateway (`TileVersionStore.list`): `GET /api/fs/download` of the tile's
/// `versions.json`, as the tile's bot. Nothing is ever written.
public sealed class TileVersionReader(GatewaySession session, string profile, string tile)
{
    /// The most of a file read (`TileVersionStore.largest`).
    public const int Largest = 6 * 1024 * 1024;

    public string Tile => tile;

    /// The tile's versions as kept: empty when there's no list yet (404) or it isn't one the Mac would decode.
    public async Task<TileVersionList> ListAsync(CancellationToken ct = default)
    {
        var query = new List<KeyValuePair<string, string>> { new("path", TileVersionFiles.IndexPath(tile)) };
        if (profile.Length > 0) query.Add(new("profile", profile));
        var a = await session.SendAsync(HttpMethod.Get, "/api/fs/download", query, timeout: TimeSpan.FromSeconds(60), ct: ct);
        if (a.Status == 404) return TileVersionList.Empty;
        if (!a.Ok) throw new GatewayException("http", $"The gateway answered {a.Status}.", a.Status, a.Body.Length > 65536 ? a.Body[..65536] : a.Body);
        // Too large, or not UTF-8 (the shared session decodes text; an invalid byte becomes U+FFFD).
        if (Encoding.UTF8.GetByteCount(a.Body) > Largest || a.Body.Contains('\uFFFD')) throw new TileVersionUnreadable();
        return TileVersionList.Parse(a.Body) ?? TileVersionList.Empty;
    }
}

/// Full read/write tile version store on the bot's computer (`/api/fs/download`, `/api/fs/write-text`, `/api/files/mkdir`).
public sealed class TileVersionStore(GatewaySession session, string profile, string tile)
{
    public const int Largest = TileVersionReader.Largest;

    public string Tile => tile;

    private List<KeyValuePair<string, string>> ProfileQuery() =>
        profile.Length > 0 ? [new("profile", profile)] : [];

    private async Task<string?> ReadTextAsync(string path, CancellationToken ct)
    {
        var query = new List<KeyValuePair<string, string>> { new("path", path) };
        if (profile.Length > 0) query.Add(new("profile", profile));
        var a = await session.SendAsync(HttpMethod.Get, "/api/fs/download", query, timeout: TimeSpan.FromSeconds(60), ct: ct);
        if (a.Status == 404) return null;
        if (!a.Ok) throw new GatewayException("http", $"The gateway answered {a.Status}.", a.Status, a.Body.Length > 65536 ? a.Body[..65536] : a.Body);
        if (Encoding.UTF8.GetByteCount(a.Body) > Largest || a.Body.Contains('\uFFFD')) throw new TileVersionUnreadable();
        return a.Body;
    }

    private async Task WriteTextAsync(string path, string content, CancellationToken ct)
    {
        var body = new JsonObject { ["path"] = path, ["content"] = content };
        var a = await session.SendAsync(HttpMethod.Post, "/api/fs/write-text", ProfileQuery(), body, timeout: TimeSpan.FromSeconds(30), ct: ct);
        if (!a.Ok) throw new GatewayException("http", $"The gateway answered {a.Status}.", a.Status, a.Body.Length > 65536 ? a.Body[..65536] : a.Body);
        var answer = J.Parse(a.Body);
        if (answer is not JsonObject || answer.Bool("ok") == false || answer.Get("error") != null)
            throw new TileVersionRefused("The gateway didn’t keep the file.");
    }

    private async Task MakeFolderAsync(CancellationToken ct)
    {
        var body = new JsonObject { ["path"] = TileVersionFiles.Folder(tile) };
        var a = await session.SendAsync(HttpMethod.Post, "/api/files/mkdir", ProfileQuery(), body, timeout: TimeSpan.FromSeconds(30), ct: ct);
        if (!a.Ok && a.Status != 409)
            throw new GatewayException("http", $"The gateway answered {a.Status}.", a.Status, a.Body.Length > 65536 ? a.Body[..65536] : a.Body);
    }

    public async Task<TileVersionList> ListAsync(CancellationToken ct = default)
    {
        var text = await ReadTextAsync(TileVersionFiles.IndexPath(tile), ct);
        return text == null ? TileVersionList.Empty : TileVersionList.Parse(text) ?? TileVersionList.Empty;
    }

    private Task KeepAsync(TileVersionList list, CancellationToken ct) =>
        WriteTextAsync(TileVersionFiles.IndexPath(tile), list.ToJsonString(), ct);

    /// Reads the current tile page and saves a new version if its design differs from the currently shown version.
    public async Task<TileVersionList> NoteAsync(TileVersionKind kind, string? what, CancellationToken ct = default)
    {
        var html = await ReadTextAsync(tile, ct);
        if (string.IsNullOrWhiteSpace(html)) throw new TileVersionUnreadable();
        var list = await ListAsync(ct);
        var (noted, added) = TileVersionFiles.Noting(html, list, kind, what);
        if (added == null) return list;
        if (list.Versions.Count == 0) await MakeFolderAsync(ct);
        await WriteTextAsync(TileVersionFiles.PathOf(added, tile), html, ct);
        await KeepAsync(noted, ct);
        return noted;
    }

    /// Writes version `number`'s saved HTML back over the tile. Preserves the current tile as a version first if needed.
    public async Task<TileVersionList> RollBackAsync(int number, CancellationToken ct = default)
    {
        var list = await NoteAsync(TileVersionKind.Outside, null, ct);
        var version = list.Versions.FirstOrDefault(v => v.Number == number) ?? throw new TileVersionMissing();
        var html = await ReadTextAsync(TileVersionFiles.PathOf(version, tile), ct) ?? throw new TileVersionMissing();
        await WriteTextAsync(tile, html, ct);
        var next = list with { Current = number };
        await KeepAsync(next, ct);
        return next;
    }
}

/// Versions in a tile's menu, as the gateway allows it.
public enum TileVersionsOffer
{
    /// Not offered: not a page (or a writable gateway when calling the legacy read-only 2-arg `Offer`).
    Hidden,
    /// Shown, dimmed: a page with no path on the bot's computer (`pin.gatewayPath == nil`).
    Disabled,
    Enabled,
}

/// The Versions sheet's state and words, UI-free (`TileVersionsModel`, `TileVersionsView`).
public sealed class TileVersionsModel
{
    public abstract record State
    {
        public sealed record Reading : State;
        public sealed record Listed(TileVersionList List) : State;
        public sealed record Problem(string Words) : State;
    }

    /// One row: "Version 3", Current, what was asked, when.
    public sealed record Row(int Number, string Title, bool Current, string Words, string When, string AccessibilityLabel, string AutomationId);

    public const string Title = "Versions";
    public const string ProblemTitle = "Couldn’t Read This Tile’s Versions";
    public const string TryAgain = "Try Again";
    public const string ReadingWords = "Reading versions…";
    public const string ReadOnlyWords = " This gateway is read-only, so versions can’t be rolled back from here.";

    private readonly TilePin _pin;
    private readonly Func<string, TileVersionReader>? _reader;
    private readonly Func<string, TileVersionStore>? _store;
    private int _generation;

    /// The tile's name, the sheet's subtitle.
    public string Name { get; }
    public bool Writable => _store != null;
    public State Now { get; private set; } = new State.Reading();
    public int? RollingBack { get; private set; }
    public string? RollBackError { get; private set; }
    public event Action? Changed;

    /// Read-only constructor (preserved for existing callers and tests): reads `versions.json`, never writes.
    public TileVersionsModel(TilePin pin, string name, Func<string, TileVersionReader>? reader)
    {
        _pin = pin;
        Name = name;
        _reader = reader;
    }

    private TileVersionsModel(TilePin pin, string name, Func<string, TileVersionStore>? store)
    {
        _pin = pin;
        Name = name;
        _store = store;
    }

    /// Writable model: notes the current tile when opened and supports Roll Back / Restore.
    public static TileVersionsModel WritableFor(TilePin pin, string name, Func<string, TileVersionStore>? store) =>
        new(pin, name, store);

    /// Legacy read-only menu check (preserved for existing `TileVersionsTests`).
    public static TileVersionsOffer Offer(TilePin pin, bool readOnlyGateway) =>
        !readOnlyGateway || !pin.IsPage ? TileVersionsOffer.Hidden
        : pin.GatewayPath == null ? TileVersionsOffer.Disabled
        : TileVersionsOffer.Enabled;

    /// Full menu check supporting both writable and read-only gateways (`ArtifactsViewController.versionsAction`).
    public static TileVersionsOffer Offer(TilePin pin, bool readOnlyGateway, bool supportsWritable) =>
        !supportsWritable ? Offer(pin, readOnlyGateway)
        : !pin.IsPage ? TileVersionsOffer.Hidden
        : pin.GatewayPath == null ? TileVersionsOffer.Disabled
        : TileVersionsOffer.Enabled;

    /// The menu's subtitle: the version the pin last showed ("Version 2"), when known.
    public static string? MenuSubtitle(TilePin pin) => pin.Version is { } v ? $"Version {v}" : null;

    /// Older versions confirm before rolling back; newer versions restore immediately.
    public static bool AsksFirst(TileVersion version, TileVersionList list) => version.Number < list.Current;

    public static string Verb(TileVersion version, TileVersionList list) =>
        AsksFirst(version, list) ? TileWords.RollBack : TileWords.Restore;

    public static string RollBackWords(int number, string? botName, bool hasJob) =>
        hasJob && !string.IsNullOrWhiteSpace(botName)
            ? $"This puts Version {number} back on the tile and asks {botName} to keep its updates on this version. Newer versions stay here so you can restore them later."
            : $"This puts Version {number} back on the tile. Newer versions stay here so you can restore them later.";

    /// Reads (or notes, when writable) the version list. Try Again calls it again.
    public async Task LoadAsync(CancellationToken ct = default)
    {
        var generation = ++_generation;
        RollBackError = null;
        Set(new State.Reading());
        State next;
        if (_pin.GatewayPath is not { } path || !_pin.IsPage || (_reader == null && _store == null))
            next = new State.Problem(TileVersionError.Unreadable);
        else
        {
            try
            {
                var list = _store != null
                    ? await _store(path).NoteAsync(TileVersionKind.Outside, null, ct)
                    : await _reader!(path).ListAsync(ct);
                next = new State.Listed(list);
            }
            catch (Exception e) when (e is not OperationCanceledException || !ct.IsCancellationRequested)
            {
                next = new State.Problem(TileVersionError.Words(e));
            }
        }
        if (generation == _generation) Set(next);
    }

    /// Rolls back or restores `number` over the tile (writable gateways only).
    public async Task<TileVersionList?> RollBackAsync(int number, CancellationToken ct = default)
    {
        if (_store == null || _pin.GatewayPath is not { } path || RollingBack != null) return null;
        RollingBack = number;
        RollBackError = null;
        Changed?.Invoke();
        try
        {
            var updated = await _store(path).RollBackAsync(number, ct);
            RollingBack = null;
            Set(new State.Listed(updated));
            return updated;
        }
        catch (Exception e) when (e is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            RollingBack = null;
            RollBackError = TileVersionError.Words(e);
            Changed?.Invoke();
            return null;
        }
    }

    private void Set(State state)
    {
        Now = state;
        Changed?.Invoke();
    }

    /// Newest first, Current on the one that shows.
    public static IReadOnlyList<Row> Rows(TileVersionList list, DateTimeOffset? now = null, TimeZoneInfo? zone = null) =>
        list.NewestFirst.Select(v =>
        {
            var current = v.Number == list.Current;
            return new Row(v.Number, v.Title, current, v.Words,
                JobWords.RelativeDateTime(DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(v.At * 1000)), now, zone),
                $"{v.Title}{(current ? ", current" : "")}. {v.Words}", $"tile.version.{v.Number}");
        }).ToList();

    /// The section's footer, read-only (preserved 1-arg signature for existing tests).
    public static string Footer(TileVersionList list) => Footer(list, writable: false);

    /// The section's footer for writable or read-only gateways (`TileVersionsView.footer`).
    public static string Footer(TileVersionList list, bool writable)
    {
        var body = list.Versions.Count == 1
            ? "This is the only version so far. Each change makes a new one, and the ones before stay here."
            : "Click a version to see it full size. Rolling back puts that version on the tile; the others stay here.";
        return writable ? body : body + ReadOnlyWords;
    }

    /// The pin a version opens as (full size, as the tile opens), read as the tile's bot.
    public TilePin? VersionPin(TileVersion version) => _pin.GatewayPath is { } path
        ? TilePin.Make(TileKind.File, TileVersionFiles.PathOf(version, path), version.File, _pin.Profile, _pin.SessionId, _pin.SessionTitle, _pin.PinnedAt)
        : null;
}
