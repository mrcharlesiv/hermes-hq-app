// [WIN-SCREEN-SOCKET-STREAM] The display socket (docs/spec/3x-screen.md §2.2), ported from the Mac's
// HermesKit/Screen/ScreenSocket.swift at 93f984bb1: `/api/display/ws?display_ticket=…`, binary frames carrying RFB.
// How it is closed matters: a close frame with 1000/1001 hands the lease back to the bot, so this type sends one only
// when asked (`Close(handBack: true)`); every other ending sends no 1000/1001 (the Mac's URLSession cancel sends a close
// frame with no status, read as 1005; here the connection is cut with no close frame, read as no code), which the
// gateway treats as a dropped link and so keeps a person's control. (A socket that sends 1001 on dispose must not be
// reused here.)

using System.Net.WebSockets;
using Hermes.Core.Net;

namespace Hermes.Core.Screen;

public abstract record ScreenSocketFrame
{
    public sealed record Binary(byte[] Data) : ScreenSocketFrame;
    public sealed record Text : ScreenSocketFrame;
}

/// What a screen stream needs from its socket. `ClientScreenSocket` is the real one; tests use fakes.
public interface IScreenSocket
{
    /// The next whole message; throws when the socket closes or drops (then `CloseCode`/`CloseReason` say how).
    Task<ScreenSocketFrame> ReceiveAsync(CancellationToken ct);
    Task SendAsync(byte[] data, CancellationToken ct);
    /// true when the pong came back in time.
    Task<bool> PingAsync(TimeSpan timeout);
    /// `handBack`: a close frame with 1000 (the gateway gives the lease back to the bot). Otherwise never 1000/1001.
    void Close(bool handBack);
    /// The code the gateway closed with (null: no close frame was seen).
    int? CloseCode { get; }
    string? CloseReason { get; }
}

/// A client that can open a bot's display socket (the Swift `GatewayDisplaySockets`).
public interface IGatewayDisplaySockets
{
    /// Dials `path` (which must be `/api/display/ws`) with the single-use `ticket`. Throws without dialling otherwise.
    Task<IScreenSocket> DisplaySocketAsync(string path, string ticket, CancellationToken ct);
}

/// The display socket over ClientWebSocket.
public sealed class ClientScreenSocket : IScreenSocket
{
    /// The dial's limit (the Mac's URLRequest timeoutInterval).
    public static readonly TimeSpan DialTimeout = TimeSpan.FromSeconds(15);

    private readonly ClientWebSocket _ws;
    private readonly SemaphoreSlim _sending = new(1, 1);     // ClientWebSocket allows one send in flight
    private int _closed;

    private ClientScreenSocket(ClientWebSocket ws) => _ws = ws;

    public static readonly TimeSpan PingEvery = TimeSpan.FromSeconds(20);
    public static readonly TimeSpan PingTimeout = TimeSpan.FromSeconds(10);

    /// Dials `url` (built by ScreenWire.DisplaySocketUrl).
    public static async Task<IScreenSocket> ConnectAsync(Uri url, string? cookie, CancellationToken ct)
    {
        var ws = new ClientWebSocket();
        ws.Options.KeepAliveInterval = PingEvery;
        ws.Options.KeepAliveTimeout = PingTimeout;
        if (cookie != null) ws.Options.SetRequestHeader("Cookie", cookie);
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(DialTimeout);
        try { await ws.ConnectAsync(url, limit.Token); }
        catch { ws.Dispose(); throw; }
        return new ClientScreenSocket(ws);
    }

    public int? CloseCode { get; private set; }
    public string? CloseReason { get; private set; }

    public async Task<ScreenSocketFrame> ReceiveAsync(CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        using var whole = new MemoryStream();
        while (true)
        {
            WebSocketReceiveResult r;
            try { r = await _ws.ReceiveAsync(buffer, ct); }
            catch (Exception) { NoteClose(); throw; }
            if (r.MessageType == WebSocketMessageType.Close)
            {
                NoteClose();
                throw new WebSocketException(WebSocketError.ConnectionClosedPrematurely, "closed");
            }
            whole.Write(buffer, 0, r.Count);
            // The Mac's maximumMessageSize: a bigger message ends the socket.
            if (whole.Length > ScreenWire.MaxMessage)
            {
                Close(handBack: false);
                throw new WebSocketException(WebSocketError.Faulted, "message too large");
            }
            if (!r.EndOfMessage) continue;
            return r.MessageType == WebSocketMessageType.Binary ? new ScreenSocketFrame.Binary(whole.ToArray()) : new ScreenSocketFrame.Text();
        }
    }

    private void NoteClose()
    {
        try
        {
            if (_ws.CloseStatus is { } code && code != WebSocketCloseStatus.Empty)
            {
                CloseCode = (int)code;
                CloseReason = _ws.CloseStatusDescription;
            }
        }
        catch (ObjectDisposedException) { }
    }

    public async Task SendAsync(byte[] data, CancellationToken ct)
    {
        await _sending.WaitAsync(ct);
        try { await _ws.SendAsync(data, WebSocketMessageType.Binary, true, ct); }
        finally { _sending.Release(); }
    }

    /// ClientWebSocket sends no ping on demand. Its own keep-alive does the Mac's ping instead: a ping every
    /// `PingEvery` (20 s, the stream's default) and the socket aborted when the pong is not back within `PingTimeout`
    /// (10 s, the stream's ping limit). A late pong therefore ends the receive, and the stream ends as a dropped link
    /// (`Closed(null, null)`) rather than `Stuck`; both reconnect. This reports whether the socket is still open.
    public Task<bool> PingAsync(TimeSpan timeout) =>
        Task.FromResult(Volatile.Read(ref _closed) == 0 && _ws.State == WebSocketState.Open);

    /// How long a hand-back waits for the gateway's answering close frame before the connection is cut.
    public static readonly TimeSpan HandBackWait = TimeSpan.FromSeconds(1);

    public void Close(bool handBack)
    {
        if (Interlocked.Exchange(ref _closed, 1) == 1) return;
        var ws = _ws;
        if (!handBack)
        {
            // No close frame at all: the connection is cut, which the gateway reads as a dropped link (no code). The
            // Mac's plain cancel sends a status-less close frame (1005); ClientWebSocket cannot send one (its Empty puts
            // 1005 on the wire, which RFC 6455 forbids), and both are "never 1000/1001" to the gateway.
            try { ws.Abort(); } catch (Exception) { }
            ws.Dispose();
            return;
        }
        var sending = _sending;
        _ = Task.Run(async () =>
        {
            using var limit = new CancellationTokenSource(HandBackWait);
            try
            {
                await sending.WaitAsync(limit.Token);
                try
                {
                    if (ws.State is WebSocketState.Open or WebSocketState.CloseReceived)
                        await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, limit.Token);
                }
                finally { sending.Release(); }
                // The 1000 is out; give the gateway its close handshake (the receive loop reads the answer) before the cut.
                while (ws.State == WebSocketState.CloseSent && !limit.IsCancellationRequested) await Task.Delay(10, limit.Token);
            }
            catch (Exception) { }
            try { ws.Abort(); } catch (Exception) { }
            ws.Dispose();
        });
    }
}

/// Dials a bot's display socket (the Swift `LiveGatewayClient.displaySocket`): the single-use display ticket from
/// `display.observe` is the only credential that route takes, so no auth ticket is minted; a path other than
/// /api/display/ws is refused without dialling.
public static class ScreenDialer
{
    public static async Task<IScreenSocket> DialAsync(Uri @base, string path, string ticket, string? cookie, CancellationToken ct)
    {
        var url = ScreenWire.DisplaySocketUrl(@base, path, ticket)
            ?? throw new GatewayException("invalid-url", "That doesn't look like a gateway address.");
        return await ClientScreenSocket.ConnectAsync(url, cookie, ct);
    }

    /// The dial a ScreenService takes for a signed-in gateway (the transport's cookies ride along, as URLSession's do).
    public static Func<string, string, CancellationToken, Task<IScreenSocket>> For(GatewaySession session) =>
        (path, ticket, ct) =>
        {
            var url = ScreenWire.DisplaySocketUrl(session.Address.Base, path, ticket);
            return DialAsync(session.Address.Base, path, ticket, url == null ? null : session.CookieHeader(url), ct);
        };
}
