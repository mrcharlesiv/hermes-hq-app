using Hermes.Core.Chat;
using Hermes.Core.Net;
using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Pages;
using HermesHQ.Services;
using HermesHQ.ViewModels;
using Microsoft.UI.Xaml;

namespace Hermes.Core.Tests;

// Both test classes exercise the same app-owned window/page registries. Don't let another fixture become Current.
[CollectionDefinition("Shutdown UI", DisableParallelization = true)]
public class ShutdownUiCollection;

[Collection("Shutdown UI")]
public class OpenChatShutdownTests
{
    private static void Release(ChatViewModel vm, bool refuse)
    {
        if (refuse) vm.Session.Result.SetException(new GatewayException("http", "fixture refusal", 404));
        else vm.Session.Result.SetResult();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task LiveOpenReachesItsOwnChat(bool refuse)
    {
        using var page = new ChatPage();
        var vm = new ChatViewModel();
        var (context, opened) = page.OpenFixture(vm);
        Assert.False(opened.IsCompleted);
        Release(vm, refuse);
        await opened;
        Assert.Equal(refuse ? ChatOpenPhase.Failed : ChatOpenPhase.Open, context.OpenPhase);
        Assert.False(page.LoadingRing.IsActive);
        Assert.Equal(refuse ? Visibility.Visible : Visibility.Collapsed, page.LoadProblem.Visibility);
        Assert.Equal(refuse ? "This chat isn't on the gateway anymore." : null, page.LoadProblem.Text);
        Assert.Equal(refuse ? 0 : 1, page.Landings);
        Assert.Equal(1, page.ComposerUpdates);
        Assert.Equal(("ivy", false), Assert.Single(ListsHub.Current!.Bots.Changes));
        await page.EndForQuitAsync();
        Assert.Equal(1, vm.Disposals);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(true, true)]
    public async Task LateOpenCannotPaintAClosedOrReplacementChat(bool refuse, bool reopen)
    {
        using var page = new ChatPage();
        var old = new ChatViewModel();
        var (closed, pending) = page.OpenFixture(old);
        await page.EndForQuitAsync();
        Assert.Equal(1, old.Disposals);
        var next = reopen ? new ChatViewModel() : null;
        var replacement = next != null ? page.OpenFixture(next) : default;
        Release(old, refuse);
        await pending;
        Assert.Equal(ChatOpenPhase.Opening, closed.OpenPhase);
        Assert.True(page.LoadingRing.IsActive); // even the spinner must not be touched
        Assert.Null(page.LoadProblem.Text);
        Assert.Equal(Visibility.Collapsed, page.LoadProblem.Visibility);
        Assert.Empty(ListsHub.Current!.Bots.Changes);
        Assert.Equal((0, 0), (page.Landings, page.ComposerUpdates));
        if (next != null)
        {
            Assert.Equal(ChatOpenPhase.Opening, replacement.Context.OpenPhase);
            Release(next, false);
            await replacement.Opened;
            Assert.Equal(ChatOpenPhase.Open, replacement.Context.OpenPhase);
            Assert.Equal((1, 1), (page.Landings, page.ComposerUpdates));
            await page.EndForQuitAsync();
            Assert.Equal(1, next.Disposals);
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task UnexpectedOpenFailureIsStillTheOriginalFailure(bool detached)
    {
        using var page = new ChatPage();
        var vm = new ChatViewModel();
        var (_, pending) = page.OpenFixture(vm);
        var fault = new InvalidOperationException("fixture failure");
        if (detached) await page.EndForQuitAsync();
        vm.Session.Result.SetException(fault);
        Assert.Same(fault, await Assert.ThrowsAsync<InvalidOperationException>(() => pending));
        Assert.Empty(ListsHub.Current!.Bots.Changes);
        await page.EndForQuitAsync();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task QueuedSessionAndRowNotificationsBelongOnlyToTheirOpening(bool detach)
    {
        using var page = new ChatPage();
        var vm = new ChatViewModel();
        var (context, opened) = page.OpenFixture(vm);
        Release(vm, true);
        await opened;
        var changes = 0;
        context.TranscriptChanged += () => changes++;
        vm.Session.NotifyTitleAndRecovery();
        vm.NotifyRows();
        Assert.Equal(1, changes); // live rows updated, but title, recovery and deferred scroll haven't run yet
        Assert.Equal(3, page.DispatcherQueue.Count);
        var updates = page.ComposerUpdates;
        if (detach) await page.EndForQuitAsync();
        page.DispatcherQueue.Drain();
        Assert.Equal(detach ? null : "FIXTURE", page.TitleText.Text);
        Assert.Equal(detach ? ChatOpenPhase.Failed : ChatOpenPhase.Open, context.OpenPhase);
        Assert.Equal(detach ? Visibility.Visible : Visibility.Collapsed, page.LoadProblem.Visibility);
        Assert.Equal(detach ? 1 : 2, changes);
        Assert.Equal(detach ? updates : updates + 1, page.ComposerUpdates);
        Assert.Equal(detach ? 0 : 1, page.Landings);
        await page.EndForQuitAsync();
        vm.Session.NotifyTitleAndRecovery();
        vm.NotifyRows();
        Assert.Equal(0, page.DispatcherQueue.Count); // subscriptions themselves were removed, not just muted
        Assert.Equal(detach ? 1 : 2, changes);
        Assert.Equal(1, vm.Disposals);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ClosingInsidePhaseChangeStopsTheRestOfTheOpen(bool refuse)
    {
        using var page = new ChatPage();
        var vm = new ChatViewModel();
        var (context, opened) = page.OpenFixture(vm);
        Task? closed = null;
        context.TranscriptChanged += () => closed = page.EndForQuitAsync();
        Release(vm, refuse);
        await opened;
        Assert.NotNull(closed);
        await closed;
        Assert.Equal(1, vm.Disposals);
        Assert.Equal((0, 0), (page.Landings, page.ComposerUpdates));
        Assert.Null(page.LoadProblem.Text);
        Assert.Empty(ListsHub.Current!.Bots.Changes);
    }

    [Fact]
    public async Task AFailureInTheLiveUiIsNotARefusedGatewayOpen()
    {
        using var page = new ChatPage();
        var vm = new ChatViewModel();
        var (context, pending) = page.OpenFixture(vm);
        var fault = new GatewayException("fixture", "fixture UI fault");
        context.TranscriptChanged += () => { if (context.OpenPhase == ChatOpenPhase.Open) throw fault; };
        Release(vm, false);
        Assert.Same(fault, await Assert.ThrowsAsync<GatewayException>(() => pending));
        Assert.Equal(ChatOpenPhase.Open, context.OpenPhase);
        Assert.Null(page.LoadProblem.Text);
        await page.EndForQuitAsync();
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public async Task PendingOpenCannotRestartItsDisposedViewModelOrDeliverAnOldTick(bool detach, bool tickPosted)
    {
        using var page = new ChatPage();
        var vm = new ChatViewModel();
        var (_, pending) = page.OpenFixture(vm);
        vm.Session.NotifyChange(); // the first read of the pending open has rows; a timer start is now queued
        Assert.Equal(1, vm.RenderQueue.Count);
        Action? posted = null;
        if (tickPosted) { vm.RenderQueue.Drain(); posted = vm.RenderTimer.TakeTick(); }
        if (detach) await page.EndForQuitAsync();
        vm.RenderQueue.Drain();
        if (detach) Assert.False(vm.RenderTimer.IsRunning);
        if (posted != null) posted();
        else if (vm.RenderTimer.IsRunning) vm.RenderTimer.TakeTick()();
        Assert.Equal(detach ? 0 : 1, vm.Paints);
        Release(vm, false);
        await pending;
        await page.EndForQuitAsync();
        Assert.Equal(1, vm.Disposals);
    }

    [Fact]
    public async Task LeavingExpiresOnlyThatOpeningBeforeItsDisposalReturns()
    {
        using var page = new ChatPage();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var old = new ChatViewModel { Dispose = () => release.Task };
        var (closed, pending) = page.OpenFixture(old);
        var leaving = page.LeaveFixtureAsync();
        Assert.False(leaving.IsCompleted);
        Assert.Null(ChatPage.Current);
        Assert.Equal(("ivy", false), Assert.Single(ListsHub.Current!.Bots.Changes)); // the navigation, not a stale open
        var next = new ChatViewModel();
        var (current, opened) = page.OpenFixture(next);
        Release(old, true);
        try { await pending; }
        finally { release.SetResult(); }
        await leaving;
        Assert.Equal(ChatOpenPhase.Opening, closed.OpenPhase);
        Assert.Equal(ChatOpenPhase.Opening, current.OpenPhase);
        Assert.Null(page.LoadProblem.Text);
        Assert.Same(page, ChatPage.Current);
        Release(next, false);
        await opened;
        Assert.Equal(ChatOpenPhase.Open, current.OpenPhase);
        Assert.Equal(2, ListsHub.Current.Bots.Changes.Count);
        await page.EndForQuitAsync();
        await page.LeaveFixtureAsync(); // late navigation after the quit does not clear another bot's waiting marker
        Assert.Equal(2, ListsHub.Current.Bots.Changes.Count);
        Assert.Equal((1, 1), (old.Disposals, next.Disposals));
    }

    [Fact]
    public async Task RefusalAndReentryDoNotChangeTheSnapshottedRegistrations()
    {
        using var page = new ChatPage();
        var vm = new ChatViewModel();
        var (context, opened) = page.OpenFixture(vm);
        Release(vm, false);
        await opened;
        var calls = new List<string>();
        var first = new IOException("private fixture detail");
        Action peer = () => calls.Add("peer");
        context.Closed += () =>
        {
            calls.Add("first");
            context.Closed -= peer;
            context.Close(); // must not replay or consume a pending peer
            throw first;
        };
        context.Closed += peer;
        context.Closed += () => { calls.Add("second refusal"); throw new InvalidOperationException(); };
        context.Closed += peer; // two registrations, not two distinct target objects
        Assert.Same(first, await Assert.ThrowsAsync<IOException>(page.EndForQuitAsync));
        await page.EndForQuitAsync();
        context.Close();
        Assert.Equal(new[] { "first", "peer", "second refusal", "peer" }, calls);
        Assert.Equal(1, vm.Disposals);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public async Task EveryRegisteredChatCloseRunsOnceBeforeDisposeDrainAndExit(bool refuse, bool pendingAtQuit)
    {
        using var page = new ChatPage();
        var calls = new List<string>();
        var disposing = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var vm = new ChatViewModel { Dispose = () => { calls.Add("dispose"); disposing.SetResult(); return release.Task; } };
        var (context, opened) = page.OpenFixture(vm);
        if (!pendingAtQuit) { Release(vm, false); await opened; }
        context.Closed += () => { calls.Add("first"); if (refuse) throw new InvalidOperationException("private fixture detail"); };
        context.Closed += () => calls.Add("second");
        context.Closed += () => calls.Add("third");
        var plan = AppShutdown.Build();
        var notes = new List<string>();
        var marks = new List<(ShutdownStage, ShutdownProgress)>();
        IReadOnlyList<ShutdownStepResult> results = [];
        var finish = ShutdownPlan.FinishWalkAsync(() => Task.CompletedTask,
            async () => results = await plan.RunAsync("walk", notes.Add, milestone: (s, p) =>
            {
                marks.Add((s, p));
                if (s == ShutdownStage.Drain && p == ShutdownProgress.Done) calls.Add("drain");
            }), () => calls.Add("exit"));
        await disposing.Task.WaitAsync(TimeSpan.FromSeconds(10));
        var second = plan.RunAsync("second quit", notes.Add);
        try
        {
            Assert.False(finish.IsCompleted);
            Assert.False(second.IsCompleted);
            if (pendingAtQuit)
            {
                Release(vm, refuse);
                await opened;
                Assert.Equal(ChatOpenPhase.Opening, context.OpenPhase);
                Assert.True(page.LoadingRing.IsActive);
                Assert.Empty(ListsHub.Current!.Bots.Changes);
            }
        }
        finally { release.SetResult(); }
        await finish;
        Assert.Empty(await second);
        Assert.Equal(new[] { "first", "second", "third", "dispose", "drain", "exit" }, calls);
        Assert.Equal(1, vm.Disposals);
        Assert.Equal(refuse ? "threw InvalidOperationException 0x80131509" : "done", results.First().Outcome);
        Assert.Equal((ShutdownStage.Timers, refuse ? ShutdownProgress.Threw : ShutdownProgress.Done), marks[1]);
        Assert.DoesNotContain(notes, line => line.Contains("private fixture detail"));
    }
}
