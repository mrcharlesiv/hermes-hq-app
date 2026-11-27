namespace Hermes.Core.Shell;

/// [mac-layout] The sidebar's top, Search and New Chat (App/Mac/MacBotsRail.swift `MacSidebarTools` at 93f984bb1, sizes
/// from App/Mac/SidebarType.swift `current`). Search is a button, not a field: a click opens Open Quickly exactly as
/// Ctrl+K does (the Mac sends KeyCommands.openQuickly). Open, it is a well (glass, "Search", the quiet "Ctrl+K") beside
/// New Chat's well; folded into the rail, named or not, the two are small quiet actions side by side on one line with a
/// hairline under them ([rail-actions]).
public static class SidebarSearch
{
    /// The tools' row (`mac-sidebar.tools`), Search (`mac-sidebar.search`) and New Chat (`mac-sidebar.compose`).
    public const string ToolsAutomationId = "shell.tools";
    public const string SearchAutomationId = "shell.search";
    public const string ComposeAutomationId = "shell.compose";

    /// What Narrator reads (the Mac's accessibilityLabel) and the word in the open well.
    public const string SearchName = "Search";
    public const string ComposeName = "New Chat";

    /// The quiet key after "Search": the Mac's "⌘K" is the same key here, Ctrl+K (ShellKeys.OpenQuickly).
    public static string SearchHint => ShellKeys.OpenQuickly.Display;

    /// "Search or jump to… (⌘K)" and "New Chat (⌘N)" with the Windows keys.
    public static string SearchToolTip => $"Search or jump to\u2026 ({SearchHint})";
    public static string ComposeToolTip => $"{ComposeName} ({ShellKeys.NewChat.Display})";

    /// The Mac draws the app at 77 %: its sidebar points times this are the points on the screen (SidebarType.swift).
    public const double MacScale = Settings.ChatVisualTokens.Dip;

    /// A Mac sidebar size as drawn on the screen, to the nearest half point.
    public static double OnScreen(double macPoints) => Math.Round(macPoints * MacScale * 2, MidpointRounding.AwayFromZero) / 2;

    /// "Search" (`SidebarType.current.search`, 17) and its "Ctrl+K" (`shortcut`, 14.5).
    public static double WordSize => Settings.ChatVisualTokens.SidebarSearch;
    public static double HintSize => Settings.ChatVisualTokens.SidebarSmall;

    /// The glyphs follow the ink the Mac draws, not the symbols' point sizes: an SF Symbol's image is about 1.2× its
    /// point size, while a Segoe Fluent glyph's ink is about its FontSize. Measured on 93f984bb1 in window points, the
    /// glass is 16×17 open and folded (13 pt medium at the large scale open, 13 pt folded) and New Chat's pencil 19
    /// open (15 pt) and 17 folded (13 pt). Each FontSize is that ink's longer side on the screen.
    public static double GlassSize => OnScreen(17);
    public static double ComposeGlyphSize(bool rail) => OnScreen(rail ? 17 : 19);
    public static double RailGlassSize => OnScreen(17);

    /// Open: both wells are 34 tall, New Chat's square; corners 9; 6 between them; 2 above and 6 below the row.
    public static double OpenSide => OnScreen(34);
    public static double WellCorner => OnScreen(9);
    public const double OpenGap = 6, OpenTop = 2, OpenBottom = 6;

    /// The hint ends 10 in from the well's edge, at least 6 after the word.
    public const double HintTrailing = 10, HintGap = 6;

    /// Folded: the Mac's 24 squares (18.5 on the screen) are under a pointer target here, so the rail keeps the open
    /// well's height as each button's target; the glyphs draw the Mac's ink (above). 1 either side of the centre (2
    /// apart), the hairline 7 under them, 2 in from their outer edges, then 8 before the places.
    public static double RailSide => OpenSide;
    public const double RailGap = 2, RuleGap = 7, RuleInset = 2, RuleBottom = 8;

    /// The wells: label ink at 6 % (light) or white at 8 % (dark), 10 % / 13 % under the pointer. A press dims the
    /// glass, the word and the hint to half, as the Mac's configurationUpdateHandler does.
    public static double WellAlpha(bool dark) => dark ? 0.08 : 0.06;
    public static double WellHoverAlpha(bool dark) => dark ? 0.13 : 0.10;
    public const double PressedInk = 0.5;

    /// The quiet hint (`MacSidebar.quietInk`: label at 50 %) and the rail's hairline (12 % light, 14 % dark).
    public const double QuietInk = 0.5;
    public static double RuleAlpha(bool dark) => dark ? 0.14 : 0.12;

    /// How the two sit: open, Search fills the row and New Chat is a square after it; folded (named rail or not), they
    /// are side by side, centred, with the hairline under them.
    public enum Arrangement { SearchThenCompose, SideBySideWithRule }

    public static Arrangement Layout(bool rail) => rail ? Arrangement.SideBySideWithRule : Arrangement.SearchThenCompose;

    /// The folded row's width: two targets and the gap; it fits the compact rail (64 less its 4 + 4 padding).
    public static double RailRowWidth => RailSide * 2 + RailGap;
}
