using System.Diagnostics;

namespace Hermes.Core.Shell;

/// [WIN-EXIT-REDACTED] The order the app takes itself apart in before it quits. A Windows walk ended with status
/// 0xC000027B; that status alone doesn't identify the failing module, exception type or disposal step.
/// On the Mac, AppDelegate.applicationWillTerminate notes "quit" and flushes the log (App/AppDelegate.swift at
/// d60cdb0ca and 784f6c222). Each Windows step runs in its stage's place, with a breadcrumb before and after.
/// The last breadcrumb is progress, not a diagnosis: the fault may occur later or during a different operation.
///
/// Stages run in this order; inside a stage, steps run in the order they were added.
public enum ShutdownStage
{
    /// Timers first, so nothing fires into what the next steps take apart.
    Timers,
    /// The gateway socket: no more events marshal onto the UI thread, and requests in flight end while the UI still
    /// runs (their continuations fail now, logged, instead of after Exit).
    Gateway,
    /// Media and speech players stop.
    Media,
    /// The app's other windows close (their own Closed handlers run their teardown).
    Windows,
    /// The main window's WebView2 controls Close().
    WebViews,
    /// The toast registration goes (AppNotificationManager.Unregister): a later click starts the app again.
    Notifications,
    /// A last short wait so the continuations the steps above ended run while XAML still dispatches.
    Drain,
}

public sealed record ShutdownStepResult(ShutdownStage Stage, string Name, string Outcome, long Milliseconds);
public enum ShutdownProgress { Begin, Done, Threw, Timeout }

public sealed class ShutdownPlan
{
    /// How long one step may take before the pass moves on (a hung socket close never holds the quit).
    public static readonly TimeSpan DefaultStepLimit = TimeSpan.FromSeconds(5);

    private sealed record Step(ShutdownStage Stage, string Name, Func<Task> Run, int Seq);

    private readonly object _lock = new();
    private readonly SemaphoreSlim _pass = new(1);
    private readonly List<Step> _steps = [];
    private int _seq;
    private string? _ranFor;

    /// Adds a step that runs on the caller's thread and returns when it's done.
    public void Add(ShutdownStage stage, string name, Action run) =>
        Add(stage, name, () => { run(); return Task.CompletedTask; });

    /// Adds a step that may wait (a socket's close). Added after the pass has started, it is never run.
    public void Add(ShutdownStage stage, string name, Func<Task> run)
    {
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(run);
        lock (_lock) _steps.Add(new Step(stage, name, run, _seq++));
    }

    /// True once a pass has started. A second quit waits for it without taking anything apart twice.
    public bool Started { get { lock (_lock) return _ranFor != null; } }

    /// The steps as they will run: "stage · name".
    public IReadOnlyList<string> Order
    {
        get { lock (_lock) return [.. Ordered(_steps).Select(s => Label(s.Stage, s.Name))]; }
    }

    private static IEnumerable<Step> Ordered(IEnumerable<Step> steps) => steps.OrderBy(s => s.Stage).ThenBy(s => s.Seq);

    public static string Label(ShutdownStage stage, string name) => $"{stage.ToString().ToLowerInvariant()} · {name}";

    /// Closing a window can remove it from its registry. Snapshot first; attempt every distinct owned object once.
    /// On a partial close the step receives the first real error, never a successful count or a list of error messages.
    public static int CloseEach<T>(IEnumerable<T> current, Action<T> close) where T : class
    {
        var owned = current.Distinct<T>(ReferenceEqualityComparer.Instance).ToArray();
        Exception? first = null;
        foreach (var item in owned)
        {
            try { close(item); }
            catch (Exception e) { first ??= e; }
        }
        if (first is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Throw(first);
        return owned.Length;
    }

    /// Runs every step once, in order. `note` gets one line before and one after each step; a step that throws is
    /// noted with a known type and HRESULT and the pass goes on (it never ends the process here: the throw is
    /// named, and what quits the app is still the caller's Exit()). A step still running after `stepLimit` is noted
    /// and left behind. A second caller waits for the first pass before it can proceed to Exit.
    public async Task<IReadOnlyList<ShutdownStepResult>> RunAsync(string why, Action<string> note, TimeSpan? stepLimit = null,
        Action<ShutdownStage, ShutdownProgress>? milestone = null)
    {
        await _pass.WaitAsync();
        try { return await RunOnceAsync(why, note, stepLimit, milestone); }
        finally { _pass.Release(); }
    }

    private async Task<IReadOnlyList<ShutdownStepResult>> RunOnceAsync(string why, Action<string> note, TimeSpan? stepLimit,
        Action<ShutdownStage, ShutdownProgress>? milestone)
    {
        // Isolate the two evidence sinks, not the disposal. A closed log must not stop a step or mark it as thrown.
        void Note(string text) { try { note(text); } catch (Exception) { } }
        void Mark(ShutdownStage stage, ShutdownProgress progress) { try { milestone?.Invoke(stage, progress); } catch (Exception) { } }
        List<Step> steps;
        lock (_lock)
        {
            if (_ranFor != null)
            {
                Note($"shutdown ({why}): already ran for {_ranFor}");
                return [];
            }
            _ranFor = why;
            steps = [.. Ordered(_steps)];
        }
        var limit = stepLimit ?? DefaultStepLimit;
        var results = new List<ShutdownStepResult>(steps.Count);
        Note($"shutdown ({why}): begin, {steps.Count} steps");
        for (var i = 0; i < steps.Count; i++)
        {
            var step = steps[i];
            var label = $"{i + 1}/{steps.Count} {Label(step.Stage, step.Name)}";
            Mark(step.Stage, ShutdownProgress.Begin);
            Note($"shutdown {label}: begin");
            var clock = Stopwatch.StartNew();
            string outcome;
            ShutdownProgress progress;
            try
            {
                var running = step.Run();
                if (running.IsCompleted || await Task.WhenAny(running, Task.Delay(limit)).ConfigureAwait(true) == running)
                {
                    await running.ConfigureAwait(true);
                    outcome = "done";
                    progress = ShutdownProgress.Done;
                }
                else
                {
                    outcome = $"still running after {(long)limit.TotalMilliseconds} ms, moving on";
                    progress = ShutdownProgress.Timeout;
                    _ = running.ContinueWith(t => { _ = t.Exception; }, TaskScheduler.Default);   // observed, never unobserved
                }
            }
            catch (Exception e)
            {
                outcome = Threw(e);
                progress = ShutdownProgress.Threw;
            }
            clock.Stop();
            Mark(step.Stage, progress);
            results.Add(new ShutdownStepResult(step.Stage, step.Name, outcome, clock.ElapsedMilliseconds));
            Note($"shutdown {label}: {outcome} ({clock.ElapsedMilliseconds} ms)");
        }
        Note($"shutdown ({why}): end");
        return results;
    }

    /// A missing walk log still fails the caller's evidence check. It must not strand the app or replace an exit fault.
    public static async Task FinishWalkAsync(Func<Task> writeLog, Func<Task> dispose, Action exit)
    {
        try { await writeLog(); } catch (Exception) { } // best effort only around the evidence write
        await dispose();
        exit();
    }

    /// A managed cleanup failure is not the cause of a subsequent process fault. Never record the exception's text.
    public static string Threw(Exception e)
    {
        var type = e.GetType();
        var known = type == typeof(InvalidOperationException) || type == typeof(ObjectDisposedException) ||
            type == typeof(System.Runtime.InteropServices.COMException) || type == typeof(OperationCanceledException) ||
            type == typeof(IOException) || type == typeof(TimeoutException);
        return $"threw {(known ? type.Name : "unknown")} 0x{e.HResult:X8}";
    }
}
