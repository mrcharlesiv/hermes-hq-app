using System.Text.Json.Nodes;
using Hermes.Core.Insights;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// The Tiles page's logic (HermesKit/Pages/ArtifactPins.swift, TileNames.swift, App/Pages/Artifacts/TileUpdates.swift,
/// HermesKit/Store/GatewaySync.swift): names, the grid's packing, the jobs and their health, the pins and their pages,
/// and the gateway sync's merge rules.
public class InsightsTilesTests
{
    private static TilePin Pin(string value, string profile = "default", TileSize? size = null, string? page = null) =>
        TilePin.Make(TileKind.File, value, "", profile, "s1", "Chat", 1000) with { Size = size, Page = page };

    // ------------------------------------------------------------------ names

    [Theory]
    [InlineData("revenue-week.html", "Revenue Week")]
    [InlineData("/home/hermes/site/revenueWeek.html", "Revenue Week")]
    [InlineData("calls_of_the_week.md", "Calls of the Week")]
    [InlineData("Q3-report.pdf", "Q3 Report")]
    [InlineData("the-plan.txt", "The Plan")]
    [InlineData("otto_notes.html", "Otto Notes")]
    public void PrettyNamesAFileInWords(string file, string words) => Assert.Equal(words, TileNames.Pretty(file));

    [Fact]
    public void ClashingFileNamesKeepTheirExtensions()
    {
        var a = Pin("/x/index.md");
        var b = Pin("/x/index.html");
        var c = Pin("/x/report.html");
        var store = new TilePinStore(null);
        store.Pin(c); store.Pin(b); store.Pin(a);
        Assert.Equal("Index.md", store.Name(a));
        Assert.Equal("Index.html", store.Name(b));
        Assert.Equal("Report", store.Name(c));
        Assert.Equal("Index.md", TileNames.Pretty("index.md", keepsExtension: true));
    }

    [Fact]
    public void ATitleIsCleanedAndCut()
    {
        Assert.Equal("Revenue Week", TileNames.CleanTitle("revenue-week.html"));
        Assert.Null(TileNames.CleanTitle("  ·  "));
        Assert.Equal("Sales  Today".Replace("  ", " "), TileNames.CleanTitle("Sales\n   Today"));
        var cut = TileNames.CleanTitle("A very long dashboard title that goes on and on past the limit");
        Assert.Equal("A very long dashboard title that goes…", cut);
    }

    [Fact]
    public void APagesHeadSaysItsTitleJobAndWhetherItIsLive()
    {
        var head = TileNames.ReadHead("<html><head><title>Sales &amp; Leads</title><meta name=\"hq-tile-job\" content=\"j-1\">"
            + "<meta name=\"hq-tile-refresh\" content=\"10\"></head><body></body></html>");
        Assert.Equal("Sales & Leads", head.Title);
        Assert.Equal("j-1", head.JobId);
        Assert.Equal(TileNames.ShortestRefresh, head.RefreshSeconds);
        Assert.True(head.Live);
        Assert.True(TileNames.ReadHead("<button data-hermes-send=\"Add\">x</button>").Live);
        Assert.True(TileNames.ReadHead("<meta name='hq-tile' content='live'>").Live);
        var still = TileNames.ReadHead("<title>Plain</title>");
        Assert.False(still.Live);
        Assert.Null(still.RefreshSeconds);
    }

    // ------------------------------------------------------------------ the grid

    [Fact]
    public void TilesPackAsHomeScreenWidgets()
    {
        // A Large (2×2) then two Smalls fill beside it on a 4-wide grid; a Medium goes under; Extra Large is cut to the grid.
        var spans = new[] { TileSize.Large, TileSize.Small, TileSize.Small, TileSize.Medium, TileSize.ExtraLarge }.Select(s => s.Span());
        var (cells, rows) = TileGridPacking.Place(spans, 4);
        Assert.Equal(new TileGridPacking.Cell(0, 0, 2, 2), cells[0]);
        Assert.Equal(new TileGridPacking.Cell(2, 0, 1, 1), cells[1]);
        Assert.Equal(new TileGridPacking.Cell(3, 0, 1, 1), cells[2]);
        Assert.Equal(new TileGridPacking.Cell(2, 1, 2, 1), cells[3]);
        Assert.Equal(new TileGridPacking.Cell(0, 2, 4, 3), cells[4]);
        Assert.Equal(5, rows);
    }

    [Fact]
    public void GridCellsAreAtLeast150Or190Wide()
    {
        Assert.Equal((2, 154), TileGridPacking.Metrics(320, 12));
        var (columns, side) = TileGridPacking.Metrics(1000, 12);
        Assert.Equal(5, columns);
        Assert.True(side >= 190);
        Assert.Equal(TileSize.ExtraLarge, TileSizes.Fitting(1, 3));
        Assert.Equal(TileSize.Large, TileSizes.Fitting(1, 2));
        Assert.Equal(TileSize.Medium, TileSizes.Fitting(2, 1));
        Assert.Equal(TileSize.Small, TileSizes.Fitting(1, 1));
    }

    // ------------------------------------------------------------------ pins and pages

    [Fact]
    public void APinsJsonIsTheSwiftAppsCodableForm()
    {
        var json = JsonNode.Parse("""
            {"id":"deploys\u001F/home/hermes/site/tile.html","kind":"file","value":"/home/hermes/site/tile.html","label":"tile.html",
             "profile":"deploys","sessionId":"s-1","sessionTitle":"Make my tile","pinnedAt":1790000000.5,"size":"extraLarge",
             "page":"P2","title":"Money","pageTitle":"Revenue This Week","jobId":"j-tile","version":3,"chatAt":1790000100}
            """);
        var pin = TilePin.FromJson(json)!;
        Assert.Equal(TileSize.ExtraLarge, pin.TileSize);
        Assert.Equal("Money", pin.Name);
        Assert.Equal("Revenue This Week", pin.AutomaticName);
        Assert.True(pin.IsPage);
        Assert.Equal("/home/hermes/site/tile.html", pin.GatewayPath);
        Assert.True(JsonNode.DeepEquals(json, pin.ToJson()));
        Assert.Equal(TileSize.Small, (pin with { Size = null }).TileSize);
        Assert.Null(TilePin.FromJson(JsonNode.Parse("""{"kind":"video","value":"x"}""")));
    }

    [Fact]
    public void PinsKeepTheirPlacesAndPages()
    {
        var path = Path.Combine(Path.GetTempPath(), "hqw-tiles-" + Guid.NewGuid().ToString("N"), "pins.json");
        var store = new TilePinStore(path);
        Assert.True(store.StartedEmpty);
        var a = Pin("/a.html"); var b = Pin("/b.html"); var c = Pin("/c.png");
        store.Pin(a); store.Pin(b); store.Pin(c);
        Assert.Equal(["/c.png", "/b.html", "/a.html"], store.Pins.Select(p => p.Value));
        Assert.True(store.Pin(a)); // already pinned
        store.Move(a.Id, c.Id);
        Assert.Equal(["/a.html", "/c.png", "/b.html"], store.Pins.Select(p => p.Value));
        store.SetSize(TileSize.Large, b.Id);
        store.Rename(c.Id, "  My   picture ");
        Assert.Equal("My picture", store.Pins.First(p => p.Id == c.Id).Name);
        store.Rename(c.Id, "");
        Assert.Null(store.Pins.First(p => p.Id == c.Id).Title);

        var work = store.AddPage("Work");
        Assert.Equal(work.Id, store.CurrentPage);
        store.Pin(Pin("/d.html"));
        Assert.Equal(work.Id, store.PageId(store.Pins[0]));   // a new pin goes on the page looked at
        store.SetPage(work.Id, a.Id);
        Assert.Equal(2, store.OnPage(work.Id).Count());
        store.AddPage("");
        Assert.Equal("Page 3", store.Pages[^1].Name);
        store.MovePage(store.Pages[^1].Id, -1);
        Assert.Equal("Page 3", store.Pages[1].Name);
        store.MovePage(store.Pages[1].Id, -1);   // Main stays first
        Assert.Equal(TilePage.MainId, store.Pages[0].Id);
        store.DeletePage(work.Id);
        Assert.All(store.Pins, p => Assert.Equal(TilePage.MainId, store.PageId(p)));

        var again = new TilePinStore(path);
        Assert.False(again.StartedEmpty);
        Assert.Equal(store.Pins.Select(p => p.Id), again.Pins.Select(p => p.Id));
        Assert.Equal(TileSize.Large, again.Pins.First(p => p.Id == b.Id).TileSize);
        Assert.Equal(store.Pages.Count, again.Pages.Count);

        var index = again.IndexOf(b.Id);
        again.Unpin(b.Id);
        Assert.DoesNotContain(again.Pins, p => p.Id == b.Id);
        again.Restore(store.Pins.First(p => p.Id == b.Id), index);
        Assert.Equal(index, again.IndexOf(b.Id));
    }

    [Fact]
    public void ATilesPageIsFullAt120()
    {
        var store = new TilePinStore(null);
        for (var i = 0; i < TilePinStore.Limit; i++) Assert.True(store.Pin(Pin($"/{i}.html")));
        Assert.True(store.IsFull);
        Assert.False(store.Pin(Pin("/one-more.html")));
    }

    [Fact]
    public void RemovedArtifactsAreUnpinnedAndStayGone()
    {
        var store = new TilePinStore(null);
        var hidden = new TileHidden(null);
        var a = Pin("/a.html");
        store.Pin(a);
        store.Pin(Pin("/b.html"));
        hidden.Hide(a.Id, store);
        Assert.DoesNotContain(store.Pins, p => p.Id == a.Id);
        store.Pin(a);
        Assert.Single(hidden.Visible(store.Pins));
        hidden.AdoptSynced(new JsonArray("x\u001F/y", a.Id));
        Assert.Equal(2, hidden.SyncValue().Count);
    }

    [Fact]
    public void AThreeWayMergeKeepsEachSidesChanges()
    {
        List<string> baseList = ["a", "b", "c"];
        List<string> local = ["n", "a", "c"];    // added n, dropped b
        List<string> remote = ["c", "a", "b", "r"]; // reordered, added r
        Assert.Equal(["n", "c", "a", "r"], TilePinStore.Merged(remote, local, baseList, s => s));
    }

    // ------------------------------------------------------------------ jobs and health

    private static TileCronJob Job(string id, string owner = "deploys", string? prompt = null, string? expr = "0 * * * *",
        string? last = null, string? next = null, string? status = null, string? error = null, bool? enabled = null, string? state = null) => new()
    {
        Id = id, Profile = owner, Prompt = prompt, ScheduleExpr = expr, LastRunAt = last, NextRunAt = next, LastStatus = status,
        LastError = error, Enabled = enabled, State = state,
    };

    [Fact]
    public void ATilesJobIsTheOneItsPageNamesElseTheBestMatch()
    {
        var jobs = new List<TileCronJob>
        {
            Job("j-name", prompt: "Refresh tile.html please"),
            Job("j-path", prompt: "Update ~/site/tile.html with the skill", state: "paused"),
            Job("j-path2", prompt: "Update /home/hermes/site/tile.html"),
            Job("j-other", owner: "research", prompt: "/home/hermes/site/tile.html"),
        };
        Assert.Equal("j-path2", TileJobs.Match("/home/hermes/site/tile.html", "deploys", null, jobs)?.Id);
        Assert.Equal("j-other", TileJobs.Match("/home/hermes/site/tile.html", "deploys", "j-other", jobs)?.Id);
        Assert.Equal("j-name", TileJobs.Match("/elsewhere/tile.html", "deploys", null, jobs)?.Id);
        Assert.Null(TileJobs.Match("/home/hermes/site/other.html", "deploys", null, jobs));
        // A paused job loses a tie to one that runs; the ~ form of the path matches.
        Assert.Equal("j-path", TileJobs.Match("~/site/tile.html", "deploys", null, [jobs[1]])?.Id);
    }

    [Fact]
    public void HowOftenAndTheStatusLine()
    {
        var now = DateTimeOffset.Parse("2026-11-21T12:00:00Z");
        var job = Job("j", expr: "*/15 * * * *", last: "2026-11-21T11:55:00Z");
        Assert.Equal("every 15 min", TileJobs.HowOften(job));
        Assert.Equal("Updated 5 min ago · every 15 min", TileJobs.Status(job, now));
        Assert.Equal("updated 5 min ago", TileJobs.ShortStatus(job, now));
        Assert.Equal("Not updated yet · hourly", TileJobs.Status(Job("j"), now));
        Assert.Equal("Updates paused", TileJobs.Status(Job("j", enabled: false), now));
        Assert.Equal("Update failed 2 hours ago · daily", TileJobs.Status(Job("j", expr: "0 8 * * *", last: "2026-11-21T10:00:00Z", status: "error"), now));
        Assert.Equal("weekdays at 9", TileJobs.HowOften(Job("j", expr: null) with { ScheduleDisplay = "Weekdays at 9" }));
        Assert.Equal("every 3 hours", TileJobs.HowOften(Job("j", expr: null) with { ScheduleDisplay = "every 3h" }));
        Assert.Equal("yesterday", TileJobs.Ago(now.AddDays(-1), now));
        Assert.Equal("just now", TileJobs.Ago(now, now));
        Assert.Equal("1 hour ago", TileJobs.Ago(now.AddMinutes(-61), now));
    }

    [Fact]
    public void ATilesHealth()
    {
        var now = DateTimeOffset.Parse("2026-11-21T12:00:00Z");
        Assert.Equal(TileJobs.HealthKind.None, TileJobs.HealthOf(null, now).Kind);
        Assert.Equal(TileJobs.HealthKind.Fine, TileJobs.HealthOf(Job("j", last: "2026-11-21T11:30:00Z", next: "2026-11-21T12:30:00Z"), now).Kind);
        Assert.Equal(TileJobs.HealthKind.Paused, TileJobs.HealthOf(Job("j", state: "paused"), now).Kind);
        var failed = TileJobs.HealthOf(Job("j", status: "error", error: "Model refused\nmore"), now);
        Assert.Equal(new TileJobs.Health(TileJobs.HealthKind.Failed, "Model refused"), failed);
        Assert.Equal(TileJobs.HealthKind.Late, TileJobs.HealthOf(Job("j", next: "2026-11-21T11:00:00Z"), now).Kind);
        Assert.Equal(TileJobs.HealthKind.Late, TileJobs.HealthOf(Job("j", expr: "*/15 * * * *", last: "2026-11-21T11:00:00Z"), now).Kind);
        var running = Job("j") with { LatestRunStatus = "running", LatestRunClaimedAt = "2026-11-21T11:59:00Z", LastRunAt = "2026-11-21T11:00:00Z" };
        Assert.Equal(TileJobs.HealthKind.Updating, TileJobs.HealthOf(running, now).Kind);
        Assert.Equal("last update failed", TileJobs.Spoken(failed));
        Assert.Equal("page missing", TileJobs.Spoken(new(TileJobs.HealthKind.Failed, TileWords.GoneWords)));
    }

    [Fact]
    public void JobsAreReadLeniently()
    {
        var list = TileCronJob.List(JsonNode.Parse("""
            {"jobs":[{"id":"j1","profile_name":"deploys","schedule":{"kind":"cron","expr":"0 * * * *","display":"0 * * * *"},
                      "enabled":"true","latest_execution":{"status":"claimed","claimed_at":"2026-11-21T10:00:00Z"}},
                     {"name":"no id"}]}
            """));
        var job = Assert.Single(list);
        Assert.Equal("deploys", job.Owner);
        Assert.Equal("deploys|j1", job.Key);
        Assert.Equal("hourly", TileJobs.HowOften(job));
        Assert.True(TileJobs.WorkIsOut(job));
        Assert.Equal("A script, no model", TileJobs.ModelWords(job with { Script = "x.py" }, "Otto", null));
        Assert.Equal("Otto’s own model", TileJobs.ModelWords(job with { Prompt = "go" }, "Otto", null));
        Assert.Equal("Sonnet 5 (Otto’s model)", TileJobs.ModelWords(job with { Prompt = "go" }, "Otto", "Sonnet 5"));
    }

    [Fact]
    public void GatewayTimesReadAsJsDoes()
    {
        Assert.Equal(DateTimeOffset.Parse("2026-11-21T16:40:42-06:00"), TileDates.Parse("2026-11-21T16:40:42-06:00"));
        Assert.Equal(DateTimeOffset.Parse("2026-11-21T00:00:00Z"), TileDates.Parse("2026-11-21"));
        Assert.Equal(DateTimeOffset.Parse("2026-11-21T10:00:00.5Z"), TileDates.Parse("2026-11-21 10:00:00.5Z"));
        Assert.Equal(DateTimeOffset.Parse("2026-11-21T10:00:00+05:30"), TileDates.Parse("2026-11-21T10:00:00+0530"));
        var utc = TimeZoneInfo.Utc;
        Assert.Equal(DateTimeOffset.Parse("2026-11-21T10:00:00Z"), TileDates.Parse("2026-11-21T10:00", utc));
        Assert.Null(TileDates.Parse("2026-02-30T10:00:00Z"));
        Assert.Null(TileDates.Parse("yesterday"));
    }

    // ------------------------------------------------------------------ files

    [Fact]
    public void HowEachKindOpens()
    {
        Assert.Equal(TileFiles.Opening.Html, TileFiles.OpeningOf(Pin("/a/tile.HTML")));
        Assert.Equal(TileFiles.Opening.Markdown, TileFiles.OpeningOf(Pin("/a/notes.md")));
        Assert.Equal(TileFiles.Opening.Text, TileFiles.OpeningOf(Pin("/a/log.txt")));
        Assert.Equal(TileFiles.Opening.Other, TileFiles.OpeningOf(Pin("/a/report.pdf")));
        Assert.Equal(TileFiles.Opening.Image, TileFiles.OpeningOf(TilePin.Make(TileKind.Image, "/a/b.png", "", null)));
        Assert.Equal(TileFiles.Opening.Link, TileFiles.OpeningOf(TilePin.Make(TileKind.Link, "https://example.com/x", "", null)));
        Assert.Equal("report.pdf", TileFiles.Label("file:///home/hermes/report.pdf", TileKind.File));
        Assert.Equal("example.com", TileFiles.Label("https://example.com/news/", TileKind.Link));
        Assert.Null(TilePin.Make(TileKind.Link, "https://example.com", "", null).GatewayPath);
        Assert.Equal([1, 2, 3], TileFiles.DecodeDataUrl("data:application/octet-stream;base64,AQID"));
        Assert.Equal("hi there"u8.ToArray(), TileFiles.DecodeDataUrl("data:text/plain,hi%20there"));
    }

    [Fact]
    public void APageWithoutAViewportGetsOne()
    {
        Assert.Null(TileFiles.WithViewport("<meta name=\"viewport\" content=\"width=device-width\">"));
        Assert.StartsWith("<html><head><meta name=\"viewport\"", TileFiles.WithViewport("<html><head><title>x</title></head></html>"));
        Assert.StartsWith("<html lang=en><head><meta", TileFiles.WithViewport("<html lang=en><body></body></html>"));
        Assert.StartsWith("<meta name=\"viewport\"", TileFiles.WithViewport("<p>bare</p>"));
    }

    [Fact]
    public void FailureWords()
    {
        Assert.Equal("This file is no longer on the computer running Hermes. It may have been moved or deleted.",
            TileFiles.FailureText(new GatewayException("http", "", 404, "{\"detail\":\"File not found\"}"), false));
        Assert.Equal("From an older session whose folder is unknown.",
            TileFiles.FailureText(new GatewayException("http", "", 400, "{\"detail\":\"Session working directory is unavailable\"}"), false));
        Assert.Equal("This image is too large to preview.", TileFiles.FailureText(new GatewayException("http", "", 413), true));
        Assert.True(TileFiles.IsMissing(new GatewayException("http", "", 404)));
        Assert.Equal("1 Item", TileWords.ItemCount(1));
        Assert.Equal("3 Items", TileWords.ItemCount(3));
        Assert.Equal("Its 2 tiles move to Main. Nothing is unpinned.", TileWords.DeletePageMessage(2, "Main"));
    }

    // ------------------------------------------------------------------ sync

    /// A gateway's `profiles.list` default row and `profiles.configure` with compare-and-swap, as Hermes keeps them.
    private sealed class FakeGateway
    {
        public JsonObject Meta { get; } = [];
        public JsonObject Revisions { get; } = [];
        public int Configures;
        public bool Old;

        public Task<JsonNode> Call(string method, JsonObject p, TimeSpan timeout, CancellationToken ct)
        {
            if (method == "profiles.list")
                return Task.FromResult<JsonNode>(new JsonObject
                {
                    ["profiles"] = new JsonArray(new JsonObject
                    {
                        ["name"] = "default", ["is_default"] = true, ["ui_meta"] = JsonNode.Parse(Meta.ToJsonString()), ["ui_meta_revisions"] = JsonNode.Parse(Revisions.ToJsonString()),
                    }),
                });
            if (method == "profiles.configure")
            {
                Configures++;
                if (Old) throw new GatewayException("rpc", "Method not found", rpcCode: -32601);
                foreach (var (k, v) in p.Obj("ui_meta_expected_revisions")!)
                    if ((Revisions.Int(k) ?? 0) != (long)double.Parse(J.AsString(v)!, System.Globalization.CultureInfo.InvariantCulture))
                        return Task.FromResult<JsonNode>(new JsonObject { ["applied"] = new JsonObject { ["ui_meta"] = false } });
                foreach (var (k, v) in p.Obj("ui_meta")!)
                {
                    Meta[k] = JsonNode.Parse(v!.ToJsonString());
                    Revisions[k] = (double)((Revisions.Int(k) ?? 0) + 1);
                }
                return Task.FromResult<JsonNode>(new JsonObject { ["applied"] = new JsonObject { ["ui_meta"] = true } });
            }
            throw new InvalidOperationException(method);
        }
    }

    private static string Temp() => Path.Combine(Path.GetTempPath(), "hqw-tilesync-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task ATileMadeHereGoesUpAndAnotherDeviceTakesItIn()
    {
        var gw = new FakeGateway();
        var dir = Temp();
        var mine = new TilePinStore(Path.Combine(dir, "a.json"));
        var sync = new TileSync(gw.Call, mine, new TileHidden(null), Path.Combine(dir, "a-sync.json"));
        mine.Pin(Pin("/home/hermes/site/tile.html", "deploys", TileSize.Medium));
        await sync.SyncAsync();
        Assert.Equal(1, gw.Configures);
        var envelope = TileSync.Envelope.From(gw.Meta["hermes-hq-sync.pins"])!;
        Assert.Equal(TileSync.DeviceName, envelope.By);
        Assert.Single(envelope.Data.Arr("pins")!);
        Assert.NotNull(TileSync.Envelope.From(gw.Meta["hermes-hq-sync.hidden"]));

        // Another device (empty) takes the gateway's copy.
        var other = new TilePinStore(Path.Combine(dir, "b.json"));
        var otherSync = new TileSync(gw.Call, other, new TileHidden(null), Path.Combine(dir, "b-sync.json"));
        Assert.True(await otherSync.SyncAsync());
        Assert.Equal(TileSize.Medium, Assert.Single(other.Pins).TileSize);

        // It unpins it; the first device follows.
        other.Unpin(other.Pins[0].Id);
        await otherSync.SyncAsync();
        Assert.True(await sync.SyncAsync());
        Assert.Empty(mine.Pins);
        // Nothing changed: nothing is written again.
        var writes = gw.Configures;
        await sync.SyncAsync();
        Assert.Equal(writes, gw.Configures);
    }

    [Fact]
    public async Task TwoDevicesThatHadTilesBeforeTheyMetKeepBoth()
    {
        var gw = new FakeGateway();
        var dir = Temp();
        var a = new TilePinStore(Path.Combine(dir, "a.json"));
        a.Pin(Pin("/a.html"));
        var syncA = new TileSync(gw.Call, a, new TileHidden(null), Path.Combine(dir, "a-sync.json"));
        await syncA.SyncAsync();
        var b = new TilePinStore(Path.Combine(dir, "b.json"));
        b.Pin(Pin("/b.html"));
        var syncB = new TileSync(gw.Call, b, new TileHidden(null), Path.Combine(dir, "b-sync.json"));
        await syncB.SyncAsync();
        Assert.Equal(["/a.html", "/b.html"], b.Pins.Select(p => p.Value));
        await syncA.SyncAsync();
        Assert.Equal(["/a.html", "/b.html"], a.Pins.Select(p => p.Value));
    }

    [Fact]
    public async Task AChangeMadeWhileAnotherDeviceWroteIsRebased()
    {
        var gw = new FakeGateway();
        var dir = Temp();
        var a = new TilePinStore(Path.Combine(dir, "a.json"));
        a.Pin(Pin("/one.html"));
        var syncA = new TileSync(gw.Call, a, new TileHidden(null), Path.Combine(dir, "a-sync.json"));
        await syncA.SyncAsync();
        var b = new TilePinStore(Path.Combine(dir, "b.json"));
        var syncB = new TileSync(gw.Call, b, new TileHidden(null), Path.Combine(dir, "b-sync.json"));
        await syncB.SyncAsync();
        // B adds two; A, not having read, resizes its tile.
        b.Pin(Pin("/two.html"));
        await syncB.SyncAsync();
        a.SetSize(TileSize.Large, a.Pins[0].Id);
        await syncA.SyncAsync();
        Assert.Equal(["/two.html", "/one.html"], a.Pins.Select(p => p.Value));
        Assert.Equal(TileSize.Large, a.Pins.First(p => p.Value == "/one.html").TileSize);
        await syncB.SyncAsync();
        Assert.Equal(TileSize.Large, b.Pins.First(p => p.Value == "/one.html").TileSize);
    }

    [Fact]
    public async Task AnOlderGatewayThatCantKeepThemIsNotAskedAgainUntilTheNextChange()
    {
        var gw = new FakeGateway { Old = true };
        var store = new TilePinStore(null);
        var sync = new TileSync(gw.Call, store, new TileHidden(null), null);
        store.Pin(Pin("/a.html"));
        await sync.SyncAsync();
        Assert.True(sync.CantWrite);
        await sync.SyncAsync();
        Assert.Equal(1, gw.Configures);
        store.Pin(Pin("/b.html"));
        Assert.False(sync.CantWrite);
        await sync.SyncAsync();
        Assert.Equal(2, gw.Configures);
    }

    [Fact]
    public async Task ARefusedWriteIsTriedAgainOnTheNextSync()
    {
        var gw = new FakeGateway();
        var store = new TilePinStore(null);
        store.Pin(Pin("/a.html"));
        gw.Revisions["hermes-hq-sync.pins"] = 0.0;
        // Another writer bumps the revision between this device's read and its write: the swap is refused.
        var refused = new FakeGateway();
        Task<JsonNode> Racing(string m, JsonObject p, TimeSpan t, CancellationToken ct)
        {
            if (m == "profiles.configure" && refused.Configures++ == 0)
                return Task.FromResult<JsonNode>(new JsonObject { ["applied"] = new JsonObject { ["ui_meta"] = false } });
            return gw.Call(m, p, t, ct);
        }
        var racing = new TileSync(Racing, store, new TileHidden(null), null);
        await racing.SyncAsync();
        Assert.Null(gw.Meta["hermes-hq-sync.pins"]);
        await racing.SyncAsync();
        Assert.NotNull(TileSync.Envelope.From(gw.Meta["hermes-hq-sync.pins"]));
    }
}
