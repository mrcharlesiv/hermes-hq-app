using Hermes.Core.Settings;
using Hermes.Core.Shell;
using HermesHQ.Features.Settings;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Shell;

/// [WIN-49] The bar over a page, as the Mac's (App/Mac/MacWindow.swift `pageBar`; numbers in Hermes.Core.Shell.DesktopLook):
/// the title in the page-title token (headline: 15 semibold in the Desktop Look, 17 in the iOS look), the page's own
/// buttons with the magnifier at the trailing edge (DesktopBars.searchToEdge), 15 pt glyphs, no hairline under it.
/// In the floating glass canvas the bar is transparent at rest and transitions to a frosted scroll veil once rows scroll
/// under it (`AttachScrollVeil`).
public static class PageBar
{
    /// The title's automation id on a page ("sessions" → "sessions.title"), which the CI walk measures.
    public static string TitleId(string page) => page + ".title";

    /// The page-title token on a bar's title; `page` (a place id) names it for the CI walk. [WIN-50] A host that draws
    /// several places' bars (Capabilities' stack, the bot pages' host) passes null until it knows which it shows.
    public static void Title(TextBlock title, string? page)
    {
        title.FontSize = DesktopLook.PageTitleSize(ThemeService.State.DesktopLook);
        title.FontWeight = new Windows.UI.Text.FontWeight { Weight = (ushort)DesktopLook.PageTitleWeight };
        if (page != null) AutomationProperties.SetAutomationId(title, TitleId(page));
    }

    /// A bar glyph at the Mac's size.
    public static void Glyph(FontIcon glyph) => glyph.FontSize = DesktopLook.BarGlyph;

    /// The bar's padding: the title the page's side in, the last glyph the side from the edge (its button's own room
    /// counts toward it).
    public static Thickness Padding(double top, double bottom) => new(DesktopLook.PageSide, top, DesktopLook.BarTrailingPad, bottom);

    /// Leaves the bar transparent at rest so the header blends into the floating canvas with no background strip.
    public static void Transparent(FrameworkElement bar) => SetBackground(bar, new SolidColorBrush(Colors.Transparent));

    /// Keeps `bar` transparent while `scroller` is at its top (`VerticalOffset <= 0.5`) and transitions it to a frosted
    /// scroll veil (`GlassShell.PageBarVeilBrush`) once scrolled content passes underneath (App/Mac/MacWindow.swift `pageBar`).
    public static IDisposable AttachScrollVeil(FrameworkElement bar, ScrollViewer scroller)
    {
        var scrolled = scroller.VerticalOffset > 0.5;
        var disposed = false;

        void Paint()
        {
            if (disposed || AppShutdown.Stopping) return;
            SetBackground(bar, scrolled ? GlassShell.PageBarVeilBrush() : new SolidColorBrush(Colors.Transparent));
        }

        void OnViewChanged(object? sender, ScrollViewerViewChangedEventArgs e)
        {
            var next = scroller.VerticalOffset > 0.5;
            if (next == scrolled) return;
            scrolled = next;
            Paint();
        }

        void OnPaletteChanged() => Paint();

        void Detach()
        {
            if (disposed) return;
            disposed = true;
            scroller.ViewChanged -= OnViewChanged;
            ThemeService.Changed -= OnPaletteChanged;
            WindowTransparency.Changed -= OnPaletteChanged;
            bar.Unloaded -= OnUnloaded;
        }

        void OnUnloaded(object sender, RoutedEventArgs e) => Detach();

        scroller.ViewChanged += OnViewChanged;
        ThemeService.Changed += OnPaletteChanged;
        WindowTransparency.Changed += OnPaletteChanged;
        bar.Unloaded += OnUnloaded;
        Paint();

        return new VeilHandle(Detach);
    }

    private static void SetBackground(FrameworkElement bar, Brush brush)
    {
        switch (bar)
        {
            case Panel p: p.Background = brush; break;
            case Border b: b.Background = brush; break;
            case Control c: c.Background = brush; break;
        }
    }

    private sealed class VeilHandle(Action dispose) : IDisposable
    {
        public void Dispose() => dispose();
    }
}
