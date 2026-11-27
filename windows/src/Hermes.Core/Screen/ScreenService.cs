// [WIN-SCREEN-SERVICE] The account's Bot Screen service (docs/spec/3x-screen.md §3.1, §5.1, §5.4), the C# twin of the
// Mac's HermesKit/Screen/ScreenService.swift at 93f984bb1: what is known about each bot's screen (for the row menu's
// label), the `display.status` / `display.lease` event pump, the open Screens (so sign-out can leave them), and the Mac
// health reader. One per signed-in account, like BrowserService.
//
// The Mac's @MainActor is the SynchronizationContext the service is created on (the UI thread), as for ScreenSession:
// make it there and call it only there. The gateway's events and connection states may arrive on any thread; they are
// posted to that context (the Swift pump's `Task` on the main actor). The gateway is IScreenGateway; the live app
// hands in `ClientScreenGateway` and `ScreenDialer.For(session)` (`ScreenService.For`).
//
// The Swift's `expiry` (ScreenshotExpiry, whether the gateway still has a step's screenshot) is `Expiry`
// ([WIN-SCREEN-SHOT-FEED], ToolScreenshots.cs), made on first use with no profile as the Swift `lazy var` is.

using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Screen;

/// What a ScreenService asks of its gateway (the Swift `GatewayClient` as the service uses it): `display.*` calls, the
/// plugin's health route, the account, the gateway's events of some types and its connection states.
public interface IScreenGateway : IScreenRpc, IScreenRest, IScreenshotRest
{
    string AccountId { get; }

    /// The gateway's events whose type is in `types` (the Swift `events(matching:)`), on any thread, until disposed.
    IDisposable Events(IReadOnlySet<string> types, Action<string, JsonNode?> handler);

    /// The connection's states, the current one first (the Swift `connectionStates()`), on any thread, until disposed.
    IDisposable ConnectionStates(Action<ConnectionState> handler);
}

/// The signed-in gateway as a ScreenService reads it.
public sealed class ClientScreenGateway(HermesClient client) : IScreenGateway, IScreenshotGateway
{
    public HermesClient Client { get; } = client;
    public string AccountId => Client.AccountId;

    public Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default) =>
        Client.Rpc.RequestAsync(method, parameters, timeout, ct);

    public async Task<string> RestAsync(string method, string path, CancellationToken ct = default)
    {
        var answer = await Client.Session.SendAsync(new HttpMethod(method), path, null, null, null, ct: ct);
        if (!answer.Ok) throw GatewaySession.HttpError(answer);
        return answer.Body;
    }

    public async Task<string> RestAsync(string method, string path, IReadOnlyList<KeyValuePair<string, string>> query, CancellationToken ct = default)
    {
        var answer = await Client.Session.SendAsync(new HttpMethod(method), path, query, null, null, ct: ct);
        if (!answer.Ok) throw GatewaySession.HttpError(answer);
        return answer.Body;
    }

    public IDisposable RpcEvents(IReadOnlySet<string> types, Action<RpcEvent> handler)
    {
        Action<RpcEvent> sink = e => { if (types.Contains(e.Type)) handler(e); };
        Client.Rpc.Event += sink;
        return new Subscription(() => Client.Rpc.Event -= sink);
    }

    public IDisposable Events(IReadOnlySet<string> types, Action<string, JsonNode?> handler)
    {
        Action<RpcEvent> sink = e => { if (types.Contains(e.Type)) handler(e.Type, e.Payload); };
        Client.Rpc.Event += sink;
        return new Subscription(() => Client.Rpc.Event -= sink);
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

public sealed class ScreenService
{
    private sealed class Known
    {
        public ScreenStatus? Status;
        public ScreenLease? Lease;
        public ScreenViewer? Viewer;
        public bool Unavailable;
    }

    /// The events the pump reads.
    public static readonly IReadOnlySet<string> EventTypes = new HashSet<string>(StringComparer.Ordinal) { "display.status", "display.lease" };

    public IScreenGateway Client { get; }
    public ScreenHolds Holds { get; }
    public MacScreenHealthReader Health { get; }
    /// Whether the gateway still has a step's screenshot (the Swift `private(set) lazy var expiry`).
    public ScreenshotExpiry Expiry => _expiry ??= new ScreenshotExpiry(Client, null);
    private ScreenshotExpiry? _expiry;
    public ScreenSession.Timing Timing { get; set; } = new();
    /// The clock the eviction and failure windows read (tests move it by hand). null: the session's own uptime.
    public Func<double>? Now { get; set; }
    /// DECISION D9 for the sessions' polls (Windows: battery saver).
    public Func<bool> Slow { get; set; } = () => false;
    /// AppLog.note("screen", …).
    public Action<string>? Note { get; set; }

    private readonly Func<string, string, CancellationToken, Task<IScreenSocket>> _dial;
    private readonly SynchronizationContext? _main;
    private readonly Dictionary<string, Known> _known = [];
    /// Hermes names a screen in its events by `profile_key`, the profile's home PATH on the gateway (hermes_home_key),
    /// and a `display.lease` event carries nothing else. The menu asks by the bot's NAME, so every status that says
    /// both teaches this map which name a path belongs to.
    private readonly Dictionary<string, string> _profileForKey = [];
    private readonly List<WeakReference<ScreenSession>> _open = [];
    private readonly IDisposable _pump;
    private readonly IDisposable _states;
    private ConnectionState? _lastState;
    private bool _stopped;

    /// What is known about a bot's screen changed: Bot Info's Screen row, open under a Screen, reads it again (the
    /// Swift `ScreenService.knownChanged` notification).
    public event Action? KnownChanged;

    /// Make it on the UI thread: its SynchronizationContext is the service's (and its sessions') main actor.
    public ScreenService(IScreenGateway client, Func<string, string, CancellationToken, Task<IScreenSocket>> dial, ScreenHolds holds)
    {
        Client = client;
        Holds = holds;
        _dial = dial;
        _main = SynchronizationContext.Current;
        Health = new MacScreenHealthReader(client);
        _pump = client.Events(EventTypes, (type, payload) => OnMain(() => HandleEvent(type, payload)));
        _states = client.ConnectionStates(state => OnMain(() => HandleState(state)));
    }

    /// The live client's own display socket.
    public static ScreenService For(HermesClient client, ScreenHolds holds) =>
        new(new ClientScreenGateway(client), ScreenDialer.For(client.Session), holds);

    public string AccountId => Client.AccountId;

    private void OnMain(Action work)
    {
        if (_main == null) work();
        else _main.Post(_ => work(), null);
    }

    private List<ScreenSession> Sessions
    {
        get
        {
            _open.RemoveAll(w => !w.TryGetTarget(out _));
            return _open.Select(w => w.TryGetTarget(out var s) ? s : null).OfType<ScreenSession>().ToList();
        }
    }

    /// Whether a Screen is open right now (the viewer's own check; one at a time).
    public bool HasOpenSession => Sessions.Count > 0;

    // What the menu reads

    public ScreenTone Tone(string profile)
    {
        if (!_known.TryGetValue(profile, out var entry)) return ScreenTone.Unknown;
        var status = entry.Status;
        if (entry.Lease is { } lease && status != null) status = status with { Lease = lease };
        return ScreenWire.Tone(entry.Unavailable, status, entry.Viewer);
    }

    /// The kind of Screen a bot has, by what is known, else by what its gateway gave last (§5.4).
    public ScreenKind Kind(string profile)
    {
        var (kind, remember) = ScreenWire.Kind(Tone(profile), Holds.RememberedKind(AccountId));
        if (remember is { } r) Holds.RememberKind(r, AccountId);
        return kind;
    }

    public ScreenStatus? Status(string profile) => _known.TryGetValue(profile, out var entry) ? entry.Status : null;

    private void SetKnown(string profile, Known entry)
    {
        _known[profile] = entry;
        KnownChanged?.Invoke();
    }

    // Sessions

    public ScreenSession Session(string profile, string name)
    {
        var environment = new ScreenSession.Environment
        {
            Client = Client, Dial = _dial, Holds = Holds, Health = Health, AccountId = AccountId, Timing = Timing, Slow = Slow, Note = Note,
            CachedStatus = p =>
            {
                if (!_known.TryGetValue(p, out var entry) || entry.Unavailable || entry.Status is not { } status) return null;
                return entry.Lease is { } lease ? status with { Lease = lease } : status;
            },
        };
        if (Now is { } now) environment = environment with { Now = now };
        var session = new ScreenSession(profile, name, environment) { Report = NoteSession };
        _open.Add(new WeakReference<ScreenSession>(session));
        return session;
    }

    private void NoteSession(ScreenSession session)
    {
        if (_stopped) return;
        var entry = _known.GetValueOrDefault(session.Profile) ?? new Known();
        if (session.Unavailable)
        {
            entry = new Known { Unavailable = true };
        }
        else if (session.Status is { } status)
        {
            entry.Status = status;
            entry.Lease = session.Lease;
            entry.Viewer = session.Viewer;
            entry.Unavailable = false;
        }
        SetKnown(session.Profile, entry);
        if (session.Status?.ProfileKey is { Length: > 0 } key) _profileForKey[key] = session.Profile;     // the surest pairing
        if (session.Unavailable || session.Status != null) _ = Kind(session.Profile);                    // remembered for the gateway
    }

    /// The bot an event is about, by name. A pairing learned from an open Screen wins; then the status's own `profile`
    /// ("custom" is Hermes' word for a home it cannot name); then a home under `…/profiles/<name>`; then a key that is
    /// not a path at all (an older gateway). null: nobody here can say whose screen it is, and the event is dropped.
    public string? ProfileName(JsonNode? payload)
    {
        var key = ScreenJson.Str(payload, "profile_key") ?? "";
        if (_profileForKey.TryGetValue(key, out var learned)) return learned;
        if (ScreenJson.Str(payload, "profile") is { Length: > 0 } name && name != "custom")
        {
            if (key.Length > 0) _profileForKey[key] = name;
            return name;
        }
        if (key.Length == 0) return null;
        if (!key.Contains('/') && !key.Contains('\\')) return key;
        var parts = key.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length >= 2 && parts[^2] == "profiles")
        {
            _profileForKey[key] = parts[^1];
            return parts[^1];
        }
        return null;
    }

    private void HandleEvent(string type, JsonNode? payload)
    {
        if (_stopped || !EventTypes.Contains(type)) return;
        var name = ProfileName(payload);
        if (name != null)
        {
            var entry = _known.GetValueOrDefault(name) ?? new Known();
            if (type == "display.status" && ScreenStatus.Parse(payload) is { } status)
            {
                entry.Status = status;
                if (status.Lease is { } lease && !lease.IsOlder(entry.Lease)) entry.Lease = lease;
                entry.Unavailable = false;
                SetKnown(name, entry);
            }
            else if (type == "display.lease" && ScreenLease.Parse(payload is JsonObject o ? o["lease"] : null) is { } lease && !lease.IsOlder(entry.Lease))
            {
                entry.Lease = lease;
                SetKnown(name, entry);
            }
            // A hold this phone saved is over once the gateway says the bot (or someone else) has control: a Screen
            // that was closed while in control leaves its hold saved until this word arrives.
            if (_known.GetValueOrDefault(name)?.Lease is { } known && !Sessions.Any(s => s.Profile == name && !s.Left))
                Holds.Note(known, null, AccountId, name);
        }
        foreach (var session in Sessions) session.Handle(type, payload, name);
    }

    /// A new /api/ws connection (ready again after anything else, never the first state): every open Screen re-checks
    /// its viewer id and control.
    private void HandleState(ConnectionState state)
    {
        var earlier = _lastState;
        _lastState = state;
        if (_stopped || state != ConnectionState.Open || earlier is not { } was || was == ConnectionState.Open) return;
        foreach (var session in Sessions) session.GatewayReconnected();
    }

    // Check setup (§5.13)

    /// The plugin's health and the bot's status, read together, as the one line "Check setup" shows. Throws when the
    /// gateway cannot be reached (a missing plugin route is not a failure).
    public async Task<string> CheckSetupAsync(string profile)
    {
        var health = Health.ReadAsync();
        var status = Client.CallAsync("display.status", ScreenWire.ProfileParams(profile), ScreenWire.StatusTimeout);
        try { await Task.WhenAll((Task)health, status); }
        catch (Exception) { }                                   // both are read to the end; each failure is judged below
        var healthValue = await health;
        ScreenStatus? parsed = null;
        try { parsed = ScreenStatus.Parse(await status); }
        catch (Exception e) when (ScreenWire.IsUnavailable(e)) { }
        return MacScreenReadiness.Message(healthValue, parsed);
    }

    // Leaving

    /// Sign-out and gateway switch call this first, while the client can still ask: every open Screen leaves, and one
    /// that holds control waits for the gateway's word that the bot has it back (in all at most `limit`, 2 s). A hold
    /// whose hand-back was not confirmed stays saved for the next launch. Returns at once when no Screen is open.
    public async Task HandBackBeforeLeavingAsync(TimeSpan? limit = null)
    {
        var leaving = Sessions.Where(s => !s.Left).ToList();
        if (leaving.Count == 0) return;
        using var clock = new CancellationTokenSource(limit ?? TimeSpan.FromSeconds(2));
        foreach (var session in leaving) await session.LeaveConfirming(ct: clock.Token);         // one Screen is open at a time
    }

    /// Sign-out and account switch: every open Screen leaves by the rules of §5.8, and nothing more is read.
    public void Shutdown()
    {
        if (_stopped) return;
        _stopped = true;
        foreach (var session in Sessions) session.Leave();
        _open.Clear();
        _pump.Dispose();
        _states.Dispose();
    }
}
