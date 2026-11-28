// Contracts added by the live-voice stream (docs/spec/3x-talk.md §2.3). `Contracts.swift` is not edited; the
// integrator may fold these in later.

import Foundation

/// A chat that can hold a live voice conversation (adopted by `LiveChatSession`, and by a fake in tests).
@MainActor
protocol ChatVoiceTurns: AnyObject {
    /// False in a group room (T25) and for a chat that cannot send.
    var allowsTalk: Bool { get }
    /// "<account id>|<profile>|<stored session id>": the same scope the memo stores use.
    var memoScope: String { get }
    var isRunning: Bool { get }
    var connection: ConnectionState { get }
    /// An ordinary send whose `prompt.submit` carries `interrupted: true` when asked (T2). Shows the usual bubble.
    func sendSpoken(_ text: String, interrupted: Bool)
    func stop()
    /// The assistant words of the newest turn, text parts only, in order. `pending` while it still streams.
    var newestReply: SpokenReply? { get }
    /// Fired after every change, on screen or off (a second listener beside `onChange`).
    var onVoiceChange: (() -> Void)? { get set }
    /// True while a conversation lives here: the chat keeps listening after its screen leaves (§2.4).
    var voiceHold: Bool { get set }
    /// What the away pill needs to reopen this chat.
    var storedSessionId: String? { get }
    /// False for a brand-new chat that nothing could lead back to yet (no saved id and not a bot's own chat): a
    /// conversation there ends when its screen is left (§6.6, DECISION).
    var canReopen: Bool { get }
    var profile: String { get }
    /// The gateway this chat talks to (speech to text, text to speech).
    var voiceClient: any GatewayClient { get }
    /// A reply by its message id (Read Aloud on an older message).
    func spokenText(messageId: String) -> SpokenReply?
    // [gpt-live] defaults below
    func sendDelegated(_ text: String, voiceContext: String)
    var runningToolTitle: String? { get }
    var spokenHistory: [(assistant: Bool, text: String)] { get }
    func spokenSeed() async -> [(assistant: Bool, text: String)]
    var openQuestion: VoiceQuestion? { get }
    func answerQuestion(_ id: String, spoken: String)
    var onDelegationRefused: (() -> Void)? { get set }
    func spokenReplies(since: Date) -> [SpokenReply]
    // [voice record] defaults below
    func sendVoiceRecord(_ text: String)
    var voiceFoldedMessageIds: Set<String> { get }
    var voiceFoldedRowIds: Set<Int> { get }
    var isAnsweringVoiceRecord: Bool { get }
    func setLiveVoiceActive(_ active: Bool)
    func noteLiveVoiceHeard(messageId: String)
    func revokeLiveVoiceHeard(messageId: String)
    func releaseUnheardLiveVoice(heardReplyIds: Set<String>)
    func finishLiveVoice(heardReplyIds: Set<String>, sendingRecord: Bool) -> [String]
}

// [gpt-live] What a GPT-Live conversation asks of the chat beyond the standard engine (docs/spec/3x-gpt-live.md §4).
// Defaults keep the test fakes compiling; `LiveChatSession` has the real ones.
extension ChatVoiceTurns {
    /// A delegation: an ordinary send whose `prompt.submit` carries `surface: voice-live` and `voice_context`.
    func sendDelegated(_ text: String, voiceContext: String) { sendSpoken(text, interrupted: false) }
    /// The title of the tool the running turn is in (its newest running tool row), or nil.
    var runningToolTitle: String? { nil }
    /// The chat's text turns, oldest first, for a new session's seed.
    var spokenHistory: [(assistant: Bool, text: String)] { [] }
    /// The turns a new session is seeded from: `spokenHistory` once the chat has loaded, read further back when what is
    /// on screen is less than the seed holds.
    func spokenSeed() async -> [(assistant: Bool, text: String)] { spokenHistory }
    /// The bot's question that waits for an answer, as the voice asks it (`VoiceQuestion`).
    var openQuestion: VoiceQuestion? { nil }
    /// What the person said in answer to it.
    func answerQuestion(_ id: String, spoken: String) {}
    /// The chat's finished assistant replies dated `since` or later, oldest first (never one still streaming, stopped
    /// or failed): what a GPT-Live conversation passes on when nothing else did.
    func spokenReplies(since: Date) -> [SpokenReply] { [] }
    /// What was said in a live voice conversation that just ended (`VoiceChatRecord.message`): one message, after
    /// whatever the chat is doing now. It never stops or steers a running reply.
    func sendVoiceRecord(_ text: String) {}
    /// [voice record] Delegated live-voice message ids and stored row ids folded into the Voice Chat card.
    var voiceFoldedMessageIds: Set<String> { [] }
    var voiceFoldedRowIds: Set<Int> { [] }
    /// [voice record] True only when the running turn is answering a `VoiceChatRecord` (`NO_REPLY`).
    var isAnsweringVoiceRecord: Bool { false }
    /// [voice record] Marks whether a live voice engine (GPT-Live / Grok Live) is actively running in this chat.
    func setLiveVoiceActive(_ active: Bool) {}
    /// [voice record] Records that `messageId`'s reply finished being spoken aloud and heard.
    func noteLiveVoiceHeard(messageId: String) {}
    /// [voice record] Revokes a previously noted heard reply if it was cut off on stop/interrupt.
    func revokeLiveVoiceHeard(messageId: String) {}
    /// [voice record] On fallback to Standard Talk, releases any still-running or unheard delegated live-voice turns
    /// immediately while keeping already-heard turns folded until the call ends.
    func releaseUnheardLiveVoice(heardReplyIds: Set<String>) {}
    /// [voice record] Ends live-voice hiding: returns stable content-hash fold tags (`[folded: …]`) for turns whose
    /// replies were actually heard, while unhiding any turn still running or unheard so the person can read it in chat.
    func finishLiveVoice(heardReplyIds: Set<String>, sendingRecord: Bool) -> [String] { [] }
    /// Called when a delegation's send was refused before the turn ran.
    var onDelegationRefused: (() -> Void)? {
        get { nil }
        set {}
    }
}

nonisolated struct SpokenReply: Equatable, Sendable {
    /// The assistant message's id (the highlight and "already spoken" key).
    var messageId: String
    /// Markdown, not yet cleaned for speech.
    var text: String
    var pending: Bool
}
