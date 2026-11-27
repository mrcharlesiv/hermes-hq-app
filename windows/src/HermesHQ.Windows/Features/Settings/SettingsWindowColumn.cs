using Hermes.Core.Gateways;
using Hermes.Core.Settings;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using static Hermes.Core.Settings.SettingsColumnLayout;

namespace HermesHQ.Features.Settings;

/// Only the standalone window. The same native text box, gateway button and list still own input and automation.
internal sealed class SettingsWindowColumn
{
    public ScrollViewer View { get; }
    public Border Divider { get; } = new() { IsHitTestVisible = false };
    private readonly TextBox _field;
    private readonly Button _gateway;
    private readonly ListView _list;
    private readonly FontIcon _lens = new() { Glyph = "\uE721", IsHitTestVisible = false,
        HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(FieldSide, 0, 0, 0) };
    private readonly FontIcon _computer = new() { Glyph = "\uE7F4" };
    private readonly TextBlock _name = new() { FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap,
        TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 2 };
    private readonly AddressLine _address = new();
    private readonly Grid _gatewayRow;
    private readonly List<(ListViewItem Item, Grid Row, FontIcon Icon, TextBlock Label)> _rows = [];
    private XamlRoot? _display;
    private bool _marked;
    private bool _contrast;

    public SettingsWindowColumn(TextBox field, Button gateway, ListView list, Func<SettingsCategory, string> glyph)
    {
        (_field, _gateway, _list) = (field, gateway, list);
        var stack = new StackPanel { Padding = new Thickness(ColumnInset, TopInset, ColumnInset, BottomInset), Spacing = RowGap };
        View = new ScrollViewer { Content = stack, HorizontalContentAlignment = HorizontalAlignment.Stretch, IsTabStop = false,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        AutomationProperties.SetAccessibilityView(Divider, AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(_lens, AccessibilityView.Raw);
        // Overlay only the decorative glass: the whole field, native clear button, caret and focus treatment stay live.
        var search = new Grid { Margin = new Thickness(0, 0, 0, BlockGap) };
        field.MinWidth = field.MinHeight = 0;
        field.CornerRadius = new CornerRadius(FieldRadius);
        field.UseSystemFocusVisuals = true;
        _lens.SizeChanged += (_, e) => FitField(e.NewSize.Width);
        search.Children.Add(field);
        search.Children.Add(_lens);
        stack.Children.Add(search);

        var words = new StackPanel { Spacing = WordGap, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(_name);
        words.Children.Add(_address);
        _gatewayRow = Row(_computer, words);
        AutomationProperties.SetAccessibilityView(words, AccessibilityView.Raw);
        gateway.Content = _gatewayRow;
        gateway.Margin = new Thickness(0, 0, 0, BlockGap);
        gateway.UseSystemFocusVisuals = true;
        gateway.MinHeight = 0;
        gateway.Padding = new Thickness(0);
        stack.Children.Add(gateway);

        // One scroll owner, like the Mac's ScrollView around the entire VStack. No second scrollbar narrows the marks.
        ScrollViewer.SetVerticalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
        ScrollViewer.SetHorizontalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
        list.Padding = new Thickness(0);
        list.SingleSelectionFollowsFocus = false; // a keyboard ring can explore the other rows without marking one
        list.Resources["ListViewItemSelectionIndicatorVisualEnabled"] = false;
        // The native presenter insets its selected backplate even when Padding is zero. Our stretched content
        // paints the mark instead. Leave unselected hover/press and both native focus brushes alone.
        var clear = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        foreach (var key in new[] { "ListViewItemBackgroundSelected", "ListViewItemBackgroundSelectedPointerOver",
            "ListViewItemBackgroundSelectedPressed", "ListViewItemBackgroundSelectedDisabled" }) list.Resources[key] = clear;
        foreach (var c in SettingsCategories.All)
        {
            var icon = new FontIcon { Glyph = glyph(c) };
            var label = new TextBlock { Text = c.Title(), TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 1, FontWeight = FontWeights.Normal, VerticalAlignment = VerticalAlignment.Center };
            var row = Row(icon, label);
            row.Tag = c;
            AutomationProperties.SetAutomationId(row, "settings.category." + c.Key());
            var item = new ListViewItem { Content = row, Tag = c, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(0), BorderThickness = new Thickness(0), MinHeight = 0,
                Margin = new Thickness(0, 0, 0, RowGap), UseSystemFocusVisuals = true };
            AutomationProperties.SetName(item, c.Title());
            list.Items.Add(item);
            _rows.Add((item, row, icon, label));
        }
        stack.Children.Add(list);
        list.SelectionChanged += (_, _) => PaintCategories();
        View.Loaded += (_, _) => { DetachDisplay(); _display = View.XamlRoot; _display.Changed += DisplayChanged; FitTracks(); };
        View.Unloaded += (_, _) => DetachDisplay();
        ApplyTheme();
    }

    private static Grid Row(FontIcon glyph, FrameworkElement words)
    {
        var row = new Grid { Padding = new Thickness(RowSide, RowVertical, RowSide, RowVertical), ColumnSpacing = IconGap };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(IconSlot) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(glyph);
        Grid.SetColumn(words, 1);
        row.Children.Add(words);
        return row;
    }

    private void DisplayChanged(XamlRoot _, XamlRootChangedEventArgs e) => FitTracks();

    public void DetachDisplay()
    {
        if (_display != null) _display.Changed -= DisplayChanged;
        _display = null;
    }

    // As Windows text size changes the glass can be wider than FontSize; never put the caret on top of it.
    private void FitField(double lensWidth) =>
        _field.Padding = new Thickness(FieldSide + lensWidth + FieldGap, FieldVertical, FieldSide, FieldVertical);
    private void FitTracks()
    {
        var dpi = _display?.RasterizationScale ?? 1;
        var width = new SettingsColumnLayout(ThemeService.State).ColumnWidth(dpi);
        if (View.Width != width) View.Width = width;
        var line = Hairline(dpi);
        if (Divider.Width != line) Divider.Width = line;
    }

    public void ApplyTheme()
    {
        var layout = new SettingsColumnLayout(ThemeService.State);
        var radius = new CornerRadius(layout.MarkRadius);
        FitTracks();
        _field.FontSize = _name.FontSize = layout.Body;
        _lens.FontSize = layout.SearchIcon;
        FitField(_lens.ActualWidth > 0 ? _lens.ActualWidth : layout.SearchIcon);
        _computer.FontSize = layout.GatewayIcon;
        _address.SetSize(layout.Footnote);
        _gateway.CornerRadius = _gatewayRow.CornerRadius = radius;
        _list.Resources["ListViewItemCornerRadius"] = radius;
        foreach (var (item, row, icon, label) in _rows)
        {
            item.CornerRadius = row.CornerRadius = radius;
            icon.FontSize = label.FontSize = layout.Body;
        }
        ApplyPalette();
    }

    public void ApplyPalette()
    {
        _contrast = ThemeService.SystemHighContrast;
        Divider.Background = Kit.B("HQSettingsPaneLineBrush");
        _field.Background = Kit.B("HQSettingsFieldBrush");
        _field.BorderThickness = new Thickness(_contrast ? 1 : 0);
        _lens.Foreground = Kit.B("HQLabel2Brush");
        PaintCategories();
        PaintGateway();
    }

    private void PaintCategories()
    {
        for (var i = 0; i < _rows.Count; i++)
        {
            var (_, row, icon, label) = _rows[i];
            var selected = _list.SelectedIndex == i;
            row.Background = selected ? Kit.B("HQSettingsMarkBrush") : null;
            Ink(icon, label, null, _contrast && selected);
        }
    }

    public void ShowGateway(SettingsFeature.GatewayInfo info, bool marked)
    {
        _name.Text = info.Name.Length == 0 ? "Gateway" : info.Name;
        _address.Show(info.Host); // two separate roles even when the name is the address
        _marked = marked;
        PaintGateway();
    }

    private void PaintGateway()
    {
        _gatewayRow.Background = _marked ? Kit.B("HQSettingsMarkBrush") : null;
        Ink(_computer, _name, _address.Words, _contrast && _marked);
    }

    // A selected rich row in Windows contrast is HighlightText on Highlight, without WinUI's Window-colour
    // text backplate. Unmarked controls inherit the native presenter's ink (including pointer-over and pressed).
    private void Ink(FontIcon icon, TextBlock name, TextBlock? address, bool onHighlight)
    {
        void Paint(UIElement element, DependencyProperty ink, string key)
        {
            if (onHighlight)
            {
                element.SetValue(ink, Kit.B("HQOnTintBrush"));
                element.HighContrastAdjustment = ElementHighContrastAdjustment.None;
            }
            else
            {
                element.ClearValue(UIElement.HighContrastAdjustmentProperty);
                if (_contrast) element.ClearValue(ink); else element.SetValue(ink, Kit.B(key));
            }
        }
        Paint(icon, IconElement.ForegroundProperty, "HQTintTextBrush");
        Paint(name, TextBlock.ForegroundProperty, "HQLabelBrush");
        if (address != null) Paint(address, TextBlock.ForegroundProperty, "HQLabel2Brush");
    }

    // The address is one line cut in the middle, not a fixed character count. The zero-size canvas measures in the
    // button's actual font, including Windows text scaling. Refitting starts with the whole address on every measure.
    private sealed class AddressLine : Grid
    {
        public TextBlock Words { get; } = new() { MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis };
        private readonly TextBlock _measure = new() { Opacity = 0, IsHitTestVisible = false };
        private string _whole = "";
        public AddressLine()
        {
            Children.Add(Words);
            var ruler = new Canvas { Width = 0, Height = 0, IsHitTestVisible = false };
            AutomationProperties.SetAccessibilityView(ruler, AccessibilityView.Raw);
            AutomationProperties.SetAccessibilityView(_measure, AccessibilityView.Raw);
            ruler.Children.Add(_measure);
            Children.Add(ruler);
        }
        public void Show(string host) { if (host != _whole) { _whole = host; InvalidateMeasure(); } }
        public void SetSize(double size) => Words.FontSize = _measure.FontSize = size;
        protected override Size MeasureOverride(Size available)
        {
            var shown = GatewayFootFit.Name(_whole, available.Width, text => {
                _measure.Text = text;
                _measure.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                return _measure.DesiredSize.Width;
            });
            _measure.Text = "";
            if (Words.Text != shown) Words.Text = shown;
            return base.MeasureOverride(available);
        }
    }
}
