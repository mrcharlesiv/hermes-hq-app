using System.Text.RegularExpressions;

namespace Hermes.Core.Voice;

// Port of HermesKit/Voice/VoiceChatRecord.swift: encodes a live voice conversation's transcript into a single
// chat message ("[Voice chat transcript · M:SS]\n(From the app...)\n\nUser: ...\nVoice assistant: ..."), parses it
// back for the chat's collapsible Voice Chat card, and extracts clean spoken turns (without header or bot note) for
// future voice session seeds.

/// One speaker turn in a voice chat transcript.
public sealed record VoiceTurn(bool IsUser, string Text);

public static class VoiceChatRecordCodec
{
    /// Maximum characters kept in the formatted transcript body (oldest turns are dropped first).
    public const int MaxChars = 24_000;

    /// Opening prefix checked when identifying a voice chat transcript record.
    public const string MarkLead = "[Voice chat transcript";

    /// Instruction carried on the message for the bot (stripped from chat card display and future voice seeds).
    public const string BotNote =
        "(From the app, not typed by the user: this is what was said in the voice chat that just ended, "
        + "kept here so you have it. \"Voice assistant\" is the voice that spoke with the user for you. Everything they "
        + "asked for in it was already passed to you as it was said. Do not act on this message and do not answer it: "
        + "reply with exactly NO_REPLY.)";

    /// Marker inserted when earlier turns of a long voice chat were omitted to stay under `MaxChars`.
    public const string CutNote = "(The earlier part of a long voice chat is left out.)";

    private static readonly Regex HeadRegex = new(
        @"^\[Voice chat transcript(?: · ([0-9:]{1,9}))?\][ \t]*(?:\r?\n|$)",
        RegexOptions.CultureInvariant);

    private static readonly Regex WhitespaceRuns = new(@"\s+", RegexOptions.CultureInvariant);

    /// Appends a live transcript fragment, merging consecutive fragments from the same speaker into one turn.
    public static void AddFragment(List<VoiceTurn> turns, bool isUser, string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        if (turns.Count > 0 && turns[^1].IsUser == isUser)
            turns[^1] = turns[^1] with { Text = turns[^1].Text + text };
        else
            turns.Add(new VoiceTurn(isUser, text));
    }

    /// Collapses whitespace within each turn, drops blank turns, and merges adjacent same-speaker turns.
    public static IReadOnlyList<VoiceTurn> Settle(IReadOnlyList<VoiceTurn> turns)
    {
        var settled = new List<VoiceTurn>(turns.Count);
        foreach (var turn in turns)
        {
            var words = Collapse(turn.Text);
            if (words.Length == 0) continue;
            if (settled.Count > 0 && settled[^1].IsUser == turn.IsUser)
                settled[^1] = settled[^1] with { Text = settled[^1].Text + " " + words };
            else
                settled.Add(new VoiceTurn(turn.IsUser, words));
        }
        return settled;
    }

    /// Formats duration as `M:SS` (or `H:MM:SS` for conversations lasting an hour or longer).
    public static string FormatElapsed(TimeSpan duration)
    {
        var seconds = duration.TotalSeconds;
        var whole = double.IsFinite(seconds) && seconds > 0 ? (long)Math.Floor(seconds) : 0L;
        var hours = whole / 3600;
        var minutes = (whole % 3600) / 60;
        var secs = whole % 60;
        return hours > 0 ? $"{hours}:{minutes:00}:{secs:00}" : $"{minutes}:{secs:00}";
    }

    /// True when `text` (trimmed) is a stored voice chat transcript record.
    public static bool IsVoiceChatRecord(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return false;
        var trimmed = text.Trim();
        return trimmed.StartsWith(MarkLead, StringComparison.Ordinal) && HeadRegex.IsMatch(trimmed);
    }

    /// Parses a stored voice chat record into its card title ("Voice Chat · M:SS") and display body ("You: …\n\nVoice: …"),
    /// or null when `text` is not a voice chat record.
    public static (string Title, string Body)? ParseCard(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var trimmed = text.Trim();
        if (!trimmed.StartsWith(MarkLead, StringComparison.Ordinal)) return null;
        var match = HeadRegex.Match(trimmed);
        if (!match.Success) return null;

        var length = match.Groups[1].Success ? match.Groups[1].Value : null;
        var title = length is { Length: > 0 } ? $"Voice Chat · {length}" : "Voice Chat";
        var rest = StripBotNote(trimmed[match.Length..]);

        var lines = new List<string>();
        foreach (var rawLine in rest.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var line = rawLine.Trim();
            if (line.Length == 0) continue;
            if (line.StartsWith("User: ", StringComparison.Ordinal))
                lines.Add("You: " + line["User: ".Length..]);
            else if (line.StartsWith("Voice assistant: ", StringComparison.Ordinal))
                lines.Add("Voice: " + line["Voice assistant: ".Length..]);
            else
                lines.Add(line);
        }

        return (title, string.Join("\n\n", lines));
    }

    /// Formats a finished voice chat into the single transcript message to queue into the chat, or null when
    /// the user said nothing worth keeping (empty, whitespace only, or only a stop phrase).
    public static string? FormatMessage(IReadOnlyList<VoiceTurn> turns, TimeSpan duration)
    {
        var said = Settle(turns);
        var person = string.Join(" ", said.Where(t => t.IsUser).Select(t => t.Text));
        if (person.Length == 0 || TalkStopWord.IsStopPhrase(person)) return null;

        var lines = said.Select(t => $"{(t.IsUser ? "User" : "Voice assistant")}: {t.Text}").ToList();
        var cut = false;
        var totalChars = lines.Sum(l => l.Length + 1);
        while (lines.Count > 1 && totalChars > MaxChars)
        {
            totalChars -= lines[0].Length + 1;
            lines.RemoveAt(0);
            cut = true;
        }
        if (lines.Count == 1 && lines[0].Length > MaxChars)
        {
            lines[0] = lines[0][^MaxChars..];
            cut = true;
        }

        var head = $"{MarkLead} · {FormatElapsed(duration)}]";
        var parts = new List<string>(lines.Count + 4) { head, BotNote, "" };
        if (cut) parts.Add(CutNote);
        parts.AddRange(lines);
        return string.Join("\n", parts);
    }

    /// Extracts the spoken turns from a voice chat transcript message (stripping header, bot note, and truncation note)
    /// for seeding future voice sessions without leaking the `NO_REPLY` instruction.
    public static IReadOnlyList<VoiceTurn> SpokenTurns(string message)
    {
        if (ParseCard(message) is not { } card || string.IsNullOrWhiteSpace(card.Body))
            return [];

        var raw = new List<VoiceTurn>();
        foreach (var rawLine in card.Body.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || string.Equals(line, CutNote, StringComparison.Ordinal)) continue;

            if (line.StartsWith("You: ", StringComparison.Ordinal))
                raw.Add(new VoiceTurn(true, line["You: ".Length..]));
            else if (line.StartsWith("Voice: ", StringComparison.Ordinal))
                raw.Add(new VoiceTurn(false, line["Voice: ".Length..]));
            else if (line.StartsWith("User: ", StringComparison.Ordinal))
                raw.Add(new VoiceTurn(true, line["User: ".Length..]));
            else if (line.StartsWith("Voice assistant: ", StringComparison.Ordinal))
                raw.Add(new VoiceTurn(false, line["Voice assistant: ".Length..]));
        }

        return Settle(raw);
    }

    /// Formats a stored voice chat record as a clean seed summary without the bot note, or null if not a record.
    public static string? SeedSummary(string? message) =>
        ParseCard(message) is { } card ? "(Said in an earlier voice chat) " + card.Body : null;

    private static string Collapse(string text) =>
        string.IsNullOrWhiteSpace(text) ? "" : WhitespaceRuns.Replace(text.Trim(), " ");

    private static string StripBotNote(string rest)
    {
        if (!rest.StartsWith("(From the app", StringComparison.Ordinal)) return rest;
        var closeCrlf = rest.IndexOf(")\r\n", StringComparison.Ordinal);
        var closeLf = rest.IndexOf(")\n", StringComparison.Ordinal);
        if (closeCrlf >= 0 && (closeLf < 0 || closeCrlf < closeLf))
            return rest[(closeCrlf + 3)..];
        if (closeLf >= 0)
            return rest[(closeLf + 2)..];
        var lastClose = rest.LastIndexOf(')');
        return lastClose >= 0 ? rest[(lastClose + 1)..] : rest;
    }
}
