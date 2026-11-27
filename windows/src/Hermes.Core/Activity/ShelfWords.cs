namespace Hermes.Core.Activity;

// The activity shelf's words that come straight from the model (no UI): App/Chat/Activity/SubagentBodies.swift
// (`SubagentLook`, the helper rows, back row and detail), ShelfBodies.swift (the goal card) and
// ChatActivityController.swift (helper counts, steer / stop feedback, goal menu and confirmations).

/// One row of the goal card's ⋯ menu. `Action` is the `session.control` action it sends, or null for a local one
/// (`View Details`, `Add Criterion` asks for text first and then sends `subgoal.add`, `Hide Goal` hides it on this
/// device). `Confirm` is set when the Mac asks first.
public sealed record GoalMenuItem(string Title, string? Action, bool Destructive = false, GoalConfirm? Confirm = null);

public sealed record GoalConfirm(string Title, string Message, string Action);

public static class SubagentWords
{
    public const string StepsPlaceholder = "Choose a helper to see its steps.";
    public const string SteerPlaceholder = "Steer this helper…";
    public const string Steer = "Steer";
    public const string Stop = "Stop";
    public const string TruncatedOutput = "Showing the latest 16 KB";
    public const string SteerQueued = "Queued for the next checkpoint";
    public const string StopRequested = "Stop requested";
    /// A steer or stop the helper refused (shown in red, and announced).
    public const string Rejected = "The helper didn’t accept your message.";
    /// The detail's output folds to its last lines.
    public const int FoldedOutputLines = 12;
    /// The detail shows the last steps and the first files.
    public const int ShownSteps = 12;
    public const int ShownFiles = 8;

    public static string FormatElapsed(int seconds) => SubagentRules.FormatElapsed(seconds);

    /// The status word beside a helper (`SubagentLook.word`).
    public static string Status(SubagentStatus s) => s switch
    {
        SubagentStatus.Running => "Running",
        SubagentStatus.Queued => "Queued",
        SubagentStatus.Dispatched => "Dispatched · status unavailable",
        SubagentStatus.Completed => "Done",
        SubagentStatus.Failed => "Failed",
        _ => "Stopped",
    };

    /// The time a child ran: live, now − start; finished, its stated duration (or its last update).
    public static int Elapsed(SubagentProgress child, double now)
    {
        if (child.IsLive) return (int)(now - child.StartedAt);
        if (child.DurationSeconds is { } d && d > 0) return (int)ActivityJson.Round(d);
        return (int)Math.Max(0, child.UpdatedAt - child.StartedAt);
    }

    /// The row's timer text.
    public static string Timer(SubagentProgress child, double now) => FormatElapsed(Elapsed(child, now));

    /// The row's second line: a finished child's summary, else its newest step, else "Queued" / "Waiting for activity".
    public static string RowLine(SubagentProgress child)
    {
        if (!child.IsLive && !string.IsNullOrEmpty(child.Summary)) return child.Summary;
        return child.Stream.Count > 0 ? child.Stream[^1].Text : child.Status == SubagentStatus.Queued ? "Queued" : "Waiting for activity";
    }

    /// The row's screen-reader label: "Read the changelog, Running".
    public static string RowAccessibilityLabel(SubagentProgress child) => $"{child.Goal}, {Status(child.Status)}";

    /// "‹ All Helpers" at the top of a helper's page.
    public static string BackRow(int count) => count == 1 ? "All Helpers" : $"All {count} Helpers";
    public static string BackRowValue(int live) => live > 0 ? $"{live} running" : "All finished";

    /// "3 helpers · 2 running · 1 queued" over the inspector panel's list.
    public static string CountLine(IReadOnlyCollection<SubagentProgress> children)
    {
        var parts = new List<string> { children.Count == 1 ? "1 helper" : $"{children.Count} helpers" };
        var working = children.Count(c => c.Status == SubagentStatus.Running);
        var queued = children.Count(c => c.Status == SubagentStatus.Queued);
        if (working > 0) parts.Add($"{working} running");
        if (queued > 0) parts.Add($"{queued} queued");
        return string.Join(" · ", parts);
    }

    /// The helpers row's count: "2 running · 1 queued · 1 done".
    public static string HelperCounts(IEnumerable<SubagentStatus> live, int done)
    {
        var liveList = live.ToList();
        var queued = liveList.Count(s => s == SubagentStatus.Queued);
        var running = liveList.Count - queued;
        var parts = new List<string>();
        if (running > 0) parts.Add($"{running} running");
        if (queued > 0) parts.Add($"{queued} queued");
        if (done > 0) parts.Add($"{done} done");
        return string.Join(" · ", parts);
    }

    /// A finished child's result box text (null while live or without a summary).
    public static string? Result(SubagentProgress child) => child.IsLive || string.IsNullOrEmpty(child.Summary) ? null : child.Summary;

    /// The detail's steps: the last 12, newest at the bottom; the summary line is the result box once it finished.
    public static (IReadOnlyList<SubagentStreamEntry> Shown, int Total) Steps(SubagentProgress child)
    {
        var stream = Result(child) is null ? child.Stream.ToList() : child.Stream.Where(e => e.Kind != SubagentStreamKind.Summary).ToList();
        return (stream.Skip(Math.Max(0, stream.Count - ShownSteps)).ToList(), stream.Count);
    }

    public static string StepsHeader(int shown, int total) => total > shown ? $"Steps · latest {shown} of {total}" : "Steps";

    /// The detail's files: written first, up to 8.
    public static (IReadOnlyList<(string Path, bool Written)> Shown, int Total) Files(SubagentProgress child)
    {
        var all = child.FilesWritten.Select(p => (p, true)).Concat(child.FilesRead.Select(p => (p, false))).ToList();
        return (all.Take(ShownFiles).ToList(), all.Count);
    }

    public static string FilesHeader(int shown, int total) => total > shown ? $"Files · {total}" : "Files";
    public static string FileAccessibilityLabel(string path, bool written) => $"{(written ? "Wrote" : "Read")} {path}";

    /// The output fold's button.
    public static string OutputToggle(bool expanded, int lineCount) => expanded ? "Show Less" : $"Show All {lineCount} Lines";

    /// The step's offset from the child's start ("+12s" on the Mac is drawn from this whole number of seconds).
    public static int StepOffset(SubagentStreamEntry entry, SubagentProgress child) => (int)(entry.At - child.StartedAt);
}

public static class GoalWords
{
    public static string CriteriaHeader(int count) => $"Criteria · {count}";
    public const string ViewDetails = "View Details";
    public const string AddCriterion = "Add Criterion";
    public const string ClearAllCriteria = "Clear All Criteria";
    public const string CriterionPlaceholder = "Enter criterion text…";
    public const string DetailsTitle = "Goal Details";

    public static readonly GoalConfirm ClearGoal =
        new("Clear Goal?", "The goal and its criteria are removed. This can’t be undone.", "Clear Goal");
    public static readonly GoalConfirm ClearCriteria =
        new("Clear All Criteria?", "Every criterion is removed from this goal.", "Clear All Criteria");

    /// "Remove Criterion 2?" with the criterion's text (≤ 80 characters) when it has one. `index` is 1-based.
    public static GoalConfirm RemoveCriterion(GoalSnapshot goal, int index)
    {
        var text = index >= 1 && index <= goal.Subgoals.Count ? goal.Subgoals[index - 1].Trim() : "";
        var shown = ActivityJson.Length(text) > 80 ? ActivityJson.Prefix(text, 80) + "…" : text;
        return new($"Remove Criterion {index}?",
            shown.Length == 0 ? "It is removed from this goal." : $"“{shown}” is removed from this goal.",
            $"Remove Criterion {index}");
    }

    /// The goal card's ⋯ menu, in the Mac's order. Every action is disabled while `entry.PendingAction` is set.
    public static List<GoalMenuItem> Menu(GoalSnapshot goal)
    {
        var items = new List<GoalMenuItem>();
        if (ControlRules.HasDetails(goal)) items.Add(new(ViewDetails, null));
        if (goal.Status != GoalStatus.Done) items.Add(new(AddCriterion, null));
        if (goal.WaitBarrier is not null)
        {
            items.Add(new("Resume Now", GoalActions.Unwait));
            items.Add(new("Pause Goal", GoalActions.Pause));
        }
        else if (goal.Status == GoalStatus.Active) items.Add(new("Pause Goal", GoalActions.Pause));
        else if (goal.Status == GoalStatus.Paused) items.Add(new("Resume Goal", GoalActions.Resume));
        if (goal.Status == GoalStatus.Done) items.Add(new("Hide Goal", null));
        items.Add(new("Clear Goal", GoalActions.Clear, Destructive: true, Confirm: ClearGoal));
        return items;
    }
}
