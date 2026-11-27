namespace Hermes.Core.Voice;

// Port of HermesKit/Voice/TalkDockState.swift: pure UI projection from Talk state to the
// TalkDock bar, notice dock, away pill, silence clock, and audio route controls.

public static class TalkSilence
{
    public const double HintAfterSeconds = 30.0;
    public const double PauseAfterSeconds = 120.0;
}

public enum TalkDockPhase { None, Live, Notice }

public enum TalkDockVisual { Bars, Dots, Spinner, Muted }

public enum TalkDockCenter { None, SendNow, Interrupt, Stop, Unmute }

public sealed record TalkBarControls(
    bool ShowSpeaker,
    bool SpeakerActive,
    bool ShowMute,
    bool IsMuted,
    TalkDockCenter Center,
    bool CenterEnabled,
    bool ShowEnd)
{
    public string CenterLabel => Center switch
    {
        TalkDockCenter.SendNow => "Send Now",
        TalkDockCenter.Interrupt => "Interrupt",
        TalkDockCenter.Stop => "Stop",
        TalkDockCenter.Unmute => "Unmute",
        _ => "",
    };
}

public sealed record TalkDockSnapshot(
    TalkDockPhase Phase,
    TalkStatus Status,
    TalkDockVisual Visual,
    string StatusText,
    string SubText,
    string ElapsedText,
    bool ShowElapsed,
    LiveWordsText LiveWords,
    TalkBarControls Controls,
    TalkNotice? Notice,
    TalkNotice? InlineProblem,
    TalkAudioRoute? ActiveRoute);

public sealed record TalkAwayPillContent(
    bool Visible,
    string Title,
    string Subtitle,
    string Elapsed,
    TalkDockVisual Visual,
    bool IsPaused,
    bool IsError,
    string ChatScope,
    string BotName);

public enum SilenceSignal { None, Hint, Pause }

public sealed class SilenceClock
{
    private double _silentSeconds;
    private bool _hinted;
    private bool _paused;

    public double SilentSeconds => _silentSeconds;

    public SilenceSignal Advance(double dtSeconds, bool isSilentListening)
    {
        if (!isSilentListening)
        {
            Reset();
            return SilenceSignal.None;
        }
        _silentSeconds += Math.Max(0, dtSeconds);
        if (!_paused && _silentSeconds >= TalkSilence.PauseAfterSeconds)
        {
            _paused = true;
            return SilenceSignal.Pause;
        }
        if (!_hinted && _silentSeconds >= TalkSilence.HintAfterSeconds)
        {
            _hinted = true;
            return SilenceSignal.Hint;
        }
        return SilenceSignal.None;
    }

    public void Reset()
    {
        _silentSeconds = 0;
        _hinted = false;
        _paused = false;
    }
}

public static class TalkDockState
{
    public static TalkDockVisual Visual(TalkStatus status) => status switch
    {
        TalkStatus.Listening or TalkStatus.Speaking => TalkDockVisual.Bars,
        TalkStatus.Starting or TalkStatus.Thinking or TalkStatus.Waiting => TalkDockVisual.Dots,
        TalkStatus.Transcribing => TalkDockVisual.Spinner,
        TalkStatus.Muted or TalkStatus.Paused or TalkStatus.Stopped => TalkDockVisual.Muted,
        _ => TalkDockVisual.Bars,
    };

    public static string StatusLine(TalkStatus status, bool silenceHint = false, bool heardSpeech = false, TalkEngine engine = TalkEngine.Classic) =>
        status switch
        {
            TalkStatus.Starting => engine.IsLive() ? $"Connecting {engine.Label()}…" : "Starting voice chat…",
            TalkStatus.Listening when heardSpeech => "Hearing you…",
            TalkStatus.Listening when silenceHint => "Still listening — click End when done",
            TalkStatus.Listening => "Listening…",
            TalkStatus.Transcribing => "Transcribing…",
            TalkStatus.Thinking => "Thinking…",
            TalkStatus.Waiting => "Waiting for your reply…",
            TalkStatus.Speaking => "Speaking…",
            TalkStatus.Muted => "Muted",
            TalkStatus.Paused => "Paused",
            TalkStatus.Stopped => "Voice chat stopped",
            _ => "",
        };

    public static TalkBarControls Controls(TalkStatus status, bool speakReplies, bool heardSpeech, bool hasOutputRoutes = true)
    {
        var isMuted = status == TalkStatus.Muted;
        var center = status switch
        {
            TalkStatus.Listening when heardSpeech => TalkDockCenter.SendNow,
            TalkStatus.Speaking => TalkDockCenter.Interrupt,
            TalkStatus.Thinking or TalkStatus.Transcribing => TalkDockCenter.Stop,
            TalkStatus.Muted => TalkDockCenter.Unmute,
            _ => TalkDockCenter.None,
        };
        var centerEnabled = center != TalkDockCenter.None;
        return new TalkBarControls(
            ShowSpeaker: hasOutputRoutes,
            SpeakerActive: speakReplies,
            ShowMute: status is TalkStatus.Listening or TalkStatus.Speaking or TalkStatus.Thinking or TalkStatus.Waiting or TalkStatus.Muted,
            IsMuted: isMuted,
            Center: center,
            CenterEnabled: centerEnabled,
            ShowEnd: status != TalkStatus.Idle);
    }

    public static TalkDockSnapshot Build(
        TalkStatus status,
        string botName,
        TalkEngine engine,
        double elapsedSeconds,
        LiveWordsText liveWords,
        bool speakReplies,
        bool heardSpeech,
        bool silenceHint,
        TalkNotice? notice,
        TalkAudioRoute? activeRoute)
    {
        if (status == TalkStatus.Idle && notice == null)
        {
            return new TalkDockSnapshot(
                TalkDockPhase.None, TalkStatus.Idle, TalkDockVisual.Bars, "", "", "", false,
                LiveWordsText.Empty, new TalkBarControls(false, false, false, false, TalkDockCenter.None, false, false),
                null, null, activeRoute);
        }

        var isNoticeDock = status is TalkStatus.Paused or TalkStatus.Stopped || (status == TalkStatus.Idle && notice != null);
        var phase = isNoticeDock ? TalkDockPhase.Notice : TalkDockPhase.Live;
        var visual = Visual(status);
        var statusText = StatusLine(status, silenceHint, heardSpeech, engine);
        var elapsed = TalkClock.Elapsed(elapsedSeconds);
        var subText = engine.IsLive() ? $"{botName} · {engine.Label()}" : botName;
        var controls = Controls(status, speakReplies, heardSpeech);
        return new TalkDockSnapshot(
            Phase: phase,
            Status: status,
            Visual: visual,
            StatusText: statusText,
            SubText: subText,
            ElapsedText: elapsed,
            ShowElapsed: status != TalkStatus.Idle && status != TalkStatus.Starting,
            LiveWords: liveWords,
            Controls: controls,
            Notice: isNoticeDock ? notice : null,
            InlineProblem: !isNoticeDock ? notice : null,
            ActiveRoute: activeRoute);
    }

    public static TalkAwayPillContent AwayPill(
        bool visible,
        TalkStatus status,
        string chatScope,
        string botName,
        double elapsedSeconds,
        TalkNotice? notice)
    {
        if (!visible || (status == TalkStatus.Idle && notice == null))
            return new TalkAwayPillContent(false, "", "", "", TalkDockVisual.Bars, false, false, chatScope, botName);

        var paused = status is TalkStatus.Paused or TalkStatus.Muted;
        var isError = status == TalkStatus.Stopped || notice?.Fatal == true;
        var title = isError
            ? notice?.Title ?? "Voice chat stopped"
            : paused
                ? $"{botName} · Paused"
                : $"{botName} · {StatusLine(status)}";
        var subtitle = isError ? (notice?.Message ?? "Click to return") : "Click to return to voice chat";
        return new TalkAwayPillContent(
            Visible: true,
            Title: title,
            Subtitle: subtitle,
            Elapsed: TalkClock.Elapsed(elapsedSeconds),
            Visual: Visual(status),
            IsPaused: paused,
            IsError: isError,
            ChatScope: chatScope,
            BotName: botName);
    }

    public static string CopyText(TalkNotice? notice, VoiceEvents? events = null)
    {
        if (notice == null) return "";
        var parts = new List<string> { notice.Title, notice.Message };
        if (!string.IsNullOrWhiteSpace(notice.Detail)) parts.Add(notice.Detail);
        var log = events?.Text;
        if (!string.IsNullOrWhiteSpace(log)) parts.Add(log);
        return string.Join("\n", parts);
    }

    public static string RouteLabel(TalkAudioRoute? route) => route == null ? "Speaker" : route.Name;
}
