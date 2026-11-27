// [WIN-UNDELIVERED-ACTIONS] What your bubble marked "Delivery unconfirmed" offers (spec 04 §2.5; 93f984bb1
// HermesKit/Chat/LiveChatSession+ChatActions.swift `sendAgain`, `deleteUndelivered`; LiveChatSession.swift
// `checkDelivery`): the read-only Check under it ("Delivery Unconfirmed · Check"), and Send Again and Delete in its menu
// (HermesKit/Chat/ChatActionsModel.swift: `ctx.undelivered`). Each clears the kept lost send (ClearLostSend,
// [sessions-m9]) exactly where the Mac does: Check only when it found the message, Send Again and Delete always.
// A restored lost send's bubble (RestoreLostSends) carries the same mark, so it offers the same three.

using Hermes.Core.Model;
using Hermes.Core.Net;

namespace Hermes.Core.Chat;

public sealed partial class ChatSession
{
    /// The line under an unconfirmed bubble, a button (App/Chat/ChatRow.swift); while its Check runs, not a button.
    public const string CheckDeliveryWords = "Delivery Unconfirmed · Check";
    public const string CheckingDeliveryWords = "Checking Delivery…";
    /// The line's automation id and its hint (App/Chat/Cells/ChatCells.swift).
    public const string CheckDeliveryId = "chat.delivery-check";
    public const string CheckDeliveryHint = "Checks whether " + Gateways.HostWord.Phrase + " got this message";
    /// What Check says when it didn't find it, and when it couldn't tell (ChatViewController `chatCellCheckDelivery`).
    public const string NotThereYetNotice = Gateways.HostWord.Sentence + " doesn’t have this message yet.";
    public const string CouldntCheckNotice = "Couldn’t check right now. Try again in a moment.";

    /// Your bubble offers Send Again and Delete: its send is marked and no longer pending (ChatMenus `ctx.undelivered`).
    public static bool IsUndelivered(ChatMessage m) => m.Role == Role.User && m.Error != null && !m.IsPending;

    private ChatMessage? UndeliveredMessage(string messageId)
    {
        lock (_lock)
        {
            var m = _t.Messages.LastOrDefault(x => x.Id == messageId);
            return m is { Role: Role.User, Error: not null } ? m : null;
        }
    }

    /// Send Again: the unconfirmed bubble goes, its kept lost send with it, and its words go out as a new send (whose
    /// own bubble may be marked again, and kept under its own id). Null when the message isn't your unconfirmed one.
    /// A plain send: never a rewind (no `truncate_before_row_id`).
    public Task<SendOutcome>? SendAgain(string messageId)
    {
        if (UndeliveredMessage(messageId) is not { } m) return null;
        var text = string.Join("\n", m.Parts.OfType<TextPart>().Select(p => p.Text));   // ChatTranscript.messageText
        lock (_lock) _t.Remove(messageId);
        ClearLostSend(messageId);                        // [sessions-m9]
        Changed?.Invoke();
        return SendAsync(text);
    }

    /// Delete: the unconfirmed bubble goes, and its Sessions row’s “Not Delivered:” with it. Only an unconfirmed send.
    public bool DeleteUndelivered(string messageId)
    {
        if (UndeliveredMessage(messageId) is null) return false;
        lock (_lock) _t.Remove(messageId);
        ClearLostSend(messageId);                        // [sessions-m9]
        Changed?.Invoke();
        return true;
    }

    /// The read-only Check: looks for the message in the newest stored rows, by its row id when one came back, else a
    /// user row past the last row known before it with the same words. True: delivered (the mark and the kept lost send
    /// go, and the chat is read again); false: not there; null: couldn't tell. Never resends.
    public async Task<bool?> CheckDeliveryAsync(string messageId, CancellationToken ct = default)
    {
        if (StoredId.Length == 0) return null;
        ChatMessage message;
        long knownRow;
        lock (_lock)
        {
            var messages = _t.Messages;
            var index = LostIndexOf(messages, messageId);
            if (index < 0) return null;
            message = messages[index];
            knownRow = messages.Take(index).Select(m => m.RowId ?? 0).DefaultIfEmpty(0).Max();
        }
        HistoryPage page;
        try { page = await _client.HistoryAsync(Profile, StoredId, 24, 0, ct); }
        catch (GatewayException) { return null; }
        // [WIN-SENT-TITLES] A titled request is stored as the request it stands for, not as its bubble's words.
        var sent = DisplayKey(SentTitles.Prompt(message.Text) ?? message.Text);
        var found = page.Messages.Any(row =>
        {
            if (row.Role != Role.User || row.RowId is not { } id) return false;
            if (message.RowId is { } mine) return id == mine;
            return id > knownRow && DisplayKey(row.Text) == sent;
        });
        if (found)
        {
            lock (_lock) _t.Revise(messageId, m => m with { Error = null });
            ClearLostSend(messageId);                    // [sessions-m9]
            Changed?.Invoke();
            _ = RefreshQuietly();                        // startRefresh(force: true)
        }
        return found;
    }
}
