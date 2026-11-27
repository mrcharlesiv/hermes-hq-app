using Hermes.Core.Groups;

namespace Hermes.Core.Shell;

/// [WIN-41] The checks behind the group-room walk (Services/ProofWalks.GroupRoom.cs) on settings-gateway.py
/// --group-rooms's Launch Room (ivy, research): each answers null for what the Mac shows and names what is wrong otherwise.
public static class GroupRoomWalkProof
{
    public const string LaunchKey = "id:rfixture-launch";
    public const string LaunchTitle = "Launch Room";
    /// The walk's synthetic line; the stand-in's members answer "<Name> here: noted." to a line of yours.
    public const string Line = "Who has the release notes this week?";
    public const string StopLine = "And who takes the demo?";

    /// The room on screen: its title, the title's faces (the seated members), the sidebar row read.
    public static string? Opened(string? title, IReadOnlyList<string> faces, bool unread)
    {
        if (title != LaunchTitle) return $"the room is titled {title}";
        if (!faces.SequenceEqual(["ivy", "research"])) return $"the title's faces are {string.Join(", ", faces)}";
        if (unread) return "the room's row is still unread";
        return null;
    }

    /// The transcript after the send, top to bottom (the sender line each row shows, its role, its words): your line,
    /// then Ivy's and Research's replies under it, each under its own name.
    public static string? Replies(IReadOnlyList<(string? Sender, string Role, string Text)> rows)
    {
        var at = -1;
        for (var i = rows.Count - 1; i >= 0; i--) if (rows[i].Role == "user" && rows[i].Text == Line) { at = i; break; }
        if (at < 0) return $"no line of yours reads \"{Line}\"";
        foreach (var name in new[] { "Ivy", "Research" })
        {
            var words = $"{name} here: noted.";
            var reply = rows.Skip(at + 1).Where(r => r.Role == "assistant" && r.Text == words).ToList();
            if (reply.Count == 0) return $"no reply from {name} under the line";
            if (reply[0].Sender != name) return $"{name}'s reply shows the name \"{reply[0].Sender}\"";
        }
        return null;
    }

    /// Stop pressed while the second round runs: the room's Activity since that send has Stopped before any end of the
    /// round, the room no longer runs, and the composer is back to Send.
    public static string? StoppedMidRound(IReadOnlyList<GroupActivityKind> since, bool running, bool stopShown)
    {
        var stop = since.ToList().IndexOf(GroupActivityKind.Stopped);
        if (stop < 0) return $"the round was not stopped ({string.Join(", ", since)})";
        if (since.Take(stop).Any(k => k is GroupActivityKind.Settled or GroupActivityKind.Capped))
            return $"the round had ended before Stop ({string.Join(", ", since)})";
        if (running) return "the room still runs after Stop";
        if (stopShown) return "the composer still offers Stop";
        return null;
    }

    /// [WIN-52] The walk's Find in the room: the stand-in's members both answer "… here: noted.", so "noted" is found
    /// in each reply under the walk's line.
    public const string FindQuery = "noted";

    /// The typing rows while the second round runs (group-room-typing): one, naming a member that answers, with that
    /// member's face (its profile).
    public static string? Typing(IReadOnlyList<(string Label, string? Face)> rows)
    {
        if (rows.Count == 0) return "no typing row while the round runs";
        foreach (var (label, face) in rows)
        {
            var who = new[] { ("Ivy", "ivy"), ("Research", "research") }.FirstOrDefault(p => label == $"{p.Item1} is replying…");
            if (who.Item1 == null) return $"the typing row reads \"{label}\"";
            if (face != who.Item2) return $"{who.Item1}'s typing row wears the face {face ?? "none"}";
        }
        return null;
    }

    /// Find in the room (group-room-find): the bar counts what it found ("1 of N") and at least one match is painted.
    public static string? Found(string count, int matches)
    {
        if (matches < 2) return $"Find found {matches} match(es) for \"{FindQuery}\"";
        if (count != $"1 of {matches}" && !count.EndsWith($" of {matches}", StringComparison.Ordinal)) return $"the bar's count reads \"{count}\"";
        return null;
    }
}
