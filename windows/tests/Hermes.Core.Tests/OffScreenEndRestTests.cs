// [WIN-OFFSCREEN-END-REST] The rest of the Mac's off-screen turn end: a turn that ends in an error gives its bot row the
// standing problem's orange words (`noteTurnOutcome` → BotStore `noteTurnFailed`/`noteTurnSucceeded`, Attention), the
// step the ended turn was on leaves its bot row (`offScreenTurnEnded` → `liveSteps.clear(runtime)`), and the account's
// teardown resets the marks at the moment the app signs out or moves to another gateway. As the Mac at 93f984bb1:
// App/AppModel.swift (`gatewayEvent`, `noteTurnOutcome`, `offScreenTurnEnded`, `tearDown`),
// HermesKit/Store/BotStore+RowStatus.swift, HermesKit/Model/Attention.swift, HermesKit/Store/BotStore.swift `ownSteps`.
// Ported case for case from Tests/BotsList/BotsListTests.swift (standingProblemsAreNamedAndPassingOnesAreNot,
// aStandingFailureStaysUntilTheNextGoodTurn, the attention steps of rowStatusOrder); the rest state the AppModel hooks
// and the Windows-only rules from the Swift. The Mac's second bot "ada" is the demo bot wren here. Synthetic data only.
using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Chat;
using Hermes.Core.Rpc;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests;

public class OffScreenEndRestTests
{
    // MARK: BotsListTests.swift — L185 the classifier

    [Fact]
    public void StandingProblemsAreNamedAndPassingOnesAreNot()
    {
        (string Message, Attention? Expected)[] cases =
        [
            ("HTTP 401 Unauthorized", Attention.ProviderAuthOrAccess),
            ("403 Forbidden: this key cannot use the model", Attention.ProviderAuthOrAccess),
            ("Authentication failed for provider anthropic", Attention.ProviderAuthOrAccess),
            ("invalid api key", Attention.ProviderAuthOrAccess),
            ("Invalid_API_Key supplied", Attention.ProviderAuthOrAccess),
            ("Your credentials are expired", Attention.ProviderAuthOrAccess),
            ("credential invalid", Attention.ProviderAuthOrAccess),
            ("You exceeded your current quota", Attention.ProviderQuotaLimit),
            ("Out of funds", Attention.ProviderQuotaLimit),
            ("insufficient credits to run this request", Attention.ProviderQuotaLimit),
            ("Insufficient balance", Attention.ProviderQuotaLimit),
            ("402 Payment Required", Attention.ProviderQuotaLimit),
            ("Check your billing details", Attention.ProviderQuotaLimit),
            ("No LLM provider configured", Attention.MissingConfig),
            ("No access token for provider", Attention.MissingConfig),
            ("provider is not configured", Attention.MissingConfig),
            ("No API key found for openai", Attention.MissingConfig),
            ("Missing API key", Attention.MissingConfig),
            ("The agent is blocked on a tool", Attention.AgentBlocked),
            ("Rate limit reached", null),
            ("rate-limited, slow down", null),
            ("429 Too Many Requests", null),
            ("Too many requests", null),
            ("500 Internal Server Error", null),
            ("503 Service Unavailable", null),
            ("server error", null),
            ("The model is overloaded", null),
            ("Request timed out", null),
            ("timeout waiting for the provider", null),
            ("Temporary failure, 401 will clear", null),            // a passing failure wins over the words after it
            ("Something else went wrong", null),
            ("", null),
        ];
        foreach (var (message, expected) in cases) Assert.True(expected == AttentionReason.From(message), message);
        Assert.Null(AttentionReason.From(null));
        // The gateway's own reason wins over the message.
        Assert.Equal(Attention.ProviderQuotaLimit, AttentionReason.From("rate limit", "provider_quota_limit"));
        Assert.Equal(Attention.ProviderAuthOrAccess, AttentionReason.From("401", "something_new"));
        Assert.Equal(Attention.MissingConfig, AttentionReason.From(null, "  Missing_Config \n"));
        foreach (var kind in Enum.GetValues<Attention>())
        {
            Assert.NotEmpty(kind.Words());
            Assert.DoesNotContain("Dispatch", kind.Words());
            Assert.DoesNotContain("profile", kind.Words().ToLowerInvariant());
        }
        Assert.Equal(["provider_auth_or_access", "provider_quota_limit", "missing_config", "agent_blocked"],
            Enum.GetValues<Attention>().Select(k => k.RawValue()));
        Assert.Equal(["Sign in again for this bot", "Quota or balance exhausted", "Provider not set up", "Bot is blocked — see its last message"],
            Enum.GetValues<Attention>().Select(k => k.Words()));
    }

    // MARK: BotsListTests.swift — the store

    private static JsonObject Session(string id, string? resolved, string preview, double lastActive)
    {
        var o = new JsonObject { ["id"] = id, ["title"] = "Bot Chat", ["preview"] = preview, ["last_active"] = lastActive, ["message_count"] = 4.0 };
        if (resolved != null) o["resolved_id"] = resolved;
        return o;
    }

    /// ivy's Bot Chat goes by "reg" and its tip "tip"; wren's by "wren-chat".
    private static BotStore Bots()
    {
        var store = new BotStore(new FakeGateway(), new MemoryDeviceStore());
        store.ApplyFull(new JsonObject
        {
            ["profiles"] = new JsonArray
            {
                new JsonObject { ["name"] = "ivy", ["canonical_session"] = Session("reg", "tip", "old words", 1_791_000_000) },
                new JsonObject { ["name"] = "wren", ["canonical_session"] = Session("wren-chat", null, "wren's", 1_791_000_500) },
            },
        }, DateTimeOffset.UtcNow);
        return store;
    }

    [Fact]
    public void AStandingFailureStaysUntilTheNextGoodTurn()
    {
        var store = Bots();
        store.NoteTurnFailed("ivy", "429 Too Many Requests");
        Assert.Null(store.Bot("ivy")!.Attention);
        store.NoteTurnFailed("ivy", "401 Unauthorized");
        Assert.Equal("Sign in again for this bot", store.Bot("ivy")!.Attention);
        Assert.Null(store.Bot("wren")!.Attention);
        store.NoteTurnFailed("ivy", "Request timed out");       // a passing failure keeps the standing one
        Assert.Equal("Sign in again for this bot", store.Bot("ivy")!.Attention);
        store.NoteTurnFailed("ivy", "out of funds");            // the latest standing one wins
        Assert.Equal("Quota or balance exhausted", store.Bot("ivy")!.Attention);
        store.NoteTurnSucceeded("ivy");
        Assert.Null(store.Bot("ivy")!.Attention);
    }

    /// rowStatusOrder's attention steps, on the store's own row: the problem outranks Working…, in orange.
    [Fact]
    public void AStandingProblemIsTheRowsOrangeStatus()
    {
        var store = Bots();
        store.SetWorkingChats("ivy", new HashSet<string> { "tip" });
        store.NoteTurnFailed("ivy", "You exceeded your current quota");
        var ivy = store.Bot("ivy")!;
        Assert.Equal(BotList.RowStatus.Attention, BotList.StatusOf(ivy));
        Assert.Equal("Quota or balance exhausted", BotList.SecondLine(ivy).Text);
        Assert.Equal(BotList.Tone.Attention, BotList.SecondLine(ivy).Tone);
        // While the chat is opening the row says so, and the problem comes back after.
        Assert.Equal(BotList.RowStatus.Waking, BotList.StatusOf(ivy with { Waking = true }));
        // The same problem again, or a good turn of a bot with none, draws nothing.
        var raised = 0;
        store.Changed += () => raised++;
        store.NoteTurnFailed("ivy", "insufficient balance");
        Assert.Equal(0, raised);
        store.NoteTurnSucceeded("wren");
        Assert.Equal(0, raised);
    }

    // MARK: AppModel.noteTurnOutcome (TurnRows.Outcome / Event → ApplyTo)

    private static RpcEvent Ev(string type, string runtime, JsonObject? payload = null) => new(type, runtime, payload ?? [], null);

    [Fact]
    public void AnOutcomeReadsTheMacsFields()
    {
        Assert.Equal(new TurnOutcome("ivy", true, "boom"), TurnRows.Outcome(Ev("error", "r1", new() { ["message"] = "boom" }), "ivy"));
        // `message`, then `error`, then `text`; an empty message gives way.
        Assert.Equal(new TurnOutcome("ivy", true, "401 Unauthorized"),
            TurnRows.Outcome(Ev("error", "r1", new() { ["message"] = "  ", ["error"] = "401 Unauthorized", ["text"] = "x" }), "ivy"));
        Assert.Equal(new TurnOutcome("ivy", true, "partial words"),
            TurnRows.Outcome(Ev("message.complete", "r1", new() { ["status"] = "error", ["text"] = "partial words" }), "ivy"));
        Assert.Equal(new TurnOutcome("ivy", true, null),
            TurnRows.Outcome(Ev("message.complete", "r1", new() { ["error"] = true }), "ivy"));
        // The gateway's reason: `data.reason` before `reason`.
        Assert.Equal(new TurnOutcome("ivy", true, "nope", "agent_blocked"),
            TurnRows.Outcome(Ev("error", "r1", new() { ["message"] = "nope", ["data"] = new JsonObject { ["reason"] = "agent_blocked" }, ["reason"] = "missing_config" }), "ivy"));
        Assert.Equal(new TurnOutcome("ivy", true, "nope", "missing_config"),
            TurnRows.Outcome(Ev("error", "r1", new() { ["message"] = "nope", ["reason"] = "missing_config" }), "ivy"));
        // A good end; a partial one says nothing; a falsy error is no error.
        Assert.Equal(new TurnOutcome("ivy", false), TurnRows.Outcome(Ev("message.complete", "r1", new() { ["text"] = "Done." }), "ivy"));
        Assert.Equal(new TurnOutcome("ivy", false), TurnRows.Outcome(Ev("message.complete", "r1", new() { ["error"] = "", ["partial"] = false }), "ivy"));
        Assert.Null(TurnRows.Outcome(Ev("message.complete", "r1", new() { ["partial"] = true }), "ivy"));
    }

    [Fact]
    public void AnOffScreenErrorEndCarriesItsFailureAndItsStepEnd()
    {
        var rows = new TurnRows();
        rows.Closed("ivy", "tip", "r1", running: true);
        var change = rows.Event(Ev("error", "r1", new() { ["message"] = "HTTP 401 Unauthorized" }), onScreen: false);
        Assert.Equal([new TurnOutcome("ivy", true, "HTTP 401 Unauthorized")], change.Outcomes!);
        Assert.Equal([new StepEnd("ivy", "tip")], change.StepEnds!);
        Assert.Null(change.Replies);
        Assert.Equal(["tip"], change.Ended);
        // A session.info end has no outcome (it isn't a message.complete or an error), but its step ends.
        rows.Closed("ivy", "tip", "r2", running: true);
        var info = rows.Event(Ev("session.info", "r2", new() { ["running"] = false }), onScreen: false);
        Assert.Null(info.Outcomes);
        Assert.Equal([new StepEnd("ivy", "tip")], info.StepEnds!);
        // A turn nobody here tracks: nothing (the Mac's `noteTurnOutcome` finds no owner).
        Assert.True(rows.Event(Ev("error", "r9", new() { ["message"] = "401" }), onScreen: false).IsEmpty);
    }

    /// The chat on screen reports its own end, but its bot's standing problem comes from the socket's frame too.
    [Fact]
    public void TheChatOnScreenGivesOnlyItsOutcome()
    {
        var rows = new TurnRows();
        var change = rows.Event(Ev("error", "r1", new() { ["message"] = "No LLM provider configured" }), onScreen: true, screenProfile: "wren");
        Assert.Equal([new TurnOutcome("wren", true, "No LLM provider configured")], change.Outcomes!);
        Assert.Empty(change.Profiles);
        Assert.Empty(change.Ended);
        Assert.Null(change.StepEnds);
        Assert.Equal([new TurnOutcome("wren", false)],
            rows.Event(Ev("message.complete", "r1", new() { ["text"] = "Hi." }), onScreen: true, screenProfile: "wren").Outcomes!);
        Assert.True(rows.Event(Ev("message.delta", "r1", new() { ["text"] = "H" }), onScreen: true, screenProfile: "wren").IsEmpty);
        Assert.True(rows.Event(Ev("session.info", "r1", new() { ["running"] = false }), onScreen: true, screenProfile: "wren").IsEmpty);
    }

    [Fact]
    public void TheOffScreenErrorEndShowsTheProblemOnTheBotRowAndEndsBothRowsWork()
    {
        var bots = Bots();
        var sessions = new SessionStore(new FakeGateway(), new MemoryDeviceStore());
        sessions.Apply(SidebarPayload.Decode(JsonNode.Parse("""
            {"recents":{"sessions":[{"id":"tip","profile":"ivy","title":"Chat","preview":"first thing I asked","last_active":1791000000,
              "message_count":4,"source":"desktop"}]},"cron":{"sessions":[]},"messaging":{"sessions":[]}}
            """)));
        var rows = new TurnRows();
        rows.ApplyTo(rows.Closed("ivy", "tip", "r1", running: true), bots, sessions);
        Assert.True(bots.Bot("ivy")!.IsWorking);
        Assert.True(sessions.LiveSummaries().Single().IsRunning);

        rows.ApplyTo(rows.Event(Ev("error", "r1", new() { ["message"] = "Out of funds" }), false), bots, sessions);
        var ivy = bots.Bot("ivy")!;
        Assert.False(ivy.IsWorking);
        Assert.Equal("Quota or balance exhausted", BotList.SecondLine(ivy).Text);
        Assert.Equal(BotList.Tone.Attention, BotList.SecondLine(ivy).Tone);
        Assert.False(ivy.Unread);                                      // no reply, no dot
        Assert.Equal("old words", ivy.Preview.Text);
        var row = sessions.LiveSummaries().Single();
        Assert.False(row.IsRunning);
        Assert.Equal("first thing I asked", row.Preview);
        Assert.Empty(sessions.Device.Latest);

        // Its next good turn, off screen too, clears it.
        rows.ApplyTo(rows.Closed("ivy", "tip", "r2", running: true), bots, sessions);
        rows.ApplyTo(rows.Event(Ev("message.complete", "r2", new() { ["text"] = "Back." }), false), bots, sessions);
        Assert.Null(bots.Bot("ivy")!.Attention);
        Assert.Equal("Back.", BotList.SecondLine(bots.Bot("ivy")!).Text);
    }

    // MARK: AppModel.offScreenTurnEnded → liveSteps.clear(runtime) (BotStore.EndStep)

    [Fact]
    public void TheStepOfTheBotChatEndsWithItsTurn()
    {
        var bots = Bots();
        var sessions = new SessionStore(new FakeGateway(), new MemoryDeviceStore());
        var rows = new TurnRows();
        rows.ApplyTo(rows.Closed("ivy", "tip", "r1", running: true), bots, sessions);
        bots.SetStep("ivy", "Reading package.json…");
        Assert.Equal("Reading package.json…", BotList.SecondLine(bots.Bot("ivy")!).Text);
        rows.ApplyTo(rows.Event(Ev("message.complete", "r1", new() { ["text"] = "Done." }), false), bots, sessions);
        Assert.Null(bots.Bot("ivy")!.Step);
        Assert.Equal("Done.", BotList.SecondLine(bots.Bot("ivy")!).Text);
    }

    /// The row's step is its own Bot Chat's (`ownSteps`): a side chat's end leaves it; a chat not stored yet is the
    /// Bot Chat (the "" key); any of the Bot Chat's ids counts.
    [Fact]
    public void ASideChatsEndLeavesTheBotChatsStep()
    {
        var bots = Bots();
        bots.SetStep("ivy", "Running npm test…");
        bots.EndStep("ivy", "side");
        Assert.Equal("Running npm test…", bots.Bot("ivy")!.Step);
        bots.EndStep("ivy", "reg");
        Assert.Null(bots.Bot("ivy")!.Step);
        bots.SetStep("ivy", "Running npm test…");
        bots.EndStep("ivy", null);
        Assert.Null(bots.Bot("ivy")!.Step);
        var raised = 0;
        bots.Changed += () => raised++;
        bots.EndStep("ivy", "tip");                                    // nothing to end: no redraw
        bots.EndStep("otto", null);
        Assert.Equal(0, raised);
    }

    /// A reconnect drops the marks of turns no chat on screen hears; as far as this device knows they are over, so the
    /// steps go too.
    [Fact]
    public void AReconnectDropsTheUnheardTurnsSteps()
    {
        var bots = Bots();
        var sessions = new SessionStore(new FakeGateway(), new MemoryDeviceStore());
        var rows = new TurnRows();
        rows.ApplyTo(rows.Closed("ivy", "tip", "r1", running: true), bots, sessions);
        bots.SetStep("ivy", "Reading package.json…");
        var change = rows.Reconnected(new HashSet<string>());
        Assert.Equal([new StepEnd("ivy", "tip")], change.StepEnds!);
        rows.ApplyTo(change, bots, sessions);
        Assert.Null(bots.Bot("ivy")!.Step);
        Assert.False(bots.Bot("ivy")!.IsWorking);
    }
}
