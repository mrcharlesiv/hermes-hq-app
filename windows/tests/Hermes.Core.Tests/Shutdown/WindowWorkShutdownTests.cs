using System.Reflection;
using System.Runtime.Loader;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Bots;
using Hermes.Core.Gateways;
using Hermes.Core.Net;
using Hermes.Core.Sessions;
using HermesHQ;
using HermesHQ.Features.Gateways;
using HermesHQ.Features.Jobs;
using HermesHQ.Features.Onboarding;
using HermesHQ.Features.Settings;
using HermesHQ.Services;

namespace Hermes.Core.Tests;

public class WindowWorkShutdownTests
{
    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static readonly TimeSpan Limit = TimeSpan.FromSeconds(10);

    // A window and its quit plan never reopen. Don't reset product statics or depend on other tests' order.
    private static async Task Fresh(string method, string mode)
    {
        var type = typeof(WindowWorkShutdownTests);
        var context = new AssemblyLoadContext(null, isCollectible: true);
        context.Resolving += (_, name) => AssemblyLoadContext.GetLoadContext(type.Assembly)!.LoadFromAssemblyName(name);
        try
        {
            var test = context.LoadFromAssemblyPath(type.Assembly.Location).GetType(type.FullName!, true)!;
            await ((Task)test.GetMethod(method, BindingFlags.Static | BindingFlags.NonPublic)!.Invoke(null, [mode])!).WaitAsync(Limit);
        }
        finally { context.Unload(); }
    }

    private sealed class Store : ITokenStore
    {
        internal int Writes;
        public string? Read() => null;
        public void Write(string _) => Writes++;
        public void Delete() => throw new NotSupportedException();
    }

    // Records route names only. It can intentionally return an ordinary reply despite cancellation.
    private sealed class Transport(string held = "") : HttpMessageHandler
    {
        internal readonly TaskCompletionSource Waiting = Signal(), Release = Signal();
        internal readonly List<string> Requests = [];
        internal int Disposals;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var (name, body) = request.RequestUri!.AbsolutePath switch
            {
                "/api/auth/providers" => ("providers", """{"providers":[{"name":"basic","supports_password":true}]}"""),
                "/auth/password-login" => ("login", "{}"),
                "/api/auth/me" => ("verify", "{}"),
                _ => throw new NotSupportedException(),
            };
            Requests.Add(name);
            if (held == name) { Waiting.SetResult(); await Release.Task; } // deliberately ignore the token
            return new(System.Net.HttpStatusCode.OK) { Content = new StringContent(body) };
        }
        protected override void Dispose(bool disposing) { if (disposing) Disposals++; base.Dispose(disposing); }
    }

    [Theory]
    [InlineData("live")]
    [InlineData("providers")]
    [InlineData("login")]
    [InlineData("verify")]
    public Task PasswordSignInStopsAtTheHeldReply(string mode) => Fresh(nameof(CheckSignIn), mode);

    private static async Task CheckSignIn(string mode)
    {
        var lifetime = new WindowShutdown(); var http = new Transport(mode); var store = new Store();
        var signIn = new SignIn(store, () => http);
        var work = signIn.PasswordAsync(GatewayAddress.FromTyped("https://example.com"), "fixture", "unused", lifetime.StopToken);
        if (mode == "live")
        {
            using (await work) { Assert.Equal(1, store.Writes); Assert.Equal(0, http.Disposals); }
            Assert.Equal(new[] { "providers", "login", "verify" }, http.Requests);
        }
        else
        {
            await http.Waiting.Task.WaitAsync(Limit);
            string[] before = [.. http.Requests];
            int closes = 0;
            var closed = lifetime.OnClosingAsync(() => { }, () => { closes++; lifetime.OnClosed(() => { }); });
            Assert.True(lifetime.StopToken.IsCancellationRequested);
            await closed.WaitAsync(Limit);
            http.Release.SetResult();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => work);
            Assert.Equal(before, http.Requests); Assert.Equal(0, store.Writes); Assert.Equal(1, closes);
        }
        Assert.Equal(1, http.Disposals);
    }

    [Theory]
    [InlineData("live")]
    [InlineData("log flush")]
    [InlineData("draining")]
    [InlineData("closed")]
    public Task BothRegisteredSignInReturnsHaveAnOwner(string mode) => Fresh(nameof(CheckForm), mode);

    private static async Task CheckForm(string mode)
    {
        var window = new MainWindow(); LaunchFlow.AttachWindow(window);
        var account = new StoredAccount("https://example.com", "fixture");
        LaunchFlow.ShowSignIn(account); LaunchFlow.PresentSignInSheet(account, "Sign In");
        var views = new[] { Assert.IsType<OnboardingView>(window.Content), Assert.IsType<OnboardingView>(window.Sheet) };
        var release = Signal(); Task end = Task.CompletedTask;
        if (mode == "log flush") end = window.Lifetime.FinishWalkAsync(() => release.Task, () => { });
        if (mode == "draining") end = AppShutdown.RunAsync("close");
        if (mode == "closed") { window.Lifetime.OnClosed(LaunchFlow.Closed); await AppShutdown.RunAsync("join"); }
        try
        {
            if (mode == "log flush") { Assert.True(window.Lifetime.IsClosing); Assert.False(AppShutdown.Started); }
            foreach (var view in views)
            {
                var http = new Transport();
                var returned = new GatewaySession(GatewayAddress.FromTyped(account.Url), account, new Store(), http);
                if (mode == "live")
                {
                    using (returned) // the live adopter is an inert throwing endpoint; the fixture cleans up only this case
                    {
                        var sentinel = Assert.Throws<NotSupportedException>(() => view.Return(returned));
                        Assert.Contains("AppState.Adopt(", sentinel.StackTrace); // inert adopter; no real client
                        Assert.Equal(0, http.Disposals);
                    }
                }
                else view.Return(returned);
                Assert.Empty(http.Requests);
                Assert.Equal(1, http.Disposals);
            }
        }
        finally { release.TrySetResult(); await end; }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AClosedFormWillNotStartOrWaitForAnotherVersionRead(bool alreadyClosed)
    {
        using var stop = new CancellationTokenSource();
        var called = Signal(); var finish = Signal(); var left = Signal();
        int reads = 0; CancellationToken given = default;
        if (alreadyClosed) stop.Cancel();
        var check = GatewayCompatibility.CappedAsync(async token =>
        {
            given = token; reads++; called.SetResult();
            await finish.Task; left.SetResult(); return GatewayCompatibility.Compatible; // ignores cancellation
        }, Timeout.InfiniteTimeSpan, stop.Token);
        try
        {
            if (!alreadyClosed) { await called.Task.WaitAsync(Limit); stop.Cancel(); }
            Assert.Same(GatewayCompatibility.Unknown, await check.WaitAsync(Limit));
            Assert.Equal(alreadyClosed ? 0 : 1, reads);
            if (!alreadyClosed) Assert.True(given.IsCancellationRequested);
        }
        finally { finish.TrySetResult(); if (called.Task.IsCompleted) await left.Task.WaitAsync(Limit); }
    }

    [Theory]
    [InlineData("log")]
    [InlineData("rollback")]
    public Task AlreadyQueuedOwnersCannotStartNewWorkWhileQuitWaitsToTearDown(string mode) => Fresh(nameof(CheckHeldOwner), mode);

    private static async Task CheckHeldOwner(string mode)
    {
        var window = App.Window = new Microsoft.UI.Xaml.Window(); var ui = window.DispatcherQueue;
        AppState.Client = new("fixture");
        JobsSidebarBadge.Register(); GatewaysFeature.RegisterNews(); AppState.NotifyClient(); ui.Drain();
        var (badge, news) = (ui.Timers[0], ui.Timers[1]);
        var badgeTick = badge.CaptureTick(); var newsTick = news.CaptureTick(); var activate = window.CaptureActivation();
        badgeTick(); newsTick(); activate(); // prove all three live endpoints, not stopped timers or missing handlers
        Assert.Equal((1, 1), (AppState.Gateways.Checks, AppState.Gateways.Activations));
        var release = Signal(); var life = new WindowShutdown();
        var visit = mode == "rollback" ? life.WithFixtureChangeAsync(() => Task.CompletedTask, () => Task.CompletedTask, () => release.Task) : Task.CompletedTask;
        JobsServices.Store.Notify(); AppState.NotifyClient(); // subscriber calls already queued before close
        var stop = mode == "rollback" ? life.OnClosingAsync(() => { }, () => life.OnClosed(() => { })) : life.FinishWalkAsync(() => release.Task, () => { });
        (int, int, int, int, int) Reads() => (badge.Starts, news.Starts, JobsServices.Store.Refreshes, AppState.Gateways.Checks, AppState.Gateways.Activations);
        var before = Reads();
        try
        {
            Assert.True(life.IsClosing); Assert.False(AppShutdown.Started); Assert.False(stop.IsCompleted);
            badgeTick(); newsTick(); activate(); ui.Drain();
            Assert.Equal(before, Reads());
        }
        finally { release.TrySetResult(); await visit; await stop; App.Window = null; AppState.Client = null; }
    }

    [Theory]
    [InlineData("live")]
    [InlineData("change in flight")]
    [InlineData("read outlives close")]
    [InlineData("closed directly")]
    [InlineData("restore in flight")]
    [InlineData("restore failed")]
    public Task TheCloseAndVisitShareOneLiveFixtureRestore(string mode) => Fresh(nameof(CheckFixture), mode);

    private static async Task CheckFixture(string mode)
    {
        var life = new WindowShutdown(); var initial = Signal(); var read = Signal(); var undo = Signal(); var undoStarted = Signal();
        var changed = 0; var restored = 0; var visited = 0; var navigated = 0; var closed = 0;
        if (mode != "change in flight") initial.SetResult();
        if (mode is "live" or "restore in flight") read.SetResult();
        var rollbackError = new IOException("fixture unavailable");
        var work = life.WithFixtureChangeAsync(async () => { changed++; await initial.Task; },
            async () => { visited++; await read.Task; life.RequireOpen(); navigated++; },
            async () => { restored++; undoStarted.SetResult(); await undo.Task; if (mode == "restore failed") throw rollbackError; });
        int steps = 0; bool rollbackFailureNoted = false;
        AppLog.Sink = (area, line) =>
        {
            if (area == "shutdown" && line.EndsWith(": begin")) steps++;
            if (area == "shutdown" && line.StartsWith("fixture rollback: threw IOException")) rollbackFailureNoted = true;
        };
        Task end = Task.CompletedTask;
        try
        {
            void Close() { closed++; life.OnClosed(() => { }); }
            if (mode == "live") { undo.SetResult(); await work; }
            if (mode == "restore in flight") await undoStarted.Task.WaitAsync(Limit);
            if (mode == "closed directly") { Close(); end = life.FinishWalkAsync(() => Task.CompletedTask, () => Assert.Fail("second exit")); }
            else
            {
                end = life.OnClosingAsync(() => { }, Close);
                await life.OnClosingAsync(() => { }, () => Assert.Fail("second close"));
            }
            if (mode == "change in flight") { Assert.Equal(0, restored); initial.SetResult(); }
            if (mode != "live")
            {
                await undoStarted.Task.WaitAsync(Limit);
                Assert.True(life.IsClosing); Assert.False(AppShutdown.Started); Assert.False(end.IsCompleted);
                Assert.Equal(0, steps); Assert.Equal(1, restored);
                undo.SetResult();
            }
            await end.WaitAsync(Limit); Assert.True(AppShutdown.Finished); Assert.Equal(20, steps);
            read.TrySetResult(); // deliberately deliver even after the gateway has gone
            if (mode is "live" or "restore in flight") await work;
            else if (mode == "restore failed") Assert.Same(rollbackError, await Assert.ThrowsAsync<IOException>(() => work));
            else await Assert.ThrowsAsync<WindowShutdown.WalkEnded>(() => work);
            Assert.Equal(mode == "restore failed", rollbackFailureNoted);
            Assert.Equal((1, 1, 1), (changed, restored, closed));
            Assert.Equal(mode == "change in flight" ? 0 : 1, visited);
            Assert.Equal(mode is "live" or "restore in flight" ? 1 : 0, navigated);
        }
        finally { initial.TrySetResult(); read.TrySetResult(); undo.TrySetResult(); AppLog.Sink = null; }
    }

    [Theory]
    [InlineData("sidebar")]
    [InlineData("fallback")]
    [InlineData("projects")]
    [InlineData("new chat")]
    public async Task ACancelledListReplyStartsNoFallbackAndPublishesNothing(string mode)
    {
        using var stop = new CancellationTokenSource();
        var gateway = new FakeGateway();
        gateway.OnRest = (_, _, _, _) => { stop.Cancel(); return new RestAnswer(mode == "fallback" ? 404 : 200, "{}"); };
        gateway.OnCall = (_, _) => { stop.Cancel(); return new JsonObject { ["stored_session_id"] = "unused" }; };
        var store = new SessionStore(gateway, new MemoryDeviceStore()) { BotOrder = ["ivy", "wren"] };
        int events = 0; store.Changed += () => events++;
        Task Read() => mode switch { "projects" => store.LoadProjectsAsync(true, stop.Token), "new chat" => store.NewChatAsync("ivy", "/fixture", stop.Token), _ => store.RefreshAsync(stop.Token) };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(Read);
        Assert.Equal(1, gateway.Rest.Count + gateway.Calls.Count);
        Assert.Empty(store.ProjectsByProfile); Assert.Equal(0, store.Reads); Assert.Equal(0, events);
        if (mode == "new chat") Assert.False(Hermes.Core.Chat.StartedChats.Take("ivy", "unused"));
    }
}
