using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Net;

namespace Hermes.Core.Sessions;

/// What this device keeps for the Sessions list, per gateway account (SessionsDeviceState).
public sealed class SessionsDeviceState
{
    public SessionsViewPrefs View { get; set; } = new();
    public bool ShowBackgroundRuns { get; set; }
    public SessionUnreadState Unread { get; set; } = new();
    /// Closed groups, by the chip's bot ("*" for All).
    public Dictionary<string, List<string>> CollapsedGroups { get; set; } = [];
    /// Pins a gateway refused while its maintenance lock was held: kept here (row key → pinned).
    public Dictionary<string, bool> Pins { get; set; } = [];
    /// [WIN-OFFSCREEN-TURN-END] The newest message this device saw in a chat (row key → message), the Mac's
    /// `device.latest` (HermesKit/Store/SessionStore+Latest.swift): the row's second line until its activity moves.
    public Dictionary<string, SessionLatestMessage> Latest { get; set; } = [];
}

/// The newest message of a chat this device saw (`SessionLatestMessage`): `At` is the row's recency when it was noted.
public sealed record SessionLatestMessage(double At, string Text, string? Role = null);

/// `SessionLatestRules`: messages kept on the device.
public static class SessionLatestRules
{
    public const int Keep = 400;
}

/// The Sessions list's data: the sidebar read (and its fallback), the archived read, projects, unread state, the live
/// registry, and every row action (pin, archive, mark read/unread, rename, delete, move to project, new project, new
/// chat, branch). Port of HermesKit/Store/SessionStore*.swift.
public sealed class SessionStore
{
    private readonly IListsGateway _gw;
    private readonly IDeviceStore _disk;
    private readonly string _diskKey;
    private readonly object _gate = new();
    private readonly SemaphoreSlim _readGate = new(1, 1);
    private readonly HashSet<string> _leaving = [];
    private readonly Dictionary<string, DateTimeOffset> _projectsReadAt = [];
    private List<SidebarSessionRow> _recents = [];
    private List<SidebarSessionRow> _messaging = [];
    private List<SidebarSessionRow> _archived = [];

    public SessionsDeviceState Device { get; }
    public SessionsViewPrefs Prefs => Device.View;
    /// The chip's bot (in memory: All on every launch).
    public string? BotFilter { get; set; }
    public SessionStatusChip? StatusChip { get; set; }
    public HashSet<string> OpenGroups { get; } = [];
    public HashSet<string> ExpandedGroups { get; } = [];
    public HashSet<string> KeepNew { get; } = [];
    public Dictionary<string, List<SessionProject>> ProjectsByProfile { get; } = [];
    public LiveStatus Live { get; } = new();
    private HashSet<string> _running = [];
    /// [WIN-EXTERNAL-SURFACES] Stored ids this device sees running a turn, ours or another Hermes process's (the Mac's
    /// `sessionStore.setRunning`); their rows say Working… with the gateway's live registry.
    public void SetRunning(IReadOnlySet<string> ids)
    {
        lock (_gate) { if (_running.SetEquals(ids)) return; _running = [.. ids]; }
        Raise();
    }
    private Dictionary<string, string> _steps = [];
    /// [WIN-LIVE-STEPS] Each heard chat's step as its row's line ("Running npm test…"), by stored id: the Mac's
    /// `setSteps(_:)` (93f984bb1 HermesKit/Store/SessionStore.swift). A working row says its step instead of Working….
    public void SetSteps(IReadOnlyDictionary<string, string> byChat)
    {
        lock (_gate)
        {
            if (_steps.Count == byChat.Count && byChat.All(kv => _steps.TryGetValue(kv.Key, out var w) && w == kv.Value)) return;
            _steps = byChat.ToDictionary(kv => kv.Key, kv => kv.Value);
        }
        Raise();
    }
    /// [WIN-OWN-TURN-ROWS] A turn of ours ended in this chat: the gateway's last "working" for it no longer counts (the
    /// Mac's `liveStatus.turnEnded`). True when its row changed.
    public bool TurnEnded(string storedId)
    {
        if (!Live.TurnEnded(storedId)) return false;
        Raise();
        return true;
    }

    /// [WIN-OFFSCREEN-TURN-END] A chat just seen or answered on this device: its row says so before the next read (the
    /// Mac's `noteLatest(profile:sessionId:text:role:)`). The sidebar's own preview is the chat's FIRST message.
    public void NoteLatest(string profile, string sessionId, string text, string? role = null)
    {
        var line = string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        if (line.Length == 0 || line == "[SILENT]" || Row(profile, sessionId) is not { } row) return;
        lock (_gate)
        {
            var key = row.WriteKey;
            var update = new SessionLatestMessage(row.Recency, line, role);
            if (Device.Latest.TryGetValue(key, out var had) && had == update) return;
            // The row's recency is the one before this message.
            Device.Latest[key] = update;
            if (Device.Latest.Count > SessionLatestRules.Keep)
            {
                var known = _recents.Concat(_messaging).Concat(_archived).Select(r => r.WriteKey).ToHashSet();
                foreach (var k in Device.Latest.Keys.Where(k => !known.Contains(k)).ToList()) Device.Latest.Remove(k);
            }
        }
        Persist();
        Raise();
    }

    /// The newest message to show for `row`, else null (the gateway's preview stands): the Mac's `latestText`. Windows
    /// reads no chat's tail (the Mac's `refreshLatest`), so a message noted here stands only until the row's activity
    /// moves past the recency it was noted at; then the gateway's preview is back until the chat is seen again.
    public string? LatestText(SidebarSessionRow row)
    {
        SessionLatestMessage? latest;
        lock (_gate) latest = Device.Latest.GetValueOrDefault(row.WriteKey);
        if (latest == null || Transcripts.TimelineNotes.IsTaskSnapshot(latest.Text) || row.Recency > latest.At) return null;
        return latest.Text;
    }
    /// The chat on screen (its dot stays off).
    public (string Profile, string Id)? Selected { get; set; }
    /// Display names by profile (from the Bots list), for owners and Group By Bot.
    public IReadOnlyDictionary<string, string> BotNames { get; set; } = new Dictionary<string, string>();
    /// Bot order for the chips (the Bots list's).
    public IReadOnlyList<string> BotOrder { get; set; } = [];
    public bool ReadOnly { get; set; }
    public bool Loaded { get; private set; }
    /// [WIN-39] Chats listings applied so far (each `Apply`): the CI's window-keys walk waits for the read Ctrl+R made.
    public int Reads { get; private set; }
    /// The last read failed (or a whole slice's scan did): "Retry", not "No sessions".
    public string? Failure { get; private set; }
    public bool ProjectsUnsupported { get; private set; }
    public event Action? Changed;

    public SessionStore(IListsGateway gateway, IDeviceStore disk)
    {
        _gw = gateway;
        _disk = disk;
        _diskKey = "sessions-" + gateway.AccountId;
        Device = DeviceJson.Load<SessionsDeviceState>(disk, _diskKey);
    }

    private void Persist() => DeviceJson.Save(_disk, _diskKey, Device);
    private void Raise() => Changed?.Invoke();

    // ---------------------------------------------------------------- reads

    public static readonly string RecentsExclude =
        "acp,cron,kanban,oneshot,subagent,telegram,discord,slack,mattermost,matrix,signal,whatsapp,bluebubbles,photon,homeassistant,email,sms,webhook,api_server,weixin,wecom,qqbot,yuanbao,dingtalk,feishu";
    public static readonly string MessagingExclude = "cron,acp,cli,codex,desktop,gateway,kanban,local,tui";

    /// 50 rows, 300 while a filter narrows the list (§3.6).
    public int RecentsLimit => Prefs.StatusFilter.Count > 0 || BotFilter != null
        || Prefs.ProjectFilter.Intersect(ProjectEntries().Select(p => p.Key)).Any() ? 300 : 50;

    public List<KeyValuePair<string, string>> SidebarQuery(int? limit = null) =>
    [
        new("recents_profile", "all"), new("recents_limit", (limit ?? RecentsLimit).ToString()), new("cron_limit", "50"),
        new("messaging_limit", "100"), new("recents_exclude", RecentsExclude), new("messaging_exclude", MessagingExclude),
        new("profile", "default"),
    ];

    public async Task RefreshAsync(CancellationToken ct = default)
    {
        await _readGate.WaitAsync(ct);
        try
        {
            ct.ThrowIfCancellationRequested();
            var a = await _gw.RestAsync(HttpMethod.Get, "/api/profiles/sessions/sidebar", SidebarQuery(), null, ct);
            ct.ThrowIfCancellationRequested(); // no fallback read or store write from a retired request
            SidebarPayload payload;
            if (a.Status == 404) payload = await LegacyAsync(ct);
            else if (!a.Ok) throw new GatewayException("http", $"The gateway answered {a.Status}.", a.Status, a.Body);
            else payload = SidebarPayload.Decode(a.Json);
            ct.ThrowIfCancellationRequested();
            Apply(payload);
        }
        catch (GatewayException e)
        {
            ct.ThrowIfCancellationRequested();
            lock (_gate) Failure = e.Code == "timeout" ? "Your gateway is slow to list sessions. Try again in a moment." : e.Message;
            Raise();
        }
        finally { _readGate.Release(); }
    }

    /// An older gateway (404 on the sidebar route): three `GET /api/profiles/sessions` reads.
    private async Task<SidebarPayload> LegacyAsync(CancellationToken ct)
    {
        async Task<JsonNode?> Page(params (string, string)[] q)
        {
            var a = await _gw.RestAsync(HttpMethod.Get, "/api/profiles/sessions",
                q.Select(x => new KeyValuePair<string, string>(x.Item1, x.Item2)), null, ct);
            return a.Ok ? a.Json : null;
        }
        var recents = await Page(("limit", RecentsLimit.ToString()), ("offset", "0"), ("min_messages", "1"), ("archived", "exclude"),
            ("order", "recent"), ("profile", "all"), ("exclude_sources", RecentsExclude));
        var root = new JsonObject
        {
            ["recents"] = recents?.DeepClone() ?? new JsonObject(), ["cron"] = new JsonObject { ["sessions"] = new JsonArray() },
            ["messaging"] = new JsonObject { ["sessions"] = new JsonArray() },
        };
        return SidebarPayload.Decode(root);
    }

    /// One sidebar answer (also used by tests with captured fixtures).
    public void Apply(SidebarPayload payload)
    {
        lock (_gate)
        {
            if (payload.Recents is { } rows) { _recents = rows; Failure = null; }
            else Failure = "Your gateway couldn’t list sessions.";
            if (payload.Messaging is { } m) _messaging = m;
            Device.Unread.Observe(_recents.Concat(_messaging).ToList());
            Loaded = true;
            Reads++;
        }
        Persist();
        Raise();
    }

    public async Task LoadArchivedAsync(CancellationToken ct = default)
    {
        try
        {
            var a = await _gw.RestAsync(HttpMethod.Get, "/api/profiles/sessions",
            [
                new("limit", "200"), new("offset", "0"), new("min_messages", "0"), new("archived", "only"),
                new("order", "recent"), new("profile", "all"),
            ], null, ct);
            if (!a.Ok) return;
            lock (_gate) _archived = (a.Json?["sessions"] as JsonArray ?? []).Select(SidebarSessionRow.From).OfType<SidebarSessionRow>().ToList();
            Raise();
        }
        catch (GatewayException) { }
    }

    /// `projects.tree {preview_limit:3, profile}` for each bot that owns a listed chat, at most once a minute each.
    public async Task LoadProjectsAsync(bool force = false, CancellationToken ct = default)
    {
        if (ProjectsUnsupported && !force) return;
        var profiles = RowsListed().Select(r => r.Profile).Concat(BotOrder).Distinct().ToList();
        var changed = false;
        foreach (var profile in profiles)
        {
            ct.ThrowIfCancellationRequested();
            if (!force && _projectsReadAt.TryGetValue(profile, out var at) && DateTimeOffset.UtcNow - at < TimeSpan.FromMinutes(1)) continue;
            _projectsReadAt[profile] = DateTimeOffset.UtcNow;
            try
            {
                var tree = await _gw.CallAsync("projects.tree", new JsonObject { ["preview_limit"] = 3, ["profile"] = profile }, TimeSpan.FromSeconds(20), ct);
                ct.ThrowIfCancellationRequested();
                lock (_gate) ProjectsByProfile[profile] = SessionProject.DecodeTree(tree);
                changed = true;
            }
            catch (GatewayException e) when (e.RpcCode == -32601) { ct.ThrowIfCancellationRequested(); ProjectsUnsupported = true; break; }
            catch (GatewayException) { }
        }
        ct.ThrowIfCancellationRequested();
        if (changed) Raise();
    }

    public async Task<bool> ReadLiveAsync(CancellationToken ct = default)
    {
        var changed = await Live.ReadAsync(_gw, ct);
        if (changed) Raise();
        return changed;
    }

    // ---------------------------------------------------------------- what the list draws

    private IEnumerable<SidebarSessionRow> RowsListed()
    {
        lock (_gate) return _recents.ToList();
    }

    public SidebarSessionRow? Row(string profile, string id)
    {
        lock (_gate) return _recents.Concat(_archived).Concat(_messaging).FirstOrDefault(r => r.Id == id && r.Profile == profile);
    }

    /// [WIN-LOST-SEND-MARKER] The row's pending line (a send that may not have arrived, else words waiting in the
    /// field), wired by the app (`pendingLine`); read as each row is drawn.
    public Func<string, string, SessionPending?>? PendingLine { get; set; }
    /// [WIN-LOST-SEND-MARKER] A chat was deleted on the gateway: what the device kept for it alone (its lost sends) can
    /// go (`onDeleted`).
    public event Action<string, string>? Deleted;

    /// The pending lines changed (a lost send noted or cleared, a draft typed): the rows read them again.
    public void RefreshPending() => Raise();

    private SessionSummary Summary(SidebarSessionRow row, bool archived = false)
    {
        var selected = Selected is { } s && s.Profile == row.Profile && s.Id == row.Id;
        bool local; string? step;
        lock (_gate) { local = _running.Contains(row.Id); step = _steps.GetValueOrDefault(row.Id); }
        var running = Live.Working.Contains(row.Id) || local;
        var waiting = Live.Waiting.Contains(row.Id);
        var unread = Device.Unread.IsUnread(row, ChatSource.IsMessaging(row.Source), selected, running, selected);
        var pinned = Device.Pins.TryGetValue(row.WriteKey, out var kept) ? kept : row.Pinned == true;
        static DateTimeOffset? At(double? s) => s is > 0 ? DateTimeOffset.FromUnixTimeMilliseconds((long)(s.Value * 1000)) : null;
        var pending = PendingLine?.Invoke(row.Profile, row.Id);
        return new SessionSummary
        {
            Id = row.Id, Profile = row.Profile, Title = SessionRules.Title(row), Preview = SessionRules.PreviewOf(LatestText(row) is { } latest ? row with { Preview = latest } : row),
            LastActive = At(row.LastActive ?? row.StartedAt), StartedAt = At(row.StartedAt), Source = row.Source,
            Unread = unread, IsRunning = running, Pinned = pinned, Archived = archived || row.Archived == true,
            Outside = ChatSource.IsMessaging(row.Source), Tokens = row.TotalTokens, Cost = row.CostUsd,
            Metadata = SessionRules.Metadata(row.GitBranch, row.Model, row.MessageCount, row.ToolCallCount),
            Branch = row.GitBranch, Cwd = row.Cwd, Model = row.Model, MessageCount = row.MessageCount, Owner = row.UserId,
            Pending = pending,
            Status = waiting ? SessionStatus.NeedsInput : running ? SessionStatus.Working : unread ? SessionStatus.Unread
                : pending is { Failed: false } ? SessionStatus.Draft : SessionStatus.Idle,
            Step = running ? step : null,                                    // [toolnow] the step of a busy row only
        };
    }

    private bool Listable(SidebarSessionRow r) =>
        !SessionRules.IsBotChat(r) && (Device.ShowBackgroundRuns || !SessionRules.IsBackgroundRun(r)) && !_leaving.Contains(r.WriteKey);

    public List<SessionSummary> LiveSummaries()
    {
        lock (_gate) return _recents.Where(Listable).Where(r => r.Archived != true).Select(r => Summary(r)).ToList();
    }

    public List<SessionSummary> ArchivedSummaries()
    {
        lock (_gate) return _archived.Where(Listable).Select(r => Summary(r, true)).ToList();
    }

    public List<SessionProjectEntry> ProjectEntries()
    {
        lock (_gate) return SessionProjects.MenuEntries(ProjectsByProfile, BotOrder);
    }

    private string ChipKey => BotFilter ?? "*";

    public SessionListInput Input(bool liveUnderProjects = true) => new()
    {
        Live = LiveSummaries(), Archived = ArchivedSummaries(), Prefs = Prefs, BotFilter = BotFilter,
        ProjectsByProfile = ProjectsByProfile, Projects = ProjectEntries(),
        CollapsedGroups = Device.CollapsedGroups.GetValueOrDefault(ChipKey)?.ToHashSet() ?? [],
        OpenGroups = OpenGroups, ExpandedGroups = ExpandedGroups, KeepNew = KeepNew,
        BotNames = BotNames, StatusChip = StatusChip, LiveUnderProjects = liveUnderProjects,
    };

    public List<SessionGroup> Groups() => SessionListPipeline.Groups(Input());

    public SessionFilterState FilterState() => new()
    {
        Prefs = Prefs, ShowBackgroundRuns = Device.ShowBackgroundRuns, BotFilter = BotFilter, Projects = ProjectEntries(),
        BotCount = Math.Max(BotOrder.Count, LiveSummaries().Select(s => s.Profile).Distinct().Count()),
        AnySpend = LiveSummaries().Any(s => s.Cost >= 0.01), HasUnread = LiveSummaries().Any(s => s.Unread),
    };

    /// A Filter & Sort pick; the store keeps the choices.
    public void ApplyFilter(SessionFilterAction action, string homeBot)
    {
        var state = FilterState();
        if (!SessionFilterMenu.Apply(action, state, homeBot)) return;
        BotFilter = state.BotFilter;
        Device.ShowBackgroundRuns = state.ShowBackgroundRuns;
        Persist();
        Raise();
        if (action.Kind == SessionFilterActionKind.Archived && Prefs.ShowArchived) _ = LoadArchivedAsync();
    }

    public void SetCollapsed(string groupId, bool collapsed)
    {
        if (!Device.CollapsedGroups.TryGetValue(ChipKey, out var list)) Device.CollapsedGroups[ChipKey] = list = [];
        list.Remove(groupId);
        if (collapsed) list.Add(groupId);
        Persist(); Raise();
    }

    public void Toggle(HashSet<string> set, string id) { if (!set.Remove(id)) set.Add(id); Raise(); }

    public void Changed_() => Raise();

    /// Search over the listed (and archived) chats: title, preview, owner; every word. Background runs too.
    public List<SessionSummary> Search(string query)
    {
        var words = query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return [];
        List<SessionSummary> pool;
        lock (_gate) pool = _recents.Concat(_archived).Where(r => !SessionRules.IsBotChat(r)).Select(r => Summary(r, _archived.Contains(r))).ToList();
        return SessionListPipeline.Sort(pool.Where(s =>
        {
            var hay = string.Join('\n', s.Title, s.Preview ?? "", SessionRules.OwnerName(s.Profile, BotNames));
            return words.All(w => hay.Contains(w, StringComparison.CurrentCultureIgnoreCase));
        }), SessionSortBy.Updated);
    }

    // ---------------------------------------------------------------- row actions

    private void RefuseWhenReadOnly()
    {
        if (ReadOnly) throw new BotWriteException("", BotWriteException.ReadOnlyReason);
    }

    private void Update(string profile, string id, Func<SidebarSessionRow, SidebarSessionRow> change)
    {
        lock (_gate)
        {
            static void In(List<SidebarSessionRow> rows, string p, string i, Func<SidebarSessionRow, SidebarSessionRow> c)
            {
                for (var k = 0; k < rows.Count; k++) if (rows[k].Id == i && rows[k].Profile == p) rows[k] = c(rows[k]);
            }
            In(_recents, profile, id, change); In(_messaging, profile, id, change); In(_archived, profile, id, change);
        }
        Raise();
    }

    public async Task SetPinnedAsync(SessionSummary s, bool pinned)
    {
        RefuseWhenReadOnly();
        var before = Row(s.Profile, s.Id)?.Pinned;
        Update(s.Profile, s.Id, r => r with { Pinned = pinned });
        try
        {
            await SessionWrite.PatchAsync(_gw, s.Id, s.Profile, new JsonObject { ["pinned"] = pinned });
            if (Device.Pins.Remove(s.Profile + "\u0000" + s.Id)) Persist();
        }
        catch (GatewayException e) when (e.Status == 409 && e.Body?.Contains("maintenance", StringComparison.OrdinalIgnoreCase) == true)
        {
            Device.Pins[s.Profile + "\u0000" + s.Id] = pinned;   // this device keeps it
            Persist(); Raise();
        }
        catch (GatewayException)
        {
            Update(s.Profile, s.Id, r => r with { Pinned = before });
            throw;
        }
    }

    /// Mark as Read / Unread. Read: local, and the server's flag cleared when it says unread. Unread: a marker and
    /// `"unread": true`.
    public async Task SetUnreadAsync(SessionSummary s, bool unread)
    {
        if (Row(s.Profile, s.Id) is not { } row) return;
        if (unread)
        {
            Device.Unread.Mark(row);
            Persist(); Raise();
            if (!ReadOnly) { try { await SessionWrite.PatchAsync(_gw, s.Id, s.Profile, new JsonObject { ["unread"] = true }); } catch (GatewayException) { } }
        }
        else await OpenedAsync(s.Profile, s.Id);
    }

    /// Opening a row: its local state clears, and when the server's flag says unread, `PATCH {"unread": false}`
    /// (optimistic, rolled back on failure).
    public async Task OpenedAsync(string profile, string id)
    {
        if (Row(profile, id) is not { } row) return;
        var serverUnread = row.Unread == true;
        Device.Unread.Opened(row, serverUnread && ReadOnly);
        Persist();
        if (!serverUnread || ReadOnly) { Raise(); return; }
        Update(profile, id, r => r with { Unread = false });
        try { await SessionWrite.PatchAsync(_gw, id, profile, new JsonObject { ["unread"] = false }); }
        catch (GatewayException) { Update(profile, id, r => r with { Unread = true }); }
    }

    /// Mark All as Read: every listed chat the server says is unread, at most four writes at a time.
    public async Task MarkAllReadAsync()
    {
        var targets = LiveSummaries().Where(s => s.Unread).ToList();
        using var limit = new SemaphoreSlim(4);
        await Task.WhenAll(targets.Select(async s =>
        {
            await limit.WaitAsync();
            try { await OpenedAsync(s.Profile, s.Id); }
            finally { limit.Release(); }
        }));
        Raise();
    }

    public async Task SetArchivedAsync(SessionSummary s, bool archived)
    {
        RefuseWhenReadOnly();
        var key = s.Profile + "\u0000" + s.Id;
        var row = Row(s.Profile, s.Id);
        lock (_gate) _leaving.Add(key);
        Raise();
        try { await SessionWrite.PatchAsync(_gw, s.Id, s.Profile, new JsonObject { ["archived"] = archived }); }
        catch (GatewayException)
        {
            lock (_gate) _leaving.Remove(key);
            Raise();
            throw;
        }
        lock (_gate)
        {
            _leaving.Remove(key);
            if (archived)
            {
                _recents.RemoveAll(r => r.Id == s.Id && r.Profile == s.Profile);
                if (row != null) { _archived.RemoveAll(r => r.WriteKey == row.WriteKey); _archived.Insert(0, row with { Archived = true }); }
            }
            else
            {
                _archived.RemoveAll(r => r.Id == s.Id && r.Profile == s.Profile);
                if (row != null && !_recents.Any(r => r.WriteKey == row.WriteKey)) _recents.Add(row with { Archived = false });
            }
        }
        Raise();
    }

    public async Task<string> RenameAsync(SessionSummary s, string title)
    {
        RefuseWhenReadOnly();
        var typed = title.Trim();
        var before = Row(s.Profile, s.Id)?.Title;
        Update(s.Profile, s.Id, r => r with { Title = typed.Length == 0 ? null : typed });
        try
        {
            var a = await SessionWrite.PatchAsync(_gw, s.Id, s.Profile, new JsonObject { ["title"] = typed });
            var stored = RosterText.Trimmed(a.Json?["title"]) ?? typed;
            Update(s.Profile, s.Id, r => r with { Title = stored.Length == 0 ? null : stored });
            return stored;
        }
        catch (GatewayException)
        {
            Update(s.Profile, s.Id, r => r with { Title = before });
            throw;
        }
    }

    public async Task DeleteAsync(SessionSummary s)
    {
        RefuseWhenReadOnly();
        await SessionWrite.DeleteAsync(_gw, s.Id, s.Profile);
        lock (_gate)
        {
            _recents.RemoveAll(r => r.Id == s.Id && r.Profile == s.Profile);
            _archived.RemoveAll(r => r.Id == s.Id && r.Profile == s.Profile);
            _messaging.RemoveAll(r => r.Id == s.Id && r.Profile == s.Profile);
        }
        Deleted?.Invoke(s.Profile, s.Id);
        Raise();
    }

    public SessionProject? ProjectOf(SessionSummary s)
    {
        lock (_gate)
            return ProjectsByProfile.TryGetValue(s.Profile, out var list) && SessionProject.OwnerOf(s.Cwd, list) is { } id
                ? list.FirstOrDefault(p => p.Id == id) : null;
    }

    public IReadOnlyList<SessionProject> MoveTargets(SessionSummary s)
    {
        lock (_gate) return ProjectsByProfile.TryGetValue(s.Profile, out var list) ? list.Where(p => !p.IsAuto).ToList() : [];
    }

    /// Move to Project: `session.workspace.move {cwd, session_key, profile}`; the row takes the new folder.
    public async Task MoveAsync(SessionSummary s, SessionProject project)
    {
        RefuseWhenReadOnly();
        var answer = await _gw.CallAsync("session.workspace.move", new JsonObject
        { ["cwd"] = project.Root, ["session_key"] = s.Id, ["profile"] = s.Profile }, TimeSpan.FromSeconds(30));
        var moved = RosterText.Trimmed(answer["cwd"]) ?? project.Root;
        Update(s.Profile, s.Id, r => r with { Cwd = moved });
    }

    /// New Project…: `projects.create {name, folders:[path], use:false, profile}` (no folder typed: `~/Projects/<slug>`
    /// made with `POST /api/files/mkdir`, the next free one when taken).
    public async Task<SessionProject> CreateProjectAsync(string name, string folder, string profile)
    {
        RefuseWhenReadOnly();
        var clean = name.Trim();
        var path = folder.Trim();
        if (path.Length > 0) return await CreateProjectAtAsync(clean, path, profile);
        for (var attempt = 1; ; attempt++)
        {
            var made = await MakeFolderAsync(SessionProject.AutoFolder(clean, attempt));
            try { return await CreateProjectAtAsync(clean, made, profile); }
            catch (GatewayException e) when (e.Message.Contains("already belongs to project") && attempt < 5) { }
        }
    }

    private async Task<string> MakeFolderAsync(string path)
    {
        var a = await _gw.RestAsync(HttpMethod.Post, "/api/files/mkdir", null, new JsonObject { ["path"] = path });
        if (!a.Ok)
        {
            var why = a.Status == 404 ? null : BotStore.RestReason(a).Trim();
            var said = why == null ? null : why.EndsWith('.') || why.EndsWith('!') || why.EndsWith('?') ? why : why + ".";
            throw new BotWriteException("", string.Join(" ", new[] { $"Couldn’t make the folder {path}.", said, "Type a folder to use instead." }.OfType<string>()));
        }
        return RosterText.Trimmed(a.Json?["path"]) ?? path;
    }

    private async Task<SessionProject> CreateProjectAtAsync(string clean, string path, string profile)
    {
        JsonNode answer;
        try
        {
            answer = await _gw.CallAsync("projects.create", new JsonObject
            { ["name"] = clean, ["folders"] = new JsonArray(path), ["use"] = false, ["profile"] = profile }, TimeSpan.FromSeconds(30));
        }
        catch (GatewayException e) when (e.RpcCode == -32601)
        {
            throw new BotWriteException("", "This gateway doesn’t have projects yet. Update Hermes on the computer running Hermes, then try again.");
        }
        var p = answer["project"];
        var id = RosterText.Trimmed(p?["id"]) ?? clean;
        var root = RosterText.Trimmed(p?["primary_path"]) ?? (p?["folders"] as JsonArray)?.Select(f => RosterText.Trimmed(f?["path"])).FirstOrDefault(x => x != null) ?? path;
        var project = new SessionProject(id, RosterText.Trimmed(p?["name"]) ?? clean, root, [root]);
        lock (_gate)
        {
            if (!ProjectsByProfile.TryGetValue(profile, out var list)) ProjectsByProfile[profile] = list = [];
            list.Add(project);
        }
        _projectsReadAt.Remove(profile);
        Raise();
        return project;
    }

    /// Compose: a new chat in `profile` (`session.create`, the profile's own settings); its stored id to open.
    public async Task<string> NewChatAsync(string profile, string? folder = null, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        RefuseWhenReadOnly();
        var p = new JsonObject { ["profile"] = profile, ["follow_profile_config"] = true };
        var made = await Hermes.Core.Settings.SessionCreate.CallAsync(_gw.CallAsync, p, profile, TimeSpan.FromSeconds(30), folder, ct);
        ct.ThrowIfCancellationRequested();
        var id = RosterText.Trimmed(made["stored_session_id"]) ?? RosterText.Trimmed(made["session_id"])
            ?? throw new BotWriteException("", "The gateway didn’t make the new chat.");
        // Its first open only resumes: Hermes answers its history 404 until the first prompt (the Mac's `startsNew`).
        Hermes.Core.Chat.StartedChats.Note(profile, id);
        return id;
    }

    /// Branch in New Chat: `session.branch_stored {cols:96, source:"desktop", profile, parent_session_id, cwd?}`.
    public async Task<string> BranchAsync(SessionSummary s)
    {
        RefuseWhenReadOnly();
        var p = new JsonObject { ["cols"] = 96, ["source"] = "desktop", ["profile"] = s.Profile, ["parent_session_id"] = s.Id };
        if (Row(s.Profile, s.Id)?.Cwd is { } cwd) p["cwd"] = cwd;
        JsonNode answer;
        try { answer = await _gw.CallAsync("session.branch_stored", p, TimeSpan.FromSeconds(60)); }
        catch (GatewayException e) when (e.RpcCode == -32601)
        {
            throw new BotWriteException("", "This gateway can’t branch chats yet. Update Hermes on the computer running Hermes, then try again.");
        }
        _ = RefreshAsync();
        return RosterText.Trimmed(answer["stored_session_id"]) ?? RosterText.Trimmed(answer["session_id"])
            ?? throw new BotWriteException("", "The gateway didn’t make the new chat.");
    }

    /// A refused edit in plain words (SessionActionText.reason).
    public static string ReasonOf(Exception e) => e switch
    {
        BotWriteException w => w.Reason,
        GatewayException { Code: "timeout" } => "Your gateway didn’t answer in time. Try again in a moment.",
        GatewayException { IsConnectionLost: true } => GatewayException.ConnectionLostWords,
        GatewayException { Status: 403 } => "Hermes says this chat belongs to another sign-in. If you made it in Hermes HQ, update Hermes’s notification add-on in Settings › Notifications, then try again.",
        GatewayException g => g.PlainReason,
        _ => e.Message,
    };

    public const string ArchivedWayBack = "Find it in Filter and Sort › Show › Archived.";
    public const string DeleteMessage = "This chat and its history will be deleted from the computer running Hermes.";
}
