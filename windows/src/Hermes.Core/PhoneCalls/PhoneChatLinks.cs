using System.Security.Cryptography;
using System.Text;

namespace Hermes.Core.PhoneCalls;

/// Constants and markers shared between the Phone Calls window and Chat views (`PhoneChatLinks.swift`, `PhoneChatCards.swift`).
public static class PhoneMark
{
    public const string ProposalScheme = "hermes";
    public const string ProposalHost = "phone-call";
    public const string ResultPrefix = "[Phone Call Result]";
    public const string CapabilityNoteMarker = "[Hermes Phone Calling Note]";
}

/// Parsed `hermes://phone-call?to=...&goal=...&name=...&voicemail=leave` proposal link (`PhoneChatLinks.swift` port).
public sealed record PhoneProposal(
    string To,
    string Goal,
    string? Name = null,
    PhoneVoicemailChoice Voicemail = PhoneVoicemailChoice.HangUp)
{
    public string ToUri()
    {
        var q = new List<string>
        {
            "to=" + Uri.EscapeDataString(To),
            "goal=" + Uri.EscapeDataString(Goal),
        };
        if (!string.IsNullOrWhiteSpace(Name)) q.Add("name=" + Uri.EscapeDataString(Name!));
        if (Voicemail == PhoneVoicemailChoice.LeaveMessage) q.Add("voicemail=leave");
        return $"{PhoneMark.ProposalScheme}://{PhoneMark.ProposalHost}?{string.Join("&", q)}";
    }

    /// Parses a phone call proposal link. Refuses links originating outside chat (`fromChat == false`) for security.
    public static PhoneProposal? TryParse(string? rawUri, bool fromChat = true)
    {
        if (!fromChat || string.IsNullOrWhiteSpace(rawUri)) return null;
        if (!Uri.TryCreate(rawUri.Trim(), UriKind.Absolute, out var uri)) return null;
        if (!string.Equals(uri.Scheme, PhoneMark.ProposalScheme, StringComparison.OrdinalIgnoreCase)) return null;
        if (!string.Equals(uri.Host, PhoneMark.ProposalHost, StringComparison.OrdinalIgnoreCase)) return null;

        var query = ParseQuery(uri.Query);
        if (!query.TryGetValue("to", out var rawTo) || PhoneFormatting.NormalizeDestination(rawTo) is not { } to)
            return null;
        if (!query.TryGetValue("goal", out var rawGoal) || string.IsNullOrWhiteSpace(rawGoal))
            return null;

        var goal = rawGoal.Trim();
        if (goal.Length > PhoneLimits.MaxGoalChars) goal = goal[..PhoneLimits.MaxGoalChars];

        string? name = null;
        if (query.TryGetValue("name", out var rawName) && !string.IsNullOrWhiteSpace(rawName))
        {
            name = rawName.Trim();
            if (name.Length > PhoneLimits.MaxNameChars) name = name[..PhoneLimits.MaxNameChars];
        }

        var vm = query.TryGetValue("voicemail", out var rawVm)
            && string.Equals(rawVm.Trim(), "leave", StringComparison.OrdinalIgnoreCase)
            ? PhoneVoicemailChoice.LeaveMessage
            : PhoneVoicemailChoice.HangUp;

        return new PhoneProposal(to, goal, name, vm);
    }

    private static Dictionary<string, string> ParseQuery(string query)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var q = query.TrimStart('?');
        if (q.Length == 0) return map;
        foreach (var pair in q.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = pair.IndexOf('=');
            var key = Uri.UnescapeDataString((eq >= 0 ? pair[..eq] : pair).Replace('+', ' '));
            var val = eq >= 0 ? Uri.UnescapeDataString(pair[(eq + 1)..].Replace('+', ' ')) : "";
            map[key] = val;
        }
        return map;
    }
}

/// Formats and parses call result messages posted back into chat (`PhoneChatCards.swift` port).
public static class PhoneResultMessage
{
    public static string Fingerprint(PhoneCallRecord call)
    {
        var input = $"{call.Id}|{call.To}|{call.StartedAt.ToUnixTimeSeconds()}|{call.Outcome?.Kind}";
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(input)))[..12];
    }

    public static string Format(PhoneCallRecord call, string? apiKey = null)
    {
        var outcome = call.Outcome ?? PhoneOutcome.Unknown;
        var title = PhoneFormatting.OutcomeTitle(outcome, call.LocalEnd);
        var duration = call.AnsweredAt != null && call.EndedAt != null
            ? PhoneFormatting.FormatDuration(call.EndedAt.Value - call.AnsweredAt.Value)
            : null;

        var sb = new StringBuilder();
        sb.AppendLine($"{PhoneMark.ResultPrefix} {call.DisplayTarget} ({PhoneFormatting.FormatShown(call.To)})");
        sb.AppendLine($"Outcome: {title}" + (duration != null ? $" · {duration}" : ""));
        sb.AppendLine($"Goal: {call.Goal}");
        if (!string.IsNullOrWhiteSpace(call.Summary))
            sb.AppendLine($"Summary: {call.Summary}");
        if (call.QAs.Count > 0)
        {
            sb.AppendLine("Questions answered:");
            foreach (var qa in call.QAs)
                sb.AppendLine($"- {qa.Question} → {qa.Answer}");
        }
        sb.Append($"Ref: {Fingerprint(call)}");
        return PhoneMessages.Redact(sb.ToString(), apiKey);
    }
}

/// Parsed chat bubble card for a delivered phone call result (`PhoneChatCards.swift`).
public sealed record PhoneResultCard(
    string Target,
    string OutcomeLine,
    string Goal,
    string? Summary,
    string? Fingerprint)
{
    public static PhoneResultCard? TryParse(string? messageText)
    {
        if (string.IsNullOrWhiteSpace(messageText)) return null;
        var trimmed = messageText.Trim();
        if (!trimmed.StartsWith(PhoneMark.ResultPrefix, StringComparison.Ordinal)) return null;

        var lines = trimmed.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        var header = lines[0][PhoneMark.ResultPrefix.Length..].Trim();
        string outcome = "", goal = "";
        string? summary = null, fp = null;
        foreach (var line in lines.Skip(1))
        {
            if (line.StartsWith("Outcome:", StringComparison.Ordinal)) outcome = line["Outcome:".Length..].Trim();
            else if (line.StartsWith("Goal:", StringComparison.Ordinal)) goal = line["Goal:".Length..].Trim();
            else if (line.StartsWith("Summary:", StringComparison.Ordinal)) summary = line["Summary:".Length..].Trim();
            else if (line.StartsWith("Ref:", StringComparison.Ordinal)) fp = line["Ref:".Length..].Trim();
        }
        return new PhoneResultCard(header, outcome, goal, summary, fp);
    }
}

/// Appends the hidden calling-capability note when the user mentions placing a phone call, and strips it from bubbles.
public static class PhoneChatNote
{
    private static readonly string[] TriggerWords = ["call ", "phone ", "dial ", "voicemail", "ring "];

    public static bool ShouldAttach(string text, bool phoneReady)
    {
        if (!phoneReady || string.IsNullOrWhiteSpace(text)) return false;
        if (text.Contains(PhoneMark.CapabilityNoteMarker, StringComparison.Ordinal)) return false;
        var lower = " " + text.Trim().ToLowerInvariant() + " ";
        return TriggerWords.Any(w => lower.Contains(w, StringComparison.Ordinal));
    }

    public static string Attach(string text)
    {
        var note = $"\n\n{PhoneMark.CapabilityNoteMarker} This app can place real phone calls when you include a `hermes://phone-call?to=+1...&goal=...` link. Confirm details with the user first.";
        return text.TrimEnd() + note;
    }

    public static string Strip(string text)
    {
        var idx = text.IndexOf(PhoneMark.CapabilityNoteMarker, StringComparison.Ordinal);
        return idx < 0 ? text : text[..idx].TrimEnd();
    }
}

/// Live in-chat chip words (`PhoneChatChip.swift` port).
public sealed record PhoneChipState(
    bool Visible,
    string Text,
    bool NeedsAttention,
    bool IsLive,
    string? CallId);

public static class PhoneChipWords
{
    public static PhoneChipState From(PhoneCallRecord? call, DateTimeOffset now)
    {
        if (call is not { IsActive: true })
            return new PhoneChipState(false, "", false, false, null);

        if (call.PendingQuestion != null)
            return new PhoneChipState(true, "Call needs you", NeedsAttention: true, IsLive: true, call.Id);

        if (call.State == PhoneCallState.Ending)
            return new PhoneChipState(true, "Ending the call", NeedsAttention: false, IsLive: false, call.Id);

        if (call.State is PhoneCallState.Dialing or PhoneCallState.Ringing)
            return new PhoneChipState(true, $"Calling {call.DisplayTarget}…", NeedsAttention: false, IsLive: false, call.Id);

        var timer = PhoneFormatting.FormatTimer(call.Elapsed(now));
        if (call.State == PhoneCallState.OnHold)
            return new PhoneChipState(true, $"On hold · {timer}", NeedsAttention: false, IsLive: true, call.Id);

        if (call.VoicemailDetected)
            return new PhoneChipState(true, $"Voicemail answered · {timer}", NeedsAttention: false, IsLive: true, call.Id);

        return new PhoneChipState(true, $"On a call · {timer}", NeedsAttention: false, IsLive: true, call.Id);
    }
}

/// Summary and share presentation helper (`PhoneCallPresentation.swift` port).
public static class PhoneCallPresentation
{
    public static string Title(PhoneCallRecord call) =>
        call.IsDone
            ? PhoneFormatting.OutcomeTitle(call.Outcome ?? PhoneOutcome.Unknown, call.LocalEnd)
            : call.State switch
            {
                PhoneCallState.Dialing => "Dialing…",
                PhoneCallState.Ringing => "Ringing…",
                PhoneCallState.OnHold => "On Hold",
                PhoneCallState.Ending => "Ending…",
                _ => "Connected",
            };

    public static string WhatHappened(PhoneCallRecord call)
    {
        if (!string.IsNullOrWhiteSpace(call.Summary)) return call.Summary!;
        if (!string.IsNullOrWhiteSpace(call.Error)) return call.Error!;
        var delay = call.AnsweredAt != null ? call.AnsweredAt.Value - call.StartedAt : (TimeSpan?)null;
        return PhoneFormatting.OutcomeWords(call.Outcome ?? PhoneOutcome.Unknown, call.LocalEnd, delay);
    }

    public static IReadOnlyList<(string Label, string Value)> Facts(PhoneCallRecord call, DateTimeOffset now)
    {
        var list = new List<(string, string)>
        {
            ("Number", PhoneFormatting.FormatShown(call.To)),
            ("Goal", call.Goal),
            ("Voicemail", call.Voicemail == PhoneVoicemailChoice.LeaveMessage ? "Leave a message" : "Hang up"),
        };
        if (call.AnsweredAt != null)
            list.Add(("Duration", PhoneFormatting.FormatDuration(call.Elapsed(now))));
        return list;
    }

    /// Builds a plain-text transcript/summary share block with API key redaction guaranteed.
    public static string ShareText(PhoneCallRecord call, string? apiKey = null)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"Phone Call · {call.DisplayTarget} ({PhoneFormatting.FormatShown(call.To)})");
        sb.AppendLine($"Status: {Title(call)}");
        sb.AppendLine($"Goal: {call.Goal}");
        sb.AppendLine($"Summary: {WhatHappened(call)}");
        if (call.QAs.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("Questions & Answers:");
            foreach (var qa in call.QAs)
                sb.AppendLine($"Q: {qa.Question}\nA: {qa.Answer}");
        }
        if (call.Lines.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("Transcript:");
            foreach (var line in call.Lines)
            {
                var who = line.Speaker switch
                {
                    PhoneSpeaker.Assistant => "Assistant",
                    PhoneSpeaker.Them => call.DisplayTarget,
                    PhoneSpeaker.You => "You",
                    _ => "System",
                };
                sb.AppendLine($"{who}: {line.Text}");
            }
        }
        return PhoneMessages.Redact(sb.ToString().TrimEnd(), apiKey);
    }
}
