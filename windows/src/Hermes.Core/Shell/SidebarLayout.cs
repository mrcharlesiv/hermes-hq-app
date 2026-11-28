using Hermes.Core.Bots;

namespace Hermes.Core.Shell;

/// One place a sidebar row can open (the app's `Places` table, without its page type).
public sealed record PlaceInfo(string Id, string Title, bool IsTool);

/// The Mac sidebar's kept state and editing rules (App/Mac/MacSidebar.swift width and fold, MacBotsRail's named rail,
/// App/Mac/SidebarEditing.swift's Move Up / Move Down / Remove from Sidebar / Add to Sidebar / drag to reorder, which all
/// go through `TabOrder.tabs`). Kept per device, not per account.
public sealed class SidebarLayout
{
    /// The open sidebar's edge drags between these (device-independent pixels); the width is kept across launches.
    public const double NarrowestOpen = 200, WidestOpen = 520, DefaultOpenWidth = Settings.ChatVisualTokens.OpenWidth;
    /// The folded rail: faces alone (78 DIPs, matching Mac's 77.95 px so faces & working badges aren't clipped), or named.
    public const double CompactRailWidth = 78, NamedRailWidth = 120;
    /// The rail's edge, dragged past this, locks with names; pushed back under it, faces alone.
    public const double NamedRailThreshold = (CompactRailWidth + NamedRailWidth) / 2;

    public double OpenWidth { get; set; } = DefaultOpenWidth;
    /// Folded by the person (kept across launches).
    public bool Collapsed { get; set; }
    /// The rail shows each bot's name under its face.
    public bool RailNamed { get; set; }
    /// The places shown above Tools, in order. Null: the default (every non-tool place in table order).
    public List<string>? Order { get; set; }
    /// The bots in the sidebar (true) or a Bots row whose list opens beside it ([bots-place]); only the former is built.
    public bool BotsInSidebar { get; set; } = true;

    public static double ClampOpen(double width, double windowWidth = 0, double paneMin = 360)
    {
        var room = windowWidth > 0 ? windowWidth - paneMin : double.MaxValue;
        return Math.Max(NarrowestOpen, Math.Min(Math.Min(width, WidestOpen), room));
    }

    /// The rail's width while its edge is dragged settles to one of its two widths.
    public static (double Width, bool Named) SettleRail(double dragged) =>
        dragged >= NamedRailThreshold ? (NamedRailWidth, true) : (CompactRailWidth, false);

    public double RailWidth => RailNamed ? NamedRailWidth : CompactRailWidth;

    /// A window too narrow for the open sidebar and a pane folds it to its rail by itself (nothing saved).
    public static bool NarrowWindow(double windowWidth, double paneMin = 360) => windowWidth > 0 && windowWidth < NarrowestOpen + paneMin;

    // ---------------------------------------------------------------- the places' order (SidebarEditing)

    public List<string> Shown(IReadOnlyList<PlaceInfo> all)
    {
        var known = all.Select(p => p.Id).ToHashSet();
        return (Order ?? all.Where(p => !p.IsTool).Select(p => p.Id).ToList()).Where(known.Contains).Distinct().ToList();
    }

    /// The tools: every tool not moved up to the places (Settings has its own footer button and Ctrl+, window).
    public List<string> Tools(IReadOnlyList<PlaceInfo> all)
    {
        var shown = Shown(all).ToHashSet();
        return all.Where(p => p.IsTool && p.Id != SettingsPlaceId && !shown.Contains(p.Id)).Select(p => p.Id).ToList();
    }

    /// Add to Sidebar ▸: the places in neither the places nor Tools (a removed one).
    public List<PlaceInfo> Addable(IReadOnlyList<PlaceInfo> all)
    {
        var shown = Shown(all).ToHashSet();
        return all.Where(p => !p.IsTool && !shown.Contains(p.Id)).ToList();
    }

    /// Not the only place left.
    public bool CanRemove(string id, IReadOnlyList<PlaceInfo> all) => Shown(all) is var s && s.Contains(id) && s.Count > 1;

    public bool CanMove(string id, int step, IReadOnlyList<PlaceInfo> all)
    {
        var rows = Shown(all);
        var i = rows.IndexOf(id);
        return i >= 0 && i + step >= 0 && i + step < rows.Count;
    }

    public void Add(string id, IReadOnlyList<PlaceInfo> all)
    {
        var rows = Shown(all);
        if (rows.Contains(id)) return;
        rows.Add(id);
        Order = rows;
    }

    public void Remove(string id, IReadOnlyList<PlaceInfo> all)
    {
        if (!CanRemove(id, all)) return;
        Order = Shown(all).Where(x => x != id).ToList();
    }

    public void Move(string id, int step, IReadOnlyList<PlaceInfo> all)
    {
        if (!CanMove(id, step, all)) return;
        var rows = Shown(all);
        var i = rows.IndexOf(id);
        rows.RemoveAt(i);
        rows.Insert(i + step, id);
        Order = rows;
    }

    /// A dragged row dropped above `target`, or below the last row (null).
    public void MoveBefore(string id, string? target, IReadOnlyList<PlaceInfo> all)
    {
        if (target == id) return;
        var rows = Shown(all);
        if (!rows.Remove(id)) return;
        var at = target == null ? rows.Count : rows.IndexOf(target);
        rows.Insert(at < 0 ? rows.Count : at, id);
        Order = rows;
    }

    // ---------------------------------------------------------------- Settings › Appearance › Sidebar (TabOrderPage)

    /// The place that never joins the list: Settings is a window of its own (TabOrderPage.pageChoices, Mac polish #28).
    public const string SettingsPlaceId = "settings";

    /// Add to Sidebar's rows: every place not shown, removed places and Tools alike, in the table's order (the Mac's
    /// main tabs then More's pages), Settings left out.
    public List<PlaceInfo> AddRows(IReadOnlyList<PlaceInfo> all)
    {
        var shown = Shown(all).ToHashSet();
        return all.Where(p => !shown.Contains(p.Id) && p.Id != SettingsPlaceId).ToList();
    }

    /// The places are the default ones in the default order (Use Default Tabs then hides).
    public bool IsDefault(IReadOnlyList<PlaceInfo> all) =>
        Shown(all).SequenceEqual(all.Where(p => !p.IsTool).Select(p => p.Id));

    /// Use Default Tabs (`save(TabOrder.defaultTabs)`; the default is stored as nothing).
    public void UseDefault() => Order = null;

    /// The page's list after a drag: the shown rows in `order`; ids not shown are ignored, a shown row left out stays at the end.
    public void Arrange(IReadOnlyList<string> order, IReadOnlyList<PlaceInfo> all)
    {
        var shown = Shown(all);
        var next = order.Where(shown.Contains).Distinct().ToList();
        next.AddRange(shown.Where(id => !next.Contains(id)));
        Order = next;
    }

    /// The sidebar and Settings' Sidebar page follow each other's changes (`TabOrder.didChange`).
    public static event Action? Changed;
    public static void NotifyChanged() => Changed?.Invoke();

    public static SidebarLayout Load(IDeviceStore store) => DeviceJson.Load<SidebarLayout>(store, "sidebar");
    public void Save(IDeviceStore store) => DeviceJson.Save(store, "sidebar", this);
}

/// Groups sidebar tools into collapsible categories so the Windows sidebar does not render one flat 20-item wall.
public static class SidebarToolGroups
{
    public sealed record Group(string Key, string Title, IReadOnlyList<string> PlaceIds);

    private static readonly (string Key, string Title, string[] Ids)[] Definitions =
    [
        ("tools:work", "Productivity", ["quick-actions", "tasks", "kanban", "tiles"]),
        ("tools:workspace", "Workspace", ["files", "review", "terminal", "coding-pipeline", "project-repo"]),
        ("tools:monitor", "Monitor", ["command-center", "usage", "spawn-tree", "star-map"]),
        ("tools:setup", "Integrations", ["marketplace", "profiles", "messaging", "capabilities", "webhooks", "phone-calls", "import-sessions"]),
    ];

    public static bool IsToolsHeaderKey(string key) =>
        key == "tools" || key.StartsWith("tools:", StringComparison.Ordinal);

    public static List<Group> Partition(IReadOnlyList<string> toolIds)
    {
        var available = toolIds.ToHashSet(StringComparer.Ordinal);
        var assigned = new HashSet<string>(StringComparer.Ordinal);
        var groups = new List<Group>();
        foreach (var (key, title, ids) in Definitions)
        {
            var members = new List<string>();
            foreach (var id in ids)
            {
                if (available.Contains(id) && assigned.Add(id))
                    members.Add(id);
            }
            if (members.Count > 0)
                groups.Add(new Group(key, title, members));
        }
        var rest = toolIds.Where(id => !assigned.Contains(id)).ToList();
        if (rest.Count > 0)
            groups.Add(new Group("tools:other", "More Tools", rest));
        return groups;
    }
}
