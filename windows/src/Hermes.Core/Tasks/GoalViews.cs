using System.Text.Json.Nodes;
namespace Hermes.Core.Tasks;

// [goals] The rules behind the Goals view and Today's Goals shelf, as pure functions (HermesKit/Pages/Goals/GoalViews.swift
// and GoalShelf.swift at 93f984bb1; docs/goals.md "Progress and pace", "The Goals view", "The shelf").
// - The ring never lies: your number when the goal has one, else milestones done, else tasks done; with none of those
//   the ring is empty and says "No plan yet".
// - Pace is said in words, only with a date: on pace, ahead, a week behind. Red only once it is late.
// Tested in tests/Hermes.Core.Tests/GoalsTests.cs.

public static class GoalViews
{
    /// With no goals at all: what a goal is, in two lines.
    public const string EmptyText = "A goal is something you want to finish: a number to reach, a date, or a few milestones.\nPut tasks under it, and the ring shows how far you’ve come.";

    // ------------------------------------------------------------------ tasks under a goal

    /// The goal's tasks, in their own order (`position`).
    public static List<TodoTask> TasksOf(Goal goal, IEnumerable<TodoTask> tasks) =>
        [.. tasks.Where(t => t.Goal == goal.Id).OrderBy(t => t.Order).ThenBy(t => t.Id, StringComparer.Ordinal)];

    /// A milestone's tasks, in order.
    public static List<TodoTask> TasksOf(Goal goal, string milestone, IEnumerable<TodoTask> all) =>
        [.. TasksOf(goal, all).Where(t => t.Milestone == milestone)];

    /// The goal's tasks under no milestone (or under one the goal no longer has), in order.
    public static List<TodoTask> LooseTasks(Goal goal, IEnumerable<TodoTask> all)
    {
        var known = goal.Milestones.Select(m => m.Id).ToHashSet();
        return [.. TasksOf(goal, all).Where(t => t.Milestone is not { } m || !known.Contains(m))];
    }

    /// The milestone the goal is on: the first not done.
    public static GoalMilestone? Current(Goal goal) => goal.Milestones.FirstOrDefault(m => !m.Done);

    /// The goal's next task: the first open task of the first milestone not done, else the first open task under no
    /// milestone, else none.
    public static TodoTask? NextTask(Goal goal, IReadOnlyList<TodoTask> all)
    {
        if (Current(goal) is { } milestone && TasksOf(goal, milestone.Id, all).FirstOrDefault(t => !t.IsDone) is { } task) return task;
        return LooseTasks(goal, all).FirstOrDefault(t => !t.IsDone);
    }

    // ------------------------------------------------------------------ progress

    /// What the ring shows, 0…1: your number, else milestones done, else tasks done; null with none ("No plan yet").
    public static double? Fraction(Goal goal, IReadOnlyList<TodoTask> all)
    {
        if (goal.Measure is { } measure) return Fraction(measure);
        if (goal.Milestones.Count > 0) return (double)goal.Milestones.Count(m => m.Done) / goal.Milestones.Count;
        var mine = TasksOf(goal, all);
        if (mine.Count > 0) return (double)mine.Count(t => t.IsDone) / mine.Count;
        return null;
    }

    /// `(now - start) / (target - start)`, held to 0…1 (a target below the start counts down the same way).
    public static double Fraction(GoalMeasure measure)
    {
        var span = measure.Target - measure.Start;
        if (span == 0) return measure.Now == measure.Target ? 1 : 0;
        return Math.Min(1, Math.Max(0, (measure.Now - measure.Start) / span));
    }

    /// "34%".
    public static string Percent(double fraction) => $"{(int)Math.Floor(fraction * 100)}%";

    /// What part of the way an even pace would have covered today, 0…1; null with no date.
    public static double? EvenPace(Goal goal, DateTimeOffset now, TimeZoneInfo zone)
    {
        if (Span(goal, zone) is not { } span) return null;
        var today = TodoDates.LocalDay(now, zone);
        if (span.Days <= 0) return today >= span.Due ? 1 : 0;
        var gone = (today - span.Created).Days;
        return Math.Min(1, Math.Max(0, (double)gone / span.Days));
    }

    /// The pace in words; null with no date, for an achieved, paused or let-go goal, and for one with no plan yet (until
    /// it is late).
    public static GoalPace? Pace(Goal goal, IReadOnlyList<TodoTask> all, DateTimeOffset now, TimeZoneInfo zone)
    {
        if (goal.State != GoalState.Active || Span(goal, zone) is not { } span) return null;
        var today = TodoDates.LocalDay(now, zone);
        if (today > span.Due) return new GoalPace.Late((today - span.Due).Days);
        if (Fraction(goal, all) is not { } done || EvenPace(goal, now, zone) is not { } even) return null;
        var gap = even - done;
        if (Math.Abs(gap) <= 0.05) return new GoalPace.OnPace();
        if (gap < 0) return new GoalPace.Ahead();
        return new GoalPace.Behind(Math.Max(1, (int)Math.Round(gap * Math.Max(1, span.Days), MidpointRounding.AwayFromZero)));
    }

    // ------------------------------------------------------------------ words

    /// A number as the app says it: "1,000", "12.5", "$" before it ("$1,200").
    public static string Number(double value, string unit = "")
    {
        var text = value.ToString("#,##0.##", GoalNumbers.En);
        return unit == "$" ? "$" + text : text;
    }

    /// "340 of 1,000" (the card), "340 of 1,000 testers" (`unit: true`). Counting down: "185, down to 170 lbs".
    public static string MeasureWords(GoalMeasure measure, bool unit = false)
    {
        var suffix = unit && measure.Unit.Length > 0 && measure.Unit != "$" ? " " + measure.Unit : "";
        var now = Number(measure.Now, measure.Unit);
        var target = Number(measure.Target, measure.Unit);
        return measure.CountsDown ? $"{now}, down to {target}{suffix}" : $"{now} of {target}{suffix}";
    }

    private static string Plural(int count, string one) => count == 1 ? one : one + "s";

    /// The card's grey line, without the pace: "340 of 1,000 · by Jan 31", "1 of 4 milestones · by Apr 11", "4 of 6
    /// tasks", "No plan yet".
    public static string Line(Goal goal, IReadOnlyList<TodoTask> all, DateTimeOffset now, TimeZoneInfo zone)
    {
        var parts = new List<string>();
        if (goal.Measure is { } measure) parts.Add(MeasureWords(measure));
        else if (goal.Milestones.Count > 0)
            parts.Add($"{goal.Milestones.Count(m => m.Done)} of {goal.Milestones.Count} " + Plural(goal.Milestones.Count, "milestone"));
        else
        {
            var mine = TasksOf(goal, all);
            parts.Add(mine.Count == 0 ? "No plan yet" : $"{mine.Count(t => t.IsDone)} of {mine.Count} " + Plural(mine.Count, "task"));
        }
        if (DueDate(goal, zone) is { } due) parts.Add("by " + TodoWords.MonthDay(due, now, zone));
        return string.Join(" · ", parts);
    }

    /// A Someday, Achieved or Let Go card's line: "Paused Nov 30", "Achieved Dec 20", "Let go Dec 20"; null when active.
    public static string? StatusLine(Goal goal, DateTimeOffset now, TimeZoneInfo zone)
    {
        var word = goal.State switch
        {
            GoalState.Paused => "Paused",
            GoalState.Achieved => "Achieved",
            GoalState.LetGo => "Let go",
            _ => null,
        };
        if (word == null) return null;
        var at = TodoDates.Moment(goal.StatusAt) ?? TodoDates.Moment(goal.UpdatedAt);
        return at is { } moment ? word + " " + TodoWords.MonthDay(moment, now, zone) : word;
    }

    /// What a screen reader hears for a card: "1,000 public testers, 34 percent, a week behind, next: Post the beta link".
    public static string Spoken(Goal goal, IReadOnlyList<TodoTask> all, DateTimeOffset now, TimeZoneInfo zone)
    {
        var parts = new List<string> { goal.Title };
        parts.Add(Fraction(goal, all) is { } done ? $"{(int)Math.Floor(done * 100)} percent" : "No plan yet");
        if (Pace(goal, all, now, zone) is { } pace) parts.Add(pace.Words);
        if (StatusLine(goal, now, zone) is { } status) parts.Add(status);
        if (goal.State == GoalState.Active && NextTask(goal, all) is { } next) parts.Add("next: " + next.Title);
        return string.Join(", ", parts);
    }

    /// The shelf card's grey line: the number alone ("340"), else milestones done of all ("1 of 4"), else tasks done of all
    /// ("4 of 6"), then the date ("by Jan 31"). A goal with no plan says only its date; with neither it is empty.
    public static string ShortLine(Goal goal, IReadOnlyList<TodoTask> all, DateTimeOffset now, TimeZoneInfo zone)
    {
        var parts = new List<string>();
        if (goal.Measure is { } measure) parts.Add(Number(measure.Now, measure.Unit));
        else if (goal.Milestones.Count > 0) parts.Add($"{goal.Milestones.Count(m => m.Done)} of {goal.Milestones.Count}");
        else
        {
            var mine = TasksOf(goal, all);
            if (mine.Count > 0) parts.Add($"{mine.Count(t => t.IsDone)} of {mine.Count}");
        }
        if (DueDate(goal, zone) is { } due) parts.Add("by " + ShortDay(due, now, zone));
        return string.Join(" · ", parts);
    }

    /// "Jan 31": a small card has no room for a year, so a date within the next eleven months (or the last one) drops it
    /// even across New Year; farther off it says it ("Mar 1, 2028").
    public static string ShortDay(DateTimeOffset date, DateTimeOffset now, TimeZoneInfo zone)
    {
        var from = TodoDates.LocalDay(now, zone);
        var to = TodoDates.LocalDay(date, zone);
        var months = (to.Year - from.Year) * 12 + to.Month - from.Month;
        if (months > 0 && to.Day < from.Day) months--;
        else if (months < 0 && to.Day > from.Day) months++;
        if (months is < -1 or > 10) return TodoWords.MonthDay(date, now, zone);
        return to.ToString("MMM d", GoalNumbers.En);
    }

    // ------------------------------------------------------------------ groups

    /// Active (your order), Someday (paused, your order), Achieved and Let Go (latest first).
    public static GoalGroups Groups(IEnumerable<Goal> goals)
    {
        var list = goals.ToList();
        List<Goal> Ordered(GoalState s) => [.. list.Where(g => g.State == s).OrderBy(g => g.Order).ThenBy(g => g.Id, StringComparer.Ordinal)];
        List<Goal> Latest(GoalState s) => [.. list.Where(g => g.State == s)
            .OrderByDescending(g => TodoDates.Moment(g.StatusAt) ?? DateTimeOffset.MinValue).ThenByDescending(g => g.Id, StringComparer.Ordinal)];
        return new GoalGroups(Ordered(GoalState.Active), Ordered(GoalState.Paused), Latest(GoalState.Achieved), Latest(GoalState.LetGo));
    }

    /// The pill's number: active goals.
    public static int ActiveCount(IEnumerable<Goal> goals) => goals.Count(g => g.State == GoalState.Active);

    /// A group's heading (TasksViewController.configureGoalHeader).
    public static string GroupTitle(GoalGroupKey key) => key switch
    {
        GoalGroupKey.Active => "Active",
        GoalGroupKey.Someday => "Someday",
        GoalGroupKey.Achieved => "Achieved",
        GoalGroupKey.LetGo => "Let Go",
        _ => "Goals",
    };

    /// The fold's identifier on a group's heading: "goals.fold.<key>" (GoalGroupKey's raw values).
    public static string FoldId(GoalGroupKey key) => "goals.fold." + key switch
    {
        GoalGroupKey.Active => "active",
        GoalGroupKey.Someday => "someday",
        GoalGroupKey.Achieved => "achieved",
        GoalGroupKey.LetGo => "letGo",
        _ => "found",
    };

    /// Someday, Achieved and Let Go have a heading (Active has none: it leads the view). Achieved and Let Go are folded
    /// to their heading with a count until opened (`goalFoldsOpen`, the page's own: never saved).
    public static bool HasHeading(GoalGroupKey key) => key != GoalGroupKey.Active;
    public static bool Folds(GoalGroupKey key) => key is GoalGroupKey.Achieved or GoalGroupKey.LetGo;
    /// The fold's word: "Show" folded, "Hide" open; null for a group that doesn't fold.
    public static string? FoldWord(GoalGroupKey key, bool open) => Folds(key) ? open ? "Hide" : "Show" : null;

    /// A search's Goals group: goals whose name or why holds the words, any status, in the Goals view's order. Empty for
    /// no words, and for "#tag" (which looks for a task's tag alone).
    public static List<Goal> Found(IEnumerable<Goal> goals, string query)
    {
        var words = query.Trim().ToLowerInvariant();
        if (words.Length == 0 || words.StartsWith('#')) return [];
        var made = Groups(goals.Where(g => g.Title.ToLowerInvariant().Contains(words) || g.Why.ToLowerInvariant().Contains(words)));
        return [.. made.Active, .. made.Someday, .. made.Achieved, .. made.LetGo];
    }

    /// [WIN-47] A search has a Goals group only with every task on show (or yours alone), where goals are kept: a goal
    /// has no bot yet (TasksViewController.appendFoundGoals).
    public static bool FindsGoals(bool goalsSupported, string scope) => goalsSupported && scope is "all" or "@me";

    /// [WIN-47] The words a task is also found by: its goal's name and its milestone's name (GoalShelf.swift
    /// `searchWords`).
    public static List<string> SearchWords(TodoTask task, IEnumerable<Goal> goals)
    {
        if (task.Goal is not { } id || goals.FirstOrDefault(g => g.Id == id) is not { } goal) return [];
        return goal.Milestone(task.Milestone) is { } m ? [goal.Title, m.Title] : [goal.Title];
    }

    // ------------------------------------------------------------------ a task's goal

    /// [WIN-47] The goal whose mark a task's row carries, in its list's dot's place: a task in an active or paused goal
    /// (GoalShelf.swift `markGoal`). A task in an achieved or let-go goal (or one the list no longer has) has none.
    public static Goal? MarkGoal(TodoTask task, IEnumerable<Goal> goals) =>
        task.Goal is { } id && goals.FirstOrDefault(g => g.Id == id) is { State: GoalState.Active or GoalState.Paused } goal ? goal : null;

    /// The mark's spoken words, after the row's own (TaskRowViews.swift: ", for <goal>").
    public static string MarkWords(Goal goal) => "for " + goal.Shown;
    /// The mark's identifier (TaskRowViews.swift `tasks.goal-mark`).
    public const string MarkId = "tasks.goal-mark";

    /// [WIN-47] A task PATCH that puts it in a goal (null: none), under one of its milestones or none: a milestone the
    /// goal doesn't have is sent as none (GoalViews.swift `assign`).
    public static JsonObject Assign(string? goal, string? milestone, IEnumerable<Goal> goals)
    {
        var kept = goal == null ? null : goals.FirstOrDefault(g => g.Id == goal)?.Milestone(milestone)?.Id;
        return new JsonObject { ["goal"] = goal, ["milestone"] = kept };
    }

    // ------------------------------------------------------------------ dates

    private static DateTimeOffset? DueDate(Goal goal, TimeZoneInfo zone) =>
        goal.Due is { Length: >= 10 } raw ? TodoDates.Day(raw[..10], zone) : null;

    private static (DateTime Created, DateTime Due, int Days)? Span(Goal goal, TimeZoneInfo zone)
    {
        if (DueDate(goal, zone) is not { } dueAt) return null;
        var due = TodoDates.LocalDay(dueAt, zone);
        var created = TodoDates.Moment(goal.CreatedAt) is { } c ? TodoDates.LocalDay(c, zone) : due;
        return (created, due, (due - created).Days);
    }
}

/// What a goal's card draws (App/Pages/Goals/GoalsListViews.swift `GoalCardModel.make`).
public sealed record GoalCardModel(string Id, string Title, string Color, double? Fraction, string Line, GoalPace? Pace,
    string? NextId, string? NextTitle, bool Quiet, bool GreyRing, string Spoken)
{
    public static GoalCardModel Make(Goal goal, IReadOnlyList<TodoTask> tasks, DateTimeOffset now, TimeZoneInfo zone)
    {
        var active = goal.State == GoalState.Active;
        var next = active ? GoalViews.NextTask(goal, tasks) : null;
        return new GoalCardModel(goal.Id, goal.Shown, goal.Tint, GoalViews.Fraction(goal, tasks),
            active ? GoalViews.Line(goal, tasks, now, zone) : GoalViews.StatusLine(goal, now, zone) ?? "",
            GoalViews.Pace(goal, tasks, now, zone), next?.Id, next?.Title, !active,
            goal.State is GoalState.Paused or GoalState.LetGo, GoalViews.Spoken(goal, tasks, now, zone));
    }

    /// The ring's value for a screen reader: "34 percent", "No plan yet".
    public string RingWords => Fraction is { } f ? $"{(int)Math.Floor(f * 100)} percent" : "No plan yet";

    /// The card's identifier (GoalCard's `goal-card-<title>`).
    public string AutomationId => "goal-card-" + Title;
}

/// What a shelf card says under its name and grey line (GoalShelf.swift `GoalShelfNext`): "Next: <task>", "No plan yet"
/// (no number, no milestones, no tasks), "Nothing next" (every task under it done).
public sealed record GoalShelfCard(string Id, string Title, string Color, double? Fraction, string Line, string? NextId, string Next, string Spoken)
{
    public string AutomationId => "goal-shelf-" + Title;
}

/// Today's Goals shelf (GoalShelf.swift; docs/goals.md "The shelf").
public static class GoalShelf
{
    /// The shelf shows on Today alone, not during a search, on an add-on that keeps goals, with an active goal, and while
    /// the bots filter is All Bots or Me (`scope` "all" or "@me"; with one bot picked it is hidden).
    public static bool Shows(TodoView view, bool searching, string scope, bool goalsSupported, IEnumerable<Goal> goals) =>
        view == TodoView.Today && !searching && goalsSupported && scope is "all" or "@me" && goals.Any(g => g.State == GoalState.Active);

    /// The active goals in your order, each as a card. A paused, achieved or let-go goal has none.
    public static List<GoalShelfCard> Cards(IEnumerable<Goal> goals, IReadOnlyList<TodoTask> tasks, DateTimeOffset now, TimeZoneInfo zone) =>
        [.. GoalViews.Groups(goals).Active.Select(g => Card(g, tasks, now, zone))];

    public static GoalShelfCard Card(Goal goal, IReadOnlyList<TodoTask> tasks, DateTimeOffset now, TimeZoneInfo zone)
    {
        var fraction = GoalViews.Fraction(goal, tasks);
        var task = GoalViews.NextTask(goal, tasks);
        var next = task != null ? "Next: " + (task.Title.Length == 0 ? "Untitled Task" : task.Title) : fraction == null ? "No plan yet" : "Nothing next";
        return new GoalShelfCard(goal.Id, goal.Shown, goal.Tint, fraction, GoalViews.ShortLine(goal, tasks, now, zone), task?.Id, next,
            GoalViews.Spoken(goal, tasks, now, zone));
    }

    /// The heading's count: none open ("Goals"), the count folded ("Goals 3"). "All 3 ›" stands at its end either way.
    public static int? HeadingCount(int count, bool folded) => folded ? count : null;

    /// "All 3".
    public static string AllWords(int count) => $"All {count}";

    /// A screen reader: the heading is a button, "Goals, 3, shown" / "Goals, 3, hidden" (label, then value).
    public static string HeadingValue(int count, bool folded) => $"{count}, " + (folded ? "hidden" : "shown");

    public const string HeadingId = "goals.shelf.heading";
    public const string AllId = "goals.shelf.all";
    public const string ShelfId = "goals.shelf";
}

/// The Goals view's own words and identifiers (GoalsListViews.swift, TasksViewController.swift).
public static class GoalsCopy
{
    public const string Goals = "Goals";
    public const string NewGoal = "New Goal";
    public const string PillKey = "goals";
    public const string NewId = "goals.new";
    public const string EmptyId = "goals.empty";
    public const string EmptyNewId = "goals.empty.new";
    public const string TickId = "goal.card.tick";
    public const string OpensTheGoal = "Opens the goal";
    public static string MarkDone(string title) => $"Mark {title} Done";
}

/// A goal's colour as drawn: a list's colour name (TodoListColors) to the system colour the Mac's `TodoListColor` uses.
public static class GoalTints
{
    public static (byte R, byte G, byte B) Rgb(string name) => name switch
    {
        "green" => (0x34, 0xC7, 0x59),
        "orange" => (0xFF, 0x95, 0x00),
        "red" => (0xFF, 0x3B, 0x30),
        "purple" => (0xAF, 0x52, 0xDE),
        "pink" => (0xFF, 0x2D, 0x55),
        "teal" => (0x30, 0xB0, 0xC7),
        "yellow" => (0xFF, 0xCC, 0x00),
        "gray" => (0x8E, 0x8E, 0x93),
        _ => (0x00, 0x7A, 0xFF),
    };
}

/// Today's Goals shelf folded to its heading or not, kept on this device (GoalShelfViews.swift `GoalShelfFold`, its key
/// "HQGoalShelfFolded").
public sealed class GoalShelfFold(Hermes.Core.Composer.IKeyValueStore store)
{
    public const string Key = "HQGoalShelfFolded";
    public bool Folded
    {
        get => store.Get(Key) == "true";
        set => store.Set(Key, value ? "true" : null);
    }
}
