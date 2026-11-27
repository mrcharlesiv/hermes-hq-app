using System.Collections.Concurrent;
using Hermes.Core.Gateways;
using Hermes.Core.Shell;
using HermesHQ;
using HermesHQ.Features.Gateways;
using HermesHQ.Features.Jobs;
using HermesHQ.Features.Settings;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage.Streams;

namespace Hermes.Core.Tests;

[Collection("Shutdown UI")]
public class RegisteredOwnerShutdownTests
{
    // Queue the continuation of an actual PlayAsync render, then explicitly dispatch it on the fixture UI.
    // No sleeps and no racing an async-void method against the coordinator's drain delay.
    private sealed class HeldUi : SynchronizationContext
    {
        private readonly BlockingCollection<Action> _posts = new();
        public override void Post(SendOrPostCallback callback, object? state) => _posts.Add(() => callback(state));

        internal static Action HoldRender(int variant)
        {
            var ui = new HeldUi();
            using var render = new ManualResetEventSlim();
            var previous = Current;
            Task pending;
            try
            {
                CompletionSoundSynth.Hold = render;
                SetSynchronizationContext(ui);
                pending = CompletionCue.PlayAsync(variant);
            }
            finally { SetSynchronizationContext(previous); render.Set(); }
            var posted = ui._posts.TryTake(out var deliver, TimeSpan.FromSeconds(10));
            CompletionSoundSynth.Hold = null;
            Assert.True(posted && !pending.IsCompleted, "The live render did not reach the held UI continuation.");
            return () => { deliver!(); Assert.True(pending.IsCompletedSuccessfully); };
        }
    }

    private sealed record Snapshot(int Players, int Plays, int Disposals, int Sources, int ClosedSources,
        bool BadgeRunning, int BadgeStarts, int Refreshes, bool NewsRunning, int NewsStarts, int Checks, int Activations)
    {
        internal static Snapshot Read(DispatcherQueueTimer badge, DispatcherQueueTimer news) =>
            new(MediaPlayer.Created, MediaPlayer.Plays, MediaPlayer.Disposals, MediaSource.Created, MediaSource.Disposals,
                badge.IsRunning, badge.Starts, JobsServices.Store.Refreshes, news.IsRunning, news.Starts,
                AppState.Gateways.Checks, AppState.Gateways.Activations);
    }

    private static async Task CheckLivePlaybackAsync()
    {
        await CompletionCue.PlayAsync(1);
        HeldUi.HoldRender(2)();
        CompletionCue.Preview(2); // cached WAV, same player, another playback
        Assert.Equal([1, 2, 2], MediaPlayer.Variants);
        Assert.Equal(2, CompletionSoundSynth.Renders);
        var current = Assert.IsType<MediaSource>(MediaPlayer.Current?.Source);
        try
        {
            MediaSource.RefuseCreate = true; await CompletionCue.PlayAsync(2); MediaSource.RefuseCreate = false;
            MediaPlayer.RefuseBind = true; await CompletionCue.PlayAsync(2);
        }
        finally { MediaSource.RefuseCreate = false; MediaPlayer.RefuseBind = false; }
        Assert.Same(current, MediaPlayer.Current?.Source);
        Assert.True(current.Open);
        Assert.Equal((1, 3), (MediaPlayer.Created, MediaPlayer.Plays));
        Assert.Equal((4, 3), (MediaSource.Created, MediaSource.Disposals));
        Assert.Equal((5, 4), (FixtureStream.Opened, FixtureStream.Closed));
    }

    [Fact]
    public async Task LiveCuesBadgeAndNewsWorkButCannotResumeDuringOrAfterTheirQuitPass()
    {
        var window = App.Window = new Window();
        var ui = window.DispatcherQueue;
        AppState.Client = new("fixture-" + Guid.NewGuid().ToString("N"));
        try
        {
            JobsSidebarBadge.Register();
            GatewaysFeature.RegisterNews();
            AppState.NotifyClient();
            ui.Drain();
            Assert.Equal(2, ui.Timers.Count);
            var (badge, news) = (ui.Timers[0], ui.Timers[1]);
            Assert.Equal((1, 1, 1, 1, 2), (badge.Subscribers, news.Subscribers, window.Subscribers, JobsServices.Store.Subscribers, AppState.Subscribers));
            var starts = badge.Starts;
            JobsServices.Store.Notify();
            ui.Drain();
            Assert.Equal(starts + 1, badge.Starts);
            Assert.True(badge.IsRunning);
            window.CaptureActivation(WindowActivationState.Deactivated)();
            Assert.Equal(0, AppState.Gateways.Activations);
            window.CaptureActivation()();
            news.TakeTick()();
            Assert.True(news.IsRunning);
            Assert.Equal(GatewayHub.Every, news.Interval);
            Assert.Equal((1, 1), (AppState.Gateways.Activations, AppState.Gateways.Checks));
            await CheckLivePlaybackAsync();

            var live = Snapshot.Read(badge, news);
            Assert.True(live.BadgeRunning && live.NewsRunning);
            var stopsBeforeQuit = (Badge: badge.Stops, News: news.Stops);
            var resume = HeldUi.HoldRender(3);
            var postedActivation = window.CaptureActivation();
            var badgeTick = badge.CaptureTick(); // quit must disarm the timers, not the fixture
            var newsTick = news.CaptureTick();
            JobsServices.Store.Notify();                        // change already posted to the UI
            AppState.NotifyClient();                           // an Attach can already be queued too
            ui.TryEnqueue(() => CompletionCue.Preview(2));     // cached variant, no async render
            Task? secondQuit = null;
            Snapshot? atStart = null, atDrain = null, atExit = null;
            int newlyQueuedAtStart = -1;
            Exception? deliveryError = null;
            var notes = new List<string>();
            AppLog.Sink = (area, line) =>
            {
                if (area != "shutdown") return;
                notes.Add(line);
                if (line.StartsWith("shutdown (walk): begin,"))
                {
                    var count = ui.Count;
                    window.CaptureActivation()(); JobsServices.Store.Notify(); AppState.NotifyClient(); CompletionCue.Preview(2);
                    newlyQueuedAtStart = ui.Count - count;
                    atStart = Snapshot.Read(badge, news);
                }
                if (!line.Contains("drain · let the UI thread settle: begin")) return;
                // Evidence writes are best effort. Capture any fixture error and assert OUTSIDE the note callback.
                try
                {
                    atDrain = Snapshot.Read(badge, news);
                    secondQuit = AppShutdown.RunAsync("overlapping quit");
                    resume();
                    postedActivation(); badgeTick(); newsTick(); // delegates captured before unsubscribe
                    window.CaptureActivation()();              // new events from the old publishers
                    AppState.NotifyClient(); JobsServices.Store.Notify();
                    ui.Drain();
                }
                catch (Exception e) { deliveryError = e; }
            };
            await ShutdownPlan.FinishWalkAsync(() => Task.CompletedTask, () => AppShutdown.RunAsync("walk"),
                () => atExit = Snapshot.Read(badge, news));
            Assert.Null(deliveryError);
            Assert.NotNull(secondQuit);
            await secondQuit;
            Assert.True(AppShutdown.Finished);
            Assert.NotNull(atDrain);
            Assert.NotNull(atExit);
            var stops = (badge.Stops, news.Stops);
            await AppShutdown.RunAsync("second close");
            JobsSidebarBadge.Register(); GatewaysFeature.RegisterNews(); // a late setup is no new owner
            CompletionCue.Preview(2); JobsServices.Store.Notify(); AppState.NotifyClient(); window.CaptureActivation()(); ui.Drain();
            var after = Snapshot.Read(badge, news);
            foreach (var step in new[] { "completion cue player", "jobs badge timer", "gateway news timer" })
                Assert.Single(notes, n => n.Contains(step + ": done"));
            Assert.Multiple(
                () => Assert.Equal(0, newlyQueuedAtStart),
                () => Assert.Equal(live, atStart),
                () => Assert.Equal((stopsBeforeQuit.Badge + 1, stopsBeforeQuit.News + 1), stops),
                () => Assert.Equal(2, ui.Timers.Count),
                () => Assert.Equal((0, 0, 0, 0, 0), (badge.Subscribers, news.Subscribers, window.Subscribers, JobsServices.Store.Subscribers, AppState.Subscribers)),
                () => Assert.Equal((1, live.Plays, 1), (atExit.Players, atExit.Plays, atExit.Disposals)),
                () => Assert.Equal(atExit.Sources, atExit.ClosedSources),
                () => Assert.Equal((5, 5), (FixtureStream.Opened, FixtureStream.Closed)),
                () => Assert.Equal(3, CompletionSoundSynth.Renders),
                () => Assert.Equal((false, live.BadgeStarts, live.Refreshes), (atExit.BadgeRunning, atExit.BadgeStarts, atExit.Refreshes)),
                () => Assert.Equal((false, live.NewsStarts, 1, 1), (atExit.NewsRunning, atExit.NewsStarts, atExit.Checks, atExit.Activations)),
                () => Assert.Equal(atDrain, atExit),
                () => Assert.Equal(atExit, after),
                () => Assert.Equal(stops, (badge.Stops, news.Stops)));
        }
        finally { AppLog.Sink = null; App.Window = null; AppState.Client = null; }
    }
}
