using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Questions;
using Proof = Hermes.Core.Shell.SettledQuestionsWalkProof;

namespace Hermes.Core.Tests;

/// The tests that drive questions-gateway.py (HQW_E2E_QUESTIONS_CREDENTIALS) one at a time: each resets it.
[CollectionDefinition(Name, DisableParallelization = true)]
public class QuestionsStandIn { public const string Name = "questions stand-in"; }

/// [WIN-QUESTIONS-SETTLED-WALK] The questions-settled walk's steps without WinUI (what can run headless): against
/// questions-gateway.py, with a client already signed in as the app's is, the walk's fresh session, its words, the dock's
/// answers (ClarifyStaging, as the dock stages them), the stand-in's hold and release, the skip, Answer Now's prompt and
/// Send (SettledClarify.LateSend), and every SettledQuestionsWalkProof check on the cards the chat's messages draw, here and
/// after a reload. What it can't show is the WinUI drawing (the transcript's card views, the dock's buttons, the bubble's
/// TextBlock): that is the walk's on Windows. Run through windows/scripts/e2e.sh; without it this passes vacuously.
[Trait("Category", "E2E")]
[Collection(QuestionsStandIn.Name)]
public class SettledQuestionsWalkStandInTests
{
    private static (string Url, string User, string Password)? Credentials()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_QUESTIONS_CREDENTIALS");
        if (path == null || !File.Exists(path)) return null;
        var j = JsonNode.Parse(File.ReadAllText(path))!;
        return (j.Str("url")!, j.Str("username")!, j.Str("password")!);
    }

    private static async Task Until(Func<bool> condition, string what, int seconds = 20)
    {
        var until = DateTime.UtcNow.AddSeconds(Math.Max(10, seconds));
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException($"{what} not met");
            await Task.Delay(50);
        }
    }

    /// Polls a check that answers null when so (≥ 10 s), failing with its last words.
    private static async Task Holds(Func<Task<string?>> check, string what)
    {
        string? wrong = "not read";
        for (var until = DateTime.UtcNow.AddSeconds(15); DateTime.UtcNow < until; await Task.Delay(100))
            if ((wrong = await check()) == null) return;
        Assert.Fail($"{what}: {wrong}");
    }

    private static async Task<JsonNode> Get(string url, string path)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url + path))!;
    }

    private static async Task<JsonNode?> Post(string url, string path, object? body = null)
    {
        using var http = new HttpClient();
        var content = new StringContent(System.Text.Json.JsonSerializer.Serialize(body ?? new { }), System.Text.Encoding.UTF8, "application/json");
        var response = await http.PostAsync(url + path, content);
        response.EnsureSuccessStatusCode();
        var text = await response.Content.ReadAsStringAsync();
        return text.Length == 0 ? null : JsonNode.Parse(text);
    }

    private static bool Replied(ChatSession chat, string words) =>
        !chat.Busy && chat.Messages.LastOrDefault(m => m.Role == Role.Assistant)?.Text.Contains(words) == true;

    /// The cards the transcript draws, in order, as the walk reads them (Answer Now where the card is answerable).
    private static List<Proof.CardSeen> Cards(IReadOnlyList<ChatMessage> messages)
    {
        var cards = new List<Proof.CardSeen>();
        foreach (var m in messages)
            foreach (var call in m.Tools.Where(t => t.Name == "clarify"))
                if (SettledClarify.Card(call, m, messages) is { } card)
                    cards.Add(new Proof.CardSeen(SettledClarify.Spoken(card), card.Answerable));
        return cards;
    }

    [Fact]
    public async Task TheWalksStepsHoldAgainstTheQuestionsStandIn()
    {
        if (Credentials() is not var (url, user, password)) return;
        await Post(url, "/__fixture/reset");
        // Signed in first, as the app is when its extra's walk starts.
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), user, password);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        var bot = (await client.BotsAsync()).First(b => b.Name == Proof.Bot);
        var other = (await client.BotsAsync()).First(b => b.Name == Proof.OtherBot);
        var before = await client.BotChatIdAsync(bot);

        // The fresh session, found as the walk finds it.
        var made = await Post(url, "/__fixture/history", new { profile = Proof.Bot, count = 0, new_session = true });
        var storedId = await client.BotChatIdAsync((await client.BotsAsync()).First(b => b.Name == Proof.Bot));
        Assert.Null(Proof.FreshSession(before, storedId, made?["session_id"]?.GetValue<string>()));
        Assert.NotEqual(storedId, await client.BotChatIdAsync(other));   // the walk's detour is another chat

        var chat = client.OpenChat(bot.Name, storedId, bot.DisplayName);
        using var link = client.Questions.Link(bot.Name);
        link.InterruptedProbe = () => chat.TurnInterrupted;
        chat.RuntimeBound += r => link.Bind(r, chat.StoredId);
        await chat.OpenAsync();
        Assert.Empty(chat.Messages);

        // 1. Answered in the live dock while the stand-in holds the tool; released.
        await Post(url, "/__fixture/config", new { clarify_hold = true });
        await chat.SendAsync(Proof.AnsweredPrompt);
        await Until(() => link.Prompts.Clarify != null, "the live dock");
        var live = link.Prompts.Clarify!;
        var question = Assert.Single(live.Questions);
        Assert.Equal(Proof.AnsweredQuestion, question.Question);
        var choice = question.Choices!.Single(c => ClarifyText.BareChoice(c) == Proof.AnsweredChoice);   // the row named "Lisbon"
        var stage = ClarifyStaging.Toggle(question, ClarifyStage.Empty, choice);
        await link.SendClarifyAsync(live.Id, [(question.Qid, ClarifyStaging.StagedAnswer(question, stage))]);
        await Holds(async () => Proof.AnsweredAndHeld(await Get(url, "/__fixture/requests")), "answered and held");
        Assert.Empty(Cards(chat.Messages));   // the tool hasn't ended: no settled card yet
        await Post(url, "/__fixture/config", new { clarify_hold = false });
        await Post(url, "/__fixture/release");
        await Until(() => Replied(chat, Proof.AnsweredReply), "the answered question's reply");
        await Until(() => link.Prompts.Clarify == null, "the dock gone");
        Assert.Null(Proof.Cards(Cards(chat.Messages), [Proof.Answered]));

        // From history (the walk goes to Sam's chat and back; here the chat is opened afresh): the same card.
        await chat.DisposeAsync();
        chat = client.OpenChat(bot.Name, storedId, bot.DisplayName);
        chat.RuntimeBound += r => link.Bind(r, chat.StoredId);
        await chat.OpenAsync();
        await Until(() => Cards(chat.Messages).Count == 1, "the answered card from history");
        Assert.Null(Proof.Cards(Cards(chat.Messages), [Proof.Answered]));

        // 2. Skipped: the card offers Answer Now.
        await chat.SendAsync(Proof.SkippedPrompt);
        await Until(() => link.Prompts.Clarify != null, "the second question's dock");
        Assert.Equal(Proof.SkippedQuestion, Assert.Single(link.Prompts.Clarify!.Questions).Question);
        await link.SkipClarifyAsync(link.Prompts.Clarify!.Id);
        await Until(() => Replied(chat, Proof.SkippedReply), "the skipped question's reply");
        Assert.Null(Proof.SkippedOnStandIn(await Get(url, "/__fixture/requests")));
        await Until(() => Cards(chat.Messages).Count == 2, "the skipped card");
        Assert.Null(Proof.Cards(Cards(chat.Messages), [Proof.Answered, Proof.Skipped]));

        // 3. Answer Now: its prompt asks the skipped question; the answer typed into its field.
        SettledClarifyCard Skipped() => chat.Messages.SelectMany(m => m.Tools.Where(t => t.Name == "clarify")
            .Select(t => SettledClarify.Card(t, m, chat.Messages))).OfType<SettledClarifyCard>().Last();
        var card = Skipped();
        var later = SettledClarify.LaterPrompt(card)!;
        var asked = Assert.Single(later.Questions);
        Assert.Equal(Proof.SkippedQuestion, asked.Question);
        Assert.Null(asked.Choices);
        Assert.Null(Proof.LaterDock(new Proof.DockSeen(asked.Question, [Proof.LaterSkip, Proof.SendTitle], SendEnabled: false), typed: false));
        var draft = new ClarifyDraft(0, new Dictionary<string, ClarifyStage> { [asked.Qid] = ClarifyStage.Empty with { Draft = Proof.LateAnswer } });
        Assert.True(SettledClarify.HasAnswers(draft));   // Send can be pressed

        // 4. Send: the card's message in the chat; the bubble reads the answer alone; the card is answered later.
        var plan = SettledClarify.LateSend(card, later, draft, chat.Messages);
        Assert.True(plan.Close);
        Assert.Equal(Proof.LateMessage, plan.Text);
        var count = chat.Messages.Count;
        await chat.SendAsync(plan.Text!);
        await Holds(async () => Proof.LateSent(await Get(url, "/__fixture/state"), await Get(url, "/__fixture/requests")), "the late answer sent");
        await Until(() => !chat.Busy && chat.Messages.Count > count + 1 && chat.Messages[^1].Role == Role.Assistant, "the reply to the late answer");
        Assert.Null(Proof.Cards(Cards(chat.Messages), [Proof.Answered, Proof.AnsweredLater]));
        var mine = chat.Messages.Last(m => m.Role == Role.User);
        Assert.Null(Proof.BubbleShowsAnswersAlone([ClarifyLate.BubbleWords(mine.Text) ?? mine.Text]));

        // 5. Opened again: both cards and the bubble from history.
        await chat.DisposeAsync();
        await using var again = client.OpenChat(bot.Name, storedId, bot.DisplayName);
        await again.OpenAsync();
        await Until(() => Cards(again.Messages).Count == 2, "both cards from history");
        Assert.Null(Proof.Cards(Cards(again.Messages), [Proof.Answered, Proof.AnsweredLater]));
        var reloaded = again.Messages.Last(m => m.Role == Role.User);
        Assert.Equal(Proof.LateMessage, reloaded.Text);
        Assert.Null(Proof.BubbleShowsAnswersAlone([ClarifyLate.BubbleWords(reloaded.Text) ?? reloaded.Text]));
    }
}
