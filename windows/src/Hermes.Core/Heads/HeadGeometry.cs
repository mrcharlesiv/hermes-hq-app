using System.Globalization;

namespace Hermes.Core.Heads;

// Shapes head geometry (spec 02 §10.4), ported from App/Heads/HeadGeometry.swift (the web app's `shapes.ts` and
// `parts.ts`). Everything here is in the icon's 1024×1024 space and is pure data: the outline, colours and marks a
// renderer draws, so it is unit-tested against the web renderer's vectors.

public readonly record struct P(double X, double Y);

/// An sRGB colour as 0xRRGGBB.
public readonly record struct HeadRgb(uint Hex)
{
    public byte R => (byte)(Hex >> 16);
    public byte G => (byte)(Hex >> 8);
    public byte B => (byte)Hex;
    public override string ToString() => $"#{Hex:X6}";
}

public abstract record HeadPrimitive
{
    /// SVG path data, local coordinates.
    public sealed record PathData(string D) : HeadPrimitive;
    public sealed record Rect(double X, double Y, double Width, double Height, double Rx) : HeadPrimitive;
    public sealed record Circle(double Cx, double Cy, double R) : HeadPrimitive;
    public sealed record Ellipse(double Cx, double Cy, double Rx, double Ry) : HeadPrimitive;
}

/// One step of an SVG transform list, applied in order (as `transform="translate(…) scale(…) rotate(…)"`).
public abstract record HeadTransformStep
{
    public sealed record Translate(double X, double Y) : HeadTransformStep;
    public sealed record Scale(double K) : HeadTransformStep;
    /// Degrees about a point.
    public sealed record Rotate(double Degrees, double Cx, double Cy) : HeadTransformStep;
}

/// A 2-D affine matrix (x' = M11·x + M21·y + OffsetX; y' = M12·x + M22·y + OffsetY), as XAML's Matrix.
public readonly record struct HeadMatrix(double M11, double M12, double M21, double M22, double OffsetX, double OffsetY)
{
    public static readonly HeadMatrix Identity = new(1, 0, 0, 1, 0, 0);

    /// `this` applied first, then `next`.
    public HeadMatrix Then(HeadMatrix n) => new(
        M11 * n.M11 + M12 * n.M21, M11 * n.M12 + M12 * n.M22,
        M21 * n.M11 + M22 * n.M21, M21 * n.M12 + M22 * n.M22,
        OffsetX * n.M11 + OffsetY * n.M21 + n.OffsetX, OffsetX * n.M12 + OffsetY * n.M22 + n.OffsetY);

    public P Apply(P p) => new(M11 * p.X + M21 * p.Y + OffsetX, M12 * p.X + M22 * p.Y + OffsetY);

    /// An SVG transform list as one matrix: the list's first step is the outermost (applied last to a point).
    public static HeadMatrix Of(IEnumerable<HeadTransformStep> steps)
    {
        var m = Identity;
        foreach (var step in steps)
        {
            HeadMatrix s = step switch
            {
                HeadTransformStep.Translate t => new(1, 0, 0, 1, t.X, t.Y),
                HeadTransformStep.Scale k => new(k.K, 0, 0, k.K, 0, 0),
                HeadTransformStep.Rotate r => Rotation(r.Degrees, r.Cx, r.Cy),
                _ => Identity,
            };
            m = s.Then(m);
        }
        return m;
    }

    public static HeadMatrix Rotation(double degrees, double cx, double cy)
    {
        var a = degrees * Math.PI / 180;
        double c = Math.Cos(a), s = Math.Sin(a);
        return new HeadMatrix(c, s, -s, c, cx - c * cx + s * cy, cy - s * cx - c * cy);
    }
}

public sealed record HeadStyle
{
    public HeadRgb? Fill { get; init; }
    public double FillOpacity { get; init; } = 1;
    public HeadRgb? Stroke { get; init; }
    public double StrokeWidth { get; init; }
    public double StrokeOpacity { get; init; } = 1;
    public double Opacity { get; init; } = 1;
    public bool RoundCap { get; init; }
    public bool RoundJoin { get; init; }

    public static HeadStyle Filled(HeadRgb c) => new() { Fill = c };
    public static HeadStyle Stroked(HeadRgb c, double width, bool cap = true, bool join = false) =>
        new() { Stroke = c, StrokeWidth = width, RoundCap = cap, RoundJoin = join };
}

public sealed record HeadMark(HeadPrimitive Primitive, IReadOnlyList<HeadTransformStep> Transform, HeadStyle Style)
{
    public HeadMark(HeadPrimitive primitive, HeadStyle style) : this(primitive, [], style) { }
    public HeadMatrix Matrix => HeadMatrix.Of(Transform);

    public bool Equals(HeadMark? other) => other is not null && Primitive == other.Primitive && Style == other.Style
        && Transform.SequenceEqual(other.Transform);
    public override int GetHashCode() => HashCode.Combine(Primitive, Style, Transform.Count);
}

/// `matrix(k 0 0 k tx ty)` that places the drawn head in the picture, rounded as the web writes it.
public readonly record struct HeadPlacement(double K, double Tx, double Ty);

/// Everything needed to draw one Shapes head, in 1024 space.
public sealed record ShapeHeadLayout(
    IReadOnlyList<P> Outline,
    string OutlinePath,
    HeadRgb Fill,
    HeadRgb? Rim,
    HeadRgb EyeColor,
    HeadPlacement? Placement,
    IReadOnlyList<HeadMark> Under,
    IReadOnlyList<HeadMark> Face,
    (HeadRgb Frame, HeadRgb Panel)? Board,
    P FaceCentre)
{
    /// The outline as cubic segments (the renderer's path; the web's numbers unrounded).
    public IReadOnlyList<(P C1, P C2, P To)> Segments => HeadGeometry.Spline(Outline).Segments;
}

/// [face-colour] The heads' tones (`robot.ts` TONES, `shapes.ts:113-133`): panel and accent per colour.
public static class HeadTones
{
    public static readonly HeadRgb Ink = new(0x0A0A0A);
    public static HeadRgb Accent(HeadColor c) => new(Tones[c].Accent);
    public static HeadRgb Panel(HeadColor c) => new(Tones[c].Panel);

    public static readonly Dictionary<HeadColor, (uint Panel, uint Accent)> Tones = new()
    {
        [HeadColor.Ink] = (0xF7F5F0, 0x2EC4B6), [HeadColor.Mint] = (0xBDEEDF, 0x078267), [HeadColor.Teal] = (0xAEE6EE, 0x057E93),
        [HeadColor.Sky] = (0xBCD9FF, 0x2770D9), [HeadColor.Lilac] = (0xD7CCFF, 0x795CDF), [HeadColor.Pink] = (0xFFC7E1, 0xCC3582),
        [HeadColor.Coral] = (0xFFC4B6, 0xCD422C), [HeadColor.Peach] = (0xFFDAB6, 0xC15003), [HeadColor.Butter] = (0xFFDAB6, 0xC15003),
        [HeadColor.Lime] = (0xB3E8C6, 0x03843C), [HeadColor.Paper] = (0xE7E1D3, 0xEFE9DB), [HeadColor.Red] = (0xF9B8B7, 0xDE2627),
        [HeadColor.Grass] = (0xB3E8C6, 0x03843C), [HeadColor.Forest] = (0xB0CEBF, 0x23784E), [HeadColor.Cobalt] = (0xB4C4FF, 0x2E5BFF),
        [HeadColor.Denim] = (0xB8C4E0, 0x3A5BA8), [HeadColor.Grape] = (0xD0B8F9, 0x7C3AED), [HeadColor.Plum] = (0xD5BAD9, 0x8A3F96),
        [HeadColor.Magenta] = (0xF4AFD5, 0xD91585), [HeadColor.Rose] = (0xFFC7E1, 0xCC3582), [HeadColor.Wine] = (0xE3B4C2, 0xB03055),
        [HeadColor.Caramel] = (0xD5C2B7, 0x8A5638), [HeadColor.Cocoa] = (0xD5C2B7, 0x8A5638), [HeadColor.Slate] = (0xCACED4, 0x6B7688),
    };

    /// Edit Head's swatch: ink #0A0A0A, paper #E7E1D3, else the colour's accent tone.
    public static HeadRgb Swatch(string name) => name switch
    {
        "ink" => new HeadRgb(0x0A0A0A),
        "paper" => new HeadRgb(0xE7E1D3),
        _ => HeadWire.Parse<HeadColor>(name) is { } c ? Accent(c) : new HeadRgb(0x8E8E93),
    };
}

public static class HeadGeometry
{
    public const double Unit = 300;
    const double Tau = Math.PI * 2;

    /// JavaScript's Math.round (halves go up, also for negatives).
    public static double JsRound(double v) => Math.Floor(v + 0.5);
    /// `n` in shapes.ts: one decimal.
    public static double N1(double v) => JsRound(v * 10) / 10;
    /// Three decimals (place() and placement scales).
    public static double N3(double v) => JsRound(v * 1000) / 1000;

    /// A number as JavaScript prints it ("14.1", "-54", "0").
    public static string Js(double v)
    {
        if (v == 0) return "0";
        if (v == Math.Round(v, MidpointRounding.AwayFromZero) && Math.Abs(v) < 1e15) return ((long)v).ToString(CultureInfo.InvariantCulture);
        return v.ToString("R", CultureInfo.InvariantCulture);
    }

    // ---- parts.ts helpers
    static P[] Around(int count, Func<double, P> at) =>
        [.. Enumerable.Range(0, count).Select(i => at((double)i / count * Tau - Math.PI / 2))];
    static P[] Sampled(int count, Func<double, P> at) => [.. Enumerable.Range(0, count).Select(i => at((double)i / count * Tau))];
    static P[] Ring(int count, Func<int, double> reach, double dy = 0) => [.. Enumerable.Range(0, count).Select(i =>
    {
        var a = -Math.PI / 2 + i * Tau / count;
        return new P(Math.Cos(a) * reach(i), Math.Sin(a) * reach(i) + dy);
    })];
    static P[] Rounded(P[] corners, double cut) => [.. corners.SelectMany((p, i) =>
    {
        P a = corners[(i + corners.Length - 1) % corners.Length], b = corners[(i + 1) % corners.Length];
        return new[] { new P(p.X + (a.X - p.X) * cut, p.Y + (a.Y - p.Y) * cut), new P(p.X + (b.X - p.X) * cut, p.Y + (b.Y - p.Y) * cut) };
    })];
    static P[] Superellipse(double w, double h, double power, int count = 40) => Around(count, t =>
    {
        double c = Math.Cos(t), s = Math.Sin(t);
        return new P(Math.Sign(c) * Math.Pow(Math.Abs(c), power) * w, Math.Sign(s) * Math.Pow(Math.Abs(s), power) * h);
    });
    static P[] Wobble(P[] points, int seed, double amount)
    {
        double a = seed % 997 / 997.0 * Tau, b = seed % 613 / 613.0 * Tau;
        return [.. points.Select(p =>
        {
            double t = Math.Atan2(p.Y, p.X), k = 1 + amount * (Math.Sin(3 * t + a) * 0.6 + Math.Sin(5 * t + b) * 0.4);
            return new P(p.X * k, p.Y * k);
        })];
    }
    internal static P[] Cloud()
    {
        (double, double, double)[] puffs = [(-0.58, -0.02, 0.44), (-0.14, -0.36, 0.5), (0.4, -0.26, 0.44), (0.72, 0.08, 0.36)];
        var origin = new P(0, 0.12);
        return Around(72, t =>
        {
            double dx = Math.Cos(t), dy = Math.Sin(t);
            var reach = 1 / Math.Sqrt((dx / 0.98) * (dx / 0.98) + (dy / 0.4) * (dy / 0.4));
            foreach (var (cx, cy, r) in puffs)
            {
                double x = cx - origin.X, y = cy - origin.Y, b = dx * x + dy * y, q = b * b - (x * x + y * y - r * r);
                if (q >= 0) reach = Math.Max(reach, b + Math.Sqrt(q));
            }
            return new P(origin.X + dx * reach, origin.Y + dy * reach);
        });
    }

    /// A closed Catmull-Rom spline through the points: the cubic segments, its path data as the web writes it (integer
    /// coordinates) and a dense outline (6 samples per segment).
    public static (List<(P C1, P C2, P To)> Segments, string D, List<P> Dense) Spline(IReadOnlyList<P> p)
    {
        var count = p.Count;
        var segments = new List<(P, P, P)>();
        var dense = new List<P>();
        static string R(double v) => Js(JsRound(v));
        var d = new System.Text.StringBuilder($"M{R(p[0].X)} {R(p[0].Y)}");
        for (var i = 0; i < count; i++)
        {
            P p0 = p[(i - 1 + count) % count], p1 = p[i], p2 = p[(i + 1) % count], p3 = p[(i + 2) % count];
            var c1 = new P(p1.X + (p2.X - p0.X) / 6, p1.Y + (p2.Y - p0.Y) / 6);
            var c2 = new P(p2.X - (p3.X - p1.X) / 6, p2.Y - (p3.Y - p1.Y) / 6);
            d.Append($"C{R(c1.X)} {R(c1.Y)} {R(c2.X)} {R(c2.Y)} {R(p2.X)} {R(p2.Y)}");
            segments.Add((c1, c2, p2));
            for (var step = 0; step < 6; step++)
            {
                double t = step / 6.0, u = 1 - t;
                dense.Add(new P(u * u * u * p1.X + 3 * u * u * t * c1.X + 3 * u * t * t * c2.X + t * t * t * p2.X,
                    u * u * u * p1.Y + 3 * u * u * t * c1.Y + 3 * u * t * t * c2.Y + t * t * t * p2.Y));
            }
        }
        return (segments, d + "Z", dense);
    }

    /// Each form's outline in unit space and where its face sits (x, y, size) (`shapes.ts:26-41`).
    public static (P[] Outline, (double X, double Y, double Size) Face) Form(HeadForm form, int seed) => form switch
    {
        HeadForm.Round => (Around(40, t => new P(Math.Cos(t), Math.Sin(t))), (0, -0.04, 1)),
        HeadForm.Blob => (Wobble(Around(40, t => new P(Math.Cos(t) * 1.05, Math.Sin(t) * 0.9 + 0.03)), seed, 0.08), (0, -0.04, 1)),
        HeadForm.Square => (Superellipse(0.93, 0.93, 0.3, 48), (0, -0.04, 1)),
        HeadForm.Pill => ([.. new[] { -1.0, 1.0 }.SelectMany(side => Enumerable.Range(0, 13).Select(i =>
            {
                var a = side * Math.PI / 2 + i * Math.PI / 12;
                return new P(-side * 0.42 + Math.Cos(a) * 0.66, Math.Sin(a) * 0.66);
            }))], (0, -0.02, 0.92)),
        HeadForm.Triangle => (Rounded([new P(0, -1.04), new P(1.06, 0.78), new P(-1.06, 0.78)], 0.24), (0, 0.3, 0.86)),
        HeadForm.Hex => (Rounded(Ring(6, _ => 1), 0.2), (0, -0.02, 1)),
        HeadForm.Cloud => ([.. Cloud().Select(p => new P(p.X * 1.04 - 0.06, p.Y * 1.04 + 0.14))], (-0.02, 0.1, 0.92)),
        HeadForm.Drop => (Sampled(48, t => new P(1.04 * Math.Sin(t) * Math.Pow(Math.Sin(t / 2), 0.8), -Math.Cos(t) * 1.06 - 0.08)), (0, 0.34, 0.9)),
        HeadForm.Star => (Rounded(Ring(10, i => i % 2 == 1 ? 0.58 : 1.08, 0.08), 0.18), (0, 0.12, 0.78)),
        _ => (Sampled(48, t =>
        {
            var s = Math.Sin(t);
            return new P(s * s * s * 1.02, -(13 * Math.Cos(t) - 5 * Math.Cos(2 * t) - 2 * Math.Cos(3 * t) - Math.Cos(4 * t)) / 16 - 0.12);
        }), (-0.04, 0.08, 0.9)),
    };

    static ((double X, double Y) At, (double, double) Lean) Pose(HeadState state) => state switch
    {
        HeadState.Idle => ((0.3, -0.28), (-20, -20)),
        HeadState.Thinking or HeadState.Speaking => ((0, 0.02), (0, 0)),
        HeadState.Done => ((0, -0.08), (24, -24)),
        _ => ((0, 0.1), (90, 90)),
    };

    // ---- hats (placement only: hats are never drawn, owner 2026-10-08)
    static readonly Dictionary<HeadHat, (double, double, double)> HatBox = new()
    {
        [HeadHat.Crown] = (-186, -197, 163), [HeadHat.Halo] = (-179, -154, 179), [HeadHat.Sprout] = (-131, -178, 154),
        [HeadHat.Party] = (-114, -307, 178), [HeadHat.Bow] = (-59, -64, 206),
    };

    public static (double X, double Y, double Stretch) HatSeat(Head head, IReadOnlyList<P> points)
    {
        var fx = Form(head.Form, head.Seed).Face.X;
        var near = points.Where(p => Math.Abs(p.X - fx) < 0.35).ToList();
        var pool = near.Count == 0 ? points.ToList() : near;
        var top = pool.Skip(1).Aggregate(pool[0], (best, p) => p.Y < best.Y ? p : best);
        var below = points.Where(p => Math.Abs(p.Y - (top.Y + 0.3)) < 0.12).ToList();
        var half = below.Count == 0 ? 160 : below.Max(p => Math.Abs(p.X - top.X)) * Unit;
        var x = 512 + top.X * Unit + (head.Hat == HeadHat.Bow ? half * 0.45 - 74 : 0);
        return (x, 512 + top.Y * Unit, JsRound(Math.Max(130, Math.Min(190, half)) / 1.6) / 100);
    }

    /// `placing` (`shapes.ts:86-99`): how the head fills the picture. `withHat` only for the test vectors.
    public static HeadPlacement? Placement(Head head, IReadOnlyList<P> points, bool withHat)
    {
        var hat = withHat ? head.Hat : HeadHat.None;
        if (head.Tile != HeadTile.None) return hat == HeadHat.None ? null : new HeadPlacement(0.8, 102.4, 160);
        var drawn = Spline(points).Dense.Select(p => new P(512 + p.X * Unit, 512 + p.Y * Unit)).ToList();
        if (hat != HeadHat.None)
        {
            var seat = HatSeat(head, points);
            var box = hat == HeadHat.Beanie ? (-170 * seat.Stretch, -136, 170 * seat.Stretch) : HatBox[hat];
            drawn.Add(new P(seat.X + box.Item1, seat.Y + box.Item2));
            drawn.Add(new P(seat.X + box.Item3, seat.Y));
        }
        double left = drawn.Min(p => p.X), right = drawn.Max(p => p.X), top = drawn.Min(p => p.Y), bottom = drawn.Max(p => p.Y);
        var k = Math.Min(984 / (right - left), 984 / (bottom - top));
        return new HeadPlacement(N3(k), N1(512 - k * (left + right) / 2), N1(512 - k * (top + bottom) / 2));
    }

    // ---- constant markup (`shapes.ts:55-56,102-164`)
    public static readonly string Star = PathData(Enumerable.Range(0, 10).Select(i =>
    {
        double a = -Math.PI / 2 + i * Math.PI / 5, r = i % 2 == 1 ? 24.0 : 54.0;
        return new P(Math.Cos(a) * r, Math.Sin(a) * r);
    }));
    public static readonly string Heart = PathData(Sampled(28, t =>
    {
        var s = Math.Sin(t);
        return new P(s * s * s * 51, 3 - (13 * Math.Cos(t) - 5 * Math.Cos(2 * t) - 2 * Math.Cos(3 * t) - Math.Cos(4 * t)) / 16 * 51);
    }));
    static string PathData(IEnumerable<P> points) => "M" + string.Join("L", points.Select(p => $"{Js(N1(p.X))} {Js(N1(p.Y))}")) + "Z";

    public static readonly HeadRgb Gold = new(0xF5C542);
    public static readonly HeadRgb White = new(0xFFFFFF);
    public static readonly HeadRgb DarkEye = new(0x1A1A1A);

    /// Whether inverting the head's light-page picture gives its dark-page one (the desktop copy's dark-flip mark).
    public static bool InvertsOnDarkPage(Head head)
    {
        if (head.Theme == HeadTheme.Matrix) return head.Color == HeadColor.Ink && !head.Blush;
        return head.Themed == null && head.Color == HeadColor.Ink && head.Tile == HeadTile.None && !head.Blush
            && head.Look != HeadLook.Hearts && head.Look != HeadLook.Googly && (head.Specs == HeadSpecs.None || head.Specs == HeadSpecs.Round);
    }

    /// The whole layout of a Shapes head: outline, colours, placement and every mark (spec 02 §10.4).
    /// `darkPage`: the page mode (null = unknown, as for the desktop copy). `compact`: a small picture (side &lt; 64)
    /// draws bolder eyes. `withHatPlacement`: only for the test vectors; drawn heads never wear hats.
    public static ShapeHeadLayout Layout(Head head, HeadState state = HeadState.Idle, bool compact = true, bool? darkPage = false,
        bool withHatPlacement = false)
    {
        bool dark = head.Tile == HeadTile.Dark, bare = head.Tile == HeadTile.None;
        var panel = dark ? new HeadRgb(0x1C1C1E) : head.Tile == HeadTile.Color ? HeadTones.Panel(head.Color) : new HeadRgb(0xF7F5F0);
        var fill = head.Color switch
        {
            HeadColor.Ink => dark || (bare && darkPage == true) ? new HeadRgb(0xF4F4F2) : HeadTones.Ink,
            HeadColor.Paper => dark || bare ? new HeadRgb(0xEFE9DB) : head.Tile == HeadTile.Color ? new HeadRgb(0xFFFDF8) : new HeadRgb(0xD9D0BD),
            _ => HeadTones.Accent(head.Color),
        };
        HeadRgb? rim = bare && (head.Color == HeadColor.Paper || (head.Color == HeadColor.Ink && darkPage == null))
            ? (head.Color == HeadColor.Ink ? new HeadRgb(0x636366) : new HeadRgb(0xB8AD95)) : null;
        var shape = Form(head.Form, head.Seed);
        var (fx, fy, size) = shape.Face;
        var points = shape.Outline;
        var mapped = points.Select(p => new P(512 + p.X * Unit, 512 + p.Y * Unit)).ToList();
        var outlineD = Spline(mapped).D;

        var p = Pose(state);
        var flat = state == HeadState.Offline;
        var look = flat ? HeadLook.Slits : head.Look;
        var narrow = state is HeadState.Thinking or HeadState.Speaking ? 0.86 : 1;
        double bold = compact ? 1.2 : 1, s = Unit * size;
        bool googly = look == HeadLook.Googly, glasses = head.Specs != HeadSpecs.None;
        var gap = (glasses ? 0.26 : googly ? 0.24 : 0.2) * s;
        double cx = 512 + (fx + p.At.X * size) * Unit, cy = 512 + (fy + p.At.Y * size) * Unit;
        var ink = darkPage == true || head.Color == HeadColor.Paper || fill == new HeadRgb(0xF4F4F2) ? DarkEye : White;

        List<HeadMark> Place(double x, double y, double k, List<HeadMark> body, double turn = 0)
        {
            var steps = new List<HeadTransformStep> { new HeadTransformStep.Translate(N1(x), N1(y)), new HeadTransformStep.Scale(N3(k)) };
            if (turn != 0) steps.Add(new HeadTransformStep.Rotate(N1(turn), 0, 0));
            return [.. body.Select(m => m with { Transform = [.. steps, .. m.Transform] })];
        }
        List<HeadMark> Eye(double side)
        {
            double x = N1(cx + side * gap), y = N1(cy), lean = side < 0 ? p.Lean.Item1 : p.Lean.Item2;
            double w = 0.15 * s * bold, h = (flat ? 0.28 : 0.38 * narrow) * s;
            switch (look)
            {
                case HeadLook.Dots:
                    return [new HeadMark(new HeadPrimitive.Circle(x, y, N1(0.11 * s * bold)), HeadStyle.Filled(ink))];
                case HeadLook.Ovals:
                    return [new HeadMark(new HeadPrimitive.Ellipse(x, y, N1(0.11 * s * bold), N1(0.19 * s * narrow)),
                        [new HeadTransformStep.Rotate(lean / 2, x, y)], HeadStyle.Filled(ink))];
                case HeadLook.Googly:
                    var ring = HeadStyle.Filled(White) with { Stroke = ink, StrokeWidth = 9 * bold };
                    return Place(x, y, size, [
                        new HeadMark(new HeadPrimitive.Circle(0, 0, 51), ring),
                        new HeadMark(new HeadPrimitive.Circle(N1(p.At.X * 60), N1(p.At.Y * 60), N1(25.5 * bold)), HeadStyle.Filled(DarkEye)),
                    ]);
                case HeadLook.Happy:
                    return Place(x, y, size * bold, [new HeadMark(new HeadPrimitive.PathData("M-39 15Q0-48 39 15"), HeadStyle.Stroked(ink, 24))]);
                case HeadLook.Sleepy:
                    return Place(x, y, size * bold, [new HeadMark(new HeadPrimitive.PathData("M-42-9A42 33 0 0 0 42-9Z"), HeadStyle.Filled(ink))]);
                case HeadLook.Stars:
                    return Place(x, y, size * bold, [new HeadMark(new HeadPrimitive.PathData(Star), HeadStyle.Filled(ink))], lean / 2);
                case HeadLook.Hearts:
                    return Place(x, y, size * bold, [new HeadMark(new HeadPrimitive.PathData(Heart), HeadStyle.Filled(new HeadRgb(0xFF4D8D)))]);
                default:
                    return [new HeadMark(new HeadPrimitive.Rect(N1(x - w / 2), N1(y - h / 2), N1(w), N1(h), N1(w / 2)),
                        [new HeadTransformStep.Rotate(lean, x, y)], HeadStyle.Filled(ink))];
            }
        }
        HeadMark Bridge(HeadRgb c) => new(new HeadPrimitive.PathData("M-18-30Q0-48 18-30"), HeadStyle.Stroked(c, 16.5));
        List<HeadMark> face;
        switch (head.Specs)
        {
            case HeadSpecs.Shades:
                face = Place(cx, cy, size, [
                    new HeadMark(new HeadPrimitive.PathData("M-144-45H-12V6Q-12 51-63 51H-93Q-144 51-144 6ZM12-45H144V6Q144 51 93 51H63Q12 51 12 6Z"),
                        HeadStyle.Filled(new HeadRgb(0x111318))),
                    new HeadMark(new HeadPrimitive.PathData("M-117-18l24-16.5M39-18l24-16.5"), HeadStyle.Stroked(White, 12) with { StrokeOpacity = 0.6 }),
                    Bridge(new HeadRgb(0x111318)),
                ]);
                break;
            case HeadSpecs.Aviators:
                face = Place(cx, cy, size, [
                    new HeadMark(new HeadPrimitive.PathData("M18-42H138Q147 36 87 57Q21 51 18-42ZM-18-42H-138Q-147 36-87 57Q-21 51-18-42Z"),
                        HeadStyle.Filled(new HeadRgb(0x26323F)) with { Stroke = Gold, StrokeWidth = 10.5, RoundJoin = true }),
                    new HeadMark(new HeadPrimitive.PathData("M-48-21l-18-12M48-21l18-12"), HeadStyle.Stroked(White, 10.5) with { StrokeOpacity = 0.5 }),
                    Bridge(Gold),
                ]);
                break;
            default:
                face = [.. Eye(-1), .. Eye(1)];
                break;
        }
        HeadMark LensRing(double x, HeadRgb c) =>
            new(new HeadPrimitive.Circle(x, 0, 66), HeadStyle.Filled(White) with { FillOpacity = 0.18, Stroke = c, StrokeWidth = 15 });
        var clear = new List<HeadMark>();
        if (head.Specs == HeadSpecs.Round)
            clear = Place(cx, cy, size, [LensRing(-78, ink), LensRing(78, ink),
                new HeadMark(new HeadPrimitive.PathData("M-15-30Q0-48 15-30"), HeadStyle.Stroked(ink, 15))]);
        else if (head.Specs == HeadSpecs.Monocle)
            clear = Place(cx, cy, size, [LensRing(78, Gold),
                new HeadMark(new HeadPrimitive.PathData("M123 48q42 78 6 144"), HeadStyle.Stroked(Gold, 7.5, cap: false))]);
        var mouth = new List<HeadMark>();
        if (head.Mouth != HeadMouth.None)
        {
            var line = HeadStyle.Stroked(ink, N1(19.5 * bold), cap: true, join: true);
            var body = head.Mouth switch
            {
                HeadMouth.Smile => new HeadMark(new HeadPrimitive.PathData("M-48 0Q0 48 48 0"), line),
                HeadMouth.Open => new HeadMark(new HeadPrimitive.Ellipse(0, 9, 22.5, 27), HeadStyle.Filled(ink)),
                HeadMouth.Cat => new HeadMark(new HeadPrimitive.PathData("M-48 0Q-24 30 0 0Q24 30 48 0"), line),
                _ => new HeadMark(new HeadPrimitive.PathData("M-30 6h60"), line),
            };
            mouth = Place(cx, cy + (googly || glasses ? 0.36 : 0.32) * s, size, [body]);
        }
        var blush = new List<HeadMark>();
        if (head.Blush)
        {
            var cheek = N1(gap / size + 42);
            var st = HeadStyle.Filled(new HeadRgb(0xFF7FA8)) with { Opacity = 0.8 };
            blush = Place(cx, cy, size, [new HeadMark(new HeadPrimitive.Ellipse(-cheek, 66, 30, 18), st),
                new HeadMark(new HeadPrimitive.Ellipse(cheek, 66, 30, 18), st)]);
        }
        return new ShapeHeadLayout(mapped, outlineD, fill, rim, ink, Placement(head, points, withHatPlacement),
            [.. blush, .. mouth, .. clear], face, bare ? null : (dark ? new HeadRgb(0x000000) : HeadTones.Ink, panel), new P(cx, cy));
    }

    // ---- the icon's board (`parts.ts:8-9`)
    public const string Frame = "M350 0h324c101 0 151 0 205 17 60 22 106 68 128 128 17 54 17 104 17 205v324c0 101 0 151-17 205-22 60-68 106-128 128-54 17-104 17-205 17h-324c-101 0-151 0-205-17-60-22-106-68-128-128-17-54-17-104-17-205v-324c0-101 0-151 17-205 22-60 68-106 128-128 54-17 104-17 205-17z";
    public const string PanelPath = "M322 54h380c77 0 116 0 157 13 46 17 81 52 98 98 13 41 13 80 13 157v380c0 77 0 116-13 157-17 46-52 81-98 98-41 13-80 13-157 13h-380c-77 0-116 0-157-13-46-17-81-52-98-98-13-41-13-80-13-157v-380c0-77 0-116 13-157 17-46 52-81 98-98 41-13 80-13 157-13z";
}
