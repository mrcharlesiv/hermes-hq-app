using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core;
using Hermes.Core.Heads;
using Hermes.Core.Model;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// Robot heads (spec 02 §10, spec 1x-settings §7): the Mac's own vectors (Tests/HeadModelTests.swift,
/// ThemeHeadTests.swift, MatrixHeadTests.swift), the recorded theme markup, the fixture roster's heads, and the
/// compare-and-swap save.
public class HeadsTests
{
    static JsonNode J(string json) => JsonNode.Parse(json)!;

    // MARK: default heads (§10.3)

    [Theory]
    [InlineData("default", 2470140894u, HeadColor.Wine, HeadForm.Round, 322657247)]
    [InlineData("ivy", 2466054493u, HeadColor.Teal, HeadForm.Square, 318570846)]
    [InlineData("hermes", 3348504771u, HeadColor.Butter, HeadForm.Round, 1201021124)]
    [InlineData("inbox", 3797079355u, HeadColor.Pink, HeadForm.Round, 1649595708)]
    [InlineData("otto", 501755363u, HeadColor.Grape, HeadForm.Square, 501755363)]
    public void DefaultShapeHead(string profile, uint hash, HeadColor color, HeadForm form, int seed)
    {
        Assert.Equal(hash, Head.NameHash(profile));
        var head = Head.DefaultShapeHead(profile);
        Assert.Equal(HeadTheme.Shape, head.Theme);
        Assert.Equal(color, head.Color);
        Assert.Equal(form, head.Form);
        Assert.Equal(seed, head.Seed);
        Assert.True(head is { Look: HeadLook.Slits, Specs: HeadSpecs.None, Hat: HeadHat.None, Mouth: HeadMouth.None, Tile: HeadTile.None, Blush: false });
    }

    [Fact]
    public void DefaultHeadKeyIsTrimmedAndLowercased()
    {
        Assert.Equal(Head.DefaultShapeHead("ivy"), Head.DefaultShapeHead("  Ivy "));
        Assert.Equal(Head.DefaultShapeHead("default"), Head.DefaultShapeHead("   "));
        // §10.4.10: the owner's heads without a saved record.
        Assert.True(Head.DefaultShapeHead("finance") is { Color: HeadColor.Butter, Form: HeadForm.Square });
        Assert.True(Head.DefaultShapeHead("maple-revenue-operator") is { Color: HeadColor.Lime, Form: HeadForm.Hex });
        Assert.True(Head.DefaultShapeHead("bike-shop") is { Color: HeadColor.Lime, Form: HeadForm.Pill });
        // No saved head: the name's default.
        Assert.Equal(Head.DefaultShapeHead("ivy"), Head.Resolve(null, "ivy"));
    }

    [Theory]
    [InlineData("default", HeadColor.Teal, MatrixSilhouette.Arch, HeadLook.Happy, HeadMouth.None, 322657247, 1)]
    [InlineData("ivy", HeadColor.Peach, MatrixSilhouette.Hex, HeadLook.Slits, HeadMouth.None, 318570846, -1)]
    [InlineData("finance", HeadColor.Lilac, MatrixSilhouette.Pebble, HeadLook.Slits, HeadMouth.None, 355747310, 1)]
    [InlineData("hermes", HeadColor.Lime, MatrixSilhouette.Octagon, HeadLook.Dots, HeadMouth.Smile, 1201021124, 1)]
    [InlineData("codex", HeadColor.Red, MatrixSilhouette.Wide, HeadLook.Slits, HeadMouth.None, 1422778469, -1)]
    public void DefaultMatrixHead(string profile, HeadColor color, MatrixSilhouette silhouette, HeadLook look, HeadMouth mouth, int seed, int facing)
    {
        var head = Head.DefaultMatrixHead(profile);
        Assert.Equal(HeadTheme.Matrix, head.Theme);
        Assert.Equal((color, silhouette, look, mouth, seed), (head.Color, head.Silhouette, head.Look, head.Mouth, head.Seed));
        Assert.Equal(facing, MatrixHead.Facing(head.Seed));
        Assert.Equal(1, MatrixDesign.Of(head).Facing);
    }

    // MARK: parse (§10.2)

    [Fact]
    public void ParseRejectsNonHeads()
    {
        Assert.Null(Head.Parse(null));
        Assert.Null(Head.Parse(J("\"shape\"")));
        Assert.Null(Head.Parse(J("[]")));
        Assert.Null(Head.Parse(J("""{"theme":"nope","form":"round"}""")));
    }

    [Fact]
    public void ParseFallsBackFieldByField()
    {
        var head = Head.Parse(J("""{"theme":"shape","v":6,"color":"chartreuse","form":"zigzag","seed":2.5}"""))!;
        Assert.True(head is { Color: HeadColor.Mint, Form: HeadForm.Round, Seed: 1, Tile: HeadTile.Dark });
        Assert.Equal(2147483647, Head.Parse(J("""{"theme":"shape","v":6,"seed":1e12}"""))!.Seed);
        Assert.Equal(HeadTheme.Robot, Head.Parse(J("""{"shape":"dome","face":"visor"}"""))!.Theme);
        var old = Head.Resolve(J("""{"shape":"dome"}"""), "ivy");
        Assert.Equal(HeadTheme.Robot, old.Theme);
        Assert.Equal("dome", old.Themed!.Shape);
    }

    [Fact]
    public void LegacyShapeFixUps()
    {
        var head = Head.Parse(J("""{"v":4,"theme":"shape","color":"ink","form":"round","look":"ovals","mouth":"open","blush":true,"tile":"color","seed":7}"""))!;
        Assert.True(head is { Mouth: HeadMouth.None, Blush: false, Tile: HeadTile.None, Look: HeadLook.Ovals, Color: HeadColor.Ink });
        var v5 = Head.Parse(J("""{"v":5,"theme":"shape","mouth":"smile","tile":"light"}"""))!;
        Assert.True(v5 is { Mouth: HeadMouth.Smile, Tile: HeadTile.None });
        Assert.Equal(HeadTile.Light, Head.Parse(J("""{"v":"6","theme":"shape","tile":"light"}"""))!.Tile);
    }

    [Fact]
    public void CharacterFallsBackToTheDefaultAndRobotsKeepTheirKey()
    {
        Assert.Equal(Head.DefaultHead("ivy"), Head.Resolve(J("""{"v":6,"theme":"persona","color":"pink"}"""), "ivy"));
        var robot = Head.Resolve(J("""{"v":6,"theme":"robot","shape":"cat","face":"happy","color":"lilac"}"""), "ivy");
        Assert.Equal("cat", robot.Themed!.Shape);
        Assert.StartsWith("robot|cat|happy|", robot.CacheKey);
    }

    /// Every head in the demo gateway's roster parses to the Shapes head it names.
    [Fact]
    public void FixtureRosterHeads()
    {
        var bots = Roster.Parse(Fixture.Load("demo-profiles-list.json"));
        Assert.NotEmpty(bots);
        foreach (var bot in bots)
        {
            Assert.NotNull(bot.HeadRaw);
            var head = HeadStore.HeadOf(bot);
            Assert.Equal(HeadTheme.Shape, head.Theme);
            Assert.Equal(HeadForm.Blob, head.Form);
            Assert.Equal(bot.HeadRaw!["color"]!.GetValue<string>(), HeadWire.Name(head.Color));
            Assert.Equal((int)bot.HeadRaw!["seed"]!.GetValue<double>(), head.Seed);
            Assert.True(HeadStore.State(bot).Saved);
        }
        var hermes = bots.First(b => b.Name == "default");
        Assert.True(Head.Resolve(hermes.HeadRaw, "default") is { Color: HeadColor.Peach, Seed: 3, Tile: HeadTile.None });
    }

    // MARK: geometry (§10.4.9)

    static Head Shape(HeadForm form, HeadColor color = HeadColor.Grass, int seed = 416723) =>
        new() { Theme = HeadTheme.Shape, Form = form, Color = color, Seed = seed, Tile = HeadTile.None };

    static HeadMark Slit(double x, double y, double w, double h, double rx, double a, double cx, double cy) =>
        new(new HeadPrimitive.Rect(x, y, w, h, rx), [new HeadTransformStep.Rotate(a, cx, cy)], HeadStyle.Filled(new HeadRgb(0xFFFFFF)));

    [Theory]
    [InlineData(HeadForm.Round, 1.64, -327.7, -327.7, new[] { 515, 359, 54, 114, 27, 542, 416.0 }, 635.0, 662.0)]
    [InlineData(HeadForm.Blob, 1.528, -257.8, -270.2, new[] { 515, 359, 54, 114, 27, 542, 416.0 }, 635, 662)]
    [InlineData(HeadForm.Square, 1.763, -390.9, -390.9, new[] { 515, 359, 54, 114, 27, 542, 416.0 }, 635, 662)]
    [InlineData(HeadForm.Pill, 1.519, -265.5, -265.5, new[] { 514.8, 376.3, 49.7, 104.9, 24.8, 539.6, 428.7 }, 625.2, 650)]
    [InlineData(HeadForm.Triangle, 2.001, -512.5, -546.4, new[] { 514.6, 480.8, 46.4, 98, 23.2, 537.8, 529.8 }, 617.8, 641)]
    [InlineData(HeadForm.Hex, 1.749, -383.7, -383.7, new[] { 515, 365, 54, 114, 27, 542, 422.0 }, 635, 662)]
    [InlineData(HeadForm.Cloud, 1.502, -244, -240.4, new[] { 508.8, 412.3, 49.7, 104.9, 24.8, 533.6, 464.7 }, 619.2, 644)]
    [InlineData(HeadForm.Drop, 1.547, -280.2, -243, new[] { 514.7, 487.1, 48.6, 102.6, 24.3, 539, 538.4 }, 622.7, 647)]
    [InlineData(HeadForm.Star, 1.692, -354.4, -347.1, new[] { 514.3, 438, 42.1, 88.9, 21.1, 535.4, 482.5 }, 607.9, 629)]
    [InlineData(HeadForm.Heart, 1.608, -311.2, -329.9, new[] { 502.7, 409.1, 48.6, 102.6, 24.3, 527, 460.4 }, 610.7, 635)]
    public void FormVectors(HeadForm form, double k, double tx, double ty, double[] eye, double rightX, double rightCx)
    {
        var layout = HeadGeometry.Layout(Shape(form), compact: true, darkPage: false);
        Assert.Equal(new HeadPlacement(k, tx, ty), layout.Placement);
        Assert.Equal(2, layout.Face.Count);
        Assert.Equal(Slit(eye[0], eye[1], eye[2], eye[3], eye[4], -20, eye[5], eye[6]), layout.Face[0]);
        Assert.Equal(Slit(rightX, eye[1], eye[2], eye[3], eye[4], -20, rightCx, eye[6]), layout.Face[1]);
    }

    [Fact]
    public void RoundOutlinePath() =>
        Assert.StartsWith("M512 212C528 212 543 213 559 216C574 218", HeadGeometry.Layout(Shape(HeadForm.Round), compact: true, darkPage: false).OutlinePath);

    [Fact]
    public void NonCompactSlitsAndStates()
    {
        var big = HeadGeometry.Layout(Shape(HeadForm.Round), compact: false, darkPage: false);
        Assert.Equal(Slit(519.5, 359, 45, 114, 22.5, -20, 542, 416), big.Face[0]);
        Assert.Equal(Slit(639.5, 359, 45, 114, 22.5, -20, 662, 416), big.Face[1]);
        var thinking = HeadGeometry.Layout(Shape(HeadForm.Round), HeadState.Thinking, true, false);
        Assert.Equal(Slit(425, 457, 54, 98, 27, 0, 452, 506), thinking.Face[0]);
        var done = HeadGeometry.Layout(Shape(HeadForm.Round), HeadState.Done, true, false);
        Assert.Equal(Slit(545, 419, 54, 114, 27, -24, 572, 476), done.Face[1]);
        var offline = HeadGeometry.Layout(Shape(HeadForm.Round), HeadState.Offline, true, false);
        Assert.Equal(Slit(425, 488, 54, 84, 27, 90, 452, 530), offline.Face[0]);
    }

    [Fact]
    public void Looks()
    {
        var head = Shape(HeadForm.Round) with { Look = HeadLook.Dots };
        var layout = HeadGeometry.Layout(head, compact: true, darkPage: false);
        Assert.Equal([new HeadPrimitive.Circle(542, 416, 39.6), new HeadPrimitive.Circle(662, 416, 39.6)], layout.Face.Select(m => m.Primitive).ToArray());
        head = head with { Look = HeadLook.Ovals };
        layout = HeadGeometry.Layout(head, compact: true, darkPage: false);
        Assert.Equal(new HeadPrimitive.Ellipse(542, 416, 39.6, 57), layout.Face[0].Primitive);
        Assert.Equal([new HeadTransformStep.Rotate(-10, 542, 416)], layout.Face[0].Transform);
        head = head with { Look = HeadLook.Googly };
        layout = HeadGeometry.Layout(head, compact: true, darkPage: false);
        Assert.Equal([new HeadTransformStep.Translate(530, 416), new HeadTransformStep.Scale(1)], layout.Face[0].Transform);
        Assert.Equal(10.8, layout.Face[0].Style.StrokeWidth, 9);
        Assert.Equal(new HeadPrimitive.Circle(18, -16.8, 30.6), layout.Face[1].Primitive);
        head = head with { Look = HeadLook.Stars };
        layout = HeadGeometry.Layout(head, compact: true, darkPage: false);
        Assert.Equal([new HeadTransformStep.Translate(542, 416), new HeadTransformStep.Scale(1.2), new HeadTransformStep.Rotate(-10, 0, 0)], layout.Face[0].Transform);
    }

    [Fact]
    public void GlassesMouthAndBlush()
    {
        var layout = HeadGeometry.Layout(Shape(HeadForm.Round) with { Specs = HeadSpecs.Shades }, compact: true, darkPage: false);
        Assert.Equal(3, layout.Face.Count);
        Assert.All(layout.Face, m => Assert.Equal([new HeadTransformStep.Translate(602, 416), new HeadTransformStep.Scale(1)], m.Transform));
        layout = HeadGeometry.Layout(Shape(HeadForm.Round) with { Mouth = HeadMouth.Smile }, compact: true, darkPage: false);
        Assert.Equal([new HeadTransformStep.Translate(602, 512), new HeadTransformStep.Scale(1)], layout.Under[0].Transform);
        Assert.Equal(23.4, layout.Under[0].Style.StrokeWidth);
        layout = HeadGeometry.Layout(Shape(HeadForm.Round) with { Blush = true }, compact: true, darkPage: false);
        Assert.Equal([new HeadPrimitive.Ellipse(-102, 66, 30, 18), new HeadPrimitive.Ellipse(102, 66, 30, 18)], layout.Under.Select(m => m.Primitive).ToArray());
    }

    [Theory]
    [InlineData(HeadHat.Crown, 1.235, -120.1, 1.5)]
    [InlineData(HeadHat.Halo, 1.305, -156.2, -55.7)]
    [InlineData(HeadHat.Sprout, 1.265, -135.6, -23)]
    [InlineData(HeadHat.Party, 1.085, -43.5, 123.1)]
    [InlineData(HeadHat.Bow, 1.482, -246.7, -199.3)]
    [InlineData(HeadHat.Beanie, 1.337, -172.5, -81.6)]
    public void HatPlacement(HeadHat hat, double k, double tx, double ty)
    {
        var head = Shape(HeadForm.Round) with { Hat = hat };
        var points = HeadGeometry.Form(HeadForm.Round, head.Seed).Outline;
        Assert.Equal(new HeadPlacement(k, tx, ty), HeadGeometry.Placement(head, points, withHat: true));
        Assert.Equal(new HeadPlacement(1.64, -327.7, -327.7), HeadGeometry.Layout(head, compact: true, darkPage: false).Placement);
        Assert.Equal(new HeadPlacement(0.8, 102.4, 160), HeadGeometry.Placement(head with { Tile = HeadTile.Dark }, points, withHat: true));
    }

    [Fact]
    public void FillsAndEyes()
    {
        var paper = HeadGeometry.Layout(Shape(HeadForm.Round, HeadColor.Paper), compact: true, darkPage: false);
        Assert.Equal((new HeadRgb(0xEFE9DB), (HeadRgb?)new HeadRgb(0xB8AD95), new HeadRgb(0x1A1A1A)), (paper.Fill, paper.Rim, paper.EyeColor));
        var ink = Shape(HeadForm.Round, HeadColor.Ink);
        var l = HeadGeometry.Layout(ink, compact: true, darkPage: false);
        Assert.Equal((new HeadRgb(0x0A0A0A), new HeadRgb(0xFFFFFF)), (l.Fill, l.EyeColor));
        Assert.Null(l.Rim);
        l = HeadGeometry.Layout(ink, compact: true, darkPage: true);
        Assert.Equal((new HeadRgb(0xF4F4F2), new HeadRgb(0x1A1A1A)), (l.Fill, l.EyeColor));
        Assert.Equal(new HeadRgb(0x636366), HeadGeometry.Layout(ink, compact: true, darkPage: null).Rim);
        l = HeadGeometry.Layout(ink with { Tile = HeadTile.Dark }, compact: true, darkPage: false);
        Assert.Equal((new HeadRgb(0x000000), new HeadRgb(0x1C1C1E)), l.Board);
        Assert.Equal(new HeadRgb(0x03843C), HeadGeometry.Layout(Shape(HeadForm.Round), compact: true, darkPage: false).Fill);
        Assert.Equal(new HeadRgb(0x1A1A1A), HeadGeometry.Layout(Shape(HeadForm.Round), compact: true, darkPage: true).EyeColor);
    }

    [Fact]
    public void OwnerHeads()
    {
        var dance = Head.Parse(J("""{"v":6,"theme":"shape","color":"lilac","form":"cloud","look":"ovals","tile":"none"}"""))!;
        var layout = HeadGeometry.Layout(dance, compact: true, darkPage: false);
        Assert.Equal(new HeadPlacement(1.502, -244, -240.4), layout.Placement);
        Assert.Equal([new HeadPrimitive.Ellipse(533.6, 464.7, 36.4, 52.4), new HeadPrimitive.Ellipse(644, 464.7, 36.4, 52.4)],
            layout.Face.Select(m => m.Primitive).ToArray());
    }

    [Fact]
    public void StarAndHeartMarkup()
    {
        Assert.Equal("M0 -54L14.1 -19.4L51.4 -16.7L22.8 7.4L31.7 43.7L0 24L-31.7 43.7L-22.8 7.4L-51.4 -16.7L-14.1 -19.4Z", HeadGeometry.Star);
        Assert.Equal("M0 -12.9L0.6 -16.1L4.2 -23.7L12.4 -31.5L24.4 -35L37.3 -31.8L47.3 -22.6L51 -9.8L47.3 3.8L37.3 16.5L24.4 28.2L12.4 38.8L4.2 48.1L0.6 54.8L0 57.2L-0.6 54.8L-4.2 48.1L-12.4 38.8L-24.4 28.2L-37.3 16.5L-47.3 3.8L-51 -9.7L-47.3 -22.6L-37.3 -31.8L-24.4 -35L-12.4 -31.5L-4.2 -23.7L-0.6 -16.1Z", HeadGeometry.Heart);
    }

    [Fact]
    public void CacheKeyIgnoresSeedUnlessBlob()
    {
        Assert.Equal(Shape(HeadForm.Round, seed: 1).CacheKey, Shape(HeadForm.Round, seed: 2).CacheKey);
        Assert.NotEqual(Shape(HeadForm.Blob, seed: 1).CacheKey, Shape(HeadForm.Blob, seed: 2).CacheKey);
    }

    /// The same head always makes the same picture, and marks map through their transforms as the web's would.
    [Fact]
    public void GeometryIsDeterministic()
    {
        var a = HeadPicture.For(Head.DefaultShapeHead("inbox"), 28, false) as HeadPicture.Shapes;
        var b = HeadPicture.For(Head.DefaultShapeHead("inbox"), 28, false) as HeadPicture.Shapes;
        Assert.NotNull(a);
        Assert.Equal(a!.Layout.OutlinePath, b!.Layout.OutlinePath);
        Assert.Equal(a.Layout.Face, b.Layout.Face);
        // The left slit's centre (542, 416) through the rotation stays put; the placement maps it as the Mac's pixel test.
        var eye = a.Layout.Face[0].Matrix.Apply(new P(542, 416));
        Assert.Equal(542, eye.X, 6);
        Assert.Equal(416, eye.Y, 6);
        var round = HeadGeometry.Layout(Shape(HeadForm.Round), compact: true, darkPage: false);
        var placed = new HeadMatrix(round.Placement!.Value.K, 0, 0, round.Placement.Value.K, round.Placement.Value.Tx, round.Placement.Value.Ty);
        var px = placed.Apply(new P(542, 416));
        Assert.Equal(92, (int)Math.Round(px.X * 168 / 1024));
        Assert.Equal(58, (int)Math.Round(px.Y * 168 / 1024));
    }

    // MARK: SVG path data

    [Fact]
    public void SvgPathReader()
    {
        var frame = SvgPath.Bounds(SvgPath.Parse(HeadGeometry.Frame));
        Assert.True(Math.Abs(frame.MinX) < 0.5 && Math.Abs(frame.MaxX - 1024) < 0.5 && Math.Abs(frame.MaxY - 1024) < 0.5);
        Assert.Equal((10.0, 10.0, 30.0, 20.0), SvgPath.Bounds(SvgPath.Parse("M10 10h20v5l-5 5z")));
        var monocle = SvgPath.Parse("M123 48q42 78 6 144");
        Assert.Equal(new P(129, 192), ((SvgSegment.Quad)monocle[0].Segments[0]).To);
        var sleepy = SvgPath.Parse("M-42-9A42 33 0 0 0 42-9Z");
        Assert.True(sleepy[0].Closed);
        Assert.Equal(new SvgSegment.Arc(42, 33, 0, false, false, new P(42, -9)), sleepy[0].Segments[0]);
        Assert.Equal(2, SvgPath.Parse("M-144-45H-12V6Q-12 51-63 51H-93Q-144 51-144 6ZM12-45H144V6Q144 51 93 51H63Q12 51 12 6Z").Count);
    }

    // MARK: themed heads

    sealed record Sample(JsonNode Head, string? State, bool Compact, string Sha);

    /// ThemeHeadSvg writes exactly the markup the Mac records for 300+ heads (ids normalised).
    [Fact]
    public void ThemeMarkupMatchesTheMac()
    {
        var samples = Fixture.Load("theme-heads-web.json").AsArray()
            .Select(s => new Sample(s!["head"]!, s["state"]?.GetValue<string>(), s["compact"]!.GetValue<bool>(), s["sha"]!.GetValue<string>())).ToList();
        Assert.True(samples.Count > 300);
        var mismatches = new List<string>();
        foreach (var (s, i) in samples.Select((s, i) => (s, i)))
        {
            var record = HeadRecord.Parse(s.Head);
            if (record == null) { mismatches.Add($"#{i} unparsed"); continue; }
            var state = s.State == null ? (HeadState?)null : HeadWire.Parse<HeadState>(s.State);
            var svg = ThemeHeadSvg.Svg(record, state, s.Compact);
            var normalised = Regex.Replace(svg, "(dh|rb)[0-9a-z]+", "ID");
            var sha = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(normalised)));
            if (sha != s.Sha) mismatches.Add($"#{i} {record.PictureKey}");
        }
        Assert.True(mismatches.Count == 0, string.Join("; ", mismatches.Take(200)) + $" ({mismatches.Count} of {samples.Count})");
    }

    [Theory]
    [InlineData("robot")]
    [InlineData("dots")]
    [InlineData("orb")]
    [InlineData("pixel")]
    [InlineData("glyph")]
    public void EveryThemeDrawsForDirect2D(string theme)
    {
        var record = new HeadRecord { Theme = theme, Tile = "dark" };
        var head = Head.FromRecord(record)!;
        Assert.NotNull(head.Themed);
        var picture = Assert.IsType<HeadPicture.Svg>(HeadPicture.For(head, 28, false));
        Assert.StartsWith("<svg ", picture.Markup);
        Assert.DoesNotContain("filter", picture.Markup);
        Assert.DoesNotContain("<text", picture.Markup);
        Assert.DoesNotContain("class=", picture.Markup);
        Assert.NotNull(System.Xml.Linq.XDocument.Parse(picture.Markup));
        Assert.Equal(theme == "glyph", picture.Label != null);
    }

    [Fact]
    public void RestLookMovesTheFaceRight()
    {
        var robot = new HeadRecord();
        Assert.Contains("class=\"dh-face\" transform=\"translate(22 0)\"", ThemeHeadSvg.Svg(robot, plain: true, restLook: true));
        Assert.DoesNotContain("translate(22 0)", ThemeHeadSvg.Svg(robot, plain: true));
    }

    [Fact]
    public void MatrixHeadsDraw()
    {
        var head = Head.DefaultMatrixHead("finance");
        var svg = MatrixHeadSvg.Svg(head, 28, dark: false);
        Assert.Equal(svg, MatrixHeadSvg.Svg(head, 28, dark: false));
        var dots = MatrixHead.Dots(MatrixDesign.Of(head), MatrixPose.Look);
        Assert.Equal(Regex.Matches(svg, "<circle").Count, dots.Count(d => d.Kind != MatrixDotKind.White));
        Assert.Equal(8, dots.Count(d => d.Kind == MatrixDotKind.Hole));         // two slits, three drawn LEDs: four of the head's
        Assert.Contains("radialGradient", MatrixHeadSvg.Svg(head, 28, dark: true));
        Assert.Equal(0.8427007929497149, MatrixHead.Erf(1), 13);
        Assert.Equal(-0.5204998778130465, MatrixHead.Erf(-0.5), 13);
        // Each outline traced onto the 20-across grid: the counts the Mac's MatrixHead.swift makes (LED for LED, checked
        // against a run of the Swift on 2026-11-21, with every dot's kind and light).
        var counts = new Dictionary<MatrixSilhouette, int>
        {
            [MatrixSilhouette.Round] = 308, [MatrixSilhouette.Square] = 284, [MatrixSilhouette.Tall] = 232, [MatrixSilhouette.Wide] = 232,
            [MatrixSilhouette.Pebble] = 265, [MatrixSilhouette.Cloud] = 297, [MatrixSilhouette.Arch] = 316, [MatrixSilhouette.Shield] = 316,
            [MatrixSilhouette.Drop] = 260, [MatrixSilhouette.Leaf] = 264, [MatrixSilhouette.Hex] = 260, [MatrixSilhouette.Octagon] = 288,
            [MatrixSilhouette.Heart] = 250,
        };
        foreach (var s in Enum.GetValues<MatrixSilhouette>())
        {
            var leds = MatrixHead.Leds(s, 1).Sum(r => r.Count(x => x));
            Assert.Equal(counts[s], leds);
            Assert.Equal(leds, MatrixHead.Leds(s, -1).Sum(r => r.Count(x => x)));
            Assert.True(MatrixHead.Dots(new MatrixDesign { Silhouette = s }).Count(d => d.Light >= 0.5) >= 0.8 * leds, $"{s}");
        }
    }

    // MARK: records, ideas, describe

    [Fact]
    public void DescribeReadsWords()
    {
        var d = HeadDescribe.Describe("sleepy purple cat with goggles");
        Assert.Equal(["purple", "cat", "sleepy", "goggles"], d.Understood);
        Assert.Equal("lilac", d.Parts["color"]);
        Assert.Equal("cat", d.Parts["shape"]);
        Assert.False(d.Parts.ContainsKey("theme"));
        var rocket = HeadDescribe.Describe("🚀 deploys");
        Assert.Equal(("glyph", "🚀", "🚀"), (rocket.Parts["theme"], rocket.Parts["glyph"], rocket.Understood[0]));
        Assert.Equal("shape", HeadDescribe.Describe("cool shades").Parts["theme"]);
        Assert.Empty(HeadDescribe.Describe("xyzzy").Understood);
    }

    [Fact]
    public void SavingKeepsTheThemeButNeverCharacterOrHats()
    {
        var robot = new HeadRecord { Theme = "robot", Hat = "crown" };
        Assert.Equal(("robot", "none"), (robot.ForSaving.Theme, robot.ForSaving.Hat));
        Assert.Equal("shape", new HeadRecord { Theme = "persona" }.ForSaving.Theme);
        Assert.Equal("Robot, Teal, Cat", HeadLabels.Summary(new HeadRecord { Color = "teal", Shape = "cat" }));
        Assert.Equal("Shapes, Grass, Hex", HeadLabels.Summary(new HeadRecord { Theme = "shape", Color = "grass", Form = "hex" }));
    }

    [Fact]
    public void IdeasAreSeededPerBotAndRound()
    {
        var a = HeadRecord.Ideas("deploys", "deploys Ships builds", 0);
        Assert.Equal(10, a.Count);
        Assert.Equal(a, HeadRecord.Ideas("deploys", "deploys Ships builds", 0));
        Assert.NotEqual(a, HeadRecord.Ideas("deploys", "deploys Ships builds", 1));
        // The first half take the bot's subject: deploys are coral.
        Assert.All(a.Take(5), h => Assert.Equal("coral", h.Color));
        Assert.All(a, h => Assert.Equal("shape", h.Theme));
        var rolled = HeadRecord.Roll(new SeededRandom(7).Next, "matrix");
        Assert.True(rolled is { Theme: "matrix", Tile: "none", Mouth: "none", Antenna: "none", EarsKind: "none" });
    }

    [Fact]
    public void StoredRecordRoundTrips()
    {
        var record = HeadRecord.DefaultRecord("ivy");
        var stored = record.Stored();
        Assert.Equal(6, stored["v"]!.GetValue<int>());
        Assert.True(stored["headset"]!.GetValue<bool>());          // ICON_HEAD's ears
        Assert.Equal(22, stored.Count);
        Assert.Equal(record, HeadRecord.Parse(stored));
        Assert.Equal(Head.DefaultShapeHead("ivy"), record.Head);
        Assert.Equal("✨", HeadRecord.CleanGlyph("   "));
        Assert.Equal("🦊", HeadRecord.CleanGlyph("ab🦊"));
        Assert.Equal("AB", HeadRecord.CleanGlyph("A-B-C"));
    }

    // MARK: save (§7.5)

    [Fact]
    public void SaveRequestShape()
    {
        var p = HeadStore.SaveParams("inbox", new HeadRecord { Theme = "shape" }.Stored(), 4);
        Assert.Equal("inbox", p["name"]!.GetValue<string>());
        Assert.Equal("shape", p["ui_meta"]!["dispatch-head"]!["theme"]!.GetValue<string>());
        Assert.Equal(4, p["ui_meta_expected_revisions"]!["dispatch-head"]!.GetValue<int>());
        Assert.Equal(3, p.Count);
        // Reset Head writes null.
        var reset = HeadStore.SaveParams("inbox", null, 4);
        Assert.True(reset["ui_meta"]!.AsObject().ContainsKey("dispatch-head"));
        Assert.Null(reset["ui_meta"]!["dispatch-head"]);
        Assert.Equal("""{"name":"inbox","ui_meta":{"dispatch-head":null},"ui_meta_expected_revisions":{"dispatch-head":4}}""", reset.ToJsonString());
    }

    [Fact]
    public void SaveResults()
    {
        Assert.Equal(5, HeadStore.ReadSaveResult(J("""{"applied":{"ui_meta":true,"ui_meta_revisions":{"dispatch-head":5}}}"""), 4));
        Assert.Equal(5, HeadStore.ReadSaveResult(J("""{"applied":{"ui_meta":true}}"""), 4));
        var conflict = Assert.Throws<HeadSaveException>(() =>
            HeadStore.ReadSaveResult(J("""{"applied":{"ui_meta":false,"ui_meta_conflicts":{"dispatch-head":{"expected":4,"actual":9}}}}"""), 4));
        Assert.Equal(9, conflict.ActualRevision);
        Assert.Equal(HeadSaveException.ConflictWords, conflict.Message);
        Assert.Equal(HeadSaveException.Outdated, Assert.Throws<HeadSaveException>(() => HeadStore.ReadSaveResult(J("""{"ok":true}"""), 4)).Message);
        Assert.Equal(HeadSaveException.NotSaved, Assert.Throws<HeadSaveException>(() => HeadStore.ReadSaveResult(J("""{"applied":{"ui_meta":false}}"""), 4)).Message);
    }

    [Fact]
    public async Task SaveSendsCompareAndSwapAndShowsAtOnce()
    {
        var calls = new List<(string, JsonObject)>();
        RpcCall rpc = (method, p, _, _) =>
        {
            calls.Add((method, p));
            return Task.FromResult<JsonNode>(J("""{"applied":{"ui_meta":true,"ui_meta_revisions":{"dispatch-head":3}}}"""));
        };
        var bot = Roster.Parse(Fixture.Load("demo-profiles-list.json")).First(b => b.Name == "inbox");
        var draft = new HeadRecord { Theme = "shape", Color = "grape", Form = "hex", Tile = "none", Hat = "crown" };
        string? changed = null;
        void OnChange(string n) => changed = n;
        HeadStore.Changed += OnChange;
        try
        {
            var revision = await HeadStore.SaveAsync(rpc, "inbox", draft, bot.HeadRevision);
            Assert.Equal(Math.Max(3, bot.HeadRevision + 1), revision);
            Assert.Equal("inbox", changed);
            var (method, sent) = calls.Single();
            Assert.Equal("profiles.configure", method);
            Assert.Equal("none", sent["ui_meta"]!["dispatch-head"]!["hat"]!.GetValue<string>());
            Assert.Equal(bot.HeadRevision, sent["ui_meta_expected_revisions"]!["dispatch-head"]!.GetValue<int>());
            // The overlay shows the new head before the roster catches up.
            Assert.True(HeadStore.HeadOf(bot) is { Color: HeadColor.Grape, Form: HeadForm.Hex });
        }
        finally
        {
            HeadStore.Changed -= OnChange;
            HeadStore.Forget();
        }
        RpcCall failing = (_, _, _, _) => throw new GatewayException("timeout", "");
        Assert.Equal(HeadSaveException.NoAnswer, (await Assert.ThrowsAsync<HeadSaveException>(() => HeadStore.SaveAsync(failing, "inbox", draft, 1))).Message);
    }

    [Fact]
    public async Task ResetRemovesOnlyThisAppsDesktopCopy()
    {
        var mirror = "data:image/png;base64," + Convert.ToBase64String([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 1, 0x20, 0, 0, 1, 0x20, 8, 6, 0, 0, 0]);
        Assert.True(HeadRecord.IsHeadMirror(mirror));
        Assert.Equal(PhotoVerdict.Mirror, BotPicture.Classify(true, mirror).Verdict);
        Assert.Equal(PhotoVerdict.None, BotPicture.Classify(false, null).Verdict);
        Assert.Equal(PhotoVerdict.Photo, BotPicture.Classify(true, "data:image/jpeg;base64,/9j/4AAQSkZJRg==").Verdict);
        foreach (var (data, clears) in new[] { (mirror, true), ("data:image/jpeg;base64,/9j/4AAQSkZJRg==", false) })
        {
            var calls = new List<(string, JsonObject)>();
            RpcCall rpc = (m, p, _, _) =>
            {
                calls.Add((m, p));
                return Task.FromResult<JsonNode>(m == "profiles.get_asset" ? new JsonObject { ["found"] = true, ["data"] = data } : J("""{"ok":true}"""));
            };
            await HeadStore.MirrorAsync(rpc, "inbox", null);
            Assert.Equal(clears ? 2 : 1, calls.Count);
            if (clears) Assert.True(calls[1].Item2["clear"]!.GetValue<bool>());
        }
    }

    // MARK: Edit Head's model

    static Bot Inbox() => Roster.Parse(Fixture.Load("demo-profiles-list.json")).First(b => b.Name == "inbox");

    [Fact]
    public void EditorOpensOnTheSavedHeadAndTracksChanges()
    {
        var bot = Inbox();
        var model = new EditHeadModel(bot, HeadStore.State(bot));
        Assert.True(model.Opened.Saved);
        Assert.Equal(("shape", "sky", "blob"), (model.Draft.Theme, model.Draft.Color, model.Draft.Form));
        Assert.False(model.HasChanges);
        Assert.Equal(10, model.Ideas.Count);
        Assert.Same(model.Ideas, model.Ideas);
        model.Set(h => h.Color = "grape");
        Assert.True(model.HasChanges);
        Assert.Null(model.Undo);                    // one part is not undoable, a whole head is
        model.Shuffle(new SeededRandom(3).Next);
        Assert.NotNull(model.Undo);
        Assert.Equal(1, model.Round);
        model.UndoLast();
        Assert.Equal("grape", model.Draft.Color);
        Assert.Equal(20, model.Palette.Length);
        Assert.Equal([("Shape", HeadRecord.Forms, HeadLabels.Forms, "form")], model.Strips);
    }

    [Fact]
    public void EditorThemesAndDescribe()
    {
        var bot = Inbox();
        var model = new EditHeadModel(bot, new StoredHeadState(null, 0, false));
        Assert.Equal(HeadRecord.DefaultRecord("inbox"), model.Draft);
        model.PickTheme("robot");
        Assert.Equal(("robot", "dark"), (model.Draft.Theme, model.Draft.Tile));
        Assert.Equal(["Head", "Visor", "Shell"], model.Strips.Select(s => s.Title));
        model.PickTheme("matrix");
        Assert.Equal(("matrix", "none"), (model.Draft.Theme, model.Draft.Tile));
        Assert.Equal(["shape", "none"], [EditHeadModel.Themed(model.Draft, "shape").Theme, EditHeadModel.Themed(model.Draft, "shape").Tile]);
        model.Describe("sleepy purple cat");
        Assert.Equal("Got it: purple, cat, sleepy", model.UnderstoodWords);
        Assert.Equal("lilac", model.Draft.Color);
        model.Describe("sleepy");
        Assert.Equal("Got it: sleepy", model.UnderstoodWords);
        Assert.NotEqual("lilac", model.Draft.Color);   // deleting a word takes it back
        model.Describe("xyzzy");
        Assert.Equal("Try a color, an animal, a mood, or what the bot does.", model.UnderstoodWords);
        string? stored = null;
        var styled = new EditHeadModel(bot, new StoredHeadState(null, 0, false), () => stored, json => stored = json);
        styled.PickTheme("orb");
        styled.SetStyle();
        Assert.NotNull(stored);
        var other = new EditHeadModel(Roster.Parse(Fixture.Load("demo-profiles-list.json")).First(b => b.Name == "garden"),
            new StoredHeadState(null, 0, false), () => stored);
        other.UseStyle();
        Assert.Equal("orb", other.Draft.Theme);
        Assert.Equal(HeadRecord.DefaultRecord("garden").Color, other.Draft.Color);
    }

    [Fact]
    public async Task EditorSaveConflictKeepsTheDraftAndTheGatewaysRevision()
    {
        var bot = Inbox();
        var model = new EditHeadModel(bot, HeadStore.State(bot));
        model.Set(h => h.Form = "star");
        RpcCall rpc = (_, _, _, _) => Task.FromResult<JsonNode>(J("""{"applied":{"ui_meta":false,"ui_meta_conflicts":{"dispatch-head":{"actual":41}}}}"""));
        Assert.False(await model.SaveAsync(rpc, model.Draft));
        Assert.Equal(41, model.Revision);
        Assert.Equal(HeadSaveException.ConflictWords, model.Notice);
        Assert.Equal("star", model.Draft.Form);
        Assert.False(model.Saving);
        var sent = new List<JsonObject>();
        RpcCall ok = (m, p, _, _) => { if (m == "profiles.configure") sent.Add(p); return Task.FromResult<JsonNode>(J("""{"applied":{"ui_meta":true,"ui_meta_revisions":{"dispatch-head":42}}}""")); };
        try
        {
            Assert.True(await model.SaveAsync(ok, model.Draft));
            Assert.Equal(41, sent.Single()["ui_meta_expected_revisions"]!["dispatch-head"]!.GetValue<int>());
            Assert.Equal(42, model.Revision);
        }
        finally { HeadStore.Forget(); }
    }
}
