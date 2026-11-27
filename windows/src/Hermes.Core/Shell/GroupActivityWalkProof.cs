using Hermes.Core.Groups;

namespace Hermes.Core.Shell;

/// [WIN-57] The checks behind the group-room-activity walk (Services/ProofWalks.GroupActivity.cs) on
/// settings-gateway.py --group-rooms --quiet-room: Launch Room's ⋯ menu, its Activity after a round, the typing dots
/// moving while the round runs, and Quiet Room (no messages) as the empty room with an empty Activity. Each answers null
/// for what the Mac shows and names what is wrong otherwise.
public static class GroupActivityWalkProof
{
    public const string LaunchKey = GroupRoomWalkProof.LaunchKey;
    public const string QuietKey = "id:rfixture-quiet";
    public const string QuietTitle = "Quiet Room";
    /// Quiet Room's members as the empty room lists them (`GroupRowWords.MembersOrNone`).
    public const string QuietMembers = "Ivy, Research";
    public const string Line = "Who has the launch checklist?";

    /// The room's ⋯ (GroupRoomChrome.swift `moreItems`): Find in Chat, Group Info, …, Activity, …, Delete Group Chat.
    public static string? Menu(IReadOnlyList<string> ids)
    {
        string[] want = ["room.more.find", "room.more.info", "room.more.activity", "room.more.delete"];
        var at = want.Select(w => ids.ToList().IndexOf(w)).ToList();
        if (at.Any(i => i < 0)) return $"the room's ⋯ has {string.Join(", ", ids)}";
        if (!at.SequenceEqual(at.Order())) return $"the room's ⋯ is in the order {string.Join(", ", ids)}";
        return null;
    }

    /// Activity after a round: titled Activity, rows newest first (the last ends the round, the first is your send),
    /// each with a time, no empty note.
    public static string? Activity(string? title, IReadOnlyList<(string Text, string Time)> rows, bool emptyShown)
    {
        if (title != GroupActivitySheet.Title) return $"the sheet is titled {title}";
        if (emptyShown || rows.Count == 0) return "Activity shows no rows after a round";
        if (rows[^1].Text != "You sent a message") return $"the oldest row reads \"{rows[^1].Text}\", not your send";
        if (rows[0].Text == "You sent a message") return "the rows are oldest first";
        if (rows.FirstOrDefault(r => r.Time.Length == 0) is { Text: { } untimed }) return $"\"{untimed}\" has no time";
        return null;
    }

    /// Activity in a room that has said nothing: titled Activity, no rows, the Mac's note.
    public static string? EmptyActivity(string? title, IReadOnlyList<(string Text, string Time)> rows, string? emptyText)
    {
        if (title != GroupActivitySheet.Title) return $"the sheet is titled {title}";
        if (rows.Count > 0) return $"an empty room's Activity shows {rows.Count} rows";
        if (emptyText != GroupActivitySheet.Empty) return $"the empty Activity reads \"{emptyText}\"";
        return null;
    }

    /// Quiet Room on screen: the empty room (RoomEmptyView) with its name, its members and the hint.
    public static string? EmptyRoom(bool shown, string? name, string? members, string? hint)
    {
        if (!shown) return "the empty room isn't showing";
        if (name != QuietTitle) return $"the empty room is named {name}";
        if (members != QuietMembers) return $"the empty room lists \"{members}\"";
        if (hint != GroupRoomChrome.EmptyHint) return $"the empty room's hint reads \"{hint}\"";
        return null;
    }

    /// The typing row's dots while a round runs: with animations on, each dot's wave runs and its clock moved between
    /// two looks (`before`/`after`, seconds into the wave's clock); with animations off, none runs (still at 60 %).
    public static string? DotsMoving(bool animationsEnabled, IReadOnlyList<bool> running, IReadOnlyList<double> before, IReadOnlyList<double> after)
    {
        if (running.Count != TypingDots.Count) return $"the typing row has {running.Count} dots";
        if (!TypingDots.Animates(animationsEnabled))
            return running.Any(r => r) ? "the dots move with animations off" : null;
        if (running.Any(r => !r)) return "a typing dot's wave isn't running";
        if (before.Count != after.Count || before.Zip(after).Any(p => Math.Abs(p.First - p.Second) < 1e-6)) return "a typing dot's wave stood still";
        return null;
    }
}
