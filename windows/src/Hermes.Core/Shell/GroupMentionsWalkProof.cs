using Hermes.Core.Groups;

namespace Hermes.Core.Shell;

/// [WIN-59] The checks behind the group-mentions walk (Services/ProofWalks.GroupMentions.cs) on settings-gateway.py
/// --group-rooms's Launch Room (ivy, research): "@Re" typed opens the @ list with Research alone; ↓ marks it; Tab or
/// Return puts "@research " in the box and closes the list; Esc closes it until the words change; the line sent asks
/// Research alone (GroupEngine.Responders). Each answers null for what the Mac shows and names what is wrong otherwise.
public static class GroupMentionsWalkProof
{
    public const string LaunchKey = GroupRoomWalkProof.LaunchKey;
    /// What the walk types into Launch Room's box.
    public const string Typed = "@Re";
    /// The box after Research is picked (GroupRoomChrome.swift `insertMention`: `@tag `).
    public const string Picked = "@research ";
    /// The words typed after the pick; the line sent is `Picked + Rest`.
    public const string Rest = "what's left before launch?";
    public const string Line = Picked + Rest;

    /// The list as "@Re" leaves it: open, Research alone (its name, `@research` under it, its face).
    public static string? Drawer(bool open, IReadOnlyList<GroupMentionList.Row> rows, IReadOnlyList<string?> faces)
    {
        if (!open) return "the @ list isn't showing";
        if (rows.Count != 1 || rows[0].Tag != "research") return $"the @ list offers {string.Join(", ", rows.Select(r => r.Tag))}";
        if (rows[0].Name != "Research" || rows[0].Detail != "@research") return $"Research's row reads \"{rows[0].Name}\" / \"{rows[0].Detail}\"";
        if (faces.Count != 1 || faces[0] != "research") return $"Research's row wears the face {(faces.Count > 0 ? faces[0] ?? "none" : "none")}";
        return null;
    }

    /// ↓ once: the first row (Research) marked, and drawn marked.
    public static string? Marked(int? marked, IReadOnlyList<GroupMentionList.Row> rows, int? drawnMarked)
    {
        if (marked != 0 || rows.Count == 0 || rows[0].Tag != "research") return $"↓ marked row {marked?.ToString() ?? "none"}";
        if (drawnMarked != 0) return $"the list draws row {drawnMarked?.ToString() ?? "none"} marked";
        return null;
    }

    /// A pick (Tab or Return): the box reads "@research ", the caret after it, the list closed.
    public static string? AfterPick(string text, int caret, bool open)
    {
        if (text != Picked) return $"the box reads \"{text}\"";
        if (caret != Picked.Length) return $"the caret is at {caret}, not after the tag";
        if (open) return "the @ list is still showing after the pick";
        return null;
    }

    /// Esc on the open list: it closes and the words stay; the next letter opens it again.
    public static string? Escaped(string text, bool openAfterEsc, bool openAfterTyping)
    {
        if (text != Typed) return $"Esc left the box reading \"{text}\"";
        if (openAfterEsc) return "Esc didn't close the @ list";
        if (!openAfterTyping) return "typing after Esc didn't open the @ list again";
        return null;
    }

    /// The line sent and its round settled: the room's Activity since your send asked Research and never Ivy, and the
    /// transcript has Research's reply under the line and none from Ivy.
    public static string? Addressed(IReadOnlyList<(GroupActivityKind Kind, string Member)> since, IReadOnlyList<(string? Sender, string Role, string Text)> rows)
    {
        if (!since.Any(a => a.Member == "research" && a.Kind == GroupActivityKind.Working)) return $"Research was not asked ({Kinds(since)})";
        if (since.Any(a => a.Member == "ivy")) return $"Ivy was asked too ({Kinds(since)})";
        var at = -1;
        for (var i = rows.Count - 1; i >= 0; i--) if (rows[i].Role == "user" && rows[i].Text == Line) { at = i; break; }
        if (at < 0) return $"no line of yours reads \"{Line}\"";
        var after = rows.Skip(at + 1).Where(r => r.Role == "assistant").ToList();
        if (!after.Any(r => r.Text == "Research here: noted." && r.Sender == "Research")) return "no reply from Research under the line";
        if (after.Any(r => r.Text == "Ivy here: noted.")) return "Ivy replied to a line for Research";
        return null;
    }

    private static string Kinds(IReadOnlyList<(GroupActivityKind Kind, string Member)> since) =>
        string.Join(", ", since.Select(a => a.Member.Length > 0 ? $"{a.Kind} {a.Member}" : a.Kind.ToString()));
}
