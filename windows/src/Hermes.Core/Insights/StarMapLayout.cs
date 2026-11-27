namespace Hermes.Core.Insights;

// The Star Map's layout (docs/spec/3x-morepages.md §17, D-M14), ported from HermesKit/Pages/More/StarMapLayout.swift.
// Pure and deterministic: the same nodes always give the same points, whatever order the gateway lists them in.
// - Categories sit on a ring, the largest at the top, then clockwise by size (ties by name). One category alone sits in
//   the middle.
// - Inside a category the stars lie on a golden-angle spiral, the most used in the middle (rank of `useCount`, ties by
//   id), so no two overlap at 1×.
// - A star is 4–14 pt across by `useCount`.
// World units are points at 1×; the origin is the middle of the ring.

public readonly record struct Pt(double X, double Y)
{
    public static readonly Pt Zero = new(0, 0);
}

/// CoreGraphics' CGRect as far as the map needs it: `Null` for the empty union start, half-open `Contains`.
public readonly record struct Box(double X, double Y, double Width, double Height)
{
    public static readonly Box Null = new(double.PositiveInfinity, double.PositiveInfinity, 0, 0);
    public static readonly Box Zero = new(0, 0, 0, 0);
    public bool IsNull => double.IsPositiveInfinity(X);
    public bool IsEmpty => IsNull || Width <= 0 || Height <= 0;
    public double MinX => X;
    public double MinY => Y;
    public double MaxX => X + Width;
    public double MaxY => Y + Height;
    public double MidX => X + Width / 2;
    public double MidY => Y + Height / 2;

    public Box Union(Box o)
    {
        if (IsNull) return o;
        if (o.IsNull) return this;
        double x0 = Math.Min(MinX, o.MinX), y0 = Math.Min(MinY, o.MinY), x1 = Math.Max(MaxX, o.MaxX), y1 = Math.Max(MaxY, o.MaxY);
        return new Box(x0, y0, x1 - x0, y1 - y0);
    }

    public bool Contains(Pt p) => !IsNull && p.X >= MinX && p.X < MaxX && p.Y >= MinY && p.Y < MaxY;
    public bool Contains(Box b) => !IsNull && !b.IsNull && b.MinX >= MinX && b.MaxX <= MaxX && b.MinY >= MinY && b.MaxY <= MaxY;
    public Box Inset(double dx, double dy) => new(X + dx, Y + dy, Width - dx * 2, Height - dy * 2);
    public bool Intersects(Box b) => !IsNull && !b.IsNull && b.MinX < MaxX && b.MaxX > MinX && b.MinY < MaxY && b.MaxY > MinY;
}

public sealed class StarMapLayout
{
    public sealed record Star(string Id, string Label, int Cluster, Pt Point, double Radius, bool Pinned, int UseCount);

    public sealed record Cluster(string Category, string Title, Pt Center, double Radius, int First, int Count, int Color, bool IsMemory, Pt LabelSide)
    {
        /// Where the name is anchored (world), `LabelDrop` beyond the cluster's edge.
        public Pt LabelPoint => new(Center.X + LabelSide.X * (Radius + LabelDrop), Center.Y + LabelSide.Y * (Radius + LabelDrop));
        /// The unit point of the name's box that sits on `LabelPoint`, so the text grows away from the cluster.
        public Pt LabelAnchor => new(0.5 - LabelSide.X * 0.5, 0.5 - LabelSide.Y * 0.5);
        /// Room the name is given in the map's bounds (a guess at its size at 1×).
        public Box LabelBox
        {
            get
            {
                double width = Title.Length * 7.5 + 10, height = 20;
                var a = LabelAnchor; var p = LabelPoint;
                return new Box(p.X - width * a.X, p.Y - height * a.Y, width, height);
            }
        }
        /// Its stars and its name.
        public Box Box => new Box(Center.X - Radius, Center.Y - Radius, Radius * 2, Radius * 2).Union(LabelBox);
    }

    public readonly record struct Edge(int A, int B);

    public List<Star> Stars { get; } = [];
    public List<Cluster> Clusters { get; } = [];
    public List<Edge> Edges { get; } = [];
    /// Everything drawn at 1×, cluster labels included.
    public Box Bounds { get; private set; } = Box.Zero;
    private readonly Dictionary<long, List<int>> _grid = [];

    public const double Spacing = 11;
    public static readonly double GoldenAngle = Math.PI * (3 - Math.Sqrt(5));
    public const double MinDiameter = 4, MaxDiameter = 14;
    public const double Gap = 30;
    public const double LabelDrop = 8;
    public const double Cell = 64;
    public const int PaletteCount = 12;

    public static double Diameter(int useCount) => Math.Min(MaxDiameter, MinDiameter + Math.Sqrt(Math.Max(0, useCount)) * 1.25);

    /// FNV-1a: stable across launches and machines.
    public static ulong StableHash(string text)
    {
        unchecked
        {
            var hash = 0xcbf29ce484222325UL;
            foreach (var b in System.Text.Encoding.UTF8.GetBytes(text)) hash = (hash ^ b) * 0x00000100000001b3UL;
            return hash;
        }
    }

    /// A palette slot per category: its stable hash, moved to the next free slot when another category of this graph
    /// (earlier by name) already has it. Computed from the whole graph, so a filter never recolours a cluster.
    public static Dictionary<string, int> Colors(IEnumerable<string> categories, int count = PaletteCount)
    {
        var o = new Dictionary<string, int>(StringComparer.Ordinal);
        var taken = new HashSet<int>();
        if (count <= 0) return o;
        var sorted = categories.Distinct(StringComparer.Ordinal).ToList();
        sorted.Sort(string.CompareOrdinal);
        foreach (var c in sorted)
        {
            var slot = (int)(StableHash(c) % (ulong)count);
            if (taken.Count < count) while (taken.Contains(slot)) slot = (slot + 1) % count;
            taken.Add(slot);
            o[c] = slot;
        }
        return o;
    }

    public StarMapLayout() { }

    /// `colors` maps a category to its palette slot (`Colors`); a category it lacks gets its own hash.
    public StarMapLayout(IEnumerable<StarMapNode> nodes, IEnumerable<StarMapEdge>? edges = null, IReadOnlyDictionary<string, int>? colors = null)
    {
        var groups = new Dictionary<string, List<StarMapNode>>(StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var n in nodes)
        {
            if (!seen.Add(n.Id)) continue;
            if (!groups.TryGetValue(n.Category, out var l)) groups[n.Category] = l = [];
            l.Add(n);
        }
        var ordered = groups.ToList();
        ordered.Sort((a, b) => a.Value.Count != b.Value.Count ? b.Value.Count.CompareTo(a.Value.Count) : string.CompareOrdinal(a.Key, b.Key));

        var built = new List<(string Category, List<Star> Stars, double Radius, bool Memory)>();
        foreach (var (category, members) in ordered)
        {
            var ranked = members.ToList();
            ranked.Sort((a, b) => a.UseCount != b.UseCount ? b.UseCount.CompareTo(a.UseCount) : string.CompareOrdinal(a.Id, b.Id));
            var phase = (double)(StableHash(category) % 3600) / 3600 * 2 * Math.PI;
            var stars = new List<Star>();
            double reach = 0;
            for (var i = 0; i < ranked.Count; i++)
            {
                var node = ranked[i];
                var distance = ranked.Count == 1 ? 0 : Spacing * Math.Sqrt(i + 0.5);
                var angle = phase + i * GoldenAngle;
                var radius = Diameter(node.UseCount) / 2;
                stars.Add(new Star(node.Id, node.Label, built.Count, new Pt(distance * Math.Cos(angle), distance * Math.Sin(angle)),
                    radius, node.Pinned, node.UseCount));
                reach = Math.Max(reach, distance + radius);
            }
            built.Add((category, stars, Math.Max(reach, 12), members.All(m => m.Kind == StarMapKind.Memory)));
        }

        var centers = Ring(built.Select(b => b.Radius).ToList());
        var index = new Dictionary<string, int>(StringComparer.Ordinal);
        var box = Box.Null;
        for (var number = 0; number < built.Count; number++)
        {
            var c = built[number];
            var center = centers[number];
            var far = Math.Sqrt(center.X * center.X + center.Y * center.Y);
            var color = colors != null && colors.TryGetValue(c.Category, out var slot) ? slot : (int)(StableHash(c.Category) % PaletteCount);
            var made = new Cluster(c.Category, StarMapRules.CategoryTitle(c.Category), center, c.Radius, Stars.Count, c.Stars.Count,
                color, c.Memory, far > 0.5 ? new Pt(center.X / far, center.Y / far) : new Pt(0, 1));
            Clusters.Add(made);
            foreach (var s in c.Stars)
            {
                var star = s with { Point = new Pt(center.X + s.Point.X, center.Y + s.Point.Y) };
                index[star.Id] = Stars.Count;
                var k = Key(star.Point);
                if (!_grid.TryGetValue(k, out var cell)) _grid[k] = cell = [];
                cell.Add(Stars.Count);
                Stars.Add(star);
            }
            box = box.Union(made.Box);
        }
        Bounds = box.IsNull ? Box.Zero : box;

        var pairs = new HashSet<long>();
        foreach (var e in edges ?? [])
        {
            if (!index.TryGetValue(e.Source, out var a) || !index.TryGetValue(e.Target, out var b) || a == b) continue;
            if (!pairs.Add(((long)Math.Min(a, b) << 32) | (uint)Math.Max(a, b))) continue;
            Edges.Add(new Edge(a, b));
        }
    }

    /// Centres for clusters of these radii (largest first): on a ring just wide enough that neighbours keep `Gap` between
    /// them, starting at the top and going clockwise, the spare angle shared out evenly.
    public static List<Pt> Ring(IReadOnlyList<double> radii)
    {
        if (radii.Count <= 1) return [.. radii.Select(_ => Pt.Zero)];
        var reach = radii.Select(r => r + Gap / 2).ToList();
        double Spread(double ring) => reach.Sum(r => 2 * Math.Asin(Math.Min(1, r / ring)));
        var low = reach.Max();
        var high = Math.Max(low, reach.Sum());
        if (Spread(low) > 2 * Math.PI)
        {
            for (var i = 0; i < 48; i++)
            {
                var middle = (low + high) / 2;
                if (Spread(middle) > 2 * Math.PI) low = middle; else high = middle;
            }
        }
        else high = low;
        var ringR = high;
        var widths = reach.Select(r => 2 * Math.Asin(Math.Min(1, r / ringR))).ToList();
        var spare = Math.Max(0, 2 * Math.PI - widths.Sum()) / radii.Count;
        var angle = -Math.PI / 2;
        var o = new List<Pt>();
        for (var n = 0; n < widths.Count; n++)
        {
            if (n > 0) angle += (widths[n - 1] + widths[n]) / 2 + spare;
            o.Add(new Pt(ringR * Math.Cos(angle), ringR * Math.Sin(angle)));
        }
        return o;
    }

    private static long Key(Pt p) => Key((int)Math.Floor(p.X / Cell), (int)Math.Floor(p.Y / Cell));
    private static long Key(int column, int row) => ((long)column << 32) | (uint)row;

    /// The stars whose centre is inside `rect`, in drawing order.
    public List<int> StarsIn(Box rect)
    {
        if (Stars.Count == 0 || rect.IsEmpty) return [];
        int minC = (int)Math.Floor(rect.MinX / Cell), maxC = (int)Math.Floor(rect.MaxX / Cell);
        int minR = (int)Math.Floor(rect.MinY / Cell), maxR = (int)Math.Floor(rect.MaxY / Cell);
        if ((long)(maxC - minC + 1) * (maxR - minR + 1) > Math.Max(64, Stars.Count / 2))
        {
            var all = new List<int>();
            for (var i = 0; i < Stars.Count; i++) if (rect.Contains(Stars[i].Point)) all.Add(i);
            return all;
        }
        var o = new List<int>();
        for (var c = minC; c <= maxC; c++)
            for (var r = minR; r <= maxR; r++)
            {
                if (!_grid.TryGetValue(Key(c, r), out var members)) continue;
                foreach (var m in members) if (rect.Contains(Stars[m].Point)) o.Add(m);
            }
        o.Sort();
        return o;
    }

    /// The star a click at `point` means: the nearest centre within `reach`. Ties go to the earlier star.
    public int? Hit(Pt point, double reach)
    {
        if (reach <= 0) return null;
        int? best = null; double bestD = 0;
        foreach (var m in StarsIn(new Box(point.X - reach, point.Y - reach, reach * 2, reach * 2)))
        {
            var s = Stars[m];
            var d = Math.Sqrt((s.Point.X - point.X) * (s.Point.X - point.X) + (s.Point.Y - point.Y) * (s.Point.Y - point.Y));
            if (d > reach) continue;
            if (best == null || d < bestD) { best = m; bestD = d; }
        }
        return best;
    }

    /// The cluster a double click at `point` means: the one whose edge is nearest, when within `reach` of it.
    public int? ClusterAt(Pt point, double reach)
    {
        int? best = null; double bestD = 0;
        for (var n = 0; n < Clusters.Count; n++)
        {
            var c = Clusters[n];
            var d = Math.Sqrt((c.Center.X - point.X) * (c.Center.X - point.X) + (c.Center.Y - point.Y) * (c.Center.Y - point.Y)) - c.Radius;
            if (d > reach) continue;
            if (best == null || d < bestD) { best = n; bestD = d; }
        }
        return best;
    }

    /// The whole map in a view of `width`×`height`: the largest zoom (at most `most`) at which every cluster and its name
    /// are inside, `margin` clear of the edges, and the world point to centre on. A name keeps its size on screen.
    public StarMapCamera Whole(double width, double height, double most = 1, double margin = 12, double names = 1)
    {
        if (Clusters.Count == 0 || width <= margin * 2 || height <= margin * 2) return new StarMapCamera();
        Box Extent(double scale)
        {
            var box = Box.Null;
            foreach (var c in Clusters)
            {
                var radius = c.Radius * scale;
                box = box.Union(new Box(c.Center.X * scale - radius, c.Center.Y * scale - radius, radius * 2, radius * 2));
                var guess = c.LabelBox; var anchor = c.LabelAnchor;
                double nw = guess.Width * Math.Max(1, names), nh = guess.Height * Math.Max(1, names);
                var px = c.Center.X * scale + c.LabelSide.X * (radius + LabelDrop);
                var py = c.Center.Y * scale + c.LabelSide.Y * (radius + LabelDrop);
                box = box.Union(new Box(px - nw * anchor.X, py - nh * anchor.Y, nw, nh));
            }
            return box;
        }
        bool Fits(double scale) { var b = Extent(scale); return b.Width <= width - margin * 2 && b.Height <= height - margin * 2; }
        var s = most;
        if (!Fits(most))
        {
            double low = 0.02, high = most;
            for (var i = 0; i < 32; i++) { var mid = (low + high) / 2; if (Fits(mid)) low = mid; else high = mid; }
            s = low;
        }
        var e = Extent(s);
        return new StarMapCamera(s, new Pt(e.MidX / s, e.MidY / s));
    }

    /// The scale at which `rect` (world) fills a view, with `margin` to spare on each side.
    public static double Fit(Box rect, double width, double height, double margin = 16)
    {
        if (rect.IsEmpty || width <= margin * 2 || height <= margin * 2) return 1;
        return Math.Min((width - margin * 2) / rect.Width, (height - margin * 2) / rect.Height);
    }
}

/// Where the map is looked at from: `Center` is the world point in the middle of the view.
public record struct StarMapCamera(double Scale, Pt Center)
{
    public const double MinZoom = 0.5, MaxZoom = 4;
    /// Star names are drawn above this.
    public const double LabelZoom = 1.6;
    /// One Zoom In / Zoom Out press (ZoomStep.stepFactor).
    public const double StepFactor = 1.5;

    public StarMapCamera() : this(1, Pt.Zero) { }

    public readonly Pt Screen(Pt w, double width, double height) => new((w.X - Center.X) * Scale + width / 2, (w.Y - Center.Y) * Scale + height / 2);
    public readonly Pt World(Pt s, double width, double height) => new((s.X - width / 2) / Scale + Center.X, (s.Y - height / 2) / Scale + Center.Y);

    public readonly Box Visible(double width, double height, double margin = 0)
    {
        double w = (width + margin * 2) / Scale, h = (height + margin * 2) / Scale;
        return new Box(Center.X - w / 2, Center.Y - h / 2, w, h);
    }

    /// The smallest zoom allowed: 0.5×, or less when the whole map needs it to fit.
    public static double Floor(double fit) => Math.Max(0.05, Math.Min(MinZoom, fit));

    /// Multiplies the zoom by `factor`, keeping the world point under `anchor` (a screen point) where it is.
    public void Zoom(double factor, Pt anchor, double width, double height, double floor)
    {
        var before = World(anchor, width, height);
        Scale = Math.Min(MaxZoom, Math.Max(floor, Scale * factor));
        var after = World(anchor, width, height);
        Center = new Pt(Center.X + before.X - after.X, Center.Y + before.Y - after.Y);
    }

    public void Pan(double dx, double dy) => Center = new Pt(Center.X - dx / Scale, Center.Y - dy / Scale);

    /// Keeps some of the map on screen: the centre never leaves the map's bounds.
    public void Clamp(Box bounds)
    {
        if (bounds.IsEmpty) { Center = Pt.Zero; return; }
        Center = new Pt(Math.Min(bounds.MaxX, Math.Max(bounds.MinX, Center.X)), Math.Min(bounds.MaxY, Math.Max(bounds.MinY, Center.Y)));
    }

    /// A star's half-width on screen: with the zoom below 1× (never under 0.75), gently above it.
    public readonly double StarRadius(double radius) => Scale <= 1 ? Math.Max(0.75, radius * Scale) : radius * Math.Sqrt(Scale);

    /// A scroll of `dy` as a zoom factor (ZoomStep.scrollFactor): a wheel's notch is a fifth of a step.
    public static double ScrollFactor(double dy, bool discrete)
    {
        if (!double.IsFinite(dy) || dy == 0) return 1;
        var f = Math.Pow(2, dy / (discrete ? 40 : 200));
        return Math.Min(StepFactor, Math.Max(1 / StepFactor, f));
    }
}
