using Hermes.Core.Transcripts;
using HermesHQ.Features.Settings;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Controls;

// [mermaid] Inline Mermaid diagram card inside a chat bubble (App/Chat/Cells/MermaidCardView.swift):
// header `"Mermaid · <kindLabel>"`, Copy Source, Expand button, vector Canvas preview, and right-click menu.
public sealed partial class MermaidCardView : UserControl
{
    internal const string InlineMermaidTag = "chat.markdown.inline-mermaid";

    private readonly MermaidDiagram _diagram;
    private readonly ContentControl _diagramHost;
    private readonly FontIcon _copyIcon;
    private readonly Button _copyButton;

    public MermaidCardView(MermaidDiagram diagram)
    {
        _diagram = diagram;
        Tag = InlineMermaidTag;
        Margin = new Thickness(0, 2, 0, 10);
        HorizontalAlignment = HorizontalAlignment.Stretch;

        var title = new TextBlock
        {
            Text = $"Mermaid · {diagram.KindLabel}",
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get("HQLabel2Brush"),
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };

        _copyIcon = new FontIcon { Glyph = "\uE8C8", FontSize = 12, Foreground = ThemeBrushes.Get("HQLabel2Brush") };
        _copyButton = new Button
        {
            Content = _copyIcon,
            Width = 30,
            Height = 28,
            Padding = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(6),
        };
        ToolTipService.SetToolTip(_copyButton, "Copy Mermaid Source");
        AutomationProperties.SetName(_copyButton, "Copy Mermaid Source");
        AutomationProperties.SetAutomationId(_copyButton, "mermaid.card.copy");
        _copyButton.Click += async (_, _) => await CopySourceAsync();

        var expandBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE740", FontSize = 12, Foreground = ThemeBrushes.Get("HQLabel2Brush") },
            Width = 30,
            Height = 28,
            Padding = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(6),
        };
        ToolTipService.SetToolTip(expandBtn, "Expand Diagram");
        AutomationProperties.SetName(expandBtn, "Expand Diagram");
        AutomationProperties.SetAutomationId(expandBtn, "mermaid.card.expand");
        expandBtn.Click += async (_, _) => await ExpandAsync();

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        actions.Children.Add(_copyButton);
        actions.Children.Add(expandBtn);

        var header = new Grid { Height = 34, Padding = new Thickness(12, 0, 6, 0) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(title, 0);
        Grid.SetColumn(actions, 1);
        header.Children.Add(title);
        header.Children.Add(actions);

        _diagramHost = new ContentControl
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
            IsTabStop = false,
            MinHeight = 120,
            MaxHeight = 360,
            Padding = new Thickness(8, 2, 8, 10),
        };

        var surface = new Button
        {
            Content = _diagramHost,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(0),
        };
        AutomationProperties.SetName(surface, $"Open {diagram.KindLabel}");
        AutomationProperties.SetAutomationId(surface, "mermaid.card");
        surface.Click += async (_, _) => await ExpandAsync();
        surface.ContextFlyout = BuildContextMenu();

        var stack = new StackPanel();
        stack.Children.Add(header);
        stack.Children.Add(surface);

        Content = new Border
        {
            Child = stack,
            CornerRadius = new CornerRadius(10),
            Background = ThemeBrushes.Get("HQCodeFillBrush"),
            BorderBrush = ThemeBrushes.Get("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };

        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        RenderDiagram();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ThemeService.Changed -= OnThemeChanged;
        ThemeService.Changed += OnThemeChanged;
        RenderDiagram();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        ThemeService.Changed -= OnThemeChanged;
    }

    private void OnThemeChanged() => RenderDiagram();

    private void RenderDiagram()
    {
        var canvas = MermaidRenderer.RenderCanvas(_diagram);
        _diagramHost.Content = new Viewbox
        {
            Child = canvas,
            Stretch = Stretch.Uniform,
            StretchDirection = StretchDirection.DownOnly,
            MaxHeight = 344,
        };
    }

    private MenuFlyout BuildContextMenu()
    {
        var menu = new MenuFlyout();
        var expand = new MenuFlyoutItem { Text = "Expand Diagram", Icon = new FontIcon { Glyph = "\uE740" } };
        expand.Click += async (_, _) => await ExpandAsync();
        var copy = new MenuFlyoutItem { Text = "Copy Mermaid Source", Icon = new FontIcon { Glyph = "\uE8C8" } };
        copy.Click += async (_, _) => await CopySourceAsync();
        menu.Items.Add(expand);
        menu.Items.Add(copy);
        return menu;
    }

    private Task ExpandAsync() => XamlRoot == null ? Task.CompletedTask : MermaidDialog.ShowAsync(XamlRoot, _diagram);

    private async Task CopySourceAsync()
    {
        if (!SafeClipboard.TrySetText(_diagram.Source)) return;
        _copyIcon.Glyph = "\uE73E";
        try
        {
            await Task.Delay(1500);
            _copyIcon.Glyph = "\uE8C8";
        }
        catch (Exception) { }
    }
}
