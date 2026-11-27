using Hermes.Core.Transcripts;

namespace Hermes.Core.Shell;

/// [WIN-MATH-UI] What the chat-math walk (HermesHQ.Windows/Services/ProofWalks.Math.cs) checks on the pages stand-in run
/// with `--chat-math` (pages-fixture-gateway.py's s-chat-math: a synthetic reply holding an inline fraction, an aligned
/// block, cases, a pmatrix, a sum with limits and one formula the Mac's typesetter can't set). Each check answers null
/// when right, otherwise the words of what is wrong.
public static class MathWalkProof
{
    public const string Walk = "chat-math";
    public const string Bot = "research";
    public const string Session = "s-chat-math";
    public const string Title = "The maths notes";

    /// The reply's formulas, as the fixture writes them (sources as MathText.Extract takes them out).
    public const string InlineFraction = @"\frac{a}{b}";
    public const string Aligned = @"\begin{aligned} (a+b)^2 &= a^2 + 2ab + b^2 \\ (a-b)^2 &= a^2 - 2ab + b^2 \end{aligned}";
    public const string Cases = @"f(x) = \begin{cases} x^2 & x \ge 0 \\ -x & x < 0 \end{cases}";
    public const string Pmatrix = @"A = \begin{pmatrix} a & b \\ c & d \end{pmatrix}";
    public const string Sum = @"\sum_{i=1}^{n} i = \frac{n(n+1)}{2}";
    /// SwiftMath (and so CSharpMath here) returns nil for `\stackrel`: it falls back to readable text or its source.
    public const string Unset = @"\stackrel{a}{b}";

    /// The assistant's reply in the fixture (also written out in pages-fixture-gateway.py, checked by a test).
    public static readonly string Reply =
        "The ratio is \\( " + InlineFraction + " \\) of the whole, and the squares open up as\n\n"
        + "$$\n" + Aligned + "\n$$\n\n"
        + "A piecewise function:\n\n$$\n" + Cases + "\n$$\n\n"
        + "A matrix:\n\n$$\n" + Pmatrix + "\n$$\n\n"
        + "And the sum:\n\n$$\n" + Sum + "\n$$\n\n"
        + "One the typesetter can't set:\n\n$$\n" + Unset + "\n$$";

    /// The block formulas, top to bottom, that must be pictures.
    public static readonly IReadOnlyList<string> Blocks = [Aligned, Cases, Pmatrix, Sum];

    /// One formula as the chat drew it: its plan's kind, block or inline, its source, the picture's box in DIPs and in
    /// pixels at the window's scale, and the ink: how many pixels have any, and whether they are the text's colour.
    public sealed record Drawn(MathRunKind Kind, bool Block, string Source, double Width, double Height,
        int PixelWidth, int PixelHeight, double Scale, int InkPixels, bool InkIsTextColour);

    /// The reply's formulas: the inline fraction a picture on the words' line, the four blocks pictures each a
    /// centred block of its own, every picture drawn at the window's scale with ink in the text's colour, and the one
    /// the typesetter can't set drawn as text (readable or its source), never a picture.
    public static string? Formulas(IReadOnlyList<Drawn> drawn)
    {
        var inline = drawn.FirstOrDefault(d => d.Source == InlineFraction);
        if (inline == null) return "the inline fraction isn't drawn";
        if (inline.Kind != MathRunKind.Picture || inline.Block) return $"the inline fraction is drawn as {inline.Kind}{(inline.Block ? " block" : "")}, not an inline picture";
        foreach (var source in Blocks)
        {
            var d = drawn.FirstOrDefault(x => x.Source == source);
            if (d == null) return $"{source} isn't drawn";
            if (d.Kind != MathRunKind.Picture || !d.Block) return $"{source} is drawn as {d.Kind}, not a block picture";
        }
        foreach (var d in drawn.Where(d => d.Kind == MathRunKind.Picture))
        {
            if (!(d.Scale > 0)) return $"{d.Source} was drawn at scale {d.Scale}";
            var (w, h) = ((int)Math.Ceiling(d.Width * d.Scale), (int)Math.Ceiling(d.Height * d.Scale));
            if (d.PixelWidth != Math.Max(1, w) || d.PixelHeight != Math.Max(1, h))
                return $"{d.Source} is {d.PixelWidth}×{d.PixelHeight} pixels, not {w}×{h} at scale {d.Scale}";
            if (d.InkPixels == 0) return $"{d.Source} is drawn blank";
            if (!d.InkIsTextColour) return $"{d.Source}'s ink isn't the text's colour";
        }
        var unset = drawn.FirstOrDefault(d => d.Source == Unset);
        if (unset == null) return "the formula the typesetter can't set isn't drawn at all";
        if (unset.Kind == MathRunKind.Picture) return "the formula the typesetter can't set is drawn as a picture";
        return null;
    }

    /// [WIN-MATH-THEME-WALK] On a failure, every element on show whose words hold the formula the typesetter can't
    /// set (`Element`: its kind, e.g. Border or TextBlock) and the plan it carries (null: none), so the log tells a
    /// card that is gone from one drawn but not read (CI run 45150564097's shot showed the card the walk never found).
    public static string Unread(IReadOnlyList<(string Element, MathRunKind? Plan)> holders)
    {
        if (holders.Count == 0) return $"no element on show holds {Unset}";
        return (holders.Count == 1 ? "1 element on show holds " : $"{holders.Count} elements on show hold ") + Unset + ": "
            + string.Join(", ", holders.Select(h => $"{h.Element} (plan {(h.Plan is { } k ? k.ToString() : "null")})"));
    }

    /// [WIN-THEME-APP-RESOURCES] The chat in the other theme, as the shot shows it: the window's ground (what the shot
    /// is drawn on) is the ground of the mode on show, and every picture's ink is the colour its paragraph's words are
    /// drawn in and reads on that ground. CI run 45095225249 (shot 194) set Appearance › Dark on a light Windows and
    /// kept a light ground and black formulas under white words.
    public static string? Theme(bool dark, Hermes.Core.Settings.Rgba ground, IReadOnlyList<(string Source, Hermes.Core.Settings.Rgba Ink, Hermes.Core.Settings.Rgba Text)> pictures)
    {
        var want = Hermes.Core.Settings.ThemeKeys.ShotGround(dark);
        if (!ground.Near(want, 1.5 / 255)) return $"the ground is {ground.HexString}, not {want.HexString} in {(dark ? "Dark" : "Light")}";
        if (pictures.Count == 0) return "no formula pictures to check";
        foreach (var (source, ink, text) in pictures)
        {
            if (!ink.Near(text, 1.5 / 255)) return $"{source}'s ink is {ink.HexString} at {ink.A:0.00}, not its words' {text.HexString} at {text.A:0.00}";
            var drawn = ink.Over(ground);
            if (drawn.Contrast(ground) < 3) return $"{source}'s ink {ink.HexString} doesn't read on the {(dark ? "dark" : "light")} ground {ground.HexString}";
        }
        return null;
    }

    /// Select All in the reply, copied: every formula's TeX source, not its drawing.
    public static string? Copied(string copied)
    {
        foreach (var source in new[] { InlineFraction, Aligned, Cases, Pmatrix, Sum })
            if (!copied.Contains(source, StringComparison.Ordinal)) return $"the copy lacks {source}";
        if (copied.Contains('\uFFFC')) return "the copy holds the picture's stand-in character";
        return null;
    }
}
