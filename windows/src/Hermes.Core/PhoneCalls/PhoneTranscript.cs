using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.PhoneCalls;

public enum PhoneSpeaker
{
    Assistant,
    Them,
    You,
    System,
}

public sealed record PhoneTranscriptLine(
    string Id,
    PhoneSpeaker Speaker,
    string Text,
    DateTimeOffset? At = null,
    bool Pending = false)
{
    public JsonObject ToJson() => new()
    {
        ["id"] = Id,
        ["speaker"] = Speaker.ToString().ToLowerInvariant(),
        ["text"] = Text,
        ["at"] = At?.ToString("O"),
    };

    public static PhoneTranscriptLine? FromJson(JsonNode? node)
    {
        if (node is not JsonObject) return null;
        var text = node.Text("text");
        if (text == null) return null;
        var speaker = (node.Str("speaker")?.ToLowerInvariant()) switch
        {
            "them" => PhoneSpeaker.Them,
            "you" => PhoneSpeaker.You,
            "system" => PhoneSpeaker.System,
            _ => PhoneSpeaker.Assistant,
        };
        return new PhoneTranscriptLine(node.Text("id") ?? Guid.NewGuid().ToString("N")[..8], speaker, text,
            PhoneCallEvent.ParseTimestamp(node.Str("at")));
    }
}

public sealed record PhoneQuestion(
    string ToolCallId,
    string Question,
    IReadOnlyList<string> Choices,
    DateTimeOffset? AskedAt = null,
    bool Answered = false,
    string? AnswerText = null);

public sealed record PhoneQA(string Question, string Answer)
{
    public JsonObject ToJson() => new() { ["question"] = Question, ["answer"] = Answer };

    public static PhoneQA? FromJson(JsonNode? node)
    {
        if (node is not JsonObject) return null;
        var q = node.Text("question");
        var a = node.Text("answer");
        return q != null && a != null ? new PhoneQA(q, a) : null;
    }
}

public sealed record PhoneTranscriptSnapshot(
    IReadOnlyList<PhoneTranscriptLine> Lines,
    PhoneQuestion? PendingQuestion,
    IReadOnlyList<PhoneQA> QAs);

/// Live call transcript accumulator (`App/PhoneCalls/PhoneTranscript.swift` port):
/// strips `<emotion ...>` tags, suppresses `[long silence]`, deduplicates repeated `ask_owner` tool calls,
/// and merges optimistic owner instructions cleanly.
public static partial class PhoneTranscript
{
    [GeneratedRegex(@"</?emotion\b[^>]*>", RegexOptions.IgnoreCase)]
    private static partial Regex EmotionTagRegex();

    [GeneratedRegex(@"\[long silence\]", RegexOptions.IgnoreCase)]
    private static partial Regex SilenceMarkerRegex();

    [GeneratedRegex(@"\s+")]
    private static partial Regex MultiSpaceRegex();

    public static string CleanText(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "";
        var stripped = EmotionTagRegex().Replace(raw, " ");
        stripped = SilenceMarkerRegex().Replace(stripped, " ");
        return MultiSpaceRegex().Replace(stripped, " ").Trim();
    }

    public static PhoneTranscriptSnapshot Read(
        IReadOnlyList<samplehostMessage> messages,
        IReadOnlyList<PhoneTranscriptLine>? pendingOwnerLines = null,
        IReadOnlyDictionary<string, string>? localAnswers = null)
    {
        var lines = new List<PhoneTranscriptLine>();
        var toolAnswers = new Dictionary<string, string>(StringComparer.Ordinal);
        if (localAnswers != null)
        {
            foreach (var (k, v) in localAnswers) toolAnswers[k] = v;
        }

        // First pass: capture tool responses.
        foreach (var msg in messages)
        {
            if (string.Equals(msg.Role, "tool", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrEmpty(msg.ToolCallId))
            {
                var cleaned = CleanText(msg.Text);
                if (cleaned.Length > 0) toolAnswers[msg.ToolCallId!] = cleaned;
            }
        }

        var seenQuestions = new Dictionary<string, PhoneQuestion>(StringComparer.OrdinalIgnoreCase);
        var questionOrder = new List<string>();
        var confirmedOwnerTexts = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var msg in messages)
        {
            var role = msg.Role.Trim().ToLowerInvariant();
            if (role == "tool") continue;

            if (msg.ToolCalls != null)
            {
                foreach (var tc in msg.ToolCalls)
                {
                    if (!string.Equals(tc.Name, PhoneAskOwner.ToolName, StringComparison.OrdinalIgnoreCase)) continue;
                    var parsed = ParseAskOwner(tc, msg.CreatedAt, toolAnswers);
                    if (parsed == null) continue;
                    var normKey = parsed.Question.Trim();
                    if (!seenQuestions.TryGetValue(normKey, out var existing))
                    {
                        seenQuestions[normKey] = parsed;
                        questionOrder.Add(normKey);
                    }
                    else if (!existing.Answered && parsed.Answered)
                    {
                        seenQuestions[normKey] = parsed;
                    }
                    else if (!parsed.Answered)
                    {
                        // Keep newest unanswered tool call id so replies reach the live invocation.
                        seenQuestions[normKey] = parsed;
                    }
                }
            }

            var text = CleanText(msg.Text);
            if (text.Length == 0) continue;

            if (role == "system")
            {
                const string prefix = "Owner instruction:";
                if (text.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                {
                    var body = text[prefix.Length..].Trim();
                    if (body.Length > 0)
                    {
                        confirmedOwnerTexts.Add(body);
                        lines.Add(new PhoneTranscriptLine(msg.Id, PhoneSpeaker.You, body, msg.CreatedAt));
                    }
                }
                continue;
            }

            var speaker = role switch
            {
                "user" => PhoneSpeaker.Them,
                "assistant" => PhoneSpeaker.Assistant,
                _ => PhoneSpeaker.System,
            };
            lines.Add(new PhoneTranscriptLine(msg.Id, speaker, text, msg.CreatedAt));
        }

        // Merge optimistic owner lines not yet echoed back by samplehost.
        if (pendingOwnerLines != null)
        {
            foreach (var pending in pendingOwnerLines)
            {
                var clean = CleanText(pending.Text);
                if (clean.Length > 0 && !confirmedOwnerTexts.Contains(clean))
                    lines.Add(pending with { Text = clean, Pending = true });
            }
        }

        // Cap retained lines to PhoneLimits.MaxLinesPerCall (newest preserved).
        if (lines.Count > PhoneLimits.MaxLinesPerCall)
            lines = lines.Skip(lines.Count - PhoneLimits.MaxLinesPerCall).ToList();

        var qas = new List<PhoneQA>();
        PhoneQuestion? pendingQuestion = null;
        foreach (var key in questionOrder)
        {
            var q = seenQuestions[key];
            if (q.Answered && !string.IsNullOrWhiteSpace(q.AnswerText))
                qas.Add(new PhoneQA(q.Question, q.AnswerText!));
            else
                pendingQuestion = q;
        }

        return new PhoneTranscriptSnapshot(lines, pendingQuestion, qas);
    }

    private static PhoneQuestion? ParseAskOwner(samplehostToolCall tc, DateTimeOffset? at, IReadOnlyDictionary<string, string> answers)
    {
        var args = J.Parse(tc.ArgumentsJson);
        var question = CleanText(args.Str("question"));
        if (question.Length == 0) return null;
        var choices = (args.Arr("choices") ?? [])
            .Select(J.AsString)
            .OfType<string>()
            .Select(CleanText)
            .Where(s => s.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(6)
            .ToList();
        var answered = answers.TryGetValue(tc.Id, out var answerText) && !string.IsNullOrWhiteSpace(answerText);
        return new PhoneQuestion(tc.Id, question, choices, at, answered, answered ? answerText : null);
    }
}
