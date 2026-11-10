// Stand-ins for the live-voice tests: a chat that records what a conversation asks of it, and a speaker with no audio.

import Foundation
@testable import HermesHQNative

@MainActor final class FakeTalkChat: ChatVoiceTurns {
    var allowsTalk = true
    var memoScope: String
    var isRunning = false
    var connection: ConnectionState = .ready
    var newestReply: SpokenReply?
    var onVoiceChange: (() -> Void)?
    var voiceHold = false
    var storedSessionId: String?
    var canReopen = true
    var profile: String
    let voiceClient: any GatewayClient = FakeGatewayClient()
    private(set) var sent: [(text: String, interrupted: Bool)] = []
    private(set) var stops = 0
    /// What a spoken send does to the chat (default: a turn starts running).
    var onSend: ((FakeTalkChat) -> Void)? = { $0.isRunning = true }
    var replies: [String: SpokenReply] = [:]

    init(profile: String = "ivy", stored: String? = "20260929_120000_aabbcc02") {
        self.profile = profile
        storedSessionId = stored
        memoScope = "acct|\(profile)|\(stored ?? "new")"
    }

    func sendSpoken(_ text: String, interrupted: Bool) {
        sent.append((text, interrupted))
        onSend?(self)
    }

    func stop() {
        stops += 1
        isRunning = false
        changed()
    }

    func spokenText(messageId: String) -> SpokenReply? { replies[messageId] }

    // [gpt-live]
    private(set) var delegated: [(text: String, context: String)] = []
    var runningTool: String?
    var history: [(assistant: Bool, text: String)] = []
    var onDelegationRefused: (() -> Void)?
    var runningToolTitle: String? { runningTool }
    var spokenHistory: [(assistant: Bool, text: String)] { history }
    /// The finished replies `spokenReplies(since:)` returns, whatever the date.
    var recent: [SpokenReply] = []
    func spokenReplies(since: Date) -> [SpokenReply] { recent }

    func sendDelegated(_ text: String, voiceContext: String) {
        delegated.append((text, voiceContext))
        onSend?(self)
    }

    func changed() { onVoiceChange?() }

    /// The bot's reply grows to `text`; `done` ends the turn.
    func reply(_ id: String, _ text: String, done: Bool) {
        newestReply = SpokenReply(messageId: id, text: text, pending: !done)
        if done { isRunning = false }
        changed()
    }
}

@MainActor final class FakeSpeechSession: SpeechSession {
    let messageId: String
    var onStarted: (() -> Void)?
    private(set) var appended: [String] = []
    private(set) var finished = false
    private var result: SpeechOutcome?
    private var waiters: [CheckedContinuation<SpeechOutcome, Never>] = []

    init(messageId: String) { self.messageId = messageId }

    func append(_ fullTextSoFar: String) { appended.append(fullTextSoFar) }
    func finish() { finished = true }

    var outcome: SpeechOutcome {
        get async {
            if let result { return result }
            return await withCheckedContinuation { waiters.append($0) }
        }
    }

    func resolve(_ outcome: SpeechOutcome) {
        guard result == nil else { return }
        result = outcome
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: outcome) }
    }
}

@MainActor final class FakeSpeaker: TalkSpeaking {
    private(set) var state: SpeechState = .idle
    private(set) var owner: SpeechOwner?
    var level = 0.5
    var isAudible: Bool { if case .speaking = state { true } else { false } }
    private(set) var sessions: [FakeSpeechSession] = []
    private(set) var stops = 0

    func open(messageId: String, profile: String?, client: any GatewayClient, owner: SpeechOwner, host: TalkPlaybackHost?) -> any SpeechSession {
        sessions.last?.resolve(.stopped)
        let session = FakeSpeechSession(messageId: messageId)
        sessions.append(session)
        state = .preparing(messageId)
        self.owner = owner
        post()
        return session
    }

    func stop() {
        stops += 1
        sessions.last?.resolve(.stopped)
        state = .idle
        owner = nil
        post()
    }

    /// The first audio leaves the speaker.
    func begin() {
        guard let session = sessions.last else { return }
        state = .speaking(session.messageId)
        post()
        session.onStarted?()
    }

    /// The reply finished playing (or failed).
    func complete(_ outcome: SpeechOutcome = .done) {
        guard let session = sessions.last else { return }
        state = .idle
        owner = nil
        post()
        session.resolve(outcome)
    }

    private func post() { NotificationCenter.default.post(name: .talkSpeechChanged, object: self) }
}
