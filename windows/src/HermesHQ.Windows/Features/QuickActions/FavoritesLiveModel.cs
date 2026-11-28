using Hermes.Core;
using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Insights;
using Hermes.Core.Jobs;
using Hermes.Core.Kanban;
using Hermes.Core.QuickActions;
using Hermes.Core.Sessions;
using Hermes.Core.Tasks;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Jobs;
using HermesHQ.Features.Kanban;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;

namespace HermesHQ.Features.QuickActions;

/// Live data aggregator for Favorites (`App/QuickActions/FavoritesLiveModel.swift`): pulls Tasks, Goals, Jobs,
/// Sessions, Groups, Bots, Kanban, `GET /api/status`, `delegation.status`, and `GET /api/analytics/usage?days=N`;
/// tracks in-flight tile runs, 3.5 s inline feedback pills, and live page tile badges.
internal sealed class FavoritesLiveModel : IDisposable
{
    public enum AttentionTone { Critical, Warning, Accent, Working }

    public abstract record AttentionTarget
    {
        public sealed record BotChat(string Profile) : AttentionTarget;
        public sealed record Tasks : AttentionTarget;
        public sealed record Kanban : AttentionTarget;
        public sealed record Jobs : AttentionTarget;
        public sealed record Subagents : AttentionTarget;
        public sealed record CommandCenter : AttentionTarget;
    }

    public sealed record AttentionItem(
        string Id,
        string Title,
        string Subtitle,
        string Badge,
        AttentionTone Tone,
        AttentionTarget Target);

    public sealed record TasksFrame(
        string Title,
        int OpenCount,
        IReadOnlyList<TodoTask> Rows,
        int RemainingCount,
        bool Loading,
        string? EmptyNote);

    public sealed record GoalSnapshot(
        Goal? Goal,
        double? Fraction,
        string Line,
        GoalPace? Pace,
        TodoTask? NextTask,
        bool Loading);

    public sealed record JobSnapshot(
        CronJob? Job,
        string Title,
        string Subtitle,
        bool Running,
        bool Failed,
        bool Overdue,
        bool Paused,
        DateTimeOffset? NextRunAt);

    public sealed record KanbanSnapshot(
        string BoardTitle,
        IReadOnlyList<(string Status, string Label, int Count)> Columns,
        IReadOnlyList<KanbanTask> TopCards,
        int TotalOpen,
        bool Loading);

    public sealed record TileFeedback(bool Ok, string Message);

    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan StatusStale = TimeSpan.FromSeconds(25);
    private static readonly TimeSpan SubagentsStale = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan UsageStale = TimeSpan.FromSeconds(240);
    private static readonly TimeSpan FeedbackDuration = TimeSpan.FromMilliseconds(3500);

    private readonly DispatcherQueue? _ui = DispatcherQueue.GetForCurrentThread();
    private CancellationTokenSource? _pollCts;
    private readonly Dictionary<string, CancellationTokenSource> _feedbackTimers = [];

    private string? _accountId;
    private ListsHub? _hub;
    private JobsStore? _jobs;
    private TasksStore? _tasks;
    private KanbanStore? _kanban;
    private IReadOnlyList<QuickTile> _activeTiles = [];

    private DateTimeOffset _statusAt = DateTimeOffset.MinValue;
    private DateTimeOffset _subagentsAt = DateTimeOffset.MinValue;
    private readonly Dictionary<int, DateTimeOffset> _usageAt = [];
    private bool _tasksPrimed;
    private bool _kanbanPrimed;
    private bool _disposed;

    public int Tick { get; private set; }
    public HashSet<string> TickingTasks { get; } = [];
    public HashSet<string> RunningTiles { get; } = [];
    public Dictionary<string, TileFeedback> FeedbackByTile { get; } = [];
    public GatewayStatusReport? GatewayStatus { get; private set; }
    public bool StatusLoading { get; private set; }
    public Dictionary<int, UsageReport> UsageByDays { get; } = [];
    public HashSet<int> UsageLoadingDays { get; } = [];
    public int ActiveSubagents { get; private set; }

    public TasksStore? Tasks => _tasks;
    public KanbanStore? Kanban => _kanban;
    public JobsStore? Jobs => _jobs ?? JobsServices.Store;
    public ListsHub? Hub => _hub ?? ListsHub.Current;

    public event Action? Changed;

    // ------------------------------------------------------------------ lifecycle

    public void Start(IReadOnlyList<QuickTile> tiles)
    {
        if (_disposed) return;
        _activeTiles = tiles;
        AttachStores();
        RefreshIfNeeded(tiles, force: false);
        _pollCts?.Cancel();
        _pollCts?.Dispose();
        var cts = _pollCts = new CancellationTokenSource();
        _ = PollLoopAsync(cts.Token);
    }

    public void UpdateTiles(IReadOnlyList<QuickTile> tiles)
    {
        _activeTiles = tiles;
        if (_disposed) return;
        AttachStores();
        RefreshIfNeeded(tiles, force: false);
    }

    public void Stop()
    {
        _pollCts?.Cancel();
        _pollCts?.Dispose();
        _pollCts = null;
        DetachHubAndJobs();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Stop();
        DetachAccountStores();
        foreach (var cts in _feedbackTimers.Values) { cts.Cancel(); cts.Dispose(); }
        _feedbackTimers.Clear();
    }

    private void AttachStores()
    {
        var hub = ListsHub.Current;
        if (!ReferenceEquals(_hub, hub))
        {
            if (_hub != null) _hub.Changed -= OnSourceChanged;
            _hub = hub;
            if (_hub != null) _hub.Changed += OnSourceChanged;
        }
        var jobs = JobsServices.Store;
        if (!ReferenceEquals(_jobs, jobs))
        {
            if (_jobs != null) _jobs.Changed -= OnSourceChanged;
            _jobs = jobs;
            if (_jobs != null) _jobs.Changed += OnSourceChanged;
        }
        var client = AppState.Client;
        var nextAccount = client?.AccountId;
        if (_accountId != nextAccount)
        {
            DetachAccountStores();
            _accountId = nextAccount;
            GatewayStatus = null;
            UsageByDays.Clear();
            UsageLoadingDays.Clear();
            _usageAt.Clear();
            ActiveSubagents = 0;
            _statusAt = DateTimeOffset.MinValue;
            _subagentsAt = DateTimeOffset.MinValue;
            _tasksPrimed = false;
            _kanbanPrimed = false;
            if (client != null)
            {
                _tasks = new TasksStore(new TasksApi(new GatewaySessionRest(client.Session)));
                _tasks.Changed += OnSourceChanged;
                _kanban = new KanbanStore(new KanbanApi(new GatewaySessionRest(client.Session)), client.AccountId, new FileKanbanPrefs());
                _kanban.Changed += OnSourceChanged;
            }
        }
    }

    private void DetachHubAndJobs()
    {
        if (_hub != null) { _hub.Changed -= OnSourceChanged; _hub = null; }
        if (_jobs != null) { _jobs.Changed -= OnSourceChanged; _jobs = null; }
    }

    private void DetachAccountStores()
    {
        if (_tasks != null) { _tasks.Changed -= OnSourceChanged; _tasks = null; }
        if (_kanban != null) { _kanban.Changed -= OnSourceChanged; _kanban.Stop(); _kanban = null; }
    }

    private void OnSourceChanged() => Bump();

    private void Bump()
    {
        if (_disposed || AppShutdown.Stopping) return;
        if (_ui != null && !_ui.HasThreadAccess)
        {
            _ui.TryEnqueue(Bump);
            return;
        }
        Tick++;
        Changed?.Invoke();
    }

    private async Task PollLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && !_disposed && !AppShutdown.Stopping)
        {
            try { await Task.Delay(PollInterval, ct); }
            catch (OperationCanceledException) { return; }
            if (ct.IsCancellationRequested || _disposed || AppShutdown.Stopping) return;
            OnUi(() =>
            {
                AttachStores();
                RefreshIfNeeded(_activeTiles, force: false);
            });
        }
    }

    private void OnUi(Action work)
    {
        if (_disposed || AppShutdown.Stopping) return;
        if (_ui == null || _ui.HasThreadAccess) work();
        else _ui.TryEnqueue(() => { if (!_disposed && !AppShutdown.Stopping) work(); });
    }

    // ------------------------------------------------------------------ refreshing

    public async Task RefreshAllAsync(IReadOnlyList<QuickTile> tiles)
    {
        _activeTiles = tiles;
        AttachStores();
        var tasks = new List<Task>();
        if (_tasks != null) tasks.Add(SafeAsync(() => _tasks.RefreshAsync(force: true)));
        if (Jobs is { } j) tasks.Add(SafeAsync(() => j.RefreshAsync()));
        if (_kanban != null) tasks.Add(SafeAsync(() => _kanban.RefreshAsync()));
        tasks.Add(FetchGatewayStatusAsync(force: true));
        tasks.Add(FetchSubagentsAsync(force: true));
        foreach (var d in UsageDaysIn(tiles)) tasks.Add(FetchUsageAsync(d, force: true));
        await Task.WhenAll(tasks);
        Bump();
    }

    public void RefreshIfNeeded(IReadOnlyList<QuickTile> tiles, bool force = false)
    {
        if (AppState.Client == null || _disposed || AppShutdown.Stopping) return;
        var kinds = tiles.Select(t => t.Known).OfType<QuickTileKind>().ToHashSet();
        var pageIds = tiles.Where(t => t.Known == QuickTileKind.Page && !string.IsNullOrEmpty(t.Page))
            .Select(t => t.Page!).ToHashSet(StringComparer.Ordinal);

        var needsTasks = kinds.Contains(QuickTileKind.Tasks) || kinds.Contains(QuickTileKind.Goal)
            || kinds.Contains(QuickTileKind.NeedsYou) || pageIds.Contains("tasks");
        if (needsTasks && _tasks != null && (force || !_tasksPrimed))
        {
            _tasksPrimed = true;
            _ = SafeAsync(() => _tasks.RefreshAsync(force));
        }

        var needsJobs = kinds.Contains(QuickTileKind.JobCard) || kinds.Contains(QuickTileKind.RunJob)
            || kinds.Contains(QuickTileKind.NeedsYou) || pageIds.Contains("jobs");
        if (needsJobs && Jobs is { } j && (force || !j.HasList))
            _ = SafeAsync(() => j.RefreshAsync());

        var needsKanban = kinds.Contains(QuickTileKind.Kanban) || kinds.Contains(QuickTileKind.NeedsYou)
            || pageIds.Contains("kanban");
        if (needsKanban && _kanban != null && (force || !_kanbanPrimed))
        {
            _kanbanPrimed = true;
            _kanban.RefreshAll(force);
        }

        var needsStatus = kinds.Contains(QuickTileKind.GatewayStatus) || kinds.Contains(QuickTileKind.NeedsYou)
            || pageIds.Contains("command-center");
        if (needsStatus) _ = FetchGatewayStatusAsync(force);

        var needsSubagents = kinds.Contains(QuickTileKind.NeedsYou) || kinds.Contains(QuickTileKind.GatewayStatus);
        if (needsSubagents) _ = FetchSubagentsAsync(force);

        foreach (var days in UsageDaysIn(tiles))
            _ = FetchUsageAsync(days, force);
    }

    private static IEnumerable<int> UsageDaysIn(IReadOnlyList<QuickTile> tiles) =>
        tiles.Where(t => t.Known == QuickTileKind.Usage)
            .Select(t => t.Days is 30 or 90 ? t.Days.Value : 7)
            .Distinct();

    private async Task FetchGatewayStatusAsync(bool force)
    {
        var client = AppState.Client;
        if (client == null || StatusLoading) return;
        if (!force && GatewayStatus != null && DateTimeOffset.UtcNow - _statusAt < StatusStale) return;
        StatusLoading = true;
        Bump();
        try
        {
            var api = new CommandCenterApi(client.Session);
            var report = await api.StatusAsync();
            OnUi(() =>
            {
                if (_accountId != client.AccountId) return;
                GatewayStatus = report;
                _statusAt = DateTimeOffset.UtcNow;
                StatusLoading = false;
                Bump();
            });
        }
        catch (Exception)
        {
            OnUi(() =>
            {
                StatusLoading = false;
                Bump();
            });
        }
    }

    private async Task FetchSubagentsAsync(bool force)
    {
        var client = AppState.Client;
        if (client == null) return;
        if (!force && DateTimeOffset.UtcNow - _subagentsAt < SubagentsStale) return;
        _subagentsAt = DateTimeOffset.UtcNow;
        try
        {
            var profiles = Hub?.Bots.Rows.Where(r => !r.Hidden).Select(r => r.Id).Take(6).ToList() ?? ["default"];
            if (profiles.Count == 0) profiles = ["default"];
            var active = 0;
            foreach (var profile in profiles)
            {
                try
                {
                    var status = await SpawnTreeApi.StatusAsync(client, profile == "default" ? null : profile);
                    active += status.Active.Count(a => a.Status == SpawnStatus.Running);
                }
                catch (Exception) { }
            }
            OnUi(() =>
            {
                if (_accountId != client.AccountId) return;
                if (ActiveSubagents != active)
                {
                    ActiveSubagents = active;
                    Bump();
                }
            });
        }
        catch (Exception) { }
    }

    private async Task FetchUsageAsync(int days, bool force)
    {
        var client = AppState.Client;
        if (client == null || UsageLoadingDays.Contains(days)) return;
        if (!force && UsageByDays.ContainsKey(days) && _usageAt.TryGetValue(days, out var at)
            && DateTimeOffset.UtcNow - at < UsageStale)
            return;
        UsageLoadingDays.Add(days);
        Bump();
        try
        {
            var api = new CommandCenterApi(client.Session);
            var report = await api.UsageAsync(days);
            OnUi(() =>
            {
                if (_accountId != client.AccountId) return;
                UsageByDays[days] = report;
                _usageAt[days] = DateTimeOffset.UtcNow;
                UsageLoadingDays.Remove(days);
                Bump();
            });
        }
        catch (Exception)
        {
            OnUi(() =>
            {
                UsageLoadingDays.Remove(days);
                Bump();
            });
        }
    }

    private static async Task SafeAsync(Func<Task> work)
    {
        try { await work(); }
        catch (Exception) { }
    }

    // ------------------------------------------------------------------ interactive state & feedback

    public void SetRunning(string tileId, bool running)
    {
        if (running) RunningTiles.Add(tileId);
        else RunningTiles.Remove(tileId);
        Bump();
    }

    public void RecordFeedback(string tileId, bool ok, string message)
    {
        FeedbackByTile[tileId] = new TileFeedback(ok, message);
        if (_feedbackTimers.TryGetValue(tileId, out var prev)) { prev.Cancel(); prev.Dispose(); }
        var cts = _feedbackTimers[tileId] = new CancellationTokenSource();
        Bump();
        _ = ClearFeedbackLaterAsync(tileId, cts.Token);
    }

    private async Task ClearFeedbackLaterAsync(string tileId, CancellationToken ct)
    {
        try { await Task.Delay(FeedbackDuration, ct); }
        catch (OperationCanceledException) { return; }
        OnUi(() =>
        {
            if (ct.IsCancellationRequested) return;
            if (FeedbackByTile.Remove(tileId)) Bump();
        });
    }

    public async Task ToggleTaskDoneAsync(string taskId)
    {
        if (_tasks == null || _tasks.Find(taskId) is not { } task || !TickingTasks.Add(taskId)) return;
        Bump();
        try { await _tasks.SetDoneAsync(taskId, !task.IsDone); }
        catch (Exception) { }
        finally
        {
            TickingTasks.Remove(taskId);
            Bump();
        }
    }

    // ------------------------------------------------------------------ live snapshots

    public string BotName(string? profile)
    {
        if (string.IsNullOrEmpty(profile)) return "Hermes";
        if (Hub?.Bots.Bot(profile) is { } row) return row.Model.DisplayName;
        return PageKit.BotName(profile);
    }

    public TasksFrame TasksSnapshot(QuickTile tile, int maxRows)
    {
        var key = string.IsNullOrEmpty(tile.TaskView) ? "today" : tile.TaskView;
        var view = TodoView.FromKey(key) ?? TodoView.Today;
        var title = !string.IsNullOrWhiteSpace(tile.Name) ? tile.Name : tile.TaskViewName ?? "Today";
        if (_tasks == null || (!_tasks.HasList && _tasks.Loading))
            return new TasksFrame(title, 0, [], 0, Loading: true, EmptyNote: null);
        if (!_tasks.HasList)
            return new TasksFrame(title, 0, [], 0, Loading: false, EmptyNote: _tasks.NeedsAddOn ? "Tasks add-on required." : "Open Tasks to load.");

        var now = DateTimeOffset.Now;
        var zone = TimeZoneInfo.Local;
        var botIds = Hub?.Bots.Rows.Select(r => r.Id).ToList() ?? [];
        var groups = TodoViews.Groups(_tasks.Tasks, view, _tasks.Sections, botIds, now, zone, _tasks.Settings.Sort);
        var open = groups.Where(g => g.Kind != TodoGroupKind.Done).SelectMany(g => g.Tasks).ToList();
        var shown = open.Take(Math.Max(1, maxRows)).ToList();
        var remaining = Math.Max(0, open.Count - shown.Count);
        var listName = view.ListId is { } lid ? _tasks.Sections.FirstOrDefault(s => s.Id == lid)?.Name : null;
        return new TasksFrame(title, open.Count, shown, remaining, Loading: false,
            EmptyNote: open.Count == 0 ? TodoViews.EmptyText(view, listName ?? tile.TaskViewName) : null);
    }

    public GoalSnapshot GoalData(QuickTile tile)
    {
        if (_tasks == null || (!_tasks.HasList && _tasks.Loading))
            return new GoalSnapshot(null, null, "Loading…", null, null, Loading: true);
        var goal = !string.IsNullOrEmpty(tile.GoalId) ? _tasks.FindGoal(tile.GoalId) : null;
        if (goal == null)
            return new GoalSnapshot(null, null, _tasks.HasList ? "Goal not found on this gateway." : "Open Tasks to load goals.", null, null, Loading: false);
        var now = DateTimeOffset.Now;
        var zone = TimeZoneInfo.Local;
        var fraction = GoalViews.Fraction(goal, _tasks.Tasks);
        var line = goal.State == GoalState.Active
            ? GoalViews.Line(goal, _tasks.Tasks, now, zone)
            : GoalViews.StatusLine(goal, now, zone) ?? "";
        var pace = GoalViews.Pace(goal, _tasks.Tasks, now, zone);
        var next = goal.State == GoalState.Active ? GoalViews.NextTask(goal, _tasks.Tasks) : null;
        return new GoalSnapshot(goal, fraction, line, pace, next, Loading: false);
    }

    public JobSnapshot JobData(QuickTile tile)
    {
        var store = Jobs;
        if (store == null || !store.HasList || string.IsNullOrEmpty(tile.Job))
            return new JobSnapshot(null, tile.Name, store == null ? "Open Jobs to load" : "Job unavailable", false, false, false, false, null);
        var job = store.Jobs.FirstOrDefault(j => j.Key == tile.Job);
        if (job == null)
            return new JobSnapshot(null, tile.JobName ?? tile.Name, "Not on this gateway", false, false, false, false, null);
        var now = DateTimeOffset.Now;
        var running = JobWords.IsRunning(job);
        return new JobSnapshot(
            job,
            store.Title(job),
            JobWords.RowSubtitle(job, now, TimeZoneInfo.Local, running),
            running,
            JobWords.LastRunFailed(job),
            JobWords.NextRunOverdue(job, now) != null,
            JobWords.IsPaused(job),
            PagesDate.Parse(job.NextRunAt));
    }

    public IReadOnlyList<JobSnapshot> UpcomingJobs(int limit)
    {
        var store = Jobs;
        if (store == null || !store.HasList) return [];
        var now = DateTimeOffset.Now;
        var zone = TimeZoneInfo.Local;
        return store.Jobs
            .Where(j => !JobWords.IsPaused(j))
            .Select(j =>
            {
                var running = JobWords.IsRunning(j);
                var next = PagesDate.Parse(j.NextRunAt);
                return new JobSnapshot(
                    j,
                    store.Title(j),
                    JobWords.RowSubtitle(j, now, zone, running),
                    running,
                    JobWords.LastRunFailed(j),
                    JobWords.NextRunOverdue(j, now) != null,
                    false,
                    next);
            })
            .OrderByDescending(s => s.Running)
            .ThenByDescending(s => s.Failed || s.Overdue)
            .ThenBy(s => s.NextRunAt ?? DateTimeOffset.MaxValue)
            .Take(Math.Max(1, limit))
            .ToList();
    }

    public KanbanSnapshot KanbanData(QuickTile tile, int maxCards)
    {
        var fallbackTitle = tile.BoardName ?? tile.Name;
        if (_kanban == null || (_kanban.Board == null && _kanban.LoadingBoard))
            return new KanbanSnapshot(fallbackTitle, [], [], 0, Loading: true);
        if (_kanban.Board is not { } board)
            return new KanbanSnapshot(fallbackTitle, [], [], 0, Loading: false);

        var title = !string.IsNullOrEmpty(tile.BoardName) ? tile.BoardName : _kanban.BoardTitle;
        var counts = KanbanModel.StatusCounts(board);
        var order = KanbanModel.ChipOrder(board.Columns.Select(c => c.Name));
        var cols = new List<(string Status, string Label, int Count)>();
        foreach (var status in order)
        {
            if (status == "done") continue;
            cols.Add((status, KanbanModel.Label(status), counts.GetValueOrDefault(status)));
        }
        var totalOpen = cols.Sum(c => c.Count);

        IEnumerable<KanbanTask> pool;
        if (!string.IsNullOrEmpty(tile.ColumnStatus))
            pool = board.Columns.FirstOrDefault(c => c.Name == tile.ColumnStatus)?.Tasks ?? [];
        else
            pool = order.Where(s => s != "done")
                .SelectMany(s => board.Columns.FirstOrDefault(c => c.Name == s)?.Tasks ?? []);

        return new KanbanSnapshot(title, cols, pool.Take(Math.Max(0, maxCards)).ToList(), totalOpen, Loading: false);
    }

    public IReadOnlyList<AttentionItem> AttentionItems(int limit = 8)
    {
        var items = new List<AttentionItem>();
        var hub = Hub;
        if (hub != null)
        {
            foreach (var row in hub.Bots.Rows.Where(r => !r.Hidden && !string.IsNullOrEmpty(r.NeedsInput)))
            {
                items.Add(new AttentionItem(
                    "bot-input-" + row.Id,
                    row.Model.DisplayName,
                    row.NeedsInput!,
                    "Approval",
                    AttentionTone.Critical,
                    new AttentionTarget.BotChat(row.Id)));
            }
            foreach (var row in hub.Bots.Rows.Where(r => !r.Hidden && string.IsNullOrEmpty(r.NeedsInput) && !string.IsNullOrEmpty(r.Attention)))
            {
                items.Add(new AttentionItem(
                    "bot-attn-" + row.Id,
                    row.Model.DisplayName,
                    row.Attention!,
                    "Attention",
                    AttentionTone.Warning,
                    new AttentionTarget.BotChat(row.Id)));
            }
        }

        if (_tasks is { HasList: true })
        {
            var waiting = _tasks.Tasks.Where(t => !t.IsDone && TodoViews.WaitsOnYou(t)).Take(3);
            foreach (var t in waiting)
            {
                var who = !string.IsNullOrEmpty(t.Helper) ? BotName(t.Helper) : "Task";
                items.Add(new AttentionItem(
                    "task-" + t.Id,
                    string.IsNullOrWhiteSpace(t.Title) ? "Untitled Task" : t.Title,
                    t.Status == "needs_you" ? $"{who} has a question" : $"{who} finished its part",
                    "Task",
                    AttentionTone.Warning,
                    new AttentionTarget.Tasks()));
            }
        }

        if (_kanban?.Board is { } board)
        {
            var blocked = board.Columns.FirstOrDefault(c => c.Name == "blocked")?.Tasks ?? [];
            foreach (var card in blocked.Take(2))
            {
                items.Add(new AttentionItem(
                    "kanban-" + card.Id,
                    card.Title,
                    "Blocked on Kanban",
                    "Blocked",
                    AttentionTone.Critical,
                    new AttentionTarget.Kanban()));
            }
        }

        if (Jobs is { HasList: true } jobStore)
        {
            var now = DateTimeOffset.Now;
            foreach (var job in jobStore.Jobs.Where(j => JobWords.Section(j, now) == JobSection.NeedsAttention).Take(2))
            {
                items.Add(new AttentionItem(
                    "job-" + job.Key,
                    jobStore.Title(job),
                    JobWords.LastRunFailed(job) ? "Last run failed" : "Overdue",
                    "Job",
                    AttentionTone.Critical,
                    new AttentionTarget.Jobs()));
            }
        }

        if (GatewayStatus is { GatewayRunning: false })
        {
            items.Add(new AttentionItem(
                "gw-stopped",
                "Messaging Stopped",
                "Gateway messaging is not running",
                "Gateway",
                AttentionTone.Critical,
                new AttentionTarget.CommandCenter()));
        }
        else if (GatewayStatus != null)
        {
            var down = GatewayStatus.Platforms.Where(p => p.IsDown).ToList();
            if (down.Count > 0)
            {
                items.Add(new AttentionItem(
                    "gw-platforms",
                    down.Count == 1 ? $"{down[0].Name} Down" : $"{down.Count} Platforms Down",
                    "Check Status & Maintenance",
                    "Gateway",
                    AttentionTone.Warning,
                    new AttentionTarget.CommandCenter()));
            }
        }

        if (ActiveSubagents > 0)
        {
            items.Add(new AttentionItem(
                "subagents",
                ActiveSubagents == 1 ? "1 Subagent Running" : $"{ActiveSubagents} Subagents Running",
                "Inspect live activity in Spawn Tree",
                "Live",
                AttentionTone.Working,
                new AttentionTarget.Subagents()));
        }

        if (hub != null)
        {
            foreach (var row in hub.Bots.Rows.Where(r => !r.Hidden && r.IsWorking && string.IsNullOrEmpty(r.NeedsInput)).Take(2))
            {
                items.Add(new AttentionItem(
                    "bot-work-" + row.Id,
                    row.Model.DisplayName,
                    !string.IsNullOrEmpty(row.Step) ? row.Step : "Working…",
                    "Working",
                    AttentionTone.Working,
                    new AttentionTarget.BotChat(row.Id)));
            }
        }

        return items.Take(Math.Max(1, limit)).ToList();
    }

    /// Live numeric/status badge for Page tiles (`tasks`, `bots`, `jobs`, `kanban`, `command-center`).
    public (string Text, bool Urgent)? PageBadgeFor(string? pageId)
    {
        if (string.IsNullOrEmpty(pageId)) return null;
        switch (pageId)
        {
            case "tasks":
            {
                if (_tasks is not { HasList: true }) return null;
                var waiting = _tasks.Tasks.Count(t => !t.IsDone && TodoViews.WaitsOnYou(t));
                if (waiting > 0) return (waiting.ToString(), true);
                var today = TodoViews.OpenCount(_tasks.Tasks, TodoView.Today, _tasks.Sections, DateTimeOffset.Now, TimeZoneInfo.Local);
                return today > 0 ? (today.ToString(), false) : null;
            }
            case "bots":
            {
                if (Hub is not { Bots.HasRoster: true } hub) return null;
                var attn = hub.Bots.Rows.Count(r => !r.Hidden && (!string.IsNullOrEmpty(r.NeedsInput) || !string.IsNullOrEmpty(r.Attention)));
                if (attn > 0) return (attn.ToString(), true);
                var unread = hub.Bots.Rows.Count(r => !r.Hidden && r.Unread);
                return unread > 0 ? (unread.ToString(), false) : null;
            }
            case "jobs":
            {
                if (Jobs is not { HasList: true } jobs) return null;
                var now = DateTimeOffset.Now;
                var attn = jobs.Jobs.Count(j => JobWords.Section(j, now) == JobSection.NeedsAttention);
                if (attn > 0) return (attn.ToString(), true);
                var running = jobs.Jobs.Count(JobWords.IsRunning);
                return running > 0 ? (running.ToString(), false) : null;
            }
            case "kanban":
            {
                if (_kanban?.Board is not { } board) return null;
                var counts = KanbanModel.StatusCounts(board);
                var blocked = counts.GetValueOrDefault("blocked");
                if (blocked > 0) return (blocked.ToString(), true);
                var running = counts.GetValueOrDefault("running");
                return running > 0 ? (running.ToString(), false) : null;
            }
            case "command-center":
            {
                if (GatewayStatus == null) return null;
                if (GatewayStatus.GatewayRunning == false) return ("Off", true);
                var down = GatewayStatus.Platforms.Count(p => p.IsDown);
                return down > 0 ? (down.ToString(), true) : null;
            }
            default:
                return null;
        }
    }

    /// Populates a `QuickTileWorld` with all currently loaded gateway entities (never null-claiming missing when unloaded).
    public QuickTileWorld FillWorld(QuickTileWorld baseWorld, FavoriteTiles? dashboardTiles)
    {
        var hub = Hub;
        IReadOnlyDictionary<string, string>? rooms = null;
        if (hub != null && hub.Bots.HasRoster)
            rooms = hub.Groups.Rows().GroupBy(r => r.Id).ToDictionary(g => g.Key, g => g.First().Name);

        IReadOnlyDictionary<string, string>? sessions = null;
        if (hub != null && hub.Sessions.Loaded)
            sessions = hub.Sessions.LiveSummaries().GroupBy(s => s.Id).ToDictionary(g => g.Key, g => g.First().Title);

        IReadOnlyDictionary<string, string>? goals = null;
        IReadOnlyDictionary<string, string>? taskLists = null;
        bool? tasksEnabled = null;
        if (_tasks is { HasList: true })
        {
            goals = _tasks.Goals.GroupBy(g => g.Id).ToDictionary(g => g.Key, g => g.First().Shown);
            taskLists = _tasks.Sections.GroupBy(s => s.Id).ToDictionary(g => g.Key, g => g.First().Name);
            tasksEnabled = _tasks.Settings.Enabled;
        }

        IReadOnlyDictionary<string, string>? boards = null;
        if (_kanban?.Boards is { } kb)
            boards = kb.Boards.GroupBy(b => b.Slug).ToDictionary(g => g.Key, g => KanbanModel.BoardTitle(g.First().Slug, g.First().Name));

        IReadOnlyDictionary<string, string>? pins = null;
        IReadOnlyDictionary<string, string>? dashPages = null;
        if (dashboardTiles is { Ready: true })
        {
            pins = dashboardTiles.VisiblePins.GroupBy(p => p.Id).ToDictionary(g => g.Key, g => dashboardTiles.Name(g.First()));
            dashPages = dashboardTiles.Pages.GroupBy(p => p.Id).ToDictionary(g => g.Key, g => g.First().Name);
        }

        return baseWorld with
        {
            Pins = pins,
            Rooms = rooms,
            Sessions = sessions,
            Goals = goals,
            TaskLists = taskLists,
            DashboardPages = dashPages,
            Boards = boards,
            TasksEnabled = tasksEnabled,
            CurrentGatewayId = AppState.Client?.AccountId,
        };
    }
}
