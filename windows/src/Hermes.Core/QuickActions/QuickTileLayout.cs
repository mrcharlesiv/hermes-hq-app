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

/// A rectangle in layout DIPs for the responsive 2D Bento engine (`QuickTileLayout.Placement.frame`).
public readonly record struct QuickTileRect(double X, double Y, double Width, double Height);

/// Inputs for the responsive 2–5 column 2D Bento engine (`QuickTileLayout.Metrics` in `QuickTiles.swift`).
public sealed record QuickTileBentoMetrics(
    double Width,
    double Gap,
    bool Stacked,
    double Scale = 1.0,
    double ActionTallHeight = 116,
    double ActionShortHeight = 58,
    double MiniHeight = 76,
    double SectionHeight = 32,
    double DashboardNameHeight = 22)
{
    public int Columns => QuickTileBento.Columns(Width, Gap, Stacked, Scale);

    public double ColumnWidth
    {
        get
        {
            var cols = Math.Max(1, Columns);
            return Math.Max(0, Math.Floor((Width - (cols - 1) * Gap) / cols));
        }
    }

    /// Square widget cell height (matches `FavoriteTileSize.picture` on phone; capped sensibly on ultra-wide screens).
    public double UnitHeight
    {
        get
        {
            if (Stacked) return Math.Max(0, Math.Floor((Width - Gap) / 2));
            if (Columns <= 2) return ColumnWidth;
            return Math.Min(ColumnWidth, Math.Floor(220 * Math.Max(1, Scale)));
        }
    }
}

/// One placed cell in the 2D Bento layout (`QuickTileLayout.Placement`).
public sealed record QuickTilePlacement(int Index, QuickTileRect Frame, bool FillsRow);

/// Full 2D Bento layout output (`QuickTileLayout.Result`).
public sealed record QuickTileBentoResult(
    IReadOnlyList<QuickTilePlacement> Placements,
    double TotalHeight,
    int Columns,
    double ColumnWidth,
    double UnitHeight);

/// Responsive 2–5 column 2D Bento layout engine (`QuickTileLayout` in `HermesKit/Intents/QuickTiles.swift`):
///   - 1 column at accessibility text sizes (`Stacked`), 2 columns under 620 DIP, 3–5 columns on wide screens;
///   - full-width collapsible `Section` header rows (+4 DIP breathing room above);
///   - dense `2 * Columns` Mini action strips (4–10 across);
///   - 2-subrow band packing beside 2-row widgets (`TallCard` 1×2, `Large` 2×2) when columns remain beside them;
///   - standard single-band rows keeping linear order and matching row heights across mixed action/widget rows.
public static class QuickTileBento
{
    /// Responsive column count: 1 when stacked, 2 under 620 DIP, 3–5 on wider screens.
    public static int Columns(double width, double gap, bool stacked, double scale = 1.0)
    {
        if (stacked) return 1;
        if (!double.IsFinite(width) || width < 620) return 2;
        var safeGap = double.IsFinite(gap) ? Math.Max(0, gap) : QuickTileLayout.BaseGap;
        var safeScale = double.IsFinite(scale) ? Math.Max(1, scale) : 1;
        var minCell = 200 * safeScale;
        return Math.Clamp((int)((width + safeGap) / (minCell + safeGap)), 2, 5);
    }

    /// Intrinsic height for a tile given `metrics` and its effective span.
    public static double NaturalHeight(QuickTile tile, QuickTileBentoMetrics metrics)
    {
        if (tile.Known is not { } kind) return tile.Short ? metrics.ActionShortHeight : metrics.ActionTallHeight;
        if (kind.IsSection()) return metrics.SectionHeight;
        var size = tile.EffectiveSize;
        if (size == QuickTileSize.Mini) return metrics.MiniHeight;
        if (kind.IsPicture())
        {
            var rows = size.RowSpan();
            var picHeight = rows * metrics.UnitHeight + (rows - 1) * metrics.Gap;
            return picHeight + metrics.DashboardNameHeight;
        }
        if (kind.IsLiveCard())
        {
            var rows = size.RowSpan();
            var baseH = Math.Max(metrics.UnitHeight, metrics.ActionTallHeight);
            return rows * baseH + (rows - 1) * metrics.Gap;
        }
        return tile.Short ? metrics.ActionShortHeight : metrics.ActionTallHeight;
    }

    /// Computes 2D placements for `tiles` (optionally including a trailing Small slot for `+ Add Action`).
    public static QuickTileBentoResult Compute(IReadOnlyList<QuickTile> tiles, QuickTileBentoMetrics metrics, bool hasAddTile = false)
    {
        var items = tiles.ToList();
        if (hasAddTile) items.Add(QuickTile.Create(QuickTileKind.Page, id: "__add__"));
        var cols = metrics.Columns;
        var colW = metrics.ColumnWidth;
        var gap = metrics.Gap;
        var unitH = metrics.UnitHeight;
        if (items.Count == 0 || !double.IsFinite(metrics.Width) || metrics.Width <= 0)
            return new QuickTileBentoResult([], 0, cols, colW, unitH);

        // Single-column accessibility layout: every tile spans full width.
        if (cols <= 1)
        {
            double sy = 0;
            var stackedOut = new List<QuickTilePlacement>(items.Count);
            for (var idx = 0; idx < items.Count; idx++)
            {
                var h = NaturalHeight(items[idx], metrics);
                stackedOut.Add(new QuickTilePlacement(idx, new QuickTileRect(0, sy, metrics.Width, h), false));
                sy += h + gap;
            }
            return new QuickTileBentoResult(stackedOut, Math.Max(0, sy - gap), 1, metrics.Width, unitH);
        }

        double ItemWidth(int colSpan)
        {
            var clamped = Math.Clamp(colSpan, 1, cols);
            return clamped == cols ? metrics.Width : clamped * colW + (clamped - 1) * gap;
        }
        double ItemX(int col) => col * (colW + gap);

        var placements = new List<QuickTilePlacement>(items.Count);
        double y = 0;
        var i = 0;

        while (i < items.Count)
        {
            var first = items[i];

            // 1. Section Header: full-width divider row.
            if (first.Known == QuickTileKind.Section)
            {
                var h = metrics.SectionHeight;
                if (y > 0) y += 4;
                placements.Add(new QuickTilePlacement(i, new QuickTileRect(0, y, metrics.Width, h), false));
                y += h + gap;
                i++;
                continue;
            }

            // 2. Mini Strip: pack consecutive mini tiles into dense 2*cols rows (4 across on narrow, 6–10 on desktop).
            if (first.EffectiveSize == QuickTileSize.Mini)
            {
                var miniCols = cols * 2;
                var miniGap = Math.Min(gap, 10);
                var miniW = Math.Max(0, Math.Floor((metrics.Width - (miniCols - 1) * miniGap) / miniCols));
                var col = 0;
                while (i < items.Count && items[i].EffectiveSize == QuickTileSize.Mini)
                {
                    var x = col * (miniW + miniGap);
                    placements.Add(new QuickTilePlacement(i, new QuickTileRect(x, y, miniW, metrics.MiniHeight), false));
                    i++;
                    col++;
                    if (col == miniCols)
                    {
                        col = 0;
                        y += metrics.MiniHeight + miniGap;
                    }
                }
                if (col > 0) y += metrics.MiniHeight + gap;
                else y += gap - miniGap;
                continue;
            }

            // 3. Multi-row 2D band: if a 2-row item leaves open columns beside it, pack row-1 items into 2 subrows beside it.
            var firstSpan = first.EffectiveSize.ColSpan(cols);
            var firstRows = first.EffectiveSize.RowSpan();

            if (firstRows == 2 && firstSpan < cols)
            {
                var grid = new bool[2, cols];
                var baseUnit = Math.Max(unitH, metrics.ActionTallHeight);
                var picBonus = first.Known?.IsPicture() == true ? metrics.DashboardNameHeight : 0;
                var subH = baseUnit + picBonus / 2.0;
                var bandH = subH * 2 + gap;
                var bandHasPicture = first.Known?.IsPicture() == true;

                (int Col, int Row)? FindSpot(int cSpan, int rSpan)
                {
                    for (var r = 0; r <= 2 - rSpan; r++)
                    {
                        for (var c = 0; c <= cols - cSpan; c++)
                        {
                            var free = true;
                            for (var rr = r; rr < r + rSpan && free; rr++)
                                for (var cc = c; cc < c + cSpan; cc++)
                                    if (grid[rr, cc]) { free = false; break; }
                            if (free) return (c, r);
                        }
                    }
                    return null;
                }

                bool BandFull()
                {
                    for (var r = 0; r < 2; r++)
                        for (var c = 0; c < cols; c++)
                            if (!grid[r, c]) return false;
                    return true;
                }

                var bandEntries = new List<(int Index, int Col, int Row, int CSpan, int RSpan, bool IsPicture)>();
                while (i < items.Count)
                {
                    var tile = items[i];
                    if (tile.Known == QuickTileKind.Section || tile.EffectiveSize == QuickTileSize.Mini) break;
                    var cSpan = tile.EffectiveSize.ColSpan(cols);
                    var rSpan = tile.EffectiveSize.RowSpan();
                    if (FindSpot(cSpan, rSpan) is not { } spot) break;
                    for (var rr = spot.Row; rr < spot.Row + rSpan; rr++)
                        for (var cc = spot.Col; cc < spot.Col + cSpan; cc++)
                            grid[rr, cc] = true;
                    if (tile.Known?.IsPicture() == true) bandHasPicture = true;
                    bandEntries.Add((i, spot.Col, spot.Row, cSpan, rSpan, tile.Known?.IsPicture() == true));
                    i++;
                    if (BandFull()) break;
                }

                foreach (var entry in bandEntries)
                {
                    var w = ItemWidth(entry.CSpan);
                    var h = entry.RSpan == 2 ? bandH : subH;
                    var fy = y + entry.Row * (subH + gap);
                    placements.Add(new QuickTilePlacement(
                        entry.Index,
                        new QuickTileRect(ItemX(entry.Col), fy, w, h),
                        bandHasPicture && !entry.IsPicture));
                }
                y += bandH + gap;
                continue;
            }

            // 4. Standard single-band row: fill columns left-to-right without jumping past wider items.
            var rowItems = new List<(int Index, int Col, int CSpan, QuickTile Tile)>();
            var used = 0;
            while (i < items.Count)
            {
                var tile = items[i];
                if (tile.Known == QuickTileKind.Section || tile.EffectiveSize == QuickTileSize.Mini) break;
                var cSpan = tile.EffectiveSize.ColSpan(cols);
                var rSpan = tile.EffectiveSize.RowSpan();
                if (rowItems.Count > 0 && rSpan == 2) break;
                if (used + cSpan > cols) break;
                rowItems.Add((i, used, cSpan, tile));
                used += cSpan;
                i++;
                if (rSpan == 2 || used == cols) break;
            }

            var rowHasWidget = rowItems.Count > 1 && rowItems.Any(e => e.Tile.Known?.IsWidget() == true);
            var rowHeight = rowItems.Count > 0 ? rowItems.Max(e => NaturalHeight(e.Tile, metrics)) : metrics.ActionTallHeight;
            foreach (var entry in rowItems)
            {
                var isAction = entry.Tile.Known?.IsWidget() != true;
                var isShortAction = isAction && entry.Tile.Short;
                var cellHeight = isShortAction ? metrics.ActionShortHeight : rowHeight;
                placements.Add(new QuickTilePlacement(
                    entry.Index,
                    new QuickTileRect(ItemX(entry.Col), y, ItemWidth(entry.CSpan), cellHeight),
                    rowHasWidget && isAction && !entry.Tile.Short));
            }
            y += rowHeight + gap;
        }

        placements.Sort((a, b) => a.Index.CompareTo(b.Index));
        return new QuickTileBentoResult(placements, Math.Max(0, y - gap), cols, colW, unitH);
    }
}

/// [favorites-live-tiles] Dashboard tile picture sizing on Favorites (`FavoriteTileSize` in `FavoriteDashboardTiles.swift`).
public static class FavoriteTileSize
{
    public static (double Width, double Height) Picture(double width, double side, double gap, bool wide, bool stacked)
    {
        var whole = Math.Max(0, width - 2 * side);
        var column = Math.Max(0, (whole - gap) / 2);
        return wide || stacked ? (whole, column) : (column, column);
    }

    public static (double Width, double Height) Picture(double width, double side, double gap, QuickTileSize size, bool stacked, double scale = 1.0)
    {
        var whole = Math.Max(0, width - 2 * side);
        var cols = QuickTileBento.Columns(whole, gap, stacked, scale);
        if (stacked || cols <= 1)
        {
            var unit = Math.Max(0, (whole - gap) / 2);
            var rows = size.RowSpan();
            return (whole, rows * unit + (rows - 1) * gap);
        }
        var colW = Math.Max(0, Math.Floor((whole - (cols - 1) * gap) / cols));
        var unitH = cols <= 2 ? colW : Math.Min(colW, Math.Floor(220 * Math.Max(1, scale)));
        var cSpan = size.ColSpan(cols);
        var rSpan = size.RowSpan();
        var w = cSpan == cols ? whole : cSpan * colW + (cSpan - 1) * gap;
        var h = rSpan * unitH + (rSpan - 1) * gap;
        return (w, h);
    }

    public static double Height(double pictureHeight, bool showsNames, double nameHeight) =>
        pictureHeight + (showsNames ? nameHeight : 0);
}

/// [WIN-QUICK-GRID] Legacy two-column row layout helper (kept 100% compatible with `QuickTileLayoutTests`) plus
/// forwarding helpers into `QuickTileBento` for the expanded responsive 2–5 column 2D Bento canvas.
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

    /// Responsive Bento layout key including column count and rounded usable width bucket.
    public static (bool Stacked, double Side, double Gap, int Columns, int WidthBucket) BentoKey(double width, double textScaleFactor)
    {
        var stacked = StackedAt(textScaleFactor);
        var side = Side(width);
        var gap = Gap(textScaleFactor);
        var scale = Scale(textScaleFactor);
        var usable = double.IsFinite(width) ? Math.Max(0, width - 2 * side) : 0;
        var cols = QuickTileBento.Columns(usable, gap, stacked, scale);
        return (stacked, side, gap, cols, (int)Math.Round(usable));
    }

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

    public static int Columns(double width, double gap, bool stacked, double scale = 1.0) =>
        QuickTileBento.Columns(width, gap, stacked, scale);

    public static QuickTileBentoResult Compute(IReadOnlyList<QuickTile> tiles, QuickTileBentoMetrics metrics, bool hasAddTile = false) =>
        QuickTileBento.Compute(tiles, metrics, hasAddTile);

    public static double SideFor(double width) => Side(width);
    public static double GapFor(double textScaleFactor) => Gap(textScaleFactor);
    public static double ScaleFor(double textScaleFactor) => Scale(textScaleFactor);

    private static double Side(double width) => double.IsFinite(width) && width > Breakpoint ? WideSide : NarrowSide;

    private static double Gap(double textScaleFactor) => BaseGap * Scale(textScaleFactor);

    /// The text size within Windows' range; an unreadable one is the default.
    private static double Scale(double textScaleFactor) =>
        double.IsFinite(textScaleFactor) ? Math.Clamp(textScaleFactor, SmallestScale, LargestScale) : SmallestScale;
}
