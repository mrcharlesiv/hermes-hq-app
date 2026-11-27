// Geometry and lifetime regression, not a WinUI renderer. test_welcome_scale_host.py links the production
// WelcomeScaleHost and ThemeService.ApplyScale. Only framework property storage and the child's demand are inert.
using System.Xml.Linq;
using Hermes.Core.Settings;
using Hermes.Core.Transcripts;
using HermesHQ.Features.Onboarding;
using HermesHQ.Features.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

var shell = XElement.Load(Path.Combine(args[0], "MainWindow.xaml"));
var page = XElement.Load(Path.Combine(args[0], "Features/Onboarding/WelcomeScreen.xaml"));
XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";
XElement Named(string name) => page.Descendants().Single(e => (string?)e.Attribute(x + "Name") == name);
double cap = (double)Named("Column").Attribute("MaxWidth")!, pad = (double)Named("Room").Attribute("Padding")!;
double mark = (double)Named("AppMark").Attribute("Width")!;
var frameRow = (int)shell.Descendants().Single(e => e.Name.LocalName == "Frame").Attribute("Grid.Row")!;
var caption = (double)shell.Descendants().First(e => e.Name.LocalName == "RowDefinition").Attribute("Height")!;
var window = new Grid { RowDefinitions = { new() { ActualHeight = caption }, new() } };
var frame = new FrameworkElement { Row = frameRow };
var raw = new MemoryPreferences();
var store = new ThemeStore(raw);
store.SetUiScale(90); // the window has this zoom before the first view loads
ThemeService.Bind(window, frame, new ThemeStore(raw).Load());
var guide = new Grid();
var boundary = new WelcomeScaleHost(guide);
boundary.ShowWelcome(true);

static void Near(double expected, double actual)
{
    if (!double.IsFinite(actual) || Math.Abs(expected - actual) > 0.001)
        throw new Exception($"Expected {expected}, measured {actual}");
}
static double Zoom(FrameworkElement e) => (e.RenderTransform as ScaleTransform)?.ScaleX ?? 1;
void Measure(int percent, double px, double dpi, bool welcome = true)
{
    var width = px / dpi;
    double height = 779 / dpi - caption;
    window.ActualWidth = width;
    window.RowDefinitions[frameRow].ActualHeight = height;
    store.SetUiScale(percent);
    ThemeService.Refresh(new ThemeStore(raw).Load());
    var slot = new Size(double.IsNaN(frame.Width) ? width : frame.Width, double.IsNaN(frame.Height) ? height : frame.Height);
    boundary.Measure(slot);
    boundary.Arrange(new Rect(0, 0, slot.Width, slot.Height));
    double outer = Zoom(frame), inner = Zoom(guide), net = outer * inner;
    Near(percent / 100d, outer); Near(welcome ? 1 : outer, net);
    Near(width, guide.Proposed.Width * net); Near(height, guide.Proposed.Height * net);
    Near(width, guide.Placed.Width * net); Near(height, guide.Placed.Height * net);
    Near(guide.DesiredSize.Width * inner, boundary.DesiredSize.Width);
    Near(guide.DesiredSize.Height * inner, boundary.DesiredSize.Height);
    if (!welcome) return;
    Near(Math.Min(338.8, width - 36.96), Math.Min(cap, guide.Proposed.Width - 2 * pad) * net);
    Near(55.44 * dpi, mark * net * dpi);
}

boundary.Attach();
foreach (var pct in new[] { 90, 100, 125, 150, 100 }.Concat(Enumerable.Range(80, 81)))
    foreach (var (px, dpi) in new[] { (1028, 1d), (640, 2d), (480, 2d), (1001, 1.25) }) Measure(pct, px, dpi);
for (int i = 0; i < 3; i++)
{
    boundary.Detach(); Near(0, ThemeService.Listeners);
    var before = Zoom(guide);
    store.SetUiScale(87); ThemeService.Refresh(store.Load()); Near(before, Zoom(guide));
    var invalidations = boundary.Invalidations;
    boundary.Attach(); Near(1, ThemeService.Listeners); Near(1 / .87, Zoom(guide));
    Near(invalidations + 1, boundary.Invalidations); // even if the host's proposed slot hasn't changed
    boundary.Attach(); Near(1, ThemeService.Listeners); Near(invalidations + 1, boundary.Invalidations);
    Measure(150, 640, 2);
    boundary.ShowWelcome(false); Near(0, ThemeService.Listeners); Measure(125, 640, 2, welcome: false);
    boundary.ShowWelcome(true); Near(1, ThemeService.Listeners); Measure(100, 1028, 1);
    if (guide.RenderTransform != null || frame.RenderTransform != null || raw.Get(ThemeStore.Key.UiScale) != null)
        throw new Exception("Reset left a transform or preference behind");
}
boundary.Detach(); Near(0, ThemeService.Listeners);

sealed class MemoryPreferences : IPreferences
{
    private readonly Dictionary<string, string> _values = [];
    public string? Get(string key) => _values.GetValueOrDefault(key);
    public void Set(string key, string? value) { if (value == null) _values.Remove(key); else _values[key] = value; }
}

namespace HermesHQ.Features.Settings
{
    static partial class ThemeService
    {
        private static FrameworkElement? _root, _content;
        public static ThemeState State { get; private set; } = ThemeState.Default;
        public static event Action? Changed;
        public static int Listeners => Changed?.GetInvocationList().Length ?? 0;
        public static void Bind(Grid grid, FrameworkElement frame, ThemeState state) { _root = grid; _content = frame; Refresh(state); }
        public static void Refresh(ThemeState state) { State = state; ApplyScale(); Changed?.Invoke(); }
    }
}
namespace Windows.Foundation { public record struct Size(double Width, double Height); public record struct Rect(double X, double Y, double Width, double Height); }
namespace Microsoft.UI.Xaml.Media { public class ScaleTransform { public double ScaleX, ScaleY; } }
namespace Microsoft.UI.Xaml
{
    public enum HorizontalAlignment { Stretch, Left } public enum VerticalAlignment { Stretch, Top }
    public record struct Thickness(double Left, double Top, double Right, double Bottom);
    public class FrameworkElement
    {
        public object? RenderTransform; public Thickness Margin; public HorizontalAlignment HorizontalAlignment; public VerticalAlignment VerticalAlignment;
        public double Width = double.NaN, Height = double.NaN, ActualWidth, ActualHeight; public int Row;
        public const string WidthProperty = "Width", HeightProperty = "Height", MarginProperty = "Margin";
        public void ClearValue(string key) { if (key == WidthProperty) Width = double.NaN; else if (key == HeightProperty) Height = double.NaN; else if (key == MarginProperty) Margin = default; else throw new Exception(key); }
        public bool IsLoaded; public event EventHandler? Loaded, Unloaded;
        public void Attach() { IsLoaded = true; Loaded?.Invoke(this, EventArgs.Empty); }
        public void Detach() { IsLoaded = false; Unloaded?.Invoke(this, EventArgs.Empty); }
        public Size DesiredSize, Proposed; public Rect Placed;
        public void Measure(Size size) { Proposed = size; DesiredSize = MeasureOverride(size); }
        public void Arrange(Rect rect) { Placed = rect; ArrangeOverride(new Size(rect.Width, rect.Height)); }
        // Arbitrary intrinsic size, not the incoming proposal.
        protected virtual Size MeasureOverride(Size size) => new(Math.Min(113, size.Width), Math.Min(57, size.Height));
        protected virtual Size ArrangeOverride(Size size) => size;
        public int Invalidations { get; private set; }
        public void InvalidateMeasure() => Invalidations++;
    }
}
namespace Microsoft.UI.Xaml.Controls
{
    public class Panel : FrameworkElement { public List<FrameworkElement> Children { get; } = []; }
    public class RowDefinition { public double ActualHeight; }
    public class Grid : Panel { public List<RowDefinition> RowDefinitions { get; } = []; public static int GetRow(FrameworkElement e) => e.Row; }
}
