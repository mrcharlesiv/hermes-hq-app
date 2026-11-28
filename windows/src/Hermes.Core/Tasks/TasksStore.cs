using System.Globalization;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Kanban;
using Hermes.Core.Net;

namespace Hermes.Core.Tasks;

/// The add-on's routes (`HermesKit/Pages/Tasks/TasksStore.swift` `TasksAPI`; `docs/tasks.md` "Routes").
public sealed class TasksApi(IPagesRest rest)
{
    public const string Route = "/api/plugins/hermes-hq-push";
    public const string Base = Route + "/tasks";
    public IPagesRest Rest { get; } = rest;

    private static string PathOf(string id) => Base + "/" + KanbanRest.Segment(id);

    public async Task<TodoListAnswer> ListAsync(int? since, CancellationToken ct = default) =>
        TodoListAnswer.From(await Rest.JsonAsync(HttpMethod.Get, Base, since is { } s ? [new("since", s.ToString(CultureInfo.InvariantCulture))] : null, ct: ct));

    public async Task<TodoTask> CreateAsync(JsonObject fields, CancellationToken ct = default) =>
        TaskOf(await Rest.JsonAsync(HttpMethod.Post, Base, body: fields, ct: ct));

    public async Task<TodoTask> PatchAsync(string id, int rev, JsonObject fields, CancellationToken ct = default)
    {
        var body = (JsonObject)fields.DeepClone();
        body["rev"] = rev;
        return TaskOf(await Rest.JsonAsync(HttpMethod.Patch, PathOf(id), body: body, ct: ct));
    }

    public Task DeleteAsync(string id, CancellationToken ct = default) => Rest.JsonAsync(HttpMethod.Delete, PathOf(id), ct: ct);

    /// `PUT /tasks/settings` with the whole settings; the gateway's answer, or what was sent when it can't be read.
    public async Task<TodoSettings> SaveSettingsAsync(TodoSettings settings, CancellationToken ct = default) =>
        await Rest.JsonAsync(HttpMethod.Put, Base + "/settings", body: settings.Wire(), ct: ct) is JsonObject answer ? TodoSettings.From(answer) : settings;

    /// `PUT /tasks/sections`: your lists, the whole list in order. One left out is deleted; its tasks stay, in no list.
    public async Task<IReadOnlyList<TodoUserSection>> SaveSectionsAsync(IReadOnlyList<TodoUserSection> sections, CancellationToken ct = default)
    {
        var answer = await Rest.JsonAsync(HttpMethod.Put, Base + "/sections",
            body: new JsonObject { ["sections"] = new JsonArray([.. sections.Select(s => (JsonNode)s.Wire())]) }, ct: ct);
        return answer.Arr("sections") is { } saved ? [.. saved.Select(TodoUserSection.From).OfType<TodoUserSection>()]
            : throw new PagesMessageException("The gateway sent lists this app can’t read.");
    }

    /// `POST /tasks/prep-job/{profile}`: reconciles that bot's "Task prep" scheduled job to match its open prep tasks.
    public async Task<bool> ReconcilePrepAsync(string profile, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(profile)) return false;
        try
        {
            await Rest.JsonAsync(HttpMethod.Post, Base + "/prep-job/" + KanbanRest.Segment(profile), timeout: TimeSpan.FromSeconds(30), ct: ct);
            return true;
        }
        catch (Exception) { return false; }
    }

    /// `POST /goals` `{title, why?, …}`: the goal made.
    public async Task<Goal> CreateGoalAsync(JsonObject fields, CancellationToken ct = default) =>
        GoalOf(await Rest.JsonAsync(HttpMethod.Post, Route + "/goals", body: fields, ct: ct));

    /// `PATCH /goals/{id}` with `rev` and changed fields.
    public async Task<Goal> PatchGoalAsync(string goalId, int rev, JsonObject fields, CancellationToken ct = default)
    {
        var body = (JsonObject)fields.DeepClone();
        body["rev"] = rev;
        return GoalOf(await Rest.JsonAsync(HttpMethod.Patch, Route + "/goals/" + KanbanRest.Segment(goalId), body: body, ct: ct));
    }

    /// `DELETE /goals/{id}`.
    public Task DeleteGoalAsync(string goalId, CancellationToken ct = default) =>
        Rest.JsonAsync(HttpMethod.Delete, Route + "/goals/" + KanbanRest.Segment(goalId), ct: ct);

    /// `POST /tasks/{id}/attach` with a file payload (`data` base64).
    public async Task<TodoTask> AttachFileAsync(string taskId, string fileName, byte[] bytes, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["kind"] = "file",
            ["name"] = fileName,
            ["data"] = Convert.ToBase64String(bytes),
        };
        return TaskOf(await Rest.JsonAsync(HttpMethod.Post, PathOf(taskId) + "/attach", body: body, timeout: TimeSpan.FromSeconds(120), ct: ct));
    }

    /// `POST /tasks/{id}/attach` with a web link (`title`, `url`).
    public async Task<TodoTask> AttachLinkAsync(string taskId, string title, string url, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["kind"] = "link",
            ["title"] = title,
            ["url"] = url,
        };
        return TaskOf(await Rest.JsonAsync(HttpMethod.Post, PathOf(taskId) + "/attach", body: body, ct: ct));
    }

    /// `DELETE /tasks/{id}/made/{madeId}` removes one attachment/made item.
    public async Task<TodoTask> DetachMadeAsync(string taskId, string madeId, CancellationToken ct = default) =>
        TaskOf(await Rest.JsonAsync(HttpMethod.Delete, PathOf(taskId) + "/made/" + KanbanRest.Segment(madeId), ct: ct));

    /// Dismisses a bot's close offer (`PATCH /tasks/{id}` `{keep_open: true, rev}`).
    public Task<TodoTask> KeepTaskOpenAsync(string taskId, int rev, CancellationToken ct = default) =>
        PatchAsync(taskId, rev, new JsonObject { ["keep_open"] = true }, ct);

    /// `POST /tasks/offers/{id}` with `{action, list, plan?, in_goal?}`.
    public async Task<TodoOfferAnswer> AnswerOfferAsync(
        string offerId,
        string action,
        bool list = true,
        bool? plan = null,
        bool? inGoal = null,
        CancellationToken ct = default)
    {
        var wireAction = action == "accept_no_list" ? "accept" : action;
        var wireList = action == "accept_no_list" ? false : list;
        var body = new JsonObject
        {
            ["action"] = wireAction,
            ["list"] = wireList,
        };
        if (plan is { } p) body["plan"] = p;
        if (inGoal is { } ig) body["in_goal"] = ig;
        return TodoOfferAnswer.From(await Rest.JsonAsync(HttpMethod.Post, Base + "/offers/" + KanbanRest.Segment(offerId), body: body, ct: ct));
    }

    /// `GET /tasks/{id}/page`: supports both raw HTML (live add-on) and `{html, markdown, text}` JSON answers.
    public Task<string?> GetTaskPageHtmlAsync(string taskId, CancellationToken ct = default) =>
        GetTaskPageHtmlAsync(taskId, names: null, ct);

    public Task<string?> GetTaskPageHtmlAsync(string taskId, IReadOnlyDictionary<string, string>? names, CancellationToken ct = default) =>
        FetchPageHtmlAsync(PathOf(taskId) + "/page", names, ct);

    /// `GET /goals/{id}/page`: supports both raw HTML (live add-on) and `{html, markdown, text}` JSON answers.
    public Task<string?> GetGoalPageHtmlAsync(string goalId, CancellationToken ct = default) =>
        GetGoalPageHtmlAsync(goalId, names: null, ct);

    public Task<string?> GetGoalPageHtmlAsync(string goalId, IReadOnlyDictionary<string, string>? names, CancellationToken ct = default) =>
        FetchPageHtmlAsync(Route + "/goals/" + KanbanRest.Segment(goalId) + "/page", names, ct);

    private async Task<string?> FetchPageHtmlAsync(string path, IReadOnlyDictionary<string, string>? names, CancellationToken ct)
    {
        IEnumerable<KeyValuePair<string, string>>? query = null;
        if (names is { Count: > 0 })
        {
            var obj = new JsonObject();
            foreach (var (k, v) in names) obj[k] = v;
            query = [new("names", obj.ToJsonString())];
        }

        // 1) Try JSON first (works with mocks/older JSON responses).
        var json = await Rest.JsonAsync(HttpMethod.Get, path, query, timeout: TimeSpan.FromSeconds(20), ct: ct);
        if (json != null)
            return json.Str("html") ?? json.Str("markdown") ?? json.Str("text");

        // 2) Live add-on returns text/html (so `a.Json` is null): download raw bytes via `DownloadAsync`.
        var temp = Path.Combine(Path.GetTempPath(), "hermes-page-" + Guid.NewGuid().ToString("N") + ".html");
        try
        {
            await Rest.DownloadAsync(path, query, temp, 5L << 20, ct);
            if (!File.Exists(temp)) return null;
            var text = await File.ReadAllTextAsync(temp, Encoding.UTF8, ct);
            return string.IsNullOrWhiteSpace(text) ? null : text;
        }
        catch (NotSupportedException) { return null; }
        finally
        {
            try { if (File.Exists(temp)) File.Delete(temp); } catch (IOException) { }
        }
    }

    public async Task<TaskIdeasPage> GetIdeasAsync(CancellationToken ct = default) =>
        TaskIdeasPage.From(await Rest.JsonAsync(HttpMethod.Get, Base + "/ideas", ct: ct));

    public async Task<TaskIdeasAvailableSources> GetIdeasSourcesAsync(CancellationToken ct = default) =>
        TaskIdeasAvailableSources.From(await Rest.JsonAsync(HttpMethod.Get, Base + "/ideas/sources", ct: ct));

    public async Task<TodoTask?> AddIdeaAsync(string ideaId, bool letBotStart = false, CancellationToken ct = default)
    {
        var body = new JsonObject { ["start"] = letBotStart };
        var json = await Rest.JsonAsync(HttpMethod.Post, Base + "/ideas/" + KanbanRest.Segment(ideaId) + "/add", body: body, ct: ct);
        return TodoTask.From(json) ?? TodoTask.From(json.Get("task"));
    }

    public Task DismissIdeaAsync(string ideaId, CancellationToken ct = default) =>
        Rest.JsonAsync(HttpMethod.Post, Base + "/ideas/" + KanbanRest.Segment(ideaId) + "/dismiss", body: new JsonObject(), ct: ct);

    public Task RestoreIdeaAsync(string ideaId, CancellationToken ct = default) =>
        Rest.JsonAsync(HttpMethod.Post, Base + "/ideas/" + KanbanRest.Segment(ideaId) + "/restore", body: new JsonObject(), ct: ct);

    public async Task<bool> LookForIdeasAsync(CancellationToken ct = default) =>
        (await Rest.JsonAsync(HttpMethod.Post, Base + "/ideas/run", body: new JsonObject(), ct: ct)).Bool("started") ?? false;

    public static Goal GoalOf(JsonNode? json) =>
        Goal.From(json) ?? Goal.From(json.Get("goal")) ?? Goal.From(json.Obj("detail").Get("goal"))
        ?? throw new PagesMessageException("The gateway sent a goal this app can’t read.");

    public static Goal? GoalConflict(Exception e)
    {
        if (e is not GatewayException { Code: "http", Status: 409 } g || J.Parse(g.Body ?? "") is not { } json) return null;
        try { return GoalOf(json); } catch (PagesMessageException) { return null; }
    }

    public async Task<bool?> AddOnServesTasksAsync(CancellationToken ct = default)
    {
        try { return (await Rest.JsonAsync(HttpMethod.Get, Route + "/status", timeout: TimeSpan.FromSeconds(15), ct: ct)).Bool("tasks") == true; }
        catch (GatewayException e) when (e.Code == "http") { return false; }
        catch (Exception) { return null; }
    }

    public async Task<bool?> AddOnDrawsGoalPagesAsync(CancellationToken ct = default)
    {
        try { return (await Rest.JsonAsync(HttpMethod.Get, Route + "/status", timeout: TimeSpan.FromSeconds(15), ct: ct)).Bool("goal_pages") == true; }
        catch (GatewayException e) when (e.Code == "http") { return false; }
        catch (Exception) { return null; }
    }

    public static TodoTask TaskOf(JsonNode? json) =>
        TodoTask.From(json) ?? TodoTask.From(json.Get("task")) ?? TodoTask.From(json.Obj("detail").Get("task"))
        ?? throw new PagesMessageException("The gateway sent a task this app can’t read.");

    public static TodoTask? Conflict(Exception e)
    {
        if (e is not GatewayException { Code: "http", Status: 409 } g || J.Parse(g.Body ?? "") is not { } json) return null;
        try { return TaskOf(json); } catch (PagesMessageException) { return null; }
    }
}

/// Kind of offline mutation queued in `tasks-pending.json` (`TodoPendingOp.Kind` in `TasksStore.swift`).
public enum TodoPendingOpKind
{
    Add,
    Patch,
    Delete,
    SaveSections,
    AnswerOffer,
}

/// A task mutation queued while the gateway was unreachable (replayed FIFO on reconnect / refresh).
public sealed record TodoPendingOp
{
    public string Id { get; init; } = Guid.NewGuid().ToString("N");
    public TodoPendingOpKind Kind { get; init; }
    public double CreatedAt { get; init; } = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
    /// Task id (for `Add` = localId, `Patch`, `Delete`) or offer id (for `AnswerOffer`).
    public string TargetId { get; init; } = "";
    /// Wire fields for `Add` or `Patch`.
    public JsonObject? Fields { get; init; }
    /// Baseline wire values before the queued `Patch` (for 3-way conflict resolution on replay).
    public JsonObject? BaseFields { get; init; }
    public bool Touch { get; init; }
    public IReadOnlyList<TodoUserSection>? Sections { get; init; }
    public TodoOfferAction? OfferAction { get; init; }
    public bool OfferList { get; init; } = true;
    public bool? GoalPlan { get; init; }
    public bool? GoalInGoal { get; init; }

    public JsonObject Wire()
    {
        var o = new JsonObject
        {
            ["id"] = Id,
            ["kind"] = Kind.ToString(),
            ["created_at"] = CreatedAt,
            ["target_id"] = TargetId,
        };
        if (Fields != null) o["fields"] = Fields.DeepClone();
        if (BaseFields != null) o["base_fields"] = BaseFields.DeepClone();
        if (Touch) o["touch"] = true;
        if (Sections != null) o["sections"] = new JsonArray([.. Sections.Select(s => (JsonNode)s.Wire())]);
        if (OfferAction is { } act) o["offer_action"] = act.ToString();
        if (Kind == TodoPendingOpKind.AnswerOffer)
        {
            o["offer_list"] = OfferList;
            if (GoalPlan is { } gp) o["goal_plan"] = gp;
            if (GoalInGoal is { } gi) o["goal_in_goal"] = gi;
        }
        return o;
    }

    public static TodoPendingOp? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        if (!Enum.TryParse<TodoPendingOpKind>(n.Str("kind"), ignoreCase: true, out var kind)) return null;
        TodoOfferAction? offerAction = null;
        if (n.Str("offer_action") is { Length: > 0 } actStr && Enum.TryParse<TodoOfferAction>(actStr, ignoreCase: true, out var parsed))
            offerAction = parsed;
        return new TodoPendingOp
        {
            Id = n.Text("id") ?? Guid.NewGuid().ToString("N"),
            Kind = kind,
            CreatedAt = n.Num("created_at") ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            TargetId = n.Str("target_id") ?? "",
            Fields = n.Obj("fields") is { } f ? (JsonObject)f.DeepClone() : null,
            BaseFields = n.Obj("base_fields") is { } bf ? (JsonObject)bf.DeepClone() : null,
            Touch = n.Bool("touch") ?? false,
            Sections = n.Arr("sections") is { } secs ? [.. secs.Select(TodoUserSection.From).OfType<TodoUserSection>()] : null,
            OfferAction = offerAction,
            OfferList = n.Bool("offer_list") ?? true,
            GoalPlan = n.Bool("goal_plan"),
            GoalInGoal = n.Bool("goal_in_goal"),
        };
    }
}

/// The Tasks page's data (`HermesKit/Pages/Tasks/TasksStore.swift`): disk cache (`tasks.json`), offline write queue
/// (`tasks-pending.json`) with coalescing & add-folding + FIFO replay, per-task serialized write queue with monotonic
/// edit tokens, 3-way step merge on 409 conflicts, foreground-gated 30s polling, and live `tasks.changed` refresh.
///
/// One thread only (UI thread / `MainLoop` in tests), matching `@MainActor` on Apple.
public sealed class TasksStore
{
    public const int FileLimit = 10 * 1024 * 1024;
    public const string SectionsNeedAddOn = "Sections need the newest HQ add-on on your computer (0.9.36 or later).";

    public TasksApi Api { get; }
    public string? CacheDirectory { get; }
    private readonly TimeSpan _pollInterval;

    private bool _readOnlyGateway;
    public bool ReadOnlyGateway
    {
        get => _readOnlyGateway;
        set
        {
            if (_readOnlyGateway == value) return;
            _readOnlyGateway = value;
            TodoTaskStates.NoteReadOnly(value);
        }
    }

    public IReadOnlyList<TodoTask> Tasks => _tasks;
    private List<TodoTask> _tasks = [];
    public TodoSettings Settings { get; private set; } = new();
    public IReadOnlyList<TodoUserSection> Sections { get; private set; } = [];
    public int Rev { get; private set; }
    public bool HasList { get; private set; }
    public bool Loading { get; private set; }
    public string? Error { get; private set; }
    public bool NeedsAddOn { get; private set; }
    public bool FieldsSupported { get; private set; }
    public bool FilesSupported { get; private set; }
    public bool PagesSupported { get; private set; }
    public bool GoalBotsSupported { get; private set; }
    public bool GoalPagesSupported { get; private set; }
    public bool CustomRepeatSupported { get; private set; }
    public IReadOnlyList<TodoOffer> Offers { get; private set; } = [];
    public int IdeasCount { get; private set; }
    public bool SectionsSupported { get; private set; }
    public bool ListsSupported { get; private set; }
    public IReadOnlyList<Goal> Goals { get; private set; } = [];
    public bool GoalsSupported { get; private set; }
    public bool GoalsNeedAddOn => GoalsAddOn.NeedsAddOn(HasList, NeedsAddOn, GoalsSupported);
    public bool EditsLists => !ReadOnlyGateway && SectionsSupported;
    public string? AddFailure { get; private set; }
    public string? AddGoalFailure { get; private set; }
    public int PendingCount => _pendingOps.Count;
    public IReadOnlyList<TodoPendingOp> PendingOps => _pendingOps;
    public string? LastNotice { get; set; }
    public string? NoticeTask { get; private set; }

    public event Action? Changed;
    public event Action<string, string?>? Notice;
    public event Action<IReadOnlyList<TodoTask>>? ListChanged;
    public event Action<string>? RefreshFailed;
    public event Action<TodoOffer>? PlanTaken;
    public event Action<bool>? EnabledChanged;

    private readonly Dictionary<string, int> _inFlight = new(StringComparer.Ordinal);
    private readonly HashSet<string> _deleting = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Task> _taskQueue = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> _taskEditToken = new(StringComparer.Ordinal);
    private readonly Dictionary<string, TodoTask> _serverTask = new(StringComparer.Ordinal);
    private readonly List<TodoPendingOp> _pendingOps = [];
    private bool _flushingPending;
    private string? _flushingOpId;
    private bool _sectionsWriting;
    private int _offersWriting;
    private readonly Dictionary<string, int> _goalsInFlight = new(StringComparer.Ordinal);
    private int _readGeneration;
    private bool _prepared;
    private bool _closed;
    private bool _goalPagesAsked;
    private long _writes;
    private readonly Dictionary<string, long> _addedAt = new(StringComparer.Ordinal);
    private readonly Dictionary<string, long> _deletedAt = new(StringComparer.Ordinal);

    // Foreground-gated polling & live socket throttle.
    private int _visibleCount;
    private bool _appActive = true;
    private CancellationTokenSource? _pollCts;
    private CancellationTokenSource? _changedRefreshCts;
    private CancellationTokenSource? _gatewayReadyCts;

    public TasksStore(TasksApi api, string? cacheDirectory = null, TimeSpan? pollInterval = null)
    {
        Api = api;
        CacheDirectory = cacheDirectory;
        _pollInterval = pollInterval ?? TimeSpan.FromSeconds(30);
    }

    public TodoTask? Find(string id) => _tasks.FirstOrDefault(t => t.Id == id);
    public Goal? FindGoal(string id) => Goals.FirstOrDefault(g => g.Id == id);

    private string? CachePath => CacheDirectory == null ? null : Path.Combine(CacheDirectory, "tasks.json");
    private string? PendingPath => CacheDirectory == null ? null : Path.Combine(CacheDirectory, "tasks-pending.json");

    // ------------------------------------------------------------------ Static pure helpers (3-way step merge, prep bots, duplicate)

    /// True for transport/network reachability failures (not HTTP 4xx/5xx server refusals or cancellation).
    public static bool IsOfflineError(Exception e) => e switch
    {
        GatewayException { Code: "offline" or "timeout" } => true,
        HttpRequestException => true,
        SocketException => true,
        _ when e.InnerException != null => IsOfflineError(e.InnerException),
        _ => false,
    };

    /// Who changes to Just Me: a bot's steps become yours. Returns null when nothing changes.
    public static List<TodoStep>? StepsForJustMe(TodoWho who, IReadOnlyList<TodoStep> steps)
    {
        if (who != TodoWho.Me || !steps.Any(s => s.Who != "me")) return null;
        return [.. steps.Select(s => s with { Who = "me" })];
    }

    /// The bots whose "Task prep" job a change may start or end (`TodoEdits.prepBots`).
    public static List<string> PrepBots(TodoTask? before, TodoTask? after, IReadOnlySet<string>? fields)
    {
        if (fields != null && !fields.Overlaps(["prep", "bot", "who", "status"])) return [];
        var bots = new List<string>();
        foreach (var task in new[] { before, after })
        {
            if (task is { Prep: true, Helper: { } bot } && !bots.Contains(bot, StringComparer.Ordinal))
                bots.Add(bot);
        }
        if (fields != null && (before?.Prep == true || after?.Prep == true))
        {
            foreach (var task in new[] { before, after })
            {
                if (task?.Helper is { } bot && !bots.Contains(bot, StringComparer.Ordinal))
                    bots.Add(bot);
            }
        }
        return bots;
    }

    /// 3-way conflict resolution that merges non-conflicting per-step edits by `id` (`TodoEdits.resolveFields`).
    /// Returns `(rev, mergedFields)` to resend on `current.Rev`, or null on an unresolvable clash.
    public static (int Rev, JsonObject Fields)? ResolveFields(TodoTask @base, TodoTask current, JsonObject fields)
    {
        var resolved = (JsonObject)fields.DeepClone();
        foreach (var (key, value) in fields)
        {
            if (key == "rev") continue;
            if (TodoEdits.ValueOf(key, @base) == TodoEdits.ValueOf(key, current)) continue;
            if (key != "steps" || value is not JsonArray rawSteps) return null;
            var ours = rawSteps.Select(TodoStep.From).ToList();
            if (MergeSteps(@base.Steps, current.Steps, ours) is not { } merged) return null;
            resolved["steps"] = TodoWire.Steps(merged);
        }
        return (current.Rev, resolved);
    }

    /// 3-way merge of `steps` keyed by `id` (`TodoEdits.mergeSteps`). Two edits to different steps (or non-overlapping
    /// fields of the same step, or concurrent additions) merge cleanly; conflicting edits or edit-vs-delete return null.
    public static List<TodoStep>? MergeSteps(IReadOnlyList<TodoStep> @base, IReadOnlyList<TodoStep> current, IReadOnlyList<TodoStep> ours)
    {
        var baseById = new Dictionary<string, TodoStep>(StringComparer.Ordinal);
        foreach (var s in @base) baseById.TryAdd(s.Id, s);
        var currentById = new Dictionary<string, TodoStep>(StringComparer.Ordinal);
        foreach (var s in current) currentById.TryAdd(s.Id, s);
        var oursById = new Dictionary<string, TodoStep>(StringComparer.Ordinal);
        foreach (var s in ours) oursById.TryAdd(s.Id, s);

        var output = new List<TodoStep>();
        var emitted = new HashSet<string>(StringComparer.Ordinal);

        // Walk `current`'s order first so remote additions/order are preserved.
        foreach (var step in current)
        {
            emitted.Add(step.Id);
            if (!baseById.TryGetValue(step.Id, out var orig))
            {
                // Added remotely. If we also added the exact same id with different content, conflict.
                if (oursById.TryGetValue(step.Id, out var sameIdMine) && sameIdMine != step) return null;
                output.Add(step);
                continue;
            }
            if (!oursById.TryGetValue(step.Id, out var mine))
            {
                // Deleted by us. If they changed it, edit-vs-delete conflict; otherwise honor delete.
                if (step != orig) return null;
                continue;
            }
            // Present in all three: merge field-by-field.
            var title = step.Title;
            var who = step.Who;
            var done = step.Done;
            if (mine.Title != orig.Title)
            {
                if (step.Title != orig.Title && step.Title != mine.Title) return null;
                title = mine.Title;
            }
            if (mine.Who != orig.Who)
            {
                if (step.Who != orig.Who && step.Who != mine.Who) return null;
                who = mine.Who;
            }
            if (mine.Done != orig.Done)
            {
                if (step.Done != orig.Done && step.Done != mine.Done) return null;
                done = mine.Done;
            }
            output.Add(new TodoStep(step.Id, title, who, done));
        }

        // Steps in `base` deleted remotely: if we edited one, edit-vs-delete conflict.
        foreach (var orig in @base)
        {
            if (currentById.ContainsKey(orig.Id)) continue;
            if (oursById.TryGetValue(orig.Id, out var mine) && mine != orig) return null;
        }

        // Append steps newly added by us (not in `base` and not already emitted).
        foreach (var step in ours)
        {
            if (baseById.ContainsKey(step.Id) || !emitted.Add(step.Id)) continue;
            output.Add(step);
        }
        return output;
    }

    /// Builds a clean `POST /tasks` body cloning `task` as a fresh open task with unticked steps (`TodoWire.duplicate`).
    public static JsonObject DuplicateBody(TodoTask task, bool fieldsSupported, bool goalsSupported)
    {
        var freshSteps = task.Steps.Select(s => new TodoStep(TodoIds.Make(), s.Title, s.Who, Done: false)).ToList();
        var body = TodoWire.NewTask(
            title: task.Title,
            who: task.WhoKind,
            bot: task.Helper,
            due: task.Due,
            repeatRule: task.RepeatRule,
            prep: task.Prep,
            notes: task.Notes,
            steps: freshSteps,
            sourceKind: "app",
            fieldsSupported: fieldsSupported,
            goal: goalsSupported ? task.Goal : null,
            milestone: goalsSupported ? task.Milestone : null);
        if (task.Section != null) body["section"] = task.Section;
        if (fieldsSupported)
        {
            if (task.Priority > 0) body["priority"] = task.Priority;
            if (task.Tags.Count > 0) body["tags"] = new JsonArray([.. task.Tags.Select(t => (JsonNode)t)]);
            if (task.Starts != null) body["starts"] = task.Starts;
            if (task.Alert != null) body["alert"] = task.Alert;
        }
        return body;
    }

    /// Switching a task's goal without setting a milestone clears the old goal's milestone.
    public static JsonObject WithMilestoneRule(JsonObject fields, TodoTask task)
    {
        if (!fields.ContainsKey("goal") || fields.ContainsKey("milestone")) return fields;
        var nextGoal = J.AsString(fields["goal"]);
        if (string.Equals(nextGoal, task.Goal, StringComparison.Ordinal)) return fields;
        var copy = (JsonObject)fields.DeepClone();
        copy["milestone"] = null;
        return copy;
    }

    // ------------------------------------------------------------------ Lifecycle, polling & live events

    public void SetVisible(bool shown)
    {
        _visibleCount = shown ? _visibleCount + 1 : Math.Max(0, _visibleCount - 1);
        SyncPolling();
    }

    public void SetForeground(bool active)
    {
        _appActive = active;
        SyncPolling();
    }

    private void SyncPolling()
    {
        if (_closed || _visibleCount <= 0 || !_appActive)
        {
            CancelCts(ref _pollCts);
            return;
        }
        if (_pollCts != null) return;
        var cts = _pollCts = new CancellationTokenSource();
        _ = PollLoopAsync(cts);
    }

    private async Task PollLoopAsync(CancellationTokenSource cts)
    {
        try
        {
            while (!cts.IsCancellationRequested && !_closed)
            {
                await Task.Delay(_pollInterval, cts.Token);
                if (cts.IsCancellationRequested || _closed) break;
                if (_visibleCount > 0 && _appActive)
                    await RefreshAsync();
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        finally
        {
            if (ReferenceEquals(_pollCts, cts)) _pollCts = null;
            try { cts.Dispose(); } catch (ObjectDisposedException) { }
        }
    }

    /// Live `tasks.changed` socket event: throttled forced refresh (~1 s debounce).
    public void ApplyTasksChangedEvent()
    {
        if (_closed || _changedRefreshCts != null) return;
        var cts = _changedRefreshCts = new CancellationTokenSource();
        _ = RunChangedRefreshAsync(cts);
    }

    private async Task RunChangedRefreshAsync(CancellationTokenSource cts)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(1), cts.Token);
            if (!_closed && !cts.IsCancellationRequested)
                await RefreshAsync(force: true);
        }
        catch (OperationCanceledException) { }
        finally
        {
            if (ReferenceEquals(_changedRefreshCts, cts)) _changedRefreshCts = null;
            try { cts.Dispose(); } catch (ObjectDisposedException) { }
        }
    }

    /// Gateway reconnected (`gateway.ready`): replays queued offline mutations, then refreshes.
    public async Task GatewayReadyAsync()
    {
        if (_closed) return;
        CancelCts(ref _gatewayReadyCts);
        var cts = _gatewayReadyCts = new CancellationTokenSource();
        try
        {
            await FlushPendingAsync();
            if (_closed || cts.IsCancellationRequested) return;
            await RefreshAsync(force: true);
        }
        finally
        {
            if (ReferenceEquals(_gatewayReadyCts, cts)) _gatewayReadyCts = null;
            try { cts.Dispose(); } catch (ObjectDisposedException) { }
        }
    }

    /// Signed out or switched away: stop polling, cancel timers, forget in-memory state.
    public void Forget()
    {
        _closed = true;
        CancelCts(ref _pollCts);
        CancelCts(ref _changedRefreshCts);
        CancelCts(ref _gatewayReadyCts);
        _visibleCount = 0;
        _taskQueue.Clear();
        _tasks = [];
        Sections = [];
        Goals = [];
        Offers = [];
        _pendingOps.Clear();
        _deleting.Clear();
        _serverTask.Clear();
        _taskEditToken.Clear();
        Rev = 0;
        HasList = false;
        _prepared = false;
        _readGeneration++;
        TodoTaskStates.Forget();
        Changed?.Invoke();
        ListChanged?.Invoke(_tasks);
    }

    private static void CancelCts(ref CancellationTokenSource? cts)
    {
        if (cts is not { } current) return;
        cts = null;
        try { current.Cancel(); } catch (ObjectDisposedException) { }
        try { current.Dispose(); } catch (ObjectDisposedException) { }
    }

    // ------------------------------------------------------------------ Disk cache (`tasks.json`) & offline queue (`tasks-pending.json`)

    /// Paints the cached list and loads pending offline ops from disk before the first network read.
    public void Prepare()
    {
        if (_prepared || _closed) return;
        _prepared = true;
        if (PendingPath is { } pendingFile && File.Exists(pendingFile))
        {
            try
            {
                var node = J.Parse(File.ReadAllText(pendingFile));
                var arr = node as JsonArray ?? node.Arr("ops");
                if (arr != null)
                {
                    _pendingOps.Clear();
                    foreach (var item in arr)
                        if (TodoPendingOp.From(item) is { } op) _pendingOps.Add(op);
                }
            }
            catch (IOException) { }
        }

        if (HasList || CachePath is not { } cacheFile || !File.Exists(cacheFile)) return;
        try
        {
            if (J.Parse(File.ReadAllText(cacheFile)) is not JsonObject snap) return;
            var answer = TodoListAnswer.From(snap);
            if (answer.Tasks == null) return;
            _tasks = [.. answer.Tasks];
            if (answer.Settings != null) Settings = answer.Settings;
            Sections = answer.Sections ?? [];
            SectionsSupported = answer.Sections != null;
            PagesSupported = answer.Pages;
            FieldsSupported = answer.Fields;
            FilesSupported = answer.Files;
            ListsSupported = answer.Lists;
            Offers = Once(answer.Offers ?? []);
            Goals = answer.Goals ?? [];
            GoalsSupported = answer.Goals != null;
            GoalBotsSupported = GoalsSupported && answer.GoalBots;
            GoalPagesSupported = GoalBotsSupported && (snap.Bool("goal_pages") ?? false);
            CustomRepeatSupported = answer.CustomRepeat;
            IdeasCount = answer.IdeasCount;
            Rev = answer.Rev;
            HasList = true;
            TodoTaskStates.Note(_tasks);
            Raise();
        }
        catch (IOException) { }
    }

    private void Save()
    {
        if (_closed || CachePath is not { } path) return;
        try
        {
            var queuedLocals = PendingTaskIds();
            var hasPendingSecs = HasPendingSections();
            var snap = new JsonObject
            {
                ["rev"] = Rev,
                ["tasks"] = new JsonArray([.. _tasks
                    .Where(t => !TodoIds.IsLocal(t.Id) || queuedLocals.Contains(t.Id))
                    .Select(TaskToCacheNode)]),
                ["settings"] = Settings.Wire(),
                ["pages"] = PagesSupported,
                ["ideas"] = IdeasCount,
                ["fields"] = FieldsSupported,
                ["files"] = FilesSupported,
                ["lists"] = ListsSupported,
                ["offers"] = new JsonArray([.. Offers.Select(o => (JsonNode)o.Wire())]),
                ["goal_bots"] = GoalBotsSupported,
                ["goal_pages"] = GoalPagesSupported,
                ["custom_repeat"] = CustomRepeatSupported,
            };
            if (SectionsSupported)
                snap["sections"] = new JsonArray([.. Sections.Where(s => !TodoIds.IsLocal(s.Id) || hasPendingSecs).Select(s => (JsonNode)s.Wire())]);
            if (GoalsSupported)
                snap["goals"] = new JsonArray([.. Goals.Where(g => !TodoIds.IsLocal(g.Id)).Select(GoalToCacheNode)]);

            WriteAtomic(path, snap.ToJsonString());
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private void SavePending()
    {
        if (_closed || PendingPath is not { } path) return;
        try
        {
            if (_pendingOps.Count == 0)
            {
                if (File.Exists(path)) File.Delete(path);
                return;
            }
            var body = new JsonObject
            {
                ["at"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                ["ops"] = new JsonArray([.. _pendingOps.Select(o => (JsonNode)o.Wire())]),
            };
            WriteAtomic(path, body.ToJsonString());
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void WriteAtomic(string path, string content)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var tmp = path + ".tmp." + Guid.NewGuid().ToString("N");
        File.WriteAllText(tmp, content, Encoding.UTF8);
        File.Move(tmp, path, overwrite: true);
    }

    private static JsonNode TaskToCacheNode(TodoTask t)
    {
        var o = t.Raw.Count > 0 ? (JsonObject)t.Raw.DeepClone() : new JsonObject();
        o["id"] = t.Id;
        o["rev"] = t.Rev;
        o["title"] = t.Title;
        o["notes"] = t.Notes;
        o["who"] = t.Who;
        o["bot"] = t.Bot;
        o["status"] = t.Status;
        o["status_note"] = t.StatusNote;
        o["due"] = t.Due;
        o["repeat"] = t.RepeatRule;
        o["prep"] = t.Prep;
        o["position"] = t.Position;
        o["priority"] = t.Priority;
        o["section"] = t.Section;
        o["goal"] = t.Goal;
        o["milestone"] = t.Milestone;
        o["starts"] = t.Starts;
        o["steps"] = TodoWire.Steps(t.Steps);
        o["tags"] = new JsonArray([.. t.Tags.Select(x => (JsonNode)x)]);
        if (t.CreatedAt != null) o["created_at"] = t.CreatedAt;
        if (t.UpdatedAt != null) o["updated_at"] = t.UpdatedAt;
        if (t.DoneAt != null) o["done_at"] = t.DoneAt;
        if (t.Offer != null)
        {
            o["offer"] = new JsonObject
            {
                ["by"] = t.Offer.By,
                ["text"] = t.Offer.Text,
                ["at"] = t.Offer.At,
                ["kept"] = t.Offer.Kept,
            };
        }
        return o;
    }

    private static JsonNode GoalToCacheNode(Goal g)
    {
        if (g.Raw.Count > 0) return g.Raw.DeepClone();
        var o = new JsonObject
        {
            ["id"] = g.Id, ["rev"] = g.Rev, ["title"] = g.Title, ["why"] = g.Why, ["status"] = g.Status,
            ["position"] = g.Position, ["adds"] = g.Adds, ["known_to_all"] = g.KnownToAll,
            ["milestones"] = GoalWire.Milestones(g.Milestones),
        };
        if (g.Color != null) o["color"] = g.Color;
        if (g.Due != null) o["due"] = g.Due;
        if (g.Lead != null) o["lead"] = g.Lead;
        if (g.Helpers.Count > 0) o["helpers"] = new JsonArray([.. g.Helpers.Select(h => (JsonNode)h)]);
        if (g.Measure != null) o["measure"] = g.Measure.Wire();
        if (g.Review != null) o["review"] = g.Review.Wire();
        return o;
    }

    private HashSet<string> PendingTaskIds()
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var op in _pendingOps)
            if (op.Kind is TodoPendingOpKind.Add or TodoPendingOpKind.Patch or TodoPendingOpKind.Delete && op.TargetId.Length > 0)
                ids.Add(op.TargetId);
        return ids;
    }

    private HashSet<string> PendingDeletedIds()
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var op in _pendingOps)
            if (op.Kind == TodoPendingOpKind.Delete && op.TargetId.Length > 0)
                ids.Add(op.TargetId);
        return ids;
    }

    private bool HasPendingSections() => _pendingOps.Any(o => o.Kind == TodoPendingOpKind.SaveSections);
    private bool HasPendingOffers() => _pendingOps.Any(o => o.Kind == TodoPendingOpKind.AnswerOffer);

    private static JsonObject BaselineFields(JsonObject fields, TodoTask task)
    {
        var baseline = new JsonObject();
        foreach (var (key, _) in fields)
        {
            if (key == "rev") continue;
            baseline[key] = task.Raw.Get(key)?.DeepClone();
        }
        return baseline;
    }

    private void EnqueueOffline(TodoPendingOp op, bool quiet = false, string? about = null)
    {
        switch (op.Kind)
        {
            case TodoPendingOpKind.Patch:
                // Fold into an existing queued Add for a local task, or coalesce into the last queued Patch for this id,
                // skipping whichever op is currently in flight in FlushPendingAsync.
                var addIdx = _pendingOps.FindLastIndex(o => o.Id != _flushingOpId && o.Kind == TodoPendingOpKind.Add && o.TargetId == op.TargetId);
                if (addIdx >= 0 && _pendingOps[addIdx].Fields is { } existingAddFields && op.Fields != null)
                {
                    var mergedAdd = (JsonObject)existingAddFields.DeepClone();
                    foreach (var (k, v) in op.Fields) mergedAdd[k] = v?.DeepClone();
                    _pendingOps[addIdx] = _pendingOps[addIdx] with { Fields = mergedAdd };
                }
                else
                {
                    var patchIdx = _pendingOps.FindLastIndex(o => o.Id != _flushingOpId && o.Kind == TodoPendingOpKind.Patch && o.TargetId == op.TargetId);
                    if (patchIdx >= 0 && _pendingOps[patchIdx].Fields is { } existingPatch && op.Fields != null)
                    {
                        var mergedBase = _pendingOps[patchIdx].BaseFields is { } eb ? (JsonObject)eb.DeepClone() : new JsonObject();
                        if (op.BaseFields != null)
                        {
                            foreach (var (k, v) in op.BaseFields)
                                if (!mergedBase.ContainsKey(k)) mergedBase[k] = v?.DeepClone();
                        }
                        var mergedFields = (JsonObject)existingPatch.DeepClone();
                        foreach (var (k, v) in op.Fields) mergedFields[k] = v?.DeepClone();
                        _pendingOps[patchIdx] = _pendingOps[patchIdx] with
                        {
                            Fields = mergedFields,
                            BaseFields = mergedBase.Count > 0 ? mergedBase : null,
                            Touch = _pendingOps[patchIdx].Touch || op.Touch,
                        };
                    }
                    else
                    {
                        _pendingOps.Add(op);
                    }
                }
                break;

            case TodoPendingOpKind.Delete:
                // Deleting a task added offline cancels its queued Add + Patches with zero network traffic.
                if (_pendingOps.Any(o => o.Kind == TodoPendingOpKind.Add && o.TargetId == op.TargetId))
                {
                    _pendingOps.RemoveAll(o => (o.Kind is TodoPendingOpKind.Add or TodoPendingOpKind.Patch) && o.TargetId == op.TargetId);
                }
                else
                {
                    _pendingOps.RemoveAll(o => o.Kind == TodoPendingOpKind.Patch && o.TargetId == op.TargetId);
                    _pendingOps.Add(op);
                }
                break;

            case TodoPendingOpKind.SaveSections:
                _pendingOps.RemoveAll(o => o.Kind == TodoPendingOpKind.SaveSections);
                _pendingOps.Add(op);
                break;

            default:
                _pendingOps.Add(op);
                break;
        }

        SavePending();
        Save();
        Raise();
        if (!quiet) Tell(TasksCopy.SavedOffline, about);
    }

    /// Replays queued offline writes in FIFO order with `idMap` (`local-*` → server id) and 409 3-way resolution.
    /// Stops immediately if the gateway is still unreachable.
    public async Task FlushPendingAsync()
    {
        if (_closed || _flushingPending || _pendingOps.Count == 0 || ReadOnlyGateway) return;
        _flushingPending = true;
        var idMap = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            while (!_closed && _pendingOps.Count > 0)
            {
                var op = _pendingOps[0];
                var opId = op.Id;
                _flushingOpId = opId;
                try
                {
                    switch (op.Kind)
                    {
                        case TodoPendingOpKind.Add:
                            if (op.Fields == null) break;
                            var made = await Api.CreateAsync(op.Fields);
                            if (_closed) break;
                            // If the user deleted `localId` while create was in flight, avoid resurrection and remove orphan.
                            if (!_pendingOps.Any(o => o.Id == opId))
                            {
                                try { await Api.DeleteAsync(made.Id); } catch (Exception) { }
                                continue;
                            }
                            idMap[op.TargetId] = made.Id;
                            _tasks.RemoveAll(t => t.Id == op.TargetId);
                            Put(made);
                            _addedAt[made.Id] = ++_writes;
                            TriggerReconcilePrep(PrepBots(null, made, null));
                            break;

                        case TodoPendingOpKind.Patch:
                            var id = idMap.GetValueOrDefault(op.TargetId, op.TargetId);
                            if (Find(id) is not { } current || TodoIds.IsLocal(id) || op.Fields == null)
                            {
                                _pendingOps.RemoveAll(o => o.Id == opId);
                                SavePending();
                                continue;
                            }
                            var rawBase = _serverTask.GetValueOrDefault(id) ?? current;
                            var @base = op.BaseFields != null ? (TodoEdits.Applying(op.BaseFields, rawBase) ?? rawBase) : rawBase;
                            try
                            {
                                var answer = await Api.PatchAsync(id, current.Rev, op.Fields);
                                if (_closed) break;
                                if (!_pendingOps.Any(o => o.Id == opId)) continue;
                                _serverTask[id] = answer;
                                Put(answer);
                                TriggerReconcilePrep(PrepBots(@base, answer, op.Fields.Select(kv => kv.Key).ToHashSet(StringComparer.Ordinal)));
                            }
                            catch (Exception e)
                            {
                                if (_closed) break;
                                if (TasksApi.Conflict(e) is { } latest)
                                {
                                    if (ResolveFields(@base, latest, op.Fields) is { } resolved)
                                    {
                                        try
                                        {
                                            var retryAnswer = await Api.PatchAsync(id, resolved.Rev, resolved.Fields);
                                            if (_closed) break;
                                            if (!_pendingOps.Any(o => o.Id == opId)) continue;
                                            _serverTask[id] = retryAnswer;
                                            Put(retryAnswer);
                                            TriggerReconcilePrep(PrepBots(@base, retryAnswer, resolved.Fields.Select(kv => kv.Key).ToHashSet(StringComparer.Ordinal)));
                                        }
                                        catch (Exception retryErr)
                                        {
                                            if (_closed) break;
                                            if (IsOfflineError(retryErr))
                                            {
                                                var idx = _pendingOps.FindIndex(o => o.Id == opId);
                                                if (idx >= 0)
                                                {
                                                    _serverTask[id] = latest;
                                                    Put(TodoEdits.Applying(resolved.Fields, latest) ?? latest);
                                                    _pendingOps[idx] = _pendingOps[idx] with
                                                    {
                                                        Fields = resolved.Fields,
                                                        BaseFields = BaselineFields(resolved.Fields, latest),
                                                    };
                                                    SavePending();
                                                }
                                                throw;
                                            }
                                            if (TasksApi.Conflict(retryErr) is { } newer)
                                            {
                                                if (_pendingOps.Any(o => o.Id == opId))
                                                {
                                                    _serverTask[id] = newer;
                                                    Put(newer);
                                                    Tell(TasksCopy.ChangedElsewhere, id);
                                                }
                                            }
                                            else if (KanbanRest.Status(retryErr) == 404)
                                            {
                                                _tasks.RemoveAll(t => t.Id == id);
                                            }
                                            else throw;
                                        }
                                    }
                                    else if (_pendingOps.Any(o => o.Id == opId))
                                    {
                                        _serverTask[id] = latest;
                                        Put(latest);
                                        Tell(TasksCopy.ChangedElsewhere, id);
                                    }
                                }
                                else if (KanbanRest.Status(e) == 404)
                                {
                                    _tasks.RemoveAll(t => t.Id == id);
                                }
                                else throw;
                            }
                            break;

                        case TodoPendingOpKind.Delete:
                            var delId = idMap.GetValueOrDefault(op.TargetId, op.TargetId);
                            if (!TodoIds.IsLocal(delId))
                            {
                                try { await Api.DeleteAsync(delId); }
                                catch (Exception e) when (KanbanRest.Status(e) == 404) { }
                            }
                            if (_closed) break;
                            _tasks.RemoveAll(t => t.Id == delId);
                            _deletedAt[delId] = ++_writes;
                            break;

                        case TodoPendingOpKind.SaveSections:
                            if (op.Sections == null) break;
                            var savedSecs = await Api.SaveSectionsAsync(op.Sections);
                            if (_closed) break;
                            if (_pendingOps.Any(o => o.Id == opId)) Sections = savedSecs;
                            break;

                        case TodoPendingOpKind.AnswerOffer:
                            if (op.OfferAction is not { } act) break;
                            var btn = new TodoOfferButton(act, "", MakesList: op.OfferList, Plan: op.GoalPlan ?? true, InGoal: op.GoalInGoal ?? true);
                            try
                            {
                                var sendGoal = op.GoalPlan != null || op.GoalInGoal != null;
                                var ans = await Api.AnswerOfferAsync(op.TargetId, btn.WireAction, btn.WireList,
                                    sendGoal ? btn.WirePlan : null, sendGoal ? btn.WireInGoal : null);
                                if (_closed) break;
                                if (ans.Offer is { } updated)
                                    Offers = [.. Offers.Select(o => o.Id == op.TargetId ? updated : o)];
                                if (!HasPendingSections() && ans.HasSections) Sections = ans.Sections;
                                if (ans.Goals is { } gs) { GoalsSupported = true; Goals = gs; }
                            }
                            catch (Exception e) when (KanbanRest.Status(e) is 409 or 404) { }
                            break;
                    }

                    if (_closed) break;
                    _pendingOps.RemoveAll(o => o.Id == opId);
                    SavePending();
                    Save();
                    Raise();
                }
                catch (Exception e)
                {
                    if (_closed) break;
                    if (IsOfflineError(e)) break;
                    var wasPresent = _pendingOps.Any(o => o.Id == opId);
                    _pendingOps.RemoveAll(o => o.Id == opId);
                    SavePending();
                    if (wasPresent) Tell($"Couldn’t sync an offline change. {KanbanRest.Reason(e)}");
                }
                finally
                {
                    if (_flushingOpId == opId) _flushingOpId = null;
                }
            }
        }
        finally
        {
            _flushingPending = false;
            _flushingOpId = null;
        }
    }

    // ------------------------------------------------------------------ Helpers

    private void Raise()
    {
        if (_closed) return;
        TodoTaskStates.Note(_tasks);
        Changed?.Invoke();
        ListChanged?.Invoke(_tasks);
    }

    private void Tell(string text, string? about = null)
    {
        NoticeTask = about;
        LastNotice = text;
        Notice?.Invoke(text, about);
    }

    private bool Refuse(string? about = null, bool quiet = false)
    {
        if (!ReadOnlyGateway) return false;
        if (!quiet) Tell(KanbanRest.ReadOnlyNotice, about);
        return true;
    }

    private void Put(TodoTask task)
    {
        var at = _tasks.FindIndex(t => t.Id == task.Id);
        if (at >= 0) _tasks[at] = task; else _tasks.Add(task);
    }

    private void Begin(string id) => _inFlight[id] = _inFlight.GetValueOrDefault(id) + 1;
    private void End(string id)
    {
        var left = _inFlight.GetValueOrDefault(id, 1) - 1;
        if (left > 0) _inFlight[id] = left;
        else
        {
            _inFlight.Remove(id);
            _serverTask.Remove(id);
        }
    }

    private int NextEditToken(string id)
    {
        var next = _taskEditToken.GetValueOrDefault(id) + 1;
        _taskEditToken[id] = next;
        return next;
    }

    /// Serializes network writes per task id so concurrent edits on the same task execute in order with up-to-date revs,
    /// while edits on distinct task ids still run concurrently.
    private async Task<T> SerializeTaskWriteAsync<T>(string id, Func<Task<T>> work)
    {
        _taskQueue.TryGetValue(id, out var previous);
        var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task RunAsync()
        {
            if (previous != null)
            {
                try { await previous; } catch (Exception) { }
            }
            try { tcs.TrySetResult(await work()); }
            catch (Exception e) { tcs.TrySetException(e); }
        }
        var next = RunAsync();
        _taskQueue[id] = next;
        try
        {
            return await tcs.Task;
        }
        finally
        {
            if (_taskQueue.TryGetValue(id, out var cur) && ReferenceEquals(cur, next))
                _taskQueue.Remove(id);
        }
    }

    private void RestoreFields(IEnumerable<string> keys, TodoTask @base, string id, bool touch)
    {
        if (Find(id) is not { } current) return;
        var revert = new JsonObject();
        foreach (var key in keys)
            if (key != "rev") revert[key] = @base.Raw.Get(key)?.DeepClone();
        if (touch) revert["updated_at"] = @base.UpdatedAt;
        if (TodoEdits.Applying(revert, current) is { } restored) Put(restored);
    }

    private static List<TodoOffer> Once(IEnumerable<TodoOffer> offers)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return [.. offers.Where(o => seen.Add(o.Id))];
    }

    private void TriggerReconcilePrep(IReadOnlyList<string> bots)
    {
        if (bots.Count == 0) return;
        foreach (var bot in bots) _ = Api.ReconcilePrepAsync(bot);
    }

    public Task<bool> ReconcilePrepAsync(string profile, CancellationToken ct = default) =>
        Api.ReconcilePrepAsync(profile, ct);

    public void IdeasRead(int count)
    {
        if (IdeasCount == count) return;
        IdeasCount = count;
        Save();
        Changed?.Invoke();
    }

    // ------------------------------------------------------------------ Reads

    /// Reads the list. `force` skips `?since=`.
    public async Task RefreshAsync(bool force = false)
    {
        if (_closed) return;
        Prepare();
        if (_pendingOps.Count > 0) await FlushPendingAsync();
        if (_closed) return;

        var generation = ++_readGeneration;
        var leftAt = _writes;
        Loading = true;
        Changed?.Invoke();
        try
        {
            var answer = await Api.ListAsync(HasList && !force && Rev > 0 ? Rev : null);
            if (_closed || generation != _readGeneration) return;
            if (answer.Unchanged) { Error = null; NeedsAddOn = false; return; }
            if (answer.Tasks is not { } fresh)
            {
                NeedsAddOn = await Api.AddOnServesTasksAsync() != true;
                if (!NeedsAddOn) Error = KanbanRest.OlderHermes;
                return;
            }
            NeedsAddOn = false;
            Error = null;
            FieldsSupported = answer.Fields;
            FilesSupported = answer.Files;
            PagesSupported = answer.Pages;
            GoalBotsSupported = answer.GoalBots;
            CustomRepeatSupported = answer.CustomRepeat;
            IdeasCount = answer.IdeasCount;
            if (_offersWriting == 0 && !HasPendingOffers()) Offers = Once(answer.Offers ?? []);
            ListsSupported = answer.Lists;
            GoalsSupported = answer.Goals != null;
            if (!GoalBotsSupported)
            {
                GoalPagesSupported = false;
                _goalPagesAsked = false;
            }
            else if (!_goalPagesAsked && CacheDirectory != null)
            {
                _goalPagesAsked = true;
                _ = CheckGoalPagesAsync();
            }
            var goals = answer.Goals ?? [];
            AdoptGoals(goals, leftAt);
            if (!_sectionsWriting && !HasPendingSections())
            {
                Sections = answer.Sections ?? [];
                SectionsSupported = answer.Sections != null;
            }
            Adopt(fresh, answer.Rev, answer.Settings, leftAt);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            if (_closed || generation != _readGeneration) return;
            if (KanbanRest.IsUnknownRoute(e))
            {
                NeedsAddOn = await Api.AddOnServesTasksAsync() != true;
                Error = NeedsAddOn ? null : KanbanRest.Reason(e);
            }
            else Error = KanbanRest.Reason(e);
            if (HasList && !NeedsAddOn && Error is { } reason) RefreshFailed?.Invoke(reason);
        }
        finally
        {
            if (!_closed && generation == _readGeneration) { Loading = false; Changed?.Invoke(); }
        }
    }

    private async Task CheckGoalPagesAsync()
    {
        var draws = await Api.AddOnDrawsGoalPagesAsync();
        if (_closed) return;
        if (draws is { } d) { GoalPagesSupported = d && GoalBotsSupported; Save(); Changed?.Invoke(); }
        else _goalPagesAsked = false;
    }

    private void Adopt(IReadOnlyList<TodoTask> fresh, int rev, TodoSettings? settings, long leftAt)
    {
        var pendingIds = PendingTaskIds();
        var pendingDeletes = PendingDeletedIds();
        var next = fresh.Where(t => !_deleting.Contains(t.Id) && !pendingDeletes.Contains(t.Id) && _deletedAt.GetValueOrDefault(t.Id) <= leftAt).ToList();
        var places = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var i = 0; i < next.Count; i++) places.TryAdd(next[i].Id, i);
        foreach (var local in _tasks)
        {
            if (_deleting.Contains(local.Id) || pendingDeletes.Contains(local.Id)) continue;
            var inHand = _inFlight.ContainsKey(local.Id)
                || TodoIds.IsLocal(local.Id)
                || pendingIds.Contains(local.Id)
                || _addedAt.GetValueOrDefault(local.Id) > leftAt;
            if (places.TryGetValue(local.Id, out var at))
            {
                if (inHand || next[at].Rev < local.Rev) next[at] = local;
            }
            else if (inHand) next.Add(local);
        }
        _tasks = next;
        Rev = rev;
        if (settings != null)
        {
            var prevEnabled = Settings.Enabled;
            Settings = settings;
            if (prevEnabled != settings.Enabled) EnabledChanged?.Invoke(settings.Enabled);
        }
        HasList = true;
        ForgetLanded(_addedAt, leftAt);
        ForgetLanded(_deletedAt, leftAt);
        TodoTaskStates.NoteRead();
        Save();
        Raise();
    }

    private void AdoptGoals(IReadOnlyList<Goal> fresh, long leftAt)
    {
        var next = fresh.ToList();
        var places = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var i = 0; i < next.Count; i++) places.TryAdd(next[i].Id, i);
        foreach (var local in Goals)
        {
            var inHand = _goalsInFlight.ContainsKey(local.Id) || TodoIds.IsLocal(local.Id) || _addedAt.GetValueOrDefault(local.Id) > leftAt;
            if (places.TryGetValue(local.Id, out var at))
            {
                if (inHand || next[at].Rev < local.Rev) next[at] = local;
            }
            else if (inHand) next.Add(local);
        }
        Goals = next;
    }

    private static void ForgetLanded(Dictionary<string, long> landed, long leftAt)
    {
        foreach (var id in landed.Where(p => p.Value <= leftAt).Select(p => p.Key).ToList()) landed.Remove(id);
    }

    // ------------------------------------------------------------------ Task writes

    /// Adds a task: shown at once, then swapped for the gateway's. On offline transport failure, queues offline and keeps
    /// the local task. Returns null when refused by the server, with the reason in `AddFailure`.
    public async Task<TodoTask?> AddAsync(JsonObject fields, bool quiet = false)
    {
        AddFailure = null;
        if (ReadOnlyGateway)
        {
            AddFailure = KanbanRest.ReadOnlyNotice;
            if (!quiet) Tell(KanbanRest.ReadOnlyNotice);
            return null;
        }
        var draft = (JsonObject)fields.DeepClone();
        var localId = TodoIds.Local();
        draft["id"] = localId;
        draft["created_at"] = TodoDates.Now();
        draft["updated_at"] = draft["created_at"]!.DeepClone();
        draft["created_by"] = "you";
        var shown = TodoTask.From(TodoEdits.Reparse(draft));
        if (shown != null) { _tasks.Add(shown); Raise(); }
        try
        {
            var made = await Api.CreateAsync(fields);
            if (_closed) return null;
            _tasks.RemoveAll(t => t.Id == localId);
            Put(made);
            _addedAt[made.Id] = ++_writes;
            Save();
            Raise();
            TriggerReconcilePrep(PrepBots(null, made, null));
            return made;
        }
        catch (Exception e)
        {
            if (_closed) return null;
            if (IsOfflineError(e) && shown != null)
            {
                EnqueueOffline(new TodoPendingOp { Kind = TodoPendingOpKind.Add, TargetId = localId, Fields = (JsonObject)fields.DeepClone() }, quiet: quiet);
                return shown;
            }
            _tasks.RemoveAll(t => t.Id == localId);
            Raise();
            var reason = KanbanRest.Reason(e);
            AddFailure = reason;
            if (!quiet) Tell(TasksCopy.CouldNotAdd(reason));
            return null;
        }
    }

    /// Changes a task's fields (wire names). Serialized per task id with monotonic edit tokens, 3-way step merge on 409,
    /// and offline queueing on transport failures.
    public async Task<bool> PatchAsync(string id, JsonObject fields, bool touch = false)
    {
        if (Refuse(id) || Find(id) is not { } initialBase) return false;
        var patchFields = WithMilestoneRule(fields, initialBase);
        if (TodoIds.IsLocal(id))
        {
            if (PendingTaskIds().Contains(id))
            {
                if (TodoEdits.Applying(patchFields, initialBase) is { } localShown)
                {
                    if (touch) localShown = localShown with { UpdatedAt = TodoDates.Now() };
                    Put(localShown);
                }
                EnqueueOffline(new TodoPendingOp
                {
                    Kind = TodoPendingOpKind.Patch,
                    TargetId = id,
                    Fields = (JsonObject)patchFields.DeepClone(),
                    Touch = touch,
                }, quiet: true, about: id);
                return true;
            }
            Tell(TasksCopy.StillBeingAdded, id);
            return false;
        }

        var token = NextEditToken(id);
        if (TodoEdits.Applying(patchFields, initialBase) is { } shown)
        {
            if (touch) shown = shown with { UpdatedAt = TodoDates.Now() };
            Put(shown);
            Raise();
        }

        Begin(id);
        return await SerializeTaskWriteAsync(id, async () =>
        {
            try
            {
                if (_closed) return false;
                var @base = _serverTask.GetValueOrDefault(id) ?? initialBase;
                var sendFields = (JsonObject)patchFields.DeepClone();
                // If an earlier queued write changed `steps` on this task, 3-way merge our step edits onto `@base`.
                if (sendFields["steps"] is JsonArray rawSteps && !@base.Steps.SequenceEqual(initialBase.Steps))
                {
                    var ours = rawSteps.Select(TodoStep.From).ToList();
                    if (MergeSteps(initialBase.Steps, @base.Steps, ours) is { } merged)
                        sendFields["steps"] = TodoWire.Steps(merged);
                }

                try
                {
                    var answer = await Api.PatchAsync(id, @base.Rev, sendFields);
                    if (_closed) return false;
                    _serverTask[id] = answer;
                    if (_taskEditToken.GetValueOrDefault(id) == token)
                        Put(answer);
                    else if (Find(id) is { } live)
                        Put(live with { Rev = answer.Rev });
                    Save();
                    Raise();
                    TriggerReconcilePrep(PrepBots(@base, answer, sendFields.Select(kv => kv.Key).ToHashSet(StringComparer.Ordinal)));
                    return true;
                }
                catch (Exception e)
                {
                    if (_closed) return false;
                    if (IsOfflineError(e))
                    {
                        EnqueueOffline(new TodoPendingOp
                        {
                            Kind = TodoPendingOpKind.Patch,
                            TargetId = id,
                            Fields = sendFields,
                            BaseFields = BaselineFields(sendFields, @base),
                            Touch = touch,
                        }, about: id);
                        return true;
                    }
                    if (TasksApi.Conflict(e) is { } current)
                    {
                        if (ResolveFields(@base, current, sendFields) is { } resolved)
                        {
                            try
                            {
                                var answer = await Api.PatchAsync(id, resolved.Rev, resolved.Fields);
                                if (_closed) return false;
                                _serverTask[id] = answer;
                                if (_taskEditToken.GetValueOrDefault(id) == token)
                                    Put(answer);
                                else if (Find(id) is { } live)
                                    Put(live with { Rev = answer.Rev });
                                Save();
                                Raise();
                                TriggerReconcilePrep(PrepBots(@base, answer, resolved.Fields.Select(kv => kv.Key).ToHashSet(StringComparer.Ordinal)));
                                return true;
                            }
                            catch (Exception retryErr)
                            {
                                if (_closed) return false;
                                if (IsOfflineError(retryErr))
                                {
                                    _serverTask[id] = current;
                                    if (Find(id) is { } live) Put(live with { Rev = current.Rev });
                                    EnqueueOffline(new TodoPendingOp
                                    {
                                        Kind = TodoPendingOpKind.Patch,
                                        TargetId = id,
                                        Fields = resolved.Fields,
                                        BaseFields = BaselineFields(resolved.Fields, current),
                                        Touch = touch,
                                    }, about: id);
                                    return true;
                                }
                                if (TasksApi.Conflict(retryErr) is { } newer)
                                {
                                    ApplyConflictSnapshot(newer, id, token, resolved.Fields.Select(kv => kv.Key), touch);
                                    return false;
                                }
                                if (KanbanRest.Status(retryErr) == 404)
                                {
                                    _tasks.RemoveAll(t => t.Id == id);
                                    Save();
                                    Raise();
                                    Tell(TasksCopy.DeletedElsewhere, id);
                                    return false;
                                }
                                if (_taskEditToken.GetValueOrDefault(id) == token) Put(current);
                                else RestoreFields(resolved.Fields.Select(kv => kv.Key), current, id, touch);
                                Save();
                                Raise();
                                Tell(TasksCopy.CouldNotSave(KanbanRest.Reason(retryErr)), id);
                                return false;
                            }
                        }
                        ApplyConflictSnapshot(current, id, token, sendFields.Select(kv => kv.Key), touch);
                        return false;
                    }
                    if (KanbanRest.Status(e) == 404)
                    {
                        _tasks.RemoveAll(t => t.Id == id);
                        Save();
                        Raise();
                        Tell(TasksCopy.DeletedElsewhere, id);
                        return false;
                    }
                    if (_taskEditToken.GetValueOrDefault(id) == token) Put(@base);
                    else RestoreFields(sendFields.Select(kv => kv.Key), @base, id, touch);
                    Raise();
                    Tell(TasksCopy.CouldNotSave(KanbanRest.Reason(e)), id);
                    return false;
                }
            }
            finally { End(id); }
        });
    }

    private void ApplyConflictSnapshot(TodoTask current, string id, int token, IEnumerable<string> keys, bool touch)
    {
        _serverTask[id] = current;
        if (_taskEditToken.GetValueOrDefault(id) == token) Put(current);
        else RestoreFields(keys, current, id, touch);
        Save();
        Raise();
        Tell(TasksCopy.ChangedElsewhere, id);
    }

    /// Accepts a bot's suggested title conditionally on the exact revision shown (never retries on 409).
    public async Task<bool> AcceptSuggestedTitleAsync(string id, string suggestion, string forTitle)
    {
        if (Refuse(id)) return false;
        if (_inFlight.ContainsKey(id))
        {
            Tell("This task is being saved. Try again in a moment.", id);
            return false;
        }
        if (Find(id) is not { } @base || TodoIds.IsLocal(id)
            || !string.Equals(@base.Title, forTitle, StringComparison.Ordinal)
            || !string.Equals(TodoViews.CurrentSuggestedTitle(@base), suggestion, StringComparison.Ordinal))
        {
            Tell("This suggestion is no longer current.", id);
            return false;
        }
        Begin(id);
        try
        {
            var answer = await Api.PatchAsync(id, @base.Rev, new JsonObject { ["title"] = suggestion });
            Put(answer);
            Save();
            Raise();
            if (!string.Equals(answer.Title, suggestion, StringComparison.Ordinal))
            {
                Tell("Couldn’t save the suggested title. Showing the saved task.", id);
                return false;
            }
            return true;
        }
        catch (Exception e)
        {
            if (TasksApi.Conflict(e) is { } current)
            {
                Put(current);
                Save();
                Raise();
                Tell(TasksCopy.ChangedElsewhere, id);
            }
            else if (KanbanRest.Status(e) == 404)
            {
                _tasks.RemoveAll(t => t.Id == id);
                Save();
                Raise();
                Tell(TasksCopy.DeletedElsewhere, id);
            }
            else
            {
                Tell($"Couldn’t save the suggested title. {KanbanRest.Reason(e)}", id);
            }
            return false;
        }
        finally { End(id); }
    }

    public Task<bool> KeepAsync(string id) => PatchAsync(id, new JsonObject(), touch: true);
    public Task<bool> SetGoalAsync(string taskId, string? goal, string? milestone = null) =>
        PatchAsync(taskId, GoalViews.Assign(goal, milestone, Goals));
    public Task<bool> SetDoneAsync(string id, bool done) => PatchAsync(id, new JsonObject { ["status"] = done ? "done" : "open" });

    public Task<bool> SetStepAsync(string taskId, string step, bool done)
    {
        if (Find(taskId) is not { } task) return Task.FromResult(false);
        return PatchAsync(taskId, new JsonObject { ["steps"] = TodoWire.Steps(task.Steps.Select(s => s.Id == step ? s with { Done = done } : s)) });
    }

    public Task<bool> EditStepAsync(string taskId, string stepId, string title)
    {
        var clean = title.Trim();
        if (clean.Length == 0 || Find(taskId) is not { } task) return Task.FromResult(false);
        return PatchAsync(taskId, new JsonObject { ["steps"] = TodoWire.Steps(task.Steps.Select(s => s.Id == stepId ? s with { Title = clean } : s)) });
    }

    public Task<bool> DeleteStepAsync(string taskId, string stepId)
    {
        if (Find(taskId) is not { } task) return Task.FromResult(false);
        return PatchAsync(taskId, new JsonObject { ["steps"] = TodoWire.Steps(task.Steps.Where(s => s.Id != stepId)) });
    }

    public Task<bool> MoveStepAsync(string taskId, string stepId, int offset)
    {
        if (Find(taskId) is not { } task) return Task.FromResult(false);
        var list = task.Steps.ToList();
        var at = list.FindIndex(s => s.Id == stepId);
        var target = at + offset;
        if (at < 0 || target < 0 || target >= list.Count) return Task.FromResult(false);
        (list[at], list[target]) = (list[target], list[at]);
        return PatchAsync(taskId, new JsonObject { ["steps"] = TodoWire.Steps(list) });
    }

    public Task<bool> ReorderStepAsync(string taskId, string fromStepId, string toStepId)
    {
        if (fromStepId == toStepId || Find(taskId) is not { } task) return Task.FromResult(false);
        var list = task.Steps.ToList();
        var from = list.FindIndex(s => s.Id == fromStepId);
        var to = list.FindIndex(s => s.Id == toStepId);
        if (from < 0 || to < 0) return Task.FromResult(false);
        var item = list[from];
        list.RemoveAt(from);
        list.Insert(to, item);
        return PatchAsync(taskId, new JsonObject { ["steps"] = TodoWire.Steps(list) });
    }

    public Task<bool> SetStepWhoAsync(string taskId, string stepId, string who)
    {
        if (Find(taskId) is not { } task) return Task.FromResult(false);
        var nextWho = who == "bot" ? "bot" : "me";
        return PatchAsync(taskId, new JsonObject { ["steps"] = TodoWire.Steps(task.Steps.Select(s => s.Id == stepId ? s with { Who = nextWho } : s)) });
    }

    /// Promotes a step into its own top-level task (inheriting list/goal/milestone & bot when assigned to the bot) and
    /// removes the step from the parent task. Returns the created task, or null on failure.
    public async Task<TodoTask?> PromoteStepAsync(string taskId, string stepId)
    {
        if (Refuse(taskId) || Find(taskId) is not { } parent) return null;
        if (parent.Steps.FirstOrDefault(s => s.Id == stepId) is not { } step) return null;
        var isBotStep = step.Who == "bot" && parent.Helper != null;
        var body = TodoWire.NewTask(
            title: step.Title,
            who: isBotStep ? TodoWho.Bot : TodoWho.Me,
            bot: isBotStep ? parent.Helper : null,
            due: null,
            repeatRule: null,
            prep: false,
            notes: "",
            steps: [],
            sourceKind: "app",
            fieldsSupported: FieldsSupported,
            goal: GoalsSupported ? parent.Goal : null,
            milestone: GoalsSupported ? parent.Milestone : null);
        if (parent.Section != null) body["section"] = parent.Section;
        var created = await AddAsync(body);
        if (created == null) return null;
        await DeleteStepAsync(taskId, stepId);
        return created;
    }

    /// Reschedules one or more tasks onto `date` (null clears due date). When `preserveTime` is true, each task with an
    /// existing due time keeps its hour and minute on the new day.
    public async Task<bool> RescheduleAsync(
        IReadOnlyList<string> ids,
        DateTimeOffset? date,
        bool hasTime = false,
        bool preserveTime = false,
        TimeZoneInfo? zone = null)
    {
        if (Refuse()) return false;
        var tz = zone ?? TimeZoneInfo.Local;
        var writes = new List<Task<bool>>();
        foreach (var id in ids)
        {
            if (Find(id) is not { } task) continue;
            string? wire = null;
            if (date is { } day)
                wire = preserveTime
                    ? TodoViews.RescheduledDue(task, day, tz, preserveTime: true)
                    : TodoDates.Wire(day, hasTime, tz);
            writes.Add(PatchAsync(id, new JsonObject { ["due"] = wire }));
        }
        var ok = true;
        foreach (var one in await Task.WhenAll(writes)) ok &= one;
        return ok;
    }

    public async Task<bool> SetPriorityAsync(IReadOnlyList<string> ids, int priority)
    {
        if (Refuse() || !FieldsSupported) return false;
        var writes = new List<Task<bool>>();
        foreach (var id in ids)
            if (Find(id) != null) writes.Add(PatchAsync(id, new JsonObject { ["priority"] = priority }));
        var ok = true;
        foreach (var one in await Task.WhenAll(writes)) ok &= one;
        return ok;
    }

    public async Task<bool> SetGoalBatchAsync(IReadOnlyList<string> ids, string? goal, string? milestone = null)
    {
        if (Refuse() || !GoalsSupported) return false;
        var fields = GoalViews.Assign(goal, milestone, Goals);
        var writes = new List<Task<bool>>();
        foreach (var id in ids)
            if (Find(id) != null) writes.Add(PatchAsync(id, (JsonObject)fields.DeepClone()));
        var ok = true;
        foreach (var one in await Task.WhenAll(writes)) ok &= one;
        return ok;
    }

    /// Duplicates a task (fresh unticked steps, same metadata, new open task).
    public Task<TodoTask?> DuplicateAsync(string id)
    {
        if (Find(id) is not { } source) return Task.FromResult<TodoTask?>(null);
        return AddAsync(DuplicateBody(source, FieldsSupported, GoalsSupported));
    }

    /// Deletes a task (shown gone at once; queued offline on transport failure; put back if the server refuses).
    public async Task<bool> DeleteAsync(string id)
    {
        if (Refuse(id)) return false;
        var at = _tasks.FindIndex(t => t.Id == id);
        var removed = at >= 0 ? _tasks[at] : null;
        if (removed != null) { _tasks.RemoveAt(at); Raise(); }
        _addedAt.Remove(id);
        if (TodoIds.IsLocal(id) && PendingTaskIds().Contains(id))
        {
            EnqueueOffline(new TodoPendingOp { Kind = TodoPendingOpKind.Delete, TargetId = id }, quiet: true, about: id);
            return true;
        }
        _deletedAt[id] = long.MaxValue;
        _deleting.Add(id);
        Begin(id);
        return await SerializeTaskWriteAsync(id, async () =>
        {
            try
            {
                if (_closed) return false;
                await Api.DeleteAsync(id);
                if (_closed) return false;
                _deletedAt[id] = ++_writes;
                Save();
                TriggerReconcilePrep(PrepBots(removed, null, null));
                return true;
            }
            catch (Exception e)
            {
                if (_closed) return false;
                if (KanbanRest.Status(e) == 404) { _deletedAt[id] = ++_writes; Save(); return true; }
                if (IsOfflineError(e))
                {
                    _deletedAt.Remove(id);
                    EnqueueOffline(new TodoPendingOp { Kind = TodoPendingOpKind.Delete, TargetId = id }, about: id);
                    return true;
                }
                _deletedAt.Remove(id);
                if (removed != null && !_tasks.Any(t => t.Id == id)) { _tasks.Insert(Math.Min(at, _tasks.Count), removed); Raise(); }
                Tell(TasksCopy.CouldNotDelete(KanbanRest.Reason(e)), id);
                return false;
            }
            finally
            {
                _deleting.Remove(id);
                End(id);
            }
        });
    }

    public async Task<bool> SaveSettingsAsync(TodoSettings next)
    {
        if (Refuse()) return false;
        var before = Settings;
        Settings = next;
        if (before.Enabled != next.Enabled) EnabledChanged?.Invoke(next.Enabled);
        Raise();
        try
        {
            Settings = await Api.SaveSettingsAsync(next);
            Save();
            Raise();
            return true;
        }
        catch (Exception e)
        {
            Settings = before;
            if (before.Enabled != next.Enabled) EnabledChanged?.Invoke(before.Enabled);
            Raise();
            Tell(TasksCopy.CouldNotSaveSettings(KanbanRest.Reason(e)));
            return false;
        }
    }

    public Task<bool> SetSortAsync(string sort) =>
        Settings.Sort == sort ? Task.FromResult(true) : SaveSettingsAsync(Settings with { Sort = sort });

    public async Task<bool> MoveAsync(IReadOnlyList<string> ids, string? section, double? position = null)
    {
        if (Refuse()) return false;
        if (!SectionsSupported) { Tell(SectionsNeedAddOn); return false; }
        var next = position ?? (_tasks.Where(t => t.Section == section && !ids.Contains(t.Id)).Select(t => (double?)t.Order).Max()
            ?? DateTimeOffset.Now.ToUnixTimeMilliseconds() / 1000.0) + 1;
        var writes = new List<Task<bool>>();
        foreach (var id in ids)
        {
            if (Find(id) is not { } task) continue;
            var fields = new JsonObject { ["position"] = next };
            if (task.Section != section) fields["section"] = section;
            next += 1;
            writes.Add(PatchAsync(id, fields));
        }
        var moved = true;
        foreach (var ok in await Task.WhenAll(writes)) moved &= ok;
        return moved;
    }

    // ------------------------------------------------------------------ Sections (Lists)

    public async Task<IReadOnlyList<TodoUserSection>?> SaveSectionsAsync(IReadOnlyList<TodoUserSection> next)
    {
        if (Refuse()) return null;
        if (!SectionsSupported) { Tell(SectionsNeedAddOn); return null; }
        var before = Sections;
        var kept = next.Select(s => s.Id).ToHashSet();
        var clearedSections = new Dictionary<string, string>(StringComparer.Ordinal);
        Sections = [.. next];
        _tasks = [.. _tasks.Select(t =>
        {
            if (t.Section is { } sid && !kept.Contains(sid))
            {
                clearedSections[t.Id] = sid;
                return t with { Section = null };
            }
            return t;
        })];
        Raise();
        _sectionsWriting = true;
        try
        {
            var saved = await Api.SaveSectionsAsync(next);
            if (_closed) return null;
            Sections = saved;
            Save();
            Raise();
            _sectionsWriting = false;
            _ = RefreshAsync(force: true);
            return saved;
        }
        catch (Exception e)
        {
            if (_closed) return null;
            if (IsOfflineError(e))
            {
                EnqueueOffline(new TodoPendingOp { Kind = TodoPendingOpKind.SaveSections, Sections = [.. next] });
                return next;
            }
            Sections = before;
            if (clearedSections.Count > 0)
            {
                _tasks = [.. _tasks.Select(t => t.Section == null && clearedSections.TryGetValue(t.Id, out var old) ? t with { Section = old } : t)];
            }
            Raise();
            Tell(TodoListCopy.CouldNotSaveSections(KanbanRest.Reason(e)));
            return null;
        }
        finally { _sectionsWriting = false; }
    }

    public async Task<TodoUserSection?> AddSectionAsync(string name)
    {
        if (TodoListCopy.CleanName(name) is not { } clean) return null;
        var draft = new TodoUserSection(TodoIds.Local(), clean) { Color = ListsSupported ? TodoListColors.Next(Sections) : null };
        if (await SaveSectionsAsync([.. Sections, draft]) is not { } saved) return null;
        return saved.LastOrDefault(s => s.Name == draft.Name) ?? saved.LastOrDefault();
    }

    public async Task<bool> RenameSectionAsync(string id, string name)
    {
        if (TodoListCopy.CleanName(name) is not { } clean || !Sections.Any(s => s.Id == id)) return false;
        return await SaveSectionsAsync([.. Sections.Select(s => s.Id == id ? s with { Name = clean } : s)]) != null;
    }

    public async Task<bool> MoveSectionAsync(string id, int offset)
    {
        var next = Sections.ToList();
        var at = next.FindIndex(s => s.Id == id);
        if (at < 0 || at + offset < 0 || at + offset >= next.Count) return false;
        (next[at], next[at + offset]) = (next[at + offset], next[at]);
        return await SaveSectionsAsync(next) != null;
    }

    public async Task<bool> SaveSectionAsync(TodoUserSection section)
    {
        if (!Sections.Any(s => s.Id == section.Id)) return false;
        return await SaveSectionsAsync([.. Sections.Select(s => s.Id == section.Id ? section : s)]) != null;
    }

    public async Task<bool> DeleteSectionAsync(string id) =>
        Sections.Any(s => s.Id == id) && await SaveSectionsAsync([.. Sections.Where(s => s.Id != id)]) != null;

    // ------------------------------------------------------------------ Attachments & Offers

    public async Task<bool> AttachFileAsync(string taskId, string fileName, byte[] bytes)
    {
        if (bytes.Length > FileLimit) { Tell("That file is over 10 MB. A task takes files up to 10 MB.", taskId); return false; }
        if (Refuse(taskId) || Find(taskId) == null) return false;
        if (TodoIds.IsLocal(taskId)) { Tell(TasksCopy.StillBeingAdded, taskId); return false; }
        var token = NextEditToken(taskId);
        Begin(taskId);
        return await SerializeTaskWriteAsync(taskId, async () =>
        {
            try
            {
                var answer = await Api.AttachFileAsync(taskId, fileName, bytes);
                _serverTask[taskId] = answer;
                if (_taskEditToken.GetValueOrDefault(taskId) == token) Put(answer);
                else if (Find(taskId) is { } live) Put(live with { Rev = answer.Rev, Made = answer.Made });
                Save();
                Raise();
                return true;
            }
            catch (Exception e)
            {
                Tell($"Couldn’t attach file. {KanbanRest.Reason(e)}", taskId);
                return false;
            }
            finally { End(taskId); }
        });
    }

    public async Task<bool> AttachLinkAsync(string taskId, string title, string url)
    {
        if (Refuse(taskId) || Find(taskId) == null) return false;
        if (TodoIds.IsLocal(taskId)) { Tell(TasksCopy.StillBeingAdded, taskId); return false; }
        if (TodoMade.ValidLinkUrl(url) is not { } validUrl) { Tell("Enter a valid http:// or https:// link.", taskId); return false; }
        var token = NextEditToken(taskId);
        Begin(taskId);
        return await SerializeTaskWriteAsync(taskId, async () =>
        {
            try
            {
                var answer = await Api.AttachLinkAsync(taskId, string.IsNullOrWhiteSpace(title) ? validUrl : title.Trim(), validUrl);
                _serverTask[taskId] = answer;
                if (_taskEditToken.GetValueOrDefault(taskId) == token) Put(answer);
                else if (Find(taskId) is { } live) Put(live with { Rev = answer.Rev, Made = answer.Made });
                Save();
                Raise();
                return true;
            }
            catch (Exception e)
            {
                Tell($"Couldn’t attach link. {KanbanRest.Reason(e)}", taskId);
                return false;
            }
            finally { End(taskId); }
        });
    }

    public async Task<bool> DetachMadeAsync(string taskId, string madeId)
    {
        if (Refuse(taskId) || Find(taskId) is not { } @base) return false;
        var removedItem = @base.Made.FirstOrDefault(m => m.Id == madeId);
        var removedIdx = @base.Made.ToList().FindIndex(m => m.Id == madeId);
        var token = NextEditToken(taskId);
        Put(@base with { Made = [.. @base.Made.Where(m => m.Id != madeId)] });
        Raise();
        Begin(taskId);
        return await SerializeTaskWriteAsync(taskId, async () =>
        {
            try
            {
                var answer = await Api.DetachMadeAsync(taskId, madeId);
                _serverTask[taskId] = answer;
                if (_taskEditToken.GetValueOrDefault(taskId) == token) Put(answer);
                else if (Find(taskId) is { } live) Put(live with { Rev = answer.Rev, Made = answer.Made });
                Save();
                Raise();
                return true;
            }
            catch (Exception e)
            {
                if (_taskEditToken.GetValueOrDefault(taskId) == token) Put(@base);
                else if (Find(taskId) is { } live && removedItem != null && !live.Made.Any(m => m.Id == madeId))
                {
                    var list = live.Made.ToList();
                    list.Insert(Math.Min(removedIdx >= 0 ? removedIdx : list.Count, list.Count), removedItem);
                    Put(live with { Made = list });
                }
                Raise();
                Tell($"Couldn’t remove attachment. {KanbanRest.Reason(e)}", taskId);
                return false;
            }
            finally { End(taskId); }
        });
    }

    public async Task<bool> KeepTaskOpenAsync(string taskId)
    {
        if (Refuse(taskId) || Find(taskId) is not { } @base) return false;
        if (TodoIds.IsLocal(taskId)) { Tell(TasksCopy.StillBeingAdded, taskId); return false; }
        var token = NextEditToken(taskId);
        if (@base.Offer != null)
        {
            Put(@base with { Offer = @base.Offer with { Kept = true } });
            Raise();
        }
        Begin(taskId);
        return await SerializeTaskWriteAsync(taskId, async () =>
        {
            try
            {
                var liveBase = _serverTask.GetValueOrDefault(taskId) ?? @base;
                var answer = await Api.KeepTaskOpenAsync(taskId, liveBase.Rev);
                _serverTask[taskId] = answer;
                if (_taskEditToken.GetValueOrDefault(taskId) == token) Put(answer);
                else if (Find(taskId) is { } live) Put(live with { Rev = answer.Rev, Offer = answer.Offer });
                Save();
                Raise();
                return true;
            }
            catch (Exception e)
            {
                if (TasksApi.Conflict(e) is { } current)
                {
                    var fields = new JsonObject { ["keep_open"] = true };
                    if (TodoEdits.Resolve(@base, current, fields) is { } rev)
                    {
                        try
                        {
                            var answer = await Api.KeepTaskOpenAsync(taskId, rev);
                            _serverTask[taskId] = answer;
                            Put(answer);
                            Save();
                            Raise();
                            return true;
                        }
                        catch (Exception) { }
                    }
                    Put(current);
                    Save();
                    Raise();
                    Tell(TasksCopy.ChangedElsewhere, taskId);
                    return false;
                }
                Put(@base);
                Raise();
                Tell($"Couldn’t keep task open. {KanbanRest.Reason(e)}", taskId);
                return false;
            }
            finally { End(taskId); }
        });
    }

    public async Task<TodoOfferAnswer?> AnswerOfferAsync(
        string offerId,
        TodoOfferAction action,
        bool list = true,
        bool plan = true,
        bool inGoal = true)
    {
        if (Refuse()) return null;
        var btn = new TodoOfferButton(action, "", MakesList: list, Plan: plan, InGoal: inGoal);
        var before = Offers.FirstOrDefault(o => o.Id == offerId);
        var isGoal = before?.IsGoal == true;
        var wireAction = btn.WireAction;
        var wireList = btn.WireList;
        var wirePlan = btn.WirePlan;
        var wireInGoal = btn.WireInGoal;

        if (before != null)
        {
            var shown = wireAction switch
            {
                "accept" when before.IsGoal => before.Kind == "plan" && !wirePlan
                    ? before with { State = "declined" }
                    : before with { State = "accepted", WithPlan = wirePlan, InGoal = wireInGoal },
                "accept" => before with { State = "accepted", Listed = wireList || !before.IsNew },
                "decline" => before with { State = "declined" },
                "move" => before with { MoveState = "moved" },
                "leave" => before with { MoveState = "left" },
                "undo" => before with { State = "undone" },
                _ => before,
            };
            Offers = [.. Offers.Select(o => o.Id == offerId ? shown : o)];
            Raise();
        }

        _offersWriting++;
        var holdingWrite = true;
        try
        {
            var sendGoalFlags = isGoal || action is TodoOfferAction.AcceptNoPlan or TodoOfferAction.AcceptJustTasks || !plan || !inGoal;
            var answer = await Api.AnswerOfferAsync(
                offerId,
                wireAction,
                list: wireList,
                plan: sendGoalFlags ? wirePlan : null,
                inGoal: sendGoalFlags ? wireInGoal : null);

            foreach (var added in answer.AddedTasks) Put(added);
            if (answer.Offer is { } updated)
                Offers = [.. Offers.Select(o => o.Id == offerId ? updated : o)];
            else
                Offers = [.. Offers.Where(o => o.Id != offerId)];
            if (!_sectionsWriting && answer.HasSections)
                Sections = answer.Sections;
            if (answer.Goals is { } goals)
            {
                GoalsSupported = true;
                Goals = goals;
            }
            else if (answer.UpdatedGoal is { } g)
            {
                PutGoal(g);
            }
            Save();
            Raise();

            // [goals set-up] This device took a plan: notify listeners so the goal's lead is told once.
            if (action == TodoOfferAction.Accept && wirePlan && answer.Offer is { Kind: "plan", State: "accepted" } takenOffer)
                PlanTaken?.Invoke(takenOffer);

            _offersWriting--;
            holdingWrite = false;
            await RefreshAsync(force: true);
            return answer;
        }
        catch (Exception e)
        {
            if (IsOfflineError(e))
            {
                _offersWriting--;
                holdingWrite = false;
                EnqueueOffline(new TodoPendingOp
                {
                    Kind = TodoPendingOpKind.AnswerOffer,
                    TargetId = offerId,
                    OfferAction = action,
                    OfferList = wireList,
                    GoalPlan = isGoal ? wirePlan : null,
                    GoalInGoal = isGoal ? wireInGoal : null,
                });
                return new TodoOfferAnswer(offer: Offers.FirstOrDefault(o => o.Id == offerId));
            }
            if (before != null)
                Offers = [.. Offers.Select(o => o.Id == offerId ? before : o)];
            _offersWriting--;
            holdingWrite = false;
            Raise();
            if (KanbanRest.Status(e) == 409)
            {
                Tell("That was already answered on another device.");
                _ = RefreshAsync(force: true);
                return null;
            }
            Tell($"Couldn’t do that. {KanbanRest.Reason(e)}");
            return null;
        }
        finally
        {
            if (holdingWrite) _offersWriting--;
        }
    }

    // ------------------------------------------------------------------ Goals

    public Task<Goal?> AddGoalAsync(
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
        AddGoalFailure = null;
        var clean = title.Trim();
        if (clean.Length == 0) return Task.FromResult<Goal?>(null);
        var fields = GoalWire.CreateBody(clean, why, due, measure, lead, helpers, adds, review, knownToAll, color, milestones);
        return AddGoalAsync(fields);
    }

    public async Task<Goal?> AddGoalAsync(JsonObject fields)
    {
        AddGoalFailure = null;
        if (ReadOnlyGateway) { AddGoalFailure = KanbanRest.ReadOnlyNotice; return null; }
        if (!GoalsSupported) { AddGoalFailure = TasksCopy.GoalsNeedAddOn; return null; }
        try
        {
            var made = await Api.CreateGoalAsync(GoalWire.CreateBody(fields));
            var left = GoalWire.TeamLeft(fields, made);
            if (left.Count > 0)
            {
                try { made = await Api.PatchGoalAsync(made.Id, made.Rev, left); }
                catch (Exception) { }
            }
            Goals = [.. Goals.Where(g => g.Id != made.Id), made];
            _addedAt[made.Id] = ++_writes;
            Save();
            Raise();
            return made;
        }
        catch (Exception e)
        {
            AddGoalFailure = KanbanRest.Reason(e);
            return null;
        }
    }

    public Task<Goal?> CreateGoalAsync(JsonObject fields) => AddGoalAsync(fields);

    public Task<Goal?> CreateGoalAsync(
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
        IEnumerable<GoalMilestone>? milestones = null) =>
        AddGoalAsync(title, why, due, measure, lead, helpers, adds, review, knownToAll, color, milestones);

    private void PutGoal(Goal goal)
    {
        var list = Goals.ToList();
        var at = list.FindIndex(g => g.Id == goal.Id);
        if (at >= 0) list[at] = goal; else list.Add(goal);
        Goals = list;
    }

    public async Task<bool> PatchGoalAsync(string goalId, JsonObject fields)
    {
        if (Refuse(goalId) || FindGoal(goalId) is not { } @base) return false;
        if (GoalWire.Applying(fields, @base) is { } shown) { PutGoal(shown); Raise(); }
        _goalsInFlight[goalId] = _goalsInFlight.GetValueOrDefault(goalId) + 1;
        try
        {
            PutGoal(await Api.PatchGoalAsync(goalId, @base.Rev, fields));
            Save();
            Raise();
            return true;
        }
        catch (Exception e)
        {
            if (TasksApi.GoalConflict(e) is { } current)
            {
                if (GoalWire.Resolve(@base, current, fields) is { } rev)
                {
                    try { PutGoal(await Api.PatchGoalAsync(goalId, rev, fields)); Save(); Raise(); return true; }
                    catch (Exception) { }
                }
                PutGoal(current);
                Save();
                Raise();
                Tell("This goal changed somewhere else. Showing the latest.", goalId);
                return false;
            }
            if (KanbanRest.Status(e) == 404)
            {
                Goals = [.. Goals.Where(g => g.Id != goalId)];
                Save();
                Raise();
                Tell("This goal was deleted somewhere else.", goalId);
                return false;
            }
            PutGoal(@base);
            Raise();
            Tell($"Couldn’t save goal. {KanbanRest.Reason(e)}", goalId);
            return false;
        }
        finally
        {
            var left = _goalsInFlight.GetValueOrDefault(goalId, 1) - 1;
            if (left > 0) _goalsInFlight[goalId] = left; else _goalsInFlight.Remove(goalId);
        }
    }

    public async Task<bool> DeleteGoalAsync(string goalId)
    {
        if (Refuse(goalId) || FindGoal(goalId) == null) return false;
        var before = Goals;
        Goals = [.. Goals.Where(g => g.Id != goalId)];
        Raise();
        try
        {
            await Api.DeleteGoalAsync(goalId);
            Save();
            return true;
        }
        catch (Exception e)
        {
            if (KanbanRest.Status(e) == 404) { Save(); return true; }
            Goals = before;
            Raise();
            Tell($"Couldn’t delete goal. {KanbanRest.Reason(e)}", goalId);
            return false;
        }
    }

    public Task<bool> SetGoalMilestoneDoneAsync(string goalId, string milestoneId, bool done)
    {
        if (FindGoal(goalId) is not { } goal) return Task.FromResult(false);
        var now = TodoDates.Now();
        var updated = goal.Milestones.Select(m => m.Id == milestoneId ? m with { Done = done, DoneAt = done ? now : null } : m);
        return PatchGoalAsync(goalId, new JsonObject { ["milestones"] = GoalWire.Milestones(updated) });
    }

    public Task<bool> AddGoalMilestoneAsync(string goalId, string title, string? due = null)
    {
        var clean = title.Trim();
        if (clean.Length == 0 || FindGoal(goalId) is not { } goal) return Task.FromResult(false);
        var next = goal.Milestones.Append(new GoalMilestone(TodoIds.Make(), clean, due, Done: false));
        return PatchGoalAsync(goalId, new JsonObject { ["milestones"] = GoalWire.Milestones(next) });
    }

    public Task<bool> EditGoalMilestoneAsync(string goalId, string milestoneId, string? title = null, string? due = null, bool clearDue = false)
    {
        if (FindGoal(goalId) is not { } goal) return Task.FromResult(false);
        var updated = goal.Milestones.Select(m =>
        {
            if (m.Id != milestoneId) return m;
            var nextTitle = title != null && title.Trim().Length > 0 ? title.Trim() : m.Title;
            var nextDue = clearDue ? null : (due ?? m.Due);
            return m with { Title = nextTitle, Due = nextDue };
        });
        return PatchGoalAsync(goalId, new JsonObject { ["milestones"] = GoalWire.Milestones(updated) });
    }

    public Task<bool> MoveGoalMilestoneAsync(string goalId, string milestoneId, int offset)
    {
        if (FindGoal(goalId) is not { } goal) return Task.FromResult(false);
        var list = goal.Milestones.ToList();
        var at = list.FindIndex(m => m.Id == milestoneId);
        var target = at + offset;
        if (at < 0 || target < 0 || target >= list.Count) return Task.FromResult(false);
        (list[at], list[target]) = (list[target], list[at]);
        return PatchGoalAsync(goalId, new JsonObject { ["milestones"] = GoalWire.Milestones(list) });
    }

    public Task<bool> DeleteGoalMilestoneAsync(string goalId, string milestoneId)
    {
        if (FindGoal(goalId) is not { } goal) return Task.FromResult(false);
        var next = goal.Milestones.Where(m => m.Id != milestoneId);
        return PatchGoalAsync(goalId, new JsonObject { ["milestones"] = GoalWire.Milestones(next) });
    }

    public Task<bool> UpdateGoalMeasureAsync(string goalId, GoalMeasure? measure) =>
        PatchGoalAsync(goalId, new JsonObject { ["measure"] = measure?.Wire() });

    public Task<bool> KeepGoalGoingAsync(string goalId) =>
        GoalBotsSupported
            ? PatchGoalAsync(goalId, new JsonObject { ["keep"] = true })
            : Task.FromResult(false);

    public Task<bool> AnswerGoalLooksDoneAsync(string goalId, bool achieved) =>
        PatchGoalAsync(goalId, new JsonObject { ["offer_answer"] = achieved ? "done" : "keep" });
}
