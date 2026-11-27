using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Jobs;
using Hermes.Core.Net;
using Hermes.Core.QuickActions;
using static Hermes.Core.Tests.QuickTileStandIns;

namespace Hermes.Core.Tests;

/// [quick-actions] Send a Message and Run Job tiles against the stand-ins: the background send reaches the composer
/// stand-in's `prompt.submit` on the bot's own chat (composer-gateway.py), and Run Job reaches the jobs stand-in's
/// `/trigger` for the tile's job and owner, a paused job paused again, a slow trigger counted as started and a refusal
/// in the gateway's words (jobs-gateway.py). Run through windows/scripts/e2e.sh (HQW_E2E_COMPOSER_CREDENTIALS,
/// HQW_E2E_JOBS_CREDENTIALS); without them these pass vacuously. Every wait is a deadline of at least 10 s.
public static class QuickTileStandIns
{
    public static async Task Until(Func<Task<bool>> condition, int seconds = 15)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!await condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(100);
        }
    }

    public static async Task Post(string url, string path, object body)
    {
        using var http = new HttpClient();
        var content = new StringContent(System.Text.Json.JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json");
        (await http.PostAsync(url.TrimEnd('/') + path, content)).EnsureSuccessStatusCode();
    }

    public static async Task<JsonNode> Get(string url, string path)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + path))!;
    }

    public static async Task<(string Url, GatewaySession Session)> SignInAsync(string variable)
    {
        var path = Environment.GetEnvironmentVariable(variable);
        if (path == null || !File.Exists(path)) return ("", null!);
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        return (url, session);
    }

}

[Trait("Category", "E2E")]
[Collection(ComposerStandIn.Name)]
public class QuickTileSendEndToEndTests
{
    [Fact]
    public async Task SendAMessageReachesTheBotsOwnChat()
    {
        var (url, session) = await SignInAsync("HQW_E2E_COMPOSER_CREDENTIALS");
        if (url.Length == 0) return;
        await Post(url, "/__composer/reset", new { });
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        var bot = (await client.BotsAsync()).First(b => b.Name == "default");
        var chatId = await client.BotChatIdAsync(bot);

        // The tile as Set Up saves it, Open the Chat off: the background send, the page stays.
        var tile = QuickTile.Create(QuickTileKind.Send, id: "send-1") with { Bot = bot.Name, BotName = bot.DisplayName, Message = "status of the deploy?", Flag = false };
        var world = new QuickTileWorld(Bots: new Dictionary<string, string> { [bot.Name] = bot.DisplayName });
        var route = Assert.IsType<QuickTileRoute.SendInBackground>(QuickTileRoute.Make(tile, world, QuickTileRules.Windows));
        var said = await QuickTileRun.SendInBackgroundAsync(client, route.Profile, bot.DisplayName, ct => client.BotChatIdAsync(bot, ct), route.Words);
        Assert.Equal(new QuickTileSaid.Done($"Sent to {bot.DisplayName}"), said);

        // The stand-in took prompt.submit with the words, for the bot, on the session its own chat resumed.
        JsonNode? submit = null, resume = null;
        await Until(async () =>
        {
            var calls = (await Get(url, "/__menus/state")).Arr("calls") ?? [];
            submit = calls.OfType<JsonNode>().LastOrDefault(c => c.Str("method") == "prompt.submit" && c["params"].Str("text") == "status of the deploy?");
            resume = calls.OfType<JsonNode>().LastOrDefault(c => c.Str("method") == "session.resume" && c["params"].Str("session_id") == chatId);
            return submit != null && resume != null;
        });
        Assert.Equal("default", submit!["params"].Str("profile"));
        Assert.False(string.IsNullOrEmpty(submit["params"].Str("session_id")));
    }

}

[Trait("Category", "E2E")]
[Collection(JobsStandIn.Name)]
public class QuickTileRunJobEndToEndTests
{
    [Fact]
    public async Task RunJobReachesTheJobsTrigger()
    {
        var (url, session) = await SignInAsync("HQW_E2E_JOBS_CREDENTIALS");
        if (url.Length == 0) return;
        await Post(url, "/__fixture/reset", new { });
        using var store = new JobsStore(new JobsApi(session));
        await store.RefreshAsync();
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (!store.HasList && DateTime.UtcNow < deadline) await Task.Delay(100);
        Assert.True(store.HasList);
        var watch = store.Jobs.First(j => store.Title(j) == "Release watch");
        var world = new QuickTileWorld(Jobs: QuickTileRun.WorldJobs(store.Jobs, store.Scope));
        Assert.Contains(watch.Key, world.Jobs!);

        async Task<(QuickTileSaid Said, List<JsonNode> Triggers)> Tap(CronJob job, TimeSpan? timeout = null)
        {
            var tile = QuickTile.Create(QuickTileKind.RunJob, id: "job-" + job.Id) with { Job = job.Key, JobName = store.Title(job), Name = store.Title(job) };
            var route = Assert.IsType<QuickTileRoute.RunJob>(QuickTileRoute.Make(tile, world, QuickTileRules.Windows));
            var (owner, id) = QuickTileRun.Job(route.Key, store.Jobs)!.Value;
            var said = await QuickTileRun.RunJobAsync(store.Api, owner, id, route.Name, timeout);
            var requests = (await Get(url, "/__fixture/state")).Arr("requests") ?? [];
            var triggers = requests.OfType<JsonNode>()
                .Where(r => r.Str("method") == "POST" && r.Str("path") == JobsApi.JobPath(job.Id) + "/trigger").ToList();
            return (said, triggers);
        }

        // The tap reaches the trigger for the tile's job, named for its owner.
        var (said, triggers) = await Tap(watch);
        Assert.Equal(new QuickTileSaid.Done("Running Release watch"), said);
        Assert.Single(triggers);
        Assert.Equal(watch.Owner, triggers[0]["query"].Str("profile"));

        // A trigger still out after the wait has started (the stand-in's trigger takes 3 s).
        var slow = await Tap(watch, TimeSpan.FromSeconds(1));
        Assert.Equal(new QuickTileSaid.Done("Running Release watch"), slow.Said);
        Assert.Equal(2, slow.Triggers.Count);

        // A paused job runs once and is paused again.
        var paused = store.Jobs.First(j => store.Title(j) == "Nightly finance report");
        Assert.Equal(new QuickTileSaid.Done("Running Nightly finance report"), (await Tap(paused)).Said);
        await Until(async () => ((await Get(url, "/__fixture/state")).Arr("requests") ?? []).OfType<JsonNode>()
            .Any(r => r.Str("method") == "POST" && r.Str("path") == JobsApi.JobPath(paused.Id) + "/pause"));

        // A refusal in the gateway's own words.
        await Post(url, "/__fixture/fail", new { method = "POST", path = JobsApi.JobPath(watch.Id) + "/trigger", status = 409, detail = "Job is already running" });
        Assert.Equal(new QuickTileSaid.Failed("Job is already running"), (await Tap(watch)).Said);
    }
}

/// The tests that drive jobs-gateway.py one at a time (each resets it).
[CollectionDefinition(Name, DisableParallelization = true)]
public class JobsStandIn { public const string Name = "jobs stand-in"; }
