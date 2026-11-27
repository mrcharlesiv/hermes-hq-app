using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Hermes.Core.Bots;

/// Row-building rules for the Bots list (spec 02 §6). Port of HermesKit/Model/RosterRules.swift.
public static class RosterRules
{
    public const string BotChatTitle = "Bot Chat";
    public const string PinnedSectionId = "hermes-hq-pinned";
    public const string PinnedSectionName = "Pinned";
    /// The first six pinned rows become tiles (spec 02 §7.3).
    public const int MaxTiles = 6;

    /// @handle: `default` is `hermes`; other profiles their lowercased name.
    public static string Handle(string name)
    {
        var key = name.Trim().ToLowerInvariant();
        return key.Length == 0 || key == "default" ? "hermes" : key;
    }

    private static readonly Regex SeparatorRun = new("[-_]+");

    /// `research-buddy` → `Research Buddy`: `-`/`_` runs → one space, then every word character after a non-word
    /// character upper-cased.
    public static string TitleCase(string raw)
    {
        var spaced = SeparatorRun.Replace(raw, " ").Trim();
        var sb = new StringBuilder();
        var previousIsWord = false;
        foreach (var ch in spaced)
        {
            var isWord = char.IsLetterOrDigit(ch) || ch == '_';
            sb.Append(isWord && !previousIsWord ? char.ToUpperInvariant(ch) : ch);
            previousIsWord = isWord;
        }
        return sb.ToString();
    }

    /// The display name (§6.1): meta title, display_name, "Hermes" for `default`, else Title Case of the name.
    public static string DisplayName(RosterProfile profile, BotMeta meta)
    {
        if (meta.Title is { } title) return title;
        if (profile.DisplayName is { } shown) return shown;
        if (profile.Name == "default" && profile.Title == null) return "Hermes";
        return TitleCase(profile.Title ?? profile.Name);
    }

    /// The role line (§6.2): meta description, row description, or the row title when it differs from the name.
    public static string? RoleLine(RosterProfile profile, BotMeta meta, string name) =>
        meta.Description ?? profile.Description ?? (profile.Title is { } t && t != name ? t : null);

    /// A Bot Chat with something in it: `message_count > 0` when it is a number, else a non-blank preview.
    public static bool HoldsMessages(RosterSessionRef? session) =>
        session != null && (session.MessageCount is { } c ? c > 0 : RosterText.NonBlank(session.Preview) != null);

    public sealed record PreviewSource(RosterSessionRef? Session, double Time, string Preview);

    /// `rosterPreview`, phone rule: the Bot Chat when it holds messages, else nothing (a side chat speaks on its Sessions row).
    public static PreviewSource RosterPreviewOf(RosterProfile profile)
    {
        if (profile.CanonicalSession is { } c && HoldsMessages(c))
            return new PreviewSource(c, c.LastActive ?? 0, RosterPreview.RowPreview(c.Preview));
        return new PreviewSource(null, 0, "");
    }

    public static double RosterTime(RosterProfile profile) =>
        profile.CanonicalSession is { } c && HoldsMessages(c) ? c.LastActive ?? 0 : 0;

    /// Sort key (§7.2), milliseconds: the row's time, else the bot's creation time.
    public static double SortTime(RosterProfile profile, BotMeta meta)
    {
        var t = RosterTime(profile) * 1000;
        return t != 0 ? t : meta.Created ?? 0;
    }

    // ---------------------------------------------------------------- errors (S/list-helpers.ts:73-82)

    private static readonly Regex Busy = new(@"timed?\s*out|timeout|overloaded|too many requests|\b429\b|\b503\b|pool (?:is )?(?:full|exhausted)|busy", RegexOptions.IgnoreCase);
    private static readonly Regex NotConnected = new("gateway unavailable|not connected|connection closed|connection reset|ECONNRESET", RegexOptions.IgnoreCase);

    public static bool IsGatewayBusy(Exception e) => e is Net.GatewayException { Status: 429 or 503 } || e is Net.GatewayException { Code: "timeout" }
        || e is Net.GatewayException { NotSentBecause: "timeout" }   // [WIN-SEND-NOTSENT-REFUSE] the socket wait ran out
        || Busy.IsMatch(e.Message);

    public static bool IsGatewayNotConnected(Exception e) => NotConnected.IsMatch(e.Message);
}

/// What a Bots row's second line says: the cleaned last-message preview (spec 02 §6.3–6.4). Port of
/// HermesKit/Model/RosterPreview.swift.
public static class RosterPreview
{
    private const RegexOptions I = RegexOptions.IgnoreCase;
    private static readonly Regex ModelSwitch = new(@"^\s*\[System: The active model for this chat has changed to\b\s*(\S*)", I);
    private static readonly Regex ModelSwitchCut = new(@"^\s*\[System: The active model for this chat\b", I);
    private static readonly Regex MachineNote = new(@"^\s*\[(?:System note|Runtime note):\s*|^\s*\[SYSTEM\]\s*", I);
    private static readonly Regex KanbanDispatch = new(@"^\s*work kanban task t_[0-9a-z]+\s*$", I);
    private static readonly Regex MachineTag = new(@"^\s*<[a-z][\w-]*>", I);
    private static readonly Regex MachineTagPair = new(@"<([a-z][\w-]*)>[\s\S]*?(?:</\1>|\z)", I);
    private static readonly Regex ViaFollows = new(@"^\s+via\b", I);
    private static readonly Regex ClosingBracket = new(@"\]\s*$");
    private static readonly Regex LeadingAt = new("^@");

    /// What a row shows for a preview that is a machine note: "Model changed to <label>", a note's own words, "Kanban
    /// task", no leading machine tags. Any other preview comes back as it is.
    public static string RowPreview(string? text, Func<string, string>? model = null)
    {
        var value = text ?? "";
        if (ModelSwitch.Match(value) is { Success: true } m)
        {
            var rest = value[(m.Index + m.Length)..];
            var raw = m.Groups[1].Value;
            var id = raw;
            while (id.EndsWith(']') && id.Count(c => c == ']') > id.Count(c => c == '[')) id = id[..^1];
            while (id.EndsWith('.')) id = id[..^1];
            var via = ViaFollows.IsMatch(rest);
            var cutShort = raw.EndsWith("...") || raw.EndsWith('…');
            var whole = id.Length > 0 && (via || (!cutShort && (raw.EndsWith('.') || raw.EndsWith(']'))));
            return whole ? $"Model changed to {(model ?? (s => s))(id)}" : "Model changed";
        }
        if (ModelSwitchCut.IsMatch(value)) return "Model changed";
        if (MachineNote.IsMatch(value))
            return ClosingBracket.Replace(MachineNote.Replace(value, "", 1), "", 1).Trim();
        if (KanbanDispatch.IsMatch(value)) return "Kanban task";
        if (MachineTag.IsMatch(value)) return MachineTagPair.Replace(value, "").Trim();
        return value;
    }

    private static readonly (Regex, string)[] MarkdownSteps =
    [
        (new(@"```[\s\S]*?(?:```|\z)"), " "),
        (new(@"`([^`\n]*)`"), "$1"),
        (new(@"!\[([^\]]*)\]\([^)]*\)"), "$1"),
        (new(@"\[([^\]]*)\]\([^)]*\)"), "$1"),
        (new(@"!?\[([^\]]*)\]\([^)]*\z"), "$1"),
        (new(@"(\*\*|__)(.*?)\1"), "$2"),
        (new(@"(^|\s)[*_](\S(?:.*?\S)?)[*_](?=\s|\z|[.,;:!?])"), "$1$2"),
        (new(@"~~(.*?)~~"), "$1"),
        (new(@"\*\*|__|~~|`+"), ""),
        (new(@"^\s{0,3}#{1,6}\s+", RegexOptions.Multiline), ""),
        (new(@"^\s{0,3}>\s?", RegexOptions.Multiline), ""),
        (new(@"^\s{0,3}[-*+]\s+", RegexOptions.Multiline), ""),
        (new(@"^\s{0,3}\|?(?:\s*:?-{3,}:?\s*\|)+\s*$", RegexOptions.Multiline), " "),
        (new(@"\s*\|\s*"), " · "),
        (new(@"\s+"), " "),
        (new(@"(?:\s*·\s*){2,}"), " · "),
        (new(@"^(?:\s*·\s*)+|(?:\s*·\s*)+\z"), ""),
    ];

    public static string StripMarkdown(string text)
    {
        var o = text;
        foreach (var (regex, template) in MarkdownSteps) o = regex.Replace(o, template);
        return o.Trim();
    }

    private static readonly Regex Note = new(@"\[\s*(?:system(?: note)?|runtime note|note to self|context|internal)\s*:[^\]]*(?:\]|\z)", I);
    private static readonly Regex Sentinel = new(@"\[\s*(?:SILENT|CRON_FAILURE|NO_REPLY|SYSTEM)\s*\]", I);
    private static readonly Regex Scheduler = new(@"\n?#{1,3}\s*Run Context[\s\S]*\z", I);
    private static readonly Regex SilentOnly = new(@"^\s*\[\s*SILENT\s*\]\s*\z", I);
    private static readonly HashSet<string> SilenceMarkers = ["[SILENT]", "SILENT", "NO_REPLY", "NO REPLY", "[静默]", "静默", "[沉默]", "沉默"];

    /// The gateway's own silence markers (Hydration.isSilenceMarker).
    public static bool IsSilenceMarker(string text)
    {
        var t = text.Trim();
        if (t.Length == 0 || t.Length > 64) return false;
        static bool Edge(char c) => c != '[' && c != ']' && char.IsPunctuation(c);
        var core = t.AsSpan();
        while (core.Length > 0 && Edge(core[0])) core = core[1..];
        while (core.Length > 0 && Edge(core[^1])) core = core[..^1];
        static string Canon(ReadOnlySpan<char> s) =>
            string.Join(' ', s.ToString().ToUpperInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return SilenceMarkers.Contains(Canon(t)) || SilenceMarkers.Contains(Canon(core));
    }

    /// The machine-free text of a preview ("" when nothing human is left).
    public static string CleanPreviewText(string? raw, Func<string, string>? model = null)
    {
        var value = raw ?? "";
        if (IsSilenceMarker(value)) return "";
        if (ModelSwitchCut.IsMatch(value)) return RowPreview(value, model).Trim();
        return StripMarkdown(Sentinel.Replace(Note.Replace(Scheduler.Replace(value, "", 1), " "), " "));
    }

    public static bool IsSilentOnly(string? raw) => SilentOnly.IsMatch(raw ?? "") || IsSilenceMarker(raw ?? "");

    private static readonly Regex A2A = new(@"^Message from (?:agent '([^']+)'|🤖\s*([^\s(@]+))", I);
    private static readonly Regex Delivery = new(@"^\s*(?:\[\s*)?Message from (?:agent '[^']+'|🤖[^:\]]+)\]?:?\s*", I);

    public static bool IsDelivery(string text) => Delivery.IsMatch(text);

    /// The sender handle of a bot-to-bot delivery preview; `default` → `hermes`.
    public static string? DeliveryHandle(string? preview)
    {
        var text = (preview ?? "").Trim();
        if (text.Length == 0 || A2A.Match(text) is not { Success: true } m) return null;
        var sender = (m.Groups[1].Success && m.Groups[1].Value.Length > 0 ? m.Groups[1].Value : m.Groups[2].Value).Trim().ToLowerInvariant();
        return sender.Length == 0 ? null : RosterRules.Handle(sender);
    }

    /// The gateway's own words behind a shown preview (`sourcePreview`).
    public static string SourcePreview(RosterProfile profile, string shown)
    {
        var want = shown.Trim();
        if (want.Length == 0)
        {
            if (profile.CanonicalSession is { } c && RosterRules.HoldsMessages(c))
                return IsSilentOnly(c.Preview) ? c.Preview ?? shown : shown;
            return shown;
        }
        var raw = profile.CanonicalSession?.Preview ?? "";
        if (raw.Length > 0 && raw != shown && RowPreview(raw).Trim() == want) return raw;
        return shown;
    }

    /// The cleaned preview split for drawing: prefix ("From Inbox:", "Draft:") then the text.
    public sealed record Parts(string? Prefix, string Text, bool IsFallback)
    {
        public string Line => Prefix is { } p ? $"{p} {Text}" : Text;
    }

    public const string NotDeliveredPrefix = "Not Delivered:";

    /// `botPreview` (`S/ui-bots/bot-preview.ts:79-90`). Rows never say "You:".
    public static Parts BotPreview(string? text, string? fromBot, bool draft, string? role, Func<string, string>? model = null)
    {
        var raw = text ?? "";
        var delivered = Delivery.IsMatch(raw);
        var body = CleanPreviewText(Delivery.Replace(raw, "", 1), model);
        var sender = fromBot is null ? null : LeadingAt.Replace(fromBot.Trim(), "", 1);
        if (draft) return new Parts("Draft:", body, false);
        if (body.Length > 0)
        {
            if ((delivered || !string.IsNullOrEmpty(fromBot)) && !string.IsNullOrEmpty(sender)) return new Parts($"From {sender}:", body, false);
            return new Parts(null, body, false);
        }
        if (IsSilentOnly(Delivery.Replace(raw, "", 1))) return new Parts(null, RosterText.NonBlank(role) ?? "", true);
        return new Parts(null, RosterText.NonBlank(role) ?? "No messages yet", true);
    }
}

/// The list's right-hand time (S/list-time.ts:29-40, App/Root/ListTime.swift): same day → "9:05 AM"; yesterday →
/// "Yesterday"; within 6 days → "Mon"; else "Aug 7", with year "Aug 7, 2025" if another year. Empty for none.
public static class ListTime
{
    private static readonly CultureInfo EnUs = CultureInfo.GetCultureInfo("en-US");

    public static string Format(double seconds, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        if (seconds <= 0 || !double.IsFinite(seconds)) return "";
        var tz = zone ?? TimeZoneInfo.Local;
        var at = TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000)), tz);
        var today = TimeZoneInfo.ConvertTime(now ?? DateTimeOffset.UtcNow, tz);
        var days = (today.Date - at.Date).Days;
        if (days == 0) return at.ToString("h:mm tt", EnUs);
        if (days == 1) return "Yesterday";
        if (days > 1 && days < 7) return at.ToString("ddd", EnUs);
        return at.Year == today.Year ? at.ToString("MMM d", EnUs) : at.ToString("MMM d, yyyy", EnUs);
    }

    public static string Format(DateTimeOffset? when, DateTimeOffset? now = null, TimeZoneInfo? zone = null) =>
        when is { } w ? Format(w.ToUnixTimeMilliseconds() / 1000.0, now, zone) : "";

    /// Clock time alone ("1:02 AM") for rows already sitting under the "Yesterday" group heading (SessionsViewController.swift:536–544).
    public static string FormatClock(DateTimeOffset? when, TimeZoneInfo? zone = null)
    {
        if (when is not { } w) return "";
        var tz = zone ?? TimeZoneInfo.Local;
        return TimeZoneInfo.ConvertTime(w, tz).ToString("h:mm tt", EnUs);
    }
}
