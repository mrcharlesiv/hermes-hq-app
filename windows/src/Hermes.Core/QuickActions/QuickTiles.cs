using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Composer;

namespace Hermes.Core.QuickActions;

// [quick-actions] The Quick Actions page's saved tiles and first-run starter set (docs/spec/3x-morepages.md §25,
// docs/spec/3x-intents.md DECISION I22): a port of the pure parts of HermesKit/Intents/QuickTiles.swift that own the
// list on this device — what a tile is, how the list is stored (`hqn.quickActions`, versioned), the edits, the starter
// set, and what a tile says under its name. Where a tap goes (QuickTileRoute), missing targets (QuickTileRules) and the
// grid (QuickTileGrid) are not here.

/// What a tile does. Stored by its raw value (QuickTileKinds.Raw); a kind this build doesn't know is kept and drawn
/// switched off.
public enum QuickTileKind { NewChat, Memo, Talk, Send, OpenChat, AddTask, RunJob, Page, Search }

/// The tile colours (`accent` is the theme's tint).
public enum QuickTileColor { Accent, Red, Orange, Yellow, Green, Teal, Indigo, Pink, Gray }

public static class QuickTileKinds
{
    public static string Raw(this QuickTileKind kind) => kind switch
    {
        QuickTileKind.NewChat => "new-chat",
        QuickTileKind.Memo => "memo",
        QuickTileKind.Talk => "talk",
        QuickTileKind.Send => "send",
        QuickTileKind.OpenChat => "open-chat",
        QuickTileKind.AddTask => "add-task",
        QuickTileKind.RunJob => "run-job",
        QuickTileKind.Page => "page",
        _ => "search",
    };

    /// The kind for a stored raw value; null for one this build doesn't know.
    public static QuickTileKind? Parse(string? raw) =>
        Enum.GetValues<QuickTileKind>().Cast<QuickTileKind?>().FirstOrDefault(k => k!.Value.Raw() == raw);

    /// Done in the background: the page stays open and says what happened.
    public static bool StaysOnPage(this QuickTileKind kind) => kind == QuickTileKind.RunJob;

    public static bool NeedsBot(this QuickTileKind kind) =>
        kind is QuickTileKind.NewChat or QuickTileKind.Memo or QuickTileKind.Talk or QuickTileKind.Send or QuickTileKind.OpenChat;

    /// The name a new tile of this kind is given (the setup form's Name starts with it).
    public static string DefaultName(this QuickTileKind kind, string? bot, string? job, string? page) => kind switch
    {
        QuickTileKind.NewChat => "New Chat",
        QuickTileKind.Memo => "Memo",
        QuickTileKind.Talk => "Talk",
        QuickTileKind.Send => "Message",
        QuickTileKind.OpenChat => string.IsNullOrEmpty(bot) ? "Open Chat" : bot,
        QuickTileKind.AddTask => "Add Task",
        QuickTileKind.RunJob => string.IsNullOrEmpty(job) ? "Run Job" : job,
        QuickTileKind.Page => string.IsNullOrEmpty(page) ? "Page" : page,
        _ => "Search Chats",
    };

    /// The icon (the Mac's SF Symbol name, as stored) and colour a new tile of this kind starts with.
    public static (string Symbol, QuickTileColor Color) DefaultLook(this QuickTileKind kind) => kind switch
    {
        QuickTileKind.NewChat => ("square.and.pencil", QuickTileColor.Accent),
        QuickTileKind.Memo => ("mic.fill", QuickTileColor.Red),
        QuickTileKind.Talk => ("waveform", QuickTileColor.Green),
        QuickTileKind.Send => ("paperplane.fill", QuickTileColor.Indigo),
        QuickTileKind.OpenChat => ("bubble.left.fill", QuickTileColor.Green),
        QuickTileKind.AddTask => ("checklist", QuickTileColor.Teal),
        QuickTileKind.RunJob => ("bolt.fill", QuickTileColor.Orange),
        QuickTileKind.Page => ("square.grid.2x2.fill", QuickTileColor.Gray),
        _ => ("magnifyingglass", QuickTileColor.Gray),
    };

    public static string Raw(this QuickTileColor color) => color.ToString().ToLowerInvariant();

    public static QuickTileColor? ParseColor(string? raw) =>
        Enum.GetValues<QuickTileColor>().Cast<QuickTileColor?>().FirstOrDefault(c => c!.Value.Raw() == raw);
}

/// One tile (QuickTile in the Swift). Fields a kind doesn't use stay null.
public sealed record QuickTile
{
    public required string Id { get; init; }
    /// QuickTileKind's raw value, kept as written: a newer build's kind survives this build's edits.
    public required string Kind { get; init; }
    public string Name { get; init; } = "";
    public string Symbol { get; init; } = "square.grid.2x2.fill";
    /// QuickTileColor's raw value.
    public string Color { get; init; } = "gray";
    public bool Wide { get; init; }
    public bool Short { get; init; }
    /// The bot's profile, and its name when the tile was set up (said when the bot isn't on this gateway).
    public string? Bot { get; init; }
    public string? BotName { get; init; }
    /// New Chat's project: its key (folder) and name.
    public string? Project { get; init; }
    public string? ProjectName { get; init; }
    /// New Chat's first message, or Send a Message's words.
    public string? Message { get; init; }
    /// New Chat: send the first message (on) or leave it in the box. Send a Message: open the chat (on) or send it in
    /// the background.
    public bool? Flag { get; init; }
    /// Run Job's job (`<owner>|<id>`) and its name.
    public string? Job { get; init; }
    public string? JobName { get; init; }
    /// A page's More row id, and its title.
    public string? Page { get; init; }
    public string? PageName { get; init; }
    /// The saved Dashboard pin id and its name when added, even on builds that can't open that kind.
    public string? Pin { get; init; }
    public string? PinName { get; init; }
    /// A stored entry this build could not read at all, as canonical JSON text: kept, written back as it was, and
    /// drawn switched off.
    public string? Unreadable { get; init; }
    // Unknown fields only. A record copy shares immutable text, never a mutable node with a parent.
    private string? ExtraJson { get; init; }

    // Swift compares the values, not their Unicode spelling. Keep that spelling for the next real edit.
    public bool Equals(QuickTile? other)
    {
        if (ReferenceEquals(this, other)) return true;
        static bool Same(string? a, string? b) => QuickTileJson.Text.Equals(a, b);
        return other != null && Wide == other.Wide && Short == other.Short && Flag == other.Flag &&
            Same(Id, other.Id) && Same(Kind, other.Kind) && Same(Name, other.Name) && Same(Symbol, other.Symbol) &&
            Same(Color, other.Color) && Same(Bot, other.Bot) && Same(BotName, other.BotName) &&
            Same(Project, other.Project) && Same(ProjectName, other.ProjectName) && Same(Message, other.Message) &&
            Same(Job, other.Job) && Same(JobName, other.JobName) && Same(Page, other.Page) && Same(PageName, other.PageName) &&
            Same(Pin, other.Pin) && Same(PinName, other.PinName) &&
            QuickTileJson.SameValue(ExtraJson, other.ExtraJson) && QuickTileJson.SameValue(Unreadable, other.Unreadable);
    }

    public override int GetHashCode() => QuickTileJson.Text.GetHashCode(Id);

    public QuickTileKind? Known => Unreadable == null ? QuickTileKinds.Parse(Kind) : null;
    public QuickTileColor Tint => QuickTileKinds.ParseColor(Color) ?? QuickTileColor.Gray;

    /// A new tile of `kind`, with its default name and look (QuickTile.init(id:kind:...)). The id is a fresh UUID.
    public static QuickTile Create(QuickTileKind kind, string? id = null, string? name = null, string? symbol = null,
        QuickTileColor? color = null, bool wide = false) => new()
        {
            Id = id ?? Guid.NewGuid().ToString().ToUpperInvariant(),
            Kind = kind.Raw(),
            Name = name ?? kind.DefaultName(null, null, null),
            Symbol = symbol ?? kind.DefaultLook().Symbol,
            Color = (color ?? kind.DefaultLook().Color).Raw(),
            Wide = wide,
        };

    /// An entry that can't be read as a tile (QuickTile.init(unreadable:)).
    public static QuickTile FromUnreadable(JsonNode? raw)
    {
        var canonical = QuickTileJson.Canonical(raw);
        return new QuickTile
        {
            Id = StringOf(raw.Get("id")) ?? StableID(canonical),
            Kind = StringOf(raw.Get("kind")) ?? "unknown",
            Name = StringOf(raw.Get("name")) ?? "Unknown Action",
            Symbol = "questionmark.square.dashed",
            Color = QuickTileColor.Gray.Raw(),
            Wide = raw.Get("wide") is JsonValue w && w.GetValueKind() is JsonValueKind.True,
            Short = raw.Get("short") is JsonValue s && s.GetValueKind() is JsonValueKind.True,
            Unreadable = canonical,
        };
    }

    private static string? StringOf(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    /// The same id for the same stored bytes on every read (FNV-1a over the entry's sorted JSON), so an entry without a
    /// readable id can still be removed or moved. (Stable on this PC; not promised to equal the Mac's in-memory id.)
    private static string StableID(string canonical)
    {
        ulong hash = 0xcbf29ce484222325;
        foreach (var b in Encoding.UTF8.GetBytes(canonical))
        {
            hash ^= b;
            hash = unchecked(hash * 0x00000100000001b3);
        }
        return "unreadable-" + hash.ToString("x");
    }

    /// Reads a stored entry as a tile, strictly as the Swift decoder does (wrong types fail); null when it can't.
    internal static QuickTile? Read(JsonElement row)
    {
        if (row.ValueKind != JsonValueKind.Object) return null;
        // Only consume keys in our own dictionary. The source row remains available for the unreadable fallback.
        var remaining = QuickTileJson.Fields(row);
        JsonElement Take(string key) => remaining.Remove(key, out var value) ? value : default;
        bool ok = true;
        string? Opt(string key)
        {
            var v = Take(key);
            if (v.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null;
            if (v.ValueKind == JsonValueKind.String) return v.GetString();
            ok = false;
            return null;
        }
        bool? OptBool(string key)
        {
            var v = Take(key);
            if (v.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null;
            if (v.ValueKind is JsonValueKind.True or JsonValueKind.False) return v.GetBoolean();
            ok = false;
            return null;
        }
        var id = Opt("id");
        var kind = Opt("kind");
        if (id == null || kind == null) return null;
        var tile = new QuickTile
        {
            Id = id,
            Kind = kind,
            Name = Opt("name") ?? "",
            Symbol = Opt("symbol") ?? "square.grid.2x2.fill",
            Color = Opt("color") ?? QuickTileColor.Gray.Raw(),
            Wide = OptBool("wide") ?? false,
            Short = OptBool("short") ?? false,
            Bot = Opt("bot"),
            BotName = Opt("botName"),
            Project = Opt("project"),
            ProjectName = Opt("projectName"),
            Message = Opt("message"),
            Flag = OptBool("flag"),
            Job = Opt("job"),
            JobName = Opt("jobName"),
            Page = Opt("page"),
            PageName = Opt("pageName"),
            Pin = Opt("pin"),
            PinName = Opt("pinName"),
        };
        if (!ok) return null;
        if (remaining.Count == 0) return tile;
        // Swift's optional JSONValue decode drops the extras as a group if one isn't representable.
        try { return tile with { ExtraJson = QuickTileJson.Canonical(QuickTileJson.Object(remaining)) }; }
        catch (Exception e) when (e is JsonException or InvalidOperationException) { return tile; }
    }

    /// Keep unreadable rows whole. On readable rows, only true size flags and non-null known optionals are written.
    internal JsonNode? ToJson()
    {
        if (Unreadable != null) return JsonNode.Parse(Unreadable, documentOptions: QuickTileJson.ReadOptions);
        var o = ExtraJson == null ? new JsonObject() : JsonNode.Parse(ExtraJson, documentOptions: QuickTileJson.ReadOptions)!.AsObject();
        o["id"] = Id;
        o["kind"] = Kind;
        o["name"] = Name;
        o["symbol"] = Symbol;
        o["color"] = Color;
        if (Wide) o["wide"] = true;
        if (Short) o["short"] = true;
        void Put(string key, string? value) { if (value != null) o[key] = value; }
        Put("bot", Bot);
        Put("botName", BotName);
        Put("project", Project);
        Put("projectName", ProjectName);
        Put("message", Message);
        if (Flag is { } flag) o["flag"] = flag;
        Put("job", Job);
        Put("jobName", JobName);
        Put("page", Page);
        Put("pageName", PageName);
        Put("pin", Pin);
        Put("pinName", PinName);
        return o;
    }

    /// What the tile does, in a few words under its name ("to otto", "in Site", "run job").
    public string Subtitle(string? currentBotName)
    {
        var who = currentBotName ?? BotName ?? Bot ?? "";
        return Known switch
        {
            QuickTileKind.Memo => $"to {who}",
            QuickTileKind.Talk => $"with {who}",
            QuickTileKind.NewChat => (ProjectName ?? Project) is { Length: > 0 } project ? $"in {project}" : $"with {who}",
            QuickTileKind.Send => Flag == true ? $"with {who}" : $"asks {who}",
            QuickTileKind.OpenChat => $"chat with {who}",
            QuickTileKind.AddTask => Bot == null ? "for me" : $"for {who}",
            QuickTileKind.RunJob => "run job",
            QuickTileKind.Page => "page",
            QuickTileKind.Search => "all chats",
            _ => "needs a newer app",
        };
    }
}

/// The page's tiles on this device (QuickTileList). A value: use Copy() before editing a list someone else holds.
public sealed class QuickTileList : IEquatable<QuickTileList>
{
    private readonly List<QuickTile> _tiles;

    public QuickTileList() : this([], false) { }

    public QuickTileList(IEnumerable<QuickTile> tiles, bool seeded)
    {
        _tiles = tiles.ToList();
        Seeded = seeded;
    }

    public IReadOnlyList<QuickTile> Tiles => _tiles;
    /// The starter set was offered once (or the person changed the list): never seeded again.
    public bool Seeded { get; set; }

    public QuickTileList Copy() => new(_tiles, Seeded);

    public void Add(QuickTile tile) => _tiles.Add(tile);

    public void Replace(QuickTile tile)
    {
        var index = _tiles.FindIndex(t => t.Id == tile.Id);
        if (index >= 0) _tiles[index] = tile; else _tiles.Add(tile);
    }

    public void Remove(string id) => _tiles.RemoveAll(t => t.Id == id);

    public void SetWide(string id, bool wide)
    {
        var index = _tiles.FindIndex(t => t.Id == id);
        if (index >= 0) _tiles[index] = _tiles[index] with { Wide = wide };
    }

    /// Moves the tile to `index` (clamped).
    public void Move(string id, int index)
    {
        var from = _tiles.FindIndex(t => t.Id == id);
        if (from < 0) return;
        var tile = _tiles[from];
        _tiles.RemoveAt(from);
        _tiles.Insert(Math.Max(0, Math.Min(index, _tiles.Count)), tile);
    }

    /// One step earlier (-1) or later (+1); false at an end.
    public bool Step(string id, int delta)
    {
        var from = _tiles.FindIndex(t => t.Id == id);
        var to = from + delta;
        if (from < 0 || to < 0 || to >= _tiles.Count) return false;
        (_tiles[from], _tiles[to]) = (_tiles[to], _tiles[from]);
        return true;
    }

    /// The tiles in `order` (ids); any not named keep their place after them (none is ever dropped).
    public void Reorder(IEnumerable<string> order)
    {
        var byID = new Dictionary<string, QuickTile>();
        foreach (var t in _tiles) byID.TryAdd(t.Id, t);
        var next = new List<QuickTile>();
        foreach (var id in order)
            if (byID.Remove(id, out var t)) next.Add(t);
        next.AddRange(_tiles.Where(t => byID.ContainsKey(t.Id)));
        _tiles.Clear();
        _tiles.AddRange(next);
    }

    public bool Equals(QuickTileList? other) =>
        other != null && Seeded == other.Seeded && _tiles.SequenceEqual(other._tiles);

    public override bool Equals(object? obj) => Equals(obj as QuickTileList);

    public override int GetHashCode() => HashCode.Combine(Seeded, _tiles.Count);
}

/// The list's place on this device (QuickTileStore): JSON text under `hqn.quickActions` in an IKeyValueStore.
public static class QuickTileStore
{
    public const string Key = "hqn.quickActions";
    /// A stored list this build could not read is copied here once, before anything is written over it.
    public const string UnreadableKey = "hqn.quickActions.unreadable";
    public const int Version = 1;
    /// The page's own More row id (and its tab's page id): never a tile of itself.
    public const string RowID = "quick-actions";

    /// The stored envelope `{version, seeded?, tiles}`; null when it can't be read as one. Entries that can't be read
    /// as tiles are kept as unreadable tiles.
    public static QuickTileList? Decode(string text) => Decode(text, out _);

    private static QuickTileList? Decode(string text, out long? version)
    {
        version = null;
        try
        {
            using var doc = JsonDocument.Parse(text, QuickTileJson.ReadOptions);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
            var fields = QuickTileJson.Fields(doc.RootElement);
            version = ReadVersion(fields.GetValueOrDefault("version"));
            if (version == null) return null;
            var seeded = fields.GetValueOrDefault("seeded");
            var rows = fields.GetValueOrDefault("tiles");
            if (rows.ValueKind != JsonValueKind.Array || seeded.ValueKind is not
                (JsonValueKind.True or JsonValueKind.False or JsonValueKind.Undefined or JsonValueKind.Null)) return null;
            var tiles = rows.EnumerateArray().Select(e => QuickTile.Read(e) ?? QuickTile.FromUnreadable(QuickTileJson.Value(e))).ToList();
            return new QuickTileList(tiles, seeded.ValueKind is JsonValueKind.True or JsonValueKind.False ? seeded.GetBoolean() : tiles.Count > 0);
        }
        // GetString (including a property name) rejects an unpaired JSON surrogate with InvalidOperationException.
        catch (Exception e) when (e is JsonException or InvalidOperationException) { return null; }
    }

    /// An integer `version` (Swift decodes it as Int); null when missing or not one.
    private static long? ReadVersion(JsonElement v)
    {
        if (v.ValueKind != JsonValueKind.Number) return null;
        if (v.TryGetInt64(out var integer)) return integer; // never round an integer version through Double
        var d = v.GetDouble();
        if (!double.IsInteger(d) || d < long.MinValue || d >= (double)long.MaxValue) return null;
        if (Math.Abs(d) < (1L << 53)) return (long)d;

        // Beyond Double's consecutive integers, Foundation rescales the decimal significand as UInt64.
        // Ignore trailing zeroes; do not round a fractional token up, or admit a significand too large to read.
        var digits = QuickTileJson.Mantissa(v).TrimStart('-').ToString().Replace(".", "").TrimEnd('0');
        // The signed magnitude must fit before negation. The plain Int64 minimum already took the integer path.
        if (!ulong.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out _) ||
            !v.TryGetDecimal(out var m) || m <= long.MinValue) return null;
        return (long)m;
    }

    public static string? Encode(QuickTileList list, long version = Version)
    {
        var tiles = new JsonArray();
        foreach (var t in list.Tiles) tiles.Add(t.ToJson());
        try { return QuickTileJson.Canonical(new JsonObject { ["version"] = version, ["seeded"] = list.Seeded, ["tiles"] = tiles }); }
        catch (InvalidOperationException) { return null; } // exceeds the encoder's nesting limit: don't overwrite the list
    }

    public static QuickTileList Load(IKeyValueStore store)
    {
        if (store.Get(Key) is not { } text) return new QuickTileList();
        if (Decode(text) is { } list) return list;
        // Unreadable as a whole: kept aside (never wiped), and the starter set is not offered over it.
        if (store.Get(UnreadableKey) == null) store.Set(UnreadableKey, text);
        return new QuickTileList([], seeded: true);
    }

    /// Stores `list` (marking the stored copy seeded: the person has a list now). Returns whether it changed.
    public static bool Save(QuickTileList list, IKeyValueStore store)
    {
        var next = list.Copy();
        next.Seeded = true;
        var current = store.Get(Key);
        long? version = null;
        var stored = current == null ? null : Decode(current, out version);
        if (next.Equals(stored)) return false;
        if (current != null && stored == null && store.Get(UnreadableKey) == null) store.Set(UnreadableKey, current);
        // A newer build's version number stays (its entries were kept as written).
        if (Encode(next, Math.Max(version ?? Version, Version)) is not { } text) return false;
        store.Set(Key, text);
        return true;
    }

    /// The list to show: the stored one, or the starter set the first time there's a bot to make it for. An unknown
    /// first bot (the roster hasn't answered) seeds nothing yet. Returns the list and whether it was just seeded (the
    /// caller saves it).
    public static (QuickTileList List, bool Seeded) ListToShow(QuickTileList stored, (string Profile, string Name)? firstBot)
    {
        if (stored.Tiles.Count > 0 || stored.Seeded || firstBot is not { } bot) return (stored, false);
        return (new QuickTileList(Starter(bot.Profile, bot.Name), seeded: true), true);
    }

    /// Voice Memo, Talk, New Chat (wide), Add Task and Search Chats, for the roster's first bot.
    public static IReadOnlyList<QuickTile> Starter(string bot, string name)
    {
        QuickTile ForBot(QuickTile t) => t with { Bot = bot, BotName = name };
        return
        [
            ForBot(QuickTile.Create(QuickTileKind.Memo, id: "starter-memo")),
            ForBot(QuickTile.Create(QuickTileKind.Talk, id: "starter-talk")),
            ForBot(QuickTile.Create(QuickTileKind.NewChat, id: "starter-new-chat", wide: true)) with { Flag = true },
            QuickTile.Create(QuickTileKind.AddTask, id: "starter-add-task"),
            QuickTile.Create(QuickTileKind.Search, id: "starter-search"),
        ];
    }
}

/// JSON written as the Mac's JSONEncoder with .sortedKeys writes it: compact, keys in order, whole numbers as integers.
internal static class QuickTileJson
{
    // Foundation reads up to 512 nested containers, but encodes at most 511.
    internal static readonly JsonDocumentOptions ReadOptions = new() { MaxDepth = 512 };
    private static readonly JsonWriterOptions Options = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, MaxDepth = 511 };

    // Swift String equality is ordinal after canonical normalization, not linguistic/case-insensitive comparison.
    // U+FFFE is valid in JSON but .NET refuses to normalize it. It cannot compose across either neighbor.
    private static string TextKey(string text) => text.Contains('\uFFFE')
        ? string.Join('\uFFFE', text.Split('\uFFFE').Select(s => s.Normalize())) : text.Normalize();

    internal static readonly IEqualityComparer<string> Text = EqualityComparer<string>.Create(
        (a, b) => a == b || a != null && b != null && TextKey(a) == TextKey(b),
        s => TextKey(s).GetHashCode(StringComparison.Ordinal));

    // Keep the first spelling and value. In particular, never decode the value of an equivalent later key:
    // it might not be representable, while the retained object and its siblings are perfectly readable.
    internal static Dictionary<string, JsonElement> Fields(JsonElement value)
    {
        var fields = new Dictionary<string, JsonElement>(Text);
        foreach (var p in value.EnumerateObject()) fields.TryAdd(p.Name, p.Value);
        return fields;
    }

    internal static JsonObject Object(Dictionary<string, JsonElement> fields) =>
        new(fields.Select(p => KeyValuePair.Create(p.Key, Value(p.Value))));

    internal static ReadOnlySpan<char> Mantissa(JsonElement number)
    {
        var text = number.GetRawText().AsSpan();
        int e = text.IndexOfAny('e', 'E');
        return e < 0 ? text : text[..e];
    }

    private static bool CanReadDouble(JsonElement number)
    {
        var d = number.GetDouble();
        // JSONDecoder rejects both overflow and nonzero magnitudes rounded to zero, but accepts literal zero.
        return double.IsFinite(d) && (d != 0 || !Mantissa(number).ContainsAnyInRange('1', '9'));
    }

    internal static JsonNode? Value(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.Object => Object(Fields(value)),
        JsonValueKind.Array => new JsonArray(value.EnumerateArray().Select(Value).ToArray()),
        JsonValueKind.Number when !CanReadDouble(value) => throw new JsonException("Number not representable as a JSONValue"),
        _ => JsonValue.Create(value.Clone()),
    };

    internal static bool SameValue(string? a, string? b)
    {
        if (a == b) return true; // copies and ordinary reloads; no reparse on redraw
        if (a == null || b == null) return false;
        try
        {
            using var left = JsonDocument.Parse(a, ReadOptions);
            using var right = JsonDocument.Parse(b, ReadOptions);
            return SameValue(left.RootElement, right.RootElement);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException) { return false; }
    }

    private static bool SameValue(JsonElement a, JsonElement b)
    {
        if (a.ValueKind != b.ValueKind) return false;
        switch (a.ValueKind)
        {
            case JsonValueKind.Object:
                var right = Fields(b);
                foreach (var p in a.EnumerateObject())
                    if (!right.Remove(p.Name, out var v) || !SameValue(p.Value, v)) return false;
                return right.Count == 0;
            case JsonValueKind.Array:
                if (a.GetArrayLength() != b.GetArrayLength()) return false;
                var items = b.EnumerateArray();
                foreach (var item in a.EnumerateArray())
                {
                    items.MoveNext();
                    if (!SameValue(item, items.Current)) return false;
                }
                return true;
            case JsonValueKind.String: return Text.Equals(a.GetString(), b.GetString());
            case JsonValueKind.Number: return a.GetDouble() == b.GetDouble();
            default: return true; // null, true or false: the kind identifies the value
        }
    }

    public static string Canonical(JsonNode? node)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, Options)) Write(writer, node);
        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    private static void Write(Utf8JsonWriter w, JsonNode? node)
    {
        switch (node)
        {
            case null: w.WriteNullValue(); break;
            case JsonObject o:
                w.WriteStartObject();
                foreach (var (key, value) in o.OrderBy(p => p.Key, StringComparer.Ordinal))
                {
                    w.WritePropertyName(key);
                    Write(w, value);
                }
                w.WriteEndObject();
                break;
            case JsonArray a:
                w.WriteStartArray();
                foreach (var e in a) Write(w, e);
                w.WriteEndArray();
                break;
            case JsonValue v:
                switch (v.GetValueKind())
                {
                    case JsonValueKind.String: w.WriteStringValue(v.GetValue<string>()); break;
                    case JsonValueKind.True: w.WriteBooleanValue(true); break;
                    case JsonValueKind.False: w.WriteBooleanValue(false); break;
                    case JsonValueKind.Number:
                        // The envelope's version is a typed Int64; opaque JSONValue numbers are Doubles.
                        if (!v.TryGetValue(out JsonElement number)) { v.WriteTo(w); break; }
                        double d = number.GetDouble();
                        if (Math.Round(d) == d && Math.Abs(d) < 9.007e15) w.WriteNumberValue((long)d);
                        else if (double.IsFinite(d)) w.WriteNumberValue(d);
                        else w.WriteNullValue();
                        break;
                    default: w.WriteNullValue(); break;
                }
                break;
        }
    }
}
