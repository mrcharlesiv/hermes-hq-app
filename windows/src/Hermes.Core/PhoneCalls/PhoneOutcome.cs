using System.Globalization;
using System.Text.RegularExpressions;

namespace Hermes.Core.PhoneCalls;

/// One samplehost call webhook event (`PhoneCallEvent` in `PhoneOutcome.swift`).
public sealed record PhoneCallEvent(
    string Type,
    DateTimeOffset? At = null,
    string? HangupCause = null,
    string? SipCode = null,
    string? MachineResult = null,
    string? Summary = null)
{
    public static DateTimeOffset? ParseTimestamp(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        if (DateTimeOffset.TryParse(raw.Trim(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var dt))
            return dt;
        return null;
    }
}

public enum PhoneOutcomeKind
{
    Finished,
    Voicemail,
    NoAnswer,
    Busy,
    Declined,
    NoSuchNumber,
    CouldNotConnect,
    Unknown,
}

public sealed record PhoneOutcome(PhoneOutcomeKind Kind, string? Reason = null)
{
    public static readonly PhoneOutcome Finished = new(PhoneOutcomeKind.Finished);
    public static readonly PhoneOutcome Voicemail = new(PhoneOutcomeKind.Voicemail);
    public static readonly PhoneOutcome NoAnswer = new(PhoneOutcomeKind.NoAnswer);
    public static readonly PhoneOutcome Busy = new(PhoneOutcomeKind.Busy);
    public static readonly PhoneOutcome Declined = new(PhoneOutcomeKind.Declined);
    public static readonly PhoneOutcome NoSuchNumber = new(PhoneOutcomeKind.NoSuchNumber);
    public static readonly PhoneOutcome Unknown = new(PhoneOutcomeKind.Unknown);
    public static PhoneOutcome CouldNotConnect(string reason) => new(PhoneOutcomeKind.CouldNotConnect, reason);
}

public enum PhoneLocalEnd
{
    None,
    YouHungUp,
    SafetyStop,
    RingTimeout,
}

/// Derives a calm, accurate call verdict from samplehost events, call status, and transcript (`PhoneOutcome.swift` port).
public static class PhoneVerdict
{
    public static PhoneOutcome Derive(
        IReadOnlyList<PhoneCallEvent> events,
        samplehostCallStatus? status,
        PhoneLocalEnd localEnd,
        IReadOnlyList<PhoneTranscriptLine> lines,
        bool everAnswered)
    {
        // Check machine / voicemail detection events first.
        if (events.Any(e =>
                e.Type.Contains("machine", StringComparison.OrdinalIgnoreCase)
                && (e.MachineResult?.Contains("machine", StringComparison.OrdinalIgnoreCase) == true
                    || e.MachineResult?.Contains("voicemail", StringComparison.OrdinalIgnoreCase) == true
                    || e.MachineResult?.Equals("human", StringComparison.OrdinalIgnoreCase) == false)))
        {
            return PhoneOutcome.Voicemail;
        }

        var cause = (events.Select(e => e.HangupCause).LastOrDefault(c => !string.IsNullOrWhiteSpace(c))
            ?? status?.HangupCause)?.Trim().ToLowerInvariant();
        var sip = events.Select(e => e.SipCode).LastOrDefault(s => !string.IsNullOrWhiteSpace(s))?.Trim();

        if (cause is "unallocated_number" or "invalid_number_format" or "no_route_destination" || sip == "404")
            return PhoneOutcome.NoSuchNumber;
        if (cause is "user_busy" or "busy" || sip == "486")
            return PhoneOutcome.Busy;
        if (cause is "call_rejected" or "rejected" || sip is "603" or "608")
            return PhoneOutcome.Declined;
        if (cause is "no_answer" or "originator_cancel" or "no_user_response" or "recovery_on_timer_expire" || sip == "480" || sip == "408")
        {
            if (!everAnswered) return PhoneOutcome.NoAnswer;
        }

        if (localEnd == PhoneLocalEnd.RingTimeout && !everAnswered)
            return PhoneOutcome.NoAnswer;

        // Heuristic voicemail check from transcript lines spoken by the remote party.
        var remoteText = string.Join(" ", lines.Where(l => l.Speaker == PhoneSpeaker.Them).Select(l => l.Text));
        if (PhoneFormatting.SoundsLikeVoicemail(remoteText))
            return PhoneOutcome.Voicemail;

        if (everAnswered || lines.Count > 0 || localEnd is PhoneLocalEnd.YouHungUp or PhoneLocalEnd.SafetyStop)
            return PhoneOutcome.Finished;

        if (!string.IsNullOrWhiteSpace(cause) && cause != "normal_clearing")
            return PhoneOutcome.CouldNotConnect(cause.Replace('_', ' '));

        return PhoneOutcome.Unknown;
    }
}

/// Phone number normalization, formatting, duration copy, and voicemail phrase detection (`PhoneOutcome.swift` port).
public static partial class PhoneFormatting
{
    [GeneratedRegex(@"^\+[1-9]\d{6,14}$")]
    private static partial Regex E164Regex();

    private static readonly string[] VoicemailPhrases =
    [
        "leave a message",
        "leave your message",
        "after the tone",
        "after the beep",
        "at the tone",
        "not available",
        "voice messaging system",
        "voicemail box",
        "mailbox is full",
        "has been forwarded to an automated",
        "please record your message",
        "unable to take your call",
    ];

    public static bool IsE164(string? raw) => !string.IsNullOrWhiteSpace(raw) && E164Regex().IsMatch(raw.Trim());

    /// Normalizes common US/international phone inputs into strict E.164 (`+15550100123`), or null when invalid.
    public static string? NormalizeDestination(string? raw, string defaultCountryCode = "1")
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        var s = raw.Trim();
        var hasPlus = s.StartsWith('+');
        var digits = new string(s.Where(char.IsDigit).ToArray());
        if (digits.Length == 0) return null;

        if (hasPlus)
        {
            var e164 = "+" + digits;
            return IsE164(e164) ? e164 : null;
        }
        if (digits.Length == 10 && defaultCountryCode == "1")
        {
            var e164 = "+1" + digits;
            return IsE164(e164) ? e164 : null;
        }
        if (digits.Length == 11 && digits.StartsWith('1') && defaultCountryCode == "1")
        {
            var e164 = "+" + digits;
            return IsE164(e164) ? e164 : null;
        }
        if (digits.Length is >= 7 and <= 15)
        {
            var e164 = "+" + digits;
            return IsE164(e164) ? e164 : null;
        }
        return null;
    }

    /// Formats `+15550100123` as `+1 555 010 0123` for display.
    public static string FormatShown(string? e164)
    {
        if (string.IsNullOrWhiteSpace(e164)) return "";
        var clean = e164.Trim();
        if (clean.StartsWith("+1", StringComparison.Ordinal) && clean.Length == 12 && clean[1..].All(char.IsDigit))
            return $"+1 {clean[2..5]} {clean[5..8]} {clean[8..12]}";
        return clean;
    }

    public static bool SoundsLikeVoicemail(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return false;
        return VoicemailPhrases.Any(p => text.Contains(p, StringComparison.OrdinalIgnoreCase));
    }

    public static string FormatDuration(TimeSpan elapsed)
    {
        var total = Math.Max(0, (int)Math.Floor(elapsed.TotalSeconds));
        var mins = total / 60;
        var secs = total % 60;
        if (mins == 0) return $"{secs}s";
        return secs == 0 ? $"{mins}m" : $"{mins}m {secs}s";
    }

    public static string FormatTimer(TimeSpan elapsed)
    {
        var total = Math.Max(0, (int)Math.Floor(elapsed.TotalSeconds));
        return $"{total / 60}:{total % 60:00}";
    }

    public static string OutcomeTitle(PhoneOutcome outcome, PhoneLocalEnd localEnd) => (outcome.Kind, localEnd) switch
    {
        (PhoneOutcomeKind.Voicemail, _) => "Went to Voicemail",
        (PhoneOutcomeKind.NoAnswer, _) => "No Answer",
        (PhoneOutcomeKind.Busy, _) => "Line Busy",
        (PhoneOutcomeKind.Declined, _) => "Call Declined",
        (PhoneOutcomeKind.NoSuchNumber, _) => "Number Not Found",
        (PhoneOutcomeKind.CouldNotConnect, _) => "Couldn’t Connect",
        (PhoneOutcomeKind.Finished, PhoneLocalEnd.SafetyStop) => "Stopped at 30-Minute Limit",
        (PhoneOutcomeKind.Finished, PhoneLocalEnd.YouHungUp) => "Call Ended",
        (PhoneOutcomeKind.Finished, _) => "Call Finished",
        _ => "Call Ended",
    };

    public static string OutcomeWords(PhoneOutcome outcome, PhoneLocalEnd localEnd, TimeSpan? answerDelay = null)
    {
        if (outcome.Kind == PhoneOutcomeKind.Voicemail && StraightToVoicemailNote(answerDelay) is { } note)
            return note;

        return (outcome.Kind, localEnd) switch
        {
            (PhoneOutcomeKind.Voicemail, _) => "The call reached voicemail.",
            (PhoneOutcomeKind.NoAnswer, _) => "Nobody picked up.",
            (PhoneOutcomeKind.Busy, _) => "The line was busy.",
            (PhoneOutcomeKind.Declined, _) => "The call was declined.",
            (PhoneOutcomeKind.NoSuchNumber, _) => "That phone number couldn’t be reached.",
            (PhoneOutcomeKind.CouldNotConnect, _) => string.IsNullOrWhiteSpace(outcome.Reason) ? "The call couldn’t connect." : $"Couldn’t connect: {outcome.Reason}.",
            (PhoneOutcomeKind.Finished, PhoneLocalEnd.SafetyStop) => "Ended automatically after reaching the 30-minute safety limit.",
            (PhoneOutcomeKind.Finished, PhoneLocalEnd.YouHungUp) => "You hung up the call.",
            (PhoneOutcomeKind.Finished, _) => "The call completed.",
            _ => "The call ended.",
        };
    }

    public static string? StraightToVoicemailNote(TimeSpan? answerDelay) =>
        answerDelay is { TotalSeconds: <= PhoneLimits.StraightToVoicemailSeconds }
            ? "Went straight to voicemail (answered within 3 seconds)."
            : null;
}
