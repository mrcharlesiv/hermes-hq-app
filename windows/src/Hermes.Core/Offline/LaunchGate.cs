namespace Hermes.Core.Offline;

/// Timers the launch machine schedules. The app's runs its callbacks on the UI thread; tests use ManualClock.
public interface ILaunchClock
{
    IDisposable Schedule(TimeSpan after, Action run);
    DateTimeOffset Now { get; }
}

/// A clock the test moves by hand.
public sealed class ManualClock : ILaunchClock
{
    private readonly List<(DateTimeOffset Due, Action Run, Handle H)> _timers = [];
    public DateTimeOffset Now { get; private set; } = DateTimeOffset.UnixEpoch;

    private sealed class Handle : IDisposable { public bool Cancelled; public void Dispose() => Cancelled = true; }

    public IDisposable Schedule(TimeSpan after, Action run)
    {
        var h = new Handle();
        _timers.Add((Now + after, run, h));
        return h;
    }

    public void Advance(TimeSpan by)
    {
        var end = Now + by;
        while (true)
        {
            var next = _timers.Where(t => !t.H.Cancelled && t.Due <= end).OrderBy(t => t.Due).FirstOrDefault();
            if (next.Run == null) break;
            _timers.Remove(next);
            Now = next.Due;
            next.Run();
        }
        Now = end;
    }
}

/// What still stands between the launch screen and an app worth showing: the gateway is not open and nothing saved is
/// on show (`Cover`), or it is open and a first list is still loading (`Loading`). Null = content.
public enum LaunchBlocker { Cover, Loading }

/// The launch screen's machine (HermesKit/Offline/LaunchGate.swift, docs/spec/3x-offline.md §3.1, §3.2): the icon
/// alone; an activity indicator once the wait is noticeable; a caption that says what it waits for; after 12 s still
/// not connected, the usual cause and the two buttons. It leaves once the app is connected with content, and a first
/// list gets 5 s to fill once the gateway is open before the app shows with its own loading state.
public sealed class LaunchGate
{
    public enum Phase { Shown, Leaving, Gone }

    public sealed record View(Phase Phase = Phase.Shown, bool Spinner = false, string Status = "", bool Actions = false);

    public sealed record Timing
    {
        public TimeSpan Spinner { get; init; } = TimeSpan.FromSeconds(0.9);
        public TimeSpan Status { get; init; } = TimeSpan.FromSeconds(4);
        public TimeSpan Stalled { get; init; } = TimeSpan.FromSeconds(12);
        public TimeSpan Content { get; init; } = TimeSpan.FromSeconds(5);
        public TimeSpan Settle { get; init; } = TimeSpan.FromSeconds(0.1);
        public TimeSpan Leave { get; init; } = TimeSpan.FromSeconds(0.12);
        public static readonly Timing Standard = new();
    }

    public static class StatusWords
    {
        public const string Connecting = "Connecting to Hermes…";
        public const string Loading = "Loading…";
        public const string Stalled = "Still connecting. Check that the computer running Hermes is on and awake.";
        public const string StalledTailscale =
            "Still connecting. Check that the computer running Hermes is on and awake, and that Tailscale is on here.";
        public const string StalledNous = "Still connecting. Your Nous agent may be stopped or still starting.";
        public static string StalledFor(bool throughTailscale, bool nous = false) =>
            nous ? StalledNous : throughTailscale ? StalledTailscale : Stalled;
    }

    private readonly Timing _timing;
    private readonly ILaunchClock _clock;
    private readonly Func<LaunchBlocker?> _blocker;
    private readonly Func<bool> _throughTailscale;
    private readonly Func<bool> _nous;
    private readonly Action<View> _render;
    private readonly List<IDisposable> _timers = [];
    private IDisposable? _contentTimer, _settleTimer;
    private bool _failed, _mounted, _contentDeadline;

    public View Current { get; private set; } = new();
    public bool HasFailed => _failed;
    public bool IsMounted => _mounted;

    public LaunchGate(ILaunchClock clock, Func<LaunchBlocker?> blocker, Action<View> render, Timing? timing = null,
        Func<bool>? throughTailscale = null, Func<bool>? nous = null)
    {
        _clock = clock;
        _blocker = blocker;
        _render = render;
        _timing = timing ?? Timing.Standard;
        _throughTailscale = throughTailscale ?? (() => false);
        _nous = nous ?? (() => false);
        Show();
    }

    private void Publish() => _render(Current);
    private void Later(TimeSpan after, Action run) => _timers.Add(_clock.Schedule(after, run));

    private void Clear()
    {
        foreach (var t in _timers) t.Dispose();
        _timers.Clear();
        _contentTimer?.Dispose(); _contentTimer = null;
        _settleTimer?.Dispose(); _settleTimer = null;
    }

    private void Arm()
    {
        Later(_timing.Spinner, () =>
        {
            if (Current.Phase != Phase.Shown || _failed || Current.Spinner) return;
            Current = Current with { Spinner = true };
            Publish();
        });
        Later(_timing.Status, WaitingCaption);
        Later(_timing.Stalled, () =>
        {
            if (Current.Phase != Phase.Shown || _failed || (_mounted && _blocker() != LaunchBlocker.Cover)) return;
            Current = Current with { Status = StatusWords.StalledFor(_throughTailscale(), _nous()), Actions = true };
            Publish();
        });
    }

    private void WaitingCaption()
    {
        if (_failed || Current.Phase != Phase.Shown) return;
        var now = _mounted ? _blocker() : LaunchBlocker.Cover;
        Current = Current with { Status = now == LaunchBlocker.Loading ? StatusWords.Loading : StatusWords.Connecting };
        Publish();
    }

    private void Show()
    {
        Clear();
        Current = new View();
        _failed = _mounted = _contentDeadline = false;
        Publish();
        Arm();
    }

    private void Leave()
    {
        if (Current.Phase != Phase.Shown) return;
        Clear();
        Current = Current with { Phase = Phase.Leaving, Spinner = false, Actions = false };
        Publish();
        Later(_timing.Leave, () =>
        {
            Current = Current with { Phase = Phase.Gone, Status = "" };
            Publish();
        });
    }

    private bool Ready(LaunchBlocker? now) => now == null || (now == LaunchBlocker.Loading && _contentDeadline);

    /// The lists or the connection changed: is the app worth showing now?
    public void Check()
    {
        if (Current.Phase != Phase.Shown || _failed || !_mounted) return;
        var now = _blocker();
        if (now != LaunchBlocker.Cover && _contentTimer == null && !_contentDeadline)
        {
            _contentTimer = _clock.Schedule(_timing.Content, () =>
            {
                _contentTimer = null;
                _contentDeadline = true;
                Check();
            });
        }
        if (!Ready(now))
        {
            _settleTimer?.Dispose(); _settleTimer = null;
            if (Current.Status == StatusWords.Connecting && now == LaunchBlocker.Loading)
            {
                Current = Current with { Status = StatusWords.Loading };
                Publish();
            }
            return;
        }
        if (_settleTimer != null) return;
        _settleTimer = _clock.Schedule(_timing.Settle, () =>
        {
            _settleTimer = null;
            if (Ready(_blocker())) Leave();
        });
    }

    /// Restoring or signing in finished and the app is loading again: the launch screen covers it.
    public void Booting() { if (Current.Phase != Phase.Shown) Show(); }

    /// An account is active: the launch screen leaves as soon as it is connected with content.
    public void Mount()
    {
        if (Current.Phase != Phase.Shown || _mounted) return;
        _mounted = true;
        if (_failed)
        {
            _failed = false;
            Current = Current with { Status = "", Actions = false };
            Publish();
        }
        Check();
    }

    /// Sign-in (or the offline screen) owns the window.
    public void Hide() => Leave();

    /// Startup stopped before the app was on screen: the icon stays with the reason and the buttons.
    public void Fail(string message)
    {
        if (Current.Phase != Phase.Shown) return;
        Clear();
        _failed = true;
        Current = Current with { Spinner = false, Status = message, Actions = true };
        Publish();
    }

    /// Try Again: the timers start over; the indicator stays, the caption is back to connecting, the buttons leave.
    public void Retry()
    {
        if (Current.Phase != Phase.Shown) return;
        Clear();
        _failed = false;
        _contentDeadline = false;
        Current = Current with { Spinner = true, Status = StatusWords.Connecting, Actions = false };
        Publish();
        Arm();
        Check();
    }
}

/// What the offline screen shows (App/Offline/OfflineScreenModel.swift): the words for the reason, the card naming
/// the gateway, and the status line — a countdown drawn from the due date (never a decrementing counter), or
/// "Connecting…" while an attempt runs.
public sealed class OfflineScreenModel
{
    public sealed record OtherGateway(string Key, string Title);

    public string? Reason { get; set; }
    public Uri? Url { get; set; }
    public string? Label { get; set; }
    public string? AccountName { get; set; }
    public int KeychainReads { get; set; }
    public IReadOnlyList<OtherGateway> OtherGateways { get; set; } = [];
    public DateTimeOffset? Due { get; private set; }
    public bool ConnectingNow { get; private set; }
    /// A sentence that replaces the status line (the storage sentence).
    public string? Problem { get; set; }

    /// Narrator's announcements (the app speaks them); recorded for tests.
    public Action<string> Announce { get; set; } = _ => { };
    public List<string> Announced { get; } = [];

    public OfflineCopy.Screen Screen => OfflineCopy.ScreenFor(Reason, Url != null, OfflineCopy.NousHosted(Url));
    private bool WaitsForNetwork => Reason == "network" && Due == null && !ConnectingNow;
    public OfflineCopy.Card? Card => OfflineCopy.CardFor(Reason, Url, Label, AccountName);
    public bool ShowsDifferentGateway => OfflineCopy.ShowsDifferentGateway(Url != null);
    public bool ShowsSignInAgain => OfflineCopy.ShowsSignInAgain(Reason, KeychainReads);
    public bool TryAgainEnabled => !ConnectingNow;

    public string StatusText(DateTimeOffset now)
    {
        if (!string.IsNullOrEmpty(Problem)) return Problem;
        if (ConnectingNow) return OfflineCopy.Connecting;
        if (WaitsForNetwork) return OfflineCopy.WaitingForNetwork;
        return Due is { } due ? OfflineCopy.Countdown(RetryLadder.Remaining(due, now)) : "";
    }

    /// What Narrator reads for the status line: never the number.
    public string SpokenStatus
    {
        get
        {
            if (!string.IsNullOrEmpty(Problem)) return Problem;
            if (ConnectingNow) return OfflineCopy.Connecting;
            if (WaitsForNetwork) return OfflineCopy.WaitingForNetwork;
            return Due == null ? "" : OfflineCopy.RetryingSpoken;
        }
    }

    /// The retry clock changed. One announcement when a countdown starts, one when an attempt starts.
    public void SetStatus(DateTimeOffset? due, bool connecting)
    {
        var countdownBegan = due != null && !connecting && (Due == null || ConnectingNow);
        var attemptBegan = connecting && !ConnectingNow;
        Due = connecting ? null : due;
        ConnectingNow = connecting;
        if (attemptBegan) Say(OfflineCopy.Connecting);
        else if (countdownBegan) Say(OfflineCopy.RetryingSpoken);
    }

    private void Say(string words)
    {
        Announced.Add(words);
        Announce(words);
    }
}
