using System.Text.Json.Nodes;
using Hermes.Core.Tasks;

namespace Hermes.Core.Shell;

/// [WIN-42] What the tasks-goals walk (HermesHQ.Windows Services/ProofWalks.Goals.cs) checks, against the pages stand-in
/// with --task-goals --task-lists (ci/fixtures/pages-fixture-gateway.py `seed_task_goals`, every name made up). Kept apart
/// from WalkProof.cs so lanes don't collide; proved against the stand-in by GoalsEndToEndTests.
public static class GoalsWalkProof
{
    /// The Goals view's active cards, in the stand-in's order.
    public static readonly string[] ActiveTitles = ["1,000 public testers", "Run a 10K", "Family trip to the coast"];
    /// Someday (paused).
    public static readonly string[] SomedayTitles = ["Learn conversational Spanish"];
    /// Achieved (folded until its Show).
    public static readonly string[] AchievedTitles = ["Read 12 books this year"];

    /// The trip's next task (its loose tasks: four done, then these two in order), ticked by the walk on its card.
    public const string TripGoal = "g_trip";
    public const string TripNext = "t_g_tickets";
    public const string TripNextTitle = "Book the aquarium tickets";
    public const string TripAfter = "Make the packing list";

    /// Each active goal's shelf card says "Next: …" for these (the open milestone's first open task, else the first
    /// loose one).
    public static readonly string[] ShelfNext = ["Next: Post the build notes to the forum", "Next: Easy 3 mile run", "Next: " + TripNextTitle];

    /// [WIN-47] A search for "coast": its Goals group is the trip alone (by name), over the trip's tasks (found by their
    /// goal's name), each with the trip's mark.
    public const string SearchQuery = "coast";
    public static readonly string[] SearchCards = ["Family trip to the coast"];
    public const string SearchRow = "t_g_pack";

    /// [WIN-47] Today's goal task the walk moves with Add to Goal: under the testers goal's Launch week, due today.
    public const string MarkTask = "t_g_notes";
    public const string MarkGoalTitle = "1,000 public testers";
    /// Add to Goal's rows for it: the active goals (the 10K's a submenu), then No Goal and Open Goal.
    public static readonly string[] MarkChoices = ["1,000 public testers", "Run a 10K", "Family trip to the coast", "No Goal", "Open Goal"];
    /// The pick: the trip (no milestones), so the task leaves its milestone too.
    public const string MoveGoal = TripGoal;
    public const string MoveGoalTitle = "Family trip to the coast";

    /// A row's spoken name ends with its goal's words ("…, for <goal>"); null when so.
    public static string? RowMarked(string rowName, string goalTitle) =>
        rowName.EndsWith(", for " + goalTitle, StringComparison.Ordinal) || rowName.EndsWith(". for " + goalTitle, StringComparison.Ordinal)
            ? null : $"the row reads “{rowName}”, not for {goalTitle}";

    /// After `mark`, the stand-in took one write to the tasks: `PATCH …/tasks/<task>` with exactly `goal` and
    /// `milestone` (Add to Goal's pick, GoalViews.Assign). null when so, else what is wrong.
    public static string? GoalRecorded(JsonNode? fixtureState, int mark, string task, string? goal, string? milestone)
    {
        var after = (fixtureState.Arr("rest") ?? []).OfType<JsonNode>().Skip(Math.Max(0, mark)).ToList();
        var writes = after.Where(r => r.Str("method") is { } m && m != "GET"
            && (r.Str("path") ?? "").StartsWith(TasksApi.Route, StringComparison.Ordinal)).ToList();
        if (writes.Count != 1) return $"{writes.Count} writes reached the add-on: {string.Join(", ", writes.Select(w => w.Str("method") + " " + w.Str("path")))}";
        var w = writes[0];
        if (w.Str("method") != "PATCH" || w.Str("path") != TasksApi.Base + "/" + task) return $"Add to Goal wrote {w.Str("method")} {w.Str("path")}";
        var body = w["body"] as JsonObject;
        var keys = body?.Select(p => p.Key).Where(k => k != "rev").OrderBy(k => k, StringComparer.Ordinal).ToList() ?? [];
        if (!keys.SequenceEqual(["goal", "milestone"]) || body.Str("goal") != goal || body.Str("milestone") != milestone)
            return $"Add to Goal sent {body?.ToJsonString() ?? "null"}";
        return null;
    }

    /// The cards on show (`goal-card-<title>`) are exactly `titles`, in order; null when so, else what is wrong.
    public static string? CardsShown(IReadOnlyList<string> automationIds, IReadOnlyList<string> titles, string prefix = "goal-card-")
    {
        var shown = automationIds.Where(id => id.StartsWith(prefix, StringComparison.Ordinal)).Select(id => id[prefix.Length..]).ToList();
        return shown.SequenceEqual(titles) ? null : $"cards {string.Join(" | ", shown)}, not {string.Join(" | ", titles)}";
    }

    /// After `mark`, the stand-in took one write to the tasks: `PATCH …/tasks/<task>` with status done (the card's tick,
    /// as a task row's), and nothing to the goals. null when so.
    public static string? TickRecorded(JsonNode? fixtureState, int mark, string task)
    {
        var after = (fixtureState.Arr("rest") ?? []).OfType<JsonNode>().Skip(Math.Max(0, mark)).ToList();
        var writes = after.Where(r => r.Str("method") is { } m && m != "GET"
            && (r.Str("path") ?? "").StartsWith(TasksApi.Route, StringComparison.Ordinal)).ToList();
        if (writes.Count != 1) return $"{writes.Count} writes reached the add-on: {string.Join(", ", writes.Select(w => w.Str("method") + " " + w.Str("path")))}";
        var w = writes[0];
        if (w.Str("method") != "PATCH" || w.Str("path") != TasksApi.Base + "/" + task) return $"the tick wrote {w.Str("method")} {w.Str("path")}";
        return w["body"].Str("status") == "done" ? null : $"the tick sent {w["body"]?.ToJsonString() ?? "null"}";
    }
}
