using System.Globalization;
using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Groups;

// [groups] One member's turn in a room (HermesKit/Groups/GroupTurn.swift; docs/spec/3x-groups.md §6.6–§6.7): its
// hidden session, the baseline, the submit, the wait and the pick. A port of `HB/group-turns.ts:278-445, 859-1286` over
// the account's JSON-RPC socket (§4.4). Like the Mac's main actor, a turn runs on the caller's synchronization context
// (the UI thread in the app); only GroupSignals is touched from the socket's read thread.

/// What the room engine needs of the account's gateway: its calls, and its event frames.
public interface IGroupGateway
{
    Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default);
    /// Every event frame, on any thread (RpcConnection.Event).
    event Action<RpcEvent>? Event;
}

/// The app's account as the room engine's gateway.
public sealed class ClientGroupGateway(HermesClient client) : IGroupGateway
{
    public Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default) =>
        client.Rpc.RequestAsync(method, parameters, timeout, ct);

    public event Action<RpcEvent>? Event
    {
        add => client.Rpc.Event += value;
        remove => client.Rpc.Event -= value;
    }
}

public sealed class GroupTiming
{
    /// Base time limit of a turn, extended while the session is busy or waits for your answer.
    public TimeSpan Base { get; set; } = TimeSpan.FromSeconds(180);
    public TimeSpan HardCap { get; set; } = TimeSpan.FromMinutes(180);
    /// The read after a silent stretch, and between reads of a busy session.
    public TimeSpan Poll { get; set; } = TimeSpan.FromSeconds(5);
    public TimeSpan Settle { get; set; } = TimeSpan.FromSeconds(0.25);
    public int SettleChecks { get; set; } = 8;
    public TimeSpan HarvestEvery { get; set; } = TimeSpan.FromSeconds(5);
    public TimeSpan Call { get; set; } = TimeSpan.FromSeconds(30);

    /// The Mac's DEBUG `-HQGroupsTurnLimit 6` (UI tests strand a turn in seconds) is the environment's
    /// `HQGroupsTurnLimit` here: a turn that stays busy is given up at twice the limit.
    public static GroupTiming Standard
    {
        get
        {
            var timing = new GroupTiming();
            if (double.TryParse(Environment.GetEnvironmentVariable("HQGroupsTurnLimit"), NumberStyles.Float, CultureInfo.InvariantCulture, out var limit) && limit > 0)
            {
                timing.Base = TimeSpan.FromSeconds(limit);
                timing.HardCap = TimeSpan.FromSeconds(limit * 2);
                timing.Poll = TimeSpan.FromSeconds(Math.Min(timing.Poll.TotalSeconds, Math.Max(1, limit / 3)));
                timing.HarvestEvery = TimeSpan.FromSeconds(2);
            }
            return timing;
        }
    }
}

/// A member's hidden session as one `session.resume` answered it.
public sealed class GroupSessionState
{
    public sealed record Row(string Role, string Text);

    public string Runtime { get; set; }
    public string? Stored { get; set; }
    public List<Row> Rows { get; } = [];
    public bool Running { get; }
    public bool HasInflight { get; }
    /// A kept `{status: "error"}`: the turn failed, the session is not busy.
    public string? RetainedError { get; }
    public string? RetainedKey { get; }
    public bool WaitingOnUser { get; }
    /// `EnsureSessionAsync` made this session just now (`fresh`): it has no transcript yet.
    public bool Fresh { get; set; }
    /// The answer said whether the session is busy (`running` or `inflight` present). A light read (`omit_messages`)
    /// from a gateway that dropped them says nothing, so its "not busy" can't be trusted.
    public bool BusyKnown { get; } = true;

    /// `groupSessionBusy`.
    public bool Busy => Running || (HasInflight && RetainedError == null);

    private GroupSessionState(string runtime) => Runtime = runtime;

    public static GroupSessionState? Parse(JsonNode? result)
    {
        if (GroupMember.Str(result, "session_id")?.Trim(' ', '\t') is not { Length: > 0 } runtime) return null;
        return new GroupSessionState(runtime, result!);
    }

    private GroupSessionState(string runtime, JsonNode result)
    {
        Runtime = runtime;
        Stored = GroupMember.Str(result, "session_key") ?? GroupMember.Str(result, "stored_session_id") ?? GroupMember.Str(result, "resumed");
        Running = result.Get("running") is JsonValue r && r.TryGetValue(out bool running) && running;
        var o = result as JsonObject;
        BusyKnown = o != null && (o.ContainsKey("running") || o.ContainsKey("inflight"));
        if (o != null && o.TryGetPropertyValue("inflight", out var inflight) && inflight != null)
        {
            HasInflight = true;
            if (GroupMember.Str(inflight, "status") == "error")
            {
                RetainedError = GroupMember.Str(inflight, "error") ?? "turn failed";
                RetainedKey = $"{SwiftNumber(GroupPrompt.Number(result.Get("turn_started_at")) ?? 0)}|{RetainedError}";
            }
        }
        var open = result.Arr("open_requests") ?? [];
        var approval = o != null && o.TryGetPropertyValue("pending_approval", out var a) && a != null;
        WaitingOnUser = open.Any(req => (GroupMember.Str(req, "method") ?? GroupMember.Str(req, "kind") ?? "").StartsWith("clarify", StringComparison.Ordinal)) || approval;
        foreach (var message in result.Arr("messages") ?? [])
        {
            string text;
            if (GroupMember.Str(message, "content") is { } content) text = content;
            else if (message.Arr("content") is { } parts)
                text = string.Concat(parts.Select(p => p is JsonValue v && v.TryGetValue(out string? s) ? s : GroupMember.Str(p, "text") ?? ""));
            else text = GroupMember.Str(message, "text") ?? "";
            Rows.Add(new Row(GroupMember.Str(message, "role") ?? "", text));
        }
    }

    /// Swift's `"\(double)"`: 12 → "12.0".
    internal static string SwiftNumber(double d) =>
        d == Math.Floor(d) && Math.Abs(d) < 1e16 ? d.ToString("0.0", CultureInfo.InvariantCulture) : d.ToString("R", CultureInfo.InvariantCulture);
}

public enum GroupTurnFailure
{
    /// The session check failed with something other than "does not exist": never start a second session.
    Check,
    /// The prompt never went out (the member did not take the message).
    NotSent,
    /// The prompt went out and the turn failed.
    Failed,
    /// The prompt went out and no reply came in time: it may still land (§6.7).
    TimedOut,
    Cancelled,
}

public sealed class GroupTurnException(GroupTurnFailure kind, string text = "", int before = 0, string? stored = null)
    : Exception(text)
{
    public GroupTurnFailure Kind { get; } = kind;
    public string Text { get; } = text;
    public int Before { get; } = before;
    public string? Stored { get; } = stored;

    public string Reason => Kind switch
    {
        GroupTurnFailure.TimedOut => "took too long",
        GroupTurnFailure.Cancelled => "cancelled",
        _ => Text,
    };

    public static GroupTurnException Cancelled() => new(GroupTurnFailure.Cancelled);
}

/// `message.complete` / `error` events by runtime id, for the turn's wait. Fired from the socket's read thread.
public sealed class GroupSignals
{
    public const int FiredLimit = 64;
    private readonly object gate = new();
    private readonly Dictionary<Guid, (string Runtime, TaskCompletionSource<bool> Done)> waiters = [];
    /// When each runtime last ended a turn: a signal that lands between two waits (during a read) is not lost.
    private readonly Dictionary<string, DateTimeOffset> fired = [];
    private IGroupGateway? source;

    public IReadOnlyDictionary<string, DateTimeOffset> Fired { get { lock (gate) return new Dictionary<string, DateTimeOffset>(fired); } }

    public void Start(IGroupGateway client)
    {
        lock (gate)
        {
            if (source != null) return;
            source = client;
        }
        client.Event += OnEvent;
    }

    private void OnEvent(RpcEvent e)
    {
        if (e.Type is "message.complete" or "error") Fire(e.SessionId);
    }

    public void Stop()
    {
        IGroupGateway? was;
        lock (gate)
        {
            was = source;
            source = null;
            fired.Clear();
        }
        if (was != null) was.Event -= OnEvent;
        WakeAll();
    }

    public void Fire(string runtime)
    {
        var wake = new List<TaskCompletionSource<bool>>();
        lock (gate)
        {
            fired[runtime] = DateTimeOffset.UtcNow;
            if (fired.Count > FiredLimit) fired.Remove(fired.MinBy(kv => kv.Value).Key);
            foreach (var (id, waiter) in waiters.Where(w => w.Value.Runtime == runtime).ToList())
            {
                waiters.Remove(id);
                wake.Add(waiter.Done);
            }
        }
        foreach (var done in wake) done.TrySetResult(true);
    }

    /// Stop and delete wake every wait at once (the turn then sees it is no longer current).
    public void WakeAll()
    {
        List<TaskCompletionSource<bool>> all;
        lock (gate)
        {
            all = [.. waiters.Values.Select(w => w.Done)];
            waiters.Clear();
        }
        foreach (var done in all) done.TrySetResult(false);
    }

    /// true when the session's turn ended within `wait`, or already ended after `since`.
    public Task<bool> WaitAsync(string runtime, TimeSpan wait, DateTimeOffset since)
    {
        var id = Guid.NewGuid();
        var done = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (gate)
        {
            if (fired.TryGetValue(runtime, out var at) && at > since) return Task.FromResult(true);
            waiters[id] = (runtime, done);
        }
        _ = Task.Delay(wait < TimeSpan.FromMilliseconds(50) ? TimeSpan.FromMilliseconds(50) : wait).ContinueWith(_ =>
        {
            bool mine;
            lock (gate) mine = waiters.Remove(id);
            if (mine) done.TrySetResult(false);
        }, TaskScheduler.Default);
        return done.Task;
    }
}

public sealed class GroupTurn(IGroupGateway client, GroupSignals signals, GroupTiming? timing = null)
{
    public IGroupGateway Client { get; } = client;
    public GroupSignals Signals { get; } = signals;
    public GroupTiming Timing { get; set; } = timing ?? GroupTiming.Standard;

    /// Words for why a turn failed (RPCError.plainReason, GroupTurnError.reason).
    public static string Reason(Exception error) => error switch
    {
        GroupTurnException turn => turn.Reason,
        GatewayException { Code: "rpc" or "timeout" } or GatewayException { IsConnectionLost: true } or GatewayException { IsNotConnected: true }
            => ((GatewayException)error).PlainReason,
        // A transport failure that is no RPCError on the Mac (a URLError there): the lost-link sentence, as before.
        GatewayException { Code: "offline" } => GatewayException.ConnectionLostWords,
        _ => error.Message,
    };

    private static bool IsRpc(Exception e, out GatewayException rpc)
    {
        rpc = (e as GatewayException)!;
        return rpc is { Code: "rpc" };
    }

    /// `isSessionGoneError`: the runtime id is not live any more (resume by the stored id, then go on).
    public static bool IsGone(Exception error)
    {
        if (!IsRpc(error, out var rpc)) return false;
        var message = rpc.Message.ToLowerInvariant();
        return rpc.RpcCode == 4001 || message.Contains("not in memory") || message.Contains("session not found");
    }

    /// "This session doesn't exist": 4007 on the plain chat helper; on a gateway-hosted Hermes's session authority
    /// every refusal is 4001 and its reason says which, so `4001 not_found` is the same answer.
    public static bool IsAbsent(GatewayException error)
    {
        if (error.Code != "rpc") return false;
        if (error.RpcCode == 4007) return true;
        if (error.RpcCode != 4001) return false;
        return error.Message == "not_found" || (error.Body is { } body && GroupMember.Str(J.Parse(body), "reason") == "not_found");
    }

    public async Task<GroupSessionState> ReadAsync(string target, string profile, bool messages)
    {
        var p = new JsonObject { ["session_id"] = target, ["profile"] = profile };
        if (!messages) p["omit_messages"] = true;
        var result = await Client.CallAsync("session.resume", p, Timing.Call);
        return GroupSessionState.Parse(result) ?? throw new GatewayException("rpc", "Missing group runtime", rpcCode: -1);
    }

    private async Task<GroupSessionState?> TryReadAsync(string target, string profile, bool messages)
    {
        try { return await ReadAsync(target, profile, messages); }
        catch (Exception) { return null; }
    }

    /// The newest assistant message after `before` with real text; a `(pass)` only when nothing else is there.
    public static string? Pick(IReadOnlyList<GroupSessionState.Row> rows, int before)
    {
        string? pass = null;
        for (var index = rows.Count - 1; index >= Math.Max(0, before); index--)
        {
            var row = rows[index];
            if (row.Role != "assistant") continue;
            var text = row.Text.Trim();
            if (text.Length == 0) continue;
            if (GroupPrompt.IsPass(text)) { pass ??= text; continue; }
            return text;
        }
        return pass;
    }

    /// `ensureGroupChatSession`: the member's hidden session for this thread, found or made once.
    public async Task<GroupSessionState> EnsureSessionAsync(GroupRoom room, string thread, GroupSeat seat, string idempotencyKey, Action<string> save)
    {
        var roomTitle = $"Group: {room.RoomId ?? room.Name}";
        var title = $"{roomTitle} · {thread}";
        var known = room.Sessions.GetValueOrDefault(GroupKeys.SessionKey(thread, seat.Key));
        var scoped = room.Sessions.Keys.Any(k => k.StartsWith("thread:", StringComparison.Ordinal) && k.EndsWith($"::{seat.Key}", StringComparison.Ordinal));
        var legacy = scoped ? null : room.Sessions.GetValueOrDefault(seat.Key);
        var targets = new[] { known, title }.OfType<string>().ToList();
        if (legacy != null) targets.AddRange([legacy, roomTitle]);
        foreach (var target in targets.Where(t => t.Length > 0))
        {
            var attempt = 0;
            while (true)
            {
                attempt++;
                try
                {
                    var state = await ReadAsync(target, seat.Name, messages: false);
                    var stored = state.Stored ?? (target == title || target == roomTitle ? known : target);
                    if (stored != null) save(stored);
                    state.Stored = stored;
                    return state;
                }
                catch (GatewayException error) when (IsAbsent(error))
                {
                    // Does not exist: the next target. A 4007 that says "no longer live" is asked once more.
                    if (attempt == 1 && error.RpcCode == 4007 && error.Message.Contains("no longer live", StringComparison.OrdinalIgnoreCase)) continue;
                    break;
                }
                catch (OperationCanceledException)
                {
                    throw GroupTurnException.Cancelled();
                }
                catch (Exception error)
                {
                    throw new GroupTurnException(GroupTurnFailure.Check,
                        $"Couldn’t check {seat.Display}'s group session ({Reason(error)}) — not starting a new one");
                }
            }
        }
        JsonObject Params() => new()
        {
            ["profile"] = seat.Name, ["title"] = title, ["hidden"] = true, ["room_plumbing"] = true,
            ["follow_profile_config"] = true, ["idempotency_key"] = idempotencyKey,
        };
        JsonNode created;
        try { created = await Client.CallAsync("session.create", Params(), Timing.Call); }
        catch (GatewayException error) when (error.Code is "offline" or "timeout")
        {
            // A lost answer: the same key answers the same session, never a second one.
            created = await Client.CallAsync("session.create", Params(), Timing.Call);
        }
        var made = GroupSessionState.Parse(created) ?? throw new GroupTurnException(GroupTurnFailure.NotSent, $"The gateway did not start a session for {seat.Display}.");
        made.Stored = GroupMember.Str(created, "stored_session_id") ?? made.Stored;
        made.Fresh = true;
        if (made.Stored is { } s2) save(s2);
        return made;
    }

    /// Runs the turn. Returns the member's reply text (null = nothing to post). `onRuntime` gets the live runtime id as
    /// soon as it is known (and again when it changes); `onWaiting` follows "waits for your answer". `freshContext`:
    /// the room's other threads, added to the prompt only when this turn makes the member's session.
    public async Task<string?> RunAsync(GroupRoom room, string thread, GroupSeat seat, string basePrompt, IReadOnlyList<string> freshContext,
        Func<bool> isCurrent, Action<string> save, Action<string, string?> onRuntime, Action<int, string?> onAccepted, Action<bool> onWaiting)
    {
        GroupSessionState session;
        try { session = await EnsureSessionAsync(room, thread, seat, Guid.NewGuid().ToString().ToLowerInvariant(), save); }
        catch (GroupTurnException) { throw; }
        catch (Exception error) { throw new GroupTurnException(GroupTurnFailure.NotSent, Reason(error)); }
        if (!isCurrent()) throw GroupTurnException.Cancelled();
        var prompt = session.Fresh ? GroupPrompt.AddFreshThreadContext(basePrompt, freshContext) : basePrompt;
        var stored = session.Stored ?? session.Runtime;
        var runtime = session.Runtime;
        // Baseline: how long the transcript is now, and a failure left over from an earlier turn.
        int before;
        string? staleError;
        try
        {
            var baseline = await ReadAsync(stored, seat.Name, messages: true);
            runtime = baseline.Runtime;
            before = baseline.Rows.Count;
            staleError = baseline.RetainedKey;
        }
        catch (Exception error) { throw new GroupTurnException(GroupTurnFailure.NotSent, Reason(error)); }
        if (!isCurrent()) throw GroupTurnException.Cancelled();
        onRuntime(runtime, session.Stored);
        Task Submit(string id) => Client.CallAsync("prompt.submit", new JsonObject { ["session_id"] = id, ["profile"] = seat.Name, ["text"] = prompt }, Timing.Call);
        var submitted = DateTimeOffset.UtcNow;
        try
        {
            try { await Submit(runtime); }
            catch (Exception error) when (IsGone(error))
            {
                var again = await ReadAsync(stored, seat.Name, messages: false);
                runtime = again.Runtime;
                onRuntime(runtime, session.Stored);
                await Submit(runtime);
            }
        }
        catch (Exception error) { throw new GroupTurnException(GroupTurnFailure.NotSent, Reason(error)); }
        onAccepted(before, session.Stored);
        // Signals count from the submit on (an earlier turn's end on this runtime never does). Moved on after each wait,
        // so a signal that lands during a read wakes the next wait at once, and each one counts only once.
        var since = submitted;
        var started = DateTimeOffset.UtcNow;
        var deadline = started + Timing.Base;
        var hardStop = started + Timing.HardCap;
        var waiting = false;
        try
        {
            while (true)
            {
                if (!isCurrent()) throw GroupTurnException.Cancelled();
                var signalled = await Signals.WaitAsync(runtime, Timing.Poll, since);
                since = DateTimeOffset.UtcNow;
                if (!isCurrent()) throw GroupTurnException.Cancelled();
                // Light reads while it works; the full read only once it says it's done, or didn't say. A light "not
                // busy" never picks.
                var state = await TryReadAsync(stored, seat.Name, messages: false);
                if (signalled)
                {
                    var checks = 0;
                    while (state is { Busy: true } && checks < Timing.SettleChecks)
                    {
                        checks++;
                        await Task.Delay(Timing.Settle);
                        state = await TryReadAsync(stored, seat.Name, messages: false);
                    }
                }
                if (state is { } light && (!light.Busy || !light.BusyKnown)) state = await TryReadAsync(stored, seat.Name, messages: true);
                if (!isCurrent()) throw GroupTurnException.Cancelled();
                if (state != null)
                {
                    if (state.Runtime != runtime) { runtime = state.Runtime; onRuntime(runtime, session.Stored); }
                    if (state.WaitingOnUser != waiting) { waiting = state.WaitingOnUser; onWaiting(waiting); }
                    if (!state.Busy)
                    {
                        if (Pick(state.Rows, before) is { } reply) return reply;
                        if (state.RetainedError is { } error && state.RetainedKey != staleError) throw new GroupTurnException(GroupTurnFailure.Failed, error);
                        if (signalled) return null;   // the turn ended and left nothing to post
                    }
                    else deadline = Min(hardStop, DateTimeOffset.UtcNow + Timing.Base);
                    if (state.WaitingOnUser) deadline = Min(hardStop, DateTimeOffset.UtcNow + Timing.Base);
                }
                if (DateTimeOffset.UtcNow >= deadline) throw new GroupTurnException(GroupTurnFailure.TimedOut, before: before, stored: session.Stored);
            }
        }
        finally
        {
            if (waiting) onWaiting(false);
        }
    }

    private static DateTimeOffset Min(DateTimeOffset a, DateTimeOffset b) => a < b ? a : b;

    public enum HarvestKind { Busy, Reply, Nothing }
    public sealed record Harvest(HarvestKind Kind, string? Text = null)
    {
        public static readonly Harvest Busy = new(HarvestKind.Busy), Nothing = new(HarvestKind.Nothing);
    }

    /// `harvestStrandedGroupReply`: a timed-out turn's session read again.
    public async Task<Harvest> HarvestAsync(GroupStranded marker, string profile)
    {
        // Light first: a member still at work costs no transcript download.
        if (marker.Stored is not { } stored || await TryReadAsync(stored, profile, messages: false) is not { } light) return Harvest.Busy;
        if (light.Busy) return Harvest.Busy;
        if (await TryReadAsync(stored, profile, messages: true) is not { } state) return Harvest.Busy;
        if (state.Busy) return Harvest.Busy;
        if (Pick(state.Rows, marker.Before) is { } reply && !GroupPrompt.IsPass(reply)) return new Harvest(HarvestKind.Reply, reply);
        return Harvest.Nothing;
    }
}

/// A room's Stop (row L467, `S/group-interrupt.ts`): the interrupt goes to the session's **live** runtime id, asked for
/// first by its stored id. Any failure answers false ("could not confirm").
public static class GroupInterrupt
{
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(15);

    public static async Task<bool> InterruptAsync(IGroupGateway client, string profile, string storedId)
    {
        try
        {
            var resumed = await client.CallAsync("session.resume", new JsonObject { ["session_id"] = storedId, ["omit_messages"] = true, ["profile"] = profile }, Timeout);
            var runtime = (GroupMember.Str(resumed, "session_id") ?? "").Trim();
            if (runtime.Length == 0) return false;
            var result = await client.CallAsync("session.interrupt", new JsonObject { ["session_id"] = runtime, ["profile"] = profile }, Timeout);
            return GroupMember.Str(result, "status") is "interrupted" or "not_interrupted";
        }
        catch (Exception)
        {
            return false;
        }
    }
}
