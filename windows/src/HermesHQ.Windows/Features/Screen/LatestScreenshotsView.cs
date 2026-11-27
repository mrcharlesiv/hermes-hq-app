using Hermes.Core.Screen;
using HermesHQ.Features.Capabilities;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace HermesHQ.Features.Screen;

/// [WIN-SCREEN-PAGE] The latest-screenshots page while the gateway has no live screen (App/Screen/LatestScreenshotsView.swift
/// at 93f984bb1, §5.14): the heading and its line (ScreenshotRules.Heading), the picture in a rounded frame at its own
/// aspect (16:10 until one loads) with the spinner and the empty line, the caption with the shot's age (re-read every
/// 5 s), and the setup card (none on a Hermes Cloud agent). The picture zooms (1–5×) in a ScrollViewer; double-click
/// toggles. Pictures come inline (a data URL) or through `LoadImage` (a gateway path).
/// [WIN-SCREEN-SETUP-LAYOUT] The page scrolls, as the Mac's; the frame's height is Hermes.Core's ScreenshotsLayout: with
/// no picture the Mac's 16:10 at most, and no taller than leaves the card's buttons in view in this window (`Fit`).
internal sealed class LatestScreenshotsView : Grid
{
    public ScreenSetupCard Card { get; } = new(controlOnly: false);
    /// A gateway path's bytes; null: not loadable here (the feed retries and then says so).
    public Func<string, string, Task<byte[]?>>? LoadImage { get; set; }
    public bool Managed { get; set; }

    private readonly ScreenshotFeed _feed;
    private readonly TextBlock _heading = new() { FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 4) };
    private readonly TextBlock _detail = new() { FontSize = 13, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 14) };
    private readonly TextBlock _caption = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 16) };
    private readonly TextBlock _status = new() { FontSize = 13, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
    private readonly ProgressRing _spinner = new() { Width = 20, Height = 20 };
    private readonly Border _frame = new() { CornerRadius = new CornerRadius(16) };
    private readonly ScrollViewer _zoom = new()
    {
        ZoomMode = ZoomMode.Enabled, MinZoomFactor = 1, MaxZoomFactor = 5,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
        HorizontalScrollMode = ScrollMode.Auto, VerticalScrollMode = ScrollMode.Auto,
    };
    private readonly Image _picture = new() { Stretch = Stretch.Uniform };
    private readonly DispatcherQueueTimer _ageTimer;
    private ScreenSession.Fallback _reason = ScreenSession.Fallback.Unsupported;
    private string? _blocker;
    private double _ratio = 10.0 / 16.0;
    private string? _loadedId;
    private int _loadedAttempt;
    private bool _hasPicture;
    private readonly ScrollViewer _page = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    private readonly StackPanel _stack = new()
    {
        Margin = new Thickness(ScreenshotsLayout.Side, ScreenshotsLayout.Top, ScreenshotsLayout.Side, ScreenshotsLayout.Bottom),
    };
    private readonly StackPanel _empty = new()
    {
        Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        Margin = new Thickness(16, ScreenshotsLayout.StatusInset, 16, ScreenshotsLayout.StatusInset),
    };

    public LatestScreenshotsView(ScreenshotFeed feed, Action<string> announce)
    {
        _feed = feed;
        Background = HermesHQ.Features.Settings.ThemeService.BrushFor("HQGroupedBrush");
        AutomationProperties.SetAutomationId(this, "screenshots.page");
        AutomationProperties.SetAutomationId(_heading, "screenshots.heading");
        AutomationProperties.SetHeadingLevel(_heading, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        AutomationProperties.SetAutomationId(_detail, "screenshots.detail");
        AutomationProperties.SetAutomationId(_caption, "screenshots.caption");
        AutomationProperties.SetAutomationId(_status, "screenshots.status");
        AutomationProperties.SetAutomationId(_zoom, "screenshots.picture");
        _detail.Foreground = _caption.Foreground = _status.Foreground = Kit.Secondary;
        _frame.Background = Kit.Brush("SubtleFillColorTertiaryBrush");
        _zoom.Content = _picture;
        _empty.Children.Add(_spinner);
        _empty.Children.Add(_status);
        var inside = new Grid();
        inside.Children.Add(_zoom);
        inside.Children.Add(_empty);
        _frame.Child = inside;
        _frame.Height = 0;
        _zoom.DoubleTapped += (_, e) =>
        {
            if (!_hasPicture) return;
            if (_zoom.ZoomFactor > 1.01) _zoom.ChangeView(0, 0, 1);
            else
            {
                var at = e.GetPosition(_zoom);
                _zoom.ChangeView(at.X * 1.5, at.Y * 1.5, 2.5f);
            }
        };
        foreach (var view in new UIElement[] { _heading, _detail, _frame, _caption, Card }) _stack.Children.Add(view);
        _page.Content = _stack;
        AutomationProperties.SetAutomationId(_page, "screenshots.scroll");
        Children.Add(_page);
        // Whatever moves the frame's width, the page's visible height, what sits above the frame or the run down to the
        // card's buttons fits the frame again (its own height changing it settles: `Fit` sets it only when it differs).
        foreach (var element in new FrameworkElement[] { _frame, _page, _heading, _detail, _caption, _empty, Card })
            element.SizeChanged += (_, _) => Fit();
        Card.Announce = announce;
        feed.OnChange = Render;
        feed.OnNewShot = () => announce("New screenshot");
        _ageTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _ageTimer.Interval = TimeSpan.FromSeconds(5);
        _ageTimer.IsRepeating = true;
        _ageTimer.Tick += (_, _) => RenderCaption();
        Render();
    }

    public ScreenshotFeed Feed => _feed;

    /// The page's scrolling viewport (the walk checks Set Up with Hermes lies inside it).
    public ScrollViewer Page => _page;

    /// [WIN-SCREEN-SETUP-LAYOUT] The frame's height from ScreenshotsLayout: a picture's own shape, or, with none, the
    /// Mac's 16:10 capped so the card's buttons stay in view (at least the status line and its insets).
    private void Fit()
    {
        var width = _frame.ActualWidth;
        if (width <= 0 || _stack.XamlRoot == null) return;
        double room = double.PositiveInfinity;
        if (!_hasPicture && _page.ViewportHeight > 0)
        {
            try
            {
                var frameTop = _frame.TransformToVisual(_stack).TransformPoint(new global::Windows.Foundation.Point(0, 0)).Y;
                var frameBottom = frameTop + _frame.ActualHeight;
                var run = 0.0;
                if (Card.Visibility == Visibility.Visible)
                    run = Card.TransformToVisual(_stack).TransformPoint(new global::Windows.Foundation.Point(0, 0)).Y - frameBottom + Card.ButtonsBottom;
                else if (_caption.Visibility == Visibility.Visible)
                    run = _caption.TransformToVisual(_stack).TransformPoint(new global::Windows.Foundation.Point(0, 0)).Y - frameBottom + _caption.ActualHeight;
                room = ScreenshotsLayout.Room(_page.ViewportHeight, frameTop + _stack.Margin.Top, run);
            }
            catch (ArgumentException) { return; }   // not in the tree yet
        }
        var height = ScreenshotsLayout.FrameHeight(width, _hasPicture ? _ratio : null, room, _empty.ActualHeight);
        if (Math.Abs(_frame.Height - height) > 1) _frame.Height = height;
    }

    public void Update(ScreenSession.Fallback reason, string? blocker)
    {
        _reason = reason;
        _blocker = blocker;
        Render();
    }

    public void SetVisible(bool on)
    {
        _feed.SetVisible(on);
        _ageTimer.Stop();
        Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        if (!on) return;
        Render();
        _ageTimer.Start();
    }

    public void Stop()
    {
        _ageTimer.Stop();
        _feed.Stop();
    }

    private void RenderCaption()
    {
        var text = _feed.Caption();
        _caption.Text = text;
        _caption.Visibility = text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetItemStatus(_zoom, text);
    }

    private void Render()
    {
        var host = _feed.HostKind;
        var words = ScreenshotRules.Heading(_reason, _feed.Name, host, _blocker is { } b ? ScreenWire.Plain(b) : null, Managed);
        _heading.Text = words.Title;
        _detail.Text = words.Detail;
        Card.WindowsGateway = host == ScreenHostKind.Windows;
        Card.NeedsUpdate = _reason == ScreenSession.Fallback.Unavailable;
        Card.Visibility = Managed ? Visibility.Collapsed : Visibility.Visible;
        RenderCaption();
        AutomationProperties.SetName(_zoom, $"{_feed.Name}’s latest screenshot");
        var state = _feed.State;
        var shows = _hasPicture && state != ScreenshotFeed.FeedState.Expired && state != ScreenshotFeed.FeedState.Unloadable;
        _zoom.Visibility = shows ? Visibility.Visible : Visibility.Collapsed;
        _status.Text = shows ? "" : _feed.EmptyLine;
        _status.Visibility = shows ? Visibility.Collapsed : Visibility.Visible;
        var waiting = !shows && state is ScreenshotFeed.FeedState.Searching or ScreenshotFeed.FeedState.Loading;
        _spinner.IsActive = waiting;
        _spinner.Visibility = waiting ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetAutomationId(_frame, "screenshots.frame." + state.ToString().ToLowerInvariant());
        if (state == ScreenshotFeed.FeedState.Expired) SetPicture(null, 0, 0);
        _ = LoadAsync();
    }

    private void SetPicture(ImageSource? image, int width, int height)
    {
        _picture.Source = image;
        _hasPicture = image != null;
        _zoom.ChangeView(0, 0, 1, disableAnimation: true);
        if (image == null || width <= 0) { Fit(); return; }
        _ratio = ScreenshotsLayout.Aspect(width, height);
        Fit();
    }

    private async Task LoadAsync()
    {
        if (_feed.Shot is not { } shot || (shot.Id == _loadedId && _feed.LoadAttempt == _loadedAttempt)) return;
        _loadedId = shot.Id;
        _loadedAttempt = _feed.LoadAttempt;
        byte[]? bytes = null;
        var gone = false;
        if (ToolScreenshots.IsInline(shot.Src))
        {
            var comma = shot.Src.IndexOf(',');
            try { bytes = comma < 0 ? null : Convert.FromBase64String(shot.Src[(comma + 1)..]); } catch (FormatException) { }
            gone = bytes == null;                      // an inline picture that cannot be read never will be
        }
        else if (LoadImage is { } load)
        {
            try { bytes = await load(shot.Src, _feed.Profile); }
            catch (Exception e) { gone = ScreenshotFeed.IsGone(e); }
        }
        if (_feed.Shot?.Id != shot.Id) return;
        var image = bytes == null ? null : await Decode(bytes);
        if (image != null)
        {
            SetPicture(image, image.PixelWidth, image.PixelHeight);
            _feed.Loaded(shot.Id, ok: true);
        }
        else if (gone || bytes != null) _feed.Loaded(shot.Id, ok: false);
        else _feed.LoadFailed(shot.Id);
        Render();
    }

    private static async Task<BitmapImage?> Decode(byte[] bytes)
    {
        try
        {
            var image = new BitmapImage();
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            await stream.WriteAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(bytes));
            stream.Seek(0);
            await image.SetSourceAsync(stream);
            return image;
        }
        catch (Exception) { return null; }
    }

    public double ZoomScale => _zoom.ZoomFactor;
}
