using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Drafts;
using Hermes.Core.Model;

namespace Hermes.Core.Asks;

public sealed record AskAttachment(string Name, string Note);

public sealed record AskLink(string Title, Uri Url);

/// Where a choice's ready reply goes (asks v2, HermesKit/Asks/AskCards.swift `ReplyTo`).
public sealed record AskReplyTo(string App, string To = "", string Subject = "", string From = "");

/// Parsed payload of `ask_to_act` (HermesKit/Asks/AskCards.swift `Ask`).
public sealed record AskCard(
    string Id,
    string Question,
    string Then,
    IReadOnlyList<string> Choices,
    string App,
    string From,
    string Place,
    string When,
    string Quote,
    IReadOnlyList<AskAttachment> Attachments,
    AskLink? Link,
    IReadOnlyList<string> Replies,
    AskReplyTo? ReplyTo);

public abstract record AskAnswer
{
    public sealed record Choice(int Number, string Words) : AskAnswer;
    public sealed record Other(string Words) : AskAnswer;
    public sealed record Sent(int Number, string ChoiceWords, string Reply) : AskAnswer;
}

/// Port of HermesKit/Asks/AskCards.swift: `ask_to_act` cards (v1 choices + "Something else…" and v2 ready replies),
/// 64 KB whole-args preservation, add-on handshake metadata, calm-chat folding, boilerplate suppression, and markers.
public static class AskCards
{
    public const string Tool = "ask_to_act";
    public const string CardsPath = "/asks/cards";
    public const string MarkLead = "[Hermes HQ ask ";
    public const int MaxArgsBytes = 64_000;
    public const int MaxChoices = 3;
    public const int MaxAttachments = 4;
    public const int MaxReply = 20_000;
    public static readonly IReadOnlyList<string> DefaultChoices = ["Yes", "No"];

    private const string Written = " exactly as written:";
    private const string EditedLead = "I edited it. ";
    private static readonly char[] Newlines = ['\r', '\n', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029'];
    private static readonly Regex MarkRegex = new(
        @"^\s*\[Hermes HQ ask (a-[0-9a-f]{8}): ([1-3]( send)?|other)\]",
        RegexOptions.CultureInvariant);
    private static readonly Regex SendLineRegex = new(
        @"^(?:I edited it\. )?(.*?) Send this (?:to|on) ",
        RegexOptions.CultureInvariant);
    private static readonly Regex ReadyBoilerplateRegex = new(
        @"^(?:(?:the|your)\s+(?:approval|decision|ask|action|confirmation)\s+card\s+is\s+ready(?:\s+(?:above|below|for\s+review|to\s+review))?[.!]?|waiting\s+(?:on\s+you|for\s+your\s+(?:approval|answer|reply|call|confirmation))[.!]?|let\s+me\s+know\s+(?:how\s+you(?:['’]d|\s+would)\s+like\s+to\s+proceed|what\s+you(?:['’]d|\s+would)\s+like\s+(?:me\s+)?to\s+do)[.!]?)$",
        RegexOptions.CultureInvariant);

    // MARK: Shared Contracts

    public static bool IsAskTool(string? name) => name == Tool;

    public static string? RewriteMarkerBubble(string? text) =>
        string.IsNullOrEmpty(text) ? null : BubbleWords(text);

    /// True only when an assistant message's entire prose alongside an ask card is pure card-ready chrome.
    public static bool IsReadyBoilerplate(string? text)
    {
        if (string.IsNullOrEmpty(text)) return false;
        var trimmed = text.Trim();
        if (trimmed.Length == 0 || trimmed.Length > 90) return false;
        if (trimmed.IndexOfAny(Newlines) >= 0) return false;
        if (trimmed.Contains("http://", StringComparison.OrdinalIgnoreCase)
            || trimmed.Contains("https://", StringComparison.OrdinalIgnoreCase)
            || trimmed.Contains('`'))
            return false;
        var collapsed = string.Join(" ", trimmed.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return ReadyBoilerplateRegex.IsMatch(collapsed);
    }

    // MARK: Add-on handshake

    /// `actCards` (not `askCards`, which is the older clarify flag).
    public static bool CardsUntold(JsonObject? status) =>
        status?.Bool("actCards") == true && status?.Bool("actCardsShown") != true;

    public static string? WholeArgsText(string name, JsonObject? args)
    {
        if (name != Tool || args == null || args.Count == 0) return null;
        var text = args.ToJsonString();
        return Encoding.UTF8.GetByteCount(text) <= MaxArgsBytes ? text : null;
    }

    // MARK: Parsing

    public static AskCard? Parse(ToolCall call)
    {
        if (call.Name != Tool || call.State == ToolState.Failed) return null;
        JsonObject? args = null;
        if (!string.IsNullOrWhiteSpace(call.ArgsJson) && J.Parse(call.ArgsJson) is JsonObject jsonObj)
            args = jsonObj;
        else if (!string.IsNullOrWhiteSpace(call.ArgsText) && J.Parse(call.ArgsText) is JsonObject textObj)
            args = textObj;
        return args != null ? Parse(args) : null;
    }

    public static AskCard? Parse(JsonObject o)
    {
        var question = Trimmed(o.Get("question"));
        if (question.Length == 0) return null;

        var rawFrom = Trimmed(o.Get("from"));
        var quote = Trimmed(o.Get("quote"));
        var choices = ParseChoices(o.Get("choices"));
        var app = OneLine(o.Get("app"), 40);

        var attachments = new List<AskAttachment>();
        if (o.Arr("attachments") is { } attArr)
        {
            foreach (var item in attArr)
            {
                if (item is JsonObject ao)
                {
                    var name = OneLine(ao.Get("name"), 80);
                    if (name.Length == 0) continue;
                    attachments.Add(new AskAttachment(name, OneLine(ao.Get("note"), 160)));
                }
                else
                {
                    var name = OneLine(item, 80);
                    if (name.Length == 0) continue;
                    attachments.Add(new AskAttachment(name, ""));
                }
                if (attachments.Count >= MaxAttachments) break;
            }
        }

        AskLink? link = null;
        if (o.Obj("link") is { } lo && ParseHttps(Trimmed(lo.Get("url"))) is { } url)
        {
            var title = OneLine(lo.Get("title"), 60);
            link = new AskLink(title.Length == 0 ? DefaultLinkTitle(app) : title, url);
        }

        IReadOnlyList<string> replies = [];
        AskReplyTo? replyTo = null;
        if (o.Arr("replies") is { } repArr && repArr.Count == choices.Count)
        {
            var parsed = repArr.Select(item =>
            {
                var words = Trimmed(item);
                return words.Length <= MaxReply ? words : "";
            }).ToList();

            if (parsed.Any(r => r.Length > 0))
            {
                var ro = o.Obj("reply_to");
                var replyApp = OneLine(ro?.Get("app"), 40);
                if (replyApp.Length == 0) replyApp = app;
                if (replyApp.Length > 0)
                {
                    replies = parsed;
                    replyTo = new AskReplyTo(
                        App: replyApp,
                        To: OneLine(ro?.Get("to"), 300),
                        Subject: OneLine(ro?.Get("subject"), 300),
                        From: OneLine(ro?.Get("from"), 300));
                }
            }
        }

        return new AskCard(
            Id: Id(question, rawFrom, quote, choices),
            Question: question,
            Then: Trimmed(o.Get("then")),
            Choices: choices,
            App: app,
            From: OneLine(o.Get("from"), 120),
            Place: OneLine(o.Get("where"), 120),
            When: OneLine(o.Get("when"), 60),
            Quote: quote,
            Attachments: attachments,
            Link: link,
            Replies: replies,
            ReplyTo: replyTo);
    }

    public static IReadOnlyList<string> ParseChoices(JsonNode? value)
    {
        var list = new List<string>();
        if (value is JsonArray arr)
        {
            foreach (var item in arr)
            {
                var words = Trimmed(item);
                if (words.Length > 0 && !list.Contains(words, StringComparer.Ordinal))
                    list.Add(words);
            }
        }
        return list.Count >= 2 ? list.Take(MaxChoices).ToList() : DefaultChoices;
    }

    public static string? Reply(AskCard ask, int index)
    {
        if (ask.ReplyTo == null || index < 0 || index >= ask.Replies.Count) return null;
        var reply = ask.Replies[index];
        return reply.Length == 0 ? null : reply;
    }

    public static string DefaultLinkTitle(string app) =>
        string.IsNullOrEmpty(app) ? "Open" : $"Open in {app}";

    /// "a-" and the first 8 hex digits of SHA-256 over `question\nfrom\nquote\n` + choices joined by newlines.
    public static string Id(string question, string from, string quote, IReadOnlyList<string> choices)
    {
        var parts = new List<string>(3 + choices.Count) { question.Trim(), from.Trim(), quote.Trim() };
        foreach (var c in choices) parts.Add(c.Trim());
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(string.Join("\n", parts)));
        return "a-" + Convert.ToHexString(hash.AsSpan(0, 4)).ToLowerInvariant();
    }

    // MARK: Words

    public static string SourceDetail(AskCard ask) =>
        string.Join(" · ", new[] { ask.From, ask.Place, ask.When }.Where(s => s.Length > 0));

    public static string ReplyHeading(AskReplyTo to) =>
        to.To.Length == 0 ? $"Reply on {to.App}" : $"Reply to {to.To} · {to.App}";

    public static string ReplySpoken(AskReplyTo to, string reply) =>
        (to.To.Length == 0 ? $"Reply on {to.App}" : $"Reply to {to.To} on {to.App}") + ": " + reply;

    public static string Sentence(string choice)
    {
        if (choice.Length == 0) return choice;
        var last = choice[^1];
        return last is '.' or '!' or '?' or '…' ? choice : choice + ".";
    }

    public static string ChoiceWords(string line) =>
        line.EndsWith('.') && !line.EndsWith("..", StringComparison.Ordinal) ? line[..^1] : line;

    // MARK: Calm-chat Folding

    public static string RowId(string messageId, string callId) => $"{messageId}|ask{callId}";

    /// Ask row ids left unanswered after a later normal human turn or a later ask card in a subsequent message.
    public static IReadOnlySet<string> StaleRowIds(IReadOnlyList<ChatMessage> messages)
    {
        var lastHumanOrAsk = -1;
        for (var idx = 0; idx < messages.Count; idx++)
        {
            var m = messages[idx];
            if (DraftCards.IsNormalHumanTurn(m))
                lastHumanOrAsk = idx;
            else if (m.Role == Role.Assistant && m.Tools.Any(c => c.Name == Tool && Parse(c) != null))
                lastHumanOrAsk = idx;
        }
        var result = new HashSet<string>(StringComparer.Ordinal);
        if (lastHumanOrAsk <= 0) return result;

        for (var idx = 0; idx < lastHumanOrAsk; idx++)
        {
            var m = messages[idx];
            if (m.Role != Role.Assistant) continue;
            foreach (var call in m.Tools)
                if (call.Name == Tool && Parse(call) != null)
                    result.Add(RowId(m.Id, call.Id));
        }
        return result;
    }

    public static bool IsAdjacentAnswerEcho(IReadOnlyList<ChatMessage> messages, int index, string askId)
    {
        if (index <= 0 || index >= messages.Count) return false;
        for (var scan = index - 1; scan >= 0; scan--)
        {
            var prev = messages[scan];
            if (prev.Role == Role.System) continue;
            if (prev.Role != Role.Assistant) return false;
            return prev.Tools.Any(c => c.Name == Tool && Parse(c) is { } a && a.Id == askId);
        }
        return false;
    }

    // MARK: Answers

    public static string? ChoiceMessage(AskCard ask, int index)
    {
        if (index < 0 || index >= ask.Choices.Count) return null;
        var then = ask.Then.Length == 0 ? "" : $" Go on as you said: {ask.Then}";
        return string.Join("\n",
            $"[Hermes HQ ask {ask.Id}: {index + 1}]",
            Sentence(ask.Choices[index]),
            $"(Your question was: \"{ask.Question}\"{then})");
    }

    public static string OtherMessage(AskCard ask, string text) =>
        string.Join("\n",
            $"[Hermes HQ ask {ask.Id}: other]",
            text.Trim(),
            $"(Your question was: \"{ask.Question}\")");

    public static string? SendMessage(AskCard ask, int index, string reply)
    {
        if (index < 0 || index >= ask.Choices.Count || ask.ReplyTo is not { } to || Reply(ask, index) is not { } own)
            return null;
        var final = reply.Trim();
        var edited = final != own;
        var place = to.To.Length == 0 ? $"Send this on {to.App}" : $"Send this to {to.To} ({to.App})";
        var lines = new List<string>
        {
            $"[Hermes HQ ask {ask.Id}: {index + 1} send]",
            (edited ? EditedLead : "") + Sentence(ask.Choices[index]) + " " + place
                + (to.From.Length == 0 ? "" : $" from {to.From}") + Written,
        };
        if (to.Subject.Length > 0) lines.Add($"Subject: {to.Subject}");
        return string.Join("\n", lines) + "\n\n" + final;
    }

    public static (string Id, AskAnswer Answer)? ParseAnswer(string text)
    {
        if (string.IsNullOrEmpty(text) || !text.TrimStart().StartsWith(MarkLead, StringComparison.Ordinal))
            return null;
        var m = MarkRegex.Match(text);
        if (!m.Success) return null;
        var id = m.Groups[1].Value;
        var kind = m.Groups[2].Value;
        var words = SecondLine(text);
        if (kind == "other") return (id, new AskAnswer.Other(words));
        if (!int.TryParse(kind[..1], out var number)) return null;
        if (!m.Groups[3].Success) return (id, new AskAnswer.Choice(number, words));

        var sendMatch = SendLineRegex.Match(words);
        var choice = sendMatch.Success ? sendMatch.Groups[1].Value : "";
        var rest = text[m.Length..];
        var gap = rest.IndexOf("\n\n", StringComparison.Ordinal);
        var reply = gap >= 0 ? rest[(gap + 2)..].Trim() : "";
        return (id, new AskAnswer.Sent(number, choice, reply));
    }

    public static string? BubbleWords(string text)
    {
        if (ParseAnswer(text) is not { } found) return null;
        switch (found.Answer)
        {
            case AskAnswer.Choice c:
                var words = ChoiceWords(c.Words);
                return words.Length == 0 ? $"Choice {c.Number}" : words;
            case AskAnswer.Other o:
                return o.Words.Length == 0 ? "Something else" : o.Words;
            case AskAnswer.Sent s:
                var choiceWords = ChoiceWords(s.ChoiceWords);
                var send = text.Contains("]\n" + EditedLead, StringComparison.Ordinal)
                    ? "Send it with my edits"
                    : "Send the reply";
                return (choiceWords.Length == 0 ? $"Choice {s.Number}" : choiceWords) + " · " + send;
            default:
                return null;
        }
    }

    public static IReadOnlyDictionary<string, AskAnswer> Answers(IReadOnlyList<ChatMessage> messages, IEnumerable<string>? queued = null)
    {
        var output = new Dictionary<string, AskAnswer>(StringComparer.Ordinal);
        foreach (var message in messages)
        {
            if (message.Role != Role.User) continue;
            foreach (var part in message.Parts.OfType<TextPart>())
                if (ParseAnswer(part.Text) is { } found)
                    output[found.Id] = found.Answer;
        }
        if (queued != null)
            foreach (var text in queued)
                if (ParseAnswer(text) is { } found)
                    output[found.Id] = found.Answer;
        return output;
    }

    public static string StatusText(AskCard ask, AskAnswer answer) => answer switch
    {
        AskAnswer.Choice c =>
            $"You answered: {(c.Number >= 1 && c.Number <= ask.Choices.Count ? ask.Choices[c.Number - 1] : ChoiceWords(c.Words))}",
        AskAnswer.Other o =>
            $"You answered: {(o.Words.Length == 0 ? "something else" : o.Words)}",
        AskAnswer.Sent s =>
            $"You answered: {(s.Number >= 1 && s.Number <= ask.Choices.Count ? ask.Choices[s.Number - 1] : ChoiceWords(s.ChoiceWords))} · Reply approved",
        _ => "You answered",
    };

    // MARK: Helpers

    private static string SecondLine(string text)
    {
        var lines = text.Trim().Split('\n');
        return lines.Length > 1 ? lines[1].Trim() : "";
    }

    private static string Trimmed(JsonNode? value) =>
        value is JsonValue jv && jv.TryGetValue(out string? s) ? s.Trim() : "";

    private static string OneLine(JsonNode? value, int max)
    {
        var raw = Trimmed(value);
        if (raw.Length == 0) return "";
        var collapsed = string.Join(" ", raw.Split(Newlines, StringSplitOptions.RemoveEmptyEntries).Select(l => l.Trim()));
        return collapsed.Length <= max ? collapsed : collapsed[..(max - 1)].Trim() + "…";
    }

    private static Uri? ParseHttps(string text)
    {
        if (!text.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) return null;
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri)) return null;
        return string.IsNullOrEmpty(uri.Host) ? null : uri;
    }
}
