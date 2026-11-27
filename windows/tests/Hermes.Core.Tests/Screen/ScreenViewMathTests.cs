// [WIN-SCREEN-WIRE-KEYS-MATH] The Screen's view math and touch rules (Hermes.Core/Screen/ScreenViewMath.cs), ported
// case for case from the Mac's Tests/Screen/ScreenViewMathTests.swift at 93f984bb1 (docs/spec/3x-screen.md §5.5, §5.7;
// itself ported from the web app's bot-screen-phone.test.ts so the numbers are the same everywhere). CGFloat is double;
// CGPoint / CGSize / CGRect are ScreenPoint / ScreenSize / ScreenRect.

using Hermes.Core.Screen;
using GA = Hermes.Core.Screen.ScreenGesture.Action;

namespace Hermes.Core.Tests.Screen;

public class ScreenViewMathTests
{
    internal static bool Close(double a, double b, double tolerance = 0.001) => Math.Abs(a - b) <= tolerance;

    private static ScreenView V(double zoom, double x, double y) => new(zoom, x, y);

    [Fact]
    public void ClampsAndZoomsAboutAPoint()
    {
        Assert.Equal(V(5, 0, -1000), ScreenViewMath.ClampView(V(9, 50, -5000), 400, 250));
        var zoomed = ScreenViewMath.ZoomAbout(ScreenView.Fit, 2, new ScreenPoint(200, 125), 400, 250);
        Assert.Equal(V(2, -200, -125), zoomed);
        Assert.Equal(ScreenView.Fit, ScreenViewMath.ZoomAbout(zoomed, 0.1, ScreenPoint.Zero, 400, 250));
    }

    [Fact]
    public void ClampsToTheDrawnDesktopNotTheLetterbox()
    {
        const double aspect = 1024.0 / 640.0;
        Assert.Equal(V(1, 0, (600 - 251.25) / 2), ScreenViewMath.ClampToDesktop(ScreenView.Fit, 402, 600, aspect));
        Assert.Equal(V(2, -402, (600 - 502.5) / 2), ScreenViewMath.ClampToDesktop(V(2, -900, -300), 402, 600, aspect));
        Assert.True(Close(ScreenViewMath.ClampToDesktop(ScreenView.Fit, 574, 1013, aspect).Y, (1013 - 358.75) / 2));
        Assert.Equal(V(3, 0, 600 - 402 / aspect * 3), ScreenViewMath.ClampToDesktop(V(3, 0, -2000), 402, 600, aspect));
        var landscape = ScreenViewMath.ClampToDesktop(V(1.2, -50, 0), 874, 330, aspect);
        Assert.True(Close(landscape.X, (874 - 528 * 1.2) / 2 - (874 * 1.2 - 528 * 1.2) / 2));
        var plain = V(2, 0, 0);
        Assert.Equal(ScreenViewMath.ClampView(plain, 400, 250), ScreenViewMath.ClampToDesktop(plain, 400, 250, 0));
    }

    [Fact]
    public void TheDesktopIsDrawnCentredAcrossAndNeverInTheBands()
    {
        const double aspect = 1024.0 / 640.0;
        // Portrait: full width, centred down.
        var portrait = ScreenViewMath.Drawn(new ScreenSize(402, 600), aspect, ScreenView.Fit);
        Assert.True(Close(portrait.MinX, 0) && Close(portrait.Width, 402) && Close(portrait.Height, 251.25) && Close(portrait.MinY, 174.375));
        // Landscape: full height, centred across.
        var landscape = ScreenViewMath.Drawn(new ScreenSize(874, 330), aspect, ScreenView.Fit);
        Assert.True(Close(landscape.Width, 528) && Close(landscape.Height, 330) && Close(landscape.MinX, 173) && Close(landscape.MinY, 0));
        // Zoomed in landscape until wider than the stage: the left edge can reach the stage's edge, never past it.
        var wide = ScreenViewMath.Drawn(new ScreenSize(874, 330), aspect, V(3, 5000, 5000));
        Assert.True(Close(wide.MinX, 0) && Close(wide.MinY, 0) && Close(wide.Width, 1584));
        var far = ScreenViewMath.Drawn(new ScreenSize(874, 330), aspect, V(3, -5000, -5000));
        Assert.True(Close(far.MaxX, 874) && Close(far.MaxY, 330));
        Assert.Equal(ScreenRect.Zero, ScreenViewMath.Drawn(ScreenSize.Zero, aspect, ScreenView.Fit));
        Assert.Equal(ScreenRect.Zero, ScreenViewMath.Drawn(new ScreenSize(10, 10), 0, ScreenView.Fit));
    }

    [Fact]
    public void DoubleTapFillsTheScreen()
    {
        Assert.True(Close(ScreenViewMath.FillZoom(402, 600, new ScreenSize(402, 251)), 600.0 / 251.0));
        Assert.True(Close(ScreenViewMath.FillZoom(874, 330, new ScreenSize(528, 330)), 874.0 / 528.0));
        Assert.Equal(2.5, ScreenViewMath.FillZoom(400, 250, new ScreenSize(400, 250)));
        Assert.Equal(2.5, ScreenViewMath.FillZoom(400, 250, null));
        Assert.Equal(5, ScreenViewMath.FillZoom(4000, 250, new ScreenSize(40, 25)));
    }

    [Fact]
    public void KeepsTheTappedPointClearOfTheKeyBar()
    {
        Assert.Equal(V(2, 0, -10), ScreenViewMath.KeepVisible(V(2, 0, 0), 300, 400, 330));
        Assert.Equal(V(2, 0, -180), ScreenViewMath.KeepVisible(V(2, 0, -200), 20, 400, 330));
        var view = V(2, 0, 0);
        Assert.Equal(view, ScreenViewMath.KeepVisible(view, 100, 400, 330));
    }

    [Fact]
    public void TypingOnAShortWideScreenFillsTheWidth()
    {
        Assert.True(ScreenViewMath.CompactTyping(true, new ScreenSize(1194, 406)));
        Assert.True(ScreenViewMath.CompactTyping(true, new ScreenSize(874, 150)));
        Assert.False(ScreenViewMath.CompactTyping(true, new ScreenSize(834, 790)));
        Assert.False(ScreenViewMath.CompactTyping(true, new ScreenSize(375, 400)));
        Assert.False(ScreenViewMath.CompactTyping(false, new ScreenSize(1194, 406)));
        Assert.False(ScreenViewMath.CompactTyping(true, null));
        const double aspect = 1024.0 / 640.0;
        var filled = ScreenViewMath.FillWidthView(922, 314, aspect, 0.5);
        Assert.NotNull(filled);
        Assert.True(Close(filled.Zoom, 922 / (314 * aspect)));
        Assert.True(Close(filled.Y, 314.0 / 2 - 0.5 * 922 / aspect));
        Assert.True(Close(ScreenViewMath.FillWidthView(922, 314, aspect, 1)!.Y, 314 - 922 / aspect));
        Assert.Equal(0, ScreenViewMath.FillWidthView(922, 314, aspect, 0)!.Y);
        Assert.Null(ScreenViewMath.FillWidthView(402, 600, aspect, 0.5));
        Assert.Equal(5, ScreenViewMath.FillWidthView(874, 60, aspect, 0.5)?.Zoom);
        Assert.Null(ScreenViewMath.FillWidthView(922, 314, 0, 0.5));
        // The filled desktop spans the stage's width exactly.
        var drawn = ScreenViewMath.Drawn(new ScreenSize(922, 314), aspect, filled);
        Assert.True(Close(drawn.MinX, 0) && Close(drawn.Width, 922));
    }

    [Fact]
    public void TheRotateHintShowsOnceOnAPhoneHeldUpright()
    {
        Assert.True(ScreenViewMath.WantsRotateHint(seen: false, portrait: true, phone: true));
        Assert.False(ScreenViewMath.WantsRotateHint(seen: true, portrait: true, phone: true));
        Assert.False(ScreenViewMath.WantsRotateHint(seen: false, portrait: false, phone: true));
        Assert.False(ScreenViewMath.WantsRotateHint(seen: false, portrait: true, phone: false));
    }

    [Fact]
    public void ThePointerIsAFractionOfTheDesktopAndStaysInside()
    {
        var pointer = new ScreenPointer();
        Assert.Equal((640, 400), pointer.Pixel((1280, 800)));
        pointer.Move(36, -18, new ScreenSize(360, 180), (1200, 600));
        Assert.True(Close(pointer.X, 0.6) && Close(pointer.Y, 0.4));
        Assert.Equal((720, 240), pointer.Pixel((1200, 600)));
        pointer.Move(9000, 9000, new ScreenSize(360, 180), (1200, 600));
        Assert.Equal((1199, 599), pointer.Pixel((1200, 600)));
        pointer.Move(-90000, -90000, new ScreenSize(360, 180), (1200, 600));
        Assert.Equal((0, 0), pointer.Pixel((1200, 600)));
        // No picture yet: nothing moves, nothing divides by zero.
        pointer.Move(10, 10, ScreenSize.Zero, (0, 0));
        Assert.Equal(new ScreenPointer(0, 0), pointer);
        Assert.Equal(new ScreenPoint(110, 210), new ScreenPointer(0.25, 0.5).Point(new ScreenRect(20, 120, 360, 180)));
    }
}

public class ScreenGestureTests
{
    private static ScreenGesture.Context Ctx(bool control, ScreenSize? stage = null, (int, int)? framebuffer = null)
    {
        var fb = framebuffer ?? (400, 250);
        return new ScreenGesture.Context(control, stage ?? new ScreenSize(400, 250), (double)fb.Item1 / fb.Item2, fb);
    }

    private static ScreenPoint P(double x, double y) => new(x, y);
    private static ScreenPoint[] Ps(params ScreenPoint[] points) => points;
    private static bool Close(double a, double b) => ScreenViewMathTests.Close(a, b);

    private static void Is(IEnumerable<GA> expected, IEnumerable<GA> actual) => Assert.Equal(expected.ToList(), actual.ToList());

    private static readonly GA Moved = new GA.PointerMoved();
    private static GA Touching(bool on) => new GA.Touching(on);
    private static GA Click(byte mask) => new GA.Click(mask);
    private static GA Buttons(byte mask) => new GA.Buttons(mask);
    private static GA Tapped(double fx, double fy) => new GA.Tapped(fx, fy);
    private static GA Wheel(bool down) => new GA.Wheel(down);
    private static GA View(ScreenView view, bool committed) => new GA.View(view, committed);

    [Fact]
    public void ATapClicksAtThePointerNotAtTheFinger()
    {
        var gesture = new ScreenGesture();
        var control = Ctx(true);
        Is([Touching(true)], gesture.Began(Ps(P(40, 60)), 0, control));
        Assert.Equal(0.55, gesture.HoldDeadline);
        Is([Click(1), Tapped(0.5, 0.5), Touching(false)], gesture.Ended(0, 0.1, control));
        Assert.Equal(new ScreenPointer(0.5, 0.5), gesture.Pointer);
        Assert.Equal(0.5, gesture.Tapped?.Fx);
    }

    [Fact]
    public void ASwipeOnlyMovesThePointer()
    {
        var gesture = new ScreenGesture();
        var control = Ctx(true);
        gesture.Began(Ps(P(10, 10)), 0, control);
        Is([], gesture.Moved(Ps(P(14, 12)), control));                       // inside the tap slop
        Is([Moved], gesture.Moved(Ps(P(30, 10)), control));
        Assert.Null(gesture.HoldDeadline);
        Is([Moved], gesture.Moved(Ps(P(60, 20)), control));
        Assert.True(Close(gesture.Pointer.X, 0.5 + 50.0 / 400.0) && Close(gesture.Pointer.Y, 0.5 + 10.0 / 250.0));
        Is([Touching(false)], gesture.Ended(0, 0.4, control));
        // The next touch starts from where the pointer is, wherever the finger lands.
        gesture.Began(Ps(P(300, 200)), 1, control);
        gesture.Moved(Ps(P(280, 180)), control);
        Assert.True(Close(gesture.Pointer.X, 0.5 + 30.0 / 400.0) && Close(gesture.Pointer.Y, 0.5 - 10.0 / 250.0));
    }

    [Fact]
    public void ASwipeCannotTurnIntoAClickOrDragAfterResting()
    {
        var gesture = new ScreenGesture();
        var control = Ctx(true);
        gesture.Began(Ps(P(10, 10)), 0, control);
        gesture.Moved(Ps(P(50, 30)), control);
        Is([], gesture.HoldFired(1));
        Is([Moved], gesture.Moved(Ps(P(60, 40)), control));
        Is([Touching(false)], gesture.Ended(0, 1.1, control));
        Assert.False(gesture.Pressed);
    }

    [Fact]
    public void AStillHoldLiftedRightClicks()
    {
        var gesture = new ScreenGesture();
        var control = Ctx(true);
        gesture.Began(Ps(P(70, 80)), 0, control);
        Is([], gesture.HoldFired(0.3));                                       // not yet
        Is([new GA.HoldArmed()], gesture.HoldFired(0.6));
        Is([], gesture.HoldFired(0.7));                                       // once
        Is([Click(4), Tapped(0.5, 0.5), Touching(false)], gesture.Ended(0, 0.8, control));
    }

    [Fact]
    public void AHoldThatThenMovesIsALeftDrag()
    {
        var gesture = new ScreenGesture();
        var control = Ctx(true);
        gesture.Began(Ps(P(70, 80)), 0, control);
        gesture.HoldFired(0.7);
        Is([Buttons(1), Moved], gesture.Moved(Ps(P(120, 80)), control));
        Assert.True(gesture.Pressed);
        Is([Moved], gesture.Moved(Ps(P(130, 80)), control));
        var pointer = gesture.Pointer;
        Is([Buttons(0), Tapped(pointer.X, pointer.Y), Touching(false)], gesture.Ended(0, 1, control));
        Assert.False(gesture.Pressed);
    }

    [Fact]
    public void ACancelledTouchNeverClicksAndACancelledDragIsReleased()
    {
        var gesture = new ScreenGesture();
        var control = Ctx(true);
        gesture.Began(Ps(P(40, 60)), 0, control);
        Is([Touching(false)], gesture.Cancelled());
        gesture.Began(Ps(P(10, 10)), 1, control);
        gesture.HoldFired(1.7);
        gesture.Moved(Ps(P(50, 30)), control);
        Is([Buttons(0), Touching(false)], gesture.Cancelled());
        Assert.False(gesture.Pressed);
        // And the touch after it is a fresh one.
        gesture.Began(Ps(P(40, 60)), 3, control);
        Assert.Equal(Click(1), gesture.Ended(0, 3.1, control).First());
    }

    [Fact]
    public void ASecondFingerEndsADragWhereItIs()
    {
        var gesture = new ScreenGesture();
        var control = Ctx(true);
        gesture.Began(Ps(P(10, 10)), 0, control);
        gesture.HoldFired(0.7);
        gesture.Moved(Ps(P(80, 40)), control);
        Is([Buttons(0)], gesture.Began(Ps(P(80, 40), P(200, 40)), 1, control));
        Assert.False(gesture.Pressed);
        // Lifting both never clicks.
        Is([View(ScreenView.Fit, true)], gesture.Ended(1, 1.2, control));
        Is([Touching(false)], gesture.Ended(0, 1.3, control));
    }

    [Fact]
    public void PinchZoomsLocallyInBothModes()
    {
        foreach (var control in new[] { false, true })
        {
            var gesture = new ScreenGesture();
            var ctx = Ctx(control);
            Is([], gesture.Began(Ps(P(150, 125), P(250, 125)), 0, ctx));
            var actions = gesture.Moved(Ps(P(100, 125), P(300, 125)), ctx);
            Is([View(new ScreenView(2, -200, -125), false)], actions);
            Is([View(new ScreenView(2, -200, -125), true)], gesture.Ended(1, 0.5, ctx));
            Is([Touching(false)], gesture.Ended(0, 0.6, ctx));
            Assert.Equal(2, gesture.View.Zoom);
        }
    }

    [Fact]
    public void TwoFingersAtFitScrollTheRemoteScreenInWheelSteps()
    {
        var gesture = new ScreenGesture();
        var control = Ctx(true);
        gesture.Began(Ps(P(150, 200), P(250, 200)), 0, control);
        // Fingers up 50 pt: two steps down (24 pt each), the remainder carries.
        Is([Wheel(true), Wheel(true)], gesture.Moved(Ps(P(150, 150), P(250, 150)), control));
        Is([Wheel(true)], gesture.Moved(Ps(P(150, 127), P(250, 127)), control));
        // And back down: up steps.
        Is([Wheel(false), Wheel(false), Wheel(false)], gesture.Moved(Ps(P(150, 200), P(250, 200)), control));
        Is([Touching(false)], gesture.Ended(0, 1, control));
        Assert.Equal(ScreenView.Fit, gesture.View);
        // Watching, the same drag is no scroll (nothing may be sent) and no zoom.
        var watching = new ScreenGesture();
        var watch = Ctx(false);
        watching.Began(Ps(P(150, 200), P(250, 200)), 0, watch);
        var watched = watching.Moved(Ps(P(150, 150), P(250, 150)), watch);
        Assert.True(!watched.Contains(Wheel(true)) && !watched.Contains(Wheel(false)));
        // Zoomed in, two fingers move the view instead of scrolling.
        var zoomed = new ScreenGesture();
        zoomed.SetView(new ScreenView(2, -100, -100), control);
        zoomed.Began(Ps(P(150, 200), P(250, 200)), 0, control);
        var panned = zoomed.Moved(Ps(P(150, 150), P(250, 150)), control);
        Assert.True(!panned.Contains(Wheel(true)) && !panned.Contains(Wheel(false)));
    }

    [Fact]
    public void WatchingDoubleTapZoomsDragPansDoubleTapFits()
    {
        var gesture = new ScreenGesture();
        var watch = Ctx(false);
        Is([], gesture.Began(Ps(P(100, 100)), 0, watch));
        Assert.Null(gesture.HoldDeadline);
        Is([Touching(false)], gesture.Ended(0, 0.05, watch));
        gesture.Began(Ps(P(100, 100)), 0.2, watch);
        var actions = gesture.Ended(0, 0.25, watch);
        Assert.Equal(View(gesture.View, true), actions.First());
        Assert.Equal(2.5, gesture.View.Zoom);
        var x = gesture.View.X;
        gesture.Began(Ps(P(200, 100)), 2, watch);
        gesture.Moved(Ps(P(150, 100)), watch);
        gesture.Moved(Ps(P(120, 100)), watch);
        gesture.Ended(0, 2.5, watch);
        Assert.Equal(x - 80, gesture.View.X);
        gesture.Began(Ps(P(50, 50)), 4, watch);
        gesture.Ended(0, 4.05, watch);
        gesture.Began(Ps(P(50, 50)), 4.2, watch);
        gesture.Ended(0, 4.25, watch);
        Assert.Equal(ScreenView.Fit, gesture.View);
        // Two slow taps, or two far apart, are not a double tap.
        gesture.Began(Ps(P(50, 50)), 6, watch);
        gesture.Ended(0, 6.05, watch);
        gesture.Began(Ps(P(50, 50)), 7, watch);
        gesture.Ended(0, 7.05, watch);
        Assert.Equal(ScreenView.Fit, gesture.View);
        gesture.Began(Ps(P(300, 200)), 7.1, watch);
        gesture.Ended(0, 7.15, watch);
        Assert.Equal(ScreenView.Fit, gesture.View);
    }

    [Fact]
    public void FittingALandscapeDesktopInAPortraitStageCentresIt()
    {
        var gesture = new ScreenGesture();
        var watch = Ctx(false, new ScreenSize(402, 600), (1024, 640));
        gesture.SetView(ScreenView.Fit, watch);
        Assert.Equal(new ScreenView(1, 0, (600 - 251.25) / 2), gesture.View);
        foreach (var now in new[] { 0.0, 0.2 })
        {
            gesture.Began(Ps(P(100, 100)), now, watch);
            gesture.Ended(0, now + 0.05, watch);
        }
        Assert.True(Close(gesture.View.Zoom, 600 / 251.25));
        foreach (var now in new[] { 2.0, 2.2 })
        {
            gesture.Began(Ps(P(50, 50)), now, watch);
            gesture.Ended(0, now + 0.05, watch);
        }
        Assert.Equal(new ScreenView(1, 0, (600 - 251.25) / 2), gesture.View);
    }

    [Fact]
    public void TheBlackBandsAreTrackpadToo()
    {
        // A 1200x600 desktop drawn 400x200 in a 400x600 stage: the finger below the picture still moves the pointer.
        var gesture = new ScreenGesture();
        var control = Ctx(true, new ScreenSize(400, 600), (1200, 600));
        gesture.Began(Ps(P(100, 450)), 0, control);
        Is([Moved], gesture.Moved(Ps(P(140, 420)), control));
        Assert.True(Close(gesture.Pointer.X, 0.6) && Close(gesture.Pointer.Y, 0.35));
        gesture.Moved(Ps(P(5000, 5000)), control);
        Assert.Equal((1199, 599), gesture.Pointer.Pixel((1200, 600)));
        gesture.Moved(Ps(P(4980, 4980)), control);                            // back 20 pt: no dead zone at the edge
        Assert.True(Close(gesture.Pointer.X, 1 - 1.0 / 1200 - 0.05));
    }

    [Fact]
    public void DroppingControlForgetsTheTouchAndSaysAButtonWasDown()
    {
        var gesture = new ScreenGesture();
        var control = Ctx(true);
        gesture.Began(Ps(P(10, 10)), 0, control);
        gesture.HoldFired(0.7);
        gesture.Moved(Ps(P(60, 60)), control);
        var wasDown = gesture.Drop();
        Assert.True(wasDown);
        Assert.False(gesture.Pressed);
        var again = gesture.Drop();
        Assert.False(again);
        // The finger still on the glass does nothing more.
        Is([], gesture.Moved(Ps(P(90, 90)), control));
        Is([Touching(false)], gesture.Ended(0, 2, control));
    }

    [Fact]
    public void RelayoutKeepsTheViewLegalAndTheTappedRowInSight()
    {
        var gesture = new ScreenGesture();
        var tall = Ctx(true, new ScreenSize(400, 600), (400, 600));
        gesture.Began(Ps(P(10, 10)), 0, tall);
        gesture.Moved(Ps(P(10, 250)), tall);                                  // the pointer goes down to 0.9
        gesture.Ended(0, 0.2, tall);
        gesture.Began(Ps(P(10, 10)), 1, tall);
        gesture.Ended(0, 1.1, tall);                                          // a click there
        Assert.True(Close(gesture.Tapped?.Fy ?? 0, 0.9));
        gesture.SetView(new ScreenView(2, 0, 0), tall);
        // The keyboard takes half the stage: the tapped row (y = 1080 of 1200) is brought 40 pt clear of the bottom.
        var @short = Ctx(true, new ScreenSize(400, 300), (400, 600));
        gesture.Relayout(@short);
        var rect = ScreenViewMath.Drawn(@short.Stage, @short.Aspect, gesture.View);
        var row = rect.MinY + 0.9 * rect.Height;
        Assert.True(row <= 300 - 40 + 0.001 && row >= 40 - 0.001);
        // A resize of the desktop keeps the pointer inside it.
        gesture.ClampPointer(Ctx(true, new ScreenSize(400, 300), (2, 2)));
        Assert.True(gesture.Pointer.Pixel((2, 2)) == (1, 1) || gesture.Pointer.Pixel((2, 2)) == (0, 1));
    }

    // Windows-only addition (no Swift twin): a touch lifted with no touch begun, or a move before any touch, says
    // nothing more than the lift.
    [Fact]
    public void AStrayLiftOrMoveIsHarmless()
    {
        var gesture = new ScreenGesture();
        var control = Ctx(true);
        Is([], gesture.Moved(Ps(P(10, 10)), control));
        Is([Touching(false)], gesture.Ended(0, 0, control));
        Is([], gesture.Began([], 0, control));
        Assert.Null(gesture.HoldDeadline);
    }
}
