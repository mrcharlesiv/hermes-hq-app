// [botslist] A bot's standing problem, as its row says it in orange (parity §3 L185, docs/spec/3x-botslist.md §9).
// The classes and patterns are the desktop plugin's (`V/plugins/hermes-bots/data.ts:54-166`): a provider sign-in or
// access failure, an exhausted quota or balance, a provider that was never set up, a blocked agent. A passing failure
// (rate limit, 429, 5xx, overloaded, timeout) is not a standing problem and says nothing. Display only, never saved:
// the latest failure wins and the bot's next good turn clears it.

import Foundation

nonisolated enum Attention: String, Sendable, CaseIterable {
    case providerAuthOrAccess = "provider_auth_or_access"
    case providerQuotaLimit = "provider_quota_limit"
    case missingConfig = "missing_config"
    case agentBlocked = "agent_blocked"

    /// The row's words. DECISION (spec §9): "bot", not "profile", and no Terminal command (the owner runs none); the
    /// chat's own error message says what failed.
    var words: String {
        switch self {
        case .providerAuthOrAccess: "Sign in again for this bot"
        case .providerQuotaLimit: "Quota or balance exhausted"
        case .missingConfig: "Provider not set up"
        case .agentBlocked: "Bot is blocked — see its last message"
        }
    }

    private static let transient = JSRegex(#"rate.?limit|too many requests|\b429\b|\b5\d\d\b|server error|overloaded|timed?.?out|timeout|temporar"#, "i")
    private static let missing = JSRegex(#"no llm provider|no access token|not configured|no api key|missing api key"#, "i")
    private static let auth = JSRegex(#"\b401\b|\b403\b|unauthorized|forbidden|authentication|invalid.?api.?key|credentials? (are )?(invalid|expired)"#, "i")
    private static let quota = JSRegex(#"quota|out of funds|insufficient (credits?|funds|balance)|payment required|\b402\b|billing"#, "i")
    private static let blocked = JSRegex(#"\bblocked\b"#, "i")

    /// The class of a failed turn: the gateway's own `reason` when it names one, else read from the message; nil for a
    /// passing failure or anything unrecognised.
    static func reason(from message: String?, reason: String? = nil) -> Attention? {
        if let reason, let named = Attention(rawValue: reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) { return named }
        guard let message, !message.isEmpty else { return nil }
        if transient.test(message) { return nil }
        if missing.test(message) { return .missingConfig }
        if auth.test(message) { return .providerAuthOrAccess }
        if quota.test(message) { return .providerQuotaLimit }
        if blocked.test(message) { return .agentBlocked }
        return nil
    }
}
