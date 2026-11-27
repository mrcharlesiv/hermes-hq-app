using Hermes.Core.Shell;
using Hermes.Core.Transcripts;
using Hermes.Typeset;

namespace Hermes.Core.Tests;

// [WIN-MATH-UI] The chat's plan for each formula (Hermes.Core/Transcript/MathRunPlan.cs), the selection's copy
// (MathCopy, the Mac's SelectionText.plain in MessageSelection.swift), the per-colour picture cache (MathAttachment.drawn)
// and the chat-math walk's checks (MathWalkProof), against the Mac's MarkdownRenderer.swift / MathTypeset.swift at
// 93f984bb1. Fake measurers pin the rules; the real typesetter (Hermes.Math) runs the walk's fixture headless.
public class MathRunPlanTests
{
    private const double Body = 14, Line = 21;   // MarkdownRenderer's body size and paragraph line height

    private static MathMeasure Fixed(double w, double a, double d) => (_, size, _) => (w * size / 10, a * size / 10, d * size / 10);
    private static readonly MathMeasure Never = (_, _, _) => null;
    private static TakenFormula F(string source, bool block = false, string? written = null) =>
        new(source, block, block, written ?? (block ? "$$" + source + "$$" : "$" + source + "$"));

    [Fact]
    public void AnInlineFractionIsAPictureOnTheBaselineAtTheWordsSizeTimes112()
    {
        var run = MathRunPlan.Inline(F(@"\frac{a}{b}"), Body, Line, Fixed(10, 8, 4));
        Assert.Equal(MathRunKind.Picture, run.Kind);
        Assert.False(run.Block);
        Assert.Equal(15.5, run.Fit!.Size);   // (14 × 1.12 × 2).rounded() / 2
        // 15.5/10 × (10, 8, 4) = (15.5, 12.4, 6.2): bounds rounded up with the pad of 1 all round.
        Assert.Equal(18, run.Width);
        Assert.Equal(Math.Ceiling(12.4 + 1) + Math.Ceiling(6.2 + 1), run.Height);
        Assert.Equal(8, run.BaselineDrop);   // ceil(descent + pad) below the baseline
        Assert.True(run.GrowsLine);          // 22 > 21 - 2
        Assert.Equal(@"\frac{a}{b}", run.Copy);
        Assert.Equal("\uFFFC", run.Drawn);
    }

    [Fact]
    public void AnInlineFormulaTallerThanTwoPointFourLinesIsSetSmallerAndAShortOneDoesntGrowTheLine()
    {
        Assert.Equal(50, MathRunPlan.InlineMaxHeight(21));   // (21 × 2.4).rounded()
        // 10 tall per size-unit → 15.5 tall at 15.5: no shrink. 40 per unit → 62 > 50: set at floor(15.5×50/62×2)/2 = 12.5.
        var tall = MathRunPlan.Inline(F(@"\sqrt{x}"), Body, Line, Fixed(10, 30, 10));
        Assert.Equal(12.5, tall.Fit!.Size);
        var small = MathRunPlan.Inline(F(@"\sqrt{x}"), Body, Line, Fixed(4, 5, 1));
        Assert.Equal(15.5, small.Fit!.Size);
        Assert.False(small.GrowsLine);   // ceil(7.75+1)+ceil(1.55+1) = 9+3 = 12 ≤ 19
    }

    [Fact]
    public void AnInlineFormulaWithoutStructureStaysReadableTextThatDoesntBreak()
    {
        var run = MathRunPlan.Inline(F("E = mc^2"), Body, Line, Fixed(10, 8, 4));
        Assert.Equal(MathRunKind.Readable, run.Kind);
        Assert.Null(run.Fit);
        Assert.DoesNotContain(' ', run.Drawn);
        Assert.Equal("E\u2060\u00A0\u2060=\u2060\u00A0\u2060m\u2060c\u2060²", run.Drawn);
        Assert.Equal("E = mc^2", run.Copy);
        // Copied whole, the source; in part, the drawn characters without their joiners.
        var piece = new CopyPiece(0, run.Drawn.Length, run.Drawn, run.Copy);
        Assert.Equal("E = mc^2", MathCopy.Plain([piece], 0, run.Drawn.Length));
        Assert.Equal("E\u00A0=", MathCopy.Plain([piece], 0, 5));
    }

    [Fact]
    public void AFormulaTheTypesetterCantSetFallsBackToReadableThenSource()
    {
        // Needs typesetting, typesetter says nil, readable exists → readable.
        var readable = MathRunPlan.Inline(F(@"\frac{1}{2}"), Body, Line, Never);
        Assert.Equal(MathRunKind.Readable, readable.Kind);
        // No readable text and no typesetter → the source as written.
        var source = MathRunPlan.Inline(F(@"\begin{tikzcd} A \end{tikzcd}", written: @"\(\begin{tikzcd} A \end{tikzcd}\)"), Body, Line, Never);
        Assert.Equal(MathRunKind.Source, source.Kind);
        Assert.Equal(@"\(\begin{tikzcd} A \end{tikzcd}\)", source.Drawn);
        Assert.Equal(@"\begin{tikzcd} A \end{tikzcd}", source.Copy);
        // Display: picture, else readable centred, else a code card of the source.
        var block = MathRunPlan.Display(F(@"\begin{tikzcd} A \end{tikzcd}", block: true), Body, Never, first: false);
        Assert.Equal(MathRunKind.Source, block.Kind);
        Assert.Equal(@"\begin{tikzcd} A \end{tikzcd}", block.Drawn);
    }

    [Fact]
    public void InsideALinkAFormulaCopiesNothingOfItsOwn()
    {
        Assert.Null(MathRunPlan.Inline(F(@"\frac{a}{b}"), Body, Line, Fixed(10, 8, 4), inLink: true).Copy);
        Assert.Null(MathRunPlan.Inline(F("x_1"), Body, Line, Fixed(10, 8, 4), inLink: true).Copy);
    }

    [Fact]
    public void ADisplayFormulaIsACentredBlockFittedToTheBlockWidthWithItsGaps()
    {
        var run = MathRunPlan.Display(F(@"\sum_{i=1}^n i", block: true), Body, Fixed(10, 8, 4), first: false);
        Assert.Equal(MathRunKind.Picture, run.Kind);
        Assert.True(run.Block);
        Assert.Equal((8.0, 8.0), (run.TopGap, run.BottomGap));
        Assert.Equal(0, MathRunPlan.Display(F("x", block: true), Body, Fixed(10, 8, 4), first: true).TopGap);
        // 600 per unit at 15.5 = 930 wide > 520: scale 520/930 → floor(15.5 × 0.559 × 2)/2 = 8.5.
        var wide = MathRunPlan.Display(F(@"\sum x", block: true), Body, Fixed(600, 8, 4), first: false);
        Assert.Equal(8.5, wide.Fit!.Size);
        Assert.True(wide.Width <= MathTypeset.BlockWidth + 2);
        // A narrower column fits it narrower still; one that needs under half its size falls back.
        var narrow = MathRunPlan.Display(F(@"\sum x", block: true), Body, Fixed(400, 8, 4), first: false, columnWidth: 400);
        Assert.Equal(10, narrow.Fit!.Size);   // 620 wide in a 400 column: floor(15.5 × 400/620 × 2)/2
        var tooWide = MathRunPlan.Display(F(@"\sum x", block: true), Body, Fixed(2000, 8, 4), first: false);
        Assert.NotEqual(MathRunKind.Picture, tooWide.Kind);
    }

    [Fact]
    public void ReadableLimitsAreSmallerAndShiftedAsTheMacsMathStyle()
    {
        var text = "∑" + MathText.LimitBelowOpen + "i=1" + MathText.LimitClose + MathText.LimitAboveOpen + "n" + MathText.LimitClose + " i";
        var pieces = MathRunPlan.Pieces(text, 14);
        Assert.Equal(["∑", "i=1", "n", " i"], pieces.Select(p => p.Text));
        Assert.Equal([0, -1, 1, 0], pieces.Select(p => p.Limit));
        Assert.Equal(14 * 0.72, pieces[1].Size, 6);
        Assert.Equal(-3, pieces[1].BaselineShift);   // (14 × −0.22).rounded()
        Assert.Equal(6, pieces[2].BaselineShift);    // (14 × 0.40).rounded()
    }

    [Fact]
    public void CopyGivesEachWholeFormulaItsSourceAndDropsTheDrawingsMarks()
    {
        var pieces = new List<CopyPiece>
        {
            new(0, 13, "The ratio is "),
            new(13, 1, "\uFFFC", @"\frac{a}{b}"),
            new(14, 4, " of\u2028"),
            new(18, 1, "\n"),
            new(19, 1, "\uFFFC", @"\sum_i i"),
            new(20, 6, "\u202Fx\u202F", "x", Code: true),
        };
        Assert.Equal("The ratio is \\frac{a}{b} of\n\n\\sum_i ix", MathCopy.Plain(pieces, 0, 26));
        Assert.Equal("ratio is ", MathCopy.Plain(pieces, 4, 13));
        Assert.Equal("", MathCopy.Plain(pieces, 13, 13));
        Assert.True(MathCopy.Matters(pieces, 10, 14));
        Assert.False(MathCopy.Matters(pieces, 0, 13));
    }

    [Fact]
    public void PicturesAreKeptPerColourAndTheCacheEmptiesPastFour()
    {
        var cache = new MathInkCache<string>();
        var draws = 0;
        string Draw() { draws++; return "p" + draws; }
        Assert.Equal("p1", cache.Get(MathInkCache<string>.Key(0, 0, 0, 255), Draw));
        Assert.Equal("p1", cache.Get(MathInkCache<string>.Key(0, 0, 0, 255), Draw));
        Assert.Equal(1, draws);
        for (byte i = 1; i <= 4; i++) cache.Get(MathInkCache<string>.Key(i, 0, 0, 255), Draw);
        Assert.Equal(5, cache.Count);
        cache.Get(MathInkCache<string>.Key(9, 9, 9, 255), Draw);   // > 4 kept: emptied, then this one
        Assert.Equal(1, cache.Count);
        Assert.NotEqual(MathInkCache<string>.Key(1, 2, 3, 255, 1), MathInkCache<string>.Key(1, 2, 3, 255, 1.5));
        Assert.Null(cache.Get("none", () => null));
        Assert.Equal(1, cache.Count);
    }

    // ------------------------------------------------------------------ the chat-math walk, headless

    [Fact]
    public void TheWalksReplySetsAsTheWalkExpectsWithTheRealTypesetter()
    {
        var extracted = MathText.Extract(MathWalkProof.Reply);
        Assert.Equal(6, extracted.Formulas.Count);
        Assert.Equal([MathWalkProof.InlineFraction, MathWalkProof.Aligned, MathWalkProof.Cases, MathWalkProof.Pmatrix, MathWalkProof.Sum, MathWalkProof.Unset],
            extracted.Formulas.Select(f => f.Source.Trim()));
        var drawn = new List<MathWalkProof.Drawn>();
        foreach (var f in extracted.Formulas)
        {
            var run = f.Block ? MathRunPlan.Display(f, Body, MathEngine.Measurer, first: false)
                : MathRunPlan.Inline(f, Body, Line, MathEngine.Measurer);
            var scale = 1.5;
            if (run.Kind == MathRunKind.Picture)
            {
                var picture = MathEngine.Draw(run.Fit!, new MathColor(20, 20, 20), scale)!;
                var ink = 0;
                for (var i = 3; i < picture.Bgra.Length; i += 4) if (picture.Bgra[i] != 0) ink++;
                drawn.Add(new(run.Kind, run.Block, f.Source.Trim(), run.Width, run.Height, picture.Width, picture.Height, scale, ink, true));
            }
            else drawn.Add(new(run.Kind, run.Block, f.Source.Trim(), 0, 0, 0, 0, scale, 0, true));
        }
        Assert.Null(MathWalkProof.Formulas(drawn));
        // The inline fraction hangs below the baseline (a denominator) and its line grows; the unset one is text.
        var inline = MathRunPlan.Inline(extracted.Formulas[0], Body, Line, MathEngine.Measurer);
        Assert.True(inline.BaselineDrop > 1);
        Assert.NotEqual(MathRunKind.Picture, MathRunPlan.Display(extracted.Formulas[5], Body, MathEngine.Measurer, first: false).Kind);
    }

    [Fact]
    public void TheWalksChecksNameWhatIsWrong()
    {
        var good = new MathWalkProof.Drawn(MathRunKind.Picture, false, MathWalkProof.InlineFraction, 10, 20, 15, 30, 1.5, 9, true);
        List<MathWalkProof.Drawn> All(MathWalkProof.Drawn inline) =>
            [inline, .. MathWalkProof.Blocks.Select(b => good with { Source = b, Block = true }),
             new(MathRunKind.Source, true, MathWalkProof.Unset, 0, 0, 0, 0, 1.5, 0, true)];
        Assert.Null(MathWalkProof.Formulas(All(good)));
        Assert.Equal("the inline fraction is drawn as Readable, not an inline picture", MathWalkProof.Formulas(All(good with { Kind = MathRunKind.Readable })));
        Assert.Equal(@"\frac{a}{b} is 14×30 pixels, not 15×30 at scale 1.5", MathWalkProof.Formulas(All(good with { PixelWidth = 14 })));
        Assert.Equal(@"\frac{a}{b} is drawn blank", MathWalkProof.Formulas(All(good with { InkPixels = 0 })));
        Assert.Equal(@"\frac{a}{b}'s ink isn't the text's colour", MathWalkProof.Formulas(All(good with { InkIsTextColour = false })));
        var unsetPicture = All(good);
        unsetPicture[^1] = unsetPicture[^1] with { Kind = MathRunKind.Picture, Width = 1, Height = 1, PixelWidth = 2, PixelHeight = 2, InkPixels = 1 };
        Assert.Equal("the formula the typesetter can't set is drawn as a picture", MathWalkProof.Formulas(unsetPicture));
        Assert.Null(MathWalkProof.Copied(string.Join(" ", MathWalkProof.InlineFraction, MathWalkProof.Aligned, MathWalkProof.Cases, MathWalkProof.Pmatrix, MathWalkProof.Sum)));
        Assert.Equal(@"the copy lacks \frac{a}{b}", MathWalkProof.Copied("The ratio is \uFFFC"));
    }

    // [WIN-THEME-APP-RESOURCES] CI run 45095225249, shot 194: Appearance › Dark on a light Windows kept a light ground
    // and black formulas under white words.
    [Fact]
    public void ThemeKeysAreReadInTheModeOnShowAndTheShotGroundIsWinUIsBase()
    {
        Assert.Equal(["Dark", "Default"], Hermes.Core.Settings.ThemeKeys.Dictionaries(dark: true));
        Assert.Equal(["Light"], Hermes.Core.Settings.ThemeKeys.Dictionaries(dark: false));
        Assert.Equal(["HighContrast"], Hermes.Core.Settings.ThemeKeys.Dictionaries(dark: true, highContrast: true));
        Assert.Equal("#202020", Hermes.Core.Settings.ThemeKeys.ShotGround(true).HexString);
        Assert.Equal("#F3F3F3", Hermes.Core.Settings.ThemeKeys.ShotGround(false).HexString);
    }

    [Fact]
    public void TheThemedShotNeedsTheModesGroundAndFormulasInTheirWordsColour()
    {
        var R = Hermes.Core.Settings.Rgba.Hex;
        var white = R(0xFFFFFF);
        var nearBlack = Hermes.Core.Settings.Rgba.Black.Alpha(228 / 255.0);   // WinUI Light's TextFillColorPrimary
        var dark = Hermes.Core.Settings.ThemeKeys.ShotGround(true);
        var light = Hermes.Core.Settings.ThemeKeys.ShotGround(false);
        Assert.Null(MathWalkProof.Theme(true, dark, [(MathWalkProof.InlineFraction, white, white)]));
        Assert.Null(MathWalkProof.Theme(false, light, [(MathWalkProof.Sum, nearBlack, nearBlack)]));
        // Shot 194: the light ground kept under Appearance › Dark.
        Assert.Equal("the ground is #F3F3F3, not #202020 in Dark", MathWalkProof.Theme(true, light, [(MathWalkProof.Sum, white, white)]));
        // Shot 194: black formulas under white words.
        Assert.Equal(@"\sum_{i=1}^{n} i = \frac{n(n+1)}{2}'s ink is #000000 at 0.89, not its words' #FFFFFF at 1.00",
            MathWalkProof.Theme(true, dark, [(MathWalkProof.Sum, nearBlack, white)]));
        // Ink equal to words that themselves don't read (both black on dark) still fails.
        Assert.Equal(@"\frac{a}{b}'s ink #000000 doesn't read on the dark ground #202020",
            MathWalkProof.Theme(true, dark, [(MathWalkProof.InlineFraction, nearBlack, nearBlack)]));
        Assert.Equal("no formula pictures to check", MathWalkProof.Theme(true, dark, []));
    }

    [Fact]
    public void CodeLooksBrushesUpInTheModeOnShowNotTheApplicationsTheme()
    {
        var app = Path.Combine(WindowsDir(), "src", "HermesHQ.Windows");
        var brushLookup = new System.Text.RegularExpressions.Regex(@"\((?:Microsoft\.UI\.Xaml\.Media\.)?(?:Solid(?:Color)?)?Brush\)Application\.Current\.Resources\[|\(T\)Application\.Current\.Resources\[|Resources\.TryGetValue\(""[A-Za-z]*Brush""");
        var offenders = Directory.EnumerateFiles(app, "*.cs", SearchOption.AllDirectories)
            .Where(f => !f.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}") && !f.EndsWith("ThemeBrushes.cs", StringComparison.Ordinal))
            .SelectMany(f => File.ReadAllLines(f).Select((line, i) => (f, i, line)))
            .Where(x => brushLookup.IsMatch(x.line) && !x.line.Contains("SystemHighContrast", StringComparison.Ordinal))
            .Select(x => $"{Path.GetRelativePath(app, x.f)}:{x.i + 1}")
            .ToList();
        Assert.Empty(offenders);
        var pictures = Read("src", "HermesHQ.Windows", "Controls", "MathPictures.cs");
        Assert.Contains("Of(image)?.Container is { } container && TextInk(container)", pictures);
        Assert.Contains("ThemeService.Changed += Repainted;", pictures);
        Assert.Contains("made = MathPictures.Inline(run);", Read("src", "HermesHQ.Windows", "Controls", "MarkdownRenderer.cs"));
        Assert.Contains("if (Automation.Enabled) Automation.PaintShotGround(Dark);", Read("src", "HermesHQ.Windows", "Features", "Settings", "ThemeService.cs"));
        var walk = Read("src", "HermesHQ.Windows", "Services", "ProofWalks.Math.cs");
        Assert.DoesNotContain("shown.Ink == MathPictures.InkOf(image)", walk);
        Assert.Contains("MathWalkProof.Theme(dark,", walk);
    }

    // ------------------------------------------------------------------ the wiring, read from source

    private static string WindowsDir()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "windows", "HermesHQ.sln"))) return Path.Combine(dir.FullName, "windows");
        throw new InvalidOperationException("repo root not found");
    }

    private static string Read(params string[] parts) => File.ReadAllText(Path.Combine([WindowsDir(), .. parts])).ReplaceLineEndings("\n");

    [Fact]
    public void TheAppReferencesTheTypesetterAndTheRendererDrawsThePlan()
    {
        Assert.Contains(@"<ProjectReference Include=""..\Hermes.Math\Hermes.Math.csproj"" />", Read("src", "HermesHQ.Windows", "HermesHQ.Windows.csproj"));
        var renderer = Read("src", "HermesHQ.Windows", "Controls", "MarkdownRenderer.cs");
        Assert.Contains("MathRunPlan.Inline(", renderer);
        Assert.Contains("MathRunPlan.Display(", renderer);
        Assert.Contains("prose.PreviewKeyDown += CopyFormulasAsSource;", renderer);
        Assert.Contains("MathCopy.Plain(", renderer);
        Assert.DoesNotContain("Text = formulas[i].Source, FontStyle", renderer);   // no longer the source in italics
        var pictures = Read("src", "HermesHQ.Windows", "Controls", "MathPictures.cs");
        Assert.Contains("RasterizationScale", pictures);
        Assert.Contains("ActualThemeChanged", pictures);
        Assert.Contains("MathEngine.Draw(", pictures);
        Assert.Contains("MathInkCache<", pictures);
    }

    [Fact]
    public void TheWalkIsRegisteredAskedForAndItsFixtureHoldsTheReply()
    {
        var walk = Read("src", "HermesHQ.Windows", "Services", "ProofWalks.Math.cs");
        Assert.Contains("Automation.NamedWalks[\"chat-math\"] = ChatMathAsync;", walk);
        Assert.Contains("shot(\"chat-math\")", walk);
        Assert.Contains("RegisterMathWalks();", Read("src", "HermesHQ.Windows", "Services", "ProofWalks.cs"));
        var yml = Read("ci", "windows.yml");
        Assert.Matches(@"tag = ""chat-math""; args = @\(""-X"",""utf8"",""windows/ci/fixtures/pages-fixture-gateway.py""[^\n]*""--chat-math""[^\n]*walks = @\(""chat-math""\)", yml);
        var fixture = Read("ci", "fixtures", "pages-fixture-gateway.py");
        Assert.Contains("parser.add_argument('--chat-math'", fixture);
        Assert.Contains($"add_session('{MathWalkProof.Session}', '{MathWalkProof.Bot}', '{MathWalkProof.Title}'", fixture);
        foreach (var source in new[] { MathWalkProof.InlineFraction, MathWalkProof.Aligned, MathWalkProof.Cases, MathWalkProof.Pmatrix, MathWalkProof.Sum, MathWalkProof.Unset })
            Assert.Contains(source.Replace("\\", "\\\\", StringComparison.Ordinal), fixture);   // as a Python string literal
    }

    [Fact]
    public void TheAboutLicencesNameEveryPartOfTheTypesetter()
    {
        var names = Hermes.Core.Settings.LicenseNotices.Load()!.Select(n => n.Name).ToList();
        foreach (var name in new[] { "CSharpMath (formulas)", "Latin Modern Math (font)", "SkiaSharp (formula drawing)" })
            Assert.Contains(name, names);
    }

    [Fact]
    public void TheWalksFailureNamesEveryElementHoldingTheUnsetFormulaAndItsPlan()
    {
        // [WIN-MATH-THEME-WALK] A card drawn but not read (plan null) reads differently from one that is gone.
        Assert.Equal(@"no element on show holds \stackrel{a}{b}", MathWalkProof.Unread([]));
        Assert.Equal(@"2 elements on show hold \stackrel{a}{b}: Border (plan null), TextBlock (plan null)",
            MathWalkProof.Unread([("Border", null), ("TextBlock", null)]));
        Assert.Equal(@"1 element on show holds \stackrel{a}{b}: Border (plan Source)",
            MathWalkProof.Unread([("Border", MathRunKind.Source)]));
    }
}
