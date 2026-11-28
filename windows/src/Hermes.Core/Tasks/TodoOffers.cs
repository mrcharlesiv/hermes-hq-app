using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hermes.Core.Tasks;

/// Proposed task inside a list or goal offer (`TodoOfferTask` in `HermesKit/Pages/Tasks/TodoLists.swift`).
public sealed record TodoOfferTask(
    string Title,
    string? Who = null,
    string? Bot = null,
    string? Due = null,
    string? Milestone = null,
    string? Notes = null,
    TodoFrom? Source = null)
{
    /// The bot it goes to, for a bot's task: its own `Bot`, else the offering bot.
    public string? BotFor(TodoOffer offer) => Who == "bot" ? (Bot ?? offer.Bot) : null;

    public static TodoOfferTask? From(JsonNode? n)
    {
        if (n is not JsonObject || n.Text("title") is not { } title) return null;
        return new TodoOfferTask(
            Title: title,
            Who: n.Text("who"),
            Bot: n.Text("bot"),
            Due: n.Text("due"),
            Milestone: n.Text("milestone"),
            Notes: n.Text("notes"),
            Source: TodoFrom.From(n.Get("source")));
    }
}

/// [goals step 3] A milestone a goal or plan offer would add (`GoalOfferMilestone` in `TodoLists.swift`).
public sealed record GoalOfferMilestone(string Title, string? Due = null)
{
    public static GoalOfferMilestone? From(JsonNode? n) =>
        n is JsonObject && n.Text("title") is { } title ? new GoalOfferMilestone(title, n.Text("due")) : null;
}

/// [goals step 3] The number a goal offer would give the new goal (`GoalOfferMeasure` in `TodoLists.swift`).
public sealed record GoalOfferMeasure(string Unit, double Start, double Target, double Now)
{
    public GoalOfferMeasure(string unit, double start, double target) : this(unit, start, target, start) { }

    public static GoalOfferMeasure? From(JsonNode? n)
    {
        if (n is not JsonObject || n.Num("target") is not { } target) return null;
        var start = n.Num("start") ?? 0;
        return new GoalOfferMeasure(n.Str("unit") ?? "", start, target, n.Num("now") ?? start);
    }
}

/// [goals set-up] What accepting a plan offer also sets on its goal (`setup` in `TodoLists.swift`):
/// only the keys the add-on kept (`name`, `why`, `due`, `measure`).
public sealed record GoalPlanSetup
{
    public string? Name { get; init; }
    public string? Why { get; init; }
    /// A day ("2027-01-31").
    public string? Due { get; init; }
    public GoalOfferMeasure? Measure { get; init; }
    /// Backwards-compatible fields populated on `TodoOffer.Plan` for UI views.
    public IReadOnlyList<GoalOfferMilestone> Milestones { get; init; } = [];
    public IReadOnlyList<TodoOfferTask> Tasks { get; init; } = [];
    public IReadOnlyList<string> BuiltOn { get; init; } = [];

    public GoalPlanSetup(
        string? name = null,
        string? why = null,
        string? due = null,
        GoalOfferMeasure? measure = null,
        IReadOnlyList<GoalOfferMilestone>? milestones = null,
        IReadOnlyList<TodoOfferTask>? tasks = null,
        IReadOnlyList<string>? builtOn = null)
    {
        Name = name;
        Why = why;
        Due = due;
        Measure = measure;
        Milestones = milestones ?? [];
        Tasks = tasks ?? [];
        BuiltOn = builtOn ?? [];
    }

    public bool IsEmpty => Name == null && Why == null && Due == null && Measure == null;

    public static GoalPlanSetup? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var name = n.Text("name") ?? n.Text("title");
        var why = n.Text("why");
        var rawDue = n.Text("due");
        var due = rawDue != null ? (rawDue.Length > 10 ? rawDue[..10] : rawDue) : null;
        var measure = GoalOfferMeasure.From(n.Get("measure"));
        if (name == null && why == null && due == null && measure == null)
            return null;
        return new GoalPlanSetup(name, why, due, measure);
    }
}

/// A task already on your page that an offer would move into the list (`TodoOfferMove` in `TodoLists.swift`).
public sealed record TodoOfferMove(string Id, string Title, string? FromSection = null, string? ToSection = null)
{
    /// Backwards-compatible alias.
    public string TaskId => Id;

    public static TodoOfferMove? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var id = n.Text("id") ?? n.Text("task_id");
        if (id == null) return null;
        return new TodoOfferMove(id, n.Str("title") ?? "", n.Text("from"), n.Text("to"));
    }
}

/// A bot's offer (`tasks_offer` / `goals_offer`; `TodoOffer` in `HermesKit/Pages/Tasks/TodoLists.swift`):
/// a list to make with tasks, tasks for a list that asks first, tasks to move into a list,
/// or a goal/plan/checkin/tasks offer. Nothing changes until you tap.
public sealed record TodoOffer(string Id)
{
    public string Bot { get; init; } = "default";
    public string? SessionId { get; init; }
    public string? At { get; init; }
    public string List { get; init; } = "";
    public string? Section { get; init; }
    public bool IsNew { get; init; } = true;
    public string Why { get; init; } = "";
    public IReadOnlyList<TodoOfferTask> Tasks { get; init; } = [];
    public IReadOnlyList<TodoOfferMove> Move { get; init; } = [];
    public string State { get; init; } = "new";
    public string? MoveState { get; init; }
    public bool? Listed { get; init; }
    public IReadOnlyList<string> Added { get; init; } = [];
    public string Kind { get; init; } = "list";
    public string? Goal { get; init; }
    public string Title { get; init; } = "";
    public string Summary { get; init; } = "";
    public string? Due { get; init; }
    public GoalOfferMeasure? Measure { get; init; }
    public IReadOnlyList<GoalOfferMilestone> Milestones { get; init; } = [];
    public string? AnsweredAt { get; init; }
    public string? MadeGoal { get; init; }
    public IReadOnlyList<string> MadeMilestones { get; init; } = [];
    public bool? WithPlan { get; init; }
    public bool? InGoal { get; init; }
    public IReadOnlyList<string> Kept { get; init; } = [];
    public bool Held { get; init; }
    public GoalPlanSetup? Setup { get; init; }
    public IReadOnlyList<string> BuiltOn { get; init; } = [];

    public bool IsGoal => Kind != "list";
    public bool IsWaiting => State == "new";
    public bool AsksMove => State == "accepted" && MoveState == "new" && Move.Count > 0 && Listed != false;
    public bool Undoable => State == "accepted";

    public string By => Bot;
    public string Status => State;
    public string? SectionId => Section;
    public string? GoalId => Goal;
    public bool IsGoalOffer => IsGoal;
    public IReadOnlyList<TodoOfferTask> AllTasks => Tasks;
    public IReadOnlyList<TodoOfferMove> AllMoves => Move;
    public IReadOnlyList<TodoOfferMove> Moves => Move;

    public GoalPlanSetup? Plan =>
        Setup != null
            ? Setup with
            {
                Milestones = Milestones.Count > 0 ? Milestones : Setup.Milestones,
                Tasks = Tasks.Count > 0 ? Tasks : Setup.Tasks,
                BuiltOn = BuiltOn.Count > 0 ? BuiltOn : Setup.BuiltOn,
            }
            : Kind == "plan" && (Milestones.Count > 0 || Tasks.Count > 0 || BuiltOn.Count > 0)
                ? new GoalPlanSetup(milestones: Milestones, tasks: Tasks, builtOn: BuiltOn)
                : null;

    public static TodoOffer? From(JsonNode? n)
    {
        if (n is not JsonObject || n.Text("id") is not { } id) return null;
        var section = n.Text("section");
        var kind = n.Text("kind") ?? "list";
        var list = n.Str("list") ?? "";
        var title = n.Text("title") ?? (kind == "list" ? "" : list);
        if (list.Length == 0) list = title;

        var builtOn = new List<string>();
        if (n.Arr("built_on") is { } rawBuiltOn)
        {
            foreach (var item in rawBuiltOn)
                if (item is JsonValue jv && jv.GetValueKind() == JsonValueKind.String && jv.TryGetValue(out string? s) && s != null)
                    builtOn.Add(s);
        }

        return new TodoOffer(id)
        {
            Bot = n.Text("bot") ?? "default",
            SessionId = n.Text("session_id"),
            At = n.Text("at"),
            List = list,
            Section = section,
            IsNew = n.Bool("new") ?? (section == null),
            Why = n.Str("why") ?? "",
            Tasks = [.. (n.Arr("tasks") ?? []).Select(TodoOfferTask.From).OfType<TodoOfferTask>()],
            Move = [.. (n.Arr("move") ?? n.Arr("moves") ?? []).Select(TodoOfferMove.From).OfType<TodoOfferMove>()],
            State = n.Text("state") ?? "new",
            MoveState = n.Text("move_state"),
            Listed = n.Bool("listed"),
            Added = [.. (n.Arr("added") ?? []).Select(J.AsString).OfType<string>().Where(s => s.Length > 0)],
            Kind = kind,
            Goal = n.Text("goal"),
            Title = title,
            Summary = n.Str("summary") ?? "",
            Due = n.Text("due"),
            Measure = GoalOfferMeasure.From(n.Get("measure")),
            Milestones = [.. (n.Arr("milestones") ?? []).Select(GoalOfferMilestone.From).OfType<GoalOfferMilestone>()],
            AnsweredAt = n.Text("answered_at"),
            MadeGoal = n.Text("made_goal"),
            MadeMilestones = [.. (n.Arr("made_milestones") ?? []).Select(J.AsString).OfType<string>().Where(s => s.Length > 0)],
            WithPlan = n.Bool("plan"),
            InGoal = n.Bool("in_goal"),
            Kept = [.. (n.Arr("kept") ?? []).Select(J.AsString).OfType<string>().Where(s => s.Length > 0)],
            Held = n.Bool("held") ?? false,
            Setup = GoalPlanSetup.From(n.Get("setup")),
            BuiltOn = builtOn,
        };
    }

    public JsonObject Wire()
    {
        var o = new JsonObject
        {
            ["id"] = Id,
            ["bot"] = Bot,
            ["list"] = List,
            ["new"] = IsNew,
            ["why"] = Why,
            ["state"] = State,
            ["kind"] = Kind,
            ["title"] = Title,
            ["summary"] = Summary,
            ["held"] = Held,
        };
        if (SessionId != null) o["session_id"] = SessionId;
        if (At != null) o["at"] = At;
        if (Section != null) o["section"] = Section;
        if (MoveState != null) o["move_state"] = MoveState;
        if (Listed is { } listed) o["listed"] = listed;
        if (Goal != null) o["goal"] = Goal;
        if (Due != null) o["due"] = Due;
        if (AnsweredAt != null) o["answered_at"] = AnsweredAt;
        if (MadeGoal != null) o["made_goal"] = MadeGoal;
        if (WithPlan is { } wp) o["plan"] = wp;
        if (InGoal is { } ig) o["in_goal"] = ig;
        if (Added.Count > 0) o["added"] = new JsonArray([.. Added.Select(x => (JsonNode)x)]);
        if (MadeMilestones.Count > 0) o["made_milestones"] = new JsonArray([.. MadeMilestones.Select(x => (JsonNode)x)]);
        if (Kept.Count > 0) o["kept"] = new JsonArray([.. Kept.Select(x => (JsonNode)x)]);
        if (BuiltOn.Count > 0) o["built_on"] = new JsonArray([.. BuiltOn.Select(x => (JsonNode)x)]);
        if (Tasks.Count > 0)
        {
            o["tasks"] = new JsonArray([.. Tasks.Select(t =>
            {
                var to = new JsonObject { ["title"] = t.Title };
                if (t.Who != null) to["who"] = t.Who;
                if (t.Bot != null) to["bot"] = t.Bot;
                if (t.Due != null) to["due"] = t.Due;
                if (t.Milestone != null) to["milestone"] = t.Milestone;
                if (t.Notes != null) to["notes"] = t.Notes;
                if (t.Source != null) to["source"] = t.Source.Wire();
                return (JsonNode)to;
            })]);
        }
        if (Move.Count > 0)
        {
            o["move"] = new JsonArray([.. Move.Select(m =>
            {
                var mo = new JsonObject { ["id"] = m.Id, ["title"] = m.Title };
                if (m.FromSection != null) mo["from"] = m.FromSection;
                if (m.ToSection != null) mo["to"] = m.ToSection;
                return (JsonNode)mo;
            })]);
        }
        if (Milestones.Count > 0)
        {
            o["milestones"] = new JsonArray([.. Milestones.Select(m =>
            {
                var mo = new JsonObject { ["title"] = m.Title };
                if (m.Due != null) mo["due"] = m.Due;
                return (JsonNode)mo;
            })]);
        }
        if (Measure is { } meas)
            o["measure"] = new JsonObject { ["unit"] = meas.Unit, ["start"] = meas.Start, ["target"] = meas.Target, ["now"] = meas.Now };
        if (Setup is { } setup)
        {
            var so = new JsonObject();
            if (setup.Name != null) so["name"] = setup.Name;
            if (setup.Why != null) so["why"] = setup.Why;
            if (setup.Due != null) so["due"] = setup.Due;
            if (setup.Measure is { } sm)
                so["measure"] = new JsonObject { ["unit"] = sm.Unit, ["start"] = sm.Start, ["target"] = sm.Target, ["now"] = sm.Now };
            o["setup"] = so;
        }
        return o;
    }
}

public enum TodoOfferAction
{
    Accept,
    AcceptNoList,
    AcceptNoPlan,
    AcceptJustTasks,
    Decline,
    Move,
    Leave,
    Undo,
}

public sealed record TodoOfferButton(
    TodoOfferAction Action,
    string Label,
    bool Primary = false,
    bool Destructive = false,
    bool MakesList = true,
    bool Plan = true,
    bool InGoal = true)
{
    public string WireAction => Action switch
    {
        TodoOfferAction.Accept or TodoOfferAction.AcceptNoList or TodoOfferAction.AcceptNoPlan or TodoOfferAction.AcceptJustTasks => "accept",
        TodoOfferAction.Decline => "decline",
        TodoOfferAction.Move => "move",
        TodoOfferAction.Leave => "leave",
        TodoOfferAction.Undo => "undo",
        _ => "accept",
    };

    public bool WireList => Action != TodoOfferAction.AcceptNoList && MakesList;
    public bool WirePlan => Action != TodoOfferAction.AcceptNoPlan && Plan;
    public bool WireInGoal => Action != TodoOfferAction.AcceptJustTasks && InGoal;
}

/// Answer from `POST /tasks/offers/{id}` (`TodoOfferAnswer` in `TasksStore.swift`).
public sealed record TodoOfferAnswer
{
    public int Rev { get; init; }
    public TodoOffer? Offer { get; init; }
    public IReadOnlyList<TodoUserSection> Sections { get; init; } = [];
    public bool HasSections { get; init; }
    public IReadOnlyList<Goal>? Goals { get; init; }
    public IReadOnlyList<TodoTask> AddedTasks { get; init; } = [];
    public Goal? UpdatedGoal { get; init; }

    public TodoOfferAnswer(
        int rev = 0,
        TodoOffer? offer = null,
        IReadOnlyList<TodoUserSection>? sections = null,
        IReadOnlyList<Goal>? goals = null,
        IReadOnlyList<TodoTask>? addedTasks = null,
        Goal? updatedGoal = null,
        bool hasSections = false)
    {
        Rev = rev;
        Offer = offer;
        Sections = sections ?? [];
        HasSections = hasSections || sections != null;
        Goals = goals;
        AddedTasks = addedTasks ?? [];
        UpdatedGoal = updatedGoal;
    }

    public static TodoOfferAnswer From(JsonNode? n)
    {
        var rawSections = n.Arr("sections");
        var rawGoals = n.Arr("goals");
        return new TodoOfferAnswer(
            rev: (int)(n.Int("rev") ?? 0),
            offer: TodoOffer.From(n.Get("offer")),
            sections: rawSections?.Select(TodoUserSection.From).OfType<TodoUserSection>().ToList(),
            goals: rawGoals?.Select(Goal.From).OfType<Goal>().ToList(),
            addedTasks: [.. (n.Arr("tasks") ?? []).Select(TodoTask.From).OfType<TodoTask>()],
            updatedGoal: Goal.From(n.Get("goal")),
            hasSections: rawSections != null);
    }
}

/// Presentation & action rules for Offers (`TodoLists.swift` / `GoalBots.swift`).
public static class TodoOfferRules
{
    public static IReadOnlyList<TodoOffer> Waiting(IEnumerable<TodoOffer> offers) =>
        [.. offers.Where(o => !o.Held && (o.IsWaiting || o.AsksMove))];

    public static string Count(int n) => n == 1 ? "1 task" : $"{n} tasks";

    public static string OfferTitle(TodoOffer offer, Func<string?, string> botName)
    {
        if (!string.IsNullOrWhiteSpace(offer.Title)) return offer.Title;
        var who = botName(offer.Bot);
        if (!offer.IsGoal)
        {
            if (offer.AsksMove) return $"Move {Count(offer.Move.Count)} to {offer.List}?";
            if (offer.IsNew && !string.IsNullOrWhiteSpace(offer.List)) return $"{who} suggests a {offer.List} list";
            if (offer.Tasks.Count == 0 && offer.Move.Count > 0) return $"{who} would move {Count(offer.Move.Count)} to {offer.List}";
            if (!string.IsNullOrWhiteSpace(offer.List)) return $"{who} has {Count(offer.Tasks.Count)} for {offer.List}";
            return $"{who} suggested tasks for your list";
        }
        return offer.Kind switch
        {
            "goal" => $"{who} suggested a goal",
            "plan" => $"{who} drafted a setup plan",
            "checkin" => $"{who} checked in on your goal",
            _ => $"{who} suggested {Count(offer.Tasks.Count)}",
        };
    }

    public static IReadOnlyList<TodoOfferButton> OfferButtons(TodoOffer offer)
    {
        if (offer.AsksMove)
        {
            return
            [
                new TodoOfferButton(TodoOfferAction.Move, $"Move {offer.Move.Count} to {offer.List}", Primary: true),
                new TodoOfferButton(TodoOfferAction.Leave, "Leave Them"),
            ];
        }

        if (!offer.IsWaiting)
        {
            return offer.Undoable
                ? [new TodoOfferButton(TodoOfferAction.Undo, "Undo")]
                : [];
        }

        if (!offer.IsGoal)
        {
            var n = offer.Tasks.Count;
            if (offer.IsNew)
            {
                var make = n > 0
                    ? (string.IsNullOrWhiteSpace(offer.List) ? $"Add {n}" : $"Make {offer.List} & Add {n}")
                    : (string.IsNullOrWhiteSpace(offer.List) ? "Make List" : $"Make {offer.List}");
                var list = new List<TodoOfferButton> { new(TodoOfferAction.Accept, make, Primary: true) };
                if (n > 0) list.Add(new TodoOfferButton(TodoOfferAction.AcceptNoList, "Add, No List", MakesList: false));
                list.Add(new TodoOfferButton(TodoOfferAction.Decline, "Not Now", Destructive: true));
                return list;
            }
            if (n == 0 && offer.Move.Count > 0)
            {
                return
                [
                    new TodoOfferButton(TodoOfferAction.Accept, $"Move {offer.Move.Count} to {offer.List}", Primary: true),
                    new TodoOfferButton(TodoOfferAction.Decline, "Leave Them", Destructive: true),
                ];
            }
            return
            [
                new TodoOfferButton(TodoOfferAction.Accept, string.IsNullOrWhiteSpace(offer.List) ? $"Add {n}" : $"Add {n} to {offer.List}", Primary: true),
                new TodoOfferButton(TodoOfferAction.Decline, "Not Now", Destructive: true),
            ];
        }

        var hasPlan = offer.Milestones.Count > 0 || offer.Tasks.Count > 0;
        return offer.Kind switch
        {
            "goal" when hasPlan =>
            [
                new TodoOfferButton(TodoOfferAction.Accept, "Make This Goal", Primary: true),
                new TodoOfferButton(TodoOfferAction.AcceptNoPlan, "Keep the Goal, No Plan", Plan: false),
                new TodoOfferButton(TodoOfferAction.Decline, "Not Now", Destructive: true),
            ],
            "goal" =>
            [
                new TodoOfferButton(TodoOfferAction.Accept, "Make This Goal", Primary: true),
                new TodoOfferButton(TodoOfferAction.Decline, "Not Now", Destructive: true),
            ],
            "plan" =>
            [
                new TodoOfferButton(TodoOfferAction.Accept, "Use This Plan", Primary: true),
                new TodoOfferButton(TodoOfferAction.AcceptNoPlan, "Keep the Goal, No Plan", Plan: false),
            ],
            "checkin" =>
            [
                new TodoOfferButton(TodoOfferAction.Accept, offer.Tasks.Count == 0 ? "Got It" : $"Add These {offer.Tasks.Count}", Primary: true),
                new TodoOfferButton(TodoOfferAction.Decline, "Not Now", Destructive: true),
            ],
            _ =>
            [
                new TodoOfferButton(TodoOfferAction.Accept, "Add to Goal", Primary: true),
                new TodoOfferButton(TodoOfferAction.AcceptJustTasks, "Just Tasks", InGoal: false),
                new TodoOfferButton(TodoOfferAction.Decline, "No", Destructive: true),
            ],
        };
    }

    public static string DoneLabel(TodoOffer offer) => offer.State switch
    {
        "accepted" => "Accepted",
        "declined" => offer.Kind == "plan" ? "Kept the goal, no plan" : "Not now",
        "undone" => offer.Kept.Count > 0 ? "Undone, except what you changed" : "Undone",
        _ => "",
    };
}

/// Thread-safe snapshot of the Tasks store's close-card state (`TodoTaskStates` in `HermesKit/Pages/Tasks/TodoCloseCards.swift`,
/// commit `c37d7ddad`): read by chat close cards off or on the UI thread, updated whenever the Tasks store changes.
public static class TodoTaskStates
{
    public sealed record Entry(bool Done, TodoCloseOffer? Offer);

    public sealed record Snapshot(
        IReadOnlyDictionary<string, Entry> Tasks,
        bool Read,
        bool ReadOnly,
        IReadOnlySet<string> Reopened)
    {
        public static readonly Snapshot Empty = new(
            new Dictionary<string, Entry>(StringComparer.Ordinal),
            Read: false,
            ReadOnly: false,
            Reopened: new HashSet<string>(StringComparer.Ordinal));

        public bool StructurallyEquals(Snapshot other)
        {
            if (Read != other.Read || ReadOnly != other.ReadOnly) return false;
            if (Tasks.Count != other.Tasks.Count || Reopened.Count != other.Reopened.Count) return false;
            if (!Reopened.SetEquals(other.Reopened)) return false;
            foreach (var (k, v) in Tasks)
                if (!other.Tasks.TryGetValue(k, out var ov) || v != ov) return false;
            return true;
        }
    }

    private static readonly Lock Gate = new();
    private static Snapshot _snapshot = Snapshot.Empty;
    private static readonly HashSet<string> Asked = new(StringComparer.Ordinal);

    /// A task changed in a way a close card shows (done, its offer, gone), or the gateway list was read.
    public static event Action? Changed;

    /// A chat's close card names a task the store hasn't read yet (or an offer newer than what it has).
    public static event Action<string>? Wanted;

    public static Snapshot GetSnapshot()
    {
        lock (Gate) return _snapshot;
    }

    /// The store's list changed (optimistic edit, read, or save).
    public static void Note(IReadOnlyList<TodoTask> tasks)
    {
        var next = new Dictionary<string, Entry>(tasks.Count, StringComparer.Ordinal);
        foreach (var t in tasks)
            next.TryAdd(t.Id, new Entry(t.IsDone, t.Offer));
        Update(s => s with { Tasks = next });
    }

    /// The gateway's list was read (not just disk cache).
    public static void NoteRead() => Update(s => s with { Read = true });

    public static void NoteReadOnly(bool readOnly) => Update(s => s with { ReadOnly = readOnly });

    /// A card's Undo opened the task again this run.
    public static void NoteReopened(string id)
    {
        if (string.IsNullOrEmpty(id)) return;
        Update(s =>
        {
            if (s.Reopened.Contains(id)) return s;
            var next = new HashSet<string>(s.Reopened, StringComparer.Ordinal) { id };
            return s with { Reopened = next };
        });
    }

    /// Signed out, or the store let its list go.
    public static void Forget()
    {
        bool moved;
        lock (Gate)
        {
            moved = !_snapshot.StructurallyEquals(Snapshot.Empty);
            _snapshot = Snapshot.Empty;
            Asked.Clear();
        }
        if (moved) Changed?.Invoke();
    }

    /// A chat card references a task the store hasn't read (or a newer offer): requests refresh once per `(id, at)`.
    public static void Want(string id, string? at = null)
    {
        if (string.IsNullOrEmpty(id)) return;
        var key = id + "|" + (at ?? "");
        bool fire;
        lock (Gate) fire = Asked.Add(key);
        if (fire) Wanted?.Invoke(id);
    }

    private static void Update(Func<Snapshot, Snapshot> change)
    {
        bool moved;
        lock (Gate)
        {
            var next = change(_snapshot);
            moved = !next.StructurallyEquals(_snapshot);
            if (moved) _snapshot = next;
        }
        if (moved) Changed?.Invoke();
    }
}

/// Close-offer card state machine (`HermesKit/Pages/Tasks/TodoCloseCards.swift`, commit `c37d7ddad`).
public enum TodoCloseCardState
{
    Waiting,
    Done,
    Reopened,
    Kept,
    Gone,
    Settled,
}

public enum TodoCloseCardAction
{
    MarkDone,
    KeepOpen,
    Reopen,
}

/// Resolved state of a chat Mark Done card (`State` plus whether Undo is offered when Done).
public sealed record TodoCloseCardResolution(TodoCloseCardState State, bool Undo = false);

/// Parsed payload from a `tasks_update` tool call carrying `offer_done` or `status: "done"` with `asked: true`.
public sealed record TodoCloseCardToolPayload(
    string TaskId,
    string Title,
    bool Asked,
    TodoCloseOffer? Offer,
    string Bot);

public static class TodoCloseCards
{
    /// Every line the foot can say (measured for uniform height so the card never jumps).
    public static readonly IReadOnlyList<string> AllWords =
        ["Marked Done", "Back on the list", "Kept Open", "No longer on your list", "Still open"];

    /// Simple single-task state helper (kept for existing callers and tests).
    public static TodoCloseCardState StateOf(TodoTask? task, bool locallyMarkedDone = false, bool locallyKept = false, bool locallyReopened = false)
    {
        if (task == null) return TodoCloseCardState.Gone;
        if (locallyReopened && !task.IsDone) return TodoCloseCardState.Reopened;
        if (task.IsDone) return locallyMarkedDone ? TodoCloseCardState.Done : TodoCloseCardState.Settled;
        if (locallyKept || task.Offer is { Kept: true }) return TodoCloseCardState.Kept;
        if (task.Offer is { Kept: false }) return TodoCloseCardState.Waiting;
        return TodoCloseCardState.Settled;
    }

    /// Full chat close-card state (`TodoCloseCards.state(asked:offer:id:newest:in:)` in `TodoCloseCards.swift`).
    /// Returns null while the store hasn't read the task from the gateway yet (so buttons don't flash and vanish).
    public static TodoCloseCardResolution? State(
        bool asked,
        TodoCloseOffer? offer,
        string id,
        bool newest,
        TodoTaskStates.Snapshot snapshot)
    {
        if (!snapshot.Tasks.TryGetValue(id, out var task))
            return snapshot.Read ? new TodoCloseCardResolution(TodoCloseCardState.Gone) : null;
        if (task.Done)
            return new TodoCloseCardResolution(TodoCloseCardState.Done, Undo: newest && !snapshot.ReadOnly);
        if (asked)
            return new TodoCloseCardResolution(TodoCloseCardState.Reopened);
        if (task.Offer is { Kept: true })
            return new TodoCloseCardResolution(TodoCloseCardState.Kept);
        if (!newest)
            return new TodoCloseCardResolution(TodoCloseCardState.Settled);
        if (task.Offer is not { } live)
            return new TodoCloseCardResolution(snapshot.Reopened.Contains(id) ? TodoCloseCardState.Reopened : TodoCloseCardState.Settled);
        if (Newer(live.At, offer?.At))
            return new TodoCloseCardResolution(TodoCloseCardState.Settled);
        return new TodoCloseCardResolution(TodoCloseCardState.Waiting);
    }

    /// The quiet words shown in place of the buttons; null while the offer waits.
    public static string? Words(TodoCloseCardState state) => state switch
    {
        TodoCloseCardState.Waiting => null,
        TodoCloseCardState.Done => "Marked Done",
        TodoCloseCardState.Reopened => "Back on the list",
        TodoCloseCardState.Kept => "Kept Open",
        TodoCloseCardState.Gone => "No longer on your list",
        TodoCloseCardState.Settled => "Still open",
        _ => null,
    };

    public static string? Words(TodoCloseCardResolution resolution) => Words(resolution.State);

    /// Whether ISO moment `a` is strictly later than `b` (false when either is missing or unreadable).
    public static bool Newer(string? a, string? b) =>
        TodoDates.Moment(a) is { } ma && TodoDates.Moment(b) is { } mb && ma > mb;

    /// Extracts a chat Mark Done card from a `tasks_update` tool call (`offer_done` or `status: "done"` with `asked: true`).
    public static TodoCloseCardToolPayload? FromTasksUpdate(JsonNode? args, JsonNode? result, string defaultBot = "default")
    {
        var task = result?.Get("task") as JsonObject ?? result as JsonObject;
        var id = task.Text("id") ?? args.Text("id") ?? args.Text("task_id");
        if (string.IsNullOrEmpty(id)) return null;

        var title = task.Text("title") ?? args.Text("title") ?? TasksCopy.Untitled;
        var bot = task.Text("bot") ?? args.Text("bot") ?? defaultBot;

        // 1) Bot offered to close (`offer_done` arg or `offer` in returned task).
        var offerText = args.Text("offer_done") ?? args.Obj("offer_done")?.Text("text");
        var rawOffer = task?.Obj("offer");
        if (offerText != null || rawOffer != null)
        {
            var offer = rawOffer != null
                ? new TodoCloseOffer(rawOffer.Text("by") ?? bot, rawOffer.Str("text") ?? offerText ?? "", rawOffer.Text("at"), rawOffer.Bool("kept") ?? false)
                : new TodoCloseOffer(bot, offerText ?? "", task.Text("updated_at"), Kept: false);
            return new TodoCloseCardToolPayload(id, title, Asked: false, offer, offer.By);
        }

        // 2) User asked the bot to close it (`status: "done"` + `asked: true`).
        var status = args.Text("status") ?? task.Text("status");
        var asked = args.Bool("asked") == true || result.Bool("asked") == true;
        if (status == "done" && asked)
            return new TodoCloseCardToolPayload(id, title, Asked: true, Offer: null, bot);

        return null;
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
