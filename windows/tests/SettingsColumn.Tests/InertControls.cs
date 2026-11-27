// Only the control surface used by the linked production files. Setters and events are observable;
// no Windows runtime, display, physical input, automation provider or file operation is involved.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Windows.Foundation { public readonly record struct Size(double Width, double Height); }
namespace Windows.System { public enum VirtualKey { Enter, Escape, W } public enum VirtualKeyModifiers { Control } }
namespace Microsoft.UI { public static class Colors { public const string Transparent = "Transparent"; } }
namespace Microsoft.UI.Text { public enum FontWeights { Normal, SemiBold } }
namespace Microsoft.UI.Xaml.Data { public sealed class BindableAttribute : Attribute; }
namespace Microsoft.UI.Xaml.Navigation { public record NavigationEventArgs(object? Parameter); }
namespace Microsoft.UI.Xaml.Automation.Peers { public enum AccessibilityView { Raw } }
namespace Microsoft.UI.Xaml.Automation
{
    public static class AutomationProperties
    {
        public static void SetAutomationId(UIElement e, string id) => e.Id = id;
        public static void SetName(UIElement e, string name) => e.A11yName = name;
        public static void SetHelpText(UIElement e, string hint) => e.Hint = hint;
        public static void SetAccessibilityView(UIElement e, Peers.AccessibilityView view) { }
    }
}
namespace Microsoft.UI.Xaml.Media
{
    public record Brush(string Key);
    public record SolidColorBrush(string Color) : Brush(Color);
    public record FontFamily(string Name);
    public static class VisualTreeHelper { public static Popup[] GetOpenPopupsForXamlRoot(XamlRoot _) => []; }
    public record Popup(object? Child);
}
namespace Microsoft.UI.Dispatching
{
    public enum DispatcherQueuePriority { Low }
    public sealed class Queue
    {
        private readonly Queue<Action> _pending = new();
        public bool TryEnqueue(Action action) { _pending.Enqueue(action); return true; }
        public bool TryEnqueue(DispatcherQueuePriority priority, Action action) => throw new InvalidOperationException("No file actions in column tests");
        public int Count => _pending.Count;
        public void Drain() { while (_pending.TryDequeue(out var action)) action(); }
    }
}
namespace Microsoft.UI.Xaml
{
    public record DependencyProperty(string Name);
    public class DependencyObject
    {
        private readonly Dictionary<DependencyProperty, object?> _values = [];
        public void SetValue(DependencyProperty p, object? value) => _values[p] = value;
        public object? GetValue(DependencyProperty p) => _values.GetValueOrDefault(p);
        public void ClearValue(DependencyProperty p) => _values.Remove(p);
    }
    public readonly record struct Thickness(double Left, double Top, double Right, double Bottom) { public Thickness(double all) : this(all, all, all, all) { } }
    public readonly record struct CornerRadius(double Radius);
    public enum GridUnitType { Pixel, Auto, Star }
    public readonly record struct GridLength(double Value, GridUnitType GridUnitType = GridUnitType.Pixel) { public static GridLength Auto => new(1, GridUnitType.Auto); }
    public enum HorizontalAlignment { Stretch, Center, Left } public enum VerticalAlignment { Stretch, Center, Top }
    public enum Visibility { Visible, Collapsed } public enum TextTrimming { CharacterEllipsis } public enum TextWrapping { NoWrap, Wrap }
    public enum FocusState { Unfocused, Keyboard, Pointer, Programmatic }
    public enum ElementHighContrastAdjustment { Application, None }
    public class ResourceDictionary : Dictionary<string, object> { public Dictionary<string, object> ThemeDictionaries { get; } = []; }
    public class Application { public static Application Current { get; } = new(); public ResourceDictionary Resources { get; } = new(); }
    public class XamlRootChangedEventArgs : EventArgs;
    public class XamlRoot
    {
        public double RasterizationScale = 1;
        public event Action<XamlRoot, XamlRootChangedEventArgs>? Changed;
        public void Dpi(double value) { RasterizationScale = value; Changed?.Invoke(this, new()); }
    }
    public class UIElement : DependencyObject
    {
        public object? Tag; public string? Id, A11yName, Hint;
        public bool IsHitTestVisible = true; public Visibility Visibility; public Brush? Background;
        public static readonly DependencyProperty HighContrastAdjustmentProperty = new("contrast adjustment");
        public ElementHighContrastAdjustment HighContrastAdjustment { get => (ElementHighContrastAdjustment)(GetValue(HighContrastAdjustmentProperty) ?? ElementHighContrastAdjustment.Application); set => SetValue(HighContrastAdjustmentProperty, value); }
    }
    public record SizeArgs(Size NewSize);
    public class FrameworkElement : UIElement
    {
        public ResourceDictionary Resources { get; } = new(); public bool IsLoaded; public double Opacity = 1, ActualWidth;
        public double Width = double.NaN, Height = double.NaN, MaxWidth = double.PositiveInfinity, MinWidth, MinHeight;
        public Thickness Margin, Padding, BorderThickness; public CornerRadius CornerRadius;
        public HorizontalAlignment HorizontalAlignment; public VerticalAlignment VerticalAlignment; public object? RequestedTheme;
        public XamlRoot XamlRoot = new(); public Dispatching.Queue DispatcherQueue = new();
        public List<Input.KeyboardAccelerator> KeyboardAccelerators = []; public Input.KeyboardAcceleratorPlacementMode KeyboardAcceleratorPlacementMode;
        public event Action<object, object>? Loaded, Unloaded, LayoutUpdated; public event Action<object, SizeArgs>? SizeChanged;
        public void Load() { IsLoaded = true; Loaded?.Invoke(this, new()); } public void Unload() { IsLoaded = false; Unloaded?.Invoke(this, new()); }
        public void UpdateLayout() => LayoutUpdated?.Invoke(this, new()); public void Resize(double w) { ActualWidth = w; SizeChanged?.Invoke(this, new(new(w, 12))); }
        public Size DesiredSize; public void InvalidateMeasure() { } public void Measure(Size n) => DesiredSize = MeasureOverride(n); protected virtual Size MeasureOverride(Size n) => n;
    }
}
namespace Microsoft.UI.Xaml.Controls
{
    public class Control : FrameworkElement
    {
        internal static Control? FocusOwner;
        public FocusState FocusState { get; private set; }
        public bool Focus(FocusState state)
        {
            if (FocusOwner != null) FocusOwner.FocusState = FocusState.Unfocused;
            FocusOwner = this; FocusState = state; return true;
        }
        public bool UseSystemFocusVisuals, IsTabStop = true; public double FontSize; public HorizontalAlignment HorizontalContentAlignment;
        public FontFamily? FontFamily; public static readonly DependencyProperty FontFamilyProperty = new("font family");
    }
    public class ContentControl : Control { public object? Content; }
    public class Page : ContentControl
    {
        public void Navigate(object? value) => OnNavigatedTo(new(value));
        protected virtual void OnNavigatedTo(Navigation.NavigationEventArgs e) { } protected virtual void OnNavigatedFrom(Navigation.NavigationEventArgs e) { }
    }
    public class Frame : ContentControl
    {
        public void Navigate(Type type, object? route) { var page = (Page)Activator.CreateInstance(type)!; Content = page; page.Navigate(route); page.Load(); }
    }
    public class Panel : FrameworkElement { public List<UIElement> Children { get; } = []; }
    public class Grid : Panel
    {
        public List<RowDefinition> RowDefinitions { get; } = []; public List<ColumnDefinition> ColumnDefinitions { get; } = []; public double RowSpacing, ColumnSpacing;
        public static readonly DependencyProperty ColumnDP = new("column"), RowDP = new("row"), SpanDP = new("row span");
        public static void SetColumn(UIElement e, int i) => e.SetValue(ColumnDP, i); public static void SetRow(UIElement e, int i) => e.SetValue(RowDP, i); public static void SetRowSpan(UIElement e, int i) => e.SetValue(SpanDP, i);
    }
    public class RowDefinition { public GridLength Height; } public class ColumnDefinition { public GridLength Width; }
    public enum Orientation { Vertical, Horizontal } public class StackPanel : Panel { public Orientation Orientation; public double Spacing; }
    public class Canvas : Panel; public class Border : FrameworkElement { public UIElement? Child; }
    public class TextBlock : FrameworkElement
    {
        public static readonly DependencyProperty ForegroundProperty = new("text ink"); public Brush? Foreground { get => (Brush?)GetValue(ForegroundProperty); set => SetValue(ForegroundProperty, value); }
        public string Text = ""; public double FontSize = 14; public Text.FontWeights FontWeight; public TextTrimming TextTrimming; public TextWrapping TextWrapping; public int MaxLines;
        protected override Size MeasureOverride(Size n) => new(Text.Length * FontSize * .6, FontSize * 1.2);
    }
    public class IconElement : FrameworkElement
    {
        public static readonly DependencyProperty ForegroundProperty = new("icon ink"); public Brush? Foreground { get => (Brush?)GetValue(ForegroundProperty); set => SetValue(ForegroundProperty, value); }
    }
    public class FontIcon : IconElement { public string Glyph = ""; public double FontSize; }
    public class KeyArgs { public global::Windows.System.VirtualKey Key; public bool Handled; }
    public class TextBox : Control
    {
        public string PlaceholderText = ""; private string _text = ""; public bool QueueEvents;
        public event Action<object, object>? TextChanged; public event Action<object, KeyArgs>? KeyDown;
        public string Text { get => _text; set { if (_text == value) return; _text = value; if (QueueEvents) DispatcherQueue.TryEnqueue(Notify); else Notify(); } }
        private void Notify() => TextChanged?.Invoke(this, new());
        public void Drain() => DispatcherQueue.Drain();
        public bool Key(global::Windows.System.VirtualKey key) { var e = new KeyArgs { Key = key }; KeyDown?.Invoke(this, e); return e.Handled; }
    }
    public class Button : ContentControl { public event Action<object, object>? Click; public void InertClick() => Click?.Invoke(this, new()); }
    public class HyperlinkButton : Button; public class ContentDialog : ContentControl;
    public enum ListViewSelectionMode { Single } public class ListViewItem : ContentControl;
    public record ItemClickEventArgs(object ClickedItem);
    public class ListView : Control
    {
        public List<object> Items { get; } = []; public object? ItemsSource; public ListViewSelectionMode SelectionMode;
        public bool IsItemClickEnabled, SingleSelectionFollowsFocus = true;
        public Control? FocusedItem => FocusOwner is { } focused && Items.Contains(focused) ? focused : null;
        public event Action<object, ItemClickEventArgs>? ItemClick; public event Action<object, object>? SelectionChanged;
        private int _index = -1;
        public int SelectedIndex
        {
            get => _index;
            set
            {
                if (_index == value) return;
                _index = value;
                // WinUI Selector::OnSelectionChanged -> SetFocusedItem: move actual focus only if the list has it.
                if (value >= 0 && FocusedItem is { } prior) ((Control)At(value)).Focus(prior.FocusState);
                SelectionChanged?.Invoke(this, new());
            }
        }
        private object At(int index) => Items.Count > 0 ? Items[index] : ((global::System.Collections.IList)ItemsSource!)[index]!;
        public object? SelectedItem => SelectedIndex < 0 ? null : At(SelectedIndex);
        public void FocusArrow(int i) { ((Control)At(i)).Focus(FocusState.Keyboard); if (SingleSelectionFollowsFocus) SelectedIndex = i; }
        public void Pick(object item) => ItemClick?.Invoke(this, new(item));
    }
    public enum ScrollBarVisibility { Disabled, Auto } public enum ScrollMode { Disabled }
    public class ScrollViewer : ContentControl
    {
        public ScrollBarVisibility HorizontalScrollBarVisibility, VerticalScrollBarVisibility; public ScrollMode HorizontalScrollMode; public double VerticalOffset, ViewportWidth;
        public static readonly DependencyProperty ViewportWidthProperty = new("viewport"); private Action<DependencyObject, DependencyProperty>? _changed;
        public long RegisterPropertyChangedCallback(DependencyProperty p, Action<DependencyObject, DependencyProperty> changed) { if (p != ViewportWidthProperty) throw new ArgumentException(); _changed += changed; return 1; }
        public void ChangeView(double? x, double? y, float? zoom, bool now) => VerticalOffset = y ?? 0;
        public static void SetHorizontalScrollBarVisibility(Control c, ScrollBarVisibility v) { } public static void SetVerticalScrollBarVisibility(Control c, ScrollBarVisibility v) { }
        public void ResizeViewport(double v) { ViewportWidth = v; _changed?.Invoke(this, ViewportWidthProperty); }
    }
}
namespace Microsoft.UI.Xaml.Shapes { public class Ellipse : FrameworkElement { public Brush? Fill; } }
