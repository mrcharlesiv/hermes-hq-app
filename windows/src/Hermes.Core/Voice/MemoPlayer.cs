using System.Globalization;
using Hermes.Core.Composer;
using Hermes.Core.Net;

namespace Hermes.Core.Voice;

// [WIN-VOICE-PLAYER] One memo plays at a time, app-wide (spec 1x-voice §6.4, V3/V4; HermesKit/Voice/MemoPlayer.swift at
// 93f984bb1). A memo plays from a local file (a gateway memo is downloaded whole first, MemoPlaybackCache.FetchAsync),
// rate 1×/1.5×/2× remembered app-wide (D3). The audio session is taken on Play and given back on pause, end,
// interruption, unplugged headphones, media services resetting, the screen leaving and the app leaving the screen, so
// other apps' audio resumes. No background playback (V14).
//
// The Mac's player is @MainActor: here it is one-thread. It is built on the app's UI thread (or given that thread's
// SynchronizationContext) and every public member is called there; its awaits come back there, and callbacks from the
// audio output and the system (any thread) are posted to it, as the Mac's `queue: .main` / `DispatchQueue.main.async`.
// The app holds one MemoPlayer (the Mac's `static let shared`, Swift line 21).
//
// Seams (the Swift line each replaces):
//   IMemoAudioOutput.OpenAsync   lines 94-98   `AudioWork.run { AVAudioPlayer(contentsOf:); enableRate; prepareToPlay }`
//   IMemoAudioTrack              AVAudioPlayer: duration, currentTime (64-66, 77, 108, 154, 168-169, 237), rate (50, 134),
//                                play() (135), pause() (153), stop() (201); its delegate (103, 199) is the Finished and
//                                DecodeError events (213-232)
//   IMemoAudioSession            AudioSessionCoordinator.shared for `.memoPlayback`: onPlaybackPreempted (127),
//                                acquire (132), release (156, 206, 240), reset (262)
//   IMemoSystemEvents            the four NotificationCenter observers (246-269): AVAudioSession interruption (began
//                                only), routeChange (.oldDeviceUnavailable only), mediaServicesWereReset and
//                                UIApplication.didEnterBackground
//   IKeyValueStore               UserDefaults.standard for `hq.voice.memoSpeed` (45, 49)
//   Changed event                NotificationCenter `hq.memo.player.changed` with userInfo `path` (23-24, 272)
// Not ported: line 105, the DEBUG Simulator's silent speaker (`EngineSpeechOutput.silent`), a Mac test switch.
// The Windows output (MediaPlayer / AudioGraph behind IMemoAudioOutput, the system media events behind
// IMemoSystemEvents) is the next slice; Core has none.

/// Memo files that couldn't be fetched or played this launch ("Couldn’t load audio · Retry"); the row builder reads it
/// on any thread (Swift lines 11-17, a Mutex'd set).
public static class MemoLoadFailures
{
    private static readonly HashSet<string> Paths = [];

    public static bool Contains(string path) { lock (Paths) return Paths.Contains(path); }
    public static bool Insert(string path) { lock (Paths) return Paths.Add(path); }
    public static bool Remove(string path) { lock (Paths) return Paths.Remove(path); }
}

/// The `resolve` closures the Mac's callers hand the player: local file vs gateway fetch.
public static class MemoResolve
{
    /// A recording on this PC (the review and the draft chip: ChatVoiceHost.swift:464, MemoDraftChip.swift:125).
    /// A file that's gone is a 404.
    public static Func<Task<string>> LocalFile(string path) => () => File.Exists(path)
        ? Task.FromResult(path)
        : Task.FromException<string>(new GatewayException("http", "HTTP 404", 404, "missing"));

    /// A chat's memo (MemoBubbleContent.swift:285, `MemoPlaybackContexts.resolver`): the recording itself, a cached
    /// copy, or a download through the chat's gateway. A gateway error marks the memo failed. Await it on the player's
    /// thread (the player does).
    public static Func<Task<string>> Through(MemoAccountStores stores, string path, string? profile, IMemoGateway? client,
        MemoPlayer player) => async () =>
    {
        if (stores.Cache is not { } cache) throw new GatewayException("http", "HTTP 401", 401, "signed out");
        if (cache.Local(path) is { } local) return local;
        if (client == null) throw new GatewayException("http", "HTTP 503", 503, "no gateway");
        try
        {
            var file = await cache.FetchAsync(path, profile, client);
            // An account switch while it downloaded: the file belongs to the account that left.
            if (!ReferenceEquals(stores.Cache, cache)) throw new OperationCanceledException();
            return file;
        }
        catch (GatewayException)
        {
            player.MarkFailed(path);
            throw;
        }
    };
}

public enum MemoPlayState { Idle, Loading, Playing, Paused }

/// One opened, primed memo file (the Mac's AVAudioPlayer). Members are called on the player's thread; the events may
/// be raised on any thread.
public interface IMemoAudioTrack
{
    /// Seconds.
    double Duration { get; }
    /// Seconds played; settable (seek).
    double CurrentTime { get; set; }
    /// Playback rate (rate is enabled when the track is opened).
    double Rate { get; set; }
    /// Starts or resumes; false when it won't play.
    bool Play();
    void Pause();
    void Stop();
    /// audioPlayerDidFinishPlaying(_:successfully:): the track that finished and whether it did so successfully.
    event Action<IMemoAudioTrack, bool>? Finished;
    /// audioPlayerDecodeErrorDidOccur(_:error:): the track that failed.
    event Action<IMemoAudioTrack>? DecodeError;
}

/// Opens memo files (the Mac builds and primes AVAudioPlayer on the audio queue, never on the main thread: A-P1).
public interface IMemoAudioOutput
{
    /// Opens and primes `file` off the UI thread; throws when it isn't playable audio.
    Task<IMemoAudioTrack> OpenAsync(string file);
}

/// The audio session as memo playback holds it (AudioSessionCoordinator's `.memoPlayback` owner).
public interface IMemoAudioSession
{
    /// Called when another owner takes the session from memo playback (recording starts): the player pauses.
    Action? PlaybackPreempted { get; set; }
    /// Takes the session for playback; throws when it can't be had (a call, another app holding it).
    Task AcquireAsync();
    /// Gives it back (others' audio resumes).
    void Release();
    /// Media services were reset: forget who held it.
    void Reset();
}

/// What the system says about audio and the app (raised on any thread).
public enum MemoSystemEvent
{
    InterruptionBegan,
    InterruptionEnded,
    /// A route change whose reason is "old device unavailable" (headphones out).
    OldDeviceUnavailable,
    /// Any other route change.
    RouteChanged,
    MediaServicesReset,
    EnteredBackground,
}

public interface IMemoSystemEvents
{
    event Action<MemoSystemEvent>? Raised;
}

public sealed class MemoPlayer
{
    /// The Mac's notification name and its userInfo key (the Changed event here).
    public const string DidChangeName = "hq.memo.player.changed";
    public const string PathKey = "path";
    public const string SpeedKey = "hq.voice.memoSpeed";
    public static readonly IReadOnlyList<double> Speeds = [1, 1.5, 2];

    private readonly IMemoAudioOutput _output;
    private readonly IMemoAudioSession _session;
    private readonly IMemoSystemEvents _events;
    private readonly IKeyValueStore _defaults;
    private readonly SynchronizationContext _context;

    private IMemoAudioTrack? _player;
    private double _pausedAt;
    private CancellationTokenSource? _loadTask;
    /// Bumped by every start and teardown: a session activation that lands late plays only for the start that asked.
    private int _startGeneration;
    private readonly HashSet<string> _failed = [];
    private bool _observing;

    /// Built on the UI thread, or given its context.
    public MemoPlayer(IMemoAudioOutput output, IMemoAudioSession session, IMemoSystemEvents events, IKeyValueStore defaults,
        SynchronizationContext? context = null)
    {
        _output = output;
        _session = session;
        _events = events;
        _defaults = defaults;
        _context = context ?? SynchronizationContext.Current
            ?? throw new InvalidOperationException("MemoPlayer is one-thread: build it on the UI thread or pass its context.");
    }

    /// The playing memo, its state or the speed changed (the memo's path when one memo is concerned).
    public event Action<string?>? Changed;

    /// The memo the player holds (its message path: gateway or local).
    public string? Path { get; private set; }
    public MemoPlayState State { get; private set; } = MemoPlayState.Idle;
    public double Duration { get; private set; }
    /// Memos that couldn't load this launch ("Couldn’t load audio · Retry").
    public IReadOnlySet<string> Failed => _failed;

    public double Speed
    {
        get
        {
            var stored = double.TryParse(_defaults.Get(SpeedKey), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : 0;
            return Speeds.Contains(stored) ? stored : 1;
        }
        set
        {
            _defaults.Set(SpeedKey, value.ToString("R", CultureInfo.InvariantCulture));
            if (_player != null) _player.Rate = (float)value;
            Post(Path);
        }
    }

    /// 1 → 1.5 → 2 → 1, saved at once (memo-player.ts:8-22).
    public void CycleSpeed()
    {
        var index = IndexOf(Speed);
        Speed = Speeds[(Math.Max(0, index) + 1) % Speeds.Count];
    }

    private static int IndexOf(double speed)
    {
        for (var i = 0; i < Speeds.Count; i++) if (Speeds[i] == speed) return i;
        return -1;
    }

    public bool IsCurrent(string path) => Path == path;

    /// Seconds played of `path` (0 when it isn't the one held).
    public double CurrentTime(string path) => Path != path ? 0 : _player?.CurrentTime ?? _pausedAt;

    public MemoPlayState StateOf(string path) => Path == path ? State : MemoPlayState.Idle;

    // MARK: Play / pause

    /// Play `path`, from `fraction` of it when given. `resolve` finds (or downloads) its local file.
    public void Play(string path, Func<Task<string>> resolve, double? fraction = null)
    {
        InstallObservers();
        if (Path == path && _player is { } held)
        {
            if (fraction is { } f) held.CurrentTime = Clamp(f) * held.Duration;
            Start(held);
            return;
        }
        // Starting a memo pauses the one playing (memo-player.ts:24-26).
        Teardown(release: true);
        Path = path;
        _failed.Remove(path);
        State = MemoPlayState.Loading;
        Post(path);
        var load = new CancellationTokenSource();
        _loadTask = load;
        _ = Load(path, resolve, fraction, load.Token);
    }

    private async Task Load(string path, Func<Task<string>> resolve, double? fraction, CancellationToken cancelled)
    {
        try
        {
            var file = await resolve();
            if (Path != path || cancelled.IsCancellationRequested) return;
            var generation = _startGeneration;
            // [perf] Opening the file and priming it are media calls (A-P1): off the UI thread. Play stays on the UI
            // thread in Start, so a Pause can never be overtaken by a queued Play.
            var player = await _output.OpenAsync(file);
            // A stop, or another memo, while it was built: the player was never started, so it is just dropped.
            if (Path != path || _startGeneration != generation || cancelled.IsCancellationRequested) return;
            player.Finished += OnFinished;
            player.DecodeError += OnDecodeError;
            _player = player;
            Duration = player.Duration;
            if (fraction is { } f) player.CurrentTime = Clamp(f) * player.Duration;
            Start(player);
        }
        catch (Exception e)
        {
            if (Path != path || e is OperationCanceledException) return;
            _failed.Add(path);
            MemoLoadFailures.Insert(path);
            Teardown(release: true);
            Path = null;
            Post(path);
        }
    }

    /// Shows Pause at once; the sound starts once the session is active. A session that can't be had or a player that
    /// won't play is a load failure: the bubble says "Couldn’t load audio · Retry" instead of a Pause with no sound.
    private void Start(IMemoAudioTrack player)
    {
        _startGeneration++;
        var generation = _startGeneration;
        _session.PlaybackPreempted = Pause;
        State = MemoPlayState.Playing;
        Post(Path);
        _ = Activate(player, generation);
    }

    private async Task Activate(IMemoAudioTrack player, int generation)
    {
        var ready = true;
        try { await _session.AcquireAsync(); } catch (Exception) { ready = false; }
        if (_startGeneration != generation || State != MemoPlayState.Playing || !ReferenceEquals(_player, player)) return;
        player.Rate = (float)Speed;
        if (!ready || !player.Play()) StartFailed();
    }

    private void StartFailed()
    {
        if (Path is not { } path) return;
        _failed.Add(path);
        MemoLoadFailures.Insert(path);
        Teardown(release: true);
        Path = null;
        Post(path);
    }

    public void Pause()
    {
        if (_player is not { } player || State != MemoPlayState.Playing)
        {
            if (State == MemoPlayState.Loading) Stop();
            return;
        }
        player.Pause();
        _pausedAt = player.CurrentTime;
        State = MemoPlayState.Paused;
        _session.Release();
        Post(Path);
    }

    public void Toggle(string path, Func<Task<string>> resolve)
    {
        if (Path == path && State == MemoPlayState.Playing) Pause(); else Play(path, resolve);
    }

    /// Moves `path` to `fraction` (scrubbing). A memo not loaded yet loads and starts there (Telegram's bubbles scrub at
    /// any time; the web only seeks a loaded memo).
    public void Seek(string path, double fraction, Func<Task<string>> resolve)
    {
        if (Path == path && _player is { } player)
        {
            player.CurrentTime = Clamp(fraction) * player.Duration;
            _pausedAt = player.CurrentTime;
            Post(path);
            return;
        }
        Play(path, resolve, fraction);
    }

    /// Stops and lets go (the chat screen left, recording starts, sign-out).
    public void Stop()
    {
        var old = Path;
        Teardown(release: true);
        Path = null;
        if (old != null) Post(old);
    }

    public void ForgetFailure(string path)
    {
        _failed.Remove(path);
        if (MemoLoadFailures.Remove(path)) Post(path);
    }

    /// The memo's file couldn't be fetched (a 404 while its waveform loaded): the bubble says so, with Retry.
    public void MarkFailed(string path)
    {
        MemoLoadFailures.Insert(path);
        if (!_failed.Add(path)) return;
        Post(path);
    }

    private void Teardown(bool release)
    {
        _startGeneration++;
        _loadTask?.Cancel();
        _loadTask = null;
        if (_player is { } player)
        {
            player.Finished -= OnFinished;
            player.DecodeError -= OnDecodeError;
            player.Stop();
        }
        _player = null;
        _pausedAt = 0;
        Duration = 0;
        State = MemoPlayState.Idle;
        if (release) _session.Release();
    }

    // MARK: Ended

    // Only the player that is playing now may end or fail the memo: a callback already queued for memo A must not reset
    // memo B, started in the same instant. Raised on any thread; handled on the player's (DispatchQueue.main.async).
    private void OnFinished(IMemoAudioTrack track, bool successfully) => _context.Post(_ =>
    {
        if (ReferenceEquals(track, _player)) Ended();
    }, null);

    private void OnDecodeError(IMemoAudioTrack track) => _context.Post(_ =>
    {
        if (ReferenceEquals(track, _player)) StartFailed();
    }, null);

    /// Back to the start, not playing, no progress (memo-player.ts:148); the session goes back.
    private void Ended()
    {
        if (State != MemoPlayState.Playing) return;
        if (_player != null) _player.CurrentTime = 0;
        _pausedAt = 0;
        State = MemoPlayState.Paused;
        _session.Release();
        Post(Path);
    }

    // MARK: System events

    private void InstallObservers()
    {
        if (_observing) return;
        _observing = true;
        _events.Raised += e => _context.Post(_ => OnSystem(e), null);
    }

    private void OnSystem(MemoSystemEvent e)
    {
        switch (e)
        {
            // Pause on began; never auto-resume on ended.
            case MemoSystemEvent.InterruptionBegan: Pause(); break;
            // Headphones out: pause, per Apple's guidance.
            case MemoSystemEvent.OldDeviceUnavailable: Pause(); break;
            case MemoSystemEvent.MediaServicesReset:
                _session.Reset();
                Stop();
                break;
            case MemoSystemEvent.EnteredBackground: Pause(); break;
        }
    }

    private void Post(string? path) => Changed?.Invoke(path);

    private static double Clamp(double fraction) => Math.Max(0, Math.Min(1, fraction));
}
