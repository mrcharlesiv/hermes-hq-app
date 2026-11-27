using Hermes.Core.Chat;
using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace HermesHQ.Services;

/// [WIN-CHAT-INTRO] The CI's walk for the empty chat's intro on the composer stand-in (windows/ci/windows.yml), right after
/// new-chat-bare and on the same synthetic chat kind (`session.create` with no messages: no rows until its first send):
///   chat-intro       A new empty chat for the stand-in's default bot: the intro shows the roster's bot name (not the
///                    chat's "New Chat"), its role/description lines deduped (else "No messages yet. Say hello."), Bot
///                    Info and Name Chat, and no Talk (not on Windows). Words typed in the box.
///   chat-intro-off   Greeting on Empty Chats switched off: the intro is gone, "No messages yet" stays for a screen reader,
///                    and the box still has its words and the keyboard. Switched on again: the intro is back.
///   chat-intro-sent  The words sent: the stand-in took exactly one prompt.submit of them, the chat has its first row and
///                    the intro is gone.
/// The switch is flipped through the same setter Settings › Chat's row calls (ChatIntro.IsOn), so the chat stays on screen.
internal static partial class ProofWalks
{
    private const string IntroDraft = "hello from the intro walk";

    private static void RegisterChatIntroWalks() => Automation.NamedWalks["chat-intro"] = ChatIntroAsync;

    private static async Task ChatIntroAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var hub = await Until(() => ListsHub.Current, "the lists");
        var bots = await client.BotsAsync();
        var bot = bots.FirstOrDefault(b => b.Name == "default") ?? bots.FirstOrDefault() ?? throw new InvalidOperationException("no bots");
        await Until(() => hub.Bots.Bot(bot.Name), "the roster's row for the bot");
        var wasOn = ChatIntro.IsOn;
        ChatIntro.IsOn = true;
        try
        {
            var id = await hub.Sessions.NewChatAsync(bot.Name);
            Navigator.Go(new ChatDestination(bot.Name, id, Hermes.Core.Composer.NewChatCommand.Title));
            var page = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == id ? p : null, "the new chat");
            if (page.ChatTitle != Hermes.Core.Composer.NewChatCommand.Title) throw new InvalidOperationException($"the new chat is titled {page.ChatTitle}");
            await Until(() => FindIn(page, "chat.intro"), "the empty chat's intro");
            if (page.MessageCount != 0) throw new InvalidOperationException($"the new chat has {page.MessageCount} rows");

            var row = hub.Bots.Bot(bot.Name)!;
            var name = ChatIntro.BotName(row.Name, bot.Name);
            var title = ((TextBlock)Need(page, "chat.intro.title")).Text;
            if (title != name) throw new InvalidOperationException($"the intro names \"{title}\", not the bot \"{name}\"");
            if (title == page.ChatTitle) throw new InvalidOperationException("the intro shows the chat's title, not the bot's name");
            var lines = ChatIntro.Lines(name, row.Role, row.Model.Description);
            var body = ((TextBlock)Need(page, "chat.intro.body")).Text;
            if (body != ChatIntro.Body(lines)) throw new InvalidOperationException($"the intro's line reads \"{body}\", not \"{ChatIntro.Body(lines)}\"");
            var role = FindIn(page, "chat.intro.role") as TextBlock;
            if ((role?.Text) != lines.Role) throw new InvalidOperationException($"the intro's role reads \"{role?.Text}\", not \"{lines.Role}\"");
            Need(page, "chat.intro.info");
            Need(page, "chat.intro.name");
            if (FindIn(page, "chat.intro.talk") != null) throw new InvalidOperationException("a Talk button shows; Windows has no Talk");
            AppLog.Note("automation", $"walk chat-intro: \"{title}\" / role \"{lines.Role}\" / \"{body}\", Bot Info and Name Chat");

            var box = (TextBox)Need(page, "chat.composer");
            box.Focus(FocusState.Keyboard);
            if (!await KeysAsync(() => Keys.Type(IntroDraft), () => box.Text == IntroDraft, "typing"))
            {
                box.Text = IntroDraft;   // a WinUI TextBox's peer gives no managed Value pattern (CI run 44976036331)
                box.SelectionStart = IntroDraft.Length;
            }
            await shot("chat-intro");

            // Off: blank, still heard, the box untouched.
            ChatIntro.IsOn = false;
            await Until(() => FindIn(page, "chat.intro.off"), "\"No messages yet\" for a screen reader");
            if (FindIn(page, "chat.intro") != null) throw new InvalidOperationException("the intro still shows with the switch off");
            BoxKept(page, box);
            await shot("chat-intro-off");

            ChatIntro.IsOn = true;
            await Until(() => FindIn(page, "chat.intro"), "the intro, switched on again");
            if (FindIn(page, "chat.intro.off") != null) throw new InvalidOperationException("\"No messages yet\" stays over the intro");
            BoxKept(page, box);

            // The first send replaces the intro with its own row.
            var url = client.Session.Address.ToString();
            var mark = WalkProof.LastCallAt(await StandIn(url, "/__menus/state"));
            if (!await KeysAsync(() => Keys.Press(Keys.Enter), () => page.MessageCount > 0, "Enter"))
                Invoke(Need(page, "chat.send"));
            await Until(() => page.MessageCount > 0 && FindIn(page, "chat.intro") == null && FindIn(page, "chat.intro.off") == null ? page : null,
                "the first row in place of the intro");
            await Task.Delay(800);
            if (WalkProof.QuickSentInChat(await StandIn(url, "/__menus/state"), mark, IntroDraft) is { } wrong)
                throw new InvalidOperationException(wrong.Replace("the tile", "the intro's chat"));
            if (FindIn(page, "chat.intro") != null) throw new InvalidOperationException("the intro came back over the first row");
            await shot("chat-intro-sent");
        }
        finally { ChatIntro.IsOn = wasOn; }
    }

    private static void BoxKept(ChatPage page, TextBox box)
    {
        if (box.Text != IntroDraft) throw new InvalidOperationException($"the box reads \"{box.Text}\", not the typed words");
        if (!ReferenceEquals(FocusManager.GetFocusedElement(page.XamlRoot), box)) throw new InvalidOperationException("the box lost the keyboard");
    }
}
