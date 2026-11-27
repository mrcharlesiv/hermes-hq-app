using Hermes.Core.Insights;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-STAR-CLUSTER-ACCESS] The Map's one keyboard / Narrator element per cluster (StarMapClusterElements in
/// App/Pages/More/StarMap/StarMapCanvas.swift): the first 40 clusters of the layout, those whose centre the settled camera
/// shows, "Coding, 42 skills", Zooms to this group, keyed by category, and activation frames the group. Synthetic data only.
public class StarMapClusterAccessTests
{
    private static StarMapNode Skill(string id, string category) => StarMapNode.Make(id, category: category);
    private static StarMapNode Memory(string id, string category) => StarMapNode.Make(id, kind: StarMapKind.Memory, category: category);

    private static StarMapLayout Clusters(int count, int perCluster = 3)
    {
        var nodes = new List<StarMapNode>();
        for (var c = 0; c < count; c++)
            for (var i = 0; i < perCluster; i++) nodes.Add(Skill($"s{c}-{i}", $"cat-{c:D2}"));
        return new StarMapLayout(nodes);
    }

    private const double W = 800, H = 600;

    [Fact]
    public void EveryClusterOfTheWholeMapIsOfferedInLayoutOrderKeyedByCategory()
    {
        var layout = Clusters(6);
        var whole = layout.Whole(W, H);
        var targets = StarMapClusterTargets.Make(layout, whole, W, H);
        Assert.Equal(layout.Clusters.Select(c => c.Category), targets.Select(t => t.Category));
        Assert.Equal(Enumerable.Range(0, 6), targets.Select(t => t.Index));
        Assert.All(targets, t => Assert.Equal($"starmap.cluster.{t.Category}", t.AutomationId));
        Assert.Equal("Zooms to this group", StarMapClusterTargets.Hint);
    }

    [Fact]
    public void SpokenNamesCountExactlyAndSayMemoryOrSkillSingularOrPlural()
    {
        var nodes = new List<StarMapNode>
        {
            Skill("a", "coding"),
            Skill("b", "research"), Skill("c", "research"),
            Memory("m1", "notes"),
            Memory("m2", "people"), Memory("m3", "people"), Memory("m4", "people"),
        };
        var layout = new StarMapLayout(nodes);
        var spoken = StarMapClusterTargets.Make(layout, layout.Whole(W, H), W, H).ToDictionary(t => t.Category, t => t.Spoken);
        Assert.Equal("Coding, 1 skill", spoken["coding"]);
        Assert.Equal("Research, 2 skills", spoken["research"]);
        Assert.Equal(StarMapRules.ClusterSpoken(StarMapRules.CategoryTitle("notes"), 1, true), spoken["notes"]);
        Assert.EndsWith(", 1 memory", spoken["notes"]);
        Assert.EndsWith(", 3 memories", spoken["people"]);
    }

    [Fact]
    public void OnlyTheFirstFortyClustersOfTheLayoutAreOfferedBeforeTheViewFilter()
    {
        var layout = Clusters(45, perCluster: 1);
        Assert.Equal(45, layout.Clusters.Count);
        // A camera far enough out to show every centre.
        var all = new StarMapCamera(0.05, layout.Bounds.IsNull ? Pt.Zero : new Pt(layout.Bounds.MidX, layout.Bounds.MidY));
        var targets = StarMapClusterTargets.Make(layout, all, W, H);
        Assert.Equal(StarMapClusterTargets.Limit, targets.Count);
        Assert.Equal(40, StarMapClusterTargets.Limit);
        Assert.Equal(layout.Clusters.Take(40).Select(c => c.Category), targets.Select(t => t.Category));

        // Framed on the 41st, it is still never offered (the cap is by layout order, as the Mac's prefix(40)).
        var last = layout.Clusters[44];
        var onLast = new StarMapCamera(4, last.Center);
        Assert.DoesNotContain(StarMapClusterTargets.Make(layout, onLast, W, H), t => t.Index >= 40);
    }

    [Fact]
    public void AClusterWhoseCentreIsOffscreenIsLeftOutAndTheEdgeIsHalfOpen()
    {
        var layout = Clusters(4);
        var c = layout.Clusters[0];
        // Centre exactly on the left edge (minX is inside) and exactly on the right edge (maxX is outside).
        var leftEdge = new StarMapCamera(1, new Pt(c.Center.X + W / 2, c.Center.Y));
        Assert.Contains(StarMapClusterTargets.Make(layout, leftEdge, W, H), t => t.Index == 0);
        var rightEdge = new StarMapCamera(1, new Pt(c.Center.X - W / 2, c.Center.Y));
        Assert.DoesNotContain(StarMapClusterTargets.Make(layout, rightEdge, W, H), t => t.Index == 0);
        var away = new StarMapCamera(1, new Pt(c.Center.X + 10_000, c.Center.Y + 10_000));
        Assert.Empty(StarMapClusterTargets.Make(layout, away, W, H));
        // No size yet: nothing.
        Assert.Empty(StarMapClusterTargets.Make(layout, layout.Whole(W, H), 0, 0));
        Assert.Empty(StarMapClusterTargets.Make(new StarMapLayout(), new StarMapCamera(), W, H));
    }

    [Fact]
    public void TheTargetIsCentredOnTheClusterAtLeastFortyFourAndNoLargerThanTheView()
    {
        var layout = Clusters(3, perCluster: 40);
        var c = layout.Clusters[0];
        var tight = new StarMapCamera(0.05, c.Center);
        var small = StarMapClusterTargets.Make(layout, tight, W, H).Single(t => t.Index == 0);
        Assert.Equal(44, small.Frame.Width, 6);
        Assert.Equal(W / 2, small.Frame.MidX, 6);
        Assert.Equal(H / 2, small.Frame.MidY, 6);
        var close = new StarMapCamera(StarMapCamera.MaxZoom * 10, c.Center);
        var big = StarMapClusterTargets.Make(layout, close, W, H).Single(t => t.Index == 0);
        Assert.Equal(Math.Min(W, H), big.Frame.Width, 6);
        Assert.Equal(big.Frame.Width, big.Frame.Height, 6);
        var mid = new StarMapCamera(1, c.Center);
        var normal = StarMapClusterTargets.Make(layout, mid, W, H).Single(t => t.Index == 0);
        Assert.Equal(Math.Min(Math.Max(44, c.Radius * 2), Math.Min(W, H)), normal.Frame.Width, 6);
    }

    [Fact]
    public void ANewLayoutOrCameraGivesItsOwnTargets()
    {
        var first = Clusters(5);
        var camera = first.Whole(W, H);
        var before = StarMapClusterTargets.Make(first, camera, W, H);
        // A filter (a new layout) with fewer groups: only its own categories, never a stale one.
        var filtered = new StarMapLayout(Enumerable.Range(0, 3).Select(i => Skill($"s0-{i}", "cat-00")));
        var after = StarMapClusterTargets.Make(filtered, filtered.Whole(W, H), W, H);
        Assert.Equal(["cat-00"], after.Select(t => t.Category));
        // Zoomed onto one group: the others leave, that one stays under its key.
        var onOne = StarMapClusterTargets.Framing(first, 2, W, H, StarMapCamera.Floor(1));
        var zoomed = StarMapClusterTargets.Make(first, onOne, W, H);
        Assert.Contains(zoomed, t => t.Category == before[2].Category);
        Assert.True(zoomed.Count < before.Count);
        // A resize moves the frame.
        var resized = StarMapClusterTargets.Make(first, camera, W / 2, H / 2);
        Assert.NotEqual(before.First(t => t.Index == 0).Frame, resized.FirstOrDefault(t => t.Index == 0)?.Frame);
    }

    [Fact]
    public void ActivationFramesThatGroupAndKeepsItOffered()
    {
        var layout = Clusters(8);
        var floor = StarMapCamera.Floor(layout.Whole(W, H, most: 8).Scale);
        foreach (var target in StarMapClusterTargets.Make(layout, layout.Whole(W, H), W, H))
        {
            var c = layout.Clusters[target.Index];
            var framed = StarMapClusterTargets.Framing(layout, target.Index, W, H, floor);
            Assert.Equal(c.Center.X, framed.Center.X, 6);
            Assert.Equal(c.Center.Y, framed.Center.Y, 6);
            Assert.InRange(framed.Scale, floor, StarMapCamera.MaxZoom);
            var r = new Box(c.Center.X - c.Radius, c.Center.Y - c.Radius, c.Radius * 2, c.Radius * 2).Inset(-28, -28);
            Assert.Equal(Math.Min(StarMapCamera.MaxZoom, Math.Max(floor, StarMapLayout.Fit(r, W, H))), framed.Scale, 9);
            // The activated element survives its own move under the same key (focus is not dropped).
            Assert.Contains(StarMapClusterTargets.Make(layout, framed, W, H), t => t.Category == target.Category);
            Assert.Equal(target.Index, StarMapClusterTargets.IndexOf(layout, target.Category));
        }
        Assert.Null(StarMapClusterTargets.IndexOf(layout, "gone"));
    }

    // ------------------------------------------------------------------ the WinUI canvas wiring (source)

    private static string Canvas()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Features", "Insights", "StarMapCanvas.cs")).ReplaceLineEndings("\n");
    }

    [Fact]
    public void TheCanvasOffersNativeButtonsThatNeverTakeThePointerOrTheFocus()
    {
        var src = Canvas();
        Assert.Contains("StarMapClusterTargets.Make(_layout, _settled", src);
        Assert.Contains("_clusterLayer", src);
        Assert.Matches(@"_clusterLayer\s*=\s*new\(\)\s*\{[^}]*IsHitTestVisible\s*=\s*false", src);
        Assert.Contains("AutomationProperties.SetHelpText(b, StarMapClusterTargets.Hint)", src);
        Assert.Contains("AutomationProperties.SetAutomationId(b, target.AutomationId)", src);
        Assert.Contains("AutomationProperties.SetName(b, target.Spoken)", src);
        // Activation is the one framing path the double click also takes.
        Assert.Contains("ZoomToCluster(", src);
        Assert.Contains("StarMapClusterTargets.Framing(_layout", src);
        // Refreshed from the settled camera, not each frame, and never moving the keyboard.
        var layer = src[src.IndexOf("private void RefreshClusters", StringComparison.Ordinal)..];
        layer = layer[..layer.IndexOf("\n    }\n", StringComparison.Ordinal)];
        Assert.DoesNotContain(".Focus(", layer);
    }
}
