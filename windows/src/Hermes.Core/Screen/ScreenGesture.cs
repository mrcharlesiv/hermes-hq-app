// [WIN-SCREEN-GESTURE] The Bot Screen stage's input rules, the C# twin of the input half of the Mac's
// App/Screen/ScreenStageView.swift and of App/Screen/ScreenKeyField.swift at 93f984bb1 (docs/spec/3x-screen.md §5.5,
// §5.6). The touch state machine itself (tap, hold, drag, pinch, two-finger scroll, double tap) is ScreenGesture in
// ScreenViewMath.cs, ported with its Mac tests; this file is what the stage view does around it: which contacts reach
// it, the hold timer, turning its actions into RFB PointerEvent(mask, x, y) in the bot's framebuffer pixels (through
// ScreenStageState.OnPointer, which the viewer wires to ScreenSession.SendPointer), the wheel, the accessibility
// actions, and the keyboard's rules (ScreenKeyInput → the viewer's KeyText / KeyPress / Chord → ScreenSession).
//
// Windows has no trackpad gesture recognizers; a WinUI page gets PointerPressed / Moved / Released / Canceled /
// CaptureLost and PointerWheelChanged with a PointerDeviceType of Touch, Pen or Mouse. How each Mac input maps:
//
//   Mac (iPhone, iPad, Catalyst)                      Windows                         Here
//   ─────────────────────────────────────────────    ─────────────────────────────   ─────────────────────────────
//   a finger on the glass                             a Touch contact                 one finger (PointerId = touch)
//   Catalyst: a click / click-drag on the stage       a Mouse left button press/drag  one finger: the stage is a
//     (UIKit delivers it as one touch)                                                 relative trackpad on the Mac too
//   Apple Pencil (a touch)                            a Pen contact                   one finger
//   hold 550 ms then lift = right click               the same, any device            unchanged
//   (Catalyst: a secondary click reaches nothing)     Mouse right button / pen barrel Secondary: a right click at the
//                                                       button / pen tap with barrel    pointer, the Windows idiom (mask 4)
//   (none)                                            Mouse middle button             Middle: a middle click (mask 2)
//   hover (Catalyst: nothing tracks it)               Mouse / pen moving, no button   ignored: the pointer is relative
//   two-finger pinch                                  two Touch contacts              pinch (unchanged); a precision
//                                                                                       touchpad's pinch reaches a WinUI
//                                                                                       element as Ctrl+wheel, below
//   two fingers at fit, in control = wheel steps      two Touch contacts              unchanged (24 pt a step)
//   trackpad two-finger scroll (continuous pan)       precision touchpad wheel        Wheel, continuous: a step per
//                                                       (delta not a multiple of 120)   WheelNotch of travel
//   mouse wheel (discrete pan, a step per line)       mouse wheel, 120 a notch        Wheel, discrete: a step a notch
//   ⌘-scroll zooms the local view about the pointer  Ctrl+wheel (Windows' zoom)      Wheel with zoom: true
//   horizontal scroll (ignored: only y is read)       Shift+wheel / tilt wheel        ignored
//   VoiceOver custom actions                          UIA / Narrator actions          Act(ScreenStageAct)
//
// A contact that is not a finger by the table above never reaches ScreenGesture, so a right-button drag moves
// nothing. Covered (the window is not active: the task switcher must not show another computer's screen, D17), the
// viewer has already dropped the touches; nothing that arrives then is taken, as on the Mac where an inactive app
// gets no touches. Not in control, a finger still pans, pinches and double-taps the local view but nothing goes on
// the wire: ScreenStageState.Send checks Control, and ScreenSession.SendPointer checks CanSendInput.

namespace Hermes.Core.Screen;

/// The kind of device a WinUI pointer event came from (`PointerDeviceType`).
public enum ScreenPointerDevice { Touch, Pen, Mouse }

/// What a press means on the stage.
public enum ScreenPointerButton
{
    /// A finger: the trackpad (and, watching, the local view's pan, pinch and double tap).
    Primary,
    /// A right click at the pointer.
    Secondary,
    /// A middle click at the pointer.
    Middle,
    /// Nothing the stage takes (X buttons, an eraser's flip side with no contact).
    None,
}

/// The stage's accessibility actions (`accessibilityCustomActions`): in control the pointer's four, always the zoom.
public enum ScreenStageAct { Click, RightClick, ScrollUp, ScrollDown, ZoomIn, ZoomOut, Fit }

public static class ScreenPointerButtons
{
    /// What a WinUI press is, from its `PointerPointProperties`. Touch is always a finger. A pen is a finger unless its
    /// barrel button is held (Windows' pen right click); the eraser end is a finger too (VNC has no eraser). A mouse:
    /// left is the finger, right and middle are clicks; with several held the left wins, as it began the press.
    public static ScreenPointerButton From(ScreenPointerDevice device, bool left = false, bool right = false, bool middle = false,
                                           bool barrel = false) => device switch
    {
        ScreenPointerDevice.Touch => ScreenPointerButton.Primary,
        ScreenPointerDevice.Pen => barrel ? ScreenPointerButton.Secondary : ScreenPointerButton.Primary,
        _ when left => ScreenPointerButton.Primary,
        _ when right => ScreenPointerButton.Secondary,
        _ when middle => ScreenPointerButton.Middle,
        _ => ScreenPointerButton.None,
    };

    /// `MouseWheelDelta` of one mouse-wheel notch (WHEEL_DELTA).
    public const int WheelNotch = 120;

    /// A mouse turns its wheel in whole notches; a precision touchpad sends any amount. (A touchpad that happens to send
    /// exactly 120 reads as a notch: one step, which is what a notch's travel is worth either way.)
    public static bool Discrete(int delta) => delta != 0 && delta % WheelNotch == 0;
}

public sealed partial class ScreenStageState
{
    /// The gap after which a touchpad's next wheel event starts a new scroll (`pan.state == .began`): Windows sends no
    /// gesture phases with a wheel.
    public const double WheelGestureGap = 0.3;
    /// A wheel delta of one notch is one line (`wheelLine`, 10 pt) of a Mac's discrete scroll, for the ⌘-scroll zoom.
    public const double WheelPointsPerNotch = 10;

    private readonly ScreenGesture _gesture = new();
    private readonly List<(uint Id, ScreenPoint At)> _active = [];
    private readonly HashSet<uint> _fresh = [];
    private (uint Id, byte Mask)? _click;
    private IDisposable? _holdTimer;
    private ScreenSize _size;
    private ScreenView? _shaping;
    private double _wheelScrolled;
    private double _wheelAt = double.NegativeInfinity;

    /// The local view changed (`committed` false while fingers still shape it).
    public Action<ScreenView, bool>? OnView { get; set; }
    /// The hold armed: a tick for the finger (the viewer plays a selection haptic).
    public Action? OnHoldArmed { get; set; }
    /// A contact began (the person is using the picture).
    public Action? OnTouch { get; set; }
    /// The pointer ring shows (a finger is down in control) or goes.
    public Action<bool>? OnRing { get; set; }

    /// The view to draw: a pinch's while fingers shape it, else the gesture's.
    public ScreenView View => _shaping ?? _gesture.View;
    /// The row of the desktop last clicked, a fraction of its height (compact typing keeps it in sight).
    public double? TappedRow => _gesture.Tapped?.Fy;
    /// The pointer, as fractions of the desktop.
    public ScreenPointer Pointer => _gesture.Pointer;
    /// The left button is held down (a hold then move drags).
    public bool Dragging => _gesture.Pressed;
    public bool Ring { get; private set; }
    /// The stage's size in the page's units (DIPs); the page sets it on every layout (`layoutSubviews`).
    public ScreenSize Size => _size;
    /// Where the picture is drawn in the stage.
    public ScreenRect Drawn => ScreenViewMath.Drawn(_size, Aspect, View);
    /// Where the ring is drawn: the pointer on the picture.
    public ScreenPoint RingPoint => _gesture.Pointer.Point(Drawn);
    /// When the pending hold arms, on the `uptime` clock; null when none is pending.
    public double? HoldDeadline => _gesture.HoldDeadline;
    /// The contacts down on the stage now.
    public int Contacts => _active.Count;

    private ScreenGesture.Context Context => new(Control, _size, Aspect, Framebuffer);

    // Layout and view

    /// The stage changed size (`layoutSubviews`): re-clamp, keep the tapped row in sight.
    public void Layout(ScreenSize size)
    {
        _size = size;
        _gesture.Relayout(Context);
    }

    /// Sets the local view (Fit, compact typing). The page animates the picture to `Drawn` unless motion is reduced.
    public ScreenView SetView(ScreenView next)
    {
        _shaping = null;
        _gesture.SetView(next, Context);
        return _gesture.View;
    }

    /// Zooms by `factor` about the middle (Narrator, the = / - keys, the Zoom buttons). False without a picture.
    public bool ZoomBy(double factor)
    {
        if (Framebuffer.Width <= 0) return false;
        var next = ScreenViewMath.ZoomAbout(_gesture.View, factor, new ScreenPoint(_size.Width / 2, _size.Height / 2), _size.Width, _size.Height);
        SetView(next);
        OnView?.Invoke(_gesture.View, true);
        return true;
    }

    public bool FitView()
    {
        SetView(ScreenView.Fit);
        OnView?.Invoke(_gesture.View, true);
        return true;
    }

    /// The picture went (the stream closed with no last frame to keep).
    public void ClearPicture()
    {
        _picture = null;
        Framebuffer = (0, 0);
    }

    private void FramebufferResized()
    {
        _gesture.ClampPointer(Context);
        _gesture.Relayout(Context);
        SyncPointer();
    }

    // Pointer events (WinUI PointerPressed / PointerMoved / PointerReleased / PointerCanceled + PointerCaptureLost)

    /// A contact came down. Returns whether the stage took it (the page then captures the pointer).
    public bool Pressed(uint id, ScreenPointerButton button, ScreenPoint at)
    {
        if (Covered || Framebuffer.Width <= 0) return false;
        switch (button)
        {
            case ScreenPointerButton.Primary:
                if (_active.Any(a => a.Id == id)) return true;
                FlushMoves();
                _active.Add((id, at));
                OnTouch?.Invoke();
                Apply(_gesture.Began(Points(), _uptime(), Context));
                ArmHold();
                return true;
            case ScreenPointerButton.Secondary or ScreenPointerButton.Middle:
                // A click of its own at the pointer: only in control, and not in the middle of a finger's gesture.
                if (!Control || _active.Count > 0 || _click != null) return false;
                _click = (id, button == ScreenPointerButton.Secondary ? (byte)4 : (byte)2);
                OnTouch?.Invoke();
                return true;
            default:
                return false;
        }
    }

    /// A contact moved. A contact that is not down (a hovering mouse or pen) moves nothing.
    ///
    /// UIKit hands every finger's move of a frame over in one `touchesMoved`; WinUI raises PointerMoved once per
    /// contact. Fed one at a time, two fingers sliding up together would look, between their events, like a spread
    /// and turn a scroll into a zoom. So with two or more contacts down the moves are gathered until each contact has
    /// moved once (one UIKit event), or until a contact moves again before the others (they are holding still).
    public void Moved(uint id, ScreenPoint at)
    {
        var index = _active.FindIndex(a => a.Id == id);
        if (index < 0) return;
        if (_active.Count < 2)
        {
            _active[index] = (id, at);
            FeedMove();
            return;
        }
        if (_fresh.Contains(id)) FeedMove();
        _active[index] = (id, at);
        _fresh.Add(id);
        if (_active.All(a => _fresh.Contains(a.Id))) FeedMove();
    }

    private void FeedMove()
    {
        _fresh.Clear();
        Apply(_gesture.Moved(Points(), Context));
        ArmHold();
    }

    /// Moves gathered but not yet fed go in before a contact comes or goes.
    private void FlushMoves()
    {
        if (_fresh.Count > 0) FeedMove();
    }

    /// A contact lifted.
    public void Released(uint id)
    {
        if (_click is { } click && click.Id == id)
        {
            _click = null;
            if (Control && Framebuffer.Width > 0 && !Covered) Apply([new ScreenGesture.Action.Click(click.Mask)]);
            return;
        }
        if (!_active.Any(a => a.Id == id)) return;
        FlushMoves();
        _active.RemoveAll(a => a.Id == id);
        Apply(_gesture.Ended(_active.Count, _uptime(), Context));
        ArmHold();
    }

    /// The system took the contact (PointerCanceled, PointerCaptureLost): end a drag where it is, never click.
    public void Canceled(uint id)
    {
        if (_click is { } click && click.Id == id) { _click = null; return; }
        if (!_active.Any(a => a.Id == id)) return;
        _active.Clear();
        _fresh.Clear();
        _shaping = null;
        Apply(_gesture.Cancelled());
        ArmHold();
    }

    // The wheel (PointerWheelChanged)

    /// One wheel event: `delta` as WinUI gives it (positive: the wheel turned away from the person, content comes
    /// down); `zoom` when Ctrl is held; `at` where the pointer is over the stage; `discrete` null to tell a mouse's
    /// notches from a touchpad by the delta.
    public void Wheel(int delta, ScreenPoint at, bool zoom = false, bool horizontal = false, bool? discrete = null)
    {
        if (Covered || horizontal || delta == 0) return;
        var notched = discrete ?? ScreenPointerButtons.Discrete(delta);
        var now = _uptime();
        var began = now - _wheelAt > WheelGestureGap;
        _wheelAt = now;
        if (began) { _wheelScrolled = 0; OnTouch?.Invoke(); }
        // Ctrl-wheel zooms about the pointer, watching or in control (the Mac's ⌘-scroll; a mouse has no pinch, and a
        // precision touchpad's pinch arrives as this). Windows gives a wheel no end, so every step is committed.
        if (zoom)
        {
            if (Framebuffer.Width <= 0) return;
            var factor = ScreenZoomSteps.ScrollFactor(delta / (double)ScreenPointerButtons.WheelNotch * WheelPointsPerNotch, notched);
            SetView(ScreenViewMath.ZoomAbout(_gesture.View, factor, at, _size.Width, _size.Height));
            OnView?.Invoke(_gesture.View, true);
            return;
        }
        if (!Control || Framebuffer.Width <= 0) return;
        var down = delta < 0;
        if (notched)
        {
            // A mouse: one step a notch, as any remote-screen app does.
            var notches = Math.Max(1, (int)Math.Round(Math.Abs(delta) / (double)ScreenPointerButtons.WheelNotch, MidpointRounding.AwayFromZero));
            Apply(Enumerable.Range(0, notches).Select(_ => (ScreenGesture.Action)new ScreenGesture.Action.Wheel(down)).ToList());
            return;
        }
        // A touchpad: a step every notch's worth of travel, the remainder carried (two fingers' 24 pt on the phone).
        _wheelScrolled += -delta;
        var steps = new List<ScreenGesture.Action>();
        while (Math.Abs(_wheelScrolled) >= ScreenPointerButtons.WheelNotch)
        {
            var stepDown = _wheelScrolled > 0;
            steps.Add(new ScreenGesture.Action.Wheel(stepDown));
            _wheelScrolled -= (stepDown ? 1 : -1) * ScreenPointerButtons.WheelNotch;
        }
        Apply(steps);
    }

    // Accessibility (§6.3)

    /// The actions Narrator offers now: in control Click, Right-click, Scroll up, Scroll down, then the zoom three.
    public IReadOnlyList<ScreenStageAct> Acts =>
        Control
            ? [ScreenStageAct.Click, ScreenStageAct.RightClick, ScreenStageAct.ScrollUp, ScreenStageAct.ScrollDown,
               ScreenStageAct.ZoomIn, ScreenStageAct.ZoomOut, ScreenStageAct.Fit]
            : [ScreenStageAct.ZoomIn, ScreenStageAct.ZoomOut, ScreenStageAct.Fit];

    public static string ActName(ScreenStageAct act) => act switch
    {
        ScreenStageAct.Click => "Click",
        ScreenStageAct.RightClick => "Right-click",
        ScreenStageAct.ScrollUp => "Scroll up",
        ScreenStageAct.ScrollDown => "Scroll down",
        ScreenStageAct.ZoomIn => "Zoom in",
        ScreenStageAct.ZoomOut => "Zoom out",
        _ => "Fit screen",
    };

    /// One accessibility action; false when it does nothing now.
    public bool Act(ScreenStageAct act)
    {
        switch (act)
        {
            case ScreenStageAct.ZoomIn: return ZoomBy(ScreenZoomSteps.StepFactor);
            case ScreenStageAct.ZoomOut: return ZoomBy(1 / ScreenZoomSteps.StepFactor);
            case ScreenStageAct.Fit: return FitView();
        }
        if (!Control || Framebuffer.Width <= 0) return false;
        Apply([act switch
        {
            ScreenStageAct.Click => new ScreenGesture.Action.Click(1),
            ScreenStageAct.RightClick => new ScreenGesture.Action.Click(4),
            ScreenStageAct.ScrollUp => new ScreenGesture.Action.Wheel(false),
            _ => new ScreenGesture.Action.Wheel(true),
        }]);
        return true;
    }

    // The gesture's actions → the wire

    private List<ScreenPoint> Points() => _active.Select(a => a.At).ToList();

    private void SyncPointer()
    {
        if (Framebuffer.Width > 0) PointerPixel = _gesture.Pointer.Pixel(Framebuffer);
    }

    private void Apply(IReadOnlyList<ScreenGesture.Action> actions)
    {
        foreach (var action in actions)
        {
            switch (action)
            {
                case ScreenGesture.Action.PointerMoved:
                    SyncPointer();
                    ScheduleMove();
                    break;
                case ScreenGesture.Action.Buttons(var mask):
                    // The last position, then the new buttons there.
                    SyncPointer();
                    SendPosition();
                    Held = mask;
                    SendPosition();
                    break;
                case ScreenGesture.Action.Click(var mask):
                    SyncPointer();
                    SendPosition();
                    Send((byte)(Held | mask));
                    Send(Held);
                    break;
                case ScreenGesture.Action.Wheel(var down):
                    // RFB buttons 4 and 5 (masks 8 and 16) are the wheel: a press and a release a step.
                    SyncPointer();
                    _movePending = false;
                    Send((byte)(Held | (down ? 16 : 8)));
                    Send(Held);
                    break;
                case ScreenGesture.Action.View(var view, var committed):
                    // The Mac's `apply` places and reports `gesture.view`, which a pinch only changes when it ends, so
                    // read as written its picture holds still under the fingers. Here a pinch's view shows as it is
                    // shaped (the action's own view), and the committed one replaces it.
                    _shaping = committed ? null : view;
                    OnView?.Invoke(committed ? _gesture.View : view, committed);
                    break;
                case ScreenGesture.Action.HoldArmed:
                    OnHoldArmed?.Invoke();
                    break;
                case ScreenGesture.Action.Touching(var on):
                    Ring = on;
                    OnRing?.Invoke(on);
                    break;
            }
        }
    }

    private void ArmHold()
    {
        _holdTimer?.Dispose();
        _holdTimer = null;
        if (_timers == null || _gesture.HoldDeadline is not { } deadline) return;
        var wait = Math.Max(0, deadline - _uptime());
        _holdTimer = _timers.Schedule(TimeSpan.FromSeconds(wait), false, () =>
        {
            _holdTimer = null;
            // A timer may fire a hair early: the hold is due whenever its own timer says so.
            var now = Math.Max(_uptime(), _gesture.HoldDeadline ?? 0);
            Apply(_gesture.HoldFired(now));
        });
    }

    /// DropTouches' input half: forget every contact and the pending hold and click, let go of a drag, hide the ring.
    private void DropInput()
    {
        _active.Clear();
        _fresh.Clear();
        _shaping = null;
        _click = null;
        _holdTimer?.Dispose();
        _holdTimer = null;
        _gesture.Drop();
        if (Ring) { Ring = false; OnRing?.Invoke(false); }
    }
}

/// The key field's rules (ScreenKeyField): what a Windows keyboard sends to the bot's screen. Windows is a desktop, so
/// this is the Mac's (Catalyst) field, which reads each press as a VNC client does, not the iPhone's text field: a
/// named key by its virtual key, a key with Ctrl, Alt or the Windows key as a chord, any other key as the text it
/// types. Nothing typed is kept or logged.
///
/// The page feeds it KeyDown (`VirtualKey`, the modifiers held, `KeyStatus.WasKeyDown`) and CharacterReceived, and
/// marks a KeyDown handled when this returns true (so Tab and the arrows don't move focus out of the stage). It takes
/// input only while the page says it has focus. Differences from the Mac, each a Windows fact:
/// - Windows repeats a held key itself (KeyDown with WasKeyDown, CharacterReceived again), so there is no repeat timer
///   here; as on the Mac, named keys and text repeat and a held chord does not.
/// - AltGr is Ctrl+Alt on Windows. With `altGr` (the right Alt down) those two are not a chord: the layout's
///   character (@ on a German keyboard) arrives as text. The left Alt still makes chords.
/// - CharacterReceived comes one UTF-16 unit at a time: a surrogate pair (an emoji) is joined before it is sent.
/// - The Windows key (Meta) mostly goes to the shell (Win+L, Win+D never reach an app); what does reach is sent.
public sealed class ScreenKeyInput
{
    /// Text the keyboard typed.
    public Action<string>? OnText { get; set; }
    /// A named key, with the modifiers held with it.
    public Action<ScreenKeys.Named, IReadOnlySet<ScreenKeys.Modifier>>? OnKey { get; set; }
    /// A key pressed with Ctrl, Alt or the Windows key: its unshifted character, lower case.
    public Action<string, IReadOnlySet<ScreenKeys.Modifier>>? OnChord { get; set; }
    public Action<bool>? OnFocusChange { get; set; }

    private char? _high;

    public bool Focused { get; private set; }

    /// The viewer's key field: text, named keys and chords go to the viewer (which sends only in control).
    public static ScreenKeyInput For(ScreenViewerController viewer) => new()
    {
        OnText = viewer.KeyText,
        OnKey = (key, mods) => viewer.KeyPress(key.Keysym(), mods),
        OnChord = viewer.Chord,
        OnFocusChange = viewer.KeyboardFocusChanged,
    };

    /// The page's key target gained or lost focus (`textFieldDidBeginEditing` / `becomeFirstResponder`).
    public void FocusChanged(bool on)
    {
        _high = null;
        if (on == Focused) return;
        Focused = on;
        OnFocusChange?.Invoke(on);
    }

    // Windows.System.VirtualKey values.
    private static readonly Dictionary<int, ScreenKeys.Named> NamedKeys = new()
    {
        [0x25] = ScreenKeys.Named.Left, [0x27] = ScreenKeys.Named.Right, [0x26] = ScreenKeys.Named.Up, [0x28] = ScreenKeys.Named.Down,
        [0x1B] = ScreenKeys.Named.Escape, [0x09] = ScreenKeys.Named.Tab, [0x2E] = ScreenKeys.Named.Delete, [0x08] = ScreenKeys.Named.Backspace,
        [0x0D] = ScreenKeys.Named.Enter,   // the keypad's Enter is the same virtual key on Windows
        [0x24] = ScreenKeys.Named.Home, [0x23] = ScreenKeys.Named.End, [0x21] = ScreenKeys.Named.PageUp, [0x22] = ScreenKeys.Named.PageDown,
        [0x70] = ScreenKeys.Named.F1, [0x71] = ScreenKeys.Named.F2, [0x72] = ScreenKeys.Named.F3, [0x73] = ScreenKeys.Named.F4,
        [0x74] = ScreenKeys.Named.F5, [0x75] = ScreenKeys.Named.F6, [0x76] = ScreenKeys.Named.F7, [0x77] = ScreenKeys.Named.F8,
        [0x78] = ScreenKeys.Named.F9, [0x79] = ScreenKeys.Named.F10, [0x7A] = ScreenKeys.Named.F11, [0x7B] = ScreenKeys.Named.F12,
    };

    /// The named key a virtual key is, if any.
    public static ScreenKeys.Named? Named(int virtualKey) => NamedKeys.TryGetValue(virtualKey, out var named) ? named : null;

    /// The modifiers a chord carries: AltGr's Ctrl+Alt is the layout's, not the person's.
    public static HashSet<ScreenKeys.Modifier> Mods(bool shift = false, bool ctrl = false, bool alt = false, bool meta = false, bool altGr = false)
    {
        var out_ = new HashSet<ScreenKeys.Modifier>();
        if (shift) out_.Add(ScreenKeys.Modifier.Shift);
        if (ctrl && !altGr) out_.Add(ScreenKeys.Modifier.Ctrl);
        if (alt && !altGr) out_.Add(ScreenKeys.Modifier.Alt);
        if (meta) out_.Add(ScreenKeys.Modifier.Meta);
        return out_;
    }

    private static bool Chording(IReadOnlySet<ScreenKeys.Modifier> mods) =>
        mods.Contains(ScreenKeys.Modifier.Ctrl) || mods.Contains(ScreenKeys.Modifier.Alt) || mods.Contains(ScreenKeys.Modifier.Meta);

    /// Not a control character, nor one of the private-use ones the Mac's function keys carry.
    public static bool Printable(int scalar) => scalar >= 0x20 && scalar != 0x7F && !(scalar is >= 0xF700 and <= 0xF8FF);

    /// The unshifted character of a virtual key the layout cannot change: A–Z, 0–9 (top row and keypad), Space.
    public static string? Unmodified(int virtualKey) => virtualKey switch
    {
        >= 0x41 and <= 0x5A => ((char)('a' + virtualKey - 0x41)).ToString(),
        >= 0x30 and <= 0x39 => ((char)virtualKey).ToString(),
        >= 0x60 and <= 0x69 => ((char)('0' + virtualKey - 0x60)).ToString(),
        0x20 => " ",
        _ => null,
    };

    /// KeyDown. `character`: the key's unshifted character from the page's layout (punctuation keys: Ctrl+/ is "/"),
    /// else A–Z, 0–9 and Space are known. Returns whether it was taken (the page sets Handled).
    public bool KeyDown(int virtualKey, IReadOnlySet<ScreenKeys.Modifier> mods, bool repeat = false, string? character = null)
    {
        if (!Focused) return false;
        if (Named(virtualKey) is { } named)
        {
            _high = null;
            OnKey?.Invoke(named, mods);
            return true;
        }
        if (!Chording(mods)) return false;   // its text comes as CharacterReceived (a modifier alone: nothing)
        var text = character ?? Unmodified(virtualKey);
        if (text is not { Length: > 0 } || !IsOneScalar(text, out var scalar) || !Printable(scalar)) return false;
        if (!repeat) OnChord?.Invoke(text.ToLowerInvariant(), mods);
        return true;   // a held chord does not repeat, and its character is not typed as well
    }

    /// CharacterReceived: one UTF-16 unit. Text only with no Ctrl, Alt or Windows key held (a chord's control
    /// character, Ctrl+A's 0x01, is never text); Enter's \r, Backspace's \b, Tab and Escape are named keys already.
    public void CharacterReceived(char unit, IReadOnlySet<ScreenKeys.Modifier> mods)
    {
        if (!Focused || Chording(mods)) { _high = null; return; }
        if (char.IsHighSurrogate(unit)) { _high = unit; return; }
        string text;
        if (char.IsLowSurrogate(unit))
        {
            if (_high is not { } high) return;   // half a pair: nothing
            text = new string([high, unit]);
        }
        else text = unit.ToString();
        _high = null;
        if (!Printable(char.ConvertToUtf32(text, 0))) return;
        OnText?.Invoke(text);
    }

    private static bool IsOneScalar(string text, out int scalar)
    {
        scalar = 0;
        if (text.Length == 1 && !char.IsSurrogate(text[0])) { scalar = text[0]; return true; }
        if (text.Length == 2 && char.IsSurrogatePair(text[0], text[1])) { scalar = char.ConvertToUtf32(text[0], text[1]); return true; }
        return false;
    }
}
