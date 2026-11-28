using System.Globalization;
using System.Text.Json.Nodes;

namespace Hermes.Core.Tasks;

// [goals] What your tasks are for (docs/goals.md; HermesKit/Pages/Goals/GoalModel.swift). The hermes-hq-push
// add-on keeps goals beside the list (0.9.65's `goals` in `GET /tasks`, 0.9.66's bots on goals); the app draws them.
// Read leniently, as a task is: an unknown status or colour, or a field missing, never loses the goal, and one bad
// goal never loses the list.

/// Where a goal stands. An unknown status (a later add-on's) reads as active, so the goal still shows.
public enum GoalState { Active, Paused, Achieved, LetGo }

/// [goals step 3] Who reads the goal's number (hermes-hq-push 0.9.66): you, or one bot and what it reads
/// ("TestFlight public testers"). On the wire `"you"` or `{bot, what}`; anything else reads as you.
public sealed record GoalSource(string? Bot = null, string What = "")
{
    public static readonly GoalSource You = new(null, "");
    public bool IsYou => string.IsNullOrEmpty(Bot);

    public static GoalSource BotSource(string bot, string what = "") =>
        string.IsNullOrWhiteSpace(bot) ? You : new GoalSource(bot.Trim(), what ?? "");

    public static GoalSource From(JsonNode? n)
    {
        if (n is JsonObject o && o.Text("bot") is { } bot)
            return new GoalSource(bot, o.Str("what") ?? "");
        return You;
    }

    /// Wire form (`GoalSource.json`): `"you"` or `{"bot": ..., "what": ...}`.
    public JsonNode Wire() =>
        IsYou ? JsonValue.Create("you")! : new JsonObject { ["bot"] = Bot, ["what"] = What };
}

/// One historical reading on a goal's measure (`GoalReading` in `GoalModel.swift`).
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

/// [goals step 4] The weekly check-in's slot: a weekday (0 = Monday … 6 = Sunday) and a time ("08:00"),
/// in the gateway's own time (`GoalReview` in `GoalModel.swift`).
public sealed record GoalReview(int Day = 0, string Time = "08:00")
{
    public static GoalReview? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        if (n.Int("day") is not { } rawDay || rawDay is < 0 or > 6) return null;
        if (n.Str("time") is not { } time || !IsValidTime(time)) return null;
        return new GoalReview((int)rawDay, time);
    }

    private static bool IsValidTime(string raw)
    {
        var colon = raw.IndexOf(':');
        if (colon is not (1 or 2) || raw.Length != colon + 3) return false;
        for (var i = 0; i < raw.Length; i++)
            if (i != colon && !char.IsAsciiDigit(raw[i])) return false;
        return true;
    }

    public JsonObject Wire() => new() { ["day"] = Day, ["time"] = Time };
}

/// [goals step 3] The lead's "where it stands": its words and what is next (`GoalStands` in `GoalModel.swift`).
public sealed record GoalStands(string Text, string Next = "", string? At = null, string By = "default")
{
    /// Backwards-compatible alias for existing UI callers (Wave 5 updates GoalDetailPane).
    public string Summary => Text;

    public static GoalStands? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        return new GoalStands(
            Text: n.Str("text") ?? n.Str("summary") ?? "",
            Next: n.Str("next") ?? "",
            At: n.Text("at"),
            By: n.Text("by") ?? "default");
    }

    public JsonObject Wire()
    {
        var o = new JsonObject { ["by"] = By, ["text"] = Text, ["next"] = Next };
        if (At != null) o["at"] = At;
        return o;
    }
}

/// [goals step 4] The last check-in: when, its offer, and what became of it (`GoalCheckin` in `GoalModel.swift`).
public sealed record GoalCheckin(string? At = null, string? Offer = null, string State = "offered")
{
    /// Backwards-compatible properties for legacy UI callers (Wave 5 updates GoalDetailPane).
    public string Summary { get; init; } = "";
    public string? By { get; init; }

    public static GoalCheckin? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        return new GoalCheckin(
            At: n.Text("at"),
            Offer: n.Text("offer"),
            State: n.Text("state") ?? "none")
        {
            Summary = n.Str("summary") ?? "",
            By = n.Text("by"),
        };
    }

    public JsonObject Wire()
    {
        var o = new JsonObject { ["state"] = State };
        if (At != null) o["at"] = At;
        if (Offer != null) o["offer"] = Offer;
        return o;
    }
}

/// [goals step 4] The lead says a milestone, or the goal, looks done (`goals_update looks_done`).
/// You answer Mark Done or Not Yet (`PATCH offer_answer`); after Not Yet it stays on the goal with `kept`.
public sealed record GoalDoneOffer(
    string What,
    string By,
    string Text,
    string? At = null,
    bool Kept = false,
    string Kind = "done",
    string? KeptAt = null)
{
    public static GoalDoneOffer? From(JsonNode? n)
    {
        if (n is not JsonObject || n.Text("what") is not { } what) return null;
        return new GoalDoneOffer(
            What: what,
            By: n.Text("by") ?? "default",
            Text: n.Str("text") ?? "",
            At: n.Text("at"),
            Kept: n.Bool("kept") ?? false,
            Kind: n.Text("kind") ?? "done",
            KeptAt: n.Text("kept_at"));
    }

    public JsonObject Wire()
    {
        var o = new JsonObject
        {
            ["kind"] = Kind,
            ["what"] = What,
            ["by"] = By,
            ["text"] = Text,
            ["kept"] = Kept,
        };
        if (At != null) o["at"] = At;
        if (KeptAt != null) o["kept_at"] = KeptAt;
        return o;
    }
}

/// The goal's number: "340 of 1,000 testers". A target below the start counts down.
public sealed record GoalMeasure(string Unit, double Start, double Target, double Now)
{
    public string? At { get; init; }
    public GoalSource? Source { get; init; } = GoalSource.You;
    public string? CheckedAt { get; init; }
    public IReadOnlyList<GoalReading> History { get; init; } = [];

    public GoalSource EffectiveSource => Source ?? GoalSource.You;

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
            ["title"] = Title,
            ["due"] = Due,
            ["done"] = Done,
        };
        if (!string.IsNullOrEmpty(Id) && !TodoIds.IsLocal(Id)) o["id"] = Id;
        if (DoneAt != null) o["done_at"] = DoneAt;
        return o;
    }
}

/// One goal, as the routes send it (`Goal` in `GoalModel.swift`).
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
    /// Tell My Other Bots: every bot knows its name and why (defaults to true per GoalModel.swift).
    public bool KnownToAll { get; init; } = true;
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
        var lead = n.Text("lead");
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
            Milestones = [.. (n.Arr("milestones") ?? []).Where(m => m is JsonObject).Select(GoalMilestone.From).Where(m => m.Id.Length > 0)],
            CreatedAt = n.Str("created_at"),
            UpdatedAt = n.Str("updated_at"),
            Lead = lead,
            Helpers = [.. (n.Arr("helpers") ?? []).Select(J.AsString).OfType<string>().Select(s => s.Trim()).Where(s => s.Length > 0 && s != lead).Distinct(StringComparer.Ordinal)],
            Adds = n.Text("adds") == "auto" ? "auto" : "ask",
            Review = GoalReview.From(n.Get("review")),
            KnownToAll = n.Bool("known_to_all") ?? true,
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

/// Wire helpers and optimistic 409 conflict resolution for `POST/PATCH /goals` (`GoalWire` in `GoalModel.swift`).
public static class GoalWire
{
    /// [goals steps 3-5] All team fields on a goal.
    public static readonly IReadOnlySet<string> TeamKeys =
        new HashSet<string>(["lead", "helpers", "adds", "review", "known_to_all", "chat"], StringComparer.Ordinal);

    /// [goals set-up] Team fields accepted directly on `POST /goals` (one write, one "Added" log entry).
    public static readonly IReadOnlySet<string> CreateTeamKeys =
        new HashSet<string>(["lead", "helpers", "adds", "review"], StringComparer.Ordinal);

    /// What `AddGoalAsync` sends in `POST /goals`: everything except team fields the create route does not take.
    public static JsonObject CreateBody(JsonObject fields)
    {
        var body = new JsonObject();
        foreach (var (key, value) in fields)
            if (!TeamKeys.Contains(key) || CreateTeamKeys.Contains(key))
                body[key] = value?.DeepClone();
        return body;
    }

    /// The team fields still to PATCH once the goal is made: ones POST never takes (`known_to_all`, `chat`),
    /// and any POST was sent that `made` doesn't carry (an older add-on ignores them). Empty when POST took them all.
    public static JsonObject TeamLeft(JsonObject fields, Goal made)
    {
        var left = new JsonObject();
        foreach (var (key, value) in fields)
        {
            if (!TeamKeys.Contains(key)) continue;
            switch (key)
            {
                case "lead":
                    var sentLead = J.AsString(value)?.Trim() is { Length: > 0 } sl ? sl : null;
                    if (!string.Equals(made.Lead, sentLead, StringComparison.Ordinal)) left[key] = value?.DeepClone();
                    break;
                case "helpers":
                    var leadName = fields.Text("lead") ?? made.Lead;
                    var sentHelpers = (value as JsonArray ?? [])
                        .Select(J.AsString).OfType<string>()
                        .Select(s => s.Trim())
                        .Where(s => s.Length > 0 && !string.Equals(s, leadName, StringComparison.Ordinal))
                        .ToList();
                    if (!made.Helpers.SequenceEqual(sentHelpers, StringComparer.Ordinal)) left[key] = value?.DeepClone();
                    break;
                case "adds":
                    var sentAdds = J.AsString(value);
                    if (!string.Equals(made.Adds, sentAdds, StringComparison.Ordinal)) left[key] = value?.DeepClone();
                    break;
                case "review":
                    var sentReview = GoalReview.From(value);
                    if (made.Review != sentReview) left[key] = value?.DeepClone();
                    break;
                default:
                    // known_to_all, chat: POST never takes them.
                    left[key] = value?.DeepClone();
                    break;
            }
        }
        // A lead given again brings its helpers with it (the PATCH that sets a lead keeps them as sent).
        if (left.ContainsKey("lead") && fields.TryGetPropertyValue("helpers", out var helpersVal))
            left["helpers"] = helpersVal?.DeepClone();
        return left;
    }

    /// `measure`: unit, start, target, and now (`GoalWire.measure`).
    public static JsonObject Measure(GoalMeasure measure) => new()
    {
        ["unit"] = measure.Unit,
        ["start"] = measure.Start,
        ["target"] = measure.Target,
        ["now"] = measure.Now,
    };

    public static JsonArray Milestones(IEnumerable<GoalMilestone> milestones) =>
        [.. milestones.Select(m => (JsonNode)m.Wire())];

    public static JsonObject CreateBody(
        string title,
        string why = "",
        string? due = null,
        GoalMeasure? measure = null,
        string? lead = null,
        IEnumerable<string>? helpers = null,
        string? adds = null,
        GoalReview? review = null,
        bool? knownToAll = null,
        string? color = null,
        IEnumerable<GoalMilestone>? milestones = null)
    {
        var o = new JsonObject { ["title"] = title.Trim() };
        if (why.Trim() is { Length: > 0 } reason) o["why"] = reason;
        if (due is { Length: > 0 }) o["due"] = due;
        if (color is { Length: > 0 }) o["color"] = color;
        if (measure != null) o["measure"] = Measure(measure);
        var msList = milestones?.ToList();
        if (msList is { Count: > 0 }) o["milestones"] = Milestones(msList);
        var cleanLead = lead?.Trim() is { Length: > 0 } l ? l : null;
        if (cleanLead != null) o["lead"] = cleanLead;
        if (helpers?.Select(h => h.Trim()).Where(h => h.Length > 0 && h != cleanLead).Distinct(StringComparer.Ordinal).ToList() is { Count: > 0 } list)
            o["helpers"] = new JsonArray([.. list.Select(h => (JsonNode)h)]);
        if (adds is "ask" or "auto") o["adds"] = adds;
        if (review != null) o["review"] = review.Wire();
        if (knownToAll is { } k) o["known_to_all"] = k;
        return o;
    }

    public static Goal? Applying(JsonObject fields, Goal goal, DateTimeOffset? now = null)
    {
        var stamp = TodoDates.Now(now);
        var o = (JsonObject)goal.Raw.DeepClone();
        if (o.Count == 0)
        {
            o["id"] = goal.Id;
            o["rev"] = goal.Rev;
            o["title"] = goal.Title;
            o["why"] = goal.Why;
            o["status"] = goal.Status;
            if (goal.Offer != null) o["offer"] = goal.Offer.Wire();
            if (goal.Measure != null) o["measure"] = goal.Measure.Wire();
            if (goal.Milestones.Count > 0) o["milestones"] = Milestones(goal.Milestones);
        }
        foreach (var (key, value) in fields)
        {
            switch (key)
            {
                case "keep":
                    if (J.Bool(fields, "keep") == true) o["kept_at"] = stamp;
                    break;
                case "offer_answer":
                    if (J.AsString(value) is { } ans && goal.Offer is { Kept: false } offer)
                    {
                        if (ans == "keep")
                        {
                            o["offer"] = (offer with { Kept = true, KeptAt = stamp }).Wire();
                        }
                        else if (ans == "done")
                        {
                            if (offer.What == "goal")
                            {
                                o["status"] = "achieved";
                                o["status_at"] = stamp;
                            }
                            else
                            {
                                var updated = goal.Milestones.Select(m => m.Id == offer.What && !m.Done ? m with { Done = true, DoneAt = stamp } : m);
                                o["milestones"] = Milestones(updated);
                            }
                            o["offer"] = null;
                        }
                    }
                    break;
                case "measure_now":
                    if (fields.Num("measure_now") is { } num && goal.Measure is { } m)
                    {
                        var next = num != m.Now
                            ? m with { Now = num, At = stamp, History = [.. m.History.Append(new GoalReading(num, stamp)).TakeLast(60)] }
                            : m;
                        o["measure"] = next.Wire();
                    }
                    break;
                default:
                    o[key] = value?.DeepClone();
                    break;
            }
        }
        o["updated_at"] = stamp;
        return Goal.From(TodoEdits.Reparse(o));
    }

    public static string ValueOf(string key, Goal goal)
    {
        if (key == "measure_now") return goal.Measure != null ? JsonValue.Create(goal.Measure.Now)!.ToJsonString() : "null";
        if (key is "keep" or "offer_answer") return "null";
        return goal.Raw.Get(key)?.ToJsonString() ?? "null";
    }

    /// Returns `current.Rev` to safely resend when the other edit touched disjoint fields; null when conflicting.
    public static int? Resolve(Goal @base, Goal current, JsonObject fields)
    {
        foreach (var (key, _) in fields)
            if (key != "rev" && ValueOf(key, @base) != ValueOf(key, current)) return null;
        return current.Rev;
    }
}
