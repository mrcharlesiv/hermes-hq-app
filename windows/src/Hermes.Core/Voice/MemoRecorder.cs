namespace Hermes.Core.Voice;

// [WIN-VOICE-RECORDER] The inline recorder (spec 1x-voice §3.3, §3.4; HermesKit/Voice/MemoRecorder.swift at 93f984bb1).
// One take at a time; `BeginAsync` resolves only once the input's `Record` returned true, so the screen never shows red
// before the microphone is really recording. A call, an interruption, leaving the app or a lost headset ends the take as
// a draft (a second or longer), never a send.
//
// Every recorder call (making it, Record, metering, Stop) runs on the audio work queue (`MemoAudioWork`, the Mac's
// `AudioWork`): they are blocking calls into the media stack and never run on the UI thread (A-P1). The take's state
// (token, clock, samples) stays on the UI thread; the recorder object is only ever driven on that queue.
//
// The Mac's recorder is @MainActor: here it is one-thread. It is built on the app's UI thread (or given that thread's
// SynchronizationContext) and every public member is called there; its awaits come back there, and callbacks from the
// input and the system (any thread) are posted to it, as the Mac's `queue: .main` / `DispatchQueue.main.async`.
// The app holds one MemoRecorder (the Mac's `static let shared`, Swift line 37).
//
// Seams (the Swift line each replaces):
//   IMemoAudioInput.Permission / RequestPermissionAsync   AVAudioApplication recordPermission / requestRecordPermission
//                                                          (267-285)
//   IMemoAudioInput.Create        lines 191-197  `AVAudioRecorder(url:settings:)` AAC mono 24 kHz 48 kbps, metering on;
//                                                 run on the work queue (135)
//   IMemoAudioTake                AVAudioRecorder: record(forDuration:) (143), prepareToRecord (163), updateMeters +
//                                 averagePower(forChannel: 0) (332-333), stop (203, 360); its delegate (194, 202, 359)
//                                 is the Finished and EncodeError events (478-496)
//   IMemoAudioSession             AudioSessionCoordinator.shared for `.memoRecording`: acquire (133, 162), release (138,
//                                 148, 168, 181, 366), reset (468). The same interface the player holds for
//                                 `.memoPlayback`; the app hands the recorder the coordinator's recording handle, and
//                                 the recorder never reads `PlaybackPreempted`.
//   IMemoSystemEvents             the player's event seam, reused: the four observers (456-475; interruption began only,
//                                 route change `.oldDeviceUnavailable` only, media services reset, entered background)
//                                 and the busy-input pause's background watch (150-153)
//   MemoAudioWork                 AudioWork (AudioSessionCoordinator.swift:14-36): one serial queue off the UI thread
//   TimeProvider                  CACurrentMediaTime (85, 214, 296, 301) and the 15 Hz Timer (302-304) and the 150 ms
//                                 pause (152)
//   appActive                     `UIApplication.shared.applicationState == .active` (87, 155, 177-178)
//   limitSeconds                  `MemoPolicy.limitSeconds()` (98): the attachment limit is a Settings value later
//   temporaryFolder               FileManager.default.temporaryDirectory (130)
// Not ported: the DEBUG simulator fixture recorder (67-78, 111-127, 268-292, 305-322, 337-338, 376-377, 393-405,
// 498-518; `-HQDebugMemoFixture`, a Mac simulator switch: the fake audio input in the tests stands in for it), the
// keep-awake hold (59-61, 216-219, 367-368; [talk], Core has no KeepAwake), the "memo start" signpost (63-65, 109,
// 208-211) and the AppLog notes (222, 427, 436; the log lives in the WinUI app). File protection (404, 411-412) is the
// account folder's IMemoFolderGuard, applied by MemoPaths.Ensure.
// The Windows input (MediaCapture / AudioGraph behind IMemoAudioInput, the system's audio and app events behind
// IMemoSystemEvents) is the next slice; Core has none.

/// AVAudioApplication.recordPermission.
public enum MemoMicPermission { Undetermined, Denied, Granted }

/// One recorder writing a take's file (the Mac's AVAudioRecorder). Every member is called on the audio work queue; the
/// events may be raised on any thread.
public interface IMemoAudioTake
{
    /// record(forDuration:): starts recording, stopping by itself after `seconds` (then `Finished` with true). False
    /// when the input didn't start (busy for a moment after a call's capture let go).
    bool Record(double seconds);
    /// prepareToRecord(): readies the file again for the one retry.
    bool Prepare();
    /// updateMeters() then averagePower(forChannel: 0): the latest average power, dBFS (-160 silent … 0).
    float AveragePower();
    /// Stops and finishes the file (idempotent).
    void Stop();
    /// audioRecorderDidFinishRecording(_:successfully:): the take that finished and whether it did so successfully
    /// (true at the duration limit).
    event Action<IMemoAudioTake, bool>? Finished;
    /// audioRecorderEncodeErrorDidOccur(_:error:).
    event Action<IMemoAudioTake>? EncodeError;
}

/// The microphone (AVAudioApplication + AVAudioRecorder's construction).
public interface IMemoAudioInput
{
    /// Whether the app may record (read on the UI thread).
    MemoMicPermission Permission { get; }
    /// Shows the system's prompt; true when it was granted.
    Task<bool> RequestPermissionAsync();
    /// Makes a recorder writing AAC (MPEG-4 audio, .m4a), mono, 24 kHz, 48 kbps into `file`, metering on
    /// (`MemoRecorder.SampleRate`, `Channels`, `BitRate`). Blocking: called on the audio work queue. Throws when the
    /// input can't be had; the exception's HResult is read by `MemoRecorder.StartReason`.
    IMemoAudioTake Create(string file);
}

/// Optional format descriptor for an `IMemoAudioInput` that writes a container other than `.m4a` (e.g. Windows
/// `winmm.dll` PCM WAV capture writing `.wav` / `"audio/wav"`). Implementations that do not implement this keep the
/// default `.m4a` / `"audio/x-m4a"` format unchanged.
public interface IMemoAudioFormat
{
    string Mime { get; }
    string Extension { get; }
}

/// The serial queue every audio session and recorder call runs on, off the UI thread (AudioWork). Work runs in the order
/// it was sent; a failure doesn't stop the work behind it.
public sealed class MemoAudioWork
{
    public static readonly MemoAudioWork Shared = new();

    private readonly object _gate = new();
    private Task _tail = Task.CompletedTask;

    /// Runs `work` on the queue (behind everything already sent there) and returns its result.
    public Task<T> Run<T>(Func<T> work)
    {
        lock (_gate)
        {
            var task = _tail.ContinueWith(_ => work(), CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
            _tail = task;
            return task;
        }
    }

    /// Fire-and-forget, behind everything already sent to the queue.
    public void Later(Action work) => _ = Run(() =>
    {
        try { work(); } catch (Exception) { }
        return 0;
    });

    /// Completes once everything sent to the queue so far has run.
    public Task Drain() => Run(() => 0);
}

/// Why `BeginAsync` didn't start a recording (the Mac throws `MemoBeginError` itself).
public sealed class MemoBeginException(MemoBeginError error) : Exception(error.Message ?? error.Code)
{
    public MemoBeginError Error { get; } = error;
}

/// A take couldn't be saved, in words (the Mac's NSError in the "HQMemo" domain, code 3).
public sealed class MemoSaveException(string reason) : Exception(reason);

/// A started take: its id and its length limit in seconds.
public readonly record struct MemoTakeStart(string Id, double Limit);

/// What MemoController drives: the real recorder, or a test stand-in (the Mac's `MemoCapturing`, Swift lines 21-34).
/// Called on the UI thread; `OnEvent` is raised there.
public interface IMemoCapturing
{
    Action<MemoCaptureEvent>? OnEvent { get; set; }
    /// Whose memo folder a saved take goes to (`MemoPaths.AccountKey`).
    string? AccountKey { get; set; }
    bool IsRecording { get; }
    /// Milliseconds from `BeginAsync` to recording (A-P1), once started.
    double? StartLatencyMs { get; }
    /// Starts recording. Throws `MemoBeginException`.
    Task<MemoTakeStart> BeginAsync();
    /// Ends the take: `Cancel` deletes it (null), anything else saves it off the UI thread.
    Task<MemoFile?> EndAsync(string id, MemoEndAction action);
    /// The system or the app ended the take (`MemoPolicy.Finish` decides).
    void NativeStop(MemoStopReason reason);
}

public sealed class MemoRecorder : IMemoCapturing
{
    /// The recorder's format (Swift lines 192-193).
    public const int SampleRate = 24000;
    public const int Channels = 1;
    public const int BitRate = 48000;
    public const string Mime = "audio/x-m4a";
    /// Levels at 15 Hz (Swift line 302); one waveform sample per 100 ms; at most 6000 samples (line 341).
    public static readonly TimeSpan TickInterval = TimeSpan.FromSeconds(1.0 / 15);
    public const int MaxSamples = 6000;
    /// The busy-input pause before the one retry (Swift line 152).
    public static readonly TimeSpan RetryPause = TimeSpan.FromMilliseconds(150);

    private readonly IMemoAudioInput _input;
    private readonly IMemoAudioSession _session;
    private readonly MemoPaths _paths;
    private readonly Func<bool> _appActive;
    private readonly MemoAudioWork _work;
    private readonly TimeProvider _time;
    private readonly Func<double> _limitSeconds;
    private readonly string _temporary;
    private readonly SynchronizationContext _context;

    /// Driven only on the audio queue; the reference is kept on the UI thread.
    private IMemoAudioTake? _recorder;
    /// Completes once the recorder's Stop ran on the audio queue (the file is complete): the save waits for it.
    private Task? _recorderStopped;
    /// The latest average power, read on the audio queue at each tick.
    private readonly Meter _meter = new();
    private string? _url;
    private long? _started;
    private double? _elapsedAtStop;
    private double _limit = 600;
    private ITimer? _ticker;
    private int _clock;
    private readonly List<double> _samples = [];
    private double _windowMax;
    private bool _observing;
    private bool _retryWatch;
    private bool _backgrounded;
    private string _mime = Mime;

    /// Built on the UI thread, or given its context.
    public MemoRecorder(IMemoAudioInput input, IMemoAudioSession session, IMemoSystemEvents events, MemoPaths paths,
        Func<bool> appActive, MemoAudioWork? work = null, TimeProvider? time = null, Func<double>? limitSeconds = null,
        string? temporaryFolder = null, SynchronizationContext? context = null)
    {
        _input = input;
        _session = session;
        _paths = paths;
        _appActive = appActive;
        _work = work ?? MemoAudioWork.Shared;
        _time = time ?? TimeProvider.System;
        _limitSeconds = limitSeconds ?? (() => MemoPolicy.LimitSeconds());
        _temporary = temporaryFolder ?? Path.GetTempPath();
        _context = context ?? SynchronizationContext.Current
            ?? throw new InvalidOperationException("MemoRecorder is one-thread: build it on the UI thread or pass its context.");
        // The system's events come from any thread; they act on the UI thread, and only while a take records (or its
        // start pauses for the one retry).
        events.Raised += e => _context.Post(_ => OnSystem(e), null);
    }

    public Action<MemoCaptureEvent>? OnEvent { get; set; }
    public string? AccountKey { get; set; }
    public double? StartLatencyMs { get; private set; }
    /// The take that is open (recording, or stopped at its limit and waiting for `EndAsync`).
    public string? Token { get; private set; }

    public bool IsRecording => Token != null && _elapsedAtStop == null;

    // MARK: Begin

    public async Task<MemoTakeStart> BeginAsync()
    {
        var asked = _time.GetTimestamp();
        if (Token != null) throw Fail(new MemoBeginError.Busy());
        if (!_appActive()) throw Fail(new MemoBeginError.Background());
        switch (_input.Permission)
        {
            case MemoMicPermission.Undetermined:
                // The touch that raised the prompt records nothing: the next touch records (C1).
                var granted = await _input.RequestPermissionAsync();
                throw Fail(new MemoBeginError.PermissionPending(granted));
            case MemoMicPermission.Denied:
                throw Fail(new MemoBeginError.PermissionDenied());
        }
        var seconds = _limitSeconds();
        if (seconds < MemoPolicy.MinimumLimit) throw Fail(new MemoBeginError.TooSmall());
        var id = Guid.NewGuid().ToString().ToUpperInvariant();
        Token = id;
        _limit = seconds;
        _samples.Clear();
        _windowMax = 0;
        _elapsedAtStop = null;
        _started = null;
        StartLatencyMs = null;
        _meter.Set(-160);

        var format = _input as IMemoAudioFormat;
        var extension = format?.Extension is { Length: > 0 } ext ? ext.TrimStart('.') : "m4a";
        var mime = format?.Mime is { Length: > 0 } m ? m : Mime;
        var file = Path.Combine(_temporary, id + "." + extension);
        IMemoAudioTake box;
        try
        {
            await _session.AcquireAsync();
            // Speech: AAC mono 24 kHz at 48 kbps (V2), or WAV PCM when the platform input declares IMemoAudioFormat.
            box = await _work.Run(() => MakeRecorder(file));
        }
        catch (Exception e)
        {
            if (Token == id) Token = null;
            _session.Release();
            throw Fail(new MemoBeginError.StartFailed(StartReason(e)));
        }
        _mime = mime;
        if (await _work.Run(() => Record(box, seconds))) return FinishStart(box, file, id, seconds, asked);
        // A capture that was just released (a call's, another app's) can leave the input busy for a moment: one fresh
        // activation and a second try. The pause awaits; it never blocks the UI thread (touches keep flowing).
        _session.Release();
        _backgrounded = false;
        _retryWatch = true;
        try { await Task.Delay(RetryPause, _time); }
        finally { _retryWatch = false; }
        if (!MemoPolicy.MayRetry(sameTake: Token == id, stopped: _elapsedAtStop != null, active: _appActive(),
                backgrounded: _backgrounded))
        {
            if (Token == id) Token = null;
            DiscardRecorder(box, file);
            throw Fail(new MemoBeginError.Canceled());
        }
        var again = false;
        var acquired = true;
        try { await _session.AcquireAsync(); } catch (Exception) { acquired = false; }
        if (acquired) again = await _work.Run(() => Prepare(box) && Record(box, seconds));
        if (!again)
        {
            if (Token == id) Token = null;
            DiscardRecorder(box, file);
            _session.Release();
            throw Fail(new MemoBeginError.StartFailed("the microphone did not start recording"));
        }
        return FinishStart(box, file, id, seconds, asked);
    }

    private static MemoBeginException Fail(MemoBeginError error) => new(error);

    // Record and Prepare are the input's own calls: one that throws didn't start (AudioWork.perform can't fail).
    private static bool Record(IMemoAudioTake box, double seconds)
    {
        try { return box.Record(seconds); } catch (Exception) { return false; }
    }

    private static bool Prepare(IMemoAudioTake box)
    {
        try { return box.Prepare(); } catch (Exception) { return false; }
    }

    /// The recorder runs: unless the take was dropped, or the app left the screen, while it started.
    private MemoTakeStart FinishStart(IMemoAudioTake box, string file, string id, double seconds, long asked)
    {
        if (Token != id || _elapsedAtStop != null || !_appActive())
        {
            var background = !_appActive();
            if (Token == id) Token = null;
            DiscardRecorder(box, file);
            _session.Release();
            throw Fail(background ? new MemoBeginError.Background() : new MemoBeginError.Canceled());
        }
        _recorder = box;
        _url = file;
        DidStart(asked);
        return new MemoTakeStart(id, seconds);
    }

    private IMemoAudioTake MakeRecorder(string file)
    {
        var recorder = _input.Create(file);
        recorder.Finished += OnFinished;
        recorder.EncodeError += OnEncodeError;
        return recorder;
    }

    /// Stops a recorder that won't be used and deletes its file (on the audio queue).
    private void DiscardRecorder(IMemoAudioTake box, string file) => _work.Later(() =>
    {
        box.Finished -= OnFinished;
        box.EncodeError -= OnEncodeError;
        try { box.Stop(); }
        finally { TryDelete(file); }
    });

    private void DidStart(long asked)
    {
        StartLatencyMs = _time.GetElapsedTime(asked).TotalMilliseconds;
        StartClock();
        _observing = true;
    }

    // MARK: End

    public async Task<MemoFile?> EndAsync(string id, MemoEndAction action)
    {
        if (Token != id) throw SaveError("that voice memo already ended");
        var elapsed = Stop();
        if (action == MemoEndAction.Cancel)
        {
            Discard();
            Token = null;
            return null;
        }
        var saving = SaveTask(elapsed);
        Token = null;
        return await saving;
    }

    public void NativeStop(MemoStopReason reason)
    {
        if (Token is not { } id || _elapsedAtStop != null) return;
        var elapsed = Stop();
        switch (MemoPolicy.Finish(reason, elapsed))
        {
            case MemoFinish.Await:
                // The length limit: the release rule decides; the take stays open for `EndAsync`.
                OnEvent?.Invoke(new MemoCaptureEvent.Stopped(reason, id, elapsed, new MemoStopDisposition.Await()));
                break;
            case MemoFinish.Draft:
                var saving = SaveTask(elapsed);
                Token = null;
                _ = Drafted(saving, reason, id, elapsed);
                break;
            default:
                Discard();
                Token = null;
                OnEvent?.Invoke(new MemoCaptureEvent.Stopped(reason, id, elapsed, new MemoStopDisposition.Discard()));
                break;
        }
    }

    private async Task Drafted(Task<MemoFile> saving, MemoStopReason reason, string id, double elapsed)
    {
        MemoStopDisposition disposition;
        try { disposition = new MemoStopDisposition.Draft(await saving); }
        catch (Exception e) { disposition = new MemoStopDisposition.Failed(Reason(e)); }
        OnEvent?.Invoke(new MemoCaptureEvent.Stopped(reason, id, elapsed, disposition));
    }

    // MARK: Recording

    private double Elapsed() =>
        _elapsedAtStop ?? (_started is { } started ? Math.Min(_limit, _time.GetElapsedTime(started).TotalSeconds) : 0);

    /// Levels at 15 Hz, one waveform sample per 100 ms of elapsed time.
    private void StartClock()
    {
        _started = _time.GetTimestamp();
        var clock = ++_clock;
        _ticker = _time.CreateTimer(_ => _context.Post(_ =>
        {
            if (clock == _clock && _ticker != null) Tick();
        }, null), null, TickInterval, TickInterval);
    }

    private void Tick()
    {
        var seconds = Elapsed();
        var level = 0.0;
        if (_recorder is { } recorder)
        {
            // Metered on the audio queue; this tick shows the reading the last one asked for (66 ms old at most).
            var meter = _meter;
            _work.Later(() => meter.Set(recorder.AveragePower()));
            level = MemoPolicy.Level(meter.Get());
        }
        _windowMax = Math.Max(_windowMax, level);
        while (_samples.Count < Math.Min(MaxSamples, (int)(seconds * 10)))
        {
            _samples.Add(_windowMax);
            _windowMax = 0;
        }
        OnEvent?.Invoke(new MemoCaptureEvent.Level(Math.Round(level * 1000, MidpointRounding.AwayFromZero) / 1000,
            MemoPolicy.TwoDecimals(seconds)));
    }

    /// Stops recording (idempotent) and returns the take's length.
    private double Stop()
    {
        if (_elapsedAtStop is { } done) return done;
        var seconds = Elapsed();
        _elapsedAtStop = seconds;
        if (_recorder is { } recorder)
        {
            _recorder = null;
            // The recorder finishes its file on the audio queue; the session's release is queued right behind it.
            var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _work.Later(() =>
            {
                recorder.Finished -= OnFinished;
                recorder.EncodeError -= OnEncodeError;
                try { recorder.Stop(); }
                finally { stopped.TrySetResult(); }
            });
            _recorderStopped = stopped.Task;
        }
        Teardown();
        _session.Release();
        return seconds;
    }

    private void Teardown()
    {
        _ticker?.Dispose();
        _ticker = null;
        _clock++;
        _observing = false;
    }

    /// Saves the take off the UI thread into memos/<account>/<UUID>/voice-memo.<ext>. The temporary recording is
    /// deleted only once it is saved (moved).
    private Task<MemoFile> SaveTask(double elapsed)
    {
        var source = _url;
        _url = null;
        var stopped = _recorderStopped;
        _recorderStopped = null;
        var peaks = MemoPolicy.Peaks(_samples);
        var key = AccountKey ?? "local";
        var mime = _mime;
        var paths = _paths;
        return Task.Run(async () =>
        {
            // The recorder's file is complete once its stop ran on the audio queue.
            if (stopped != null) await stopped.ConfigureAwait(false);
            var target = paths.NewRecording(key, mime == "audio/wav" ? "wav" : "m4a");
            paths.Ensure(Path.GetDirectoryName(target)!);
            if (source == null) throw SaveError("the recording is empty");
            var size = File.Exists(source) ? new FileInfo(source).Length : 0;
            if (size <= 0) throw SaveError("the recording is empty");
            File.Move(source, target);
            return new MemoFile(target, MemoPolicy.TwoDecimals(elapsed), peaks, mime);
        });
    }

    public static MemoSaveException SaveError(string reason) => new(reason);

    /// Why a take couldn't be saved, in words; "" when there are none (the card then says it couldn't be saved on this
    /// PC). A bare code never reaches the card.
    public static string Reason(Exception error) => error is MemoSaveException save ? save.Message : "";

    /// Why the microphone didn't start (a memo or a dictation), in words. The input's codes mean something: the card
    /// said "iOS error 561017449" when a call held the microphone.
    public static string StartReason(Exception error) =>
        error is MemoSaveException save ? save.Message : MicrophoneWords(error.HResult);

    public static string MicrophoneWords(int code) => code switch
    {
        // '!pri' (insufficient priority), '!int' (can't interrupt others), '!rec' (can't start recording): a call, Siri
        // or another app holds the microphone (the Mac's codes). Windows: AUDCLNT_E_DEVICE_IN_USE, another app holds
        // the device exclusively.
        561_017_449 or 560_557_684 or 561_145_187 or unchecked((int)0x8889000A) => "a call or another app is using the microphone",
        _ => "the microphone didn’t start",
    };

    /// Deletes the take's file, on the audio queue behind the recorder's stop (it may still be finishing the file).
    private void Discard()
    {
        _recorderStopped = null;
        if (_url is { } url) _work.Later(() => TryDelete(url));
        _url = null;
    }

    private static void TryDelete(string file)
    {
        try { File.Delete(file); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private void OnSystem(MemoSystemEvent e)
    {
        // The busy-input pause: a trip to the background means no retry.
        if (_retryWatch && e == MemoSystemEvent.EnteredBackground) _backgrounded = true;
        if (!_observing) return;
        switch (e)
        {
            case MemoSystemEvent.InterruptionBegan: NativeStop(MemoStopReason.Interrupted); break;
            case MemoSystemEvent.OldDeviceUnavailable: NativeStop(MemoStopReason.RouteLost); break;
            case MemoSystemEvent.MediaServicesReset:
                _session.Reset();
                NativeStop(MemoStopReason.Reset);
                break;
            case MemoSystemEvent.EnteredBackground: NativeStop(MemoStopReason.Background); break;
        }
    }

    // The input calls these on its own thread: every piece of the memo's state lives on the UI thread. Only the recorder
    // that is recording now may end the take.
    private void OnFinished(IMemoAudioTake take, bool successfully) => _context.Post(_ =>
    {
        if (ReferenceEquals(take, _recorder)) NativeStop(successfully ? MemoStopReason.Limit : MemoStopReason.Error);
    }, null);

    private void OnEncodeError(IMemoAudioTake take) => _context.Post(_ =>
    {
        if (ReferenceEquals(take, _recorder)) NativeStop(MemoStopReason.Error);
    }, null);

    /// The recorder's latest average power (dBFS), written on the audio queue and read on the UI thread.
    private sealed class Meter
    {
        private float _power = -160;
        public void Set(float value) => Volatile.Write(ref _power, value);
        public float Get() => Volatile.Read(ref _power);
    }
}

/// Connects a recorder (`IMemoCapturing`) to the gesture's runner (`MemoSession`, through `IMemoRecorder`): the
/// recorder half of MemoController.swift at 93f984bb1 (`begin()` 293-327, `end(_:before:)` 329-394, `captured(_:)`
/// 421-470, `reset()` 627-650). The session's Begin starts a take and answers `Started` or `BeginFailed`; its End
/// ends the take and answers `Ended` (review carries the saved length); the recorder's levels tick the clock and its
/// own stops go to `MemoSession.RecorderStopped`. What becomes of a saved file (send, draft chip, review, notices) is
/// the page's, through the events. One-thread: built and used on the UI thread, with the session.
public sealed class MemoCaptureLink : IMemoRecorder
{
    private readonly IMemoCapturing _capture;
    private readonly Func<double> _nowMs;
    private MemoSession? _session;
    private int _generation;

    /// `nowMs`: the gesture's clock in milliseconds (the `at` of `Started`).
    public MemoCaptureLink(IMemoCapturing capture, Func<double> nowMs)
    {
        _capture = capture;
        _nowMs = nowMs;
        capture.OnEvent = Captured;
    }

    /// The session this link answers (it is built with the link as its recorder).
    public void Attach(MemoSession session) => _session = session;

    private MemoSession Session => _session ?? throw new InvalidOperationException("Attach the MemoSession first.");

    /// The take recording now (null before the recorder confirmed, and once it ended).
    public string? TakeId { get; private set; }
    public double Limit { get; private set; }

    /// A take ended with a file: the end action and the file (send, draft, review).
    public event Action<MemoEndAction, MemoFile>? Saved;
    /// A take that should have been kept couldn't be saved: the end action and the words (`MemoRecorder.Reason`).
    public event Action<MemoEndAction, string>? SaveFailed;
    /// The recorder stopped a take by itself (not the limit): the reason, the length and the draft or why not.
    public event Action<MemoCaptureEvent.Stopped>? Stopped;
    /// 15 Hz: the level and the seconds recorded.
    public event Action<double, double>? LevelChanged;

    public void Begin()
    {
        var mine = ++_generation;
        _ = Run();

        async Task Run()
        {
            await Task.Yield();   // the Mac's `Task { }`: after the effect that asked
            try
            {
                var started = await _capture.BeginAsync();
                if (mine != _generation)
                {
                    try { await _capture.EndAsync(started.Id, MemoEndAction.Cancel); } catch (Exception) { }
                    return;
                }
                TakeId = started.Id;
                Limit = started.Limit;
                Session.Input(new MemoInput.Started(_nowMs()));
                // Nothing wanted it any more (the take was reset meanwhile): stop recording.
                if (Session.State.Phase == MemoPhase.Idle && TakeId is { } id)
                {
                    TakeId = null;
                    try { await _capture.EndAsync(id, MemoEndAction.Cancel); } catch (Exception) { }
                }
            }
            catch (Exception e)
            {
                if (mine != _generation) return;
                var failure = (e as MemoBeginException)?.Error ?? new MemoBeginError.StartFailed(MemoRecorder.StartReason(e));
                Session.Input(failure.Input);
            }
        }
    }

    public void End(MemoEndAction action)
    {
        if (TakeId is not { } id)
        {
            Session.Input(new MemoInput.Ended(MemoEndAction.Cancel));
            return;
        }
        // Windows: the link forgets the take as the recorder is asked to end it (the Mac clears it once `end`
        // returned); nothing the recorder says about this take matters any more, and it is never ended twice.
        TakeId = null;
        var ending = _capture.EndAsync(id, action);
        _ = Finish();

        async Task Finish()
        {
            try
            {
                var saved = await ending;
                if (saved is null)
                {
                    // A cancelled take (slid away, or deleted when asked) leaves no file.
                    Session.Input(new MemoInput.Ended(action));
                    return;
                }
                if (action == MemoEndAction.Review)
                {
                    Saved?.Invoke(action, saved);
                    Session.Input(new MemoInput.Ended(MemoEndAction.Review, saved.Seconds));
                    return;
                }
                Session.Input(new MemoInput.Ended(action));
                Saved?.Invoke(action, saved);
            }
            catch (Exception e)
            {
                Session.Input(new MemoInput.Ended(MemoEndAction.Cancel));
                if (action != MemoEndAction.Cancel) SaveFailed?.Invoke(action, MemoRecorder.Reason(e));
            }
        }
    }

    /// Sign-out or an account switch: a take still recording is dropped.
    public void Reset()
    {
        _generation++;
        if (TakeId is not { } id) return;
        TakeId = null;
        _ = Drop();

        async Task Drop()
        {
            try { await _capture.EndAsync(id, MemoEndAction.Cancel); } catch (Exception) { }
        }
    }

    private void Captured(MemoCaptureEvent e)
    {
        switch (e)
        {
            case MemoCaptureEvent.Level level:
                if (TakeId == null || Session.State.Phase == MemoPhase.Review) return;
                LevelChanged?.Invoke(level.Value, level.Seconds);
                if (Math.Floor(level.Seconds) != Math.Floor(Session.State.Seconds)) Session.Input(new MemoInput.Tick(level.Seconds));
                break;
            case MemoCaptureEvent.Stopped stopped:
                if (stopped.Id != TakeId) return;
                if (stopped.Reason != MemoStopReason.Limit) TakeId = null;
                // The limit waits for the release rule; anything else returns the gesture to idle. Never a send.
                Session.RecorderStopped(stopped.Reason, stopped.Seconds);
                if (stopped.Reason != MemoStopReason.Limit) Stopped?.Invoke(stopped);
                break;
        }
    }
}
