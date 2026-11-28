using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Model;
using Hermes.Core.Travel;

namespace Hermes.Core.Drafts;

/// One earlier message of the conversation a draft answers (`thread`) (HermesKit/Drafts/DraftCards.swift `Message`).
public sealed record DraftThreadMessage(string From, string When, string Text);

/// Parsed payload of `draft_message` (HermesKit/Drafts/DraftCards.swift `Draft`).
public sealed record Draft(
    string Id,
    string App,
    string To,
    string Cc,
    string Bcc,
    string Subject,
    string Body,
    string From,
    string AppName,
    string Via,
    IReadOnlyList<DraftThreadMessage> Thread);

/// One labelled header field on the draft card: To, Cc, Bcc, From, Via, Subject (HermesKit/Drafts/DraftCards.swift `Field`).
public sealed record DraftField(string Label, string Value, bool Strong = false, bool People = false);

public abstract record DraftAnswer
{
    public sealed record Send(string? Body) : DraftAnswer;
    public sealed record Skip : DraftAnswer;
}

public enum DraftState
{
    Waiting,
    Sent,
    Skipped,
    Superseded,
    Stale,
}

/// Port of HermesKit/Drafts/DraftCards.swift: `draft_message` cards with To/Cc/Bcc/From/Via/Subject/Body/Thread,
/// 12-name recipient cap, calm-chat superseding & stale folding, ready boilerplate detection, and transcript markers.
public static class DraftCards
{
    public const string Tool = "draft_message";
    public const string CardsPath = "/drafts/cards";
    public const string MarkLead = "[Hermes HQ draft ";
    public const int MaxArgsBytes = 256_000;
    public const int MaxThread = 30;
    public const int PeopleShown = 12;
    public const int PeopleNameLength = 80;

    private const string Written = " exactly as written:";
    private const string EditedLead = "I edited it. ";
    private static readonly char[] Newlines = ['\r', '\n', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029'];
    private static readonly string[] AppBreaks = [" — ", " – ", " - ", " (", ", ", ": ", " from ", " via "];
    private static readonly Regex MarkRegex = new(
        @"^\s*\[Hermes HQ draft (d-[0-9a-f]{8}): (send|skip)\]",
        RegexOptions.CultureInvariant);
    private static readonly Regex ReadyBoilerplateRegex = new(
        @"^(?:(?:your|the)\s+(?:(?:revised|updated|new|corrected)\s+)?(?:[a-z0-9][a-z0-9&/-]{0,18}(?:\s+[a-z0-9&/-]{1,12})?\s+)?(?:draft|text|message|email|reply|note)(?:\s+(?:for|to)\s+[^.!?\n]{1,60})?\s+is\s+ready(?:\s+(?:to|for)\s+(?:review|send|sending|your\s+(?:review|approval)))?[.!]?(?:\s+nothing(?:['’]s|\s+has)\s+been\s+sent(?:\s+yet)?[.!]?)?|nothing(?:['’]s|\s+has)\s+been\s+sent(?:\s+yet)?[.!]?)$",
        RegexOptions.CultureInvariant);

    // MARK: Shared Contracts

    public static bool IsDraftTool(string? name) => name == Tool;

    public static string? RewriteMarkerBubble(string? text) =>
        string.IsNullOrEmpty(text) ? null : BubbleWords(text);

    /// True only when an assistant message's entire prose alongside a draft card is stock "Your draft is ready to
    /// review. Nothing's been sent." boilerplate carrying no extra commentary.
    public static bool IsReadyBoilerplate(string? text)
    {
        if (string.IsNullOrEmpty(text)) return false;
        var trimmed = text.Trim();
        if (trimmed.Length == 0 || trimmed.Length > 140) return false;
        if (trimmed.IndexOfAny(Newlines) >= 0) return false;
        if (trimmed.Contains("http://", StringComparison.OrdinalIgnoreCase)
            || trimmed.Contains("https://", StringComparison.OrdinalIgnoreCase)
            || trimmed.Contains('`'))
            return false;
        var collapsed = string.Join(" ", trimmed.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return ReadyBoilerplateRegex.IsMatch(collapsed);
    }

    // MARK: Add-on handshake

    public static bool CardsUntold(JsonObject? status) =>
        status?.Bool("draftCards") == true && status?.Bool("draftCardsShown") != true;

    public static string? WholeArgsText(string name, JsonObject? args)
    {
        if (name != Tool || args == null || args.Count == 0) return null;
        var text = args.ToJsonString();
        return Encoding.UTF8.GetByteCount(text) <= MaxArgsBytes ? text : null;
    }

    // MARK: Parsing

    public static Draft? Parse(ToolCall call)
    {
        if (call.Name != Tool || call.State == ToolState.Failed) return null;
        JsonObject? args = null;
        if (!string.IsNullOrWhiteSpace(call.ArgsJson) && J.Parse(call.ArgsJson) is JsonObject jsonObj)
            args = jsonObj;
        else if (!string.IsNullOrWhiteSpace(call.ArgsText) && J.Parse(call.ArgsText) is JsonObject textObj)
            args = textObj;
        return args != null ? Parse(args) : null;
    }

    public static Draft? Parse(JsonObject args)
    {
        var body = Trimmed(args.Get("body"));
        var app = Trimmed(args.Get("app"));
        if (body.Length == 0 || app.Length == 0) return null;
        var to = Trimmed(args.Get("to"));
        var subject = Trimmed(args.Get("subject"));
        var cc = ParseRecipients(args.Get("cc"));
        var bcc = ParseRecipients(args.Get("bcc"));
        var parts = SplitApp(app);
        var from = Trimmed(args.Get("from"));
        return new Draft(
            Id: Id(app, to, subject, body),
            App: app,
            To: to,
            Cc: cc,
            Bcc: bcc,
            Subject: subject,
            Body: body,
            From: from.Length == 0 ? parts.From : from,
            AppName: parts.Name,
            Via: parts.Via,
            Thread: ParseThread(args.Get("thread")));
    }

    /// Reads an optional recipient list (`cc` / `bcc`): string or string array, one line joined by ", ".
    public static string ParseRecipients(JsonNode? value)
    {
        var raw = new List<string>();
        if (value is JsonArray arr)
        {
            foreach (var item in arr)
                if (item is JsonValue jv && jv.TryGetValue(out string? s))
                    raw.Add(s);
        }
        else if (value is JsonValue jv && jv.TryGetValue(out string? s))
        {
            raw.Add(s);
        }

        var parts = new List<string>();
        foreach (var entry in raw)
        {
            foreach (var line in entry.Split(Newlines, StringSplitOptions.RemoveEmptyEntries))
            {
                var cleaned = line.Trim().Trim(',', ';').Trim();
                if (cleaned.Length > 0) parts.Add(cleaned);
            }
        }
        return string.Join(", ", parts);
    }

    public static IReadOnlyList<DraftThreadMessage> ParseThread(JsonNode? value)
    {
        if (value is not JsonArray arr) return [];

        static string First(JsonObject o, string[] keys)
        {
            foreach (var k in keys)
            {
                var found = Trimmed(o.Get(k));
                if (found.Length > 0) return found;
            }
            return "";
        }

        var messages = new List<DraftThreadMessage>();
        foreach (var item in arr)
        {
            if (item is JsonObject obj)
            {
                var text = First(obj, ["text", "body", "content", "message"]);
                if (text.Length == 0) continue;
                messages.Add(new DraftThreadMessage(
                    From: First(obj, ["from", "sender", "author", "name"]),
                    When: First(obj, ["when", "time", "date", "sent"]),
                    Text: text));
            }
            else
            {
                var text = Trimmed(item);
                if (text.Length > 0)
                    messages.Add(new DraftThreadMessage("", "", text));
            }
        }
        return messages.Count <= MaxThread ? messages : messages.GetRange(messages.Count - MaxThread, MaxThread);
    }

    /// Splits "Email — from me@x.com" or "Slack (Acme workspace)" into `(Name, From, Via)`.
    public static (string Name, string From, string Via) SplitApp(string app)
    {
        var bestIndex = -1;
        var bestLength = 0;
        foreach (var mark in AppBreaks)
        {
            var idx = app.IndexOf(mark, StringComparison.OrdinalIgnoreCase);
            if (idx > 0 && (bestIndex < 0 || idx < bestIndex))
            {
                bestIndex = idx;
                bestLength = mark.Length;
            }
        }
        if (bestIndex <= 0) return (app, "", "");

        var name = app[..bestIndex].Trim();
        var lead = app.Substring(bestIndex, bestLength).Trim().ToLowerInvariant();
        var rest = app[(bestIndex + bestLength)..].Trim(' ', ')');
        var isFrom = lead == "from";
        foreach (var word in new[] { "from ", "via " })
        {
            if (rest.StartsWith(word, StringComparison.OrdinalIgnoreCase))
            {
                isFrom = word == "from ";
                rest = rest[word.Length..].Trim();
                break;
            }
        }
        if (name.Length == 0 || rest.Length == 0) return (app, "", "");
        return isFrom ? (name, rest, "") : (name, "", rest);
    }

    /// "d-" and the first 8 hex digits of SHA-256 over `app\nto\nsubject\nbody`, matching drafts.py `draft_id`.
    public static string Id(string app, string to, string subject, string body)
    {
        var payload = string.Join("\n", app, to, subject, body);
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(payload));
        return "d-" + Convert.ToHexString(hash.AsSpan(0, 4)).ToLowerInvariant();
    }

    // MARK: Words & Fields

    public static string Name(Draft draft) =>
        string.IsNullOrEmpty(draft.AppName) ? draft.App : draft.AppName;

    public static string Place(Draft draft) =>
        string.IsNullOrEmpty(draft.To) ? Name(draft) : $"{draft.To} ({Name(draft)})";

    public static string Heading(Draft draft) => $"{Name(draft)} draft";

    public static string ThreadTitle(Draft draft) =>
        draft.Thread.Count == 1 ? "Show Whole Message" : $"Show Conversation ({draft.Thread.Count})";

    /// Header fields in letter order: To, Cc, Bcc, From, Via, Subject (omitting empty values).
    public static IReadOnlyList<DraftField> Fields(Draft draft)
    {
        var list = new List<DraftField>(6);
        if (draft.To.Length > 0) list.Add(new DraftField("To", draft.To, People: true));
        if (draft.Cc.Length > 0) list.Add(new DraftField("Cc", draft.Cc, People: true));
        if (draft.Bcc.Length > 0) list.Add(new DraftField("Bcc", draft.Bcc, People: true));
        if (draft.From.Length > 0) list.Add(new DraftField("From", draft.From));
        if (draft.Via.Length > 0) list.Add(new DraftField("Via", draft.Via));
        if (draft.Subject.Length > 0) list.Add(new DraftField("Subject", draft.Subject, Strong: true));
        return list;
    }

    /// Formats a comma-separated recipient list with a 12-name cap (", and N more" when > 13 names).
    public static string ShownPeople(string value)
    {
        var names = value.Split(',')
            .Select(n => n.Trim())
            .Where(n => n.Length > 0)
            .Select(n => n.Length > PeopleNameLength ? n[..PeopleNameLength] + "…" : n)
            .ToList();
        if (names.Count <= PeopleShown + 1)
            return string.Join(", ", names);
        return string.Join(", ", names.Take(PeopleShown)) + $", and {names.Count - PeopleShown} more";
    }

    public static string? StatusText(DraftState state, bool edited) => state switch
    {
        DraftState.Waiting => null,
        DraftState.Sent => edited ? "Approved to send, with your edits" : "Approved to send",
        DraftState.Skipped => "Not sent",
        DraftState.Superseded => "Revised below",
        DraftState.Stale => "Left unsent",
        _ => null,
    };

    // MARK: Calm-chat Superseding & Stale Folding

    public static string TargetKey(Draft draft)
    {
        var app = Name(draft).Trim().ToLowerInvariant();
        var to = draft.To.Trim().ToLowerInvariant();
        if (to.Length > 0) return $"{app}|{to}";
        var subject = draft.Subject.Trim().ToLowerInvariant();
        return $"{app}||{subject}";
    }

    public static string RowId(string messageId, string callId) => $"{messageId}|draft{callId}";

    /// A normal human turn (typed message, voice memo, attachment) — not a bot/sender delivery or synthetic card echo.
    public static bool IsNormalHumanTurn(ChatMessage message)
    {
        if (message.Role != Role.User || message.Sender != null) return false;
        var text = string.Join("\n", message.Parts.OfType<TextPart>().Select(p => p.Text)).Trim();
        if (text.StartsWith(MarkLead, StringComparison.Ordinal)
            || text.StartsWith("[Hermes HQ ask ", StringComparison.Ordinal)
            || text.StartsWith("[Hermes HQ question ", StringComparison.Ordinal)
            || text.StartsWith("[Hermes HQ order ", StringComparison.Ordinal)
            || text.StartsWith(TravelCards.Lead, StringComparison.Ordinal))
            return false;
        return true;
    }

    /// Draft row ids superseded by a later draft to the same destination (`TargetKey`), OR by a later draft on the
    /// same app after an intervening human turn.
    public static IReadOnlySet<string> SupersededRowIds(IReadOnlyList<ChatMessage> messages)
    {
        var latestByTarget = new Dictionary<string, string>(StringComparer.Ordinal);
        var all = new List<(string Target, string App, int MsgIndex, string RowId)>();
        var humanTurnsBefore = new int[messages.Count];
        var turns = 0;

        for (var idx = 0; idx < messages.Count; idx++)
        {
            humanTurnsBefore[idx] = turns;
            var message = messages[idx];
            if (IsNormalHumanTurn(message)) turns++;
            if (message.Role != Role.Assistant) continue;
            foreach (var call in message.Tools)
            {
                if (call.Name != Tool || Parse(call) is not { } draft) continue;
                var target = TargetKey(draft);
                var app = Name(draft).Trim().ToLowerInvariant();
                var rowId = RowId(message.Id, call.Id);
                latestByTarget[target] = rowId;
                all.Add((target, app, idx, rowId));
            }
        }

        var result = new HashSet<string>(StringComparer.Ordinal);
        if (all.Count <= 1) return result;

        var latestAppTurn = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var entry in all)
        {
            if (entry.App.Length == 0) continue;
            var cur = latestAppTurn.TryGetValue(entry.App, out var prev) ? prev : -1;
            latestAppTurn[entry.App] = Math.Max(cur, humanTurnsBefore[entry.MsgIndex]);
        }

        foreach (var entry in all)
        {
            if (latestByTarget[entry.Target] != entry.RowId)
                result.Add(entry.RowId);
            else if (entry.App.Length > 0
                && latestAppTurn.TryGetValue(entry.App, out var latest)
                && latest > humanTurnsBefore[entry.MsgIndex])
                result.Add(entry.RowId);
        }
        return result;
    }

    /// Draft row ids left unanswered after at least 2 later normal human turns.
    public static IReadOnlySet<string> StaleRowIds(IReadOnlyList<ChatMessage> messages)
    {
        var totalHumanTurns = 0;
        foreach (var m in messages)
            if (IsNormalHumanTurn(m)) totalHumanTurns++;
        var result = new HashSet<string>(StringComparer.Ordinal);
        if (totalHumanTurns < 2) return result;

        var turnsSoFar = 0;
        foreach (var message in messages)
        {
            if (IsNormalHumanTurn(message)) { turnsSoFar++; continue; }
            if (message.Role != Role.Assistant) continue;
            if (totalHumanTurns - turnsSoFar < 2) break;
            foreach (var call in message.Tools)
            {
                if (call.Name == Tool && Parse(call) != null)
                    result.Add(RowId(message.Id, call.Id));
            }
        }
        return result;
    }

    /// True when `messages[index]` is a synthetic draft-card tap immediately answering a draft in the preceding non-system message.
    public static bool IsAdjacentAnswerEcho(IReadOnlyList<ChatMessage> messages, int index, string draftId)
    {
        if (index <= 0 || index >= messages.Count) return false;
        for (var scan = index - 1; scan >= 0; scan--)
        {
            var prev = messages[scan];
            if (prev.Role == Role.System) continue;
            if (prev.Role != Role.Assistant) return false;
            return prev.Tools.Any(c => c.Name == Tool && Parse(c) is { } d && d.Id == draftId);
        }
        return false;
    }

    // MARK: Sending & Answers

    public static string SendMessage(Draft draft, string body) =>
        SendMessage(draft, body, to: null, cc: null, bcc: null, subject: null);

    public static string SendMessage(Draft draft, string body, string? to, string? cc, string? bcc, string? subject)
    {
        var finalBody = body.Trim();
        var effectiveTo = to != null ? to.Trim() : draft.To;
        var effectiveCc = cc != null ? NormalizeRecipients(cc) : draft.Cc;
        var effectiveBcc = bcc != null ? NormalizeRecipients(bcc) : draft.Bcc;
        var effectiveSubject = subject != null ? subject.Trim() : draft.Subject;
        var effective = draft with
        {
            To = effectiveTo,
            Cc = effectiveCc,
            Bcc = effectiveBcc,
            Subject = effectiveSubject,
        };
        var edited = finalBody != draft.Body
            || effectiveTo != draft.To
            || effectiveCc != draft.Cc
            || effectiveBcc != draft.Bcc
            || effectiveSubject != draft.Subject;

        var lines = new List<string>
        {
            $"[Hermes HQ draft {draft.Id}: send]",
            (edited ? EditedLead : "")
                + (effective.To.Length == 0 ? $"Send this on {Name(effective)}" : $"Send this to {Place(effective)}")
                + (effective.From.Length == 0 ? "" : $" from {effective.From}")
                + (effective.Via.Length == 0 ? "" : $" ({effective.Via})")
                + Written,
        };
        if (effective.Cc.Length > 0) lines.Add($"Cc: {effective.Cc}");
        if (effective.Bcc.Length > 0) lines.Add($"Bcc: {effective.Bcc}");
        if (effective.Subject.Length > 0) lines.Add($"Subject: {effective.Subject}");
        return string.Join("\n", lines) + "\n\n" + finalBody;
    }

    public static string SkipMessage(Draft draft) =>
        $"[Hermes HQ draft {draft.Id}: skip]\nDon't send this draft.";

    public static (string Id, DraftAnswer Answer)? ParseAnswer(string text)
    {
        if (string.IsNullOrEmpty(text) || !text.TrimStart().StartsWith(MarkLead, StringComparison.Ordinal))
            return null;
        var m = MarkRegex.Match(text);
        if (!m.Success) return null;
        var id = m.Groups[1].Value;
        if (m.Groups[2].Value == "skip") return (id, new DraftAnswer.Skip());
        var rest = text[m.Length..];
        var gap = rest.IndexOf("\n\n", StringComparison.Ordinal);
        if (gap < 0) return (id, new DraftAnswer.Send(null));
        var body = rest[(gap + 2)..].Trim();
        return (id, new DraftAnswer.Send(body.Length == 0 ? null : body));
    }

    public static string? BubbleWords(string text)
    {
        if (ParseAnswer(text) is not { } found) return null;
        return found.Answer switch
        {
            DraftAnswer.Skip => "Don’t send it",
            DraftAnswer.Send => text.Contains("]\n" + EditedLead, StringComparison.Ordinal)
                ? "Send it with my edits"
                : "Send it",
            _ => null,
        };
    }

    public static IReadOnlyDictionary<string, DraftAnswer> Answers(IReadOnlyList<ChatMessage> messages, IEnumerable<string>? queued = null)
    {
        var output = new Dictionary<string, DraftAnswer>(StringComparer.Ordinal);
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

    // MARK: Helpers

    private static string NormalizeRecipients(string raw)
    {
        var parts = raw.Split(Newlines, StringSplitOptions.RemoveEmptyEntries)
            .Select(l => l.Trim().Trim(',', ';').Trim())
            .Where(l => l.Length > 0);
        return string.Join(", ", parts);
    }

    private static string Trimmed(JsonNode? value) =>
        value is JsonValue jv && jv.TryGetValue(out string? s) ? s.Trim() : "";
}
