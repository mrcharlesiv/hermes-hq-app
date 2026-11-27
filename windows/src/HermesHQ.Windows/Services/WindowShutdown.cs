using Hermes.Core.Shell;

namespace HermesHQ.Services;

/// The last window and the walk share AppShutdown. All three callbacks enter on the UI thread.
internal sealed class WindowShutdown
{
    internal bool IsClosing { get; private set; }
    private bool _closed;
    private readonly CancellationTokenSource _stop = new();
    internal CancellationToken StopToken => _stop.Token;
    private readonly TaskCompletionSource _ownersStopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Task? _fixtureRestored;

    // A fixture read can complete after a user close. It has not been adopted by AppState, so the
    // walk (not the already-disposed gateway owner) still owns that returned session.
    internal sealed class WalkEnded : OperationCanceledException;

    internal void RequireOpen(IDisposable? unadopted = null)
    {
        if (!IsClosing) return;
        unadopted?.Dispose();
        throw new WalkEnded();
    }

    // The walk changes one fixture through its live gateway. Register the rollback BEFORE the first write.
    // Close can release it even if the visit's read or shot won't return until after Closed. Normal and
    // interrupted completion await the same restore; neither can restore twice or overtake the initial write.
    internal async Task WithFixtureChangeAsync(Func<Task> change, Func<Task> visit, Func<Task> restore)
    {
        RequireOpen();
        if (_fixtureRestored != null) throw new InvalidOperationException("a fixture change is still active");
        var changed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task RestoreAsync()
        {
            await release.Task;
            await changed.Task;
            await restore(); // the fixture uses its own bounded RPC, not the cancelled visit token
        }
        var restored = _fixtureRestored = RestoreAsync();
        using var closing = StopToken.Register(() => release.TrySetResult());
        try
        {
            try { await change(); }
            finally { changed.TrySetResult(); } // even an unacknowledged move may have reached the fixture
            RequireOpen();
            await visit();
        }
        finally
        {
            release.TrySetResult();
            try { await restored; } finally { _fixtureRestored = null; }
        }
    }

    private void Claim()
    {
        IsClosing = true;
        AppShutdown.StopNewWork(); // already-queued owners must not start a read during rollback or log flush
        try { _stop.Cancel(); }
        catch (AggregateException e) { AppLog.Note("shutdown", $"cancel window work: {ShutdownPlan.Threw(e)}"); }
    }

    private async Task StopOwnersAsync(string why)
    {
        try
        {
            if (_fixtureRestored is { } restored)
            {
                try { await restored; }
                catch (Exception e) { AppLog.Note("shutdown", $"fixture rollback: {ShutdownPlan.Threw(e)}"); }
            }
            await AppShutdown.RunAsync(why);
            _ownersStopped.TrySetResult();
        }
        catch (Exception e) { _ownersStopped.TrySetException(e); throw; }
    }

    internal async Task OnClosingAsync(Action cancel, Action close)
    {
        if (AppShutdown.Finished) return; // the deferred Close or XAML Exit can now go through
        cancel(); // must happen synchronously inside AppWindow.Closing, before any await
        if (IsClosing || AppShutdown.Started) return; // a close or the walk already owns the request
        Claim();
        await StopOwnersAsync("window closing");
        if (!_closed) close();
    }

    internal void OnClosed(Action remember)
    {
        _closed = true;
        bool ownsClose = !IsClosing;
        if (ownsClose) Claim();
        AppLog.Note("app", "window closed");
        try { remember(); }
        catch (Exception e) { AppLog.Note("unhandled", $"window closed: {ShutdownPlan.Threw(e)}"); throw; }
        finally
        {
            // A close that bypassed Closing has no deferral. Begin teardown if nobody already owns it.
            if (ownsClose) _ = StopOwnersAsync("window closed");
        }
    }

    internal Task FinishWalkAsync(Func<Task> writeLog, Action exit)
    {
        // Claim before the first await: a close during the log flush must wait, not tear down XAML
        // underneath the writer. Conversely, a late walk must not exit an already-closing dispatcher.
        bool ownsExit = !IsClosing;
        if (ownsExit) Claim();
        return ShutdownPlan.FinishWalkAsync(writeLog, () => ownsExit ? StopOwnersAsync("walk done") : _ownersStopped.Task, () =>
        {
            if (!ownsExit || _closed) return;
            AppLog.Note("app", "exiting after the walk");
            exit(); // no catch and no substitute process status
            AppLog.Note("app", "exit returned");
        });
    }
}
