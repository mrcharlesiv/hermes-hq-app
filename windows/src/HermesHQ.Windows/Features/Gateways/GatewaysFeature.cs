using Hermes.Core.Gateways;
using Hermes.Core.Model;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Gateways;

/// Sign-in, gateways and launch (PARITY "Sign-in, gateways, onboarding"): the gateway line at the sidebar's foot and
/// its switcher, Add Gateway… and Manage Gateways… in the account menu, Sign Out's words, the reconnect notice, the
/// "session ended" route, the news check on the other gateways, and reopening the last chat at launch.
public static partial class GatewaysFeature
{
    private static Destination? _lastOpened;

    public static void Register()
    {
        ShellExtensions.GatewayFoot = client => new GatewayFoot(client);
        ShellExtensions.AccountMenu.Add(GatewayFoot.AddGatewayItem);
        ShellExtensions.AccountMenu.Add(GatewayFoot.ManageGatewaysItem);
        ShellExtensions.SignOut = LaunchFlow.SignOutAsync;
        ShellExtensions.ConnectionNotice = (client, bar) => new ConnectionNotice(client, bar);
        ShellExtensions.SessionEnded = LaunchFlow.SessionEnded;
        ShellExtensions.FirstDestination = FirstDestination;
        Navigator.Requested += Remember;
        RegisterNews();
    }

    // ------------------------------------------------------------------ reopen the last chat at launch

    /// The screen on show is what the next cold launch reopens: a chat (with where it was opened from), or nothing.
    private static void Remember(Destination d)
    {
        _lastOpened = d;
        if (!LaunchFlow.AppShown || AppState.Client is not { } c) return;
        RememberedChat? chat = d switch
        {
            BotChatDestination { Bot: var b } => new RememberedChat(RememberedChat.Bots, b.Name, null, true, b.DisplayName),
            ChatDestination ch => new RememberedChat(RememberedChat.Sessions, ch.Profile, ch.StoredId, false, ch.Title),
            _ => null,
        };
        AppState.LaunchChat.Remember(chat, c.AccountId, foreground: true);
    }

    /// The shell's first open at a cold launch (App/Root/MainTabController+LaunchChat.swift): the remembered chat if
    /// its bot is still there; a listed chat is put back at once and checked against the gateway's first fresh list,
    /// going back to the first bot quietly if the gateway no longer lists it.
    private static Destination? FirstDestination(IReadOnlyList<Bot> bots)
    {
        if (!LaunchFlow.TakeColdLaunch() || AppState.Client is not { } c) return null;
        var memory = AppState.LaunchChat;
        var account = c.AccountId;
        var decision = LaunchChatDecision.Decide(memory.Recall(account), memory.CrashedFor(account), memory.Resume(account),
            bot: p => bots.Any(b => b.Name == p), listed: (_, _) => true);
        if (decision.Reopen is not { } chat)
        {
            AppLog.Note("restore", $"skipped: {decision.Skip}");
            return null;
        }
        AppLog.Note("restore", $"reopened the last chat ({chat.Origin})");
        if (chat.BotChat) return new BotChatDestination(bots.First(b => b.Name == chat.Profile));
        var reopened = new ChatDestination(chat.Profile, chat.StoredId!, chat.Title ?? "");
        _ = VerifyAsync(reopened, bots);
        return reopened;
    }

    private static async Task VerifyAsync(ChatDestination reopened, IReadOnlyList<Bot> bots)
    {
        if (AppState.Client is not { } c) return;
        try
        {
            var sidebar = await c.SessionsAsync();
            var rows = sidebar.Recents.Rows.Concat(sidebar.Cron.Rows).Concat(sidebar.Messaging.Rows);
            if (sidebar.Recents.Failed) return; // a failed scan says nothing about the chat
            var decision = LaunchChatDecision.Decide(new RememberedChat(RememberedChat.Sessions, reopened.Profile, reopened.StoredId, false),
                false, true, _ => true, (p, id) => rows.Any(r => r.Id == id && r.Profile == p));
            if (decision.Reopen != null || _lastOpened != reopened || bots.Count == 0) return;
            AppLog.Note("restore", $"closed the reopened chat: {decision.Skip}");
            App.Window?.DispatcherQueue.TryEnqueue(() => Navigator.Go(new BotChatDestination(bots[0])));
        }
        catch (Exception e) when (e is Hermes.Core.Net.GatewayException or OperationCanceledException) { }
    }
}
