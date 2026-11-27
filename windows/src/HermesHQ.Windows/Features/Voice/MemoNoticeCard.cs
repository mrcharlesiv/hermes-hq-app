using Hermes.Core.Voice;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace HermesHQ.Features.Voice;

/// Port of App/Chat/Voice/MemoNoticeCard.swift: persistent voice notice card above the composer
/// (permission denied, mic unavailable, saved as draft, no transcript, upload/dictation retry).
public sealed class MemoNoticeCardView : UserControl
{
    private readonly FontIcon _glyph;
    private readonly TextBlock _title;
    private readonly TextBlock _message;
    private readonly TextBlock _detail;
    private readonly Button _actionBtn;
    private readonly Button _copyBtn;
    private readonly Button _closeBtn;
    private readonly StackPanel _actionsRow;

    private MemoNotice? _notice;

    public event Action<MemoNoticeAction>? ActionClicked;
    public event Action? DismissClicked;

    public MemoNoticeCardView()
    {
        Margin = new Thickness(0, 0, 0, 6);
        Visibility = Visibility.Collapsed;
        AutomationProperties.SetAutomationId(this, MemoNoticeCard.Id);

        _glyph = new FontIcon
        {
            FontSize = 16,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 2, 0, 0),
        };

        _title = new TextBlock
        {
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        };
        AutomationProperties.SetAutomationId(_title, MemoNoticeCard.TitleId);

        _message = new TextBlock
        {
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
        };
        AutomationProperties.SetAutomationId(_message, MemoNoticeCard.MessageId);

        _detail = new TextBlock
        {
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            FontFamily = ThemeBrushes.Res<FontFamily>("CodeFont"),
            Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
            Visibility = Visibility.Collapsed,
            Margin = new Thickness(0, 2, 0, 0),
        };

        _actionBtn = new Button
        {
            FontSize = 12,
            Padding = new Thickness(10, 4, 10, 4),
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_actionBtn, MemoNoticeCard.ActionId);
        _actionBtn.Click += (_, _) =>
        {
            if (_notice?.Action is { } act) ActionClicked?.Invoke(act);
        };

        _copyBtn = new Button
        {
            Content = MemoNoticeCard.CopyTitle,
            FontSize = 12,
            Padding = new Thickness(10, 4, 10, 4),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_copyBtn, MemoNoticeCard.CopyId);
        _copyBtn.Click += async (_, _) => await CopyDetailsAsync();

        _actionsRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Margin = new Thickness(0, 6, 0, 0),
            Visibility = Visibility.Collapsed,
        };
        _actionsRow.Children.Add(_actionBtn);
        _actionsRow.Children.Add(_copyBtn);

        _closeBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE711", FontSize = 11 },
            MinWidth = 28,
            MinHeight = 28,
            Padding = new Thickness(4),
            VerticalAlignment = VerticalAlignment.Top,
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_closeBtn, MemoNoticeCard.CloseId);
        AutomationProperties.SetName(_closeBtn, MemoNoticeCard.CloseLabel);
        ToolTipService.SetToolTip(_closeBtn, MemoNoticeCard.CloseLabel);
        _closeBtn.Click += (_, _) => DismissClicked?.Invoke();

        var body = new StackPanel { Spacing = 2 };
        body.Children.Add(_title);
        body.Children.Add(_message);
        body.Children.Add(_detail);
        body.Children.Add(_actionsRow);

        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        Grid.SetColumn(_glyph, 0);
        Grid.SetColumn(body, 1);
        Grid.SetColumn(_closeBtn, 2);
        grid.Children.Add(_glyph);
        grid.Children.Add(body);
        grid.Children.Add(_closeBtn);

        Content = new Border
        {
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(12, 10, 10, 10),
            BorderThickness = new Thickness(1),
            Background = ThemeBrushes.Get("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = ThemeBrushes.Get("CardStrokeColorDefaultBrush"),
            Child = grid,
        };
    }

    public void Update(MemoNotice? notice)
    {
        _notice = notice;
        if (notice == null)
        {
            Visibility = Visibility.Collapsed;
            return;
        }

        Visibility = Visibility.Visible;
        _title.Text = notice.Title;
        _message.Text = notice.Message;

        var hasDetail = !string.IsNullOrWhiteSpace(notice.Detail);
        _detail.Text = notice.Detail ?? "";
        _detail.Visibility = hasDetail ? Visibility.Visible : Visibility.Collapsed;

        switch (notice.Tone)
        {
            case MemoNoticeTone.Error:
                _glyph.Glyph = "\uEA39";
                _glyph.Foreground = ThemeBrushes.Get("SystemFillColorCriticalBrush");
                break;
            case MemoNoticeTone.Warning:
                _glyph.Glyph = "\uE7BA";
                _glyph.Foreground = ThemeBrushes.Get("SystemFillColorCautionBrush");
                break;
            default:
                _glyph.Glyph = "\uE946";
                _glyph.Foreground = ThemeBrushes.Get("AccentFillColorDefaultBrush");
                break;
        }

        var showAction = notice.ActionTitle is { Length: > 0 };
        _actionBtn.Content = notice.ActionTitle ?? "";
        _actionBtn.Visibility = showAction ? Visibility.Visible : Visibility.Collapsed;

        var showCopy = MemoNoticeCard.ShowsCopy(notice);
        _copyBtn.Content = MemoNoticeCard.CopyTitle;
        _copyBtn.Visibility = showCopy ? Visibility.Visible : Visibility.Collapsed;
        _actionsRow.Visibility = showAction || showCopy ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task CopyDetailsAsync()
    {
        var text = MemoNoticeCard.CopyText(_notice);
        if (string.IsNullOrEmpty(text)) return;
        try
        {
            var pkg = new DataPackage();
            pkg.SetText(text);
            Clipboard.SetContent(pkg);
            _copyBtn.Content = "Copied";
            await Task.Delay(1500);
            if (_copyBtn.Content as string == "Copied") _copyBtn.Content = MemoNoticeCard.CopyTitle;
        }
        catch (Exception) { }
    }
}
