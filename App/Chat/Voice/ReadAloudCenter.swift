// Read Aloud and Read Replies Aloud (docs/spec/3x-talk.md §7): all speech outside a live conversation. It speaks
// through the same `TalkSpeaking` the conversation uses (the stream first, clips as the fallback), under the
// `.speech` audio owner, so the silent switch does not mute it. One reply at a time; asking for another switches.

import UIKit

@MainActor final class ReadAloudCenter {
    static let shared = ReadAloudCenter()
    /// The state changed (object: the centre).
    static let didChange = Notification.Name("hq.read-aloud.changed")

    enum State: Equatable {
        case idle
        /// Asked for; no audio yet.
        case preparing(String)
        case speaking(String)

        var messageId: String? {
            switch self {
            case .idle: nil
            case .preparing(let id), .speaking(let id): id
            }
        }
    }

    /// What the action row's button shows for one reply (§7.1).
    enum Button: Equatable {
        case idle, preparing, speaking

        var label: String {
            switch self {
            case .idle: "Read Aloud"
            case .preparing: "Preparing audio"
            case .speaking: "Stop reading"
            }
        }
    }

    static let failureTitle = "Couldn’t Read Aloud"
    static let nothingToRead = "There’s nothing to read in this reply."
    static let unreachable = "\(HostWord.sentence) isn’t reachable right now. Try again when it reconnects."
    static let noAnswer = "The voice didn’t answer in time. Try again."
    static let conversationSpeaking = "The voice chat is speaking. Try again when it finishes."
    /// No audio this long after asking: the reading is given up (§7.6). Longer than the speaker's own wait before the
    /// iPhone's voice takes over from a silent computer (§7.7), so that voice always gets its turn first.
    static let answerTimeout: TimeInterval = VoiceWire.phoneVoiceAfter + 10

    // What tests swap.
    var speaker: any TalkSpeaking = TalkSpeaker.shared
    var holdsLeases = true
    var answerTimeout = ReadAloudCenter.answerTimeout
    var conversationLive: @MainActor () -> Bool = { TalkController.shared.isLive }
    /// The live conversation's engine: Read Aloud plays through it, so its voice processing keeps the reply out of the
    /// microphone (T13).
    var conversationHost: @MainActor () -> TalkPlaybackHost? = { TalkController.shared.playbackHost }
    /// A reading failed (or there was nothing to read): the chat on screen shows the alert.
    var onFailure: ((_ scope: String, _ failure: VoiceFailure) -> Void)?

    private struct Reading {
        var session: any SpeechSession
        var scope: String
        var auto: Bool
        var audible = false
    }

    private var reading: Reading?
    private var watchdog: Timer?
    private var observers: [any NSObjectProtocol] = []
    /// Readings ever started (the probe and tests read it).
    private(set) var started = 0

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .talkSpeechChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.speakerChanged() }
        })
        // Locking the phone or leaving the app stops the reading (§7.4, §10.1).
        observers.append(center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
                self?.away = true
                self?.applyLease()
            }
        })
        observers.append(center.addObserver(forName: UIScene.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.away = false
                self?.applyLease()
            }
        })
    }

    // MARK: Reading

    var state: State {
        #if DEBUG
        if let debugShown { return debugShown.state }
        #endif
        guard let reading else { return .idle }
        return reading.audible ? .speaking(reading.session.messageId) : .preparing(reading.session.messageId)
    }

    /// The chat the reading belongs to.
    var scope: String? {
        #if DEBUG
        if let debugShown { return debugShown.scope }
        #endif
        return reading?.scope
    }

    var level: Double {
        #if DEBUG
        if debugShown != nil { return 0.6 }
        #endif
        return speaker.level
    }

    func button(for messageId: String) -> Button {
        switch state {
        case .preparing(messageId): .preparing
        case .speaking(messageId): .speaking
        default: .idle
        }
    }

    /// The reply whose words are leaving the speaker now, whoever asked (Read Aloud, Read Replies Aloud, a
    /// conversation): the list marks it (§7.5).
    var spokenMessageId: String? {
        #if DEBUG
        if case .speaking(let id)? = debugShown?.state { return id }
        #endif
        if case .speaking(let id) = speaker.state { return id }
        return nil
    }

    // MARK: Asking

    /// The action row and the hold menu: this reply starts, stops, or takes over from another (T30).
    func toggle(messageId: String, markdown: String, in chat: any ChatVoiceTurns) {
        if state.messageId == messageId {
            stop()
        } else {
            read(messageId: messageId, markdown: markdown, in: chat, auto: false)
        }
    }

    /// Reads one reply. `auto`: Read Replies Aloud asked (a reply with nothing to say is skipped without an alert).
    @discardableResult
    func read(messageId: String, markdown: String, in chat: any ChatVoiceTurns, auto: Bool) -> Bool {
        let scope = chat.memoScope
        let conversation = conversationLive()
        if conversation {
            // Read Replies Aloud: a conversation speaks its own replies.
            guard !auto else { return false }
            // T13: Read Aloud tapped on a reply plays inside the conversation's session and the conversation mutes
            // itself. Never over the conversation's own voice: cutting it off would leave the conversation waiting on a
            // reply that never finishes playing.
            if speaker.owner == .conversation {
                onFailure?(scope, VoiceFailure(reason: Self.conversationSpeaking, detail: nil))
                return false
            }
        }
        guard !SpeechText.sanitizeForSpeech(markdown).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AppLog.trace("talk", "read aloud \(AppLog.tag(scope: scope)) skipped: nothing to read")
            if !auto { onFailure?(scope, VoiceFailure(reason: Self.nothingToRead, detail: nil)) }
            return false
        }
        guard chat.connection == .ready else {
            AppLog.note("talk", "read aloud \(AppLog.tag(scope: scope)) refused: gateway not ready")
            if !auto { onFailure?(scope, VoiceFailure(reason: Self.unreachable, detail: nil)) }
            return false
        }
        end(announce: false)
        started += 1
        let profile = chat.profile.isEmpty ? nil : chat.profile
        let session = speaker.open(messageId: messageId, profile: profile, client: chat.voiceClient, owner: auto ? .repliesAloud : .readAloud,
                                   host: conversation ? conversationHost() : nil)
        reading = Reading(session: session, scope: scope, auto: auto)
        VoiceEvents.note(auto ? "read replies aloud: reading the newest reply" : "read aloud: started")
        AppLog.trace("talk", "read aloud \(AppLog.tag(scope: scope)) started (\(auto ? "auto" : "asked"))")
        session.onStarted = { [weak self, weak session] in
            guard let self, let session, self.reading?.session === session else { return }
            self.reading?.audible = true
            self.watchdog?.invalidate()
            self.watchdog = nil
            self.publish()
        }
        session.append(markdown)
        session.finish()
        let asked = started
        let timer = Timer(timeInterval: answerTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.started == asked, self.reading?.audible == false else { return }
                VoiceEvents.note("read aloud: no audio after \(Int(self.answerTimeout)) s")
                AppLog.note("talk", "read aloud \(AppLog.tag(scope: scope)) gave up: no audio after \(Int(self.answerTimeout))s")
                self.end(announce: true)
                self.onFailure?(scope, VoiceFailure(reason: Self.noAnswer, detail: nil))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        Task { [weak self, weak session] in
            guard let session else { return }
            let outcome = await session.outcome
            guard let self, self.reading?.session === session else { return }
            self.finished(outcome, scope: scope)
        }
        publish()
        return true
    }

    private func finished(_ outcome: SpeechOutcome, scope: String) {
        clear()
        publish()
        switch outcome {
        case .failed(let reason, _):
            VoiceEvents.note("read aloud failed: \(reason)")
            AppLog.note("talk", "read aloud \(AppLog.tag(scope: scope)) failed: \(AppLog.scrub(reason))")
            onFailure?(scope, VoicePlainWords.plain(VoiceFailure(reason: reason, detail: nil), .speech))
        default:
            AppLog.trace("talk", "read aloud \(AppLog.tag(scope: scope)) finished")
        }
    }

    /// Stop on the strip, the action row, the hold menu; leaving the chat; a new message; the lock button.
    func stop() { end(announce: true) }

    /// Stops a reading that belongs to `scope` (its chat left the screen).
    func stop(scope: String) {
        guard reading?.scope == scope else { return }
        end(announce: true)
    }

    private func end(announce: Bool) {
        guard let reading else { return }
        AppLog.trace("talk", "read aloud \(AppLog.tag(scope: reading.scope)) stopped")
        clear()
        if speaker.owner == .readAloud || speaker.owner == .repliesAloud { speaker.stop() }
        if announce { publish() }
    }

    private func clear() {
        reading = nil
        watchdog?.invalidate()
        watchdog = nil
    }

    /// Something else took the speaker (a conversation started): the reading is over. Its own end arrives through
    /// its outcome.
    private func speakerChanged() {
        guard let reading, let owner = speaker.owner, owner != .readAloud, owner != .repliesAloud else { return }
        AppLog.trace("talk", "read aloud \(AppLog.tag(scope: reading.scope)) pre-empted")
        clear()
        publish()
    }

    private func publish() { NotificationCenter.default.post(name: Self.didChange, object: self) }

    // MARK: The warm-up lease (§3.5, §7.4)

    private var leased: (client: any GatewayClient, profile: String?, key: String)?
    private weak var shown: (any ChatVoiceTurns)?
    /// The app is in the background: nothing is kept warm there (a lease left held pins a local voice in the
    /// gateway's memory if the app is then closed).
    private var away = false

    /// Held while Read Replies Aloud is on and a chat is on screen. `chat` nil: nothing is on screen.
    func warmUp(for chat: (any ChatVoiceTurns)?) {
        shown = chat
        applyLease()
    }

    private func applyLease() {
        let wanted = TalkController.readsRepliesAloud && !away ? shown : nil
        let key = wanted.map { "\($0.voiceClient.account.id)|\($0.profile)" }
        guard key != leased?.key else { return }
        if let leased, holdsLeases {
            VoiceGateway.lease(client: leased.client, kind: .tts, lease: .readAloud, active: false, profile: leased.profile)
        }
        leased = nil
        if let wanted, let key {
            let profile = wanted.profile.isEmpty ? nil : wanted.profile
            if holdsLeases { VoiceGateway.lease(client: wanted.voiceClient, kind: .tts, lease: .readAloud, active: true, profile: profile) }
            leased = (wanted.voiceClient, profile, key)
        }
    }

    #if DEBUG
    private var debugShown: (state: State, scope: String)?

    func resetForTests() {
        end(announce: false)
        debugShown = nil
        leased = nil
        shown = nil
        away = false
        started = 0
    }

    /// Screenshots: a reading that stays as it is.
    func debugShow(_ state: State, scope: String) {
        debugShown = (state, scope)
        publish()
    }

    var debugSnapshot: [String: Any] {
        let name = switch state {
        case .idle: "idle"
        case .preparing: "preparing"
        case .speaking: "speaking"
        }
        return ["reading": name, "readingMessage": state.messageId ?? "", "readings": started]
    }
    #endif
}
