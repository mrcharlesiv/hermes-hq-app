using System.Text.Json.Nodes;
using Hermes.Core.Questions;

namespace Hermes.Core.Shell;

/// [WIN-QUESTIONS-SETTLED-WALK] What the questions-settled walk (HermesHQ.Windows Services/ProofWalks.SettledQuestions.cs;
/// windows.yml asks for it on its own questions stand-in, windows/ci/fixtures/questions-gateway.py) checks as it drives
/// the settled Q&A card and Answer Now with the app's own controls (93f984bb1 PromptLogic.swift ClarifySettled /
/// ClarifyLate, PromptRows.swift settledCard, ChatPromptCell's Answer Now, ChatPromptsController answerLater/sendLater):
/// a question answered in the live dock while the stand-in holds its tool (clarify_hold), released, and its settled card
/// drawn from history after the chat is opened again; a question skipped, its card offering Answer Now; Answer Now's dock
/// (Cancel, not Skip); its Send putting the card's message in the chat, the bubble reading the answer alone, the card
/// then "Answered later". Each check answers null when the app (or the stand-in's record) shows what it should,
/// otherwise the words of what is wrong. Kept apart from WalkProof.cs so lanes don't collide.
public static class SettledQuestionsWalkProof
{
    public const string Walk = "questions-settled";

    /// The walk's pictures besides its own (`questions-settled`: the chat opened again at the end, both cards from history).
    public static readonly IReadOnlyList<string> Shots =
        ["questions-settled-card", "questions-answer-now", "questions-answer-now-dock", "questions-answer-now-sent"];

    /// The stand-in's bot whose chat the walk uses (a fresh, empty session of it), and the one opened in between so the
    /// chat is drawn again from its history.
    public const string Bot = "default";
    public const string OtherBot = "sam";

    // ------------------------------------------------------------------ what the stand-in asks (questions-gateway.py)

    /// Words carrying the stand-in's `one` keyword (and no earlier one): ONE, a pick-one question.
    public const string AnsweredPrompt = "Pick one city for me";
    public const string AnsweredQuestion = "Which city should I book?";
    /// The choice picked, as its row reads (offered as "Lisbon (Recommended)"; the card shows it bare).
    public const string AnsweredChoice = "Lisbon";

    /// Words carrying the stand-in's `text` keyword (and no earlier one): TEXT, a question typed into.
    public const string SkippedPrompt = "Quick text question about the project name";
    public const string SkippedQuestion = "What should I name the new project?";

    /// What Answer Now's dock is given for the skipped question (synthetic).
    public const string LateAnswer = "Harbor Lights";

    /// The stand-in's replies once its clarify tool ends.
    public const string AnsweredReply = "Thanks, I have your answers.";
    public const string SkippedReply = "Questions skipped.";

    /// The live dock's Skip for one question, and Answer Now's in its place (QuestionDockView.swift `skip.title`).
    public const string LiveSkip = "Skip";
    public const string LaterSkip = "Cancel";
    public const string SendTitle = "Send";

    /// The QuestionDock's accessible name for one question.
    public const string DockName = "Question";

    // ------------------------------------------------------------------ what the cards say

    /// One settled card as the transcript shows it: its accessible name (SettledClarify.Spoken) and whether it carries
    /// Answer Now.
    public sealed record CardSeen(string Spoken, bool AnswerNow);

    private static SettledClarifyCard Card(string question, string answer, bool later) =>
        new([new ClarifyQA(question, answer, answer.Length == 0)], ClarifyLate.Key([question]), "", new HashSet<string>(),
            answer.Length == 0, later);

    /// The answered question's card: "Your answer", the city, no Answer Now.
    public static CardSeen Answered { get; } = new(SettledClarify.Spoken(Card(AnsweredQuestion, AnsweredChoice, later: false)), false);

    /// The skipped question's card: "Question skipped", "No answer" (the stand-in says `unanswered`), Answer Now.
    public static CardSeen Skipped { get; } = new(SettledClarify.Spoken(Card(SkippedQuestion, "", later: false)), true);

    /// The same card once Answer Now's answer is in the chat: "Answered later", the answer, no Answer Now.
    public static CardSeen AnsweredLater { get; } = new(SettledClarify.Spoken(Card(SkippedQuestion, LateAnswer, later: true)), false);

    /// The chat's settled cards, in the transcript's order, are exactly `expected`. Null when so.
    public static string? Cards(IReadOnlyList<CardSeen> seen, IReadOnlyList<CardSeen> expected)
    {
        static string Say(IEnumerable<CardSeen> cards) =>
            cards.Any() ? string.Join(" | ", cards.Select(c => $"\u201C{c.Spoken}\u201D{(c.AnswerNow ? " + Answer Now" : "")}")) : "none";
        return seen.SequenceEqual(expected) ? null : $"the chat's settled cards are {Say(seen)}, not {Say(expected)}";
    }

    // ------------------------------------------------------------------ Answer Now's dock

    /// Answer Now's dock as shown: its question, the words of its buttons, and whether Send can be pressed.
    public sealed record DockSeen(string? Question, IReadOnlyList<string> Buttons, bool SendEnabled);

    /// Answer Now's dock for the skipped question: that question, Cancel where the live dock has Skip, Send (pressable
    /// only once something is typed, `typed`). Null when so.
    public static string? LaterDock(DockSeen dock, bool typed)
    {
        if (dock.Question != SkippedQuestion) return $"Answer Now's dock asks \u201C{dock.Question ?? "nothing"}\u201D, not \u201C{SkippedQuestion}\u201D";
        if (!dock.Buttons.Contains(LaterSkip)) return $"Answer Now's dock has no {LaterSkip} (its buttons: {string.Join(", ", dock.Buttons)})";
        if (dock.Buttons.Contains(LiveSkip) || dock.Buttons.Contains("Skip All")) return "Answer Now's dock offers Skip, as a live question's";
        if (!dock.Buttons.Contains(SendTitle)) return $"Answer Now's dock has no {SendTitle}";
        if (dock.SendEnabled != typed) return typed ? "Send can't be pressed with the answer typed" : "Send can be pressed with nothing typed";
        return null;
    }

    // ------------------------------------------------------------------ the bubble

    /// The message Answer Now's Send puts in the chat (ClarifyLate.Message for the skipped card's key).
    public static string LateMessage { get; } =
        ClarifyLate.Message(ClarifyLate.Key([SkippedQuestion]), [(SkippedQuestion, LateAnswer)]);

    /// The bubble of that message reads the answer alone: `texts` (the words drawn in its row) hold the answer, and none
    /// shows the mark, the lead line or a "Q:" line. Null when so.
    public static string? BubbleShowsAnswersAlone(IReadOnlyCollection<string> texts)
    {
        var words = ClarifyLate.BubbleWords(LateMessage);
        if (words != LateAnswer) return $"the late message's bubble words are \u201C{words}\u201D, not \u201C{LateAnswer}\u201D";
        if (!texts.Contains(words)) return $"your bubble doesn't read \u201C{words}\u201D (it shows {string.Join(" / ", texts.Select(t => $"\u201C{t}\u201D"))})";
        if (texts.FirstOrDefault(t => t.Contains(ClarifyLate.MarkLead, StringComparison.Ordinal)
                || t.Contains("which went unanswered", StringComparison.Ordinal) || t.Contains("Q: ", StringComparison.Ordinal)) is { } raw)
            return $"your bubble shows the message's own words \u201C{raw}\u201D";
        return null;
    }

    // ------------------------------------------------------------------ the stand-in's record

    /// The walk's chat is a fresh session: the bot's chat the app opens is the one the stand-in just made (`made`), not
    /// the one before (`before`). Null when so.
    public static string? FreshSession(string? before, string opened, string? made)
    {
        if (string.IsNullOrEmpty(made)) return "the stand-in made no new session";
        if (made == before) return "the stand-in's new session is the old one";
        return opened == made ? null : $"the app opened {opened}, not the stand-in's new session {made}";
    }

    private static List<JsonNode> Clarifies(JsonNode requests) =>
        (requests["requests"] as JsonArray ?? []).Where(r => r?["method"]?.GetValue<string>() == "clarify").Select(r => r!).ToList();

    private static string? Str(JsonNode? node, string key) =>
        node?[key] is JsonValue v && v.TryGetValue(out string? s) ? s : null;

    /// GET /__fixture/requests after the live dock's Send, the stand-in holding the tool: one clarify, `submitted` by the
    /// app's clarify.lock of q0 with the city, and held (its tool not ended). Null when so.
    public static string? AnsweredAndHeld(JsonNode requests)
    {
        var clarifies = Clarifies(requests);
        if (clarifies.Count != 1) return $"the stand-in has {clarifies.Count} clarify requests, not 1";
        var request = clarifies[0];
        if (Str(request, "outcome") != "submitted") return $"the clarify request is {Str(request, "outcome") ?? "unsettled"}, not submitted";
        if (request["held"] is not JsonValue held || !held.TryGetValue(out bool isHeld) || !isHeld) return "the stand-in isn't holding the clarify tool (clarify_hold)";
        var locks = (request["answers"] as JsonArray ?? []).Where(a => Str(a, "kind") == "lock").ToList();
        if (locks.Count != 1 || Str(locks[0], "question_id") != "q0") return $"the app locked {locks.Count} answers, not q0 alone";
        var answer = Str(locks[0], "answer") ?? "";
        return ClarifyText.BareChoice(answer) == AnsweredChoice ? null : $"the app answered \u201C{answer}\u201D, not {AnsweredChoice}";
    }

    /// GET /__fixture/requests after the live dock's Skip: the newest clarify ended `skipped` with nothing locked. Null when so.
    public static string? SkippedOnStandIn(JsonNode requests)
    {
        var clarifies = Clarifies(requests);
        if (clarifies.Count != 2) return $"the stand-in has {clarifies.Count} clarify requests, not 2";
        var request = clarifies[^1];
        if (Str(request, "outcome") != "skipped") return $"the second clarify request is {Str(request, "outcome") ?? "unsettled"}, not skipped";
        return (request["answers"] as JsonArray ?? []).Any(a => Str(a, "kind") == "lock") ? "the skipped question got an answer locked" : null;
    }

    /// GET /__fixture/state after Answer Now's Send: the stand-in's last prompt.submit is the card's message, for the
    /// walk's bot, and no clarify was answered over the wire for it (the call is long over). Null when so.
    public static string? LateSent(JsonNode state, JsonNode requests)
    {
        var submits = (state["rpc"] as JsonArray ?? []).Where(r => Str(r, "method") == "prompt.submit").ToList();
        if (submits.Count == 0) return "the stand-in took no prompt";
        var last = submits[^1]!["params"];
        if (Str(last, "text") != LateMessage) return $"the stand-in's last prompt is \u201C{Str(last, "text")}\u201D, not the card's message";
        if (Str(last, "profile") is { } profile && profile != Bot) return $"the card's message went to {profile}, not {Bot}";
        var clarifies = Clarifies(requests);
        return clarifies.Count == 2 ? null : $"the stand-in has {clarifies.Count} clarify requests after Answer Now, not 2";
    }
}
