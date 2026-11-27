// [WIN-SCREEN-SESSION] One open Bot Screen (docs/spec/3x-screen.md §4), the C# twin of the Mac's
// HermesKit/Screen/ScreenSession.swift at 93f984bb1: the status, the attach (observe, reclaim, dial, stream), the lease
// calls, eviction, pause and resume, the Mac health poll and leaving. A port of the vendor pane's state
// (`screen-pane.tsx`, `screen-state.ts`) plus the phone's rules (`bot-screen-phone.tsx`); the view only draws it.
//
// The Mac's @MainActor is the SynchronizationContext the session is created on (the UI thread): every call into it is
// made there, its own work is posted there (Swift `Task {}`), and every await resumes there, so nothing in here locks.
// The gateway is IScreenRpc (`display.*` calls), the socket a dial behind IScreenSocket, the plugin's health an
// IScreenHealthReader. AppLog notes go to `Environment.Note` with the Swift strings. The CGImage is the framebuffer's
// BGRX snapshot (ScreenStream's picture). RPCError is GatewayException ("rpc" + RpcCode; "timeout" is isTimeout).

using System.Diagnostics;
using System.Text.Json.Nodes;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.Screen;

/// The `display.*` calls a Screen makes (the Swift `GatewayClient.call`). Errors are GatewayException.
public interface IScreenRpc
{
    Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default);
}

public sealed class ScreenSession
{
    public abstract record Conn
    {
        private Conn() { }
        public sealed record Idle : Conn;
        public sealed record Attaching : Conn;
        public sealed record Live : Conn;
        public sealed record Error(string Title, string? Detail) : Conn;
    }

    public enum Fallback { Unsupported, Unavailable, Blocked }

    /// What the viewer shows (S0–S7 of the spec).
    public abstract record Phase
    {
        private Phase() { }
        public sealed record Connecting : Phase;
        /// null: the status never arrived; else the failed call's message.
        public sealed record NoAnswer(string? Message) : Phase;
        public sealed record FallbackTo(Fallback Kind) : Phase;
        public sealed record Missing : Phase;
        public sealed record Off : Phase;
        public sealed record Attaching : Phase;
        public sealed record Live : Phase;
        public sealed record Ended(string Title, string? Detail) : Phase;
    }

    public enum Busy { Take, Give, Force, Start }

    /// One-shot moments the view answers with a pill, a haptic or an announcement.
    public enum Notice { ControlStarted, ControlEnded, ControlTaken, Live }

    public sealed record Timing
    {
        public TimeSpan StatusWait { get; init; } = TimeSpan.FromSeconds(20);
        public TimeSpan PauseDelay { get; init; } = TimeSpan.FromSeconds(1);
        public TimeSpan RetryDelay { get; init; } = TimeSpan.FromSeconds(1);
        public double FailureWindow { get; init; } = 10;
        public double EvictionWindow { get; init; } = 10;
        public int MaxEvictions { get; init; } = 3;
        public TimeSpan HealthEvery { get; init; } = TimeSpan.FromSeconds(15);
        public double StuckAfter { get; init; } = 8;
        /// How long a finished handshake may go without its first picture (the Mac helper sends none while it has none).
        public double FirstPictureWait { get; init; } = 20;
        public TimeSpan PingEvery { get; init; } = TimeSpan.FromSeconds(20);
        internal TimeProvider FlushClock { get; init; } = TimeProvider.System;
    }

    public sealed record Environment
    {
        public required IScreenRpc Client { get; init; }
        public required Func<string, string, CancellationToken, Task<IScreenSocket>> Dial { get; init; }
        public required ScreenHolds Holds { get; init; }
        public required IScreenHealthReader Health { get; init; }
        public required string AccountId { get; init; }
        public Timing Timing { get; init; } = new();
        public Func<double> Now { get; init; } = Uptime;
        /// DECISION D9: polls double their interval in Low Power Mode or under thermal pressure (Windows: battery saver).
        public Func<bool> Slow { get; init; } = () => false;
        /// What the service last knew of a bot's screen (its events and earlier Screens): a running one is attached
        /// at once on the first open.
        public Func<string, ScreenStatus?> CachedStatus { get; init; } = _ => null;
        /// AppLog.note("screen", …).
        public Action<string>? Note { get; init; }
    }

    private static readonly long Uptime0 = Stopwatch.GetTimestamp();
    private static double Uptime() => Stopwatch.GetElapsedTime(Uptime0).TotalSeconds;

    public const string StreamEnded = "Screen Stopped";
    public const string ControlTakenText = "Another viewer took control. Watching only.";
    public const string NoPictureMac = "The Mac hasn’t sent a picture yet";
    public const string NoPicture = "The screen hasn’t sent a picture yet";

    public string Profile { get; }
    public string Name { get; }
    private readonly Environment _env;
    private readonly SynchronizationContext? _main;
    private readonly int _mainThread;

    // What the view reads.
    public ScreenStatus? Status { get; private set; }
    public ScreenLease? Lease { get; private set; }
    public ScreenViewer? Viewer { get; private set; }
    public bool Unavailable { get; private set; }
    /// null: no failure. "": the status never arrived. Else the failed call's message.
    public string? StatusFailure { get; private set; }
    public Conn Connection { get; private set; } = new Conn.Idle();
    public MacScreen? Mac { get; private set; }
    /// The plugin's last health answer as sent (for "Check setup"); null before the first read or when it is missing.
    public JsonNode? Health { get; private set; }
    public string? ErrorLine { get; private set; }
    public Busy? BusyWith { get; private set; }
    public (int Width, int Height)? Framebuffer { get; private set; }
    public bool OnView { get; private set; } = true;
    public bool Left { get; private set; }

    public Action? OnChange { get; set; }
    public Action<byte[], int, int>? OnFrame { get; set; }
    public Action<Notice>? OnNotice { get; set; }
    /// The service's cache (the row menu's label reads it).
    public Action<ScreenSession>? Report { get; set; }

    private ScreenStream? _stream;
    // A pause can detach the stream while its final button-up is still being written.
    private Task _detachedWrites = Task.CompletedTask;
    private int _statusGeneration;
    private int _attachGeneration;
    private CancellationTokenSource? _statusTimer;
    private CancellationTokenSource? _retryTask;
    private CancellationTokenSource? _pauseTask;
    private CancellationTokenSource? _healthTask;
    private CancellationTokenSource? _typeTask;
    private double _dialedAt;
    private int _rapidEvictions;
    private double? _lastFailureAt;
    private bool _ticketRetried;
    private bool _autoRetry;
    private bool _wasHolding;
    private byte _mask;
    private (int X, int Y)? _pointer;
    private readonly ScreenTyper _typer = new();
    private int _typeToken;
    /// The first open went straight to observe on the service's cached status (once per session).
    private bool _seeded;
    /// The status shown is that cached one, not yet confirmed by the gateway.
    private bool _unverifiedSeed;

    /// Create it on the UI thread (its SynchronizationContext is the session's main actor) and call it only there.
    public ScreenSession(string profile, string name, Environment environment)
    {
        Profile = profile;
        Name = name;
        _env = environment;
        _main = SynchronizationContext.Current;
        _mainThread = System.Environment.CurrentManagedThreadId;
    }

    // Derived

    public bool Holding => ScreenWire.Holds(Lease, Viewer);
    /// A hold saved by an earlier run that the lease still names (§5.8): "You were in control".
    public SavedHold? Held => ScreenHolds.HeldBefore(_env.Holds.Saved(_env.AccountId, Profile), Lease, Viewer);
    public bool OtherHolds => Lease?.Holder == ScreenHolder.Human && !Holding && Held == null;
    public bool IsMac => Status?.IsMac == true;
    /// On a Mac, control needs the plugin's word that input is ready.
    public bool CanTake => !IsMac || Mac?.InputReady == true;
    public bool CanSendInput => Connection is Conn.Live && Holding && BusyWith != Busy.Give && _stream != null;
    public ScreenTone Tone => ScreenWire.Tone(Unavailable, StatusWithLease, Viewer);
    public string Label => ScreenWire.ScreenLabel(Status);
    public ScreenPacing Pacing => _stream?.Pacing ?? new ScreenPacing();

    /// A screen there is something to attach to.
    private bool CanAttach => Status is { } status && !Unavailable && status.Supported && status.Installed && status.Running;

    private ScreenStatus? StatusWithLease => Status is not { } status ? null : Lease is { } lease ? status with { Lease = lease } : status;

    public Phase CurrentPhase
    {
        get
        {
            if (Unavailable) return new Phase.FallbackTo(Fallback.Unavailable);
            if (Status is not { } status)
                return StatusFailure is { } failure ? new Phase.NoAnswer(failure.Length == 0 ? null : failure) : new Phase.Connecting();
            if (!status.Supported) return new Phase.FallbackTo(Fallback.Unsupported);
            if (!status.Installed) return new Phase.Missing();
            if (!status.Running) return status.Blocker == null ? new Phase.Off() : new Phase.FallbackTo(Fallback.Blocked);
            return Connection switch
            {
                Conn.Live => new Phase.Live(),
                Conn.Error e => new Phase.Ended(e.Title, e.Detail),
                _ => new Phase.Attaching(),
            };
        }
    }

    /// The control row's caption.
    public string Caption
    {
        get
        {
            if (Holding) return "You are in control";
            if (Held != null) return "You were in control";
            return Lease?.Holder == ScreenHolder.Human ? "Another viewer is in control" : $"{(Name.Length == 0 ? "The bot" : Name)} is in control";
        }
    }

    private void Note(string line) => _env.Note?.Invoke(line);

    /// Swift `Task { … }` on the main actor: queued to run after the current work, on the main context.
    private void Spawn(Func<Task> work)
    {
        if (_main != null) _main.Post(_ => _ = work(), null);
        else _ = Task.Run(work);
    }

    private static CancellationTokenSource? Cancel(CancellationTokenSource? task)
    {
        try { task?.Cancel(); } catch (ObjectDisposedException) { }
        return null;
    }

    /// `Task.sleep`, false when cancelled.
    private static async Task<bool> Sleep(TimeSpan delay, CancellationToken ct)
    {
        try { await Task.Delay(delay, ct); return !ct.IsCancellationRequested; }
        catch (OperationCanceledException) { return false; }
    }

    // Status

    /// Reads the bot's status (every open, Retry, Check Again, and the resume signals while there is none).
    public void Open()
    {
        if (Left) return;
        // [perf] First open of a screen the service already saw running: observe at once (its answer carries the
        // status), one gateway round trip fewer. A stale cache falls back to this status read (RunAttach's catch).
        if (!_seeded && Status == null && StatusFailure == null && !Unavailable && _env.CachedStatus(Profile) is { } seed
            && seed.Supported && seed.Installed && seed.Running)
        {
            _seeded = true;
            _statusGeneration++;
            _statusTimer = Cancel(_statusTimer);
            _unverifiedSeed = true;
            Note("open on the known status");
            Apply(seed);
            AfterStatus();
            return;
        }
        _seeded = true;
        _statusGeneration++;
        var token = _statusGeneration;
        StatusFailure = null;
        Changed();
        Cancel(_statusTimer);
        var wait = _env.Timing.StatusWait;
        var timer = new CancellationTokenSource();
        _statusTimer = timer;
        Spawn(async () =>
        {
            if (!await Sleep(wait, timer.Token)) return;
            if (token != _statusGeneration || Status != null || Unavailable || StatusFailure != null) return;
            Note("status never arrived");
            StatusFailure = "";
            Changed();
        });
        Spawn(() => ReadStatus(token));
    }

    /// A quiet re-read (after a stream ends, while the fallback is on view): a failure changes nothing.
    public void Refresh()
    {
        if (Left) return;
        _statusGeneration++;
        var token = _statusGeneration;
        Spawn(() => ReadStatus(token, quiet: true));
    }

    private async Task ReadStatus(int token, bool quiet = false)
    {
        try
        {
            var value = await _env.Client.CallAsync("display.status", ScreenWire.ProfileParams(Profile), ScreenWire.StatusTimeout);
            if (token != _statusGeneration || Left) return;
            if (ScreenStatus.Parse(value) is not { } parsed)
            {
                if (!quiet && Status == null) StatusFailure = "The gateway’s answer could not be read";
                Changed();
                return;
            }
            Unavailable = false;
            StatusFailure = null;
            _statusTimer = Cancel(_statusTimer);
            _unverifiedSeed = false;
            Apply(parsed);
            AfterStatus();
        }
        catch (Exception error)
        {
            if (token != _statusGeneration || Left || IsCancellation(error)) return;
            if (ScreenWire.IsUnavailable(error))
            {
                Note("unavailable");
                _statusTimer = Cancel(_statusTimer);
                Unavailable = true;
                Status = null;
                Lease = null;
                Viewer = null;
                StatusFailure = null;
                Detach();
                Connection = new Conn.Idle();
            }
            else if (!quiet && Status == null && !Unavailable)
            {
                _statusTimer = Cancel(_statusTimer);
                // The request's own 20 s limit and the 20 s wait are the same event: "never arrived", in those words.
                StatusFailure = error is GatewayException { Code: "timeout" } ? "" : ScreenWire.Message(error);
            }
            Changed();
        }
    }

    /// Swift `error is CancellationError` (a GatewayException "timeout" is not one).
    private static bool IsCancellation(Exception error) => error is OperationCanceledException;

    /// A status from an event or a call's own result: newer than any request still in flight.
    private void ApplyAuthoritative(ScreenStatus next)
    {
        _statusGeneration++;
        _unverifiedSeed = false;
        Unavailable = false;
        StatusFailure = null;
        _statusTimer = Cancel(_statusTimer);
        Apply(next);
    }

    private void Apply(ScreenStatus next)
    {
        Status = next;
        if (next.Lease is { } fresh && !fresh.IsOlder(Lease)) Lease = fresh;
        Framebuffer ??= ScreenWire.Size(next.Geometry);
    }

    private void ApplyLease(ScreenLease next)
    {
        if (next.IsOlder(Lease)) return;
        Lease = next;
    }

    /// What a new status means for the stream and the health poll.
    private void AfterStatus()
    {
        if (CanAttach)
        {
            if (Connection is Conn.Idle && OnView && _retryTask == null) Attach(auto: true);
        }
        else
        {
            Detach();
            Connection = new Conn.Idle();
        }
        SyncHealth();
        Changed();
    }

    // Events (forwarded by the service)

    /// A `display.status` or `display.lease` frame (`type`, `payload`).
    /// `about` is the bot the service worked the event out to be about (Hermes' `profile_key` is a home path, so a
    /// Screen that has no status yet cannot tell by the key alone).
    public void Handle(string type, JsonNode? payload, string? about = null)
    {
        if (Left) return;
        var key = ScreenJson.Str(payload, "profile_key");
        var named = about ?? ScreenJson.Str(payload, "profile");
        if (!(named == Profile || (key != null && (key == Status?.ProfileKey || key == Profile)))) return;
        switch (type)
        {
            case "display.status":
                if (ScreenStatus.Parse(payload) is not { } parsed) return;
                ApplyAuthoritative(parsed);
                AfterStatus();
                if (IsMac && OnView) Spawn(ReadHealth);      // a helper change is often why it was sent
                break;
            case "display.lease":
                if (ScreenLease.Parse(payload?["lease"]) is not { } next) return;
                ApplyLease(next);
                Changed();
                break;
        }
    }

    /// The gateway connection is ready again after anything else: viewer ids belonged to the old connection.
    public void GatewayReconnected()
    {
        if (Left) return;
        Note("gateway back");
        if (Status == null)
        {
            if (!Unavailable) Open();
            return;
        }
        if (!OnView || !CanAttach) return;
        Attach(auto: true, signal: true);
    }

    /// The app came to the front or the network returned: a stream that is not live attaches again.
    public void ResumeSignal()
    {
        if (Left || !OnView) return;
        if (Status == null && !Unavailable)
        {
            Open();
            return;
        }
        SyncHealth();
        if (!CanAttach || Connection is Conn.Live || Connection is Conn.Attaching) return;
        Attach(auto: true, signal: true);
    }

    // Attach

    /// "Reconnect".
    public void Reconnect() => Attach(auto: false);

    private void Attach(bool auto, bool signal = false)
    {
        if (Left || !OnView || !CanAttach) return;
        if (!auto || signal)
        {
            _rapidEvictions = 0;
            _lastFailureAt = signal ? _lastFailureAt : null;
            _ticketRetried = false;
        }
        if (!auto) _autoRetry = false;
        _retryTask = Cancel(_retryTask);
        var prior = Viewer;
        Detach();
        var generation = _attachGeneration;
        Connection = new Conn.Attaching();
        Note("attach");
        Changed();
        Spawn(() => RunAttach(generation, prior));
    }

    private async Task RunAttach(int generation, ScreenViewer? prior)
    {
        try
        {
            var value = await _env.Client.CallAsync("display.observe", ScreenWire.ObserveParams(Profile, prior?.Id), ScreenWire.ObserveTimeout);
            if (generation != _attachGeneration || Left) return;
            var observed = ScreenObserved.Parse(value)
                ?? throw new GatewayException("rpc", "The gateway’s answer could not be read.", rpcCode: 5300);
            var wasSeed = _unverifiedSeed;
            ApplyAuthoritative(observed.Status);
            // Opened on a cached status that is out of date: the screen's own page, no stream.
            if (wasSeed && !CanAttach) { AfterStatus(); return; }
            var minted = observed.Viewer;
            Viewer = minted;
            Changed();
            // §5.8: the lease still names an id this app held on the old connection. Look again, then take it with
            // the new id.
            if (ScreenHolds.ShouldReclaim(prior, minted, Lease, _env.Holds.Own(_env.AccountId, Profile)))
            {
                var fresh = await Try(() => _env.Client.CallAsync("display.status", ScreenWire.ProfileParams(Profile), ScreenWire.StatusTimeout));
                if (generation != _attachGeneration || Left) return;
                if (fresh != null && ScreenStatus.Parse(fresh) is { } recheck)
                {
                    ApplyAuthoritative(recheck);
                    if (ScreenHolds.ShouldReclaim(prior, minted, Lease, _env.Holds.Own(_env.AccountId, Profile)))
                    {
                        var got = await Try(() => _env.Client.CallAsync("display.lease.acquire",
                            ScreenWire.AcquireParams(Profile, minted.Id), ScreenWire.LeaseTimeout));
                        if (Left)
                        {
                            // Closed while the acquire ran: do not leave the new id holding.
                            if (got != null) Release(minted.Id, forget: true);
                            return;
                        }
                        if (ScreenLease.Parse(got?["lease"]) is { } next)
                        {
                            Note("lease reclaimed");
                            ApplyLease(next);
                        }
                        Changed();
                        if (generation != _attachGeneration) return;
                    }
                }
            }
            var socket = await _env.Dial(observed.Path, observed.Ticket, CancellationToken.None);
            if (generation != _attachGeneration || Left)
            {
                socket.Close(handBack: false);
                return;
            }
            _dialedAt = _env.Now();
            var timing = _env.Timing;
            var stream = new ScreenStream(socket,
                onReady: (width, height) => StreamReady(generation, width, height),
                onFrame: (image, width, height, _) => StreamFrame(generation, image, width, height),
                onEnd: end => StreamEndedWith(generation, end),
                stuckAfter: timing.StuckAfter, firstPictureWait: timing.FirstPictureWait, pingEvery: timing.PingEvery, now: _env.Now,
                onMain: OnMain, isMain: () => System.Environment.CurrentManagedThreadId == _mainThread, note: _env.Note)
                { FlushClock = timing.FlushClock };
            _stream = stream;
            stream.Start();
        }
        catch (Exception error)
        {
            if (generation != _attachGeneration || Left || IsCancellation(error)) return;
            if (_unverifiedSeed)
            {
                // The cached status was stale (the screen was turned off, the gateway lost it): no "stream ended"
                // page, just the status read every other open makes.
                Note("known status was stale: reading it");
                _unverifiedSeed = false;
                Status = null;
                Framebuffer = null;
                Connection = new Conn.Idle();
                Open();
                return;
            }
            Note("attach failed");
            var auto = _autoRetry;
            _autoRetry = false;
            Connection = new Conn.Error(StreamEnded, auto ? null : ScreenWire.Sentence(ScreenWire.Message(error)));
            Changed();
            Refresh();
        }
    }

    /// Swift `try?`: the value, or null on any failure.
    private static async Task<JsonNode?> Try(Func<Task<JsonNode>> call)
    {
        try { return await call(); }
        catch (Exception) { return null; }
    }

    /// The stream's callbacks run here, on the main context.
    private Task OnMain(Action action)
    {
        if (_main == null) { action(); return Task.CompletedTask; }
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _main.Post(_ => { try { action(); } finally { done.TrySetResult(); } }, null);
        return done.Task;
    }

    private void StreamReady(int generation, int width, int height)
    {
        if (generation != _attachGeneration || Left) return;
        _ticketRetried = false;                       // this ticket was taken: a later one gets its own second try
        Framebuffer = (width, height);
        Changed();
    }

    private void StreamFrame(int generation, byte[] image, int width, int height)
    {
        if (generation != _attachGeneration || Left) return;
        if (Framebuffer?.Width != width || Framebuffer?.Height != height)
        {
            Framebuffer = (width, height);
            _pointer = _pointer is { } p ? (Math.Min(p.X, width - 1), Math.Min(p.Y, height - 1)) : null;
            if (Connection is Conn.Live) Changed();
        }
        OnFrame?.Invoke(image, width, height);
        if (Connection is Conn.Live) return;
        Connection = new Conn.Live();
        _autoRetry = false;
        Note("live");
        // DECISION D14: a button a dropped link left down is released before anything else is sent.
        if (Holding) ClearButtons();
        OnNotice?.Invoke(Notice.Live);
        Changed();
    }

    private void StreamEndedWith(int generation, ScreenStreamEnd end)
    {
        if (generation != _attachGeneration || Left) return;
        _stream = null;
        _mask = 0;
        StopTyping();
        int? code = null;
        var reason = "";
        if (end is ScreenStreamEnd.Closed closed)
        {
            code = closed.Code;
            reason = closed.Reason ?? "";
        }
        Note($"close {(code is { } c ? c.ToString(System.Globalization.CultureInfo.InvariantCulture) : "none")}");
        if (end is ScreenStreamEnd.NoPicture)
        {
            // The socket was fine and the handshake finished: trying again by itself would only wait the same 20 s.
            // Say why instead of the bare "Screen Stopped" (the web's viewer just sat there under its notes).
            _retryTask = Cancel(_retryTask);
            _lastFailureAt = null;
            _autoRetry = false;
            Connection = new Conn.Error(IsMac ? NoPictureMac : NoPicture, IsMac ? NoPictureReason(Health) : null);
            Changed();
            Refresh();
            if (IsMac) Spawn(ReadHealth);           // the reason may be newer than the last poll
            return;
        }
        if (code == ScreenWire.Close.ControlTaken || reason.Contains("control-taken", StringComparison.Ordinal))
        {
            var now = _env.Now();
            _rapidEvictions = now - _dialedAt < _env.Timing.EvictionWindow ? _rapidEvictions + 1 : 1;
            OnNotice?.Invoke(Notice.ControlTaken);
            if (_rapidEvictions > _env.Timing.MaxEvictions)
            {
                Connection = new Conn.Error(ControlTakenText, null);
            }
            else
            {
                Connection = new Conn.Idle();
                Attach(auto: true);
            }
        }
        else if (code == ScreenWire.Close.Ticket)
        {
            if (_ticketRetried)
            {
                // The fresh ticket was refused too: say so. No third try by itself (the stress run counted three).
                _retryTask = Cancel(_retryTask);
                _lastFailureAt = null;
                _autoRetry = false;
                Connection = new Conn.Error(StreamEnded, null);
            }
            else
            {
                _ticketRetried = true;              // a spent or expired ticket: observe again, once
                Connection = new Conn.Idle();
                Attach(auto: true);
            }
        }
        else if (code == ScreenWire.Close.NotRunning)
        {
            // The status read below says what is true now (off, or running again). Twice inside the window is a
            // gateway that says both: stop and ask for a tap.
            var now = _env.Now();
            _retryTask = Cancel(_retryTask);
            if (_lastFailureAt is { } last && now - last < _env.Timing.FailureWindow)
            {
                _lastFailureAt = null;
                Connection = new Conn.Error(StreamEnded, null);
            }
            else
            {
                _lastFailureAt = now;
                Connection = new Conn.Idle();
            }
        }
        else
        {
            UnexpectedEnd();
        }
        Changed();
        Refresh();
    }

    /// Why a Mac that answered has no picture to send, from the helper's own health (the web's readiness wording).
    public static string? NoPictureReason(JsonNode? health)
    {
        var helper = health?["helper"];
        if (ScreenJson.Bool(helper, "paused") == true) return "Resume sharing from Hermes HQ Screen’s menu on the Mac.";
        if (ScreenJson.Str(helper, "capture_error") is { } raw && ScreenWire.Plain(raw) is { Length: > 0 } capture) return ScreenWire.Sentence(capture);
        if (ScreenJson.Bool(helper?["tcc"], "screen") == false) return "Allow Screen Recording for Hermes HQ Screen on the Mac.";
        if (ScreenJson.Bool(helper, "locked") == true) return $"The Mac is locked, and its display may be asleep. Wake it, then {DeviceWord.Tap} Reconnect.";
        return $"Its display may be asleep. Wake the Mac, then {DeviceWord.Tap} Reconnect.";
    }

    /// DECISION D11: one quiet re-attach after a second; a second failure inside the window asks for a tap.
    private void UnexpectedEnd()
    {
        var now = _env.Now();
        if (_lastFailureAt is { } last && now - last < _env.Timing.FailureWindow)
        {
            _lastFailureAt = null;
            _autoRetry = false;
            Connection = new Conn.Error(StreamEnded, null);
            return;
        }
        _lastFailureAt = now;
        Connection = new Conn.Attaching();
        _autoRetry = true;
        var delay = _env.Timing.RetryDelay;
        Cancel(_retryTask);
        var retry = new CancellationTokenSource();
        _retryTask = retry;
        Spawn(async () =>
        {
            if (!await Sleep(delay, retry.Token)) return;
            if (_retryTask == retry) _retryTask = null;
            if (!OnView || !CanAttach)
            {
                Connection = new Conn.Idle();
                Changed();
                return;
            }
            Attach(auto: true);
        });
    }

    /// Ends the current attach without handing the lease back.
    private void Detach()
    {
        _attachGeneration++;
        StopTyping();
        if (_stream is { } stream)
        {
            stream.Stop(handBack: false, flush: ReleaseMessages());
            if (Holding) _detachedWrites = Task.WhenAll(_detachedWrites, stream.WritesEnded);
            _stream = null;
        }
        _mask = 0;
    }

    // On view (§5.11)

    /// The viewer went out of view (`immediately` for the background, else after a second if still away) or came back.
    public void SetOnView(bool visible, bool immediately = false)
    {
        if (Left) return;
        _pauseTask = Cancel(_pauseTask);
        if (visible)
        {
            // Already in view (the first appearance, or a look away shorter than the pause): nothing to resume. A
            // signal here re-attached a stream that had just ended in words (the stress run saw the refused-ticket
            // page try twice more when the viewer finished appearing).
            if (OnView) return;
            OnView = true;
            Note("resume");
            ResumeSignal();
            return;
        }
        if (!OnView) return;
        if (immediately)
        {
            Pause();
            return;
        }
        var delay = _env.Timing.PauseDelay;
        var pause = new CancellationTokenSource();
        _pauseTask = pause;
        Spawn(async () =>
        {
            if (!await Sleep(delay, pause.Token)) return;
            if (_pauseTask == pause) _pauseTask = null;
            Pause();
        });
    }

    private void Pause()
    {
        if (!OnView || Left) return;
        OnView = false;
        Note("pause");
        _retryTask = Cancel(_retryTask);
        _autoRetry = false;
        Detach();                                   // a plain cancel: the lease is kept, as for a dropped link
        if (Connection is not Conn.Idle && CanAttach && !IsError) Connection = new Conn.Idle();
        _healthTask = Cancel(_healthTask);
        Changed();
    }

    private bool IsError => Connection is Conn.Error;

    // Calls

    public void Start()
    {
        if (Left || BusyWith != null) return;
        BusyWith = Busy.Start;
        Changed();
        Spawn(async () =>
        {
            try
            {
                var value = await _env.Client.CallAsync("display.start", ScreenWire.ProfileParams(Profile), ScreenWire.StartTimeout);
                if (Left) return;
                BusyWith = null;
                ErrorLine = null;
                if (ScreenStatus.Parse(value) is { } parsed)
                {
                    ApplyAuthoritative(parsed);
                    Connection = new Conn.Idle();
                    AfterStatus();
                }
                else
                {
                    Changed();
                    Refresh();
                }
            }
            catch (Exception error)
            {
                Fail(error);
            }
        });
    }

    /// "Take over" and "Resume control".
    public void TakeOver()
    {
        if (Left || BusyWith != null || Viewer is not { } viewer || !CanTake) return;
        LeaseCall(Busy.Take, ScreenWire.AcquireParams(Profile, viewer.Id), "display.lease.acquire", session =>
        {
            if (session.Connection is not Conn.Live && session.Connection is not Conn.Attaching) session.Attach(auto: false);
        });
    }

    /// "Hand back": this attach's hold, or a hold this phone lost track of (released by its saved id).
    public void HandBack()
    {
        if (Left || BusyWith != null) return;
        if (Holding && Viewer is { } viewer)
        {
            var drained = ReleaseButtons();
            LeaseCall(Busy.Give, ScreenWire.ReleaseParams(Profile, viewer.Id, force: false), "display.lease.release", drain: drained);
        }
        else if (Held is { } held)
        {
            LeaseCall(Busy.Give, ScreenWire.ReleaseParams(Profile, held.Id, force: true), "display.lease.release",
                session => session._env.Holds.Forget(session._env.AccountId, session.Profile), drain: _detachedWrites);
        }
    }

    /// "Hand back (force)": returns another viewer's control to the bot.
    public void ForceHandBack()
    {
        if (Left || BusyWith != null) return;
        LeaseCall(Busy.Force, ScreenWire.ReleaseParams(Profile, null, force: true), "display.lease.release");
    }

    private void LeaseCall(Busy kind, JsonObject parameters, string method, Action<ScreenSession>? then = null, Task? drain = null)
    {
        var viewer = Viewer;
        var holder = Lease?.ViewerHash; // the current viewer or this app's saved id, checked by HandBack
        BusyWith = kind;
        Changed();
        Spawn(async () =>
        {
            try
            {
                if (drain != null)
                {
                    await drain;
                    if (Left) return; // Leave owns the close and hand-back now
                    if (Viewer != viewer || Lease is not { Holder: ScreenHolder.Human } lease || lease.ViewerHash != holder)
                    {
                        BusyWith = null;
                        Changed();
                        return;
                    }
                }
                var value = await _env.Client.CallAsync(method, parameters, ScreenWire.LeaseTimeout);
                if (Left) return;
                BusyWith = null;
                ErrorLine = null;                       // a call that worked clears an earlier failure
                if (ScreenLease.Parse(value["lease"]) is { } next) ApplyLease(next);
                Note(Holding ? "lease mine" : "lease changed");
                then?.Invoke(this);
                Changed();
            }
            catch (Exception error)
            {
                Fail(error);
            }
        });
    }

    private void Fail(Exception error)
    {
        if (Left) return;
        BusyWith = null;
        if (!IsCancellation(error)) ErrorLine = ScreenWire.Message(error);
        Changed();
    }

    public void DismissError()
    {
        if (ErrorLine == null) return;
        ErrorLine = null;
        Changed();
    }

    // Input (accepted only while this viewer holds the lease and the stream is live)

    /// A pointer message at a framebuffer pixel. The position is remembered for the next button change.
    public void SendPointer(byte mask, int x, int y)
    {
        if (BusyWith == Busy.Give) return; // keep the last admitted pointer position throughout the hand-back
        _pointer = (x, y);
        if (!CanSendInput || _stream is not { } stream) return;
        _mask = (byte)(mask & 0b0000_0111);             // wheel bits are momentary
        stream.Send(RfbMessage.Pointer(mask, x, y));
    }

    public void SendKeys(IEnumerable<byte[]> messages)
    {
        if (!CanSendInput || _stream is not { } stream) return;
        foreach (var message in messages) stream.Send(message);
    }

    /// Text typed key by key, 500 characters per turn of the run loop (DECISION D18); stops when control ends.
    public void Type(string text, IReadOnlyCollection<ScreenKeys.Modifier>? mods = null)
    {
        if (!CanSendInput || text.Length == 0) return;
        _typer.Add(text, mods ?? []);
        if (_typeTask != null) return;
        _typeToken++;
        var token = _typeToken;
        var task = new CancellationTokenSource();
        _typeTask = task;
        Spawn(async () =>
        {
            while (!task.IsCancellationRequested && token == _typeToken && CanSendInput && !_typer.IsEmpty)
            {
                SendKeys(_typer.Next());
                await Task.Yield();
            }
            if (token != _typeToken) return;
            StopTyping();
        });
    }

    /// Text still waiting to be typed is dropped (hand back, control lost, the stream closing).
    private void StopTyping()
    {
        _typeToken++;
        _typeTask = Cancel(_typeTask);
        _typer.Cancel();
    }

    /// Characters still waiting to be typed (a long paste in progress).
    public int TypingBacklog => _typer.Count;

    /// Paste: false when there is nothing to paste (the view says "There’s no text to paste.").
    public bool Paste(string? text)
    {
        switch (ScreenKeys.Paste(text, IsMac))
        {
            case ScreenPaste.Empty: return false;
            case ScreenPaste.Clipboard clipboard: SendKeys(clipboard.Messages); break;
            case ScreenPaste.Typed typed: Type(typed.Text); break;
        }
        return true;
    }

    private List<byte[]> ReleaseMessages()
    {
        if (_mask == 0 || !Holding || (_pointer ?? Centre) is not { } at) return [];
        return [RfbMessage.Pointer(0, at.X, at.Y)];
    }

    private (int X, int Y)? Centre => Framebuffer is { } fb ? (fb.Width / 2, fb.Height / 2) : null;

    /// DECISION D14: button-up for a held pointer button before control is given away.
    private Task ReleaseButtons()
    {
        StopTyping();
        foreach (var message in ReleaseMessages()) _stream?.Send(message);
        _mask = 0;
        // Fence even a zero mask: the last pointer-up from the view may itself still be queued.
        return _stream is { } stream ? Task.WhenAll(_detachedWrites, stream.DrainBeforeHandBack()) : _detachedWrites;
    }

    private void ClearButtons()
    {
        if (!CanSendInput || _stream is not { } stream || (_pointer ?? Centre) is not { } at) return;
        _mask = 0;
        stream.Send(RfbMessage.Pointer(0, at.X, at.Y));
    }

    // Mac health (§5.10)

    private void SyncHealth()
    {
        if (!IsMac || !OnView || Left)
        {
            _healthTask = Cancel(_healthTask);
            return;
        }
        if (_healthTask != null) return;
        var every = _env.Timing.HealthEvery;
        var task = new CancellationTokenSource();
        _healthTask = task;
        Spawn(async () =>
        {
            while (!task.IsCancellationRequested)
            {
                await ReadHealth();
                if (Left) return;
                if (!await Sleep(_env.Slow() ? every * 2 : every, task.Token)) return;
            }
        });
    }

    private async Task ReadHealth()
    {
        JsonNode? value;
        try { value = await _env.Health.ReadAsync(); }
        catch (Exception) { return; }                         // a failed read keeps the last value
        if (Left) return;
        var parsed = MacScreen.Parse(value);
        var same = parsed == Mac && JsonNode.DeepEquals(value, Health);
        Health = value;
        Mac = parsed;
        // "The Mac hasn’t sent a picture yet" says why in the helper's newest words.
        if (Connection is Conn.Error { Title: NoPictureMac } error && error.Detail != NoPictureReason(value))
        {
            Connection = new Conn.Error(NoPictureMac, NoPictureReason(value));
            Changed();
            return;
        }
        if (!same) Changed();
    }

    // Leaving (§5.8, §6.2)

    /// Close, and whatever sign-out or an account switch did not hand back first. Never waits on the network.
    public void Leave()
    {
        if (Depart() is not var (action, stream, flush)) return;
        switch (action)
        {
            case ScreenLeave.CloseHandsBack:
                // The close frame 1000 hands the lease back. Nothing says here that it arrived, so the saved hold is not
                // forgotten on faith (review finding 2): the gateway's `display.lease` event forgets it (ScreenService),
                // or the next visit's status does; if neither comes, the next visit offers "You were in control".
                stream?.Stop(handBack: true, flush: flush);
                _env.Holds.ClearOwn(_env.AccountId, Profile);          // this run does not take it back silently
                break;
            case ScreenLeave.Release release:
                stream?.Stop(handBack: false, flush: flush);
                Release(release.Id, forget: true);
                break;
            default:
                stream?.Stop(handBack: false);
                break;
        }
    }

    /// Sign-out and gateway switch, called while the client can still ask: leaves as `Leave()` does and waits (at most
    /// about two seconds) for the gateway's own word that the bot has control again. Without that word the saved
    /// hold is kept, so the next launch offers Resume control / Hand back. `ct` is the caller's limit (Swift's task
    /// cancellation).
    public async Task LeaveConfirming(TimeSpan? wait = null, CancellationToken ct = default)
    {
        var limit = wait ?? TimeSpan.FromMilliseconds(1500);
        var viewerId = Viewer?.Id;
        if (Depart() is not var (action, stream, flush)) return;
        switch (action)
        {
            case ScreenLeave.CloseHandsBack:
                _env.Holds.ClearOwn(_env.AccountId, Profile);
                if (stream != null) await stream.StopAndWait(handBack: true, flush: flush);     // the button-up, then the close frame, in order
                if (viewerId != null) await ConfirmReleased(viewerId, limit, ct);
                break;
            case ScreenLeave.Release release:
                stream?.Stop(handBack: false, flush: flush);
                await ConfirmReleased(release.Id, limit, ct);
                break;
            default:
                stream?.Stop(handBack: false);
                break;
        }
    }

    /// Everything `Leave` does but the stream's close and the lease. null: already left.
    private (ScreenLeave, ScreenStream?, List<byte[]>)? Depart()
    {
        if (Left) return null;
        var action = ScreenHolds.Leave(Holding, _stream != null && Connection is Conn.Live, Viewer, _env.Holds.Saved(_env.AccountId, Profile));
        var flush = action is ScreenLeave.Nothing ? [] : ReleaseMessages();
        Left = true;
        Note("leave");
        foreach (var task in new[] { _statusTimer, _retryTask, _pauseTask, _healthTask }) Cancel(task);
        _attachGeneration++;
        StopTyping();
        var stream = _stream;
        _stream = null;
        OnChange = null;
        OnFrame = null;
        OnNotice = null;
        return (action, stream, flush);
    }

    /// `display.lease.release {viewer_id, force}` answers with the lease as it now is (it is not an error when the
    /// close frame already gave it back). Only that answer forgets the hold.
    private async Task ConfirmReleased(string id, TimeSpan wait, CancellationToken ct)
    {
        var hash = ScreenWire.ViewerHash(id);
        JsonNode? value;
        try
        {
            await _detachedWrites.WaitAsync(ct);
            value = await _env.Client.CallAsync("display.lease.release", ScreenWire.ReleaseParams(Profile, id, force: true), wait, ct);
        }
        catch (Exception) { value = null; }
        if (ScreenLease.Parse(value?["lease"]) is not { } lease || (lease.Holder == ScreenHolder.Human && lease.ViewerHash == hash))
        {
            Note("hand-back not confirmed");
            return;
        }
        var holds = _env.Holds;
        var account = _env.AccountId;
        if (holds.Saved(account, Profile)?.Id == id) holds.Forget(account, Profile);
        if (holds.Own(account, Profile)?.Id == id) holds.ClearOwn(account, Profile);
    }

    /// `display.lease.release {viewer_id, force}` in a task that outlives the viewer (bounded by the call's 10 s).
    /// Offline, nothing is forgotten: the next launch offers the hold again.
    private void Release(string id, bool forget)
    {
        var client = _env.Client;
        var holds = _env.Holds;
        var account = _env.AccountId;
        var profile = Profile;
        var drained = _detachedWrites;
        Spawn(async () =>
        {
            await drained;
            try { await client.CallAsync("display.lease.release", ScreenWire.ReleaseParams(profile, id, force: true), ScreenWire.LeaseTimeout); }
            catch (Exception) { return; }
            if (forget)
            {
                if (holds.Saved(account, profile)?.Id == id) holds.Forget(account, profile);
                if (holds.Own(account, profile)?.Id == id) holds.ClearOwn(account, profile);
            }
        });
    }

    // Bookkeeping

    private void Changed()
    {
        if (Left) return;
        _env.Holds.Note(Lease, Viewer, _env.AccountId, Profile);
        var now = Holding;
        if (now != _wasHolding)
        {
            _wasHolding = now;
            if (now)
            {
                if (Connection is Conn.Live) ClearButtons();
                OnNotice?.Invoke(Notice.ControlStarted);
            }
            else
            {
                _mask = 0;
                StopTyping();
                OnNotice?.Invoke(Notice.ControlEnded);
            }
        }
        Report?.Invoke(this);
        OnChange?.Invoke();
    }
}
