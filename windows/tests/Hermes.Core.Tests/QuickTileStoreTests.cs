// [quick-actions] The Quick Actions page's saved tiles and first-run starter set: a port of the Mac's
// Tests/Intents/QuickTilesTests.swift (QuickTileStoreTests, QuickTileSeedingTests, QuickTileListTests), plus the
// envelope's field defaults, unreadable rows and raw data, and a temporary on-disk store. Synthetic data only.
using System.Text.Json.Nodes;
using Hermes.Core.Composer;
using Hermes.Core.QuickActions;

namespace Hermes.Core.Tests;

public class QuickTileStoreTests
{
    private static QuickTile Tile(QuickTileKind kind, string? id = null, string? bot = null, bool wide = false) =>
        QuickTile.Create(kind, id: id ?? Guid.NewGuid().ToString(), wide: wide) with
        {
            Bot = bot,
            BotName = bot == null ? null : char.ToUpperInvariant(bot[0]) + bot[1..],
        };

    private static JsonObject Raw(IKeyValueStore store) =>
        (JsonObject)JsonNode.Parse(store.Get(QuickTileStore.Key) ?? "null")!;

    // ---- Q7: stored per device, versioned, read back as written ----

    [Fact]
    public void AListIsStoredAndReadBack()
    {
        var box = new MemoryStore();
        var list = new QuickTileList();
        list.Add(Tile(QuickTileKind.NewChat, "a", "otto", wide: true) with
        {
            Project = "/Users/me/site", ProjectName = "Site", Message = "Morning", Flag = false,
        });
        list.Add(Tile(QuickTileKind.Memo, "b", "ivy"));
        Assert.True(QuickTileStore.Save(list, box));
        var back = QuickTileStore.Load(box);
        Assert.Equal(list.Tiles, back.Tiles);
        Assert.True(back.Seeded, "a saved list is never seeded over");
        Assert.False(QuickTileStore.Save(back, box), "the same list writes nothing");
        Assert.Equal(QuickTileStore.Version, (int)Raw(box)["version"]!);
        Assert.Equal(1, QuickTileStore.Version);
        Assert.Equal("hqn.quickActions", QuickTileStore.Key);
        Assert.Equal("hqn.quickActions.unreadable", QuickTileStore.UnreadableKey);
        Assert.Equal("quick-actions", QuickTileStore.RowID);
    }

    // The envelope the Mac writes: version, seeded, tiles; sorted keys; Wide only when on; unused fields left out.
    [Fact]
    public void TheEnvelopeIsWrittenAsTheMacWritesIt()
    {
        var list = new QuickTileList();
        list.Add(QuickTile.Create(QuickTileKind.Search, id: "s"));
        list.Add(QuickTile.Create(QuickTileKind.Memo, id: "m", wide: true) with { Bot = "otto", Flag = true });
        var text = QuickTileStore.Encode(list)!;
        Assert.Equal(
            "{\"seeded\":false,\"tiles\":[" +
            "{\"color\":\"gray\",\"id\":\"s\",\"kind\":\"search\",\"name\":\"Search Chats\",\"symbol\":\"magnifyingglass\"}," +
            "{\"bot\":\"otto\",\"color\":\"red\",\"flag\":true,\"id\":\"m\",\"kind\":\"memo\",\"name\":\"Memo\",\"symbol\":\"mic.fill\",\"wide\":true}" +
            "],\"version\":1}", text);
        Assert.Contains("\"version\":7", QuickTileStore.Encode(list, version: 7));
    }

    // A tile's name, symbol and colour fill in when missing (as the Swift decoder does).
    [Fact]
    public void MissingFieldsTakeTheMacsDefaults()
    {
        var list = QuickTileStore.Decode("""
            {"version":1,"tiles":[{"id":"x","kind":"talk","extra":{"a":1},"bot":null}]}
            """)!;
        var tile = Assert.Single(list.Tiles);
        Assert.Null(tile.Unreadable);
        Assert.Equal(("", "square.grid.2x2.fill", "gray", false), (tile.Name, tile.Symbol, tile.Color, tile.Wide));
        Assert.Null(tile.Bot);
        Assert.Equal(QuickTileKind.Talk, tile.Known);
        Assert.Equal(QuickTileColor.Gray, tile.Tint);
        Assert.True(list.Seeded, "tiles without the flag mean it was seeded");
        Assert.Equal(QuickTileColor.Gray, (tile with { Color = "plaid" }).Tint);
    }

    // The default name and look each kind starts with (QuickTileKind.defaultName / defaultLook).
    [Fact]
    public void EachKindStartsWithItsMacNameAndLook()
    {
        var expected = new (QuickTileKind Kind, string Raw, string Name, string Symbol, QuickTileColor Color)[]
        {
            (QuickTileKind.NewChat, "new-chat", "New Chat", "square.and.pencil", QuickTileColor.Accent),
            (QuickTileKind.Memo, "memo", "Memo", "mic.fill", QuickTileColor.Red),
            (QuickTileKind.Talk, "talk", "Talk", "waveform", QuickTileColor.Green),
            (QuickTileKind.Send, "send", "Message", "paperplane.fill", QuickTileColor.Indigo),
            (QuickTileKind.OpenChat, "open-chat", "Open Chat", "bubble.left.fill", QuickTileColor.Green),
            (QuickTileKind.AddTask, "add-task", "Add Task", "checklist", QuickTileColor.Teal),
            (QuickTileKind.RunJob, "run-job", "Run Job", "bolt.fill", QuickTileColor.Orange),
            (QuickTileKind.Page, "page", "Page", "square.grid.2x2.fill", QuickTileColor.Gray),
            (QuickTileKind.Search, "search", "Search Chats", "magnifyingglass", QuickTileColor.Gray),
        };
        Assert.Equal(28, Enum.GetValues<QuickTileKind>().Length);
        foreach (var e in expected)
        {
            var tile = QuickTile.Create(e.Kind, id: "t");
            Assert.Equal((e.Raw, e.Name, e.Symbol, e.Color.Raw()), (tile.Kind, tile.Name, tile.Symbol, tile.Color));
            Assert.Equal(e.Kind, QuickTileKinds.Parse(e.Raw));
        }
        Assert.Equal("otto", QuickTileKind.OpenChat.DefaultName("otto", null, null));
        Assert.Equal("Open Chat", QuickTileKind.OpenChat.DefaultName("", null, null));
        Assert.Equal("Brief", QuickTileKind.RunJob.DefaultName(null, "Brief", null));
        Assert.Equal("Files", QuickTileKind.Page.DefaultName(null, null, "Files"));
        Assert.True(QuickTileKind.RunJob.StaysOnPage());
        Assert.False(QuickTileKind.Send.StaysOnPage());
        Assert.Contains(QuickTileKind.NewChat, Enum.GetValues<QuickTileKind>().Where(k => k.NeedsBot()));
        Assert.Contains(QuickTileKind.Memo, Enum.GetValues<QuickTileKind>().Where(k => k.NeedsBot()));
        Assert.Contains(QuickTileKind.Talk, Enum.GetValues<QuickTileKind>().Where(k => k.NeedsBot()));
        Assert.Contains(QuickTileKind.Send, Enum.GetValues<QuickTileKind>().Where(k => k.NeedsBot()));
        Assert.Contains(QuickTileKind.OpenChat, Enum.GetValues<QuickTileKind>().Where(k => k.NeedsBot()));
        Assert.Equal(["accent", "red", "orange", "yellow", "green", "teal", "indigo", "pink", "gray"],
            Enum.GetValues<QuickTileColor>().Select(c => c.Raw()));
        Assert.False(Guid.TryParse("starter-memo", out _));
        Assert.True(Guid.TryParse(QuickTile.Create(QuickTileKind.Memo).Id, out _), "a new tile gets a fresh UUID");
    }

    // ---- Q7: a kind this build doesn't know, or an entry it can't read, is kept as written ----

    private sealed class CountingStore : IKeyValueStore
    {
        private readonly MemoryStore _store = new();
        public CountingStore(string raw) => _store.Set(QuickTileStore.Key, raw);
        public int Writes { get; private set; }
        public string? Get(string key) => _store.Get(key);
        public void Set(string key, string? value) { Writes++; _store.Set(key, value); }
    }

    [Fact]
    public void MovingAnotherTileChangesOnlyTheOrder()
    {
        const string original = """
            {"version":7,"seeded":true,"tiles":[
              {"id":"compact","kind":"page","name":"Files","symbol":"folder","color":"gray","page":"files","short":true,"future":{"nested":[[true,null],{"off":false}]}},
              {"id":"picture","kind":"dashboard-tile","name":"Example","symbol":"chart","color":"accent","pin":"example-pin","pinName":"Example","meta":{"level":2}},
              {"id":"newer","kind":"future-kind","name":"New","symbol":"star","color":"gray","options":["sample",false],"empty":null},
              {"id":"broken","kind":"page","name":123,"option":{"note":"keep"}},
              {"id":"control","kind":"new-chat","name":"Other","symbol":"square","color":"gray","wide":true}
            ]}
            """;
        var box = new CountingStore(original);
        var list = QuickTileStore.Load(box);
        Assert.False(QuickTileStore.Save(list.Copy(), box));
        Assert.Equal(original, box.Get(QuickTileStore.Key));
        Assert.Equal(0, box.Writes);

        var edit = list.Copy();
        Assert.True(edit.Step("control", -1));
        Assert.True(QuickTileStore.Save(edit, box));
        var expected = JsonNode.Parse(original)!;
        var rows = expected["tiles"]!.AsArray();
        var control = rows[4];
        rows.RemoveAt(4);
        rows.Insert(3, control);
        Assert.True(JsonNode.DeepEquals(expected, Raw(box)), "all five rows and envelope fields survive the move");
        var reopened = QuickTileStore.Load(box);
        Assert.Equal(edit, reopened);
        Assert.True(reopened.Seeded);
        Assert.Equal(QuickTileKind.DashboardTile, reopened.Tiles[1].Known);
        Assert.Null(reopened.Tiles[2].Known);
        Assert.NotNull(reopened.Tiles[4].Unreadable);
        Assert.Equal("control", list.Tiles[^1].Id);
        Assert.False(QuickTileStore.Save(reopened, box));
        Assert.Equal(1, box.Writes);
    }

    [Fact]
    public void FutureFieldsHaveValueEqualityAcrossCopiesAndIndependentLoads()
    {
        static CountingStore Store(string nested) => new($$"""
            {"version":7,"tiles":[{"id":"a","kind":"search","future":{{nested}}}]}
            """);
        var box = Store("""{"a":1,"b":[{"flag":false},null]}""");
        var original = QuickTileStore.Load(box);
        var equivalent = QuickTileStore.Load(Store("""{"b":[{"flag":false},null],"a":1.0}"""));
        Assert.Equal(original, equivalent);
        Assert.False(QuickTileStore.Save(equivalent.Copy(), box));
        Assert.Equal(0, box.Writes);

        var changed = QuickTileStore.Load(Store("""{"a":1,"b":[{"flag":true},null]}"""));
        Assert.NotEqual(original, changed);
        Assert.True(QuickTileStore.Save(changed, box));
        Assert.True((bool)Raw(box)["tiles"]![0]!["future"]!["b"]![0]!["flag"]!);
        Assert.True(QuickTileStore.Save(original.Copy(), box));
        Assert.False((bool)Raw(box)["tiles"]![0]!["future"]!["b"]![0]!["flag"]!);
        Assert.False(QuickTileStore.Save(original, box));
        Assert.Equal(2, box.Writes);
    }

    [Fact]
    public void EquivalentNestedTextDoesNotWriteOrChangeTheStoredSpelling()
    {
        static CountingStore Store(string key, string value) => new($$$"""
            {"version":7,"tiles":[{"id":"a","kind":"later","meta":[{"{{{key}}}":"{{{value}}}","f":false}]}]}
            """);
        var box = Store("é", "Café");
        var raw = box.Get(QuickTileStore.Key);
        var original = QuickTileStore.Load(box);
        var copy = QuickTileStore.Load(Store("e\u0301", "Cafe\u0301")).Copy();
        Assert.Equal(original.Tiles[0], copy.Tiles[0]);
        Assert.Equal(original.Tiles[0].GetHashCode(), copy.Tiles[0].GetHashCode());
        Assert.False(QuickTileStore.Save(copy, box));
        Assert.Equal(raw, box.Get(QuickTileStore.Key));
        Assert.Equal(0, box.Writes);

        copy.SetWide("a", true);
        Assert.True(QuickTileStore.Save(copy, box));
        var meta = Raw(box)["tiles"]![0]!["meta"]![0]!.AsObject();
        Assert.False(meta.ContainsKey("é"));
        Assert.Equal("Cafe\u0301", (string?)meta["e\u0301"]);
        var different = QuickTileStore.Load(Store("e\u0301", "Cafe"));
        different.SetWide("a", true);
        Assert.True(QuickTileStore.Save(different, box));
        Assert.Equal("Cafe", (string?)Raw(box)["tiles"]![0]!["meta"]![0]!["e\u0301"]);
        Assert.False(QuickTileStore.Save(QuickTileStore.Load(box), box));
        Assert.Equal(2, box.Writes);
    }

    [Theory]
    [InlineData("\"pin\":\"$\",\"pinName\":\"$\"")]
    [InlineData("\"short\":\"bad\",\"name\":\"$\",\"meta\":{\"$\":true}")]
    [InlineData("\"meta\":[{\"$\\ufffe$\":\"$\\ufffe$\"}]")]
    public void EquivalentTextInAPinRawRowOrFutureKeyIsNotAnEdit(string fields)
    {
        var raw = $$"""{"version":7,"tiles":[{"id":"kept","kind":"page",{{fields}}}]}""";
        var box = new CountingStore(raw.Replace("$", "가"));
        var list = QuickTileStore.Load(new CountingStore(raw.Replace("$", "\u1100\u1161")));
        var first = Assert.Single(QuickTileStore.Load(box).Tiles);
        Assert.Equal(first, Assert.Single(list.Tiles));
        Assert.False(QuickTileStore.Save(list, box));
        Assert.Equal(raw.Replace("$", "가"), box.Get(QuickTileStore.Key));
        Assert.Equal(0, box.Writes);
    }

    [Theory]
    [InlineData("page", "café", "cafe\u0301", "2", "1e400", true)]
    [InlineData("later", "café", "cafe\u0301", "2", "1e400", true)]
    [InlineData("page", "cafe\u0301", "café", "1e400", "2", false)]
    [InlineData("later", "cafe\u0301", "café", "2", "1", true)]
    public void AReorderKeepsTheFirstEquivalentKeyWithoutReadingTheDiscardedValue(
        string kind, string first, string second, string a, string b, bool retained)
    {
        var original = $$$"""
            {"version":7,"tiles":[{"id":"kept","kind":"{{{kind}}}","short":true,"meta":[{"{{{first}}}":{{{a}}},"{{{second}}}":{{{b}}}}],"other":[null,false]},{"id":"control","kind":"search"}]}
            """;
        var box = new CountingStore(original);
        var list = QuickTileStore.Load(box);
        Assert.False(QuickTileStore.Save(list.Copy(), box));
        Assert.Equal(original, box.Get(QuickTileStore.Key));
        Assert.True(list.Step("control", -1));
        Assert.True(QuickTileStore.Save(list, box));
        var row = Raw(box)["tiles"]![1]!.AsObject();
        Assert.Equal("kept", (string?)row["id"]);
        Assert.Equal(retained, row.ContainsKey("meta"));
        Assert.Equal(retained, row.ContainsKey("other"));
        if (retained)
        {
            var member = Assert.Single(row["meta"]![0]!.AsObject());
            Assert.Equal(first, member.Key); // preserve spelling, not just canonical equivalence
            Assert.Equal(2, (int)member.Value!);
            Assert.True(JsonNode.DeepEquals(JsonNode.Parse("[null,false]"), row["other"]));
        }
        Assert.False(QuickTileStore.Save(QuickTileStore.Load(box), box));
        Assert.Equal(1, box.Writes);
    }

    [Fact]
    public void EditingATileKeepsItsExtrasButNeverRestoresClearedKnownFields()
    {
        const string original = """
            {"version":7,"tiles":[
              {"id":"a","kind":"page","page":"files","short":true,"flag":false,"pin":"first","pinName":"First","meta":[[null],{"v":false}]},
              {"id":"b","kind":"dashboard-tile","short":false,"pin":"otto\u001ffile","pinName":"Picture"},
              {"id":"c","kind":"later","short":null,"pin":null,"pinName":null,"Short":false},
              {"id":"d","kind":"search"}
            ]}
            """;
        var box = new CountingStore(original);
        var list = QuickTileStore.Load(box);
        Assert.Equal([true, false, false, false], list.Tiles.Select(t => t.Short));
        Assert.Equal(("first", "First"), (list.Tiles[0].Pin, list.Tiles[0].PinName));
        Assert.False(QuickTileStore.Save(list, box));
        Assert.Equal(original, box.Get(QuickTileStore.Key)); // explicit false, null and missing stay distinct on a no-op

        var edit = list.Copy();
        edit.Replace(edit.Tiles[0] with { Name = "Renamed", Short = false, Pin = null, PinName = "" });
        edit.SetWide("c", true);
        Assert.True(QuickTileStore.Save(edit, box));
        var rows = Raw(box)["tiles"]!.AsArray();
        Assert.All(rows, row => Assert.False(row!.AsObject().ContainsKey("short")));
        Assert.False(rows[0]!.AsObject().ContainsKey("pin"));
        Assert.Equal("", (string?)rows[0]!["pinName"]);
        Assert.False((bool)rows[0]!["flag"]!);
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(original)!["tiles"]![0]!["meta"], rows[0]!["meta"]));
        Assert.Equal(("otto\u001ffile", "Picture"), ((string?)rows[1]!["pin"], (string?)rows[1]!["pinName"]));
        Assert.False(rows[2]!.AsObject().ContainsKey("pin"));
        Assert.False(rows[2]!.AsObject().ContainsKey("pinName"));
        Assert.False((bool)rows[2]!["Short"]!); // different spelling, not a size flag
        Assert.True((bool)rows[2]!["wide"]!);
        Assert.Equal(edit, QuickTileStore.Load(box));
        Assert.True(list.Tiles[0].Short);
        Assert.False(QuickTileStore.Save(edit, box));
        Assert.Equal(1, box.Writes);
    }

    [Theory]
    [InlineData("\"short\":\"true\"", false)]
    [InlineData("\"short\":0", false)]
    [InlineData("\"short\":true,\"pin\":false", true)]
    [InlineData("\"short\":true,\"pinName\":[]", true)]
    public void MalformedHeightOrPinKeepsTheEntireRowUnreadable(string fields, bool fallbackShort)
    {
        var box = new CountingStore($$"""
            {"version":7,"seeded":false,"tiles":[{"id":"bad","kind":"page","wide":true,"extra":[null,{}],{{fields}}}]}
            """);
        var raw = Raw(box)["tiles"]![0];
        var list = QuickTileStore.Load(box);
        var tile = Assert.Single(list.Tiles);
        Assert.NotNull(tile.Unreadable);
        Assert.Null(tile.Known);
        Assert.True(tile.Wide);
        Assert.Equal(fallbackShort, tile.Short);
        Assert.True(QuickTileStore.Save(list, box)); // marks the stored copy seeded
        Assert.False(list.Seeded);
        Assert.True(JsonNode.DeepEquals(raw, Raw(box)["tiles"]![0]));
        Assert.True(QuickTileStore.Load(box).Seeded);
        Assert.False(QuickTileStore.Save(list, box));
        Assert.Equal(1, box.Writes);
    }

    [Theory]
    [InlineData("""{"level":2,"level":1e400}""", """{"level":2}""")]
    [InlineData("[1e400]", null)]
    [InlineData("{\"n\":1e-400}", null)]
    [InlineData("{\"n\":-1e-324}", null)]
    [InlineData("{\"n\":-0.00e-400}", "{\"n\":0}")]
    [InlineData("{\"n\":5e-324}", "{\"n\":5e-324}")]
    [InlineData("\"\\ud800\"", null)]
    public void FutureValuesUseTheMacsJsonValueFallback(string future, string? retained)
    {
        var box = new CountingStore($$"""{"version":7,"tiles":[{"id":"s","kind":"search","future":{{future}},"other":false}]}""");
        var list = QuickTileStore.Load(box);
        Assert.Equal(QuickTileKind.Search, Assert.Single(list.Tiles).Known);
        Assert.False(QuickTileStore.Save(list, box));
        list.SetWide("s", true);
        Assert.True(QuickTileStore.Save(list, box));
        var row = Raw(box)["tiles"]![0]!.AsObject();
        Assert.Equal(retained != null, row.ContainsKey("future"));
        Assert.Equal(retained != null, row.ContainsKey("other"));
        if (retained != null) Assert.True(JsonNode.DeepEquals(JsonNode.Parse(retained), row["future"]));
        Assert.Equal(list, QuickTileStore.Load(box));
        Assert.Equal(1, box.Writes);
    }

    [Theory]
    [InlineData("\"short\":0,\"future\":1e400")]
    [InlineData("\"short\":\"bad\",\"meta\":{\"n\":1e-400}")]
    [InlineData("\"pin\":\"\\ud800\"")]
    public void WhenEvenTheRawRowCannotDecodeTheOriginalListIsBackedUp(string fields)
    {
        var raw = $$"""{"version":7,"tiles":[{"id":"x","kind":"page",{{fields}}}]}""";
        var box = new CountingStore(raw);
        var list = QuickTileStore.Load(box);
        Assert.Empty(list.Tiles);
        Assert.True(list.Seeded);
        Assert.Equal(raw, box.Get(QuickTileStore.Key));
        Assert.Equal(raw, box.Get(QuickTileStore.UnreadableKey));
        Assert.Equal(1, box.Writes); // one backup; Load never touched the primary value
        Assert.Empty(QuickTileStore.Load(box).Tiles);
        Assert.Equal(1, box.Writes);
        Assert.True(QuickTileStore.Save(list, box));
        Assert.Equal(7, (int)Raw(box)["version"]!);
        Assert.Equal(raw, box.Get(QuickTileStore.UnreadableKey));
        Assert.False(QuickTileStore.Save(QuickTileStore.Load(box), box));
        Assert.Equal(2, box.Writes);
    }

    [Theory]
    [InlineData(64, true)]
    [InlineData(508, true)]
    [InlineData(509, false)]
    public void DeeplyNestedFutureValuesAreSavedOrTheOriginalIsLeftAlone(int depth, bool encodable)
    {
        var nested = new string('[', depth) + "false" + new string(']', depth);
        var raw = $$"""{"version":7,"tiles":[{"id":"a","kind":"search","future":{{nested}}}]}""";
        var box = new CountingStore(raw);
        var list = QuickTileStore.Load(box);
        Assert.Equal(QuickTileKind.Search, Assert.Single(list.Tiles).Known);
        list.SetWide("a", true);
        Assert.Equal(encodable, QuickTileStore.Save(list, box));
        if (encodable)
        {
            Assert.Contains("\"future\":" + nested, box.Get(QuickTileStore.Key));
            Assert.Equal(list, QuickTileStore.Load(box));
        }
        else Assert.Equal(raw, box.Get(QuickTileStore.Key));
        Assert.Equal(encodable ? 1 : 0, box.Writes);
    }

    [Fact]
    public void UnknownKindsAndUnreadableEntriesAreKept()
    {
        var box = new MemoryStore();
        box.Set(QuickTileStore.Key, """
            {"version":3,"seeded":true,"tiles":[
              {"id":"a","kind":"memo","name":"Memo","symbol":"mic.fill","color":"red","bot":"ivy"},
              {"id":"b","kind":"teleport","name":"Beam Me","symbol":"sparkles","color":"pink","where":"orbit"},
              {"id":7,"name":"Broken"}
            ]}
            """);
        var list = QuickTileStore.Load(box);
        Assert.Equal(["Memo", "Beam Me", "Broken"], list.Tiles.Select(t => t.Name));
        Assert.Equal(QuickTileKind.Memo, list.Tiles[0].Known);
        Assert.True(list.Tiles[1].Known == null && list.Tiles[1].Kind == "teleport");
        Assert.True(list.Tiles[2].Unreadable != null && list.Tiles[2].Known == null);
        Assert.Equal("needs a newer app", list.Tiles[1].Subtitle(null));
        Assert.Equal("questionmark.square.dashed", list.Tiles[2].Symbol);
        Assert.Equal("unknown", list.Tiles[2].Kind);
        // An edit elsewhere keeps both: the newer build's version and the unreadable entry's own bytes.
        list.SetWide("a", true);
        Assert.True(QuickTileStore.Save(list, box));
        var raw = Raw(box);
        Assert.Equal(3, (int)raw["version"]!);
        var tiles = raw["tiles"]!.AsArray();
        Assert.Equal(7, (int)tiles[2]!["id"]!);
        Assert.Equal("teleport", (string)tiles[1]!["kind"]!);
        Assert.True((bool)tiles[0]!["wide"]!);
        Assert.Equal(["a", "b"], QuickTileStore.Load(box).Tiles.Take(2).Select(t => t.Id));
    }

    // Wrong types, nulls and non-objects are kept raw (never dropped, never rewritten), with ids that stay the same.
    [Fact]
    public void UnreadableRowsKeepTheirRawDataAndAStableID()
    {
        var box = new MemoryStore();
        const string stored = """
            {"version":1,"tiles":[
              {"id":"ok","kind":"search"},
              {"id":"w","kind":"memo","wide":"yes","nested":{"z":[1,2.5,null],"a":"é/"}},
              null,
              "just words",
              {"kind":"talk","name":"No ID"}
            ]}
            """;
        box.Set(QuickTileStore.Key, stored);
        var first = QuickTileStore.Load(box);
        Assert.Equal(5, first.Tiles.Count);
        Assert.Null(first.Tiles[0].Unreadable);
        Assert.All(first.Tiles.Skip(1), t => Assert.NotNull(t.Unreadable));
        Assert.Equal("w", first.Tiles[1].Id);
        Assert.Equal("memo", first.Tiles[1].Kind);
        Assert.False(first.Tiles[1].Wide, "a non-bool wide reads as off");
        Assert.Equal("No ID", first.Tiles[4].Name);
        Assert.Equal("Unknown Action", first.Tiles[2].Name);
        foreach (var t in first.Tiles.Skip(2)) Assert.StartsWith("unreadable-", t.Id);
        Assert.Equal(3, first.Tiles.Skip(2).Select(t => t.Id).Distinct().Count());
        // The same bytes give the same ids on every read.
        Assert.Equal(first.Tiles.Select(t => t.Id), QuickTileStore.Load(box).Tiles.Select(t => t.Id));
        Assert.Equal(first.Tiles, QuickTileStore.Load(box).Tiles);
        // So one can be moved and removed, and the rest are written back as they were.
        first.Move(first.Tiles[3].Id, 0);
        first.Remove(first.Tiles[3].Id);   // the null row
        Assert.True(QuickTileStore.Save(first, box));
        var tiles = Raw(box)["tiles"]!.AsArray();
        Assert.Equal(4, tiles.Count);
        Assert.Equal("just words", (string)tiles[0]!);
        Assert.Equal("yes", (string)tiles[2]!["wide"]!);
        Assert.Equal(2.5, (double)tiles[2]!["nested"]!["z"]![1]!);
        Assert.Equal("é/", (string)tiles[2]!["nested"]!["a"]!);
        Assert.Equal("No ID", (string)tiles[3]!["name"]!);
        Assert.False(tiles[3]!.AsObject().ContainsKey("id"), "an unreadable row is never given a stored id");
        Assert.Equal(["unreadable-", "ok", "w", "unreadable-"],
            QuickTileStore.Load(box).Tiles.Select(t => t.Id.StartsWith("unreadable-") ? "unreadable-" : t.Id));
    }

    // Q7: a list that can't be read at all is never wiped: it is copied aside, and no starter set goes over it.
    [Theory]
    [InlineData("not json")]
    [InlineData("[]")]
    [InlineData("{\"tiles\":[]}")]
    [InlineData("{\"version\":\"1\",\"tiles\":[]}")]
    [InlineData("{\"version\":1,\"seeded\":\"yes\",\"tiles\":[]}")]
    [InlineData("{\"version\":1,\"tiles\":null}")]
    public void ADecodeErrorNeverWipesTheList(string junk)
    {
        var box = new MemoryStore();
        box.Set(QuickTileStore.Key, junk);
        Assert.Null(QuickTileStore.Decode(junk));
        var list = QuickTileStore.Load(box);
        Assert.True(list.Tiles.Count == 0 && list.Seeded);
        Assert.Equal(junk, box.Get(QuickTileStore.UnreadableKey));
        Assert.Equal(junk, box.Get(QuickTileStore.Key));
        Assert.False(QuickTileStore.ListToShow(list, ("otto", "Otto")).Seeded);
        // Saving later keeps the first copy aside.
        var next = list.Copy();
        next.Add(Tile(QuickTileKind.Search, "s"));
        Assert.True(QuickTileStore.Save(next, box));
        Assert.Equal(junk, box.Get(QuickTileStore.UnreadableKey));
        Assert.Equal(["s"], QuickTileStore.Load(box).Tiles.Select(t => t.Id));
        // A later unreadable value never overwrites the first copy.
        box.Set(QuickTileStore.Key, "also junk");
        QuickTileStore.Load(box);
        QuickTileStore.Save(next, box);
        Assert.Equal(junk, box.Get(QuickTileStore.UnreadableKey));
    }

    // Save copies an unreadable stored value aside even when Load was never called first.
    [Fact]
    public void SavingOverJunkCopiesItAsideFirst()
    {
        var box = new MemoryStore();
        box.Set(QuickTileStore.Key, "{broken");
        var list = new QuickTileList();
        list.Add(Tile(QuickTileKind.Search, "s"));
        Assert.True(QuickTileStore.Save(list, box));
        Assert.Equal("{broken", box.Get(QuickTileStore.UnreadableKey));
        Assert.Equal(1, (int)Raw(box)["version"]!);
    }

    // The JSON the Mac writes (JSONEncoder escapes "/" as "\/") reads back the same.
    [Fact]
    public void TheMacsBytesReadBack()
    {
        const string mac = """
            {"seeded":true,"tiles":[{"bot":"otto","botName":"Otto","color":"accent","flag":false,"id":"a","kind":"new-chat","message":"Morning","name":"New Chat","project":"\/Users\/me\/site","projectName":"Site","symbol":"square.and.pencil","wide":true},{"color":"orange","id":"j","job":"otto|brief","jobName":"Brief","kind":"run-job","name":"Brief","symbol":"bolt.fill"},{"color":"gray","id":"p","kind":"page","name":"Files","page":"files","pageName":"Files","symbol":"square.grid.2x2.fill"}],"version":1}
            """;
        var list = QuickTileStore.Decode(mac)!;
        Assert.Equal("/Users/me/site", list.Tiles[0].Project);
        Assert.Equal((false, true), (list.Tiles[0].Flag!.Value, list.Tiles[0].Wide));
        Assert.Equal(("otto|brief", "Brief"), (list.Tiles[1].Job, list.Tiles[1].JobName));
        Assert.Equal(("files", "Files"), (list.Tiles[2].Page, list.Tiles[2].PageName));
        Assert.Equal(list, QuickTileStore.Decode(QuickTileStore.Encode(list)!));
    }

    // A real file on disk (a temporary folder), across a reopen: what the app's JsonFileStore keeps.
    [Fact]
    public void ATemporaryFileStoreKeepsTheListAcrossAReopen()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hq-quick-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var path = Path.Combine(dir, "quick-actions.json");
            var shown = QuickTileStore.ListToShow(QuickTileStore.Load(new JsonFileStore(path)), ("otto", "Otto"));
            Assert.True(shown.Seeded);
            Assert.True(QuickTileStore.Save(shown.List, new JsonFileStore(path)));
            var reopened = QuickTileStore.Load(new JsonFileStore(path));
            Assert.Equal(shown.List, reopened);
            Assert.False(QuickTileStore.ListToShow(reopened, ("ivy", "Ivy")).Seeded);
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    // ---- Q8: seeding ----

    [Fact]
    public void TheStarterSetIsMadeForTheFirstBot()
    {
        var shown = QuickTileStore.ListToShow(new QuickTileList(), ("otto", "Otto"));
        Assert.True(shown.Seeded && shown.List.Seeded);
        Assert.Equal([QuickTileKind.Memo, QuickTileKind.Talk, QuickTileKind.NewChat, QuickTileKind.AddTask, QuickTileKind.Search],
            shown.List.Tiles.Select(t => t.Known!.Value));
        Assert.Equal(["Memo", "Talk", "New Chat", "Add Task", "Search Chats"], shown.List.Tiles.Select(t => t.Name));
        Assert.Equal([false, false, true, false, false], shown.List.Tiles.Select(t => t.Wide));
        Assert.All(shown.List.Tiles.Take(3), t => Assert.True(t.Bot == "otto" && t.BotName == "Otto"));
        Assert.All(shown.List.Tiles.Skip(3), t => Assert.True(t.Bot == null && t.BotName == null));
        Assert.Equal(["to Otto", "with Otto", "with Otto", "for me", "all chats"], shown.List.Tiles.Select(t => t.Subtitle(null)));
        // Stable ids: the same starter set every time.
        Assert.Equal(["starter-memo", "starter-talk", "starter-new-chat", "starter-add-task", "starter-search"],
            shown.List.Tiles.Select(t => t.Id));
        Assert.Equal(shown.List.Tiles, QuickTileStore.Starter("otto", "Otto"));
        Assert.True(shown.List.Tiles[2].Flag, "New Chat sends its first message");
        Assert.All(shown.List.Tiles.Where(t => t.Known != QuickTileKind.NewChat), t => Assert.Null(t.Flag));
    }

    // Q8: no bot yet (the roster hasn't answered) is not an empty roster: nothing seeded, and nothing marked seeded,
    // so the starter set still comes once a bot is known.
    [Fact]
    public void AnUnknownFirstBotSeedsNothingYet()
    {
        var box = new MemoryStore();
        var stored = QuickTileStore.Load(box);
        Assert.False(stored.Seeded);
        var notYet = QuickTileStore.ListToShow(stored, null);
        Assert.False(notYet.Seeded);
        Assert.False(notYet.List.Seeded);
        Assert.Empty(notYet.List.Tiles);
        Assert.Null(box.Get(QuickTileStore.Key));
        var later = QuickTileStore.ListToShow(QuickTileStore.Load(box), ("herald", "Herald"));
        Assert.True(later.Seeded);
        Assert.Equal("herald", later.List.Tiles[0].Bot);
    }

    // Q8: once edited (even emptied), never seeded again.
    [Fact]
    public void NeverReseededAfterAnEdit()
    {
        Assert.False(QuickTileStore.ListToShow(new QuickTileList(), null).Seeded);
        var box = new MemoryStore();
        var list = QuickTileStore.ListToShow(new QuickTileList(), ("otto", "Otto")).List;
        foreach (var id in list.Tiles.Select(t => t.Id).ToList()) list.Remove(id);
        QuickTileStore.Save(list, box);
        var stored = QuickTileStore.Load(box);
        Assert.True(stored.Tiles.Count == 0 && stored.Seeded);
        Assert.True((bool)Raw(box)["seeded"]!);
        Assert.False(QuickTileStore.ListToShow(stored, ("ivy", "Ivy")).Seeded);
        Assert.Empty(QuickTileStore.ListToShow(stored, ("ivy", "Ivy")).List.Tiles);
        // Even an unseeded empty list saved by the app counts as the person's list now.
        var box2 = new MemoryStore();
        QuickTileStore.Save(new QuickTileList(), box2);
        Assert.False(QuickTileStore.ListToShow(QuickTileStore.Load(box2), ("ivy", "Ivy")).Seeded);
    }

    // An older stored list without the flag: tiles mean it was seeded.
    [Fact]
    public void AListWithoutTheFlagCountsAsSeededWhenItHasTiles()
    {
        Assert.True(QuickTileStore.Decode("""{"version":1,"tiles":[{"id":"a","kind":"search","name":"Search Chats","symbol":"magnifyingglass","color":"gray"}]}""")!.Seeded);
        Assert.False(QuickTileStore.Decode("""{"version":1,"tiles":[]}""")!.Seeded);
        Assert.False(QuickTileStore.Decode("""{"version":1,"seeded":null,"tiles":[]}""")!.Seeded);
        Assert.True(QuickTileStore.Decode("""{"version":1,"seeded":true,"tiles":[]}""")!.Seeded);
    }

    // ---- Q3: list edits never lose a tile ----

    [Fact]
    public void EditsKeepEveryTile()
    {
        var tiles = new QuickTileList(new[] { "a", "b", "c", "d" }.Select(id => Tile(QuickTileKind.Search, id)), seeded: true);
        tiles.Move("a", 2);
        Assert.Equal(["b", "c", "a", "d"], tiles.Tiles.Select(t => t.Id));
        tiles.Move("d", -4);
        Assert.Equal(["d", "b", "c", "a"], tiles.Tiles.Select(t => t.Id));
        tiles.Move("c", 99);
        Assert.Equal(["d", "b", "a", "c"], tiles.Tiles.Select(t => t.Id));
        tiles.Move("missing", 0);
        tiles.Move("c", 2);
        Assert.Equal(["d", "b", "c", "a"], tiles.Tiles.Select(t => t.Id));
        Assert.False(tiles.Step("d", -1));
        Assert.True(tiles.Step("d", 1));
        Assert.Equal(["b", "d", "c", "a"], tiles.Tiles.Select(t => t.Id));
        Assert.False(tiles.Step("a", 1));
        Assert.False(tiles.Step("missing", 1));
        tiles.Reorder(["a", "missing", "c"]);
        Assert.Equal(["a", "c", "b", "d"], tiles.Tiles.Select(t => t.Id));
        tiles.SetWide("c", true);
        Assert.True(tiles.Tiles[1].Wide);
        tiles.SetWide("missing", true);
        tiles.Remove("b");
        Assert.Equal(["a", "c", "d"], tiles.Tiles.Select(t => t.Id));
        tiles.Replace(tiles.Tiles[0] with { Name = "Find" });
        Assert.True(tiles.Tiles[0].Name == "Find" && tiles.Tiles.Count == 3);
        tiles.Replace(Tile(QuickTileKind.Memo, "new"));
        Assert.Equal(["a", "c", "d", "new"], tiles.Tiles.Select(t => t.Id));
        tiles.Add(Tile(QuickTileKind.Talk, "z"));
        Assert.Equal("z", tiles.Tiles[^1].Id);
    }

    // Reorder with a repeated id keeps the first; a duplicate stored id is not lost by Reorder either.
    [Fact]
    public void ReorderNeverDropsATile()
    {
        var tiles = new QuickTileList([Tile(QuickTileKind.Search, "a"), Tile(QuickTileKind.Memo, "b"), Tile(QuickTileKind.Talk, "c")], seeded: true);
        tiles.Reorder(["c", "c", "a"]);
        Assert.Equal(["c", "a", "b"], tiles.Tiles.Select(t => t.Id));
        tiles.Reorder([]);
        Assert.Equal(["c", "a", "b"], tiles.Tiles.Select(t => t.Id));
    }

    // Copy is a value copy (the Swift list is a struct): editing it never changes the original.
    [Fact]
    public void ACopyIsItsOwnList()
    {
        var list = new QuickTileList([Tile(QuickTileKind.Search, "a")], seeded: false);
        var copy = list.Copy();
        copy.Add(Tile(QuickTileKind.Memo, "b"));
        copy.SetWide("a", true);
        Assert.Single(list.Tiles);
        Assert.False(list.Tiles[0].Wide);
        Assert.NotEqual(list, copy);
        Assert.Equal(list, list.Copy());
    }

    // Saving never changes the caller's list (Swift's save works on a copy marked seeded).
    [Fact]
    public void SaveLeavesTheCallersListAlone()
    {
        var box = new MemoryStore();
        var list = new QuickTileList([Tile(QuickTileKind.Search, "a")], seeded: false);
        QuickTileStore.Save(list, box);
        Assert.False(list.Seeded);
        Assert.True(QuickTileStore.Load(box).Seeded);
        Assert.False(QuickTileStore.Save(list, box), "the same tiles write nothing (stored is seeded already)");
    }

    // A version older than this build's is raised to it on the next write; a newer one stays.
    [Fact]
    public void AnOlderVersionIsRaisedAndANewerOneKept()
    {
        var box = new MemoryStore();
        box.Set(QuickTileStore.Key, """{"version":0,"seeded":true,"tiles":[]}""");
        var list = QuickTileStore.Load(box);
        list.Add(Tile(QuickTileKind.Search, "s"));
        QuickTileStore.Save(list, box);
        Assert.Equal(1, (int)Raw(box)["version"]!);
        box.Set(QuickTileStore.Key, """{"version":12,"tiles":[{"id":"s","kind":"search"}]}""");
        list = QuickTileStore.Load(box);
        list.Remove("s");
        QuickTileStore.Save(list, box);
        Assert.Equal(12, (int)Raw(box)["version"]!);
        Assert.Null(box.Get(QuickTileStore.UnreadableKey));
    }

    [Theory]
    [InlineData(9007199254740993L)]
    [InlineData(long.MaxValue)]
    public void AnEditNeverRoundsTheIntegerVersion(long version)
    {
        var box = new CountingStore(FormattableString.Invariant($$"""{"version":{{version}},"tiles":[{"id":"s","kind":"search"}]}"""));
        var list = QuickTileStore.Load(box);
        list.SetWide("s", true);
        Assert.True(QuickTileStore.Save(list, box));
        Assert.Equal(version, (long)Raw(box)["version"]!);
        Assert.Equal(list, QuickTileStore.Load(box));
        Assert.Equal(1, box.Writes);
    }

    [Theory]
    [InlineData("9007199254740993.5", 9007199254740993L)]
    [InlineData("9.007199254740993500e15", 9007199254740993L)]
    [InlineData("7.99999999999999999", 8L)]
    [InlineData("18446744073709551615e-3", 18446744073709551L)]
    [InlineData("18446744073709551616e-3", null)]
    [InlineData("9223372036854775807.0", null)]
    [InlineData("-9223372036854775807.0", -9223372036854775807L)]
    [InlineData("-9223372036854775808.0", null)]
    [InlineData("-9223372036854775808", long.MinValue)]
    [InlineData("7.25", null)]
    public void AnEditUsesTheVersionAcceptedByTheShippingDecoder(string token, long? decoded)
    {
        var raw = $$"""{"version":{{token}},"seeded":true,"tiles":[]}""";
        var box = new CountingStore(raw);
        var list = QuickTileStore.Load(box);
        Assert.Equal(decoded == null ? raw : null, box.Get(QuickTileStore.UnreadableKey));
        Assert.Equal(raw, box.Get(QuickTileStore.Key));
        list.Add(Tile(QuickTileKind.Search, "added"));
        Assert.True(QuickTileStore.Save(list, box));
        Assert.Equal(Math.Max(decoded ?? 1, 1), (long)Raw(box)["version"]!);
        Assert.False(QuickTileStore.Save(QuickTileStore.Load(box), box));
        Assert.Equal(decoded == null ? 2 : 1, box.Writes);
    }

    // Subtitles: what each tile says under its name (QuickTile.subtitle).
    [Fact]
    public void SubtitlesSayWhatATileDoes()
    {
        Assert.Equal("in Site", (Tile(QuickTileKind.NewChat, bot: "otto") with { Project = "/x", ProjectName = "Site" }).Subtitle(null));
        Assert.Equal("in /x", (Tile(QuickTileKind.NewChat, bot: "otto") with { Project = "/x" }).Subtitle(null));
        Assert.Equal("with Ivy", Tile(QuickTileKind.NewChat, bot: "otto").Subtitle("Ivy"));
        Assert.Equal("asks Otto", Tile(QuickTileKind.Send, bot: "otto").Subtitle(null));
        Assert.Equal("with Otto", (Tile(QuickTileKind.Send, bot: "otto") with { Flag = true }).Subtitle(null));
        Assert.Equal("chat with otto", (Tile(QuickTileKind.OpenChat, bot: "otto") with { BotName = null }).Subtitle(null));
        Assert.Equal("for Otto", Tile(QuickTileKind.AddTask, bot: "otto").Subtitle(null));
        Assert.Equal("run job", Tile(QuickTileKind.RunJob).Subtitle(null));
        Assert.Equal("page", Tile(QuickTileKind.Page).Subtitle(null));
        Assert.Equal("to ", Tile(QuickTileKind.Memo).Subtitle(null));
        Assert.Equal("needs a newer app", QuickTile.FromUnreadable(JsonNode.Parse("""{"id":"x","kind":"memo","wide":3}""")).Subtitle(null));
    }
}
