using Hermes.Core.Sessions;

namespace Hermes.Core.Coding;

/// Which item on a multi-PR session the PR card is currently showing (`PullRequestCard.Focus`).
public abstract record PullRequestCardFocus
{
    public sealed record Lead : PullRequestCardFocus;
    public sealed record Item(int Index) : PullRequestCardFocus;
}

/// Quick actions available on a PR card.
public enum PullRequestQuickAction
{
    Merge,
    Approve,
    RequestChanges,
    OpenInBrowser,
    AskBotToFixCI,
    AskBotToFixReview,
    Checkout,
    MarkClosed,
    Reopen,
    OpenChat,
}

/// One action button on a PR card with optional confirmation copy and bot prompt text.
public sealed record PullRequestActionItem(
    PullRequestQuickAction Kind,
    string Label,
    bool Primary = false,
    bool Destructive = false,
    string? ConfirmationTitle = null,
    string? ConfirmationMessage = null,
    string? BotPrompt = null);

/// Checks summary row inside the PR card (`PullRequestCardDetail.swift`).
public sealed record PullRequestChecksRow(
    string Summary,
    SessionPRCheckState State,
    IReadOnlyList<SessionPRCheckRun> Runs)
{
    public bool CanDrillIn => Runs.Count > 0;
}

/// How a changed file's diff body can be displayed.
public enum PullRequestFileBodyKind
{
    Patch,
    Binary,
    TooLarge,
    None,
}

/// One changed file row in the PR card.
public sealed record PullRequestFileRow(
    string Path,
    string FileName,
    string Directory,
    int Additions,
    int Deletions,
    PullRequestFileBodyKind BodyKind,
    string? Patch,
    bool PatchCut,
    int CommentCount)
{
    public string StatsLabel => Binary ? "Binary" : $"+{Additions} \u2212{Deletions}";
    public bool Binary => BodyKind == PullRequestFileBodyKind.Binary;
    public bool CanOpenDiff => BodyKind == PullRequestFileBodyKind.Patch && !string.IsNullOrEmpty(Patch);
}

/// Another PR or branch in the same chat (`Also in This Chat`).
public sealed record PullRequestSiblingRow(
    int Index,
    string Label,
    string? Title,
    SessionPRState State,
    PRVerdict? Verdict);

/// Complete presentation model for `PullRequestCardView` (`HermesKit/Model/PullRequestCard.swift` + `PullRequestCardDetail.swift`).
public sealed record PullRequestCardModel
{
    public required string SessionKey { get; init; }
    public required string Profile { get; init; }
    public required string SessionId { get; init; }
    public required SessionPRState State { get; init; }
    public SessionPRUnknownReason? UnknownReason { get; init; }
    public string? UnknownExplanation { get; init; }
    public required string Title { get; init; }
    public required string BadgeLabel { get; init; }
    public string? Repo { get; init; }
    public string? Branch { get; init; }
    public string? Base { get; init; }
    public int? Number { get; init; }
    public string? Url { get; init; }
    public bool Manual { get; init; }
    public PRReviewVerdict ReviewVerdict { get; init; }
    public int CommentsCount { get; init; }
    public SessionPRSize? Size { get; init; }
    public PRVerdict? Verdict { get; init; }
    public PullRequestChecksRow? Checks { get; init; }
    public string? ChangesLabel { get; init; }
    public IReadOnlyList<PullRequestFileRow> Files { get; init; } = [];
    public string? MoreFilesWords { get; init; }
    public IReadOnlyList<PullRequestActionItem> Actions { get; init; } = [];
    public IReadOnlyList<PullRequestSiblingRow> Others { get; init; } = [];
    public string? RefreshedText { get; init; }

    public string BranchRoute => !string.IsNullOrWhiteSpace(Branch) && !string.IsNullOrWhiteSpace(Base)
        ? $"{Branch} \u2192 {Base}"
        : Branch ?? "";

    public static PullRequestCardModel Build(
        SessionSummary session,
        SessionPRStatus status,
        PullRequestCardFocus? focus = null,
        IReadOnlyDictionary<string, int>? fileCommentCounts = null,
        DateTimeOffset? refreshedAt = null,
        DateTimeOffset? now = null)
    {
        focus ??= new PullRequestCardFocus.Lead();
        SessionPRItem? focusedItem = null;
        var focusedIndex = -1;
        if (focus is PullRequestCardFocus.Item { Index: var idx } && idx >= 0 && idx < status.AllItems.Count)
        {
            focusedItem = status.AllItems[idx];
            focusedIndex = idx;
        }
        else if (status.AllItems.Count > 0)
        {
            focusedIndex = 0;
        }

        var state = focusedItem?.State ?? status.State;
        var repo = focusedItem?.Repo ?? status.Repo;
        var branch = focusedItem?.Branch ?? status.Branch;
        var baseBranch = focusedItem?.Base ?? status.Base;
        var number = focusedItem?.Number ?? status.Number;
        var url = focusedItem?.Url ?? status.Url;
        var size = focusedItem?.Size ?? status.Size;
        var checks = focusedItem?.Checks ?? status.Checks;
        var review = focusedItem?.ReviewVerdict ?? status.ReviewVerdict;
        var comments = focusedItem?.CommentsCount ?? status.CommentsCount;
        var title = focusedItem?.Title ?? status.Title ?? session.Title;
        var files = focusedItem?.Files ?? status.AllFiles;

        var checksRow = checks != null ? BuildChecksRow(checks) : null;
        var fileRows = files.Select(f => BuildFileRow(f, fileCommentCounts)).ToList();

        string? changesLabel = null;
        if (size != null)
            changesLabel = $"{size.Files} {(size.Files == 1 ? "file" : "files")} · {size.FormattedDelta}";
        else if (fileRows.Count > 0)
            changesLabel = $"{fileRows.Count} {(fileRows.Count == 1 ? "file" : "files")}";

        string? moreFilesWords = null;
        if (size != null && fileRows.Count > 0 && size.Files > fileRows.Count)
        {
            var extra = size.Files - fileRows.Count;
            moreFilesWords = $"{extra} more {(extra == 1 ? "file" : "files")} on GitHub";
        }

        var others = new List<PullRequestSiblingRow>();
        if (status.AllItems.Count > 1)
        {
            for (var i = 0; i < status.AllItems.Count; i++)
            {
                if (i == focusedIndex) continue;
                var item = status.AllItems[i];
                others.Add(new PullRequestSiblingRow(i, item.Label, item.Title, item.State, PRVerdict.From(item)));
            }
        }

        var badge = number is { } n ? $"#{n} · {state.LabelWord()}" : state.LabelWord();
        var actions = BuildActions(state, number, repo, branch, url, checks, review, status.Manual);

        return new PullRequestCardModel
        {
            SessionKey = session.Key,
            Profile = session.Profile,
            SessionId = session.Id,
            State = state,
            UnknownReason = state == SessionPRState.Unknown ? status.UnknownReason : null,
            UnknownExplanation = state == SessionPRState.Unknown ? status.UnknownExplanation : null,
            Title = string.IsNullOrWhiteSpace(title) ? "Pull Request" : title,
            BadgeLabel = badge,
            Repo = repo,
            Branch = branch,
            Base = baseBranch,
            Number = number,
            Url = url,
            Manual = status.Manual,
            ReviewVerdict = review,
            CommentsCount = comments,
            Size = size,
            Verdict = PRVerdict.From(checks, size),
            Checks = checksRow,
            ChangesLabel = changesLabel,
            Files = fileRows,
            MoreFilesWords = moreFilesWords,
            Actions = actions,
            Others = others,
            RefreshedText = RefreshedWords(refreshedAt, now ?? DateTimeOffset.Now),
        };
    }

    public static string MergeWords(int? number, SessionPRChecks? checks, PRReviewVerdict review)
    {
        if (checks?.State == SessionPRCheckState.Failed) return "Merge Anyway…";
        if (review == PRReviewVerdict.ChangesRequested) return "Merge Anyway…";
        return number is { } n ? $"Merge #{n}" : "Merge PR";
    }

    public static (string Title, string Message) MergeConfirm(int? number, SessionPRChecks? checks, PRReviewVerdict review)
    {
        var label = number is { } n ? $"PR #{n}" : "this pull request";
        if (checks?.State == SessionPRCheckState.Failed)
        {
            var count = Math.Max(1, checks.Failed);
            var noun = count == 1 ? "1 check is" : $"{count} checks are";
            return ($"Merge {label} with Failing Checks?", $"{noun} currently failing. Ask your bot to merge {label} anyway?");
        }
        if (checks?.State == SessionPRCheckState.Running)
            return ($"Merge {label} While Checks Run?", $"Checks are still running on {label}. Ask your bot to merge once ready or immediately?");
        if (review == PRReviewVerdict.ChangesRequested)
            return ($"Merge {label} with Changes Requested?", $"A reviewer requested changes on {label}. Merge anyway?");
        return ($"Merge {label}?", $"Ask your bot to merge {label} into its base branch.");
    }

    public static string FixChecksPrompt(int? number, SessionPRChecks checks)
    {
        var failing = checks.Runs.Where(r => r.State == SessionPRCheckState.Failed).Select(r => r.Name).Take(5).ToList();
        var prRef = number is { } n ? $"PR #{n}" : "this PR";
        return failing.Count > 0
            ? $"Fix the failing CI checks on {prRef} ({string.Join(", ", failing)}) and push the fix."
            : $"Investigate and fix the failing CI checks on {prRef} and push the fix.";
    }

    public static string FixReviewPrompt(int? number) =>
        number is { } n
            ? $"Address the review feedback on PR #{n}, update the branch, and summarize what changed."
            : "Address the review feedback on this branch and summarize what changed.";

    public static string CheckoutPrompt(string? branch, int? number) =>
        !string.IsNullOrWhiteSpace(branch)
            ? $"Check out branch `{branch}` locally and show git status."
            : number is { } n
                ? $"Check out PR #{n} locally and show git status."
                : "Check out this pull request branch locally.";

    public static string? RefreshedWords(DateTimeOffset? refreshedAt, DateTimeOffset now)
    {
        if (refreshedAt == null) return null;
        var span = now - refreshedAt.Value;
        if (span.TotalSeconds < 45) return "Updated just now";
        if (span.TotalMinutes < 60) return $"Updated {(int)Math.Round(span.TotalMinutes)}m ago";
        if (span.TotalHours < 24) return $"Updated {(int)Math.Round(span.TotalHours)}h ago";
        return $"Updated {(int)Math.Round(span.TotalDays)}d ago";
    }

    private static PullRequestChecksRow BuildChecksRow(SessionPRChecks checks)
    {
        var summary = checks.State switch
        {
            SessionPRCheckState.Failed => checks.Failed == 1 ? "1 check failing" : $"{Math.Max(1, checks.Failed)} checks failing",
            SessionPRCheckState.Running => checks.Running > 0
                ? $"{checks.Running} running · {checks.Passed} passed"
                : "Checks running",
            SessionPRCheckState.Passed => checks.Passed > 0
                ? $"{checks.Passed} {(checks.Passed == 1 ? "check" : "checks")} passed"
                : "Checks passed",
            _ => "Checks",
        };
        return new PullRequestChecksRow(summary, checks.State, checks.Runs);
    }

    private static PullRequestFileRow BuildFileRow(SessionPRFile file, IReadOnlyDictionary<string, int>? commentCounts)
    {
        var slash = file.Path.LastIndexOf('/');
        var name = slash >= 0 ? file.Path[(slash + 1)..] : file.Path;
        var dir = slash > 0 ? file.Path[..slash] : "";
        var body = file.Binary
            ? PullRequestFileBodyKind.Binary
            : !string.IsNullOrEmpty(file.Patch)
                ? PullRequestFileBodyKind.Patch
                : file.PatchCut
                    ? PullRequestFileBodyKind.TooLarge
                    : PullRequestFileBodyKind.None;
        var count = commentCounts != null && commentCounts.TryGetValue(file.Path, out var c) ? c : 0;
        return new PullRequestFileRow(file.Path, name, dir, file.Additions, file.Deletions, body, file.Patch, file.PatchCut, count);
    }

    private static IReadOnlyList<PullRequestActionItem> BuildActions(
        SessionPRState state,
        int? number,
        string? repo,
        string? branch,
        string? url,
        SessionPRChecks? checks,
        PRReviewVerdict review,
        bool manual)
    {
        var actions = new List<PullRequestActionItem>();
        var prRef = number is { } n ? $"PR #{n}" : "this pull request";
        var repoSuffix = !string.IsNullOrWhiteSpace(repo) ? $" in {repo}" : "";

        if (state == SessionPRState.Open)
        {
            if (checks?.State == SessionPRCheckState.Failed)
            {
                actions.Add(new PullRequestActionItem(
                    PullRequestQuickAction.AskBotToFixCI,
                    "Ask Bot to Fix CI",
                    Primary: true,
                    BotPrompt: FixChecksPrompt(number, checks)));
            }
            if (review == PRReviewVerdict.ChangesRequested)
            {
                actions.Add(new PullRequestActionItem(
                    PullRequestQuickAction.AskBotToFixReview,
                    "Ask Bot to Fix Review",
                    Primary: checks?.State != SessionPRCheckState.Failed,
                    BotPrompt: FixReviewPrompt(number)));
            }

            var (confirmTitle, confirmMsg) = MergeConfirm(number, checks, review);
            var cleanMerge = checks?.State != SessionPRCheckState.Failed && review != PRReviewVerdict.ChangesRequested;
            actions.Add(new PullRequestActionItem(
                PullRequestQuickAction.Merge,
                MergeWords(number, checks, review),
                Primary: cleanMerge,
                Destructive: !cleanMerge,
                ConfirmationTitle: confirmTitle,
                ConfirmationMessage: confirmMsg,
                BotPrompt: $"Merge {prRef}{repoSuffix}."));

            actions.Add(new PullRequestActionItem(
                PullRequestQuickAction.Approve,
                "Approve",
                BotPrompt: $"Submit an approval review on {prRef}{repoSuffix}."));

            actions.Add(new PullRequestActionItem(
                PullRequestQuickAction.RequestChanges,
                "Request Changes",
                BotPrompt: $"Request changes on {prRef}{repoSuffix} with the inline review notes."));
        }
        else if (state == SessionPRState.Draft && checks?.State == SessionPRCheckState.Failed)
        {
            actions.Add(new PullRequestActionItem(
                PullRequestQuickAction.AskBotToFixCI,
                "Ask Bot to Fix CI",
                Primary: true,
                BotPrompt: FixChecksPrompt(number, checks)));
        }

        if (!string.IsNullOrWhiteSpace(branch) || number != null)
        {
            actions.Add(new PullRequestActionItem(
                PullRequestQuickAction.Checkout,
                "Checkout Branch",
                BotPrompt: CheckoutPrompt(branch, number)));
        }

        if (!string.IsNullOrEmpty(url))
        {
            actions.Add(new PullRequestActionItem(
                PullRequestQuickAction.OpenInBrowser,
                "Open on GitHub"));
        }

        actions.Add(new PullRequestActionItem(
            PullRequestQuickAction.OpenChat,
            "Open Chat"));

        if (state is SessionPRState.Open or SessionPRState.Draft or SessionPRState.Unknown)
        {
            actions.Add(new PullRequestActionItem(
                PullRequestQuickAction.MarkClosed,
                "Mark Closed",
                Destructive: true));
        }
        else if (manual && state == SessionPRState.Closed)
        {
            actions.Add(new PullRequestActionItem(
                PullRequestQuickAction.Reopen,
                "Reopen Status"));
        }

        return actions;
    }
}
