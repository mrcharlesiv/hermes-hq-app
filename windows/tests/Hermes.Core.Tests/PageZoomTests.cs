using Hermes.Core.Artifacts;
using Hermes.Core.Composer;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-PAGE-ZOOM] An HTML page's zoom (App/Chat/Viewer/PageZoom.swift at 93f984bb1): one level for every page, kept on
/// this PC, the browser's steps, 100 % the page's real size on Windows (no Catalyst 77 % factor).
public class PageZoomTests
{
    private static PageZoomLevel Fresh(out MemoryStore store)
    {
        store = new MemoryStore();
        return new PageZoomLevel(store);
    }

    [Fact]
    public void TheStepsAreTheMacs()
    {
        Assert.Equal([50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300], PageZoomSteps.Steps);
        Assert.Equal(100, PageZoomSteps.Actual);
    }

    [Fact]
    public void ItStartsAtActualSizeAndAnInvalidStoredLevelReadsAsActualSize()
    {
        var zoom = Fresh(out var store);
        Assert.Equal(100, zoom.Percent);
        foreach (var bad in new[] { "33", "0", "-50", "abc", "", "125.5", "1e2", "301" })
        {
            store.Set(PageZoomLevel.Key, bad);
            Assert.Equal(100, zoom.Percent);
        }
        store.Set(PageZoomLevel.Key, "175");
        Assert.Equal(175, zoom.Percent);
    }

    [Fact]
    public void SettingAStepKeepsItAndActualSizeRemovesTheKey()
    {
        var zoom = Fresh(out var store);
        Assert.True(zoom.Set(125));
        Assert.Equal("125", store.Get(PageZoomLevel.Key));
        Assert.True(zoom.Set(100));
        Assert.Null(store.Get(PageZoomLevel.Key));
        Assert.False(zoom.Set(100));        // no change: nothing written, nobody told
        Assert.False(zoom.Set(120));        // not a step
        Assert.False(zoom.Set(0));
        Assert.Equal(100, zoom.Percent);
    }

    [Fact]
    public void ALevelIsRememberedAcrossLaunches()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hq-page-zoom-" + Guid.NewGuid().ToString("N"));
        try
        {
            var file = Path.Combine(dir, "page-zoom.json");
            Assert.True(new PageZoomLevel(new JsonFileStore(file)).Set(150));
            Assert.Equal(150, new PageZoomLevel(new JsonFileStore(file)).Percent);   // the next launch reads it
            Assert.True(new PageZoomLevel(new JsonFileStore(file)).Change(0));
            Assert.Equal(100, new PageZoomLevel(new JsonFileStore(file)).Percent);
        }
        finally { if (Directory.Exists(dir)) Directory.Delete(dir, true); }
    }

    [Fact]
    public void StepsWalkTheRangeAndStopAtItsEnds()
    {
        var zoom = Fresh(out _);
        var seen = new List<int>();
        while (zoom.Change(1)) seen.Add(zoom.Percent);
        Assert.Equal([110, 125, 150, 175, 200, 250, 300], seen);
        Assert.False(zoom.CanChange(1));
        Assert.Null(PageZoomSteps.Step(300, 1));
        Assert.True(zoom.CanChange(-1));
        Assert.True(zoom.CanChange(0));

        Assert.True(zoom.Change(0));
        Assert.Equal(100, zoom.Percent);
        Assert.False(zoom.CanChange(0));    // Actual Size is off at 100 %
        Assert.False(zoom.Change(0));

        seen.Clear();
        while (zoom.Change(-1)) seen.Add(zoom.Percent);
        Assert.Equal([90, 80, 75, 67, 50], seen);
        Assert.False(zoom.CanChange(-1));
        Assert.Null(PageZoomSteps.Step(50, -1));
        Assert.Null(PageZoomSteps.Step(120, 1));   // not a step: nowhere to go
    }

    [Fact]
    public void WindowsDrawsAtNativeSize_NoCatalystFactor()
    {
        Assert.Equal(1.0, PageZoomSteps.Scale(100));
        Assert.Equal(1.25, PageZoomSteps.Scale(125));
        Assert.Equal(0.5, PageZoomSteps.Scale(50));
        Assert.Equal(1.0, PageZoomSteps.Scale(42));   // invalid: actual size
        // The page lays out in its room over the zoom and is drawn grown by it, filling the room again.
        var p = PageZoomSteps.Place(800, 600, 125);
        Assert.Equal((640.0, 480.0, 1.25), p);
        Assert.Equal((800.0, 600.0, 1.0), PageZoomSteps.Place(800, 600, 100));
        var small = PageZoomSteps.Place(801, 601, 67);
        Assert.Equal(Math.Round(801 / 0.67), small.Width);
        Assert.Equal(Math.Round(601 / 0.67), small.Height);
        Assert.Equal((0.0, 0.0, 2.0), PageZoomSteps.Place(0, -5, 200));   // a room not laid out yet
    }

    [Fact]
    public void TheLabelsAreTheMacs()
    {
        Assert.Equal("Zoom In", PageZoomWords.ZoomIn);
        Assert.Equal("Zoom Out", PageZoomWords.ZoomOut);
        Assert.Equal("Actual Size", PageZoomWords.ActualSize);
        Assert.Equal("125%", PageZoomWords.Level(125));
        Assert.Equal("Zoom, 125 percent", PageZoomWords.LevelName(125));
    }

    [Fact]
    public void TheFullMenuHasActualSizeAndEveryStepWithTheLevelChosen()
    {
        var menu = PageZoomMenu.Items(125, compact: false);
        Assert.Equal(PageZoomItemKind.ActualSize, menu[0].Kind);
        Assert.True(menu[0].Enabled);
        var levels = menu.Skip(1).ToList();
        Assert.All(levels, i => Assert.Equal(PageZoomItemKind.Level, i.Kind));
        Assert.Equal(PageZoomSteps.Steps, levels.Select(i => i.Percent));
        Assert.Equal(levels.Select(i => $"{i.Percent}%"), levels.Select(i => i.Title));
        Assert.Equal([125], levels.Where(i => i.Checked).Select(i => i.Percent));   // single selection
        Assert.False(PageZoomMenu.Items(100, compact: false)[0].Enabled);
    }

    [Fact]
    public void TheCompactMenuPutsZoomInAndOutFirstAndDisablesThemAtTheEnds()
    {
        var mid = PageZoomMenu.Items(100, compact: true);
        Assert.Equal([PageZoomItemKind.ZoomIn, PageZoomItemKind.ZoomOut, PageZoomItemKind.ActualSize],
            mid.Take(3).Select(i => i.Kind));
        Assert.Equal(["Zoom In", "Zoom Out", "Actual Size"], mid.Take(3).Select(i => i.Title));
        Assert.True(mid[0].Enabled && mid[1].Enabled);
        Assert.False(mid[2].Enabled);
        Assert.Equal(3 + PageZoomSteps.Steps.Count, mid.Count);

        var top = PageZoomMenu.Items(300, compact: true);
        Assert.False(top[0].Enabled);
        Assert.True(top[1].Enabled);
        var bottom = PageZoomMenu.Items(50, compact: true);
        Assert.True(bottom[0].Enabled);
        Assert.False(bottom[1].Enabled);
    }

    [Fact]
    public void ControlKeysAreTheMacsCommandKeys()
    {
        // Ctrl+= / Ctrl++ (VK_OEM_PLUS 187, keypad Add 107), Ctrl+- (VK_OEM_MINUS 189, keypad Subtract 109),
        // Ctrl+0 (48, keypad 96).
        Assert.Equal(1, PageZoomKeys.Change(187, ctrl: true));
        Assert.Equal(1, PageZoomKeys.Change(107, ctrl: true));
        Assert.Equal(-1, PageZoomKeys.Change(189, ctrl: true));
        Assert.Equal(-1, PageZoomKeys.Change(109, ctrl: true));
        Assert.Equal(0, PageZoomKeys.Change(48, ctrl: true));
        Assert.Equal(0, PageZoomKeys.Change(96, ctrl: true));
        Assert.Null(PageZoomKeys.Change(187, ctrl: false));   // plain = types into the page
        Assert.Null(PageZoomKeys.Change(65, ctrl: true));
        Assert.Equal([(187, 1), (107, 1), (189, -1), (109, -1), (48, 0), (96, 0)], PageZoomKeys.All);
    }

    [Fact]
    public void TwoVisiblePagesFollowOneLevel_AStaleOrClosedOneHearsNothing()
    {
        var zoom = Fresh(out _);
        var first = new List<int>();
        var second = new List<int>();
        var stale = new List<int>();
        using var a = zoom.Watch(first.Add);
        using var b = zoom.Watch(second.Add);
        var c = zoom.Watch(stale.Add);
        c.Dispose();                     // its window closed / taken off screen
        c.Dispose();                     // twice is harmless

        Assert.True(zoom.Change(1));     // from the first page's bar
        Assert.True(zoom.Set(150));      // from the second page's menu
        Assert.False(zoom.Set(150));     // no change: nobody told
        Assert.False(zoom.Set(77));      // not a step: nobody told

        Assert.Equal([110, 150], first);
        Assert.Equal([110, 150], second);
        Assert.Empty(stale);

        b.Dispose();
        Assert.True(zoom.Change(0));
        Assert.Equal([110, 150, 100], first);
        Assert.Equal([110, 150], second);
    }

    [Fact]
    public void AWatcherThatLeavesWhileBeingToldDoesntStopTheOthers()
    {
        var zoom = Fresh(out _);
        var heard = new List<string>();
        IDisposable? first = null;
        first = zoom.Watch(_ => { heard.Add("first"); first!.Dispose(); });
        using var second = zoom.Watch(_ => heard.Add("second"));
        zoom.Change(1);
        zoom.Change(1);
        Assert.Equal(["first", "second", "second"], heard);
    }

    [Fact]
    public void TwoPreviewsOverOneStoreShareTheLevel()
    {
        // A preview in the file pane and the page in its own window read the one kept level.
        var store = new MemoryStore();
        var pane = new PageZoomLevel(store);
        Assert.True(pane.Set(200));
        Assert.Equal(200, new PageZoomLevel(store).Percent);
    }
}
