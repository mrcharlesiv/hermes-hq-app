using Hermes.Core.Insights;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.System;

namespace HermesHQ.Features.Insights;

/// Category colours (StarMapPalette in App/Pages/More/StarMap/StarMapCanvas.swift): the More tiles' hues and their
/// neighbours, readable as small dots on the light and the dark page.
public static class StarMapPalette
{
    public static readonly uint[] Hues = [0x5E5CE6, 0x30B94D, 0x0A84FF, 0x00A2B8, 0x8E5CD9, 0xE5446D,
                                          0xA2845E, 0xF0902A, 0xC9A000, 0xE0483E, 0x1FAE8C, 0x7A8CA8];
    public static Windows.UI.Color Color(int slot) => Kit.Rgb(Hues[((slot % Hues.Length) + Hues.Length) % Hues.Length]);
}

/// The Star Map's Map (StarMapCanvas.swift): drawn on a XAML Canvas from the layout, one Path per layer and colour.
/// A drag pans, the wheel zooms about the pointer, a touch pinch zooms about the fingers, a double click frames the
/// cluster under it (again: the whole map), a click opens the nearest star within a 44 px target. = / - / 0 and the
/// Zoom In, Zoom Out and Whole Map buttons at the top corner. Only what is in view is drawn. Over it, a layer the pointer
/// passes through holds one native button per cluster in view (StarMapClusterElements): Tab and Narrator reach a group,
/// Enter, Space or Invoke frames it.
public sealed class StarMapCanvas : Grid
{
    private const double MoveSeconds = 0.3, AppearSeconds = 0.7;
    /// Most star names drawn at once, most links drawn at once, and above this many stars in view no halos.
    private const int LabelLimit = 60, EdgeLimit = 1500, HaloLimit = 500;

    private readonly Canvas _canvas = new() { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), IsTabStop = true };
    private readonly Microsoft.UI.Xaml.Shapes.Path _edges = new() { StrokeThickness = 1, IsHitTestVisible = false };
    private readonly Microsoft.UI.Xaml.Shapes.Path[] _halos = new Microsoft.UI.Xaml.Shapes.Path[StarMapPalette.Hues.Length];
    private readonly Microsoft.UI.Xaml.Shapes.Path[] _dots = new Microsoft.UI.Xaml.Shapes.Path[StarMapPalette.Hues.Length];
    private readonly Microsoft.UI.Xaml.Shapes.Path _rings = new() { StrokeThickness = 1, IsHitTestVisible = false };
    private readonly List<TextBlock> _clusterLabels = [], _starLabels = [];
    private readonly Action<string> _onStar;
    /// [WIN-STAR-CLUSTER-ACCESS] The cluster buttons: never hit by the pointer (stars, clicks and drags stay the map's),
    /// keyed by category so the one holding the keyboard survives a pan, a zoom or a redraw.
    private readonly Canvas _clusterLayer = new() { IsHitTestVisible = false, TabFocusNavigation = KeyboardNavigationMode.Local };
    private readonly Dictionary<string, Button> _clusterButtons = [];

    private StarMapLayout _layout = new();
    private StarMapCamera _camera = new();
    /// The camera once a gesture or a move has ended (StarMapStage.settled): what the cluster buttons follow, so they are
    /// not laid out again on every frame of a pan.
    private StarMapCamera _settled = new();
    private int _framed = -1;
    private bool _flewIn;
    private double _appear = 1, _fit = 1;
    private int _pendingGeneration = -1;
    private StarMapLayout? _pendingLayout;

    // A move (zoom button, double click, Whole Map) and the fly-in, frame by frame.
    private StarMapCamera _from, _to;
    private DateTime _moveStart, _appearStart;
    private bool _moving, _appearing, _rendering;

    // Dragging with the mouse or pen.
    private uint? _dragPointer;
    private Point _dragLast;
    private DispatcherQueueTimerHandle? _tapTimer;

    public double Zoom => _camera.Scale;
    /// [WIN-STAR-FIRST] What the last redraw put on screen: stars in view and links drawn (0 before the first draw).
    public int DrawnStars { get; private set; }
    public int DrawnEdges { get; private set; }
    /// The fly-in has ended, or never ran.
    public bool Settled => !_appearing;

    public StarMapCanvas(Action<string> onStar)
    {
        _onStar = onStar;
        for (var i = 0; i < _dots.Length; i++)
        {
            var color = StarMapPalette.Color(i);
            _halos[i] = new() { Fill = new SolidColorBrush(color) { Opacity = 0.16 }, IsHitTestVisible = false };
            _dots[i] = new() { Fill = new SolidColorBrush(color), IsHitTestVisible = false };
        }
        _canvas.Children.Add(_edges);
        foreach (var h in _halos) _canvas.Children.Add(h);
        foreach (var d in _dots) _canvas.Children.Add(d);
        _canvas.Children.Add(_rings);
        Children.Add(_canvas);
        Children.Add(_clusterLayer);
        Children.Add(ZoomButtons());

        AutomationProperties.SetName(_canvas, "Star Map");
        AutomationProperties.SetAutomationId(_canvas, "starmap.canvas");
        AutomationProperties.SetHelpText(_canvas, "Zooms in and out. The List shows every skill.");

        _canvas.SizeChanged += (_, _) => { ClipCanvas(); Resized(); };
        _canvas.PointerPressed += Pressed;
        _canvas.PointerMoved += Moved;
        _canvas.PointerReleased += Released;
        _canvas.PointerCanceled += Released;
        _canvas.PointerCaptureLost += Released;
        _canvas.PointerWheelChanged += Wheel;
        _canvas.Tapped += OnTapped;
        _canvas.DoubleTapped += OnDoubleTapped;
        _canvas.KeyDown += Key;
        _canvas.ManipulationMode = ManipulationModes.TranslateX | ManipulationModes.TranslateY | ManipulationModes.Scale;
        _canvas.ManipulationDelta += Manipulated;
        _canvas.ManipulationCompleted += (_, _) => Settle();
        _clusterLayer.KeyDown += Key;   // = / - / 0 also from a cluster button
        ActualThemeChanged += (_, _) => Redraw();
        Unloaded += (_, _) =>
        {
            _tapTimer?.Stop();
            _tapTimer = null;
            StopRendering();
        };
    }

    private void ClipCanvas() => _canvas.Clip = new RectangleGeometry { Rect = new Rect(0, 0, _canvas.ActualWidth, _canvas.ActualHeight) };

    private double W => _canvas.ActualWidth;
    private double H => _canvas.ActualHeight;
    private double Floor => StarMapCamera.Floor(_fit);

    // ------------------------------------------------------------------ showing a layout (StarMapStage.show)

    /// A new layout (graph, bot or filter) is framed once, whole; the first ever flies in from the cluster centres.
    public void Show(StarMapLayout layout, int generation)
    {
        _pendingLayout = layout;
        _pendingGeneration = generation;
        Resized();
    }

    private void Resized()
    {
        if (W <= 1 || H <= 1) return;
        if (_pendingLayout != null && _pendingGeneration != _framed)
        {
            _framed = _pendingGeneration;
            _layout = _pendingLayout;
            _fit = _layout.Whole(W, H, most: 8).Scale;
            _moving = false;
            _camera = _layout.Whole(W, H, most: StarMapViewRules.DesktopFitScale);
            _settled = _camera;
            if (!_flewIn && _layout.Stars.Count > 0)
            {
                _flewIn = true;
                if (new Windows.UI.ViewManagement.UISettings().AnimationsEnabled)
                {
                    _appear = 0;
                    _appearing = true;
                    _appearStart = DateTime.UtcNow;
                    StartRendering();
                }
            }
        }
        else
        {
            _fit = _layout.Whole(W, H, most: 8).Scale;
            _camera.Scale = Math.Max(Floor, _camera.Scale);
            _settled = _camera;
        }
        Redraw();
        RefreshClusters();
    }

    // ------------------------------------------------------------------ moves

    public void ZoomIn() => ZoomBy(StarMapCamera.StepFactor);
    public void ZoomOut() => ZoomBy(1 / StarMapCamera.StepFactor);
    public void WholeMap() => Move(_layout.Whole(W, H, most: StarMapViewRules.DesktopFitScale));

    private void ZoomBy(double factor)
    {
        var next = _camera;
        next.Zoom(factor, new Hermes.Core.Insights.Pt(W / 2, H / 2), W, H, Floor);
        Move(next);
    }

    private StarMapCamera Framing(int cluster) => StarMapClusterTargets.Framing(_layout, cluster, W, H, Floor);

    /// A cluster button's activation (StarMapStage.zoom(toCluster:)): frames that group, found by its key in the layout
    /// now shown.
    public void ZoomToCluster(string category)
    {
        if (W <= 1 || H <= 1 || StarMapClusterTargets.IndexOf(_layout, category) is not { } index) return;
        Move(Framing(index));
    }

    private void Move(StarMapCamera next)
    {
        _settled = next;
        RefreshClusters();
        if (!new Windows.UI.ViewManagement.UISettings().AnimationsEnabled) { _camera = next; _moving = false; Redraw(); return; }
        _from = _camera;
        _to = next;
        _moveStart = DateTime.UtcNow;
        _moving = true;
        StartRendering();
    }

    private void StartRendering()
    {
        if (_rendering) return;
        _rendering = true;
        CompositionTarget.Rendering += Frame;
    }

    private void StopRendering()
    {
        if (!_rendering) return;
        _rendering = false;
        CompositionTarget.Rendering -= Frame;
    }

    private void Frame(object? sender, object e)
    {
        var now = DateTime.UtcNow;
        if (_moving)
        {
            var t = Math.Min(1, (now - _moveStart).TotalSeconds / MoveSeconds);
            var k = t < 0.5 ? 2 * t * t : 1 - Math.Pow(-2 * t + 2, 2) / 2;   // ease in and out
            _camera = new StarMapCamera(_from.Scale + (_to.Scale - _from.Scale) * k,
                new Hermes.Core.Insights.Pt(_from.Center.X + (_to.Center.X - _from.Center.X) * k, _from.Center.Y + (_to.Center.Y - _from.Center.Y) * k));
            if (t >= 1) { _camera = _to; _moving = false; }
        }
        if (_appearing)
        {
            var t = Math.Min(1, (now - _appearStart).TotalSeconds / AppearSeconds);
            _appear = 1 - Math.Pow(1 - t, 3);   // ease out
            if (t >= 1) { _appear = 1; _appearing = false; }
        }
        if (!_moving && !_appearing) StopRendering();
        Redraw();
    }

    // ------------------------------------------------------------------ input

    private void Pressed(object sender, PointerRoutedEventArgs e)
    {
        _canvas.Focus(FocusState.Pointer);
        if (e.Pointer.PointerDeviceType == PointerDeviceType.Touch) return;
        if (!e.GetCurrentPoint(_canvas).Properties.IsLeftButtonPressed) return;
        _dragPointer = e.Pointer.PointerId;
        _dragLast = e.GetCurrentPoint(_canvas).Position;
        _canvas.CapturePointer(e.Pointer);
    }

    private void Moved(object sender, PointerRoutedEventArgs e)
    {
        if (_dragPointer != e.Pointer.PointerId) return;
        var p = e.GetCurrentPoint(_canvas).Position;
        _moving = false;
        _camera.Pan(p.X - _dragLast.X, p.Y - _dragLast.Y);
        _camera.Clamp(_layout.Bounds);
        _dragLast = p;
        Redraw();
    }

    private void Released(object sender, PointerRoutedEventArgs e)
    {
        if (_dragPointer != e.Pointer.PointerId) return;
        _dragPointer = null;
        _canvas.ReleasePointerCapture(e.Pointer);
        Settle();
    }

    /// A gesture ended: the cluster buttons follow the camera now.
    private void Settle()
    {
        if (_settled == _camera) return;
        _settled = _camera;
        RefreshClusters();
    }

    /// The wheel zooms about the pointer (as Maps does; a mouse has no pinch); Shift pans sideways, a horizontal wheel too.
    private void Wheel(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(_canvas);
        var delta = point.Properties.MouseWheelDelta;
        _moving = false;
        if (point.Properties.IsHorizontalMouseWheel || (e.KeyModifiers & VirtualKeyModifiers.Shift) != 0)
            _camera.Pan(-delta / 120.0 * 40, 0);
        else
        {
            var factor = StarMapCamera.ScrollFactor(delta / 12.0, discrete: true);
            if (factor != 1) _camera.Zoom(factor, new Hermes.Core.Insights.Pt(point.Position.X, point.Position.Y), W, H, Floor);
        }
        _camera.Clamp(_layout.Bounds);
        Redraw();
        Settle();   // each notch is a whole gesture
        e.Handled = true;
    }

    /// A touch pinch zooms about the fingers and pans with them.
    private void Manipulated(object sender, ManipulationDeltaRoutedEventArgs e)
    {
        if (e.PointerDeviceType != PointerDeviceType.Touch) return;
        _moving = false;
        var d = e.Delta;
        _camera.Pan(d.Translation.X, d.Translation.Y);
        if (d.Scale > 0 && double.IsFinite(d.Scale) && d.Scale != 1)
            _camera.Zoom(d.Scale, new Hermes.Core.Insights.Pt(e.Position.X, e.Position.Y), W, H, Floor);
        _camera.Clamp(_layout.Bounds);
        Redraw();
    }

    /// A click waits to see that it is not the first of a double click (in a cluster every point is near some star).
    private void OnTapped(object sender, TappedRoutedEventArgs e)
    {
        var p = e.GetPosition(_canvas);
        _tapTimer?.Stop();
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(260);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            _tapTimer = null;
            var hit = _layout.Hit(_camera.World(new Hermes.Core.Insights.Pt(p.X, p.Y), W, H), 22 / _camera.Scale);
            if (hit is { } i) _onStar(_layout.Stars[i].Id);
        };
        _tapTimer = new DispatcherQueueTimerHandle(timer);
        timer.Start();
    }

    /// Frames the cluster under the pointer; when it already is framed (or there is none), the whole map.
    private void OnDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        _tapTimer?.Stop();
        _tapTimer = null;
        var p = e.GetPosition(_canvas);
        var next = _layout.Whole(W, H, most: StarMapViewRules.DesktopFitScale);
        if (_layout.ClusterAt(_camera.World(new Hermes.Core.Insights.Pt(p.X, p.Y), W, H), 30 / _camera.Scale) is { } index)
        {
            var target = Framing(index);
            var moved = Math.Sqrt(Math.Pow(target.Center.X - _camera.Center.X, 2) + Math.Pow(target.Center.Y - _camera.Center.Y, 2)) * _camera.Scale;
            if (Math.Abs(target.Scale - _camera.Scale) > 0.05 * _camera.Scale || moved > 24) next = target;
        }
        Move(next);
        e.Handled = true;
    }

    private void Key(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Add or (VirtualKey)187: ZoomIn(); break;            // = / + and the keypad's +
            case VirtualKey.Subtract or (VirtualKey)189: ZoomOut(); break;      // - and the keypad's -
            case VirtualKey.Number0 or VirtualKey.NumberPad0: WholeMap(); break;
            default: return;
        }
        e.Handled = true;
    }

    private FrameworkElement ZoomButtons()
    {
        Button B(string glyph, string label, string id, Action run)
        {
            var b = new Button
            {
                Content = new FontIcon { Glyph = glyph, FontSize = 15 }, Width = 40, Height = 40, Padding = new Thickness(0),
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
            };
            ToolTipService.SetToolTip(b, label);
            AutomationProperties.SetName(b, label);
            AutomationProperties.SetAutomationId(b, id);
            b.Click += (_, _) => run();
            return b;
        }
        Border Rule() => new() { Height = 1, Width = 28, Background = Kit.Brush("DividerStrokeColorDefaultBrush"), HorizontalAlignment = HorizontalAlignment.Center };
        var stack = new StackPanel
        {
            Children =
            {
                B("", "Zoom In", "starmap.zoomIn", ZoomIn), Rule(),
                B("", "Zoom Out", "starmap.zoomOut", ZoomOut), Rule(),
                B("", "Whole Map", "starmap.whole", WholeMap),
            },
        };
        return new Border
        {
            Child = stack, CornerRadius = new CornerRadius(20), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 12, 20, 0), Background = Kit.Brush("AcrylicInAppFillColorDefaultBrush"),
            BorderBrush = Kit.Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
        };
    }

    // ------------------------------------------------------------------ cluster buttons (StarMapClusterElements)

    /// Lays the cluster buttons out from the settled camera: one per cluster in view among the layout's first forty,
    /// reused under its category, in layout order for Tab. It never moves the keyboard.
    private void RefreshClusters()
    {
        var targets = StarMapClusterTargets.Make(_layout, _settled, W, H);
        var keep = new HashSet<string>(targets.Select(t => t.Category));
        foreach (var gone in _clusterButtons.Keys.Where(k => !keep.Contains(k)).ToList())
        {
            _clusterLayer.Children.Remove(_clusterButtons[gone]);
            _clusterButtons.Remove(gone);
        }
        for (var order = 0; order < targets.Count; order++)
        {
            var target = targets[order];
            if (!_clusterButtons.TryGetValue(target.Category, out var b))
            {
                var category = target.Category;
                b = new Button
                {
                    Padding = new Thickness(0), BorderThickness = new Thickness(0), MinWidth = 0, MinHeight = 0,
                    Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                    BorderBrush = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                };
                AutomationProperties.SetHelpText(b, StarMapClusterTargets.Hint);
                b.Click += (_, _) => ZoomToCluster(category);
                _clusterButtons[category] = b;
                _clusterLayer.Children.Add(b);
            }
            AutomationProperties.SetName(b, target.Spoken);
            AutomationProperties.SetAutomationId(b, target.AutomationId);
            AutomationProperties.SetPositionInSet(b, order + 1);
            AutomationProperties.SetSizeOfSet(b, targets.Count);
            b.TabIndex = order;
            b.Width = target.Frame.Width;
            b.Height = target.Frame.Height;
            Canvas.SetLeft(b, target.Frame.X);
            Canvas.SetTop(b, target.Frame.Y);
        }
        _clusterLayer.Clip = new RectangleGeometry { Rect = new Rect(0, 0, Math.Max(0, W), Math.Max(0, H)) };
    }

    // ------------------------------------------------------------------ drawing (StarMapDrawing.draw)

    private Hermes.Core.Insights.Pt Place(StarMapLayout.Star s)
    {
        if (_appear >= 1) return _camera.Screen(s.Point, W, H);
        var c = _layout.Clusters[s.Cluster].Center;
        return _camera.Screen(new Hermes.Core.Insights.Pt(c.X + (s.Point.X - c.X) * _appear, c.Y + (s.Point.Y - c.Y) * _appear), W, H);
    }

    private void Redraw()
    {
        var secondary = Kit.Brush("TextFillColorSecondaryBrush") as SolidColorBrush;
        var label = Kit.Brush("TextFillColorPrimaryBrush") as SolidColorBrush;
        var secondaryColor = secondary?.Color ?? Microsoft.UI.Colors.Gray;
        var labelColor = label?.Color ?? Microsoft.UI.Colors.White;
        var appear = Math.Clamp(_appear, 0, 1);
        foreach (var t in _clusterLabels) t.Visibility = Visibility.Collapsed;
        foreach (var t in _starLabels) t.Visibility = Visibility.Collapsed;
        if (_layout.Stars.Count == 0 || W <= 1 || H <= 1)
        {
            _edges.Data = null; _rings.Data = null;
            DrawnStars = DrawnEdges = 0;
            foreach (var p in _dots) p.Data = null;
            foreach (var p in _halos) p.Data = null;
            return;
        }
        var visible = _camera.Visible(W, H, 28);

        // Links: hairlines at 25 %, fainter (and no more than EdgeLimit) when there are many in view.
        var lines = new GeometryGroup();
        var count = 0;
        foreach (var edge in _layout.Edges)
        {
            var a = _layout.Stars[edge.A]; var b = _layout.Stars[edge.B];
            if (Math.Max(a.Point.X, b.Point.X) < visible.MinX || Math.Min(a.Point.X, b.Point.X) > visible.MaxX
                || Math.Max(a.Point.Y, b.Point.Y) < visible.MinY || Math.Min(a.Point.Y, b.Point.Y) > visible.MaxY) continue;
            var pa = Place(a); var pb = Place(b);
            lines.Children.Add(new LineGeometry { StartPoint = new Point(pa.X, pa.Y), EndPoint = new Point(pb.X, pb.Y) });
            if (++count >= EdgeLimit) break;
        }
        var calm = count <= 250 ? 1 : Math.Max(0.3, Math.Sqrt(250.0 / count));
        _edges.Data = count > 0 ? lines : null;
        _edges.Stroke = new SolidColorBrush(secondaryColor) { Opacity = 0.25 * calm * appear };

        // Stars: one path per colour.
        var inView = _layout.StarsIn(visible);
        var slots = StarMapPalette.Hues.Length;
        var dots = new GeometryGroup[slots];
        var halos = new GeometryGroup[slots];
        for (var i = 0; i < slots; i++) { dots[i] = new GeometryGroup(); halos[i] = new GeometryGroup(); }
        var rings = new GeometryGroup();
        var withHalos = inView.Count <= HaloLimit;
        foreach (var m in inView)
        {
            var s = _layout.Stars[m];
            var p = Place(s);
            var r = _camera.StarRadius(s.Radius);
            var slot = ((_layout.Clusters[s.Cluster].Color % slots) + slots) % slots;
            if (r < 1.1) dots[slot].Children.Add(new RectangleGeometry { Rect = new Rect(p.X - r, p.Y - r, r * 2, r * 2) });
            else dots[slot].Children.Add(new EllipseGeometry { Center = new Point(p.X, p.Y), RadiusX = r, RadiusY = r });
            if (withHalos && s.UseCount > 0) halos[slot].Children.Add(new EllipseGeometry { Center = new Point(p.X, p.Y), RadiusX = r * 1.9, RadiusY = r * 1.9 });
            if (s.Pinned && r >= 2) rings.Children.Add(new EllipseGeometry { Center = new Point(p.X, p.Y), RadiusX = r + 2.5, RadiusY = r + 2.5 });
        }
        for (var i = 0; i < slots; i++)
        {
            _dots[i].Data = dots[i].Children.Count > 0 ? dots[i] : null;
            _dots[i].Opacity = appear;
            _halos[i].Data = halos[i].Children.Count > 0 ? halos[i] : null;
            _halos[i].Opacity = appear;
        }
        _rings.Data = rings.Children.Count > 0 ? rings : null;
        DrawnStars = inView.Count;
        DrawnEdges = count;
        _rings.Stroke = new SolidColorBrush(labelColor) { Opacity = 0.7 * appear };

        // Cluster names, on the outer side of each cluster.
        var taken = new List<Box>();
        var used = 0;
        var labelDrop = StarMapLayout.LabelDrop * Math.Min(1.0, Math.Max(StarMapViewRules.DesktopFitScale, _camera.Scale));
        foreach (var c in _layout.Clusters)
        {
            var edge = _camera.Screen(new Hermes.Core.Insights.Pt(c.Center.X + c.LabelSide.X * c.Radius, c.Center.Y + c.LabelSide.Y * c.Radius), W, H);
            double px = edge.X + c.LabelSide.X * labelDrop, py = edge.Y + c.LabelSide.Y * labelDrop;
            if (px < -120 || px > W + 120 || py < -30 || py > H + 30) continue;
            var t = Label(_clusterLabels, used++, c.Title, 11, FontWeights.SemiBold, secondaryColor, appear);
            var size = t.DesiredSize;
            var anchor = c.LabelAnchor;
            var box = new Box(px - size.Width * anchor.X, py - size.Height * anchor.Y, size.Width, size.Height);
            for (var tries = 0; tries < 6 && taken.Any(o => o.Intersects(box.Inset(-2, 0))); tries++)
            {
                px += c.LabelSide.X * 8; py += c.LabelSide.Y * 8;
                box = new Box(px - size.Width * anchor.X, py - size.Height * anchor.Y, size.Width, size.Height);
            }
            taken.Add(box);
            Canvas.SetLeft(t, box.X); Canvas.SetTop(t, box.Y);
        }

        // Star names above 1.6×: the most used first, left out where they would run into a name already drawn.
        if (_camera.Scale > StarMapCamera.LabelZoom && appear >= 1)
        {
            var fade = Math.Min(1, (_camera.Scale - StarMapCamera.LabelZoom) / 0.25);
            var ranked = inView.OrderByDescending(i => _layout.Stars[i].UseCount).ThenBy(i => i).Take(LabelLimit);
            var n = 0;
            foreach (var m in ranked)
            {
                var s = _layout.Stars[m];
                var p = _camera.Screen(s.Point, W, H);
                var name = s.Label.Length > 24 ? s.Label[..23] + "…" : s.Label;
                var t = Label(_starLabels, n, name, 11, FontWeights.Normal, labelColor, 0.9 * fade);
                var size = t.DesiredSize;
                var top = p.Y + _camera.StarRadius(s.Radius) + 3;
                var box = new Box(p.X - size.Width / 2, top, size.Width, size.Height);
                if (taken.Any(o => o.Intersects(box.Inset(-4, -1)))) { t.Visibility = Visibility.Collapsed; continue; }
                taken.Add(box);
                n++;
                Canvas.SetLeft(t, box.X); Canvas.SetTop(t, box.Y);
            }
        }
    }

    private TextBlock Label(List<TextBlock> pool, int index, string text, double size, Windows.UI.Text.FontWeight weight, Windows.UI.Color color, double opacity)
    {
        while (pool.Count <= index)
        {
            var nt = new TextBlock { IsHitTestVisible = false, TextWrapping = TextWrapping.NoWrap };
            pool.Add(nt);
            _canvas.Children.Add(nt);
        }
        var t = pool[index];
        t.Text = text;
        t.FontSize = size;
        t.FontWeight = weight;
        t.Foreground = new SolidColorBrush(color);
        t.Opacity = opacity;
        t.Visibility = Visibility.Visible;
        t.Measure(new Size(260, 60));
        return t;
    }

    /// A one-shot timer that can be stopped.
    private sealed class DispatcherQueueTimerHandle(Microsoft.UI.Dispatching.DispatcherQueueTimer timer)
    {
        public void Stop() => timer.Stop();
    }
}
