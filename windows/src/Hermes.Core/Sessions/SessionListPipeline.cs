namespace Hermes.Core.Sessions;

/// The pipeline's input (HermesKit's SessionListInput, without the parts not ported yet: other apps' folders, manual
/// order, project pins, kept projects, quiet-to-Done and pull requests).
public sealed class SessionListInput
{
    /// The listed chats: no bots' own chats, no hidden runs, no rows on their way out.
    public List<SessionSummary> Live { get; init; } = [];
    /// The archived chats; listed with the rest while Show › Archived is on (and on a project's page, as Done).
    public List<SessionSummary> Archived { get; init; } = [];
    public SessionsViewPrefs Prefs { get; init; } = new();
    public string? BotFilter { get; init; }
    public IReadOnlyDictionary<string, List<SessionProject>> ProjectsByProfile { get; init; } = new Dictionary<string, List<SessionProject>>();
    /// Filter › Project's list (Home last).
    public List<SessionProjectEntry> Projects { get; init; } = [];
    /// Titled groups the user closed.
    public IReadOnlySet<string> CollapsedGroups { get; init; } = new HashSet<string>();
    /// Projects the user opened (group ids); every other project is folded to its summary row.
    public IReadOnlySet<string> OpenGroups { get; init; } = new HashSet<string>();
    /// Groups whose "Show More" was tapped.
    public IReadOnlySet<string> ExpandedGroups { get; init; } = new HashSet<string>();
    /// Chats read since the page was last left (row keys): they keep their New rank until then.
    public IReadOnlySet<string> KeepNew { get; init; } = new HashSet<string>();
    public IReadOnlyDictionary<string, string> BotNames { get; init; } = new Dictionary<string, string>();
    public SessionStatusChip? StatusChip { get; init; }
    /// A closed project keeps its live chats under its row (the app; the Mac's Projects side).
    public bool LiveUnderProjects { get; init; }
    public DateTimeOffset Now { get; init; } = DateTimeOffset.Now;
    public TimeZoneInfo Zone { get; init; } = TimeZoneInfo.Local;
}

/// The Sessions list as one pure pipeline (docs/spec/3x-sessions.md §3.5): pool → filter → new → pinned → sort → group →
/// fold. Port of HermesKit/Model/SessionListPipeline.swift.
public static class SessionListPipeline
{
    public const string FlatId = "all";
    public const int ProjectFirstRows = 5;
    public const string NewId = "new";
    public const string NewTitle = "New for You";
    public const int NewFirstRows = 3;
    public const string RecentId = "recent";
    public const string RecentTitle = "Recent";
    public static readonly (string Id, string Title)[] RecentParts = [("today", "Today"), ("yesterday", "Yesterday"), ("week", "This Week"), ("older", "Older")];
    public const string RecentOlderId = "recent-older";
    public const int ProjectLiveRows = 3;
    public const int FreshPinnedRows = 3;
    public const int FreshProjectRows = 2;
    public const string ProjectsId = "projects";
    public const string ChipId = "chip";
    public const string PageId = "page";
    public const string StatePrefix = "state-";
    public const int PageFirstRows = 15;
    public const string ProjectPrefix = "project-";
    public const string BotPrefix = "bot-";
    public const string ProjectsTitle = "Projects";

    public static string Key(SessionSummary s) => s.Profile + "\u001F" + s.Id;
    public static bool IsFlat(SessionsViewPrefs p) => p.SortBy is SessionSortBy.Tokens or SessionSortBy.Cost;
    public static bool IsFresh(SessionsViewPrefs p) => p.GroupBy == SessionGroupBy.Date && !IsFlat(p);
    public static bool IsRecent(string id) => id == RecentId || id.StartsWith(RecentId + "-");
    public static bool IsProject(string id) => id.StartsWith(ProjectPrefix);
    public static string? ProjectKey(string id) => IsProject(id) ? id[ProjectPrefix.Length..] : null;
    public static string? BotProfile(string id) => id.StartsWith(BotPrefix) ? id[BotPrefix.Length..] : null;
    public static bool IsPageSection(string id) => id.StartsWith(StatePrefix);

    public static bool IsNew(SessionSummary s, IReadOnlySet<string>? keep = null) =>
        !s.Archived && (s.Unread || s.Status == SessionStatus.NeedsInput || keep?.Contains(Key(s)) == true);

    public static bool Matches(SessionStatusChip chip, SessionSummary s, IReadOnlySet<string>? keep = null) => chip switch
    {
        SessionStatusChip.New => IsNew(s, keep),
        _ => !s.Archived && (s.IsRunning || s.Status == SessionStatus.Working),
    };

    /// The chips' counts under the bot chip (the Filter menu's filters do not narrow them); under the project pill's
    /// project while the pills are the projects.
    public static Dictionary<SessionStatusChip, int> ChipCounts(SessionListInput input)
    {
        var counts = new Dictionary<SessionStatusChip, int> { [SessionStatusChip.New] = 0, [SessionStatusChip.Working] = 0 };
        var picked = input.Prefs.Pills == SessionPills.Projects
            ? input.Prefs.ProjectFilter.Intersect(input.Projects.Select(p => p.Key)).ToHashSet() : [];
        foreach (var s in input.Live)
        {
            if (input.BotFilter != null && s.Profile != input.BotFilter) continue;
            if (picked.Count > 0 && !picked.Contains(SessionProjects.KeyOf(s.Cwd, s.Profile, input.ProjectsByProfile))) continue;
            foreach (var chip in Enum.GetValues<SessionStatusChip>()) if (Matches(chip, s)) counts[chip]++;
        }
        return counts;
    }

    /// "Needs You", "New", "Working" counts for a header line: chats waiting on the person, with a reply not read yet,
    /// at work (under the bot chip).
    public static (int NeedsYou, int New, int Working) StateCounts(SessionListInput input)
    {
        int needs = 0, fresh = 0, working = 0;
        foreach (var s in input.Live)
        {
            if (input.BotFilter != null && s.Profile != input.BotFilter) continue;
            switch (SessionProjects.StateOf(s))
            {
                case SessionProjectState.NeedsYou: needs++; break;
                case SessionProjectState.Ready: fresh++; break;
                case SessionProjectState.Working: working++; break;
            }
        }
        return (needs, fresh, working);
    }

    public static List<SessionGroup> Groups(SessionListInput input) => Folded(Listed(input), input);

    private static List<SessionGroup> Listed(SessionListInput input)
    {
        var prefs = input.Prefs;
        var picked = prefs.ProjectFilter.Intersect(input.Projects.Select(p => p.Key)).ToHashSet();
        var pool = prefs.ShowArchived ? input.Live.Concat(input.Archived).ToList() : [.. input.Live];
        var isPage = prefs.Pills == SessionPills.Projects && picked.Count == 1 && !IsFlat(prefs);
        if (isPage && !prefs.ShowArchived) pool.AddRange(input.Archived);
        var needsProject = picked.Count > 0 || IsFresh(prefs) || (prefs.GroupBy == SessionGroupBy.Project && !IsFlat(prefs));
        var projectOf = new Dictionary<string, string>();
        string ProjectOf(SessionSummary s) => projectOf.GetValueOrDefault(Key(s), SessionProjects.HomeKey);

        var seen = new HashSet<string>();
        var rows = new List<SessionSummary>(pool.Count);
        foreach (var s in pool)
        {
            if (input.BotFilter != null && s.Profile != input.BotFilter) continue;
            if (prefs.StatusFilter.Count > 0 && !prefs.StatusFilter.Contains(s.Status)) continue;
            if (needsProject)
            {
                var found = SessionProjects.KeyOf(s.Cwd, s.Profile, input.ProjectsByProfile);
                if (picked.Count > 0 && !picked.Contains(found)) continue;
                projectOf[Key(s)] = found;
            }
            if (!seen.Add(Key(s))) continue;
            rows.Add(s);
        }
        if (isPage) return ProjectPage(picked.First(), rows, input);
        if (input.StatusChip is { } chip)
        {
            var run = Sort(rows.Where(s => Matches(chip, s, input.KeepNew)), SessionSortBy.Updated);
            return run.Count == 0 ? [] : [new SessionGroup { Id = ChipId, Sessions = run }];
        }
        if (rows.Count == 0) return [];

        var sorted = Sort(rows, prefs.SortBy);
        var lifts = !IsFlat(prefs) && prefs.StatusFilter.Count == 0 && !IsFresh(prefs);
        var fresh = lifts ? Sort(rows.Where(s => IsNew(s, input.KeepNew)), SessionSortBy.Updated) : [];
        var lifted = fresh.Select(Key).ToHashSet();
        var pinned = sorted.Where(s => s.Pinned && !lifted.Contains(Key(s))).ToList();
        var keepsNew = prefs.GroupBy == SessionGroupBy.Project;
        var rest = sorted.Where(s => !s.Pinned && (keepsNew || !lifted.Contains(Key(s)))).ToList();
        var o = new List<SessionGroup>();
        if (fresh.Count > 0) o.Add(new SessionGroup { Id = NewId, Title = NewTitle, Sessions = fresh });
        if (pinned.Count > 0) o.Add(new SessionGroup { Id = "pinned", Title = "Pinned", Sessions = pinned });
        if (IsFlat(prefs)) return rest.Count == 0 ? o : [.. o, new SessionGroup { Id = FlatId, Sessions = rest }];
        var projectRows = sorted.Where(s => s.Pinned
            ? ProjectOf(s) != SessionProjects.HomeKey && (keepsNew || !lifted.Contains(Key(s)))
            : keepsNew || !lifted.Contains(Key(s))).ToList();

        List<SessionGroup> ProjectGroups(List<SessionSummary> list)
        {
            var labels = input.Projects.GroupBy(p => p.Key).ToDictionary(g => g.Key, g => g.First().Label);
            var groups = Bucketed(list, s => (ProjectPrefix + ProjectOf(s), labels.GetValueOrDefault(ProjectOf(s), SessionProjects.HomeLabel)));
            var home = ProjectPrefix + SessionProjects.HomeKey;
            return groups.Select((g, i) => (g, i))
                .OrderBy(x => x.g.Id == home ? 1 : 0)
                .ThenByDescending(x => x.g.Sessions.Select(Recency).DefaultIfEmpty(double.NegativeInfinity).Max())
                .ThenBy(x => x.i).Select(x => x.g).ToList();
        }

        switch (prefs.GroupBy)
        {
            case SessionGroupBy.Date:
            {
                var projects = prefs.ShowProjects
                    ? ProjectGroups(projectRows).Where(g => g.Id != ProjectPrefix + SessionProjects.HomeKey).ToList() : [];
                if (projects.Count > 0 && prefs.StatusFilter.Count == 0 && picked.Count == 0)
                    projects = projects.Take(FreshProjectRows).ToList();
                o.AddRange(projects);
                var shownProjects = projects.Select(g => ProjectKey(g.Id)!).ToHashSet();
                if (projects.Count > 0 && prefs.StatusFilter.Count == 0 && picked.Count == 0)
                {
                    var homeRows = sorted.Where(s => ProjectOf(s) == SessionProjects.HomeKey).ToList();
                    if (homeRows.Count > 0)
                        o.Add(new SessionGroup { Id = ProjectPrefix + SessionProjects.HomeKey, Title = SessionProjects.HomeLabel, Sessions = homeRows });
                }
                var recent = prefs.ProjectChatsInRecent ? rest : rest.Where(s => !shownProjects.Contains(ProjectOf(s))).ToList();
                var sortedRecent = Sort(recent, prefs.SortBy);
                if (prefs.SortBy is SessionSortBy.Updated or SessionSortBy.Created)
                {
                    var today = TimeZoneInfo.ConvertTime(input.Now, input.Zone).Date;
                    var parts = new Dictionary<string, List<SessionSummary>>();
                    foreach (var s in sortedRecent)
                    {
                        var date = prefs.SortBy == SessionSortBy.Created ? s.StartedAt ?? s.LastActive : s.LastActive ?? s.StartedAt;
                        var days = date is { } d && d.ToUnixTimeSeconds() > 0 ? (today - TimeZoneInfo.ConvertTime(d, input.Zone).Date).Days : int.MaxValue;
                        var part = days <= 0 ? "today" : days == 1 ? "yesterday" : days < 7 ? "week" : "older";
                        if (!parts.TryGetValue(part, out var l)) parts[part] = l = [];
                        l.Add(s);
                    }
                    foreach (var (part, title) in RecentParts)
                        if (parts.TryGetValue(part, out var chats)) o.Add(new SessionGroup { Id = RecentId + "-" + part, Title = title, Sessions = chats });
                }
                else if (sortedRecent.Count > 0) o.Add(new SessionGroup { Id = RecentId, Title = RecentTitle, Sessions = sortedRecent });
                break;
            }
            case SessionGroupBy.Status:
            {
                var working = rest.Where(s => s.Status is SessionStatus.Working or SessionStatus.NeedsInput).ToList();
                var done = rest.Where(s => s.Status is not (SessionStatus.Working or SessionStatus.NeedsInput)).ToList();
                if (working.Count > 0) o.Add(new SessionGroup { Id = "status-working", Title = "Working", Sessions = working });
                if (done.Count > 0) o.Add(new SessionGroup { Id = "status-done", Title = "Done", Sessions = done });
                break;
            }
            case SessionGroupBy.Project:
            {
                // The Projects side is the projects alone, ordered by what needs the owner; Home last.
                o = [];
                var groups = ProjectGroups(sorted);
                int Rank(SessionGroup g)
                {
                    var states = g.Sessions.SelectMany(SessionProjects.StatesOf).ToHashSet();
                    return (int)Enum.GetValues<SessionProjectState>().FirstOrDefault(states.Contains, SessionProjectState.Quiet);
                }
                var home = ProjectPrefix + SessionProjects.HomeKey;
                o.AddRange(groups.Select((g, i) => (g, i)).OrderBy(x => x.g.Id == home ? 1 : 0).ThenBy(x => Rank(x.g)).ThenBy(x => x.i).Select(x => x.g));
                break;
            }
            case SessionGroupBy.Bot:
            {
                var groups = Bucketed(rest, s => (BotPrefix + s.Profile, input.BotNames.GetValueOrDefault(s.Profile, s.Profile)));
                o.AddRange(groups.Select((g, i) => (g, i))
                    .OrderByDescending(x => x.g.Sessions.Select(Recency).DefaultIfEmpty(double.NegativeInfinity).Max()).ThenBy(x => x.i)
                    .Select(x => x.g));
                break;
            }
        }
        return o;
    }

    /// A project pill opens the project as a page: a header, then its chats in three piles, Pinned, Active, Done.
    public static List<SessionGroup> ProjectPage(string key, List<SessionSummary> rows, SessionListInput input)
    {
        var done = rows.Where(s => SessionProjects.StateOf(s) == SessionProjectState.Quiet && s.Archived).ToList();
        var doneKeys = done.Select(Key).ToHashSet();
        var active = rows.Where(s => !doneKeys.Contains(Key(s))).ToList();
        var label = input.Projects.FirstOrDefault(p => p.Key == key)?.Label ?? key;
        var newest = Sort(active, SessionSortBy.Updated);
        var buckets = active.GroupBy(SessionProjects.StateOf).ToDictionary(g => g.Key, g => g.Count());
        var page = new SessionGroup
        {
            Id = PageId, PageKey = key, LatestTitle = label,
            Newest = newest.FirstOrDefault() is { } n ? n.LastActive ?? n.StartedAt : null,
            Branch = newest.Select(s => s.Branch).FirstOrDefault(b => b != null),
            Profiles = newest.Select(s => s.Profile).Distinct().ToList(),
            Needs = buckets.GetValueOrDefault(SessionProjectState.NeedsYou), Ready = buckets.GetValueOrDefault(SessionProjectState.Ready),
            Busy = buckets.GetValueOrDefault(SessionProjectState.Working), Total = active.Count,
        };
        var o = new List<SessionGroup> { page };
        int Rank(SessionSummary s)
        {
            var now = SessionProjects.StateOf(s);
            return (int)(now == SessionProjectState.Quiet && input.KeepNew.Contains(Key(s)) ? SessionProjectState.Ready : now);
        }
        var ordered = Sort(active, input.Prefs.SortBy).Select((s, i) => (s, i)).OrderBy(x => Rank(x.s)).ThenBy(x => x.i).Select(x => x.s).ToList();
        var shown = input.StatusChip is { } chip
            ? ordered.Where(s => chip == SessionStatusChip.New
                ? SessionProjects.StateOf(s) is SessionProjectState.NeedsYou or SessionProjectState.Ready || input.KeepNew.Contains(Key(s))
                : SessionProjects.StateOf(s) == SessionProjectState.Working).ToList()
            : ordered;
        (string Id, string Title, List<SessionSummary> Chats, bool Capped)[] sections =
        [
            ("pinned", "Pinned", shown.Where(s => s.Pinned || s.ProjectPinned).ToList(), false),
            ("active", "Active", shown.Where(s => !s.Pinned && !s.ProjectPinned).ToList(), true),
            ("done", "Done", input.StatusChip == null ? Sort(done, SessionSortBy.Updated) : [], true),
        ];
        var filtered = input.Prefs.StatusFilter.Count > 0 || input.StatusChip != null;
        foreach (var (id, title, chats, capped) in sections)
        {
            if (chats.Count == 0) continue;
            var group = new SessionGroup { Id = StatePrefix + id, Title = title, Sessions = chats, Total = chats.Count, Unread = chats.Count(s => s.Unread) };
            if (!filtered)
            {
                var startsClosed = id == "done";
                if (input.CollapsedGroups.Contains(group.Id) || (startsClosed && !input.OpenGroups.Contains(group.Id)))
                    group = group with { Collapsed = true, Sessions = [] };
                else if (capped && chats.Count > PageFirstRows + 1)
                    group = input.ExpandedGroups.Contains(group.Id) ? group with { Expanded = true }
                        : group with { More = chats.Count - PageFirstRows, Sessions = chats.Take(PageFirstRows).ToList() };
            }
            o.Add(group);
        }
        return o;
    }

    /// A header that folds: every titled section.
    public static bool Folds(SessionGroup g) => g.Title.Length > 0 && (g.Id == NewId || g.Id == "pinned" || IsRecent(g.Id)
        || g.Id == ProjectsId || IsPageSection(g.Id) || g.Id.StartsWith("status-") || IsProject(g.Id) || g.Id.StartsWith(BotPrefix));

    private static List<SessionGroup> Folded(List<SessionGroup> groups, SessionListInput input)
    {
        var filtered = input.Prefs.StatusFilter.Count > 0 || input.Prefs.ProjectFilter.Intersect(input.Projects.Select(p => p.Key)).Any();
        var olderStartsClosed = groups.Any(g => IsRecent(g.Id) && g.Id != RecentOlderId);
        return groups.Select(group =>
        {
            if (group.Title.Length == 0 || IsPageSection(group.Id)) return group;
            var g = group with { Total = group.Sessions.Count, Unread = group.Sessions.Count(s => s.Unread) };
            if (IsProject(g.Id))
            {
                var newest = g.Sessions.MaxBy(Recency);
                g = g with
                {
                    Newest = newest?.LastActive ?? newest?.StartedAt, LatestTitle = newest?.Title,
                    Profiles = g.Sessions.OrderByDescending(Recency).Select(s => s.Profile).Distinct().ToList(),
                    Working = g.Sessions.Any(s => s.IsRunning || s.Status == SessionStatus.Working),
                };
            }
            if (filtered) return g;
            var freshPinned = IsFresh(input.Prefs) && g.Id == "pinned";
            var closed = IsProject(g.Id) ? !input.OpenGroups.Contains(g.Id)
                : g.Id == RecentOlderId && olderStartsClosed ? !input.OpenGroups.Contains(g.Id) || input.CollapsedGroups.Contains(g.Id)
                : input.CollapsedGroups.Contains(g.Id);
            var first = g.Id == NewId ? NewFirstRows : freshPinned ? FreshPinnedRows : ProjectFirstRows;
            if (Folds(g) && closed)
            {
                if (input.LiveUnderProjects && IsProject(g.Id) && input.Prefs.GroupBy == SessionGroupBy.Project)
                {
                    var live = g.Sessions.Where(s => SessionProjects.StatesOf(s).Count > 0).Select((s, i) => (s, i))
                        .OrderBy(x => (int)SessionProjects.StateOf(x.s)).ThenByDescending(x => Recency(x.s)).ThenBy(x => x.i)
                        .Select(x => x.s).Take(ProjectLiveRows).ToList();
                    return g with { Collapsed = true, Sessions = live };
                }
                return g with { Collapsed = true, Sessions = [] };
            }
            if ((IsProject(g.Id) || g.Id.StartsWith(BotPrefix) || g.Id == NewId || freshPinned) && g.Sessions.Count > first)
                return input.ExpandedGroups.Contains(g.Id) ? g with { Expanded = true }
                    : g with { More = g.Sessions.Count - first, Sessions = g.Sessions.Take(first).ToList() };
            return g;
        }).ToList();
    }

    private static List<SessionGroup> Bucketed(List<SessionSummary> rows, Func<SessionSummary, (string Id, string Title)> label)
    {
        var groups = new List<SessionGroup>();
        var index = new Dictionary<string, int>();
        foreach (var s in rows)
        {
            var (id, title) = label(s);
            if (index.TryGetValue(id, out var at)) groups[at].Sessions.Add(s);
            else { index[id] = groups.Count; groups.Add(new SessionGroup { Id = id, Title = title, Sessions = [s] }); }
        }
        return groups;
    }

    public static double Recency(SessionSummary s) => (s.LastActive ?? s.StartedAt)?.ToUnixTimeMilliseconds() / 1000.0 ?? double.NegativeInfinity;
    public static double Created(SessionSummary s) => (s.StartedAt ?? s.LastActive)?.ToUnixTimeMilliseconds() / 1000.0 ?? double.NegativeInfinity;

    /// Sort By; ties by recency (newest first), then id.
    public static List<SessionSummary> Sort(IEnumerable<SessionSummary> rows, SessionSortBy by) =>
        rows.Select(s =>
        {
            var primary = by switch
            {
                SessionSortBy.Created => -Created(s),
                SessionSortBy.Status => (double)s.Status,
                SessionSortBy.Tokens => -(double)s.Tokens,
                SessionSortBy.Cost => -(double.IsFinite(s.Cost) ? s.Cost : 0),
                _ => 0,
            };
            return (Primary: double.IsNaN(primary) ? 0 : primary, Recency: Recency(s), S: s);
        })
        .OrderBy(x => x.Primary).ThenByDescending(x => x.Recency).ThenBy(x => x.S.Id, StringComparer.Ordinal)
        .ThenBy(x => x.S.Profile, StringComparer.Ordinal).Select(x => x.S).ToList();
}
