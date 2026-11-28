using Hermes.Core.Voice;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace HermesHQ.Features.Voice;

/// Port of App/Chat/Voice/DictationRow.swift: inline dictation strip above the composer with
/// Cancel (×), status label + spinner, elapsed clock (orange in final 10s), 5 animated audio
/// bars, Done button, and live words preview.
public sealed class DictationRowView : UserControl
{
    private const int BarCount = 5;

    private readonly LiveWordsView _liveWords;
    private readonly Button _cancelBtn;
    private readonly FontIcon _micIcon;
    private readonly ProgressRing _spinner;
    private readonly TextBlock _statusText;
    private readonly TextBlock _clockText;
    private readonly Rectangle[] _bars;
    private readonly Button _doneBtn;
    private readonly DispatcherQueueTimer _animTimer;

    private DictationState _state = DictationState.Idle;
    private double _phaseSeconds;

    public event Action? CancelClicked;
    public event Action? DoneClicked;

    public DictationRowView()
    {
        Margin = new Thickness(0, 0, 0, 6);
        Visibility = Visibility.Collapsed;
        AutomationProperties.SetAutomationId(this, "dictation.row");

        _liveWords = new LiveWordsView(maxLines: 2);

        _cancelBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE711", FontSize = 12 },
            MinWidth = 30,
            MinHeight = 30,
            Padding = new Thickness(4),
            CornerRadius = new CornerRadius(15),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_cancelBtn, "dictation.cancel");
        AutomationProperties.SetName(_cancelBtn, "Cancel dictation");
        ToolTipService.SetToolTip(_cancelBtn, "Cancel dictation");
        _cancelBtn.Click += (_, _) => CancelClicked?.Invoke();

        _micIcon = new FontIcon
        {
            Glyph = "\uE720",
            FontSize = 14,
            Foreground = ThemeBrushes.Get("AccentFillColorDefaultBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        _spinner = new ProgressRing
        {
            Width = 14,
            Height = 14,
            IsActive = false,
            Visibility = Visibility.Collapsed,
            VerticalAlignment = VerticalAlignment.Center,
        };

        _statusText = new TextBlock
        {
            Text = "Dictating",
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetAutomationId(_statusText, "dictation.status");

        _clockText = new TextBlock
        {
            Text = "0:00",
            FontSize = 12,
            FontFamily = ThemeBrushes.Res<FontFamily>("CodeFont"),
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetAutomationId(_clockText, "dictation.clock");

        var barsPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 3,
            Height = 20,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _bars = new Rectangle[BarCount];
        for (var i = 0; i < BarCount; i++)
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
            barsPanel.Children.Add(rect);
        }

        _doneBtn = new Button
        {
            Content = "Done",
            FontSize = 12,
            Padding = new Thickness(12, 4, 12, 4),
            CornerRadius = new CornerRadius(14),
            Style = ThemeBrushes.Res<Style>("AccentButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_doneBtn, "dictation.done");
        _doneBtn.Click += (_, _) => DoneClicked?.Invoke();

        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(_cancelBtn);
        left.Children.Add(_micIcon);
        left.Children.Add(_spinner);
        left.Children.Add(_statusText);
        left.Children.Add(_clockText);

        var row = new Grid { ColumnSpacing = 10, MinHeight = 32 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(left, 0);
        Grid.SetColumn(barsPanel, 1);
        Grid.SetColumn(_doneBtn, 2);
        row.Children.Add(left);
        row.Children.Add(barsPanel);
        row.Children.Add(_doneBtn);

        var root = new StackPanel { Spacing = 4 };
        root.Children.Add(_liveWords);
        root.Children.Add(row);
        Content = new Border
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(10, 8, 10, 8),
            BorderThickness = new Thickness(1),
            Background = ThemeBrushes.Get("HQPromptCardBrush"),
            BorderBrush = ThemeBrushes.Get("HQPromptEdgeBrush"),
            Child = root,
        };

        _animTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _animTimer.Interval = TimeSpan.FromMilliseconds(50);
        _animTimer.Tick += (_, _) =>
        {
            _phaseSeconds += 0.05;
            PaintBars();
        };
        Unloaded += (_, _) => _animTimer.Stop();
    }

    public void Update(DictationState state, bool activeHere)
    {
        _state = state;
        if (!activeHere || state.Phase == DictationPhase.Idle)
        {
            Visibility = Visibility.Collapsed;
            _animTimer.Stop();
            _liveWords.Reset();
            return;
        }
        if (state.Phase == DictationPhase.Starting && !state.StartingShown)
        {
            Visibility = Visibility.Collapsed;
            return;
        }

        Visibility = Visibility.Visible;
        var busy = state.Phase is DictationPhase.Starting or DictationPhase.Transcribing;
        _spinner.IsActive = busy;
        _spinner.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        _micIcon.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;

        _statusText.Text = state.Phase switch
        {
            DictationPhase.Starting => "Starting…",
            DictationPhase.Transcribing => "Transcribing…",
            _ => "Dictating",
        };

        _clockText.Text = state.Clock;
        _clockText.Visibility = state.Phase == DictationPhase.Recording ? Visibility.Visible : Visibility.Collapsed;
        _clockText.Foreground = ThemeBrushes.Get(state.IsWarningCountdown
            ? "SystemFillColorCautionBrush"
            : "TextFillColorSecondaryBrush");

        _doneBtn.IsEnabled = state.Phase == DictationPhase.Recording;
        _liveWords.Update(state.LiveWords, showWhenEmpty: false);

        if (state.Phase == DictationPhase.Recording)
        {
            if (!_animTimer.IsRunning) _animTimer.Start();
            PaintBars();
        }
        else
        {
            _animTimer.Stop();
            foreach (var b in _bars) b.Height = 4;
        }
    }

    private void PaintBars()
    {
        var heights = DictationBarsMath.Heights(_state.Level, _phaseSeconds, minHeight: 4, maxHeight: 20);
        for (var i = 0; i < _bars.Length; i++) _bars[i].Height = heights[i];
    }
}
