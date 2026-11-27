using Hermes.Core.Voice;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace HermesHQ.Features.Voice;

/// Port of App/Chat/Voice/TalkDockView.swift: hosts both the live Talk conversation bar
/// (equalizer visual, status/bot/elapsed clock, live words, inline problem strip, route menu,
/// mute toggle, center Send Now / Interrupt / Stop / Unmute button, and End button) and the
/// paused/stopped TalkNoticeDock card.
public sealed class TalkDockView : UserControl
{
    private readonly TalkController _controller;

    // Live bar controls
    private readonly StackPanel _livePanel;
    private readonly LiveWordsView _liveWords;
    private readonly Border _inlineProblemBar;
    private readonly TextBlock _inlineProblemText;
    private readonly Button _inlineCopyBtn;
    private readonly TalkVisualView _visual;
    private readonly TextBlock _statusText;
    private readonly TextBlock _subText;
    private readonly TextBlock _elapsedText;
    private readonly Button _routeBtn;
    private readonly FontIcon _routeIcon;
    private readonly Button _muteBtn;
    private readonly FontIcon _muteIcon;
    private readonly Button _centerBtn;
    private readonly Button _endBtn;

    // Notice dock controls (paused / stopped)
    private readonly StackPanel _noticePanel;
    private readonly FontIcon _noticeGlyph;
    private readonly TextBlock _noticeTitle;
    private readonly TextBlock _noticeMessage;
    private readonly TextBlock _noticeDetail;
    private readonly Button _noticePrimaryBtn;
    private readonly Button _noticeCopyBtn;
    private readonly Button _noticeDoneBtn;

    private TalkDockSnapshot? _last;

    public TalkDockView(TalkController controller)
    {
        _controller = controller;

        AutomationProperties.SetAutomationId(this, "talk.dock");

        // --- Live Bar ---
        _liveWords = new LiveWordsView(maxLines: 2);

        _inlineProblemText = new TextBlock
        {
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Foreground = ThemeBrushes.Get("SystemFillColorCautionBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        _inlineCopyBtn = new Button
        {
            Content = "Copy Details",
            FontSize = 11,
            Padding = new Thickness(8, 2, 8, 2),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
        };
        _inlineCopyBtn.Click += async (_, _) => await CopyNoticeAsync(_last?.InlineProblem, _inlineCopyBtn);
        var inlineGrid = new Grid { ColumnSpacing = 8 };
        inlineGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        inlineGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_inlineProblemText, 0);
        Grid.SetColumn(_inlineCopyBtn, 1);
        inlineGrid.Children.Add(_inlineProblemText);
        inlineGrid.Children.Add(_inlineCopyBtn);
        _inlineProblemBar = new Border
        {
            Child = inlineGrid,
            Padding = new Thickness(8, 4, 8, 4),
            CornerRadius = new CornerRadius(8),
            Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush"),
            Visibility = Visibility.Collapsed,
        };

        _visual = new TalkVisualView(TalkVisualSize.Dock);

        _statusText = new TextBlock
        {
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        };
        AutomationProperties.SetAutomationId(_statusText, "talk.dock.status");

        _subText = new TextBlock
        {
            FontSize = 12,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        };

        _elapsedText = new TextBlock
        {
            FontSize = 12,
            FontFamily = ThemeBrushes.Res<FontFamily>("CodeFont"),
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetAutomationId(_elapsedText, "talk.dock.elapsed");

        var metaLine = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        metaLine.Children.Add(_subText);
        metaLine.Children.Add(_elapsedText);

        var labelCol = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        labelCol.Children.Add(_statusText);
        labelCol.Children.Add(metaLine);

        _routeIcon = new FontIcon { Glyph = "\uE767", FontSize = 14 };
        _routeBtn = new Button
        {
            Content = _routeIcon,
            MinWidth = 34,
            MinHeight = 34,
            Padding = new Thickness(6),
            CornerRadius = new CornerRadius(17),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_routeBtn, "talk.dock.route");
        AutomationProperties.SetName(_routeBtn, "Audio route and speaker");
        ToolTipService.SetToolTip(_routeBtn, "Audio output and speaker");
        _routeBtn.Click += (_, _) =>
        {
            var menu = TalkRouteMenu.BuildAudioRouteFlyout(_controller);
            menu.ShowAt(_routeBtn);
        };

        _muteIcon = new FontIcon { Glyph = "\uE720", FontSize = 14 };
        _muteBtn = new Button
        {
            Content = _muteIcon,
            MinWidth = 34,
            MinHeight = 34,
            Padding = new Thickness(6),
            CornerRadius = new CornerRadius(17),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_muteBtn, "talk.dock.mute");
        AutomationProperties.SetName(_muteBtn, "Mute microphone");
        ToolTipService.SetToolTip(_muteBtn, "Mute / Unmute");
        _muteBtn.Click += (_, _) => _controller.ToggleMute();

        _centerBtn = new Button
        {
            FontSize = 12,
            Padding = new Thickness(12, 5, 12, 5),
            CornerRadius = new CornerRadius(16),
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_centerBtn, "talk.dock.center");
        _centerBtn.Click += (_, _) => OnCenterAction();

        _endBtn = new Button
        {
            Content = "End",
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Padding = new Thickness(14, 5, 14, 5),
            CornerRadius = new CornerRadius(16),
            Background = ThemeBrushes.Get("SystemFillColorCriticalBrush"),
            Foreground = ThemeBrushes.Get("TextOnAccentFillColorPrimaryBrush"),
        };
        AutomationProperties.SetAutomationId(_endBtn, "talk.dock.end");
        AutomationProperties.SetName(_endBtn, "End voice conversation");
        _endBtn.Click += (_, _) => _controller.End(TalkEnd.User);

        var controlsRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        controlsRow.Children.Add(_routeBtn);
        controlsRow.Children.Add(_muteBtn);
        controlsRow.Children.Add(_centerBtn);
        controlsRow.Children.Add(_endBtn);

        var mainBar = new Grid { ColumnSpacing = 12, MinHeight = 42 };
        mainBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        mainBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        mainBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_visual, 0);
        Grid.SetColumn(labelCol, 1);
        Grid.SetColumn(controlsRow, 2);
        mainBar.Children.Add(_visual);
        mainBar.Children.Add(labelCol);
        mainBar.Children.Add(controlsRow);

        _livePanel = new StackPanel { Spacing = 6 };
        _livePanel.Children.Add(_liveWords);
        _livePanel.Children.Add(_inlineProblemBar);
        _livePanel.Children.Add(mainBar);

        // --- Notice Dock (paused / stopped) ---
        _noticeGlyph = new FontIcon { Glyph = "\uE7BA", FontSize = 18, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) };
        _noticeTitle = new TextBlock { FontSize = 14, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
        AutomationProperties.SetAutomationId(_noticeTitle, "talk.notice.title");
        _noticeMessage = new TextBlock
        {
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
        };
        _noticeDetail = new TextBlock
        {
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            FontFamily = ThemeBrushes.Res<FontFamily>("CodeFont"),
            Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
            Visibility = Visibility.Collapsed,
        };

        _noticePrimaryBtn = new Button
        {
            FontSize = 12,
            Padding = new Thickness(12, 5, 12, 5),
            Style = ThemeBrushes.Res<Style>("AccentButtonStyle"),
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_noticePrimaryBtn, "talk.notice.primary");
        _noticePrimaryBtn.Click += (_, _) => OnNoticePrimaryAction();

        _noticeCopyBtn = new Button
        {
            Content = "Copy Details",
            FontSize = 12,
            Padding = new Thickness(10, 5, 10, 5),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_noticeCopyBtn, "talk.notice.copy");
        _noticeCopyBtn.Click += async (_, _) => await CopyNoticeAsync(_last?.Notice, _noticeCopyBtn);

        _noticeDoneBtn = new Button
        {
            Content = "Done",
            FontSize = 12,
            Padding = new Thickness(12, 5, 12, 5),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_noticeDoneBtn, "talk.notice.done");
        _noticeDoneBtn.Click += (_, _) =>
        {
            if (_controller.IsActive) _controller.End(TalkEnd.User);
            else _controller.DismissNotice();
        };

        var noticeActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 8, 0, 0) };
        noticeActions.Children.Add(_noticePrimaryBtn);
        noticeActions.Children.Add(_noticeCopyBtn);
        noticeActions.Children.Add(_noticeDoneBtn);

        var noticeWords = new StackPanel { Spacing = 2 };
        noticeWords.Children.Add(_noticeTitle);
        noticeWords.Children.Add(_noticeMessage);
        noticeWords.Children.Add(_noticeDetail);
        noticeWords.Children.Add(noticeActions);

        var noticeGrid = new Grid { ColumnSpacing = 10 };
        noticeGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        noticeGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(_noticeGlyph, 0);
        Grid.SetColumn(noticeWords, 1);
        noticeGrid.Children.Add(_noticeGlyph);
        noticeGrid.Children.Add(noticeWords);

        _noticePanel = new StackPanel { Visibility = Visibility.Collapsed };
        _noticePanel.Children.Add(noticeGrid);

        var host = new Grid();
        host.Children.Add(_livePanel);
        host.Children.Add(_noticePanel);
        Content = new Border
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(14, 10, 14, 10),
            BorderThickness = new Thickness(1),
            Background = ThemeBrushes.Get("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = ThemeBrushes.Get("CardStrokeColorDefaultBrush"),
            Child = host,
        };
    }

    public void Update(TalkState state)
    {
        var snap = state.Dock;
        _last = snap;

        if (snap.Phase == TalkDockPhase.Notice)
        {
            _livePanel.Visibility = Visibility.Collapsed;
            _noticePanel.Visibility = Visibility.Visible;
            _visual.SetVisual(TalkDockVisual.Muted, active: false);
            RenderNoticeDock(snap.Notice);
            return;
        }

        _noticePanel.Visibility = Visibility.Collapsed;
        _livePanel.Visibility = Visibility.Visible;

        _visual.SetVisual(snap.Visual, active: snap.Phase == TalkDockPhase.Live);
        _visual.SetLevel(state.Level);

        _statusText.Text = snap.StatusText;
        _subText.Text = snap.SubText;
        _elapsedText.Text = snap.ElapsedText;
        _elapsedText.Visibility = snap.ShowElapsed ? Visibility.Visible : Visibility.Collapsed;

        _liveWords.Update(snap.LiveWords, showWhenEmpty: false);

        if (snap.InlineProblem is { } prob)
        {
            _inlineProblemText.Text = $"{prob.Title}: {prob.Message}";
            _inlineCopyBtn.Visibility = prob.Copies ? Visibility.Visible : Visibility.Collapsed;
            _inlineProblemBar.Visibility = Visibility.Visible;
        }
        else
        {
            _inlineProblemBar.Visibility = Visibility.Collapsed;
        }

        var ctrl = snap.Controls;
        _routeBtn.Visibility = ctrl.ShowSpeaker ? Visibility.Visible : Visibility.Collapsed;
        _routeIcon.Glyph = ctrl.SpeakerActive ? "\uE767" : "\uE74F";
        ToolTipService.SetToolTip(_routeBtn, $"{TalkDockState.RouteLabel(snap.ActiveRoute)} · {(ctrl.SpeakerActive ? "Replies spoken" : "Replies muted")}");

        _muteBtn.Visibility = ctrl.ShowMute ? Visibility.Visible : Visibility.Collapsed;
        _muteIcon.Glyph = ctrl.IsMuted ? "\uEC54" : "\uE720";
        AutomationProperties.SetName(_muteBtn, ctrl.IsMuted ? "Unmute microphone" : "Mute microphone");

        _centerBtn.Content = ctrl.CenterLabel;
        _centerBtn.Visibility = ctrl.Center != TalkDockCenter.None ? Visibility.Visible : Visibility.Collapsed;
        _centerBtn.IsEnabled = ctrl.CenterEnabled;
    }

    public void SetLevel(double level) => _visual.SetLevel(level);

    private void RenderNoticeDock(TalkNotice? notice)
    {
        _noticeTitle.Text = notice?.Title ?? "Voice Chat Paused";
        _noticeMessage.Text = notice?.Message ?? "Click Resume to keep talking, or Done to close.";
        var hasDetail = !string.IsNullOrWhiteSpace(notice?.Detail);
        _noticeDetail.Text = notice?.Detail ?? "";
        _noticeDetail.Visibility = hasDetail ? Visibility.Visible : Visibility.Collapsed;

        _noticeGlyph.Glyph = notice?.Fatal == true ? "\uEA39" : "\uE7BA";
        _noticeGlyph.Foreground = ThemeBrushes.Get(notice?.Fatal == true
            ? "SystemFillColorCriticalBrush"
            : "SystemFillColorCautionBrush");

        var primaryLabel = notice?.ActionTitle;
        _noticePrimaryBtn.Content = primaryLabel ?? "";
        _noticePrimaryBtn.Visibility = !string.IsNullOrEmpty(primaryLabel) ? Visibility.Visible : Visibility.Collapsed;
        _noticeCopyBtn.Visibility = notice?.Copies == true ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnCenterAction()
    {
        if (_last == null) return;
        switch (_last.Controls.Center)
        {
            case TalkDockCenter.SendNow: _controller.SendNow(); break;
            case TalkDockCenter.Interrupt or TalkDockCenter.Stop: _controller.Interrupt(); break;
            case TalkDockCenter.Unmute: _controller.ToggleMute(); break;
        }
    }

    private void OnNoticePrimaryAction()
    {
        var action = _last?.Notice?.Action ?? TalkNoticeAction.None;
        switch (action)
        {
            case TalkNoticeAction.OpenSettings:
                VoiceMemosFeature.OpenMicrophoneSettings();
                break;
            case TalkNoticeAction.VoiceSettings:
                SettingsWindows.Show("voice");
                break;
            case TalkNoticeAction.Resume or TalkNoticeAction.Retry:
                _ = _controller.ResumeAsync();
                break;
            case TalkNoticeAction.SwitchToClassic:
                _controller.SetPreferredEngine(TalkEngine.Classic);
                _ = _controller.ResumeAsync();
                break;
            case TalkNoticeAction.Dismiss:
                _controller.DismissNotice();
                break;
        }
    }

    private async Task CopyNoticeAsync(TalkNotice? notice, Button button)
    {
        var text = TalkDockState.CopyText(notice, _controller.Events);
        if (string.IsNullOrEmpty(text)) return;
        try
        {
            var pkg = new DataPackage();
            pkg.SetText(text);
            Clipboard.SetContent(pkg);
            var prev = button.Content;
            button.Content = "Copied";
            await Task.Delay(1500);
            if (button.Content as string == "Copied") button.Content = prev;
        }
        catch (Exception) { }
    }
}
