using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.UI.StartScreen;

namespace HermesHQ.Services;

/// Native Windows OS shell integrations: Taskbar Jump Lists, Explorer file drag-out, and jump/protocol URI dispatch.
public static class WindowsShellIntegration
{
    private const string ArgNewChat = "hermeshq://new-chat";
    private const string ArgOpenQuickly = "hermeshq://open-quickly";
    private const string ArgSettings = "hermeshq://settings";
    private const string ArgBotPrefix = "hermeshq://bot/";

    /// Populates the Windows Taskbar Jump List with New Chat, Open Quickly, Settings, and recent bots.
    /// Gracefully skips when running under CI automation or when JumpList is unsupported on the host.
    public static async Task UpdateJumpListAsync(IEnumerable<(string Id, string Name)>? recentBots = null)
    {
        if (Automation.Enabled) return;
        try
        {
            if (!JumpList.IsSupported()) return;
            var list = await JumpList.LoadCurrentAsync();
            list.SystemGroupKind = JumpListSystemGroupKind.None;
            list.Items.Clear();

            var newChat = JumpListItem.CreateWithArguments(ArgNewChat, "New Chat");
            newChat.Description = "Start a new chat in Hermes HQ";
            newChat.GroupName = "Tasks";
            list.Items.Add(newChat);

            var openQuickly = JumpListItem.CreateWithArguments(ArgOpenQuickly, "Open Quickly");
            openQuickly.Description = "Jump to any bot, chat, or setting";
            openQuickly.GroupName = "Tasks";
            list.Items.Add(openQuickly);

            var settings = JumpListItem.CreateWithArguments(ArgSettings, "Settings");
            settings.Description = "Open Hermes HQ Settings";
            settings.GroupName = "Tasks";
            list.Items.Add(settings);

            if (recentBots != null)
            {
                foreach (var (id, name) in recentBots.Take(5))
                {
                    if (string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(name)) continue;
                    var item = JumpListItem.CreateWithArguments(ArgBotPrefix + Uri.EscapeDataString(id), name);
                    item.GroupName = "Bots";
                    item.Description = $"Open {name}";
                    list.Items.Add(item);
                }
            }
            await list.SaveAsync();
        }
        catch (Exception e)
        {
            AppLog.Note("shell", $"jump list update skipped: {e.GetType().Name}");
        }
    }

    /// Dispatches a launch argument or protocol URI (`hermeshq://...`) through the shell Navigator.
    public static bool TryHandleCommandArgument(string? arg)
    {
        if (string.IsNullOrWhiteSpace(arg)) return false;
        var trimmed = arg.Trim();
        if (trimmed.Equals(ArgSettings, StringComparison.OrdinalIgnoreCase))
        {
            Navigator.Open("settings");
            return true;
        }
        if (trimmed.Equals(ArgNewChat, StringComparison.OrdinalIgnoreCase))
        {
            Navigator.Open("sessions");
            return true;
        }
        if (trimmed.Equals(ArgOpenQuickly, StringComparison.OrdinalIgnoreCase))
        {
            Navigator.Open("sessions");
            return true;
        }
        if (trimmed.StartsWith(ArgBotPrefix, StringComparison.OrdinalIgnoreCase))
        {
            var id = Uri.UnescapeDataString(trimmed[ArgBotPrefix.Length..]);
            var bot = AppState.Client?.Bots?.FirstOrDefault(b => string.Equals(b.Name, id, StringComparison.OrdinalIgnoreCase));
            if (bot != null) { Navigator.Go(new BotChatDestination(bot)); return true; }
        }
        return false;
    }

    /// Enables dragging a local file out of Hermes HQ into Windows Explorer or other desktop apps.
    public static void AttachFileDragOut(UIElement element, Func<string?> localPathProvider, Func<string?>? titleProvider = null)
    {
        element.CanDrag = true;
        element.DragStarting += async (_, args) =>
        {
            var path = localPathProvider();
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) { args.Cancel = true; return; }
            var deferral = args.GetDeferral();
            try
            {
                var file = await StorageFile.GetFileFromPathAsync(path);
                args.Data.SetStorageItems([file]);
                args.Data.RequestedOperation = DataPackageOperation.Copy;
                if (titleProvider?.Invoke() is { Length: > 0 } title) args.Data.Properties.Title = title;
            }
            catch (Exception e)
            {
                AppLog.Note("shell", $"file drag-out skipped: {e.GetType().Name}");
                args.Cancel = true;
            }
            finally { deferral.Complete(); }
        };
    }
}
