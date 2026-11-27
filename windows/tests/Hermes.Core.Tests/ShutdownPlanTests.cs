using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-EXIT-STOWED-PROBE] The quit's ordered, logged teardown (Hermes.Core/Shell/ShutdownPlan.cs).
public class ShutdownPlanTests
{
    [Fact]
    public async Task RunsStagesInOrderWhateverTheOrderTheyWereAdded()
    {
        var plan = new ShutdownPlan();
        var ran = new List<string>();
        plan.Add(ShutdownStage.Notifications, "toasts unregister", () => ran.Add("toasts"));
        plan.Add(ShutdownStage.WebViews, "web views close", () => ran.Add("webviews"));
        plan.Add(ShutdownStage.Gateway, "gateway socket", () => { ran.Add("socket"); return Task.CompletedTask; });
        plan.Add(ShutdownStage.Timers, "launch timers", () => ran.Add("timers 1"));
        plan.Add(ShutdownStage.Media, "players", () => ran.Add("media"));
        plan.Add(ShutdownStage.Timers, "chat timers", () => ran.Add("timers 2"));
        plan.Add(ShutdownStage.Windows, "other windows", () => ran.Add("windows"));
        plan.Add(ShutdownStage.Drain, "drain", () => ran.Add("drain"));

        Assert.Equal(new[]
        {
            "timers · launch timers", "timers · chat timers", "gateway · gateway socket", "media · players",
            "windows · other windows", "webviews · web views close", "notifications · toasts unregister", "drain · drain",
        }, plan.Order);

        await plan.RunAsync("test", _ => { });
        Assert.Equal(new[] { "timers 1", "timers 2", "socket", "media", "windows", "webviews", "toasts", "drain" }, ran);
    }

    [Fact]
    public async Task NotesABreadcrumbBeforeAndAfterEveryStep()
    {
        var plan = new ShutdownPlan();
        var lines = new List<string>();
        plan.Add(ShutdownStage.Media, "players", () => lines.Add("(players ran)"));
        plan.Add(ShutdownStage.Timers, "timers", () => lines.Add("(timers ran)"));

        await plan.RunAsync("walk done", lines.Add);

        Assert.Equal("shutdown (walk done): begin, 2 steps", lines[0]);
        Assert.Equal("shutdown 1/2 timers · timers: begin", lines[1]);
        Assert.Equal("(timers ran)", lines[2]);
        Assert.Matches(@"^shutdown 1/2 timers · timers: done \(\d+ ms\)$", lines[3]);
        Assert.Equal("shutdown 2/2 media · players: begin", lines[4]);
        Assert.Equal("(players ran)", lines[5]);
        Assert.Matches(@"^shutdown 2/2 media · players: done \(\d+ ms\)$", lines[6]);
        Assert.Equal("shutdown (walk done): end", lines[7]);
        Assert.Equal(8, lines.Count);
    }

    [Fact]
    public async Task AStepThatThrowsIsNamedAndTheRestStillRun()
    {
        var plan = new ShutdownPlan();
        var lines = new List<string>();
        var after = false;
        plan.Add(ShutdownStage.WebViews, "web views close", () =>
            throw new InvalidOperationException("the control was already closed\nsecond line"));
        plan.Add(ShutdownStage.Notifications, "toasts unregister", () => after = true);

        var results = await plan.RunAsync("walk done", lines.Add);

        Assert.True(after);
        Assert.Equal("threw InvalidOperationException 0x80131509", results[0].Outcome);
        Assert.DoesNotContain(lines, l => l.Contains("already closed") || l.Contains("second line"));
        Assert.Contains(lines, l => l.StartsWith("shutdown 1/2 webviews · web views close: threw InvalidOperationException"));
        Assert.Equal("done", results[1].Outcome);
    }

    [Fact]
    public async Task AnAsyncThrowIsNamedToo()
    {
        var plan = new ShutdownPlan();
        plan.Add(ShutdownStage.Gateway, "gateway socket", async () =>
        {
            await Task.Yield();
            throw new ObjectDisposedException("socket");
        });
        var results = await plan.RunAsync("x", _ => { });
        Assert.StartsWith("threw ObjectDisposedException", results[0].Outcome);
    }

    [Fact]
    public async Task AStepThatHangsIsLeftBehindAfterTheLimit()
    {
        var plan = new ShutdownPlan();
        var never = new TaskCompletionSource();
        var next = false;
        plan.Add(ShutdownStage.Gateway, "gateway socket", () => never.Task);
        plan.Add(ShutdownStage.Media, "players", () => next = true);

        var results = await plan.RunAsync("x", _ => { }, TimeSpan.FromMilliseconds(50));

        Assert.Equal("still running after 50 ms, moving on", results[0].Outcome);
        Assert.True(next);
        never.SetException(new InvalidOperationException("late"));   // observed by the plan, never unobserved
    }

    [Fact]
    public async Task RunsOnceTheWindowsClosedAfterTheWalkAsksForNothing()
    {
        var plan = new ShutdownPlan();
        var count = 0;
        plan.Add(ShutdownStage.Timers, "timers", () => count++);
        Assert.False(plan.Started);

        await plan.RunAsync("walk done", _ => { });
        var lines = new List<string>();
        var second = await plan.RunAsync("window closed", lines.Add);

        Assert.True(plan.Started);
        Assert.Equal(1, count);
        Assert.Empty(second);
        Assert.Equal(new[] { "shutdown (window closed): already ran for walk done" }, lines);
    }

    [Fact]
    public async Task ASecondExitWaitsForDisposalAlreadyInFlight()
    {
        var plan = new ShutdownPlan();
        var dispose = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var released = false;
        plan.Add(ShutdownStage.Gateway, "socket", async () => { await dispose.Task; released = true; });
        var closing = plan.RunAsync("window closing", _ => { });
        var walkExit = plan.RunAsync("walk done", _ => { });
        try { Assert.False(walkExit.IsCompleted); } finally { dispose.SetResult(); }
        Assert.Empty(await walkExit);
        Assert.True(released);
        Assert.Single(await closing);
    }

    [Fact]
    public async Task WalkReceiptContainsOnlyThisStartTimeAndFlushedKnownMilestones()
    {
        var folder = Directory.CreateTempSubdirectory("exit-receipt-");
        try
        {
            using var self = System.Diagnostics.Process.GetCurrentProcess();
            var path = Path.Combine(folder.FullName, $"shutdown-{self.Id}.mark");
            var receipt = Assert.IsType<WalkShutdownReceipt>(WalkShutdownReceipt.StartIn(folder.FullName));
            var birth = $"birth={self.StartTime.ToFileTimeUtc():X16}";
            Assert.Equal([birth], File.ReadAllLines(path));
            Assert.Null(WalkShutdownReceipt.StartIn(folder.FullName)); // never replace an existing marker
            receipt.Step((ShutdownStage)99, ShutdownProgress.Begin);
            receipt.Step(ShutdownStage.Drain, (ShutdownProgress)99);

            var plan = new ShutdownPlan();
            plan.Add(ShutdownStage.Gateway, "socket", () => Assert.Equal("gateway.begin", File.ReadLines(path).Last()));
            plan.Add(ShutdownStage.Media, "players", () => throw new IOException("fixture-private-text"));
            var never = new TaskCompletionSource();
            plan.Add(ShutdownStage.Drain, "drain", () => never.Task);
            await plan.RunAsync("test", _ => { }, TimeSpan.FromMilliseconds(20), receipt.Step);
            never.SetResult();
            receipt.ExitRequested(); receipt.ExitReturned();
            Assert.Equal([birth, "gateway.begin", "gateway.done", "media.begin", "media.threw", "drain.begin",
                "drain.timeout", "exit.requested", "exit.returned"], File.ReadAllLines(path));
        }
        finally { folder.Delete(recursive: true); }
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task UnavailableEvidenceCannotSkipOrRepeatDisposal(bool failAtStart)
    {
        var plan = new ShutdownPlan();
        var stages = Enum.GetValues<ShutdownStage>();
        var ran = new List<ShutdownStage>();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        foreach (var stage in stages)
            plan.Add(stage, stage.ToString(), async () =>
            {
                ran.Add(stage);
                if (stage == ShutdownStage.Gateway) await release.Task;
            });
        void Note(string _) { if (failAtStart || ran.Count > 1) throw new UnauthorizedAccessException(); }
        void Mark(ShutdownStage stage, ShutdownProgress _) { if (stage >= ShutdownStage.Gateway) throw new IOException(); }

        var first = plan.RunAsync("walk", Note, milestone: Mark);
        var second = plan.RunAsync("window closing", Note, milestone: Mark);
        try { Assert.False(second.IsCompleted); } finally { release.SetResult(); }
        Assert.All(await first, result => Assert.Equal("done", result.Outcome));
        Assert.Empty(await second);
        Assert.Equal(stages, ran);
    }

    [Fact]
    public async Task DeniedWalkLogStillDisposesBeforeExitAndPreservesTheActualFailure()
    {
        var order = new List<string>();
        var plan = new ShutdownPlan();
        foreach (var stage in Enum.GetValues<ShutdownStage>()) plan.Add(stage, stage.ToString(), () => order.Add(stage.ToString()));
        var actual = new InvalidOperationException();
        var exitError = await Assert.ThrowsAsync<InvalidOperationException>(() => ShutdownPlan.FinishWalkAsync(
            () => Task.FromException(new UnauthorizedAccessException()),
            () => plan.RunAsync("walk", _ => throw new IOException()),
            () => { order.Add("exit"); throw actual; }));
        Assert.Same(actual, exitError);
        Assert.Equal(Enum.GetNames<ShutdownStage>().Append("exit"), order);

        var disposalError = new IOException();
        var error = await Assert.ThrowsAsync<IOException>(() => ShutdownPlan.FinishWalkAsync(
            () => throw new IOException(), () => Task.FromException(disposalError), () => Assert.Fail("Exited before disposal")));
        Assert.Same(disposalError, error);
    }

    [Fact]
    public async Task AStepAddedAfterThePassStartedNeverRuns()
    {
        var plan = new ShutdownPlan();
        var late = false;
        plan.Add(ShutdownStage.Timers, "adds another", () => plan.Add(ShutdownStage.Drain, "late", () => late = true));
        await plan.RunAsync("x", _ => { });
        Assert.False(late);
    }
}
