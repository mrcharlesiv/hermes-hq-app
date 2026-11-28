using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Composer;
using Hermes.Core.Kanban;
using Hermes.Core.Rpc;
using Hermes.Core.Tasks;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace HermesHQ.Features.Tasks;

/// Tasks (`App/Pages/Tasks/TasksHub.swift`; `docs/tasks.md`): shared to-do list and goals across you and your bots.
/// Claims the `"tasks"` place; keeps one `TasksStore` & `TaskIdeasStore` per signed-in account across navigations,
/// hooks `tasks.changed`, `gateway.ready`, `TodoTaskStates.Wanted`, foreground activation, and `GoalPlanTaken` auto-notify.
public static class TasksFeature
{
    private static bool _registered;

    public static void Register()
    {
        if (_registered) return;
        _registered = true;
        Places.Register("tasks", typeof(TasksPage));
        ChatExtensions.ToolRenderers["tasks_update"] = TodoCloseCardView.Render;
        AppState.ClientChanged += TasksHub.Use;
        TodoTaskStates.Wanted += TasksHub.OnTaskStateWanted;
        if (AppState.Client is { } client) TasksHub.Use(client);
    }

    /// Sign Out / Remove Gateway: drop the hub and delete this PC's cached copy of tasks and pending offline ops.
    public static void SignedOut(string accountKey)
    {
        TasksHub.Drop();
        try { Directory.Delete(TasksHub.CacheDirectory(accountKey), recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

/// Shared per-account hub owning `TasksStore` & `TaskIdeasStore` across page navigations (`TasksHub.swift` + `JobsServices`).
internal static class TasksHub
{
    private static readonly object Gate = new();
    private static HermesClient? _client;
    private static TasksStore? _store;
    private static TaskIdeasStore? _ideas;
    private static DispatcherQueue? _ui;
    private static Window? _window;
    private static readonly IKeyValueStore PlanToldPrefs = new JsonFileStore(Path.Combine(AppPaths.Root, "tasks-plan-told.json"));
    private static readonly GoalPlanTold PlanTold = new();
    private static bool _planToldLoaded;

    public static string CacheDirectory(string accountKey) =>
        Path.Combine(AppPaths.Root, "tasks", string.Concat(accountKey.Select(c => char.IsLetterOrDigit(c) ? c : '_')));

    public static (TasksStore Store, TaskIdeasStore Ideas)? Current => For(AppState.Client);

    public static (TasksStore Store, TaskIdeasStore Ideas)? For(HermesClient? client)
    {
        if (client == null) return null;
        lock (Gate)
        {
            if (_client == client && _store != null && _ideas != null)
            {
                HookWindowLocked();
                return (_store, _ideas);
            }
            DropLocked();
            _ui ??= DispatcherQueue.GetForCurrentThread();
            _client = client;
            var dir = CacheDirectory(client.AccountId);
            var api = new TasksApi(new GatewaySessionRest(client.Session));
            _store = new TasksStore(api, cacheDirectory: dir);
            _ideas = new TaskIdeasStore(api, cacheDirectory: dir);
            _store.Prepare();
            _ideas.Prepare();
            _store.PlanTaken += OnPlanTaken;
            client.Rpc.Event += OnRpcEvent;
            client.Rpc.Reconnected += OnRpcReconnected;
            HookWindowLocked();
            AppLog.Note("tasks", "hub store ready");
            return (_store, _ideas);
        }
    }

    public static void Use(HermesClient? client)
    {
        if (client == null) Drop();
        else For(client);
    }

    public static void Drop()
    {
        lock (Gate) DropLocked();
    }

    private static void DropLocked()
    {
        if (_client != null)
        {
            _client.Rpc.Event -= OnRpcEvent;
            _client.Rpc.Reconnected -= OnRpcReconnected;
        }
        if (_store != null)
        {
            _store.PlanTaken -= OnPlanTaken;
            _store.Forget();
        }
        _ideas?.Forget();
        _store = null;
        _ideas = null;
        _client = null;
    }

    private static void HookWindowLocked()
    {
        if (App.Window is not { } win || ReferenceEquals(_window, win)) return;
        if (_window != null) _window.Activated -= OnWindowActivated;
        _window = win;
        _window.Activated += OnWindowActivated;
    }

    private static void OnWindowActivated(object sender, WindowActivatedEventArgs e)
    {
        if (AppShutdown.Stopping) return;
        var active = e.WindowActivationState != WindowActivationState.Deactivated;
        RunOnUi(() => _store?.SetForeground(active));
    }

    private static void OnRpcEvent(RpcEvent ev)
    {
        if (ev.Type == "tasks.changed")
        {
            RunOnUi(() =>
            {
                _store?.ApplyTasksChangedEvent();
                if (_ideas is { Loaded: true } ideas) _ = ideas.RefreshAsync(force: true);
            });
        }
    }

    private static void OnRpcReconnected(bool resumed)
    {
        RunOnUi(() =>
        {
            if (_store is { } store) _ = store.GatewayReadyAsync();
        });
    }

    internal static void OnTaskStateWanted(string taskId)
    {
        RunOnUi(() =>
        {
            if (_store is { } store) _ = store.RefreshAsync(force: true);
        });
    }

    /// [goals set-up] When this device accepts a goal's `"plan"` offer, tell the goal's lead once via its goal chat
    /// so it starts its own tasks and updates Where It Stands (`GoalPlanTaken` / `GoalPlanTold`).
    private static void OnPlanTaken(TodoOffer offer)
    {
        if (offer.Kind != "plan" || offer.State != "accepted" || string.IsNullOrEmpty(offer.Goal)) return;
        var client = _client;
        var store = _store;
        if (client == null || store == null) return;
        if (store.FindGoal(offer.Goal) is not { State: GoalState.Active, Lead: { Length: > 0 } lead } goal) return;

        EnsurePlanToldLoaded();
        if (!PlanTold.Remember(goal.Id, offer.Id)) return;
        PersistPlanTold(goal.Id, offer.Id);

        var mCount = offer.MadeMilestones.Count;
        var tCount = offer.Added.Count;
        var parts = new List<string>();
        if (mCount > 0) parts.Add(GoalOffers.MilestoneCount(mCount));
        if (tCount > 0) parts.Add(TodoOfferRules.Count(tCount));
        var made = parts.Count == 0
            ? "nothing new is on it, only its set-up"
            : string.Join(" and ", parts) + (mCount + tCount == 1 ? " is" : " are") + " on it now";
        var prompt = $"I took your plan for “{goal.Shown}”: {made}. Start your own tasks under it now, then tell me where it stands in one line (goals_update with stands). (Goal id {goal.Id})";

        _ = NotifyLeadAsync(client, goal, lead, prompt);
    }

    private static async Task NotifyLeadAsync(HermesClient client, Goal goal, string lead, string prompt)
    {
        try
        {
            string? storedId = goal.Chat?.SessionId;
            if (string.IsNullOrEmpty(storedId))
            {
                var bot = client.Bots?.FirstOrDefault(b => b.Name == lead);
                if (bot != null) storedId = await client.BotChatIdAsync(bot);
            }
            if (string.IsNullOrEmpty(storedId)) return;

            var resumed = await client.Rpc.RequestAsync("session.resume", new JsonObject
            {
                ["session_id"] = storedId,
                ["profile"] = lead,
            }, TimeSpan.FromSeconds(30));
            var runtime = resumed.Text("session_id") ?? storedId;
            await client.Rpc.RequestAsync("prompt.submit", new JsonObject
            {
                ["session_id"] = runtime,
                ["profile"] = lead,
                ["text"] = prompt,
            }, TimeSpan.FromSeconds(60));
            AppLog.Note("tasks", $"goal plan taken notified lead {lead}");
        }
        catch (Exception ex)
        {
            AppLog.Note("tasks", $"goal plan taken notify skipped: {ex.GetType().Name}");
        }
    }

    private static void EnsurePlanToldLoaded()
    {
        if (_planToldLoaded) return;
        _planToldLoaded = true;
        var raw = PlanToldPrefs.Get("told") ?? "";
        foreach (var entry in raw.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var idx = entry.IndexOf(':');
            if (idx > 0 && idx < entry.Length - 1)
                PlanTold.Remember(entry[..idx], entry[(idx + 1)..]);
        }
    }

    private static void PersistPlanTold(string goalId, string offerId)
    {
        var key = $"{goalId}:{offerId}";
        var existing = (PlanToldPrefs.Get("told") ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (!existing.Contains(key, StringComparer.Ordinal))
        {
            existing.Add(key);
            if (existing.Count > 200) existing.RemoveRange(0, existing.Count - 200);
            PlanToldPrefs.Set("told", string.Join('\n', existing));
        }
    }

    private static void RunOnUi(Action action)
    {
        if (AppShutdown.Stopping) return;
        var ui = _ui ?? DispatcherQueue.GetForCurrentThread();
        if (ui == null || ui.HasThreadAccess) action();
        else ui.TryEnqueue(() => { if (!AppShutdown.Stopping) action(); });
    }
}
