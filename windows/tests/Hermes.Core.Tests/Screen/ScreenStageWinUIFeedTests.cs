// [WIN-SCREEN-INPUT-WIRE] The WinUI stage's translation into Hermes.Core (Hermes.Core/Screen/ScreenStageInput.cs): a
// test per rule for what the page hands over (pointer events, the wheel, the keyboard's state, Narrator's patterns)
// and the motion taken from 93f984bb1 App/Screen/ScreenStageView.swift. The Mac has no test of ScreenStageView's
// wiring or its layers (UIKit drives them); its rules' tests are ported in ScreenStageInputTests, ScreenKeyInputTests
// and ScreenStageLifetimeTests. Synthetic pictures and keys only.

using Hermes.Core.Screen;
using M = Hermes.Core.Screen.ScreenKeys.Modifier;
using N = Hermes.Core.Screen.ScreenKeys.Named;

namespace Hermes.Core.Tests.Screen;

public sealed class ScreenStageWinUIFeedTests
{
    private const int Touch = ScreenStageInput.Touch, Pen = ScreenStageInput.Pen, Mouse = ScreenStageInput.Mouse, Touchpad = ScreenStageInput.Touchpad;

    private sealed class Rig
    {
        public FakeFrameTicks Ticks { get; } = new();
        public FakeViewerTimers Timers { get; } = new();
        public double Now;
        public List<(byte Mask, int X, int Y)> Sent { get; } = [];
        public List<(ScreenView View, bool Committed)> Views { get; } = [];
        public List<bool> Rings { get; } = [];
        public ScreenStageState Stage { get; }
        public ScreenStageInput Input { get; }

        public Rig(bool control = true)
        {
            Stage = new ScreenStageState(Ticks, Timers, () => Now)
            {
                OnPointer = (m, x, y) => Sent.Add((m, x, y)),
                OnView = (v, c) => Views.Add((v, c)),
                OnRing = Rings.Add,
            };
            Stage.Layout(new ScreenSize(400, 250));
            Stage.Show(new byte[400 * 250 * 4], 400, 250);
            Stage.Control = control;
            Input = new ScreenStageInput(Stage);
        }
    }

    private static ScreenPointerArgs E(uint id, int device, double x = 40, double y = 60, bool left = false, bool right = false,
                                       bool middle = false, bool barrel = false, int wheel = 0, bool horizontal = false,
                                       bool ctrl = false, bool shift = false) =>
        new(id, device, new ScreenPoint(x, y), left, right, middle, barrel, wheel, horizontal, ctrl, shift);

    private static (byte, int, int) S(int mask, int x, int y) => ((byte)mask, x, y);

    // Pointer events

    [Fact]
    public void WinUIsDeviceTypesAreTheStagesAndATouchpadPressesAsTheMouse()
    {
        Assert.Equal(ScreenPointerDevice.Touch, ScreenStageInput.Device(Touch));
        Assert.Equal(ScreenPointerDevice.Pen, ScreenStageInput.Device(Pen));
        Assert.Equal(ScreenPointerDevice.Mouse, ScreenStageInput.Device(Mouse));
        Assert.Equal(ScreenPointerDevice.Mouse, ScreenStageInput.Device(Touchpad));
        Assert.Equal(ScreenPointerDevice.Mouse, ScreenStageInput.Device(99));   // a device type Windows adds later
    }

    [Fact]
    public void EachPressIsReadFromItsProperties()
    {
        Assert.Equal(ScreenPointerButton.Primary, ScreenStageInput.Button(E(1, Touch, right: true)));      // a finger is a finger
        Assert.Equal(ScreenPointerButton.Primary, ScreenStageInput.Button(E(2, Pen, left: true)));
        Assert.Equal(ScreenPointerButton.Secondary, ScreenStageInput.Button(E(2, Pen, left: true, barrel: true)));
        Assert.Equal(ScreenPointerButton.Primary, ScreenStageInput.Button(E(3, Mouse, left: true)));
        Assert.Equal(ScreenPointerButton.Secondary, ScreenStageInput.Button(E(3, Mouse, right: true)));
        Assert.Equal(ScreenPointerButton.Middle, ScreenStageInput.Button(E(3, Mouse, middle: true)));
        Assert.Equal(ScreenPointerButton.Primary, ScreenStageInput.Button(E(4, Touchpad, left: true)));
        Assert.Equal(ScreenPointerButton.None, ScreenStageInput.Button(E(3, Mouse)));                       // an X button
    }

    [Fact]
    public void AMouseClickIsOneClickEvenWithTheCaptureLostAfterTheRelease()
    {
        var rig = new Rig();
        Assert.True(rig.Input.Pressed(E(1, Mouse, left: true)));
        rig.Input.Released(E(1, Mouse));
        rig.Input.Lost(E(1, Mouse));   // ReleasePointerCapture raises PointerCaptureLost after the release
        Assert.Equal([S(0, 200, 125), S(1, 200, 125), S(0, 200, 125)], rig.Sent);
        Assert.Equal([true, false], rig.Rings);
    }

    [Fact]
    public void ARightButtonClickLandsOnReleaseAndALostOneNever()
    {
        var rig = new Rig();
        Assert.True(rig.Input.Pressed(E(1, Mouse, right: true)));
        rig.Input.Released(E(1, Mouse));
        Assert.Equal([S(0, 200, 125), S(4, 200, 125), S(0, 200, 125)], rig.Sent);
        rig.Sent.Clear();
        Assert.True(rig.Input.Pressed(E(1, Mouse, right: true)));
        rig.Input.Lost(E(1, Mouse));
        rig.Input.Released(E(1, Mouse));
        Assert.Empty(rig.Sent);
    }

    [Fact]
    public void ACanceledTouchNeverClicksAndAHoverMovesNothing()
    {
        var rig = new Rig();
        rig.Input.Moved(E(5, Mouse, 90, 90));   // hovering: never pressed here
        rig.Ticks.Frame();
        Assert.Empty(rig.Sent);
        Assert.True(rig.Input.Pressed(E(7, Touch)));
        rig.Input.Lost(E(7, Touch));            // PointerCanceled: the system took the finger
        rig.Input.Released(E(7, Touch));
        rig.Ticks.Frame();
        Assert.Empty(rig.Sent);
        Assert.Equal([true, false], rig.Rings);
    }

    [Fact]
    public void ATouchDragMovesThePointerAndTheRingFollowsIt()
    {
        var rig = new Rig();
        Assert.True(rig.Input.Pressed(E(7, Touch, 10, 10)));
        rig.Input.Moved(E(7, Touch, 60, 20));
        rig.Ticks.Frame();
        Assert.Equal([S(0, 250, 135)], rig.Sent);
        // The ring sits on the pointer over the picture (400×250 in a 400×250 stage: pixels are points).
        Assert.Equal(new ScreenPoint(250, 135), rig.Stage.RingPoint);
        rig.Input.Released(E(7, Touch));
    }

    [Fact]
    public void WatchingAPressIsStillTakenForTheLocalViewButNothingIsSent()
    {
        var rig = new Rig(control: false);
        Assert.True(rig.Input.Pressed(E(1, Touch)));
        rig.Input.Released(E(1, Touch));
        Assert.False(rig.Input.Pressed(E(2, Mouse, right: true)));   // a right click is control's only
        Assert.Empty(rig.Sent);
    }

    // The wheel

    [Fact]
    public void AMouseWheelNotchIsAStepAndShiftOrATiltWheelIsIgnored()
    {
        var rig = new Rig();
        rig.Input.Wheel(E(1, Mouse, wheel: -120));
        Assert.Equal([S(16, 200, 125), S(0, 200, 125)], rig.Sent);
        rig.Sent.Clear();
        rig.Input.Wheel(E(1, Mouse, wheel: -120, shift: true));       // Shift+wheel: Windows' sideways scroll
        rig.Input.Wheel(E(1, Mouse, wheel: 120, horizontal: true));  // the tilt wheel
        Assert.Empty(rig.Sent);
    }

    [Fact]
    public void CtrlWheelZoomsAndCtrlShiftWheelToo()
    {
        var rig = new Rig();
        rig.Input.Wheel(E(1, Mouse, 200, 125, wheel: 120, ctrl: true));
        Assert.True(ScreenViewMathTests.Close(rig.Stage.View.Zoom, ScreenZoomSteps.ScrollFactor(10, discrete: true)));
        rig.Now = 1;
        rig.Input.Wheel(E(1, Mouse, 200, 125, wheel: 120, ctrl: true, shift: true));
        Assert.Equal(2, rig.Views.Count);
        Assert.Empty(rig.Sent);
    }

    [Fact]
    public void ATouchpadWheelIsContinuousEvenInWholeNotches()
    {
        // The same 120 zooms by a notch's factor from a mouse and by a touchpad's (smaller) one.
        var mouse = new Rig();
        mouse.Input.Wheel(E(1, Mouse, 200, 125, wheel: 120, ctrl: true));
        var pad = new Rig();
        pad.Input.Wheel(E(1, Touchpad, 200, 125, wheel: 120, ctrl: true));
        Assert.True(ScreenViewMathTests.Close(mouse.Stage.View.Zoom, ScreenZoomSteps.ScrollFactor(10, discrete: true)));
        Assert.True(ScreenViewMathTests.Close(pad.Stage.View.Zoom, ScreenZoomSteps.ScrollFactor(10, discrete: false)));
        Assert.True(pad.Stage.View.Zoom < mouse.Stage.View.Zoom);
        // Scrolling, a touchpad's travel is carried: 60 is nothing yet, 60 more is a step.
        pad.Now = 1;
        pad.Input.Wheel(E(1, Touchpad, wheel: -60));
        Assert.Empty(pad.Sent);
        pad.Now = 1.05;
        pad.Input.Wheel(E(1, Touchpad, wheel: -60));
        Assert.Equal([S(16, 200, 125), S(0, 200, 125)], pad.Sent);
    }

    // The keyboard

    [Fact]
    public void AltGrIsTheRightAltWithCtrlAndOtherwiseTheRightAltIsAlt()
    {
        Assert.True(new ScreenKeyState(Ctrl: true, Alt: true, RightAlt: true).AltGr);
        Assert.Empty(new ScreenKeyState(Ctrl: true, Alt: true, RightAlt: true).Mods);
        Assert.False(new ScreenKeyState(Alt: true, RightAlt: true).AltGr);   // a US layout's right Alt
        Assert.Equal([M.Alt], new ScreenKeyState(Alt: true, RightAlt: true).Mods);
        Assert.Equal([M.Ctrl, M.Alt], new ScreenKeyState(Ctrl: true, Alt: true).Mods.ToHashSet());   // left Ctrl+Alt: a chord
        Assert.Equal([M.Shift, M.Meta], new ScreenKeyState(Shift: true, Meta: true).Mods.ToHashSet());
        Assert.Equal([M.Shift], new ScreenKeyState(Shift: true, Ctrl: true, Alt: true, RightAlt: true).Mods);
    }

    [Fact]
    public void PunctuationKeysCarryTheirUnshiftedCharacter()
    {
        var expected = new Dictionary<int, string>
        {
            [ScreenKeyFeed.Oem1] = ";", [ScreenKeyFeed.OemPlus] = "=", [ScreenKeyFeed.OemComma] = ",", [ScreenKeyFeed.OemMinus] = "-",
            [ScreenKeyFeed.OemPeriod] = ".", [ScreenKeyFeed.Oem2] = "/", [ScreenKeyFeed.Oem3] = "`", [ScreenKeyFeed.Oem4] = "[",
            [ScreenKeyFeed.Oem5] = "\\", [ScreenKeyFeed.Oem6] = "]", [ScreenKeyFeed.Oem7] = "'", [ScreenKeyFeed.Oem102] = "\\",
            [ScreenKeyFeed.Multiply] = "*", [ScreenKeyFeed.Add] = "+", [ScreenKeyFeed.Subtract] = "-", [ScreenKeyFeed.Decimal] = ".",
            [ScreenKeyFeed.Divide] = "/",
        };
        foreach (var (vk, character) in expected) Assert.Equal(character, ScreenKeyFeed.Unshifted(vk));
        Assert.Null(ScreenKeyFeed.Unshifted(0x41));
        // A–Z, 0–9 and Space come from the key itself; a layout seam wins when the page has one.
        Assert.Equal("c", ScreenKeyFeed.ChordCharacter(0x43));
        Assert.Equal("7", ScreenKeyFeed.ChordCharacter(0x67));
        Assert.Equal("#", ScreenKeyFeed.ChordCharacter(ScreenKeyFeed.Oem2, vk => vk == ScreenKeyFeed.Oem2 ? "#" : null));
        Assert.Equal("c", ScreenKeyFeed.ChordCharacter(0x43, _ => null));
        Assert.Null(ScreenKeyFeed.ChordCharacter(0x10));   // Shift alone
    }

    private sealed class Keys
    {
        public List<string> Texts { get; } = [];
        public List<(N Key, HashSet<M> Mods)> Named { get; } = [];
        public List<(string Character, HashSet<M> Mods)> Chords { get; } = [];
        public ScreenKeyInput Input { get; }

        public Keys()
        {
            Input = new ScreenKeyInput
            {
                OnText = Texts.Add,
                OnKey = (k, m) => Named.Add((k, m.ToHashSet())),
                OnChord = (c, m) => Chords.Add((c, m.ToHashSet())),
            };
            Input.FocusChanged(true);
        }
    }

    [Fact]
    public void CtrlChordsOnPunctuationSendTheKeysUnshiftedCharacterOnce()
    {
        var keys = new Keys();
        Assert.True(ScreenKeyFeed.KeyDown(keys.Input, ScreenKeyFeed.Oem2, new ScreenKeyState(Ctrl: true)));                   // Ctrl+/
        Assert.True(ScreenKeyFeed.KeyDown(keys.Input, ScreenKeyFeed.OemPlus, new ScreenKeyState(Shift: true, Ctrl: true)));   // Ctrl+Shift+=
        Assert.True(ScreenKeyFeed.KeyDown(keys.Input, ScreenKeyFeed.Divide, new ScreenKeyState(Alt: true)));                  // Alt+keypad /
        Assert.True(ScreenKeyFeed.KeyDown(keys.Input, ScreenKeyFeed.Oem2, new ScreenKeyState(Ctrl: true), repeat: true));    // held: no repeat
        // The chord's control character never types as well.
        ScreenKeyFeed.Character(keys.Input, '\u001f', new ScreenKeyState(Ctrl: true));
        Assert.Equal([("/", [M.Ctrl]), ("=", [M.Shift, M.Ctrl]), ("/", [M.Alt])],
                     keys.Chords.Select(c => (c.Character, c.Mods)).ToList(), new ChordComparer());
        Assert.Empty(keys.Texts);
    }

    [Fact]
    public void AltGrTypesTheLayoutsCharacterAsText()
    {
        var keys = new Keys();
        var altGr = new ScreenKeyState(Ctrl: true, Alt: true, RightAlt: true);
        // AltGr+Q on a German keyboard: the KeyDown is not a chord, the @ comes as CharacterReceived.
        Assert.False(ScreenKeyFeed.KeyDown(keys.Input, 0x51, altGr));
        ScreenKeyFeed.Character(keys.Input, '@', altGr);
        Assert.Equal(["@"], keys.Texts);
        Assert.Empty(keys.Chords);
        // The left Ctrl+Alt with Q is a chord.
        Assert.True(ScreenKeyFeed.KeyDown(keys.Input, 0x51, new ScreenKeyState(Ctrl: true, Alt: true)));
        Assert.Equal("q", keys.Chords.Single().Character);
    }

    [Fact]
    public void NamedKeysGoAsKeysWithTheirModifiers()
    {
        var keys = new Keys();
        Assert.True(ScreenKeyFeed.KeyDown(keys.Input, 0x09, new ScreenKeyState(Shift: true)));   // Shift+Tab stays on the stage
        Assert.True(ScreenKeyFeed.KeyDown(keys.Input, 0x1B, new ScreenKeyState()));
        Assert.Equal([(N.Tab, new HashSet<M> { M.Shift }), (N.Escape, new HashSet<M>())], keys.Named, new NamedComparer());
        Assert.False(ScreenKeyFeed.KeyDown(keys.Input, 0x41, new ScreenKeyState()));              // plain A: CharacterReceived's
    }

    private sealed class ChordComparer : IEqualityComparer<List<(string, HashSet<M>)>>
    {
        public bool Equals(List<(string, HashSet<M>)>? a, List<(string, HashSet<M>)>? b) =>
            a!.Count == b!.Count && a.Zip(b).All(p => p.First.Item1 == p.Second.Item1 && p.First.Item2.SetEquals(p.Second.Item2));
        public int GetHashCode(List<(string, HashSet<M>)> obj) => obj.Count;
    }

    private sealed class NamedComparer : IEqualityComparer<List<(N, HashSet<M>)>>
    {
        public bool Equals(List<(N, HashSet<M>)>? a, List<(N, HashSet<M>)>? b) =>
            a!.Count == b!.Count && a.Zip(b).All(p => p.First.Item1 == p.Second.Item1 && p.First.Item2.SetEquals(p.Second.Item2));
        public int GetHashCode(List<(N, HashSet<M>)> obj) => obj.Count;
    }

    // Narrator

    [Fact]
    public void NarratorsPatternsAreTheStagesActions()
    {
        Assert.Equal(ScreenStageAct.Click, ScreenStageAccess.Invoke);
        Assert.Equal(ScreenStageAct.ScrollUp, ScreenStageAccess.Scroll(ScreenStageAccess.ScrollSmallDecrement));
        Assert.Equal(ScreenStageAct.ScrollUp, ScreenStageAccess.Scroll(ScreenStageAccess.ScrollLargeDecrement));
        Assert.Equal(ScreenStageAct.ScrollDown, ScreenStageAccess.Scroll(ScreenStageAccess.ScrollSmallIncrement));
        Assert.Equal(ScreenStageAct.ScrollDown, ScreenStageAccess.Scroll(ScreenStageAccess.ScrollLargeIncrement));
        Assert.Null(ScreenStageAccess.Scroll(ScreenStageAccess.ScrollNoAmount));
        Assert.Equal(ScreenStageAct.ZoomIn, ScreenStageAccess.ZoomUnit(ScreenStageAccess.ZoomSmallIncrement));
        Assert.Equal(ScreenStageAct.ZoomIn, ScreenStageAccess.ZoomUnit(ScreenStageAccess.ZoomLargeIncrement));
        Assert.Equal(ScreenStageAct.ZoomOut, ScreenStageAccess.ZoomUnit(ScreenStageAccess.ZoomSmallDecrement));
        Assert.Equal(ScreenStageAct.ZoomOut, ScreenStageAccess.ZoomUnit(ScreenStageAccess.ZoomLargeDecrement));
        Assert.Null(ScreenStageAccess.ZoomUnit(ScreenStageAccess.ZoomNoAmount));
        Assert.Equal(ScreenStageAct.Fit, ScreenStageAccess.ZoomTo(1, 2));
        Assert.Equal(ScreenStageAct.Fit, ScreenStageAccess.ZoomTo(0.5, 1));
        Assert.Equal(ScreenStageAct.ZoomIn, ScreenStageAccess.ZoomTo(3, 1.5));
        Assert.Equal(ScreenStageAct.ZoomOut, ScreenStageAccess.ZoomTo(2, 3));
        Assert.Null(ScreenStageAccess.ZoomTo(2, 2));
    }

    [Fact]
    public void NarratorClicksAndScrollsOnlyInControlAndZoomsAlways()
    {
        var watching = new Rig(control: false);
        Assert.False(ScreenStageAccess.Offers(watching.Stage, ScreenStageAct.Click));
        Assert.False(ScreenStageAccess.Run(watching.Stage, ScreenStageAccess.Invoke));
        Assert.False(ScreenStageAccess.Run(watching.Stage, ScreenStageAccess.Scroll(ScreenStageAccess.ScrollSmallIncrement)));
        Assert.True(ScreenStageAccess.Run(watching.Stage, ScreenStageAct.ZoomIn));
        Assert.True(ScreenViewMathTests.Close(watching.Stage.View.Zoom, ScreenZoomSteps.StepFactor));
        Assert.True(ScreenStageAccess.Run(watching.Stage, ScreenStageAct.Fit));
        Assert.Equal(ScreenView.Fit, watching.Stage.View);
        Assert.Empty(watching.Sent);

        var control = new Rig();
        Assert.True(ScreenStageAccess.Run(control.Stage, ScreenStageAccess.Invoke));
        Assert.True(ScreenStageAccess.Run(control.Stage, ScreenStageAccess.Scroll(ScreenStageAccess.ScrollSmallDecrement)));
        Assert.Equal([S(0, 200, 125), S(1, 200, 125), S(0, 200, 125), S(8, 200, 125), S(0, 200, 125)], control.Sent);
        Assert.False(ScreenStageAccess.Run(control.Stage, null));
    }

    // Motion (ScreenStageView.swift)

    [Fact]
    public void TheMotionIsTheSwifts()
    {
        Assert.Equal(0.22, ScreenStageMotion.ViewSeconds);      // setView: animation.duration = 0.22
        Assert.Equal(0.3, ScreenStageMotion.RingFadeSeconds);   // showRing: fade.duration = 0.3
        Assert.Equal(0.9, ScreenStageMotion.RingOpacity);       // ring.opacity = on ? 0.9 : 0
        Assert.Equal(14, ScreenStageMotion.RingDiameter);       // ovalIn: (-7, -7, 14, 14)
        Assert.Equal(ScreenStageMotion.RingStrokeAlpha, (byte)Math.Round(0.6 * 255));
        Assert.Equal(ScreenStageMotion.DimAlpha, (byte)Math.Round(0.4 * 255));
        Assert.Equal(0.5, ScreenStageMotion.Hairline(2));
        Assert.Equal(1, ScreenStageMotion.Hairline(0));
    }

    [Fact]
    public void TheRingShowsAtOnceAndFadesUnlessMotionIsReduced()
    {
        Assert.Equal((0.9, 0.0), ScreenStageMotion.Ring(on: true, animationsEnabled: true));
        Assert.Equal((0.9, 0.0), ScreenStageMotion.Ring(on: true, animationsEnabled: false));
        Assert.Equal((0.0, 0.3), ScreenStageMotion.Ring(on: false, animationsEnabled: true));
        Assert.Equal((0.0, 0.0), ScreenStageMotion.Ring(on: false, animationsEnabled: false));
        Assert.True(ScreenStageMotion.Animates(true, true));
        Assert.False(ScreenStageMotion.Animates(true, false));
        Assert.False(ScreenStageMotion.Animates(false, true));
    }

    [Fact]
    public void AViewChangeStartsWhereThePictureWasAndRunsToWhereItWent()
    {
        var from = new ScreenRect(0, 0, 400, 250);
        var to = new ScreenRect(-200, -125, 800, 500);
        var (sx, sy, tx, ty) = ScreenStageMotion.From(from, to);
        Assert.Equal((0.5, 0.5, 200.0, 125.0), (sx, sy, tx, ty));
        // The start transform, about the placed picture's top-left, lands it exactly on the old frame.
        Assert.Equal(from.X, to.X + tx);
        Assert.Equal(from.Width, to.Width * sx);
        Assert.Equal((1.0, 1.0, 0.0, 0.0), ScreenStageMotion.From(ScreenRect.Zero, to));   // nothing drawn before: no motion
        Assert.Equal(new ScreenPoint(193, 118), ScreenStageMotion.RingOrigin(new ScreenPoint(200, 125)));
    }
}
