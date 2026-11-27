// [WIN-SCREEN-GESTURE] The Bot Screen stage's input rules (Hermes.Core/Screen/ScreenGesture.cs): Windows touch, pen
// and mouse contacts and the wheel through ScreenGesture into RFB PointerEvents, a test per rule. The Mac has no test
// of ScreenStageView's input half (its rules are ScreenGesture's, tested in ScreenViewMathTests, and the view is
// driven by UIKit); these pin the same behaviour the view's `apply` gives: a click is position, down, up at the
// pointer, a drag sends its position before each button change, wheel steps are buttons 4 and 5 (masks 8 and 16).
// Synthetic pictures only.

using Hermes.Core.Screen;
using static Hermes.Core.Tests.Screen.ScreenWaits;

namespace Hermes.Core.Tests.Screen;

public sealed class ScreenStageInputTests
{
    private const uint Finger = 1, Second = 2, Mouse = 9;

    private sealed class Rig
    {
        public FakeFrameTicks Ticks { get; } = new();
        public FakeViewerTimers Timers { get; } = new();
        public double Now;
        public List<(byte Mask, int X, int Y)> Sent { get; } = [];
        public List<(ScreenView View, bool Committed)> Views { get; } = [];
        public List<bool> Rings { get; } = [];
        public int Holds;
        public int Touches;
        public ScreenStageState Stage { get; }

        public Rig(bool control = true, int width = 400, int height = 250, double stageWidth = 400, double stageHeight = 250)
        {
            Stage = new ScreenStageState(Ticks, Timers, () => Now)
            {
                OnPointer = (m, x, y) => Sent.Add((m, x, y)),
                OnView = (v, c) => Views.Add((v, c)),
                OnRing = Rings.Add,
                OnHoldArmed = () => Holds++,
                OnTouch = () => Touches++,
            };
            Stage.Layout(new ScreenSize(stageWidth, stageHeight));
            Stage.Show(new byte[width * height * 4], width, height);
            Stage.Control = control;
        }

        public FakeViewerTimers.Timer? Hold => Timers.All.SingleOrDefault(t => !t.Disposed);

        public void Tap(double x = 40, double y = 60)
        {
            Assert.True(Stage.Pressed(Finger, ScreenPointerButton.Primary, new ScreenPoint(x, y)));
            Stage.Released(Finger);
        }
    }

    private static ScreenPoint P(double x, double y) => new(x, y);
    private static (byte, int, int) S(int mask, int x, int y) => ((byte)mask, x, y);

    [Fact]
    public void WhatEachWindowsPressIs()
    {
        Assert.Equal(ScreenPointerButton.Primary, ScreenPointerButtons.From(ScreenPointerDevice.Touch));
        Assert.Equal(ScreenPointerButton.Primary, ScreenPointerButtons.From(ScreenPointerDevice.Pen));
        Assert.Equal(ScreenPointerButton.Secondary, ScreenPointerButtons.From(ScreenPointerDevice.Pen, barrel: true));
        Assert.Equal(ScreenPointerButton.Primary, ScreenPointerButtons.From(ScreenPointerDevice.Mouse, left: true));
        Assert.Equal(ScreenPointerButton.Secondary, ScreenPointerButtons.From(ScreenPointerDevice.Mouse, right: true));
        Assert.Equal(ScreenPointerButton.Middle, ScreenPointerButtons.From(ScreenPointerDevice.Mouse, middle: true));
        Assert.Equal(ScreenPointerButton.Primary, ScreenPointerButtons.From(ScreenPointerDevice.Mouse, left: true, right: true));
        Assert.Equal(ScreenPointerButton.None, ScreenPointerButtons.From(ScreenPointerDevice.Mouse));   // X buttons
        Assert.True(ScreenPointerButtons.Discrete(120) && ScreenPointerButtons.Discrete(-240));
        Assert.False(ScreenPointerButtons.Discrete(37) || ScreenPointerButtons.Discrete(0));
    }

    [Fact]
    public void ATapClicksAtThePointerNotAtTheFinger()
    {
        var rig = new Rig();
        rig.Tap(40, 60);
        // Position, down, up at the centre of a 400×250 desktop: the pointer starts there, wherever the finger is.
        Assert.Equal([S(0, 200, 125), S(1, 200, 125), S(0, 200, 125)], rig.Sent);
        Assert.Equal([true, false], rig.Rings);
        Assert.Equal(0.5, rig.Stage.TappedRow);
        Assert.Equal(1, rig.Touches);
    }

    [Fact]
    public void ASwipeMovesThePointerOncePerFrameAndNeverClicks()
    {
        var rig = new Rig();
        rig.Stage.Pressed(Finger, ScreenPointerButton.Primary, P(10, 10));
        rig.Stage.Moved(Finger, P(14, 12));                          // inside the tap slop: nothing
        Assert.Empty(rig.Ticks.Links);
        rig.Stage.Moved(Finger, P(30, 10));
        Assert.Null(rig.Hold);                                       // a move ends the hold
        rig.Stage.Moved(Finger, P(60, 20));
        Assert.Empty(rig.Sent);
        rig.Ticks.Frame();
        // 50 pt across a 400 pt desktop is an eighth: 0.625 × 400 = 250; 10 pt down of 250 is 0.04: 0.54 × 250 = 135.
        Assert.Equal([S(0, 250, 135)], rig.Sent);
        Assert.Equal((250, 135), rig.Stage.PointerPixel);
        rig.Stage.Released(Finger);
        rig.Ticks.Frame();
        Assert.Single(rig.Sent);
    }

    [Fact]
    public void AStillHoldArmsOnItsTimerAndLiftedRightClicks()
    {
        var rig = new Rig();
        rig.Stage.Pressed(Finger, ScreenPointerButton.Primary, P(70, 80));
        var hold = rig.Hold!;
        Assert.Equal(TimeSpan.FromSeconds(0.55), hold.After);
        rig.Now = 0.5;                                               // a timer a hair early is still the hold
        hold.Fire();
        Assert.Equal(1, rig.Holds);
        rig.Stage.Released(Finger);
        Assert.Equal([S(0, 200, 125), S(4, 200, 125), S(0, 200, 125)], rig.Sent);
    }

    [Fact]
    public void AHoldThatThenMovesIsALeftDragWithItsPositionBeforeEachButton()
    {
        var rig = new Rig();
        rig.Stage.Pressed(Finger, ScreenPointerButton.Primary, P(70, 80));
        rig.Now = 0.6;
        rig.Hold!.Fire();
        rig.Stage.Moved(Finger, P(120, 80));
        Assert.True(rig.Stage.Dragging);
        // As the Mac's `apply` does, the position and the button go out where the gesture's pointer is once the move
        // that started the drag is in: the button comes down, then the next frame's move carries it on.
        Assert.Equal([S(0, 250, 125), S(1, 250, 125)], rig.Sent);
        rig.Stage.Moved(Finger, P(160, 80));
        rig.Ticks.Frame();
        Assert.Equal(S(1, 290, 125), rig.Sent[^1]);                  // and moves with the button down
        rig.Stage.Released(Finger);
        Assert.Equal([S(1, 290, 125), S(0, 290, 125)], rig.Sent[^2..]);
        Assert.False(rig.Stage.Dragging);
        Assert.Equal(0, rig.Stage.Held);
    }

    [Fact]
    public void ACancelledContactNeverClicksAndACancelledDragIsReleased()
    {
        var rig = new Rig();
        rig.Stage.Pressed(Finger, ScreenPointerButton.Primary, P(40, 60));
        rig.Stage.Canceled(Finger);
        Assert.Empty(rig.Sent);
        Assert.Null(rig.Hold);
        rig.Stage.Pressed(Finger, ScreenPointerButton.Primary, P(10, 10));
        rig.Now = 1;
        rig.Hold!.Fire();
        rig.Stage.Moved(Finger, P(50, 10));
        rig.Sent.Clear();
        rig.Stage.Canceled(Finger);                                  // PointerCaptureLost mid-drag
        Assert.Equal([S(1, 240, 125), S(0, 240, 125)], rig.Sent);
        Assert.Equal(0, rig.Stage.Contacts);
    }

    [Fact]
    public void TwoFingersMovesAreGatheredLikeOneUIKitEventSoAScrollStaysAScroll()
    {
        var rig = new Rig();
        rig.Stage.Pressed(Finger, ScreenPointerButton.Primary, P(150, 200));
        rig.Stage.Pressed(Second, ScreenPointerButton.Primary, P(250, 200));
        Assert.Null(rig.Hold);                                       // a second finger is no hold
        // WinUI raises one PointerMoved per finger. Fed alone, the first (100 → 112 pt apart) would read as a spread.
        rig.Stage.Moved(Finger, P(150, 150));
        Assert.Empty(rig.Sent);
        Assert.Empty(rig.Views);
        rig.Stage.Moved(Second, P(250, 150));
        // Fingers up 50 pt: two wheel steps down (24 pt each), each a press and release of button 5 at the pointer.
        Assert.Equal([S(16, 200, 125), S(0, 200, 125), S(16, 200, 125), S(0, 200, 125)], rig.Sent);
        Assert.Equal(ScreenView.Fit, rig.Stage.View);
        // One finger still while the other moves twice: the first move goes in on the second.
        rig.Sent.Clear();
        rig.Stage.Moved(Finger, P(150, 200));
        rig.Stage.Moved(Finger, P(150, 210));
        Assert.Empty(rig.Sent);                                      // the spread decided nothing more: mode is scroll
        rig.Stage.Released(Finger);
        rig.Stage.Released(Second);
        Assert.DoesNotContain(rig.Sent, s => s.Mask is 1 or 4);      // lifting two fingers never clicks
    }

    [Fact]
    public void APinchZoomsTheLocalViewAndSendsNothing()
    {
        foreach (var control in new[] { false, true })
        {
            var rig = new Rig(control);
            rig.Stage.Pressed(Finger, ScreenPointerButton.Primary, P(150, 125));
            rig.Stage.Pressed(Second, ScreenPointerButton.Primary, P(250, 125));
            rig.Stage.Moved(Finger, P(100, 125));
            rig.Stage.Moved(Second, P(300, 125));
            Assert.Equal((new ScreenView(2, -200, -125), false), rig.Views.Single());
            Assert.Equal(new ScreenView(2, -200, -125), rig.Stage.View);  // drawn as the fingers shape it
            Assert.Equal(800, rig.Stage.Drawn.Width);
            rig.Stage.Released(Second);
            Assert.Equal((new ScreenView(2, -200, -125), true), rig.Views[^1]);
            rig.Stage.Released(Finger);
            Assert.Empty(rig.Sent);
            Assert.Equal(2, rig.Stage.View.Zoom);
        }
    }

    [Fact]
    public void WatchingNothingGoesOnTheWireAndADoubleTapZooms()
    {
        var rig = new Rig(control: false);
        rig.Tap(100, 100);
        Assert.Null(rig.Hold);                                       // no hold, no ring while watching
        Assert.DoesNotContain(true, rig.Rings);
        rig.Now = 0.2;
        rig.Tap(100, 100);
        Assert.Equal(2.5, rig.Stage.View.Zoom);
        Assert.True(rig.Views[^1].Committed);
        rig.Stage.Pressed(Finger, ScreenPointerButton.Primary, P(200, 100));
        rig.Stage.Moved(Finger, P(150, 100));                        // a drag pans the zoomed view
        rig.Stage.Released(Finger);
        Assert.Empty(rig.Sent);
        Assert.False(rig.Stage.Pressed(Mouse, ScreenPointerButton.Secondary, P(10, 10)));
        Assert.False(rig.Stage.Act(ScreenStageAct.Click));
        rig.Stage.Wheel(-120, P(10, 10));
        Assert.Empty(rig.Sent);
    }

    [Fact]
    public void TheRightButtonAndAPenBarrelRightClickAndTheMiddleButtonMiddleClicks()
    {
        var rig = new Rig();
        Assert.True(rig.Stage.Pressed(Mouse, ScreenPointerButtons.From(ScreenPointerDevice.Mouse, right: true), P(300, 10)));
        rig.Stage.Moved(Mouse, P(10, 200));                          // a right-button drag moves nothing
        Assert.Empty(rig.Ticks.Links);
        rig.Stage.Released(Mouse);
        Assert.Equal([S(0, 200, 125), S(4, 200, 125), S(0, 200, 125)], rig.Sent);
        rig.Sent.Clear();
        rig.Stage.Pressed(5, ScreenPointerButtons.From(ScreenPointerDevice.Pen, barrel: true), P(1, 1));
        rig.Stage.Released(5);
        Assert.Equal(S(4, 200, 125), rig.Sent[1]);
        rig.Sent.Clear();
        rig.Stage.Pressed(Mouse, ScreenPointerButton.Middle, P(1, 1));
        rig.Stage.Released(Mouse);
        Assert.Equal([S(0, 200, 125), S(2, 200, 125), S(0, 200, 125)], rig.Sent);
        // Cancelled, or pressed while a finger is down: nothing.
        rig.Sent.Clear();
        rig.Stage.Pressed(Mouse, ScreenPointerButton.Secondary, P(1, 1));
        rig.Stage.Canceled(Mouse);
        rig.Stage.Released(Mouse);
        rig.Stage.Pressed(Finger, ScreenPointerButton.Primary, P(1, 1));
        Assert.False(rig.Stage.Pressed(Mouse, ScreenPointerButton.Secondary, P(1, 1)));
        Assert.False(rig.Stage.Pressed(Mouse, ScreenPointerButton.None, P(1, 1)));
        Assert.Empty(rig.Sent);
    }

    [Fact]
    public void AHoveringMouseOrPenMovesNothing()
    {
        var rig = new Rig();
        rig.Stage.Moved(Mouse, P(300, 200));
        rig.Ticks.Frame();
        Assert.Empty(rig.Sent);
        Assert.Equal(new ScreenPointer(), rig.Stage.Pointer);
    }

    [Fact]
    public void AMouseWheelTurnsTheBotsWheelANotchAStep()
    {
        var rig = new Rig();
        rig.Stage.Wheel(-120, P(10, 10));                            // towards the person: content up, wheel down
        Assert.Equal([S(16, 200, 125), S(0, 200, 125)], rig.Sent);
        rig.Sent.Clear();
        rig.Stage.Wheel(240, P(10, 10));                             // two notches away: two steps up
        Assert.Equal([S(8, 200, 125), S(0, 200, 125), S(8, 200, 125), S(0, 200, 125)], rig.Sent);
        rig.Sent.Clear();
        rig.Stage.Wheel(120, P(10, 10), horizontal: true);           // a tilt wheel: only y is read
        rig.Stage.Wheel(0, P(10, 10));
        Assert.Empty(rig.Sent);
        // During a drag the wheel keeps the button held.
        rig.Stage.Pressed(Finger, ScreenPointerButton.Primary, P(10, 10));
        rig.Now = 1;
        rig.Hold!.Fire();
        rig.Stage.Moved(Finger, P(10, 40));
        rig.Sent.Clear();
        rig.Ticks.Frame();
        rig.Stage.Wheel(-120, P(10, 10));
        Assert.Equal([S(17, 200, 155), S(1, 200, 155)], rig.Sent[^2..]);
    }

    [Fact]
    public void ATouchpadScrollStepsEveryNotchOfTravelAndCarriesTheRest()
    {
        var rig = new Rig();
        rig.Stage.Wheel(-50, P(10, 10));
        rig.Now = 0.05;
        rig.Stage.Wheel(-50, P(10, 10));
        Assert.Empty(rig.Sent);
        rig.Now = 0.1;
        rig.Stage.Wheel(-30, P(10, 10));                            // 130: one step, 10 carried
        Assert.Equal([S(16, 200, 125), S(0, 200, 125)], rig.Sent);
        rig.Now = 0.15;
        rig.Stage.Wheel(-110, P(10, 10));                           // 120 with the carry: another
        Assert.Equal(4, rig.Sent.Count);
        rig.Now = 0.2;
        rig.Stage.Wheel(-100, P(10, 10));
        rig.Now = 1;                                                 // a pause starts a new scroll: the carry goes
        rig.Stage.Wheel(-30, P(10, 10));
        Assert.Equal(4, rig.Sent.Count);
        Assert.Equal(2, rig.Touches);
    }

    [Fact]
    public void CtrlWheelZoomsTheLocalViewAboutThePointerWatchingOrInControl()
    {
        foreach (var control in new[] { false, true })
        {
            var rig = new Rig(control);
            rig.Stage.Wheel(120, P(200, 125), zoom: true);
            var factor = ScreenZoomSteps.ScrollFactor(10, discrete: true);
            Assert.True(ScreenViewMathTests.Close(rig.Stage.View.Zoom, factor));
            Assert.Equal((rig.Stage.View, true), rig.Views.Single());
            rig.Stage.Wheel(-120, P(200, 125), zoom: true);
            Assert.True(ScreenViewMathTests.Close(rig.Stage.View.Zoom, 1));
            Assert.Empty(rig.Sent);
        }
        // No picture yet: nothing.
        var empty = new Rig(width: 0, height: 0);
        empty.Stage.Wheel(120, P(1, 1), zoom: true);
        Assert.Empty(empty.Views);
    }

    [Fact]
    public void CoveredOrWithoutAPictureNothingIsTaken()
    {
        var rig = new Rig();
        rig.Stage.Covered = true;
        Assert.False(rig.Stage.Pressed(Finger, ScreenPointerButton.Primary, P(1, 1)));
        Assert.False(rig.Stage.Pressed(Mouse, ScreenPointerButton.Secondary, P(1, 1)));
        rig.Stage.Wheel(-120, P(1, 1));
        rig.Stage.Wheel(120, P(1, 1), zoom: true);
        Assert.Empty(rig.Sent);
        Assert.Empty(rig.Views);
        var blank = new Rig(width: 0, height: 0);
        Assert.False(blank.Stage.Pressed(Finger, ScreenPointerButton.Primary, P(1, 1)));
    }

    [Fact]
    public void LosingControlForgetsTheContactAndTheNextOneIsFresh()
    {
        var rig = new Rig();
        rig.Stage.Pressed(Finger, ScreenPointerButton.Primary, P(10, 10));
        rig.Now = 1;
        rig.Hold!.Fire();
        rig.Stage.Moved(Finger, P(60, 60));
        rig.Stage.Control = false;                                   // what DropTouches does
        Assert.False(rig.Stage.Dragging);
        Assert.Equal(0, rig.Stage.Held);
        Assert.Equal(0, rig.Stage.Contacts);
        Assert.False(rig.Stage.Ring);
        Assert.Null(rig.Hold);
        var sent = rig.Sent.Count;
        rig.Stage.Moved(Finger, P(90, 90));                          // the finger still on the glass does nothing
        rig.Stage.Released(Finger);
        Assert.Equal(sent, rig.Sent.Count);
        // Control again: the pointer starts at the centre (the stream has no cursor-position messages).
        rig.Stage.Control = true;
        Assert.Equal(new ScreenPointer(), rig.Stage.Pointer);
        rig.Tap();
        Assert.Equal(S(1, 200, 125), rig.Sent[^2]);
    }

    [Fact]
    public void ANewDesktopSizeKeepsThePointerInside()
    {
        var rig = new Rig(width: 1200, height: 600, stageWidth: 400, stageHeight: 600);
        rig.Stage.Pressed(Finger, ScreenPointerButton.Primary, P(100, 450));
        rig.Stage.Moved(Finger, P(5000, 5000));                      // the black bands are trackpad too
        rig.Stage.Released(Finger);
        Assert.Equal((1199, 599), rig.Stage.PointerPixel);
        rig.Stage.Show(new byte[16], 2, 2);
        Assert.Equal((1, 1), rig.Stage.PointerPixel);
        rig.Tap();
        Assert.Equal(S(1, 1, 1), rig.Sent[^2]);
    }

    [Fact]
    public void TheAccessibilityActionsClickScrollAndZoom()
    {
        var rig = new Rig();
        Assert.Equal(["Click", "Right-click", "Scroll up", "Scroll down", "Zoom in", "Zoom out", "Fit screen"],
                     rig.Stage.Acts.Select(ScreenStageState.ActName));
        Assert.True(rig.Stage.Act(ScreenStageAct.Click));
        Assert.True(rig.Stage.Act(ScreenStageAct.RightClick));
        Assert.True(rig.Stage.Act(ScreenStageAct.ScrollUp));
        Assert.True(rig.Stage.Act(ScreenStageAct.ScrollDown));
        Assert.Equal([0, 1, 0, 0, 4, 0, 8, 0, 16, 0], rig.Sent.Select(s => (int)s.Mask).ToList());
        Assert.True(rig.Stage.Act(ScreenStageAct.ZoomIn));
        Assert.Equal(1.5, rig.Stage.View.Zoom);
        Assert.True(rig.Stage.Act(ScreenStageAct.Fit));
        Assert.Equal(ScreenView.Fit, rig.Stage.View);
        var watching = new Rig(control: false);
        Assert.Equal(["Zoom in", "Zoom out", "Fit screen"], watching.Stage.Acts.Select(ScreenStageState.ActName));
        Assert.True(watching.Stage.Act(ScreenStageAct.ZoomOut));
        Assert.False(watching.Stage.Act(ScreenStageAct.ScrollDown));
    }

    [Fact]
    public void TheRingSitsOnThePointerOverThePicture()
    {
        var rig = new Rig(width: 1200, height: 600, stageWidth: 400, stageHeight: 600);
        Assert.Equal(new ScreenRect(0, 200, 400, 200), rig.Stage.Drawn);
        Assert.Equal(P(200, 300), rig.Stage.RingPoint);
        rig.Stage.Pressed(Finger, ScreenPointerButton.Primary, P(100, 450));
        Assert.True(rig.Stage.Ring);
        rig.Stage.Moved(Finger, P(140, 420));
        Assert.True(ScreenViewMathTests.Close(rig.Stage.RingPoint.X, 0.6 * 400) && ScreenViewMathTests.Close(rig.Stage.RingPoint.Y, 200 + 0.35 * 200));
    }

    // ViewerKeys.swift's scroll factor, ported case for case from Tests/Kit/ViewerKeysTests.swift at 93f984bb1.

    [Fact]
    public void ScrollUpZoomsInAndDownZoomsOut()
    {
        foreach (var discrete in new[] { false, true })
        {
            Assert.True(ScreenZoomSteps.ScrollFactor(10, discrete) > 1);
            Assert.True(ScreenZoomSteps.ScrollFactor(-10, discrete) < 1);
            Assert.Equal(1, ScreenZoomSteps.ScrollFactor(0, discrete));
            Assert.Equal(1, ScreenZoomSteps.ScrollFactor(double.NaN, discrete));
            Assert.True(Math.Abs(ScreenZoomSteps.ScrollFactor(7, discrete) * ScreenZoomSteps.ScrollFactor(-7, discrete) - 1) < 1e-9);
        }
        Assert.True(Math.Abs(ScreenZoomSteps.ScrollFactor(100, false) - Math.Sqrt(2)) < 1e-9);
        Assert.True(ScreenZoomSteps.ScrollFactor(10, true) > ScreenZoomSteps.ScrollFactor(10, false));
    }

    [Fact]
    public void OneScrollEventNeverMovesMoreThanAStep()
    {
        Assert.Equal(ScreenZoomSteps.StepFactor, ScreenZoomSteps.ScrollFactor(10_000, false));
        Assert.Equal(1 / ScreenZoomSteps.StepFactor, ScreenZoomSteps.ScrollFactor(-10_000, true));
    }

    [Fact]
    public void ZoomKeysAndAStepInThenOut()
    {
        Assert.Equal(ScreenZoomStep.ZoomIn, ScreenZoomSteps.ForKey("="));
        Assert.Equal(ScreenZoomStep.ZoomIn, ScreenZoomSteps.ForKey("+"));
        Assert.Equal(ScreenZoomStep.ZoomOut, ScreenZoomSteps.ForKey("-"));
        Assert.Equal(ScreenZoomStep.ZoomOut, ScreenZoomSteps.ForKey("_"));
        Assert.Equal(ScreenZoomStep.Fit, ScreenZoomSteps.ForKey("0"));
        Assert.Null(ScreenZoomSteps.ForKey("1"));
        Assert.Null(ScreenZoomSteps.ForKey(""));
        Assert.Equal(1.5, ScreenZoomStep.ZoomIn.Factor());
        Assert.True(Math.Abs(ScreenZoomStep.ZoomIn.Factor()!.Value * ScreenZoomStep.ZoomOut.Factor()!.Value - 1) < 1e-9);
        Assert.Null(ScreenZoomStep.Fit.Factor());
    }
}

/// Through the viewer and a fake bot screen: a tap and the keys reach the wire as RFB messages, only in control.
[Collection("ScreenSession")]
public sealed class ScreenStageInputWireTests
{
    private static List<string> Inputs(ViewerRig rig) => SessionRig.Inputs(rig.Socket);

    [Fact]
    public async Task ATapAndTheKeysGoOutAsPointerAndKeyEventsOnlyInControl()
    {
        using var rig = new ViewerRig(s => s.Display = "Xvfb :99");
        rig.Show();
        Assert.True(await rig.Live());
        var (width, height) = rig.Get(v => v.Stage.Framebuffer);
        rig.Do(v => v.Stage.Layout(new ScreenSize(width, height)));
        // Watching: the tap is taken (the local view's) but nothing is sent.
        rig.Do(v => { v.Stage.Pressed(1, ScreenPointerButton.Primary, new ScreenPoint(2, 2)); v.Stage.Released(1); });
        rig.Do(v => { v.KeyInput.FocusChanged(true); v.KeyInput.CharacterReceived('q', ScreenKeyInput.Mods()); v.KeyInput.FocusChanged(false); });
        Assert.Empty(Inputs(rig));
        Assert.True(await rig.TakeOver());
        var (x, y) = (width / 2, height / 2);
        // Taking control clears the buttons at the centre. That pointer message crosses the socket on its own time:
        // counting before it lands made the tap's count off by one under load (timed out once in a full run).
        Assert.True(await ScreenWait(() => Inputs(rig).Contains($"pointer 0 {x},{y}")));
        var taken = Inputs(rig).Count;
        rig.Do(v => { v.Stage.Pressed(1, ScreenPointerButton.Primary, new ScreenPoint(2, 2)); v.Stage.Released(1); });
        Assert.True(await ScreenWait(() => Inputs(rig).Count == taken + 3));
        Assert.Equal([$"pointer 0 {x},{y}", $"pointer 1 {x},{y}", $"pointer 0 {x},{y}"], Inputs(rig).Skip(taken));
        rig.Do(v => v.Stage.Wheel(-120, new ScreenPoint(2, 2)));
        Assert.True(await ScreenWait(() => Inputs(rig).Contains($"pointer 16 {x},{y}")));
        // Control raised the key field; text and a chord go out as key events.
        rig.Do(v => v.KeyInput.FocusChanged(true));
        rig.Do(v => v.KeyInput.CharacterReceived('h', ScreenKeyInput.Mods()));
        Assert.True(await ScreenWait(() => Inputs(rig).Contains("key 68 up")));
        rig.Do(v => v.KeyInput.KeyDown(0x43, ScreenKeyInput.Mods(ctrl: true)));
        Assert.True(await ScreenWait(() => Inputs(rig).Count(i => i.StartsWith("key", StringComparison.Ordinal)) == 6));
        Assert.Equal(["key 68 down", "key 68 up", "key ffe3 down", "key 63 down", "key 63 up", "key ffe3 up"],
                     Inputs(rig).Where(i => i.StartsWith("key", StringComparison.Ordinal)));
    }
}
