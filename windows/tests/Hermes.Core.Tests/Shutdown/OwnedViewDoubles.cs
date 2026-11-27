// Only the UI/OS endpoints are stand-ins. The coordinator, file registry, chat viewer lifetime and quit plan are shipping code.
using Microsoft.UI.Xaml;

namespace Microsoft.UI.Xaml
{
    public class DependencyObject { public List<DependencyObject> Children { get; } = []; }
    public sealed class XamlRoot { internal List<Popup> Popups { get; } = []; }
    public class UIElement : DependencyObject { internal XamlRoot XamlRoot { get; } = new(); }
    internal sealed class Popup(UIElement child) { public UIElement Child { get; } = child; }
    internal sealed partial class Window { public UIElement Content { get; } = new(); }
}
namespace Microsoft.UI.Xaml.Controls
{
    internal sealed class WebView2(Action close) : UIElement { public void Close() => close(); }
}
namespace Microsoft.UI.Xaml.Media
{
    internal static class VisualTreeHelper
    {
        public static int GetChildrenCount(DependencyObject node) => node.Children.Count;
        public static DependencyObject GetChild(DependencyObject node, int index) => node.Children[index];
        public static IEnumerable<Popup> GetOpenPopupsForXamlRoot(XamlRoot root) => root.Popups;
    }
}
namespace HermesHQ { internal static class App { public static Window? Window { get; set; } } }
namespace HermesHQ.Features.Artifacts
{
    internal static class ArtifactImageWindow { public static void CloseOpen() { } }
    internal sealed partial class ArtifactFileWindow
    {
        private Action _onClose = () => { };
        public static ArtifactFileWindow AddFixture(string key, Action close) =>
            Registry.OpenPage(key, key, _ => new ArtifactFileWindow { _onClose = close }).Window!;
        public void Close() { _onClose(); Registry.Closed(this); }
        public void ForgetFixture() => Registry.Closed(this);
    }
}
namespace HermesHQ.Features.Attachments
{
    internal sealed record ViewerItem;
    internal sealed partial class MediaViewerWindow
    {
        public static MediaViewerWindow? Activated { get; private set; }
        public int Requests { get; private set; }
        public event EventHandler? Closed;
        private MediaViewerWindow(IReadOnlyList<ViewerItem> items, int index) { }
        private void Activate() => Activated = this;
        public void Close() { Requests++; Closed?.Invoke(this, EventArgs.Empty); }
    }
}
// Other registered steps never touch a real timer, socket, player, window or notification service.
namespace HermesHQ.Services
{
    internal static class AppLog
    {
        internal static Action<string, string>? Sink;
        public static void Note(string area, string line) => Sink?.Invoke(area, line);
        public static void Error(string area, Exception error) => throw new NotSupportedException();
    }
    internal static partial class AppState { public static Task CloseGatewayForQuitAsync() => Task.CompletedTask; }
    internal static class UiTree { public static void DeactivateProgressRings(DependencyObject? root) { } }
}

namespace HermesHQ.Pages { internal static class ShellPage { internal static void StopForQuit() { } } }
namespace HermesHQ.Features.Voice
{
    internal sealed class FixturePlayer { public void Stop() { } }
    internal static class ReadAloudFeature { public static FixturePlayer Center { get; } = new(); }
}
namespace HermesHQ.Features.Composer { internal static class MemoApp { public static Voice.FixturePlayer? Player => null; internal static void StopForQuit() { } } }
namespace HermesHQ.Features.Settings { internal static class SettingsWindow { public static void CloseOpen() { } } }
namespace HermesHQ.Features.Screen { internal static class ScreenWindow { public static void CloseOpen() { } } }
namespace HermesHQ.Features.Browser
{
    internal static class BrowserWindow { public static void CloseOpen() { } }
    internal static class PreviewTabWindow { public static void CloseOpen() { } }
}
namespace HermesHQ.Features.PhoneCalls { internal static class PhoneCallsFeature { public static void CloseForQuit() { } } }
namespace HermesHQ.Features.Notifications { internal static class NotificationsFeature { public static string UnregisterForQuit() => "not registered"; } }
