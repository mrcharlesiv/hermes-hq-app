// [WIN-SCREEN-INPUT-WIRE] What the WinUI Bot Screen stage hands Hermes.Core, as plain values: the page reads a
// PointerRoutedEventArgs / KeyRoutedEventArgs / CharacterReceivedRoutedEventArgs / an automation pattern call into the
// records here and this turns them into ScreenStageState and ScreenKeyInput calls (ScreenGesture.cs holds the rules
// themselves). It also carries the stage's motion from the Mac's App/Screen/ScreenStageView.swift at 93f984bb1: the
// local view animates over 0.22 s and the pointer ring fades out over 0.3 s, both CABasicAnimation's default (linear)
// curve; with Reduce Motion (Windows: UISettings.AnimationsEnabled off) both jump. Nothing typed is kept or logged.

namespace Hermes.Core.Screen;

/// The stage's motion (ScreenStageView.swift: `setView(_:animated:)`, `showRing(_:)`, the ring's layer).
public static class ScreenStageMotion
{
    /// `animation.duration = 0.22` for the picture's size and position when the local view changes.
    public const double ViewSeconds = 0.22;
    /// `fade.duration = 0.3` when the ring goes (it shows at once).
    public const double RingFadeSeconds = 0.3;
    /// `ring.opacity = 0.9` while a finger is down in control.
    public const double RingOpacity = 0.9;
    /// `UIBezierPath(ovalIn: CGRect(x: -7, y: -7, width: 14, height: 14))`.
    public const double RingDiameter = 14;
    /// `ring.strokeColor = UIColor.black.withAlphaComponent(0.6)`: the stroke's alpha byte.
    public const byte RingStrokeAlpha = 0x99;
    /// `dimLayer.backgroundColor = UIColor.black.withAlphaComponent(0.4)`: the dim's alpha byte.
    public const byte DimAlpha = 0x66;

    /// The ring's stroke: `HQShape.hairline`, one physical pixel.
    public static double Hairline(double rasterizationScale) => rasterizationScale > 0 ? 1 / rasterizationScale : 1;

    /// Whether a change animates: asked to, and motion is not reduced (`animated, !HQMotion.reduced`).
    public static bool Animates(bool animated, bool animationsEnabled) => animated && animationsEnabled;

    /// The ring's change: showing jumps to 0.9; going fades over 0.3 s, unless motion is reduced (then it jumps).
    public static (double Opacity, double Seconds) Ring(bool on, bool animationsEnabled) =>
        on ? (RingOpacity, 0) : (0, animationsEnabled ? RingFadeSeconds : 0);

    /// The transform that draws a picture placed at `to` where it was at `from` (the animation's start; it runs to
    /// identity), scaling about the picture's top-left: what the Swift's bounds.size + position pair animates.
    public static (double ScaleX, double ScaleY, double TranslateX, double TranslateY) From(ScreenRect from, ScreenRect to)
    {
        if (!(to.Width > 0 && to.Height > 0 && from.Width > 0 && from.Height > 0)) return (1, 1, 0, 0);
        return (from.Width / to.Width, from.Height / to.Height, from.X - to.X, from.Y - to.Y);
    }

    /// Where the ring's 14-point box goes for the pointer at `point`.
    public static ScreenPoint RingOrigin(ScreenPoint point) => new(point.X - RingDiameter / 2, point.Y - RingDiameter / 2);
}

/// One WinUI pointer event as values (`e.Pointer`, `e.GetCurrentPoint(stage)`, `e.KeyModifiers`).
/// `DeviceType` is Microsoft.UI.Input.PointerDeviceType's value: Touch 0, Pen 1, Mouse 2, Touchpad 3.
public readonly record struct ScreenPointerArgs(
    uint Id, int DeviceType, ScreenPoint At,
    bool Left = false, bool Right = false, bool Middle = false, bool Barrel = false,
    int WheelDelta = 0, bool HorizontalWheel = false, bool Ctrl = false, bool Shift = false);

/// The stage's pointer input: WinUI's events into ScreenStageState.
public sealed class ScreenStageInput(ScreenStageState stage)
{
    public const int Touch = 0, Pen = 1, Mouse = 2, Touchpad = 3;

    public ScreenStageState Stage => stage;

    /// A WinUI device type as the stage's: a touchpad's click and press is the mouse's (Windows sends it as the mouse).
    public static ScreenPointerDevice Device(int deviceType) => deviceType switch
    {
        Touch => ScreenPointerDevice.Touch,
        Pen => ScreenPointerDevice.Pen,
        _ => ScreenPointerDevice.Mouse,
    };

    /// What the press is (ScreenPointerButtons.From over the event's properties).
    public static ScreenPointerButton Button(ScreenPointerArgs e) =>
        ScreenPointerButtons.From(Device(e.DeviceType), e.Left, e.Right, e.Middle, e.Barrel);

    /// PointerPressed. True: the stage took it (the page captures the pointer and marks the event handled).
    public bool Pressed(ScreenPointerArgs e) => stage.Pressed(e.Id, Button(e), e.At);

    /// PointerMoved (a hover moves nothing: the stage only follows contacts it took).
    public void Moved(ScreenPointerArgs e) => stage.Moved(e.Id, e.At);

    /// PointerReleased.
    public void Released(ScreenPointerArgs e) => stage.Released(e.Id);

    /// PointerCanceled and PointerCaptureLost: never a click. After a release the capture's loss finds nothing.
    public void Lost(ScreenPointerArgs e) => stage.Canceled(e.Id);

    /// PointerWheelChanged. Ctrl zooms; Shift+wheel and a tilt wheel are horizontal (ignored, as the Mac reads only
    /// y); a touchpad's wheel is continuous whatever its delta, a mouse's is told by the delta.
    public void Wheel(ScreenPointerArgs e) =>
        stage.Wheel(e.WheelDelta, e.At, zoom: e.Ctrl, horizontal: e.HorizontalWheel || (e.Shift && !e.Ctrl),
                    discrete: e.DeviceType == Touchpad ? false : null);
}

/// The keyboard's state at a KeyDown or CharacterReceived (InputKeyboardSource.GetKeyStateForCurrentThread).
public readonly record struct ScreenKeyState(bool Shift = false, bool Ctrl = false, bool Alt = false, bool Meta = false, bool RightAlt = false)
{
    /// AltGr: Windows sends the right Alt of a layout that has one as Ctrl+Alt. Only with Ctrl held is the right Alt
    /// AltGr; on a layout without one the right Alt is an Alt like the left.
    public bool AltGr => RightAlt && Ctrl;

    public HashSet<ScreenKeys.Modifier> Mods => ScreenKeyInput.Mods(Shift, Ctrl, Alt, Meta, AltGr);
}

/// The key field's WinUI feed: KeyDown and CharacterReceived into ScreenKeyInput.
public static class ScreenKeyFeed
{
    // Windows.System.VirtualKey values of the punctuation (OEM) keys and the keypad's operators.
    public const int Oem1 = 0xBA, OemPlus = 0xBB, OemComma = 0xBC, OemMinus = 0xBD, OemPeriod = 0xBE, Oem2 = 0xBF, Oem3 = 0xC0;
    public const int Oem4 = 0xDB, Oem5 = 0xDC, Oem6 = 0xDD, Oem7 = 0xDE, Oem102 = 0xE2;
    public const int Multiply = 0x6A, Add = 0x6B, Subtract = 0x6D, Decimal = 0x6E, Divide = 0x6F;

    /// The unshifted character of a punctuation key, for a chord (Ctrl+/ is "/"). Without ToUnicodeEx the page has
    /// no layout to ask, so this is the US layout's (what the bot's own keymap most often is; a VNC client sends the
    /// keysym of the key's unshifted character). The keypad's operators are the same on every layout.
    public static string? Unshifted(int virtualKey) => virtualKey switch
    {
        Oem1 => ";", OemPlus => "=", OemComma => ",", OemMinus => "-", OemPeriod => ".", Oem2 => "/", Oem3 => "`",
        Oem4 => "[", Oem5 => "\\", Oem6 => "]", Oem7 => "'", Oem102 => "\\",
        Multiply => "*", Add => "+", Subtract => "-", Decimal => ".", Divide => "/",
        _ => null,
    };

    /// The character a chord carries: the layout's when the page has one (`layout`, a seam), else the US punctuation
    /// above, else A–Z, 0–9 and Space (ScreenKeyInput.Unmodified).
    public static string? ChordCharacter(int virtualKey, Func<int, string?>? layout = null) =>
        layout?.Invoke(virtualKey) ?? Unshifted(virtualKey) ?? ScreenKeyInput.Unmodified(virtualKey);

    /// KeyDown (`KeyStatus.WasKeyDown` is `repeat`). True: the page marks it handled (Tab and the arrows stay here).
    public static bool KeyDown(ScreenKeyInput input, int virtualKey, ScreenKeyState keys, bool repeat = false, Func<int, string?>? layout = null) =>
        input.KeyDown(virtualKey, keys.Mods, repeat, ChordCharacter(virtualKey, layout));

    /// CharacterReceived: one UTF-16 unit.
    public static void Character(ScreenKeyInput input, char unit, ScreenKeyState keys) => input.CharacterReceived(unit, keys.Mods);
}

/// The stage's actions as UI Automation offers them. UIA has no custom actions (VoiceOver's), so Narrator reaches them
/// through patterns: Invoke is Click; Scroll's vertical small/large steps are Scroll up / Scroll down; Transform2's
/// zoom steps are Zoom in / Zoom out, and zooming to 1 (or below) is Fit screen. Right-click has no pattern.
public static class ScreenStageAccess
{
    // Microsoft.UI.Xaml.Automation.ScrollAmount and ZoomUnit values.
    public const int ScrollLargeDecrement = 0, ScrollSmallDecrement = 1, ScrollNoAmount = 2, ScrollLargeIncrement = 3, ScrollSmallIncrement = 4;
    public const int ZoomNoAmount = 0, ZoomLargeDecrement = 1, ZoomSmallDecrement = 2, ZoomLargeIncrement = 3, ZoomSmallIncrement = 4;

    public static ScreenStageAct Invoke => ScreenStageAct.Click;

    /// IScrollProvider.Scroll(horizontal, vertical): only the vertical amount is read (the Mac's wheel is y only).
    public static ScreenStageAct? Scroll(int vertical) => vertical switch
    {
        ScrollSmallDecrement or ScrollLargeDecrement => ScreenStageAct.ScrollUp,
        ScrollSmallIncrement or ScrollLargeIncrement => ScreenStageAct.ScrollDown,
        _ => null,
    };

    /// ITransformProvider2.ZoomByUnit.
    public static ScreenStageAct? ZoomUnit(int unit) => unit switch
    {
        ZoomSmallIncrement or ZoomLargeIncrement => ScreenStageAct.ZoomIn,
        ZoomSmallDecrement or ZoomLargeDecrement => ScreenStageAct.ZoomOut,
        _ => null,
    };

    /// ITransformProvider2.Zoom(level): 1 or below fits; otherwise a step toward the level asked for.
    public static ScreenStageAct? ZoomTo(double level, double current) =>
        level <= 1.001 ? ScreenStageAct.Fit
        : level > current + 0.001 ? ScreenStageAct.ZoomIn
        : level < current - 0.001 ? ScreenStageAct.ZoomOut
        : null;

    /// Whether a pattern is offered now: Invoke and Scroll only in control (the pointer's actions), zoom always.
    public static bool Offers(ScreenStageState stage, ScreenStageAct act) => stage.Acts.Contains(act);

    /// Runs the act if the stage offers it now; false when it does nothing.
    public static bool Run(ScreenStageState stage, ScreenStageAct? act) => act is { } a && Offers(stage, a) && stage.Act(a);
}
