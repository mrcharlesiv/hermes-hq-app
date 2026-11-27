using System.Globalization;
using Hermes.Core.Composer;

namespace Hermes.Core.Artifacts;

// [WIN-PAGE-ZOOM] An HTML page's zoom (App/Chat/Viewer/PageZoom.swift at 93f984bb1; owner 2026-11-16: an HTML file
// was too small to read, with no way to enlarge it). One level for every page, kept on this PC between launches: the
// browser's steps, − / + in the bar and Ctrl+- / Ctrl+= / Ctrl+0 while the page has the keys. 100 % is the page's real
// size: Windows draws the app at its own size, so the Mac's 77 % Catalyst factor does not apply here. The page lays out
// in its room over the zoom and is drawn grown by it (PageZoom.place). WinUI's WebView2 keeps its controller's
// ZoomFactor private (microsoft-ui-xaml #5772), so the view grows it with a XAML transform, as the Mac does, and never
// with a script in the page. The views are Features/Artifacts/ArtifactViewers.cs `ArtifactHtmlView` and
// Features/Artifacts/PageZoomControls.cs.

/// The levels and what each means for a page in its room.
public static class PageZoomSteps
{
    public static readonly IReadOnlyList<int> Steps = [50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300];
    public const int Actual = 100;

    public static bool IsStep(int percent) => Steps.Contains(percent);

    /// The level one step in (`by` 1) or out (-1) from `from`; null at the end of the range or off the steps.
    public static int? Step(int from, int by)
    {
        var at = IndexOf(from);
        return at < 0 || at + by < 0 || at + by >= Steps.Count ? null : Steps[at + by];
    }

    /// Whether Zoom In (1), Zoom Out (-1) or Actual Size (0) does anything at `now`.
    public static bool CanChange(int now, int by) => by == 0 ? now != Actual : Step(now, by) != null;

    /// What the page is drawn grown by: the level itself (an invalid one is actual size).
    public static double Scale(int percent) => IsStep(percent) ? percent / 100.0 : 1.0;

    /// A page filling a room `width` × `height`: laid out in the room's size over the zoom (rounded) and drawn grown
    /// by it.
    public static (double Width, double Height, double Scale) Place(double width, double height, int percent)
    {
        var zoom = Scale(percent);
        return (Math.Round(Math.Max(0, width) / zoom), Math.Round(Math.Max(0, height) / zoom), zoom);
    }

    private static int IndexOf(int percent)
    {
        for (var i = 0; i < Steps.Count; i++) if (Steps[i] == percent) return i;
        return -1;
    }
}

/// The Mac's words for the controls.
public static class PageZoomWords
{
    public const string ZoomIn = "Zoom In";
    public const string ZoomOut = "Zoom Out";
    public const string ActualSize = "Actual Size";
    /// The level's button ("125%").
    public static string Level(int percent) => $"{percent}%";
    /// Its name for a screen reader ("Zoom, 125 percent").
    public static string LevelName(int percent) => $"Zoom, {percent} percent";
}

public enum PageZoomItemKind { ZoomIn, ZoomOut, ActualSize, Level }

public readonly record struct PageZoomMenuItem(PageZoomItemKind Kind, string Title, bool Enabled, bool Checked = false, int Percent = 0);

/// The level's menu (PageZoom.Controls.refresh): Actual Size and every step, the level chosen; `compact` (a narrow
/// pane's bar, the level alone) puts Zoom In and Zoom Out first.
public static class PageZoomMenu
{
    public static IReadOnlyList<PageZoomMenuItem> Items(int now, bool compact)
    {
        var items = new List<PageZoomMenuItem>();
        if (compact)
        {
            items.Add(new(PageZoomItemKind.ZoomIn, PageZoomWords.ZoomIn, PageZoomSteps.CanChange(now, 1)));
            items.Add(new(PageZoomItemKind.ZoomOut, PageZoomWords.ZoomOut, PageZoomSteps.CanChange(now, -1)));
        }
        items.Add(new(PageZoomItemKind.ActualSize, PageZoomWords.ActualSize, now != PageZoomSteps.Actual));
        items.AddRange(PageZoomSteps.Steps.Select(s => new PageZoomMenuItem(PageZoomItemKind.Level, PageZoomWords.Level(s), true, s == now, s)));
        return items;
    }
}

/// Ctrl+= / Ctrl++ (and the keypad's +) zoom in, Ctrl+- out, Ctrl+0 back to actual size: the Mac's ⌘+ ⌘− ⌘0.
public static class PageZoomKeys
{
    /// (virtual key, change): VK_OEM_PLUS, keypad Add, VK_OEM_MINUS, keypad Subtract, 0, keypad 0.
    public static readonly IReadOnlyList<(int Key, int By)> All = [(187, 1), (107, 1), (189, -1), (109, -1), (48, 0), (96, 0)];

    public static int? Change(int virtualKey, bool ctrl)
    {
        if (!ctrl) return null;
        foreach (var (key, by) in All) if (key == virtualKey) return by;
        return null;
    }
}

/// The one level, kept in `store` (100 % is no key at all, as the Mac removes it). Everything showing a page watches
/// it while on screen; a watch disposed (the view taken off screen, its window closed) is never told again.
public sealed class PageZoomLevel(IKeyValueStore store)
{
    public const string Key = "hq.page-zoom";

    private readonly List<Watcher> _watchers = [];

    public int Percent
    {
        get
        {
            var raw = store.Get(Key);
            return raw != null && int.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out var stored) && PageZoomSteps.IsStep(stored)
                ? stored : PageZoomSteps.Actual;
        }
    }

    /// To `percent`; false (nothing kept, nobody told) when it isn't a step or is the level already.
    public bool Set(int percent)
    {
        if (!PageZoomSteps.IsStep(percent) || percent == Percent) return false;
        store.Set(Key, percent == PageZoomSteps.Actual ? null : percent.ToString(CultureInfo.InvariantCulture));
        foreach (var w in _watchers.ToArray()) if (!w.Gone) w.Changed(percent);
        return true;
    }

    /// Steps in (1) or out (-1), or back to actual size (0). False at the end of the range.
    public bool Change(int by) => by == 0 ? Set(PageZoomSteps.Actual) : PageZoomSteps.Step(Percent, by) is { } next && Set(next);

    public bool CanChange(int by) => PageZoomSteps.CanChange(Percent, by);

    /// `changed` gets each new level until the returned handle is disposed.
    public IDisposable Watch(Action<int> changed)
    {
        var w = new Watcher(this, changed);
        _watchers.Add(w);
        return w;
    }

    private sealed class Watcher(PageZoomLevel owner, Action<int> changed) : IDisposable
    {
        public Action<int> Changed { get; } = changed;
        public bool Gone { get; private set; }

        public void Dispose()
        {
            if (Gone) return;
            Gone = true;
            owner._watchers.Remove(this);
        }
    }
}
