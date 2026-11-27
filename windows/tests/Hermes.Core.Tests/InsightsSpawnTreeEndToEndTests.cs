using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Insights;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// Spawn Tree against windows/ci/fixtures/morepages-gateway.py (its delegation module): every bot's
/// `delegation.status` with `{"profile"?}` only, the tree built with the chats' titles, paused, empty, a refused read
/// keeping the last tree, and an older Hermes. Run through windows/scripts/e2e.sh (HQW_E2E_INSIGHTS_SPAWN); without
/// it these pass vacuously.
[Trait("Category", "E2E")]
public class InsightsSpawnTreeEndToEndTests
{
    private static async Task<JsonNode> Post(string url, string path, object body)
    {
        using var http = new HttpClient();
        var content = new StringContent(System.Text.Json.JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json");
        var r = await http.PostAsync(url.TrimEnd('/') + path, content);
        r.EnsureSuccessStatusCode();
        return JsonNode.Parse(await r.Content.ReadAsStringAsync())!;
    }

    private static async Task<JsonNode> Get(string url, string path)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + path))!;
    }

    /// Reads until `done` holds, or fails after `seconds`.
    private static async Task Until(Func<Task<bool>> done, int seconds = 20)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!await done())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(200);
        }
    }

    [Fact]
    public async Task EveryBotsSubagentsGroupedByChat()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_INSIGHTS_SPAWN");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        await Post(url, "/__fixture/delegation", new { mode = "seed", delay = 0 });
        try
        {
            var signIn = new SignIn(new MemoryTokenStore());
            var session = await signIn.PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
            await using var client = new HermesClient(session);
            await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(20)).Token);
            var bots = await client.BotsAsync();
            var profiles = bots.OrderBy(b => b.Name == "default" ? 0 : 1).Select(b => b.Name).ToList();
            Assert.Contains("deploys", profiles);
            var sessions = SpawnTreeLoader.Sessions(await client.SessionsAsync());
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(60));
            var loader = new SpawnTreeLoader();

            await Until(async () => { await loader.ReadAsync(client, profiles, sessions, cts.Token); return loader.State == SpawnTreeLoader.Load.Ready; });
            var tree = loader.Tree;
            Assert.Equal(14, tree.Total);
            Assert.False(tree.Paused);
            var deploys = tree.Bots.Single(b => b.Id == "deploys");
            var release = deploys.Chats.Single(c => c.SessionId == "s-release");
            Assert.Equal("Ship the 2.4 release notes", release.Title);
            Assert.Equal(["sa-r7", "sa-r8", "sa-r1", "sa-r2", "sa-r3", "sa-r4", "sa-r5", "sa-r6"], release.Rows.Select(r => r.Record.Id));
            Assert.Equal([0, 1, 0, 1, 2, 2, 1, 2], release.Rows.Select(r => r.Level));
            Assert.StartsWith("Opus 5 · 7 tools · running ", SpawnTree.Detail(release.Rows[3].Record, loader.Now));
            Assert.Equal("research", tree.Bots.Single(b => b.Chats.Any(c => c.SessionId == "s-reading")).Id);

            // Only `profile`, and only for named bots (Hermes answers 4000 for any other key; the fixture checks).
            var state = await Get(url, "/__fixture/state");
            var calls = (state.Arr("rpc") ?? []).OfType<JsonNode>().Where(c => c.Str("method") == "delegation.status").ToList();
            Assert.NotEmpty(calls);
            Assert.All(calls, c => Assert.True(c.Obj("params")!.Count == 0 || (c.Obj("params")!.Count == 1 && c.Obj("params")!.Text("profile") != "default")));

            // Paused.
            await Post(url, "/__fixture/delegation", new { mode = "paused" });
            await Until(async () => { await loader.ReadAsync(client, profiles, sessions, cts.Token); return loader.Tree.Paused; });

            // A refused read keeps the last tree.
            await Post(url, "/__fixture/delegation", new { mode = "error" });
            await Until(async () => { await loader.ReadAsync(client, profiles, sessions, cts.Token); return loader.RefreshFailed; });
            Assert.Equal(SpawnTreeLoader.Load.Ready, loader.State);
            Assert.Equal(14, loader.Tree.Total);

            // A first read refused: the reason in words.
            var fresh = new SpawnTreeLoader();
            await fresh.ReadAsync(client, profiles, sessions, cts.Token);
            Assert.Equal(SpawnTreeLoader.Load.Failed, fresh.State);
            Assert.Equal("The delegation registry is not available.", fresh.Reason);

            // Nothing running.
            await Post(url, "/__fixture/delegation", new { mode = "empty" });
            await Until(async () => { await loader.ReadAsync(client, profiles, sessions, cts.Token); return loader.State == SpawnTreeLoader.Load.Ready && loader.Tree.IsEmpty && !loader.RefreshFailed; });

            // A gateway that answers the whole list for every bot: each subagent once, under its chat's bot.
            await Post(url, "/__fixture/delegation", new { mode = "global" });
            await Until(async () => { await loader.ReadAsync(client, profiles, sessions, cts.Token); return loader.Tree.Total == 14; });
            Assert.Equal(10, loader.Tree.Bots.Single(b => b.Id == "deploys").Count);

            // Orphans, cycles and odd fields still make a tree.
            await Post(url, "/__fixture/delegation", new { mode = "odd" });
            await Until(async () => { await loader.ReadAsync(client, profiles, sessions, cts.Token); return loader.Tree.Records.Any(r => r.Id == "sa-o1"); });
            Assert.Contains(loader.Tree.Records, r => r.Id == "9" && r.ToolCount == 4);

            // An older Hermes.
            await Post(url, "/__fixture/delegation", new { mode = "missing" });
            await Until(async () => { await loader.ReadAsync(client, profiles, sessions, cts.Token); return loader.State == SpawnTreeLoader.Load.Older; });
        }
        finally
        {
            await Post(url, "/__fixture/delegation", new { mode = "seed", delay = 0 });
        }
    }
}
