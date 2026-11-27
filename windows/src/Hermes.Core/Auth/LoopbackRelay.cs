using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Hermes.Core.Auth;

/// Catches the browser's redirect to http://127.0.0.1:&lt;port&gt;/callback (HermesKit/Auth/LoopbackRelay.swift).
/// IPv4 loopback only (Hermes rejects "localhost"), any free port, answers every connection with a small page, and
/// settles on the first GET /callback that carries code or error.
public sealed class LoopbackRelay : IDisposable
{
    public sealed record Callback(string? Code, string? Error, string? State, string? Iss);

    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly TaskCompletionSource<Callback> _done = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly CancellationTokenSource _life = new(TimeSpan.FromSeconds(900));
    private int _connections;

    public Uri RedirectUri { get; }

    public LoopbackRelay()
    {
        _listener.Start();
        RedirectUri = new Uri($"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}/callback");
        _ = AcceptLoop();
    }

    /// Start waiting before the browser opens.
    public async Task<Callback> WaitAsync(CancellationToken ct)
    {
        using var t = CancellationTokenSource.CreateLinkedTokenSource(ct);
        t.CancelAfter(TimeSpan.FromSeconds(600));
        return await _done.Task.WaitAsync(t.Token);
    }

    private async Task AcceptLoop()
    {
        try
        {
            while (!_life.IsCancellationRequested && _connections < 4 && !_done.Task.IsCompleted)
            {
                var client = await _listener.AcceptTcpClientAsync(_life.Token);
                _connections++;
                _ = Serve(client);
            }
        }
        catch (Exception) when (_life.IsCancellationRequested || _done.Task.IsCompleted) { }
        catch (ObjectDisposedException) { }
    }

    private async Task Serve(TcpClient client)
    {
        using (client)
        {
            try
            {
                using var t = CancellationTokenSource.CreateLinkedTokenSource(_life.Token);
                t.CancelAfter(TimeSpan.FromSeconds(10));
                var stream = client.GetStream();
                var buf = new byte[8192];
                var n = 0;
                while (n < buf.Length)
                {
                    var r = await stream.ReadAsync(buf.AsMemory(n), t.Token);
                    if (r == 0) break;
                    n += r;
                    if (Encoding.ASCII.GetString(buf, 0, n).Contains("\r\n\r\n")) break;
                }
                var head = Encoding.ASCII.GetString(buf, 0, n);
                var line = head.Split("\r\n", 2)[0].Split(' ');
                if (line.Length >= 2 && line[0] == "GET" && line[1].StartsWith("/callback?"))
                {
                    var q = ParseQuery(line[1][(line[1].IndexOf('?') + 1)..]);
                    q.TryGetValue("code", out var code);
                    q.TryGetValue("error", out var error);
                    if (code != null || error != null)
                    {
                        q.TryGetValue("state", out var state);
                        q.TryGetValue("iss", out var iss);
                        _done.TrySetResult(new Callback(code, error, state, iss));
                    }
                }
                var page = Encoding.UTF8.GetBytes(Page);
                var res = Encoding.ASCII.GetBytes(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n" +
                    $"Connection: close\r\nContent-Length: {page.Length}\r\n\r\n");
                await stream.WriteAsync(res, t.Token);
                await stream.WriteAsync(page, t.Token);
            }
            catch (Exception) { /* a stray connection; the wait carries on */ }
        }
    }

    internal static Dictionary<string, string> ParseQuery(string q)
    {
        var d = new Dictionary<string, string>();
        foreach (var pair in q.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = pair.Split('=', 2);
            d[Uri.UnescapeDataString(kv[0].Replace('+', ' '))] =
                kv.Length > 1 ? Uri.UnescapeDataString(kv[1].Replace('+', ' ')) : "";
        }
        return d;
    }

    private const string Page = """
        <!doctype html><html><head><meta charset="utf-8"><title>Hermes HQ</title>
        <style>body{font:16px system-ui,"Segoe UI",sans-serif;display:grid;place-items:center;height:90vh;color:#222}</style>
        </head><body><div><h2>Signed in</h2><p>You can close this tab and go back to Hermes HQ.</p></div></body></html>
        """;

    public void Dispose()
    {
        _life.Cancel();
        _listener.Stop();
        _done.TrySetCanceled();
    }
}
