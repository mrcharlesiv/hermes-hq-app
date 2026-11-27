using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

// Port of Tests/MathTypesetTests.swift (at 93f984bb1) for Hermes.Core/Transcript/MathTypeset.cs. The Mac's cases that
// set real formulas with SwiftMath run here over a fake measurer, so the rules are tested apart from any typesetter;
// each names the Mac case it mirrors. Typeset/MathEngineTests runs them again over the real one (Hermes.Math). The NeedsTypesetting/Prepared vectors are the Mac's own output: the Swift rules at 93f984bb1 run on
// macOS over these synthetic formulas (the Mac test's samples first, then edge cases for every replacement).

public class MathTypesetTests
{
    /// (source, NeedsTypesetting, Prepared) as the Mac's Swift computes them.
    public static readonly (string Source, bool Needs, string Prepared)[] Golden =
    [
        ("E = mc^2", false, "E = mc^2"),
        ("x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}", true, "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}"),
        ("\\lVert \\vec{v} \\rVert = \\sqrt{\\sum_{i=1}^{n} v_i^2}", true, "\\| \\vec{v} \\| = \\sqrt{\\sum_{i=1}^{n} v_i^2}"),
        ("\\vec{v} \\in \\mathbb{R}^n", true, "\\vec{v} \\in \\mathbb{R}^n"),
        ("\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2} \\qquad \\int_{0}^{\\infty} e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}", true, "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2} \\qquad \\int_{0}^{\\infty} e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}"),
        ("\\begin{aligned} (a+b)^2 &= (a+b)(a+b) \\\\ &= a^2 + 2ab + b^2 \\end{aligned}", true, "\\begin{aligned} (a+b)^2 &= (a+b)(a+b) \\\\ &= a^2 + 2ab + b^2 \\end{aligned}"),
        ("f(x) = \\begin{cases} x^2 & \\text{if } x \\ge 0 \\\\ -x & \\text{otherwise} \\end{cases}", true, "f(x) = \\begin{cases} x^2 & \\text{if } x \\ge 0 \\\\ -x & \\text{otherwise} \\end{cases}"),
        ("A = \\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", true, "A = \\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"),
        ("\\begin{bmatrix} 1 & 0 \\\\ 0 & 1 \\end{bmatrix} \\begin{vmatrix} a & b \\\\ c & d \\end{vmatrix} \\begin{Bmatrix} 1 \\\\ 2 \\end{Bmatrix}", true, "\\begin{bmatrix} 1 & 0 \\\\ 0 & 1 \\end{bmatrix} \\begin{vmatrix} a & b \\\\ c & d \\end{vmatrix} \\begin{Bmatrix} 1 \\\\ 2 \\end{Bmatrix}"),
        ("\\begin{align} \\nabla \\cdot \\mathbf{E} &= \\frac{\\rho}{\\varepsilon_0} \\\\ \\nabla \\times \\mathbf{B} &= \\mu_0 \\mathbf{J} \\end{align}", true, "\\begin{aligned} \\nabla \\cdot \\mathbf{E} &= \\frac{\\rho}{\\varepsilon_0} \\\\ \\nabla \\times \\mathbf{B} &= \\mu_0 \\mathbf{J} \\end{aligned}"),
        ("\\begin{align*} a &= b \\tag{1} \\\\ c &= d \\label{eq:x} \\end{align*}", true, "\\begin{aligned} a &= b  \\\\ c &= d  \\end{aligned}"),
        ("\\begin{equation} \\dfrac{\\partial u}{\\partial t} = \\alpha \\nabla^2 u \\end{equation}", true, "\\frac{\\partial u}{\\partial t} = \\alpha \\nabla^2 u"),
        ("\\lim_{x \\to 0} \\frac{\\sin x}{x} = 1", true, "\\lim_{x \\to 0} \\frac{\\sin x}{x} = 1"),
        ("\\left( \\frac{a}{b} \\right)^n \\cdot \\binom{n}{k}", true, "\\left( \\frac{a}{b} \\right)^n \\cdot \\binom{n}{k}"),
        ("\\mathcal{L} = \\operatorname{argmin}_\\theta \\mathbb{E}[\\ell(\\theta)]", true, "\\mathcal{L} = \\operatorname{argmin}_\\theta \\mathbb{E}[\\ell(\\theta)]"),
        ("\\hat{y} = \\sigma(\\mathbf{W}\\mathbf{x} + \\mathbf{b})", true, "\\hat{y} = \\sigma(\\mathbf{W}\\mathbf{x} + \\mathbf{b})"),
        ("P(A \\mid B) = \\frac{P(B \\mid A)\\,P(A)}{P(B)}", true, "P(A \\mid B) = \\frac{P(B \\mid A)\\,P(A)}{P(B)}"),
        ("\\overline{z} \\cdot \\underbrace{a + b}_{c} \\to \\infty", true, "\\overline{z} \\cdot {a + b}_{c} \\to \\infty"),
        ("\\begin{gather} a = b \\\\ c = d \\end{gather}", true, "\\begin{gather} a = b \\\\ c = d \\end{gather}"),
        ("\\boxed{x = 1} \\quad \\text{and} \\quad \\boldsymbol{\\beta} \\neq \\emptyset", true, "{x = 1} \\quad \\text{and} \\quad \\boldsymbol{\\beta} \\neq \\emptyset"),
        ("\\begin{array}{cc} a & b \\\\ c & d \\end{array}", true, "\\begin{matrix} a & b \\\\ c & d \\end{matrix}"),
        ("a \\equiv b \\pmod{n}, \\quad \\mathrm{d}x, \\quad x \\mapsto x^2, \\quad \\forall \\epsilon > 0\\ \\exists \\delta", false, "a \\equiv b \\pmod{n}, \\quad \\mathrm{d}x, \\quad x \\mapsto x^2, \\quad \\forall \\epsilon > 0\\ \\exists \\delta"),
        ("e^{i\\pi} + 1 = 0", true, "e^{i\\pi} + 1 = 0"),
        ("x_1 + x_2", false, "x_1 + x_2"),
        ("\\alpha \\le \\beta", false, "\\alpha \\le \\beta"),
        ("a^{b^c}", true, "a^{b^c}"),
        ("x_{ij}", true, "x_{ij}"),
        ("a^{x_1}", true, "a^{x_1}"),
        ("x^{2}", false, "x^{2}"),
        ("  \\begin{equation*} a \\nonumber \\end{equation*}  ", true, "a"),
        ("\\begin{multline*} a \\\\ b \\end{multline*}", true, "\\begin{gather} a \\\\ b \\end{gather}"),
        ("\\begin{gathered} a \\end{gathered}", true, "\\begin{gather} a \\end{gather}"),
        ("\\begin{eqnarray*} a &=& b \\end{eqnarray*}", true, "\\begin{eqnarray} a &=& b \\end{eqnarray}"),
        ("\\begin{dcases} a & b \\end{dcases}", true, "\\begin{cases} a & b \\end{cases}"),
        ("\\begin{pmatrix*} 1 \\end{pmatrix*}", true, "\\begin{pmatrix} 1 \\end{pmatrix}"),
        ("\\begin{bmatrix*} 1 \\end{bmatrix*}", true, "\\begin{bmatrix} 1 \\end{bmatrix}"),
        ("\\begin{matrix*} 1 \\end{matrix*}", true, "\\begin{matrix} 1 \\end{matrix}"),
        ("\\begin{array} \n {l|r} a & b \\end{array}", true, "\\begin{matrix} a & b \\end{matrix}"),
        ("\\tbinom{n}{k} + \\dbinom{n}{k} + \\tfrac{1}{2}", true, "\\binom{n}{k} + \\binom{n}{k} + \\frac{1}{2}"),
        ("\\lvert x \\rvert + \\mathds{1} + \\bigl( \\Bigr) \\biggl[ \\Biggr]", true, "| x | + \\mathbb{1} + ( ) [ ]"),
        ("a \\tag*{A} \\notag b \\nonumbers", false, "a   b \\nonumbers"),
        ("\\displaystyle \\overbrace{a}^{n} \\textstyle", true, "{a}^{n}"),
        ("\\begin{math} x \\end{math}", true, "x"),
        ("\\begin{displaymath} y \\end{displaymath}", true, "y"),
        ("\\begin{equation}\\label{e1}\\end{equation}", true, ""),
        ("\\boxed{}", false, "{}"),
        ("\\tilde{x}", true, "\\tilde{x}"),
        ("\\over", true, "\\over"),
        ("\\Bigg", true, "\\Bigg"),
        ("\\big", true, "\\big"),
        ("\\under", true, "\\under"),
        ("\\bm{x}", true, "\\bm{x}"),
        ("\\mathfrak{g}", true, "\\mathfrak{g}"),
        ("\\oint", true, "\\oint"),
        ("\\prod", true, "\\prod"),
        ("\\substack{a}", true, "\\substack{a}"),
        ("\\stackrel{a}{b}", true, "\\stackrel{a}{b}"),
        ("\\bar x", true, "\\bar x"),
        ("\\dot x", true, "\\dot x"),
        ("x^{ab}", true, "x^{ab}"),
        ("x^{a}_{b}", false, "x^{a}_{b}"),
        ("x^{\n}", false, "x^{\n}"),
    ];

    /// The Mac test's `samples`: (source, block).
    public static readonly (string Source, bool Block)[] Samples =
    [
        (@"E = mc^2", false),
        (@"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}", false),
        (@"\lVert \vec{v} \rVert = \sqrt{\sum_{i=1}^{n} v_i^2}", false),
        (@"\vec{v} \in \mathbb{R}^n", false),
        (@"\sum_{i=1}^{n} i = \frac{n(n+1)}{2} \qquad \int_{0}^{\infty} e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}", true),
        (@"\begin{aligned} (a+b)^2 &= (a+b)(a+b) \\ &= a^2 + 2ab + b^2 \end{aligned}", true),
        (@"f(x) = \begin{cases} x^2 & \text{if } x \ge 0 \\ -x & \text{otherwise} \end{cases}", true),
        (@"A = \begin{pmatrix} a & b \\ c & d \end{pmatrix}", true),
        (@"\begin{bmatrix} 1 & 0 \\ 0 & 1 \end{bmatrix} \begin{vmatrix} a & b \\ c & d \end{vmatrix} \begin{Bmatrix} 1 \\ 2 \end{Bmatrix}", true),
        (@"\begin{align} \nabla \cdot \mathbf{E} &= \frac{\rho}{\varepsilon_0} \\ \nabla \times \mathbf{B} &= \mu_0 \mathbf{J} \end{align}", true),
        (@"\begin{align*} a &= b \tag{1} \\ c &= d \label{eq:x} \end{align*}", true),
        (@"\begin{equation} \dfrac{\partial u}{\partial t} = \alpha \nabla^2 u \end{equation}", true),
        (@"\lim_{x \to 0} \frac{\sin x}{x} = 1", true),
        (@"\left( \frac{a}{b} \right)^n \cdot \binom{n}{k}", true),
        (@"\mathcal{L} = \operatorname{argmin}_\theta \mathbb{E}[\ell(\theta)]", false),
        (@"\hat{y} = \sigma(\mathbf{W}\mathbf{x} + \mathbf{b})", false),
        (@"P(A \mid B) = \frac{P(B \mid A)\,P(A)}{P(B)}", true),
        (@"\overline{z} \cdot \underbrace{a + b}_{c} \to \infty", true),
        (@"\begin{gather} a = b \\ c = d \end{gather}", true),
        (@"\boxed{x = 1} \quad \text{and} \quad \boldsymbol{\beta} \neq \emptyset", true),
        (@"\begin{array}{cc} a & b \\ c & d \end{array}", true),
        (@"a \equiv b \pmod{n}, \quad \mathrm{d}x, \quad x \mapsto x^2, \quad \forall \epsilon > 0\ \exists \delta", true),
    ];

    /// A stand-in for SwiftMath's metrics: proportional to the size, a fraction or a row stands taller, and it can't
    /// read a command it doesn't know (`\notacommand`) or a numbered environment `Prepared` should have renamed.
    public static (double Width, double Ascent, double Descent)? Fake(string latex, double size, bool block)
    {
        if (latex.Contains("\\notacommand", StringComparison.Ordinal)) return null;
        foreach (var raw in new[] { "{align}", "{align*}", "{equation}", "{array}", "\\tag", "\\label", "\\dfrac", "\\boxed" })
            if (latex.Contains(raw, StringComparison.Ordinal)) return null;
        int Count(string s) => (latex.Length - latex.Replace(s, "", StringComparison.Ordinal).Length) / s.Length;
        var tall = 1 + 1.2 * Count("\\frac") + 0.4 * Count("\\sqrt") + 0.5 * Count("\\\\") + 0.4 * Count("\\sum");
        return (0.45 * size * latex.Length, 0.8 * size * tall, 0.3 * size * tall);
    }

    /// The words' line at 17 points (a stand-in for the system font's line height there).
    private const double Base = 17;
    private const double LineHeight = 20.29;

    [Fact]
    public void TheMacConstants()
    {
        Assert.Equal(1.12, MathTypeset.SizeRatio);
        Assert.Equal(2.4, MathTypeset.InlineHeightRatio);
        Assert.Equal(0.5, MathTypeset.Smallest);
        Assert.Equal(520, MathTypeset.BlockWidth);
        Assert.Equal(1, MathFit.Pad);
        Assert.Equal(
            ["\\frac", "\\dfrac", "\\tfrac", "\\sqrt", "\\sum", "\\prod", "\\int", "\\oint", "\\lim", "\\binom",
             "\\begin", "\\over", "\\under", "\\hat", "\\vec", "\\bar", "\\tilde", "\\dot", "\\mathbb",
             "\\mathcal", "\\mathfrak", "\\left", "\\big", "\\Big", "\\substack", "\\stackrel", "\\boldsymbol", "\\bm"],
            MathTypeset.Structures);
    }

    [Fact]
    public void NeedsTypesettingAsTheMac()
    {
        foreach (var (source, needs, _) in Golden)
            Assert.True(needs == MathTypeset.NeedsTypesetting(source), source);
        // Inline formulas Unicode can show stay readable text.
        Assert.False(MathTypeset.NeedsTypesetting("E = mc^2"));
        Assert.False(MathTypeset.NeedsTypesetting("x_1 + x_2"));
        Assert.False(MathTypeset.NeedsTypesetting(@"\alpha \le \beta"));
        Assert.True(MathTypeset.NeedsTypesetting("x_{ij}"));
        Assert.True(MathTypeset.NeedsTypesetting("a^{x_1}"));
    }

    [Fact]
    public void PreparedAsTheMac()
    {
        foreach (var (source, _, prepared) in Golden)
            Assert.Equal(prepared, MathTypeset.Prepared(source));
    }

    /// Mirrors `theSamplesAreSet`: every sample is prepared into words the typesetter knows and set (here by the fake).
    [Fact]
    public void TheSamplesAreSet()
    {
        var failed = Samples.Where(s => MathTypeset.Fit(s.Source, s.Block, Base, Fake) == null).Select(s => s.Source).ToList();
        Assert.True(failed.Count == 0, "not set: " + string.Join("  ||  ", failed));
        // Without Prepared, the numbered environments, tags, labels, \dfrac, \boxed and arrays would not be read.
        Assert.Contains(Samples, s => Fake(s.Source.Trim(), 19, s.Block) == null);
    }

    /// Mirrors `whatCantBeSetFallsBack`.
    [Fact]
    public void WhatCantBeSetFallsBack()
    {
        Assert.Null(MathTypeset.Fit(@"\notacommand{x}", false, Base, Fake));
        var calls = 0;
        MathMeasure counting = (l, s, b) => { calls++; return Fake(l, s, b); };
        Assert.Null(MathTypeset.Fit("", false, Base, counting));
        Assert.Null(MathTypeset.Fit("  \n ", false, Base, counting));
        Assert.Null(MathTypeset.Fit(@"\begin{equation}\label{e1}\end{equation}", true, Base, counting));
        Assert.Equal(0, calls);
    }

    /// Mirrors `aBareEnvironmentIsAFormula` (MathText.Extract, ported earlier; here as the Mac test has it).
    [Fact]
    public void ABareEnvironmentIsAFormula()
    {
        var text = "So:\n\n\\begin{align}\na &= b \\\\\nc &= d\n\\end{align}\n\nDone.";
        var taken = MathText.Extract(text);
        Assert.Single(taken.Formulas);
        Assert.StartsWith("\\begin{align}", taken.Formulas[0].Source, StringComparison.Ordinal);
        Assert.True(taken.Formulas[0].OwnParagraph, "on its own lines: its own centred paragraph");
        Assert.EndsWith("\\end{align}", taken.Formulas[0].Written, StringComparison.Ordinal);
        Assert.Empty(MathText.Extract("```\n\\begin{align}\na\n\\end{align}\n```").Formulas);
        Assert.Empty(MathText.Extract("Streaming: \\begin{align} a &= b").Formulas);
    }

    /// Mirrors `anInlineFormulaFitsItsLine`.
    [Fact]
    public void AnInlineFormulaFitsItsLine()
    {
        var limit = Math.Round(LineHeight * MathTypeset.InlineHeightRatio, MidpointRounding.AwayFromZero);
        Assert.Equal(49, limit);
        var set = MathTypeset.Fit(@"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}", false, Base, Fake, maxHeight: limit);
        Assert.NotNull(set);
        Assert.True(set!.Size < 19, "the fake sets it taller than the line at 19: it is set smaller");
        Assert.True(set.Bounds.Height <= limit + 4);
        foreach (var source in new[] { @"\lVert \vec{v} \rVert = \sqrt{\sum_{i=1}^{n} v_i^2}", @"\vec{v} \in \mathbb{R}^n", @"e^{i\pi} + 1 = 0" })
        {
            var fit = MathTypeset.Fit(source, false, Base, Fake, maxHeight: limit, maxWidth: MathTypeset.BlockWidth);
            Assert.True(fit != null, source);
            Assert.True(fit!.Bounds.Height <= limit + 4, source);
        }
    }

    [Fact]
    public void TheFirstSizeIsTheWordsTimesOnePointOneTwoToTheHalfPoint()
    {
        Assert.Equal(19, MathTypeset.BaseSize(17));     // 19.04
        Assert.Equal(14.5, MathTypeset.BaseSize(13));   // 14.56
        Assert.Equal(17, MathTypeset.BaseSize(15));     // 16.8
        Assert.Equal(15.5, MathTypeset.BaseSize(14));   // 15.68
        Assert.Equal(14, MathTypeset.BaseSize(12.5));   // 14.0
        var sizes = new List<double>();
        var fit = MathTypeset.Fit("x_{ij}", false, 17, (l, s, b) => { sizes.Add(s); return (10, 8, 3); });
        Assert.Equal([19.0], sizes);
        Assert.Equal(new MathFit("x_{ij}", false, 19, 10, 8, 3), fit);
    }

    [Fact]
    public void SetSmallerAtTheFlooredHalfPointAndMeasuredAgain()
    {
        var calls = new List<(string L, double S, bool B)>();
        (double, double, double)? M(string l, double s, bool b) { calls.Add((l, s, b)); return (s * 10, s * 4, s); }
        // 19pt: 190 wide, 95 tall. Height 60 → 0.6316; width 150 → 0.789: the smaller wins, 19 × 0.6316 = 12 → 12.
        var fit = MathTypeset.Fit(@"\begin{equation} a \end{equation}", true, 17, M, maxHeight: 60, maxWidth: 150);
        Assert.Equal([("a", 19.0, true), ("a", 12.0, true)], calls);
        Assert.Equal(new MathFit("a", true, 12, 120, 48, 12), fit);
        // Width only: 19 × 100/190 = 10 → 10.
        calls.Clear();
        Assert.Equal(10, MathTypeset.Fit("a", false, 17, M, maxWidth: 100)!.Size);
        // 19 × 101/190 = 10.1 → floored to the half point, 10.
        calls.Clear();
        Assert.Equal(10, MathTypeset.Fit("a", false, 17, M, maxWidth: 101)!.Size);
        // 19 × 105/190 = 10.5 exactly, kept.
        Assert.Equal(10.5, MathTypeset.Fit("a", false, 17, M, maxWidth: 105)!.Size);
        // Fits: measured once, the first size kept.
        calls.Clear();
        Assert.Equal(19, MathTypeset.Fit("a", false, 17, M, maxHeight: 95, maxWidth: 190)!.Size);
        Assert.Single(calls);
    }

    [Fact]
    public void BelowTheSmallestItIsLeftToTheFallbacks()
    {
        (double, double, double)? M(string l, double s, bool b) => (s * 10, s * 4, s);
        // 95 tall at 19: half is 47.5 → 0.5, set at 9.5.
        Assert.Equal(9.5, MathTypeset.Fit("a", false, 17, M, maxHeight: 47.5)!.Size);
        Assert.Null(MathTypeset.Fit("a", false, 17, M, maxHeight: 47.4));
        Assert.Null(MathTypeset.Fit("a", false, 17, M, maxWidth: 94.9));
        // Measured smaller but unreadable at that size: nothing.
        Assert.Null(MathTypeset.Fit("a", false, 17, (l, s, b) => s < 19 ? null : (s * 10, s * 4, s), maxWidth: 150));
    }

    [Fact]
    public void AnUnreadableMeasureIsNothing()
    {
        Assert.Null(MathTypeset.Fit("a", false, 17, (_, _, _) => (0, 8, 3)));
        Assert.Null(MathTypeset.Fit("a", false, 17, (_, _, _) => (-1, 8, 3)));
        Assert.Null(MathTypeset.Fit("a", false, 17, (_, _, _) => (double.NaN, 8, 3)));
        Assert.Null(MathTypeset.Fit("a", false, 17, (_, _, _) => (double.PositiveInfinity, 8, 3)));
        Assert.Null(MathTypeset.Fit("a", false, 17, (_, _, _) => (10, double.NaN, 3)));
        Assert.Null(MathTypeset.Fit("a", false, 17, (_, _, _) => (10, 8, double.NegativeInfinity)));
    }

    [Fact]
    public void TooLongIsNeverMeasured()
    {
        var calls = 0;
        MathMeasure m = (_, _, _) => { calls++; return (10, 8, 3); };
        Assert.NotNull(MathTypeset.Fit(new string('x', MathText.MaxLength), false, 17, m));
        Assert.Equal(1, calls);
        Assert.Null(MathTypeset.Fit(new string('x', MathText.MaxLength + 1), false, 17, m));
        Assert.Equal(1, calls);
    }

    [Fact]
    public void TheBoundsPadOnePointAndRoundUp()
    {
        Assert.Equal(new MathBounds(0, -3, 12, 11), MathTypeset.Bounds(10, 7, 2));
        Assert.Equal(new MathBounds(0, -4, 13, 13), MathTypeset.Bounds(10.2, 7.1, 2.3));
        Assert.Equal(new MathBounds(0, -1, 3, 2), MathTypeset.Bounds(0.5, 0, 0));
        Assert.Equal(MathTypeset.Bounds(120, 48, 12), new MathFit("a", true, 12, 120, 48, 12).Bounds);
    }
}
