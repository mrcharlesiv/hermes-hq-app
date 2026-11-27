using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Voice;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;
using DispatcherQueue = Microsoft.UI.Dispatching.DispatcherQueue;
using DispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;

namespace HermesHQ.Features.Voice;

/// Port of App/Chat/Voice/MemoBubbleContent.swift: transcript voice memo bubble with
/// Play/Pause disc + loading spinner, scrubbable 48-bar waveform (mouse/touch/keyboard ±5s),
/// 1×/1.5×/2× speed pill, duration/remaining clock, load-error retry row, and collapsible transcript.
public sealed class MemoBubbleView : UserControl
{
    private const int Bars = MemoBubbleLayout.BarCount;

    private readonly VoiceMemo _memo;
    private readonly bool _pending;
    private readonly bool _sendFailed;
    private readonly string? _profile;
    private readonly IMemoGateway? _gateway;
    private readonly MemoAccountStores? _stores;
    private readonly MemoPlayer? _player;
    private readonly DispatcherQueue _queue;
    private readonly DispatcherQueueTimer _progressTimer;

    private readonly Button _playBtn;
    private readonly FontIcon _playIcon;
    private readonly ProgressRing _spinner;
    private readonly ContentControl _waveHost;
    private readonly Rectangle[] _bars;
    private readonly TextBlock _clock;
    private readonly Button _speedBtn;
    private readonly StackPanel _errorRow;
    private readonly TextBlock _transcript;
    private readonly Button _toggleTranscriptBtn;
    private readonly TextBlock _restText;

    private bool _expanded;
    private bool _scrubbing;
    private bool _waveformRequested;

    /// Returns a MemoBubbleView if `message` is a user voice memo (`MEDIA:"..."`), else null.
    /// Hook point for `MessageView.UserBubble`.
    public static FrameworkElement? TryCreate(ChatMessage message, ChatSession? session = null)
    {
        if (message.Role != Role.User) return null;
        var parsed = VoiceMemo.Parse(message.Text);
        if (parsed == null) return null;
        var stores = session?.MemoStores ?? VoiceMemosFeature.Stores;
        var player = VoiceMemosFeature.Player;
        return new MemoBubbleView(parsed, message.IsPending, message.Error != null,
            session?.Profile, session?.MemoGateway, stores, player);
    }

    public MemoBubbleView(
        VoiceMemo memo,
        bool pending,
        bool sendFailed,
        string? profile,
        IMemoGateway? gateway,
        MemoAccountStores? stores,
        MemoPlayer? player)
    {
        _memo = memo;
        _pending = pending;
        _sendFailed = sendFailed;
        _profile = profile;
        _gateway = gateway;
        _stores = stores;
        _player = player;
        _queue = DispatcherQueue.GetForCurrentThread();

        MinWidth = 260;
        MaxWidth = 380;
        AutomationProperties.SetAutomationId(this, "memo.bubble");

        // Play/Pause circle
        _playIcon = new FontIcon { Glyph = "\uE768", FontSize = 14, Foreground = ThemeBrushes.Get("HQMeTextBrush") };
        _spinner = new ProgressRing { Width = 16, Height = 16, IsActive = false, Visibility = Visibility.Collapsed };
        var playInner = new Grid();
        playInner.Children.Add(_playIcon);
        playInner.Children.Add(_spinner);

        _playBtn = new Button
        {
            Content = playInner,
            Width = 36,
            Height = 36,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(18),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_playBtn, "memo.bubble.play");
        _playBtn.Click += (_, _) => TogglePlay();

        // Scrubbable 48-bar waveform
        var wavePanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 2,
            Height = 26,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _bars = new Rectangle[Bars];
        for (var i = 0; i < Bars; i++)
        {
            var r = new Rectangle
            {
                Width = 2.5,
                Height = 5,
                RadiusX = 1.2,
                RadiusY = 1.2,
                VerticalAlignment = VerticalAlignment.Center,
            };
            _bars[i] = r;
            wavePanel.Children.Add(r);
        }

        var waveHitSurface = new Grid
        {
            MinHeight = 30,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            VerticalAlignment = VerticalAlignment.Center,
        };
        waveHitSurface.Children.Add(wavePanel);

        _waveHost = new ContentControl
        {
            MinHeight = 30,
            IsTabStop = true,
            UseSystemFocusVisuals = true,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Center,
            Content = waveHitSurface,
        };
        AutomationProperties.SetAutomationId(_waveHost, "memo.bubble.waveform");
        AutomationProperties.SetName(_waveHost, "Voice memo waveform. Use Left and Right arrows to seek.");
        _waveHost.PointerPressed += OnWavePressed;
        _waveHost.PointerMoved += OnWaveMoved;
        _waveHost.PointerReleased += OnWaveReleased;
        _waveHost.KeyDown += OnWaveKeyDown;

        // Clock & Speed pill
        _clock = new TextBlock
        {
            Text = "0:00",
            FontSize = 11,
            FontFamily = ThemeBrushes.Res<FontFamily>("CodeFont"),
            Foreground = ThemeBrushes.Get("HQMeTextBrush"),
            Opacity = 0.85,
            VerticalAlignment = VerticalAlignment.Center,
        };

        _speedBtn = new Button
        {
            Content = "1×",
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Padding = new Thickness(7, 2, 7, 2),
            MinHeight = 22,
            MinWidth = 34,
            CornerRadius = new CornerRadius(10),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
        };
        AutomationProperties.SetAutomationId(_speedBtn, "memo.bubble.speed");
        AutomationProperties.SetName(_speedBtn, "Playback speed");
        _speedBtn.Click += (_, _) => _player?.CycleSpeed();

        var metaRow = new Grid();
        metaRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        metaRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_clock, 0);
        Grid.SetColumn(_speedBtn, 1);
        metaRow.Children.Add(_clock);
        metaRow.Children.Add(_speedBtn);

        var rightCol = new StackPanel { Spacing = 3 };
        rightCol.Children.Add(_waveHost);
        rightCol.Children.Add(metaRow);

        var topRow = new Grid { ColumnSpacing = 10 };
        topRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        topRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(_playBtn, 0);
        Grid.SetColumn(rightCol, 1);
        topRow.Children.Add(_playBtn);
        topRow.Children.Add(rightCol);

        // Error retry row
        var errLabel = new TextBlock
        {
            Text = "Couldn’t load audio",
            FontSize = 12,
            Foreground = ThemeBrushes.Get("SystemFillColorCriticalBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var retryBtn = new Button
        {
            Content = "Try Again",
            FontSize = 12,
            Padding = new Thickness(6, 2, 6, 2),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
        };
        AutomationProperties.SetAutomationId(retryBtn, "memo.bubble.retry");
        retryBtn.Click += (_, _) => RetryLoad();
        _errorRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Margin = new Thickness(0, 6, 0, 0),
            Visibility = Visibility.Collapsed,
        };
        _errorRow.Children.Add(errLabel);
        _errorRow.Children.Add(retryBtn);

        // Collapsible transcript
        _transcript = new TextBlock
        {
            FontSize = 13,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            MaxLines = 3,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = ThemeBrushes.Get("HQMeTextBrush"),
            Opacity = 0.92,
            Margin = new Thickness(0, 8, 0, 0),
        };
        AutomationProperties.SetAutomationId(_transcript, "memo.bubble.transcript");

        _toggleTranscriptBtn = new Button
        {
            Content = "More",
            FontSize = 11,
            Padding = new Thickness(4, 1, 4, 1),
            Margin = new Thickness(0, 2, 0, 0),
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_toggleTranscriptBtn, "memo.bubble.toggleTranscript");
        _toggleTranscriptBtn.Click += (_, _) =>
        {
            _expanded = !_expanded;
            ApplyTranscriptCollapse();
        };

        _restText = new TextBlock
        {
            Text = memo.Rest,
            FontSize = 14,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            Foreground = ThemeBrushes.Get("HQMeTextBrush"),
            Margin = new Thickness(0, 8, 0, 0),
            Visibility = string.IsNullOrWhiteSpace(memo.Rest) ? Visibility.Collapsed : Visibility.Visible,
        };

        var stack = new StackPanel();
        stack.Children.Add(topRow);
        stack.Children.Add(_errorRow);
        stack.Children.Add(_transcript);
        stack.Children.Add(_toggleTranscriptBtn);
        stack.Children.Add(_restText);
        Content = new Border
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(12, 10, 12, 10),
            Background = ThemeBrushes.Get("HQMeBubbleBrush"),
            BorderBrush = ThemeBrushes.Get("HQMeBorderBrush"),
            BorderThickness = new Thickness(1),
            Child = stack,
        };

        _progressTimer = _queue.CreateTimer();
        _progressTimer.Interval = TimeSpan.FromMilliseconds(100);
        _progressTimer.Tick += (_, _) => { if (!_isLoaded || HermesHQ.Services.AppShutdown.Stopping) { _progressTimer.Stop(); return; } Refresh(); };

        Loaded += OnLoaded;
        Unloaded += OnUnloaded;

        Refresh();
    }

    private bool _isLoaded;

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _isLoaded = true;
        if (_player != null) { _player.Changed -= OnPlayerChanged; _player.Changed += OnPlayerChanged; }
        if (_stores?.Shapes != null) { _stores.Shapes.Changed -= OnShapeChanged; _stores.Shapes.Changed += OnShapeChanged; }
        Refresh();
        EnsureWaveformLoaded();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _isLoaded = false;
        _progressTimer.Stop();
        _spinner.IsActive = false;
        if (_player != null) _player.Changed -= OnPlayerChanged;
        if (_stores?.Shapes != null) _stores.Shapes.Changed -= OnShapeChanged;
        if (_waveformRequested)
        {
            _waveformRequested = false;
            MemoWaveformQueue.Shared.Leave(_memo.Path);
        }
    }

    private void OnPlayerChanged(string? path)
    {
        if (_isLoaded && !HermesHQ.Services.AppShutdown.Stopping && (path == null || path == _memo.Path))
            _queue.TryEnqueue(() => { if (_isLoaded && !HermesHQ.Services.AppShutdown.Stopping) Refresh(); });
    }

    private void OnShapeChanged(string path)
    {
        if (_isLoaded && !HermesHQ.Services.AppShutdown.Stopping && path == _memo.Path)
            _queue.TryEnqueue(() => { if (_isLoaded && !HermesHQ.Services.AppShutdown.Stopping) Refresh(); });
    }

    private void Refresh()
    {
        var snap = MemoBubbleLayout.Snapshot(_memo, _player, _stores?.Shapes, _pending, _sendFailed);

        var loading = snap.PlayState == MemoPlayState.Loading;
        _spinner.IsActive = loading && _isLoaded;
        _spinner.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
        _playIcon.Visibility = loading ? Visibility.Collapsed : Visibility.Visible;
        _playIcon.Glyph = snap.PlayState == MemoPlayState.Playing ? "\uE769" : "\uE768";
        AutomationProperties.SetName(_playBtn, snap.PlayState == MemoPlayState.Playing ? "Pause voice memo" : "Play voice memo");

        if (_isLoaded && snap.PlayState == MemoPlayState.Playing)
        {
            if (!_progressTimer.IsRunning) _progressTimer.Start();
        }
        else
        {
            _progressTimer.Stop();
        }

        _clock.Text = snap.ClockText;
        _speedBtn.Content = snap.SpeedLabel;
        _errorRow.Visibility = snap.LoadFailed ? Visibility.Visible : Visibility.Collapsed;

        var heights = MemoBubbleLayout.BarHeights(snap.Peaks, Bars, minHeight: 3, maxHeight: 22);
        var activeBrush = ThemeBrushes.Get("HQMeTextBrush");
        for (var i = 0; i < Bars; i++)
        {
            _bars[i].Height = heights[i];
            _bars[i].Fill = activeBrush;
            var played = snap.PlayState is MemoPlayState.Playing or MemoPlayState.Paused
                && (i + 0.5) / Bars <= snap.Progress;
            _bars[i].Opacity = played ? 1.0 : 0.4;
        }

        _transcript.Text = snap.WordsText;
        ApplyTranscriptCollapse();
    }

    private void ApplyTranscriptCollapse()
    {
        var longText = _transcript.Text.Length > 130 || _transcript.Text.Contains('\n');
        _transcript.MaxLines = _expanded ? 0 : 3;
        _toggleTranscriptBtn.Visibility = longText ? Visibility.Visible : Visibility.Collapsed;
        _toggleTranscriptBtn.Content = _expanded ? "Less" : "More";
    }

    private Func<Task<string>> MakeResolver()
    {
        if (_stores != null && _player != null)
            return MemoResolve.Through(_stores, _memo.Path, _profile, _gateway, _player);
        return MemoResolve.LocalFile(_memo.Path);
    }

    private void TogglePlay() => _player?.Toggle(_memo.Path, MakeResolver());

    private void RetryLoad()
    {
        if (_player == null) return;
        _player.ForgetFailure(_memo.Path);
        _stores?.Shapes?.UnmarkFailed(_memo.Path);
        _player.Play(_memo.Path, MakeResolver());
    }

    private void EnsureWaveformLoaded()
    {
        if (_waveformRequested || _stores?.Shapes is not { } shapes) return;
        if (shapes.Shape(_memo.Path) != null || shapes.Failed.Contains(_memo.Path)) return;
        _waveformRequested = true;
        var resolve = MakeResolver();
        var path = _memo.Path;
        _ = Task.Run(async () =>
        {
            try
            {
                var peaks = await MemoWaveformQueue.Shared.Load(path, async ct =>
                {
                    var local = await resolve();
                    ct.ThrowIfCancellationRequested();
                    return MemoWaveform.Compute(local, WavMemoAudio.Decoder, ct);
                });
                _queue.TryEnqueue(() => shapes.Remember(path, peaks.Peaks, peaks.Seconds));
            }
            catch (OperationCanceledException) { }
            catch (Exception)
            {
                _queue.TryEnqueue(() => shapes.MarkFailed(path));
            }
        });
    }

    private void OnWavePressed(object sender, PointerRoutedEventArgs e)
    {
        _scrubbing = true;
        _waveHost.CapturePointer(e.Pointer);
        SeekAt(e);
        e.Handled = true;
    }

    private void OnWaveMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_scrubbing) return;
        SeekAt(e);
        e.Handled = true;
    }

    private void OnWaveReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_scrubbing) return;
        _scrubbing = false;
        _waveHost.ReleasePointerCapture(e.Pointer);
        e.Handled = true;
    }

    private void SeekAt(PointerRoutedEventArgs e)
    {
        if (_player == null) return;
        var x = e.GetCurrentPoint(_waveHost).Position.X;
        var frac = MemoBubbleLayout.ClampFraction(x, _waveHost.ActualWidth);
        _player.Seek(_memo.Path, frac, MakeResolver());
    }

    private void OnWaveKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_player == null) return;
        var duration = _player.IsCurrent(_memo.Path) && _player.Duration > 0
            ? _player.Duration
            : _stores?.Shapes?.Shape(_memo.Path)?.Seconds ?? 0;
        if (duration <= 0) return;
        var cur = _player.CurrentTime(_memo.Path);
        if (e.Key == VirtualKey.Left)
        {
            _player.Seek(_memo.Path, Math.Clamp((cur - MemoBubbleLayout.SeekStepSeconds) / duration, 0, 1), MakeResolver());
            e.Handled = true;
        }
        else if (e.Key == VirtualKey.Right)
        {
            _player.Seek(_memo.Path, Math.Clamp((cur + MemoBubbleLayout.SeekStepSeconds) / duration, 0, 1), MakeResolver());
            e.Handled = true;
        }
        else if (e.Key is VirtualKey.Space or VirtualKey.Enter)
        {
            TogglePlay();
            e.Handled = true;
        }
    }
}
