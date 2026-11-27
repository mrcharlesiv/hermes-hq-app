// Watch Browser's connection to the gateway's browser plugin (hermes-hq-browser, or dispatch-browser under its old
// name): plugin discovery, the activity list (one socket per account, shared by the chat card, Bots and the viewer),
// the bot's own-Chrome status, per-bot Chrome profile choice (plugin 3.6+) and Browser Use Cloud (plugin 3.9–3.11+).
// C# twin of HermesKit/Browser/BrowserService.swift.

using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Composer;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Browser;

/// One text WebSocket to a gateway browser plugin route. `ClientBrowserSocket` is the real one; tests use fakes.
public interface IBrowserSocket : IDisposable
{
    /// Next UTF-8 text message; returns null on clean close, throws on drop (then `CloseCode` carries the close status).
    Task<string?> ReceiveTextAsync(CancellationToken ct);
    Task SendTextAsync(string text, CancellationToken ct = default);
    void Close(int code = 1000);
    /// Sends a final message (e.g. Give Back), then closes once sent or after `limit` (Audit 14-7).
    void CloseAfter(string text, TimeSpan? limit = null);
    int CloseCode { get; }
}

/// Real WebSocket transport for plugin sockets over ClientWebSocket.
public sealed class ClientBrowserSocket : IBrowserSocket
{
    public static readonly TimeSpan DialTimeout = TimeSpan.FromSeconds(15);

    private readonly ClientWebSocket _ws;
    private readonly SemaphoreSlim _sendGate = new(1, 1);
    private readonly int _maxBytes;
    private int _closed;

    private ClientBrowserSocket(ClientWebSocket ws, int maxBytes)
    {
        _ws = ws;
        _maxBytes = maxBytes;
    }

    public static async Task<IBrowserSocket> ConnectAsync(Uri url, string? cookie, int maxBytes, CancellationToken ct)
    {
        var ws = new ClientWebSocket();
        ws.Options.KeepAliveInterval = TimeSpan.Zero; // plugin protocol has its own ping/pong
        if (cookie != null) ws.Options.SetRequestHeader("Cookie", cookie);
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(DialTimeout);
        try { await ws.ConnectAsync(url, limit.Token).ConfigureAwait(false); }
        catch { ws.Dispose(); throw; }
        return new ClientBrowserSocket(ws, maxBytes);
    }

    public int CloseCode { get; private set; } = 1006;

    public async Task<string?> ReceiveTextAsync(CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        using var whole = new MemoryStream();
        while (true)
        {
            WebSocketReceiveResult r;
            try { r = await _ws.ReceiveAsync(buffer, ct).ConfigureAwait(false); }
            catch (Exception) { NoteClose(); throw; }
            if (r.MessageType == WebSocketMessageType.Close)
            {
                NoteClose();
                return null;
            }
            whole.Write(buffer, 0, r.Count);
            if (whole.Length > _maxBytes)
            {
                Close(1009);
                return null;
            }
            if (!r.EndOfMessage) continue;
            return Encoding.UTF8.GetString(whole.GetBuffer(), 0, (int)whole.Length);
        }
    }

    private void NoteClose()
    {
        try
        {
            if (_ws.CloseStatus is { } status && status != WebSocketCloseStatus.Empty) CloseCode = (int)status;
        }
        catch (ObjectDisposedException) { }
    }

    public async Task SendTextAsync(string text, CancellationToken ct = default)
    {
        if (Volatile.Read(ref _closed) != 0) return;
        var bytes = Encoding.UTF8.GetBytes(text);
        await _sendGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (Volatile.Read(ref _closed) == 0 && _ws.State == WebSocketState.Open)
                await _ws.SendAsync(bytes, WebSocketMessageType.Text, true, ct).ConfigureAwait(false);
        }
        catch (Exception e) when (e is WebSocketException or ObjectDisposedException or InvalidOperationException) { }
        finally { _sendGate.Release(); }
    }

    public void Close(int code = 1000)
    {
        if (Interlocked.Exchange(ref _closed, 1) == 1) return;
        var ws = _ws;
        _ = Task.Run(async () =>
        {
            try
            {
                if (ws.State == WebSocketState.Open)
                {
                    using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
                    await ws.CloseOutputAsync((WebSocketCloseStatus)code, null, cts.Token).ConfigureAwait(false);
                }
            }
            catch (Exception) { }
            try { ws.Abort(); } catch (Exception) { }
            ws.Dispose();
        });
    }

    public void CloseAfter(string text, TimeSpan? limit = null)
    {
        if (Interlocked.Exchange(ref _closed, 1) == 1) return;
        var ws = _ws;
        var wait = limit ?? TimeSpan.FromSeconds(2);
        var bytes = Encoding.UTF8.GetBytes(text);
        _ = Task.Run(async () =>
        {
            using var cts = new CancellationTokenSource(wait);
            try
            {
                await _sendGate.WaitAsync(cts.Token).ConfigureAwait(false);
                try
                {
                    if (ws.State == WebSocketState.Open)
                    {
                        await ws.SendAsync(bytes, WebSocketMessageType.Text, true, cts.Token).ConfigureAwait(false);
                        await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, cts.Token).ConfigureAwait(false);
                    }
                }
                finally { _sendGate.Release(); }
            }
            catch (Exception) { }
            try { ws.Abort(); } catch (Exception) { }
            ws.Dispose();
        });
    }

    public void Dispose() => Close(1001);
}

/// What BrowserService asks of its gateway: JSON REST calls, plugin WebSockets, and connection state changes.
public interface IBrowserGateway
{
    string AccountId { get; }
    Uri BaseUrl { get; }

    Task<JsonNode> JsonAsync(
        string method,
        string path,
        IReadOnlyList<KeyValuePair<string, string>>? query = null,
        JsonNode? body = null,
        TimeSpan? timeout = null,
        CancellationToken ct = default);

    Task<IBrowserSocket> PluginSocketAsync(
        string path,
        IReadOnlyList<KeyValuePair<string, string>> query,
        int maxBytes = BrowserWire.MaxMessage,
        CancellationToken ct = default);

    IDisposable ConnectionStates(Action<ConnectionState> handler);
}

/// The signed-in HermesClient wired as an IBrowserGateway.
public sealed class ClientBrowserGateway(HermesClient client) : IBrowserGateway
{
    public HermesClient Client { get; } = client;
    public string AccountId => Client.AccountId;
    public Uri BaseUrl => Client.Session.Address.Base;

    public async Task<JsonNode> JsonAsync(
        string method,
        string path,
        IReadOnlyList<KeyValuePair<string, string>>? query = null,
        JsonNode? body = null,
        TimeSpan? timeout = null,
        CancellationToken ct = default)
    {
        var effectiveTimeout = timeout ?? TimeSpan.FromSeconds(8);
        var httpMethod = new HttpMethod(method);
        if (effectiveTimeout > TimeSpan.FromSeconds(120))
        {
            // Profile copy can take up to 600 s: use the byte transfer lane.
            var payload = body == null ? null : Encoding.UTF8.GetBytes(body.ToJsonString());
            var byteAnswer = await Client.Session.SendBytesAsync(
                httpMethod, path, query, payload, "application/json", effectiveTimeout, ct).ConfigureAwait(false);
            var text = Encoding.UTF8.GetString(byteAnswer.Body);
            if (!byteAnswer.Ok)
                throw GatewaySession.HttpError(new HttpAnswer(byteAnswer.Status, text, byteAnswer.Headers));
            return J.Parse(text) ?? throw new GatewayException("not-hermes", "The gateway sent something that isn't JSON.", byteAnswer.Status);
        }
        var answer = await Client.Session.SendAsync(httpMethod, path, query, body, effectiveTimeout, ct: ct).ConfigureAwait(false);
        return GatewaySession.Require(answer);
    }

    public async Task<IBrowserSocket> PluginSocketAsync(
        string path,
        IReadOnlyList<KeyValuePair<string, string>> query,
        int maxBytes = BrowserWire.MaxMessage,
        CancellationToken ct = default)
    {
        var ticket = await Client.Session.MintTicketAsync(TimeSpan.FromSeconds(8), ct).ConfigureAwait(false);
        var url = BrowserWire.SocketUrl(Client.Session.Address.Base, path, query, ticket)
            ?? throw new GatewayException("invalid-url", "That doesn't look like a gateway address.");
        return await ClientBrowserSocket.ConnectAsync(url, Client.Session.CookieHeader(url), maxBytes, ct).ConfigureAwait(false);
    }

    public IDisposable ConnectionStates(Action<ConnectionState> handler)
    {
        Client.Rpc.StateChanged += handler;
        handler(Client.Rpc.State);
        return new Subscription(() => Client.Rpc.StateChanged -= handler);
    }

    private sealed class Subscription(Action stop) : IDisposable
    {
        private int _done;
        public void Dispose() { if (Interlocked.Exchange(ref _done, 1) == 0) stop(); }
    }
}

// ------------------------------------------------------------------ Per-bot choice & Browser Use Cloud models

public abstract record BrowserChoiceChange
{
    private BrowserChoiceChange() { }
    public sealed record Own : BrowserChoiceChange { public static readonly Own Instance = new(); }
    public sealed record Copy(string Source) : BrowserChoiceChange;
    public sealed record Refresh : BrowserChoiceChange { public static readonly Refresh Instance = new(); }
    public sealed record Window(bool Normal) : BrowserChoiceChange;
    /// Hand a browser the plugin doesn't run to it (only when `CanTakeOver`).
    public sealed record TakeOver : BrowserChoiceChange { public static readonly TakeOver Instance = new(); }
    /// Browse in Browser Use Cloud (plugin 3.9+; needs the person's API key saved first).
    public sealed record Cloud : BrowserChoiceChange { public static readonly Cloud Instance = new(); }
}

public sealed record ChromeProfile(string Dir, string Name, string? Account = null)
{
    public string Id => Dir;

    public static ChromeProfile? Parse(JsonNode? value)
    {
        if (value is not JsonObject) return null;
        var dir = BrowserJson.Str(value, "dir");
        if (string.IsNullOrEmpty(dir)) return null;
        return new ChromeProfile(dir, BrowserJson.Str(value, "name") ?? dir, BrowserJson.Str(value, "account"));
    }
}

public sealed record ChromeProfiles(
    bool Supported,
    string? Browser,
    IReadOnlyList<ChromeProfile> Profiles,
    string? Reason,
    string? Program = null)
{
    public static ChromeProfiles Parse(JsonNode? value)
    {
        var profiles = value is JsonObject o && o["profiles"] is JsonArray arr
            ? arr.Select(ChromeProfile.Parse).OfType<ChromeProfile>().ToArray()
            : [];
        return new ChromeProfiles(
            BrowserJson.Bool(value, "supported") == true,
            BrowserJson.Str(value, "browser"),
            profiles,
            BrowserJson.Str(value, "reason"),
            BrowserJson.Str(value, "python") is { } py ? BrowserJson.Prefix(py, 300) : null);
    }

    public bool Equals(ChromeProfiles? other) =>
        other is not null && Supported == other.Supported && Browser == other.Browser
        && Profiles.SequenceEqual(other.Profiles) && Reason == other.Reason && Program == other.Program;

    public override int GetHashCode() => HashCode.Combine(Supported, Browser, Profiles.Count, Reason, Program);
}

/// A bot's browser choice as the plugin reports it.
public sealed record BrowserChoice(
    string Profile,
    ChromeProfile? Copy,
    DateTimeOffset? CopiedAt,
    bool NormalWindow,
    bool Changeable,
    string? Blocked = null,
    bool CanTakeOver = false,
    bool Hosted = false)
{
    /// The bot browses in Browser Use Cloud (the plugin reports it as `blocked: "cloud"`: it runs no Chrome for it).
    public bool Cloud => Blocked == "cloud";

    public static BrowserChoice? Parse(JsonNode? value)
    {
        if (value is not JsonObject || BrowserJson.Str(value, "schema") != "hermes-hq-browser.choice.v1") return null;
        var profile = BrowserJson.Str(value, "profile");
        if (profile == null) return null;
        var source = BrowserJson.Str(value, "mode") == "copy" ? ChromeProfile.Parse(value["source"]) : null;
        DateTimeOffset? copiedAt = BrowserJson.Double(value, "copied_at") is { } ts && double.IsFinite(ts)
            ? DateTimeOffset.FromUnixTimeMilliseconds((long)(ts * 1000.0))
            : null;
        var rawBlocked = BrowserJson.Str(value, "blocked");
        var blocked = string.IsNullOrEmpty(rawBlocked) ? null : BrowserJson.Prefix(rawBlocked, 40);
        return new BrowserChoice(
            profile,
            source,
            copiedAt,
            BrowserJson.Str(value, "window") == "normal",
            BrowserJson.Bool(value, "changeable") == true,
            blocked,
            BrowserJson.Bool(value, "can_take_over") == true,
            BrowserJson.Bool(value, "hosted") == true);
    }
}

/// Browser Use Cloud on this computer: whether the person's API key is saved (never the key itself).
public sealed record BrowserCloud(bool KeySet, string? KeyHint = null, bool All = false, IReadOnlyList<string>? Skipped = null)
{
    public IReadOnlyList<string> SkippedList => Skipped ?? [];

    public static BrowserCloud? Parse(JsonNode? value)
    {
        if (value is not JsonObject || BrowserJson.Str(value, "schema") != "hermes-hq-browser.cloud.v1") return null;
        var hint = BrowserJson.Str(value, "key_hint") is { } h ? BrowserJson.Prefix(h, 8) : null;
        var skipped = value["skipped"] is JsonArray arr
            ? arr.Take(50).Select(BrowserJson.AsString).OfType<string>().Select(s => BrowserJson.Prefix(s, 60)).ToArray()
            : [];
        return new BrowserCloud(
            BrowserJson.Bool(value, "key_set") == true,
            hint,
            BrowserJson.Bool(value, "all") == true,
            skipped);
    }

    public bool Equals(BrowserCloud? other) =>
        other is not null && KeySet == other.KeySet && KeyHint == other.KeyHint && All == other.All
        && SkippedList.SequenceEqual(other.SkippedList);

    public override int GetHashCode() => HashCode.Combine(KeySet, KeyHint, All, SkippedList.Count);
}

// ------------------------------------------------------------------ BrowserService & ActivityChannel

public sealed record BrowserPluginInfo(string Base, JsonNode Health, bool Legacy)
{
    public BrowserSetup Setup => BrowserHealth.Setup(Health);
}

/// The browser plugin of one gateway account.
public sealed class BrowserService
{
    public static readonly TimeSpan HealthReuse = TimeSpan.FromMinutes(5);

    private readonly object _gate = new();
    private readonly SynchronizationContext? _main;
    private readonly List<WeakReference<BrowserWatchSession>> _watchers = [];
    private readonly IDisposable _states;
    private ConnectionState? _lastState;
    private string _base = BrowserWire.Plugin;
    private (BrowserPluginInfo Plugin, DateTimeOffset At)? _ready;
    private BrowserActivityChannel? _activity;

    public IBrowserGateway Gateway { get; }
    public IKeyValueStore Prefs { get; }
    public IBrowserImageDecoder ImageDecoder { get; set; } = ManagedBrowserImageDecoder.Instance;
    public BrowserLastPages? LastPages { get; set; }
    public bool HostedGateway { get; set; }
    public string? AccountId { get; set; }
    public bool IsShutDown { get; private set; }
    public Action<string>? Note { get; set; }
    /// Optional UI-thread dispatcher hook (WinUI sets DispatcherQueue.TryEnqueue); falls back to SynchronizationContext.
    public Action<Action>? PostToMain { get; set; }

    public BrowserActivityChannel Activity => _activity ??= new BrowserActivityChannel(this);

    public BrowserService(IBrowserGateway gateway, IKeyValueStore? prefs = null)
    {
        Gateway = gateway;
        Prefs = prefs ?? new MemoryStore();
        AccountId = gateway.AccountId;
        HostedGateway = BrowserWire.IsCloudHost(gateway.BaseUrl);
        _main = SynchronizationContext.Current;
        _states = gateway.ConnectionStates(state => Post(() => HandleConnectionState(state)));
    }

    public static BrowserService For(
        HermesClient client,
        IKeyValueStore prefs,
        BrowserLastPages? lastPages = null,
        IBrowserImageDecoder? imageDecoder = null) =>
        new(new ClientBrowserGateway(client), prefs)
        {
            LastPages = lastPages,
            ImageDecoder = imageDecoder ?? ManagedBrowserImageDecoder.Instance,
        };

    internal void Post(Action work)
    {
        if (PostToMain is { } dispatch) { dispatch(work); return; }
        if (_main == null || ReferenceEquals(SynchronizationContext.Current, _main)) work();
        else _main.Post(_ => work(), null);
    }

    private void HandleConnectionState(ConnectionState state)
    {
        var old = _lastState;
        _lastState = state;
        if (old is { } was && BrowserLinkRule.Restored(was, state)) LinkRestored();
    }

    public void Register(BrowserWatchSession session)
    {
        lock (_gate) _watchers.Add(new WeakReference<BrowserWatchSession>(session));
    }

    private List<BrowserWatchSession> LiveWatchers()
    {
        lock (_gate)
        {
            _watchers.RemoveAll(w => !w.TryGetTarget(out _));
            return _watchers.Select(w => w.TryGetTarget(out var s) ? s : null).OfType<BrowserWatchSession>().ToList();
        }
    }

    internal int DebugWatcherCount => LiveWatchers().Count;

    public void Shutdown()
    {
        if (IsShutDown) return;
        IsShutDown = true;
        _states.Dispose();
        foreach (var session in LiveWatchers()) session.ShutDown();
        lock (_gate)
        {
            _watchers.Clear();
            _ready = null;
        }
        _activity?.Shutdown();
    }

    public void LinkRestored()
    {
        if (IsShutDown) return;
        foreach (var session in LiveWatchers()) session.LinkRestored();
        _activity?.LinkRestored();
    }

    /// The ready answer still within its 5 minutes, without asking (null when there is none).
    public BrowserPluginInfo? CachedPlugin
    {
        get
        {
            lock (_gate)
            {
                if (_ready is not { } r || DateTimeOffset.UtcNow - r.At >= HealthReuse) return null;
                return r.Plugin;
            }
        }
    }

    public void ForgetPlugin()
    {
        lock (_gate) _ready = null;
    }

    public static bool IsMissing(Exception error) => error is GatewayException { Status: 404 };

    /// The plugin on this gateway: hermes-hq-browser, else dispatch-browser. Ready answer reused for 5 minutes.
    public async Task<BrowserPluginInfo> PluginAsync(bool fresh = false, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        if (!fresh && CachedPlugin is { } cached) return cached;
        string first;
        lock (_gate) first = _base;
        var second = first == BrowserWire.Plugin ? BrowserWire.LegacyPlugin : BrowserWire.Plugin;
        var limit = timeout ?? TimeSpan.FromSeconds(8);
        foreach (var candidate in new[] { first, second })
        {
            try
            {
                var health = await Gateway.JsonAsync("GET", candidate + "/health", timeout: limit, ct: ct).ConfigureAwait(false);
                lock (_gate) _base = candidate;
                if (HostedGateway && BrowserHealth.KnowsHosted(health) && !BrowserHealth.Hosted(health))
                {
                    try
                    {
                        await Gateway.JsonAsync("POST", candidate + "/cloud", body: new JsonObject { ["hosted"] = true }, timeout: limit, ct: ct).ConfigureAwait(false);
                        health = await Gateway.JsonAsync("GET", candidate + "/health", timeout: limit, ct: ct).ConfigureAwait(false);
                    }
                    catch (Exception) { /* best-effort hosted hint */ }
                }
                var found = new BrowserPluginInfo(candidate, health, candidate == BrowserWire.LegacyPlugin);
                lock (_gate) _ready = found.Setup == BrowserSetup.Ready ? (found, DateTimeOffset.UtcNow) : null;
                return found;
            }
            catch (GatewayException e) when (e.Status == 404)
            {
                if (candidate == first) continue;
                ForgetPlugin();
                throw;
            }
        }
        ForgetPlugin();
        throw new GatewayException("http", "The gateway answered 404.", 404);
    }

    public async Task<OwnBrowser?> OwnBrowserAsync(string profile, CancellationToken ct = default)
    {
        var found = await PluginAsync(ct: ct).ConfigureAwait(false);
        try { return OwnBrowser.Parse(await Gateway.JsonAsync("GET", found.Base + "/bots", ct: ct).ConfigureAwait(false), profile); }
        catch (Exception e) when (IsMissing(e)) { return null; }
    }

    public async Task<BrowserChoice?> ChoiceAsync(string profile, CancellationToken ct = default)
    {
        var found = await PluginAsync(ct: ct).ConfigureAwait(false);
        if (found.Setup != BrowserSetup.Ready || (!BrowserHealth.OffersChoice(found.Health) && !BrowserHealth.OffersCloud(found.Health)))
            return null;
        var answer = await Gateway.JsonAsync("GET", found.Base + "/choice",
            query: [new KeyValuePair<string, string>("profile", profile)], ct: ct).ConfigureAwait(false);
        return BrowserChoice.Parse(answer);
    }

    public async Task<BrowserCloud?> CloudAsync(CancellationToken ct = default)
    {
        var found = await PluginAsync(ct: ct).ConfigureAwait(false);
        if (found.Setup != BrowserSetup.Ready || !BrowserHealth.OffersCloud(found.Health)) return null;
        return BrowserCloud.Parse(await Gateway.JsonAsync("GET", found.Base + "/cloud", ct: ct).ConfigureAwait(false));
    }

    public async Task<BrowserCloud> SaveCloudKeyAsync(string key, CancellationToken ct = default)
    {
        var found = await PluginAsync(ct: ct).ConfigureAwait(false);
        var answer = await Gateway.JsonAsync("POST", found.Base + "/cloud",
            body: new JsonObject { ["key"] = key }, timeout: TimeSpan.FromSeconds(30), ct: ct).ConfigureAwait(false);
        return BrowserCloud.Parse(answer) ?? throw new GatewayException("not-hermes", "The gateway sent something unexpected.");
    }

    public async Task<BrowserCloud> SetCloudForAllAsync(bool on, CancellationToken ct = default)
    {
        var found = await PluginAsync(ct: ct).ConfigureAwait(false);
        var answer = await Gateway.JsonAsync("POST", found.Base + "/cloud",
            body: new JsonObject { ["all"] = on }, timeout: TimeSpan.FromSeconds(120), ct: ct).ConfigureAwait(false);
        return BrowserCloud.Parse(answer) ?? throw new GatewayException("not-hermes", "The gateway sent something unexpected.");
    }

    public async Task<(BrowserCloud Cloud, bool OffersAll, bool Hosted)?> CloudSettingsAsync(CancellationToken ct = default)
    {
        var found = await PluginAsync(ct: ct).ConfigureAwait(false);
        if (found.Legacy || found.Setup == BrowserSetup.Missing)
            throw new GatewayException("http", "The gateway answered 404.", 404);
        if (found.Setup != BrowserSetup.Ready || !BrowserHealth.OffersCloud(found.Health)) return null;
        var cloud = BrowserCloud.Parse(await Gateway.JsonAsync("GET", found.Base + "/cloud", ct: ct).ConfigureAwait(false));
        if (cloud == null) return null;
        return (cloud, BrowserHealth.OffersCloudForAll(found.Health), BrowserHealth.Hosted(found.Health));
    }

    public async Task<ChromeProfiles> ChromeProfilesAsync(CancellationToken ct = default)
    {
        var found = await PluginAsync(ct: ct).ConfigureAwait(false);
        return ChromeProfiles.Parse(await Gateway.JsonAsync("GET", found.Base + "/chrome-profiles", ct: ct).ConfigureAwait(false));
    }

    public async Task<BrowserChoice> SetChoiceAsync(string profile, BrowserChoiceChange change, CancellationToken ct = default)
    {
        var found = await PluginAsync(ct: ct).ConfigureAwait(false);
        var body = new JsonObject { ["profile"] = profile };
        switch (change)
        {
            case BrowserChoiceChange.Own: body["mode"] = "own"; break;
            case BrowserChoiceChange.Copy c: body["mode"] = "copy"; body["source"] = c.Source; break;
            case BrowserChoiceChange.Refresh: body["refresh"] = true; break;
            case BrowserChoiceChange.Window w: body["window"] = w.Normal ? "normal" : "hidden"; break;
            case BrowserChoiceChange.TakeOver: body["take_over"] = true; break;
            case BrowserChoiceChange.Cloud: body["mode"] = "cloud"; break;
        }
        var answer = await Gateway.JsonAsync("POST", found.Base + "/choice", body: body,
            timeout: TimeSpan.FromSeconds(600), ct: ct).ConfigureAwait(false);
        return BrowserChoice.Parse(answer) ?? throw new GatewayException("not-hermes", "The gateway sent something unexpected.");
    }
}

/// One foreground activity connection shared by its consumers (the chat card, Bots rows, the viewer).
public sealed class BrowserActivityChannel
{
    public static TimeSpan Linger { get; set; } = TimeSpan.FromSeconds(3);
    public static TimeSpan Retain { get; set; } = TimeSpan.FromMinutes(3);
    public static TimeSpan Silence { get; set; } = TimeSpan.FromSeconds(45);
    public static TimeSpan WatchEvery { get; set; } = TimeSpan.FromSeconds(5);
    public static TimeSpan QuietOnRestore { get; set; } = TimeSpan.FromSeconds(25);

    private readonly WeakReference<BrowserService> _service;
    private readonly object _gate = new();
    private readonly Dictionary<Guid, Action> _listeners = [];
    private int _generation;
    private IBrowserSocket? _socket;
    private CancellationTokenSource? _workCts;
    private CancellationTokenSource? _lingerCts;
    private CancellationTokenSource? _retryCts;
    private CancellationTokenSource? _watchdogCts;
    private long _lastInbound = System.Diagnostics.Stopwatch.GetTimestamp();
    private int _attempt;
    private DateTimeOffset? _retainedAt;
    private bool _foreground = true;
    private bool _shutDown;

    public IReadOnlyList<BrowserRow> Rows { get; private set; } = [];
    public bool Connected { get; private set; }
    public Action? OnRowsChanged { get; set; }

    public BrowserActivityChannel(BrowserService service) => _service = new WeakReference<BrowserService>(service);

    public BrowserSubscription Subscribe(Action listener)
    {
        var id = Guid.NewGuid();
        var shouldBegin = false;
        lock (_gate)
        {
            _listeners[id] = listener;
            if (_listeners.Count == 1)
            {
                if (_lingerCts != null)
                {
                    _lingerCts.Cancel();
                    _lingerCts.Dispose();
                    _lingerCts = null;
                    if (_socket == null && _workCts == null)
                    {
                        CancelCts(ref _retryCts);
                        shouldBegin = true;
                    }
                }
                else shouldBegin = true;
            }
        }
        if (shouldBegin) Begin();
        return new BrowserSubscription(() => Unsubscribe(id));
    }

    private void Unsubscribe(Guid id)
    {
        CancellationTokenSource? linger;
        lock (_gate)
        {
            if (!_listeners.Remove(id) || _listeners.Count > 0) return;
            CancelCts(ref _lingerCts);
            linger = _lingerCts = new CancellationTokenSource();
        }
        var wait = Linger;
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(wait, linger.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            var shouldClose = false;
            lock (_gate)
            {
                if (ReferenceEquals(_lingerCts, linger) && _listeners.Count == 0)
                {
                    _lingerCts = null;
                    shouldClose = true;
                }
            }
            if (shouldClose) Post(Close);
        });
    }

    public void SetForeground(bool on)
    {
        bool start = false, stop = false;
        lock (_gate)
        {
            _foreground = on;
            if (on) start = _listeners.Count > 0;
            else stop = true;
        }
        if (start) Begin();
        else if (stop) Close();
    }

    public void Shutdown()
    {
        lock (_gate)
        {
            _shutDown = true;
            CancelCts(ref _lingerCts);
            _listeners.Clear();
        }
        Close();
        Rows = [];
    }

    public void LinkRestored()
    {
        IBrowserSocket? quiet = null;
        var dialNow = false;
        var forgetAndBegin = false;
        lock (_gate)
        {
            if (_shutDown || !_foreground || _listeners.Count == 0) return;
            if (_socket != null && ElapsedSinceInbound() > QuietOnRestore)
            {
                quiet = _socket;
            }
            else if (_socket == null && _workCts == null)
            {
                if (_retryCts != null)
                {
                    CancelCts(ref _retryCts);
                    _attempt = 0;
                    dialNow = true;
                }
                else forgetAndBegin = true;
            }
        }
        if (quiet != null)
        {
            Note("activity link restored: quiet socket replaced");
            quiet.Close();
            return;
        }
        if (dialNow)
        {
            Note("activity link restored: dialing now");
            Connect();
        }
        else if (forgetAndBegin)
        {
            if (_service.TryGetTarget(out var svc)) svc.ForgetPlugin();
            Begin();
        }
    }

    private void Begin()
    {
        lock (_gate)
        {
            if (_shutDown || !_foreground || _socket != null || _workCts != null) return;
            if (_retainedAt is { } at && DateTimeOffset.UtcNow - at > Retain) Rows = [];
            _retainedAt = null;
        }
        Connect();
    }

    private void Close()
    {
        var notify = false;
        lock (_gate)
        {
            _generation++;
            CancelCts(ref _retryCts);
            CancelCts(ref _watchdogCts);
            CancelCts(ref _workCts);
            _socket?.Close();
            _socket = null;
            if (Rows.Count > 0) _retainedAt = DateTimeOffset.UtcNow;
            _attempt = 0;
            if (Connected) { Connected = false; notify = true; }
        }
        if (notify) Publish();
    }

    private void Connect()
    {
        int mine;
        CancellationTokenSource cts;
        lock (_gate)
        {
            if (_shutDown || !_foreground) return;
            _generation++;
            mine = _generation;
            CancelCts(ref _workCts);
            cts = _workCts = new CancellationTokenSource();
        }
        _ = RunConnectAsync(mine, cts);
    }

    private async Task RunConnectAsync(int mine, CancellationTokenSource cts)
    {
        try
        {
            if (!_service.TryGetTarget(out var service)) return;
            var plugin = await service.PluginAsync(timeout: TimeSpan.FromSeconds(4), ct: cts.Token).ConfigureAwait(false);
            if (!IsCurrent(mine)) return;
            if (plugin.Setup != BrowserSetup.Ready)
            {
                lock (_gate) { if (_generation == mine) ClearWorkLocked(cts); }
                return;
            }
            var socket = await service.Gateway.PluginSocketAsync(plugin.Base + "/activity", [], maxBytes: 256_000, ct: cts.Token).ConfigureAwait(false);
            if (!IsCurrent(mine)) { socket.Close(); return; }
            lock (_gate)
            {
                if (_generation != mine) { socket.Close(); return; }
                _socket = socket;
                _lastInbound = System.Diagnostics.Stopwatch.GetTimestamp();
            }
            StartWatchdog(mine, socket);
            Note("activity socket open");
            while (!cts.IsCancellationRequested)
            {
                var text = await socket.ReceiveTextAsync(cts.Token).ConfigureAwait(false);
                if (!IsCurrent(mine)) return;
                if (text == null) break;
                Volatile.Write(ref _lastInbound, System.Diagnostics.Stopwatch.GetTimestamp());
                if (text.Length <= 256_000 && J.Parse(text) is { } parsed && BrowserRow.ParseList(parsed) is { } rows)
                {
                    lock (_gate)
                    {
                        if (_generation != mine) return;
                        _attempt = 0;
                        Rows = rows;
                        Connected = true;
                    }
                    Post(Publish);
                }
            }
            if (IsCurrent(mine)) Lost(mine);
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            if (!IsCurrent(mine)) return;
            if (BrowserService.IsMissing(e))
            {
                lock (_gate) { if (_generation == mine) ClearWorkLocked(cts); }
                return;
            }
            if (e is GatewayException { Status: 405 or >= 500 } && _service.TryGetTarget(out var svc))
                svc.ForgetPlugin();
            Note($"activity socket failed ({e.GetType().Name})");
            Lost(mine);
        }
    }

    private void StartWatchdog(int mine, IBrowserSocket socket)
    {
        CancellationTokenSource wd;
        lock (_gate)
        {
            CancelCts(ref _watchdogCts);
            wd = _watchdogCts = new CancellationTokenSource();
        }
        _ = Task.Run(async () =>
        {
            while (!wd.IsCancellationRequested)
            {
                try { await Task.Delay(WatchEvery, wd.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                if (!IsCurrent(mine)) return;
                if (ElapsedSinceInbound() > Silence)
                {
                    Note("activity socket silent: redialing");
                    socket.Close();
                    return;
                }
            }
        });
    }

    private void Lost(int mine)
    {
        var notify = false;
        double wait;
        CancellationTokenSource retry;
        lock (_gate)
        {
            if (_generation != mine || _shutDown) return;
            CancelCts(ref _watchdogCts);
            _socket?.Close();
            _socket = null;
            CancelCts(ref _workCts);
            if (Connected) { Connected = false; notify = true; }
            wait = Math.Min(10.0, Math.Pow(2.0, _attempt));
            _attempt++;
            CancelCts(ref _retryCts);
            retry = _retryCts = new CancellationTokenSource();
        }
        if (notify) Post(Publish);
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(TimeSpan.FromSeconds(wait), retry.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            var shouldReconnect = false;
            lock (_gate)
            {
                if (_generation == mine && !_shutDown && _listeners.Count > 0 && _foreground && ReferenceEquals(_retryCts, retry))
                {
                    _retryCts = null;
                    shouldReconnect = true;
                }
            }
            if (shouldReconnect) Connect();
        });
    }

    private void Publish()
    {
        Action[] snapshot;
        lock (_gate) snapshot = [.. _listeners.Values];
        foreach (var listener in snapshot) listener();
        OnRowsChanged?.Invoke();
    }

    private void Post(Action work)
    {
        if (_service.TryGetTarget(out var svc)) svc.Post(work);
        else work();
    }

    private void Note(string message)
    {
        if (_service.TryGetTarget(out var svc)) svc.Note?.Invoke(message);
    }

    private bool IsCurrent(int mine) { lock (_gate) return _generation == mine && !_shutDown; }

    private void ClearWorkLocked(CancellationTokenSource cts)
    {
        if (ReferenceEquals(_workCts, cts)) { _workCts.Dispose(); _workCts = null; }
    }

    private TimeSpan ElapsedSinceInbound() =>
        System.Diagnostics.Stopwatch.GetElapsedTime(Volatile.Read(ref _lastInbound));

    private static void CancelCts(ref CancellationTokenSource? cts)
    {
        if (cts == null) return;
        try { cts.Cancel(); } catch (ObjectDisposedException) { }
        try { cts.Dispose(); } catch (ObjectDisposedException) { }
        cts = null;
    }

    // Internal test seams matching Swift #if DEBUG accessors
    internal int DebugAttempt { get { lock (_gate) return _attempt; } }
    internal bool DebugRetrying { get { lock (_gate) return _retryCts != null; } }
    internal bool DebugDialing { get { lock (_gate) return _workCts != null; } }
    internal bool DebugOpen { get { lock (_gate) return _socket != null; } }
    internal int DebugListeners { get { lock (_gate) return _listeners.Count; } }

    internal void DebugPublish(IReadOnlyList<BrowserRow> rows, bool connected = true)
    {
        lock (_gate) { Rows = rows; Connected = connected; }
        Publish();
    }
}

/// Cancels an activity listener on Cancel or Dispose.
public sealed class BrowserSubscription(Action cancel) : IDisposable
{
    private Action? _cancel = cancel;

    public void Cancel()
    {
        Interlocked.Exchange(ref _cancel, null)?.Invoke();
    }

    public void Dispose() => Cancel();
}
