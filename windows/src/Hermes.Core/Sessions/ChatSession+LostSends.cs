// [WIN-LOST-SEND-MARKER] The chat's side of a send that may never have arrived (93f984bb1 HermesKit/Chat/LostSends.swift,
// `extension LiveChatSession`): a typed send marked "Delivery unconfirmed" is kept for its Sessions row ("Not
// Delivered: <words>"); a history read that shows it arrived clears it quietly. Kept beside the store it feeds (this
// card may touch Hermes.Core/Sessions and the unconfirmed branches only).
// [WIN-LOST-SEND-RESTORE] `restoreLostSends`: after each history read the marked bubble comes back where it was said
// (Transcript.Insert). [WIN-UNDELIVERED-ACTIONS] Check, Send Again and Delete clear here through ClearLostSend
// (Chat/ChatSession+Undelivered.cs: `checkDelivery`, `sendAgain`, `deleteUndelivered`). [WIN-SENT-TITLES] The gateway's
// inflight prompt clears it too (Chat/ChatSession+SentTitles.cs GraftInflight, the Sync fold's `graftInflightTurn`).

using Hermes.Core.Model;
using Hermes.Core.Sessions;

namespace Hermes.Core.Chat;

public sealed partial class ChatSession
{
    /// Where a send that may never have arrived is kept for its Sessions row; the app sets it (HermesClient.LostSends),
    /// null keeps nothing (`lostSends`).
    public LostSends? LostSends { get; set; }

    /// The id the Sessions row knows this chat by.
    private string? LostSendChatId => StoredId.Length > 0 ? StoredId : null;

    /// A visible text send was marked "Delivery unconfirmed": its row says "Not Delivered:". Voice memos keep their own
    /// drafts and are not kept (the Mac's `guard !memo`).
    internal void NoteLostSend(string localId, bool memo)
    {
        if (LostSends is not { } lost || memo || LostSendChatId is not { } chatId) return;
        LostSends.Entry entry;
        lock (_lock)
        {
            var messages = _t.Messages;
            var index = LostIndexOf(messages, localId);
            if (index < 0 || messages[index].Role != Role.User) return;
            var numbered = messages.Take(index).Select(m => m.RowId).Where(r => r != null).Max();
            // Earlier messages with no stored row number yet: "after row 0" would let any older message with the same
            // words (a "yes") pass for this one, so the send's own time is the test instead (LostSendArrived). A new
            // chat has nothing earlier, so row 0 holds there.
            var known = numbered ?? (index == 0 ? 0 : null);
            entry = new LostSends.Entry(localId, messages[index].Text, messages[index].Timestamp ?? DateTimeOffset.Now, known);
        }
        lost.Note(_client.AccountId, Profile, chatId, entry);
    }

    /// The mark cleared: Check found it, the gateway holds it, Send Again, Delete (ChatSession+Undelivered.cs).
    internal void ClearLostSend(string messageId)
    {
        if (LostSends is not { } lost || LostSendChatId is not { } chatId) return;
        lost.Clear(_client.AccountId, Profile, chatId, messageId);
    }

    /// A page was merged into the transcript: an entry whose bubble lost its mark, or whose words are now a stored row
    /// past the rows the chat knew when it was sent, did arrive; it goes quietly. Stored row numbers, never the two clocks.
    public void SettleLostSends()
    {
        if (LostSends is not { } lost || LostSendChatId is not { } chatId) return;
        foreach (var entry in lost.Entries(_client.AccountId, Profile, chatId))
        {
            bool settled;
            lock (_lock)
            {
                var messages = _t.Messages;
                var index = LostIndexOf(messages, entry.Id);
                settled = index >= 0 ? messages[index].Error == null : LostSendArrived(messages, entry);
            }
            if (settled) lost.Clear(_client.AccountId, Profile, chatId, entry.Id);
        }
    }

    /// [WIN-LOST-SEND-RESTORE] A history page landed: every lost send this screen does not show (the chat was left, or
    /// the app was closed, since) comes back as your bubble with its mark, where it was said, unless the page shows it
    /// arrived (`restoreLostSends`). Its new id is "local-user-lost-" and 8 hex digits, and the entry follows it (Rekey).
    /// Windows' page read (Transcript.ReplaceWithHistory) leaves such a bubble out rather than at the end, so a later
    /// read puts it back here again, at its place in that page, under the same id. Returns whether any came back.
    public bool RestoreLostSends()
    {
        if (LostSends is not { } lost || LostSendChatId is not { } chatId) return false;
        SettleLostSends();
        var restored = 0;
        var rekeys = new List<(string From, string To)>();
        lock (_lock)
        {
            foreach (var entry in lost.Entries(_client.AccountId, Profile, chatId))
            {
                if (LostIndexOf(_t.Messages, entry.Id) >= 0) continue;
                var id = entry.Id.StartsWith(Transcript.LostPrefix, StringComparison.Ordinal)
                    ? entry.Id
                    : Transcript.LostPrefix + Guid.NewGuid().ToString("N")[..8];
                var bubble = new ChatMessage(id, Role.User, [new TextPart(entry.Text)], entry.At, Error: UnconfirmedMark);
                _t.Insert(bubble, LostSendPlace(_t.Messages, entry));
                restored++;
                if (id != entry.Id) rekeys.Add((entry.Id, id));
            }
        }
        foreach (var (from, to) in rekeys) lost.Rekey(_client.AccountId, Profile, chatId, from, to);
        return restored > 0;
    }

    /// Where a lost send's bubble goes back: before the first stored row past the rows the chat knew when it was sent;
    /// without that, before the first message stamped later than it; else at the end (`lostSendPlace`).
    public int LostSendPlace(LostSends.Entry entry)
    {
        lock (_lock) return LostSendPlace(_t.Messages, entry);
    }

    internal static int LostSendPlace(IReadOnlyList<ChatMessage> messages, LostSends.Entry entry)
    {
        int index;
        if (entry.After is { } after && after > 0)
            index = LostIndexWhere(messages, m => (m.RowId ?? 0) > after);
        else
            index = LostIndexWhere(messages, m => m.Timestamp is { } at && at > entry.At);
        return index < 0 ? messages.Count : index;
    }

    private static bool LostSendArrived(IReadOnlyList<ChatMessage> messages, LostSends.Entry entry)
    {
        var words = DisplayKey(entry.Text);
        return messages.Any(m =>
        {
            if (m.Role != Role.User || m.RowId is not { } row || DisplayKey(m.Text) != words) return false;
            if (entry.After is { } after) return row > after;
            return m.Timestamp is { } at && at >= entry.At.AddSeconds(-5);
        });
    }

    /// The words as a bubble shows them, for comparing a send with a stored row (`Hydration.userDisplayKey`: whitespace
    /// runs folded, ends trimmed).
    internal static string DisplayKey(string text) =>
        string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    private static int LostIndexOf(IReadOnlyList<ChatMessage> messages, string id) => LostIndexWhere(messages, m => m.Id == id);

    private static int LostIndexWhere(IReadOnlyList<ChatMessage> messages, Func<ChatMessage, bool> match)
    {
        for (var i = 0; i < messages.Count; i++) if (match(messages[i])) return i;
        return -1;
    }
}
