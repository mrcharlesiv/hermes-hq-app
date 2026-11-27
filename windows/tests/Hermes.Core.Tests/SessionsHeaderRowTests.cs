using Hermes.Core.Sessions;
using Hermes.Core.Settings;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-SESSIONS-WORKING-CHIP] The row under Sessions' bar as the Mac lays it out (93f984bb1
/// App/Sessions/SessionsHeaderView.swift `macRow`, `macRowContent`, `macStatus`, `SessionsPillsSwitch.macBody`,
/// `SessionsMacControl`; App/Settings/Config/MacForm.swift `MacPopUpInsets`). Word widths are stand-ins of the right size.
public class SessionsHeaderRowTests
{
    // Stand-in word widths at the footnote size: "Chats", "Projects", "All Bots", "1 working", "1".
    private const double Chats = 31, Projects = 49, AllBots = 46, OneWorking = 55, One = 7;

    /// The list's row room on Windows at a list `pane` wide: its 12 / 8 padding, the rows' 6 at the left, and at the
    /// right the rows' 6 less a count's 6.
    private static double Room(double pane) =>
        pane - 12 - 8 - SessionsHeaderRow.Insets(6, menuEndsRow: false).Leading - SessionsHeaderRow.Insets(6, menuEndsRow: false).Trailing;

    private static (double Switch, double Menu, double Count) Parts(SessionsHeaderVariant v) =>
        (SessionsHeaderRow.SwitchWidth(Chats, Projects, v.SwitchIcons), SessionsHeaderRow.MenuWidth(AllBots, null),
         SessionsHeaderRow.CountWidth(SessionStatusChip.Working, v.CountWords ? OneWorking : One, v.CountWords));

    private static List<double> Ideals() => [.. SessionsHeaderRow.Variants.Select(v =>
    {
        var (s, m, c) = Parts(v);
        return SessionsHeaderRow.IdealWidth(s, m, [c], v.Spacing);
    })];

    [Fact]
    public void TheMacsNumbers()
    {
        Assert.Equal(24, SessionsHeaderRow.ControlHeight);
        Assert.Equal(6, SessionsHeaderRow.ControlRadius);
        Assert.Equal(4, SessionsHeaderRow.SwitchThumbRadius);
        Assert.Equal(64, SessionsHeaderRow.MenuMinWidth);
        Assert.Equal(12.5, SessionsHeaderRow.FontSize(desktopLook: true));
        Assert.Equal(13, SessionsHeaderRow.FontSize(desktopLook: false));
        // Four drawings, in ViewThatFits' order: the counts' words go first, then the switch's glyphs, then the picture.
        Assert.Equal(
            [(true, true, true), (true, false, true), (false, false, true), (false, false, false)],
            SessionsHeaderRow.Variants.Select(v => (v.SwitchIcons, v.CountWords, v.MenuPicture)).ToList());
        Assert.Equal([8.0, 6, 6, 6], SessionsHeaderRow.Variants.Select(v => v.Spacing).ToList());
        Assert.Equal([6.0, 4, 4, 4], SessionsHeaderRow.Variants.Select(v => v.CountPadding).ToList());
        Assert.Equal([8.0, 8, 7, 7], SessionsHeaderRow.Variants.Select(v => v.SwitchPadding).ToList());
        // A count: 6 + the 12 pt working ring + 5 + "1 working" + 6; the number alone keeps 4 either side.
        Assert.Equal(84, SessionsHeaderRow.CountWidth(SessionStatusChip.Working, OneWorking, words: true));
        Assert.Equal(32, SessionsHeaderRow.CountWidth(SessionStatusChip.Working, One, words: false));
        Assert.Equal(28, SessionsHeaderRow.CountWidth(SessionStatusChip.New, One, words: false));
        // The switch: 2 round both sides, each 8 + 11 glyph + 4 + name + 8 (7 + name + 7 without the glyph).
        Assert.Equal(146, SessionsHeaderRow.SwitchWidth(Chats, Projects, icons: true));
        Assert.Equal(112, SessionsHeaderRow.SwitchWidth(Chats, Projects, icons: false));
        // The menu: 12 + name + 8 + 9 chevron + 10; never under 64.
        Assert.Equal(85, SessionsHeaderRow.MenuWidth(AllBots, null));
        Assert.Equal(64, SessionsHeaderRow.MenuWidth(10, null));
        Assert.Equal("1 working", SessionsHeaderRow.CountText(SessionStatusChip.Working, 1, words: true));
        Assert.Equal("3 new", SessionsHeaderRow.CountText(SessionStatusChip.New, 3, words: true));
        Assert.Equal("1", SessionsHeaderRow.CountText(SessionStatusChip.Working, 1, words: false));
    }

    [Fact]
    public void TheSpacerIsAnItemOfTheStack()
    {
        // switch, spacer, menu, one count: three gaps.
        Assert.Equal(146 + 85 + 84 + 3 * 8, SessionsHeaderRow.IdealWidth(146, 85, [84], 8));
        // No switch: the spacer still stands before the menu, so a gap still does.
        Assert.Equal(85 + 84 + 2 * 8, SessionsHeaderRow.IdealWidth(null, 85, [84], 8));
        // No counts: switch, spacer, menu.
        Assert.Equal(146 + 85 + 2 * 6, SessionsHeaderRow.IdealWidth(146, 85, [], 6));
    }

    [Fact]
    public void ViewThatFitsTakesTheFirstThatFitsElseTheLast()
    {
        Assert.Equal(0, SessionsHeaderRow.Pick([100, 80, 60, 50], 100));
        Assert.Equal(1, SessionsHeaderRow.Pick([101, 80, 60, 50], 100));
        Assert.Equal(3, SessionsHeaderRow.Pick([101, 101, 101, 101], 100));
        Assert.Equal(0, SessionsHeaderRow.Pick([], 100));
    }

    /// The window in the report (1028 px, the list 360): "● 1 working" no longer fits, so the Mac says "● 1" with the
    /// switch's glyphs, and every item stands whole inside the row.
    [Fact]
    public void AtTheReportedWidthTheCountSaysItsNumberWhole()
    {
        var room = Room(360);
        Assert.Equal(334, room);
        var ideals = Ideals();
        Assert.Equal(339, ideals[0]);   // what the old row asked: 5 more than it had, so the count was cut
        var pick = SessionsHeaderRow.Pick(ideals, room);
        Assert.Equal(1, pick);
        var v = SessionsHeaderRow.Variants[pick];
        var (s, m, c) = Parts(v);
        var place = SessionsHeaderRow.Place(room, s, m, [c], v.Spacing);
        Assert.Equal(0.0, place.SwitchX!.Value);
        Assert.Equal(m, place.MenuWidth);
        // The count ends on the row's right edge, the menu one gap before it, the spare room between switch and menu.
        Assert.Equal(room, place.CountXs[0] + c, 6);
        Assert.Equal(place.CountXs[0] - v.Spacing - m, place.MenuX!.Value, 6);
        Assert.True(place.MenuX > s + v.Spacing);
        Assert.Equal(room, place.Width, 6);
    }

    /// The narrowest list (its 280 least width): the switch says its names without glyphs, and still nothing is cut.
    [Fact]
    public void AtTheNarrowestListTheSwitchDropsItsGlyphs()
    {
        var room = Room(280);
        Assert.Equal(254, room);
        var ideals = Ideals();
        Assert.Equal(2, SessionsHeaderRow.Pick(ideals, room));
        var v = SessionsHeaderRow.Variants[2];
        var (s, m, c) = Parts(v);
        Assert.True(SessionsHeaderRow.IdealWidth(s, m, [c], v.Spacing) <= room);
        var place = SessionsHeaderRow.Place(room, s, m, [c], v.Spacing);
        Assert.Equal(room, place.CountXs[0] + c, 6);
        Assert.Equal(m, place.MenuWidth);
    }

    /// Too narrow for any drawing: the last one, its counts whole at the right edge, only the menu's name cut (never
    /// under 64).
    [Fact]
    public void TooNarrowTheMenuGivesWayFirst()
    {
        var v = SessionsHeaderRow.Variants[^1];
        var (s, m, c) = Parts(v);
        var room = 230.0;
        Assert.Equal(3, SessionsHeaderRow.Pick(Ideals(), room));
        var place = SessionsHeaderRow.Place(room, s, m, [c], v.Spacing);
        Assert.Equal(room - s - c - 3 * v.Spacing, place.MenuWidth, 6);
        Assert.True(place.MenuWidth < m);
        Assert.Equal(room, place.CountXs[0] + c, 6);
        // Narrower still: the menu keeps its 64 and the row runs past the room (the Mac's minWidth), counts still whole.
        var tight = SessionsHeaderRow.Place(200, s, m, [c], v.Spacing);
        Assert.Equal(64, tight.MenuWidth);
        Assert.True(tight.Width > 200);
    }

    [Fact]
    public void TheRowsEdges()
    {
        // With a count after the menu, the count's words end on the rows' (6 in) edge: the row stops 6 short of it.
        Assert.Equal((6.0, 0.0), SessionsHeaderRow.Insets(6, menuEndsRow: false));
        // With the menu last, its box stands as far in as the switch's.
        Assert.Equal((6.0, 6.0), SessionsHeaderRow.Insets(6, menuEndsRow: true));
        Assert.True(SessionsHeaderRow.MenuEndsRow(hasMenu: true, onPage: false, shownCounts: 0));
        Assert.True(SessionsHeaderRow.MenuEndsRow(hasMenu: true, onPage: true, shownCounts: 2));
        Assert.False(SessionsHeaderRow.MenuEndsRow(hasMenu: true, onPage: false, shownCounts: 1));
        Assert.False(SessionsHeaderRow.ShowsCounts(onPage: true));
        Assert.True(SessionsHeaderRow.ShowsCounts(onPage: false));
        Assert.Equal(6, SessionsHeaderRow.Top(desktopLook: true));
        Assert.Equal(4, SessionsHeaderRow.Top(desktopLook: false));
    }

    /// The line at a working row's right edge is the Working Ring (`WorkingArc.rowLine` / `rowCorner`).
    [Fact]
    public void TheWorkingRowsRing()
    {
        Assert.Equal(1.25, WorkingRing.RowLine);
        Assert.Equal(2, WorkingRing.RowCorner(desktopLook: true));
        Assert.Equal(14, WorkingRing.RowCorner(desktopLook: false));
    }
}
