using Hermes.Core.Shell;

namespace Hermes.Core.Kanban;

/// The board's columns in the space under the page bar, as the Mac lays them out
/// (App/Pages/Kanban/KanbanBoardView.swift `layoutSubviews`, 93f984bb1):
///   - the page's one side inset (`MacInset.side`, here `DesktopLook.PageSide`, which the page bar's title also starts
///     at), so the first column's edge stands under "Kanban" (the Mac's [Mac AAA 2026-11-16] fix);
///   - 10 between columns (`gap`), 4 over them, the side again under them;
///   - every column the same whole width, the room shared and floored (`rounded(.down)`), never under 212
///     (`narrowest`): narrower than that and the board scrolls sideways, with the side after the last column so it
///     can be scrolled fully into view;
///   - the columns' height is what is left, never negative (the Mac has no floor: a short window shortens the columns,
///     which scroll their own cards, rather than pushing them past the window's foot).
///
/// One calculation for the page (KanbanPage.SizeColumns) and its tests. The lengths are the page's own layout units.
/// UI Scale on Windows is a ScaleTransform over the whole window's content (ThemeService.ApplyScale): the page is laid
/// out at the window's width divided by the scale and drawn scaled, so 212 here is 212 × the scale on the screen, the
/// Mac's `HQFont.scaled(212)`, without scaling it twice. The Mac's side and gap don't follow UI Scale; on Windows they
/// do, with the page bar's, so the column still stands under the title. Windows' own text scaling (TextScaleFactor)
/// sizes text only, as Dynamic Type doesn't move the Mac's board either.
/// Right to left: the positions here are from the leading edge. WinUI's FlowDirection mirrors the panel and its scroll
/// for the page; the Mac mirrors by hand only because UIScrollView doesn't. Don't mirror them again.
public static class KanbanBoardGeometry
{
    /// Between two columns (`KanbanBoardView.gap`).
    public const double Gap = 10;
    /// Over the columns, under the page bar.
    public const double Top = 4;
    /// The narrowest a column gets before the board scrolls sideways (`narrowest`, before UI Scale).
    public const double Narrowest = 212;
    /// Either side of the columns and under them: the page's side (`KanbanBoardView.margin` = `MacInset.side`).
    public static double Side => DesktopLook.PageSide;

    /// The columns for a viewport `width` × `height` (the board's scroller) holding `count` columns.
    public static KanbanBoardLayout Fit(double width, double height, int count)
    {
        var w = Length(width);
        var h = Length(height);
        var columnHeight = Math.Max(0, h - Top - Side);
        if (count <= 0) return new KanbanBoardLayout(0, 0, columnHeight, w, w);
        var room = w - Side * 2 - Gap * (count - 1);
        var columnWidth = Math.Max(Narrowest, Math.Floor(room / count));
        var total = Side * 2 + columnWidth * count + Gap * (count - 1);
        return new KanbanBoardLayout(count, columnWidth, columnHeight, total, w);
    }

    /// A measured length the layout can use: a collapsed, unmeasured or nonsense size is none.
    private static double Length(double value) => double.IsFinite(value) && value > 0 ? value : 0;
}

/// Where the board's columns go. `ContentWidth` is the columns with the side either end; the scroller's extent is the
/// larger of it and the `Viewport`.
public readonly record struct KanbanBoardLayout(int Count, double ColumnWidth, double ColumnHeight, double ContentWidth, double Viewport)
{
    /// The extent the board's scroller holds (the Mac's `contentSize.width`).
    public double Extent => Math.Max(ContentWidth, Viewport);

    /// True when the columns don't all fit and the board scrolls sideways.
    public bool Scrolls => ContentWidth > Viewport;

    /// The farthest the board scrolls sideways (0 when everything fits).
    public double MostOffset => Math.Max(0, Extent - Viewport);

    /// Column `index`'s leading edge, from the board's leading edge.
    public double Leading(int index) => KanbanBoardGeometry.Side + index * (ColumnWidth + KanbanBoardGeometry.Gap);

    /// Column `index`'s trailing edge.
    public double Trailing(int index) => Leading(index) + ColumnWidth;

    /// The column's x on a right-to-left board drawn by hand (the Mac's `total - x - width`). WinUI pages don't need it:
    /// FlowDirection does it. Kept to check the two agree.
    public double MirroredLeading(int index) => ContentWidth - Leading(index) - ColumnWidth;
}
