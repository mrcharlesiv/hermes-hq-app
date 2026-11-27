using Hermes.Core.Settings;
using Hermes.Core.Shell;
using HermesHQ.Features.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

// Palette notifications are independent of the app theme and are delivered through the real window's handlers.
// The colour revision lets a test distinguish switching brushes from refreshing a brush inside the same scheme.
namespace Microsoft.UI.System
{
    public sealed class ThemeSettings
    {
        public static ThemeSettings? Last; public uint WindowId { get; private init; }
        public static ThemeSettings CreateForWindowId(uint id) => Last = new() { WindowId = id };
        public event Action<ThemeSettings, object>? Changed;
        public int Listeners => Changed?.GetInvocationList().Length ?? 0;
        public void Notify() => Changed?.Invoke(this, new());
    }
}
namespace Windows.UI.ViewManagement
{
    public sealed class UISettings
    {
        public static UISettings? Last; public UISettings() => Last = this;
        public event Action<UISettings, object>? ColorValuesChanged;
        public int Listeners => ColorValuesChanged?.GetInvocationList().Length ?? 0;
        public void Notify() => ColorValuesChanged?.Invoke(this, new());
    }
}
namespace Windows.Graphics { public record struct RectInt32(int X, int Y, int Width, int Height); }
namespace Microsoft.UI.Windowing
{
    public enum DisplayAreaFallback { Nearest } public enum OverlappedPresenterState { Restored }
    public class OverlappedPresenter { public int PreferredMinimumWidth, PreferredMinimumHeight; public OverlappedPresenterState State; }
    public class DisplayArea
    {
        public static DisplayArea Primary { get; } = new(); public RectInt32 WorkArea = new(0, 0, 1200, 900);
        public static DisplayArea GetFromWindowId(uint id, DisplayAreaFallback fallback) => Primary;
        public static DisplayArea GetFromRect(RectInt32 rect, DisplayAreaFallback fallback) => Primary;
    }
    public record Change(bool DidPositionChange, bool DidSizeChange);
    public sealed class AppWindow
    {
        private static uint _next; public uint Id { get; } = ++_next;
        public OverlappedPresenter Presenter = new(); public RectInt32 Size, Position;
        public event Action<AppWindow, Change>? Changed;
        public void MoveAndResize(RectInt32 rect) { Position = Size = rect; Changed?.Invoke(this, new(true, true)); }
        public void Show(bool activate) { }
    }
}
namespace Microsoft.UI.Xaml
{
    public class Window
    {
        public string Title = ""; public bool ExtendsContentIntoTitleBar; public FrameworkElement? Content;
        public Windowing.AppWindow AppWindow { get; } = new(); public Dispatching.Queue DispatcherQueue { get; } = new();
        public event Action<Window, object>? Closed; public void Close() => Closed?.Invoke(this, new());
        public void Activate() { } public void SetTitleBar(Grid drag) { }
    }
}
namespace Microsoft.UI.Xaml.Input
{
    public enum KeyboardAcceleratorPlacementMode { Hidden }
    public class KeyboardAcceleratorInvokedEventArgs { public bool Handled; }
    public class KeyboardAccelerator
    {
        public global::Windows.System.VirtualKey Key; public global::Windows.System.VirtualKeyModifiers Modifiers;
        public event Action<object, KeyboardAcceleratorInvokedEventArgs>? Invoked;
        public void Raise(KeyboardAcceleratorInvokedEventArgs args) => Invoked?.Invoke(this, args);
    }
}
namespace HermesHQ.Shell
{
    public record PlaceArgs(object? Place, object? Argument);
    public static class Navigator { public static bool Listening => true; }
}
namespace HermesHQ.Services
{
    public static class AppLog { public static void Note(string area, string message) { } }
    public static class AppState { public static object? Client { get; } = new(); }
    public static class Automation { public static bool Enabled => false; public static Brush ShotBackground() => throw new InvalidOperationException(); }
}
namespace HermesHQ { public static class App { public static Window? Window { get; } = new() { Content = new Grid() }; } }
namespace HermesHQ.Features.Transcript
{
    public sealed class FilePreferences : Hermes.Core.Transcripts.IPreferences
    {
        public static FilePreferences Shared = new(); private readonly Dictionary<string, string> _values = [];
        public string? Get(string key) => _values.GetValueOrDefault(key);
        public void Set(string key, string? value) { if (value == null) _values.Remove(key); else _values[key] = value; }
    }
}
namespace HermesHQ.Features.Settings
{
    public static class ThemeService
    {
        public static ThemeState State = ThemeState.Default; public static bool SystemHighContrast, Dark;
        public static int OsRevision, PaintedRevision, Refreshes; public static event Action? Changed;
        public static void RefreshContrastBrushes() { PaintedRevision = OsRevision; Refreshes++; }
        public static void Set(ThemeState state, bool contrast) { State = state; SystemHighContrast = contrast; RefreshContrastBrushes(); Changed?.Invoke(); }
        public static Brush Brush(string key) => new(SystemHighContrast
            ? $"contrast:{PaintedRevision}:{HighContrastWalkProof.SystemColourFor(key) ?? key}" : $"{(Dark ? "dark" : "light")}:{key}");
    }
    public static class SettingsFeature
    {
        public sealed record GatewayInfo(string Name, string Host, GatewayConnection State, int Bots, string? Version);
        public static GatewayInfo Gateway() => new("Example Gateway", "desk.example.com:8600", GatewayConnection.Ready, 5, "0.1");
        public static void RefreshVersion(Action refresh) { }
    }
    internal static class Kit
    {
        public static Brush B(string key) => ThemeService.Brush(key);
        public static StackPanel Page(params UIElement[] elements) { var panel = new StackPanel(); panel.Children.AddRange(elements); return panel; }
        public static Border Card(params UIElement[] elements) => new() { Child = Page(elements) };
        public static Button Nav(string? icon, string title, string? detail, Action go, string id) => new() { Id = id, A11yName = title };
        public static UIElement? FormAtLastRowLookup;
        public static FrameworkElement? Find(DependencyObject root, string id)
        {
            FormAtLastRowLookup = ((root as ScrollViewer)?.Content as Border)?.Child;
            return null; // record the real landing's search root; don't run a flash or synthesize a renderer
        }
        public static void Flash(FrameworkElement row) => throw new InvalidOperationException();
    }
    public class SettingsFileActions { public Task OpenAsync(string target) => throw new InvalidOperationException("No file actions"); }
    internal static class SettingsPanes
    {
        public static int CategoriesBuilt;
        public static FrameworkElement Category(SettingsPage p, SettingsCategory c) { CategoriesBuilt++; return new Border { Tag = c }; }
        public static FrameworkElement GatewayPage(SettingsPage p) => new Border { Tag = "gateway" };
        public static (string Title, Func<FrameworkElement> Make)? PageFor(SettingsPage p, string id) => id switch
        {
            "theme" => ("Theme", () => new Border { Tag = id }), "about" => ("About", () => new Border { Tag = id }),
            "licenses" => (LicenseNotices.PageTitle, () => new Border { Tag = id }), _ => null,
        };
    }
}
