using System.Text.Json.Nodes;

namespace Hermes.Core.Tasks;

/// 14-day stall detection for active goals (`GoalModel.swift` / `GoalPlainView.swift`).
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

public sealed record GoalSetupRow(string Label, string Value);

/// Presentation rules for Goal Setup Plan and Check-in offer cards (`HermesKit/Pages/Goals/GoalBots.swift` + `GoalOfferViews.swift`).
public static class GoalOffers
{
    public static IReadOnlyList<string> BuiltOnLines(TodoOffer offer) =>
        offer.Plan?.BuiltOn ?? [];

    public static IReadOnlyList<GoalSetupRow> SetupRows(GoalPlanSetup plan, DateTimeOffset now, TimeZoneInfo zone)
    {
        var rows = new List<GoalSetupRow>();
        if (!string.IsNullOrWhiteSpace(plan.Name)) rows.Add(new("Goal", plan.Name!));
        if (!string.IsNullOrWhiteSpace(plan.Why)) rows.Add(new("Why", plan.Why!));
        if (plan.Measure is { } m)
            rows.Add(new("Number", GoalViews.MeasureWords(new GoalMeasure(m.Unit, m.Start, m.Target, m.Now), unit: true)));
        if (plan.Due is { Length: >= 10 } raw && TodoDates.Day(raw[..10], zone) is { } d)
            rows.Add(new("By", TodoWords.MonthDay(d, now, zone)));
        return rows;
    }

    public static IReadOnlyList<TodoOfferButton> Buttons(TodoOffer offer) => TodoOfferRules.OfferButtons(offer);

    public static string? Foot(TodoOffer offer, Func<string?, string> botName)
    {
        if (offer.IsWaiting) return $"Proposed by {botName(offer.By)}";
        var done = TodoOfferRules.DoneLabel(offer);
        return string.IsNullOrEmpty(done) ? null : $"{done} · {botName(offer.By)}";
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

/// Bot selection & prompt text for asking a bot to draft a Goal Setup Plan (`GoalBots.swift`).
public static class GoalBots
{
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
    public static JsonObject PatchFields(string? lead, IReadOnlyList<string> helpers, string adds = "ask", bool knownToAll = false)
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
