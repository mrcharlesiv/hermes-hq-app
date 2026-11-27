using Hermes.Core.Artifacts;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Artifacts;

/// A file open beside the grid (ArtifactsViewController `showBeside`, [mac-tools]): its own bar with ✕ (Close File),
/// the file's name, Preview | Source, a page's zoom level, Open in Window and Share; a note's linked notes push onto it, and Back returns
/// to the note before (named when that name is 12 characters or fewer, else plain "Back").
internal sealed class ArtifactFilePane : Grid
{
    private readonly List<ArtifactViewer> _stack = [];
    private readonly Grid _host = new();
    private readonly Button _close = new() { Style = (Style)Application.Current.Resources["QuietButtonStyle"] };
    private readonly Button _back = new() { Style = (Style)Application.Current.Resources["QuietButtonStyle"] };
    private readonly TextBlock _title = new()
    {
        FontWeight = FontWeights.SemiBold, FontSize = 15, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
        TextTrimming = TextTrimming.CharacterEllipsis,
    };
    private readonly StackPanel _trailing = new() { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };

    /// ✕ was chosen: the page closes the pane.
    public event Action? CloseRequested;

    public ArtifactViewer? Top => _stack.Count > 0 ? _stack[^1] : null;

    public ArtifactFilePane()
    {
        BorderBrush = Look.Brush("CardStrokeColorDefaultBrush");
        BorderThickness = new Thickness(1, 0, 0, 0);
        Background = Look.Brush("SolidBackgroundFillColorBaseBrush");
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var bar = new Grid { Height = 52, Padding = new Thickness(8, 6, 12, 6), ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _close.Content = new FontIcon { Glyph = "\uE711", FontSize = 14 };
        ToolTipService.SetToolTip(_close, ArtifactPageWords.CloseFile);
        AutomationProperties.SetName(_close, ArtifactPageWords.CloseFile);
        AutomationProperties.SetAutomationId(_close, "artifacts.file.close");
        _close.Click += (_, _) => CloseRequested?.Invoke();
        _back.Click += (_, _) => Pop();
        AutomationProperties.SetAutomationId(_back, "artifacts.file.back");
        var leading = new StackPanel { Orientation = Orientation.Horizontal, Children = { _close, _back } };
        bar.Children.Add(leading);
        Grid.SetColumn(_title, 1);
        bar.Children.Add(_title);
        Grid.SetColumn(_trailing, 2);
        _trailing.HorizontalAlignment = HorizontalAlignment.Right;
        bar.Children.Add(_trailing);
        Children.Add(bar);
        Grid.SetRow(_host, 1);
        Children.Add(_host);
    }

    /// Shows `viewer` alone (a new file from the grid).
    public void Show(ArtifactViewer viewer)
    {
        foreach (var old in _stack) CloseViewer(old);
        _stack.Clear();
        Push(viewer);
    }

    /// A linked note over the one on screen.
    public void Push(ArtifactViewer viewer)
    {
        _stack.Add(viewer);
        viewer.Changed += Refresh;
        _host.Children.Clear();
        _host.Children.Add(viewer);
        Refresh();
    }

    public void Pop()
    {
        if (_stack.Count < 2) return;
        CloseViewer(_stack[^1]);
        _stack.RemoveAt(_stack.Count - 1);
        _host.Children.Clear();
        _host.Children.Add(_stack[^1]);
        Refresh();
    }

    public void Clear()
    {
        foreach (var old in _stack) CloseViewer(old);
        _stack.Clear();
        _host.Children.Clear();
    }

    private void CloseViewer(ArtifactViewer viewer)
    {
        viewer.Changed -= Refresh;
        HermesHQ.Services.UiTree.DeactivateProgressRings(viewer);
        if (viewer is ArtifactHtmlView html) html.Close();
    }

    private void Refresh()
    {
        if (Top is not { } top) return;
        _title.Text = top.Title;
        _close.Visibility = _stack.Count == 1 ? Visibility.Visible : Visibility.Collapsed;
        _back.Visibility = _stack.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        if (_stack.Count > 1)
        {
            var before = _stack[^2].Title;
            var words = ArtifactLinks.BackUsesName(before) ? before : ArtifactPageWords.Back;
            _back.Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { new FontIcon { Glyph = "\uE72B", FontSize = 12 }, new TextBlock { Text = words } } };
            AutomationProperties.SetName(_back, before);
        }
        _trailing.Children.Clear();
        if (top.HasModes) _trailing.Children.Add(Look.Modes(top.Mode, mode => { top.SetMode(mode); Refresh(); }));
        // [WIN-PAGE-ZOOM] The level (its menu zooms) while the HTML Preview shows, as the Mac's pane bar.
        if (top is ArtifactHtmlView html && html.Mode == 0) _trailing.Children.Add(new PageZoomControls(compact: true));
        if (top.OpenInWindow is { } window)
        {
            var b = new Button { Content = new FontIcon { Glyph = "\uE8A7", FontSize = 14 }, Style = (Style)Application.Current.Resources["QuietButtonStyle"] };
            ToolTipService.SetToolTip(b, ArtifactPageWords.OpenInWindow);
            AutomationProperties.SetName(b, ArtifactPageWords.OpenInWindow);
            AutomationProperties.SetAutomationId(b, "artifact.page.window");
            b.Click += (_, _) => window();
            _trailing.Children.Add(b);
        }
        if (top.ShareFile is { } share)
        {
            var b = new Button { Content = new FontIcon { Glyph = "\uE72D", FontSize = 14 }, Style = (Style)Application.Current.Resources["QuietButtonStyle"], IsEnabled = top.IsReady };
            ToolTipService.SetToolTip(b, "Share");
            AutomationProperties.SetName(b, "Share");
            b.Click += async (_, _) =>
            {
                if (await share() is { } file) await ArtifactActions.ShareFileAsync(file, top.Title);
            };
            _trailing.Children.Add(b);
        }
    }
}
