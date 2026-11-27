namespace Hermes.Core.Voice;

// Port of App/Chat/Voice/DictationController.swift & HermesKit/Voice/DictationRecorder.swift:
// press-to-dictate flow into the composer text box using live on-device speech recognition
// when available, with automatic fallback to gateway `/api/audio/transcribe`.

public enum DictationPhase { Idle, Starting, Recording, Transcribing }

public sealed record DictationTake(string FilePath, string Mime, double Seconds, string? LiveWords = null);

public enum DictationCaptureError { PermissionDenied, Busy, Failed, Empty, Limit }

public sealed class DictationCaptureException(DictationCaptureError error, string message) : Exception(message)
{
    public DictationCaptureError Error { get; } = error;
}

public interface IDictationCapturing : IDisposable
{
    MemoMicPermission Permission { get; }
    int SampleRate { get; }
    Task<bool> RequestPermissionAsync();

    event Action<double, double>? LevelChanged;
    event Action<short[]>? PcmCaptured;
    event Action<DictationCaptureError, string>? Interrupted;

    Task StartAsync(double limitSeconds, CancellationToken ct = default);
    Task<DictationTake?> StopAsync(bool cancel);
}

public sealed record DictationState(
    DictationPhase Phase,
    string? TargetScope,
    double Seconds,
    double LimitSeconds,
    double Level,
    IReadOnlyList<double> Levels,
    LiveWordsText LiveWords,
    bool StartingShown)
{
    public static readonly DictationState Idle = new(DictationPhase.Idle, null, 0, DictationController.DefaultLimitSeconds, 0, [], LiveWordsText.Empty, false);

    public bool IsActive => Phase != DictationPhase.Idle;
    public double SecondsLeft => Math.Max(0, LimitSeconds - Seconds);
    public bool IsWarningCountdown => Phase == DictationPhase.Recording && SecondsLeft <= DictationController.WarningThresholdSeconds;
    public string Clock => MemoPolicy.Length(Seconds);
    public string Spoken => LiveWords.Text;
}

public sealed class DictationController : IDisposable
{
    public const double DefaultLimitSeconds = 120.0;
    public const double WarningThresholdSeconds = 10.0;
    public const int StartingDelayMs = 250;
    public const int LevelWindow = 120;

    private readonly IDictationCapturing _capture;
    private readonly IVoiceGateway? _gateway;
    private readonly ILiveWordsListening? _liveWords;
    private readonly WordFixes? _fixes;
    private readonly double _limitSeconds;
    private readonly List<double> _levels = [];

    private DictationPhase _phase = DictationPhase.Idle;
    private string? _scope;
    private string? _profile;
    private double _seconds;
    private double _level;
    private LiveWordsText _liveWordsText = LiveWordsText.Empty;
    private bool _startingShown;
    private int _generation;
    private CancellationTokenSource? _cts;

    public DictationController(
        IDictationCapturing capture,
        IVoiceGateway? gateway = null,
        ILiveWordsListening? liveWords = null,
        WordFixes? fixes = null,
        double limitSeconds = DefaultLimitSeconds)
    {
        _capture = capture;
        _gateway = gateway;
        _liveWords = liveWords;
        _fixes = fixes;
        _limitSeconds = Math.Max(10, limitSeconds);

        _capture.LevelChanged += OnCaptureLevel;
        _capture.PcmCaptured += OnCapturePcm;
        _capture.Interrupted += OnCaptureInterrupted;
        if (_liveWords != null) _liveWords.Changed += OnLiveWordsChanged;
    }

    public event Action<DictationState>? Changed;
    public event Action<double>? LevelChanged;
    public event Action<string, string>? Completed;
    public event Action<string, MemoNotice>? NoticePosted;

    public DictationState State => new(_phase, _scope, _seconds, _limitSeconds, _level, [.. _levels], _liveWordsText, _startingShown);

    public bool IsActive => _phase != DictationPhase.Idle;
    public bool IsActiveIn(string scope) => IsActive && _scope == scope;

    public async Task StartAsync(string scope, string? profile = null, CancellationToken ct = default)
    {
        if (IsActive) return;

        switch (_capture.Permission)
        {
            case MemoMicPermission.Denied:
                PostMicDenied(scope);
                return;
            case MemoMicPermission.Undetermined:
                var granted = await _capture.RequestPermissionAsync();
                if (!granted)
                {
                    PostMicDenied(scope);
                    return;
                }
                break;
        }

        var gen = ++_generation;
        _cts?.Cancel();
        _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _scope = scope;
        _profile = profile;
        _phase = DictationPhase.Starting;
        _seconds = 0;
        _level = 0;
        _levels.Clear();
        _liveWordsText = LiveWordsText.Empty;
        _startingShown = false;
        Publish();

        _ = ShowStartingAfterDelayAsync(gen, _cts.Token);

        try
        {
            await _capture.StartAsync(_limitSeconds, _cts.Token);
            if (gen != _generation)
            {
                await _capture.StopAsync(cancel: true);
                return;
            }
            if (_liveWords is { IsAvailable: true })
                await _liveWords.StartAsync(_cts.Token);

            _phase = DictationPhase.Recording;
            _startingShown = false;
            Publish();
        }
        catch (OperationCanceledException)
        {
            if (gen == _generation) ResetState();
        }
        catch (DictationCaptureException ex)
        {
            if (gen != _generation) return;
            ResetState();
            if (ex.Error == DictationCaptureError.PermissionDenied) PostMicDenied(scope);
            else NoticePosted?.Invoke(scope, new MemoNotice(MemoNoticeTone.Error, "Couldn’t Dictate", ex.Message, Action: MemoNoticeAction.RetryDictation));
        }
        catch (Exception ex)
        {
            if (gen != _generation) return;
            ResetState();
            var plain = VoicePlainWords.Plain(ex, "start dictation");
            NoticePosted?.Invoke(scope, new MemoNotice(MemoNoticeTone.Error, "Couldn’t Dictate", plain.Message, plain.Detail, MemoNoticeAction.RetryDictation));
        }
    }

    public async Task DoneAsync()
    {
        if (_phase != DictationPhase.Recording || _scope is not { } scope) return;
        var gen = _generation;
        var profile = _profile;
        var ct = _cts?.Token ?? CancellationToken.None;

        _phase = DictationPhase.Transcribing;
        Publish();

        string? liveResult = null;
        if (_liveWords != null)
        {
            try { liveResult = await _liveWords.FinishAsync(ct); }
            catch (Exception) { liveResult = _liveWordsText.Text; }
        }

        DictationTake? take;
        try
        {
            take = await _capture.StopAsync(cancel: false);
        }
        catch (Exception ex)
        {
            if (gen != _generation) return;
            ResetState();
            var plain = VoicePlainWords.Plain(ex, "finish dictation");
            NoticePosted?.Invoke(scope, new MemoNotice(MemoNoticeTone.Error, "Couldn’t Dictate", plain.Message, plain.Detail, MemoNoticeAction.RetryDictation));
            return;
        }

        if (gen != _generation)
        {
            TryDeleteFile(take?.FilePath);
            return;
        }

        try
        {
            var fastWords = LiveWordsTidy.Tidy(liveResult ?? take?.LiveWords ?? _liveWordsText.Text, _fixes);
            if (!string.IsNullOrWhiteSpace(fastWords))
            {
                ResetState();
                Completed?.Invoke(scope, fastWords);
                return;
            }

            if (take == null || !File.Exists(take.FilePath))
            {
                ResetState();
                PostNoSpeech(scope);
                return;
            }

            if (_gateway == null)
            {
                ResetState();
                NoticePosted?.Invoke(scope, new MemoNotice(MemoNoticeTone.Warning, "Speech-to-Text Unavailable",
                    "Turn on Speech-to-Text on your gateway or enable Windows speech recognition.", Action: MemoNoticeAction.VoiceSettings));
                return;
            }

            var cfg = TalkConfig.Default;
            try { cfg = await _gateway.ConfigAsync(profile, ct); } catch (Exception) { }
            if (gen != _generation) return;
            if (!cfg.SttEnabled)
            {
                ResetState();
                NoticePosted?.Invoke(scope, new MemoNotice(MemoNoticeTone.Warning, "Speech-to-Text Is Off",
                    "Turn on Speech-to-Text in Voice Settings to dictate with Hermes.", Action: MemoNoticeAction.VoiceSettings));
                return;
            }

            var bytes = await File.ReadAllBytesAsync(take.FilePath, ct);
            if (bytes.Length <= TalkWave.HeaderSize)
            {
                ResetState();
                PostNoSpeech(scope);
                return;
            }

            var transcript = await _gateway.TranscribeAsync(bytes, take.Mime, profile, ct);
            if (gen != _generation) return;
            var cleaned = LiveWordsTidy.Tidy(transcript, _fixes);
            ResetState();
            if (string.IsNullOrWhiteSpace(cleaned)) PostNoSpeech(scope);
            else Completed?.Invoke(scope, cleaned);
        }
        catch (OperationCanceledException)
        {
            if (gen == _generation) ResetState();
        }
        catch (Exception ex)
        {
            if (gen != _generation) return;
            ResetState();
            var plain = VoicePlainWords.Plain(ex, "transcribe your dictation");
            NoticePosted?.Invoke(scope, new MemoNotice(MemoNoticeTone.Error, "Couldn’t Dictate", plain.Message, plain.Detail, MemoNoticeAction.RetryDictation));
        }
        finally
        {
            TryDeleteFile(take?.FilePath);
        }
    }

    public void Cancel()
    {
        if (!IsActive) return;
        _generation++;
        _cts?.Cancel();
        _liveWords?.Cancel();
        _ = StopAndDiscardQuietly();
        ResetState();
    }

    public void Reset() => Cancel();

    private async Task StopAndDiscardQuietly()
    {
        try
        {
            var take = await _capture.StopAsync(cancel: true);
            TryDeleteFile(take?.FilePath);
        }
        catch (Exception) { }
    }

    private async Task ShowStartingAfterDelayAsync(int gen, CancellationToken ct)
    {
        try { await Task.Delay(StartingDelayMs, ct); }
        catch (OperationCanceledException) { return; }
        if (gen == _generation && _phase == DictationPhase.Starting && !_startingShown)
        {
            _startingShown = true;
            Publish();
        }
    }

    private void OnCaptureLevel(double level, double seconds)
    {
        if (_phase != DictationPhase.Recording) return;
        _level = Math.Clamp(level, 0, 1);
        _seconds = Math.Max(0, seconds);
        _levels.Add(_level);
        if (_levels.Count > LevelWindow) _levels.RemoveRange(0, _levels.Count - LevelWindow);
        LevelChanged?.Invoke(_level);
        Publish();
        if (_seconds >= _limitSeconds) _ = DoneAsync();
    }

    private void OnCapturePcm(short[] pcm)
    {
        if (_phase == DictationPhase.Recording) _liveWords?.FeedPcm(pcm, _capture.SampleRate);
    }

    private void OnCaptureInterrupted(DictationCaptureError error, string message)
    {
        if (!IsActive || _scope is not { } scope) return;
        if (error == DictationCaptureError.Limit)
        {
            _ = DoneAsync();
            return;
        }
        Cancel();
        NoticePosted?.Invoke(scope, new MemoNotice(MemoNoticeTone.Warning, "Dictation Stopped", message, Action: MemoNoticeAction.RetryDictation));
    }

    private void OnLiveWordsChanged(LiveWordsText text)
    {
        if (_phase != DictationPhase.Recording) return;
        _liveWordsText = text;
        Publish();
    }

    private void PostMicDenied(string scope) => NoticePosted?.Invoke(scope, new MemoNotice(
        MemoNoticeTone.Warning,
        "Microphone Access Is Off",
        $"Turn on Microphone for {MemoNotice.AppName} in {PrivacySettingsWords.Place} to dictate.",
        Action: MemoNoticeAction.OpenSettings));

    private void PostNoSpeech(string scope) => NoticePosted?.Invoke(scope, new MemoNotice(
        MemoNoticeTone.Warning,
        "No Speech Detected",
        "Nothing was heard. Try speaking a bit closer to the microphone."));

    private void ResetState()
    {
        _cts?.Dispose();
        _cts = null;
        _phase = DictationPhase.Idle;
        _scope = null;
        _profile = null;
        _seconds = 0;
        _level = 0;
        _levels.Clear();
        _liveWordsText = LiveWordsText.Empty;
        _startingShown = false;
        Publish();
    }

    private void Publish() => Changed?.Invoke(State);

    private static void TryDeleteFile(string? path)
    {
        if (string.IsNullOrEmpty(path)) return;
        try { if (File.Exists(path)) File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    public void Dispose()
    {
        Cancel();
        _capture.LevelChanged -= OnCaptureLevel;
        _capture.PcmCaptured -= OnCapturePcm;
        _capture.Interrupted -= OnCaptureInterrupted;
        if (_liveWords != null) _liveWords.Changed -= OnLiveWordsChanged;
    }
}
