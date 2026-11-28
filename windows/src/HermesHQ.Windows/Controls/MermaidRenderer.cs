using System.Globalization;
using Hermes.Core.Settings;
using Hermes.Core.Transcripts;
using HermesHQ.Features.Settings;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;
using XamlPath = Microsoft.UI.Xaml.Shapes.Path;

namespace HermesHQ.Controls;

// [mermaid] Native offline WinUI vector Canvas layout & renderer for Mermaid diagrams (flowchart, sequence, state, pie,
// and structured generic fallback). Port of App/Chat/Render/MermaidRenderer.swift without WebView2.
public static class MermaidRenderer
{
    public const double MaxNodeWidth = 220;
    public const double MaxNodeHeight = 150;
    public const double LabelInset = 8;
    public const int ArchTiers = 6;
    public const double ArchStep = 14;

    private sealed record Palette(
        Brush NodeFill,
        Brush NodeStroke,
        Brush SubgraphFill,
        Brush SubgraphStroke,
        Brush EdgeBrush,
        Brush TextBrush,
        Brush SecondaryTextBrush,
        Brush AccentBrush,
        Brush LabelPillFill,
        Brush PieSeparatorBrush,
        IReadOnlyList<Brush> SliceBrushes);

    private static Palette CurrentPalette()
    {
        var dark = ThemeService.Dark;
        var tokens = ThemeService.Tokens;
        var accentColor = ThemeService.ToColor(tokens.Tint);
        var sgFill = new SolidColorBrush(Color.FromArgb((byte)(dark ? 26 : 15), accentColor.R, accentColor.G, accentColor.B));
        var sgStroke = new SolidColorBrush(Color.FromArgb((byte)(dark ? 90 : 72), accentColor.R, accentColor.G, accentColor.B));
        var nodeFill = ThemeService.SystemHighContrast
            ? ThemeBrushes.Get("HQPageBrush")
            : new SolidColorBrush(dark ? Color.FromArgb(255, 43, 45, 50) : Colors.White);

        Brush[] slices =
        [
            ThemeBrushes.Get("HQTintBrush"),
            new SolidColorBrush(dark ? Color.FromArgb(255, 45, 212, 191) : Color.FromArgb(255, 13, 148, 136)),  // Teal
            new SolidColorBrush(dark ? Color.FromArgb(255, 251, 146, 60) : Color.FromArgb(255, 234, 88, 12)),   // Orange
            new SolidColorBrush(dark ? Color.FromArgb(255, 192, 132, 252) : Color.FromArgb(255, 147, 51, 234)), // Purple
            new SolidColorBrush(dark ? Color.FromArgb(255, 74, 222, 128) : Color.FromArgb(255, 22, 163, 74)),   // Green
            new SolidColorBrush(dark ? Color.FromArgb(255, 244, 114, 182) : Color.FromArgb(255, 219, 39, 119)), // Pink
            new SolidColorBrush(dark ? Color.FromArgb(255, 129, 140, 248) : Color.FromArgb(255, 79, 70, 229)),  // Indigo
        ];

        return new Palette(
            NodeFill: nodeFill,
            NodeStroke: ThemeBrushes.Get("HQSeparatorBrush"),
            SubgraphFill: sgFill,
            SubgraphStroke: sgStroke,
            EdgeBrush: ThemeBrushes.Get("HQLabel2Brush"),
            TextBrush: ThemeBrushes.Get("HQLabelBrush"),
            SecondaryTextBrush: ThemeBrushes.Get("HQLabel2Brush"),
            AccentBrush: ThemeBrushes.Get("HQTintBrush"),
            LabelPillFill: ThemeBrushes.Get("HQCodeFillBrush"),
            PieSeparatorBrush: ThemeBrushes.Get("HQCodeFillBrush"),
            SliceBrushes: slices);
    }

    /// Natural canvas size of the rendered diagram.
    public static Size NaturalSize(MermaidDiagram diagram) => diagram.Kind switch
    {
        MermaidKind.Flowchart f => ComputeFlowLayout(f.Direction, f.Nodes, f.Edges, f.Subgraphs).Size,
        MermaidKind.State s => ComputeFlowLayout(MermaidDirection.TopDown, s.Nodes, s.Edges, []).Size,
        MermaidKind.Sequence seq => ComputeSequenceLayout(seq.Participants, seq.Messages).Size,
        MermaidKind.Pie p => new Size(460, (string.IsNullOrEmpty(p.Title) ? 28 : 54) + Math.Max(200, Math.Max(1, p.Slices.Count) * 26 + 32)),
        MermaidKind.Generic g => new Size(420, 52 + Math.Max(1, g.Lines.Count) * 22 + 16),
        _ => new Size(240, 120),
    };

    /// Renders `diagram` into a native WinUI vector `Canvas` sized to its natural dimensions.
    public static Canvas RenderCanvas(MermaidDiagram diagram, bool solidBackground = false)
    {
        var palette = CurrentPalette();
        var natural = NaturalSize(diagram);
        var canvas = new Canvas
        {
            Width = natural.Width,
            Height = natural.Height,
            Background = solidBackground ? ThemeBrushes.Get("HQCodeFillBrush") : new SolidColorBrush(Colors.Transparent),
        };

        switch (diagram.Kind)
        {
            case MermaidKind.Flowchart f:
                DrawFlowchart(canvas, ComputeFlowLayout(f.Direction, f.Nodes, f.Edges, f.Subgraphs), f.Edges, palette);
                break;
            case MermaidKind.State s:
                DrawFlowchart(canvas, ComputeFlowLayout(MermaidDirection.TopDown, s.Nodes, s.Edges, []), s.Edges, palette);
                break;
            case MermaidKind.Sequence seq:
                DrawSequence(canvas, ComputeSequenceLayout(seq.Participants, seq.Messages), palette);
                break;
            case MermaidKind.Pie p:
                DrawPie(canvas, p.Title, p.ShowData, p.Slices, natural, palette);
                break;
            case MermaidKind.Generic g:
                DrawGeneric(canvas, g.Title, g.Lines, natural, palette);
                break;
        }
        return canvas;
    }

    // MARK: Text width estimation (fast, deterministic, off-layout)

    private static double EstimateLineWidth(string line, double fontSize)
    {
        double units = 0;
        foreach (var ch in line)
        {
            units += ch switch
            {
                ' ' or 'i' or 'l' or 'I' or '!' or '.' or ',' or ':' or ';' or '|' or '\'' or '`' => 0.34,
                'f' or 'j' or 'r' or 't' or '(' or ')' or '[' or ']' or '-' => 0.42,
                'm' or 'w' or 'M' or 'W' or '@' or '%' or '&' => 0.86,
                >= '\u2E80' => 1.0,
                _ => char.IsUpper(ch) ? 0.68 : 0.56,
            };
        }
        return Math.Ceiling(units * fontSize);
    }

    private static (double Width, double Height) EstimateWrappedText(string text, double fontSize, double maxWidth)
    {
        var lineH = Math.Ceiling(fontSize * 1.32);
        var paragraphs = text.Split('\n');
        double widest = 0;
        var totalLines = 0;
        foreach (var para in paragraphs)
        {
            var rawW = EstimateLineWidth(para, fontSize);
            if (rawW <= maxWidth || maxWidth <= 10)
            {
                widest = Math.Max(widest, rawW);
                totalLines += 1;
            }
            else
            {
                widest = maxWidth;
                totalLines += Math.Max(1, (int)Math.Ceiling(rawW / maxWidth));
            }
        }
        return (Math.Min(maxWidth, widest), Math.Max(lineH, totalLines * lineH));
    }

    // MARK: Flowchart / State layout & vector drawing

    private sealed record FlowLayout(
        Size Size,
        MermaidDirection Direction,
        Dictionary<string, Rect> NodeFrames,
        IReadOnlyList<MermaidFlowNode> Nodes,
        List<(string Title, Rect Frame)> SubgraphBoxes);

    private static FlowLayout ComputeFlowLayout(
        MermaidDirection direction,
        IReadOnlyList<MermaidFlowNode> nodes,
        IReadOnlyList<MermaidFlowEdge> edges,
        IReadOnlyList<MermaidFlowSubgraph> subgraphs)
    {
        if (nodes.Count == 0)
            return new FlowLayout(new Size(240, 120), direction, [], [], []);

        var rank = MermaidLayoutMath.FlowRanks(
            [.. nodes.Select(n => n.Id)],
            [.. edges.Select(e => (e.From, e.To))]);

        var maxRank = rank.Count > 0 ? rank.Values.Max() : 0;
        if (direction is MermaidDirection.BottomUp or MermaidDirection.RightLeft)
        {
            foreach (var k in rank.Keys.ToList())
                rank[k] = maxRank - rank[k];
        }
        maxRank = rank.Count > 0 ? rank.Values.Max() : 0;

        var layers = Enumerable.Range(0, maxRank + 1).Select(_ => new List<MermaidFlowNode>()).ToList();
        foreach (var n in nodes)
        {
            var r = Math.Clamp(rank.GetValueOrDefault(n.Id), 0, maxRank);
            layers[r].Add(n);
        }
        layers = OrderedLayers(layers, edges);

        var horizontal = direction is MermaidDirection.LeftRight or MermaidDirection.RightLeft;
        var arched = edges.Count(e =>
        {
            var r1 = rank.GetValueOrDefault(e.From);
            var r2 = rank.GetValueOrDefault(e.To);
            return Math.Abs(r2 - r1) != 1 || (direction is MermaidDirection.BottomUp or MermaidDirection.RightLeft ? r2 > r1 : r2 < r1);
        });
        var hasSkipEdge = arched > 0;
        var archRoom = 58.0 + Math.Max(0, Math.Min(arched, ArchTiers) - 1) * ArchStep;
        const double pad = 24;
        var rankGap = horizontal ? 50.0 : 44.0;
        const double peerGap = 22;

        static Size NodeSize(MermaidFlowNode n)
        {
            if (n.Shape == MermaidNodeShape.Circle && n.Label is "Start" or "End" or "●")
                return new Size(44, 44);
            var lines = n.Label.Split('\n');
            var maxLineW = lines.Length > 0 ? lines.Max(l => EstimateLineWidth(l, 13.5)) : 40;
            var sidePad = n.Shape == MermaidNodeShape.Diamond ? 42.0 : 28.0;
            var w = Math.Min(MaxNodeWidth, Math.Max(76, maxLineW + sidePad));
            var innerW = Math.Max(24, w - LabelInset * 2 - (n.Shape == MermaidNodeShape.Diamond ? 20 : 0));
            var (_, textH) = EstimateWrappedText(n.Label, 13.5, innerW);
            var h = Math.Min(MaxNodeHeight, Math.Max(38, textH + (n.Shape == MermaidNodeShape.Diamond ? 30 : 18)));
            return new Size(w, h);
        }

        var sizes = new Dictionary<string, Size>(StringComparer.Ordinal);
        foreach (var n in nodes) sizes[n.Id] = NodeSize(n);

        var gapAfter = Enumerable.Repeat(rankGap, layers.Count).ToArray();
        if (horizontal)
        {
            foreach (var e in edges)
            {
                if (string.IsNullOrEmpty(e.Label)) continue;
                if (!rank.TryGetValue(e.From, out var a) || !rank.TryGetValue(e.To, out var b)) continue;
                var lo = Math.Min(a, b);
                if (Math.Abs(a - b) == 1 && lo >= 0 && lo < gapAfter.Length)
                {
                    var wordsW = Math.Min(180, EstimateLineWidth(e.Label, 11));
                    gapAfter[lo] = Math.Max(gapAfter[lo], wordsW + 46);
                }
            }
        }

        var frames = new Dictionary<string, Rect>(StringComparer.Ordinal);
        if (horizontal)
        {
            var x = pad;
            var lastGap = rankGap;
            var topPad = hasSkipEdge ? archRoom : pad;
            var bottomPad = pad;
            var colHeights = layers.Select(layer =>
                layer.Sum(n => sizes.TryGetValue(n.Id, out var s) ? s.Height : 40) + Math.Max(0, layer.Count - 1) * peerGap).ToList();
            var contentH = colHeights.Count > 0 ? colHeights.Max() : 60;
            var totalH = contentH + topPad + bottomPad;

            for (var li = 0; li < layers.Count; li++)
            {
                var layer = layers[li];
                if (layer.Count == 0) continue;
                var colW = layer.Max(n => sizes.TryGetValue(n.Id, out var s) ? s.Width : 90);
                var y = topPad + (contentH - colHeights[li]) / 2;
                foreach (var n in layer)
                {
                    var s = sizes.TryGetValue(n.Id, out var sz) ? sz : new Size(90, 40);
                    frames[n.Id] = new Rect(x + (colW - s.Width) / 2, y, s.Width, s.Height);
                    y += s.Height + peerGap;
                }
                lastGap = gapAfter[li];
                x += colW + lastGap;
            }
            var totalW = Math.Max(240, x - lastGap + pad);
            var sgBoxes = ComputeSubgraphs(subgraphs, nodes, frames);
            return new FlowLayout(new Size(totalW, Math.Max(140, totalH)), direction, frames, nodes, sgBoxes);
        }
        else
        {
            var y = pad;
            var sidePad = hasSkipEdge ? archRoom : pad;
            var rowWidths = layers.Select(layer =>
                layer.Sum(n => sizes.TryGetValue(n.Id, out var s) ? s.Width : 90) + Math.Max(0, layer.Count - 1) * peerGap).ToList();
            var contentW = rowWidths.Count > 0 ? rowWidths.Max() : 200;
            var totalW = Math.Max(260, contentW + pad + sidePad);

            for (var li = 0; li < layers.Count; li++)
            {
                var layer = layers[li];
                if (layer.Count == 0) continue;
                var rowH = layer.Max(n => sizes.TryGetValue(n.Id, out var s) ? s.Height : 40);
                var x = pad + (contentW - rowWidths[li]) / 2;
                foreach (var n in layer)
                {
                    var s = sizes.TryGetValue(n.Id, out var sz) ? sz : new Size(90, 40);
                    frames[n.Id] = new Rect(x, y + (rowH - s.Height) / 2, s.Width, s.Height);
                    x += s.Width + peerGap;
                }
                y += rowH + rankGap;
            }
            var totalH = Math.Max(140, y - rankGap + pad);
            var sgBoxes = ComputeSubgraphs(subgraphs, nodes, frames);
            return new FlowLayout(new Size(totalW, totalH), direction, frames, nodes, sgBoxes);
        }
    }

    private static List<List<MermaidFlowNode>> OrderedLayers(List<List<MermaidFlowNode>> layers, IReadOnlyList<MermaidFlowEdge> edges)
    {
        if (layers.Count <= 1 || !layers.Any(l => l.Count > 1)) return layers;
        var neighbours = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var e in edges)
        {
            if (e.From == e.To) continue;
            if (!neighbours.TryGetValue(e.From, out var a)) neighbours[e.From] = a = [];
            if (!neighbours.TryGetValue(e.To, out var b)) neighbours[e.To] = b = [];
            a.Add(e.To);
            b.Add(e.From);
        }

        var slot = new Dictionary<string, double>(StringComparer.Ordinal);
        void Place(List<MermaidFlowNode> layer)
        {
            for (var i = 0; i < layer.Count; i++)
                slot[layer[i].Id] = layer.Count == 1 ? 0.5 : (double)i / (layer.Count - 1);
        }
        foreach (var l in layers) Place(l);

        void SortLayer(int index, int other)
        {
            var layer = layers[index];
            if (layer.Count <= 1 || other < 0 || other >= layers.Count) return;
            var fixedIds = layers[other].Select(n => n.Id).ToHashSet(StringComparer.Ordinal);
            var written = new Dictionary<string, int>(StringComparer.Ordinal);
            for (var i = 0; i < layer.Count; i++) written[layer[i].Id] = i;

            double Pull(MermaidFlowNode n)
            {
                if (!neighbours.TryGetValue(n.Id, out var nbrs)) return slot.GetValueOrDefault(n.Id, 0.5);
                var near = nbrs.Where(fixedIds.Contains).Select(id => slot.GetValueOrDefault(id, 0.5)).ToList();
                return near.Count == 0 ? slot.GetValueOrDefault(n.Id, 0.5) : near.Average();
            }

            var groups = new Dictionary<string, List<MermaidFlowNode>>(StringComparer.Ordinal);
            var groupOrder = new List<string>();
            foreach (var n in layer)
            {
                var key = n.Subgraph != null ? "sg|" + n.Subgraph : "n|" + n.Id;
                if (!groups.TryGetValue(key, out var g)) { groups[key] = g = []; groupOrder.Add(key); }
                g.Add(n);
            }

            var firstSeen = groupOrder.Select((k, idx) => (k, idx)).ToDictionary(x => x.k, x => x.idx, StringComparer.Ordinal);
            double Middle(string key) => groups[key].Average(Pull);

            groupOrder.Sort((a, b) =>
            {
                var cmp = Middle(a).CompareTo(Middle(b));
                return cmp != 0 ? cmp : firstSeen[a].CompareTo(firstSeen[b]);
            });

            var next = new List<MermaidFlowNode>(layer.Count);
            foreach (var key in groupOrder)
            {
                var g = groups[key];
                g.Sort((a, b) =>
                {
                    var cmp = Pull(a).CompareTo(Pull(b));
                    return cmp != 0 ? cmp : written[a.Id].CompareTo(written[b.Id]);
                });
                next.AddRange(g);
            }
            layers[index] = next;
            Place(next);
        }

        for (var pass = 0; pass < 2; pass++)
        {
            for (var i = 1; i < layers.Count; i++) SortLayer(i, i - 1);
            for (var i = layers.Count - 2; i >= 0; i--) SortLayer(i, i + 1);
        }
        return layers;
    }

    private static List<(string Title, Rect Frame)> ComputeSubgraphs(
        IReadOnlyList<MermaidFlowSubgraph> subgraphs,
        IReadOnlyList<MermaidFlowNode> nodes,
        Dictionary<string, Rect> frames)
    {
        var output = new List<(string, Rect)>();
        foreach (var sg in subgraphs)
        {
            var rects = nodes.Where(n => n.Subgraph == sg.Id && frames.ContainsKey(n.Id)).Select(n => frames[n.Id]).ToList();
            if (rects.Count == 0) continue;
            var minX = rects.Min(r => r.Left) - 12;
            var minY = rects.Min(r => r.Top) - 22;
            var maxX = rects.Max(r => r.Right) + 12;
            var maxY = rects.Max(r => r.Bottom) + 14;
            output.Add((sg.Title, new Rect(minX, minY, Math.Max(40, maxX - minX), Math.Max(40, maxY - minY))));
        }
        return output;
    }

    private static void DrawFlowchart(Canvas canvas, FlowLayout layout, IReadOnlyList<MermaidFlowEdge> edges, Palette palette)
    {
        // 1. Subgraphs behind edges and nodes
        foreach (var (title, frame) in layout.SubgraphBoxes)
        {
            var rect = new Rectangle
            {
                Width = frame.Width,
                Height = frame.Height,
                RadiusX = 12,
                RadiusY = 12,
                Fill = palette.SubgraphFill,
                Stroke = palette.SubgraphStroke,
                StrokeThickness = 1.25,
                StrokeDashArray = [4, 3],
            };
            Canvas.SetLeft(rect, frame.Left);
            Canvas.SetTop(rect, frame.Top);
            canvas.Children.Add(rect);

            var tb = new TextBlock
            {
                Text = title,
                FontSize = 11,
                FontWeight = FontWeights.SemiBold,
                Foreground = palette.AccentBrush,
                MaxWidth = Math.Max(40, frame.Width - 20),
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            Canvas.SetLeft(tb, frame.Left + 10);
            Canvas.SetTop(tb, frame.Top + 4);
            canvas.Children.Add(tb);
        }

        // 2. Edges
        var horizontal = layout.Direction is MermaidDirection.LeftRight or MermaidDirection.RightLeft;
        var bypassIndex = 0;
        var drawnPairs = new HashSet<(string, string)>();

        foreach (var edge in edges)
        {
            if (!layout.NodeFrames.TryGetValue(edge.From, out var fromRect) || !layout.NodeFrames.TryGetValue(edge.To, out var toRect))
                continue;

            if (edge.From == edge.To)
            {
                DrawSelfLoop(canvas, edge, fromRect, horizontal, palette);
                continue;
            }

            var (start, end) = EdgeEndpoints(fromRect, toRect, horizontal);
            var against = layout.Direction switch
            {
                MermaidDirection.TopDown => MidY(toRect) < MidY(fromRect),
                MermaidDirection.BottomUp => MidY(toRect) > MidY(fromRect),
                MermaidDirection.LeftRight => MidX(toRect) < MidX(fromRect),
                MermaidDirection.RightLeft => MidX(toRect) > MidX(fromRect),
                _ => false,
            };
            var returning = drawnPairs.Contains((edge.To, edge.From));
            drawnPairs.Add((edge.From, edge.To));

            var lineBox = new Rect(
                Math.Min(start.X, end.X) - 2,
                Math.Min(start.Y, end.Y) - 2,
                Math.Abs(end.X - start.X) + 4,
                Math.Abs(end.Y - start.Y) + 4);

            Rect? obstacle = null;
            foreach (var (otherId, rect) in layout.NodeFrames)
            {
                if (otherId == edge.From || otherId == edge.To) continue;
                var padded = new Rect(rect.Left - 4, rect.Top - 4, rect.Width + 8, rect.Height + 8);
                if (Intersects(padded, lineBox))
                    obstacle = obstacle is { } o ? Union(o, rect) : rect;
            }
            if ((against || returning) && obstacle == null)
                obstacle = Union(fromRect, toRect);

            var figure = new PathFigure { IsClosed = false, IsFilled = false };
            Point labelPoint;
            Point tangentFrom;

            if (obstacle is { } obs)
            {
                var tier = (bypassIndex % ArchTiers) * ArchStep;
                bypassIndex++;
                if (horizontal)
                {
                    start = new Point(MidX(fromRect), fromRect.Top);
                    end = new Point(MidX(toRect), toRect.Top);
                    var archY = Math.Min(Math.Min(start.Y, end.Y), obs.Top) - 42 - tier;
                    var ctrl = new Point((start.X + end.X) / 2, archY);
                    figure.StartPoint = start;
                    figure.Segments.Add(new QuadraticBezierSegment { Point1 = ctrl, Point2 = end });
                    labelPoint = new Point(0.25 * start.X + 0.5 * ctrl.X + 0.25 * end.X, 0.25 * start.Y + 0.5 * ctrl.Y + 0.25 * end.Y);
                    tangentFrom = ctrl;
                }
                else
                {
                    start = new Point(fromRect.Right, MidY(fromRect));
                    end = new Point(toRect.Right, MidY(toRect));
                    var archX = Math.Max(Math.Max(start.X, end.X), obs.Right) + 44 + tier;
                    var ctrl = new Point(archX, (start.Y + end.Y) / 2);
                    figure.StartPoint = start;
                    figure.Segments.Add(new QuadraticBezierSegment { Point1 = ctrl, Point2 = end });
                    labelPoint = new Point(0.25 * start.X + 0.5 * ctrl.X + 0.25 * end.X, 0.25 * start.Y + 0.5 * ctrl.Y + 0.25 * end.Y);
                    tangentFrom = ctrl;
                }
            }
            else
            {
                var mid = new Point((start.X + end.X) / 2, (start.Y + end.Y) / 2);
                figure.StartPoint = start;
                if (horizontal)
                {
                    var c1 = new Point(mid.X, start.Y);
                    var c2 = new Point(mid.X, end.Y);
                    figure.Segments.Add(new BezierSegment { Point1 = c1, Point2 = c2, Point3 = end });
                    tangentFrom = c2;
                }
                else
                {
                    var c1 = new Point(start.X, mid.Y);
                    var c2 = new Point(end.X, mid.Y);
                    figure.Segments.Add(new BezierSegment { Point1 = c1, Point2 = c2, Point3 = end });
                    tangentFrom = c2;
                }
                labelPoint = mid;
            }

            var path = new XamlPath
            {
                Stroke = palette.EdgeBrush,
                StrokeThickness = edge.Style == MermaidEdgeStyle.Thick ? 2.5 : 1.5,
                Data = new PathGeometry { Figures = { figure } },
            };
            if (edge.Style == MermaidEdgeStyle.Dashed)
                path.StrokeDashArray = [5, 4];
            canvas.Children.Add(path);

            if (edge.Directed)
            {
                var fromPt = Math.Abs(tangentFrom.X - end.X) < 0.1 && Math.Abs(tangentFrom.Y - end.Y) < 0.1 ? start : tangentFrom;
                DrawArrowHead(canvas, end, fromPt, palette.EdgeBrush);
            }
            if (!string.IsNullOrEmpty(edge.Label))
                DrawEdgeLabel(canvas, edge.Label, labelPoint, palette);
        }

        // 3. Nodes
        foreach (var node in layout.Nodes)
        {
            if (!layout.NodeFrames.TryGetValue(node.Id, out var frame)) continue;
            var accentBorder = node.Shape is MermaidNodeShape.Diamond or MermaidNodeShape.Circle;
            var stroke = accentBorder ? palette.AccentBrush : palette.NodeStroke;
            var strokeW = accentBorder ? 1.6 : 1.25;

            var shape = BuildNodeShape(node.Shape, frame, palette.NodeFill, stroke, strokeW);
            Canvas.SetLeft(shape, frame.Left);
            Canvas.SetTop(shape, frame.Top);
            canvas.Children.Add(shape);

            var insetX = LabelInset + (node.Shape == MermaidNodeShape.Diamond ? 10 : 0);
            var textHost = new Grid
            {
                Width = Math.Max(16, frame.Width - insetX * 2),
                Height = Math.Max(16, frame.Height - 8),
            };
            textHost.Children.Add(new TextBlock
            {
                Text = node.Label,
                FontSize = 13,
                FontWeight = FontWeights.Medium,
                Foreground = palette.TextBrush,
                TextAlignment = TextAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
            });
            Canvas.SetLeft(textHost, frame.Left + insetX);
            Canvas.SetTop(textHost, frame.Top + 4);
            canvas.Children.Add(textHost);
        }
    }

    private static void DrawSelfLoop(Canvas canvas, MermaidFlowEdge edge, Rect r, bool horizontal, Palette palette)
    {
        Point start, end, c1, c2, labelPoint;
        if (horizontal)
        {
            start = new Point(MidX(r) - 10, r.Top);
            end = new Point(MidX(r) + 10, r.Top);
            c1 = new Point(MidX(r) - 28, r.Top - 34);
            c2 = new Point(MidX(r) + 28, r.Top - 34);
            labelPoint = new Point(MidX(r), r.Top - 32);
        }
        else
        {
            start = new Point(r.Right, MidY(r) - 8);
            end = new Point(r.Right, MidY(r) + 8);
            c1 = new Point(r.Right + 34, MidY(r) - 26);
            c2 = new Point(r.Right + 34, MidY(r) + 26);
            labelPoint = new Point(r.Right + 30, MidY(r));
        }

        var fig = new PathFigure { StartPoint = start, IsClosed = false, IsFilled = false };
        fig.Segments.Add(new BezierSegment { Point1 = c1, Point2 = c2, Point3 = end });
        var path = new XamlPath
        {
            Stroke = palette.EdgeBrush,
            StrokeThickness = edge.Style == MermaidEdgeStyle.Thick ? 2.5 : 1.5,
            Data = new PathGeometry { Figures = { fig } },
        };
        if (edge.Style == MermaidEdgeStyle.Dashed) path.StrokeDashArray = [5, 4];
        canvas.Children.Add(path);

        if (edge.Directed) DrawArrowHead(canvas, end, c2, palette.EdgeBrush);
        if (!string.IsNullOrEmpty(edge.Label)) DrawEdgeLabel(canvas, edge.Label, labelPoint, palette);
    }

    private static void DrawEdgeLabel(Canvas canvas, string label, Point point, Palette palette)
    {
        var estW = Math.Min(180, EstimateLineWidth(label, 11));
        var pillW = estW + 12;
        const double pillH = 20;
        var pill = new Border
        {
            Background = palette.LabelPillFill,
            CornerRadius = new CornerRadius(5),
            Padding = new Thickness(5, 2, 5, 2),
            MaxWidth = 192,
            Child = new TextBlock
            {
                Text = label,
                FontSize = 11,
                FontWeight = FontWeights.Medium,
                Foreground = palette.SecondaryTextBrush,
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 1,
            },
        };
        Canvas.SetLeft(pill, point.X - pillW / 2);
        Canvas.SetTop(pill, point.Y - pillH / 2);
        canvas.Children.Add(pill);
    }

    private static Shape BuildNodeShape(MermaidNodeShape shape, Rect frame, Brush fill, Brush stroke, double strokeThickness)
    {
        var w = frame.Width;
        var h = frame.Height;
        switch (shape)
        {
            case MermaidNodeShape.Circle:
                return new Ellipse { Width = w, Height = h, Fill = fill, Stroke = stroke, StrokeThickness = strokeThickness };
            case MermaidNodeShape.Diamond:
                return new Polygon
                {
                    Fill = fill, Stroke = stroke, StrokeThickness = strokeThickness,
                    Points = [new Point(w / 2, 0), new Point(w, h / 2), new Point(w / 2, h), new Point(0, h / 2)],
                };
            case MermaidNodeShape.Hexagon:
                var dx = Math.Min(14, w * 0.16);
                return new Polygon
                {
                    Fill = fill, Stroke = stroke, StrokeThickness = strokeThickness,
                    Points = [new Point(dx, 0), new Point(w - dx, 0), new Point(w, h / 2), new Point(w - dx, h), new Point(dx, h), new Point(0, h / 2)],
                };
            case MermaidNodeShape.Stadium:
                return new Rectangle { Width = w, Height = h, RadiusX = h / 2, RadiusY = h / 2, Fill = fill, Stroke = stroke, StrokeThickness = strokeThickness };
            case MermaidNodeShape.Cylinder:
                var cr = Math.Min(16, h * 0.35);
                return new Rectangle { Width = w, Height = h, RadiusX = cr, RadiusY = cr, Fill = fill, Stroke = stroke, StrokeThickness = strokeThickness };
            case MermaidNodeShape.Rounded:
                return new Rectangle { Width = w, Height = h, RadiusX = 12, RadiusY = 12, Fill = fill, Stroke = stroke, StrokeThickness = strokeThickness };
            default:
                return new Rectangle { Width = w, Height = h, RadiusX = 6, RadiusY = 6, Fill = fill, Stroke = stroke, StrokeThickness = strokeThickness };
        }
    }

    private static void DrawArrowHead(Canvas canvas, Point tip, Point tail, Brush brush, bool open = false)
    {
        var angle = Math.Atan2(tip.Y - tail.Y, tip.X - tail.X);
        const double len = 8;
        const double spread = Math.PI / 6;
        var p1 = new Point(tip.X - len * Math.Cos(angle - spread), tip.Y - len * Math.Sin(angle - spread));
        var p2 = new Point(tip.X - len * Math.Cos(angle + spread), tip.Y - len * Math.Sin(angle + spread));
        if (open)
        {
            canvas.Children.Add(new Polyline
            {
                Stroke = brush,
                StrokeThickness = 1.5,
                Points = [p1, tip, p2],
            });
        }
        else
        {
            canvas.Children.Add(new Polygon
            {
                Fill = brush,
                Points = [tip, p1, p2],
            });
        }
    }

    private static (Point Start, Point End) EdgeEndpoints(Rect a, Rect b, bool horizontal)
    {
        if (horizontal)
        {
            return MidX(b) >= MidX(a)
                ? (new Point(a.Right, MidY(a)), new Point(b.Left, MidY(b)))
                : (new Point(a.Left, MidY(a)), new Point(b.Right, MidY(b)));
        }
        return MidY(b) >= MidY(a)
            ? (new Point(MidX(a), a.Bottom), new Point(MidX(b), b.Top))
            : (new Point(MidX(a), a.Top), new Point(MidX(b), b.Bottom));
    }

    // MARK: Sequence Diagram

    private sealed record SequenceLayout(
        Size Size,
        IReadOnlyList<string> Participants,
        Dictionary<string, double> XForParticipant,
        IReadOnlyList<MermaidSequenceMessage> Messages,
        double HeaderHeight,
        double RowHeight,
        double ColumnSpacing);

    private static SequenceLayout ComputeSequenceLayout(IReadOnlyList<string> participants, IReadOnlyList<MermaidSequenceMessage> messages)
    {
        const double pad = 24;
        const double headerH = 34;
        const double rowH = 42;
        var place = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var i = 0; i < participants.Count; i++) place[participants[i]] = i;

        double widest = 0;
        foreach (var m in messages)
        {
            if (string.IsNullOrEmpty(m.Text)) continue;
            if (!place.TryGetValue(m.From, out var a) || !place.TryGetValue(m.To, out var b)) continue;
            var span = Math.Max(1, Math.Abs(a - b));
            widest = Math.Max(widest, EstimateLineWidth(m.Text, 11) / span);
        }

        var colSpacing = Math.Min(250, Math.Max(136, widest + 28));
        var map = new Dictionary<string, double>(StringComparer.Ordinal);
        for (var i = 0; i < participants.Count; i++)
            map[participants[i]] = pad + colSpacing / 2 + i * colSpacing;

        var w = Math.Max(280, pad * 2 + Math.Max(1, participants.Count) * colSpacing);
        var h = pad * 2 + headerH + 20 + Math.Max(1, messages.Count) * rowH + 16;
        return new SequenceLayout(new Size(w, h), participants, map, messages, headerH, rowH, colSpacing);
    }

    private static void DrawSequence(Canvas canvas, SequenceLayout layout, Palette palette)
    {
        const double pad = 24;
        var topY = pad;
        var bottomY = layout.Size.Height - pad;

        foreach (var name in layout.Participants)
        {
            if (!layout.XForParticipant.TryGetValue(name, out var cx)) continue;

            canvas.Children.Add(new Line
            {
                X1 = cx, Y1 = topY + layout.HeaderHeight,
                X2 = cx, Y2 = bottomY,
                Stroke = palette.NodeStroke,
                StrokeThickness = 1.25,
                StrokeDashArray = [4, 4],
            });

            var boxW = Math.Min(layout.ColumnSpacing - 14, Math.Max(108, EstimateLineWidth(name, 12) + 22));
            var headerBox = new Border
            {
                Width = boxW,
                Height = layout.HeaderHeight,
                CornerRadius = new CornerRadius(8),
                Background = palette.NodeFill,
                BorderBrush = palette.AccentBrush,
                BorderThickness = new Thickness(1.4),
                Padding = new Thickness(6, 0, 6, 0),
                Child = new TextBlock
                {
                    Text = name,
                    FontSize = 12,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = palette.TextBrush,
                    TextAlignment = TextAlignment.Center,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    VerticalAlignment = VerticalAlignment.Center,
                    MaxLines = 1,
                },
            };
            Canvas.SetLeft(headerBox, cx - boxW / 2);
            Canvas.SetTop(headerBox, topY);
            canvas.Children.Add(headerBox);
        }

        for (var i = 0; i < layout.Messages.Count; i++)
        {
            var msg = layout.Messages[i];
            if (!layout.XForParticipant.TryGetValue(msg.From, out var x1) || !layout.XForParticipant.TryGetValue(msg.To, out var x2))
                continue;
            var y = topY + layout.HeaderHeight + 28 + i * layout.RowHeight;
            var own = Math.Abs(x1 - x2) < 1;

            if (own)
            {
                const double loopW = 30;
                const double loopH = 18;
                var loop = new Polyline
                {
                    Stroke = palette.EdgeBrush,
                    StrokeThickness = 1.5,
                    Points =
                    [
                        new Point(x1, y - 6),
                        new Point(x1 + loopW, y - 6),
                        new Point(x1 + loopW, y + loopH - 6),
                        new Point(x1, y + loopH - 6),
                    ],
                };
                if (msg.Dashed) loop.StrokeDashArray = [5, 3];
                canvas.Children.Add(loop);
                DrawArrowHead(canvas, new Point(x1, y + loopH - 6), new Point(x1 + loopW, y + loopH - 6), palette.EdgeBrush, msg.OpenArrow);
            }
            else
            {
                var line = new Line
                {
                    X1 = x1, Y1 = y, X2 = x2, Y2 = y,
                    Stroke = palette.EdgeBrush,
                    StrokeThickness = 1.5,
                };
                if (msg.Dashed) line.StrokeDashArray = [5, 3];
                canvas.Children.Add(line);
                DrawArrowHead(canvas, new Point(x2, y), new Point(x1, y), palette.EdgeBrush, msg.OpenArrow);
            }

            if (!string.IsNullOrEmpty(msg.Text))
            {
                var roomX = own ? x1 + 36 : Math.Min(x1, x2) + 8;
                var roomW = own
                    ? Math.Max(40, Math.Min(layout.ColumnSpacing, layout.Size.Width - x1 - 8) - 44)
                    : Math.Max(40, Math.Abs(x1 - x2) - 16);
                var roomY = own ? y - 10 : y - 18;
                var label = new TextBlock
                {
                    Text = msg.Text,
                    Width = roomW,
                    FontSize = 11,
                    FontWeight = FontWeights.Medium,
                    Foreground = palette.TextBrush,
                    TextAlignment = own ? TextAlignment.Left : TextAlignment.Center,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    MaxLines = 1,
                };
                Canvas.SetLeft(label, roomX);
                Canvas.SetTop(label, roomY);
                canvas.Children.Add(label);
            }
        }
    }

    // MARK: Pie Chart

    private static void DrawPie(Canvas canvas, string title, bool showData, IReadOnlyList<MermaidPieSlice> slices, Size size, Palette palette)
    {
        var total = slices.Sum(s => s.Value);
        if (total <= 0 || !double.IsFinite(total)) return;

        var top = 18.0;
        if (!string.IsNullOrEmpty(title))
        {
            var titleTb = new TextBlock
            {
                Text = title,
                FontSize = 14,
                FontWeight = FontWeights.SemiBold,
                Foreground = palette.TextBrush,
                MaxWidth = size.Width - 40,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            Canvas.SetLeft(titleTb, 20);
            Canvas.SetTop(titleTb, top);
            canvas.Children.Add(titleTb);
            top += 28;
        }

        const double radius = 78;
        var center = new Point(24 + radius, top + radius + 10);
        var startAngle = -Math.PI / 2;

        for (var i = 0; i < slices.Count; i++)
        {
            var slice = slices[i];
            var sweep = (slice.Value / total) * Math.PI * 2;
            var endAngle = startAngle + sweep;
            var brush = palette.SliceBrushes[i % palette.SliceBrushes.Count];

            if (slices.Count == 1 || sweep >= Math.PI * 2 - 0.001)
            {
                var full = new Ellipse
                {
                    Width = radius * 2,
                    Height = radius * 2,
                    Fill = brush,
                    Stroke = palette.PieSeparatorBrush,
                    StrokeThickness = 1.5,
                };
                Canvas.SetLeft(full, center.X - radius);
                Canvas.SetTop(full, center.Y - radius);
                canvas.Children.Add(full);
            }
            else if (sweep > 0.0005)
            {
                var p1 = new Point(center.X + radius * Math.Cos(startAngle), center.Y + radius * Math.Sin(startAngle));
                var p2 = new Point(center.X + radius * Math.Cos(endAngle), center.Y + radius * Math.Sin(endAngle));
                var fig = new PathFigure { StartPoint = center, IsClosed = true, IsFilled = true };
                fig.Segments.Add(new LineSegment { Point = p1 });
                fig.Segments.Add(new ArcSegment
                {
                    Point = p2,
                    Size = new Size(radius, radius),
                    IsLargeArc = sweep > Math.PI,
                    SweepDirection = SweepDirection.Clockwise,
                });
                canvas.Children.Add(new XamlPath
                {
                    Fill = brush,
                    Stroke = palette.PieSeparatorBrush,
                    StrokeThickness = 1.5,
                    Data = new PathGeometry { Figures = { fig } },
                });
            }
            startAngle = endAngle;
        }

        var legendX = center.X + radius + 28;
        var ly = top + 14;
        for (var i = 0; i < slices.Count; i++)
        {
            var slice = slices[i];
            var swatch = new Rectangle
            {
                Width = 12,
                Height = 12,
                RadiusX = 3,
                RadiusY = 3,
                Fill = palette.SliceBrushes[i % palette.SliceBrushes.Count],
            };
            Canvas.SetLeft(swatch, legendX);
            Canvas.SetTop(swatch, ly + 2);
            canvas.Children.Add(swatch);

            var share = slice.Value / total;
            var pct = double.IsFinite(share) ? (int)Math.Round(share * 100, MidpointRounding.AwayFromZero) : 0;
            var suffix = showData ? $" ({FormatNumber(slice.Value)} · {pct}%)" : $" ({pct}%)";
            var labelTb = new TextBlock
            {
                Text = slice.Label + suffix,
                FontSize = 12,
                FontWeight = FontWeights.Medium,
                Foreground = palette.TextBrush,
                MaxWidth = Math.Max(60, size.Width - legendX - 30),
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 1,
            };
            Canvas.SetLeft(labelTb, legendX + 18);
            Canvas.SetTop(labelTb, ly);
            canvas.Children.Add(labelTb);
            ly += 24;
        }
    }

    private static string FormatNumber(double value) =>
        Math.Abs(Math.Round(value) - value) < 1e-9 && Math.Abs(value) < 1e15
            ? ((long)Math.Round(value)).ToString(CultureInfo.InvariantCulture)
            : value.ToString("0.0", CultureInfo.InvariantCulture);

    // MARK: Generic structured fallback

    private static void DrawGeneric(Canvas canvas, string title, IReadOnlyList<string> lines, Size size, Palette palette)
    {
        var titleTb = new TextBlock
        {
            Text = string.IsNullOrEmpty(title) ? "Mermaid Diagram" : title,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Foreground = palette.AccentBrush,
        };
        Canvas.SetLeft(titleTb, 18);
        Canvas.SetTop(titleTb, 16);
        canvas.Children.Add(titleTb);

        var codeFont = Application.Current.Resources.TryGetValue("CodeFont", out var f) && f is FontFamily ff
            ? ff
            : new FontFamily("Consolas");

        var y = 42.0;
        foreach (var line in lines)
        {
            var tb = new TextBlock
            {
                Text = line,
                FontFamily = codeFont,
                FontSize = 12,
                Foreground = palette.TextBrush,
                MaxWidth = Math.Max(60, size.Width - 32),
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 1,
            };
            Canvas.SetLeft(tb, 16);
            Canvas.SetTop(tb, y);
            canvas.Children.Add(tb);
            y += 22;
        }
    }

    private static double MidX(Rect r) => r.Left + r.Width / 2;
    private static double MidY(Rect r) => r.Top + r.Height / 2;

    private static bool Intersects(Rect a, Rect b) =>
        a.Left < b.Right && b.Left < a.Right && a.Top < b.Bottom && b.Top < a.Bottom;

    private static Rect Union(Rect a, Rect b)
    {
        var left = Math.Min(a.Left, b.Left);
        var top = Math.Min(a.Top, b.Top);
        var right = Math.Max(a.Right, b.Right);
        var bottom = Math.Max(a.Bottom, b.Bottom);
        return new Rect(left, top, right - left, bottom - top);
    }
}
