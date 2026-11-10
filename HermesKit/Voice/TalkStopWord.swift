// Spoken stop phrases (docs/spec/3x-talk.md §4.1), ported from the web app's
// `vendor/hermes/apps/desktop/src/lib/voice-stop-word.ts` and `store/voice-prefs.ts`.
//
// It only fires when the WHOLE utterance is a stop phrase (optionally addressed to Hermes), so "stop the deploy" is
// sent as an ordinary turn.

import Foundation

nonisolated enum TalkStopWord {
    enum Config: Equatable, Sendable {
        /// `voice.stop_phrases` unset or still Hermes' own default: the built-in English list.
        case standard
        /// An explicit empty list: saying "stop" is just a message.
        case disabled
        case custom([String])
    }

    static let phrases = ["stop", "stop listening", "stop it", "stop please", "please stop", "stop stop", "that is all",
                          "that's all", "never mind", "nevermind", "end conversation", "end the conversation", "goodbye",
                          "good bye", "bye", "cancel"]
    static let addressPrefixes = ["hey hermes", "hey hermes,", "hermes", "hermes,", "ok", "okay", "hey"]
    /// Hermes' own default for `voice.stop_phrases`.
    static let backendDefault = ["stop"]

    /// Compose (NFKC), lowercase, punctuation of any script to spaces, collapse whitespace.
    static func normalize(_ text: String) -> String {
        var value = text.precomposedStringWithCompatibilityMapping.lowercased()
        value = value.replacingOccurrences(of: "\\p{P}+", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripAddress(_ text: String) -> String {
        for prefix in addressPrefixes where text != prefix && text.hasPrefix(prefix + " ") {
            return String(text.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private static let standardPhrases = phrases.map(normalize)

    /// True when the entire utterance is a stop command.
    static func isStop(_ transcript: String, config: Config = .standard) -> Bool {
        let list: [String]
        switch config {
        case .disabled: return false
        case .standard: list = standardPhrases
        case .custom(let custom): list = custom.map(normalize).filter { !$0.isEmpty }
        }
        guard !list.isEmpty else { return false }
        let normalized = normalize(transcript)
        guard !normalized.isEmpty else { return false }
        return list.contains(normalized) || list.contains(stripAddress(normalized))
    }

    /// A bare stop phrase typed while a conversation is live ends it instead of being sent (§6.7).
    static func interceptsTyped(active: Bool, text: String, attachments: Int = 0, config: Config = .standard) -> Bool {
        active && attachments == 0 && isStop(text, config: config)
    }

    /// `voice.stop_phrases`: a bare string is one phrase, entries that are not text or numbers are skipped, anything
    /// that is not a list or a string means Hermes' default.
    static func list(_ raw: JSONValue?) -> [String]? {
        let entries: [JSONValue]
        switch raw {
        case .string(let one)?: entries = [.string(one)]
        case .array(let many)?: entries = many
        default: return nil
        }
        return entries.compactMap { entry -> String? in
            switch entry {
            case .string(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines)
            case .number(let number): return number.rounded() == number ? String(Int64(number)) : String(number)
            default: return nil
            }
        }.filter { !$0.isEmpty }
    }

    static func config(from raw: JSONValue?, defaults: JSONValue? = nil) -> Config {
        guard let phrases = list(raw) else { return .standard }
        if phrases.isEmpty { return .disabled }
        let usual = list(defaults) ?? backendDefault
        let same = phrases.count == usual.count && zip(phrases, usual).allSatisfy { $0.lowercased() == $1.lowercased() }
        return same ? .standard : .custom(phrases)
    }
}
