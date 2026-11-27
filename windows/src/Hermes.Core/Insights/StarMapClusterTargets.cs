namespace Hermes.Core.Insights;

/// [WIN-STAR-CLUSTER-ACCESS] One keyboard / Narrator element per cluster in view (StarMapClusterElements in
/// App/Pages/More/StarMap/StarMapCanvas.swift): "Coding, 42 skills", Zooms to this group. Keyed by category.
public sealed record StarMapClusterTarget(int Index, string Category, string Spoken, Box Frame)
{
    public string AutomationId => $"starmap.cluster.{Category}";
}

public static class StarMapClusterTargets
{
    /// Most cluster elements offered (the Mac's `limit`): the layout's first forty, before the view filter.
    public const int Limit = 40;
    public const string Hint = "Zooms to this group";

    /// The first `Limit` clusters of the layout whose centre the settled camera shows, in layout order. Each is a square
    /// on the cluster's centre: its drawn diameter, at least 44 and never larger than the view.
    public static List<StarMapClusterTarget> Make(StarMapLayout layout, StarMapCamera settled, double width, double height)
    {
        var o = new List<StarMapClusterTarget>();
        if (width <= 1 || height <= 1) return o;
        var visible = settled.Visible(width, height);
        for (var i = 0; i < Math.Min(Limit, layout.Clusters.Count); i++)
        {
            var c = layout.Clusters[i];
            if (!visible.Contains(c.Center)) continue;
            var p = settled.Screen(c.Center, width, height);
            var side = Math.Min(Math.Max(44, c.Radius * 2 * settled.Scale), Math.Min(width, height));
            o.Add(new StarMapClusterTarget(i, c.Category, StarMapRules.ClusterSpoken(c.Title, c.Count, c.IsMemory),
                new Box(p.X - side / 2, p.Y - side / 2, side, side)));
        }
        return o;
    }

    /// The cluster under `category` in this layout (the element is keyed by it; the index can change with a new layout).
    public static int? IndexOf(StarMapLayout layout, string category)
    {
        for (var i = 0; i < layout.Clusters.Count; i++) if (layout.Clusters[i].Category == category) return i;
        return null;
    }

    /// The camera that frames cluster `index` (StarMapStage.framing(cluster:)): its circle 28 beyond, at most MaxZoom.
    /// The double click and a cluster element's activation both take it.
    public static StarMapCamera Framing(StarMapLayout layout, int index, double width, double height, double floor)
    {
        var c = layout.Clusters[index];
        var rect = new Box(c.Center.X - c.Radius, c.Center.Y - c.Radius, c.Radius * 2, c.Radius * 2).Inset(-28, -28);
        var scale = Math.Min(StarMapCamera.MaxZoom, Math.Max(floor, StarMapLayout.Fit(rect, width, height)));
        return new StarMapCamera(scale, new Pt(rect.MidX, rect.MidY));
    }
}
