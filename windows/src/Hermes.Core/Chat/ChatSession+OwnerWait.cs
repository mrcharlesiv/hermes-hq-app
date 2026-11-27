// [WIN-OWNER-WAIT] A send refused because another Hermes process holds the chat waits for it and goes out when the chat
// is free (93f984bb1 HermesKit/Chat/LiveChatSession.swift `OwnerWait`, `ownerWaitNotice`, `ownerWaitCardDismissed`,
// the `ownerDeadline` part of the submit loop, `isOwnedElsewhere`/`isOwnerBusy`/`isOwnerUnconfirmed`/`isChatLocked`/
// `waitsForOwner`/`ownerWait`; LiveChatSession+External.swift `ownerPause`, `waitForOwner`; TurnErrorCopy.swift
// `SessionProblem.chatLocked`). Both send loops use it: the typed one (ChatSession.cs SendAsync) and the one with
// photos and files (ChatSession+Attachments.cs); a voice memo's submit (ChatSession+Memo.cs, as the Swift's
// `runMemoSend` ends in the same submit loop) uses it too.
//
// [WIN-EXTERNAL-TURN] The wait starts the external-turn watch (`checkExternalWork("send waits for the owner")`), and its
// pause ends early when the watch sees the holder's run end (`externalEnds`, ChatSession+External.cs).

using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Net;
using Hermes.Core.Rpc;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Chat;

/// Who holds the chat a send is waiting for (`OwnerWait`).
public enum OwnerWaitKind
{
    /// A one-shot `hermes chat` on the gateway computer: a scheduled job, or a message from another bot.
    BackgroundTask,
    /// Any other live runtime: a short wait, then "Couldn't Send" (never named as "your computer").
    OtherWindow,
    /// `4090 SESSION_OWNER_BUSY`: the gateway runs a turn here and couldn't queue yours behind it.
    RunningReply,
    /// A turn the messaging gateway runs for a message from Telegram, Discord or another platform.
    MessagingTurn,
}

/// The wait's holder, and for a messaging turn the platform's name (null when the holder names none).
public sealed record OwnerWait(OwnerWaitKind Kind, string? App = null)
{
    public static readonly OwnerWait BackgroundTask = new(OwnerWaitKind.BackgroundTask);
    public static readonly OwnerWait OtherWindow = new(OwnerWaitKind.OtherWindow);
    public static readonly OwnerWait RunningReply = new(OwnerWaitKind.RunningReply);
    public static OwnerWait MessagingTurn(string? app) => new(OwnerWaitKind.MessagingTurn, app);

    /// The chat's status line while the send waits.
    public string Status => Kind switch
    {
        OwnerWaitKind.BackgroundTask => "Waiting for a background task…",
        OwnerWaitKind.MessagingTurn => $"Waiting while Hermes answers {App ?? "another app"}…",
        OwnerWaitKind.OtherWindow => "Waiting for this chat to free up…",
        _ => "Waiting for the current reply…",
    };

    /// The holder in a send's trace line.
    public string LogWord => Kind switch
    {
        OwnerWaitKind.BackgroundTask => "one-shot run",
        OwnerWaitKind.OtherWindow => "elsewhere",
        OwnerWaitKind.RunningReply => "busy",
        _ => $"messaging turn {App ?? "?"}",
    };

    public const string CardTitle = "Your message is waiting";
    public const string CancelTitle = "Cancel Message";

    public string CardBody => Kind switch
    {
        OwnerWaitKind.BackgroundTask =>
            "Hermes is running a scheduled job or a message from another bot in this chat. Yours sends as soon as it’s done. You can keep typing.",
        OwnerWaitKind.OtherWindow =>
            "Hermes has this chat open somewhere else, like the Hermes desktop app or an earlier connection. Yours sends if it frees up in the next few seconds.",
        OwnerWaitKind.RunningReply =>
            "Hermes is still running a reply in this chat. Yours sends as soon as it’s done. You can keep typing.",
        _ => $"Hermes is answering a message from {App ?? "another app"} in this chat. Yours sends as soon as it’s done. You can keep typing.",
    };
}

public sealed partial class ChatSession
{
    /// A send refused because another Hermes process has this chat open: retried this often, for this long when the
    /// holder lets go on its own (a one-shot run, a messaging turn, a running reply), for the short window when it is a
    /// window or terminal someone keeps open.
    public TimeSpan OwnerRetryInterval { get; set; } = TimeSpan.FromSeconds(2);
    public TimeSpan OwnerWaitWindow { get; set; } = TimeSpan.FromSeconds(1200);
    public TimeSpan OwnerWaitShortWindow { get; set; } = TimeSpan.FromSeconds(30);
    /// [locked-chat] How long a send waits out "busy" refusals whose hand-off to the gateway's queue was itself refused
    /// before the chat is called locked (a restart's drain refuses the same way for up to a minute).
    public TimeSpan LockedAfter { get; set; } = TimeSpan.FromSeconds(120);

    private volatile OwnerWait? _waitingForOwner;
    private string? _ownerWaitSendId;
    private bool _ownerWaitCardDismissed;

    /// The send waiting for the chat's owner (`turn.waitingForOwner`): the status line says so while it waits.
    public OwnerWait? WaitingForOwner => _waitingForOwner;

    /// The waiting card (`ownerWaitNotice`): shown while a send waits; its ✕ hides it (the wait and the status stay).
    public OwnerWait? OwnerWaitNotice => _ownerWaitCardDismissed ? null : _waitingForOwner;

    /// The waiting card's ✕ (`dismissOwnerWait`); the next send's wait shows it again.
    public void DismissOwnerWait()
    {
        if (_ownerWaitCardDismissed) return;
        _ownerWaitCardDismissed = true;
        Changed?.Invoke();
    }

    /// The waiting card's Cancel Message (`cancelOwnerWait`): takes the message back like Stop.
    public Task CancelOwnerWaitAsync() => _waitingForOwner == null ? Task.CompletedTask : StopAsync();

    /// [locked-chat] A problem with the chat itself, docked above the composer (`sessionProblem`): set when the gateway
    /// won't open this chat any more (SessionProblem.ChatLocked, whose one action is a new chat with the same bot).
    public SessionProblem? SessionProblem { get; private set; }

    public void DismissSessionProblem()
    {
        if (SessionProblem == null) return;
        SessionProblem = null;
        Changed?.Invoke();
    }

    // ------------------------------------------------------------------ the refusals

    /// The `reason` in a JSON-RPC error's `data` (RpcConnection keeps `data` as the exception's Body).
    internal static string? RefusalReason(GatewayException e)
    {
        if (e.Body is not { Length: > 0 } body) return null;
        try { return JsonNode.Parse(body) is JsonObject o && o["reason"] is JsonValue v && v.TryGetValue(out string? s) ? s : null; }
        catch (System.Text.Json.JsonException) { return null; }
    }

    /// `4090` with reason `SESSION_NOT_OWNED`: another live process holds this chat.
    public static bool IsOwnedElsewhere(GatewayException e) =>
        RefusalReason(e) == "SESSION_NOT_OWNED" || TurnErrors.Owned.Test(e.Message);

    /// `4090` with reason `SESSION_OWNER_BUSY`: the gateway runs a turn here and its queue couldn't take this prompt.
    public static bool IsOwnerBusy(GatewayException e) => RefusalReason(e) == "SESSION_OWNER_BUSY";

    /// `4090` with reason `SESSION_OWNER_UNCONFIRMED`: the gateway's queue may hold it already; never resent.
    public static bool IsOwnerUnconfirmed(GatewayException e) => RefusalReason(e) == "SESSION_OWNER_UNCONFIRMED";

    /// [locked-chat] The gateway won't open this chat at all: `4001 profile_mismatch`, or a `SESSION_OWNER_BUSY` whose
    /// hand-off to the gateway's queue was itself refused.
    public static bool IsChatLocked(GatewayException e)
    {
        if (e.RpcCode == 4001 && (RefusalReason(e) == "profile_mismatch" || e.Message == "profile_mismatch")) return true;
        return e.RpcCode == 4090 && IsOwnerBusy(e) && TurnErrors.HandOffRefused.Test(e.Message);
    }

    /// A refusal the send waits out instead of failing at once.
    public static bool WaitsForOwner(GatewayException e) => e.RpcCode == 4090 && (IsOwnedElsewhere(e) || IsOwnerBusy(e));

    private static readonly Regex OneShot = new(@"opened by cli\b");
    private static readonly Regex Messaging = new(@"opened by gateway(?::([A-Za-z0-9_\-]+))?(?=[\s.]|$)");

    /// `ChatSource.label`'s names (`SOURCE_LABELS`); anything else in Title Case with `_`/`-` as spaces.
    private static readonly Dictionary<string, string> SourceLabels = new()
    {
        ["acp"] = "ACP", ["api_server"] = "API", ["bluebubbles"] = "iMessage", ["cli"] = "CLI", ["codex"] = "Codex",
        ["desktop"] = "Desktop", ["discord"] = "Discord", ["email"] = "Email", ["gateway"] = "Gateway", ["kanban"] = "Kanban",
        ["local"] = "Local", ["matrix"] = "Matrix", ["mattermost"] = "Mattermost", ["oneshot"] = "One-shot", ["photon"] = "Photon",
        ["qqbot"] = "QQ", ["signal"] = "Signal", ["slack"] = "Slack", ["sms"] = "SMS", ["telegram"] = "Telegram", ["tui"] = "TUI",
        ["webhook"] = "Webhook", ["weixin"] = "WeChat", ["whatsapp"] = "WhatsApp", ["yuanbao"] = "Yuanbao",
        ["homeassistant"] = "Home Assistant", ["wecom"] = "WeCom", ["dingtalk"] = "DingTalk", ["feishu"] = "Feishu",
    };

    private static string SourceLabel(string source)
    {
        var key = source.Trim().ToLowerInvariant();
        if (SourceLabels.TryGetValue(key, out var known)) return known;
        return string.Join(" ", key.Split(['_', '-'], StringSplitOptions.RemoveEmptyEntries).Select(w => char.ToUpperInvariant(w[0]) + w[1..]));
    }

    /// Who holds the chat a refused (4090) send waits for.
    public static OwnerWait OwnerWaitOf(GatewayException e)
    {
        if (IsOwnerBusy(e)) return OwnerWait.RunningReply;
        if (OneShot.IsMatch(e.Message)) return OwnerWait.BackgroundTask;
        if (Messaging.Match(e.Message) is { Success: true } m)
            return OwnerWait.MessagingTurn(m.Groups[1].Success ? SourceLabel(m.Groups[1].Value) : null);
        return OwnerWait.OtherWindow;
    }

    /// The pause before the next try while another run owns the chat: OwnerRetryInterval for the first three, then half
    /// again longer each time up to 4× (`ownerPause`).
    public TimeSpan OwnerPause(int tries) => OwnerRetryInterval * Math.Min(Math.Pow(1.5, Math.Max(0, tries - 3)), 4);

    // ------------------------------------------------------------------ one send's wait

    /// One send's wait for the chat's owner (the submit loop's `ownerDeadline`, `ownerTries`, `handOffRefusedSince`).
    private sealed class OwnerWaitRun(string localId, int epoch)
    {
        public readonly string LocalId = localId;
        public readonly int Epoch = epoch;
        public DateTimeOffset? Deadline;
        public int Tries;
        public DateTimeOffset? HandOffRefusedSince;
        public bool Waiting => Deadline != null;
    }

    /// What a send loop does with a refusal after the owner wait looked at it.
    private enum OwnerStep
    {
        /// Not an owner refusal: the loop's own cases (4001/4007, 4009, anything else) take it.
        NotOwner,
        /// The chat is free to try again (the wait goes on).
        Retry,
        /// Hand it back with this reason ("Couldn't Send").
        Refuse,
        /// [locked-chat] Hand it back on the problem card, not "Couldn't Send".
        Locked,
        /// The gateway's queue may hold it: "Delivery unconfirmed", never resent.
        Unconfirmed,
        /// Stop (or Cancel Message) came while it waited: it never goes out.
        Stopped,
    }

    private OwnerWaitRun BeginOwnerWaitRun(string localId)
    {
        _ownerWaitCardDismissed = false;
        return new OwnerWaitRun(localId, Volatile.Read(ref _stopEpoch));
    }

    /// The wait ends (sent, refused, or stopped): the status and the card go, unless a newer send's wait holds them.
    private void EndOwnerWait(OwnerWaitRun run)
    {
        if (run.Deadline == null) return;
        run.Deadline = null;
        if (_ownerWaitSendId == run.LocalId) { _waitingForOwner = null; _ownerWaitSendId = null; }
        Changed?.Invoke();
    }

    private bool StoppedSince(OwnerWaitRun run) => Volatile.Read(ref _stopEpoch) != run.Epoch;

    /// The owner wait's part of a send loop's refusal handling (the submit loop's `[locked-chat]` and `4090` cases):
    /// `photos`: the send carries photos (which can't wait in the gateway's queue). `reason` is what a Refuse says.
    private async Task<(OwnerStep Step, string Reason)> OwnerRefusalAsync(OwnerWaitRun run, GatewayException e, bool photos)
    {
        var now = DateTimeOffset.UtcNow;
        var locked = IsChatLocked(e);
        run.HandOffRefusedSince = locked ? run.HandOffRefusedSince ?? now : null;
        if (locked && (e.RpcCode != 4090 || now - run.HandOffRefusedSince >= LockedAfter))
        {
            EndOwnerWait(run);
            return (OwnerStep.Locked, e.Message);
        }
        if (e.RpcCode == 4090 && IsOwnerUnconfirmed(e)) { EndOwnerWait(run); return (OwnerStep.Unconfirmed, e.Message); }
        if (e.RpcCode == 4090 && IsOwnerBusy(e) && photos) { EndOwnerWait(run); return (OwnerStep.Refuse, e.Message); }
        if (!WaitsForOwner(e)) { EndOwnerWait(run); return (OwnerStep.NotOwner, e.Message); }
        if (run.Deadline == null)
        {
            var kind = OwnerWaitOf(e);
            run.Deadline = now + (kind.Kind == OwnerWaitKind.OtherWindow ? OwnerWaitShortWindow : OwnerWaitWindow);
            _ownerWaitSendId = run.LocalId;
            _waitingForOwner = kind;
            Changed?.Invoke();
            CheckExternalWork("send waits for the owner");   // [WIN-EXTERNAL-TURN] its steps show meanwhile
        }
        if (now >= run.Deadline)
        {
            EndOwnerWait(run);
            _ = RefreshQuietly();   // what the holder saved during the wait (`probeTailSoon`)
            return (OwnerStep.Refuse, e.Message);
        }
        run.Tries++;
        await SleepForOwnerAsync(OwnerPause(run.Tries), run);
        if (StoppedSince(run)) { EndOwnerWait(run); return (OwnerStep.Stopped, ""); }
        // The link away for now (offline, reconnecting): the wait goes on until it's back; a sign-out ends it
        // (`linkAwayForNow`: a sign-out is not away for now).
        while (_client.Rpc.State != ConnectionState.Open)
        {
            if (_client.Rpc.State == ConnectionState.SignedOut) { EndOwnerWait(run); return (OwnerStep.Refuse, SignedOutWords); }
            if (StoppedSince(run)) { EndOwnerWait(run); return (OwnerStep.Stopped, ""); }
            if (DateTimeOffset.UtcNow >= run.Deadline) { EndOwnerWait(run); return (OwnerStep.Refuse, e.Message); }
            await Task.Delay(TimeSpan.FromMilliseconds(100));
        }
        return (OwnerStep.Retry, "");
    }

    /// [WIN-SEND-NOTSENT-REFUSE] A try that never left (`GatewayException.IsNotConnected`) while the send waits for the
    /// chat's owner (LiveChatSession.swift's submit loop at 93f984bb1: `if let deadline = ownerDeadline, now < deadline,
    /// linkAwayForNow(error)`): the wait goes on and the send goes out once the link is back and the chat is free. Retry
    /// after `OwnerRetryInterval`; Stopped when Stop came meanwhile; NotOwner (no wait, past its deadline, or a sign-out)
    /// and the loop refuses it (nothing went out, so it is safe to send again).
    internal static bool KeepsWaitingWhileAway(DateTimeOffset? deadline, DateTimeOffset now, GatewayException e) =>
        deadline is { } until && now < until && GatewayException.LinkAwayForNow(e);

    private async Task<OwnerStep> OwnerLinkAwayAsync(OwnerWaitRun run, GatewayException e)
    {
        if (!KeepsWaitingWhileAway(run.Deadline, DateTimeOffset.UtcNow, e))
        {
            EndOwnerWait(run);
            return OwnerStep.NotOwner;
        }
        await Task.Delay(OwnerRetryInterval);
        if (StoppedSince(run)) { EndOwnerWait(run); return OwnerStep.Stopped; }
        return OwnerStep.Retry;
    }

    /// The refusal a sign-out during the wait hands the words back with.
    public const string SignedOutWords = "Sign in again.";

    /// Sleeps `pause`, or less (`waitForOwner`): the external-turn watch saw the other run end (the chat is free now), or
    /// Stop was pressed, so the waiting message goes (or comes back) at once.
    private async Task SleepForOwnerAsync(TimeSpan pause, OwnerWaitRun run)
    {
        var ends = ExternalEnds;
        var until = DateTimeOffset.UtcNow + pause;
        while (ExternalEnds == ends && !StoppedSince(run) && _client.Rpc.State != ConnectionState.SignedOut)
        {
            var left = until - DateTimeOffset.UtcNow;
            if (left <= TimeSpan.Zero) return;
            await Task.Delay(left < TimeSpan.FromMilliseconds(250) ? left : TimeSpan.FromMilliseconds(250));
        }
    }

    /// [locked-chat] One card: the problem card names the way on, so no "Couldn't Send" as well.
    private void ShowChatLocked(string detail)
    {
        SendFailure = null;
        SessionProblem = Transcripts.SessionProblem.ChatLocked(detail);
        Changed?.Invoke();
    }

    /// Stop came before a waiting send went out (`withdrawStoppedSend`): the bubble goes, the words come back, no card.
    private void WithdrawStoppedSend(string localId, string draft, string text)
    {
        lock (_lock)
        {
            _t.Withdraw(localId);
            if (_turnPrompt == text) { _turnPrompt = null; _turnStarted = null; }
        }
        Changed?.Invoke();
        DraftReturned?.Invoke(draft, StoppedBeforeSending);
    }
}
