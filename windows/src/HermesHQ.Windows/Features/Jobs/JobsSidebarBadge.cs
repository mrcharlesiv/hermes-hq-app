using Hermes.Core;
using Hermes.Core.Jobs;
using HermesHQ.Features.Transcript;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;

namespace HermesHQ.Features.Jobs;

/// JobsBadge.swift and PagesTabs.showJobsTab: one account's count, updated on reads and at the overdue boundary.
internal static partial class JobsSidebarBadge
{
    private const string PreferenceKey = "hqn.jobsBadgeClear";
    private static DispatcherQueue? _ui;
    private static DispatcherQueueTimer? _timer;
    private static JobsStore? _store;
    private static HermesClient? _client;
    private static JobsBadgeHistory _history = new(null);
    private static int _attention, _running;
    private static JobsBadgeClear Clear => FilePreferences.Shared.Get(PreferenceKey) == "whenSeen" ? JobsBadgeClear.WhenSeen : JobsBadgeClear.WhenFixed;

    internal static void StopTimerForQuit()
    {
        AppState.ClientChanged -= ClientChanged;
        if (_store != null) _store.Changed -= Changed;
        _store = null;
        _client = null;
        var timer = _timer;
        _timer = null;
        _ui = null;
        if (timer == null) return; // can quit before the badge registered
        try { timer.Tick -= OnTick; }
        finally { timer.Stop(); }
    }

    public static void Register()
    {
        if (AppShutdown.Stopping || _timer != null) return;
        _ui = DispatcherQueue.GetForCurrentThread();
        _timer = _ui.CreateTimer();
        _timer.IsRepeating = false;
        _timer.Tick += OnTick;
        RegisterAppearance();
        AppState.ClientChanged += ClientChanged;
        if (AppState.Client is { } client) Attach(client);
    }

    private static void OnTick(DispatcherQueueTimer sender, object args) => Update();

    private static void ClientChanged(HermesClient? client)
    {
        if (!AppShutdown.Stopping) _ui?.TryEnqueue(() => Attach(client));
    }

    private static void Attach(HermesClient? client)
    {
        if (AppShutdown.Stopping || _timer == null || client != AppState.Client) return;
        if (_store != null) _store.Changed -= Changed;
        _timer.Stop();
        _client = client;
        _store = client == null ? null : JobsServices.For(client);
        _history = new JobsBadgeHistory(client == null ? null : new JobsDiskCache(JobsServices.CacheDirectory(client.AccountId)));
        if (_store != null)
        {
            _store.Changed += Changed;
            _ = _store.RefreshAsync();
        }
        Update();
    }

    private static void Changed()
    {
        if (!AppShutdown.Stopping) _ui?.TryEnqueue(Update);
    }

    private static void Update()
    {
        if (AppShutdown.Stopping || _timer == null) return;
        // A sign-out can purge the cache before ClientChanged is raised; never re-create it from a stale callback.
        if (_client != AppState.Client) { _timer.Stop(); return; }
        var now = DateTimeOffset.Now;
        var jobs = _store?.Jobs ?? [];
        if (_store?.IsShowing == true) _history.MarkSeen(jobs, now);
        var count = JobsBadge.Count(jobs, now, Clear, _history.Seen.ToHashSet());
        var running = _store?.WorkingCount ?? 0;
        _timer.Stop();
        if (JobsBadge.NextChange(jobs, now) is { } at)
        {
            // Dispatcher timers have a bounded interval; re-evaluate long waits daily.
            _timer.Interval = TimeSpan.FromSeconds(Math.Clamp((at - now).TotalSeconds, 0.05, 86400));
            _timer.Start();
        }
        if (count == _attention && running == _running) return;
        _attention = count;
        _running = running;
        Places.InvalidateBadges();
    }
}
