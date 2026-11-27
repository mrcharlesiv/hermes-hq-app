using System.Collections.Concurrent;
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Gateways;
using Hermes.Core.Questions;

namespace Hermes.Core.Notifications;

/// Who an alert is from (HermesKit/Push/NotificationText.swift NotificationWho): the bot's display name, the chat's own
/// title, its group room, and whether it is a bot's chat (a plain chat is titled by its title).
public sealed record NotificationWho(string Sender = "", string Chat = "", string Group = "", bool Bot = false);

/// An alert's words: title (who), subtitle (which chat), body (what).
public sealed record NotificationCopy(string Title, string Subtitle, string Body);

/// Alert words (HermesKit/Push/NotificationText.swift, the web's notification-preview.ts and redactPrivate; the cases
/// all of them agree on are Tests/Fixtures/push/notification-preview-cases.json). Who an alert is from, what it says
/// (a reply's first words, why a reply failed), with secrets masked. Pure .NET: no Windows APIs.
///
/// Lengths count what a person sees as one character (text elements), as Swift's `String.count` does.
public static class NotificationText
{
    /// How much of an alert's lines each part stays within (notification-preview.ts PREVIEW_MAX).
    public const int PreviewMax = 180;
    public const string Redacted = "••••";

    /// Alert copy per kind (docs/notifications.md; NotificationText.notification). The title says who (the bot's name,
    /// "Ivy · Room" in a group room, a plain chat's own title), the subtitle which chat, the body what. With Show
    /// Previews off an alert only says who needs you. A sender nobody could name is never guessed.
    public static NotificationCopy Notification(string kind, NotificationWho? who, string? text, string? title = null,
        string? body = null, bool previews = true)
    {
        string Passed(string? value, string fallback)
        {
            if (value == null) return fallback;
            var v = Prefix(Redact(OneLine(value)), 240);
            return v.Length == 0 ? fallback : v;
        }
        switch (kind)
        {
            case "test": return new(Passed(title, "Hermes HQ"), "", Passed(body, "Notifications are working."));
            case "plugin": return new(Passed(title, "Hermes HQ"), "", previews ? Passed(body, "Notifications are working.") : "Open Hermes HQ to see what’s new");
            case "credits": return new(Passed(title, "Credits"), "", previews ? Passed(body, "Your credit balance changed.") : "Your credit balance changed");
        }
        var named = Sanitized(who ?? new NotificationWho());
        var sender = named.Sender;
        var group = named.Group;
        var chat = GenericChat(named.Chat) || named.Chat == sender ? "" : named.Chat;
        var bot = who?.Bot == true || group.Length > 0;
        var name = group.Length > 0 ? (sender.Length == 0 ? group : $"{sender} · {group}") : bot || chat.Length == 0 ? sender : chat;
        var approval = kind is "approval.request" or "approval";
        var reply = kind is "message.complete" or "turnDone";
        if (!previews)
        {
            var from = sender.Length == 0 ? group : group.Length == 0 ? sender : $"{sender} in {group}";
            var quiet = approval ? (from.Length == 0 ? "A request needs your approval" : $"{from} needs your approval")
                : kind == "input" ? (from.Length == 0 ? "A question is waiting for your answer" : $"{from} is waiting for your answer")
                : reply ? (from.Length == 0 ? "New reply" : $"New reply from {from}")
                : kind == "turnError" ? (from.Length == 0 ? "A reply couldn’t finish" : $"{from} couldn’t finish a reply")
                : kind == "backgroundDone" ? "A background task finished" : "Open Hermes HQ to see what’s new";
            return new("", "", quiet);
        }
        var fallback = approval ? "Approval needed" : kind == "input" ? "Question" : reply ? "New reply" : kind == "turnError" ? "Reply failed"
            : kind == "backgroundDone" ? "Background task" : "Hermes HQ";
        var heading = name.Length == 0 ? fallback : name;
        var subtitle = group.Length == 0 && chat != heading ? chat : "";
        var shown = Preview(text ?? "");
        string line;
        switch (kind)
        {
            case "approval.request" or "approval":
                var command = CommandSummary(text ?? "");
                var about = Preview(body ?? "");
                line = command.Length > 0 ? $"Wants to run: {command}" : about.Length == 0 ? "Needs your approval" : about;
                break;
            case "input": line = shown.Length == 0 ? "Waiting for your answer" : shown; break;
            case "message.complete" or "turnDone": line = shown.Length == 0 ? "New reply" : shown; break;
            case "turnError": line = shown.Length == 0 ? "Couldn’t finish this reply" : $"Couldn’t finish: {ErrorSentence(Preview(text ?? "", 150))}"; break;
            case "backgroundDone": line = shown.Length == 0 ? "A background task finished" : shown; break;
            default: line = shown.Length == 0 ? "Open Hermes HQ to see what’s new" : shown; break;
        }
        return new(heading, subtitle, line);
    }

    /// Who, as an alert may show it anywhere: one line, masked, bounded.
    public static NotificationWho Sanitized(NotificationWho who)
    {
        static string Named(string value, int max) => Clip(Redact(OneLine(value)), max);
        return new(Named(who.Sender, 60), Named(who.Chat, 80), Named(who.Group, 60), who.Bot);
    }

    /// Titles the gateway or the app give a chat nobody named: the alert says the bot's name instead.
    public static bool GenericChat(string title) =>
        title.ToLowerInvariant() is "" or "bot chat" or "new chat" or "new session" or "new conversation" or "untitled" or "untitled chat"
            or "untitled session" or "chat";

    public static string OneLine(string text) => Replace(text, @"\s+", _ => " ").Trim();

    /// What a value request's alert says (its sheet's words, shortened; NotificationText.valueRequestLine): only a secret
    /// request carries a `prompt`, so the others name what they want instead of all reading "A password or secret is needed".
    public static string ValueRequestLine(PromptKind kind, JsonObject? parameters)
    {
        string? Value(string key) =>
            parameters?[key] is JsonValue v && v.TryGetValue(out string? s) && s.Trim() is { Length: > 0 } t ? t : null;
        return kind switch
        {
            PromptKind.Sudo => "Your administrator password is needed",
            PromptKind.VaultUnlock => $"Unlock {Value("display_name") ?? Value("backend") ?? "your password manager"} to continue",
            PromptKind.VaultSaveLogin => (Value("site") ?? Value("origin")) is { } site ? $"Save your {site} login?" : "Save a login?",
            PromptKind.VaultCode => Value("site") is { } code ? $"A verification code for {code} is needed" : "A verification code is needed",
            _ => Value("prompt") ?? "A password or secret is needed",
        };
    }

    /// Whether an alert showing this command summary may offer Approve (NotificationText.approvable): the whole command
    /// is on it (no "…": one line, not clipped) and none of it masked (a masked value can hide more of the command).
    /// Otherwise the alert only opens the chat, where the whole command is shown.
    public static bool Approvable(string summary) => summary.Length > 0 && !summary.EndsWith('…') && !summary.Contains(Redacted);

    /// A reply, question or result as its alert shows it: plain text, secrets masked, one line, clipped.
    public static string Preview(string markdown, int max = PreviewMax) => Clip(OneLine(Redact(PlainText(Redact(markdown)))), max);

    /// At most `max` characters, cut at a word when one ends in the last 40%, with an ellipsis.
    public static string Clip(string text, int max = PreviewMax)
    {
        if (Count(text) <= max) return text;
        var cut = Prefix(text, max - 1);
        var space = cut.LastIndexOf(' ');
        if (space >= 0 && Count(cut[..space]) >= (int)(max * 0.6)) cut = cut[..space];
        return Replace(cut, @"[\s,.;:!?\-–—]+$", _ => "") + "…";
    }

    /// A command awaiting approval: its first line, masked and clipped ("…" when more lines follow).
    public static string CommandSummary(string command, int max = 120)
    {
        var lines = command.Split(NewLines).Select(l => l.Trim(' ', '\t')).Where(l => l.Trim().Length > 0).ToList();
        if (lines.Count == 0) return "";
        var line = Clip(Replace(Redact(lines[0]), @"\s+", _ => " "), max);
        return lines.Count > 1 && !line.EndsWith('…') ? line + " …" : line;
    }

    private static readonly char[] NewLines = ['\n', '\r', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029'];

    /// "Couldn’t finish: <reason>" reads as one sentence: a leading common word loses its capital.
    public static string ErrorSentence(string reason)
    {
        var text = Replace(reason.Trim(), @"\.+$", _ => "");
        var word = new string(text.TakeWhile(c => c < 128 && char.IsLetter(c)).ToArray()).ToLowerInvariant();
        return word is "usage" or "this" or "the" or "your" or "that" or "a" or "an" or "it" or "there" && text.Length > 0
            ? text[..1].ToLowerInvariant() + text[1..]
            : text;
    }

    private static readonly Dictionary<string, string> KnownErrors = new()
    {
        ["auth"] = "the AI service rejected the sign-in", ["auth_permanent"] = "the AI service rejected the sign-in", ["billing"] = "out of credits",
        ["context_overflow"] = "this conversation is too long", ["payload_too_large"] = "this message is too large", ["timeout"] = "the reply timed out",
        ["stream_drop"] = "the reply was cut off", ["overloaded"] = "the AI service is overloaded", ["server_error"] = "the AI service had a problem",
        ["model_not_found"] = "this model isn’t available", ["content_policy_blocked"] = "the AI service declined this request",
        ["disk_full"] = $"the disk on {HostWord.Phrase} is full", ["loop_error"] = "Hermes got stuck in a loop",
    };

    /// Why a turn failed, in a few words: a usage limit and when it lifts, a chat open elsewhere, a known error code,
    /// else the gateway's first sentence. The time is in this PC's own format (Swift: the locale's "jmm" /
    /// "EEEMMMdjmm" templates).
    public static string ErrorReason(string error, string? code = null, string? provider = null, double? resetsAt = null,
        DateTimeOffset? now = null, CultureInfo? culture = null, TimeZoneInfo? zone = null)
    {
        var at0 = now ?? DateTimeOffset.UtcNow;
        var nowSeconds = at0.ToUnixTimeMilliseconds() / 1000.0;
        const string limit = @"\b429\b|usage[_ ]limit|rate[_ ]?limit|quota (?:is )?(?:exhausted|exceeded)|too many requests";
        if (code is "rate_limit" or "upstream_rate_limit" || Matches(error, limit, RegexOptions.IgnoreCase))
        {
            var at = resetsAt;
            if (at == null && First(error, @"resets?_at[""'\s:=]+(\d{10})\b", RegexOptions.IgnoreCase) is { } stamp) at = double.Parse(stamp, CultureInfo.InvariantCulture);
            if (at == null)
                foreach (var wait in new[] { @"retry after\s+(\d+(?:\.\d+)?)\s*s", @"resets?_in_seconds[""'\s:=]+(\d+)", @"retry-after[""'\s:=]+(\d+)", @"resets? in\s+(\d+)\s*s(?:ec(?:ond)?s?)?\b" })
                    if (First(error, wait, RegexOptions.IgnoreCase) is { } s && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds))
                    {
                        at = nowSeconds + seconds;
                        break;
                    }
            var who = !string.IsNullOrEmpty(provider) ? provider[..1].ToUpperInvariant() + provider[1..] + " usage limit" : "Usage limit";
            if (at is not { } when || when <= nowSeconds) return ErrorSentence($"{who} reached");
            var tz = zone ?? TimeZoneInfo.Local;
            var c = culture ?? CultureInfo.CurrentCulture;
            var local = TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds((long)(when * 1000)), tz);
            var today = TimeZoneInfo.ConvertTime(at0, tz);
            var time = local.ToString(c.DateTimeFormat.ShortTimePattern, c);
            var shown = local.Date == today.Date ? time : local.ToString("ddd, MMM d", c) + ", " + time;
            return ErrorSentence($"{who} reached until {shown}");
        }
        if (code == "SESSION_NOT_OWNED" || Matches(error, "open in another Hermes window|another live owner|SESSION_NOT_OWNED|session has another", RegexOptions.IgnoreCase))
            return "this chat is open somewhere else";
        if (code != null && KnownErrors.TryGetValue(code, out var words)) return words;
        var plain = Preview(error, 150);
        return ErrorSentence(First(plain, @"^(.{12,}?[.!?])\s") ?? plain);
    }

    // ------------------------------------------------------------------ Markdown as plain text

    /// notification-preview.ts plainText: code blocks are "[code]", images "[image]", links their words; a heading ends
    /// with ":" and a list item or table row with "." when more follows.
    public static string PlainText(string markdown)
    {
        var lines = new List<(string Text, string End)>();
        var fence = "";
        var source = Prefix(markdown, 4000).Replace("\r\n", "\n").Replace("\r", "\n");
        foreach (var raw in source.Split('\n'))
        {
            var open = First(raw, @"^\s*(`{3,}|~{3,})");
            if (fence.Length > 0)
            {
                if (open != null && open[0] == fence[0] && open.Length >= fence.Length && raw.Trim()[open.Length..].Trim().Length == 0) fence = "";
                continue;
            }
            if (open != null) { fence = open; lines.Add(("[code]", "")); continue; }
            var line = raw.Trim();
            var end = "";
            if (line.Length == 0 || Matches(line, @"^([-*_]\s*){3,}$") || Matches(line, @"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?$")) continue;
            line = Replace(line, @"^(>\s?)+", _ => "");
            if (Matches(line, @"^#{1,6}\s+")) { line = Replace(line, @"^#{1,6}\s+", _ => ""); end = ":"; }
            else if (Matches(line, @"^([-*+]|\d{1,3}[.)])\s+")) { line = Replace(Replace(line, @"^([-*+]|\d{1,3}[.)])\s+", _ => ""), @"^\[[ xX]\]\s+", _ => ""); end = "."; }
            else if (line.StartsWith('|')) { line = Replace(Replace(line, @"^\||\|$", _ => "").Trim(), @"\s*\|\s*", _ => " · "); end = "."; }
            lines.Add((line, end));
        }
        var text = string.Join("\n", lines.Select((l, i) =>
            i < lines.Count - 1 && l.End.Length > 0 && !Matches(l.Text, "[.!?:;,…]$") ? l.Text + l.End : l.Text));
        text = Replace(text, @"!\[[^\]]*\]\([^)]*\)", _ => "[image]");
        text = Replace(text, @"<img\b[^>]*>", _ => "[image]", RegexOptions.IgnoreCase);
        text = Replace(text, @"\[([^\]]+)\]\([^)]*\)", g => g[1]);
        text = Replace(text, @"<(https?://[^>\s]+)>", g => g[1]);
        // Emphasis and tags outside inline code: `__init__` in backticks stays as written.
        var out_ = new StringBuilder();
        var rest = text;
        while (Rx(@"`[^`\n]+`").Match(rest) is { Success: true } span)
        {
            out_.Append(Inline(rest[..span.Index])).Append(span.Value[1..^1]);
            rest = rest[(span.Index + span.Length)..];
        }
        return out_.Append(Inline(rest)).ToString();
    }

    private static string Inline(string text)
    {
        text = Replace(text, @"</?(?:br|p|div|li|ul|ol|tr|table|h[1-6]|blockquote|details|summary|pre)\b[^>]*>", _ => " ", RegexOptions.IgnoreCase);
        text = Replace(text, @"</?(?:a|b|i|u|s|em|strong|span|sup|sub|small|code|kbd|mark|del|ins|thead|tbody|td|th)\b[^>]*>", _ => "", RegexOptions.IgnoreCase);
        text = Replace(text, @"(\*\*|__)(?=\S)([^\n]+?)(?<=\S)\1", g => g[2]);
        text = Replace(text, @"(?<![A-Za-z0-9_*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![A-Za-z0-9_*])", g => g[1]);
        text = Replace(text, @"(?<![A-Za-z0-9_])_(?=\S)([^_\n]+?)(?<=\S)_(?![A-Za-z0-9_])", g => g[1]);
        return Replace(text, @"~~(?=\S)([^~\n]+?)(?<=\S)~~", g => g[1]);
    }

    // ------------------------------------------------------------------ masking (fe-platform-policy.ts redactPrivate)

    /// A random-looking run (letters and digits together, 16+ in a row): a vendor prefix alone isn't a key.
    private static bool Random(string text) => Matches(text, @"\d") && Matches(text, "[A-Za-z]") && Matches(text, "[A-Za-z0-9]{16,}");

    // A value: quoted (any length, across lines; a quote never closed runs to the end) or one run up to whitespace.
    private const string Value = """(?:"([^"]+)("?)|'([^']+)('?)|([^\s"'`<>]+))""";
    private const string Key = """(?<![A-Za-z0-9_.-])([A-Za-z0-9_.-]{0,40}?(?:pass|pw|secret|token|key|auth|credential|sig)[A-Za-z0-9_.-]{0,40})""";
    private const string Argument = """("[^"]*"?|'[^']*'?|[^\s"']+)""";
    private static readonly HashSet<string> StrongKeys = ["password", "passwd", "passphrase", "passcode", "secret", "secrets", "credential", "credentials", "apikey", "accesskey",
        "privatekey", "secretkey", "authtoken", "accesstoken", "refreshtoken", "idtoken", "sessiontoken", "clientsecret", "bearertoken"];
    private static readonly HashSet<string> PasswordKeys = ["password", "passwd", "passphrase", "passcode"];
    private static readonly HashSet<string> WeakKeys = ["token", "tokens", "key", "keys", "auth", "authorization", "bearer", "signature", "sig"];
    private static readonly HashSet<string> ProseWords = ["the", "a", "an", "i", "we", "you", "your", "my", "our", "their", "his", "her", "its", "it", "this", "that", "these", "those",
        "same", "not", "no", "none", "null", "nil", "true", "false", "yes", "required", "optional", "hidden", "redacted", "empty",
        "blank", "unset", "unchanged", "provided", "needed", "missing", "see", "use", "is", "was", "are", "be", "will", "should",
        "must", "can", "set", "reset", "changed", "stored", "saved", "sent", "and", "or", "in", "on", "at", "for", "from", "with",
        "of", "to", "if", "when", "only", "also", "still", "just", "now", "here", "there", "below", "above", "as", "by", "via"];

    /// What a key names: "password" (any literal value is masked, paths too), "strong" (masked unless a path), "weak"
    /// (masked only when the value looks opaque), or "".
    public static string SecretKeyKind(string key)
    {
        var caps = !Matches(key, "[a-z]");
        var split = Replace(Replace(key, "([a-z0-9])([A-Z])", g => $"{g[1]}_{g[2]}"), "([A-Z]+)([A-Z][a-z])", g => $"{g[1]}_{g[2]}").ToLowerInvariant();
        var parts = Replace(split, "[^a-z0-9]+", _ => " ").Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        var pairs = parts.Zip(parts.Skip(1), (a, b) => a + b).ToList();
        var last = parts.Count > 0 ? parts[^1] : "";
        if (parts.Any(PasswordKeys.Contains) || last == "pass" || last == "pw" || (last == "pwd" && parts.Count > 1)
            || (caps && parts.Any(p => p.EndsWith("password", StringComparison.Ordinal) || p.EndsWith("passwd", StringComparison.Ordinal)))) return "password";
        if (parts.Concat(pairs).Any(StrongKeys.Contains) || (caps && parts.Any(p => p.EndsWith("secret", StringComparison.Ordinal)))) return "strong";
        return parts.Any(WeakKeys.Contains) || (caps && parts.Any(p => p.EndsWith("token", StringComparison.Ordinal))) ? "weak" : "";
    }

    private static bool Opaque(string value) =>
        Random(value) || (Count(value) >= 16 && Matches(value, "^[A-Fa-f0-9]+$")) || (Count(value) >= 20 && Matches(value, "^[A-Za-z0-9_./+=-]+$"))
        || (Count(value) >= 12 && new[] { "[a-z]", "[A-Z]", "[0-9]" }.Count(p => Matches(value, p)) >= 2);

    /// A variable or lookup names where the secret is ($DB_PASS, ${TOKEN}, process.env.X), not the secret itself.
    private static bool Reference(string value) =>
        Matches(value, """^(?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$|\$\(|\$\{\{|process\.env\.|os\.(?:getenv|environ))""");

    private static bool FilePath(string value) =>
        Matches(value, """^(?:~|\.{1,2})?/[A-Za-z0-9._/-]*$""") && !value.Split('/').Where(p => p.Length > 0).Any(Random);

    private static string MaskValue(string kind, string value, bool quoted)
    {
        var core = value;
        if (!quoted) while (core.Length > 0 && ".,;:)]}".Contains(core[^1])) core = core[..^1];
        if (kind.Length == 0 || !Matches(core, "[A-Za-z0-9]") || Reference(core)) return value;
        var keep = kind == "weak" ? !Opaque(core) || FilePath(core)
            : (!quoted && ProseWords.Contains(core.ToLowerInvariant())) || (kind == "strong" && FilePath(core));
        return keep ? value : Redacted + value[core.Length..];
    }

    /// A `value` match (groups 3–7: double-quoted and its close, single-quoted and its close, bare) rebuilt: masked, or
    /// kept and scanned again (a kept run can hold the next key=value).
    private static string Valued(string kind, string[] g)
    {
        string Quoted(string quote, string content, string end)
        {
            var shown = MaskValue(kind, content, quoted: true);
            return quote + (shown == content ? Assignments(content) : shown) + end;
        }
        if (g[3].Length > 0) return Quoted("\"", g[3], g[4]);
        if (g[5].Length > 0) return Quoted("'", g[5], g[6]);
        var value = g[7];
        var head = new string(value.TakeWhile(c => !",;&".Contains(c)).ToArray());
        if (kind is "password" or "strong")
        {
            // A reference, path, word or mask before the punctuation is kept (the rest is its own text); a credential runs on.
            if (head.Length > 0 && MaskValue(kind, head, quoted: false) == head) return head + Assignments(value[head.Length..]);
            return MaskValue(kind, value, quoted: false);
        }
        return MaskValue(kind, head, quoted: false) + Assignments(value[head.Length..]);
    }

    private static string Assignments(string text) =>
        Replace(text, Key + """(["']?\s*[:=]\s*)""" + Value, g => g[1] + g[2] + Valued(SecretKeyKind(g[1]), g), RegexOptions.IgnoreCase);

    /// Where a password written as words ends (in characters): two or more words, none reading as prose, up to one
    /// that ends a clause. 0 when it is one word or none.
    public static int Phrase(string value)
    {
        int end = 0, words = 0;
        foreach (Match m in Rx(@"\S+").Matches(value))
        {
            var word = m.Value;
            var core = word;
            while (core.Length > 0 && ".,;:!?)]}".Contains(core[^1])) core = core[..^1];
            if (!Matches(core, "[A-Za-z0-9]") || ProseWords.Contains(core.ToLowerInvariant()) || "([{".Contains(word[0])) break;
            words++;
            end = m.Index + core.Length;
            if (core != word) break;
        }
        return words >= 2 ? end : 0;
    }

    /// A quoted or bare argument masked in place, or null when it names no secret.
    private static string? MaskedArgument(string value)
    {
        var quote = value.Length > 0 && value[0] is '"' or '\'' ? value[..1] : "";
        var closed = quote.Length > 0 && value.Length > 1 && value.EndsWith(quote, StringComparison.Ordinal);
        var content = quote.Length == 0 ? value : value[1..^(closed ? 1 : 0)];
        if (!Matches(content, "[A-Za-z0-9]") || content.StartsWith('-') || Reference(content)) return null;
        return quote.Length == 0 ? Redacted : quote + Redacted + (closed ? quote : "");
    }

    private static string Masking(string[] g, string head, string value) => MaskedArgument(value) is { } shown ? head + shown : g[0];

    /// Keys, tokens and passwords masked in place (redactPrivate, rule for rule and in the same order).
    public static string Redact(string text)
    {
        string Mask(string[] g) => Random(g[0]) ? Redacted : g[0];
        var out_ = Replace(text, """-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----[\s\S]*?(?:-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----|\z)""", _ => Redacted);
        out_ = Replace(out_, @"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*", _ => Redacted);
        out_ = Replace(out_, @"(?<![0-9])[0-9]{8,10}:[A-Za-z0-9_-]{30,}", _ => Redacted);
        out_ = Replace(out_, @"(?<![A-Za-z0-9])SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}", _ => Redacted);
        out_ = Replace(out_, @"(?<![A-Za-z0-9_-])[MNO][A-Za-z0-9_-]{23,27}\.[A-Za-z0-9_-]{6,7}\.[A-Za-z0-9_-]{27,40}", Mask);
        foreach (var token in new[]
        {
            "(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}", "(?<![A-Za-z0-9])[rs]k_(?:live|test)_[A-Za-z0-9]{20,}", "(?<![A-Za-z0-9])(?:xai-|gsk_|pplx-|r8_|hf_)[A-Za-z0-9]{20,}",
            "(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|glpat-[A-Za-z0-9_-]{20,})", "(?<![A-Za-z0-9])xox[abprs]-[A-Za-z0-9-]{10,}",
            "(?<![A-Za-z0-9])AIza[0-9A-Za-z_-]{35}", "(?<![A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Za-z0-9])", "(?<![A-Za-z0-9])npm_[A-Za-z0-9]{30,}",
        }) out_ = Replace(out_, token, Mask);
        out_ = Replace(out_, """(authorization["']?\s*[:=]\s*["']?(?:basic|bearer|token|digest|negotiate|ntlm|apikey|key)\s+)([^\s"'`,;]+)""",
            g => Matches(g[2], "[A-Za-z0-9]") ? g[1] + Redacted : g[0], RegexOptions.IgnoreCase);
        out_ = Replace(out_, """(?<![A-Za-z0-9_])(bearer\s+)([A-Za-z0-9._~+/-]{20,}=*)""", g => g[1] + Redacted, RegexOptions.IgnoreCase);
        // `-u user:pass`, quoted too (the whole quoted password, to the end when never closed).
        out_ = Replace(out_, """(?<!\S)(-u|--user)(\s+|=)(?:"([^\s:"]+):([^"]*)("?)|'([^\s:']+):([^']*)('?)|([^\s:"']+):([^\s"']+))""", g =>
            g[1] + g[2] + (g[3].Length > 0 ? $"\"{g[3]}:{Redacted}{g[5]}" : g[6].Length > 0 ? $"'{g[6]}:{Redacted}{g[8]}" : $"{g[9]}:{Redacted}"));
        out_ = Replace(out_, """(?<!\S)(--(?:password|passwd|pass|passphrase|token|api-key|apikey|secret|client-secret|auth-token|access-token))(=|\s+)""" + Argument,
            g => Masking(g, g[1] + g[2], g[3]));
        // The short flag whose value is the password: mysql -pS3cret (and its kin), mongo/sshpass/registry logins' -p, redis-cli -a.
        out_ = Replace(out_, """(?<![A-Za-z0-9_.-])((?:mysql[A-Za-z0-9_-]*|mariadb[A-Za-z0-9_-]*|mongo(?:sh|dump|restore|import|export)?|sshpass|(?:docker|podman|nerdctl|buildah|skopeo|oras)\s+login|helm\s+registry\s+login)\b[^\n|;&]{0,200}?\s-p|redis-cli\b[^\n|;&]{0,200}?\s-a)([ \t]*)""" + Argument,
            g => Masking(g, g[1] + g[2], g[3]));
        // htpasswd -b (batch mode): the password is the command's last argument.
        out_ = Replace(out_, """(?<![A-Za-z0-9_.-])(htpasswd\b[^\n|;&]{0,200}?\s-[A-Za-z]*b[A-Za-z]*\b[^\n|;&]{0,300}\s)("[^"]*"?|'[^']*'?|[^\s"'|;&]+)(?=[ \t]*(?:[|;&\n]|\z))""",
            g => Masking(g, g[1], g[2]));
        out_ = Replace(out_, """(?<![A-Za-z0-9+.-])([a-z][a-z0-9+.-]*://[^\s/:@?#]*):([^\s/?#]*)@""", g => g[2].Length == 0 ? g[0] : $"{g[1]}:{Redacted}@", RegexOptions.IgnoreCase);
        out_ = Replace(out_, """(?<![A-Za-z0-9+.-])([a-z][a-z0-9+.-]*://)([^\s/:@?#]{8,})@""", g => Opaque(g[2]) ? $"{g[1]}{Redacted}@" : g[0], RegexOptions.IgnoreCase);
        out_ = Replace(out_, """([?&#](?:access_token|refresh_token|id_token|auth_token|session_token|token|api_key|apikey|key|secret|client_secret|password|passwd|pass|pwd|auth|jwt|code|sig|signature|x-amz-signature|x-amz-credential|x-amz-security-token)=)[^&\s#]+""",
            g => g[1] + Redacted, RegexOptions.IgnoreCase);
        // Prose is only masked where the value can't be a word: quoted, opaque, or a password with a digit or symbol.
        out_ = Replace(out_, """(?<![A-Za-z0-9_])(api[ _-]?key|access[ _-]?key|secret[ _-]?key|access[ _-]?token|auth[ _-]?token|password|passwd|passcode|passphrase|token|secret)(\s+(?:is|was)\s*:?\s+)""" + Value, g =>
        {
            var quoted = g[7].Length == 0;
            var core = quoted ? g[3] + g[5] : g[7];
            if (!quoted) while (core.Length > 0 && ".,;:)]}".Contains(core[^1])) core = core[..^1];
            var hide = quoted || Opaque(core) || (Matches(g[1], "pass", RegexOptions.IgnoreCase) && Matches(core, "[^A-Za-z]") && Count(core) >= 4);
            return hide ? g[1] + g[2] + Valued("password", g) : g[0];
        }, RegexOptions.IgnoreCase);
        // "password = correct horse battery staple": after `:` or a spaced `=`, a password written as words.
        out_ = Replace(out_, Key + """(["']?(?:[ \t]*:[ \t]*|[ \t]+=[ \t]*|=[ \t]+))([^\s"'`<>][^\n<`]*)""", g =>
        {
            var end = SecretKeyKind(g[1]) == "password" ? Phrase(g[3]) : 0;
            return end > 0 ? g[1] + g[2] + Redacted + g[3][end..] : g[0];
        }, RegexOptions.IgnoreCase);
        return Assignments(out_);
    }

    // ------------------------------------------------------------------ helpers

    private static readonly ConcurrentDictionary<(string, RegexOptions), Regex> Compiled = new();

    private static Regex Rx(string pattern, RegexOptions options = RegexOptions.None) =>
        Compiled.GetOrAdd((pattern, options), k => new Regex(k.Item1, k.Item2 | RegexOptions.CultureInvariant));

    private static bool Matches(string text, string pattern, RegexOptions options = RegexOptions.None) => Rx(pattern, options).IsMatch(text);

    /// The first capture group of the first match.
    private static string? First(string text, string pattern, RegexOptions options = RegexOptions.None) =>
        Rx(pattern, options).Match(text) is { Success: true } m && m.Groups.Count > 1 && m.Groups[1].Success ? m.Groups[1].Value : null;

    /// Every match replaced by `transform(groups)` (group 0 is the whole match; an unmatched group is "").
    private static string Replace(string text, string pattern, Func<string[], string> transform, RegexOptions options = RegexOptions.None) =>
        Rx(pattern, options).Replace(text, m => transform([.. m.Groups.Cast<Group>().Select(g => g.Success ? g.Value : "")]));

    /// Characters as a person counts them (Swift's String.count).
    internal static int Count(string text) => new StringInfo(text).LengthInTextElements;

    internal static string Prefix(string text, int n)
    {
        if (text.Length <= n) return text;
        var info = new StringInfo(text);
        return n >= info.LengthInTextElements ? text : info.SubstringByTextElements(0, n);
    }
}
