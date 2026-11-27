using HermesHQ.Features.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

// Test-only stand-ins for the edges of the linked walk. The test supplies each successive pane;
// Invoke and shot only record calls. Nothing here can dispatch input or read a desktop.
namespace Microsoft.UI.Xaml
{
    internal sealed record Popup(FrameworkElement? Child);
    internal sealed class XamlRoot { public List<Popup> Popups { get; } = []; }
    internal class FrameworkElement(string id = "")
    {
        public string Id { get; } = id;
        public bool IsLoaded { get; set; } = true;
        public double ActualWidth { get; set; } = 20;
        public double ActualHeight { get; set; } = 20;
        public XamlRoot? XamlRoot { get; set; } = new();
        public FrameworkElement? Parent { get; set; }
    }
}
namespace Microsoft.UI.Xaml.Controls
{
    internal sealed class HyperlinkButton(string text) : FrameworkElement("settings.back")
    {
        public bool IsEnabled { get; set; } = true;
        public Uri? NavigateUri { get; set; }
        public object Content { get; set; } = text;
    }
}
namespace Microsoft.UI.Xaml.Media
{
    internal static class VisualTreeHelper
    {
        public static IReadOnlyList<Popup> GetOpenPopupsForXamlRoot(XamlRoot root) => root.Popups;
    }
}
namespace HermesHQ.Features.Settings
{
    internal sealed class Queue { public bool HasThreadAccess { get; set; } = true; }
    internal sealed class SettingsPage : FrameworkElement
    {
        public static SettingsPage? Current { get; set; }
        public Queue DispatcherQueue { get; } = new();
        public bool Searching { get; set; }
        public string? MarkedCategory { get; set; } = "About";
        public string PageTitle { get; set; } = "";
        public bool CanGoBack { get; set; }
        public List<FrameworkElement> Children { get; } = [];

        public void Show(string title, string? back, params string[] markers)
        {
            PageTitle = title;
            CanGoBack = back != null;
            Children.Clear();
            Children.AddRange(markers.Select(id => new FrameworkElement(id) { Parent = this }));
            if (back != null) Children.Add(new HyperlinkButton(back) { Parent = this });
        }
    }
}
namespace HermesHQ.Services
{
    internal sealed class Client { public Session Session { get; } = new(); }
    internal sealed class Session { public string Address { get; set; } = "http://127.0.0.1:9830"; }
    internal static class AppState { public static Client? Client { get; set; } }
    internal sealed record Proof(string Stamp);
    internal static class Automation
    {
        public static bool AppOnly { get; set; }
        public static Proof? Desktop { get; set; }
    }
    internal sealed class Window
    {
        public FrameworkElement? Content { get; set; } = new();
        public bool SheetShown { get; set; }
    }
    internal static class App { public static Window? Window { get; set; } }

    internal static partial class ProofWalks
    {
        internal static Task Run(Func<string, Task> shot, bool notice) => AboutBackAsync(shot, notice);
        internal static Action<FrameworkElement> OnInvoke = null!;
        internal static Action<FrameworkElement>? AfterShowing;
        internal static Action? BetweenPolls;
        // The parent walk's Root and PopupRoots are also supplied so its unmodified source can replay the two failures.
        private static FrameworkElement Root => App.Window!.Content!;
        private static string Id(FrameworkElement e) => e.Id;
        private static IEnumerable<FrameworkElement> Shown(SettingsPage page) => page.Children;
        private static bool Within(FrameworkElement element, FrameworkElement ancestor) =>
            element == ancestor || element.Parent is { } parent && Within(parent, ancestor);
        private static IEnumerable<FrameworkElement> PopupRoots() => Root.XamlRoot?.Popups.Select(p => p.Child).OfType<FrameworkElement>() ?? [];
        private static void Invoke(FrameworkElement e) => OnInvoke(e);
        private static Task<FrameworkElement> Until(Func<FrameworkElement?> read, string what)
        {
            var element = read();
            if (element == null && BetweenPolls is { } next)
            {
                BetweenPolls = null;
                next(); // The fixture advances one observation, never a real clock or UI.
                element = read();
            }
            if (element == null) throw new TimeoutException($"waited too long for {what}");
            AfterShowing?.Invoke(element);
            return Task.FromResult(element);
        }
    }
}
