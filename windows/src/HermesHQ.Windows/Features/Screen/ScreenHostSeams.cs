using Hermes.Core.Screen;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Screen;

/// [WIN-SCREEN-PAGE] The Bot Screen viewer's timers on the UI thread (Foundation's `Timer.scheduledTimer`):
/// a DispatcherQueueTimer per schedule, stopped when disposed (`invalidate()`).
internal sealed class DispatcherScreenTimers(DispatcherQueue queue) : IScreenViewerTimers
{
    public IDisposable Schedule(TimeSpan after, bool repeats, Action fire)
    {
        var timer = queue.CreateTimer();
        timer.Interval = after;
        timer.IsRepeating = repeats;
        timer.Tick += (t, _) =>
        {
            if (!repeats) t.Stop();
            fire();
        };
        timer.Start();
        return new Stop(timer.Stop);
    }

    private sealed class Stop(Action stop) : IDisposable
    {
        private bool _done;
        public void Dispose() { if (_done) return; _done = true; stop(); }
    }
}

/// [WIN-SCREEN-PAGE] The display's frame ticks (`CADisplayLink`): CompositionTarget.Rendering, subscribed while the link
/// runs and unsubscribed while it is paused or after it is disposed, so an idle stage costs no frames.
internal sealed class RenderingScreenTicks : IScreenFrameTicks
{
    public IScreenFrameLink Start(Action tick) => new Link(tick);

    private sealed class Link : IScreenFrameLink
    {
        private Action? _tick;
        private bool _paused = true;

        public Link(Action tick)
        {
            _tick = tick;
            Paused = false;
        }

        public bool Paused
        {
            get => _paused;
            set
            {
                if (_tick == null || value == _paused) return;
                _paused = value;
                if (value) CompositionTarget.Rendering -= OnRendering;
                else CompositionTarget.Rendering += OnRendering;
            }
        }

        private void OnRendering(object? sender, object e) => _tick?.Invoke();

        public void Dispose()
        {
            if (_tick == null) return;
            if (!_paused) CompositionTarget.Rendering -= OnRendering;
            _paused = true;
            _tick = null;
        }
    }
}

/// [WIN-SCREEN-PAGE] The display stays on while a live picture is on view (`isIdleTimerDisabled`): a DisplayRequest held
/// once, let go once. A refusal (no desktop session) is logged and otherwise ignored.
internal sealed class ScreenKeepAwake
{
    private Windows.System.Display.DisplayRequest? _request;
    public bool Held => _request != null;

    public void Set(bool on)
    {
        try
        {
            if (on && _request == null)
            {
                var request = new Windows.System.Display.DisplayRequest();
                request.RequestActive();
                _request = request;
            }
            else if (!on && _request is { } held)
            {
                _request = null;
                held.RequestRelease();
            }
        }
        catch (Exception e) { AppLog.Note("screen", $"keep awake {(on ? "on" : "off")} failed ({e.GetType().Name})"); }
    }
}
