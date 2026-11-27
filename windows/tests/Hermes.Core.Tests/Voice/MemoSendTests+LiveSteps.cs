// [WIN-LIVE-STEPS] The rows' live step over the real wire (the loopback stand-in), as the Mac's AppModel at 93f984bb1
// (`gatewayEvent` → `liveSteps.handle(event, roster:)` → `pushSteps`, `offScreenTurnEnded` → `liveSteps.clear`,
// `tearDown` → `liveSteps.reset()`): a tool frame on the client's socket names the step on the bot row and the Sessions
// row of its chat, a side chat's step stays its own, the reply writing or the turn's end takes the step away, and a
// sign-out resets them all. The pure rules are in ../LiveStepsTests.cs. Synthetic data only.

using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Chat;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    [Fact]
    public async Task TheSocketsToolFramesNameEachChatsStepOnItsRows()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        var (bots, sessions) = EndRestLists();
        var rows = new TurnRows { Roster = () => [] };
        // The app applies each change on the UI thread (Features/Bots/ChatRowsWorking); here, where it is raised.
        rows.Changed += change => rows.ApplyTo(change, bots, sessions);
        rows.UseSocket(rig.Client.Rpc);
        var screen = rows.Follow(rig.Chat);
        string? SessionStep() => sessions.LiveSummaries().Single().Step;

        await rig.Chat.SendAsync("Check the synthetic brief.");
        Assert.True(bots.Bot("ivy")!.IsWorking);
        Assert.Equal("Working…", BotList.SecondLine(bots.Bot("ivy")!).Text);

        // The chat on screen runs a step: its bot row and its Sessions row name it.
        await rig.Socket.Emit("tool.start", new JsonObject
        {
            ["name"] = "read_file", ["tool_id"] = "t-1", ["args"] = new JsonObject { ["path"] = "/Users/me/app/package.json" },
        });
        Assert.True(await Until(() => bots.Bot("ivy")!.Step == "Reading package.json…" && SessionStep() == "Reading package.json…"));
        Assert.Equal("Reading package.json…", BotList.SecondLine(bots.Bot("ivy")!).Text);
        Assert.Equal("Reading package.json…", SessionRowWords.DetailText(sessions.LiveSummaries().Single(), new HashSet<SessionRowDetail>()));

        // One of ivy's side chats, closed mid-turn, runs its own step: it never overwrites the Bot Chat's.
        rows.Closed("ivy", "20260929_130000_side01", "r-side", running: true);
        await rig.Socket.EmitAs("r-side", "tool.start", new JsonObject
        {
            ["name"] = "terminal", ["tool_id"] = "t-2", ["args"] = new JsonObject { ["command"] = "cd /Users/me/app && npm test" },
        });
        Assert.True(await Until(() => rows.StepsByRuntime.GetValueOrDefault("r-side") == "running npm test"));
        Assert.Equal("Reading package.json…", bots.Bot("ivy")!.Step);
        Assert.Equal("Reading package.json…", SessionStep());

        // The reply writes: Working… again on both rows; the side chat keeps its step.
        await rig.Socket.Emit("message.delta", new JsonObject { ["text"] = "The brief looks fine." });
        Assert.True(await Until(() => bots.Bot("ivy")!.Step == null && SessionStep() == null));
        Assert.Equal("Working…", BotList.SecondLine(bots.Bot("ivy")!).Text);
        Assert.Equal("running npm test", rows.StepsByRuntime["r-side"]);

        // A next step, then the chat leaves the screen mid-turn: the step stays with the turn until its end.
        await rig.Socket.Emit("tool.start", new JsonObject
        {
            ["name"] = "web_search", ["tool_id"] = "t-3", ["args"] = new JsonObject { ["query"] = "synthetic brief" },
        });
        Assert.True(await Until(() => bots.Bot("ivy")!.Step == "Searching the web for synthetic brief…"));
        screen.Dispose();
        await rig.Chat.DisposeAsync();
        Assert.Equal("Searching the web for synthetic brief…", bots.Bot("ivy")!.Step);
        await rig.Socket.Emit("message.complete", new JsonObject { ["text"] = "The synthetic brief is fine." });
        Assert.True(await Until(() => bots.Bot("ivy") is { Step: null, Unread: true } && SessionStep() == null));
        Assert.False(rows.StepsByRuntime.ContainsKey(VoiceFakeClient.Rid));
        Assert.Equal("running npm test", rows.StepsByRuntime["r-side"]);

        // A sign-out: every step goes at that moment.
        rows.UseSocket(null);
        Assert.Empty(rows.StepsByRuntime);
        Assert.Null(bots.Bot("ivy")!.Step);
        Assert.False(bots.Bot("ivy")!.IsWorking);
    }
}
