using System.Globalization;
using System.Text;

namespace Hermes.Core.Heads;

// The dot-matrix head (the Matrix theme), ported from App/Heads/MatrixHead.swift: a face of 20 × 20 round LEDs in one
// of thirteen outlines, drawn by hand on a 15 × 15 grid and traced onto the finer one, lit in the bot's own colour on the
// side it turns to and fading toward the back, its eyes LEDs left dark. On a dark page the LEDs glow; on a light one they
// are coloured dots with dark eyes. The grid is pure data here; `MatrixHeadSvg` writes it as SVG for the renderer.

public enum MatrixSilhouette { Round, Square, Tall, Wide, Pebble, Cloud, Arch, Shield, Drop, Leaf, Hex, Octagon, Heart }
public enum MatrixEyes { Slits, Dots, Ovals, Googly, Happy, Sleepy, Stars, Hearts, Crossed }
public enum MatrixMouth { None, Smile, Open, Cat, Line }

public static class MatrixSilhouettes
{
    /// A saved head's `form`: an outline's own name, else a Shapes head's form as the outline nearest it.
    public static MatrixSilhouette FromStored(string form) => HeadWire.Parse<MatrixSilhouette>(form) ?? form switch
    {
        "pill" => MatrixSilhouette.Tall,
        "blob" => MatrixSilhouette.Pebble,
        "triangle" => MatrixSilhouette.Drop,
        "star" => MatrixSilhouette.Octagon,
        _ => MatrixSilhouette.Round,
    };

    /// The Shapes form nearest this outline, for a dot-matrix head that becomes a Shapes head.
    public static string ShapesForm(MatrixSilhouette s) => s switch
    {
        MatrixSilhouette.Round or MatrixSilhouette.Arch => "round",
        MatrixSilhouette.Square or MatrixSilhouette.Shield => "square",
        MatrixSilhouette.Tall or MatrixSilhouette.Wide => "pill",
        MatrixSilhouette.Pebble => "blob",
        MatrixSilhouette.Cloud => "cloud",
        MatrixSilhouette.Drop or MatrixSilhouette.Leaf => "drop",
        MatrixSilhouette.Hex or MatrixSilhouette.Octagon => "hex",
        _ => "heart",
    };
}

/// What a dot-matrix head is made of: an outline and a face, on the same grid.
public sealed record MatrixDesign
{
    public MatrixSilhouette Silhouette { get; init; } = MatrixSilhouette.Round;
    public MatrixEyes Eyes { get; init; } = MatrixEyes.Slits;
    public MatrixMouth Mouth { get; init; } = MatrixMouth.None;
    public bool Blush { get; init; }
    /// The LED colour, sRGB 0xRRGGBB.
    public uint Color { get; init; } = 0x9479FF;
    /// Ink: white LEDs on a dark page, black ones on a light page.
    public bool Mono { get; init; }
    /// −1 turned to the left, +1 to the right.
    public int Facing { get; init; } = 1;

    /// A head's outline and face: its colour's accent, turned to the right as every head is, slit eyes and nothing else.
    public static MatrixDesign Of(Head head) => new()
    {
        Silhouette = head.Silhouette, Eyes = MatrixEyes.Slits, Mouth = MatrixMouth.None, Blush = false,
        Mono = head.Color == HeadColor.Ink, Color = HeadTones.Accent(head.Color).Hex, Facing = MatrixHead.ShownFacing,
    };
}

/// A moment of the face: where the eyes look and how far the lids are down.
public readonly record struct MatrixPose(int Gaze = 0, int Lift = 0, int Lids = 0)
{
    public static readonly MatrixPose Rest = new();
    /// How a head rests on screen: its eyes over to the right, at the words beside it.
    public static readonly MatrixPose Look = new(Gaze: 1);
    public MatrixPose Mirrored => this with { Gaze = -Gaze };
}

public enum MatrixDotKind { Body, Hole, White, Blush, Pupil }

public readonly record struct MatrixDot(int Col, int Row, MatrixDotKind Kind, double Light, double Hot);

public readonly record struct Cell(int Col, int Row);

public static class MatrixHead
{
    /// LEDs across (and down) a head.
    public const int Grid = 20;
    /// The grid the outlines and faces are drawn on.
    public const int Drawn = 15;
    /// The way every head is drawn: turned to the right, toward the words beside it (owner, 2026-11-16).
    public const int ShownFacing = 1;

    public readonly record struct Box(double Cx, double Cy, double Hw, double Hh);

    public static Box BoxOf(bool[][] body)
    {
        var size = body.Length;
        var rows = Enumerable.Range(0, size).Where(r => body[r].Contains(true)).ToList();
        var cols = Enumerable.Range(0, size).Where(c => body.Any(row => row[c])).ToList();
        if (rows.Count == 0 || cols.Count == 0) return new Box(size / 2.0, size / 2.0, 1, 1);
        int top = rows[0], bottom = rows[^1], first = cols[0], last = cols[^1];
        return new Box((first + last + 1) / 2.0, (top + bottom + 1) / 2.0, (last - first + 1) / 2.0, (bottom - top + 1) / 2.0);
    }

    /// The way a head with this seed was turned when heads faced either way (bit 7).
    public static int Facing(int seed) => ((seed >> 7) & 1) == 0 ? -1 : 1;

    /// `seed` turned to face the other way (bit 7 flipped; 128, which would become 0, becomes 256).
    public static int Turned(int seed)
    {
        var next = seed ^ 0x80;
        return next > 0 ? next : 0x100;
    }

    // MARK: Outlines

    public sealed class Outline
    {
        public bool[][] Body { get; init; } = [];
        public int EyeRow { get; init; }
        public int Left { get; init; }
        public int Right { get; init; }

        public static Outline From(string[] drawing)
        {
            var eyes = drawing.SelectMany((line, row) => line.Select((ch, col) => (ch, col, row)).Where(x => x.ch == 'o')
                .Select(x => new Cell(x.col, x.row))).ToList();
            return new Outline
            {
                Body = [.. drawing.Select(line => line.Select(ch => ch != '.').ToArray())],
                EyeRow = eyes.Count > 0 ? eyes[0].Row : Drawn / 2,
                Left = eyes.Count > 0 ? eyes[0].Col : Drawn / 2 - 2,
                Right = eyes.Count > 0 ? eyes[^1].Col : Drawn / 2 + 2,
            };
        }

        public Outline Mirrored => new()
        {
            Body = [.. Body.Select(r => Enumerable.Reverse(r).ToArray())], EyeRow = EyeRow, Left = Drawn - 1 - Right, Right = Drawn - 1 - Left,
        };

        public bool Contains(Cell c) => c.Row >= 0 && c.Row < Drawn && c.Col >= 0 && c.Col < Drawn && Body[c.Row][c.Col];
    }

    static readonly Dictionary<MatrixSilhouette, Outline> Outlines =
        Enum.GetValues<MatrixSilhouette>().ToDictionary(s => s, s => Outline.From(Drawing(s)));

    public static Outline OutlineOf(MatrixSilhouette s, int facing) => facing < 0 ? Outlines[s].Mirrored : Outlines[s];
    public static Outline OutlineOf(MatrixDesign d) => OutlineOf(d.Silhouette, d.Facing);

    /// Each outline LED by LED, facing right: `#` an LED, `o` the LED an eye is centred on (the eye line).
    public static string[] Drawing(MatrixSilhouette s) => s switch
    {
        MatrixSilhouette.Round => [".....#####.....", "...#########...", "..###########..", ".#############.", ".#############.", "###############",
            "######o###o####", "###############", "###############", "###############", ".#############.", ".#############.", "..###########..",
            "...#########...", ".....#####....."],
        MatrixSilhouette.Square => ["...............", "...#########...", "..###########..", ".#############.", ".#############.", ".#############.",
            ".#####o###o###.", ".#############.", ".#############.", ".#############.", ".#############.", ".#############.", "..###########..",
            "...#########...", "..............."],
        MatrixSilhouette.Tall => ["......###......", "....#######....", "...#########...", "...#########...", "..###########..", "..###########..",
            "..###########..", "..###o###o###..", "..###########..", "..###########..", "..###########..", "...#########...", "...#########...",
            "....#######....", "......###......"],
        MatrixSilhouette.Wide => ["...............", "...............", "....#######....", "..###########..", ".#############.", ".#############.",
            "#####o###o#####", "###############", "###############", ".#############.", ".#############.", "..###########..", "....#######....",
            "...............", "..............."],
        MatrixSilhouette.Pebble => ["...............", ".......#####...", ".....#########.", "...###########.", "..#############", ".##############",
            "######o###o####", "###############", "###############", "##############.", "#############..", ".###########...", "..#########....",
            "....#####......", "..............."],
        MatrixSilhouette.Cloud => ["...............", ".........####..", "..###...######.", ".#####.#######.", "###############", "###############",
            "###############", "######o###o####", "###############", "###############", "###############", "###############", ".#############.",
            "...#########...", "..............."],
        MatrixSilhouette.Arch => [".....#####.....", "...#########...", "..###########..", "..###########..", ".#############.", ".#############.",
            ".#############.", ".#####o###o###.", ".#############.", ".#############.", ".#############.", ".#############.", ".#############.",
            ".#############.", "..###########.."],
        MatrixSilhouette.Shield => [".#############.", "###############", "###############", "###############", "###############", "######o###o####",
            "###############", "###############", ".#############.", ".#############.", "..###########..", "...#########...", "....#######....",
            ".....#####.....", "......###......"],
        MatrixSilhouette.Drop => [".......#.......", "......###......", ".....#####.....", "....#######....", "...#########...", "..###########..",
            ".#############.", ".#############.", "###############", "#####o###o#####", "###############", ".#############.", ".#############.",
            "..###########..", "....#######...."],
        MatrixSilhouette.Leaf => ["...............", "......########.", "....##########.", "...###########.", "..############.", "..############.",
            ".#####o###o###.", ".#############.", ".#############.", ".############..", ".############..", ".###########...", ".##########....",
            ".########......", "..............."],
        MatrixSilhouette.Hex => [".......#.......", ".....#####.....", "...#########...", ".#############.", ".#############.", ".#############.",
            ".#####o###o###.", ".#############.", ".#############.", ".#############.", ".#############.", ".#############.", "...#########...",
            ".....#####.....", ".......#......."],
        MatrixSilhouette.Octagon => [".....#####.....", "....#######....", "...#########...", "..###########..", ".#############.", "###############",
            "###############", "######o###o####", "###############", "###############", ".#############.", "..###########..", "...#########...",
            "....#######....", ".....#####....."],
        _ => ["...............", "..####...####..", ".######.######.", "###############", "###############", "###############",
            "#####o###o#####", ".#############.", ".#############.", "..###########..", "...#########...", "....#######....", ".....#####.....",
            "......###......", ".......#......."],
    };

    // MARK: The head's LEDs

    static readonly Dictionary<MatrixSilhouette, bool[][]> Traced =
        Enum.GetValues<MatrixSilhouette>().ToDictionary(s => s, s => Trace(OutlineOf(s, 1)));

    public static bool[][] Leds(MatrixSilhouette s, int facing) =>
        facing < 0 ? [.. Traced[s].Select(r => Enumerable.Reverse(r).ToArray())] : Traced[s];

    public static bool[][] Leds(MatrixDesign d) => Leds(d.Silhouette, d.Facing);

    /// A drawn outline on the head's grid: the drawing softened (each drawn LED a square, blurred by 0.85 of one) and an
    /// LED lit where it is more than half covered; then an LED touching fewer than two others is dropped.
    public static bool[][] Trace(Outline outline)
    {
        double step = (double)Drawn / Grid, spread = 0.85 * Math.Sqrt(2.0);
        double Share(double lo, double x) => 0.5 * (Erf((lo + 1 - x) / spread) - Erf((lo - x) / spread));
        var body = new bool[Grid][];
        for (var row = 0; row < Grid; row++)
        {
            body[row] = new bool[Grid];
            for (var col = 0; col < Grid; col++)
            {
                double x = (col + 0.5) * step, y = (row + 0.5) * step, covered = 0;
                for (var r = Math.Max(0, (int)y - 3); r <= Math.Min(Drawn - 1, (int)y + 3); r++)
                {
                    var down = Share(r, y);
                    for (var c = Math.Max(0, (int)x - 3); c <= Math.Min(Drawn - 1, (int)x + 3); c++)
                        if (outline.Body[r][c]) covered += down * Share(c, x);
                }
                body[row][col] = covered > 0.5;
            }
        }
        var changed = true;
        while (changed)
        {
            changed = false;
            for (var row = 0; row < Grid; row++)
                for (var col = 0; col < Grid; col++)
                {
                    if (!body[row][col]) continue;
                    var touching = 0;
                    for (var dr = -1; dr <= 1; dr++)
                        for (var dc = -1; dc <= 1; dc++)
                            if ((dr != 0 || dc != 0) && row + dr is >= 0 and < Grid && col + dc is >= 0 and < Grid && body[row + dr][col + dc]) touching++;
                    if (touching < 2) { body[row][col] = false; changed = true; }
                }
        }
        return body;
    }

    /// The error function to double precision (|error| &lt; 1e-15 over the range traced): exp(−x²)·Σ 2ⁿx²ⁿ⁺¹/(2n+1)!!,
    /// a series of positive terms, so nothing cancels.
    public static double Erf(double x)
    {
        if (double.IsNaN(x)) return x;
        if (x < 0) return -Erf(-x);
        if (x > 6) return 1;
        double term = x, sum = x, x2 = x * x;
        for (var n = 1; n < 500; n++)
        {
            term *= 2 * x2 / (2 * n + 1);
            sum += term;
            if (term < sum * 1e-17) break;
        }
        return 2 / Math.Sqrt(Math.PI) * Math.Exp(-x2) * sum;
    }

    /// Every LED of `design` at `pose`, lit or not, row by row.
    public static List<MatrixDot> Dots(MatrixDesign design, MatrixPose pose = default)
    {
        var body = Leds(design);
        var box = BoxOf(body);
        var face = FaceLeds(design, pose);
        var dots = new List<MatrixDot>();
        for (var row = 0; row < Grid; row++)
            for (var col = 0; col < Grid; col++)
            {
                if (!body[row][col]) continue;
                var (light, hot) = Lighting(design, box, col + 0.5, row + 0.5);
                dots.Add(new MatrixDot(col, row, face.TryGetValue(new Cell(col, row), out var k) ? k : MatrixDotKind.Body, light, hot));
            }
        return dots;
    }

    static readonly MatrixDotKind[] FaceOrder = [MatrixDotKind.Pupil, MatrixDotKind.White, MatrixDotKind.Hole, MatrixDotKind.Blush];

    /// The face on the head's grid: worked out on the drawn grid and each part scaled up on its own.
    public static Dictionary<Cell, MatrixDotKind> FaceLeds(MatrixDesign design, MatrixPose pose)
    {
        if (design.Facing < 0)
            return FaceLeds(design with { Facing = 1 }, pose.Mirrored).ToDictionary(kv => new Cell(Grid - 1 - kv.Key.Col, kv.Key.Row), kv => kv.Value);
        var face = FaceCells(design, OutlineOf(design), pose);
        var kinds = face.Kinds;
        var leds = new Dictionary<Cell, MatrixDotKind>();
        foreach (var part in face.Parts)
            foreach (var (cell, kind) in Scaled(part, kinds, new Cell(pose.Gaze, pose.Lift)))
                if (!leds.TryGetValue(cell, out var was) || Array.IndexOf(FaceOrder, was) > Array.IndexOf(FaceOrder, kind)) leds[cell] = kind;
        return leds;
    }

    /// One part of the face on the head's grid (`scaled` in MatrixHead.swift).
    public static Dictionary<Cell, MatrixDotKind> Scaled(HashSet<Cell> part, Dictionary<Cell, MatrixDotKind> kinds, Cell moved)
    {
        if (part.Count == 0) return [];
        int first = part.Min(c => c.Col), last = part.Max(c => c.Col), top = part.Min(c => c.Row), bottom = part.Max(c => c.Row);
        double scale = (double)Grid / Drawn;
        const int samples = 4;
        int w = last - first + 1, h = bottom - top + 1;
        int wide = Math.Max(1, (int)Math.Round(w * scale, MidpointRounding.AwayFromZero)), high = Math.Max(1, (int)Math.Round(h * scale, MidpointRounding.AwayFromZero));
        int Start(int from, int span, int count)
        {
            var middle = (from + span / 2.0) * scale;
            var centre = count % 2 == 1 ? Math.Round(middle - 0.5, MidpointRounding.AwayFromZero) + 0.5 : Math.Round(middle, MidpointRounding.AwayFromZero);
            return (int)(centre - count / 2.0);
        }
        int left = Start(first - moved.Col, w, wide) + moved.Col, upper = Start(top - moved.Row, h, high) + moved.Row;
        var leds = new Dictionary<Cell, MatrixDotKind>();
        for (var row = upper; row < upper + high; row++)
            for (var col = left; col < left + wide; col++)
            {
                var counts = new int[FaceOrder.Length];
                for (var sy = 0; sy < samples; sy++)
                    for (var sx = 0; sx < samples; sx++)
                    {
                        var fx = (col - left + (sx + 0.5) / samples) / wide;
                        var fy = (row - upper + (sy + 0.5) / samples) / high;
                        var cell = new Cell(first + (int)(fx * w), top + (int)(fy * h));
                        if (part.Contains(cell) && kinds.TryGetValue(cell, out var kind)) counts[Array.IndexOf(FaceOrder, kind)]++;
                    }
                if (counts.Sum() * 2 <= samples * samples) continue;
                leds[new Cell(col, row)] = FaceOrder[Array.IndexOf(counts, counts.Max())];
            }
        return leds;
    }

    public static double Smooth(double a, double b, double x)
    {
        var t = Math.Max(0, Math.Min(1, (x - a) / (b - a)));
        return t * t * (3 - 2 * t);
    }

    /// Lit from above on the side the face turns to: (how lit, how near the glint).
    public static (double Light, double Hot) Lighting(MatrixDesign design, Box box, double x, double y)
    {
        double u = (x - box.Cx) / Math.Max(box.Hw, 1), v = (y - box.Cy) / Math.Max(box.Hh, 1), f = design.Facing;
        var shadow = 0.6 * v - 0.38 * f * u + 0.38 * (u * u + v * v);
        return (1 - Smooth(0.25, 1.25, shadow), 1 - Smooth(0.0, 0.62, Math.Sqrt((u - 0.32 * f) * (u - 0.32 * f) + (v + 0.5) * (v + 0.5))));
    }

    public sealed class Face
    {
        public HashSet<Cell> Holes = [], Whites = [], Pupils = [], Blush = [];
        public List<HashSet<Cell>> Parts = [];
        public Dictionary<Cell, MatrixDotKind> Kinds
        {
            get
            {
                var kinds = new Dictionary<Cell, MatrixDotKind>();
                foreach (var c in Blush) kinds[c] = MatrixDotKind.Blush;
                foreach (var c in Holes) kinds[c] = MatrixDotKind.Hole;
                foreach (var c in Whites) kinds[c] = MatrixDotKind.White;
                foreach (var c in Pupils) kinds[c] = MatrixDotKind.Pupil;
                return kinds;
            }
        }
    }

    public static Face FaceCells(MatrixDesign design, Outline outline, MatrixPose pose)
    {
        var face = new Face();
        var look = design.Eyes;
        var ey = outline.EyeRow + pose.Lift;
        int[] eyes = [outline.Left + pose.Gaze, outline.Right + pose.Gaze];
        for (var index = 0; index < 2; index++)
        {
            var x = eyes[index];
            var outward = TwoWide(look) && index == 0 ? -1 : 0;
            var cells = EyeShape(look, pose.Lids).Select(d => new Cell(x + d.Item1 + outward, ey + d.Item2)).ToList();
            var part = cells.ToHashSet();
            if (look == MatrixEyes.Googly && pose.Lids == 0)
            {
                var pupil = new Cell(x + Math.Max(-1, Math.Min(1, pose.Gaze)), ey + (pose.Lift < 0 ? 0 : 1));
                cells.RemoveAll(c => c == pupil);
                face.Pupils.Add(pupil);
                part.Add(pupil);
            }
            if (look == MatrixEyes.Googly) face.Whites.UnionWith(cells); else face.Holes.UnionWith(cells);
            face.Parts.Add(part);
        }
        int my = ey + 3, mx = (eyes[0] + eyes[1]) / 2;
        (int, int)[] mouth = design.Mouth switch
        {
            MatrixMouth.Smile => [(-2, 0), (-1, 1), (0, 1), (1, 1), (2, 0)],
            MatrixMouth.Open => [(0, 0), (0, 1)],
            MatrixMouth.Cat => [(-2, 0), (-1, 1), (0, 0), (1, 1), (2, 0)],
            MatrixMouth.Line => [(-1, 0), (0, 0), (1, 0)],
            _ => [],
        };
        foreach (var (dx, dy) in mouth) face.Holes.Add(new Cell(mx + dx, my + dy));
        face.Parts.Add(mouth.Select(m => new Cell(mx + m.Item1, my + m.Item2)).ToHashSet());
        if (design.Blush)
            foreach (var x in new[] { eyes[0] - 1, eyes[1] + 1 })
            {
                face.Blush.Add(new Cell(x, ey + 2));
                face.Parts.Add([new Cell(x, ey + 2)]);
            }
        face.Parts = [.. face.Parts.Select(p => p.Where(outline.Contains).ToHashSet()).Where(p => p.Count > 0)];
        face.Holes = face.Holes.Where(outline.Contains).ToHashSet();
        face.Whites = face.Whites.Where(outline.Contains).ToHashSet();
        face.Pupils = face.Pupils.Where(outline.Contains).ToHashSet();
        face.Blush = face.Blush.Where(outline.Contains).ToHashSet();
        face.Holes.ExceptWith(face.Pupils);
        face.Whites.ExceptWith(face.Pupils);
        face.Blush.ExceptWith(face.Holes.Union(face.Whites));
        return face;
    }

    public static bool TwoWide(MatrixEyes e) => e is MatrixEyes.Dots or MatrixEyes.Ovals;

    /// One eye's dark cells about its centre, with the lids `lids` steps down.
    public static (int, int)[] EyeShape(MatrixEyes eyes, int lids)
    {
        (int, int)[] open = eyes switch
        {
            MatrixEyes.Slits => [(0, -1), (0, 0), (0, 1)],
            MatrixEyes.Dots => [(0, 0), (1, 0), (0, 1), (1, 1)],
            MatrixEyes.Ovals => [(0, -1), (1, -1), (0, 0), (1, 0), (0, 1), (1, 1)],
            MatrixEyes.Googly => [(-1, -1), (0, -1), (1, -1), (-1, 0), (0, 0), (1, 0), (-1, 1), (0, 1), (1, 1)],
            MatrixEyes.Happy => [(-1, 1), (0, 0), (1, 1)],
            MatrixEyes.Sleepy => [(-1, 1), (0, 1), (1, 1)],
            MatrixEyes.Stars => [(0, -1), (-1, 0), (0, 0), (1, 0), (0, 1)],
            MatrixEyes.Hearts => [(-1, -1), (1, -1), (-1, 0), (0, 0), (1, 0), (0, 1)],
            _ => [(-1, -1), (1, -1), (0, 0), (-1, 1), (1, 1)],
        };
        if (lids <= 0) return open;
        int bottom = open.Max(p => p.Item2), top = open.Min(p => p.Item2);
        if (eyes is MatrixEyes.Happy or MatrixEyes.Sleepy) return lids >= 2 ? [.. open.Where(p => p.Item2 == bottom)] : open;
        if (lids >= 2)
        {
            var line = bottom - (bottom - top) / 2;
            return [.. open.Select(p => p.Item1).Distinct().Order().Select(x => (x, line))];
        }
        return [.. open.Where(p => p.Item2 > top)];
    }
}

/// Björn Ottosson's OKLab: colours mixed in it stay vivid in between.
public readonly record struct OkLab(double L, double A, double B)
{
    public static OkLab FromRgb(HeadRgb rgb)
    {
        static double Linear(double c) => c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
        double r = Linear(rgb.R / 255.0), g = Linear(rgb.G / 255.0), bl = Linear(rgb.B / 255.0);
        var l_ = Math.Cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl);
        var m_ = Math.Cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl);
        var s_ = Math.Cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl);
        return new OkLab(0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_);
    }

    public OkLab Mixed(OkLab o, double t) => new(L + (o.L - L) * t, A + (o.A - A) * t, B + (o.B - B) * t);

    /// sRGB 0…1, clipped to the gamut.
    public (double R, double G, double B) Rgb
    {
        get
        {
            var l_ = L + 0.3963377774 * A + 0.2158037573 * B;
            var m_ = L - 0.1055613458 * A - 0.0638541728 * B;
            var s_ = L - 0.0894841775 * A - 1.2914855480 * B;
            double l3 = l_ * l_ * l_, m3 = m_ * m_ * m_, s3 = s_ * s_ * s_;
            static double Gamma(double c) => Math.Max(0, Math.Min(1, c <= 0.0031308 ? 12.92 * c : 1.055 * Math.Pow(c, 1 / 2.4) - 0.055));
            return (Gamma(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
                Gamma(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
                Gamma(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3));
        }
    }

    public HeadRgb ToRgb()
    {
        var (r, g, b) = Rgb;
        static uint C(double v) => (uint)Math.Round(v * 255, MidpointRounding.AwayFromZero);
        return new HeadRgb(C(r) << 16 | C(g) << 8 | C(b));
    }
}

/// The LED colours of one head on one page.
public sealed record MatrixPalette(OkLab Lit, OkLab Hot, OkLab Unlit, OkLab Shade, OkLab Blush, OkLab Pupil, OkLab? Hole)
{
    public static MatrixPalette Make(MatrixDesign design, bool dark)
    {
        if (design.Mono) return Mono(dark);
        var b = OkLab.FromRgb(new HeadRgb(design.Color));
        var lit = b with { L = dark ? Math.Min(Math.Max(b.L, 0.68), 0.80) : Math.Min(Math.Max(b.L, 0.55), 0.64) };
        var chroma = Math.Sqrt(lit.A * lit.A + lit.B * lit.B);
        if (chroma > 0.02)
        {
            var want = Math.Max(chroma, 0.11);
            lit = lit with { A = lit.A * want / chroma, B = lit.B * want / chroma };
        }
        var hot = new OkLab(Math.Min(0.97, lit.L + (dark ? 0.15 : 0.1)), lit.A * 0.62, lit.B * 0.62);
        var unlit = new OkLab(dark ? 0.56 : 0.72, lit.A * 0.14, lit.B * 0.14);
        var shade = new OkLab(dark ? 0.44 : 0.78, lit.A * 0.06, lit.B * 0.06);
        var ink = new OkLab(0.24, lit.A * 0.18, lit.B * 0.18);
        return new MatrixPalette(lit, hot, unlit, shade, new OkLab(dark ? 0.76 : 0.7, 0.15, 0.02),
            dark ? new OkLab(0.99, 0, 0) : new OkLab(0.22, lit.A * 0.15, lit.B * 0.15), dark ? null : ink);
    }

    /// Ink: white LEDs on a dark page, black ones on a light page, its dark LEDs gaps on both.
    public static MatrixPalette Mono(bool dark) => new(new OkLab(dark ? 0.94 : 0.25, 0, 0), new OkLab(dark ? 1 : 0.36, 0, 0),
        new OkLab(dark ? 0.5 : 0.8, 0, 0), new OkLab(dark ? 0.38 : 0.88, 0, 0), new OkLab(dark ? 0.76 : 0.7, 0.15, 0.02),
        new OkLab(dark ? 0.99 : 0.2, 0, 0), null);
}

/// A dot-matrix head as SVG in a 1024 square (MatrixHeadRenderer.draw), for the renderer to rasterise.
public static class MatrixHeadSvg
{
    /// How much of a cell a dot fills, by how far apart the dots are (points).
    public static double Fill(double pitch) => 0.74 + 0.16 * MatrixHead.Smooth(0, 1, (44 - pitch * 15) / 22);

    static string Hex(OkLab c) => c.ToRgb().ToString();
    static string F(double v) => Math.Round(v, 2).ToString(CultureInfo.InvariantCulture);

    /// `pointSide`: the head's size in points (how plump the dots are). `dark`: the page.
    public static string Svg(Head head, double pointSide, bool dark, MatrixPose? pose = null)
    {
        var design = MatrixDesign.Of(head);
        var at = pose ?? MatrixPose.Look;
        var palette = MatrixPalette.Make(design, dark);
        const double side = 1024;
        var pitch = side / MatrixHead.Grid;
        var dots = MatrixHead.Dots(design, at);
        var full = Fill(pointSide / MatrixHead.Grid);
        OkLab? Colour(MatrixDot dot) => dot.Kind switch
        {
            MatrixDotKind.Body => palette.Shade.Mixed(palette.Unlit, MatrixHead.Smooth(0, 0.5, dot.Light))
                .Mixed(palette.Lit.Mixed(palette.Hot, dot.Hot * 0.8), MatrixHead.Smooth(0.1, 1, dot.Light)),
            MatrixDotKind.Hole => palette.Hole,
            MatrixDotKind.White => null,
            MatrixDotKind.Blush => palette.Blush,
            _ => palette.Pupil,
        };
        double Radius(MatrixDot d) => pitch * (d.Kind == MatrixDotKind.Body ? full * (0.8 + 0.2 * MatrixHead.Smooth(0, 0.6, d.Light)) : full) / 2;
        P Centre(MatrixDot d) => new((d.Col + 0.5) * pitch, (d.Row + 0.5) * pitch);
        var o = new StringBuilder("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\">");
        if (dark)
        {
            // The light the face gives off, pooled behind it and gone before the picture's edge.
            var box = MatrixHead.BoxOf(MatrixHead.Leds(design));
            var middle = new P((box.Cx + design.Facing * box.Hw * 0.1) * pitch, (box.Cy - box.Hh * 0.12) * pitch);
            var reach = Math.Min(Math.Min(middle.X, side - middle.X), Math.Min(middle.Y, side - middle.Y));
            var glow = design.Mono ? 0.12 : 0.2;
            var lit = Hex(palette.Lit);
            o.Append($"<defs><radialGradient id=\"g\" gradientUnits=\"userSpaceOnUse\" cx=\"{F(middle.X)}\" cy=\"{F(middle.Y)}\" r=\"{F(reach)}\">"
                + $"<stop offset=\"0\" stop-color=\"{lit}\" stop-opacity=\"{F(glow)}\"/><stop offset=\".55\" stop-color=\"{lit}\" stop-opacity=\"{F(glow * 0.45)}\"/>"
                + $"<stop offset=\"1\" stop-color=\"{lit}\" stop-opacity=\"0\"/></radialGradient></defs><rect width=\"1024\" height=\"1024\" fill=\"url(#g)\"/>");
            foreach (var dot in dots)
            {
                if (dot.Kind is MatrixDotKind.Hole or MatrixDotKind.White || (dot.Kind == MatrixDotKind.Body && dot.Light <= 0.4)) continue;
                if (Colour(dot) is not { } c) continue;
                var p = Centre(dot);
                var r = Math.Min(Math.Min(pitch * 0.62, Math.Min(p.X, p.Y)), Math.Min(side - p.X, side - p.Y));
                o.Append($"<circle cx=\"{F(p.X)}\" cy=\"{F(p.Y)}\" r=\"{F(r)}\" fill=\"{Hex(c)}\" fill-opacity=\"{F(dot.Kind == MatrixDotKind.Body ? 0.16 * dot.Light : 0.22)}\"/>");
            }
        }
        foreach (var dot in dots)
        {
            if (Colour(dot) is not { } c) continue;
            var p = Centre(dot);
            o.Append($"<circle cx=\"{F(p.X)}\" cy=\"{F(p.Y)}\" r=\"{F(Radius(dot))}\" fill=\"{Hex(c)}\"/>");
        }
        return o + "</svg>";
    }
}
