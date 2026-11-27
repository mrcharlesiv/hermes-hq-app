using System.Text.RegularExpressions;
using Hermes.Core.Kanban;
using Hermes.Core.Settings;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// The board's columns (App/Pages/Kanban/KanbanBoardView.swift `layoutSubviews`, 93f984bb1): the page's side either end
/// (under the page bar's title), 10 between, 4 over, the side under; equal whole widths never under 212, the board
/// scrolling sideways below that with the last column reachable; the height what is left, never negative. Sizes are
/// synthetic; the source tests tie them to KanbanPage's real sizing.
public class KanbanBoardGeometryTests
{
    /// Every status the board shows (KanbanModel.ChipOrder without Archived).
    private static readonly int Statuses = KanbanModel.ChipOrder(KanbanModel.StatusOrder).Count;

    /// The task panel beside the board (KanbanPage `_panel`).
    private const double TaskPanel = 420;

    /// The last column scrolled fully into view, the side after it, when the board is scrolled to its end.
    private static void LastColumnReachable(KanbanBoardLayout layout)
    {
        var last = layout.Count - 1;
        Assert.Equal(layout.Extent, layout.Trailing(last) + KanbanBoardGeometry.Side, 6);
        // Scrolled to the end, the last column's trailing edge sits the side in from the viewport's edge.
        Assert.Equal(layout.Viewport - KanbanBoardGeometry.Side, layout.Trailing(last) - layout.MostOffset, 6);
        // A viewport with room for a column and its sides shows the whole of it; a smaller one (a tiny window) still
        // scrolls over every part of it: its leading edge is at or past the start of the scroll range.
        if (layout.Viewport >= layout.ColumnWidth + KanbanBoardGeometry.Side * 2)
            Assert.True(layout.Leading(last) - layout.MostOffset >= 0, "the last column is cut at the leading edge");
        else
            Assert.True(layout.Leading(last) >= 0 && layout.Leading(last) <= layout.MostOffset + layout.Viewport);
    }

    [Fact]
    public void TheBoardTakesThePageSideTheBarsTitleStartsAt()
    {
        Assert.Equal(20, KanbanBoardGeometry.Side);
        Assert.Equal(DesktopLook.PageSide, KanbanBoardGeometry.Side);
        var layout = KanbanBoardGeometry.Fit(1400, 800, Statuses);
        Assert.Equal(DesktopLook.PageSide, layout.Leading(0));
        Assert.Equal(10, KanbanBoardGeometry.Gap);
        Assert.Equal(4, KanbanBoardGeometry.Top);
        Assert.Equal(212, KanbanBoardGeometry.Narrowest);
    }

    [Fact]
    public void AWideWindowSharesTheRoomInEqualWholeColumnsThatFit()
    {
        // 8 columns: room 2000 - 40 - 70 = 1890, 236.25 each, floored to 236.
        var layout = KanbanBoardGeometry.Fit(2000, 900, Statuses);
        Assert.Equal(8, layout.Count);
        Assert.Equal(236, layout.ColumnWidth);
        Assert.Equal(1998, layout.ContentWidth);
        Assert.False(layout.Scrolls);
        Assert.Equal(2000, layout.Extent);
        Assert.Equal(0, layout.MostOffset);
        Assert.Equal(900 - 4 - 20, layout.ColumnHeight);
        for (var i = 1; i < layout.Count; i++) Assert.Equal(KanbanBoardGeometry.Gap, layout.Leading(i) - layout.Trailing(i - 1));
    }

    [Fact]
    public void AnExactFitNeitherScrollsNorLeavesARemainder()
    {
        // 5 columns of 224: 40 + 1120 + 40 = 1200.
        var exact = KanbanBoardGeometry.Fit(1200, 700, 5);
        Assert.Equal(224, exact.ColumnWidth);
        Assert.Equal(1200, exact.ContentWidth);
        Assert.False(exact.Scrolls);
        Assert.Equal(1200 - KanbanBoardGeometry.Side, exact.Trailing(4));

        // At the narrowest exactly: 40 + 212·8 + 70 = 1806 fits; a point less scrolls by that point.
        var narrowest = 40 + 212 * Statuses + 10 * (Statuses - 1);
        var fit = KanbanBoardGeometry.Fit(narrowest, 700, Statuses);
        Assert.Equal(212, fit.ColumnWidth);
        Assert.False(fit.Scrolls);
        var under = KanbanBoardGeometry.Fit(narrowest - 1, 700, Statuses);
        Assert.Equal(212, under.ColumnWidth);
        Assert.True(under.Scrolls);
        Assert.Equal(1, under.MostOffset);
        LastColumnReachable(under);
    }

    [Theory]
    [InlineData(1203.0, 5)]
    [InlineData(1207.9, 5)]
    [InlineData(1919.5, 8)]
    [InlineData(1366.0, 6)]
    public void AFractionalRoomIsFlooredSoTheColumnsNeverOverflow(double width, int count)
    {
        var layout = KanbanBoardGeometry.Fit(width, 700, count);
        Assert.Equal(Math.Floor(layout.ColumnWidth), layout.ColumnWidth);
        Assert.False(layout.Scrolls);
        Assert.True(layout.ContentWidth <= width);
        Assert.True(width - layout.ContentWidth < count, "the floor gives back less than a point a column");
    }

    [Theory]
    [InlineData(1280.0)]
    [InlineData(1024.0)]
    [InlineData(800.0)]
    [InlineData(500.0)]
    public void ANarrowWindowScrollsSidewaysToTheLastColumn(double window)
    {
        var layout = KanbanBoardGeometry.Fit(window, 640, Statuses);
        Assert.Equal(212, layout.ColumnWidth);
        Assert.True(layout.Scrolls);
        LastColumnReachable(layout);
    }

    [Theory]
    [InlineData(1920.0, 100)]
    [InlineData(1440.0, 100)]
    [InlineData(1280.0, 125)]
    [InlineData(1920.0, 90)]
    [InlineData(700.0, 100)]
    public void OpeningTheTaskPanelNarrowsTheBoardAndItsLastColumnStaysReachable(double window, int uiScale)
    {
        var scale = new ThemeState { UiScalePercent = uiScale }.Scale;
        var page = window / scale;
        var closed = KanbanBoardGeometry.Fit(page, 800 / scale, Statuses);
        var open = KanbanBoardGeometry.Fit(Math.Max(0, page - TaskPanel), 800 / scale, Statuses);
        Assert.True(open.ColumnWidth <= closed.ColumnWidth);
        Assert.Equal(KanbanBoardGeometry.Side, open.Leading(0));
        if (open.Scrolls) LastColumnReachable(open);
        else Assert.True(open.ContentWidth <= open.Viewport);
    }

    /// UI Scale is a ScaleTransform over the window's content (ThemeService.ApplyScale): the page is laid out at the
    /// window's width over the scale, so the narrowest column on the screen is 212 × the scale (the Mac's
    /// HQFont.scaled(212)), and the board and the bar's title share the same side however it scales.
    [Theory]
    [InlineData(90)]
    [InlineData(100)]
    [InlineData(125)]
    [InlineData(160)]
    public void UiScaleScalesTheNarrowestColumnOnceOnTheScreen(int uiScale)
    {
        var scale = new ThemeState { UiScalePercent = uiScale }.Scale;
        const double screen = 1000;
        var layout = KanbanBoardGeometry.Fit(screen / scale, 700 / scale, Statuses);
        Assert.True(layout.Scrolls);
        Assert.Equal(212 * scale, layout.ColumnWidth * scale, 6);
        Assert.Equal(DesktopLook.PageSide * scale, layout.Leading(0) * scale, 6);
        LastColumnReachable(layout);

        // Wide enough at this scale: equal columns over 212 that fit the screen once scaled.
        var wide = KanbanBoardGeometry.Fit(3000 / scale, 700 / scale, Statuses);
        Assert.False(wide.Scrolls);
        Assert.True(wide.ContentWidth * scale <= 3000 + 1e-9);
        Assert.True(wide.ColumnWidth >= 212);
    }

    [Theory]
    [InlineData(100.0, 76.0)]
    [InlineData(24.0, 0.0)]
    [InlineData(10.0, 0.0)]
    [InlineData(0.0, 0.0)]
    public void AShortWindowShortensTheColumnsInsteadOfPushingThemPastItsFoot(double height, double column)
    {
        var layout = KanbanBoardGeometry.Fit(1400, height, Statuses);
        Assert.Equal(column, layout.ColumnHeight);
        // The columns with the top and foot never overrun a viewport that has room for the insets.
        if (height >= KanbanBoardGeometry.Top + KanbanBoardGeometry.Side)
            Assert.Equal(height, KanbanBoardGeometry.Top + layout.ColumnHeight + KanbanBoardGeometry.Side);
    }

    [Fact]
    public void NoColumnsLayOutNothing()
    {
        var layout = KanbanBoardGeometry.Fit(900, 600, 0);
        Assert.Equal(0, layout.Count);
        Assert.Equal(0, layout.ColumnWidth);
        Assert.False(layout.Scrolls);
        Assert.Equal(900, layout.Extent);
        Assert.Equal(0, KanbanBoardGeometry.Fit(900, 600, -3).Count);
    }

    [Theory]
    [InlineData(1.0, 1.0, 1)]
    [InlineData(0.0, 0.0, 3)]
    [InlineData(-50.0, -50.0, 2)]
    [InlineData(double.NaN, double.NaN, 8)]
    [InlineData(double.PositiveInfinity, 300.0, 4)]
    public void ATinyOrUnmeasuredBoardStillGivesFiniteColumnsAtTheNarrowest(double width, double height, int count)
    {
        var layout = KanbanBoardGeometry.Fit(width, height, count);
        Assert.Equal(212, layout.ColumnWidth);
        Assert.True(double.IsFinite(layout.ColumnHeight) && layout.ColumnHeight >= 0);
        Assert.True(double.IsFinite(layout.Extent));
        Assert.True(layout.Scrolls);
        LastColumnReachable(layout);
    }

    [Fact]
    public void RightToLeftMirrorsTheRowExactlyOnce()
    {
        foreach (var width in new[] { 2000.0, 1200.0, 700.0 })
        {
            var layout = KanbanBoardGeometry.Fit(width, 600, Statuses);
            for (var i = 0; i < layout.Count; i++)
            {
                // The Mac's hand mirror (`total - x - width`) is the leading layout seen from the other edge: the same
                // gaps and sides, the first column at the right.
                Assert.Equal(layout.ContentWidth - layout.Trailing(i), layout.MirroredLeading(i), 6);
            }
            Assert.Equal(KanbanBoardGeometry.Side, layout.MirroredLeading(layout.Count - 1), 6);
        }
    }

    // ------------------------------------------------------------------ the real page's sizing

    private static string PageSource()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Features", "Kanban", "KanbanPage.cs"));
    }

    private static string Method(string source, string signature)
    {
        var start = source.IndexOf(signature, StringComparison.Ordinal);
        Assert.True(start >= 0, $"{signature} not found");
        var open = source.IndexOf('{', start);
        var depth = 0;
        for (var i = open; i < source.Length; i++)
        {
            if (source[i] == '{') depth++;
            else if (source[i] == '}' && --depth == 0) return source[open..(i + 1)];
        }
        throw new InvalidOperationException("unbalanced " + signature);
    }

    [Fact]
    public void ThePageSizesItsColumnsFromTheGeometryAndTheBoardsViewport()
    {
        var source = PageSource();
        var size = Method(source, "private void SizeColumns()");
        Assert.Contains("KanbanBoardGeometry.Fit(_boardScroll.ActualWidth, _boardScroll.ActualHeight, _columns.Children.Count)", size);
        Assert.Contains("layout.ColumnWidth", size);
        Assert.Contains("layout.ColumnHeight", size);
        // No sizes of its own any more (the old 16 + 16, 212 and 120).
        Assert.DoesNotMatch(new Regex(@"\b(32|212|120|20)\b"), size);
        // The scroller sizes them again whenever it changes size (the window, or the task panel opening beside it).
        Assert.Contains("_boardScroll.SizeChanged += (_, _) => SizeColumns();", source);
    }

    [Fact]
    public void TheColumnsRowTakesTheGeometrysInsetsAndTheBarTheSameSide()
    {
        var source = PageSource();
        var row = Regex.Match(source, @"private readonly StackPanel _columns = new\(\)\s*\{(.*?)\};", RegexOptions.Singleline);
        Assert.True(row.Success, "the columns' row");
        Assert.Contains("Spacing = KanbanBoardGeometry.Gap", row.Groups[1].Value);
        Assert.Contains("Padding = new Thickness(KanbanBoardGeometry.Side, KanbanBoardGeometry.Top, KanbanBoardGeometry.Side, KanbanBoardGeometry.Side)", row.Groups[1].Value);
        // The bar's title starts at DesktopLook.PageSide (Shell/PageBar.Padding), the side the geometry uses.
        Assert.Contains("HermesHQ.Shell.PageBar.Padding(", source);
    }

    [Fact]
    public void TheBoardScrollsSidewaysOnlyAndEachColumnScrollsItsOwnCards()
    {
        var source = PageSource();
        var board = Regex.Match(source, @"_boardScroll = new ScrollViewer\s*\{(.*?)\};", RegexOptions.Singleline).Groups[1].Value;
        Assert.Contains("HorizontalScrollMode = ScrollMode.Auto", board);
        Assert.Contains("VerticalScrollMode = ScrollMode.Disabled", board);
        var column = Method(source, "private FrameworkElement ColumnView(");
        Assert.Contains("new ScrollViewer { Content = cards, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }", column);
        Assert.Contains("AllowDrop = true", column);
        Assert.Contains("panel.Drop +=", column);
        // FlowDirection mirrors the row for right to left; the page never mirrors positions by hand as well.
        Assert.DoesNotContain("MirroredLeading", source);
        Assert.DoesNotMatch(new Regex(@"FlowDirection\s*="), source);
    }
}
