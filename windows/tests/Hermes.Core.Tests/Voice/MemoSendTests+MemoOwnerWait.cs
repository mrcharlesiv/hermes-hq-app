// [WIN-MEMO-OWNER-WAIT] A voice memo refused because another Hermes process holds the chat waits for it like a typed
// send (93f984bb1 HermesKit/Chat/LiveChatSession+Memo.swift `runMemoSend` ends in the same `submit` loop as a typed
// send, so its `ownerDeadline`, the waiting card, the locked-chat and SESSION_OWNER_UNCONFIRMED branches apply to a
// memo too, and `refuseSend`/`withdrawStoppedSend`/`markUnconfirmed` hand it to `memoSendFinished` as .refused,
// .withdrawn or .unconfirmed). On the same loopback stand-in as the other memo cases, synthetic data only.
//
// The Mac has no memo owner-wait cases of its own (its Tests name none for a memo and a 4090): these mirror the typed
// ones in MemoSendTests+OwnerWait.cs for a memo. Each checks the memo's own ending: staged once (one upload, one
// attach, one transcription) however many tries; sent, the recording is adopted under its gateway path; handed back
// (window over, Stop, a locked chat), the memo is the chat's draft chip and the words typed beside it go to the field;
// unconfirmed, never resent and never handed back.

using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    private const string MemoGatewayPath = "/Users/owner/.hermes/profiles/ivy/attachments/voice-memo.wav";

    /// Staged once, however many times the submit was refused.
    private static void StagedOnce(Rig rig)
    {
        Assert.Equal(1, rig.Count("POST /api/files/upload-stream"));
        Assert.Single(rig.Socket.Calls("file.attach"));
        Assert.Equal(1, rig.Count("POST /api/audio/transcribe"));
    }

    [Fact]
    public async Task AMemoOwnedByAOneShotRunWaitsThenSends()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" && attempt <= 10 ? throw OwnedRefusal("cli")
            : method == "prompt.submit" ? new JsonObject { ["user_row_id"] = 95 } : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        var sending = rig.Chat.SendMemoAsync(memo, "beside it");
        Assert.True(await Until(() => rig.Chat.OwnerWaitNotice == OwnerWait.BackgroundTask));
        Assert.Equal(OwnerWait.BackgroundTask.Status, rig.Chat.Status);
        Assert.True(LastUser(rig)?.IsPending);                       // the memo's bubble waits with the transcript
        Assert.Contains("Pick up milk", LastUser(rig)?.Text);
        Assert.Null(rig.Chat.SendFailure);
        Assert.Null(rig.Chat.MemoDraft);
        Assert.Equal(SendOutcome.Accepted, await sending.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(95, LastUser(rig)?.RowId);
        Assert.Equal(11, rig.Socket.Calls("prompt.submit").Count);
        Assert.All(rig.Socket.Calls("prompt.submit"), p => Assert.Equal(
            $"MEDIA:\"{MemoGatewayPath}\"\n\nVoice memo transcript: Pick up milk on the way home.\n\nbeside it", p.Str("text")));
        StagedOnce(rig);
        Assert.Empty(rig.Returned);
        Assert.Null(rig.Chat.MemoDraft);
        Assert.NotNull(_stores.Stores.Cache!.Local(MemoGatewayPath));   // acknowledged: adopted under its gateway path
        Assert.Empty(rig.Chat.MemoSendIds);
        Assert.Null(rig.Chat.OwnerWaitNotice);
        Assert.Null(rig.Chat.WaitingForOwner);
    }

    [Fact]
    public async Task AMemoWaitsForTheRunningReplyThenSends()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" && attempt <= 4
            ? throw OwnerBusyRefusal("a rewind or attachment cannot join its queue")   // not a refused hand-off: waits
            : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        var sending = rig.Chat.SendMemoAsync(memo, "");
        Assert.True(await Until(() => rig.Chat.OwnerWaitNotice == OwnerWait.RunningReply));
        Assert.Equal(SendOutcome.Accepted, await sending.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(5, rig.Socket.Calls("prompt.submit").Count);
        StagedOnce(rig);
        Assert.Null(rig.Chat.MemoDraft);
        Assert.Null(rig.Chat.SendFailure);
        Assert.Null(rig.Chat.WaitingForOwner);
    }

    /// Stop (here the card's Cancel Message) while the memo waits: it never goes out; the memo is the draft chip again.
    [Fact]
    public async Task StopWithdrawsAMemoWaitingForTheOwnerAsTheDraftChip()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw OwnedRefusal("cli") : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        var sending = rig.Chat.SendMemoAsync(memo, "beside it");
        Assert.True(await Until(() => rig.Chat.OwnerWaitNotice == OwnerWait.BackgroundTask));
        await rig.Chat.CancelOwnerWaitAsync();
        Assert.Equal(SendOutcome.Refused, await sending.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(memo, rig.Chat.MemoDraft);
        Assert.Equal([("beside it", ChatSession.StoppedBeforeSending)], rig.Returned);
        Assert.True(File.Exists(memo.Path));
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Role == Role.User);
        Assert.Null(rig.Chat.SendFailure);   // a Stop is no refusal
        Assert.Null(rig.Chat.OwnerWaitNotice);
        Assert.Null(rig.Chat.WaitingForOwner);
        Assert.Empty(rig.Chat.MemoSendIds);
        var tries = rig.Socket.Calls("prompt.submit").Count;
        await Task.Delay(150);
        Assert.Equal(tries, rig.Socket.Calls("prompt.submit").Count);   // the wait ended: no more tries
    }

    /// A window that keeps the chat open: the short wait, then "Couldn’t Send" with the memo back as the draft chip.
    [Fact]
    public async Task AMemoOwnedByAWindowEndsCouldntSendWithTheMemoBack()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Chat.OwnerWaitShortWindow = TimeSpan.FromMilliseconds(200);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw OwnedRefusal("desktop") : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        var sending = rig.Chat.SendMemoAsync(memo, "beside it");
        Assert.True(await Until(() => rig.Chat.OwnerWaitNotice == OwnerWait.OtherWindow));
        Assert.Equal(SendOutcome.Refused, await sending.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.True(rig.Socket.Calls("prompt.submit").Count > 1);   // it waited before giving up
        StagedOnce(rig);
        Assert.Equal(memo, rig.Chat.MemoDraft);
        var (typed, why) = Assert.Single(rig.Returned);
        Assert.Equal("beside it", typed);
        Assert.Contains("opened by desktop", why);
        Assert.NotNull(rig.Chat.SendFailure);
        Assert.Contains("opened by desktop", rig.Chat.SendFailure!.CopyText);
        Assert.True(File.Exists(memo.Path));
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Role == Role.User);
        Assert.Null(rig.Chat.OwnerWaitNotice);
        Assert.False(rig.Chat.Busy);
        // A retry into the same chat reuses the first attempt's staging (no second upload or transcription).
        var draft = _stores.Stores.Drafts!.Take(rig.Chat.DraftScope)!;
        rig.Socket.OnCall(Loopback.Default);
        Assert.Equal(SendOutcome.Accepted, await rig.Chat.SendMemoAsync(draft, "beside it").WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(1, rig.Count("POST /api/files/upload-stream"));
        Assert.Equal(1, rig.Count("POST /api/audio/transcribe"));
    }

    /// The gateway's queue may hold it already: "Delivery unconfirmed", never resent and never handed back.
    [Fact]
    public async Task AMemoWhoseOwnerIsUnconfirmedIsMarkedAndNeverResent()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit"
            ? throw new Refuse(4090, "The gateway is running a turn in this chat and did not confirm your message in time. "
                + "It may already be queued there: check the chat before sending it again.",
                new JsonObject { ["reason"] = "SESSION_OWNER_UNCONFIRMED" })
            : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        Assert.Equal(SendOutcome.Unconfirmed, await rig.Chat.SendMemoAsync(memo, "beside it").WaitAsync(TimeSpan.FromSeconds(10)));
        var bubble = LastUser(rig)!;
        Assert.Equal(ChatSession.UnconfirmedMark, bubble.Error);
        Assert.False(bubble.IsPending);
        Assert.Contains("Pick up milk", bubble.Text);
        await Task.Delay(150);
        Assert.Single(rig.Socket.Calls("prompt.submit"));
        Assert.Null(rig.Chat.MemoDraft);
        Assert.Empty(rig.Returned);
        Assert.Null(rig.Chat.SendFailure);
        Assert.Null(rig.Chat.OwnerWaitNotice);
        Assert.NotNull(_stores.Stores.Cache!.Local(MemoGatewayPath));   // the recording goes to the playback cache
        Assert.Empty(rig.Chat.MemoSendIds);
    }

    /// [locked-chat] A chat the gateway won't open: the memo comes back as the draft chip on the problem card (New
    /// Chat), not Couldn't Send, and is never resumed and resent.
    [Fact]
    public async Task ALockedChatHandsTheMemoBackWithNewChat()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit"
            ? throw new Refuse(4001, "profile_mismatch", new JsonObject { ["reason"] = "profile_mismatch" })
            : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendMemoAsync(memo, "beside it").WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(memo, rig.Chat.MemoDraft);
        Assert.Equal([("beside it", "profile_mismatch")], rig.Returned);
        Assert.Equal(SessionProblemPrimary.NewChat, rig.Chat.SessionProblem?.Primary);
        Assert.Null(rig.Chat.SendFailure);
        Assert.Single(rig.Socket.Calls("prompt.submit"));
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Role == Role.User);
    }
}
