using Hermes.Core.Heads;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.Storage.Streams;
using Windows.UI;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace HermesHQ.Features.Heads;

/// Draws a head picture (Hermes.Core `HeadPicture`) as XAML (App/Heads/HeadRenderer.swift's twin). A Shapes head is
/// vector shapes in the icon's 1024 space, scaled by a Viewbox, so it is sharp at 22 px and at 288. A Robot, Dots, Orb,
/// Pixel, Emoji or dot-matrix head is its SVG markup drawn by Direct2D (SvgImageSource), each picture made once and
/// shared by every face that shows it; an Emoji head's words are drawn over it as text (Direct2D's SVG has none).
public static class HeadDrawing
{
    public static UIElement Draw(HeadPicture picture, double side, double scale)
    {
        var canvas = new Canvas { Width = 1024, Height = 1024 };
        switch (picture)
        {
            case HeadPicture.Shapes s:
                DrawShapes(canvas, s.Layout);
                break;
            case HeadPicture.Svg svg:
                canvas.Children.Add(new Image
                {
                    Width = 1024, Height = 1024, Stretch = Stretch.Fill,
                    Source = SvgSource(svg.Markup, Math.Max(16, (int)Math.Ceiling(side * scale))),
                });
                if (svg.Label is { } label) canvas.Children.Add(Label(label));
                break;
        }
        return new Viewbox { Width = side, Height = side, Stretch = Stretch.Uniform, Child = canvas };
    }

    // MARK: Shapes heads (HeadRenderer.draw)

    static void DrawShapes(Canvas canvas, ShapeHeadLayout layout)
    {
        if (layout.Board is { } board)
        {
            canvas.Children.Add(new Path { Data = Geometry(HeadGeometry.Frame), Fill = Brush(board.Frame) });
            canvas.Children.Add(new Path { Data = Geometry(HeadGeometry.PanelPath), Fill = Brush(board.Panel) });
        }
        var head = new Canvas { Width = 1024, Height = 1024 };
        if (layout.Placement is { } p)
            head.RenderTransform = new MatrixTransform { Matrix = new Matrix(p.K, 0, 0, p.K, p.Tx, p.Ty) };
        var outline = new Path { Data = Outline(layout), Fill = Brush(layout.Fill) };
        if (layout.Rim is { } rim)
        {
            outline.Stroke = Brush(rim);
            outline.StrokeThickness = 14;
        }
        head.Children.Add(outline);
        foreach (var mark in layout.Under.Concat(layout.Face)) head.Children.Add(Mark(mark));
        canvas.Children.Add(head);
    }

    static PathGeometry Outline(ShapeHeadLayout layout)
    {
        var figure = new PathFigure { StartPoint = Pt(layout.Outline[0]), IsClosed = true, IsFilled = true };
        foreach (var (c1, c2, to) in layout.Segments)
            figure.Segments.Add(new BezierSegment { Point1 = Pt(c1), Point2 = Pt(c2), Point3 = Pt(to) });
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return geometry;
    }

    static Path Mark(HeadMark mark)
    {
        var style = mark.Style;
        Geometry data = mark.Primitive switch
        {
            HeadPrimitive.PathData d => Geometry(d.D),
            HeadPrimitive.Rect r => RoundedRect(r.X, r.Y, r.Width, r.Height, Math.Max(0, Math.Min(r.Rx, Math.Min(r.Width / 2, r.Height / 2)))),
            HeadPrimitive.Circle c => new EllipseGeometry { Center = new Point(c.Cx, c.Cy), RadiusX = c.R, RadiusY = c.R },
            HeadPrimitive.Ellipse e => new EllipseGeometry { Center = new Point(e.Cx, e.Cy), RadiusX = e.Rx, RadiusY = e.Ry },
            _ => new PathGeometry(),
        };
        var path = new Path { Data = data, Opacity = style.Opacity };
        if (style.Fill is { } fill) path.Fill = Brush(fill, style.FillOpacity);
        if (style.Stroke is { } stroke && style.StrokeWidth > 0)
        {
            path.Stroke = Brush(stroke, style.StrokeOpacity);
            path.StrokeThickness = style.StrokeWidth;
            var cap = style.RoundCap ? PenLineCap.Round : PenLineCap.Flat;
            path.StrokeStartLineCap = cap;
            path.StrokeEndLineCap = cap;
            path.StrokeLineJoin = style.RoundJoin ? PenLineJoin.Round : PenLineJoin.Miter;
        }
        if (mark.Transform.Count > 0)
        {
            var m = mark.Matrix;
            path.RenderTransform = new MatrixTransform { Matrix = new Matrix(m.M11, m.M12, m.M21, m.M22, m.OffsetX, m.OffsetY) };
        }
        return path;
    }

    /// SVG path data as a XAML geometry (Hermes.Core `SvgPath`: absolute segments; arcs in SVG's own endpoint form).
    public static PathGeometry Geometry(string d)
    {
        var geometry = new PathGeometry();
        foreach (var f in SvgPath.Parse(d))
        {
            var figure = new PathFigure { StartPoint = Pt(f.Start), IsClosed = f.Closed, IsFilled = true };
            foreach (var s in f.Segments)
            {
                PathSegment segment = s switch
                {
                    SvgSegment.Line l => new LineSegment { Point = Pt(l.To) },
                    SvgSegment.Cubic c => new BezierSegment { Point1 = Pt(c.C1), Point2 = Pt(c.C2), Point3 = Pt(c.To) },
                    SvgSegment.Quad q => new QuadraticBezierSegment { Point1 = Pt(q.C), Point2 = Pt(q.To) },
                    SvgSegment.Arc a when a.Rx == 0 || a.Ry == 0 => new LineSegment { Point = Pt(a.To) },
                    SvgSegment.Arc a => new ArcSegment
                    {
                        Point = Pt(a.To), Size = new Size(a.Rx, a.Ry), RotationAngle = a.Rotation, IsLargeArc = a.Large,
                        SweepDirection = a.Sweep ? SweepDirection.Clockwise : SweepDirection.Counterclockwise,
                    },
                    _ => new LineSegment { Point = figure.StartPoint },
                };
                figure.Segments.Add(segment);
            }
            geometry.Figures.Add(figure);
        }
        return geometry;
    }

    static PathGeometry RoundedRect(double x, double y, double w, double h, double r)
    {
        var figure = new PathFigure { StartPoint = new Point(x + r, y), IsClosed = true, IsFilled = true };
        void Line(double px, double py) => figure.Segments.Add(new LineSegment { Point = new Point(px, py) });
        void Arc(double px, double py) => figure.Segments.Add(new ArcSegment
        { Point = new Point(px, py), Size = new Size(r, r), SweepDirection = SweepDirection.Clockwise });
        Line(x + w - r, y);
        if (r > 0) Arc(x + w, y + r);
        Line(x + w, y + h - r);
        if (r > 0) Arc(x + w - r, y + h);
        Line(x + r, y + h);
        if (r > 0) Arc(x, y + h - r);
        Line(x, y + r);
        if (r > 0) Arc(x + r, y);
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return geometry;
    }

    static Point Pt(P p) => new(p.X, p.Y);

    public static Color ColorOf(HeadRgb rgb, double alpha = 1) =>
        Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), rgb.R, rgb.G, rgb.B);

    public static SolidColorBrush Brush(HeadRgb rgb, double alpha = 1) => new(ColorOf(rgb, alpha));

    /// "#RGB", "#RRGGBB" as a colour.
    public static Color ColorOf(string hex)
    {
        var h = hex.TrimStart('#');
        if (h.Length == 3) h = string.Concat(h.Select(c => $"{c}{c}"));
        return uint.TryParse(h, System.Globalization.NumberStyles.HexNumber, null, out var v) ? ColorOf(new HeadRgb(v)) : Color.FromArgb(255, 0, 0, 0);
    }

    // MARK: SVG heads

    static readonly Dictionary<string, SvgImageSource> Sources = [];

    /// One SvgImageSource per markup and pixel size, kept for the session (a list scrolls without remaking pictures).
    static SvgImageSource SvgSource(string markup, int pixels)
    {
        var key = $"{pixels}|{markup.GetHashCode()}|{markup.Length}";
        if (Sources.TryGetValue(key, out var hit)) return hit;
        if (Sources.Count > 600) Sources.Clear();
        var source = new SvgImageSource { RasterizePixelWidth = pixels, RasterizePixelHeight = pixels };
        Sources[key] = source;
        _ = LoadAsync(source, markup);
        return source;
    }

    static async Task LoadAsync(SvgImageSource source, string markup)
    {
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
            {
                writer.WriteString(markup);
                await writer.StoreAsync();
                await writer.FlushAsync();
                writer.DetachStream();
            }
            stream.Seek(0);
            var status = await source.SetSourceAsync(stream);
            if (status != SvgImageSourceLoadStatus.Success) AppLog.Note("heads", $"svg head: {status}");
        }
        catch (Exception e)
        {
            AppLog.Error("heads", e);
        }
    }

    /// An Emoji head's words, centred where the web's `<text>` puts them.
    static UIElement Label(ThemeHeadSvg.GlyphLabel label)
    {
        var text = new TextBlock
        {
            Text = label.Text, FontSize = label.FontSize * 0.8, TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Foreground = new SolidColorBrush(ColorOf(label.Fill)),
            FontWeight = label.Bold ? FontWeights.ExtraBold : FontWeights.Normal,
            CharacterSpacing = label.Bold ? -24 : 0,
            FontFamily = new FontFamily(label.Emoji ? "Segoe UI Emoji" : "Segoe UI Variable Display, Segoe UI"),
        };
        var box = new Grid { Width = 1024, Height = 1024, Children = { text } };
        box.RenderTransform = new TranslateTransform { Y = label.CentreY - 512 };
        return box;
    }
}
