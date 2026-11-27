// [WIN-OWNER-WAIT] A typed send refused because another Hermes process holds the chat waits for it and goes out when
// the chat is free (93f984bb1 HermesKit/Chat/LiveChatSession.swift `ownerDeadline`, `ownerWaitNotice`, the 4090
// SESSION_NOT_OWNED / SESSION_OWNER_BUSY / SESSION_OWNER_UNCONFIRMED and locked-chat branches; ChatSession+OwnerWait.cs).
// On the same loopback stand-in as the memo cases, synthetic data only.
//
// Ported case for case from LiveChatSessionTests: ownedByAOneShotRunWaitsThenSends, aSignOutEndsTheOwnerWait,
// aWaitingSendResumesEachTimeItsRuntimeIsReaped, ownedByAWindowIsRefusedAfterTheShortWait,
// ownedByAMessagingTurnWaitsThenSends, theHolderNamesTheWait, stopWithdrawsASendWaitingForTheOwner,
// ownerBusyWaitsForTheRunningReplyThenSends, lockedChatRefusalsAreKnown, lockedChatSendIsHandedBackWithNewChat,
// busyWhoseHandOffKeepsBeingRefusedStopsWaiting, ownerBusyPastTheWaitIsRefusedInPlainWords,
// ownerUnconfirmedIsMarkedAndNeverResent. The attachment path's ownerBusyWithPhotosHandsThemBackAtOnce is in
// AttachmentRefusalTests.cs.
// Not ported: aSendWaitingForTheOwnerOutlivesAPausedLink (RPCError.notSent(.paused/.offline) answered per call has no
// Windows counterpart: a call made while the link is down waits for it in RpcConnection; the wait's link-away half is
// what aSignOutEndsTheOwnerWait walks through), ownerWaitChangedPassShowsHoldersReply and refusedWindowWaitReadsTail
// (the changed pass: Windows' chat has none). The external-turn watch's part of the wait is in MemoSendTests+External.cs.

using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    /// The gateway's refusal while another process (a cron job's one-shot `hermes chat`, a window) holds the chat.
    private static Refuse OwnedRefusal(string surface) => new(4090,
        "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\n"
        + $"Details: session 20260101_090000_aa0001 opened by {surface} 0m ago.", new JsonObject { ["reason"] = "SESSION_NOT_OWNED" });

    /// The gateway runs a turn in this chat and its queue couldn't take ours.
    private static Refuse OwnerBusyRefusal(string why = "the gateway refused it") => new(4090,
        $"The gateway is running a turn in this chat and {why}. Nothing was sent. Send it again when the current turn ends.",
        new JsonObject { ["reason"] = "SESSION_OWNER_BUSY" });

    private static GatewayException AsError(Refuse r) =>
        new("rpc", r.Message, rpcCode: r.Code, body: r.Data?.ToJsonString());

    private static void FastOwnerWait(ChatSession chat) => chat.OwnerRetryInterval = TimeSpan.FromMilliseconds(20);

    private ChatMessage? LastUser(Rig rig) => rig.Chat.Messages.LastOrDefault(m => m.Role == Role.User);

    [Fact]
    public async Task OwnedByAOneShotRunWaitsThenSends()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" && attempt <= 10 ? throw OwnedRefusal("cli")
            : method == "prompt.submit" ? new JsonObject { ["user_row_id"] = 91 } : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var sending = rig.Chat.SendAsync("What is the plan for the synthetic project?");
        Assert.True(await Until(() => rig.Chat.Status == OwnerWait.BackgroundTask.Status));
        Assert.Equal(OwnerWait.BackgroundTask, rig.Chat.OwnerWaitNotice);
        rig.Chat.DismissOwnerWait();
        Assert.Null(rig.Chat.OwnerWaitNotice);                                    // ✕ hides the card…
        Assert.Equal(OwnerWait.BackgroundTask.Status, rig.Chat.Status);           // …the wait and its status stay
        Assert.True(LastUser(rig)?.IsPending);
        Assert.Null(rig.Chat.SendFailure);
        Assert.Equal(SendOutcome.Accepted, await sending.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(91, LastUser(rig)?.RowId);
        Assert.Equal(11, rig.Socket.Calls("prompt.submit").Count);
        Assert.Empty(rig.Drafts);
        Assert.Null(rig.Chat.SendFailure);
        Assert.NotEqual(OwnerWait.BackgroundTask.Status, rig.Chat.Status);
        Assert.Null(rig.Chat.OwnerWaitNotice);
        Assert.Null(rig.Chat.WaitingForOwner);
    }

    /// A sign-out while the send waits ends the wait: the words come back instead of a send nobody can see. (On the
    /// Mac the third try fails as `notSent(.signedOut)`; on Windows it never goes out: the wait sees the link signed out.)
    [Fact]
    public async Task ASignOutEndsTheOwnerWait()
    {
        await using var rig = new Rig(_stores);
        rig.Chat.OwnerRetryInterval = TimeSpan.FromMilliseconds(400);   // the cut lands well inside the second pause
        var socket = rig.Socket;
        socket.OnCall((method, p, attempt) =>
        {
            if (method != "prompt.submit") return Loopback.Default(method, p, attempt);
            if (attempt == 2)
            {
                socket.RefuseTickets = true;   // signed out elsewhere: the next dial is refused
                _ = Task.Run(async () => { await Task.Delay(50); socket.Cut(); });
            }
            throw OwnedRefusal("cli");
        });
        await rig.Ready();
        var sending = rig.Chat.SendAsync("hi");
        Assert.True(await Until(() => rig.Drafts.Count > 0, 15));
        Assert.Equal(SendOutcome.Refused, await sending.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal("hi", rig.Drafts[0].Text);
        Assert.Equal(2, rig.Socket.Calls("prompt.submit").Count);
        Assert.Null(rig.Chat.OwnerWaitNotice);
        Assert.False(rig.Chat.Busy);
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Role == Role.User && m.Text == "hi");
    }

    /// The chat's runtime is reaped more than once during one wait: each time it resumes and keeps waiting.
    [Fact]
    public async Task AWaitingSendResumesEachTimeItsRuntimeIsReaped()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit"
            ? attempt switch
            {
                1 or 3 or 5 => throw OwnedRefusal("cli"),
                2 or 4 => throw new Refuse(4001, "session not found"),
                _ => new JsonObject { ["user_row_id"] = 94 },
            }
            : Loopback.Default(method, p, attempt));
        await rig.Ready();
        Assert.Equal(SendOutcome.Accepted, await rig.Chat.SendAsync("hi").WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(94, LastUser(rig)?.RowId);
        Assert.Equal(3, rig.Socket.Calls("session.resume").Count);   // open + one per reap
        Assert.Empty(rig.Drafts);
        Assert.Null(rig.Chat.SendFailure);
    }

    [Fact]
    public async Task OwnedByAWindowIsRefusedAfterTheShortWait()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Chat.OwnerWaitShortWindow = TimeSpan.FromMilliseconds(200);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw OwnedRefusal("desktop") : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var sending = rig.Chat.SendAsync("hi");
        Assert.True(await Until(() => rig.Chat.OwnerWaitNotice == OwnerWait.OtherWindow));
        Assert.Equal(SendOutcome.Refused, await sending.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal("hi", rig.Drafts[0].Text);
        Assert.Null(rig.Chat.OwnerWaitNotice);
        Assert.NotNull(rig.Chat.SendFailure);
        Assert.Contains("opened by desktop", rig.Chat.SendFailure!.CopyText);   // the holder stays copyable
        Assert.False(rig.Chat.Busy);
        Assert.Null(rig.Chat.Status);
    }

    /// A Telegram or Discord turn holds the chat as "gateway:<platform>": the long wait, and the card names the app.
    [Fact]
    public async Task OwnedByAMessagingTurnWaitsThenSends()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Chat.OwnerWaitShortWindow = TimeSpan.FromMilliseconds(50);   // ten refusals outlast it: the wait is the long one
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" && attempt <= 10 ? throw OwnedRefusal("gateway:discord")
            : method == "prompt.submit" ? new JsonObject { ["user_row_id"] = 93 } : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var sending = rig.Chat.SendAsync("hi");
        Assert.True(await Until(() => rig.Chat.OwnerWaitNotice == OwnerWait.MessagingTurn("Discord")));
        Assert.Contains("a message from Discord", rig.Chat.OwnerWaitNotice?.CardBody ?? "");
        Assert.Equal(OwnerWait.MessagingTurn("Discord").Status, rig.Chat.Status);
        Assert.Equal(SendOutcome.Accepted, await sending.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(93, LastUser(rig)?.RowId);
        Assert.Empty(rig.Drafts);
        Assert.Null(rig.Chat.SendFailure);
        Assert.Null(rig.Chat.OwnerWaitNotice);
    }

    [Fact]
    public void TheHolderNamesTheWait()
    {
        static OwnerWait Wait(string surface) => ChatSession.OwnerWaitOf(AsError(OwnedRefusal(surface)));
        Assert.Equal(OwnerWait.MessagingTurn("Telegram"), Wait("gateway:telegram"));
        Assert.Equal(OwnerWait.MessagingTurn("iMessage"), Wait("gateway:bluebubbles"));
        Assert.Equal(OwnerWait.MessagingTurn(null), Wait("gateway"));
        Assert.Equal(OwnerWait.OtherWindow, Wait("gateway_boot"));
        Assert.Equal(OwnerWait.BackgroundTask, Wait("cli"));
        Assert.Equal(OwnerWait.OtherWindow, Wait("desktop"));
        Assert.Equal(OwnerWait.OtherWindow, Wait("tui"));
        Assert.Equal(OwnerWait.RunningReply, ChatSession.OwnerWaitOf(AsError(OwnerBusyRefusal())));
        Assert.DoesNotContain("nil", OwnerWait.MessagingTurn(null).CardBody);
        Assert.DoesNotContain("null", OwnerWait.MessagingTurn(null).CardBody);
    }

    [Fact]
    public async Task StopWithdrawsASendWaitingForTheOwner()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw OwnedRefusal("cli") : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var sending = rig.Chat.SendAsync("hi");
        Assert.True(await Until(() => rig.Chat.OwnerWaitNotice == OwnerWait.BackgroundTask));
        await rig.Chat.CancelOwnerWaitAsync();
        Assert.Equal(SendOutcome.Refused, await sending.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(("hi", ChatSession.StoppedBeforeSending), rig.Drafts[0]);
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Role == Role.User && m.Text == "hi");
        Assert.Null(rig.Chat.SendFailure);   // a Stop is no refusal
        Assert.Null(rig.Chat.OwnerWaitNotice);
    }

    [Fact]
    public async Task OwnerBusyWaitsForTheRunningReplyThenSends()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Chat.OwnerWaitShortWindow = TimeSpan.FromMilliseconds(50);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" && attempt <= 10 ? throw OwnerBusyRefusal()
            : method == "prompt.submit" ? new JsonObject { ["user_row_id"] = 92 } : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var sending = rig.Chat.SendAsync("hi");
        Assert.True(await Until(() => rig.Chat.OwnerWaitNotice == OwnerWait.RunningReply));
        Assert.Equal(OwnerWait.RunningReply.Status, rig.Chat.Status);
        Assert.True(LastUser(rig)?.IsPending);
        Assert.Null(rig.Chat.SendFailure);
        Assert.Equal(SendOutcome.Accepted, await sending.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(92, LastUser(rig)?.RowId);
        Assert.Equal(11, rig.Socket.Calls("prompt.submit").Count);
        Assert.Empty(rig.Drafts);
        Assert.Null(rig.Chat.SendFailure);
        Assert.Null(rig.Chat.OwnerWaitNotice);
    }

    // [locked-chat] A chat whose stored record names the bot's old folder is refused (`profile_mismatch`), and the
    // queued work it holds can never run, so every send came back "busy" and waited.
    [Fact]
    public void LockedChatRefusalsAreKnown()
    {
        Assert.True(ChatSession.IsChatLocked(AsError(new Refuse(4001, "profile_mismatch", new JsonObject { ["reason"] = "profile_mismatch" }))));
        Assert.True(ChatSession.IsChatLocked(AsError(OwnerBusyRefusal())));
        Assert.False(ChatSession.IsChatLocked(AsError(OwnerBusyRefusal("a rewind or attachment cannot join its queue"))));
        Assert.False(ChatSession.IsChatLocked(AsError(new Refuse(4001, "runtime_draining", new JsonObject { ["reason"] = "runtime_draining" }))));
        Assert.False(ChatSession.IsChatLocked(AsError(OwnedRefusal("cli"))));
    }

    [Fact]
    public async Task LockedChatSendIsHandedBackWithNewChat()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit"
            ? throw new Refuse(4001, "profile_mismatch", new JsonObject { ["reason"] = "profile_mismatch" })
            : Loopback.Default(method, p, attempt));
        await rig.Ready();
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendAsync("hi").WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal("hi", rig.Drafts[0].Text);
        Assert.Equal(SessionProblemPrimary.NewChat, rig.Chat.SessionProblem?.Primary);
        Assert.Equal(SessionProblem.ChatLockedTitle, rig.Chat.SessionProblem?.Title);
        Assert.Null(rig.Chat.SendFailure);
        Assert.Single(rig.Socket.Calls("prompt.submit"));   // never resumed and resent: nothing can open it
    }

    [Fact]
    public async Task BusyWhoseHandOffKeepsBeingRefusedStopsWaiting()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Chat.LockedAfter = TimeSpan.FromMilliseconds(200);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw OwnerBusyRefusal() : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var sending = rig.Chat.SendAsync("hi");
        Assert.True(await Until(() => rig.Chat.OwnerWaitNotice == OwnerWait.RunningReply));   // a restart's drain refuses alike: wait first
        Assert.True(await Until(() => rig.Chat.SessionProblem?.Primary == SessionProblemPrimary.NewChat));
        Assert.Equal(SendOutcome.Refused, await sending.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal("hi", rig.Drafts[0].Text);
        Assert.Null(rig.Chat.OwnerWaitNotice);
        Assert.Null(rig.Chat.SendFailure);
    }

    [Fact]
    public async Task OwnerBusyPastTheWaitIsRefusedInPlainWords()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Chat.OwnerWaitWindow = TimeSpan.FromMilliseconds(200);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw OwnerBusyRefusal() : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var sending = rig.Chat.SendAsync("hi");
        Assert.True(await Until(() => rig.Chat.OwnerWaitNotice == OwnerWait.RunningReply));
        Assert.Equal(SendOutcome.Refused, await sending.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal("hi", rig.Drafts[0].Text);
        Assert.Null(rig.Chat.OwnerWaitNotice);
        Assert.Equal("Your message is still in the box below. Hermes is still running a reply in this chat. "
            + "Send it again when that reply is done.", rig.Chat.SendFailure?.Body);
        Assert.False(rig.Chat.Busy);
    }

    /// The gateway's queue may hold it already: a second copy would run, so it is never resent and never handed back.
    [Fact]
    public async Task OwnerUnconfirmedIsMarkedAndNeverResent()
    {
        await using var rig = new Rig(_stores);
        FastOwnerWait(rig.Chat);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit"
            ? throw new Refuse(4090, "The gateway is running a turn in this chat and did not confirm your message in time. "
                + "It may already be queued there: check the chat before sending it again.",
                new JsonObject { ["reason"] = "SESSION_OWNER_UNCONFIRMED" })
            : Loopback.Default(method, p, attempt));
        await rig.Ready();
        Assert.Equal(SendOutcome.Unconfirmed, await rig.Chat.SendAsync("hi").WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(ChatSession.UnconfirmedMark, LastUser(rig)?.Error);
        await Task.Delay(150);
        Assert.Single(rig.Socket.Calls("prompt.submit"));
        Assert.Empty(rig.Drafts);
        Assert.Null(rig.Chat.SendFailure);
        Assert.Null(rig.Chat.OwnerWaitNotice);
    }
}
