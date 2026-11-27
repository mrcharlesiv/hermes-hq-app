// Recording sinks. Ownership, brush selection, geometry arguments and event handlers come from
// the linked renderer. This is not a model of Windows text measurement, pixels or accessibility.
using Hermes.Core.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Windows.Foundation
{
    internal record struct Size(double Width, double Height);
    internal record struct Rect(double X, double Y, double Width, double Height);
    internal record struct Point(double X, double Y);
}
namespace Windows.UI.Text { internal struct FontWeight { public ushort Weight { get; set; } } }
namespace Microsoft.UI.Text
{
    internal static class FontWeights { public static Windows.UI.Text.FontWeight SemiBold => new() { Weight = 600 }; }
}
namespace Microsoft.UI
{
    internal static class ColorHelper
    {
        public static Rgba FromArgb(byte a, byte r, byte g, byte b) => Rgba.C(r, g, b, a / 255d);
    }
}
namespace Microsoft.UI.Xaml
{
    internal record struct Thickness(double Left, double Top, double Right, double Bottom)
    { public Thickness(double all) : this(all, all, all, all) { } }
    internal record struct CornerRadius(double TopLeft, double TopRight, double BottomRight, double BottomLeft)
    { public CornerRadius(double all) : this(all, all, all, all) { } }
    internal enum HorizontalAlignment { Stretch, Left, Right }
    internal enum VerticalAlignment { Stretch, Center, Top, Bottom }
    internal enum ElementTheme { Light, Dark }
    public enum Visibility { Visible, Collapsed }
    internal enum TextWrapping { NoWrap, Wrap }
    internal enum TextTrimming { None, CharacterEllipsis }
    internal record struct GridLength(double Value = 0, GridUnitType Type = GridUnitType.Auto) { public static GridLength Auto => new(); }
    internal enum GridUnitType { Auto, Star }
    internal record SizeChange(Size NewSize);
    internal class FrameworkElement
    {
        public object? Tag { get; set; }
        public string Id { get; set; } = "";
        public string Help { get; set; } = "";
        public string Name { get; set; } = "";
        public int Column { get; set; }
        public bool IsHitTestVisible { get; set; }
        public Thickness Margin { get; set; }
        public double Width { get; set; } = double.NaN;
        public double Height { get; set; } = double.NaN;
        public double MaxWidth { get; set; } = double.PositiveInfinity;
        public Size DesiredSize { get; private set; }
        public Size LastConstraint { get; private set; }
        public Rect Frame { get; private set; }
        public double ActualHeight => Frame.Height;
        public HorizontalAlignment HorizontalAlignment { get; set; }
        public VerticalAlignment VerticalAlignment { get; set; }
        public ElementTheme ActualTheme => HermesHQ.Features.Settings.ThemeService.Dark ? ElementTheme.Dark : ElementTheme.Light;
        public event Action<object, object>? ActualThemeChanged;
        public event Action<object, SizeChange>? SizeChanged;
        public void ApplyTheme() => ActualThemeChanged?.Invoke(this, this);
        public void Measure(Size room) { LastConstraint = room; DesiredSize = MeasureOverride(room); }
        public void Arrange(Rect r) { Frame = r; var size = ArrangeOverride(new(r.Width, r.Height)); SizeChanged?.Invoke(this, new(size)); }
        protected virtual Size MeasureOverride(Size room) => new(Math.Min(100, room.Width), 18);
        protected virtual Size ArrangeOverride(Size size) => size;
        public virtual IEnumerable<FrameworkElement> Kids => [];
        public IEnumerable<FrameworkElement> Tree() => new[] { this }.Concat(Kids.SelectMany(c => c.Tree()));
    }
}
namespace Microsoft.UI.Xaml.Controls
{
    internal class Panel : FrameworkElement
    {
        public List<FrameworkElement> Children { get; } = [];
        public override IEnumerable<FrameworkElement> Kids => Children;
    }
    internal enum Orientation { Vertical, Horizontal }
    internal class StackPanel : Panel { public Orientation Orientation { get; set; } public double Spacing { get; set; } }
    internal class Grid : Panel
    {
        public double ColumnSpacing { get; set; }
        public List<ColumnDefinition> ColumnDefinitions { get; } = [];
        public static void SetColumn(FrameworkElement e, int column) => e.Column = column;
    }
    internal class ColumnDefinition { public GridLength Width { get; set; } }
    internal class Border : FrameworkElement
    {
        public FrameworkElement? Child { get; set; }
        public Brush? Background { get; set; }
        public Brush? BorderBrush { get; set; }
        public Thickness Padding { get; set; }
        public Thickness BorderThickness { get; set; }
        public CornerRadius CornerRadius { get; set; }
        public override IEnumerable<FrameworkElement> Kids => Child == null ? [] : [Child];
    }
    internal class TextBlock : FrameworkElement
    {
        public string Text { get; set; } = "";
        public double FontSize { get; set; }
        public double LineHeight { get; set; }
        public Windows.UI.Text.FontWeight FontWeight { get; set; }
        public FontFamily? FontFamily { get; set; }
        public Brush? Foreground { get; set; }
        public TextWrapping TextWrapping { get; set; }
        public TextTrimming TextTrimming { get; set; }
        public int MaxLines { get; set; }
        public bool IsTextSelectionEnabled { get; set; }
        public bool BackplateDisabled { get; set; }
    }
    internal class RichTextBlock : FrameworkElement { public string? Trailing { get; init; } }
    internal class ProgressRing : FrameworkElement { public bool IsActive { get; set; } }
}
namespace Microsoft.UI.Xaml.Media
{
    internal record Brush(Rgba Color, string? SystemElement = null);
    internal record SolidColorBrush(Rgba Value) : Brush(Value);
    internal class FontFamily;
    internal enum Stretch { None }
    internal class PathFigure { public Point StartPoint; public bool IsClosed, IsFilled; public List<object> Segments { get; } = []; }
    internal class LineSegment { public Point Point; }
    internal class BezierSegment { public Point Point1, Point2, Point3; }
    internal class PathGeometry { public List<PathFigure> Figures { get; } = []; }
}
namespace Microsoft.UI.Xaml.Shapes
{
    internal class Path : FrameworkElement { public Brush? Fill, Stroke; public double StrokeThickness; public Stretch Stretch; public PathGeometry? Data; }
}
namespace Microsoft.UI.Xaml.Automation.Peers { internal enum AccessibilityView { Raw } }
namespace Microsoft.UI.Xaml.Automation
{
    internal static class AutomationProperties
    {
        public static void SetAccessibilityView(FrameworkElement e, Peers.AccessibilityView view) { }
        public static void SetHelpText(FrameworkElement e, string text) => e.Help = text;
        public static void SetAutomationId(FrameworkElement e, string id) => e.Id = id;
    }
}
