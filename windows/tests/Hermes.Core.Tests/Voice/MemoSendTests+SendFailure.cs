// [WIN-SEND-FAILURE-ONE-CARD] The one "Couldn’t Send" card (93f984bb1 HermesKit/Chat/LiveChatSession.swift `sendFailure`,
// App/Chat/ChatViewController.swift `sendFailureCard`): typed and memo refusals both set ChatSession.SendFailure, the
// latest wins, and it is cleared only where the Mac clears it (its ✕, a fresh typed send; never a memo send or a queue
// drain). On the same loopback stand-in as the memo cases, synthetic data only.
//
// Ported case for case: (TranscriptFinishTests) aRefusedSendIsTheComposerCardAndNotATranscriptCard (the card, its body,
// no bubble left behind, the words handed back, the next send answers it: [WIN-SEND-REFUSE-WITHDRAW]); (LiveChatSessionTests)
// busyIsRetriedByCodeThenReturnedToTheComposer. The rest of `refuseSend`'s `onDraftReturned` cases are in
// MemoSendTests+RefuseSend.cs. The memo cases that read `sendFailure` (aLinkLostOnScreenIsStillRefused,
// aRefusalReturnsTheDraftAndARetryPaysOnce, aFilesFailureRefusesBeforeSubmitting) are in MemoSendTests.cs, and the copy
// cases (TranscriptPortsTests, TranscriptFinishTests' SendFailure.make ones) in TranscriptExtrasTests.cs.
// The owner-wait, locked-chat and owner-unconfirmed cases of LiveChatSessionTests are in MemoSendTests+OwnerWait.cs
// ([WIN-OWNER-WAIT]); AttachmentPipelineTests' refusals in AttachmentRefusalTests.cs. Not ported (Windows' ChatSession has
// no such path): StopSendRaceTests' stop-hold cases. Added: memo-then-text and text-then-memo refusals, ✕, a queue drain
// and an empty send leaving the card, and Try Again's "anything to send again" rule.

using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    /// The stand-in refuses `prompt.submit` for the words in `refused` (and a memo's first submit when `memoReason` is
    /// set); everything else is answered as usual.
    private static Loopback.Respond RefusingTexts(Dictionary<string, (long Code, string Reason)> refused, string? memoReason = null) =>
        (method, p, attempt) =>
        {
            if (method == "prompt.submit" && p.Str("text") is { } text)
            {
                if (refused.TryGetValue(text, out var no)) throw new Refuse(no.Code, no.Reason);
                if (memoReason != null && VoiceMemo.Parse(text) != null) throw new Refuse(4000, memoReason);
            }
            return Loopback.Default(method, p, attempt);
        };

    [Fact]
    public async Task ARefusedSendIsTheComposerCardAndNotATranscriptCard()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall(RefusingTexts(new() { ["Draft the reply"] = (4012, "this profile has no model provider") }));
        await rig.Ready();
        var before = rig.Chat.Messages.Select(m => m.Id).ToList();
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendAsync("Draft the reply"));
        var failure = Assert.IsType<SendFailure>(rig.Chat.SendFailure);
        Assert.Equal("Couldn’t Send", SendFailure.Title);
        Assert.Equal("Your message is still in the box below. This profile has no model provider.", failure.Body);
        // [WIN-SEND-REFUSE-WITHDRAW] No bubble left behind and no error card (`refuseSend` removes the optimistic one).
        Assert.Equal(before, rig.Chat.Messages.Select(m => m.Id).ToList());
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Error != null);
        Assert.Equal("Draft the reply", rig.Drafts.Last().Text);   // the words go back to the field
        Assert.False(rig.Chat.Busy);

        // The next send answers it.
        rig.Socket.OnCall(Loopback.Default);
        var next = rig.Chat.SendAsync("Draft the reply");
        Assert.Null(rig.Chat.SendFailure);
        Assert.Equal(SendOutcome.Accepted, await next);
        Assert.Null(rig.Chat.SendFailure);
    }

    [Fact]
    public async Task BusyIsRetriedByCodeThenReturnedToTheComposer()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw new Refuse(4009, "session busy") : Loopback.Default(method, p, attempt));
        await rig.Ready();
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendAsync("Are you there?"));
        Assert.True(rig.Socket.Calls("prompt.submit").Count >= 3);
        Assert.Equal(("Are you there?", "session busy"), rig.Drafts.First());
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Role == Role.User && m.Text == "Are you there?");
        Assert.Equal("session busy", rig.Chat.SendFailure?.Reason);   // the refusal is the Couldn't Send card
        Assert.False(rig.Chat.Busy);
    }

    [Fact]
    public async Task AMemoRefusalThenATypedRefusalIsOneCardSayingTheLatest()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall(RefusingTexts(new() { ["typed words"] = (4012, "typed refusal") }, memoReason: "Memo refusal."));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendMemoAsync(memo, ""));
        Assert.Equal("Memo refusal.", rig.Chat.SendFailure?.Reason);
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendAsync("typed words"));
        var failure = Assert.IsType<SendFailure>(rig.Chat.SendFailure);   // one card, the typed refusal's
        Assert.Equal("typed refusal", failure.Reason);
        Assert.Equal("Your message is still in the box below. Typed refusal.", failure.Body);
    }

    [Fact]
    public async Task ATypedRefusalThenAMemoRefusalIsOneCardSayingTheLatest()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall(RefusingTexts(new() { ["typed words"] = (4012, "typed refusal") }, memoReason: "Memo refusal."));
        await rig.Ready();
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendAsync("typed words"));
        var typed = rig.Chat.SendFailure;
        Assert.Equal("typed refusal", typed?.Reason);
        var memo = _stores.Recording(rig.Client.AccountId);
        var sending = rig.Chat.SendMemoAsync(memo, "");
        Assert.Same(typed, rig.Chat.SendFailure);   // a memo send doesn't answer the card (only a typed send does)
        Assert.Equal(SendOutcome.Refused, await sending);
        var failure = Assert.IsType<SendFailure>(rig.Chat.SendFailure);   // one card, the memo refusal's
        Assert.Equal("Memo refusal.", failure.Reason);
        Assert.Equal("Your message is still in the box below. Memo refusal.", failure.Body);
    }

    [Fact]
    public async Task CloseDismissesTheCardAndOnlyAFreshTypedSendAnswersIt()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall(RefusingTexts(new() { ["no"] = (4012, "not now") }));
        await rig.Ready();
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendAsync("no"));
        Assert.NotNull(rig.Chat.SendFailure);
        // An empty send never gets as far as the card (`sendAfterOpen`'s guard comes first).
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendAsync("   "));
        Assert.NotNull(rig.Chat.SendFailure);
        // A queue drain (`drainQueueHead` → `beginSend`) leaves it.
        Assert.Equal(SendOutcome.Accepted, await rig.Chat.SendAsync("queued words", queued: true));
        Assert.NotNull(rig.Chat.SendFailure);
        // ✕ (`dismissSendFailure`) clears it, and says so once.
        var changes = 0;
        rig.Chat.Changed += () => Interlocked.Increment(ref changes);
        rig.Chat.DismissSendFailure();
        Assert.Null(rig.Chat.SendFailure);
        Assert.Equal(1, changes);
        rig.Chat.DismissSendFailure();
        Assert.Equal(1, changes);
    }

    [Fact]
    public void TryAgainSendsOnlyWhenThereIsSomethingToSendAgain()
    {
        // ChatViewController `sendFailureCard.onPrimary`: the field's words or attachments; else the card just goes.
        Assert.True(ChatSession.TryAgainSends("Draft the reply", hasAttachments: false));
        Assert.True(ChatSession.TryAgainSends("", hasAttachments: true));
        Assert.True(ChatSession.TryAgainSends("  \n", hasAttachments: true));
        Assert.False(ChatSession.TryAgainSends("", hasAttachments: false));
        Assert.False(ChatSession.TryAgainSends(" \n\t", hasAttachments: false));
    }
}
