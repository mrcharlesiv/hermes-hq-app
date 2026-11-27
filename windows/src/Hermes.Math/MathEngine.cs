using CSharpMath.Atom;
using CSharpMath.Rendering.BackEnd;
using CSharpMath.SkiaSharp;
using Hermes.Core.Transcripts;
using SkiaSharp;
using Typesetter = CSharpMath.Display.Typesetter;

namespace Hermes.Typeset;

// [WIN-MATH-ENGINE] The Mac's typesetter, headless (Vendor/SwiftMath/Sources/SwiftMath/HQMathLine.swift and the drawing
// in App/Chat/Render/MathTypeset.swift's MathAttachment.picture, at 93f984bb1). A formula is read (nil when the TeX
// can't be), set in Latin Modern Math at a size in display style (large operators, limits above and below) or text
// style, measured, and drawn into BGRA pixels in one colour with the Mac's pad of 1 all round. CSharpMath is iosMath's
// C# port as SwiftMath is its Swift one: the same parser, typesetter and font tables, so the same formulas set.

/// An ink colour, straight (not premultiplied) 8-bit channels.
public readonly record struct MathColor(byte R, byte G, byte B, byte A = 255);

/// A formula drawn: `Width` × `Height` pixels, premultiplied BGRA rows of `Stride` bytes (Windows'
/// `BitmapPixelFormat.Bgra8` with `BitmapAlphaMode.Premultiplied`), transparent where there is no ink. `Scale` is pixels
/// per point; the baseline is `BaselineY` pixels from the top.
public sealed record MathPicture(int Width, int Height, int Stride, byte[] Bgra, double Scale, double BaselineY)
{
    /// The picture as PNG bytes (for tests and diagnostics).
    public byte[] EncodePng()
    {
        using var bitmap = Bitmap();
        using var data = bitmap.Encode(SKEncodedImageFormat.Png, 100);
        return data.ToArray();
    }

    internal SKBitmap Bitmap()
    {
        var bitmap = new SKBitmap(new SKImageInfo(Width, Height, SKColorType.Bgra8888, SKAlphaType.Premul));
        System.Runtime.InteropServices.Marshal.Copy(Bgra, 0, bitmap.GetPixels(), Bgra.Length);
        return bitmap;
    }
}

public static class MathEngine
{
    /// CSharpMath sets a font size as pixels at 96 per inch (an em is 4/3 of it); SwiftMath sets it in points. A size
    /// in points is handed over three quarters as big, so a formula measures in points as the Mac's does.
    public const double PointScale = 0.75;

    /// Hermes.Core's measuring, done by the real typesetter: hand it to `MathTypeset.Fit`.
    public static readonly MathMeasure Measurer = Measure;

    // CSharpMath's fonts and glyph caches are shared statics; one formula is set at a time.
    private static readonly object Gate = new();

    /// What `latex` measures set at `size` points: nil when it can't be read (the Mac's `HQMathLine.init?`) or sets to
    /// nothing (`MathTypeset.line`'s guard: a width not above zero, or a measure that isn't a number).
    public static (double Width, double Ascent, double Descent)? Measure(string latex, double size, bool block)
    {
        lock (Gate)
        {
            if (Line(latex, size, block) is not { } line) return null;
            return (line.Width, line.Ascent, line.Descent);
        }
    }

    /// The formula fitted by `MathTypeset.Fit`, drawn as the Mac's `MathAttachment.picture`: its bounds (the ink plus
    /// `MathFit.Pad`, rounded up to whole points) at `scale` pixels per point, the baseline `Pad` in from the left and
    /// the descent plus `Pad` (rounded up) up from the bottom. Nil when it can no longer be set.
    public static MathPicture? Draw(MathFit fit, MathColor color, double scale = 1)
    {
        ArgumentNullException.ThrowIfNull(fit);
        if (!(scale > 0) || !double.IsFinite(scale)) throw new ArgumentOutOfRangeException(nameof(scale));
        var bounds = fit.Bounds;
        // The Mac draws at (pad, floor) in a context whose y grows upward from the bottom: from the top, that is the
        // height less the floor, the ascent plus the pad rounded up.
        var baseline = bounds.Height + bounds.Y;
        var width = Math.Max(1, (int)Math.Ceiling(bounds.Width * scale));
        var height = Math.Max(1, (int)Math.Ceiling(bounds.Height * scale));
        lock (Gate)
        {
            if (Line(fit.Latex, fit.Size, fit.Block) is not { } line) return null;
            var info = new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Premul);
            using var bitmap = new SKBitmap(info);
            using (var canvas = new SKCanvas(bitmap))
            {
                canvas.Clear(SKColors.Transparent);
                canvas.Scale((float)scale);
                var painter = new MathPainter { TextColor = new SKColor(color.R, color.G, color.B, color.A), AntiAlias = true };
                MathPainter.DrawDisplay(painter, line.Display, canvas, new System.Drawing.PointF((float)(MathFit.Pad + line.Overhang), (float)baseline));
                canvas.Flush();
            }
            var bytes = new byte[bitmap.RowBytes * height];
            System.Runtime.InteropServices.Marshal.Copy(bitmap.GetPixels(), bytes, 0, bytes.Length);
            return new MathPicture(width, height, bitmap.RowBytes, bytes, scale, baseline * scale);
        }
    }

    /// Fits and draws in one go: `MathTypeset.Fit` with this engine's measuring, then `Draw`.
    public static MathPicture? Draw(string source, bool block, double basePointSize, MathColor color, double scale = 1,
        double? maxHeight = null, double? maxWidth = null) =>
        MathTypeset.Fit(source, block, basePointSize, Measurer, maxHeight, maxWidth) is { } fit ? Draw(fit, color, scale) : null;

    /// A line set: its width runs from the left-most part (`Overhang` before its origin, never negative) to the
    /// right-most.
    private sealed record Set(CSharpMath.Display.Displays.ListDisplay<Fonts, Glyph> Display, double Width, double Ascent, double Descent, double Overhang);

    // How far a line's parts reach, left and right of its origin. CSharpMath's table cells leave out the space a
    // cell's first relation is set after (aligned's "&= b", a case's "x ≥ 0"), so a table's width falls short of its
    // ink by up to a thick space; and an accent over a first letter (\hat{y}) starts left of the line. The parts
    // don't. A list's parts are placed from its own position; every other display places its parts in its parent's.
    private static (double Left, double Right) Reach(CSharpMath.Display.IDisplay<Fonts, Glyph>? display, double origin)
    {
        if (display == null) return (double.PositiveInfinity, double.NegativeInfinity);
        var left = origin + display.Position.X;
        var right = left + display.Width;
        IEnumerable<(CSharpMath.Display.IDisplay<Fonts, Glyph>? Part, double Origin)> parts = display switch
        {
            CSharpMath.Display.Displays.ListDisplay<Fonts, Glyph> list =>
                list.Displays.Select(p => ((CSharpMath.Display.IDisplay<Fonts, Glyph>?)p, origin + display.Position.X)),
            CSharpMath.Display.Displays.InnerDisplay<Fonts, Glyph> inner => [(inner.Inner, origin), (inner.Left, origin), (inner.Right, origin)],
            CSharpMath.Display.Displays.FractionDisplay<Fonts, Glyph> fraction => [(fraction.Numerator, origin), (fraction.Denominator, origin)],
            CSharpMath.Display.Displays.RadicalDisplay<Fonts, Glyph> radical => [(radical.Radicand, origin), (radical.Degree, origin)],
            CSharpMath.Display.Displays.LargeOpLimitsDisplay<Fonts, Glyph> op =>
                [(op.NucleusDisplay, origin), (op.UpperLimit, origin), (op.LowerLimit, origin)],
            CSharpMath.Display.Displays.AccentDisplay<Fonts, Glyph> accent => [(accent.Accentee, origin), (accent.Accent, origin)],
            CSharpMath.Display.Displays.OverOrUnderlineDisplay<Fonts, Glyph> line => [(line.Inner, origin)],
            _ => [],
        };
        foreach (var (part, at) in parts)
        {
            var reach = Reach(part, at);
            left = Math.Min(left, reach.Left);
            right = Math.Max(right, reach.Right);
        }
        return (left, right);
    }

    // The Mac's HQMathLine: read the TeX (any error is nil), set it in Latin Modern at the size in display or text
    // style. A formula the typesetter can't lay out (it throws) can't be set either.
    private static Set? Line(string latex, double size, bool block)
    {
        if (!(size > 0) || !double.IsFinite(size)) return null;
        try
        {
            var (list, error) = LaTeXParser.MathListFromLaTeX(InCSharpMathWords(latex));
            if (error != null || list == null) return null;
            var style = block ? LineStyle.Display : LineStyle.Text;
            AsSwiftMath(list, style);
            var fonts = new Fonts(Fonts.GlobalTypefaces, (float)(size * PointScale));
            var line = Typesetter.CreateLine(list, fonts, TypesettingContext.Instance, style);
            if (!(line.Width > 0) || !float.IsFinite(line.Width) || !float.IsFinite(line.Ascent) || !float.IsFinite(line.Descent))
                return null;
            var (left, right) = Reach(line, 0);
            var overhang = Math.Max(0, -left);
            return new Set(line, overhang + Math.Max(line.Width, right), line.Ascent, line.Descent, overhang);
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            return null;
        }
    }

    /// Commands SwiftMath reads that CSharpMath 0.5.1 has no name for, written as CSharpMath can set them with
    /// SwiftMath's meaning (MTMathListBuilder.swift / MTMathAtomFactory.swift at 93f984bb1):
    /// `\boldsymbol` is bold italic, CSharpMath's `\bm`; `\pmod{n}` is "(mod n)" with 6mu after "mod" (no space before,
    /// as SwiftMath); `\substack{a \\ b}` stacks its rows (one row is just itself). Anything else is left as written.
    internal static string InCSharpMathWords(string latex)
    {
        if (!latex.Contains('\\', StringComparison.Ordinal)) return latex;
        var out_ = new System.Text.StringBuilder(latex.Length + 16);
        var i = 0;
        while (i < latex.Length)
        {
            if (latex[i] == '\\' && Command(latex, i) is { } name)
            {
                var after = i + 1 + name.Length;
                switch (name)
                {
                    case "boldsymbol":
                        out_.Append("\\bm");
                        i = after;
                        continue;
                    case "pmod" when Argument(latex, after) is { } mod:
                        out_.Append("\\left(\\operatorname{mod}\\,\\,{").Append(InCSharpMathWords(mod.Body)).Append("}\\right)");
                        i = mod.End;
                        continue;
                    case "substack" when Argument(latex, after) is { } stack:
                        var rows = stack.Body.Split("\\\\").Select(r => "{" + InCSharpMathWords(r.Trim()) + "}").ToList();
                        // \atop stacks two rows without a rule; more rows stack pairwise.
                        var stacked = rows[0];
                        foreach (var row in rows.Skip(1)) stacked = "{" + stacked + " \\atop " + row + "}";
                        out_.Append(stacked);
                        i = stack.End;
                        continue;
                }
                out_.Append('\\').Append(name);
                i = after;
                continue;
            }
            if (latex[i] == '\\' && i + 1 < latex.Length)
            {
                out_.Append(latex, i, 2);
                i += 2;
                continue;
            }
            out_.Append(latex[i]);
            i++;
        }
        return out_.ToString();
    }

    // A command's letters after the backslash at `at`, or nil for a control symbol (\\, \{, \,).
    private static string? Command(string latex, int at)
    {
        var end = at + 1;
        while (end < latex.Length && char.IsAsciiLetter(latex[end])) end++;
        return end > at + 1 ? latex[(at + 1)..end] : null;
    }

    // A braced argument after optional spaces: its body and the index past its closing brace; nil when unbalanced.
    private static (string Body, int End)? Argument(string latex, int at)
    {
        while (at < latex.Length && char.IsWhiteSpace(latex[at])) at++;
        if (at >= latex.Length || latex[at] != '{') return null;
        var depth = 0;
        for (var j = at; j < latex.Length; j++)
        {
            if (latex[j] == '\\') { j++; continue; }
            if (latex[j] == '{') depth++;
            else if (latex[j] == '}' && --depth == 0) return (latex[(at + 1)..j], j + 1);
        }
        return null;
    }

    // Where the Mac's SwiftMath leaves TeX (MTTypesetter.swift at 93f984bb1), CSharpMath is told to follow it:
    //  • `fractionStyle()` returns the style it is given: a fraction's parts are set as large as the words around it
    //    (TeX, and CSharpMath, set them a style smaller), so an inline ½ isn't drawn in script letters;
    //  • `makeLargeOp`, in text style, takes the operator's larger glyph and sets its limits above and below, as
    //    display style does (TeX puts the limits beside a small operator).
    // Each is a style change at the start of the list it applies to, the way `\displaystyle` is written in TeX.
    private static void AsSwiftMath(MathList list, LineStyle style)
    {
        for (var i = 0; i < list.Count; i++)
        {
            var atom = list[i];
            switch (atom)
            {
                case CSharpMath.Atom.Atoms.Style changed:
                    style = changed.LineStyle;
                    break;
                case CSharpMath.Atom.Atoms.Fraction fraction:
                    fraction.Numerator.Insert(0, new CSharpMath.Atom.Atoms.Style(style));
                    fraction.Denominator.Insert(0, new CSharpMath.Atom.Atoms.Style(style));
                    AsSwiftMath(fraction.Numerator, style);
                    AsSwiftMath(fraction.Denominator, style);
                    break;
                case CSharpMath.Atom.Atoms.LargeOperator when style == LineStyle.Text:
                    list.Insert(i, new CSharpMath.Atom.Atoms.Style(LineStyle.Display));
                    list.Insert(i + 2, new CSharpMath.Atom.Atoms.Style(LineStyle.Text));
                    i += 2;
                    break;
                case CSharpMath.Atom.Atoms.Radical radical:
                    AsSwiftMath(radical.Radicand, style);
                    if (radical.Degree != null) AsSwiftMath(radical.Degree, LineStyle.ScriptScript);
                    break;
                case CSharpMath.Atom.Atoms.Inner inner:
                    AsSwiftMath(inner.InnerList, style);
                    break;
                case CSharpMath.Atom.Atoms.Overline over:
                    AsSwiftMath(over.InnerList, style);
                    break;
                case CSharpMath.Atom.Atoms.Underline under:
                    AsSwiftMath(under.InnerList, style);
                    break;
                case CSharpMath.Atom.Atoms.Accent accent:
                    AsSwiftMath(accent.InnerList, style);
                    break;
                case CSharpMath.Atom.Atoms.Colored colored:
                    AsSwiftMath(colored.InnerList, style);
                    break;
                case CSharpMath.Atom.Atoms.ColorBox box:
                    AsSwiftMath(box.InnerList, style);
                    break;
                case CSharpMath.Atom.Atoms.Table table:
                    foreach (var row in table.Cells)
                        foreach (var cell in row)
                            AsSwiftMath(cell, style);
                    break;
            }
            // Scripts are a style smaller, as in TeX and SwiftMath alike.
            var script = style <= LineStyle.Text ? LineStyle.Script : LineStyle.ScriptScript;
            if (atom.Superscript.Count > 0) AsSwiftMath(atom.Superscript, script);
            if (atom.Subscript.Count > 0) AsSwiftMath(atom.Subscript, script);
        }
    }
}
