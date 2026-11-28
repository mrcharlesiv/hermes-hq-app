using System.Text.Json.Nodes;
using Hermes.Core.Composer;
using Hermes.Core.Insights;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests;

/// Wave 4B parity tests covering Tiles v2 polish (`28b14acf7`, `35066e38c`, `53f8574db`) & Command Center
/// read-only / cloud update parity: `TilePendingStore` persistence & 30-min prune, `TileChats.IsTileChat`/`ToHide`,
/// `TileModels` & `TileModelSync.ReconcileAsync`/`ReconcileAllAsync`, `TilePin` model override & `NoteChat`,
/// `TileUpdates` concurrent prefetch + active 4 s polling & prior-poll cancellation, `__hqApplyTheme` script
/// generation & `themeKey`, `HermesUpdateKind.Cloud`, and `TileLiveGuard` busy/1 s throttle guards.
public class TilesV2PolishParityTests
{
    private static TilePin PagePin(string path, string profile = "default", string sessionId = "s-1", string sessionTitle = "Chat",
        string? jobId = null) =>
        TilePin.Make(TileKind.File, path, "", profile, sessionId, sessionTitle, 1790000000) with { JobId = jobId };

    private static TileCronJob CronJob(string id, string owner = "default", string? prompt = "Update /dash/rev.html",
        string? model = null, string? provider = null, string? lastRunAt = null, string? latestStatus = null,
        bool noAgent = false, string? script = null) => new()
    {
        Id = id,
        Profile = owner,
        Prompt = prompt,
        Model = model,
        Provider = provider,
        ScheduleExpr = "0 * * * *",
        LastRunAt = lastRunAt,
        LatestRunStatus = latestStatus,
        NoAgent = noAgent,
        Script = script,
    };

    // ------------------------------------------------------------------ TilePendingStore

    [Fact]
    public void PendingStorePersistsUnderAccountPrefixAndPrunesAfter30Minutes()
    {
        var store = new MemoryStore();
        var now = DateTimeOffset.Parse("2026-11-28T12:00:00Z");
        var fresh = new PendingTileMaker
        {
            Id = "m-fresh",
            AccountId = "acct-1",
            SessionId = "sess-fresh",
            BotId = "finance",
            What = "Revenue this week",
            DashboardPage = TilePage.MainId,
            DesiredSize = TileSize.Large,
            AskedAt = now.AddMinutes(-10).ToUnixTimeSeconds(),
        };
        var stale = fresh with
        {
            Id = "m-stale",
            SessionId = "sess-stale",
            AskedAt = now.AddMinutes(-31).ToUnixTimeSeconds(),
        };

        Assert.Equal("hq.tilePendingMakers.acct-1", TilePendingStore.Key("acct-1"));
        Assert.Equal(TimeSpan.FromMinutes(30), TilePendingStore.MaxAge);

        TilePendingStore.Save([fresh, stale], "acct-1", store);
        Assert.NotNull(store.Get("hq.tilePendingMakers.acct-1"));

        var loaded = TilePendingStore.Load("acct-1", store, now);
        var kept = Assert.Single(loaded);
        Assert.Equal("m-fresh", kept.Id);
        Assert.Equal(TileSize.Large, kept.DesiredSize);

        // Deduplicates by SessionId on Add/Upsert and removes cleanly.
        var updated = fresh with { Id = "m-fresh-2", What = "Revenue + expenses" };
        TilePendingStore.Add(updated, store, now);
        var afterUpsert = TilePendingStore.Load("acct-1", store, now);
        Assert.Equal("m-fresh-2", Assert.Single(afterUpsert).Id);

        TilePendingStore.Remove("m-fresh-2", "acct-1", store);
        Assert.Empty(TilePendingStore.Load("acct-1", store, now));
        Assert.Null(store.Get("hq.tilePendingMakers.acct-1"));
    }

    // ------------------------------------------------------------------ TileChats

    [Fact]
    public void TileChatsDetectsOpeningsAndHidesTileSessionsOnly()
    {
        Assert.True(TileChats.IsTileChat("Make me a live tile for my Hermes HQ Dashboard showing: Revenue"));
        Assert.True(TileChats.IsTileChat("Change my Hermes HQ Dashboard tile /dash/rev.html: bar chart"));
        Assert.True(TileChats.IsTileChat("I rolled my Hermes HQ tile “Revenue” back to its version 2"));
        Assert.True(TileChats.IsTileChat("Keep my Hermes HQ Dashboard tile “Revenue” up to date"));
        Assert.True(TileChats.IsTileChat("New tile: Weather today"));
        Assert.True(TileChats.IsTileChat("Change tile Revenue: bigger numbers"));
        Assert.False(TileChats.IsTileChat("Weekly project standup"));
        Assert.False(TileChats.IsTileChat(null));

        var sessions = new[]
        {
            new SessionSummary { Id = "s-make", Profile = "default", Title = "Revenue", Preview = "Make me a live tile for my Hermes HQ Dashboard showing: Revenue" },
            new SessionSummary { Id = "s-note", Profile = "default", Title = "Tile Session", Preview = "Done" },
            new SessionSummary { Id = "s-normal", Profile = "default", Title = "Q3 Planning", Preview = "Here is the Q3 chart" },
        };
        var pins = new[]
        {
            PagePin("/dash/noted.html", sessionId: "s-note", sessionTitle: "Tile Session") with { ChatAt = 1790000100 },
            PagePin("/dash/normal.html", sessionId: "s-normal", sessionTitle: "Q3 Planning"),
        };

        var hidden = TileChats.ToHide(sessions, pins);
        Assert.Contains("s-make", hidden);
        Assert.Contains("s-note", hidden);
        Assert.DoesNotContain("s-normal", hidden);
    }

    // ------------------------------------------------------------------ TileModels & TileModelSync

    [Fact]
    public void TileModelsDesiredAndReconcileWriteAndClearOverrides()
    {
        var store = new MemoryStore();
        var settings = new TileModelSettings("acct-1", store);
        var defaultPick = new TileModelPick("anthropic", "claude-sonnet-4-5");
        var fallbackPick = new TileModelPick("openai", "gpt-4.1-mini");
        var overridePick = new TileModelPick("openai", "gpt-5.4");
        settings.DefaultModel = defaultPick;
        settings.FallbackModel = fallbackPick;

        Assert.Equal("hq.tileModels.default|acct-1", TileModelSettings.Key("default", "acct-1"));
        Assert.Equal(defaultPick, settings.DefaultModel);
        Assert.Equal(fallbackPick, settings.FallbackModel);

        // Unpinned job receives default + fallback_providers.
        var unpinned = CronJob("j1", model: null, provider: null);
        var plan1 = settings.Plan(unpinned)!;
        Assert.Equal(defaultPick, plan1.Pin);
        Assert.Equal(TileModels.FallbackAction.Set, plan1.Fallback);
        var u1 = plan1.Updates();
        Assert.Equal("claude-sonnet-4-5", u1.Str("model"));
        Assert.Equal("anthropic", u1.Str("provider"));
        Assert.Single(u1.Arr("fallback_providers")!);

        // Script-only job is never modified.
        Assert.Null(settings.Plan(CronJob("j-script", prompt: "", script: "refresh.py")));
        Assert.Null(settings.Plan(CronJob("j-noagent", noAgent: true)));

        // Hand-pinned job (no applied record) is left alone when no per-tile override exists.
        var handPinned = CronJob("j-hand", model: "gemini-2.5-pro", provider: "gemini");
        Assert.Null(settings.Plan(handPinned));

        // Setting per-tile override overrides even a hand pin; clearing override reverts to default/bot.
        settings.SetOverride(overridePick, unpinned.Key);
        var planOverride = settings.Plan(unpinned)!;
        Assert.Equal(overridePick, planOverride.Pin);
        Assert.Equal("gpt-5.4", planOverride.Updates().Str("model"));
    }

    [Fact]
    public async Task TileModelSyncReconcileWritesPutAndClearsPinWhenRevertingToBotDefault()
    {
        var store = new MemoryStore();
        var sync = new TileModelSync();
        var settings = new TileModelSettings("acct-sync", store);
        var pick = new TileModelPick("anthropic", "claude-sonnet-4-5");
        var fallback = new TileModelPick("openai", "gpt-4.1-mini");
        settings.DefaultModel = pick;
        settings.FallbackModel = fallback;

        var writes = new List<(string JobId, JsonObject Updates)>();
        Task<TileModelSync.WriteResult> Writer(TileCronJob job, JsonObject updates, CancellationToken _)
        {
            writes.Add((job.Id, updates));
            return Task.FromResult(TileModelSync.WriteResult.Done);
        }

        var job = CronJob("j-rev", owner: "finance");
        var first = await sync.ReconcileAsync(job, "acct-sync", store, Writer, force: true);
        Assert.Equal(TileModelSync.OutcomeKind.Changed, first.Kind);
        Assert.Single(writes);
        Assert.Equal("claude-sonnet-4-5", writes[0].Updates.Str("model"));
        Assert.Equal("anthropic", writes[0].Updates.Str("provider"));
        Assert.Single(writes[0].Updates.Arr("fallback_providers")!);
        Assert.Equal(pick, settings.Applied(job.Key)?.Pin);
        Assert.Equal(fallback, settings.Applied(job.Key)?.Fallback);

        // Now revert account default & fallback back to null (each bot's own): reconciles with nulls to clear override.
        settings.DefaultModel = null;
        settings.FallbackModel = null;
        var pinnedJob = job with { Model = pick.Model, Provider = pick.Provider };
        var second = await sync.ReconcileAsync(pinnedJob, "acct-sync", store, Writer, force: true);
        Assert.Equal(TileModelSync.OutcomeKind.Changed, second.Kind);
        Assert.Equal(2, writes.Count);
        Assert.Null(writes[1].Updates["model"]);
        Assert.Null(writes[1].Updates["provider"]);
        Assert.Null(writes[1].Updates["fallback_providers"]);
        Assert.Null(settings.Applied(job.Key));

        // Read-only gateway never writes.
        settings.DefaultModel = pick;
        var ro = await sync.ReconcileAsync(job, "acct-sync", store, Writer, readOnlyGateway: true, force: true);
        Assert.Equal(TileModelSync.OutcomeKind.Unchanged, ro.Kind);
        Assert.Equal(2, writes.Count);
    }

    [Fact]
    public async Task TileModelSyncReconcileAllDeduplicatesJobsAndReportsSummary()
    {
        var store = new MemoryStore();
        var sync = new TileModelSync();
        var settings = new TileModelSettings("acct-all", store) { DefaultModel = new TileModelPick("openai", "gpt-5.4") };
        var sharedJob = CronJob("j-shared", owner: "default");
        var pins = new[]
        {
            PagePin("/dash/a.html", jobId: "j-shared"),
            PagePin("/dash/b.html", jobId: "j-shared"),
        };
        var count = 0;
        var (changed, failed) = await sync.ReconcileAllAsync(
            pins,
            "acct-all",
            store,
            (_, _) => Task.FromResult<TileCronJob?>(sharedJob),
            (_, _, _) => { count++; return Task.FromResult(TileModelSync.WriteResult.Done); });

        Assert.Equal(1, changed);
        Assert.Equal(1, count);
        Assert.Empty(failed);
        Assert.Equal("1 tile’s job changed.", TileModels.AppliedWords(changed, failed));
    }

    // ------------------------------------------------------------------ TilePin model overrides, NoteChat, ReorderPage

    [Fact]
    public void TilePinPreservesUnknownFieldsAndRoundTripsModelOverridesAndNoteChat()
    {
        var raw = JsonNode.Parse("""
            {"id":"default\u001F/dash/rev.html","kind":"file","value":"/dash/rev.html","label":"rev.html",
             "profile":"default","sessionId":"s-0","sessionTitle":"Old","pinnedAt":1790000000,
             "modelOverride":"gpt-5.4","providerOverride":"openai","futureFlag":true}
            """);
        var pin = TilePin.FromJson(raw)!;
        Assert.Equal("gpt-5.4", pin.ModelOverride);
        Assert.Equal("openai", pin.ProviderOverride);
        var serialized = pin.ToJson();
        Assert.Equal("gpt-5.4", serialized.Str("modelOverride"));
        Assert.Equal("openai", serialized.Str("providerOverride"));
        Assert.True(serialized.Bool("futureFlag"));

        var store = new TilePinStore(null);
        store.Pin(pin);
        store.NoteChat(pin.Id, "s-new", "Change tile Revenue: bar chart", DateTimeOffset.FromUnixTimeSeconds(1790000500));
        store.SetModelOverride(pin.Id, null, null);
        var updated = store.Pins[0];
        Assert.Equal("s-new", updated.SessionId);
        Assert.Equal("Change tile Revenue: bar chart", updated.SessionTitle);
        Assert.Equal(1790000500, updated.ChatAt);
        Assert.Null(updated.ModelOverride);
        Assert.Null(updated.ProviderOverride);
        Assert.False(updated.ToJson().ContainsKey("modelOverride"));

        // ReorderPage onto Main lands at index 1 (Main always stays at 0).
        var p1 = store.AddPage("Work");
        var p2 = store.AddPage("Ops");
        store.ReorderPage(p2.Id, TilePage.MainId);
        Assert.Equal([TilePage.MainId, p2.Id, p1.Id], store.Pages.Select(p => p.Id));
    }

    // ------------------------------------------------------------------ TileUpdates prefetch + active 4s polling

    [Fact]
    public async Task TileUpdatesPrefetchRunsConcurrentlyAndPollsUntilFinished()
    {
        var active = 0;
        var maxConcurrent = 0;
        var pollCount = 0;
        var pin = PagePin("/dash/rev.html", profile: "finance", jobId: "j-1");
        var initialJob = CronJob("j-1", owner: "finance", lastRunAt: "2026-11-28T10:00:00Z");

        var updates = new TileUpdates(
            readList: async (profile, ct) =>
            {
                var cur = Interlocked.Increment(ref active);
                Interlocked.Exchange(ref maxConcurrent, Math.Max(maxConcurrent, cur));
                await Task.Delay(25, ct);
                Interlocked.Decrement(ref active);
                if (profile == "finance")
                {
                    var n = Interlocked.Increment(ref pollCount);
                    var job = n < 3
                        ? initialJob with { LatestRunStatus = "running" }
                        : initialJob with { LastRunAt = "2026-11-28T10:05:00Z", LatestRunStatus = "succeeded" };
                    return [job];
                }
                return [];
            },
            runNow: (_, _) => Task.CompletedTask)
        {
            PollInterval = TimeSpan.FromMilliseconds(5),
        };

        await updates.PrefetchAsync(["bot-a", "bot-b", "bot-c", "bot-d"], maxConcurrency: 4);
        Assert.True(maxConcurrent >= 2, $"Expected concurrent prefetch, saw max {maxConcurrent}");

        TileCronJob? finishedJob = null;
        var completed = await updates.UpdateNowAndPollAsync(initialJob, pin, onFinished: j => finishedJob = j, maxChecks: 10);
        Assert.True(completed);
        Assert.Equal("2026-11-28T10:05:00Z", finishedJob?.LastRunAt);
    }

    [Fact]
    public async Task TileUpdatesStartingSecondPollCancelsPriorPollForSamePin()
    {
        var pin = PagePin("/dash/rev.html", profile: "default", jobId: "j-1");
        var job = CronJob("j-1", owner: "default", lastRunAt: "2026-11-28T10:00:00Z");
        var firstEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var secondAllowed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var call = 0;

        var updates = new TileUpdates(
            readList: async (_, ct) =>
            {
                var n = Interlocked.Increment(ref call);
                if (n == 1)
                {
                    firstEntered.TrySetResult();
                    await Task.Delay(TimeSpan.FromSeconds(5), ct);
                }
                await secondAllowed.Task;
                return [job with { LastRunAt = "2026-11-28T10:10:00Z" }];
            },
            runNow: (_, _) => Task.CompletedTask)
        {
            PollInterval = TimeSpan.FromMilliseconds(1),
        };

        var firstFinished = false;
        var firstTask = updates.UpdateNowAndPollAsync(job, pin, onFinished: _ => firstFinished = true, maxChecks: 5);
        await firstEntered.Task;

        secondAllowed.SetResult();
        var secondFinished = false;
        var secondResult = await updates.UpdateNowAndPollAsync(job, pin, onFinished: _ => secondFinished = true, maxChecks: 5);
        var firstResult = await firstTask;

        Assert.False(firstResult);
        Assert.False(firstFinished);
        Assert.True(secondResult);
        Assert.True(secondFinished);
    }

    // ------------------------------------------------------------------ __hqApplyTheme & ExtractPagePath

    [Fact]
    public void ApplyThemeScriptAndThemeKeyAreDeterministicAndHandleReloadResult()
    {
        var light = TileWebTheme.DefaultPalette(dark: false);
        var dark = TileWebTheme.DefaultPalette(dark: true);
        var darkDesktop = TileWebTheme.DefaultPalette(dark: true, desktopLook: true, desktopRadius: 4);

        var kLight1 = TileWebTheme.ThemeKey(light);
        var kLight2 = TileWebTheme.ThemeKey(light);
        var kDark = TileWebTheme.ThemeKey(dark);
        var kDarkDesktop = TileWebTheme.ThemeKey(darkDesktop);

        Assert.Equal(kLight1, kLight2);
        Assert.StartsWith("l-", kLight1);
        Assert.StartsWith("d-", kDark);
        Assert.NotEqual(kLight1, kDark);
        Assert.NotEqual(kDark, kDarkDesktop);

        var applyScript = TileWebTheme.ApplyThemeScript(dark);
        Assert.Contains("window.__hqApplyTheme", applyScript);
        Assert.Contains("true,[28,28,30,1]", applyScript);
        Assert.EndsWith(":'reload'", applyScript);

        var prelude = TileWebTheme.PreludeScript(dark, talks: true, inTile: true);
        Assert.Contains("window.__hqApplyTheme=function(css,isDark,ground)", prelude);
        Assert.Contains("window.__hqLegible=", prelude);
        Assert.Contains("s.id='__hq-theme'", prelude);

        Assert.False(TileWebTheme.NeedsReloadAfterThemeApply("false"));
        Assert.True(TileWebTheme.NeedsReloadAfterThemeApply("true"));
        Assert.True(TileWebTheme.NeedsReloadAfterThemeApply("\"reload\""));
        Assert.True(TileWebTheme.NeedsReloadAfterThemeApply(null));

        // MEDIA: takes priority; bare absolute .html/.htm works as fallback.
        Assert.Equal("/home/hermes/dash/rev.html",
            TileWebTheme.ExtractPagePath("Created /tmp/draft.html\nMEDIA:/home/hermes/dash/rev.html"));
        Assert.Equal("~/dashboards/weather.htm",
            TileWebTheme.ExtractPagePath("Saved your updated tile at `~/dashboards/weather.htm`."));
        Assert.Null(TileWebTheme.ExtractPagePath("Could you clarify which account to read?"));
    }

    // ------------------------------------------------------------------ HermesUpdateKind.Cloud

    [Fact]
    public async Task CloudUpdateRunsFourStepFlowAndConfirmsVersion()
    {
        var version = "0.22.5";
        var started = false;
        var run = HermesUpdate.ForCloud(
            "cloud:agent-1",
            "Research Bot",
            readVersion: () => Task.FromResult<string?>(version),
            startUpdate: _ => started = true);
        run.VersionReadDelay = TimeSpan.FromMilliseconds(5);

        Assert.Equal(HermesUpdateKind.Cloud, run.Kind);
        run.Check();
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (run.Phase != HermesUpdate.PhaseKind.Asking && DateTime.UtcNow < deadline) await Task.Delay(5);

        Assert.Equal(HermesUpdate.PhaseKind.Asking, run.Phase);
        Assert.Equal("0.22.5", run.From);
        Assert.Equal("Update Research Bot", run.Headline);
        Assert.Equal(HermesUpdate.CloudAskingLine, run.Line);
        Assert.Equal(["Ask Nous", "Nous Reinstalls", "Hermes Answers", "Confirm Version"], run.CloudSteps.Select(s => s.Title));

        run.Confirm();
        Assert.True(started);
        Assert.Equal(HermesUpdate.PhaseKind.Working, run.Phase);
        Assert.Equal(HermesUpdateStepState.Active, run.CloudSteps[0].State);

        run.Cloud(new CloudUpdateSignal.Asked());
        Assert.Equal(HermesUpdateStepState.Done, run.CloudSteps[0].State);
        Assert.Equal(HermesUpdateStepState.Active, run.CloudSteps[1].State);

        run.Cloud(new CloudUpdateSignal.Settling("Restarting container…"));
        Assert.Equal("Restarting container…", run.CloudSteps[1].Detail);

        version = "0.23.0";
        run.Cloud(new CloudUpdateSignal.Ready());
        deadline = DateTime.UtcNow.AddSeconds(5);
        while (run.Phase != HermesUpdate.PhaseKind.Ended && DateTime.UtcNow < deadline) await Task.Delay(5);

        Assert.Equal(new HermesUpdateEnd.Updated("0.23.0"), run.End);
        Assert.Equal("Updated to 0.23.0", run.Headline);
        Assert.Equal("Research Bot answers on its new Hermes.", run.Line);
        Assert.All(run.CloudSteps, s => Assert.Equal(HermesUpdateStepState.Done, s.State));

        // CloudEnd edge cases & CloudUnchanged wording.
        Assert.Equal(new HermesUpdateEnd.Unchanged("0.22.5"), HermesUpdate.CloudEnd("v0.22.5", "0.22.5"));
        Assert.IsType<HermesUpdateEnd.Unconfirmed>(HermesUpdate.CloudEnd("0.22.5", null));
        Assert.IsType<HermesUpdateEnd.Unconfirmed>(HermesUpdate.CloudEnd(null, "0.23.0"));
        Assert.Equal("Nous restarted Research Bot on 0.22.5. Nous hasn’t released a newer Hermes yet.",
            HermesUpdate.CloudUnchanged("Research Bot", "v0.22.5"));
    }

    // ------------------------------------------------------------------ Live-tile busy & 1 s throttle guards

    [Fact]
    public void LiveTileGuardEnforcesBusyAndOneSecondThrottle()
    {
        var guard = new TileLiveGuard();
        var t0 = DateTimeOffset.Parse("2026-11-28T12:00:00Z");

        // Empty / oversized / busy rejections.
        Assert.Equal((TileLiveGuard.DecisionKind.Reject, "empty"), Result(guard.Evaluate("p1", "   ", false, t0)));
        Assert.Equal((TileLiveGuard.DecisionKind.Reject, "too_long"), Result(guard.Evaluate("p1", new string('a', TileWords.MaxIntentLength + 1), false, t0)));
        Assert.Equal((TileLiveGuard.DecisionKind.Reject, "busy"), Result(guard.Evaluate("p1", "Refresh", isWorking: true, t0)));

        // First prompt delivers immediately.
        Assert.Equal((TileLiveGuard.DecisionKind.Deliver, null), Result(guard.Evaluate("p1", "Refresh", false, t0)));

        // Second tap within 1 s waits out the remaining window; third tap while waiting is throttled.
        var wait = guard.Evaluate("p1", "Second", false, t0.AddMilliseconds(250));
        Assert.Equal(TileLiveGuard.DecisionKind.Wait, wait.Kind);
        Assert.Equal(TimeSpan.FromMilliseconds(750), wait.Delay);
        Assert.Equal((TileLiveGuard.DecisionKind.Reject, "throttled"), Result(guard.Evaluate("p1", "Third", false, t0.AddMilliseconds(300))));

        // If the tile became busy during the wait, CompleteWait rejects with busy.
        Assert.Equal((TileLiveGuard.DecisionKind.Reject, "busy"), Result(guard.CompleteWait("p1", isWorking: true, t0.AddSeconds(1))));

        // Once 1 s has elapsed and not busy, delivers cleanly.
        Assert.Equal((TileLiveGuard.DecisionKind.Deliver, null), Result(guard.Evaluate("p1", "Fourth", false, t0.AddSeconds(2))));

        static (TileLiveGuard.DecisionKind, string?) Result(TileLiveGuard.Decision d) => (d.Kind, d.Error);
    }
}
