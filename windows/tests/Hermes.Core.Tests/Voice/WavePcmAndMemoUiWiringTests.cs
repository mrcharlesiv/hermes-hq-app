using Hermes.Core.Composer;
using Hermes.Core.Transcripts;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests.Voice;

public sealed class WavePcmAndMemoUiWiringTests : IDisposable
{
    private readonly string _tempDir = Path.Combine(Path.GetTempPath(), $"hq-wave-tests-{Guid.NewGuid():N}");

    public WavePcmAndMemoUiWiringTests() => Directory.CreateDirectory(_tempDir);

    public void Dispose()
    {
        MemoDisk.Flush();
        try { if (Directory.Exists(_tempDir)) Directory.Delete(_tempDir, recursive: true); } catch (IOException) { }
    }

    [Fact]
    public void TalkWaveEncodeDecodeRoundTripAndMemoWaveformComputeProduceValidPeaks()
    {
        const int rate = 16000;
        var samples = new short[rate]; // 1.0 second sine wave
        for (var i = 0; i < samples.Length; i++)
        {
            var env = i < rate / 2 ? 0.35 : 0.9;
            samples[i] = (short)Math.Round(env * 28000 * Math.Sin(2 * Math.PI * 440 * i / rate));
        }

        var wav = TalkWave.EncodeWav(samples, rate, channels: 1);
        Assert.Equal(TalkWave.HeaderSize + samples.Length * 2, wav.Length);

        var (decoded, decodedRate, channels) = TalkWave.DecodePcm16(wav);
        Assert.Equal(rate, decodedRate);
        Assert.Equal(1, channels);
        Assert.Equal(samples, decoded);

        // Verify compatibility with existing WavMemoAudio & MemoWaveform.Compute
        var path = Path.Combine(_tempDir, "roundtrip.wav");
        File.WriteAllBytes(path, wav);
        var computed = MemoWaveform.Compute(path, WavMemoAudio.Decoder);
        Assert.Equal(MemoWaveform.PeakCount, computed.Peaks.Count);
        Assert.InRange(computed.Seconds, 0.99, 1.01);
        Assert.True(computed.Peaks.Max() >= 0.99);
        Assert.True(computed.Peaks[0] < computed.Peaks[^1]);
    }

    [Fact]
    public void TalkWaveStreamingHeaderPatchAndResamplingWork()
    {
        var path = Path.Combine(_tempDir, "streamed.wav");
        short[] pcm = [0, 12000, -12000, 24000, -24000, 6000];
        var bytes = new byte[pcm.Length * 2];
        Buffer.BlockCopy(pcm, 0, bytes, 0, bytes.Length);

        using (var fs = new FileStream(path, FileMode.Create, FileAccess.ReadWrite))
        {
            TalkWave.WriteWavHeader(fs, 24000, 1, 16, 0);
            fs.Write(bytes);
            TalkWave.PatchWavHeader(fs, bytes.Length);
        }

        var (decoded, rate, ch) = TalkWave.DecodePcm16(File.ReadAllBytes(path));
        Assert.Equal(24000, rate);
        Assert.Equal(1, ch);
        Assert.Equal(pcm, decoded);

        var floats = TalkWave.Pcm16ToFloat(pcm);
        var back = TalkWave.FloatToPcm16(floats);
        for (var i = 0; i < pcm.Length; i++) Assert.InRange(Math.Abs(pcm[i] - back[i]), 0, 2);

        var upsampled = TalkWave.ResampleLinear(new short[160], 16000, 24000);
        Assert.Equal(240, upsampled.Length);
    }

    [Fact]
    public void TalkVadPreRollBargeMonitorAndTalkCaptureCoreDetectUtterance()
    {
        var preRoll = new PreRoll(capacitySamples: 4);
        preRoll.Push([1, 2, 3]);
        preRoll.Push([4, 5]);
        Assert.Equal([2, 3, 4, 5], preRoll.Drain());
        Assert.Equal(0, preRoll.Count);

        var barge = new BargeMonitor { Threshold = 0.05, RequiredMs = 200 };
        Assert.False(barge.Feed(0.08, 100));
        Assert.True(barge.Feed(0.08, 120));

        var core = new TalkCaptureCore(sampleRate: 16000, preRollMs: 50);
        core.Endpoint.MinSpeechMs = 100;
        core.Endpoint.SilenceEndMs = 200;

        var started = 0;
        TalkTake? completed = null;
        core.SpeechStarted += () => started++;
        core.TakeCompleted += t => completed = t;

        var quiet = new short[800]; // 50ms silence
        var loud = Enumerable.Range(0, 800).Select(i => (short)(14000 * Math.Sin(i * 0.2))).ToArray();

        core.Feed(quiet); // goes into pre-roll
        core.Feed(loud);  // starts speech
        core.Feed(loud);
        core.Feed(loud);  // 150ms speech
        Assert.Equal(1, started);

        // 250ms silence triggers take completion
        for (var i = 0; i < 5; i++) core.Feed(quiet);

        Assert.NotNull(completed);
        Assert.True(completed!.WavBytes.Length > TalkWave.HeaderSize);
        Assert.True(completed.DurationSeconds >= 0.25);
        var (_, wavRate, _) = TalkWave.DecodePcm16(completed.WavBytes);
        Assert.Equal(16000, wavRate);
    }

    private sealed class WavFormatInput : IMemoAudioInput, IMemoAudioFormat
    {
        public string Mime => "audio/wav";
        public string Extension => "wav";
        public MemoMicPermission Permission => MemoMicPermission.Granted;
        public Task<bool> RequestPermissionAsync() => Task.FromResult(true);
        public IMemoAudioTake Create(string file) => new FakeWavTake(file);
    }

    private sealed class FakeWavTake(string file) : IMemoAudioTake
    {
        public bool Record(double seconds)
        {
            File.WriteAllBytes(file, TalkWave.EncodeWav([500, -500, 1000, -1000], MemoRecorder.SampleRate));
            return true;
        }
        public bool Prepare() => true;
        public float AveragePower() => -15f;
        public void Stop() { }
        public event Action<IMemoAudioTake, bool>? Finished { add { } remove { } }
        public event Action<IMemoAudioTake>? EncodeError { add { } remove { } }
    }

    private sealed class SyncContext : SynchronizationContext
    {
        public override void Post(SendOrPostCallback d, object? state) => d(state);
    }

    private sealed class MemPrefs : IPreferences
    {
        private readonly Dictionary<string, string> _map = [];
        public string? Get(string key) => _map.TryGetValue(key, out var v) ? v : null;
        public void Set(string key, string? value) { if (value == null) _map.Remove(key); else _map[key] = value; }
    }

    private sealed class MemKv : IKeyValueStore
    {
        private readonly Dictionary<string, string> _map = [];
        public string? Get(string key) => _map.TryGetValue(key, out var v) ? v : null;
        public void Set(string key, string? value) { if (value == null) _map.Remove(key); else _map[key] = value; }
    }

    [Fact]
    public async Task MemoRecorderHonorsIMemoAudioFormatAndMemoAppWiringSavesWavEndToEnd()
    {
        var paths = new MemoPaths(Path.Combine(_tempDir, "support"), Path.Combine(_tempDir, "cache"));
        var ctx = new SyncContext();
        var wiring = MemoAppWiring.Build(
            paths,
            new WavFormatInput(),
            new FakeMemoOutput(),
            new FakeMemoSystem(),
            new MemPrefs(),
            new MemKv(),
            () => true,
            context: ctx);
        wiring.SignedIn("acct-wav");
        Assert.True(wiring.IsActive);

        var recorder = new MemoRecorder(
            new WavFormatInput(),
            new MemoAudioSessions().Recording,
            new FakeMemoSystem(),
            paths,
            () => true,
            temporaryFolder: Path.Combine(_tempDir, "tmp"),
            context: ctx)
        { AccountKey = wiring.Stores.Key };
        Directory.CreateDirectory(Path.Combine(_tempDir, "tmp"));

        var start = await recorder.BeginAsync();
        var saved = await recorder.EndAsync(start.Id, MemoEndAction.Send);

        Assert.NotNull(saved);
        Assert.Equal("audio/wav", saved!.Mime);
        Assert.EndsWith(".wav", saved.Path, StringComparison.OrdinalIgnoreCase);
        Assert.True(File.Exists(saved.Path));
    }

    [Fact]
    public void VoiceUiMathComputesMemoBubbleWaveformsSpeedLabelsLiveWavesAndTalkIntro()
    {
        Assert.Equal("1×", MemoBubbleLayout.SpeedLabel(1.0));
        Assert.Equal("1.5×", MemoBubbleLayout.SpeedLabel(1.5));
        Assert.Equal("2×", MemoBubbleLayout.SpeedLabel(2.0));
        Assert.Equal(0.5, MemoBubbleLayout.ClampFraction(50, 100), 3);
        Assert.Equal(0.0, MemoBubbleLayout.ClampFraction(-10, 100), 3);

        var heights = MemoBubbleLayout.BarHeights([0.0, 0.5, 1.0], count: 48, minHeight: 3, maxHeight: 24);
        Assert.Equal(48, heights.Length);
        Assert.All(heights, h => Assert.InRange(h, 3, 24));
        Assert.True(heights[^1] > heights[0]);

        var liveWave = MemoLiveWaveMath.Shape([0.2, 0.8, 1.0], visibleBars: 10, minHeight: 3, maxHeight: 26);
        Assert.Equal(10, liveWave.Length);
        Assert.Equal(3.0, liveWave[0]);
        Assert.Equal(26.0, liveWave[^1]);

        var dictBars = DictationBarsMath.Heights(0.75, phaseSeconds: 0.4);
        Assert.Equal(5, dictBars.Length);
        Assert.All(dictBars, h => Assert.InRange(h, 4, 20));

        var talkBars = TalkVisualMath.BarHeights(0.6, phaseSeconds: 0.2);
        Assert.Equal(5, talkBars.Length);
        var dots = TalkVisualMath.DotOpacities(0.5, count: 3);
        Assert.Equal(3, dots.Length);
        Assert.All(dots, o => Assert.InRange(o, 0.3, 1.0));

        var introRows = TalkIntroModel.Rows("Ivy", isLiveOffered: true);
        Assert.Equal(4, introRows.Count);
        Assert.Equal("Talk with Ivy", TalkIntroModel.Title("Ivy"));
        Assert.Contains("Ivy", introRows[0].Detail);
    }
}
