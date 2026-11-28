using System.Diagnostics;
using Hermes.Core.Settings;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Voice;

// [WIN-MEMO-CONTROLLER] The chat's memo controller (spec 1x-voice §3.2; App/Chat/Voice/MemoController.swift at
// 93f984bb1, a port of W:src/ui-voice/memo-live.ts): one take at a time app-wide. The take's chat is frozen at
// touch-down (C3): a send goes only through that chat while its screen still shows it, anything else keeps the memo as a
// draft chip there, with a notice that says so. Cues follow the code: light on recording and lock, rigid crossing into
// cancel; a send is silent.
//
// Built over the ported pieces, not beside them: the gesture runs in `MemoSession` (MemoGesture.Reduce and its effects),
// the recorder half (begin, end, the recorder's levels and its own stops) is `MemoCaptureLink`, drafts and waveforms are
// the signed-in account's `MemoAccountStores`, playback is `MemoPlayer`. This class is the rest of the Swift: where a
// saved take goes (send, draft chip, review), the notices by chat, the tips the gesture teaches, the live waveform and
// what the composer's recorder row shows (`ShownPhase`, `Levels`, `Words`).
//
// Seams (the Swift each replaces):
//   IMemoChatHost         ChatVoiceHost (weak): the chat's composer and recorder row
//   IMemoChatSession      ChatVoiceMemos (weak): the chat's session; its `MemoScope` once a new chat learns its id
//   MemoAccountStores     MemoAccountStores.shared (drafts, shapes) and MemoPaths.remove
//   MemoPlayer            MemoPlayer.shared (null: no player, nothing to stop)
//   IPreferences          UserDefaults: Send Memo on Release (VoicePrefs) and the tips (MemoTips)
//   Feel                  Haptics.prepare / Haptics.play (light, rigid, warning, error); Windows has no haptic engine,
//                         the page may play a sound or nothing
//   MemoSessionNotice     NotificationCenter `hq.memo.session.notice`; NoticesChanged is `hq.memo.notices.changed`
//   nowMs                 CACurrentMediaTime() * 1000
// Not ported: Live Words (the listener, its microphone tap, WordFixes.learn, the words log lines; Core has no
// LiveWords: the take's words are only what the saved file carries and what review revises), the "memo send"
// signpost, AppLog lines, the DEBUG Send on Release switch, and the recorder's keep-awake scope ([talk]).
// One-thread: build and use it on the UI thread (the Mac's @MainActor); the recorder's answers come back there.

/// The chat's composer and recorder row (the Mac's ChatVoiceHost, as the controller calls it).
public interface IMemoChatHost
{
    bool IsOnScreen { get; }
    /// On screen with its composer enabled.
    bool CanSendMemo { get; }
    /// Send the take as the chat's next bubble (with the field's words).
    void MemoSend(MemoFile file, bool keyboardWasUp);
    /// The phase changed: re-lay out the composer.
    void MemoStateChanged();
    /// A move or a tick within a phase: redraw the recorder's row and circle only.
    void MemoLevelChanged();
    void MemoWordsChanged();
    void MemoFocusStatus();
    /// A long take's Delete asks first; `answer(true)` deletes.
    void MemoConfirmDelete(double seconds, bool recording, Action<bool> answer);
    void MemoShowTip(MemoTip tip);
    void MemoDismissTip();
}

/// The chat's session as memos see it (ChatVoiceMemos): its layout scope now (a new chat learns its stored id after
/// touch-down), else null.
public interface IMemoChatSession
{
    string? MemoScope { get; }
}

/// Where a take goes, fixed at touch-down. The host and session are held weakly, as the Mac's.
public sealed class MemoTarget(string scope, IMemoChatHost? host, IMemoChatSession? session, string botName, string accountKey)
{
    private readonly WeakReference<IMemoChatHost>? _host = host == null ? null : new(host);
    private readonly WeakReference<IMemoChatSession>? _session = session == null ? null : new(session);

    /// The chat's layout scope (the draft store's key).
    public string Scope { get; } = scope;
    /// "Ivy", for the words on screen.
    public string BotName { get; } = botName;
    public string AccountKey { get; } = accountKey;

    public IMemoChatHost? Host => _host != null && _host.TryGetTarget(out var h) ? h : null;
    public IMemoChatSession? Session => _session != null && _session.TryGetTarget(out var s) ? s : null;
}

/// A haptic the Mac plays (Haptics.swift's kinds the controller uses).
public enum MemoFeel { Light, Rigid, Warning, Error }

public sealed class MemoController : IDisposable
{
    public const string NoticesChangedName = "hq.memo.notices.changed";
    public const string SendOnReleaseKey = VoicePrefs.SendOnReleaseKey;
    /// One level per 100 ms; the newest 600 (60 s) are kept.
    public const int LevelWindow = 600;

    private readonly MemoCaptureLink _link;
    private readonly MemoSession _session;
    private readonly IMemoCapturing _capture;
    private readonly MemoAccountStores _stores;
    private readonly IPreferences _prefs;
    private readonly MemoPlayer? _player;
    private readonly Func<double> _nowMs;
    private readonly Dictionary<string, MemoNotice> _notices = [];
    private readonly List<double> _levels = [];
    private int _levelSamples;
    private bool _keyboardWasUp;
    private string? _reviewHeard;
    // The state before the input that's running, and after it (MemoSession raises Changed before it runs the effects).
    private MemoGestureState _last = MemoGestureState.Idle, _previous = MemoGestureState.Idle;
    // The take's target when its end was asked for: a reset meanwhile still delivers it there.
    private MemoTarget? _endingTarget;
    // M17: Live words listener & captured words preserved across native/focus interruptions until the draft/save consumes them.
    private ILiveWordsListening? _wordsListener;
    private string _capturedWords = "";
    private Task<string>? _finishingWords;

    public MemoController(IMemoCapturing capture, MemoAccountStores stores, IPreferences prefs, MemoPlayer? player = null,
        Func<double>? nowMs = null)
    {
        _capture = capture;
        _stores = stores;
        _prefs = prefs;
        _player = player;
        _nowMs = nowMs ?? (() => Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency);
        _link = new MemoCaptureLink(capture, _nowMs);
        _session = new MemoSession(new Recorder(this), () => SendOnRelease, Run, ConfirmDelete);
        _link.Attach(_session);
        _session.Changed += Changed;
        _link.Saved += Saved;
        _link.SaveFailed += SaveFailed;
        _link.Stopped += Stopped;
        _link.LevelChanged += LevelChanged;
        // A chat's own memo notices are kept by scope here, so they show when that chat is on screen.
        MemoSessionNotice.Posted += SessionNotice;
    }

    /// Optional factory producing a live-words listener per take (M17).
    public Func<ILiveWordsListening?>? MakeWords { get; set; }

    public void Dispose()
    {
        CancelWords();
        MemoSessionNotice.Posted -= SessionNotice;
    }

    /// Raised when a chat's notices change (the scope).
    public event Action<string>? NoticesChanged;
    /// A haptic the Mac would play here.
    public event Action<MemoFeel>? Feel;

    public MemoGestureState State => _session.State;
    public MemoTarget? Target { get; private set; }
    public string? TakeId => _link.TakeId;
    public double Limit => _link.Limit > 0 ? _link.Limit : 600;
    /// The take in review.
    public MemoFile? File { get; private set; }
    public double Level { get; private set; }
    /// One level per 100 ms of the take (the live waveform), newest last; the newest 600 are kept.
    public IReadOnlyList<double> Levels => _levels;
    /// The phase the recorder showed last (an `ending` from `locked` keeps the locked row, disabled).
    public MemoPhase ShownPhase { get; private set; } = MemoPhase.Idle;
    /// In review, the words the memo will carry ("" when none).
    public string Words { get; private set; } = "";
    public double Now => _nowMs();

    /// Send Memo on Release (V12): on unless Settings turned it off.
    public bool SendOnRelease => VoicePrefs.SendOnRelease(_prefs);

    public bool IsTarget(IMemoChatHost host) => ReferenceEquals(Target?.Host, host);

    /// The recorder is showing for `host` (anything but idle).
    public bool IsActive(IMemoChatHost host) => State.Phase != MemoPhase.Idle && IsTarget(host);

    // MARK: Touches

    /// A press on a mic (or Narrator's Invoke, `a11y`), with where the take is going. A press while another take runs is
    /// ignored; a take whose chat can't be reached any more becomes a draft there first.
    public void MemoDown(MemoTarget target, double width, bool a11y = false, bool keyboardUp = false)
    {
        if (State.Phase != MemoPhase.Idle)
        {
            if (State.Phase != MemoPhase.Ending && Target?.Host?.IsOnScreen != true) Input(new MemoInput.Leave());
            return;
        }
        Target = target;
        File = null;
        Words = "";
        _reviewHeard = null;
        _capturedWords = "";
        _finishingWords = null;
        _levels.Clear();
        _levelSamples = 0;
        Level = 0;
        _keyboardWasUp = keyboardUp;
        Input(a11y ? new MemoInput.A11yOpen(Now) : new MemoInput.Down(Now, width));
    }

    public void Input(MemoInput input)
    {
        var before = State;
        _session.Input(input);
        ButtonHaptic(input, before, State);
    }

    /// The locked recorder's own buttons: Stop takes the memo to review with a light tap; Delete throws the take away
    /// with the rigid one, once it is really gone (a long take asks first).
    private void ButtonHaptic(MemoInput input, MemoGestureState before, MemoGestureState after)
    {
        if (after.Phase == before.Phase) return;
        switch (input)
        {
            case MemoInput.Stop: Feel?.Invoke(MemoFeel.Light); break;
            case MemoInput.Delete or MemoInput.DeleteConfirmed: Feel?.Invoke(MemoFeel.Rigid); break;
        }
    }

    private void Changed(MemoGestureState next)
    {
        var before = _last;
        _previous = before;
        _last = next;
        var shownBefore = ShownPhase;
        if (next.Phase != MemoPhase.Ending) ShownPhase = next.Phase;
        if (next.Phase == MemoPhase.Idle && before.Phase != MemoPhase.Idle) Settle();
        // A move or the clock's tick within one phase only redraws the row and circle; a new phase re-lays out.
        if (next.Phase == before.Phase && ShownPhase == shownBefore) Target?.Host?.MemoLevelChanged();
        else Target?.Host?.MemoStateChanged();
    }

    private void Settle()
    {
        _levels.Clear();
        _levelSamples = 0;
        Level = 0;
        DropWords();
    }

    /// Where a take's draft and notices go: the chat's scope now, else the one frozen at touch-down.
    private static string Scope(MemoTarget target) => target.Session?.MemoScope ?? target.Scope;

    // MARK: Effects (memo-live.ts:87-118)

    private void Run(MemoEffect effect)
    {
        var target = Target;
        switch (effect)
        {
            case MemoEffect.SendReviewed:
                if (File is { } file && target != null) DeliverOrKeep(file, target);
                File = null;
                _reviewHeard = null;
                target?.Host?.MemoStateChanged();
                break;
            case MemoEffect.DiscardReviewed:
                _reviewHeard = null;
                // Deleted in review: the file leaves the PC now.
                if (File is { } discarded)
                {
                    if (_player?.IsCurrent(discarded.Path) == true) _player.Stop();
                    _stores.Paths.Remove(discarded.Path);
                }
                File = null;
                target?.Host?.MemoStateChanged();
                break;
            case MemoEffect.DraftReviewed:
                if (File is { } kept && target != null) DeliverDraft(kept, target);
                File = null;
                break;
            case MemoEffect.Tip tip:
                target?.Host?.MemoShowTip(tip.Value);
                break;
            case MemoEffect.Failed failed:
                CancelWords();
                if (target != null) Announce(MemoNotice.Failure(failed.Code, failed.Message), Scope(target));
                break;
            case MemoEffect.Haptic haptic:
                Feel?.Invoke(haptic.Value == MemoHaptic.CancelArmed ? MemoFeel.Rigid : MemoFeel.Light);
                break;
            case MemoEffect.FocusStatus:
                target?.Host?.MemoFocusStatus();
                break;
            // ConfirmDelete is asked through ConfirmDelete below; Begin and End go to the recorder.
        }
    }

    private void ConfirmDelete(double seconds, bool recording, Action<bool> answer)
    {
        // The answer comes back as the controller's own input, so a delete really done plays its cue.
        void Answered(bool yes)
        {
            var before = State;
            answer(yes);
            ButtonHaptic(yes ? new MemoInput.DeleteConfirmed() : new MemoInput.DeleteKept(), before, State);
        }
        if (Target?.Host is not { } host) { Answered(false); return; }
        host.MemoConfirmDelete(seconds, recording, Answered);
    }

    /// The session's recorder: the link, with what the controller does as a take begins and ends.
    private sealed class Recorder(MemoController owner) : IMemoRecorder
    {
        public void Begin()
        {
            // A memo owns the audio: playback stops first.
            owner._player?.Stop();
            owner._capture.AccountKey = owner.Target?.AccountKey;
            owner.StartWords();
            owner._link.Begin();
        }

        public void End(MemoEndAction action)
        {
            owner.Lesson(action, owner._previous);
            owner._endingTarget = owner.Target;
            if (action == MemoEndAction.Cancel) owner.CancelWords();
            else owner.BeginFinishingWords();
            owner._link.End(action);
        }
    }

    // MARK: The recorder's side

    private void Saved(MemoEndAction action, MemoFile file)
    {
        var target = _endingTarget ?? Target;
        var resolved = ApplyCapturedWords(file, out var pendingWords);
        _stores.Shapes?.Remember(resolved.Path, resolved.Peaks, resolved.Seconds);
        if (action == MemoEndAction.Review)
        {
            Words = resolved.Words ?? "";
            _reviewHeard = resolved.Words;
            File = resolved;
            if (pendingWords != null) _ = CompleteReviewWordsAsync(pendingWords, resolved);
            return;
        }
        if (target == null) return;
        if (action == MemoEndAction.Send)
        {
            if (pendingWords != null) _ = CompleteSendWordsAsync(pendingWords, resolved, target);
            else DeliverOrKeep(resolved, target);
        }
        else if (action == MemoEndAction.Draft)
        {
            DeliverDraft(resolved, target);
            if (pendingWords != null) _ = CompleteDraftWordsAsync(pendingWords, resolved, target);
        }
    }

    private void SaveFailed(MemoEndAction action, string reason)
    {
        CancelWords();
        if (action == MemoEndAction.Cancel || (_endingTarget ?? Target) is not { } target) return;
        Announce(MemoNotice.CouldNotSave(reason), Scope(target));
    }

    private void Stopped(MemoCaptureEvent.Stopped stopped)
    {
        if (Target is not { } target)
        {
            CancelWords();
            return;
        }
        switch (stopped.Disposition)
        {
            case MemoStopDisposition.Failed failed:
                CancelWords();
                Announce(MemoNotice.StoppedUnsaved(stopped.Reason, stopped.Seconds, failed.Words), Scope(target));
                break;
            case MemoStopDisposition.Draft draft:
                // M17: preserve live transcription words across native/focus interruptions — never cancel the listener
                // before finishing and saving the captured words onto the draft.
                BeginFinishingWords();
                var preserved = ApplyCapturedWords(draft.Memo, out var pendingWords);
                _stores.Shapes?.Remember(preserved.Path, preserved.Peaks, preserved.Seconds);
                DeliverDraft(preserved, target);
                if (pendingWords != null) _ = CompleteDraftWordsAsync(pendingWords, preserved, target);
                Announce(MemoNotice.StoppedAsDraft(stopped.Reason, stopped.Seconds), Scope(target));
                break;
            default:
                CancelWords();
                break;
        }
    }

    private void LevelChanged(double level, double seconds)
    {
        Level = level;
        // One sample per 100 ms of the take, counted apart from `Levels` (which keeps only the newest 600): a take past
        // 60 s must not refill the whole window with the current level on every tick.
        var want = (int)(seconds * 10);
        if (want > _levelSamples)
        {
            _levels.AddRange(Enumerable.Repeat(level, Math.Min(want - _levelSamples, 64)));
            _levelSamples = want;
            if (_levels.Count > LevelWindow) _levels.RemoveRange(0, _levels.Count - LevelWindow);
        }
        // A new second ticks the gesture (the link sends it next); within one only the row redraws.
        if (Math.Floor(seconds) == Math.Floor(State.Seconds)) Target?.Host?.MemoLevelChanged();
    }

    /// Sends only through the chat still showing the composer it was recorded in; anything else keeps it as a draft chip
    /// in that chat, with a notice saying so (`deliverOrKeep`).
    private void DeliverOrKeep(MemoFile file, MemoTarget target)
    {
        if (target.Host is { CanSendMemo: true } host && target.Session != null)
        {
            host.MemoSend(file, _keyboardWasUp);
            return;
        }
        DeliverDraft(file, target);
        Announce(MemoNotice.SavedAsDraft(target.BotName), Scope(target));
    }

    /// The memo waits as its chat's draft chip (on screen now, or when the chat opens next); for an account no longer
    /// signed in, its file goes.
    private void DeliverDraft(MemoFile file, MemoTarget target)
    {
        if (_stores.Drafts is { } drafts && _stores.Key == target.AccountKey) drafts.Set(file, Scope(target));
        else _stores.Paths.Remove(file.Path);
    }

    // MARK: Words (Live Words + review revisions; M17 preserves captured words across interruptions)

    /// Updates live words during an active take (also populated automatically by `MakeWords` listeners).
    public void UpdateLiveWords(string text)
    {
        if (State.Phase is MemoPhase.Idle or MemoPhase.Review) return;
        Words = text;
        if (!string.IsNullOrWhiteSpace(text)) _capturedWords = text.Trim();
        Target?.Host?.MemoWordsChanged();
    }

    /// Feeds PCM samples to the active live-words listener when one was created via `MakeWords`.
    public void FeedLivePcm(ReadOnlySpan<short> pcm, int sampleRate) => _wordsListener?.FeedPcm(pcm, sampleRate);

    private void StartWords()
    {
        CancelWords();
        if (MakeWords?.Invoke() is not { } listener) return;
        _wordsListener = listener;
        listener.Changed += OnWordsChanged;
        _ = StartWordsQuietlyAsync(listener);
    }

    private static async Task StartWordsQuietlyAsync(ILiveWordsListening listener)
    {
        try { await listener.StartAsync(); }
        catch (Exception) { }
    }

    private void OnWordsChanged(LiveWordsText text)
    {
        var combined = text.Text;
        Words = combined;
        if (!string.IsNullOrWhiteSpace(combined)) _capturedWords = combined.Trim();
        Target?.Host?.MemoWordsChanged();
    }

    /// Finishes the active live-words listener without cancelling it so captured words survive into draft/review/send.
    private void BeginFinishingWords()
    {
        if (_wordsListener is not { } listener) return;
        _wordsListener = null;
        listener.Changed -= OnWordsChanged;
        try { _finishingWords = listener.FinishAsync(); }
        catch (Exception) { _finishingWords = null; }
    }

    private void CancelWords()
    {
        if (_wordsListener is { } listener)
        {
            _wordsListener = null;
            listener.Changed -= OnWordsChanged;
            try { listener.Cancel(); } catch (Exception) { }
        }
        _finishingWords = null;
        _capturedWords = "";
        DropWords();
    }

    private MemoFile ApplyCapturedWords(MemoFile file, out Task<string>? pendingWords)
    {
        pendingWords = null;
        var finishing = _finishingWords;
        var captured = _capturedWords;
        _finishingWords = null;
        _capturedWords = "";

        if (!string.IsNullOrWhiteSpace(file.Words)) return file;

        if (finishing != null)
        {
            if (finishing.IsCompletedSuccessfully)
            {
                var settled = finishing.Result.Trim();
                if (settled.Length > 0) return file with { Words = settled };
            }
            else if (!finishing.IsCompleted)
            {
                pendingWords = finishing;
            }
        }

        var trimmed = captured.Trim();
        return trimmed.Length > 0 ? file with { Words = trimmed } : file;
    }

    private async Task CompleteDraftWordsAsync(Task<string> pending, MemoFile file, MemoTarget target)
    {
        string heard;
        try { heard = (await pending).Trim(); }
        catch (Exception) { return; }
        if (heard.Length == 0 || string.Equals(file.Words, heard, StringComparison.Ordinal)) return;
        var scope = Scope(target);
        if (_stores.Drafts?.Draft(scope) is { } current && current.Path == file.Path)
            DeliverDraft(current with { Words = heard }, target);
    }

    private async Task CompleteReviewWordsAsync(Task<string> pending, MemoFile file)
    {
        string heard;
        try { heard = (await pending).Trim(); }
        catch (Exception) { return; }
        if (heard.Length == 0 || State.Phase != MemoPhase.Review || File?.Path != file.Path) return;
        if (!string.IsNullOrWhiteSpace(Words)) return;
        File = File with { Words = heard };
        Words = heard;
        _reviewHeard = heard;
        Target?.Host?.MemoWordsChanged();
    }

    private async Task CompleteSendWordsAsync(Task<string> pending, MemoFile file, MemoTarget target)
    {
        string heard = "";
        try { heard = (await pending).Trim(); }
        catch (Exception) { }
        var finalFile = heard.Length > 0 && string.IsNullOrWhiteSpace(file.Words) ? file with { Words = heard } : file;
        DeliverOrKeep(finalFile, target);
    }

    private void DropWords()
    {
        if (Words.Length == 0) return;
        Words = "";
        Target?.Host?.MemoWordsChanged();
    }

    /// A take's words in review were fixed: the memo carries the fixed words (null when none are left: the gateway
    /// transcribes it then). Spec 3x-live-words §3.1.1.
    public void ReviseWords(string text)
    {
        if (State.Phase != MemoPhase.Review || File is not { } file) return;
        var trimmed = text.Trim();
        File = file with { Words = trimmed.Length == 0 ? null : trimmed };
        Words = text;
        Target?.Host?.MemoWordsChanged();
    }

    /// What the take in review settled on before any fix (the Mac learns word fixes from it).
    public string? ReviewHeard => _reviewHeard;

    // MARK: Tips (memo-live.ts:274-284)

    /// A memo sent by holding teaches both hold tips; a memo locked by a tap earns "Hold to Record" once.
    private void Lesson(MemoEndAction action, MemoGestureState before)
    {
        if (action is MemoEndAction.Cancel or MemoEndAction.Draft) return;
        if (before.Phase == MemoPhase.Holding)
        {
            MemoTips.Finish(_prefs, MemoTip.HoldToRecord);
            MemoTips.Finish(_prefs, MemoTip.NowHold);
            Target?.Host?.MemoDismissTip();
            return;
        }
        if (before.TapLocked && !MemoTips.IsDone(_prefs, MemoTip.HoldToRecord)) Target?.Host?.MemoShowTip(MemoTip.HoldToRecord);
    }

    // MARK: Notices

    public MemoNotice? Notice(string scope) => _notices.GetValueOrDefault(scope);

    private void SessionNotice(MemoSessionNoticeInfo info)
    {
        var notice = info.Kind == MemoSessionNoticeKind.SavedAsDraft
            ? MemoNotice.SavedAsDraft(info.Bot ?? "Hermes", info.Detail)
            : MemoNotice.NoTranscript(info.Bot ?? "Hermes", info.Detail);
        Announce(notice, info.Scope);
    }

    /// A memo's own notice, with the cue its tone gives (an info one plays none). `Post` alone stays silent: Dictation and
    /// Talk post through it after playing their own.
    private void Announce(MemoNotice notice, string scope)
    {
        switch (notice.Tone)
        {
            case MemoNoticeTone.Error: Feel?.Invoke(MemoFeel.Error); break;
            case MemoNoticeTone.Warning: Feel?.Invoke(MemoFeel.Warning); break;
        }
        Post(notice, scope);
    }

    public void Post(MemoNotice notice, string scope)
    {
        _notices[scope] = notice;
        NoticesChanged?.Invoke(scope);
    }

    public void DismissNotice(string scope)
    {
        if (!_notices.Remove(scope)) return;
        NoticesChanged?.Invoke(scope);
    }

    // MARK: Lifecycle

    /// The take's chat left the screen: a take left behind becomes a draft chip there (C3).
    public void ScreenLeft(IMemoChatHost host)
    {
        if (!IsTarget(host) || State.Phase == MemoPhase.Idle) return;
        Input(new MemoInput.Leave());
    }

    /// Sign-out or an account switch: a take still recording is dropped. A take in review waits as its chat's draft on
    /// the account it was recorded for (UX study #267; a sign-out purges that account's drafts right after).
    public void Reset()
    {
        _link.Reset();
        CancelWords();
        if (File is { } file)
        {
            if (_player?.IsCurrent(file.Path) == true) _player.Stop();
            if (Target is { } target) DeliverDraft(file, target); else _stores.Paths.Remove(file.Path);
        }
        File = null;
        _reviewHeard = null;
        var host = Target?.Host;
        Target = null;
        _session.Input(new MemoInput.Reset());
        _last = _previous = MemoGestureState.Idle;
        ShownPhase = MemoPhase.Idle;
        Settle();
        _notices.Clear();
        host?.MemoStateChanged();
    }
}
