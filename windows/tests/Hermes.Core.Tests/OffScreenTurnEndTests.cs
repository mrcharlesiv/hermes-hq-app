// [WIN-OFFSCREEN-TURN-END] A chat closed mid-turn gets the Mac's off-screen end when its turn ends: the reply on its bot
// row and its Sessions row, and the bot's unread dot. As the Mac at 93f984bb1: App/AppModel.swift `gatewayEvent` →
// `offScreenTurnEnded` (botStore.noteChatActivity(…unseen: true, said: false), sessionStore.noteLatest(…role:
// "assistant")), HermesKit/Store/BotStore.swift `noteChatActivity`, HermesKit/Store/SessionStore+Latest.swift
// `noteLatest`/`latestText`. Ported case for case from Tests/Chat/UnreadFocusAuditTests.swift (UnreadAuditTests, both
// cases), Tests/Chat/VerificationRoundThreeTests.swift aReplySeenOrMissedUpdatesTheRowAtOnce and
// Tests/Sessions/SessionLatestTests.swift (the noteLatest step of rowShowsNewestMessageAndRereadsWhenActivityMoves);
// the rest state the AppModel hook and the Windows-only rules from the Swift. Synthetic data only.
using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Chat;
using Hermes.Core.Rpc;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests;

public class OffScreenTurnEndTests
{
    private static readonly DateTimeOffset Reply = DateTimeOffset.FromUnixTimeSeconds(1_791_001_000);

    private static JsonObject Session(string id, string? resolved, string preview, double lastActive, int count = 4)
    {
        var o = new JsonObject { ["id"] = id, ["title"] = "Bot Chat", ["preview"] = preview, ["last_active"] = lastActive, ["message_count"] = (double)count };
        if (resolved != null) o["resolved_id"] = resolved;
        return o;
    }

    /// The Mac's UnreadAuditTests/VerificationRoundThree roster: ivy's Bot Chat goes by "reg" and its tip "tip".
    private static BotStore Bots(bool withWren = false)
    {
        var profiles = new JsonArray { new JsonObject { ["name"] = "ivy", ["canonical_session"] = Session("reg", "tip", "old words", 1_791_000_000) } };
        if (withWren) profiles.Add(new JsonObject { ["name"] = "wren", ["canonical_session"] = Session("wren-chat", null, "wren's", 1_791_000_500) });
        var store = new BotStore(new FakeGateway(), new MemoryDeviceStore());
        store.ApplyFull(new JsonObject { ["profiles"] = profiles }, DateTimeOffset.UtcNow);
        return store;
    }

    // MARK: UnreadFocusAuditTests.swift — UnreadAuditTests

    /// A reply that ends in a bot's own chat while one of its side chats is on screen gets its dot at once.
    [Fact]
    public void AReplyInTheBotsOwnChatGetsItsDotWhileASideChatIsOpen()
    {
        var store = Bots();
        store.VisibleBot = null;               // a side chat of ivy's on screen: ShellPage sets VisibleBot for the Bot Chat only
        store.NoteChatActivity("ivy", "tip", "The new reply", Reply, unseen: true);
        Assert.True(store.Bot("ivy")!.Unread);
    }

    /// …and none while the bot's own chat is the one on screen.
    [Fact]
    public void NoDotWhileTheBotsOwnChatIsOnScreen()
    {
        var store = Bots();
        store.VisibleBot = "ivy";
        store.NoteChatActivity("ivy", "tip", "The new reply", Reply, unseen: true);
        Assert.False(store.Bot("ivy")!.Unread);
    }

    // MARK: VerificationRoundThreeTests.swift

    [Fact]
    public void AReplySeenOrMissedUpdatesTheRowAtOnce()
    {
        var store = Bots(withWren: true);
        Assert.Equal(["wren", "ivy"], store.Rows.Select(b => b.Id).ToList());
        store.NoteChatActivity("ivy", "tip", "The new reply", Reply, unseen: true);
        var ivy = store.Bot("ivy")!;
        Assert.Contains("The new reply", ivy.Preview.Line);
        Assert.Equal(Reply, ivy.LastActive);
        Assert.True(ivy.Unread);
        Assert.Equal(["ivy", "wren"], store.Rows.Select(b => b.Id).ToList());          // newest first
        // A side chat of the bot doesn't patch its row.
        store.NoteChatActivity("wren", "side", "x", DateTimeOffset.FromUnixTimeSeconds(1_791_002_000), unseen: true);
        Assert.False(store.Bot("wren")!.Unread);
        Assert.Equal("wren's", store.Bot("wren")!.Preview.Text);
    }

    // MARK: SessionLatestTests.swift

    private static SessionStore Sessions(double lastActive = 1_791_000_000)
    {
        var store = new SessionStore(new FakeGateway(), new MemoryDeviceStore());
        store.Apply(Sidebar(lastActive));
        return store;
    }

    private static SidebarPayload Sidebar(double lastActive) => SidebarPayload.Decode(JsonNode.Parse($$$"""
        {"recents":{"sessions":[{"id":"s1","profile":"ivy","title":"Chat","preview":"first thing I asked","last_active":{{{lastActive}}},
          "started_at":{{{lastActive - 60}}},"message_count":4,"source":"desktop","is_active":false}]},
         "cron":{"sessions":[]},"messaging":{"sessions":[]}}
        """));

    /// A chat just left updates its row at once (the step of rowShowsNewestMessageAndRereadsWhenActivityMoves).
    [Fact]
    public void AChatJustLeftUpdatesItsRowAtOnce()
    {
        var store = Sessions();
        Assert.Equal("first thing I asked", store.LiveSummaries()[0].Preview);
        Assert.Equal("Chat", store.LiveSummaries()[0].Title);
        store.NoteLatest("ivy", "s1", "seen just now");
        Assert.Equal("seen just now", store.LiveSummaries()[0].Preview);
        Assert.Equal("Chat", store.LiveSummaries()[0].Title);
    }

    /// `noteLatest`'s guards: words only (whitespace runs fold), never a bare [SILENT], only the row of that very bot.
    [Fact]
    public void NoteLatestKeepsWordsOnlyAndOnlyForThatChat()
    {
        var store = Sessions();
        var raised = 0;
        store.Changed += () => raised++;
        store.NoteLatest("ivy", "s1", "  \n ");
        store.NoteLatest("ivy", "s1", "[SILENT]");
        store.NoteLatest("wren", "s1", "not ivy's");
        store.NoteLatest("ivy", "nope", "no such row");
        Assert.Equal(0, raised);
        Assert.Equal("first thing I asked", store.LiveSummaries()[0].Preview);
        store.NoteLatest("ivy", "s1", "the  real\nanswer", "assistant");
        Assert.Equal(1, raised);
        Assert.Equal("the real answer", store.LiveSummaries()[0].Preview);
        Assert.Equal("assistant", store.Device.Latest.Single().Value.Role);
        store.NoteLatest("ivy", "s1", "the real answer", "assistant");               // the same: no redraw
        Assert.Equal(1, raised);
    }

    /// Windows reads no chat's tail (the Mac's refreshLatest): once the row's activity moves past the recency the
    /// message was noted at, the gateway's preview is back rather than a message that may no longer be the newest.
    [Fact]
    public void ANotedMessageStandsUntilTheRowsActivityMoves()
    {
        var store = Sessions();
        store.NoteLatest("ivy", "s1", "Done.", "assistant");
        store.Apply(Sidebar(1_791_000_000));
        Assert.Equal("Done.", store.LiveSummaries()[0].Preview);
        store.Apply(Sidebar(1_791_000_030));
        Assert.Equal("first thing I asked", store.LiveSummaries()[0].Preview);
    }

    // MARK: AppModel.offScreenTurnEnded (TurnRows.Event → ApplyTo)

    private static RpcEvent Ev(string type, string runtime, JsonObject? payload = null) => new(type, runtime, payload ?? [], null);

    [Fact]
    public void AMessageCompleteOffScreenCarriesItsReply()
    {
        var rows = new TurnRows();
        rows.Closed("ivy", "tip", "r1", running: true);
        var change = rows.Event(Ev("message.complete", "r1", new JsonObject { ["text"] = "Done." }), onScreen: false);
        Assert.Equal([new OffScreenReply("ivy", "tip", "Done.")], change.Replies!);
        Assert.Equal(["tip"], change.Ended);
        Assert.False(change.IsEmpty);
    }

    [Fact]
    public void AnErrorOrASessionInfoEndCarriesNoReply()
    {
        var rows = new TurnRows();
        rows.Closed("ivy", "tip", "r1", running: true);
        Assert.Null(rows.Event(Ev("error", "r1", new JsonObject { ["text"] = "boom" }), onScreen: false).Replies);
        rows.Closed("ivy", "tip", "r2", running: true);
        Assert.Null(rows.Event(Ev("session.info", "r2", new JsonObject { ["running"] = false }), onScreen: false).Replies);
        rows.Closed("ivy", "tip", "r3", running: true);
        // A text that isn't a string is no reply (`payload["text"]?.string`).
        Assert.Null(rows.Event(Ev("message.complete", "r3", new JsonObject { ["text"] = 3 }), onScreen: false).Replies);
    }

    [Fact]
    public void TheChatOnScreenOrAnUntrackedTurnCarriesNoReply()
    {
        var rows = new TurnRows();
        rows.Closed("ivy", "tip", "r1", running: true);
        Assert.True(rows.Event(Ev("message.complete", "r1", new JsonObject { ["text"] = "Done." }), onScreen: true).IsEmpty);
        Assert.True(rows.Event(Ev("message.complete", "r9", new JsonObject { ["text"] = "Done." }), onScreen: false).IsEmpty);
    }

    [Fact]
    public void TheOffScreenEndGivesBothRowsTheReplyAndTheBotItsDot()
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
        Assert.False(bots.Bot("ivy")!.Unread);

        rows.ApplyTo(rows.Event(Ev("message.complete", "r1", new JsonObject { ["text"] = "Shipped.  Build 930\nis live." }), false),
            bots, sessions, Reply);
        var ivy = bots.Bot("ivy")!;
        Assert.False(ivy.IsWorking);
        Assert.True(ivy.Unread);
        Assert.Equal("Shipped. Build 930 is live.", ivy.Preview.Text);
        Assert.Equal(Reply, ivy.LastActive);
        Assert.Equal("Shipped. Build 930 is live.", sessions.LiveSummaries().Single(s => s.Id == "tip").Preview);
        Assert.Equal("assistant", sessions.Device.Latest.Single().Value.Role);
    }

    /// A turn whose stored id never came back still patches the bot's own row (`sessionId: nil`), not a Sessions row.
    [Fact]
    public void AnEndWithNoStoredIdPatchesTheBotRowOnly()
    {
        var bots = Bots();
        var sessions = new SessionStore(new FakeGateway(), new MemoryDeviceStore());
        var rows = new TurnRows();
        rows.Closed("ivy", null, "r1", running: true);
        rows.ApplyTo(rows.Event(Ev("message.complete", "r1", new JsonObject { ["text"] = "Done." }), false), bots, sessions, Reply);
        Assert.True(bots.Bot("ivy")!.Unread);
        Assert.Equal("Done.", bots.Bot("ivy")!.Preview.Text);
        Assert.Empty(sessions.Device.Latest);
    }

    /// The Mac's `noteChatActivity` details: the bot's own chat on screen gets the words but no dot; an older time
    /// doesn't move the row back; an empty chat counts one message; the words fold to one line of at most 80.
    [Fact]
    public void NoteChatActivityKeepsTheMacsRules()
    {
        var store = Bots();
        store.NoteChatActivity("ivy", "reg", "older", DateTimeOffset.FromUnixTimeSeconds(1_790_000_000), unseen: false);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_791_000_000), store.Bot("ivy")!.LastActive);
        Assert.Equal("older", store.Bot("ivy")!.Preview.Text);
        Assert.False(store.Bot("ivy")!.Unread);

        var words = string.Concat(Enumerable.Repeat("word ", 30));
        store.NoteChatActivity("ivy", null, words, Reply, unseen: true);
        Assert.Equal(80, store.Bot("ivy")!.Profile.CanonicalSession!.Preview!.Length);
        Assert.EndsWith("…", store.Bot("ivy")!.Profile.CanonicalSession!.Preview);
        Assert.True(store.Bot("ivy")!.Unread);

        var empty = new BotStore(new FakeGateway(), new MemoryDeviceStore());
        empty.ApplyFull(new JsonObject { ["profiles"] = new JsonArray { new JsonObject { ["name"] = "juno", ["canonical_session"] = Session("j1", null, "", 1_791_000_000, count: 0) } } },
            DateTimeOffset.UtcNow);
        Assert.False(empty.Bot("juno")!.Unread);
        empty.NoteChatActivity("juno", "j1", "Hello there.", Reply, unseen: true);
        Assert.Equal(1, empty.Bot("juno")!.MessageCount);
        Assert.True(empty.Bot("juno")!.Unread);                                      // a non-empty chat may show its dot

        // A bot not in the roster, or one without a Bot Chat, is left alone.
        empty.NoteChatActivity("otto", null, "x", Reply, unseen: true);
        Assert.Null(empty.Bot("otto"));
    }
}
