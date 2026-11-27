// [WIN-COMPOSER-CARD-IDS] The chat's problem card beyond the locked chat (ChatSession+Problems.cs), stated from the Swift
// at 93f984bb1 on the same loopback stand-in as the memo cases, synthetic data only:
//   HermesKit/Chat/LiveChatSession+Events.swift — an `error` with no turn in flight: `sessionProblem =
//     SessionProblem.make(text:botName:)` (nothing for the ignored ones), no error card; with a turn in flight it ends
//     the turn on an error card instead;
//   HermesKit/Chat/LiveChatSession.swift — `send`: `sessionProblem = nil`; `resumeNow`: a resume that fails after its
//     quiet retry with a timeout says `SessionProblem.reopenFailed(starting: true)` (`noteResumeFailed`), one that lands
//     clears a reopen problem; `retryAfterProblem`: the card goes, a reopen problem resumes once more.
// The Mac has no unit test of these paths (LiveChatSessionTests reads `sessionProblem` only for the locked chat).

using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    [Fact]
    public async Task AnErrorWithNoTurnInFlightIsTheProblemCardWithChooseAModel()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        await rig.Socket.Emit("error", new JsonObject { ["message"] = "could not start the assistant" });
        Assert.True(await Until(() => rig.Chat.SessionProblem != null));
        var problem = rig.Chat.SessionProblem!;
        Assert.Equal("This chat’s model couldn’t start", problem.Title);
        Assert.Equal(SessionProblemPrimary.ChooseModel, problem.Primary);
        Assert.Equal("Choose a Model", ComposerNotices.ActionTitle(problem.Primary));
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Role == Role.System);   // a card, not an error row
        Assert.False(rig.Chat.Busy);
    }

    [Fact]
    public async Task AnUnknownChatErrorNamesTheBotAndOffersTryAgain()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        await rig.Socket.Emit("error", new JsonObject { ["message"] = "Disk is full" });
        Assert.True(await Until(() => rig.Chat.SessionProblem != null));
        Assert.Equal("Ivy reported a problem", rig.Chat.SessionProblem!.Title);
        Assert.Equal("Disk is full", rig.Chat.SessionProblem.Body);
        Assert.Equal(SessionProblemPrimary.TryAgain, rig.Chat.SessionProblem.Primary);
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Role == Role.System);
    }

    [Fact]
    public async Task TheIgnoredChatErrorsRaiseNothing()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        await rig.Socket.Emit("error", new JsonObject { ["message"] = "Turn cancelled before the agent was ready" });
        await rig.Socket.Emit("error", new JsonObject { ["message"] = "Session no longer running before the agent was ready to go" });
        await rig.Socket.Emit("error", new JsonObject { ["message"] = "Disk is full" });   // the marker that the two went first
        Assert.True(await Until(() => rig.Chat.SessionProblem != null));
        Assert.Equal("Disk is full", rig.Chat.SessionProblem!.Detail);
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Role == Role.System);
    }

    [Fact]
    public async Task AnErrorDuringATurnEndsItOnAnErrorRowNotTheCard()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        Assert.Equal(SendOutcome.Accepted, await rig.Chat.SendAsync("What is the plan for the synthetic project?"));
        await rig.Socket.Emit("message.start", new JsonObject());
        await rig.Socket.Emit("error", new JsonObject { ["message"] = "Disk is full" });
        Assert.True(await Until(() => !rig.Chat.Busy && rig.Chat.Messages.Any(m => m.Error == "Disk is full")));
        Assert.Null(rig.Chat.SessionProblem);
    }

    [Fact]
    public async Task AFreshSendAnswersTheProblemCard()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        await rig.Socket.Emit("error", new JsonObject { ["message"] = "Disk is full" });
        Assert.True(await Until(() => rig.Chat.SessionProblem != null));
        Assert.Equal(SendOutcome.Accepted, await rig.Chat.SendAsync("Try once more"));
        Assert.Null(rig.Chat.SessionProblem);
    }

    [Fact]
    public async Task AResumeThatNeverAnswersSaysCouldntReopenAndTryAgainResumesOnceMore()
    {
        await using var rig = new Rig(_stores);
        rig.Chat.ResumeTimeout = TimeSpan.FromMilliseconds(150);
        rig.Socket.Delay("session.resume", TimeSpan.FromSeconds(2));
        await rig.Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        await Assert.ThrowsAsync<GatewayException>(() => rig.Chat.EnsureRuntimeAsync());
        // One quiet retry, then the card (the connect's own re-bind may have run its two first, behind the same gate).
        var before = rig.Socket.Calls("session.resume").Count;
        Assert.True(before >= 2);
        var problem = rig.Chat.SessionProblem;
        Assert.NotNull(problem);
        Assert.Equal("Couldn’t reopen this chat", problem!.Title);
        Assert.Equal("This chat is still starting on the computer running Hermes.", problem.Body);
        Assert.True(problem.Reopen);
        Assert.Equal(SessionProblemPrimary.TryAgain, problem.Primary);

        rig.Socket.Delay("session.resume", TimeSpan.Zero);
        rig.Chat.ResumeTimeout = TimeSpan.FromSeconds(10);
        await rig.Chat.RetryAfterProblemAsync().WaitAsync(TimeSpan.FromSeconds(15));
        Assert.Null(rig.Chat.SessionProblem);
        Assert.True(rig.Socket.Calls("session.resume").Count > before);   // Try Again resumed once more
        Assert.Equal(VoiceFakeClient.Rid, rig.Chat.RuntimeId);
    }

    [Fact]
    public async Task AResumeThatLandsClearsTheReopenProblem()
    {
        await using var rig = new Rig(_stores);
        rig.Chat.ResumeTimeout = TimeSpan.FromMilliseconds(150);
        rig.Socket.Delay("session.resume", TimeSpan.FromSeconds(2));
        await rig.Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        await Assert.ThrowsAsync<GatewayException>(() => rig.Chat.EnsureRuntimeAsync());
        Assert.True(rig.Chat.SessionProblem?.Reopen);
        rig.Socket.Delay("session.resume", TimeSpan.Zero);
        rig.Chat.ResumeTimeout = TimeSpan.FromSeconds(10);
        await rig.Chat.EnsureRuntimeAsync();   // any resume (a send's, a reconnect's), not only Try Again's
        Assert.Null(rig.Chat.SessionProblem);
    }

    [Fact]
    public async Task ARefusedResumeIsNotAReopenProblem()
    {
        // `noteResumeFailed`: only `rpc.isTimeout` says "Couldn’t reopen this chat"; a refusal says its own words elsewhere.
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "session.resume"
            ? throw new Refuse(4004, "session not found") : Loopback.Default(method, p, attempt));
        await rig.Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        await Assert.ThrowsAsync<GatewayException>(() => rig.Chat.EnsureRuntimeAsync());
        Assert.Null(rig.Chat.SessionProblem);
    }

    [Fact]
    public async Task TryAgainOnAChatProblemTakesTheCardAway()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        await rig.Socket.Emit("error", new JsonObject { ["message"] = "Disk is full" });
        Assert.True(await Until(() => rig.Chat.SessionProblem != null));
        var resumes = rig.Socket.Calls("session.resume").Count;
        await rig.Chat.RetryAfterProblemAsync().WaitAsync(TimeSpan.FromSeconds(15));
        Assert.Null(rig.Chat.SessionProblem);
        Assert.Equal(resumes, rig.Socket.Calls("session.resume").Count);   // bound and not a reopen problem: no resume
    }
}
