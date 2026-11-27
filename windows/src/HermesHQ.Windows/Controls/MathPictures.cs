using System.Runtime.InteropServices.WindowsRuntime;
using Hermes.Core.Transcripts;
using Hermes.Typeset;
using HermesHQ.Features.Settings;
using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace HermesHQ.Controls;

/// [WIN-MATH-UI] A typeset formula as an Image in the chat's text (the Mac's MathAttachment, App/Chat/Render/
/// MathTypeset.swift at 93f984bb1): its box in DIPs is the plan's (`MathRun.Width`/`Height`), its pixels drawn by
/// Hermes.Math at the window's rasterization scale, in the colour the text around it is drawn in. It draws again when
/// the theme changes (that colour with it) and when the window moves to a screen of another scale; one picture per
/// colour and scale is kept (`MathInkCache`, the Mac's five).
public static class MathPictures
{
    /// What each picture in the chat is (the chat-math walk reads them).
    public sealed record Shown(MathRun Run, Image Image)
    {
        public double Scale { get; internal set; }
        public MathPicture? Picture { get; internal set; }
        public MathColor Ink { get; internal set; }
        /// The chat text's element holding the picture (MathPictures.Inline), whose words' colour is the ink.
        public InlineUIContainer? Container { get; internal set; }
    }

    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<Image, Shown> Pictures = new();

    /// The picture behind an Image this made, if it is one.
    public static Shown? Of(Image image) => Pictures.TryGetValue(image, out var s) ? s : null;

    /// The picture in the chat's text: an Image in an InlineUIContainer, its ink the colour that element's words are
    /// drawn in (the Mac's foregroundColor at the attachment's character, MathTypeset.swift:142).
    public static InlineUIContainer Inline(MathRun run)
    {
        var image = Create(run);
        var container = new InlineUIContainer { Child = image };
        if (Of(image) is { } shown) shown.Container = container;
        return container;
    }

    public static Image Create(MathRun run)
    {
        ArgumentNullException.ThrowIfNull(run);
        var image = new Image
        {
            Width = run.Width, Height = run.Height, Stretch = Stretch.Fill,
            // Its baseline on the words': the descent hangs below it (an inline element stands on the baseline).
            Margin = run.Block ? new Thickness(0) : new Thickness(0, 0, 0, -run.BaselineDrop),
            IsHitTestVisible = false,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(image, run.Source);
        var shown = new Shown(run, image);
        Pictures.AddOrUpdate(image, shown);
        var cache = new MathInkCache<WriteableBitmap>();
        XamlRoot? watched = null;
        void Draw()
        {
            if (image.XamlRoot is not { } root || run.Fit is not { } fit) return;
            var scale = root.RasterizationScale > 0 ? root.RasterizationScale : 1;
            var ink = InkOf(image);
            var key = MathInkCache<WriteableBitmap>.Key(ink.R, ink.G, ink.B, ink.A, scale);
            try
            {
                MathPicture? drawn = null;
                var bitmap = cache.Get(key, () =>
                {
                    drawn = MathEngine.Draw(fit, ink, scale);
                    return drawn == null ? null : Bitmap(drawn);
                });
                if (bitmap == null) return;
                image.Source = bitmap;
                shown.Scale = scale;
                shown.Ink = ink;
                if (drawn != null) shown.Picture = drawn;
            }
            catch (Exception e) { AppLog.Error("math", e); }
        }
        void ScaleChanged(XamlRoot sender, XamlRootChangedEventArgs args)
        {
            if (sender.RasterizationScale != shown.Scale) Draw();
        }
        // [WIN-THEME-APP-RESOURCES] Also after ThemeService has painted the new mode's brushes: ActualThemeChanged can
        // come while the words' brush still holds the old mode's colour.
        void Repainted() => Draw();
        image.Loaded += (_, _) =>
        {
            ThemeService.Changed -= Repainted;
            ThemeService.Changed += Repainted;
            if (watched != image.XamlRoot)
            {
                if (watched != null) watched.Changed -= ScaleChanged;
                watched = image.XamlRoot;
                if (watched != null) watched.Changed += ScaleChanged;
            }
            Draw();
        };
        image.Unloaded += (_, _) =>
        {
            ThemeService.Changed -= Repainted;
            if (watched != null) watched.Changed -= ScaleChanged;
            watched = null;
        };
        image.ActualThemeChanged += (_, _) => Draw();
        return image;
    }

    /// The colour the words around the picture are drawn in: the chat text's own (TextInk) when the picture sits in an
    /// InlineUIContainer (an Image there has no visual parent chain to its RichTextBlock, so the walk up found nothing
    /// and fell back to the application's light-theme near-black under Appearance › Dark: CI run 45095225249, shot
    /// 194), else the nearest text element's foreground up the visual parents, else the primary text in the mode on
    /// show (ThemeBrushes, not Application.Current.Resources) [WIN-THEME-APP-RESOURCES].
    internal static MathColor InkOf(FrameworkElement element)
    {
        if (element is Image image && Of(image)?.Container is { } container && TextInk(container) is { } words) return Colour(words);
        for (DependencyObject? at = element; at != null; at = VisualTreeHelper.GetParent(at))
        {
            var brush = at switch
            {
                RichTextBlock r => r.Foreground,
                TextBlock t => t.Foreground,
                Control c => c.Foreground,
                _ => null,
            };
            if (brush is SolidColorBrush solid) return Colour(solid);
        }
        if (ThemeBrushes.Get("TextFillColorPrimaryBrush") is SolidColorBrush primary) return Colour(primary);
        return element.ActualTheme == ElementTheme.Dark ? new MathColor(255, 255, 255) : new MathColor(0, 0, 0, 228);
    }

    /// The brush a text element's words are drawn with: the nearest foreground set on it or a text element holding it
    /// (a quote's quieter paragraph, a bubble's own ink), else the RichTextBlock's, resolved in the block's own theme.
    public static SolidColorBrush? TextInk(TextElement element)
    {
        DependencyObject? at = element;
        for (var depth = 0; at is TextElement text && depth < 16; depth++)
        {
            if (text.ReadLocalValue(TextElement.ForegroundProperty) is SolidColorBrush own) return own;
            var parent = text.ElementStart?.Parent;
            if (ReferenceEquals(parent, text)) break;
            at = parent;
        }
        var block = at as RichTextBlock ?? element.ContentStart?.VisualParent as RichTextBlock;
        return block?.Foreground as SolidColorBrush;
    }

    private static MathColor Colour(SolidColorBrush solid)
    {
        var c = solid.Color;
        return new MathColor(c.R, c.G, c.B, (byte)Math.Round(c.A * Math.Clamp(solid.Opacity, 0, 1)));
    }

    private static WriteableBitmap Bitmap(MathPicture picture)
    {
        var bitmap = new WriteableBitmap(picture.Width, picture.Height);
        using (var stream = bitmap.PixelBuffer.AsStream())
        {
            var row = picture.Width * 4;
            for (var y = 0; y < picture.Height; y++) stream.Write(picture.Bgra, y * picture.Stride, row);
        }
        bitmap.Invalidate();
        return bitmap;
    }
}
