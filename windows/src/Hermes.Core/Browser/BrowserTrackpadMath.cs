// The browser viewer's touch & pointer geometry and gesture state machine, C# twin of
// HermesKit/Browser/BrowserTrackpadMath.swift and the non-drawing half of App/Browser/BrowserStageView.swift.
// Pure: the WinUI stage view feeds pointer/touch/wheel events in, and unit tests drive it directly without a window.

namespace Hermes.Core.Browser;

public readonly record struct BrowserPoint(double X, double Y)
{
    public static readonly BrowserPoint Zero = new(0, 0);
}

public readonly record struct BrowserSize(double Width, double Height)
{
    public static readonly BrowserSize Zero = new(0, 0);
}

public readonly record struct BrowserRect(double X, double Y, double Width, double Height)
{
    public static readonly BrowserRect Zero = new(0, 0, 0, 0);
}

public readonly record struct BrowserVector(double Dx, double Dy)
{
    public static readonly BrowserVector Zero = new(0, 0);
}

/// The drawn page: `Zoom` over its fitted size, its top-left at `X`, `Y` in the stage.
public readonly record struct BrowserStageViewRect(double Zoom = 1, double X = 0, double Y = 0, double Width = 0, double Height = 0)
{
    public BrowserSize DrawnSize => new(Width * Zoom, Height * Zoom);
    public BrowserRect Frame => new(X, Y, Width * Zoom, Height * Zoom);
}

public static class BrowserTrackpadMath
{
    public const double TapSlop = 8;
    /// A hardware pointer (mouse/touchpad) is steadier than a fingertip, so drags start sooner.
    public const double DirectDragSlop = 4;
    public const double HoldSeconds = 0.45;
    public const double DoubleTapSeconds = 0.32;
    /// A second touch this soon after and this close to a trackpad tap arms a drag on movement.
    public const double DoubleTapDragSeconds = 0.28;
    public const double DoubleTapDragReach = 36;
    /// Past this a frame (at most 1920 px wide) is too soft to read.
    public const double MaxZoom = 4;
    public const double DoubleTapZoom = 2.5;
    /// A spread or squeeze this big makes two fingers a zoom rather than a scroll.
    public const double PinchStart = 0.06;
    public const double FlingDecay = 0.92;
    /// Page points per ms.
    public const double FlingStop = 0.4;
    /// A zoomed view pans to keep the pointer this far inside it.
    public const double Edge = 28;
    /// Mouse wheel discrete step: 40 page pixels per wheel line (10 points * 4).
    public const double PixelsPerWheelPoint = 4;

    /// The page fitted into the stage, zoomed, and kept covering the stage (centred where it is smaller).
    public static BrowserStageViewRect Place(BrowserSize stage, BrowserSize? page, double zoom, double x, double y)
    {
        var aspect = page is { Width: > 0, Height: > 0 } p
            ? p.Width / p.Height
            : stage.Width / Math.Max(1.0, stage.Height);
        var width = Math.Min(stage.Width, stage.Height * aspect);
        var height = width / Math.Max(aspect, 0.0001);
        var level = Math.Min(MaxZoom, Math.Max(1.0, zoom));
        static double Along(double offset, double drawn, double room) =>
            drawn <= room ? (room - drawn) / 2.0 : Math.Min(0.0, Math.Max(room - drawn, offset));
        return new BrowserStageViewRect(
            level,
            Along(x, width * level, stage.Width),
            Along(y, height * level, stage.Height),
            width,
            height);
    }

    /// Zoom by `factor` about a stage point, keeping the page point under it in place.
    public static BrowserStageViewRect Zoom(BrowserStageViewRect view, double factor, BrowserPoint at, BrowserSize stage, BrowserSize? page)
    {
        var zoom = Math.Min(MaxZoom, Math.Max(1.0, view.Zoom * factor));
        var ratio = zoom / view.Zoom;
        return Place(stage, page, zoom, at.X - (at.X - view.X) * ratio, at.Y - (at.Y - view.Y) * ratio);
    }

    /// Moves a pointer (fractions of the page) by finger travel in points, 1:1 with the drawn page.
    public static BrowserPoint Move(BrowserPoint pointer, double dx, double dy, BrowserSize drawn)
    {
        if (drawn.Width <= 0 || drawn.Height <= 0) return pointer;
        return new BrowserPoint(
            Math.Min(1.0, Math.Max(0.0, pointer.X + dx / drawn.Width)),
            Math.Min(1.0, Math.Max(0.0, pointer.Y + dy / drawn.Height)));
    }

    /// Two-finger travel in points as page scroll in page pixels (fingers up scroll the page down).
    public static BrowserVector ScrollDelta(double dx, double dy, BrowserSize drawn, BrowserSize? page)
    {
        var sx = page is { } p && drawn.Width > 0 ? p.Width / drawn.Width : 1.0;
        var sy = page is { } p2 && drawn.Height > 0 ? p2.Height / drawn.Height : 1.0;
        return new BrowserVector(-dx * sx, -dy * sy);
    }

    /// A stage point as fractions of the drawn page, kept on the page; null before the page has a size.
    public static BrowserPoint? Clamped(BrowserPoint point, BrowserStageViewRect view)
    {
        var size = view.DrawnSize;
        if (size.Width <= 0 || size.Height <= 0) return null;
        return new BrowserPoint(
            Math.Min(1.0, Math.Max(0.0, (point.X - view.X) / size.Width)),
            Math.Min(1.0, Math.Max(0.0, (point.Y - view.Y) / size.Height)));
    }

    /// A stage point as fractions of the drawn page, or null outside it.
    public static BrowserPoint? Fraction(BrowserPoint point, BrowserStageViewRect view)
    {
        var size = view.DrawnSize;
        if (size.Width <= 0 || size.Height <= 0) return null;
        var px = (point.X - view.X) / size.Width;
        var py = (point.Y - view.Y) / size.Height;
        return px is >= 0.0 and <= 1.0 && py is >= 0.0 and <= 1.0 ? new BrowserPoint(px, py) : null;
    }

    /// How far a zoomed view must pan to keep the pointer `Edge` inside the stage.
    public static BrowserVector Follow(BrowserPoint pointer, BrowserStageViewRect view, BrowserSize stage)
    {
        if (view.Zoom <= 1.0) return BrowserVector.Zero;
        var size = view.DrawnSize;
        var px = view.X + pointer.X * size.Width;
        var py = view.Y + pointer.Y * size.Height;
        var dx = px < Edge ? Edge - px : px > stage.Width - Edge ? stage.Width - Edge - px : 0.0;
        var dy = py < Edge ? Edge - py : py > stage.Height - Edge ? stage.Height - Edge - py : 0.0;
        return new BrowserVector(dx, dy);
    }

    /// True when a new finger touch lands quickly enough and close enough to a prior trackpad tap to arm a double-tap drag.
    public static bool IsDoubleTapDrag((double Time, BrowserPoint Point)? previous, BrowserPoint at, double now)
    {
        if (previous is not { } prev) return false;
        var dt = now - prev.Time;
        return dt >= 0 && dt <= DoubleTapDragSeconds && Hypot(at.X - prev.Point.X, at.Y - prev.Point.Y) <= DoubleTapDragReach;
    }

    public static double Hypot(double dx, double dy) => Math.Sqrt(dx * dx + dy * dy);
}

public enum BrowserOneFingerKind { Trackpad, Direct }

public abstract record BrowserOneFingerOut
{
    private BrowserOneFingerOut() { }
    /// The pointer draws pressed (a little smaller, with a grab ring) or not.
    public sealed record Look(bool Pressed) : BrowserOneFingerOut;
    /// A tactile tick when a finger grabs on glass (hold or double-tap-and-drag; not on a mouse).
    public sealed record Haptic : BrowserOneFingerOut { public static readonly Haptic Instance = new(); }
    /// The page's left button goes down where the pointer is.
    public sealed record Down : BrowserOneFingerOut { public static readonly Down Instance = new(); }
    /// The page's left button comes up where the pointer is.
    public sealed record Up : BrowserOneFingerOut { public static readonly Up Instance = new(); }
    /// A click where the pointer is.
    public sealed record Tap : BrowserOneFingerOut { public static readonly Tap Instance = new(); }
}

/// One finger, or the mouse's button, on the page while this device holds the browser: what goes to the page as it
/// lands, waits, travels and lifts. 1:1 port of HermesKit/Browser/BrowserTrackpadMath.swift `BrowserOneFinger`.
public struct BrowserOneFinger : IEquatable<BrowserOneFinger>
{
    public BrowserOneFingerKind Kind { get; }
    /// A press is owed to the first travel (`Direct`: from the start; `Trackpad`: after a quick preceding tap or once a hold runs).
    public bool Armed { get; private set; }
    /// The finger has travelled past the tap's slop (or moved while holding).
    public bool Moved { get; private set; }
    /// The page's button is down: a `Down` went out and its `Up` has not.
    public bool ButtonDown { get; private set; }

    public BrowserOneFinger(BrowserOneFingerKind kind, bool armed = false)
    {
        Kind = kind;
        Armed = kind == BrowserOneFingerKind.Direct || armed;
        Moved = false;
        ButtonDown = false;
    }

    /// The still hold ran out: presses the page's button right away so press-and-hold controls and sliders react before movement.
    public IReadOnlyList<BrowserOneFingerOut> Held()
    {
        if (Moved || ButtonDown) return [];
        Armed = true;
        ButtonDown = true;
        return Kind == BrowserOneFingerKind.Direct
            ? [new BrowserOneFingerOut.Look(true), BrowserOneFingerOut.Down.Instance]
            : [new BrowserOneFingerOut.Look(true), BrowserOneFingerOut.Haptic.Instance, BrowserOneFingerOut.Down.Instance];
    }

    /// The first travel: presses when armed and not already down (`Direct`, or `Trackpad` double-tap-and-drag).
    public IReadOnlyList<BrowserOneFingerOut> Travelled()
    {
        if (Moved) return [];
        Moved = true;
        if (!Armed || ButtonDown) return [];
        ButtonDown = true;
        return Kind == BrowserOneFingerKind.Direct
            ? [new BrowserOneFingerOut.Look(true), BrowserOneFingerOut.Down.Instance]
            : [new BrowserOneFingerOut.Look(true), BrowserOneFingerOut.Haptic.Instance, BrowserOneFingerOut.Down.Instance];
    }

    /// The finger lifted: a held button lets go; a finger that never travelled and never held clicks.
    public IReadOnlyList<BrowserOneFingerOut> Lifted()
    {
        Armed = false;
        if (ButtonDown)
        {
            ButtonDown = false;
            return [BrowserOneFingerOut.Up.Instance, new BrowserOneFingerOut.Look(false)];
        }
        if (Moved) return [];
        return [BrowserOneFingerOut.Tap.Instance];
    }

    /// The touch was taken away (a second finger, a call, control lost): a held button is let go, nothing clicks.
    public IReadOnlyList<BrowserOneFingerOut> Cancelled()
    {
        Armed = false;
        if (ButtonDown)
        {
            ButtonDown = false;
            return [BrowserOneFingerOut.Up.Instance, new BrowserOneFingerOut.Look(false)];
        }
        return [];
    }

    public bool Equals(BrowserOneFinger other) =>
        Kind == other.Kind && Armed == other.Armed && Moved == other.Moved && ButtonDown == other.ButtonDown;

    public override bool Equals(object? obj) => obj is BrowserOneFinger other && Equals(other);
    public override int GetHashCode() => HashCode.Combine(Kind, Armed, Moved, ButtonDown);
}

/// Host interface for BrowserStageState (matches App/Browser/BrowserStageView.swift `BrowserStageHost`).
public interface IBrowserStageHost
{
    bool StageHasControl { get; }
    void StageSend(BrowserInput input);
    void StageWillTap();
    void StageZoomed();
    void StageWatchTap();
}

/// Headless stage state machine (the non-drawing half of App/Browser/BrowserStageView.swift): layout, zoom, pan,
/// cursor placement, press-hold / direct drag / double-tap-and-drag, two-finger pinch & scroll + fling, mouse hover
/// and wheel, and batched per-frame move/scroll sending.
public sealed class BrowserStageState
{
    private sealed class OneState
    {
        public uint? PointerId;
        public BrowserPoint Start;
        public BrowserPoint Last;
        public BrowserOneFinger Press;
        public bool Moved => Press.Moved;
    }

    private enum TwoMode { Undecided, Zoom, Scroll }

    private sealed class TwoState
    {
        public BrowserPoint Mid;
        public double Distance;
        public double Time;
        public double Vx;
        public double Vy;
        public TwoMode Mode = TwoMode.Undecided;
        public BrowserStageViewRect Base;
    }

    private readonly IBrowserTimers? _timers;
    private readonly Func<double> _now;
    private readonly Dictionary<uint, BrowserPoint> _touches = [];
    private OneState? _one;
    private TwoState? _two;
    private IDisposable? _holdTimer;
    private IDisposable? _tapTimer;
    private IDisposable? _batchTimer;
    private IDisposable? _flingTimer;
    private double _lastTap;
    private (double Time, BrowserPoint Point)? _lastControlTap;
    private bool _pointing = true;
    private bool _pendingMove;
    private BrowserVector _scroll = BrowserVector.Zero;
    private BrowserVector _flingVelocity = BrowserVector.Zero;
    private double _flingLast;
    private bool _showsCursor;
    private bool _pressedLook;

    public IBrowserStageHost? Host { get; set; }

    public BrowserSize Bounds { get; private set; } = BrowserSize.Zero;
    public BrowserSize? PageSize { get; private set; }
    public BrowserStageViewRect Drawn { get; private set; } = new();
    public BrowserPoint Pointer { get; private set; } = new(0.5, 0.5);
    public bool HasFrame { get; private set; }
    public bool Covered { get; set; }

    /// Drawn pointer tip in stage coordinates.
    public BrowserPoint CursorPoint => new(
        Drawn.X + Pointer.X * Drawn.DrawnSize.Width,
        Drawn.Y + Pointer.Y * Drawn.DrawnSize.Height);

    /// Whether the drawn cursor and grab ring are visible (hidden when using mouse/hardware pointer).
    public bool CursorVisible => _showsCursor && HasFrame && !_pointing;
    public bool DragRingVisible => CursorVisible && _pressedLook;
    public bool PressedLook => _pressedLook;

    public bool ShowsCursor
    {
        get => _showsCursor;
        set
        {
            _showsCursor = value;
            OnVisualChanged?.Invoke();
            if (!value) DropLocalPress();
        }
    }

    public bool Pointing
    {
        get => _pointing;
        private set
        {
            if (_pointing == value) return;
            _pointing = value;
            OnVisualChanged?.Invoke();
        }
    }

    /// Fired whenever layout, cursor position, pressed look, or visibility changes.
    public Action? OnVisualChanged { get; set; }
    /// Fired when a click pulse should animate at `CursorPoint`.
    public Action<BrowserPoint>? OnClickFlash { get; set; }
    /// Fired when a touch grab should trigger a haptic cue (in tests or touch devices).
    public Action? OnHaptic { get; set; }

    public BrowserStageState(IBrowserTimers? timers = null, Func<double>? now = null)
    {
        _timers = timers;
        _now = now ?? (() => System.Diagnostics.Stopwatch.GetTimestamp() / (double)System.Diagnostics.Stopwatch.Frequency);
    }

    private bool Control => Host?.StageHasControl ?? false;

    public void SetBounds(BrowserSize size)
    {
        Bounds = size;
        Relayout();
    }

    public void ShowFrame(BrowserSize size)
    {
        var first = !HasFrame;
        HasFrame = true;
        if (PageSize != size || first)
        {
            PageSize = size;
            Relayout();
        }
        else OnVisualChanged?.Invoke();
    }

    public void Clear()
    {
        HasFrame = false;
        PageSize = null;
        DropLocalPress();
        OnVisualChanged?.Invoke();
    }

    public void Relayout() => Apply(BrowserTrackpadMath.Place(Bounds, PageSize, Drawn.Zoom, Drawn.X, Drawn.Y));

    public void Fit()
    {
        Apply(BrowserTrackpadMath.Place(Bounds, PageSize, 1, 0, 0));
        Host?.StageZoomed();
    }

    public void ZoomBy(double factor)
    {
        if (!HasFrame) return;
        var center = new BrowserPoint(Bounds.Width / 2, Bounds.Height / 2);
        Apply(BrowserTrackpadMath.Zoom(Drawn, factor, center, Bounds, PageSize));
        Host?.StageZoomed();
    }

    private void Apply(BrowserStageViewRect view)
    {
        Drawn = view;
        OnVisualChanged?.Invoke();
    }

    private BrowserVector Pan(double dx, double dy)
    {
        var next = BrowserTrackpadMath.Place(Bounds, PageSize, Drawn.Zoom, Drawn.X + dx, Drawn.Y + dy);
        var left = new BrowserVector(dx - (next.X - Drawn.X), dy - (next.Y - Drawn.Y));
        if (next.X != Drawn.X || next.Y != Drawn.Y) Apply(next);
        return left;
    }

    private void DropLocalPress()
    {
        CancelHold();
        _lastControlTap = null;
        if (!Control) _one = null;
        SetPressed(false);
    }

    private void SetPressed(bool on)
    {
        if (_pressedLook == on) return;
        _pressedLook = on;
        OnVisualChanged?.Invoke();
    }

    // ------------------------------------------------------------------ Hover & Wheel (mouse / touchpad)

    public void Hover(BrowserPoint point)
    {
        if (_one != null || _two != null) return;
        Pointing = true;
        if (!Control) return;
        if (BrowserTrackpadMath.Clamped(point, Drawn) is not { } now || now == Pointer) return;
        Pointer = now;
        OnVisualChanged?.Invoke();
        _pendingMove = true;
        ScheduleFlush();
    }

    /// Mouse wheel or touchpad scroll. `dx`/`dy` follow content motion (negative dy = scroll page down);
    /// `discrete` is true for notched mouse wheels (40 px per step), false for continuous trackpad scrolls.
    public void Wheel(double dx, double dy, bool discrete, BrowserPoint? at = null, bool zoom = false)
    {
        StopFling();
        if (zoom)
        {
            var anchor = at ?? new BrowserPoint(Bounds.Width / 2, Bounds.Height / 2);
            var factor = dy > 0 ? 1.15 : 1.0 / 1.15;
            Apply(BrowserTrackpadMath.Zoom(Drawn, factor, anchor, Bounds, PageSize));
            Host?.StageZoomed();
            return;
        }
        if (Control && discrete)
        {
            _scroll = new BrowserVector(_scroll.Dx - dx * BrowserTrackpadMath.PixelsPerWheelPoint,
                                        _scroll.Dy - dy * BrowserTrackpadMath.PixelsPerWheelPoint);
            ScheduleFlush();
            return;
        }
        var left = Pan(dx, dy);
        if (!Control) return;
        var delta = BrowserTrackpadMath.ScrollDelta(left.Dx, left.Dy, Drawn.DrawnSize, PageSize);
        _scroll = new BrowserVector(_scroll.Dx + delta.Dx, _scroll.Dy + delta.Dy);
        ScheduleFlush();
    }

    // ------------------------------------------------------------------ Touches / Pointer press

    public void TouchBegan(uint pointerId, BrowserPoint point, bool points, double? now = null)
    {
        StopFling();
        var t = now ?? _now();
        _touches[pointerId] = point;
        if (_touches.Count >= 2)
        {
            CancelHold();
            _lastControlTap = null;
            if (Control) Lift();
            _one = null;
            var pts = _touches.Values.Take(2).ToArray();
            var (mid, dist) = Midpoint(pts[0], pts[1]);
            _two = new TwoState { Mid = mid, Distance = dist, Time = t, Base = Drawn };
            return;
        }
        SingleBegan(pointerId, point, points, t);
    }

    public void TouchMoved(uint pointerId, BrowserPoint point, double? now = null)
    {
        if (!_touches.ContainsKey(pointerId))
        {
            Hover(point);
            return;
        }
        _touches[pointerId] = point;
        if (_two is { } two && _touches.Count >= 2)
        {
            var pts = _touches.Values.Take(2).ToArray();
            var (mid, distance) = Midpoint(pts[0], pts[1]);
            var factor = distance / two.Distance;
            if (two.Mode == TwoMode.Undecided)
            {
                if (Math.Abs(factor - 1) > BrowserTrackpadMath.PinchStart) two.Mode = TwoMode.Zoom;
                else if (BrowserTrackpadMath.Hypot(mid.X - two.Mid.X, mid.Y - two.Mid.Y) > BrowserTrackpadMath.TapSlop)
                    two.Mode = Control ? TwoMode.Scroll : TwoMode.Zoom;
                else return;
            }
            if (two.Mode == TwoMode.Zoom)
            {
                var zoomed = BrowserTrackpadMath.Zoom(two.Base, factor, two.Mid, Bounds, PageSize);
                Apply(BrowserTrackpadMath.Place(Bounds, PageSize, zoomed.Zoom, zoomed.X + mid.X - two.Mid.X, zoomed.Y + mid.Y - two.Mid.Y));
                return;
            }
            var t = now ?? _now();
            var dt = Math.Max(0.001, t - two.Time) * 1000.0;
            var left = Pan(mid.X - two.Mid.X, mid.Y - two.Mid.Y);
            var delta = BrowserTrackpadMath.ScrollDelta(left.Dx, left.Dy, Drawn.DrawnSize, PageSize);
            _scroll = new BrowserVector(_scroll.Dx + delta.Dx, _scroll.Dy + delta.Dy);
            two.Mid = mid;
            two.Time = t;
            two.Vx = delta.Dx / dt;
            two.Vy = delta.Dy / dt;
            ScheduleFlush();
            return;
        }
        if (_touches.Count == 1) SingleMoved(point);
    }

    public void TouchEnded(uint pointerId, double? now = null)
    {
        _touches.Remove(pointerId);
        if (_two is { } two)
        {
            if (_touches.Count < 2)
            {
                if (two.Mode == TwoMode.Zoom) Host?.StageZoomed();
                else if (two.Mode == TwoMode.Scroll && BrowserTrackpadMath.Hypot(two.Vx, two.Vy) > BrowserTrackpadMath.FlingStop)
                    StartFling(new BrowserVector(two.Vx, two.Vy));
                _two = null;
            }
            if (_touches.Count == 0) Reset();
            return;
        }
        if (_touches.Count > 0) return;
        SingleEnded(now ?? _now());
    }

    public void TouchCancelled(uint? pointerId = null)
    {
        if (pointerId is { } id) _touches.Remove(id);
        else _touches.Clear();
        SingleCancelled();
    }

    public void SingleBegan(uint? pointerId, BrowserPoint point, bool points, double now)
    {
        CancelHold();
        Pointing = points;
        var armed = Control && !points && BrowserTrackpadMath.IsDoubleTapDrag(_lastControlTap, point, now);
        _lastControlTap = null;
        _one = new OneState
        {
            PointerId = pointerId,
            Start = point,
            Last = point,
            Press = new BrowserOneFinger(points ? BrowserOneFingerKind.Direct : BrowserOneFingerKind.Trackpad, armed),
        };
        if (!Control) return;
        if (points)
        {
            if (BrowserTrackpadMath.Clamped(point, Drawn) is { } next && next != Pointer)
            {
                Pointer = next;
                OnVisualChanged?.Invoke();
                _pendingMove = true;
                ScheduleFlush();
            }
        }
        _holdTimer = _timers?.Schedule(TimeSpan.FromSeconds(BrowserTrackpadMath.HoldSeconds), repeats: false, SingleHoldFired);
    }

    public void SingleHoldFired()
    {
        CancelHold();
        if (!Control || _one is not { } held) return;
        if (held.PointerId is { } id && _touches.TryGetValue(id, out var livePoint)) held.Last = livePoint;
        var outs = held.Press.Held();
        if (outs.Count == 0) return;
        if (_pendingMove || _scroll != BrowserVector.Zero) Flush();
        Run(outs);
    }

    public void SingleMoved(BrowserPoint now)
    {
        if (_one is not { } o) return;
        var slop = o.Press.Kind == BrowserOneFingerKind.Direct ? BrowserTrackpadMath.DirectDragSlop : BrowserTrackpadMath.TapSlop;
        if (!o.Moved && !o.Press.ButtonDown && BrowserTrackpadMath.Hypot(now.X - o.Start.X, now.Y - o.Start.Y) < slop)
        {
            o.Last = now;
            return;
        }
        var dx = now.X - o.Last.X;
        var dy = now.Y - o.Last.Y;
        o.Last = now;
        if (!o.Moved)
        {
            CancelHold();
            var outs = o.Press.Travelled();
            if (Control)
            {
                if ((_pendingMove || _scroll != BrowserVector.Zero) && outs.Any(x => x is BrowserOneFingerOut.Down)) Flush();
                Run(outs);
            }
        }
        if (!Control) { Pan(dx, dy); return; }
        Pointer = o.Press.Kind == BrowserOneFingerKind.Direct
            ? BrowserTrackpadMath.Clamped(now, Drawn) ?? Pointer
            : BrowserTrackpadMath.Move(Pointer, dx, dy, Drawn.DrawnSize);
        var follow = BrowserTrackpadMath.Follow(Pointer, Drawn, Bounds);
        if (follow.Dx != 0 || follow.Dy != 0) Pan(follow.Dx, follow.Dy);
        OnVisualChanged?.Invoke();
        _pendingMove = true;
        ScheduleFlush();
    }

    public void SingleEnded(double now)
    {
        if (_one is not { } o) return;
        CancelHold();
        var tapped = !o.Moved;
        if (!Control)
        {
            Reset();
            if (!tapped) return;
            if (now - _lastTap < BrowserTrackpadMath.DoubleTapSeconds)
            {
                _lastTap = 0;
                _tapTimer?.Dispose();
                _tapTimer = null;
                Apply(Drawn.Zoom > 1.05
                    ? BrowserTrackpadMath.Place(Bounds, PageSize, 1, 0, 0)
                    : BrowserTrackpadMath.Zoom(Drawn, BrowserTrackpadMath.DoubleTapZoom, o.Start, Bounds, PageSize));
                Host?.StageZoomed();
                return;
            }
            _lastTap = now;
            if (BrowserTrackpadMath.Fraction(o.Start, Drawn) != null)
            {
                _tapTimer?.Dispose();
                if (_timers != null)
                    _tapTimer = _timers.Schedule(TimeSpan.FromSeconds(BrowserTrackpadMath.DoubleTapSeconds), repeats: false, () => Host?.StageWatchTap());
                else Host?.StageWatchTap();
            }
            return;
        }
        if (_pendingMove || _scroll != BrowserVector.Zero) Flush();
        var outs = o.Press.Lifted();
        Run(outs);
        _lastControlTap = o.Press.Kind == BrowserOneFingerKind.Trackpad && outs.Any(x => x is BrowserOneFingerOut.Tap)
            ? (now, o.Start)
            : null;
        Reset();
    }

    public void SingleCancelled()
    {
        StopFling();
        _batchTimer?.Dispose();
        _batchTimer = null;
        _pendingMove = false;
        _scroll = BrowserVector.Zero;
        _lastControlTap = null;
        if (Control) Lift(); else SetPressed(false);
        Reset();
    }

    public void Flush()
    {
        _batchTimer?.Dispose();
        _batchTimer = null;
        if (_pendingMove)
        {
            _pendingMove = false;
            Host?.StageSend(new BrowserInput.Move(Pointer.X, Pointer.Y));
        }
        if (_scroll.Dx != 0 || _scroll.Dy != 0)
        {
            Host?.StageSend(new BrowserInput.Scroll(
                Pointer.X, Pointer.Y,
                (int)Math.Round(_scroll.Dx, MidpointRounding.AwayFromZero),
                (int)Math.Round(_scroll.Dy, MidpointRounding.AwayFromZero)));
            _scroll = BrowserVector.Zero;
        }
    }

    public void Dispose()
    {
        StopFling();
        CancelHold();
        _tapTimer?.Dispose(); _tapTimer = null;
        _batchTimer?.Dispose(); _batchTimer = null;
    }

    private void ScheduleFlush()
    {
        if (_timers == null)
        {
            // Headless tests without timers flush synchronously when needed or via Flush().
            return;
        }
        if (_batchTimer != null) return;
        _batchTimer = _timers.Schedule(TimeSpan.FromMilliseconds(16), repeats: false, Flush);
    }

    private void Run(IReadOnlyList<BrowserOneFingerOut> outs)
    {
        foreach (var o in outs)
        {
            switch (o)
            {
                case BrowserOneFingerOut.Look l: SetPressed(l.Pressed); break;
                case BrowserOneFingerOut.Haptic: OnHaptic?.Invoke(); break;
                case BrowserOneFingerOut.Down: Host?.StageSend(new BrowserInput.Down(Pointer.X, Pointer.Y)); break;
                case BrowserOneFingerOut.Up: Host?.StageSend(new BrowserInput.Up(Pointer.X, Pointer.Y)); break;
                case BrowserOneFingerOut.Tap:
                    Host?.StageWillTap();
                    Host?.StageSend(new BrowserInput.Tap(Pointer.X, Pointer.Y));
                    OnClickFlash?.Invoke(CursorPoint);
                    break;
            }
        }
    }

    private void Lift()
    {
        if (_one is not { } held) return;
        if ((_pendingMove || _scroll != BrowserVector.Zero) && held.Press.ButtonDown) Flush();
        Run(held.Press.Cancelled());
    }

    private void CancelHold() { _holdTimer?.Dispose(); _holdTimer = null; }
    private void Reset() { CancelHold(); _one = null; _two = null; }

    private void StartFling(BrowserVector velocity)
    {
        if (_timers == null) return;
        _flingVelocity = velocity;
        _flingLast = _now();
        _flingTimer = _timers.Schedule(TimeSpan.FromMilliseconds(16), repeats: true, FlingStep);
    }

    private void FlingStep()
    {
        var now = _now();
        var dt = Math.Min(48.0, (now - _flingLast) * 1000.0);
        _flingLast = now;
        _scroll = new BrowserVector(_scroll.Dx + _flingVelocity.Dx * dt, _scroll.Dy + _flingVelocity.Dy * dt);
        _flingVelocity = new BrowserVector(_flingVelocity.Dx * BrowserTrackpadMath.FlingDecay,
                                           _flingVelocity.Dy * BrowserTrackpadMath.FlingDecay);
        Flush();
        if (BrowserTrackpadMath.Hypot(_flingVelocity.Dx, _flingVelocity.Dy) <= BrowserTrackpadMath.FlingStop / 4.0) StopFling();
    }

    private void StopFling() { _flingTimer?.Dispose(); _flingTimer = null; }

    private static (BrowserPoint Mid, double Distance) Midpoint(BrowserPoint a, BrowserPoint b) =>
        (new BrowserPoint((a.X + b.X) / 2.0, (a.Y + b.Y) / 2.0),
         Math.Max(1.0, BrowserTrackpadMath.Hypot(a.X - b.X, a.Y - b.Y)));
}
