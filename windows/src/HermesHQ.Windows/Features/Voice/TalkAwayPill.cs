using Hermes.Core.Voice;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Voice;

/// Port of App/Chat/Voice/TalkAwayPill.swift: floating pill shown when the user navigates
/// away from an active Talk conversation, letting them jump right back or end the call.
public sealed class TalkAwayPillView : UserControl
{
    private readonly TalkVisualView _visual;
    private readonly TextBlock _title;
    private readonly TextBlock _elapsed;
    private readonly TextBlock _subtitle;
    private readonly Button _returnBtn;
    private readonly Button _endBtn;

    public event Action? ReturnClicked;
    public event Action? EndClicked;

    public TalkAwayPillView()
    {
        Margin = new Thickness(12, 10, 12, 10);
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Top;
        Visibility = Visibility.Collapsed;
        AutomationProperties.SetAutomationId(this, "talk.awayPill");

        _visual = new TalkVisualView(TalkVisualSize.Indicator);

        _title = new TextBlock
        {
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        _elapsed = new TextBlock
        {
            FontSize = 12,
            FontFamily = ThemeBrushes.Res<FontFamily>("CodeFont"),
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        _subtitle = new TextBlock
        {
            FontSize = 11,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };

        var topLine = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        topLine.Children.Add(_title);
        topLine.Children.Add(_elapsed);

        var textCol = new StackPanel { Spacing = 0, VerticalAlignment = VerticalAlignment.Center };
        textCol.Children.Add(topLine);
        textCol.Children.Add(_subtitle);

        var pillBody = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        pillBody.Children.Add(_visual);
        pillBody.Children.Add(textCol);

        _returnBtn = new Button
        {
            Content = pillBody,
            Padding = new Thickness(4, 2, 6, 2),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_returnBtn, "talk.awayPill.return");
        AutomationProperties.SetName(_returnBtn, "Return to active voice conversation");
        _returnBtn.Click += (_, _) => ReturnClicked?.Invoke();

        _endBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE711", FontSize = 11 },
            MinWidth = 28,
            MinHeight = 28,
            Padding = new Thickness(4),
            CornerRadius = new CornerRadius(14),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_endBtn, "talk.awayPill.end");
        AutomationProperties.SetName(_endBtn, "End voice conversation");
        ToolTipService.SetToolTip(_endBtn, "End voice conversation");
        _endBtn.Click += (_, _) => EndClicked?.Invoke();

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(_returnBtn);
        row.Children.Add(_endBtn);
        Content = new Border
        {
            CornerRadius = new CornerRadius(20),
            Padding = new Thickness(12, 6, 8, 6),
            BorderThickness = new Thickness(1),
            Background = ThemeBrushes.Get("AcrylicInAppFillColorDefaultBrush"),
            BorderBrush = ThemeBrushes.Get("CardStrokeColorDefaultBrush"),
            Child = row,
        };
    }

    public void Update(TalkAwayPillContent pill, double level)
    {
        if (!pill.Visible)
        {
            Visibility = Visibility.Collapsed;
            _visual.SetVisual(TalkDockVisual.Muted, active: false);
            return;
        }

        Visibility = Visibility.Visible;
        _title.Text = pill.Title;
        _elapsed.Text = pill.Elapsed;
        _subtitle.Text = pill.Subtitle;
        _title.Foreground = ThemeBrushes.Get(pill.IsError
            ? "SystemFillColorCriticalBrush"
            : "TextFillColorPrimaryBrush");

        _visual.SetVisual(pill.Visual, active: !pill.IsPaused && !pill.IsError);
        _visual.SetLevel(level);
    }

    public void SetLevel(double level) => _visual.SetLevel(level);
}
