// [WIN-PROBLEM-CARD-REST] The problem card around a send with photos and files, stated from the Swift at 93f984bb1 on
// the same loopback stand-in gateway as the refusal cases, synthetic data only:
//   HermesKit/Chat/LiveChatSession+Events.swift `onError` — `let preparing = turn.preparingSendId != nil &&
//     turn.streamId == nil` ("A send still uploading has no turn on the gateway yet: an error now isn't about it"):
//     the error is the problem card (`SessionProblem.make`), not an error row, and the send goes on; once the attaches
//     are done (`endPreparing`) the send is in flight and an error ends it on an error row;
//   HermesKit/Chat/LiveChatSession.swift `resumeNow` — a resume refused `4001 profile_mismatch` is the locked chat's card,
//     and the refused send says it there only (`sendFailure = nil   // one card`).

using System.Text.Json.Nodes;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

public sealed partial class AttachmentRefusalTests
{
    [Fact]
    public async Task AnErrorWhileAttachmentsAreStillAttachingIsTheProblemCardAndTheSendGoesOn()
    {
        await using var rig = new Rig();
        await rig.Ready();
        rig.Socket.HoldCalls("image.attach");
        rig.Center.SetText(rig.Scope, rig.Chat.Profile, "look");
        var (text, taken) = rig.Center.TakeForSend(rig.Scope);
        var sending = rig.Chat.SendAsync(text, taken, rig.Center);
        Assert.True(await Until(() => rig.Socket.Calls("image.attach").Count == 1), "the photo is attaching");

        await rig.Socket.Emit("error", new JsonObject { ["message"] = "Disk is full" });
        Assert.True(await Until(() => rig.Chat.SessionProblem != null), "the problem card");
        Assert.Equal("Ivy reported a problem", rig.Chat.SessionProblem!.Title);
        Assert.Equal(SessionProblemPrimary.TryAgain, rig.Chat.SessionProblem.Primary);
        NoErrorRow(rig.Chat);
        Assert.True(rig.Chat.Busy);                                                        // the send is still going
        Assert.Contains(rig.Chat.Messages, m => m.Id.StartsWith("local-user"));

        rig.Socket.Release();
        await sending.WaitAsync(TimeSpan.FromSeconds(15));
        Assert.Single(rig.Socket.Calls("prompt.submit"));                                   // it went out after all
        Assert.Null(rig.Chat.SendFailure);
        Assert.Empty(rig.Returned);
        NoErrorRow(rig.Chat);
    }

    [Fact]
    public async Task AnErrorAfterTheAttachesAreDoneEndsTheSendOnAnErrorRow()
    {
        await using var rig = new Rig();
        await rig.Ready();
        rig.Center.SetText(rig.Scope, rig.Chat.Profile, "look");
        var (text, taken) = rig.Center.TakeForSend(rig.Scope);
        await rig.Chat.SendAsync(text, taken, rig.Center).WaitAsync(TimeSpan.FromSeconds(15));
        Assert.Single(rig.Socket.Calls("prompt.submit"));
        Assert.True(rig.Chat.Busy);                                                        // in flight: no longer preparing

        await rig.Socket.Emit("error", new JsonObject { ["message"] = "Disk is full" });
        Assert.True(await Until(() => !rig.Chat.Busy && rig.Chat.Messages.Any(m => m.Error == "Disk is full")), "the error row");
        Assert.Null(rig.Chat.SessionProblem);
    }

    [Fact]
    public async Task ASendWithAttachmentsWhoseResumeIsRefusedLockedShowsOnlyTheProblemCard()
    {
        await using var rig = new Rig();
        await rig.Ready();
        rig.Socket.OnCall((method, p, attempt) => method == "session.resume"
            ? throw new Refuse(4001, "profile_mismatch", new JsonObject { ["reason"] = "profile_mismatch" })
            : Loopback.Default(method, p, attempt));
        rig.Chat.ForgetRuntime();
        rig.Center.SetText(rig.Scope, rig.Chat.Profile, "look");
        var (text, taken) = rig.Center.TakeForSend(rig.Scope);
        await rig.Chat.SendAsync(text, taken, rig.Center).WaitAsync(TimeSpan.FromSeconds(15));

        Assert.Equal(SessionProblem.ChatLockedTitle, rig.Chat.SessionProblem?.Title);
        Assert.Equal(SessionProblemPrimary.NewChat, rig.Chat.SessionProblem?.Primary);
        Assert.Null(rig.Chat.SendFailure);                                                  // one card
        Assert.Equal(["profile_mismatch"], rig.Returned);                                   // the draft came back, with why
        Assert.Empty(rig.Socket.Calls("prompt.submit"));
        Assert.Equal(taken.Select(a => a.Id), rig.Center.GetDraft(rig.Scope).Attachments.Select(a => a.Id));
        NoErrorRow(rig.Chat);
        Assert.False(rig.Chat.Busy);
    }
}
