using Hermes.Core.Sessions;

namespace Hermes.Core.Coding;

/// The four decision-first buckets on a coding project page (`HermesKit/Model/CodingPipeline.swift`, `3e7f6374a`/`997919566`).
public enum CodingPipelineBucket
{
    /// Open pull requests ready to review and merge (not working, checks not failing or running).
    Ready,
    /// Chats needing the owner's attention: waiting for input, failing CI checks, or unread replies.
    NeedsYou,
    /// Active work in progress: running bots, drafts, branches without PRs, checks running, or plain project chats.
    InFlight,
    /// Completed work: merged/closed PRs (quiet) and archived/auto-done chats. Collapsed by default.
    Shipped,
}

public static class CodingPipelineBucketExtensions
{
    public static string Label(this CodingPipelineBucket bucket) => bucket switch
    {
        CodingPipelineBucket.Ready => "Ready",
        CodingPipelineBucket.NeedsYou => "Needs You",
        CodingPipelineBucket.InFlight => "Active",
        CodingPipelineBucket.Shipped => "Shipped",
        _ => "Active",
    };

    public static string SectionTitle(this CodingPipelineBucket bucket) => bucket switch
    {
        CodingPipelineBucket.Ready => "Ready to Ship",
        CodingPipelineBucket.NeedsYou => "Needs You",
        CodingPipelineBucket.InFlight => "Active",
        CodingPipelineBucket.Shipped => "Shipped",
        _ => "Active",
    };

    public static string SectionId(this CodingPipelineBucket bucket) => bucket switch
    {
        CodingPipelineBucket.Ready => SessionListPipeline.PipelineReady,
        CodingPipelineBucket.NeedsYou => SessionListPipeline.PipelineNeeds,
        CodingPipelineBucket.InFlight => SessionListPipeline.PipelineInFlight,
        CodingPipelineBucket.Shipped => SessionListPipeline.PipelineShipped,
        _ => SessionListPipeline.PipelineInFlight,
    };

    public static bool CollapsedByDefault(this CodingPipelineBucket bucket) =>
        bucket == CodingPipelineBucket.Shipped;
}

/// Pure 4-bucket classifier matching `HermesKit/Model/CodingPipeline.swift` 1-to-1 so header counts and list sections align.
public static class CodingPipeline
{
    public static readonly IReadOnlyList<CodingPipelineBucket> AllBuckets =
    [
        CodingPipelineBucket.Ready,
        CodingPipelineBucket.NeedsYou,
        CodingPipelineBucket.InFlight,
        CodingPipelineBucket.Shipped,
    ];

    public static CodingPipelineBucket BucketFor(SessionSummary session, SessionPRStatus? prOverride = null, bool isDone = false)
    {
        var working = session.IsRunning || session.Status == SessionStatus.Working;
        var needsInput = session.Status == SessionStatus.NeedsInput;
        var pr = prOverride ?? session.PullRequest;

        if (needsInput) return CodingPipelineBucket.NeedsYou;
        if (isDone || (session.Archived && !working)) return CodingPipelineBucket.Shipped;
        if (pr != null && pr.State is SessionPRState.Open or SessionPRState.Draft && pr.Checks?.State == SessionPRCheckState.Failed)
            return CodingPipelineBucket.NeedsYou;
        if (pr != null && pr.State == SessionPRState.Open && !working && pr.Checks?.State != SessionPRCheckState.Running)
            return CodingPipelineBucket.Ready;
        if (session.Unread && !working) return CodingPipelineBucket.NeedsYou;
        if (pr != null && pr.State is SessionPRState.Merged or SessionPRState.Closed && !working)
            return CodingPipelineBucket.Shipped;
        return CodingPipelineBucket.InFlight;
    }

    public static Dictionary<CodingPipelineBucket, int> Counts(
        IEnumerable<SessionSummary> rows,
        IReadOnlyDictionary<string, SessionPRStatus>? prBySessionKey = null,
        Func<SessionSummary, bool>? isDone = null)
    {
        var counts = new Dictionary<CodingPipelineBucket, int>
        {
            [CodingPipelineBucket.Ready] = 0,
            [CodingPipelineBucket.NeedsYou] = 0,
            [CodingPipelineBucket.InFlight] = 0,
            [CodingPipelineBucket.Shipped] = 0,
        };
        foreach (var row in rows)
        {
            var pr = CodingPipelineEngine.ResolvePR(row, prBySessionKey);
            var done = isDone != null && isDone(row);
            counts[BucketFor(row, pr, done)]++;
        }
        return counts;
    }

    public static bool IsReadyToMerge(SessionSummary session, SessionPRStatus? prOverride = null)
    {
        var pr = prOverride ?? session.PullRequest;
        return BucketFor(session, pr) == CodingPipelineBucket.Ready && pr?.State == SessionPRState.Open;
    }

    public static bool HasFailingChecks(SessionSummary session, SessionPRStatus? prOverride = null)
    {
        var pr = prOverride ?? session.PullRequest;
        if (pr == null || session.Archived) return false;
        return pr.State is SessionPRState.Open or SessionPRState.Draft && pr.Checks?.State == SessionPRCheckState.Failed;
    }

    /// Sort priority within a bucket: pinned first, then most urgent sub-state, then recency (`CodingPipeline.swift`).
    public static int SubRank(SessionSummary session, CodingPipelineBucket bucket, SessionPRStatus? prOverride = null)
    {
        var pr = prOverride ?? session.PullRequest;
        var pinBonus = (session.Pinned || session.ProjectPinned) ? 0 : 10;
        return bucket switch
        {
            CodingPipelineBucket.Ready => pinBonus + (pr?.Checks?.State == SessionPRCheckState.Passed ? 0 : 1),
            CodingPipelineBucket.NeedsYou => session.Status == SessionStatus.NeedsInput
                ? pinBonus
                : HasFailingChecks(session, pr) ? pinBonus + 1 : pinBonus + 2,
            CodingPipelineBucket.InFlight => (session.IsRunning || session.Status == SessionStatus.Working)
                ? pinBonus
                : pr?.Checks?.State == SessionPRCheckState.Running
                    ? pinBonus + 1
                    : pr?.State is SessionPRState.Draft or SessionPRState.Open
                        ? pinBonus + 2
                        : pinBonus + 3,
            CodingPipelineBucket.Shipped => pinBonus,
            _ => pinBonus,
        };
    }
}

/// One row in the 4-bucket calm shipping pipeline view.
public sealed record CodingBucketRow(
    SessionSummary Session,
    SessionPRStatus? PrStatus,
    CodingPipelineBucket Bucket,
    PRVerdict? Verdict,
    string? Branch,
    DateTimeOffset SortMoment)
{
    public bool IsReadyToMerge => Bucket == CodingPipelineBucket.Ready && PrStatus?.State == SessionPRState.Open;
    public bool HasFailingChecks => CodingPipeline.HasFailingChecks(Session, PrStatus);
}

/// One visual section in the 4-bucket calm shipping pipeline (`Ready to Ship`, `Needs You`, `Active`, `Shipped`).
public sealed record CodingBucketSection(
    string Id,
    string Title,
    CodingPipelineBucket? Bucket,
    IReadOnlyList<CodingBucketRow> Rows,
    bool CollapsedByDefault = false);

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
    public CodingPipelineBucket? SelectedBucket { get; init; }
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

    /// Resolves a session's PR status from the lookup dictionary (handling both `\u001F` and `:` keys) or inline `SessionSummary.PullRequest`.
    public static SessionPRStatus? ResolvePR(SessionSummary session, IReadOnlyDictionary<string, SessionPRStatus>? prBySessionKey)
    {
        if (prBySessionKey != null)
        {
            if (prBySessionKey.TryGetValue(session.Key, out var byKey)) return byKey;
            if (prBySessionKey.TryGetValue($"{session.Profile}:{session.Id}", out var byColon)) return byColon;
        }
        return session.PullRequest;
    }

    /// Builds filtered and sorted 4-bucket shipping pipeline sections (`Ready to Ship`, `Needs You`, `Active`, `Shipped`
    /// collapsed by default), honoring `SelectedBucket` across `NeedsMeFirst`, `ByStatus`, and `Newest` sorts (`1f3a49712`).
    public static IReadOnlyList<CodingBucketSection> BuildBucketSections(
        IEnumerable<SessionSummary> sessions,
        IReadOnlyDictionary<string, SessionPRStatus>? prBySessionKey,
        ProjectPageSort sort,
        CodingPipelineFilter filter,
        Func<SessionSummary, bool>? isDone = null)
    {
        var rows = new List<CodingBucketRow>();
        var query = filter.SearchQuery.Trim();

        foreach (var session in sessions)
        {
            if (!string.IsNullOrWhiteSpace(filter.FilterByBot)
                && !string.Equals(session.Profile, filter.FilterByBot, StringComparison.OrdinalIgnoreCase))
                continue;

            var pr = ResolvePR(session, prBySessionKey);
            if (filter.SelectedPRState is { } pickedState && (pr == null || !pr.CountedStates.Contains(pickedState)))
                continue;

            var done = isDone != null && isDone(session);
            var bucket = CodingPipeline.BucketFor(session, pr, done);
            if (filter.SelectedBucket is { } pickedBucket && bucket != pickedBucket)
                continue;

            if (query.Length > 0 && !MatchesSearch(session, pr, query))
                continue;

            var verdict = PRVerdict.ForActiveRow(pr);
            var branch = pr?.Branch ?? session.Branch;
            var moment = session.LastActive ?? session.StartedAt ?? DateTimeOffset.MinValue;
            rows.Add(new CodingBucketRow(session, pr, bucket, verdict, branch, moment));
        }

        if (rows.Count == 0) return [];

        if (sort == ProjectPageSort.Newest)
        {
            var ordered = rows
                .OrderByDescending(r => r.Session.ProjectPinned || r.Session.Pinned)
                .ThenByDescending(r => r.SortMoment)
                .ThenBy(r => r.Session.Id, StringComparer.Ordinal)
                .ToList();
            return [new CodingBucketSection("newest", filter.SelectedBucket?.SectionTitle() ?? "Newest", filter.SelectedBucket, ordered)];
        }

        // NeedsMeFirst and ByStatus both present the 4 calm decision-first buckets (matching `SessionListPipeline.swift` `1f3a49712`).
        var sections = new List<CodingBucketSection>();
        foreach (var bucket in CodingPipeline.AllBuckets)
        {
            var group = rows
                .Where(r => r.Bucket == bucket)
                .OrderBy(r => CodingPipeline.SubRank(r.Session, bucket, r.PrStatus))
                .ThenByDescending(r => r.SortMoment)
                .ThenBy(r => r.Session.Id, StringComparer.Ordinal)
                .ToList();
            if (group.Count == 0) continue;
            sections.Add(new CodingBucketSection(
                Id: bucket.SectionId(),
                Title: bucket.SectionTitle(),
                Bucket: bucket,
                Rows: group,
                CollapsedByDefault: bucket.CollapsedByDefault() && filter.SelectedBucket == null));
        }
        return sections;
    }

    /// Computes 4-bucket header counts matching `BuildBucketSections` 1-to-1 (respecting bot & search filters).
    public static Dictionary<CodingPipelineBucket, int> ComputeBucketCounts(
        IEnumerable<SessionSummary> sessions,
        IReadOnlyDictionary<string, SessionPRStatus>? prBySessionKey,
        string? filterByBot = null,
        string? searchQuery = null,
        Func<SessionSummary, bool>? isDone = null)
    {
        var counts = new Dictionary<CodingPipelineBucket, int>
        {
            [CodingPipelineBucket.Ready] = 0,
            [CodingPipelineBucket.NeedsYou] = 0,
            [CodingPipelineBucket.InFlight] = 0,
            [CodingPipelineBucket.Shipped] = 0,
        };
        var query = (searchQuery ?? "").Trim();
        foreach (var session in sessions)
        {
            if (!string.IsNullOrWhiteSpace(filterByBot)
                && !string.Equals(session.Profile, filterByBot, StringComparison.OrdinalIgnoreCase))
                continue;
            var pr = ResolvePR(session, prBySessionKey);
            if (query.Length > 0 && !MatchesSearch(session, pr, query))
                continue;
            var done = isDone != null && isDone(session);
            counts[CodingPipeline.BucketFor(session, pr, done)]++;
        }
        return counts;
    }

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
            var pr = ResolvePR(session, prBySessionKey);
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
            var pr = ResolvePR(session, prBySessionKey);
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
    public static CodingHealthBanner? Health(bool codingProject, SessionPRRepo? repo, SessionPRReposState reposState) =>
        Health(codingProject, repo, reposState, prAutoLinkFailed: false, prUnsupported: false, rowStatuses: null);

    /// Full project coding health diagnostic matching `ProjectPage.swift` `projectCodingHealth`.
    public static CodingHealthBanner? Health(
        bool codingProject,
        SessionPRRepo? repo,
        SessionPRReposState reposState,
        bool prAutoLinkFailed,
        bool prUnsupported = false,
        IReadOnlyList<SessionPRStatus?>? rowStatuses = null)
    {
        if (!codingProject) return null;
        if (prUnsupported || reposState == SessionPRReposState.Unsupported)
            return new CodingHealthBanner("unsupported", "Pull request tracking needs the Hermes HQ add-on.", "");
        if (reposState == SessionPRReposState.Loading && repo == null)
            return new CodingHealthBanner("checking", "Checking repository…", "Looking up pull request status for this project.");
        if (reposState == SessionPRReposState.Failed && repo == null)
            return new CodingHealthBanner("unavailable", "Couldn’t check repository link.", "Reconnect or open Repository settings to verify this folder.", "Retry");
        if (repo == null && prAutoLinkFailed)
            return new CodingHealthBanner("needsRepo", "Link a git repository to track pull requests.", "This project folder isn’t a git repository on the gateway.", "Link…");
        if (repo == null)
            return new CodingHealthBanner("unlinked", "Link a git repository to track pull requests.", "Connect this project’s folder and GitHub repo to track checks, reviews, and merge readiness.", "Link…");

        if (rowStatuses is { Count: > 0 })
        {
            var unavailable = rowStatuses.Count(s => s?.State == SessionPRState.Unknown && s.UnknownReason == SessionPRUnknownReason.Unavailable);
            var unmatched = rowStatuses.Count(s => s?.State == SessionPRState.Unknown && s.UnknownReason == SessionPRUnknownReason.Unmatched);
            var matched = rowStatuses.Count(s => s != null && s.State != SessionPRState.Unknown);
            if (unavailable > 0 && unavailable == rowStatuses.Count)
                return new CodingHealthBanner("unavailable", "Couldn’t reach the gateway for pull request status.", "Retry once the gateway is reachable.", "Retry");
            if (matched == 0 && unmatched > 0)
                return new CodingHealthBanner("unmatched", $"No chats matched {RepoPathHelpers.FolderName(repo.Path)}.", "Check the linked folder in Repository settings.", "Repository…");
        }
        return null;
    }

    private static bool MatchesSearch(SessionSummary session, SessionPRStatus? pr, string query) =>
        session.Title.Contains(query, StringComparison.OrdinalIgnoreCase)
        || (session.Branch?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false)
        || (pr?.Title?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false)
        || (pr?.Branch?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false)
        || (pr?.Repo?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false)
        || (pr?.Number is { } num && $"#{num}".Contains(query, StringComparison.OrdinalIgnoreCase));

    private static bool MatchesFilter(
        SessionSummary session,
        SessionPRStatus? pr,
        CodingPipelineStage stage,
        CodingPipelineFilter filter)
    {
        if (!string.IsNullOrWhiteSpace(filter.FilterByBot)
            && !string.Equals(session.Profile, filter.FilterByBot, StringComparison.OrdinalIgnoreCase))
            return false;

        if (filter.SelectedBucket is { } pickedBucket && CodingPipeline.BucketFor(session, pr) != pickedBucket)
            return false;

        if (filter.SelectedPRState is { } pickedState)
        {
            if (pr == null || !pr.CountedStates.Contains(pickedState)) return false;
        }
        else if (filter.SelectedBucket == null)
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
        if (query.Length > 0 && !MatchesSearch(session, pr, query))
            return false;

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
