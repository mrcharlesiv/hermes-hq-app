using System.Text.RegularExpressions;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-QUICK-GRID] Source coverage for the WinUI page (it can't run here): QuickActionsPage draws the grid from
/// QuickTileLayout.Fit with the page's own width and Windows' text size, redraws when either moves the plan, keeps the
/// focused tile focused across a redraw, and lets a tile's words wrap instead of cutting them to one line. Actual
/// Windows proof (a real window narrowed past 700 and Text size at 150 %) is a separate gate.
public class QuickActionsPageLayoutSourceTests
{
    private static string Source(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine([dir, "src", .. parts]));
    }

    private static string Page() => Source("HermesHQ.Windows", "Features", "QuickActions", "QuickActionsPage.cs");

    private static string Method(string source, string signature)
    {
        var start = source.IndexOf(signature, StringComparison.Ordinal);
        Assert.True(start >= 0, "missing " + signature);
        var open = source.IndexOf('{', start);
        var depth = 0;
        for (var i = open; i < source.Length; i++)
        {
            if (source[i] == '{') depth++;
            else if (source[i] == '}' && --depth == 0) return source[start..(i + 1)];
        }
        throw new InvalidOperationException("unbalanced " + signature);
    }

    [Fact]
    public void TheGridComesFromTheLayoutHelperNotAFixedTwoColumnsAndWideInset()
    {
        var page = Page();
        Assert.DoesNotContain("QuickTileGrid.Rows(cells, 2)", page);
        Assert.DoesNotContain("24 - Gap / 2", page);
        Assert.Contains("QuickTileLayout.Fit(", page);
        var draw = Method(page, "private void Draw(");
        Assert.Contains("plan.Rows", draw);
        Assert.Contains("plan.Side", draw);
        Assert.Contains("plan.Gap", draw);
        Assert.Contains("Grid.SetColumnSpan", draw);
        Assert.Contains("row.Columns", draw);   // one column when stacked: no spare half-width column
    }

    [Fact]
    public void ThePageReflowsOnItsWidthAndTheTextSizeAndLetsGoOfTheTextSizeEvent()
    {
        var page = Page();
        Assert.Matches(new Regex(@"\.SizeChanged\s*\+="), page);
        Assert.Contains("TextScaleFactorChanged +=", page);
        Assert.Contains("TextScaleFactorChanged -=", page);
        Assert.Contains("QuickTileLayout.Key(", page);   // a resize within the same plan doesn't rebuild the tiles
        // The app's one accessibility text-size threshold (UndoPillClock), not a second number of its own.
        Assert.Contains("UndoPillClock.AccessibilityTextScale(", Source("Hermes.Core", "QuickActions", "QuickTileLayout.cs"));
    }

    [Fact]
    public void ARedrawKeepsTheFocusedTileFocusedByItsStableId()
    {
        var page = Page();
        var draw = Method(page, "private void Draw(");
        Assert.Contains("FocusManager.GetFocusedElement", draw);
        Assert.Contains("FocusKey(focused)", draw);
        Assert.Contains("Refocus(", draw);
        // Every − badge shares one automation id: the key names the badge by its tile's id.
        Assert.Contains("AutomationProperties.GetAutomationId", Method(page, "private static string? FocusKey("));
        // The keyboard's reorder (the menu's Move Up / Down) and Small / Wide land back on the tile they moved.
        var menu = Method(page, "private MenuFlyout Menu(");
        Assert.Equal(5, Regex.Matches(menu, @"_focusAfter = ""quick-tile-"" \+ id;").Count);
    }

    [Fact]
    public void ATilesWordsWrapAndTheStackedFaceSitsBesideItsIcon()
    {
        var page = Page();
        var tile = Method(page, "private FrameworkElement Tile(");
        Assert.Contains("TextWrapping.WrapWholeWords", tile);
        Assert.Contains("MaxLines = plan.Stacked ? 8 : 2", tile);
        Assert.Contains("plan.Stacked", tile);
        var add = Method(page, "private FrameworkElement AddTile(");
        Assert.Contains("plan.AddMinHeight", add);
        Assert.Contains("TextWrapping.WrapWholeWords", add);
        var empty = Method(page, "private FrameworkElement Empty(");
        Assert.Contains("QuickTileLayout.StackedAt", empty);   // the Mac drops the empty state's picture at accessibility sizes
    }
}
