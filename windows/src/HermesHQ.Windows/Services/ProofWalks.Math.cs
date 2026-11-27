using Hermes.Core.Settings;
using Hermes.Core.Shell;
using Hermes.Core.Transcripts;
using Hermes.Typeset;
using HermesHQ.Controls;
using HermesHQ.Features.Settings;
using HermesHQ.Pages;
using HermesHQ.Shell;
using HermesHQ.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;

namespace HermesHQ.Services;

/// [WIN-MATH-UI] The CI's walk for the chat's formulas, on the pages stand-in run with `--chat-math`
/// (pages-fixture-gateway.py's s-chat-math, “The maths notes”), backed by `Hermes.Core.Shell.MathWalkProof`:
///   chat-math        The reply draws \frac{a}{b} as a picture on its sentence's baseline, the aligned block, the cases,
///                    the pmatrix and the sum with limits as centred block pictures, each at the window's rasterization
///                    scale in the text's colour, and \stackrel{a}{b} (which the Mac's typesetter can't set) as text,
///                    readable or its source card (shot chat-math). Select All in the reply, copied, gives every
///                    formula's TeX source (the Mac's .chatCopy).
///   chat-math-theme  The chat in the other theme: every picture drawn again in the new text colour; then put back.
internal static partial class ProofWalks
{
    private static void RegisterMathWalks()
    {
        Automation.NamedWalks["chat-math"] = ChatMathAsync;
    }

    private static async Task ChatMathAsync(Func<string, Task> shot)
    {
        _ = AppState.Client ?? throw new InvalidOperationException("not signed in");
        Navigator.Go(new ChatDestination(MathWalkProof.Bot, MathWalkProof.Session, MathWalkProof.Title));
        var chat = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == MathWalkProof.Session && p.MessageCount >= 2 ? p : null,
            "the maths notes' messages");
        var list = await Until(() => Shown(chat).OfType<ListView>().FirstOrDefault(), "the transcript");
        var items = (list.ItemsSource as IEnumerable<object>)?.OfType<MessageItem>().ToList() ?? [];
        list.ScrollIntoView(items[^1], ScrollIntoViewAlignment.Leading);
        await Task.Delay(600);
        var pictures = await Until(() => Formulas(list) is { } f && f.Count(d => d.Kind == MathRunKind.Picture && d.PixelWidth > 0) >= 5 ? f : null,
            "the reply's formulas drawn", 20);
        if (MathWalkProof.Formulas(pictures) is { } wrong) throw new InvalidOperationException(wrong);
        AppLog.Note("automation", $"walk chat-math: {pictures.Count} formulas, {pictures.Count(d => d.Kind == MathRunKind.Picture)} pictures at scale {pictures.First(d => d.Scale > 0).Scale}");
        await shot("chat-math");

        // Select All in the reply's text, copied: every formula's source (what Ctrl+C puts on the clipboard).
        var rich = Shown(list).OfType<RichTextBlock>().FirstOrDefault(r => MarkdownRenderer.CopyPieces(r).Any(p => p.Copy == MathWalkProof.InlineFraction))
            ?? throw new InvalidOperationException("no reply text holds the inline fraction");
        rich.SelectAll();
        var copied = MarkdownRenderer.CopiedText(rich) ?? throw new InvalidOperationException("copying the reply gave no formula's source");
        rich.Select(rich.ContentStart, rich.ContentStart);
        if (MathWalkProof.Copied(copied) is { } uncopied) throw new InvalidOperationException(uncopied);

        // The other theme: the pictures drawn again in the new text colour.
        var before = pictures.Where(d => d.Kind == MathRunKind.Picture).Select(d => d.Source).ToList();
        // Switched as Settings › Appearance does (the whole window), not on the chat element alone: CI run 45089742433
        // set it on the chat only, so the page's light backdrop showed through under dark-theme text (202, a walk
        // artifact, not the app's look).
        var was = ThemeService.Chosen;
        ThemeService.SetAppearance(((FrameworkElement)chat).ActualTheme == ElementTheme.Dark ? AppearanceSetting.Light : AppearanceSetting.Dark);
        try
        {
            await Task.Delay(800);
            // The whole reply drawn again, not just its pictures re-inked. CI runs 45104481282, 45124170121 and
            // 45150564097 failed here on "isn't drawn at all" with the card on screen: the card's plan was kept in a
            // table keyed by its C# wrapper, which a collection during the theme change took ([WIN-MATH-THEME-WALK];
            // the plan now lives on the element, MarkdownRenderer.PlanOf). Wait for the full check; on a timeout
            // report what it last saw.
            string? last = null;
            List<MathWalkProof.Drawn> again;
            try
            {
                again = await Until(() => Formulas(list) is { } f && f.Where(d => d.Kind == MathRunKind.Picture).All(d => d.InkIsTextColour)
                    && (last = MathWalkProof.Formulas(f)) == null ? f : null,
                    "the formulas drawn again in the other theme's text colour", 15);
            }
            catch (TimeoutException) when (last != null)
            {
                // CI run 45124170121 timed out here with the unset formula's card missing for 15 s, and the failure
                // shot (taken after the theme went back) showed it. Say what the list held and shoot the other theme
                // before it is put back, so the next failure shows whether the card is gone or only unread.
                var seen = Formulas(list);
                AppLog.Note("automation", $"walk chat-math: in the other theme the list held {seen.Count} formulas: "
                    + string.Join(" | ", seen.Select(d => $"{d.Kind}:{d.Source}")) + $"; {Shown(list).Count()} elements shown, "
                    + $"{Shown(list).OfType<RichTextBlock>().Count()} text blocks, list {list.ActualWidth:0}×{list.ActualHeight:0}; "
                    + MathWalkProof.Unread(Holders(list)));
                await shot("chat-math-theme-failure");
                throw new InvalidOperationException("in the other theme: " + last);
            }
            // [WIN-THEME-APP-RESOURCES] What the shot will show: the window's ground in the mode on show, and each
            // picture's ink its paragraph's words' colour, readable there (shot 194 had a light ground, black formulas).
            var window = App.Window?.Content as Panel ?? throw new InvalidOperationException("no window root");
            var dark = window.ActualTheme == ElementTheme.Dark;
            if (window.Background is not Microsoft.UI.Xaml.Media.SolidColorBrush ground) throw new InvalidOperationException("the window's ground isn't a solid colour");
            var inks = Inks(list);
            if (MathWalkProof.Theme(dark, ToRgba(ground.Color, 1), inks) is { } unthemed) throw new InvalidOperationException("in the other theme: " + unthemed);
            AppLog.Note("automation", $"walk chat-math: {(dark ? "dark" : "light")} ground {ToRgba(ground.Color, 1).HexString}, {inks.Count} pictures in their words' colour");
            await shot("chat-math-theme");
        }
        finally { ThemeService.SetAppearance(was); }
        await Task.Delay(400);
    }

    /// [WIN-MATH-THEME-WALK] Every Border and TextBlock on show whose words hold the formula the typesetter can't set,
    /// and the plan each carries (MarkdownRenderer.PlanOf; the source card is the Border).
    private static List<(string Element, MathRunKind? Plan)> Holders(ListView list)
    {
        static string Words(FrameworkElement e) => e switch
        {
            TextBlock t => t.Text ?? "",
            Border b => string.Join("\n", Shown(b).OfType<TextBlock>().Select(t => t.Text)),
            _ => "",
        };
        return [.. Shown(list).Where(e => e is Border or TextBlock && Words(e).Contains(MathWalkProof.Unset, StringComparison.Ordinal))
            .Select(e => (e.GetType().Name, MarkdownRenderer.PlanOf(e)?.Kind))];
    }

    /// Each picture's ink beside its paragraph's words' colour.
    private static List<(string Source, Hermes.Core.Settings.Rgba Ink, Hermes.Core.Settings.Rgba Text)> Inks(ListView list)
    {
        var found = new List<(string, Hermes.Core.Settings.Rgba, Hermes.Core.Settings.Rgba)>();
        void Walk(IEnumerable<Inline> inlines)
        {
            foreach (var inline in inlines)
            {
                if (MarkdownRenderer.PlanOf(inline) is { Kind: MathRunKind.Picture } run && inline is InlineUIContainer { Child: Image image }
                    && MathPictures.Of(image) is { } shown && WordsColour(inline) is { } words)
                {
                    var ink = shown.Ink;
                    found.Add((run.Source.Trim(), new(ink.R / 255.0, ink.G / 255.0, ink.B / 255.0, ink.A / 255.0), ToRgba(words.Color, words.Opacity)));
                }
                else if (inline is Span span) Walk(span.Inlines);
            }
        }
        foreach (var rich in Shown(list).OfType<RichTextBlock>())
            foreach (var p in rich.Blocks.OfType<Paragraph>()) Walk(p.Inlines);
        return found;
    }

    /// The brush the words of the paragraph holding `element` are drawn with (MathPictures.TextInk: the paragraph's own
    /// foreground if it has one, a quote's, else the RichTextBlock's as it resolves in the block's theme).
    private static Microsoft.UI.Xaml.Media.SolidColorBrush? WordsColour(object element) =>
        element is TextElement text ? MathPictures.TextInk(text) : null;

    private static bool Same(MathColor ink, Microsoft.UI.Xaml.Media.SolidColorBrush words) =>
        ToRgba(words.Color, words.Opacity).Near(new(ink.R / 255.0, ink.G / 255.0, ink.B / 255.0, ink.A / 255.0), 1.5 / 255);

    private static Hermes.Core.Settings.Rgba ToRgba(Windows.UI.Color c, double opacity) =>
        new(c.R / 255.0, c.G / 255.0, c.B / 255.0, c.A / 255.0 * Math.Clamp(opacity, 0, 1));

    /// Every formula drawn in the transcript: its plan and, for a picture, what was drawn.
    private static List<MathWalkProof.Drawn> Formulas(ListView list)
    {
        var found = new List<MathWalkProof.Drawn>();
        void Read(object element, MathRun run)
        {
            if (run.Kind == MathRunKind.Picture && element is InlineUIContainer { Child: Image image } && MathPictures.Of(image) is { } shown)
            {
                var ink = 0;
                if (shown.Picture is { } p) for (var i = 3; i < p.Bgra.Length; i += 4) if (p.Bgra[i] != 0) ink++;
                // The ink against the colour the paragraph's words are drawn in, read here, not MathPictures.InkOf again:
                // comparing InkOf with itself passed while shot 194 showed black formulas under white words.
                found.Add(new(run.Kind, run.Block, run.Source.Trim(), run.Width, run.Height, shown.Picture?.Width ?? 0, shown.Picture?.Height ?? 0,
                    shown.Scale, ink, WordsColour(element) is { } words && Same(shown.Ink, words)));
            }
            else found.Add(new(run.Kind, run.Block, run.Source.Trim(), run.Width, run.Height, 0, 0, 0, 0, true));
        }
        void Walk(IEnumerable<Inline> inlines)
        {
            foreach (var inline in inlines)
            {
                if (MarkdownRenderer.PlanOf(inline) is { } run) { Read(inline, run); continue; }
                if (inline is Span span) Walk(span.Inlines);
            }
        }
        foreach (var element in Shown(list))
        {
            if (element is RichTextBlock rich) foreach (var p in rich.Blocks.OfType<Paragraph>()) Walk(p.Inlines);
            else if (MarkdownRenderer.PlanOf(element) is { } card) Read(element, card);
        }
        return found;
    }
}
