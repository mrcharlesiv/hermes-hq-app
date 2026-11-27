using Hermes.Core.Voice;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace HermesHQ.Features.Voice;

/// Port of App/Chat/Voice/MemoRecorderViews.swift: active voice memo recorder bar in both
/// Holding (red dot, live clock, slide-to-cancel / lock hint) and Locked / Review modes
/// (Delete, Play/Pause, live scrolling or scrubbable waveform, Stop, Send, plus live words).
public sealed class MemoRecorderBar : UserControl
{
    private const int LiveBarCount = 36;
    private const int ReviewBarCount = 48;

    private readonly LiveWordsView _liveWords;
    private readonly Grid _holdingRow;
    private readonly Ellipse _redDot;
    private readonly TextBlock _holdClock;
    private readonly TextBlock _slideHint;
    private readonly TextBlock _lockHint;

    private readonly Grid _lockedRow;
    private readonly Button _deleteBtn;
    private readonly Button _playReviewBtn;
    private readonly FontIcon _playReviewIcon;
    private readonly Grid _waveHost;
    private readonly StackPanel _waveBars;
    private readonly Rectangle[] _bars;
    private readonly TextBlock _lockedClock;
    private readonly Button _stopBtn;
    private readonly Button _sendBtn;

    private readonly MemoController _controller;
    private readonly MemoPlayer? _player;
    private bool _scrubbing;
    private int _pulsePhase;

    public MemoRecorderBar(MemoController controller, MemoPlayer? player)
    {
        _controller = controller;
        _player = player;

        Margin = new Thickness(0, 0, 0, 6);
        Visibility = Visibility.Collapsed;
        AutomationProperties.SetAutomationId(this, "memo.recorder");

        _liveWords = new LiveWordsView(maxLines: 2);
        _liveWords.WordsEdited += text => _controller.ReviseWords(text);

        // --- Holding row ---
        _redDot = new Ellipse
        {
            Width = 9,
            Height = 9,
            Fill = ThemeBrushes.Get("SystemFillColorCriticalBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        _holdClock = new TextBlock
        {
            Text = "0:00",
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            FontFamily = ThemeBrushes.Res<FontFamily>("CodeFont"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetAutomationId(_holdClock, "memo.recorder.clock");

        _slideHint = new TextBlock
        {
            Text = "‹ Slide left to cancel",
            FontSize = 13,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };

        _lockHint = new TextBlock
        {
            Text = "↑ Slide up to lock",
            FontSize = 12,
            Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };

        var leftHold = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        leftHold.Children.Add(_redDot);
        leftHold.Children.Add(_holdClock);

        _holdingRow = new Grid { ColumnSpacing = 12, MinHeight = 36, Visibility = Visibility.Collapsed };
        _holdingRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _holdingRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _holdingRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(leftHold, 0);
        Grid.SetColumn(_slideHint, 1);
        Grid.SetColumn(_lockHint, 2);
        _holdingRow.Children.Add(leftHold);
        _holdingRow.Children.Add(_slideHint);
        _holdingRow.Children.Add(_lockHint);

        // --- Locked / Review row ---
        _deleteBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE74D", FontSize = 14 },
            MinWidth = 34,
            MinHeight = 34,
            Padding = new Thickness(6),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_deleteBtn, "memo.recorder.delete");
        AutomationProperties.SetName(_deleteBtn, "Delete recording");
        ToolTipService.SetToolTip(_deleteBtn, "Delete recording");
        _deleteBtn.Click += (_, _) => _controller.Input(new MemoInput.Delete());

        _playReviewIcon = new FontIcon { Glyph = "\uE768", FontSize = 13 };
        _playReviewBtn = new Button
        {
            Content = _playReviewIcon,
            MinWidth = 32,
            MinHeight = 32,
            Padding = new Thickness(6),
            CornerRadius = new CornerRadius(16),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_playReviewBtn, "memo.recorder.play");
        AutomationProperties.SetName(_playReviewBtn, "Play voice memo");
        _playReviewBtn.Click += (_, _) => ToggleReviewPlayback();

        _bars = new Rectangle[ReviewBarCount];
        _waveBars = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 2,
            Height = 28,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        for (var i = 0; i < ReviewBarCount; i++)
        {
            var rect = new Rectangle
            {
                Width = 3,
                Height = 4,
                RadiusX = 1.5,
                RadiusY = 1.5,
                VerticalAlignment = VerticalAlignment.Center,
                Fill = ThemeBrushes.Get("AccentFillColorDefaultBrush"),
            };
            _bars[i] = rect;
            _waveBars.Children.Add(rect);
        }

        _waveHost = new Grid
        {
            MinHeight = 32,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            VerticalAlignment = VerticalAlignment.Center,
        };
        _waveHost.Children.Add(_waveBars);
        _waveHost.PointerPressed += OnWavePointerPressed;
        _waveHost.PointerMoved += OnWavePointerMoved;
        _waveHost.PointerReleased += OnWavePointerReleased;

        _lockedClock = new TextBlock
        {
            Text = "0:00",
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            FontFamily = ThemeBrushes.Res<FontFamily>("CodeFont"),
            VerticalAlignment = VerticalAlignment.Center,
            MinWidth = 38,
            TextAlignment = TextAlignment.Right,
        };

        _stopBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE71A", FontSize = 13 },
            MinWidth = 34,
            MinHeight = 34,
            Padding = new Thickness(6),
            CornerRadius = new CornerRadius(17),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_stopBtn, "memo.recorder.stop");
        AutomationProperties.SetName(_stopBtn, "Stop recording to review");
        ToolTipService.SetToolTip(_stopBtn, "Stop to review before sending");
        _stopBtn.Click += (_, _) => _controller.Input(new MemoInput.Stop());

        _sendBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE724", FontSize = 14 },
            MinWidth = 34,
            MinHeight = 34,
            Padding = new Thickness(6),
            CornerRadius = new CornerRadius(17),
            Style = ThemeBrushes.Res<Style>("AccentButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_sendBtn, "memo.recorder.send");
        AutomationProperties.SetName(_sendBtn, "Send voice memo");
        ToolTipService.SetToolTip(_sendBtn, "Send voice memo");
        _sendBtn.Click += (_, _) => _controller.Input(new MemoInput.Send());

        var leftControls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        leftControls.Children.Add(_deleteBtn);
        leftControls.Children.Add(_playReviewBtn);

        var rightControls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        rightControls.Children.Add(_lockedClock);
        rightControls.Children.Add(_stopBtn);
        rightControls.Children.Add(_sendBtn);

        _lockedRow = new Grid { ColumnSpacing = 10, MinHeight = 36, Visibility = Visibility.Collapsed };
        _lockedRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _lockedRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _lockedRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(leftControls, 0);
        Grid.SetColumn(_waveHost, 1);
        Grid.SetColumn(rightControls, 2);
        _lockedRow.Children.Add(leftControls);
        _lockedRow.Children.Add(_waveHost);
        _lockedRow.Children.Add(rightControls);

        var root = new StackPanel { Spacing = 4 };
        root.Children.Add(_liveWords);
        root.Children.Add(_holdingRow);
        root.Children.Add(_lockedRow);
        Content = new Border
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(12, 8, 12, 8),
            BorderThickness = new Thickness(1),
            Background = ThemeBrushes.Get("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = ThemeBrushes.Get("CardStrokeColorDefaultBrush"),
            Child = root,
        };
    }

    public void FocusPrimary() => _sendBtn.Focus(FocusState.Programmatic);

    public void Refresh(IMemoChatHost host)
    {
        if (!_controller.IsActive(host))
        {
            Visibility = Visibility.Collapsed;
            _liveWords.Reset();
            return;
        }

        var state = _controller.State;
        var shown = _controller.ShownPhase;
        if (shown == MemoPhase.Pressing || shown == MemoPhase.Idle)
        {
            Visibility = Visibility.Collapsed;
            return;
        }

        Visibility = Visibility.Visible;
        var ending = state.Phase == MemoPhase.Ending;
        var secondsLeft = Math.Max(0, _controller.Limit - state.Seconds);
        var warn = state.IsRecording && secondsLeft <= 10;
        var clockBrush = ThemeBrushes.Get(warn ? "SystemFillColorCautionBrush" : "TextFillColorPrimaryBrush");

        if (shown == MemoPhase.Holding)
        {
            _holdingRow.Visibility = Visibility.Visible;
            _lockedRow.Visibility = Visibility.Collapsed;
            _liveWords.UpdatePlain(_controller.Words, editable: false);

            _pulsePhase = (_pulsePhase + 1) % 16;
            _redDot.Opacity = 0.55 + 0.45 * Math.Sin(_pulsePhase * Math.PI / 8.0);
            _holdClock.Text = MemoPolicy.Length(state.Seconds);
            _holdClock.Foreground = clockBrush;

            _slideHint.Text = state.CancelArmed ? "Release to Cancel" : "‹ Slide left to cancel";
            _slideHint.Foreground = ThemeBrushes.Get(state.CancelArmed
                ? "SystemFillColorCriticalBrush"
                : "TextFillColorSecondaryBrush");
            _lockHint.Text = state.LockNear ? "Release to Lock" : "↑ Slide up to lock";
            _lockHint.Foreground = ThemeBrushes.Get(state.LockNear
                ? "AccentFillColorDefaultBrush"
                : "TextFillColorTertiaryBrush");
            return;
        }

        _holdingRow.Visibility = Visibility.Collapsed;
        _lockedRow.Visibility = Visibility.Visible;

        var isReview = shown == MemoPhase.Review;
        _deleteBtn.IsEnabled = !ending;
        _stopBtn.IsEnabled = !ending;
        _sendBtn.IsEnabled = !ending;
        _stopBtn.Visibility = isReview ? Visibility.Collapsed : Visibility.Visible;
        _playReviewBtn.Visibility = isReview ? Visibility.Visible : Visibility.Collapsed;

        _liveWords.UpdatePlain(_controller.Words, editable: isReview);

        if (isReview && _controller.File is { } file)
        {
            var playState = _player?.StateOf(file.Path) ?? MemoPlayState.Idle;
            var current = _player?.CurrentTime(file.Path) ?? 0;
            var total = file.Seconds > 0 ? file.Seconds : (_player?.Duration ?? 0);
            var progress = total > 0 ? Math.Clamp(current / total, 0, 1) : 0;

            _playReviewIcon.Glyph = playState == MemoPlayState.Playing ? "\uE769" : "\uE768";
            AutomationProperties.SetName(_playReviewBtn, playState == MemoPlayState.Playing ? "Pause voice memo" : "Play voice memo");
            _lockedClock.Text = playState is MemoPlayState.Playing or MemoPlayState.Paused && total > 0
                ? MemoPolicy.Length(Math.Max(0, total - current))
                : MemoPolicy.Total(total);
            _lockedClock.Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush");

            var heights = MemoBubbleLayout.BarHeights(file.Peaks, ReviewBarCount, minHeight: 3, maxHeight: 24);
            var playedBrush = ThemeBrushes.Get("AccentFillColorDefaultBrush");
            var restBrush = ThemeBrushes.Get("ControlStrongFillColorDefaultBrush");
            for (var i = 0; i < ReviewBarCount; i++)
            {
                _bars[i].Visibility = Visibility.Visible;
                _bars[i].Height = heights[i];
                _bars[i].Fill = (i + 0.5) / ReviewBarCount <= progress ? playedBrush : restBrush;
            }
        }
        else
        {
            _lockedClock.Text = MemoPolicy.Length(state.Seconds);
            _lockedClock.Foreground = clockBrush;

            var heights = MemoLiveWaveMath.Shape(_controller.Levels, LiveBarCount, minHeight: 3, maxHeight: 24);
            var liveBrush = ThemeBrushes.Get("SystemFillColorCriticalBrush");
            for (var i = 0; i < ReviewBarCount; i++)
            {
                if (i < LiveBarCount)
                {
                    _bars[i].Visibility = Visibility.Visible;
                    _bars[i].Height = heights[i];
                    _bars[i].Fill = liveBrush;
                }
                else
                {
                    _bars[i].Visibility = Visibility.Collapsed;
                }
            }
        }
    }

    private void ToggleReviewPlayback()
    {
        if (_player == null || _controller.File is not { } file) return;
        _player.Toggle(file.Path, MemoResolve.LocalFile(file.Path));
    }

    private void OnWavePointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_controller.ShownPhase != MemoPhase.Review || _controller.File is not { } file || _player == null) return;
        _scrubbing = true;
        _waveHost.CapturePointer(e.Pointer);
        SeekFromPointer(e, file);
        e.Handled = true;
    }

    private void OnWavePointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_scrubbing || _controller.File is not { } file || _player == null) return;
        SeekFromPointer(e, file);
        e.Handled = true;
    }

    private void OnWavePointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_scrubbing) return;
        _scrubbing = false;
        _waveHost.ReleasePointerCapture(e.Pointer);
        e.Handled = true;
    }

    private void SeekFromPointer(PointerRoutedEventArgs e, MemoFile file)
    {
        var pos = e.GetCurrentPoint(_waveHost).Position;
        var frac = MemoBubbleLayout.ClampFraction(pos.X, _waveHost.ActualWidth);
        _player?.Seek(file.Path, frac, MemoResolve.LocalFile(file.Path));
    }
}
