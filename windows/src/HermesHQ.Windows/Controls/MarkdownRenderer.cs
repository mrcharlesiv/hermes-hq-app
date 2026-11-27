using Hermes.Core.Settings;
using Markdig;
using Markdig.Extensions.Tables;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using MdBlock = Markdig.Syntax.Block;
using MdInline = Markdig.Syntax.Inlines.Inline;
using XamlBlock = Microsoft.UI.Xaml.Documents.Block;
using XamlInline = Microsoft.UI.Xaml.Documents.Inline;

namespace HermesHQ.Controls;

/// Markdown → WinUI elements. Prose goes into selectable RichTextBlocks; fenced code gets its own monospaced,
/// horizontally scrolling card, like the iPhone app's code blocks.
public static class MarkdownRenderer
{
    private static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder()
        .UseEmphasisExtras().UsePipeTables().UseAutoLinks().UseTaskLists().Build();

    /// `trailing`: words drawn small and quiet after the last line (the reply's time, as the Mac puts it after its
    /// last words: "I read the big file.  11:13 AM").
    /// `onLink`: [artifacts] every link in the text goes here as written (a note's links to other notes, its `#fragment`
    /// headings and web links: Artifacts' linked notes). Null: web links open as before, others are plain words.
    public static void Render(string markdown, Panel into, Brush? foreground = null, string? trailing = null, Action<string>? onLink = null,
        ChatVisualTokens.TypeRamp? chatType = null)
    {
        var previous = (_onLink, _chatType, _formulas, _size, _lineHeight, _inLink);
        (_onLink, _chatType) = (onLink, chatType);
        try { RenderBlocks(markdown, into, foreground); }
        finally { (_onLink, _chatType, _formulas, _size, _lineHeight, _inLink) = previous; }
        if (trailing == null) return;
        var time = new Run
        {
            Text = "\u2002" + trailing, FontSize = chatType?.Caption2.Size ?? 11,
            FontWeight = FontWeights.Normal, Foreground = ThemeBrushes.Get("HQLabel2Brush"),
        };
        if (into.Children.LastOrDefault() is RichTextBlock { Blocks.Count: > 0 } last && last.Blocks[^1] is Paragraph p)
            p.Inlines.Add(time);
        else
            into.Children.Add(new TextBlock { Text = trailing, FontSize = chatType?.Caption2.Size ?? 11, HorizontalAlignment = HorizontalAlignment.Right,
                Foreground = ThemeBrushes.Get("HQLabel2Brush") });
    }

    /// The formulas taken out of the text being drawn (MathText.Extract): their tokens draw as math runs.
    [ThreadStatic] private static IReadOnlyList<Hermes.Core.Transcripts.TakenFormula>? _formulas;
    /// [artifacts] Where the text being drawn sends its links (Render's `onLink`).
    [ThreadStatic] private static Action<string>? _onLink;
    /// [WIN-MATH-UI] The words' size and line height where a formula is being drawn (a heading's, else the body's), and
    /// whether it sits inside a link (no picture can: a Hyperlink holds text only; and it copies as the link's words).
    [ThreadStatic] private static double _size, _lineHeight;
    [ThreadStatic] private static bool _inLink;
    // Only chat passes this ramp. Other Markdown surfaces keep their existing layout.
    [ThreadStatic] private static ChatVisualTokens.TypeRamp? _chatType;
    private static double BodySize => _chatType?.Body.Size ?? 14;
    private static double BodyLineHeight => _chatType?.BodyLine ?? 21;
    /// [WIN-MATH-UI] What each formula's text element copies when selected whole (the Mac's `.chatCopy`), and the plan
    /// each drawn formula follows (its text element, or a display formula's source card). Both live on the element
    /// itself, as the Mac's attributes live in the text: [WIN-MATH-THEME-WALK] a ConditionalWeakTable keyed by the
    /// element lost them. A Border, Run or Span made here is a sealed WinRT class whose C# object is only a wrapper the
    /// tree doesn't hold; once a collection takes it (the theme change's redrawn pictures bring one on), the tree hands
    /// back a new wrapper for the same element and the table knows it no more. The source card of \stackrel{a}{b}
    /// went unread for 15 s in CI runs 45104481282, 45124170121 and 45150564097 while the failure shot showed it drawn
    /// (the pictures kept theirs only because MathPictures holds their containers), and Ctrl+C would have copied a
    /// readable or source formula's drawn text, not its TeX.
    private static readonly DependencyProperty CopyProperty =
        DependencyProperty.RegisterAttached("MathCopy", typeof(object), typeof(MarkdownRenderer), new PropertyMetadata(null));
    private static readonly DependencyProperty PlanProperty =
        DependencyProperty.RegisterAttached("MathPlan", typeof(object), typeof(MarkdownRenderer), new PropertyMetadata(null));

    private static void SetPlan(DependencyObject element, Hermes.Core.Transcripts.MathRun run) => element.SetValue(PlanProperty, run);
    private static string? CopyOf(DependencyObject element) => element.ReadLocalValue(CopyProperty) as string;

    /// [WIN-MATH-UI] The formula an element draws, if it draws one (the chat-math walk reads these).
    public static Hermes.Core.Transcripts.MathRun? PlanOf(object element) =>
        element is DependencyObject d ? d.ReadLocalValue(PlanProperty) as Hermes.Core.Transcripts.MathRun : null;
    /// [WIN-MATH-UI] The real typesetter's measuring (Hermes.Math); `NoPicture` inside a link, so a formula there falls
    /// back to its readable text or source.
    private static readonly Hermes.Core.Transcripts.MathMeasure Measure = Hermes.Typeset.MathEngine.Measurer;
    private static readonly Hermes.Core.Transcripts.MathMeasure NoPicture = (_, _, _) => null;

    private static void RenderBlocks(string markdown, Panel into, Brush? foreground)
    {
        // [transcript] Math ($…$, \(…\), $$…$$) is lifted out before Markdown sees it, so its _ and * stay math.
        var extracted = Hermes.Core.Transcripts.MathText.Extract(markdown);
        _formulas = extracted.Formulas;
        (_size, _lineHeight, _inLink) = (BodySize, BodyLineHeight, false);
        var doc = Markdown.Parse(extracted.Text, Pipeline);
        RichTextBlock? prose = null;
        RichTextBlock Prose()
        {
            if (prose != null) return prose;
            prose = new RichTextBlock { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
            if (_chatType != null)
            {
                prose.FontSize = BodySize;
                prose.FontWeight = new Windows.UI.Text.FontWeight { Weight = _chatType.Body.Weight };
            }
            if (foreground != null) prose.Foreground = foreground;
            prose.PreviewKeyDown += CopyFormulasAsSource;   // [WIN-MATH-UI] Ctrl+C: formulas as their source
            into.Children.Add(prose);
            return prose;
        }

        foreach (var block in doc)
        {
            // [WIN-MATH-UI] A display formula nothing can draw (no picture, no readable text): its source as a code
            // card, which scrolls sideways (the Mac's `appendCodeText`).
            if (block is ParagraphBlock { Inline: { } only } && DisplayFormula(only) is { Kind: Hermes.Core.Transcripts.MathRunKind.Source } card)
            {
                prose = null;
                var sourceCard = CodeCard(card.Source, null);
                SetPlan(sourceCard, card);
                into.Children.Add(sourceCard);
                continue;
            }
            if (block is CodeBlock code)
            {
                prose = null;
                into.Children.Add(CodeCard(code));
                continue;
            }
            if (block is Table table)
            {
                prose = null;
                into.Children.Add(TableGrid(table));
                continue;
            }
            foreach (var b in Blocks(block, 0))
            {
                var text = Prose();
                if (_chatType != null && b is Paragraph p && block is not HeadingBlock && p.LineHeight > 0)
                    p.Margin = new Thickness(p.Margin.Left, text.Blocks.Count == 0 ? 0 : _chatType.ParagraphGap, p.Margin.Right, 0);
                text.Blocks.Add(b);
            }
        }
    }

    private static IEnumerable<XamlBlock> Blocks(MdBlock block, int depth)
    {
        switch (block)
        {
            case HeadingBlock h:
                var headingSize = _chatType?.Heading(h.Level).Size ?? (h.Level switch { 1 => 22, 2 => 19, 3 => 16.5, _ => 15 });
                (_size, _lineHeight) = (headingSize, _chatType?.HeadingLine(h.Level) ?? Math.Ceiling(headingSize * 1.3));
                Paragraph hp;
                try { hp = Para(h.Inline); }
                finally { (_size, _lineHeight) = (BodySize, BodyLineHeight); }
                hp.FontWeight = _chatType == null ? FontWeights.SemiBold : new Windows.UI.Text.FontWeight { Weight = _chatType.Heading(h.Level).Weight };
                hp.FontSize = headingSize;
                hp.Margin = new Thickness(0, 6, 0, 4);
                yield return hp;
                break;
            case ParagraphBlock p:
                // [WIN-MATH-UI] A formula on its own lines: a centred block (picture or readable text).
                if (p.Inline != null && DisplayFormula(p.Inline) is { } display)
                {
                    yield return DisplayParagraph(display, depth);
                    break;
                }
                yield return Para(p.Inline, depth);
                break;
            case ListBlock list:
                var n = int.TryParse(list.OrderedStart, out var start) ? start : 1;
                foreach (var item in list.OfType<ListItemBlock>())
                {
                    var marker = list.IsOrdered ? $"{n++}{list.OrderedDelimiter} " : "•  ";
                    var first = true;
                    foreach (var child in item)
                    {
                        foreach (var b in Blocks(child, depth + 1))
                        {
                            if (first && b is Paragraph para)
                            {
                                para.Inlines.Insert(0, new Run { Text = marker });
                                para.TextIndent = -14;
                            }
                            first = false;
                            yield return b;
                        }
                    }
                }
                break;
            case QuoteBlock q:
                foreach (var child in q)
                    foreach (var b in Blocks(child, depth + 1))
                    {
                        if (b is Paragraph para) para.Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush");
                        yield return b;
                    }
                break;
            case CodeBlock nestedCode:
            {
                var text = string.Join("\n", nestedCode.Lines.Lines.Take(nestedCode.Lines.Count).Select(l => l.Slice.ToString())).TrimEnd('\n');
                var cp = new Paragraph { Margin = new Thickness(depth * 16 + 8, 2, 0, 8), LineHeight = _chatType?.CodeLine ?? 19 };
                var run = new Run { Text = text, FontFamily = (FontFamily)Application.Current.Resources["CodeFont"], FontSize = _chatType?.Footnote.Size ?? 13 };
                cp.Inlines.Add(run);
                yield return cp;
                break;
            }
            case Table nestedTable:
            {
                foreach (var row in nestedTable.OfType<TableRow>())
                {
                    var tp = new Paragraph { Margin = new Thickness(depth * 16, 0, 0, 4), LineHeight = _chatType?.TableLine ?? 20 };
                    if (row.IsHeader) tp.FontWeight = FontWeights.SemiBold;
                    var firstCell = true;
                    foreach (var cell in row.OfType<TableCell>())
                    {
                        if (!firstCell) tp.Inlines.Add(new Run { Text = "  ·  ", Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush") });
                        firstCell = false;
                        foreach (var sub in cell.OfType<LeafBlock>())
                            if (sub.Inline != null)
                                foreach (var x in Inlines(sub.Inline)) tp.Inlines.Add(x);
                    }
                    yield return tp;
                }
                break;
            }
            case ThematicBreakBlock:
                yield return new Paragraph { Inlines = { new Run { Text = "———" } },
                    Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush") };
                break;
            case HtmlBlock html:
                yield return new Paragraph { Inlines = { new Run { Text = html.Lines.ToString() } } };
                break;
            case ContainerBlock c:
                foreach (var child in c) foreach (var b in Blocks(child, depth)) yield return b;
                break;
        }
    }

    private static Paragraph Para(ContainerInline? inline, int depth = 0)
    {
        var p = new Paragraph { Margin = new Thickness(depth * 16, 0, 0, 8), LineHeight = _chatType == null ? 21 : _lineHeight };
        if (inline != null) foreach (var i in Inlines(inline)) p.Inlines.Add(i);
        return p;
    }

    private static IEnumerable<XamlInline> Inlines(ContainerInline container)
    {
        foreach (var inline in container) foreach (var x in Inline(inline)) yield return x;
    }

    private static IEnumerable<XamlInline> Inline(MdInline inline)
    {
        switch (inline)
        {
            case LiteralInline lit:
                foreach (var run in Literal(lit.Content.ToString())) yield return run;
                break;
            case CodeInline code:
                var mono = new Run
                {
                    Text = code.Content,
                    FontFamily = (FontFamily)Application.Current.Resources["CodeFont"],
                    Foreground = ThemeBrushes.Get("AccentTextFillColorPrimaryBrush"),
                };
                if (_chatType != null) mono.FontSize = _chatType.InlineCode;
                yield return mono;
                break;
            case LineBreakInline br:
                yield return br.IsHard ? new LineBreak() : new Run { Text = " " };
                break;
            case EmphasisInline em:
                var span = em.DelimiterChar == '~' ? new Span()
                    : em.DelimiterCount >= 2 ? (Span)new Bold() : new Italic();
                if (em.DelimiterChar == '~') span.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
                foreach (var x in Inlines(em)) span.Inlines.Add(x);
                yield return span;
                break;
            case LinkInline { IsImage: false } followed when _onLink is { } follow:
                // [artifacts] A note's link: the page decides (another note, a heading, or the browser).
                var fh = new Hyperlink();
                var destination = followed.Url ?? "";
                fh.Click += (_, _) => follow(destination);
                var anyWords = false;
                _inLink = true;
                foreach (var x in Inlines(followed)) { fh.Inlines.Add(x); anyWords = true; }
                _inLink = false;
                if (!anyWords) fh.Inlines.Add(new Run { Text = destination });
                yield return fh;
                break;
            case LinkInline { IsImage: false } phoneLink when Uri.TryCreate(phoneLink.Url, UriKind.Absolute, out var phoneUri)
                                                            && phoneUri.Scheme.Equals("hermes", StringComparison.OrdinalIgnoreCase):
                var ph = new Hyperlink();
                var rawPhoneUrl = phoneLink.Url ?? "";
                ph.Click += (_, _) => HermesHQ.Features.PhoneCalls.PhoneCallsFeature.TryHandleProposalUri(rawPhoneUrl);
                var anyPhone = false;
                _inLink = true;
                foreach (var x in Inlines(phoneLink)) { ph.Inlines.Add(x); anyPhone = true; }
                _inLink = false;
                if (!anyPhone) ph.Inlines.Add(new Run { Text = rawPhoneUrl });
                yield return ph;
                break;
            case Markdig.Extensions.TaskLists.TaskList task:
                yield return new Run { Text = task.Checked ? "☑ " : "☐ " };
                break;
            case LinkInline { IsImage: false } link when Uri.TryCreate(link.Url, UriKind.Absolute, out var uri)
                                                       && uri.Scheme is "http" or "https" or "mailto":
            {
                // [transcript] A page on the gateway computer itself (localhost) can't open here (LinkTargets).
                var target = Hermes.Core.Transcripts.LinkTargets.Target(uri).Kind;
                if (target is Hermes.Core.Transcripts.LinkTargetKind.Loopback or Hermes.Core.Transcripts.LinkTargetKind.Refused)
                {
                    var plain = new Span { Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush") };
                    var anyPlain = false;
                    _inLink = true;
                    foreach (var x in Inlines(link)) { plain.Inlines.Add(x); anyPlain = true; }
                    _inLink = false;
                    if (!anyPlain) plain.Inlines.Add(new Run { Text = link.Url });
                    yield return plain;
                    break;
                }
                var h = new Hyperlink { NavigateUri = uri };
                var any = false;
                _inLink = true;
                foreach (var x in Inlines(link)) { h.Inlines.Add(x); any = true; }
                _inLink = false;
                if (!any) h.Inlines.Add(new Run { Text = link.Url });
                yield return h;
                break;
            }
            case AutolinkInline auto when Uri.TryCreate(auto.IsEmail ? "mailto:" + auto.Url : auto.Url, UriKind.Absolute, out var au)
                                          && au.Scheme is "http" or "https" or "mailto":
            {
                if (_onLink is { } followAuto)
                {
                    var ah = new Hyperlink();
                    var autoUrl = auto.IsEmail ? "mailto:" + auto.Url : auto.Url;
                    ah.Click += (_, _) => followAuto(autoUrl);
                    ah.Inlines.Add(new Run { Text = auto.Url });
                    yield return ah;
                    break;
                }
                var autoTarget = Hermes.Core.Transcripts.LinkTargets.Target(au).Kind;
                if (autoTarget is Hermes.Core.Transcripts.LinkTargetKind.Loopback or Hermes.Core.Transcripts.LinkTargetKind.Refused)
                    yield return new Run { Text = auto.Url, Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush") };
                else
                    yield return new Hyperlink { NavigateUri = au, Inlines = { new Run { Text = auto.Url } } };
                break;
            }
            case ContainerInline c:
                foreach (var x in Inlines(c)) yield return x;
                break;
            case HtmlInline html:
                yield return new Run { Text = html.Tag };
                break;
            case HtmlEntityInline ent:
                yield return new Run { Text = ent.Transcoded.ToString() };
                break;
        }
    }

    /// Plain words, with any math token drawn as its formula in the math font.
    private static IEnumerable<XamlInline> Literal(string text)
    {
        if (_formulas is not { Count: > 0 } formulas
            || text.IndexOfAny([Hermes.Core.Transcripts.MathText.InlineOpen, Hermes.Core.Transcripts.MathText.BlockOpen]) < 0)
        {
            yield return new Run { Text = text };
            yield break;
        }
        foreach (var piece in Hermes.Core.Transcripts.MathText.Pieces(text))
        {
            if (piece.Formula is { } i && i >= 0 && i < formulas.Count)
            {
                // [WIN-MATH-UI] Typeset on the words' baseline, else readable, else the source (MathRunPlan.Inline).
                // A Hyperlink holds text only, so inside a link a formula is never a picture.
                var run = Hermes.Core.Transcripts.MathRunPlan.Inline(formulas[i], _size > 0 ? _size : BodySize,
                    _lineHeight > 0 ? _lineHeight : BodyLineHeight, _inLink ? NoPicture : Measure, _inLink);
                yield return FormulaInline(run);
            }
            else if (piece.Text is { Length: > 0 } words) yield return new Run { Text = words };
        }
    }

    // ------------------------------------------------------------------ [WIN-MATH-UI] formulas

    /// The formula a paragraph is, when it is nothing but one display formula's token (the Mac's `MathText.blockToken`).
    private static Hermes.Core.Transcripts.MathRun? DisplayFormula(ContainerInline inline)
    {
        if (_formulas is not { Count: > 0 } formulas) return null;
        if (Hermes.Core.Transcripts.MathText.BlockToken(InlineText(inline).Trim()) is not { } index || index < 0 || index >= formulas.Count) return null;
        return Hermes.Core.Transcripts.MathRunPlan.Display(formulas[index], BodySize, Measure, first: false);
    }

    /// A display formula's own centred paragraph: its picture with a line as tall as it, or its readable text; 8 more
    /// points above and below (`MathStyle.blockGap`). A source card is drawn by RenderBlocks; nested (a list, a quote)
    /// the source stays in the code font here.
    private static Paragraph DisplayParagraph(Hermes.Core.Transcripts.MathRun run, int depth)
    {
        var p = new Paragraph
        {
            TextAlignment = TextAlignment.Center,
            Margin = new Thickness(depth * 16, run.TopGap, 0, 8 + run.BottomGap),
            LineHeight = run.Kind == Hermes.Core.Transcripts.MathRunKind.Picture ? 0 : BodyLineHeight,
        };
        p.Inlines.Add(FormulaInline(run));
        return p;
    }

    /// One formula as text elements: the picture in an InlineUIContainer, the readable text in the math font (its
    /// limits smaller), or the source in the code font; each remembers the TeX it copies.
    private static XamlInline FormulaInline(Hermes.Core.Transcripts.MathRun run)
    {
        XamlInline made;
        switch (run.Kind)
        {
            case Hermes.Core.Transcripts.MathRunKind.Picture:
                made = MathPictures.Inline(run);
                break;
            case Hermes.Core.Transcripts.MathRunKind.Readable:
                var span = new Span { FontFamily = new FontFamily("Cambria Math") };
                foreach (var piece in run.Text)
                {
                    var r = new Run { Text = piece.Text };
                    if (piece.Limit != 0) r.FontSize = piece.Size;
                    span.Inlines.Add(r);
                }
                made = span;
                break;
            default:
                made = new Run
                {
                    Text = run.Drawn, FontFamily = (FontFamily)Application.Current.Resources["CodeFont"],
                    FontSize = Math.Round((_size > 0 ? _size : BodySize) * (_chatType?.InlineCode ?? 13) / BodySize, 1),
                };
                break;
        }
        if (run.Copy is { } copy) made.SetValue(CopyProperty, copy);
        SetPlan(made, run);
        return made;
    }

    /// Copying a selection (Ctrl+C or Ctrl+Insert) gives each formula selected whole as its TeX source (the Mac's
    /// `SelectionText.plain`); a selection without one is left to the platform's own copy. WinUI's RichTextBlock has no
    /// copying event, so the keys are taken before it copies.
    private static void CopyFormulasAsSource(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        try
        {
            if (sender is not RichTextBlock rich || e.Key is not (Windows.System.VirtualKey.C or Windows.System.VirtualKey.Insert)) return;
            var control = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            if (!control || CopiedText(rich) is not { } text) return;
            e.Handled = true;
            HermesHQ.Services.SafeClipboard.TrySetText(text);
        }
        catch (Exception ex) { HermesHQ.Services.AppLog.Error("math", ex); }
    }

    /// What copying `rich`'s selection gives when a formula is in it (null when none is, or nothing is selected).
    public static string? CopiedText(RichTextBlock rich)
    {
        if (rich.SelectionStart is not { } from || rich.SelectionEnd is not { } to) return null;
        var (start, end) = (Math.Min(from.Offset, to.Offset), Math.Max(from.Offset, to.Offset));
        var pieces = CopyPieces(rich);
        if (end <= start || !Hermes.Core.Transcripts.MathCopy.Matters(pieces, start, end)) return null;
        return Hermes.Core.Transcripts.MathCopy.Plain(pieces, start, end);
    }

    /// The RichTextBlock's text as the selection counts it: each run, line break and formula at its offsets, a line
    /// break between paragraphs.
    public static List<Hermes.Core.Transcripts.CopyPiece> CopyPieces(RichTextBlock rich)
    {
        var pieces = new List<Hermes.Core.Transcripts.CopyPiece>();
        int? previousEnd = null;
        void Add(IEnumerable<XamlInline> inlines)
        {
            foreach (var inline in inlines)
            {
                var (s, e) = (inline.ContentStart.Offset, inline.ContentEnd.Offset);
                if (CopyOf(inline) is { } copy)
                {
                    var drawn = inline switch
                    {
                        Run r => r.Text,
                        Span sp => string.Concat(sp.Inlines.OfType<Run>().Select(r => r.Text)),
                        _ => "\uFFFC",
                    };
                    pieces.Add(new(s, Math.Max(1, e - s), drawn, copy, Code: inline is Run));
                    continue;
                }
                switch (inline)
                {
                    case Run r: pieces.Add(new(s, Math.Max(r.Text.Length, e - s), r.Text)); break;
                    case LineBreak: pieces.Add(new(inline.ElementStart.Offset, Math.Max(1, inline.ElementEnd.Offset - inline.ElementStart.Offset), "\n")); break;
                    case Span sp: Add(sp.Inlines); break;
                }
            }
        }
        foreach (var block in rich.Blocks.OfType<Paragraph>())
        {
            var (s, e) = (block.ContentStart.Offset, block.ContentEnd.Offset);
            if (previousEnd is { } before && s > before) pieces.Add(new(before, s - before, "\n"));
            Add(block.Inlines);
            previousEnd = e;
        }
        return pieces;
    }

    private static string CellText(MdBlock block, IReadOnlyList<Hermes.Core.Transcripts.TakenFormula>? formulas = null) => block switch
    {
        LeafBlock { Inline: { } inline } => ExpandFormulaTokens(InlineText(inline), formulas),
        ContainerBlock c => string.Join(" ", c.Select(b => CellText(b, formulas))),
        _ => "",
    };

    private static string ExpandFormulaTokens(string text, IReadOnlyList<Hermes.Core.Transcripts.TakenFormula>? formulas)
    {
        var list = formulas ?? _formulas;
        if (list is not { Count: > 0 }
            || text.IndexOfAny([Hermes.Core.Transcripts.MathText.InlineOpen, Hermes.Core.Transcripts.MathText.BlockOpen]) < 0)
            return text;
        var sb = new System.Text.StringBuilder(text.Length);
        foreach (var piece in Hermes.Core.Transcripts.MathText.Pieces(text))
        {
            if (piece.Formula is { } i && i >= 0 && i < list.Count) sb.Append(list[i].Written);
            else if (piece.Text != null) sb.Append(piece.Text);
        }
        return sb.ToString();
    }

    private static string InlineText(ContainerInline c) => string.Concat(c.Select(i => i switch
    {
        LiteralInline l => l.Content.ToString(),
        CodeInline code => code.Content,
        ContainerInline inner => InlineText(inner),
        _ => " ",
    }));

    /// The table sheet's grid: every cell, no width cap.
    private static FrameworkElement SheetGrid(Table table, IReadOnlyList<Hermes.Core.Transcripts.TakenFormula>? formulas)
    {
        var grid = new Grid { ColumnSpacing = 20, RowSpacing = 6 };
        var rows = table.OfType<TableRow>().ToList();
        var cols = rows.Count == 0 ? 0 : rows.Max(r => r.Count);
        for (var c = 0; c < cols; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        for (var r = 0; r < rows.Count; r++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            for (var c = 0; c < rows[r].Count; c++)
            {
                var cell = new TextBlock
                {
                    Text = CellText((TableCell)rows[r][c], formulas), IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, MaxWidth = 480,
                    FontWeight = rows[r].IsHeader ? FontWeights.SemiBold : FontWeights.Normal,
                };
                Grid.SetRow(cell, r);
                Grid.SetColumn(cell, c);
                grid.Children.Add(cell);
            }
        }
        return grid;
    }

    private static FrameworkElement CodeCard(CodeBlock code) =>
        CodeCard(string.Join("\n", code.Lines.Lines.Take(code.Lines.Count).Select(l => l.Slice.ToString())).TrimEnd('\n'),
            (code as FencedCodeBlock)?.Info);

    private static FrameworkElement CodeCard(string text, string? lang)
    {
        var stack = new StackPanel { Spacing = 4 };
        if (!string.IsNullOrWhiteSpace(lang))
            stack.Children.Add(new TextBlock
            {
                Text = lang, FontSize = _chatType?.Caption1.Size ?? 11, FontWeight = _chatType == null ? FontWeights.Normal : FontWeights.Medium,
                Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
            });
        stack.Children.Add(new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Auto, VerticalScrollMode = ScrollMode.Disabled,
            Content = new TextBlock
            {
                Text = text, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.NoWrap, FontSize = _chatType?.Footnote.Size ?? 13,
                LineHeight = _chatType?.CodeLine ?? 0,
                FontFamily = (FontFamily)Application.Current.Resources["CodeFont"],
            },
        });
        return new Border
        {
            Child = stack,
            Padding = new Thickness(12, 10, 12, 10),
            Margin = new Thickness(0, 2, 0, 10),
            CornerRadius = new CornerRadius(8),
            Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush"),
            BorderBrush = ThemeBrushes.Get("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
    }

    private static FrameworkElement TableGrid(Table table, bool sheet = false, IReadOnlyList<Hermes.Core.Transcripts.TakenFormula>? formulas = null)
    {
        var capturedFormulas = formulas ?? _formulas;
        if (sheet) return SheetGrid(table, capturedFormulas);
        var grid = new Grid { Margin = new Thickness(0, 2, 0, 10), ColumnSpacing = 16, RowSpacing = 4 };
        var rows = table.OfType<TableRow>().ToList();
        var cols = rows.Count == 0 ? 0 : rows.Max(r => r.Count);
        for (var c = 0; c < cols; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        for (var r = 0; r < rows.Count; r++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            for (var c = 0; c < rows[r].Count; c++)
            {
                var cell = new RichTextBlock { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, MaxWidth = 320 };
                cell.PreviewKeyDown += CopyFormulasAsSource;
                foreach (var b in ((TableCell)rows[r][c]).SelectMany(x => Blocks(x, 0)))
                {
                    if (b is Paragraph p)
                    {
                        p.Margin = new Thickness(0);
                        if (_chatType != null) { p.FontSize = _chatType.Footnote.Size; p.LineHeight = _chatType.TableLine; }
                        if (rows[r].IsHeader) p.FontWeight = FontWeights.SemiBold;
                    }
                    cell.Blocks.Add(b);
                }
                Grid.SetRow(cell, r);
                Grid.SetColumn(cell, c);
                grid.Children.Add(cell);
            }
        }
        var scroller = new ScrollViewer
        {
            Content = grid, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Auto, VerticalScrollMode = ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        // [transcript] The table sheet: the whole table in a window of its own, with Copy as Text (tab-separated cells).
        // [WIN-36] Opened from the Mac's footer (ChatTextViews.swift `TableFooterControl`): “3 rows · 7 columns” on the
        // left, “Expand” on the right; named “Expand table”, id chat.table.expand. The sheet is titled “Table” and
        // its copy button reads “Copy as Text” (TableSheetController.swift), id table.sheet.
        var cells = rows.Select(r => (IReadOnlyList<string>)r.OfType<TableCell>().Select(c => CellText(c, capturedFormulas)).ToList()).ToList();
        var bodyRows = rows.Count(r => !r.IsHeader);
        var footer = new Grid { ColumnSpacing = 12 };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.Children.Add(new TextBlock
        {
            Text = Hermes.Core.Transcripts.TableText.FooterCounts(bodyRows, cols), FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center, Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
        });
        var expandWords = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, VerticalAlignment = VerticalAlignment.Center };
        expandWords.Children.Add(new FontIcon { Glyph = "\uE740", FontSize = 11,   // FullScreen (the Mac's arrow.up.left.and.arrow.down.right)
            Foreground = ThemeBrushes.Get("AccentTextFillColorPrimaryBrush") });
        expandWords.Children.Add(new TextBlock { Text = Hermes.Core.Transcripts.TableText.ExpandWord, FontSize = 12, FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get("AccentTextFillColorPrimaryBrush") });
        Grid.SetColumn(expandWords, 1);
        footer.Children.Add(expandWords);
        var open = new Button
        {
            Content = footer, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(0, 6, 0, 6), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderBrush = ThemeBrushes.Get("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(0, 1, 0, 0),
            CornerRadius = new CornerRadius(0), IsEnabled = bodyRows > 0,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(open, Hermes.Core.Transcripts.TableText.ExpandName);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(open, Hermes.Core.Transcripts.TableText.ExpandId);
        open.Click += async (_, _) =>
        {
            if (open.XamlRoot == null) return;
            var big = TableGrid(table, sheet: true, formulas: capturedFormulas);
            var dialog = new ContentDialog
            {
                Title = Hermes.Core.Transcripts.TableText.SheetTitle, Content = new ScrollViewer
                {
                    Content = big, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                    HorizontalScrollMode = ScrollMode.Auto, MaxHeight = 560,
                },
                PrimaryButtonText = Hermes.Core.Transcripts.TableText.CopyTitle, CloseButtonText = "Done", DefaultButton = ContentDialogButton.Close,
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(dialog, Hermes.Core.Transcripts.TableText.SheetId);
            dialog.PrimaryButtonClick += (_, _) =>
            {
                if (Hermes.Core.Transcripts.TableText.Copyable(cells) is not { } text) return;
                HermesHQ.Services.SafeClipboard.TrySetText(text);
            };
            await HermesHQ.Services.SafeDialog.ShowAsync(open.XamlRoot, dialog);
        };
        var stack = new StackPanel { Tag = InlineTableTag, Margin = new Thickness(0, 0, 0, 6) };
        stack.Children.Add(scroller);
        stack.Children.Add(open);
        return stack;
    }

    // A parsed table, not a guess based on pipes in prose or fenced code.
    internal const string InlineTableTag = "chat.markdown.inline-table";
}
