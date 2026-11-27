using Hermes.Core.Groups;

namespace Hermes.Core.Bots;

// [groups] Group chats in the Bots list and the sidebar (App/Bots/BotListModel.swift `BotListSection.rows`,
// App/Bots/BotListSections.swift `BotListLayout.file` / `flat`, App/Bots/BotsViewController.swift `composeSections`,
// App/Mac/MacBotsRail.swift `Item`): where each room goes among the bots' blocks, and the order a block draws its bots
// and rooms in. Pure.

/// One head of a block: a bot, or a group chat (`MacBotsRail.Item`).
public sealed record BotListHead(BotRow? Bot, GroupRowModel? Room)
{
    /// Unique across both kinds: a room's key is not a bot's profile name (`Item.key`).
    public string Key => Bot?.Id ?? RoomKey(Room!.Id);
    public string Name => Bot?.Name ?? Room!.Name;
    public static string RoomKey(string key) => "room:" + key;
}

public static class BotListRooms
{
    /// The Group Chats block's heading.
    public const string GroupChatsTitle = "Group Chats";

    /// [bots-groupby] A block's bots and rooms in drawing order: the two lists merged by activity (a bot's last activity
    /// in seconds, a room's last message in milliseconds), each kind keeping its own order; a tie goes to the bot.
    public static List<BotListHead> Rows(BotListSection section)
    {
        var o = new List<BotListHead>(section.Bots.Count + section.Rooms.Count);
        int b = 0, r = 0;
        while (b < section.Bots.Count && r < section.Rooms.Count)
        {
            var bot = section.Bots[b];
            var room = section.Rooms[r];
            if (bot.Time >= room.LastAt / 1000) { o.Add(new BotListHead(bot, null)); b++; }
            else { o.Add(new BotListHead(null, room)); r++; }
        }
        for (; b < section.Bots.Count; b++) o.Add(new BotListHead(section.Bots[b], null));
        for (; r < section.Rooms.Count; r++) o.Add(new BotListHead(null, section.Rooms[r]));
        return o;
    }

    /// `composeSections` under Show › All with no search: pinned rooms are tiles after the bots' tiles (the rest of the
    /// pins with the Pinned rows); with a user section each room is filed in its section or Unassigned
    /// (`BotListLayout.file`); without one the rooms are a Group Chats block before Hidden; Group By › None (`groupByNone`)
    /// makes one block of every bot and room by activity (`BotListLayout.flat`). Hidden rooms go under Hidden.
    /// `records`: the device's user sections, in order. Also the Group Chats header's count.
    public static (List<BotListSection> Sections, int GroupCount) Compose(IReadOnlyList<BotListSection> bots, IReadOnlyList<GroupRowModel> rooms,
        IReadOnlyList<RosterSectionRecord> records, bool groupByNone = false, bool draggingRoom = false)
    {
        var sections = bots.ToList();
        if (rooms.Count == 0) return (sections, 0);
        var botTiles = sections.FirstOrDefault(s => s.Block == BotBlock.Tiles)?.Bots.Count ?? 0;
        var known = records.Where(r => r.Id != RosterRules.PinnedSectionId).Select(r => (r.Id, r.Name)).ToList();
        var plan = GroupList.Make(rooms, RosterRules.MaxTiles - botTiles, known, draggingRoom);
        if (plan.Tiles.Count > 0)
        {
            var at = sections.FindIndex(s => s.Block == BotBlock.Tiles);
            if (at >= 0) sections[at] = sections[at] with { Rooms = plan.Tiles };
            else sections.Insert(0, new BotListSection(BotBlock.Tiles, null, null, []) { Rooms = plan.Tiles });
        }
        if (plan.Hidden.Count > 0)
        {
            var at = sections.FindIndex(s => s.Block == BotBlock.Hidden);
            if (at >= 0) sections[at] = sections[at] with { Rooms = plan.Hidden };
            else sections.Add(new BotListSection(BotBlock.Hidden, null, "Hidden", []) { Rooms = plan.Hidden });
        }
        var pinned = plan.Overflow;
        var pinnedIds = pinned.Select(r => r.Id).ToHashSet();
        var loose = plan.Loose.Where(r => !pinnedIds.Contains(r.Id)).ToList();
        if (groupByNone) return (Flat(sections, [.. plan.Loose, .. plan.FiledSections.SelectMany(f => f.Rooms)]), plan.Count);
        if (File(sections, loose, [.. plan.FiledSections.Select(f => (f.Id, f.Rooms))], pinned) is { } filed) return (filed, plan.Count);
        if (plan.Loose.Count > 0 || plan.FiledSections.Count > 0)
        {
            var blocks = new List<BotListSection> { new(BotBlock.Groups, null, GroupChatsTitle, []) { Rooms = plan.Loose } };
            blocks.AddRange(plan.FiledSections.Select(f => new BotListSection(BotBlock.GroupSection, f.Id, f.Name, []) { Rooms = f.Rooms }));
            var at = sections.FindIndex(s => s.Block == BotBlock.Hidden);
            sections.InsertRange(at < 0 ? sections.Count : at, blocks);
        }
        return (sections, plan.Count);
    }

    /// `BotListLayout.file`: with a user section, each filed room joins its section, the rest Unassigned (titled so, made
    /// before Hidden when only rooms are left), pins past the tiles the Pinned section (made after the tiles). null
    /// without a user section (the Group Chats block stays).
    public static List<BotListSection>? File(IReadOnlyList<BotListSection> sections, IReadOnlyList<GroupRowModel> loose,
        IReadOnlyList<(string Id, IReadOnlyList<GroupRowModel> Rooms)> filed, IReadOnlyList<GroupRowModel>? pinned = null)
    {
        if (!sections.Any(s => s.Block == BotBlock.User)) return null;
        var o = sections.ToList();
        if (pinned is { Count: > 0 })
        {
            var at = o.FindIndex(s => s.Block == BotBlock.Pinned);
            if (at >= 0) o[at] = o[at] with { Rooms = [.. o[at].Rooms, .. pinned] };
            else
            {
                var tiles = o.FindIndex(s => s.Block == BotBlock.Tiles);
                o.Insert(tiles + 1, new BotListSection(BotBlock.Pinned, RosterRules.PinnedSectionId, RosterRules.PinnedSectionName, []) { Rooms = pinned });
            }
        }
        foreach (var (id, rooms) in filed)
        {
            var at = o.FindIndex(s => s.Block == BotBlock.User && s.SectionId == id);
            if (at >= 0) o[at] = o[at] with { Rooms = [.. o[at].Rooms, .. rooms] };
        }
        var un = o.FindIndex(s => s.Block == BotBlock.Unassigned);
        if (un >= 0) o[un] = o[un] with { Title = BotList.UnassignedName, Rooms = [.. o[un].Rooms, .. loose] };
        else if (loose.Count > 0)
        {
            var hidden = o.FindIndex(s => s.Block == BotBlock.Hidden);
            o.Insert(hidden < 0 ? o.Count : hidden, new BotListSection(BotBlock.Unassigned, null, BotList.UnassignedName, []) { Rooms = loose });
        }
        return o;
    }

    /// `BotListLayout.flat`, Group By › None: the tiles stay on top and Hidden at the bottom; every other bot and room is
    /// one block with no heading, newest activity first (rooms by their last message, then name).
    public static List<BotListSection> Flat(IReadOnlyList<BotListSection> sections, IReadOnlyList<GroupRowModel> loose)
    {
        var bots = new List<BotRow>();
        var rooms = loose.ToList();
        var o = new List<BotListSection>();
        foreach (var s in sections)
        {
            if (s.Block is BotBlock.Tiles or BotBlock.Hidden) { o.Add(s); continue; }
            bots.AddRange(s.Bots);
            rooms.AddRange(s.Rooms);
        }
        var byActivity = bots.Select((b, i) => (b, i)).OrderByDescending(x => x.b.Time).ThenBy(x => x.i).Select(x => x.b).ToList();
        var sortedRooms = rooms.OrderByDescending(r => r.LastAt).ThenBy(r => r.Name, StringComparer.Ordinal).ToList();
        if (byActivity.Count == 0 && sortedRooms.Count == 0) return o;
        var everything = new BotListSection(BotBlock.Everything, null, null, byActivity) { Rooms = sortedRooms };
        var at = o.FindIndex(s => s.Block == BotBlock.Hidden);
        o.Insert(at < 0 ? o.Count : at, everything);
        return o;
    }

    /// A room's rail face mark (`MacBotsRailHead.configuration`): the working badge while a round runs, else the unread dot.
    public enum FaceMark { None, Working, Unread }

    public static FaceMark Mark(GroupRowModel room) => room.Running ? FaceMark.Working : room.Unread ? FaceMark.Unread : FaceMark.None;

    /// The open sidebar row's line under the name (`describe`): "Working…" while a round runs, else none.
    public static string? Status(GroupRowModel room) => room.Running ? "Working…" : null;

    /// The rail's peek line (`peekLine`): the row's second line, or "No messages yet".
    public static string PeekLine(GroupRowModel room) => room.Line.Trim() is { Length: > 0 } line ? line : "No messages yet";

    /// The row read aloud in the sidebar and the rail (`describe`): no time.
    public static string AccessibilityLabel(GroupRowModel room) =>
        GroupRowWords.AccessibilityLabel(room.Name, room.Line, "", room.Unread, room.Pinned, room.Muted);
}
