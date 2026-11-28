using System.Globalization;
using System.Text.Json.Nodes;
using Hermes.Core.Kanban;

namespace Hermes.Core.Tasks;

/// One suggested task (`TaskIdea` in `HermesKit/Pages/Tasks/TaskIdeas.swift`).
public sealed record TaskIdea(
    string Id,
    string Title,
    string Why = "",
    string? Bot = "default",
    string? Due = null,
    string? Section = null,
    TodoFrom? From = null,
    string? CreatedAt = null)
{
    /// Where it came from, in a few words ("Chat with Finance, Mon").
    public string Source { get; init; } = "";
    /// "me" | "together" | "bot".
    public string Who { get; init; } = "me";
    /// What the bot would do to help, in a line ("" for your own).
    public string Help { get; init; } = "";
    public string State { get; init; } = "new";
    public string? TaskId { get; init; }

    /// A bot can take part of it, so it can be added with that bot starting.
    public bool BotHelps => Who != "me";

    public static TaskIdea? FromJson(JsonNode? n)
    {
        if (n is not JsonObject || n.Text("id") is not { } id) return null;
        return new TaskIdea(
            Id: id,
            Title: n.Str("title") ?? "",
            Why: n.Str("why") ?? n.Str("reason") ?? "",
            Bot: n.Text("bot") ?? "default",
            Due: n.Text("due"),
            Section: n.Text("section"),
            From: TodoFrom.From(n.Get("from")),
            CreatedAt: n.Str("created_at") ?? "")
        {
            Source = n.Str("source") ?? "",
            Who = n.Text("who") ?? "me",
            Help = n.Str("help") ?? "",
            State = n.Text("state") ?? "new",
            TaskId = n.Text("task_id"),
        };
    }

    public JsonObject Wire()
    {
        var o = new JsonObject
        {
            ["id"] = Id,
            ["created_at"] = CreatedAt ?? "",
            ["bot"] = Bot ?? "default",
            ["title"] = Title,
            ["why"] = Why,
            ["source"] = Source,
            ["who"] = Who,
            ["help"] = Help,
            ["state"] = State,
        };
        if (TaskId != null) o["task_id"] = TaskId;
        if (Due != null) o["due"] = Due;
        if (Section != null) o["section"] = Section;
        if (From != null) o["from"] = From.Wire();
        return o;
    }
}

/// An auto-discovered connected app (direct MCP server or Composio app) on one or more bot profiles
/// (`TaskIdeasConnector` in `HermesKit/Pages/Tasks/TaskIdeas.swift`).
public sealed record TaskIdeasConnector
{
    public string Id { get; init; }
    public string Name { get; init; }
    /// `"mcp"` or `"composio"`.
    public string Kind { get; init; } = "mcp";
    public IReadOnlyList<string> Bots { get; init; } = [];

    public TaskIdeasConnector(string id, string name, string kind = "mcp", IReadOnlyList<string>? bots = null)
    {
        Id = id;
        Name = name;
        Kind = kind;
        Bots = bots ?? [];
    }

    public static TaskIdeasConnector? From(JsonNode? n)
    {
        if (n is not JsonObject || n.Text("id") is not { } id) return null;
        return new TaskIdeasConnector(
            id: id,
            name: n.Text("name") ?? id,
            kind: n.Text("kind") ?? "mcp",
            bots: [.. (n.Arr("bots") ?? []).Select(J.AsString).OfType<string>().Where(s => s.Length > 0)]);
    }

    public JsonObject Wire() => new()
    {
        ["id"] = Id,
        ["name"] = Name,
        ["kind"] = Kind,
        ["bots"] = new JsonArray([.. Bots.Select(b => (JsonNode)b)]),
    };

    public bool Equals(TaskIdeasConnector? other) =>
        other != null
        && string.Equals(Id, other.Id, StringComparison.Ordinal)
        && string.Equals(Name, other.Name, StringComparison.Ordinal)
        && string.Equals(Kind, other.Kind, StringComparison.Ordinal)
        && Bots.SequenceEqual(other.Bots, StringComparer.Ordinal);

    public override int GetHashCode()
    {
        var h = new HashCode();
        h.Add(Id, StringComparer.Ordinal);
        h.Add(Name, StringComparer.Ordinal);
        h.Add(Kind, StringComparer.Ordinal);
        foreach (var b in Bots) h.Add(b, StringComparer.Ordinal);
        return h.ToHashCode();
    }
}

/// Auto-discovered connectors and bot profiles from `GET /tasks/ideas` or `GET /tasks/ideas/sources`
/// (`TaskIdeasAvailableSources` in `HermesKit/Pages/Tasks/TaskIdeas.swift`).
public sealed record TaskIdeasAvailableSources
{
    public static readonly TaskIdeasAvailableSources Empty = new();

    public IReadOnlyList<TaskIdeasConnector> Connectors { get; init; } = [];
    public IReadOnlyList<string> Bots { get; init; } = [];

    public TaskIdeasAvailableSources(IReadOnlyList<TaskIdeasConnector>? connectors = null, IReadOnlyList<string>? bots = null)
    {
        Connectors = connectors ?? [];
        Bots = bots ?? [];
    }

    public static TaskIdeasAvailableSources From(JsonNode? n)
    {
        if (n is not JsonObject) return Empty;
        return new TaskIdeasAvailableSources(
            connectors: [.. (n.Arr("connectors") ?? []).Select(TaskIdeasConnector.From).OfType<TaskIdeasConnector>()],
            bots: [.. (n.Arr("bots") ?? []).Select(J.AsString).OfType<string>().Where(s => s.Length > 0)]);
    }

    public JsonObject Wire() => new()
    {
        ["connectors"] = new JsonArray([.. Connectors.Select(c => (JsonNode)c.Wire())]),
        ["bots"] = new JsonArray([.. Bots.Select(b => (JsonNode)b)]),
    };

    public bool Equals(TaskIdeasAvailableSources? other) =>
        other != null
        && Connectors.SequenceEqual(other.Connectors)
        && Bots.SequenceEqual(other.Bots, StringComparer.Ordinal);

    public override int GetHashCode()
    {
        var h = new HashCode();
        foreach (var c in Connectors) h.Add(c);
        foreach (var b in Bots) h.Add(b, StringComparer.Ordinal);
        return h.ToHashCode();
    }
}

/// Pure formatting and toggle rules for Suggested Tasks' Where to Look controls
/// (`TaskIdeasSummary` in `HermesKit/Pages/Tasks/TaskIdeas.swift`).
public static class TaskIdeasSummary
{
    private static readonly Dictionary<string, string> PrettyMap = new(StringComparer.OrdinalIgnoreCase)
    {
        ["gmail"] = "Gmail",
        ["googlecalendar"] = "Google Calendar",
        ["google_calendar"] = "Google Calendar",
        ["google-calendar"] = "Google Calendar",
        ["googledrive"] = "Google Drive",
        ["notion"] = "Notion",
        ["slack"] = "Slack",
        ["github"] = "GitHub",
        ["linear"] = "Linear",
        ["jira"] = "Jira",
        ["asana"] = "Asana",
        ["trello"] = "Trello",
        ["airtable"] = "Airtable",
        ["hubspot"] = "HubSpot",
        ["salesforce"] = "Salesforce",
        ["outlook"] = "Outlook",
        ["todoist"] = "Todoist",
    };

    public static string PrettyConnectorName(string id)
    {
        var colon = id.IndexOf(':');
        var slug = colon >= 0 ? id[(colon + 1)..] : id;
        if (PrettyMap.TryGetValue(slug, out var hit)) return hit;
        var parts = slug.Split(['-', '_'], StringSplitOptions.RemoveEmptyEntries)
            .Select(p => char.ToUpper(p[0], CultureInfo.InvariantCulture) + p[1..]);
        return string.Join(" ", parts);
    }

    /// Concise summary shown on the Suggested page banner and in Tasks Settings ("Chats, Memory, Gmail, Notion").
    public static string ActiveSourcesLabel(TodoIdeasSources sources, IReadOnlyList<TaskIdeasConnector> available)
    {
        var parts = new List<string>();
        if (sources.Chats) parts.Add("Chats");
        if (sources.Memory) parts.Add("Memory");
        if (sources.Files) parts.Add("Files");
        if (sources.Web) parts.Add("Web");
        var byId = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var c in available) byId.TryAdd(c.Id, c.Name);
        foreach (var cid in sources.Connectors)
            parts.Add(byId.TryGetValue(cid, out var name) ? name : PrettyConnectorName(cid));
        return parts.Count == 0 ? "No sources selected" : string.Join(", ", parts);
    }

    /// Concise label for the participating bots ("Hermes", "Hermes & Work", "Hermes, Work +1").
    public static string ActiveBotsLabel(IReadOnlyList<string> active, IReadOnlyList<(string Id, string Name)> bots)
    {
        var names = active.Select(id => BotName(id, bots)).ToList();
        return names.Count switch
        {
            0 => bots.Count > 0 ? bots[0].Name : "Hermes",
            1 => names[0],
            2 => $"{names[0]} & {names[1]}",
            _ => $"{names[0]}, {names[1]} +{names.Count - 2}",
        };
    }

    /// Subtitle for the Recent Chats row in Where to Look.
    public static string ChatBotsSubtitle(TodoIdeasSources sources, IReadOnlyList<(string Id, string Name)> bots)
    {
        if (!sources.Chats) return "Off · blocked during runs";
        if (bots.Count <= 1) return "Recent messages from your chats";
        var allIds = bots.Select(b => b.Id).ToHashSet(StringComparer.Ordinal);
        var picked = sources.ChatBots.Where(allIds.Contains).ToList();
        if (picked.Count == 0 || picked.Count >= bots.Count) return "All bots";
        var excluded = bots.Count - picked.Count;
        var names = string.Join(", ", picked.Take(2).Select(id => BotName(id, bots)));
        var suffix = picked.Count > 2 ? $" +{picked.Count - 2}" : "";
        return $"{names}{suffix} · {excluded} {(excluded == 1 ? "bot" : "bots")} excluded";
    }

    /// Toggles a connected app on or off. Turning on an app that lives on a bot not yet in `activeBots`
    /// automatically adds that bot to `activeBots` so multi-bot sweeps cover it seamlessly.
    public static (TodoIdeasSources Sources, List<string> ActiveBots) ToggleConnector(
        string id,
        bool on,
        TaskIdeasConnector? connector,
        TodoIdeasSources sources,
        IReadOnlyList<string> activeBots)
    {
        var nextConnectors = sources.Connectors.ToList();
        var nextBots = activeBots.ToList();
        if (on)
        {
            if (!nextConnectors.Contains(id, StringComparer.Ordinal)) nextConnectors.Add(id);
            if (connector?.Bots is { Count: > 0 } owners && !owners.Any(o => nextBots.Contains(o, StringComparer.Ordinal)))
                nextBots.Add(owners[0]);
        }
        else
        {
            nextConnectors.RemoveAll(c => string.Equals(c, id, StringComparison.Ordinal));
        }
        return (sources with { Connectors = nextConnectors }, nextBots);
    }

    private static string BotName(string id, IReadOnlyList<(string Id, string Name)> bots)
    {
        foreach (var (bid, name) in bots)
            if (string.Equals(bid, id, StringComparison.Ordinal)) return name;
        return id;
    }
}

/// Snapshot returned by `GET /tasks/ideas` (`TaskIdeasPage` in `HermesKit/Pages/Tasks/TaskIdeas.swift`).
public sealed record TaskIdeasPage(
    bool On,
    string Bot,
    string? At,
    int Max,
    bool Looking,
    string? RanAt,
    IReadOnlyList<TaskIdea> Ideas)
{
    public static readonly TaskIdeasPage Empty = new(false, "default", TodoSettingsCopy.DefaultIdeasAt, TodoSettingsCopy.DefaultIdeasMax, false, null, []);

    /// [task-ideas 0.9.86] Participating bots for multi-bot sweeps.
    public IReadOnlyList<string>? Bots { get; init; }
    /// [task-ideas 0.9.86] Active sources, instructions, and auto-discovered connectors.
    public TodoIdeasSources? Sources { get; init; }
    public string? Note { get; init; }
    public TaskIdeasAvailableSources? AvailableSources { get; init; }

    public IReadOnlyList<string> ActiveBots => Bots is { Count: > 0 } b ? b : [Bot];

    /// Backwards-compatible aliases for existing UI callers (Wave 5 updates TasksPage).
    public bool Running => Looking;
    public string? LastRunAt => RanAt;

    public static TaskIdeasPage From(JsonNode? n)
    {
        if (n is not JsonObject) return Empty;
        return new TaskIdeasPage(
            On: n.Bool("on") ?? n.Bool("enabled") ?? false,
            Bot: n.Text("bot") ?? "default",
            At: n.Text("at") ?? TodoSettingsCopy.DefaultIdeasAt,
            Max: (int)(n.Int("max") ?? TodoSettingsCopy.DefaultIdeasMax),
            Looking: n.Bool("looking") ?? n.Bool("running") ?? false,
            RanAt: n.Text("ran_at") ?? n.Text("last_run_at"),
            Ideas: [.. (n.Arr("ideas") ?? []).Select(TaskIdea.FromJson).OfType<TaskIdea>()])
        {
            Bots = n.Arr("bots") is { } bots ? [.. bots.Select(J.AsString).OfType<string>().Where(s => s.Length > 0)] : null,
            Sources = n.Obj("sources") is { } src ? TodoIdeasSources.From(src) : null,
            Note = n.Str("note"),
            AvailableSources = n.Obj("available_sources") is { } avail ? TaskIdeasAvailableSources.From(avail) : null,
        };
    }

    public JsonObject Wire()
    {
        var o = new JsonObject
        {
            ["on"] = On,
            ["bot"] = Bot,
            ["at"] = At ?? TodoSettingsCopy.DefaultIdeasAt,
            ["max"] = Max,
            ["ideas"] = new JsonArray([.. Ideas.Select(i => (JsonNode)i.Wire())]),
            ["looking"] = Looking,
        };
        if (Bots is { } bots) o["bots"] = new JsonArray([.. bots.Select(b => (JsonNode)b)]);
        if (Sources is { } sources) o["sources"] = sources.Wire();
        if (Note != null) o["note"] = Note;
        if (AvailableSources is { } avail) o["available_sources"] = avail.Wire();
        if (RanAt != null) o["ran_at"] = RanAt;
        return o;
    }
}

/// Stateful store for Task Ideas with disk cache (`task-ideas.json`), 4s polling while `Looking` (up to 10 min),
/// optimistic add/dismiss, and dismiss-vs-restore race protection (`TaskIdeasStore` in `TaskIdeas.swift`).
public sealed class TaskIdeasStore(
    TasksApi api,
    string? cacheDirectory = null,
    TimeSpan? pollInterval = null,
    TimeSpan? pollTimeout = null)
{
    public static readonly TimeSpan DefaultPollInterval = TimeSpan.FromSeconds(4);
    public static readonly TimeSpan DefaultPollTimeout = TimeSpan.FromMinutes(10);

    private readonly TimeSpan _pollInterval = pollInterval ?? DefaultPollInterval;
    private readonly TimeSpan _pollTimeout = pollTimeout ?? DefaultPollTimeout;
    private readonly HashSet<string> _decided = new(StringComparer.Ordinal);
    private readonly Dictionary<string, TaskIdea> _dismissedCache = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Task<bool>> _dismissing = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> _actionGen = new(StringComparer.Ordinal);

    private bool _prepared;
    private bool _closed;
    private bool _lookingRequestInFlight;
    private DateTimeOffset? _lastReadAt;
    private CancellationTokenSource? _pollCts;

    public string? CachePath => cacheDirectory != null ? Path.Combine(cacheDirectory, "task-ideas.json") : null;
    public TaskIdeasPage Page { get; private set; } = TaskIdeasPage.Empty;
    public bool Loaded { get; private set; }
    public bool Loading { get; private set; }
    public bool Looking => _lookingRequestInFlight || Page.Looking;
    public bool IsPolling => _pollCts != null && !_pollCts.IsCancellationRequested;
    public string? Error { get; private set; }

    public event Action? Changed;
    public event Action<string>? Notice;

    public IReadOnlyList<TaskIdea> VisibleIdeas => [.. Page.Ideas.Where(i => !_decided.Contains(i.Id))];
    public TaskIdea? LastDismissed(string id) => _dismissedCache.TryGetValue(id, out var idea) ? idea : null;

    /// Loads the cached `task-ideas.json` page once before the first network read (`TaskIdeasStore.prepare`).
    public void Prepare()
    {
        if (_prepared || _closed) return;
        _prepared = true;
        if (Loaded || CachePath is not { } path || !File.Exists(path)) return;
        try
        {
            var raw = File.ReadAllText(path);
            if (J.Parse(raw) is not JsonObject root) return;
            var payload = root.Obj("value") ?? root;
            Page = TaskIdeasPage.From(payload);
            Loaded = true;
            Changed?.Invoke();
        }
        catch (Exception) { }
    }

    private void Adopt(TaskIdeasPage fresh)
    {
        Page = fresh;
        Loaded = true;
        var liveIds = fresh.Ideas.Select(i => i.Id).ToHashSet(StringComparer.Ordinal);
        _decided.RemoveWhere(id => !liveIds.Contains(id));
        WriteCache(fresh);
        Changed?.Invoke();
    }

    private void WriteCache(TaskIdeasPage fresh)
    {
        if (_closed || CachePath is not { } path) return;
        try
        {
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            var wrapped = new JsonObject
            {
                ["at"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
                ["value"] = fresh.Wire(),
            };
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, wrapped.ToJsonString());
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception) { }
    }

    public Task RefreshAsync(CancellationToken ct = default) => RefreshAsync(force: false, ct);

    public async Task RefreshAsync(bool force, CancellationToken ct = default)
    {
        if (_closed) return;
        Prepare();
        if (!force && _lastReadAt is { } at && DateTimeOffset.UtcNow - at < TimeSpan.FromSeconds(2)) return;
        Loading = true;
        Changed?.Invoke();
        try
        {
            var fresh = await api.GetIdeasAsync(ct);
            if (_closed) return;
            _lastReadAt = DateTimeOffset.UtcNow;
            Error = null;
            Adopt(fresh);
            if (fresh.Looking) StartPolling();
            else StopPolling();
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            if (!_closed) Error = KanbanRest.Reason(e);
        }
        finally
        {
            Loading = false;
            if (!_closed) Changed?.Invoke();
        }
    }

    /// Reads auto-discovered connected apps and participating bots (`GET /tasks/ideas/sources`).
    public Task<TaskIdeasAvailableSources> GetAvailableSourcesAsync(CancellationToken ct = default) =>
        api.GetIdeasSourcesAsync(ct);

    public async Task<TodoTask?> AddAsync(TaskIdea idea, bool letBotStart = false, TasksStore? tasksStore = null, CancellationToken ct = default)
    {
        var gen = BumpGen(idea.Id);
        _decided.Add(idea.Id);
        Changed?.Invoke();
        try
        {
            var created = await api.AddIdeaAsync(idea.Id, letBotStart, ct);
            if (tasksStore != null) _ = tasksStore.RefreshAsync(force: true);
            await RefreshAsync(force: true, ct);
            return created;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            if (_actionGen.GetValueOrDefault(idea.Id) == gen) _decided.Remove(idea.Id);
            Notice?.Invoke($"Couldn’t add it. {KanbanRest.Reason(e)}");
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
        var request = RunDismissAsync(idea.Id, gen, ct);
        _dismissing[idea.Id] = request;
        var ok = await request;
        if (_dismissing.TryGetValue(idea.Id, out var current) && ReferenceEquals(current, request))
            _dismissing.Remove(idea.Id);
        return ok;
    }

    private async Task<bool> RunDismissAsync(string id, int gen, CancellationToken ct)
    {
        try
        {
            await api.DismissIdeaAsync(id, ct);
            return true;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            if (_actionGen.GetValueOrDefault(id) == gen) _decided.Remove(id);
            Notice?.Invoke($"Couldn’t dismiss it. {KanbanRest.Reason(e)}");
            Changed?.Invoke();
            return false;
        }
    }

    /// Restores a recently dismissed idea (Undo banner). Waits for any in-flight dismiss to land first
    /// (`TaskIdeasStore.restore` in `TaskIdeas.swift`).
    public async Task<bool> RestoreAsync(TaskIdea idea, CancellationToken ct = default)
    {
        if (_dismissing.TryGetValue(idea.Id, out var pending))
        {
            var dismissed = await pending;
            if (!dismissed) return true; // dismiss never landed, already restored
        }
        var gen = BumpGen(idea.Id);
        _decided.Remove(idea.Id);
        if (!Page.Ideas.Any(i => i.Id == idea.Id))
            Page = Page with { Ideas = [idea, .. Page.Ideas] };
        Changed?.Invoke();
        try
        {
            await api.RestoreIdeaAsync(idea.Id, ct);
            _dismissedCache.Remove(idea.Id);
            await RefreshAsync(force: true, ct);
            return true;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            if (_actionGen.GetValueOrDefault(idea.Id) == gen) _decided.Add(idea.Id);
            Notice?.Invoke($"Couldn’t bring it back. {KanbanRest.Reason(e)}");
            Changed?.Invoke();
            return false;
        }
    }

    /// Look Now: asks the gateway to sweep now, marks `Page.Looking = true`, and polls every 4 s until done (up to 10 min).
    public async Task<bool> LookNowAsync(CancellationToken ct = default)
    {
        if (_closed || _lookingRequestInFlight) return false;
        _lookingRequestInFlight = true;
        Changed?.Invoke();
        try
        {
            _ = await api.LookForIdeasAsync(ct);
            if (_closed) return false;
            Page = Page with { Looking = true };
            Changed?.Invoke();
            StartPolling();
            return true;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            Notice?.Invoke($"Couldn’t look now. {KanbanRest.Reason(e)}");
            return false;
        }
        finally
        {
            _lookingRequestInFlight = false;
            if (!_closed) Changed?.Invoke();
        }
    }

    public async Task<bool> SetOnAsync(bool on, TasksStore tasksStore, CancellationToken ct = default)
    {
        if (Loaded)
        {
            Page = Page with { On = on };
            Changed?.Invoke();
        }
        var ok = await tasksStore.SaveSettingsAsync(tasksStore.Settings with { Ideas = on });
        await RefreshAsync(force: true, ct);
        return ok;
    }

    /// Stops any active "Look Now" poll (page left, backgrounded, or sign-out).
    public void StopPolling()
    {
        if (_pollCts is not { } cts) return;
        _pollCts = null;
        try { cts.Cancel(); } catch (ObjectDisposedException) { }
    }

    /// Sign-out or gateway switch: stop polling and drop in-memory state.
    public void Forget()
    {
        _closed = true;
        StopPolling();
        _dismissing.Clear();
        _dismissedCache.Clear();
        _decided.Clear();
        Page = TaskIdeasPage.Empty;
        Loaded = false;
        _prepared = false;
        _lastReadAt = null;
    }

    private void StartPolling()
    {
        if (_closed || _pollCts != null) return;
        var cts = new CancellationTokenSource();
        _pollCts = cts;
        _ = PollLoopAsync(cts);
    }

    private async Task PollLoopAsync(CancellationTokenSource cts)
    {
        var started = DateTimeOffset.UtcNow;
        try
        {
            while (!cts.IsCancellationRequested && !_closed && DateTimeOffset.UtcNow - started < _pollTimeout)
            {
                await Task.Delay(_pollInterval, cts.Token);
                if (cts.IsCancellationRequested || _closed) break;
                await RefreshAsync(force: true, cts.Token);
                if (!Page.Looking) break;
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        finally
        {
            if (ReferenceEquals(_pollCts, cts))
                _pollCts = null;
            try { cts.Dispose(); } catch (ObjectDisposedException) { }
        }
    }

    private int BumpGen(string id)
    {
        var next = _actionGen.GetValueOrDefault(id) + 1;
        _actionGen[id] = next;
        return next;
    }
}
