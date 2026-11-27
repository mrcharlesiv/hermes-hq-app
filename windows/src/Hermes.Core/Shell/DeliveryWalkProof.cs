// [WIN-DELIVERY-WALK] What the chat-delivery walk (HermesHQ.Windows/Services/ProofWalks.Delivery.cs) sends, presses and
// checks over the real wire against windows/ci/fixtures/performance-fixture-gateway.py (build47-fixture-gateway.py's
// plans: a prompt.submit refused with JSON-RPC error data {reason}, the add-on's sessions/working ledger, a stored prompt
// another app wrote). The words are the Mac's, written out (93f984bb1):
//   App/Chat/ChatRow.swift, App/Chat/Cells/ChatCells.swift  "Delivery Unconfirmed · Check", `chat.delivery-check`
//   App/Chat/ChatViewController.swift `chatCellCheckDelivery` "\(HostWord.sentence) doesn’t have this message yet."
//   HermesKit/Chat/LiveChatSession.swift `OwnerWait` (.backgroundTask's status and card, "Cancel Message")
//   HermesKit/Chat/Transcript/TurnErrorCopy.swift `SessionProblem.chatLocked`
//   HermesKit/Chat/LiveChatSession.swift `computeStatus` "Working…" for ExternalTurn (another process's turn)
// Each check answers null when right, else what is wrong. The cards' automation ids are the Mac's (`chat.ownerWait`,
// `chat.problem`; Hermes.Core/Chat/ComposerNotices.cs).

using System.Text.Json.Nodes;
using Hermes.Core.Model;

namespace Hermes.Core.Shell;

public static class DeliveryWalkProof
{
    public const string Walk = "chat-delivery";
    /// The stand-in's tag in windows.yml's screenshot extras.
    public const string Tag = "delivery";
    public const string Bot = "default";
    /// The chat another app's turn runs in (the voice fixture's second bot, Sam).
    public const string ExternalBot = "sam";

    public const string StandIn = "/__fixture/state";
    public const string PlanPath = "/__fixture/plan";
    public const string FinishPath = "/__fixture/finish";
    /// The add-on's working ledger as the stand-in serves it (404 until this sets it).
    public const string WorkingPath = "/__fixture/working";
    /// A stored prompt another app wrote just now (no answer yet).
    public const string ExternalPath = "/__fixture/external";

    public const string UnconfirmedShot = "delivery-unconfirmed";
    public const string CheckNoticeShot = "delivery-check-notice";
    public const string OwnerWaitShot = "owner-wait";
    public const string LockedShot = "chat-locked";
    public const string WorkingShot = "external-working";
    /// The walk's own picture (windows.yml wants one per walk name): the waiting message sent and answered.
    public const string FinalShot = Walk;
    public static readonly IReadOnlyList<string> Shots = [UnconfirmedShot, CheckNoticeShot, OwnerWaitShot, LockedShot, WorkingShot];

    // ------------------------------------------------------------------ the Mac's words

    public const string CheckLine = "Delivery Unconfirmed · Check";
    public const string CheckId = "chat.delivery-check";
    public const string NotThere = "The computer running Hermes doesn’t have this message yet.";
    public const string OwnerWaitTitle = "Your message is waiting";
    public const string OwnerWaitBody =
        "Hermes is running a scheduled job or a message from another bot in this chat. Yours sends as soon as it’s done. You can keep typing.";
    public const string OwnerWaitCancel = "Cancel Message";
    public const string OwnerWaitStatus = "Waiting for a background task…";
    public const string LockedTitle = "This chat can’t take messages";
    public const string LockedBody =
        "Hermes won’t open this chat any more, so messages sent here can’t reach it. Your message is still in the box below. Continue in a new chat with the same bot.";
    public const string Working = "Working…";

    /// The two cards at the composer by the Mac's identifiers (ChatViewController's `ownerWaitCard`, `problemCard`).
    public const string OwnerWaitId = Hermes.Core.Chat.ComposerNotices.OwnerWaitId;
    public const string LockedId = Hermes.Core.Chat.ComposerNotices.ProblemId;
    /// [WIN-CHAT-LOCKED-ACTIONS] The locked card's one action (ChatNoticeCard.Content.title(.newChat)), before Copy.
    public const string LockedAction = "Continue in New Chat";

    // ------------------------------------------------------------------ what is sent (synthetic)

    public const string UnconfirmedText = "Synthetic delivery check note";
    public const string OwnerText = "Synthetic message that waits its turn";
    public const string OwnerReply = "Synthetic reply once the chat was free.";
    public const string LockedText = "Synthetic message to a locked chat";
    public const string ExternalText = "Synthetic prompt another app sent";
    /// Refusals before the waiting message goes: pauses of 2, 2, 2 and 3 s, so the card shows about 9 s.
    public const int OwnerRefusals = 4;
    /// A one-shot `hermes chat` holds the chat (`opened by cli`): the background task's long wait, not the 30 s one.
    public const string OwnedMessage = "Session is open in another Hermes process (opened by cli)";

    private static JsonObject Refusal(string message, int code, string reason) =>
        new() { ["reject"] = message, ["code"] = code, ["data"] = new JsonObject { ["reason"] = reason } };

    private static string Plans(params JsonObject[] plans) => new JsonObject { ["plans"] = new JsonArray([.. plans]) }.ToJsonString();

    public static string UnconfirmedPlan() => Plans(Refusal("Synthetic owner didn't confirm the prompt", 4090, "SESSION_OWNER_UNCONFIRMED"));

    public static string OwnerWaitPlan() =>
        Plans([.. Enumerable.Range(0, OwnerRefusals).Select(_ => Refusal(OwnedMessage, 4090, "SESSION_NOT_OWNED")),
            new JsonObject { ["replyText"] = OwnerReply }]);

    public static string LockedPlan() => Plans(Refusal("profile_mismatch", 4001, "profile_mismatch"));

    public static string ExternalBody() => new JsonObject { ["profile"] = ExternalBot, ["text"] = ExternalText }.ToJsonString();

    public static string WorkingBody(string storedId) => new JsonObject
    {
        ["sessions"] = new JsonArray(new JsonObject { ["profile"] = ExternalBot, ["id"] = storedId, ["status"] = "running", ["kind"] = "gateway" }),
    }.ToJsonString();

    public static string IdleBody() => """{"sessions":[]}""";

    // ------------------------------------------------------------------ the chat

    private static ChatMessage? Newest(IReadOnlyList<ChatMessage> messages, string text) =>
        messages.LastOrDefault(m => m.Role == Role.User && m.Text.Trim() == text);

    /// Your bubble with the note, marked and no longer sending (MessageView draws the Check line under it).
    public static string? Unconfirmed(IReadOnlyList<ChatMessage> messages)
    {
        if (Newest(messages, UnconfirmedText) is not { } m) return "unconfirmed: no bubble of yours says the note";
        if (m.IsPending) return "unconfirmed: the bubble is still sending";
        if (m.Error == null) return "unconfirmed: the bubble isn't marked";
        return null;
    }

    /// The line under it: a button with the automation id and the Mac's words.
    public static string? CheckButton(string? automationId, string? name)
    {
        if (automationId != CheckId) return $"check: the line's automation id is \"{automationId}\", not {CheckId}";
        if (name != CheckLine) return $"check: the line says \"{name}\", not \"{CheckLine}\"";
        return null;
    }

    /// The notice over the transcript after Check found nothing.
    public static string? Notice(string? shown) =>
        shown == null ? "notice: no notice shows"
        : shown != NotThere ? $"notice: it says \"{shown}\", not \"{NotThere}\"" : null;

    public static string? OwnerWaitCard(string? title, string? body, string? action)
    {
        if (title != OwnerWaitTitle) return $"owner wait: the card's title is \"{title}\"";
        if (body != OwnerWaitBody) return $"owner wait: the card's body is \"{body}\"";
        if (action != OwnerWaitCancel) return $"owner wait: the card's button is \"{action}\", not {OwnerWaitCancel}";
        return null;
    }

    /// The waiting message went once the chat was free: unmarked, answered.
    public static string? OwnerSent(IReadOnlyList<ChatMessage> messages)
    {
        var index = -1;
        for (var i = messages.Count - 1; i >= 0 && index < 0; i--)
            if (messages[i].Role == Role.User && messages[i].Text.Trim() == OwnerText) index = i;
        if (index < 0) return "owner wait: no bubble of yours says the waiting message";
        var m = messages[index];
        if (m.Error != null || m.IsPending) return "owner wait: the waiting message is marked or still sending";
        if (!messages.Skip(index + 1).Any(r => r.Role == Role.Assistant && !r.IsStreaming && r.Text.Trim() == OwnerReply))
            return "owner wait: no reply under the waiting message yet";
        return null;
    }

    /// The problem card's words, and the message back in the box.
    public static string? LockedCard(string? title, string? body, string? box)
    {
        if (title != LockedTitle) return $"locked: the card's title is \"{title}\"";
        if (body != LockedBody) return $"locked: the card's body is \"{body}\"";
        if (box?.Trim() != LockedText) return $"locked: the box says \"{box}\", not the message";
        return null;
    }

    /// The locked card's buttons as drawn, in order (the ✕ aside): Continue in New Chat, then Copy.
    public static string? LockedButtons(IReadOnlyList<string?> shown)
    {
        if (!shown.Contains(LockedAction))
            return shown.Count == 1 && shown[0] == "Copy" ? "locked: the card offers Copy only, not " + LockedAction
                : $"locked: the card's buttons are {string.Join(", ", shown.Select(s => $"\"{s}\""))}, not \"{LockedAction}\" and Copy";
        if (shown.Count != 2 || shown[0] != LockedAction || shown[1] != "Copy")
            return $"locked: the buttons' order is {string.Join(", ", shown.Select(s => $"\"{s}\""))}, not \"{LockedAction}\", \"Copy\"";
        return null;
    }

    /// The chat header's status line.
    public static string? Header(string? status) =>
        string.IsNullOrEmpty(status) ? "header: the status line says nothing"
        : status != Working ? $"header: the status line says \"{status}\", not \"{Working}\"" : null;

    // ------------------------------------------------------------------ the wire (the stand-in's ledger)

    private static List<JsonObject> Since(JsonNode? state, int mark, string text) =>
        (state.Arr("ledger") ?? []).Skip(mark).OfType<JsonObject>().Where(e => e.Str("text") == text).ToList();

    private static string? Reason(JsonObject entry) => entry["plan"]?["data"].Str("reason");

    /// Where the ledger stands now (each try appends one entry).
    public static int Mark(JsonNode? state) => state.Arr("ledger")?.Count ?? 0;

    /// One try, refused as SESSION_OWNER_UNCONFIRMED, never sent again (Check only reads).
    public static string? UnconfirmedWire(JsonNode? state, int mark)
    {
        var tries = Since(state, mark, UnconfirmedText);
        if (tries.Count == 0) return "unconfirmed: the note never reached the stand-in";
        if (tries.Count > 1) return $"unconfirmed: the note was resent ({tries.Count} tries)";
        if (tries[0].Bool("accepted") == true || Reason(tries[0]) != "SESSION_OWNER_UNCONFIRMED")
            return $"unconfirmed: its one try wasn't refused SESSION_OWNER_UNCONFIRMED ({Reason(tries[0])})";
        return null;
    }

    /// The refusals (SESSION_NOT_OWNED), then one accepted try.
    public static string? OwnerWire(JsonNode? state, int mark)
    {
        var tries = Since(state, mark, OwnerText);
        var refused = tries.TakeWhile(e => e.Bool("accepted") != true).ToList();
        if (refused.Count != OwnerRefusals || refused.Any(e => Reason(e) != "SESSION_NOT_OWNED"))
            return $"owner wait: {refused.Count} refused tries before it went, not {OwnerRefusals} SESSION_NOT_OWNED";
        var accepted = tries.Skip(refused.Count).ToList();
        if (accepted.Count == 0) return "owner wait: no try was accepted";
        if (accepted.Count > 1) return $"owner wait: the message went twice or more ({accepted.Count})";
        return null;
    }

    /// One try, refused 4001 profile_mismatch: no resume and resend.
    public static string? LockedWire(JsonNode? state, int mark)
    {
        var tries = Since(state, mark, LockedText);
        if (tries.Count == 0) return "locked: the message never reached the stand-in";
        if (tries.Count > 1) return $"locked: {tries.Count} tries, not one";
        if (Reason(tries[0]) != "profile_mismatch") return $"locked: refused for {Reason(tries[0])}";
        return null;
    }

    /// For a log line: what the ledger holds since `mark`.
    public static string Describe(JsonNode? state, int mark) =>
        string.Join(" | ", (state.Arr("ledger") ?? []).Skip(mark).OfType<JsonObject>()
            .Select(e => $"{e.Str("text")}:{(e.Bool("accepted") == true ? "accepted" : Reason(e) ?? "refused")}"));
}
