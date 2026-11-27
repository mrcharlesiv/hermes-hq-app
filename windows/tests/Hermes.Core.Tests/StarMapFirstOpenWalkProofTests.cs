using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Insights;
using Hermes.Core.Net;
using Hermes.Core.Shell;
using Proof = Hermes.Core.Shell.StarMapFirstOpenWalkProof;

namespace Hermes.Core.Tests;

/// [WIN-STAR-FIRST] The star-map-first-open walk's checks (Services/ProofWalks.StarMapFirstOpen.cs): each control passes
/// only with its own state from one read, and fails for the others' states, a retry, a second read or an empty map.
public class StarMapFirstOpenWalkProofTests
{
    private static Proof.Seen Seeded(string? id = Proof.MapId) => new("loaded", id, [], false, true,
        Proof.SeedSubtitle, 60, 40, 100, 150, 100, 150, 1, 0, "default");

    private static Proof.Seen Error() => new("failed", Proof.ErrorId, [Proof.ErrorTitle, Proof.FailDetail, "Try Again", "Copy Details"],
        true, true, null, 0, 0, 0, 0, 0, 0, 1, 0, "default");

    private static Proof.Seen Empty() => new("loaded", Proof.EmptyId,
        [Proof.EmptyTitle, "As Hermes builds skills and memories for your work, they appear here."], false, true, null, 0, 0, 0, 0, 0, 0, 1, 0, "default");

    private static Proof.Seen Unavailable() => new("failed", Proof.UnavailableId,
        [InsightsWire.NotAvailableTitle, InsightsWire.NotAvailableBody("Star Map")], false, false, null, 0, 0, 0, 0, 0, 0, 1, 0, "default");

    [Fact]
    public void FirstOpenIsRegisteredAndRequestedOnAFreshFixtureWithEveryPicture()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(Path.Combine(dir.FullName, "HermesHQ.sln"))) dir = dir.Parent;
        Assert.NotNull(dir);
        var services = Path.Combine(dir.FullName, "src", "HermesHQ.Windows", "Services");
        Assert.Contains("RegisterStarMapFirstOpenWalks();", File.ReadAllText(Path.Combine(services, "ProofWalks.cs")));
        var workflow = File.ReadAllLines(Path.Combine(dir.FullName, "ci", "windows.yml"));
        var fixture = Assert.Single(workflow, line => line.Contains($"walks = @(\"{Proof.Walk}\")", StringComparison.Ordinal));
        Assert.Contains("morepages-gateway.py", fixture);
        Assert.Contains("places = @()", fixture);
        var walk = File.ReadAllText(Path.Combine(services, "ProofWalks.StarMapFirstOpen.cs"));
        Assert.Contains($"Automation.NamedWalks[\"{Proof.Walk}\"]", walk);
        Assert.Contains($"await shot(\"{Proof.Walk}\");", walk); // the workflow requires one picture named for each walk as well
        foreach (var control in Proof.Order) Assert.Contains($"\"star-map-first-{Proof.Name(control)}\"", fixture);
    }

    [Fact]
    public void EachControlPassesWithItsOwnStateFromOneRead()
    {
        Assert.Equal("60 skills across 12 categories", Proof.SeedSubtitle);
        Assert.Null(Proof.Check(Proof.Control.Seeded, Seeded(), 4, 5));
        Assert.Null(Proof.Check(Proof.Control.Seeded, Seeded(Proof.ListId) with { DrawnStars = 0, DrawnEdges = 0 }, 4, 5));
        Assert.Null(Proof.Check(Proof.Control.Error, Error(), 5, 6));
        Assert.Null(Proof.Check(Proof.Control.Empty, Empty(), 6, 7));
        Assert.Null(Proof.Check(Proof.Control.Unsupported, Unavailable(), 7, 8));
        Assert.Null(Proof.Check(Proof.Control.Bare, Unavailable(), 8, 9));
    }

    [Fact]
    public void TheSeededOpeningFailsWithoutAPopulatedDrawnMap()
    {
        Assert.NotNull(Proof.Check(Proof.Control.Seeded, Unavailable(), 0, 1));     // run 45034520666's first visit
        Assert.NotNull(Proof.Check(Proof.Control.Seeded, Empty(), 0, 1));
        Assert.NotNull(Proof.Check(Proof.Control.Seeded, Seeded() with { DrawnStars = 0 }, 0, 1));
        Assert.NotNull(Proof.Check(Proof.Control.Seeded, Seeded() with { DrawnEdges = 0 }, 0, 1));
        Assert.NotNull(Proof.Check(Proof.Control.Seeded, Seeded() with { Skills = 0, Subtitle = "0 skills across 0 categories" }, 0, 1));
        Assert.NotNull(Proof.Check(Proof.Control.Seeded, Seeded() with { Stars = 60 }, 0, 1));
        Assert.NotNull(Proof.Check(Proof.Control.Seeded, Seeded() with { Phase = "loading", StateId = Proof.LoadingId }, 0, 1));
    }

    [Fact]
    public void ARetryOrASecondReadIsNotAFirstOpening()
    {
        Assert.Contains("retried", Proof.Check(Proof.Control.Seeded, Seeded() with { Retries = 1, PageReads = 2 }, 0, 2));
        Assert.Contains("2 times", Proof.Check(Proof.Control.Seeded, Seeded() with { PageReads = 2 }, 0, 2));
        Assert.Contains("answered 2", Proof.Check(Proof.Control.Seeded, Seeded(), 0, 2));
        Assert.Contains("answered 0", Proof.Check(Proof.Control.Error, Error(), 3, 3));
        Assert.NotNull(Proof.Check(Proof.Control.Seeded, Seeded(), -1, 1));
        Assert.Contains("bot inbox", Proof.Check(Proof.Control.Seeded, Seeded() with { Profile = "inbox" }, 0, 1));
    }

    [Fact]
    public void TheErrorEmptyAndUnavailableStatesAreNotInterchangeable()
    {
        Assert.NotNull(Proof.Check(Proof.Control.Error, Unavailable(), 0, 1));
        Assert.NotNull(Proof.Check(Proof.Control.Error, Error() with { StateTexts = [Proof.ErrorTitle, InsightsWire.CouldntDoThat] }, 0, 1));
        Assert.NotNull(Proof.Check(Proof.Control.Error, Error() with { RetryShown = false }, 0, 1));
        Assert.NotNull(Proof.Check(Proof.Control.Empty, Unavailable(), 0, 1));
        Assert.NotNull(Proof.Check(Proof.Control.Empty, Empty() with { RetryShown = true }, 0, 1));
        Assert.NotNull(Proof.Check(Proof.Control.Unsupported, Empty() with { Phase = "failed" }, 0, 1));
        Assert.NotNull(Proof.Check(Proof.Control.Unsupported, Error(), 0, 1));
        Assert.Contains("Bot picker", Proof.Check(Proof.Control.Unsupported, Unavailable() with { PickerShown = true }, 0, 1));
        Assert.NotNull(Proof.Check(Proof.Control.Bare, Unavailable() with { RetryShown = true }, 0, 1));

        var all = new Dictionary<Proof.Control, Proof.Seen>
        {
            [Proof.Control.Seeded] = Seeded(), [Proof.Control.Error] = Error(), [Proof.Control.Empty] = Empty(),
            [Proof.Control.Unsupported] = Unavailable(), [Proof.Control.Bare] = Unavailable(),
        };
        Assert.Null(Proof.Distinct(all));
        Assert.NotNull(Proof.Distinct(new Dictionary<Proof.Control, Proof.Seen>(all) { [Proof.Control.Empty] = Unavailable() }));
        Assert.NotNull(Proof.Distinct(new Dictionary<Proof.Control, Proof.Seen>(all) { [Proof.Control.Bare] = Empty() }));
        all.Remove(Proof.Control.Bare);
        Assert.Contains("no bare", Proof.Distinct(all));
    }

    /// What each control's answer decodes to with the page's own reading (StarMapApi.GetAsync → StarMapGraph.FromJson,
    /// InsightsWire.Reason): the states the walk expects follow from the wire, not from the walk.
    [Fact]
    public void EachControlsAnswerReadsAsItsState()
    {
        // Bare: 200 `{}` (the performance stand-in, run 45034520666 line 86) is "not available", as on the Mac.
        var bare = Assert.Throws<PagesMessageException>(() => StarMapGraph.FromJson(JsonNode.Parse("{}")));
        Assert.Equal(InsightsWire.OlderHermes, InsightsWire.Reason(bare));
        // Empty: a graph with no nodes is a graph, and empty.
        Assert.True(StarMapGraph.FromJson(JsonNode.Parse("""{"nodes":[],"edges":[],"memory":[]}""")).IsEmpty);
        // Unsupported: 404 Not Found is the missing route; Error: 500 says the gateway's reason.
        Assert.Equal(InsightsWire.OlderHermes, InsightsWire.Reason(new GatewayException("http", "Not Found", 404, """{"detail":"Not Found"}""")));
        Assert.Equal(Proof.FailDetail, InsightsWire.Reason(new GatewayException("http", "error", 500, $$"""{"detail":"{{Proof.FailDetail}}"}""")));
        Assert.Equal("Couldn’t Load Star Map", Proof.ErrorTitle);
    }

    [Fact]
    public void TheKnobsSetEveryControlFromScratch()
    {
        foreach (var c in Proof.Order)
        {
            var k = Proof.Knobs(c);
            foreach (var key in new[] { "nodes", "edges", "memory", "delay", "fail", "bare" }) Assert.True(k.ContainsKey(key), $"{c} {key}");
        }
        Assert.Equal(0, (int)Proof.Knobs(Proof.Control.Empty)["nodes"]!);
        Assert.Equal(500, (int)Proof.Knobs(Proof.Control.Error)["fail"]!["status"]!);
        Assert.Equal(404, (int)Proof.Knobs(Proof.Control.Unsupported)["fail"]!["status"]!);
        Assert.True((bool)Proof.Knobs(Proof.Control.Bare)["bare"]!);
        Assert.False((bool)Proof.Knobs(Proof.Control.Seeded)["bare"]!);
        Assert.Null(Proof.Knobs(Proof.Control.Seeded)["fail"]);
        Assert.Equal(7, Proof.Served(JsonNode.Parse("""{"learning":{"served":{"graph":7,"node":0}}}""")));
        Assert.Equal(-1, Proof.Served(JsonNode.Parse("{}")));
    }
}

/// [WIN-STAR-FIRST] The walk's controls against the real stand-in (morepages-gateway.py, learning.py): each knob set
/// makes ONE graph read answer what the walk expects to see, and the stand-in counts that one read. Run through
/// windows/scripts/e2e.sh (HQW_E2E_INSIGHTS_STARMAP); without it this passes vacuously.
[Trait("Category", "E2E")]
[Collection(StandIn)]
public class StarMapFirstOpenEndToEndTests
{
    /// The Star Map stand-in's tests share its knobs, so they don't run side by side.
    public const string StandIn = "star-map stand-in";

    private static async Task<JsonNode> Http(string url, string path, JsonObject? body = null)
    {
        using var http = new HttpClient();
        var r = body == null ? await http.GetAsync(url.TrimEnd('/') + path)
            : await http.PostAsync(url.TrimEnd('/') + path, new StringContent(body.ToJsonString(), System.Text.Encoding.UTF8, "application/json"));
        r.EnsureSuccessStatusCode();
        return JsonNode.Parse(await r.Content.ReadAsStringAsync())!;
    }

    [Fact]
    public async Task EachControlAnswersOneReadWithItsState()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_INSIGHTS_STARMAP");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        try
        {
            foreach (var c in Proof.Order)
            {
                await Http(url, "/__fixture/graph", Proof.Knobs(c));
                var before = Proof.Served(await Http(url, "/__fixture/state"));
                string? reason = null;
                StarMapGraph? graph = null;
                try { graph = await StarMapApi.GraphAsync(session, "default"); }
                catch (Exception e) { reason = InsightsWire.Reason(e); }
                var after = Proof.Served(await Http(url, "/__fixture/state"));
                Assert.True(before >= 0, $"{c}: no served count");
                Assert.Equal(1, after - before);
                switch (c)
                {
                    case Proof.Control.Seeded:
                        Assert.NotNull(graph);
                        var shown = StarMapShown.Make(graph!, StarMapFilter.All, 1);
                        Assert.Equal(Proof.SeedSubtitle, shown.Subtitle);
                        Assert.Equal(Proof.SeedSkills, shown.Skills);
                        Assert.Equal(Proof.SeedMemory, shown.Memory.Count);
                        Assert.Equal(Proof.SeedStars, shown.Layout.Stars.Count);
                        Assert.True(shown.Layout.Edges.Count > 0);
                        break;
                    case Proof.Control.Error: Assert.Equal(Proof.FailDetail, reason); break;
                    case Proof.Control.Empty: Assert.True(graph is { IsEmpty: true }); break;
                    default: Assert.Equal(InsightsWire.OlderHermes, reason); break;
                }
                // A control holds for one opening only where the walk relies on it: the next read is the seeded graph again
                // for Error and Unsupported (count 1); Bare and Empty stay until the next control resets them.
                if (c is Proof.Control.Error or Proof.Control.Unsupported)
                    Assert.False((await StarMapApi.GraphAsync(session, "default")).IsEmpty);
            }
        }
        finally { await Http(url, "/__fixture/graph", Proof.Knobs(Proof.Control.Seeded)); }
    }
}
