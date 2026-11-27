// Watch Browser service discovery, caching, activity channel, JPEG frame decoder, pacing, and watch session tests.

using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using Hermes.Core.Browser;
using Hermes.Core.Composer;
using Hermes.Core.Net;
using Hermes.Core.Rpc;
using Hermes.Core.Tests.Screen;

namespace Hermes.Core.Tests.Browser;

internal sealed class FakeMemoryStore : IKeyValueStore
{
    private readonly ConcurrentDictionary<string, string> _map = new();
    public string? Get(string key) => _map.TryGetValue(key, out var v) ? v : null;
    public void Set(string key, string? value)
    {
        if (value == null) _map.TryRemove(key, out _);
        else _map[key] = value;
    }
}

internal sealed class FakeBrowserSocket : IBrowserSocket
{
    private readonly Channel<string?> _inbound = Channel.CreateUnbounded<string?>();
    public ConcurrentQueue<string> Sent { get; } = new();
    public int CloseCode { get; set; } = 1000;
    public bool Closed { get; private set; }
    public string? ClosedAfterText { get; private set; }

    public void Enqueue(string text) => _inbound.Writer.TryWrite(text);
    public void Drop(int closeCode = 1006)
    {
        CloseCode = closeCode;
        _inbound.Writer.TryComplete();
    }

    public async Task<string?> ReceiveTextAsync(CancellationToken ct)
    {
        while (await _inbound.Reader.WaitToReadAsync(ct).ConfigureAwait(false))
            if (_inbound.Reader.TryRead(out var item)) return item;
        return null;
    }

    public Task SendTextAsync(string text, CancellationToken ct = default)
    {
        Sent.Enqueue(text);
        return Task.CompletedTask;
    }

    public void Close(int code = 1000)
    {
        Closed = true;
        CloseCode = code;
        _inbound.Writer.TryComplete();
    }

    public void CloseAfter(string text, TimeSpan? limit = null)
    {
        ClosedAfterText = text;
        Sent.Enqueue(text);
        Close(1000);
    }

    public void Dispose() => Close(1001);
}

internal sealed class FakeBrowserGateway : IBrowserGateway
{
    public string AccountId { get; set; } = "acct-test";
    public Uri BaseUrl { get; set; } = new("https://gateway.example.com");
    public Func<string, string, IReadOnlyList<KeyValuePair<string, string>>?, JsonNode?, Task<JsonNode>>? OnJson { get; set; }
    public Func<string, IReadOnlyList<KeyValuePair<string, string>>, Task<IBrowserSocket>>? OnSocket { get; set; }
    public List<(string Method, string Path, JsonNode? Body)> Requests { get; } = [];

    private readonly List<Action<ConnectionState>> _stateListeners = [];
    private ConnectionState _state = ConnectionState.Open;

    public void PushState(ConnectionState next)
    {
        _state = next;
        foreach (var l in _stateListeners.ToArray()) l(next);
    }

    public Task<JsonNode> JsonAsync(
        string method,
        string path,
        IReadOnlyList<KeyValuePair<string, string>>? query = null,
        JsonNode? body = null,
        TimeSpan? timeout = null,
        CancellationToken ct = default)
    {
        Requests.Add((method, path, body));
        if (OnJson == null) throw new GatewayException("http", "not found", 404);
        return OnJson(method, path, query, body);
    }

    public Task<IBrowserSocket> PluginSocketAsync(
        string path,
        IReadOnlyList<KeyValuePair<string, string>> query,
        int maxBytes = BrowserWire.MaxMessage,
        CancellationToken ct = default)
    {
        if (OnSocket == null) throw new GatewayException("http", "no socket", 503);
        return OnSocket(path, query);
    }

    public IDisposable ConnectionStates(Action<ConnectionState> handler)
    {
        _stateListeners.Add(handler);
        handler(_state);
        return new Unsub(() => _stateListeners.Remove(handler));
    }

    private sealed class Unsub(Action stop) : IDisposable
    {
        public void Dispose() => stop();
    }
}

public sealed class BrowserServiceAndSessionTests
{
    private const string RowId = "0123456789abcdef01234567";

    private static JsonNode ReadyHealth(bool hosted = false, bool knowsHosted = true, string version = "3.10.0") =>
        JsonNode.Parse($$"""
            {
              "installed": true,
              "protocol": 3,
              "version": "{{version}}",
              "hosted": {{(hosted ? "true" : "false")}},
              "features": { "control": true, "choice": true, "cloud": true, "cloud_all": true, "dialogs": true, "hosted": {{(knowsHosted ? "true" : "false")}} }
            }
            """)!;

    [Fact]
    public async Task PluginDiscoveryFallsBackToLegacyCachesReadyAndNotifiesHostedGateway()
    {
        // Fallback from hermes-hq-browser 404 to dispatch-browser
        var gw = new FakeBrowserGateway
        {
            OnJson = (_, path, _, _) =>
            {
                if (path == BrowserWire.Plugin + "/health") throw new GatewayException("http", "404", 404);
                if (path == BrowserWire.LegacyPlugin + "/health") return Task.FromResult(ReadyHealth());
                throw new GatewayException("http", "404", 404);
            },
        };
        var service = new BrowserService(gw, new FakeMemoryStore());
        var found = await service.PluginAsync();
        Assert.True(found.Legacy);
        Assert.Equal(BrowserWire.LegacyPlugin, found.Base);
        Assert.Equal(BrowserSetup.Ready, found.Setup);

        // Cached hit skips extra HTTP call
        var countBefore = gw.Requests.Count;
        var cached = await service.PluginAsync();
        Assert.Equal(found, cached);
        Assert.Equal(countBefore, gw.Requests.Count);
        service.Shutdown();

        // Hosted gateway automatically POSTs /cloud { hosted: true } once when health reports hosted=false
        var postedHosted = false;
        var hostedGw = new FakeBrowserGateway
        {
            BaseUrl = new Uri("https://ivy.agents.nousresearch.com"),
            OnJson = (method, path, _, body) =>
            {
                if (method == "POST" && path == BrowserWire.Plugin + "/cloud" && body?["hosted"]?.GetValue<bool>() == true)
                {
                    postedHosted = true;
                    return Task.FromResult<JsonNode>(new JsonObject { ["ok"] = true });
                }
                return Task.FromResult(ReadyHealth(hosted: postedHosted, knowsHosted: true));
            },
        };
        var hostedService = new BrowserService(hostedGw, new FakeMemoryStore());
        var hostedInfo = await hostedService.PluginAsync();
        Assert.True(postedHosted);
        Assert.True(BrowserHealth.Hosted(hostedInfo.Health));
        hostedService.Shutdown();
    }

    [Fact]
    public async Task FrameDecoderDecodesRealJpegOffMainThreadAndSkipsStaleWaitingFrames()
    {
        var redJpeg = ScreenTestImage.Red64;
        var greenJpeg = ScreenTestImage.Green64;

        // Direct managed decode produces 64x64 BGRA with strong red channel
        var direct = ManagedBrowserImageDecoder.Instance.Decode(redJpeg);
        Assert.NotNull(direct);
        Assert.Equal(64, direct!.Width);
        Assert.Equal(64, direct.Height);
        Assert.True(direct.Bgra[2] > 180); // R
        Assert.Equal(0xFF, direct.Bgra[3]); // A

        // Slow first decode lets frames 2 and 3 queue -> frame 2 is skipped, frame 3 decodes
        var firstEntered = new ManualResetEventSlim();
        var releaseFirst = new ManualResetEventSlim();
        var decodedSeqs = new ConcurrentQueue<int>();
        var skippedSeqs = new ConcurrentQueue<int>();
        var allDone = new TaskCompletionSource();

        var blockingDecoder = new TestSlowDecoder(firstEntered, releaseFirst, ManagedBrowserImageDecoder.Instance);
        var decoder = new BrowserFrameDecoder(
            decoded: (frame, _) =>
            {
                decodedSeqs.Enqueue(frame.Seq);
                if (frame.Seq == 3) allDone.TrySetResult();
            },
            skipped: seq => skippedSeqs.Enqueue(seq),
            failed: () => { },
            imageDecoder: blockingDecoder,
            mainThreadId: Environment.CurrentManagedThreadId);

        Assert.True(decoder.Push(new BrowserFrame(1, "t1", 0, 64, 64, redJpeg)));
        Assert.True(firstEntered.Wait(TimeSpan.FromSeconds(5)));
        Assert.True(decoder.Push(new BrowserFrame(2, "t1", 0, 64, 64, redJpeg)));
        Assert.True(decoder.Push(new BrowserFrame(3, "t1", 0, 64, 64, greenJpeg)));
        releaseFirst.Set();

        await allDone.Task.WaitAsync(TimeSpan.FromSeconds(5));
        decoder.Close();

        Assert.Equal([1, 3], decodedSeqs.ToArray());
        Assert.Equal([2], skippedSeqs.ToArray());
        Assert.Equal(0, decoder.Stats.MainThreadDecodes);
        Assert.Equal(1, decoder.Stats.Skipped);

        // Corrupt JPEG invokes failure callback
        var failed = new TaskCompletionSource();
        var corruptDecoder = new BrowserFrameDecoder((_, _) => { }, _ => { }, () => failed.TrySetResult());
        corruptDecoder.Push(new BrowserFrame(1, "t1", 0, 64, 64, [0xFF, 0xD8, 0x00, 0x00, 0xFF]));
        await failed.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(1, corruptDecoder.Stats.Failed);
    }

    private sealed class TestSlowDecoder(ManualResetEventSlim entered, ManualResetEventSlim release, IBrowserImageDecoder inner)
        : IBrowserImageDecoder
    {
        private int _calls;
        public BrowserDecodedImage? Decode(byte[] jpeg)
        {
            if (Interlocked.Increment(ref _calls) == 1)
            {
                entered.Set();
                release.Wait(TimeSpan.FromSeconds(5));
            }
            return inner.Decode(jpeg);
        }
    }

    [Fact]
    public async Task WatchSessionControlHandoffPendingTypingFramesAndCloseAfterGive()
    {
        var socket1 = new FakeBrowserSocket();
        var socket2 = new FakeBrowserSocket();
        var dials = 0;
        var gw = new FakeBrowserGateway
        {
            OnJson = (_, _, _, _) => Task.FromResult(ReadyHealth()),
            OnSocket = (_, _) => Task.FromResult<IBrowserSocket>(Interlocked.Increment(ref dials) == 1 ? socket1 : socket2),
        };
        var service = new BrowserService(gw, new FakeMemoryStore());
        var session = new BrowserWatchSession(service, RowId, BrowserWire.Plugin, "ivy", "Ivy");

        var frameReceived = new TaskCompletionSource<BrowserFrame>();
        var copiedText = new TaskCompletionSource<string>();
        var notices = new ConcurrentQueue<string>();

        session.OnFrame = (_, frame) => frameReceived.TrySetResult(frame);
        session.OnCopied = text => copiedText.TrySetResult(text);
        session.OnNotice = (msg, _) => { if (msg.Length > 0) notices.Enqueue(msg); };

        // Pre-enqueue initial waiting state + ping + copied so the session goes Live on connect
        socket1.Enqueue("""{"type":"state","tabs":[{"id":"t1","title":"Shop","url":"https://shop.example.com"}],"tab":"t1","follow":true,"control":{"state":"waiting","mine":true,"epoch":3}}""");
        socket1.Enqueue("""{"type":"ping"}""");
        socket1.Enqueue("""{"type":"copied","text":"invoice-42"}""");

        session.SetViewSize(800, 600, 1.0);
        session.SetShown(true);
        await WaitUntilAsync(() => session.Link == BrowserWatchLink.Live && session.Waiting);
        Assert.Equal("invoice-42", await copiedText.Task.WaitAsync(TimeSpan.FromSeconds(5)));
        await WaitUntilAsync(() => socket1.Sent.Contains("""{"type":"pong"}"""));

        // Server grants control -> Mine becomes true
        socket1.Enqueue("""{"type":"state","tabs":[{"id":"t1","title":"Shop","url":"https://shop.example.com"}],"tab":"t1","follow":true,"control":{"state":"person","mine":true,"epoch":4}}""");
        await WaitUntilAsync(() => session.Mine);

        // Server sends a real JPEG frame -> decoded & acked
        var jpegB64 = Convert.ToBase64String(ScreenTestImage.Red64);
        socket1.Enqueue($$"""{"type":"frame","seq":1,"tab":"t1","epoch":4,"width":64,"height":64,"image":"data:image/jpeg;base64,{{jpegB64}}"}""");
        var gotFrame = await frameReceived.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(1, gotFrame.Seq);
        await WaitUntilAsync(() => socket1.Sent.Any(s => s.Contains("\"type\":\"ack\"") && s.Contains("\"seq\":1")));

        // Socket drops while user holds control -> typing queues into PendingTyping, then flushes on reconnect with new epoch
        socket1.Drop(1006);
        await WaitUntilAsync(() => session.Link == BrowserWatchLink.Reconnecting);
        session.Input(new BrowserInput.Text("hello"));
        Assert.Contains(notices, n => n.Contains("Reconnecting"));

        socket2.Enqueue("""{"type":"state","tabs":[{"id":"t1","title":"Shop","url":"https://shop.example.com"}],"tab":"t1","follow":true,"control":{"state":"person","mine":true,"epoch":5}}""");
        session.LinkRestored();
        await WaitUntilAsync(() => socket2.Sent.Any(s => s.Contains("\"text\":\"hello\"") && s.Contains("\"epoch\":5")));

        // Stopping while holding control sends Give via CloseAfter
        session.Stop();
        Assert.Equal("""{"type":"give"}""", socket2.ClosedAfterText);
        Assert.True(socket2.Closed);
        service.Shutdown();
    }

    [Fact]
    public async Task ActivityChannelPublishesRowsAndShutsDownCleanly()
    {
        var socket = new FakeBrowserSocket();
        var gw = new FakeBrowserGateway
        {
            OnJson = (_, _, _, _) => Task.FromResult(ReadyHealth()),
            OnSocket = (_, _) => Task.FromResult<IBrowserSocket>(socket),
        };
        var service = new BrowserService(gw, new FakeMemoryStore());
        var updated = new TaskCompletionSource();
        socket.Enqueue($$"""
            {"schema":"dispatch-browser.list.v3","browsers":[
              {"id":"{{RowId}}","profile":"ivy","session_id":"s1","url":"https://example.com","active":true,"control":"bot","agent_at":100}
            ]}
            """);
        var sub = service.Activity.Subscribe(() =>
        {
            if (service.Activity.Rows.Count > 0) updated.TrySetResult();
        });

        await updated.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(service.Activity.Connected);
        Assert.Single(service.Activity.Rows);
        Assert.Equal("ivy", service.Activity.Rows[0].Profile);

        sub.Cancel();
        service.Shutdown();
        Assert.True(service.IsShutDown);
    }

    [Fact]
    public void PacingComputesMedianP95AndSummary()
    {
        var pacing = BrowserPacing.From([0.010, 0.020, 0.030, 0.040, 0.100], frames: 5, mainThreadDecodes: 0);
        Assert.Equal(5, pacing.Frames);
        Assert.Equal(30, pacing.MedianMs, 1);
        Assert.Equal(40, pacing.P95Ms, 1);
        Assert.Equal("frames=5 p50=30 p95=40 mainDecodes=0", pacing.Summary);
    }

    private static async Task WaitUntilAsync(Func<bool> predicate, int timeoutMs = 4000)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (!predicate() && DateTime.UtcNow < deadline)
            await Task.Delay(15);
        Assert.True(predicate());
    }
}
