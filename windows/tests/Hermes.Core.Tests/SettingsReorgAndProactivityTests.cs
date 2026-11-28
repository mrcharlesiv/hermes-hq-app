using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Capabilities;
using Hermes.Core.Net;
using Hermes.Core.Settings;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

/// Wave 2B unit tests: 7-category Settings reorganization (`e27566897`), Proactivity (Beta) (`b446e2abf`, `6bedd2ea3`),
/// Discord Community Invite (`dcf89ffb1`), and Settings › Models & Auxiliary Models (`517927687`).
public sealed class SettingsReorgAndProactivityTests
{
    private sealed class MemPrefs : IPreferences
    {
        private readonly Dictionary<string, string> _data = [];
        public string? Get(string key) => _data.GetValueOrDefault(key);
        public void Set(string key, string? value) { if (value == null) _data.Remove(key); else _data[key] = value; }
    }

    private sealed class StubHandler(Func<HttpRequestMessage, string?, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public List<(HttpMethod Method, string Path, string Query, string? Body)> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = request.Content == null ? null : await request.Content.ReadAsStringAsync(ct);
            Requests.Add((request.Method, request.RequestUri!.AbsolutePath, request.RequestUri.Query, body));
            return respond(request, body);
        }
    }

    private static HttpResponseMessage JsonResponse(HttpStatusCode status, string json) =>
        new(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };

    private static GatewaySession MakeSession(StubHandler handler)
    {
        var addr = GatewayAddress.Validated("http://127.0.0.1:9119");
        var account = new StoredAccount(addr.ToString(), "tester");
        return new GatewaySession(addr, account, new MemoryTokenStore(), handler);
    }

    // ---------------------------------------------------------------- 7-Category Layout (`e27566897`)

    [Fact]
    public void SevenMacCategoriesInExactOrderAndNames()
    {
        Assert.Equal(
            [
                SettingsCategory.General,
                SettingsCategory.Appearance,
                SettingsCategory.Chat,
                SettingsCategory.Gateway,
                SettingsCategory.Accounts,
                SettingsCategory.Tools,
                SettingsCategory.About,
            ],
            SettingsCategories.All);
        Assert.Equal(
            ["General", "Appearance", "Chat", "Hermes", "Accounts & Keys", "Bots & Tools", "About"],
            SettingsCategories.All.Select(c => c.Title()));
        Assert.Equal(SettingsCategory.Accounts, SettingsCategories.Parse("accounts"));
        Assert.Equal(SettingsCategory.Tools, SettingsCategories.Parse("tools"));
        // Legacy persisted "sounds" folds cleanly into General.
        Assert.Equal(SettingsCategory.General, SettingsCategories.Parse("sounds"));
        Assert.Null(SettingsCategories.Parse("nonexistent"));
    }

    // ---------------------------------------------------------------- SettingsSearch Routing

    [Theory]
    [InlineData("row:window-transparency", SettingsCategory.Appearance)]
    [InlineData("row:hermes-corners", SettingsCategory.Appearance)]
    [InlineData("row:reply-bubbles", SettingsCategory.Appearance)]
    [InlineData("row:bot-chats-style", SettingsCategory.Appearance)]
    [InlineData("row:desktop-look", SettingsCategory.Appearance)]
    [InlineData("row:session-strip", SettingsCategory.Chat)]
    [InlineData("row:send-while-busy", SettingsCategory.Chat)]
    [InlineData("row:new-chat-asks-project", SettingsCategory.Chat)]
    [InlineData("action:clear-models", SettingsCategory.Chat)]
    [InlineData("proactivity-beta", SettingsCategory.General)]
    [InlineData("row:completion-sound", SettingsCategory.General)]
    [InlineData("row:sound", SettingsCategory.General)]
    [InlineData("row:resume-last-chat", SettingsCategory.General)]
    [InlineData("row:tips", SettingsCategory.General)]
    [InlineData("models", SettingsCategory.Gateway)]
    [InlineData("auxiliary-models", SettingsCategory.Gateway)]
    [InlineData("fallback-models", SettingsCategory.Gateway)]
    [InlineData("action:export", SettingsCategory.Gateway)]
    [InlineData("action:import", SettingsCategory.Gateway)]
    [InlineData("action:reset", SettingsCategory.Gateway)]
    [InlineData("vault", SettingsCategory.Accounts)]
    [InlineData("providers", SettingsCategory.Accounts)]
    [InlineData("keys", SettingsCategory.Accounts)]
    [InlineData("billing", SettingsCategory.Accounts)]
    [InlineData("capabilities", SettingsCategory.Tools)]
    [InlineData("more:profiles", SettingsCategory.Tools)]
    [InlineData("more:messaging", SettingsCategory.Tools)]
    [InlineData("more:webhooks", SettingsCategory.Tools)]
    [InlineData("more:import-sessions", SettingsCategory.Tools)]
    [InlineData("about", SettingsCategory.About)]
    [InlineData("diagnostics", SettingsCategory.About)]
    [InlineData("licenses", SettingsCategory.About)]
    [InlineData("about:detailed-log", SettingsCategory.About)]
    [InlineData("discord", SettingsCategory.About)]
    public void SearchCategoryRoutesTargetsToSevenMacCategories(string target, SettingsCategory expected)
    {
        Assert.Equal(expected, SettingsSearch.Category(target));
    }

    [Fact]
    public void SearchIndexContainsNewEntriesUniqueIdsAndDesktopLookAlias()
    {
        var index = SettingsSearch.Index;
        Assert.Equal(index.Count, index.Select(e => e.Id).Distinct().Count());
        foreach (var e in index)
            Assert.True(SettingsSearch.Category(e.Target) != null, $"Unmapped target for {e.Id}: {e.Target}");

        // "desktop look" remains a search keyword alias for "Hermes Look".
        var desktopHits = SettingsSearch.Results("desktop look", index);
        Assert.Contains(desktopHits, h => h.Target == "row:desktop-look" && h.Label == SettingsWords.HermesLookTitle);

        Assert.Contains(SettingsSearch.Results("window transparency", index), h => h.Target == "row:window-transparency");
        Assert.Contains(SettingsSearch.Results("frosted", index), h => h.Target == "row:window-transparency");
        Assert.Contains(SettingsSearch.Results("hermes corners", index), h => h.Target == "row:hermes-corners");
        Assert.Contains(SettingsSearch.Results("reply bubbles", index), h => h.Target == "row:reply-bubbles");
        Assert.Contains(SettingsSearch.Results("other chats", index), h => h.Target == "row:session-strip");
        Assert.Contains(SettingsSearch.Results("session strip", index), h => h.Target == "row:session-strip");
        Assert.Contains(SettingsSearch.Results("proactivity", index), h => h.Target == "proactivity-beta" && h.Label == ProactivityBeta.PageLabel);
        Assert.Contains(SettingsSearch.Results("open loops", index), h => h.Target == "proactivity-beta");
        Assert.Contains(SettingsSearch.Results("auxiliary models", index), h => h.Target == "auxiliary-models");
        Assert.Contains(SettingsSearch.Results("fallback models", index), h => h.Target == "models");
        Assert.Contains(SettingsSearch.Results("discord", index), h => h.Target == "discord");
        Assert.Contains(SettingsSearch.Results("webhooks", index), h => h.Target == "more:webhooks");
        Assert.Contains(SettingsSearch.Results("passwords", index), h => h.Target == "vault");
    }

    // ---------------------------------------------------------------- Proactivity (Beta) (`b446e2abf`, `6bedd2ea3`)

    [Fact]
    public void ProactivityStatusParsesOffByDefaultAndActivePayloads()
    {
        Assert.Equal("hermes-hq-proactive", ProactivityBeta.PluginName);
        Assert.Equal("mrcharlesiv/hermes-hq-plugins/hermes-hq-proactive", ProactivityBeta.PluginSource);
        Assert.Equal("/api/plugins/hermes-hq-proactive", ProactivityBeta.Route);

        const string offJson = """
        {
          "plugin": "hermes-hq-proactive",
          "version": "0.1.0-beta.1",
          "beta": true,
          "enabled": false,
          "autonomy_mode": "prep",
          "quiet_hours_active": false,
          "budgets": {"offers_used_24h": 0, "offers_limit_24h": 6, "interrupts_used_24h": 0, "interrupts_limit_24h": 2},
          "counts": {"pending_offers": 0, "open_loops": 0, "snoozed_loops": 0, "active_watches": 0},
          "settings": {
            "enabled": false,
            "autonomy_mode": "prep",
            "quiet_start": "22:00",
            "quiet_end": "08:00",
            "in_turn_enabled": true,
            "loop_radar_enabled": true,
            "idle_sweep_enabled": true,
            "daily_brief_enabled": true,
            "pattern_detection_enabled": true,
            "allow_llm_in_sweep": true
          }
        }
        """;
        var off = ProactivityStatus.Parse(offJson);
        Assert.True(off.Beta);
        Assert.False(off.Enabled);
        Assert.Equal(AutonomyMode.Prep, off.AutonomyMode);
        Assert.Equal(6, off.OffersLimit24h);
        Assert.Equal("22:00", off.QuietStart);
        Assert.Equal("08:00", off.QuietEnd);

        const string activeJson = """
        {
          "version": "0.2.0-beta.1",
          "beta": true,
          "enabled": true,
          "autonomy_mode": "full",
          "quiet_hours_active": true,
          "budgets": {"offers_used_24h": 3, "offers_limit_24h": 8, "interrupts_used_24h": 1, "interrupts_limit_24h": 2},
          "counts": {"pending_offers": 2, "open_loops": 5, "snoozed_loops": 1, "active_watches": 3},
          "settings": {"in_turn_enabled": true, "loop_radar_enabled": false, "idle_sweep_enabled": true}
        }
        """;
        var active = ProactivityStatus.Parse(activeJson);
        Assert.True(active.Enabled);
        Assert.Equal(AutonomyMode.Full, active.AutonomyMode);
        Assert.True(active.QuietHoursActive);
        Assert.Equal(3, active.OffersUsed24h);
        Assert.Equal(2, active.PendingOffers);
        Assert.Equal(5, active.OpenLoops);
        Assert.Equal(1, active.SnoozedLoops);
        Assert.False(active.LoopRadarEnabled);
        Assert.True(active.InTurnEnabled);
        Assert.Equal("Prep + Urgent", AutonomyMode.Full.Title());
        Assert.Equal("observe", AutonomyMode.Observe.Raw());
    }

    [Fact]
    public async Task ProactivityApiHandlesStatusUpdateSweepAnd404NotFound()
    {
        var handler = new StubHandler((req, _) =>
        {
            var path = req.RequestUri!.AbsolutePath;
            if (req.Method == HttpMethod.Get && path == "/api/plugins/hermes-hq-proactive/status")
            {
                if (req.RequestUri.Query.Contains("profile=missing"))
                    return JsonResponse(HttpStatusCode.NotFound, """{"detail":"Plugin not found"}""");
                return JsonResponse(HttpStatusCode.OK, """{"version":"0.1.0-beta.1","enabled":true,"autonomy_mode":"prep","counts":{"open_loops":2}}""");
            }
            if (req.Method == HttpMethod.Patch && path == "/api/plugins/hermes-hq-proactive/settings")
            {
                return JsonResponse(HttpStatusCode.OK, """{"status":{"version":"0.1.0-beta.1","enabled":true,"autonomy_mode":"observe"}}""");
            }
            if (req.Method == HttpMethod.Post && path == "/api/plugins/hermes-hq-proactive/sweep")
            {
                return JsonResponse(HttpStatusCode.OK, """{"quiet":false,"signals_detected":4,"created_offers":1,"tokens_used":120}""");
            }
            return JsonResponse(HttpStatusCode.InternalServerError, """{"detail":"unexpected"}""");
        });

        using var session = MakeSession(handler);
        var api = new ProactivityBetaApi(session);

        // Default profile omits ?profile=; named profile includes ?profile=otto.
        Assert.Empty(ProactivityBetaApi.ProfileQuery("default"));
        Assert.Equal([new KeyValuePair<string, string>("profile", "otto")], ProactivityBetaApi.ProfileQuery("otto"));

        var st = await api.StatusAsync("default");
        Assert.True(st.Enabled);
        Assert.Equal(2, st.OpenLoops);
        Assert.DoesNotContain("profile=", handler.Requests[^1].Query);

        var updated = await api.UpdateSettingsAsync(new JsonObject { ["autonomy_mode"] = "observe" }, "otto");
        Assert.Equal(AutonomyMode.Observe, updated.AutonomyMode);
        Assert.Contains("profile=otto", handler.Requests[^1].Query);

        var sweep = await api.SweepAsync(forceBrief: true, "otto");
        Assert.False(sweep.Quiet);
        Assert.Equal(4, sweep.SignalsDetected);
        Assert.Equal(1, sweep.CreatedOffers);
        Assert.Equal("Checked 4 signal(s), staged 1 offer(s).", ProactivityBetaApi.SweepSummary(sweep));
        Assert.Equal("Signal check quiet — nothing crossed threshold (0 tokens).",
            ProactivityBetaApi.SweepSummary(new SweepOutcome(true, 0, 0, 0)));

        // 404 Plugin not found is classified cleanly as route missing -> NeedsRestart vs NotInstalled.
        var ex = await Assert.ThrowsAsync<GatewayException>(() => api.StatusAsync("missing"));
        Assert.True(ProactivityBetaApi.IsRouteMissing(ex));
        Assert.Equal("Plugin not found", ProactivityBetaApi.ErrorWords(ex));
        Assert.False(ProactivityBetaApi.IsRouteMissing(new GatewayException("http", "500", 500, "boom")));
        Assert.Equal("Hermes answered HTTP 503.", ProactivityBetaApi.ErrorWords(new GatewayException("http", "503", 503, "")));

        var plugin = new PluginInfo(ProactivityBeta.PluginName, ProactivityBeta.PluginName, "0.1.0", "", "git", true, false, [], false, null, null, []);
        Assert.Equal(ProactivityMissingState.NeedsRestart, ProactivityBetaApi.ClassifyMissingRoute([plugin]));
        Assert.Equal(ProactivityMissingState.NotInstalled, ProactivityBetaApi.ClassifyMissingRoute([]));
    }

    // ---------------------------------------------------------------- Discord Community Invite (`dcf89ffb1`)

    [Fact]
    public void CommunityInviteConstantsAndDismissPersistence()
    {
        Assert.Equal("https://discord.gg/KP9cDXD6ET", CommunityInvite.DiscordUrl);
        Assert.Equal("#5865F2", CommunityInvite.BlurpleHex);
        Assert.Equal(0x5865F2u, CommunityInvite.BlurpleRgb);
        Assert.Equal("https://gethermeshq.com", CommunityInvite.WebsiteUrl);
        Assert.Equal("https://github.com/mrcharlesiv/hermes-hq-app", CommunityInvite.GitHubUrl);
        Assert.Equal("hqn.more.discordInvite.closed", CommunityInvite.DismissedKey);
        Assert.Equal("Join the Hermes HQ Discord", CommunityInvite.BannerTitle);
        Assert.Equal("Join the Discord", CommunityInvite.BannerJoinLabel);

        var prefs = new MemPrefs();
        Assert.False(CommunityInvite.IsDismissed(prefs));
        CommunityInvite.Dismiss(prefs);
        Assert.True(CommunityInvite.IsDismissed(prefs));
        Assert.Equal("true", prefs.Get(CommunityInvite.DismissedKey));
        CommunityInvite.Reset(prefs);
        Assert.False(CommunityInvite.IsDismissed(prefs));
    }

    // ---------------------------------------------------------------- Settings › Models & Auxiliary Models (`517927687`)

    [Fact]
    public void FallbackAndAuxiliaryModelsParseAndFormatCleanly()
    {
        var parsedFallbacks = FallbackModel.ParseList(JsonNode.Parse("""[{"provider":"anthropic","model":"claude-sonnet-4-5"},"openai:gpt-5"]"""));
        Assert.Equal(2, parsedFallbacks.Count);
        Assert.Equal(new FallbackModel("anthropic", "claude-sonnet-4-5"), parsedFallbacks[0]);
        Assert.Equal(new FallbackModel("openai", "gpt-5"), parsedFallbacks[1]);

        var roundTrip = FallbackModel.ParseList(FallbackModel.ToJson(parsedFallbacks));
        Assert.Equal(parsedFallbacks, roundTrip);

        Assert.Equal("Compression", AuxiliaryAssignment.Label("compression"));
        Assert.Equal("Connectors", AuxiliaryAssignment.Label("mcp"));
        Assert.Equal("Chat Titles", AuxiliaryAssignment.Label("title_generation"));
        Assert.Equal("Custom Helper", AuxiliaryAssignment.Label("custom_helper"));

        var mainFollow = new AuxiliaryAssignment("vision", "auto", "");
        Assert.True(mainFollow.FollowsMain);
        var customAux = new AuxiliaryAssignment("review", "openai", "gpt-5-mini");
        Assert.False(customAux.FollowsMain);
        Assert.Equal($"{Hermes.Core.Composer.ModelNames.DisplayModelName("gpt-5-mini")} · {Hermes.Core.Composer.ModelNames.PlainProviderName("openai")}",
            ModelSettingsWords.Describe("openai", "gpt-5-mini"));
        Assert.Equal("None", ModelSettingsWords.Describe("openai", ""));
    }

    [Fact]
    public async Task ModelSettingsApiCoversSetModelConfirmAuxiliaryAndMoa()
    {
        var handler = new StubHandler((req, body) =>
        {
            var path = req.RequestUri!.AbsolutePath;
            if (req.Method == HttpMethod.Get && path == "/api/model/info")
                return JsonResponse(HttpStatusCode.OK, """{"provider":"anthropic","model":"claude-opus-4-5"}""");
            if (req.Method == HttpMethod.Get && path == "/api/model/options")
                return JsonResponse(HttpStatusCode.OK, """{"providers":[{"slug":"anthropic","name":"Anthropic","models":["claude-opus-4-5"],"authenticated":true}]}""");
            if (req.Method == HttpMethod.Get && path == "/api/model/auxiliary")
                return JsonResponse(HttpStatusCode.OK, """{"tasks":[{"task":"compression","provider":"openai-codex","model":"gpt-6.1-terra"}]}""");
            if (req.Method == HttpMethod.Post && path == "/api/model/set")
            {
                var parsed = J.Parse(body ?? "");
                if (parsed.Str("model") == "expensive-model" && parsed.Bool("confirm_expensive_model") != true)
                    return JsonResponse(HttpStatusCode.OK, """{"confirm_required":true,"confirm_message":"Costs $50/Mtok."}""");
                return JsonResponse(HttpStatusCode.OK, """{"ok":true}""");
            }
            if (req.Method == HttpMethod.Get && path == "/api/model/moa")
                return JsonResponse(HttpStatusCode.OK, """{"default_preset":"balanced","presets":{"balanced":{"aggregator":{"provider":"anthropic","model":"claude-opus-4-5"},"reference_models":[{"provider":"openai","model":"gpt-5"}],"fanout":"every_n:3"}}}""");
            if (req.Method == HttpMethod.Put && path == "/api/model/moa")
                return JsonResponse(HttpStatusCode.OK, """{"ok":true,"default_preset":"balanced","presets":{"balanced":{"aggregator":{"provider":"anthropic","model":"claude-opus-4-5"},"reference_models":[{"provider":"openai","model":"gpt-5"}]}}}""");
            return JsonResponse(HttpStatusCode.NotFound, """{"detail":"Not Found"}""");
        });

        using var session = MakeSession(handler);
        var api = new ModelSettingsApi(session);

        var info = await api.GetModelInfoAsync();
        Assert.Equal("anthropic", info.Provider);
        Assert.Equal("claude-opus-4-5", info.Model);

        var options = await api.GetModelOptionsAsync();
        var anth = Assert.Single(options);
        Assert.True(anth.IsReady);
        Assert.Contains("explicit_only=1", handler.Requests[^1].Query);

        var aux = await api.GetAuxiliaryModelsAsync();
        var comp = Assert.Single(aux);
        Assert.Equal("compression", comp.Task);
        Assert.Equal("openai-codex", comp.Provider);

        // Expensive model asks for confirmation before saving.
        var confirmEx = await Assert.ThrowsAsync<ModelConfirmRequiredException>(() =>
            api.SetModelAsync("main", "anthropic", "expensive-model"));
        Assert.Equal("Costs $50/Mtok.", confirmEx.Message);
        await api.SetModelAsync("main", "anthropic", "expensive-model", confirmExpensive: true);
        Assert.Contains("\"confirm_expensive_model\":true", handler.Requests[^1].Body);

        // Auxiliary scope sends task field.
        await api.SetModelAsync("auxiliary", "openai", "gpt-5-mini", task: "compression");
        Assert.Contains("\"scope\":\"auxiliary\"", handler.Requests[^1].Body);
        Assert.Contains("\"task\":\"compression\"", handler.Requests[^1].Body);

        // MoA GET/PUT and helpers.
        var moa = await api.GetMoaAsync();
        Assert.True(MixtureRecord.Complete(moa));
        Assert.Equal(["balanced"], MixtureRecord.PresetNames(moa));
        Assert.Equal("balanced", MixtureRecord.DefaultPreset(moa));
        Assert.Contains("every 3 steps", MixtureRecord.AdviceLine(MixtureRecord.Presets(moa).Get("balanced")));
        var saved = await api.SetMoaAsync(MixtureRecord.Mirrored(moa));
        Assert.Equal("balanced", saved.Str("default_preset"));
    }
}
