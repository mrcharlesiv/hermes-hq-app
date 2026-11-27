using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Shell;
using HermesHQ.Controls;
using HermesHQ.Pages;
using HermesHQ.Shell;
using HermesHQ.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Proof = Hermes.Core.Shell.SettledQuestionsWalkProof;

namespace HermesHQ.Services;

/// [WIN-QUESTIONS-SETTLED-WALK] The CI's walk for the settled Q&A card and Answer Now (225c169d6 + b2d7f15f0; the Mac's
/// 93f984bb1 PromptLogic.swift ClarifySettled/ClarifyLate, PromptRows.swift settledCard, ChatPromptCell's Answer Now,
/// ChatPromptsController answerLater/sendLater), on its own questions stand-in (windows.yml's "questions-settled" extra,
/// windows/ci/fixtures/questions-gateway.py), backed by the app's state and the stand-in's own record
/// (`Hermes.Core.Shell.SettledQuestionsWalkProof`):
///   questions-settled  The stand-in reset and a fresh, empty session made for Hermes (its /__fixture/reset keeps the bot's
///                      history), opened as the bot's chat. With clarify_hold on, "Pick one city for me" is sent from the
///                      message box: the dock's Lisbon and Send; the stand-in has it submitted with its tool held; then
///                      POST /__fixture/release ends the tool. Sam's chat and back, so the chat is drawn again from its
///                      history: the card "Your answer", the city, no Answer Now (questions-settled-card). The hold off,
///                      "Quick text question about the project name": the dock's Skip; the stand-in has it skipped; the
///                      second card reads "Question skipped" … "No answer" with Answer Now (questions-answer-now). Answer
///                      Now: the dock asks that question with Cancel for Skip, Send held until something is typed; "Harbor
///                      Lights" typed (questions-answer-now-dock); Send: the stand-in takes the card's message
///                      (ClarifyLate.Message), your bubble reads "Harbor Lights" alone, and the card reads "Answered
///                      later" with no Answer Now (questions-answer-now-sent). Sam's chat and back once more: both cards
///                      and the bubble as before, from history (the walk's own picture).
/// The app's own controls through their automation peers (Invoke) and the dock's answer field's Text; no OS input.
internal static partial class ProofWalks
{
    private static void RegisterSettledQuestionsWalks() => Automation.NamedWalks["questions-settled"] = SettledQuestionsAsync;   // Proof.Walk

    private static async Task SettledQuestionsAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        try { await SettledQuestionsWalkAsync(shot, client, url); }
        finally
        {
            // Nothing left held or running on the stand-in, whatever happened.
            try
            {
                await SettledPostAsync(url, "/__fixture/config", new JsonObject { ["clarify_hold"] = false });
                await SettledPostAsync(url, "/__fixture/release", new JsonObject());
            }
            catch (Exception x) { AppLog.Note("automation", $"walk questions-settled: the stand-in's hold wasn't let go: {x.Message}"); }
        }
    }

    private static async Task SettledQuestionsWalkAsync(Func<string, Task> shot, Hermes.Core.HermesClient client, string url)
    {
        await SettledPostAsync(url, "/__fixture/reset", new JsonObject());
        var bots = await client.BotsAsync();
        var bot = bots.FirstOrDefault(b => b.Name == Proof.Bot) ?? throw new InvalidOperationException("the stand-in has no Hermes");
        var other = bots.FirstOrDefault(b => b.Name == Proof.OtherBot) ?? throw new InvalidOperationException("the stand-in has no Sam");
        var before = await client.BotChatIdAsync(bot);

        // A fresh, empty session: the stand-in's reset keeps the bot's history.
        var made = await SettledPostAsync(url, "/__fixture/history", new JsonObject
        {
            ["profile"] = Proof.Bot, ["count"] = 0, ["new_session"] = true,
        });
        var storedId = await client.BotChatIdAsync((await client.BotsAsync()).First(b => b.Name == Proof.Bot));
        if (Proof.FreshSession(before, storedId, made?["session_id"]?.GetValue<string>()) is { } stale) throw new InvalidOperationException(stale);
        var chat = await OpenSettledChatAsync(bot.Name, storedId, bot.DisplayName, 0);

        // 1. Answered in the live dock while the stand-in holds the tool; released; drawn again from history.
        await SettledPostAsync(url, "/__fixture/config", new JsonObject { ["clarify_hold"] = true });
        await SendFromBoxAsync(chat, Proof.AnsweredPrompt);
        var dock = await Until(() => QuestionDockIn(chat), "the live question's dock", 20);
        Invoke(await Until(() => Shown(QuestionDockIn(chat) ?? dock).OfType<Button>()
            .FirstOrDefault(b => AutomationProperties.GetName(b) == Proof.AnsweredChoice), $"{Proof.AnsweredChoice} in the dock"));
        var send = await Until(() => DockButton(QuestionDockIn(chat), Proof.SendTitle) is { IsEnabled: true } b ? b : null, "the dock's Send");
        Invoke(send);
        string? held = "not read";
        for (var until = DateTime.UtcNow.AddSeconds(15); DateTime.UtcNow < until && held != null; await Task.Delay(250))
            held = Proof.AnsweredAndHeld(await StandIn(url, "/__fixture/requests"));
        if (held != null) throw new InvalidOperationException(held);
        AppLog.Note("automation", "walk questions-settled: the stand-in holds the answered clarify; releasing it");
        await SettledPostAsync(url, "/__fixture/config", new JsonObject { ["clarify_hold"] = false });
        await SettledPostAsync(url, "/__fixture/release", new JsonObject());
        await Until(() => !chat.IsBusy && LastReply(chat)?.Contains(Proof.AnsweredReply, StringComparison.Ordinal) == true ? chat : null,
            "the answered question's reply", 20);
        await Until(() => QuestionDockIn(chat) == null ? chat : null, "the dock gone");
        chat = await ReopenSettledChatAsync(other, bot.Name, storedId, bot.DisplayName, minimum: 2);
        await CardsAsync(chat, [Proof.Answered], "the answered card from history");
        await shot("questions-settled-card");

        // 2. Skipped in the live dock: the card offers Answer Now.
        await SendFromBoxAsync(chat, Proof.SkippedPrompt);
        await Until(() => QuestionDockIn(chat) is { } d && DockButton(d, Proof.LiveSkip) != null ? d : null, "the second question's dock", 20);
        Invoke(DockButton(QuestionDockIn(chat), Proof.LiveSkip) ?? throw new InvalidOperationException("the dock has no Skip"));
        await Until(() => !chat.IsBusy && LastReply(chat)?.Contains(Proof.SkippedReply, StringComparison.Ordinal) == true ? chat : null,
            "the skipped question's reply", 20);
        if (Proof.SkippedOnStandIn(await StandIn(url, "/__fixture/requests")) is { } notSkipped) throw new InvalidOperationException(notSkipped);
        var cards = await CardsAsync(chat, [Proof.Answered, Proof.Skipped], "the skipped card with Answer Now");
        await shot("questions-answer-now");

        // 3. Answer Now: its dock (Cancel, the question, Send held), the answer typed.
        var answerNow = cards.Last().AnswerNow ?? throw new InvalidOperationException("the skipped card has no Answer Now");
        Invoke(answerNow);
        var later = await Until(() => QuestionDockIn(chat) is { } d && DockButton(d, Proof.LaterSkip) != null ? d : null, "Answer Now's dock");
        if (Proof.LaterDock(SeenDock(later), typed: false) is { } dockWrong) throw new InvalidOperationException(dockWrong);
        var field = Shown(later).OfType<TextBox>().FirstOrDefault() ?? throw new InvalidOperationException("Answer Now's dock has no answer field");
        field.Text = Proof.LateAnswer;   // a WinUI TextBox's peer gives no managed Value pattern (CI run 44976036331)
        field.SelectionStart = Proof.LateAnswer.Length;
        await Until(() => DockButton(QuestionDockIn(chat), Proof.SendTitle) is { IsEnabled: true } b ? b : null, "Answer Now's Send after typing");
        if (Proof.LaterDock(SeenDock(QuestionDockIn(chat) ?? later), typed: true) is { } typedWrong) throw new InvalidOperationException(typedWrong);
        await shot("questions-answer-now-dock");

        // 4. Send: the card's message goes into the chat; the bubble reads the answer alone; the card is answered later.
        Invoke(DockButton(QuestionDockIn(chat), Proof.SendTitle) ?? throw new InvalidOperationException("Answer Now's dock has no Send"));
        await Until(() => QuestionDockIn(chat) == null ? chat : null, "Answer Now's dock closed");
        string? sent = "not read";
        for (var until = DateTime.UtcNow.AddSeconds(15); DateTime.UtcNow < until && sent != null; await Task.Delay(250))
            sent = Proof.LateSent(await StandIn(url, "/__fixture/state"), await StandIn(url, "/__fixture/requests"));
        if (sent != null) throw new InvalidOperationException(sent);
        await Until(() => !chat.IsBusy && LastItem(chat)?.Role == Hermes.Core.Model.Role.Assistant ? chat : null, "the reply to the late answer", 20);
        await BubbleAsync(chat);
        await CardsAsync(chat, [Proof.Answered, Proof.AnsweredLater], "the card answered later");
        await shot("questions-answer-now-sent");

        // 5. Opened again: both cards and the bubble from history.
        chat = await ReopenSettledChatAsync(other, bot.Name, storedId, bot.DisplayName, minimum: 5);
        await CardsAsync(chat, [Proof.Answered, Proof.AnsweredLater], "both cards from history");
        await BubbleAsync(chat);
        await shot("questions-settled");   // Proof.Walk, its own picture
    }

    // ------------------------------------------------------------------ the chat

    private static async Task<ChatPage> OpenSettledChatAsync(string profile, string storedId, string title, int minimum)
    {
        Navigator.Go(new ChatDestination(profile, storedId, title));
        var chat = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == storedId && p.MessageCount >= minimum && !p.IsBusy ? p : null,
            "the walk's chat", 20);
        await Until(() => FindIn(chat, "chat.composer"), "the message box");
        await Task.Delay(1500);   // the chat's own binding (session.resume, the questions link) settles
        return chat;
    }

    /// Sam's chat, then the walk's again: its transcript drawn afresh from the stand-in's history.
    private static async Task<ChatPage> ReopenSettledChatAsync(Hermes.Core.Model.Bot other, string profile, string storedId, string title, int minimum)
    {
        var otherId = await AppState.Client!.BotChatIdAsync(other);
        Navigator.Go(new ChatDestination(other.Name, otherId, other.DisplayName));
        await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == otherId ? p : null, "Sam's chat");
        await Task.Delay(500);
        return await OpenSettledChatAsync(profile, storedId, title, minimum);
    }

    /// The words go in the message box (its Text: no OS input) and its Send is invoked.
    private static async Task SendFromBoxAsync(ChatPage chat, string words)
    {
        var box = (TextBox)Need(chat, "chat.composer");
        box.Text = words;
        box.SelectionStart = words.Length;
        var count = chat.MessageCount;
        // Enabled too: invoking a Send that is still off throws UIA_E_ELEMENTNOTENABLED (CI run 45081613795).
        Invoke(await Until(() => FindIn(chat, "chat.send") is Control { IsHitTestVisible: true, IsEnabled: true } s ? s : null, "the Send button, on"));
        await Until(() => chat.MessageCount > count ? chat : null, $"\u201C{words}\u201D in the chat");
    }

    private static List<MessageItem> SettledItems(ChatPage chat) =>
        Shown(chat).OfType<ListView>().FirstOrDefault()?.ItemsSource is IEnumerable<object> items ? items.OfType<MessageItem>().ToList() : [];

    private static MessageItem? LastItem(ChatPage chat) => SettledItems(chat).LastOrDefault();

    private static string? LastReply(ChatPage chat) =>
        SettledItems(chat).LastOrDefault(i => i.Role == Hermes.Core.Model.Role.Assistant)?.Message.Text;

    /// The chat's settled cards in order (each message with a clarify call brought on screen in turn), checked against
    /// `expected` until they agree (10 s at least); answers what was seen with each card's Answer Now button.
    private static async Task<List<(Proof.CardSeen Seen, Button? AnswerNow)>> CardsAsync(ChatPage chat, IReadOnlyList<Proof.CardSeen> expected, string what)
    {
        var list = await Until(() => Shown(chat).OfType<ListView>().FirstOrDefault(), "the transcript");
        List<(Proof.CardSeen Seen, Button? AnswerNow)> seen = [];
        string? wrong = "not read";
        for (var until = DateTime.UtcNow.AddSeconds(15); DateTime.UtcNow < until; await Task.Delay(300))
        {
            seen = [];
            foreach (var item in SettledItems(chat).Where(i => i.Message.Tools.Any(t => t.Name == "clarify")))
            {
                list.ScrollIntoView(item, ScrollIntoViewAlignment.Leading);
                await Task.Delay(300);
                if (Shown(list).OfType<MessageView>().FirstOrDefault(v => v.Item?.Id == item.Id) is not { } view) continue;
                foreach (var card in Shown(view).Where(e => Id(e) == "clarify.note"))
                {
                    var button = Shown(card).OfType<Button>().FirstOrDefault(b => Id(b) == "clarify.answerNow");
                    seen.Add((new Proof.CardSeen(AutomationProperties.GetName(card) ?? "", button != null), button));
                }
            }
            if ((wrong = Proof.Cards([.. seen.Select(s => s.Seen)], expected)) == null) break;
        }
        if (wrong != null) throw new InvalidOperationException($"{what}: {wrong}");
        if (SettledItems(chat).LastOrDefault() is { } last) list.ScrollIntoView(last, ScrollIntoViewAlignment.Leading);
        await Task.Delay(500);
        return seen;
    }

    /// Your bubble of the late answer: brought on screen, its words checked.
    private static async Task BubbleAsync(ChatPage chat)
    {
        var list = await Until(() => Shown(chat).OfType<ListView>().FirstOrDefault(), "the transcript");
        var mine = await Until(() => SettledItems(chat).LastOrDefault(i => i.Role == Hermes.Core.Model.Role.User
            && i.Message.Text == Proof.LateMessage), "your late answer's message");
        string? wrong = "not read";
        for (var until = DateTime.UtcNow.AddSeconds(10); DateTime.UtcNow < until && wrong != null; await Task.Delay(300))
        {
            list.ScrollIntoView(mine, ScrollIntoViewAlignment.Leading);
            await Task.Delay(300);
            var view = Shown(list).OfType<MessageView>().FirstOrDefault(v => v.Item?.Id == mine.Id);
            var texts = view == null ? new List<string>() : Shown(view).OfType<TextBlock>().Select(t => t.Text).Where(t => t is { Length: > 0 }).ToList();
            wrong = Proof.BubbleShowsAnswersAlone(texts);
        }
        if (wrong != null) throw new InvalidOperationException(wrong);
        if (SettledItems(chat).LastOrDefault() is { } last) list.ScrollIntoView(last, ScrollIntoViewAlignment.Leading);
        await Task.Delay(500);
    }

    // ------------------------------------------------------------------ the dock

    /// The question dock shown in the chat (QuestionDock.View: named "Question" for one question), or null.
    private static Border? QuestionDockIn(ChatPage chat) =>
        Shown(chat).OfType<Border>().FirstOrDefault(b => AutomationProperties.GetName(b) == Proof.DockName
            && Shown(b).OfType<Button>().Any(x => x.Content is string s && (s == Proof.LiveSkip || s == Proof.LaterSkip || s == "Skip All")));

    private static Button? DockButton(FrameworkElement? dock, string words) =>
        dock == null ? null : Shown(dock).OfType<Button>().FirstOrDefault(b => b.Content is string s && s == words);

    private static Proof.DockSeen SeenDock(FrameworkElement dock)
    {
        var buttons = Shown(dock).OfType<Button>().Select(b => b.Content as string).OfType<string>().ToList();
        var question = Shown(dock).OfType<TextBlock>().FirstOrDefault(t => t.FontSize >= 15 && t.Text.Length > 0)?.Text;
        return new Proof.DockSeen(question, buttons, DockButton(dock, Proof.SendTitle)?.IsEnabled == true);
    }

    /// A POST to the stand-in's controls; its JSON answer.
    private static async Task<JsonNode?> SettledPostAsync(string url, string path, JsonObject body)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        using var content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        using var response = await http.PostAsync(url.TrimEnd('/') + path, content);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"the stand-in's {path} answered {(int)response.StatusCode}");
        var text = await response.Content.ReadAsStringAsync();
        return text.Length == 0 ? null : JsonNode.Parse(text);
    }
}
