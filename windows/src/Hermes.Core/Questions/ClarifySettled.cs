using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Model;

namespace Hermes.Core.Questions;

// The settled clarify card in history and Answer Now on it (Mac at 93f984bb1: HermesKit/Chat/PromptLogic.swift
// `ClarifyQA`, `ClarifySettled`, `ClarifyLate`; App/Questions/PromptRows.swift `settledCard`, `multiSelect`,
// `answersTitle`; App/Questions/ChatPromptsController.swift `answerLater`, `keepAnswering`, `hasAnswers`, `sendLater`;
// App/Questions/ChatViewController+Prompts.swift `settledClarify`).

/// One question of a settled clarify card. Unanswered: blank with `status == "unanswered"` ("No answer"); any other
/// blank is "Skipped". Choices: what it offered (`choices_offered`), for answering it later; null = an open question.
public sealed record ClarifyQA(string Question, string Answer, bool Unanswered, IReadOnlyList<string>? Choices = null);

/// The clarify tool's result (HA:tools/clarify_tool.py `_result`): `responses[]` → rows.
public static class ClarifySettled
{
    /// From a live `tool.complete` result or a history `tool` row's content (JSON text). Null when there is no
    /// `responses` array (the generic step line stays).
    public static IReadOnlyList<ClarifyQA>? Parse(string? resultText)
    {
        if (string.IsNullOrWhiteSpace(resultText)) return null;
        JsonNode? result;
        try { result = JsonNode.Parse(resultText); }
        catch (JsonException) { return null; }
        return Parse(result);
    }

    public static IReadOnlyList<ClarifyQA>? Parse(JsonNode? result)
    {
        if (result is JsonValue v && v.TryGetValue(out string? text)) return Parse(text);
        if (result is not JsonObject o || o["responses"] is not JsonArray responses) return null;
        var rows = new List<ClarifyQA>();
        foreach (var item in responses)
        {
            if (item is not JsonObject r || r["question"] is not JsonValue qv || !qv.TryGetValue(out string? question)) continue;
            var answer = r["user_response"] switch
            {
                JsonValue s when s.TryGetValue(out string? str) => str,
                JsonArray list => string.Join(", ", list.Select(n => n is JsonValue e && e.TryGetValue(out string? x) ? x : null).Where(x => x != null)),
                JsonValue other when other.GetValueKind() is JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False => other.ToJsonString(),
                _ => "",
            };
            var blank = answer.Trim().Length == 0;
            var offered = (r["choices_offered"] as JsonArray ?? [])
                .Select(n => n is JsonValue e && e.TryGetValue(out string? x) ? x : null)
                .Where(x => x != null && x.Trim().Length > 0).Select(x => x!).ToList();
            var status = r["status"] is JsonValue sv && sv.TryGetValue(out string? st) ? st : null;
            rows.Add(new ClarifyQA(question, answer, blank && status == "unanswered", offered.Count == 0 ? null : offered));
        }
        return rows;
    }
}

/// A question that went unanswered can still be answered from its card: the answer goes into the chat as a message of
/// yours naming the card, and the card then shows it (on every device, after a reload). The bot's clarify call is long
/// over, so a plain message is the only way back to it.
public static class ClarifyLate
{
    /// One card's answers found in the chat: the question (on one line) → its answer, and the index of the newest
    /// message that gave them (`int.MaxValue`: still queued behind a running reply).
    public sealed record Found(IReadOnlyDictionary<string, string> Answers, int Index);

    public const string MarkLead = "[Hermes HQ question ";
    private static readonly Regex Mark = new(@"^\s*\[Hermes HQ question (q-[0-9a-f]{8}): answer\]", RegexOptions.CultureInvariant);
    private static readonly char[] Newlines = ['\n', '\r', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029'];

    /// A question on one line (how the message writes it and how a card looks it up).
    public static string Flat(string question) => string.Join(" ",
        question.Split(Newlines).Select(l => l.Trim(' ', '\t', '\u00A0')).Where(l => l.Length > 0));

    /// The card's name in the message: the same for the same questions on every device and after a reload
    /// (FNV-1a 32 over the UTF-8 of the questions on one line, joined by a line feed).
    public static string Key(IEnumerable<string> questions)
    {
        var hash = 0x811c9dc5u;
        foreach (var b in Encoding.UTF8.GetBytes(string.Join("\n", questions.Select(Flat))))
        {
            hash ^= b;
            hash = unchecked(hash * 0x01000193u);
        }
        return $"q-{hash:x8}";
    }

    /// What the card's Send sends: the mark, a line saying what it is, then each question and its answer.
    public static string Message(string key, IReadOnlyList<(string Question, string Answer)> answers)
    {
        var lead = answers.Count == 1 ? "My answer to the question you asked earlier, which went unanswered:"
            : "My answers to the questions you asked earlier, which went unanswered:";
        var body = answers.Select(a => $"Q: {Flat(a.Question)}\nA: {a.Answer.Trim()}");
        return $"{MarkLead}{key}: answer]\n{lead}\n\n" + string.Join("\n\n", body);
    }

    /// The card a message of yours answers, and its answers by question (on one line).
    public static (string Key, IReadOnlyDictionary<string, string> Answers)? Answer(string text)
    {
        if (!text.TrimStart().StartsWith(MarkLead, StringComparison.Ordinal) || Mark.Match(text) is not { Success: true } m) return null;
        var key = m.Groups[1].Value;
        var gap = text.IndexOf("\n\nQ: ", StringComparison.Ordinal);
        var output = new Dictionary<string, string>();
        if (gap < 0) return (key, output);
        foreach (var chunk in text[(gap + 5)..].Split("\n\nQ: "))
        {
            var split = chunk.IndexOf("\nA: ", StringComparison.Ordinal);
            if (split < 0) continue;
            var question = Flat(chunk[..split]);
            var answer = chunk[(split + 4)..].Trim();
            if (question.Length > 0 && answer.Length > 0) output[question] = answer;
        }
        return (key, output);
    }

    /// Your bubble's words: the answers alone, one a line, in the order written (the card above shows the questions).
    public static string? BubbleWords(string text)
    {
        if (Answer(text) == null) return null;
        var words = new List<string>();
        foreach (var chunk in text.Split("\n\nQ: ").Skip(1))
        {
            var split = chunk.IndexOf("\nA: ", StringComparison.Ordinal);
            if (split < 0) continue;
            var answer = chunk[(split + 4)..].Trim();
            if (answer.Length > 0) words.Add(answer);
        }
        return words.Count == 0 ? null : string.Join("\n", words);
    }

    /// Every card the chat's messages answer, by key (answers merge; the newest wins). `queued`: answers still waiting
    /// behind a running reply count too (they are newest).
    public static IReadOnlyDictionary<string, Found> Answers(IReadOnlyList<ChatMessage> messages, IEnumerable<string>? queued = null)
    {
        var output = new Dictionary<string, (Dictionary<string, string> Answers, int Index)>();
        void Take(string text, int index)
        {
            if (Answer(text) is not { } found) return;
            if (!output.TryGetValue(found.Key, out var entry)) entry = (new Dictionary<string, string>(), index);
            foreach (var (q, a) in found.Answers) entry.Answers[q] = a;
            output[found.Key] = (entry.Answers, index);
        }
        for (var i = 0; i < messages.Count; i++)
        {
            if (messages[i].Role != Role.User) continue;
            foreach (var part in messages[i].Parts.OfType<TextPart>()) Take(part.Text, i);
        }
        foreach (var text in queued ?? []) Take(text, int.MaxValue);
        return output.ToDictionary(kv => kv.Key, kv => new Found(kv.Value.Answers, kv.Value.Index));
    }

    /// What the chat's later answers are, as one string: a change means a card is drawn again.
    public static string Signature(IReadOnlyDictionary<string, Found> found) => string.Join("\u001F",
        found.OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => kv.Key + "\u001E" + kv.Value.Index + "\u001E"
            + string.Join("\u001D", kv.Value.Answers.OrderBy(a => a.Key, StringComparer.Ordinal).Select(a => a.Key + "\u001C" + a.Value))));

    /// The keys whose answers differ between two readings.
    public static IReadOnlySet<string> Changed(IReadOnlyDictionary<string, Found> before, IReadOnlyDictionary<string, Found> now)
    {
        var keys = new HashSet<string>(before.Keys);
        keys.UnionWith(now.Keys);
        keys.RemoveWhere(k => before.TryGetValue(k, out var a) && now.TryGetValue(k, out var b)
            && Signature(new Dictionary<string, Found> { [k] = a }) == Signature(new Dictionary<string, Found> { [k] = b }));
        return keys;
    }

    /// A settled card's rows with the answers given later filled in; `Later` is true when any were.
    public static (IReadOnlyList<ClarifyQA> Rows, bool Later) Filled(IReadOnlyList<ClarifyQA> rows, Found? found)
    {
        if (found == null || found.Answers.Count == 0) return (rows, false);
        var later = false;
        var output = rows.Select(row =>
        {
            if (row.Answer.Trim().Length > 0 || !found.Answers.TryGetValue(Flat(row.Question), out var answer)) return row;
            later = true;
            return row with { Answer = answer, Unanswered = false };
        }).ToList();
        return (output, later);
    }

    /// [calm-chat] A normal human turn (typed message, voice memo, attachment) — not a bot/cron delivery, internal
    /// notification, or synthetic card-tap marker message (HermesKit/Chat/PromptLogic.swift `isUserTurn` +
    /// DraftCards.isNormalHumanTurn).
    public static bool IsNormalHumanTurn(ChatMessage message)
    {
        if (message.Role != Role.User || message.Sender != null) return false;
        var text = string.Join("\n", message.Parts.OfType<TextPart>().Select(p => p.Text)).Trim();
        if (text.StartsWith("[Hermes HQ draft ", StringComparison.Ordinal)
            || text.StartsWith("[Hermes HQ ask ", StringComparison.Ordinal)
            || text.StartsWith(MarkLead, StringComparison.Ordinal)
            || text.StartsWith("[Hermes HQ order ", StringComparison.Ordinal)
            || text.StartsWith("[Hermes HQ travel ", StringComparison.Ordinal)
            || text.StartsWith("Message from 🤖 ", StringComparison.Ordinal)
            || text.Contains("[INTERNAL NOTIFICATION", StringComparison.Ordinal)
            || text.StartsWith("[Cronjob \"", StringComparison.Ordinal))
            return false;
        return true;
    }

    /// [calm-chat] Whether `messages[index]` is a late clarify answer immediately following the assistant message
    /// containing that settled clarify card (the card right above already fills in the answer).
    public static bool IsAdjacentAnswerEcho(IReadOnlyList<ChatMessage> messages, int index, string key)
    {
        if (index <= 0 || index >= messages.Count) return false;
        for (var scan = index - 1; scan >= 0; scan--)
        {
            var prev = messages[scan];
            if (prev.Role == Role.System) continue;
            if (prev.Role != Role.Assistant) return false;
            return prev.Tools.Any(c => c.Name == "clarify" && c.State != ToolState.Running
                && ClarifySettled.Parse(c.ResultText) is { Count: > 0 } rows
                && Key(rows.Select(r => r.Question)) == key);
        }
        return false;
    }

    /// [calm-chat] True when at least one later normal human turn or later clarify call follows `messageId`, so an
    /// unanswered clarify card stops displaying a bright live "Answer Now" pill in scrollback.
    public static bool HasLaterHumanTurn(string messageId, IReadOnlyList<ChatMessage> messages)
    {
        var at = -1;
        for (var i = messages.Count - 1; i >= 0; i--) if (messages[i].Id == messageId) { at = i; break; }
        if (at < 0 || at + 1 >= messages.Count) return false;
        for (var i = at + 1; i < messages.Count; i++)
        {
            var m = messages[i];
            if (IsNormalHumanTurn(m)) return true;
            if (m.Role == Role.Assistant && m.Tools.Any(c => c.Name == "clarify")) return true;
        }
        return false;
    }

    /// [calm-chat] True once the user sends a new normal message after `messageId` (and after any late answer
    /// `answeredAt` filling this card). Answered clarify cards stay open throughout their own turn and fold only once
    /// the user moves on with a new turn.
    public static bool HasMovedPastTurn(string messageId, IReadOnlyList<ChatMessage> messages, int? answeredAt = null)
    {
        if (answeredAt == int.MaxValue) return false;
        var at = -1;
        for (var i = messages.Count - 1; i >= 0; i--) if (messages[i].Id == messageId) { at = i; break; }
        if (at < 0) return false;
        var anchor = Math.Max(at, answeredAt ?? at);
        if (anchor + 1 >= messages.Count) return false;
        for (var i = anchor + 1; i < messages.Count; i++)
            if (IsNormalHumanTurn(messages[i])) return true;
        return false;
    }

    /// [calm-chat] Lookback when a later human turn, clarify call, or late answer arrives so earlier settled clarify
    /// cards fold or drop Answer Now live (HermesKit/Chat/PromptLogic.swift `ClarifyLate.reach`).
    public static int Reach(int from, int floor, IReadOnlyList<ChatMessage> messages)
    {
        if (from <= floor || from >= messages.Count) return from;
        var triggers = false;
        for (var i = from; i < messages.Count; i++)
        {
            var m = messages[i];
            if (IsNormalHumanTurn(m)) { triggers = true; break; }
            if (m.Role == Role.User && m.Parts.OfType<TextPart>().Any(p => Answer(p.Text) != null)) { triggers = true; break; }
            if (m.Role == Role.Assistant && m.Tools.Any(c => c.Name == "clarify")) { triggers = true; break; }
        }
        if (!triggers) return from;
        var scanFloor = Math.Max(floor, from - 120);
        var lowest = from;
        for (var i = from - 1; i >= scanFloor; i--)
        {
            if (messages[i].Role == Role.Assistant && messages[i].Tools.Any(c => c.Name == "clarify" && c.State != ToolState.Running))
                lowest = i;
        }
        return lowest;
    }
}

/// A clarify call's settled card: its questions and answers (answers given later in the chat filled in), whether a
/// question still waits for one (Answer Now), and calm-chat readability fold state.
public sealed record SettledClarifyCard(
    IReadOnlyList<ClarifyQA> Rows,
    string Key,
    string MessageId,
    IReadOnlySet<string> Multi,
    bool Answerable,
    bool AnsweredLater,
    bool Folded = false,
    bool StaleUnanswered = false);

/// What Answer Now's Send does: Close the later dock (or keep it: nothing typed), and the message to put in the chat
/// (null: nothing to send) for the card in `MessageId`.
public readonly record struct LateSendPlan(bool Close, string? Text, string MessageId);

/// The settled card's rules and Answer Now (PromptRows.settledCard; ChatPromptsController's Answer Now).
public static class SettledClarify
{
    public const string AnswerNowTitle = "Answer Now";

    /// The card for a clarify call whose result has `responses`, else null (running: the note; otherwise a step line).
    /// Answers you gave later in the chat (after this message) fill its blanks; a blank left over offers Answer Now
    /// until later human turns move past it (not in a room, whose sends go to its members).
    public static SettledClarifyCard? Card(ToolCall call, ChatMessage message, IReadOnlyList<ChatMessage> messages,
        IEnumerable<string>? queued = null, bool room = false)
    {
        if (call.Name != "clarify" || call.State == ToolState.Running) return null;
        if (ClarifySettled.Parse(call.ResultText) is not { Count: > 0 } rows) return null;
        var key = ClarifyLate.Key(rows.Select(r => r.Question));
        ClarifyLate.Answers(messages, queued).TryGetValue(key, out var found);
        if (found != null && found.Index != int.MaxValue)
        {
            var at = -1;
            for (var i = messages.Count - 1; i >= 0; i--) if (messages[i].Id == message.Id) { at = i; break; }
            if (at >= 0 && found.Index < at) found = null;
        }
        var (shown, later) = ClarifyLate.Filled(rows, found);
        var blank = shown.Any(r => r.Answer.Trim().Length == 0);
        var staleUnanswered = blank && ClarifyLate.HasLaterHumanTurn(message.Id, messages);
        var movedPastTurn = !blank && ClarifyLate.HasMovedPastTurn(message.Id, messages, found?.Index);
        var folded = staleUnanswered || movedPastTurn;
        return new SettledClarifyCard(shown, key, message.Id, MultiSelect(call.ArgsJson),
            blank && !room && !staleUnanswered, later, Folded: folded, StaleUnanswered: staleUnanswered);
    }

    /// The questions (on one line) the call asked as multi-select.
    public static IReadOnlySet<string> MultiSelect(string? argsJson)
    {
        var output = new HashSet<string>();
        if (argsJson == null || !argsJson.Contains("multi_select", StringComparison.Ordinal)) return output;
        JsonNode? args;
        try { args = JsonNode.Parse(argsJson); }
        catch (JsonException) { return output; }
        if (args is not JsonObject o || o["questions"] is not JsonArray questions) return output;
        foreach (var q in questions)
            if (q is JsonObject qo && qo["multi_select"] is JsonValue m && m.GetValueKind() == JsonValueKind.True
                && qo["question"] is JsonValue t && t.TryGetValue(out string? text))
                output.Add(ClarifyLate.Flat(text));
        return output;
    }

    /// The header: "Answered later" / "Your answers, some later" when an answer came later; else "Your answer(s)", or
    /// "Question skipped" / "N questions skipped" (Skipped: the grey minus mark) when none was given.
    public static (string Title, bool Skipped) Header(SettledClarifyCard card)
    {
        var rows = card.Rows;
        var skipped = rows.Count > 0 && rows.All(r => r.Answer.Trim().Length == 0);
        var title = skipped ? (rows.Count == 1 ? "Question skipped" : $"{rows.Count} questions skipped")
            : rows.Count == 1 ? "Your answer" : "Your answers";
        if (card.AnsweredLater) title = rows.Count == 1 ? "Answered later" : "Your answers, some later";
        return (title, skipped);
    }

    /// A row's answer as drawn: the answer, or "No answer" / "Skipped" for a blank.
    public static string Words(ClarifyQA row)
    {
        var answer = row.Answer.Trim();
        return answer.Length > 0 ? answer : row.Unanswered ? "No answer" : "Skipped";
    }

    /// The card as read aloud: the title, then each "question: answer".
    public static string Spoken(SettledClarifyCard card) =>
        string.Join(". ", [Header(card).Title, .. card.Rows.Select(r => $"{r.Question}: {Words(r)}")]);

    public static string AnswerNowHint(SettledClarifyCard card) =>
        card.Rows.Count == 1 ? "Answers the question now, in the chat" : "Answers the questions now, in the chat";

    /// Answer Now: the card's unanswered questions, with the choices they offered (null: none is open).
    public static ClarifyPrompt? LaterPrompt(SettledClarifyCard card)
    {
        var open = card.Rows.Where(r => r.Answer.Trim().Length == 0).ToList();
        if (open.Count == 0) return null;
        var questions = open.Select((row, i) =>
        {
            var choices = (row.Choices ?? []).Where(c => c.Length <= ClarifyText.MaxChoiceChars).ToList();
            return new ClarifyQuestion($"q{i}", row.Question, choices.Count == 0 ? null : choices,
                choices.Count > 0 && card.Multi.Contains(ClarifyLate.Flat(row.Question)));
        }).ToList();
        return new ClarifyPrompt($"late|{card.Key}", questions, new Dictionary<string, string?>(), false);
    }

    /// Something typed or picked in a dock's draft.
    public static bool HasAnswers(ClarifyDraft draft) =>
        draft.Stages.Values.Any(s => s.Choices.Count > 0 || s.Draft.Trim().Length > 0);

    /// A live question that went unsent with answers typed: it stays as Answer Now's, the same questions (so the typed
    /// draft fits), its card found again at Send.
    public static (SettledClarifyCard Card, ClarifyPrompt Prompt) Kept(ClarifyPrompt gone)
    {
        var questions = gone.Questions;
        var key = ClarifyLate.Key(questions.Select(q => q.Question));
        var rows = questions.Select(q => new ClarifyQA(q.Question, "", true, q.Choices)).ToList();
        var multi = questions.Where(q => q.MultiSelect).Select(q => ClarifyLate.Flat(q.Question)).ToHashSet();
        return (new SettledClarifyCard(rows, key, "", multi, true, false),
            new ClarifyPrompt($"late|{key}", questions, new Dictionary<string, string?>(), false));
    }

    /// The newest settled clarify card asking these questions: its message, and whether a question on it went blank.
    public static (string MessageId, bool HasBlank)? Find(IReadOnlyList<ChatMessage> messages, string key)
    {
        for (var i = messages.Count - 1; i >= 0; i--)
        {
            var message = messages[i];
            if (message.Role != Role.Assistant) continue;
            foreach (var call in message.Tools)
            {
                if (call.Name != "clarify" || ClarifySettled.Parse(call.ResultText) is not { Count: > 0 } rows
                    || ClarifyLate.Key(rows.Select(r => r.Question)) != key) continue;
                return (message.Id, rows.Any(r => r.Answer.Trim().Length == 0));
            }
        }
        return null;
    }

    /// Answer Now's Send: the typed answers (blank ones left out) as the card's message. A dock kept from a live
    /// question has no card yet: its settled card, by the same questions; one whose questions all got answers was
    /// answered on the live request (another device), so nothing more is sent.
    public static LateSendPlan LateSend(SettledClarifyCard card, ClarifyPrompt prompt, ClarifyDraft draft, IReadOnlyList<ChatMessage> messages)
    {
        var answers = ClarifyStaging.SentRows(prompt.Questions, draft.Stages)
            .Where(r => r.Answer != null && r.Answer.Trim().Length > 0)
            .Select(r => (r.Question, r.Answer!)).ToList();
        if (answers.Count == 0) return new LateSendPlan(false, null, card.MessageId);
        var messageId = card.MessageId;
        if (messageId.Length == 0 && Find(messages, card.Key) is { } found)
        {
            messageId = found.MessageId;
            if (!found.HasBlank) return new LateSendPlan(true, null, messageId);
        }
        return new LateSendPlan(true, ClarifyLate.Message(card.Key, answers), messageId);
    }
}
