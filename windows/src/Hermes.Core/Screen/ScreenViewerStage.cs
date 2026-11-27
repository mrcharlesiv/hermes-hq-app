// [WIN-SCREEN-VIEWER-CORE] The Bot Screen stage's non-drawing state, from the Mac's App/Screen/ScreenStageView.swift at
// 93f984bb1: the picture it holds, control / covered / dimmed, and the pacing of pointer moves. Moves go out at most
// once per display frame through a display link (IScreenFrameTicks). The link must not keep the stage (and its last
// full-size frame) alive after the screen goes away: it holds the stage through a weak proxy, as the Swift's
// DisplayTarget does, and a tick that finds the stage gone takes the link off the frame source. dropTouches takes it
// off at once; the next move builds a fresh one. The input half (touches, pen, mouse, wheel → ScreenGesture → pointer
// messages) is in ScreenGesture.cs [WIN-SCREEN-GESTURE]; the drawing is the page's.

namespace Hermes.Core.Screen;

/// `timers` arms the hold (550 ms) and `uptime` is the clock the gesture reads (seconds,
/// `ProcessInfo.systemUptime`); both default to the real ones.
public sealed partial class ScreenStageState(IScreenFrameTicks ticks, IScreenViewerTimers? timers = null, Func<double>? uptime = null)
{
    private readonly IScreenViewerTimers? _timers = timers;
    private readonly Func<double> _uptime = uptime ?? (() => System.Diagnostics.Stopwatch.GetTimestamp() / (double)System.Diagnostics.Stopwatch.Frequency);
    private IScreenFrameLink? _moveLink;
    private bool _movePending;
    private byte[]? _picture;
    private bool _control;

    /// `PointerEvent(mask, x, y)` for the bot's screen.
    public Action<byte, int, int>? OnPointer { get; set; }

    public (int Width, int Height) Framebuffer { get; private set; }
    /// The pointer's pixel on the bot's screen (the gesture's pointer; the page keeps it current).
    public (int X, int Y) PointerPixel { get; set; }
    /// The mouse buttons held down (a hold then move drags).
    public byte Held { get; set; }

    public bool HasPicture => _picture != null;
    public double Aspect => Framebuffer.Height > 0 ? (double)Framebuffer.Width / Framebuffer.Height : 16.0 / 10.0;

    /// This device holds the lease and the stream is live: input drives the pointer. Turning it off drops touches.
    public bool Control
    {
        get => _control;
        set
        {
            if (value == _control) return;
            _control = value;
            if (value) _gesture.ResetPointer();
            else DropTouches();
        }
    }

    /// The picture is dimmed while a stream is being attached over it.
    public bool Dimmed { get; set; }
    /// The picture is hidden (the task switcher must not show another computer's screen, DECISION D17).
    public bool Covered { get; set; }

    public void Show(byte[] picture, int width, int height)
    {
        var resized = width != Framebuffer.Width || height != Framebuffer.Height;
        _picture = picture;
        Framebuffer = (width, height);
        if (resized) FramebufferResized();
    }

    /// Control ended, the stream closed or the view is going away: forget touches and let go of a held button.
    public void DropTouches()
    {
        DropInput();
        _movePending = false;
        // Off the frame source now, not when collected; the next move builds a fresh link.
        _moveLink?.Dispose();
        _moveLink = null;
        Held = 0;
    }

    /// Moves go out at most once per display frame; the last position always goes before a button changes.
    public void ScheduleMove()
    {
        _movePending = true;
        if (_moveLink == null)
        {
            // A weak proxy: the frame source keeps its callback alive, and the stage must not outlive the screen.
            var proxy = new WeakTarget(this);
            _moveLink = ticks.Start(proxy.Tick);
            proxy.Link = _moveLink;
        }
        _moveLink.Paused = false;
    }

    /// A button change or a wheel step sends the position first (`sendPosition`).
    public void SendPosition()
    {
        _movePending = false;
        Send(Held);
    }

    public void Send(byte mask)
    {
        if (!Control || Framebuffer.Width <= 0) return;
        OnPointer?.Invoke(mask, PointerPixel.X, PointerPixel.Y);
    }

    private void FlushMove()
    {
        if (_moveLink != null) _moveLink.Paused = true;
        if (!_movePending) return;
        SendPosition();
    }

    /// Test seam (Swift `debugScheduleMove` / `debugHasMoveLink`).
    public void DebugScheduleMove() => ScheduleMove();
    public bool DebugHasMoveLink => _moveLink != null;

    private sealed class WeakTarget(ScreenStageState stage)
    {
        private readonly WeakReference<ScreenStageState> _stage = new(stage);
        public IScreenFrameLink? Link { get; set; }

        public void Tick()
        {
            if (_stage.TryGetTarget(out var stage)) stage.FlushMove();
            else
            {
                // The stage is gone: its link leaves the frame source (the Swift's deinit invalidates it).
                Link?.Dispose();
                Link = null;
            }
        }
    }
}
