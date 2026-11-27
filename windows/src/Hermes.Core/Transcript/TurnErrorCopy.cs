using System.Globalization;
using System.Text.RegularExpressions;
using Hermes.Core.Model;

namespace Hermes.Core.Transcripts;

// Port of HermesKit/Chat/Transcript/TurnErrorCopy.swift: a failed turn in words (docs/spec/3x-transcript.md §6.1 and
// §6.2), the session problem card, and the "Couldn’t Send" card (§6.3).

public enum TurnErrorKind
{
    UsageLimit, AnotherWindow, ModelStart, GatewayBusy, CutOff,
    // Plain-words provider failures: these reuse the card's Choose a Model button (no separate Switch Provider).
    Billing, BadApiKey, ProviderDown, ModelGone,
}

public enum TurnErrorPrimary { Retry, ChooseModel, NewChat }

/// A known failure's words. `ResetsAt`: when the provider's limit lifts (unix seconds), when the text names it.
public sealed record TurnErrorCopy(TurnErrorKind Kind, string Title, string Body, TurnErrorPrimary Primary, double? ResetsAt = null);

public static class TurnErrors
{
    private const RegexOptions I = RegexOptions.IgnoreCase;

    internal static readonly TranscriptRx Limit = new(@"\b429\b|usage[_ ]limit|rate[_ ]?limit|quota (?:is )?(?:exhausted|exceeded)|too many requests", I);
    internal static readonly TranscriptRx Owned = new(@"open in another Hermes window|another live owner|SESSION_NOT_OWNED|session has another", I);
    /// A busy refusal whose hand-off to the gateway's queue was refused too (`_submit_to_ledger_owner`).
    internal static readonly TranscriptRx HandOffRefused = new(@"running a turn in this chat and the gateway refused it", I);
    /// `4090 SESSION_OWNER_BUSY`'s words.
    internal static readonly TranscriptRx OwnerBusy = new(@"send it again when the current turn ends|SESSION_OWNER_BUSY", I);
    internal static readonly TranscriptRx Start = new(@"could not start the assistant|couldn['’]t start (?:the )?(?:assistant|agent|model)|agent[_ ]init|failed to (?:initiali[sz]e|start) (?:the )?agent|could not find the '[^']+' CLI command", I);
    internal static readonly TranscriptRx Busy = new(@"readiness probe|exceeded its budget|\b5097\b", I);
    /// What the app itself writes when the link drops under a reply, and what a gateway says.
    internal static readonly TranscriptRx Cut = new(@"connection (?:was )?(?:lost|dropped|closed)|reply was cut off|stream (?:ended|closed) (?:early|before)|socket closed|disconnected (?:before|while)", I);

    /// A provider's HTTP status the way error texts carry one ("Error code: 529 - …", "status 402", "HTTP 404", "(401)"),
    /// not a bare number.
    private static string Status(string code) => @"(?:error code|status(?: code)?|http)\s*:?\s*" + code + @"\b|\(" + code + @"\)";

    internal static readonly TranscriptRx Billing = new(@"credit balance|\bbilling\b|insufficient[_ ]credits?|" + Status("402"), I);
    internal static readonly TranscriptRx BadApiKey = new(@"invalid[_ ]?(?:x-)?api[_ ]?key|rejected the api key|authentication[_ ](?:error|failed)|" + Status("40[13]"), I);
    internal static readonly TranscriptRx ProviderDown = new(@"overloaded|service unavailable|bad gateway|internal server error|gateway time-?out|" + Status(@"5\d\d"), I);
    /// The part of ProviderDown that really is a busy provider ("Overloaded", 529, 503).
    internal static readonly TranscriptRx Overloaded = new(@"overloaded|service unavailable|" + Status("5(?:29|03)"), I);
    internal static readonly TranscriptRx ModelGone = new(@"model_not_found|\bmodel\b[^\n]{0,60}?\b(?:does not exist|not found)|" + Status("404"), I);
    private static readonly TranscriptRx ResetsAtRe = new("""resets?_at["'\s:=]+(\d{10})\b""", I);
    private static readonly TranscriptRx[] Waits =
    [
        new(@"retry after\s+(\d+(?:\.\d+)?)\s*s", I),
        new("""resets?_in_seconds["'\s:=]+(\d+)""", I),
        new("""retry-after["'\s:=]+(\d+)""", I),
        new(@"resets? in\s+(\d+)\s*s(?:ec(?:ond)?s?)?\b", I),
    ];
    private static readonly TranscriptRx Provider = new(@"\b([A-Z][\w-]*|openai-codex|codex|anthropic|openai)\b provider (?:quota|rate)", I);

    public const string CutOffTitle = "The reply was cut off";

    private static double? ParseNumber(string? s) =>
        s is not null && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : null;

    /// When the provider's limit lifts (unix seconds), from the wait the error text names.
    public static double? ResetsAt(string text, DateTimeOffset now)
    {
        if (ResetsAtRe.Groups(text) is { } g && ParseNumber(g[1]) is { } at) return at;
        foreach (var pattern in Waits)
            if (pattern.Groups(text) is { } w && ParseNumber(w[1]) is { } wait)
                return Math.Round(now.ToUnixTimeMilliseconds() / 1000.0 + wait, MidpointRounding.AwayFromZero);
        return null;
    }

    /// "3:10 PM" today, "Sat, Oct 3, 12:57 PM" on another day.
    public static string ResetTimeLabel(double resetsAt, DateTimeOffset now, CultureInfo? culture = null, TimeZoneInfo? timeZone = null)
    {
        culture ??= CultureInfo.CurrentCulture;
        timeZone ??= TimeZoneInfo.Local;
        var when = TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds((long)(resetsAt * 1000)), timeZone);
        var today = TimeZoneInfo.ConvertTime(now, timeZone);
        var time = culture.DateTimeFormat.ShortTimePattern;
        var pattern = when.Date == today.Date ? time : "ddd, MMM d, " + time;
        return when.ToString(pattern, culture);
    }

    private static double Unix(DateTimeOffset d) => d.ToUnixTimeMilliseconds() / 1000.0;

    /// A provider failure whose title may gain " until <time>" and whose body may offer a wait, when the text gives a reset.
    private static TurnErrorCopy ProviderCopy(TurnErrorKind kind, string title, string otherwise, string text, DateTimeOffset now,
                                              DateTimeOffset? at, CultureInfo? culture, TimeZoneInfo? timeZone)
    {
        var resets = ResetsAt(text, at ?? now);
        var reset = resets is { } r && r > Unix(now) ? ResetTimeLabel(r, now, culture, timeZone) : "";
        return new TurnErrorCopy(kind, reset.Length == 0 ? title : $"{title} until {reset}",
            reset.Length == 0 ? otherwise : "Choose another model, or wait until then.", TurnErrorPrimary.ChooseModel, resets);
    }

    /// The failure's words when it is one of the known kinds; null for anything else (the card keeps its own title).
    /// `at`: when the failure happened (a relative wait counts from it). Precedence as on the web: open elsewhere, usage
    /// limit, billing, a bad key, the provider down, a gone model, model start, gateway busy; then the cut-off reply.
    public static TurnErrorCopy? Copy(string text, DateTimeOffset? now = null, DateTimeOffset? at = null,
                                      CultureInfo? culture = null, TimeZoneInfo? timeZone = null)
    {
        var n = now ?? DateTimeOffset.Now;
        if (Owned.Test(text))
            return new TurnErrorCopy(TurnErrorKind.AnotherWindow, "This chat is open somewhere else",
                $"{TranscriptWords.HostSentence}, or another window, has this chat open, so it can’t answer here. Start a new chat, or close it there and try again.",
                TurnErrorPrimary.NewChat);
        if (Limit.Test(text))
        {
            var resets = ResetsAt(text, at ?? n);
            var name = Provider.Groups(text)?[1];
            var reset = resets is { } r && r > Unix(n) ? ResetTimeLabel(r, n, culture, timeZone) : "";
            var who = name is not null ? $"{name[..1].ToUpperInvariant()}{name[1..]} usage limit" : "Usage limit";
            return new TurnErrorCopy(TurnErrorKind.UsageLimit, $"{who} reached{(reset.Length == 0 ? "" : $" until {reset}")}",
                reset.Length == 0 ? "Choose another model, or try again later." : "Choose another model, or wait until then.",
                TurnErrorPrimary.ChooseModel, resets);
        }
        if (Billing.Test(text))
            return ProviderCopy(TurnErrorKind.Billing, "Low on credit", "Choose another model, or add credit with its provider.",
                text, n, at, culture, timeZone);
        if (BadApiKey.Test(text))
            return ProviderCopy(TurnErrorKind.BadApiKey, "This model’s API key failed", "Choose another model, or fix the API key with its provider.",
                text, n, at, culture, timeZone);
        if (ProviderDown.Test(text))
        {
            var title = Overloaded.Test(text) ? "This model’s provider is overloaded" : "This model’s provider had a problem";
            return ProviderCopy(TurnErrorKind.ProviderDown, title, "Choose another model, or try again in a moment.",
                text, n, at, culture, timeZone);
        }
        if (ModelGone.Test(text))
            return new TurnErrorCopy(TurnErrorKind.ModelGone, "This model is gone", "Choose another model to continue this chat.",
                TurnErrorPrimary.ChooseModel);
        if (Start.Test(text))
            return new TurnErrorCopy(TurnErrorKind.ModelStart, "This chat’s model couldn’t start",
                $"{TranscriptWords.HostSentence} couldn’t start this chat’s model. Choose another model, or check the model’s provider there.",
                TurnErrorPrimary.ChooseModel);
        if (Busy.Test(text))
            return new TurnErrorCopy(TurnErrorKind.GatewayBusy, $"{TranscriptWords.HostSentence} is busy",
                "It didn’t answer in time while it checked its model. Try again in a moment.", TurnErrorPrimary.Retry);
        if (Cut.Test(text))
            return new TurnErrorCopy(TurnErrorKind.CutOff, CutOffTitle,
                $"The connection dropped before the reply finished. {TranscriptWords.Tap} Try Again to send it again.", TurnErrorPrimary.Retry);
        return null;
    }

    /// A provider or quota failure's Details start closed: the card's words already say what happened.
    public static bool DetailClosed(string? detail)
    {
        if (string.IsNullOrEmpty(detail)) return false;
        return Limit.Test(detail) || Start.Test(detail) || Billing.Test(detail) || BadApiKey.Test(detail)
            || ProviderDown.Test(detail) || ModelGone.Test(detail);
    }

    // Details that only repeat the card (r5-95)

    private static readonly TranscriptRx Marks = new("[`*_]");
    private static readonly TranscriptRx Trailing = new(@"[.\s]+$");
    private static readonly TranscriptRx SpacesRe = new(@"\s+");

    private static string Squash(string text) =>
        TxText.TrimSpaces(SpacesRe.Replace(Trailing.Replace(Marks.Replace(text.ToLowerInvariant(), ""), ""), " "));

    public static bool DetailRepeatsBody(string detail, params string?[] shown)
    {
        var text = Squash(detail);
        if (text.Length == 0) return true;
        return shown.Any(line =>
        {
            if (string.IsNullOrEmpty(line)) return false;
            var s = Squash(line);
            return s == text || s.StartsWith(text, StringComparison.Ordinal);
        });
    }

    // No retry words without a Retry button (r6-01)

    private static readonly TranscriptRx RetryAlone = new(@"^(?:tap\s+)?(?:retry|try again)(?:\s+(?:to|and)\b[^.]*)?\.?$", I);
    private static readonly TranscriptRx RetryOr = new(@"^(?:retry|try again),?\s+or\s+(.+)$", I);
    private static readonly TranscriptRx Moment = new(@"^(?:retry|try again)\s+in\s+a\s+moment(?:,?\s+or\s+(.+?))?\.?$", I);
    private static readonly TranscriptRx Later = new(@"^(?:retry|try again)\s+later\.?$", I);
    private static readonly TranscriptRx ThenRetry = new(@",?\s*then\s+retry\b", I);
    private static readonly TranscriptRx TryAgain = new(@"\btry\s+again\b", I);
    private static readonly TranscriptRx LeadRetry = new(@"^retry\b", I);
    private static readonly TranscriptRx SentenceEnd = new(@"(?<=[.!?])\s+");
    private static readonly TranscriptRx RetryHint = new(@"\s*(?:Tap Try Again|Retry)(?: to| and)? [^.]*\.?\s*$");

    private static string Period(string text) => text.Length == 0 || ".!?".Contains(text[^1]) ? text : text + ".";

    private static string? WithoutRetrySentence(string sentence)
    {
        var text = TxText.TrimSpaces(sentence);
        if (RetryAlone.Test(text)) return null;
        if (RetryOr.Groups(text) is { } g && g[1] is { } rest) return Period(TxText.Cap(TxText.TrimSpaces(rest)));
        if (Moment.Groups(text) is { } m)
        {
            if (m[1] is { Length: > 0 } r) return $"{TxText.Cap(TxText.TrimSpaces(r))}, or send it again in a moment.";
            return "Send it again in a moment.";
        }
        if (Later.Test(text)) return "Send it again later.";
        var out_ = ThenRetry.Replace(text, ", then send it again");
        out_ = TryAgain.Replace(out_, "send it again");
        out_ = LeadRetry.Replace(out_, "Send it again");
        return out_;
    }

    /// The card's body when it offers no Retry: sentence by sentence, without retry wording.
    public static string WithoutRetryWords(string body)
    {
        var marked = SentenceEnd.Replace(body.Trim(), "\u0001");
        var kept = marked.Split('\u0001', StringSplitOptions.RemoveEmptyEntries)
            .Select(WithoutRetrySentence).OfType<string>().Where(s => TxText.TrimSpaces(s).Length > 0);
        var out_ = TxText.TrimSpaces(string.Join(" ", kept));
        return out_.Length == 0 ? body : out_;
    }

    /// The card's body without the sentence that points at Retry.
    public static string WithoutRetryHint(string body)
    {
        var out_ = TxText.TrimSpaces(RetryHint.Replace(body, ""));
        return out_.Length == 0 ? body : out_;
    }

    // One card per failed turn (r1-37)

    public static bool SameFailure(string a, string b)
    {
        if (a.Trim() == b.Trim()) return true;
        return Copy(a)?.Kind is { } ka && Copy(b)?.Kind is { } kb && ka == kb;
    }

    private static bool Shows(ChatMessage message) =>
        message.Parts.Any(p => p is not TextPart t || t.Text.Trim().Length > 0);

    /// A failed submit and the stream's own error for the same turn each made a card with the same failure: the turn
    /// keeps one (the one with output, else the latest). The others keep their place with their error cleared, so the
    /// list's positions do not move. The same list comes back when nothing changed.
    public static IReadOnlyList<ChatMessage> WithoutDuplicateTurnErrors(IReadOnlyList<ChatMessage> messages)
    {
        var lastUser = -1;
        for (var i = messages.Count - 1; i >= 0; i--) if (messages[i].Role == Role.User) { lastUser = i; break; }
        var failed = Enumerable.Range(0, messages.Count)
            .Where(i => i > lastUser && messages[i].Role == Role.Assistant && messages[i].Error is not null).ToList();
        if (failed.Count < 2) return messages;
        var drop = new HashSet<int>();
        foreach (var index in failed)
        {
            var message = messages[index];
            if (Shows(message)) continue;
            var twin = failed.Any(other => other != index && !drop.Contains(other)
                && SameFailure(messages[other].Error ?? "", message.Error ?? "")
                && (Shows(messages[other]) || other > index));
            if (twin) drop.Add(index);
        }
        if (drop.Count == 0) return messages;
        var out_ = messages.ToList();
        foreach (var index in drop) out_[index] = out_[index] with { Error = null, Revision = out_[index].Revision + 1 };
        return out_;
    }

    // The session problem (r5-92)

    private static readonly TranscriptRx Cancelled = new(@"^(?:Turn cancelled|Session no longer running) before the agent was ready", I);
    private static readonly TranscriptRx Reopen = new("could not reopen that session", I);

    /// A session-level error the chat does not report (a turn cancelled before the agent was ready).
    public static bool IsIgnoredSessionError(string text) => Cancelled.Test(text.Trim());

    public static bool IsReopenFailure(string text) => Reopen.Test(text);
}

public enum SessionProblemPrimary { ChooseModel, TryAgain, NewChat }

/// A problem with the chat itself (no turn in flight): the card docked above the composer (§6.2).
/// `Detail`: the raw text, for Copy (and "More").
public sealed record SessionProblem(string Title, string Body, string Detail, SessionProblemPrimary Primary)
{
    public const string ReopenTitle = "Couldn’t reopen this chat";

    /// The chat could not be reopened (§6.5): a resume that lands clears it.
    public bool Reopen => Title == ReopenTitle;

    /// What Copy puts on the clipboard.
    public string CopyText => string.Join("\n\n", new[] { Title, Body, Detail == Body ? "" : Detail }.Where(s => s.Length > 0));

    /// The card for an `error` event that arrived with no turn running; null for the ones the chat ignores.
    /// `botName`: "Hermes reported a problem" names the chat's bot. `room`: a group room has no single model to choose.
    public static SessionProblem? Make(string text, string botName, bool room = false, DateTimeOffset? now = null)
    {
        var raw = text.Trim();
        if (raw.Length == 0 || TurnErrors.IsIgnoredSessionError(raw)) return null;
        var known = TurnErrors.Copy(raw, now);
        var bot = TxText.TrimSpaces(botName);
        var title = known?.Title ?? (TurnErrors.IsReopenFailure(raw) ? ReopenTitle : $"{(bot.Length == 0 ? "Hermes" : bot)} reported a problem");
        var isShort = raw.Length <= 240 && !raw.Any(TxText.IsNewline);
        var body = known?.Body ?? (isShort ? raw : "Something went wrong with this chat. Copy the details if it keeps happening.");
        var choose = !room && (known?.Kind == TurnErrorKind.UsageLimit || known?.Kind == TurnErrorKind.ModelStart);
        return new SessionProblem(title, body, raw, choose ? SessionProblemPrimary.ChooseModel : SessionProblemPrimary.TryAgain);
    }

    /// The gateway won't open this chat any more: the card's one action is a new chat with the same bot.
    public const string ChatLockedTitle = "This chat can’t take messages";

    public static SessionProblem ChatLocked(string detail) => new(ChatLockedTitle,
        "Hermes won’t open this chat any more, so messages sent here can’t reach it. Your message is still in the box below. Continue in a new chat with the same bot.",
        detail, SessionProblemPrimary.NewChat);

    /// A cold bot that never came up (§6.5): both resume attempts failed or timed out.
    public static SessionProblem ReopenFailed(bool starting)
    {
        var body = starting ? $"This chat is still starting on {TranscriptWords.HostPhrase}." : $"{TranscriptWords.HostSentence} didn’t answer in time.";
        return new SessionProblem(ReopenTitle, body, body, SessionProblemPrimary.TryAgain);
    }
}

/// A send the gateway refused, or that never left (§6.3): the "Couldn’t Send" card at the composer.
public sealed record SendFailure(string Reason, bool TimedOut, bool Offline, DateTimeOffset At)
{
    public const string Title = "Couldn’t Send";

    public string Body
    {
        get
        {
            if (TimedOut) return $"{TranscriptWords.HostSentence} didn’t answer in time. Your message is still in the box below.";
            if (Offline) return "You’re offline. Your message is still in the box below.";
            // 4090 SESSION_NOT_OWNED: often this device's own earlier connection; said plainly.
            if (TurnErrors.Owned.Test(Reason))
                return "Your message is still in the box below. Hermes has this chat open somewhere else, like the Hermes desktop app. Close it there and try again, or start a new chat.";
            // 4090 SESSION_OWNER_BUSY: the gateway's own words name "the gateway" twice and an internal queue.
            if (TurnErrors.OwnerBusy.Test(Reason))
                return "Your message is still in the box below. Hermes is still running a reply in this chat. Send it again when that reply is done.";
            var words = OneSentence(Reason);
            return words.Length == 0 ? "Your message is still in the box below." : $"Your message is still in the box below. {words}";
        }
    }

    /// The gateway's whole refusal, for the card's Copy, when it carries a `Details:` line the body leaves out.
    public string? CopyText =>
        TxText.NonEmptyLines(Reason).Any(l => TxText.TrimSpaces(l).StartsWith("Details:", StringComparison.Ordinal)) ? Reason : null;

    /// The gateway's message as one sentence, at most 160 characters.
    public static string OneSentence(string reason)
    {
        var text = reason.Trim();
        if (TxText.NonEmptyLines(text) is { Count: > 0 } lines) text = lines[0];
        if (text.Length > 160) text = TxText.TrimSpaces(text[..159]) + "…";
        if (text.Length == 0) return "";
        text = text[..1].ToUpperInvariant() + text[1..];
        if (!".!?…".Contains(text[^1])) text += ".";
        return text;
    }

    public static SendFailure Make(string? reason, DateTimeOffset? now = null)
    {
        var raw = (reason ?? "").Trim();
        var lower = raw.ToLowerInvariant();
        var timedOut = lower.Contains("timed out") || lower.Contains("timeout") || lower.Contains("didn’t answer in time")
            || lower.Contains("didn't answer in time");
        var offline = lower.StartsWith("you’re offline", StringComparison.Ordinal) || lower.StartsWith("you're offline", StringComparison.Ordinal)
            || lower.Contains("internet connection appears to be offline") || lower.Contains("not connected to the internet");
        return new SendFailure(raw, timedOut, offline && !timedOut, now ?? DateTimeOffset.Now);
    }
}
