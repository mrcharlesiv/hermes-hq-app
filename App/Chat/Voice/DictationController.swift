// Dictation (docs/spec/3x-talk.md §8, row L541): "Dictate with Hermes" records the person, sends the take to the
// gateway's speech to text and types the words into the composer's field. Nothing is sent to the bot. One dictation
// app-wide; a conversation starting anywhere, the chat leaving the screen, the app leaving the screen or a phone call
// cancels it without a card. [live words] With Live Words on, the words show above the row as they are said and are
// the words typed: the gateway transcribes only when this device heard none (docs/spec/3x-live-words.md §3.3).

import AVFoundation
import UIKit

@MainActor final class DictationController {
    static let shared = DictationController()
    /// Started, stopped, or moved between phases (object: the controller).
    static let didChange = Notification.Name("hq.dictation.changed")
    /// The elapsed time and the meter, about 15 times a second while recording.
    static let levelChanged = Notification.Name("hq.dictation.level")
    /// [live words] The words heard so far changed (object: the controller).
    static let wordsChanged = Notification.Name("hq.dictation.words")

    nonisolated enum Phase: Equatable, Sendable { case idle, starting, recording, transcribing }

    // MARK: Words (`V:app/chat/composer/hooks/use-voice-recorder.ts`)

    /// Try Again starts a new dictation, as after a failed transcription: recording again is the next step.
    static let noSpeech = MemoNotice(tone: .warning, title: "No Speech Detected", message: "Try recording again.", action: .retryDictation)
    static let speechToTextOff = MemoNotice(
        tone: .warning, title: "Voice Unavailable",
        message: "Speech to Text is off on your gateway. Turn it on in Settings › Voice › Speech to Text, then try again.",
        action: .voiceSettings)

    static func microphoneOff(app: String = MemoNotice.appName) -> MemoNotice {
        MemoNotice(tone: .warning, title: "Microphone Access Is Off",
                   message: "Turn on Microphone for \(app) in \(PrivacySettingsLink.place) to dictate.", action: .openSettings)
    }

    static func recordingFailed(_ reason: String) -> MemoNotice {
        MemoNotice(tone: .error, title: "Voice Recording Failed", message: reason)
    }

    static func transcriptionFailed(_ raw: VoiceFailure) -> MemoNotice {
        let failure = VoicePlainWords.plain(raw, .transcription)
        return MemoNotice(tone: .error, title: "Voice Transcription Failed", message: failure.reason, detail: failure.detail, action: .retryDictation)
    }

    // MARK: What tests swap

    var makeRecorder: @MainActor () -> any DictationCapturing = { DictationRecorder() }
    var loadConfig: @MainActor (any ChatVoiceTurns) async -> TalkConfig = { chat in
        await VoiceGateway.config(client: chat.voiceClient, profile: chat.profile.isEmpty ? nil : chat.profile)
    }
    var transcribe: @MainActor (any ChatVoiceTurns, DictationTake) async -> Result<String, VoiceFailure> = { chat, take in
        await VoiceGateway.transcribe(client: chat.voiceClient, file: take.url, mime: take.mime, profile: chat.profile.isEmpty ? nil : chat.profile)
    }
    var holdsLeases = true
    /// [live words] What hears a take as it's recorded, and whether the microphone is tapped for it (as for memos).
    var makeWords: @MainActor (@escaping @MainActor (LiveWordsText) -> Void) -> (any LiveWordsListening)? = { LiveWords.listen(onText: $0) }
    var tapsMicrophone = true
    var isOnScreen: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
    var now: @MainActor () -> TimeInterval = { CACurrentMediaTime() }
    var haptics = true
    /// A card for the chat that dictated (the memo recorder's notice card shows it).
    var onNotice: @MainActor (_ scope: String, _ notice: MemoNotice) -> Void = { MemoController.shared.post($1, scope: $0) }
    /// Seconds counted per real second (the stress runs shorten the limit with it).
    var clockScale = 1.0

    private final class Take {
        let chat: any ChatVoiceTurns
        let recorder: any DictationCapturing
        let deliver: @MainActor (String) -> Void
        var phase = Phase.starting
        var limit = Double(TalkConfig().maxRecordingSeconds)
        var startedAt: TimeInterval?
        /// The length when recording stopped.
        var stoppedAt: TimeInterval?
        var leased = false
        /// The last seconds' warning was given (`secondsLeft`).
        var warned = false
        /// Still starting after `startingShownAfter`: the row shows "Starting…".
        var startingShown = false
        var file: URL?
        /// [live words] What hears the take, and the microphone tap that feeds it.
        var listener: (any LiveWordsListening)?
        var mic: LiveWordsMic?

        init(chat: any ChatVoiceTurns, recorder: any DictationCapturing, deliver: @escaping @MainActor (String) -> Void) {
            self.chat = chat
            self.recorder = recorder
            self.deliver = deliver
        }
    }

    private var take: Take?
    private var ticker: Timer?
    private var observers: [any NSObjectProtocol] = []
    /// Dictations ever started and words ever delivered (tests and the probe read them).
    private(set) var started = 0
    private(set) var delivered = 0
    private(set) var lastWords = ""
    /// [live words] The words heard so far, shown above the dictation row; once it stops, the words it will type.
    private(set) var words = LiveWordsText()
    /// Dictations whose words came from this device, not the gateway (tests read them).
    private(set) var heardHere = 0

    init() {
        let center = NotificationCenter.default
        // The app left the screen: the audio is thrown away, no card (§8).
        observers.append(center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording(why: "the app left the screen") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                self?.cancelRecording(why: "a call or Siri took the microphone")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording(why: "\(DeviceWord.system) reset its audio services") }
        })
    }

    // MARK: Reading

    var phase: Phase { take?.phase ?? .idle }
    var isActive: Bool { take != nil }
    func isActive(in chat: (any ChatVoiceTurns)?) -> Bool { chat != nil && take?.chat === chat }
    /// The limit of the dictation that runs, in seconds.
    var limit: Double { take?.limit ?? 0 }

    /// Seconds recorded so far (it stands still while the words are fetched).
    var elapsed: TimeInterval {
        guard let take, let startedAt = take.startedAt else { return 0 }
        return max(0, ((take.stoppedAt ?? now()) - startedAt) * clockScale)
    }

    var level: Double { take?.phase == .recording ? take?.recorder.level ?? 0 : 0 }

    /// A start that takes a while (the voice settings read from a slow gateway, nothing saved yet) shows the row as
    /// "Starting…" after this long: nothing showed at all, and tapping again did nothing. A quick start never flashes it.
    static let startingShownAfter: Duration = .milliseconds(400)
    var startingShown: Bool { take?.startingShown ?? false }

    /// [live words] This device listens to the take: the composer's words row opens at once ("Listening…").
    var hearsWords: Bool { take?.listener != nil }

    /// "0:07".
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.isFinite ? seconds : 0))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    /// What VoiceOver reads for the row.
    nonisolated static func spoken(phase: Phase, elapsed: TimeInterval, limit: Double = 0) -> String {
        if phase == .transcribing { return "Transcribing" }
        if phase == .starting { return "Starting dictation" }
        guard let left = secondsLeft(elapsed: elapsed, limit: limit) else { return "Dictating, \(clock(elapsed))" }
        return "Dictating, \(clock(elapsed)), \(left) \(left == 1 ? "second" : "seconds") left"
    }

    /// The last seconds before the limit (ten, or half of a shorter limit), whole and rounded up; nil before them. The
    /// row counts them down and a warning is felt once: it stopped at 2:00 with no warning at all.
    nonisolated static func secondsLeft(elapsed: TimeInterval, limit: Double) -> Int? {
        guard limit > 0, elapsed.isFinite else { return nil }
        let left = limit - elapsed
        guard left > 0, left <= min(10, limit / 2) else { return nil }
        return Int(left.rounded(.up))
    }

    // MARK: Asking

    /// "Dictate with Hermes". `deliver` gets the words (trimmed, never empty) when they arrive.
    func start(in chat: any ChatVoiceTurns, deliver: @escaping @MainActor (String) -> Void) {
        guard take == nil else { return }
        guard isOnScreen() else {
            VoiceEvents.note("dictation did not start: the app is not on screen")
            AppLog.note("talk", "dictation \(AppLog.tag(chat.memoScope)) refused: app not on screen")
            return
        }
        let take = Take(chat: chat, recorder: makeRecorder(), deliver: deliver)
        self.take = take
        started += 1
        KeepAwake.hold(.dictation)
        VoiceEvents.note("dictation: starting")
        AppLog.trace("talk", "dictation \(AppLog.tag(chat.memoScope)) starting")
        publish()
        Task { [weak self] in await self?.begin(take) }
        Task { [weak self, weak take] in
            try? await Task.sleep(for: Self.startingShownAfter)
            guard let self, let take, self.take === take, take.phase == .starting else { return }
            take.startingShown = true
            self.publish()
        }
    }

    private func begin(_ take: Take) async {
        let config = await loadConfig(take.chat)
        guard self.take === take else { return }
        guard config.sttEnabled else {
            fail(take, Self.speechToTextOff, why: "Speech to Text is off")
            return
        }
        take.limit = Double(config.maxRecordingSeconds)
        do {
            // The microphone prompt, then the audio session. A conversation that holds it ends first (§2.4).
            try await take.recorder.begin()
        } catch {
            guard self.take === take else { return }
            switch error as? DictationCaptureError {
            case .denied: fail(take, Self.microphoneOff(), why: "microphone access is off")
            case .cancelled: close(take)
            case .failed(let reason): fail(take, Self.recordingFailed(reason), why: reason)
            case nil: fail(take, Self.recordingFailed(error.localizedDescription), why: error.localizedDescription)
            }
            return
        }
        guard self.take === take else {
            take.recorder.cancel()
            return
        }
        guard isOnScreen() else {
            cancel(why: "the app left the screen while it started")
            return
        }
        take.phase = .recording
        take.startedAt = now()
        startWords(take)   // [live words]
        if holdsLeases {
            take.leased = true
            VoiceGateway.lease(client: take.chat.voiceClient, kind: .stt, lease: .voiceInput, active: true, profile: take.chat.profile.isEmpty ? nil : take.chat.profile)
        }
        if haptics { Haptics.play(.selection) }
        VoiceEvents.note("dictation: recording (limit \(Int(take.limit)) s)")
        AppLog.trace("talk", "dictation \(AppLog.tag(take.chat.memoScope)) recording (limit \(Int(take.limit))s)")
        startTicker()
        publish()
    }

    /// Stop on the circle, Done on the row, or the limit: the words are fetched.
    func done() {
        guard let take else { return }
        switch take.phase {
        case .starting:
            cancel(why: "stopped before it started")
        case .recording:
            take.phase = .transcribing
            take.stoppedAt = now()
            stopMic(take)   // [live words] nothing said after Stop belongs to it
            stopTicker()
            publish()
            Task { [weak self] in await self?.finish(take) }
        case .transcribing, .idle:
            break
        }
    }

    private func finish(_ take: Take) async {
        // [live words] The words settle while the file closes (a moment at most).
        let heard = take.listener
        let settling = Task { await Self.settledWords(heard) }
        let recorded = await take.recorder.finish()
        let said = await settling.value
        guard self.take === take else {
            if let recorded { TalkCaptureCore.discard(recorded.url) }
            return
        }
        take.listener = nil
        if let recorded { take.file = recorded.url }
        let result: Result<String, VoiceFailure>
        if let said {
            // The words on screen are the words typed: no gateway speech to text.
            heardHere += 1
            VoiceEvents.note("dictation: words from this device")
            AppLog.trace("talk", "dictation \(AppLog.tag(take.chat.memoScope)): words from this device")
            result = .success(said)
        } else {
            guard let recorded else {
                fail(take, Self.recordingFailed("Nothing was recorded."), why: "nothing was recorded")
                return
            }
            VoiceEvents.note("dictation: transcribing \(Int(recorded.seconds.rounded())) s\(heard == nil ? "" : " (this device heard no words)")")
            AppLog.trace("talk", "dictation \(AppLog.tag(take.chat.memoScope)) transcribing \(Int(recorded.seconds.rounded()))s")
            result = await transcribe(take.chat, recorded)
            // Cancelled while the words were on their way: they are dropped, and `close` already deleted the file.
            guard self.take === take else { return }
        }
        let scope = take.chat.memoScope
        close(take)
        switch result {
        case .success(let words):
            let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                VoiceEvents.note("dictation: no speech detected")
                AppLog.trace("talk", "dictation \(AppLog.tag(scope: scope)): no speech detected")
                if haptics { Haptics.play(.warning) }
                onNotice(scope, Self.noSpeech)
            } else {
                VoiceEvents.note("dictation: \(trimmed.count) characters typed")
                AppLog.trace("talk", "dictation \(AppLog.tag(scope: scope)): \(trimmed.count) characters typed")
                delivered += 1
                lastWords = trimmed
                take.deliver(trimmed)
                if haptics { Haptics.play(.success) }
            }
        case .failure(let failure):
            VoiceEvents.note("dictation: transcription failed: \(failure.reason)")
            AppLog.note("talk", "dictation \(AppLog.tag(scope: scope)) transcription failed: \(AppLog.scrub(failure.reason))")
            if haptics { Haptics.play(.error) }
            onNotice(scope, Self.transcriptionFailed(failure))
        }
    }

    /// ✕ on the row, and everything that takes the microphone or the screen away: the audio is thrown away and nothing
    /// is typed. No card.
    func cancel() { cancel(why: "cancelled") }

    /// Cancels a dictation that belongs to `chat` (its screen left, a question took the composer's place).
    func cancel(in chat: (any ChatVoiceTurns)?) {
        guard isActive(in: chat) else { return }
        cancel(why: "its chat gave up the composer")
    }

    /// A call, Siri, the audio services or the app leaving: a take still starting or recording is thrown away (§8).
    /// One that is Transcribing has finished with the microphone, and the words the person asked for (Done) were thrown
    /// away with no card: it goes on, and its words land in the field (or its card says why) when they come back.
    private func cancelRecording(why: String) {
        if let take, take.phase == .transcribing {
            VoiceEvents.note("dictation kept: \(why) after it finished recording")
            AppLog.trace("talk", "dictation \(AppLog.tag(take.chat.memoScope)) kept: \(AppLog.scrub(why)) while transcribing")
            return
        }
        cancel(why: why)
    }

    private func cancel(why: String) {
        guard let take else { return }
        VoiceEvents.note("dictation cancelled: \(why)")
        AppLog.trace("talk", "dictation \(AppLog.tag(take.chat.memoScope)) cancelled: \(AppLog.scrub(why))")
        take.recorder.cancel()
        close(take)
    }

    private func fail(_ take: Take, _ notice: MemoNotice, why: String) {
        VoiceEvents.note("dictation stopped: \(why)")
        AppLog.note("talk", "dictation \(AppLog.tag(take.chat.memoScope)) failed to start: \(AppLog.scrub(why))")
        let scope = take.chat.memoScope
        take.recorder.cancel()
        close(take)
        if haptics { Haptics.play(notice.tone == .error ? .error : .warning) }
        onNotice(scope, notice)
    }

    /// Always at the end: the lease, the screen lock, the ticker and the take's file.
    private func close(_ take: Take) {
        guard self.take === take else { return }
        self.take = nil
        stopTicker()
        dropWords(take)   // [live words]
        if take.leased { VoiceGateway.lease(client: take.chat.voiceClient, kind: .stt, lease: .voiceInput, active: false, profile: take.chat.profile.isEmpty ? nil : take.chat.profile) }
        KeepAwake.release(.dictation)
        if let file = take.file { TalkCaptureCore.discard(file) }
        publish()
    }

    // MARK: [live words] Words as the take is recorded (docs/spec/3x-live-words.md §3.3)

    /// A listener and its microphone tap for the take that just started recording (nothing when Live Words can't run:
    /// the gateway transcribes it then).
    private func startWords(_ take: Take) {
        guard let listener = makeWords({ [weak self, weak take] text in
            guard let self, let take, self.take === take, take.listener != nil else { return }
            self.words = text
            NotificationCenter.default.post(name: Self.wordsChanged, object: self)
        }) else { return }
        take.listener = listener
        NotificationCenter.default.post(name: Self.wordsChanged, object: self)
        guard tapsMicrophone else { return }
        #if DEBUG
        if LiveWords.debugScript != nil { return }   // the stand-in hears its script without a microphone
        #endif
        let mic = LiveWordsMic()
        take.mic = mic
        #if DEBUG
        if let file = LiveWords.debugFile {
            AudioWork.later { _ = mic.start(file: file, listener) }
            return
        }
        #endif
        AudioWork.later {
            // A tap that won't start only means no words: the listener settles on none and the gateway transcribes.
            if !mic.start(listener) { VoiceEvents.noteLater("dictation words: the microphone tap didn’t start") }
        }
    }

    private func stopMic(_ take: Take) {
        guard let mic = take.mic else { return }
        take.mic = nil
        AudioWork.later { mic.stop() }
    }

    /// The take is over: its listener (if still held) is cancelled and the words row clears.
    private func dropWords(_ take: Take) {
        stopMic(take)
        take.listener?.cancel()
        take.listener = nil
        guard !words.isEmpty else { return }
        words = LiveWordsText()
        NotificationCenter.default.post(name: Self.wordsChanged, object: self)
    }

    /// What `heard` settled on (nil: nothing heard it, or no words; the gateway transcribes then).
    private nonisolated static func settledWords(_ heard: (any LiveWordsListening)?) async -> String? {
        guard let heard else { return nil }
        let said = await heard.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? nil : said
    }

    // MARK: The clock

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let take, take.phase == .recording else { return }
        if elapsed >= take.limit {
            VoiceEvents.note("dictation: reached the \(Int(take.limit)) s limit")
            done()
            return
        }
        if !take.warned, let left = Self.secondsLeft(elapsed: elapsed, limit: take.limit) {
            take.warned = true
            VoiceEvents.note("dictation: \(left) s before the limit")
            if haptics { Haptics.play(.warning) }
            HQAnnounce.say("\(left) seconds left")
        }
        NotificationCenter.default.post(name: Self.levelChanged, object: self)
    }

    private func publish() { NotificationCenter.default.post(name: Self.didChange, object: self) }

    // MARK: Tests and screenshots

    #if DEBUG
    func resetForTests() {
        cancel(why: "reset")
        started = 0
        delivered = 0
        heardHere = 0
        lastWords = ""
        clockScale = 1
    }

    var debugSnapshot: [String: Any] {
        let name = switch phase {
        case .idle: "idle"
        case .starting: "starting"
        case .recording: "recording"
        case .transcribing: "transcribing"
        }
        return ["dictation": name, "dictations": started, "dictated": delivered, "dictationWords": lastWords,
                "dictationLimit": Int(limit)]
    }
    #endif
}
