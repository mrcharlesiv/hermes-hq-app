using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Kanban;

/// The Kanban board model (HermesKit/Pages/KanbanModel.swift; docs/spec/1x-pages.md §4.3–§4.5), with the plugin's
/// words it uses. Pure functions on value snapshots.
public static partial class KanbanModel
{
    /// Chips in workflow order, except Blocked: it is often waiting on you, so it leads.
    public static readonly string[] StatusOrder = ["blocked", "triage", "todo", "scheduled", "ready", "running", "review", "done"];

    /// Blocked covers every block kind (your input, another task, a missing tool, a retry): each row says which.
    public static readonly IReadOnlyDictionary<string, string> StatusHelp = new Dictionary<string, string>
    {
        ["blocked"] = "Waiting on something, often you.",
        ["triage"] = "A bot turns the idea into a proper task first.",
        ["todo"] = "Waits until the tasks it depends on are done.",
        ["scheduled"] = "Waiting for its scheduled time.",
        ["ready"] = "The assigned bot picks it up within a minute.",
        ["running"] = "A bot is working on it.",
        ["review"] = "A bot is checking the work.",
        ["done"] = "Finished. The result is on the task.",
    };

    public static string Help(string status) => StatusHelp.TryGetValue(status, out var h) ? h : "";

    /// "2 Tasks · A bot is working on it": the help without its full stop (a heading).
    public static string GroupHeading(int count, string status)
    {
        var help = Help(status);
        if (help.EndsWith('.')) help = help[..^1];
        var tasks = $"{count} {(count == 1 ? "Task" : "Tasks")}";
        return help.Length == 0 ? tasks : $"{tasks} · {help}";
    }

    /// The line under a task's title: a running task names the bot doing it ("Deploys is working on it.").
    public static string StatusLine(string status, string? worker) =>
        status == "running" && !string.IsNullOrEmpty(worker) ? $"{worker} is working on it." : Help(status);

    /// The task sheet's Priority value, with which way it counts.
    public static string PriorityWords(int priority) => priority == 0 ? "None" : $"{priority} (higher goes first)";

    /// An unassigned task's Assigned To: the board's default bot runs it when there is one ("Deploys (default)").
    public static string NobodyWords(string defaultBot) => defaultBot.Length == 0 ? "No One" : $"{defaultBot} (default)";

    /// Column labels (`i18n.ts` `col.*.label`).
    public static readonly IReadOnlyDictionary<string, string> StatusLabels = new Dictionary<string, string>
    {
        ["triage"] = "Triage", ["todo"] = "Todo", ["scheduled"] = "Scheduled", ["ready"] = "Ready", ["running"] = "Running",
        ["blocked"] = "Blocked", ["review"] = "Review", ["done"] = "Done", ["archived"] = "Archived",
    };

    public static string Label(string status) => StatusLabels.TryGetValue(status, out var l) ? l
        : status.Length == 0 ? "" : (char.ToUpperInvariant(status[0]) + status[1..]).Replace('_', ' ');

    /// System-owned targets: a card may leave them, never be moved into them (`ui.tsx` `LOCKED_COLUMNS`).
    public static readonly IReadOnlySet<string> LockedColumns = new HashSet<string> { "review", "running", "scheduled" };
    public static bool IsLocked(string status) => LockedColumns.Contains(status);

    public static readonly IReadOnlyDictionary<string, string> LockedReasons = new Dictionary<string, string>
    {
        ["review"] = "A bot moves tasks into Review when it checks the work.",
        ["running"] = "A bot moves a task into Running when it starts work on it.",
        ["scheduled"] = "A bot schedules a task when it gives it a time to start.",
    };

    public static string LockedReason(string status) => LockedReasons.TryGetValue(status, out var r) ? r : $"{Label(status)} is set by the board.";

    /// The chips (and the Mac's columns): every known status in order, then any the backend adds, never `archived`.
    public static List<string> ChipOrder(IEnumerable<string> columns)
    {
        var list = columns.ToList();
        return [.. StatusOrder.Where(list.Contains), .. list.Where(c => !StatusOrder.Contains(c) && c != "archived")];
    }

    public static Dictionary<string, int> StatusCounts(KanbanBoard board)
    {
        var d = new Dictionary<string, int>();
        foreach (var c in board.Columns) d.TryAdd(c.Name, c.Tasks.Count);
        return d;
    }

    /// The first status with work in it (Done last, it is history), else the first chip.
    public static string DefaultStatus(IReadOnlyList<string> order, IReadOnlyDictionary<string, int> counts)
    {
        foreach (var s in order) if (s != "done" && counts.GetValueOrDefault(s) > 0) return s;
        if (counts.GetValueOrDefault("done") > 0) return "done";
        return order.Count > 0 ? order[0] : "triage";
    }

    public static bool Matches(KanbanTask task, string query)
    {
        var words = query.Trim().ToLowerInvariant();
        return words.Length == 0 || $"{task.Title} {task.Body ?? ""} {task.Id}".ToLowerInvariant().Contains(words);
    }

    public static KanbanBoard Filter(KanbanBoard board, string query)
    {
        if (query.Trim().Length == 0) return board;
        return board with { Columns = [.. board.Columns.Select(c => new KanbanColumn(c.Name, [.. c.Tasks.Where(t => Matches(t, query))]))] };
    }

    private static readonly string[] Months = CultureInfo.InvariantCulture.DateTimeFormat.MonthNames[..12];

    /// Done reads as history: Today, Yesterday, This Week, then months ("September", "June 2025").
    public static string DoneGroup(double? seconds, DateTimeOffset now, TimeZoneInfo? zone = null)
    {
        if (seconds is not { } s || s <= 0) return "Earlier";
        zone ??= TimeZoneInfo.Local;
        var date = TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds((long)(s * 1000)), zone);
        var today = TimeZoneInfo.ConvertTime(now, zone);
        var days = (today.Date - date.Date).Days;
        if (days <= 0) return "Today";
        if (days == 1) return "Yesterday";
        if (days < 7) return "This Week";
        var month = Months[date.Month - 1];
        return date.Year == today.Year ? month : $"{month} {date.Year}";
    }

    /// Consecutive runs under one heading, in the order given.
    public static List<(string Heading, List<T> Items)> GroupBy<T>(IEnumerable<T> items, Func<T, string> heading)
    {
        var groups = new List<(string Heading, List<T> Items)>();
        foreach (var item in items)
        {
            var name = heading(item);
            if (groups.Count > 0 && groups[^1].Heading == name) groups[^1].Items.Add(item);
            else groups.Add((name, [item]));
        }
        return groups;
    }

    /// "4m", "3h", "2d", "5w", "4mo", "1y" ("now" under a minute; "" for no time).
    public static string ShortAge(double? seconds, DateTimeOffset now)
    {
        if (seconds is not { } s || s <= 0) return "";
        var elapsed = Math.Max(0, now.ToUnixTimeMilliseconds() / 1000.0 - s);
        if (elapsed < 60) return "now";
        if (elapsed < 3600) return $"{(int)(elapsed / 60)}m";
        if (elapsed < 86_400) return $"{(int)(elapsed / 3600)}h";
        if (elapsed < 86_400 * 14) return $"{(int)(elapsed / 86_400)}d";
        if (elapsed < 86_400 * 60) return $"{(int)(elapsed / (86_400 * 7))}w";
        if (elapsed < 86_400 * 365) return $"{(int)(elapsed / (86_400 * 30))}mo";
        return $"{(int)(elapsed / (86_400 * 365))}y";
    }

    /// The task sheet's Running For, units spelled out: "Just started", "12 min", "3 hr", "2 days" ("" for no time).
    public static string RunningFor(double? seconds, DateTimeOffset now)
    {
        if (seconds is not { } s || s <= 0) return "";
        var elapsed = Math.Max(0, now.ToUnixTimeMilliseconds() / 1000.0 - s);
        if (elapsed < 60) return "Just started";
        if (elapsed < 3600) return $"{(int)(elapsed / 60)} min";
        if (elapsed < 86_400) return $"{(int)(elapsed / 3600)} hr";
        var days = (int)(elapsed / 86_400);
        return days == 1 ? "1 day" : $"{days} days";
    }

    /// "3h ago", "Just now", "".
    public static string Ago(double? seconds, DateTimeOffset now)
    {
        var age = ShortAge(seconds, now);
        return age.Length == 0 ? "" : age == "now" ? "Just now" : $"{age} ago";
    }

    public static string BlockReason(string? kind) => kind switch
    {
        "needs_input" => "Needs your input",
        "dependency" => "Waiting on another task",
        "capability" => "Missing a tool or skill",
        "transient" => "Will try again",
        _ => "Needs you",
    };

    /// The step a person usually takes from a status (the sheet's primary button, the card menu's first move).
    public static (string To, string Label)? QuickMove(string status) => status switch
    {
        "blocked" => ("ready", "Unblock"),
        "triage" or "todo" => ("ready", "Mark Ready"),
        "done" => ("ready", "Reopen"),
        _ => null,
    };

    /// The card leaves its column and goes to the top of the target (an optimistic edit).
    public static KanbanBoard MoveCard(KanbanBoard board, string id, string to, int token = 0)
    {
        KanbanTask? moved = null;
        var columns = board.Columns.Select(c => new KanbanColumn(c.Name, [.. c.Tasks.Where(t =>
        {
            if (t.Id != id) return true;
            moved = t with { Status = to, EditToken = token };
            return false;
        })])).ToList();
        if (moved == null) return board;
        columns = [.. columns.Select(c => c.Name == to ? new KanbanColumn(c.Name, [moved, .. c.Tasks]) : c)];
        return board with { Columns = columns };
    }

    public static KanbanBoard RemoveCard(KanbanBoard board, string id) =>
        board with { Columns = [.. board.Columns.Select(c => new KanbanColumn(c.Name, [.. c.Tasks.Where(t => t.Id != id)]))] };

    public static KanbanBoard EditCard(KanbanBoard board, string id, int token, Func<KanbanTask, KanbanTask> edit) =>
        board with { Columns = [.. board.Columns.Select(c => new KanbanColumn(c.Name, [.. c.Tasks.Select(t => t.Id == id ? edit(t) with { EditToken = token } : t)]))] };

    private static (string Column, int Index, KanbanTask Task)? Locate(KanbanBoard board, string id)
    {
        foreach (var c in board.Columns)
            for (var i = 0; i < c.Tasks.Count; i++)
                if (c.Tasks[i].Id == id) return (c.Name, i, c.Tasks[i]);
        return null;
    }

    /// R21: one failed optimistic write undone on its own task, only while the task is still what this write left.
    public static KanbanBoard RestoreTask(KanbanBoard now, KanbanBoard before, KanbanBoard after, string id)
    {
        var mine = Locate(after, id);
        var current = Locate(now, id);
        var same = mine == null ? current == null : current != null && mine.Value.Task.Same(current.Value.Task) && mine.Value.Column == current.Value.Column;
        if (!same) return now;
        var was = Locate(before, id);
        var columns = now.Columns.Select(c => new KanbanColumn(c.Name, [.. c.Tasks.Where(t => t.Id != id)])).ToList();
        if (was is { } w)
        {
            columns = [.. columns.Select(c =>
            {
                if (c.Name != w.Column) return c;
                var tasks = c.Tasks.ToList();
                tasks.Insert(Math.Min(w.Index, tasks.Count), w.Task);
                return new KanbanColumn(c.Name, tasks);
            })];
        }
        return now with { Columns = columns };
    }

    private static readonly HashSet<string> Upper = ["ai", "ha", "ui", "ux", "api", "ios", "qa", "seo", "crm", "kpi", "mvp"];

    /// A board's name as people read it: its own name, else its slug in words.
    public static string BoardTitle(string slug, string? name)
    {
        if (name?.Trim() is { Length: > 0 } n && n != slug) return n;
        if (slug.Length == 0 || slug == "default") return "Default Board";
        return string.Join(" ", slug.Split(['-', '_'], StringSplitOptions.RemoveEmptyEntries).Select(word =>
            Upper.Contains(word) ? word.ToUpperInvariant() : word == "saas" ? "SaaS" : char.ToUpperInvariant(word[0]) + word[1..]));
    }

    // ------------------------------------------------------------------ activity words

    private static JsonObject PayloadObject(JsonNode? payload, out string? raw)
    {
        raw = null;
        if (payload is JsonValue v && v.TryGetValue(out string? s))
        {
            if (string.IsNullOrEmpty(s)) return [];
            raw = s;
            return J.Parse(s) as JsonObject ?? throw new FormatException();
        }
        return payload as JsonObject ?? [];
    }

    /// The plugin's wording for an event (`drawer.tsx` `eventText`).
    public static (string Label, string? Detail) EventText(string kind, JsonNode? payload)
    {
        JsonObject p;
        try { p = PayloadObject(payload, out _); }
        catch (FormatException) { return (kind.Replace('_', ' '), J.AsString(payload)); }
        string? Str(string key) => p.Str(key) is { Length: > 0 } v && p.Get(key) is JsonValue jv && jv.GetValueKind() == JsonValueKind.String ? v : null;
        string? Col(string key) => Str(key) is { } s ? Label(s) : null;
        switch (kind)
        {
            case "created":
                var where = Col("status") ?? "";
                var assignee = Str("assignee") ?? "";
                return ($"created{(where.Length == 0 ? "" : $" in {where}")}{(assignee.Length == 0 ? "" : $" · assigned to {assignee}")}", null);
            case "status":
                var reason = Str("reason");
                return ($"moved to {Col("status") ?? "?"}", reason == "parent_reopened" ? $"parent {Str("parent") ?? ""} reopened" : reason);
            case "assigned": return Str("assignee") is { } a ? ($"assigned to {a}", null) : ("unassigned", null);
            case "commented": return ($"comment by {Str("author") ?? "someone"}", null);
            case "claimed": return (Str("source_status") == "review" ? "claimed by a review agent" : "claimed by a worker", null);
            case "spawned":
                var pid = p.Get("pid");
                return ("worker started", pid == null || pid.GetValueKind() == JsonValueKind.Null ? null : $"pid {J.AsString(pid) ?? ""}");
            case "completed": return ("completed", null);
            case "blocked": return ("blocked — needs human input", Str("reason"));
            case "unblocked":
                var c = Col("status") ?? "";
                return ($"unblocked{(c.Length == 0 ? " → Ready" : $" → {c}")}", null);
            case "reclaimed": return ("reclaimed — returned to the queue", Str("reason"));
            case "specified": return ("spec written by the triage agent", null);
            case "promoted": return ("dependencies done — promoted to Ready", null);
            case "scheduled": return ("scheduled for later", Str("reason"));
            case "archived": return ("archived", null);
            case "reprioritized": return ($"priority set to {J.AsString(p.Get("priority")) ?? "?"}", null);
            default:
                var detail = string.Join(" ", p.Select(kv => kv.Key).Order(StringComparer.Ordinal).Select(key =>
                {
                    var value = p[key];
                    if (value == null || value is JsonObject || value is JsonArray || value.GetValueKind() == JsonValueKind.Null) return null;
                    return $"{key}={J.AsString(value) ?? ""}";
                }).OfType<string>());
                return (kind.Replace('_', ' '), detail.Length == 0 ? null : detail);
        }
    }

    /// The bot's own words for the two lines the plugin leaves raw (`model.ts` `activityLine`).
    public static (string Label, string? Detail) ActivityLine(string kind, JsonNode? payload, (string Label, string? Detail) line,
        Func<string, string> botName)
    {
        JsonObject p;
        try { p = PayloadObject(payload, out _); } catch (FormatException) { p = []; }
        if (kind == "heartbeat")
        {
            if (p.Str("note") is { } note) return ("Progress update", note);
            return ("Progress update", line.Detail is { } d ? NotePrefix().Replace(d, "", 1) : null);
        }
        if (kind == "commented" && p.Str("author") is { } author)
            return ($"Comment from {(author == "desktop" ? "you" : botName(author))}", null);
        return line;
    }

    [GeneratedRegex("^note=")] private static partial Regex NotePrefix();
    [GeneratedRegex(@"^status changed to \w+ \(dashboard/direct\)$")] private static partial Regex AdminSummary();

    /// A reclaim writes an administrative note into the summary slot (hidden).
    public static bool IsAdminSummary(string summary) => AdminSummary().IsMatch(summary);

    /// The agent's latest summary, when it says more than the board's own bookkeeping or the result.
    public static string? LatestUpdate(KanbanTask task) =>
        task.LatestSummary is { Length: > 0 } s && !IsAdminSummary(s) && s != task.Result ? s : null;

    /// "Created 3h ago by Hermes".
    public static string? MadeLine(KanbanTask task, DateTimeOffset now, Func<string, string> botName)
    {
        var ago = Ago(task.CreatedAt, now);
        var by = task.CreatedBy is { Length: > 0 } b ? botName(b) : null;
        if (ago.Length == 0) return by == null ? null : $"Created by {by}";
        return $"Created {(ago == "Just now" ? "just now" : ago)}" + (by == null ? "" : $" by {by}");
    }

    /// The task sheet's dates: "Nov 6, 11:31 AM".
    public static string When(double seconds, TimeZoneInfo? zone = null)
    {
        var d = TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000)), zone ?? TimeZoneInfo.Local);
        return d.ToString("MMM d, h:mm tt", CultureInfo.GetCultureInfo("en-US"));
    }

    /// A run's outcome in words ("Timed Out · Deploys").
    public static string RunWords(KanbanTaskRun run, Func<string, string> botName)
    {
        var outcome = run.Outcome ?? run.Status;
        var words = CultureInfo.InvariantCulture.TextInfo.ToTitleCase(outcome.Replace('_', ' '));
        return words + (run.Profile is { } p ? $" · {botName(p)}" : "");
    }

    public static bool RunFailed(KanbanTaskRun run) => (run.Outcome ?? run.Status) is "crashed" or "failed" or "timed_out" or "gave_up";
    public static bool RunLive(KanbanTaskRun run) => (run.Outcome ?? run.Status) is "running" or "started" or "claimed";
}
