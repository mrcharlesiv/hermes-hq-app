using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hermes.Core.Insights;

/// A tile's size in Grid (HermesKit/Pages/ArtifactPins.swift `PinTileSize`): the sizes of a Home Screen widget, in cells.
public enum TileSize { Small, Medium, Tall, Banner, Large, ExtraLarge }

public static class TileSizes
{
    public static readonly TileSize[] All =
        [TileSize.Small, TileSize.Medium, TileSize.Tall, TileSize.Banner, TileSize.Large, TileSize.ExtraLarge];

    /// Banner and Extra Large's width is cut to the grid's (`TileGridPacking`).
    public const int WholeWidth = 99;

    public static string Title(this TileSize s) => s switch
    {
        TileSize.Small => "Small",
        TileSize.Medium => "Medium",
        TileSize.Tall => "Tall",
        TileSize.Banner => "Banner",
        TileSize.Large => "Large",
        _ => "Extra Large",
    };

    public static string Raw(this TileSize s) => s switch
    {
        TileSize.Small => "small",
        TileSize.Medium => "medium",
        TileSize.Tall => "tall",
        TileSize.Banner => "banner",
        TileSize.Large => "large",
        _ => "extraLarge",
    };

    public static string ShapeWords(this TileSize s) => s switch
    {
        TileSize.Small => "Small (1×1 square)",
        TileSize.Medium => "Medium (2×1 wide)",
        TileSize.Tall => "Tall (1×2 vertical)",
        TileSize.Banner => "Banner (full-width × 1 strip)",
        TileSize.Large => "Large (2×2 big square)",
        _ => "Extra Large (full-width × 3)",
    };

    public static TileSize? FromRaw(string? raw) => raw switch
    {
        "small" => TileSize.Small,
        "medium" => TileSize.Medium,
        "tall" => TileSize.Tall,
        "banner" => TileSize.Banner,
        "large" => TileSize.Large,
        "extraLarge" => TileSize.ExtraLarge,
        _ => null,
    };

    /// Columns across and rows down.
    public static (int Columns, int Rows) Span(this TileSize s) => s switch
    {
        TileSize.Small => (1, 1),
        TileSize.Medium => (2, 1),
        TileSize.Tall => (1, 2),
        TileSize.Banner => (WholeWidth, 1),
        TileSize.Large => (2, 2),
        _ => (WholeWidth, 3),
    };

    /// Legacy 2-column fitting kept compatible with existing callers/tests.
    public static TileSize Fitting(int columns, int rows) =>
        rows >= 3 ? TileSize.ExtraLarge : rows == 2 ? TileSize.Large : columns >= 2 ? TileSize.Medium : TileSize.Small;

    /// [tiles-v2] The size a tile dragged by its corner to this many cells takes (Edit Tiles): three rows or more
    /// Extra Large, two rows Tall (1 column) or Large (2+), one row Banner (3+ columns on a wide grid), Medium (2),
    /// else Small.
    public static TileSize Fitting(int columns, int rows, int gridColumns) =>
        rows >= 3 ? TileSize.ExtraLarge
        : rows == 2 ? (columns >= 2 ? TileSize.Large : TileSize.Tall)
        : columns >= 3 && gridColumns >= 3 ? TileSize.Banner
        : columns >= 2 ? TileSize.Medium
        : TileSize.Small;
}

/// Canonical JSON helpers so unknown properties on synced pins, pages, and root documents survive round-trips intact.
internal static class TileExtraJson
{
    public static string? Capture(JsonNode? node, HashSet<string> known)
    {
        if (node is not JsonObject obj) return null;
        JsonObject? extra = null;
        foreach (var (k, v) in obj.OrderBy(p => p.Key, StringComparer.Ordinal))
        {
            if (known.Contains(k)) continue;
            extra ??= new JsonObject();
            extra[k] = CloneCanonical(v);
        }
        return extra == null ? null : extra.ToJsonString();
    }

    public static void ApplyTo(JsonObject target, string? extraJson)
    {
        if (string.IsNullOrEmpty(extraJson)) return;
        JsonNode? parsed;
        try { parsed = JsonNode.Parse(extraJson); }
        catch (JsonException) { return; }
        if (parsed is not JsonObject extra) return;
        foreach (var (k, v) in extra) target[k] = v?.DeepClone();
    }

    private static JsonNode? CloneCanonical(JsonNode? node) => node switch
    {
        null => null,
        JsonObject o => new JsonObject(o.OrderBy(p => p.Key, StringComparer.Ordinal)
            .Select(p => KeyValuePair.Create(p.Key, CloneCanonical(p.Value)))),
        JsonArray a => new JsonArray(a.Select(CloneCanonical).ToArray()),
        _ => node.DeepClone(),
    };
}

/// What kind of thing a tile shows (`ArtifactRecord.Kind`).
public enum TileKind { Image, File, Link }

/// One pinned artifact: a file, image or link on one bot's computer (`ArtifactPin`). Its JSON is the Swift app's
/// Codable form, so the gateway's synced copy reads the same on the Mac, the iPhone and here. Unknown fields and
/// unknown future size raw strings are preserved across sync round-trips.
public sealed record TilePin
{
    private static readonly HashSet<string> KnownKeys =
    [
        "id", "kind", "value", "label", "profile", "sessionId", "sessionTitle", "pinnedAt",
        "size", "page", "title", "pageTitle", "jobId", "version", "chatAt",
    ];

    /// `"<profile>\u001F<value>"`.
    public required string Id { get; init; }
    public TileKind Kind { get; init; }
    public required string Value { get; init; }
    public string Label { get; init; } = "";
    public string Profile { get; init; } = "default";
    public string SessionId { get; init; } = "";
    public string SessionTitle { get; init; } = "";
    /// Seconds since 1970.
    public double PinnedAt { get; init; }
    public TileSize? Size { get; init; }
    /// Preserved raw `"size"` string when a newer build wrote a size this build doesn't know yet.
    public string? RawSize { get; init; }
    public string? Page { get; init; }
    public string? Title { get; init; }
    public string? PageTitle { get; init; }
    public string? JobId { get; init; }
    public int? Version { get; init; }
    public double? ChatAt { get; init; }
    /// Canonical JSON of any unknown properties preserved from a newer build's synced document.
    private string? ExtraJson { get; init; }

    public TileSize TileSize => Size ?? Insights.TileSize.Small;

    public static string Key(string? profile, string value)
    {
        var p = (profile ?? "").Trim();
        return (p.Length == 0 ? "default" : p) + "\u001F" + value;
    }

    public static TilePin Make(TileKind kind, string value, string label, string? profile, string sessionId = "", string sessionTitle = "",
        double? pinnedAt = null)
    {
        var owner = string.IsNullOrEmpty(profile) ? "default" : profile;
        return new TilePin
        {
            Id = Key(owner, value), Kind = kind, Value = value, Label = label.Length == 0 ? TileFiles.Label(value, kind) : label,
            Profile = owner, SessionId = sessionId, SessionTitle = sessionTitle,
            PinnedAt = pinnedAt ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
        };
    }

    /// Its name in plain words: the owner's, the page's title, else the file name in words (a link keeps its label).
    public string Name => !string.IsNullOrEmpty(Title) ? Title! : AutomaticName;

    public string AutomaticName => !string.IsNullOrEmpty(PageTitle) ? PageTitle! : Kind == TileKind.Link ? Label : TileNames.Pretty(Label);

    public bool NamedByFile => string.IsNullOrEmpty(Title) && string.IsNullOrEmpty(PageTitle) && Kind != TileKind.Link;

    /// An HTML page (pictured, and opened live).
    public bool IsPage => Kind == TileKind.File && TileFiles.Extension(Value) is "html" or "htm";

    /// A path on the bot's computer the app can read straight (absolute, `~/`, or `file://`).
    public string? GatewayPath
    {
        get
        {
            if (Kind == TileKind.Link || Value.StartsWith("http://") || Value.StartsWith("https://") || Value.StartsWith("data:")) return null;
            if (Value.StartsWith("file://")) return Uri.TryCreate(Value, UriKind.Absolute, out var u) ? Uri.UnescapeDataString(u.AbsolutePath) : null;
            return Value;
        }
    }

    // ------------------------------------------------------------------ JSON (Swift Codable keys)

    public JsonObject ToJson()
    {
        var o = new JsonObject();
        TileExtraJson.ApplyTo(o, ExtraJson);
        o["id"] = Id;
        o["kind"] = Kind.ToString().ToLowerInvariant();
        o["value"] = Value;
        o["label"] = Label;
        o["profile"] = Profile;
        o["sessionId"] = SessionId;
        o["sessionTitle"] = SessionTitle;
        o["pinnedAt"] = PinnedAt;
        if (Size is { } s) o["size"] = s.Raw();
        else if (!string.IsNullOrEmpty(RawSize)) o["size"] = RawSize;
        else o.Remove("size");
        if (Page != null) o["page"] = Page; else o.Remove("page");
        if (Title != null) o["title"] = Title; else o.Remove("title");
        if (PageTitle != null) o["pageTitle"] = PageTitle; else o.Remove("pageTitle");
        if (JobId != null) o["jobId"] = JobId; else o.Remove("jobId");
        if (Version != null) o["version"] = Version; else o.Remove("version");
        if (ChatAt != null) o["chatAt"] = ChatAt; else o.Remove("chatAt");
        return o;
    }

    public static TilePin? FromJson(JsonNode? n)
    {
        var value = n.Str("value");
        if (string.IsNullOrEmpty(value)) return null;
        var kind = n.Str("kind") switch { "image" => TileKind.Image, "link" => TileKind.Link, "file" => TileKind.File, _ => (TileKind?)null };
        if (kind == null) return null;
        var profile = n.Text("profile") ?? "default";
        var rawSize = n.Str("size");
        var parsedSize = TileSizes.FromRaw(rawSize);
        return new TilePin
        {
            Id = n.Text("id") ?? Key(profile, value), Kind = kind.Value, Value = value, Label = n.Str("label") ?? TileFiles.Label(value, kind.Value),
            Profile = profile, SessionId = n.Str("sessionId") ?? "", SessionTitle = n.Str("sessionTitle") ?? "",
            PinnedAt = n.Num("pinnedAt") ?? 0, Size = parsedSize,
            RawSize = parsedSize == null && !string.IsNullOrEmpty(rawSize) ? rawSize : null,
            Page = n.Str("page"), Title = n.Str("title"),
            PageTitle = n.Str("pageTitle"), JobId = n.Str("jobId"), Version = (int?)n.Int("version"), ChatAt = n.Num("chatAt"),
            ExtraJson = TileExtraJson.Capture(n, KnownKeys),
        };
    }
}

/// One page of the Tiles (`DashboardPage`): Main is always there and first.
public sealed record TilePage(string Id, string Name, string? Symbol = null)
{
    private static readonly HashSet<string> KnownKeys = ["id", "name", "symbol"];

    public const string MainId = "main";
    public static readonly TilePage Main = new(MainId, "Main");

    /// Curated SF Symbols offered for Dashboard pages (matching Mac `DashboardPage.symbolChoices`).
    public static readonly (string Symbol, string Label)[] SymbolChoices =
    [
        ("rectangle.3.group", "Default"),
        ("chart.bar.fill", "Metrics"),
        ("briefcase.fill", "Work"),
        ("house.fill", "Home"),
        ("calendar", "Schedule"),
        ("dollarsign.circle.fill", "Finance"),
        ("chevron.left.forwardslash.chevron.right", "Code"),
        ("heart.fill", "Health"),
        ("bolt.fill", "Ops"),
        ("star.fill", "Starred"),
        ("globe", "News"),
        ("tray.full.fill", "Inbox"),
    ];

    /// Unknown JSON fields preserved across sync round-trips.
    private string? ExtraJson { get; init; }

    public JsonObject ToJson()
    {
        var o = new JsonObject();
        TileExtraJson.ApplyTo(o, ExtraJson);
        o["id"] = Id;
        o["name"] = Name;
        if (!string.IsNullOrEmpty(Symbol)) o["symbol"] = Symbol;
        else o.Remove("symbol");
        return o;
    }

    public static TilePage? FromJson(JsonNode? n)
    {
        if (n.Text("id") is not { } id) return null;
        return new TilePage(id, n.Str("name") ?? id, n.Text("symbol"))
        {
            ExtraJson = TileExtraJson.Capture(n, KnownKeys),
        };
    }
}

/// Where Grid's tiles go (`PinGridPacking`): in order, each in the first place from the top where its span fits.
public static class TileGridPacking
{
    public readonly record struct Cell(int Column, int Row, int Columns, int Rows);

    public static (List<Cell> Cells, int Rows) Place(IEnumerable<(int Columns, int Rows)> spans, int columns)
    {
        var width = Math.Max(1, columns);
        var taken = new List<bool[]>();
        var cells = new List<Cell>();
        bool Free(int c, int r, int across, int down)
        {
            for (var y = r; y < r + down && y < taken.Count; y++)
                for (var x = c; x < c + across; x++)
                    if (taken[y][x]) return false;
            return true;
        }
        foreach (var span in spans)
        {
            int across = Math.Min(Math.Max(1, span.Columns), width), down = Math.Max(1, span.Rows);
            for (var row = 0; ; row++)
            {
                var placed = false;
                for (var column = 0; column <= width - across; column++)
                {
                    if (!Free(column, row, across, down)) continue;
                    while (taken.Count < row + down) taken.Add(new bool[width]);
                    for (var y = row; y < row + down; y++) for (var x = column; x < column + across; x++) taken[y][x] = true;
                    cells.Add(new Cell(column, row, across, down));
                    placed = true;
                    break;
                }
                if (placed) break;
            }
        }
        return (cells, taken.Count);
    }

    /// How many cells across `width`, and their side (`gridMetrics`): 150 or more, 190 on a wider pane.
    public static (int Columns, double Cell) Metrics(double width, double spacing, double scale = 1)
    {
        var least = (width >= 560 ? 190 : 150) * Math.Max(1, scale);
        var columns = Math.Max(2, (int)((width + spacing) / (least + spacing)));
        return (columns, Math.Floor((width - (columns - 1) * spacing) / columns));
    }
}

/// How tiles show: picture tiles in a grid, cards with their names and chats, or rows (`PinsView`).
public enum TilesView { Grid, Cards, List }

/// The pins of one gateway account and the Tiles' pages (`ArtifactPins`), kept in a file on this PC and, through
/// `TileSync`, on the gateway for every device. Not thread-safe: the page uses it from the UI thread.
public sealed class TilePinStore
{
    /// The most pins kept.
    public const int Limit = 120;

    private static readonly HashSet<string> KnownRootKeys = ["pins", "pages", "current"];
    private static readonly HashSet<string> KnownSyncKeys = ["pins", "pages"];

    private readonly string? _path;
    private List<TilePin> _pins = [];
    private List<TilePage> _pages = [TilePage.Main];
    private string _current = TilePage.MainId;
    private string? _extraRootJson;
    private HashSet<string>? _clashes;

    /// After any change (the page redraws; the sync writes).
    public event Action? Changed;

    public TilePinStore(string? path)
    {
        _path = path;
        if (path != null && File.Exists(path))
        {
            var root = J.Parse(File.ReadAllText(path));
            Load(root);
            StartedEmpty = _pins.Count == 0;
        }
        else StartedEmpty = true;
    }

    /// Nothing of its own on disk: it meets the gateway's copy as a new device does.
    public bool StartedEmpty { get; }

    /// The file for an account: `<dir>/<sha256(account)[..16]>.json`, as the Swift app names it.
    public static string FileFor(string directory, string accountId)
    {
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(accountId))).ToLowerInvariant()[..16];
        return Path.Combine(directory, hash + ".json");
    }

    public IReadOnlyList<TilePin> Pins => _pins;
    public IReadOnlyList<TilePage> Pages => _pages;
    public bool IsFull => _pins.Count >= Limit;

    public string CurrentPage
    {
        get => _current;
        set
        {
            var next = _pages.Any(p => p.Id == value) ? value : TilePage.MainId;
            if (next == _current) return;
            _current = next;
            Save();
        }
    }

    private void Load(JsonNode? root)
    {
        _pins = [.. (root.Arr("pins") ?? []).Select(TilePin.FromJson).OfType<TilePin>()];
        var pages = (root.Arr("pages") ?? []).Select(TilePage.FromJson).OfType<TilePage>().ToList();
        _pages = Normalized(pages);
        var cur = root.Str("current");
        _current = cur != null && _pages.Any(p => p.Id == cur) ? cur : TilePage.MainId;
        _extraRootJson = TileExtraJson.Capture(root, KnownRootKeys);
        _clashes = null;
    }

    private static List<TilePage> Normalized(List<TilePage> pages)
    {
        var main = pages.FirstOrDefault(p => p.Id == TilePage.MainId) ?? TilePage.Main;
        return [main, .. pages.Where(p => p.Id != TilePage.MainId)];
    }

    private void Save()
    {
        _clashes = null;
        if (_path != null)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
                var o = new JsonObject();
                TileExtraJson.ApplyTo(o, _extraRootJson);
                o["pins"] = new JsonArray([.. _pins.Select(p => (JsonNode)p.ToJson())]);
                o["pages"] = new JsonArray([.. _pages.Select(p => (JsonNode)p.ToJson())]);
                o["current"] = _current;
                File.WriteAllText(_path, o.ToJsonString());
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        Changed?.Invoke();
    }

    /// A pin's name as every list shows it: pins named by their files that read the same keep their extensions.
    public string Name(TilePin pin)
    {
        _clashes ??= TileNames.Clashing(_pins.Select(p => (p.Id, p.Name, p.NamedByFile)));
        return _clashes.Contains(pin.Id) ? TileNames.Pretty(pin.Label, keepsExtension: true) : pin.Name;
    }

    public string PageId(TilePin pin) => pin.Page is { } p && _pages.Any(x => x.Id == p) ? p : TilePage.MainId;
    public IEnumerable<TilePin> OnPage(string page) => _pins.Where(p => PageId(p) == page);
    public bool IsPinned(string? profile, string value) => _pins.Any(p => p.Id == TilePin.Key(profile, value));

    /// Pins it first; false when it's refused (full). Already pinned counts as pinned.
    public bool Pin(TilePin pin)
    {
        if (_pins.Any(p => p.Id == pin.Id)) return true;
        if (IsFull) return false;
        if (pin.Page == null && _current != TilePage.MainId) pin = pin with { Page = _current };
        _pins.Insert(0, pin);
        Save();
        return true;
    }

    /// An unpin undone: the pin as it was, where it was.
    public void Restore(TilePin pin, int index)
    {
        if (_pins.Any(p => p.Id == pin.Id) || IsFull) return;
        _pins.Insert(Math.Clamp(index, 0, _pins.Count), pin);
        Save();
    }

    public void Unpin(string id)
    {
        if (_pins.RemoveAll(p => p.Id == id) > 0) Save();
    }

    public int IndexOf(string id) => _pins.FindIndex(p => p.Id == id);

    /// A tile dragged onto another's place: it takes that place, the others moving up or down one.
    public void Move(string id, string target)
    {
        int from = IndexOf(id), to = IndexOf(target);
        if (from < 0 || to < 0 || from == to) return;
        var moved = _pins[from];
        _pins.RemoveAt(from);
        _pins.Insert(Math.Clamp(to, 0, _pins.Count), moved);
        Save();
    }

    private void Update(string id, Func<TilePin, TilePin> change)
    {
        var i = IndexOf(id);
        if (i < 0) return;
        var next = change(_pins[i]);
        if (next == _pins[i]) return;
        _pins[i] = next;
        Save();
    }

    public void SetSize(TileSize size, string id) =>
        Update(id, p => p.TileSize == size && p.RawSize == null ? p : p with { Size = size, RawSize = null });

    /// Rename…: the owner's name for it; empty goes back to the automatic one.
    public void Rename(string id, string name)
    {
        var words = string.Join(' ', name.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        Update(id, p => p with { Title = words.Length == 0 ? null : words });
    }

    /// What its page's head said when it was last read (its title, its job).
    public void NotePage(string id, TileNames.Head head) =>
        Update(id, p => p.PageTitle == head.Title && p.JobId == head.JobId ? p : p with { PageTitle = head.Title, JobId = head.JobId });

    /// Records the version number the tile now shows (`ArtifactPins.noteVersion`).
    public void NoteVersion(string id, int number) =>
        Update(id, p => p.Version == number ? p : p with { Version = number });

    // ------------------------------------------------------------------ pages

    public TilePage AddPage(string name, string? symbol = null)
    {
        var words = name.Trim();
        var cleanSymbol = string.IsNullOrWhiteSpace(symbol) ? null : symbol.Trim();
        var page = new TilePage(Guid.NewGuid().ToString().ToUpperInvariant(), words.Length == 0 ? $"Page {_pages.Count + 1}" : words, cleanSymbol);
        _pages.Add(page);
        _current = page.Id;
        Save();
        return page;
    }

    public void RenamePage(string id, string name)
    {
        var words = name.Trim();
        var i = _pages.FindIndex(p => p.Id == id);
        if (words.Length == 0 || i < 0 || _pages[i].Name == words) return;
        _pages[i] = _pages[i] with { Name = words };
        Save();
    }

    /// Sets or clears a Dashboard page's icon symbol (`DashboardPage.symbol`).
    public void SetPageSymbol(string id, string? symbol)
    {
        var clean = string.IsNullOrWhiteSpace(symbol) ? null : symbol.Trim();
        var i = _pages.FindIndex(p => p.Id == id);
        if (i < 0 || _pages[i].Symbol == clean) return;
        _pages[i] = _pages[i] with { Symbol = clean };
        Save();
    }

    /// A page moved one place left (-1) or right (+1); Main stays first.
    public void MovePage(string id, int step)
    {
        var i = _pages.FindIndex(p => p.Id == id);
        if (i < 1) return;
        var target = i + step;
        if (target < 1 || target >= _pages.Count) return;
        (_pages[i], _pages[target]) = (_pages[target], _pages[i]);
        Save();
    }

    /// Moves a non-Main page to another non-Main page's index.
    public void ReorderPage(string id, string targetId)
    {
        if (id == TilePage.MainId || targetId == TilePage.MainId || id == targetId) return;
        var from = _pages.FindIndex(p => p.Id == id);
        var to = _pages.FindIndex(p => p.Id == targetId);
        if (from < 1 || to < 1) return;
        var moved = _pages[from];
        _pages.RemoveAt(from);
        _pages.Insert(Math.Clamp(to, 1, _pages.Count), moved);
        Save();
    }

    /// A page deleted: its tiles go to Main, nothing unpinned. Main can't be deleted.
    public void DeletePage(string id)
    {
        var i = _pages.FindIndex(p => p.Id == id);
        if (id == TilePage.MainId || i < 0) return;
        _pages.RemoveAt(i);
        for (var k = 0; k < _pins.Count; k++) if (_pins[k].Page == id) _pins[k] = _pins[k] with { Page = null };
        if (_current == id) _current = _pages[Math.Max(0, i - 1)].Id;
        Save();
    }

    /// A tile moved to another page (the end of that page's tiles).
    public void SetPage(string page, string id)
    {
        var i = IndexOf(id);
        if (i < 0 || PageId(_pins[i]) == page || !_pages.Any(p => p.Id == page)) return;
        var pin = _pins[i] with { Page = page == TilePage.MainId ? null : page };
        _pins.RemoveAt(i);
        var last = _pins.FindLastIndex(p => PageId(p) == page);
        _pins.Insert(last >= 0 ? last + 1 : _pins.Count, pin);
        Save();
    }

    // ------------------------------------------------------------------ sync (`GatewaySynced`, document "pins")

    public JsonObject SyncValue()
    {
        var o = new JsonObject();
        TileExtraJson.ApplyTo(o, _extraRootJson);
        o["pins"] = new JsonArray([.. _pins.Select(p => (JsonNode)p.ToJson())]);
        o["pages"] = new JsonArray([.. _pages.Select(p => (JsonNode)p.ToJson())]);
        o.Remove("current");
        return o;
    }

    public void AdoptSynced(JsonNode? value, TileSyncMerge merge, JsonNode? baseValue)
    {
        if (value is not JsonObject) return;
        var remotePins = (value.Arr("pins") ?? []).Select(TilePin.FromJson).OfType<TilePin>().ToList();
        var remotePages = Normalized([.. (value.Arr("pages") ?? []).Select(TilePage.FromJson).OfType<TilePage>()]);
        var remoteExtra = TileExtraJson.Capture(value, KnownSyncKeys);
        switch (merge)
        {
            case TileSyncMerge.Replace:
                _pins = remotePins;
                _pages = remotePages;
                _extraRootJson = remoteExtra;
                break;
            case TileSyncMerge.FirstContact:
            {
                var ids = remotePins.Select(p => p.Id).ToHashSet();
                _pins = [.. remotePins.Concat(_pins.Where(p => !ids.Contains(p.Id))).Take(Limit)];
                var pageIds = remotePages.Select(p => p.Id).ToHashSet();
                _pages = [.. remotePages, .. _pages.Where(p => !pageIds.Contains(p.Id))];
                if (remoteExtra != null) _extraRootJson = remoteExtra;
                break;
            }
            default:
            {
                var wasPins = (baseValue.Arr("pins") ?? []).Select(TilePin.FromJson).OfType<TilePin>().ToList();
                var wasPages = (baseValue.Arr("pages") ?? []).Select(TilePage.FromJson).OfType<TilePage>().ToList();
                _pins = Merged(remotePins, _pins, wasPins, p => p.Id);
                _pages = Merged(remotePages, _pages, wasPages, p => p.Id);
                if (_pins.Count > Limit) _pins.RemoveRange(Limit, _pins.Count - Limit);
                if (remoteExtra != null) _extraRootJson = remoteExtra;
                break;
            }
        }
        _pages = Normalized(_pages);
        if (!_pages.Any(p => p.Id == _current)) _current = TilePage.MainId;
        Save();
    }

    /// A three-way merge by id: `remote`'s order, less what `local` dropped since `base`, with what `local` added first
    /// and `local`'s version of an item it changed.
    public static List<T> Merged<T>(List<T> remote, List<T> local, List<T> baseList, Func<T, string> id)
    {
        var baseById = new Dictionary<string, T>();
        foreach (var b in baseList) baseById.TryAdd(id(b), b);
        var localById = new Dictionary<string, T>();
        foreach (var l in local) localById.TryAdd(id(l), l);
        var remoteIds = remote.Select(id).ToHashSet();
        var dropped = baseById.Keys.Where(k => !localById.ContainsKey(k)).ToHashSet();
        var output = local.Where(l => !baseById.ContainsKey(id(l)) && !remoteIds.Contains(id(l))).ToList();
        foreach (var item in remote)
        {
            var key = id(item);
            if (dropped.Contains(key)) continue;
            if (localById.TryGetValue(key, out var mine) && baseById.TryGetValue(key, out var was) && !EqualityComparer<T>.Default.Equals(mine, was))
                output.Add(mine);
            else output.Add(item);
        }
        return output;
    }
}

/// Removed artifacts (`ArtifactHidden`): a pinned one is unpinned and stays gone, in every chat that names it. Keyed
/// as a pin is. Document "hidden" on the gateway: the newest 400, joined, never replaced.
public sealed class TileHidden
{
    public const int Limit = 5000, SyncedLimit = 400;
    private readonly string? _path;
    private List<string> _order = [];
    private HashSet<string> _keys = [];
    public event Action? Changed;

    public TileHidden(string? path)
    {
        _path = path;
        if (path != null && File.Exists(path) && J.Parse(File.ReadAllText(path)) is JsonArray a)
            _order = [.. a.Select(J.AsString).OfType<string>()];
        _keys = [.. _order];
    }

    public bool IsHidden(TilePin pin) => _keys.Contains(pin.Id);
    public IEnumerable<TilePin> Visible(IEnumerable<TilePin> pins) => _keys.Count == 0 ? pins : pins.Where(p => !_keys.Contains(p.Id));

    public void Hide(string key, TilePinStore? pins = null)
    {
        pins?.Unpin(key);
        if (!_keys.Add(key)) return;
        _order.Add(key);
        Trim();
        Save();
    }

    private void Trim()
    {
        if (_order.Count <= Limit) return;
        foreach (var gone in _order.Take(_order.Count - Limit)) _keys.Remove(gone);
        _order.RemoveRange(0, _order.Count - Limit);
    }

    private void Save()
    {
        if (_path != null)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
                File.WriteAllText(_path, new JsonArray([.. _order.Select(k => (JsonNode)k)]).ToJsonString());
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        Changed?.Invoke();
    }

    public JsonArray SyncValue() => new([.. _order.Skip(Math.Max(0, _order.Count - SyncedLimit)).Select(k => (JsonNode)k)]);

    public void AdoptSynced(JsonNode? value)
    {
        var remote = (value as JsonArray ?? []).Select(J.AsString).OfType<string>().Where(k => !_keys.Contains(k)).ToList();
        if (remote.Count == 0) return;
        _order = [.. remote, .. _order];
        _keys.UnionWith(remote);
        Trim();
        Save();
    }
}
