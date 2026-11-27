using System.Text.Json.Nodes;
using Hermes.Core.BotPages;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// A gateway that answers from code and records what was asked.
internal sealed class FakePagesGateway : IPagesGateway
{
    public List<(string Method, string Path, List<KeyValuePair<string, string>> Query, JsonNode? Body)> Rest { get; } = [];
    public List<(string Method, JsonObject Params)> Calls { get; } = [];
    public Func<string, string, JsonNode?, string> OnRest { get; set; } = (_, _, _) => "{}";
    public Func<string, JsonObject, JsonNode> OnCall { get; set; } = (_, _) => new JsonObject();

    public Task<string> RestAsync(string method, string path, IEnumerable<KeyValuePair<string, string>>? query = null, JsonNode? body = null,
        TimeSpan? timeout = null, CancellationToken ct = default)
    {
        lock (Rest) Rest.Add((method, path, [.. query ?? []], body?.DeepClone()));
        return Task.FromResult(OnRest(method, path, body));
    }

    public Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default)
    {
        lock (Calls) Calls.Add((method, (JsonObject)parameters.DeepClone()));
        return Task.FromResult(OnCall(method, parameters));
    }

    public static GatewayException Http(int status, string body = "") => new("http", $"The gateway answered {status}.", status, body);
}

public class BotPagesWireTests
{
    [Fact]
    public void ReasonsAndScopes()
    {
        Assert.Equal(PagesRest.OlderHermes, PagesRest.Reason(FakePagesGateway.Http(404, """{"detail":"Not Found"}""")));
        Assert.Equal("Session not found", PagesRest.Reason(FakePagesGateway.Http(404, """{"detail":"Session not found"}""")));
        Assert.Equal("Nope", PagesRest.Reason(FakePagesGateway.Http(400, """{"detail":{"message":"Nope"}}""")));
        Assert.Equal(PagesRest.CouldNotDo, PagesRest.Reason(FakePagesGateway.Http(500, "<html>")));
        Assert.Equal(PagesRest.OlderHermes, PagesRest.Reason(new GatewayException("rpc", "x", rpcCode: -32601)));
        Assert.StartsWith("Can’t reach the computer running Hermes.", PagesRest.Reason(new GatewayException("offline", "x")));
        Assert.True(PagesRest.IsNotAvailable(new PagesMessageException(PagesRest.OlderHermes)));
        Assert.True(PagesRest.IsMissingRoute(FakePagesGateway.Http(405)));
        Assert.Equal("job%2F1", PagesRest.Segment("job/1"));
        Assert.Equal("a!b*(c)'", PagesRest.Segment("a!b*(c)'"));
        Assert.Empty(PagesRest.ProfileQuery("default"));
        Assert.Empty(PagesRest.ProfileQuery(null));
        Assert.Equal("inbox", PagesRest.ProfileQuery("inbox").Single().Value);
        Assert.False(PagesRest.ProfileParams("default").ContainsKey("profile"));
        Assert.Equal("This Hermes doesn’t have Messaging. Updating Hermes may add it.", PagesRest.NotAvailableBody("Messaging"));
        Assert.Equal("Star Map", PagesRest.PageName("Couldn’t Load Star Map"));
        Assert.Equal(PagesRest.OlderHermes, PagesRest.UnreadableAnswer(new JsonObject()).Message);
        Assert.Equal(PagesRest.Unreadable, PagesRest.UnreadableAnswer(new JsonObject { ["x"] = 1 }).Message);
        Assert.Equal("100000001", PagesRest.PgString(JsonValue.Create(100000001.0)));
        Assert.Equal(new DateTimeOffset(2026, 10, 1, 8, 30, 0, TimeSpan.Zero), PagesRest.ParseDate(JsonValue.Create("2026-10-01T08:30:00")));
    }

    [Fact]
    public void BotChoicesRememberedPerPageAndAccount()
    {
        var path = Path.Combine(Path.GetTempPath(), $"hqw-choice-{Guid.NewGuid():N}.json");
        var store = new BotChoiceStore(path);
        string[] bots = ["default", "inbox"];
        Assert.Equal("default", store.Read("messaging", "acct", bots));
        store.Save("messaging", "acct", "inbox");
        Assert.Equal("inbox", new BotChoiceStore(path).Read("messaging", "acct", bots));
        Assert.Equal("default", store.Read("messaging", "acct", ["default"]));   // a bot that left the roster
        Assert.Equal("default", store.Read("import-sessions", "acct", bots));
        File.Delete(path);
    }
}

public class ProfilesTests
{
    [Fact]
    public void RowsDefaultFirstRepeatsAndJunkSkipped()
    {
        var json = JsonNode.Parse("""
        {"profiles":[{"name":"inbox","model":"hermes-4","skill_count":"4","display_name":"Inbox"},{"name":"default","skill_count":12},
          {"name":"inbox"},null,7,"text",{},{"name":null},{"name":""},{"name":42,"skill_count":"many"},
          {"name":"numbers","skill_count":"7","is_default":"no","path":["x"]}]}
        """);
        var rows = ProfileRow.Rows(json);
        Assert.Equal(["default", "inbox", "numbers"], rows.Select(r => r.Name));
        Assert.True(rows[0].IsDefault);
        Assert.Equal(4, rows[1].SkillCount);
        Assert.Equal(7, rows[2].SkillCount);
        Assert.False(rows[2].IsDefault);
        Assert.Null(rows[2].Path);
    }

    [Fact]
    public void NamesAndWords()
    {
        Assert.True(ProfileName.IsValid("inbox-2_a"));
        Assert.False(ProfileName.IsValid("-inbox"));
        Assert.False(ProfileName.IsValid("Inbox"));
        Assert.False(ProfileName.IsValid("café"));
        Assert.False(ProfileName.IsValid(new string('a', 65)));
        Assert.Equal(ProfileName.Check.Unchanged, ProfileName.Of("inbox", "inbox", ["inbox", "deploys"]));
        Assert.Equal(ProfileName.Check.Taken, ProfileName.Of("deploys", "inbox", ["inbox", "deploys"]));
        Assert.Equal(ProfileName.Check.Invalid, ProfileName.Of("default", "inbox", []));
        Assert.Equal(ProfileName.Check.Invalid, ProfileName.Of("my bot", "inbox", []));
        Assert.Equal(ProfileName.Check.Ok, ProfileName.Of("triage", "inbox", ["inbox"]));
        Assert.Equal(ProfileName.Taken, ProfileName.RenameReason(FakePagesGateway.Http(409)));
        Assert.Equal("Profile 'x' already exists.", ProfileName.RenameReason(FakePagesGateway.Http(400, """{"detail":"Profile 'x' already exists."}""")));
        Assert.Equal("No skills", ProfileName.Skills(0));
        Assert.Equal("1 skill", ProfileName.Skills(1));
        Assert.Equal("Hermes 4 · 12 skills", ProfileName.Subtitle("Hermes 4", 12));
        Assert.Equal("4 skills", ProfileName.Subtitle(null, 4));
        Assert.Equal("Research Buddy", ProfileName.Readable("research-buddy"));
        Assert.Equal("Hermes", ProfileName.Readable("default"));
        Assert.Equal("5 profiles", ProfileName.Count(5));
        var rows = new[] { new ProfileRow("inbox", Model: "hermes-4"), new ProfileRow("deploys", Provider: "anthropic") };
        Assert.Equal(["deploys"], ProfileName.Filter(rows, "ANTHROPIC", r => r.Name).Select(r => r.Name));
        Assert.Equal(2, ProfileName.Filter(rows, "  ", r => r.Name).Count);
        Assert.Equal("Delete “Inbox”?", BotDelete.Title("Inbox"));
        Assert.Equal("Inbox’s memory, skills, settings and chats are deleted from the computer running Hermes. This can’t be undone.", BotDelete.Message("Inbox"));
        Assert.Equal("This bot is busy. Try again in a moment.", BotDelete.RestReason(409, ""));
    }

    [Fact]
    public void SoulDraftsKeptPerAccountAndProfile()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"hqw-soul-{Guid.NewGuid():N}");
        var store = new SoulDraftStore(dir);
        var draft = new SoulDraft("Line one\nLine two", SoulDraft.Hash("base"));
        Assert.Equal(draft, SoulDraftStore.Decode(SoulDraftStore.Encode(draft)));
        Assert.Null(SoulDraftStore.Decode("hq-soul-draft base=xyz\ntext"));
        Assert.Null(SoulDraftStore.Decode("nonsense"));
        Assert.Matches("^soul-draft-[0-9a-f]{16}-inbox\\.txt$", SoulDraftStore.FileName("https://gw", "inbox"));
        Assert.Matches("^soul-draft-[0-9a-f]{16}-[0-9a-f]{16}\\.txt$", SoulDraftStore.FileName("https://gw", "../x"));
        store.Write(draft, "acct", "inbox");
        store.Write(draft, "acct", "deploys");
        store.Write(draft, "other", "inbox");
        Assert.Equal(draft, store.Read("acct", "inbox"));
        store.Remove("acct", "inbox");
        Assert.Null(store.Read("acct", "inbox"));
        store.RemoveAll("acct");
        Assert.Null(store.Read("acct", "deploys"));
        Assert.Equal(draft, store.Read("other", "inbox"));
        Directory.Delete(dir, true);
    }

    [Fact]
    public void SoulRulesOfferChangedAndBar()
    {
        Assert.Equal(SoulRules.DraftOffer.None, SoulRules.OfferFor(null, "x"));
        Assert.Equal(SoulRules.DraftOffer.None, SoulRules.OfferFor(new SoulDraft("x", SoulDraft.Hash("")), "x"));
        Assert.Equal(SoulRules.DraftOffer.Offer, SoulRules.OfferFor(new SoulDraft("y", SoulDraft.Hash("")), "x"));
        Assert.False(SoulRules.ChangedOnGateway(SoulDraft.Hash("a"), false, new SoulDocument("", false)));
        Assert.False(SoulRules.ChangedOnGateway(SoulDraft.Hash("a"), true, new SoulDocument("a", true)));
        Assert.True(SoulRules.ChangedOnGateway(SoulDraft.Hash("a"), true, new SoulDocument("b", true)));
        Assert.True(SoulRules.ChangedOnGateway(SoulDraft.Hash(""), false, new SoulDocument("", true)));
        Assert.Equal(new SoulRules.Bar(true, false, "Save"), SoulRules.BarFor(false, false));
        Assert.Equal(new SoulRules.Bar(false, false, "Saving…"), SoulRules.BarFor(true, true));
        Assert.Equal(new SoulDocument("", false), SoulDocument.From(new JsonObject()));
        Assert.True(SoulDocument.From(new JsonObject { ["content"] = "x" }).Exists);
    }

    [Fact]
    public async Task ApiPathsAndBodies()
    {
        var gw = new FakePagesGateway
        {
            OnRest = (m, p, _) => (m, p) switch
            {
                ("GET", "/api/profiles") => """{"profiles":[{"name":"default"}]}""",
                ("GET", _) => """{"content":"Hi","exists":true}""",
                ("PATCH", _) => """{"ok":true,"name":"triage","path":"/h/profiles/triage"}""",
                ("DELETE", _) => throw FakePagesGateway.Http(404, """{"detail":"Profile 'x' does not exist."}"""),
                _ => """{"ok":true}""",
            },
        };
        var api = new ProfilesApi(gw);
        Assert.Single(await api.ListAsync());
        Assert.Equal(new SoulDocument("Hi", true), await api.SoulAsync("my bot"));
        Assert.Equal("/api/profiles/my%20bot/soul", gw.Rest[^1].Path);
        await api.SaveSoulAsync("inbox", "New text");
        Assert.Equal(("PUT", "/api/profiles/inbox/soul"), (gw.Rest[^1].Method, gw.Rest[^1].Path));
        Assert.Equal("""{"content":"New text"}""", gw.Rest[^1].Body!.ToJsonString());
        Assert.Equal(new ProfileRenamed("triage", "/h/profiles/triage"), await api.RenameAsync("inbox", "triage"));
        Assert.Equal("""{"new_name":"triage"}""", gw.Rest[^1].Body!.ToJsonString());
        await api.DeleteAsync("gone", "Gone");   // already gone: not a failure
        var refused = await Assert.ThrowsAsync<BotWriteException>(() => api.DeleteAsync("default", "Hermes"));
        Assert.Equal("Couldn’t Delete Hermes", refused.Title);
        gw.OnRest = (_, _, _) => """{"nope":1}""";
        Assert.Equal(PagesRest.Unreadable, (await Assert.ThrowsAsync<PagesMessageException>(() => api.ListAsync())).Message);
        gw.OnRest = (_, _, _) => "{}";
        Assert.Equal(PagesRest.OlderHermes, (await Assert.ThrowsAsync<PagesMessageException>(() => api.ListAsync())).Message);
    }
}

public class NewBotTests
{
    [Fact]
    public void Identity()
    {
        Assert.Equal("inbox-triage", BotIdentity.Slugify("Inbox Triage!"));
        Assert.Equal("cafe-bot", BotIdentity.SlugifyProfileName("Café Bot"));
        Assert.Equal("u65e5-u672c", BotIdentity.SlugifyProfileName("日本"));
        Assert.Equal(("u65e5-u672c", "日本"), BotIdentity.ProfileIdentity("日本", ""));
        Assert.Equal(("research", "Lab"), BotIdentity.ProfileIdentity(" Research ", " Lab "));
        Assert.Equal(("research", ""), BotIdentity.ProfileIdentity("research", ""));
        Assert.True(BotIdentity.SlugifyProfileName(new string('a', 70)).Length <= 64);
        Assert.True(BotIdentity.IsValidProfileId("a-b"));
        Assert.False(BotIdentity.IsValidProfileId(""));
        Assert.Equal("Lab — Reads papers", BotIdentity.DescriptionText("Lab", " Reads papers "));
        Assert.Equal("Research Buddy", BotIdentity.DisplayName("research_buddy", ""));
        Assert.Equal("Hermes", BotIdentity.DisplayName("default", ""));
        var soul = BotIdentity.ComposeSoul("research", "Lab", "Reads papers", serverInjectsProtocol: true);
        Assert.Equal("# Lab\n\n**Role:** Lab\n**Mission:** Reads papers\n\nYou are Lab, a persistent named agent (profile `research`) on this machine.\n"
            + "You keep your own memory, skills, and conversation history across sessions.", soul);
        var full = BotIdentity.ComposeSoul("research", "", "", serverInjectsProtocol: false, [("research", null), ("inbox", "Mail")]);
        Assert.Contains("## Messaging other agents", full);
        Assert.Contains("- `inbox` — Mail", full);
        Assert.DoesNotContain("- `research`", full);
        Assert.Contains("Message from \U0001F916 research (@research)", full);
    }

    [Fact]
    public async Task CreateSendsExactKeysAndInlineRefusal()
    {
        var gw = new FakePagesGateway
        {
            OnCall = (m, _) => m == "setup.runtime_check" ? new JsonObject { ["ok"] = false } : new JsonObject { ["ok"] = true },
        };
        var made = await new NewBotApi(gw).CreateAsync("Inbox Triage", "", "Sorts mail", []);
        Assert.Equal(new NewBotResult("inbox-triage", "Inbox Triage", true), made);
        var create = gw.Calls[0];
        Assert.Equal("profiles.create", create.Method);
        Assert.Equal(["name", "description", "clone_from", "no_skills", "share_auth", "soul"], create.Params.Select(p => p.Key));
        Assert.Equal("Sorts mail", create.Params["description"]!.GetValue<string>());
        Assert.Equal("""{"profile":"inbox-triage"}""", gw.Calls[1].Params.ToJsonString());

        gw.OnCall = (_, _) => throw new GatewayException("rpc", "A profile named that already exists.", rpcCode: 4062);
        var inline = await Assert.ThrowsAsync<NewBotInlineException>(() => new NewBotApi(gw).CreateAsync("inbox", "", "", []));
        Assert.Equal("A profile named that already exists.", inline.Message);
        var empty = await Assert.ThrowsAsync<BotWriteException>(() => new NewBotApi(gw).CreateAsync("!!!", "", "", []));
        Assert.Equal(NewBotWords.NoLetters, empty.Message);
    }
}

public class MessagingTests
{
    private static MessagingPlatform P(bool configured = true, bool enabled = true, bool running = true, string? state = "connected",
        string? error = null, string? updated = "x") =>
        new("chirp", "Chirp", Configured: configured, Enabled: enabled, GatewayRunning: running, State: state, ErrorMessage: error, UpdatedAt: updated);

    [Fact]
    public void StatusWords()
    {
        Assert.Equal(("Needs setup", MessagingStatus.Tone.Warn), (P(configured: false).Status.Text, P(configured: false).Status.Kind));
        Assert.Equal("Off", P(enabled: false).Status.Text);
        Assert.Equal(("Bot token was refused", MessagingStatus.Tone.Bad), (P(error: " Bot token was refused ").Status.Text, P(error: "Bot token was refused").Status.Kind));
        Assert.Equal("Not running", P(running: false).Status.Text);
        Assert.Equal("Startup failed", P(running: false, state: "startup_failed").Status.Text);
        Assert.Equal("Connected", P().Status.Text);
        Assert.Equal("Connecting…", P(state: "connecting").Status.Text);
        Assert.Equal("Status unknown", P(state: "pending_restart", updated: null).Status.Text);
        Assert.Equal("Restart needed", P(state: "pending_restart").Status.Text);
        Assert.Equal("Status unknown", P(state: null).Status.Text);
        Assert.Equal("Some New State", P(state: "some_new_state").Status.Text);
    }

    [Fact]
    public void PlatformsParsedSortedAndSearched()
    {
        var json = JsonNode.Parse("""
        {"platforms":[
          {"id":"pigeon","name":"Pigeon Post","configured":true,"enabled":false},
          {"id":"chirp","name":"Chirp","configured":true,"enabled":true,"gateway_running":true,"state":"connected",
           "env_vars":[{"key":"CHIRP_BOT_TOKEN","prompt":"Bot Token","is_password":true,"is_set":true,"redacted_value":"«redacted:ab12»","required":true},
                       {"key":"CHIRP_BOT_TOKEN"},{"key":"CHIRP_PROXY","advanced":true},{"key":" "}]},
          {"id":"semaphore","name":"Semaphore","configured":true,"enabled":true,"gateway_running":true,"error_message":"Flags down"},
          {"id":"telegram","name":"Telegram"},{"id":"chirp"},{"name":"no id"}]}
        """);
        var list = MessagingPlatform.List(json);
        Assert.Equal(4, list.Count);
        Assert.Equal(["semaphore", "telegram", "chirp", "pigeon"], MessagingPlatform.Sorted(list, "").Select(p => p.Id));
        Assert.Equal(["chirp"], MessagingPlatform.Sorted(list, "conn").Select(p => p.Id));
        var chirp = list.Single(p => p.Id == "chirp");
        Assert.Equal(2, chirp.Vars.Count);
        Assert.Single(chirp.Keys);
        Assert.Single(chirp.AdvancedKeys);
        Assert.Equal("Set · ab12", chirp.Keys[0].Value);
        Assert.Equal("Not Set", chirp.AdvancedKeys[0].Value);
        Assert.Equal("CHIRP_PROXY", chirp.AdvancedKeys[0].Label);
        Assert.Equal("Required", new MessagingEnvVar("K", Required: true).Value);
        Assert.Equal("Set", new MessagingEnvVar("K", IsSet: true, RedactedValue: "«redacted»").Value);
        Assert.Equal(("1 Issue", "Semaphore: Flags down"), MessagingIssues.RowWords(list));
        Assert.Null(MessagingIssues.RowWords([list.Single(p => p.Id == "pigeon")]));
    }

    [Fact]
    public void PairingAndBodies()
    {
        var pairing = MessagingPairing.From(JsonNode.Parse("""
        {"pending":[{"platform":"Chirp","user_id":42,"user_name":"Ana","request_id":"r1","age_minutes":125},
                    {"platform":"chirp","user_id":"43"},{"platform":"chirp","user_id":42,"request_id":"r1"}],
         "approved":[{"platform":"chirp","user_id":"7"}]}
        """));
        Assert.Single(pairing.Pending);
        Assert.Equal(("chirp:42", "Ana", "2 hr ago"), (pairing.Pending[0].Id, pairing.Pending[0].Name, pairing.Pending[0].Age));
        Assert.Equal("7", pairing.ApprovedFor("CHIRP")[0].Name);
        Assert.Equal("Just now", new PairingPerson("x", "1", AgeMinutes: 0.4).Age);
        Assert.Equal("3 days ago", new PairingPerson("x", "1", AgeMinutes: 3 * 1440 + 5).Age);
        Assert.Equal("""{"enabled":true}""", MessagingBodies.Enabled(true).ToJsonString());
        Assert.Equal("""{"env":{"K":"v"}}""", MessagingBodies.Env("K", "v").ToJsonString());
        Assert.Equal("""{"clear_env":["K"]}""", MessagingBodies.Clear("K").ToJsonString());
        Assert.Equal("""{"platform":"chirp","request_id":"r1","profile":"inbox"}""", MessagingBodies.Approve("chirp", "r1", "inbox").ToJsonString());
        Assert.Equal("""{"platform":"chirp","user_id":"7"}""", MessagingBodies.Revoke("chirp", "7", "default").ToJsonString());
        Assert.Equal("{}", MessagingBodies.TelegramStart(" ").ToJsonString());
        Assert.Equal("""{"allowed_user_ids":["42"]}""", MessagingBodies.TelegramApply(["42"], null).ToJsonString());
        Assert.Equal("Connected.", MessagingTestResult.From(new JsonObject { ["ok"] = true }).Message);
        Assert.Equal("The gateway gave no answer for this test.", MessagingTestResult.From(new JsonObject()).Message);
        Assert.Equal("Connected to @demo_bot", MessagingWords.Connected("@demo_bot"));
        Assert.Equal("Connected to Telegram", MessagingWords.Connected(null));
    }

    [Fact]
    public async Task TelegramFlowStartWaitReadyFinish()
    {
        var statuses = new Queue<TelegramSetupStatus>([new TelegramSetupStatus.Waiting(), new TelegramSetupStatus.Ready("demo_bot", "42")]);
        var cancelled = new List<string>();
        IReadOnlyList<string>? applied = null;
        var setup = new TelegramSetup(new TelegramSetup.Calls(
            _ => Task.FromResult(new TelegramSetupStart("p1", "tg://resolve?x", "https://t.me/x", ExpiresAt: DateTimeOffset.UtcNow.AddMinutes(10))),
            (_, _) => Task.FromResult(statuses.Count > 0 ? statuses.Dequeue() : new TelegramSetupStatus.Waiting()),
            (_, ids, _) => { applied = ids; return Task.FromResult(new TelegramSetupApplied("demo_bot", NeedsRestart: true)); },
            id => { lock (cancelled) cancelled.Add(id); return Task.CompletedTask; })) { Interval = TimeSpan.FromMilliseconds(20) };
        TelegramSetupApplied? done = null;
        setup.AppliedEvent += a => done = a;
        setup.Start();
        await Until(() => setup.Current is TelegramSetup.Phase.Ready);
        Assert.Equal(new TelegramSetup.Phase.Ready("demo_bot", "42"), setup.Current);
        Assert.NotNull(setup.Remaining(DateTimeOffset.UtcNow));
        setup.Finish([]);
        Assert.Equal("Add at least one Telegram user ID.", setup.Notice);
        setup.Finish(["42"]);
        await Until(() => done != null);
        Assert.Equal(["42"], applied);
        setup.Close();   // after Finish there is nothing to give back
        await Task.Delay(50);
        Assert.Empty(cancelled);

        // Closing while waiting gives the pairing back; a 410 while waiting is an expired link.
        var waiting = new TelegramSetup(new TelegramSetup.Calls(
            _ => Task.FromResult(new TelegramSetupStart("p2", "https://t.me/y", "")),
            (_, _) => Task.FromResult<TelegramSetupStatus>(new TelegramSetupStatus.Waiting()),
            (_, _, _) => throw new InvalidOperationException(),
            id => { lock (cancelled) cancelled.Add(id); return Task.CompletedTask; })) { Interval = TimeSpan.FromMilliseconds(20) };
        waiting.Start();
        await Until(() => waiting.Current is TelegramSetup.Phase.Waiting);
        waiting.Close();
        await (waiting.CancelTask ?? Task.CompletedTask);
        Assert.Equal(["p2"], cancelled);
        Assert.IsType<TelegramSetup.Phase.Idle>(waiting.Current);

        var expiring = new TelegramSetup(new TelegramSetup.Calls(
            _ => Task.FromResult(new TelegramSetupStart("p3", "https://t.me/z", "")),
            (_, _) => throw FakePagesGateway.Http(410),
            (_, _, _) => throw new InvalidOperationException(),
            _ => Task.CompletedTask)) { Interval = TimeSpan.FromMilliseconds(20) };
        expiring.Start();
        await Until(() => expiring.Current is TelegramSetup.Phase.Expired);
        Assert.Equal(["42", "43"], TelegramSetup.UserIds("42, 43,42"));
        Assert.Null(TelegramSetup.UserIds("42, abc"));
        Assert.Null(TelegramSetup.UserIds(" "));
        Assert.Equal("tg", new TelegramSetupStart("p", "tg://resolve", "").OpenUrl!.Scheme);
        Assert.Null(new TelegramSetupStart("p", "javascript:alert(1)", "").OpenUrl);
    }

    internal static async Task Until(Func<bool> condition, int seconds = 10)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(20);
        }
    }
}

public class WebhooksTests
{
    [Fact]
    public void RoutesAndWords()
    {
        var answer = WebhooksAnswer.From(JsonNode.Parse("""
        {"enabled":true,"subscriptions":[{"name":"github-push","events":["push"," ","pull_request"],"deliver":"telegram","url":"http://x/webhooks/github-push"},
          {"name":"invoice-paid","deliver":""},{"name":"status-page","enabled":false},{"name":"github-push"},{"description":"no name"}]}
        """))!;
        Assert.Equal(["github-push", "invoice-paid", "status-page"], answer.Subscriptions.Select(r => r.Name));
        Assert.Equal("push, pull_request → Telegram", answer.Subscriptions[0].Summary);
        Assert.Equal("All Events → Log Only", answer.Subscriptions[1].Summary);
        Assert.Equal("All Events to Log Only", answer.Subscriptions[1].SpokenSummary);
        Assert.True(answer.Subscriptions[1].Enabled);   // default-on
        Assert.False(answer.Subscriptions[2].Enabled);
        Assert.True(answer.Subscriptions[0].Matches("PULL"));
        Assert.True(answer.Subscriptions[1].Matches("log only"));
        Assert.Null(WebhooksAnswer.From(new JsonObject()));
        Assert.True(new WebhookEnableResult(true, false).ShowsRestartNotice);
        Assert.False(new WebhookEnableResult(true, true).ShowsRestartNotice);
        Assert.Equal(WebhookWords.NameTaken, WebhookWords.CreateFailure(FakePagesGateway.Http(409)));
        Assert.Equal("Couldn’t turn “x” off", WebhookWords.ToggleFailure("x", false));
        Assert.Equal("GitHub Comment", WebhookDeliver.Label("github_comment"));
    }

    [Fact]
    public void FormPayloadSendsOnlyWhatHasAValue()
    {
        var bare = new WebhookForm { Name = " github-push " };
        Assert.Equal("""{"name":"github-push","deliver":"log","deliver_only":false}""", bare.Payload().ToJsonString());
        var full = new WebhookForm
        {
            Name = "deploy", Description = "Ships", Events = "push, ,pull_request\nrelease", Skills = "checks", Deliver = "slack",
            DeliverChatId = " C123 ", DeliverOnly = true, Prompt = " Say it ",
        };
        Assert.Equal("""{"name":"deploy","deliver":"slack","deliver_only":true,"description":"Ships","events":["push","pull_request","release"],"skills":["checks"],"deliver_chat_id":"C123","prompt":"Say it"}""",
            full.Payload().ToJsonString());
        Assert.False((full with { Deliver = "log" }).Payload()["deliver_only"]!.GetValue<bool>());
        Assert.False((full with { Deliver = "email" }).Payload().ContainsKey("deliver_chat_id"));
        Assert.True(new WebhookForm { Name = "My Hook" }.NameIsValid);   // spaces become hyphens
        Assert.False(new WebhookForm { Name = "-hook" }.NameIsValid);
        Assert.False(new WebhookForm { Name = "" }.CanCreate);
    }
}

public class ForeignSessionsTests
{
    private static ForeignSession S(string id, string title = "", string? cwd = null, int turns = 2, string label = "Claude Code", string excerpt = "") =>
        new(id, "claude", label, title, cwd, null, turns, excerpt);

    [Fact]
    public void RulesAndWords()
    {
        var merged = ForeignWords.Merge([S("a"), S("b"), S("a")], [S("b", "new"), S("c")]);
        Assert.Equal(["a", "b", "c"], merged.Select(s => s.Id));
        Assert.Equal("new", merged[1].Title);
        Assert.Equal("Claude Code Conversation", ForeignWords.Title(S("x")));
        Assert.Equal("Untitled Conversation", ForeignWords.Title(S("x", label: "")));
        Assert.Equal("Fix the build", ForeignWords.Title(S("x", " Fix\nthe   build ")));
        var now = DateTimeOffset.UtcNow;
        Assert.Equal("site · 12 messages · 2 hours ago", ForeignWords.Detail(S("x", cwd: "/Users/me/site", turns: 12) with { Modified = now.AddHours(-2) }, now));
        Assert.Equal("1 message", ForeignWords.Detail(S("x", turns: 1), now));
        Assert.Equal("just now", ForeignWords.Relative(now.AddSeconds(30), now));
        Assert.Equal("just now", ForeignWords.Relative(now.AddMinutes(5), now));
        Assert.Equal("1 day ago", ForeignWords.Relative(now.AddDays(-1), now));
        Assert.Equal(["x"], ForeignWords.Filter([S("x", excerpt: "Deploy NOW"), S("y")], "deploy").Select(s => s.Id));
        Assert.Equal("Studio’s Mac mini", ForeignWords.FriendlyHost("Studios-Mac-mini.local"));
        Assert.Equal("192.168.1.4", ForeignWords.FriendlyHost("192.168.1.4"));
        Assert.Equal("Reading from the computer running Hermes", ForeignWords.ReadingFrom(null));
        Assert.Equal(PagesRest.OlderHermes, ForeignWords.ScanHelp(new GatewayException("rpc", "x", rpcCode: -32601)));
        Assert.StartsWith("Reading the Claude Code and Codex logs", ForeignWords.ScanHelp(new GatewayException("timeout", "x")));
        Assert.StartsWith("Your sign-in to Hermes has expired", ForeignWords.ScanHelp(FakePagesGateway.Http(401)));
        Assert.StartsWith("Hermes HQ can’t reach", ForeignWords.ScanHelp(new GatewayException("offline", "x")));
        Assert.Equal($"{ForeignWords.ScanHelpText} (Disk full)", ForeignWords.ScanHelp("Disk full"));
        Assert.Equal("Before\nUsed Bash (2×) and Read\nAfter", ForeignWords.PreviewText("Before\n[ran tool: Bash]\n\n[ran tool: Read]\n[ran tool: Bash]\nAfter"));
        Assert.Equal("You", ForeignWords.Speaker(new ForeignTurn("user", "x"), "Codex"));
        Assert.Equal("Codex", ForeignWords.Speaker(new ForeignTurn("assistant", "x"), "Codex"));
        Assert.Equal("Another App", ForeignWords.SourceName(""));
        Assert.Equal("Gemini", ForeignWords.SourceName("gemini"));
    }

    [Fact]
    public void ParamsHaveExactlyTheirKeys()
    {
        Assert.Equal("""{"limit":50}""", ForeignSessionsApi.ListParams("default", null, 0).ToJsonString());
        Assert.Equal("""{"limit":50,"source":"codex","offset":50,"profile":"inbox"}""", ForeignSessionsApi.ListParams("inbox", "codex", 50).ToJsonString());
        Assert.Equal("""{"limit":50}""", ForeignSessionsApi.ListParams(null, "gemini", 0).ToJsonString());
        Assert.Equal("""{"id":"fs-1"}""", ForeignSessionsApi.IdParams("default", "fs-1").ToJsonString());
        var preview = ForeignPreview.From(JsonNode.Parse("""{"messages":[{"role":"user","content":"Hi"},{"content":""},{"content":"Yo"}],"truncated":true,"already_imported":""}"""));
        Assert.Equal(2, preview.Messages.Count);
        Assert.Equal("assistant", preview.Messages[1].Role);
        Assert.Equal(2, preview.Total);
        Assert.Null(preview.AlreadyImported);
        Assert.Throws<PagesMessageException>(() => ForeignImportResult.From(new JsonObject()));
        var page = ForeignPage.From(JsonNode.Parse("""{"sessions":[{"id":"a","mtime":1700000000},{"id":" "},{"x":1}],"next_offset":0,"unreadable":"3"}"""));
        Assert.Single(page.Sessions);
        Assert.Null(page.NextOffset);
        Assert.Equal(3, page.Unreadable);
        Assert.Equal("Claude Code", ForeignSession.From(JsonNode.Parse("""{"id":"a","source":"claude"}"""))!.Label);
    }

    [Fact]
    public async Task StorePagesWithoutRepeatsAndStopsOnAnEmptyPage()
    {
        var gw = new FakePagesGateway
        {
            OnCall = (_, p) => (p["offset"]?.GetValue<int>() ?? 0) switch
            {
                0 => JsonNode.Parse("""{"sessions":[{"id":"a"},{"id":"b"}],"next_offset":2,"host":"Studios-Mac-mini.local"}""")!,
                2 => JsonNode.Parse("""{"sessions":[{"id":"b"},{"id":"c"}],"next_offset":4,"unreadable":1}""")!,
                _ => JsonNode.Parse("""{"sessions":[],"next_offset":6}""")!,
            },
        };
        var store = new ForeignSessionsStore(gw, "default");
        await store.Reload();
        Assert.IsType<ForeignSessionsStore.Phase.Loaded>(store.Current);
        Assert.Equal("Studios-Mac-mini.local", store.Host);
        await store.LoadMore();
        Assert.Equal(["a", "b", "c"], store.Rows.Select(r => r.Id));
        Assert.Equal(1, store.Unreadable);
        await store.LoadMore();
        Assert.False(store.HasMore);
        store.Query = "c";
        Assert.Empty(store.Visible);   // the id isn't searched: title, folder, excerpt
        await store.SetSource(ForeignSessionsStore.SourceKind.Claude);
        Assert.Equal("claude", gw.Calls[^1].Params["source"]!.GetValue<string>());

        gw.OnCall = (_, _) => throw new GatewayException("rpc", "x", rpcCode: -32601);
        Exception? first = new();
        store.FirstRead += e => first = e;
        await store.SetProfile("inbox");
        Assert.Equal(new ForeignSessionsStore.Phase.Failed(PagesRest.OlderHermes, PagesRest.OlderHermes), store.Current);
        Assert.NotNull(first);
    }
}

public class GatewayRestartTests
{
    [Fact]
    public async Task RunsToItsEndOrSaysWhyNot()
    {
        var reads = new Queue<GatewayActionStatus?>([null, new("gateway-restart", true, null, []), new("gateway-restart", false, 0, ["", "Gateway restarted.", " "])]);
        var run = new GatewayActionRun((_, _) => reads.Dequeue() is { } s ? Task.FromResult(s) : throw new GatewayException("offline", "down"))
            { Interval = TimeSpan.FromMilliseconds(10) };
        var finished = new List<bool>();
        run.Finished += finished.Add;
        await run.Start(_ => Task.FromResult("gateway-restart"));
        Assert.Equal(new GatewayActionRun.Phase.Finished(true, "Gateway restarted."), run.Current);
        Assert.Equal([true], finished);
        Assert.Equal(("Gateway Restarted", false, false), GatewayRestartWords.Words(run.Current));

        var untracked = new GatewayActionRun((_, _) => throw FakePagesGateway.Http(404)) { Interval = TimeSpan.FromMilliseconds(10) };
        await untracked.Start(_ => Task.FromResult("x"));
        Assert.IsType<GatewayActionRun.Phase.Untracked>(untracked.Current);
        Assert.Equal(GatewayRestartWords.Untracked, GatewayRestartWords.Words(untracked.Current)!.Value.Text);

        var refused = new GatewayActionRun((_, _) => throw new InvalidOperationException());
        await refused.Start(_ => throw new PagesMessageException("Busy."));
        Assert.Equal(new GatewayActionRun.Phase.Failed("Busy."), refused.Current);
        Assert.Null(GatewayRestartWords.Words(new GatewayActionRun.Phase.Idle()));
        Assert.Equal("The gateway didn’t restart.", GatewayRestartWords.Words(new GatewayActionRun.Phase.Finished(false, null))!.Value.Text);
        Assert.False(GatewayActionStatus.From(JsonNode.Parse("""{"exit_code":1}"""), "n").Running);
        Assert.True(GatewayActionStatus.From(new JsonObject(), "n").Running);
    }
}

public class MoreSearchTests
{
    [Fact]
    public void ScoresAndRanks()
    {
        Assert.Equal(0, MoreSearch.Score("mess", "Messaging"));
        Assert.Equal(1, MoreSearch.Score("tree", "Spawn Tree"));
        Assert.Equal(2, MoreSearch.Score("ag", "Messaging"));
        Assert.Equal(3, MoreSearch.Score("telegram", "Messaging", ["telegram"]));
        Assert.Null(MoreSearch.Score("telegram slack", "Messaging", ["telegram"]));
        Assert.Equal(0, MoreSearch.Score("CAFE", "Café notes"));
        Assert.Null(MoreSearch.Score("  ", "x"));
        var ranked = MoreSearch.Rank([new("a", "Webhooks", Keywords: ["hooks"]), new("b", "Hooks"), new("b", "Hooks again"), new("c", "Other")], "hooks");
        Assert.Equal(["b", "a"], ranked.Select(r => r.Id));
        Assert.Equal("1.2.3", MoreSearch.ShortVersion("v1.2.3+abc"));
        Assert.Equal("Bot", MoreSearch.BotDetail("inbox", "inbox"));
        Assert.Equal("Bot · inbox", MoreSearch.BotDetail("inbox", "Inbox"));
        Assert.True(MoreSearch.HiddenSession("Bot Chat"));
        Assert.True(MoreSearch.HiddenSession("Group: Ops"));
        Assert.Equal("Untitled Chat", MoreSearch.SessionTitle(" "));
    }

    [Fact]
    public void GroupsActionsAndStart()
    {
        MoreSearch.Item[] pages = [new("webhooks", "Webhooks"), new("import-sessions", "Import Sessions"), new("messaging", "Messaging", Keywords: ["telegram"])];
        var sessions = Enumerable.Range(0, 9).Select(i => new MoreSearch.Item($"default|s{i}", $"Import notes {i}")).ToList();
        var groups = MoreSearch.Results("import", pages, [], sessions, [], MoreSearch.Actions(new()));
        Assert.Equal([MoreSearch.Kind.GoTo, MoreSearch.Kind.Sessions], groups.Select(g => g.Kind));
        Assert.Equal(MoreSearch.Limit, groups[1].Rows.Count);
        Assert.Equal("Show All 9", groups[1].ShowAll);
        Assert.Null(groups[0].ShowAll);
        Assert.Equal(9, MoreSearch.Results("import", pages, [], sessions, [], [], allSessions: true)[1].Rows.Count);
        Assert.Equal("Messaging", MoreSearch.Results("telegram", pages, [], [], [], [])[0].Rows[0].Title);
        Assert.Equal("Webhooks", MoreSearch.Results("triggers", pages, [], [], [], [])[0].Rows[0].Title);   // the web's extra words
        Assert.Empty(MoreSearch.Results(" ", pages, [], [], [], []));

        var actions = MoreSearch.Actions(new(Writable: true, Kanban: true, CommandCenter: true, Version: "v2.4.0+g1"));
        Assert.Equal(["new-chat", "new-bot", "new-task", "restart-gateway", "update-hermes", "perf-logs"], actions.Select(a => a.Id));
        Assert.Equal("Hermes 2.4.0", actions.Single(a => a.Id == "update-hermes").Detail);
        Assert.Equal(["perf-logs"], MoreSearch.Actions(new(Writable: false)).Select(a => a.Id));

        // "New Chat" + Return opens New Chat, wherever its group sits.
        Hermes.Core.Settings.SettingsSearchEntry[] settings = [new("personality", "New Chat Personality", "Chat", [], "personality")];
        var mixed = MoreSearch.Results("new chat", [], [], [], settings, actions);
        Assert.Equal((1, 0), MoreSearch.StartRow(mixed, "New Chat"));
        Assert.Equal((MoreSearch.Kind.Settings, new MoreSearch.Item("personality", "New Chat Personality", "Settings › Chat")), MoreSearch.First(mixed));
    }

    [Fact]
    public void ListSearchFiltersAndWordsTheMiss()
    {
        var rows = new[] { ("Inbox", "mail"), ("Deploys", "builds"), ("Research", (string?)null) };
        Assert.Equal(["Deploys"], ListSearch.Filter(rows, " BUILD ", r => [r.Item1, r.Item2]).Select(r => r.Item1));
        Assert.Equal(3, ListSearch.Filter(rows, "", r => [r.Item1]).Count);
        Assert.Equal("No Results for “zzz”", ListSearch.MissTitle(" zzz "));
        Assert.Equal("Check the spelling, or try another word.", ListSearch.MissText);
    }
}

public class QrCodeTests
{
    /// `qrencode -l M -t ASCII "https://t.me/x"` (libqrencode 4), the same mask forced.
    private static readonly string[] Reference =
    [
        "#######  # ## #######", "#     # ###   #     #", "# ### #   ### # ### #", "# ### #  # #  # ### #", "# ### # #   # # ### #",
        "#     #  ###  #     #", "####### # # # #######", "         ###         ", "# # # #   #     #  # ", "  ##   ###  # ###   #",
        "## ## ### ####  # ###", "# # #  ###  #   #  # ", "####  # # ## # # #   ", "        # ###  ##  ##", "#######  #  # # # ###",
        "#     #  ##  # ##  ##", "# ### # # ###    # # ", "# ### #   ### # ## # ", "# ### # ## ##   # # #", "#     #  ##     #  # ",
        "####### # ##    ## ##",
    ];

    [Fact]
    public void MatchesAReferenceEncoder()
    {
        var qr = QrCode.Encode("https://t.me/x", mask: 0)!;
        Assert.Equal(1, qr.Version);
        Assert.Equal(string.Join("\n", Reference) + "\n", qr.Text());
        var best = QrCode.Encode("https://t.me/x")!;
        Assert.InRange(best.Mask, 0, 7);
        Assert.Equal(10, QrCode.Encode(new string('a', 200))!.Version);
        Assert.Null(QrCode.Encode(new string('a', 3000)));
    }
}
