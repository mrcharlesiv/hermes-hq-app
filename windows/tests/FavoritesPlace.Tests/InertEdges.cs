// The real place registry needs page types, not windows. Registration may install a chat hook but must never run it.
namespace Microsoft.UI.Xaml { public class FrameworkElement; }
namespace HermesHQ.Pages
{
    internal sealed class SessionsPage;
    internal sealed class PlaceholderPage;
    internal sealed class ChatPage
    {
        internal bool IsLoaded => false;
        internal static ChatPage? Current => null;
        internal void AutomationSend(string words) => throw new NotSupportedException();
    }
}
namespace HermesHQ.Features.QuickActions { internal sealed class QuickActionsPage; }
namespace HermesHQ.Services
{
    internal static class AppPaths { internal static string Root { get; } = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N")); }
    internal static class AppLog { internal static void Note(string area, string words) => throw new NotSupportedException(); }
}
namespace HermesHQ.Shell
{
    internal static class ChatExtensions { internal static List<Action<ChatContext>> OnOpen { get; } = []; }
    internal sealed class ChatContext
    {
        internal Hermes.Core.Chat.ChatSession Session => throw new NotSupportedException();
        internal Pages.ChatPage Page => throw new NotSupportedException();
        internal sealed class Draft { internal string Text { get; set; } = ""; }
        internal Draft Composer => throw new NotSupportedException();
        internal event Action Closed { add => throw new NotSupportedException(); remove => throw new NotSupportedException(); }
    }
}
