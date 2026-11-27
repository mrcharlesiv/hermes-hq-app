// [WIN-OWN-TURN-ROWS] Our own running turns on the Bots/Sessions rows, as the Mac at 93f984bb1: App/AppModel.swift
// `runningChats`, `onRunningChange`, `onExternalWorkChange`, `onStoredIdResolved`, `onRuntimeBound`, `gatewayEvent` →
// `offScreenTurnEnded`, `setWorking(profile:storedId:)`, HermesKit/Activity/TurnWorking.swift and
// HermesKit/Activity/LiveStatusWatch.swift `turnEnded`. Ported from Tests/Activity/TurnWorkingTests.swift (the three
// cases, onto ChatsWorking.Move) and Tests/ReadSync/AttentionTests.swift aTurnThisAppSawEndIsNotBroughtBackByAnOlderRead;
// the rest state the AppModel hooks from the Swift (the Mac has no AppModel unit test of them). Synthetic data only.
using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Rpc;
using Hermes.Core.Sessions;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

public class OwnTurnRowsTests
{
    // MARK: TurnWorkingTests.swift, on ChatsWorking

    [Fact]
    public void ATurnThatStartedUnstoredEndsUnderItsId()
    {
        var w = new ChatsWorking();
        w.Set("inbox", null, true);
        Assert.True(w.Busy("inbox"));
        Assert.Empty(w.StoredIds);
        Assert.True(w.Move("inbox", null, "s1"));
        Assert.Equal(["s1"], w.StoredIds.ToList());
        w.Set("inbox", "s1", false);
        Assert.False(w.Busy("inbox"));
    }

    [Fact]
    public void AnIdWithNothingUnstoredRunningChangesNothing()
    {
        var w = new ChatsWorking();
        w.Set("otto", "a", true);
        Assert.False(w.Move("otto", null, "b"));
        Assert.False(w.Move("inbox", null, "b"));
        Assert.Equal(["a"], w.Chats("otto").ToList());
        Assert.False(w.Busy("inbox"));
    }

    [Fact]
    public void OtherChatsOfTheBotKeepRunning()
    {
        var w = new ChatsWorking();
        w.Set("otto", "a", true);
        w.Set("otto", null, true);
        Assert.True(w.Move("otto", null, "b"));
        w.Set("otto", "b", false);
        Assert.Equal(["a"], w.Chats("otto").ToList());
    }

    // MARK: AppModel's hooks (TurnRows)

    private static RpcEvent Ev(string type, string runtime, JsonObject? payload = null) => new(type, runtime, payload ?? [], null);

    [Fact]
    public void OurSendMarksBothRowsAtOnce()
    {
        var rows = new TurnRows();
        var change = rows.Running("ivy", "s1", "r1", running: true, external: false);
        Assert.Equal(["ivy"], change.Profiles);
        Assert.Empty(change.Ended);
        Assert.True(rows.Working.Busy("ivy"));                 // the bot row
        Assert.Equal(["s1"], rows.Working.StoredIds.ToList()); // the Sessions row
        Assert.True(rows.Tracks("r1"));
        // Its end (heard by the open chat): both clear, and the gateway's stale "working" goes too.
        change = rows.Running("ivy", "s1", "r1", running: false, external: false);
        Assert.Equal(["ivy"], change.Profiles);
        Assert.Equal(["s1"], change.Ended);
        Assert.False(rows.Working.Busy("ivy"));
        Assert.False(rows.Tracks("r1"));
    }

    [Fact]
    public void AnEndWhileAnotherProcessRunsKeepsTheRowsOnAndTheGatewaysWord()
    {
        var rows = new TurnRows();
        rows.Running("ivy", "s1", "r1", true, false);
        var change = rows.Running("ivy", "s1", "r1", running: false, external: true);
        Assert.True(rows.Working.Busy("ivy"));
        Assert.Empty(change.Ended);                           // `!running, !chat.externalWorking` only
        rows.External("ivy", "s1", working: false, ownRunning: false);
        Assert.False(rows.Working.Busy("ivy"));
    }

    [Fact]
    public void TheMarkMovesToTheStoredId()
    {
        var rows = new TurnRows();
        rows.Running("ivy", "s-old", "r1", true, false);
        var change = rows.Resolved("ivy", "r1", "s-old", "s-new");
        Assert.Equal(["ivy"], change.Profiles);
        Assert.Equal(["s-new"], rows.Working.StoredIds.ToList());
        // Its end, said under the new id, clears it; and an off-screen end names the new id too.
        rows.Closed("ivy", "s-new", "r1", running: true);
        change = rows.Event(Ev("message.complete", "r1"), onScreen: false);
        Assert.Equal(["s-new"], change.Ended);
        Assert.False(rows.Working.Busy("ivy"));
        // Nothing running under the old id: nothing moves.
        Assert.Empty(rows.Resolved("ivy", "r2", "nope", "s-x").Profiles);
    }

    [Fact]
    public void ClosingTheChatWhileItRunsKeepsTheMarkUntilTheTurnEnds()
    {
        var rows = new TurnRows();
        rows.Running("ivy", "s1", "r1", true, false);
        var change = rows.Closed("ivy", "s1", "r1", running: true);
        Assert.Empty(change.Profiles);
        Assert.True(rows.Working.Busy("ivy"));
        Assert.Equal(["s1"], rows.Working.StoredIds.ToList());
        // Its steps go on: still working.
        Assert.Empty(rows.Event(Ev("message.delta", "r1"), onScreen: false).Profiles);
        Assert.Empty(rows.Event(Ev("session.info", "r1", new JsonObject { ["running"] = true }), onScreen: false).Profiles);
        // Another chat's end changes nothing.
        Assert.Empty(rows.Event(Ev("message.complete", "r9"), onScreen: false).Profiles);
        Assert.True(rows.Working.Busy("ivy"));
        change = rows.Event(Ev("message.complete", "r1"), onScreen: false);
        Assert.Equal(["ivy"], change.Profiles);
        Assert.Equal(["s1"], change.Ended);
        Assert.False(rows.Working.Busy("ivy"));
        Assert.Empty(rows.Working.StoredIds);
    }

    /// The Mac's account teardown (93f984bb1 App/AppModel.swift `turnWorking = TurnWorking()`, `runningChats = [:]`):
    /// a turn kept off screen on the old gateway leaves no mark for the next account's bot of the same name, and its
    /// end, should it ever come, changes nothing (CI 45141338140, shots 218-222).
    [Fact]
    public void TheAccountGoingTakesItsMarksWithIt()
    {
        var rows = new TurnRows();
        rows.Running("hermes", "s-old", "r-old", true, false);
        rows.Closed("hermes", "s-old", "r-old", running: true);
        rows.Running("ivy", "s2", "r2", true, false);
        var changes = new List<TurnRowsChange>();
        rows.Changed += changes.Add;
        var change = rows.Reset();
        Assert.Equal(["hermes", "ivy"], change.Profiles.Order().ToList());
        Assert.Empty(change.Ended);
        Assert.Single(changes);
        Assert.False(rows.Working.Busy("hermes"));
        Assert.Empty(rows.Working.StoredIds);
        Assert.False(rows.Tracks("r-old"));
        Assert.Empty(rows.Event(Ev("message.complete", "r-old"), onScreen: false).Profiles);
        // The next account's send marks its own chat alone.
        rows.Running("hermes", "s-new", "r-new", true, false);
        Assert.Equal(["s-new"], rows.Working.Chats("hermes").ToList());
        // Nothing to drop: no change.
        rows.Running("hermes", "s-new", "r-new", false, false);
        Assert.True(rows.Reset().IsEmpty);
    }

    [Fact]
    public void TheAppResetsTheMarksWhenItMovesToAnotherGateway()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        var source = File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Features", "Bots", "ChatRowsWorking.cs")).ReplaceLineEndings("\n");
        // [WIN-OFFSCREEN-END-REST] The app moves its socket through TurnRows.UseSocket (which unlistens the old one and
        // resets), when a chat opens and at the moment the client changes (a sign-out, another gateway).
        Assert.Matches(@"Rows\.UseSocket\(client\.Rpc\)", source);
        Assert.Matches(@"AppState\.ClientChanged \+= client => Rows\.UseSocket\(client\?\.Rpc\);", source);
        var core = File.ReadAllText(Path.Combine(dir, "src", "Hermes.Core", "Chat", "TurnRows.cs")).ReplaceLineEndings("\n");
        Assert.Matches(@"Unlisten\(was\);\s*c = Reset\(\);", core);
    }

    [Theory]
    [InlineData("error", null)]
    [InlineData("session.info", false)]
    public void AnOffScreenTurnEndsOnAnErrorOrTheGatewaySayingIdle(string type, bool? running)
    {
        var rows = new TurnRows();
        rows.Running("wren", "s2", "r2", true, false);
        rows.Closed("wren", "s2", "r2", running: true);
        var payload = running is { } r ? new JsonObject { ["running"] = r } : null;
        Assert.Equal(["s2"], rows.Event(Ev(type, "r2", payload), onScreen: false).Ended);
        Assert.False(rows.Working.Busy("wren"));
    }

    [Fact]
    public void TheOpenChatReportsItself()
    {
        var rows = new TurnRows();
        rows.Running("ivy", "s1", "r1", true, false);
        Assert.Empty(rows.Event(Ev("message.complete", "r1"), onScreen: true).Profiles);
        Assert.True(rows.Working.Busy("ivy"));
    }

    [Fact]
    public void ClosingAnIdleChatOrOneWithNoRuntimeClearsItsMark()
    {
        var rows = new TurnRows();
        rows.External("juno", "s3", working: true, ownRunning: false);   // another process's turn: the screen's watch
        Assert.True(rows.Working.Busy("juno"));
        Assert.Equal(["juno"], rows.Closed("juno", "s3", "r3", running: false).Profiles);
        Assert.False(rows.Working.Busy("juno"));
        // A turn of ours with no runtime id to hear its end by: nothing could clear it later.
        rows.Running("juno", "s4", null, true, false);
        Assert.True(rows.Working.Busy("juno"));
        rows.Closed("juno", "s4", null, running: true);
        Assert.False(rows.Working.Busy("juno"));
    }

    [Fact]
    public void ARebindMovesTheTurnToItsNewRuntimeId()
    {
        var rows = new TurnRows();
        rows.Running("ivy", "s1", "r1", true, false);
        rows.Bound("ivy", "s1", "r1", "r2", running: true);
        Assert.False(rows.Tracks("r1"));
        Assert.True(rows.Tracks("r2"));
        rows.Closed("ivy", "s1", "r2", running: true);
        Assert.Empty(rows.Event(Ev("message.complete", "r1"), onScreen: false).Profiles);
        Assert.Equal(["s1"], rows.Event(Ev("message.complete", "r2"), onScreen: false).Ended);
        // A chat reopened mid-turn runs under its new runtime: the old entry of the same chat goes.
        rows.Running("ivy", "s1", "r5", true, false);
        rows.Running("ivy", "s1", "r6", true, false);
        Assert.False(rows.Tracks("r5"));
        Assert.True(rows.Tracks("r6"));
        // A not-running chat's rebind tracks nothing.
        rows.Bound("wren", "s2", null, "r7", running: false);
        Assert.False(rows.Tracks("r7"));
    }

    [Fact]
    public void AReconnectDropsTheTurnsNoChatHears()
    {
        var rows = new TurnRows();
        rows.Running("ivy", "s1", "r1", true, false);
        rows.Closed("ivy", "s1", "r1", true);
        rows.Running("wren", "s2", "r2", true, false);   // still on screen
        var change = rows.Reconnected(heard: new HashSet<string> { "r2" });
        Assert.Equal(["ivy"], change.Profiles);
        Assert.Empty(change.Ended);                    // the gateway's registry says whether it still runs
        Assert.False(rows.Working.Busy("ivy"));
        Assert.True(rows.Working.Busy("wren"));
    }

    [Fact]
    public void TheRowsTakeTheChange()
    {
        var bots = new BotStore(new FakeGateway(), new MemoryDeviceStore());
        bots.ApplyFull(Fixture.Load("demo-profiles-list.json") is var j && j["result"] is { } r ? r : j, DateTimeOffset.UtcNow);
        var sessions = new SessionStore(new FakeGateway(), new MemoryDeviceStore());
        sessions.Live.Apply(new Dictionary<string, string> { ["s1"] = "working" });
        bots.SetLive(sessions.Live.Working, sessions.Live.Waiting);
        var rows = new TurnRows();
        rows.ApplyTo(rows.Running("inbox", "s1", "r1", true, false), bots, sessions);
        Assert.True(bots.Bot("inbox")!.IsWorking);
        rows.ApplyTo(rows.Running("inbox", "s1", "r1", false, false), bots, sessions);
        Assert.DoesNotContain("s1", sessions.Live.Working);   // the gateway's stale word went with the end
        Assert.False(bots.Bot("inbox")!.IsWorking);
    }

    // MARK: AttentionTests.swift (LiveStatusWatch.turnEnded)

    [Fact]
    public void ATurnThisAppSawEndIsNotBroughtBackByAnOlderRead()
    {
        var live = new LiveStatus();
        live.Apply(new Dictionary<string, string> { ["a"] = "working" });
        var asked = DateTimeOffset.UtcNow;
        Assert.True(live.TurnEnded("a"));
        Assert.Empty(live.Working);
        Assert.False(live.TurnEnded("a"));
        live.Apply(new Dictionary<string, string> { ["a"] = "working" }, started: asked.AddSeconds(-1));
        Assert.Empty(live.Working);
        live.Apply(new Dictionary<string, string> { ["a"] = "working" }, started: DateTimeOffset.UtcNow.AddMilliseconds(1));
        Assert.Equal(["a"], live.Working.ToList());   // a read asked after the end is believed: a new turn
    }

    // MARK: ChatRow.swift oneLineRow externalTail

    private static ChatMessage Steps(bool streaming) => new("m1", Role.Assistant,
        [new ToolPart(new ToolCall("c1", "terminal", null, null, ToolState.Done, ArgsJson: """{"command":"npm test"}"""))],
        DateTimeOffset.Now, 2, IsStreaming: streaming);

    [Fact]
    public void TheExternalTailsLineSaysItsLatestStep()
    {
        var line = ReplyLayout.Build(Steps(false), new ReplyContext { Style = ToolCallStyle.Line, Working = true, ExternalTail = true })
            .OfType<StepsRow>().Single();
        Assert.True(line.Live);
        Assert.Equal("Running npm test", line.Title);
        // Not the tail (or the other turn ended): what it did.
        var settled = ReplyLayout.Build(Steps(false), new ReplyContext { Style = ToolCallStyle.Line })
            .OfType<StepsRow>().Single();
        Assert.False(settled.Live);
        Assert.NotEqual("Running npm test", settled.Title);
    }

    [Fact]
    public void TheTranscriptHandsTheExternalTailToTheLastRowOnly()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        var source = File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "ViewModels", "ChatViewModel.cs")).ReplaceLineEndings("\n");
        Assert.Contains("ExternalTail = turn.ExternalTail(i, messages.Count),", source);
    }
}
