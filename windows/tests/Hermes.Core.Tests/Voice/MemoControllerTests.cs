// [WIN-MEMO-CONTROLLER] Tests/Voice/MemoControllerTests.swift at 93f984bb1, case for case: MemoController against a
// fake recorder (spec 1x-voice §3.2 effect handling): where a take goes when its chat is gone, what a system stop leaves
// behind, the live waveform of a long take, and the notices' words. The Mac's sixth case
// (fixtureRecorderStartsQuicklyAndSavesAWav) is the recorder's alone and lives in MemoRecorderTests
// (FixtureRecorderStartsQuicklyAndSavesAWav). After the Mac's five, the controller's other paths, from
// MemoController.swift's lines (the Mac has no tests for them). The controller runs on the Mac's main actor
// (MainLoop.Drive). Synthetic data only: a made-up account, the demo bot Ivy, a generated WAV.

using System.Diagnostics;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests.Voice;

/// The Mac's FakeCapture: begins at once, ends with its one file (nothing on cancel), stops by itself on request.
internal sealed class FakeCapture(MemoFile file) : IMemoCapturing
{
    public Action<MemoCaptureEvent>? OnEvent { get; set; }
    public string? AccountKey { get; set; }
    public bool IsRecording { get; private set; }
    public double? StartLatencyMs { get; } = 4;
    public MemoFile File { get; } = file;
    public List<MemoEndAction> Ended { get; } = [];

    public Task<MemoTakeStart> BeginAsync()
    {
        IsRecording = true;
        return Task.FromResult(new MemoTakeStart("take-1", 600));
    }

    public Task<MemoFile?> EndAsync(string id, MemoEndAction action)
    {
        IsRecording = false;
        Ended.Add(action);
        return Task.FromResult(action == MemoEndAction.Cancel ? null : File);
    }

    public void NativeStop(MemoStopReason reason)
    {
        IsRecording = false;
        OnEvent?.Invoke(new MemoCaptureEvent.Stopped(reason, "take-1", 12.4, new MemoStopDisposition.Draft(File)));
    }
}

/// The chat's composer, writing down what the controller asked of it.
internal sealed class FakeMemoHost : IMemoChatHost
{
    public bool IsOnScreen { get; set; } = true;
    public bool CanSendMemo { get; set; } = true;
    public List<string> Log { get; } = [];
    public List<MemoFile> Sent { get; } = [];
    /// The answer to a delete question (null: the test answers later through `Answer`).
    public bool? Confirms { get; set; }
    public Action<bool>? Answer { get; private set; }

    public void MemoSend(MemoFile file, bool keyboardWasUp) { Sent.Add(file); Log.Add($"send:{keyboardWasUp}"); }
    public void MemoStateChanged() => Log.Add("state");
    public void MemoLevelChanged() => Log.Add("level");
    public void MemoWordsChanged() => Log.Add("words");
    public void MemoFocusStatus() => Log.Add("focus");
    public void MemoConfirmDelete(double seconds, bool recording, Action<bool> answer)
    {
        Log.Add($"confirm:{seconds}:{recording}");
        if (Confirms is { } yes) answer(yes); else Answer = answer;
    }
    public void MemoShowTip(MemoTip tip) => Log.Add($"tip:{tip}");
    public void MemoDismissTip() => Log.Add("dismiss-tip");
}

internal sealed class FakeMemoChat(string? scope = null) : IMemoChatSession
{
    public string? MemoScope { get; set; } = scope;
}

public sealed class MemoControllerTests : IDisposable
{
    private readonly VoiceTestStores _stores = new();
    private readonly List<MemoController> _made = [];
    // The target holds its chat and session weakly (as the Mac's): the open chat holds them in the app, the test here.
    private readonly List<object> _alive = [];

    public void Dispose()
    {
        foreach (var c in _made) c.Dispose();
        _stores.Dispose();
    }

    private (MemoController Controller, FakeCapture Capture, MemoTarget Target, MemoryPrefs Prefs) SetUp(
        IMemoChatHost? host = null, IMemoChatSession? session = null, bool sendOnRelease = true)
    {
        var accountId = $"controller-{Guid.NewGuid()}";
        _stores.Activate(accountId);
        var file = _stores.Recording(accountId, seconds: 3);
        var capture = new FakeCapture(file);
        var prefs = new MemoryPrefs();
        if (!sendOnRelease) prefs.Set(MemoController.SendOnReleaseKey, "false");
        var controller = new MemoController(capture, _stores.Stores, prefs);
        _made.Add(controller);
        if (host != null) _alive.Add(host);
        if (session != null) _alive.Add(session);
        var target = new MemoTarget($"acct|ivy|{Guid.NewGuid()}", host, session, "Ivy", MemoPaths.AccountKey(accountId));
        return (controller, capture, target, prefs);
    }

    private static Task<bool> WaitUntil(Func<bool> condition) => VoiceFixtures.WaitUntil(condition);

    private static double Ms() => Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;

    // MARK: MemoControllerTests.swift

    [Fact]
    public Task ASendWhoseChatIsGoneBecomesADraftWithANotice() => MainLoop.Drive(async () =>
    {
        var (controller, capture, target, _) = SetUp();
        controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Holding));
        controller.Input(new MemoInput.Up(Ms() + 5000));
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Idle));
        Assert.Equal([MemoEndAction.Send], capture.Ended);
        Assert.Equal(capture.File, _stores.Stores.Drafts?.Draft(target.Scope));
        var notice = controller.Notice(target.Scope);
        Assert.NotNull(notice);
        Assert.Equal("Memo Saved as a Draft", notice.Title);
        Assert.Equal("It didn’t send. It’s waiting in the message field of your chat with Ivy.", notice.Message);
    });

    [Fact]
    public Task ASystemStopLeavesADraftAndSaysWhy() => MainLoop.Drive(async () =>
    {
        var (controller, capture, target, _) = SetUp();
        controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Holding));
        capture.NativeStop(MemoStopReason.Interrupted);
        Assert.Equal(MemoPhase.Idle, controller.State.Phase);
        Assert.Equal(capture.File, _stores.Stores.Drafts?.Draft(target.Scope));
        var notice = controller.Notice(target.Scope);
        Assert.NotNull(notice);
        Assert.Equal("Recording Stopped", notice.Title);
        Assert.Equal("A call or Siri took the microphone. Your 0:12 memo is waiting in the message field.", notice.Message);
        controller.DismissNotice(target.Scope);
        Assert.Null(controller.Notice(target.Scope));
    });

    [Fact]
    public Task LeavingTurnsATakeIntoADraftAndCancelDeletesNothingKept() => MainLoop.Drive(async () =>
    {
        var (controller, capture, target, _) = SetUp();
        controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Holding));
        controller.Input(new MemoInput.Leave());
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Idle));
        Assert.Equal([MemoEndAction.Draft], capture.Ended);
        Assert.Equal(capture.File, _stores.Stores.Drafts?.Draft(target.Scope));
        Assert.Null(controller.Notice(target.Scope));   // a draft from leaving says nothing
        // Slide to cancel: nothing kept.
        controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Holding));
        controller.Input(new MemoInput.Move(-200, 0));
        controller.Input(new MemoInput.Up(Ms() + 5000));
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Idle));
        Assert.Equal([MemoEndAction.Draft, MemoEndAction.Cancel], capture.Ended);
    });

    /// A locked take past 60 s keeps a live waveform: one new sample per 100 ms, never the whole 600-sample window
    /// refilled with the current level (it went flat, then solid, after about 66 s).
    [Fact]
    public Task LongTakeLevelsKeepTheirShape() => MainLoop.Drive(async () =>
    {
        var (controller, capture, target, _) = SetUp();
        controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Holding));
        controller.Input(new MemoInput.Move(0, -100));
        Assert.Equal(MemoPhase.Locked, controller.State.Phase);
        var maxGrowth = 0;
        for (var tick = 0; tick <= 120 * 15; tick++)
        {
            var seconds = tick / 15.0;
            var level = 0.5 + 0.4 * Math.Sin(seconds * 3.1);
            var before = controller.Levels.Count;
            capture.OnEvent?.Invoke(new MemoCaptureEvent.Level(level, seconds));
            maxGrowth = Math.Max(maxGrowth, controller.Levels.Count - before);
        }
        Assert.Equal(600, controller.Levels.Count);   // the newest 600 samples (60 s) are kept
        Assert.True(maxGrowth <= 2, $"a 15 Hz tick adds one or two samples, not a window ({maxGrowth})");
        var shown = controller.Levels.Skip(controller.Levels.Count - 64).ToArray();
        Assert.True(shown.Select(v => Math.Round(v * 100)).Distinct().Count() > 10, "the visible bars still vary at 2:00");
        // The newest bar is the newest level.
        Assert.True(Math.Abs(controller.Levels[^1] - (0.5 + 0.4 * Math.Sin(120 * 3.1))) < 0.001);
        controller.Reset();
        Assert.Equal(MemoPhase.Idle, controller.State.Phase);
        Assert.Empty(controller.Levels);
    });

    [Fact]
    public void FailureNoticesSayWhatHappened()
    {
        var denied = MemoNotice.Failure("permission-denied", null);
        Assert.Equal("Microphone Access Is Off", denied.Title);
        Assert.Equal($"Turn on Microphone for {MemoNotice.AppName} in Settings to record voice memos.", denied.Message);
        Assert.Equal("Open Settings", denied.ActionTitle);
        Assert.False(denied.Copies, "a permission notice has nothing technical to copy");
        Assert.Equal($"Voice memos record while {MemoNotice.AppName} is on screen.", MemoNotice.Failure("background", null).Message);
        var other = MemoNotice.Failure("start-failed", null);
        Assert.True(other.Message == "The microphone didn’t start. Try again." && other.ActionTitle == "Try Again");
        Assert.True(other.Copies, "a failure offers Copy");
        Assert.Equal("The headset or microphone disconnected.", MemoNotice.Why(MemoStopReason.RouteLost));
        // An audio session's code is said in words, never shown bare (MemoRecorderTests.StartAndSaveReasonsAreWords has
        // the rest of these lines).
        var held = new IOException("OSStatus") { HResult = 561_017_449 };
        Assert.Equal("a call or another app is using the microphone", MemoRecorder.StartReason(held));
        Assert.Equal("Couldn’t start the voice memo: a call or another app is using the microphone.",
            new MemoBeginError.StartFailed(MemoRecorder.StartReason(held)).Message);
        Assert.Equal("the microphone didn’t start", MemoRecorder.StartReason(new IOException("x") { HResult = -50 }));
        Assert.Equal("", MemoRecorder.Reason(new IOException("x") { HResult = 2_003_334_207 }));
        Assert.Equal("the file is empty", MemoRecorder.Reason(MemoRecorder.SaveError("the file is empty")));
        // A group chat's memo that didn't send says why (a bot chat's failed bubble does).
        var draft = MemoNotice.SavedAsDraft("Team", "Couldn’t send the voice memo. Your gateway ran into a problem (error 500). Try again.");
        Assert.True(draft.Detail == "Couldn’t send the voice memo. Your gateway ran into a problem (error 500). Try again." && draft.Draft);
        Assert.Null(MemoNotice.SavedAsDraft("Ivy").Detail);
        // Not here: GroupRoomSession.memoRefusal (Windows' group room sends no memos yet; a gap on the card).
        Assert.Equal("Hermes HQ", MemoNotice.AppName);   // "Hermes HQ" on every identity
    }

    // MARK: MemoController.swift's other paths

    [Fact]
    public Task AHeldSendGoesThroughItsChatOnScreenAndRetiresTheHoldTips() => MainLoop.Drive(async () =>
    {
        // deliverOrKeep (lines 398-411) with the chat showing; lesson (580-590) for a memo sent by holding.
        var host = new FakeMemoHost();
        var (controller, capture, target, prefs) = SetUp(host, new FakeMemoChat());
        var feel = new List<MemoFeel>();
        controller.Feel += feel.Add;
        controller.MemoDown(target, 402, keyboardUp: true);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Holding));
        Assert.Equal(target.AccountKey, capture.AccountKey);
        controller.Input(new MemoInput.Up(Ms() + 5000));
        Assert.True(await WaitUntil(() => host.Sent.Count == 1));
        Assert.Equal(capture.File, host.Sent[0]);
        Assert.Contains("send:True", host.Log);
        Assert.Contains("dismiss-tip", host.Log);
        Assert.True(MemoTips.IsDone(prefs, MemoTip.HoldToRecord) && MemoTips.IsDone(prefs, MemoTip.NowHold));
        Assert.Null(_stores.Stores.Drafts?.Draft(target.Scope));
        Assert.Null(controller.Notice(target.Scope));
        Assert.Equal([MemoFeel.Light], feel);   // the recording cue; a send is silent
        Assert.True(controller.IsTarget(host));
        Assert.False(controller.IsActive(host));
    });

    [Fact]
    public Task AChatThatCantSendKeepsTheMemoUnderItsCurrentScope() => MainLoop.Drive(async () =>
    {
        // canSendMemo false (the composer disabled): a draft and its notice, under the scope the new chat learned after
        // touch-down (line 182); the warning cue plays (announce, 600-607).
        var host = new FakeMemoHost { CanSendMemo = false };
        var chat = new FakeMemoChat();
        var (controller, _, target, _) = SetUp(host, chat);
        var feel = new List<MemoFeel>();
        var changed = new List<string>();
        controller.Feel += feel.Add;
        controller.NoticesChanged += changed.Add;
        controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Holding));
        chat.MemoScope = "acct|ivy|stored-id";
        controller.Input(new MemoInput.Up(Ms() + 5000));
        Assert.True(await WaitUntil(() => controller.Notice("acct|ivy|stored-id") != null));
        Assert.NotNull(_stores.Stores.Drafts?.Draft("acct|ivy|stored-id"));
        Assert.Null(_stores.Stores.Drafts?.Draft(target.Scope));
        Assert.Empty(host.Sent);
        Assert.Equal([MemoFeel.Light, MemoFeel.Warning], feel);
        Assert.Equal(["acct|ivy|stored-id"], changed);
    });

    [Fact]
    public Task ATapLockedSendEarnsTheHoldTipOnce() => MainLoop.Drive(async () =>
    {
        // lesson (586-589): a memo locked by a tap shows "Hold to Record" until it is done; tips off shows none.
        var host = new FakeMemoHost();
        var (controller, _, target, prefs) = SetUp(host, new FakeMemoChat());
        controller.MemoDown(target, 402);
        controller.Input(new MemoInput.Up(Ms()));   // let go before the recorder confirmed
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Locked));
        Assert.True(controller.State.TapLocked);
        Assert.Contains("focus", host.Log);
        controller.Input(new MemoInput.Send());
        Assert.True(await WaitUntil(() => host.Sent.Count == 1));
        Assert.Contains("tip:HoldToRecord", host.Log);
        Assert.False(MemoTips.IsDone(prefs, MemoTip.HoldToRecord));   // shown, not retired: closing it does that

        MemoTips.Finish(prefs, MemoTip.HoldToRecord);
        host.Log.Clear();
        controller.MemoDown(target, 402);
        controller.Input(new MemoInput.Up(Ms()));
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Locked));
        controller.Input(new MemoInput.Send());
        Assert.True(await WaitUntil(() => host.Sent.Count == 2));
        Assert.DoesNotContain("tip:HoldToRecord", host.Log);
    });

    [Fact]
    public Task AReviewedTakeSendsDeletesOrStaysAsADraft() => MainLoop.Drive(async () =>
    {
        // Send Memo on Release off: the release goes to review with the file (lines 368-373); its words can be fixed
        // (reviseWords 540-547); Send sends it through the chat (sendReviewed 189-196).
        var host = new FakeMemoHost();
        var (controller, capture, target, _) = SetUp(host, new FakeMemoChat(), sendOnRelease: false);
        controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Holding));
        controller.Input(new MemoInput.Up(Ms() + 5000));
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Review));
        Assert.Equal(capture.File, controller.File);
        Assert.Equal(MemoPhase.Review, controller.ShownPhase);
        Assert.Equal(3, controller.State.Seconds);
        Assert.Empty(host.Sent);
        controller.ReviseWords("  Pick up milk.  ");
        Assert.Equal("Pick up milk.", controller.File?.Words);
        controller.ReviseWords("   ");
        Assert.Null(controller.File?.Words);
        controller.ReviseWords("Pick up milk.");
        controller.Input(new MemoInput.Send());
        Assert.Equal(MemoPhase.Idle, controller.State.Phase);
        Assert.Null(controller.File);
        Assert.Equal("Pick up milk.", Assert.Single(host.Sent).Words);
        Assert.Equal("", controller.Words);

        // Delete in review: the file leaves the PC (discardReviewed 197-205).
        controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Holding));
        controller.Input(new MemoInput.Up(Ms() + 5000));
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Review));
        controller.Input(new MemoInput.Delete());
        Assert.Equal(MemoPhase.Idle, controller.State.Phase);
        Assert.False(File.Exists(capture.File.Path));
        Assert.Single(host.Sent);
    });

    [Fact]
    public Task LeavingOrResettingDuringReviewKeepsTheTakeAsADraft() => MainLoop.Drive(async () =>
    {
        // screenLeft (618-622) → draftReviewed; reset (627-650) with a take in review → its chat's draft; notices go.
        var host = new FakeMemoHost();
        var (controller, capture, target, _) = SetUp(host, new FakeMemoChat(), sendOnRelease: false);
        controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Holding));
        controller.Input(new MemoInput.Up(Ms() + 5000));
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Review));
        controller.ScreenLeft(new FakeMemoHost());   // another chat's screen: nothing
        Assert.Equal(MemoPhase.Review, controller.State.Phase);
        controller.ScreenLeft(host);
        Assert.Equal(MemoPhase.Idle, controller.State.Phase);
        Assert.Equal(capture.File, _stores.Stores.Drafts?.Draft(target.Scope));
        _stores.Stores.Drafts!.Take(target.Scope);

        controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Holding));
        controller.Input(new MemoInput.Up(Ms() + 5000));
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Review));
        controller.Post(MemoNotice.Failure("background", null), target.Scope);
        host.Log.Clear();
        controller.Reset();
        Assert.Equal(MemoPhase.Idle, controller.State.Phase);
        Assert.Null(controller.Target);
        Assert.Null(controller.File);
        Assert.Equal(capture.File, _stores.Stores.Drafts?.Draft(target.Scope));
        Assert.Null(controller.Notice(target.Scope));
        Assert.Equal(["state"], host.Log);
    });

    [Fact]
    public Task ALongDeleteAsksTheChatAndNoChatKeepsTheTake() => MainLoop.Drive(async () =>
    {
        // confirmDelete (210-214): the chat asks; yes deletes with the rigid cue (buttonHaptic 260-267); with no chat to
        // ask, the take is kept.
        var host = new FakeMemoHost();
        var (controller, capture, target, _) = SetUp(host, new FakeMemoChat());
        var feel = new List<MemoFeel>();
        controller.Feel += feel.Add;
        controller.MemoDown(target, 402, a11y: true);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Locked));
        capture.OnEvent?.Invoke(new MemoCaptureEvent.Level(0.4, 30));
        Assert.Equal(30, controller.State.Seconds);
        controller.Input(new MemoInput.Delete());
        Assert.Contains("confirm:30:True", host.Log);
        Assert.True(controller.State.ConfirmingDelete);
        host.Answer!(true);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Idle));
        Assert.Equal([MemoEndAction.Cancel], capture.Ended);
        Assert.Equal(MemoFeel.Rigid, feel[^1]);

        var (alone, aloneCapture, lone, _) = SetUp();
        alone.MemoDown(lone, 402, a11y: true);
        Assert.True(await WaitUntil(() => alone.State.Phase == MemoPhase.Locked));
        aloneCapture.OnEvent?.Invoke(new MemoCaptureEvent.Level(0.4, 30));
        alone.Input(new MemoInput.Delete());
        Assert.Equal(MemoPhase.Locked, alone.State.Phase);
        Assert.False(alone.State.ConfirmingDelete);
    });

    [Fact]
    public Task AFailedStartAndAnUnsavedStopSayWhy() => MainLoop.Drive(async () =>
    {
        // failed (218-219) with the warning/error cues; a native stop that couldn't save (450-455); a save that failed
        // (380-389).
        var (controller, capture, target, _) = SetUp();
        controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Holding));
        capture.OnEvent?.Invoke(new MemoCaptureEvent.Stopped(MemoStopReason.RouteLost, "take-1", 61.6,
            new MemoStopDisposition.Failed("the disk is full")));
        Assert.Equal(MemoPhase.Idle, controller.State.Phase);
        var notice = controller.Notice(target.Scope)!;
        Assert.Equal("Couldn’t Save the Memo", notice.Title);
        Assert.Equal("The headset or microphone disconnected. The 1:02 recording couldn’t be saved: the disk is full.", notice.Message);
        Assert.Equal("A call or Siri took the microphone. The 0:04 recording couldn’t be saved on this PC.",
            MemoNotice.StoppedUnsaved(MemoStopReason.Interrupted, 4.2, "").Message);
        Assert.Equal("The recording couldn’t be saved on this PC.", MemoNotice.CouldNotSave("").Message);
        Assert.Equal("The recording couldn’t be saved: the recording is empty.", MemoNotice.CouldNotSave("the recording is empty").Message);
        Assert.Equal("Windows reset its audio.", MemoNotice.Why(MemoStopReason.Reset));
        Assert.Equal("Hermes HQ left the screen.", MemoNotice.Why(MemoStopReason.Background));
        Assert.Equal("The recording stopped unexpectedly.", MemoNotice.Why(MemoStopReason.Limit));
        // A begin-failed's notice lands on the chat's scope.
        controller.Input(new MemoInput.Reset());
        controller.MemoDown(target, 402);
        controller.Input(new MemoInput.BeginFailed("permission-denied"));
        Assert.Equal("Microphone Access Is Off", controller.Notice(target.Scope)?.Title);
    });

    [Fact]
    public void SessionNoticesTipsCardAndChipWords()
    {
        // MemoSessionNotice (LiveChatSession+Memo.swift 31-61) kept by scope; MemoTips.swift; MemoNoticeCard.swift;
        // MemoDraftChip.swift.
        var (controller, _, _, prefs) = SetUp();
        MemoSessionNotice.Post(MemoSessionNotice.From(new Dictionary<string, string?>
            { ["scope"] = "acct|ivy|s1", ["kind"] = "transcript", ["detail"] = "speech-to-text is off" })!);
        var transcript = controller.Notice("acct|ivy|s1")!;
        Assert.Equal("No Transcript for This Voice Memo", transcript.Title);
        Assert.Equal("Transcription failed. The memo is still attached and plays in the chat; Hermes gets it without the text.", transcript.Message);
        Assert.Equal("speech-to-text is off", transcript.Detail);
        Assert.Null(MemoSessionNotice.From(new Dictionary<string, string?> { ["kind"] = "draft" }));
        MemoSessionNotice.Post(MemoSessionNotice.From(new Dictionary<string, string?> { ["scope"] = "acct|ivy|s2", ["kind"] = "draft", ["bot"] = "Ivy" })!);
        Assert.True(controller.Notice("acct|ivy|s2")!.Draft);
        Assert.Equal(("transcript", "draft"), (MemoSessionNotice.Raw(MemoSessionNoticeKind.NoTranscript), MemoSessionNotice.Raw(MemoSessionNoticeKind.SavedAsDraft)));
        controller.Dispose();
        MemoSessionNotice.Post(new MemoSessionNoticeInfo(MemoSessionNoticeKind.NoTranscript, "acct|ivy|s3"));
        Assert.Null(controller.Notice("acct|ivy|s3"));

        // Tips: their keys and words, retired for good; In-App Tips off retires them all.
        Assert.Equal(["hq.voice.tip.nowHold", "hq.voice.tip.holdToRecord", "hq.voice.tip.talk"],
            new[] { MemoTip.NowHold, MemoTip.HoldToRecord, MemoTip.Talk }.Select(MemoTips.Key));
        Assert.Equal("Click and Hold to Record", MemoTips.Title(MemoTip.HoldToRecord));
        Assert.Equal("Next time, click and hold the mic and let go to send.", MemoTips.Message(MemoTip.HoldToRecord));
        Assert.Equal("Now Click and Hold to Record", MemoTips.Title(MemoTip.NowHold));
        Assert.Equal("Click and hold the mic and talk, then let go to send.", MemoTips.Message(MemoTip.NowHold));
        Assert.Equal("Talk with Hermes", MemoTips.Title(MemoTip.Talk));
        Assert.False(MemoTips.IsDone(prefs, MemoTip.Talk));
        prefs.Set(MemoTips.InAppTipsKey, "false");
        Assert.True(MemoTips.IsDone(prefs, MemoTip.Talk));

        // The notice card: Copy only where there's something to copy; the copied text.
        Assert.False(MemoNoticeCard.ShowsCopy(MemoNotice.Failure("permission-denied", null)));
        Assert.False(MemoNoticeCard.ShowsCopy(MemoNotice.SavedAsDraft("Ivy")));
        Assert.True(MemoNoticeCard.ShowsCopy(MemoNotice.SavedAsDraft("Team", "error 500")));
        Assert.True(MemoNoticeCard.ShowsCopy(MemoNotice.Failure("start-failed", null)));
        Assert.Equal("Memo Saved as a Draft\nIt didn’t send. It’s waiting in the message field of your chat with Team.\nerror 500",
            MemoNoticeCard.CopyText(MemoNotice.SavedAsDraft("Team", "error 500")));
        Assert.Equal("", MemoNoticeCard.CopyText(null));
        Assert.Equal("Voice Settings…", new MemoNotice(MemoNoticeTone.Info, "t", "m", Action: MemoNoticeAction.VoiceSettings).ActionTitle);
        Assert.Equal("xmark.octagon.fill", MemoNoticeCard.Glyph(MemoNoticeTone.Error));

        // The draft chip.
        var memo = new MemoFile("/Users/me/memo.m4a", 20.4, [], "audio/x-m4a");
        Assert.Equal("Voice Memo 0:20", MemoDraftChipText.Title(memo));
        Assert.Equal("Loading…", MemoDraftChipText.Status(MemoPlayState.Loading, false));
        Assert.Equal("Couldn’t load audio", MemoDraftChipText.Status(MemoPlayState.Idle, true));
        Assert.Equal("", MemoDraftChipText.Status(MemoPlayState.Playing, false));
        Assert.Equal("Try voice memo again", MemoDraftChipText.PlayLabel(MemoPlayState.Playing, true));
        Assert.Equal("Pause Voice Memo", MemoDraftChipText.PlayLabel(MemoPlayState.Playing, false));
        Assert.Equal("Play Voice Memo", MemoDraftChipText.PlayLabel(MemoPlayState.Paused, false));
    }
}
