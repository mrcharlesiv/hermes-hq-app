using System.Text.Json.Nodes;

namespace Hermes.Core.Coding;

/// Pull request lifecycle state reported by the gateway add-on (`SessionPRStatus.State`).
public enum SessionPRState
{
    None,
    Draft,
    Open,
    Merged,
    Closed,
    Unknown,
}

/// Why a PR status could not be confirmed (`SessionPRStatus.UnknownReason`).
public enum SessionPRUnknownReason
{
    Checking,
    Unavailable,
    Unsupported,
    Unmatched,
}

/// Where a PR or branch item came from (`SessionPRItem.Source`).
public enum SessionPRSource
{
    GitHub,
    Git,
}

/// Aggregated or individual check status (`SessionPRChecks.State`).
public enum SessionPRCheckState
{
    Passed,
    Failed,
    Running,
}

/// Review decision for a pull request.
public enum PRReviewVerdict
{
    None,
    Approved,
    ChangesRequested,
    ReviewRequired,
    Commented,
}

/// Line and file diff totals for a PR or branch.
public sealed record SessionPRSize(int Files, int Additions, int Deletions)
{
    /// "+128 −12" using true minus (U+2212), matching `PRVerdict.swift`.
    public string FormattedDelta => $"+{Additions} \u2212{Deletions}";
    public string SpokenDelta => $"{Additions} added, {Deletions} removed across {Files} {(Files == 1 ? "file" : "files")}";
}

/// One CI check run reported for a PR.
public sealed record SessionPRCheckRun(
    string Name,
    SessionPRCheckState State,
    string? Url = null,
    string? Summary = null);

/// Rollup of checks on a PR.
public sealed record SessionPRChecks(
    SessionPRCheckState State,
    int Passed,
    int Failed,
    int Running,
    IReadOnlyList<SessionPRCheckRun> Runs)
{
    public int Total => Passed + Failed + Running;
}

/// One changed file in a PR's detail payload.
public sealed record SessionPRFile(
    string Path,
    int Additions,
    int Deletions,
    bool Binary = false,
    string? Patch = null,
    bool PatchCut = false);

/// One PR or branch associated with a coding session (`SessionPRItem`).
public sealed record SessionPRItem(
    SessionPRSource Source,
    SessionPRState State,
    string? Repo,
    string? Branch,
    int? Number,
    string? Url,
    SessionPRSize? Size = null,
    SessionPRChecks? Checks = null,
    PRReviewVerdict ReviewVerdict = PRReviewVerdict.None,
    int CommentsCount = 0,
    string? Title = null,
    string? Base = null,
    IReadOnlyList<SessionPRFile>? Files = null)
{
    /// Short badge label: "#42" for a GitHub PR, else the branch name, else the state word.
    public string Label => Number is { } n
        ? $"#{n}"
        : !string.IsNullOrWhiteSpace(Branch)
            ? Branch!
            : State.LabelWord();

    /// Projects this single item as a standalone `SessionPRStatus`.
    public SessionPRStatus ToStatus(bool manual = false) => new(
        State: State,
        UnknownReason: State == SessionPRState.Unknown ? SessionPRUnknownReason.Unavailable : null,
        Repo: Repo,
        Branch: Branch,
        Number: Number,
        Url: Url,
        Manual: manual,
        Items: [this],
        Size: Size,
        Checks: Checks,
        ReviewVerdict: ReviewVerdict,
        CommentsCount: CommentsCount,
        Title: Title,
        Base: Base,
        Files: Files ?? []);
}

/// A session's aggregated PR status (`SessionPRStatus` in HermesKit).
public sealed record SessionPRStatus(
    SessionPRState State,
    SessionPRUnknownReason? UnknownReason = null,
    string? Repo = null,
    string? Branch = null,
    int? Number = null,
    string? Url = null,
    bool Manual = false,
    IReadOnlyList<SessionPRItem>? Items = null,
    SessionPRSize? Size = null,
    SessionPRChecks? Checks = null,
    PRReviewVerdict ReviewVerdict = PRReviewVerdict.None,
    int CommentsCount = 0,
    string? Title = null,
    string? Base = null,
    IReadOnlyList<SessionPRFile>? Files = null)
{
    public IReadOnlyList<SessionPRItem> AllItems => Items ?? [];
    public IReadOnlyList<SessionPRFile> AllFiles => Files ?? [];

    public bool IsPendingCheck => State == SessionPRState.Unknown && UnknownReason == SessionPRUnknownReason.Checking;

    public bool DrawsMark => State != SessionPRState.None && !IsPendingCheck;

    public string? UnknownExplanation => UnknownReason switch
    {
        SessionPRUnknownReason.Checking => "Checking pull request status…",
        SessionPRUnknownReason.Unavailable => "Couldn’t reach GitHub for this pull request.",
        SessionPRUnknownReason.Unsupported => "Pull request checks need a newer Hermes HQ add-on.",
        SessionPRUnknownReason.Unmatched => "This chat’s branch isn’t linked to a repository yet.",
        _ => null,
    };

    /// How many PRs/branches on this chat are still open or draft.
    public int WaitingCount => AllItems.Count > 0
        ? AllItems.Count(i => i.State is SessionPRState.Open or SessionPRState.Draft)
        : State is SessionPRState.Open or SessionPRState.Draft ? 1 : 0;

    /// Distinct non-empty states represented by this status.
    public IReadOnlySet<SessionPRState> CountedStates
    {
        get
        {
            var set = new HashSet<SessionPRState>();
            if (AllItems.Count > 0)
            {
                foreach (var item in AllItems)
                    if (item.State != SessionPRState.None) set.Add(item.State);
            }
            else if (State != SessionPRState.None)
            {
                set.Add(State);
            }
            return set;
        }
    }

    /// Short label for the lead PR or branch.
    public string Label => Number is { } n
        ? $"#{n}"
        : !string.IsNullOrWhiteSpace(Branch)
            ? Branch!
            : State.LabelWord();

    /// One-line summary for row subtitles and accessibility.
    public string Summary
    {
        get
        {
            if (State == SessionPRState.None) return "";
            if (State == SessionPRState.Unknown) return UnknownExplanation ?? "Status unknown";
            var lead = Number is { } n ? $"PR #{n} · {State.LabelWord()}" : State.LabelWord();
            var extra = AllItems.Count > 1 ? $" (+{AllItems.Count - 1})" : "";
            return lead + extra;
        }
    }

    /// Up to `limit` short tags ("#42", "#45") for multi-PR rows.
    public IReadOnlyList<string> Tags(int limit = 2)
    {
        if (limit <= 0) return [];
        if (AllItems.Count > 0)
            return [.. AllItems.Select(i => i.Label).Where(l => l.Length > 0).Distinct(StringComparer.Ordinal).Take(limit)];
        return DrawsMark ? [Label] : [];
    }

    public static SessionPRStatus From(JsonNode? node) => PRFacts.ParseStatus(node);
}

public static class SessionPRStateExtensions
{
    public static string WireValue(this SessionPRState state) => state switch
    {
        SessionPRState.Draft => "draft",
        SessionPRState.Open => "open",
        SessionPRState.Merged => "merged",
        SessionPRState.Closed => "closed",
        SessionPRState.Unknown => "unknown",
        _ => "none",
    };

    public static string LabelWord(this SessionPRState state) => state switch
    {
        SessionPRState.Draft => "Draft",
        SessionPRState.Open => "Open",
        SessionPRState.Merged => "Merged",
        SessionPRState.Closed => "Closed",
        SessionPRState.Unknown => "Unknown",
        _ => "No PR",
    };

    public static string LabelWord(this PRReviewVerdict verdict) => verdict switch
    {
        PRReviewVerdict.Approved => "Approved",
        PRReviewVerdict.ChangesRequested => "Changes requested",
        PRReviewVerdict.ReviewRequired => "Review required",
        PRReviewVerdict.Commented => "Commented",
        _ => "",
    };
}

/// Visual tone for a PR verdict pill (`PRVerdictView.swift`).
public enum PRVerdictTone
{
    Positive,
    Critical,
    Active,
    Neutral,
}

/// The calm one-line verdict on a PR row (`PRVerdict` in `HermesKit/Model/PullRequestFacts.swift`).
public abstract record PRVerdict
{
    public sealed record Passed(SessionPRSize? DiffSize = null) : PRVerdict;
    public sealed record Failing(int Count) : PRVerdict;
    public sealed record Running : PRVerdict;
    public sealed record SizeOnly(SessionPRSize DiffSize) : PRVerdict;

    public string Words => this switch
    {
        Failing { Count: var c } => c == 1 ? "1 check failing" : $"{c} checks failing",
        Running => "checks running",
        Passed { DiffSize: { } s } => s.FormattedDelta,
        Passed => "checks passed",
        SizeOnly { DiffSize: var s } => s.FormattedDelta,
        _ => "",
    };

    public string Spoken => this switch
    {
        Failing { Count: var c } => c == 1 ? "1 check failing" : $"{c} checks failing",
        Running => "Checks running",
        Passed { DiffSize: { } s } => $"Checks passed, {s.SpokenDelta}",
        Passed => "Checks passed",
        SizeOnly { DiffSize: var s } => s.SpokenDelta,
        _ => "",
    };

    public PRVerdictTone Tone => this switch
    {
        Failing => PRVerdictTone.Critical,
        Running => PRVerdictTone.Active,
        Passed => PRVerdictTone.Positive,
        _ => PRVerdictTone.Neutral,
    };

    public static PRVerdict? From(SessionPRChecks? checks, SessionPRSize? size)
    {
        if (checks != null)
        {
            return checks.State switch
            {
                SessionPRCheckState.Failed => new Failing(Math.Max(1, checks.Failed)),
                SessionPRCheckState.Running => new Running(),
                SessionPRCheckState.Passed => new Passed(size),
                _ => size != null ? new SizeOnly(size) : null,
            };
        }
        return size != null ? new SizeOnly(size) : null;
    }

    public static PRVerdict? From(SessionPRStatus status) => From(status.Checks, status.Size);

    public static PRVerdict? From(SessionPRItem item) => From(item.Checks, item.Size);
}

/// Tolerant JSON decoder & URL validator matching `HermesKit/Model/PullRequestFacts.swift`.
public static class PRFacts
{
    public const int TitleLimit = 200;
    public const int RunLimit = 30;
    public const int RunNameLimit = 120;
    public const int FileLimit = 50;
    public const int PatchLimit = 20_000;

    public static SessionPRStatus ParseStatus(JsonNode? node)
    {
        if (node is not JsonObject)
            return new SessionPRStatus(SessionPRState.None);

        var state = ParseState(node.Str("state"));
        var unknownReason = state == SessionPRState.Unknown ? ParseUnknownReason(node.Str("reason") ?? node.Str("unknown_reason")) : (SessionPRUnknownReason?)null;
        var items = ParseItems(node.Arr("items"));
        var size = ParseSize(node.Obj("size"));
        var checks = ParseChecks(node.Obj("checks"));
        var files = ParseFiles(node.Arr("files"));
        var url = ValidGitHubPullUrl(node.Str("url"));
        var number = node.Int("number") is { } n and > 0 ? (int)n : (int?)null;
        var comments = node.Int("comments") ?? node.Int("comments_count") ?? 0;

        return new SessionPRStatus(
            State: state,
            UnknownReason: unknownReason,
            Repo: Clean(node.Str("repo"), 160),
            Branch: Clean(node.Str("branch"), 200),
            Number: number,
            Url: url,
            Manual: node.Bool("manual") ?? false,
            Items: items,
            Size: size,
            Checks: checks,
            ReviewVerdict: ParseReviewVerdict(node.Str("review_decision") ?? node.Str("review_verdict") ?? node.Str("review")),
            CommentsCount: (int)Math.Max(0, comments),
            Title: Clean(node.Str("title"), TitleLimit),
            Base: Clean(node.Str("base"), 120),
            Files: files);
    }

    public static IReadOnlyList<SessionPRItem> ParseItems(JsonArray? arr)
    {
        if (arr == null) return [];
        var list = new List<SessionPRItem>();
        foreach (var node in arr)
        {
            if (ParseItem(node) is { } item) list.Add(item);
        }
        return list;
    }

    public static SessionPRItem? ParseItem(JsonNode? node)
    {
        if (node is not JsonObject) return null;
        var source = string.Equals(node.Str("source"), "git", StringComparison.OrdinalIgnoreCase)
            ? SessionPRSource.Git
            : SessionPRSource.GitHub;
        var state = ParseState(node.Str("state"));
        var number = node.Int("number") is { } n and > 0 ? (int)n : (int?)null;
        var comments = node.Int("comments") ?? node.Int("comments_count") ?? 0;
        return new SessionPRItem(
            Source: source,
            State: state,
            Repo: Clean(node.Str("repo"), 160),
            Branch: Clean(node.Str("branch"), 200),
            Number: number,
            Url: ValidGitHubPullUrl(node.Str("url")),
            Size: ParseSize(node.Obj("size")),
            Checks: ParseChecks(node.Obj("checks")),
            ReviewVerdict: ParseReviewVerdict(node.Str("review_decision") ?? node.Str("review_verdict") ?? node.Str("review")),
            CommentsCount: (int)Math.Max(0, comments),
            Title: Clean(node.Str("title"), TitleLimit),
            Base: Clean(node.Str("base"), 120),
            Files: ParseFiles(node.Arr("files")));
    }

    public static SessionPRSize? ParseSize(JsonObject? obj)
    {
        if (obj == null) return null;
        var files = (int)Math.Max(0, obj.Int("files") ?? 0);
        var add = (int)Math.Max(0, obj.Int("additions") ?? 0);
        var del = (int)Math.Max(0, obj.Int("deletions") ?? 0);
        if (files == 0 && add == 0 && del == 0 && obj.Get("files") == null && obj.Get("additions") == null && obj.Get("deletions") == null)
            return null;
        return new SessionPRSize(files, add, del);
    }

    public static SessionPRChecks? ParseChecks(JsonObject? obj)
    {
        if (obj == null) return null;
        var rawState = obj.Str("state")?.Trim().ToLowerInvariant();
        if (string.IsNullOrEmpty(rawState)) return null;
        var state = rawState switch
        {
            "passed" or "success" => SessionPRCheckState.Passed,
            "failed" or "failure" or "error" => SessionPRCheckState.Failed,
            "running" or "pending" or "in_progress" or "queued" => SessionPRCheckState.Running,
            _ => (SessionPRCheckState?)null,
        };
        if (state == null) return null;

        var runs = new List<SessionPRCheckRun>();
        if (obj.Arr("runs") is { } rawRuns)
        {
            foreach (var r in rawRuns)
            {
                if (runs.Count >= RunLimit) break;
                if (r is not JsonObject) continue;
                var name = Clean(r.Str("name"), RunNameLimit);
                if (name == null) continue;
                var runState = (r.Str("state")?.Trim().ToLowerInvariant()) switch
                {
                    "passed" or "success" => SessionPRCheckState.Passed,
                    "failed" or "failure" or "error" => SessionPRCheckState.Failed,
                    _ => SessionPRCheckState.Running,
                };
                runs.Add(new SessionPRCheckRun(name, runState, ValidCheckRunUrl(r.Str("url")), Clean(r.Str("summary"), 240)));
            }
        }

        var passed = (int)Math.Max(0, obj.Int("passed") ?? runs.Count(x => x.State == SessionPRCheckState.Passed));
        var failed = (int)Math.Max(0, obj.Int("failed") ?? runs.Count(x => x.State == SessionPRCheckState.Failed));
        var running = (int)Math.Max(0, obj.Int("running") ?? runs.Count(x => x.State == SessionPRCheckState.Running));
        return new SessionPRChecks(state.Value, passed, failed, running, runs);
    }

    public static IReadOnlyList<SessionPRFile> ParseFiles(JsonArray? arr)
    {
        if (arr == null) return [];
        var list = new List<SessionPRFile>();
        foreach (var node in arr)
        {
            if (list.Count >= FileLimit) break;
            if (node is not JsonObject) continue;
            var path = Clean(node.Str("path"), 400);
            if (path == null) continue;
            var binary = node.Bool("binary") ?? false;
            var rawPatch = binary ? null : node.Str("patch");
            var patchCut = node.Bool("patch_cut") ?? node.Bool("patchCut") ?? false;
            if (rawPatch is { Length: > PatchLimit })
            {
                rawPatch = rawPatch[..PatchLimit];
                patchCut = true;
            }
            list.Add(new SessionPRFile(
                Path: path,
                Additions: (int)Math.Max(0, node.Int("additions") ?? 0),
                Deletions: (int)Math.Max(0, node.Int("deletions") ?? 0),
                Binary: binary,
                Patch: string.IsNullOrEmpty(rawPatch) ? null : rawPatch,
                PatchCut: patchCut));
        }
        return list;
    }

    public static SessionPRState ParseState(string? raw) => (raw?.Trim().ToLowerInvariant()) switch
    {
        "draft" => SessionPRState.Draft,
        "open" => SessionPRState.Open,
        "merged" => SessionPRState.Merged,
        "closed" => SessionPRState.Closed,
        "unknown" => SessionPRState.Unknown,
        _ => SessionPRState.None,
    };

    public static SessionPRUnknownReason ParseUnknownReason(string? raw) => (raw?.Trim().ToLowerInvariant()) switch
    {
        "checking" => SessionPRUnknownReason.Checking,
        "unsupported" => SessionPRUnknownReason.Unsupported,
        "unmatched" => SessionPRUnknownReason.Unmatched,
        _ => SessionPRUnknownReason.Unavailable,
    };

    public static PRReviewVerdict ParseReviewVerdict(string? raw) => (raw?.Trim().ToLowerInvariant()) switch
    {
        "approved" => PRReviewVerdict.Approved,
        "changes_requested" or "changes-requested" or "changes requested" => PRReviewVerdict.ChangesRequested,
        "review_required" or "review-required" or "review required" => PRReviewVerdict.ReviewRequired,
        "commented" => PRReviewVerdict.Commented,
        _ => PRReviewVerdict.None,
    };

    /// Only strict `https://github.com/<owner>/<repo>/pull/<n>` (or `/commit/...`, `/tree/...`) URLs are accepted.
    public static string? ValidGitHubPullUrl(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        if (!Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var uri)) return null;
        if (!string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)) return null;
        if (!string.Equals(uri.Host, "github.com", StringComparison.OrdinalIgnoreCase)) return null;
        var segments = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length < 4) return null;
        if (segments[2] is not ("pull" or "commit" or "tree" or "compare")) return null;
        return uri.AbsoluteUri;
    }

    /// Strict HTTPS URL on github.com or known CI hosts for a check run.
    public static string? ValidCheckRunUrl(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        if (!Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var uri)) return null;
        if (!string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)) return null;
        if (string.IsNullOrEmpty(uri.Host)) return null;
        if (uri.IsLoopback) return null;
        return uri.AbsoluteUri;
    }

    private static string? Clean(string? raw, int limit)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        var trimmed = raw.Trim();
        return trimmed.Length > limit ? trimmed[..limit] : trimmed;
    }
}
