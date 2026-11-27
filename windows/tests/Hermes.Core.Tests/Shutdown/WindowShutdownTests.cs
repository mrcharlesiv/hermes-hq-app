using System.Reflection;
using System.Runtime.Loader;
using HermesHQ.Services;

namespace Hermes.Core.Tests;

public class WindowShutdownTests
{
    private sealed class ReturnedSession : IDisposable
    {
        public int Disposals;
        public void Dispose() => Disposals++;
    }

    // A process has one permanent quit plan. Give each ordering a fresh app, not a test-only reset.
    [Theory]
    [InlineData("walk")]
    [InlineData("close during log")]
    [InlineData("close during disposal")]
    [InlineData("user close first")]
    [InlineData("closed without closing")]
    [InlineData("log and exit fail")]
    public async Task RealBoundaryRunsOwnersOnceBeforeTheWinningTerminalCall(string ordering)
    {
        var assembly = typeof(WindowShutdownTests).Assembly;
        var context = new AssemblyLoadContext(null, isCollectible: true);
        context.Resolving += (_, name) => AssemblyLoadContext.GetLoadContext(assembly)!.LoadFromAssemblyName(name);
        try
        {
            var fresh = context.LoadFromAssemblyPath(assembly.Location).GetType(typeof(WindowShutdownTests).FullName!, true)!;
            await (Task)fresh.GetMethod(nameof(Check), BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(null, [ordering])!;
        }
        finally { context.Unload(); }
    }

    private static async Task Check(string ordering)
    {
        var lifetime = new WindowShutdown();
        var logRelease = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var order = new List<string>();
        var steps = new List<string>();
        var exitError = new InvalidOperationException("inert exit");
        var liveSession = new ReturnedSession();
        lifetime.RequireOpen(liveSession); // still owned by the live walk until adoption
        Assert.Equal(0, liveSession.Disposals);
        const string closed = "closed";
        void Cancel() => order.Add("cancel");
        void Remember() => order.Add(closed);
        void Close() { order.Add("close"); lifetime.OnClosed(Remember); }
        async Task WriteLog()
        {
            order.Add("log");
            if (ordering == "close during log") await logRelease.Task;
            if (ordering == "log and exit fail") throw new UnauthorizedAccessException();
        }
        void Exit()
        {
            order.Add("exit");
            if (ordering == "log and exit fail") throw exitError;
            lifetime.OnClosed(Remember);
        }
        AppLog.Sink = (area, line) =>
        {
            if (area != "shutdown") return;
            if (line.StartsWith("shutdown (") && line.Contains(": begin,")) order.Add("begin");
            if (line.EndsWith(": begin")) steps.Add(line);
            if (line.Contains("drain · let the UI thread settle: done")) order.Add("drained");
        };
        try
        {
            Task firstClose = Task.CompletedTask;
            if (ordering == "user close first")
            {
                firstClose = lifetime.OnClosingAsync(Cancel, Close);
                Assert.True(lifetime.IsClosing); Assert.False(firstClose.IsCompleted);
                await lifetime.OnClosingAsync(Cancel, Close); // repeated close while the first is deferred
            }
            else if (ordering == "closed without closing") lifetime.OnClosed(Remember);
            var walk = lifetime.FinishWalkAsync(WriteLog, Exit);
            if (ordering == "close during log")
            {
                try
                {
                    firstClose = lifetime.OnClosingAsync(Cancel, Close);
                    Assert.Equal(new[] { "log", "cancel" }, order);
                }
                finally { logRelease.TrySetResult(); }
            }
            else if (ordering == "close during disposal")
            {
                Assert.False(walk.IsCompleted);
                await lifetime.OnClosingAsync(Cancel, Close);
                Assert.Equal(["log", "begin", "cancel"], order);
            }
            if (ordering == "log and exit fail") Assert.Same(exitError, await Assert.ThrowsAsync<InvalidOperationException>(() => walk));
            else await walk;
            await firstClose;
            Assert.True(AppShutdown.Finished);
            Assert.Equal(ordering switch
            {
                "user close first" => ["cancel", "begin", "cancel", "log", "drained", "close", closed],
                "closed without closing" => [closed, "begin", "log", "drained"],
                "close during log" => ["log", "cancel", "begin", "drained", "exit", closed],
                "close during disposal" => ["log", "begin", "cancel", "drained", "exit", closed],
                "log and exit fail" => ["log", "begin", "drained", "exit"],
                _ => new[] { "log", "begin", "drained", "exit", closed },
            }, order);
            string[] owners = ["timers · open chat (its features' timers, its view model)", "timers · shell, lists and row steps",
                "timers · launch flow timers", "timers · gateway news timer", "timers · jobs badge timer", "gateway · gateway socket",
                "media · read aloud", "media · memo player", "media · completion cue player", "windows · settings window",
                "windows · screen window", "windows · browser window", "windows · preview tab window", "windows · phone call window",
                "windows · image viewer window", "windows · chat photo viewer", "windows · file and page windows",
                "webviews · main window's web views", "notifications · toast registration", "drain · let the UI thread settle"];
            Assert.Equal(owners.Select((owner, i) => $"shutdown {i + 1}/{owners.Length} {owner}: begin"), steps);
            var lateSession = new ReturnedSession();
            Assert.Throws<WindowShutdown.WalkEnded>(() => lifetime.RequireOpen(lateSession));
            Assert.Equal(1, lateSession.Disposals);
            var count = steps.Count;
            await lifetime.OnClosingAsync(() => Assert.Fail("Final close was cancelled"), () => Assert.Fail("Duplicate close"));
            await AppShutdown.RunAsync("late close");
            Assert.Equal(count, steps.Count);
        }
        finally { logRelease.TrySetResult(); AppLog.Sink = null; }
    }
}
