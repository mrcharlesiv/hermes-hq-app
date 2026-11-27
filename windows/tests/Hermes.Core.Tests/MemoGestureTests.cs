using Hermes.Core.Voice;

namespace Hermes.Core.Tests;

/// The memo gesture reducer (HermesKit/Voice/MemoGesture.swift at 93f984bb1): every case of
/// Tests/Voice/MemoGestureTests.swift, ported vector for vector (times in milliseconds, as the Mac's).
public class MemoGestureTests
{
    private const bool On = true, Off = false;

    private static (MemoGestureState State, List<MemoEffect> Effects) Run(MemoInput[] inputs, bool sendOnRelease = On,
        MemoGestureState? from = null)
    {
        var state = from ?? MemoGestureState.Idle;
        var effects = new List<MemoEffect>();
        foreach (var input in inputs)
        {
            var (next, more) = MemoGesture.Reduce(state, input, sendOnRelease);
            state = next;
            effects.AddRange(more);
        }
        return (state, effects);
    }

    private static readonly MemoInput Down = new MemoInput.Down(1000, 402);
    private static readonly MemoInput Started = new MemoInput.Started(1080);

    /// An end effect's action, else the effect's kind (the Mac test's `types()`).
    private static List<string> Types(IEnumerable<MemoEffect> effects) => effects.Select(e => e switch
    {
        MemoEffect.End end => end.Action.ToString().ToLowerInvariant(),
        MemoEffect.Begin => "begin",
        MemoEffect.SendReviewed => "send-reviewed",
        MemoEffect.DiscardReviewed => "discard-reviewed",
        MemoEffect.DraftReviewed => "draft-reviewed",
        MemoEffect.ConfirmDelete => "confirm-delete",
        MemoEffect.Tip => "tip",
        MemoEffect.Failed => "failed",
        MemoEffect.Haptic => "haptic",
        MemoEffect.FocusStatus => "focus-status",
        _ => "?",
    }).ToList();

    [Fact]
    public void TouchDownAsksAtOnceAndIsNotRedUntilConfirmed()
    {
        var pressed = Run([Down]);
        Assert.Equal(MemoPhase.Pressing, pressed.State.Phase);
        Assert.Equal([new MemoEffect.Begin()], pressed.Effects);
        Assert.False(pressed.State.IsRecording);
        var recording = Run([Down, Started]);
        Assert.Equal(MemoPhase.Holding, recording.State.Phase);
        Assert.Equal(1080, recording.State.StartedAt);
    }

    [Fact]
    public void PermissionPromptRecordsNothingAndAllowTeaches()
    {
        var allowed = Run([Down, new MemoInput.Up(1300), new MemoInput.BeginFailed("permission-pending", Granted: true)]);
        Assert.Equal(MemoGestureState.Idle, allowed.State);
        Assert.Equal([new MemoEffect.Begin(), new MemoEffect.Tip(MemoTip.NowHold)], allowed.Effects);
        // A late "started" for that touch never begins recording.
        Assert.Equal(MemoGestureState.Idle, Run([new MemoInput.Started(2000)], from: allowed.State).State);
        var denied = Run([Down, new MemoInput.BeginFailed("permission-pending", Granted: false)]);
        Assert.Equal(new MemoEffect.Failed("permission-denied"), denied.Effects[^1]);
        Assert.Equal(new MemoEffect.Failed("permission-denied"), Run([Down, new MemoInput.BeginFailed("permission-denied")]).Effects[^1]);
        // Busy and cancelled starts go quietly back to idle; anything else says why.
        Assert.Equal([new MemoEffect.Begin()], Run([Down, new MemoInput.BeginFailed("busy")]).Effects);
        Assert.Equal([new MemoEffect.Begin()], Run([Down, new MemoInput.BeginFailed("canceled")]).Effects);
        Assert.Equal(new MemoEffect.Failed("start-failed", "no input"),
            Run([Down, new MemoInput.BeginFailed("start-failed", Message: "no input")]).Effects[^1]);
    }

    [Theory]
    [InlineData(1001.0)]
    [InlineData(1200.0)]
    [InlineData(1000 + MemoGesture.HoldSendMs - 1)]
    public void ReleaseBeforeOneSecondLocksStillRecording(double at)
    {
        var (state, effects) = Run([Down, Started, new MemoInput.Up(at)]);
        Assert.Equal(MemoPhase.Locked, state.Phase);
        Assert.True(state.TapLocked);
        Assert.DoesNotContain("send", Types(effects));
        Assert.DoesNotContain("cancel", Types(effects));
        Assert.Contains(new MemoEffect.FocusStatus(), effects);
    }

    [Fact]
    public void AWobbleStillLocksButIsNotATap()
    {
        // Moved a little (not to either line): still locked, but not a tap for the tip.
        var wobble = Run([Down, Started, new MemoInput.Move(-30, -10), new MemoInput.Up(1400)]);
        Assert.Equal(MemoPhase.Locked, wobble.State.Phase);
        Assert.False(wobble.State.TapLocked);
    }

    [Fact]
    public void TheSecondCountsFromRecordingStart()
    {
        // A Bluetooth headset or the busy-microphone retry: the recorder confirms 900 ms after the touch.
        var slow = Run([Down, new MemoInput.Started(1900), new MemoInput.Up(2100)]);
        Assert.Equal(MemoPhase.Locked, slow.State.Phase);
        Assert.DoesNotContain("send", Types(slow.Effects));
        // A full second of recording after that slow start sends as usual.
        Assert.Equal(new MemoEffect.End(MemoEndAction.Send),
            Run([Down, new MemoInput.Started(1900), new MemoInput.Up(1900 + MemoGesture.HoldSendMs)]).Effects[^1]);
    }

    [Fact]
    public void LiftBeforeConfirmLocksOnceRecordingStarts()
    {
        var (state, effects) = Run([Down, new MemoInput.Up(1050), Started]);
        Assert.Equal(MemoPhase.Locked, state.Phase);
        Assert.True(state.TapLocked);
        Assert.DoesNotContain("send", Types(effects));
        // However long the touch, nothing was recorded while the finger was down: still never a send.
        var longPress = Run([Down, new MemoInput.Up(9000), new MemoInput.Started(9100)]);
        Assert.Equal(MemoPhase.Locked, longPress.State.Phase);
        Assert.DoesNotContain("send", Types(longPress.Effects));
    }

    [Theory]
    [InlineData(1080 + MemoGesture.HoldSendMs)]
    [InlineData(9000.0)]
    public void ReleaseAtOneSecondOrLaterSends(double at)
    {
        var (state, effects) = Run([Down, Started, new MemoInput.Up(at)]);
        Assert.Equal(MemoPhase.Ending, state.Phase);
        Assert.Equal(new MemoEffect.End(MemoEndAction.Send), effects[^1]);
    }

    [Fact]
    public void AnEndedSendGoesIdle() =>
        Assert.Equal(MemoGestureState.Idle,
            Run([Down, Started, new MemoInput.Up(3000), new MemoInput.Ended(MemoEndAction.Send)]).State);

    [Fact]
    public void SendOnReleaseOffStopsIntoReview()
    {
        var (state, effects) = Run([Down, Started, new MemoInput.Up(3000)], Off);
        Assert.Equal(new MemoEffect.End(MemoEndAction.Review), effects[^1]);
        var review = Run([new MemoInput.Ended(MemoEndAction.Review, 2)], Off, from: state);
        Assert.Equal(MemoPhase.Review, review.State.Phase);
        Assert.Equal(2, review.State.Seconds);
        Assert.Equal([new MemoEffect.SendReviewed()], Run([new MemoInput.Send()], Off, from: review.State).Effects);
    }

    [Fact]
    public void SlidingLeftPastTheLineArmsCancel()
    {
        Assert.Equal(-120, MemoGesture.CancelLine(402));
        Assert.Equal(-105, MemoGesture.CancelLine(300));
        var armed = Run([Down, Started, new MemoInput.Move(-125, 0)]);
        Assert.True(armed.State.CancelArmed);
        Assert.Contains(new MemoEffect.Haptic(MemoHaptic.CancelArmed), armed.Effects);
        Assert.Equal([new MemoEffect.End(MemoEndAction.Cancel)], Run([new MemoInput.Up(5000)], from: armed.State).Effects);
        // Sliding back disarms it: that release follows the time rule again.
        var back = Run([new MemoInput.Move(-40, 0), new MemoInput.Up(5000)], from: armed.State);
        Assert.Equal(new MemoEffect.End(MemoEndAction.Send), back.Effects[^1]);
        // Released past the line before the recorder confirmed: nothing is kept.
        Assert.Equal(new MemoEffect.End(MemoEndAction.Cancel),
            Run([Down, new MemoInput.Move(-130, 0), new MemoInput.Up(1100), Started]).Effects[^1]);
    }

    [Fact]
    public void CancelBeatsLockWhenBothLinesAreCrossed()
    {
        // Up past the lock line and left past the cancel line: never locks; the release cancels.
        var both = Run([Down, Started, new MemoInput.Move(-125, -80)]);
        Assert.Equal(MemoPhase.Holding, both.State.Phase);
        Assert.True(both.State.CancelArmed);
        Assert.Equal([new MemoEffect.End(MemoEndAction.Cancel)], Run([new MemoInput.Up(5000)], from: both.State).Effects);
        // The cancel cue plays once per crossing, not on every move past the line.
        var twice = Run([Down, Started, new MemoInput.Move(-125, 0), new MemoInput.Move(-150, 0)]);
        Assert.Single(twice.Effects, e => e == new MemoEffect.Haptic(MemoHaptic.CancelArmed));
    }

    [Fact]
    public void SlidingUpLocks()
    {
        var near = Run([Down, Started, new MemoInput.Move(0, -45)]);
        Assert.True(near.State.LockNear);
        Assert.Equal(MemoPhase.Holding, near.State.Phase);
        var locked = Run([new MemoInput.Move(0, MemoGesture.LockDY)], from: near.State);
        Assert.Equal(MemoPhase.Locked, locked.State.Phase);
        Assert.Contains(new MemoEffect.Haptic(MemoHaptic.Lock), locked.Effects);
        // After locking, lifting the finger changes nothing.
        Assert.Equal(MemoPhase.Locked, Run([new MemoInput.Up(9000)], from: locked.State).State.Phase);
        // Slid up before the recorder confirmed: it starts locked.
        Assert.Equal(MemoPhase.Locked, Run([Down, new MemoInput.Move(0, -80), Started]).State.Phase);
    }

    [Fact]
    public void NoMovementThenReleaseNeverMovesState()
    {
        // A zero move is not past either line: the release is decided by time alone.
        var still = Run([Down, Started, new MemoInput.Move(0, 0), new MemoInput.Up(1500)]);
        Assert.Equal(MemoPhase.Locked, still.State.Phase);
        Assert.True(still.State.TapLocked);
        Assert.False(still.State.CancelArmed);
        Assert.False(still.State.LockNear);
    }

    [Fact]
    public void PointerCancelKeepsADraft()
    {
        Assert.Equal(new MemoEffect.End(MemoEndAction.Draft), Run([Down, Started, new MemoInput.PointerCancel()]).Effects[^1]);
        // Before recording began, there is nothing to keep.
        Assert.Equal(new MemoEffect.End(MemoEndAction.Cancel), Run([Down, new MemoInput.PointerCancel(), Started]).Effects[^1]);
    }

    [Fact]
    public void LockedRowStopSendAndReview()
    {
        var locked = Run([Down, Started, new MemoInput.Up(1200)]).State;
        Assert.Equal([new MemoEffect.End(MemoEndAction.Review)], Run([new MemoInput.Stop()], from: locked).Effects);
        Assert.Equal([new MemoEffect.End(MemoEndAction.Send)], Run([new MemoInput.Send()], from: locked).Effects);
        var review = Run([new MemoInput.Stop(), new MemoInput.Ended(MemoEndAction.Review, 4)], from: locked).State;
        Assert.Equal(MemoPhase.Review, review.Phase);
        Assert.Equal([new MemoEffect.DiscardReviewed()], Run([new MemoInput.Delete()], from: review).Effects);
    }

    [Fact]
    public void DeletingTenSecondsOrMoreAsksFirst()
    {
        var locked = Run([Down, Started, new MemoInput.Up(1200), new MemoInput.Tick(45)]).State;
        var asking = Run([new MemoInput.Delete()], from: locked);
        Assert.Equal([new MemoEffect.ConfirmDelete(45, Recording: true)], asking.Effects);
        Assert.Equal(MemoPhase.Locked, asking.State.Phase);
        Assert.False(Run([new MemoInput.DeleteKept()], from: asking.State).State.ConfirmingDelete);
        Assert.Equal([new MemoEffect.End(MemoEndAction.Cancel)], Run([new MemoInput.DeleteConfirmed()], from: asking.State).Effects);
        var shortTake = Run([Down, Started, new MemoInput.Up(1200), new MemoInput.Tick(9.9), new MemoInput.Delete()]);
        Assert.Equal(new MemoEffect.End(MemoEndAction.Cancel), shortTake.Effects[^1]);
        // In review the same question, with recording false; "confirmed" without a question does nothing.
        var review = Run([new MemoInput.Stop(), new MemoInput.Ended(MemoEndAction.Review, 12)], from: locked).State;
        var reviewAsk = Run([new MemoInput.Delete()], from: review);
        Assert.Equal([new MemoEffect.ConfirmDelete(12, Recording: false)], reviewAsk.Effects);
        Assert.Equal([new MemoEffect.DiscardReviewed()], Run([new MemoInput.DeleteConfirmed()], from: reviewAsk.State).Effects);
        Assert.Empty(Run([new MemoInput.DeleteConfirmed()], from: review).Effects);
    }

    [Fact]
    public void LimitFollowsTheReleaseRuleOrReviews()
    {
        var held = Run([Down, Started]);
        Assert.Equal([new MemoEffect.End(MemoEndAction.Send)], Run([new MemoInput.Limit(600)], On, from: held.State).Effects);
        Assert.Equal([new MemoEffect.End(MemoEndAction.Review)], Run([new MemoInput.Limit(600)], Off, from: held.State).Effects);
        var locked = Run([new MemoInput.Up(1100)], from: held.State);
        Assert.Equal([new MemoEffect.End(MemoEndAction.Review)], Run([new MemoInput.Limit(600)], from: locked.State).Effects);
        // A finger past the cancel line ("Release to Cancel") when the limit arrives cancels; it never sends.
        var armed = Run([new MemoInput.Move(-125, 0)], from: held.State);
        foreach (var option in new[] { On, Off })
            Assert.Equal([new MemoEffect.End(MemoEndAction.Cancel)], Run([new MemoInput.Limit(600)], option, from: armed.State).Effects);
        Assert.Equal(600, Run([new MemoInput.Limit(600)], from: locked.State).State.Seconds);
    }

    [Fact]
    public void NativeStopReturnsToIdle()
    {
        foreach (var from in new[] { Run([Down, Started]).State, Run([Down, Started, new MemoInput.Up(1100)]).State, Run([Down]).State })
        {
            var (state, effects) = Run([new MemoInput.NativeStopped()], from: from);
            Assert.Equal(MemoGestureState.Idle, state);
            Assert.Empty(effects);
        }
    }

    [Fact]
    public void LeavingKeepsADraftNeverSends()
    {
        Assert.Equal(new MemoEffect.End(MemoEndAction.Draft), Run([Down, Started, new MemoInput.Leave()]).Effects[^1]);
        Assert.Equal(new MemoEffect.End(MemoEndAction.Draft), Run([Down, Started, new MemoInput.Up(1100), new MemoInput.Leave()]).Effects[^1]);
        var review = Run([Down, Started, new MemoInput.Up(1100), new MemoInput.Stop(), new MemoInput.Ended(MemoEndAction.Review, 3)]).State;
        var left = Run([new MemoInput.Leave()], from: review);
        Assert.Equal(MemoGestureState.Idle, left.State);
        Assert.Equal([new MemoEffect.DraftReviewed()], left.Effects);
        Assert.Equal(new MemoEffect.End(MemoEndAction.Cancel), Run([Down, new MemoInput.Leave(), Started]).Effects[^1]);
    }

    [Fact]
    public void AccessibilityOpensTheLockedRecorder()
    {
        var (state, effects) = Run([new MemoInput.A11yOpen(1), Started]);
        Assert.Equal(MemoPhase.Locked, state.Phase);
        Assert.Contains(new MemoEffect.FocusStatus(), effects);
        Assert.DoesNotContain("send", Types(effects));
    }

    [Fact]
    public void ASecondTouchIsIgnored()
    {
        var holding = Run([Down, Started]).State;
        var again = Run([new MemoInput.Down(1500, 402)], from: holding);
        Assert.Equal(holding, again.State);
        Assert.Empty(again.Effects);
    }

    /// The cancel line is min(120 pt, 35 % of the composer's width), never less than 0.35 pt (a zero width).
    [Fact]
    public void CancelLineAtSmallWidths()
    {
        Assert.Equal(-0.35, MemoGesture.CancelLine(0), 10);
        Assert.Equal(-70, MemoGesture.CancelLine(200), 10);
    }

    [Fact]
    public void ResetGoesIdleFromAnywhere()
    {
        var locked = Run([Down, Started, new MemoInput.Up(1100)]).State;
        Assert.Equal((MemoGestureState.Idle, 0), (Run([new MemoInput.Reset()], from: locked).State, Run([new MemoInput.Reset()], from: locked).Effects.Count));
    }
}

/// MemoPolicy (HermesKit/Voice/MemoPolicy.swift at 93f984bb1), the parts the gesture's runner uses: the vendor's
/// vectors from Tests/Voice/MemoPolicyTextTests.swift.
public class MemoPolicyTests
{
    [Fact]
    public void FinishTable()
    {
        Assert.Equal(MemoFinish.Await, MemoPolicy.Finish(MemoStopReason.Limit, 0.2));
        Assert.Equal(MemoFinish.Await, MemoPolicy.Finish(MemoStopReason.Limit, 600));
        Assert.Equal(MemoFinish.Discard, MemoPolicy.Finish(MemoStopReason.Cancel, 30));
        foreach (var reason in new[] { MemoStopReason.Interrupted, MemoStopReason.RouteLost, MemoStopReason.Reset, MemoStopReason.Background, MemoStopReason.Error })
        {
            Assert.Equal(MemoFinish.Draft, MemoPolicy.Finish(reason, 1));
            Assert.Equal(MemoFinish.Draft, MemoPolicy.Finish(reason, 12));
            Assert.Equal(MemoFinish.Discard, MemoPolicy.Finish(reason, 0.99));
        }
    }

    [Fact]
    public void LimitSeconds()
    {
        Assert.Equal(600, MemoPolicy.LimitSeconds(32 * 1024 * 1024));
        Assert.Equal(600, MemoPolicy.LimitSeconds());
        // The spec's 512 KB example gives 83 s (0.95 × 524,288 / 6,000); a 60 KB limit is the one too small to record.
        Assert.Equal(83, MemoPolicy.LimitSeconds(512 * 1024));
        Assert.True(MemoPolicy.LimitSeconds(60_000) < MemoPolicy.MinimumLimit);
    }

    [Fact]
    public void LengthsRoundDown()
    {
        Assert.Equal("0:04", MemoPolicy.Length(4.69));
        Assert.Equal("1:30", MemoPolicy.Length(90));
        Assert.Equal("10:00", MemoPolicy.Length(600));
        Assert.Equal("0:00", MemoPolicy.Length(-3));
        Assert.Equal("0:00", MemoPolicy.Length(double.NaN));
    }

    /// A finished memo's total rounds to the nearest second (Telegram): a 2.0 s hold records about 1.9 s.
    [Fact]
    public void TotalsRound()
    {
        Assert.Equal("0:02", MemoPolicy.Total(1.9));
        Assert.Equal("0:01", MemoPolicy.Total(1.49));
        Assert.Equal("1:00", MemoPolicy.Total(59.6));
        Assert.Equal("0:00", MemoPolicy.Total(double.NaN));
        Assert.Equal("0:03", MemoPolicy.Total(2.5));   // Swift's rounded() is half away from zero, not to even
        Assert.Equal("0:01", MemoPolicy.Length(1.9));  // a running clock still rounds down
    }
}
