using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Model;
using Hermes.Core.Questions;
using Hermes.Core.Shell;
using Proof = Hermes.Core.Shell.SettledQuestionsWalkProof;

namespace Hermes.Core.Tests;

/// [WIN-QUESTIONS-SETTLED-WALK] The checks behind the questions-settled walk (HermesHQ.Windows
/// Services/ProofWalks.SettledQuestions.cs) and its wiring: the words it sends make questions-gateway.py ask the questions
/// it expects; the app registers it and takes every picture. All data synthetic. Source reads are CRLF-normalised (the
/// Windows runner checks the tree out with CRLF). SettledQuestionsWalkStandInTests runs the same steps against the stand-in.
public class SettledQuestionsWalkProofTests
{
    // ------------------------------------------------------------------ the cards (the Mac's words)

    [Fact]
    public void TheCardsReadAsTheMacs()
    {
        Assert.Equal(new Proof.CardSeen("Your answer. Which city should I book?: Lisbon", false), Proof.Answered);
        Assert.Equal(new Proof.CardSeen("Question skipped. What should I name the new project?: No answer", true), Proof.Skipped);
        Assert.Equal(new Proof.CardSeen("Answered later. What should I name the new project?: Harbor Lights", false), Proof.AnsweredLater);
    }

    [Fact]
    public void CardsMustBeExactlyTheExpectedOnesInOrder()
    {
        Assert.Null(Proof.Cards([Proof.Answered, Proof.Skipped], [Proof.Answered, Proof.Skipped]));
        Assert.Equal("the chat's settled cards are none, not \u201CYour answer. Which city should I book?: Lisbon\u201D",
            Proof.Cards([], [Proof.Answered]));
        // Out of order, one missing, Answer Now missing, Answer Now on an answered card: each is wrong.
        Assert.NotNull(Proof.Cards([Proof.Skipped, Proof.Answered], [Proof.Answered, Proof.Skipped]));
        Assert.NotNull(Proof.Cards([Proof.Answered], [Proof.Answered, Proof.Skipped]));
        Assert.Contains("+ Answer Now", Proof.Cards([Proof.Answered, Proof.Skipped with { AnswerNow = false }], [Proof.Answered, Proof.Skipped]));
        Assert.NotNull(Proof.Cards([Proof.Answered, Proof.AnsweredLater with { AnswerNow = true }], [Proof.Answered, Proof.AnsweredLater]));
    }

    [Fact]
    public void TheCardsMatchWhatSettledClarifyDrawsFromTheStandInsResult()
    {
        // The stand-in's clarify_result for the skipped question (status `unanswered`), as the app parses it.
        var skipped = """{"responses":[{"question":"What should I name the new project?","choices_offered":null,"status":"unanswered","user_response":null}],"outcome":"cancelled"}""";
        var call = new ToolCall("c1", "clarify", null, null, ToolState.Done,
            ArgsJson: """{"questions":[{"question":"What should I name the new project?","choices":null,"multi_select":false}]}""", ResultText: skipped);
        var reply = new ChatMessage("a1", Role.Assistant, [new ToolPart(call)]);
        var asked = new ChatMessage("u1", Role.User, [new TextPart(Proof.SkippedPrompt)]);
        var card = SettledClarify.Card(call, reply, [asked, reply])!;
        Assert.Equal(Proof.Skipped, new Proof.CardSeen(SettledClarify.Spoken(card), card.Answerable));

        // Answer Now's message after it: the same card, answered later.
        var later = SettledClarify.Card(call, reply, [asked, reply, new ChatMessage("u2", Role.User, [new TextPart(Proof.LateMessage)])])!;
        Assert.Equal(Proof.AnsweredLater, new Proof.CardSeen(SettledClarify.Spoken(later), later.Answerable));
    }

    // ------------------------------------------------------------------ Answer Now's dock and the bubble

    [Fact]
    public void AnswerNowsDockHasCancelTheQuestionAndSendOnlyOnceTyped()
    {
        var dock = new Proof.DockSeen(Proof.SkippedQuestion, ["Cancel", "Send"], SendEnabled: false);
        Assert.Null(Proof.LaterDock(dock, typed: false));
        Assert.Equal("Send can be pressed with nothing typed", Proof.LaterDock(dock with { SendEnabled = true }, typed: false));
        Assert.Null(Proof.LaterDock(dock with { SendEnabled = true }, typed: true));
        Assert.Equal("Send can't be pressed with the answer typed", Proof.LaterDock(dock, typed: true));
        Assert.Equal("Answer Now's dock offers Skip, as a live question's", Proof.LaterDock(dock with { Buttons = ["Cancel", "Skip", "Send"] }, typed: false));
        Assert.StartsWith("Answer Now's dock has no Cancel", Proof.LaterDock(dock with { Buttons = ["Skip", "Send"] }, typed: false));
        Assert.Equal("Answer Now's dock has no Send", Proof.LaterDock(dock with { Buttons = ["Cancel"] }, typed: false));
        Assert.StartsWith("Answer Now's dock asks \u201CWhich city", Proof.LaterDock(dock with { Question = Proof.AnsweredQuestion }, typed: false));
    }

    [Fact]
    public void TheLateMessageIsTheCardsAndTheBubbleReadsTheAnswerAlone()
    {
        Assert.Equal($"[Hermes HQ question {ClarifyLate.Key([Proof.SkippedQuestion])}: answer]\n"
            + "My answer to the question you asked earlier, which went unanswered:\n\nQ: What should I name the new project?\nA: Harbor Lights",
            Proof.LateMessage);
        Assert.Null(Proof.BubbleShowsAnswersAlone(["Harbor Lights", "Sent"]));
        Assert.StartsWith("your bubble doesn't read", Proof.BubbleShowsAnswersAlone(["Something else"]));
        Assert.StartsWith("your bubble shows the message's own words", Proof.BubbleShowsAnswersAlone(["Harbor Lights", Proof.LateMessage]));
        Assert.NotNull(Proof.BubbleShowsAnswersAlone(["Harbor Lights", "Q: What should I name the new project?"]));
    }

    // ------------------------------------------------------------------ the stand-in's record

    [Fact]
    public void FreshSessionIsTheStandInsNewOne()
    {
        Assert.Null(Proof.FreshSession("20261002_120000_aaaa0001", "20261002_120000_bbbb0002", "20261002_120000_bbbb0002"));
        Assert.Equal("the stand-in made no new session", Proof.FreshSession("x", "x", null));
        Assert.Equal("the stand-in's new session is the old one", Proof.FreshSession("x", "x", "x"));
        Assert.Equal("the app opened x, not the stand-in's new session y", Proof.FreshSession("w", "x", "y"));
    }

    private static JsonNode Clarify(string outcome, bool held, params (string Qid, string Answer)[] locks) => new JsonObject
    {
        ["id"] = "srq-" + outcome, ["method"] = "clarify", ["outcome"] = outcome, ["held"] = held,
        ["answers"] = new JsonArray([.. locks.Select(l => (JsonNode)new JsonObject { ["kind"] = "lock", ["question_id"] = l.Qid, ["answer"] = l.Answer })]),
    };

    private static JsonNode Requests(params JsonNode[] requests) =>
        new JsonObject { ["requests"] = new JsonArray([new JsonObject { ["method"] = "approval", ["outcome"] = "answered" }, .. requests.Select(r => r.DeepClone())]) };

    [Fact]
    public void TheAnsweredQuestionIsSubmittedWithTheCityAndHeld()
    {
        Assert.Null(Proof.AnsweredAndHeld(Requests(Clarify("submitted", true, ("q0", "Lisbon (Recommended)")))));
        Assert.Null(Proof.AnsweredAndHeld(Requests(Clarify("submitted", true, ("q0", "Lisbon")))));
        Assert.Equal("the stand-in isn't holding the clarify tool (clarify_hold)", Proof.AnsweredAndHeld(Requests(Clarify("submitted", false, ("q0", "Lisbon")))));
        Assert.Equal("the clarify request is open, not submitted", Proof.AnsweredAndHeld(Requests(Clarify("open", true))));
        Assert.Equal("the app answered \u201CPorto\u201D, not Lisbon", Proof.AnsweredAndHeld(Requests(Clarify("submitted", true, ("q0", "Porto")))));
        Assert.Equal("the stand-in has 0 clarify requests, not 1", Proof.AnsweredAndHeld(Requests()));
    }

    [Fact]
    public void TheSecondQuestionIsSkippedWithNothingLocked()
    {
        var answered = Clarify("submitted", false, ("q0", "Lisbon"));
        Assert.Null(Proof.SkippedOnStandIn(Requests(answered, Clarify("skipped", false))));
        Assert.Equal("the second clarify request is submitted, not skipped", Proof.SkippedOnStandIn(Requests(answered, Clarify("submitted", false, ("q0", "x")))));
        Assert.Equal("the skipped question got an answer locked", Proof.SkippedOnStandIn(Requests(answered, Clarify("skipped", false, ("q0", "x")))));
        Assert.Equal("the stand-in has 1 clarify requests, not 2", Proof.SkippedOnStandIn(Requests(answered)));
    }

    [Fact]
    public void TheLateAnswerGoesOutAsTheCardsMessageForTheBot()
    {
        JsonNode State(params string[] texts) => new JsonObject
        {
            ["rpc"] = new JsonArray([new JsonObject { ["method"] = "session.resume", ["params"] = new JsonObject() },
                .. texts.Select(t => (JsonNode)new JsonObject { ["method"] = "prompt.submit", ["params"] = new JsonObject { ["text"] = t, ["profile"] = "default" } })]),
        };
        var two = Requests(Clarify("submitted", false, ("q0", "Lisbon")), Clarify("skipped", false));
        Assert.Null(Proof.LateSent(State(Proof.AnsweredPrompt, Proof.SkippedPrompt, Proof.LateMessage), two));
        Assert.Equal("the stand-in took no prompt", Proof.LateSent(State(), two));
        Assert.StartsWith("the stand-in's last prompt is \u201CHarbor Lights\u201D", Proof.LateSent(State("Harbor Lights"), two));
        Assert.Equal("the stand-in has 3 clarify requests after Answer Now, not 2",
            Proof.LateSent(State(Proof.LateMessage), Requests(Clarify("submitted", false), Clarify("skipped", false), Clarify("open", false))));
        var elsewhere = new JsonObject { ["rpc"] = new JsonArray(new JsonObject { ["method"] = "prompt.submit", ["params"] = new JsonObject { ["text"] = Proof.LateMessage, ["profile"] = "sam" } }) };
        Assert.Equal("the card's message went to sam, not default", Proof.LateSent(elsewhere, two));
    }

    // ------------------------------------------------------------------ the stand-in asks what the walk expects

    private static string WindowsDir()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "windows", "HermesHQ.sln")))
                return Path.Combine(dir.FullName, "windows");
        throw new InvalidOperationException("repo root not found");
    }

    private static string Read(params string[] parts) => File.ReadAllText(Path.Combine([WindowsDir(), .. parts])).Replace("\r\n", "\n");

    /// questions-gateway.py `keyword()`: the first of KEYWORDS standing alone in the words ("job applications" first).
    private static string? Keyword(string gateway, string text)
    {
        var list = Regex.Match(gateway, @"\nKEYWORDS = \[(?<list>[^\]]+)\]").Groups["list"].Value;
        var keywords = Regex.Matches(list, "'([^']+)'").Select(m => m.Groups[1].Value).ToList();
        Assert.NotEmpty(keywords);
        var lowered = text.ToLowerInvariant();
        if (lowered.Contains("job applications")) return "offer";
        return keywords.FirstOrDefault(k => Regex.IsMatch(lowered, @"(?<![\w-])" + Regex.Escape(k) + @"(?![\w-])"));
    }

    [Fact]
    public void TheWalksWordsMakeTheStandInAskItsQuestions()
    {
        var gateway = Read("ci", "fixtures", "questions-gateway.py");
        Assert.Equal("one", Keyword(gateway, Proof.AnsweredPrompt));
        Assert.Equal("text", Keyword(gateway, Proof.SkippedPrompt));
        Assert.Null(Keyword(gateway, Proof.LateMessage));   // the late answer starts an ordinary turn
        Assert.Contains("ONE = [{'qid': 'q0', 'question': 'Which city should I book?', 'choices': ['Lisbon (Recommended)', 'Porto'], 'multi_select': False}]", gateway);
        Assert.Contains("TEXT = [{'qid': 'q0', 'question': 'What should I name the new project?', 'choices': None, 'multi_select': False}]", gateway);
        Assert.Contains($"'{Proof.AnsweredReply}'", gateway);
        Assert.Contains($"'{Proof.SkippedReply}'", gateway);
        Assert.Contains("POST /__fixture/release", gateway);
        Assert.Contains("clarify_hold", gateway);
        Assert.Contains("if body.get('new_session')", Read("ci", "fixtures", "performance-fixture-gateway.py"));
    }

    // ------------------------------------------------------------------ wiring

    [Fact]
    public void TheAppRegistersTheWalkAndTakesEveryPicture()
    {
        Assert.Contains("        RegisterSettledQuestionsWalks();", Read("src", "HermesHQ.Windows", "Services", "ProofWalks.cs"));
        var walk = Read("src", "HermesHQ.Windows", "Services", "ProofWalks.SettledQuestions.cs");
        // Literal names: WalkProofTests reads windows.yml's walks against the source as written.
        Assert.Contains("Automation.NamedWalks[\"questions-settled\"] = SettledQuestionsAsync;", walk);
        Assert.Equal("questions-settled", Proof.Walk);
        foreach (var name in Proof.Shots) Assert.Contains($"await shot(\"{name}\");", walk);
        Assert.Contains("await shot(\"questions-settled\");", walk);
        Assert.Equal(["questions-settled-card", "questions-answer-now", "questions-answer-now-dock", "questions-answer-now-sent"], Proof.Shots);
        // The app's own controls, no OS input.
        Assert.DoesNotContain("Keys.", walk);
        Assert.DoesNotContain("Mouse.", walk);
        Assert.DoesNotContain("KeysAsync", walk);
        // The stand-in's hold is let go whatever happens.
        Assert.Matches(new Regex(@"finally\n\s+\{\n\s+// Nothing left held"), walk);
    }
}
