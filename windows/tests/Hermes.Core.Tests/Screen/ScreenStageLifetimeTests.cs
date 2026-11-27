// [WIN-SCREEN-VIEWER-CORE] The Bot Screen stage paces pointer moves with a display link; the link must not keep the
// stage (and its last full-size frame) alive after the screen goes away. The Mac's Tests/Screen/
// ScreenStageLifetimeTests.swift at 93f984bb1, case for case, over ScreenStageState and a frame source that, like a
// run loop, keeps every link's callback alive until the link is disposed. Swift's `weak var` + autoreleasepool +
// a run-loop turn is a WeakReference + a full GC here.

using System.Runtime.CompilerServices;
using Hermes.Core.Screen;

namespace Hermes.Core.Tests.Screen;

/// A display's frame source: links stay registered (their callbacks held strongly) until disposed.
internal sealed class FakeFrameTicks : IScreenFrameTicks
{
    public sealed class Link(FakeFrameTicks owner, Action tick) : IScreenFrameLink
    {
        public Action Callback { get; } = tick;
        public bool Paused { get; set; }
        public bool Disposed { get; private set; }
        public void Dispose()
        {
            Disposed = true;
            owner.Links.Remove(this);
        }
    }

    public List<Link> Links { get; } = [];
    public int Started { get; private set; }

    public IScreenFrameLink Start(Action tick)
    {
        Started++;
        var link = new Link(this, tick);
        Links.Add(link);
        return link;
    }

    /// One display frame: every running link ticks.
    public void Frame()
    {
        foreach (var link in Links.ToList()) if (!link.Paused) link.Callback();
    }
}

public sealed class ScreenStageLifetimeTests
{
    private static byte[] Picture() => Enumerable.Repeat((byte)0xFF, 8 * 8 * 4).ToArray();   // 8×8, red BGRX

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static WeakReference<ScreenStageState> PacedStage(FakeFrameTicks ticks)
    {
        var stage = new ScreenStageState(ticks);
        stage.Show(Picture(), 8, 8);
        stage.Control = true;
        stage.DebugScheduleMove();
        Assert.True(stage.DebugHasMoveLink);
        return new WeakReference<ScreenStageState>(stage);
    }

    [Fact]
    public void AStageThatPacedAMoveIsFreedWithItsPicture()
    {
        var ticks = new FakeFrameTicks();
        var gone = PacedStage(ticks);
        Assert.Single(ticks.Links);                                // the frame source still holds the link
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
        Assert.False(gone.TryGetTarget(out _));
        // The next frame finds the stage gone and takes its link off the frame source.
        ticks.Frame();
        Assert.Empty(ticks.Links);
    }

    [Fact]
    public void DroppingTouchesTakesTheLinkOffTheRunLoopAndAMoveBuildsANewOne()
    {
        var ticks = new FakeFrameTicks();
        var stage = new ScreenStageState(ticks);
        stage.Show(Picture(), 8, 8);
        stage.Control = true;
        stage.DebugScheduleMove();
        Assert.True(stage.DebugHasMoveLink);
        var first = ticks.Links.Single();
        stage.DropTouches();
        Assert.False(stage.DebugHasMoveLink);
        Assert.True(first.Disposed);
        Assert.Empty(ticks.Links);
        stage.DebugScheduleMove();
        Assert.True(stage.DebugHasMoveLink);
        Assert.Equal(2, ticks.Started);
    }

    // Beyond the Swift's two: what the link paces.

    [Fact]
    public void MovesGoOutOncePerFrameAndOnlyInControl()
    {
        var ticks = new FakeFrameTicks();
        var sent = new List<(byte, int, int)>();
        var stage = new ScreenStageState(ticks) { OnPointer = (m, x, y) => sent.Add((m, x, y)) };
        stage.Show(Picture(), 8, 8);
        stage.Control = true;
        stage.PointerPixel = (3, 4);
        stage.ScheduleMove();
        stage.PointerPixel = (5, 6);
        stage.ScheduleMove();
        ticks.Frame();
        Assert.Equal([((byte)0, 5, 6)], sent);
        Assert.True(ticks.Links.Single().Paused);                  // paused until the next move
        ticks.Frame();
        Assert.Single(sent);
        // Control ending drops touches: no link, a held button let go, nothing sent.
        stage.Held = 1;
        stage.Control = false;
        Assert.False(stage.DebugHasMoveLink);
        Assert.Equal(0, stage.Held);
        stage.ScheduleMove();
        ticks.Frame();
        Assert.Single(sent);
    }
}
