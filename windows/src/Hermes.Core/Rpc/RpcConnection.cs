using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Questions;

namespace Hermes.Core.Rpc;

public sealed record RpcEvent(string Type, string SessionId, JsonNode? Payload, long? Seq)
{
    /// [authority] The turn this frame belongs to (`execution_generation`, sent by a gateway-hosted Hermes's session
    /// authority; HermesKit/Contracts.swift `generation`).
    public long? Generation { get; init; }
}

public enum ConnectionState { Connecting, Open, Offline, SignedOut }

/// The one /api/ws socket per account (HermesKit/Net/GatewayConnection.swift, spec 01 §9–§13). JSON-RPC 2.0, one
/// object per text frame. A fresh single-use ticket per dial, heartbeat when gateway.ready asks for it, full-jitter
/// reconnect, and seq replay with session.events.since when the server's replay_epoch hasn't changed.
///
/// [questions] `client.capabilities {"server_requests":true}` is the first frame on every socket (spec 1x §2.1, which
/// replaces D1). Server→client requests (string ids "srq-…") surface through ServerRequest; the still-open requests a
/// session.resume / session.activate / session.events.since result carries come through ServerRequest (replayed) and
/// OpenRequests before its caller sees the result (spec 1x §2.4). RespondAsync / FailAsync answer them.
public sealed class RpcConnection : IAsyncDisposable
{
    private sealed record Pending(TaskCompletionSource<JsonNode> Tcs, string Method, string? SessionParam);

    private readonly GatewaySession _session;
    private readonly CancellationTokenSource _life = new();
    private readonly ConcurrentDictionary<long, Pending> _pending = new();
    private readonly SemaphoreSlim _sendGate = new(1, 1);
    private readonly ReplayBook _replayBook = new();
    private readonly object _deliverGate = new();
    private TaskCompletionSource _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly object _readyGate = new();
    private ClientWebSocket? _ws;
    private long _nextId;
    private string? _epoch;
    private DateTimeOffset _lastInbound = DateTimeOffset.UtcNow;
    private Task? _loop;
    // [WIN-HEARTBEAT-RESILIENT] gateway.ping frames sent with no reply yet (Swift `heartbeatsOutstanding`).
    private int _heartbeatsOutstanding;
    // [questions] The socket generation (an answer's epoch), its capabilities call, and its declines_not_shown.
    private int _socketEpoch;
    private long _capabilitiesId = -1;
    private volatile bool _declinesNotShown;
    private volatile bool _socketReady;
    private volatile bool _heartbeatLapsed;
    // [authority] This socket's gateway.ready named the session authority; each session's latest turn.
    private volatile bool _sessionAuthority;
    private readonly Dictionary<string, long> _generations = new();

    /// Deadline for one reconnect replay batch (tests may shorten).
    internal TimeSpan ReplayDeadline { get; set; } = TimeSpan.FromSeconds(10);
    /// Per-session `session.events.since` timeout (tests may shorten).
    internal TimeSpan ReplayRequestTimeout { get; set; } = TimeSpan.FromSeconds(10);

    public ConnectionState State { get; private set; } = ConnectionState.Connecting;
    public JsonNode? ReadyPayload { get; private set; }

    // [offline] What the offline screen and the reconnect notice read (docs/spec/3x-offline.md §3.6, §5.1).
    private CancellationTokenSource? _wake;
    /// When the next automatic dial is due; null while a dial runs or the socket is open.
    public DateTimeOffset? NextRetry { get; private set; }
    /// Why the last dial failed, as the offline screen's reason codes: unreachable, timeout, rate-limited,
    /// gateway-outdated, host-rejected, not-hermes, tls. Null once a dial gets through.
    public string? LastFailure { get; private set; }
    /// Dials that failed in a row since the socket was last open.
    public int FailedDials { get; private set; }
    /// Has the socket ever opened in this connection's life (the launch's "first connection").
    public bool EverOpen { get; private set; }
    /// NextRetry or LastFailure changed.
    public event Action? RetryChanged;

    /// Every event frame, in arrival order, on a background thread. Replayed frames come through here too.
    public event Action<RpcEvent>? Event;
    public event Action<ConnectionState>? StateChanged;
    /// After each gateway.ready (first connect and every reconnect). True when the server restarted (new epoch), so
    /// REST is the authority and open chats should re-read history.
    public event Action<bool>? Reconnected;
    /// [questions] A server→client request (approval, clarify, sudo, …), live or re-delivered from a result's
    /// open_requests, on the read loop's thread, in order with Event.
    public event Action<ServerRequest>? ServerRequest;
    /// [questions] The authoritative open requests of one session, right after the ServerRequest re-deliveries of a
    /// session.resume / session.activate / session.events.since result and before its caller resumes.
    public event Action<OpenRequests>? OpenRequests;
    /// A listener of Event, StateChanged, Reconnected, ServerRequest, OpenRequests or RetryChanged threw (which event,
    /// and what). The listener's own problem: the socket, and every other listener, go on (Deliver). The app logs it.
    public event Action<string, Exception>? ListenerFailed;
    /// An open socket (gateway.ready had come) closed: why, in the log's words ("closed by the gateway", "no frame in
    /// 45 s", the exception's type). Never the frames' contents.
    public event Action<string>? Dropped;

    /// The kill switch (spec 1x §9 R1): HQNNoServerRequests in the environment skips client.capabilities (M1 behaviour).
    public static bool ServerRequestsEnabled { get; } = Environment.GetEnvironmentVariable("HQNNoServerRequests") == null;

    /// The current socket's client.capabilities answer said declines_not_shown (spec 1x §2.1).
    public bool DeclinesNotShown => _declinesNotShown;
    /// The current socket's generation (answers report the one they went out on).
    public int SocketEpoch => _socketEpoch;
    /// [authority] The current socket's gateway.ready said `session_authority: true` (GatewayConnection.swift
    /// `sessionAuthority`): every call goes out as AuthorityWire adapts it.
    public bool SessionAuthority => _sessionAuthority;

    /// [authority] The session's latest known turn (`execution_generation`), or null when none was seen.
    public long? GenerationOf(string session)
    {
        lock (_generations) return _generations.TryGetValue(session, out var g) ? g : null;
    }

    /// [authority] A snapshot states the session's turn as it is now (a restarted gateway counts afresh); a frame only
    /// moves it on (GatewayConnection.swift `noteGeneration`).
    private void NoteGeneration(long? generation, string session, bool snapshot = false)
    {
        if (generation is not { } g || session.Length == 0) return;
        lock (_generations)
        {
            if (!snapshot && _generations.TryGetValue(session, out var known) && g < known) return;
            if (_generations.Count > 256) _generations.Clear();
            _generations[session] = g;
        }
    }

    public RpcConnection(GatewaySession session) => _session = session;

    public void Start() => _loop ??= Task.Run(RunAsync);

    /// Waits for the socket to be open (gateway.ready received).
    public Task WhenReadyAsync(CancellationToken ct) => _ready.Task.WaitAsync(ct);

    // ------------------------------------------------------------------ requests

    /// The longest a call waits for a socket before it fails as not sent (GatewayConnection.Timing.maxReadyWait, 60 s;
    /// tests shorten it).
    public TimeSpan MaxReadyWait { get; set; } = TimeSpan.FromSeconds(60);

    public async Task<JsonNode> RequestAsync(string method, JsonObject parameters, TimeSpan timeout,
        CancellationToken ct = default)
    {
        if (State == ConnectionState.SignedOut)
            throw GatewayException.NotSent("signed-out");
        using var t = CancellationTokenSource.CreateLinkedTokenSource(ct, _life.Token);
        t.CancelAfter(timeout);
        // [WIN-RPC-DEAD-SOCKET-READY] waitPublished: until a socket is up and ready (`published, socket != nil`).
        // [WIN-SEND-NOTSENT-REFUSE] The wait is at most min(timeout, MaxReadyWait) (GatewayConnection.call:
        // `waitPublished(until: .now + min(timeout, timing.maxReadyWait))`).
        using (var readyWait = CancellationTokenSource.CreateLinkedTokenSource(t.Token))
        {
            readyWait.CancelAfter(timeout < MaxReadyWait ? timeout : MaxReadyWait);
            try { while (true) { await WhenReadyAsync(readyWait.Token); if (_socketReady && _ws != null) break; await Task.Yield(); } }
            // waitPublished's deadline: `throw out.failure.value ?? GatewayFailure.timeout` (a shut-down connection:
            // `.connectionChanged`), which LiveGatewayClient.call turns into RPCError.notSent(failure). Nothing went out:
            // a not-sent error (safe to send again), never "timeout" (sent, no answer: Delivery unconfirmed).
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            { throw GatewayException.NotSent(_life.IsCancellationRequested ? "connection-changed" : LastFailure ?? "timeout"); }
        }

        var id = Interlocked.Increment(ref _nextId);
        var tcs = new TaskCompletionSource<JsonNode>(TaskCreationOptions.RunContinuationsAsynchronously);
        var sessionParam = J.AsString(parameters.Get("session_id"));
        _pending[id] = new Pending(tcs, method, sessionParam);
        // [authority] The frame as this socket's server takes it; the caller (and `_pending`) keep the app's own verb.
        var wire = AuthorityWire.Adapt(method, parameters, _sessionAuthority,
            sessionParam is { Length: > 0 } sp ? GenerationOf(sp) : null);
        try
        {
            await SendFrameAsync(new JsonObject
            {
                ["jsonrpc"] = "2.0", ["id"] = id, ["method"] = wire.Method,
                ["params"] = wire.Params,
            }, t.Token, method);
            var result = await tcs.Task.WaitAsync(t.Token);
            // `session.resume` / `session.create` answer with the runtime id: a snapshot names its turn.
            if (result.Str("session_id") is { Length: > 0 } runtime)
                NoteGeneration(AuthorityWire.Generation(result), runtime, snapshot: true);
            return result;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new GatewayException("timeout", $"The gateway didn't answer {method} in time.");
        }
        finally { _pending.TryRemove(id, out _); }
    }

    /// No socket: NotConnected (nothing went out). The send itself failed: ConnectionLost (GatewayConnection.swift
    /// `sendFailed`; the frame may have gone out).
    private async Task SendFrameAsync(JsonNode frame, CancellationToken ct, string method = "frame")
    {
        var ws = _ws ?? throw GatewayException.NotConnected();
        var bytes = Encoding.UTF8.GetBytes(frame.ToJsonString());
        await _sendGate.WaitAsync(ct);
        try { await ws.SendAsync(bytes, WebSocketMessageType.Text, true, ct); }
        catch (Exception e) when (e is WebSocketException or ObjectDisposedException or InvalidOperationException)
        { throw GatewayException.ConnectionLost(method); }
        finally { _sendGate.Release(); }
    }

    /// [WIN-RPC-DROP-PENDING] GatewayConnection.swift `failAllPending`: every call still waiting on the socket that went
    /// fails now as ConnectionLost(method), not at its own timeout. Each entry is taken out before it fails, so a reply
    /// that already settled a call (it took its entry first) is never failed after it, and a sweep twice is harmless.
    private void FailAllPending()
    {
        foreach (var id in _pending.Keys)
            if (_pending.TryRemove(id, out var p)) p.Tcs.TrySetException(GatewayException.ConnectionLost(p.Method));
    }

    // ------------------------------------------------------------------ answers to server requests (spec 1x §2.3)

    /// `{"jsonrpc":"2.0","id":"srq-…","result":…}` on the current socket. Returns that socket's epoch. Throws
    /// GatewayException("offline") when no socket is up (nothing is queued) or the send failed.
    public Task<int> RespondAsync(string id, JsonNode result) =>
        SendAnswerAsync(ServerRequestFrames.Response(id, result));

    /// `{"jsonrpc":"2.0","id":"srq-…","error":{"code":…,"message":…}}`.
    public Task<int> FailAsync(string id, int code, string message) =>
        SendAnswerAsync(ServerRequestFrames.ErrorResponse(id, code, message));

    private async Task<int> SendAnswerAsync(JsonObject frame)
    {
        if (!_socketReady || _ws == null) throw GatewayException.NotConnected();
        var epoch = _socketEpoch;
        await SendFrameAsync(frame, _life.Token, "server request answer");
        return epoch;
    }

    // ------------------------------------------------------------------ the dial loop

    private async Task RunAsync()
    {
        var attempt = 0;
        var everReady = false;
        while (!_life.IsCancellationRequested)
        {
            SetState(ConnectionState.Connecting);
            var openedAt = DateTimeOffset.UtcNow;
            var gotReady = false;
            try
            {
                var ticket = await _session.MintTicketAsync(TimeSpan.FromSeconds(attempt switch { 0 => 8, 1 => 15, _ => 20 }), _life.Token);
                var url = _session.Address.SocketUrl(ticket);
                using var ws = new ClientWebSocket();
                // [WIN-HEARTBEAT-BACKSTOP] Protocol-level PING/PONG floor (matching ScreenSocket.cs) so idle
                // NAT/firewall/tunnel mappings stay warm even if app-level liveness degrades. Our own gateway.ping
                // heartbeat still runs above it.
                ws.Options.KeepAliveInterval = TimeSpan.FromSeconds(15);
                ws.Options.KeepAliveTimeout = TimeSpan.FromSeconds(45);
                if (_session.CookieHeader(url) is { } cookie) ws.Options.SetRequestHeader("Cookie", cookie);
                using (var t = CancellationTokenSource.CreateLinkedTokenSource(_life.Token))
                {
                    t.CancelAfter(TimeSpan.FromSeconds(15));
                    await ws.ConnectAsync(url, t.Token);
                }
                _ws = ws;
                _heartbeatLapsed = false;
                Interlocked.Increment(ref _socketEpoch);
                openedAt = DateTimeOffset.UtcNow;
                _lastInbound = openedAt;
                await ReadLoopAsync(ws, () =>
                {
                    gotReady = true;
                    everReady = true;
                }, _life.Token);
                if (gotReady && !_life.IsCancellationRequested)
                    Drop(_heartbeatLapsed ? "no frame in 45 s" : "closed by the gateway");
            }
            catch (GatewayException e) when (e.Code == "session-ended")
            {
                SetState(ConnectionState.SignedOut);
                return;
            }
            catch (Exception e) when (!_life.IsCancellationRequested)
            {
                if (!gotReady) NoteFailure(e);
                else Drop(_heartbeatLapsed ? "no frame in 45 s"
                    : e is GatewayException { Code: "offline" } g ? g.Message : e.GetType().Name);
            }
            catch (Exception) { return; }
            finally
            {
                _ws = null;
                MarkSocketGone();
                _declinesNotShown = false;
                _capabilitiesId = -1;
                FailAllPending();   // again: a call that registered while the read loop was ending
            }
            if (_life.IsCancellationRequested) return;
            SetState(ConnectionState.Offline);

            // The ladder resets only if the last socket stayed open at least 5 s.
            attempt = gotReady && DateTimeOffset.UtcNow - openedAt >= TimeSpan.FromSeconds(5) ? 0 : attempt + 1;
            var delay = everReady
                ? TimeSpan.FromSeconds(Random.Shared.NextDouble() * Math.Min(15, 0.3 * Math.Pow(2, attempt)))
                // RetryLadder: 3 s before the first retry after the first failure (HermesKit/Offline/RetryLadder.swift).
                : TimeSpan.FromSeconds(new[] { 3, 6, 12, 24, 30 }[Math.Clamp(attempt - 1, 0, 4)]);
            if (delay < TimeSpan.FromSeconds(1)) delay = TimeSpan.FromSeconds(1);
            _wake = CancellationTokenSource.CreateLinkedTokenSource(_life.Token);
            NextRetry = DateTimeOffset.UtcNow + delay;
            DeliverRetry();
            try { await Task.Delay(delay, _wake.Token); }
            catch (OperationCanceledException) when (!_life.IsCancellationRequested) { attempt = Math.Max(0, attempt - 1); }
            catch (OperationCanceledException) { return; }
            finally { NextRetry = null; _wake.Dispose(); _wake = null; }
            DeliverRetry();
        }
    }

    /// Try Again: the wait before the next dial ends now (one dial; the ladder keeps its place). A dial already
    /// running is left to finish.
    public void ReconnectNow()
    {
        try { _wake?.Cancel(); } catch (ObjectDisposedException) { }
    }

    /// [WIN-RPC-DEAD-SOCKET-READY] closeSocket: the socket is no longer ready and a new wait for the next one begins.
    private void MarkSocketGone()
    {
        _socketReady = false;
        lock (_readyGate)
            if (_ready.Task.IsCompleted) _ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private void Drop(string why)
    {
        try { Dropped?.Invoke(why); } catch (Exception) { /* never stops the dial loop */ }
    }

    private void NoteFailure(Exception e)
    {
        FailedDials++;
        LastFailure = e switch
        {
            GatewayException { Code: "timeout" } => "timeout",
            GatewayException { Code: "rate-limited" } => "rate-limited",
            GatewayException { Code: "gateway-outdated" } => "gateway-outdated",
            GatewayException { Code: "host-rejected" } => "host-rejected",
            GatewayException { Code: "not-hermes" } => "not-hermes",
            GatewayException { Code: "offline" } x when x.Message.Contains("SSL", StringComparison.OrdinalIgnoreCase) => "tls",
            GatewayException { Code: "http", Status: >= 500 } => "gateway-error",
            OperationCanceledException => "timeout",
            _ => "unreachable",
        };
        DeliverRetry();
    }

    private async Task ReadLoopAsync(ClientWebSocket ws, Action onReady, CancellationToken ct)
    {
        using var socketLife = CancellationTokenSource.CreateLinkedTokenSource(ct);
        Task? heartbeat = null;
        var buffer = new byte[64 * 1024];
        using var frame = new MemoryStream();
        try
        {
            while (ws.State == WebSocketState.Open)
            {
                frame.SetLength(0);
                WebSocketReceiveResult r;
                do
                {
                    r = await ws.ReceiveAsync(buffer, socketLife.Token);
                    if (r.MessageType == WebSocketMessageType.Close) return;
                    frame.Write(buffer, 0, r.Count);
                    if (frame.Length > 64L * 1024 * 1024) throw new GatewayException("offline", "Frame too large.");
                } while (!r.EndOfMessage);
                _lastInbound = DateTimeOffset.UtcNow;
                if (r.MessageType != WebSocketMessageType.Text) continue;
                var node = J.Parse(Encoding.UTF8.GetString(frame.GetBuffer(), 0, (int)frame.Length));
                if (node is not JsonObject obj) continue;

                if (obj.Str("method") == "event" && obj.Obj("params") is { } p)
                {
                    var ev = new RpcEvent(p.Str("type") ?? "", p.Str("session_id") ?? "", p.Get("payload"), p.Int("seq"))
                        { Generation = AuthorityWire.Generation(p) };
                    if (ev.Type == "gateway.ready")
                    {
                        ReadyPayload = ev.Payload;
                        _sessionAuthority = ev.Payload.Get("session_authority") is JsonValue sa
                            && sa.GetValueKind() == System.Text.Json.JsonValueKind.True;   // [authority]
                        var epoch = ev.Payload.Str("replay_epoch");
                        bool restarted;
                        List<string> toReplay;
                        lock (_deliverGate)
                        {
                            (restarted, toReplay) = _replayBook.Ready(epoch);
                            _epoch = epoch;
                        }
                        if (ev.Payload.Bool("heartbeat") == true) heartbeat ??= HeartbeatAsync(ws, socketLife);
                        // [questions] client.capabilities first, before the replay and before any caller may send.
                        if (ServerRequestsEnabled)
                        {
                            var capId = Interlocked.Increment(ref _nextId);
                            _capabilitiesId = capId;
                            try
                            {
                                await SendFrameAsync(new JsonObject
                                {
                                    ["jsonrpc"] = "2.0", ["id"] = capId, ["method"] = "client.capabilities",
                                    ["params"] = new JsonObject { ["server_requests"] = true },
                                }, socketLife.Token);
                            }
                            catch (GatewayException) { }
                        }
                        var currentEpoch = Volatile.Read(ref _socketEpoch);
                        _socketReady = true;
                        onReady();
                        EverOpen = true;
                        FailedDials = 0;
                        LastFailure = null;
                        SetState(ConnectionState.Open);
                        _ready.TrySetResult();
                        if (toReplay.Count > 0) _ = ReplayAsync(toReplay, currentEpoch);
                        Deliver(Reconnected, restarted, nameof(Reconnected));
                        continue;
                    }
                    var frameBytes = (int)frame.Length;
                    var socketEpoch = Volatile.Read(ref _socketEpoch);
                    bool overBudget;
                    lock (_deliverGate)
                    {
                        // H11 / H1: detect a per-session sequence gap, park only that session, and repair independently.
                        if (_socketReady && _replayBook.HasGap(ev) && _replayBook.Park(ev.SessionId))
                        {
                            var gapSession = ev.SessionId;
                            _ = Task.Run(() => ReplayOneAsync(gapSession, socketEpoch));
                        }
                        var (forward, exceeded) = _replayBook.Live(ev, frameBytes);
                        overBudget = exceeded;
                        if (!overBudget && forward != null)
                        {
                            NoteGeneration(forward.Generation, forward.SessionId);   // [authority]
                            Deliver(Event, forward, nameof(Event));
                        }
                    }
                    if (overBudget)
                    {
                        ws.Abort();
                        return;
                    }
                    continue;
                }
                // [questions] A server→client request: a string id and a method other than "event" (spec 1x §2.2).
                if (obj.Str("method") is { } srqMethod && srqMethod != "event" && obj.Get("id") is JsonValue sid
                    && sid.TryGetValue(out string? srqId) && srqId != null)
                {
                    if (!ServerRequestsEnabled) continue;
                    var srqParams = obj.Get("params") as JsonObject ?? new JsonObject();
                    Deliver(ServerRequest, new ServerRequest(srqId, srqMethod, srqParams,
                        srqParams.Str("session_id") ?? "", false, _socketEpoch), nameof(ServerRequest));
                    continue;
                }
                // A response to one of ours (numeric id). Other string ids are heartbeat answers.
                if (obj.Get("id") is JsonValue idv && idv.TryGetValue(out long id))
                {
                    if (id == _capabilitiesId)
                    {
                        _capabilitiesId = -1;
                        _declinesNotShown = obj.Obj("result").Bool("declines_not_shown") == true; // -32601: stays false
                        continue;
                    }
                    // Taken out first (GatewayConnection.swift `settle`): the close's sweep can't fail it after this.
                    if (!_pending.TryRemove(id, out var pending)) continue;
                    if (obj.Obj("error") is { } err)
                        pending.Tcs.TrySetException(new GatewayException("rpc",
                            J.AsString(err.Get("message")) ?? "Hermes RPC failed", rpcCode: err.Int("code") ?? 0,
                            body: err.Get("data")?.ToJsonString()));
                    else
                    {
                        var result = obj.Get("result") ?? new JsonObject();
                        // [questions] Still-open requests reach their listeners before the caller sees the result (§2.4).
                        if (ServerRequestsEnabled) Intercept(pending, result);
                        pending.Tcs.TrySetResult(result);
                    }
                }
                else if (obj.Get("id") is JsonValue hbId && hbId.TryGetValue(out string? hb) && hb?.StartsWith("heartbeat-") == true)
                {
                    NoteHeartbeatAnswer();
                }
            }
        }
        finally
        {
            // The socket is gone (aborted, closed, a read failed): the calls waiting on it fail before anything else
            // here can wait (closeSocket → failAllPending). It stops being ready first, as closeSocket clears
            // `socketReady` before failing them: a call made in a failed call's continuation waits for the next socket.
            MarkSocketGone();
            lock (_deliverGate) _replayBook.SocketClosed();
            FailAllPending();
            await socketLife.CancelAsync();
            if (ws.State == WebSocketState.Open)
            {
                try { await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None); }
                catch { }
            }
        }
    }

    /// gateway.ping every 15 s; fail the socket after 45 s with no inbound frame of any kind, or more than 8 unanswered
    /// pings (matching Swift `livenessTick` / `heartbeatsOutstanding`). A single transient send error must not terminate
    /// liveness — the 1 s loop and 45 s silence check stay active for the life of the socket.
    private async Task HeartbeatAsync(ClientWebSocket ws, CancellationTokenSource socketLife)
    {
        var n = 0;
        Interlocked.Exchange(ref _heartbeatsOutstanding, 0);
        var lastSent = DateTimeOffset.UtcNow;
        while (!socketLife.IsCancellationRequested)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(1), socketLife.Token); }
            catch (OperationCanceledException) { return; }
            catch (Exception) { continue; }
            try
            {
                if (DateTimeOffset.UtcNow - _lastInbound > TimeSpan.FromSeconds(45))
                {
                    _heartbeatLapsed = true;
                    ws.Abort();
                    await socketLife.CancelAsync();
                    return;
                }
                if (Volatile.Read(ref _heartbeatsOutstanding) > 8)
                {
                    _heartbeatLapsed = true;
                    ws.Abort();
                    await socketLife.CancelAsync();
                    return;
                }
                if (DateTimeOffset.UtcNow - lastSent >= TimeSpan.FromSeconds(15))
                {
                    lastSent = DateTimeOffset.UtcNow;
                    Interlocked.Increment(ref _heartbeatsOutstanding);
                    try
                    {
                        await SendFrameAsync(new JsonObject
                        {
                            ["jsonrpc"] = "2.0", ["id"] = $"heartbeat-{++n}", ["method"] = "gateway.ping", ["params"] = new JsonObject(),
                        }, socketLife.Token);
                    }
                    catch (Exception)
                    {
                        // One failed ping must not end liveness: the 45 s silence check and outstanding counter still guard.
                    }
                }
            }
            catch (Exception) { /* keep ticking */ }
        }
    }

    /// A heartbeat reply came in (ReadLoop calls this for string id "heartbeat-…"): one ping less outstanding, floored at 0.
    private void NoteHeartbeatAnswer()
    {
        while (true)
        {
            var current = Volatile.Read(ref _heartbeatsOutstanding);
            if (current <= 0) return;
            if (Interlocked.CompareExchange(ref _heartbeatsOutstanding, current - 1, current) == current) return;
        }
    }

    /// After a reconnect with the same epoch: fetch what each followed session missed, two at a time, while live events
    /// for parked sessions wait in `_replayBook`. Releases only sessions from this reconnect batch that never started so
    /// concurrent per-session gap repairs stay isolated (H11).
    private async Task ReplayAsync(IReadOnlyList<string> sessions, int socketEpoch)
    {
        var deadline = DateTimeOffset.UtcNow + ReplayDeadline;
        var started = new bool[sessions.Count];
        using var gate = new SemaphoreSlim(2);
        var tasks = new List<Task>(sessions.Count);
        try
        {
            for (var i = 0; i < sessions.Count; i++)
            {
                var remaining = deadline - DateTimeOffset.UtcNow;
                if (remaining <= TimeSpan.Zero || Volatile.Read(ref _socketEpoch) != socketEpoch) break;
                try { await gate.WaitAsync(remaining, _life.Token); }
                catch (OperationCanceledException) { break; }
                if (Volatile.Read(ref _socketEpoch) != socketEpoch || DateTimeOffset.UtcNow >= deadline)
                {
                    gate.Release();
                    break;
                }
                started[i] = true;
                var sessionId = sessions[i];
                tasks.Add(Task.Run(async () =>
                {
                    try { await ReplayOneAsync(sessionId, socketEpoch); }
                    finally { gate.Release(); }
                }));
            }
            if (tasks.Count > 0) await Task.WhenAll(tasks);
        }
        finally
        {
            for (var i = 0; i < sessions.Count; i++)
            {
                if (!started[i]) ReleaseParked(sessions[i], socketEpoch);
            }
        }
    }

    /// Replays one parked session (either from a reconnect batch or from live per-session gap repair), delivering
    /// replayed frames before draining any live frames that arrived while the replay was in flight (H11).
    private async Task ReplayOneAsync(string sessionId, int socketEpoch)
    {
        var epochRestarted = false;
        try
        {
            var lastSeen = _replayBook.CursorFor(sessionId);
            if (lastSeen is not { } cursor || Volatile.Read(ref _socketEpoch) != socketEpoch) return;
            var res = await RequestAsync("session.events.since",
                new JsonObject { ["session_id"] = sessionId, ["last_seen"] = cursor }, ReplayRequestTimeout);
            lock (_deliverGate)
            {
                if (Volatile.Read(ref _socketEpoch) != socketEpoch) return;
                if (res.Str("epoch") is { } e && e != _epoch)
                {
                    _epoch = e;
                    _replayBook.EpochRestarted(e);
                    epochRestarted = true;
                    return;
                }
                foreach (var p in res.Arr("events") ?? [])
                {
                    var ev = new RpcEvent(p.Str("type") ?? "", p.Str("session_id") ?? sessionId, p.Get("payload"), p.Int("seq"))
                        { Generation = AuthorityWire.Generation(p) };
                    if (_replayBook.Replayed(ev) is not { } accepted) continue;
                    NoteGeneration(accepted.Generation, accepted.SessionId);   // [authority]
                    Deliver(Event, accepted, nameof(Event));
                }
                if (res.Bool("truncated") == true)
                    Deliver(Event, new RpcEvent("hq.replay_truncated", sessionId, null, null), nameof(Event));
                DrainParkedLocked(sessionId);
            }
        }
        catch (GatewayException) { }
        finally
        {
            if (epochRestarted) Deliver(Reconnected, true, nameof(Reconnected));
            else ReleaseParked(sessionId, socketEpoch);
        }
    }

    private void ReleaseParked(string sessionId, int socketEpoch)
    {
        lock (_deliverGate)
        {
            if (Volatile.Read(ref _socketEpoch) != socketEpoch) return;
            DrainParkedLocked(sessionId);
        }
    }

    private void DrainParkedLocked(string sessionId)
    {
        foreach (var ev in _replayBook.Release(sessionId))
        {
            NoteGeneration(ev.Generation, ev.SessionId);   // [authority]
            Deliver(Event, ev, nameof(Event));
        }
    }

    private void Intercept(Pending pending, JsonNode result)
    {
        var parameters = new JsonObject();
        if (pending.SessionParam != null) parameters["session_id"] = pending.SessionParam;
        var items = OpenRequestsIntercept.Events(pending.Method, parameters, result, _socketEpoch);
        foreach (var item in items)
        {
            switch (item)
            {
                case ServerRequest r: Deliver(ServerRequest, r, nameof(ServerRequest)); break;
                case OpenRequests o: Deliver(OpenRequests, o, nameof(OpenRequests)); break;
                case RpcEvent e: Deliver(Event, e, nameof(Event)); break;
            }
        }
    }

    /// Hands `value` to each listener in turn, each on its own: one that throws is reported (ListenerFailed) and the
    /// rest still hear it. Listeners run on the read loop's thread, and before this an exception from any of them (a
    /// WinUI page touched off its thread, a chat's listener after its page went) ended the account's one socket: the
    /// link redialled while a chat opened or closed (WIN-23). The Mac's listeners read an AsyncStream
    /// (GatewayConnection.swift `out.events.yield`), so none of them can end its socket.
    private void Deliver<T>(Action<T>? listeners, T value, string name)
    {
        if (listeners == null) return;
        foreach (var listener in listeners.GetInvocationList())
        {
            try { ((Action<T>)listener)(value); }
            catch (Exception e) { Failed(name, e); }
        }
    }

    private void DeliverRetry()
    {
        if (RetryChanged is not { } listeners) return;
        foreach (var listener in listeners.GetInvocationList())
        {
            try { ((Action)listener)(); }
            catch (Exception e) { Failed(nameof(RetryChanged), e); }
        }
    }

    private void Failed(string name, Exception e)
    {
        try { ListenerFailed?.Invoke(name, e); } catch (Exception) { /* the report's own listener never stops the socket */ }
    }

    private void SetState(ConnectionState s)
    {
        if (State == s) return;
        State = s;
        Deliver(StateChanged, s, nameof(StateChanged));
    }

    public async ValueTask DisposeAsync()
    {
        await _life.CancelAsync();
        _ws?.Abort();
        if (_loop != null) { try { await _loop; } catch { } }
    }
}

/// Per-session sequence cursor book, live-event parking during replay / gap repair, and overflow-safe gap detection
/// (port of HermesKit/Net/ConnectionSupport.swift `ReplayBook`, H11 + H1).
internal sealed class ReplayBook
{
    public const int CursorBudget = 8;
    public const int ParkedFrameCap = 2048;
    public const int ParkedByteCap = 4 * 1024 * 1024;

    private readonly object _gate = new();
    private readonly Dictionary<string, (long Seq, long Tick)> _cursors = new(StringComparer.Ordinal);
    private readonly Dictionary<string, List<(RpcEvent Event, int Bytes)>> _parked = new(StringComparer.Ordinal);
    private long _tick;
    private string? _epoch;
    private int _parkedFrames;
    private int _parkedBytes;

    public (bool Restarted, List<string> SessionsToReplay) Ready(string? epoch)
    {
        lock (_gate)
        {
            var hadEpoch = _epoch != null;
            var restarted = hadEpoch && epoch != _epoch;
            _epoch = epoch;
            ClearParkedLocked();
            if (restarted)
            {
                _cursors.Clear();
                return (true, []);
            }
            if (!hadEpoch) return (false, []);
            var sessions = _cursors
                .OrderByDescending(kv => kv.Value.Tick)
                .Take(CursorBudget)
                .Select(kv => kv.Key)
                .ToList();
            foreach (var session in sessions) _parked[session] = [];
            return (false, sessions);
        }
    }

    public long? CursorFor(string session)
    {
        lock (_gate) return _cursors.TryGetValue(session, out var cur) ? cur.Seq : null;
    }

    public bool IsParked(string session)
    {
        lock (_gate) return _parked.ContainsKey(session);
    }

    /// True when `ev` jumps past the last delivered sequence number for its session (H1: guards `long.MaxValue`
    /// against arithmetic overflow).
    public bool HasGap(RpcEvent ev)
    {
        if (ev.Seq is not { } seq || ev.SessionId.Length == 0) return false;
        lock (_gate)
        {
            if (_parked.ContainsKey(ev.SessionId)) return false;
            if (!_cursors.TryGetValue(ev.SessionId, out var cur)) return false;
            return cur.Seq < long.MaxValue && seq > cur.Seq + 1;
        }
    }

    /// Parks a single session for per-session gap repair. Returns false if it is already parked.
    public bool Park(string session)
    {
        if (session.Length == 0) return false;
        lock (_gate)
        {
            if (_parked.ContainsKey(session)) return false;
            _parked[session] = [];
            return true;
        }
    }

    /// Processes an incoming live event: parks it if its session is parked, drops duplicates, or advances the cursor.
    public (RpcEvent? Forward, bool OverBudget) Live(RpcEvent ev, int bytes)
    {
        lock (_gate)
        {
            if (ev.SessionId.Length > 0 && _parked.TryGetValue(ev.SessionId, out var queue))
            {
                var size = Math.Max(1, bytes);
                if (_parkedFrames + 1 > ParkedFrameCap || _parkedBytes + size > ParkedByteCap)
                    return (null, true);
                queue.Add((ev, size));
                _parkedFrames++;
                _parkedBytes += size;
                return (null, false);
            }
            if (ev.Seq is { } seq && ev.SessionId.Length > 0)
            {
                if (_cursors.TryGetValue(ev.SessionId, out var cur) && seq <= cur.Seq) return (null, false);
                SetCursorLocked(ev.SessionId, seq);
            }
            return (ev, false);
        }
    }

    /// Accepts one replayed event from `session.events.since`, advancing the cursor and skipping duplicates.
    public RpcEvent? Replayed(RpcEvent ev)
    {
        lock (_gate)
        {
            if (ev.Seq is { } seq && ev.SessionId.Length > 0)
            {
                if (_cursors.TryGetValue(ev.SessionId, out var cur) && seq <= cur.Seq) return null;
                SetCursorLocked(ev.SessionId, seq);
            }
            return ev;
        }
    }

    /// Unparks one session and returns its queued live events in arrival order, deduplicated against the updated cursor.
    public List<RpcEvent> Release(string session)
    {
        lock (_gate)
        {
            if (!_parked.Remove(session, out var queue)) return [];
            _parkedFrames = Math.Max(0, _parkedFrames - queue.Count);
            foreach (var (_, size) in queue) _parkedBytes = Math.Max(0, _parkedBytes - size);
            var out_ = new List<RpcEvent>(queue.Count);
            foreach (var (ev, _) in queue)
            {
                if (ev.Seq is { } seq && ev.SessionId.Length > 0)
                {
                    if (_cursors.TryGetValue(ev.SessionId, out var cur) && seq <= cur.Seq) continue;
                    SetCursorLocked(ev.SessionId, seq);
                }
                out_.Add(ev);
            }
            return out_;
        }
    }

    public void EpochRestarted(string newEpoch)
    {
        lock (_gate)
        {
            _epoch = newEpoch;
            _cursors.Clear();
            ClearParkedLocked();
        }
    }

    public void SocketClosed()
    {
        lock (_gate) ClearParkedLocked();
    }

    private void ClearParkedLocked()
    {
        _parked.Clear();
        _parkedFrames = 0;
        _parkedBytes = 0;
    }

    private void SetCursorLocked(string session, long seq)
    {
        _cursors[session] = (seq, ++_tick);
        while (_cursors.Count > CursorBudget)
        {
            string? oldest = null;
            var oldestTick = long.MaxValue;
            foreach (var (key, val) in _cursors)
            {
                if (key == session || _parked.ContainsKey(key)) continue;
                if (val.Tick < oldestTick)
                {
                    oldestTick = val.Tick;
                    oldest = key;
                }
            }
            if (oldest is null) break;
            _cursors.Remove(oldest);
        }
    }
}
