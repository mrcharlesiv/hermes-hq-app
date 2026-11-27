// [WIN-SCREEN-SESSION] The Mac's Tests/Screen/FakeDisplay.swift at 93f984bb1: a gateway's display side for ScreenSession
// tests: the lease rules of Hermes (ids minted per /api/ws connection, holder named by hash, epochs, 5300 refusals,
// force release), scripted failures, and display sockets the test ends by hand. Also the SessionRig, whose sessions run
// on a MainLoop (the Mac's main actor; MainLoop.cs) and come from the real ScreenService ([WIN-SCREEN-SERVICE]; it
// replaced the session slice's stand-in), as the Swift rig's do.

using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Hermes.Core.Composer;
using Hermes.Core.Net;
using Hermes.Core.Rpc;
using Hermes.Core.Screen;
using static Hermes.Core.Tests.Screen.ScreenWaits;

namespace Hermes.Core.Tests.Screen;

internal sealed record FakeCall(string Method, JsonObject Params)
{
    public List<string> Keys => Params.Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal).ToList();
    public string? Str(string key) => Params[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
    public bool? Bool(string key) => Params[key] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;
}

internal sealed class FakeDisplay : IScreenGateway
{
    public sealed class State
    {
        public bool Supported = true;
        public bool Installed = true;
        public bool Running = true;
        public string Display = "This Mac";
        public string Geometry = "64x48";
        public string? Blocker;
        public string? InstallCommand;
        public string Placement = "gateway";
        public string Holder = "agent";
        public string? Hash;
        public int Epoch = 1;
        public int Connection = 1;
        public Dictionary<string, int> Minted = [];
        public Dictionary<string, string> Tickets = [];
        public int Counter;
        public Dictionary<string, Exception> Fail = [];
        public HashSet<string> Hang = [];
        public Dictionary<string, TimeSpan> Delay = [];
        /// One-shot at RPC entry, before the gateway model changes its lease or returns a reply.
        public Dictionary<string, Func<CancellationToken, Task>> AtCall = [];
        public bool DialFails;
        public bool Pictures = true;
        public List<FakeScreenSocket> Sockets = [];
        public List<string> SocketViewers = [];
        /// Runs once inside the next call of that method, before it answers (to change the world mid-flight).
        public Dictionary<string, Action<State>> Before = [];
    }

    public const string HealthPath = "/api/plugins/hermes-hq-screen/health";
    /// As Hermes sends it: the profile's home path (hermes_home_key), never its name.
    public const string HomeKey = "/fixture/home";
    /// A Mac whose helper is set up: viewing and control ready.
    public const string Healthy = """{"installed":true,"ok":true,"platform":"darwin","drift":[],"enabled":true,"control":true,"helper":{"ok":true,"tcc":{"screen":true,"events":true}}}""";

    private readonly object _gate = new();
    private readonly State _state = new();
    private readonly List<FakeCall> _calls = [];
    private readonly List<string> _restLog = [];
    private Func<string?> _rest = () => Healthy;
    private readonly List<(IReadOnlySet<string> Types, Action<string, JsonNode?> Handler)> _eventSinks = [];
    private readonly List<Action<ConnectionState>> _stateSinks = [];
    private ConnectionState _connectionState = ConnectionState.Open;

    public string Account => "account-fixture";
    public string AccountId => Account;
    /// The event types someone is subscribed to now (the Swift `events(matching:)`).
    public List<string> SubscribedTypes { get { lock (_gate) return _eventSinks.SelectMany(s => s.Types).ToList(); } }
    public int StateSubscribers { get { lock (_gate) return _stateSinks.Count; } }

    public IDisposable Events(IReadOnlySet<string> types, Action<string, JsonNode?> handler)
    {
        var sink = (types, handler);
        lock (_gate) _eventSinks.Add(sink);
        return new Unsubscribe(() => { lock (_gate) _eventSinks.Remove(sink); });
    }

    /// Yields the current state first, as the Swift `connectionStates()` does.
    public IDisposable ConnectionStates(Action<ConnectionState> handler)
    {
        ConnectionState current;
        lock (_gate)
        {
            _stateSinks.Add(handler);
            current = _connectionState;
        }
        handler(current);
        return new Unsubscribe(() => { lock (_gate) _stateSinks.Remove(handler); });
    }

    private sealed class Unsubscribe(Action stop) : IDisposable
    {
        private int _done;
        public void Dispose() { if (Interlocked.Exchange(ref _done, 1) == 0) stop(); }
    }

    /// The gateway's event, as it arrives off the wire, to every subscriber of its type.
    private void Publish(string type, JsonObject payload)
    {
        List<Action<string, JsonNode?>> sinks;
        lock (_gate) sinks = _eventSinks.Where(s => s.Types.Contains(type)).Select(s => s.Handler).ToList();
        foreach (var sink in sinks) sink(type, Wire(payload));
    }

    private void SetConnection(ConnectionState state)
    {
        List<Action<ConnectionState>> sinks;
        lock (_gate)
        {
            _connectionState = state;
            sinks = [.. _stateSinks];
        }
        foreach (var sink in sinks) sink(state);
    }

    public void Set(Action<State> change) { lock (_gate) change(_state); }
    public List<FakeScreenSocket> Sockets { get { lock (_gate) return [.. _state.Sockets]; } }
    public (string Holder, string? Hash, int Epoch) Lease { get { lock (_gate) return (_state.Holder, _state.Hash, _state.Epoch); } }
    public List<FakeCall> Calls(string method) { lock (_gate) return _calls.Where(c => c.Method == method).ToList(); }
    public List<string> Methods { get { lock (_gate) return _calls.Select(c => c.Method).ToList(); } }
    public List<string> RestLog { get { lock (_gate) return [.. _restLog]; } }
    /// The health route's answer: JSON text, null for a 404 (no plugin), or a throw.
    public void OnRest(Func<string?> answer) { lock (_gate) _rest = answer; }

    /// Another person takes control: the lease changes, the holder's socket is evicted with 4000, the event goes out.
    public void OtherTakes()
    {
        FakeScreenSocket? evicted = null;
        JsonObject payload;
        lock (_gate)
        {
            var s = _state;
            var previous = s.Hash;
            s.Holder = "human";
            s.Hash = ScreenWire.ViewerHash($"someone-else-{s.Epoch}");
            s.Epoch += 1;
            if (previous != null)
            {
                var index = s.SocketViewers.FindLastIndex(v => ScreenWire.ViewerHash(v) == previous);
                if (index >= 0) evicted = s.Sockets[index];
            }
            payload = new JsonObject { ["profile_key"] = HomeKey, ["lease"] = LeaseJson(s) };
        }
        evicted?.End(4000, "control-taken");
        Publish("display.lease", payload);
    }

    /// The bot takes control back by itself.
    public void AgentTakes()
    {
        JsonObject payload;
        lock (_gate)
        {
            _state.Holder = "agent";
            _state.Hash = null;
            _state.Epoch += 1;
            payload = new JsonObject { ["profile_key"] = HomeKey, ["lease"] = LeaseJson(_state) };
        }
        Publish("display.lease", payload);
    }

    public void EmitStatus()
    {
        JsonObject payload;
        lock (_gate) payload = StatusJson(_state);
        Publish("display.status", payload);
    }

    public void Emit(string type, JsonObject payload) => Publish(type, payload);

    /// The app's /api/ws drops and comes back as a new connection.
    public void ReconnectGateway()
    {
        SetConnection(ConnectionState.Connecting);
        lock (_gate) _state.Connection += 1;
        SetConnection(ConnectionState.Open);
    }

    // The display socket

    public Task<IScreenSocket> Dial(string path, string ticket, CancellationToken ct)
    {
        FakeScreenSocket socket;
        bool pictures;
        (int W, int H) size;
        lock (_gate)
        {
            var s = _state;
            if (s.DialFails || path != ScreenWire.DisplayPath || !s.Tickets.Remove(ticket, out var viewer))
                throw new IOException("Could not connect to the server.");
            socket = new FakeScreenSocket();
            s.Sockets.Add(socket);
            s.SocketViewers.Add(viewer);
            pictures = s.Pictures;
            size = ScreenWire.Size(s.Geometry) ?? (64, 48);
        }
        if (pictures) Picture(socket, size.W, size.H);
        return Task.FromResult<IScreenSocket>(socket);
    }

    /// The handshake and one whole picture.
    public static void Picture(FakeScreenSocket socket, int width, int height)
    {
        socket.Push(RfbBuild.Preamble(width, height));
        socket.Push(RfbBuild.Update([RfbBuild.Raw(0, 0, width, height, b: 40, g: 80, r: 120)]));
    }

    // The calls

    private static JsonObject LeaseJson(State s) => new()
    {
        ["holder"] = s.Holder, ["viewer_id"] = null, ["viewer_hash"] = s.Hash, ["since"] = 1_791_700_000, ["epoch"] = s.Epoch, ["reason"] = "",
    };

    private static JsonObject StatusJson(State s) => new()
    {
        ["profile"] = "default", ["profile_key"] = HomeKey, ["supported"] = s.Supported, ["installed"] = s.Installed, ["missing"] = new JsonArray(),
        ["running"] = s.Running, ["display"] = s.Display, ["geometry"] = s.Geometry,
        ["install_command"] = s.InstallCommand, ["blocker"] = s.Blocker, ["placement"] = s.Placement, ["lease"] = LeaseJson(s),
    };

    /// As it arrives off the wire (JSON text read back), never the CLR values it was built from.
    private static JsonNode Wire(JsonNode node) => JsonNode.Parse(node.ToJsonString())!;

    public static GatewayException Rpc(long code, string message) => new("rpc", message, rpcCode: code);
    public static GatewayException TimedOut() => new("timeout", "The gateway took too long to answer.");

    public async Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default)
    {
        bool hang;
        TimeSpan? delay;
        Func<CancellationToken, Task>? atCall;
        lock (_gate)
        {
            _calls.Add(new FakeCall(method, (JsonObject)parameters.DeepClone()));
            _state.AtCall.Remove(method, out atCall);
            hang = _state.Hang.Contains(method);
            delay = _state.Delay.TryGetValue(method, out var d) ? d : null;
        }
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(timeout);
        try
        {
            if (atCall != null) await atCall(limit.Token);
            if (hang) await Task.Delay(TimeSpan.FromSeconds(600), limit.Token).ConfigureAwait(false);
            if (delay is { } wait) await Task.Delay(wait, limit.Token).ConfigureAwait(false);
            else await Task.Yield();
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw TimedOut();
        }
        JsonNode answer;
        lock (_gate) answer = Answer(method, parameters);
        return Wire(answer);
    }

    private JsonNode Answer(string method, JsonObject parameters)
    {
        var s = _state;
        if (s.Before.Remove(method, out var hook)) hook(s);
        if (s.Fail.TryGetValue(method, out var error)) throw error;
        var viewer = parameters["viewer_id"] is JsonValue v && v.TryGetValue<string>(out var id0) ? id0 : null;
        switch (method)
        {
            case "display.status":
                return StatusJson(s);
            case "display.start":
                s.Running = true;
                return StatusJson(s);
            case "display.observe":
            {
                if (!s.Running) throw Rpc(5300, "this profile's Bot Desktop is not running; call display.start first");
                var id = viewer;
                if (id == null || s.Minted.GetValueOrDefault(id) != s.Connection)
                {
                    s.Counter += 1;
                    id = $"viewer-{s.Counter}-{Guid.NewGuid().ToString("N")[..8]}";       // opaque and never reused, as Hermes mints them
                    s.Minted[id] = s.Connection;
                }
                s.Counter += 1;
                var ticket = $"ticket-{s.Counter}";
                s.Tickets[ticket] = id;
                var out_ = StatusJson(s);
                out_["ticket"] = ticket;
                out_["path"] = ScreenWire.DisplayPath;
                out_["viewer_id"] = id;
                return out_;
            }
            case "display.lease.acquire":
                if (viewer == null) throw Rpc(5300, "viewer_id required");
                if (s.Minted.GetValueOrDefault(viewer) != s.Connection)
                    throw Rpc(5300, "viewer_id was not minted for this connection; call display.observe first");
                s.Holder = "human";
                s.Hash = ScreenWire.ViewerHash(viewer);
                s.Epoch += 1;
                return new JsonObject { ["lease"] = LeaseJson(s) };
            case "display.lease.release":
            {
                var force = parameters["force"] is JsonValue f && f.TryGetValue<bool>(out var b) && b;
                if (viewer != null)
                {
                    if (force)
                    {
                        // Released only while that id still holds: someone who took control meanwhile keeps it.
                        if (s.Holder == "human" && s.Hash == ScreenWire.ViewerHash(viewer))
                        {
                            s.Holder = "agent";
                            s.Hash = null;
                            s.Epoch += 1;
                        }
                    }
                    else
                    {
                        if (s.Minted.GetValueOrDefault(viewer) != s.Connection || s.Holder != "human" || s.Hash != ScreenWire.ViewerHash(viewer))
                            throw Rpc(5300, "another viewer holds control");
                        s.Holder = "agent";
                        s.Hash = null;
                        s.Epoch += 1;
                    }
                }
                else if (force)
                {
                    s.Holder = "agent";
                    s.Hash = null;
                    s.Epoch += 1;
                }
                else if (s.Holder == "human")
                {
                    throw Rpc(5300, "a person holds control");
                }
                return new JsonObject { ["lease"] = LeaseJson(s) };
            }
            default:
                throw Rpc(-32601, "Method not found");
        }
    }

    // The plugin's health route (the Swift fake client's REST)

    public async Task<string> RestAsync(string method, string path, CancellationToken ct = default)
    {
        Func<string?> answer;
        lock (_gate)
        {
            _restLog.Add(path);
            answer = _rest;
        }
        await Task.Yield();
        ct.ThrowIfCancellationRequested();
        return answer() ?? throw new GatewayException("http", "The gateway answered 404.", 404);     // null: no plugin route
    }

    // The same REST with a query (ScreenService.Expiry's folder listings), logged as its path.
    public Task<string> RestAsync(string method, string path, IReadOnlyList<KeyValuePair<string, string>> query, CancellationToken ct = default) =>
        RestAsync(method, path, ct);
}

/// A session wired to a `FakeDisplay`, with what it told its view. Every read and call goes through the main loop.
internal sealed class SessionRig : IDisposable
{
    public FakeDisplay Display { get; } = new();
    public FakeUptime Clock { get; } = new();
    public MemoryStore Defaults { get; }
    public ScreenHolds Holds { get; }
    public ScreenService Service { get; private set; } = null!;
    public MainLoop Main { get; }
    private ScreenSession _session = null!;
    private readonly List<ScreenSession.Notice> _notices = [];
    private int _frames;
    private readonly List<ScreenSession.Phase> _phases = [];

    /// `pauseDelay`: the look-away pause, 150 ms unless a test needs the shipping second (see AShortLookAway…).
    public SessionRig(MemoryStore? defaults = null, TimeSpan? pauseDelay = null, TimeProvider? flushClock = null)
    {
        Main = new MainLoop();
        Defaults = defaults ?? new MemoryStore();
        Holds = new ScreenHolds(Defaults);
        var display = Display;
        var clock = Clock;
        Main.Run(() =>
        {
            // Made on the main loop: its events and sessions run there, as the Mac's do on the main actor.
            Service = new ScreenService(display, display.Dial, Holds)
            {
                Timing = new ScreenSession.Timing
                {
                    StatusWait = TimeSpan.FromMilliseconds(300), PauseDelay = pauseDelay ?? TimeSpan.FromMilliseconds(150),
                    RetryDelay = TimeSpan.FromMilliseconds(40), HealthEvery = TimeSpan.FromMilliseconds(250),
                    FlushClock = flushClock ?? TimeProvider.System,
                },
                Now = () => clock.Now,
            };
            _session = Service.Session("default", "Hermes");
        });
        Wire();
    }

    /// A second Screen on the same service (after Close, or another bot).
    public void Reopen(string profile = "default")
    {
        Main.Run(() =>
        {
            _session = Service.Session(profile, "Hermes");
            _notices.Clear();
            _phases.Clear();
        });
        Wire();
    }

    private void Wire() => Main.Run(() =>
    {
        var session = _session;
        session.OnNotice = n => _notices.Add(n);
        session.OnFrame = (_, _, _) => _frames++;
        session.OnChange = () =>
        {
            var phase = session.CurrentPhase;
            if (_phases.Count == 0 || _phases[^1] != phase) _phases.Add(phase);
        };
    });

    public T Get<T>(Func<ScreenSession, T> read) => Main.Read(() => read(_session));
    public void Do(Action<ScreenSession> act) => Main.Run(() => act(_session));
    public ScreenSession Session => Main.Read(() => _session);
    public ScreenSession.Phase Phase => Get(s => s.CurrentPhase);
    public List<ScreenSession.Notice> Notices => Main.Read(() => _notices.ToList());
    public int Frames => Main.Read(() => _frames);
    public List<ScreenSession.Phase> Phases => Main.Read(() => _phases.ToList());

    public FakeScreenSocket? Socket => Display.Sockets.LastOrDefault();
    public string Account => Display.Account;

    public Task<bool> Live(double seconds = 10) => ScreenWait(() => Phase is ScreenSession.Phase.Live, seconds);

    /// Opens and waits for the picture.
    public Task<bool> OpenLive()
    {
        Do(s => s.Open());
        return Live();
    }

    public async Task<bool> TakeOver()
    {
        if (!await ScreenWait(() => Get(s => s.CanTake))) return false;
        Do(s => s.TakeOver());
        return await ScreenWait(() => Get(s => s.Holding && s.BusyWith == null));
    }

    public Task HandBackBeforeLeaving(TimeSpan? limit = null) => Main.RunAsync(() => Service.HandBackBeforeLeavingAsync(limit));

    public Task<string> CheckSetup(string profile) => Main.RunAsync(() => Service.CheckSetupAsync(profile));

    /// Pointer and key messages a socket received, as readable tuples.
    public static List<string> Inputs(FakeScreenSocket? socket) => (socket?.Inputs ?? []).Select(b => b[0] switch
    {
        5 when b.Length == 6 => $"pointer {b[1]} {(b[2] << 8) | b[3]},{(b[4] << 8) | b[5]}",
        4 when b.Length == 8 => $"key {((uint)b[4] << 24 | (uint)b[5] << 16 | (uint)b[6] << 8 | b[7]).ToString("x", System.Globalization.CultureInfo.InvariantCulture)} {(b[1] == 1 ? "down" : "up")}",
        6 => $"cut {b.Length - 8}",
        _ => "other",
    }).ToList();

    public void Dispose()
    {
        try { Main.Run(() => { if (!_session.Left) _session.Leave(); Service.Shutdown(); }); } catch (Exception) { }
        Main.Dispose();
        Assert.Empty(Main.Failures);
    }
}
