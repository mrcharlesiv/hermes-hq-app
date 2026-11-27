using Hermes.Core.Sessions;

namespace Hermes.Core.Coding;

/// The calm shipping pipeline stages for a coding project (Mac 1277 `ProjectPage` + shipping pipeline).
public enum CodingPipelineStage
{
    NeedsAttention,
    ReadyToMerge,
    InReview,
    ChecksRunning,
    Draft,
    Merged,
    Closed,
}

/// Sort modes on the project coding pipeline header (`ProjectPageSort`).
public enum ProjectPageSort
{
    NeedsMeFirst,
    ByStatus,
    Newest,
}

/// Header toggles and filters honored by `ByStatus`, `Newest`, and `NeedsMeFirst` sorts.
public sealed record CodingPipelineFilter
{
    public bool ShowMerged { get; init; }
    public bool ShowDrafts { get; init; } = true;
    public bool ShowClosed { get; init; }
    public string? FilterByBot { get; init; }
    public SessionPRState? SelectedPRState { get; init; }
    public SessionStatusChip? StatusChip { get; init; }
    public string SearchQuery { get; init; } = "";
}

/// One row in the coding pipeline view.
public sealed record CodingSessionRow(
    SessionSummary Session,
    SessionPRStatus? PrStatus,
    CodingPipelineStage Stage,
    PRVerdict? Verdict,
    string? Branch,
    DateTimeOffset SortMoment)
{
    public bool NeedsAttention => Stage == CodingPipelineStage.NeedsAttention;
    public bool IsReadyToMerge => Stage == CodingPipelineStage.ReadyToMerge;
    public bool IsFinished => Stage is CodingPipelineStage.Merged or CodingPipelineStage.Closed;
}

/// One visual section in the coding pipeline list.
public sealed record CodingPipelineSection(
    string Id,
    string Title,
    CodingPipelineStage? Stage,
    IReadOnlyList<CodingSessionRow> Rows,
    bool CollapsedByDefault = false);

/// Summary counts for header filter chips and metrics.
public sealed record CodingPipelineCounts(
    int Total,
    int NeedsAttention,
    int ReadyToMerge,
    int InReview,
    int ChecksRunning,
    int Draft,
    int Merged,
    int Closed,
    int OpenPRs,
    int NeedsYou,
    int Unread,
    int Working);

/// Health banner shown at the top of a coding project when its repository isn't ready.
public sealed record CodingHealthBanner(
    string Kind,
    string Title,
    string Detail,
    string? ActionLabel = null);

/// Pure classification, filtering, and sorting engine for the Calm Shipping Pipeline view.
public static class CodingPipelineEngine
{
    /// Classifies a session + its PR status into one calm shipping pipeline stage.
    public static CodingPipelineStage ClassifyStage(SessionSummary session, SessionPRStatus? pr)
    {
        if (pr != null)
        {
            if (pr.State == SessionPRState.Merged) return CodingPipelineStage.Merged;
            if (pr.State == SessionPRState.Closed) return CodingPipelineStage.Closed;

            // Attention takes precedence: failing checks, changes requested, or bot waiting on you.
            if (pr.Checks?.State == SessionPRCheckState.Failed
                || pr.ReviewVerdict == PRReviewVerdict.ChangesRequested
                || session.Status == SessionStatus.NeedsInput)
                return CodingPipelineStage.NeedsAttention;

            if (pr.State == SessionPRState.Draft) return CodingPipelineStage.Draft;

            if (pr.Checks?.State == SessionPRCheckState.Running
                || session.IsRunning
                || session.Status == SessionStatus.Working)
                return CodingPipelineStage.ChecksRunning;

            if (pr.State == SessionPRState.Open)
            {
                var checksGreen = pr.Checks?.State == SessionPRCheckState.Passed;
                var reviewOk = pr.ReviewVerdict == PRReviewVerdict.Approved
                    || (checksGreen && pr.ReviewVerdict is PRReviewVerdict.None or PRReviewVerdict.Commented);
                if (checksGreen && reviewOk) return CodingPipelineStage.ReadyToMerge;
                return CodingPipelineStage.InReview;
            }
        }

        if (session.Archived) return CodingPipelineStage.Closed;
        if (session.Status == SessionStatus.NeedsInput) return CodingPipelineStage.NeedsAttention;
        if (session.IsRunning || session.Status == SessionStatus.Working) return CodingPipelineStage.ChecksRunning;
        if (session.Status == SessionStatus.Draft) return CodingPipelineStage.Draft;
        return CodingPipelineStage.InReview;
    }

    public static string StageTitle(CodingPipelineStage stage) => stage switch
    {
        CodingPipelineStage.NeedsAttention => "Needs Attention",
        CodingPipelineStage.ReadyToMerge => "Ready to Merge",
        CodingPipelineStage.InReview => "In Review",
        CodingPipelineStage.ChecksRunning => "Checks Running",
        CodingPipelineStage.Draft => "Draft",
        CodingPipelineStage.Merged => "Merged",
        CodingPipelineStage.Closed => "Closed",
        _ => "Other",
    };

    public static int StageRank(CodingPipelineStage stage) => stage switch
    {
        CodingPipelineStage.NeedsAttention => 0,
        CodingPipelineStage.ReadyToMerge => 1,
        CodingPipelineStage.InReview => 2,
        CodingPipelineStage.ChecksRunning => 3,
        CodingPipelineStage.Draft => 4,
        CodingPipelineStage.Merged => 5,
        CodingPipelineStage.Closed => 6,
        _ => 7,
    };

    public static string SortLabel(ProjectPageSort sort) => sort switch
    {
        ProjectPageSort.ByStatus => "By Status",
        ProjectPageSort.Newest => "Newest",
        _ => "Needs Me First",
    };

    /// Builds filtered and sorted pipeline sections honoring every header toggle.
    public static IReadOnlyList<CodingPipelineSection> BuildSections(
        IEnumerable<SessionSummary> sessions,
        IReadOnlyDictionary<string, SessionPRStatus> prBySessionKey,
        ProjectPageSort sort,
        CodingPipelineFilter filter)
    {
        var rows = new List<CodingSessionRow>();
        foreach (var session in sessions)
        {
            prBySessionKey.TryGetValue(session.Key, out var pr);
            var stage = ClassifyStage(session, pr);
            if (!MatchesFilter(session, pr, stage, filter)) continue;
            var verdict = pr != null ? PRVerdict.From(pr) : null;
            var branch = pr?.Branch ?? session.Branch;
            var moment = session.LastActive ?? session.StartedAt ?? DateTimeOffset.MinValue;
            rows.Add(new CodingSessionRow(session, pr, stage, verdict, branch, moment));
        }

        if (rows.Count == 0) return [];

        if (sort == ProjectPageSort.Newest)
        {
            var ordered = rows
                .OrderByDescending(r => r.Session.ProjectPinned || r.Session.Pinned)
                .ThenByDescending(r => r.SortMoment)
                .ThenBy(r => r.Session.Id, StringComparer.Ordinal)
                .ToList();
            return [new CodingPipelineSection("newest", "Newest", null, ordered)];
        }

        if (sort == ProjectPageSort.NeedsMeFirst)
        {
            var ordered = rows
                .OrderByDescending(r => r.Session.ProjectPinned || r.Session.Pinned)
                .ThenBy(r => NeedsMeRank(r))
                .ThenByDescending(r => r.SortMoment)
                .ThenBy(r => r.Session.Id, StringComparer.Ordinal)
                .ToList();

            var sections = new List<CodingPipelineSection>();
            var attention = ordered.Where(r => r.Stage == CodingPipelineStage.NeedsAttention).ToList();
            var ready = ordered.Where(r => r.Stage == CodingPipelineStage.ReadyToMerge).ToList();
            var active = ordered.Where(r => r.Stage is CodingPipelineStage.InReview or CodingPipelineStage.ChecksRunning or CodingPipelineStage.Draft).ToList();
            var done = ordered.Where(r => r.Stage is CodingPipelineStage.Merged or CodingPipelineStage.Closed).ToList();

            if (attention.Count > 0) sections.Add(new("needs-attention", StageTitle(CodingPipelineStage.NeedsAttention), CodingPipelineStage.NeedsAttention, attention));
            if (ready.Count > 0) sections.Add(new("ready-to-merge", StageTitle(CodingPipelineStage.ReadyToMerge), CodingPipelineStage.ReadyToMerge, ready));
            if (active.Count > 0) sections.Add(new("active", "In Progress", null, active));
            if (done.Count > 0) sections.Add(new("done", "Merged & Closed", CodingPipelineStage.Merged, done, CollapsedByDefault: !filter.ShowMerged && !filter.ShowClosed));
            return sections;
        }

        // ProjectPageSort.ByStatus: grouped cleanly by every active calm shipping pipeline stage.
        var byStage = new List<CodingPipelineSection>();
        foreach (var stage in Enum.GetValues<CodingPipelineStage>().OrderBy(StageRank))
        {
            var group = rows
                .Where(r => r.Stage == stage)
                .OrderByDescending(r => r.Session.ProjectPinned || r.Session.Pinned)
                .ThenByDescending(r => r.SortMoment)
                .ThenBy(r => r.Session.Id, StringComparer.Ordinal)
                .ToList();
            if (group.Count == 0) continue;
            byStage.Add(new CodingPipelineSection(
                Id: stage.ToString().ToLowerInvariant(),
                Title: StageTitle(stage),
                Stage: stage,
                Rows: group,
                CollapsedByDefault: stage is CodingPipelineStage.Merged or CodingPipelineStage.Closed));
        }
        return byStage;
    }

    /// Computes live stage and PR counts before header filter toggles hide merged/draft/closed rows.
    public static CodingPipelineCounts ComputeCounts(
        IEnumerable<SessionSummary> sessions,
        IReadOnlyDictionary<string, SessionPRStatus> prBySessionKey,
        string? filterByBot = null)
    {
        int total = 0, attention = 0, ready = 0, review = 0, running = 0, draft = 0, merged = 0, closed = 0;
        int openPRs = 0, needsYou = 0, unread = 0, working = 0;

        foreach (var session in sessions)
        {
            if (!string.IsNullOrWhiteSpace(filterByBot)
                && !string.Equals(session.Profile, filterByBot, StringComparison.OrdinalIgnoreCase))
                continue;

            total++;
            prBySessionKey.TryGetValue(session.Key, out var pr);
            var stage = ClassifyStage(session, pr);
            switch (stage)
            {
                case CodingPipelineStage.NeedsAttention: attention++; break;
                case CodingPipelineStage.ReadyToMerge: ready++; break;
                case CodingPipelineStage.InReview: review++; break;
                case CodingPipelineStage.ChecksRunning: running++; break;
                case CodingPipelineStage.Draft: draft++; break;
                case CodingPipelineStage.Merged: merged++; break;
                case CodingPipelineStage.Closed: closed++; break;
            }
            if (pr?.State == SessionPRState.Open) openPRs++;
            if (session.Status == SessionStatus.NeedsInput) needsYou++;
            if (session.Unread) unread++;
            if (session.IsRunning || session.Status == SessionStatus.Working) working++;
        }

        return new CodingPipelineCounts(total, attention, ready, review, running, draft, merged, closed, openPRs, needsYou, unread, working);
    }

    /// Computes the calm project coding health banner (`ProjectPage.swift` `codingHealth`).
    public static CodingHealthBanner? Health(bool codingProject, SessionPRRepo? repo, SessionPRReposState reposState)
    {
        if (!codingProject) return null;
        if (reposState == SessionPRReposState.Loading && repo == null)
            return new CodingHealthBanner("checking", "Checking repository…", "Looking up pull request status for this project.");
        if (reposState == SessionPRReposState.Failed && repo == null)
            return new CodingHealthBanner("failed", "Couldn’t check repository", "Reconnect or open Repository Settings to verify this folder.", "Repository…");
        if (repo == null)
            return new CodingHealthBanner("unlinked", "Link a Git repository", "Connect this project’s folder and GitHub repo to track checks, reviews, and merge readiness.", "Link Repository…");
        return null;
    }

    private static bool MatchesFilter(
        SessionSummary session,
        SessionPRStatus? pr,
        CodingPipelineStage stage,
        CodingPipelineFilter filter)
    {
        if (!string.IsNullOrWhiteSpace(filter.FilterByBot)
            && !string.Equals(session.Profile, filter.FilterByBot, StringComparison.OrdinalIgnoreCase))
            return false;

        if (filter.SelectedPRState is { } pickedState)
        {
            if (pr == null || !pr.CountedStates.Contains(pickedState)) return false;
        }
        else
        {
            if (stage == CodingPipelineStage.Merged && !filter.ShowMerged) return false;
            if (stage == CodingPipelineStage.Closed && !filter.ShowClosed) return false;
            if (stage == CodingPipelineStage.Draft && !filter.ShowDrafts) return false;
        }

        if (filter.StatusChip is { } chip)
        {
            var states = SessionProjects.StatesOf(session);
            if (chip == SessionStatusChip.New && !states.Contains(SessionProjectState.NeedsYou) && !states.Contains(SessionProjectState.Ready))
                return false;
            if (chip == SessionStatusChip.Working && !states.Contains(SessionProjectState.Working) && stage != CodingPipelineStage.ChecksRunning)
                return false;
        }

        var query = filter.SearchQuery.Trim();
        if (query.Length > 0)
        {
            var hit = session.Title.Contains(query, StringComparison.OrdinalIgnoreCase)
                || (session.Branch?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false)
                || (pr?.Title?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false)
                || (pr?.Branch?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false)
                || (pr?.Repo?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false)
                || (pr?.Number is { } num && $"#{num}".Contains(query, StringComparison.OrdinalIgnoreCase));
            if (!hit) return false;
        }

        return true;
    }

    private static int NeedsMeRank(CodingSessionRow row)
    {
        if (row.Stage == CodingPipelineStage.NeedsAttention) return 0;
        if (row.Session.Unread) return 1;
        if (row.Stage == CodingPipelineStage.ReadyToMerge) return 2;
        if (row.Stage == CodingPipelineStage.InReview) return 3;
        if (row.Stage == CodingPipelineStage.ChecksRunning) return 4;
        if (row.Stage == CodingPipelineStage.Draft) return 5;
        return 6;
    }
}
