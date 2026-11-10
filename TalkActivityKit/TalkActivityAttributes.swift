// [talk-background] The Live Activity a voice conversation shows on the Lock Screen and in the Dynamic Island while it
// runs (docs/spec/3x-talk-background.md). Built into the app (which starts, updates and ends it) and the
// HermesHQTalkActivity widget extension (which draws it). The buttons' intents run in the app's process.

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import AppIntents
import Foundation

nonisolated struct TalkActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        /// `TalkDockView.Phase` raw value ("listening", "thinking", …) or "ended".
        var phase: String
        /// The dock's title ("Listening", "Thinking…").
        var title: String
        var muted: Bool
        /// `<scheme>://session/<stored id>` once the chat has one: a conversation started in a brand-new chat gets its
        /// id with the first message, after the attributes were fixed. Preferred over `link`.
        var link: String? = nil
        /// When the conversation ended ("ended" only): the clock stops there.
        var endedAt: Date? = nil
    }

    /// The bot's name.
    var name: String
    /// When the conversation began: the activity's running clock counts from it.
    var startedAt: Date
    /// `<scheme>://session/<stored id>`: a tap opens the conversation's chat (nil before the chat has an id).
    var link: String?
    /// The app's accent, as `HQLiveAttributes.accent`.
    var accent: [Double]? = nil
}

/// What a Live Activity button asks of the app. The app sets `handler` at launch; the extension never runs it.
@MainActor enum TalkActivityActions {
    enum Action: Sendable { case end, toggleMute }
    static var handler: ((Action) -> Void)?
}

/// Ends the conversation from the Lock Screen or the Dynamic Island.
nonisolated struct TalkEndIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End Conversation"
    static let isDiscoverable = false

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        TalkActivityActions.handler?(.end)
        return .result()
    }
}

/// Mutes or unmutes the microphone from the Lock Screen or the Dynamic Island.
nonisolated struct TalkMuteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute or Unmute"
    static let isDiscoverable = false

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        TalkActivityActions.handler?(.toggleMute)
        return .result()
    }
}
#endif
