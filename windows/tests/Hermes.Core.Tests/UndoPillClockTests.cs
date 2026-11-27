using Hermes.Core.Bots;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-44] The Undo pill's clock (App/Kit/UndoPill.swift `UndoPillClock`; the Mac's Tests/BotsList/BotsListTests.swift
/// "L237 the Undo pill's clock"), and the life that keeps its timer while the pill is up (the Windows pill made a timer it
/// kept no reference to, and the pill never left).
public class UndoPillClockTests
{
    private static readonly DateTimeOffset Start = DateTimeOffset.FromUnixTimeSeconds(1_000);

    // ------------------------------------------------------------------ the Mac's three tests

    [Fact]
    public void UndoClockRunsFourSecondsAndEightAtAccessibilitySizes()
    {
        var clock = new UndoPillClock(4, accessibilitySize: false);
        Assert.Equal(4, clock.Resume(Start));
        Assert.True(clock.IsRunning);
        Assert.Equal(2.5, clock.Left(Start.AddSeconds(1.5)), 3);
        var large = new UndoPillClock(4, accessibilitySize: true);
        Assert.Equal(8, large.Resume(Start));
        var longer = new UndoPillClock(10, accessibilitySize: true);
        Assert.Equal(10, longer.Resume(Start));
    }

    [Fact]
    public void UndoClockPausesAndResumesWithWhatWasLeft()
    {
        var clock = new UndoPillClock(4, accessibilitySize: false);
        clock.Resume(Start);
        clock.Hold(UndoPillHold.Finger, Start.AddSeconds(1));
        Assert.False(clock.IsRunning);
        // Held for a minute: nothing is lost, and it does not start over.
        var left = clock.Release(UndoPillHold.Finger, Start.AddSeconds(61));
        Assert.NotNull(left);
        Assert.Equal(3, left!.Value, 3);
        Assert.Equal(2, clock.Left(Start.AddSeconds(62)), 3);
    }

    [Fact]
    public void UndoClockWaitsForEveryHold()
    {
        var clock = new UndoPillClock(4, accessibilitySize: false);
        clock.Hold(UndoPillHold.Away, Start);
        Assert.Null(clock.Resume(Start));                                  // made while the away pill shows: never starts
        clock.Hold(UndoPillHold.VoiceOver, Start.AddSeconds(1));
        Assert.Null(clock.Release(UndoPillHold.Away, Start.AddSeconds(5)));
        Assert.Equal(4, clock.Release(UndoPillHold.VoiceOver, Start.AddSeconds(9)));
        // A second resume while running keeps the first start.
        Assert.Equal(3, clock.Resume(Start.AddSeconds(10))!.Value, 3);
        Assert.Equal(0, clock.Left(Start.AddSeconds(100)));
    }

    // ------------------------------------------------------------------ Windows: what counts as an accessibility size

    [Theory]
    [InlineData(1.0, false)]
    [InlineData(1.35, false)]   // iOS xxxLarge (Body 23 pt over 17): the largest size that isn't an accessibility one
    [InlineData(1.49, false)]
    [InlineData(1.5, true)]
    [InlineData(1.65, true)]    // iOS AX1 (Body 28 pt over 17)
    [InlineData(2.25, true)]    // Windows' largest text size
    public void WindowsTextScaleStandsForTheAccessibilitySizes(double factor, bool large) =>
        Assert.Equal(large, UndoPillClock.AccessibilityTextScale(factor));

    [Fact]
    public void TheMacsDurations()
    {
        Assert.Equal(4, UndoPillClock.Seconds);
        Assert.Equal(8, UndoPillClock.AccessibilitySeconds);
    }

    // ------------------------------------------------------------------ the life: one timer, kept, re-armed after a hold

    private sealed class FakeTimers
    {
        public DateTimeOffset Now = Start;
        public readonly List<(TimeSpan After, Action Fire, Handle Handle, DateTimeOffset At)> Armed = [];

        public sealed class Handle : IDisposable
        {
            public bool Stopped;
            public void Dispose() => Stopped = true;
        }

        public IDisposable Schedule(TimeSpan after, Action fire)
        {
            var handle = new Handle();
            Armed.Add((after, fire, handle, Now));
            return handle;
        }

        /// Moves time on and fires every armed timer that is due and still running.
        public void Advance(double seconds)
        {
            Now = Now.AddSeconds(seconds);
            foreach (var (after, fire, handle, at) in Armed.ToList())
                if (!handle.Stopped && (at + after - Now).TotalSeconds <= 1e-9) { handle.Stopped = true; fire(); }
        }
    }

    private static (UndoPillLife Life, FakeTimers Timers, Func<int> Gone) Make(double duration = 4, bool large = false)
    {
        var timers = new FakeTimers();
        var gone = 0;
        var life = new UndoPillLife(new UndoPillClock(duration, large), () => timers.Now, timers.Schedule, () => gone++);
        return (life, timers, () => gone);
    }

    [Fact]
    public void TheLifeGoesAfterFourSecondsWithNothingHoldingIt()
    {
        var (life, timers, gone) = Make();
        life.Start();
        Assert.Single(timers.Armed);
        Assert.Equal(TimeSpan.FromSeconds(4), timers.Armed[0].After);
        Assert.NotNull(life.Timer);   // the life keeps the timer it armed (the pill's own reference)
        timers.Advance(3.9);
        Assert.Equal(0, gone());
        timers.Advance(0.1);
        Assert.Equal(1, gone());
        Assert.True(life.Ended);
        Assert.Null(life.Timer);
    }

    [Fact]
    public void AHoldStopsTheTimerAndLettingGoRunsWhatWasLeft()
    {
        var (life, timers, gone) = Make();
        life.Start();
        timers.Advance(1);
        life.SetHold(UndoPillHold.Pointer, true);
        Assert.True(timers.Armed[0].Handle.Stopped);
        timers.Advance(60);
        Assert.Equal(0, gone());
        life.SetHold(UndoPillHold.VoiceOver, true);
        life.SetHold(UndoPillHold.Pointer, false);   // keyboard focus still inside: still held
        Assert.Single(timers.Armed);
        life.SetHold(UndoPillHold.VoiceOver, false);
        Assert.Equal(2, timers.Armed.Count);
        Assert.Equal(3, timers.Armed[1].After.TotalSeconds, 3);
        timers.Advance(3);
        Assert.Equal(1, gone());
    }

    [Fact]
    public void RepeatedHoldsAndReleasesAreOnce()
    {
        var (life, timers, _) = Make();
        life.Start();
        life.SetHold(UndoPillHold.Pointer, true);
        life.SetHold(UndoPillHold.Pointer, true);
        life.SetHold(UndoPillHold.Pointer, false);
        life.SetHold(UndoPillHold.Pointer, false);
        Assert.Equal(2, timers.Armed.Count);
        Assert.Single(timers.Armed, a => !a.Handle.Stopped);
    }

    [Fact]
    public void AtLargeTextItStaysEightSeconds()
    {
        var (life, timers, gone) = Make(large: true);
        life.Start();
        Assert.Equal(TimeSpan.FromSeconds(8), timers.Armed[0].After);
        timers.Advance(4);
        Assert.Equal(0, gone());
        timers.Advance(4);
        Assert.Equal(1, gone());
    }

    [Fact]
    public void HeldFromTheStartItWaits()
    {
        var (life, timers, gone) = Make();
        life.SetHold(UndoPillHold.Pointer, true);   // the pointer already rests where the pill appears
        life.Start();
        Assert.Empty(timers.Armed);
        timers.Advance(30);
        life.SetHold(UndoPillHold.Pointer, false);
        Assert.Equal(TimeSpan.FromSeconds(4), timers.Armed.Single().After);
        timers.Advance(4);
        Assert.Equal(1, gone());
    }

    [Fact]
    public void EndedByUndoOrAnotherPillItNeverFiresOrRearms()
    {
        var (life, timers, gone) = Make();
        life.Start();
        life.End();
        Assert.True(timers.Armed[0].Handle.Stopped);
        timers.Armed[0].Fire();   // a tick already queued when it ended
        life.SetHold(UndoPillHold.Pointer, true);
        life.SetHold(UndoPillHold.Pointer, false);
        Assert.Single(timers.Armed);
        Assert.Equal(0, gone());
    }

    // ------------------------------------------------------------------ the walk's checks (WalkProof.UndoPill.cs)

    [Fact]
    public void TheWalkFindsTheClockRunningFreeForTheMacsTime()
    {
        var clock = new UndoPillClock(UndoPillClock.Seconds, accessibilitySize: false);
        Assert.Equal("the Undo pill's clock isn't running", WalkProof.UndoPillRuns(clock, false));
        clock.Resume(Start);
        Assert.Null(WalkProof.UndoPillRuns(clock, false));
        Assert.Equal("the Undo pill shows for 4 s, not 8 s", WalkProof.UndoPillRuns(clock, true));
        var six = new UndoPillClock(6, accessibilitySize: false);   // the Windows pill's old default
        six.Resume(Start);
        Assert.Equal("the Undo pill shows for 6 s, not 4 s", WalkProof.UndoPillRuns(six, false));
        clock.Hold(UndoPillHold.VoiceOver, Start);
        clock.Hold(UndoPillHold.Finger, Start);
        Assert.Equal("the Undo pill is held (Finger, VoiceOver)", WalkProof.UndoPillRuns(clock, false));
        var large = new UndoPillClock(UndoPillClock.Seconds, accessibilitySize: true);
        large.Resume(Start);
        Assert.Null(WalkProof.UndoPillRuns(large, true));
    }

    [Fact]
    public void TheWalkWantsThePillGone()
    {
        Assert.Null(WalkProof.UndoPillGone(false, 4.2));
        Assert.Equal("the Undo pill was still up 10.1 s later with nothing holding it", WalkProof.UndoPillGone(true, 10.05));
        Assert.True(WalkProof.UndoPillGoneWithin >= 10);
    }
}
