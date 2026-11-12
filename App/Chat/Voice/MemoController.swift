// Runs the memo gesture reducer (`MemoGesture`) against the recorder (spec 1x-voice §3.2; a port of
// W:src/ui-voice/memo-live.ts): one take at a time app-wide. The take's chat is frozen at touch-down (C3): a send goes
// only through that chat while its screen still shows, anything else keeps the memo as a draft chip there, with a
// notice that says so. Haptics follow the code: light on recording and lock, rigid crossing into cancel; a send is
// silent.

import UIKit
import os

/// Where a take goes, fixed at touch-down.
struct MemoTarget {
    /// The chat's layout scope (the draft store's key).
    let scope: String
    weak var host: ChatVoiceHost?
    weak var session: (any ChatVoiceMemos)?
    /// "Ivy", for the words on screen.
    let botName: String
    let accountKey: String
}

/// A notice on the memo card (spec §3.7): stays until closed, acted on, or its chat is left.
struct MemoNotice: Equatable {
    enum Tone: Equatable { case warning, error, info }
    enum Action: Equatable { case openSettings, retry, retryTalk, voiceSettings, retryDictation }   // [talk] the last three (3x-talk §5.7, §8)
    var tone: Tone
    var title: String
    var message: String
    var detail: String? = nil
    var action: Action? = nil
    /// "Memo Saved as a Draft": sending a memo from that chat deals with it, so the card goes then.
    var draft = false

    /// Whether the card offers Copy: not on a microphone-permission notice, which has nothing technical to copy.
    var copies: Bool { detail != nil || action != .openSettings }

    var actionTitle: String? {
        switch action {
        case .openSettings: PrivacySettingsLink.openTitle   // [mac] Mac polish #11: "Open System Settings" on the Mac
        case .retry, .retryTalk, .retryDictation: "Try Again"
        case .voiceSettings: "Voice Settings…"
        case nil: nil
        }
    }

    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? AppIdentity.current.displayName
    }

    /// `memo-live.ts:294-300`.
    static func why(_ reason: MemoStopReason) -> String {
        switch reason {
        case .interrupted: "A call or Siri took the microphone."
        case .background: "\(appName) left the screen."
        case .routeLost: "The headset or microphone disconnected."
        case .reset: "\(DeviceWord.system) reset its audio."
        case .error, .limit, .cancel: "The recording stopped unexpectedly."
        }
    }

    /// A memo that couldn't go out waits in its chat's composer (`memo-live.ts:174-177`).
    /// `detail`: why it didn't send (a group chat's upload or refusal), when known.
    static func savedAsDraft(bot: String, detail: String? = nil) -> MemoNotice {
        MemoNotice(tone: .warning, title: "Memo Saved as a Draft",
                   message: "It didn’t send. It’s waiting in the message field of your chat with \(bot).", detail: detail, draft: true)
    }

    /// The memo still went, without its transcript (spec §3.7); `bot` is the chat's bot.
    static func noTranscript(bot: String, detail: String?) -> MemoNotice {
        MemoNotice(tone: .warning, title: "No Transcript for This Voice Memo",
                   message: "Transcription failed. The memo is still attached and plays in the chat; \(bot) gets it without the text.",
                   detail: detail)
    }

    /// Why a take couldn't begin (`failureNotice`, with V11's wording).
    static func failure(code: String, message: String?) -> MemoNotice {
        switch code {
        case "permission-denied":
            return MemoNotice(tone: .warning, title: "Microphone Access Is Off",
                              message: "Turn on Microphone for \(appName) in \(PrivacySettingsLink.place) to record voice memos.", action: .openSettings)
        case "background":
            return MemoNotice(tone: .info, title: "Couldn’t Record", message: "Voice memos record while \(appName) is on screen.")
        default:
            return MemoNotice(tone: .error, title: "Couldn’t Record", message: message ?? "The microphone didn’t start. Try again.",
                              action: .retry)
        }
    }
}

@MainActor final class MemoController {
    static let shared = MemoController()
    /// Posted when a chat's notices change (userInfo `scope`).
    static let noticesChanged = Notification.Name("hq.memo.notices.changed")
    static let sendOnReleaseKey = "hq.voice.sendOnRelease"

    var capture: any MemoCapturing {
        didSet { wireCapture() }
    }
    private(set) var state = MemoGestureState.idle
    private(set) var target: MemoTarget?
    private(set) var takeId: String?
    private(set) var limit: Double = 600
    /// The take in review.
    private(set) var file: MemoFile?
    private(set) var level: Double = 0
    /// One level per 100 ms of the take (the live waveform), newest last; the newest 600 are kept.
    private(set) var levels: [Double] = []
    /// How many 100 ms samples the take has had (`levels` keeps only the newest 600 of them).
    private var levelSamples = 0
    private var generation = 0
    /// A-P1 on a device: "memo send" runs from the release to the optimistic bubble (Instruments › os_signpost).
    private var sendInterval: OSSignpostIntervalState?
    private var notices: [String: MemoNotice] = [:]
    private var keyboardWasUp = false
    /// The phase the recorder showed last (an `ending` from `locked` keeps the locked row, disabled).
    private(set) var shownPhase: MemoPhase = .idle
    // [live words] (docs/spec/3x-live-words.md)
    /// What hears the take as it's recorded, and the microphone tap that feeds it.
    private var listener: (any LiveWordsListening)?
    private var mic: LiveWordsMic?
    private var wordsToken = 0
    /// The words heard so far, shown above the recorder; in review, the words the memo will carry.
    private(set) var words = LiveWordsText()
    /// What the take in review settled on before any fix: a fix sent is learned from it (`WordFixes.learn`).
    private var reviewHeard: String?
    /// For the take's log line: when its listening started, and how long its first words took.
    private var wordsStartedAt = ContinuousClock.now
    private var firstWordsMs: Int?
    /// This device is listening to the take (Live Words runs for it): the composer's words row opens at once.
    var hearsWords: Bool { listener != nil }
    /// What hears a take as it’s recorded (tests swap it), and whether the microphone is tapped for it.
    var makeWords: @MainActor (@escaping @MainActor (LiveWordsText) -> Void) -> (any LiveWordsListening)? = { LiveWords.listen(onText: $0) }
    var tapsMicrophone = true

    /// Send Memo on Release (V12): on unless Settings turned it off.
    var sendOnRelease: Bool {
        #if DEBUG
        if let debug = Self.debugSendOnRelease { return debug }
        #endif
        return UserDefaults.standard.object(forKey: Self.sendOnReleaseKey) as? Bool ?? true
    }
    #if DEBUG
    /// `-HQDebugSendOnRelease NO` (this launch only).
    static var debugSendOnRelease: Bool?
    #endif

    init(capture: any MemoCapturing = MemoRecorder.shared) {
        self.capture = capture
        wireCapture()
        // A chat's own memo notices (a transcript that failed, memos still queued when the chat was left) are kept by
        // scope here, so they show when that chat is on screen, now or when it opens next.
        sessionNotices = NotificationCenter.default.addObserver(forName: MemoSessionNotice.post, object: nil, queue: .main) { [weak self] note in
            let info = MemoSessionNotice.Info(note)
            MainActor.assumeIsolated { self?.sessionNotice(info) }
        }
    }

    private var sessionNotices: NSObjectProtocol?

    isolated deinit {
        if let sessionNotices { NotificationCenter.default.removeObserver(sessionNotices) }
    }

    private func sessionNotice(_ info: MemoSessionNotice.Info?) {
        guard let info else { return }
        switch info.kind {
        case .savedAsDraft: announce(MemoNotice.savedAsDraft(bot: info.bot ?? "Hermes", detail: info.detail), scope: info.scope)
        case .noTranscript: announce(MemoNotice.noTranscript(bot: info.bot ?? "Hermes", detail: info.detail), scope: info.scope)
        }
    }

    private func wireCapture() {
        capture.onEvent = { [weak self] event in self?.captured(event) }
    }

    private var now: Double { CACurrentMediaTime() * 1000 }

    func isTarget(_ host: ChatVoiceHost) -> Bool { target?.host === host }

    /// The recorder is showing for `host` (anything but idle).
    func isActive(for host: ChatVoiceHost) -> Bool { state.phase != .idle && isTarget(host) }

    // MARK: Touches

    /// A touch on a mic (or VoiceOver's double-tap, `a11y`), with where the take is going. A touch while another take
    /// runs is ignored; a take whose chat can't be reached any more becomes a draft there first.
    func memoDown(_ target: MemoTarget, width: Double, a11y: Bool = false, keyboardUp: Bool = false) {
        if state.phase != .idle {
            if state.phase != .ending, self.target?.host?.isOnScreen != true { input(.leave) }
            return
        }
        self.target = target
        file = nil
        words = LiveWordsText()   // [live words]
        reviewHeard = nil
        levels = []
        levelSamples = 0
        level = 0
        keyboardWasUp = keyboardUp
        Haptics.prepare(.light)
        Haptics.prepare(.rigid)
        input(a11y ? .a11yOpen(at: now) : .down(at: now, width: width))
    }

    func input(_ input: MemoInput) {
        let before = state
        let shownBefore = shownPhase
        let (next, effects) = MemoGesture.reduce(state, input, sendOnRelease: sendOnRelease)
        state = next
        if next.phase != .ending { shownPhase = next.phase }
        if next.phase == .idle && before.phase != .idle { settle() }
        // A finger's move (60–120 Hz) or the clock's tick within one phase only redraws the recorder's row and circle;
        // the screen re-lays out only when the phase changes.
        if next.phase == before.phase && shownPhase == shownBefore {
            target?.host?.memoLevelChanged()
        } else {
            target?.host?.memoStateChanged()
        }
        for effect in effects { run(effect, before: before) }
        buttonHaptic(input, before: before, after: next)
    }

    /// The locked recorder's own buttons (the gesture's effects carry only the hold's cues): Stop takes the memo to
    /// review with a light tap, as recording and locking; Delete throws the take away with the rigid one cancelling
    /// gives, once it is really gone (a long take asks first).
    private func buttonHaptic(_ input: MemoInput, before: MemoGestureState, after: MemoGestureState) {
        guard after.phase != before.phase else { return }
        switch input {
        case .stop: Haptics.play(.light)
        case .delete, .deleteConfirmed: Haptics.play(.rigid)
        default: break
        }
    }

    private func settle() {
        levels = []
        levelSamples = 0
        level = 0
        dropWords()   // [live words]
    }

    /// Where a take's draft and notices go: the chat's scope now (a new chat learns its stored id after touch-down),
    /// else the one frozen at touch-down.
    private func scope(_ target: MemoTarget) -> String { target.session?.memoScope ?? target.scope }

    // MARK: Effects (memo-live.ts:87-118)

    private func run(_ effect: MemoEffect, before: MemoGestureState) {
        let target = self.target
        switch effect {
        case .begin:
            begin()
        case .end(let action):
            end(action, before: before)
        case .sendReviewed:
            if let file, let target {
                learnFixes(file, target)   // [live words]
                deliverOrKeep(.send, file, target)
            }
            file = nil
            reviewHeard = nil
            target?.host?.memoStateChanged()
        case .discardReviewed:
            reviewHeard = nil
            // Deleted in review: the file leaves the phone now.
            if let file {
                if MemoPlayer.shared.isCurrent(file.path) { MemoPlayer.shared.stop() }
                MemoPaths.remove(file.path)
            }
            file = nil
            target?.host?.memoStateChanged()
        case .draftReviewed:
            if let file, let target { deliverDraft(file, target) }
            file = nil
        case .confirmDelete(let seconds, let recording):
            guard let host = target?.host else { input(.deleteKept); return }
            host.memoConfirmDelete(seconds: seconds, recording: recording) { [weak self] yes in
                self?.input(yes ? .deleteConfirmed : .deleteKept)
            }
        case .tip(let tip):
            target?.host?.memoShowTip(tip)
        case .failed(let code, let message):
            if let target { announce(MemoNotice.failure(code: code, message: message), scope: scope(target)) }
        case .haptic(let haptic):
            Haptics.play(haptic == .cancelArmed ? .rigid : .light)
        case .focusStatus:
            target?.host?.memoFocusStatus()
        }
    }

    private func begin() {
        generation += 1
        let mine = generation
        // A memo owns the audio session: playback stops first.
        MemoPlayer.shared.stop()
        capture.accountKey = target?.accountKey
        (capture as? MemoRecorder)?.keepAwakeScope = target?.scope ?? ""   // [talk] the hold is named after its chat
        Task {
            do {
                let started = try await capture.begin()
                guard mine == generation else {
                    _ = try? await capture.end(id: started.id, action: .cancel)
                    return
                }
                takeId = started.id
                limit = started.limit
                levels = []
                levelSamples = 0
                level = 0
                startWords()   // [live words]
                input(.started(at: now))
                if let target { AppLog.trace("talk", "memo started \(AppLog.tag(scope: target.scope))") }
                // Nothing wanted it any more (the take was reset meanwhile): stop recording.
                if state.phase == .idle, let id = takeId {
                    takeId = nil
                    _ = try? await capture.end(id: id, action: .cancel)
                }
            } catch {
                guard mine == generation else { return }
                let failure = error as? MemoBeginError ?? .startFailed(MemoRecorder.startReason(error))
                AppLog.note("talk", "memo failed to start (\(failure.code))")
                input(.beginFailed(code: failure.code, granted: failure.granted, message: failure.message))
            }
        }
    }

    private func end(_ action: MemoEndAction, before: MemoGestureState) {
        let target = self.target
        lesson(action, before: before)
        if action == .send {
            if let sendInterval { MemoRecorder.signposts.endInterval("memo send", sendInterval) }
            sendInterval = MemoRecorder.signposts.beginInterval("memo send")
        }
        // [live words] The microphone tap stops with the take; the words settle while the file is saved.
        let heard = takeWords(keep: action != .cancel)
        let heardFrom = (heard != nil, firstWordsMs)
        guard let id = takeId else {
            heard?.cancel()
            if let target { AppLog.trace("talk", "memo \(AppLog.tag(scope: target.scope)) ended (\(action)) before recording started") }
            input(.ended(action: .cancel))
            return
        }
        let seconds = max(before.seconds, state.seconds)
        Task {
            do {
                let saved = try await capture.end(id: id, action: action)
                if takeId == id { takeId = nil }
                guard var result = saved else {
                    heard?.cancel()
                    // A cancelled take (slid away, or deleted when asked) leaves no file.
                    if let target { AppLog.trace("talk", "memo \(AppLog.tag(scope: target.scope)) ended (\(action)): \(Int(seconds))s, nothing kept") }
                    input(.ended(action: action))
                    return
                }
                let settleStart = ContinuousClock.now
                result.words = await Self.settledWords(heard)
                if let target { Self.logWords(result, scope: target.scope, listened: heardFrom.0, firstMs: heardFrom.1, settleMs: AppLog.ms(since: settleStart)) }
                if action == .review {
                    words = LiveWordsText(settled: result.words ?? "")
                    reviewHeard = result.words
                }
                MemoAccountStores.shared.shapes?.remember(result.path, peaks: result.peaks, seconds: result.seconds)
                if action == .review {
                    file = result
                    input(.ended(action: .review, seconds: result.seconds))
                    if let target { AppLog.trace("talk", "memo \(AppLog.tag(scope: target.scope)) ended for review: \(Int(result.seconds))s") }
                    return
                }
                input(.ended(action: action))
                if let target {
                    AppLog.trace("talk", "memo \(AppLog.tag(scope: target.scope)) ended (\(action)): \(Int(result.seconds))s")
                    if action == .send || action == .draft {
                        if action == .send { deliverOrKeep(.send, result, target) } else { deliverDraft(result, target) }
                    }
                }
            } catch {
                if takeId == id { takeId = nil }
                heard?.cancel()
                input(.ended(action: .cancel))
                if action != .cancel, let target {
                    let reason = MemoRecorder.reason(error)
                    AppLog.note("talk", "memo \(AppLog.tag(scope: target.scope)) failed to save (\(action)): \(AppLog.scrub(reason))")
                    announce(MemoNotice(tone: .error, title: "Couldn’t Save the Memo",
                                    message: reason.isEmpty ? "The recording couldn’t be saved on this \(DeviceWord.name)."
                                        : "The recording couldn’t be saved: \(reason)."), scope: scope(target))
                }
            }
        }
    }

    /// Sends only through the chat still showing the composer it was recorded in; anything else keeps it as a draft
    /// chip in that chat, with a notice saying so (`deliverOrKeep`).
    private func deliverOrKeep(_ kind: MemoEndAction, _ file: MemoFile, _ target: MemoTarget) {
        defer {
            if let sendInterval { MemoRecorder.signposts.endInterval("memo send", sendInterval) }
            sendInterval = nil
        }
        if kind == .send, let host = target.host, host.canSendMemo, target.session != nil {
            host.memoSend(file, keyboardWasUp: keyboardWasUp)
            return
        }
        deliverDraft(file, target)
        if kind == .send {
            announce(MemoNotice.savedAsDraft(bot: target.botName), scope: scope(target))
        }
    }

    /// The memo waits as its chat's draft chip (on screen now, or when the chat opens next).
    private func deliverDraft(_ file: MemoFile, _ target: MemoTarget) {
        if let drafts = MemoAccountStores.shared.drafts, MemoAccountStores.shared.key == target.accountKey {
            drafts.set(file, for: scope(target))
        } else {
            MemoPaths.remove(file.path)
        }
    }

    // MARK: The recorder's side

    private func captured(_ event: MemoCaptureEvent) {
        switch event {
        case .level(let level, let seconds):
            guard takeId != nil, state.phase != .review else { return }
            self.level = level
            // One sample per 100 ms of the take. Counted apart from `levels`, which keeps only the newest 600: a take
            // past 60 s must not refill the whole window with the current level on every tick.
            let want = Int(seconds * 10)
            if want > levelSamples {
                levels.append(contentsOf: repeatElement(level, count: min(want - levelSamples, 64)))
                levelSamples = want
                if levels.count > 600 { levels.removeFirst(levels.count - 600) }
            }
            if seconds.rounded(.down) != state.seconds.rounded(.down) {
                input(.tick(seconds: seconds))
            } else {
                target?.host?.memoLevelChanged()
            }
        case .stopped(let reason, let id, let seconds, let disposition):
            guard id == takeId else { return }
            stopMic()   // [live words] nothing said after the recording stopped belongs to it
            if reason == .limit {
                if let target { AppLog.trace("talk", "memo \(AppLog.tag(scope: target.scope)) hit its limit at \(Int(seconds))s") }
                input(.limit(seconds: seconds))
                return
            }
            let target = self.target
            takeId = nil
            input(.nativeStopped)
            guard let target else { return }
            let length = MemoPolicy.total(seconds)
            switch disposition {
            case .failed(let error):
                dropWords()   // [live words]
                AppLog.note("talk", "memo \(AppLog.tag(scope: target.scope)) stopped natively (\(reason)), failed to save: \(AppLog.scrub("\(error)"))")
                announce(MemoNotice(tone: .error, title: "Couldn’t Save the Memo",
                                message: "\(MemoNotice.why(reason)) The \(length) recording couldn’t be saved"
                                    + (error.isEmpty ? " on this \(DeviceWord.name)." : ": \(error).")), scope: scope(target))
            case .draft(var file):
                AppLog.trace("talk", "memo \(AppLog.tag(scope: target.scope)) stopped natively (\(reason)), kept as a draft: \(Int(file.seconds))s")
                MemoAccountStores.shared.shapes?.remember(file.path, peaks: file.peaks, seconds: file.seconds)
                // [live words] The draft carries what was heard (settled first: a moment at most).
                if let heard = takeWords(keep: true) {
                    Task {
                        file.words = await Self.settledWords(heard)
                        self.deliverDraft(file, target)
                    }
                } else {
                    deliverDraft(file, target)
                }
                announce(MemoNotice(tone: .info, title: "Recording Stopped",
                                message: "\(MemoNotice.why(reason)) Your \(length) memo is waiting in the message field."), scope: scope(target))
            case .discard, .await:
                AppLog.trace("talk", "memo \(AppLog.tag(scope: target.scope)) stopped natively (\(reason)), discarded")
                dropWords()
            }
        }
    }

    // MARK: [live words] Words as the take is recorded (docs/spec/3x-live-words.md)

    /// A listener and its microphone tap for the take that just started (nothing when Live Words can't run).
    private func startWords() {
        dropWords()
        wordsToken += 1
        let token = wordsToken
        wordsStartedAt = .now
        firstWordsMs = nil
        guard let listener = makeWords({ [weak self] text in
            guard let self, self.wordsToken == token, self.listener != nil else { return }
            if self.firstWordsMs == nil, !text.isEmpty { self.firstWordsMs = AppLog.ms(since: self.wordsStartedAt) }
            self.words = text
            self.target?.host?.memoWordsChanged()
        }) else { return }
        self.listener = listener
        guard tapsMicrophone else { return }
        #if DEBUG
        if LiveWords.debugScript != nil { return }   // the stand-in hears its script without a microphone
        #endif
        let mic = LiveWordsMic()
        self.mic = mic
        #if DEBUG
        if let file = LiveWords.debugFile {
            AudioWork.later { _ = mic.start(file: file, listener) }
            return
        }
        #endif
        AudioWork.later {
            // A tap that won't start only means no words: the listener settles on none and the gateway transcribes.
            if !mic.start(listener) { VoiceEvents.noteLater("memo words: the microphone tap didn’t start") }
        }
    }

    private func stopMic() {
        guard let mic else { return }
        self.mic = nil
        AudioWork.later { mic.stop() }
    }

    /// The take's listener, its tap stopped: kept to settle its words, or cancelled (nil).
    private func takeWords(keep: Bool) -> (any LiveWordsListening)? {
        stopMic()
        let heard = listener
        listener = nil
        wordsToken += 1
        if !keep { heard?.cancel() }
        return keep ? heard : nil
    }

    private func dropWords() {
        _ = takeWords(keep: false)
        guard !words.isEmpty else { return }
        words = LiveWordsText()
        target?.host?.memoWordsChanged()
    }

    /// [live words] A take's words in review were fixed: the memo carries the fixed words (nil when none are left: the
    /// gateway transcribes it then). Spec 3x-live-words §3.1.1.
    func reviseWords(_ text: String) {
        guard state.phase == .review, var file else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        file.words = trimmed.isEmpty ? nil : trimmed
        self.file = file
        words = LiveWordsText(settled: text)
        target?.host?.memoWordsChanged()
    }

    /// A memo sent from review with its words fixed: what the fix teaches is kept for later memos.
    private func learnFixes(_ file: MemoFile, _ target: MemoTarget) {
        guard let heard = reviewHeard, let meant = file.words, heard != meant else { return }
        let kept = WordFixes.learn(from: heard, to: meant)
        AppLog.trace("talk", "memo \(AppLog.tag(scope: target.scope)) words fixed in review: \(kept) word fix\(kept == 1 ? "" : "es") kept")
    }

    /// One line per take about its words, never the words: whether this device heard them, how many, how soon the first
    /// showed, how long they took to settle. "No words" means the gateway transcribes the memo.
    private static func logWords(_ file: MemoFile, scope: String, listened: Bool, firstMs: Int?, settleMs: Int) {
        let tag = AppLog.tag(scope: scope)
        guard listened else {
            AppLog.trace("talk", "memo \(tag) words: this device didn't listen (\(LiveWords.diagnosticsLine)); the gateway transcribes")
            return
        }
        guard let words = file.words else {
            AppLog.trace("talk", "memo \(tag) words: none heard in \(Int(file.seconds.rounded()))s, settled in \(settleMs) ms; the gateway transcribes")
            return
        }
        let count = words.split(whereSeparator: \.isWhitespace).count
        AppLog.trace("talk", "memo \(tag) words: \(count) from this device in \(Int(file.seconds.rounded()))s, first after \(firstMs.map { "\($0) ms" } ?? "-"), settled in \(settleMs) ms\(settleMs >= Int(LiveWords.settleLimit * 1000) ? " (hit the limit)" : "")")
    }

    /// What `heard` settled on (nil: nothing heard it, or no words; the gateway transcribes the memo then).
    private static func settledWords(_ heard: (any LiveWordsListening)?) async -> String? {
        guard let heard else { return nil }
        let said = await heard.finish()
        return said.isEmpty ? nil : said
    }

    // MARK: Tips (memo-live.ts:274-284)

    /// A memo sent by holding teaches both hold tips; a memo locked by a tap earns "Hold to Record" once.
    private func lesson(_ action: MemoEndAction, before: MemoGestureState) {
        guard action != .cancel && action != .draft else { return }
        if before.phase == .holding {
            MemoTips.finish(.holdToRecord)
            MemoTips.finish(.nowHold)
            target?.host?.memoDismissTip()
            return
        }
        if before.tapLocked && !MemoTips.isDone(.holdToRecord) {
            target?.host?.memoShowTip(.holdToRecord)
        }
    }

    // MARK: Notices

    func notice(for scope: String) -> MemoNotice? { notices[scope] }

    /// A memo's own notice, with the tap its tone gives (an info one plays none), as Dictation's. `post` alone stays
    /// silent: Dictation and Talk post through it after playing their own.
    private func announce(_ notice: MemoNotice, scope: String) {
        switch notice.tone {
        case .error: Haptics.play(.error)
        case .warning: Haptics.play(.warning)
        case .info: break
        }
        post(notice, scope: scope)
    }

    func post(_ notice: MemoNotice, scope: String) {
        notices[scope] = notice
        NotificationCenter.default.post(name: Self.noticesChanged, object: self, userInfo: ["scope": scope])
    }

    func dismissNotice(scope: String) {
        guard notices.removeValue(forKey: scope) != nil else { return }
        NotificationCenter.default.post(name: Self.noticesChanged, object: self, userInfo: ["scope": scope])
    }

    // MARK: Lifecycle

    /// The take's chat left the screen: a take left behind becomes a draft chip there (C3).
    func screenLeft(_ host: ChatVoiceHost) {
        guard isTarget(host), state.phase != .idle else { return }
        input(.leave)
    }

    /// Sign-out or an account switch: a take still recording is dropped. A take in review waits as its chat's draft
    /// on the account it was recorded for (UX study #267; a sign-out purges that account's drafts right after).
    func reset() {
        generation += 1
        dropWords()   // [live words]
        if let id = takeId {
            takeId = nil
            Task { _ = try? await capture.end(id: id, action: .cancel) }
        }
        if let file {
            if MemoPlayer.shared.isCurrent(file.path) { MemoPlayer.shared.stop() }
            if let target { deliverDraft(file, target) } else { MemoPaths.remove(file.path) }
        }
        file = nil
        let host = target?.host
        state = .idle
        shownPhase = .idle
        settle()
        target = nil
        notices = [:]
        host?.memoStateChanged()
    }
}
