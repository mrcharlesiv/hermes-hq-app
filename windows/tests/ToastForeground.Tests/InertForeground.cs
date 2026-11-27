using Hermes.Core.Notifications;
using Hermes.Core.Shell;
using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

// These are the only edges visible to the linked foreground method. The trace records getter names,
// not their values. No WinUI runtime, native import, input, session transport or desktop is linked.
namespace HermesHQ.Services
{
    internal sealed class Scene
    {
        internal const string A = "fixture-a", B = "fixture-b";
        internal const string Canary = "fake-user@example.com C:\\fixture\\private 0xDEADBEEF\nforged-log-line";
        internal static Scene Now { get; set; } = null!;
        internal readonly List<string> Reads = [];
        internal readonly HashSet<string> Fail = [];
        internal string? ThrowAt;
        internal Action<string>? AfterRead;
        internal string Chat = B;
        internal OpenPane Pane = OpenPane.Chat;
        internal readonly XamlRoot Root = new();
        internal readonly Window Window = new();
        internal readonly TextBox Composer = new();

        internal T Read<T>(string step, T good, T bad)
        {
            Reads.Add(step);
            if (ThrowAt == step) throw new InvalidOperationException(Canary);
            var value = Fail.Contains(step) ? bad : good;
            AfterRead?.Invoke(step);
            return value;
        }
    }

    internal static class App { internal static Window? Window => Scene.Now.Read("window", Scene.Now.Window, null); }
    internal sealed class Window
    {
        internal Queue DispatcherQueue => Scene.Now.Read("queue", new Queue(), null)!;
        internal bool SheetShown => Scene.Now.Read("sheet", false, true);
        internal object Content => Scene.Now.Read<object>("content", new FrameworkElement("root"), new object());
    }
    internal sealed class Queue { internal bool HasThreadAccess => Scene.Now.Read("thread", true, false); }

    internal static partial class ReplyQuietReadback
    {
        private const string ChatA = Scene.A, ChatB = Scene.B;
        internal static IQuietReader Reader() => new WindowsReader();
        private sealed partial class WindowsReader : IQuietReader
        {
            private static IntPtr GetForegroundWindow() => Scene.Now.Read<nint>("foreground", 101, 202);
            public int? ReadQuns() => Scene.Now.Read("quns", 5, 6);
            public QuietProfileRead? ReadFocus() => Scene.Now.Read("focus-profile", new QuietProfileRead(0, 4, 1, 0), default);
            public string? ReadAppSetting() => Scene.Now.Read("app-setting", "Enabled", Scene.Canary);
        }
    }
}

namespace Microsoft.UI.Xaml
{
    internal sealed class XamlRoot;
    internal enum Visibility { Visible, Collapsed }
    internal class FrameworkElement(string rootRead)
    {
        internal XamlRoot? XamlRoot => Scene.Now.Read(rootRead, Scene.Now.Root, rootRead == "root" ? null : new XamlRoot());
    }
}
namespace HermesHQ.Pages
{
    internal sealed class ShellPage : FrameworkElement
    {
        private ShellPage() : base("shell-root") { }
        internal static ShellPage? Current => Scene.Now.Read("shell", new ShellPage(), null);
        internal bool IsLoaded => Scene.Now.Read("shell-loaded", true, false);
        internal PaneState KeyState() => Scene.Now.Read("key-state", new PaneState(), null)!;
    }
    internal sealed class PaneState
    {
        internal bool Online => Scene.Now.Read("online", true, false);
        internal OpenPane Pane => Scene.Now.Read("pane", Scene.Now.Pane, OpenPane.Place);
        internal string StoredId => Scene.Now.Read("shell-id", Scene.Now.Chat, Scene.Canary);
    }
    internal sealed class ChatPage : FrameworkElement
    {
        private ChatPage() : base("chat-root") { }
        internal static ChatPage? Current => Scene.Now.Read("chat", new ChatPage(), null);
        internal bool IsLoaded => Scene.Now.Read("chat-loaded", true, false);
        internal string StoredId => Scene.Now.Read("chat-id", Scene.Now.Chat, Scene.Canary);
        internal object? FindName(string name) => Scene.Now.Read("composer", name == "Composer" ? Scene.Now.Composer : null, new object());
    }
}
namespace HermesHQ.Features.Notifications
{
    internal static class NotificationsFeature
    {
        internal static bool Tracks(string id) => Scene.Now.Read("tracked", id == Scene.Now.Chat, false);
    }
}
namespace Microsoft.UI.Xaml.Media
{
    internal sealed class Popup(bool last)
    {
        internal bool IsOpen => Scene.Now.Read(last ? "last-popup" : "popup-open", false, true);
    }
    internal static class VisualTreeHelper
    {
        internal static Popup[] GetOpenPopupsForXamlRoot(XamlRoot root) =>
            Scene.Now.Read("popups", ReferenceEquals(root, Scene.Now.Root) ? new Popup[] { new(false), new(true) } : throw new InvalidOperationException(), null)!;
    }
}
namespace Microsoft.UI.Xaml.Controls
{
    internal sealed class TextBox
    {
        internal bool IsEnabled => Scene.Now.Read("enabled", true, false);
        internal Visibility Visibility => Scene.Now.Read("visible", Visibility.Visible, Visibility.Collapsed);
    }
}
namespace Microsoft.UI.Xaml.Input
{
    internal static class FocusManager
    {
        internal static object GetFocusedElement(XamlRoot root) =>
            Scene.Now.Read<object>("focused", ReferenceEquals(root, Scene.Now.Root) ? Scene.Now.Composer : throw new InvalidOperationException(), new TextBox());
    }
}
namespace WinRT.Interop
{
    internal static class WindowNative
    {
        internal static IntPtr GetWindowHandle(Window window) =>
            Scene.Now.Read<nint>("owned", ReferenceEquals(window, Scene.Now.Window) ? 101 : throw new InvalidOperationException(), 0);
    }
}
