using System.Text.RegularExpressions;

namespace Hermes.Core.Tasks;

/// Contextual action on a task detail pane (`HermesKit/Pages/Tasks/TaskNow.swift`).
public enum TaskNowKind
{
    Reopen,
    Answer,
    Share,
    OpenLink,
    OpenFile,
    Call,
    AskUpdate,
    AskStart,
    AskHelp,
    MarkDone,
}

public sealed record TaskNowAction(TaskNowKind Kind, string Title, string? Target = null, bool Primary = false);

public sealed record TaskNowPlan(TaskNowAction? Primary, IReadOnlyList<TaskNowAction> Secondary);

/// Chooses the single most helpful "right now" action and quiet secondary actions for a task (`TaskNow.swift` port).
public static partial class TaskNow
{
    [GeneratedRegex(@"(?<!\d)(?:\+\d{1,3}[\s.-]?)?(?:\(\d{3}\)|\d{3})[\s.-]\d{3}[\s.-]\d{4}(?!\d)")]
    private static partial Regex PhoneCandidateRegex();

    [GeneratedRegex(@"https?://\S+", RegexOptions.IgnoreCase)]
    private static partial Regex UrlStripRegex();

    public static TaskNowPlan Pick(TodoTask task, Func<string?, string> botName)
    {
        if (task.IsDone)
        {
            return new TaskNowPlan(
                new TaskNowAction(TaskNowKind.Reopen, "Reopen Task", Primary: true),
                []);
        }

        var secondary = new List<TaskNowAction>();
        TaskNowAction? primary = null;

        var helper = task.Helper;
        var helperName = helper != null ? botName(helper) : null;

        if (task.Status == "needs_you")
        {
            primary = new TaskNowAction(TaskNowKind.Answer, helperName != null ? $"Answer {helperName}" : "Answer Question", Primary: true);
        }
        else if (task.Made.FirstOrDefault(m => m.IsLink && m.LinkUrl != null) is { } link)
        {
            primary = new TaskNowAction(TaskNowKind.OpenLink, $"Open {ShortTitle(link.Title, "Link")}", link.LinkUrl, Primary: true);
        }
        else if (task.Made.FirstOrDefault(m => m.IsFile) is { } file)
        {
            primary = new TaskNowAction(TaskNowKind.OpenFile, $"Open {ShortTitle(file.Title, "File")}", file.Ref, Primary: true);
        }
        else if (Callable(task) is { } number)
        {
            primary = new TaskNowAction(TaskNowKind.Call, $"Call {number}", number, Primary: true);
        }
        else if (helperName != null && task.Status == "working")
        {
            primary = new TaskNowAction(TaskNowKind.AskUpdate, $"Ask {helperName} for Update", helper, Primary: true);
        }
        else if (helperName != null && task.Status == "open")
        {
            primary = new TaskNowAction(TaskNowKind.AskStart, $"Ask {helperName} to Start", helper, Primary: true);
        }
        else if (task.Status == "ready" || task.Offer is { Kept: false })
        {
            primary = new TaskNowAction(TaskNowKind.MarkDone, TasksCopy.MarkDone, Primary: true);
        }
        else
        {
            primary = new TaskNowAction(TaskNowKind.AskHelp, "Ask a Bot for Help", Primary: true);
        }

        // Secondary actions (non-duplicating)
        if (primary.Kind != TaskNowKind.Call && Callable(task) is { } secondaryNumber)
            secondary.Add(new TaskNowAction(TaskNowKind.Call, $"Call {secondaryNumber}", secondaryNumber));
        if (primary.Kind != TaskNowKind.OpenLink && task.Made.FirstOrDefault(m => m.IsLink && m.LinkUrl != null) is { } secLink)
            secondary.Add(new TaskNowAction(TaskNowKind.OpenLink, "Open Link", secLink.LinkUrl));
        if (primary.Kind != TaskNowKind.AskUpdate && helperName != null && task.Status == "working")
            secondary.Add(new TaskNowAction(TaskNowKind.AskUpdate, $"Ask {helperName}", helper));
        if (primary.Kind != TaskNowKind.MarkDone)
            secondary.Add(new TaskNowAction(TaskNowKind.MarkDone, TasksCopy.MarkDone));
        secondary.Add(new TaskNowAction(TaskNowKind.Share, "Copy Summary"));

        return new TaskNowPlan(primary, secondary);
    }

    /// Extracts a callable phone number from a task's title, notes, or notes attachments while ignoring URLs and dates.
    public static string? Callable(TodoTask task)
    {
        var sources = new List<string> { task.Title, task.Notes };
        sources.AddRange(task.Made.Where(m => !m.IsLink && !m.IsFile).Select(m => m.Ref));
        foreach (var raw in sources)
        {
            if (string.IsNullOrWhiteSpace(raw)) continue;
            var cleaned = UrlStripRegex().Replace(raw, " ");
            var match = PhoneCandidateRegex().Match(cleaned);
            if (!match.Success) continue;
            var value = match.Value.Trim();
            var digits = new string(value.Where(char.IsDigit).ToArray());
            if (digits.Length is >= 10 and <= 15) return value;
        }
        return null;
    }

    private static string ShortTitle(string title, string fallback)
    {
        var t = title.Trim();
        if (t.Length == 0) return fallback;
        return t.Length > 28 ? t[..28] + "…" : t;
    }
}

/// Builds titles and context-carrying chat messages for task-linked and goal-linked chats (`TaskPage.swift`).
public static class TaskChatLinks
{
    public static string SessionTitle(TodoTask task)
    {
        var name = task.Title.Trim();
        return name.Length == 0 ? "Task" : $"Task: {name}";
    }

    public static string GoalSessionTitle(Goal goal) => $"Goal: {goal.Shown}";

    /// Builds a clean draft prompt carrying the task's context into its linked chat.
    public static string OutgoingTaskPrompt(TodoTask task, string? actionNote = null)
    {
        var lines = new List<string> { $"Regarding task “{(task.Title.Length == 0 ? TasksCopy.Untitled : task.Title)}” (id: {task.Id}):" };
        if (!string.IsNullOrWhiteSpace(task.Notes)) lines.Add(task.Notes.Trim());
        if (!string.IsNullOrWhiteSpace(actionNote)) lines.Add(actionNote.Trim());
        return string.Join("\n\n", lines);
    }

    public static string OutgoingGoalPrompt(Goal goal, string? actionNote = null)
    {
        var lines = new List<string> { $"Regarding goal “{goal.Shown}” (id: {goal.Id}):" };
        if (!string.IsNullOrWhiteSpace(goal.Why)) lines.Add("Why: " + goal.Why.Trim());
        if (!string.IsNullOrWhiteSpace(actionNote)) lines.Add(actionNote.Trim());
        return string.Join("\n\n", lines);
    }
}
