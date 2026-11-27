// [WIN-VOICE-PLAYER] Headless stand-ins for the memo player's seams: an output that "opens" a WAV off the test thread
// (as AVAudioPlayer(contentsOf:) on the audio queue: a RIFF/WAVE header gives its duration, anything else throws, as
// the Mac's unreadable-file case), the audio session as memo playback holds it, and the system's audio events.
// Synthetic data only.

using Hermes.Core.Voice;

namespace Hermes.Core.Tests.Voice;

internal sealed class FakeMemoTrack(string file, double duration) : IMemoAudioTrack
{
    public string File { get; } = file;
    public double Duration { get; } = duration;
    public double CurrentTime { get; set; }
    public double Rate { get; set; } = 1;
    public bool Playing { get; private set; }
    public bool Stopped { get; private set; }
    public int Plays { get; private set; }
    public bool PlayResult { get; set; } = true;

    public bool Play()
    {
        Plays++;
        Playing = PlayResult;
        return PlayResult;
    }

    public void Pause() => Playing = false;

    public void Stop()
    {
        Playing = false;
        Stopped = true;
    }

    public event Action<IMemoAudioTrack, bool>? Finished;
    public event Action<IMemoAudioTrack>? DecodeError;

    public bool Subscribed => Finished != null || DecodeError != null;

    /// The delegate's callbacks come from the audio thread.
    public Task Finish(bool successfully = true) => Task.Run(() => Finished?.Invoke(this, successfully));
    public Task FailDecode() => Task.Run(() => DecodeError?.Invoke(this));
}

internal sealed class FakeMemoOutput : IMemoAudioOutput
{
    private readonly object _gate = new();
    private readonly List<Task> _work = [];
    private readonly List<FakeMemoTrack> _opened = [];

    /// How long building and priming a player takes (the window a stop or another memo can land in).
    public TimeSpan OpenDelay { get; set; } = TimeSpan.FromMilliseconds(50);
    /// What the next opened tracks answer to Play().
    public bool PlayResult { get; set; } = true;

    public IReadOnlyList<FakeMemoTrack> Opened { get { lock (_gate) return _opened.ToArray(); } }

    public Task<IMemoAudioTrack> OpenAsync(string file)
    {
        var delay = OpenDelay;
        var plays = PlayResult;
        var work = Task.Run<IMemoAudioTrack>(async () =>
        {
            await Task.Delay(delay);
            var track = new FakeMemoTrack(file, WaveSeconds(System.IO.File.ReadAllBytes(file))) { PlayResult = plays };
            lock (_gate) _opened.Add(track);
            return track;
        });
        lock (_gate) _work.Add(work);
        return work;
    }

    /// AudioWork.drain: everything sent to the audio side so far has run.
    public async Task Drain()
    {
        Task[] work;
        lock (_gate) work = _work.ToArray();
        try { await Task.WhenAll(work); } catch (Exception) { }
    }

    /// A 16-bit PCM WAV's length; anything else isn't audio.
    private static double WaveSeconds(byte[] data)
    {
        if (data.Length < 44 || System.Text.Encoding.ASCII.GetString(data, 0, 4) != "RIFF"
            || System.Text.Encoding.ASCII.GetString(data, 8, 4) != "WAVE")
            throw new InvalidDataException("The operation couldn’t be completed. (OSStatus error 1954115647.)");
        var rate = BitConverter.ToInt32(data, 24);
        var bytesPerSecond = BitConverter.ToInt32(data, 28);
        var size = BitConverter.ToInt32(data, 40);
        return rate <= 0 || bytesPerSecond <= 0 ? 0 : (double)size / bytesPerSecond;
    }
}

internal sealed class FakeMemoSession : IMemoAudioSession
{
    private int _acquires, _releases, _resets;
    public Action? PlaybackPreempted { get; set; }
    /// The next acquires throw (a call holds the session).
    public bool Refuse { get; set; }
    /// How long activation takes on the audio queue.
    public TimeSpan AcquireDelay { get; set; } = TimeSpan.FromMilliseconds(10);
    public int Acquires => Volatile.Read(ref _acquires);
    public int Releases => Volatile.Read(ref _releases);
    public int Resets => Volatile.Read(ref _resets);

    public async Task AcquireAsync()
    {
        Interlocked.Increment(ref _acquires);
        var refuse = Refuse;
        await Task.Delay(AcquireDelay);   // activated on the audio queue
        if (refuse) throw new InvalidOperationException("Session activation failed");
    }

    public void Release() => Interlocked.Increment(ref _releases);
    public void Reset() => Interlocked.Increment(ref _resets);
}

internal sealed class FakeMemoSystem : IMemoSystemEvents
{
    public event Action<MemoSystemEvent>? Raised;
    /// The system posts from its own thread.
    public Task Raise(MemoSystemEvent e) => Task.Run(() => Raised?.Invoke(e));
}
