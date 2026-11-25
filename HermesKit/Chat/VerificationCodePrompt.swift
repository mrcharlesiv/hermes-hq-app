// Detects when an agent is asking for a one-time verification code (email, SMS, or authenticator app) so the chat
// composer and question dock can offer a native `.oneTimeCode` AutoFill field above the keyboard.

import Foundation

nonisolated enum VerificationCodePrompt {
    /// Non-OTP uses of the word "code" that should never trigger the verification-code AutoFill bar.
    private static let nonOTPCodeTerms: [String] = [
        "source code", "exit code", "error code", "status code", "http code", "response code",
        "zip code", "postal code", "area code", "country code", "dialing code",
        "promo code", "promotional code", "discount code", "coupon code", "referral code", "voucher code",
        "qr code", "bar code", "barcode", "color code", "colour code", "hex code", "cheat code", "dress code",
        "codebase", "code block", "code snippet", "code review", "codebase", "pseudo code", "pseudocode",
        "invite code", "invitation code", "gift code", "redeem code", "airport code", "swift code", "iban code",
        "morse code", "area-code", "zip-code",
    ]

    /// Direct phrases that unambiguously name a one-time login/verification code.
    private static let directPhrases: [String] = [
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
    ]

    /// Phrases that pair a generic "code" with delivery or an explicit request for the user to supply it.
    private static let contextualCodeAsks: [String] = [
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
    ]

    /// Cues that indicate the assistant is actively asking or waiting for user input.
    private static let askCues: [String] = [
        "?", "please", "enter", "send", "share", "reply", "paste", "give", "provide", "type",
        "what's", "what is", "need", "needs", "asking", "waiting", "sent", "emailed", "texted",
        "check your", "let me know", "forward", "drop", "prompted", "prompting", "input",
    ]

    /// Past-tense sign-in completion phrases; if present near the end with no follow-up ask, the agent already moved on.
    private static let completedPhrases: [String] = [
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
    ]

    private static let digitCodeRegex = try! NSRegularExpression(pattern: #"\b[4-8][- ]?digit\s+(?:code|pin|passcode)\b"#)
    private static let otpWordRegex = try! NSRegularExpression(pattern: #"\botp\b"#)
    private static let passcodeWordRegex = try! NSRegularExpression(pattern: #"\bpasscode\b"#)

    /// Trims surrounding whitespace from a typed or AutoFilled code.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `text` (an assistant reply or clarify question) is asking the user for a verification/OTP code.
    static func asksForCode(_ text: String) -> Bool {
        let normalized = canonical(text)
        guard !normalized.isEmpty else { return false }

        // If the message is strictly talking about a non-OTP code (promo, zip, error, source, QR...) with no direct
        // verification-code phrase, never trigger.
        let hasDirect = directPhrases.contains { normalized.contains($0) }
            || matches(digitCodeRegex, in: normalized)
            || (matches(otpWordRegex, in: normalized) && hasAuthOrDeliveryContext(normalized))
            || (matches(passcodeWordRegex, in: normalized) && hasAuthOrDeliveryContext(normalized))

        let hasContextual: Bool
        if hasDirect {
            hasContextual = true
        } else {
            let strippedNonOTP = stripNonOTPCodeTerms(normalized)
            hasContextual = contextualCodeAsks.contains { strippedNonOTP.contains($0) }
        }
        guard hasContextual else { return false }

        // Require an active ask or delivery/waiting cue so purely descriptive prose doesn't trigger.
        guard askCues.contains(where: { normalized.contains($0) }) else { return false }

        // If the agent already reports finishing sign-in and isn't asking a follow-up question, stay out of the way.
        if let completedRange = lastMatchRange(of: completedPhrases, in: normalized) {
            let afterCompleted = normalized[completedRange.upperBound...]
            let stillAsking = afterCompleted.contains("?")
                || directPhrases.contains { afterCompleted.contains($0) }
                || contextualCodeAsks.contains { afterCompleted.contains($0) }
            if !stillAsking { return false }
        }

        return true
    }

    /// The latest message's id when the newest turn is an assistant message asking for a verification code (and the
    /// user hasn't replied after it yet); nil otherwise.
    static func activeMessageId(in messages: [ChatMessage]) -> String? {
        guard let latest = messages.last(where: { $0.role == .user || $0.role == .assistant }),
              latest.role == .assistant else { return nil }
        let text = latest.parts.compactMap { part -> String? in
            if case .text(let s) = part { return s }
            return nil
        }.joined(separator: "\n")
        return asksForCode(text) ? latest.id : nil
    }

    private static func canonical(_ text: String) -> String {
        let folded = text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .lowercased()
        let parts = folded.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func hasAuthOrDeliveryContext(_ text: String) -> Bool {
        let context = [
            "email", "inbox", "sms", "text", "phone", "message", "authenticator",
            "login", "log in", "sign in", "sign-in", "signin", "verify", "verification",
            "2fa", "mfa", "two-factor", "two factor", "account", "enter", "send", "share", "sent",
        ]
        return context.contains { text.contains($0) }
    }

    private static func stripNonOTPCodeTerms(_ text: String) -> String {
        var out = text
        for term in nonOTPCodeTerms {
            out = out.replacingOccurrences(of: term, with: " ")
        }
        return out
    }

    private static func lastMatchRange(of phrases: [String], in text: String) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for phrase in phrases {
            if let range = text.range(of: phrase, options: .backwards) {
                if best == nil || range.upperBound > best!.upperBound {
                    best = range
                }
            }
        }
        return best
    }
}
