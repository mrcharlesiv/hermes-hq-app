using System.Globalization;

namespace Hermes.Core.Groups;

// [groups] Where rooms go in the list (App/Groups/GroupListPlan.swift; docs/spec/3x-groups.md §7.1, §7.9, §7.11): pinned
// rooms as tiles after the bots' tiles, then the Group Chats block — rooms in no section first, then one sub-block per
// user section that holds rooms (an empty one only while a room is being dragged). Also the Show › filter. Pure.

/// Filter › Show (`S/ui-bots/roster-filters.ts:12-18`), for this session.
public enum BotKindFilter { All, Bots, Groups }

/// Filter › Activity (App/Bots/BotsBarModel.swift `BotActivityFilter`).
public enum BotActivityFilter { All, Active, Recent, Older }

public static class GroupFilters
{
    /// `BotsBar.recentWindow`: seven days.
    public static readonly TimeSpan RecentWindow = TimeSpan.FromDays(7);

    public static string Title(this BotKindFilter f) => f switch { BotKindFilter.Bots => "Bots", BotKindFilter.Groups => "Group Chats", _ => "All" };

    public static string Title(this BotActivityFilter f) => f switch
    {
        BotActivityFilter.Active => "Active Now", BotActivityFilter.Recent => "Recently Active", BotActivityFilter.Older => "Older", _ => "Any Time",
    };

    /// A room under Activity (`HB/row-helpers.ts`): Active Now = a round is running; Recently Active = a message in the
    /// last 7 days; Older = none.
    public static bool Matches(this BotActivityFilter f, GroupRowModel room, DateTimeOffset now)
    {
        if (f == BotActivityFilter.All) return true;
        if (f == BotActivityFilter.Active) return room.Running;
        var recent = room.LastAt > 0 && now.ToUnixTimeMilliseconds() / 1000.0 - room.LastAt / 1000 <= RecentWindow.TotalSeconds;
        return f == BotActivityFilter.Recent ? recent : !recent;
    }

    /// The token under the bar: the active filters joined in the web's order ("Group Chats · Active Now").
    public static string? Token(BotKindFilter kind, BotActivityFilter activity)
    {
        var parts = new[] { kind == BotKindFilter.All ? null : kind.Title(), activity == BotActivityFilter.All ? null : activity.Title() }.OfType<string>().ToList();
        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }

    public static bool FiltersActive(BotKindFilter kind, BotActivityFilter activity) => kind != BotKindFilter.All || activity != BotActivityFilter.All;
}

/// The list's sections a dragged room can be over (App/Bots `BotListSectionID`, the cases a room reads).
public abstract record BotListSectionId
{
    public sealed record Tiles : BotListSectionId;
    public sealed record Pinned : BotListSectionId;
    public sealed record Hidden : BotListSectionId;
    public sealed record Results : BotListSectionId;
    public sealed record Everything : BotListSectionId;
    public sealed record Groups : BotListSectionId;
    public sealed record GroupSection(string Id) : BotListSectionId;
    public sealed record User(string Id) : BotListSectionId;
    public sealed record Unassigned : BotListSectionId;
}

public static class GroupList
{
    public sealed record Filed(string Id, string Name, IReadOnlyList<GroupRowModel> Rooms, bool Hint);

    public sealed class Plan
    {
        public List<GroupRowModel> Tiles { get; set; } = [];
        /// Directly under the Group Chats header: pins the grid could not take first, then rooms in no section.
        public List<GroupRowModel> Loose { get; set; } = [];
        /// The pins the grid could not take (also first in `Loose`).
        public List<GroupRowModel> Overflow { get; set; } = [];
        public List<Filed> FiledSections { get; set; } = [];
        /// Hidden rooms (UX study #254): under Hidden, after the hidden bots.
        public List<GroupRowModel> Hidden { get; set; } = [];
        /// The header's count: every room of the block.
        public int Count => Loose.Count + FiledSections.Sum(f => f.Rooms.Count);
        public bool IsEmpty => Tiles.Count == 0 && Loose.Count == 0 && FiledSections.Count == 0;
    }

    private static readonly CompareInfo Compare = CultureInfo.InvariantCulture.CompareInfo;

    /// By the user's order when set, else newest message first; names break ties.
    public static List<GroupRowModel> Sorted(IEnumerable<GroupRowModel> rooms)
    {
        var list = rooms.ToList();
        list.Sort((a, b) =>
        {
            switch (a.Order, b.Order)
            {
                case ({ } x, { } y) when x != y: return x.CompareTo(y);
                case ({ }, null): return -1;
                case (null, { }): return 1;
            }
            if (a.LastAt != b.LastAt) return b.LastAt.CompareTo(a.LastAt);
            return Compare.Compare(a.Name, b.Name, CompareOptions.IgnoreCase);
        });
        return list;
    }

    /// `freeTiles`: slots the bots' tiles left in the grid. `sections`: the device's user sections, in order.
    public static Plan Make(IEnumerable<GroupRowModel> all, int freeTiles, IReadOnlyList<(string Id, string Name)> sections, bool draggingRoom)
    {
        var list = all.ToList();
        var plan = new Plan { Hidden = Sorted(list.Where(r => r.Hidden)) };
        var rooms = list.Where(r => !r.Hidden).ToList();
        var pinned = rooms.Where(r => r.Pinned).OrderBy(r => r.PinnedAt ?? 0).ThenBy(r => r.Name, StringComparer.Ordinal).ToList();
        plan.Tiles = [.. pinned.Take(Math.Max(0, freeTiles))];
        plan.Overflow = [.. pinned.Skip(Math.Max(0, freeTiles))];
        var rest = Sorted(rooms.Where(r => !r.Pinned));
        var known = sections.Select(s => s.Id).ToHashSet();
        // A room whose section was deleted shows in "no section" again.
        plan.Loose = [.. plan.Overflow, .. rest.Where(r => r.SectionId == null || !known.Contains(r.SectionId))];
        foreach (var (id, name) in sections)
        {
            var members = rest.Where(r => r.SectionId == id).ToList();
            if (members.Count > 0 || draggingRoom) plan.FiledSections.Add(new Filed(id, name, members, members.Count == 0));
        }
        return plan;
    }

    /// Search (the room's name and its members' names) and Activity, in list order.
    public static List<GroupRowModel> Results(IEnumerable<GroupRowModel> rooms, string query, BotActivityFilter activity, DateTimeOffset now)
    {
        var words = query.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return [.. Sorted(rooms).Where(room => activity.Matches(room, now)
            && words.All(w => Compare.IndexOf(room.Search, w, CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace) >= 0))];
    }

    /// Where a dragged room may drop (§7.11): the Group Chats header clears its section; a room sub-block files it; a
    /// user section files it and Unassigned clears it; the tiles, Pinned and Hidden refuse it. null = not a target;
    /// `Section(null)` = clear its section.
    public sealed record Drop(string? Section);

    public static Drop? DropFor(bool room, BotListSectionId? over) => !room ? null : over switch
    {
        BotListSectionId.Groups => new Drop(null),
        BotListSectionId.GroupSection g => new Drop(g.Id),
        BotListSectionId.User u => new Drop(u.Id),
        BotListSectionId.Unassigned => new Drop(null),
        _ => null,
    };

    public const string DropHint = "Drop a group chat here.";
}
