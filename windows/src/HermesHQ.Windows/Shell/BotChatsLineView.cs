using Hermes.Core.Heads;
using Hermes.Core.Model;
using Hermes.Core.Sessions;
using HermesHQ.Features.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;
using XamlPath = Microsoft.UI.Xaml.Shapes.Path;

namespace HermesHQ.Shell;

/// Session state for status-aware bot branch styles (`Splines`, `Dots`, `Rail`; App/Bots/BotChatsUnder.swift `BotChatsLine.NodeStatus`).
public enum BotChatNodeStatus
{
    Quiet,
    Unread,
    Waiting,
    Working,
}

/// WinUI 3 vector connector down a bot's chats in the sidebar, rendering all 9 `BotChatsStyleKind` styles
/// (`Branch`, `Arrows`, `Splines`, `Quill`, `Dots`, `Rail`, `Line`, `Dividers`, `None`) with unified-opacity geometry,
/// top fade on the first row, status-aware node coloring, and hover/selected emphasis
/// (App/Bots/BotChatsUnder.swift `BotChatsLine`, `c8d7bdd88`).
public sealed partial class BotChatsLineView : Grid
{
    public const double DefaultStrokeWidth = 1.5;
    public const double DefaultReach = 10.5;
    public const double DefaultLineX = 5.0;
    public const double DefaultTail = 3.0;

    private readonly Canvas _canvas = new() { IsHitTestVisible = false };

    private bool _first;
    private bool _last;
    private bool _more;
    private BotChatsStyleKind _style;
    private BotChatNodeStatus _status;
    private bool _emphasized;
    private Color _tint;
    private double _lineX = DefaultLineX;
    private double _reach = DefaultReach;
    private double _tail = DefaultTail;

    public BotChatsLineView(
        bool first,
        bool last,
        bool more,
        BotChatsStyleKind style,
        BotChatNodeStatus status,
        Color tint,
        double lineX = DefaultLineX,
        double reach = DefaultReach,
        double tail = DefaultTail)
    {
        _first = first;
        _last = last;
        _more = more;
        _style = style;
        _status = status;
        _tint = tint;
        _lineX = lineX;
        _reach = reach;
        _tail = tail;

        IsHitTestVisible = false;
        AutomationProperties.SetAccessibilityView(this, AccessibilityView.Raw);
        Children.Add(_canvas);
        SizeChanged += (_, _) => Redraw();
        Loaded += (_, _) => Redraw();
    }

    public static BotChatNodeStatus StatusOf(SessionSummary session)
    {
        if (session.Status == SessionStatus.NeedsInput) return BotChatNodeStatus.Waiting;
        if (session.IsRunning || session.Status == SessionStatus.Working) return BotChatNodeStatus.Working;
        if (session.Unread) return BotChatNodeStatus.Unread;
        return BotChatNodeStatus.Quiet;
    }

    /// Resolves the bot's own branch tint matching `Bot.chatsTint` (App/Bots/BotChatsUnder.swift):
    /// Ink -> Label, Paper -> Label2, else the bot's head accent color.
    public static Color BotTintColor(Bot? bot, string profile)
    {
        var headColor = Head.Resolve(bot?.HeadRaw, profile).Color;
        if (headColor == HeadColor.Ink) return ThemeService.ToColor(ThemeService.Tokens.Label);
        if (headColor == HeadColor.Paper) return ThemeService.ToColor(ThemeService.Tokens.Label2);
        var rgb = HeadTones.Accent(headColor);
        return Color.FromArgb(255, rgb.R, rgb.G, rgb.B);
    }

    public void SetEmphasized(bool emphasized)
    {
        if (_emphasized == emphasized) return;
        _emphasized = emphasized;
        Redraw();
    }

    public void UpdateStyle(BotChatsStyleKind style)
    {
        if (_style == style) return;
        _style = style;
        Redraw();
    }

    private void Redraw()
    {
        _canvas.Children.Clear();
        if (_style == BotChatsStyleKind.None) return;

        var h = ActualHeight > 1 ? ActualHeight : 26;
        var content = Math.Max(1.0, h - (_last ? _tail : 0));
        var mid = content / 2.0;
        var endX = _lineX + _reach;
        var fadeTop = Math.Min(7.0, mid * 0.55);
        var waitingColor = ThemeService.ToColor(ThemeService.Tokens.Orange);

        switch (_style)
        {
            case BotChatsStyleKind.Branch:
                DrawBranch(h, mid, endX, fadeTop);
                break;
            case BotChatsStyleKind.Arrows:
                DrawArrows(h, mid, endX, fadeTop);
                break;
            case BotChatsStyleKind.Splines:
                DrawSplines(h, mid, endX, fadeTop, waitingColor);
                break;
            case BotChatsStyleKind.Quill:
                DrawQuill(h, mid, endX, fadeTop);
                break;
            case BotChatsStyleKind.Dots:
                DrawDots(h, mid, fadeTop, waitingColor);
                break;
            case BotChatsStyleKind.Rail:
                DrawRail(h, content, mid);
                break;
            case BotChatsStyleKind.Line:
            case BotChatsStyleKind.Dividers:
                DrawPlainLine(h, content, fadeTop);
                break;
        }
    }

    private void DrawBranch(double h, double mid, double endX, double fadeTop)
    {
        var r = Math.Min(8.5, Math.Min(_reach * 0.72, Math.Max(2.0, mid - 1)));
        var tipX = _more ? endX - 2 : endX;
        var layer = UnifiedLayer(_emphasized ? 0.94 : 0.64);
        var shade = TopFadeBrush(h, fadeTop, 1.0);

        var trunkEnd = _last ? Math.Max(0, mid - r) : h;
        if (trunkEnd > 0)
        {
            layer.Children.Add(StrokePath(LineFigure(_lineX, 0, _lineX, trunkEnd), shade, DefaultStrokeWidth, PenLineCap.Flat, PenLineCap.Flat));
        }

        var sy = Math.Max(0, mid - r);
        var cr = mid - sy;
        var arm = new PathFigure { StartPoint = new Point(_lineX, sy), IsClosed = false, IsFilled = false };
        arm.Segments.Add(new QuadraticBezierSegment { Point1 = new Point(_lineX, mid), Point2 = new Point(_lineX + cr, mid) });
        arm.Segments.Add(new LineSegment { Point = new Point(tipX, mid) });
        layer.Children.Add(StrokePath(arm, shade, DefaultStrokeWidth, PenLineCap.Round, PenLineCap.Round));
    }

    private void DrawArrows(double h, double mid, double endX, double fadeTop)
    {
        var r = Math.Min(8.5, Math.Min(_reach * 0.66, Math.Max(2.0, mid - 1)));
        var tipX = _more ? endX - 2.5 : endX;
        var lineW = _emphasized ? 1.6 : 1.4;
        var layer = UnifiedLayer(_emphasized ? 0.92 : 0.56);
        var shade = TopFadeBrush(h, fadeTop, 1.0);

        var trunkEnd = _last ? Math.Max(0, mid - r) : h;
        if (trunkEnd > 0)
        {
            layer.Children.Add(StrokePath(LineFigure(_lineX, 0, _lineX, trunkEnd), shade, lineW, PenLineCap.Flat, PenLineCap.Flat));
        }

        var sy = Math.Max(0, mid - r);
        var cr = mid - sy;
        var arm = new PathFigure { StartPoint = new Point(_lineX, sy), IsClosed = false, IsFilled = false };
        arm.Segments.Add(new QuadraticBezierSegment { Point1 = new Point(_lineX, mid), Point2 = new Point(_lineX + cr, mid) });
        arm.Segments.Add(new LineSegment { Point = new Point(tipX, mid) });
        layer.Children.Add(StrokePath(arm, shade, lineW, PenLineCap.Round, PenLineCap.Round));

        if (!_more)
        {
            const double aw = 3.4, ah = 2.9;
            var chevron = new PathFigure { StartPoint = new Point(tipX - aw, mid - ah), IsClosed = false, IsFilled = false };
            chevron.Segments.Add(new LineSegment { Point = new Point(tipX, mid) });
            chevron.Segments.Add(new LineSegment { Point = new Point(tipX - aw, mid + ah) });
            _canvas.Children.Add(StrokePath(chevron, Solid(_tint, _emphasized ? 1.0 : 0.88),
                _emphasized ? 1.7 : 1.45, PenLineCap.Round, PenLineCap.Round));
        }
    }

    private void DrawSplines(double h, double mid, double endX, double fadeTop, Color waitingColor)
    {
        var sy = Math.Max(0, mid - Math.Min(12.0, mid - 1));
        var tipX = endX - 2;
        var spineEnd = _last ? sy : h;
        if (spineEnd > 0)
        {
            _canvas.Children.Add(StrokePath(LineFigure(_lineX, 0, _lineX, spineEnd), TopFadeBrush(h, fadeTop, 0.40),
                1.3, PenLineCap.Flat, PenLineCap.Flat));
        }

        var curve = new PathFigure { StartPoint = new Point(_lineX, sy), IsClosed = false, IsFilled = false };
        curve.Segments.Add(new BezierSegment
        {
            Point1 = new Point(_lineX, sy + (mid - sy) * 0.72),
            Point2 = new Point(_lineX + (tipX - _lineX) * 0.22, mid),
            Point3 = new Point(tipX, mid),
        });
        var curveOpacity = _emphasized ? 0.96 : _more ? 0.44 : 0.62;
        _canvas.Children.Add(StrokePath(curve, Solid(_tint, curveOpacity), _emphasized ? 1.7 : 1.35, PenLineCap.Round, PenLineCap.Round));

        if (!_more)
        {
            var isHot = _emphasized || _status is BotChatNodeStatus.Unread or BotChatNodeStatus.Waiting or BotChatNodeStatus.Working;
            var dotColor = _status == BotChatNodeStatus.Waiting ? waitingColor : _tint;
            var rDot = isHot ? 2.5 : 2.0;
            if (isHot)
            {
                AddCircle(_canvas, tipX, mid, rDot + 2.2, Solid(dotColor, 0.22), null, 0);
            }
            AddCircle(_canvas, tipX, mid, rDot, Solid(dotColor, isHot ? 0.98 : 0.78), null, 0);
        }
    }

    private void DrawQuill(double h, double mid, double endX, double fadeTop)
    {
        var r = Math.Min(9.5, Math.Min(_reach * 0.74, Math.Max(2.0, mid - 1)));
        var sy = Math.Max(0, mid - r);
        var cr = mid - sy;
        var tipX = _more ? endX - 2 : endX + 0.5;
        var layer = UnifiedLayer(_emphasized ? 0.94 : _more ? 0.56 : 0.74);
        var shade = TopFadeBrush(h, fadeTop, 1.0);

        var trunkEnd = _last ? Math.Max(0, sy + 1.5) : h;
        if (trunkEnd > 0)
        {
            var topW = _first ? 1.1 : 0.72;
            const double botW = 0.72;
            var spine = new PathFigure { StartPoint = new Point(_lineX - topW, 0), IsClosed = true, IsFilled = true };
            spine.Segments.Add(new LineSegment { Point = new Point(_lineX + topW, 0) });
            spine.Segments.Add(new LineSegment { Point = new Point(_lineX + botW, trunkEnd) });
            spine.Segments.Add(new LineSegment { Point = new Point(_lineX - botW, trunkEnd) });
            layer.Children.Add(FillPath(spine, shade));
        }

        const double wStart = 0.86;
        const double tipR = 0.35;
        var midTailX = _lineX + cr + (tipX - (_lineX + cr)) * 0.55;
        var nib = new PathFigure { StartPoint = new Point(_lineX - wStart * 0.78, sy), IsClosed = true, IsFilled = true };
        nib.Segments.Add(new BezierSegment
        {
            Point1 = new Point(_lineX - wStart * 0.78, sy + cr * 0.68),
            Point2 = new Point(_lineX + cr * 0.32, mid + wStart * 0.92),
            Point3 = new Point(_lineX + cr, mid + wStart * 0.72),
        });
        nib.Segments.Add(new QuadraticBezierSegment
        {
            Point1 = new Point(midTailX, mid + wStart * 0.52),
            Point2 = new Point(tipX, mid + tipR),
        });
        nib.Segments.Add(new ArcSegment
        {
            Point = new Point(tipX, mid - tipR),
            Size = new Size(tipR, tipR),
            SweepDirection = SweepDirection.Counterclockwise,
            IsLargeArc = false,
        });
        nib.Segments.Add(new QuadraticBezierSegment
        {
            Point1 = new Point(midTailX, mid - wStart * 0.52),
            Point2 = new Point(_lineX + cr, mid - wStart * 0.62),
        });
        nib.Segments.Add(new BezierSegment
        {
            Point1 = new Point(_lineX + cr * 0.45, mid - wStart * 0.64),
            Point2 = new Point(_lineX + wStart * 0.72, sy + cr * 0.55),
            Point3 = new Point(_lineX + wStart * 0.72, sy),
        });
        layer.Children.Add(FillPath(nib, shade));
    }

    private void DrawDots(double h, double mid, double fadeTop, Color waitingColor)
    {
        if (_more)
        {
            var stubEnd = Math.Max(0, mid - 6);
            if (!_first && stubEnd > 0)
            {
                _canvas.Children.Add(StrokePath(LineFigure(_lineX, 0, _lineX, stubEnd), Solid(_tint, 0.42), 1.5, PenLineCap.Flat, PenLineCap.Flat));
            }
            foreach (var (dy, op) in new[] { (-3.0, 0.55), (0.5, 0.38), (4.0, 0.22) })
            {
                AddCircle(_canvas, _lineX, mid + dy, 1.15, Solid(_tint, op), null, 0);
            }
            return;
        }

        var isSolid = _emphasized || _status is BotChatNodeStatus.Unread or BotChatNodeStatus.Waiting or BotChatNodeStatus.Working;
        var gapR = isSolid ? 5.0 : 4.2;
        var upperEnd = Math.Max(0, mid - gapR);
        if (upperEnd > 0)
        {
            _canvas.Children.Add(StrokePath(LineFigure(_lineX, 0, _lineX, upperEnd), TopFadeBrush(h, fadeTop, 0.44), 1.5, PenLineCap.Flat, PenLineCap.Flat));
        }
        if (!_last)
        {
            var lowerStart = Math.Min(h, mid + gapR);
            if (lowerStart < h)
            {
                _canvas.Children.Add(StrokePath(LineFigure(_lineX, lowerStart, _lineX, h), Solid(_tint, 0.44), 1.5, PenLineCap.Flat, PenLineCap.Flat));
            }
        }

        var nodeColor = _status == BotChatNodeStatus.Waiting ? waitingColor : _tint;
        if (isSolid)
        {
            AddCircle(_canvas, _lineX, mid, 3.2, Solid(nodeColor, _emphasized ? 1.0 : 0.94), null, 0);
        }
        else
        {
            AddCircle(_canvas, _lineX, mid, 3.2, null, Solid(_tint, 0.82), 1.6);
        }

        var cx = _lineX + _reach * 0.72;
        var tick = new PathFigure { StartPoint = new Point(cx - 2.1, mid - 2.5), IsClosed = false, IsFilled = false };
        tick.Segments.Add(new LineSegment { Point = new Point(cx + 0.9, mid) });
        tick.Segments.Add(new LineSegment { Point = new Point(cx - 2.1, mid + 2.5) });
        _canvas.Children.Add(StrokePath(tick, Solid(_tint, _emphasized ? 0.96 : 0.55), 1.35, PenLineCap.Round, PenLineCap.Round));
    }

    private void DrawRail(double h, double content, double mid)
    {
        var barTop = _first ? 3.0 : 0.0;
        var barBot = _last ? Math.Min(content, mid + 5.0) : h;
        if (barBot > barTop)
        {
            Brush barBrush;
            if (_last)
            {
                var grad = new LinearGradientBrush { StartPoint = new Point(0.5, 0), EndPoint = new Point(0.5, 1) };
                grad.GradientStops.Add(new GradientStop { Offset = 0, Color = WithAlpha(_tint, 0.46) });
                grad.GradientStops.Add(new GradientStop { Offset = 1, Color = WithAlpha(_tint, 0.18) });
                barBrush = grad;
            }
            else
            {
                barBrush = Solid(_tint, 0.46);
            }

            var bar = new Rectangle
            {
                Width = 2,
                Height = barBot - barTop,
                RadiusX = (_first || _last) ? 1 : 0,
                RadiusY = (_first || _last) ? 1 : 0,
                Fill = barBrush,
            };
            Canvas.SetLeft(bar, _lineX - 1);
            Canvas.SetTop(bar, barTop);
            _canvas.Children.Add(bar);
        }

        if (_emphasized)
        {
            var pillTop = Math.Max(barTop, mid - 7);
            var pill = new Rectangle
            {
                Width = 2.3,
                Height = Math.Min(14, content),
                RadiusX = 1.15,
                RadiusY = 1.15,
                Fill = Solid(_tint, 0.95),
            };
            Canvas.SetLeft(pill, _lineX - 1.15);
            Canvas.SetTop(pill, pillTop);
            _canvas.Children.Add(pill);
        }

        var gx = _lineX + Math.Max(4.2, Math.Min(5.5, _reach - 6.0));
        if (_more)
        {
            AddCircle(_canvas, gx + 2.8, mid, 1.3, Solid(_tint, 0.52), null, 0);
            return;
        }

        var op = _emphasized ? 0.98 : _status is BotChatNodeStatus.Unread or BotChatNodeStatus.Waiting or BotChatNodeStatus.Working ? 0.82 : 0.54;
        var layer = UnifiedLayer(op);
        var strokeBrush = Solid(_tint, 1.0);
        var stem = new PathFigure { StartPoint = new Point(gx, mid - 4.2), IsClosed = false, IsFilled = false };
        stem.Segments.Add(new LineSegment { Point = new Point(gx, mid - 1.5) });
        stem.Segments.Add(new QuadraticBezierSegment { Point1 = new Point(gx, mid + 0.6), Point2 = new Point(gx + 2.1, mid + 0.6) });
        stem.Segments.Add(new LineSegment { Point = new Point(gx + 6.0, mid + 0.6) });

        var head = new PathFigure { StartPoint = new Point(gx + 3.8, mid - 1.6), IsClosed = false, IsFilled = false };
        head.Segments.Add(new LineSegment { Point = new Point(gx + 6.3, mid + 0.6) });
        head.Segments.Add(new LineSegment { Point = new Point(gx + 3.8, mid + 2.8) });

        layer.Children.Add(StrokePath(stem, strokeBrush, 1.35, PenLineCap.Round, PenLineCap.Round));
        layer.Children.Add(StrokePath(head, strokeBrush, 1.35, PenLineCap.Round, PenLineCap.Round));
    }

    private void DrawPlainLine(double h, double content, double fadeTop)
    {
        var end = _last ? Math.Max(0, content - 7) : h;
        if (end <= 0) return;
        _canvas.Children.Add(StrokePath(
            LineFigure(_lineX, 0, _lineX, end),
            TopFadeBrush(end, fadeTop, _emphasized ? 0.88 : 0.58),
            DefaultStrokeWidth,
            PenLineCap.Flat,
            _last ? PenLineCap.Round : PenLineCap.Flat));
    }

    private Canvas UnifiedLayer(double opacity)
    {
        var layer = new Canvas { Opacity = opacity, IsHitTestVisible = false };
        _canvas.Children.Add(layer);
        return layer;
    }

    private Brush TopFadeBrush(double height, double fadeTop, double opacity)
    {
        if (!_first || height <= 0) return Solid(_tint, opacity);
        var stop = Math.Clamp(fadeTop / height, 0.05, 1.0);
        var grad = new LinearGradientBrush { StartPoint = new Point(0.5, 0), EndPoint = new Point(0.5, 1) };
        grad.GradientStops.Add(new GradientStop { Offset = 0.0, Color = WithAlpha(_tint, 0.0) });
        grad.GradientStops.Add(new GradientStop { Offset = stop, Color = WithAlpha(_tint, opacity) });
        grad.GradientStops.Add(new GradientStop { Offset = 1.0, Color = WithAlpha(_tint, opacity) });
        return grad;
    }

    private static PathFigure LineFigure(double x1, double y1, double x2, double y2)
    {
        var f = new PathFigure { StartPoint = new Point(x1, y1), IsClosed = false, IsFilled = false };
        f.Segments.Add(new LineSegment { Point = new Point(x2, y2) });
        return f;
    }

    private static XamlPath StrokePath(PathFigure figure, Brush stroke, double width, PenLineCap startCap, PenLineCap endCap) => new()
    {
        Stroke = stroke,
        StrokeThickness = width,
        StrokeStartLineCap = startCap,
        StrokeEndLineCap = endCap,
        StrokeLineJoin = PenLineJoin.Round,
        Data = new PathGeometry { Figures = { figure } },
    };

    private static XamlPath FillPath(PathFigure figure, Brush fill) => new()
    {
        Fill = fill,
        Data = new PathGeometry { Figures = { figure } },
    };

    private static void AddCircle(Canvas target, double cx, double cy, double radius, Brush? fill, Brush? stroke, double strokeWidth)
    {
        var ellipse = new Ellipse
        {
            Width = radius * 2,
            Height = radius * 2,
            Fill = fill,
            Stroke = stroke,
            StrokeThickness = strokeWidth,
        };
        Canvas.SetLeft(ellipse, cx - radius);
        Canvas.SetTop(ellipse, cy - radius);
        target.Children.Add(ellipse);
    }

    private static SolidColorBrush Solid(Color c, double opacity) => new(WithAlpha(c, opacity));

    private static Color WithAlpha(Color c, double opacity) =>
        Color.FromArgb((byte)Math.Round(Math.Clamp(opacity, 0, 1) * 255), c.R, c.G, c.B);
}
