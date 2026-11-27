using System.Reflection;
using System.Runtime.Loader;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using Hermes.Core.Offline;
using Hermes.Core.Rpc;
using Hermes.Core.Shell;
using HermesHQ;
using HermesHQ.Features.Gateways;
using HermesHQ.Services;
using Client = HermesHQ.HermesClient;

namespace Hermes.Core.Tests;

public class LaunchFlowShutdownTests
{
    // Each case gets the shipping static app's actual, one-way quit. Don't add a production "reset quit"
    // or let whichever xUnit test runs first decide whether the other cases ever exercised a live app.
    private static async Task FreshApp(string method, params object[] args)
    {
        var type = typeof(LaunchFlowShutdownTests);
        var context = new AssemblyLoadContext(null, isCollectible: true);
        context.Resolving += (_, name) => AssemblyLoadContext.GetLoadContext(type.Assembly)!.LoadFromAssemblyName(name);
        try
        {
            var fixture = context.LoadFromAssemblyPath(type.Assembly.Location).GetType(type.FullName!, throwOnError: true)!;
            await (Task)fixture.GetMethod(method, BindingFlags.Static | BindingFlags.NonPublic)!.Invoke(null, args)!;
        }
        finally { context.Unload(); }
    }

    [Theory]
    [InlineData("status")]
    [InlineData("retry")]
    [InlineData("spinner")]
    [InlineData("replaced launch screen")]
    [InlineData("content and settle")]
    public Task LiveDeliveryThenPostedWorkDuringDrain(string mode) => FreshApp(nameof(CheckOwner), mode);

    private sealed record Snapshot(int Timers, int Running, int Starts, int Stops, int TimerObservers,
        int ViewObservers, int ClientObservers, int Roots, int Paints, int Announcements, int Restores, int FirstReads);

    private static async Task CheckOwner(string mode)
    {
        var window = new MainWindow();
        var ui = window.DispatcherQueue;
        var client = mode == "retry" ? null : new Client("fixture");
        if (client != null)
        {
            client.Rpc.State = mode switch { "status" => ConnectionState.Offline, "content and settle" => ConnectionState.Open, _ => ConnectionState.Connecting };
            if (mode == "content and settle") client.Bots = new();
        }
        LaunchFlow.ShowFixture(window, client);
        if (mode == "replaced launch screen")
        {
            // First paint a live spinner. Go offline and back to a first-list wait before its old fade fires.
            var first = Assert.IsType<LaunchView>(window.Content);
            var frames = first.Frames.Count;
            ui.Timers.Single(t => t.Interval == LaunchGate.Timing.Standard.Spinner).TakeTick()();
            Assert.Equal(frames + 1, first.Frames.Count); Assert.True(first.Frames.Last().Spinner);
            client!.Rpc.State = ConnectionState.Offline; client.Rpc.CaptureState()(); ui.Drain();
            var retired = Assert.IsType<OfflineView>(window.Content); Assert.True(retired.Clock.IsEnabled);
            client.Rpc.State = ConnectionState.Open; client.Rpc.CaptureState()(); ui.Drain();
            Assert.NotSame(first, Assert.IsType<LaunchView>(window.Content)); Assert.False(retired.Clock.IsEnabled);
            Assert.Single(ui.Timers, t => t.IsRunning && t.Interval == LaunchGate.Timing.Standard.Leave);
            Assert.Single(ui.Timers, t => t.IsRunning && t.Interval == LaunchGate.Timing.Standard.Spinner);
        }
        var launches = window.Roots.OfType<LaunchView>().ToArray();
        var launch = launches.Last();
        var offlineViews = window.Roots.OfType<OfflineView>().ToArray();
        var offline = window.Content as OfflineView;
        Snapshot Snap() => new(ui.Timers.Count, ui.Timers.Count(t => t.IsRunning) + offlineViews.Count(v => v.Clock.IsEnabled),
            ui.Timers.Sum(t => t.Starts) + offlineViews.Sum(v => v.Clock.Starts), ui.Timers.Sum(t => t.Stops) + offlineViews.Sum(v => v.Clock.Stops),
            ui.Timers.Sum(t => t.Subscribers), offlineViews.Sum(v => v.Observers), (client?.BotObservers ?? 0) + (client?.Rpc.Observers ?? 0),
            window.Roots.Count, launches.Sum(v => v.Frames.Count) + offlineViews.Sum(v => v.Paints), offlineViews.Sum(v => v.Announcements),
            AppState.SignIn.Reads, client?.FirstReads ?? 0);
        var fromClient = new[] { client?.Rpc.CaptureState(), client?.CaptureBots(), client?.Rpc.CaptureRetry() };
        try
        {
            // Ordinary controls use the very same view, clock, subscribers and sign-in reader as the late deliveries.
            if (offline != null)
            {
                Assert.True(offline.Clock.IsEnabled);
                var paints = offline.Paints; offline.Clock.CaptureTick()(); Assert.Equal(paints + 1, offline.Paints);
                var announcements = offline.Announcements; offline.Announcement("fixture"); Assert.Equal(announcements + 1, offline.Announcements);
                offline.CaptureUnload()(); Assert.False(offline.Clock.IsEnabled);
                offline.CaptureLoad()(); Assert.True(offline.Clock.IsEnabled);
            }
            switch (mode)
            {
                case "status":
                    var count = ui.Timers.Count;
                    client!.Rpc.CaptureRetry()(); ui.Drain();
                    Assert.Equal(count + 1, ui.Timers.Count);
                    var status = ui.Timers.Last(); Assert.Equal(TimeSpan.FromMilliseconds(60), status.Interval);
                    var paints = offline!.Paints; status.TakeTick()(); Assert.Equal(paints + 1, offline.Paints);
                    client.Rpc.CaptureRetry()(); ui.Drain(); // another 60 ms refresh is armed at quit
                    break;
                case "retry":
                    var reads = AppState.SignIn.Reads;
                    var first = Assert.Single(ui.Timers, t => t.IsRunning && t.Interval == RetryLadder.Wait(0));
                    first.TakeTick()(); Assert.Equal(reads + 1, AppState.SignIn.Reads);
                    Assert.Single(ui.Timers, t => t.IsRunning && t.Interval == RetryLadder.Wait(1));
                    break;
                case "spinner":
                    // Render a live caption but keep the spinner itself armed. The drain will try it two ways.
                    Assert.Equal(3, ui.Timers.Count(t => t.IsRunning));
                    ui.Timers.Single(t => t.Interval == LaunchGate.Timing.Standard.Status).TakeTick()();
                    Assert.Equal(LaunchGate.StatusWords.Connecting, launch.Frames.Last().Status);
                    Assert.True(ui.Timers.Single(t => t.Interval == LaunchGate.Timing.Standard.Spinner).IsRunning);
                    break;
                case "content and settle":
                    Assert.Single(ui.Timers, t => t.IsRunning && t.Interval == LaunchGate.Timing.Standard.Content);
                    Assert.Single(ui.Timers, t => t.IsRunning && t.Interval == LaunchGate.Timing.Standard.Settle);
                    break;
            }
            if (client != null) Assert.Equal(3, Snap().ClientObservers);
            // Capturing a callback does NOT disarm its timer. Deliver both pre-posted work and genuinely new events.
            var ticks = ui.Timers.Where(t => t.IsRunning).Select(t => t.CaptureTick()).ToArray();
            var postedLoad = offline?.CaptureLoad(); var postedViewTick = offline?.Clock.CaptureTick();
            var postedAnnouncement = offline?.Announcement;
            foreach (var send in fromClient) send?.Invoke(); // handlers have already queued their UI continuations
            if (client != null) { Assert.Equal(3, ui.Count); client.Rpc.State = ConnectionState.Open; }
            var live = Snap();
            Snapshot? atBegin = null, stopped = null, exit = null;
            int done = 0, drains = 0, newPosts = -1, newPostsAtBegin = -1;
            Exception? callbackError = null;
            Task? overlapping = null;
            AppLog.Sink = (area, line) =>
            {
                if (area != "shutdown") return;
                if (line.StartsWith("shutdown (walk): begin,"))
                {
                    try
                    {
                        var queued = ui.Count;
                        foreach (var send in fromClient) send?.Invoke();
                        postedViewTick?.Invoke(); postedLoad?.Invoke(); postedAnnouncement?.Invoke("fixture");
                        launch.Retry(); launch.Different();
                        newPostsAtBegin = ui.Count - queued; atBegin = Snap();
                    }
                    catch (Exception e) { callbackError = e; }
                }
                if (line.Contains("launch flow timers: done")) { done++; stopped = Snap(); }
                if (!line.Contains("drain · let the UI thread settle: begin")) return;
                drains++;
                try
                {
                    overlapping = AppShutdown.RunAsync("overlapping close");
                    foreach (var timer in ui.Timers.Where(t => t.IsRunning).ToArray()) timer.TakeTick()();
                    foreach (var tick in ticks) tick();
                    postedLoad?.Invoke(); postedViewTick?.Invoke(); offline?.CaptureLoad()(); postedAnnouncement?.Invoke("fixture");
                    launch.Retry(); launch.Different();
                    int queued = ui.Count;
                    foreach (var send in fromClient) send?.Invoke();
                    client?.Rpc.CaptureState()(); client?.CaptureBots()(); client?.Rpc.CaptureRetry()();
                    newPosts = ui.Count - queued;
                    ui.Drain();
                }
                catch (Exception e) { callbackError = e; } // the coordinator deliberately ignores evidence-sink exceptions
            };
            await ShutdownPlan.FinishWalkAsync(() => Task.CompletedTask, () => AppShutdown.RunAsync("walk"), () => exit = Snap());
            Assert.Null(callbackError);
            Assert.NotNull(overlapping); await overlapping;
            await AppShutdown.RunAsync("second close");
            Assert.Equal((1, 1), (done, drains)); Assert.NotNull(stopped);
            Assert.Multiple(
                () => Assert.Equal(live, atBegin), () => Assert.Equal(0, newPostsAtBegin),
                () => Assert.Equal(live.Stops + live.Running, stopped.Stops),
                () => Assert.Equal(0, stopped.Running), () => Assert.Equal(0, stopped.TimerObservers),
                () => Assert.Equal(0, stopped.ClientObservers), () => Assert.Equal(0, stopped.ViewObservers),
                () => Assert.Equal(0, newPosts), () => Assert.Equal(stopped, exit), () => Assert.Equal(stopped, Snap()));
        }
        finally { AppLog.Sink = null; client?.Rpc.Ready.TrySetCanceled(); client?.Session.Reply.TrySetCanceled(); }
    }

    private sealed class HeldTurn : SynchronizationContext
    {
        private readonly Channel<Action> _posts = Channel.CreateUnbounded<Action>();
        public override void Post(SendOrPostCallback d, object? state) => _posts.Writer.TryWrite(() => InTurn(() => d(state)));
        internal void InTurn(Action run)
        {
            var saved = Current;
            try { SetSynchronizationContext(this); run(); }
            finally { SetSynchronizationContext(saved); }
        }
        internal Task<Action> Next() => _posts.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(10));
        internal Task<bool> HasTurn(CancellationToken ct) => _posts.Reader.WaitToReadAsync(ct).AsTask();
        internal async Task Finish(Task work)
        {
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var closed = work.ContinueWith(_ => _posts.Writer.TryComplete(), CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            await foreach (var deliver in _posts.Reader.ReadAllAsync(limit.Token)) deliver();
            await closed;
            await work;
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public Task AlreadyPostedOfflineSwitchCannotResumeSavedSignInAfterQuit(bool late) => FreshApp(nameof(CheckSwitch), late);

    private static async Task CheckSwitch(bool late)
    {
        var window = new MainWindow();
        LaunchFlow.ShowFixture(window, null);
        Assert.IsType<OfflineView>(window.Content);
        AppState.Gateways.Rows = [new("other", new("https://example.com"), "Fixture", "", null, "example.com", "", false, true, 0, false)];
        var held = new HeldTurn();
        Task pick = Task.CompletedTask;
        held.InTurn(() => pick = LaunchFlow.SwitchAsync("other", viaLaunch: true));
        // Its real row-display delay has finished. Hold the posted continuation just before the saved session read.
        var resume = await held.Next();
        Assert.False(pick.IsCompleted); Assert.Equal("other", AppState.Gateways.SwitchingTo);
        int? resumesAtStop = null; string? switchingAtSocket = null;
        bool socket = false;
        AppLog.Sink = (area, line) =>
        {
            if (area != "shutdown") return;
            if (line.Contains("launch flow timers: done")) resumesAtStop = AppState.SignIn.Resumes;
            if (line.Contains("gateway · gateway socket: begin")) { socket = true; switchingAtSocket = AppState.Gateways.SwitchingTo; }
        };
        try
        {
            var quit = late ? AppShutdown.RunAsync("close") : Task.CompletedTask;
            var socketBeforeDelivery = socket;
            resume(); await held.Finish(pick);
            if (!late) quit = AppShutdown.RunAsync("close");
            await quit.WaitAsync(TimeSpan.FromSeconds(10)); await AppShutdown.RunAsync("second close");
            // The inert saved reader always declines. Live: show the form. After quit: don't even call the reader.
            Assert.Equal(new[] { false }, AppState.Gateways.SwitchResults);
            Assert.Multiple(() => Assert.Equal(late ? 0 : 1, AppState.SignIn.Resumes),
                () => Assert.Equal(late ? 0 : 1, window.Sheets), () => Assert.Equal(late ? 0 : 1, resumesAtStop),
                () => Assert.False(socketBeforeDelivery), () => Assert.True(socket), () => Assert.Null(switchingAtSocket));
        }
        finally { AppLog.Sink = null; }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public Task PreferencePersistenceAndQuitUseTheSameUiQueue(bool quitFirst) => FreshApp(nameof(CheckPreferenceTurn), quitFirst);

    private static async Task CheckPreferenceTurn(bool quitFirst)
    {
        var client = new Client("fixture"); client.Rpc.Ready.SetResult();
        var ui = new HeldTurn();
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        using var writable = new ManualResetEventSlim();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        // LaunchChatMemory.SetResume takes the store lock before it writes. Park only that write, not the HTTP reply.
        AppState.LaunchChat.BeforePersist = () => { entered.TrySetResult(); writable.Wait(limit.Token); };
        try
        {
            ui.InTurn(() => LaunchFlow.ShowFixture(new MainWindow(), client));
            var read = LaunchFlow.PendingPreferences;
            var reading = client.Session.Reading.Task;
            await Task.WhenAny(reading, ui.HasTurn(limit.Token)).WaitAsync(limit.Token);
            if (!reading.IsCompleted) (await ui.Next())(); // the three-second delay's posted continuation
            await reading.WaitAsync(limit.Token);
            client.Session.Reply.SetResult(new JsonObject());
            // The reply reached either the waiting store or the pending UI callback. Neither has persisted it.
            await Task.WhenAny(entered.Task, ui.HasTurn(limit.Token)).WaitAsync(limit.Token);
            Assert.False(AppState.LaunchChat.Preference.Task.IsCompleted);
            Task quit = Task.CompletedTask;
            if (quitFirst) { ui.InTurn(() => quit = AppShutdown.RunAsync("close")); Assert.True(AppShutdown.Started); }
            writable.Set(); await ui.Finish(Task.WhenAll(quit, read));
            await AppShutdown.RunAsync("close");
            Assert.Equal(!quitFirst, entered.Task.IsCompleted);
            Assert.Equal(!quitFirst, AppState.LaunchChat.Preference.Task.IsCompletedSuccessfully);
        }
        finally { writable.Set(); AppState.LaunchChat.BeforePersist = null; }
    }

    [Theory]
    [InlineData("live")]
    [InlineData("waiting for ready")]
    [InlineData("read in flight")]
    [InlineData("read past deadline")]
    public Task ResumePreferenceBelongsToTheLaunchWatch(string delivery) => FreshApp(nameof(CheckPreference), delivery);

    private static async Task CheckPreference(string delivery)
    {
        var client = new Client("fixture");
        LaunchFlow.ShowFixture(new MainWindow(), client);
        var limit = TimeSpan.FromSeconds(10);
        try
        {
            var waiting = await client.Rpc.Waiting.Task.WaitAsync(limit);
            var read = LaunchFlow.PendingPreferences;
            if (delivery != "waiting for ready") client.Rpc.Ready.SetResult();
            var reading = delivery == "waiting for ready" ? default : await client.Session.Reading.Task.WaitAsync(limit);
            if (delivery == "live")
            {
                client.Session.Reply.SetResult(JsonNode.Parse("""{"display":{"resume_last_session":false}}""")!);
                Assert.False(await AppState.LaunchChat.Preference.Task.WaitAsync(limit));
            }
            var quitNotes = new List<string>();
            AppLog.Sink = (area, line) => { if (area == "shutdown") quitNotes.Add(line); };
            var quit = AppShutdown.RunAsync("close");
            if (delivery is "read in flight" or "read past deadline")
            {
                // A mere !quit.IsCompleted would also pass if the coordinator had skipped the join and reached its drain delay.
                Assert.True(reading.IsCancellationRequested);
                Assert.DoesNotContain(quitNotes, line => line.Contains("gateway · gateway socket: begin"));
                if (delivery == "read past deadline")
                {
                    await quit.WaitAsync(limit);
                    Assert.False(read.IsCompleted);
                    Assert.Single(quitNotes, line => line.Contains("launch flow timers: still running after"));
                }
                client.Session.Reply.SetResult(new JsonObject());
            }
            await quit.WaitAsync(limit); await AppShutdown.RunAsync("second close");
            await read.WaitAsync(limit);
            Assert.Single(quitNotes, line => line.Contains("gateway · gateway socket: begin"));
            Assert.Equal(delivery != "read past deadline", quitNotes.Any(line => line.Contains("launch flow timers: done")));
            if (delivery == "waiting for ready") Assert.True(waiting.IsCancellationRequested);
            Assert.Equal(delivery == "live", AppState.LaunchChat.Preference.Task.IsCompleted);
            Assert.Equal(delivery == "waiting for ready" ? 0 : 1, client.Session.Reads);
        }
        finally { AppLog.Sink = null; client.Rpc.Ready.TrySetCanceled(); client.Session.Reply.TrySetCanceled(); }
    }
}
