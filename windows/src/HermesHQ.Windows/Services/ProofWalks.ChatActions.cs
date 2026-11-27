using Hermes.Core.Chat;
using Hermes.Core.Shell;
using HermesHQ.Controls;
using HermesHQ.Pages;
using HermesHQ.Shell;
using HermesHQ.ViewModels;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Services;

/// [WIN-43] The CI's walk for the chat actions (windows/ci/windows.yml asks for it on the composer stand-in), on the
/// stand-in's Trip planning chat (menus-gateway.py `TRIP`), backed by the stand-in's call log
/// (`Hermes.Core.Shell.ChatActionsProof`):
///   chat-actions  The latest reply's right-click menu reads Copy, Share…, Select Text, Regenerate, Branch in New Chat
///                 (picture chat-actions-menu). A click on Branch in New Chat says “Branching…”, the stand-in takes one
///                 `session.branch` with the count of messages through the reply, and the branch opens in the chat's
///                 place titled “Branch of Trip planning”, saying “Branched into a new chat.” (picture chat-branched).
/// The menu opens as a right-click opens it (MessageView.OpenMenu); its Branch is clicked by SendInput; where they don't arrive, the walk does what they do and says so in the app log.
internal static partial class ProofWalks
{
    private static void RegisterChatActionsWalks()
    {
        Automation.NamedWalks["chat-actions"] = ChatActionsAsync;
    }

    private static async Task ChatActionsAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        Navigator.Go(new ChatDestination(ChatActionsProof.TripBot, ChatActionsProof.TripStoredId, ChatActionsProof.TripTitle));
        var chat = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == ChatActionsProof.TripStoredId && p.MessageCount >= 4 && !p.IsBusy ? p : null,
            "Trip planning's messages");
        var list = await Until(() => Shown(chat).OfType<ListView>().FirstOrDefault(), "the transcript");
        List<MessageItem> Items() => (list.ItemsSource as IEnumerable<object>)?.OfType<MessageItem>().ToList() ?? [];
        var reply = await Until(() => Items().LastOrDefault(i => i.Role == Hermes.Core.Model.Role.Assistant), "the latest reply");
        list.ScrollIntoView(reply, ScrollIntoViewAlignment.Leading);
        await Task.Delay(500);
        var view = await Until(() => Shown(list).OfType<MessageView>().FirstOrDefault(v => v.Item?.Id == reply.Id), "the latest reply on screen");

        // The reply's action row: Regenerate and More.
        await Until(() => Shown(view).FirstOrDefault(e => Id(e) == ChatActionWords.RegenerateReplyId), "the reply's Regenerate");
        await Until(() => Shown(view).FirstOrDefault(e => Id(e) == ChatActionWords.ReplyMoreId), "the reply's More");

        // The right-click menu, opened at the reply as ContextRequested opens it (the walk's pointer has no right button;
        // MessageView.OpenMenu builds the same menu the right-click shows).
        AppLog.Note("automation", "walk chat-actions: opening the reply's menu as a right-click does");
        view.OpenMenu();
        var branchItem = await Until(() => MenuItem("Branch in New Chat"), "Branch in New Chat in the reply's menu");
        var entries = InPopups().OfType<MenuFlyoutItem>().Select(i => (i.Text, i.IsEnabled)).ToList();
        if (ChatActionsProof.MenuReads(entries) is { } menuWrong) throw new InvalidOperationException(menuWrong);
        await Task.Delay(400);
        await shot("chat-actions-menu");

        // Branch in New Chat: one session.branch with the count through the reply; the branch opens with its notice.
        var count = RewindParams.BranchCount(reply.Id, [.. Items().Select(i => i.Message)])
            ?? throw new InvalidOperationException("the reply isn't in the chat");
        var mark = WalkProof.LastCallAt(await StandIn(url, "/__menus/state"));
        try { Mouse.Click(branchItem); }
        catch (InvalidOperationException e) { AppLog.Note("automation", $"walk chat-actions: Branch wasn't clicked ({e.Message}); invoking it"); Invoke(branchItem); }
        var branched = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId != ChatActionsProof.TripStoredId
            && p.NoticeText == ChatActionWords.Branched ? p : null, "the branch to open with its notice", 30);
        if (ChatActionsProof.BranchOpened(branched.StoredId, branched.ChatTitle, branched.NoticeText, ChatActionsProof.TripStoredId,
                ChatActionsProof.TripTitle) is { } openWrong)
            throw new InvalidOperationException(openWrong);
        if (ChatActionsProof.Branched(await StandIn(url, "/__menus/state"), mark, count) is { } wireWrong)
            throw new InvalidOperationException(wireWrong);
        await Until(() => branched.MessageCount >= count ? branched : null, "the branch's messages", 20);
        await shot("chat-branched");
        // The walk's own picture: the branch once its notice has gone, as it stays.
        await Until(() => branched.NoticeText == null ? branched : null, "the notice to go", 15);
        await shot("chat-actions");
    }
}
