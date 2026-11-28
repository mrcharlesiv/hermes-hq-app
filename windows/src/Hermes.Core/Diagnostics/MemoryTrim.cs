using System.Diagnostics;

namespace Hermes.Core.Diagnostics;

// Port of HermesKit/System/MemoryTrim.swift (docs/spec/3x-diagnostics.md §12): one central path for giving memory back
// on memory pressure or after sitting in the background. Each cache registers its own trim callback and returns how
// many items it dropped; pressure events within a 1-second window are deduplicated; returning to the foreground cancels
// any pending background trim.

public enum MemoryTrimReason
{
    Pressure,
    Background,
}

public static class MemoryTrim
{
    /// The background rule: at most this many warm chats, or this much decoded text, whichever is smaller.
    public const int BackgroundChats = 4;
    public const int BackgroundBytes = 4 << 20;

    /// One pressure event, one trim: triggers within this window are treated as the same event.
    public static readonly TimeSpan PressureWindow = TimeSpan.FromSeconds(1);

    private static readonly TimeSpan BackgroundLateGrace = TimeSpan.FromSeconds(2);
    private static readonly long ClockStart = Stopwatch.GetTimestamp();

    private sealed record Registered(string Name, Func<MemoryTrimReason, int> Trim);

    private static readonly object Gate = new();
    private static readonly List<Registered> Trims = [];
    private static int _runs;
    private static int _lastDropped;
    private static long _backgroundGeneration;
    private static TimeSpan _backgroundDelay = TimeSpan.FromSeconds(20);
    private static TimeSpan? _lastPressure;
    private static Task _queueTail = Task.CompletedTask;

    /// How many trims have run, and what the last one dropped.
    public static int Runs { get { lock (Gate) return _runs; } }
    public static int LastDropped { get { lock (Gate) return _lastDropped; } }

    /// How long the app stays in the background before its trim runs (tests shorten it).
    public static TimeSpan BackgroundDelay
    {
        get { lock (Gate) return _backgroundDelay; }
        set { lock (Gate) _backgroundDelay = value; }
    }

    /// Registers a cache's trim callback; a second registration under the same name replaces the first.
    public static void Register(string name, Func<MemoryTrimReason, int> trim)
    {
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(trim);
        lock (Gate)
        {
            Trims.RemoveAll(r => r.Name == name);
            Trims.Add(new Registered(name, trim));
        }
    }

    /// Runs a pressure trim unless another pressure trigger already ran within `PressureWindow`.
    public static bool PressureSignal(TimeSpan? now = null)
    {
        var current = now ?? Stopwatch.GetElapsedTime(ClockStart);
        bool fresh;
        lock (Gate)
        {
            if (_lastPressure is { } last && current >= last && current - last < PressureWindow)
                fresh = false;
            else
            {
                _lastPressure = current;
                fresh = true;
            }
        }
        if (fresh) RunNow(MemoryTrimReason.Pressure);
        return fresh;
    }

    /// Schedules a background trim after `BackgroundDelay`, unless cancelled or superseded first.
    public static void ScheduleBackground()
    {
        long generation;
        TimeSpan delay;
        lock (Gate)
        {
            generation = ++_backgroundGeneration;
            delay = _backgroundDelay;
        }
        var scheduledAt = Stopwatch.GetTimestamp();
        _ = Task.Run(async () =>
        {
            if (delay > TimeSpan.Zero)
            {
                try { await Task.Delay(delay).ConfigureAwait(false); }
                catch { return; }
            }
            // Fired well after its deadline: the process was suspended and is waking now.
            var elapsed = Stopwatch.GetElapsedTime(scheduledAt);
            if (elapsed > delay + BackgroundLateGrace) return;
            lock (Gate)
            {
                if (_backgroundGeneration != generation) return;
            }
            await RunAsync(MemoryTrimReason.Background).ConfigureAwait(false);
        });
    }

    /// Cancels any pending background trim.
    public static void CancelBackground()
    {
        lock (Gate) _backgroundGeneration++;
    }

    /// Runs every registered trim off the caller's thread, serialized against other queued trims.
    public static Task RunAsync(MemoryTrimReason reason)
    {
        lock (Gate)
        {
            _queueTail = _queueTail.ContinueWith(
                _ => RunNow(reason),
                CancellationToken.None,
                TaskContinuationOptions.None,
                TaskScheduler.Default);
            return _queueTail;
        }
    }

    /// Runs every registered trim synchronously and returns the total dropped count.
    public static int RunNow(MemoryTrimReason reason)
    {
        Registered[] snapshot;
        lock (Gate) snapshot = [.. Trims];
        var dropped = 0;
        foreach (var entry in snapshot)
            dropped += entry.Trim(reason);
        lock (Gate)
        {
            _runs++;
            _lastDropped = dropped;
        }
        return dropped;
    }

    /// Waits for any queued async trims to finish (tests).
    public static Task SettleAsync()
    {
        lock (Gate) return _queueTail;
    }

    /// Resets state for tests and cancels any previously scheduled background trim.
    public static void ResetForTests()
    {
        lock (Gate)
        {
            _backgroundGeneration++;
            Trims.Clear();
            _runs = 0;
            _lastDropped = 0;
            _backgroundDelay = TimeSpan.FromSeconds(20);
            _lastPressure = null;
        }
    }
}
