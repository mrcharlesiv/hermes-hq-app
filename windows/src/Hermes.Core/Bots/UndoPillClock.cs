namespace Hermes.Core.Bots;

/// What holds the Undo pill on screen (App/Kit/UndoPill.swift `UndoPillClock.Hold`). On Windows: `Finger` is a touch
/// pressed on the pill, `Pointer` the mouse or pen resting over it, `VoiceOver` the keyboard (which Narrator follows)
/// inside it, `Away` kept for the Mac's Talk "away" pill (Windows has none yet).
public enum UndoPillHold { Finger, VoiceOver, Away, Pointer }

/// The Undo pill's clock, kept apart from the view so its rules are unit-tested (App/Kit/UndoPill.swift `UndoPillClock`,
/// `S/ui-kit/undo-pill.tsx`, parity §3 L237): it runs only while nothing holds it, and a hold keeps what was left, so the
/// pill resumes instead of starting over.
public sealed class UndoPillClock
{
    /// The Mac's default (`UndoPill.show(duration: 4)`).
    public const double Seconds = 4;

    /// At least this long at accessibility text sizes.
    public const double AccessibilitySeconds = 8;

    /// [WIN-44] The Windows text scale (Settings › Accessibility › Text size, `UISettings.TextScaleFactor`, 1.0–2.25) that
    /// stands for iOS's accessibility sizes. iOS's largest ordinary size (xxxLarge, Body 23 pt over the default 17 pt) is
    /// 135%, its first accessibility size (AX1, Body 28 pt) about 165%; Windows text sized 150% or more counts.
    public const double AccessibilityTextScaleFactor = 1.5;

    public static bool AccessibilityTextScale(double textScaleFactor) => textScaleFactor >= AccessibilityTextScaleFactor;

    private readonly HashSet<UndoPillHold> _holds = [];
    private DateTimeOffset? _runningSince;

    /// 4 s as asked, at least 8 s at accessibility text sizes (chosen when the pill is made).
    public UndoPillClock(double duration, bool accessibilitySize) =>
        Remaining = accessibilitySize ? Math.Max(AccessibilitySeconds, duration) : duration;

    /// Seconds still to show once nothing holds it.
    public double Remaining { get; private set; }

    public IReadOnlySet<UndoPillHold> Holds => _holds;

    public bool IsRunning => _runningSince != null;

    /// Starts (or resumes) the clock when nothing holds it: the seconds until the pill goes, or null while held.
    public double? Resume(DateTimeOffset now)
    {
        if (_holds.Count > 0) return null;
        _runningSince ??= now;
        return Left(now);
    }

    /// A hold begins: the clock stops and keeps what is left.
    public void Hold(UndoPillHold hold, DateTimeOffset now)
    {
        if (_runningSince is { } since)
        {
            Remaining = Math.Max(0, Remaining - (now - since).TotalSeconds);
            _runningSince = null;
        }
        _holds.Add(hold);
    }

    /// A hold ends: the seconds until the pill goes if the clock runs again, null while another hold stands.
    public double? Release(UndoPillHold hold, DateTimeOffset now)
    {
        _holds.Remove(hold);
        return Resume(now);
    }

    public double Left(DateTimeOffset now) =>
        _runningSince is { } since ? Math.Max(0, Remaining - (now - since).TotalSeconds) : Remaining;
}

/// [WIN-44] One pill's time on screen: its clock and the one timer armed for what is left (App/Kit/UndoPill.swift
/// `resumeClock`, `arm`, `setHold`, `dismiss`). The pill keeps this, and this keeps the timer: the Windows pill armed a
/// DispatcherQueueTimer it held no reference to, which never ticked, and "Archived “Trip planning” · Undo" stayed for
/// minutes. `schedule` arms a one-shot timer (disposing it stops it); `expired` takes the pill away.
public sealed class UndoPillLife(UndoPillClock clock, Func<DateTimeOffset> now, Func<TimeSpan, Action, IDisposable> schedule, Action expired)
{
    public UndoPillClock Clock { get; } = clock;

    /// The timer armed now (null while held or once ended).
    public IDisposable? Timer { get; private set; }

    public bool Ended { get; private set; }

    /// The pill is on show: run the clock unless something holds it already.
    public void Start()
    {
        if (Ended) return;
        Stop();
        if (Clock.Resume(now()) is { } left) Arm(left);
    }

    public void SetHold(UndoPillHold hold, bool on)
    {
        if (Ended) return;
        if (on)
        {
            if (Clock.Holds.Contains(hold)) return;
            Clock.Hold(hold, now());
            Stop();
        }
        else
        {
            if (!Clock.Holds.Contains(hold)) return;
            if (Clock.Release(hold, now()) is { } left) Arm(left);
        }
    }

    /// Undo pressed, a failure, or another pill took the place: no timer left behind.
    public void End()
    {
        Ended = true;
        Stop();
    }

    private void Arm(double seconds)
    {
        Stop();
        IDisposable? armed = null;
        armed = schedule(TimeSpan.FromSeconds(Math.Max(0.01, seconds)), () =>
        {
            if (Ended || !ReferenceEquals(Timer, armed)) return;
            End();
            expired();
        });
        Timer = armed;
    }

    private void Stop()
    {
        Timer?.Dispose();
        Timer = null;
    }
}
