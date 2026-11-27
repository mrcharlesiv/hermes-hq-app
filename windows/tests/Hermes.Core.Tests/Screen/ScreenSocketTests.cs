// [WIN-SCREEN-SOCKET-STREAM] The display socket over a real ClientWebSocket (Hermes.Core/Screen/ScreenSocket.cs) against
// a synthetic WebSocket on 127.0.0.1 (HttpListener): Windows-side tests for what the Mac's ScreenLiveWireTests.swift
// checks at the socket edge (93f984bb1) without the screen-gateway.py stand-in — frames, the close the gateway sees
// (1000 only for a hand-back, otherwise no close frame and no code), the gateway's close code and reason, a cut
// link with no code, the message limit, and the stream's pull model end to end. Nothing here is a real gateway or
// desktop: every byte is the test's own.

using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using Hermes.Core.Net;
using Hermes.Core.Screen;
using static Hermes.Core.Tests.Screen.ScreenWaits;

namespace Hermes.Core.Tests.Screen;

public sealed class ScreenSocketTests
{
    /// A display route on 127.0.0.1 that hands each accepted socket (and the ticket it came with) to the test.
    private sealed class LoopbackDisplay : IDisposable
    {
        private readonly HttpListener _http = new();
        private readonly System.Threading.Channels.Channel<(WebSocket Socket, string? Ticket)> _accepted =
            System.Threading.Channels.Channel.CreateUnbounded<(WebSocket, string?)>();
        public Uri Base { get; }
        public int Requests;

        public LoopbackDisplay()
        {
            var probe = new TcpListener(IPAddress.Loopback, 0);
            probe.Start();
            var port = ((IPEndPoint)probe.LocalEndpoint).Port;
            probe.Stop();
            Base = new Uri($"http://127.0.0.1:{port}/");
            _http.Prefixes.Add(Base.ToString());
            _http.Start();
            _ = Task.Run(Serve);
        }

        private async Task Serve()
        {
            while (_http.IsListening)
            {
                HttpListenerContext ctx;
                try { ctx = await _http.GetContextAsync(); } catch { return; }
                Interlocked.Increment(ref Requests);
                if (ctx.Request.Url!.AbsolutePath != ScreenWire.DisplayPath || !ctx.Request.IsWebSocketRequest)
                {
                    ctx.Response.StatusCode = 404;
                    ctx.Response.Close();
                    continue;
                }
                var ticket = ctx.Request.QueryString["display_ticket"];
                var ws = (await ctx.AcceptWebSocketAsync(null)).WebSocket;
                await _accepted.Writer.WriteAsync((ws, ticket));
            }
        }

        public async Task<(WebSocket Socket, string? Ticket)> Accepted()
        {
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            return await _accepted.Reader.ReadAsync(limit.Token);
        }

        /// The link is cut: every connection drops with no close frame.
        public void Cut() { try { _http.Abort(); } catch { } }

        public void Dispose() { try { _http.Stop(); _http.Close(); } catch { } }
    }

    private static async Task<IScreenSocket> Dial(LoopbackDisplay server, string ticket = "synthetic-ticket") =>
        await ScreenDialer.DialAsync(server.Base, ScreenWire.DisplayPath, ticket, cookie: null, CancellationToken.None);

    /// Reads one whole message on the server side; returns null when the client closed (its status in `closed`).
    private static async Task<(byte[]? Data, WebSocketMessageType Type, WebSocketCloseStatus? Closed)> ServerReceive(WebSocket ws)
    {
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var buffer = new byte[64 * 1024];
        using var whole = new MemoryStream();
        while (true)
        {
            WebSocketReceiveResult r;
            // The client sends its close frame and then cuts the connection (as URLSession's cancel does), so the reply
            // this side tries to send can fail; the status it read from the frame is still the one the client sent.
            try { r = await ws.ReceiveAsync(buffer, limit.Token); }
            catch (WebSocketException) when (ws.CloseStatus != null) { return (null, WebSocketMessageType.Close, ws.CloseStatus); }
            if (r.MessageType == WebSocketMessageType.Close) return (null, r.MessageType, r.CloseStatus);
            whole.Write(buffer, 0, r.Count);
            if (r.EndOfMessage) return (whole.ToArray(), r.MessageType, null);
        }
    }

    [Fact]
    public async Task FramesArriveAsBinaryOrTextAndSendsGoOutInOrder()
    {
        using var server = new LoopbackDisplay();
        var socket = await Dial(server, "ticket with/odd=chars");
        var (ws, ticket) = await server.Accepted();
        Assert.Equal("ticket with/odd=chars", ticket);
        await ws.SendAsync(new byte[] { 1, 2, 3 }, WebSocketMessageType.Binary, true, CancellationToken.None);
        await ws.SendAsync(Encoding.UTF8.GetBytes("hello"), WebSocketMessageType.Text, true, CancellationToken.None);
        // A message split over several frames is one binary frame to the stream.
        await ws.SendAsync(new byte[] { 4, 5 }, WebSocketMessageType.Binary, false, CancellationToken.None);
        await ws.SendAsync(new byte[] { 6 }, WebSocketMessageType.Binary, true, CancellationToken.None);
        Assert.Equal(new byte[] { 1, 2, 3 }, Assert.IsType<ScreenSocketFrame.Binary>(await socket.ReceiveAsync(CancellationToken.None)).Data);
        Assert.IsType<ScreenSocketFrame.Text>(await socket.ReceiveAsync(CancellationToken.None));
        Assert.Equal(new byte[] { 4, 5, 6 }, Assert.IsType<ScreenSocketFrame.Binary>(await socket.ReceiveAsync(CancellationToken.None)).Data);
        for (var i = 0; i < 50; i++) await socket.SendAsync([(byte)i, 9], CancellationToken.None);
        for (var i = 0; i < 50; i++)
        {
            var got = await ServerReceive(ws);
            Assert.Equal(WebSocketMessageType.Binary, got.Type);
            Assert.Equal(new byte[] { (byte)i, 9 }, got.Data);
        }
        Assert.True(await socket.PingAsync(TimeSpan.FromSeconds(10)));
        socket.Close(handBack: false);
    }

    [Fact]
    public async Task OnlyAHandBackClosesWith1000()
    {
        foreach (var handBack in new[] { true, false })
        {
            using var server = new LoopbackDisplay();
            var socket = await Dial(server);
            var (ws, _) = await server.Accepted();
            socket.Close(handBack);
            socket.Close(!handBack);                                    // only the first close counts
            if (handBack)
            {
                var got = await ServerReceive(ws);
                Assert.Null(got.Data);
                Assert.Equal(WebSocketCloseStatus.NormalClosure, got.Closed);   // a hand-back is a 1000 close frame
            }
            else
            {
                // Any other ending is a cut with no close frame: the gateway sees no code (never 1000 or 1001), a dropped
                // link, so a person keeps control.
                await Assert.ThrowsAnyAsync<WebSocketException>(() => ServerReceive(ws));
                Assert.Null(ws.CloseStatus);
            }
            Assert.False(await socket.PingAsync(TimeSpan.FromSeconds(10)), "a closed socket answers no ping");
        }
    }

    [Fact]
    public async Task TheGatewaysCloseCodeAndReasonArriveAsSentAndACutLinkHasNone()
    {
        foreach (var (code, reason) in new (int, string?)[] { (4000, "control-taken"), (4001, null), (4401, null), (1003, null) })
        {
            using var server = new LoopbackDisplay();
            var socket = await Dial(server);
            var (ws, _) = await server.Accepted();
            await ws.CloseOutputAsync((WebSocketCloseStatus)code, reason, CancellationToken.None);
            await Assert.ThrowsAnyAsync<Exception>(() => socket.ReceiveAsync(CancellationToken.None));
            Assert.Equal(code, socket.CloseCode);
            Assert.Equal(reason, string.IsNullOrEmpty(socket.CloseReason) ? null : socket.CloseReason);
            socket.Close(handBack: false);
        }
        using var cut = new LoopbackDisplay();
        var dropped = await Dial(cut);
        _ = await cut.Accepted();
        var began = System.Diagnostics.Stopwatch.StartNew();
        cut.Cut();
        await Assert.ThrowsAnyAsync<Exception>(() => dropped.ReceiveAsync(CancellationToken.None));
        Assert.True(began.Elapsed < TimeSpan.FromSeconds(10), $"a cut link ends the receive at once ({began.Elapsed})");
        Assert.Null(dropped.CloseCode);
        Assert.Null(dropped.CloseReason);
        dropped.Close(handBack: false);
    }

    [Fact]
    public async Task AMessageOverTheLimitEndsTheSocket()
    {
        using var server = new LoopbackDisplay();
        var socket = await Dial(server);
        var (ws, _) = await server.Accepted();
        _ = ws.SendAsync(new byte[ScreenWire.MaxMessage + 1], WebSocketMessageType.Binary, true, CancellationToken.None);
        await Assert.ThrowsAnyAsync<Exception>(() => socket.ReceiveAsync(CancellationToken.None));
        socket.Close(handBack: false);
    }

    [Fact]
    public async Task APathOtherThanTheDisplayRouteIsNeverDialled()
    {
        using var server = new LoopbackDisplay();
        foreach (var (path, ticket) in new[] { ("/api/ws", "t"), ("/api/display/ws/../ws", "t"), (ScreenWire.DisplayPath, "") })
        {
            var error = await Assert.ThrowsAsync<GatewayException>(() =>
                ScreenDialer.DialAsync(server.Base, path, ticket, cookie: null, CancellationToken.None));
            Assert.Equal("invalid-url", error.Code);
            Assert.Equal("That doesn't look like a gateway address.", error.Message);
        }
        Assert.Equal(0, Volatile.Read(ref server.Requests));
    }

    /// The stream and RFB client over the loopback socket: handshake, a picture, one request outstanding at a time,
    /// and a hand-back close after the flushed button-up (what ScreenLiveWireTests checks against the stand-in).
    [Fact]
    public async Task TheStreamRunsOverTheRealSocket()
    {
        using var server = new LoopbackDisplay();
        var socket = await Dial(server);
        var (ws, _) = await server.Accepted();
        var frames = 0;
        var ends = new List<ScreenStreamEnd>();
        var stream = new ScreenStream(socket, onReady: (_, _) => { }, onFrame: (_, _, _, _) => Interlocked.Increment(ref frames),
            onEnd: end => { lock (ends) ends.Add(end); });
        stream.Start();
        await ws.SendAsync(RfbBuild.Preamble(64, 48), WebSocketMessageType.Binary, true, CancellationToken.None);
        var fill = RfbBuild.Update([RfbBuild.TightFill(0, 0, 64, 48, r: 10, g: 20, b: 30)]);
        var kinds = new List<byte>();
        var outstanding = 0;
        var maxOutstanding = 0;
        while (Volatile.Read(ref frames) < 3)
        {
            var got = await ServerReceive(ws);
            Assert.NotNull(got.Data);
            kinds.Add(got.Data![0]);
            if (got.Data[0] != 3) continue;
            maxOutstanding = Math.Max(maxOutstanding, ++outstanding);
            await ws.SendAsync(fill, WebSocketMessageType.Binary, true, CancellationToken.None);
            outstanding--;
        }
        Assert.Equal(new byte[] { 82, 1, 1, 0, 2, 3 }, kinds.Take(6).ToArray());
        Assert.Equal(1, maxOutstanding);
        Assert.True(await ScreenWait(() => stream.IsLive));
        Assert.Equal("1e140a1e140a1e140a1e140a1e140a", stream.Pacing.Probe);
        var up = RfbMessage.Pointer(0, 5, 5);
        Assert.True(await stream.StopAndWait(handBack: true, flush: [up], limit: TimeSpan.FromSeconds(10)));
        while (true)
        {
            var got = await ServerReceive(ws);
            if (got.Data == null) { Assert.Equal(WebSocketCloseStatus.NormalClosure, got.Closed); break; }
            if (got.Data[0] == 5) Assert.Equal(up, got.Data);
        }
        lock (ends) Assert.Empty(ends);
    }
}
