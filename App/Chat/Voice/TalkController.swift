// One live voice conversation for the whole app (docs/spec/3x-talk.md §2.4, §4.2, §6): it feeds `TalkLoop` and performs
// what the loop asks (takes, transcription, the spoken turn, speech), keeps the elapsed clock, and keeps each chat's
// paused / stopped notice and "Voice chat ended" caption. The dock, the away pill and the composer read it and listen
// for `didChange`.
//
// Never two live microphones: starting here ends the conversation anywhere else first, and the new microphone is
// prepared only after the old one has shut down.

import AVFAudio
import UIKit

@MainActor final class TalkController {
    static let shared = TalkController()
    /// The conversation, a notice or an ended caption changed.
    static let didChange = Notification.Name("hq.talk.changed")
    /// The level moved (30 a second while listening or speaking): only the bars redraw.
    static let levelChanged = Notification.Name("hq.talk.level")
    /// [live words] The words heard so far changed (`words(in:)`).
    static let wordsChanged = Notification.Name("hq.talk.words")

    /// Why a start did not become a conversation (§5.7): shown in the card above the field.
    enum StartFailure: Equatable {
        case speechToTextOff
        case microphoneDenied
        case noMicrophone
        case engine(detail: String?)
        /// The app is not on screen (a start asked for from a notification or a shortcut that lost the screen).
        case notOnScreen
    }

    final class Conversation {
        let chat: any ChatVoiceTurns
        let name: String
        /// [gpt-live] the standard engine's microphone, or an inert stand-in while GPT-Live holds the real one
        var capture: any TalkCapturing
        let startedAt: TimeInterval
        var state: TalkLoopState
        var config = TalkConfig()
        var session: (any SpeechSession)?
        var level = 0.0
        /// A turn failed while the chat was off screen (the pill shows a warning instead of its dot).
        var problemAway = false
        /// The failure now in the dock's hint was on screen in front of the person (it is not news to the pill).
        var problemShown = false
        var lastRunning: Bool?
        var lastOpen: Bool?
        var replyTimer: Timer?
        // [gpt-live] (docs/spec/3x-gpt-live.md §4)
        var engine: TalkEngine = .standard
        var liveState = LiveTalkState()
        var transport: (any LiveVoiceTransport)?
        var lastTool: String?
        /// When GPT-Live took this conversation: replies dated earlier are the seed's, never passed on.
        var liveSince = Date()
        /// The standard engine's warm-up leases are held (given back when GPT-Live takes over).
        var leased = false
        // [live words] (docs/spec/3x-live-words.md)
        /// What heard each ended take that still waits for its words, by the take's file.
        var heard: [URL: any LiveWordsListening] = [:]
        /// The words above the dock: the take or barge-in being heard now, or GPT-Live's words for this turn.
        var words = LiveWordsText()
        /// Only the newest listener's words show.
        var wordsToken = 0

        init(chat: any ChatVoiceTurns, name: String, capture: any TalkCapturing, now: TimeInterval, speaksReplies: Bool, clock: TalkClock) {
            self.chat = chat
            self.name = name
            self.capture = capture
            startedAt = now
            state = TalkLoopState(now: now, speaksReplies: speaksReplies, clock: clock)
        }
    }

    /// A paused or stopped notice waiting in its chat, with what the away pill needs to lead back to it.
    struct Waiting {
        var notice: TalkNotice
        var scope: String
        var name: String
        var storedSessionId: String?
        var profile: String
        var at: TimeInterval
        weak var chat: (any ChatVoiceTurns)?
    }

    // What tests and the debug hooks swap.
    var makeCapture: @MainActor (TalkClock) -> any TalkCapturing = { TalkEngineCapture(clock: $0) }
    var speaker: any TalkSpeaking = TalkSpeaker.shared
    var clock = TalkClock()
    var now: @MainActor () -> TimeInterval = { CACurrentMediaTime() }
    var loadConfig: @MainActor (any ChatVoiceTurns) async -> TalkConfig = { chat in
        await VoiceGateway.config(client: chat.voiceClient, profile: chat.profile.isEmpty ? nil : chat.profile)
    }
    var transcribe: @MainActor (any ChatVoiceTurns, URL) async -> Result<String, VoiceFailure> = { chat, file in
        await VoiceGateway.transcribe(client: chat.voiceClient, file: file, mime: "audio/wav", profile: chat.profile.isEmpty ? nil : chat.profile)
    }
    var holdsLeases = true
    /// [live words] What hears a take as it's said (nil: nothing can; the gateway transcribes).
    var makeWords: @MainActor (@escaping @MainActor (LiveWordsText) -> Void) -> (any LiveWordsListening)? = { LiveWords.listen(onText: $0) }
    // [gpt-live] What tests and the debug hooks swap.
    var makeLiveTransport: @MainActor () -> any LiveVoiceTransport = { WebRTCLiveVoice() }
    // [grok-live] (docs/spec/3x-grok-live.md)
    var makeGrokTransport: @MainActor () -> any LiveVoiceTransport = { GrokLiveVoice() }
    var loadGrokStatus: @MainActor (any ChatVoiceTurns) async -> GrokLiveStatus? = { chat in
        await VoiceGateway.grokStatus(client: chat.voiceClient, profile: chat.profile.isEmpty ? nil : chat.profile)
    }
    /// The add-on's session answer (JSON text): the client secret, the socket's address, the voice and instructions.
    var openGrokSession: @MainActor (any ChatVoiceTurns) async throws -> String = { chat in
        try await VoiceGateway.grokSession(client: chat.voiceClient, profile: chat.profile.isEmpty ? nil : chat.profile)
    }
    var loadLiveStatus: @MainActor (any ChatVoiceTurns) async -> LiveVoiceStatus? = { chat in
        await VoiceGateway.liveStatus(client: chat.voiceClient, profile: chat.profile.isEmpty ? nil : chat.profile)
    }
    var exchangeLive: @MainActor (any ChatVoiceTurns, String, JSONValue) async throws -> String = { chat, sdp, history in
        try await VoiceGateway.liveSession(client: chat.voiceClient, profile: chat.profile.isEmpty ? nil : chat.profile, sdp: sdp, history: history)
    }
    /// The conversation's Speak Replies, read when a conversation starts and whenever the switch changes (rule 7).
    var speaksReplies: @MainActor () -> Bool = { TalkController.speaksInConversation }
    /// Voice works only while the app is on screen (§5.7).
    var isOnScreen: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
    /// A start that failed before a conversation existed: the chat's host shows the card.
    var onStartFailure: ((_ scope: String, _ failure: StartFailure, _ name: String) -> Void)?

    private(set) var live: Conversation?
    private var waiting: [String: Waiting] = [:]
    private var endedCaptions: [String: String] = [:]
    /// The chat whose screen is in front (set by its host).
    private(set) weak var front: (any ChatVoiceTurns)?
    private var ticker: Timer?
    private var shuttingDown: Task<Void, Never>?
    private var inputs: [Queued] = []
    /// [gpt-live] What waits for the loop: the shared inputs, or one only GPT-Live's reducer reads.
    private enum Queued { case standard(TalkLoopInput), live(LiveTalkInput) }
    private var draining = false
    private var observers: [any NSObjectProtocol] = []
    private var lastPublished: Published?
    /// Conversations ever started (the probe reads it).
    private(set) var started = 0

    private struct Published: Equatable {
        var view: TalkDockView?
        var muted: Bool
        var problem: String?
        var elapsed: Int
        var problemAway: Bool
    }

    /// The person's own choice; absent until they first switch it (T6).
    static let readRepliesAloudKey = "hq.voice.readRepliesAloud"
    /// The gateway's `voice.auto_tts` as last read: the default while there is no choice.
    static let readRepliesAloudGatewayKey = "hq.voice.readRepliesAloud.gateway"
    /// Posted when Read Replies Aloud is switched (the ⋯ menu, the voice options menu, the conversation bar and
    /// Settings show one state).
    static let readRepliesAloudChanged = Notification.Name("hq.voice.readRepliesAloud.changed")

    static var readsRepliesAloud: Bool {
        get {
            let defaults = UserDefaults.standard
            return TalkDockState.readsRepliesAloud(chosen: defaults.object(forKey: readRepliesAloudKey) as? Bool,
                                                   gateway: defaults.object(forKey: readRepliesAloudGatewayKey) as? Bool)
        }
        set {
            let was = readsRepliesAloud
            // Kept even when unchanged: switching it once, anywhere, is the choice that outranks the gateway.
            UserDefaults.standard.set(newValue, forKey: readRepliesAloudKey)
            guard newValue != was else { return }
            readRepliesAloudSwitched()
        }
    }

    /// The person has switched Read Replies Aloud at least once.
    static var readRepliesAloudChosen: Bool { UserDefaults.standard.object(forKey: readRepliesAloudKey) != nil }

    /// A bot's voice settings were read: `voice.auto_tts` becomes the default (the desktop's `applyAutoSpeakFromConfig`).
    /// It changes nothing once the person has chosen.
    static func gatewayVoiceRead(_ config: TalkConfig) {
        guard let auto = config.autoTTS else { return }
        let was = readsRepliesAloud
        UserDefaults.standard.set(auto, forKey: readRepliesAloudGatewayKey)
        guard readsRepliesAloud != was else { return }
        VoiceEvents.note("Read Replies Aloud follows the gateway: \(auto ? "on" : "off")")
        readRepliesAloudSwitched()
    }

    /// A voice conversation's own Speak Replies (the dock's Audio menu), apart from Read Replies Aloud. On until switched
    /// off: tester, 2026-11-08, "On voice chat, STT works but response is not read back", because a conversation
    /// followed Read Replies Aloud, off by default (T6), and its switch sat only in the speaker button's long press.
    static let conversationSpeaksKey = "hq.voice.conversationSpeaks"

    static var speaksInConversation: Bool {
        get { UserDefaults.standard.object(forKey: conversationSpeaksKey) as? Bool ?? true }
        set {
            guard newValue != speaksInConversation else { return }
            UserDefaults.standard.set(newValue, forKey: conversationSpeaksKey)
            readRepliesAloudSwitched()
        }
    }

    private static func readRepliesAloudSwitched() {
        if shared.live != nil { shared.send(.speaksReplies(shared.speaksReplies())) }
        NotificationCenter.default.post(name: readRepliesAloudChanged, object: nil)
    }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .talkSpeechChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.speakerChanged() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                self?.interrupted(.interrupted, detail: "interruption began" + (reason.map { " (reason \($0))" } ?? ""))
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                AudioSessionCoordinator.shared.reset()
                self?.interrupted(.interrupted, detail: "\(DeviceWord.system) reset its audio services")
            }
        })
        observers.append(center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appLeftScreen() }
        })
    }

    // MARK: Reading

    var isLive: Bool { live != nil }
    /// [mac] The live conversation's bot and whether its microphone is muted (Chat › Mute Talk, the Dock menu).
    var liveName: String? { live?.name }
    /// [live] The live conversation's chat, by stored id: its turn shows on the conversation's own Lock Screen card.
    var liveStoredSessionId: String? { live?.chat.storedSessionId }
    var isMuted: Bool { live?.state.muted ?? false }
    func isLive(in chat: (any ChatVoiceTurns)?) -> Bool { chat != nil && live?.chat === chat }
    var view: TalkDockView? { live.map { $0.state.view(name: $0.name) } }
    var elapsed: TimeInterval { live.map { now() - $0.startedAt } ?? 0 }
    var level: Double { live?.level ?? 0 }
    /// The live conversation's engine, for Read Aloud tapped during it (T13).
    var playbackHost: TalkPlaybackHost? { live?.capture.playbackHost }
    /// One turn's failure, shown as the dock's hint until the next state change (§6.4).
    var problem: String? { live?.state.problem }
    /// What Copy Details copies for that failure (its whole reason, scrubbed).
    var problemDetail: String? { live?.state.problem == nil ? nil : live?.state.problemDetail ?? live?.state.problem }
    /// What the bars follow: the microphone while listening, the speaker while the bot speaks.
    var visualLevel: Double {
        guard let live else { return 0 }
        #if DEBUG
        if let debugFixedLevel { return debugFixedLevel }
        #endif
        if live.engine.isLive { return live.state.status == .speaking ? live.transport?.speakerLevel ?? 0 : live.level }   // [gpt-live]
        return live.state.status == .speaking ? speaker.level : live.level
    }

    func notice(for scope: String) -> TalkNotice? { waiting[scope]?.notice }
    var waitingNotices: [Waiting] { waiting.values.sorted { $0.at < $1.at } }
    func endedCaption(for scope: String) -> String? { endedCaptions[scope] }
    /// [live words] What the person is saying now in this chat's conversation (empty: nothing to show).
    func words(in chat: (any ChatVoiceTurns)?) -> LiveWordsText {
        guard let live, chat != nil, live.chat === chat else { return LiveWordsText() }
        return live.words
    }

    // MARK: The away pill (§6.6)

    /// The newest notice waiting in a chat that is not the one in front.
    private var noticeAway: Waiting? {
        waitingNotices.last { entry in
            guard let front else { return true }
            return !(entry.chat === front || entry.scope == front.memoScope)
        }
    }

    /// What the pill shows: the live conversation while its chat is not in front, else a notice waiting elsewhere.
    var pillContent: TalkPillContent? {
        if let live {
            guard front !== live.chat else { return nil }
            let label = TalkDockState.pillLabel(name: live.name, status: live.state.status, muted: live.state.muted, elapsed: elapsed,
                                                problem: live.problemAway)
            return .live(label: label, problem: live.problemAway)
        }
        guard let entry = noticeAway else { return nil }
        return .notice(kind: entry.notice.kind, label: TalkDockState.pillLabel(notice: entry.notice, name: entry.name))
    }

    struct PillTarget {
        var chat: (any ChatVoiceTurns)?
        var storedSessionId: String?
        var profile: String
    }

    /// Where a tap on the pill leads.
    var pillTarget: PillTarget? {
        if let live, front !== live.chat {
            return PillTarget(chat: live.chat, storedSessionId: live.chat.storedSessionId, profile: live.chat.profile)
        }
        guard live == nil, let entry = noticeAway else { return nil }
        return PillTarget(chat: entry.chat, storedSessionId: entry.chat?.storedSessionId ?? entry.storedSessionId, profile: entry.profile)
    }

    // MARK: Start

    /// Starts a conversation in `chat` (the chat on screen). Whatever was live elsewhere ends first; every stale
    /// paused / stopped notice is cleared (an explicit start always begins clean).
    func start(in chat: any ChatVoiceTurns, name: String) {
        guard isOnScreen() else {
            VoiceEvents.note("conversation did not start: the app is not on screen")
            AppLog.note("talk", "failed to start \(AppLog.tag(chat.memoScope)): app not on screen")
            onStartFailure?(chat.memoScope, .notOnScreen, name)
            return
        }
        if let current = live { finish(current, .replaced) }
        waiting.removeAll()
        endedCaptions.removeAll()
        started += 1
        let conversation = Conversation(chat: chat, name: name, capture: makeCapture(clock), now: now(),
                                        speaksReplies: speaksReplies(), clock: clock)
        live = conversation
        chat.voiceHold = true
        chat.onVoiceChange = { [weak self, weak conversation] in
            guard let self, let conversation, self.live === conversation else { return }
            self.chatChanged(conversation)
        }
        wire(conversation)
        KeepAwake.hold(.conversation)
        chat.voiceClient.holdThroughBackground(true)   // [talk-background] the socket outlives leaving the app
        TalkActivity.shared.began(conversation.name, chat: chat, owner: self)   // [talk-background]
        if holdsLeases {
            conversation.leased = true
            VoiceGateway.lease(client: chat.voiceClient, kind: .tts, lease: .conversation, active: true, profile: chat.profile.isEmpty ? nil : chat.profile)
            VoiceGateway.lease(client: chat.voiceClient, kind: .stt, lease: .conversation, active: true, profile: chat.profile.isEmpty ? nil : chat.profile)
        }
        VoiceEvents.note("conversation started")
        AppLog.trace("talk", "started \(AppLog.tag(chat.memoScope))")
        startTicker()
        send(.start)
        chatChanged(conversation)
        let previous = shuttingDown
        Task { [weak self, weak conversation] in
            await previous?.value
            guard let self, let conversation, self.live === conversation else { return }
            let config = await self.loadConfig(conversation.chat)
            guard self.live === conversation else { return }
            Self.gatewayVoiceRead(config)
            // [grok-live] only ever this device's choice, and only when the add-on can open a session
            if Self.chosenEngine == .grokLive {
                let status = await self.loadGrokStatus(conversation.chat)
                guard self.live === conversation else { return }
                if Self.grokEngine(status: status) == .grokLive {
                    conversation.config = config
                    conversation.state.stopPhrases = config.stopPhrases
                    await self.startLive(conversation, engine: .grokLive)
                    return
                }
                VoiceEvents.note("Grok Live isn’t available here (\(status?.reason ?? "no answer")): the standard engine runs")
                await self.beginStandard(conversation, config: config)
                return
            }
            // [gpt-live] the engine: this device's choice, else the gateway's `voice.voice_chat_mode`
            if config.chatMode == .gptLive || Self.chosenEngine == .gptLive {
                let status = await self.loadLiveStatus(conversation.chat)
                guard self.live === conversation else { return }
                if Self.engine(config: config, status: status) == .gptLive {
                    conversation.config = config
                    conversation.state.stopPhrases = config.stopPhrases
                    await self.startLive(conversation, engine: .gptLive)
                    return
                }
                VoiceEvents.note("GPT-Live isn’t available here (\(status?.reason ?? "no answer")): the standard engine runs")
            }
            await self.beginStandard(conversation, config: config)
        }
        publish(force: true)
    }

    /// The standard engine's microphone: speech to text must be on, then the capture is prepared.
    private func beginStandard(_ conversation: Conversation, config: TalkConfig) async {
        guard config.sttEnabled else { failStart(conversation, .speechToTextOff); return }
        conversation.config = config
        conversation.state.bargeIn = config.bargeIn
        conversation.state.stopPhrases = config.stopPhrases
        do {
            try await conversation.capture.prepare()
        } catch {
            guard live === conversation else { return }
            switch error as? TalkCaptureError {
            case .denied: failStart(conversation, .microphoneDenied)
            case .noMicrophone: failStart(conversation, .noMicrophone)
            case .busy: failStart(conversation, .engine(detail: "Microphone is already in use by another app."))
            case .failed(let detail): failStart(conversation, .engine(detail: detail))
            case nil: failStart(conversation, .engine(detail: TalkEngineCapture.describe(error)))
            }
            return
        }
        guard live === conversation else { return }
        send(.micReady)
    }

    private func failStart(_ conversation: Conversation, _ failure: StartFailure) {
        let scope = conversation.chat.memoScope, name = conversation.name
        VoiceEvents.note("conversation did not start: \(failure)")
        AppLog.note("talk", "failed to start \(AppLog.tag(scope: scope)): \(failure)")
        finish(conversation, .gone)
        onStartFailure?(scope, failure, name)
    }

    private func wire(_ conversation: Conversation) {
        let capture = conversation.capture
        capture.onLevel = { [weak self, weak conversation] level in
            guard let self, let conversation, self.live === conversation else { return }
            conversation.level = level
            self.send(.level(level))
            NotificationCenter.default.post(name: Self.levelChanged, object: self)
        }
        capture.onTakeEnded = { [weak self, weak conversation] take in
            guard let self, let conversation, self.live === conversation else {
                TalkCaptureCore.discard(take.url)
                take.words?.cancel()
                return
            }
            if let words = take.words { conversation.heard[take.url] = words }   // [live words]
            self.send(.takeEnded(file: take.url, heardSpeech: take.heardSpeech, meterFailed: take.meterFailed, ms: take.ms))
        }
        capture.onBargeSpeech = { [weak self, weak conversation] in
            guard let self, let conversation, self.live === conversation else { return }
            // [live words] The interruption is heard from its first syllable (the capture hands over its pre-roll).
            if let words = self.listen(conversation) { conversation.capture.hearUtterance(words) }
            self.send(.bargeSpeech)
        }
        capture.onBargeUtterance = { [weak self, weak conversation] take in
            guard let self, let conversation, self.live === conversation else {
                if let take { TalkCaptureCore.discard(take.url) }
                take?.words?.cancel()
                return
            }
            if let take, let words = take.words { conversation.heard[take.url] = words }   // [live words]
            self.send(.bargeUtterance(file: take?.url))
        }
        capture.onEngineReplaced = { [weak self, weak conversation] in
            guard let self, let conversation, self.live === conversation else { return }
            self.speaker.rehost(conversation.capture.playbackHost)
        }
        capture.onInterrupted = { [weak self, weak conversation] cause, detail in
            guard let self, let conversation, self.live === conversation else { return }
            self.send(.interrupted(cause, detail: detail))
        }
    }

    // MARK: The person's controls

    func end() { send(.end) }
    func toggleMute() { send(.muteToggled) }

    /// The centre button: Send Now while listening, Stop while thinking, Interrupt while speaking.
    func centerTapped() {
        guard let view else { return }
        switch view.center {
        case .sendNow: send(.sendNow)
        case .stop, .interrupt: send(.stopOrInterrupt)
        case .spinner: break
        }
    }

    /// Another conversation, a memo or a dictation takes the microphone (§6.8). Returns once the microphone is free.
    func endForAnotherMicrophone() async {
        if let current = live { finish(current, .replaced) }
        await shuttingDown?.value
    }

    /// The chat went away (deleted, signed out).
    func chatGone(_ chat: any ChatVoiceTurns) {
        if let current = live, current.chat === chat { finish(current, .gone) }
        let scope = chat.memoScope
        if waiting[scope] != nil || endedCaptions[scope] != nil {
            waiting[scope] = nil
            endedCaptions[scope] = nil
            publish(force: true)
        }
    }

    /// Sign-out or a gateway switch: the conversation ends and every notice and caption goes with the account.
    func accountGone() {
        if let current = live { finish(current, .gone) }
        guard !waiting.isEmpty || !endedCaptions.isEmpty else { return }
        waiting.removeAll()
        endedCaptions.removeAll()
        publish(force: true)
    }

    /// A bare stop phrase typed while a conversation is live ends it and is not sent (§6.7).
    func interceptsTyped(text: String, attachments: Int) -> Bool {
        guard let live, TalkStopWord.interceptsTyped(active: true, text: text, attachments: attachments, config: live.state.stopPhrases) else { return false }
        finish(live, .said)
        return true
    }

    /// A bot's question took the dock's place, or left it (T12).
    func questionWaiting(_ waiting: Bool, in chat: (any ChatVoiceTurns)?) {
        guard isLive(in: chat) else { return }
        send(.questionWaiting(waiting))
    }

    /// Memo playback or Read Aloud started inside the conversation's session (T13).
    func otherAudioStarted() {
        guard live != nil else { return }
        send(.otherAudio(true))
    }

    func dismissNotice(scope: String) {
        guard waiting[scope] != nil else { return }
        waiting[scope] = nil
        publish(force: true)
    }

    func clearEndedCaption(scope: String) {
        guard endedCaptions[scope] != nil else { return }
        endedCaptions[scope] = nil
        publish(force: true)
    }

    /// The chat's screen came to the front, or left it.
    func setFront(_ chat: (any ChatVoiceTurns)?, onScreen: Bool) {
        if onScreen {
            front = chat
            if let live, live.chat === chat { live.problemAway = false }
        } else if front === chat {
            front = nil
        }
        publish(force: true)
    }

    // MARK: The loop

    private func send(_ input: TalkLoopInput) { enqueue(.standard(input)) }
    private func sendLive(_ input: LiveTalkInput) { enqueue(.live(input)) }

    private func enqueue(_ input: Queued) {
        inputs.append(input)
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !inputs.isEmpty {
            let next = inputs.removeFirst()
            guard let conversation = live else { cleanUp(next); continue }
            switch (conversation.engine, next) {
            case (.standard, .standard(let input)):
                let effects = TalkLoop.reduce(&conversation.state, input, now: now(), app: MemoNotice.appName)
                for effect in effects { perform(effect, in: conversation) }
            case (.gptLive, .standard(let input)), (.grokLive, .standard(let input)):
                cleanUp(next)
                guard let input = Self.liveInput(input) else { continue }
                performLive(LiveTalkLoop.reduce(&conversation.state, &conversation.liveState, input, now: now()), in: conversation)
            case (.gptLive, .live(let input)), (.grokLive, .live(let input)):
                performLive(LiveTalkLoop.reduce(&conversation.state, &conversation.liveState, input, now: now()), in: conversation)
            case (.standard, .live):
                continue
            }
        }
        publish(force: false)
    }

    // MARK: [live words] Words as the person speaks (docs/spec/3x-live-words.md)

    /// A listener for the next take or barge-in; its words replace what's shown. Nil when Live Words can't run (the
    /// gateway transcribes as before).
    private func listen(_ conversation: Conversation) -> (any LiveWordsListening)? {
        conversation.wordsToken += 1
        let token = conversation.wordsToken
        showWords(LiveWordsText(), in: conversation)
        return makeWords { [weak self, weak conversation] text in
            guard let self, let conversation, self.live === conversation, conversation.wordsToken == token else { return }
            self.showWords(text, in: conversation)
        }
    }

    private func showWords(_ text: LiveWordsText, in conversation: Conversation) {
        guard conversation.words != text else { return }
        conversation.words = text
        NotificationCenter.default.post(name: Self.wordsChanged, object: self)
    }

    /// Nothing more to show: the words were sent, or the take went.
    private func clearWords(_ conversation: Conversation) {
        conversation.wordsToken += 1
        showWords(LiveWordsText(), in: conversation)
    }

    /// [gpt-live] GPT-Live hears the person itself: its words for this turn show the same way, until the bot answers.
    private func liveWords(_ fragment: LiveTranscriptFragment, in conversation: Conversation) {
        guard LiveWords.isOn else { return }
        switch fragment.speaker {
        case .user: showWords(LiveWordsText(settled: conversation.words.settled + fragment.text), in: conversation)
        case .assistant: if !conversation.words.isEmpty { clearWords(conversation) }
        }
    }

    /// The take's words from this device; nil when nothing heard it, or it heard no words (the gateway transcribes).
    private static func phoneWords(_ heard: (any LiveWordsListening)?) async -> String? {
        guard let heard else { return nil }
        let asked = CACurrentMediaTime()
        let said = await heard.finish()
        guard !said.isEmpty else {
            VoiceEvents.note("this device heard no words: the gateway transcribes")
            return nil
        }
        VoiceEvents.note("words from this device in \(Int((CACurrentMediaTime() - asked) * 1000)) ms")
        return said
    }

    /// An input that arrives after the end still owns a file.
    private func cleanUp(_ input: Queued) {
        guard case .standard(let input) = input else { return }
        switch input {
        case .takeEnded(let file, _, _, _): TalkCaptureCore.discard(file)
        case .bargeUtterance(let file?): TalkCaptureCore.discard(file)
        default: break
        }
    }

    private func perform(_ effect: TalkLoopEffect, in conversation: Conversation) {
        let capture = conversation.capture
        switch effect {
        case .beginTake:
            // [live words] Takes the loop never asked words for (dropped as no speech or lost) let their listeners go.
            conversation.heard.values.forEach { $0.cancel() }
            conversation.heard = [:]
            capture.beginTake(silenceMs: conversation.config.silenceMs, words: listen(conversation))
        case .finishTake:
            capture.finishTake()
        case .cancelTake:
            capture.cancelTake()
            clearWords(conversation)   // [live words]
        case .transcribe(let file):
            let chat = conversation.chat, transcribe = self.transcribe
            let heard = conversation.heard.removeValue(forKey: file)   // [live words]
            Task { [weak self, weak conversation] in
                // [live words] This device's words, else the gateway's transcription.
                let result: Result<String, VoiceFailure>
                if let said = await Self.phoneWords(heard) { result = .success(said) } else { result = await transcribe(chat, file) }
                TalkCaptureCore.discard(file)
                guard let self, let conversation, self.live === conversation else { return }
                switch result {
                case .success(let words): self.send(.transcript(words))
                case .failure(let failure):
                    VoiceEvents.note("transcription failed: \(failure.reason)")
                    AppLog.note("talk", "transcription failed \(AppLog.tag(conversation.chat.memoScope))")
                    let plain = VoicePlainWords.plain(failure, .transcription)
                    self.send(.transcribeFailed(reason: plain.reason, detail: plain.detail))
                }
            }
        case .discard(let file):
            TalkCaptureCore.discard(file)
            conversation.heard.removeValue(forKey: file)?.cancel()   // [live words]
        case .submit(let text, let interrupted):
            clearWords(conversation)   // [live words] the words are the person's bubble now
            conversation.chat.sendSpoken(text, interrupted: interrupted)
            conversation.lastRunning = conversation.chat.isRunning
            send(.turnRunning(conversation.chat.isRunning))
        case .stopTurn:
            conversation.chat.stop()
        case .openSpeech(let messageId):
            let chat = conversation.chat
            let session = speaker.open(messageId: messageId, profile: chat.profile.isEmpty ? nil : chat.profile, client: chat.voiceClient,
                                       owner: .conversation, host: capture.playbackHost)
            conversation.session = session
            session.onStarted = { [weak self, weak conversation, weak session] in
                guard let self, let conversation, self.live === conversation, conversation.session === session else { return }
                self.send(.speechStarted)
            }
            Task { [weak self, weak conversation] in
                let outcome = await session.outcome
                guard let self, let conversation, self.live === conversation, conversation.session === session else { return }
                conversation.session = nil
                switch outcome {
                case .done: self.send(.speechFinished)
                case .failed(let reason, let fatal):
                    let plain = VoicePlainWords.plain(VoiceFailure(reason: reason, detail: nil), .speech)
                    self.send(.speechFailed(reason: plain.reason, fatal: fatal, detail: plain.detail))
                case .stopped: break
                }
            }
        case .feedSpeech(let text):
            conversation.session?.append(text)
        case .finishSpeech:
            conversation.session?.finish()
        case .stopSpeech:
            conversation.session = nil
            if speaker.owner == .conversation { speaker.stop() }
        case .armBarge:
            capture.armBarge(multiplier: conversation.config.bargeMultiplier, silenceMs: conversation.config.silenceMs)
            capture.setPlaying(speaker.isAudible && speaker.owner == .conversation)
        case .disarmBarge:
            capture.disarmBarge()
        case .haptic(let kind):
            Haptics.play(kind == .error ? .error : .warning)
        case .ended(let reason):
            tearDown(conversation, reason)
        }
    }

    /// Ends `conversation` from outside the loop's own rules.
    private func finish(_ conversation: Conversation, _ reason: TalkEnd) {
        guard live === conversation else { return }
        send(.finish(reason))
    }

    private func tearDown(_ conversation: Conversation, _ reason: TalkEnd) {
        guard live === conversation else { return }
        live = nil
        let chat = conversation.chat, scope = chat.memoScope
        let length = now() - conversation.startedAt
        conversation.replyTimer?.invalidate()
        chat.onVoiceChange = nil
        chat.onDelegationRefused = nil   // [gpt-live]
        chat.voiceHold = false
        ticker?.invalidate()
        ticker = nil
        conversation.session = nil
        if speaker.owner == .conversation { speaker.stop() }
        KeepAwake.release(.conversation)
        chat.voiceClient.holdThroughBackground(false)  // [talk-background]
        // A pause or a failure with the app away leaves the card saying so: no warning is felt in the background, and
        // the chat's notice is only seen later.
        TalkActivity.shared.ended(away: isOnScreen() ? nil : Self.lockScreenWords(reason))
        if conversation.leased {
            conversation.leased = false
            VoiceGateway.lease(client: chat.voiceClient, kind: .tts, lease: .conversation, active: false, profile: chat.profile.isEmpty ? nil : chat.profile)
            VoiceGateway.lease(client: chat.voiceClient, kind: .stt, lease: .conversation, active: false, profile: chat.profile.isEmpty ? nil : chat.profile)
        }
        conversation.heard.values.forEach { $0.cancel() }   // [live words]
        conversation.heard = [:]
        clearWords(conversation)
        let capture = conversation.capture
        let transport = conversation.transport   // [gpt-live] asks OpenAI to close, so the billed time stops
        conversation.transport = nil
        let previous = shuttingDown
        shuttingDown = Task {
            await previous?.value
            await transport?.close()
            await capture.shutDown()
        }
        switch reason {
        case .user, .said:
            // Posted only where the person can see it (§6.7, §6.8).
            if front === chat { endedCaptions[scope] = TalkDockState.endedCaption(elapsed: length) }
            VoiceEvents.note("conversation ended by the person after \(TalkDockState.formatElapsed(length))")
            AppLog.trace("talk", "stopped \(AppLog.tag(scope: scope)): ended by the person after \(Int(length))s")
        case .replaced:
            VoiceEvents.note("conversation ended: the microphone was needed elsewhere")
            AppLog.trace("talk", "stopped \(AppLog.tag(scope: scope)): microphone needed elsewhere")
        case .gone:
            VoiceEvents.note("conversation ended: its chat went away or it never started")
            AppLog.trace("talk", "stopped \(AppLog.tag(scope: scope)): chat went away or it never started")
        case .paused(let cause, let detail):
            let notice = TalkDockState.pausedNotice(cause, name: conversation.name, detail: detail, app: MemoNotice.appName)
            keep(notice, for: conversation, scope: scope)
            VoiceEvents.note("conversation paused: \(cause.rawValue)")
            AppLog.trace("talk", "interrupted \(AppLog.tag(scope: scope)): \(cause.rawValue)")
            Haptics.play(.warning)
        case .stopped(let title, let message, let detail):
            let notice = TalkDockState.stoppedNotice(title: title, message: message, detail: detail)
            keep(notice, for: conversation, scope: scope)
            VoiceEvents.note("conversation stopped: \(notice.message)")
            AppLog.note("talk", "failed \(AppLog.tag(scope: scope)): \(title)")
            Haptics.play(.error)
        }
        inputs.removeAll { input in
            cleanUp(input)
            return true
        }
        publish(force: true)
    }

    /// [talk-background] What an ended card on the Lock Screen says: only for an ending the person didn't ask for.
    nonisolated static func lockScreenWords(_ reason: TalkEnd) -> String? {
        switch reason {
        case .user, .said, .replaced, .gone: nil
        case .paused(let cause, _):
            switch cause {
            case .silence: "Paused after 2 minutes of silence"
            case .routeLost: "Paused: the headset disconnected"
            case .interrupted, .background: "Voice Paused"
            }
        case .stopped(let title, _, _): title.isEmpty ? "Voice Stopped" : title
        }
    }

    private func keep(_ notice: TalkNotice, for conversation: Conversation, scope: String) {
        let chat = conversation.chat
        waiting[scope] = Waiting(notice: notice, scope: scope, name: conversation.name, storedSessionId: chat.storedSessionId,
                                 profile: chat.profile, at: now(), chat: chat)
    }

    // MARK: What the conversation watches

    /// The chat changed (a delta, a turn starting or ending, the connection). Reply text is passed on at most ten
    /// times a second; a turn starting or ending and the connection go through at once.
    private func chatChanged(_ conversation: Conversation) {
        let chat = conversation.chat
        if !chat.allowsTalk { finish(conversation, .gone); return }
        if case .signedOut = chat.connection { finish(conversation, .gone); return }
        let running = chat.isRunning, open = chat.connection == .ready
        if open != conversation.lastOpen {
            conversation.lastOpen = open
            send(.connection(open: open))
        }
        if running != conversation.lastRunning {
            conversation.lastRunning = running
            conversation.replyTimer?.invalidate()
            conversation.replyTimer = nil
            send(.reply(chat.newestReply))
            send(.turnRunning(running))
            passOnReplies(conversation)
            return
        }
        if conversation.engine.isLive, chat.runningToolTitle != conversation.lastTool {   // [gpt-live]
            conversation.lastTool = chat.runningToolTitle
            sendLive(.tool(conversation.lastTool))
        }
        guard conversation.replyTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self, weak conversation] _ in
            MainActor.assumeIsolated {
                guard let self, let conversation, self.live === conversation else { return }
                conversation.replyTimer = nil
                self.send(.reply(conversation.chat.newestReply))
                self.passOnReplies(conversation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        conversation.replyTimer = timer
    }

    private func speakerChanged() {
        guard let live else { return }
        live.capture.setPlaying(speaker.isAudible && speaker.owner == .conversation)
        publish(force: false)
    }

    private func interrupted(_ cause: TalkPauseCause, detail: String?) {
        guard live != nil else { return }
        send(.interrupted(cause, detail: detail))
    }

    /// The app left the screen (lock, Home, the app switcher). [talk-background] A conversation goes on (the audio
    /// background mode keeps the app running; the Live Activity shows it on the Lock Screen and in the Dynamic Island).
    /// A call or Siri that paused it a moment before keeps its own notice: the web's rewrite to "left the screen"
    /// (`W:src/audio-lifecycle.ts`) would now blame a pause on leaving, which no longer pauses anything.
    private func appLeftScreen() {
        KeepAwake.appLeftScreen()
        if live != nil { VoiceEvents.note("conversation goes on with the app away") }
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.send(.tick) } }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func publish(force: Bool) {
        if let live {
            if live.state.problem == nil {
                live.problemShown = false
            } else if front === live.chat {
                live.problemShown = true
            } else if !live.problemShown {
                live.problemAway = true
            }
        }
        let next = Published(view: view, muted: live?.state.muted ?? false, problem: live?.state.problem, elapsed: Int(elapsed),
                             problemAway: live?.problemAway ?? false)
        guard force || next != lastPublished else { return }
        lastPublished = next
        TalkActivity.shared.update(view: next.view, muted: next.muted, storedSessionId: live?.chat.storedSessionId)   // [talk-background]
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    #if DEBUG
    private var debugFixedLevel: Double?

    /// Tests: everything forgotten, nothing running.
    func resetForTests() async {
        debugFixedLevel = nil
        if let live { finish(live, .gone) }
        await shuttingDown?.value
        shuttingDown = nil
        waiting.removeAll()
        endedCaptions.removeAll()
        front = nil
        inputs.removeAll()
    }

    /// The debug hooks raise a system event.
    func debugInterrupt(_ cause: TalkPauseCause, detail: String?) { interrupted(cause, detail: detail) }
    func debugLeaveScreen() { appLeftScreen() }
    /// Screenshots: a notice without the conversation that led to it.
    func debugKeep(_ notice: TalkNotice, chat: any ChatVoiceTurns, name: String) {
        let scope = chat.memoScope
        waiting[scope] = Waiting(notice: notice, scope: scope, name: name, storedSessionId: chat.storedSessionId, profile: chat.profile,
                                 at: now(), chat: chat)
        publish(force: true)
    }
    var debugState: TalkLoopState? { live?.state }

    /// Screenshots: the live conversation stops moving and shows exactly this state.
    func debugFreeze(_ change: (inout TalkLoopState) -> Void) {
        guard let live else { return }
        ticker?.invalidate()
        ticker = nil
        live.capture.onLevel = nil
        live.capture.onTakeEnded = nil
        live.capture.onBargeSpeech = nil
        live.capture.onBargeUtterance = nil
        live.chat.onVoiceChange = nil
        change(&live.state)
        publish(force: true)
    }

    /// Screenshots: a level for the bars of a frozen conversation.
    func debugLevel(_ level: Double) {
        debugFixedLevel = level
        NotificationCenter.default.post(name: Self.levelChanged, object: self)
    }

    /// Screenshots: a turn failed while the person was away.
    func debugProblemAway() {
        live?.problemAway = true
        publish(force: true)
    }

    /// Screenshots: the caption a finished conversation leaves.
    func debugEnded(scope: String, seconds: TimeInterval) {
        endedCaptions[scope] = TalkDockState.endedCaption(elapsed: seconds)
        publish(force: true)
    }

    /// What the probe element reports (`talk.debug`).
    var debugSnapshot: [String: Any] {
        [
            "status": live?.state.status.rawValue ?? "none",
            "muted": live?.state.muted ?? false,
            "conversations": live == nil ? 0 : 1,
            "engine": live?.engine.rawValue ?? "none",   // [gpt-live]
            "started": started,
            "notices": waiting.count,
            "problem": live?.state.problem ?? "",
            // The state's advice: the bar no longer shows it (VoiceOver hears it as the status's hint).
            "hint": view?.hint ?? "",
        ]
    }
    #endif
}

// MARK: - GPT-Live (docs/spec/3x-gpt-live.md §4)

extension TalkController {
    /// This device's engine choice (`hq.voice.engine`); nil follows the gateway's `voice.voice_chat_mode`.
    static let engineKey = "hq.voice.engine"
    static let engineChanged = Notification.Name("hq.voice.engine.changed")

    static var chosenEngine: TalkEngine? {
        get { UserDefaults.standard.string(forKey: engineKey).flatMap(TalkEngine.init(rawValue:)) }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: engineKey)
            NotificationCenter.default.post(name: engineChanged, object: nil)
        }
    }

    /// GPT-Live only when the gateway can start it (a key resolves); otherwise the standard engine. A device that chose
    /// Grok Live asks `grokEngine` instead.
    static func engine(config: TalkConfig?, status: LiveVoiceStatus?, chosen: TalkEngine? = chosenEngine) -> TalkEngine {
        guard status?.available == true, chosen != .grokLive else { return .standard }
        return chosen ?? config?.chatMode ?? .standard
    }

    /// [grok-live] Grok Live only when this device chose it and the add-on can open a session; no gateway default.
    static func grokEngine(status: GrokLiveStatus?, chosen: TalkEngine? = chosenEngine) -> TalkEngine {
        chosen == .grokLive && status?.available == true ? .grokLive : .standard
    }

    /// What the standard loop's inputs mean to GPT-Live's (nil: nothing).
    fileprivate static func liveInput(_ input: TalkLoopInput) -> LiveTalkInput? {
        switch input {
        case .start: .start
        case .micFailed(let title, let message, let detail): .sessionFailed(title: title, message: message, detail: detail)
        case .level(let level): .level(level)
        case .turnRunning(let running): .turnRunning(running)
        case .reply(let reply): .reply(reply)
        case .muteToggled: .muteToggled
        case .sendNow: .sendNow
        case .stopOrInterrupt: .stopOrInterrupt
        case .end: .end
        case .connection(let open): .connection(open: open)
        case .tick: .tick
        case .interrupted(let cause, let detail): .interrupted(cause, detail: detail)
        case .questionWaiting(let waiting): .questionWaiting(waiting)
        case .otherAudio(let playing): .otherAudio(playing)
        case .chatClosed: .finish(.gone)
        case .finish(let reason): .finish(reason)
        case .micReady, .takeEnded, .transcript, .transcribeFailed, .speechStarted, .speechFinished, .speechFailed, .bargeSpeech,
             .bargeUtterance, .speaksReplies:
            nil
        }
    }

    fileprivate func startLive(_ conversation: Conversation, engine: TalkEngine) async {
        let chat = conversation.chat
        conversation.engine = engine
        conversation.liveState = LiveTalkState(engine: engine)
        conversation.liveSince = Date()
        conversation.capture = LiveInertCapture()
        if conversation.leased {
            conversation.leased = false
            VoiceGateway.lease(client: chat.voiceClient, kind: .tts, lease: .conversation, active: false, profile: chat.profile.isEmpty ? nil : chat.profile)
            VoiceGateway.lease(client: chat.voiceClient, kind: .stt, lease: .conversation, active: false, profile: chat.profile.isEmpty ? nil : chat.profile)
        }
        VoiceEvents.note("conversation uses \(engine.title)")
        AppLog.trace("talk", "started \(AppLog.tag(chat.memoScope)): \(engine.title) engine")
        sendLive(.start)
        let transport = engine == .grokLive ? makeGrokTransport() : makeLiveTransport()
        conversation.transport = transport
        wireLive(conversation, transport)
        let history = LiveVoiceWire.history(chat.spokenHistory)
        let exchange = exchangeLive, openGrok = openGrokSession
        do {
            if engine == .grokLive {
                // [grok-live] no offer: the add-on's answer is the session (client secret, socket address, voice).
                try await transport.start(history: history) { _ in try await openGrok(chat) }
            } else {
                try await transport.start(history: history) { sdp in try await exchange(chat, sdp, history) }
            }
        } catch is CancellationError {
            return
        } catch {
            guard live === conversation else { return }
            switch error {
            // The standard engine needs the microphone too: nothing to fall back to.
            case LiveVoiceError.denied: failStart(conversation, .microphoneDenied)
            case LiveVoiceError.noMicrophone: failStart(conversation, .noMicrophone)
            case LiveVoiceError.refused(_, let detail): fallBack(conversation, reason: detail)
            case LiveVoiceError.failed(let detail): fallBack(conversation, reason: detail)
            case let failure as VoiceFailure: fallBack(conversation, reason: failure.reason)
            default: fallBack(conversation, reason: TalkEngineCapture.describe(error))
            }
        }
    }

    /// GPT-Live could not start, or went away without the person ending it: the same conversation goes on with the
    /// standard engine (a fresh loop, its own microphone and warm-up leases), once the live session has let go of the
    /// audio session.
    private func fallBack(_ conversation: Conversation, reason: String) {
        guard live === conversation, conversation.engine.isLive else { return }
        VoiceEvents.note("\(conversation.engine.title) stopped (\(VoiceReport.scrub(reason))): the standard engine takes over")
        AppLog.note("talk", "\(conversation.engine.title) failed \(AppLog.tag(conversation.chat.memoScope)): falling back to the standard engine")
        conversation.engine = .standard
        conversation.chat.onDelegationRefused = nil
        let transport = conversation.transport
        conversation.transport = nil
        Task { [weak self, weak conversation] in
            await transport?.close()
            guard let self, let conversation, self.live === conversation else { return }
            let chat = conversation.chat
            conversation.state = TalkLoopState(now: self.now(), speaksReplies: self.speaksReplies(), clock: self.clock)
            conversation.liveState = LiveTalkState()
            conversation.lastRunning = nil
            conversation.lastOpen = nil
            conversation.lastTool = nil
            conversation.capture = self.makeCapture(self.clock)
            self.wire(conversation)
            if self.holdsLeases, !conversation.leased {
                conversation.leased = true
                VoiceGateway.lease(client: chat.voiceClient, kind: .tts, lease: .conversation, active: true, profile: chat.profile.isEmpty ? nil : chat.profile)
                VoiceGateway.lease(client: chat.voiceClient, kind: .stt, lease: .conversation, active: true, profile: chat.profile.isEmpty ? nil : chat.profile)
            }
            self.send(.start)
            self.chatChanged(conversation)
            await self.beginStandard(conversation, config: conversation.config)
            // [grok-live stages] A setup xAI never confirmed is said in the dock, not only in the log.
            if reason == GrokLiveWire.setupTimeoutReason, self.live === conversation, !conversation.state.ended {
                Haptics.play(.warning)
                conversation.state.problem = TalkDockState.problemLine(reason, reason: "Using the standard voice instead")
                conversation.state.problemDetail = TalkDockState.problemDetail(reason, reason: "Using the standard voice instead", detail: nil)
                self.chatChanged(conversation)
            }
        }
    }

    /// [gpt-live] The chat's replies since the conversation began, for those nothing passed on yet (a turn the phone
    /// never saw running: Hermes answering another bot's message or a background job in the gateway).
    fileprivate func passOnReplies(_ conversation: Conversation) {
        guard conversation.engine.isLive else { return }
        sendLive(.recentReplies(conversation.chat.spokenReplies(since: conversation.liveSince)))
    }

    private func wireLive(_ conversation: Conversation, _ transport: any LiveVoiceTransport) {
        transport.onEvent = { [weak self, weak conversation] event in
            guard let self, let conversation, self.live === conversation else { return }
            switch event {
            case .started: self.sendLive(.sessionReady)
            case .transcript(let fragment):
                self.liveWords(fragment, in: conversation)   // [live words]
                self.sendLive(.transcript(fragment))
            case .delegation(let id): self.sendLive(.delegation(id: id))
            case .askAgent(let id, let request): self.sendLive(.askAgent(id: id, request: request))   // [grok-live]
            case .error(let message): self.sendLive(.vendorError(message))
            case .closed(let reason, let seconds): self.sendLive(.closed(reason: reason, usageSeconds: seconds))
            case .other: break
            }
        }
        transport.onDropped = { [weak self, weak conversation] why in
            guard let self, let conversation, self.live === conversation else { return }
            self.sendLive(.closed(reason: why, usageSeconds: nil))
        }
        transport.onMicLevel = { [weak self, weak conversation] level in
            guard let self, let conversation, self.live === conversation else { return }
            conversation.level = level
            self.sendLive(.level(level))
            NotificationCenter.default.post(name: Self.levelChanged, object: self)
        }
        transport.onSpeaking = { [weak self, weak conversation] speaking in
            guard let self, let conversation, self.live === conversation else { return }
            self.sendLive(.assistantSpeaking(speaking))
        }
        conversation.chat.onDelegationRefused = { [weak self, weak conversation] in
            guard let self, let conversation, self.live === conversation else { return }
            self.sendLive(.submitFailed)
        }
    }

    private func performLive(_ effects: [LiveTalkEffect], in conversation: Conversation) {
        for effect in effects {
            let transport = conversation.transport
            switch effect {
            case .submit(let text, let context):
                AppLog.trace("talk", "gpt-live request: \(text.split(separator: " ").count) words, context \(context.count) chars")
                conversation.chat.sendDelegated(text, voiceContext: context)
                conversation.lastRunning = conversation.chat.isRunning
                sendLive(.turnRunning(conversation.chat.isRunning))
            case .stopTurn:
                conversation.chat.stop()
            case .speak(let id, let text):
                AppLog.trace("talk", "\(conversation.engine.rawValue) says \(text.count) chars \(id == nil ? "as session news" : "for the request")")
                transport?.speak(delegationId: id, text: text)
            case .think(let id, let text):
                AppLog.trace("talk", text == LiveVoiceWire.noSpokenResult ? "\(conversation.engine.rawValue) told the request ended without words"
                             : "\(conversation.engine.rawValue) progress note")
                transport?.think(delegationId: id, text: text)
            case .instruct(let text):
                transport?.instruct(text)
            case .setMuted(let muted):
                transport?.setMuted(muted)
            case .closeSession:
                break   // `tearDown` closes it, after the end is recorded
            case .haptic(let kind):
                Haptics.play(kind == .error ? .error : .warning)
            case .ended(let reason):
                tearDown(conversation, reason)
            case .fallBack(let reason):
                fallBack(conversation, reason: reason)
            }
        }
    }
}
