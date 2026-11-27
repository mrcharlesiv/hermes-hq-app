using Hermes.Core.Voice;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;

namespace HermesHQ.Features.Voice;

public enum TalkVisualSize { Dock, Field, Indicator }

/// Port of App/Chat/Voice/TalkVisualView.swift: animated 5-bar audio level equalizer,
/// 3-dot thinking indicator, transcribing ProgressRing, and muted mic-slash glyph.
public sealed class TalkVisualView : Grid
{
    private readonly TalkVisualSize _size;
    private readonly StackPanel _barsHost;
    private readonly Rectangle[] _bars;
    private readonly StackPanel _dotsHost;
    private readonly Ellipse[] _dots;
    private readonly ProgressRing _spinner;
    private readonly FontIcon _mutedGlyph;
    private readonly DispatcherQueueTimer _timer;

    private TalkDockVisual _visual = TalkDockVisual.Bars;
    private double _level;
    private double _phase;

    public TalkVisualView(TalkVisualSize size = TalkVisualSize.Dock)
    {
        _size = size;
        var (boxW, boxH, barW, maxBarH, dotSize, glyphSize) = size switch
        {
            TalkVisualSize.Indicator => (22.0, 18.0, 2.5, 14.0, 4.0, 13.0),
            TalkVisualSize.Field => (28.0, 22.0, 3.0, 18.0, 5.0, 15.0),
            _ => (36.0, 26.0, 3.5, 22.0, 6.0, 17.0),
        };

        Width = boxW;
        Height = boxH;
        VerticalAlignment = VerticalAlignment.Center;
        HorizontalAlignment = HorizontalAlignment.Center;

        _barsHost = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = size == TalkVisualSize.Indicator ? 2 : 3,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _bars = new Rectangle[5];
        for (var i = 0; i < 5; i++)
        {
            var r = new Rectangle
            {
                Width = barW,
                Height = Math.Max(3, maxBarH * 0.25),
                RadiusX = barW / 2,
                RadiusY = barW / 2,
                VerticalAlignment = VerticalAlignment.Center,
                Fill = ThemeBrushes.Get("AccentFillColorDefaultBrush"),
            };
            _bars[i] = r;
            _barsHost.Children.Add(r);
        }

        _dotsHost = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = size == TalkVisualSize.Indicator ? 3 : 4,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        _dots = new Ellipse[3];
        for (var i = 0; i < 3; i++)
        {
            var dot = new Ellipse
            {
                Width = dotSize,
                Height = dotSize,
                Fill = ThemeBrushes.Get("AccentFillColorDefaultBrush"),
            };
            _dots[i] = dot;
            _dotsHost.Children.Add(dot);
        }

        _spinner = new ProgressRing
        {
            Width = Math.Min(boxW, boxH) - 4,
            Height = Math.Min(boxW, boxH) - 4,
            IsActive = false,
            Visibility = Visibility.Collapsed,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };

        _mutedGlyph = new FontIcon
        {
            Glyph = "\uEC54",
            FontSize = glyphSize,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };

        Children.Add(_barsHost);
        Children.Add(_dotsHost);
        Children.Add(_spinner);
        Children.Add(_mutedGlyph);

        _timer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(40);
        _timer.Tick += (_, _) =>
        {
            _phase += 0.04;
            PaintFrame();
        };

        Unloaded += (_, _) => _timer.Stop();
    }

    public void SetVisual(TalkDockVisual visual, bool active = true)
    {
        _visual = visual;
        _barsHost.Visibility = visual == TalkDockVisual.Bars ? Visibility.Visible : Visibility.Collapsed;
        _dotsHost.Visibility = visual == TalkDockVisual.Dots ? Visibility.Visible : Visibility.Collapsed;
        _spinner.Visibility = visual == TalkDockVisual.Spinner ? Visibility.Visible : Visibility.Collapsed;
        _spinner.IsActive = active && visual == TalkDockVisual.Spinner;
        _mutedGlyph.Visibility = visual == TalkDockVisual.Muted ? Visibility.Visible : Visibility.Collapsed;

        var animate = active && visual is TalkDockVisual.Bars or TalkDockVisual.Dots;
        if (animate)
        {
            if (!_timer.IsRunning) _timer.Start();
            PaintFrame();
        }
        else
        {
            _timer.Stop();
        }
    }

    public void SetLevel(double level)
    {
        _level = Math.Clamp(level, 0, 1);
        if (_visual == TalkDockVisual.Bars) PaintFrame();
    }

    private void PaintFrame()
    {
        if (_visual == TalkDockVisual.Bars)
        {
            var maxH = _size switch
            {
                TalkVisualSize.Indicator => 14.0,
                TalkVisualSize.Field => 18.0,
                _ => 22.0,
            };
            var heights = TalkVisualMath.BarHeights(_level, _phase, minHeight: 3.5, maxHeight: maxH);
            for (var i = 0; i < _bars.Length; i++) _bars[i].Height = heights[i];
        }
        else if (_visual == TalkDockVisual.Dots)
        {
            var ops = TalkVisualMath.DotOpacities(_phase, _dots.Length);
            for (var i = 0; i < _dots.Length; i++) _dots[i].Opacity = ops[i];
        }
    }
}
