// Watch Browser's live stage view (C# twin of App/Browser/BrowserStageView.swift, matching Features/Screen/ScreenStageView.cs):
// draws the decoded JPEG page frame into a WriteableBitmap at BrowserStageState.Drawn, overlays the drawn cursor arrow,
// grab ring, click flash pulse, and inactive-app privacy cover, and forwards mouse/pen/touch/wheel events into
// BrowserStageState.

using Hermes.Core.Browser;
using HermesHQ.Features.Capabilities;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.System;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace HermesHQ.Features.Browser;

internal sealed class BrowserStageView : Grid
{
    private readonly BrowserStageState _stage;
    private readonly Canvas _surface = new();
    private readonly Image _picture = new() { Stretch = Stretch.Fill };
    private readonly Canvas _overlay = new() { IsHitTestVisible = false };
    private readonly Ellipse _dragRing;
    private readonly Ellipse _clickRing;
    private readonly CompositeTransform _clickTransform = new() { CenterX = 14, CenterY = 14 };
    private readonly Polygon _cursor;
    private readonly Border _cover = new()
    {
        Background = new SolidColorBrush(Colors.Black),
        Visibility = Visibility.Collapsed,
        IsHitTestVisible = false,
    };

    private WriteableBitmap? _bitmap;
    private Storyboard? _clickFlash;

    public BrowserStageView(BrowserStageState stage, string botName)
    {
        _stage = stage;
        Background = new SolidColorBrush(Colors.Black);
        AutomationProperties.SetAutomationId(this, "browser.stage");
        AutomationProperties.SetName(this, botName.Length == 0 ? "The bot’s browser" : $"{botName}’s browser");

        var accentColor = ResolveAccentColor();
        _dragRing = new Ellipse
        {
            Width = 28,
            Height = 28,
            Fill = new SolidColorBrush(Color.FromArgb(0x33, accentColor.R, accentColor.G, accentColor.B)),
            Stroke = new SolidColorBrush(accentColor),
            StrokeThickness = 2,
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
        };
        _clickRing = new Ellipse
        {
            Width = 28,
            Height = 28,
            Fill = new SolidColorBrush(Colors.Transparent),
            Stroke = new SolidColorBrush(accentColor),
            StrokeThickness = 2,
            Opacity = 0,
            RenderTransform = _clickTransform,
            IsHitTestVisible = false,
        };

        // Same 7-point arrow path as App/Browser/BrowserStageView.swift, tip anchored at (2, 2).
        _cursor = new Polygon
        {
            Fill = new SolidColorBrush(Colors.White),
            Stroke = new SolidColorBrush(Colors.Black),
            StrokeThickness = 1.4,
            StrokeLineJoin = PenLineJoin.Round,
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
            Points = new PointCollection
            {
                new Point(2, 2),
                new Point(2, 20),
                new Point(6.8, 15.6),
                new Point(10.1, 22),
                new Point(12.8, 20.7),
                new Point(9.5, 14.5),
                new Point(15.5, 14.2),
            },
        };

        _surface.Children.Add(_picture);
        _overlay.Children.Add(_dragRing);
        _overlay.Children.Add(_clickRing);
        _overlay.Children.Add(_cursor);

        Children.Add(_surface);
        Children.Add(_overlay);
        Children.Add(_cover);

        IsHoldingEnabled = false;
        IsRightTapEnabled = false;
        IsDoubleTapEnabled = false;
        ManipulationMode = ManipulationModes.None;

        SizeChanged += (_, e) =>
        {
            Clip = new RectangleGeometry { Rect = new Rect(0, 0, e.NewSize.Width, e.NewSize.Height) };
            _stage.SetBounds(new BrowserSize(e.NewSize.Width, e.NewSize.Height));
            Place();
            OnLayoutChanged?.Invoke();
        };

        _stage.OnVisualChanged = Place;
        _stage.OnClickFlash = FlashClick;

        PointerPressed += OnPointerPressed;
        PointerMoved += OnPointerMoved;
        PointerReleased += OnPointerReleased;
        PointerCanceled += OnPointerLost;
        PointerCaptureLost += OnPointerLost;
        PointerWheelChanged += OnPointerWheelChanged;
        Unloaded += (_, _) => _clickFlash?.Stop();
    }

    public Action? OnLayoutChanged { get; set; }
    public bool HasPicture => _bitmap != null && _picture.Source != null;
    public (double Width, double Height, double Scale) Metrics =>
        (ActualWidth, ActualHeight, XamlRoot?.RasterizationScale ?? 1.0);

    public void Show(BrowserDecodedImage image, BrowserSize pageSize)
    {
        var width = image.Width;
        var height = image.Height;
        if (width <= 0 || height <= 0 || image.Bgra.Length < width * height * 4) return;

        var resized = _bitmap == null || _bitmap.PixelWidth != width || _bitmap.PixelHeight != height;
        if (resized)
        {
            _bitmap = new WriteableBitmap(width, height);
            _picture.Source = _bitmap;
        }
        using (var stream = System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsStream(_bitmap!.PixelBuffer))
        {
            stream.Write(image.Bgra, 0, width * height * 4);
        }
        _bitmap.Invalidate();
        _stage.ShowFrame(pageSize);
        Place();
    }

    public void Clear()
    {
        _bitmap = null;
        _picture.Source = null;
        _stage.Clear();
        Place();
    }

    public void Place()
    {
        var drawn = _stage.Drawn;
        Canvas.SetLeft(_picture, drawn.X);
        Canvas.SetTop(_picture, drawn.Y);
        _picture.Width = Math.Max(0, drawn.DrawnSize.Width);
        _picture.Height = Math.Max(0, drawn.DrawnSize.Height);

        var tip = _stage.CursorPoint;
        Canvas.SetLeft(_cursor, tip.X - 2);
        Canvas.SetTop(_cursor, tip.Y - 2);
        _cursor.Visibility = _stage.CursorVisible ? Visibility.Visible : Visibility.Collapsed;

        Canvas.SetLeft(_dragRing, tip.X - 14);
        Canvas.SetTop(_dragRing, tip.Y - 14);
        _dragRing.Visibility = _stage.DragRingVisible ? Visibility.Visible : Visibility.Collapsed;

        _cover.Visibility = _stage.Covered ? Visibility.Visible : Visibility.Collapsed;
    }

    private void FlashClick(BrowserPoint tip)
    {
        _clickFlash?.Stop();
        _clickFlash = null;
        if (!AnimationsEnabled()) return;

        Canvas.SetLeft(_clickRing, tip.X - 14);
        Canvas.SetTop(_clickRing, tip.Y - 14);
        _clickTransform.ScaleX = 0.5;
        _clickTransform.ScaleY = 0.5;
        _clickRing.Opacity = 0.85;

        var duration = new Duration(TimeSpan.FromMilliseconds(260));
        var sx = new DoubleAnimation { From = 0.5, To = 1.25, Duration = duration };
        var sy = new DoubleAnimation { From = 0.5, To = 1.25, Duration = duration };
        var fade = new DoubleAnimation { From = 0.85, To = 0.0, Duration = duration };
        Storyboard.SetTarget(sx, _clickTransform);
        Storyboard.SetTargetProperty(sx, "ScaleX");
        Storyboard.SetTarget(sy, _clickTransform);
        Storyboard.SetTargetProperty(sy, "ScaleY");
        Storyboard.SetTarget(fade, _clickRing);
        Storyboard.SetTargetProperty(fade, "Opacity");

        var story = new Storyboard();
        story.Children.Add(sx);
        story.Children.Add(sy);
        story.Children.Add(fade);
        _clickFlash = story;
        story.Begin();
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(this);
        var isMouse = e.Pointer.PointerDeviceType == PointerDeviceType.Mouse;
        if (isMouse && !point.Properties.IsLeftButtonPressed) return;

        var points = e.Pointer.PointerDeviceType != PointerDeviceType.Touch;
        _stage.TouchBegan(e.Pointer.PointerId, new BrowserPoint(point.Position.X, point.Position.Y), points);
        CapturePointer(e.Pointer);
        Place();
        e.Handled = true;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(this);
        _stage.TouchMoved(e.Pointer.PointerId, new BrowserPoint(point.Position.X, point.Position.Y));
        Place();
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        _stage.TouchEnded(e.Pointer.PointerId);
        ReleasePointerCapture(e.Pointer);
        Place();
        e.Handled = true;
    }

    private void OnPointerLost(object sender, PointerRoutedEventArgs e)
    {
        _stage.TouchCancelled(e.Pointer.PointerId);
        Place();
    }

    private void OnPointerWheelChanged(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(this);
        var delta = point.Properties.MouseWheelDelta;
        if (delta == 0) return;
        var horizontal = point.Properties.IsHorizontalMouseWheel;
        var zoom = e.KeyModifiers.HasFlag(VirtualKeyModifiers.Control);
        var steps = delta / 40.0;
        var dx = horizontal ? -steps : 0.0;
        var dy = horizontal ? 0.0 : steps;
        _stage.Wheel(dx, dy, discrete: true, at: new BrowserPoint(point.Position.X, point.Position.Y), zoom: zoom);
        Place();
        e.Handled = true;
    }

    private static Color ResolveAccentColor()
    {
        try
        {
            if (Kit.Accent is SolidColorBrush solid) return solid.Color;
        }
        catch (Exception) { }
        return Color.FromArgb(0xFF, 0x00, 0x78, 0xD4);
    }

    private static bool AnimationsEnabled()
    {
        try { return new UISettings().AnimationsEnabled; }
        catch (Exception) { return true; }
    }
}
