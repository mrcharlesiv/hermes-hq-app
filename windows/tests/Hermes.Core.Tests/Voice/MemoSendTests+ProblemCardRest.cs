// [WIN-PROBLEM-CARD-REST] The rest of the chat's problem card (ChatSession+Problems.cs), stated from the Swift at
// 93f984bb1 on the same loopback stand-in as the memo cases, synthetic data only:
//   HermesKit/Chat/LiveChatSession.swift `resumeNow` — `if let rpc = error as? RPCError, Self.isChatLocked(rpc) {
//     sessionProblem = SessionProblem.chatLocked(detail: rpc.message) }`: a resume refused `4001 profile_mismatch` is the
//     locked chat's card; a send that resumed first is refused into it, and the two cards never show at once (`submit`'s
//     locked path: `sendFailure = nil   // one card: the problem card names the way on`);
//   `retryAfterProblem` — `if self.openError != nil || self.messages.isEmpty { self.start() }`, and `start()`'s
//     `beginOpen(failedOpen:)` sets `openError = nil`: Try Again after a failed open reads the page, and a read that
//     lands takes the page's own "Couldn't load this chat" away (ChatSession.OpenRecovered).

using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Net;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    private static Refuse ProfileMismatch() =>
        new(4001, "profile_mismatch", new JsonObject { ["reason"] = "profile_mismatch" });

    [Fact]
    public async Task AResumeRefusedForALockedChatIsTheLockedChatsCard()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "session.resume" ? throw ProfileMismatch() : Loopback.Default(method, p, attempt));
        await rig.Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        await Assert.ThrowsAsync<GatewayException>(() => rig.Chat.EnsureRuntimeAsync());
        var problem = rig.Chat.SessionProblem;
        Assert.NotNull(problem);
        Assert.Equal(SessionProblem.ChatLockedTitle, problem!.Title);
        Assert.Equal(SessionProblemPrimary.NewChat, problem.Primary);
        Assert.Equal("profile_mismatch", problem.Detail);
        Assert.False(problem.Reopen);   // not "Couldn’t reopen this chat": no retry can open it
        Assert.Null(rig.Chat.SendFailure);
    }

    [Fact]
    public async Task ASendWhoseResumeIsRefusedLockedShowsTheProblemCardNotCouldntSend()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "session.resume" ? throw ProfileMismatch() : Loopback.Default(method, p, attempt));
        await rig.Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendAsync("hi").WaitAsync(TimeSpan.FromSeconds(15)));
        Assert.Equal(SessionProblem.ChatLockedTitle, rig.Chat.SessionProblem?.Title);
        Assert.Null(rig.Chat.SendFailure);                                            // one card
        Assert.Contains(rig.Drafts, d => d.Text == "hi");                            // the words are back in the box
        Assert.Empty(rig.Socket.Calls("prompt.submit"));                              // it never went out
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Id.StartsWith("local-user")); // no bubble left behind
        Assert.False(rig.Chat.Busy);
    }

    [Fact]
    public async Task ALockedResumeTakesAnEarlierCouldntSendAway()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        rig.Socket.OnCall((method, p, attempt) => method switch
        {
            "prompt.submit" => throw new Refuse(4000, "Model provider is out of credits."),
            "session.resume" when attempt > 1 => throw ProfileMismatch(),
            _ => Loopback.Default(method, p, attempt),
        });
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendAsync("first try"));
        Assert.NotNull(rig.Chat.SendFailure);
        rig.Chat.ForgetRuntime();
        await Assert.ThrowsAsync<GatewayException>(() => rig.Chat.EnsureRuntimeAsync());
        Assert.Equal(SessionProblem.ChatLockedTitle, rig.Chat.SessionProblem?.Title);
        Assert.Null(rig.Chat.SendFailure);   // the two cards never show at once
    }

    [Fact]
    public async Task TryAgainAfterAFailedOpenReadsThePageAndClearsTheLoadFailure()
    {
        await using var rig = new Rig(_stores);
        rig.Chat.ResumeTimeout = TimeSpan.FromMilliseconds(150);
        rig.Socket.Delay("session.resume", TimeSpan.FromSeconds(2));
        rig.Socket.FailHistory = true;
        var recovered = 0;
        rig.Chat.OpenRecovered += () => Interlocked.Increment(ref recovered);
        await rig.Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        await Assert.ThrowsAsync<GatewayException>(() => rig.Chat.OpenAsync().WaitAsync(TimeSpan.FromSeconds(15)));
        Assert.True(rig.Chat.OpenFailed);                                                       // "Couldn't load this chat"
        Assert.True(await Until(() => rig.Chat.SessionProblem?.Reopen == true));                // and "Couldn’t reopen this chat"
        Assert.Empty(rig.Chat.Messages);

        rig.Socket.FailHistory = false;
        rig.Socket.History = [UserRow("What is the plan for the synthetic project?", 1), ReplyRow("Ship it on example.com.", 2)];
        rig.Socket.Delay("session.resume", TimeSpan.Zero);
        rig.Chat.ResumeTimeout = TimeSpan.FromSeconds(10);
        await rig.Chat.RetryAfterProblemAsync().WaitAsync(TimeSpan.FromSeconds(15));
        Assert.Null(rig.Chat.SessionProblem);
        Assert.Equal(VoiceFakeClient.Rid, rig.Chat.RuntimeId);
        Assert.False(rig.Chat.OpenFailed);
        Assert.Equal(1, Volatile.Read(ref recovered));                                         // the page takes its failure away
        Assert.Equal(2, rig.Chat.Messages.Count);
    }

    [Fact]
    public async Task TryAgainWhoseReadFailsAgainKeepsTheLoadFailure()
    {
        await using var rig = new Rig(_stores);
        rig.Chat.ResumeTimeout = TimeSpan.FromMilliseconds(150);
        rig.Socket.Delay("session.resume", TimeSpan.FromSeconds(2));
        rig.Socket.FailHistory = true;
        var recovered = 0;
        rig.Chat.OpenRecovered += () => Interlocked.Increment(ref recovered);
        await rig.Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        await Assert.ThrowsAsync<GatewayException>(() => rig.Chat.OpenAsync().WaitAsync(TimeSpan.FromSeconds(15)));
        Assert.True(await Until(() => rig.Chat.SessionProblem?.Reopen == true));

        rig.Socket.Delay("session.resume", TimeSpan.Zero);
        rig.Chat.ResumeTimeout = TimeSpan.FromSeconds(10);
        await rig.Chat.RetryAfterProblemAsync().WaitAsync(TimeSpan.FromSeconds(15));
        Assert.True(rig.Chat.OpenFailed);
        Assert.Equal(0, Volatile.Read(ref recovered));
        Assert.Empty(rig.Chat.Messages);
    }
}
