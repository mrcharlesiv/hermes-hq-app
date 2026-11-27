using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Insights;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// Star Map against the More pages' stand-in (windows/ci/fixtures/morepages-gateway.py, its learning.py module): the
/// graph per bot with its bad rows skipped, the node text with its front matter, a node that is gone (404), a failed
/// read, an empty graph, and an older Hermes. Run through windows/scripts/e2e.sh (HQW_E2E_INSIGHTS_STARMAP); without it
/// these pass vacuously.
[Trait("Category", "E2E")]
[Collection(StarMapFirstOpenEndToEndTests.StandIn)]   // [WIN-STAR-FIRST] one stand-in, its knobs set by one test at a time
public class InsightsStarMapEndToEndTests
{
    private static async Task<JsonNode> Post(string url, string path, object body)
    {
        using var http = new HttpClient();
        var content = new StringContent(System.Text.Json.JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json");
        var r = await http.PostAsync(url.TrimEnd('/') + path, content);
        r.EnsureSuccessStatusCode();
        return JsonNode.Parse(await r.Content.ReadAsStringAsync())!;
    }

    /// Retries `read` until `ok` holds or the deadline passes (the Windows build machine is slow).
    private static async Task<T> Until<T>(Func<Task<T>> read, Func<T, bool> ok, int seconds = 20)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (true)
        {
            try
            {
                var value = await read();
                if (ok(value)) return value;
            }
            catch (Exception) when (DateTime.UtcNow < until) { }
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(100);
        }
    }

    [Fact]
    public async Task TheGraphTheNodesAndTheFailures()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_INSIGHTS_STARMAP");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        await Post(url, "/__fixture/graph", new { nodes = 60, memory = 40, delay = 0, fail = (object?)null });

        var signIn = new SignIn(new MemoryTokenStore());
        var session = await signIn.PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);

        // The default bot: 60 skills (12 categories) and 40 memories; the duplicate and id-less rows and the edge to
        // nowhere are skipped.
        var graph = await Until(() => StarMapApi.GraphAsync(session, "default"), g => g.Nodes.Count > 0);
        Assert.Equal(100, graph.Nodes.Count);
        Assert.Equal(graph.Nodes.Count, graph.Nodes.Select(n => n.Id).Distinct().Count());
        Assert.Equal(40, graph.Memory.Count);
        Assert.All(graph.Edges, e => Assert.Contains(graph.Nodes, n => n.Id == e.Source));
        var sections = StarMapRules.Sections(graph.Nodes, StarMapFilter.All);
        Assert.Equal("60 skills across 12 categories", StarMapRules.Subtitle(sections));
        var shown = StarMapShown.Make(graph, StarMapFilter.All, 1);
        Assert.Equal(13, shown.Layout.Clusters.Count);   // 12 categories and Memory
        Assert.Contains(shown.Layout.Clusters, c => c.IsMemory && c.Title == "Memory");
        Assert.True(graph.Memory[3].Body.Length > 19_000);
        Assert.True(StarMapRules.Folds(graph.Memory[3].Body));

        // Another bot has its own, smaller map.
        var inbox = await StarMapApi.GraphAsync(session, "inbox");
        Assert.True(inbox.Nodes.Count(n => n.Kind == StarMapKind.Skill) == 24);
        Assert.Equal(5, StarMapRules.Sections(inbox.Nodes, StarMapFilter.All).Count);

        // A skill's text: Markdown after its front matter.
        var skill = graph.Nodes.First(n => n.Kind == StarMapKind.Skill && n.Id != "retired-notes");
        var detail = await StarMapApi.NodeAsync(session, skill.Id, "default");
        var text = StarMapNodeDetail.StripFrontMatter(detail.Content);
        Assert.StartsWith("# ", text);
        Assert.DoesNotContain("description:", text);
        Assert.StartsWith("---", detail.Content);
        // A memory's text.
        var memory = graph.Nodes.First(n => n.Kind == StarMapKind.Memory);
        Assert.Contains("note", (await StarMapApi.NodeAsync(session, memory.Id, null)).Content);
        // A node that is gone: told from a failure.
        var gone = await Assert.ThrowsAsync<GatewayException>(() => StarMapApi.NodeAsync(session, "retired-notes", "default"));
        Assert.True(StarMapApi.IsMissing(gone));

        // A failed read says the gateway's reason.
        await Post(url, "/__fixture/graph", new { fail = new { status = 500, count = 1, detail = "Failed to build learning graph" } });
        var failed = await Assert.ThrowsAsync<GatewayException>(() => StarMapApi.GraphAsync(session, "default"));
        Assert.False(StarMapApi.IsMissing(failed));
        Assert.Equal("Failed to build learning graph", InsightsWire.Reason(failed));
        // The next read works again.
        Assert.Equal(100, (await Until(() => StarMapApi.GraphAsync(session, "default"), g => g.Nodes.Count > 0)).Nodes.Count);

        // Nothing learned yet.
        await Post(url, "/__fixture/graph", new { nodes = 0 });
        Assert.True((await StarMapApi.GraphAsync(session, "default")).IsEmpty);

        // A large map lays out.
        await Post(url, "/__fixture/graph", new { nodes = 2000, memory = 40 });
        var big = await Until(() => StarMapApi.GraphAsync(session, "default"), g => g.Nodes.Count > 2000, 40);
        var layout = StarMapShown.Make(big, StarMapFilter.All, 2).Layout;
        Assert.Equal(big.Nodes.Count, layout.Stars.Count);
        Assert.True(layout.Whole(900, 600).Scale > 0.02);

        await Post(url, "/__fixture/graph", new { nodes = 60, memory = 40 });
    }
}
