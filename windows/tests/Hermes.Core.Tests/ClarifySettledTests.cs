using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Questions;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-QUESTIONS-SETTLED-ANSWER-NOW] The settled Q&A card in history and Answer Now on it, from the Mac at 93f984bb1:
/// HermesKit/Chat/PromptLogic.swift (`ClarifySettled.parse`, `ClarifyLate`), App/Questions/PromptRows.swift
/// (`settledCard`, `multiSelect`, `answersTitle`, the qa rows' words), App/Questions/ChatPromptsController.swift
/// (`answerLater`, `keepAnswering`, `hasAnswers`, `sendLater`) and ChatViewController+Prompts.swift (`settledClarify`).
public class ClarifySettledTests
{
    private const string Result = """
        {"responses":[
          {"question":"Which branch?","choices_offered":["main","staging"],"status":"answered","user_response":"main"},
          {"question":"Skip?","choices_offered":["Tests","Lint"],"status":"answered","user_response":["Lint","docs too"]},
          {"question":"Name?","choices_offered":null,"status":"unanswered","user_response":null},
          {"question":"Other?","choices_offered":null,"status":"skipped","user_response":null}
        ],"outcome":"submitted"}
        """;

    private static ChatMessage User(string text, string id = "u") => new(id, Role.User, [new TextPart(text)]);

    private static ChatMessage Reply(string id, ToolCall call) => new(id, Role.Assistant, [new ToolPart(call)]);

    private static ToolCall Clarify(string result, string? args = null, ToolState state = ToolState.Done) =>
        new("c1", "clarify", null, null, state, ArgsJson: args, ResultText: result);

    private static string Responses(params (string Question, string? Answer, string Status, string[]? Choices)[] rows) =>
        new JsonObject
        {
            ["responses"] = new JsonArray([.. rows.Select(r => (JsonNode)new JsonObject
            {
                ["question"] = r.Question, ["user_response"] = r.Answer, ["status"] = r.Status,
                ["choices_offered"] = r.Choices == null ? null : new JsonArray([.. r.Choices.Select(c => (JsonNode)c)]),
            })]),
        }.ToJsonString();

    [Fact]
    public void ParsesTheToolResultsResponses()
    {
        var rows = ClarifySettled.Parse(Result)!;
        Assert.Equal(4, rows.Count);
        Assert.Equal(("Which branch?", "main", false), (rows[0].Question, rows[0].Answer, rows[0].Unanswered));
        Assert.Equal(["main", "staging"], rows[0].Choices!);
        Assert.Equal(("Skip?", "Lint, docs too", false), (rows[1].Question, rows[1].Answer, rows[1].Unanswered));
        Assert.Equal(("Name?", "", true), (rows[2].Question, rows[2].Answer, rows[2].Unanswered));
        Assert.Null(rows[2].Choices);
        Assert.Equal(("Other?", "", false), (rows[3].Question, rows[3].Answer, rows[3].Unanswered));
        Assert.Null(ClarifySettled.Parse("""{"stdout":"x"}"""));
        Assert.Null(ClarifySettled.Parse("not json"));
        Assert.Null(ClarifySettled.Parse(null));
        // A number or a bool answer reads as its JSON.
        Assert.Equal("3", ClarifySettled.Parse("""{"responses":[{"question":"How many?","user_response":3}]}""")![0].Answer);
    }

    [Fact]
    public void HistoryFoldsTheClarifyResultIntoTheCall()
    {
        var rows = new JsonArray
        {
            new JsonObject { ["role"] = "user", ["content"] = "ask", ["id"] = 1, ["timestamp"] = 1_790_852_400 },
            new JsonObject
            {
                ["role"] = "assistant", ["content"] = "", ["id"] = 2, ["timestamp"] = 1_790_852_401,
                ["tool_calls"] = new JsonArray { new JsonObject { ["id"] = "clarify-1", ["type"] = "function",
                    ["function"] = new JsonObject { ["name"] = "clarify", ["arguments"] = "{}" } } },
            },
            new JsonObject { ["role"] = "tool", ["content"] = Result, ["id"] = 3, ["tool_call_id"] = "clarify-1", ["timestamp"] = 1_790_852_402 },
        };
        var call = HistoryFold.Fold(rows).SelectMany(m => m.Tools).Single(t => t.Name == "clarify");
        Assert.Equal("main", ClarifySettled.Parse(call.ResultText)![0].Answer);
    }

    [Fact]
    public void TheMessageNamesTheCardAndReadsBack()
    {
        var key = ClarifyLate.Key(["May I spend\nmore credits?", "Which cut?"]);
        Assert.Matches("^q-[0-9a-f]{8}$", key);
        Assert.Equal(key, ClarifyLate.Key(["May I spend more credits?", "Which cut?"]));
        Assert.NotEqual(key, ClarifyLate.Key(["May I spend more credits?"]));
        // FNV-1a 32 over the UTF-8 of the questions on one line, joined by a line feed (ChatText.fnv1a).
        Assert.Equal("q-e40c292c", ClarifyLate.Key(["a"]));
        var text = ClarifyLate.Message(key, [("May I spend\nmore credits?", "Yes, go ahead"), ("Which cut?", "The short one")]);
        Assert.StartsWith($"[Hermes HQ question {key}: answer]\nMy answers to the questions you asked earlier, which went unanswered:\n\n", text);
        Assert.Contains("Q: May I spend more credits?\nA: Yes, go ahead\n\nQ: Which cut?\nA: The short one", text);
        var found = ClarifyLate.Answer(text)!.Value;
        Assert.Equal(key, found.Key);
        Assert.Equal(new Dictionary<string, string> { ["May I spend more credits?"] = "Yes, go ahead", ["Which cut?"] = "The short one" }, found.Answers);
        Assert.Equal("Yes, go ahead\nThe short one", ClarifyLate.BubbleWords(text));
        Assert.Null(ClarifyLate.Answer("Yes you can proceed."));
        Assert.Null(ClarifyLate.BubbleWords("[Hermes HQ question nope: answer]"));
        var one = ClarifyLate.Message(key, [("Proceed?", "Yes\nbut slowly")]);
        Assert.Contains("My answer to the question you asked earlier, which went unanswered:", one);
        Assert.Equal("Yes\nbut slowly", ClarifyLate.BubbleWords(one));
    }

    [Fact]
    public void AnswersFillTheCardsBlanks()
    {
        IReadOnlyList<ClarifyQA> rows = [new("Proceed?", "", true, ["Yes", "No"]), new("Name?", "Ivy", false)];
        var key = ClarifyLate.Key(rows.Select(r => r.Question));
        var found = ClarifyLate.Answers([User("hello", "a"), User(ClarifyLate.Message(key, [("Proceed?", "Yes")]), "b")]);
        Assert.Equal(1, found[key].Index);
        var (filled, later) = ClarifyLate.Filled(rows, found[key]);
        Assert.True(later);
        Assert.Equal(("Yes", false), (filled[0].Answer, filled[0].Unanswered));
        Assert.Equal("Ivy", filled[1].Answer);
        Assert.False(ClarifyLate.Filled(rows, null).Later);
        // A queued answer counts, and is newest.
        var queued = ClarifyLate.Answers([User("hello")], [ClarifyLate.Message(key, [("Proceed?", "No")])]);
        Assert.Equal(int.MaxValue, queued[key].Index);
        Assert.Equal("No", queued[key].Answers["Proceed?"]);
    }

    [Fact]
    public void ASettledCardOffersAnswerNowUntilTheAnswerComesLater()
    {
        var user = User("ask me", "u1");
        var answeredCall = Clarify(Responses(("Which?", "main", "answered", null)));
        var answered = SettledClarify.Card(answeredCall, Reply("a1", answeredCall), [user, Reply("a1", answeredCall)])!;
        Assert.Equal("main", answered.Rows[0].Answer);
        Assert.False(answered.Answerable);
        Assert.False(answered.AnsweredLater);
        Assert.Equal(("Your answer", false), SettledClarify.Header(answered));

        var skippedCall = Clarify(Responses(("Proceed?", null, "unanswered", ["Yes", "No"])));
        var settled = Reply("a1", skippedCall);
        var open = SettledClarify.Card(skippedCall, settled, [user, settled])!;
        Assert.True(open.Answerable);
        Assert.False(open.AnsweredLater);
        Assert.Equal(["Yes", "No"], open.Rows[0].Choices!);
        Assert.Equal("a1", open.MessageId);
        Assert.Equal(("Question skipped", true), SettledClarify.Header(open));
        Assert.Equal("No answer", SettledClarify.Words(open.Rows[0]));
        Assert.Equal("Question skipped. Proceed?: No answer", SettledClarify.Spoken(open));

        var lateReply = User(ClarifyLate.Message(open.Key, [("Proceed?", "Yes")]), "u2");
        var filled = SettledClarify.Card(skippedCall, settled, [user, settled, lateReply])!;
        Assert.False(filled.Answerable);
        Assert.True(filled.AnsweredLater);
        Assert.Equal("Yes", filled.Rows[0].Answer);
        Assert.Equal(("Answered later", false), SettledClarify.Header(filled));
        // An answer from before the card doesn't count (the same question asked again).
        Assert.True(SettledClarify.Card(skippedCall, settled, [lateReply, user, settled])!.Answerable);
        // Not in a room (its sends go to its members).
        Assert.False(SettledClarify.Card(skippedCall, settled, [user, settled], room: true)!.Answerable);
        // A running clarify, or a result with no responses, draws no card (the note or the step line).
        Assert.Null(SettledClarify.Card(skippedCall with { State = ToolState.Running }, settled, [user, settled]));
        Assert.Null(SettledClarify.Card(Clarify("""{"error":"timed out"}"""), settled, [user, settled]));
        Assert.Null(SettledClarify.Card(skippedCall with { Name = "terminal" }, settled, [user, settled]));

        var two = Clarify(Responses(("A?", null, "unanswered", null), ("B?", "b", "answered", null)));
        var twoMsg = Reply("a2", two);
        var someLater = SettledClarify.Card(two, twoMsg, [twoMsg, User(ClarifyLate.Message(ClarifyLate.Key(["A?", "B?"]), [("A?", "a")]))])!;
        Assert.Equal(("Your answers, some later", false), SettledClarify.Header(someLater));
        Assert.Equal(("Your answers", false), SettledClarify.Header(SettledClarify.Card(two, twoMsg, [twoMsg])!));
        Assert.Equal("Skipped", SettledClarify.Words(new ClarifyQA("Other?", "", false)));
        Assert.Equal("Answers the question now, in the chat", SettledClarify.AnswerNowHint(open));
        Assert.Equal("Answers the questions now, in the chat", SettledClarify.AnswerNowHint(someLater));
        Assert.Equal("Answer Now", SettledClarify.AnswerNowTitle);
    }

    [Fact]
    public void MultiSelectIsReadFromTheCallsArguments()
    {
        var args = """{"questions":[{"question":"Pick\nany?","choices":["a","b"],"multi_select":true},{"question":"One?","multi_select":false}]}""";
        Assert.Equal(["Pick any?"], SettledClarify.MultiSelect(args).ToList());
        Assert.Empty(SettledClarify.MultiSelect("""{"questions":[{"question":"x"}]}"""));
        Assert.Empty(SettledClarify.MultiSelect(null));
        Assert.Empty(SettledClarify.MultiSelect("not json multi_select"));
    }

    [Fact]
    public void AnswerNowAsksTheOpenQuestionsWithTheChoicesTheyOffered()
    {
        var call = Clarify(Responses(("Done?", "yes", "answered", null), ("Pick\nany?", null, "unanswered", ["a", "b"]), ("Why?", null, "skipped", null)),
            args: """{"questions":[{"question":"Pick any?","choices":["a","b"],"multi_select":true}]}""");
        var msg = Reply("a1", call);
        var card = SettledClarify.Card(call, msg, [msg])!;
        var prompt = SettledClarify.LaterPrompt(card)!;
        Assert.Equal($"late|{card.Key}", prompt.Id);
        Assert.Equal(["q0", "q1"], prompt.Questions.Select(q => q.Qid));
        Assert.Equal(["Pick\nany?", "Why?"], prompt.Questions.Select(q => q.Question));
        Assert.Equal(["a", "b"], prompt.Questions[0].Choices!);
        Assert.True(prompt.Questions[0].MultiSelect);
        Assert.Null(prompt.Questions[1].Choices);
        Assert.False(prompt.Questions[1].MultiSelect);
        Assert.Empty(prompt.LockedAnswers);
        // Nothing open: no dock.
        var done = Clarify(Responses(("Done?", "yes", "answered", null)));
        Assert.Null(SettledClarify.LaterPrompt(SettledClarify.Card(done, Reply("a3", done), [Reply("a3", done)])!));
    }

    [Fact]
    public void SendPutsTheTypedAnswersInTheChatNamingTheCard()
    {
        var call = Clarify(Responses(("Proceed?", null, "unanswered", ["Yes", "No"]), ("Name?", null, "unanswered", null)));
        var msg = Reply("a1", call);
        var card = SettledClarify.Card(call, msg, [msg])!;
        var prompt = SettledClarify.LaterPrompt(card)!;
        // Nothing typed: Send does nothing and the dock stays.
        var none = SettledClarify.LateSend(card, prompt, ClarifyDraft.Empty, [msg]);
        Assert.False(none.Close);
        Assert.Null(none.Text);
        var draft = new ClarifyDraft(0, new Dictionary<string, ClarifyStage> { ["q0"] = new(["Yes"]), ["q1"] = new([], "   ") });
        var plan = SettledClarify.LateSend(card, prompt, draft, [msg]);
        Assert.True(plan.Close);
        Assert.Equal(ClarifyLate.Message(card.Key, [("Proceed?", "Yes")]), plan.Text);
        Assert.Equal("a1", plan.MessageId);
    }

    [Fact]
    public void AClarifyThatEndedUnsentWithAnswersTypedIsKeptAsAnswerNows()
    {
        ClarifyQuestion[] questions = [new("qa", "Proceed?", ["Yes", "No"], false), new("qb", "Which\nones?", ["x", "y"], true)];
        var gone = new ClarifyPrompt("req-1", questions, new Dictionary<string, string?>(), false);
        Assert.False(SettledClarify.HasAnswers(ClarifyDraft.Empty));
        Assert.False(SettledClarify.HasAnswers(new ClarifyDraft(0, new Dictionary<string, ClarifyStage> { ["qa"] = new([], "  \n") })));
        var typed = new ClarifyDraft(1, new Dictionary<string, ClarifyStage> { ["qa"] = new([], "Not yet", true) });
        Assert.True(SettledClarify.HasAnswers(typed));
        Assert.True(SettledClarify.HasAnswers(new ClarifyDraft(0, new Dictionary<string, ClarifyStage> { ["qb"] = new(["x"]) })));

        var (card, prompt) = SettledClarify.Kept(gone);
        Assert.Equal(ClarifyLate.Key(["Proceed?", "Which\nones?"]), card.Key);
        Assert.Equal("", card.MessageId);
        Assert.True(card.Answerable);
        Assert.Equal(["Which ones?"], card.Multi.ToList());
        Assert.All(card.Rows, r => Assert.True(r.Unanswered));
        Assert.Equal($"late|{card.Key}", prompt.Id);
        Assert.Equal(["qa", "qb"], prompt.Questions.Select(q => q.Qid));   // the same questions: the typed draft fits

        // Send: its settled card arrived with the question still blank: the answer goes, naming that card.
        var settledCall = Clarify(Responses(("Proceed?", null, "unanswered", ["Yes", "No"]), ("Which\nones?", null, "unanswered", ["x", "y"])));
        var settled = Reply("a9", settledCall);
        var plan = SettledClarify.LateSend(card, prompt, typed, [User("hi"), settled]);
        Assert.True(plan.Close);
        Assert.Equal("a9", plan.MessageId);
        Assert.Equal(ClarifyLate.Message(card.Key, [("Proceed?", "Not yet")]), plan.Text);
        // Its card has no card yet: the answer still goes.
        Assert.Equal(ClarifyLate.Message(card.Key, [("Proceed?", "Not yet")]), SettledClarify.LateSend(card, prompt, typed, [User("hi")]).Text);
        // Answered on the live request (another device): nothing more to send, and the dock closes.
        var allCall = Clarify(Responses(("Proceed?", "No", "answered", null), ("Which\nones?", "x", "answered", null)));
        var gotIt = SettledClarify.LateSend(card, prompt, typed, [Reply("a10", allCall)]);
        Assert.True(gotIt.Close);
        Assert.Null(gotIt.Text);
    }

    [Fact]
    public void TheNewestSettledCardForTheQuestionsIsFound()
    {
        var a = Clarify(Responses(("Proceed?", "Yes", "answered", null)));
        var b = Clarify(Responses(("Proceed?", null, "unanswered", null)));
        var key = ClarifyLate.Key(["Proceed?"]);
        Assert.Equal(("a2", true), SettledClarify.Find([Reply("a1", a), Reply("a2", b)], key));
        Assert.Equal(("a1", false), SettledClarify.Find([Reply("a2", b), Reply("a1", a)], key));
        Assert.Null(SettledClarify.Find([User("x")], key));
    }

    // ------------------------------------------------------------------ the WinUI side, held to the rules in source

    private static string Source(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine([dir, "src", "HermesHQ.Windows", .. parts])).Replace("\r\n", "\n");
    }

    [Fact]
    public void TheTranscriptDrawsTheSettledCardWithAnswerNow()
    {
        var feature = Source("Features", "Questions", "QuestionsFeature.cs");
        Assert.Matches(@"ChatExtensions\.ToolRenderers\[""clarify""\] = QuestionsChat\.SettledCard;", feature);
        var chat = Source("Features", "Questions", "QuestionsChat.cs");
        Assert.Contains("SettledClarify.Card(call, message, messages, room: owner == null)", chat);
        Assert.Contains("ClarifyNote.Settled(card,", chat);
        var note = Source("Features", "Questions", "ClarifyNote.cs");
        Assert.Contains("SettledClarify.AnswerNowTitle", note);
        Assert.Contains("\"clarify.answerNow\"", note);
        Assert.Contains("SettledClarify.AnswerNowHint(card)", note);
        Assert.Contains("SettledClarify.Header(card)", note);
        Assert.Contains("SettledClarify.Words(", note);
        Assert.Contains("if (card.Answerable", note);
        // Your bubble reads as the answers alone.
        var bubble = Source("Controls", "MessageView.cs");
        Assert.Contains("ClarifyLate.BubbleWords(item.Text) ?? item.Text", bubble);
    }

    [Fact]
    public void AnswerNowOpensALaterDockWhoseSendGoesIntoTheChat()
    {
        var chat = Source("Features", "Questions", "QuestionsChat.cs");
        var later = Regex.Match(chat, @"internal void AnswerLater\(SettledClarifyCard card\)\n    \{(?<b>.*?)\n    \}", RegexOptions.Singleline);
        Assert.True(later.Success);
        Assert.Contains("_prompts.Clarify != null", later.Groups["b"].Value);   // a live question owns the dock
        Assert.Contains("SettledClarify.LaterPrompt(card)", later.Groups["b"].Value);
        Assert.Contains("later: true", later.Groups["b"].Value);
        Assert.Contains("SettledClarify.LateSend(card, dock.Prompt, dock.Draft,", chat);
        Assert.Contains("SettledClarify.Kept(gone.Prompt)", chat);
        Assert.Contains("SettledClarify.HasAnswers(gone.Draft)", chat);
        Assert.Contains("ClarifyLate.Signature(", chat);   // a later answer redraws its card
        var dock = Source("Features", "Questions", "QuestionDock.cs");
        Assert.Contains("later ? \"Cancel\"", dock);
    }
}
