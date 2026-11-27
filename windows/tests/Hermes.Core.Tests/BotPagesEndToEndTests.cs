using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.BotPages;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// Bot Profiles, Messaging, Webhooks, Import Sessions and Restart Gateway against the More pages stand-in
/// (windows/ci/fixtures/morepages-gateway.py, scripts/fixtures/morepages/*.py). Run through windows/scripts/e2e.sh
/// (HQW_E2E_BOTPAGES_CREDENTIALS); without it these pass vacuously. Every wait is a condition with a deadline.
[Trait("Category", "E2E")]
public class BotPagesEndToEndTests
{
    private static async Task Until(Func<Task<bool>> condition, int seconds = 30)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!await condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(100);
        }
    }

    private static async Task<JsonNode> Post(string url, string path, object body)
    {
        using var http = new HttpClient();
        var content = new StringContent(System.Text.Json.JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json");
        var r = await http.PostAsync(url.TrimEnd('/') + path, content);
        r.EnsureSuccessStatusCode();
        return JsonNode.Parse(await r.Content.ReadAsStringAsync())!;
    }

    private static async Task<JsonNode> State(string url)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + "/__fixture/state"))!;
    }

    /// The fixture's sign-in, a client, and the pages' gateway. Null when e2e.sh didn't start the stand-in.
    private static async Task<(HermesClient Client, ClientPagesGateway Gateway, string Url)?> Connect()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_BOTPAGES_CREDENTIALS");
        if (path == null || !File.Exists(path)) return null;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        await Post(url, "/__fixture/reset", new { });
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(30)).Token);
        return (client, new ClientPagesGateway(client), url);
    }

    [Fact]
    public async Task ProfilesListSoulRenameDelete()
    {
        if (await Connect() is not var (client, gw, url)) return;
        await using var _ = client;
        var api = new ProfilesApi(gw);
        var rows = await api.ListAsync();
        Assert.Equal(["default", "inbox", "deploys", "research", "finance"], rows.Select(r => r.Name));
        Assert.True(rows[0].IsDefault);
        Assert.Equal(("hermes-4", "nous", 12), (rows[0].Model, rows[0].Provider, rows[0].SkillCount));
        Assert.Equal("Inbox", rows[1].DisplayName);

        // Finance has no SOUL.md yet; Inbox has one, saved and read back.
        Assert.Equal(new SoulDocument("", false), await api.SoulAsync("finance"));
        var inbox = await api.SoulAsync("inbox");
        Assert.True(inbox.Exists);
        await api.SaveSoulAsync("inbox", inbox.Content + "\nAlways answer in one line.");
        var saved = (await State(url))["profiles"]!["souls"]!["inbox"]!;
        Assert.EndsWith("Always answer in one line.", saved.Str("content"));
        Assert.Equal(2, saved.Int("revision"));

        // Another device edits it: the editor's Save sees the change before writing.
        var baseHash = SoulDraft.Hash(inbox.Content + "\nAlways answer in one line.");
        await Post(url, "/__fixture/soul-edit", new { profile = "inbox", content = "Theirs." });
        Assert.True(SoulRules.ChangedOnGateway(baseHash, true, await api.SoulAsync("inbox")));

        // Rename: a taken name is refused in the gateway's own words; a free one moves the bot.
        var taken = await Assert.ThrowsAsync<GatewayException>(() => api.RenameAsync("research", "deploys"));
        Assert.Equal("Profile 'deploys' already exists.", ProfileName.RenameReason(taken));
        var renamed = await api.RenameAsync("research", "research-2");
        Assert.Equal("research-2", renamed.Name);
        Assert.EndsWith("/profiles/research-2", renamed.Path);
        Assert.Contains("research-2", (await client.BotsAsync()).Select(b => b.Name));
        Assert.Equal(404, PagesRest.Status(await Assert.ThrowsAsync<GatewayException>(() => api.SoulAsync("research"))));

        // Delete: never the default; a deleted bot leaves the list and the roster.
        Assert.Equal("The default profile cannot be deleted.", (await Assert.ThrowsAsync<BotWriteException>(() => api.DeleteAsync("default", "Hermes"))).Message);
        await api.DeleteAsync("finance", "Finance");
        Assert.DoesNotContain("finance", (await api.ListAsync()).Select(r => r.Name));
        Assert.DoesNotContain("finance", (await client.BotsAsync()).Select(b => b.Name));
        await api.DeleteAsync("finance", "Finance");   // already gone: not a failure
        await Post(url, "/__fixture/reset", new { });
    }

    [Fact]
    public async Task MessagingPlatformsKeysPeopleTestAndTelegram()
    {
        if (await Connect() is not var (client, gw, url)) return;
        await using var _ = client;
        var api = new MessagingApi(gw);
        var platforms = await api.PlatformsAsync("default");
        Assert.Equal(["chirp", "telegram", "pigeon", "semaphore"], platforms.Select(p => p.Id));
        var sorted = MessagingPlatform.Sorted(platforms, "");
        Assert.Equal(MessagingStatus.Tone.Bad, sorted[0].Status.Kind);   // the app with a problem leads
        Assert.Equal("Connected", platforms[0].Status.Text);
        Assert.Equal("Needs setup", platforms[1].Status.Text);
        Assert.Equal("Off", platforms[2].Status.Text);
        Assert.NotNull(MessagingIssues.RowWords(platforms));

        // A key: the value goes in the PUT body only; the next read says "Set".
        Assert.False(await api.UpdateAsync("telegram", MessagingBodies.Env("TELEGRAM_ALLOWED_USERS", "42"), "inbox"));
        var telegram = (await api.PlatformsAsync("inbox")).Single(p => p.Id == "telegram");
        Assert.True(telegram.Vars.Single(v => v.Key == "TELEGRAM_ALLOWED_USERS").IsSet);
        Assert.False((await api.PlatformsAsync("default")).Single(p => p.Id == "telegram").Vars.Single(v => v.Key == "TELEGRAM_ALLOWED_USERS").IsSet);
        await api.UpdateAsync("telegram", MessagingBodies.Clear("TELEGRAM_ALLOWED_USERS"), "inbox");
        Assert.False((await api.PlatformsAsync("inbox")).Single(p => p.Id == "telegram").Vars.Single(v => v.Key == "TELEGRAM_ALLOWED_USERS").IsSet);
        await api.UpdateAsync("pigeon", MessagingBodies.Enabled(true), null);
        Assert.True((await api.PlatformsAsync(null)).Single(p => p.Id == "pigeon").Enabled);

        // Who can message this bot: approve the one waiting, then remove them.
        var pairing = await api.PairingAsync(null);
        Assert.Equal(["Ada Byron", "Grace Hopper"], pairing.PendingFor("chirp").Select(p => p.Name));
        Assert.Equal("12 min ago", pairing.PendingFor("chirp")[0].Age);
        var ada = pairing.PendingFor("chirp")[0];
        Assert.Equal("Alan Turing", pairing.ApprovedFor("chirp").Single().Name);
        await api.ApproveAsync("chirp", ada.RequestId!, null);
        pairing = await api.PairingAsync(null);
        Assert.DoesNotContain(pairing.PendingFor("chirp"), p => p.UserId == "2001");
        Assert.Contains(pairing.ApprovedFor("chirp"), p => p.UserId == "2001");
        await api.RevokeAsync("chirp", "2001", null);
        Assert.DoesNotContain((await api.PairingAsync(null)).ApprovedFor("chirp"), p => p.UserId == "2001");

        // Test Connection answers in words either way.
        var test = await api.TestAsync("chirp", null);
        Assert.True(test.Ok);
        Assert.False(string.IsNullOrWhiteSpace(test.Message));

        // Set Up with Telegram: start, waiting, ready (the fixture says so), Finish.
        var setup = new TelegramSetup(new TelegramSetup.Calls(
            ct => api.TelegramStartAsync(null, "inbox", ct),
            (id, ct) => api.TelegramStatusAsync(id, "inbox", ct),
            (id, allowed, ct) => api.TelegramApplyAsync(id, allowed, "inbox", ct),
            id => api.TelegramCancelAsync(id, "inbox"))) { Interval = TimeSpan.FromMilliseconds(200) };
        TelegramSetupApplied? applied = null;
        setup.AppliedEvent += a => applied = a;
        setup.Start();
        await Until(() => Task.FromResult(setup.Current is TelegramSetup.Phase.Waiting));
        var start = ((TelegramSetup.Phase.Waiting)setup.Current).Start;
        Assert.NotNull(QrCode.Encode(start.QrPayload));
        Assert.NotNull(setup.Remaining(DateTimeOffset.UtcNow));
        await Post(url, "/__fixture/telegram", new { status = "ready", bot_username = "demo_bot", owner_user_id = "42" });
        await Until(() => Task.FromResult(setup.Current is TelegramSetup.Phase.Ready));
        Assert.Equal(new TelegramSetup.Phase.Ready("demo_bot", "42"), setup.Current);
        setup.Finish(["42"]);
        await Until(() => Task.FromResult(applied != null));
        Assert.Equal("Connected to @demo_bot", MessagingWords.Connected(applied!.BotUsername));
        var record = ((await State(url))["messaging"]!["telegram"]!["applied"] as JsonArray)!.Single()!;
        Assert.Equal(("inbox", "inbox"), (record.Str("profile"), record.Str("query_profile")));
        Assert.Equal("""["42"]""", record["allowed_user_ids"]!.ToJsonString());
        Assert.Equal("""["allowed_user_ids","profile"]""", record["keys"]!.ToJsonString());
        Assert.True(applied.NeedsRestart);

        // Closing a second flow before Finish gives its pairing back.
        var second = new TelegramSetup(new TelegramSetup.Calls(
            ct => api.TelegramStartAsync(null, null, ct), (id, ct) => api.TelegramStatusAsync(id, null, ct),
            (id, a, ct) => api.TelegramApplyAsync(id, a, null, ct), id => api.TelegramCancelAsync(id, null))) { Interval = TimeSpan.FromMilliseconds(200) };
        second.Start();
        await Until(() => Task.FromResult(second.Current is TelegramSetup.Phase.Waiting));
        second.Close();
        await (second.CancelTask ?? Task.CompletedTask);
        await Until(async () => ((await State(url))["messaging"]!["telegram"]!["cancelled"] as JsonArray)?.Count > 0);
        await Post(url, "/__fixture/reset", new { });
    }

    [Fact]
    public async Task WebhooksListCreateToggleDelete()
    {
        if (await Connect() is not var (client, gw, url)) return;
        await using var _ = client;
        var api = new WebhooksApi(gw);
        var list = await api.ListAsync();
        Assert.True(list.Enabled);
        Assert.Equal(["github-push", "invoice-paid", "status-page"], list.Subscriptions.Select(r => r.Name));
        Assert.Equal("push, pull_request → Telegram", list.Subscriptions[0].Summary);
        Assert.False(list.Subscriptions[2].Enabled);

        var created = await api.CreateAsync(new WebhookForm { Name = "Deploy Done", Events = "release", Deliver = "slack", DeliverChatId = "C1" });
        Assert.Equal("deploy-done", created.Name);
        Assert.False(string.IsNullOrEmpty(created.Secret));
        Assert.EndsWith("/webhooks/deploy-done", created.Url);
        var record = ((await State(url))["webhooks"]!["created"] as JsonArray)!.Last()!;
        Assert.Equal(created.Secret, record.Str("secret"));
        await Post(url, "/__fixture/webhooks", new { create = 409 });   // the gateway says the name is taken
        Assert.Equal(WebhookWords.NameTaken, WebhookWords.CreateFailure(await Assert.ThrowsAsync<GatewayException>(() =>
            api.CreateAsync(new WebhookForm { Name = "deploy-done" }))));

        await api.SetEnabledAsync("deploy-done", false);
        Assert.False((await api.ListAsync()).Subscriptions.Single(r => r.Name == "deploy-done").Enabled);
        await api.DeleteAsync("deploy-done");
        Assert.DoesNotContain("deploy-done", (await api.ListAsync()).Subscriptions.Select(r => r.Name));
        var enabled = await api.EnableAsync();
        Assert.False(enabled.RestartStarted);
        await Post(url, "/__fixture/reset", new { });
    }

    [Fact]
    public async Task ImportSessionsPagePreviewAndImport()
    {
        if (await Connect() is not var (client, gw, url)) return;
        await using var _ = client;
        var store = new ForeignSessionsStore(gw, "default");
        await store.Reload();
        Assert.IsType<ForeignSessionsStore.Phase.Loaded>(store.Current);
        Assert.Equal(ForeignSessionsApi.PageSize, store.Rows.Count);
        Assert.True(store.HasMore);
        Assert.False(string.IsNullOrEmpty(store.Host));
        await store.LoadMore();
        Assert.Equal(100, store.Rows.Count);
        Assert.Equal(store.Rows.Count, store.Rows.Select(r => r.Id).Distinct().Count());
        await store.SetSource(ForeignSessionsStore.SourceKind.Codex);
        Assert.All(store.Rows, r => Assert.Equal("codex", r.Source));

        var all = new ForeignSessionsStore(gw, "default");
        await all.Reload();
        var shortened = all.Rows.Single(r => r.Id == "fs-0003");
        var preview = await all.PreviewAsync(shortened);
        Assert.True(preview.Truncated);
        Assert.NotEmpty(preview.Messages);
        var already = await all.PreviewAsync(all.Rows.Single(r => r.Id == "fs-0002"));
        Assert.Equal("imported-fs-0002", already.AlreadyImported);

        var result = await all.ImportAsync(all.Rows.Single(r => r.Id == "fs-0004"));
        Assert.False(result.AlreadyImported);
        Assert.True((await all.ImportAsync(all.Rows.Single(r => r.Id == "fs-0004"))).AlreadyImported);
        var state = await State(url);
        Assert.Equal(1, state["foreign"]!.Int("imports"));
        // Hermes answers 4000 for any key it doesn't list: every call above sent only its own.
        Assert.DoesNotContain((state["rpc"] as JsonArray)!, c => c.Str("method")!.StartsWith("session.foreign") && c!["params"]!.AsObject().ContainsKey("profile"));
        await Post(url, "/__fixture/reset", new { });
    }

    [Fact]
    public async Task RestartGatewayRunsToItsEnd()
    {
        if (await Connect() is not var (client, gw, url)) return;
        await using var _ = client;
        var actions = new GatewayActionsApi(gw);
        var run = new GatewayActionRun(actions) { Interval = TimeSpan.FromMilliseconds(500) };
        await run.Start(ct => actions.RestartAsync(null, ct)).WaitAsync(TimeSpan.FromSeconds(60));
        Assert.Equal(new GatewayActionRun.Phase.Finished(true, "✓ Gateway restarted"), run.Current);

        await Post(url, "/__fixture/actions", new { restart = "fail" });
        var failed = new GatewayActionRun(actions) { Interval = TimeSpan.FromMilliseconds(500) };
        await failed.Start(ct => actions.RestartAsync(null, ct)).WaitAsync(TimeSpan.FromSeconds(60));
        Assert.Equal(new GatewayActionRun.Phase.Failed("Failed to restart gateway: launchctl answered 5"), failed.Current);
        await Post(url, "/__fixture/reset", new { });
    }
}
