using System.Net.WebSockets;
using System.Threading.Channels;
using Hermes.Core.Net;

namespace Hermes.Core.Terminal;

public abstract record TerminalFrame
{
    public sealed record Binary(byte[] Data) : TerminalFrame;
    public sealed record Text(string Value) : TerminalFrame;
}

/// The Terminal page's socket, behind an interface so the connection's tests can stand in for it
/// (HermesKit/Terminal/TerminalSocket.swift). Closing from this side is always a plain abort: the add-on keeps the
/// shell for the page to come back to (only the page's `end` message ends a shell).
public interface ITerminalSocket
{
    /// The next frame; throws when the socket closes or drops.
    Task<TerminalFrame> ReceiveAsync(CancellationToken ct);
    /// Queued in call order (keys must reach the shell in the order typed).
    void Send(TerminalFrame frame);
    void Close();
    /// The code the computer closed with (null: no close frame was seen).
    int? CloseCode { get; }
    string? CloseReason { get; }
    /// The HTTP status the upgrade was answered with when it never became a socket (a relay's 404; null once open).
    int? RefusedStatus { get; }
}

/// The socket over ClientWebSocket. Sends go through one queue, one at a time (ClientWebSocket allows one send in flight).
public sealed class ClientTerminalSocket : ITerminalSocket
{
    private readonly ClientWebSocket _ws;
    private readonly Channel<TerminalFrame> _out = Channel.CreateUnbounded<TerminalFrame>(new() { SingleReader = true });
    private readonly CancellationTokenSource _life = new();
    private int _closed;

    private ClientTerminalSocket(ClientWebSocket ws)
    {
        _ws = ws;
        _ = Task.Run(SendLoopAsync);
    }

    public int? CloseCode { get; private set; }
    public string? CloseReason { get; private set; }
    public int? RefusedStatus { get; private set; }

    /// Dials `url`. A refused upgrade (a relay's 404) comes back as a socket whose first receive fails with
    /// `RefusedStatus` set, so the connection reads it as it reads any other ending.
    public static async Task<ITerminalSocket> ConnectAsync(Uri url, string? cookie, CancellationToken ct)
    {
        var ws = new ClientWebSocket();
        ws.Options.KeepAliveInterval = TimeSpan.Zero;   // the add-on pings after 20 s of quiet
        ws.Options.CollectHttpResponseDetails = true;
        if (cookie != null) ws.Options.SetRequestHeader("Cookie", cookie);
        using var t = CancellationTokenSource.CreateLinkedTokenSource(ct);
        t.CancelAfter(TimeSpan.FromSeconds(15));
        try
        {
            await ws.ConnectAsync(url, t.Token);
        }
        catch (WebSocketException) when (ws.HttpStatusCode is var s && (int)s is >= 300 and < 600)
        {
            var refused = new RefusedSocket((int)ws.HttpStatusCode);
            ws.Dispose();
            return refused;
        }
        return new ClientTerminalSocket(ws);
    }

    public async Task<TerminalFrame> ReceiveAsync(CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        using var whole = new MemoryStream();
        while (true)
        {
            WebSocketReceiveResult r;
            try { r = await _ws.ReceiveAsync(buffer, ct); }
            catch (Exception) when (!ct.IsCancellationRequested) { NoteClose(); throw; }
            if (r.MessageType == WebSocketMessageType.Close)
            {
                NoteClose();
                throw new WebSocketException("closed");
            }
            whole.Write(buffer, 0, r.Count);
            if (whole.Length > TerminalWire.MaxMessage) throw new WebSocketException("message too large");
            if (!r.EndOfMessage) continue;
            var bytes = whole.ToArray();
            return r.MessageType == WebSocketMessageType.Binary
                ? new TerminalFrame.Binary(bytes)
                : new TerminalFrame.Text(System.Text.Encoding.UTF8.GetString(bytes));
        }
    }

    private void NoteClose()
    {
        if (_ws.CloseStatus is { } code) { CloseCode = (int)code; CloseReason = _ws.CloseStatusDescription; }
    }

    public void Send(TerminalFrame frame)
    {
        if (Volatile.Read(ref _closed) == 0) _out.Writer.TryWrite(frame);
    }

    private async Task SendLoopAsync()
    {
        try
        {
            await foreach (var frame in _out.Reader.ReadAllAsync(_life.Token))
            {
                switch (frame)
                {
                    case TerminalFrame.Binary b:
                        await _ws.SendAsync(b.Data, WebSocketMessageType.Binary, true, _life.Token);
                        break;
                    case TerminalFrame.Text t:
                        await _ws.SendAsync(System.Text.Encoding.UTF8.GetBytes(t.Value), WebSocketMessageType.Text, true, _life.Token);
                        break;
                }
            }
        }
        catch (Exception) { /* a failed send shows up as the receive failing */ }
    }

    public void Close()
    {
        if (Interlocked.Exchange(ref _closed, 1) == 1) return;
        _out.Writer.TryComplete();
        _life.Cancel();
        try { _ws.Abort(); } catch (Exception) { }
        _ws.Dispose();
    }

    /// An upgrade answered with an HTTP status (no socket).
    private sealed class RefusedSocket(int status) : ITerminalSocket
    {
        public Task<TerminalFrame> ReceiveAsync(CancellationToken ct) => Task.FromException<TerminalFrame>(new WebSocketException($"HTTP {status}"));
        public void Send(TerminalFrame frame) { }
        public void Close() { }
        public int? CloseCode => null;
        public string? CloseReason => null;
        public int? RefusedStatus => status;
    }
}

/// Dials the Terminal socket for a signed-in gateway: a fresh single-use ticket per socket (LiveGatewayClient.terminalSocket).
public static class TerminalDialer
{
    public static Func<IReadOnlyList<KeyValuePair<string, string>>, CancellationToken, Task<ITerminalSocket>> For(GatewaySession session) =>
        async (query, ct) =>
        {
            var ticket = await session.MintTicketAsync(TimeSpan.FromSeconds(10), ct);
            var url = TerminalWire.SocketUrl(session.Address.Base, session.Address.BasePath, query, ticket)
                ?? throw new GatewayException("invalid-url", "That doesn't look like a gateway address.");
            return await ClientTerminalSocket.ConnectAsync(url, session.CookieHeader(url), ct);
        };
}
