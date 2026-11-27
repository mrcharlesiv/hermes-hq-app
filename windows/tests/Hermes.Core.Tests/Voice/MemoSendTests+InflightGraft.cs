// [WIN-INFLIGHT-GRAFT] The gateway's running and queued prompts in the chat (93f984bb1 HermesKit/Chat/
// LiveChatSession+Sync.swift `graftInflight` / `graftInflightTurn`, the reconnect's anchor check, docs/spec 04 §2.5,
// 03 §4.5, 04 §7.3–7.4), and a returned title typed while a reply runs (LiveChatSession.swift `sendAfterOpen`).
//
// Ported from Tests/Chat/ChatCatchUpTests.swift: aTurnRunningAfterTheActivateIsReadAfresh (the activate's running turn
// makes the chat busy; Windows has no early read to drop), anOwnTurnThatEndedWhileAwayShowsItsWholeReplyBesideTheNextTurn
// and ownRunningTurnWhoseBubbleShowsOtherTextIsKeptOnReconnect (the anchor key; Windows grafts no reply text, so the
// running reply's next words open their bubble under the prompt). Not ported: the cut cases (liveTurnUserIndex), which
// Windows' whole-page read has no counterpart of, and HelperNoteInflightTests (helper notes as a turn's prompt).
// Added (the Mac has no unit test of these, stated from the Swift): the "local-user-inflight-" bubble, a titled inflight
// prompt, the queued prompt's bubble, a turn that ended while away, a titled anchor, and a title typed while a reply
// runs. On the loopback stand-in of the memo cases; synthetic data only.

using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    private static JsonObject Snapshot(bool running, string? user = null, string assistant = "", string? queued = null)
    {
        var s = new JsonObject { ["session_id"] = VoiceFakeClient.Rid, ["running"] = running };
        if (user != null) s["inflight"] = new JsonObject { ["user"] = user, ["assistant"] = assistant, ["streaming"] = running };
        if (queued != null) s["queued"] = new JsonObject { ["user"] = queued };
        return s;
    }

    /// The link drops and comes back: the chat binds again with `session.activate` answering `snapshot`.
    private static async Task Reactivate(Rig rig, JsonObject snapshot)
    {
        rig.Socket.OnCall((method, p, attempt) => method is "session.activate" or "session.resume"
            ? snapshot.DeepClone() : Loopback.Default(method, p, attempt));
        var before = rig.Socket.Calls("session.activate").Count;
        rig.Socket.Cut();
        Assert.True(await Until(() => rig.Socket.Calls("session.activate").Count > before, 15));
        await Task.Delay(400);
    }

    private static List<string> Users(Rig rig) => [.. rig.Chat.Messages.Where(m => m.Role == Role.User).Select(m => m.Text)];

    /// A turn the chat didn't see start (another device's prompt): its prompt's bubble goes in, so the running reply
    /// sits under it; the snapshot naming the newest prompt shown adds nothing.
    [Fact]
    public async Task AnInflightPromptNotShownAddsItsBubble()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        await Reactivate(rig, Snapshot(running: true, "first"));
        Assert.Equal(["first"], Users(rig));                                      // the newest shown is the running one
        await Reactivate(rig, Snapshot(running: true, "  From the laptop\n"));
        var bubble = rig.Chat.Messages.Last(m => m.Role == Role.User);
        Assert.StartsWith("local-user-inflight-", bubble.Id, StringComparison.Ordinal);
        Assert.Equal("From the laptop", bubble.Text);
        Assert.False(bubble.IsPending);
        Assert.True(rig.Chat.Busy);
        await rig.Socket.Emit("message.start", []);
        await rig.Socket.Emit("message.delta", new JsonObject { ["text"] = "Work" });
        Assert.True(await Until(() => rig.Chat.Messages.LastOrDefault()?.Text == "Work"));
        var shown = rig.Chat.Messages;
        Assert.Equal(bubble.Id, shown[^2].Id);                                   // the reply sits under its prompt
        await Reactivate(rig, Snapshot(running: true, "From the laptop"));
        Assert.Single(rig.Chat.Messages, m => m.Id.StartsWith("local-user-inflight-", StringComparison.Ordinal));   // once
    }

    /// A titled request running elsewhere shows its title, and a titled bubble already shown is its prompt.
    [Fact]
    public async Task ATitledInflightPromptShowsItsTitle()
    {
        await using var rig = new Rig(_stores, profile: "default");
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        rig.Chat.SentTitles.Note(TitledPrompt, TitledTitle);
        await Reactivate(rig, Snapshot(running: true, SentTitles.Flat(TitledPrompt)));
        Assert.Equal(["first", TitledTitle], Users(rig));
        await Reactivate(rig, Snapshot(running: true, TitledPrompt));
        Assert.Equal(["first", TitledTitle], Users(rig));                         // no second bubble
    }

    /// The gateway's queued prompt shows as a bubble unless one of the last three rows already says it.
    [Fact]
    public async Task TheQueuedPromptShowsItsBubble()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        await Reactivate(rig, Snapshot(running: true, "first", queued: "and then this"));
        var queued = rig.Chat.Messages.Last(m => m.Role == Role.User);
        Assert.StartsWith("local-user-queued-", queued.Id, StringComparison.Ordinal);
        Assert.Equal("and then this", queued.Text);
        await Reactivate(rig, Snapshot(running: true, "first", queued: "and  then this"));
        Assert.Equal(["first", "and then this"], Users(rig));                     // already shown: once, and the
                                                                                  // running prompt is still "first"
        // The queued one started: its bubble is the running turn's prompt.
        await Reactivate(rig, Snapshot(running: true, "and then this"));
        Assert.Equal(["first", "and then this"], Users(rig));
    }

    /// `aTurnRunningAfterTheActivateIsReadAfresh`: the activate says a turn runs, so the chat is busy; one that says
    /// nothing runs settles the turn the chat left streaming (it ended while away).
    [Fact]
    public async Task TheActivateSaysWhetherATurnRuns()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        Assert.False(rig.Chat.Busy);
        await Reactivate(rig, Snapshot(running: true, "first", "Work"));
        Assert.True(rig.Chat.Busy);
        await rig.Socket.Emit("message.start", []);
        await rig.Socket.Emit("message.delta", new JsonObject { ["text"] = "Work" });
        Assert.True(await Until(() => rig.Chat.Messages.Any(m => m.IsStreaming)));
        rig.Socket.History = Rows(ReplyRow("Work, all of it.", 12));
        await Reactivate(rig, Snapshot(running: false));
        Assert.True(await Until(() => !rig.Chat.Busy, 15));
        Assert.DoesNotContain(rig.Chat.Messages, m => m.IsStreaming);
    }

    /// `anOwnTurnThatEndedWhileAwayShowsItsWholeReplyBesideTheNextTurn`: our turn A ended while away and a queued B
    /// started: A's partial isn't carried as B's; the read shows A's whole stored reply, B's prompt once, B running.
    [Fact]
    public async Task AnOwnTurnThatEndedWhileAwayShowsItsWholeReplyBesideTheNextTurn()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? new JsonObject { ["user_row_id"] = 8000 } : Loopback.Default(method, p, attempt));
        Assert.Equal(SendOutcome.Accepted, await Within(rig.Chat.SendAsync("Turn A")));
        await rig.Socket.Emit("message.start", []);
        await rig.Socket.Emit("message.delta", new JsonObject { ["text"] = "A partial" });
        Assert.True(await Until(() => rig.Chat.Messages.Any(m => m.Text == "A partial")));
        rig.Socket.History = Rows(UserRow("Turn A", 8000), ReplyRow("A partial, then the whole of A.", 8001),
            UserRow("Turn B", 8002), ReplyRow("B so far", 8003));
        await Reactivate(rig, Snapshot(running: true, "Turn B", "B so far"));
        Assert.True(await Until(() => rig.Chat.Messages.Any(m => m.Text == "A partial, then the whole of A."), 15));
        var texts = rig.Chat.Messages.Select(m => m.Text).ToList();
        Assert.DoesNotContain("A partial", texts);
        Assert.Single(texts, t => t == "Turn A");
        Assert.Single(texts, t => t == "Turn B");
        Assert.Equal(["Turn A", "A partial, then the whole of A.", "Turn B", "B so far"], texts.TakeLast(4));
        Assert.DoesNotContain(rig.Chat.Messages, m => m.IsStreaming);              // A's live bubble was sealed
        Assert.True(rig.Chat.Busy);
    }

    /// `ownRunningTurnWhoseBubbleShowsOtherTextIsKeptOnReconnect`: a bubble showing other words than went out (a
    /// skill's invocation, or a titled request's title) is still the running turn's prompt by its anchor key: the live
    /// bubble keeps streaming, no second prompt bubble.
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task OwnRunningTurnWhoseBubbleShowsOtherTextIsKeptOnReconnect(bool titled)
    {
        await using var rig = new Rig(_stores, profile: "default");
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        var (sent, shown) = titled ? (TitledPrompt, TitledTitle) : ("Research the tides in depth.", "/research tides");
        if (titled) rig.Chat.SentTitles.Note(TitledPrompt, TitledTitle);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? new JsonObject { ["user_row_id"] = 8000 } : Loopback.Default(method, p, attempt));
        Assert.Equal(SendOutcome.Accepted, await Within(rig.Chat.SendAsync(sent, display: shown)));
        await rig.Socket.Emit("message.start", []);
        await rig.Socket.Emit("message.delta", new JsonObject { ["text"] = "Tides so far" });
        Assert.True(await Until(() => rig.Chat.Messages.Any(m => m.Text == "Tides so far")));
        await Reactivate(rig, Snapshot(running: true, SentTitles.Flat(sent), "Tides so far"));
        await rig.Socket.Emit("message.delta", new JsonObject { ["text"] = ", and more" });
        Assert.True(await Until(() => rig.Chat.Messages.Any(m => m.Text == "Tides so far, and more")));
        Assert.Equal(["first", shown], Users(rig));
        var after = rig.Chat.Messages.SkipWhile(m => m.Text != shown).Skip(1).ToList();
        Assert.Single(after);
        Assert.True(after[0].IsStreaming);
        Assert.True(rig.Chat.Busy);
    }

    /// `sendAfterOpen`: a returned title typed in the main bot's field while a reply runs goes out as its request (it
    /// waits in line, as anything with words other than it shows does), never steered in as the bare title.
    [Fact]
    public async Task ATitleTypedWhileAReplyRunsGoesOutAsItsRequest()
    {
        await using var rig = new Rig(_stores, profile: "default");
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        rig.Chat.SentTitles.Note(TitledPrompt, TitledTitle);
        Assert.Equal(SendOutcome.Accepted, await Within(rig.Chat.SendAsync("Turn A")));
        await rig.Socket.Emit("message.start", []);
        Assert.True(rig.Chat.CanSteerNow);
        rig.Composer.Send(TitledTitle);
        await Task.Delay(300);
        Assert.Empty(rig.Socket.Calls("session.redirect"));                        // not steered as the bare title
        var row = Assert.Single(rig.Composer.Queue.Items);
        Assert.Equal((TitledPrompt, TitledTitle), (row.Text, row.Display));
        await rig.Socket.Emit("message.complete", new JsonObject { ["text"] = "Done A." });
        await rig.Socket.Emit("session.info", new JsonObject { ["running"] = false });
        Assert.True(await Until(() => rig.Socket.Calls("prompt.submit").Count == 2, 15));
        Assert.Equal(TitledPrompt, rig.Socket.Calls("prompt.submit")[^1].Str("text"));
        Assert.Equal(TitledTitle, rig.Chat.Messages.Last(m => m.Role == Role.User).Text);
        // Plain words typed while a reply runs still steer.
        await rig.Socket.Emit("message.start", []);
        rig.Composer.Send("and quickly");
        Assert.True(await Until(() => rig.Socket.Calls("session.redirect").Count == 1));
        Assert.Equal("and quickly", rig.Socket.Calls("session.redirect")[0].Str("text"));
    }
}
