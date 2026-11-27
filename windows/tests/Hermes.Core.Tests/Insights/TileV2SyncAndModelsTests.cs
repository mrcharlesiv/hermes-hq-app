using System.Text.Json.Nodes;
using Hermes.Core.Insights;
using Hermes.Core.Net;
using Xunit;

namespace Hermes.Core.Tests.Insights;

public class TileV2SyncAndModelsTests
{
    private sealed class FakeGateway
    {
        public JsonObject Meta { get; } = [];
        public JsonObject Revisions { get; } = [];
        public int Configures;

        public Task<JsonNode> Call(string method, JsonObject p, TimeSpan timeout, CancellationToken ct)
        {
            if (method == "profiles.list")
                return Task.FromResult<JsonNode>(new JsonObject
                {
                    ["profiles"] = new JsonArray(new JsonObject
                    {
                        ["name"] = "default",
                        ["is_default"] = true,
                        ["ui_meta"] = JsonNode.Parse(Meta.ToJsonString()),
                        ["ui_meta_revisions"] = JsonNode.Parse(Revisions.ToJsonString()),
                    }),
                });
            if (method == "profiles.configure")
            {
                Configures++;
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

    private static string TempDir() => Path.Combine(Path.GetTempPath(), "hqw-tilesv2-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void TallAndBannerSizesSpanPackAndFitCorrectly()
    {
        Assert.Equal([TileSize.Small, TileSize.Medium, TileSize.Tall, TileSize.Banner, TileSize.Large, TileSize.ExtraLarge], TileSizes.All);
        Assert.Equal((1, 2), TileSize.Tall.Span());
        Assert.Equal((TileSizes.WholeWidth, 1), TileSize.Banner.Span());
        Assert.Equal(TileSize.Tall, TileSizes.FromRaw("tall"));
        Assert.Equal(TileSize.Banner, TileSizes.FromRaw("banner"));

        // 3-arg Fitting supports Tall and Banner on wide grids while legacy 2-arg Fitting stays compatible.
        Assert.Equal(TileSize.Tall, TileSizes.Fitting(1, 2, gridColumns: 4));
        Assert.Equal(TileSize.Large, TileSizes.Fitting(2, 2, gridColumns: 4));
        Assert.Equal(TileSize.Banner, TileSizes.Fitting(3, 1, gridColumns: 4));
        Assert.Equal(TileSize.Medium, TileSizes.Fitting(3, 1, gridColumns: 2));
        Assert.Equal(TileSize.Large, TileSizes.Fitting(1, 2)); // legacy compatibility

        var (cells, rows) = TileGridPacking.Place([TileSize.Banner.Span(), TileSize.Tall.Span(), TileSize.Small.Span()], columns: 4);
        Assert.Equal(new TileGridPacking.Cell(0, 0, 4, 1), cells[0]);
        Assert.Equal(new TileGridPacking.Cell(0, 1, 1, 2), cells[1]);
        Assert.Equal(new TileGridPacking.Cell(1, 1, 1, 1), cells[2]);
        Assert.Equal(3, rows);
    }

    [Fact]
    public async Task FirstContactWithMacGatewayPreservesBannerTallPageIconsAndUnknownFieldsWithZeroWrites()
    {
        var gw = new FakeGateway();
        var macData = JsonNode.Parse("""
        {
          "pins": [
            {
              "id": "default\u001F~/dash/banner.html",
              "kind": "file",
              "value": "~/dash/banner.html",
              "label": "banner.html",
              "profile": "default",
              "sessionId": "s1",
              "sessionTitle": "Dash",
              "pinnedAt": 1700000000,
              "size": "banner",
              "page": "work",
              "macFutureFlag": true,
              "macNested": { "weight": 3 }
            },
            {
              "id": "default\u001F~/dash/tall.html",
              "kind": "file",
              "value": "~/dash/tall.html",
              "label": "tall.html",
              "profile": "default",
              "sessionId": "s2",
              "sessionTitle": "Dash",
              "pinnedAt": 1700000001,
              "size": "tall"
            },
            {
              "id": "default\u001F~/dash/future.html",
              "kind": "file",
              "value": "~/dash/future.html",
              "label": "future.html",
              "profile": "default",
              "sessionId": "s3",
              "sessionTitle": "Dash",
              "pinnedAt": 1700000002,
              "size": "hero"
            }
          ],
          "pages": [
            { "id": "main", "name": "Main", "symbol": "rectangle.3.group" },
            { "id": "work", "name": "Work", "symbol": "briefcase.fill", "macPageTag": "v2" }
          ],
          "macDocVersion": 2
        }
        """)!;

        gw.Meta["hermes-hq-sync.pins"] = new TileSync.Envelope(1000, "Mac", macData).Json;
        gw.Revisions["hermes-hq-sync.pins"] = 1.0;
        gw.Meta["hermes-hq-sync.hidden"] = new TileSync.Envelope(1000, "Mac", new JsonArray()).Json;
        gw.Revisions["hermes-hq-sync.hidden"] = 1.0;

        var dir = TempDir();
        var pinsPath = Path.Combine(dir, "pins.json");
        var syncPath = Path.Combine(dir, "sync.json");
        var store = new TilePinStore(pinsPath);
        var sync = new TileSync(gw.Call, store, new TileHidden(null), syncPath);

        // First contact must NOT write back to the gateway!
        Assert.True(await sync.SyncAsync());
        Assert.Equal(0, gw.Configures);

        Assert.Equal(TileSize.Banner, store.Pins[0].TileSize);
        Assert.Equal(TileSize.Tall, store.Pins[1].TileSize);
        Assert.Equal("hero", store.Pins[2].RawSize);
        Assert.Equal("rectangle.3.group", store.Pages[0].Symbol);
        Assert.Equal("briefcase.fill", store.Pages[1].Symbol);

        // Cold reopen from disk preserves every field.
        var reopened = new TilePinStore(pinsPath);
        Assert.Equal(TileSize.Banner, reopened.Pins[0].TileSize);
        Assert.Equal(TileSize.Tall, reopened.Pins[1].TileSize);
        Assert.Equal("hero", reopened.Pins[2].RawSize);
        Assert.Equal("briefcase.fill", reopened.Pages[1].Symbol);

        // An unrelated local edit (rename one tile) syncs cleanly and preserves every untouched Mac field!
        var reopenedSync = new TileSync(gw.Call, reopened, new TileHidden(null), syncPath);
        reopened.Rename(reopened.Pins[1].Id, "Tall Renamed");
        await reopenedSync.SyncAsync();
        Assert.Equal(1, gw.Configures);

        var written = TileSync.Envelope.From(gw.Meta["hermes-hq-sync.pins"])!.Data;
        Assert.Equal("banner", written.Arr("pins")![0]!.Str("size"));
        Assert.True(written.Arr("pins")![0]!.Bool("macFutureFlag"));
        Assert.Equal(3L, written.Arr("pins")![0]!.Obj("macNested")!.Int("weight"));
        Assert.Equal("tall", written.Arr("pins")![1]!.Str("size"));
        Assert.Equal("Tall Renamed", written.Arr("pins")![1]!.Str("title"));
        Assert.Equal("hero", written.Arr("pins")![2]!.Str("size"));
        Assert.Equal("rectangle.3.group", written.Arr("pages")![0]!.Str("symbol"));
        Assert.Equal("briefcase.fill", written.Arr("pages")![1]!.Str("symbol"));
        Assert.Equal("v2", written.Arr("pages")![1]!.Str("macPageTag"));
        Assert.Equal(2L, written.Int("macDocVersion"));
    }

    [Fact]
    public void PageSymbolsAndVersionNotesPersist()
    {
        Assert.Equal(12, TilePage.SymbolChoices.Length);
        var path = Path.Combine(TempDir(), "pins.json");
        var store = new TilePinStore(path);
        var page = store.AddPage("Ops", "bolt.fill");
        Assert.Equal("bolt.fill", store.Pages[1].Symbol);
        store.SetPageSymbol(page.Id, "star.fill");
        Assert.Equal("star.fill", store.Pages[1].Symbol);

        var pin = TilePin.Make(TileKind.File, "~/dash/ops.html", "ops.html", "default");
        store.Pin(pin);
        store.NoteVersion(pin.Id, 4);
        Assert.Equal(4, store.Pins[0].Version);

        var again = new TilePinStore(path);
        Assert.Equal("star.fill", again.Pages[1].Symbol);
        Assert.Equal(4, again.Pins[0].Version);
    }

    [Fact]
    public void TileIdeaMatcherRanksAndBadgesIdeasForSelectedBot()
    {
        var neutral = TileIdeaMatcher.RankedFor([]);
        Assert.Equal(18, neutral.Count);
        Assert.All(neutral, r => Assert.False(r.Matched));

        var finance = TileIdeaMatcher.RankedFor(["Revenue Bot", "finance", "Stripe billing & expenses"]);
        Assert.True(finance[0].Matched);
        Assert.Contains(finance.Take(TileIdeaMatcher.FirstIdeas), r => r.Words.Contains("Revenue") && r.Matched);
        Assert.Contains(finance.Take(TileIdeaMatcher.FirstIdeas), r => r.Words.Contains("Spending") && r.Matched);

        var calendar = TileIdeaMatcher.RankedFor(["Executive Assistant", "calendar", "meetings and schedule"]);
        Assert.True(calendar[0].Matched);
        Assert.Contains(calendar.Take(TileIdeaMatcher.FirstIdeas), r => r.Words.Contains("calendar") && r.Matched);
    }

    [Fact]
    public void TileChangeWordsAddsRemovesAndTogglesCleanly()
    {
        var s = TileChangeWords.Toggling("Make it a bar chart", "");
        Assert.Equal("Make it a bar chart", s);
        s = TileChangeWords.Toggling("Compare with last month", s);
        Assert.Equal("Make it a bar chart, compare with last month", s);
        Assert.True(TileChangeWords.Contains(s, "Compare with last month"));
        s = TileChangeWords.Toggling("Make it a bar chart", s);
        Assert.Equal("Compare with last month", s);
        s = TileChangeWords.Toggling("Compare with last month", s);
        Assert.Equal("", s);
    }

    [Fact]
    public void TileActivitySummaryAndEstimatedRunsPerDayComputeAccurately()
    {
        var now = DateTimeOffset.Parse("2026-11-24T12:00:00Z");
        var hourly = new TileCronJob { Id = "j1", Prompt = "refresh", ScheduleExpr = "0 * * * *", Enabled = true };
        var every15 = new TileCronJob { Id = "j2", Prompt = "refresh", ScheduleExpr = "*/15 * * * *", Enabled = true, LastStatus = "failed" };
        var scriptOnly = new TileCronJob { Id = "j3", Script = "update.py", NoAgent = true, ScheduleExpr = "0 * * * *", Enabled = true };
        var paused = new TileCronJob { Id = "j4", Prompt = "refresh", ScheduleExpr = "0 * * * *", Enabled = false };

        Assert.Equal(24.0, TileJobs.EstimatedRunsPerDay(hourly)!.Value, 3);
        Assert.Equal(96.0, TileJobs.EstimatedRunsPerDay(every15)!.Value, 3);
        Assert.Null(TileJobs.EstimatedRunsPerDay(paused));

        var summary = TileActivitySummary.Summarize([hourly, every15, scriptOnly, paused], now);
        Assert.Equal(4, summary.TotalJobs);
        Assert.Equal(3, summary.ActiveJobs);
        Assert.Equal(1, summary.PausedJobs);
        Assert.Equal(1, summary.FailingJobs);
        Assert.Equal(1, summary.ScriptJobs);
        Assert.Equal(120, summary.EstimatedModelRunsPerDay); // 24 + 96 (script-only & paused excluded)
        Assert.Equal("3 active tiles · ~120 model runs/day", summary.Headline);
        Assert.Equal("1 failing · 1 paused · 1 script-only", summary.Detail);
    }

    [Fact]
    public void TileVersionDesignHashIgnoresInlineJsonDataAndNotesNewDesigns()
    {
        var v1a = "<html> <body><h1>Sales</h1><script type=\"application/json\">{\"total\": 100}</script></body></html>";
        var v1b = "<html>\n  <body><h1>Sales</h1><script type='application/json'>\n{\"total\": 9999}\n</script></body></html>";
        var v2 = "<html> <body><h2>Revenue Chart</h2><script type=\"application/json\">{\"total\": 9999}</script></body></html>";

        Assert.Equal(TileVersionFiles.DesignHash(v1a), TileVersionFiles.DesignHash(v1b));
        Assert.NotEqual(TileVersionFiles.DesignHash(v1a), TileVersionFiles.DesignHash(v2));

        var (list1, added1) = TileVersionFiles.Noting(v1a, TileVersionList.Empty, TileVersionKind.Made, "Sales tile", at: 100);
        Assert.NotNull(added1);
        Assert.Equal(1, list1.Current);

        // Same design with updated data adds no new version.
        var (listSame, addedSame) = TileVersionFiles.Noting(v1b, list1, TileVersionKind.Outside, null, at: 200);
        Assert.Null(addedSame);
        Assert.Single(listSame.Versions);

        // New design adds Version 2.
        var (list2, added2) = TileVersionFiles.Noting(v2, list1, TileVersionKind.Changed, "Make it a chart", at: 300);
        Assert.NotNull(added2);
        Assert.Equal(2, list2.Current);
        Assert.Equal(2, list2.Versions.Count);

        // Roll Back (older version) asks confirmation; Restore (newer version) does not.
        Assert.True(TileVersionsModel.AsksFirst(list2.Versions[0], list2));
        Assert.Equal(TileWords.RollBack, TileVersionsModel.Verb(list2.Versions[0], list2));
        var onV1 = list2 with { Current = 1 };
        Assert.False(TileVersionsModel.AsksFirst(onV1.Versions[1], onV1));
        Assert.Equal(TileWords.Restore, TileVersionsModel.Verb(onV1.Versions[1], onV1));

        // Writable Offer enables Versions for page tiles on writable gateways while preserving legacy 2-arg Offer.
        var pagePin = TilePin.Make(TileKind.File, "~/dash/sales.html", "sales.html", "default");
        Assert.Equal(TileVersionsOffer.Hidden, TileVersionsModel.Offer(pagePin, readOnlyGateway: false));
        Assert.Equal(TileVersionsOffer.Enabled, TileVersionsModel.Offer(pagePin, readOnlyGateway: false, supportsWritable: true));
        Assert.DoesNotContain(TileVersionsModel.ReadOnlyWords, TileVersionsModel.Footer(list2, writable: true));
        Assert.Contains(TileVersionsModel.ReadOnlyWords, TileVersionsModel.Footer(list2));
    }
}
