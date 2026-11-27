namespace Hermes.Core.Voice;

// Port of HermesKit/Voice/TalkLoop.swift and LiveTalkLoop.swift:
// pure state-machine reducers for both Classic (VAD -> STT -> Chat -> TTS) and
// Live (GPT Live / Grok Live realtime WebSocket) voice conversations.

public enum TalkHaptic { None, Started, Listening, Sent, Muted, Paused, Ended, Error }

// MARK: - Classic TalkLoop

public abstract record TalkLoopInput
{
    public sealed record Start : TalkLoopInput;
    public sealed record Started : TalkLoopInput;
    public sealed record StartFailed(TalkNotice Notice) : TalkLoopInput;
    public sealed record SpeechDetected : TalkLoopInput;
    public sealed record TakeReady(byte[] Wav, string? LiveWords = null) : TalkLoopInput;
    public sealed record TranscribeDone(string Text) : TalkLoopInput;
    public sealed record TranscribeFailed(TalkNotice Notice) : TalkLoopInput;
    public sealed record ReplyReady(string Text) : TalkLoopInput;
    public sealed record ReplyEmpty : TalkLoopInput;
    public sealed record SpeechStarted : TalkLoopInput;
    public sealed record SpeechFinished : TalkLoopInput;
    public sealed record SpeechFailed(TalkNotice Notice) : TalkLoopInput;
    public sealed record BargeIn : TalkLoopInput;
    public sealed record MuteToggle : TalkLoopInput;
    public sealed record AutoMute(TalkPauseCause Cause) : TalkLoopInput;
    public sealed record SilenceHint : TalkLoopInput;
    public sealed record SilencePause : TalkLoopInput;
    public sealed record Pause(TalkPauseCause Cause, TalkNotice Notice) : TalkLoopInput;
    public sealed record Resume : TalkLoopInput;
    public sealed record SendNow : TalkLoopInput;
    public sealed record StopCurrent : TalkLoopInput;
    public sealed record SetSpeakReplies(bool On) : TalkLoopInput;
    public sealed record End(TalkEnd Reason) : TalkLoopInput;
}

public abstract record TalkLoopEffect
{
    public sealed record StartCapture : TalkLoopEffect;
    public sealed record StopCapture : TalkLoopEffect;
    public sealed record FlushCapture : TalkLoopEffect;
    public sealed record Transcribe(byte[] Wav) : TalkLoopEffect;
    public sealed record SubmitTurn(string Text) : TalkLoopEffect;
    public sealed record Speak(string Text) : TalkLoopEffect;
    public sealed record StopSpeech : TalkLoopEffect;
    public sealed record StopTurn : TalkLoopEffect;
    public sealed record PlayChime : TalkLoopEffect;
    public sealed record Haptic(TalkHaptic Kind) : TalkLoopEffect;
    public sealed record RecordEnded(TalkEnd Reason) : TalkLoopEffect;
}

public sealed record TalkLoopState(
    TalkStatus Status,
    bool HeardSpeech = false,
    bool SilenceHint = false,
    bool SpeakReplies = true,
    int ConsecutiveTranscribeFailures = 0,
    int ConsecutiveSpeechFailures = 0,
    int Turns = 0,
    TalkNotice? Notice = null)
{
    public static readonly TalkLoopState Initial = new(TalkStatus.Idle);
}

public static class TalkLoop
{
    public const int MaxConsecutiveTranscribeFailures = 3;
    public const int MaxConsecutiveSpeechFailures = 3;

    public static (TalkLoopState State, IReadOnlyList<TalkLoopEffect> Effects) Reduce(TalkLoopState state, TalkLoopInput input)
    {
        var effects = new List<TalkLoopEffect>();
        switch (input)
        {
            case TalkLoopInput.Start:
                if (state.Status != TalkStatus.Idle && state.Status != TalkStatus.Stopped) return (state, effects);
                return (new TalkLoopState(TalkStatus.Starting, SpeakReplies: state.SpeakReplies), [new TalkLoopEffect.StartCapture()]);

            case TalkLoopInput.Started:
                if (state.Status is not (TalkStatus.Starting or TalkStatus.Paused)) return (state, effects);
                return (state with { Status = TalkStatus.Listening, HeardSpeech = false, SilenceHint = false, Notice = null },
                    [new TalkLoopEffect.PlayChime(), new TalkLoopEffect.Haptic(TalkHaptic.Started)]);

            case TalkLoopInput.StartFailed f:
                return (state with { Status = TalkStatus.Stopped, Notice = f.Notice, HeardSpeech = false },
                    [new TalkLoopEffect.StopCapture(), new TalkLoopEffect.Haptic(TalkHaptic.Error)]);

            case TalkLoopInput.SpeechDetected:
                if (state.Status != TalkStatus.Listening) return (state, effects);
                return (state with { HeardSpeech = true, SilenceHint = false }, effects);

            case TalkLoopInput.TakeReady take:
                if (state.Status != TalkStatus.Listening) return (state, effects);
                if (!string.IsNullOrWhiteSpace(take.LiveWords))
                {
                    var text = take.LiveWords.Trim();
                    return (state with
                    {
                        Status = TalkStatus.Thinking,
                        HeardSpeech = false,
                        SilenceHint = false,
                        ConsecutiveTranscribeFailures = 0,
                        Turns = state.Turns + 1,
                        Notice = null,
                    },
                    [new TalkLoopEffect.StopCapture(), new TalkLoopEffect.SubmitTurn(text), new TalkLoopEffect.Haptic(TalkHaptic.Sent)]);
                }
                return (state with { Status = TalkStatus.Transcribing, HeardSpeech = false, SilenceHint = false },
                    [new TalkLoopEffect.StopCapture(), new TalkLoopEffect.Transcribe(take.Wav)]);

            case TalkLoopInput.TranscribeDone done:
                if (state.Status != TalkStatus.Transcribing) return (state, effects);
                var cleaned = done.Text.Trim();
                if (cleaned.Length == 0)
                    return (state with { Status = TalkStatus.Listening, HeardSpeech = false, ConsecutiveTranscribeFailures = 0 },
                        [new TalkLoopEffect.StartCapture()]);
                return (state with
                {
                    Status = TalkStatus.Thinking,
                    ConsecutiveTranscribeFailures = 0,
                    Turns = state.Turns + 1,
                    Notice = null,
                },
                [new TalkLoopEffect.SubmitTurn(cleaned), new TalkLoopEffect.Haptic(TalkHaptic.Sent)]);

            case TalkLoopInput.TranscribeFailed fail:
                if (state.Status != TalkStatus.Transcribing) return (state, effects);
                var nextFails = state.ConsecutiveTranscribeFailures + 1;
                if (fail.Notice.Fatal || nextFails >= MaxConsecutiveTranscribeFailures)
                {
                    return (state with { Status = TalkStatus.Stopped, ConsecutiveTranscribeFailures = nextFails, Notice = fail.Notice with { Fatal = true } },
                        [new TalkLoopEffect.StopCapture(), new TalkLoopEffect.Haptic(TalkHaptic.Error)]);
                }
                return (state with { Status = TalkStatus.Listening, ConsecutiveTranscribeFailures = nextFails, Notice = fail.Notice },
                    [new TalkLoopEffect.StartCapture(), new TalkLoopEffect.Haptic(TalkHaptic.Error)]);

            case TalkLoopInput.ReplyReady reply:
                if (state.Status is not (TalkStatus.Thinking or TalkStatus.Waiting)) return (state, effects);
                var speakable = SpeechText.SanitizeForSpeech(reply.Text);
                if (!state.SpeakReplies || speakable.Length == 0)
                    return (state with { Status = TalkStatus.Listening, HeardSpeech = false, SilenceHint = false },
                        [new TalkLoopEffect.StartCapture()]);
                return (state with { Status = TalkStatus.Speaking, Notice = null },
                    [new TalkLoopEffect.Speak(speakable)]);

            case TalkLoopInput.ReplyEmpty:
                if (state.Status is not (TalkStatus.Thinking or TalkStatus.Waiting)) return (state, effects);
                return (state with { Status = TalkStatus.Listening, HeardSpeech = false, SilenceHint = false },
                    [new TalkLoopEffect.StartCapture()]);

            case TalkLoopInput.SpeechStarted:
                return (state, effects);

            case TalkLoopInput.SpeechFinished:
                if (state.Status != TalkStatus.Speaking) return (state, effects);
                return (state with { Status = TalkStatus.Listening, HeardSpeech = false, SilenceHint = false, ConsecutiveSpeechFailures = 0 },
                    [new TalkLoopEffect.StartCapture()]);

            case TalkLoopInput.SpeechFailed sf:
                if (state.Status != TalkStatus.Speaking) return (state, effects);
                var spFails = state.ConsecutiveSpeechFailures + 1;
                if (sf.Notice.Fatal || spFails >= MaxConsecutiveSpeechFailures)
                {
                    return (state with { Status = TalkStatus.Paused, ConsecutiveSpeechFailures = spFails, Notice = sf.Notice },
                        [new TalkLoopEffect.StopSpeech(), new TalkLoopEffect.StopCapture(), new TalkLoopEffect.Haptic(TalkHaptic.Error)]);
                }
                return (state with { Status = TalkStatus.Listening, ConsecutiveSpeechFailures = spFails, Notice = sf.Notice },
                    [new TalkLoopEffect.StartCapture(), new TalkLoopEffect.Haptic(TalkHaptic.Error)]);

            case TalkLoopInput.BargeIn:
                if (state.Status != TalkStatus.Speaking) return (state, effects);
                return (state with { Status = TalkStatus.Listening, HeardSpeech = true, SilenceHint = false },
                    [new TalkLoopEffect.StopSpeech(), new TalkLoopEffect.StartCapture(), new TalkLoopEffect.Haptic(TalkHaptic.Listening)]);

            case TalkLoopInput.MuteToggle:
                if (state.Status == TalkStatus.Muted)
                    return (state with { Status = TalkStatus.Listening, HeardSpeech = false, SilenceHint = false, Notice = null },
                        [new TalkLoopEffect.StartCapture(), new TalkLoopEffect.Haptic(TalkHaptic.Listening)]);
                if (state.Status is TalkStatus.Listening or TalkStatus.Speaking or TalkStatus.Thinking or TalkStatus.Waiting)
                {
                    var fx = new List<TalkLoopEffect> { new TalkLoopEffect.StopCapture(), new TalkLoopEffect.Haptic(TalkHaptic.Muted) };
                    if (state.Status == TalkStatus.Speaking) fx.Add(new TalkLoopEffect.StopSpeech());
                    return (state with { Status = TalkStatus.Muted, HeardSpeech = false, SilenceHint = false }, fx);
                }
                return (state, effects);

            case TalkLoopInput.AutoMute autoMute:
                if (state.Status is TalkStatus.Idle or TalkStatus.Stopped or TalkStatus.Paused or TalkStatus.Muted)
                    return (state, effects);
                var autoFx = new List<TalkLoopEffect> { new TalkLoopEffect.StopCapture(), new TalkLoopEffect.Haptic(TalkHaptic.Muted) };
                if (state.Status == TalkStatus.Speaking) autoFx.Add(new TalkLoopEffect.StopSpeech());
                var nextStatus = autoMute.Cause is TalkPauseCause.Question or TalkPauseCause.Approval
                    ? TalkStatus.Waiting : TalkStatus.Muted;
                return (state with { Status = nextStatus, HeardSpeech = false, SilenceHint = false }, autoFx);

            case TalkLoopInput.SilenceHint:
                if (state.Status != TalkStatus.Listening || state.HeardSpeech) return (state, effects);
                return (state with { SilenceHint = true }, effects);

            case TalkLoopInput.SilencePause:
                if (state.Status != TalkStatus.Listening) return (state, effects);
                return (state with { Status = TalkStatus.Paused, HeardSpeech = false, SilenceHint = false, Notice = TalkNotice.SilencePaused() },
                    [new TalkLoopEffect.StopCapture(), new TalkLoopEffect.Haptic(TalkHaptic.Paused)]);

            case TalkLoopInput.Pause p:
                if (state.Status is TalkStatus.Idle or TalkStatus.Stopped) return (state, effects);
                return (state with { Status = TalkStatus.Paused, HeardSpeech = false, SilenceHint = false, Notice = p.Notice },
                    [new TalkLoopEffect.StopCapture(), new TalkLoopEffect.StopSpeech(), new TalkLoopEffect.Haptic(TalkHaptic.Paused)]);

            case TalkLoopInput.Resume:
                if (state.Status is not (TalkStatus.Paused or TalkStatus.Stopped or TalkStatus.Muted or TalkStatus.Waiting))
                    return (state, effects);
                return (state with { Status = TalkStatus.Listening, HeardSpeech = false, SilenceHint = false, Notice = null },
                    [new TalkLoopEffect.StartCapture(), new TalkLoopEffect.Haptic(TalkHaptic.Listening)]);

            case TalkLoopInput.SendNow:
                if (state.Status != TalkStatus.Listening) return (state, effects);
                return (state, [new TalkLoopEffect.FlushCapture()]);

            case TalkLoopInput.StopCurrent:
                if (state.Status == TalkStatus.Speaking)
                    return (state with { Status = TalkStatus.Listening, HeardSpeech = false, SilenceHint = false },
                        [new TalkLoopEffect.StopSpeech(), new TalkLoopEffect.StartCapture()]);
                if (state.Status is TalkStatus.Thinking or TalkStatus.Transcribing)
                    return (state with { Status = TalkStatus.Listening, HeardSpeech = false, SilenceHint = false },
                        [new TalkLoopEffect.StopTurn(), new TalkLoopEffect.StartCapture()]);
                return (state, effects);

            case TalkLoopInput.SetSpeakReplies s:
                var speakFx = new List<TalkLoopEffect>();
                if (!s.On && state.Status == TalkStatus.Speaking)
                {
                    speakFx.Add(new TalkLoopEffect.StopSpeech());
                    speakFx.Add(new TalkLoopEffect.StartCapture());
                    return (state with { SpeakReplies = false, Status = TalkStatus.Listening }, speakFx);
                }
                return (state with { SpeakReplies = s.On }, speakFx);

            case TalkLoopInput.End end:
                if (state.Status == TalkStatus.Idle && state.Notice == null) return (state, effects);
                return (TalkLoopState.Initial with { SpeakReplies = state.SpeakReplies },
                    [new TalkLoopEffect.StopCapture(), new TalkLoopEffect.StopSpeech(), new TalkLoopEffect.StopTurn(),
                     new TalkLoopEffect.Haptic(TalkHaptic.Ended), new TalkLoopEffect.RecordEnded(end.Reason)]);

            default:
                return (state, effects);
        }
    }
}

// MARK: - LiveTalkLoop (GPT Live & Grok Live)

public abstract record LiveTalkInput
{
    public sealed record Connect : LiveTalkInput;
    public sealed record Connected : LiveTalkInput;
    public sealed record Disconnected(string Reason, bool Fatal = false) : LiveTalkInput;
    public sealed record UserSpeechStarted : LiveTalkInput;
    public sealed record UserSpeechStopped : LiveTalkInput;
    public sealed record UserTranscript(string Text, bool IsFinal) : LiveTalkInput;
    public sealed record AssistantAudio(byte[] Pcm24k) : LiveTalkInput;
    public sealed record AssistantTextDelta(string Text) : LiveTalkInput;
    public sealed record AssistantDone(string? FullText) : LiveTalkInput;
    public sealed record DelegateRequest(string CallId, string Prompt) : LiveTalkInput;
    public sealed record DelegateFinished(string CallId, string Result) : LiveTalkInput;
    public sealed record MuteToggle : LiveTalkInput;
    public sealed record Interrupt : LiveTalkInput;
    public sealed record End(TalkEnd Reason) : LiveTalkInput;
}

public abstract record LiveTalkEffect
{
    public sealed record OpenTransport : LiveTalkEffect;
    public sealed record CloseTransport : LiveTalkEffect;
    public sealed record StartMic : LiveTalkEffect;
    public sealed record StopMic : LiveTalkEffect;
    public sealed record PlayPcm(byte[] Pcm24k) : LiveTalkEffect;
    public sealed record FlushAudio : LiveTalkEffect;
    public sealed record CancelResponse : LiveTalkEffect;
    public sealed record RunDelegation(string CallId, string Prompt) : LiveTalkEffect;
    public sealed record SendToolResult(string CallId, string Result) : LiveTalkEffect;
    public sealed record SwitchToClassic(string Reason) : LiveTalkEffect;
    public sealed record PlayChime : LiveTalkEffect;
    public sealed record Haptic(TalkHaptic Kind) : LiveTalkEffect;
    public sealed record RecordEnded(TalkEnd Reason) : LiveTalkEffect;
}

public sealed record LiveTalkState(
    TalkStatus Status,
    int ReconnectAttempts = 0,
    int MaxReconnects = 2,
    bool IsMuted = false,
    bool IsDelegating = false,
    string? ActiveCallId = null,
    int Turns = 0,
    bool CanFallbackToClassic = true,
    TalkNotice? Notice = null)
{
    public static readonly LiveTalkState Initial = new(TalkStatus.Idle);
}

public static class LiveTalkResume
{
    /// Compact resume summary injected when a live session reconnects mid-conversation.
    public static string BuildNote(IReadOnlyList<TalkTurn> turns, int maxTurns = 6)
    {
        if (turns.Count == 0) return "";
        var slice = turns.Skip(Math.Max(0, turns.Count - maxTurns));
        return "Conversation resumed after brief reconnect:\n"
            + string.Join("\n", slice.Select(t => $"{t.Role}: {t.Text}"));
    }
}

public static class LiveTalkLoop
{
    public static (LiveTalkState State, IReadOnlyList<LiveTalkEffect> Effects) Reduce(LiveTalkState state, LiveTalkInput input)
    {
        var effects = new List<LiveTalkEffect>();
        switch (input)
        {
            case LiveTalkInput.Connect:
                return (state with { Status = TalkStatus.Starting, Notice = null }, [new LiveTalkEffect.OpenTransport()]);

            case LiveTalkInput.Connected:
                return (state with { Status = state.IsMuted ? TalkStatus.Muted : TalkStatus.Listening, ReconnectAttempts = 0, Notice = null },
                    [new LiveTalkEffect.StartMic(), new LiveTalkEffect.PlayChime(), new LiveTalkEffect.Haptic(TalkHaptic.Started)]);

            case LiveTalkInput.Disconnected d:
                if (state.Status == TalkStatus.Idle) return (state, effects);
                if (!d.Fatal && state.ReconnectAttempts < state.MaxReconnects)
                {
                    return (state with { Status = TalkStatus.Starting, ReconnectAttempts = state.ReconnectAttempts + 1 },
                        [new LiveTalkEffect.CloseTransport(), new LiveTalkEffect.FlushAudio(), new LiveTalkEffect.OpenTransport()]);
                }
                if (state.CanFallbackToClassic)
                {
                    return (LiveTalkState.Initial,
                        [new LiveTalkEffect.CloseTransport(), new LiveTalkEffect.StopMic(), new LiveTalkEffect.FlushAudio(),
                         new LiveTalkEffect.SwitchToClassic(d.Reason)]);
                }
                return (state with
                {
                    Status = TalkStatus.Stopped,
                    Notice = new TalkNotice(TalkNoticeKind.LiveFailed, "Live Voice Disconnected", d.Reason,
                        Action: TalkNoticeAction.Retry, Fatal: true),
                },
                [new LiveTalkEffect.CloseTransport(), new LiveTalkEffect.StopMic(), new LiveTalkEffect.FlushAudio(),
                 new LiveTalkEffect.Haptic(TalkHaptic.Error)]);

            case LiveTalkInput.UserSpeechStarted:
                if (state.IsMuted) return (state, effects);
                var fx = new List<LiveTalkEffect>();
                if (state.Status == TalkStatus.Speaking)
                {
                    fx.Add(new LiveTalkEffect.FlushAudio());
                    fx.Add(new LiveTalkEffect.CancelResponse());
                }
                return (state with { Status = TalkStatus.Listening }, fx);

            case LiveTalkInput.UserSpeechStopped:
                if (state.IsMuted || state.Status != TalkStatus.Listening) return (state, effects);
                return (state with { Status = TalkStatus.Thinking }, effects);

            case LiveTalkInput.UserTranscript ut:
                if (ut.IsFinal && !string.IsNullOrWhiteSpace(ut.Text))
                    return (state with { Turns = state.Turns + 1 }, effects);
                return (state, effects);

            case LiveTalkInput.AssistantAudio audio:
                if (state.Status == TalkStatus.Idle) return (state, effects);
                return (state with { Status = TalkStatus.Speaking }, [new LiveTalkEffect.PlayPcm(audio.Pcm24k)]);

            case LiveTalkInput.AssistantTextDelta:
                return (state, effects);

            case LiveTalkInput.AssistantDone:
                if (state.Status == TalkStatus.Idle) return (state, effects);
                var afterStatus = state.IsDelegating ? TalkStatus.Thinking
                    : state.IsMuted ? TalkStatus.Muted : TalkStatus.Listening;
                return (state with { Status = afterStatus }, effects);

            case LiveTalkInput.DelegateRequest req:
                return (state with { Status = TalkStatus.Thinking, IsDelegating = true, ActiveCallId = req.CallId },
                    [new LiveTalkEffect.RunDelegation(req.CallId, req.Prompt)]);

            case LiveTalkInput.DelegateFinished fin:
                return (state with { IsDelegating = false, ActiveCallId = null },
                    [new LiveTalkEffect.SendToolResult(fin.CallId, fin.Result)]);

            case LiveTalkInput.MuteToggle:
                var nowMuted = !state.IsMuted;
                if (nowMuted)
                    return (state with { IsMuted = true, Status = TalkStatus.Muted },
                        [new LiveTalkEffect.StopMic(), new LiveTalkEffect.Haptic(TalkHaptic.Muted)]);
                return (state with { IsMuted = false, Status = TalkStatus.Listening },
                    [new LiveTalkEffect.StartMic(), new LiveTalkEffect.Haptic(TalkHaptic.Listening)]);

            case LiveTalkInput.Interrupt:
                if (state.Status == TalkStatus.Speaking)
                    return (state with { Status = state.IsMuted ? TalkStatus.Muted : TalkStatus.Listening },
                        [new LiveTalkEffect.FlushAudio(), new LiveTalkEffect.CancelResponse()]);
                return (state, effects);

            case LiveTalkInput.End end:
                return (LiveTalkState.Initial,
                    [new LiveTalkEffect.StopMic(), new LiveTalkEffect.FlushAudio(), new LiveTalkEffect.CloseTransport(),
                     new LiveTalkEffect.Haptic(TalkHaptic.Ended), new LiveTalkEffect.RecordEnded(end.Reason)]);

            default:
                return (state, effects);
        }
    }
}
