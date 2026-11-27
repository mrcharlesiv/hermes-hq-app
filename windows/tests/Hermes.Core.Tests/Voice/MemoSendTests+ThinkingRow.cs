// [WIN-THINKING-STEP] The chat's thinking row over the real wire (the loopback stand-in), as the Mac's ActivityEndToEnd
// test19d_ThinkingRowNamesTheRunningStep at 93f984bb1: while a step runs the row reads "Ivy is running npm test…", it
// keeps naming it while the bot thinks after it, and it goes once the reply writes. The chat page draws exactly
// ThinkingRow.Build over the session's messages (Features/Transcript/ThinkingRowView). The pure rules are in
// ../ThinkingRowTests.cs. Synthetic data only.

using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    [Fact]
    public async Task TheThinkingRowNamesTheRunningStepFromTheSocketsFrames()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        string? Row()
        {
            var chat = rig.Chat;
            var turn = ExternalSurfaces.Transcript(chat.Busy, chat.ExternalWorking, chat.WaitingForOwner != null);
            return ThinkingRow.Build(new ThinkingRow.Input(chat.Messages, turn.Running, "Ivy"))?.Label;
        }

        await rig.Chat.SendAsync("Run the tests.");
        Assert.True(await Until(() => Row() == "Ivy is thinking…"));

        var args = new JsonObject { ["command"] = "cd /Users/me/app && npm test -- --watch=false" };
        await rig.Socket.Emit("tool.start", new JsonObject { ["name"] = "terminal", ["tool_id"] = "call_t1", ["args"] = args.DeepClone() });
        Assert.True(await Until(() => Row() == "Ivy is running npm test -- --watch=false…"), Row());
        await rig.Socket.Emit("tool.complete", new JsonObject
        {
            ["name"] = "terminal", ["tool_id"] = "call_t1", ["args"] = args.DeepClone(),
            ["result"] = new JsonObject { ["output"] = "42 passing", ["exit_code"] = 0 },
        });
        Assert.True(await Until(() => rig.Chat.Messages[^1].Tools.All(t => t.State != Model.ToolState.Running)));
        Assert.Equal("Ivy is running npm test -- --watch=false…", Row());   // the finished step stays named

        await rig.Socket.Emit("message.delta", new JsonObject { ["text"] = "All 42 tests pass." });
        Assert.True(await Until(() => Row() == null), Row());
    }
}
