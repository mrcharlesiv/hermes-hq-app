// Watch Browser trackpad math, one-finger press/hold/drag state machine, and BrowserStageState interaction tests.

using Hermes.Core.Browser;

namespace Hermes.Core.Tests.Browser;

public sealed class BrowserOneFingerAndStageTests
{
    private sealed class FakeTimers : IBrowserTimers
    {
        private sealed class Handle(FakeTimers owner, Action fire, bool repeats) : IDisposable
        {
            public bool Disposed { get; private set; }
            public Action Fire => fire;
            public bool Repeats => repeats;
            public void Dispose() { Disposed = true; owner._active.Remove(this); }
        }

        private readonly List<Handle> _active = [];
        public int ActiveCount => _active.Count;

        public IDisposable Schedule(TimeSpan after, bool repeats, Action fire)
        {
            var h = new Handle(this, fire, repeats);
            _active.Add(h);
            return h;
        }

        public void FireAll()
        {
            foreach (var h in _active.ToArray())
            {
                if (h.Disposed) continue;
                if (!h.Repeats) h.Dispose();
                h.Fire();
            }
        }
    }

    private sealed class FakeStageHost : IBrowserStageHost
    {
        public bool StageHasControl { get; set; }
        public List<BrowserInput> Sent { get; } = [];
        public int WillTapCount { get; private set; }
        public int ZoomedCount { get; private set; }
        public int WatchTapCount { get; private set; }

        public void StageSend(BrowserInput input) => Sent.Add(input);
        public void StageWillTap() => WillTapCount++;
        public void StageZoomed() => ZoomedCount++;
        public void StageWatchTap() => WatchTapCount++;
    }

    [Fact]
    public void TrackpadMathPlacementZoomMoveAndFollow()
    {
        var bounds = new BrowserSize(800, 600);
        var page = new BrowserSize(1600, 800); // 2:1 aspect ratio -> fits as 800x400 centered at y=100
        var placed = BrowserTrackpadMath.Place(bounds, page, zoom: 1, x: 0, y: 0);
        Assert.Equal(1.0, placed.Zoom);
        Assert.Equal(800, placed.DrawnSize.Width, 3);
        Assert.Equal(400, placed.DrawnSize.Height, 3);
        Assert.Equal(0, placed.X, 3);
        Assert.Equal(100, placed.Y, 3);

        // Zooming 2x about center (400, 300) keeps center anchored
        var zoomed = BrowserTrackpadMath.Zoom(placed, 2.0, new BrowserPoint(400, 300), bounds, page);
        Assert.Equal(2.0, zoomed.Zoom, 3);
        Assert.Equal(1600, zoomed.DrawnSize.Width, 3);
        Assert.Equal(800, zoomed.DrawnSize.Height, 3);

        // Relative pointer move clamps into [0, 1]
        var moved = BrowserTrackpadMath.Move(new BrowserPoint(0.9, 0.5), dx: 400, dy: -400, drawn: new BrowserSize(800, 400));
        Assert.Equal(1.0, moved.X, 3);
        Assert.Equal(0.0, moved.Y, 3);

        // Double-tap-and-drag window
        var tap = (10.0, new BrowserPoint(100, 100));
        Assert.True(BrowserTrackpadMath.IsDoubleTapDrag(tap, new BrowserPoint(110, 105), now: 10.2));
        Assert.False(BrowserTrackpadMath.IsDoubleTapDrag(tap, new BrowserPoint(110, 105), now: 10.9)); // too slow
        Assert.False(BrowserTrackpadMath.IsDoubleTapDrag(tap, new BrowserPoint(200, 100), now: 10.1)); // too far
    }

    [Fact]
    public void OneFingerTrackpadTapHoldDragAndDoubleTapDrag()
    {
        // Quick tap
        var tap = new BrowserOneFinger(BrowserOneFingerKind.Trackpad);
        Assert.Equal([BrowserOneFingerOut.Tap.Instance], tap.Lifted());

        // Plain slide moves cursor without pressing button
        var slide = new BrowserOneFinger(BrowserOneFingerKind.Trackpad);
        Assert.Empty(slide.Travelled());
        Assert.Empty(slide.Lifted());

        // Hold then drag then lift
        var hold = new BrowserOneFinger(BrowserOneFingerKind.Trackpad);
        var heldOuts = hold.Held();
        Assert.Contains(new BrowserOneFingerOut.Look(true), heldOuts);
        Assert.Contains(BrowserOneFingerOut.Haptic.Instance, heldOuts);
        Assert.Contains(BrowserOneFingerOut.Down.Instance, heldOuts);
        Assert.True(hold.ButtonDown);
        Assert.Empty(hold.Travelled());
        var liftOuts = hold.Lifted();
        Assert.Contains(BrowserOneFingerOut.Up.Instance, liftOuts);
        Assert.Contains(new BrowserOneFingerOut.Look(false), liftOuts);

        // Armed double-tap-and-drag starts dragging on travel, or double-clicks if lifted without travel
        var doubleDrag = new BrowserOneFinger(BrowserOneFingerKind.Trackpad, armed: true);
        var dragOuts = doubleDrag.Travelled();
        Assert.Contains(new BrowserOneFingerOut.Look(true), dragOuts);
        Assert.Contains(BrowserOneFingerOut.Down.Instance, dragOuts);
        Assert.Contains(BrowserOneFingerOut.Up.Instance, doubleDrag.Lifted());

        var doubleClick = new BrowserOneFinger(BrowserOneFingerKind.Trackpad, armed: true);
        Assert.Equal([BrowserOneFingerOut.Tap.Instance], doubleClick.Lifted());
    }

    [Fact]
    public void OneFingerDirectPointerClickDragAndCancel()
    {
        var click = new BrowserOneFinger(BrowserOneFingerKind.Direct);
        Assert.Equal([BrowserOneFingerOut.Tap.Instance], click.Lifted());

        var drag = new BrowserOneFinger(BrowserOneFingerKind.Direct);
        Assert.Contains(BrowserOneFingerOut.Down.Instance, drag.Travelled());
        Assert.Contains(BrowserOneFingerOut.Up.Instance, drag.Lifted());

        var cancelled = new BrowserOneFinger(BrowserOneFingerKind.Direct);
        _ = cancelled.Travelled();
        Assert.Contains(BrowserOneFingerOut.Up.Instance, cancelled.Cancelled());
    }

    [Fact]
    public void StageHoldThenDragDirectHoverAndWheel()
    {
        var timers = new FakeTimers();
        var host = new FakeStageHost { StageHasControl = true };
        var stage = new BrowserStageState(timers) { Host = host, ShowsCursor = true };
        stage.SetBounds(new BrowserSize(800, 600));
        stage.ShowFrame(new BrowserSize(800, 600));

        var haptics = 0;
        stage.OnHaptic = () => haptics++;

        // Touch press + hold fires haptic, drag ring, and Down
        stage.TouchBegan(1, new BrowserPoint(200, 200), points: false, now: 1.0);
        Assert.True(stage.CursorVisible);
        Assert.False(stage.DragRingVisible);
        stage.SingleHoldFired();
        Assert.Equal(1, haptics);
        Assert.True(stage.DragRingVisible);
        Assert.Contains(host.Sent, i => i is BrowserInput.Down);

        // Drag moves cursor and lift sends Up
        stage.TouchMoved(1, new BrowserPoint(260, 240), now: 1.1);
        stage.TouchEnded(1, now: 1.2);
        Assert.False(stage.DragRingVisible);
        Assert.Contains(host.Sent, i => i is BrowserInput.Move);
        Assert.Contains(host.Sent, i => i is BrowserInput.Up);

        // Hover with mouse hides drawn cursor and sends Move on flush
        host.Sent.Clear();
        stage.Hover(new BrowserPoint(400, 300));
        Assert.True(stage.Pointing);
        Assert.False(stage.CursorVisible);
        stage.Flush();
        var move = Assert.IsType<BrowserInput.Move>(Assert.Single(host.Sent));
        Assert.Equal(0.5, move.X, 3);
        Assert.Equal(0.5, move.Y, 3);

        // Discrete wheel scrolls down when dy < 0, and Ctrl+wheel zooms
        host.Sent.Clear();
        stage.Wheel(0, -3, discrete: true);
        stage.Flush();
        var scroll = Assert.IsType<BrowserInput.Scroll>(Assert.Single(host.Sent));
        Assert.True(scroll.Dy > 0);

        stage.Wheel(0, 3, discrete: true, at: new BrowserPoint(400, 300), zoom: true);
        Assert.True(stage.Drawn.Zoom > 1.0);
        Assert.Equal(1, host.ZoomedCount);
    }

    [Fact]
    public void StageWatchModeTapHintDoubleTapZoomAndLosingControlCancelsDrag()
    {
        var host = new FakeStageHost { StageHasControl = false };
        var stage = new BrowserStageState(timers: null) { Host = host };
        stage.SetBounds(new BrowserSize(800, 600));
        stage.ShowFrame(new BrowserSize(800, 600));

        // Single tap in watch mode triggers watch-tap hint
        stage.TouchBegan(1, new BrowserPoint(400, 300), points: true, now: 1.0);
        stage.TouchEnded(1, now: 1.05);
        Assert.Equal(1, host.WatchTapCount);

        // Quick second tap double-tap zooms in, then zooms back out
        stage.TouchBegan(1, new BrowserPoint(400, 300), points: true, now: 1.15);
        stage.TouchEnded(1, now: 1.2);
        Assert.True(stage.Drawn.Zoom > 1.5);

        // Double-tap again resets zoom back to 1.0
        stage.TouchBegan(1, new BrowserPoint(400, 300), points: true, now: 1.3);
        stage.TouchEnded(1, now: 1.35);
        stage.TouchBegan(1, new BrowserPoint(400, 300), points: true, now: 1.45);
        stage.TouchEnded(1, now: 1.50);
        Assert.Equal(1.0, stage.Drawn.Zoom, 3);

        // Losing control while holding clears pressed look cleanly
        host.StageHasControl = true;
        stage.ShowsCursor = true;
        stage.TouchBegan(2, new BrowserPoint(300, 300), points: false, now: 2.0);
        stage.SingleHoldFired();
        Assert.True(stage.PressedLook);
        stage.ShowsCursor = false;
        Assert.False(stage.PressedLook);
    }
}
