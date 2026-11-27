using Hermes.Core.Settings;
using HermesHQ.Features.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace HermesHQ.Controls;

/// One message in the readable column. Measure against the current row slot, not window width
/// or last frame's ActualWidth: opening the inspector or dragging the sidebar can re-wrap it.
internal sealed partial class ChatBubbleLane : Panel
{
    private readonly bool _mine, _table, _tool;
    public ChatBubbleLane(FrameworkElement bubble, bool mine, bool joined, bool table = false, bool tool = false)
    {
        (_mine, _table, _tool) = (mine, table, tool);
        Margin = new Thickness(ChatVisualTokens.Side, joined ? ChatVisualTokens.RunGap : ChatVisualTokens.TurnGap, ChatVisualTokens.Side, 0);
        Children.Add(bubble);
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        var width = Math.Min(availableSize.Width, ChatVisualTokens.Column - 2 * ChatVisualTokens.Side);
        var cap = ChatVisualTokens.BubbleWidth(width, _mine, _mine && ThemeService.AccessibilityTextSize, _table);
        Children[0].Measure(new Size(cap, availableSize.Height));
        return new Size(width, Children[0].DesiredSize.Height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var child = Children[0];
        // ActivityRows.toolBubble lays even a short step's clock against the full reply cap.
        var w = Math.Min(finalSize.Width, _tool ? ChatVisualTokens.BubbleMax : child.DesiredSize.Width);
        child.Arrange(new Rect(_mine ? finalSize.Width - w : 0, 0, w, finalSize.Height));
        return finalSize;
    }

    // ChatGlyphs.swift:257–285. The tail grows out of the last bubble of the run, even when its
    // clock is quiet. It sits in the side inset without changing the wrapping width or the hit target.
    internal static FrameworkElement Face(Border box, bool mine, bool tail, string? time, bool prose)
    {
        var outline = Outline(box, mine, tail);
        if (time == null) return outline;
        var clock = new TextBlock
        {
            Text = time, FontSize = ChatVisualTokens.Type(ThemeService.State.DesktopLook).Caption2.Size,
            Foreground = ThemeBrushes.Get(mine ? "HQMeTimeBrush" : "HQLabel2Brush"),
        };
        if (mine) ThemeService.ContrastWords(clock);
        // The body stays at the top if the clock needs a line of its own. The clock isn't part of
        // the selectable/searchable words; resizing only measures the existing elements again.
        if (box.Child is FrameworkElement content)
        {
            content.VerticalAlignment = VerticalAlignment.Top;
            // Keep measured prose out of the clock's reserved column, including right-to-left words.
            content.HorizontalAlignment = HorizontalAlignment.Left;
        }
        return new ClockPanel(outline, clock, prose,
            ChatVisualTokens.ClockInset(ThemeService.State.AppliedBubbleCorners, mine && tail && !ThemeService.State.DesktopLook));
    }

    private sealed partial class ClockPanel : Panel
    {
        private readonly bool _prose;
        private readonly double _shift;
        public ClockPanel(FrameworkElement outline, TextBlock clock, bool prose, double shift)
        {
            (_prose, _shift) = (prose, shift);
            Children.Add(outline);
            Children.Add(clock);
        }

        protected override Size MeasureOverride(Size room)
        {
            var face = Children[0]; var clock = Children[1];
            face.Measure(room);
            clock.Measure(new Size(Math.Max(0, room.Width - 2 * ChatVisualTokens.TimeTrailing), double.PositiveInfinity));
            var body = face.DesiredSize; var time = clock.DesiredSize;
            var inline = body.Width + ChatVisualTokens.TimeGap + time.Width + _shift;
            if (_prose && inline <= room.Width) return new Size(inline, Math.Max(body.Height, time.Height + 2 * (ChatVisualTokens.TimeBottom + _shift)));
            // Conservative for a wrapped last line: don't draw a time over a glyph, a link or a table.
            return new Size(Math.Min(room.Width, Math.Max(body.Width, time.Width + 2 * (ChatVisualTokens.TimeTrailing + _shift))),
                body.Height + time.Height + ChatVisualTokens.TimeBottom + _shift);
        }

        protected override Size ArrangeOverride(Size size)
        {
            Children[0].Arrange(new Rect(0, 0, size.Width, size.Height));
            var time = Children[1].DesiredSize;
            Children[1].Arrange(new Rect(Math.Max(0, size.Width - time.Width - ChatVisualTokens.TimeTrailing - _shift),
                Math.Max(0, size.Height - time.Height - ChatVisualTokens.TimeBottom - _shift), time.Width, time.Height));
            return size;
        }
    }

    private static FrameworkElement Outline(Border box, bool mine, bool tail)
    {
        if (!tail || ThemeService.State.DesktopLook) return box;
        var r = box.CornerRadius.TopLeft;
        box.CornerRadius = new CornerRadius(r, r, mine ? 0 : r, mine ? r : 0);
        const double w = ChatVisualTokens.TailWidth, h = ChatVisualTokens.TailHeight, overlap = ChatVisualTokens.TailOverlap;
        Point P(double x, double y) => new(mine ? x * ChatVisualTokens.Dip : w - x * ChatVisualTokens.Dip, y * ChatVisualTokens.Dip);
        // Fill closes implicitly. Leave the incoming edge open where the tail meets the box:
        // Window on Window needs the outline, but not a line across the root of its own tail.
        var figure = new PathFigure { StartPoint = P(0, 4), IsClosed = mine, IsFilled = true };
        figure.Segments.Add(new LineSegment { Point = P(1, 4) });
        figure.Segments.Add(new BezierSegment { Point1 = P(1, 10.5), Point2 = P(3, 15.2), Point3 = P(8, 17) });
        figure.Segments.Add(new LineSegment { Point = P(0, 17) });
        var path = new Microsoft.UI.Xaml.Shapes.Path
        {
            Width = w, Height = h, Fill = box.Background, Stretch = Stretch.None, Data = new PathGeometry { Figures = { figure } },
            Stroke = mine ? null : box.BorderBrush, StrokeThickness = mine ? 0 : box.BorderThickness.Left,
            HorizontalAlignment = mine ? HorizontalAlignment.Right : HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(mine ? 0 : overlap - w, 0, mine ? overlap - w : 0, 0), IsHitTestVisible = false,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(path, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return new Grid { Children = { box, path } };
    }
}
