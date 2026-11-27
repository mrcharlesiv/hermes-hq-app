using Hermes.Core.Transcripts;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Windows.Foundation;
using Windows.UI.ViewManagement;

namespace HermesHQ.Features.ChatFind;

/// ChatFindBar.arrange(stacked:) at Mac 1250. Change cells, not views: a resize never takes
/// the caret, selection, keyboard order or automation peer away from the person typing.
internal sealed partial class ChatFindRows : Panel
{
    private readonly Grid _rows = new(), _controls = new();
    private readonly TextBox _field;
    private readonly FontIcon _magnifier = new()
    {
        Glyph = "\uE721", Margin = new Thickness(8, 0, 6, 0),
        HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center,
        IsTextScaleFactorEnabled = true, IsHitTestVisible = false, IsTabStop = false,
    };
    // WinUI 1.8 DefaultTextBoxStyle: the trailing DeleteButton has a 30-DIP column when shown.
    private const double ClearButtonWidth = 30;
    private readonly Button _done;
    private readonly TextBlock _count, _reserve, _naturalCount;
    private readonly UISettings _settings = new();
    private bool _stacked;

    internal ChatFindRows(TextBox field, TextBlock count, Button previous, Button next, Button done)
    {
        _field = field;
        _done = done;
        _count = count;
        // Measure in the count's current font, outside its grid. A count wrapped on the
        // second row must not report that constrained width as its natural width.
        Binding FromCount(string property) => new() { Source = count, Path = new PropertyPath(property), Mode = BindingMode.OneWay };
        TextBlock WidthProbe(string text)
        {
            var probe = new TextBlock { Text = text, Opacity = 0, IsHitTestVisible = false };
            probe.SetBinding(TextBlock.FontFamilyProperty, FromCount(nameof(TextBlock.FontFamily)));
            probe.SetBinding(TextBlock.FontSizeProperty, FromCount(nameof(TextBlock.FontSize)));
            probe.SetBinding(TextBlock.IsTextScaleFactorEnabledProperty, FromCount(nameof(TextBlock.IsTextScaleFactorEnabled)));
            AutomationProperties.SetAccessibilityView(probe, AccessibilityView.Raw);
            Children.Add(probe);
            return probe;
        }
        _reserve = WidthProbe("No Results Yet");
        _naturalCount = WidthProbe(count.Text);
        Children.Add(_rows);
        _rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto, MinHeight = 40 });
        _rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _rows.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _rows.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        // Overlay the native edit, so a click through the glass is still a click in the field.
        // Follow the edit's theme brush, including live Windows contrast-theme changes.
        _magnifier.SetBinding(IconElement.ForegroundProperty, new Binding
        {
            Source = field, Path = new PropertyPath(nameof(TextBox.Foreground)), Mode = BindingMode.OneWay,
        });
        AutomationProperties.SetAccessibilityView(_magnifier, AccessibilityView.Raw);
        _rows.Children.Add(field);
        _rows.Children.Add(_magnifier);
        _rows.Children.Add(_controls);
        _controls.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        foreach (var width in new[] { GridLength.Auto, GridLength.Auto, new GridLength(ChatFindLayout.Gap), GridLength.Auto })
            _controls.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        foreach (var (element, col) in new (FrameworkElement, int)[] { (count, 0), (previous, 1), (next, 2), (done, 4) })
        {
            Grid.SetColumn(element, col);
            _controls.Children.Add(element);
        }
        Place(false);
        Loaded += (_, _) => { _settings.TextScaleFactorChanged += TextScaleChanged; InvalidateMeasure(); };
        Unloaded += (_, _) => _settings.TextScaleFactorChanged -= TextScaleChanged;
    }

    private void TextScaleChanged(UISettings settings, object args)
    {
        if (Services.AppShutdown.Stopping) return;
        DispatcherQueue.TryEnqueue(() => { if (!Services.AppShutdown.Stopping && IsLoaded) InvalidateMeasure(); });
    }

    internal void SetCount(string text)
    {
        if (_count.Text != text)
        {
            _count.Text = _naturalCount.Text = text;
            InvalidateMeasure(); // a new result or step can cross the breakpoint without a resize
        }
        _count.Visibility = text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Place(bool stacked)
    {
        _stacked = stacked;
        Grid.SetColumnSpan(_field, stacked ? 2 : 1);
        Grid.SetColumnSpan(_magnifier, stacked ? 2 : 1);
        Grid.SetRow(_controls, stacked ? 1 : 0);
        Grid.SetColumn(_controls, stacked ? 0 : 1);
        Grid.SetColumnSpan(_controls, stacked ? 2 : 1);
        _controls.Margin = stacked ? new Thickness(0, 2, 0, 0) : new Thickness(ChatFindLayout.Gap, 0, 0, 0);
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        var free = new Size(double.PositiveInfinity, double.PositiveInfinity);
        // macField(): cap-height glass with 8 leading and 6 clear of the caret. Measure the
        // actual scaled glyph with its margins; the TextBox uses Padding for both text and placeholder.
        _field.ApplyTemplate();
        var fontSize = Math.Round(_field.FontSize * 0.82, MidpointRounding.AwayFromZero);
        if (_magnifier.FontSize != fontSize) _magnifier.FontSize = fontSize;
        _magnifier.Measure(free);
        var leading = _magnifier.DesiredSize.Width;
        var padding = _field.Padding;
        if (padding.Left != leading) _field.Padding = new Thickness(leading, padding.Top, padding.Right, padding.Bottom);
        _reserve.Measure(free);
        _naturalCount.Measure(free);
        _done.Measure(free);
        // MinimumField is room to edit, not the outer TextBox. Budget for clearing even while
        // empty so typing doesn't change rows. Zero *host* width means not yet measured.
        var usable = availableSize.Width - leading - padding.Right - ClearButtonWidth;
        var stacked = (availableSize.Width > 0 && usable <= 0) || ChatFindLayout.Stacked(usable,
            _reserve.DesiredSize.Width, _naturalCount.DesiredSize.Width, _done.DesiredSize.Width, _settings.TextScaleFactor, _stacked);
        if (_stacked != stacked) Place(stacked);
        _rows.Measure(availableSize);
        return _rows.DesiredSize;
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        _reserve.Arrange(new Rect(0, 0, 0, 0));
        _naturalCount.Arrange(new Rect(0, 0, 0, 0));
        _rows.Arrange(new Rect(0, 0, finalSize.Width, finalSize.Height));
        return finalSize;
    }
}
