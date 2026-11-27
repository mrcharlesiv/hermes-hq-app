namespace Hermes.Core.Transcripts;

// [WIN-MATH-UI] What the chat's markdown renderer makes of each formula, decided headless (the Mac's
// App/Chat/Render/MarkdownRenderer.swift `inlineFormula` and `appendDisplayFormula`/`appendTypesetFormula`, with
// MathTypeset.swift's `attachment` and MathStyle.swift's readable drawing, at 93f984bb1). A formula is a picture when the
// typesetter can set it (MathTypeset.Fit), else its readable text (MathText.Readable), else its TeX source; every one of
// them copies as its source when selected whole (`.chatCopy`), unless it sits inside a link. HermesHQ.Windows draws the
// plan (Controls/MarkdownRenderer.cs, MathPictures.cs); nothing here touches WinUI.

/// How a formula is drawn.
public enum MathRunKind
{
    /// Typeset: a picture of `Fit` (inline on the words' baseline, or a centred block of its own).
    Picture,
    /// The readable text (`MathText.Readable`) in the math font, its big operators' limits smaller and shifted.
    Readable,
    /// The TeX source: inline in the code font (as written), a display formula as a code card.
    Source,
}

/// A piece of a readable formula: words, or a big operator's limit (`Limit` −1 below, +1 above) drawn at
/// `MathRunPlan.LimitScale` of the words' size and `BaselineShift` points up (negative: down).
public sealed record MathTextPiece(string Text, int Limit, double Size, double BaselineShift);

/// One formula's plan. `Width`/`Height` are the picture's box in points (DIPs), `BaselineDrop` how far it hangs below
/// the words' baseline; `GrowsLine` when its line must grow to hold it (the Mac's `tall`). `Copy` is what selecting it
/// whole copies (null inside a link, where the link's address is what a click does).
public sealed record MathRun(
    MathRunKind Kind, string Source, bool Block, MathFit? Fit, IReadOnlyList<MathTextPiece> Text,
    double Width, double Height, double BaselineDrop, bool GrowsLine, string? Copy, double TopGap, double BottomGap)
{
    /// The words drawn, as one string (the readable text joined, or the source as written).
    public string Drawn => string.Concat(Text.Select(t => t.Text));
}

public static class MathRunPlan
{
    /// Room above and below a display formula, on top of the paragraph gap (the Mac's `MathStyle.blockGap`).
    public const double BlockGap = 8;
    /// A big operator's limit in readable text: this fraction of the words' size (`MathStyle.limitScale`)…
    public const double LimitScale = 0.72;
    /// …moved down (below) or up (above) by this fraction of the words' size (`limitBelowOffset`/`limitAboveOffset`).
    public const double LimitBelowOffset = -0.22, LimitAboveOffset = 0.40;

    /// The tallest an inline formula may stand before it is set smaller: 2.4 lines, rounded (Swift's `.rounded()`).
    public static double InlineMaxHeight(double lineHeight) =>
        Math.Round(lineHeight * MathTypeset.InlineHeightRatio, MidpointRounding.AwayFromZero);

    /// A formula inside a sentence (the Mac's `inlineFormula`): typeset when it needs typesetting or has no readable
    /// text, fitted to 2.4 lines and `MathTypeset.BlockWidth`; else readable text, unbroken; else its source as written.
    public static MathRun Inline(TakenFormula formula, double basePointSize, double lineHeight, MathMeasure measure, bool inLink = false)
    {
        ArgumentNullException.ThrowIfNull(formula);
        var copy = inLink ? null : formula.Source;
        var readable = MathText.Readable(formula.Source, block: false);
        if ((MathTypeset.NeedsTypesetting(formula.Source) || readable == null)
            && MathTypeset.Fit(formula.Source, block: false, basePointSize, measure,
                maxHeight: InlineMaxHeight(lineHeight), maxWidth: MathTypeset.BlockWidth) is { } fit)
        {
            var b = fit.Bounds;
            return new MathRun(MathRunKind.Picture, formula.Source, false, fit, [new("\uFFFC", 0, basePointSize, 0)],
                b.Width, b.Height, -b.Y, GrowsLine: b.Height > lineHeight - 2, copy, 0, 0);
        }
        if (readable == null)
            return new MathRun(MathRunKind.Source, formula.Source, false, null, [new(formula.Written, 0, basePointSize, 0)],
                0, 0, 0, false, copy, 0, 0);
        // Every space is non-breaking and a word joiner sits between characters: the whole formula fits on its line
        // or moves down whole (2026-10-31 owner review on the Mac).
        var unbroken = readable.Replace('\n', '\u00A0').Replace(' ', '\u00A0');
        return new MathRun(MathRunKind.Readable, formula.Source, false, null, Pieces(Joined(unbroken), basePointSize),
            0, 0, 0, false, copy, 0, 0);
    }

    /// A display formula on its own lines (the Mac's `appendDisplayFormula`): typeset as a centred block fitted to
    /// `MathTypeset.BlockWidth` (or a narrower column when given); else its readable text centred; else its source as
    /// a code card. 8 more points above (unless it opens the reply) and below.
    public static MathRun Display(TakenFormula formula, double basePointSize, MathMeasure measure, bool first, double? columnWidth = null)
    {
        ArgumentNullException.ThrowIfNull(formula);
        var maxWidth = columnWidth is { } c && c > 0 ? Math.Min(c, MathTypeset.BlockWidth) : MathTypeset.BlockWidth;
        var top = first ? 0 : BlockGap;
        if (MathTypeset.Fit(formula.Source, block: true, basePointSize, measure, maxWidth: maxWidth) is { } fit)
        {
            var b = fit.Bounds;
            return new MathRun(MathRunKind.Picture, formula.Source, true, fit, [new("\uFFFC", 0, basePointSize, 0)],
                b.Width, b.Height, -b.Y, GrowsLine: true, formula.Source, top, BlockGap);
        }
        if (MathText.Readable(formula.Source, block: true) is { } readable)
            return new MathRun(MathRunKind.Readable, formula.Source, true, null, Pieces(readable, basePointSize),
                0, 0, 0, false, formula.Source, top, BlockGap);
        return new MathRun(MathRunKind.Source, formula.Source, true, null, [new(formula.Source, 0, basePointSize, 0)],
            0, 0, 0, false, formula.Source, 0, 0);
    }

    // A word joiner after every character but the last (the Mac inserts U+2060 between characters).
    private static string Joined(string s)
    {
        if (s.Length < 2) return s;
        var sb = new System.Text.StringBuilder(s.Length * 2);
        var e = System.Globalization.StringInfo.GetTextElementEnumerator(s);
        var firstElement = true;
        while (e.MoveNext())
        {
            if (!firstElement) sb.Append('\u2060');
            sb.Append(e.GetTextElement());
            firstElement = false;
        }
        return sb.ToString();
    }

    /// Readable text cut at its limit marks (`MathText.LimitBelowOpen`/`LimitAboveOpen` … `LimitClose`): the limits
    /// smaller and shifted as the Mac's `MathStyle.attributed` sets them, the shift rounded to whole points.
    public static IReadOnlyList<MathTextPiece> Pieces(string readable, double basePointSize)
    {
        var pieces = new List<MathTextPiece>();
        var words = new System.Text.StringBuilder();
        void Flush()
        {
            if (words.Length == 0) return;
            pieces.Add(new(words.ToString(), 0, basePointSize, 0));
            words.Clear();
        }
        for (var i = 0; i < readable.Length; i++)
        {
            var ch = readable[i];
            if (ch is MathText.LimitBelowOpen or MathText.LimitAboveOpen)
            {
                var close = readable.IndexOf(MathText.LimitClose, i + 1);
                if (close < 0) close = readable.Length;
                Flush();
                var below = ch == MathText.LimitBelowOpen;
                var limit = readable[(i + 1)..close].Replace("\u2060", "", StringComparison.Ordinal);
                if (limit.Length > 0)
                    pieces.Add(new(limit, below ? -1 : 1, basePointSize * LimitScale,
                        Math.Round(basePointSize * (below ? LimitBelowOffset : LimitAboveOffset), MidpointRounding.AwayFromZero)));
                i = close;
                continue;
            }
            if (ch == MathText.LimitClose) continue;   // a stray close draws nothing (the Mac skips it)
            words.Append(ch);
        }
        Flush();
        return pieces;
    }
}

/// [WIN-MATH-UI] A run of drawn text as the selection sees it: from `Start` for `Length` positions, the characters
/// `Drawn`, and what selecting it whole copies (`Copy`: a formula's TeX source; null for words).
public sealed record CopyPiece(int Start, int Length, string Drawn, string? Copy = null, bool Code = false)
{
    public int End => Start + Length;
}

/// [WIN-MATH-UI] The words a selection copies (the Mac's `SelectionText.plain`, MessageSelection.swift at 93f984bb1): a
/// formula selected whole gives its TeX source, a part of one its drawn characters; the drawing's own marks drop out
/// (word joiners, the attachment character a picture stands on, a code span's narrow padding); U+2028 is a line break.
public static class MathCopy
{
    public static string Plain(IReadOnlyList<CopyPiece> pieces, int start, int end)
    {
        ArgumentNullException.ThrowIfNull(pieces);
        if (end <= start) return "";
        var sb = new System.Text.StringBuilder();
        foreach (var p in pieces)
        {
            var from = Math.Max(start, p.Start);
            var to = Math.Min(end, p.End);
            if (to <= from) continue;
            var whole = from == p.Start && to == p.End;
            if (p.Copy != null && whole) { sb.Append(p.Copy); continue; }
            var a = Math.Clamp(from - p.Start, 0, p.Drawn.Length);
            var b = Math.Clamp(to - p.Start, a, p.Drawn.Length);
            sb.Append(Clean(p.Drawn[a..b], p.Code || p.Copy != null));
        }
        return sb.ToString();
    }

    /// Whether any piece the selection touches copies as something other than its drawing (else the platform's own
    /// copy is left alone).
    public static bool Matters(IReadOnlyList<CopyPiece> pieces, int start, int end) =>
        pieces.Any(p => p.Copy != null && Math.Min(end, p.End) > Math.Max(start, p.Start));

    private static string Clean(string s, bool code)
    {
        var sb = new System.Text.StringBuilder(s.Length);
        foreach (var c in s)
        {
            switch (c)
            {
                case '\u2060' or '\uFFFC': continue;
                case '\u202F' when code: continue;
                case '\u2028': sb.Append('\n'); break;
                default: sb.Append(c); break;
            }
        }
        return sb.ToString();
    }
}

/// [WIN-MATH-UI] A formula's pictures, one per ink colour (and scale), as the Mac's `MathAttachment.drawn`: the key is
/// the colour's 8-bit channels, and the cache empties when it holds more than four (`if drawn.count > 4`).
public sealed class MathInkCache<T> where T : class
{
    private readonly Dictionary<string, T> _drawn = [];
    private readonly object _gate = new();

    public static string Key(byte r, byte g, byte b, byte a, double scale = 1) =>
        $"{r}.{g}.{b}.{a}" + (scale == 1 ? "" : "@" + scale.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture));

    public int Count { get { lock (_gate) return _drawn.Count; } }

    /// The picture under `key`, drawn by `draw` when not kept (null draws are not kept).
    public T? Get(string key, Func<T?> draw)
    {
        lock (_gate)
        {
            if (_drawn.TryGetValue(key, out var known)) return known;
            var made = draw();
            if (made == null) return null;
            if (_drawn.Count > 4) _drawn.Clear();
            _drawn[key] = made;
            return made;
        }
    }
}
