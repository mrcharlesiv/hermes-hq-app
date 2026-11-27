using System.Globalization;

namespace Hermes.Core.Tasks;

// The Tasks page's views (HermesKit/Pages/Tasks/TodoViews.swift): one view at a time, picked in a row of pills: Today,
// Upcoming, Inbox, each of your lists, and Bots. Tasks are ordered by when, never by what a bot did.

/// What the Tasks page shows: "today", "upcoming", "inbox", "list:<id>", "bots" (as kept on the device).
public sealed record TodoView(string Key)
{
    public static readonly TodoView Today = new("today"), Upcoming = new("upcoming"), Inbox = new("inbox"), Bots = new("bots");
    /// [goals] The Goals view: goal cards, not tasks (the first pill, on an add-on that keeps goals).
    public static readonly TodoView Goals = new("goals");
    public static TodoView List(string id) => new("list:" + id);
    public string? ListId => Key.StartsWith("list:", StringComparison.Ordinal) && Key.Length > 5 ? Key[5..] : null;

    public static TodoView? FromKey(string key) => key switch
    {
        "today" or "upcoming" or "inbox" or "bots" or "goals" => new TodoView(key),
        _ when key.StartsWith("list:", StringComparison.Ordinal) && key.Length > 5 => new TodoView(key),
        _ => null,
    };
}

/// A group of rows in a view: "overdue", "today", "waiting", "day:2026-11-13", "next:<list>", "open", "stale",
/// "bot:<profile>", "done".
public sealed record TodoGroupKind(string Key)
{
    public static readonly TodoGroupKind Overdue = new("overdue"), Today = new("today"), Waiting = new("waiting"), Open = new("open"),
        Stale = new("stale"), Done = new("done");
    public static TodoGroupKind Day(string key) => new("day:" + key);
    public static TodoGroupKind Next(string list) => new("next:" + list);
    public static TodoGroupKind Bot(string profile) => new("bot:" + profile);
    public string? Arg => Key.IndexOf(':') is var i and > 0 ? Key[(i + 1)..] : null;
    public bool IsDay => Key.StartsWith("day:", StringComparison.Ordinal);
    public bool IsNext => Key.StartsWith("next:", StringComparison.Ordinal);
    public bool IsBot => Key.StartsWith("bot:", StringComparison.Ordinal);
}

public sealed record TodoGroup(TodoGroupKind Kind, IReadOnlyList<TodoTask> Tasks, int More = 0);

public enum TodoTone { Plain, Ready, Working, NeedsYou, Overdue }

/// A row's words: the name is the task's; these go beside and under it.
public sealed record TodoRowWords
{
    /// At the row's end: "5:00 PM", "Tomorrow", "Nov 10".
    public string? When { get; init; }
    public bool Late { get; init; }
    /// "2/4" with steps.
    public string? Steps { get; init; }
    public bool Repeats { get; init; }
    public int Priority { get; init; }
    public IReadOnlyList<string> Tags { get; init; } = [];
    /// The second line, only when a bot has something for you (or, in Bots, what it is on).
    public string? Note { get; init; }
    public TodoTone Tone { get; init; }
    /// "working", "ready", "question".
    public string? Dot { get; init; }
}

public static class TodoWords
{
    private static readonly CultureInfo En = CultureInfo.GetCultureInfo("en-US");

    /// The clock ("5:00 PM").
    public static string Clock(DateTimeOffset date, TimeZoneInfo zone) => TimeZoneInfo.ConvertTime(date, zone).ToString("h:mm tt", En);

    /// "Nov 12" (with the year when it isn't this year's).
    public static string MonthDay(DateTimeOffset date, DateTimeOffset now, TimeZoneInfo zone)
    {
        var d = TimeZoneInfo.ConvertTime(date, zone);
        return d.Year == TimeZoneInfo.ConvertTime(now, zone).Year ? d.ToString("MMM d", En) : d.ToString("MMM d, yyyy", En);
    }

    /// "Today", "Tomorrow", "Yesterday" or "Nov 12".
    public static string Day(DateTimeOffset date, DateTimeOffset now, TimeZoneInfo zone)
    {
        var d = TodoDates.LocalDay(date, zone);
        var today = TodoDates.LocalDay(now, zone);
        if (d == today) return "Today";
        if (d == today.AddDays(1)) return "Tomorrow";
        if (d == today.AddDays(-1)) return "Yesterday";
        return MonthDay(date, now, zone);
    }

    /// The due in a tile or a sheet: "Today", "Today, 5:00 PM", "Nov 12", "None".
    public static string DueTile(TodoTask task, DateTimeOffset now, TimeZoneInfo zone)
    {
        if (TodoDates.Due(task.Due, zone) is not { } due) return "None";
        var day = Day(due.Date, now, zone);
        return due.HasTime ? $"{day}, {Clock(due.Date, zone)}" : day;
    }

    public static string RepeatLabel(string? rule) => rule switch
    {
        "daily" => "Every Day",
        "weekdays" => "Every Weekday",
        "weekly" => "Every Week",
        "monthly" => "Every Month",
        "yearly" => "Every Year",
        _ => "Never",
    };

    public static readonly string[] RepeatRules = ["daily", "weekdays", "weekly", "monthly", "yearly"];

    /// New Task's due words: "Tomorrow", "Fri 5:00 PM".
    public static string NewTaskDue(DateTimeOffset date, bool hasTime, DateTimeOffset now, TimeZoneInfo zone)
    {
        var day = TodoViews.Soon(date, now, zone);
        return hasTime ? day + " " + Clock(date, zone) : day;
    }

    public static string NewTaskHelpNote(string bot) =>
        $"When you click Add, {bot}’s chat opens and {bot} reads the task right away, then asks what it should take on.";

    /// "Completed today, 11:40 AM", "Completed Nov 5, 9:02 AM"; "Completed" when it doesn't say when.
    public static string Completed(TodoTask task, DateTimeOffset now, TimeZoneInfo zone)
    {
        if (TodoDates.Moment(task.DoneAt ?? task.UpdatedAt) is not { } date) return "Completed";
        var day = Day(date, now, zone);
        return $"Completed {(day is "Today" or "Yesterday" ? day.ToLowerInvariant() : day)}, {Clock(date, zone)}";
    }
}

public static class TodoSections
{
    /// Untouched this long, a bot's dateless task asks to be kept.
    public static readonly TimeSpan StaleAfter = TimeSpan.FromDays(14);
    public const string StaleTitle = "Still Need These?";

    /// An open task a bot added (not you), with no due, that nobody changed in two weeks.
    public static bool IsStale(TodoTask task, DateTimeOffset now)
    {
        if (task.Status != "open" || task.Due != null || string.IsNullOrEmpty(task.CreatedBy) || task.CreatedBy == "you") return false;
        if ((TodoDates.Moment(task.UpdatedAt) ?? TodoDates.Moment(task.CreatedAt)) is not { } touched) return false;
        return now - touched >= StaleAfter;
    }

    /// A group's tasks in the Sort By order: "smart" is your drag order, "due" soonest first, "added" newest first,
    /// "priority" high to low.
    public static List<TodoTask> Ordered(IEnumerable<TodoTask> items, string sort, TimeZoneInfo zone)
    {
        DateTimeOffset Created(TodoTask t) => TodoDates.Moment(t.CreatedAt) ?? DateTimeOffset.MinValue;
        DateTimeOffset DueOf(TodoTask t) => TodoDates.Due(t.Due, zone)?.Date ?? DateTimeOffset.MaxValue;
        int Rank(TodoTask t) => t.Priority == 0 ? 4 : t.Priority;
        return sort switch
        {
            "due" => [.. items.OrderBy(DueOf).ThenBy(t => t.Order).ThenBy(t => t.Id, StringComparer.Ordinal)],
            "added" => [.. items.OrderByDescending(Created).ThenByDescending(t => t.Id, StringComparer.Ordinal)],
            "priority" => [.. items.OrderBy(Rank).ThenBy(t => t.Order).ThenBy(t => t.Id, StringComparer.Ordinal)],
            _ => [.. items.OrderBy(t => t.Order).ThenBy(t => t.Id, StringComparer.Ordinal)],
        };
    }

    /// A dragged task's new position between its new neighbours (TodoSections.position(between:and:)): halfway, one
    /// past the last, one before the first, or now (seconds since 1970) in an empty list.
    public static double Position(TodoTask? above, TodoTask? below, DateTimeOffset now) => (above?.Order, below?.Order) switch
    {
        ({ } a, { } b) => (a + b) / 2,
        ({ } a, null) => a + 1,
        (null, { } b) => b - 1,
        _ => now.ToUnixTimeMilliseconds() / 1000.0,
    };

    /// Search: title, notes, the bot's line, steps and tags; "#tag" finds the tag alone.
    /// [WIN-47] `goals`: a task is found by its goal's and milestone's names too (TodoModel.swift `filtered`).
    public static List<TodoTask> Filtered(IEnumerable<TodoTask> tasks, string query, IEnumerable<Goal>? goals = null)
    {
        var words = query.Trim().ToLowerInvariant();
        if (words.Length == 0) return [.. tasks];
        if (words.StartsWith('#')) return [.. tasks.Where(t => t.Tags.Any(tag => tag.ToLowerInvariant().StartsWith(words[1..], StringComparison.Ordinal)))];
        var known = goals?.ToList() ?? [];
        return [.. tasks.Where(t => new[] { t.Title, t.Notes, t.StatusNote }.Concat(t.Steps.Select(s => s.Title)).Concat(t.Tags)
            .Concat(GoalViews.SearchWords(t, known)).Any(f => f.ToLowerInvariant().Contains(words)))];
    }
}

public static class TodoViews
{
    private static readonly CultureInfo En = CultureInfo.GetCultureInfo("en-US");

    /// A bot finished its part, or has a question: the task waits on you.
    public static bool WaitsOnYou(TodoTask task) => task.Status is "ready" or "needs_you";
    /// A task a bot does by itself.
    public static bool BotsOwn(TodoTask task) => task.WhoKind == TodoWho.Bot;
    /// It belongs in your day: yours, one you share, or a bot's own once it waits on you.
    public static bool InYourDay(TodoTask task) => !BotsOwn(task) || WaitsOnYou(task);

    public static string DayKey(DateTime localDay) => localDay.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    /// The Bots pill shows once a bot has a task of its own.
    public static bool ShowsBots(IEnumerable<TodoTask> tasks) => tasks.Any(BotsOwn);

    /// How many of a list's open tasks Today shows under the dated ones.
    public const int NextCount = 3;

    /// The view's groups, top to bottom; empty ones are left out.
    public static List<TodoGroup> Groups(IReadOnlyList<TodoTask> tasks, TodoView view, IReadOnlyList<TodoUserSection> sections,
        IReadOnlyList<string> bots, DateTimeOffset now, TimeZoneInfo zone, string sort = "smart")
    {
        var today = TodoDates.LocalDay(now, zone);
        var known = sections.Select(s => s.Id).ToHashSet();
        DateTime? DueDay(TodoTask t) => TodoDates.Due(t.Due, zone) is { } d ? TodoDates.LocalDay(d.Date, zone) : null;
        DateTime? StartDay(TodoTask t) => t.Starts is { Length: >= 10 } s && TodoDates.Day(s[..10], zone) is { } d ? TodoDates.LocalDay(d, zone) : null;
        bool Waits(TodoTask t) => StartDay(t) is { } s && s > today;
        bool Started(TodoTask t) => StartDay(t) is { } s && s <= today;
        DateTimeOffset DueOf(TodoTask t) => TodoDates.Due(t.Due, zone)?.Date ?? DateTimeOffset.MaxValue;
        DateTimeOffset Created(TodoTask t) => TodoDates.Moment(t.CreatedAt) ?? DateTimeOffset.MinValue;
        DateTimeOffset Updated(TodoTask t) => TodoDates.Moment(t.UpdatedAt) ?? Created(t);
        DateTimeOffset Finished(TodoTask t) => TodoDates.Moment(t.DoneAt) ?? Updated(t);
        List<TodoTask> ByDue(IEnumerable<TodoTask> items) => [.. items.OrderBy(DueOf).ThenBy(Created).ThenBy(t => t.Id, StringComparer.Ordinal)];
        List<TodoTask> NewestDone(IEnumerable<TodoTask> items) => [.. items.OrderByDescending(Finished).ThenByDescending(t => t.Id, StringComparer.Ordinal)];
        var output = new List<TodoGroup>();
        void Add(TodoGroupKind kind, List<TodoTask> items) { if (items.Count > 0) output.Add(new TodoGroup(kind, items)); }
        var open = tasks.Where(t => !t.IsDone).ToList();
        var done = tasks.Where(t => t.IsDone).ToList();
        string? ListOf(TodoTask t) => t.Section is { } s && known.Contains(s) ? s : null;

        if (view.Key == "today")
        {
            var mine = open.Where(InYourDay).ToList();
            var overdue = mine.Where(t => !Waits(t) && DueDay(t) is { } d && d < today).ToList();
            var todays = mine.Where(t =>
            {
                if (Waits(t)) return false;
                if (DueDay(t) == today) return true;
                return Started(t) && (DueDay(t) is not { } d || d > today);
            }).ToList();
            var dated = overdue.Concat(todays).Select(t => t.Id).ToHashSet();
            Add(TodoGroupKind.Overdue, ByDue(overdue));
            Add(TodoGroupKind.Today, ByDue(todays));
            var waiting = mine.Where(t => WaitsOnYou(t) && !dated.Contains(t.Id))
                .OrderByDescending(Updated).ThenByDescending(t => t.Id, StringComparer.Ordinal).ToList();
            Add(TodoGroupKind.Waiting, waiting);
            var shown = dated.Union(waiting.Select(t => t.Id)).ToHashSet();
            foreach (var section in sections.Where(s => s.InToday))
            {
                var rest = TodoSections.Ordered(mine.Where(t => t.Section == section.Id && !BotsOwn(t) && !shown.Contains(t.Id) && !Waits(t)
                    && (DueDay(t) is not { } d || d <= today)), "smart", zone);
                if (rest.Count == 0) continue;
                output.Add(new TodoGroup(TodoGroupKind.Next(section.Id), [.. rest.Take(NextCount)], Math.Max(0, rest.Count - NextCount)));
            }
            Add(TodoGroupKind.Done, NewestDone(done.Where(t => !BotsOwn(t) && TodoDates.LocalDay(Finished(t), zone) == today)));
        }
        else if (view.Key == "upcoming")
        {
            DateTime? DayOf(TodoTask t)
            {
                if (Waits(t)) return StartDay(t);
                if (Started(t)) return null;
                return DueDay(t) is { } d && d > today ? d : null;
            }
            var coming = open.Where(t => InYourDay(t) && DayOf(t) != null);
            foreach (var g in coming.GroupBy(t => DayKey(DayOf(t)!.Value)).OrderBy(g => g.Key, StringComparer.Ordinal))
                Add(TodoGroupKind.Day(g.Key), ByDue(g));
        }
        else if (view.Key == "inbox")
        {
            var loose = open.Where(t => !BotsOwn(t) && ListOf(t) == null).ToList();
            Add(TodoGroupKind.Open, [.. loose.Where(t => !TodoSections.IsStale(t, now)).OrderByDescending(Created).ThenByDescending(t => t.Id, StringComparer.Ordinal)]);
            Add(TodoGroupKind.Stale, [.. loose.Where(t => TodoSections.IsStale(t, now)).OrderBy(Updated).ThenBy(t => t.Id, StringComparer.Ordinal)]);
            Add(TodoGroupKind.Done, NewestDone(done.Where(t => !BotsOwn(t) && ListOf(t) == null)));
        }
        else if (view.ListId is { } id)
        {
            Add(TodoGroupKind.Open, TodoSections.Ordered(open.Where(t => t.Section == id), sort, zone));
            Add(TodoGroupKind.Done, NewestDone(done.Where(t => t.Section == id)));
        }
        else if (view.Key == "bots")
        {
            var theirs = open.Where(BotsOwn).ToList();
            var byBot = theirs.GroupBy(t => t.Helper ?? "default").ToDictionary(g => g.Key, g => g.ToList());
            var order = bots.Where(byBot.ContainsKey).Concat(byBot.Keys.Where(k => !bots.Contains(k)).Order(StringComparer.Ordinal));
            foreach (var bot in order)
                Add(TodoGroupKind.Bot(bot), [.. byBot[bot].OrderBy(t => t.Status == "working" ? 0 : 1).ThenBy(DueOf).ThenBy(Created).ThenBy(t => t.Id, StringComparer.Ordinal)]);
            Add(TodoGroupKind.Done, NewestDone(done.Where(BotsOwn)));
        }
        return output;
    }

    /// [WIN-53] A search looks through every view, whichever pill is picked (Goals too): its matches' open tasks, soonest
    /// due first ("To Do"), then the done ones, newest first (TasksViewController.reload at 93f984bb1: `if searching`,
    /// TodoSections.ordered(open, sort: "due") and TodoSections.sorted(done, in: .done)). Empty groups are left out.
    public static List<TodoGroup> SearchGroups(IReadOnlyList<TodoTask> matches, TimeZoneInfo zone)
    {
        DateTimeOffset Created(TodoTask t) => TodoDates.Moment(t.CreatedAt) ?? DateTimeOffset.MinValue;
        DateTimeOffset Finished(TodoTask t) => TodoDates.Moment(t.DoneAt) ?? TodoDates.Moment(t.UpdatedAt) ?? Created(t);
        var output = new List<TodoGroup>();
        var open = TodoSections.Ordered(matches.Where(t => !t.IsDone), "due", zone);
        if (open.Count > 0) output.Add(new TodoGroup(TodoGroupKind.Open, open));
        List<TodoTask> done = [.. matches.Where(t => t.IsDone).OrderByDescending(Finished).ThenByDescending(t => t.Id, StringComparer.Ordinal)];
        if (done.Count > 0) output.Add(new TodoGroup(TodoGroupKind.Done, done));
        return output;
    }

    /// The number on a view's pill: its open tasks (Today's counts what is dated or waits on you).
    public static int OpenCount(IReadOnlyList<TodoTask> tasks, TodoView view, IReadOnlyList<TodoUserSection> sections, DateTimeOffset now,
        TimeZoneInfo zone) =>
        Groups(tasks, view, sections, [], now, zone).Where(g => !g.Kind.IsNext && g.Kind != TodoGroupKind.Done).Sum(g => g.Tasks.Count);

    /// Today's Done group folds to one line: "Done today · 4".
    public static string DoneLine(int count) => $"Done today · {count}";
    /// Under a list's next tasks in Today: "4 more in Work".
    public static string MoreLine(int more, string list) => $"{more} more in {list}";

    /// "Mon" for a day in the next six, else "Nov 16".
    public static string Soon(DateTimeOffset date, DateTimeOffset now, TimeZoneInfo zone)
    {
        var word = TodoWords.Day(date, now, zone);
        if (word is "Today" or "Tomorrow" or "Yesterday") return word;
        var days = (TodoDates.LocalDay(date, zone) - TodoDates.LocalDay(now, zone)).Days;
        return days is >= 2 and <= 6 ? TimeZoneInfo.ConvertTime(date, zone).ToString("ddd", En) : word;
    }

    /// A day group's heading in Upcoming: ("Tomorrow", "Fri, Nov 13") or ("Sat, Nov 14", null).
    public static (string Title, string? Detail) DayHeading(string key, DateTimeOffset now, TimeZoneInfo zone)
    {
        if (TodoDates.Day(key, zone) is not { } date) return (key, null);
        var local = TimeZoneInfo.ConvertTime(date, zone);
        var sameYear = local.Year == TimeZoneInfo.ConvertTime(now, zone).Year;
        var full = local.ToString(sameYear ? "ddd, MMM d" : "ddd, MMM d, yyyy", En);
        return TodoWords.Day(date, now, zone) == "Tomorrow" ? ("Tomorrow", full) : (full, null);
    }

    /// A row's words in a group.
    public static TodoRowWords Row(TodoTask task, TodoGroupKind kind, DateTimeOffset now, TimeZoneInfo zone, Func<string?, string> botName)
    {
        var words = new TodoRowWords
        {
            Priority = task.IsDone ? 0 : task.Priority,
            Tags = kind == TodoGroupKind.Open && !task.IsDone ? [.. task.Tags.Take(2)] : [],
            Steps = task.Steps.Count > 0 ? $"{task.Steps.Count(s => s.Done)}/{task.Steps.Count}" : null,
            Repeats = task.RepeatRule != null,
        };
        var name = botName(task.Helper);
        var note = task.StatusNote.Trim();
        if (task.IsDone)
            return words with { When = TodoDates.Moment(task.DoneAt) is { } d ? TodoWords.Day(d, now, zone) : null };
        if (TodoDates.Due(task.Due, zone) is { } due)
        {
            var time = due.HasTime ? TodoWords.Clock(due.Date, zone) : null;
            var today = TodoDates.LocalDay(now, zone);
            var day = TodoDates.LocalDay(due.Date, zone);
            if (kind == TodoGroupKind.Today && day > today) words = words with { When = Soon(due.Date, now, zone) };
            else if (kind.IsDay && kind.Arg != DayKey(day)) words = words with { When = "Due " + Soon(due.Date, now, zone) };
            else if (kind == TodoGroupKind.Today || kind.IsDay) words = words with { When = time };
            else if (kind == TodoGroupKind.Overdue) words = words with { When = TodoWords.Day(due.Date, now, zone), Late = true };
            else words = words with { When = day == today ? time ?? "Today" : Soon(due.Date, now, zone), Late = day <= today };
        }
        if (task.Helper != null)
            words = words with { Dot = task.Status switch { "working" => "working", "ready" => "ready", "needs_you" => "question", _ => null } };
        switch (task.Status)
        {
            case "ready":
                words = words with { Note = note.Length == 0 ? $"{name} finished its part" : $"{name}: {note}", Tone = TodoTone.Ready };
                break;
            case "needs_you":
                words = words with
                {
                    Note = note.Length == 0 ? $"{name} needs you" : note.EndsWith('?') ? $"{name} asks: {note}" : $"{name} needs you: {note}",
                    Tone = TodoTone.NeedsYou,
                };
                break;
            default:
                if (task.Offer is { Kept: false } offer && kind != TodoGroupKind.Stale)
                {
                    var why = offer.Text.Trim();
                    words = words with { Note = why.Length == 0 ? $"{botName(offer.By)} thinks this is done" : $"{botName(offer.By)}: looks done · {why}", Tone = TodoTone.Ready };
                }
                else if (kind == TodoGroupKind.Stale)
                {
                    var when = TodoDates.Moment(task.CreatedAt) is { } c ? TodoWords.Day(c, now, zone) : null;
                    words = words with { Note = string.Join(" · ", new[] { $"Added by {botName(task.CreatedBy)}", when }.OfType<string>()) };
                }
                else if (kind.IsBot && task.Status == "working" && note.Length > 0)
                    words = words with { Note = note };
                break;
        }
        return words;
    }

    /// A group's heading; null for one with none (a list's and Inbox's open tasks).
    public static (string Title, string? Detail)? Heading(TodoGroupKind kind, DateTimeOffset now, TimeZoneInfo zone,
        IReadOnlyList<TodoUserSection> sections, Func<string?, string> botName)
    {
        if (kind.IsNext) return ($"Next in {sections.FirstOrDefault(s => s.Id == kind.Arg)?.Name ?? "List"}", null);
        if (kind.IsDay) return DayHeading(kind.Arg!, now, zone);
        if (kind.IsBot) return (botName(kind.Arg), null);
        return kind.Key switch
        {
            "overdue" => ("Overdue", null),
            "today" => ("Today", null),
            "waiting" => ("Waiting on You", null),
            "stale" => (TodoSections.StaleTitle, null),
            "done" => ("Done", null),
            _ => null,
        };
    }

    /// A group's heading as the Tasks page draws it (TasksViewController.heading at 93f984bb1): none over a list's or
    /// Inbox's open tasks, but "To Do" while searching (one flat list of matches); Today's Done is "Done Today" (not while
    /// searching); every other group as `Heading`.
    public static (string Title, string? Detail)? PageHeading(TodoGroupKind kind, TodoView view, bool searching, DateTimeOffset now,
        TimeZoneInfo zone, IReadOnlyList<TodoUserSection> sections, Func<string?, string> botName)
    {
        if (kind == TodoGroupKind.Open) return searching ? ("To Do", null) : null;
        if (kind == TodoGroupKind.Done && view == TodoView.Today && !searching) return ("Done Today", null);
        return Heading(kind, now, zone, sections, botName);
    }

    /// Done's rows show once its heading's Show is clicked, and always while searching (TasksViewController.reload:
    /// `let open = doneOpen || searching`). Every other group shows its rows.
    public static bool ShowsRows(TodoGroupKind kind, bool doneOpen, bool searching) =>
        kind != TodoGroupKind.Done || doneOpen || searching;

    /// The words at the end of Done's heading: "Show" while folded, "Hide" while open; none while searching
    /// (TasksViewController.configureHeader). Other groups have no fold.
    public static string? DoneFold(TodoGroupKind kind, bool doneOpen, bool searching) =>
        kind == TodoGroupKind.Done && !searching ? (doneOpen ? "Hide" : "Show") : null;

    /// The heading drawn in red (`hqRed`): Overdue alone (TasksViewController.configureHeader at 93f984bb1,
    /// `TodoGroupHeaderView(…, red: kind == .overdue)`). In the iOS look its name goes red and the count stays grey.
    public static bool HeadingIsRed(TodoGroupKind kind) => kind == TodoGroupKind.Overdue;

    /// The fold's identifier (TodoGroupHeaderView.foldID).
    public const string DoneFoldId = "tasks.show-done";

    /// A group heading's identifier: "tasks.section.<title>".
    public static string SectionAutomationId(string title) => "tasks.section." + title;

    /// "High", "Medium", "Low"; "None" for 0.
    public static string PriorityWord(int priority) => priority switch { 1 => "High", 2 => "Medium", 3 => "Low", _ => "None" };

    /// The who row's words: "You", "You & Hermes", "Finance".
    public static string Who(TodoTask task, Func<string?, string> botName) => task.WhoKind switch
    {
        TodoWho.Me => "You",
        TodoWho.Together => $"You & {botName(task.Helper)}",
        _ => botName(task.Helper),
    };

    /// What the task's bot is doing: "Working", "Has a question", "Finished its part".
    public static (string Words, TodoTone Tone)? BotState(TodoTask task)
    {
        if (task.Helper == null || task.IsDone) return null;
        return task.Status switch
        {
            "working" => ("Working", TodoTone.Working),
            "needs_you" => ("Has a question", TodoTone.NeedsYou),
            "ready" => ("Finished its part", TodoTone.Ready),
            _ => null,
        };
    }

    /// The bar's words on a task's page: its list, else "No List"; plain "Task" for someone with no lists.
    public static string ListTitle(TodoTask task, IReadOnlyList<TodoUserSection> sections)
    {
        if (sections.Count == 0) return "Task";
        return task.Section is { } id && sections.FirstOrDefault(s => s.Id == id) is { } s ? s.Name : "No List";
    }

    /// What a view says with nothing in it.
    public static string EmptyText(TodoView view, string? listName) => view.Key switch
    {
        "today" => "Nothing due today.",
        "upcoming" => "Nothing coming up. A task with a date shows here.",
        "inbox" => "Nothing left to file. A task in no list lands here.",
        "bots" => "No bot has a task of its own right now.",
        _ => $"No tasks in {listName ?? "this list"} yet.",
    };

    /// Tags as typed in one field ("hiring, q4"): split at commas, a leading # dropped, each once, ten at most.
    public static List<string> TagsFrom(string text)
    {
        var output = new List<string>();
        var seen = new HashSet<string>();
        foreach (var part in text.Split([',', '\n'], StringSplitOptions.None))
        {
            var tag = part.Trim().TrimStart('#').Trim();
            if (tag.Length > 30) tag = tag[..30];
            if (tag.Length > 0 && seen.Add(tag.ToLowerInvariant())) output.Add(tag);
        }
        return [.. output.Take(10)];
    }
}

/// The page's own words (App/Pages/Tasks/*.swift).
public static class TasksCopy
{
    /// [goals] New Goal on an add-on that keeps no goals (TasksViewController.swift "Goals Need a Newer Add-on").
    public const string GoalsNeedAddOn = "Goals Need a Newer Add-on";
    public const string Title = "Tasks";
    public const string SearchPlaceholder = "Search Tasks";
    public const string NewTask = "New Task";
    public const string Today = "Today", Upcoming = "Upcoming", Inbox = "Inbox", Bots = "Bots";
    /// A view pill's count beside its title (TaskViewsHeader.swift line 76 at 93f984bb1: `count > 0`): none for 0 or
    /// no count, so an emptied list reads "Home", not "Home 0".
    public static string? PillDetail(int? count) =>
        count is > 0 and var n ? n.ToString(System.Globalization.CultureInfo.InvariantCulture) : null;
    /// The pill as screen readers hear it (`spoken`, lines 153–156): "Home, 1 task", "Work, 8 tasks", or the title
    /// alone for 0 or no count. Every pill, Goals too.
    public static string PillName(string title, int? count) =>
        count is > 0 and var n ? $"{title}, {n} {(n == 1 ? "task" : "tasks")}" : title;
    public const string NoTasks = "No Tasks";
    public const string NothingText = "Add what you need to do. Bots add tasks from your chats too, and get their part ready for you.";
    public const string CouldNotLoad = "Couldn’t Load Tasks";
    public const string UpdateAddOn = "Update the Add-on";
    public const string AddOnName = "Hermes HQ Add-on";
    public static string UpdateAddOnText(string host) => $"Tasks needs {AddOnName} 0.9.32 or later on {host}.";
    public const string TryAgain = "Try Again";
    public const string OpenTask = "Open Task";
    public const string MarkDone = "Mark Done";
    public const string MarkNotDone = "Mark Not Done";
    public const string MoveTo = "Move To";
    public const string NoList = "No List";
    public const string Delete = "Delete";
    public const string DeleteTask = "Delete Task";
    public const string Cancel = "Cancel";
    public const string Untitled = "Untitled Task";
    public static string DeleteTitle(string title) => $"Delete “{title}”?";
    public const string DeleteMessage = "It goes from the list for you and your bots.";
    public const string ThisTaskWasDeleted = "This task was deleted.";
    public const string NoDate = "No date";
    public const string NoDueDate = "No Due Date";
    public const string ChooseDate = "Choose Date…";
    public const string Tomorrow = "Tomorrow";
    public const string NextWeek = "Next Week";
    public const string Assign = "Assign";
    public const string JustMe = "Just Me";
    public const string WithMe = "With Me";
    public const string ByItself = "By Itself";
    public const string You = "You";
    public const string Notes = "Notes";
    public const string Steps = "Steps";
    public const string AddStep = "Add step";
    public const string DeleteStep = "Delete Step";
    public const string PlusNotes = "+ Notes", PlusRepeat = "+ Repeat", PlusPriority = "+ Priority", PlusTags = "+ Tags";
    public const string NoPriority = "No Priority";
    public const string DontRepeat = "Don’t Repeat";
    public const string Done = "Done";
    public const string Save = "Save";
    // New Task (App/Pages/Tasks/NewTodoSheet.swift).
    public const string Add = "Add";
    public const string WhatNeedsToBeDone = "What needs to be done?";
    public const string TaskTitle = "Task title";
    public const string WhosInvolved = "Who's involved";
    public const string WorkTogether = "Work together";
    public static string GiveTo(string bot) => $"Give to {bot}";
    public const string Details = "Details";
    public const string DetailsFooter = "Notes, date, priority and list";
    public const string Date = "Date";
    public const string Priority = "Priority";
    public const string List = "List";
    public static string Added(string title) => $"Added “{title}”";
    public static string StartsRightAway(string bot) => $"{bot}’s chat opens and it starts on the task right away.";
    public const string CheckConnection = "Check your connection, then try again.";
    // Notices (HermesKit/Pages/Tasks/TasksStore.swift).
    public static string CouldNotAdd(string reason) => $"Couldn’t add the task. {reason}";
    public const string StillBeingAdded = "This task is still being added. Try again in a moment.";
    public const string ChangedElsewhere = "This task changed somewhere else. Showing the latest.";
    public const string DeletedElsewhere = "This task was deleted somewhere else.";
    public static string CouldNotSave(string reason) => $"Couldn’t save the change. {reason}";
    public static string CouldNotDelete(string reason) => $"Couldn’t delete the task. {reason}";
    public static string CouldNotSaveSettings(string reason) => $"Couldn’t save Tasks settings. {reason}";
}
