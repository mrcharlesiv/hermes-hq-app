using System.Globalization;
using System.Text.Json.Nodes;

namespace Hermes.Core.Tasks;

// [goals] What your tasks are for (docs/goals.md; HermesKit/Pages/Goals/GoalModel.swift at 93f984bb1). The hermes-hq-push
// add-on keeps goals beside the list (0.9.65's `goals` in `GET /tasks`); the app draws them. Read leniently, as a task
// is: an unknown status or colour, or a field missing, never loses the goal, and one bad goal never loses the list.
// This slice reads step 1 and 2's fields; a goal's bots (0.9.66) are kept in Raw and not drawn yet.

/// Where a goal stands. An unknown status (a later add-on's) reads as active, so the goal still shows.
public enum GoalState { Active, Paused, Achieved, LetGo }

/// Where a goal's number reading comes from (`GoalSource`).
public sealed record GoalSource(string Kind, string? Ref = null, string? Label = null)
{
    public static GoalSource? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var kind = n.Text("kind");
        return kind == null ? null : new GoalSource(kind, n.Text("ref"), n.Text("label"));
    }

    public JsonObject Wire()
    {
        var o = new JsonObject { ["kind"] = Kind };
        if (Ref != null) o["ref"] = Ref;
        if (Label != null) o["label"] = Label;
        return o;
    }
}

/// One historical reading on a goal's measure.
public sealed record GoalReading(double Value, string At, string? Note = null, string? By = null)
{
    public static GoalReading? From(JsonNode? n)
    {
        if (n is not JsonObject || n.Num("value") is not { } v) return null;
        return new GoalReading(v, n.Str("at") ?? "", n.Text("note"), n.Text("by"));
    }

    public JsonObject Wire()
    {
        var o = new JsonObject { ["value"] = Value, ["at"] = At };
        if (Note != null) o["note"] = Note;
        if (By != null) o["by"] = By;
        return o;
    }
}

/// Periodic review schedule for a goal's bots (`GoalReview`).
public sealed record GoalReview(string Every, string? At = null, string? NextAt = null)
{
    public static GoalReview? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var every = n.Text("every");
        return every == null ? null : new GoalReview(every, n.Text("at"), n.Text("next_at"));
    }

    public JsonObject Wire()
    {
        var o = new JsonObject { ["every"] = Every };
        if (At != null) o["at"] = At;
        if (NextAt != null) o["next_at"] = NextAt;
        return o;
    }
}

/// Where the goal currently stands, written by its bot (`GoalStands`).
public sealed record GoalStands(string Summary, string? Next = null, string? At = null, string? By = null)
{
    public static GoalStands? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var summary = n.Text("summary");
        return summary == null ? null : new GoalStands(summary, n.Text("next"), n.Text("at"), n.Text("by"));
    }
}

/// Latest periodic check-in summary from the goal's lead bot (`GoalCheckin`).
public sealed record GoalCheckin(string Summary, string? At = null, string? By = null, bool Seen = false)
{
    public static GoalCheckin? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var summary = n.Text("summary");
        return summary == null ? null : new GoalCheckin(summary, n.Text("at"), n.Text("by"), n.Bool("seen") ?? false);
    }
}

/// Bot suggestion that a goal looks achieved (`GoalDoneOffer`).
public sealed record GoalDoneOffer(string By, string Text, string? At = null, bool Kept = false)
{
    public static GoalDoneOffer? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        return new GoalDoneOffer(n.Text("by") ?? "default", n.Str("text") ?? "", n.Text("at"), n.Bool("kept") ?? false);
    }
}

/// The goal's number: "340 of 1,000 testers". A target below the start counts down.
public sealed record GoalMeasure(string Unit, double Start, double Target, double Now)
{
    public string? At { get; init; }
    public GoalSource? Source { get; init; }
    public string? CheckedAt { get; init; }
    public IReadOnlyList<GoalReading> History { get; init; } = [];

    public static GoalMeasure? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var start = n.Num("start") ?? 0;
        return new GoalMeasure(n.Str("unit") ?? "", start, n.Num("target") ?? 0, n.Num("now") ?? start)
        {
            At = n.Str("at") is { Length: > 0 } at ? at : null,
            Source = GoalSource.From(n.Get("source")),
            CheckedAt = n.Str("checked_at") is { Length: > 0 } ca ? ca : null,
            History = [.. (n.Arr("history") ?? []).Select(GoalReading.From).OfType<GoalReading>()],
        };
    }

    public JsonObject Wire()
    {
        var o = new JsonObject
        {
            ["unit"] = Unit,
            ["start"] = Start,
            ["target"] = Target,
            ["now"] = Now,
        };
        if (At != null) o["at"] = At;
        if (Source != null) o["source"] = Source.Wire();
        if (CheckedAt != null) o["checked_at"] = CheckedAt;
        if (History.Count > 0) o["history"] = new JsonArray([.. History.Select(h => (JsonNode)h.Wire())]);
        return o;
    }

    /// It counts down (a weight to lose, a debt to pay off).
    public bool CountsDown => Target < Start;
}

/// One milestone, in the goal's order.
public sealed record GoalMilestone(string Id, string Title, string? Due = null, bool Done = false, string? DoneAt = null)
{
    public static GoalMilestone From(JsonNode? n) => new(n.Str("id") ?? "", n.Str("title") ?? "",
        n.Str("due") is { Length: > 0 } due ? due : null, n.Bool("done") ?? false, n.Str("done_at") is { Length: > 0 } at ? at : null);

    public JsonObject Wire()
    {
        var o = new JsonObject
        {
            ["id"] = string.IsNullOrEmpty(Id) ? TodoIds.Make() : Id,
            ["title"] = Title,
            ["done"] = Done,
        };
        if (Due != null) o["due"] = Due;
        if (DoneAt != null) o["done_at"] = DoneAt;
        return o;
    }
}

/// One goal, as the routes send it.
public sealed record Goal(string Id)
{
    public int Rev { get; init; }
    public string Title { get; init; } = "";
    public string Why { get; init; } = "";
    /// As sent: "active" | "paused" | "achieved" | "let_go" (`State` reads it).
    public string Status { get; init; } = "active";
    public string? StatusAt { get; init; }
    /// A list's colour name (TodoListColors); `Tint` reads it.
    public string? Color { get; init; }
    /// A day ("2027-01-31"), or null.
    public string? Due { get; init; }
    public double Position { get; init; }
    public GoalMeasure? Measure { get; init; }
    public IReadOnlyList<GoalMilestone> Milestones { get; init; } = [];
    public string? CreatedAt { get; init; }
    public string? UpdatedAt { get; init; }
    /// [goals-v2] Bots helping on this goal (0.9.66+), check-ins, pages, and close offers.
    public string? Lead { get; init; }
    public IReadOnlyList<string> Helpers { get; init; } = [];
    /// "ask" | "auto"
    public string Adds { get; init; } = "ask";
    public GoalReview? Review { get; init; }
    public bool KnownToAll { get; init; }
    public GoalStands? Stands { get; init; }
    public GoalCheckin? Checkin { get; init; }
    public TodoChat? Chat { get; init; }
    public string? PageAt { get; init; }
    public string? KeptAt { get; init; }
    public GoalDoneOffer? Offer { get; init; }
    public IReadOnlyList<TodoLogEntry> Log { get; init; } = [];
    /// The goal as the gateway sent it (unknown keys kept).
    public JsonObject Raw { get; init; } = [];

    public static Goal? From(JsonNode? n)
    {
        if (n is not JsonObject o || n.Str("id") is not { Length: > 0 } id) return null;
        return new Goal(id)
        {
            Rev = (int)(n.Int("rev") ?? 0),
            Title = n.Str("title") ?? "",
            Why = n.Str("why") ?? "",
            Status = n.Str("status") ?? "active",
            StatusAt = n.Str("status_at") is { Length: > 0 } sa ? sa : null,
            Color = n.Str("color") is { Length: > 0 } c ? c : null,
            Due = n.Str("due") is { Length: > 0 } d ? d : null,
            Position = n.Num("position") ?? 0,
            Measure = GoalMeasure.From(n.Get("measure")),
            Milestones = [.. (n.Arr("milestones") ?? []).Where(m => m is JsonObject).Select(GoalMilestone.From)],
            CreatedAt = n.Str("created_at"),
            UpdatedAt = n.Str("updated_at"),
            Lead = n.Text("lead"),
            Helpers = [.. (n.Arr("helpers") ?? []).Select(J.AsString).OfType<string>().Select(s => s.Trim()).Where(s => s.Length > 0).Distinct(StringComparer.Ordinal)],
            Adds = n.Text("adds") ?? "ask",
            Review = GoalReview.From(n.Get("review")),
            KnownToAll = n.Bool("known_to_all") ?? false,
            Stands = GoalStands.From(n.Get("stands")),
            Checkin = GoalCheckin.From(n.Get("checkin")),
            Chat = TodoChat.From(n.Get("chat")),
            PageAt = n.Text("page_at"),
            KeptAt = n.Text("kept_at"),
            Offer = GoalDoneOffer.From(n.Get("offer")),
            Log = [.. (n.Arr("log") ?? []).Select(TodoLogEntry.From).OfType<TodoLogEntry>()],
            Raw = (JsonObject)o.DeepClone(),
        };
    }

    public GoalState State => Status switch
    {
        "paused" => GoalState.Paused,
        "achieved" => GoalState.Achieved,
        "let_go" => GoalState.LetGo,
        _ => GoalState.Active,
    };

    /// All bots involved on the goal, lead first.
    public IReadOnlyList<string> Team => Lead == null ? Helpers : [Lead, .. Helpers.Where(h => h != Lead)];
    public bool HasBots => Lead != null || Helpers.Count > 0;

    /// Its colour: a list's colour name, blue when unknown (GoalModel.swift `tint`).
    public string Tint => Color is { } c && TodoListColors.All.Contains(c) ? c : "blue";

    /// Smallest first; an older goal with no position goes by when it was added.
    public double Order => Position != 0 ? Position : TodoDates.Moment(CreatedAt)?.ToUnixTimeMilliseconds() / 1000.0 ?? 0;

    public GoalMilestone? Milestone(string? id) => id == null ? null : Milestones.FirstOrDefault(m => m.Id == id);

    /// "Untitled Goal" for a goal with no name.
    public string Shown => Title.Length == 0 ? "Untitled Goal" : Title;
}

/// How a goal is doing against an even pace to its date (GoalViews.swift `GoalPace`).
public abstract record GoalPace
{
    public sealed record OnPace : GoalPace;
    public sealed record Ahead : GoalPace;
    public sealed record Behind(int Days) : GoalPace;
    public sealed record Late(int Days) : GoalPace;

    /// "on pace", "ahead", "3 days behind", "a week behind", "2 weeks behind", "3 days late".
    public string Words => this switch
    {
        OnPace => "on pace",
        Ahead => "ahead",
        Behind { Days: var d } when d < 7 => d == 1 ? "1 day behind" : $"{d} days behind",
        Behind { Days: < 14 } => "a week behind",
        Behind { Days: var d } => $"{d / 7} weeks behind",
        Late { Days: var d } => d == 1 ? "1 day late" : $"{d} days late",
        _ => "",
    };

    public GoalPaceTone Tone => this switch { Behind => GoalPaceTone.Behind, Late => GoalPaceTone.Late, _ => GoalPaceTone.Good };
}

public enum GoalPaceTone { Good, Behind, Late }

/// The Goals view's groups (TasksViewController.swift `GoalGroupKey`). `Found`: a search's Goals group (any status).
public enum GoalGroupKey { Active, Someday, Achieved, LetGo, Found }

/// The Goals view's groups, top to bottom (each only when it has a goal).
public sealed record GoalGroups(IReadOnlyList<Goal> Active, IReadOnlyList<Goal> Someday, IReadOnlyList<Goal> Achieved, IReadOnlyList<Goal> LetGo)
{
    public bool IsEmpty => Active.Count == 0 && Someday.Count == 0 && Achieved.Count == 0 && LetGo.Count == 0;

    /// The groups in order, each with its goals (the empty ones too).
    public IEnumerable<(GoalGroupKey Key, IReadOnlyList<Goal> Goals)> All()
    {
        yield return (GoalGroupKey.Active, Active);
        yield return (GoalGroupKey.Someday, Someday);
        yield return (GoalGroupKey.Achieved, Achieved);
        yield return (GoalGroupKey.LetGo, LetGo);
    }
}

internal static class GoalNumbers
{
    public static readonly CultureInfo En = CultureInfo.GetCultureInfo("en-US");
}

/// Wire helpers and optimistic 409 conflict resolution for `PATCH /goals/{id}` (`GoalWire` in `GoalModel.swift`).
public static class GoalWire
{
    public static JsonArray Milestones(IEnumerable<GoalMilestone> milestones) =>
        [.. milestones.Select(m => (JsonNode)m.Wire())];

    public static JsonObject CreateBody(string title, string why = "", string? due = null, GoalMeasure? measure = null,
        string? lead = null, IEnumerable<string>? helpers = null)
    {
        var o = new JsonObject { ["title"] = title.Trim() };
        if (why.Trim() is { Length: > 0 } reason) o["why"] = reason;
        if (due is { Length: > 0 }) o["due"] = due;
        if (measure != null) o["measure"] = measure.Wire();
        if (lead is { Length: > 0 }) o["lead"] = lead;
        if (helpers?.Where(h => !string.IsNullOrWhiteSpace(h)).Distinct(StringComparer.Ordinal).ToList() is { Count: > 0 } list)
            o["helpers"] = new JsonArray([.. list.Select(h => (JsonNode)h)]);
        return o;
    }

    public static Goal? Applying(JsonObject fields, Goal goal)
    {
        var o = (JsonObject)goal.Raw.DeepClone();
        if (o.Count == 0)
        {
            o["id"] = goal.Id;
            o["rev"] = goal.Rev;
            o["title"] = goal.Title;
            o["why"] = goal.Why;
            o["status"] = goal.Status;
        }
        foreach (var (key, value) in fields) o[key] = value?.DeepClone();
        return Goal.From(TodoEdits.Reparse(o));
    }

    public static string ValueOf(string key, Goal goal) => goal.Raw.Get(key)?.ToJsonString() ?? "null";

    /// Returns `current.Rev` to safely resend when the other edit touched disjoint fields; null when conflicting.
    public static int? Resolve(Goal @base, Goal current, JsonObject fields)
    {
        foreach (var (key, _) in fields)
            if (key != "rev" && ValueOf(key, @base) != ValueOf(key, current)) return null;
        return current.Rev;
    }
}
