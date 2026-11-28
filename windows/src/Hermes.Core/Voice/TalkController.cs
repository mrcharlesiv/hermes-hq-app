using System.Diagnostics;
using Hermes.Core.Chat;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Voice;

// Port of App/Chat/Voice/TalkController.swift: coordinates Classic and Live (GPT Live / Grok Live)
// voice conversations across capture, gateway STT/TTS/realtime, chat turns, silence pause,
// echo guard, spoken/typed stop phrases, audio route menu, and the away pill.

public sealed record TalkTurn(string Role, string Text, DateTimeOffset At);

public interface ITalkChatBridge
{
    string Scope { get; }
    string Profile { get; }
    string BotName { get; }
    bool IsBusy { get; }
    event Action? Changed;

    SpokenReply? NewestReply();
    IReadOnlyList<(string Role, string Text)> RecentHistory(int maxMessages = 10);
    Task<SendOutcome> SendTurnAsync(string text, CancellationToken ct = default);
    Task StopTurnAsync();

    /// True when the chat's currently running turn is answering a `[Voice chat transcript …]` record (`NO_REPLY`).
    /// Delegated requests must stop that turn instead of steering into it.
    bool IsAnsweringVoiceRecord => false;

    /// Queues a formatted `[Voice chat transcript …]` message as an ordinary (non-hidden) user message,
    /// never steering into a running reply.
    Task<SendOutcome> SendVoiceRecordAsync(string text, CancellationToken ct = default) => Task.FromResult(SendOutcome.Accepted);
}

public sealed record TalkSession(
    string Scope,
    string Profile,
    string BotName,
    TalkEngine Engine,
    DateTimeOffset StartedAt,
    TalkConfig Config);

public sealed record TalkState(
    TalkStatus Status,
    TalkEngine Engine,
    string? ActiveScope,
    string BotName,
    double ElapsedSeconds,
    double Level,
    LiveWordsText LiveWords,
    bool SpeakReplies,
    bool HeardSpeech,
    bool SilenceHint,
    TalkNotice? Notice,
    string? EndedCaption,
    TalkAudioRoute? ActiveRoute,
    IReadOnlyList<TalkAudioRoute> Routes,
    TalkDockSnapshot Dock,
    TalkAwayPillContent AwayPill)
{
    public bool IsActive => Status != TalkStatus.Idle;
}

public sealed class TalkController : IDisposable
{
    private readonly ITalkCapturing _capture;
    private readonly ITalkSpeaker _speaker;
    private readonly IVoiceGateway? _gateway;
    private readonly Func<ILiveVoiceTransport>? _liveFactory;
    private readonly ILiveWordsListening? _liveWords;
    private readonly IMemoSystemEvents? _systemEvents;
    private readonly IPreferences _prefs;
    private readonly VoiceEvents _events;
    private readonly Func<DateTimeOffset> _now;

    private readonly SilenceClock _silence = new();
    private readonly List<TalkTurn> _turns = [];
    private readonly List<VoiceTurn> _liveRecordTurns = [];
    private readonly Stopwatch _speechProgressWatch = new();

    private ITalkChatBridge? _chat;
    private TalkSession? _session;
    private TalkLoopState _classic = TalkLoopState.Initial;
    private LiveTalkState _live = LiveTalkState.Initial;
    private ILiveVoiceTransport? _transport;
    private CancellationTokenSource? _workCts;
    private CancellationTokenSource? _speechCts;

    private string? _visibleScope;
    private string? _endedCaption;
    private double _elapsedSeconds;
    private double _level;
    private LiveWordsText _liveWordsText = LiveWordsText.Empty;
    private string? _lastBotSpokenText;
    private DateTimeOffset? _lastBotSpokenAt;
    private string? _watchedReplyId;
    private bool _awaitingReply;
    private TalkEngine _engine = TalkEngine.Classic;
    private List<TalkAudioRoute> _routes = [];
    private string? _selectedRouteId;
    private string _liveAssistantBuffer = "";
    private bool _liveRecordSent;
    private int _speechGeneration;
    private DateTimeOffset _lastSpeechProgressAt;
    private double _liveSpeakingStallSeconds;

    public TalkController(
        ITalkCapturing capture,
        ITalkSpeaker speaker,
        IPreferences prefs,
        IVoiceGateway? gateway = null,
        Func<ILiveVoiceTransport>? liveFactory = null,
        ILiveWordsListening? liveWords = null,
        IMemoSystemEvents? systemEvents = null,
        VoiceEvents? events = null,
        Func<DateTimeOffset>? now = null)
    {
        _capture = capture;
        _speaker = speaker;
        _prefs = prefs;
        _gateway = gateway;
        _liveFactory = liveFactory;
        _liveWords = liveWords;
        _systemEvents = systemEvents;
        _events = events ?? VoiceEvents.Shared;
        _now = now ?? (() => DateTimeOffset.UtcNow);

        _classic = _classic with { SpeakReplies = TalkPrefs.SpeakReplies(_prefs) };
        _engine = TalkPrefs.Engine(_prefs);

        _capture.LevelChanged += OnLevelChanged;
        _capture.SpeechStarted += OnCaptureSpeechStarted;
        _capture.TakeCompleted += OnCaptureTakeCompleted;
        _capture.BargeInDetected += OnCaptureBargeIn;
        _capture.PcmCaptured += OnCapturePcm;
        _capture.Failed += OnCaptureFailed;
        _speaker.LevelChanged += OnSpeakerLevelChanged;
        if (_liveWords != null) _liveWords.Changed += OnLiveWordsChanged;
        if (_systemEvents != null) _systemEvents.Raised += OnSystemEvent;
    }

    public event Action<TalkState>? StateChanged;
    public event Action<double>? LevelChanged;
    public event Action? ChimeRequested;
    public event Action<TalkHaptic>? HapticRequested;
    public event Action<VoiceChatRecord>? RecordCompleted;
    public event Action<string>? ReturnToChatRequested;
    public event Action<string>? RouteSelected;

    /// Watchdog limit for a wedged TTS playback or stalled live-voice speaking state (M18).
    public TimeSpan SpeechStallTimeout { get; set; } = TimeSpan.FromSeconds(15);

    public TalkSession? Session => _session;
    public TalkEngine PreferredEngine => TalkPrefs.Engine(_prefs);
    public IReadOnlyList<TalkTurn> Turns => _turns;
    public IReadOnlyList<VoiceTurn> LiveRecordTurns => _liveRecordTurns;
    public VoiceEvents Events => _events;

    public TalkStatus Status => _engine.IsLive() ? _live.Status : _classic.Status;
    public bool IsActive => Status != TalkStatus.Idle;
    public bool IsActiveIn(string scope) => IsActive && _session?.Scope == scope;
    public string? ActiveScope => _session?.Scope;

    public TalkState CurrentState
    {
        get
        {
            var status = Status;
            var bot = _session?.BotName ?? "Hermes";
            var scope = _session?.Scope;
            var notice = _engine.IsLive() ? _live.Notice : _classic.Notice;
            var heard = !_engine.IsLive() && _classic.HeardSpeech;
            var hint = !_engine.IsLive() && _classic.SilenceHint;
            var activeRoute = ActiveRoute;
            var dock = TalkDockState.Build(status, bot, _engine, _elapsedSeconds, _liveWordsText,
                _classic.SpeakReplies, heard, hint, notice, activeRoute);
            var awayVisible = scope != null && _visibleScope != null && _visibleScope != scope && (status != TalkStatus.Idle || notice != null);
            var pill = TalkDockState.AwayPill(awayVisible, status, scope ?? "", bot, _elapsedSeconds, notice);
            return new TalkState(status, _engine, scope, bot, _elapsedSeconds, _level, _liveWordsText,
                _classic.SpeakReplies, heard, hint, notice, _endedCaption, activeRoute, _routes, dock, pill);
        }
    }

    public TalkAudioRoute? ActiveRoute =>
        _routes.FirstOrDefault(r => r.Id == _selectedRouteId)
        ?? _routes.FirstOrDefault(r => r.IsActive)
        ?? _routes.FirstOrDefault();

    public void SetRoutes(IReadOnlyList<TalkAudioRoute> routes)
    {
        _routes = [.. routes];
        if (_selectedRouteId == null)
            _selectedRouteId = _routes.FirstOrDefault(r => r.IsActive)?.Id ?? _routes.FirstOrDefault()?.Id;
        Publish();
    }

    public void SelectRoute(string routeId)
    {
        _selectedRouteId = routeId;
        _routes = _routes.Select(r => r with { IsActive = r.Id == routeId }).ToList();
        RouteSelected?.Invoke(routeId);
        Publish();
    }

    public void ScreenChanged(string? visibleScope)
    {
        if (_visibleScope == visibleScope) return;
        _visibleScope = visibleScope;
        Publish();
    }

    public void RequestReturnToChat()
    {
        if (_session?.Scope is { } scope) ReturnToChatRequested?.Invoke(scope);
    }

    public void SetPreferredEngine(TalkEngine engine)
    {
        TalkPrefs.SetEngine(_prefs, engine);
        if (!IsActive) _engine = engine;
        Publish();
    }

    public void SetSpeakReplies(bool on)
    {
        TalkPrefs.SetSpeakReplies(_prefs, on);
        if (!_engine.IsLive())
            DispatchClassic(new TalkLoopInput.SetSpeakReplies(on));
        else
        {
            _classic = _classic with { SpeakReplies = on };
            Publish();
        }
    }

    public async Task StartAsync(ITalkChatBridge chat, TalkEngine? requestedEngine = null, CancellationToken ct = default)
    {
        if (IsActive) End(TalkEnd.Replaced);

        _endedCaption = null;
        _elapsedSeconds = 0;
        _level = 0;
        _liveWordsText = LiveWordsText.Empty;
        _turns.Clear();
        _liveRecordTurns.Clear();
        _liveRecordSent = false;
        _liveAssistantBuffer = "";
        _liveSpeakingStallSeconds = 0;
        _silence.Reset();
        _awaitingReply = false;
        _lastBotSpokenText = null;
        _lastBotSpokenAt = null;
        _workCts?.Cancel();
        _workCts = CancellationTokenSource.CreateLinkedTokenSource(ct);

        AttachChat(chat);
        var config = TalkConfig.Default;
        if (_gateway != null)
        {
            try { config = await _gateway.ConfigAsync(chat.Profile, _workCts.Token); }
            catch (Exception e) { _events.Record($"talk config fallback: {e.GetType().Name}"); }
        }

        var engine = requestedEngine ?? TalkPrefs.Engine(_prefs);
        if (engine == TalkEngine.GptLive && (!config.LiveOffered || _liveFactory == null)) engine = TalkEngine.Classic;
        if (engine == TalkEngine.GrokLive && (!config.GrokOffered || _liveFactory == null)) engine = TalkEngine.Classic;

        _engine = engine;
        _session = new TalkSession(chat.Scope, chat.Profile, chat.BotName, engine, _now(), config);
        _visibleScope = chat.Scope;
        _events.Record($"talk start engine={engine.Key()}");

        if (!engine.IsLive() && !config.SttEnabled && (_liveWords == null || !_liveWords.IsAvailable))
        {
            DispatchClassic(new TalkLoopInput.StartFailed(TalkNotice.SttOff()));
            return;
        }

        if (engine.IsLive())
        {
            _live = LiveTalkState.Initial with { CanFallbackToClassic = config.SttEnabled || (_liveWords?.IsAvailable == true) };
            DispatchLive(new LiveTalkInput.Connect());
        }
        else
        {
            _classic = TalkLoopState.Initial with { SpeakReplies = TalkPrefs.SpeakReplies(_prefs) };
            DispatchClassic(new TalkLoopInput.Start());
        }
    }

    public void ToggleMute()
    {
        if (!IsActive) return;
        if (_engine.IsLive()) DispatchLive(new LiveTalkInput.MuteToggle());
        else DispatchClassic(new TalkLoopInput.MuteToggle());
    }

    public void SendNow()
    {
        if (!_engine.IsLive()) DispatchClassic(new TalkLoopInput.SendNow());
    }

    public void Interrupt()
    {
        if (_engine.IsLive()) DispatchLive(new LiveTalkInput.Interrupt());
        else DispatchClassic(new TalkLoopInput.StopCurrent());
    }

    public void StopCurrent() => Interrupt();

    public async Task ResumeAsync()
    {
        if (_session == null || _chat == null) return;
        if (_engine.IsLive())
        {
            DispatchLive(new LiveTalkInput.Connect());
        }
        else if (_classic.Status == TalkStatus.Stopped)
        {
            await StartAsync(_chat, TalkEngine.Classic);
        }
        else
        {
            _silence.Reset();
            DispatchClassic(new TalkLoopInput.Resume());
        }
    }

    public void DismissNotice()
    {
        if (_engine.IsLive())
        {
            _live = _live with { Notice = null };
            if (_live.Status == TalkStatus.Stopped) ClearSession();
        }
        else
        {
            _classic = _classic with { Notice = null };
            if (_classic.Status == TalkStatus.Stopped) ClearSession();
        }
        Publish();
    }

    /// Returns true when the typed text was a voice stop command ("stop", "end voice chat", etc.)
    /// in the active Talk chat and handled by ending Talk.
    public bool InterceptTypedSend(string scope, string typed)
    {
        if (!IsActiveIn(scope)) return false;
        if (!TalkStopWord.IsTypedStop(typed)) return false;
        End(TalkEnd.TypedStop);
        return true;
    }

    public void NoteExternalQuestion(bool waiting)
    {
        if (!IsActive || _engine.IsLive()) return;
        if (waiting) DispatchClassic(new TalkLoopInput.AutoMute(TalkPauseCause.Question));
        else if (_classic.Status == TalkStatus.Waiting) DispatchClassic(new TalkLoopInput.Resume());
    }

    /// Periodic 1-second (or sub-second) clock tick driven by UI timer or unit tests.
    public void Tick(double dtSeconds)
    {
        if (dtSeconds <= 0) return;
        var status = Status;
        if (status is TalkStatus.Idle or TalkStatus.Stopped) return;
        if (status != TalkStatus.Paused) _elapsedSeconds += dtSeconds;

        if (!_engine.IsLive())
        {
            var isSilentListening = _classic.Status == TalkStatus.Listening && !_classic.HeardSpeech;
            var signal = _silence.Advance(dtSeconds, isSilentListening);
            if (signal == SilenceSignal.Hint) DispatchClassic(new TalkLoopInput.SilenceHint());
            else if (signal == SilenceSignal.Pause) DispatchClassic(new TalkLoopInput.SilencePause());
        }
        else if (_live.Status == TalkStatus.Speaking && SpeechStallTimeout > TimeSpan.Zero)
        {
            // M18: guard against a wedged live-voice speaking state if AssistantDone never arrives.
            _liveSpeakingStallSeconds += dtSeconds;
            if (_liveSpeakingStallSeconds >= SpeechStallTimeout.TotalSeconds)
            {
                _liveSpeakingStallSeconds = 0;
                _events.Record("live talk speech stalled watchdog triggered");
                _speaker.FlushPcm();
                DispatchLive(new LiveTalkInput.AssistantDone(null));
                return;
            }
        }
        else
        {
            _liveSpeakingStallSeconds = 0;
        }
        Publish();
    }

    public void End(TalkEnd reason = TalkEnd.User)
    {
        if (!IsActive && _session == null) return;
        _events.Record($"talk end reason={reason}");
        if (_engine.IsLive()) DispatchLive(new LiveTalkInput.End(reason));
        else DispatchClassic(new TalkLoopInput.End(reason));
    }

    public void Reset()
    {
        if (IsActive) End(TalkEnd.SignedOut);
        _endedCaption = null;
        ClearSession();
        Publish();
    }

    // MARK: - Classic Reducer & Effects

    private void DispatchClassic(TalkLoopInput input)
    {
        var (next, effects) = TalkLoop.Reduce(_classic, input);
        _classic = next;
        Publish();
        foreach (var fx in effects) RunClassicEffect(fx);
    }

    private void RunClassicEffect(TalkLoopEffect effect)
    {
        switch (effect)
        {
            case TalkLoopEffect.StartCapture:
                _ = StartClassicCaptureAsync();
                break;
            case TalkLoopEffect.StopCapture:
                _capture.Stop();
                _liveWords?.Cancel();
                break;
            case TalkLoopEffect.FlushCapture:
                if (_capture.FlushNow() is { } flushed)
                    HandleTake(flushed);
                break;
            case TalkLoopEffect.Transcribe t:
                _ = TranscribeClassicAsync(t.Wav);
                break;
            case TalkLoopEffect.SubmitTurn sub:
                _ = SubmitClassicTurnAsync(sub.Text);
                break;
            case TalkLoopEffect.Speak sp:
                _ = SpeakClassicAsync(sp.Text);
                break;
            case TalkLoopEffect.StopSpeech:
                CancelSpeechWatchdog();
                _speaker.Stop();
                break;
            case TalkLoopEffect.StopTurn:
                _awaitingReply = false;
                if (_chat != null) _ = _chat.StopTurnAsync();
                break;
            case TalkLoopEffect.PlayChime:
                ChimeRequested?.Invoke();
                break;
            case TalkLoopEffect.Haptic h:
                HapticRequested?.Invoke(h.Kind);
                break;
            case TalkLoopEffect.RecordEnded r:
                FinishSessionRecord(r.Reason);
                break;
        }
    }

    private async Task StartClassicCaptureAsync()
    {
        var ct = _workCts?.Token ?? CancellationToken.None;
        try
        {
            _capture.IsMuted = false;
            _capture.BargeInEnabled = false;
            await _capture.StartAsync(ct);
            if (_liveWords is { IsAvailable: true })
            {
                _liveWordsText = LiveWordsText.Empty;
                await _liveWords.StartAsync(ct);
            }
            if (_classic.Status is TalkStatus.Starting or TalkStatus.Paused)
                DispatchClassic(new TalkLoopInput.Started());
        }
        catch (OperationCanceledException) { }
        catch (TalkCaptureException ex)
        {
            var notice = ex.Error == TalkCaptureError.PermissionDenied
                ? TalkNotice.MicDenied()
                : new TalkNotice(TalkNoticeKind.MicFailed, "Couldn’t Use the Microphone", ex.Message, Action: TalkNoticeAction.Retry, Fatal: true);
            DispatchClassic(new TalkLoopInput.StartFailed(notice));
        }
        catch (Exception ex)
        {
            DispatchClassic(new TalkLoopInput.StartFailed(TalkNotice.FromFailure(VoicePlainWords.Plain(ex, "start the microphone"), fatal: true)));
        }
    }

    private async Task TranscribeClassicAsync(byte[] wav)
    {
        var ct = _workCts?.Token ?? CancellationToken.None;
        if (_gateway == null)
        {
            DispatchClassic(new TalkLoopInput.TranscribeFailed(new TalkNotice(TalkNoticeKind.SttOff,
                "Transcription Unavailable", "No voice gateway is connected.", Action: TalkNoticeAction.Retry)));
            return;
        }
        try
        {
            var text = await _gateway.TranscribeAsync(wav, "audio/wav", _session?.Profile, ct);
            HandleHeardText(text);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            var failure = VoicePlainWords.Plain(ex, "transcribe what you said");
            DispatchClassic(new TalkLoopInput.TranscribeFailed(TalkNotice.FromFailure(failure)));
        }
    }

    private void HandleTake(TalkTake take)
    {
        if (!string.IsNullOrWhiteSpace(take.LiveWords))
        {
            var liveText = take.LiveWords.Trim();
            if (ShouldIgnoreAsEcho(liveText))
            {
                _events.Record("talk echo dropped (live words)");
                return;
            }
            if (TalkStopWord.IsStopPhrase(liveText, _session?.BotName))
            {
                End(TalkEnd.SpokenStop);
                return;
            }
            DispatchClassic(new TalkLoopInput.TakeReady(take.WavBytes, liveText));
            return;
        }
        DispatchClassic(new TalkLoopInput.TakeReady(take.WavBytes, null));
    }

    private void HandleHeardText(string raw)
    {
        var text = raw.Trim();
        if (text.Length == 0 || ShouldIgnoreAsEcho(text))
        {
            if (text.Length > 0) _events.Record("talk echo dropped (gateway stt)");
            DispatchClassic(new TalkLoopInput.TranscribeDone(""));
            return;
        }
        if (TalkStopWord.IsStopPhrase(text, _session?.BotName))
        {
            End(TalkEnd.SpokenStop);
            return;
        }
        DispatchClassic(new TalkLoopInput.TranscribeDone(text));
    }

    private bool ShouldIgnoreAsEcho(string heard)
    {
        if (_lastBotSpokenText == null || _lastBotSpokenAt == null) return false;
        var elapsed = (_now() - _lastBotSpokenAt.Value).TotalSeconds;
        return TalkEcho.IsEcho(heard, _lastBotSpokenText, elapsed);
    }

    private async Task SubmitClassicTurnAsync(string text)
    {
        if (_chat == null) return;
        var ct = _workCts?.Token ?? CancellationToken.None;
        _turns.Add(new TalkTurn("user", text, _now()));
        _liveWordsText = LiveWordsText.Empty;
        _watchedReplyId = _chat.NewestReply()?.MessageId;
        _awaitingReply = true;
        Publish();

        try
        {
            var outcome = await _chat.SendTurnAsync(text, ct);
            if (outcome == SendOutcome.Refused)
            {
                _awaitingReply = false;
                DispatchClassic(new TalkLoopInput.ReplyEmpty());
            }
            else
            {
                CheckForCompletedReply();
            }
        }
        catch (OperationCanceledException) { _awaitingReply = false; }
        catch (Exception ex)
        {
            _awaitingReply = false;
            var failure = VoicePlainWords.Plain(ex, "send your message");
            DispatchClassic(new TalkLoopInput.Pause(TalkPauseCause.Disconnected, TalkNotice.FromFailure(failure)));
        }
    }

    private void CheckForCompletedReply()
    {
        if (!_awaitingReply || _chat == null || _chat.IsBusy) return;
        var newest = _chat.NewestReply();
        if (newest == null || newest.Pending) return;
        if (newest.MessageId == _watchedReplyId) return;

        _awaitingReply = false;
        _watchedReplyId = newest.MessageId;
        var text = newest.Text.Trim();
        if (text.Length == 0)
        {
            DispatchClassic(new TalkLoopInput.ReplyEmpty());
            return;
        }
        _turns.Add(new TalkTurn("assistant", text, _now()));
        DispatchClassic(new TalkLoopInput.ReplyReady(text));
    }

    private void CancelSpeechWatchdog()
    {
        Interlocked.Increment(ref _speechGeneration);
        var cts = Interlocked.Exchange(ref _speechCts, null);
        if (cts != null)
        {
            try { cts.Cancel(); } catch (ObjectDisposedException) { }
            cts.Dispose();
        }
    }

    private async Task SpeakClassicAsync(string text)
    {
        var ct = _workCts?.Token ?? CancellationToken.None;
        _lastBotSpokenText = text;
        _lastBotSpokenAt = _now();
        _capture.BargeInEnabled = true;

        CancelSpeechWatchdog();
        var speechCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _speechCts = speechCts;
        var generation = Interlocked.Increment(ref _speechGeneration);
        _lastSpeechProgressAt = _now();
        _speechProgressWatch.Restart();

        Func<string, CancellationToken, Task<SpeechClip>>? gatewaySpeak =
            _gateway != null && _session?.Config.TtsEnabled == true
                ? (t, token) => _gateway.SpeakAsync(t, _session.Config.VoiceName, _session.Profile, token)
                : null;

        try
        {
            DispatchClassic(new TalkLoopInput.SpeechStarted());
            var speakTask = _speaker.SpeakAsync(text, gatewaySpeak, speechCts.Token);
            if (SpeechStallTimeout > TimeSpan.Zero && !speakTask.IsCompleted)
            {
                var watchdogTask = WatchSpeechStallAsync(speakTask, speechCts.Token);
                var finished = await Task.WhenAny(speakTask, watchdogTask);
                if (finished == watchdogTask && await watchdogTask)
                {
                    if (Volatile.Read(ref _speechGeneration) == generation && _classic.Status == TalkStatus.Speaking)
                    {
                        try { speechCts.Cancel(); } catch (ObjectDisposedException) { }
                        _speaker.Stop();
                        _lastBotSpokenAt = _now();
                        _events.Record("talk speech stalled watchdog triggered");
                        DispatchClassic(new TalkLoopInput.SpeechFailed(new TalkNotice(
                            TalkNoticeKind.SpeechFailed,
                            "Audio Playback Stalled",
                            "Voice playback stopped responding.",
                            Action: TalkNoticeAction.Resume)));
                    }
                    return;
                }
            }

            var outcome = await speakTask;
            if (Volatile.Read(ref _speechGeneration) != generation) return;
            _lastBotSpokenAt = _now();
            if (outcome == TalkSpeechOutcome.Completed)
                DispatchClassic(new TalkLoopInput.SpeechFinished());
            else if (outcome == TalkSpeechOutcome.Failed)
                DispatchClassic(new TalkLoopInput.SpeechFailed(new TalkNotice(TalkNoticeKind.SpeechFailed,
                    "Couldn’t Play Reply", "The voice reply couldn’t be played.", Action: TalkNoticeAction.Resume)));
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            if (Volatile.Read(ref _speechGeneration) != generation) return;
            var failure = VoicePlainWords.Plain(ex, "play the voice reply");
            DispatchClassic(new TalkLoopInput.SpeechFailed(TalkNotice.FromFailure(failure)));
        }
        finally
        {
            if (ReferenceEquals(Interlocked.CompareExchange(ref _speechCts, null, speechCts), speechCts))
                speechCts.Dispose();
        }
    }

    private async Task<bool> WatchSpeechStallAsync(Task speakTask, CancellationToken ct)
    {
        var limit = SpeechStallTimeout;
        var pollMs = Math.Clamp((int)(limit.TotalMilliseconds / 4.0), 10, 250);
        while (!speakTask.IsCompleted && !ct.IsCancellationRequested)
        {
            try { await Task.Delay(pollMs, ct); }
            catch (OperationCanceledException) { return false; }

            if (speakTask.IsCompleted || ct.IsCancellationRequested) return false;
            var wallStalled = _speechProgressWatch.Elapsed >= limit;
            var clockStalled = (_now() - _lastSpeechProgressAt) >= limit;
            if (wallStalled || clockStalled) return true;
        }
        return false;
    }

    // MARK: - Live Reducer & Effects

    private void DispatchLive(LiveTalkInput input)
    {
        var (next, effects) = LiveTalkLoop.Reduce(_live, input);
        _live = next;
        Publish();
        foreach (var fx in effects) RunLiveEffect(fx);
    }

    private void RunLiveEffect(LiveTalkEffect effect)
    {
        switch (effect)
        {
            case LiveTalkEffect.OpenTransport:
                _ = OpenLiveTransportAsync();
                break;
            case LiveTalkEffect.CloseTransport:
                CloseLiveTransport();
                break;
            case LiveTalkEffect.StartMic:
                _ = StartLiveMicAsync();
                break;
            case LiveTalkEffect.StopMic:
                _capture.Stop();
                break;
            case LiveTalkEffect.PlayPcm pcm:
                _speaker.PlayPcmChunk(pcm.Pcm24k);
                break;
            case LiveTalkEffect.FlushAudio:
                _speaker.FlushPcm();
                break;
            case LiveTalkEffect.CancelResponse:
                if (_transport != null) _ = SendControlQuietly(_transport, LiveVoiceWire.ResponseCancel());
                break;
            case LiveTalkEffect.RunDelegation del:
                _ = RunLiveDelegationAsync(del.CallId, del.Prompt);
                break;
            case LiveTalkEffect.SendToolResult res:
                if (_transport != null)
                {
                    _ = SendControlQuietly(_transport, LiveVoiceWire.FunctionCallOutput(res.CallId, res.Result));
                    _ = SendControlQuietly(_transport, LiveVoiceWire.ResponseCreate());
                }
                break;
            case LiveTalkEffect.SwitchToClassic sw:
                FallbackToClassic(sw.Reason);
                break;
            case LiveTalkEffect.PlayChime:
                ChimeRequested?.Invoke();
                break;
            case LiveTalkEffect.Haptic h:
                HapticRequested?.Invoke(h.Kind);
                break;
            case LiveTalkEffect.RecordEnded r:
                FinishSessionRecord(r.Reason);
                break;
        }
    }

    private async Task OpenLiveTransportAsync()
    {
        var ct = _workCts?.Token ?? CancellationToken.None;
        if (_gateway == null || _liveFactory == null || _session == null || _chat == null)
        {
            DispatchLive(new LiveTalkInput.Disconnected("Live voice isn’t configured.", Fatal: true));
            return;
        }
        try
        {
            var voice = TalkPrefs.LiveVoice(_prefs, _engine);
            var context = LiveVoiceWire.BuildHistoryContext(_chat.RecentHistory());
            if (_turns.Count > 0)
                context = string.IsNullOrEmpty(context) ? LiveTalkResume.BuildNote(_turns) : context + "\n\n" + LiveTalkResume.BuildNote(_turns);
            var instructions = LiveVoiceWire.DelegationPrompt(_session.BotName, context);

            VoiceLease? gptLease = null;
            GrokLiveSession? grokSession = null;
            if (_engine == TalkEngine.GrokLive)
                grokSession = await _gateway.GrokSessionAsync(_session.Profile, voice, ct);
            else
                gptLease = await _gateway.LiveSessionAsync(_session.Profile, voice, ct);

            var transport = _liveFactory();
            transport.EventReceived += OnLiveServerEvent;
            _transport = transport;
            await transport.ConnectAsync(_engine, gptLease, grokSession, instructions, ct);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            var failure = VoicePlainWords.Plain(ex, "connect live voice");
            DispatchLive(new LiveTalkInput.Disconnected(failure.Message, Fatal: !failure.Retryable));
        }
    }

    private async Task StartLiveMicAsync()
    {
        var ct = _workCts?.Token ?? CancellationToken.None;
        try
        {
            _capture.IsMuted = false;
            await _capture.StartAsync(ct);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            DispatchLive(new LiveTalkInput.Disconnected(VoicePlainWords.Plain(ex, "start the microphone").Message, Fatal: true));
        }
    }

    private void OnLiveServerEvent(LiveServerEvent ev)
    {
        switch (ev)
        {
            case LiveServerEvent.SessionReady:
                DispatchLive(new LiveTalkInput.Connected());
                break;
            case LiveServerEvent.SpeechStarted:
                DispatchLive(new LiveTalkInput.UserSpeechStarted());
                break;
            case LiveServerEvent.SpeechStopped:
                DispatchLive(new LiveTalkInput.UserSpeechStopped());
                break;
            case LiveServerEvent.UserTranscriptDelta d:
                _liveWordsText = new LiveWordsText(_liveWordsText.Settled, (_liveWordsText.Pending + d.Text).Trim());
                Publish();
                break;
            case LiveServerEvent.UserTranscriptFinal f:
                _liveWordsText = LiveWordsText.Empty;
                if (!string.IsNullOrWhiteSpace(f.Text))
                {
                    if (TalkStopWord.IsStopPhrase(f.Text, _session?.BotName))
                    {
                        End(TalkEnd.SpokenStop);
                        return;
                    }
                    _turns.Add(new TalkTurn("user", f.Text, _now()));
                    VoiceChatRecordCodec.AddFragment(_liveRecordTurns, isUser: true, f.Text);
                }
                DispatchLive(new LiveTalkInput.UserTranscript(f.Text, true));
                break;
            case LiveServerEvent.AssistantAudioDelta a:
                _liveSpeakingStallSeconds = 0;
                DispatchLive(new LiveTalkInput.AssistantAudio(a.Pcm24k));
                break;
            case LiveServerEvent.AssistantTextDelta t:
                _liveAssistantBuffer += t.Text;
                DispatchLive(new LiveTalkInput.AssistantTextDelta(t.Text));
                break;
            case LiveServerEvent.AssistantDone done:
                _liveSpeakingStallSeconds = 0;
                var spoken = !string.IsNullOrWhiteSpace(done.FullText) ? done.FullText : _liveAssistantBuffer;
                _liveAssistantBuffer = "";
                if (!string.IsNullOrWhiteSpace(spoken))
                {
                    _turns.Add(new TalkTurn("assistant", spoken, _now()));
                    VoiceChatRecordCodec.AddFragment(_liveRecordTurns, isUser: false, spoken);
                }
                DispatchLive(new LiveTalkInput.AssistantDone(done.FullText));
                break;
            case LiveServerEvent.FunctionCall call:
                var (action, prompt) = GrokLiveCalls.ParseCall(call.Name, call.ArgumentsJson);
                if (action == GrokAction.StopConversation)
                    End(TalkEnd.SpokenStop);
                else if (action == GrokAction.AskAgent)
                    DispatchLive(new LiveTalkInput.DelegateRequest(call.CallId, prompt));
                break;
            case LiveServerEvent.Error err:
                DispatchLive(new LiveTalkInput.Disconnected(err.Message, err.Fatal));
                break;
            case LiveServerEvent.Closed c:
                DispatchLive(new LiveTalkInput.Disconnected(c.Reason ?? "Live voice connection closed."));
                break;
        }
    }

    private async Task RunLiveDelegationAsync(string callId, string prompt)
    {
        if (_chat == null || string.IsNullOrWhiteSpace(prompt))
        {
            DispatchLive(new LiveTalkInput.DelegateFinished(callId, "Nothing to run."));
            return;
        }
        var ct = _workCts?.Token ?? CancellationToken.None;
        try
        {
            // Never steer a real delegated request into a running NO_REPLY voice-record turn: stop it first.
            if (_chat.IsAnsweringVoiceRecord)
                await _chat.StopTurnAsync();
            var before = _chat.NewestReply()?.MessageId;
            await _chat.SendTurnAsync(prompt, ct);
            var deadline = _now().AddSeconds(45);
            while (_now() < deadline && !ct.IsCancellationRequested)
            {
                var newest = _chat.NewestReply();
                if (!_chat.IsBusy && newest != null && !newest.Pending && newest.MessageId != before)
                {
                    DispatchLive(new LiveTalkInput.DelegateFinished(callId, SpeechText.SanitizeForSpeech(newest.Text)));
                    return;
                }
                await Task.Delay(150, ct);
            }
            DispatchLive(new LiveTalkInput.DelegateFinished(callId, "The agent is still working on that."));
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            DispatchLive(new LiveTalkInput.DelegateFinished(callId, $"Error: {VoicePlainWords.Plain(ex, "run that request").Message}"));
        }
    }

    private void FallbackToClassic(string reason)
    {
        _events.Record($"talk fallback to classic: {reason}");
        _engine = TalkEngine.Classic;
        if (_session != null) _session = _session with { Engine = TalkEngine.Classic };
        _classic = TalkLoopState.Initial with
        {
            SpeakReplies = TalkPrefs.SpeakReplies(_prefs),
            Notice = TalkNotice.LiveFallback(reason),
        };
        DispatchClassic(new TalkLoopInput.Start());
    }

    private void CloseLiveTransport()
    {
        if (_transport is not { } transport) return;
        _transport = null;
        transport.EventReceived -= OnLiveServerEvent;
        _ = transport.DisposeAsync();
    }

    private static async Task SendControlQuietly(ILiveVoiceTransport transport, string json)
    {
        try { await transport.SendControlAsync(json); } catch (Exception) { }
    }

    // MARK: - Event handlers

    private void OnLevelChanged(double level)
    {
        _level = level;
        LevelChanged?.Invoke(level);
    }

    private void OnSpeakerLevelChanged(double level)
    {
        if (level > 0.001)
        {
            _lastSpeechProgressAt = _now();
            _speechProgressWatch.Restart();
        }
        OnLevelChanged(level);
    }

    private void OnCaptureSpeechStarted()
    {
        _silence.Reset();
        if (!_engine.IsLive()) DispatchClassic(new TalkLoopInput.SpeechDetected());
    }

    private void OnCaptureTakeCompleted(TalkTake take)
    {
        if (_engine.IsLive()) return;
        var merged = take;
        if (string.IsNullOrWhiteSpace(take.LiveWords) && !_liveWordsText.IsEmpty)
            merged = take with { LiveWords = _liveWordsText.Text };
        HandleTake(merged);
    }

    private void OnCaptureBargeIn()
    {
        if (!_engine.IsLive()) DispatchClassic(new TalkLoopInput.BargeIn());
    }

    private void OnCapturePcm(short[] pcm)
    {
        if (_engine.IsLive() && _transport is { } transport && !_live.IsMuted)
        {
            var resampled = _capture.SampleRate == LiveVoiceWire.PcmSampleRate
                ? pcm : TalkWave.ResampleLinear(pcm, _capture.SampleRate, LiveVoiceWire.PcmSampleRate);
            var bytes = new byte[resampled.Length * 2];
            Buffer.BlockCopy(resampled, 0, bytes, 0, bytes.Length);
            _ = SendAudioQuietly(transport, bytes);
        }
        else if (!_engine.IsLive() && _liveWords != null)
        {
            _liveWords.FeedPcm(pcm, _capture.SampleRate);
        }
    }

    private static async Task SendAudioQuietly(ILiveVoiceTransport transport, byte[] bytes)
    {
        try { await transport.SendAudioAsync(bytes); } catch (Exception) { }
    }

    private void OnCaptureFailed(TalkCaptureError error, string message)
    {
        var notice = error == TalkCaptureError.PermissionDenied
            ? TalkNotice.MicDenied()
            : new TalkNotice(error == TalkCaptureError.MeterStalled ? TalkNoticeKind.MeterLost : TalkNoticeKind.MicFailed,
                "Microphone Stopped", message, Action: TalkNoticeAction.Resume);
        if (_engine.IsLive()) DispatchLive(new LiveTalkInput.Disconnected(message, Fatal: true));
        else DispatchClassic(new TalkLoopInput.Pause(TalkPauseCause.Interrupted, notice));
    }

    private void OnLiveWordsChanged(LiveWordsText text)
    {
        _liveWordsText = text;
        Publish();
    }

    private void OnSystemEvent(MemoSystemEvent ev)
    {
        if (!IsActive) return;
        switch (ev)
        {
            case MemoSystemEvent.InterruptionBegan:
                if (_engine.IsLive()) DispatchLive(new LiveTalkInput.MuteToggle());
                else DispatchClassic(new TalkLoopInput.Pause(TalkPauseCause.Interrupted, TalkNotice.Interrupted()));
                break;
            case MemoSystemEvent.OldDeviceUnavailable:
                if (!_engine.IsLive()) DispatchClassic(new TalkLoopInput.Pause(TalkPauseCause.RouteLost, TalkNotice.RouteLost()));
                break;
        }
    }

    private void OnChatChanged()
    {
        if (!_engine.IsLive()) CheckForCompletedReply();
    }

    private void AttachChat(ITalkChatBridge chat)
    {
        DetachChat();
        _chat = chat;
        _chat.Changed += OnChatChanged;
    }

    private void DetachChat()
    {
        if (_chat == null) return;
        _chat.Changed -= OnChatChanged;
        _chat = null;
    }

    private void FinishSessionRecord(TalkEnd reason)
    {
        var session = _session;
        var chat = _chat;
        var duration = _elapsedSeconds;
        var turnCount = _turns.Count;

        // Flush any in-flight live transcript deltas before formatting the transcript record.
        if (!string.IsNullOrWhiteSpace(_liveWordsText.Text))
            VoiceChatRecordCodec.AddFragment(_liveRecordTurns, isUser: true, _liveWordsText.Text);
        if (!string.IsNullOrWhiteSpace(_liveAssistantBuffer))
        {
            VoiceChatRecordCodec.AddFragment(_liveRecordTurns, isUser: false, _liveAssistantBuffer);
            _liveAssistantBuffer = "";
        }

        string? transcriptMessage = null;
        if (!_liveRecordSent && _liveRecordTurns.Count > 0
            && reason is not (TalkEnd.SignedOut or TalkEnd.AccountSwitch or TalkEnd.ChatLeft))
        {
            _liveRecordSent = true;
            transcriptMessage = VoiceChatRecordCodec.FormatMessage(_liveRecordTurns, TimeSpan.FromSeconds(duration));
            _liveRecordTurns.Clear();
        }
        else
        {
            _liveRecordTurns.Clear();
        }

        _endedCaption = VoiceChatRecord.EndedCaption(duration);
        ClearSession();

        if (transcriptMessage != null && chat != null)
            _ = SendVoiceRecordQuietlyAsync(chat, transcriptMessage);

        if (session != null)
        {
            var record = new VoiceChatRecord(session.Scope, session.BotName, session.Engine,
                session.StartedAt, _now(), duration, turnCount, reason, TranscriptMessage: transcriptMessage);
            RecordCompleted?.Invoke(record);
        }
        Publish();
    }

    private async Task SendVoiceRecordQuietlyAsync(ITalkChatBridge chat, string message)
    {
        try { await chat.SendVoiceRecordAsync(message); }
        catch (Exception ex) { _events.Record($"talk voice record send failed: {ex.GetType().Name}"); }
    }

    private void ClearSession()
    {
        CancelSpeechWatchdog();
        _workCts?.Cancel();
        _workCts?.Dispose();
        _workCts = null;
        CloseLiveTransport();
        _capture.Stop();
        _speaker.Stop();
        _liveWords?.Cancel();
        DetachChat();
        _session = null;
        _awaitingReply = false;
        _liveWordsText = LiveWordsText.Empty;
        _liveAssistantBuffer = "";
        _liveSpeakingStallSeconds = 0;
        _level = 0;
        _silence.Reset();
    }

    private void Publish() => StateChanged?.Invoke(CurrentState);

    public void Dispose()
    {
        ClearSession();
        _capture.LevelChanged -= OnLevelChanged;
        _capture.SpeechStarted -= OnCaptureSpeechStarted;
        _capture.TakeCompleted -= OnCaptureTakeCompleted;
        _capture.BargeInDetected -= OnCaptureBargeIn;
        _capture.PcmCaptured -= OnCapturePcm;
        _capture.Failed -= OnCaptureFailed;
        _speaker.LevelChanged -= OnSpeakerLevelChanged;
        if (_liveWords != null) _liveWords.Changed -= OnLiveWordsChanged;
        if (_systemEvents != null) _systemEvents.Raised -= OnSystemEvent;
    }
}
