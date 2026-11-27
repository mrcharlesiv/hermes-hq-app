// [WIN-OWN-TURN-ROWS] A send of ours that never started a turn leaves no Working… on the rows (CI 45141338140, shots
// 218-222: the bot row said Working… after an unconfirmed and a refused send, with nothing running). On the Mac the
// rows follow `onRunningChange` (93f984bb1 App/AppModel.swift), which reports `reportsRunning` as it stands: a send the
// gateway refused or didn't confirm ends with nothing running. Synthetic data only.

using System.Text.Json.Nodes;
using Hermes.Core.Chat;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    [Fact]
    public async Task AnUnconfirmedSendLeavesNoWorkingMarkOnTheRows()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit"
            ? throw new Refuse(4090, "The gateway did not confirm your message in time.",
                new JsonObject { ["reason"] = "SESSION_OWNER_UNCONFIRMED" })
            : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var rows = new TurnRows();
        using var screen = rows.Follow(rig.Chat);
        Assert.Equal(SendOutcome.Unconfirmed, await rig.Chat.SendAsync("hi").WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.False(rig.Chat.Busy);
        Assert.True(await Until(() => !rows.Working.Busy("ivy")), "the rows still say Working… after an unconfirmed send");
    }

    [Fact]
    public async Task ARefusedSendLeavesNoWorkingMarkOnTheRows()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit"
            ? throw new Refuse(4001, "profile_mismatch", new JsonObject { ["reason"] = "profile_mismatch" })
            : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var rows = new TurnRows();
        using var screen = rows.Follow(rig.Chat);
        await rig.Chat.SendAsync("hi").WaitAsync(TimeSpan.FromSeconds(10));
        Assert.False(rig.Chat.Busy);
        Assert.True(await Until(() => !rows.Working.Busy("ivy")), "the rows still say Working… after a refused send");
    }
}
