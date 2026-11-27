// [WIN-CONNLOST-WORDS] A lost link's words as the Mac's (HermesKit/Net/GatewayFailure.swift at 93f984bb1):
// RPCError.connectionLost(method).message is the client's line "connection closed before the gateway answered:
// <method>" (logs, Show Details, MemoUploader.words); RPCError.plainReason is the alert's sentence. On Windows the
// RPCError is GatewayException ("rpc", "timeout", and "offline" with RpcCode -33002/-33003).
//
// Ported case for case: NetUnitTests.FailureTests.failureWordsArePlain (its RPCError lines; the HTTPError.plainWords
// lines are MemoUploaderTests' PlainWords and CapabilitiesStore.detail is CapabilitiesWords.Detail here),
// SessionActionsTests (the connectionLost lines of the reason/detail case), BotWriteTests (the reason lines),
// PresenceRulesTests (NoticeWriteWords' dropped line: Windows has no NoticeWriteWords.plain; BotWriteException.ReasonOf
// says it at once). Added: the readers the Mac routes through plainReason (GroupTurn.reason, PagesWire.reason,
// CapabilitiesStore.detail) on a lost link.

using Hermes.Core.BotPages;
using Hermes.Core.Capabilities;
using Hermes.Core.Groups;
using Hermes.Core.Net;
using Hermes.Core.Sessions;
using BotWriteException = Hermes.Core.Bots.BotWriteException;

namespace Hermes.Core.Tests.ConnLostWords;

public sealed class ConnectionLostWordsTests
{
    private static GatewayException Rpc(long code, string message) => new("rpc", message, rpcCode: code);

    [Fact]
    public void TheLostLinkCarriesTheMacsLine()
    {
        var lost = GatewayException.ConnectionLost("prompt.submit");
        Assert.Equal("connection closed before the gateway answered: prompt.submit", lost.Message);
        Assert.Equal("prompt.submit", lost.Method);
        Assert.True(lost.IsConnectionLost);
        Assert.Equal("The connection dropped before your gateway answered. Check that it went through, then try again.",
            lost.PlainReason);
    }

    /// failureWordsArePlain (audit 10-2): a failure alert never shows protocol wording or a transport line.
    [Fact]
    public void FailureWordsArePlain()
    {
        var invalid = Rpc(4000, "invalid params for prompt.submit: unexpected key");
        Assert.True(!invalid.PlainReason.Contains("prompt.submit") && invalid.PlainReason.StartsWith("Your gateway didn’t accept"));
        Assert.Equal(invalid.PlainReason, Rpc(4000, "Invalid_params").PlainReason);
        Assert.Equal(invalid.PlainReason, Rpc(-32601, "method not found: x.y").PlainReason);
        Assert.Equal(GatewayException.TimeoutWords, new GatewayException("timeout", "request timed out after 30s: projects.create").PlainReason);
        Assert.DoesNotContain("projects.create", GatewayException.ConnectionLost("projects.create").PlainReason);
        Assert.Equal("That name is taken.", Rpc(5000, " That name is taken. ").PlainReason);
        Assert.Equal(GatewayException.GatewayErrorWords, Rpc(-32603, "Internal error").PlainReason);
        Assert.Equal(MemoUploaderPlain503, Hermes.Core.Voice.MemoUploader.PlainWords(503));
        Assert.Equal("Your gateway ran into a problem (error 500). Try again.", Hermes.Core.Voice.MemoUploader.PlainWords(500));
    }

    private const string MemoUploaderPlain503 = "Hermes isn’t answering right now. It may be restarting — try again in a moment.";

    [Fact]
    public void ANotSentCallKeepsItsOwnWords()
    {
        var notSent = GatewayException.NotConnected();
        Assert.Equal(notSent.Message, notSent.PlainReason);
    }

    /// SessionActionsTests: the dropped call's alert says so plainly; the transport line (with the method) stays behind.
    [Fact]
    public void ASessionActionSaysTheLinkDropped()
    {
        var dropped = GatewayException.ConnectionLost("projects.create");
        Assert.Equal(GatewayException.ConnectionLostWords, SessionStore.ReasonOf(dropped));
        Assert.DoesNotContain("projects.create", SessionStore.ReasonOf(dropped));
        Assert.Contains("projects.create", dropped.Message);
        Assert.Equal("That folder is not on this computer.", SessionStore.ReasonOf(Rpc(-32001, "That folder is not on this computer.")));
    }

    /// BotWriteTests' reason lines and PresenceRulesTests' dropped line.
    [Fact]
    public void ABotWriteSaysTheLinkDropped()
    {
        Assert.Equal(BotWriteException.UnsupportedReason, BotWriteException.ReasonOf(Rpc(-32601, "method not found: profiles.configure")));
        Assert.Equal(BotWriteException.UnsupportedReason, BotWriteException.ReasonOf(Rpc(4000, "invalid params for profiles.configure: x")));
        Assert.Equal("disk full", BotWriteException.ReasonOf(Rpc(5064, "disk full")));
        Assert.Equal("The connection dropped before the computer running Hermes answered.",
            BotWriteException.ReasonOf(GatewayException.ConnectionLost("profiles.configure")));
        Assert.Equal(GatewayException.GatewayErrorWords, BotWriteException.ReasonOf(Rpc(-32603, "Internal error")));
    }

    /// GroupTurn.reason, PagesWire.reason and CapabilitiesStore.detail read RPCError.plainReason on the Mac.
    [Fact]
    public void EveryPlainReasonReaderSaysTheLinkDropped()
    {
        var lost = GatewayException.ConnectionLost("prompt.submit");
        Assert.Equal(GatewayException.ConnectionLostWords, GroupTurn.Reason(lost));
        Assert.Equal(GatewayException.ConnectionLostWords, PagesRest.Reason(lost));
        Assert.Equal(GatewayException.ConnectionLostWords, CapabilitiesWords.Detail(lost));
        Assert.Equal(GatewayException.TimeoutWords, GroupTurn.Reason(new GatewayException("timeout", "request timed out after 30s: prompt.submit")));
        Assert.Equal(GatewayException.NotAcceptedWords, GroupTurn.Reason(Rpc(-32602, "invalid params for prompt.submit")));
        Assert.Equal(GatewayException.NotAcceptedWords, CapabilitiesWords.Detail(Rpc(4000, "invalid params for mcp.list")));
    }
}
