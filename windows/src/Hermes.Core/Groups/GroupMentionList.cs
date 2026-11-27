namespace Hermes.Core.Groups;

// [groups] [WIN-59] A room's @ suggestions above the composer (App/Groups/GroupRoomChrome.swift: `updateMentions`,
// `closeMentions`, `insertMention`, RoomMentionList `set` / `key` / `pickMarked`). Pure: the Windows room page
// (Pages/GroupRoomPage.Mentions.cs) draws the rows and routes the message box's keys here.
// The list takes the message field's list keys, as a bot chat's drawer does (Mac polish #16): ↑ / ↓ mark a row, Tab
// picks it (or the first), Return picks a marked one, Escape closes the list and keeps the words until they change.
public sealed class GroupMentionList
{
    /// RoomMentionList's accessibility identifier; each row is `room.mention.<tag>`.
    public const string ListId = "room.mentions";
    public const string EveryoneTag = "everyone";
    public const string EveryoneName = "@everyone";
    public const string EveryoneDetail = "Every bot in this group chat";

    /// `RoomMentionList.Row`: the tag a pick inserts, the name and the line under it, the member's face (none for
    /// @everyone, which wears the two-people symbol).
    public sealed record Row(string Tag, string Name, string Detail, ChatSender? Sender)
    {
        public string AutomationId => "room.mention." + Tag;
        /// RoomMentionRow's VoiceOver label.
        public string Spoken => $"{Name}, {Detail}";
    }

    /// `ComposerTextView.DrawerKey`.
    public enum DrawerKey { Down, Up, Tab }

    /// The rows a room offers for the text up to the caret (`updateMentions`): nothing unless an @word is being typed
    /// (GroupMentions.TypingQuery); @everyone, then each member (`@tag` under its name); narrowed to the tags that start
    /// with the word or the names that hold it.
    public static IReadOnlyList<Row> RowsFor(string caretText, IReadOnlyList<(string Tag, string Name, ChatSender? Sender)> choices)
    {
        if (GroupMentions.TypingQuery(caretText) is not { } query) return [];
        List<Row> all = [new(EveryoneTag, EveryoneName, EveryoneDetail, null), .. choices.Select(c => new Row(c.Tag, c.Name, "@" + c.Tag, c.Sender))];
        return query.Length == 0 ? all
            : [.. all.Where(r => r.Tag.ToLowerInvariant().StartsWith(query, StringComparison.Ordinal) || r.Name.ToLowerInvariant().Contains(query, StringComparison.Ordinal))];
    }

    public IReadOnlyList<Row> Rows { get; private set; } = [];
    /// The row ↑ / ↓ marked (Tab and Return pick it); typing starts over, as in the drawer.
    public int? Marked { get; private set; }
    public bool IsOpen => Rows.Count > 0;
    /// The words Escape closed the list on: it stays closed until they change, as the drawer does.
    private string? _closedFor;

    /// `RoomMentionList.set`: true when the rows changed (the mark goes with them).
    public bool Set(IReadOnlyList<Row> next)
    {
        if (next.SequenceEqual(Rows)) return false;
        Rows = next;
        Marked = null;
        return true;
    }

    /// The box's words changed (`updateMentions`): `text` is all of them, `caretText` those up to the caret. true when
    /// the list changed.
    public bool Update(string text, string caretText, IReadOnlyList<(string Tag, string Name, ChatSender? Sender)> choices)
    {
        if (text != _closedFor) _closedFor = null;
        return Set(_closedFor == null ? RowsFor(caretText, choices) : []);
    }

    /// Escape in the box (`closeMentions`): true when the list was open and is now closed for these words.
    public bool Escape(string text)
    {
        if (!IsOpen) return false;
        _closedFor = text;
        Set([]);
        return true;
    }

    /// `RoomMentionList.key`: ↓ marks the first row, then the next (stopping at the last); ↑ the one before, or none from
    /// the first; Tab picks the marked row, or the first. Answers the tag picked, else null.
    public string? Key(DrawerKey key)
    {
        if (Rows.Count == 0) return null;
        switch (key)
        {
            case DrawerKey.Down: Marked = Marked is { } m ? Math.Min(m + 1, Rows.Count - 1) : 0; return null;
            case DrawerKey.Up:
                if (Marked is not { } marked) return null;
                Marked = marked == 0 ? null : marked - 1;
                return null;
            default: return Rows[Math.Min(Marked ?? 0, Rows.Count - 1)].Tag;
        }
    }

    /// Return with a row marked picks it (its tag); else null, and Return does what it always does.
    public string? PickMarked() => Marked is { } m && m >= 0 && m < Rows.Count ? Rows[m].Tag : null;

    /// `insertMention`: `@tag ` at the caret, in place of the @word being typed when it came from the list (else after a
    /// space when the words before don't end in one, as the hold menu's Mention). The space after it is not doubled.
    /// Answers the new text and the caret after the inserted tag.
    public static (string Text, int Caret) Insert(string text, int caret, string tag, bool replacingQuery)
    {
        caret = Math.Clamp(caret, 0, text.Length);
        var head = text[..caret];
        var tail = text[caret..];
        var at = head.LastIndexOf('@');
        if (replacingQuery && at >= 0) head = head[..at];
        else if (head.Length > 0 && !char.IsWhiteSpace(head[^1])) head += " ";
        var insert = $"@{tag} ";
        return (head + insert + (tail.StartsWith(' ') ? tail[1..] : tail), head.Length + insert.Length);
    }
}
