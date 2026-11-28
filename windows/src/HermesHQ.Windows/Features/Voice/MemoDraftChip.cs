using Hermes.Core.Voice;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;

namespace HermesHQ.Features.Voice;

/// Port of App/Chat/Voice/MemoDraftChip.swift: reviewable voice memo draft chip sitting
/// above the composer with Play/Pause, duration, mini waveform preview, Send, and Discard.
public sealed class MemoDraftChip : UserControl
{
    private const int MiniBars = 18;

    private readonly Button _playBtn;
    private readonly FontIcon _playIcon;
    private readonly ProgressRing _spinner;
    private readonly TextBlock _title;
    private readonly TextBlock _status;
    private readonly Rectangle[] _bars;
    private readonly Button _sendBtn;
    private readonly Button _removeBtn;

    private MemoFile? _draft;
    private MemoPlayer? _player;

    public event Action? SendClicked;
    public event Action? RemoveClicked;

    public MemoDraftChip()
    {
        Margin = new Thickness(0, 0, 0, 6);
        HorizontalAlignment = HorizontalAlignment.Left;
        Visibility = Visibility.Collapsed;
        AutomationProperties.SetAutomationId(this, MemoDraftChipText.Id);

        _playIcon = new FontIcon { Glyph = "\uE768", FontSize = 12 };
        _spinner = new ProgressRing { Width = 14, Height = 14, IsActive = false, Visibility = Visibility.Collapsed };
        var playHost = new Grid();
        playHost.Children.Add(_playIcon);
        playHost.Children.Add(_spinner);

        _playBtn = new Button
        {
            Content = playHost,
            Width = 30,
            Height = 30,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(15),
            Style = ThemeBrushes.Res<Style>("AccentButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_playBtn, MemoDraftChipText.PlayId);
        _playBtn.Click += (_, _) => TogglePlay();

        _title = new TextBlock
        {
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetAutomationId(_title, MemoDraftChipText.TitleId);

        _status = new TextBlock
        {
            FontSize = 11,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            Visibility = Visibility.Collapsed,
        };

        var wave = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, Height = 18, VerticalAlignment = VerticalAlignment.Center };
        _bars = new Rectangle[MiniBars];
        for (var i = 0; i < MiniBars; i++)
        {
            var r = new Rectangle
            {
                Width = 2.5,
                Height = 4,
                RadiusX = 1.2,
                RadiusY = 1.2,
                VerticalAlignment = VerticalAlignment.Center,
                Fill = ThemeBrushes.Get("AccentFillColorDefaultBrush"),
            };
            _bars[i] = r;
            wave.Children.Add(r);
        }

        var textCol = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        textCol.Children.Add(_title);
        textCol.Children.Add(_status);

        _sendBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE724", FontSize = 12 },
            MinWidth = 28,
            MinHeight = 28,
            Padding = new Thickness(4),
            CornerRadius = new CornerRadius(14),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_sendBtn, "memo.chip.send");
        AutomationProperties.SetName(_sendBtn, "Send voice memo");
        ToolTipService.SetToolTip(_sendBtn, "Send voice memo");
        _sendBtn.Click += (_, _) => SendClicked?.Invoke();

        _removeBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE711", FontSize = 11 },
            MinWidth = 28,
            MinHeight = 28,
            Padding = new Thickness(4),
            CornerRadius = new CornerRadius(14),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_removeBtn, MemoDraftChipText.RemoveId);
        AutomationProperties.SetName(_removeBtn, MemoDraftChipText.RemoveLabel);
        ToolTipService.SetToolTip(_removeBtn, MemoDraftChipText.RemoveLabel);
        _removeBtn.Click += (_, _) => RemoveClicked?.Invoke();

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(_playBtn);
        row.Children.Add(textCol);
        row.Children.Add(wave);
        row.Children.Add(_sendBtn);
        row.Children.Add(_removeBtn);
        Content = new Border
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(10, 6, 6, 6),
            BorderThickness = new Thickness(1),
            Background = ThemeBrushes.Get("HQPromptCardBrush"),
            BorderBrush = ThemeBrushes.Get("HQPromptEdgeBrush"),
            Child = row,
        };
    }

    public void Update(MemoFile? draft, MemoPlayer? player)
    {
        _draft = draft;
        _player = player;
        if (draft == null)
        {
            Visibility = Visibility.Collapsed;
            return;
        }

        Visibility = Visibility.Visible;
        _title.Text = MemoDraftChipText.Title(draft);

        var playState = player?.StateOf(draft.Path) ?? MemoPlayState.Idle;
        var failed = player?.Failed.Contains(draft.Path) ?? false;
        var statusText = MemoDraftChipText.Status(playState, failed);
        _status.Text = statusText;
        _status.Visibility = statusText.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        _status.Foreground = ThemeBrushes.Get(failed ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush");

        var loading = playState == MemoPlayState.Loading;
        _spinner.IsActive = loading;
        _spinner.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
        _playIcon.Visibility = loading ? Visibility.Collapsed : Visibility.Visible;
        _playIcon.Glyph = failed ? "\uE72C" : playState == MemoPlayState.Playing ? "\uE769" : "\uE768";
        AutomationProperties.SetName(_playBtn, MemoDraftChipText.PlayLabel(playState, failed));

        var heights = MemoBubbleLayout.BarHeights(draft.Peaks, MiniBars, minHeight: 3, maxHeight: 16);
        var duration = player != null && player.IsCurrent(draft.Path) && player.Duration > 0 ? player.Duration : draft.Seconds;
        var current = player?.CurrentTime(draft.Path) ?? 0;
        var progress = duration > 0 ? Math.Clamp(current / duration, 0, 1) : 0;
        var activeBrush = ThemeBrushes.Get("AccentFillColorDefaultBrush");
        var idleBrush = ThemeBrushes.Get("ControlStrongFillColorDefaultBrush");
        for (var i = 0; i < MiniBars; i++)
        {
            _bars[i].Height = heights[i];
            _bars[i].Fill = (playState is MemoPlayState.Playing or MemoPlayState.Paused) && (i + 0.5) / MiniBars <= progress
                ? activeBrush : idleBrush;
        }
    }

    private void TogglePlay()
    {
        if (_draft is not { } draft || _player is not { } player) return;
        if (player.Failed.Contains(draft.Path)) player.ForgetFailure(draft.Path);
        player.Toggle(draft.Path, MemoResolve.LocalFile(draft.Path));
    }
}
