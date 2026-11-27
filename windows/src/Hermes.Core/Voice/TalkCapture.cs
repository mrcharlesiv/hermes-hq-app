namespace Hermes.Core.Voice;

// Port of HermesKit/Voice/TalkCapture.swift plus cross-platform capture core, speaker,
// and live-transport interfaces so Windows audio hardware and xUnit tests share one core.

public sealed record TalkTake(byte[] WavBytes, double DurationSeconds, string? LiveWords = null);

public enum TalkCaptureError
{
    PermissionDenied,
    DeviceUnavailable,
    Busy,
    Failed,
    MeterStalled,
}

public sealed class TalkCaptureException(TalkCaptureError error, string message) : Exception(message)
{
    public TalkCaptureError Error { get; } = error;
}

public interface ITalkCapturing : IDisposable
{
    bool IsCapturing { get; }
    bool IsMuted { get; set; }
    bool BargeInEnabled { get; set; }
    int SampleRate { get; }

    event Action<double>? LevelChanged;
    event Action? SpeechStarted;
    event Action<TalkTake>? TakeCompleted;
    event Action? BargeInDetected;
    event Action<short[]>? PcmCaptured;
    event Action<TalkCaptureError, string>? Failed;

    Task StartAsync(CancellationToken ct = default);
    TalkTake? FlushNow();
    void Stop();
}

/// Pure PCM processing core for Talk capture (pre-roll, VAD endpointing, barge-in detection,
/// WAV encoding, and meter stall detection). Driven by Windows waveIn callbacks or unit tests.
public sealed class TalkCaptureCore
{
    public const int DefaultSampleRate = 16000;
    public const double MeterStallSeconds = 4.0;

    private readonly object _gate = new();
    private readonly List<short> _recorded = [];
    private readonly PreRoll _preRoll;

    public int SampleRate { get; }
    public TakeEndpoint Endpoint { get; } = new();
    public BargeMonitor Barge { get; } = new();

    public bool IsMuted { get; set; }
    public bool BargeInEnabled { get; set; }
    public bool MonitoringBargeOnly { get; set; }

    public event Action<double>? LevelChanged;
    public event Action? SpeechStarted;
    public event Action<TalkTake>? TakeCompleted;
    public event Action? BargeInDetected;
    public event Action<short[]>? PcmCaptured;

    public TalkCaptureCore(int sampleRate = DefaultSampleRate, int preRollMs = 350)
    {
        SampleRate = sampleRate;
        _preRoll = new PreRoll(Math.Max(1, sampleRate * preRollMs / 1000));
    }

    public void Feed(short[] pcm)
    {
        if (pcm.Length == 0 || IsMuted) return;

        var rms = TalkLevel.Rms(pcm);
        var level = TalkLevel.Level(rms);
        var dtMs = pcm.Length * 1000.0 / SampleRate;

        LevelChanged?.Invoke(level);
        PcmCaptured?.Invoke(pcm);

        if (MonitoringBargeOnly)
        {
            if (BargeInEnabled && Barge.Feed(rms, dtMs))
                BargeInDetected?.Invoke();
            return;
        }

        TalkTake? completed = null;
        var startedNow = false;
        lock (_gate)
        {
            var wasSpeaking = Endpoint.HeardSpeech;
            var result = Endpoint.Feed(rms, dtMs);
            if (!wasSpeaking && Endpoint.HeardSpeech)
            {
                startedNow = true;
                _recorded.Clear();
                _recorded.AddRange(_preRoll.Drain());
                _recorded.AddRange(pcm);
            }
            else if (result == EndpointResult.Listening)
            {
                _preRoll.Push(pcm);
            }
            else if (result == EndpointResult.Speaking)
            {
                _recorded.AddRange(pcm);
            }
            else if (result is EndpointResult.Ended or EndpointResult.TimedOut)
            {
                _recorded.AddRange(pcm);
                completed = BuildTakeLocked();
                ResetLocked();
            }
            else if (result == EndpointResult.TooShort)
            {
                ResetLocked();
            }
        }

        if (startedNow) SpeechStarted?.Invoke();
        if (completed != null) TakeCompleted?.Invoke(completed);
    }

    public TalkTake? FlushNow()
    {
        TalkTake? take = null;
        lock (_gate)
        {
            if (_recorded.Count > 0)
                take = BuildTakeLocked();
            ResetLocked();
        }
        return take;
    }

    public void Reset()
    {
        lock (_gate) ResetLocked();
    }

    private TalkTake BuildTakeLocked()
    {
        var arr = _recorded.ToArray();
        var wav = TalkWave.EncodeWav(arr, SampleRate, channels: 1);
        var seconds = arr.Length / (double)SampleRate;
        return new TalkTake(wav, MemoPolicy.TwoDecimals(seconds));
    }

    private void ResetLocked()
    {
        _recorded.Clear();
        _preRoll.Clear();
        Endpoint.Reset();
        Barge.Reset();
    }
}

public enum TalkSpeechOutcome { Completed, Cancelled, Failed }

public interface ITalkSpeaker : IDisposable
{
    bool IsSpeaking { get; }
    event Action<double>? LevelChanged;

    Task<TalkSpeechOutcome> SpeakAsync(string text, Func<string, CancellationToken, Task<SpeechClip>>? gatewaySpeak,
        CancellationToken ct = default);
    void PlayPcmChunk(ReadOnlySpan<byte> pcm24k);
    void FlushPcm();
    void Stop();
}

public sealed class LiveVoiceException(string message, bool fatal = false) : Exception(message)
{
    public bool Fatal { get; } = fatal;
}

public interface ILiveVoiceTransport : IAsyncDisposable
{
    event Action<LiveServerEvent>? EventReceived;

    Task ConnectAsync(TalkEngine engine, VoiceLease? gptLease, GrokLiveSession? grokSession, string instructions,
        CancellationToken ct = default);
    Task SendAudioAsync(ReadOnlyMemory<byte> pcm24k, CancellationToken ct = default);
    Task SendControlAsync(string json, CancellationToken ct = default);
    Task CloseAsync(CancellationToken ct = default);
}
