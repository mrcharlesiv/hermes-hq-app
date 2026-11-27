// [WIN-OFFSCREEN-TURN-END] A chat closed mid-turn gets the Mac's off-screen end over the real wire (the loopback
// stand-in), as the Mac's AppModel at 93f984bb1 (`gatewayEvent` → `offScreenTurnEnded`): when message.complete arrives
// on the client's socket, the bot row shows the reply with its unread dot and the Sessions row shows it as the chat's
// newest message. The pure rules are in ../OffScreenTurnEndTests.cs. Synthetic data only.

using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Chat;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    [Fact]
    public async Task AChatClosedMidTurnGetsItsReplyAndDotWhenTheTurnEnds()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
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
        var rows = new TurnRows();
        // The app applies each change on the UI thread (Features/Bots/ChatRowsWorking); here, where it is raised.
        rows.Changed += change => rows.ApplyTo(change, bots, sessions);
        rows.Listen(rig.Client.Rpc);
        var screen = rows.Follow(rig.Chat);

        await rig.Chat.SendAsync("Check the synthetic brief.");
        Assert.True(bots.Bot("ivy")!.IsWorking);
        Assert.True(sessions.LiveSummaries().Single().IsRunning);

        // The chat leaves the screen mid-turn: the rows stay on, no dot yet.
        screen.Dispose();
        await rig.Chat.DisposeAsync();
        Assert.True(bots.Bot("ivy")!.IsWorking);
        Assert.False(bots.Bot("ivy")!.Unread);

        // Its end, heard off screen: the reply on both rows, and the bot's dot.
        await rig.Socket.Emit("message.complete", new JsonObject { ["text"] = "The synthetic brief is fine." });
        // The change is applied on the socket's thread, the bot row first: wait for both rows.
        Assert.True(await Until(() => bots.Bot("ivy") is { IsWorking: false, Unread: true }
            && sessions.LiveSummaries().Single().Preview == "The synthetic brief is fine."));
        var ivy = bots.Bot("ivy")!;
        Assert.Equal("The synthetic brief is fine.", ivy.Preview.Text);
        var row = sessions.LiveSummaries().Single();
        Assert.False(row.IsRunning);
        Assert.Equal("The synthetic brief is fine.", row.Preview);
        Assert.Equal("Synthetic brief", row.Title);
        rows.Unlisten(rig.Client.Rpc);
    }
}
