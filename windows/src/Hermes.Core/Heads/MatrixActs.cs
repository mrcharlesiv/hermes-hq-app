using System.Globalization;
using System.Text;

namespace Hermes.Core.Heads;

// [moods] How a dot-matrix face acts out what its bot is doing (App/Heads/MatrixActs.swift + HeadView.swift
// matrix elastic squash/lean & 3D specular glint): discrete LED poses, 60fps sampled frames with elastic follow-through
// and specular glint coordinates, plus deterministic SplitMix64 masks for rain, sparkles, and typing lines.

public enum MatrixActEffect
{
    /// Thinking: a comet of light running round the outline.
    Orbit,
    /// Searching: a radar sweep from the middle.
    Radar,
    /// Reading: a line of light going down the face.
    Scan,
    /// Running: code falling down the LEDs, in two speeds.
    Rain,
    /// Writing: LEDs lighting one by one along two lines under the eyes, then clearing.
    Typing,
    /// Browsing: a pointer moving about, a ripple where it clicks.
    Pointer,
    /// Messaging: rings going out to the side the face turns to.
    Waves,
    /// Making: LEDs twinkling here and there.
    Sparkle,
    /// Replying: the head glowing softly with each nod.
    Pulse,
    /// Asking: the face flashing as it lands from each hop.
    Flash,
    /// Done: rings and sparkles out from the middle.
    Burst,
    /// Failed: the face flickering.
    Flicker,
}

/// Extended dot-matrix pose adding `Wide` (perked wide slits) and `Glitch` (row-band glitch shift 1…4 for Failed)
/// while bridging cleanly to `MatrixPose` in `MatrixHead.cs`.
public readonly record struct MatrixActPose(
    int Gaze = 0,
    int Lift = 0,
    int Lids = 0,
    bool Wide = false,
    int Glitch = 0)
{
    public static readonly MatrixActPose Rest = new();
    public static readonly MatrixActPose Look = new(Gaze: 1);
    public MatrixActPose Mirrored => this with { Gaze = -Gaze };
    public MatrixPose ToMatrixPose() => new(Gaze, Lift, Lids);
}

/// Specular 3D glint gradient endpoints rolling across the LED dome as the head turns and tips (0…1 UV space).
public readonly record struct MatrixGlintFrame(double StartX, double StartY, double EndX, double EndY)
{
    public static MatrixGlintFrame For(FaceBody body, int facing = MatrixHead.ShownFacing)
    {
        var cx = Math.Clamp(0.5 + 0.16 * facing - body.Turn / 110.0, 0.12, 0.88);
        var cy = Math.Clamp(0.32 - body.Tip / 110.0, 0.10, 0.78);
        return new MatrixGlintFrame(cx, cy, cx + 0.56, cy + 0.56);
    }
}

/// One 60fps dot-matrix animation frame combining the discrete LED pose, C³ body pose, subtle 0.38/0.36 elastic
/// squash & lean follow-through, and rolling 3D specular glint.
public readonly record struct MatrixActFrame(
    double At,
    MatrixActPose Pose,
    FaceBody Body,
    FaceJelly Elastic,
    MatrixGlintFrame Glint);

/// Deterministic SplitMix64 PRNG matching `MatrixActMasks.Dice` so each head's shuffled routine order, rain,
/// and sparkles stay stable across platforms and runs.
public struct MatrixActDice
{
    private ulong _state;

    public MatrixActDice(int seed)
    {
        unchecked
        {
            _state = (ulong)seed * 0x9E3779B97F4A7C15UL + 0x2545F4914F6CDD1DUL;
        }
    }

    public ulong Next()
    {
        unchecked
        {
            _state += 0x9E3779B97F4A7C15UL;
            var z = _state;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
            return z ^ (z >> 31);
        }
    }

    public int NextInt(int minInclusive, int maxExclusive)
    {
        var count = Math.Max(1, maxExclusive - minInclusive);
        return minInclusive + (int)(Next() % (ulong)count);
    }
}

public sealed record MatrixAct(
    BotMood Mood,
    MatrixDesign Design,
    IReadOnlyList<FaceClip> Clips,
    MatrixActEffect? Effect,
    MatrixActPose Still)
{
    /// Played once (`Done`, `Failed`), not over and over.
    public bool Once => Mood.IsOnce();

    /// Whether the flare is the outline's edge only (a comet running round it).
    public bool RimOnly => Effect == MatrixActEffect.Orbit;

    public static IReadOnlyList<P> Stops => FaceRoutines.Stops;
    public const double StopLength = FaceRoutines.StopLength;
    public const double LineLength = FaceRoutines.LineLength;
    public const double TypingPause = FaceRoutines.TypingPause;

    /// Failed: the panel glitching as it starts (each band of rows slid, 0.07 s each).
    public static readonly int[] Glitches = [1, 2, 0, 3, 0, 4, 1];
    public const double GlitchLength = 0.07;

    /// Subtle elastic scaling on a dot-matrix head's mover (`HeadView.swift` `playMatrixElastic`).
    public const double ElasticSquashScale = 0.38;
    public const double ElasticLeanScale = 0.36;

    public static MatrixAct Make(BotMood mood, MatrixDesign design)
    {
        var effect = mood switch
        {
            BotMood.Thinking => MatrixActEffect.Orbit,
            BotMood.Reading => MatrixActEffect.Scan,
            BotMood.Searching => MatrixActEffect.Radar,
            BotMood.Running => MatrixActEffect.Rain,
            BotMood.Writing => MatrixActEffect.Typing,
            BotMood.Browsing => MatrixActEffect.Pointer,
            BotMood.Messaging => MatrixActEffect.Waves,
            BotMood.Making => MatrixActEffect.Sparkle,
            BotMood.Replying => MatrixActEffect.Pulse,
            BotMood.Asking => MatrixActEffect.Flash,
            BotMood.Done => MatrixActEffect.Burst,
            BotMood.Failed => MatrixActEffect.Flicker,
            _ => MatrixActEffect.Orbit,
        };
        var still = Pose(FaceBody.Rest, FaceRoutines.Still(mood, design.Facing), design);
        return new MatrixAct(mood, design, FaceRoutines.Clips(mood, design.Facing), effect, still);
    }

    /// The face at a moment of a routine, in whole LEDs: up to 2 LEDs sideways, 2 LEDs up, or 1 LED down;
    /// lids narrow, shut, or perk wide open.
    public static MatrixActPose Pose(FaceBody body, FaceEyes eyes, MatrixDesign design)
    {
        _ = design;
        var x = eyes.X + body.Turn / 22.0;
        var y = eyes.Y + body.Tip / 28.0;
        var gaze = x >= 1.15 ? 2 : x >= 0.32 ? 1 : x <= -1.15 ? -2 : x <= -0.32 ? -1 : 0;
        var lift = y <= -1.15 ? -2 : y <= -0.32 ? -1 : y >= 0.38 ? 1 : 0;
        var lids = eyes.Lids >= 0.72 ? 2 : eyes.Lids >= 0.24 ? 1 : 0;
        var wide = lids == 0 && lift >= -1 && eyes.Wide >= 0.45;
        return new MatrixActPose(gaze, lift, lids, wide);
    }

    /// Discrete pose changes `loop` goes through (with Failed's initial glitch sequence).
    public List<(double At, MatrixActPose Pose)> Frames(FaceLoop loop)
    {
        var frames = new List<(double At, MatrixActPose Pose)>();
        if (Mood == BotMood.Failed)
        {
            for (var i = 0; i < Glitches.Length; i++)
                frames.Add((i * GlitchLength, new MatrixActPose(Lids: 2, Glitch: Glitches[i])));
        }
        var after = frames.Count == 0 ? -1.0 : Glitches.Length * GlitchLength;
        foreach (var sample in loop.Samples())
        {
            if (sample.At < after || sample.At >= loop.Period - 1e-9) continue;
            var pose = Pose(sample.Body, sample.Eyes, Design);
            if (frames.Count == 0 || frames[^1].Pose != pose)
                frames.Add((sample.At, pose));
        }
        return frames;
    }

    /// 60fps animation frames combining discrete LED pose, C³ soft body motion, 0.38/0.36 elastic squash/lean,
    /// and rolling 3D specular glint (with exact periodic closure for looping moods).
    public List<MatrixActFrame> SampleFrames(FaceLoop loop, double rate = 60)
    {
        var once = Once;
        var samples = loop.SoftSamples(once, rate);
        if (samples.Count == 0) return [];
        var wobble = FaceJelly.Follow(samples, loop.Period, once);
        var glitchEnd = Mood == BotMood.Failed ? Glitches.Length * GlitchLength : -1.0;

        var frames = new List<MatrixActFrame>(samples.Count);
        for (var i = 0; i < samples.Count; i++)
        {
            var s = samples[i];
            MatrixActPose pose;
            if (Mood == BotMood.Failed && s.At < glitchEnd)
            {
                var idx = Math.Clamp((int)(s.At / GlitchLength), 0, Glitches.Length - 1);
                pose = new MatrixActPose(Lids: 2, Glitch: Glitches[idx]);
            }
            else
            {
                pose = Pose(s.Body, s.Eyes, Design);
            }
            var j = wobble[i];
            var elastic = new FaceJelly(j.Squash * ElasticSquashScale, j.Lean * ElasticLeanScale);
            var glint = MatrixGlintFrame.For(s.Body, Design.Facing);
            frames.Add(new MatrixActFrame(s.At, pose, s.Body, elastic, glint));
        }
        if (!once && frames.Count > 1)
        {
            var first = frames[0];
            frames[^1] = frames[^1] with { Pose = first.Pose, Elastic = first.Elastic, Glint = first.Glint };
        }
        return frames;
    }

    /// Every distinct pose this act visits (including `Still` and `Failed`'s glitches).
    public List<MatrixActPose> Poses
    {
        get
        {
            var seen = new HashSet<MatrixActPose>();
            var list = new List<MatrixActPose>();
            void Add(MatrixActPose p) { if (seen.Add(p)) list.Add(p); }
            if (Mood == BotMood.Failed)
                foreach (var g in Glitches) Add(new MatrixActPose(Lids: 2, Glitch: g));
            foreach (var clip in Clips)
                foreach (var t in clip.Times(30))
                    Add(Pose(clip.BodyAt(t), clip.EyesAt(t), Design));
            Add(Still);
            return list;
        }
    }

    /// The face LEDs in any of the act's poses: a light flare never covers them.
    public HashSet<Cell> FaceCells(MatrixDesign design)
    {
        var cells = new HashSet<Cell>();
        foreach (var pose in Poses)
            foreach (var cell in MatrixActSvg.FaceLeds(design, pose).Keys)
                cells.Add(cell);
        foreach (var cell in MatrixHead.FaceLeds(design, MatrixPose.Rest).Keys)
            cells.Add(cell);
        return cells;
    }

    /// The two lines a Writing face types along, in the head's LEDs: `(Row, First, Last)`.
    public static List<(int Row, int First, int Last)> TypingLines(MatrixDesign design)
    {
        var body = MatrixHead.Leds(design);
        var face = MatrixHead.FaceLeds(design, MatrixPose.Rest);
        var eyeRows = face.Where(kv => kv.Value != MatrixDotKind.Blush).Select(kv => kv.Key.Row).ToList();
        var top = eyeRows.Count > 0 ? eyeRows.Min() : MatrixHead.Grid / 2;
        var eyeBottom = face.Keys.Where(c => c.Row <= top + 3).Select(c => c.Row).DefaultIfEmpty(top).Max();
        var lines = new List<(int, int, int)>(2);
        var row = eyeBottom + 3;
        while (lines.Count < 2 && row < MatrixHead.Grid - 1)
        {
            int first = -1, last = -1;
            for (var col = 0; col < MatrixHead.Grid; col++)
            {
                if (!body[row][col]) continue;
                if (first < 0) first = col;
                last = col;
            }
            if (first >= 0 && last - first - 2 >= 4)
            {
                lines.Add((row, first + 2, last - 2));
                row += 2;
            }
            else
            {
                row += 1;
            }
        }
        return lines;
    }

    /// Deterministic falling rain streaks `(Col, HeadRow, Length)` for `MatrixActEffect.Rain`.
    public static List<(int Col, int Head, int Length)> RainStreaks(int seed, int streaks)
    {
        var grid = MatrixHead.Grid;
        var dice = new MatrixActDice(seed);
        var columns = Enumerable.Range(0, grid).ToArray();
        for (var i = columns.Length - 1; i >= 0; i--)
        {
            var j = dice.NextInt(0, i + 1);
            (columns[i], columns[j]) = (columns[j], columns[i]);
        }
        var result = new List<(int, int, int)>(streaks);
        for (var n = 0; n < streaks; n++)
        {
            var col = columns[n % grid];
            var head = dice.NextInt(0, grid);
            var len = dice.NextInt(3, 8);
            result.Add((col, head, len));
        }
        return result;
    }

    /// Deterministic twinkle cells on the head body (excluding face LEDs) for `Sparkle` / `Burst`.
    public static List<Cell> SparkleCells(MatrixDesign design, HashSet<Cell> skip, int seed, int count)
    {
        var grid = MatrixHead.Grid;
        var body = MatrixHead.Leds(design);
        var cells = new List<Cell>();
        for (var row = 0; row < grid; row++)
            for (var col = 0; col < grid; col++)
                if (body[row][col] && !skip.Contains(new Cell(col, row)))
                    cells.Add(new Cell(col, row));
        if (cells.Count == 0) return [];
        var dice = new MatrixActDice(seed);
        var chosen = new List<Cell>(count);
        for (var i = 0; i < count; i++)
            chosen.Add(cells[dice.NextInt(0, cells.Count)]);
        return chosen;
    }
}

/// Renders a dot-matrix `MatrixActPose` (including `Wide` eyes and `Glitch` row shifts) to 1024×1024 SVG.
public static class MatrixActSvg
{
    public static Dictionary<Cell, MatrixDotKind> FaceLeds(MatrixDesign design, MatrixActPose pose)
    {
        var leds = MatrixHead.FaceLeds(design, pose.ToMatrixPose());
        if (pose.Wide && pose.Lids == 0 && leds.Count > 0)
        {
            var body = MatrixHead.Leds(design);
            var minRow = leds.Keys.Min(c => c.Row);
            var maxRow = leds.Keys.Max(c => c.Row);
            var extra = new List<Cell>();
            foreach (var (cell, kind) in leds)
            {
                if (kind != MatrixDotKind.Hole) continue;
                if (cell.Row == minRow && cell.Row > 0 && body[cell.Row - 1][cell.Col])
                    extra.Add(new Cell(cell.Col, cell.Row - 1));
                if (cell.Row == maxRow && cell.Row + 1 < MatrixHead.Grid && body[cell.Row + 1][cell.Col])
                    extra.Add(new Cell(cell.Col, cell.Row + 1));
            }
            foreach (var c in extra) leds.TryAdd(c, MatrixDotKind.Hole);
        }
        return leds;
    }

    private static int GlitchShift(int row, int glitch) => glitch switch
    {
        1 => row is >= 4 and <= 7 ? 2 : row is >= 12 and <= 15 ? -1 : 0,
        2 => row is >= 6 and <= 9 ? -2 : row is >= 13 and <= 16 ? 2 : 0,
        3 => row is >= 3 and <= 6 ? -1 : row is >= 9 and <= 12 ? 2 : 0,
        4 => row is >= 5 and <= 8 ? 1 : row is >= 11 and <= 14 ? -2 : 0,
        _ => 0,
    };

    private static string Hex(OkLab c) => c.ToRgb().ToString();
    private static string F(double v) => Math.Round(v, 2).ToString(CultureInfo.InvariantCulture);

    public static string Svg(Head head, double pointSide, bool dark, MatrixActPose pose)
    {
        if (!pose.Wide && pose.Glitch == 0)
            return MatrixHeadSvg.Svg(head, pointSide, dark, pose.ToMatrixPose());

        var design = MatrixDesign.Of(head);
        var body = MatrixHead.Leds(design);
        var box = MatrixHead.BoxOf(body);
        var face = FaceLeds(design, pose);
        var palette = MatrixPalette.Make(design, dark);
        const double side = 1024;
        var pitch = side / MatrixHead.Grid;
        var full = MatrixHeadSvg.Fill(pointSide / MatrixHead.Grid);

        var dots = new List<MatrixDot>();
        for (var row = 0; row < MatrixHead.Grid; row++)
        {
            var shift = GlitchShift(row, pose.Glitch);
            for (var col = 0; col < MatrixHead.Grid; col++)
            {
                if (!body[row][col]) continue;
                var drawCol = Math.Clamp(col + shift, 0, MatrixHead.Grid - 1);
                var (light, hot) = MatrixHead.Lighting(design, box, col + 0.5, row + 0.5);
                var kind = face.TryGetValue(new Cell(col, row), out var k) ? k : MatrixDotKind.Body;
                dots.Add(new MatrixDot(drawCol, row, kind, light, hot));
            }
        }

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
