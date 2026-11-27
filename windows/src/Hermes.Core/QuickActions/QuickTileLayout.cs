using Hermes.Core.Bots;

namespace Hermes.Core.QuickActions;

/// One cell of a row: the cell's index in the page's order, the grid column it starts in and how many it spans.
public sealed record QuickTileSlot(int Index, int Column, int Span);

/// One row of the page's grid: `Columns` equal (star) grid columns, its slots left to right.
public sealed record QuickTileRow(int Columns, IReadOnlyList<QuickTileSlot> Slots);

/// The page's grid for one width and text size. `Side` is the tiles' edge from the page's, `Gap` both between two tiles
/// in a row and between two rows.
public sealed record QuickTileLayoutPlan(bool Stacked, double Side, double Top, double Bottom, double Gap, double AddMinHeight,
    IReadOnlyList<QuickTileRow> Rows);

/// [WIN-QUICK-GRID] The Quick Actions grid as the Mac lays it out (App/QuickActions/QuickActionsViewController.swift
/// `section(_:)`, `stacked`, `gap`, `configureAdd`, 93f984bb1):
///   - two columns: a small tile takes one, a Wide tile both; a small tile alone before a Wide one keeps its own row at
///     half the width (the Mac's row is only as wide as its tiles, leading), and the order never changes
///     (QuickTileGrid.Rows). The ＋ Add Action cell is always small;
///   - stacked at accessibility text sizes: one full-width column, every cell its own row, Add included;
///   - the side is 16, 24 once the page is wider than 700 (`max(16, width > 700 ? 24 : 16)`), 12 over the tiles and 24
///     under them; the text size never moves it;
///   - the gap is 12 and the ＋ tile at least 104 tall, both scaled with the text (`HQFont.scaled`).
///
/// Windows' text size is `UISettings.TextScaleFactor` (Settings › Accessibility › Text size, 1.0–2.25). The Mac stacks
/// from AX3, which is about 235 % of the default body and so past Windows' largest size; Windows stacks at the app's one
/// accessibility-size threshold instead (UndoPillClock.AccessibilityTextScale, 150 %, iOS's AX1 being about 165 %),
/// the size at which the Mac also drops the empty state's picture. Lengths are the page's layout units (UI Scale is a
/// transform over the whole window, so it isn't applied here).
public static class QuickTileLayout
{
    /// Wider than this, the page's side is 24 (else 16).
    public const double Breakpoint = 700;
    public const double NarrowSide = 16;
    public const double WideSide = 24;
    public const double Top = 12;
    public const double Bottom = 24;
    public const double BaseGap = 12;
    public const double BaseAddHeight = 104;
    /// Windows' text-size range.
    public const double SmallestScale = 1.0, LargestScale = 2.25;

    /// Whether this text size lays the tiles out in one column, the face's words beside its icon.
    public static bool StackedAt(double textScaleFactor) => UndoPillClock.AccessibilityTextScale(Scale(textScaleFactor));

    /// What decides the drawing apart from the tiles themselves: a resize or a text-size change that keeps the key
    /// keeps the tiles as they are (no rebuild, no lost focus).
    public static (bool Stacked, double Side, double Gap) Key(double width, double textScaleFactor) =>
        (StackedAt(textScaleFactor), Side(width), Gap(textScaleFactor));

    public static QuickTileLayoutPlan Fit(IReadOnlyList<QuickTile> cells, double width, double textScaleFactor)
    {
        var stacked = StackedAt(textScaleFactor);
        var rows = new List<QuickTileRow>();
        foreach (var row in QuickTileGrid.Rows(cells, stacked ? 1 : 2))
        {
            if (stacked) { rows.Add(new QuickTileRow(1, [new QuickTileSlot(row[0], 0, 1)])); continue; }
            var slots = new List<QuickTileSlot>();
            var column = 0;
            foreach (var index in row)
            {
                var span = cells[index].Wide ? 2 : 1;
                slots.Add(new QuickTileSlot(index, column, span));
                column += span;
            }
            rows.Add(new QuickTileRow(2, slots));
        }
        return new QuickTileLayoutPlan(stacked, Side(width), Top, Bottom, Gap(textScaleFactor),
            BaseAddHeight * Scale(textScaleFactor), rows);
    }

    private static double Side(double width) => double.IsFinite(width) && width > Breakpoint ? WideSide : NarrowSide;

    private static double Gap(double textScaleFactor) => BaseGap * Scale(textScaleFactor);

    /// The text size within Windows' range; an unreadable one is the default.
    private static double Scale(double textScaleFactor) =>
        double.IsFinite(textScaleFactor) ? Math.Clamp(textScaleFactor, SmallestScale, LargestScale) : SmallestScale;
}
