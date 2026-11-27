// [WIN-OWN-TURN-ROWS] Our own turn on the Bots/Sessions rows over the real wire (the loopback stand-in), as the Mac's
// AppModel at 93f984bb1 (`onRunningChange`, `onStoredIdResolved`, `gatewayEvent` → `offScreenTurnEnded`): the send marks
// both rows at once, the mark moves with the stored id the resume names, and a chat closed mid-turn keeps it until the
// turn's end arrives on the socket. The pure hooks are in ../OwnTurnRowsTests.cs. Synthetic data only.

using System.Text.Json.Nodes;
using Hermes.Core.Chat;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    [Fact]
    public async Task OurSendMarksTheRowsAndAClosedChatKeepsThemUntilItsTurnEnds()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        var rows = new TurnRows();
        rows.Listen(rig.Client.Rpc);
        var running = new List<bool>();
        rig.Chat.RunningChanged += r => { lock (running) running.Add(r); };
        var screen = rows.Follow(rig.Chat);
        Assert.False(rows.Working.Busy("ivy"));

        await rig.Chat.SendAsync("Check the synthetic brief.");
        Assert.True(rows.Working.Busy("ivy"));                         // at once: the send's own bubble said so
        Assert.Equal([Stored], rows.Working.StoredIds.ToList());
        lock (running) Assert.Equal([true], running);

        // The chat leaves the screen mid-turn: the rows stay on.
        screen.Dispose();
        await rig.Chat.DisposeAsync();
        Assert.True(rows.Working.Busy("ivy"));
        await rig.Socket.Emit("message.delta", new JsonObject { ["text"] = "Still at it" });
        await Task.Delay(100);
        Assert.True(rows.Working.Busy("ivy"));

        // Its end, heard off screen: they clear, and its stored id is named for the gateway's stale word.
        var ended = new List<string>();
        rows.Changed += c => { lock (ended) ended.AddRange(c.Ended); };
        await rig.Socket.Emit("message.complete", new JsonObject { ["text"] = "Done." });
        // Changed is raised on the socket's thread just after the mark clears: wait for both.
        Assert.True(await Until(() => { lock (ended) return !rows.Working.Busy("ivy") && ended.Count > 0; }));
        Assert.Empty(rows.Working.StoredIds);
        lock (ended) Assert.Equal([Stored], ended);
        rows.Unlisten(rig.Client.Rpc);
    }

    [Fact]
    public async Task TheOpenChatsTurnEndClearsTheRowsAndTheMarkMovesWithTheResolvedId()
    {
        const string resolved = "20260929_120000_aabbcc09";
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, parameters, attempt) => method == "session.resume"
            ? new JsonObject { ["session_id"] = VoiceFakeClient.Rid, ["session_key"] = resolved }
            : Loopback.Default(method, parameters, attempt));
        var rows = new TurnRows();
        rows.Listen(rig.Client.Rpc);
        var moved = new List<(string From, string To)>();
        rig.Chat.StoredIdResolved += (from, to) => { lock (moved) moved.Add((from, to)); };
        using var screen = rows.Follow(rig.Chat);

        // A send before the resume answered: the mark starts under the id the chat opened with and moves.
        await rig.Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        await rig.Chat.SendAsync("Summarize the synthetic notes.");
        lock (moved) Assert.Equal([(Stored, resolved)], moved);
        Assert.Equal([resolved], rows.Working.StoredIds.ToList());
        Assert.True(rows.Tracks(VoiceFakeClient.Rid));

        await rig.Socket.Emit("message.complete", new JsonObject { ["text"] = "Done." });
        Assert.True(await Until(() => !rows.Working.Busy("ivy")));
        rows.Unlisten(rig.Client.Rpc);
    }
}
