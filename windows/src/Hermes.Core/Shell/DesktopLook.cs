using Hermes.Core.Settings;

namespace Hermes.Core.Shell;

/// [WIN-49] The Mac's selection mark and page bar, measured off the shipping Swift (93f984bb1) so the Windows shell draws
/// them from one place:
///   - App/Mac/MacSelection.swift: one mark for every list row the window marks (sidebar, Bots, Sessions, Jobs…): a
///     rounded box inset in its row, never a leading bar; the accent while its pane holds the focus (the last click
///     landed there) and the window is in front, grey otherwise; a press alone is grey.
///   - App/Theme/DesktopLayout.swift `DesktopRows`: the box's inset (2 top and foot, 8 each side) and the look's 4 pt
///     corner (the iOS look's 8).
///   - App/Mac/MacWindow.swift `pageBar`: an opaque bar in the page's own colour, no hairline under it, the title in
///     `MacType.pageTitle` (headline: 15 semibold in the Desktop Look, App/Theme/ThemeFonts.swift `desktopSpec`; 17
///     semibold in the iOS look) and its grey subtitle line in footnote (12.5 / 13).
///   - App/Kit/PageBarCapsule.swift and App/Theme/DesktopBars.swift: the page's own buttons read Filter · Search · Compose,
///     and on the Mac the magnifier is moved to the trailing edge (`searchToEdge`, stress test #66) so it sits in one
///     place on every page; bar glyphs 15 pt (`glyphSize`), an item 44 tall and at least 44 wide with 6 either side of its
///     glyph (`BarItemButton` without the glass).
public static class DesktopLook
{
    // ------------------------------------------------------------------ the selection mark (MacSelection)

    /// The panes a click can land in (`MacSelection.Pane`).
    public enum Pane { Sidebar, List, Detail }

    /// The box's room inside its row (`DesktopRows.pressInset`): top, leading, bottom, trailing.
    public const double MarkInsetTop = 2, MarkInsetSide = 8, MarkInsetBottom = 2;

    /// The box's corner (`MacSelection.radius`): the Desktop Look's 4 pt, the iOS look's 8.
    public static double MarkRadius(bool desktopLook) => desktopLook ? 4 : 8;

    /// The Mac draws no leading accent bar (WinUI's ListViewItem selection indicator): the whole box is the mark.
    public const bool LeadingIndicator = false;

    /// The accent's share in the mark (`MacSelection.accent`): 24 % in light, 42 % in dark, a fifth for an ink tint in dark.
    public const double AccentShareLight = 0.24, AccentShareDark = 0.42, InkDarkShare = 0.2;

    /// The unfocused mark and a press (`MacSelection.grey`): the label colour at 9 % in light, 14 % in dark.
    public const double GreyShareLight = 0.09, GreyShareDark = 0.14;

    /// A colour with no hue to speak of and near white (`MacSelection.inkTint`): saturation under 0.12, brightness over 0.75.
    public static bool InkTint(Rgba c)
    {
        var max = Math.Max(c.R, Math.Max(c.G, c.B));
        var min = Math.Min(c.R, Math.Min(c.G, c.B));
        var saturation = max <= 0 ? 0 : (max - min) / max;
        return saturation < 0.12 && max > 0.75;
    }

    /// The emphasized mark: the chosen-row colour (the message colour where one is picked, else the tint) at its share.
    public static Rgba Accent(Rgba chosenRow, bool dark) =>
        chosenRow.Alpha(dark ? (InkTint(chosenRow) ? InkDarkShare : AccentShareDark) : AccentShareLight);

    /// The grey mark: the label colour at its share.
    public static Rgba Grey(Rgba label, bool dark) => label.Alpha(dark ? GreyShareDark : GreyShareLight);

    /// The pane whose mark is the accent: the one the last click landed in, while the window is in front
    /// (`MacSelection.emphasized`).
    public static bool Emphasized(Pane pane, Pane focus, bool windowActive) => windowActive && focus == pane;

    /// What fills a row (`MacSelection.fill`): null at rest.
    public enum Mark { None, Accent, Grey }

    public static Mark Fill(bool selected, bool pressed, Pane pane, Pane focus, bool windowActive)
    {
        if (selected) return Emphasized(pane, focus, windowActive) ? Mark.Accent : Mark.Grey;
        return pressed ? Mark.Grey : Mark.None;
    }

    /// The window opens with the sidebar holding the focus (`MacSelection.focus = .sidebar`).
    public const Pane FirstFocus = Pane.Sidebar;

    // ------------------------------------------------------------------ the page bar (MacWindow.pageBar)

    /// The page title (`MacType.pageTitle`, headline): 15 in the Desktop Look, 17 in the iOS look; semibold in both.
    public static double PageTitleSize(bool desktopLook) => desktopLook ? 15 : 17;
    public const int PageTitleWeight = 600;

    /// The grey line under a title (`MacWindow.pageSubtitle`, footnote): 12.5 in the Desktop Look, 13 in the iOS look.
    public static double PageSubtitleSize(bool desktopLook) => desktopLook ? 12.5 : 13;

    /// The bar draws no line under it (`bar.shadowColor = .clear`); its ground is the page's own colour.
    public const bool BarHairline = false;

    /// A bar glyph (`DesktopBars.glyphSize`), an item's height and least width, and the room either side of its glyph
    /// (`BarItemButton.sizeThatFits` without the glass).
    public const double BarGlyph = 15, BarItem = 44, BarItemGlyphSide = 6;

    /// The page's side (`MacInset.side`): the title starts this far in, and the last glyph ends this far from the edge.
    public const double PageSide = 20;

    /// The bar's padding after its trailing item: the item's own room round its glyph counts toward the page's side.
    public static double BarTrailingPad => Math.Max(0, PageSide - (BarItem - BarGlyph) / 2);

    /// The Catalyst bar's height (UINavigationBar's standard 50 on the iPad idiom the Mac app runs as; the Swift sets
    /// none of its own). The Windows bar is a row in the page, at least this tall.
    public const double BarHeight = 50;

    /// [WIN-50] Which places take the page bar: every page but a chat (`MacWindow.pageBar`'s one guard,
    /// `page is ChatViewController`). A page that sets its own bar keeps it, with the title token folded in (`titleToken`),
    /// so every page title is one size and weight whoever drew the bar.
    public static bool TakesPageBar(string place) => place is not ("chat" or "group-room");

    /// [WIN-50] The pages Windows draws through Shell/PageBar, by place id, and the file whose bar does it (a host draws
    /// several: InsightsPage for Usage, Spawn Tree, Star Map, Tiles and Status and Maintenance; StackHost for
    /// Capabilities and the Marketplace; PageHost for Bot Profiles, Messaging, Webhooks and Import Sessions).
    public static readonly IReadOnlyDictionary<string, string> PageBarSources = new Dictionary<string, string>
    {
        ["sessions"] = "Pages/SessionsPage.xaml.cs",
        ["tasks"] = "Features/Tasks/TasksPage.cs",
        ["jobs"] = "Features/Jobs/JobsPage.cs",
        ["artifacts"] = "Features/Artifacts/ArtifactsPage.cs",
        ["files"] = "Features/Workspace/WorkspaceListPage.cs",
        ["review"] = "Features/Workspace/WorkspaceListPage.cs",
        ["terminal"] = "Features/Workspace/TerminalPage.cs",
        ["kanban"] = "Features/Kanban/KanbanPage.cs",
        ["tiles"] = "Features/Insights/InsightsKit.cs",
        ["command-center"] = "Features/Insights/InsightsKit.cs",
        ["usage"] = "Features/Insights/InsightsKit.cs",
        ["spawn-tree"] = "Features/Insights/InsightsKit.cs",
        ["star-map"] = "Features/Insights/InsightsKit.cs",
        ["capabilities"] = "Features/Capabilities/StackHost.cs",
        ["marketplace"] = "Features/Capabilities/StackHost.cs",
        ["profiles"] = "Features/BotPages/PageHost.cs",
        ["messaging"] = "Features/BotPages/PageHost.cs",
        ["webhooks"] = "Features/BotPages/PageHost.cs",
        ["import-sessions"] = "Features/BotPages/PageHost.cs",
        ["quick-actions"] = "Features/QuickActions/QuickActionsPage.cs",
    };

    /// The page's bar items, read leading to trailing as the Mac lays them out: the page's own order
    /// (`PageBarCapsule`: Filter · Search · Compose), then the magnifier moved to the trailing edge (`searchToEdge`).
    /// Items are named by their identifiers ("sessions.filter"); the magnifier is the one ending ".search".
    public static IReadOnlyList<string> BarOrder(IEnumerable<string> pageOrder)
    {
        var items = pageOrder.ToList();
        var search = items.FindIndex(i => i.EndsWith(".search", StringComparison.Ordinal));
        if (search < 0 || search == items.Count - 1) return items;
        var magnifier = items[search];
        items.RemoveAt(search);
        items.Add(magnifier);
        return items;
    }
}
