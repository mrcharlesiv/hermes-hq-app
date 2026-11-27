using System.Security.Cryptography;
using System.Text.Json;
using Hermes.Core.Transcripts;
using Hermes.Typeset;

namespace Hermes.Core.Tests.Typeset;

// [WIN-MATH-ENGINE] Hermes.Math's MathEngine (CSharpMath in Latin Modern Math) against the Mac's SwiftMath. The Mac's
// numbers are mac-swiftmath-metrics.json: tools/swiftmath-metrics run on macOS over Vendor/SwiftMath at 93f984bb1
// (HQMathLine, size 19 = MathTypeset.BaseSize(17)), for every golden formula of MathTypesetTests in both styles.

public class MathEngineTests
{
    private sealed record MacLine(string Source, string Latex, bool Block, double Size, double? Width, double? Ascent, double? Descent);

    private static readonly Lazy<IReadOnlyList<MacLine>> Mac = new(() =>
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Typeset", "mac-swiftmath-metrics.json");
        var lines = new List<MacLine>();
        foreach (var e in JsonDocument.Parse(File.ReadAllText(path)).RootElement.EnumerateArray())
        {
            // Swift's encoder leaves a nil measure out.
            double? Number(string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : null;
            lines.Add(new MacLine(e.GetProperty("source").GetString()!, e.GetProperty("latex").GetString()!,
                e.GetProperty("block").GetBoolean(), e.GetProperty("size").GetDouble(), Number("width"), Number("ascent"), Number("descent")));
        }
        return lines;
    });

    private static MacLine MacOf(string latex, bool block) => Mac.Value.Single(l => l.Latex == latex && l.Block == block);

    /// The folder the drawn formulas are saved to, beside the test assembly.
    private static string RenderDir()
    {
        var dir = Path.Combine(AppContext.BaseDirectory, "math-renders");
        Directory.CreateDirectory(dir);
        return dir;
    }

    [Fact]
    public void TheFontIsTheMacsLatinModernMath()
    {
        // CSharpMath.Rendering embeds latinmodern-math.otf: the same bytes the Mac vendors in mathFonts.bundle.
        using var stream = typeof(CSharpMath.Rendering.BackEnd.Fonts).Assembly
            .GetManifestResourceStream("CSharpMath.Rendering.Reference_Fonts.latinmodern-math.otf");
        Assert.NotNull(stream);
        using var copy = new MemoryStream();
        stream!.CopyTo(copy);
        const string MacSha256 = "6075562b771f8b82f0c179e363389684f2dd09de30038269e2628e504bd7be0f";
        Assert.Equal(733736, copy.Length);
        Assert.Equal(MacSha256, Convert.ToHexString(SHA256.HashData(copy.ToArray())).ToLowerInvariant());
        // Where the Mac's tree is checked out beside windows/ (not in the Windows CI export), the file itself agrees.
        var vendored = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
            "../../../../../../Vendor/SwiftMath/Sources/SwiftMath/mathFonts.bundle/latinmodern-math.otf"));
        if (File.Exists(vendored))
            Assert.Equal(MacSha256, Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(vendored))).ToLowerInvariant());
    }

    [Fact]
    public void TheMacsNumbersCoverEveryGoldenFormulaInBothStyles()
    {
        foreach (var (source, _, prepared) in MathTypesetTests.Golden)
            foreach (var block in new[] { false, true })
                Assert.Contains(Mac.Value, l => l.Source == source && l.Latex == prepared && l.Block == block && l.Size == 19);
        Assert.Equal(MathTypesetTests.Golden.Length * 2, Mac.Value.Count);
    }

    /// Every golden formula is either set (finite, a width above zero) or nil, and nil exactly where the Mac's
    /// SwiftMath is: 16 of 124 (8 formulas in both styles).
    [Fact]
    public void NilExactlyWhereTheMacsSwiftMathIsNil()
    {
        var mismatches = new List<string>();
        foreach (var mac in Mac.Value)
        {
            var win = MathEngine.Measure(mac.Latex, mac.Size, mac.Block);
            if (win is { } m)
            {
                Assert.True(m.Width > 0 && double.IsFinite(m.Width) && double.IsFinite(m.Ascent) && double.IsFinite(m.Descent), mac.Latex);
                Assert.True(m.Ascent + m.Descent > 0, mac.Latex);
            }
            if ((win == null) != (mac.Width == null))
                mismatches.Add($"{(mac.Block ? "block" : "inline")} {mac.Latex}: Mac {(mac.Width == null ? "nil" : "set")}, Windows {(win == null ? "nil" : "set")}");
        }
        Assert.True(mismatches.Count == 0, "unlike the Mac: " + string.Join("  ||  ", mismatches));
        Assert.Equal(16, Mac.Value.Count(l => l.Width == null));
        Assert.Equal(
            ["", "\\Bigg", "\\big", "\\over", "\\stackrel{a}{b}", "\\under", "a   b \\nonumbers", "{}"],
            Mac.Value.Where(l => l.Width == null).Select(l => l.Latex).Distinct().Order(StringComparer.Ordinal));
    }

    /// A formula of single glyphs and scripts measures as the Mac's to the hundredth of a point: the same font, the
    /// same size (CSharpMath's 96-per-inch size × 0.75) and the same script rules.
    [Theory]
    [InlineData("a", false)]
    [InlineData("x^{ab}", false)]
    [InlineData("x_{ij}", true)]
    [InlineData("x^{a}_{b}", false)]
    [InlineData("\\mathfrak{g}", false)]
    [InlineData("\\bm{x}", true)]
    [InlineData("\\oint", true)]
    [InlineData("\\prod", true)]
    public void GlyphsMeasureAsTheMacs(string latex, bool block)
    {
        var mac = MacOf(latex, block);
        var win = MathEngine.Measure(latex, 19, block)!.Value;
        Assert.Equal(mac.Width!.Value, win.Width, 0.01);
        Assert.Equal(mac.Ascent!.Value, win.Ascent, 0.01);
        Assert.Equal(mac.Descent!.Value, win.Descent, 0.02);
    }

    /// An accent over a first letter starts left of the line: Windows counts that overhang into the width (and draws
    /// the line that far in) so the accent isn't cut; the Mac's width is the letter's alone. Heights are the Mac's.
    [Fact]
    public void AnAccentsOverhangIsCountedIn()
    {
        var mac = MacOf("\\tilde{x}", false);
        var win = MathEngine.Measure("\\tilde{x}", 19, false)!.Value;
        Assert.Equal(mac.Ascent!.Value, win.Ascent, 0.01);
        Assert.Equal(mac.Descent!.Value, win.Descent, 0.02);
        Assert.InRange(win.Width - mac.Width!.Value, 0.1, 2.5);
        Assert.Equal(mac.Width!.Value, MathEngine.Measure("x", 19, false)!.Value.Width, 0.01);
    }

    /// SwiftMath's own rules: a text-style operator is as large as display style's, with its limits above and below.
    [Fact]
    public void AnInlineLargeOperatorIsSetAsTheMacs()
    {
        foreach (var latex in new[] { "\\oint", "\\prod" })
            Assert.Equal(MathEngine.Measure(latex, 19, true), MathEngine.Measure(latex, 19, false));
        var mac = MacOf("\\| \\vec{v} \\| = \\sqrt{\\sum_{i=1}^{n} v_i^2}", false);
        var win = MathEngine.Measure(mac.Latex, 19, false)!.Value;
        Assert.Equal(mac.Ascent!.Value, win.Ascent, 0.01);
        Assert.Equal(mac.Descent!.Value, win.Descent, 0.01);
    }

    /// Three formulas beside the Mac's numbers (also written to math-renders/metrics-vs-mac.txt). Spacing between atoms
    /// is the known difference: CSharpMath sets mu spaces at 3/4 of SwiftMath's, so widths run up to ~8% narrower.
    [Fact]
    public void ThreeFormulasMeasureCloseToTheMacs()
    {
        var report = new List<string> { "latex | style | Mac w/a/d | Windows w/a/d" };
        foreach (var (latex, block) in new[]
                 {
                     ("E = mc^2", false),
                     ("x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}", true),
                     ("\\begin{aligned} (a+b)^2 &= (a+b)(a+b) \\\\ &= a^2 + 2ab + b^2 \\end{aligned}", true),
                 })
        {
            var mac = MacOf(latex, block);
            var win = MathEngine.Measure(latex, 19, block)!.Value;
            report.Add($"{latex} | {(block ? "block" : "inline")} | {mac.Width:F2}/{mac.Ascent:F2}/{mac.Descent:F2} | {win.Width:F2}/{win.Ascent:F2}/{win.Descent:F2}");
            Assert.InRange(win.Width / mac.Width!.Value, 0.90, 1.05);
            Assert.InRange(win.Ascent / mac.Ascent!.Value, 0.90, 1.05);
            Assert.InRange((win.Ascent + win.Descent) / (mac.Ascent!.Value + mac.Descent!.Value), 0.90, 1.05);
        }
        File.WriteAllLines(Path.Combine(RenderDir(), "metrics-vs-mac.txt"), report);
    }

    /// Mirrors the Mac's `theSamplesAreSet` with the real typesetter: every sample is set by `MathTypeset.Fit`.
    [Fact]
    public void TheSamplesAreSetByTheRealTypesetter()
    {
        var failed = MathTypesetTests.Samples
            .Where(s => MathTypeset.Fit(s.Source, s.Block, 17, MathEngine.Measurer) == null).Select(s => s.Source).ToList();
        Assert.True(failed.Count == 0, "not set: " + string.Join("  ||  ", failed));
        Assert.Null(MathTypeset.Fit(@"\notacommand{x}", false, 17, MathEngine.Measurer));
    }

    /// Mirrors `anInlineFormulaFitsItsLine` with the real typesetter: a 49-point line takes the quadratic formula.
    [Fact]
    public void AnInlineFormulaFitsItsLine()
    {
        const double Limit = 49;
        foreach (var source in new[]
                 {
                     @"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}", @"\lVert \vec{v} \rVert = \sqrt{\sum_{i=1}^{n} v_i^2}",
                     @"\vec{v} \in \mathbb{R}^n", @"e^{i\pi} + 1 = 0",
                 })
        {
            var fit = MathTypeset.Fit(source, false, 17, MathEngine.Measurer, maxHeight: Limit, maxWidth: MathTypeset.BlockWidth);
            Assert.True(fit != null, source);
            Assert.True(fit!.Bounds.Height <= Limit + 4, source);
        }
    }

    [Fact]
    public void CommandsSwiftMathKnowsAreWrittenAsCSharpMathKnowsThem()
    {
        Assert.Equal(@"\bm{\beta}", MathEngine.InCSharpMathWords(@"\boldsymbol{\beta}"));
        Assert.Equal(@"a \equiv b \left(\operatorname{mod}\,\,{n}\right), x", MathEngine.InCSharpMathWords(@"a \equiv b \pmod{n}, x"));
        Assert.Equal(@"\left(\operatorname{mod}\,\,{2\pi}\right)", MathEngine.InCSharpMathWords(@"\pmod {2\pi}"));
        Assert.Equal(@"\sum_{{i}}", MathEngine.InCSharpMathWords(@"\sum_{\substack{i}}"));
        Assert.Equal(@"\sum_{{{i<n} \atop {j}}}", MathEngine.InCSharpMathWords(@"\sum_{\substack{i<n \\ j}}"));
        // Untouched: other commands, control symbols, a longer name, an unbalanced argument.
        foreach (var same in new[] { @"\frac{a}{b} \\ \{ \, \boldsymbolic", @"\pmod{n", @"\substack", "plain", "" })
            Assert.Equal(same, MathEngine.InCSharpMathWords(same));
        foreach (var latex in new[] { @"\boldsymbol{\beta}", @"a \pmod{n}", @"\sum_{\substack{0<i<m \\ 0<j<n}} P(i,j)" })
            Assert.NotNull(MathEngine.Measure(latex, 19, true));
    }

    /// The Mac's picture: the bounds at the scale, the baseline the pad in from the left and the descent plus the pad
    /// up from the bottom, transparent around the ink.
    [Fact]
    public void ThePictureIsTheBoundsWithTheBaselineWhereTheMacsIs()
    {
        var fit = MathTypeset.Fit("x_{ij}", false, 17, MathEngine.Measurer)!;
        var bounds = fit.Bounds;
        foreach (var scale in new[] { 1.0, 2.0, 1.25 })
        {
            var picture = MathEngine.Draw(fit, new MathColor(0, 0, 0), scale)!;
            Assert.Equal((int)Math.Ceiling(bounds.Width * scale), picture.Width);
            Assert.Equal((int)Math.Ceiling(bounds.Height * scale), picture.Height);
            Assert.Equal((Math.Ceiling(fit.Ascent + MathFit.Pad)) * scale, picture.BaselineY, 6);
            Assert.Equal(picture.Width * 4, picture.Stride);
            var ink = Ink(picture);
            Assert.True(ink.Count > 0);
            // The ink sits on the baseline: its top at the ascent above, its bottom at the descent below (±1 pixel).
            Assert.InRange(ink.MinY, picture.BaselineY - fit.Ascent * scale - 1, picture.BaselineY - fit.Ascent * scale + 1.5);
            Assert.InRange(ink.MaxY, picture.BaselineY + fit.Descent * scale - 1.5, picture.BaselineY + fit.Descent * scale + 1);
            Assert.True(ink.MinX >= 0 && ink.MaxX < picture.Width);
        }
    }

    public static TheoryData<string, string> Renders => new()
    {
        { "aligned", @"\begin{aligned} (a+b)^2 &= (a+b)(a+b) \\ &= a^2 + 2ab + b^2 \end{aligned}" },
        { "cases", @"f(x) = \begin{cases} x^2 & \text{if } x \ge 0 \\ -x & \text{otherwise} \end{cases}" },
        { "pmatrix", @"A = \begin{pmatrix} a & b \\ c & d \end{pmatrix}" },
        { "frac", @"P(A \mid B) = \frac{P(B \mid A)\,P(A)}{P(B)}" },
        { "sqrt", @"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}" },
        { "sum-with-limits", @"\sum_{i=1}^{n} i = \frac{n(n+1)}{2}" },
    };

    /// Drawn to PNG (math-renders/*.png): ink, anti-aliased into many shades, every shade the colour asked for, a
    /// structure taller than a line, and the same shape in a light theme's ink and a dark theme's.
    [Theory]
    [MemberData(nameof(Renders))]
    public void DrawnInTheColourAskedFor(string name, string source)
    {
        var dark = new MathColor(0x1C, 0x1C, 0x1E);
        var light = new MathColor(0xF2, 0xF2, 0xF7);
        var accent = new MathColor(0xD0, 0x30, 0x60);
        var fit = MathTypeset.Fit(source, true, 17, MathEngine.Measurer)!;
        Assert.NotNull(fit);
        MathPicture? first = null;
        foreach (var (color, tag) in new[] { (dark, "dark"), (light, "light"), (accent, "accent") })
        {
            var picture = MathEngine.Draw(fit, color, 2)!;
            File.WriteAllBytes(Path.Combine(RenderDir(), $"{name}-{tag}@2x.png"), picture.EncodePng());
            var ink = Ink(picture);
            Assert.True(ink.Count > 200, $"{name}: {ink.Count} pixels of ink");
            Assert.True(ink.Shades.Count >= 8, $"{name}: {ink.Shades.Count} shades (anti-aliased edges)");
            // Nothing cut: the pad keeps the outermost pixels clear (a table's last column once ran past its width).
            Assert.True(ink.MinX > 0 && ink.MaxX < picture.Width - 1 && ink.MinY > 0 && ink.MaxY < picture.Height - 1,
                $"{name}: ink x {ink.MinX}..{ink.MaxX} of {picture.Width}, y {ink.MinY}..{ink.MaxY} of {picture.Height}");
            // Taller than one line of letters (an 'a' is 8.4 points): rows, a stack or a limit.
            Assert.True((ink.MaxY - ink.MinY) / 2.0 > 24, $"{name}: {(ink.MaxY - ink.MinY) / 2.0} points of ink");
            // Every inked pixel, unpremultiplied, is the colour asked for (where it is opaque enough to say).
            foreach (var (b, g, r, a) in ink.Pixels.Where(p => p.A >= 64))
            {
                Assert.InRange(r * 255.0 / a, color.R - 4, color.R + 4);
                Assert.InRange(g * 255.0 / a, color.G - 4, color.G + 4);
                Assert.InRange(b * 255.0 / a, color.B - 4, color.B + 4);
            }
            Assert.Contains(ink.Pixels, p => p.A == 255);
            // The same shape whatever the colour: the alpha masks agree.
            if (first == null) first = picture;
            else Assert.Equal(Alpha(first), Alpha(picture));
        }
    }

    /// Every golden formula that is set, in either style, draws inside its picture: no ink on the outermost pixels.
    [Fact]
    public void NoGoldenFormulaIsCut()
    {
        var cut = new List<string>();
        foreach (var (source, _, _) in MathTypesetTests.Golden)
            foreach (var block in new[] { false, true })
            {
                if (MathTypeset.Fit(source, block, 17, MathEngine.Measurer) is not { } fit) continue;
                var picture = MathEngine.Draw(fit, new MathColor(0, 0, 0), 2)!;
                var ink = Ink(picture);
                Assert.True(ink.Count > 0, source);
                if (!(ink.MinX > 0 && ink.MaxX < picture.Width - 1 && ink.MinY > 0 && ink.MaxY < picture.Height - 1))
                    cut.Add($"{(block ? "block" : "inline")} {source}: x {ink.MinX}..{ink.MaxX}/{picture.Width} y {ink.MinY}..{ink.MaxY}/{picture.Height}");
            }
        Assert.True(cut.Count == 0, "cut: " + string.Join("  ||  ", cut));
    }

    [Fact]
    public void WhatCantBeSetIsNotDrawn()
    {
        Assert.Null(MathEngine.Draw(@"\notacommand{x}", true, 17, new MathColor(0, 0, 0)));
        Assert.Null(MathEngine.Draw(@"\stackrel{a}{b}", true, 17, new MathColor(0, 0, 0)));
        Assert.Null(MathEngine.Measure("x", 0, false));
        Assert.Null(MathEngine.Measure("x", double.NaN, false));
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            MathEngine.Draw(MathTypeset.Fit("x_{ij}", false, 17, MathEngine.Measurer)!, new MathColor(0, 0, 0), 0));
    }

    private sealed record InkScan(int Count, int MinX, int MaxX, int MinY, int MaxY, HashSet<int> Shades, List<(byte B, byte G, byte R, byte A)> Pixels);

    private static InkScan Ink(MathPicture picture)
    {
        int count = 0, minX = int.MaxValue, maxX = -1, minY = int.MaxValue, maxY = -1;
        var shades = new HashSet<int>();
        var pixels = new List<(byte, byte, byte, byte)>();
        for (var y = 0; y < picture.Height; y++)
            for (var x = 0; x < picture.Width; x++)
            {
                var at = y * picture.Stride + x * 4;
                var a = picture.Bgra[at + 3];
                if (a == 0)
                {
                    Assert.True(picture.Bgra[at] == 0 && picture.Bgra[at + 1] == 0 && picture.Bgra[at + 2] == 0, "transparent is clear");
                    continue;
                }
                count++;
                minX = Math.Min(minX, x); maxX = Math.Max(maxX, x);
                minY = Math.Min(minY, y); maxY = Math.Max(maxY, y);
                shades.Add(BitConverter.ToInt32(picture.Bgra, at));
                pixels.Add((picture.Bgra[at], picture.Bgra[at + 1], picture.Bgra[at + 2], a));
            }
        return new InkScan(count, minX, maxX, minY, maxY, shades, pixels);
    }

    private static byte[] Alpha(MathPicture picture)
    {
        var alpha = new byte[picture.Width * picture.Height];
        for (var y = 0; y < picture.Height; y++)
            for (var x = 0; x < picture.Width; x++)
                alpha[y * picture.Width + x] = picture.Bgra[y * picture.Stride + x * 4 + 3];
        return alpha;
    }
}
