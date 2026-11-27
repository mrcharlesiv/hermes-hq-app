using System.Text.Json.Nodes;
using Hermes.Core.Kanban;

namespace Hermes.Core.Tasks;

/// One task suggested by a bot under Inbox Ideas (`HermesKit/Pages/Tasks/TaskIdeas.swift`).
public sealed record TaskIdea(
    string Id,
    string Title,
    string Why,
    string? Bot = null,
    string? Due = null,
    string? Section = null,
    TodoFrom? From = null,
    string? CreatedAt = null)
{
    public static TaskIdea? FromJson(JsonNode? n)
    {
        if (n is not JsonObject || n.Text("id") is not { } id) return null;
        return new TaskIdea(
            Id: id,
            Title: n.Str("title") ?? "",
            Why: n.Str("why") ?? n.Str("reason") ?? "",
            Bot: n.Text("bot"),
            Due: n.Text("due"),
            Section: n.Text("section"),
            From: TodoFrom.From(n.Get("from")),
            CreatedAt: n.Text("created_at"));
    }
}

/// Snapshot returned by `GET /tasks/ideas`.
public sealed record TaskIdeasPage(
    bool On,
    string Bot,
    string? At,
    int Max,
    bool Running,
    string? LastRunAt,
    IReadOnlyList<TaskIdea> Ideas)
{
    public static readonly TaskIdeasPage Empty = new(false, "default", null, TodoSettingsCopy.DefaultIdeasMax, false, null, []);

    public static TaskIdeasPage From(JsonNode? n)
    {
        if (n is not JsonObject) return Empty;
        return new TaskIdeasPage(
            On: n.Bool("on") ?? n.Bool("enabled") ?? false,
            Bot: n.Text("bot") ?? "default",
            At: n.Text("at"),
            Max: (int)(n.Int("max") ?? TodoSettingsCopy.DefaultIdeasMax),
            Running: n.Bool("running") ?? false,
            LastRunAt: n.Text("last_run_at"),
            Ideas: [.. (n.Arr("ideas") ?? []).Select(TaskIdea.FromJson).OfType<TaskIdea>()]);
    }
}

/// Stateful store for Inbox Ideas with optimistic add/dismiss and dismiss-vs-restore race protection (`TaskIdeas.swift`).
public sealed class TaskIdeasStore(TasksApi api)
{
    private readonly HashSet<string> _decided = new(StringComparer.Ordinal);
    private readonly Dictionary<string, TaskIdea> _dismissedCache = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> _actionGen = new(StringComparer.Ordinal);

    public TaskIdeasPage Page { get; private set; } = TaskIdeasPage.Empty;
    public bool Loaded { get; private set; }
    public bool Loading { get; private set; }
    public bool Looking { get; private set; }
    public string? Error { get; private set; }

    public event Action? Changed;
    public event Action<string>? Notice;

    public IReadOnlyList<TaskIdea> VisibleIdeas => [.. Page.Ideas.Where(i => !_decided.Contains(i.Id))];
    public TaskIdea? LastDismissed(string id) => _dismissedCache.TryGetValue(id, out var idea) ? idea : null;

    public async Task RefreshAsync(CancellationToken ct = default)
    {
        Loading = true;
        Changed?.Invoke();
        try
        {
            var fresh = await api.GetIdeasAsync(ct);
            Page = fresh;
            Loaded = true;
            Error = null;
            // Drop stale optimistic decisions no longer returned by the server.
            var liveIds = fresh.Ideas.Select(i => i.Id).ToHashSet(StringComparer.Ordinal);
            _decided.RemoveWhere(id => !liveIds.Contains(id));
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            Error = KanbanRest.Reason(e);
        }
        finally
        {
            Loading = false;
            Changed?.Invoke();
        }
    }

    public async Task<TodoTask?> AddAsync(TaskIdea idea, bool letBotStart = false, TasksStore? tasksStore = null, CancellationToken ct = default)
    {
        var gen = BumpGen(idea.Id);
        _decided.Add(idea.Id);
        Changed?.Invoke();
        try
        {
            var created = await api.AddIdeaAsync(idea.Id, letBotStart, ct);
            if (tasksStore != null) _ = tasksStore.RefreshAsync(force: true);
            return created;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            if (_actionGen.GetValueOrDefault(idea.Id) == gen) _decided.Remove(idea.Id);
            Notice?.Invoke($"Couldn’t add idea. {KanbanRest.Reason(e)}");
            Changed?.Invoke();
            return null;
        }
    }

    public async Task<bool> DismissAsync(TaskIdea idea, CancellationToken ct = default)
    {
        var gen = BumpGen(idea.Id);
        _decided.Add(idea.Id);
        _dismissedCache[idea.Id] = idea;
        Changed?.Invoke();
        try
        {
            await api.DismissIdeaAsync(idea.Id, ct);
            return true;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            if (_actionGen.GetValueOrDefault(idea.Id) == gen) _decided.Remove(idea.Id);
            Notice?.Invoke($"Couldn’t dismiss idea. {KanbanRest.Reason(e)}");
            Changed?.Invoke();
            return false;
        }
    }

    /// Restores a recently dismissed idea (Undo banner). Protected against racing with the prior dismiss request.
    public async Task<bool> RestoreAsync(TaskIdea idea, CancellationToken ct = default)
    {
        var gen = BumpGen(idea.Id);
        _decided.Remove(idea.Id);
        if (!Page.Ideas.Any(i => i.Id == idea.Id))
            Page = Page with { Ideas = [idea, .. Page.Ideas] };
        Changed?.Invoke();
        try
        {
            await api.RestoreIdeaAsync(idea.Id, ct);
            _dismissedCache.Remove(idea.Id);
            return true;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            if (_actionGen.GetValueOrDefault(idea.Id) == gen) _decided.Add(idea.Id);
            Notice?.Invoke($"Couldn’t restore idea. {KanbanRest.Reason(e)}");
            Changed?.Invoke();
            return false;
        }
    }

    public async Task<bool> LookNowAsync(CancellationToken ct = default)
    {
        if (Looking) return false;
        Looking = true;
        Changed?.Invoke();
        try
        {
            await api.LookForIdeasAsync(ct);
            await RefreshAsync(ct);
            return true;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            Notice?.Invoke($"Couldn’t look for ideas. {KanbanRest.Reason(e)}");
            return false;
        }
        finally
        {
            Looking = false;
            Changed?.Invoke();
        }
    }

    public async Task<bool> SetOnAsync(bool on, TasksStore tasksStore, CancellationToken ct = default)
    {
        var ok = await tasksStore.SaveSettingsAsync(tasksStore.Settings with { Ideas = on });
        if (ok) await RefreshAsync(ct);
        return ok;
    }

    private int BumpGen(string id)
    {
        var next = _actionGen.GetValueOrDefault(id) + 1;
        _actionGen[id] = next;
        return next;
    }
}
