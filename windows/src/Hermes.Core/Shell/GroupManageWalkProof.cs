using Hermes.Core.Groups;

namespace Hermes.Core.Shell;

/// [WIN-46] The checks behind the group-manage walk (Services/ProofWalks.GroupManage.cs) on settings-gateway.py
/// --group-rooms's Launch Room (ivy, research; read, not pinned, muted or hidden): each answers null for what the Mac
/// shows and names what is wrong otherwise. The walk opens and shows; it writes nothing.
public static class GroupManageWalkProof
{
    public const string LaunchKey = GroupRoomWalkProof.LaunchKey;
    public const string LaunchTitle = GroupRoomWalkProof.LaunchTitle;

    /// The room row's right-click menu, its items in order with each one's enabled state.
    public static string? RowMenu(IReadOnlyList<(string Text, bool Enabled)> items)
    {
        string[] want = ["Group Info", "Pin", "Mute", "Mark as Unread", "Hide", "Delete Group Chat"];
        var texts = items.Select(i => i.Text).ToList();
        if (!texts.SequenceEqual(want)) return $"the room's menu reads {string.Join(" · ", texts)}";
        if (items.Any(i => !i.Enabled)) return $"{items.First(i => !i.Enabled).Text} is disabled";
        return null;
    }

    /// Group Info: its title, the room's name, its line, and the members by profile, in roster order.
    public static string? Info(string? title, string? name, string? subtitle, IReadOnlyList<string> members)
    {
        if (title != GroupInfoWords.Title) return $"the sheet is titled {title}";
        if (name != LaunchTitle) return $"the sheet names the room {name}";
        if (string.IsNullOrEmpty(subtitle)) return "the sheet has no line under the name";
        if (!members.SequenceEqual(["ivy", "research"])) return $"the members are {string.Join(", ", members)}";
        return null;
    }

    /// [WIN-51] Group Info's member rows, each with whether a face (BotHead) is drawn beside the name.
    public static string? Faces(IReadOnlyList<(string Profile, bool HasFace)> rows)
    {
        var members = rows.Select(r => r.Profile).ToList();
        if (!members.SequenceEqual(["ivy", "research"])) return $"the members are {string.Join(", ", members)}";
        if (rows.FirstOrDefault(r => !r.HasFace) is { Profile: { } bare }) return $"{bare} has no face beside it";
        return null;
    }

    /// [WIN-51] Name & Photo for Launch Room: its title, its line, the name field, the photo's buttons (Remove Photo only
    /// with a photo) and Save (on only with a change).
    public static string? NamePhoto(string? title, string? intro, string? name, bool hasPhoto, IReadOnlyList<string> buttons, bool saveEnabled)
    {
        if (title != GroupInfoWords.NameAndPhoto) return $"the page is titled {title}";
        if (intro != GroupInfoWords.RenameIntro) return $"the page's line reads {intro}";
        if (name != LaunchTitle) return $"the name field holds {name}";
        if (!buttons.Contains(GroupPhoto.ChoosePhoto)) return "there is no Choose Photo";
        if (hasPhoto && !buttons.Contains(GroupPhoto.RemovePhoto)) return "Remove Photo is missing with a photo";
        if (!hasPhoto && buttons.Contains(GroupPhoto.RemovePhoto)) return "Remove Photo shows with no photo";
        if (saveEnabled != hasPhoto) return saveEnabled ? "Save is on with nothing changed" : "Save is off with a new photo";
        return null;
    }

    /// The bots picker in edit mode for Launch Room: its title, its line, both members picked and locked at the floor.
    public static string? Picker(string? title, string? line, IReadOnlyList<(string Profile, bool Checked, bool Enabled)> bots, string? footer)
    {
        if (title != LaunchTitle) return $"the picker is titled {title}";
        if (line != GroupPickRules.Line(LaunchTitle)) return $"the picker's line reads {line}";
        var picked = bots.Where(b => b.Checked).Select(b => b.Profile).ToList();
        if (!picked.SequenceEqual(["ivy", "research"])) return $"the picks are {string.Join(", ", picked)}";
        if (bots.Any(b => b.Checked && b.Enabled)) return "a pick can be taken away at 2 bots";
        if (bots.Any(b => !b.Checked && !b.Enabled)) return "a bot can't be added";
        if (footer != GroupPickRules.FloorFooter) return $"the picker's footer reads {footer}";
        return null;
    }
}
