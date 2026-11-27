using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Transcripts;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests.Voice;

public sealed class DictationTests : IDisposable
{
    private readonly string _tempDir = Path.Combine(Path.GetTempPath(), $"hq-dictation-tests-{Guid.NewGuid():N}");

    public DictationTests() => Directory.CreateDirectory(_tempDir);

    public void Dispose()
    {
        try { if (Directory.Exists(_tempDir)) Directory.Delete(_tempDir, recursive: true); } catch (IOException) { }
    }

    private sealed class MemPrefs : IPreferences
    {
        private readonly Dictionary<string, string> _map = [];
        public string? Get(string key) => _map.TryGetValue(key, out var v) ? v : null;
        public void Set(string key, string? value)
        {
            if (value == null) _map.Remove(key);
            else _map[key] = value;
        }
    }

    private sealed class FakeDictationCapture(string tempDir) : IDictationCapturing
    {
        public MemoMicPermission Permission { get; set; } = MemoMicPermission.Granted;
        public bool RequestGrantResult { get; set; } = true;
        public int SampleRate => 16000;
        public bool ThrowOnStart { get; set; }
        public bool ProduceEmptyAudio { get; set; }
        public bool Stopped { get; private set; }
        public bool LastCancel { get; private set; }
        public string? LastFile { get; private set; }

        public Task<bool> RequestPermissionAsync() => Task.FromResult(RequestGrantResult);

        public event Action<double, double>? LevelChanged;
        public event Action<short[]>? PcmCaptured;
        public event Action<DictationCaptureError, string>? Interrupted;

        public Task StartAsync(double limitSeconds, CancellationToken ct = default)
        {
            if (ThrowOnStart) throw new DictationCaptureException(DictationCaptureError.Busy, "Microphone is busy.");
            Stopped = false;
            return Task.CompletedTask;
        }

        public void EmitLevel(double level, double seconds) => LevelChanged?.Invoke(level, seconds);
        public void EmitPcm(short[] pcm) => PcmCaptured?.Invoke(pcm);
        public void EmitInterrupt(DictationCaptureError err, string msg) => Interrupted?.Invoke(err, msg);

        public Task<DictationTake?> StopAsync(bool cancel)
        {
            Stopped = true;
            LastCancel = cancel;
            if (cancel) return Task.FromResult<DictationTake?>(null);
            var file = Path.Combine(tempDir, $"take-{Guid.NewGuid():N}.wav");
            LastFile = file;
            var samples = ProduceEmptyAudio ? [] : new short[] { 1000, -1000, 2000, -2000 };
            File.WriteAllBytes(file, TalkWave.EncodeWav(samples, 16000));
            return Task.FromResult<DictationTake?>(new DictationTake(file, "audio/wav", 2.0));
        }

        public void Dispose() { }
    }

    private sealed class FakeDictationGateway : IVoiceGateway
    {
        public TalkConfig Config { get; set; } = TalkConfig.Default;
        public string Transcript { get; set; } = "hello from gateway";
        public Exception? TranscribeError { get; set; }
        public int TranscribeCalls { get; private set; }

        public Task<TalkConfig> ConfigAsync(string? profile, CancellationToken ct = default) => Task.FromResult(Config);

        public Task<string> TranscribeAsync(byte[] audio, string mime, string? profile, CancellationToken ct = default)
        {
            TranscribeCalls++;
            if (TranscribeError != null) throw TranscribeError;
            return Task.FromResult(Transcript);
        }

        public Task<SpeechClip> SpeakAsync(string text, string? voice, string? profile, CancellationToken ct = default) =>
            Task.FromResult(new SpeechClip([1, 2, 3], "audio/mpeg", text));

        public Task<LiveVoiceStatus> LiveStatusAsync(string? profile, CancellationToken ct = default) =>
            Task.FromResult(LiveVoiceStatus.Unavailable);

        public Task<VoiceLease> LiveSessionAsync(string? profile, string? voice, CancellationToken ct = default) =>
            throw new NotSupportedException();

        public Task<GrokLiveStatus> GrokStatusAsync(string? profile, CancellationToken ct = default) =>
            Task.FromResult(GrokLiveStatus.Unavailable);

        public Task<GrokLiveSession> GrokSessionAsync(string? profile, string? voice, CancellationToken ct = default) =>
            throw new NotSupportedException();
    }

    private sealed class FakeLiveWords : ILiveWordsListening
    {
        public LiveWordsSource Source => LiveWordsSource.Device;
        public bool IsAvailable { get; set; } = true;
        public string FinalText { get; set; } = "";
        public int PcmChunks { get; private set; }
        public bool Cancelled { get; private set; }

        public event Action<LiveWordsText>? Changed;

        public Task<bool> StartAsync(CancellationToken ct = default)
        {
            Cancelled = false;
            return Task.FromResult(IsAvailable);
        }

        public void FeedPcm(ReadOnlySpan<short> pcm, int sampleRate) => PcmChunks++;
        public void Emit(string settled, string pending = "") => Changed?.Invoke(new LiveWordsText(settled, pending));
        public Task<string> FinishAsync(CancellationToken ct = default) => Task.FromResult(FinalText);
        public void Cancel() => Cancelled = true;
    }

    [Fact]
    public async Task DictationGatewayRoundTripInsertsTidiedTranscriptAndDeletesTempFile()
    {
        var capture = new FakeDictationCapture(_tempDir);
        var gateway = new FakeDictationGateway { Transcript = "um check the the build log" };
        using var ctrl = new DictationController(capture, gateway);

        string? completedScope = null;
        string? completedText = null;
        ctrl.Completed += (s, t) => { completedScope = s; completedText = t; };

        await ctrl.StartAsync("acct|ivy|chat1", "ivy");
        Assert.Equal(DictationPhase.Recording, ctrl.State.Phase);
        Assert.True(ctrl.IsActiveIn("acct|ivy|chat1"));

        capture.EmitLevel(0.6, 4.2);
        Assert.Equal("0:04", ctrl.State.Clock);
        Assert.False(ctrl.State.IsWarningCountdown);

        capture.EmitLevel(0.4, 112.0);
        Assert.True(ctrl.State.IsWarningCountdown);
        Assert.Equal(8.0, ctrl.State.SecondsLeft, 1);

        await ctrl.DoneAsync();

        Assert.Equal(DictationPhase.Idle, ctrl.State.Phase);
        Assert.Equal("acct|ivy|chat1", completedScope);
        Assert.Equal("Check the build log", completedText);
        Assert.Equal(1, gateway.TranscribeCalls);
        Assert.False(File.Exists(capture.LastFile!));
    }

    [Fact]
    public async Task DictationLiveWordsSkipsGatewaySttAndAppliesWordFixes()
    {
        var prefs = new MemPrefs();
        var fixes = new WordFixes(prefs);
        Assert.Equal(1, fixes.Learn("ask hermies about builds", "ask Hermes about builds"));

        var capture = new FakeDictationCapture(_tempDir);
        var gateway = new FakeDictationGateway();
        var live = new FakeLiveWords { FinalText = "uh ask hermies about builds" };
        using var ctrl = new DictationController(capture, gateway, live, fixes);

        string? result = null;
        ctrl.Completed += (_, text) => result = text;

        await ctrl.StartAsync("scope-live");
        capture.EmitPcm([100, -100, 200]);
        live.Emit("ask hermies", "about builds");
        Assert.Equal("ask hermies about builds", ctrl.State.Spoken);
        Assert.Equal(1, live.PcmChunks);

        await ctrl.DoneAsync();

        Assert.Equal("Ask Hermes about builds", result);
        Assert.Equal(0, gateway.TranscribeCalls);
    }

    [Fact]
    public async Task DictationMicDeniedPostsOpenSettingsNotice()
    {
        var capture = new FakeDictationCapture(_tempDir) { Permission = MemoMicPermission.Denied };
        using var ctrl = new DictationController(capture);

        MemoNotice? notice = null;
        ctrl.NoticePosted += (_, n) => notice = n;

        await ctrl.StartAsync("scope-1");

        Assert.Equal(DictationPhase.Idle, ctrl.State.Phase);
        Assert.NotNull(notice);
        Assert.Equal(MemoNoticeAction.OpenSettings, notice!.Action);
        Assert.Equal("Microphone Access Is Off", notice.Title);
    }

    [Fact]
    public async Task DictationSttOffPostsVoiceSettingsNotice()
    {
        var capture = new FakeDictationCapture(_tempDir);
        var gateway = new FakeDictationGateway { Config = TalkConfig.Default with { SttEnabled = false } };
        using var ctrl = new DictationController(capture, gateway);

        MemoNotice? notice = null;
        ctrl.NoticePosted += (_, n) => notice = n;

        await ctrl.StartAsync("scope-stt");
        await ctrl.DoneAsync();

        Assert.NotNull(notice);
        Assert.Equal(MemoNoticeAction.VoiceSettings, notice!.Action);
        Assert.Equal("Speech-to-Text Is Off", notice.Title);
        Assert.Equal(0, gateway.TranscribeCalls);
    }

    [Fact]
    public async Task DictationEmptyTranscriptPostsNoSpeechNotice()
    {
        var capture = new FakeDictationCapture(_tempDir);
        var gateway = new FakeDictationGateway { Transcript = "   " };
        using var ctrl = new DictationController(capture, gateway);

        MemoNotice? notice = null;
        ctrl.NoticePosted += (_, n) => notice = n;

        await ctrl.StartAsync("scope-empty");
        await ctrl.DoneAsync();

        Assert.NotNull(notice);
        Assert.Equal("No Speech Detected", notice!.Title);
        Assert.Equal(MemoNoticeTone.Warning, notice.Tone);
    }

    [Fact]
    public async Task DictationGatewayErrorPostsRetryNotice()
    {
        var capture = new FakeDictationCapture(_tempDir);
        var gateway = new FakeDictationGateway { TranscribeError = new GatewayException("timeout", "timed out") };
        using var ctrl = new DictationController(capture, gateway);

        MemoNotice? notice = null;
        ctrl.NoticePosted += (_, n) => notice = n;

        await ctrl.StartAsync("scope-err");
        await ctrl.DoneAsync();

        Assert.NotNull(notice);
        Assert.Equal(MemoNoticeAction.RetryDictation, notice!.Action);
        Assert.Equal(MemoNoticeTone.Error, notice.Tone);
    }

    [Fact]
    public async Task DictationCancelStopsCaptureAndEmitsNoCompletion()
    {
        var capture = new FakeDictationCapture(_tempDir);
        var live = new FakeLiveWords();
        using var ctrl = new DictationController(capture, new FakeDictationGateway(), live);

        var completed = false;
        ctrl.Completed += (_, _) => completed = true;

        await ctrl.StartAsync("scope-cancel");
        ctrl.Cancel();

        Assert.Equal(DictationPhase.Idle, ctrl.State.Phase);
        Assert.True(live.Cancelled);
        Assert.False(completed);
    }

    [Fact]
    public void LiveWordsTidyPhoneticWordFixesAndGatewayWireWorkEndToEnd()
    {
        Assert.Equal("hrms", Phonetic.Key("Hermes"));
        Assert.Equal("hrms", Phonetic.Key("hermies"));
        Assert.Equal("Check the build.", LiveWordsTidy.Tidy("um, uh check check the build ."));

        var prefs = new MemPrefs();
        var fixes = new WordFixes(prefs);
        Assert.Equal(1, fixes.Learn("open tailscale", "open Tailscale"));
        Assert.Equal("Check Tailscale", fixes.Apply("Check tailscale"));

        var reloaded = new WordFixes(prefs);
        Assert.Single(reloaded.Entries);
        Assert.Equal("Check Tailscale", reloaded.Apply("Check tailscale"));

        Assert.Equal("hello world today", GatewayWordsWire.Merge("hello world", "world today"));
        Assert.True(GatewayWordsWire.Offered(JsonNode.Parse("""{"stt":{"enabled":true,"streaming":true}}""")));
        Assert.False(GatewayWordsWire.Offered(JsonNode.Parse("""{"stt":{"enabled":false,"streaming":true}}""")));

        var startJson = GatewayWordsWire.StartFrame(16000, "ivy", "en");
        Assert.Contains("\"sample_rate\":16000", startJson);
        var parsedPartial = GatewayWordsWire.ParseFrame("""{"type":"partial","text":"testing one"}""");
        Assert.IsType<GatewayWordsFrame.Partial>(parsedPartial);
        var parsedFinal = GatewayWordsWire.ParseFrame("""{"type":"final","text":"testing one two"}""");
        Assert.IsType<GatewayWordsFrame.Final>(parsedFinal);

        var run = LiveWordsDisplay.Format(new LiveWordsText("First part", "one two three four"), maxTrailingWords: 2);
        Assert.Equal("First part one two", run.Primary);
        Assert.Equal("three four", run.Secondary);
        Assert.False(run.IsPlaceholder);

        var emptyRun = LiveWordsDisplay.Format(LiveWordsText.Empty);
        Assert.True(emptyRun.IsPlaceholder);
        Assert.Equal(LiveWordsDisplay.Placeholder, emptyRun.Secondary);
    }
}
