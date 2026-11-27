// [WIN-SEND-REFUSE-WITHDRAW] A refused typed send leaves the transcript and comes back to the box (93f984bb1
// HermesKit/Chat/LiveChatSession.swift `refuseSend`, `onDraftReturned`; App/AppModel.swift's `onDraftReturned` closure):
// its optimistic bubble goes, the words are handed back with the gateway's reason (ChatSession.DraftReturned), the
// "Couldn’t Send" card says why; a send only maybe delivered keeps its bubble with "Delivery unconfirmed" and is never
// handed back. On the same loopback stand-in as the memo cases, synthetic data only.
//
// Ported case for case from LiveChatSessionTests (the cases that read `drafts`, i.e. `onDraftReturned`):
// busyOnceThenAccepted, staleRuntimeResumesOnceAndResubmits (4001, 4007), explicitRefusalsAndUnconfirmedDelivery (its
// "Check" half is not ported: Windows' ChatSession has no checkDelivery). aRefusedSendIsTheComposerCardAndNotATranscriptCard
// and busyIsRetriedByCodeThenReturnedToTheComposer are in MemoSendTests+SendFailure.cs.
// The owner-wait cases (ownedBy…, ownerBusy…, aSignOutEndsTheOwnerWait, aWaitingSendResumesEachTimeItsRuntimeIsReaped,
// stopWithdrawsASendWaitingForTheOwner), the locked-chat cases and ownerUnconfirmedIsMarkedAndNeverResent are in
// MemoSendTests+OwnerWait.cs ([WIN-OWNER-WAIT]). `returnWordsToDraft` (off screen) has no Windows counterpart.
// Added: a skill's invocation comes back rather than its body, a refusal with no words says "Your message wasn’t sent.",
// and AppModel's merge rule (ChatSession.ReturnedDraft: typing done meanwhile is never overwritten).

using Hermes.Core.Chat;
using Hermes.Core.Model;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    [Fact]
    public async Task BusyOnceThenAccepted()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" && attempt == 1
            ? throw new Refuse(4009, "subagent still running — wait for it to finish")
            : method == "prompt.submit" ? new System.Text.Json.Nodes.JsonObject { ["user_row_id"] = 77 } : Loopback.Default(method, p, attempt));
        await rig.Ready();
        Assert.Equal(SendOutcome.Accepted, await rig.Chat.SendAsync("hi"));
        Assert.Equal(77, rig.Chat.Messages.Last(m => m.Role == Role.User).RowId);
        Assert.Equal(2, rig.Socket.Calls("prompt.submit").Count);
        Assert.Empty(rig.Drafts);
        Assert.Null(rig.Chat.SendFailure);
    }

    [Theory]
    [InlineData(4001, "session not found")]
    [InlineData(4007, "session no longer live; retry resume")]
    public async Task StaleRuntimeResumesOnceAndResubmits(long code, string message)
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" && attempt == 1
            ? throw new Refuse(code, message)
            : method == "prompt.submit" ? new System.Text.Json.Nodes.JsonObject { ["user_row_id"] = 88 } : Loopback.Default(method, p, attempt));
        await rig.Ready();
        Assert.Equal(SendOutcome.Accepted, await rig.Chat.SendAsync("hi"));
        Assert.Equal(88, rig.Chat.Messages.Last(m => m.Role == Role.User).RowId);
        Assert.Equal(2, rig.Socket.Calls("session.resume").Count);   // open + one recovery
        Assert.Equal(2, rig.Socket.Calls("prompt.submit").Count);
        Assert.Empty(rig.Drafts);
    }

    [Fact]
    public async Task ExplicitRefusalsAndUnconfirmedDelivery()
    {
        await using var rig = new Rig(_stores);
        // Windows resumes once on any 4007 (the Mac only on "session no longer live"): refused again after it.
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw new Refuse(4007, "session not found") : Loopback.Default(method, p, attempt));
        await rig.Ready();
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendAsync("one"));
        Assert.Single(rig.Drafts);

        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw new Refuse(4090, "…already has a live owner…") : Loopback.Default(method, p, attempt));
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendAsync("two"));
        Assert.Equal(2, rig.Drafts.Count);
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Role == Role.User && m.Text is "one" or "two");

        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw new DropLink() : Loopback.Default(method, p, attempt));
        var before = rig.Socket.Calls("prompt.submit").Count;
        Assert.Equal(SendOutcome.Unconfirmed, await rig.Chat.SendAsync("three").WaitAsync(TimeSpan.FromSeconds(15)));
        var last = rig.Chat.Messages.Last(m => m.Role == Role.User);
        Assert.Equal("Delivery unconfirmed", last.Error);
        await Task.Delay(100);
        Assert.Equal(before + 1, rig.Socket.Calls("prompt.submit").Count);   // never auto-resent
        Assert.Equal("three", last.Text);
        Assert.False(last.IsPending);
        Assert.Equal(2, rig.Drafts.Count);   // never handed back
        // The maybe-delivered bubble keeps its mark (no withdraw) and is never the card (its fresh send answered the last).
        Assert.Null(rig.Chat.SendFailure);
    }

    [Fact]
    public async Task ARefusedSkillHandsBackItsInvocationNotItsBody()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw new Refuse(4012, "no model provider") : Loopback.Default(method, p, attempt));
        await rig.Ready();
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendAsync("Run the skill body: long synthetic text", display: "/tidy notes"));
        Assert.Equal(("/tidy notes", "no model provider"), Assert.Single(rig.Drafts));
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Role == Role.User);
        Assert.False(rig.Chat.Busy);
    }

    [Fact]
    public async Task ARefusalWithNoWordsSaysYourMessageWasntSent()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw new Refuse(4012, "") : Loopback.Default(method, p, attempt));
        await rig.Ready();
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendAsync("hello"));
        var (text, why) = Assert.Single(rig.Drafts);
        Assert.Equal("hello", text);
        Assert.False(string.IsNullOrEmpty(why));
        Assert.NotNull(rig.Chat.SendFailure);
    }

    /// AppModel's `onDraftReturned`: an empty field takes the words; typing done meanwhile is never overwritten (the
    /// words go before it), and words already in the field aren't doubled.
    [Theory]
    [InlineData("", "Draft the reply", "Draft the reply")]
    [InlineData("and more", "Draft the reply", "Draft the reply\nand more")]
    [InlineData("Draft the reply", "Draft the reply", "Draft the reply")]
    [InlineData("Draft the reply\nand more", "Draft the reply", "Draft the reply\nand more")]
    [InlineData("typed meanwhile", "", "typed meanwhile")]
    public void TheReturnedWordsNeverOverwriteTypingDoneMeanwhile(string typed, string returned, string field) =>
        Assert.Equal(field, ChatSession.ReturnedDraft(typed, returned));
}
