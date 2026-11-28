using System.Globalization;
using System.Text.Json.Nodes;

namespace Hermes.Core.Tasks;

/// 14-day stall detection for active goals (`GoalModel.swift` / `GoalBots.swift`).
public static class GoalStall
{
    public static readonly TimeSpan Threshold = TimeSpan.FromDays(14);

    public static bool IsStalled(Goal goal, IReadOnlyList<TodoTask> tasks, DateTimeOffset now)
    {
        if (goal.State != GoalState.Active) return false;
        var latest = LatestActivity(goal, tasks);
        if (latest == null) return false;
        return now - latest.Value >= Threshold;
    }

    public static DateTimeOffset? LatestActivity(Goal goal, IReadOnlyList<TodoTask> tasks)
    {
        var candidates = new List<DateTimeOffset?>
        {
            TodoDates.Moment(goal.KeptAt),
            TodoDates.Moment(goal.UpdatedAt),
            TodoDates.Moment(goal.CreatedAt),
            TodoDates.Moment(goal.Measure?.At),
            TodoDates.Moment(goal.Stands?.At),
            TodoDates.Moment(goal.Checkin?.At),
        };
        foreach (var m in goal.Milestones) candidates.Add(TodoDates.Moment(m.DoneAt));
        foreach (var t in GoalViews.TasksOf(goal, tasks))
            candidates.Add(TodoDates.Moment(t.DoneAt) ?? TodoDates.Moment(t.UpdatedAt) ?? TodoDates.Moment(t.CreatedAt));

        return candidates.OfType<DateTimeOffset>().OrderByDescending(d => d).FirstOrDefault() is var max && max != default
            ? max
            : null;
    }

    public static string Message(Goal goal, IReadOnlyList<TodoTask> tasks, DateTimeOffset now)
    {
        var latest = LatestActivity(goal, tasks);
        var days = latest != null ? Math.Max(14, (int)Math.Floor((now - latest.Value).TotalDays)) : 14;
        return $"No activity on “{goal.Shown}” for {days} days. Keep it going, pause it for someday, or let it go.";
    }
}

public sealed record GoalSetupRow(string Label, string Value, string Key = "");

/// Presentation rules for Goal Setup Plan and Check-in offer cards (`HermesKit/Pages/Goals/GoalBots.swift` + `GoalOfferViews.swift`).
public static class GoalOffers
{
    public const string BuiltOnHeader = "Built on";
    public const string SetupHeader = "Also sets";
    public const int BuiltOnShown = 3;

    /// "Your course notes, 8 units": one line each, at most 90 chars, empty dropped, at most 3 (`GoalOffers.builtOn`).
    public static IReadOnlyList<string> BuiltOnLines(TodoOffer offer)
    {
        var source = offer.BuiltOn.Count > 0 ? offer.BuiltOn : (offer.Plan?.BuiltOn ?? []);
        var result = new List<string>();
        foreach (var line in source)
        {
            var flat = string.Join(" ", line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
            if (flat.Length == 0) continue;
            if (flat.Length > 90) flat = flat[..89] + "…";
            result.Add(flat);
            if (result.Count >= BuiltOnShown) break;
        }
        return result;
    }

    /// What accepting a plan also changes on its goal: Name, Why, Number, By (`GoalOffers.setupRows`).
    public static IReadOnlyList<GoalSetupRow> SetupRows(GoalPlanSetup plan, DateTimeOffset now, TimeZoneInfo zone)
    {
        var rows = new List<GoalSetupRow>();
        if (!string.IsNullOrWhiteSpace(plan.Name)) rows.Add(new("Name", plan.Name!, "name"));
        if (!string.IsNullOrWhiteSpace(plan.Why)) rows.Add(new("Why", plan.Why!, "why"));
        if (plan.Measure is { } m)
            rows.Add(new("Number", GoalViews.MeasureWords(new GoalMeasure(m.Unit, m.Start, m.Target, m.Now), unit: true), "measure"));
        if (plan.Due is { Length: >= 10 } raw && TodoDates.Day(raw[..10], zone) is { } d)
            rows.Add(new("By", TodoWords.MonthDay(d, now, zone), "due"));
        return rows;
    }

    public static IReadOnlyList<GoalSetupRow> SetupRows(TodoOffer offer, DateTimeOffset now, TimeZoneInfo zone) =>
        offer.Kind == "plan" && offer.Setup is { } setup ? SetupRows(setup, now, zone) : [];

    public static IReadOnlyList<TodoOffer> Waiting(IEnumerable<TodoOffer> all) =>
        [.. all.Where(o => o.IsGoal && o.IsWaiting && !o.Held)];

    public static TodoOffer? Today(IEnumerable<TodoOffer> all, IEnumerable<Goal> goals)
    {
        var known = goals.Where(g => g.State == GoalState.Active).Select(g => g.Id).ToHashSet(StringComparer.Ordinal);
        return Waiting(all)
            .Where(o => o.Goal == null || known.Contains(o.Goal))
            .OrderBy(o => TodoDates.Moment(o.At) ?? DateTimeOffset.MinValue)
            .ThenBy(o => o.Id, StringComparer.Ordinal)
            .FirstOrDefault();
    }

    public static IReadOnlyList<TodoOffer> OnGoal(IEnumerable<TodoOffer> all, string goalId) =>
        [.. all.Where(o => o.IsGoal && !o.Held && (o.Goal == goalId || o.MadeGoal == goalId) && (o.IsWaiting || o.State == "accepted"))
               .OrderBy(o => TodoDates.Moment(o.At) ?? DateTimeOffset.MinValue)
               .ThenBy(o => o.Id, StringComparer.Ordinal)];

    public static string MilestoneCount(int n) => n == 1 ? "1 milestone" : $"{n} milestones";

    public static IReadOnlyList<TodoOfferButton> Buttons(TodoOffer offer) => TodoOfferRules.OfferButtons(offer);

    public static string? Foot(TodoOffer offer, Func<string?, string> botName)
    {
        if (offer.IsWaiting) return $"Proposed by {botName(offer.Bot)}";
        var done = TodoOfferRules.DoneLabel(offer);
        return string.IsNullOrEmpty(done) ? null : $"{done} · {botName(offer.Bot)}";
    }
}

/// Prevents duplicating the same goal-plan prompt/bubble in a single chat session (`GoalPlanTold`).
public sealed class GoalPlanTold
{
    private readonly HashSet<string> _seen = new(StringComparer.Ordinal);
    public bool Remember(string goalId, string offerId) => _seen.Add($"{goalId}:{offerId}");
    public bool WasTold(string goalId, string offerId) => _seen.Contains($"{goalId}:{offerId}");
}

/// Guard preventing concurrent duplicate setup-plan requests for the same goal (`GoalPlanGuard`).
public sealed class GoalPlanGuard
{
    private readonly HashSet<string> _inFlight = new(StringComparer.Ordinal);
    public bool TryBegin(string goalId) => _inFlight.Add(goalId);
    public void End(string goalId) => _inFlight.Remove(goalId);
    public bool IsBusy(string goalId) => _inFlight.Contains(goalId);
}

/// Bot selection, formatting, & prompt text for goals with bots (`GoalBots.swift`).
public static class GoalBots
{
    public static readonly IReadOnlyList<string> Weekdays =
        ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];

    public static readonly IReadOnlyList<string> ReviewTimes =
        ["07:00", "08:00", "09:00", "12:00", "17:00", "18:00", "20:00"];

    /// The who row: "Led by Hermes"; with no lead but helpers, "Helped by Ivy"; null with no bot.
    public static string? WhoLine(Goal goal, Func<string?, string> botName)
    {
        if (goal.Lead is { } lead) return $"Led by {botName(lead)}";
        if (goal.Helpers.Count == 0) return null;
        var first = goal.Helpers[0];
        return goal.Helpers.Count == 1
            ? $"Helped by {botName(first)}"
            : $"Helped by {botName(first)} and {goal.Helpers.Count - 1} more";
    }

    /// Push `request` "goal:<id>" → "<id>"; null for a task's push.
    public static string? PushedGoal(string? request) =>
        request != null && request.StartsWith("goal:", StringComparison.Ordinal) && request.Length > 5
            ? request[5..]
            : null;

    /// "8 AM", "8:30 AM", "12 PM".
    public static string Time(string hhmm)
    {
        var parts = hhmm.Split(':');
        if (parts.Length != 2 || !int.TryParse(parts[0], out var h) || !int.TryParse(parts[1], out var m))
            return hhmm;
        var hour = h % 24;
        var twelve = hour % 12 == 0 ? 12 : hour % 12;
        var clock = m == 0 ? twelve.ToString(CultureInfo.InvariantCulture) : string.Create(CultureInfo.InvariantCulture, $"{twelve}:{m:00}");
        return clock + (hour < 12 ? " AM" : " PM");
    }

    /// "Mondays 8 AM"; "Off" with no check-in.
    public static string ReviewWords(GoalReview? review) =>
        review != null && review.Day >= 0 && review.Day < Weekdays.Count
            ? $"{Weekdays[review.Day]}s {Time(review.Time)}"
            : "Off";

    /// Edit Goal's Number From: "TestFlight · Hermes", or "You".
    public static string NumberFromWords(GoalMeasure measure, Func<string?, string> botName)
    {
        var src = measure.EffectiveSource;
        if (src.Bot is not { Length: > 0 } bot) return "You";
        var what = src.What.Trim();
        return what.Length == 0 ? botName(bot) : $"{what} · {botName(bot)}";
    }

    /// The number row's end when a bot reads it: "TestFlight · 8:02 AM"; null when the number is yours.
    public static string? SourceWords(GoalMeasure measure, DateTimeOffset now, Func<string?, string> botName, TimeZoneInfo zone)
    {
        var src = measure.EffectiveSource;
        if (src.Bot is not { Length: > 0 } bot) return null;
        var what = src.What.Trim();
        var name = what.Length == 0 ? botName(bot) : what;
        var when = TodoDates.Moment(measure.CheckedAt) ?? TodoDates.Moment(measure.At);
        if (when == null) return name;
        var words = TodoDates.LocalDay(when.Value, zone) == TodoDates.LocalDay(now, zone)
            ? TodoWords.Clock(when.Value, zone)
            : TodoWords.Day(when.Value, now, zone);
        return $"{name} · {words}";
    }

    /// The lead's "this looks done" while it waits: active goal, not kept, for "goal" or an open milestone.
    public static GoalDoneOffer? LooksDone(Goal goal)
    {
        if (goal.State != GoalState.Active || goal.Offer is not { Kept: false } offer) return null;
        if (offer.What == "goal") return offer;
        return goal.Milestones.Any(m => m.Id == offer.What && !m.Done) ? offer : null;
    }

    /// "Hermes thinks Launch week looks done: all four posts are up. Mark it done?"
    public static string LooksDoneText(GoalDoneOffer offer, Goal goal, Func<string?, string> botName)
    {
        var why = offer.Text.Trim();
        var reason = why.Length == 0 ? "." : ": " + (why.EndsWith('.') ? why[..^1] : why) + ".";
        if (offer.What == "goal") return $"{botName(offer.By)} thinks this goal is achieved{reason} Mark it achieved?";
        var name = goal.Milestone(offer.What)?.Title ?? "this milestone";
        return $"{botName(offer.By)} thinks {name} looks done{reason} Mark it done?";
    }

    public static string LooksDoneYes(GoalDoneOffer offer) => offer.What == "goal" ? "Mark Achieved" : "Mark Done";

    public static bool WaitsForYou(Goal goal, IEnumerable<TodoOffer> offers) =>
        LooksDone(goal) != null || offers.Any(o => o.IsGoal && o.IsWaiting && !o.Held && o.Goal == goal.Id);

    public static string PickPlanner(Goal goal, IReadOnlyList<string> availableBots)
    {
        if (goal.Lead is { Length: > 0 } lead) return lead;
        if (goal.Helpers.FirstOrDefault() is { Length: > 0 } helper) return helper;
        return availableBots.FirstOrDefault(b => b == "default") ?? availableBots.FirstOrDefault() ?? "default";
    }

    public static string PlanRequest(Goal goal)
    {
        var why = string.IsNullOrWhiteSpace(goal.Why) ? "" : $"\nWhy it matters: {goal.Why.Trim()}";
        return $"Help me set up a clear, realistic plan for my goal “{goal.Shown}” (goal id: {goal.Id}).{why}\n"
            + "Suggest a target number (if useful), 3–5 concrete milestones, and the first few tasks as a Goal Setup Plan offer.";
    }

    public static string PlanBubble(Goal goal, string botName) =>
        $"Asked {botName} to draft a setup plan for “{goal.Shown}”.";

    public static string PlanTakenRequest(Goal goal, string botName) =>
        $"{botName} has drafted a setup plan for “{goal.Shown}”. Review the milestones and tasks to accept or adjust them.";
}

/// Team picker rules for assigning a lead bot, helper bots, and auto/ask task rule to a goal (`GoalTeam.swift`).
public static class GoalTeamPick
{
    public static JsonObject PatchFields(string? lead, IReadOnlyList<string> helpers, string adds = "ask", bool knownToAll = true)
    {
        var cleanLead = string.IsNullOrWhiteSpace(lead) ? null : lead.Trim();
        var cleanHelpers = helpers
            .Select(h => h.Trim())
            .Where(h => h.Length > 0 && !string.Equals(h, cleanLead, StringComparison.Ordinal))
            .Distinct(StringComparer.Ordinal)
            .ToList();

        return new JsonObject
        {
            ["lead"] = cleanLead,
            ["helpers"] = new JsonArray([.. cleanHelpers.Select(h => (JsonNode)h)]),
            ["adds"] = adds == "auto" ? "auto" : "ask",
            ["known_to_all"] = knownToAll,
        };
    }

    public static string Summary(Goal goal, Func<string?, string> botName)
    {
        if (goal.Lead == null && goal.Helpers.Count == 0) return "Just Me";
        if (goal.Lead != null && goal.Helpers.Count == 0) return $"Led by {botName(goal.Lead)}";
        if (goal.Lead != null) return $"Led by {botName(goal.Lead)} + {goal.Helpers.Count}";
        return string.Join(", ", goal.Helpers.Select(botName));
    }
}
