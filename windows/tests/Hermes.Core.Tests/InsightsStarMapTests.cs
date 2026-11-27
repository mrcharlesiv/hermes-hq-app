using System.Diagnostics;
using System.Text.Json.Nodes;
using Hermes.Core.Insights;

namespace Hermes.Core.Tests;

/// Star Map (docs/spec/3x-morepages.md §17), ported from Tests/Pages/More/StarMapTests.swift: the layout is
/// deterministic and its stars never overlap at 1×, the filters, the List's sections, nearest-wins hit-testing, the
/// camera, and the decoders with bad data (duplicate ids included).
public class InsightsStarMapTests
{
    private static StarMapNode Skill(string id, string category = "coding", int used = 0, string? by = "agent", bool pinned = false) =>
        StarMapNode.Make(id, category: category, useCount: used, createdBy: by, pinned: pinned);

    /// `count` skills over `categories` categories of uneven size, with every kind of use count (the Swift's generator).
    private static List<StarMapNode> Sample(int count, int categories = 12, ulong seed = 7)
    {
        var state = seed;
        ulong Next() { unchecked { state = state * 6364136223846793005UL + 1442695040888963407UL; } return state >> 33; }
        var o = new List<StarMapNode>();
        for (var i = 0; i < count; i++)
        {
            var a = (int)(Next() % (ulong)(categories * 2));
            var b = (int)(Next() % (ulong)categories);
            var category = $"cat-{Math.Min(a, b)}";
            var used = (int)(Next() % 5) == 0 ? 0 : (int)(Next() % 200);
            o.Add(Skill($"skill-{i}", category, used, pinned: Next() % 9 == 0));
        }
        return o;
    }

    private static double Dist(Pt a, Pt b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));

    // ------------------------------------------------------------------ layout

    [Fact]
    public void TheSameGraphGivesTheSamePoints()
    {
        var nodes = Sample(300);
        var edges = Enumerable.Range(0, 200).Select(i => new StarMapEdge($"skill-{i}", $"skill-{(i * 7 + 3) % 300}")).ToList();
        var first = new StarMapLayout(nodes, edges);
        var second = new StarMapLayout(nodes, edges);
        Assert.Equal(first.Stars, second.Stars);
        Assert.Equal(first.Edges, second.Edges);
        Assert.Equal(300, first.Stars.Count);
        var shuffled = new StarMapLayout(Enumerable.Reverse(nodes).ToList(), edges);
        Assert.Equal(first.Stars.ToDictionary(s => s.Id, s => s.Point), shuffled.Stars.ToDictionary(s => s.Id, s => s.Point));
        Assert.Equal(first.Clusters.Select(c => c.Category), shuffled.Clusters.Select(c => c.Category));
    }

    [Fact]
    public void TheHashIsFnv1a()
    {
        Assert.Equal(0xcbf29ce484222325UL, StarMapLayout.StableHash(""));
        Assert.Equal(0xaf63dc4c8601ec8cUL, StarMapLayout.StableHash("a"));
    }

    [Theory]
    [InlineData(1)] [InlineData(2)] [InlineData(5)] [InlineData(60)] [InlineData(700)] [InlineData(2000)]
    public void NoTwoStarsOfAClusterOverlapAtOneTimes(int count)
    {
        foreach (var nodes in new[] { Sample(count), Enumerable.Range(0, count).Select(i => Skill($"big-{i}", $"cat-{i % 3}", 500)).ToList() })
        {
            var layout = new StarMapLayout(nodes);
            foreach (var c in layout.Clusters)
            {
                var stars = layout.Stars.Skip(c.First).Take(c.Count).ToList();
                for (var a = 0; a < stars.Count; a++)
                    for (var b = a + 1; b < stars.Count; b++)
                        Assert.False(Dist(stars[a].Point, stars[b].Point) < stars[a].Radius + stars[b].Radius, $"{stars[a].Id} and {stars[b].Id} overlap");
            }
        }
    }

    [Fact]
    public void ClustersKeepApartOnTheRing()
    {
        foreach (var count in new[] { 2, 3, 60, 2000, 5000 })
        {
            var layout = new StarMapLayout(Sample(count));
            for (var a = 0; a < layout.Clusters.Count; a++)
                for (var b = a + 1; b < layout.Clusters.Count; b++)
                {
                    var one = layout.Clusters[a]; var two = layout.Clusters[b];
                    Assert.True(Dist(one.Center, two.Center) >= one.Radius + two.Radius + StarMapLayout.Gap - 0.5, $"{one.Category} and {two.Category} at {count}");
                }
        }
    }

    [Fact]
    public void CategoriesAreOrderedBySizeAndTheMostUsedIsInTheMiddle()
    {
        var nodes = new[] { Skill("a1", "small", 1), Skill("b1", "large", 3), Skill("b2", "large", 90), Skill("b3", "large"), Skill("c1", "middle"), Skill("c2", "middle", 2) };
        var layout = new StarMapLayout(nodes);
        Assert.Equal(["large", "middle", "small"], layout.Clusters.Select(c => c.Category));
        Assert.Equal([3, 2, 1], layout.Clusters.Select(c => c.Count));
        Assert.True(layout.Clusters[0].Center.Y < layout.Clusters[1].Center.Y);
        Assert.True(Math.Abs(layout.Clusters[0].Center.X) < 0.001);
        var large = layout.Stars.Skip(layout.Clusters[0].First).Take(3).ToList();
        Assert.Equal(["b2", "b1", "b3"], large.Select(s => s.Id));
        var distances = large.Select(s => Dist(s.Point, layout.Clusters[0].Center)).ToList();
        Assert.Equal(distances.OrderBy(d => d), distances);
        var alone = new StarMapLayout([Skill("only")]);
        Assert.Equal(Pt.Zero, alone.Clusters[0].Center);
        Assert.Equal(Pt.Zero, alone.Stars[0].Point);
    }

    [Fact]
    public void StarsAreFourToFourteenPointsAcross()
    {
        Assert.Equal(4, StarMapLayout.Diameter(0));
        Assert.Equal(4, StarMapLayout.Diameter(-5));
        Assert.Equal(14, StarMapLayout.Diameter(64));
        Assert.Equal(14, StarMapLayout.Diameter(1_000_000));
        Assert.True(StarMapLayout.Diameter(4) > StarMapLayout.Diameter(1));
        Assert.All(new StarMapLayout(Sample(500)).Stars, s => Assert.InRange(s.Radius, 2, 7));
    }

    [Fact]
    public void ColoursAreStableAndDistinctWhileThePaletteLasts()
    {
        var twelve = Enumerable.Range(0, 12).Select(i => $"cat-{i}").ToList();
        var colors = StarMapLayout.Colors(twelve);
        Assert.Equal(12, colors.Values.Distinct().Count());
        Assert.Equal(colors, StarMapLayout.Colors(Enumerable.Reverse(twelve).Concat(twelve)));
        var many = StarMapLayout.Colors(Enumerable.Range(0, 40).Select(i => $"c{i}"));
        Assert.Equal(40, many.Count);
        Assert.All(many.Values, v => Assert.InRange(v, 0, 11));
        Assert.Empty(StarMapLayout.Colors([]));
        Assert.Equal(colors["cat-3"], new StarMapLayout([Skill("a", "cat-3")], colors: colors).Clusters[0].Color);
    }

    [Fact]
    public void EdgesKeepOnlyRealPairsOnce()
    {
        var layout = new StarMapLayout([Skill("a"), Skill("b"), Skill("c")],
            [new("a", "b"), new("b", "a"), new("a", "a"), new("a", "gone"), new("c", "a")]);
        Assert.Equal(2, layout.Edges.Count);
        var dup = new StarMapLayout([Skill("a", used: 3), Skill("a", "other", 9), Skill("b")]);
        Assert.Equal(["a", "b"], dup.Stars.Select(s => s.Id).Order());
        Assert.Single(dup.Clusters);
    }

    [Fact]
    public void HitTestingMatchesAPlainSearch()
    {
        var layout = new StarMapLayout(Sample(1500));
        foreach (var star in layout.Stars.Take(50)) Assert.Equal(star.Id, layout.Stars[layout.Hit(star.Point, 22)!.Value].Id);
        ulong state = 99;
        double Next() { unchecked { state = state * 6364136223846793005UL + 1442695040888963407UL; } return (double)(state >> 40) / (1 << 24); }
        var b = layout.Bounds;
        for (var i = 0; i < 400; i++)
        {
            var p = new Pt(b.MinX + Next() * b.Width, b.MinY + Next() * b.Height);
            var reach = new[] { 5.5, 22, 44 }[(int)(Next() * 3) % 3];
            int? best = null; double bd = 0;
            for (var k = 0; k < layout.Stars.Count; k++)
            {
                var d = Dist(layout.Stars[k].Point, p);
                if (d <= reach && (best == null || d < bd)) { best = k; bd = d; }
            }
            Assert.Equal(best, layout.Hit(p, reach));
        }
        Assert.Equal(0, new StarMapLayout([Skill("one")]).Hit(new Pt(21, 0), 22));
        Assert.Null(new StarMapLayout([Skill("one")]).Hit(new Pt(21, 0), 11));
        Assert.Null(new StarMapLayout().Hit(Pt.Zero, 22));
    }

    [Fact]
    public void OnlyWhatIsInViewIsListed()
    {
        var layout = new StarMapLayout(Sample(2000));
        var c = layout.Clusters[3];
        var window = new Box(c.Center.X - 60, c.Center.Y - 60, 120, 120);
        var listed = layout.StarsIn(window);
        var plain = Enumerable.Range(0, layout.Stars.Count).Where(i => window.Contains(layout.Stars[i].Point)).ToList();
        Assert.Equal(plain, listed);
        Assert.True(listed.Count < 200);
        Assert.Equal(2000, layout.StarsIn(layout.Bounds.Inset(-10, -10)).Count);
        Assert.Empty(layout.StarsIn(new Box(90_000, 90_000, 50, 50)));
        Assert.Empty(layout.StarsIn(Box.Zero));
    }

    [Fact]
    public void ADoubleClickFindsTheClusterUnderIt()
    {
        var layout = new StarMapLayout(Sample(120));
        for (var i = 0; i < layout.Clusters.Count; i++) Assert.Equal(i, layout.ClusterAt(layout.Clusters[i].Center, 30));
        Assert.Null(layout.ClusterAt(new Pt(50_000, 0), 30));
    }

    [Theory]
    [InlineData(1)] [InlineData(60)] [InlineData(2000)] [InlineData(5000)]
    public void TheWholeMapFitsWithItsNames(int count)
    {
        var layout = new StarMapLayout(Sample(count));
        double w = 402, h = 560;
        var camera = layout.Whole(w, h);
        Assert.True(camera.Scale <= 1 && camera.Scale > 0.02);
        foreach (var c in layout.Clusters)
        {
            var center = camera.Screen(c.Center, w, h); var radius = c.Radius * camera.Scale;
            var name = c.LabelBox; var anchor = c.LabelAnchor;
            var px = center.X + c.LabelSide.X * (radius + StarMapLayout.LabelDrop);
            var py = center.Y + c.LabelSide.Y * (radius + StarMapLayout.LabelDrop);
            var box = new Box(px - name.Width * anchor.X, py - name.Height * anchor.Y, name.Width, name.Height)
                .Union(new Box(center.X - radius, center.Y - radius, radius * 2, radius * 2));
            Assert.True(new Box(0, 0, w, h).Inset(11, 11).Contains(box), $"{c.Category} at {count}: {box}");
        }
        if (count <= 60) Assert.True(camera.Scale > 0.7);
        Assert.Equal(new StarMapCamera(), new StarMapLayout().Whole(w, h));
    }

    [Fact]
    public void FiveThousandNodesLayOutQuickly()
    {
        var nodes = Sample(5000);
        var edges = Enumerable.Range(0, 10_000).Select(i => new StarMapEdge($"skill-{i % 5000}", $"skill-{(i * 13 + 1) % 5000}")).ToList();
        var clock = Stopwatch.StartNew();
        var layout = new StarMapLayout(nodes, edges);
        Assert.Equal(5000, layout.Stars.Count);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(4), $"5,000 nodes took {clock.Elapsed}");
    }

    // ------------------------------------------------------------------ camera

    [Fact]
    public void TheCamera()
    {
        double w = 400, h = 600;
        var cam = new StarMapCamera(2.5, new Pt(40, -10));
        var back = cam.Screen(cam.World(new Pt(123, 456), w, h), w, h);
        Assert.True(Math.Abs(back.X - 123) < 0.001 && Math.Abs(back.Y - 456) < 0.001);
        Assert.Equal(new Pt(200, 300), cam.Screen(cam.Center, w, h));

        var c = new StarMapCamera();
        var anchor = new Pt(310, 120);
        var before = c.World(anchor, w, h);
        c.Zoom(1.8, anchor, w, h, 0.5);
        var after = c.World(anchor, w, h);
        Assert.True(Math.Abs(c.Scale - 1.8) < 0.0001);
        Assert.True(Math.Abs(before.X - after.X) < 0.001 && Math.Abs(before.Y - after.Y) < 0.001);

        var z = new StarMapCamera();
        for (var i = 0; i < 20; i++) z.Zoom(2, Pt.Zero, w, h, 0.5);
        Assert.Equal(4, z.Scale);
        for (var i = 0; i < 20; i++) z.Zoom(0.5, Pt.Zero, w, h, 0.5);
        Assert.Equal(0.5, z.Scale);
        Assert.Equal(0.2, StarMapCamera.Floor(0.2));
        Assert.Equal(0.5, StarMapCamera.Floor(0.9));
        Assert.Equal(0.5, StarMapCamera.Floor(3));
        Assert.Equal(0.05, StarMapCamera.Floor(0));

        var p = new StarMapCamera(2, Pt.Zero);
        p.Pan(100, -40);
        Assert.Equal(new Pt(-50, 20), p.Center);
        p.Pan(-100_000, 0);
        p.Clamp(new Box(-300, -300, 600, 600));
        Assert.Equal(300, p.Center.X);

        Assert.Equal(0.5, StarMapLayout.Fit(new Box(0, 0, 800, 400), 432, 632));
        Assert.Equal(1, StarMapLayout.Fit(Box.Zero, w, h));
        Assert.Equal(7, new StarMapCamera(1, Pt.Zero).StarRadius(7));
        Assert.Equal(3.5, new StarMapCamera(0.5, Pt.Zero).StarRadius(7));
        Assert.Equal(0.75, new StarMapCamera(0.1, Pt.Zero).StarRadius(2));
        Assert.Equal(14, new StarMapCamera(4, Pt.Zero).StarRadius(7));
        Assert.Equal(1.6, StarMapCamera.LabelZoom);
        Assert.Equal(1, StarMapCamera.ScrollFactor(0, true));
        Assert.Equal(1.5, StarMapCamera.ScrollFactor(1000, true));
    }

    // ------------------------------------------------------------------ rules

    private static readonly StarMapNode[] Nodes =
    [
        Skill("alpha", "coding", 3, "agent"), Skill("beta", "coding", 0, "learn", pinned: true), Skill("gamma", "coding", 12, null),
        Skill("delta", "writing", 0, "agent"), Skill("Echo", "writing", 0, "user"), Skill("zeta", "email", 1, null),
        StarMapNode.Make("memory:memory:0:abc", "A note", StarMapKind.Memory, "memory", createdBy: "memory"),
    ];

    [Fact]
    public void TheFilters()
    {
        List<string> Ids(StarMapFilter f) => [.. Nodes.Where(n => f.Matches(n)).Select(n => n.Id)];
        Assert.Equal(7, Ids(StarMapFilter.All).Count);
        Assert.Equal(["alpha", "gamma", "zeta"], Ids(StarMapFilter.Used));
        Assert.Equal(["alpha", "beta", "delta"], Ids(StarMapFilter.Learned));
        Assert.Equal(["All", "Used", "Learned"], StarMapFilters.AllCases.Select(f => f.Title()));
    }

    [Fact]
    public void TheListsSections()
    {
        var all = StarMapRules.Sections(Nodes, StarMapFilter.All);
        Assert.Equal(["Coding · 3", "Writing · 2", "Email · 1"], all.Select(s => s.Header));
        Assert.Equal(["gamma", "alpha", "beta"], all[0].Nodes.Select(n => n.Id));
        Assert.Equal(["delta", "Echo"], all[1].Nodes.Select(n => n.Id));
        Assert.Equal("6 skills across 3 categories", StarMapRules.Subtitle(all));
        var used = StarMapRules.Sections(Nodes, StarMapFilter.Used);
        Assert.Equal(["Coding · 2", "Email · 1"], used.Select(s => s.Header));
        Assert.Equal("3 skills across 2 categories", StarMapRules.Subtitle(used));
        Assert.Equal(["Coding · 2", "Writing · 1"], StarMapRules.Sections(Nodes, StarMapFilter.Learned).Select(s => s.Header));
        Assert.Empty(StarMapRules.Sections([], StarMapFilter.All));
        Assert.Equal(7, StarMapRules.Stars(Nodes, StarMapFilter.All).Count);
        Assert.Equal(3, StarMapRules.Stars(Nodes, StarMapFilter.Used).Count);
    }

    [Fact]
    public void TheWords()
    {
        Assert.Equal("1 skill across 1 category", StarMapRules.Subtitle(1, 1));
        Assert.Equal("0 skills across 0 categories", StarMapRules.Subtitle(0, 0));
        Assert.Equal("Not used yet", StarMapRules.UsedLine(0));
        Assert.Equal("Used 1 time", StarMapRules.UsedLine(1));
        Assert.Equal("Used 42 times", StarMapRules.UsedLine(42));
        Assert.Equal("Software Development", StarMapRules.CategoryTitle("software-development"));
        Assert.Equal("Mlops", StarMapRules.CategoryTitle("mlops"));
        Assert.Equal("GitHub", StarMapRules.CategoryTitle("GitHub"));
        Assert.Equal("General", StarMapRules.CategoryTitle(""));
        Assert.Equal("Hermes", StarMapRules.CreatedByWord("agent"));
        Assert.Equal("Taught by You", StarMapRules.CreatedByWord("learn"));
        Assert.Null(StarMapRules.CreatedByWord(null));
        Assert.Equal("Memory", StarMapRules.KindWord(Nodes[6]));
        Assert.Equal("Skill", StarMapRules.KindWord(Nodes[0]));
        Assert.Equal("Stale", StarMapRules.StateWord("stale"));
        Assert.Equal("Coding, 42 skills", StarMapRules.ClusterSpoken("Coding", 42, false));
        Assert.Equal("Memory, 1 memory", StarMapRules.ClusterSpoken("Memory", 1, true));
        Assert.False(StarMapRules.Folds("short"));
        Assert.True(StarMapRules.Folds(new string('x', 20_000)));
        Assert.True(StarMapRules.Folds("a\nb\nc\nd\ne"));
        Assert.Equal(["Skill", "Coding", "Active", "Pinned"], StarMapRules.Tags(Nodes[1]));
        Assert.Equal("Not used yet · Created by Taught by You", StarMapRules.QuietLine(Nodes[1]));
        Assert.Equal("Created by Memory", StarMapRules.QuietLine(Nodes[6]));
    }

    [Fact]
    public void TheShownState()
    {
        var graph = new StarMapGraph(Nodes, [new("alpha", "gamma"), new("alpha", "delta")], [new StarMapMemoryCard(0, "memory", "A note", "A note\nmore")]);
        var all = StarMapShown.Make(graph, StarMapFilter.All, 4);
        Assert.Equal("6 skills across 3 categories", all.Subtitle);
        Assert.True(all.Skills == 6 && all.Layout.Stars.Count == 7 && all.Layout.Edges.Count == 2 && all.Memory.Count == 1 && all.Generation == 4);
        var used = StarMapShown.Make(graph, StarMapFilter.Used, 5);
        Assert.True(used.Layout.Stars.Count == 3 && used.Layout.Edges.Count == 1 && used.Memory.Count == 0);
        Assert.Equal(all.Layout.Clusters.First(c => c.Category == "coding").Color, used.Layout.Clusters.First(c => c.Category == "coding").Color);
    }

    // ------------------------------------------------------------------ wire

    [Fact]
    public void TheGraphAsTheGatewaySendsIt()
    {
        var graph = StarMapGraph.FromJson(JsonNode.Parse("""
        {"nodes":[{"id":"review-prs","label":"review-prs","kind":"skill","timestamp":1757000000,"category":"coding","useCount":7,
                   "state":"active","createdBy":"agent","pinned":true},
                  {"id":"memory:profile:0:abc123","label":"Likes short notes","kind":"memory","memorySource":"profile","timestamp":null,
                   "category":"memory","useCount":0,"state":"active","createdBy":"memory","pinned":false}],
         "edges":[{"source":"memory:profile:0:abc123","target":"review-prs"}],
         "clusters":[{"category":"coding","count":1},{"category":"memory","count":1}],
         "memory":[{"source":"profile","title":"Likes short notes","body":"Likes short notes\nAlways.","timestamp":1757000000,"fingerprint":"abc123"}],
         "stats":{"nodes":1,"related_edges":0}}
        """));
        Assert.True(graph.Nodes.Count == 2 && graph.Edges.Count == 1 && graph.Memory.Count == 1);
        Assert.Equal(StarMapNode.Make("review-prs", kind: StarMapKind.Skill, category: "coding", useCount: 7, createdBy: "agent", pinned: true, timestamp: 1_757_000_000), graph.Nodes[0]);
        Assert.True(graph.Nodes[1].Kind == StarMapKind.Memory && graph.Nodes[1].MemorySource == "profile" && graph.Nodes[1].Timestamp == null);
        Assert.Equal("Likes short notes\nAlways.", graph.Memory[0].Body);
        Assert.False(graph.IsEmpty);
    }

    [Fact]
    public void BadRowsAreSkippedNeverACrash()
    {
        var graph = StarMapGraph.FromJson(JsonNode.Parse("""
        {"nodes":[{"id":"a","useCount":"12","pinned":"true","category":null,"state":null,"createdBy":null},
                  {"id":"a","label":"a second copy"},
                  {"label":"no id"}, {"id":""}, {"id":null}, null, 7, "text", [], {"id":["x"]},
                  {"id":42,"label":17,"kind":"planet","useCount":-3,"pinned":1,"category":"  "},
                  {"id":"m","kind":"memory","useCount":null,"timestamp":"1757000000"}],
         "edges":[{"source":"a","target":"42"},{"source":"42","target":"a"},{"source":"a","target":"a"},
                  {"source":"a","target":"gone"},{"source":"a"},null,"x",{"source":1,"target":2}],
         "clusters":"none",
         "memory":[{"title":"","body":""},{"title":"T"},{"body":"B","source":7,"timestamp":"soon"},null,3,[]],
         "stats":null}
        """));
        Assert.Equal(["a", "42", "m"], graph.Nodes.Select(n => n.Id));
        var a = graph.Nodes[0];
        Assert.True(a.UseCount == 12 && a.Pinned && a.Category == "general" && a.State == "active");
        Assert.Equal("a", a.Label);
        var n42 = graph.Nodes[1];
        Assert.True(n42.Label == "17" && n42.Kind == StarMapKind.Skill && n42.UseCount == 0 && n42.Pinned);
        Assert.True(graph.Nodes[2].Category == "memory" && graph.Nodes[2].Timestamp == 1_757_000_000);
        Assert.Equal([new StarMapEdge("a", "42")], graph.Edges);
        Assert.Equal(["T", ""], graph.Memory.Select(m => m.Title));
        Assert.Equal([0, 1], graph.Memory.Select(m => m.Id));
        Assert.True(graph.Memory[1].Source == "memory" && graph.Memory[1].Timestamp == null);
    }

    [Fact]
    public void WhatIsNotAGraphIsAnError()
    {
        foreach (var text in new[] { "[]", "null", "7", "\"graph\"", "{}", "{\"nodes\":null}", "{\"nodes\":{\"id\":\"a\"}}", "{\"nodes\":\"many\"}" })
            Assert.Throws<PagesMessageException>(() => StarMapGraph.FromJson(JsonNode.Parse(text)));
        Assert.Equal(InsightsWire.OlderHermes, Assert.Throws<PagesMessageException>(() => StarMapGraph.FromJson(JsonNode.Parse("{}"))).Message);
        Assert.Equal(InsightsWire.OlderHermes, Assert.Throws<PagesMessageException>(() => StarMapGraph.FromJson(null)).Message);
        Assert.True(StarMapGraph.FromJson(JsonNode.Parse("{\"nodes\":[]}")).IsEmpty);
    }

    [Fact]
    public void ALargeGraphWithDuplicatesDecodes()
    {
        var rows = new JsonArray();
        for (var i = 0; i < 6000; i++) rows.Add(new JsonObject { ["id"] = $"s{i % 5000}", ["category"] = $"c{i % 12}", ["useCount"] = i % 50 });
        var edges = new JsonArray();
        for (var i = 0; i < 10_000; i++) edges.Add(new JsonObject { ["source"] = $"s{i % 5000}", ["target"] = $"s{(i * 3 + 1) % 5000}" });
        var graph = StarMapGraph.FromJson(new JsonObject { ["nodes"] = rows, ["edges"] = edges });
        Assert.Equal(5000, graph.Nodes.Count);
        Assert.Equal(5000, graph.Nodes.Select(n => n.Id).Distinct().Count());
        Assert.InRange(graph.Edges.Count, 4001, 5000);
    }

    [Fact]
    public void TheNodesText()
    {
        Assert.Equal("# A\nSteps.", StarMapNodeDetail.FromJson(JsonNode.Parse("{\"ok\":true,\"kind\":\"skill\",\"id\":\"a\",\"label\":\"a\",\"content\":\"\\n# A\\nSteps.\\n\"}")).Content);
        Assert.Equal("", StarMapNodeDetail.FromJson(JsonNode.Parse("{\"content\":null}")).Content);
        Assert.Equal("12", StarMapNodeDetail.FromJson(JsonNode.Parse("{\"content\":12}")).Content);
        Assert.Throws<PagesMessageException>(() => StarMapNodeDetail.FromJson(JsonNode.Parse("[1]")));
        Assert.Equal("# Draft\nSteps.", StarMapNodeDetail.StripFrontMatter("---\nname: draft-standups\ndescription: x\n---\n\n# Draft\nSteps."));
        Assert.Equal("no front matter", StarMapNodeDetail.StripFrontMatter("no front matter"));
        Assert.Equal("---\nunclosed", StarMapNodeDetail.StripFrontMatter("---\nunclosed"));
    }

    [Fact]
    public void TheQueries()
    {
        Assert.Empty(InsightsWire.ProfileQuery("default"));
        Assert.Equal([new("id", "a"), new("profile", "inbox")], StarMapApi.NodeQuery("a", "inbox"));
        Assert.Equal([new("id", "memory:profile:0:ab c&d")], StarMapApi.NodeQuery("memory:profile:0:ab c&d", "default"));
        Assert.True(StarMapApi.IsMissing(new Hermes.Core.Net.GatewayException("http", "x", 404)));
        Assert.False(StarMapApi.IsMissing(new Hermes.Core.Net.GatewayException("http", "x", 500)));
    }
}
