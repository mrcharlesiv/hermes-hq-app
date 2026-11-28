using System.Text.Json.Nodes;
using Hermes.Core.Bots;

namespace Hermes.Core.Sessions;

// Sessions: what the user chose in Filter & Sort, a chat's status, the list's rows and groups, projects.
// Port of HermesKit/Contracts+sessions.swift, the SessionSummary of Contracts.swift and SessionFilterWords.swift's
// project helpers (docs/spec/3x-sessions.md §3).

/// Sort By (`V/store/layout.ts` orderings). Manual (dragged rows) is not ported yet.
public enum SessionSortBy { Updated, Created, Status, Tokens, Cost }

/// Group By. Date reads "Recent".
public enum SessionGroupBy { Date, Project, Bot, Status }

/// Row Detail, menu order.
public enum SessionRowDetail { Time, Preview, Tokens, Cost }

/// A chat's one status, in menu order and sort rank 0…4.
public enum SessionStatus { NeedsInput, Working, Unread, Draft, Idle }

/// What the pills under the bar are: the bots ("Chats" side), or the projects.
public enum SessionPills { Bots, Projects }

/// The header's status chips after All: New (a reply not read yet, or waiting on you) and Working.
public enum SessionStatusChip { New, Working }

/// The choices, kept per gateway account on the device.
public sealed class SessionsViewPrefs
{
    public SessionSortBy SortBy { get; set; } = SessionSortBy.Updated;
    public SessionGroupBy GroupBy { get; set; } = SessionGroupBy.Date;
    public HashSet<SessionRowDetail> RowDetail { get; set; } = [SessionRowDetail.Preview, SessionRowDetail.Time];
    public HashSet<SessionStatus> StatusFilter { get; set; } = [];
    /// Project keys (`SessionProjects.Key`).
    public HashSet<string> ProjectFilter { get; set; } = [];
    public bool ShowArchived { get; set; }
    public bool BotFaces { get; set; } = true;
    public bool ProjectChatsInRecent { get; set; } = true;
    /// Show › Projects: the Chats side draws the projects' shortcut above Recent (off by default).
    public bool ShowProjects { get; set; }
    /// Row Detail › Preview under Group By Recent (its own setting, off by default).
    public bool RecentPreview { get; set; }

    /// Group By Project is the project pills; setting the pills picks the grouping.
    public SessionPills Pills
    {
        get => GroupBy == SessionGroupBy.Project ? SessionPills.Projects : SessionPills.Bots;
        set
        {
            if (value == SessionPills.Projects) GroupBy = SessionGroupBy.Project;
            else if (GroupBy == SessionGroupBy.Project) GroupBy = SessionGroupBy.Date;
        }
    }

    public bool RecentRows => SessionListPipeline.IsFresh(this) || (GroupBy == SessionGroupBy.Project && !SessionListPipeline.IsFlat(this));

    public IReadOnlySet<SessionRowDetail> ShownDetail
    {
        get
        {
            if (!RecentRows) return RowDetail;
            var o = new HashSet<SessionRowDetail>(RowDetail);
            if (RecentPreview) o.Add(SessionRowDetail.Preview); else o.Remove(SessionRowDetail.Preview);
            return o;
        }
    }

    public SessionsViewPrefs Copy() => new()
    {
        SortBy = SortBy, GroupBy = GroupBy, RowDetail = [.. RowDetail], StatusFilter = [.. StatusFilter],
        ProjectFilter = [.. ProjectFilter], ShowArchived = ShowArchived, BotFaces = BotFaces,
        ProjectChatsInRecent = ProjectChatsInRecent, ShowProjects = ShowProjects, RecentPreview = RecentPreview,
    };
}

/// One Sessions row as the list draws it (HermesKit's SessionSummary).
public sealed record SessionSummary
{
    public required string Id { get; init; }          // stored session id
    public required string Profile { get; init; }
    public required string Title { get; init; }
    public string? Preview { get; init; }
    public DateTimeOffset? LastActive { get; init; }
    public DateTimeOffset? StartedAt { get; init; }
    public string? Source { get; init; }
    public bool Unread { get; init; }
    public bool IsRunning { get; init; }
    public bool Pinned { get; init; }
    public bool ProjectPinned { get; init; }
    public bool Archived { get; init; }
    public bool Outside { get; init; }
    public long Tokens { get; init; }
    public double Cost { get; init; }
    /// "main · hermes-4 · 2 messages · 1 tool call".
    public string Metadata { get; init; } = "";
    public string? Branch { get; init; }
    public SessionStatus Status { get; init; } = SessionStatus.Idle;
    public string? Cwd { get; init; }
    public string? Step { get; init; }
    public string? Model { get; init; }
    public long? MessageCount { get; init; }
    public string? Owner { get; init; }
    /// [WIN-LOST-SEND-MARKER] The row's pending line (§9.4): a send that may not have arrived, else a draft.
    public SessionPending? Pending { get; init; }
    /// Lead pull request / branch status when known (`SessionSummary.pullRequest` in HermesKit).
    public Coding.SessionPRStatus? PullRequest { get; init; }

    public string Key => SessionListPipeline.Key(this);
}

/// A group of the list (Pinned, a day, a status, a project, a bot, a project page's pile).
public sealed record SessionGroup
{
    public required string Id { get; init; }
    public string Title { get; init; } = "";
    public List<SessionSummary> Sessions { get; init; } = [];
    public bool Collapsed { get; init; }
    public bool Expanded { get; init; }
    public int Total { get; init; }
    public int Unread { get; init; }
    /// Chats past the first rows ("Show More (X)").
    public int More { get; init; }
    public DateTimeOffset? Newest { get; init; }
    public string? LatestTitle { get; init; }
    public bool Working { get; init; }
    public List<string> Profiles { get; init; } = [];
    // The project page's header.
    public string? PageKey { get; init; }
    public string? Branch { get; init; }
    public int Needs { get; init; }
    public int Ready { get; init; }
    public int Busy { get; init; }
}

/// A project from `projects.tree`: its folder (`root`) and every path that counts as inside it.
public sealed record SessionProject(string Id, string Label, string Root, IReadOnlyList<string> Paths, bool IsAuto = false)
{
    public static List<SessionProject> DecodeTree(JsonNode? json)
    {
        var o = new List<SessionProject>();
        foreach (var node in json?["projects"] as JsonArray ?? [])
        {
            if (RosterText.Trimmed(node?["id"]) is not { } id) continue;
            if (RosterText.Bool(node!["isNoProject"]) == true || RosterText.Bool(node["is_no_project"]) == true) continue;
            var label = RosterText.Trimmed(node["label"]) ?? RosterText.Trimmed(node["name"]) ?? id;
            var repos = node["repos"] as JsonArray ?? [];
            var own = RosterText.Trimmed(node["path"]) ?? RosterText.Trimmed(node["primary_path"]);
            var repoPaths = repos.Select(r => RosterText.Trimmed(r?["path"])).OfType<string>().ToList();
            var lanes = repos.SelectMany(r => (r?["groups"] as JsonArray ?? []).Select(g => RosterText.Trimmed(g?["path"])).OfType<string>()).ToList();
            if ((own ?? repoPaths.FirstOrDefault()) is not { } root) continue;
            var paths = new List<string>();
            if (own != null) paths.Add(own);
            paths.AddRange(repoPaths);
            paths.AddRange(lanes);
            o.Add(new SessionProject(id, label, root, paths,
                RosterText.Bool(node["isAuto"]) == true || RosterText.Bool(node["is_auto"]) == true));
        }
        return o;
    }

    /// The project that holds a chat's folder: the longest folder match.
    public static string? OwnerOf(string? cwd, IEnumerable<SessionProject> projects)
    {
        var c = cwd?.Trim();
        if (string.IsNullOrEmpty(c)) return null;
        (string Id, int Length)? best = null;
        foreach (var p in projects)
            foreach (var path in p.Paths)
                if ((c == path || c.StartsWith(path.EndsWith('/') ? path : path + "/")) && path.Length > (best?.Length ?? -1))
                    best = (p.Id, path.Length);
        return best?.Id;
    }

    /// "~/Projects/<slug>" for New Project without a folder typed.
    public static string AutoFolder(string name, int attempt = 1)
    {
        var slug = new System.Text.StringBuilder();
        foreach (var ch in name.ToLowerInvariant())
        {
            if (ch is >= 'a' and <= 'z' or >= '0' and <= '9') slug.Append(ch);
            else if (slug.Length > 0 && slug[^1] != '-') slug.Append('-');
        }
        var s = slug.ToString();
        if (s.Length > 64) s = s[..64];
        s = s.TrimEnd('-');
        if (s.Length == 0) s = "project";
        return "~/Projects/" + s + (attempt > 1 ? $"-{attempt}" : "");
    }
}

public sealed record SessionProjectEntry(string Key, string Label);

/// A project's live states, in rank order (Needs you, New, Working, quiet).
public enum SessionProjectState { NeedsYou, Ready, Working, Quiet }

public static class SessionProjects
{
    public const string HomeKey = "home";
    public const string HomeLabel = "Home";

    /// A project's key: its folder without a trailing slash; a project without a folder `id:<profile>/<id>`.
    public static string KeyOf(SessionProject project, string profile)
    {
        var root = project.Root.Trim();
        while (root.Length > 1 && root.EndsWith('/')) root = root[..^1];
        return root.Length == 0 ? $"id:{profile}/{project.Id}" : root;
    }

    /// Every bot's projects as one list, named by the first bot in `order` that has it, sorted by name. Without Home.
    public static List<SessionProjectEntry> Entries(IReadOnlyDictionary<string, List<SessionProject>> byProfile, IReadOnlyList<string> order)
    {
        var seen = new HashSet<string>();
        var o = new List<SessionProjectEntry>();
        var profiles = order.Where(byProfile.ContainsKey).Concat(byProfile.Keys.Where(k => !order.Contains(k)).Order());
        foreach (var profile in profiles)
            foreach (var p in byProfile[profile])
                if (seen.Add(KeyOf(p, profile))) o.Add(new SessionProjectEntry(KeyOf(p, profile), p.Label));
        return o.OrderBy(e => e.Label, NumericComparer.Instance).ThenBy(e => e.Key, StringComparer.Ordinal).ToList();
    }

    /// Filter › Project's list: the projects with Home last, nothing at all without a project.
    public static List<SessionProjectEntry> MenuEntries(IReadOnlyDictionary<string, List<SessionProject>> byProfile, IReadOnlyList<string> order)
    {
        var e = Entries(byProfile, order);
        if (e.Count > 0) e.Add(new SessionProjectEntry(HomeKey, HomeLabel));
        return e;
    }

    /// The key of the project that holds a chat's folder; Home when none does.
    public static string KeyOf(string? cwd, string profile, IReadOnlyDictionary<string, List<SessionProject>> byProfile)
    {
        if (!byProfile.TryGetValue(profile, out var projects) || projects.Count == 0
            || SessionProject.OwnerOf(cwd, projects) is not { } id || projects.FirstOrDefault(p => p.Id == id) is not { } project)
            return HomeKey;
        return KeyOf(project, profile);
    }

    public static HashSet<SessionProjectState> StatesOf(SessionSummary s)
    {
        var o = new HashSet<SessionProjectState>();
        if (s.Status == SessionStatus.NeedsInput) o.Add(SessionProjectState.NeedsYou);
        if (s.Unread) o.Add(SessionProjectState.Ready);
        if (s.IsRunning || s.Status == SessionStatus.Working) o.Add(SessionProjectState.Working);
        return o;
    }

    public static SessionProjectState StateOf(SessionSummary s) =>
        Enum.GetValues<SessionProjectState>().FirstOrDefault(StatesOf(s).Contains, SessionProjectState.Quiet);

    /// A project's row line: what its bots are doing there ("Needs you · Working"); null when quiet.
    public static string? StateWords(IEnumerable<SessionSummary> sessions)
    {
        var states = sessions.Where(s => !s.Archived).SelectMany(StatesOf).ToHashSet();
        var parts = new List<string>();
        if (states.Contains(SessionProjectState.NeedsYou)) parts.Add("Needs you");
        if (states.Contains(SessionProjectState.Working)) parts.Add("Working");
        if (states.Contains(SessionProjectState.Ready)) parts.Add("New");
        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }
}

/// Case-insensitive, numbers in order ("Site 2" before "Site 10").
public sealed class NumericComparer : IComparer<string>
{
    public static readonly NumericComparer Instance = new();

    public int Compare(string? x, string? y)
    {
        x ??= ""; y ??= "";
        int i = 0, j = 0;
        while (i < x.Length && j < y.Length)
        {
            if (char.IsDigit(x[i]) && char.IsDigit(y[j]))
            {
                int si = i, sj = j;
                while (i < x.Length && char.IsDigit(x[i])) i++;
                while (j < y.Length && char.IsDigit(y[j])) j++;
                var a = x[si..i].TrimStart('0'); var b = y[sj..j].TrimStart('0');
                if (a.Length != b.Length) return a.Length.CompareTo(b.Length);
                var c = string.CompareOrdinal(a, b);
                if (c != 0) return c;
            }
            else
            {
                var c = char.ToLowerInvariant(x[i]).CompareTo(char.ToLowerInvariant(y[j]));
                if (c != 0) return c;
                i++; j++;
            }
        }
        return (x.Length - i).CompareTo(y.Length - j);
    }
}
