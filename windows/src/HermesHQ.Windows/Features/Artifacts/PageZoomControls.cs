using Hermes.Core.Artifacts;
using Hermes.Core.Composer;
using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Artifacts;

/// [WIN-PAGE-ZOOM] The one zoom level every HTML page shares, kept on this PC (the Mac's `hq.mac.page-zoom` default).
internal static class PageZoomShared
{
    public static PageZoomLevel Level { get; } = new PageZoomLevel(new JsonFileStore(Path.Combine(AppPaths.Root, "page-zoom.json")));
}

/// − 100 % + for a page's bar (PageZoom.Controls): Zoom Out, the level (its menu has Actual Size and every step, the
/// level chosen) and Zoom In. `compact` (the file pane's bar beside the grid): the level alone, with Zoom In and Zoom
/// Out in its menu. It follows the level while on screen only.
internal sealed class PageZoomControls : StackPanel
{
    private readonly bool _compact;
    private readonly Button _out = new() { Style = (Style)Application.Current.Resources["QuietButtonStyle"] };
    private readonly Button _in = new() { Style = (Style)Application.Current.Resources["QuietButtonStyle"] };
    private readonly DropDownButton _level = new() { MinWidth = 64 };
    private IDisposable? _watch;

    public PageZoomControls(bool compact)
    {
        _compact = compact;
        Orientation = Orientation.Horizontal;
        Spacing = 2;
        VerticalAlignment = VerticalAlignment.Center;
        Prepare(_out, "\uE71F", PageZoomWords.ZoomOut, "page.zoom.out", -1);
        Prepare(_in, "\uE8A3", PageZoomWords.ZoomIn, "page.zoom.in", 1);
        AutomationProperties.SetAutomationId(_level, "page.zoom.level");
        if (!compact) Children.Add(_out);
        Children.Add(_level);
        if (!compact) Children.Add(_in);
        Refresh();
        Loaded += (_, _) =>
        {
            _watch?.Dispose();
            _watch = PageZoomShared.Level.Watch(_ => Refresh());
            Refresh();
        };
        Unloaded += (_, _) => { _watch?.Dispose(); _watch = null; };
    }

    private static void Prepare(Button b, string glyph, string name, string id, int by)
    {
        b.Content = new FontIcon { Glyph = glyph, FontSize = 14 };
        ToolTipService.SetToolTip(b, name);
        AutomationProperties.SetName(b, name);
        AutomationProperties.SetAutomationId(b, id);
        b.Click += (_, _) => PageZoomShared.Level.Change(by);
    }

    private void Refresh()
    {
        var now = PageZoomShared.Level.Percent;
        _level.Content = PageZoomWords.Level(now);
        AutomationProperties.SetName(_level, PageZoomWords.LevelName(now));
        ToolTipService.SetToolTip(_level, PageZoomWords.LevelName(now));
        _out.IsEnabled = PageZoomSteps.CanChange(now, -1);
        _in.IsEnabled = PageZoomSteps.CanChange(now, 1);
        var menu = new MenuFlyout();
        var levels = false;
        foreach (var item in PageZoomMenu.Items(now, _compact))
        {
            MenuFlyoutItem entry;
            if (item.Kind == PageZoomItemKind.Level)
            {
                if (!levels) { menu.Items.Add(new MenuFlyoutSeparator()); levels = true; }
                entry = new RadioMenuFlyoutItem { GroupName = "page.zoom", IsChecked = item.Checked };
                var percent = item.Percent;
                entry.Click += (_, _) => PageZoomShared.Level.Set(percent);
            }
            else
            {
                entry = new MenuFlyoutItem();
                var by = item.Kind switch { PageZoomItemKind.ZoomIn => 1, PageZoomItemKind.ZoomOut => -1, _ => 0 };
                entry.Click += (_, _) => PageZoomShared.Level.Change(by);
                if (item.Kind != PageZoomItemKind.ActualSize)
                    entry.Icon = new FontIcon { Glyph = item.Kind == PageZoomItemKind.ZoomIn ? "\uE8A3" : "\uE71F" };
            }
            entry.Text = item.Title;
            entry.IsEnabled = item.Enabled;
            AutomationProperties.SetName(entry, item.Title);
            menu.Items.Add(entry);
        }
        _level.Flyout = menu;
    }
}
