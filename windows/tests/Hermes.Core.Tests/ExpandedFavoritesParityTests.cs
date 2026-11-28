using System.Text.Json.Nodes;
using Hermes.Core.Composer;
using Hermes.Core.Insights;
using Hermes.Core.QuickActions;
using Xunit;

namespace Hermes.Core.Tests;

/// Comprehensive Wave 4A Expanded Favorites parity tests covering all 28 tile kinds, 7 sizes, responsive 2–5 col 2D
/// Bento layout + collapsible sections, FavoritePage CRUD & envelope round-trip (including legacy JSON upgrade),
/// 4 starter presets, sequential Routine execution, FavoritesSync 3-way merge & IsUneditedStarter, and FavoritesPinRules.
public sealed class ExpandedFavoritesParityTests
{
    private sealed class MemoryStore : IKeyValueStore
    {
        public Dictionary<string, string> Map { get; } = [];
        public string? Get(string key) => Map.GetValueOrDefault(key);
        public void Set(string key, string? value)
        {
            if (value == null) Map.Remove(key);
            else Map[key] = value;
        }
    }

    // ------------------------------------------------------------------ 1. All 28 kinds & 7 sizes

    [Fact]
    public void All28TileKindsRoundTripAndHaveWindowsRoutes()
    {
        var all = Enum.GetValues<QuickTileKind>();
        Assert.Equal(28, all.Length);
        Assert.Equal(28, QuickTileRules.Windows.Count);

        var raws = all.Select(k => k.Raw()).ToHashSet(StringComparer.Ordinal);
        Assert.Equal(28, raws.Count);

        foreach (var kind in all)
        {
            Assert.Equal(kind, QuickTileKinds.Parse(kind.Raw()));
            var tile = QuickTile.Create(kind);
            Assert.Equal(kind, tile.Known);
            var encoded = QuickTileStore.Encode(new QuickTileList([tile], seeded: true));
            Assert.NotNull(encoded);
            var decoded = QuickTileStore.Decode(encoded!);
            Assert.NotNull(decoded);
            Assert.Single(decoded!.Tiles);
            Assert.Equal(kind, decoded.Tiles[0].Known);
        }

        // Exactly 10 native live card kinds
        Assert.Equal(10, all.Count(k => k.IsLiveCard()));
        Assert.True(QuickTileKind.DashboardTile.IsPicture());
        Assert.True(QuickTileKind.Section.IsSection());
    }

    [Fact]
    public void MemoAndTalkRouteOnWindowsAndLinkRejectsUnsafeSchemes()
    {
        var world = new QuickTileWorld(Bots: new Dictionary<string, string> { ["otto"] = "Otto" });
        var memo = QuickTile.Create(QuickTileKind.Memo) with { Bot = "otto", BotName = "Otto" };
        var talk = QuickTile.Create(QuickTileKind.Talk) with { Bot = "otto", BotName = "Otto" };
        Assert.Equal(new QuickTileRoute.Memo("otto"), QuickTileRoute.Make(memo, world, QuickTileRules.Windows));
        Assert.Equal(new QuickTileRoute.Talk("otto"), QuickTileRoute.Make(talk, world, QuickTileRules.Windows));

        // Link URL normalization & scheme safety
        Assert.Equal("https://example.com/", QuickTileRoute.NormalizedUrl("example.com")?.AbsoluteUri);
        Assert.Equal("http://localhost:8080/a", QuickTileRoute.NormalizedUrl("http://localhost:8080/a")?.AbsoluteUri);
        Assert.Null(QuickTileRoute.NormalizedUrl("javascript:alert(1)"));
        Assert.Null(QuickTileRoute.NormalizedUrl("file:///etc/passwd"));
        Assert.Null(QuickTileRoute.NormalizedUrl("   "));

        var badLink = QuickTile.Create(QuickTileKind.Link) with { Url = "javascript:alert(1)" };
        Assert.IsType<QuickTileRoute.Unavailable>(QuickTileRoute.Make(badLink, world, QuickTileRules.Windows));
        Assert.False(QuickTileDraft.CanSave(badLink));

        var goodLink = QuickTile.Create(QuickTileKind.Link) with { Name = "Docs", Url = "hermes.example/docs" };
        Assert.True(QuickTileDraft.CanSave(goodLink));
        var linkRoute = Assert.IsType<QuickTileRoute.Link>(QuickTileRoute.Make(goodLink, world, QuickTileRules.Windows));
        Assert.Equal("https://hermes.example/docs", linkRoute.Url.AbsoluteUri);
    }

    [Fact]
    public void All7SizesSpanCorrectlyAndRespectKindCapabilities()
    {
        var allSizes = Enum.GetValues<QuickTileSize>();
        Assert.Equal(7, allSizes.Length);
        foreach (var s in allSizes) Assert.Equal(s, QuickTileSizes.Parse(s.Raw()));

        Assert.Equal(1, QuickTileSize.Small.ColSpan(4));
        Assert.Equal(2, QuickTileSize.Wide.ColSpan(4));
        Assert.Equal(1, QuickTileSize.TallCard.ColSpan(4));
        Assert.Equal(2, QuickTileSize.TallCard.RowSpan());
        Assert.Equal(2, QuickTileSize.Large.ColSpan(4));
        Assert.Equal(2, QuickTileSize.Large.RowSpan());
        Assert.Equal(4, QuickTileSize.Banner.ColSpan(4));
        Assert.Equal(1, QuickTileSize.Banner.RowSpan());
        Assert.Equal(4, QuickTileSize.ExtraLarge.ColSpan(4));
        Assert.Equal(2, QuickTileSize.ExtraLarge.RowSpan());

        // Action tiles cannot use multi-row sizes; live cards cannot use Mini or Short
        var action = QuickTile.Create(QuickTileKind.NewChat, size: QuickTileSize.Large);
        Assert.Equal(QuickTileSize.Wide, action.EffectiveSize);
        var card = QuickTile.Create(QuickTileKind.Tasks, size: QuickTileSize.Mini);
        Assert.Equal(QuickTileSize.Small, card.EffectiveSize);

        var list = new QuickTileList([QuickTile.Create(QuickTileKind.Tasks, id: "t1")], seeded: true);
        list.SetShort("t1", true);
        Assert.False(list.Tiles[0].Short);
        list.SetSize("t1", QuickTileSize.Large);
        Assert.Equal(QuickTileSize.Large, list.Tiles[0].EffectiveSize);
        Assert.True(list.Tiles[0].Wide);
    }

    // ------------------------------------------------------------------ 2. Responsive 2–5 col 2D Bento + Collapsible Sections

    [Fact]
    public void BentoColumnsScaleFrom1To5AndPackMiniAndMultiRowBands()
    {
        Assert.Equal(1, QuickTileLayout.Columns(1200, 12, stacked: true));
        Assert.Equal(2, QuickTileLayout.Columns(500, 12, stacked: false));
        Assert.Equal(3, QuickTileLayout.Columns(700, 12, stacked: false));
        Assert.Equal(4, QuickTileLayout.Columns(920, 12, stacked: false));
        Assert.Equal(5, QuickTileLayout.Columns(1200, 12, stacked: false));

        // 4 Mini tiles pack across one dense strip on a 2-col (500px) canvas; 2-row TallCard packs 2 Small cards beside it.
        var tiles = new[]
        {
            QuickTile.Create(QuickTileKind.Section, id: "sec", name: "Quick"),
            QuickTile.Create(QuickTileKind.Memo, id: "m1", size: QuickTileSize.Mini),
            QuickTile.Create(QuickTileKind.Talk, id: "m2", size: QuickTileSize.Mini),
            QuickTile.Create(QuickTileKind.QuickAsk, id: "m3", size: QuickTileSize.Mini),
            QuickTile.Create(QuickTileKind.AddTask, id: "m4", size: QuickTileSize.Mini),
            QuickTile.Create(QuickTileKind.Tasks, id: "tall", size: QuickTileSize.TallCard),
            QuickTile.Create(QuickTileKind.GatewayStatus, id: "s1", size: QuickTileSize.Small),
            QuickTile.Create(QuickTileKind.Usage, id: "s2", size: QuickTileSize.Small),
        };
        var metrics = new QuickTileBentoMetrics(Width: 500, Gap: 12, Stacked: false);
        var result = QuickTileLayout.Compute(tiles, metrics);

        Assert.Equal(2, result.Columns);
        Assert.Equal(8, result.Placements.Count);

        // Section spans full width at y = 0
        Assert.Equal(500, result.Placements[0].Frame.Width);
        Assert.Equal(0, result.Placements[0].Frame.Y);

        // All 4 Mini tiles share one horizontal strip row (2 * 2 cols = 4 across)
        var miniY = result.Placements[1].Frame.Y;
        Assert.All(result.Placements.Skip(1).Take(4), p => Assert.Equal(miniY, p.Frame.Y));
        Assert.True(result.Placements[4].Frame.X > result.Placements[1].Frame.X);

        // TallCard (col 0, rows 0..1) has s1 at (col 1, row 0) and s2 at (col 1, row 1) stacked beside it!
        var tallFrame = result.Placements[5].Frame;
        var s1Frame = result.Placements[6].Frame;
        var s2Frame = result.Placements[7].Frame;
        Assert.Equal(0, tallFrame.X);
        Assert.True(s1Frame.X > 0);
        Assert.Equal(s1Frame.X, s2Frame.X);
        Assert.Equal(tallFrame.Y, s1Frame.Y);
        Assert.True(s2Frame.Y > s1Frame.Y);
        Assert.Equal(tallFrame.Height, s1Frame.Height + s2Frame.Height + metrics.Gap, precision: 3);
    }

    [Fact]
    public void CollapsibleSectionsHideItemsUntilExpandedAndCountHiddenItems()
    {
        var list = new QuickTileList([
            QuickTile.Create(QuickTileKind.Section, id: "sec1", name: "Ops"),
            QuickTile.Create(QuickTileKind.GatewayStatus, id: "gw"),
            QuickTile.Create(QuickTileKind.Usage, id: "u"),
            QuickTile.Create(QuickTileKind.Section, id: "sec2", name: "Chats"),
            QuickTile.Create(QuickTileKind.Search, id: "srch"),
        ], seeded: true);

        Assert.Equal(2, list.SectionItemCount("sec1"));
        Assert.Equal(1, list.SectionItemCount("sec2"));
        Assert.Equal(5, list.VisibleTiles().Count);

        list.ToggleSection("sec1");
        var visible = list.VisibleTiles();
        Assert.Equal(["sec1", "sec2", "srch"], visible.Select(t => t.Id).ToArray());
        // Edit / search mode can still see collapsed tiles
        Assert.Equal(5, list.VisibleTiles(includeCollapsed: true).Count);

        list.ToggleSection("sec1");
        Assert.Equal(5, list.VisibleTiles().Count);
    }

    // ------------------------------------------------------------------ 3. FavoritePage CRUD & Legacy JSON Upgrade

    [Fact]
    public void FavoritePageCrudAndLegacyEnvelopeUpgrade()
    {
        // Legacy JSON without `pages` or `size` decodes cleanly
        var legacyJson = """{"seeded":true,"tiles":[{"color":"orange","id":"t1","kind":"add-task","name":"Add Task","symbol":"checklist","wide":true}],"version":1}""";
        var upgraded = QuickTileStore.Decode(legacyJson);
        Assert.NotNull(upgraded);
        Assert.Single(upgraded!.Tiles);
        Assert.Equal(QuickTileSize.Wide, upgraded.Tiles[0].EffectiveSize);
        Assert.Empty(upgraded.Pages);
        Assert.Single(upgraded.AllPages);
        Assert.Equal(FavoritePage.Main, upgraded.AllPages[0]);
        Assert.Equal(12, FavoritePage.SymbolChoices.Length);

        // Add, rename, icon, move, reorder, delete page (tiles move back to Home)
        var work = upgraded.AddPage("Work", "briefcase.fill");
        var ops = upgraded.AddPage("Ops", "bolt.fill");
        Assert.True(upgraded.HasMultiplePages);
        Assert.Equal([FavoritePage.MainId, work.Id, ops.Id], upgraded.AllPages.Select(p => p.Id).ToArray());

        upgraded.RenamePage(work.Id, "Studio");
        upgraded.SetPageSymbol(work.Id, "sparkles");
        Assert.Equal("Studio", upgraded.AllPages[1].Name);
        Assert.Equal("sparkles", upgraded.AllPages[1].Symbol);

        upgraded.MovePage(ops.Id, -1);
        Assert.Equal([FavoritePage.MainId, ops.Id, work.Id], upgraded.AllPages.Select(p => p.Id).ToArray());

        upgraded.MoveTile("t1", work.Id);
        Assert.Single(upgraded.TilesOn(work.Id));
        Assert.Empty(upgraded.TilesOn(FavoritePage.MainId));

        // Round-trip envelope with pages
        var store = new MemoryStore();
        Assert.True(QuickTileStore.Save(upgraded, store));
        var reloaded = QuickTileStore.Load(store);
        Assert.Equal(upgraded, reloaded);
        Assert.Equal(3, reloaded.AllPages.Count);

        // Deleting a custom page moves its tiles back to Home (`main`)
        reloaded.DeletePage(work.Id);
        Assert.Single(reloaded.TilesOn(FavoritePage.MainId));
        Assert.Null(reloaded.Tiles[0].PageId);
    }

    // ------------------------------------------------------------------ 4. Four Starter Presets

    [Fact]
    public void AllFourStarterPresetsGenerateValidTilesForTargetPage()
    {
        Assert.Equal(4, FavoritePresets.All.Length);
        foreach (var preset in FavoritePresets.All)
        {
            var tiles = preset.Tiles(("otto", "Otto"), ("g1", "Ship Beta"), pageId: "work");
            Assert.NotEmpty(tiles);
            Assert.All(tiles, t =>
            {
                Assert.NotNull(t.Known);
                Assert.Equal("work", t.ResolvedPageId);
                Assert.False(string.IsNullOrWhiteSpace(t.Name));
            });
        }

        // CommandCenter starts with 4 Mini quick actions
        var cc = FavoritePreset.CommandCenter.Tiles(("otto", "Otto"));
        Assert.Equal(4, cc.Take(4).Count(t => t.EffectiveSize == QuickTileSize.Mini));
    }

    // ------------------------------------------------------------------ 5. Sequential Routine Execution

    [Fact]
    public async Task RoutineRunsBackgroundStepsInOrderThenLastForegroundStepOnly()
    {
        var log = new List<string>();
        var steps = new[]
        {
            QuickRoutineStep.Create(QuickRoutineStepKind.RunJob) with { Job = "otto|j1", JobName = "Digest" },
            QuickRoutineStep.Create(QuickRoutineStepKind.OpenPage) with { Page = "tasks", PageName = "Tasks" },
            QuickRoutineStep.Create(QuickRoutineStepKind.Send) with { Bot = "ivy", Message = "Summarize" },
            QuickRoutineStep.Create(QuickRoutineStepKind.OpenChat) with { Bot = "herald" },
        };

        var result = await QuickTileRun.RunRoutineAsync(
            steps,
            "Morning Flow",
            runJob: (step, _) => { log.Add("job:" + step.Job); return Task.FromResult<QuickTileSaid>(new QuickTileSaid.Done("ok")); },
            sendMessage: (step, _) => { log.Add("send:" + step.Bot + ":" + step.Message); return Task.FromResult<QuickTileSaid>(new QuickTileSaid.Done("ok")); },
            runForeground: (step, _) => { log.Add("fg:" + step.KnownKind + ":" + step.Bot); return Task.CompletedTask; });

        Assert.True(result.Ok);
        Assert.Equal(2, result.Succeeded);
        Assert.Equal(["job:otto|j1", "send:ivy:Summarize", "fg:OpenChat:herald"], log);
        Assert.Equal(QuickRoutineStepKind.OpenChat, result.ForegroundStep?.KnownKind);

        // Pure background routine reports stays-on-page
        var bgRoutine = QuickTile.Create(QuickTileKind.Routine) with
        {
            Steps = [QuickRoutineStep.Create(QuickRoutineStepKind.RunJob) with { Job = "otto|j1", JobName = "Digest" }],
        };
        var route = QuickTileRoute.Make(bgRoutine, new QuickTileWorld(), QuickTileRules.Windows);
        Assert.True(route.StaysOnPage);
    }

    // ------------------------------------------------------------------ 6. FavoritesSync 3-way merge & IsUneditedStarter

    [Fact]
    public void FavoritesSyncDetectsUneditedStarterAndPerformsThreeWayRebaseMerge()
    {
        var starter = new QuickTileList(QuickTileStore.Starter("otto", "Otto"), seeded: true);
        Assert.True(QuickTileStore.IsUneditedStarter(starter));

        var customized = starter.Copy();
        customized.Add(QuickTile.Create(QuickTileKind.Usage, id: "custom-1"));
        Assert.False(QuickTileStore.IsUneditedStarter(customized));

        // FirstContact replaces an unedited starter cleanly with the remote customized list
        var remoteList = new QuickTileList([QuickTile.Create(QuickTileKind.GatewayStatus, id: "r1")], seeded: true,
            pages: [FavoritePage.Main, new FavoritePage("ops", "Ops", "bolt.fill")]);
        var first = FavoritesSync.AdoptSynced(starter, FavoritesSync.SyncValue(remoteList), TileSyncMerge.FirstContact);
        Assert.NotNull(first);
        Assert.Equal(["r1"], first!.Tiles.Select(t => t.Id).ToArray());
        Assert.Equal(2, first.AllPages.Count);

        // 3-way Rebase preserves local addition, remote addition, and removes remote deletion
        var baseList = new QuickTileList([
            QuickTile.Create(QuickTileKind.Search, id: "keep"),
            QuickTile.Create(QuickTileKind.AddTask, id: "drop-remote"),
        ], seeded: true);
        var localList = baseList.Copy();
        localList.Add(QuickTile.Create(QuickTileKind.Usage, id: "local-new"));
        var serverList = new QuickTileList([
            QuickTile.Create(QuickTileKind.Search, id: "keep"),
            QuickTile.Create(QuickTileKind.NeedsYou, id: "remote-new"),
        ], seeded: true);

        var rebased = FavoritesSync.AdoptSynced(localList, FavoritesSync.SyncValue(serverList), TileSyncMerge.Rebase,
            FavoritesSync.SyncValue(baseList));
        Assert.NotNull(rebased);
        var ids = rebased!.Tiles.Select(t => t.Id).ToHashSet();
        Assert.Contains("keep", ids);
        Assert.Contains("local-new", ids);
        Assert.Contains("remote-new", ids);
        Assert.DoesNotContain("drop-remote", ids);
    }

    [Fact]
    public async Task FavoritesSyncPublishesToUiMetaWithCompareAndSwap()
    {
        var store = new MemoryStore();
        var list = new QuickTileList([QuickTile.Create(QuickTileKind.GatewayStatus, id: "g1")], seeded: true);
        QuickTileStore.Save(list, store, notifySync: false);

        JsonObject? configuredParams = null;
        Task<JsonNode> FakeRpc(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct)
        {
            if (method == "profiles.list")
            {
                return Task.FromResult<JsonNode>(new JsonObject
                {
                    ["profiles"] = new JsonArray(new JsonObject
                    {
                        ["name"] = "default",
                        ["is_default"] = true,
                        ["ui_meta"] = new JsonObject(),
                        ["ui_meta_revisions"] = new JsonObject { [FavoritesSync.MetaKey] = 3 },
                    }),
                });
            }
            configuredParams = (JsonObject)parameters.DeepClone();
            return Task.FromResult<JsonNode>(new JsonObject
            {
                ["applied"] = new JsonObject { ["ui_meta"] = true },
            });
        }

        using var sync = new FavoritesSync(FakeRpc, store);
        await sync.SyncAsync();

        Assert.Equal(1, sync.Writes);
        Assert.NotNull(configuredParams);
        Assert.Equal("default", configuredParams!["name"]?.GetValue<string>());
        Assert.Equal(3L, configuredParams["ui_meta_expected_revisions"]?[FavoritesSync.MetaKey]?.GetValue<long>());
        var envelope = configuredParams["ui_meta"]?[FavoritesSync.MetaKey];
        Assert.NotNull(envelope);
        Assert.Equal(1, envelope!["v"]?.GetValue<int>());
        var decoded = FavoritesSync.DecodeSynced(envelope["data"]);
        Assert.NotNull(decoded);
        Assert.Equal(["g1"], decoded!.Tiles.Select(t => t.Id).ToArray());
    }

    // ------------------------------------------------------------------ 7. FavoritesPinRules deduplication

    [Fact]
    public void FavoritesPinRulesDeduplicatesAndStampsPageAndGateway()
    {
        var store = new MemoryStore();
        var list = new QuickTileList([], seeded: true);
        var work = list.AddPage("Work", "briefcase.fill");
        QuickTileStore.Save(list, store, notifySync: false);
        QuickTileStore.SetCurrentPage(work.Id, store);

        var added = FavoritesPinRules.Toggle(
            store,
            FavoritesPinRules.BotMatch("otto"),
            () => QuickTile.Create(QuickTileKind.BotCard, name: "Otto") with { Bot = "otto", BotName = "Otto" },
            gatewayId: "gw-demo");
        Assert.True(added);
        Assert.True(FavoritesPinRules.Contains(store, FavoritesPinRules.BotMatch("otto")));

        var saved = QuickTileStore.Load(store);
        Assert.Single(saved.Tiles);
        Assert.Equal(work.Id, saved.Tiles[0].PageId);
        Assert.Equal("gw-demo", saved.Tiles[0].GatewayId);

        // Second toggle removes rather than duplicating
        var addedAgain = FavoritesPinRules.Toggle(
            store,
            FavoritesPinRules.BotMatch("otto"),
            () => QuickTile.Create(QuickTileKind.BotCard, name: "Otto") with { Bot = "otto", BotName = "Otto" });
        Assert.False(addedAgain);
        Assert.False(FavoritesPinRules.Contains(store, FavoritesPinRules.BotMatch("otto")));
        Assert.Empty(QuickTileStore.Load(store).Tiles);
    }
}
