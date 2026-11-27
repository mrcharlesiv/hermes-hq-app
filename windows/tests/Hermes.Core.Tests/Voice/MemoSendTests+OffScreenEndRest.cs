// [WIN-OFFSCREEN-END-REST] The rest of the Mac's off-screen turn end over the real wire (the loopback stand-in), as the
// Mac's AppModel at 93f984bb1 (`gatewayEvent` → `noteTurnOutcome`, `offScreenTurnEnded`, `tearDown`): a chat closed
// mid-turn whose turn ends on an error frame gives its bot row the standing problem's orange words and ends both rows'
// Working…; the step the turn was on leaves the bot row with its end; a sign-out resets the marks at that moment and the
// old socket's frames are no longer heard. The pure rules are in ../OffScreenEndRestTests.cs. Synthetic data only.

using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Chat;
using Hermes.Core.Rpc;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    private static (BotStore Bots, SessionStore Sessions) EndRestLists()
    {
        var bots = new BotStore(new FakeGateway(), new MemoryDeviceStore());
        bots.ApplyFull(new JsonObject
        {
            ["profiles"] = new JsonArray
            {
                new JsonObject
                {
                    ["name"] = "ivy",
                    ["canonical_session"] = new JsonObject
                    {
                        ["id"] = Stored, ["title"] = "Bot Chat", ["preview"] = "old words", ["last_active"] = 1_791_000_000.0, ["message_count"] = 4.0,
                    },
                },
            },
        }, DateTimeOffset.UtcNow);
        var sessions = new SessionStore(new FakeGateway(), new MemoryDeviceStore());
        sessions.Apply(SidebarPayload.Decode(JsonNode.Parse($$$"""
            {"recents":{"sessions":[{"id":"{{{Stored}}}","profile":"ivy","title":"Synthetic brief","preview":"Check the synthetic brief.",
              "last_active":1791000000,"message_count":4,"source":"desktop"}]},"cron":{"sessions":[]},"messaging":{"sessions":[]}}
            """)));
        return (bots, sessions);
    }

    [Fact]
    public async Task AChatClosedMidTurnThatEndsInAnErrorShowsItsBotsStandingProblem()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        var (bots, sessions) = EndRestLists();
        var rows = new TurnRows();
        // The app applies each change on the UI thread (Features/Bots/ChatRowsWorking); here, where it is raised.
        rows.Changed += change => rows.ApplyTo(change, bots, sessions);
        rows.UseSocket(rig.Client.Rpc);
        var screen = rows.Follow(rig.Chat);

        await rig.Chat.SendAsync("Check the synthetic brief.");
        Assert.True(bots.Bot("ivy")!.IsWorking);
        bots.SetStep("ivy", "Reading package.json…");
        Assert.Equal("Reading package.json…", BotList.SecondLine(bots.Bot("ivy")!).Text);

        screen.Dispose();
        await rig.Chat.DisposeAsync();
        Assert.True(bots.Bot("ivy")!.IsWorking);

        // Its end, an error frame heard off screen: the bot row's orange words, and both rows' Working… ends.
        await rig.Socket.Emit("error", new JsonObject { ["message"] = "HTTP 401 Unauthorized" });
        Assert.True(await Until(() => bots.Bot("ivy") is { IsWorking: false, Attention: not null, Step: null }
            && !sessions.LiveSummaries().Single().IsRunning));
        var ivy = bots.Bot("ivy")!;
        Assert.Equal("Sign in again for this bot", BotList.SecondLine(ivy).Text);
        Assert.Equal(BotList.Tone.Attention, BotList.SecondLine(ivy).Tone);
        Assert.Null(ivy.Step);                                          // the step it was on went with it
        Assert.False(ivy.Unread);                                       // no reply: no dot
        Assert.Equal("old words", ivy.Preview.Text);
        Assert.Equal("Check the synthetic brief.", sessions.LiveSummaries().Single().Preview);
        Assert.False(rows.Tracks(rig.Chat.RuntimeId ?? ""));
        rows.UseSocket(null);
    }

    [Fact]
    public async Task TheBotRowsStepEndsWithTheOffScreenTurn()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        var (bots, sessions) = EndRestLists();
        var rows = new TurnRows();
        rows.Changed += change => rows.ApplyTo(change, bots, sessions);
        rows.UseSocket(rig.Client.Rpc);
        var screen = rows.Follow(rig.Chat);

        await rig.Chat.SendAsync("Check the synthetic brief.");
        bots.SetStep("ivy", "Running npm test…");
        screen.Dispose();
        await rig.Chat.DisposeAsync();
        Assert.Equal("Running npm test…", BotList.SecondLine(bots.Bot("ivy")!).Text);

        await rig.Socket.Emit("message.complete", new JsonObject { ["text"] = "The synthetic brief is fine." });
        Assert.True(await Until(() => bots.Bot("ivy") is { IsWorking: false, Step: null, Unread: true }));
        Assert.Equal("The synthetic brief is fine.", BotList.SecondLine(bots.Bot("ivy")!).Text);
        Assert.Null(bots.Bot("ivy")!.Attention);
        rows.UseSocket(null);
    }

    /// The account's teardown at the moment it happens (the Mac's `tearDown`: `turnWorking = TurnWorking()`,
    /// `runningChats = [:]`), not when the next chat opens: the marks go, the old socket's frames are no longer heard,
    /// and the chat that was on screen leaving afterwards brings none back.
    [Fact]
    public async Task ASignOutResetsTheMarksAtOnceAndHearsTheOldSocketNoMore()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        var (bots, sessions) = EndRestLists();
        var rows = new TurnRows();
        rows.Changed += change => rows.ApplyTo(change, bots, sessions);
        Assert.True(rows.UseSocket(rig.Client.Rpc).IsEmpty);           // the first socket resets nothing
        Assert.True(rows.UseSocket(rig.Client.Rpc).IsEmpty);           // nor the same one again
        var screen = rows.Follow(rig.Chat);

        await rig.Chat.SendAsync("Check the synthetic brief.");
        Assert.True(bots.Bot("ivy")!.IsWorking);
        Assert.True(sessions.LiveSummaries().Single().IsRunning);
        var runtime = rig.Chat.RuntimeId!;

        // Signed out with the chat still on screen, mid-turn.
        var reset = rows.UseSocket(null);
        Assert.Equal(["ivy"], reset.Profiles);
        Assert.False(bots.Bot("ivy")!.IsWorking);
        Assert.False(sessions.LiveSummaries().Single().IsRunning);

        // Its page goes after: no mark comes back for the old account's turn.
        screen.Dispose();
        Assert.False(rows.Tracks(runtime));
        Assert.False(bots.Bot("ivy")!.IsWorking);
        Assert.False(sessions.LiveSummaries().Single().IsRunning);

        // The old socket's end of that turn is no longer heard: no reply, no dot, no problem.
        var heard = 0;
        void Count(RpcEvent e) { if (e.Type == "error") Interlocked.Increment(ref heard); }
        rig.Client.Rpc.Event += Count;
        await rig.Socket.Emit("error", new JsonObject { ["message"] = "HTTP 401 Unauthorized" });
        Assert.True(await Until(() => Volatile.Read(ref heard) == 1));
        rig.Client.Rpc.Event -= Count;
        var ivy = bots.Bot("ivy")!;
        Assert.Null(ivy.Attention);
        Assert.False(ivy.Unread);
        Assert.Equal("old words", ivy.Preview.Text);
    }
}
