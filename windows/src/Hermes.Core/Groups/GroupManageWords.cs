using Hermes.Core.Bots;

namespace Hermes.Core.Groups;

// [groups] The words and rules of a room's management screens, apart from the screens (unit tests read them):
// App/Groups/GroupActions.swift (the row menu, Delete Group Chat's question, New Group Chat's reason),
// App/Groups/AddToGroupController.swift (GroupJoinRules), App/Groups/GroupBotsPicker.swift (GroupPickRules) and
// App/Groups/GroupInfoSheet.swift (Group Info's lines).

public static class GroupManageWords
{
    public static string CouldNotCreate(string name) => $"Couldn’t Create {name}";
    public static string CouldNotRename(string name) => $"Couldn’t Rename {name}";
    public static string CouldNotChangeBots(string name) => $"Couldn’t Change {name}’s Bots";
    public static string CouldNotChangeGroupChats(string bot) => $"Couldn’t Change {bot}’s Group Chats";
    public static string CouldNotDelete(string name) => $"Couldn’t Delete {name}";

    public const string DeleteMessage = "The group chat and its messages are removed. The bots and their own chats are kept. This can’t be undone.";
    public static string DeleteTitle(string name) => $"Delete “{name}”?";
    public const string DeleteAction = "Delete Group Chat";
    public const string Offline = "Your gateway is offline";

    /// The Compose menu's New Group Chat is disabled with a reason: the gateway is offline, or fewer than 2 bots shown.
    public static string? NewGroupDisabledReason(int shownBots, bool online)
    {
        if (!online) return Offline;
        return shownBots < GroupLimits.MinMembers ? "Needs at least 2 bots" : null;
    }

    public const string NewGroupChat = "New Group Chat";
    public const string AddToGroupChat = "Add to Group Chat…";
}

/// One item of a room's row menu, in the Mac's order.
public sealed record GroupMenuItem(string Id, string Title)
{
    public bool Destructive { get; init; }
    public bool Enabled { get; init; } = true;
    /// The reason under a disabled item.
    public string? Subtitle { get; init; }
    /// Mute's durations (a submenu).
    public IReadOnlyList<MuteChoice> Durations { get; init; } = [];
    /// Drawn after a separator (the destructive inline group).
    public bool Separated { get; init; }
}

public static class GroupRowMenu
{
    /// Mute's durations as a bot's menu offers them.
    public static readonly IReadOnlyList<MuteChoice> MuteDurations = [MuteChoice.Hour, MuteChoice.Hours8, MuteChoice.Week, MuteChoice.Always];

    /// Group Info · Pin · Mute · Mark as Unread · Hide (Show in Bots) · Delete Group Chat, in that order (`menuNodes`).
    public static IReadOnlyList<GroupMenuItem> Items(GroupRowModel room, bool writable)
    {
        var items = new List<GroupMenuItem> { new("info", "Group Info") };
        // A hidden room offers no Pin, as a hidden bot's menu doesn't (review of #254).
        if (!room.Hidden || room.Pinned) items.Add(new("pin", room.Pinned ? "Unpin" : "Pin"));
        items.Add(room.Muted ? new("mute", "Unmute") : new("mute", "Mute") { Durations = MuteDurations });
        items.Add(new("unread", room.Unread ? "Mark as Read" : "Mark as Unread"));
        items.Add(new("hide", room.Hidden ? "Show in Bots" : "Hide"));
        items.Add(new("delete", GroupManageWords.DeleteAction)
        {
            Destructive = true, Enabled = writable, Subtitle = writable ? null : GroupManageWords.Offline, Separated = true,
        });
        return items;
    }

    /// Hide's Undo pill.
    public const string HiddenLabel = "Hidden";
    public const string HiddenWayBack = "Find it under Hidden, below your bots.";
}

/// The rules of a room's switch for one bot (AddToGroupController.swift `GroupJoinRules`).
public static class GroupJoinRules
{
    public enum State { Open, Full, Floor }

    public static State Of(bool member, int count)
    {
        if (!member && count >= GroupLimits.MaxMembers) return State.Full;
        if (member && count <= GroupLimits.MinMembers) return State.Floor;
        return State.Open;
    }

    public static string Subtitle(bool member, int count) => Of(member, count) switch
    {
        State.Full => "Full (6 bots)",
        State.Floor => "Needs at least 2 bots",
        _ => GroupRowWords.Bots(count),
    };

    /// Remove from All Group Chats shows when the bot is in at least one room and leaving drops none below 2.
    public static bool CanRemoveAll(IReadOnlyCollection<int> memberCounts) =>
        memberCounts.Count > 0 && memberCounts.All(c => c > GroupLimits.MinMembers);

    public static string EmptyLine(string bot, bool anyRooms) => anyRooms
        ? $"{bot} isn’t in any of these group chats yet. Turn one on, or name a new one."
        : $"{bot} isn’t in any group chats yet. Name one below to create it.";

    public static string Title(string bot) => $"{bot} · Groups";
    public const string Intro = "A bot can be in several group chats.";
    public const string NewName = "New group chat…";
    public const string CreateAndJoin = "Create and Join";
    public const string RemoveAll = "Remove from All Group Chats";
    public static string RemoveAllTitle(string bot) => $"Remove {bot} from all group chats?";
    public const string RemoveAllMessage = "The group chats and their history are kept.";
}

/// The bots picker's rules (GroupBotsPicker.swift `GroupPickRules`).
public static class GroupPickRules
{
    public const string LimitFooter = "A group chat can have up to 6 bots.";
    public const string FloorFooter = "A group chat needs at least 2 bots, so none can be removed.";

    public enum Tap { Added, Removed, Full, Locked }

    /// What a tap on a bot does to the picks. In edit mode a pick cannot be taken away while only 2 remain.
    public static (List<string> Picked, Tap Result) Toggle(string profile, IReadOnlyList<string> picked, bool editing)
    {
        if (picked.Contains(profile))
        {
            if (editing && picked.Count <= GroupLimits.MinMembers) return ([.. picked], Tap.Locked);
            return ([.. picked.Where(p => p != profile)], Tap.Removed);
        }
        if (picked.Count >= GroupLimits.MaxMembers) return ([.. picked], Tap.Full);
        return ([.. picked, profile], Tap.Added);
    }

    public static bool CanCreate(int count) => count >= GroupLimits.MinMembers && count <= GroupLimits.MaxMembers;

    /// The name field's placeholder: the picked bots' names, or `Group name` with none.
    public static string Placeholder(IReadOnlyList<string> names) => names.Count == 0 ? "Group name" : string.Join(", ", names);

    /// A bot matches a search by name, profile or role, case-insensitive.
    public static bool Matches(string name, string id, string? role, string query)
    {
        var needle = query.Trim().ToLowerInvariant();
        if (needle.Length == 0) return true;
        return name.ToLowerInvariant().Contains(needle) || id.ToLowerInvariant().Contains(needle)
            || (role?.ToLowerInvariant().Contains(needle) ?? false);
    }

    public static string Line(string? editingRoom) => editingRoom == null
        ? "Pick 2–6 bots to talk together."
        : $"Pick 2–6 bots for “{editingRoom}”. The group chat and its history stay as they are.";

    public static string Title(string? editingRoom) => editingRoom ?? GroupManageWords.NewGroupChat;
    public static string Save(bool editing) => editing ? "Save" : "Create";
    public const string Search = "Search bots to add…";
    public static string None(string query) => query.Trim().Length == 0 ? "No bots yet." : $"No bots match “{query.Trim()}”.";

    /// The footer under the list: the limit when full, the floor in edit mode at 2.
    public static string? Footer(int count, bool editing) =>
        count >= GroupLimits.MaxMembers ? LimitFooter : editing && count <= GroupLimits.MinMembers ? FloorFooter : null;
}

/// Group Info's lines (GroupInfoSheet.swift).
public static class GroupInfoWords
{
    public const string Title = "Group Info";
    public const string Members = "Members";
    public const string GroupChat = "Group Chat";
    public const string NameAndPhoto = "Name & Photo";
    public const string Notifications = "Notifications";
    public const string MuteNotifications = "Mute Notifications";
    public const string Organize = "Organize";
    public const string Pinned = "Pinned";
    public const string ShowInBots = "Show in Bots";
    public const string Floor = "A group chat needs at least 2 bots, so none can be removed.";
    public const string OfflineFooter = "You can change this group chat again once your gateway is back.";
    public const string RenameIntro = "Rename the group chat or change its group photo. Members and history are kept.";
    public const string GroupName = "Group name";

    public static string Unread(bool unread) => unread ? "Mark as Read" : "Mark as Unread";
    public static string EditBots(bool floor) => floor ? "Add Bots" : "Edit Bots";
    public static string MuteTile(bool muted) => muted ? "Unmute" : "Mute";
    public static string SaveTitle(bool saving) => saving ? "Saving…" : "Save";

    /// The header's second line: the row's line when it says something (replying, offline), else the bot count.
    public static string Subtitle(GroupRowModel? row, int seats) =>
        row != null && row.Tone != GroupRowWords.Tone.Secondary ? row.Line : GroupRowWords.Bots(seats);

    /// A member's second line: what it is doing, where it lives, else its role.
    public static string? MemberLine(GroupSeat seat, GroupRoom? room, string? role)
    {
        if (seat.Remote) return string.IsNullOrEmpty(seat.RemoteLabel) ? "On another gateway" : $"On {seat.RemoteLabel}";
        if (room is { Running: true } && room.Turn?.Name == seat.Name) return "Replying…";
        if (seat.Missing) return "Can’t reach this bot";
        return string.IsNullOrEmpty(role) ? null : role;
    }

    public static bool IsFloor(int seats) => seats <= GroupLimits.MinMembers;
}
