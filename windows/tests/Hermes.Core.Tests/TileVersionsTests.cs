using System.Net;
using System.Text;
using Hermes.Core.Auth;
using Hermes.Core.Insights;
using Hermes.Core.Net;
using Xunit;

namespace Hermes.Core.Tests;

/// [tile-versions] A page tile's versions, read-only (HermesKit/Pages/TileVersions.swift, Tests/Pages/TileVersionsTests.swift,
/// App/Pages/Artifacts/TileVersionsSheet.swift at 93f984bb1): where the list lives, Swift's Codable form, what the
/// sheet lists and says, and that the sheet's load makes one GET as the tile's own bot and never writes.
/// Synthetic fixtures only: demo bots ivy and otto, made-up paths.
public class TileVersionsTests
{
    private const string Tile = "/home/ivy/dashboards/revenue.html";
    private const string Index = "/home/ivy/dashboards/revenue.versions/versions.json";

    /// The gateway's file routes as the versions see them, keyed by (path, profile). Every request is kept: the ledger.
    private sealed class DiskHandler : HttpMessageHandler
    {
        public readonly Dictionary<(string Path, string Profile), (int Status, string Body)> Files = [];
        public readonly List<(string Method, string Path, Dictionary<string, string> Query, string Body)> Ledger = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = request.Content == null ? "" : await request.Content.ReadAsStringAsync(ct);
            var query = Query(request.RequestUri!.Query);
            lock (Ledger) Ledger.Add((request.Method.Method, request.RequestUri.AbsolutePath, query, body));
            if (request.Method != HttpMethod.Get || request.RequestUri.AbsolutePath != "/api/fs/download")
                return Answer(404, """{"detail":"Not Found"}""");
            var key = (query.GetValueOrDefault("path", ""), query.GetValueOrDefault("profile", ""));
            return Files.TryGetValue(key, out var f) ? Answer(f.Status, f.Body) : Answer(404, """{"detail":"File not found"}""");
        }

        private static HttpResponseMessage Answer(int status, string body) =>
            new((HttpStatusCode)status) { Content = new StringContent(body, Encoding.UTF8, "application/octet-stream") };

        private static Dictionary<string, string> Query(string q) => q.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.Split('=', 2))
            .ToDictionary(p => Uri.UnescapeDataString(p[0]), p => p.Length > 1 ? Uri.UnescapeDataString(p[1].Replace('+', ' ')) : "");

        public List<string> Writes() { lock (Ledger) return Ledger.Where(r => r.Method != "GET").Select(r => $"{r.Method} {r.Path}").ToList(); }
    }

    private static GatewaySession Session(DiskHandler disk) =>
        new(GatewayAddress.Validated("http://127.0.0.1:9"), new StoredAccount("http://127.0.0.1:9", "qa"), new MemoryTokenStore(), disk);

    private static TilePin Page(string profile = "ivy", string value = Tile) =>
        TilePin.Make(TileKind.File, value, "", profile, "s1", "Revenue", 1000);

    /// The model as TilesPage.ShowVersions builds it: the read is the tile's bot's.
    private static TileVersionsModel Model(DiskHandler disk, TilePin pin) =>
        new(pin, "Revenue", path => new TileVersionReader(Session(disk), pin.Profile, path));

    /// Three versions, rolled back to 2 (so the newest isn't the one that shows), as the Mac writes versions.json
    /// (pretty-printed, sorted keys).
    private const string Populated = """
        {
          "current" : 2,
          "versions" : [
            { "at" : 1795000000, "design" : "a1b2c3d4e5f6a7b8c9d0", "file" : "v1.html", "kind" : "made", "number" : 1, "what" : "Revenue this week" },
            { "at" : 1795200000, "design" : "b1b2c3d4e5f6a7b8c9d0", "file" : "v2.html", "kind" : "changed", "number" : 2, "what" : "  Make it a bar chart " },
            { "at" : 1795300000.5, "design" : "c1b2c3d4e5f6a7b8c9d0", "file" : "v3.html", "kind" : "outside", "number" : 3 }
          ]
        }
        """;

    // ------------------------------------------------------------------ where, and Swift's form

    [Fact]
    public void VersionsLiveBesideTheTile()
    {
        Assert.Equal("/home/otto/dashboards/revenue.versions", TileVersionFiles.Folder("/home/otto/dashboards/revenue.html"));
        Assert.Equal("~/dashboards/revenue-week.versions", TileVersionFiles.Folder("~/dashboards/revenue-week.html"));
        Assert.Equal("~/dashboards/a.b.versions/versions.json", TileVersionFiles.IndexPath("~/dashboards/a.b.html"));
        Assert.Equal("revenue.versions", TileVersionFiles.Folder("revenue.html"));
        Assert.Equal("/revenue.versions", TileVersionFiles.Folder("/revenue.html"));
        Assert.Equal("v3.html", TileVersionFiles.FileName(3));
    }

    [Fact]
    public void TheListReadsAsSwiftDecodesIt()
    {
        var list = TileVersionList.Parse(Populated)!;
        Assert.Equal(2, list.Current);
        Assert.Equal([3, 2, 1], list.NewestFirst.Select(v => v.Number));
        Assert.Equal(2, list.Shown!.Number);
        Assert.Equal(TileVersionKind.Outside, list.Versions[2].Kind);
        Assert.Null(list.Versions[2].What);
        // `what: null` decodes; 2.0 is a whole number; an unknown key is ignored.
        Assert.NotNull(TileVersionList.Parse("""{"current":2.0,"extra":1,"versions":[{"number":2,"at":1,"kind":"first","what":null,"file":"v2.html","design":"x"}]}"""));
        // Anything Swift's decoder refuses reads as no list (the Mac then lists none).
        Assert.Null(TileVersionList.Parse("""{"versions":[]}"""));
        Assert.Null(TileVersionList.Parse("""{"current":1,"versions":[{"number":1,"at":1,"kind":"edited","file":"v1.html","design":"x"}]}"""));
        Assert.Null(TileVersionList.Parse("""{"current":1,"versions":[{"number":1.5,"at":1,"kind":"made","file":"v1.html","design":"x"}]}"""));
        Assert.Null(TileVersionList.Parse("""{"current":1,"versions":[{"number":1,"at":1,"kind":"made","file":"v1.html"}]}"""));
        Assert.Null(TileVersionList.Parse("""{"current":1,"versions":[{"number":1,"at":1,"kind":"made","what":7,"file":"v1.html","design":"x"}]}"""));
        Assert.Null(TileVersionList.Parse("<html>proxy</html>"));
    }

    [Fact]
    public void EachRowSaysWhatWasAskedOrHowItCame()
    {
        TileVersion V(TileVersionKind kind, string? what) => new(1, 0, kind, what, "v1.html", "x");
        Assert.Equal("Version 1", V(TileVersionKind.Made, null).Title);
        Assert.Equal("The tile as it was made", V(TileVersionKind.Made, "  ").Words);
        Assert.Equal("Revenue this week", V(TileVersionKind.Made, " Revenue this week ").Words);
        Assert.Equal("Changed in Tiles", V(TileVersionKind.Changed, null).Words);
        Assert.Equal("Make it a bar chart", V(TileVersionKind.Changed, "Make it a bar chart").Words);
        Assert.Equal("Changed in a chat", V(TileVersionKind.Outside, "ignored").Words);
        Assert.Equal("The tile when versions began", V(TileVersionKind.First, "ignored").Words);
    }

    // ------------------------------------------------------------------ the menu

    [Fact]
    public void VersionsIsOfferedOnlyOnAReadOnlyGateway()
    {
        // A writable gateway's Versions keeps and rolls back on the Mac; Windows doesn't, so it offers none there.
        Assert.Equal(TileVersionsOffer.Hidden, TileVersionsModel.Offer(Page(), readOnlyGateway: false));
        Assert.Equal(TileVersionsOffer.Enabled, TileVersionsModel.Offer(Page(), readOnlyGateway: true));
        Assert.Equal(TileVersionsOffer.Enabled, TileVersionsModel.Offer(Page(value: "file:///home/ivy/a.htm"), readOnlyGateway: true));
        // A hosted page has no path on the bot's computer: shown, dimmed (versionsAction's `.disabled`).
        Assert.Equal(TileVersionsOffer.Disabled, TileVersionsModel.Offer(Page(value: "https://example.com/a.html"), readOnlyGateway: true));
        // Not a page: no Versions at all.
        Assert.Equal(TileVersionsOffer.Hidden, TileVersionsModel.Offer(Page(value: "/home/ivy/notes.md"), readOnlyGateway: true));
        Assert.Equal(TileVersionsOffer.Hidden, TileVersionsModel.Offer(TilePin.Make(TileKind.Link, "https://example.com", "Example", "ivy"), true));
        Assert.Null(TileVersionsModel.MenuSubtitle(Page()));
        Assert.Equal("Version 2", TileVersionsModel.MenuSubtitle(Page() with { Version = 2 }));
    }

    // ------------------------------------------------------------------ the sheet, through the read, with the ledger

    [Fact]
    public async Task APopulatedHistoryListsNewestFirstAsTheTilesBotAndWritesNothing()
    {
        var disk = new DiskHandler();
        disk.Files[(Index, "ivy")] = (200, Populated);
        // Otto has a tile at the same path with another history: never read for ivy's tile.
        disk.Files[(Index, "otto")] = (200, """{"current":9,"versions":[]}""");
        var model = Model(disk, Page("ivy"));
        var states = new List<TileVersionsModel.State>();
        model.Changed += () => states.Add(model.Now);

        await model.LoadAsync();

        Assert.IsType<TileVersionsModel.State.Reading>(states[0]);
        var listed = Assert.IsType<TileVersionsModel.State.Listed>(model.Now);
        var now = DateTimeOffset.FromUnixTimeSeconds(1795300600);
        var rows = TileVersionsModel.Rows(listed.List, now, TimeZoneInfo.Utc);
        Assert.Equal(["Version 3", "Version 2", "Version 1"], rows.Select(r => r.Title));
        Assert.Equal([false, true, false], rows.Select(r => r.Current));
        Assert.Equal(["Changed in a chat", "Make it a bar chart", "Revenue this week"], rows.Select(r => r.Words));
        Assert.Equal(["Today at 10:26 PM", "Yesterday at 6:40 PM", "Wed at 11:06 AM"], rows.Select(r => r.When));
        Assert.Equal("Version 2, current. Make it a bar chart", rows[1].AccessibilityLabel);
        Assert.Equal("Version 3. Changed in a chat", rows[0].AccessibilityLabel);
        Assert.Equal(["tile.version.3", "tile.version.2", "tile.version.1"], rows.Select(r => r.AutomationId));
        Assert.Equal("Click a version to see it full size. Rolling back puts that version on the tile; the others stay here."
                     + " This gateway is read-only, so versions can’t be rolled back from here.", TileVersionsModel.Footer(listed.List));

        // The ledger: one GET of ivy's versions.json, through the download route; no write of any kind.
        var only = Assert.Single(disk.Ledger);
        Assert.Equal(("GET", "/api/fs/download"), (only.Method, only.Path));
        Assert.Equal(new Dictionary<string, string> { ["path"] = Index, ["profile"] = "ivy" }, only.Query);
        Assert.Empty(disk.Writes());

        // A version opens full size as the tile's bot, from beside the tile.
        var v1 = listed.List.Versions.Single(v => v.Number == 1);
        var opened = model.VersionPin(v1)!;
        Assert.Equal("/home/ivy/dashboards/revenue.versions/v1.html", opened.Value);
        Assert.Equal(("ivy", "v1.html", "s1"), (opened.Profile, opened.Label, opened.SessionId));
        Assert.True(opened.IsPage);
    }

    [Fact]
    public async Task OneVersionSaysItIsTheOnlyOne()
    {
        var disk = new DiskHandler();
        disk.Files[(Index, "ivy")] = (200, """{"current":1,"versions":[{"number":1,"at":1795000000,"kind":"first","file":"v1.html","design":"x"}]}""");
        var model = Model(disk, Page());
        await model.LoadAsync();
        var list = Assert.IsType<TileVersionsModel.State.Listed>(model.Now).List;
        var row = Assert.Single(TileVersionsModel.Rows(list));
        Assert.True(row.Current);
        Assert.Equal("The tile when versions began", row.Words);
        Assert.Equal("This is the only version so far. Each change makes a new one, and the ones before stay here."
                     + " This gateway is read-only, so versions can’t be rolled back from here.", TileVersionsModel.Footer(list));
        Assert.Empty(disk.Writes());
    }

    [Fact]
    public async Task AnAbsentOrUndecodableHistoryListsNoneAndWritesNothing()
    {
        // No versions.json (404): the Mac's `.empty`, which its read-only sheet shows as an empty section and its footer.
        var disk = new DiskHandler();
        var model = Model(disk, Page());
        await model.LoadAsync();
        var list = Assert.IsType<TileVersionsModel.State.Listed>(model.Now).List;
        Assert.Equal(TileVersionList.Empty, list);
        Assert.Empty(TileVersionsModel.Rows(list));
        Assert.Equal("Click a version to see it full size. Rolling back puts that version on the tile; the others stay here."
                     + " This gateway is read-only, so versions can’t be rolled back from here.", TileVersionsModel.Footer(list));

        // A list the Mac couldn't decode (a proxy's page): also none.
        disk.Files[(Index, "ivy")] = (200, "<html>sign in</html>");
        await model.LoadAsync();
        Assert.Empty(Assert.IsType<TileVersionsModel.State.Listed>(model.Now).List.Versions);

        Assert.Equal(2, disk.Ledger.Count);
        Assert.All(disk.Ledger, r => Assert.Equal(("GET", "/api/fs/download", Index, "ivy"), (r.Method, r.Path, r.Query["path"], r.Query["profile"])));
        Assert.Empty(disk.Writes());
    }

    [Fact]
    public async Task AnUnreadableHistorySaysWhyAndTryAgainReadsAgain()
    {
        var disk = new DiskHandler();
        disk.Files[(Index, "ivy")] = (403, """{"detail":"Permission denied: /home/ivy/dashboards"}""");
        var model = Model(disk, Page());
        await model.LoadAsync();
        Assert.Equal("Permission denied: /home/ivy/dashboards", Assert.IsType<TileVersionsModel.State.Problem>(model.Now).Words);

        // A 500 with no words of its own: PagesREST.reason's fallback.
        disk.Files[(Index, "ivy")] = (500, "<html>Internal Server Error</html>");
        await model.LoadAsync();
        Assert.Equal("The gateway couldn’t do that.", Assert.IsType<TileVersionsModel.State.Problem>(model.Now).Words);

        // Larger than the Mac reads (6 MB): unreadable, in the Mac's words.
        disk.Files[(Index, "ivy")] = (200, "{\"current\":1,\"pad\":\"" + new string('x', TileVersionReader.Largest) + "\",\"versions\":[]}");
        await model.LoadAsync();
        Assert.Equal("This tile’s page couldn’t be read, or is too large to keep versions of.",
            Assert.IsType<TileVersionsModel.State.Problem>(model.Now).Words);

        // Try Again, now readable.
        disk.Files[(Index, "ivy")] = (200, Populated);
        await model.LoadAsync();
        Assert.Equal(3, Assert.IsType<TileVersionsModel.State.Listed>(model.Now).List.Versions.Count);

        Assert.Equal(4, disk.Ledger.Count);
        Assert.Empty(disk.Writes());
    }

    [Fact]
    public async Task APageWithNoGatewayPathIsUnreadableWithoutAsking()
    {
        var disk = new DiskHandler();
        var model = Model(disk, Page(value: "https://example.com/revenue.html"));
        await model.LoadAsync();
        Assert.Equal(TileVersionError.Unreadable, Assert.IsType<TileVersionsModel.State.Problem>(model.Now).Words);
        Assert.Empty(disk.Ledger);
    }

    [Fact]
    public async Task AnUnreachableGatewaySaysSo()
    {
        var model = new TileVersionsModel(Page(), "Revenue", path => new TileVersionReader(
            new GatewaySession(GatewayAddress.Validated("http://127.0.0.1:9"), new StoredAccount("http://127.0.0.1:9", "qa"), new MemoryTokenStore(), new Refusing()),
            "ivy", path));
        await model.LoadAsync();
        Assert.Equal(Hermes.Core.Kanban.KanbanRest.CantReach, Assert.IsType<TileVersionsModel.State.Problem>(model.Now).Words);
    }

    private sealed class Refusing : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            throw new HttpRequestException("Connection refused");
    }

    // ------------------------------------------------------------------ the Windows side's source

    private static string Source(string relative)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine(dir, "src", relative));
    }

    [Fact]
    public void TheVersionsCodeGatesWritableModeOnReadOnlyAndSupportsRollback()
    {
        // Read-only TileVersionReader never performs any HTTP write verb; writable TileVersionStore is gated by !ReadOnlyGateway.
        var versions = Source("Hermes.Core/Insights/TileVersions.cs");
        var readerStart = versions.IndexOf("public sealed class TileVersionReader", StringComparison.Ordinal);
        var readerEnd = versions.IndexOf("\n}", readerStart, StringComparison.Ordinal);
        Assert.True(readerStart > 0 && readerEnd > readerStart);
        var readerSection = versions[readerStart..readerEnd];
        foreach (var write in new[] { "write-text", "/api/files/mkdir", "HttpMethod.Post", "HttpMethod.Put", "HttpMethod.Delete", "PostJsonAsync" })
            Assert.DoesNotContain(write, readerSection);

        var sheet = Source("HermesHQ.Windows/Features/Insights/TileVersionsSheet.cs");
        Assert.Contains("TileVersionsModel.AsksFirst", sheet);
        Assert.Contains("RollBackAsync", sheet);

        var tiles = Source("HermesHQ.Windows/Features/Insights/TilesPage.cs");
        Assert.Contains("TileVersionsModel.Offer(pin, ReadOnlyGateway, supportsWritable: true)", tiles);
        Assert.Contains("new TileVersionReader(session, pin.Profile, path)", tiles);
        Assert.Contains("new TileVersionStore(session, pin.Profile, path)", tiles);
    }
}
