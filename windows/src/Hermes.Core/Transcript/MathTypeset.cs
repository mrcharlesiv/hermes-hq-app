using System.Text.RegularExpressions;

namespace Hermes.Core.Transcripts;

// Port of App/Chat/Render/MathTypeset.swift (docs/spec/3x-transcript.md §3.5), the rules only: which formulas need
// typesetting, the TeX handed to the typesetter, and how big a formula is set to fit its line or its bubble. The Mac
// sets a formula with SwiftMath (Vendor/SwiftMath, Latin Modern Math); Windows sets it with CSharpMath in the same font
// (Hermes.Math's MathEngine, which keeps the packages out of Hermes.Core), so the measuring is injected (`Measure`) and
// nothing here draws. What can't be set falls back to MathText's readable text, and that
// to the source, as before.

/// What a formula measures set at a size, in points: nil when the typesetter can't read it.
public delegate (double Width, double Ascent, double Descent)? MathMeasure(string latex, double size, bool block);

/// A formula's box on its line: its baseline on the line's, so `Y` is the descent hanging below it (negative).
public readonly record struct MathBounds(double X, double Y, double Width, double Height);

/// A formula set to fit: the TeX handed to the typesetter, the size it is set at and what it measures there.
public sealed record MathFit(string Latex, bool Block, double Size, double Width, double Ascent, double Descent)
{
    /// Room around the ink, so an italic's overhang isn't cut (the Mac's `MathAttachment.pad`).
    public const double Pad = 1;

    /// The attachment's bounds (the Mac's `MathAttachment.init`).
    public MathBounds Bounds => MathTypeset.Bounds(Width, Ascent, Descent);
}

public static class MathTypeset
{
    /// Latin Modern's letters are smaller than the UI font's at the same size: a formula is set this much larger than
    /// the words around it, so its x sits level with theirs.
    public const double SizeRatio = 1.12;

    /// A formula inside a sentence may stand this much taller than the words' line before it is set smaller.
    public const double InlineHeightRatio = 2.4;

    /// The smallest a formula is set to fit (a line's height, a bubble's width); one that needs less is left to the
    /// fallbacks (a display formula's source card scrolls sideways).
    public const double Smallest = 0.5;

    /// The widest a display formula is set: a Mac window's narrowest chat column (the Mac's `blockWidth` on Mac
    /// Catalyst; the iPhone's is 300, a phone bubble's words).
    public const double BlockWidth = 520;

    /// TeX that only typesetting shows as written: stacked, rooted, with limits, or laid out in rows. An inline formula
    /// without any (E = mc², x₁ + x₂, α ≤ β) stays the readable text it was: words that wrap, select and are found with
    /// the sentence around them.
    public static readonly IReadOnlyList<string> Structures =
    [
        "\\frac", "\\dfrac", "\\tfrac", "\\sqrt", "\\sum", "\\prod", "\\int", "\\oint", "\\lim", "\\binom",
        "\\begin", "\\over", "\\under", "\\hat", "\\vec", "\\bar", "\\tilde", "\\dot", "\\mathbb",
        "\\mathcal", "\\mathfrak", "\\left", "\\big", "\\Big", "\\substack", "\\stackrel", "\\boldsymbol", "\\bm",
    ];

    // A script of more than one character, or a script on a script, has no Unicode small letters to stand in.
    private static readonly Regex LongScript = new(@"[\^_]\{[^{}]{2,}\}|[\^_]\{[^{}]*[\^_]", RegexOptions.CultureInvariant);

    public static bool NeedsTypesetting(string source)
    {
        foreach (var s in Structures)
            if (source.Contains(s, StringComparison.Ordinal)) return true;
        return LongScript.IsMatch(source);
    }

    private static readonly string[] Unnumbered = ["equation*", "equation", "displaymath", "math"];

    private static readonly (string From, string To)[] Environments =
    [
        ("align*", "aligned"), ("align", "aligned"), ("gather*", "gather"), ("gathered", "gather"),
        ("multline*", "gather"), ("multline", "gather"), ("eqnarray*", "eqnarray"),
        ("dcases", "cases"), ("pmatrix*", "pmatrix"), ("bmatrix*", "bmatrix"), ("matrix*", "matrix"),
    ];

    private static readonly Regex ArrayBegin = new(@"\\begin\{array\}\s*\{[^{}]*\}", RegexOptions.CultureInvariant);

    private static readonly string[] Dropped = ["\\boxed", "\\underbrace", "\\overbrace", "\\displaystyle", "\\textstyle"];

    private static readonly Regex[] Unshown =
    [
        new(@"\\label\{[^{}]*\}", RegexOptions.CultureInvariant),
        new(@"\\tag\*?\{[^{}]*\}", RegexOptions.CultureInvariant),
        new(@"\\(nonumber|notag)\b", RegexOptions.CultureInvariant),
    ];

    private static readonly (string From, string To)[] Commands =
    [
        ("\\dfrac", "\\frac"), ("\\tfrac", "\\frac"), ("\\dbinom", "\\binom"), ("\\tbinom", "\\binom"),
        ("\\lVert", "\\|"), ("\\rVert", "\\|"), ("\\lvert", "|"), ("\\rvert", "|"),
        ("\\mathds", "\\mathbb"), ("\\bigl", ""), ("\\bigr", ""), ("\\Bigl", ""), ("\\Bigr", ""),
        ("\\biggl", ""), ("\\biggr", ""), ("\\Biggl", ""), ("\\Biggr", ""),
    ];

    /// TeX the chat models write that SwiftMath has no name for, in its own words: the numbered environments are their
    /// unnumbered bodies, and a number or a label has nowhere to show. Every replacement in the Mac's order.
    public static string Prepared(string source)
    {
        var out_ = source.Trim();
        foreach (var name in Unnumbered)
            out_ = out_.Replace("\\begin{" + name + "}", "", StringComparison.Ordinal)
                .Replace("\\end{" + name + "}", "", StringComparison.Ordinal);
        foreach (var (from, to) in Environments)
            out_ = out_.Replace("\\begin{" + from + "}", "\\begin{" + to + "}", StringComparison.Ordinal)
                .Replace("\\end{" + from + "}", "\\end{" + to + "}", StringComparison.Ordinal);
        // An array is a matrix without its column letters; a box and a brace have no drawing here, their content does.
        out_ = ArrayBegin.Replace(out_, _ => "\\begin{matrix}")
            .Replace("\\end{array}", "\\end{matrix}", StringComparison.Ordinal);
        foreach (var name in Dropped)
            out_ = out_.Replace(name, "", StringComparison.Ordinal);
        foreach (var pattern in Unshown)
            out_ = pattern.Replace(out_, "");
        foreach (var (from, to) in Commands)
            out_ = out_.Replace(from, to, StringComparison.Ordinal);
        return out_.Trim();
    }

    /// The size a formula is first set at beside words of `basePointSize`: 1.12 times, to the nearest half point
    /// (Swift's `.rounded()`, halves away from zero).
    public static double BaseSize(double basePointSize) =>
        Math.Round(basePointSize * SizeRatio * 2, MidpointRounding.AwayFromZero) / 2;

    /// The formula fitted at the words' size: set smaller when it is taller than `maxHeight` or wider than `maxWidth`,
    /// nil when it can't be set or would have to be set smaller than `Smallest` (the Mac's `MathTypeset.attachment`).
    public static MathFit? Fit(string source, bool block, double basePointSize, MathMeasure measure,
        double? maxHeight = null, double? maxWidth = null)
    {
        if (source.Length > MathText.MaxLength) return null;
        var latex = Prepared(source);
        if (latex.Length == 0) return null;
        var size = BaseSize(basePointSize);
        if (Measured(measure, latex, size, block) is not { } fit) return null;
        var scale = 1.0;
        if (maxHeight is { } h && fit.Ascent + fit.Descent > h) scale = Math.Min(scale, h / (fit.Ascent + fit.Descent));
        if (maxWidth is { } w && fit.Width > w) scale = Math.Min(scale, w / fit.Width);
        if (scale < 1)
        {
            if (scale < Smallest) return null;
            size = Math.Floor(size * scale * 2) / 2;
            if (Measured(measure, latex, size, block) is not { } smaller) return null;
            fit = smaller;
        }
        return new MathFit(latex, block, size, fit.Width, fit.Ascent, fit.Descent);
    }

    /// What the typesetter measures, nil also when it is empty or not a number (the Mac's `MathTypeset.line` guard).
    private static (double Width, double Ascent, double Descent)? Measured(MathMeasure measure, string latex, double size, bool block)
    {
        if (measure(latex, size, block) is not { } m) return null;
        if (!(m.Width > 0) || !double.IsFinite(m.Width) || !double.IsFinite(m.Ascent) || !double.IsFinite(m.Descent)) return null;
        return m;
    }

    /// A set formula's box: the ink plus `MathFit.Pad` all round, each side rounded up to whole points, its baseline on
    /// the line's (the descent hangs below it).
    public static MathBounds Bounds(double width, double ascent, double descent)
    {
        var below = Math.Ceiling(descent + MathFit.Pad);
        return new MathBounds(0, -below, Math.Ceiling(width + 2 * MathFit.Pad), Math.Ceiling(ascent + MathFit.Pad) + below);
    }
}
