using Hermes.Core.Screen;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.System;

namespace HermesHQ.Features.Screen;

/// [WIN-SCREEN-PAGE] [WIN-SCREEN-INPUT-WIRE] The bot's screen on the page (App/Screen/ScreenStageView.swift at
/// 93f984bb1): black behind the picture, the framebuffer drawn where the stage's local view puts it (ScreenStageState's
/// `Drawn`, linear magnification) from a WriteableBitmap, dimmed (black at 40 %) while a stream is attached over the
/// picture, covered while the app is not active (DECISION D17: another computer's screen never sits in the task
/// switcher), and the pointer ring over it while a finger is down in control. The viewer's ScreenStageState is the one
/// truth for the view and the pointer: touch, pen, mouse and the wheel go in through ScreenStageInput (Hermes.Core),
/// Narrator through the peer's patterns (ScreenStageAccess), and the page's Zoom / Fit through ZoomBy / FitView. A view
/// change animates over 0.22 s and the ring fades over 0.3 s, linear, as the Swift's layers do; with animations off
/// in Windows both jump (`HQMotion.reduced`).
internal sealed class ScreenStageView : Grid
{
    private readonly ScreenStageState _stage;
    private readonly ScreenStageInput _input;
    private readonly Canvas _surface = new();
    private readonly Image _picture = new() { Stretch = Stretch.Fill };
    private readonly CompositeTransform _move = new();
    private readonly Border _dim = new() { Background = new SolidColorBrush(Windows.UI.Color.FromArgb(ScreenStageMotion.DimAlpha, 0, 0, 0)), Visibility = Visibility.Collapsed };
    private readonly Ellipse _ring = new()
    {
        Width = ScreenStageMotion.RingDiameter, Height = ScreenStageMotion.RingDiameter, Opacity = 0, IsHitTestVisible = false,
        Fill = new SolidColorBrush(Colors.White), Stroke = new SolidColorBrush(Windows.UI.Color.FromArgb(ScreenStageMotion.RingStrokeAlpha, 0, 0, 0)),
    };
    private readonly Canvas _ringLayer = new() { IsHitTestVisible = false };
    private readonly Border _cover = new() { Background = new SolidColorBrush(Colors.Black), Visibility = Visibility.Collapsed };
    private WriteableBitmap? _bitmap;
    private Storyboard? _viewMotion;
    private Storyboard? _ringFade;
    private ScreenRect _placed = ScreenRect.Zero;

    public ScreenStageView(ScreenViewerController viewer, string botName)
    {
        _stage = viewer.Stage;
        _input = new ScreenStageInput(_stage);
        Background = new SolidColorBrush(Colors.Black);
        AutomationProperties.SetAutomationId(this, "screen.stage");
        AutomationProperties.SetName(this, botName.Length == 0 ? "The bot’s screen" : $"{botName}’s screen");
        _picture.RenderTransform = _move;
        _surface.Children.Add(_picture);
        _ringLayer.Children.Add(_ring);
        Children.Add(_surface);
        Children.Add(_dim);
        Children.Add(_ringLayer);
        Children.Add(_cover);
        // Windows' own touch hold (the square of a right-tap), right tap and double tap are the stage's gestures here.
        IsHoldingEnabled = false;
        IsRightTapEnabled = false;
        IsDoubleTapEnabled = false;
        ManipulationMode = ManipulationModes.None;

        // The view never draws outside its own box when zoomed; every layout re-clamps (`layoutSubviews`).
        SizeChanged += (_, e) =>
        {
            Clip = new RectangleGeometry { Rect = new Rect(0, 0, e.NewSize.Width, e.NewSize.Height) };
            _stage.Layout(new ScreenSize(e.NewSize.Width, e.NewSize.Height));
            Place();
        };
        _stage.OnView = (view, committed) =>
        {
            Place();
            ViewChanged?.Invoke(view, committed);
        };
        _stage.OnRing = ShowRing;
        PointerPressed += OnPressed;
        PointerMoved += (_, e) => { _input.Moved(Args(e)); PlaceRing(); };
        PointerReleased += OnReleased;
        PointerCanceled += (_, e) => { _input.Lost(Args(e)); PlaceRing(); };
        PointerCaptureLost += (_, e) => { _input.Lost(Args(e)); PlaceRing(); };
        PointerWheelChanged += OnWheel;
        Unloaded += (_, _) => { _viewMotion?.Stop(); _ringFade?.Stop(); };
    }

    public ScreenView View => _stage.View;
    public (int Width, int Height) Size => _bitmap is { } b ? (b.PixelWidth, b.PixelHeight) : (0, 0);
    /// What the view was last told (dimmed, covered), for the walk.
    public bool Dimmed => _dim.Visibility == Visibility.Visible;
    public bool Covered => _cover.Visibility == Visibility.Visible;
    public bool HasPicture => _bitmap != null && _picture.Source != null;
    /// The ring shows (a finger is down in control).
    public bool RingShown => _stage.Ring;
    /// Where the picture is placed in the stage now (the walk reads it).
    public ScreenRect Placed => _placed;
    /// The stage's local view changed: the viewer's StageViewChanged.
    public Action<ScreenView, bool>? ViewChanged { get; set; }

    // Picture

    /// A frame from the session: BGRX, `width` × `height`, drawn opaque. (The controller has given the same frame to
    /// ScreenStageState already, so a new desktop size is laid out from it.)
    public void Show(byte[] bgrx, int width, int height)
    {
        if (width <= 0 || height <= 0 || bgrx.Length < width * height * 4) return;
        var resized = _bitmap == null || _bitmap.PixelWidth != width || _bitmap.PixelHeight != height;
        if (resized)
        {
            _bitmap = new WriteableBitmap(width, height);
            _picture.Source = _bitmap;
        }
        var pixels = new byte[width * height * 4];
        Buffer.BlockCopy(bgrx, 0, pixels, 0, pixels.Length);
        for (var i = 3; i < pixels.Length; i += 4) pixels[i] = 0xFF;
        using (var stream = System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsStream(_bitmap!.PixelBuffer))
            stream.Write(pixels, 0, pixels.Length);
        _bitmap.Invalidate();
        if (resized) Place();
    }

    /// The colour drawn at a framebuffer pixel (the walk reads the picture it shot).
    public (byte B, byte G, byte R)? PixelAt(int x, int y)
    {
        if (_bitmap is not { } b || x < 0 || y < 0 || x >= b.PixelWidth || y >= b.PixelHeight) return null;
        var at = (y * b.PixelWidth + x) * 4;
        var bytes = new byte[4];
        using var stream = System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsStream(b.PixelBuffer);
        stream.Seek(at, SeekOrigin.Begin);
        stream.ReadExactly(bytes, 0, 4);
        return (bytes[0], bytes[1], bytes[2]);
    }

    public void Draw(ScreenViewerState state)
    {
        Visibility = state.StageHidden ? Visibility.Collapsed : Visibility.Visible;
        _dim.Visibility = state.StageDimmed ? Visibility.Visible : Visibility.Collapsed;
        _cover.Visibility = state.StageCovered ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetItemStatus(this, state.StageControl ? "control" : "watching");
    }

    /// The picture at the stage's `Drawn`, the ring on the pointer over it (`place`): no animation.
    private void Place()
    {
        var drawn = _stage.Drawn;
        _placed = drawn;
        Canvas.SetLeft(_picture, drawn.X);
        Canvas.SetTop(_picture, drawn.Y);
        _picture.Width = Math.Max(0, drawn.Width);
        _picture.Height = Math.Max(0, drawn.Height);
        PlaceRing();
    }

    private void PlaceRing()
    {
        var origin = ScreenStageMotion.RingOrigin(_stage.RingPoint);
        Canvas.SetLeft(_ring, origin.X);
        Canvas.SetTop(_ring, origin.Y);
    }

    // The local view (IScreenViewerHost.SetStageView / ZoomStage / FitStage, Narrator's zoom)

    /// Sets the local view (Fit, compact typing), animated unless motion is reduced (`setView(_:animated:)`).
    public void SetView(ScreenView view, bool animated) => Animate(animated, () => { _stage.SetView(view); Place(); return true; });

    /// `stage.zoom(by:)`: about the middle of what shows. False without a picture.
    public bool ZoomBy(double factor) => Animate(true, () => _stage.ZoomBy(factor));

    /// `stage.fit()`.
    public bool Fit() => Animate(true, _stage.FitView);

    /// Runs a view change and, when it animates, draws the picture from where it was to where it went over 0.22 s
    /// (linear, CABasicAnimation's default). The ring jumps, as its layer's position action is off on the Mac.
    private bool Animate(bool animated, Func<bool> change)
    {
        var from = _placed;
        var changed = change();
        if (!changed || !ScreenStageMotion.Animates(animated, AnimationsEnabled()) || from == _placed) return changed;
        var (sx, sy, tx, ty) = ScreenStageMotion.From(from, _placed);
        _viewMotion?.Stop();
        var story = new Storyboard();
        var duration = new Duration(TimeSpan.FromSeconds(ScreenStageMotion.ViewSeconds));
        foreach (var (property, start, end) in new[] { ("ScaleX", sx, 1.0), ("ScaleY", sy, 1.0), ("TranslateX", tx, 0.0), ("TranslateY", ty, 0.0) })
        {
            var run = new DoubleAnimation { From = start, To = end, Duration = duration };
            Storyboard.SetTarget(run, _move);
            Storyboard.SetTargetProperty(run, property);
            story.Children.Add(run);
        }
        _viewMotion = story;
        story.Begin();
        return true;
    }

    // The ring (`showRing`)

    private void ShowRing(bool on)
    {
        _ringFade?.Stop();
        _ringFade = null;
        PlaceRing();
        _ring.StrokeThickness = ScreenStageMotion.Hairline(XamlRoot?.RasterizationScale ?? 1);
        var (opacity, seconds) = ScreenStageMotion.Ring(on, AnimationsEnabled());
        var from = _ring.Opacity;
        _ring.Opacity = opacity;
        if (seconds <= 0) return;
        var fade = new DoubleAnimation { From = from, To = opacity, Duration = new Duration(TimeSpan.FromSeconds(seconds)) };
        Storyboard.SetTarget(fade, _ring);
        Storyboard.SetTargetProperty(fade, "Opacity");
        var story = new Storyboard();
        story.Children.Add(fade);
        _ringFade = story;
        story.Begin();
    }

    private static bool AnimationsEnabled()
    {
        try { return new Windows.UI.ViewManagement.UISettings().AnimationsEnabled; }
        catch { return true; }
    }

    // Pointer input (PointerPressed / Moved / Released / Canceled / CaptureLost, PointerWheelChanged)

    private ScreenPointerArgs Args(PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(this);
        var p = point.Properties;
        var mods = e.KeyModifiers;
        return new ScreenPointerArgs(
            e.Pointer.PointerId, (int)e.Pointer.PointerDeviceType, new ScreenPoint(point.Position.X, point.Position.Y),
            Left: p.IsLeftButtonPressed, Right: p.IsRightButtonPressed, Middle: p.IsMiddleButtonPressed, Barrel: p.IsBarrelButtonPressed,
            WheelDelta: p.MouseWheelDelta, HorizontalWheel: p.IsHorizontalMouseWheel,
            Ctrl: mods.HasFlag(VirtualKeyModifiers.Control), Shift: mods.HasFlag(VirtualKeyModifiers.Shift));
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!_input.Pressed(Args(e))) return;
        CapturePointer(e.Pointer);
        PlaceRing();
        e.Handled = true;
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        _input.Released(Args(e));
        PlaceRing();
        // Its capture's loss comes after and finds the contact gone: never a second end.
        ReleasePointerCapture(e.Pointer);
        e.Handled = true;
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        _input.Wheel(Args(e));
        PlaceRing();
        e.Handled = true;
    }

    // Narrator (§6.3): the Mac's custom actions through UIA patterns (ScreenStageAccess).

    protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);

    private sealed partial class Peer(ScreenStageView stage) : FrameworkElementAutomationPeer(stage), IInvokeProvider, IScrollProvider, ITransformProvider2
    {
        private ScreenStageState State => stage._stage;

        protected override object? GetPatternCore(PatternInterface patternInterface) => patternInterface switch
        {
            PatternInterface.Invoke when ScreenStageAccess.Offers(State, ScreenStageAccess.Invoke) => this,
            PatternInterface.Scroll when ScreenStageAccess.Offers(State, ScreenStageAct.ScrollDown) => this,
            PatternInterface.Transform or PatternInterface.Transform2 => this,
            _ => base.GetPatternCore(patternInterface),
        };

        protected override AutomationControlType GetAutomationControlTypeCore() =>
            State.Control ? AutomationControlType.Pane : AutomationControlType.Image;

        protected override string GetHelpTextCore() => string.Join(", ", State.Acts.Select(ScreenStageState.ActName));

        public void Invoke() => ScreenStageAccess.Run(State, ScreenStageAccess.Invoke);

        // IScrollProvider: the bot's wheel, a step a call.
        public void Scroll(ScrollAmount horizontalAmount, ScrollAmount verticalAmount) =>
            ScreenStageAccess.Run(State, ScreenStageAccess.Scroll((int)verticalAmount));
        public void SetScrollPercent(double horizontalPercent, double verticalPercent) { }
        public bool HorizontallyScrollable => false;
        public double HorizontalScrollPercent => ScrollPatternIdentifiers.NoScroll;
        public double HorizontalViewSize => 100;
        public bool VerticallyScrollable => true;
        public double VerticalScrollPercent => ScrollPatternIdentifiers.NoScroll;
        public double VerticalViewSize => 100;

        // ITransformProvider2: the local view's zoom (Zoom in / Zoom out / Fit screen).
        public bool CanMove => false;
        public bool CanResize => false;
        public bool CanRotate => false;
        public void Move(double x, double y) { }
        public void Resize(double width, double height) { }
        public void Rotate(double degrees) { }
        public bool CanZoom => State.Framebuffer.Width > 0;
        public double ZoomLevel => State.View.Zoom;
        public double MinZoom => 1;
        public double MaxZoom => ScreenViewMath.MaxZoom;
        public void Zoom(double zoom) => RunZoom(ScreenStageAccess.ZoomTo(zoom, State.View.Zoom));
        public void ZoomByUnit(ZoomUnit zoomUnit) => RunZoom(ScreenStageAccess.ZoomUnit((int)zoomUnit));

        private void RunZoom(ScreenStageAct? act)
        {
            // Through the view so it animates, as the Mac's zoom(by:) / fit() do.
            switch (act)
            {
                case ScreenStageAct.ZoomIn: stage.ZoomBy(ScreenZoomSteps.StepFactor); break;
                case ScreenStageAct.ZoomOut: stage.ZoomBy(1 / ScreenZoomSteps.StepFactor); break;
                case ScreenStageAct.Fit: stage.Fit(); break;
            }
        }
    }
}
