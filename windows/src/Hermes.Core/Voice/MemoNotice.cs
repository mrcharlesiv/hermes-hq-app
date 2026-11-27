using Hermes.Core.Composer;
using Hermes.Core.Gateways;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Voice;

// [WIN-MEMO-CONTROLLER] The memo's words around the controller, from 93f984bb1: MemoNotice (App/Chat/Voice/
// MemoController.swift lines 23-89), MemoTips (MemoTips.swift), MemoSessionNotice (HermesKit/Chat/
// LiveChatSession+Memo.swift lines 31-61), and what MemoNoticeCard.swift and MemoDraftChip.swift say and show, without
// their views. Strings are the Swift's; where the Mac has a Mac and an iPhone wording, Windows takes the Mac's (a mouse,
// "click and hold"), as DeviceWord.Tap does; where it names the Settings app, Windows' is called Settings, as the
// iPhone's is.

public enum MemoNoticeTone { Warning, Error, Info }

/// The notice card's button. The last three are Talk's and Dictation's (3x-talk §5.7, §8).
public enum MemoNoticeAction { OpenSettings, Retry, RetryTalk, VoiceSettings, RetryDictation }

/// The system's settings, as a message names them (PrivacySettingsLink.swift lines 27-30: "Settings" on the iPhone,
/// "System Settings" on the Mac). Windows' app is Settings (Privacy & security › Microphone).
public static class PrivacySettingsWords
{
    public const string Place = "Settings";
    public static string OpenTitle => $"Open {Place}";
}

/// A notice on the memo card (spec §3.7): stays until closed, acted on, or its chat is left.
public sealed record MemoNotice(MemoNoticeTone Tone, string Title, string Message, string? Detail = null,
    MemoNoticeAction? Action = null, bool Draft = false)
{
    /// "Hermes HQ" (CFBundleDisplayName; the same on every identity).
    public static string AppName => SlashResults.AppName;

    /// Whether the card offers Copy: not on a microphone-permission notice, which has nothing technical to copy.
    public bool Copies => Detail != null || Action != MemoNoticeAction.OpenSettings;

    public string? ActionTitle => Action switch
    {
        MemoNoticeAction.OpenSettings => PrivacySettingsWords.OpenTitle,
        MemoNoticeAction.Retry or MemoNoticeAction.RetryTalk or MemoNoticeAction.RetryDictation => "Try Again",
        MemoNoticeAction.VoiceSettings => "Voice Settings…",
        _ => null,
    };

    /// Why the recorder stopped by itself (`memo-live.ts:294-300`).
    public static string Why(MemoStopReason reason) => reason switch
    {
        MemoStopReason.Interrupted => "A call or Siri took the microphone.",
        MemoStopReason.Background => $"{AppName} left the screen.",
        MemoStopReason.RouteLost => "The headset or microphone disconnected.",
        MemoStopReason.Reset => $"{DeviceWord.System} reset its audio.",
        _ => "The recording stopped unexpectedly.",
    };

    /// A memo that couldn't go out waits in its chat's composer (`memo-live.ts:174-177`). `detail`: why it didn't send
    /// (a group chat's upload or refusal), when known.
    public static MemoNotice SavedAsDraft(string bot, string? detail = null) =>
        new(MemoNoticeTone.Warning, "Memo Saved as a Draft",
            $"It didn’t send. It’s waiting in the message field of your chat with {bot}.", detail, Draft: true);

    /// The memo still went, without its transcript (spec §3.7); `bot` is the chat's bot.
    public static MemoNotice NoTranscript(string bot, string? detail) =>
        new(MemoNoticeTone.Warning, "No Transcript for This Voice Memo",
            $"Transcription failed. The memo is still attached and plays in the chat; {bot} gets it without the text.", detail);

    /// Why a take couldn't begin (`failureNotice`, with V11's wording).
    public static MemoNotice Failure(string code, string? message) => code switch
    {
        "permission-denied" => new(MemoNoticeTone.Warning, "Microphone Access Is Off",
            $"Turn on Microphone for {AppName} in {PrivacySettingsWords.Place} to record voice memos.", Action: MemoNoticeAction.OpenSettings),
        "background" => new(MemoNoticeTone.Info, "Couldn’t Record", $"Voice memos record while {AppName} is on screen."),
        _ => new(MemoNoticeTone.Error, "Couldn’t Record", message ?? "The microphone didn’t start. Try again.", Action: MemoNoticeAction.Retry),
    };

    /// A take ended for keeping couldn't be saved (MemoController.swift lines 385-388).
    public static MemoNotice CouldNotSave(string reason) => new(MemoNoticeTone.Error, "Couldn’t Save the Memo",
        reason.Length == 0 ? $"The recording couldn’t be saved on this {DeviceWord.Name}." : $"The recording couldn’t be saved: {reason}.");

    /// The recorder stopped a take by itself and couldn't save it (lines 452-454). `seconds`: the take's length.
    public static MemoNotice StoppedUnsaved(MemoStopReason reason, double seconds, string error) => new(MemoNoticeTone.Error,
        "Couldn’t Save the Memo", $"{Why(reason)} The {MemoPolicy.Total(seconds)} recording couldn’t be saved"
            + (error.Length == 0 ? $" on this {DeviceWord.Name}." : $": {error}."));

    /// The recorder stopped a take by itself and kept it as the chat's draft (lines 466-467).
    public static MemoNotice StoppedAsDraft(MemoStopReason reason, double seconds) => new(MemoNoticeTone.Info,
        "Recording Stopped", $"{Why(reason)} Your {MemoPolicy.Total(seconds)} memo is waiting in the message field.");
}

/// What the notice card shows and copies (MemoNoticeCard.swift), for the page that draws it.
public static class MemoNoticeCard
{
    public const string Id = "memo.notice", TitleId = "memo.notice.title", MessageId = "memo.notice.message",
        ActionId = "memo.notice.action", CopyId = "memo.notice.copy", CloseId = "memo.notice.close";
    public const string CopyTitle = "Copy Details";
    public const string CloseLabel = "Close";

    /// A warning with nothing behind its words ("No Speech Detected") or a permission notice ("Microphone Access Is
    /// Off") has nothing worth copying; an error always offers it (lines 153-155).
    public static bool ShowsCopy(MemoNotice notice) => notice.Copies && !(notice.Detail == null && notice.Tone != MemoNoticeTone.Error);

    /// What Copy Details puts on the clipboard: title, message and detail, one a line (lines 167-170).
    public static string CopyText(MemoNotice? notice) => notice == null ? ""
        : string.Join("\n", new[] { notice.Title, notice.Message, notice.Detail }.Where(s => !string.IsNullOrEmpty(s)));

    /// The glyph's tone: a triangle (orange), an octagon (red), a circled i (the tint), lines 145-148.
    public static string Glyph(MemoNoticeTone tone) => tone switch
    {
        MemoNoticeTone.Warning => "exclamationmark.triangle.fill",
        MemoNoticeTone.Error => "xmark.octagon.fill",
        _ => "info.circle.fill",
    };
}

/// What the memo draft chip says (MemoDraftChip.swift): "Voice Memo 0:20", a status line while it loads or when it
/// can't, and the play button's and Remove's names.
public static class MemoDraftChipText
{
    public const string Id = "memo.chip", PlayId = "memo.chip.play", TitleId = "memo.chip.title", RemoveId = "memo.chip.remove";
    public const string RemoveLabel = "Remove voice memo";

    public static string Title(MemoFile memo) => $"Voice Memo {MemoPolicy.Total(memo.Seconds)}";

    public static string Status(MemoPlayState state, bool failed) =>
        state == MemoPlayState.Loading ? "Loading…" : failed ? "Couldn’t load audio" : "";

    public static string PlayLabel(MemoPlayState state, bool failed) =>
        failed ? "Try voice memo again" : state == MemoPlayState.Playing ? "Pause Voice Memo" : "Play Voice Memo";

    /// Through the player (`statusText`, `update()`).
    public static string Status(MemoPlayer player, MemoFile memo) => Status(player.StateOf(memo.Path), player.Failed.Contains(memo.Path));
    public static string PlayLabel(MemoPlayer player, MemoFile memo) => PlayLabel(player.StateOf(memo.Path), player.Failed.Contains(memo.Path));
}

/// The two memo tips and Talk's (spec 1x-voice §3.7, V8; MemoTips.swift). They never time out; closing one (or learning
/// the gesture) retires it for good. Kept in the app's preferences under the Mac's keys.
public static class MemoTips
{
    /// Settings › Chat › In-App Tips (AppPreferences.swift `InAppTips`): on unless turned off.
    public const string InAppTipsKey = "hqn.inAppTips";

    public static string Key(MemoTip tip) => tip switch
    {
        MemoTip.NowHold => "hq.voice.tip.nowHold",
        MemoTip.HoldToRecord => "hq.voice.tip.holdToRecord",
        _ => "hq.voice.tip.talk",
    };

    /// [talk] The bot the Talk tip names (set by the chat's voice host before it shows).
    public static string TalkName { get; set; } = "Hermes";

    public static bool TipsOn(IPreferences prefs) => prefs.Get(InAppTipsKey) != "false";

    /// Done, or tips are off.
    public static bool IsDone(IPreferences prefs, MemoTip tip) => !TipsOn(prefs) || prefs.Get(Key(tip)) == "true";

    public static void Finish(IPreferences prefs, MemoTip tip) => prefs.Set(Key(tip), "true");

    public static string Title(MemoTip tip) => tip switch
    {
        MemoTip.NowHold => "Now Click and Hold to Record",
        MemoTip.HoldToRecord => "Click and Hold to Record",
        _ => $"Talk with {TalkName}",
    };

    public static string Message(MemoTip tip) => tip switch
    {
        MemoTip.NowHold => "Click and hold the mic and talk, then let go to send.",
        MemoTip.HoldToRecord => "Next time, click and hold the mic and let go to send.",
        _ => "Click the waveform to talk out loud. Click and hold the mic for a voice memo.",
    };
}

/// A chat's own memo notice, posted by its session (a transcript that failed; a memo that couldn't go out and waits as
/// the chat's draft). The controller keeps it by scope, so it shows when that chat is on screen, now or when it opens
/// next (the Mac's `hq.memo.session.notice` notification). Post from the UI thread.
public enum MemoSessionNoticeKind { NoTranscript, SavedAsDraft }

public sealed record MemoSessionNoticeInfo(MemoSessionNoticeKind Kind, string Scope, string? Detail = null, string? Bot = null);

public static class MemoSessionNotice
{
    public const string Name = "hq.memo.session.notice";
    public const string ScopeKey = "scope", DetailKey = "detail", KindKey = "kind", BotKey = "bot";

    public static string Raw(MemoSessionNoticeKind kind) => kind == MemoSessionNoticeKind.SavedAsDraft ? "draft" : "transcript";

    /// The Mac's userInfo: no scope, no notice; an unknown kind is a missing transcript.
    public static MemoSessionNoticeInfo? From(IReadOnlyDictionary<string, string?> info) =>
        info.GetValueOrDefault(ScopeKey) is not { } scope ? null
            : new(info.GetValueOrDefault(KindKey) == "draft" ? MemoSessionNoticeKind.SavedAsDraft : MemoSessionNoticeKind.NoTranscript,
                scope, info.GetValueOrDefault(DetailKey), info.GetValueOrDefault(BotKey));

    public static event Action<MemoSessionNoticeInfo>? Posted;

    public static void Post(MemoSessionNoticeInfo info) => Posted?.Invoke(info);
}
