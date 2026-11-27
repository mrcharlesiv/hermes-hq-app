namespace Hermes.Core.Sessions;

/// One way of drawing the row under Sessions' bar (the Mac's `macRowContent(switchIcons:countWords:menuPicture:)`).
public sealed record SessionsHeaderVariant(bool SwitchIcons, bool CountWords, bool MenuPicture)
{
    /// The gap between the row's items (`HStack(spacing: countWords ? 8 : 6)`).
    public double Spacing => CountWords ? SessionsHeaderRow.WordsSpacing : SessionsHeaderRow.TightSpacing;
    /// A count's room either side of its mark and number (`.padding(.horizontal, words ? 6 : 4)`).
    public double CountPadding => CountWords ? SessionsHeaderRow.CountPadWords : SessionsHeaderRow.CountPadTight;
    /// A switch side's room either side of its glyph and name (`.padding(.horizontal, macIcons ? 8 : 7)`).
    public double SwitchPadding => SwitchIcons ? SessionsHeaderRow.SwitchPadIcons : SessionsHeaderRow.SwitchPadWords;
}

/// Where the row's items go in a row `Width` wide: the switch at 0, the menu and the counts after it.
public sealed record SessionsHeaderPlacement(double? SwitchX, double? MenuX, double MenuWidth, IReadOnlyList<double> CountXs, double Width);

/// [WIN-SESSIONS-WORKING-CHIP] The row under Sessions' bar (Chats | Projects, the All Bots / All Projects menu, then the
/// New and Working counts), from the shipping Mac at 93f984bb1 App/Sessions/SessionsHeaderView.swift `macRow`:
///   - `ViewThatFits(in: .horizontal)` over four drawings, the first whose ideal width fits the row wins, else the last:
///     (1) the switch's glyphs and the counts' words ("● 1 working"); (2) the counts as a mark and a number ("● 1");
///     (3) the switch's names without their glyphs; (4) the menu without its picture. Nothing is cut at the pane's edge
///     (owner 2026-11-19: "1 new" had been cut at the right); only the last drawing's menu name gives way.
///   - `macRowContent`: `HStack(spacing: countWords ? 8 : 6)` of the switch (`fixedSize`), a `Spacer(minLength: 0)`,
///     the menu (`layoutPriority(1)`, at least 64 wide: `frame(minWidth: 64)`, its name cut at the tail) and the counts
///     (`fixedSize`). The spacer is an item of the stack, so the gap stands either side of it.
///   - `SessionsMacControl`: one height (24 × UI Scale), one corner (6), the footnote type, medium.
///   - `macStatus`: the mark, 5, the words; 6 either side (4 for a number alone); a fill only while picked.
///   - `SessionsPillsSwitch.macBody`: 2 round the two sides, each 8 either side of its 11 pt glyph, 4, its name (7 and
///     no glyph in a narrow pane); the side shown a 4-corner box of the label at 12 %.
///   - The row's edges: its left edge on the rows' (`DesktopRows.gutter`); on the right a count's words end where the
///     rows' times do (the gutter less a count's 6), or with no count after it the menu's box stands as far in as the
///     switch's (`menuEndsRow`). On a project's page the counts are the page header's, not the row's.
/// Windows draws Mac points as its own layout units (UI Scale is one transform over the window).
public static class SessionsHeaderRow
{
    public const double WordsSpacing = 8, TightSpacing = 6;
    public const double CountPadWords = 6, CountPadTight = 4;
    /// From a count's mark to its words.
    public const double CountMarkGap = 5;
    public const double SwitchPadIcons = 8, SwitchPadWords = 7;
    /// The switch's track round its two sides, and a side's glyph to its name.
    public const double SwitchTrack = 2, SwitchGlyphGap = 4, SwitchGlyph = 11;
    /// The controls' height before UI Scale (`SessionsMacControl.height`, `HQFont.scaled(24)`) and their corner.
    public const double ControlHeight = 24, ControlRadius = 6;
    /// The side shown in the switch: the track's corner less its 2.
    public const double SwitchThumbRadius = ControlRadius - SwitchTrack;
    /// The menu's least width (`frame(minWidth: 64)`: never just its arrows).
    public const double MenuMinWidth = 64;
    /// `MacPopUpInsets`: 12 before the words (9 before a picture), 10 after the chevron, 8 from the words to it.
    public const double MenuLeading = 12, MenuLeadingPicture = 9, MenuTrailing = 10, MenuChevronGap = 8, MenuChevron = 9;
    /// The marks: New's 8 pt dot; Working's 12 pt still quarter ring, 2 wide, on the label at 25 %.
    public const double NewDot = 8, WorkingMark = 12, WorkingMarkLine = 2, WorkingMarkTrack = 0.25;
    /// The share of the label colour the switch's shown side is filled with.
    public const double SwitchThumbShare = 0.12;
    /// The menu's outline.
    public const double MenuStroke = 1;
    /// The row's top room (6 in the Desktop Look, 4 in the iOS look) and foot room (8).
    public static double Top(bool desktopLook) => desktopLook ? 6 : 4;
    public const double Bottom = 8;

    /// The footnote size the controls' words take (`Font.hq(.footnote)`): 12.5 in the Desktop Look, 13 in the iOS look.
    public static double FontSize(bool desktopLook) => desktopLook ? 12.5 : 13;
    /// The switch and the menu are medium; a count is regular, semibold while picked.
    public const int ControlWeight = 500, CountWeight = 400, CountPickedWeight = 600;

    /// The four drawings, in the Mac's order.
    public static readonly IReadOnlyList<SessionsHeaderVariant> Variants =
    [
        new(SwitchIcons: true, CountWords: true, MenuPicture: true),
        new(SwitchIcons: true, CountWords: false, MenuPicture: true),
        new(SwitchIcons: false, CountWords: false, MenuPicture: true),
        new(SwitchIcons: false, CountWords: false, MenuPicture: false),
    ];

    /// A count's words: "1 working" / "3 new", or the number alone.
    public static string CountText(SessionStatusChip chip, int count, bool words) =>
        words ? $"{count} {(chip == SessionStatusChip.New ? "new" : "working")}" : $"{count}";

    /// Whether the counts stand on the row: not on a project's page (that page's header says them).
    public static bool ShowsCounts(bool onPage) => !onPage;

    /// [popup-room] The menu's box ends the row: no count after it.
    public static bool MenuEndsRow(bool hasMenu, bool onPage, int shownCounts) => hasMenu && (onPage || shownCounts == 0);

    /// The row's room inside the list's own edges: left on the rows' leading edge; right on the rows' trailing edge
    /// less a count's 6 (the count's words then end where the rows' times do), or on it when the menu ends the row.
    /// `rowInset` is how far in from the list's edges the rows' content starts (on Windows the rows' own padding).
    public static (double Leading, double Trailing) Insets(double rowInset, bool menuEndsRow) =>
        (rowInset, Math.Max(0, rowInset - (menuEndsRow ? 0 : CountPadWords)));

    /// The stack's items: the switch (when shown), the spacer, the menu (when shown), the counts.
    private static int Items(double? switchWidth, double? menuWidth, int counts) =>
        (switchWidth != null ? 1 : 0) + 1 + (menuWidth != null ? 1 : 0) + counts;

    /// A drawing's ideal width: every item at its own width, the spacer at none, the gap between each two.
    public static double IdealWidth(double? switchWidth, double? menuWidth, IReadOnlyList<double> counts, double spacing) =>
        (switchWidth ?? 0) + (menuWidth ?? 0) + counts.Sum() + spacing * (Items(switchWidth, menuWidth, counts.Count) - 1);

    /// `ViewThatFits`: the first drawing whose ideal width fits `available`, else the last.
    public static int Pick(IReadOnlyList<double> ideals, double available)
    {
        if (ideals.Count == 0) return 0;
        if (!double.IsFinite(available)) return 0;
        for (var i = 0; i < ideals.Count; i++)
            if (ideals[i] <= available + 0.5) return i;
        return ideals.Count - 1;
    }

    /// The picked drawing laid out across `width`: the switch at the left, then the spacer takes what is left over, so
    /// the menu and the counts stand at the right. The menu is offered the room first (`layoutPriority(1)`): its whole
    /// width when it fits, else what the fixed items leave it, never under 64.
    public static SessionsHeaderPlacement Place(double width, double? switchWidth, double? menuIdeal, IReadOnlyList<double> counts, double spacing)
    {
        var gaps = spacing * (Items(switchWidth, menuIdeal, counts.Count) - 1);
        var fixedWidth = (switchWidth ?? 0) + counts.Sum() + gaps;
        double menuWidth = 0;
        if (menuIdeal is { } ideal)
            menuWidth = Math.Max(Math.Min(MenuMinWidth, ideal), Math.Min(ideal, Math.Max(0, width - fixedWidth)));
        var spacer = Math.Max(0, width - fixedWidth - menuWidth);
        double x = 0;
        double? switchX = null, menuX = null;
        if (switchWidth is { } sw) { switchX = 0; x = sw + spacing; }
        x += spacer + spacing;   // the spacer and the gap after it
        if (menuIdeal != null) { menuX = x; x += menuWidth + spacing; }
        var xs = new List<double>();
        foreach (var c in counts) { xs.Add(x); x += c + spacing; }
        var used = (switchWidth ?? 0) + spacer + menuWidth + counts.Sum() + gaps;
        return new SessionsHeaderPlacement(switchX, menuX, menuWidth, xs, used);
    }

    /// A count's ideal width: its mark, 5, its words, the padding either side.
    public static double CountWidth(SessionStatusChip chip, double wordsWidth, bool words) =>
        2 * (words ? CountPadWords : CountPadTight) + (chip == SessionStatusChip.New ? NewDot : WorkingMark) + CountMarkGap + wordsWidth;

    /// The switch's ideal width from its two names' widths.
    public static double SwitchWidth(double firstName, double secondName, bool icons)
    {
        double Side(double name) => 2 * (icons ? SwitchPadIcons : SwitchPadWords) + (icons ? SwitchGlyph + SwitchGlyphGap : 0) + name;
        return 2 * SwitchTrack + Side(firstName) + Side(secondName);
    }

    /// The menu's ideal width from its name's (and its picture's) width: never under 64.
    public static double MenuWidth(double nameWidth, double? pictureWidth) =>
        Math.Max(MenuMinWidth, (pictureWidth is { } p ? MenuLeadingPicture + p + 6 : MenuLeading) + nameWidth + MenuChevronGap + MenuChevron + MenuTrailing);
}
