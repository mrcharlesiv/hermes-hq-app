using Hermes.Core.Voice;

namespace Hermes.Core.Tests;

/// MemoSession, the effect runner (MemoController.input/run at 93f984bb1, without audio): a synthetic recorder answers
/// each begin and end the way the real one does, later and through Input. No microphone, speech, network or message.
public class MemoSessionTests
{
    /// A stand-in recorder: writes every call into the shared log, and the test answers for it.
    private sealed class FakeRecorder(List<string> log) : IMemoRecorder
    {
        public int Begins, Ends;
        public void Begin() { Begins++; log.Add("recorder.begin"); }
        public void End(MemoEndAction action) { Ends++; log.Add($"recorder.end:{action}"); }
    }

    private static (MemoSession Session, FakeRecorder Recorder, List<string> Log) Make(bool sendOnRelease = true)
    {
        var log = new List<string>();
        var recorder = new FakeRecorder(log);
        var session = new MemoSession(recorder, () => sendOnRelease, effect =>
        {
            switch (effect)
            {
                case MemoEffect.SendReviewed: log.Add("ui.send-reviewed"); break;
                case MemoEffect.DiscardReviewed: log.Add("ui.discard-reviewed"); break;
                case MemoEffect.DraftReviewed: log.Add("ui.draft-reviewed"); break;
                case MemoEffect.ConfirmDelete c: log.Add($"ui.confirm-delete:{c.Seconds}:{c.Recording}"); break;
                case MemoEffect.Tip t: log.Add($"ui.tip:{t.Value}"); break;
                case MemoEffect.Failed f: log.Add($"ui.failed:{f.Code}"); break;
                case MemoEffect.Haptic h: log.Add($"ui.haptic:{h.Value}"); break;
                case MemoEffect.FocusStatus: log.Add("ui.focus-status"); break;
            }
        }, confirmDelete: (_, _, _) => { });   // the test answers the question itself, through Input
        return (session, recorder, log);
    }

    private static bool AnySend(IEnumerable<string> log) =>
        log.Any(l => l == "recorder.end:Send" || l == "ui.send-reviewed");

    [Fact]
    public void ACompleteDayOfTakesNeverSendsByAccident()
    {
        var (s, recorder, log) = Make();

        // 1. A quick tap released before the recorder confirmed: it records hands-free, it never sends.
        s.Input(new MemoInput.Down(0, 402));
        s.Input(new MemoInput.Up(40));
        s.Input(new MemoInput.Started(300));
        Assert.Equal(MemoPhase.Locked, s.State.Phase);
        Assert.True(s.State.TapLocked);
        s.Input(new MemoInput.Tick(12));
        // 2. A call arrives: the recorder stopped on its own; a 12 s take is kept as a draft by the recorder.
        Assert.Equal(MemoFinish.Draft, s.RecorderStopped(MemoStopReason.Interrupted, 12));
        Assert.Equal(MemoGestureState.Idle, s.State);

        // 3. Hold, slide up past the lock line, then 45 s; Delete asks first and "Keep" keeps recording.
        s.Input(new MemoInput.Down(10_000, 402));
        s.Input(new MemoInput.Started(10_050));
        s.Input(new MemoInput.Move(0, -45));
        s.Input(new MemoInput.Move(0, -80));
        s.Input(new MemoInput.Tick(45));
        s.Input(new MemoInput.Delete());
        Assert.True(s.State.ConfirmingDelete);
        s.Input(new MemoInput.DeleteKept());
        // 4. Stop goes to review; the recorder answers with the saved length; leaving the chat keeps it as a draft.
        s.Input(new MemoInput.Stop());
        Assert.Equal(MemoPhase.Ending, s.State.Phase);
        s.Input(new MemoInput.Ended(MemoEndAction.Review, 45.2));
        Assert.Equal(MemoPhase.Review, s.State.Phase);
        s.Input(new MemoInput.Leave());

        // 5. Hold past a second but slid left past the cancel line: cancelled, nothing kept.
        s.Input(new MemoInput.Down(20_000, 300));
        s.Input(new MemoInput.Started(20_100));
        s.Input(new MemoInput.Move(-110, 0));
        s.Input(new MemoInput.Up(25_000));
        s.Input(new MemoInput.Ended(MemoEndAction.Cancel));

        // 6. Narrator opens the locked recorder; the 10-minute limit takes it to review; Delete (≥10 s) confirmed.
        s.Input(new MemoInput.A11yOpen(30_000));
        s.Input(new MemoInput.Started(30_100));
        Assert.Equal(MemoFinish.Await, s.RecorderStopped(MemoStopReason.Limit, 600));
        s.Input(new MemoInput.Ended(MemoEndAction.Review, 600));
        s.Input(new MemoInput.Delete());
        s.Input(new MemoInput.DeleteConfirmed());

        // 7. Late, stray inputs after it all settled change nothing.
        s.Input(new MemoInput.Up(99_000));
        s.Input(new MemoInput.Send());
        s.Input(new MemoInput.Ended(MemoEndAction.Send));

        Assert.Equal(MemoGestureState.Idle, s.State);
        Assert.False(AnySend(log));
        Assert.Equal(4, recorder.Begins);
        Assert.Equal(
        [
            "recorder.begin", "ui.haptic:Lock", "ui.focus-status",
            "recorder.begin", "ui.haptic:Recording", "ui.haptic:Lock", "ui.focus-status",
            "ui.confirm-delete:45:True",
            "recorder.end:Review",
            "ui.draft-reviewed",
            "recorder.begin", "ui.haptic:Recording", "ui.haptic:CancelArmed",
            "recorder.end:Cancel",
            "recorder.begin", "ui.haptic:Lock", "ui.focus-status",
            "recorder.end:Review",
            "ui.confirm-delete:600:False",
            "ui.discard-reviewed",
        ], log);
    }

    [Fact]
    public void AFullHoldSendsExactlyOnce()
    {
        var (s, recorder, log) = Make();
        s.Input(new MemoInput.Down(0, 402));
        s.Input(new MemoInput.Started(80));
        s.Input(new MemoInput.Up(1080));
        // While the recorder is saving, more releases, Send and limits do nothing.
        s.Input(new MemoInput.Up(1200));
        s.Input(new MemoInput.Send());
        s.Input(new MemoInput.Limit(600));
        s.Input(new MemoInput.Ended(MemoEndAction.Send));
        s.Input(new MemoInput.Send());
        Assert.Equal(["recorder.begin", "ui.haptic:Recording", "recorder.end:Send"], log);
        Assert.Equal(1, recorder.Ends);
        Assert.Equal(MemoGestureState.Idle, s.State);
    }

    [Fact]
    public void SendOnReleaseOffReviewsAndOnlyTheReviewSendSends()
    {
        var (s, _, log) = Make(sendOnRelease: false);
        s.Input(new MemoInput.Down(0, 402));
        s.Input(new MemoInput.Started(80));
        s.Input(new MemoInput.Up(5000));
        s.Input(new MemoInput.Ended(MemoEndAction.Review, 4.9));
        Assert.False(AnySend(log));
        Assert.Equal(4.9, s.State.Seconds);
        s.Input(new MemoInput.Send());
        Assert.Equal(["recorder.begin", "ui.haptic:Recording", "recorder.end:Review", "ui.send-reviewed"], log);
    }

    [Fact]
    public void ADeleteQuestionWithNobodyToAskKeepsTheTake()
    {
        // MemoController answers "kept" when no window can ask (the host is gone): the take is not thrown away.
        var log = new List<string>();
        var s = new MemoSession(new FakeRecorder(log), () => true, effect => { }, confirmDelete: null);
        s.Input(new MemoInput.A11yOpen(0));
        s.Input(new MemoInput.Started(10));
        s.Input(new MemoInput.Tick(30));
        s.Input(new MemoInput.Delete());
        Assert.Equal(MemoPhase.Locked, s.State.Phase);
        Assert.False(s.State.ConfirmingDelete);
        Assert.DoesNotContain("recorder.end:Cancel", log);
    }

    [Fact]
    public void ARecorderStopBelowASecondIsDiscardedAndAnEndBeforeStartCancels()
    {
        var (s, recorder, log) = Make();
        s.Input(new MemoInput.Down(0, 402));
        s.Input(new MemoInput.Started(80));
        Assert.Equal(MemoFinish.Discard, s.RecorderStopped(MemoStopReason.Background, 0.4));
        Assert.Equal(MemoGestureState.Idle, s.State);
        // Leaving before the recorder confirmed: the late start ends the take as a cancel.
        s.Input(new MemoInput.Down(1000, 402));
        s.Input(new MemoInput.Leave());
        s.Input(new MemoInput.Started(1300));
        Assert.Equal("recorder.end:Cancel", log[^1]);
        Assert.False(AnySend(log));
        Assert.Equal(2, recorder.Begins);
    }

    // MemoController.begin() at 93f984bb1: a start that lands after the gesture went idle stops the recording.
    public static TheoryData<string> GoneIdleBeforeStart => new() { "reset", "begin-failed", "native-stopped" };

    [Theory]
    [MemberData(nameof(GoneIdleBeforeStart))]
    public void AStartThatLandsWhileIdleStopsTheMicrophone(string how)
    {
        var (s, recorder, log) = Make();
        s.Input(new MemoInput.Down(0, 400));
        s.Input(how switch
        {
            "reset" => new MemoInput.Reset(),
            "begin-failed" => new MemoInput.BeginFailed("busy"),
            _ => new MemoInput.NativeStopped(),
        });
        Assert.Equal(MemoGestureState.Idle, s.State);
        log.Clear();
        s.Input(new MemoInput.Started(300));
        Assert.Equal(new[] { "recorder.end:Cancel" }, log.Where(l => l.StartsWith("recorder.")));
        Assert.Equal(MemoGestureState.Idle, s.State);
        Assert.Equal(1, recorder.Ends);
        Assert.False(AnySend(log));
    }

    [Fact]
    public void ALateStartTheGestureAlreadyCancelsIsNotEndedTwice()
    {
        var (s, recorder, log) = Make();
        s.Input(new MemoInput.Down(0, 400));
        s.Input(new MemoInput.Leave());
        Assert.Equal(0, recorder.Ends);
        // The gesture's own cancel ends the take; the session must not add a second End.
        s.Input(new MemoInput.Started(300));
        Assert.Equal(1, recorder.Ends);
        s.Input(new MemoInput.Ended(MemoEndAction.Cancel));
        Assert.Equal(MemoGestureState.Idle, s.State);
        // A stray repeat of that start, after the take already ended, has nothing left to stop.
        s.Input(new MemoInput.Started(400));
        Assert.Equal(1, recorder.Ends);
        // The next take is tracked afresh.
        s.Input(new MemoInput.Down(1000, 400));
        s.Input(new MemoInput.Reset());
        s.Input(new MemoInput.Started(1300));
        Assert.Equal("recorder.end:Cancel", log[^1]);
        Assert.Equal(2, recorder.Ends);
        Assert.False(AnySend(log));
    }
}
