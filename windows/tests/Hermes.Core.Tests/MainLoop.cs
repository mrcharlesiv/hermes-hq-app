// The Mac's main actor for tests: one thread with its own SynchronizationContext, work run in the order posted. The
// Screen rig's sessions run on it ([WIN-SCREEN-SESSION]), and so does every end-to-end test that drives a TasksStore
// ([WIN-TASKS-STORE-THREAD]): the store is used from one thread (the app's UI thread; the Mac's TasksStore is
// @MainActor), and a test with no SynchronizationContext let a Move's second PATCH start while the first one's answer
// was being put away on a pool thread. Every test that drives a KanbanStore runs on it too ([WIN-KANBAN-STORE-THREAD]:
// the Mac's KanbanStore is @MainActor; with no SynchronizationContext a write's answer, the board read after it and its
// Changed all ran on pool threads), and QuickTileRunTests' caller's-thread check uses it in place of a context of its own.

using System.Collections.Concurrent;

namespace Hermes.Core.Tests;

/// The Mac's @MainActor: one thread, its SynchronizationContext, work run in the order posted.
internal sealed class MainLoop : IDisposable
{
    private sealed class Context(MainLoop loop) : SynchronizationContext
    {
        public override void Post(SendOrPostCallback d, object? state) => loop.Enqueue(() => d(state));
        public override void Send(SendOrPostCallback d, object? state) => loop.Read(() => { d(state); return 0; });
        public override SynchronizationContext CreateCopy() => this;
    }

    private readonly BlockingCollection<Action> _work = new();
    private readonly Thread _thread;

    public MainLoop()
    {
        var context = new Context(this);
        _thread = new Thread(() =>
        {
            SynchronizationContext.SetSynchronizationContext(context);
            foreach (var action in _work.GetConsumingEnumerable())
            {
                try { action(); }
                catch (Exception e) { Failures.Add(e); }
            }
        }) { IsBackground = true, Name = "test-main" };
        _thread.Start();
    }

    /// Anything a posted piece of work threw (a test fails on it).
    public ConcurrentBag<Exception> Failures { get; } = [];

    public bool IsCurrent => Thread.CurrentThread == _thread;

    private void Enqueue(Action action)
    {
        try { _work.Add(action); } catch (InvalidOperationException) { }
    }

    public T Read<T>(Func<T> read)
    {
        if (IsCurrent) return read();
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        Enqueue(() => { try { done.SetResult(read()); } catch (Exception e) { done.SetException(e); } });
        return done.Task.GetAwaiter().GetResult();
    }

    public void Run(Action action) => Read(() => { action(); return 0; });

    /// Starts `work` on the loop and completes when it does (an `await` from a test).
    public Task<T> RunAsync<T>(Func<Task<T>> work)
    {
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        Enqueue(async () =>
        {
            try { done.SetResult(await work()); }
            catch (Exception e) { done.SetException(e); }
        });
        return done.Task;
    }

    public Task RunAsync(Func<Task> work)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Enqueue(async () =>
        {
            try { await work(); done.SetResult(); }
            catch (Exception e) { done.SetException(e); }
        });
        return done.Task;
    }

    /// Runs `body` on a loop of its own, as the app's UI thread runs it, and fails on anything posted work threw.
    public static async Task Drive(Func<Task> body)
    {
        using var loop = new MainLoop();
        await loop.RunAsync(body);
        Assert.Empty(loop.Failures);
    }

    public void Dispose() => _work.CompleteAdding();
}
