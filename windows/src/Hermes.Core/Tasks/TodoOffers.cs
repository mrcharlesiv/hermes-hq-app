using System.Text.Json.Nodes;

namespace Hermes.Core.Tasks;

/// Proposed task inside a list or goal offer (`TodoOfferTask`).
public sealed record TodoOfferTask(
    string Title,
    string? Who = null,
    string? Bot = null,
    string? Due = null,
    string? Milestone = null,
    string? Notes = null)
{
    public static TodoOfferTask? From(JsonNode? n)
    {
        if (n is not JsonObject || n.Text("title") is not { } title) return null;
        return new TodoOfferTask(title, n.Text("who"), n.Text("bot"), n.Text("due"), n.Text("milestone"), n.Text("notes"));
    }
}

public sealed record GoalOfferMilestone(string Title, string? Due = null)
{
    public static GoalOfferMilestone? From(JsonNode? n) =>
        n is JsonObject && n.Text("title") is { } title ? new GoalOfferMilestone(title, n.Text("due")) : null;
}

public sealed record GoalOfferMeasure(string Unit, double Start, double Target, double Now)
{
    public static GoalOfferMeasure? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var start = n.Num("start") ?? 0;
        return new GoalOfferMeasure(n.Str("unit") ?? "", start, n.Num("target") ?? 0, n.Num("now") ?? start);
    }
}

/// Goal setup plan payload proposed by a bot (`GoalPlanSetup`).
public sealed record GoalPlanSetup(
    string? Name,
    string? Why,
    string? Due,
    GoalOfferMeasure? Measure,
    IReadOnlyList<GoalOfferMilestone> Milestones,
    IReadOnlyList<TodoOfferTask> Tasks,
    IReadOnlyList<string> BuiltOn)
{
    public static GoalPlanSetup? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var milestones = (n.Arr("milestones") ?? []).Select(GoalOfferMilestone.From).OfType<GoalOfferMilestone>().ToList();
        var tasks = (n.Arr("tasks") ?? []).Select(TodoOfferTask.From).OfType<TodoOfferTask>().ToList();
        var builtOn = (n.Arr("built_on") ?? []).Select(J.AsString).OfType<string>().Select(s => s.Trim()).Where(s => s.Length > 0).ToList();
        var name = n.Text("name") ?? n.Text("title");
        var why = n.Text("why");
        var due = n.Text("due");
        var measure = GoalOfferMeasure.From(n.Get("measure"));
        if (name == null && why == null && due == null && measure == null && milestones.Count == 0 && tasks.Count == 0)
            return null;
        return new GoalPlanSetup(name, why, due, measure, milestones, tasks, builtOn);
    }
}

/// Proposed move of an existing task to another list.
public sealed record TodoOfferMove(string TaskId, string Title, string? FromSection, string? ToSection)
{
    public static TodoOfferMove? From(JsonNode? n)
    {
        if (n is not JsonObject || n.Text("task_id") is not { } tid) return null;
        return new TodoOfferMove(tid, n.Text("title") ?? "", n.Text("from"), n.Text("to"));
    }
}

/// One pending offer from a bot: list additions (`list`/`tasks`), goal creation (`goal`), goal setup plan (`plan`),
/// or goal check-in (`checkin`).
public sealed record TodoOffer(
    string Id,
    string Kind,
    string By,
    string Title,
    string Summary,
    string? SectionId = null,
    string? GoalId = null,
    IReadOnlyList<TodoOfferTask>? Tasks = null,
    IReadOnlyList<TodoOfferMove>? Moves = null,
    GoalPlanSetup? Plan = null,
    string Status = "waiting",
    string? At = null,
    bool Undoable = false)
{
    public IReadOnlyList<TodoOfferTask> AllTasks => Tasks ?? [];
    public IReadOnlyList<TodoOfferMove> AllMoves => Moves ?? [];
    public bool IsWaiting => Status == "waiting";
    public bool IsGoalOffer => Kind is "goal" or "plan" or "checkin" || GoalId != null;

    public static TodoOffer? From(JsonNode? n)
    {
        if (n is not JsonObject || n.Text("id") is not { } id) return null;
        return new TodoOffer(
            Id: id,
            Kind: n.Text("kind") ?? "tasks",
            By: n.Text("by") ?? "default",
            Title: n.Text("title") ?? "",
            Summary: n.Text("summary") ?? n.Text("text") ?? "",
            SectionId: n.Text("section"),
            GoalId: n.Text("goal"),
            Tasks: [.. (n.Arr("tasks") ?? []).Select(TodoOfferTask.From).OfType<TodoOfferTask>()],
            Moves: [.. (n.Arr("moves") ?? []).Select(TodoOfferMove.From).OfType<TodoOfferMove>()],
            Plan: GoalPlanSetup.From(n.Get("plan") ?? n.Get("setup")),
            Status: n.Text("status") ?? "waiting",
            At: n.Text("at"),
            Undoable: n.Bool("undoable") ?? false);
    }
}

public enum TodoOfferAction
{
    Accept,
    AcceptNoList,
    Decline,
    Undo,
}

public sealed record TodoOfferButton(TodoOfferAction Action, string Label, bool Primary = false, bool Destructive = false)
{
    public string WireAction => Action switch
    {
        TodoOfferAction.Accept => "accept",
        TodoOfferAction.AcceptNoList => "accept_no_list",
        TodoOfferAction.Decline => "decline",
        TodoOfferAction.Undo => "undo",
        _ => "accept",
    };
}

/// Answer from `POST /tasks/offers/{id}`.
public sealed record TodoOfferAnswer(TodoOffer? Offer, IReadOnlyList<TodoTask> AddedTasks, Goal? UpdatedGoal)
{
    public static TodoOfferAnswer From(JsonNode? n) => new(
        Offer: TodoOffer.From(n.Get("offer")),
        AddedTasks: [.. (n.Arr("tasks") ?? []).Select(TodoTask.From).OfType<TodoTask>()],
        UpdatedGoal: Goal.From(n.Get("goal")));
}

/// Presentation & action rules for Offers (`TodoOfferRules`).
public static class TodoOfferRules
{
    public static IReadOnlyList<TodoOffer> Waiting(IEnumerable<TodoOffer> offers) =>
        [.. offers.Where(o => o.IsWaiting)];

    public static string OfferTitle(TodoOffer offer, Func<string?, string> botName)
    {
        if (!string.IsNullOrWhiteSpace(offer.Title)) return offer.Title;
        var who = botName(offer.By);
        return offer.Kind switch
        {
            "goal" => $"{who} suggested a goal",
            "plan" => $"{who} drafted a setup plan",
            "checkin" => $"{who} checked in on your goal",
            "list" => $"{who} suggested tasks for your list",
            _ => $"{who} suggested {offer.AllTasks.Count} {(offer.AllTasks.Count == 1 ? "task" : "tasks")}",
        };
    }

    public static IReadOnlyList<TodoOfferButton> OfferButtons(TodoOffer offer)
    {
        if (!offer.IsWaiting)
        {
            return offer.Undoable
                ? [new TodoOfferButton(TodoOfferAction.Undo, "Undo")]
                : [];
        }

        if (offer.Kind == "list" && offer.SectionId != null)
        {
            return
            [
                new TodoOfferButton(TodoOfferAction.Accept, "Add to List", Primary: true),
                new TodoOfferButton(TodoOfferAction.AcceptNoList, "Add Without List"),
                new TodoOfferButton(TodoOfferAction.Decline, "Dismiss", Destructive: true),
            ];
        }

        return offer.Kind switch
        {
            "plan" =>
            [
                new TodoOfferButton(TodoOfferAction.Accept, "Apply Plan", Primary: true),
                new TodoOfferButton(TodoOfferAction.Decline, "Not Now", Destructive: true),
            ],
            "goal" =>
            [
                new TodoOfferButton(TodoOfferAction.Accept, "Add Goal", Primary: true),
                new TodoOfferButton(TodoOfferAction.Decline, "Dismiss", Destructive: true),
            ],
            "checkin" =>
            [
                new TodoOfferButton(TodoOfferAction.Accept, "Accept Update", Primary: true),
                new TodoOfferButton(TodoOfferAction.Decline, "Dismiss", Destructive: true),
            ],
            _ =>
            [
                new TodoOfferButton(TodoOfferAction.Accept, "Accept", Primary: true),
                new TodoOfferButton(TodoOfferAction.Decline, "Decline", Destructive: true),
            ],
        };
    }

    public static string DoneLabel(TodoOffer offer) => offer.Status switch
    {
        "accepted" => "Accepted",
        "declined" => "Dismissed",
        "undone" => "Undone",
        _ => "",
    };
}

/// Close-offer card state machine (`HermesKit/Pages/Tasks/TodoCloseCards.swift`).
public enum TodoCloseCardState
{
    Waiting,
    Done,
    Reopened,
    Kept,
    Gone,
    Settled,
}

public static class TodoCloseCards
{
    public static TodoCloseCardState StateOf(TodoTask? task, bool locallyMarkedDone = false, bool locallyKept = false, bool locallyReopened = false)
    {
        if (task == null) return TodoCloseCardState.Gone;
        if (locallyReopened && !task.IsDone) return TodoCloseCardState.Reopened;
        if (task.IsDone) return locallyMarkedDone ? TodoCloseCardState.Done : TodoCloseCardState.Settled;
        if (locallyKept || task.Offer is { Kept: true }) return TodoCloseCardState.Kept;
        if (task.Offer is { Kept: false }) return TodoCloseCardState.Waiting;
        return TodoCloseCardState.Settled;
    }
}

/// Today Check-in & Undo rules (`App/Pages/Tasks/TaskCheckOff.swift`).
public sealed record TodayCheckInSummary(
    int Overdue,
    int DueToday,
    int WaitingOnYou,
    int CloseOffers,
    int PendingOffers,
    int DoneToday)
{
    public bool HasActionItems => Overdue > 0 || WaitingOnYou > 0 || CloseOffers > 0 || PendingOffers > 0;

    public string Headline
    {
        get
        {
            var parts = new List<string>();
            if (Overdue > 0) parts.Add($"{Overdue} overdue");
            if (DueToday > 0) parts.Add($"{DueToday} due today");
            if (WaitingOnYou > 0) parts.Add($"{WaitingOnYou} waiting on you");
            if (CloseOffers > 0) parts.Add($"{CloseOffers} ready to close");
            if (PendingOffers > 0) parts.Add($"{PendingOffers} {(PendingOffers == 1 ? "offer" : "offers")}");
            if (parts.Count == 0) return DoneToday > 0 ? $"All clear · {DoneToday} done today" : "All clear for today";
            return string.Join(" · ", parts);
        }
    }
}

public static class TodayCheckIn
{
    /// Offers an Undo banner when ticking a non-repeating task done (`TaskCheckOff.swift`).
    public static bool ShouldOfferUndo(TodoTask task, bool markingDone) =>
        markingDone && (task.RepeatRule == null || task.WhoKind != TodoWho.Me);

    public static string UndoBannerText(TodoTask task) =>
        $"Marked “{(task.Title.Length == 0 ? TasksCopy.Untitled : task.Title)}” done";

    public static TodayCheckInSummary Compute(
        IReadOnlyList<TodoTask> tasks,
        IReadOnlyList<TodoOffer> offers,
        DateTimeOffset now,
        TimeZoneInfo zone)
    {
        var today = TodoDates.LocalDay(now, zone);
        int overdue = 0, dueToday = 0, waiting = 0, closeOffers = 0, doneToday = 0;

        foreach (var t in tasks)
        {
            if (t.IsDone)
            {
                var finished = TodoDates.Moment(t.DoneAt) ?? TodoDates.Moment(t.UpdatedAt);
                if (!TodoViews.BotsOwn(t) && finished != null && TodoDates.LocalDay(finished.Value, zone) == today)
                    doneToday++;
                continue;
            }
            if (!TodoViews.InYourDay(t)) continue;
            if (TodoViews.WaitsOnYou(t)) waiting++;
            if (t.Offer is { Kept: false }) closeOffers++;
            if (TodoDates.Due(t.Due, zone) is { } due)
            {
                var day = TodoDates.LocalDay(due.Date, zone);
                if (day < today) overdue++;
                else if (day == today) dueToday++;
            }
        }

        return new TodayCheckInSummary(overdue, dueToday, waiting, closeOffers, TodoOfferRules.Waiting(offers).Count, doneToday);
    }
}
