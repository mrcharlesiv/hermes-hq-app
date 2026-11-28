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
    private readonly ConcurrentDictionary<string, long> _lastSeq = new();
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
                // [WIN-HEARTBEAT-BACKSTOP] Protocol-level PING/PONG as a floor (ScreenSocket.cs's proven pattern):
                // the mapping between this app and the gateway stays warm even when app-level liveness ever
                // degrades (BUG-2: an idle leg is dropped by the network path in the 600–900 s band, which read
                // as a reconnect every ~13 min). Our own gateway.ping heartbeat still runs above it.
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
                        var restarted = _epoch != null && epoch != _epoch;
                        if (restarted) _lastSeq.Clear();
                        var replay = _epoch != null && !restarted;
                        _epoch = epoch;
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
                        _socketReady = true;
                        onReady();
                        EverOpen = true;
                        FailedDials = 0;
                        LastFailure = null;
                        SetState(ConnectionState.Open);
                        _ready.TrySetResult();
                        if (replay) _ = ReplayAsync();
                        Deliver(Reconnected, restarted, nameof(Reconnected));
                        continue;
                    }
                    NoteGeneration(ev.Generation, ev.SessionId);   // [authority]
                    if (ev.Seq is { } seq && ev.SessionId.Length > 0)
                        _lastSeq.AddOrUpdate(ev.SessionId, seq, (_, old) => Math.Max(old, seq));
                    Deliver(Event, ev, nameof(Event));
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
                    NoteHeartbeatAnswer();   // [WIN-HEARTBEAT-RESILIENT] one ping less outstanding
            }
        }
        finally
        {
            // The socket is gone (aborted, closed, a read failed): the calls waiting on it fail before anything else
            // here can wait (closeSocket → failAllPending). It stops being ready first, as closeSocket clears
            // `socketReady` before failing them: a call made in a failed call's continuation waits for the next socket.
            MarkSocketGone();
            FailAllPending();
            await socketLife.CancelAsync();
            if (ws.State == WebSocketState.Open)
            {
                try { await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None); }
                catch { }
            }
        }
    }

    /// gateway.ping every 15 s; fail the socket after 45 s with no inbound frame of any kind.
    /// [WIN-HEARTBEAT-RESILIENT] The Mac's livenessTick (GatewayConnection.swift:994) is a 1 s loop that never dies:
    /// one lost ping leaves liveness intact and the silence check running. The previous single-Task form ended
    /// itself on the first transient send error (its one `catch { }`), leaving the socket with no app traffic and
    /// no lapse detection until the path's idle timeout dropped it — BUG-2's reconnect every ~13 min. Also counts
    /// unanswered pings (Swift `heartbeatsOutstanding`, capped at 8): a server that answers traffic but never pings
    /// is dead all the same.
    private async Task HeartbeatAsync(ClientWebSocket ws, CancellationTokenSource socketLife)
    {
        var n = 0;
        var unanswered = 0;
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
                if (unanswered > 8)
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
                    unanswered++;
                    try
                    {
                        await SendFrameAsync(new JsonObject
                        {
                            ["jsonrpc"] = "2.0", ["id"] = $"heartbeat-{++n}", ["method"] = "gateway.ping", ["params"] = new JsonObject(),
                        }, socketLife.Token);
                    }
                    catch (Exception)
                    {
                        // One failed ping must not end liveness: the 45 s silence check still guards, and the next
                        // tick sends again (the failed frame may or may not have gone out).
                    }
                }
            }
            catch (Exception) { /* keep ticking */ }
        }
    }

    /// A heartbeat reply came in (ReadLoop calls this for the string id "heartbeat-…"): one ping less outstanding.
    private void NoteHeartbeatAnswer() => Interlocked.Decrement(ref _heartbeatsOutstanding);

    /// After a reconnect with the same epoch: fetch what each followed session missed, two at a time.
    private async Task ReplayAsync()
    {
        var cursors = _lastSeq.ToArray().OrderByDescending(kv => kv.Value).Take(8).ToArray();
        using var gate = new SemaphoreSlim(2);
        await Task.WhenAll(cursors.Select(async kv =>
        {
            await gate.WaitAsync();
            try
            {
                var res = await RequestAsync("session.events.since",
                    new JsonObject { ["session_id"] = kv.Key, ["last_seen"] = kv.Value }, TimeSpan.FromSeconds(10));
                if (res.Str("epoch") is { } e && e != _epoch) { _lastSeq.Clear(); Deliver(Reconnected, true, nameof(Reconnected)); return; }
                foreach (var p in res.Arr("events") ?? [])
                {
                    var ev = new RpcEvent(p.Str("type") ?? "", p.Str("session_id") ?? kv.Key, p.Get("payload"), p.Int("seq"))
                        { Generation = AuthorityWire.Generation(p) };
                    NoteGeneration(ev.Generation, ev.SessionId);   // [authority]
                    if (ev.Seq is { } s && s <= kv.Value) continue;
                    if (ev.Seq is { } s2) _lastSeq.AddOrUpdate(ev.SessionId, s2, (_, old) => Math.Max(old, s2));
                    Deliver(Event, ev, nameof(Event));
                }
                if (res.Bool("truncated") == true) Deliver(Event, new RpcEvent("hq.replay_truncated", kv.Key, null, null), nameof(Event));
            }
            catch (GatewayException) { }
            finally { gate.Release(); }
        }));
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
