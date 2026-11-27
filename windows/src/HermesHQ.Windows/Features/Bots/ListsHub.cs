using Hermes.Core;
using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Net;
using Hermes.Core.Sessions;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;

namespace HermesHQ.Features.Bots;

/// The Bots and Sessions stores for the signed-in account, and the reads that keep them fresh: the roster every
/// max(30 s, 10× the last read) (spec 02 §3.6), the sessions sidebar every 30 s, and the live registry every 10 s while
/// something works or waits, else every 30 s (LiveStatusWatch). Changes reach the UI on its thread.
public sealed class ListsHub
{
    private static ListsHub? _current;
    private readonly CancellationTokenSource _life = new();
    private readonly DispatcherQueue _ui;
    private readonly Action _lostChanged;

    public HermesClient Client { get; }
    public BotStore Bots { get; }
    public SessionStore Sessions { get; }
    /// [groups] The group chats this device knows (HermesKit/Groups/GroupStore.swift), merged from the default profile's
    /// `ui_meta["hermes-bots-groups"]` mirror after each roster read (`GroupSync.Pulled`); drawn among the bots.
    public GroupStore Groups { get; }
    private readonly GroupSync _groupSync;
    /// [groups] A room's management writes (New Group Chat, Rename, Edit Bots, Add to Group Chat…, Delete Group Chat):
    /// each bot's `groups` through BotStore, the room through this hub's mirror sync.
    public GroupManager GroupManager { get; }
    /// Raised on the UI thread after either store changed.
    public event Action? Changed;

    /// The hub for the signed-in client (made on first use); null when signed out or shutting down.
    public static ListsHub? Current
    {
        get
        {
            if (AppShutdown.Stopping) { _current?.Stop(); _current = null; return null; }
            var client = AppState.Client;
            if (client == null) { _current?.Stop(); _current = null; return null; }
            if (_current?.Client != client)
            {
                _current?.Stop();
                _current = new ListsHub(client, DispatcherQueue.GetForCurrentThread());
            }
            return _current;
        }
    }

    /// Stops background roster/sessions/live polling and store event dispatch before gateway teardown.
    internal static void StopForQuit()
    {
        var hub = _current;
        _current = null;
        hub?.Stop();
    }

    public static string DevicePath => Path.Combine(AppPaths.Root, "lists");

    private static GroupStore LoadGroups(IDeviceStore disk, string accountId, BotStore bots, Func<bool> isOnline)
    {
        var rooms = DeviceJson.Load<List<GroupRoom>>(disk, $"{GroupStore.RoomsKind}.{accountId}");
        var marks = DeviceJson.Load<GroupStore.Marks>(disk, $"{GroupStore.MarksKind}.{accountId}");
        return new GroupStore(rooms, marks) { Roster = new BotStoreGroupRoster(bots), IsOnline = isOnline };
    }

    private static void SaveGroups(IDeviceStore disk, string accountId, GroupStore store)
    {
        if (store.IsClosed) return;
        try
        {
            DeviceJson.Save(disk, $"{GroupStore.RoomsKind}.{accountId}", store.Rooms);
            DeviceJson.Save(disk, $"{GroupStore.MarksKind}.{accountId}", store.MarksState);
        }
        catch (Exception e) { AppLog.Note("groups", $"persist skipped: {e.GetType().Name}"); }
    }

    private ListsHub(HermesClient client, DispatcherQueue ui)
    {
        Client = client;
        _ui = ui;
        var gw = new ClientGateway(client);
        var disk = new FileDeviceStore(DevicePath);
        Bots = new BotStore(gw, disk);
        Sessions = new SessionStore(gw, disk);
        // [WIN-LOST-SEND-MARKER] A row's pending line (3x-sessions §9.4): a send that may never have arrived. (This PC's
        // Sessions rows don't read the composer's typed drafts yet: the draft half is null.)
        var lost = AppState.LostSends;
        var accountId = client.AccountId;
        Sessions.PendingLine = (profile, storedId) => SessionPending.Pending(lost.First(accountId, profile, storedId)?.Text, null);
        Sessions.Deleted += (profile, storedId) => lost.Clear(accountId, profile, storedId);
        _lostChanged = () =>
        {
            if (_life.IsCancellationRequested || AppShutdown.Stopping) return;
            _ui.TryEnqueue(() => { if (!_life.IsCancellationRequested && !AppShutdown.Stopping) Sessions.RefreshPending(); });
        };
        lost.Changed += _lostChanged;
        Groups = LoadGroups(disk, accountId, Bots, () => client.Rpc.State == Hermes.Core.Rpc.ConnectionState.Open);
        _groupSync = new GroupSync(Groups, gw) { Log = line => AppLog.Note("groups", line) };
        GroupManager = new GroupManager(Groups, new BotStoreGroupWriter(Bots), _groupSync);
        // [groups] A room's mute is this PC's, beside the bots' (key `room:<roomKey>`, BotMuteCenter's).
        Groups.IsMuted = key => Bots.MuteOf(key, DateTimeOffset.UtcNow) != null;
        Groups.Changed += () => SaveGroups(disk, accountId, Groups);
        Bots.Changed += Post;
        Sessions.Changed += Post;
        Groups.Changed += Post;
        _ui.TryEnqueue(PullGroups);   // the cached roster's mirror, before the first read lands
        _ = PollRosterAsync(_life.Token);
        _ = PollSessionsAsync(_life.Token);
        _ = PollLiveAsync(_life.Token);
    }

    private int _posted;
    private bool _jumpListUpdated;

    /// Many store changes in a row draw once.
    private void Post()
    {
        if (_life.IsCancellationRequested || AppShutdown.Stopping) return;
        if (Interlocked.Exchange(ref _posted, 1) == 1) return;
        _ui.TryEnqueue(() =>
        {
            Interlocked.Exchange(ref _posted, 0);
            if (_life.IsCancellationRequested || AppShutdown.Stopping) return;
            Sessions.BotNames = Bots.Rows.ToDictionary(b => b.Id, b => b.Name);
            Sessions.BotOrder = Bots.Rows.Where(b => !b.Hidden).Select(b => b.Id).ToList();
            if (Bots.Rows.Count > 0 && !_jumpListUpdated)
            {
                _jumpListUpdated = true;
                var botsForJump = Bots.Rows.Where(b => !b.Hidden).Select(b => (b.Id, b.Name)).ToList();
                _ = WindowsShellIntegration.UpdateJumpListAsync(botsForJump);
            }
            Changed?.Invoke();
        });
    }

    public void Stop()
    {
        _life.Cancel();
        Bots.StopWaking();   // [botslist] the Mac BotStore.stop(): no open is waiting any more
        Bots.Changed -= Post;
        Sessions.Changed -= Post;
        Groups.Changed -= Post;
        AppState.LostSends.Changed -= _lostChanged;   // [WIN-LOST-SEND-MARKER]
        _groupSync.Shutdown();
        Groups.Close();
    }

    /// [groups] The default profile's mirror into the rooms (on the UI thread, as the Mac's GroupSync runs on the main
    /// actor). Unchanged since the last pull: nothing happens.
    private void PullGroups()
    {
        if (_life.IsCancellationRequested || AppShutdown.Stopping) return;
        _groupSync.Pulled(Bots.DefaultProfileRow());
    }

    public async Task RefreshAsync()
    {
        if (_life.IsCancellationRequested || AppShutdown.Stopping) return;
        await Task.WhenAll(Safe(() => Bots.RefreshAsync(_life.Token), "roster"), Safe(() => Sessions.RefreshAsync(_life.Token), "sessions"));
        if (!_life.IsCancellationRequested && !AppShutdown.Stopping) _ui.TryEnqueue(PullGroups);
    }

    private static async Task Safe(Func<Task> run, string area)
    {
        try { await run(); }
        catch (OperationCanceledException) { }
        catch (GatewayException e) { AppLog.Note(area, $"read failed: {e.Code}"); }
    }

    private async Task PollRosterAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && !AppShutdown.Stopping)
        {
            await Safe(() => Bots.RefreshAsync(ct), "roster");
            if (ct.IsCancellationRequested || AppShutdown.Stopping) return;
            _ui.TryEnqueue(PullGroups);
            var wait = TimeSpan.FromSeconds(Math.Max(30, Bots.LastReadTook.TotalSeconds * 10));
            try { await Task.Delay(wait, ct); } catch (OperationCanceledException) { return; }
        }
    }

    private async Task PollSessionsAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && !AppShutdown.Stopping)
        {
            await Safe(() => Sessions.RefreshAsync(ct), "sessions");
            if (ct.IsCancellationRequested || AppShutdown.Stopping) return;
            await Safe(() => Sessions.LoadProjectsAsync(ct: ct), "projects");
            if (ct.IsCancellationRequested || AppShutdown.Stopping) return;
            try { await Task.Delay(TimeSpan.FromSeconds(30), ct); } catch (OperationCanceledException) { return; }
        }
    }

    private async Task PollLiveAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && !AppShutdown.Stopping)
        {
            if (await Sessions.ReadLiveAsync(ct) && !ct.IsCancellationRequested && !AppShutdown.Stopping)
                Bots.SetLive(Sessions.Live.Working, Sessions.Live.Waiting);
            if (ct.IsCancellationRequested || AppShutdown.Stopping) return;
            var busy = Sessions.Live.Working.Count > 0 || Sessions.Live.Waiting.Count > 0;
            try { await Task.Delay(TimeSpan.FromSeconds(busy ? 10 : 30), ct); } catch (OperationCanceledException) { return; }
        }
    }
}
