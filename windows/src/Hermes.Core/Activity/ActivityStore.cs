using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Activity;

// One chat's activity (docs/spec/1x-activity.md §3.2): its subagents, task lists, goal, and background-process claims,
// folded from gateway events. Port of HermesKit/Activity/ActivityStore.swift and HermesKit/Activity/StaleWork.swift.
// The polls (`subagent.list` 5→30 s, `subagent.tail` 2→16 s, `process.list` 5 s, and stale checks) drive this store
// with the same "a read answered after a newer change is discarded" guard (pass the `Version` you read when you sent it).

public sealed class ActivityStore
{
    /// A background process a chat says is running (or was: finished rows linger for a moment).
    /// Port of HermesKit/Activity/StaleWork.swift `ProcessClaim`.
    public sealed record ProcessClaim(string Id, bool Running);

    private sealed class ProcessState(string profile, string? storedId, ValueList<ProcessClaim> claims, int version)
    {
        public string Profile { get; set; } = profile;
        public string? StoredId { get; set; } = storedId;
        public ValueList<ProcessClaim> Claims { get; set; } = claims;
        public int Version { get; set; } = version;
    }

    private SubagentRoster _roster = new();
    private TodoState _todos = new();
    private ControlEntry _control = new();
    private bool _native;
    private readonly Dictionary<string, SubagentTail> _tails = new(StringComparer.Ordinal);
    private readonly Dictionary<string, SubagentProgress> _unread = new(StringComparer.Ordinal);
    private readonly HashSet<string> _read = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ProcessState> _processes = new(StringComparer.Ordinal);
    private bool _controlReadDue;

    public ActivityStore(string profile = "", string? runtimeId = null, string? storedId = null)
    {
        Profile = profile;
        RuntimeId = runtimeId;
        StoredId = storedId;
    }

    /// Seconds since 1970 (tests inject a clock).
    public Func<double> Now { get; set; } = () => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    /// The bot ("" for a nameless launch home); sent as `profile` when non-empty.
    public string Profile { get; private set; }
    /// The runtime id the chat's resume returned. While set, events for other sessions are ignored.
    public string? RuntimeId { get; private set; }
    public string? StoredId { get; private set; }
    /// Stop was pressed until the next send: late subagent and task events of the stopped turn are dropped.
    public bool Interrupted { get; private set; }
    /// Bumped by every applied event or read.
    public int Version { get; private set; }
    /// Bumped by every control snapshot applied from an event or action.
    public int ControlVersion { get; private set; }

    /// Raised when a session's background-process claims change.
    public event Action<string>? ProcessClaimsChanged;
    /// `agents.list` answered -32601 on this connection: not asked again until the next `gateway.ready`.
    public bool AgentsListUnsupported { get; private set; }
    /// `subagent.roster` answered -32601 on this connection: not asked again until the next `gateway.ready`.
    public bool RosterUnsupported { get; private set; }
    /// How many `agents.list` reads went out during stale-process checks.
    public int AgentsListReads { get; private set; }
    /// How many `subagent.roster` reads went out during stale-process checks.
    public int RosterReads { get; private set; }

    /// A chat's resume bound `runtimeId` (again after a reconnect or a re-mint): the state moves with it.
    public void Bind(string runtimeId, string? storedId = null, string? profile = null)
    {
        var previous = RuntimeId;
        RuntimeId = runtimeId;
        if (storedId is not null) StoredId = storedId;
        if (profile is not null) Profile = profile;
        if (previous is not null && previous != runtimeId && _processes.Remove(previous, out var moved))
        {
            moved.Profile = Profile;
            if (StoredId is not null) moved.StoredId = StoredId;
            _processes[runtimeId] = moved;
        }
    }

    /// Sign-out / leaving for good: everything goes.
    public void Reset()
    {
        _roster = new();
        _todos = new();
        _control = new();
        _native = false;
        _tails.Clear();
        _unread.Clear();
        _read.Clear();
        _processes.Clear();
        _controlReadDue = false;
        Interrupted = false;
        Version = 0;
        ControlVersion = 0;
        AgentsListUnsupported = false;
        RosterUnsupported = false;
        AgentsListReads = 0;
        RosterReads = 0;
    }

    // MARK: Reading

    public ChatActivity Snapshot => new()
    {
        RuntimeId = RuntimeId,
        Subagents = _roster.Items,
        LiveTodos = _todos.Live,
        RetainedTodos = _todos.Retained,
        Control = _control,
        NativeSubagentEvents = _native,
        Tails = new Dictionary<string, SubagentTail>(_tails),
        UnreadHelperFailures = new(_unread.Values.OrderBy(s => s.Id, StringComparer.Ordinal)),
    };

    /// Any tracked session currently claims a running background process.
    public bool HasRunningProcessClaims => _processes.Values.Any(p => StaleWork.ClaimsRunning(p.Claims));

    /// The chat holds a running (or queued) child or a running background process (its Sessions row says Working…, §8.4).
    public bool HasLiveWork => _roster.LiveCount > 0 || HasRunningProcessClaims;

    /// Whether a bot profile holds a running child or running background process claim.
    public bool HasLiveWorkForProfile(string profile) =>
        (string.Equals(Profile, profile, StringComparison.Ordinal) && _roster.LiveCount > 0)
        || _processes.Values.Any(p => string.Equals(p.Profile, profile, StringComparison.Ordinal) && StaleWork.ClaimsRunning(p.Claims));

    /// Whether a stored session holds a running child or running background process claim.
    public bool HasLiveWorkForStoredId(string storedId) =>
        (string.Equals(StoredId, storedId, StringComparison.Ordinal) && _roster.LiveCount > 0)
        || _processes.Values.Any(p => string.Equals(p.StoredId, storedId, StringComparison.Ordinal) && StaleWork.ClaimsRunning(p.Claims));

    /// Stored session IDs holding a live helper or running background process (optionally filtered to one profile).
    public HashSet<string> LiveWorkStoredIds(string? profile = null)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        if (_roster.LiveCount > 0 && !string.IsNullOrEmpty(StoredId)
            && (profile is null || string.Equals(Profile, profile, StringComparison.Ordinal)))
            ids.Add(StoredId);
        foreach (var entry in _processes.Values)
        {
            if (string.IsNullOrEmpty(entry.StoredId) || !StaleWork.ClaimsRunning(entry.Claims)) continue;
            if (profile is not null && !string.Equals(entry.Profile, profile, StringComparison.Ordinal)) continue;
            ids.Add(entry.StoredId);
        }
        return ids;
    }

    // MARK: Background-process claims (HermesKit/Activity/ActivityStore.swift §6.6)

    /// Records a chat's active background processes (running or just finished). An empty list forgets the chat.
    public bool SetProcessClaims(string runtimeId, string profile, string? storedId, IEnumerable<ProcessClaim> claims)
    {
        var list = new ValueList<ProcessClaim>(claims);
        if (list.Count == 0)
        {
            if (!_processes.Remove(runtimeId)) return false;
        }
        else if (_processes.TryGetValue(runtimeId, out var existing))
        {
            if (existing.Claims == list && existing.Profile == profile && existing.StoredId == storedId) return false;
            existing.Profile = profile;
            existing.StoredId = storedId;
            existing.Claims = list;
            existing.Version++;
        }
        else
        {
            _processes[runtimeId] = new ProcessState(profile, storedId, list, version: 1);
        }
        ProcessClaimsChanged?.Invoke(runtimeId);
        return true;
    }

    /// Convenience single-chat form using this store's `RuntimeId`, `Profile`, and `StoredId`.
    public bool SetProcessClaims(IEnumerable<ProcessClaim> claims) =>
        SetProcessClaims(RuntimeId ?? "", Profile, StoredId, claims);

    /// Active background-process claims for `runtimeId` (defaults to this store's `RuntimeId`).
    public IReadOnlyList<ProcessClaim> GetProcessClaims(string? runtimeId = null) =>
        _processes.TryGetValue(runtimeId ?? RuntimeId ?? "", out var state) ? state.Claims : ValueList<ProcessClaim>.Empty;

    /// Version watermark for a session's process claims (pass to `ApplyAgentsList` / `ApplySubagentRoster`).
    public int ProcessClaimsVersion(string? runtimeId = null) =>
        _processes.TryGetValue(runtimeId ?? RuntimeId ?? "", out var state) ? state.Version : 0;

    /// Runtime IDs that currently claim at least one running background process.
    public IReadOnlyList<string> ProcessClaimants =>
        _processes.Where(kv => StaleWork.ClaimsRunning(kv.Value.Claims)).Select(kv => kv.Key).ToList();

    /// Resets per-connection unsupported capability flags (called on `gateway.ready`).
    public void ResetConnectionCapabilities()
    {
        AgentsListUnsupported = false;
        RosterUnsupported = false;
    }

    /// When the next finished task list goes away (seconds since 1970); call `ExpireTodos` then.
    public double? NextTodoDeadline => _todos.DropAt;

    /// A `message.complete` / `error` ended a turn on a gateway with goals: read `session.control.read` once (true once).
    public bool TakeControlReadDue()
    {
        var due = _controlReadDue;
        _controlReadDue = false;
        return due;
    }

    // MARK: Events

    private static readonly HashSet<string> SubagentEvents =
    [
        "subagent.spawn_requested", "subagent.start", "subagent.progress", "subagent.thinking", "subagent.tool", "subagent.complete",
    ];

    /// Folds one gateway event; true when the snapshot changed.
    public bool Apply(RpcEvent e)
    {
        if (e.Type == "gateway.ready")
        {
            ResetConnectionCapabilities();
            return false;
        }
        if (RuntimeId is not null && e.SessionId != RuntimeId) return false;
        var p = e.Payload;
        var t = Now();
        var changed = false;
        switch (e.Type)
        {
            case "message.start":
                changed = _roster.PruneFinished();
                if (_native) { _native = false; changed = true; }
                break;
            case var type when SubagentEvents.Contains(type):
                if (Interrupted || p is not JsonObject payload) break;
                if (!_native)
                {
                    _native = true;
                    // Native rows supersede this turn's stand-ins, not unread results saved from earlier turns.
                    foreach (var child in _roster.Items.Where(c => c.IsDelegateStandIn)) _unread.Remove(child.Id);
                    _roster.PruneDelegateStandIns();
                    changed = true;
                }
                var create = type is "subagent.spawn_requested" or "subagent.start";
                if (_roster.Upsert(payload, create, type, t)) changed = true;
                break;
            case "todo.updated":
                if (Interrupted) break;
                if (_todos.Set(TodoRules.ParseTodos(p) ?? [], TodoRules.ParseRevision(p), t)) changed = true;
                break;
            case "tool.start" or "tool.complete":
            {
                if (Interrupted) break;
                var complete = e.Type == "tool.complete";
                var name = ActivityJson.StrOrNull(p.Get("name"));
                var anonymousTodos = name is null && ActivityJson.Has(p, "todos");
                if ((TodoRules.IsTodoTool(name) || anonymousTodos)
                    && TodoRules.NextTodos(_todos.Live ?? ValueList<TodoItem>.Empty, p) is { } todos
                    && _todos.Set(todos, TodoRules.ParseRevision(p), t))
                    changed = true;
                if (name == "delegate_task" && !_native)
                    foreach (var payload2 in SubagentRules.DelegatePayloads(p, complete, e.Type))
                        if (_roster.Upsert(payload2, true, complete ? "delegate.complete" : "delegate.running", t)) changed = true;
                break;
            }
            case "session.control.update":
                if (ControlRules.ParseSnapshot(p.Get("control")) is { } snapshot)
                {
                    if (_control.Snapshot != snapshot || _control.Capability != ControlCapability.Supported)
                    {
                        _control = _control with { Snapshot = snapshot, Capability = ControlCapability.Supported };
                        changed = true;
                    }
                    ControlVersion++;
                }
                break;
            case "message.complete" or "error":
                if (_todos.DropActive()) changed = true;
                if (e.Type == "message.complete" && _roster.PruneLiveDelegateStandIns()) changed = true;
                if (_control.Capability == ControlCapability.Supported) _controlReadDue = true;
                break;
        }
        if (changed) Touch();
        return changed;
    }

    /// The resume (or activate) answer: its `todo_state` (§2.4).
    public bool ApplyResume(JsonNode? result)
    {
        if (result.Get("todo_state") is not { } state) return false;
        var running = ActivityJson.IsBool(result.Get("running"), true);
        if (!_todos.Restore(state, running, Now())) return false;
        Touch();
        return true;
    }

    /// Stop was pressed (true) until the next send clears it (false).
    public void SetInterrupted(bool value) => Interrupted = value;

    /// Stop: the chat's children and task lists go.
    public bool Stopped()
    {
        Interrupted = true;
        var a = _roster.Clear();
        var b = _todos.Clear();
        if (!(a || b)) return false;
        Touch();
        return true;
    }

    /// Drops the finished list whose 4 s linger is over.
    public bool ExpireTodos()
    {
        if (!_todos.Expire(Now())) return false;
        Touch();
        return true;
    }

    /// The person opened and left a failed helper's result: it no longer waits as unread.
    public bool AcknowledgeHelperFailure(string subagentId)
    {
        if (!_unread.Remove(subagentId)) return false;
        _read.Add(subagentId);
        return true;
    }

    private void Touch()
    {
        Version++;
        // Pruning the live roster is not reading a result: failed children wait until acknowledged.
        foreach (var child in _roster.Items)
        {
            if (child.Status == SubagentStatus.Failed && !_read.Contains(child.Id)) _unread[child.Id] = child;
            else _unread.Remove(child.Id);
        }
    }

    // MARK: Read answers

    /// A `subagent.list` answer (`{subagents: […], delegations: […]}`); ignored when the chat changed since `versionWhenSent`.
    public bool ApplyList(JsonNode? result, int versionWhenSent)
    {
        if (Version != versionWhenSent || result.Get("subagents") is not JsonArray rows) return false;
        var children = rows.OfType<JsonObject>().ToList();
        var failed = (result.Get("delegations") as JsonArray)?.OfType<JsonObject>().ToList() ?? [];
        if (!_roster.Reconcile(children, failed, Now())) return false;
        Touch();
        return true;
    }

    /// A `subagent.tail` answer for the child whose detail is open.
    public bool ApplyTail(string subagentId, JsonNode? result)
    {
        var tail = new SubagentTail(ActivityJson.IsBool(result.Get("available"), true),
            ActivityJson.StrOrNull(result.Get("text")) ?? "", ActivityJson.IsBool(result.Get("truncated"), true));
        if (_tails.TryGetValue(subagentId, out var old) && old == tail) return false;
        _tails[subagentId] = tail;
        return true;
    }

    /// The chat claims a live child the gateway can be asked about (no live stand-in, which has no id to look up).
    public bool HasStaleClaim
    {
        get
        {
            var live = _roster.Items.Where(s => s.IsLive).ToList();
            return live.Count > 0 && !live.Any(s => s.IsDelegateStandIn);
        }
    }

    /// A `delegation.status` answer: live children it no longer lists are dropped (the stale check, §4.4).
    public bool ApplyDelegationStatus(JsonNode? answer, int versionWhenSent)
    {
        if (Version != versionWhenSent || answer.Get("active") is not JsonArray active) return false;
        var known = _roster.Items.Select(s => s.Id).ToHashSet(StringComparer.Ordinal);
        var children = active.OfType<JsonObject>().Where(c => known.Contains(ActivityJson.Str(c["subagent_id"]))).ToList();
        var listed = children.Select(c => ActivityJson.Str(c["subagent_id"])).ToHashSet(StringComparer.Ordinal);
        if (!_roster.Items.Any(s => s.IsLive && !listed.Contains(s.Id))) return false;
        if (!_roster.Reconcile(children, null, Now())) return false;
        Touch();
        return true;
    }

    /// A `session.control.read` answer; ignored when an event or action applied a newer snapshot meanwhile.
    public bool ApplyControlRead(JsonNode? result, int controlVersionWhenSent)
    {
        if (ControlVersion != controlVersionWhenSent || ControlRules.ParseSnapshot(result.Get("control")) is not { } snapshot) return false;
        if (_control.Snapshot == snapshot && _control.Capability == ControlCapability.Supported) return false;
        _control = _control with { Snapshot = snapshot, Capability = ControlCapability.Supported };
        return true;
    }

    /// `session.control.read` failed. -32601 / "method not found": no goal on this gateway (don't ask again until
    /// `gateway.ready`). Any other failure keeps the old snapshot (the app shows nothing for a read failure, §6.1).
    public bool ControlReadFailed(int code, string message)
    {
        if (!IsMethodNotFound(code, message) || _control.Capability == ControlCapability.Unsupported) return false;
        _control = _control with { Capability = ControlCapability.Unsupported, Snapshot = null };
        return true;
    }

    public static bool IsMethodNotFound(int code, string message) =>
        code == -32601
        || message.Contains("method not found", StringComparison.OrdinalIgnoreCase)
        || message.Contains("unknown method", StringComparison.OrdinalIgnoreCase);

    /// A `agents.list` answer: running process claims the gateway no longer lists are dropped; finished claims stay.
    /// Ignored when claims changed since `versionWhenSent`.
    public bool ApplyAgentsList(string runtimeId, JsonNode? answer, int versionWhenSent)
    {
        if (!_processes.TryGetValue(runtimeId, out var current) || current.Version != versionWhenSent) return false;
        if (StaleWork.RunningProcesses(answer) is not { } running) return false;
        if (StaleWork.DropProcesses(current.Claims, running) is not { } kept) return false;
        if (kept.Count == 0) _processes.Remove(runtimeId);
        else
        {
            current.Claims = new ValueList<ProcessClaim>(kept);
            current.Version++;
        }
        ProcessClaimsChanged?.Invoke(runtimeId);
        return true;
    }

    public bool ApplyAgentsList(JsonNode? answer, int versionWhenSent) =>
        ApplyAgentsList(RuntimeId ?? "", answer, versionWhenSent);

    /// A `subagent.roster` answer (fallback when `agents.list` returns -32601): drops running process claims for a
    /// non-visible session whose stored id is no longer counted with `background > 0`.
    public bool ApplySubagentRoster(string runtimeId, JsonNode? answer, int versionWhenSent, string? visibleRuntimeId = null)
    {
        if (runtimeId == visibleRuntimeId) return false;
        if (!_processes.TryGetValue(runtimeId, out var current) || current.Version != versionWhenSent) return false;
        if (string.IsNullOrEmpty(current.StoredId)) return false;
        if (StaleWork.BackgroundSessions(answer) is not { } busy || busy.Contains(current.StoredId)) return false;
        var kept = current.Claims.Where(c => !c.Running).ToList();
        if (kept.Count == current.Claims.Count) return false;
        if (kept.Count == 0) _processes.Remove(runtimeId);
        else
        {
            current.Claims = new ValueList<ProcessClaim>(kept);
            current.Version++;
        }
        ProcessClaimsChanged?.Invoke(runtimeId);
        return true;
    }

    /// Reconciles active background-process claims against `agents.list`, falling back to `subagent.roster` when the
    /// gateway lacks `agents.list` (-32601). Port of HermesKit/Activity/ActivityStore.swift `staleProcessCheck`.
    public Task<bool> ReconcileStaleProcessesAsync(HermesClient client, string? visibleRuntimeId = null, CancellationToken ct = default) =>
        ReconcileStaleProcessesAsync((method, p, token) => client.Rpc.RequestAsync(method, p, ReadTimeout, token), visibleRuntimeId, ct);

    public async Task<bool> ReconcileStaleProcessesAsync(
        Func<string, JsonObject, CancellationToken, Task<JsonNode>> call,
        string? visibleRuntimeId = null,
        CancellationToken ct = default)
    {
        var claimants = ProcessClaimants;
        if (claimants.Count == 0) return false;
        if (AgentsListUnsupported)
            return await ReconcileStaleProcessesByRosterAsync(call, claimants, visibleRuntimeId, ct).ConfigureAwait(false);

        var answers = new Dictionary<string, (bool HasAnswer, HashSet<string>? Running)>(StringComparer.Ordinal);
        var changed = false;
        foreach (var rid in claimants)
        {
            if (!_processes.TryGetValue(rid, out var entry)) continue;
            var snapshotVersion = entry.Version;
            var profile = entry.Profile;
            if (!answers.TryGetValue(profile, out var cached))
            {
                AgentsListReads++;
                try
                {
                    var (_, p) = AgentsList(profile);
                    var raw = await call("agents.list", p, ct).ConfigureAwait(false);
                    cached = (true, StaleWork.RunningProcesses(raw));
                }
                catch (GatewayException e) when (BackgroundProcessesApi.IsMethodNotFound(e))
                {
                    AgentsListUnsupported = true;
                    return await ReconcileStaleProcessesByRosterAsync(call, claimants, visibleRuntimeId, ct).ConfigureAwait(false) || changed;
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested)
                {
                    return changed;
                }
                catch (Exception)
                {
                    cached = (true, null);
                }
                answers[profile] = cached;
            }
            if (cached.Running is null) continue;
            if (!_processes.TryGetValue(rid, out var current) || current.Version != snapshotVersion) continue;
            if (StaleWork.DropProcesses(current.Claims, cached.Running) is not { } kept) continue;
            if (kept.Count == 0) _processes.Remove(rid);
            else
            {
                current.Claims = new ValueList<ProcessClaim>(kept);
                current.Version++;
            }
            changed = true;
            ProcessClaimsChanged?.Invoke(rid);
        }
        return changed;
    }

    private async Task<bool> ReconcileStaleProcessesByRosterAsync(
        Func<string, JsonObject, CancellationToken, Task<JsonNode>> call,
        IReadOnlyList<string> claimants,
        string? visibleRuntimeId,
        CancellationToken ct)
    {
        if (RosterUnsupported) return false;
        var answers = new Dictionary<string, (bool HasAnswer, HashSet<string>? Busy)>(StringComparer.Ordinal);
        var changed = false;
        foreach (var rid in claimants)
        {
            if (rid == visibleRuntimeId) continue;
            if (!_processes.TryGetValue(rid, out var entry) || string.IsNullOrEmpty(entry.StoredId)) continue;
            var snapshotVersion = entry.Version;
            var stored = entry.StoredId;
            var profile = entry.Profile;
            if (!answers.TryGetValue(profile, out var cached))
            {
                RosterReads++;
                try
                {
                    var (_, p) = SubagentRosterRequest(profile);
                    var raw = await call("subagent.roster", p, ct).ConfigureAwait(false);
                    cached = (true, StaleWork.BackgroundSessions(raw));
                }
                catch (GatewayException e) when (BackgroundProcessesApi.IsMethodNotFound(e))
                {
                    RosterUnsupported = true;
                    return changed;
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested)
                {
                    return changed;
                }
                catch (Exception)
                {
                    cached = (true, null);
                }
                answers[profile] = cached;
            }
            if (cached.Busy is null || cached.Busy.Contains(stored)) continue;
            if (rid == visibleRuntimeId || !_processes.TryGetValue(rid, out var current) || current.Version != snapshotVersion) continue;
            var kept = current.Claims.Where(c => !c.Running).ToList();
            if (kept.Count == current.Claims.Count) continue;
            if (kept.Count == 0) _processes.Remove(rid);
            else
            {
                current.Claims = new ValueList<ProcessClaim>(kept);
                current.Version++;
            }
            changed = true;
            ProcessClaimsChanged?.Invoke(rid);
        }
        return changed;
    }

    /// A goal action went out: every goal action is disabled until it answers.
    public void BeginControl(string action) => _control = _control with { PendingAction = action, ActionError = null };

    /// The goal action's answer: its `control` applies at once (§6.4); returns its `dispatch`.
    public ControlDispatch EndControl(JsonNode? result)
    {
        _control = _control with { PendingAction = null };
        if (ControlRules.ParseSnapshot(result.Get("control")) is { } snapshot)
            _control = _control with { Snapshot = snapshot, Capability = ControlCapability.Supported };
        ControlVersion++;
        return ControlRules.ParseDispatch(result.Get("dispatch"));
    }

    /// The goal action failed: the card's red row reads "Action failed: …".
    public void FailControl(string message) =>
        _control = _control with { PendingAction = null, ActionError = ControlRules.ActionFailure(message) };

    /// The card's ✕ (null), or a busy-goal message.
    public bool SetControlError(string? message)
    {
        if (_control.ActionError == message) return false;
        _control = _control with { ActionError = message };
        return true;
    }

    // MARK: Requests (method + params, for `client.Rpc.RequestAsync`; the Swift sends each with a 15 s timeout)

    public static readonly TimeSpan ReadTimeout = TimeSpan.FromSeconds(15);

    /// `{session_id, profile?, …extra}`: the profile only when non-empty (params are strict).
    public static JsonObject Params(string runtimeId, string? profile, params (string Key, JsonNode? Value)[] extra)
    {
        var p = new JsonObject { ["session_id"] = runtimeId };
        if (!string.IsNullOrEmpty(profile)) p["profile"] = profile;
        foreach (var (key, value) in extra) p[key] = value;
        return p;
    }

    /// The visible chat's roster while it has a live child (§4.4). Answer → `ApplyList`.
    public static (string Method, JsonObject Params) SubagentList(string runtimeId, string? profile) =>
        ("subagent.list", Params(runtimeId, profile));

    /// An open child's output (§4.4). Answer → `ApplyTail`.
    public static (string Method, JsonObject Params) SubagentTailRequest(string runtimeId, string? profile, string subagentId) =>
        ("subagent.tail", Params(runtimeId, profile, ("subagent_id", subagentId)));

    /// The stale-claim check, one per bot: `{profile}`, or `{}` for the nameless home. Answer → `ApplyDelegationStatus`.
    public static (string Method, JsonObject Params) DelegationStatus(string? profile) =>
        ("delegation.status", string.IsNullOrEmpty(profile) ? new JsonObject() : new JsonObject { ["profile"] = profile });

    /// Stale background-process check via `agents.list`: `{}` for default/empty, else `{profile}`.
    public static (string Method, JsonObject Params) AgentsList(string? profile) =>
        ("agents.list", BackgroundProcessesApi.ProfileParams(profile));

    /// Fallback stale background-process check via `subagent.roster`: `{}` for default/empty, else `{profile}`.
    public static (string Method, JsonObject Params) SubagentRosterRequest(string? profile) =>
        ("subagent.roster", BackgroundProcessesApi.ProfileParams(profile));

    /// The goal snapshot (§6.1). Answer → `ApplyControlRead`.
    public static (string Method, JsonObject Params) ControlRead(string runtimeId, string? profile) =>
        ("session.control.read", Params(runtimeId, profile));

    /// One goal action (`GoalActions.*`). Answer → `EndControl`; failure → `FailControl`.
    public static (string Method, JsonObject Params) Control(string runtimeId, string? profile, string action, JsonObject? args = null) =>
        ("session.control", Params(runtimeId, profile, ("action", action), ("args", args ?? new JsonObject())));

    /// Steer a running child (§4.3): null when the text is blank (rejected without asking). Answer → `ReadSteer`.
    public static (string Method, JsonObject Params)? Steer(string runtimeId, string? profile, string subagentId, string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return null;
        return ("subagent.steer", Params(runtimeId, profile, ("subagent_id", subagentId), ("text", trimmed)));
    }

    /// Stop a child (§4.3). Answer → `ReadInterrupt`.
    public static (string Method, JsonObject Params) StopChild(string runtimeId, string? profile, string subagentId) =>
        ("subagent.interrupt", Params(runtimeId, profile, ("subagent_id", subagentId)));

    /// `{status: "queued"}` → Queued; anything else (or a failed call: pass null) → Rejected.
    public static SteerOutcome ReadSteer(JsonNode? result) =>
        ActivityJson.StrOrNull(result.Get("status")) == "queued" ? SteerOutcome.Queued : SteerOutcome.Rejected;

    /// true: the stop reached it (its row ends with its `subagent.complete`); false: already finished, or refused.
    public static bool ReadInterrupt(JsonNode? result) => ActivityJson.IsBool(result.Get("found"), true);

    /// The instance forms, with this chat's runtime id and profile.
    public (string Method, JsonObject Params)? Steer(string subagentId, string text) =>
        RuntimeId is { } rid ? Steer(rid, Profile, subagentId, text) : null;
    public (string Method, JsonObject Params)? StopChild(string subagentId) =>
        RuntimeId is { } rid ? StopChild(rid, Profile, subagentId) : null;
    public (string Method, JsonObject Params)? Control(string action, JsonObject? args = null) =>
        RuntimeId is { } rid ? Control(rid, Profile, action, args) : null;
}

/// Process-claim reconciliation helpers (port of HermesKit/Activity/StaleWork.swift).
public static class StaleWork
{
    /// The IDs `agents.list` reports as running; null when the answer has no `processes` list.
    public static HashSet<string>? RunningProcesses(JsonNode? answer)
    {
        if (answer.Get("processes") is not JsonArray rows) return null;
        var running = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            if (row is null || ActivityJson.StrOrNull(row.Get("status")) != "running") continue;
            var id = row.Text("session_id") ?? row.Text("id");
            if (id is not null) running.Add(id);
        }
        return running;
    }

    /// The claims less the running ones the gateway no longer has; null when nothing changes. Finished rows stay.
    public static List<ActivityStore.ProcessClaim>? DropProcesses(
        IReadOnlyList<ActivityStore.ProcessClaim> claims, IReadOnlySet<string> running)
    {
        if (!claims.Any(c => c.Running && !running.Contains(c.Id))) return null;
        return claims.Where(c => !c.Running || running.Contains(c.Id)).ToList();
    }

    public static bool ClaimsRunning(IEnumerable<ActivityStore.ProcessClaim> claims) =>
        claims.Any(c => c.Running);

    /// The stored chats `subagent.roster` says still hold a background process (`background > 0`);
    /// null when the answer has no `sessions` list.
    public static HashSet<string>? BackgroundSessions(JsonNode? answer)
    {
        if (answer.Get("sessions") is not JsonArray rows) return null;
        var outSet = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            if (row is null) continue;
            var id = row.Text("session_id");
            if (id is not null && ActivityJson.Num(row.Get("background")) is > 0) outSet.Add(id);
        }
        return outSet;
    }
}

/// The goal actions the card and its ⋯ menu send through `session.control` (App/Chat/Activity/ChatActivityController.swift).
public static class GoalActions
{
    public const string Pause = "goal.pause";
    public const string Resume = "goal.resume";
    /// "Resume Now" while a wait condition holds.
    public const string Unwait = "goal.unwait";
    public const string Clear = "goal.clear";
    /// args `{text}`.
    public const string AddCriterion = "subgoal.add";
    /// args `{index}` (1-based).
    public const string RemoveCriterion = "subgoal.remove";
    public const string ClearCriteria = "subgoal.clear";

    public static JsonObject AddCriterionArgs(string text) => new() { ["text"] = text.Trim() };
    public static JsonObject RemoveCriterionArgs(int index) => new() { ["index"] = (double)index };
}
