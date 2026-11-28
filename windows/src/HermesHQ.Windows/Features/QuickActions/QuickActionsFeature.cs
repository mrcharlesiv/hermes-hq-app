using Hermes.Core.Composer;
using Hermes.Core.QuickActions;
using HermesHQ.Pages;
using HermesHQ.Services;
using HermesHQ.Shell;

namespace HermesHQ.Features.QuickActions;

/// The Favorites page: this device's tiles. On Windows Ctrl+Shift+K opens the same place as the sidebar.
/// NOTE: Kept strictly decoupled from WinUI controls and gateway singletons so `FavoritesPlace.Tests` compiles this
/// file directly against `InertEdges.cs`.
public static class QuickActionsFeature
{
    public const string PlaceId = QuickTileStore.RowID;

    /// The list's home on this PC: `hqn.quickActions` in its own file under the app's folder.
    public static IKeyValueStore Store { get; } = new JsonFileStore(Path.Combine(AppPaths.Root, "quick-actions.json"));

    public static void Register()
    {
        if (Places.Get(PlaceId).Page != typeof(PlaceholderPage)) return;
        Places.Register(PlaceId, typeof(QuickActionsPage));
        // [WIN-24] The chats on show, so a Send a Message / Prompt / Slash Command / Memo / Talk tile can act on the chat.
        ChatExtensions.OnOpen.Add(ctx =>
        {
            OpenChats.Add(ctx);
            ctx.Closed += () => OpenChats.Remove(ctx);
        });
    }

    private static readonly List<ChatContext> OpenChats = [];

    /// Returns the currently active `ChatContext` for `(profile, storedId)` once its `ChatPage` is loaded and on show.
    internal static ChatContext? FindOpenChat(string profile, string storedId)
    {
        var ctx = OpenChats.LastOrDefault(c => c.Session.Profile == profile && c.Session.StoredId == storedId);
        return ctx?.Page is ChatPage { IsLoaded: true } page && ChatPage.Current == page ? ctx : null;
    }

    /// Returns the currently active `ChatContext` for any open chat belonging to `profile` once loaded and on show.
    internal static ChatContext? FindOpenBotChat(string profile)
    {
        var ctx = OpenChats.LastOrDefault(c => c.Session.Profile == profile);
        return ctx?.Page is ChatPage { IsLoaded: true } page && ChatPage.Current == page ? ctx : null;
    }

    /// NewChatRouter.deliver's send: once `storedId` (the bot's own chat) is the chat on show, `words` go as typed
    /// words do (the composer's Send: its queue and steering, then the session's send), and what was in the box is
    /// put back. False: that chat isn't up yet.
    internal static bool SendInOpenChat(string profile, string storedId, string words)
    {
        var ctx = OpenChats.LastOrDefault(c => c.Session.Profile == profile && c.Session.StoredId == storedId);
        if (ctx?.Page is not ChatPage { IsLoaded: true } page || ChatPage.Current != page) return false;
        var kept = ctx.Composer.Text;
        page.AutomationSend(words);
        // Taken: the box is empty again, so the draft that was there comes back. Not taken: the words stay in the box.
        if (ctx.Composer.Text.Length == 0) ctx.Composer.Text = kept;
        AppLog.Note("quick-actions", $"send in bot chat: sent ({words.Length} chars)");
        return true;
    }
}
