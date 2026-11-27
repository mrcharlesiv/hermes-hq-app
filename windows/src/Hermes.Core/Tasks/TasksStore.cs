using System.Text.Json.Nodes;
using Hermes.Core.Kanban;
using Hermes.Core.Net;

namespace Hermes.Core.Tasks;

/// The add-on's routes (HermesKit/Pages/Tasks/TasksStore.swift TasksAPI; docs/tasks.md "Routes").
public sealed class TasksApi(IPagesRest rest)
{
    public const string Route = "/api/plugins/hermes-hq-push";
    public const string Base = Route + "/tasks";
    public IPagesRest Rest { get; } = rest;

    private static string PathOf(string id) => Base + "/" + KanbanRest.Segment(id);

    public async Task<TodoListAnswer> ListAsync(int? since, CancellationToken ct = default) =>
        TodoListAnswer.From(await Rest.JsonAsync(HttpMethod.Get, Base, since is { } s ? [new("since", s.ToString())] : null, ct: ct));

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

    /// `PUT /tasks/sections` (hermes-hq-push 0.9.36; TasksAPI.saveSections): your lists, the whole list in order. One
    /// left out is deleted; its tasks stay, in no list. The saved lists come back (new ones with their ids).
    public async Task<IReadOnlyList<TodoUserSection>> SaveSectionsAsync(IReadOnlyList<TodoUserSection> sections, CancellationToken ct = default)
    {
        var answer = await Rest.JsonAsync(HttpMethod.Put, Base + "/sections",
            body: new JsonObject { ["sections"] = new JsonArray([.. sections.Select(s => (JsonNode)s.Wire())]) }, ct: ct);
        return answer.Arr("sections") is { } saved ? [.. saved.Select(TodoUserSection.From).OfType<TodoUserSection>()]
            : throw new PagesMessageException("The gateway sent lists this app can’t read.");
    }

    /// [goals] `POST /goals` `{title, why?, …}`: the goal made (GoalsAPI.add; docs/goals.md "Routes").
    public async Task<Goal> CreateGoalAsync(JsonObject fields, CancellationToken ct = default) =>
        Goal.From(await Rest.JsonAsync(HttpMethod.Post, Route + "/goals", body: fields, ct: ct))
        ?? throw new PagesMessageException("The gateway sent a goal this app can’t read.");

    /// [goals-v2] `PATCH /goals/{id}` with `rev` and changed fields.
    public async Task<Goal> PatchGoalAsync(string goalId, int rev, JsonObject fields, CancellationToken ct = default)
    {
        var body = (JsonObject)fields.DeepClone();
        body["rev"] = rev;
        return GoalOf(await Rest.JsonAsync(HttpMethod.Patch, Route + "/goals/" + KanbanRest.Segment(goalId), body: body, ct: ct));
    }

    /// [goals-v2] `DELETE /goals/{id}`.
    public Task DeleteGoalAsync(string goalId, CancellationToken ct = default) =>
        Rest.JsonAsync(HttpMethod.Delete, Route + "/goals/" + KanbanRest.Segment(goalId), ct: ct);

    /// [tasks-v2] `POST /tasks/{id}/attach` with a file payload (`data` base64).
    public async Task<TodoTask> AttachFileAsync(string taskId, string fileName, byte[] bytes, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["kind"] = "file",
            ["name"] = fileName,
            ["data"] = Convert.ToBase64String(bytes),
        };
        return TaskOf(await Rest.JsonAsync(HttpMethod.Post, PathOf(taskId) + "/attach", body: body, ct: ct));
    }

    /// [tasks-v2] `POST /tasks/{id}/attach` with a web link (`title`, `url`).
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

    /// [tasks-v2] `DELETE /tasks/{id}/made/{madeId}` removes one attachment/made item.
    public async Task<TodoTask> DetachMadeAsync(string taskId, string madeId, CancellationToken ct = default) =>
        TaskOf(await Rest.JsonAsync(HttpMethod.Delete, PathOf(taskId) + "/made/" + KanbanRest.Segment(madeId), ct: ct));

    /// [tasks-v2] Keeps a task open when dismissing a bot's close offer.
    public async Task<TodoTask> KeepTaskOpenAsync(string taskId, CancellationToken ct = default) =>
        TaskOf(await Rest.JsonAsync(HttpMethod.Post, PathOf(taskId) + "/keep-open", body: new JsonObject(), ct: ct));

    /// [tasks-v2] `POST /tasks/offers/{id}` with `{action: "accept"|"accept_no_list"|"decline"|"undo"}`.
    public async Task<TodoOfferAnswer> AnswerOfferAsync(string offerId, string action, CancellationToken ct = default) =>
        TodoOfferAnswer.From(await Rest.JsonAsync(HttpMethod.Post, Base + "/offers/" + KanbanRest.Segment(offerId),
            body: new JsonObject { ["action"] = action }, ct: ct));

    /// [tasks-v2] `GET /tasks/{id}/page` returns `{html, summary, next}` for the Task Page.
    public async Task<string?> GetTaskPageHtmlAsync(string taskId, CancellationToken ct = default)
    {
        var json = await Rest.JsonAsync(HttpMethod.Get, PathOf(taskId) + "/page", ct: ct);
        return json.Str("html") ?? json.Str("markdown") ?? json.Str("text");
    }

    /// [goals-v2] `GET /goals/{id}/page` returns `{html, summary, next}` for the Goal Page.
    public async Task<string?> GetGoalPageHtmlAsync(string goalId, CancellationToken ct = default)
    {
        var json = await Rest.JsonAsync(HttpMethod.Get, Route + "/goals/" + KanbanRest.Segment(goalId) + "/page", ct: ct);
        return json.Str("html") ?? json.Str("markdown") ?? json.Str("text");
    }

    /// [tasks-v2] `GET /tasks/ideas`.
    public async Task<TaskIdeasPage> GetIdeasAsync(CancellationToken ct = default) =>
        TaskIdeasPage.From(await Rest.JsonAsync(HttpMethod.Get, Base + "/ideas", ct: ct));

    /// [tasks-v2] `POST /tasks/ideas/{id}/add`.
    public async Task<TodoTask?> AddIdeaAsync(string ideaId, bool letBotStart = false, CancellationToken ct = default)
    {
        var body = new JsonObject { ["start"] = letBotStart };
        var json = await Rest.JsonAsync(HttpMethod.Post, Base + "/ideas/" + KanbanRest.Segment(ideaId) + "/add", body: body, ct: ct);
        return TodoTask.From(json) ?? TodoTask.From(json.Get("task"));
    }

    /// [tasks-v2] `POST /tasks/ideas/{id}/dismiss`.
    public Task DismissIdeaAsync(string ideaId, CancellationToken ct = default) =>
        Rest.JsonAsync(HttpMethod.Post, Base + "/ideas/" + KanbanRest.Segment(ideaId) + "/dismiss", body: new JsonObject(), ct: ct);

    /// [tasks-v2] `POST /tasks/ideas/{id}/restore`.
    public Task RestoreIdeaAsync(string ideaId, CancellationToken ct = default) =>
        Rest.JsonAsync(HttpMethod.Post, Base + "/ideas/" + KanbanRest.Segment(ideaId) + "/restore", body: new JsonObject(), ct: ct);

    /// [tasks-v2] `POST /tasks/ideas/run`.
    public Task LookForIdeasAsync(CancellationToken ct = default) =>
        Rest.JsonAsync(HttpMethod.Post, Base + "/ideas/run", body: new JsonObject(), ct: ct);

    public static Goal GoalOf(JsonNode? json) =>
        Goal.From(json) ?? Goal.From(json.Get("goal")) ?? Goal.From(json.Obj("detail").Get("goal"))
        ?? throw new PagesMessageException("The gateway sent a goal this app can’t read.");

    public static Goal? GoalConflict(Exception e)
    {
        if (e is not GatewayException { Code: "http", Status: 409 } g || J.Parse(g.Body ?? "") is not { } json) return null;
        try { return GoalOf(json); } catch (PagesMessageException) { return null; }
    }

    /// Does the add-on on the computer serve Tasks (`/status` says `tasks: true`)? null when it couldn't be asked.
    public async Task<bool?> AddOnServesTasksAsync(CancellationToken ct = default)
    {
        try { return (await Rest.JsonAsync(HttpMethod.Get, Route + "/status", timeout: TimeSpan.FromSeconds(15), ct: ct)).Bool("tasks") == true; }
        catch (GatewayException e) when (e.Code == "http") { return false; }
        catch (Exception) { return null; }
    }

    /// A route's task answer: the task itself, or `{task: …}` (a 409's `{detail: {task}}` too).
    public static TodoTask TaskOf(JsonNode? json) =>
        TodoTask.From(json) ?? TodoTask.From(json.Get("task")) ?? TodoTask.From(json.Obj("detail").Get("task"))
        ?? throw new PagesMessageException("The gateway sent a task this app can’t read.");

    /// A 409's current task, null for any other failure.
    public static TodoTask? Conflict(Exception e)
    {
        if (e is not GatewayException { Code: "http", Status: 409 } g || J.Parse(g.Body ?? "") is not { } json) return null;
        try { return TaskOf(json); } catch (PagesMessageException) { return null; }
    }
}

/// The Tasks page's data (HermesKit/Pages/Tasks/TasksStore.swift): the list read from the add-on (`?since=<rev>`
/// answers `unchanged` when nothing moved); optimistic writes that carry the task's rev, sent again on a 409 when the
/// other edit touched other fields, or giving way to it when it touched the same ones.
///
/// One thread only, as the Mac's TasksStore is @MainActor: call it from a thread with a SynchronizationContext that
/// runs posted work one at a time (the app's UI thread; MainLoop in the tests), and nothing here awaits with
/// ConfigureAwait(false), so every write's answer is put away on that thread too. Its state (the tasks, the writes on
/// their way) is plain lists and dictionaries: called from a thread with no such context, a Move of several tasks has
/// the first PATCH's answer handled on a pool thread while the next PATCH starts (TasksStoreThreadTests).
public sealed class TasksStore(TasksApi api)
{
    public TasksApi Api { get; } = api;
    public bool ReadOnlyGateway { get; set; }

    public IReadOnlyList<TodoTask> Tasks => _tasks;
    private List<TodoTask> _tasks = [];
    public TodoSettings Settings { get; private set; } = new();
    public IReadOnlyList<TodoUserSection> Sections { get; private set; } = [];
    public int Rev { get; private set; }
    public bool HasList { get; private set; }
    public bool Loading { get; private set; }
    public string? Error { get; private set; }
    /// The add-on on the computer is older than Tasks (or not there).
    public bool NeedsAddOn { get; private set; }
    public bool FieldsSupported { get; private set; }
    /// [tasks-v2] File attachments supported by the add-on (`GET /tasks` has `files: true`).
    public bool FilesSupported { get; private set; }
    /// [tasks-v2] Task & Goal pages supported by the add-on (`GET /tasks` has `pages: true`).
    public bool PagesSupported { get; private set; }
    /// [goals-v2] Bots on goals supported by the add-on (`GET /tasks` has `goal_bots: true`).
    public bool GoalBotsSupported { get; private set; }
    /// [tasks-v2] Pending offers from bots (`GET /tasks` has `offers`).
    public IReadOnlyList<TodoOffer> Offers { get; private set; } = [];
    /// [tasks-v2] Pending ideas count reported in `GET /tasks`.
    public int IdeasCount { get; private set; }
    /// The add-on keeps your lists (0.9.36+: `GET /tasks` has `sections`).
    public bool SectionsSupported { get; private set; }
    /// [task-lists] The add-on keeps a list's colour, icon, bot and rules (0.9.55+: `GET /tasks` has `lists: true`).
    public bool ListsSupported { get; private set; }
    /// [goals] Every goal, any status, as the last read sent them (TasksStore.swift `goals`).
    public IReadOnlyList<Goal> Goals { get; private set; } = [];
    /// [goals] The add-on keeps goals (0.9.65: `GET /tasks` has `goals`; TasksStore.swift `goalsSupported`).
    public bool GoalsSupported { get; private set; }
    /// [WIN-47] [goals-addon] Tasks work but the add-on keeps no goals: the Goals pill stays and says to update it
    /// (TasksStore.swift `goalsNeedAddOn`).
    public bool GoalsNeedAddOn => GoalsAddOn.NeedsAddOn(HasList, NeedsAddOn, GoalsSupported);
    public Goal? FindGoal(string id) => Goals.FirstOrDefault(g => g.Id == id);
    /// Why the last New Goal failed, for its own line (TasksStore.swift `addGoalFailure`).
    public string? AddGoalFailure { get; private set; }
    /// Your lists can be made, renamed, moved and deleted here (TaskViewsHeader.swift `editsLists`).
    public bool EditsLists => !ReadOnlyGateway && SectionsSupported;
    public const string SectionsNeedAddOn = "Sections need the newest HQ add-on on your computer (0.9.36 or later).";
    /// Why the last add failed, for New Task's own line.
    public string? AddFailure { get; private set; }

    public event Action? Changed;
    /// Something to tell (a refused or failed write), with the task it is about.
    public event Action<string, string?>? Notice;

    private readonly Dictionary<string, int> _inFlight = [];
    /// A lists save is on its way: a read that crosses it keeps the lists as shown.
    private bool _sectionsWriting;
    private int _readGeneration;
    /// This store's own adds and deletes, in the order they landed (or, for a delete, while it is on its way: MaxValue).
    /// A read that left before one landed can't know of it: its answer neither drops the added task nor brings the
    /// deleted one back. (New List reads the list again without waiting; a task added meanwhile used to vanish from
    /// the store until the next read, and Move To skipped it.)
    private long _writes;
    private readonly Dictionary<string, long> _addedAt = [];
    private readonly Dictionary<string, long> _deletedAt = [];

    public TodoTask? Find(string id) => _tasks.FirstOrDefault(t => t.Id == id);
    private void Raise() => Changed?.Invoke();
    private void Tell(string text, string? about = null) => Notice?.Invoke(text, about);

    /// Reads the list. `force` skips `?since=`.
    public async Task RefreshAsync(bool force = false)
    {
        var generation = ++_readGeneration;
        var leftAt = _writes;
        Loading = true;
        Raise();
        try
        {
            var answer = await Api.ListAsync(HasList && !force && Rev > 0 ? Rev : null);
            if (generation != _readGeneration) return;
            if (answer.Unchanged) { Error = null; NeedsAddOn = false; return; }
            if (answer.Tasks is not { } fresh)
            {
                // An add-on with no Tasks answers an empty object (or a page of its own).
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
            IdeasCount = answer.IdeasCount;
            Offers = answer.Offers ?? [];
            ListsSupported = answer.Lists;
            GoalsSupported = answer.Goals != null;
            // A goal added here after this read left isn't in its answer: kept, as an added task is (Adopt).
            var goals = answer.Goals ?? [];
            Goals = [.. goals, .. Goals.Where(g => _addedAt.GetValueOrDefault(g.Id) > leftAt && goals.All(f => f.Id != g.Id))];
            if (!_sectionsWriting)
            {
                Sections = answer.Sections ?? [];
                SectionsSupported = answer.Sections != null;
            }
            Adopt(fresh, answer.Rev, answer.Settings, leftAt);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            if (generation != _readGeneration) return;
            if (KanbanRest.IsUnknownRoute(e))
            {
                NeedsAddOn = await Api.AddOnServesTasksAsync() != true;
                Error = NeedsAddOn ? null : KanbanRest.Reason(e);
            }
            else Error = KanbanRest.Reason(e);
        }
        finally
        {
            if (generation == _readGeneration) { Loading = false; Raise(); }
        }
    }

    /// A read's list, keeping tasks with a write on its way and ones added here and not yet answered.
    private void Adopt(IReadOnlyList<TodoTask> fresh, int rev, TodoSettings? settings, long leftAt)
    {
        var next = fresh.Where(t => _deletedAt.GetValueOrDefault(t.Id) <= leftAt).ToList();
        var places = new Dictionary<string, int>();
        for (var i = 0; i < next.Count; i++) places.TryAdd(next[i].Id, i);
        foreach (var local in _tasks)
        {
            var inHand = _inFlight.ContainsKey(local.Id) || TodoIds.IsLocal(local.Id) || _addedAt.GetValueOrDefault(local.Id) > leftAt;
            if (places.TryGetValue(local.Id, out var at))
            {
                // A read that left before a change landed carries the task as it was (an older rev): it never takes
                // the change back.
                if (inHand || next[at].Rev < local.Rev) next[at] = local;
            }
            else if (inHand) next.Add(local);
        }
        _tasks = next;
        Rev = rev;
        if (settings != null) Settings = settings;
        HasList = true;
        // Only a read that left later answers from now on (an earlier one is overtaken by the generation): what landed
        // before this one left is in its answer, so it needs no guard any more.
        Forget(_addedAt, leftAt);
        Forget(_deletedAt, leftAt);
    }

    private static void Forget(Dictionary<string, long> landed, long leftAt)
    {
        foreach (var id in landed.Where(p => p.Value <= leftAt).Select(p => p.Key).ToList()) landed.Remove(id);
    }

    private bool Refuse(string? about = null)
    {
        if (!ReadOnlyGateway) return false;
        Tell(KanbanRest.ReadOnlyNotice, about);
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
        if (left > 0) _inFlight[id] = left; else _inFlight.Remove(id);
    }

    /// Adds a task: shown at once, then swapped for the gateway's. null when it failed, with the reason in AddFailure.
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
        if (TodoTask.From(TodoEdits.Reparse(draft)) is { } shown) { _tasks.Add(shown); Raise(); }
        try
        {
            var made = await Api.CreateAsync(fields);
            _tasks.RemoveAll(t => t.Id == localId);
            Put(made);
            _addedAt[made.Id] = ++_writes;
            Raise();
            return made;
        }
        catch (Exception e)
        {
            _tasks.RemoveAll(t => t.Id == localId);
            Raise();
            var reason = KanbanRest.Reason(e);
            AddFailure = reason;
            if (!quiet) Tell(TasksCopy.CouldNotAdd(reason));
            return null;
        }
    }

    /// [goals] New Goal: `POST /goals` with its name (and why, when there is one). The goal made, shown at once; null when
    /// it failed, with the reason in AddGoalFailure. The colour is left to the add-on (the first no active goal uses).
    public async Task<Goal?> AddGoalAsync(string title, string why = "")
    {
        AddGoalFailure = null;
        var clean = title.Trim();
        if (clean.Length == 0) return null;
        if (ReadOnlyGateway) { AddGoalFailure = KanbanRest.ReadOnlyNotice; return null; }
        if (!GoalsSupported) { AddGoalFailure = TasksCopy.GoalsNeedAddOn; return null; }
        var fields = new JsonObject { ["title"] = clean };
        if (why.Trim() is { Length: > 0 } reason) fields["why"] = reason;
        try
        {
            var made = await Api.CreateGoalAsync(fields);
            Goals = [.. Goals.Where(g => g.Id != made.Id), made];
            _addedAt[made.Id] = ++_writes;
            Raise();
            return made;
        }
        catch (Exception e)
        {
            AddGoalFailure = KanbanRest.Reason(e);
            return null;
        }
    }

    /// Changes a task's fields (wire names). The change shows at once; a 409 sends it again on the current rev when the
    /// other edit left these fields alone, and otherwise shows the current version.
    public async Task<bool> PatchAsync(string id, JsonObject fields)
    {
        if (Refuse(id) || Find(id) is not { } @base) return false;
        if (TodoIds.IsLocal(id)) { Tell(TasksCopy.StillBeingAdded, id); return false; }
        if (TodoEdits.Applying(fields, @base) is { } shown) { Put(shown); Raise(); }
        Begin(id);
        try
        {
            Put(await Api.PatchAsync(id, @base.Rev, fields));
            Raise();
            return true;
        }
        catch (Exception e)
        {
            if (TasksApi.Conflict(e) is { } current)
            {
                if (TodoEdits.Resolve(@base, current, fields) is { } rev)
                {
                    try { Put(await Api.PatchAsync(id, rev, fields)); Raise(); return true; }
                    catch (Exception) { }
                }
                Put(current);
                Raise();
                Tell(TasksCopy.ChangedElsewhere, id);
                return false;
            }
            if (KanbanRest.Status(e) == 404)
            {
                _tasks.RemoveAll(t => t.Id == id);
                Raise();
                Tell(TasksCopy.DeletedElsewhere, id);
                return false;
            }
            Put(@base);
            Raise();
            Tell(TasksCopy.CouldNotSave(KanbanRest.Reason(e)), id);
            return false;
        }
        finally { End(id); }
    }

    /// [WIN-47] Puts a task in a goal (null: no goal), under one of its milestones or none (TasksStore.swift `setGoal`).
    public Task<bool> SetGoalAsync(string taskId, string? goal, string? milestone = null) =>
        PatchAsync(taskId, GoalViews.Assign(goal, milestone, Goals));

    /// Ticks a task done (or opens it again). false when the gateway didn't take it (the task shows as it was).
    public Task<bool> SetDoneAsync(string id, bool done) => PatchAsync(id, new JsonObject { ["status"] = done ? "done" : "open" });

    public Task<bool> SetStepAsync(string taskId, string step, bool done)
    {
        if (Find(taskId) is not { } task) return Task.FromResult(false);
        return PatchAsync(taskId, new JsonObject { ["steps"] = TodoWire.Steps(task.Steps.Select(s => s.Id == step ? s with { Done = done } : s)) });
    }

    /// Deletes a task (shown gone at once; put back if the gateway refuses).
    public async Task<bool> DeleteAsync(string id)
    {
        if (Refuse(id)) return false;
        var at = _tasks.FindIndex(t => t.Id == id);
        var removed = at >= 0 ? _tasks[at] : null;
        if (removed != null) { _tasks.RemoveAt(at); Raise(); }
        _addedAt.Remove(id);
        _deletedAt[id] = long.MaxValue;
        try
        {
            await Api.DeleteAsync(id);
            _deletedAt[id] = ++_writes;
            return true;
        }
        catch (Exception e)
        {
            if (KanbanRest.Status(e) == 404) { _deletedAt[id] = ++_writes; return true; }
            _deletedAt.Remove(id);
            if (removed != null) { _tasks.Insert(Math.Min(at, _tasks.Count), removed); Raise(); }
            Tell(TasksCopy.CouldNotDelete(KanbanRest.Reason(e)), id);
            return false;
        }
    }

    /// Saves the Tasks settings: shown at once, back as they were (with a notice) when the gateway refuses.
    public async Task<bool> SaveSettingsAsync(TodoSettings next)
    {
        if (Refuse()) return false;
        var before = Settings;
        Settings = next;
        Raise();
        try
        {
            Settings = await Api.SaveSettingsAsync(next);
            Raise();
            return true;
        }
        catch (Exception e)
        {
            Settings = before;
            Raise();
            Tell(TasksCopy.CouldNotSaveSettings(KanbanRest.Reason(e)));
            return false;
        }
    }

    /// Sort By (TasksStore.swift `setLayout(sort:)`): kept with the other Tasks settings on the gateway. The sort in
    /// force again changes nothing and is not a failure.
    public Task<bool> SetSortAsync(string sort) =>
        Settings.Sort == sort ? Task.FromResult(true) : SaveSettingsAsync(Settings with { Sort = sort });

    /// Moves tasks into `section` (null: no list), at its end in the order given, or at `position` for one dragged
    /// task (TasksStore.swift `move`). false when any of them couldn't move (the notice has said why).
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

    // ------------------------------------------------------------------ your lists (TasksStore.swift "Sections")

    /// Saves your lists (the whole list, in order). Shown at once; a list left out takes its tasks back to no list.
    /// The saved lists (new ones with their ids), null when it failed (everything back as it was, with a notice).
    public async Task<IReadOnlyList<TodoUserSection>?> SaveSectionsAsync(IReadOnlyList<TodoUserSection> next)
    {
        if (Refuse()) return null;
        if (!SectionsSupported) { Tell(SectionsNeedAddOn); return null; }
        var before = Sections;
        var beforeTasks = _tasks.ToList();
        var kept = next.Select(s => s.Id).ToHashSet();
        Sections = [.. next];
        _tasks = [.. _tasks.Select(t => t.Section is { } id && !kept.Contains(id) ? t with { Section = null } : t)];
        Raise();
        _sectionsWriting = true;
        try
        {
            var saved = await Api.SaveSectionsAsync(next);
            Sections = saved;
            Raise();
            _sectionsWriting = false;
            _ = RefreshAsync(force: true);
            return saved;
        }
        catch (Exception e)
        {
            Sections = before;
            _tasks = beforeTasks;
            Raise();
            Tell(TodoListCopy.CouldNotSaveSections(KanbanRest.Reason(e)));
            return null;
        }
        finally { _sectionsWriting = false; }
    }

    /// New List: a list at the end, with the first colour no list has (0.9.55+; an older add-on keeps only the name).
    /// The saved list (with the gateway's id); null for a blank name or a failed save.
    public async Task<TodoUserSection?> AddSectionAsync(string name)
    {
        if (TodoListCopy.CleanName(name) is not { } clean) return null;
        var draft = new TodoUserSection(TodoIds.Local(), clean) { Color = ListsSupported ? TodoListColors.Next(Sections) : null };
        if (await SaveSectionsAsync([.. Sections, draft]) is not { } saved) return null;
        return saved.LastOrDefault(s => s.Name == draft.Name) ?? saved.LastOrDefault();
    }

    /// Rename List: only its name changes (its colour, icon and bot stay).
    public async Task<bool> RenameSectionAsync(string id, string name)
    {
        if (TodoListCopy.CleanName(name) is not { } clean || !Sections.Any(s => s.Id == id)) return false;
        return await SaveSectionsAsync([.. Sections.Select(s => s.Id == id ? s with { Name = clean } : s)]) != null;
    }

    /// Move Left (-1) / Move Right (+1) on a list's pill.
    public async Task<bool> MoveSectionAsync(string id, int offset)
    {
        var next = Sections.ToList();
        var at = next.FindIndex(s => s.Id == id);
        if (at < 0 || at + offset < 0 || at + offset >= next.Count) return false;
        (next[at], next[at + offset]) = (next[at + offset], next[at]);
        return await SaveSectionsAsync(next) != null;
    }

    /// [WIN-TASK-LIST-EDIT] One list changed (its name, colour, icon, bot or rules; TasksStore.swift saveSection); the
    /// others go along as they are. false for a list that is gone, or a save that was refused.
    public async Task<bool> SaveSectionAsync(TodoUserSection section)
    {
        if (!Sections.Any(s => s.Id == section.Id)) return false;
        return await SaveSectionsAsync([.. Sections.Select(s => s.Id == section.Id ? section : s)]) != null;
    }

    /// Delete List: the list goes; every task in it is kept, in no list.
    public async Task<bool> DeleteSectionAsync(string id) =>
        Sections.Any(s => s.Id == id) && await SaveSectionsAsync([.. Sections.Where(s => s.Id != id)]) != null;

    // ------------------------------------------------------------------ Tasks & Goals v2 (attachments, offers, goal edits)

    /// [tasks-v2] Attaches a file to a task (`POST /tasks/{id}/attach`).
    public async Task<bool> AttachFileAsync(string taskId, string fileName, byte[] bytes)
    {
        if (Refuse(taskId) || Find(taskId) == null) return false;
        if (TodoIds.IsLocal(taskId)) { Tell(TasksCopy.StillBeingAdded, taskId); return false; }
        Begin(taskId);
        try
        {
            Put(await Api.AttachFileAsync(taskId, fileName, bytes));
            Raise();
            return true;
        }
        catch (Exception e)
        {
            Tell($"Couldn’t attach file. {KanbanRest.Reason(e)}", taskId);
            return false;
        }
        finally { End(taskId); }
    }

    /// [tasks-v2] Attaches a web link to a task (`POST /tasks/{id}/attach`).
    public async Task<bool> AttachLinkAsync(string taskId, string title, string url)
    {
        if (Refuse(taskId) || Find(taskId) == null) return false;
        if (TodoIds.IsLocal(taskId)) { Tell(TasksCopy.StillBeingAdded, taskId); return false; }
        if (TodoMade.ValidLinkUrl(url) is not { } validUrl) { Tell("Enter a valid http:// or https:// link.", taskId); return false; }
        Begin(taskId);
        try
        {
            Put(await Api.AttachLinkAsync(taskId, string.IsNullOrWhiteSpace(title) ? validUrl : title.Trim(), validUrl));
            Raise();
            return true;
        }
        catch (Exception e)
        {
            Tell($"Couldn’t attach link. {KanbanRest.Reason(e)}", taskId);
            return false;
        }
        finally { End(taskId); }
    }

    /// [tasks-v2] Removes an attachment or bot artifact from a task (`DELETE /tasks/{id}/made/{madeId}`).
    public async Task<bool> DetachMadeAsync(string taskId, string madeId)
    {
        if (Refuse(taskId) || Find(taskId) is not { } @base) return false;
        Put(@base with { Made = [.. @base.Made.Where(m => m.Id != madeId)] });
        Raise();
        Begin(taskId);
        try
        {
            Put(await Api.DetachMadeAsync(taskId, madeId));
            Raise();
            return true;
        }
        catch (Exception e)
        {
            Put(@base);
            Raise();
            Tell($"Couldn’t remove attachment. {KanbanRest.Reason(e)}", taskId);
            return false;
        }
        finally { End(taskId); }
    }

    /// [tasks-v2] Dismisses a bot's close offer and keeps the task open.
    public async Task<bool> KeepTaskOpenAsync(string taskId)
    {
        if (Refuse(taskId) || Find(taskId) is not { } @base) return false;
        if (@base.Offer != null)
        {
            Put(@base with { Offer = @base.Offer with { Kept = true } });
            Raise();
        }
        Begin(taskId);
        try
        {
            Put(await Api.KeepTaskOpenAsync(taskId));
            Raise();
            return true;
        }
        catch (Exception e)
        {
            Put(@base);
            Raise();
            Tell($"Couldn’t keep task open. {KanbanRest.Reason(e)}", taskId);
            return false;
        }
        finally { End(taskId); }
    }

    /// [tasks-v2] Answers a pending offer (accept / accept_no_list / decline / undo).
    public async Task<TodoOfferAnswer?> AnswerOfferAsync(string offerId, TodoOfferAction action)
    {
        if (Refuse()) return null;
        var btn = new TodoOfferButton(action, "");
        try
        {
            var answer = await Api.AnswerOfferAsync(offerId, btn.WireAction);
            foreach (var added in answer.AddedTasks) Put(added);
            if (answer.UpdatedGoal is { } g) PutGoal(g);
            if (answer.Offer is { } updated)
                Offers = [.. Offers.Select(o => o.Id == offerId ? updated : o)];
            else
                Offers = [.. Offers.Where(o => o.Id != offerId)];
            Raise();
            return answer;
        }
        catch (Exception e)
        {
            Tell($"Couldn’t answer offer. {KanbanRest.Reason(e)}");
            return null;
        }
    }

    private void PutGoal(Goal goal)
    {
        var list = Goals.ToList();
        var at = list.FindIndex(g => g.Id == goal.Id);
        if (at >= 0) list[at] = goal; else list.Add(goal);
        Goals = list;
    }

    /// [goals-v2] Optimistically patches a goal with 409 disjoint-field retry (`GoalWire.Resolve`).
    public async Task<bool> PatchGoalAsync(string goalId, JsonObject fields)
    {
        if (Refuse(goalId) || FindGoal(goalId) is not { } @base) return false;
        if (GoalWire.Applying(fields, @base) is { } shown) { PutGoal(shown); Raise(); }
        try
        {
            PutGoal(await Api.PatchGoalAsync(goalId, @base.Rev, fields));
            Raise();
            return true;
        }
        catch (Exception e)
        {
            if (TasksApi.GoalConflict(e) is { } current)
            {
                if (GoalWire.Resolve(@base, current, fields) is { } rev)
                {
                    try { PutGoal(await Api.PatchGoalAsync(goalId, rev, fields)); Raise(); return true; }
                    catch (Exception) { }
                }
                PutGoal(current);
                Raise();
                Tell("This goal changed somewhere else. Showing the latest.", goalId);
                return false;
            }
            if (KanbanRest.Status(e) == 404)
            {
                Goals = [.. Goals.Where(g => g.Id != goalId)];
                Raise();
                Tell("This goal was deleted somewhere else.", goalId);
                return false;
            }
            PutGoal(@base);
            Raise();
            Tell($"Couldn’t save goal. {KanbanRest.Reason(e)}", goalId);
            return false;
        }
    }

    /// [goals-v2] Deletes a goal (optimistic with rollback on failure).
    public async Task<bool> DeleteGoalAsync(string goalId)
    {
        if (Refuse(goalId) || FindGoal(goalId) == null) return false;
        var before = Goals;
        Goals = [.. Goals.Where(g => g.Id != goalId)];
        Raise();
        try
        {
            await Api.DeleteGoalAsync(goalId);
            return true;
        }
        catch (Exception e)
        {
            if (KanbanRest.Status(e) == 404) return true;
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

    public Task<bool> DeleteGoalMilestoneAsync(string goalId, string milestoneId)
    {
        if (FindGoal(goalId) is not { } goal) return Task.FromResult(false);
        var next = goal.Milestones.Where(m => m.Id != milestoneId);
        return PatchGoalAsync(goalId, new JsonObject { ["milestones"] = GoalWire.Milestones(next) });
    }

    public Task<bool> UpdateGoalMeasureAsync(string goalId, GoalMeasure? measure) =>
        PatchGoalAsync(goalId, new JsonObject { ["measure"] = measure?.Wire() });

    public Task<bool> KeepGoalGoingAsync(string goalId) =>
        PatchGoalAsync(goalId, new JsonObject { ["kept_at"] = TodoDates.Now() });

    public Task<bool> AnswerGoalLooksDoneAsync(string goalId, bool achieved) =>
        achieved
            ? PatchGoalAsync(goalId, new JsonObject { ["status"] = "achieved", ["status_at"] = TodoDates.Now() })
            : PatchGoalAsync(goalId, new JsonObject { ["kept_at"] = TodoDates.Now() });
}
