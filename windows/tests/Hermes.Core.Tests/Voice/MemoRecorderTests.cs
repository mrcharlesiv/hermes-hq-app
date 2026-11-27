// [WIN-VOICE-RECORDER] HermesKit/Voice/MemoRecorder.swift at 93f984bb1. The Mac has no MemoRecorder unit tests: these
// are written from the Swift's behaviour, each naming the Swift line it checks ("line N" is MemoRecorder.swift unless
// another file is named), plus the recorder-only cases of Tests/Voice/MemoControllerTests.swift (lines 134-141, and
// 155-173 with the fake input standing in for the simulator fixture). The recorder runs on the Mac's main actor
// (MainLoop.Drive); the microphone is FakeMemoInput below (no microphone, no audio session: synthetic data only); the
// session and system events are Voice/FakeMemoAudio.cs's, the player's stand-ins.

using System.Collections.Concurrent;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests.Voice;

/// A clock the test moves by hand (CACurrentMediaTime, the 15 Hz Timer and the 150 ms pause). Thread-safe.
internal sealed class ManualTime : TimeProvider
{
    private readonly object _gate = new();
    private readonly List<ManualTimer> _timers = [];
    private long _now = 1_000_000_000;

    public override long TimestampFrequency => TimeSpan.TicksPerSecond;
    public override long GetTimestamp() { lock (_gate) return _now; }

    /// Timers that will still fire.
    public int Pending { get { lock (_gate) return _timers.Count(t => t.Due != null); } }

    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        var timer = new ManualTimer(this, callback, state);
        timer.Change(dueTime, period);
        lock (_gate) _timers.Add(timer);
        return timer;
    }

    /// Moves the clock, firing every timer that falls due on the way, in order.
    public void Advance(TimeSpan span)
    {
        long end;
        lock (_gate) end = _now + span.Ticks;
        while (true)
        {
            ManualTimer? next;
            lock (_gate)
            {
                next = _timers.Where(t => t.Due is { } d && d <= end).MinBy(t => t.Due!.Value);
                if (next == null) { _now = end; return; }
                _now = Math.Max(_now, next.Due!.Value);
                next.Due = next.Period is { } p && p > 0 ? _now + p : null;
            }
            next.Fire();
        }
    }

    internal sealed class ManualTimer(ManualTime time, TimerCallback callback, object? state) : ITimer
    {
        public long? Due;
        public long? Period;

        public bool Change(TimeSpan dueTime, TimeSpan period)
        {
            lock (time._gate)
            {
                Due = dueTime == Timeout.InfiniteTimeSpan ? null : time._now + dueTime.Ticks;
                Period = period == Timeout.InfiniteTimeSpan ? null : period.Ticks;
            }
            return true;
        }

        public void Fire() => callback(state);

        public void Dispose()
        {
            lock (time._gate)
            {
                Due = null;
                time._timers.Remove(this);
            }
        }

        public ValueTask DisposeAsync()
        {
            Dispose();
            return ValueTask.CompletedTask;
        }
    }
}

/// The microphone: AVAudioApplication's permission and AVAudioRecorder. Every recorder call notes its thread.
internal sealed class FakeMemoInput(ManualTime time) : IMemoAudioInput
{
    private readonly object _gate = new();
    private readonly List<FakeMemoTake> _made = [];

    public MemoMicPermission Permission { get; set; } = MemoMicPermission.Granted;
    public bool PromptAnswer { get; set; } = true;
    public int Prompts { get; private set; }
    /// The next Create throws this (the input can't be had).
    public Exception? CreateFails { get; set; }
    /// Record's answers in order; true once they run out.
    public ConcurrentQueue<bool> RecordAnswers { get; } = new();
    /// How long starting takes on the audio queue (the start latency).
    public TimeSpan StartTakes { get; set; } = TimeSpan.FromMilliseconds(40);
    /// The average power the meter reads, dBFS.
    public float Power { get; set; } = -160;
    /// Whether the takes write any audio (an empty file can't be saved).
    public bool WritesAudio { get; set; } = true;
    /// Managed thread ids of every recorder call (Create, Record, Prepare, AveragePower, Stop).
    public ConcurrentBag<int> Threads { get; } = [];

    public IReadOnlyList<FakeMemoTake> Made { get { lock (_gate) return _made.ToArray(); } }

    public Task<bool> RequestPermissionAsync()
    {
        Prompts++;
        Permission = PromptAnswer ? MemoMicPermission.Granted : MemoMicPermission.Denied;
        return Task.FromResult(PromptAnswer);
    }

    public IMemoAudioTake Create(string file)
    {
        Note();
        if (CreateFails is { } fails) throw fails;
        var take = new FakeMemoTake(this, file);
        lock (_gate) _made.Add(take);
        return take;
    }

    internal void Note() => Threads.Add(Environment.CurrentManagedThreadId);

    internal sealed class FakeMemoTake(FakeMemoInput input, string file) : IMemoAudioTake
    {
        public string File { get; } = file;
        public List<double> Records { get; } = [];
        public int Prepares { get; private set; }
        public int Stops { get; private set; }
        public bool Recording { get; private set; }

        public bool Record(double seconds)
        {
            input.Note();
            Records.Add(seconds);
            if (input.RecordAnswers.TryDequeue(out var answer) && !answer) return false;
            input.Time.Advance(input.StartTakes);
            if (input.WritesAudio) System.IO.File.WriteAllBytes(File, [1, 2, 3, 4]);
            Recording = true;
            return true;
        }

        public bool Prepare()
        {
            input.Note();
            Prepares++;
            return true;
        }

        public float AveragePower()
        {
            input.Note();
            return input.Power;
        }

        /// Finishing the file takes a moment: the save must wait for it.
        public void Stop()
        {
            input.Note();
            Stops++;
            if (Recording && input.WritesAudio)
            {
                Thread.Sleep(30);
                using var stream = new FileStream(File, FileMode.Append);
                stream.Write([5, 6, 7, 8]);
            }
            Recording = false;
        }

        public event Action<IMemoAudioTake, bool>? Finished;
        public event Action<IMemoAudioTake>? EncodeError;

        public bool Subscribed => Finished != null || EncodeError != null;

        /// The delegate's callbacks come from the input's own thread.
        public Task Finish(bool successfully) => Task.Run(() => Finished?.Invoke(this, successfully));
        public Task FailEncoding() => Task.Run(() => EncodeError?.Invoke(this));
    }

    internal ManualTime Time { get; } = time;
}

public sealed class MemoRecorderTests : IDisposable
{
    private readonly VoiceTestStores _stores = new();

    public void Dispose() => _stores.Dispose();

    /// One recorder and its stand-ins, built on the loop (the UI thread).
    private sealed class Rig
    {
        public readonly ManualTime Time = new();
        public readonly FakeMemoInput Input;
        public readonly FakeMemoSession Session = new();
        public readonly FakeMemoSystem System = new();
        public readonly MemoAudioWork Work = new();
        public readonly MemoRecorder Recorder;
        public readonly List<MemoCaptureEvent> Events = [];
        public readonly int UiThread = Environment.CurrentManagedThreadId;
        public readonly string Temporary;
        public bool Active = true;
        public double Limit = 600;

        public Rig(VoiceTestStores stores)
        {
            Input = new FakeMemoInput(Time);
            Temporary = Path.Combine(stores.Base, "tmp");
            Directory.CreateDirectory(Temporary);
            Recorder = new MemoRecorder(Input, Session, System, stores.Paths, () => Active, Work, Time, () => Limit, Temporary)
            {
                OnEvent = Events.Add,
            };
        }

        public FakeMemoInput.FakeMemoTake Take => Input.Made.Last();

        /// Lets the clock run `seconds` (a whole number of 15 Hz ticks) in ticks, each tick handled and its metering done.
        public async Task Run(double seconds)
        {
            var steps = (int)Math.Round(seconds * 15);
            Assert.Equal(seconds * 15, steps, 6);
            for (var i = 0; i < steps; i++)
            {
                Time.Advance(MemoRecorder.TickInterval);
                await Task.Yield();   // the posted tick runs
                await Work.Drain();   // its metering ran on the audio queue
            }
        }

        /// Waits until something posted to the UI thread (an end, a stop, a save) has run.
        public static Task<bool> Until(Func<bool> condition) => VoiceFixtures.WaitUntil(condition);

        public IReadOnlyList<MemoCaptureEvent.Stopped> Stops => Events.OfType<MemoCaptureEvent.Stopped>().ToArray();

        /// No recorder call ran on the UI thread (A-P1, lines 6-8).
        public void AssertOffTheUiThread()
        {
            Assert.NotEmpty(Input.Threads);
            Assert.DoesNotContain(UiThread, Input.Threads);
        }
    }

    private static async Task<MemoBeginError> BeginFails(MemoRecorder recorder) =>
        (await Assert.ThrowsAsync<MemoBeginException>(recorder.BeginAsync)).Error;

    // MARK: Begin

    [Fact]
    public Task BeginResolvesOnlyOnceTheMicrophoneRecords() => MainLoop.Drive(async () =>
    {
        // Lines 84-85, 129-144, 185-188, 213-214: the take resolves after record(forDuration:) returned true, with the
        // start latency measured from the ask; the limit is the policy's (600 s).
        var rig = new Rig(_stores);
        Assert.False(rig.Recorder.IsRecording);
        Assert.Null(rig.Recorder.StartLatencyMs);
        var started = await rig.Recorder.BeginAsync();
        Assert.Equal(600, started.Limit);
        Assert.Equal(rig.Recorder.Token, started.Id);
        Assert.True(rig.Recorder.IsRecording);
        Assert.True(rig.Take.Recording);
        Assert.Equal([600.0], rig.Take.Records);
        Assert.Equal(40, rig.Recorder.StartLatencyMs!.Value, 3);
        Assert.Equal(Path.Combine(rig.Temporary, started.Id + ".m4a"), rig.Take.File);
        Assert.Equal(1, rig.Session.Acquires);
        Assert.Equal(0, rig.Session.Releases);
        Assert.True(rig.Take.Subscribed, "the recorder's delegate is set (line 194)");
        rig.AssertOffTheUiThread();
        await rig.Recorder.EndAsync(started.Id, MemoEndAction.Cancel);
    });

    [Fact]
    public Task OneTakeAtATime() => MainLoop.Drive(async () =>
    {
        // Line 86: a second begin while a take is open is `busy`, and leaves the first take recording.
        var rig = new Rig(_stores);
        var first = await rig.Recorder.BeginAsync();
        Assert.IsType<MemoBeginError.Busy>(await BeginFails(rig.Recorder));
        Assert.Equal(first.Id, rig.Recorder.Token);
        Assert.Single(rig.Input.Made);
        Assert.True(rig.Recorder.IsRecording);
        await rig.Recorder.EndAsync(first.Id, MemoEndAction.Cancel);
        // One take ended, the next one may begin.
        var second = await rig.Recorder.BeginAsync();
        Assert.NotEqual(first.Id, second.Id);
        await rig.Recorder.EndAsync(second.Id, MemoEndAction.Cancel);
    });

    [Fact]
    public Task AnAppOffTheScreenDoesNotRecord() => MainLoop.Drive(async () =>
    {
        // Line 87: `background` before anything is asked of the microphone.
        var rig = new Rig(_stores) { Active = false };
        Assert.IsType<MemoBeginError.Background>(await BeginFails(rig.Recorder));
        Assert.Empty(rig.Input.Made);
        Assert.Equal(0, rig.Session.Acquires);
        Assert.Null(rig.Recorder.Token);
    });

    [Fact]
    public Task ThePromptsTouchRecordsNothing() => MainLoop.Drive(async () =>
    {
        // Lines 88-92: an undetermined permission asks, and the touch that asked records nothing, whatever the answer.
        var rig = new Rig(_stores) { Input = { Permission = MemoMicPermission.Undetermined } };
        var pending = Assert.IsType<MemoBeginError.PermissionPending>(await BeginFails(rig.Recorder));
        Assert.True(pending.Answer);
        Assert.Equal(1, rig.Input.Prompts);
        Assert.Empty(rig.Input.Made);
        Assert.Null(rig.Recorder.Token);
        // The next touch records.
        var started = await rig.Recorder.BeginAsync();
        Assert.Equal(1, rig.Input.Prompts);
        await rig.Recorder.EndAsync(started.Id, MemoEndAction.Cancel);

        var refused = new Rig(_stores) { Input = { Permission = MemoMicPermission.Undetermined, PromptAnswer = false } };
        var no = Assert.IsType<MemoBeginError.PermissionPending>(await BeginFails(refused.Recorder));
        Assert.False(no.Answer);
        Assert.Equal(new MemoInput.BeginFailed("permission-pending", false, null), no.Input);
    });

    [Fact]
    public Task ADeniedMicrophoneSaysSoWithoutAsking() => MainLoop.Drive(async () =>
    {
        // Lines 93-94.
        var rig = new Rig(_stores) { Input = { Permission = MemoMicPermission.Denied } };
        var denied = Assert.IsType<MemoBeginError.PermissionDenied>(await BeginFails(rig.Recorder));
        Assert.Equal(0, rig.Input.Prompts);
        Assert.Empty(rig.Input.Made);
        Assert.Equal("permission-denied", denied.Code);
        Assert.Null(denied.Message);
    });

    [Fact]
    public Task ALimitUnderTenSecondsIsTooSmall() => MainLoop.Drive(async () =>
    {
        // Lines 98-99 (MemoPolicy.minimumLimit), with its exact words.
        var rig = new Rig(_stores) { Limit = 9.99 };
        var small = Assert.IsType<MemoBeginError.TooSmall>(await BeginFails(rig.Recorder));
        Assert.Equal("The attachment size limit is too small for a voice memo.", small.Message);
        Assert.Equal("too-small", small.Code);
        Assert.Null(rig.Recorder.Token);
        Assert.Equal(0, rig.Session.Acquires);
        rig.Limit = 10;
        var started = await rig.Recorder.BeginAsync();
        Assert.Equal(10, started.Limit);
        Assert.Equal([10.0], rig.Take.Records);
        await rig.Recorder.EndAsync(started.Id, MemoEndAction.Cancel);
    });

    [Fact]
    public Task AMicrophoneHeldByACallFailsInWords() => MainLoop.Drive(async () =>
    {
        // Lines 132-141, 433-447: the recorder couldn't be made; the session goes back, the token is cleared, and the
        // card says why in words, never the bare code.
        var rig = new Rig(_stores) { Input = { CreateFails = new IOException("held") { HResult = 561_017_449 } } };
        var failed = Assert.IsType<MemoBeginError.StartFailed>(await BeginFails(rig.Recorder));
        Assert.Equal("a call or another app is using the microphone", failed.Words);
        Assert.Equal("Couldn’t start the voice memo: a call or another app is using the microphone.", failed.Message);
        Assert.Equal("start-failed", failed.Code);
        Assert.Null(rig.Recorder.Token);
        Assert.Equal(1, rig.Session.Releases);
        // Any other code: the plain words (line 445).
        rig.Input.CreateFails = new IOException("other") { HResult = -50 };
        var other = Assert.IsType<MemoBeginError.StartFailed>(await BeginFails(rig.Recorder));
        Assert.Equal("Couldn’t start the voice memo: the microphone didn’t start.", other.Message);
        // A refused session is a start failure too (line 133).
        rig.Input.CreateFails = null;
        rig.Session.Refuse = true;
        Assert.IsType<MemoBeginError.StartFailed>(await BeginFails(rig.Recorder));
        Assert.Null(rig.Recorder.Token);
        Assert.Empty(rig.Input.Made);
    });

    [Fact]
    public Task ABusyInputGetsOneFreshTry() => MainLoop.Drive(async () =>
    {
        // Lines 146-172: record(forDuration:) said no; the session is released, 150 ms pass, then one fresh activation,
        // prepareToRecord and record again. The pause never blocks the UI thread.
        var rig = new Rig(_stores);
        rig.Input.RecordAnswers.Enqueue(false);
        var begin = rig.Recorder.BeginAsync();
        Assert.True(await Rig.Until(() => rig.Time.Pending == 1), "the pause waits on the clock");
        Assert.Equal(1, rig.Session.Releases);
        Assert.False(begin.IsCompleted);
        rig.Time.Advance(TimeSpan.FromMilliseconds(149));
        await Task.Yield();
        Assert.False(begin.IsCompleted, "150 ms, not less (line 152)");
        rig.Time.Advance(TimeSpan.FromMilliseconds(1));
        var started = await begin;
        Assert.Equal(2, rig.Session.Acquires);
        Assert.Single(rig.Input.Made);
        Assert.Equal(1, rig.Take.Prepares);
        Assert.Equal([600.0, 600.0], rig.Take.Records);
        Assert.True(rig.Recorder.IsRecording);
        rig.AssertOffTheUiThread();
        await rig.Recorder.EndAsync(started.Id, MemoEndAction.Cancel);
    });

    [Fact]
    public Task AnInputThatStaysBusyFailsWithItsWords() => MainLoop.Drive(async () =>
    {
        // Lines 165-171: the retry didn't record either: the recorder is stopped, its file deleted, the session released.
        var rig = new Rig(_stores);
        rig.Input.RecordAnswers.Enqueue(false);
        rig.Input.RecordAnswers.Enqueue(false);
        var begin = rig.Recorder.BeginAsync();
        Assert.True(await Rig.Until(() => rig.Time.Pending == 1));
        rig.Time.Advance(MemoRecorder.RetryPause);
        var failed = Assert.IsType<MemoBeginError.StartFailed>((await Assert.ThrowsAsync<MemoBeginException>(() => begin)).Error);
        Assert.Equal("Couldn’t start the voice memo: the microphone did not start recording.", failed.Message);
        Assert.Null(rig.Recorder.Token);
        await rig.Work.Drain();
        Assert.Equal(1, rig.Take.Stops);
        Assert.False(rig.Take.Subscribed, "the delegate is let go (line 202)");
        Assert.False(File.Exists(rig.Take.File));
        Assert.Equal(2, rig.Session.Releases);
        // A refused second activation is the same failure (line 162).
        rig.Input.RecordAnswers.Enqueue(false);
        var again = rig.Recorder.BeginAsync();
        Assert.True(await Rig.Until(() => rig.Time.Pending == 1));
        rig.Session.Refuse = true;
        rig.Time.Advance(MemoRecorder.RetryPause);
        Assert.IsType<MemoBeginError.StartFailed>((await Assert.ThrowsAsync<MemoBeginException>(() => again)).Error);
        Assert.Single(rig.Take.Records);
    });

    [Fact]
    public Task LeavingDuringThePauseCancelsTheRetry() => MainLoop.Drive(async () =>
    {
        // Lines 149-160 (MemoPolicy.mayRetry): a trip to the background during the pause means no second try.
        var rig = new Rig(_stores);
        rig.Input.RecordAnswers.Enqueue(false);
        var begin = rig.Recorder.BeginAsync();
        Assert.True(await Rig.Until(() => rig.Time.Pending == 1));
        await rig.System.Raise(MemoSystemEvent.EnteredBackground);
        await Task.Delay(50);   // the event is posted to the UI thread
        rig.Time.Advance(MemoRecorder.RetryPause);
        Assert.IsType<MemoBeginError.Canceled>((await Assert.ThrowsAsync<MemoBeginException>(() => begin)).Error);
        Assert.Null(rig.Recorder.Token);
        Assert.Single(rig.Take.Records);
        Assert.Equal(1, rig.Session.Acquires);
        await rig.Work.Drain();
        Assert.Equal(1, rig.Take.Stops);
        // The app no longer in front when the pause ends: no retry either (line 155).
        rig.Input.RecordAnswers.Enqueue(false);
        var hidden = rig.Recorder.BeginAsync();
        Assert.True(await Rig.Until(() => rig.Time.Pending == 1));
        rig.Active = false;
        rig.Time.Advance(MemoRecorder.RetryPause);
        Assert.IsType<MemoBeginError.Canceled>((await Assert.ThrowsAsync<MemoBeginException>(() => hidden)).Error);
    });

    [Fact]
    public Task AnAppThatLeftWhileTheMicrophoneStartedIsBackground() => MainLoop.Drive(async () =>
    {
        // Lines 176-184: the recorder runs, but the app left the screen while it started: dropped, never shown red.
        var rig = new Rig(_stores);
        var begin = rig.Recorder.BeginAsync();
        rig.Active = false;
        Assert.IsType<MemoBeginError.Background>((await Assert.ThrowsAsync<MemoBeginException>(() => begin)).Error);
        Assert.Null(rig.Recorder.Token);
        Assert.False(rig.Recorder.IsRecording);
        await rig.Work.Drain();
        Assert.Equal(1, rig.Take.Stops);
        Assert.False(File.Exists(rig.Take.File));
        Assert.Equal(1, rig.Session.Releases);
    });

    // MARK: Levels

    [Fact]
    public Task LevelsTickAtFifteenHertzAndFeedTheWaveform() => MainLoop.Drive(async () =>
    {
        // Lines 299-304, 325-346: a level event per 1/15 s tick, metered on the audio queue (the reading the last tick
        // asked for), seconds with two decimals; one waveform sample per 100 ms, each the loudest of its window; the
        // saved memo's 48 peaks come from them (line 390, MemoPolicy.peaks).
        var rig = new Rig(_stores) { Input = { Power = -25 } };   // MemoPolicy.level: 0.5
        rig.Recorder.AccountKey = "acct0123456789ab";
        var started = await rig.Recorder.BeginAsync();
        await rig.Run(1);
        var levels = rig.Events.OfType<MemoCaptureEvent.Level>().ToArray();
        Assert.Equal(15, levels.Length);
        Assert.Equal(0, levels[0].Value);        // nothing metered yet: -160 dBFS
        Assert.All(levels.Skip(1), l => Assert.Equal(0.5, l.Value));
        Assert.Equal(0.07, levels[0].Seconds);
        Assert.Equal(1, levels[^1].Seconds);
        Assert.Equal(levels.Select(l => l.Seconds).OrderBy(s => s), levels.Select(l => l.Seconds));
        rig.Input.Power = 0;   // 1.0
        await rig.Run(1);
        rig.Input.Power = -50; // 0
        await rig.Run(1);
        var memo = await rig.Recorder.EndAsync(started.Id, MemoEndAction.Send);
        Assert.NotNull(memo);
        Assert.Equal(MemoWaveform.PeakCount, memo.Peaks.Count);
        Assert.Equal(1, memo.Peaks.Max());
        Assert.Equal(0.5, memo.Peaks[0]);
        Assert.Equal(0, memo.Peaks[^1]);
        rig.AssertOffTheUiThread();
        // No tick after the take ended (line 373).
        var count = rig.Events.Count;
        await rig.Run(1);
        Assert.Equal(count, rig.Events.Count);
        Assert.Equal(0, rig.Time.Pending);
    });

    // MARK: End

    [Fact]
    public Task CancelDeletesTheTake() => MainLoop.Drive(async () =>
    {
        // Lines 227-234, 449-454: cancel stops the recorder, deletes its file behind the stop and keeps nothing.
        var rig = new Rig(_stores);
        rig.Recorder.AccountKey = "acct0123456789ab";
        var started = await rig.Recorder.BeginAsync();
        await rig.Run(2);
        Assert.Null(await rig.Recorder.EndAsync(started.Id, MemoEndAction.Cancel));
        Assert.Null(rig.Recorder.Token);
        Assert.False(rig.Recorder.IsRecording);
        await rig.Work.Drain();
        Assert.Equal(1, rig.Take.Stops);
        Assert.False(File.Exists(rig.Take.File));
        Assert.False(Directory.Exists(_stores.Paths.Memos("acct0123456789ab")), "nothing saved");
        Assert.Equal(1, rig.Session.Releases);
        Assert.Empty(rig.Stops);
    });

    [Fact]
    public Task SaveMovesTheFinishedFileIntoTheAccountsFolder() => MainLoop.Drive(async () =>
    {
        // Lines 235-237, 383-416: the save waits for the recorder's stop (the file is complete), then moves it to
        // memos/<account>/<UUID>/voice-memo.m4a off the UI thread; seconds with two decimals; the temporary file is gone.
        var rig = new Rig(_stores);
        rig.Recorder.AccountKey = "acct0123456789ab";
        var started = await rig.Recorder.BeginAsync();
        await rig.Run(2.4);
        var memo = await rig.Recorder.EndAsync(started.Id, MemoEndAction.Review);
        Assert.NotNull(memo);
        var folder = Path.GetDirectoryName(memo.Path)!;
        Assert.Equal(_stores.Paths.Memos("acct0123456789ab"), Path.GetDirectoryName(folder));
        Assert.Equal("voice-memo.m4a", Path.GetFileName(memo.Path));
        Assert.True(Guid.TryParse(Path.GetFileName(folder), out _));
        Assert.Equal("audio/x-m4a", memo.Mime);
        Assert.Equal(2.4, memo.Seconds);
        Assert.Equal([1, 2, 3, 4, 5, 6, 7, 8], File.ReadAllBytes(memo.Path));   // written to the end before the move
        Assert.False(File.Exists(rig.Take.File));
        Assert.True(_stores.Guard.Protected(folder), "the new folder is protected (lines 402, 411)");
        Assert.Null(rig.Recorder.Token);
        Assert.Null(memo.Words);
        // No account: the "local" folder (line 391).
        rig.Recorder.AccountKey = null;
        var next = await rig.Recorder.BeginAsync();
        await rig.Run(1);
        var local = await rig.Recorder.EndAsync(next.Id, MemoEndAction.Draft);
        Assert.Equal(_stores.Paths.Memos("local"), Path.GetDirectoryName(Path.GetDirectoryName(local!.Path)));
    });

    [Fact]
    public Task FixtureRecorderStartsQuicklyAndSavesAWav() => MainLoop.Drive(async () =>
    {
        // MemoControllerTests.swift lines 155-173, with the fake input standing in for the simulator fixture (not
        // ported): the take starts with the 600 s limit, within 120 ms, and its send saves a 48-peak memo of about
        // 1.2 s; the recorder is idle after.
        var rig = new Rig(_stores);
        rig.Recorder.AccountKey = MemoPaths.AccountKey("recorder-test");
        var started = await rig.Recorder.BeginAsync();
        Assert.Equal(600, started.Limit);
        Assert.True(rig.Recorder.StartLatencyMs <= 120, $"start latency {rig.Recorder.StartLatencyMs} ms");
        await rig.Run(1.2);
        var file = await rig.Recorder.EndAsync(started.Id, MemoEndAction.Send);
        Assert.NotNull(file);
        Assert.Equal(MemoRecorder.Mime, file.Mime);   // the Mac's fixture says audio/wav; the real recorder m4a
        Assert.EndsWith(Path.DirectorySeparatorChar + "voice-memo.m4a", file.Path);
        Assert.Equal(48, file.Peaks.Count);
        Assert.True(file.Seconds >= 1.1 && file.Seconds < 2);
        Assert.True(File.Exists(file.Path));
        Assert.False(rig.Recorder.IsRecording);
    });

    [Fact]
    public Task AnEndedTakeCannotEndAgain() => MainLoop.Drive(async () =>
    {
        // Line 228.
        var rig = new Rig(_stores);
        var started = await rig.Recorder.BeginAsync();
        await rig.Recorder.EndAsync(started.Id, MemoEndAction.Cancel);
        var again = await Assert.ThrowsAsync<MemoSaveException>(() => rig.Recorder.EndAsync(started.Id, MemoEndAction.Send));
        Assert.Equal("that voice memo already ended", again.Message);
        Assert.Equal("that voice memo already ended", MemoRecorder.Reason(again));
        await Assert.ThrowsAsync<MemoSaveException>(() => rig.Recorder.EndAsync("someone-else", MemoEndAction.Send));
    });

    [Fact]
    public Task AnEmptyRecordingCannotBeSaved() => MainLoop.Drive(async () =>
    {
        // Lines 407-409: a recording with no bytes is "the recording is empty".
        var rig = new Rig(_stores) { Input = { WritesAudio = false } };
        var started = await rig.Recorder.BeginAsync();
        await rig.Run(2);
        var empty = await Assert.ThrowsAsync<MemoSaveException>(() => rig.Recorder.EndAsync(started.Id, MemoEndAction.Send));
        Assert.Equal("the recording is empty", MemoRecorder.Reason(empty));
        Assert.Null(rig.Recorder.Token);
        Assert.False(rig.Recorder.IsRecording);
    });

    // MARK: The system ends the take

    [Fact]
    public Task ACallEndsALongTakeAsADraftNeverASend() => MainLoop.Drive(async () =>
    {
        // Lines 240-257, 458-461 (MemoPolicy.finish): an interruption that began stops the take; a second or longer is
        // saved as a draft, and the event says so.
        var rig = new Rig(_stores);
        rig.Recorder.AccountKey = "acct0123456789ab";
        var started = await rig.Recorder.BeginAsync();
        await rig.Run(2.4);
        await rig.System.Raise(MemoSystemEvent.InterruptionBegan);
        Assert.True(await Rig.Until(() => rig.Stops.Count == 1));
        var stop = rig.Stops[0];
        Assert.Equal(MemoStopReason.Interrupted, stop.Reason);
        Assert.Equal(started.Id, stop.Id);
        Assert.Equal(2.4, stop.Seconds, 3);
        var draft = Assert.IsType<MemoStopDisposition.Draft>(stop.Disposition).Memo;
        Assert.True(File.Exists(draft.Path));
        Assert.StartsWith(_stores.Paths.Memos("acct0123456789ab"), draft.Path);
        Assert.Equal(2.4, draft.Seconds);
        Assert.Null(rig.Recorder.Token);
        Assert.False(rig.Recorder.IsRecording);
        Assert.Equal(1, rig.Session.Releases);
        // The end of the interruption, and any other route change, change nothing (began only, line 459).
        var recorder = new Rig(_stores);
        var other = await recorder.Recorder.BeginAsync();
        await recorder.System.Raise(MemoSystemEvent.InterruptionEnded);
        await recorder.System.Raise(MemoSystemEvent.RouteChanged);
        await Task.Delay(50);
        Assert.True(recorder.Recorder.IsRecording);
        Assert.Empty(recorder.Stops);
        await recorder.Recorder.EndAsync(other.Id, MemoEndAction.Cancel);
    });

    [Fact]
    public Task ALostHeadsetUnderASecondKeepsNothing() => MainLoop.Drive(async () =>
    {
        // Lines 258-262, 462-465: the old device went away; under a second there is nothing to keep, and its file goes.
        var rig = new Rig(_stores);
        var started = await rig.Recorder.BeginAsync();
        await rig.Run(0.6);
        await rig.System.Raise(MemoSystemEvent.OldDeviceUnavailable);
        Assert.True(await Rig.Until(() => rig.Stops.Count == 1));
        Assert.Equal(new MemoCaptureEvent.Stopped(MemoStopReason.RouteLost, started.Id, rig.Stops[0].Seconds,
            new MemoStopDisposition.Discard()), rig.Stops[0]);
        Assert.True(rig.Stops[0].Seconds < 1);
        Assert.Null(rig.Recorder.Token);
        await rig.Work.Drain();
        Assert.False(File.Exists(rig.Take.File));
    });

    [Fact]
    public Task MediaServicesResettingAndLeavingTheAppEndTheTake() => MainLoop.Drive(async () =>
    {
        // Lines 466-471: the session's bookkeeping is reset and the take ends (`reset`); lines 472-474: the app left
        // the screen (`background`). Both keep a long take as a draft.
        var rig = new Rig(_stores);
        await rig.Recorder.BeginAsync();
        await rig.Run(1.2);
        await rig.System.Raise(MemoSystemEvent.MediaServicesReset);
        Assert.True(await Rig.Until(() => rig.Stops.Count == 1));
        Assert.Equal(1, rig.Session.Resets);
        Assert.Equal(MemoStopReason.Reset, rig.Stops[0].Reason);
        Assert.IsType<MemoStopDisposition.Draft>(rig.Stops[0].Disposition);

        await rig.Recorder.BeginAsync();
        await rig.Run(3);
        await rig.System.Raise(MemoSystemEvent.EnteredBackground);
        Assert.True(await Rig.Until(() => rig.Stops.Count == 2));
        Assert.Equal(MemoStopReason.Background, rig.Stops[1].Reason);
        Assert.IsType<MemoStopDisposition.Draft>(rig.Stops[1].Disposition);
        // Nothing is observed once the take ended (lines 379-380).
        await rig.System.Raise(MemoSystemEvent.MediaServicesReset);
        await Task.Delay(50);
        Assert.Equal(1, rig.Session.Resets);
        Assert.Equal(2, rig.Stops.Count);
    });

    [Fact]
    public Task TheLimitWaitsForTheReleaseRule() => MainLoop.Drive(async () =>
    {
        // Lines 244-246, 478-484, 296: the recorder finished by itself at its duration: the take stops (the clock caps
        // at the limit) and stays open for `end`, which then saves it.
        var rig = new Rig(_stores) { Limit = 10 };
        var started = await rig.Recorder.BeginAsync();
        await rig.Run(10.6);
        await rig.Take.Finish(successfully: true);
        Assert.True(await Rig.Until(() => rig.Stops.Count == 1));
        var stop = rig.Stops[0];
        Assert.Equal(MemoStopReason.Limit, stop.Reason);
        Assert.Equal(10, stop.Seconds);
        Assert.IsType<MemoStopDisposition.Await>(stop.Disposition);
        Assert.Equal(started.Id, rig.Recorder.Token);
        Assert.False(rig.Recorder.IsRecording);
        Assert.Equal(10, rig.Events.OfType<MemoCaptureEvent.Level>().Last().Seconds);
        // A second stop changes nothing (line 241).
        rig.Recorder.NativeStop(MemoStopReason.Interrupted);
        Assert.Single(rig.Stops);
        var memo = await rig.Recorder.EndAsync(started.Id, MemoEndAction.Send);
        Assert.Equal(10, memo!.Seconds);
        Assert.Single(rig.Take.Records);
    });

    [Fact]
    public Task AnEncodingFailureEndsTheTakeAsAnError() => MainLoop.Drive(async () =>
    {
        // Lines 478-496: a recorder that finished unsuccessfully, or failed to encode, ends the take with `error`
        // (a draft once a second long).
        var rig = new Rig(_stores);
        await rig.Recorder.BeginAsync();
        await rig.Run(1.6);
        await rig.Take.FailEncoding();
        Assert.True(await Rig.Until(() => rig.Stops.Count == 1));
        Assert.Equal(MemoStopReason.Error, rig.Stops[0].Reason);
        Assert.IsType<MemoStopDisposition.Draft>(rig.Stops[0].Disposition);

        await rig.Recorder.BeginAsync();
        await rig.Run(0.4);
        await rig.Take.Finish(successfully: false);
        Assert.True(await Rig.Until(() => rig.Stops.Count == 2));
        Assert.Equal(MemoStopReason.Error, rig.Stops[1].Reason);
        Assert.IsType<MemoStopDisposition.Discard>(rig.Stops[1].Disposition);
    });

    [Fact]
    public Task OnlyTheRecorderRecordingNowMayEndTheTake() => MainLoop.Drive(async () =>
    {
        // Lines 482, 492: a callback from an earlier take's recorder (already let go) never ends the current take.
        var rig = new Rig(_stores);
        var first = await rig.Recorder.BeginAsync();
        var old = rig.Take;
        await rig.Recorder.EndAsync(first.Id, MemoEndAction.Cancel);
        var second = await rig.Recorder.BeginAsync();
        Assert.NotSame(old, rig.Take);
        // The earlier recorder's delegate was let go (line 359); even a late call into the handler is ignored.
        Assert.False(old.Subscribed);
        await rig.Take.Finish(successfully: true);   // the current one: ends at its limit
        Assert.True(await Rig.Until(() => rig.Stops.Count == 1));
        Assert.Equal(second.Id, rig.Stops[0].Id);
    });

    [Fact]
    public Task ADraftThatCannotBeSavedSaysWhy() => MainLoop.Drive(async () =>
    {
        // Lines 254-256: a system stop whose save failed reports `failed` with the words.
        var rig = new Rig(_stores) { Input = { WritesAudio = false } };
        await rig.Recorder.BeginAsync();
        await rig.Run(2);
        await rig.System.Raise(MemoSystemEvent.InterruptionBegan);
        Assert.True(await Rig.Until(() => rig.Stops.Count == 1));
        Assert.Equal(new MemoStopDisposition.Failed("the recording is empty"), rig.Stops[0].Disposition);
    });

    // MARK: MemoControllerTests.swift (the recorder's words)

    [Fact]
    public void StartAndSaveReasonsAreWords()
    {
        // MemoControllerTests.swift lines 134-141: an audio session's code is said in words, never shown bare.
        var held = new IOException("OSStatus") { HResult = 561_017_449 };
        Assert.Equal("a call or another app is using the microphone", MemoRecorder.StartReason(held));
        Assert.Equal("Couldn’t start the voice memo: a call or another app is using the microphone.",
            new MemoBeginError.StartFailed(MemoRecorder.StartReason(held)).Message);
        Assert.Equal("the microphone didn’t start", MemoRecorder.StartReason(new IOException("x") { HResult = -50 }));
        Assert.Equal("", MemoRecorder.Reason(new IOException("x") { HResult = 2_003_334_207 }));
        Assert.Equal("the file is empty", MemoRecorder.Reason(MemoRecorder.SaveError("the file is empty")));
        // Line 444's other two codes, and the Windows one (AUDCLNT_E_DEVICE_IN_USE).
        foreach (var code in new[] { 560_557_684, 561_145_187, unchecked((int)0x8889000A) })
            Assert.Equal("a call or another app is using the microphone", MemoRecorder.MicrophoneWords(code));
        // Line 435: the recorder's own words pass through.
        Assert.Equal("the recording is empty", MemoRecorder.StartReason(MemoRecorder.SaveError("the recording is empty")));
    }

    [Fact]
    public void BeginErrorsCarryTheirCodesAndWords()
    {
        // MemoTypes.swift's MemoBeginError, as the recorder throws it (lines 86-99, 140, 159, 170, 183).
        Assert.Equal(new MemoInput.BeginFailed("busy", null, null), new MemoBeginError.Busy().Input);
        Assert.Equal(new MemoInput.BeginFailed("background", null, null), new MemoBeginError.Background().Input);
        Assert.Equal(new MemoInput.BeginFailed("permission-pending", true, null), new MemoBeginError.PermissionPending(true).Input);
        Assert.Equal(new MemoInput.BeginFailed("permission-denied", null, null), new MemoBeginError.PermissionDenied().Input);
        Assert.Equal(new MemoInput.BeginFailed("too-small", null, "The attachment size limit is too small for a voice memo."),
            new MemoBeginError.TooSmall().Input);
        Assert.Equal(new MemoInput.BeginFailed("start-failed", null, "Couldn’t start the voice memo: the microphone did not start recording."),
            new MemoBeginError.StartFailed("the microphone did not start recording").Input);
        Assert.Equal(new MemoInput.BeginFailed("canceled", null, null), new MemoBeginError.Canceled().Input);
        Assert.Equal("busy", new MemoBeginException(new MemoBeginError.Busy()).Message);
    }

    [Fact]
    public void ThePolicysRecorderRules()
    {
        // MemoPolicy.swift lines 21-23 (mayRetry), 26 (level), 30-38 (peaks), 63 (twoDecimals).
        Assert.True(MemoPolicy.MayRetry(true, false, true, false));
        Assert.False(MemoPolicy.MayRetry(false, false, true, false));
        Assert.False(MemoPolicy.MayRetry(true, true, true, false));
        Assert.False(MemoPolicy.MayRetry(true, false, false, false));
        Assert.False(MemoPolicy.MayRetry(true, false, true, true));
        Assert.Equal(0, MemoPolicy.Level(-160));
        Assert.Equal(0.5, MemoPolicy.Level(-25));
        Assert.Equal(1, MemoPolicy.Level(3));
        Assert.Equal(new double[48], MemoPolicy.Peaks([]));
        Assert.Empty(MemoPolicy.Peaks([0.5], 0));
        double[] samples = [0.1, 0.2345, 0.9, 0.3, 0.12345];
        Assert.Equal(VoiceFixtures.Peaks(samples), MemoPolicy.Peaks(samples));
        Assert.Equal(VoiceFixtures.Peaks(samples, 3), MemoPolicy.Peaks(samples, 3));
        Assert.All(MemoPolicy.Peaks([0.2345]), p => Assert.Equal(0.235, p));   // a short memo fills the bubble
        Assert.Equal(1.24, MemoPolicy.TwoDecimals(1.235));
        Assert.Equal(2.5, MemoPolicy.TwoDecimals(2.4999999));
    }

    // MARK: MemoCaptureLink (MemoController.swift's recorder half, driving MemoSession)

    private static (MemoSession Session, MemoCaptureLink Link, List<MemoEffect> Effects) Linked(Rig rig, bool sendOnRelease = true)
    {
        var link = new MemoCaptureLink(rig.Recorder, () => rig.Time.GetTimestamp() / 10_000.0);
        var effects = new List<MemoEffect>();
        var session = new MemoSession(link, () => sendOnRelease, effects.Add);
        link.Attach(session);
        return (session, link, effects);
    }

    private static double Ms(Rig rig) => rig.Time.GetTimestamp() / 10_000.0;

    [Fact]
    public Task AHeldTakeSendsOnReleaseWithItsFile() => MainLoop.Drive(async () =>
    {
        // MemoController.swift begin() 293-327 and end(_:before:) 329-394 with the real recorder: the press begins,
        // red only once the recorder started; levels tick the clock (captured 421-445); the release sends the saved file.
        var rig = new Rig(_stores);
        var (session, link, _) = Linked(rig);
        var saved = new List<(MemoEndAction, MemoFile)>();
        link.Saved += (action, file) => saved.Add((action, file));
        session.Input(new MemoInput.Down(Ms(rig), 402));
        Assert.Equal(MemoPhase.Pressing, session.State.Phase);
        Assert.True(await Rig.Until(() => session.State.Phase == MemoPhase.Holding));
        Assert.Equal(rig.Recorder.Token, link.TakeId);
        Assert.Equal(600, link.Limit);
        await rig.Run(2.2);
        Assert.Equal(2, Math.Floor(session.State.Seconds));
        session.Input(new MemoInput.Up(Ms(rig)));
        Assert.True(await Rig.Until(() => session.State.Phase == MemoPhase.Idle && saved.Count == 1));
        Assert.Equal(MemoEndAction.Send, saved[0].Item1);
        Assert.True(File.Exists(saved[0].Item2.Path));
        Assert.Null(link.TakeId);
        Assert.Null(rig.Recorder.Token);
    });

    [Fact]
    public Task ASystemStopLeavesADraftThroughTheLink() => MainLoop.Drive(async () =>
    {
        // MemoControllerTests.swift lines 64-70 (the recorder's half): an interruption while holding returns the
        // gesture to idle and hands the page the draft. Never a send.
        var rig = new Rig(_stores);
        var (session, link, effects) = Linked(rig);
        var stops = new List<MemoCaptureEvent.Stopped>();
        var saved = 0;
        link.Stopped += stops.Add;
        link.Saved += (_, _) => saved++;
        session.Input(new MemoInput.Down(Ms(rig), 402));
        Assert.True(await Rig.Until(() => session.State.Phase == MemoPhase.Holding));
        await rig.Run(12.4);
        await rig.System.Raise(MemoSystemEvent.InterruptionBegan);
        Assert.True(await Rig.Until(() => stops.Count == 1));
        Assert.Equal(MemoPhase.Idle, session.State.Phase);
        var draft = Assert.IsType<MemoStopDisposition.Draft>(stops[0].Disposition).Memo;
        Assert.Equal(12.4, draft.Seconds, 2);
        Assert.Null(link.TakeId);
        Assert.Equal(0, saved);
        Assert.DoesNotContain(effects, e => e is MemoEffect.SendReviewed);
    });

    [Fact]
    public Task SlidingAwayCancelsAndKeepsNothing() => MainLoop.Drive(async () =>
    {
        // MemoControllerTests.swift lines 87-93 (the recorder's half): slide to cancel ends the take with `cancel`.
        var rig = new Rig(_stores);
        var (session, link, _) = Linked(rig);
        var saved = 0;
        link.Saved += (_, _) => saved++;
        session.Input(new MemoInput.Down(Ms(rig), 402));
        Assert.True(await Rig.Until(() => session.State.Phase == MemoPhase.Holding));
        await rig.Run(1.6);
        session.Input(new MemoInput.Move(-200, 0));
        session.Input(new MemoInput.Up(Ms(rig)));
        Assert.True(await Rig.Until(() => session.State.Phase == MemoPhase.Idle));
        await rig.Work.Drain();
        Assert.Equal(0, saved);
        Assert.Null(rig.Recorder.Token);
        Assert.False(File.Exists(rig.Take.File));
    });

    [Fact]
    public Task AFailedBeginReachesTheGesture() => MainLoop.Drive(async () =>
    {
        // MemoController.swift lines 320-325: a begin that throws answers `beginFailed` with its code and words.
        var rig = new Rig(_stores) { Input = { Permission = MemoMicPermission.Denied } };
        var (session, _, effects) = Linked(rig);
        session.Input(new MemoInput.Down(Ms(rig), 402));
        Assert.True(await Rig.Until(() => effects.OfType<MemoEffect.Failed>().Any()));
        Assert.Equal("permission-denied", effects.OfType<MemoEffect.Failed>().Single().Code);
        Assert.Equal(MemoPhase.Idle, session.State.Phase);
    });

    [Fact]
    public Task AStartThatLandsAfterTheGestureLeftIsEnded() => MainLoop.Drive(async () =>
    {
        // MemoController.swift lines 302-318, 627-633: a reset while the recorder started drops the take once it
        // lands; a reset while recording ends it with `cancel`.
        var rig = new Rig(_stores);
        var (session, link, _) = Linked(rig);
        session.Input(new MemoInput.Down(Ms(rig), 402));
        link.Reset();
        session.Input(new MemoInput.Reset());
        Assert.True(await Rig.Until(() => rig.Input.Made.Count == 1 && rig.Recorder.Token == null));
        await rig.Work.Drain();
        Assert.Equal(1, rig.Take.Stops);
        Assert.Equal(MemoPhase.Idle, session.State.Phase);

        session.Input(new MemoInput.Down(Ms(rig), 402));
        Assert.True(await Rig.Until(() => session.State.Phase == MemoPhase.Holding));
        link.Reset();
        Assert.True(await Rig.Until(() => rig.Recorder.Token == null));
        Assert.Null(link.TakeId);
    });
}
