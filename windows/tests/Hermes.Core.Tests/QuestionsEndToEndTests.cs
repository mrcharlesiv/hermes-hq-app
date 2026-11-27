using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Questions;
using Hermes.Core.Rpc;

namespace Hermes.Core.Tests;

/// Approvals, questions and password prompts against scripts/fixtures/questions-gateway.py (spec 1x §6, §7.2). Run
/// through windows/scripts/e2e.sh, which starts the fixture and sets HQW_E2E_QUESTIONS_CREDENTIALS; without it these
/// tests pass vacuously.
[Trait("Category", "E2E")]
[Collection(QuestionsStandIn.Name)]   // [WIN-QUESTIONS-SETTLED-WALK] one stand-in, shared with SettledQuestionsWalkStandInTests
public class QuestionsEndToEndTests
{
    private static (string Url, string User, string Password)? Credentials()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_QUESTIONS_CREDENTIALS");
        if (path == null || !File.Exists(path)) return null;
        var j = JsonNode.Parse(File.ReadAllText(path))!;
        return (j.Str("url")!, j.Str("username")!, j.Str("password")!);
    }

    private static async Task Until(Func<bool> condition, int seconds = 20, string what = "condition")
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException($"{what} not met");
            await Task.Delay(50);
        }
    }

    private static async Task<JsonNode> Ledger(string url)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url + "/__fixture/requests"))!;
    }

    private static async Task Post(string url, string path, object? body = null)
    {
        using var http = new HttpClient();
        var content = new StringContent(System.Text.Json.JsonSerializer.Serialize(body ?? new { }),
            System.Text.Encoding.UTF8, "application/json");
        (await http.PostAsync(url + path, content)).EnsureSuccessStatusCode();
    }

    private static bool Replied(ChatSession chat, string words) =>
        !chat.Busy && chat.Messages.LastOrDefault(m => m.Role == Role.Assistant)?.Text.Contains(words) == true;

    // Notification actions are checked as data in ToastCenterTests, not answered through a gateway.

    /// [WIN-QUESTIONS-SETTLED-ANSWER-NOW] A skipped question's settled card (the clarify tool's `responses`, live and in
    /// history) offers Answer Now; its Send goes into the chat as a message naming the card (ClarifyLate.Message), and
    /// the card then shows the answer, here and after a reload.
    [Fact]
    public async Task ASkippedQuestionIsAnsweredNowFromItsSettledCard()
    {
        if (Credentials() is not var (url, user, password)) return;
        await Post(url, "/__fixture/reset");
        // Its own chat: /__fixture/reset keeps the bot's history, so in the shared one the first settled card (and the
        // message count) would be an earlier test's. A new, empty session is this test's alone.
        await Post(url, "/__fixture/history", new { profile = "default", count = 0, new_session = true });
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), user, password);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        var bot = (await client.BotsAsync()).First(b => b.Name == "default");
        var chatId = await client.BotChatIdAsync(bot);
        await using var chat = client.OpenChat(bot.Name, chatId, bot.DisplayName);
        using var link = client.Questions.Link(bot.Name);
        link.InterruptedProbe = () => chat.TurnInterrupted;
        chat.RuntimeBound += r => link.Bind(r, chat.StoredId);
        await chat.OpenAsync();

        await chat.SendAsync("one");
        await Until(() => link.Prompts.Clarify != null, what: "clarify dock");
        await link.SkipClarifyAsync(link.Prompts.Clarify!.Id);
        await Until(() => Replied(chat, "Questions skipped."), what: "skip reply");

        SettledClarifyCard? Card(IReadOnlyList<ChatMessage> messages)
        {
            foreach (var m in messages)
                foreach (var call in m.Tools.Where(t => t.Name == "clarify"))
                    if (SettledClarify.Card(call, m, messages) is { } card) return card;
            return null;
        }
        await Until(() => Card(chat.Messages) != null, what: "settled card");
        var open = Card(chat.Messages)!;
        Assert.True(open.Answerable);
        Assert.False(open.AnsweredLater);
        Assert.Equal("Which city should I book?", open.Rows[0].Question);
        Assert.Equal(["Lisbon", "Porto"], open.Rows[0].Choices!);
        Assert.Equal(("Question skipped", true), SettledClarify.Header(open));

        var prompt = SettledClarify.LaterPrompt(open)!;
        var draft = new ClarifyDraft(0, new Dictionary<string, ClarifyStage> { ["q0"] = new(["Porto"]) });
        var plan = SettledClarify.LateSend(open, prompt, draft, chat.Messages);
        Assert.True(plan.Close);
        Assert.Equal(open.MessageId, plan.MessageId);
        Assert.Equal(ClarifyLate.Message(open.Key, [("Which city should I book?", "Porto")]), plan.Text);
        var before = chat.Messages.Count;
        await chat.SendAsync(plan.Text!);
        await Until(() => !chat.Busy && chat.Messages.Count > before + 1 && chat.Messages[^1].Role == Role.Assistant, what: "late answer reply");
        var answered = Card(chat.Messages)!;
        Assert.False(answered.Answerable);
        Assert.True(answered.AnsweredLater);
        Assert.Equal("Porto", answered.Rows[0].Answer);
        Assert.Equal(("Answered later", false), SettledClarify.Header(answered));

        // A reload: the history's tool row carries the responses, your message the answer; the card is filled.
        await using var again = client.OpenChat(bot.Name, chatId, bot.DisplayName);
        await again.OpenAsync();
        await Until(() => Card(again.Messages) is { AnsweredLater: true }, what: "reloaded card answered later");
        var mine = again.Messages.Last(m => m.Role == Role.User);
        Assert.Equal(plan.Text, mine.Text);
        Assert.Equal("Porto", ClarifyLate.BubbleWords(mine.Text));
    }

    [Fact]
    public async Task ApprovalsQuestionsAndPasswordsRoundTrip()
    {
        if (Credentials() is not var (url, user, password)) return;
        await Post(url, "/__fixture/reset");
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), user, password);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);

        var bot = (await client.BotsAsync()).First(b => b.Name == "default");
        await using var chat = client.OpenChat(bot.Name, await client.BotChatIdAsync(bot), bot.DisplayName);
        using var link = client.Questions.Link(bot.Name);
        link.InterruptedProbe = () => chat.TurnInterrupted;
        chat.RuntimeBound += r => link.Bind(r, chat.StoredId);
        var waiting = new List<NeedsInput?>();
        client.Questions.NeedsInputChanged += (_, profile, _, kind) => { if (profile == "default") lock (waiting) waiting.Add(kind); };
        await chat.OpenAsync();
        Assert.NotNull(chat.RuntimeId);

        // client.capabilities is the first frame on the socket (spec 1x §2.1).
        var sockets = (await Ledger(url)).Arr("sockets")!;
        var socket = sockets.Last()!;
        Assert.True(socket.Bool("advertised"));
        Assert.Equal("client.capabilities", socket.Arr("frames")![0]!.GetValue<string>());
        await Until(() => client.Rpc.DeclinesNotShown, what: "declines_not_shown");

        // An approval: the card, Run, and the command runs.
        await chat.SendAsync("please approve");
        await Until(() => link.Prompts.Approvals.Count == 1, what: "approval card");
        var approval = link.Prompts.Approvals[0];
        Assert.StartsWith("srq-", approval.Id);
        Assert.Equal("git push --force origin main", approval.Command);
        Assert.True(approval.AllowSession && approval.AllowAlways);
        Assert.Equal(NeedsInput.Approval, link.Prompts.NeedsInput);
        Assert.Equal(TimeSpan.FromSeconds(300), await link.ApprovalTimeoutAsync(false));
        await link.AnswerApprovalAsync(approval.Id, ApprovalChoice.Once);
        await Until(() => Replied(chat, "Approval answered: once."), what: "approval reply");
        await Until(() => link.Prompts.Approvals.Count == 0, what: "card gone");
        lock (waiting) Assert.Equal([NeedsInput.Approval, null], waiting.Take(2));

        // Three questions: one clarify.lock each, in order; no response frame. The stand-in holds the clarify tool's end
        // (clarify_hold) until the sent rows are checked: otherwise its tool.complete races the last lock's reply and
        // can clear them before the check (or land first and leave them stale).
        await Post(url, "/__fixture/config", new { clarify_hold = true });
        await chat.SendAsync("ask me");
        await Until(() => link.Prompts.Clarify != null, what: "clarify dock");
        var clarify = link.Prompts.Clarify!;
        Assert.Equal(3, clarify.Questions.Count);
        Assert.Equal(NeedsInput.Reply, link.Prompts.NeedsInput);
        var picks = new Dictionary<string, ClarifyStage>
        {
            ["q0"] = new(["main (Recommended)"]),
            ["q1"] = new(["Lint"], "skip the changelog", true),
        };
        link.SaveClarifyDraft(clarify.Id, new ClarifyDraft(2, picks));
        var answers = clarify.Questions.Select(q => (q.Qid, ClarifyStaging.StagedAnswer(q, picks.GetValueOrDefault(q.Qid)))).ToList();
        await link.SendClarifyAsync(clarify.Id, answers);
        Assert.Equal("Lint, skip the changelog", link.Prompts.SentClarify!.Rows[1].Answer);
        await Post(url, "/__fixture/config", new { clarify_hold = false });
        await Post(url, "/__fixture/release");
        await Until(() => Replied(chat, "Thanks, I have your answers."), what: "clarify reply");
        var ledger = await Ledger(url);
        var locks = ledger.Arr("rpc")!.Where(r => r.Str("method") == "clarify.lock").Select(r => r!["params"]!).ToList();
        Assert.Equal(["q0", "q1", "q2"], locks.Select(l => l.Str("question_id")));
        Assert.Equal("main", locks[0].Str("answer"));
        Assert.Equal("""["Lint","skip the changelog"]""", locks[1].Str("answer"));
        Assert.Null(locks[2]["answer"]);
        Assert.Null(link.Prompts.SentClarify); // the clarify tool finished

        // A question skipped: {"result":{}}.
        await chat.SendAsync("one");
        await Until(() => link.Prompts.Clarify != null, what: "second clarify");
        await link.SkipClarifyAsync(link.Prompts.Clarify!.Id);
        await Until(() => Replied(chat, "Questions skipped."), what: "skip reply");

        // A secret: {"value": …}.
        await chat.SendAsync("secret");
        await Until(() => link.Prompts.Values.Count == 1, what: "secret sheet");
        var secret = link.Prompts.Values[0];
        Assert.Equal(PromptKind.Secret, secret.Kind);
        Assert.Equal("OPENWEATHER_API_KEY requested", PromptSheetCopy.Make(secret, bot.DisplayName).Chip);
        await link.AnswerValueAsync(secret.Id, "k-123");
        await Until(() => Replied(chat, "Received 5 characters."), what: "secret reply");

        // A desktop pane: declined with 4404, so the tool settles at once instead of timing out.
        await chat.SendAsync("terminal");
        await Until(() => Replied(chat, "terminal.read: declined."), seconds: 6, what: "4404 decline");
        // setup_choose: -32601, unanswered.
        await chat.SendAsync("setup");
        await Until(() => Replied(chat, "setup_choose: unanswered."), seconds: 6, what: "-32601 refusal");
        Assert.True(link.Prompts.IsEmpty);

        // Reconnect: a sudo prompt survives a dropped socket (re-delivered by session.activate's open_requests) and is
        // answered on the new socket.
        await chat.SendAsync("sudo");
        await Until(() => link.Prompts.Values.Count == 1, what: "sudo sheet");
        var sudo = link.Prompts.Values[0];
        var epoch = client.Rpc.SocketEpoch;
        await Post(url, "/__fixture/kick");
        await Until(() => client.Rpc.SocketEpoch > epoch && client.Rpc.State == ConnectionState.Open, what: "reconnect");
        await Until(() => (Ledger(url).Result.Arr("sockets")!.Last()!.Arr("frames") ?? []).Any(f => f!.GetValue<string>() == "session.activate"),
            what: "re-activate");
        await Task.Delay(300);
        Assert.Equal(sudo.Id, Assert.Single(link.Prompts.Values).Id);
        await link.AnswerValueAsync(sudo.Id, "pw");
        await Until(() => Replied(chat, "Received 2 characters."), what: "sudo reply after reconnect");
        var newest = (await Ledger(url)).Arr("sockets")!.Last()!;
        Assert.True(newest.Bool("advertised"));
        Assert.Equal("client.capabilities", newest.Arr("frames")![0]!.GetValue<string>());

        // An approval answered by another client: the card goes when the turn moves on (probe, §3.5).
        await chat.SendAsync("approve");
        await Until(() => link.Prompts.Approvals.Count == 1, what: "approval for another client");
        await Post(url, "/__fixture/answer", new { id = link.Prompts.Approvals[0].Id, result = new { choice = "deny" } });
        await Until(() => Replied(chat, "Approval answered: deny."), what: "answered elsewhere");
        await Until(() => link.Prompts.Approvals.Count == 0, what: "card pruned");

        Assert.Empty((await Ledger(url)).Arr("errors4000")!);
    }
}
