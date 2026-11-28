// [quick-actions] Send a Message and Run Job tiles, as QuickActionsRouter.run runs them at 93f984bb1: the routing
// decisions on Windows (QuickTileRules.Windows), Run Job through Run Now's calls with the 15 s wait and the Mac's
// refusal words (ShortcutGateway.refusal), the jobs a tile can find, Set Up's Job picker, and delivering the words
// once the chat is on show. Synthetic data only; the stand-in runs are QuickTileRunEndToEndTests.
using System.Text.Json.Nodes;
using Hermes.Core.Jobs;
using Hermes.Core.Net;
using Hermes.Core.QuickActions;

namespace Hermes.Core.Tests;

public class QuickTileRunTests
{
    private static readonly QuickTileWorld Otto = new(
        Bots: new Dictionary<string, string> { ["otto"] = "Otto" },
        Jobs: new HashSet<string> { "otto|nightly" },
        Pages: new Dictionary<string, string>());

    private static QuickTile Tile(QuickTileKind kind, string? bot = "otto") =>
        QuickTile.Create(kind, id: "t1") with { Bot = bot, BotName = bot == null ? null : "Otto" };

    private sealed class FakeApi() : JobsApi(null!)
    {
        public List<(string Method, string Path, string? Profile, TimeSpan? Timeout)> Calls { get; } = [];
        public Func<HttpMethod, string, JsonNode?> Answer { get; set; } = (_, _) => null;

        public override Task<JsonNode?> SendAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            var profile = query?.FirstOrDefault(q => q.Key == "profile").Value;
            lock (Calls) Calls.Add((method.Method, path, profile, timeout));
            return Task.FromResult(Answer(method, path));
        }
    }

    [Fact]
    public void WindowsRoutesSendAndRunJobAsTheMac()
    {
        var runs = QuickTileRules.Windows;
        Assert.Contains(QuickTileKind.Send, runs);
        Assert.Contains(QuickTileKind.RunJob, runs);
        // Open the Chat on: the bot's own chat, the words sent there; off: the background send, the page stays.
        var open = QuickTileRoute.Make(Tile(QuickTileKind.Send) with { Message = "status?", Flag = true }, Otto, runs);
        Assert.Equal(new QuickTileRoute.SendInChat("otto", "status?"), open);
        Assert.False(open.StaysOnPage);
        var background = QuickTileRoute.Make(Tile(QuickTileKind.Send) with { Message = "status?", Flag = false }, Otto, runs);
        Assert.Equal(new QuickTileRoute.SendInBackground("otto", "status?"), background);
        Assert.True(background.StaysOnPage);
        Assert.Equal(new QuickTileRoute.Unavailable("Add the words to send in Edit."),
            QuickTileRoute.Make(Tile(QuickTileKind.Send) with { Message = " " }, Otto, runs));
        Assert.Equal(new QuickTileRoute.Unavailable("Herald isn’t on this gateway."),
            QuickTileRoute.Make(Tile(QuickTileKind.Send, "herald") with { BotName = "Herald", Message = "hi" }, Otto, runs));
        // Run Job: the job by its key and name; the page stays and says what happened.
        var job = QuickTileRoute.Make(Tile(QuickTileKind.RunJob, null) with { Job = "otto|nightly", JobName = "Nightly" }, Otto, runs);
        Assert.Equal(new QuickTileRoute.RunJob("otto|nightly", "Nightly"), job);
        Assert.True(job.StaysOnPage);
        Assert.Equal(new QuickTileRoute.Unavailable("“Backup” isn’t on this gateway."),
            QuickTileRoute.Make(Tile(QuickTileKind.RunJob, null) with { Job = "otto|gone", JobName = "Backup" }, Otto, runs));
        Assert.Equal(new QuickTileRoute.Unavailable("Choose a job for this action in Edit."),
            QuickTileRoute.Make(Tile(QuickTileKind.RunJob, null), Otto, runs));
        // Jobs not known yet: never "missing".
        Assert.Equal(new QuickTileRoute.RunJob("otto|gone", "Backup"),
            QuickTileRoute.Make(Tile(QuickTileKind.RunJob, null) with { Job = "otto|gone", JobName = "Backup" }, Otto with { Jobs = null }, runs));
        // Voice Memo and Talk now have Windows routes too.
        Assert.Equal(new QuickTileRoute.Memo("otto"), QuickTileRoute.Make(Tile(QuickTileKind.Memo), Otto, runs));
        Assert.Equal(new QuickTileRoute.Talk("otto"), QuickTileRoute.Make(Tile(QuickTileKind.Talk), Otto, runs));
        // Add Action offers the full Chats & Work sets on Windows.
        var groups = QuickActionChoice.Groups(QuickActionChoice.Pages([]), runs: runs);
        Assert.Equal(["New Chat", "Voice Memo", "Talk", "Send a Message", "Open a Chat"], groups[0].Rows.Select(r => r.Title));
        Assert.Equal(["Add Task", "Run Job"], groups[1].Rows.Select(r => r.Title));
    }

    [Fact]
    public void TheJobsATileFindsAreTheWholeGatewaysOnly()
    {
        var jobs = new List<CronJob> { new("nightly") { Profile = "otto" }, new("sweep") { Profile = "" } };
        Assert.Equal(new HashSet<string> { "otto|nightly", "default|sweep" }, QuickTileRun.WorldJobs(jobs));
        Assert.Null(QuickTileRun.WorldJobs(null));
        Assert.Null(QuickTileRun.WorldJobs([]));
        Assert.Null(QuickTileRun.WorldJobs(jobs, scope: "otto"));
        Assert.Equal(("otto", "nightly"), QuickTileRun.Job("otto|nightly", jobs));
        Assert.Null(QuickTileRun.Job("otto|gone", jobs));
        // Before the list is known, the key itself (`<owner>|<id>`; an id may hold "|").
        Assert.Equal(("otto", "a|b"), QuickTileRun.Job("otto|a|b", null));
        Assert.Null(QuickTileRun.Job("nobar", null));
        Assert.Null(QuickTileRun.Job("otto|", null));
    }

    [Fact]
    public async Task RunJobIsRunNowWithTheFifteenSecondWait()
    {
        var api = new FakeApi { Answer = (_, _) => JsonNode.Parse("""{"id":"nightly","profile":"otto","enabled":true}""") };
        var said = await QuickTileRun.RunJobAsync(api, "otto", "nightly", "Nightly");
        Assert.Equal(new QuickTileSaid.Done("Running Nightly"), said);
        Assert.Equal([("GET", "/api/cron/jobs/nightly", "otto"), ("POST", "/api/cron/jobs/nightly/trigger", "otto")],
            api.Calls.Select(c => (c.Method, c.Path, c.Profile)));
        Assert.Equal(TimeSpan.FromSeconds(15), api.Calls[1].Timeout);
        Assert.Equal(TimeSpan.FromSeconds(15), QuickTileRun.JobTimeout);

        // A paused job runs once and is paused again.
        var paused = new FakeApi { Answer = (_, _) => JsonNode.Parse("""{"id":"nightly","profile":"otto","enabled":false,"state":"paused"}""") };
        Assert.Equal(new QuickTileSaid.Done("Running Nightly"), await QuickTileRun.RunJobAsync(paused, "otto", "nightly", "Nightly"));
        Assert.Contains(paused.Calls, c => c is ("POST", "/api/cron/jobs/nightly/pause", "otto", _));
    }

    [Fact]
    public async Task RunJobCountsASlowTriggerAsStartedAndSaysARefusalInTheGatewaysWords()
    {
        JsonNode? Answer(HttpMethod m, string p, GatewayException? trigger) =>
            p.EndsWith("/trigger", StringComparison.Ordinal) && trigger != null ? throw trigger : JsonNode.Parse("""{"id":"n","profile":"otto"}""");
        async Task<QuickTileSaid> Run(GatewayException e) =>
            await QuickTileRun.RunJobAsync(new FakeApi { Answer = (m, p) => Answer(m, p, e) }, "otto", "n", "Nightly");

        Assert.Equal(new QuickTileSaid.Done("Running Nightly"), await Run(new GatewayException("timeout", "slow")));
        Assert.Equal(new QuickTileSaid.Failed("That’s already running."), await Run(new GatewayException("http", "x", 409, "{}")));
        Assert.Equal(new QuickTileSaid.Failed("Job is already running"), await Run(new GatewayException("http", "x", 409, """{"detail":"Job is already running"}""")));
        Assert.Equal(new QuickTileSaid.Failed("No room"), await Run(new GatewayException("http", "x", 500, """{"detail":{"message":"No room"}}""")));
        Assert.Equal(new QuickTileSaid.Failed("bad"), await Run(new GatewayException("http", "x", 400, """{"error":"bad"}""")));
        Assert.Equal(new QuickTileSaid.Failed("Your gateway didn’t accept the job (502)."), await Run(new GatewayException("http", "x", 502, "<html>")));
        Assert.Equal(new QuickTileSaid.Failed("Your gateway doesn’t have the job. Update the Hermes HQ add-on, or open Hermes HQ to check."),
            await Run(new GatewayException("http", "x", 404, """{"detail":"Job not found"}""")));
        Assert.Equal(new QuickTileSaid.Failed(JobErrors.CantReach), await Run(new GatewayException("offline", "x")));
    }

    [Fact]
    public void SetUpsJobPickerFollowsTheMacsDraft()
    {
        var jobs = new List<(string, string)> { ("otto|nightly", "Nightly"), ("otto|sweep", "Sweep"), ("otto|nightly", "Nightly") };
        var fresh = QuickTile.Create(QuickTileKind.RunJob, id: "j");
        Assert.Equal(["otto|nightly", "otto|sweep"], QuickTileRun.JobChoices(fresh, jobs).Select(j => j.Key));
        // A saved job no longer listed stays choosable, named as it was saved.
        var gone = fresh with { Job = "otto|old", JobName = "Old one" };
        Assert.Equal(("otto|old", "Old one"), QuickTileRun.JobChoices(gone, jobs)[^1]);
        var choices = QuickTileRun.JobChoices(fresh, jobs);
        // A new tile starts on the first job, named for it; the name follows the pick until one is typed.
        var first = QuickTileRun.PickJob(fresh, choices[0].Key, choices, nameTouched: false);
        Assert.Equal(("otto|nightly", "Nightly", "Nightly"), (first.Job, first.JobName, first.Name));
        var second = QuickTileRun.PickJob(first, "otto|sweep", choices, nameTouched: false);
        Assert.Equal(("otto|sweep", "Sweep", "Sweep"), (second.Job, second.JobName, second.Name));
        var typed = QuickTileRun.PickJob(second with { Name = "Mine" }, "otto|nightly", choices, nameTouched: true);
        Assert.Equal(("otto|nightly", "Mine"), (typed.Job, typed.Name));
        var none = QuickTileRun.PickJob(first, "", choices, nameTouched: false);
        Assert.Null(none.Job);
        Assert.False(QuickTileDraft.CanSave(none));
        Assert.True(QuickTileDraft.CanSave(first));
    }

    [Fact]
    public async Task TheWordsGoOnceTheChatIsOnShowWithinEightSeconds()
    {
        var tries = 0;
        Assert.True(await QuickTileRun.DeliverAsync(() => ++tries == 3, step: TimeSpan.FromMilliseconds(1)));
        Assert.Equal(3, tries);
        tries = 0;
        Assert.False(await QuickTileRun.DeliverAsync(() => { tries++; return false; }, tries: 5, step: TimeSpan.FromMilliseconds(1)));
        Assert.Equal(5, tries);
        Assert.Equal("Hermes HQ couldn’t confirm the message arrived. Check Otto’s chat before running the shortcut again.",
            QuickTileRun.MessageUnconfirmed("Otto"));
        Assert.Equal("Your gateway didn’t accept the message.", QuickTileRun.MessageRefused);
    }

    /// [WIN-33] The check runs where the click was (the UI thread): it reads the chat page, which only that thread may.
    /// CI run 44989322637: the second try ran on a pool thread, threw, and the tile sent nothing.
    [Fact]
    public async Task EveryTryRunsOnTheCallersThread()
    {
        using var ui = new MainLoop();
        var threads = new List<int>();
        var owner = 0;
        var done = await ui.RunAsync(() =>
        {
            owner = Environment.CurrentManagedThreadId;
            return QuickTileRun.DeliverAsync(() =>
            {
                threads.Add(Environment.CurrentManagedThreadId);
                return threads.Count == 4;
            }, step: TimeSpan.FromMilliseconds(5));
        }).WaitAsync(TimeSpan.FromSeconds(10));
        Assert.True(done);
        Assert.Empty(ui.Failures);
        Assert.Equal(4, threads.Count);
        Assert.All(threads, t => Assert.Equal(owner, t));
    }
}
