// [WIN-SEND-NOTSENT-REFUSE] A send that never left is refused and handed back, never "Delivery unconfirmed" (93f984bb1
// HermesKit/Chat/LiveChatSession.swift's submit loop: only `error.isTimeout || error.isConnectionLost` is marked
// unconfirmed, "One that never went out (`isNotConnected`) is safe to refuse"; GatewayConnection.call's waitPublished
// deadline throws `out.failure.value ?? GatewayFailure.timeout`, which LiveGatewayClient.call makes RPCError.notSent).
// On the same loopback stand-in as the other memo cases: the gateway goes away for now (its dials answer 503) and the
// socket is cut, so the call waits for a socket that never comes; synthetic data only.
//
// Ported: NetBoundaryTests.notSentErrorsCarryTheirReason (Tests/NetRegressionTests.swift: a not-sent error carries its
// reason and is neither a timeout nor a lost link; a gateway's own error is not a not-sent one), the submit loop's
// refusal on notSent for a typed send and a memo, and `linkAwayForNow`. Added: the socket wait is at most
// MaxReadyWait (GatewayConnection.Timing.maxReadyWait) and nothing went out, and the same words send once the gateway
// is back (safe to send again).

using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    [Fact]
    public void NotSentErrorsCarryTheirReason()
    {
        var error = GatewayException.NotSent("paused");
        Assert.True(error.IsNotConnected && error.Code != "timeout" && !error.IsConnectionLost);
        Assert.Equal("paused", error.NotSentBecause);
        Assert.Equal("Paused while Hermes HQ is in the background.", error.Message);
        Assert.Equal(error.Message, error.PlainReason);
        Assert.Equal("network", GatewayException.NotSent("network").NotSentBecause);
        Assert.Equal("You’re offline. Hermes HQ reconnects when the network is back.", GatewayException.NotSent("network").Message);
        // The socket wait ran out with no failure of its own: GatewayFailure.timeout's words, still not sent.
        Assert.Equal(GatewayException.TimeoutWords, GatewayException.NotSent("timeout").Message);
        Assert.False(ChatSession.MayHaveGoneOut(GatewayException.NotSent("timeout")));
        Assert.Equal(GatewayException.SocketDeadReason, GatewayException.NotConnected().NotSentBecause);
        // A gateway's own error is not a not-sent one; nor is a lost link or a timeout (both may have gone out).
        Assert.Null(new GatewayException("rpc", "busy", rpcCode: 4001).NotSentBecause);
        Assert.Null(GatewayException.ConnectionLost("prompt.submit").NotSentBecause);
        Assert.Null(new GatewayException("timeout", "The gateway didn't answer prompt.submit in time.").NotSentBecause);
        Assert.True(ChatSession.MayHaveGoneOut(GatewayException.ConnectionLost("prompt.submit")));
        Assert.True(ChatSession.MayHaveGoneOut(new GatewayException("timeout", "The gateway didn't answer prompt.submit in time.")));
        Assert.False(ChatSession.MayHaveGoneOut(GatewayException.NotConnected()));
        // linkAwayForNow: away for now keeps an owner wait going; a sign-out or a changed connection ends it.
        foreach (var away in new[] { "paused", "network", "socket-dead", "timeout", "unreachable" })
            Assert.True(GatewayException.LinkAwayForNow(GatewayException.NotSent(away)), away);
        foreach (var gone in new[] { "signed-out", "session-ended", "connection-changed", "account-missing" })
            Assert.False(GatewayException.LinkAwayForNow(GatewayException.NotSent(gone)), gone);
        Assert.False(GatewayException.LinkAwayForNow(GatewayException.ConnectionLost("prompt.submit")));
        // The submit loop's `if let deadline = ownerDeadline, now < deadline, linkAwayForNow(error)`: only a send that
        // waits for the chat's owner, inside its window, keeps waiting; otherwise it is refused.
        var now = DateTimeOffset.UtcNow;
        Assert.True(ChatSession.KeepsWaitingWhileAway(now.AddMinutes(1), now, GatewayException.NotSent("paused")));
        Assert.False(ChatSession.KeepsWaitingWhileAway(null, now, GatewayException.NotSent("paused")));
        Assert.False(ChatSession.KeepsWaitingWhileAway(now, now, GatewayException.NotSent("paused")));
        Assert.False(ChatSession.KeepsWaitingWhileAway(now.AddMinutes(1), now, GatewayException.NotSent("signed-out")));
    }

    /// The gateway goes away for now: its dials answer 503 and the open socket is cut.
    private static async Task GoAway(Rig rig)
    {
        rig.Client.Rpc.MaxReadyWait = TimeSpan.FromMilliseconds(400);
        rig.Socket.DownForNow = true;
        rig.Socket.Cut();
        Assert.True(await Until(() => rig.Client.Rpc.State != ConnectionState.Open));
    }

    private static readonly string[] NotSentWordsSeen =
        [GatewayException.TimeoutWords, GatewayException.GatewayErrorWords, GatewayException.NotSentWords("unreachable")];

    [Fact]
    public async Task ARequestWithNoSocketFailsAsNotSentAtTheReadyWait()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        await GoAway(rig);
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var error = await Assert.ThrowsAsync<GatewayException>(() =>
            rig.Client.Rpc.RequestAsync("profiles.list", new System.Text.Json.Nodes.JsonObject(), TimeSpan.FromSeconds(1800)));
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(5), $"failed after {clock.Elapsed}");   // MaxReadyWait, not 1800 s
        Assert.True(error.IsNotConnected, $"{error.Code} {error.RpcCode}");
        Assert.NotEqual("timeout", error.Code);
        Assert.NotNull(error.NotSentBecause);
        Assert.Equal(GatewayException.NotSentWords(error.NotSentBecause!), error.Message);
        Assert.Empty(rig.Socket.Calls("profiles.list"));
    }

    [Fact]
    public async Task ATypedSendThatNeverLeftIsRefusedAndHandedBackThenSendsOnceBack()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        await GoAway(rig);
        Assert.Equal(SendOutcome.Refused, await Within(rig.Chat.SendAsync("never left")));
        var (text, why) = Assert.Single(rig.Drafts);
        Assert.Equal("never left", text);
        Assert.Contains(why, NotSentWordsSeen);
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Role == Role.User);   // the bubble went back to the box
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Error == ChatSession.UnconfirmedMark);
        Assert.NotNull(rig.Chat.SendFailure);
        Assert.Empty(rig.Socket.Calls("prompt.submit"));                      // nothing went out
        // Safe to send again: once the gateway is back the same words go out once.
        rig.Socket.DownForNow = false;
        rig.Client.Rpc.MaxReadyWait = TimeSpan.FromSeconds(60);
        Assert.Equal(SendOutcome.Accepted, await Within(rig.Chat.SendAsync("never left")));
        Assert.Single(rig.Socket.Calls("prompt.submit"));
        Assert.Equal("never left", rig.Chat.Messages.Single(m => m.Role == Role.User).Text);
    }

    [Fact]
    public async Task AMemoWhoseSubmitNeverLeftIsHandedBackNotUnconfirmed()
    {
        await using var rig = new Rig(_stores);
        // The link goes after the memo is attached, while it is transcribed: its prompt.submit finds no socket.
        rig.RestAnswer = (method, path, body) =>
        {
            if (path.StartsWith("/api/audio/transcribe", StringComparison.Ordinal) && !rig.Socket.DownForNow)
                GoAway(rig).GetAwaiter().GetResult();
            return VoiceFakeClient.DefaultRest(method, path, body);
        };
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        Assert.Equal(SendOutcome.Refused, await Within(rig.Chat.SendMemoAsync(memo, "beside it")));
        Assert.Single(rig.Socket.Calls("file.attach"));
        Assert.Empty(rig.Socket.Calls("prompt.submit"));                      // nothing went out
        Assert.Single(rig.Returned);                                          // handed back to the box
        Assert.NotNull(rig.Chat.MemoDraft);                                   // the memo is the draft chip again
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Error == ChatSession.UnconfirmedMark);
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Role == Role.User);
        Assert.Empty(rig.Chat.MemoSendIds);
    }
}
