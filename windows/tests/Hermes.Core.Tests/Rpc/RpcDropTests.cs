// [WIN-RPC-DROP-PENDING] HermesKit/Net/GatewayConnection.swift at 93f984bb1: closeSocket → failAllPending. Every call
// still waiting when the socket goes (the gateway aborts it, closes it cleanly, or a read fails) fails at once with
// RPCError.connectionLost(method) (code -33002, "connection closed before the gateway answered: <method>"), never at
// its own timeout; a reply that raced the close settles its call once (`settle` removes the entry first). On Windows
// that error is GatewayException("offline") with RpcCode -33002 (IsConnectionLost). A loopback stand-in gateway on
// 127.0.0.1 with synthetic data only.
//
// Ported: VerificationRoundOneTests.lostAckIsUnconfirmedNotRefused (its connectionLost half, here through the real
// socket rather than a thrown error), NetBoundaryTests.notSentErrorsCarryTheirReason (the isNotConnected /
// isConnectionLost half). Added: abort, clean close and a read failing mid-frame under pending calls, every pending call
// failing at once, a reply racing the close, and the reconnect that follows each drop.
//
// The stand-in cuts the TCP link itself (Cut): on macOS and Linux the managed HttpListener's WebSocket.Abort() alone
// leaves the connection open, so the client saw nothing until its own timeout (the 30 s / 1800 s hang the memo lane hit).

using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Tests.RpcDrop;

public sealed class RpcDropTests
{
    /// What the stand-in does with one request.
    internal enum Act { Reply, Hold, Abort, Close, ReplyThenAbort, HalfFrameThenAbort }

    /// A loopback stand-in gateway: the ws-ticket mint and /api/ws sockets that say gateway.ready, then do `Plan`'s act
    /// for each request (by method and per-method attempt) and record it.
    internal sealed class Standin : IAsyncDisposable
    {
        private readonly HttpListener _http = new();
        private readonly CancellationTokenSource _life = new();
        private readonly object _gate = new();
        private readonly Dictionary<string, int> _attempts = [];
        private readonly List<string> _log = [];
        public Func<string, int, Act> Plan { get; set; } = (_, _) => Act.Reply;
        public Func<string, JsonObject, JsonNode> Answer { get; set; } = (_, _) => new JsonObject { ["ok"] = true };
        public string Url { get; }
        public int Sockets;

        public Standin()
        {
            var probe = new TcpListener(IPAddress.Loopback, 0);
            probe.Start();
            var port = ((IPEndPoint)probe.LocalEndpoint).Port;
            probe.Stop();
            Url = $"http://127.0.0.1:{port}";
            _http.Prefixes.Add(Url + "/");
            _http.Start();
            _ = Task.Run(Serve);
        }

        public int Calls(string method) { lock (_gate) return _log.Count(m => m == method); }

        private async Task Serve()
        {
            while (!_life.IsCancellationRequested)
            {
                HttpListenerContext ctx;
                try { ctx = await _http.GetContextAsync(); } catch { return; }
                _ = Task.Run(() => Handle(ctx));
            }
        }

        private async Task Handle(HttpListenerContext ctx)
        {
            var path = ctx.Request.Url!.AbsolutePath;
            if (path == "/api/auth/ws-ticket")
            {
                var bytes = Encoding.UTF8.GetBytes("""{"ticket":"synthetic-ticket"}""");
                ctx.Response.ContentType = "application/json";
                ctx.Response.ContentLength64 = bytes.Length;
                await ctx.Response.OutputStream.WriteAsync(bytes);
                ctx.Response.Close();
                return;
            }
            if (path != "/api/ws" || !ctx.Request.IsWebSocketRequest)
            {
                ctx.Response.StatusCode = 404;
                ctx.Response.Close();
                return;
            }
            var ws = (await ctx.AcceptWebSocketAsync(null)).WebSocket;
            Interlocked.Increment(ref Sockets);
            var sendGate = new SemaphoreSlim(1, 1);
            async Task Send(JsonNode n)
            {
                await sendGate.WaitAsync();
                try { await ws.SendAsync(Encoding.UTF8.GetBytes(n.ToJsonString()), WebSocketMessageType.Text, true, CancellationToken.None); }
                catch (Exception e) when (e is WebSocketException or ObjectDisposedException or InvalidOperationException) { }
                finally { sendGate.Release(); }
            }
            // The connection's own stream: closing it is what a gateway process dying does to the TCP link.
            void Cut()
            {
                ws.Abort();
                try { ctx.Response.Abort(); } catch (Exception) { }
            }
            await Send(new JsonObject
            {
                ["jsonrpc"] = "2.0", ["method"] = "event",
                ["params"] = new JsonObject { ["type"] = "gateway.ready", ["payload"] = new JsonObject { ["replay_epoch"] = "e1" } },
            });
            var buffer = new byte[64 * 1024];
            while (ws.State == WebSocketState.Open && !_life.IsCancellationRequested)
            {
                using var frame = new MemoryStream();
                try
                {
                    WebSocketReceiveResult r;
                    do
                    {
                        r = await ws.ReceiveAsync(buffer, _life.Token);
                        if (r.MessageType == WebSocketMessageType.Close) return;
                        frame.Write(buffer, 0, r.Count);
                    } while (!r.EndOfMessage);
                }
                catch { return; }
                if (JsonNode.Parse(Encoding.UTF8.GetString(frame.ToArray())) is not JsonObject req) continue;
                var method = req["method"]?.GetValue<string>() ?? "";
                if (method == "client.capabilities") continue;
                int attempt;
                lock (_gate)
                {
                    _log.Add(method);
                    _attempts[method] = _attempts.GetValueOrDefault(method) + 1;
                    attempt = _attempts[method];
                }
                if (req["id"] is not { } id) continue;
                var answer = new JsonObject
                {
                    ["jsonrpc"] = "2.0", ["id"] = id.DeepClone(),
                    ["result"] = Answer(method, req["params"] as JsonObject ?? []),
                };
                switch (Plan(method, attempt))
                {
                    case Act.Reply: await Send(answer); break;
                    case Act.Hold: break;
                    case Act.Abort: Cut(); return;
                    case Act.Close:
                        try { await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None); }
                        catch (Exception) { }
                        return;
                    case Act.ReplyThenAbort: await Send(answer); Cut(); return;
                    case Act.HalfFrameThenAbort:
                        // A frame begun and never finished: the client's read fails mid-message.
                        await sendGate.WaitAsync();
                        try { await ws.SendAsync(Encoding.UTF8.GetBytes("{\"jsonrpc\":\"2.0\",\"id\":"), WebSocketMessageType.Text, false, CancellationToken.None); }
                        catch (Exception) { }
                        finally { sendGate.Release(); }
                        await Task.Delay(50);
                        Cut();
                        return;
                }
            }
        }

        public ValueTask DisposeAsync()
        {
            _life.Cancel();
            try { _http.Close(); } catch (ObjectDisposedException) { }
            return ValueTask.CompletedTask;
        }
    }

    internal static async Task<(Standin Gateway, HermesClient Client)> Open()
    {
        var gateway = new Standin();
        var client = new HermesClient(new GatewaySession(GatewayAddress.Validated(gateway.Url),
            new StoredAccount(gateway.Url, "synthetic"), new MemoryTokenStore()));
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        return (gateway, client);
    }

    private static async Task<(Exception Error, TimeSpan After)> Fails(Task call)
    {
        var clock = Stopwatch.StartNew();
        var finished = await Task.WhenAny(call, Task.Delay(TimeSpan.FromSeconds(10)));
        Assert.Same(call, finished);   // never waits out its own timeout
        var error = await Assert.ThrowsAnyAsync<Exception>(() => call);
        return (error, clock.Elapsed);
    }

    [Fact]
    public async Task AnAbortUnderAPlainRequestFailsItAtOnceAsConnectionLost()
    {
        var (gateway, client) = await Open();
        await using var _ = gateway;
        await using var __ = client;
        gateway.Plan = (method, _) => method == "file.attach" ? Act.Abort : Act.Reply;
        var (error, after) = await Fails(client.Rpc.RequestAsync("file.attach", new JsonObject { ["session_id"] = "rt-1" },
            TimeSpan.FromSeconds(30)));
        var lost = Assert.IsType<GatewayException>(error);
        Assert.Equal("offline", lost.Code);
        Assert.True(lost.IsConnectionLost);
        Assert.Equal(GatewayException.ConnectionLostCode, lost.RpcCode);
        Assert.Equal("file.attach", lost.Method);
        Assert.True(after < TimeSpan.FromSeconds(2), $"failed after {after}");
    }

    [Fact]
    public void ConnectionLostAndNotConnectedAreToldApart()
    {
        var lost = GatewayException.ConnectionLost("prompt.submit");
        Assert.True(lost.IsConnectionLost && !lost.IsNotConnected);
        Assert.Equal("offline", lost.Code);   // every "can't reach" check still sees it
        Assert.Equal(-33002, lost.RpcCode);
        Assert.Equal("prompt.submit", lost.Method);
        var notSent = GatewayException.NotConnected();
        Assert.True(notSent.IsNotConnected && !notSent.IsConnectionLost);
        Assert.Equal("offline", notSent.Code);
        Assert.Equal(-33003, notSent.RpcCode);
        // A gateway's own error (and a plain transport one) is neither.
        var answer = new GatewayException("rpc", "busy", rpcCode: 4001);
        Assert.False(answer.IsConnectionLost || answer.IsNotConnected);
        Assert.False(new GatewayException("offline", "Can't reach the gateway.").IsConnectionLost);
    }

    [Fact]
    public async Task EveryPendingCallFailsAtOnceWhenTheSocketGoes()
    {
        var (gateway, client) = await Open();
        await using var _ = gateway;
        await using var __ = client;
        gateway.Plan = (method, _) => method == "cut" ? Act.Abort : Act.Hold;
        var held = new[] { "session.resume", "file.attach" }
            .Select(m => client.Rpc.RequestAsync(m, new JsonObject(), TimeSpan.FromSeconds(30))).ToArray();
        Assert.True(await VoiceFixturesWait(() => gateway.Calls("file.attach") == 1 && gateway.Calls("session.resume") == 1));
        var cut = client.Rpc.RequestAsync("cut", new JsonObject(), TimeSpan.FromSeconds(30));
        foreach (var (call, method) in held.Append(cut).Zip(new[] { "session.resume", "file.attach", "cut" }))
        {
            var (error, after) = await Fails(call);
            var lost = Assert.IsType<GatewayException>(error);
            Assert.True(lost.IsConnectionLost);
            Assert.Equal(method, lost.Method);
            Assert.True(after < TimeSpan.FromSeconds(2), $"{method} failed after {after}");
        }
    }

    [Fact]
    public async Task ACleanCloseFailsThePendingCallAndTheSocketComesBack()
    {
        var (gateway, client) = await Open();
        await using var _ = gateway;
        await using var __ = client;
        var dropped = new List<string>();
        client.Rpc.Dropped += why => { lock (dropped) dropped.Add(why); };
        gateway.Plan = (method, attempt) => method == "profiles.list" && attempt == 1 ? Act.Close : Act.Reply;
        var (error, after) = await Fails(client.Rpc.RequestAsync("profiles.list", new JsonObject(), TimeSpan.FromSeconds(120)));
        Assert.True(Assert.IsType<GatewayException>(error).IsConnectionLost);
        Assert.True(after < TimeSpan.FromSeconds(2), $"failed after {after}");
        // The reconnect is as before: the dial loop opens a new socket and the next call goes through on it.
        Assert.True(await VoiceFixturesWait(() => gateway.Sockets == 2 && client.Rpc.State == ConnectionState.Open));
        lock (dropped) Assert.Equal(["closed by the gateway"], dropped);
        var again = await client.Rpc.RequestAsync("profiles.list", new JsonObject(), TimeSpan.FromSeconds(10));
        Assert.True(again["ok"]!.GetValue<bool>());
        Assert.Equal(2, gateway.Calls("profiles.list"));
    }

    [Fact]
    public async Task AReadFailingMidFrameFailsThePendingCall()
    {
        var (gateway, client) = await Open();
        await using var _ = gateway;
        await using var __ = client;
        gateway.Plan = (method, attempt) => method == "file.attach" && attempt == 1 ? Act.HalfFrameThenAbort : Act.Reply;
        var (error, after) = await Fails(client.Rpc.RequestAsync("file.attach", new JsonObject(), TimeSpan.FromSeconds(30)));
        Assert.True(Assert.IsType<GatewayException>(error).IsConnectionLost);
        Assert.True(after < TimeSpan.FromSeconds(2), $"failed after {after}");
        Assert.True(await VoiceFixturesWait(() => gateway.Sockets == 2 && client.Rpc.State == ConnectionState.Open));
    }

    /// The reply and the close race: the reply settles the call (it took its entry first) and the close's sweep never
    /// fails it after; a call still waiting fails as connection lost.
    [Fact]
    public async Task AReplyThatRacesTheCloseSettlesItsCallOnce()
    {
        for (var round = 0; round < 20; round++)
        {
            var (gateway, client) = await Open();
            await using var _ = gateway;
            await using var __ = client;
            gateway.Plan = (method, _) => method == "prompt.submit" ? Act.ReplyThenAbort : Act.Hold;
            gateway.Answer = (method, _) => new JsonObject { ["user_row_id"] = 42 };
            var waiting = client.Rpc.RequestAsync("session.title", new JsonObject(), TimeSpan.FromSeconds(30));
            Assert.True(await VoiceFixturesWait(() => gateway.Calls("session.title") == 1));
            var answered = await client.Rpc.RequestAsync("prompt.submit", new JsonObject(), TimeSpan.FromSeconds(30));
            Assert.Equal(42, answered["user_row_id"]!.GetValue<int>());
            var (error, _) = await Fails(waiting);
            Assert.True(Assert.IsType<GatewayException>(error).IsConnectionLost);
        }
    }

    /// VerificationRoundOneTests.lostAckIsUnconfirmedNotRefused (connectionLost): the gateway took the prompt, then
    /// the socket went before the ack. "Delivery unconfirmed" at once, not pending, never resent, not after the
    /// reconnect either.
    [Fact]
    public async Task AnAbortUnderPromptSubmitIsDeliveryUnconfirmedAtOnce()
    {
        var (gateway, client) = await Open();
        await using var _ = gateway;
        await using var __ = client;
        gateway.Answer = (method, _) => method == "session.resume" ? new JsonObject { ["session_id"] = "rt-synthetic" } : new JsonObject();
        gateway.Plan = (method, _) => method == "prompt.submit" ? Act.Abort : Act.Reply;
        await using var chat = client.OpenChat("ivy", "20260929_120000_aabbcc03", "Ivy");
        await chat.EnsureRuntimeAsync();
        var clock = Stopwatch.StartNew();
        var outcome = await chat.SendAsync("lost ack message").WaitAsync(TimeSpan.FromSeconds(10));
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(2), $"settled after {clock.Elapsed}");
        Assert.Equal(SendOutcome.Unconfirmed, outcome);
        var user = chat.Messages.Last(m => m.Role == Role.User);
        Assert.Equal("lost ack message", user.Text);
        Assert.Equal("Delivery unconfirmed", user.Error);
        Assert.False(user.IsPending);
        Assert.False(chat.Busy);
        Assert.Equal(1, gateway.Calls("prompt.submit"));
        Assert.True(await VoiceFixturesWait(() => gateway.Sockets == 2 && client.Rpc.State == ConnectionState.Open));
        await Task.Delay(200);
        Assert.Equal(1, gateway.Calls("prompt.submit"));   // never resent
    }

    /// [WIN-RPC-DEAD-SOCKET-READY] GatewayConnection.swift closeSocket marks the socket gone (`socketReady = false`,
    /// `published = false`) before failAllPending, and a call waits in `waitPublished` until `published, socket != nil`.
    /// A call made the moment a dropped call fails (Send Again on its "Delivery unconfirmed" bubble) waits for the next
    /// socket and goes out on it; it never meets the dead socket and fails as connection lost (run 45165939924:
    /// MemoSendTests.DeleteAndSendAgain came back Unconfirmed on the Windows runner).
    [Fact]
    public async Task ACallMadeAsADroppedCallFailsWaitsForTheNextSocket()
    {
        for (var round = 0; round < 10; round++)
        {
            var (gateway, client) = await Open();
            await using var _ = gateway;
            await using var __ = client;
            gateway.Plan = (method, attempt) => method == "prompt.submit" && attempt == 1 ? Act.Abort : Act.Reply;
            gateway.Answer = (method, _) => new JsonObject { ["user_row_id"] = 40 };
            var first = client.Rpc.RequestAsync("prompt.submit", new JsonObject(), TimeSpan.FromSeconds(30));
            Task<JsonNode>? next = null;
            // The very continuation the drop's failure runs: no yield between the failure and the next call.
            var chained = first.ContinueWith(_ => next = client.Rpc.RequestAsync("prompt.submit", new JsonObject(),
                TimeSpan.FromSeconds(10)), TaskContinuationOptions.ExecuteSynchronously);
            var (error, _) = await Fails(first);
            Assert.True(Assert.IsType<GatewayException>(error).IsConnectionLost);
            await chained;
            var answered = await next!.WaitAsync(TimeSpan.FromSeconds(15));
            Assert.Equal(40, answered["user_row_id"]!.GetValue<int>());
            Assert.Equal(2, gateway.Sockets);
            Assert.Equal(2, gateway.Calls("prompt.submit"));
        }
    }

    private static Task<bool> VoiceFixturesWait(Func<bool> condition) =>
        Hermes.Core.Tests.Voice.VoiceFixtures.WaitUntil(condition, 15);
}
