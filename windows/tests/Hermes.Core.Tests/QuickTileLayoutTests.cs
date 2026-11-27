using Hermes.Core.QuickActions;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-QUICK-GRID] The Quick Actions grid as the Mac lays it out (App/QuickActions/QuickActionsViewController.swift
/// `section(_:)` and `stacked`, 93f984bb1): two columns with a Wide tile across both, one full-width column at
/// accessibility text sizes, the side 16 up to a 700-wide page and 24 past it, the gap growing with the text. Synthetic
/// tiles only; the text size is a parameter, so no test reads or changes a system setting.
public class QuickTileLayoutTests
{
    private const string Add = "quick-actions.add";

    private static QuickTile S(string id) => QuickTile.Create(QuickTileKind.Page, id: id, name: id);
    private static QuickTile W(string id) => QuickTile.Create(QuickTileKind.Page, id: id, name: id, wide: true);

    /// The page's cells while editing: the tiles, then the ＋ tile (always small).
    private static List<QuickTile> Editing(params QuickTile[] tiles) => [.. tiles, S(Add)];

    private static int[][] Indices(QuickTileLayoutPlan plan) => plan.Rows.Select(r => r.Slots.Select(s => s.Index).ToArray()).ToArray();

    [Fact]
    public void TwoColumnsUnderAccessibilitySizesWideAcrossBothSmallInHalf()
    {
        // small, wide, small, small, small, ＋ : a small tile alone before a wide one keeps its own (half) row.
        var cells = Editing(S("a"), W("b"), S("c"), S("d"), S("e"));
        var plan = QuickTileLayout.Fit(cells, 900, 1.0);
        Assert.False(plan.Stacked);
        Assert.Equal([[0], [1], [2, 3], [4, 5]], Indices(plan));
        Assert.All(plan.Rows, r => Assert.Equal(2, r.Columns));
        Assert.Equal(new QuickTileSlot(0, 0, 1), plan.Rows[0].Slots[0]);   // the lone small tile: half the row, leading
        Assert.Equal(new QuickTileSlot(1, 0, 2), plan.Rows[1].Slots[0]);   // Wide: both columns
        Assert.Equal([new QuickTileSlot(2, 0, 1), new QuickTileSlot(3, 1, 1)], plan.Rows[2].Slots);
        Assert.Equal([new QuickTileSlot(4, 0, 1), new QuickTileSlot(5, 1, 1)], plan.Rows[3].Slots);   // ＋ pairs with e
    }

    [Fact]
    public void AnOddRunLeavesTheLastSmallTileInHalfAndTheAddTileFollowsInOrder()
    {
        var plain = QuickTileLayout.Fit([S("a"), S("b"), S("c")], 640, 1.0);
        Assert.Equal([[0, 1], [2]], Indices(plain));
        Assert.Equal(new QuickTileSlot(2, 0, 1), plain.Rows[1].Slots.Single());
        var editing = QuickTileLayout.Fit(Editing(S("a"), S("b"), S("c")), 640, 1.0);
        Assert.Equal([[0, 1], [2, 3]], Indices(editing));
        var wideLast = QuickTileLayout.Fit(Editing(S("a"), W("b")), 640, 1.0);
        Assert.Equal([[0], [1], [2]], Indices(wideLast));
        Assert.Equal(new QuickTileSlot(2, 0, 1), wideLast.Rows[2].Slots.Single());   // ＋ stays small after a Wide tile
    }

    [Theory]
    [InlineData(320, 16)]
    [InlineData(699, 16)]
    [InlineData(700, 16)]   // the Mac's `> 700`
    [InlineData(701, 24)]
    [InlineData(1400, 24)]
    public void TheSideIsSixteenUpToSevenHundredAndTwentyFourPastIt(double width, double side)
    {
        foreach (var scale in new[] { 1.0, 1.5, 2.25 })
        {
            var plan = QuickTileLayout.Fit(Editing(S("a"), W("b"), S("c")), width, scale);
            Assert.Equal(side, plan.Side);   // the text size never moves the side (MacInset)
            Assert.Equal(12, plan.Top);
            Assert.Equal(24, plan.Bottom);
        }
    }

    [Theory]
    [InlineData(1.0, false)]
    [InlineData(1.35, false)]
    [InlineData(1.49, false)]
    [InlineData(1.5, true)]
    [InlineData(2.25, true)]
    public void AccessibilityTextSizesStackAtTheAppsExistingThreshold(double scale, bool stacked)
    {
        Assert.Equal(stacked, QuickTileLayout.StackedAt(scale));
        Assert.Equal(stacked, QuickTileLayout.Fit([S("a"), S("b")], 900, scale).Stacked);
    }

    [Theory]
    [InlineData(480)]
    [InlineData(699)]
    [InlineData(701)]
    [InlineData(1200)]
    public void StackedEveryCellIncludingAddIsAFullWidthRowInOrder(double width)
    {
        var cells = Editing(S("a"), W("b"), S("c"), S("d"), S("e"));
        var plan = QuickTileLayout.Fit(cells, width, 1.5);
        Assert.True(plan.Stacked);
        Assert.Equal(cells.Count, plan.Rows.Count);
        for (var i = 0; i < cells.Count; i++)
        {
            Assert.Equal(1, plan.Rows[i].Columns);   // no spare half-width column
            Assert.Equal(new QuickTileSlot(i, 0, 1), plan.Rows[i].Slots.Single());
        }
    }

    [Fact]
    public void TheGapAndTheAddTileGrowWithTheText()
    {
        Assert.Equal(12, QuickTileLayout.Fit([S("a")], 800, 1.0).Gap);
        Assert.Equal(104, QuickTileLayout.Fit([S("a")], 800, 1.0).AddMinHeight);
        Assert.Equal(18, QuickTileLayout.Fit([S("a")], 800, 1.5).Gap);
        Assert.Equal(156, QuickTileLayout.Fit([S("a")], 800, 1.5).AddMinHeight);
        Assert.Equal(27, QuickTileLayout.Fit([S("a")], 800, 2.25).Gap);
        // Out-of-range or unreadable sizes count as the default (Windows' range is 1.0–2.25).
        Assert.Equal(12, QuickTileLayout.Fit([S("a")], 800, double.NaN).Gap);
        Assert.Equal(12, QuickTileLayout.Fit([S("a")], 800, 0.5).Gap);
        Assert.Equal(27, QuickTileLayout.Fit([S("a")], 800, 9).Gap);
    }

    [Fact]
    public void EveryCellIsPlacedOnceInItsOrderAtEveryWidthAndSize()
    {
        var cells = Editing(W("a"), S("b"), W("c"), S("d"), S("e"), S("f"), W("g"), S("h"));
        foreach (var width in new[] { double.NaN, -5, 0, 360, 699, 700, 701, 1600 })
            foreach (var scale in new[] { 1.0, 1.25, 1.5, 2.25 })
            {
                var plan = QuickTileLayout.Fit(cells, width, scale);
                Assert.Equal(Enumerable.Range(0, cells.Count), plan.Rows.SelectMany(r => r.Slots).Select(s => s.Index));
                Assert.All(plan.Rows.SelectMany(r => r.Slots, (r, s) => (r, s)), x => Assert.True(x.s.Column + x.s.Span <= x.r.Columns));
                Assert.True(plan.Side is 16 or 24);
            }
        Assert.Empty(QuickTileLayout.Fit([], 800, 1.0).Rows);
        Assert.Empty(QuickTileLayout.Fit([], 800, 2.0).Rows);
    }

    [Fact]
    public void TheSameTilesGiveTheSamePlanSoReflowKeepsIdentity()
    {
        var cells = Editing(S("a"), W("b"), S("c"));
        Assert.Equal(QuickTileLayout.Fit(cells, 800, 1.0).Rows.Select(r => (r.Columns, string.Join(",", r.Slots))),
            QuickTileLayout.Fit(cells, 800, 1.0).Rows.Select(r => (r.Columns, string.Join(",", r.Slots))));
        // Only the side, the stacking and the gap may differ between two plans: the page redraws when its key changes.
        Assert.Equal(QuickTileLayout.Key(800, 1.0), QuickTileLayout.Key(1200, 1.0));
        Assert.NotEqual(QuickTileLayout.Key(700, 1.0), QuickTileLayout.Key(701, 1.0));
        Assert.NotEqual(QuickTileLayout.Key(800, 1.0), QuickTileLayout.Key(800, 1.5));
        Assert.NotEqual(QuickTileLayout.Key(800, 1.0), QuickTileLayout.Key(800, 1.25));   // the gap
    }
}
