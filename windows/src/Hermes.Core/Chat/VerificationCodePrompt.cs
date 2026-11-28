using System.Text.RegularExpressions;
using Hermes.Core.Model;

namespace Hermes.Core.Chat;

/// Detects when an agent is asking for a one-time verification code (email, SMS, or authenticator app) so the chat
/// composer and question dock can offer a dedicated verification-code input (HermesKit/Chat/VerificationCodePrompt.swift).
public static class VerificationCodePrompt
{
    /// Non-OTP uses of the word "code" that should never trigger the verification-code prompt.
    private static readonly string[] NonOtpCodeTerms =
    [
        "source code", "exit code", "error code", "status code", "http code", "response code",
        "zip code", "postal code", "area code", "country code", "dialing code",
        "promo code", "promotional code", "discount code", "coupon code", "referral code", "voucher code",
        "qr code", "bar code", "barcode", "color code", "colour code", "hex code", "cheat code", "dress code",
        "codebase", "code block", "code snippet", "code review", "pseudo code", "pseudocode",
        "invite code", "invitation code", "gift code", "redeem code", "airport code", "swift code", "iban code",
        "morse code", "area-code", "zip-code", "vs code",
    ];

    /// Direct phrases that unambiguously name a one-time login/verification code.
    private static readonly string[] DirectPhrases =
    [
        "verification code",
        "one-time code",
        "one time code",
        "one-time passcode",
        "one time passcode",
        "one-time password",
        "one time password",
        "security code",
        "login code",
        "sign-in code",
        "sign in code",
        "signin code",
        "confirmation code",
        "authentication code",
        "auth code",
        "2fa code",
        "two-factor code",
        "two factor code",
        "mfa code",
        "sms code",
        "email code",
        "text message code",
        "authenticator code",
        "otp code",
        "verification pin",
        "login pin",
        "sign-in pin",
    ];

    /// Phrases that pair a generic "code" with delivery or an explicit request for the user to supply it.
    private static readonly string[] ContextualCodeAsks =
    [
        "sent a code",
        "sent you a code",
        "sent the code",
        "emailed a code",
        "emailed you a code",
        "texted a code",
        "texted you a code",
        "code sent to",
        "code was sent",
        "code has been sent",
        "code to your email",
        "code to your phone",
        "code to your inbox",
        "code via email",
        "code via sms",
        "code via text",
        "code by email",
        "code by sms",
        "code by text",
        "code from your email",
        "code from your sms",
        "code from your text",
        "code from your phone",
        "code from your messages",
        "code from your authenticator",
        "code in your email",
        "code in your inbox",
        "code in your messages",
        "code in your texts",
        "enter the code",
        "enter your code",
        "provide the code",
        "share the code",
        "send me the code",
        "send the code",
        "reply with the code",
        "paste the code",
        "give me the code",
        "what's the code",
        "what is the code",
        "need the code",
        "needs a code",
        "needs the code",
        "asking for a code",
        "asking for the code",
        "prompted for a code",
        "prompting for a code",
        "waiting for the code",
        "waiting for a code",
        "type the code",
        "input the code",
        "read me the code",
        "tell me the code",
    ];

    /// Cues that indicate the assistant is actively asking or waiting for user input.
    private static readonly string[] AskCues =
    [
        "?", "please", "enter", "send", "share", "reply", "paste", "give", "provide", "type",
        "what's", "what is", "need", "needs", "asking", "waiting", "sent", "emailed", "texted",
        "check your", "let me know", "forward", "drop", "prompted", "prompting", "input",
    ];

    /// Past-tense sign-in completion phrases; if present near the end with no follow-up ask, the agent already moved on.
    private static readonly string[] CompletedPhrases =
    [
        "logged in successfully",
        "signed in successfully",
        "successfully logged in",
        "successfully signed in",
        "i'm logged in",
        "i am logged in",
        "i'm signed in",
        "i am signed in",
        "now logged in",
        "now signed in",
        "we're logged in",
        "we're signed in",
        "login succeeded",
        "sign-in succeeded",
        "verification succeeded",
        "verified successfully",
        "login complete",
        "sign-in complete",
    ];

    private static readonly string[] AuthOrDeliveryContext =
    [
        "email", "inbox", "sms", "text", "phone", "message", "authenticator",
        "login", "log in", "sign in", "sign-in", "signin", "verify", "verification",
        "2fa", "mfa", "two-factor", "two factor", "account", "enter", "send", "share", "sent",
    ];

    private static readonly Regex DigitCodeRegex = new(@"\b[4-8][- ]?digit\s+(?:code|pin|passcode)\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex OtpWordRegex = new(@"\botp\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex PasscodeWordRegex = new(@"\bpasscode\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// Trims surrounding whitespace from a typed or pasted code.
    public static string Normalize(string? raw) => (raw ?? "").Trim();

    /// True when `text` (an assistant reply or clarify question) is asking the user for a verification/OTP code.
    public static bool AsksForCode(string? text)
    {
        var normalized = Canonical(text);
        if (normalized.Length == 0) return false;

        // If the message is strictly talking about a non-OTP code (promo, zip, error, source, QR...) with no direct
        // verification-code phrase, never trigger.
        var hasDirect = ContainsAny(normalized, DirectPhrases)
            || DigitCodeRegex.IsMatch(normalized)
            || (OtpWordRegex.IsMatch(normalized) && HasAuthOrDeliveryContext(normalized))
            || (PasscodeWordRegex.IsMatch(normalized) && HasAuthOrDeliveryContext(normalized));

        bool hasContextual;
        if (hasDirect)
        {
            hasContextual = true;
        }
        else
        {
            var strippedNonOtp = StripNonOtpCodeTerms(normalized);
            hasContextual = ContainsAny(strippedNonOtp, ContextualCodeAsks);
        }
        if (!hasContextual) return false;

        // Require an active ask or delivery/waiting cue so purely descriptive prose doesn't trigger.
        if (!ContainsAny(normalized, AskCues)) return false;

        // If the agent already reports finishing sign-in and isn't asking a follow-up question, stay out of the way.
        var completedEnd = LastMatchEnd(CompletedPhrases, normalized);
        if (completedEnd >= 0)
        {
            var afterCompleted = normalized[completedEnd..];
            var stillAsking = afterCompleted.Contains('?', StringComparison.Ordinal)
                || ContainsAny(afterCompleted, DirectPhrases)
                || ContainsAny(afterCompleted, ContextualCodeAsks);
            if (!stillAsking) return false;
        }

        return true;
    }

    /// The latest message's id when the newest turn is an assistant message asking for a verification code (and the
    /// user hasn't replied after it yet); null otherwise.
    public static string? ActiveMessageId(IReadOnlyList<ChatMessage> messages)
    {
        ChatMessage? latest = null;
        for (var i = messages.Count - 1; i >= 0; i--)
        {
            var m = messages[i];
            if (m.Role is Role.User or Role.Assistant)
            {
                latest = m;
                break;
            }
        }
        if (latest == null || latest.Role != Role.Assistant) return null;
        var text = string.Join('\n', latest.Parts.OfType<TextPart>().Select(p => p.Text));
        return AsksForCode(text) ? latest.Id : null;
    }

    private static string Canonical(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return "";
        var folded = text
            .Replace('\u2019', '\'')
            .Replace('\u2018', '\'')
            .Replace('\u2013', '-')
            .Replace('\u2014', '-')
            .ToLowerInvariant();
        return string.Join(' ', folded.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
    }

    private static bool HasAuthOrDeliveryContext(string text) => ContainsAny(text, AuthOrDeliveryContext);

    private static string StripNonOtpCodeTerms(string text)
    {
        var output = text;
        foreach (var term in NonOtpCodeTerms)
            output = output.Replace(term, " ", StringComparison.Ordinal);
        return output;
    }

    private static bool ContainsAny(string text, string[] phrases)
    {
        foreach (var phrase in phrases)
            if (text.Contains(phrase, StringComparison.Ordinal))
                return true;
        return false;
    }

    private static int LastMatchEnd(string[] phrases, string text)
    {
        var bestEnd = -1;
        foreach (var phrase in phrases)
        {
            var index = text.LastIndexOf(phrase, StringComparison.Ordinal);
            if (index >= 0)
            {
                var end = index + phrase.Length;
                if (end > bestEnd) bestEnd = end;
            }
        }
        return bestEnd;
    }
}
