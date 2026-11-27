using System.Text.Json.Nodes;
using Hermes.Core.Rpc;

namespace Hermes.Core.Activity;

// One chat's activity (docs/spec/1x-activity.md §3.2): its subagents, task lists and goal, folded from gateway events.
// Port of the per-chat part of HermesKit/Activity/ActivityStore.swift (the Swift store is app-wide and keyed by runtime
// id; here the app keeps one store per open chat). The polls (`subagent.list` 5→30 s, `subagent.tail` 2→16 s, the
// `delegation.status` stale check) stay with the app: this class builds each request and folds each answer, with the
// same "a read answered after a newer change is discarded" guard (pass the `Version` you read when you sent it).

public sealed class ActivityStore
{
    private SubagentRoster _roster = new();
    private TodoState _todos = new();
    private ControlEntry _control = new();
    private bool _native;
    private readonly Dictionary<string, SubagentTail> _tails = new(StringComparer.Ordinal);
    private readonly Dictionary<string, SubagentProgress> _unread = new(StringComparer.Ordinal);
    private readonly HashSet<string> _read = new(StringComparer.Ordinal);
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

    /// A chat's resume bound `runtimeId` (again after a reconnect or a re-mint): the state moves with it.
    public void Bind(string runtimeId, string? storedId = null, string? profile = null)
    {
        RuntimeId = runtimeId;
        if (storedId is not null) StoredId = storedId;
        if (profile is not null) Profile = profile;
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
        _controlReadDue = false;
        Interrupted = false;
        Version = 0;
        ControlVersion = 0;
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

    /// The chat holds a running (or queued) child (its Sessions row says Working…, §8.4).
    public bool HasLiveWork => _roster.LiveCount > 0;

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
        code == -32601 || message.Contains("method not found", StringComparison.OrdinalIgnoreCase);

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
