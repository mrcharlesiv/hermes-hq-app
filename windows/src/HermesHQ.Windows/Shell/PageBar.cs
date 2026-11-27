using Hermes.Core.Shell;
using HermesHQ.Features.Settings;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Shell;

/// [WIN-49] The bar over a page, as the Mac's (App/Mac/MacWindow.swift `pageBar`; numbers in Hermes.Core.Shell.DesktopLook):
/// the title in the page-title token (headline: 15 semibold in the Desktop Look, 17 in the iOS look), the page's own
/// buttons with the magnifier at the trailing edge (DesktopBars.searchToEdge), 15 pt glyphs, no hairline under it.
/// Windows keeps its own bar as a row in the page (the Catalyst window's UINavigationBar has no WinUI twin).
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
}
