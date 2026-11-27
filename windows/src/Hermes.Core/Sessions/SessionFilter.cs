namespace Hermes.Core.Sessions;

/// What the Filter & Sort menu is drawn from (HermesKit's SessionFilterState).
public sealed class SessionFilterState
{
    public SessionsViewPrefs Prefs { get; set; } = new();
    public bool ShowBackgroundRuns { get; set; }
    public string? BotFilter { get; set; }
    public List<SessionProjectEntry> Projects { get; set; } = [];
    public int BotCount { get; set; } = 1;
    public bool AnySpend { get; set; }
    public bool HasUnread { get; set; }
}

/// The menu's words and its derived counts (SessionFilterWords.swift, docs/spec/3x-sessions.md §5.3).
public static class SessionFilterWords
{
    public static string Name(SessionSortBy s) => s switch
    {
        SessionSortBy.Updated => "Updated", SessionSortBy.Created => "Created", SessionSortBy.Status => "Status",
        SessionSortBy.Tokens => "Tokens", _ => "Cost",
    };

    public static string Name(SessionGroupBy g) => g switch
    {
        SessionGroupBy.Date => "Recent", SessionGroupBy.Project => "Project", SessionGroupBy.Bot => "Bot", _ => "Status",
    };

    public static string Name(SessionRowDetail d) => d switch
    {
        SessionRowDetail.Time => "Time", SessionRowDetail.Preview => "Preview", SessionRowDetail.Tokens => "Tokens", _ => "Cost",
    };

    public static string Name(SessionStatus s) => s switch
    {
        SessionStatus.NeedsInput => "Needs Input", SessionStatus.Working => "Working", SessionStatus.Unread => "Unread",
        SessionStatus.Draft => "Draft", _ => "Idle",
    };

    public static HashSet<string> EffectiveProjects(SessionFilterState s) =>
        s.Prefs.ProjectFilter.Intersect(s.Projects.Select(p => p.Key)).ToHashSet();

    /// The project pills are no filter: a picked pill is not counted.
    public static HashSet<string> CountedProjects(SessionFilterState s) => s.Prefs.Pills == SessionPills.Projects ? [] : EffectiveProjects(s);

    /// Status filters + projects (Archived and Background Runs are not counted).
    public static int FilterCount(SessionFilterState s) => s.Prefs.StatusFilter.Count + CountedProjects(s).Count;

    public static bool FiltersActive(SessionFilterState s) => FilterCount(s) > 0 || s.BotFilter != null || EffectiveProjects(s).Count > 0;

    public static string ButtonLabel(SessionFilterState s)
    {
        var count = FilterCount(s);
        return count == 0 ? "Filter and Sort" : $"Filter and Sort, {count} {(count == 1 ? "filter" : "filters")} on";
    }

    /// The strip under the bar while a filter is on: "Unread · Working", "Project", "3 Filters".
    public static string? StripText(SessionFilterState s)
    {
        var projects = CountedProjects(s).Count;
        var names = Enum.GetValues<SessionStatus>().Where(s.Prefs.StatusFilter.Contains).Select(Name).ToList();
        if (projects > 0) names.Add(projects == 1 ? "Project" : $"{projects} Projects");
        if (names.Count == 0) return null;
        return names.Count <= 2 ? string.Join(" · ", names) : $"{names.Count} Filters";
    }

    public static string Picked(IReadOnlyList<string> names, string none = "Any") =>
        names.Count == 0 ? none : names.Count > 2 ? $"{names.Count} Selected" : string.Join(", ", names);

    public static List<SessionRowDetail> DetailOptions(SessionFilterState s) =>
        Enum.GetValues<SessionRowDetail>().Where(d => d != SessionRowDetail.Cost || s.AnySpend || s.Prefs.RowDetail.Contains(SessionRowDetail.Cost)).ToList();

    public static List<SessionSortBy> SortOptions(SessionFilterState s) =>
        Enum.GetValues<SessionSortBy>().Where(o => o != SessionSortBy.Cost || s.AnySpend || s.Prefs.SortBy == SessionSortBy.Cost).ToList();

    public static List<SessionGroupBy> GroupOptions(SessionFilterState s) => Enum.GetValues<SessionGroupBy>().Where(o => o switch
    {
        SessionGroupBy.Project => s.Projects.Count > 0 || s.Prefs.GroupBy == SessionGroupBy.Project,
        SessionGroupBy.Bot => s.BotCount > 1 || s.Prefs.GroupBy == SessionGroupBy.Bot,
        _ => true,
    }).ToList();

    public static string DetailSubtitle(SessionFilterState s) =>
        Picked(DetailOptions(s).Where(s.Prefs.ShownDetail.Contains).Select(Name).ToList(), "None");
    public static string StatusSubtitle(SessionFilterState s) =>
        Picked(Enum.GetValues<SessionStatus>().Where(s.Prefs.StatusFilter.Contains).Select(Name).ToList());
    public static string? ProjectSubtitle(SessionFilterState s) => s.Projects.Count == 0 ? null
        : Picked(s.Projects.Where(p => s.Prefs.ProjectFilter.Contains(p.Key)).Select(p => p.Label).ToList());
    public static string ShowSubtitle(SessionFilterState s)
    {
        var on = new[] { s.ShowBackgroundRuns ? "Background Runs" : null, s.Prefs.ShowArchived ? "Archived" : null }.OfType<string>().ToList();
        if (on.Count <= 1) return on.FirstOrDefault() ?? "Chats";
        return string.Join(", ", on.Select(w => w.Split(' ')[0]));
    }
    public static string GroupSubtitle(SessionFilterState s) => SessionListPipeline.IsFlat(s.Prefs) ? "None" : Name(s.Prefs.GroupBy);
}

public enum SessionFilterActionKind
{
    Sort, Group, Detail, Status, Project, NewProject, AllBots, Runs, Archived, BotFaces, ProjectChatsInRecent, ShowProjects, Clear, ReadAll,
}

/// One pick in the menu.
public sealed record SessionFilterAction(SessionFilterActionKind Kind, object? Value = null);

/// A menu row: an action (with a check), a submenu, or an inline group with a separator.
public sealed record SessionFilterNode(string Id, string Title)
{
    public string? Subtitle { get; init; }
    public bool Checked { get; init; }
    public bool Disabled { get; init; }
    public SessionFilterAction? Action { get; init; }
    /// A submenu (`Single`: a radio group) or an inline group (`Inline`).
    public List<SessionFilterNode>? Children { get; init; }
    public bool Single { get; init; }
    public bool Inline { get; init; }
}

/// The Filter & Sort menu (§5.2): Sort By, Group By, Row Detail | Status, Project, All Bots ✓, Show | Clear Filters or
/// Mark All as Read.
public static class SessionFilterMenu
{
    public static List<SessionFilterNode> Nodes(SessionFilterState state)
    {
        var p = state.Prefs;
        SessionFilterNode Check(string id, string title, bool on, SessionFilterAction a) => new(id, title) { Checked = on, Action = a };
        var sort = new SessionFilterNode("sessions.filter.sort", "Sort By")
        {
            Subtitle = SessionFilterWords.Name(p.SortBy), Single = true,
            Children = SessionFilterWords.SortOptions(state).Select(o => new SessionFilterNode($"sessions.filter.sort.{o}", SessionFilterWords.Name(o))
            { Checked = o == p.SortBy, Action = new(SessionFilterActionKind.Sort, o) }).ToList(),
        };
        var group = new SessionFilterNode("sessions.filter.group", "Group By")
        {
            Subtitle = SessionFilterWords.GroupSubtitle(state), Single = true,
            Children = SessionFilterWords.GroupOptions(state).Select(o => new SessionFilterNode($"sessions.filter.group.{o}", SessionFilterWords.Name(o))
            { Checked = o == p.GroupBy, Disabled = SessionListPipeline.IsFlat(p), Action = new(SessionFilterActionKind.Group, o) }).ToList(),
        };
        var detail = new SessionFilterNode("sessions.filter.detail", "Row Detail")
        {
            Subtitle = SessionFilterWords.DetailSubtitle(state),
            Children = SessionFilterWords.DetailOptions(state).Select(o => Check($"sessions.filter.detail.{o}", SessionFilterWords.Name(o),
                p.ShownDetail.Contains(o), new(SessionFilterActionKind.Detail, o))).ToList(),
        };
        var status = new SessionFilterNode("sessions.filter.status", "Status")
        {
            Subtitle = SessionFilterWords.StatusSubtitle(state),
            Children = Enum.GetValues<SessionStatus>().Select(o => Check($"sessions.filter.status.{o}", SessionFilterWords.Name(o),
                p.StatusFilter.Contains(o), new(SessionFilterActionKind.Status, o))).ToList(),
        };
        var newProject = new SessionFilterNode("sessions.filter.project.new", "New Project…") { Action = new(SessionFilterActionKind.NewProject) };
        var projectRows = state.Projects.Select((e, i) => Check($"sessions.filter.project.{i}", e.Label, p.ProjectFilter.Contains(e.Key),
            new(SessionFilterActionKind.Project, e.Key))).ToList();
        if (projectRows.Count == 0) projectRows = [newProject];
        else projectRows.Add(new SessionFilterNode("sessions.filter.project.create", "") { Inline = true, Children = [newProject] });
        var project = new SessionFilterNode("sessions.filter.project", "Project") { Subtitle = SessionFilterWords.ProjectSubtitle(state), Children = projectRows };
        var filter = new List<SessionFilterNode> { status, project };
        if (state.BotCount > 1) filter.Add(Check("sessions.filter.allbots", "All Bots", state.BotFilter == null, new(SessionFilterActionKind.AllBots)));
        var show = new List<SessionFilterNode>();
        if (p.RecentRows) show.Add(Check("sessions.filter.faces", "Bot Faces", p.BotFaces, new(SessionFilterActionKind.BotFaces)));
        if (SessionListPipeline.IsFresh(p))
        {
            show.Add(Check("sessions.filter.projects", "Projects", p.ShowProjects, new(SessionFilterActionKind.ShowProjects)));
            if (p.ShowProjects)
                show.Add(Check("sessions.filter.projectchats", "Project Chats in Recent", p.ProjectChatsInRecent, new(SessionFilterActionKind.ProjectChatsInRecent)));
        }
        show.Add(Check("sessions.filter.runs", "Background Runs", state.ShowBackgroundRuns, new(SessionFilterActionKind.Runs)));
        show.Add(Check("sessions.filter.archived", "Archived", p.ShowArchived, new(SessionFilterActionKind.Archived)));
        filter.Add(new SessionFilterNode("sessions.filter.show", "Show") { Subtitle = SessionFilterWords.ShowSubtitle(state), Children = show });
        var active = SessionFilterWords.FiltersActive(state);
        var last = active
            ? new SessionFilterNode("sessions.filter.clear", "Clear Filters") { Action = new(SessionFilterActionKind.Clear) }
            : new SessionFilterNode("sessions.filter.readall", "Mark All as Read") { Disabled = !state.HasUnread, Action = new(SessionFilterActionKind.ReadAll) };
        return
        [
            new("sessions.filter.view", "") { Inline = true, Children = [sort, group, detail] },
            new("sessions.filter.filters", "Filter") { Inline = true, Children = filter },
            new("sessions.filter.end", "") { Inline = true, Children = [last] },
        ];
    }

    /// What a pick does to the choices. `homeBot`: the chip All Bots ✓ picks when it is turned off. False for the rows
    /// that do something else (New Project…, Mark All as Read).
    public static bool Apply(SessionFilterAction a, SessionFilterState s, string homeBot)
    {
        var p = s.Prefs;
        switch (a.Kind)
        {
            case SessionFilterActionKind.Sort: p.SortBy = (SessionSortBy)a.Value!; break;
            case SessionFilterActionKind.Group:
                var was = p.Pills;
                p.GroupBy = (SessionGroupBy)a.Value!;
                if (p.Pills != was) { if (p.Pills == SessionPills.Projects) s.BotFilter = null; else p.ProjectFilter.Clear(); }
                break;
            case SessionFilterActionKind.Detail when (SessionRowDetail)a.Value! == SessionRowDetail.Preview && p.RecentRows:
                p.RecentPreview = !p.RecentPreview; break;
            case SessionFilterActionKind.Detail: Toggle(p.RowDetail, (SessionRowDetail)a.Value!); break;
            case SessionFilterActionKind.Status: Toggle(p.StatusFilter, (SessionStatus)a.Value!); break;
            case SessionFilterActionKind.Project: Toggle(p.ProjectFilter, (string)a.Value!); break;
            case SessionFilterActionKind.AllBots: s.BotFilter = s.BotFilter == null ? homeBot : null; break;
            case SessionFilterActionKind.Runs: s.ShowBackgroundRuns = !s.ShowBackgroundRuns; break;
            case SessionFilterActionKind.Archived: p.ShowArchived = !p.ShowArchived; break;
            case SessionFilterActionKind.BotFaces: p.BotFaces = !p.BotFaces; break;
            case SessionFilterActionKind.ProjectChatsInRecent: p.ProjectChatsInRecent = !p.ProjectChatsInRecent; break;
            case SessionFilterActionKind.ShowProjects: p.ShowProjects = !p.ShowProjects; break;
            case SessionFilterActionKind.Clear: ClearStrip(s); s.BotFilter = null; break;
            default: return false;
        }
        return true;
    }

    /// The strip's tap: status and project; the chip's bot stays.
    public static void ClearStrip(SessionFilterState s)
    {
        s.Prefs.StatusFilter.Clear();
        s.Prefs.ProjectFilter.Clear();
    }

    private static void Toggle<T>(HashSet<T> set, T value) { if (!set.Remove(value)) set.Add(value); }
}
