using System.Diagnostics;

namespace Hermes.Core.Diagnostics;

// Port of HermesKit/Diagnostics/RunawayGuard.swift: a background timer asks the UI thread to answer once a second.
// When the UI thread has not answered for 30 s and the process's memory footprint has grown by at least 1.5 GB since
// it stopped answering, the app is in a runaway loop and the stop callback fires. A stall with steady memory (e.g. a
// long read or debugger pause) or a whole-process pause (sleep) is left alone.

public static class RunawayJudge
{
    public static readonly TimeSpan Interval = TimeSpan.FromSeconds(1);
    /// How long the UI thread has been silent before its memory is judged.
    public static readonly TimeSpan Stuck = TimeSpan.FromSeconds(30);
    /// How much the footprint grew (in MB) since the UI thread stopped answering.
    public const long GrowthMb = 1536;
    /// A turn of the timer this late means the whole process was held back (sleep): restart the question.
    public static readonly TimeSpan Late = TimeSpan.FromSeconds(5);

    /// Whether to stop the app: silent for `waited`, with footprint growing from `fromMb` to `nowMb` meanwhile.
    public static bool Stops(TimeSpan waited, long fromMb, long nowMb) =>
        waited >= Stuck && nowMb - fromMb >= GrowthMb;
}

public sealed class RunawayGuard : IDisposable
{
    private readonly object _lock = new();
    private readonly Func<long?> _footprintMb;
    private readonly Action<TimeSpan, long, long> _stop;
    private readonly Action<Action>? _dispatchToUi;

    private Timer? _timer;
    private DateTimeOffset? _askedAt;
    private long _fromMb;
    private DateTimeOffset? _lastTick;
    private bool _fired;

    public RunawayGuard(
        Func<long?>? footprintMb = null,
        Action<TimeSpan, long, long>? stop = null,
        Action<Action>? dispatchToUi = null)
    {
        _footprintMb = footprintMb ?? SampleFootprintMb;
        _stop = stop ?? (static (_, _, _) => { });
        _dispatchToUi = dispatchToUi;
    }

    /// Whether the runaway threshold fired.
    public bool Fired
    {
        get { lock (_lock) return _fired; }
    }

    /// Samples the current process private memory footprint in MB.
    public static long? SampleFootprintMb()
    {
        try
        {
            using var proc = Process.GetCurrentProcess();
            return proc.PrivateMemorySize64 / (1024L * 1024L);
        }
        catch
        {
            return null;
        }
    }

    public void Start()
    {
        lock (_lock)
        {
            if (_timer is not null || _fired) return;
            _timer = new Timer(_ => Tick(), null, RunawayJudge.Interval, RunawayJudge.Interval);
        }
    }

    public void Stop()
    {
        Timer? timer;
        lock (_lock)
        {
            timer = _timer;
            _timer = null;
        }
        timer?.Dispose();
    }

    /// One turn of the timer (also driven directly by tests): ask when nothing is pending, else judge the wait.
    public void Tick(DateTimeOffset? now = null, Action<Action>? ask = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        var mb = _footprintMb();
        (TimeSpan Waited, long FromMb, long NowMb)? verdict = null;
        Timer? timerToDispose = null;
        bool asking;

        lock (_lock)
        {
            var previous = _lastTick;
            _lastTick = current;
            if (_fired) return;

            if (previous is { } last && current - last >= RunawayJudge.Late)
                _askedAt = null;

            if (_askedAt is not { } askedAt)
            {
                _askedAt = current;
                _fromMb = mb ?? 0;
                asking = true;
            }
            else
            {
                asking = false;
                var waited = current - askedAt;
                if (mb is > 0 && _fromMb > 0 && RunawayJudge.Stops(waited, _fromMb, mb.Value))
                {
                    _fired = true;
                    timerToDispose = _timer;
                    _timer = null;
                    verdict = (waited, _fromMb, mb.Value);
                }
            }
        }

        timerToDispose?.Dispose();

        if (verdict is { } v)
        {
            _stop(v.Waited, v.FromMb, v.NowMb);
            return;
        }

        if (!asking) return;
        Action answer = () => Answered(current);
        var dispatcher = ask ?? _dispatchToUi;
        if (dispatcher is not null) dispatcher(answer);
        else _ = ThreadPool.QueueUserWorkItem(static cb => ((Action)cb!)(), answer);
    }

    public void Answered(DateTimeOffset asked)
    {
        lock (_lock)
        {
            if (_askedAt == asked) _askedAt = null;
        }
    }

    public void Dispose() => Stop();
}
