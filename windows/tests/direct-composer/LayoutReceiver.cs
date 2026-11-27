// Layout/input test doubles, not a WinUI renderer. Link the production fitter and event handlers.
// Font advances (em) are CTLine typographic bounds for these synthetic strings in Arial at 100 pt,
// divided by 100. They are controlled, proportional text metrics, NOT inferred Windows editor widths.
using System.Xml.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Windows.Foundation;

static class TypeMetrics
{
    public static readonly string LongTitle = string.Concat(Enumerable.Repeat("Long title ", 20));
    public static readonly string LongModel = string.Concat(Enumerable.Repeat("Wide model ", 12));
    static readonly Dictionary<string, double> Advances = new() {
        [""] = 0, ["Message"] = 4.0576171875, ["Message Trip planning"] = 10.0615234375,
        ["Message Wren"] = 6.70654296875, ["Message " + LongTitle] = 91.06396484375,
        ["Sonnet 5"] = 4.00341796875, ["Model"] = 2.7236328125, ["M"] = .8330078125, [LongModel] = 66.69140625
    };
    public static double Advance(string text, double size, double factor) => Advances[text] * size * factor;
}

namespace Windows.Foundation { public record struct Size(double Width, double Height); }
namespace Microsoft.UI.Xaml.Automation.Peers { public enum AccessibilityView { Raw } }
namespace Microsoft.UI.Xaml.Automation
{
    public static class AutomationProperties
    {
        public static void SetAccessibilityView(FrameworkElement e, Peers.AccessibilityView view) => e.Raw = true;
    }
}
namespace Microsoft.UI.Xaml.Data { public class Binding { public required Control Source; public required PropertyPath Path; } }
namespace Microsoft.UI.Xaml
{
    public enum TextWrapping { Wrap, NoWrap }
    public enum Visibility { Visible, Collapsed }
    public record PropertyPath(string Name);
    public record struct Thickness(double Left, double Top, double Right, double Bottom)
    {
        public double Horizontal => Left + Right;
        public static Thickness From(string? s)
        {
            var v = (s ?? "0").Split(',').Select(double.Parse).ToArray();
            return v.Length switch { 1 => new(v[0], v[0], v[0], v[0]), 2 => new(v[0], v[1], v[0], v[1]),
                4 => new(v[0], v[1], v[2], v[3]), _ => throw new FormatException(s) };
        }
    }
    public class FrameworkElement
    {
        public const string LanguageProperty = "Language";
        public bool Raw;
        public int Row, Column, Span = 1;
        public double ActualWidth { get; private set; }
        public Thickness Margin;
        public event EventHandler? Loaded, SizeChanged;
        public void Load() => Loaded?.Invoke(this, EventArgs.Empty);
        // Publish only changed arranged widths, not the measure offer or an unconditional fitted-state callback.
        public void Arrange(double width)
        {
            if (ActualWidth == width) return;
            ActualWidth = width; SizeChanged?.Invoke(this, EventArgs.Empty);
        }
    }
}
namespace Microsoft.UI.Xaml.Controls
{
    public class Grid : FrameworkElement
    {
        public List<string> ColumnDefinitions = [];
        public static int GetRow(FrameworkElement e) => e.Row;
        public static void SetRow(FrameworkElement e, int n) => e.Row = n;
        public static void SetColumn(FrameworkElement e, int n) => e.Column = n;
        public static void SetColumnSpan(FrameworkElement e, int n) => e.Span = n;
    }
    public class Canvas : FrameworkElement { public List<TextBlock> Children = []; }
    public class Control : FrameworkElement
    {
        public string FontFamily = "Arial", FontStyle = "Normal", FontWeight = "Normal", FontStretch = "Normal", Language = "en";
        public int CharacterSpacing;
        public double MinWidth, FontSize, OsTextScale = 1;
        public bool IsTextScaleFactorEnabled = true;
        public Thickness Padding, BorderThickness;
        public double Insets => Padding.Horizontal + BorderThickness.Horizontal;
        public Visibility Visibility;
    }
    public class TextBlock : FrameworkElement
    {
        public const string FontFamilyProperty = "FontFamily", FontSizeProperty = "FontSize", FontStyleProperty = "FontStyle",
            FontWeightProperty = "FontWeight", FontStretchProperty = "FontStretch", CharacterSpacingProperty = "CharacterSpacing",
            IsTextScaleFactorEnabledProperty = "IsTextScaleFactorEnabled";
        public string Text = "";
        public TextWrapping TextWrapping = TextWrapping.Wrap;
        public bool UseLayoutRounding = true;
        public Size DesiredSize;
        readonly Dictionary<string, Control> sources = [];
        public void SetBinding(string prop, Binding binding)
        {
            if (prop != binding.Path.Name) throw new Exception("mismatched font binding: " + prop);
            sources.Add(prop, binding.Source);
        }
        public void Measure(Size offer)
        {
            var source = sources[FontSizeProperty];
            if (sources.Count != 8 || sources.Values.Any(s => s != source) || !Raw || !double.IsPositiveInfinity(offer.Width)
                || TextWrapping != TextWrapping.NoWrap) throw new Exception("constrained, exposed or mismatched metric");
            double natural = TypeMetrics.Advance(Text, source.FontSize, source.IsTextScaleFactorEnabled ? source.OsTextScale : 1);
            DesiredSize = new(UseLayoutRounding ? Math.Round(natural) : natural, source.FontSize);
        }
    }
    public class Button : Control { public string? Content; }
    public class TextBox : Control
    {
        public string PlaceholderText = "", Name = "", AutomationId = "";
        string text = ""; int start, length; bool focus;
        public int InputWrites { get; private set; }
        public string Text { get => text; set { InputWrites++; text = value; } }
        public int SelectionStart { get => start; set { InputWrites++; start = value; } }
        public int SelectionLength { get => length; set { InputWrites++; length = value; } }
        public bool KeyboardFocus { get => focus; set { InputWrites++; focus = value; } }
        public bool AcceptsReturn, FocusVisuals;
        public TextWrapping TextWrapping;
        public void Insert(string chars)
        {
            if (!KeyboardFocus) throw new Exception("input went to another owner");
            Text = Text.Remove(SelectionStart, SelectionLength).Insert(SelectionStart, chars);
            SelectionStart += chars.Length; SelectionLength = 0;
        }
    }
}

// Closed drawers, idle chat, ordinary text. Unexpected effects are errors even though there is no live receiver.
enum VirtualKey { None, Enter, Escape, Shift, Control, Down, Up, Tab }
[Flags] enum CoreVirtualKeyStates { None = 0, Down = 1 }
static class InputKeyboardSource
{
    public static bool Shift;
    public static CoreVirtualKeyStates GetKeyStateForCurrentThread(VirtualKey k) =>
        k == VirtualKey.Shift && Shift ? CoreVirtualKeyStates.Down : CoreVirtualKeyStates.None;
}
class KeyRoutedEventArgs(VirtualKey key) { public VirtualKey Key = key; public bool Handled; }
class Context(TextBox editor)
{
    public TextBox Composer = editor;
    public List<Func<KeyRoutedEventArgs, bool>> ComposerKeys = [];
    public Action<string?> SetModelChip = _ => throw new Exception("not wired");
    public Action? SendHandler => null;
}
class Drawer { public bool IsOpen => false; public object? Marked => null; public void Move(int _) => throw new Exception(); public void Close() => throw new Exception(); }
class Memo { public bool HasDraft => false; public bool PrimarySend() => throw new Exception(); }
class Session { public Task StopAsync() => throw new Exception("stop"); }
class ViewModel { public bool Busy => false; public Session Session => new(); }
class Chat { public object? Options; public bool QueuesNextSend { get => false; set => throw new Exception(); } public Chat Queue => this; public void Send(string _, bool queue) => throw new Exception("queue"); }
static class ComposerText { public static string SendText(string s) => s.Trim(); }

partial class Row
{
    readonly Grid ComposerRow = new(); readonly Canvas ComposerMetrics = new();
    public readonly TextBox Composer = new(); public readonly Button ComposerModel = new();
    readonly Context _ctx; Context _context => _ctx;
    readonly ViewModel _vm = new(); readonly Chat _c = new(); readonly Drawer _drawer = new(); readonly Memo _memo = new();
    readonly string? _editingId = null;
    bool Owns(Context opening) => ReferenceEquals(opening, _ctx);
    void Send() => throw new Exception("send"); void CancelEdit() => throw new Exception();
    void PickDrawerRow(object _) => throw new Exception(); void SetText(string _) => throw new Exception("replace draft");
    Features.Composer.DirectComposerFit _composerFit = null!;
    readonly double cap, outerInsets, leading, send;
    readonly int leadingCol, trailingCol, sendCol;
    public double Trailing, EditorCap = double.PositiveInfinity;
    public double Lane => ComposerMetrics.ActualWidth;
    public double Room => Composer.ActualWidth - Composer.Insets;
    public bool Chip => ComposerModel.Visibility == Visibility.Visible;
    public bool Stacked => Composer.Row == 0;
    public double Chrome => outerInsets + leading + send + Trailing;
    public double FullWidth(string title) => Math.Ceiling(TypeMetrics.Advance("Message " + title, Composer.FontSize, Composer.OsTextScale));
    public double WordWidth => Math.Ceiling(TypeMetrics.Advance("Message", Composer.FontSize, Composer.OsTextScale));
    public double ButtonWidth(string name) => Math.Max(ComposerModel.MinWidth, Math.Ceiling(TypeMetrics.Advance(name, ComposerModel.FontSize, ComposerModel.OsTextScale)) + ComposerModel.Insets);
    public Row(string uiRoot, double commandGlyph, double attachGlyph, double textSize, string textPadding)
    {
        _ctx = new(Composer);
        var page = XElement.Load(Path.Combine(uiRoot, "Pages", "ChatPage.xaml"));
        var app = XElement.Load(Path.Combine(uiRoot, "App.xaml"));
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml"; var ns = page.GetDefaultNamespace();
        XElement Named(string name) => page.Descendants().Single(e => (string?)e.Attribute(x + "Name") == name);
        static double N(XElement e, string key) => (double)e.Attribute(key)!;
        static double Across(XElement e, string key) => Thickness.From((string?)e.Attribute(key)).Horizontal;
        static int Col(XElement e) => (int?)e.Attribute("Grid.Column") ?? 0;
        static void Place(FrameworkElement part, XElement e)
        {
            part.Row = (int?)e.Attribute("Grid.Row") ?? 0; part.Column = Col(e); part.Span = (int?)e.Attribute("Grid.ColumnSpan") ?? 1;
            part.Margin = Thickness.From((string?)e.Attribute("Margin"));
        }
        var row = Named("ComposerRow"); var box = Named("ComposerBox"); var pane = box.Parent!;
        cap = N(pane, "MaxWidth"); outerInsets = Across(pane, "Padding") + Across(box, "Padding") + Across(box, "BorderThickness");
        var style = app.Descendants().Single(e => (string?)e.Attribute(x + "Key") == "QuietButtonStyle");
        double StyleWidth(string key) => Across(style.Elements().Single(e => (string?)e.Attribute("Property") == key), "Value");
        var lead = Named("ComposerLeading"); var trail = Named("ComposerTrailing"); var btn = Named("SendButton");
        leading = commandGlyph + attachGlyph + 2 * (StyleWidth("Padding") + StyleWidth("BorderThickness")) + N(lead, "Spacing") + Across(lead, "Margin");
        send = N(btn, "Width") + Across(btn, "Margin"); leadingCol = Col(lead); trailingCol = Col(trail); sendCol = Col(btn);
        var edit = Named("Composer"); var chip = Named("ComposerModel"); var lane = Named("ComposerMetrics");
        Place(Composer, edit); Place(ComposerModel, chip); Place(ComposerMetrics, lane);
        ComposerRow.ColumnDefinitions.AddRange(row.Element(ns + "Grid.ColumnDefinitions")!.Elements().Select(e => (string)e.Attribute("Width")!));
        if (row.Parent != box || new[] { edit, chip, lane, lead, trail, btn }.Any(e => e.Parent != row)
            || row.Element(ns + "Grid.RowDefinitions")!.Elements().Any(e => (string?)e.Attribute("Height") != "Auto")) throw new Exception("unexpected page topology");
        Composer.Name = (string)edit.Attribute("AutomationProperties.Name")!; Composer.AutomationId = (string)edit.Attribute("AutomationProperties.AutomationId")!;
        Composer.PlaceholderText = (string)edit.Attribute("PlaceholderText")!; Composer.AcceptsReturn = (bool)edit.Attribute("AcceptsReturn")!;
        Composer.TextWrapping = Enum.Parse<TextWrapping>((string)edit.Attribute("TextWrapping")!); Composer.FocusVisuals = (bool)edit.Attribute("UseSystemFocusVisuals")!;
        Composer.MinWidth = N(edit, "MinWidth"); Composer.BorderThickness = Thickness.From((string?)edit.Attribute("BorderThickness"));
        // Installed default TextBox template: placeholder spans both columns with the edit's padding and border.
        Composer.Padding = Thickness.From((string?)edit.Attribute("Padding") ?? textPadding); Composer.FontSize = (double?)edit.Attribute("FontSize") ?? textSize;
        ComposerModel.FontSize = N(chip, "FontSize"); ComposerModel.MinWidth = N(chip, "MinWidth");
        ComposerModel.Padding = Thickness.From((string?)chip.Attribute("Padding")); ComposerModel.BorderThickness = Thickness.From((string?)chip.Attribute("BorderThickness"));
        ComposerModel.Visibility = Enum.Parse<Visibility>((string)chip.Attribute("Visibility")!);
        Install(); ComposerRow.Load();
    }
    public void Type(char key, bool shift = false)
    {
        InputKeyboardSource.Shift = shift; var e = new KeyRoutedEventArgs(key == '\r' ? VirtualKey.Enter : VirtualKey.None);
        Composer_PreviewKeyDown(Composer, e);
        if (!e.Handled && (key != '\r' || Composer.AcceptsReturn)) Composer.Insert(key.ToString());
        InputKeyboardSource.Shift = false;
    }
    // WinUI is the native gate. Here Auto tracks take actual accessory demand; the star gets the final remaining slot.
    public void Arrange(double pane)
    {
        var final = Math.Min(cap, pane) - outerInsets;
        for (int pass = 0; pass < 12; pass++)
        {
            var before = (Chip, Composer.Row, Composer.Column, Composer.Span, Composer.PlaceholderText);
            var tracks = new double[ComposerRow.ColumnDefinitions.Count];
            tracks[leadingCol] = leading; tracks[trailingCol] = Trailing; tracks[sendCol] = send;
            if (Chip) tracks[ComposerModel.Column] = ButtonWidth(ComposerModel.Content!) + ComposerModel.Margin.Horizontal;
            int star = ComposerRow.ColumnDefinitions.FindIndex(w => w == "*"); tracks[star] = Math.Max(0, final - tracks.Sum());
            double Slot(int col, int span) => tracks.Skip(col).Take(span).Sum();
            // All allocations describe this pass, even if a SizeChanged asks the next pass to move a child.
            var edit = Math.Max(Composer.MinWidth, Math.Min(EditorCap, Slot(Composer.Column, Composer.Span)));
            var lane = Slot(ComposerMetrics.Column, ComposerMetrics.Span);
            ComposerRow.Arrange(final); Composer.Arrange(edit); ComposerMetrics.Arrange(lane);
            foreach (var text in ComposerMetrics.Children) { text.Measure(new(double.PositiveInfinity, double.PositiveInfinity)); text.Arrange(text.DesiredSize.Width); }
            if (before == (Chip, Composer.Row, Composer.Column, Composer.Span, Composer.PlaceholderText)) return;
        }
        throw new Exception("unstable composer layout");
    }
}
