// [WIN-SCREEN-WIRE-KEYS-MATH] The Screen's view math and touch rules, the C# twin of the Mac's
// HermesKit/Screen/ScreenViewMath.swift at 93f984bb1 (docs/spec/3x-screen.md §5.5, §5.7), itself a port of the web
// app's src/bot-screen-phone.tsx: the zoomed view, the relative-trackpad pointer, and the touch state machine. Pure
// values, so every rule is tested without a view. CGFloat is double; CGPoint / CGSize / CGRect are ScreenPoint /
// ScreenSize / ScreenRect (Hermes.Core has no UI framework). Times are seconds (TimeInterval).

namespace Hermes.Core.Screen;

public readonly record struct ScreenPoint(double X, double Y)
{
    public static readonly ScreenPoint Zero = new(0, 0);
}

public readonly record struct ScreenSize(double Width, double Height)
{
    public static readonly ScreenSize Zero = new(0, 0);
}

public readonly record struct ScreenRect(double X, double Y, double Width, double Height)
{
    public static readonly ScreenRect Zero = new(0, 0, 0, 0);
    public double MinX => Math.Min(X, X + Width);
    public double MinY => Math.Min(Y, Y + Height);
    public double MaxX => Math.Max(X, X + Width);
    public double MaxY => Math.Max(Y, Y + Height);
    public ScreenSize Size => new(Width, Height);
}

/// A zoomed view of the stage: the stage's content scaled by `Zoom` about its top-left, then moved by (X, Y).
public sealed record ScreenView(double Zoom = 1, double X = 0, double Y = 0)
{
    public static readonly ScreenView Fit = new();
}

public static class ScreenViewMath
{
    public const double TapSlop = 10;
    public const double LongPress = 0.55;
    public const double DoubleTap = 0.32;
    public const double DoubleTapReach = 30;
    public const double MaxZoom = 5;
    public const double DoubleTapZoom = 2.5;
    public const double WheelTravel = 24;
    public const double KeepClear = 40;

    // Swift's min / max (no NaN special case beyond what the comparisons give).
    private static double Min(double a, double b) => b < a ? b : a;
    private static double Max(double a, double b) => b > a ? b : a;

    /// Keep a zoomed view covering its viewport: offsets stay within [size − size·zoom, 0].
    public static ScreenView ClampView(ScreenView view, double width, double height)
    {
        var zoom = Min(MaxZoom, Max(1, view.Zoom));
        double Clamp(double value, double size) => Min(0, Max(size - size * zoom, value));
        return new ScreenView(zoom, Clamp(view.X, width), Clamp(view.Y, height));
    }

    /// Zoom by `factor` about the viewport point `at`, keeping the content under it in place.
    public static ScreenView ZoomAbout(ScreenView view, double factor, ScreenPoint at, double width, double height)
    {
        var zoom = Min(MaxZoom, Max(1, view.Zoom * factor));
        var ratio = zoom / view.Zoom;
        return ClampView(new ScreenView(zoom, at.X - (at.X - view.X) * ratio, at.Y - (at.Y - view.Y) * ratio), width, height);
    }

    /// Clamp to the desktop as drawn (it keeps the framebuffer's `aspect`, width ÷ height) rather than to the stage:
    /// panning never reaches the letterbox bands, and a desktop narrower or shorter than the view stays centred.
    public static ScreenView ClampToDesktop(ScreenView view, double width, double height, double aspect)
    {
        var @base = ClampView(view, width, height);
        if (!(aspect > 0 && width > 0 && height > 0)) return @base;
        var zoom = @base.Zoom;
        double drawnWidth = Min(width, height * aspect) * zoom, drawnHeight = Min(height, width / aspect) * zoom;
        var left = (width * zoom - drawnWidth) / 2;
        var x = drawnWidth >= width ? Min(-left, Max(width - left - drawnWidth, view.X)) : (width - drawnWidth) / 2 - left;
        var y = drawnHeight >= height ? Min(0, Max(height - drawnHeight, view.Y)) : (height - drawnHeight) / 2;
        return new ScreenView(zoom, double.IsFinite(x) ? x : 0, double.IsFinite(y) ? y : 0);
    }

    /// The desktop's size at fit (zoom 1) inside a stage.
    public static ScreenSize Fitted(double width, double height, double aspect) =>
        aspect > 0 && width > 0 && height > 0 ? new ScreenSize(Min(width, height * aspect), Min(height, width / aspect)) : ScreenSize.Zero;

    /// Where the desktop is drawn in the stage for a view (the picture layer's frame).
    public static ScreenRect Drawn(ScreenSize stage, double aspect, ScreenView view)
    {
        var fit = Fitted(stage.Width, stage.Height, aspect);
        if (!(fit.Width > 0)) return ScreenRect.Zero;
        var clamped = ClampToDesktop(view, stage.Width, stage.Height, aspect);
        return new ScreenRect(clamped.X + clamped.Zoom * (stage.Width - fit.Width) / 2, clamped.Y,
                              fit.Width * clamped.Zoom, fit.Height * clamped.Zoom);
    }

    /// Double-tap zoom: the level at which the fitted desktop fills the viewport, or 2.5× when it nearly does already.
    public static double FillZoom(double width, double height, ScreenSize? fitted)
    {
        if (fitted is not { Width: > 0, Height: > 0 } fit) return DoubleTapZoom;
        var fill = Max(width / fit.Width, height / fit.Height);
        return fill > 1.15 ? Min(MaxZoom, fill) : DoubleTapZoom;
    }

    /// Typing with the keyboard up on a short, wide stage (a phone or small tablet on its side).
    public static bool CompactTyping(bool typing, ScreenSize? visible) =>
        typing && visible is { Width: > 0, Height: > 0 } v && v.Height < 500 && v.Width > v.Height;

    /// The view that fills the stage's width with a desktop it letterboxes by height, the row last tapped (`fy`, a
    /// fraction of the desktop's height) in the middle; null when the desktop already spans the width.
    public static ScreenView? FillWidthView(double width, double height, double aspect, double? fy)
    {
        if (!(aspect > 0 && width > 0 && height > 0)) return null;
        var zoom = Min(MaxZoom, width / Min(width, height * aspect));
        if (!(zoom >= 1.05)) return null;
        var drawnHeight = Min(height, width / aspect) * zoom;
        return ClampToDesktop(new ScreenView(zoom, 0, height / 2 - (fy ?? 0.5) * drawnHeight), width, height, aspect);
    }

    /// Pan a zoomed view so a point (stage-local y) stays `margin` inside its bottom and top edges.
    public static ScreenView KeepVisible(ScreenView view, double pointY, double width, double height, double margin = KeepClear)
    {
        var room = Min(margin, height / 2);
        var shift = pointY > height - room ? height - room - pointY : (pointY < room ? room - pointY : 0);
        if (shift == 0) return view;
        return ClampView(view with { Y = view.Y + shift }, width, height);
    }

    /// The rotate hint shows once, on a phone held upright.
    public static bool WantsRotateHint(bool seen, bool portrait, bool phone) => phone && portrait && !seen;
}

/// The pointer of a controlled screen, kept as fractions of the desktop so zoom, rotation and letterboxing never move
/// it. It starts at the centre: the stream has no cursor-position messages.
public record struct ScreenPointer
{
    public ScreenPointer() { }

    public ScreenPointer(double x, double y)
    {
        X = x;
        Y = y;
    }

    public double X { get; set; } = 0.5;
    public double Y { get; set; } = 0.5;

    /// Moves by a finger's travel over a desktop drawn `drawn` points big, clamped to [0, 1 − 1/size].
    public void Move(double dx, double dy, ScreenSize drawn, (int Width, int Height) framebuffer)
    {
        if (!(drawn.Width > 0 && drawn.Height > 0)) return;
        var maxX = framebuffer.Width > 0 ? 1 - 1.0 / framebuffer.Width : 1 - 1 / drawn.Width;
        var maxY = framebuffer.Height > 0 ? 1 - 1.0 / framebuffer.Height : 1 - 1 / drawn.Height;
        X = Math.Max(0, Math.Min(maxX, X + dx / drawn.Width));
        Y = Math.Max(0, Math.Min(maxY, Y + dy / drawn.Height));
    }

    /// The framebuffer pixel the pointer is on.
    public readonly (int X, int Y) Pixel((int Width, int Height) framebuffer) =>
        (Math.Max(0, Math.Min(framebuffer.Width - 1, (int)Math.Round(X * framebuffer.Width, MidpointRounding.AwayFromZero))),
         Math.Max(0, Math.Min(framebuffer.Height - 1, (int)Math.Round(Y * framebuffer.Height, MidpointRounding.AwayFromZero))));

    /// Where the pointer is in the stage, for a desktop drawn at `rect`.
    public readonly ScreenPoint Point(ScreenRect rect) => new(rect.MinX + X * rect.Width, rect.MinY + Y * rect.Height);
}

/// The touch rules as a state machine: feed it touches (stage-local points), it says what to do. One finger in control
/// mode is a relative trackpad (move, tap = click, hold = right click, hold then move = drag); two fingers zoom the
/// local view or, at fit size in control, scroll the remote screen; watching, one finger pans a zoomed view and a double
/// tap toggles fit and fill.
public sealed class ScreenGesture
{
    public abstract record Action
    {
        private Action() { }

        /// The pointer moved (no button change): send its position, coalesced to one per display frame.
        public sealed record PointerMoved : Action;
        /// Send the pointer's position now, then this button mask (1 left, 4 right; 0 releases).
        public sealed record Buttons(byte Mask) : Action;
        /// A click: position, mask down, mask up.
        public sealed record Click(byte Mask) : Action;
        /// One wheel step (`Down`: content moves up, as when fingers move up).
        public sealed record Wheel(bool Down) : Action;
        /// Show this view; `Committed` false while fingers are still shaping it.
        public sealed record View(ScreenView Value, bool Committed) : Action;
        /// The hold armed (550 ms without moving): a tick for the finger.
        public sealed record HoldArmed : Action;
        /// A click landed at this fraction of the desktop.
        public sealed record Tapped(double Fx, double Fy) : Action;
        /// A finger is down in control mode (the pointer ring shows) or lifted.
        public sealed record Touching(bool Down) : Action;
    }

    /// What the stage knows when a touch arrives.
    public readonly record struct Context(bool Control, ScreenSize Stage, double Aspect, (int Width, int Height) Framebuffer);

    private enum PinchMode { Undecided, Zoom, Scroll }

    private sealed class Pinch(double distance, ScreenPoint mid, ScreenView @base)
    {
        public double Distance = distance;
        public ScreenPoint Mid = mid;
        public ScreenView Base = @base;
        public ScreenView Next = @base;
        public PinchMode Mode = PinchMode.Undecided;
        public double Scrolled;
    }

    private ScreenPointer _pointer = new();
    private ScreenPoint? _start;
    private ScreenPoint? _last;
    private bool _didMove;
    private bool _consumed;
    private bool _armed;
    private Pinch? _pinch;
    private (double At, ScreenPoint Point)? _lastTap;

    public ScreenView View { get; private set; } = ScreenView.Fit;
    public ScreenPointer Pointer => _pointer;
    /// The left button is held down (a drag).
    public bool Pressed { get; private set; }
    /// When a still finger's hold arms; null when none is pending.
    public double? HoldDeadline { get; private set; }
    /// Where the last control tap landed, as fractions of the desktop.
    public (double Fx, double Fy)? Tapped { get; private set; }

    private static double Hypot(double x, double y) => double.Hypot(x, y);

    // View changes from outside

    public void SetView(ScreenView next, Context context) =>
        View = ScreenViewMath.ClampToDesktop(next, context.Stage.Width, context.Stage.Height, context.Aspect);

    /// The stage changed size (rotation, keyboard): re-clamp, and keep the last tapped row clear of the edges.
    public void Relayout(Context context)
    {
        var next = ScreenViewMath.ClampToDesktop(View, context.Stage.Width, context.Stage.Height, context.Aspect);
        if (next.Zoom > 1 && Tapped is { } tapped)
        {
            var rect = ScreenViewMath.Drawn(context.Stage, context.Aspect, next);
            var pointY = rect.MinY + tapped.Fy * rect.Height;
            next = ScreenViewMath.ClampToDesktop(ScreenViewMath.KeepVisible(next, pointY, context.Stage.Width, context.Stage.Height),
                                                 context.Stage.Width, context.Stage.Height, context.Aspect);
        }
        View = next;
    }

    public void ResetPointer() => _pointer = new ScreenPointer();

    /// The framebuffer changed size: the pointer stays inside the new desktop.
    public void ClampPointer(Context context) => _pointer.Move(0, 0, new ScreenSize(1, 1), context.Framebuffer);

    // Touches

    public List<Action> Began(IReadOnlyList<ScreenPoint> touches, double now, Context context)
    {
        var out_ = new List<Action>();
        if (touches.Count >= 2)
        {
            HoldDeadline = null;
            _armed = false;
            // A second finger ends a drag where it is.
            if (Pressed) { Pressed = false; out_.Add(new Action.Buttons(0)); }
            ScreenPoint a = touches[0], b = touches[1];
            _pinch = new Pinch(Math.Max(1, Hypot(a.X - b.X, a.Y - b.Y)), new ScreenPoint((a.X + b.X) / 2, (a.Y + b.Y) / 2), View);
            _consumed = true;
            return out_;
        }
        if (touches.Count == 0) return out_;
        var touch = touches[0];
        _start = touch;
        _last = touch;
        _didMove = false;
        _consumed = false;
        _armed = false;
        if (context.Control)
        {
            HoldDeadline = now + ScreenViewMath.LongPress;
            out_.Add(new Action.Touching(true));
        }
        return out_;
    }

    /// The hold timer: call when `HoldDeadline` passes.
    public List<Action> HoldFired(double now)
    {
        if (HoldDeadline is not { } deadline || now < deadline) return [];
        HoldDeadline = null;
        if (_didMove || _start == null || _consumed) return [];
        _armed = true;
        return [new Action.HoldArmed()];
    }

    public List<Action> Moved(IReadOnlyList<ScreenPoint> touches, Context context)
    {
        double width = context.Stage.Width, height = context.Stage.Height;
        if (_pinch is { } active && touches.Count >= 2)
        {
            ScreenPoint a = touches[0], b = touches[1];
            var distance = Math.Max(1, Hypot(a.X - b.X, a.Y - b.Y));
            var mid = new ScreenPoint((a.X + b.X) / 2, (a.Y + b.Y) / 2);
            var factor = distance / active.Distance;
            if (active.Mode == PinchMode.Undecided)
            {
                // At fit size in control a steady two-finger drag scrolls the remote screen; any real spread or
                // squeeze is a local zoom.
                if (Math.Abs(factor - 1) > 0.08) active.Mode = PinchMode.Zoom;
                else if (context.Control && active.Base.Zoom == 1 && Math.Abs(mid.Y - active.Mid.Y) > ScreenViewMath.TapSlop) active.Mode = PinchMode.Scroll;
            }
            var scrolled = new List<Action>();
            if (active.Mode == PinchMode.Scroll)
            {
                active.Scrolled += active.Mid.Y - mid.Y;
                active.Mid = mid;
                while (Math.Abs(active.Scrolled) >= ScreenViewMath.WheelTravel)
                {
                    var down = active.Scrolled > 0;
                    scrolled.Add(new Action.Wheel(down));
                    active.Scrolled -= (down ? 1 : -1) * ScreenViewMath.WheelTravel;
                }
                return scrolled;
            }
            var zoomed = ScreenViewMath.ZoomAbout(active.Base, factor, active.Mid, width, height);
            active.Next = ScreenViewMath.ClampToDesktop(new ScreenView(zoomed.Zoom, zoomed.X + (mid.X - active.Mid.X), zoomed.Y + (mid.Y - active.Mid.Y)),
                                                        width, height, context.Aspect);
            return [new Action.View(active.Next, false)];
        }
        if (_start is not { } start || _last is not { } last || _consumed || _pinch != null || touches.Count == 0) return [];
        var at = touches[0];
        if (!_didMove && Hypot(at.X - start.X, at.Y - start.Y) < ScreenViewMath.TapSlop) return [];
        var out_ = new List<Action>();
        if (!_didMove)
        {
            _didMove = true;
            HoldDeadline = null;
        }
        if (context.Control)
        {
            if (_armed && !Pressed)
            {
                Pressed = true;
                out_.Add(new Action.Buttons(1));                 // the drag starts where the pointer is
            }
            var rect = ScreenViewMath.Drawn(context.Stage, context.Aspect, View);
            _pointer.Move(at.X - last.X, at.Y - last.Y, rect.Size, context.Framebuffer);
            out_.Add(new Action.PointerMoved());
        }
        else if (View.Zoom > 1)
        {
            View = ScreenViewMath.ClampToDesktop(new ScreenView(View.Zoom, View.X + at.X - last.X, View.Y + at.Y - last.Y), width, height, context.Aspect);
            out_.Add(new Action.View(View, true));
        }
        _last = at;
        return out_;
    }

    /// `remaining`: how many fingers are still down.
    public List<Action> Ended(int remaining, double now, Context context)
    {
        var out_ = new List<Action>();
        if (_pinch is { } active)
        {
            if (remaining < 2)
            {
                if (active.Mode != PinchMode.Scroll)
                {
                    View = active.Next;
                    out_.Add(new Action.View(View, true));
                }
                _pinch = null;
            }
            if (remaining == 0) { Reset(); out_.Add(new Action.Touching(false)); }
            return out_;
        }
        if (remaining != 0) return out_;
        HoldDeadline = null;
        try
        {
            if (Pressed)
            {
                Pressed = false;
                Tapped = (_pointer.X, _pointer.Y);
                return [new Action.Buttons(0), new Action.Tapped(_pointer.X, _pointer.Y), new Action.Touching(false)];
            }
            if (!_consumed && !_didMove && _start is { } start)
            {
                if (context.Control)
                {
                    Tapped = (_pointer.X, _pointer.Y);
                    out_.Add(new Action.Click((byte)(_armed ? 4 : 1)));
                    out_.Add(new Action.Tapped(_pointer.X, _pointer.Y));
                }
                else if (_lastTap is { } earlier && now - earlier.At < ScreenViewMath.DoubleTap
                         && Hypot(start.X - earlier.Point.X, start.Y - earlier.Point.Y) < ScreenViewMath.DoubleTapReach)
                {
                    double width = context.Stage.Width, height = context.Stage.Height;
                    if (View.Zoom > 1)
                        View = ScreenViewMath.ClampToDesktop(ScreenView.Fit, width, height, context.Aspect);
                    else
                    {
                        var fit = ScreenViewMath.Fitted(width, height, context.Aspect);
                        var zoomed = ScreenViewMath.ZoomAbout(View, ScreenViewMath.FillZoom(width, height, fit), start, width, height);
                        View = ScreenViewMath.ClampToDesktop(zoomed, width, height, context.Aspect);
                    }
                    _lastTap = null;
                    out_.Add(new Action.View(View, true));
                }
                else
                {
                    _lastTap = (now, start);
                }
            }
            out_.Add(new Action.Touching(false));
            return out_;
        }
        finally
        {
            Reset();
        }
    }

    /// An OS gesture or interruption cancelled the touch: end any drag where it is, never click.
    public List<Action> Cancelled()
    {
        var out_ = new List<Action>();
        if (Pressed) { Pressed = false; out_.Add(new Action.Buttons(0)); }
        if (_pinch is { } active && active.Mode != PinchMode.Scroll) out_.Add(new Action.View(View, true));
        _pinch = null;
        HoldDeadline = null;
        Reset();
        out_.Add(new Action.Touching(false));
        return out_;
    }

    /// Control ended or the stream closed: forget any touch in flight. Returns whether a button was down (the caller
    /// releases it on the wire, DECISION D14).
    public bool Drop()
    {
        var was = Pressed;
        Pressed = false;
        _pinch = null;
        HoldDeadline = null;
        Reset();
        return was;
    }

    private void Reset()
    {
        _start = null;
        _last = null;
        _didMove = false;
        _consumed = false;
        _armed = false;
    }
}
