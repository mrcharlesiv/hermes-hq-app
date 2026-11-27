// [WIN-EXTERNAL-SURFACES] Another Hermes process's turn on the Bots/Sessions rows and the transcript's live step line, as
// the Mac at 93f984bb1: App/AppModel.swift `onRunningChange`/`onExternalWorkChange` (setWorking(running ||
// chat.externalWorking), and working || chat.reportsRunning), App/Chat/ChatViewController.swift (isRunning:
// (session.isRunning || externalWorking) && !ownerWaiting; input.externalWorking = externalWorking && !ownerWaiting),
// App/Chat/ChatRow.swift `oneLineRow` (externalTail: the last row only) and App/Chat/ProgressNotes.swift `working(at:)`.
// The Mac has no unit test of these rules (its Tests cover the watch itself, ported in ExternalTurnTests); these state
// them from the Swift.
using Hermes.Core.Bots;
using Hermes.Core.Chat;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests;

public class ExternalSurfacesTests
{
    [Theory]
    [InlineData(false, false, false, false)]
    [InlineData(true, false, false, true)]
    [InlineData(false, true, false, true)]    // another process's turn reads as running
    [InlineData(true, true, false, true)]
    [InlineData(true, false, true, false)]    // a send waiting for the owner hasn't reached the model
    [InlineData(false, true, true, false)]
    [InlineData(true, true, true, false)]
    public void TheTranscriptRunsForTheOtherTurnUnlessTheOwnerWaitShows(bool running, bool external, bool ownerWaiting, bool expected)
    {
        var turn = ExternalSurfaces.Transcript(running, external, ownerWaiting);
        Assert.Equal(expected, turn.Running);
        Assert.Equal(external && !ownerWaiting, turn.External);
    }

    [Fact]
    public void TheExternalTailIsTheLastRowOnly()
    {
        var turn = ExternalSurfaces.Transcript(running: false, external: true, ownerWaiting: false);
        Assert.True(turn.ExternalTail(index: 3, count: 4));
        Assert.False(turn.ExternalTail(index: 2, count: 4));
        Assert.False(turn.ExternalTail(index: 0, count: 0));
        Assert.False(ExternalSurfaces.Transcript(false, false, false).ExternalTail(3, 4));
        Assert.False(ExternalSurfaces.Transcript(false, true, ownerWaiting: true).ExternalTail(3, 4));
    }

    [Fact]
    public void ARowWorksWhileItStreamsOrTheTurnRunsOrItIsTheExternalTail()
    {
        // Rows: 0 user, 1 assistant, 2 user, 3 assistant (the other process's reply in progress, not streaming here).
        var external = ExternalSurfaces.Transcript(running: false, external: true, ownerWaiting: false);
        Assert.True(external.Working(streaming: false, index: 3, count: 4, lastUser: 2, lastAssistant: 3));
        Assert.False(external.Working(streaming: false, index: 1, count: 4, lastUser: 2, lastAssistant: 3));
        // The other turn's last row is a tool or a note row, not an assistant: the tail still carries the live line.
        Assert.True(external.Working(streaming: false, index: 4, count: 5, lastUser: 2, lastAssistant: 3));
        // Ours: the newest reply after the last prompt, as before.
        var ours = ExternalSurfaces.Transcript(running: true, external: false, ownerWaiting: false);
        Assert.True(ours.Working(false, 3, 4, 2, 3));
        Assert.False(ours.Working(false, 1, 4, 2, 3));
        Assert.True(ours.Working(streaming: true, index: 1, count: 4, lastUser: 2, lastAssistant: 3));
        // The owner wait: nothing works but a row that streams.
        var waiting = ExternalSurfaces.Transcript(running: true, external: true, ownerWaiting: true);
        Assert.False(waiting.Working(false, 3, 4, 2, 3));
        Assert.True(waiting.Working(true, 3, 4, 2, 3));
        // Idle.
        Assert.False(ExternalSurfaces.Transcript(false, false, false).Working(false, 3, 4, 2, 3));
    }

    [Theory]
    [InlineData(false, false, false)]
    [InlineData(true, false, true)]
    [InlineData(false, true, true)]
    [InlineData(true, true, true)]
    public void TheRowsWorkWhileEitherTurnRuns(bool running, bool external, bool expected) =>
        Assert.Equal(expected, ExternalSurfaces.RowsWorking(running, external));

    [Fact]
    public void WorkingChatsCountByProfileAndStoredId()
    {
        var chats = new ChatsWorking();
        Assert.True(chats.Set("ivy", "s1", true));
        Assert.False(chats.Set("ivy", "s1", true));          // no change
        Assert.True(chats.Set("ivy", null, true));           // a chat with no stored id yet counts for its bot
        Assert.True(chats.Busy("ivy"));
        Assert.Equal(["s1"], chats.StoredIds.ToList());       // only stored ids reach the Sessions rows
        Assert.True(chats.Set("ivy", "s1", false));
        Assert.True(chats.Busy("ivy"));
        Assert.True(chats.Set("ivy", null, false));
        Assert.False(chats.Busy("ivy"));
        Assert.Empty(chats.StoredIds);
        Assert.False(chats.Set("wren", "s2", false));         // clearing what was never set changes nothing
    }

    [Fact]
    public void AWorkingChatMarksItsBotRowWorking()
    {
        var store = new BotStore(new FakeGateway(), new MemoryDeviceStore());
        store.ApplyFull(Fixture.Load("demo-profiles-list.json") is var j && j["result"] is { } r ? r : j, DateTimeOffset.UtcNow);
        Assert.False(store.Bot("inbox")!.IsWorking);
        store.SetWorkingChats("inbox", new HashSet<string> { "not-canonical" });   // any chat of the bot, not just its own
        Assert.True(store.Bot("inbox")!.IsWorking);
        Assert.Equal("Working…", BotList.SecondLine(store.Bot("inbox")!).Text);
        store.SetWorkingChats("inbox", new HashSet<string>());
        Assert.False(store.Bot("inbox")!.IsWorking);
    }

    [Fact]
    public async Task AWorkingChatMarksItsSessionsRowWorking()
    {
        var gw = new FakeGateway();
        gw.OnRest = (m, p, _, _) => (m, p) switch
        {
            ("GET", "/api/profiles/sessions/sidebar") => new RestAnswer(200, """{"recents":{"sessions":[{"id":"u1","profile":"ivy","title":"T","message_count":3,"last_active":5}]},"cron":{"sessions":[]},"messaging":{"sessions":[]}}"""),
            ("GET", _) => new RestAnswer(404, ""),
            _ => new RestAnswer(200, "{}"),
        };
        var store = new SessionStore(gw, new MemoryDeviceStore());
        await store.RefreshAsync();
        Assert.Equal(SessionStatus.Idle, store.LiveSummaries()[0].Status);
        var raised = 0;
        store.Changed += () => raised++;
        store.SetRunning(new HashSet<string> { "u1" });
        Assert.Equal(1, raised);
        Assert.True(store.LiveSummaries()[0].IsRunning);
        Assert.Equal(SessionStatus.Working, store.LiveSummaries()[0].Status);
        store.SetRunning(new HashSet<string> { "u1" });       // the same set: no redraw
        Assert.Equal(1, raised);
        store.SetRunning(new HashSet<string>());
        Assert.Equal(SessionStatus.Idle, store.LiveSummaries()[0].Status);
    }
}
