// The one owner of AVAudioSession (spec 1x-voice V3, §3.4, §6.4). The session is active only while a memo records or
// plays, never ducks other apps, and is always released with `.notifyOthersOnDeactivation` so music resumes. Nothing
// touches it at launch. Live voice (docs/spec/3x-talk.md §10.1) adds the conversation, dictation, speech and diagnostics.
//
// `setCategory`/`setActive` are blocking calls into the media server (tens to hundreds of ms on a device, more with
// Bluetooth HFP), so they run on one serial queue (`AudioWork`), never on the main thread (A-P1). Who holds the
// session is bookkept on the main actor at once; the activation is awaited, the release is fire-and-forget. One serial
// queue keeps them in the order they were asked for.

import AVFAudio
import Foundation

/// The serial queue every AVAudioSession and AVAudioRecorder call runs on.
nonisolated enum AudioWork {
    static let queue = DispatchQueue(label: "hq.audio.session", qos: .userInteractive)

    /// Runs `work` on the audio queue (behind everything already sent there) and returns its result.
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// `run` for work that can't fail.
    static func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Fire-and-forget, behind everything already sent to the audio queue.
    static func later(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

    /// Waits until everything sent to the audio queue so far has run.
    static func drain() async { await perform { () } }
}

@MainActor final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()

    // [talk] `conversation` is real now; `dictation`, `speech` and `diagnostics` are new (docs/spec/3x-talk.md §10.1).
    nonisolated enum Owner: String, Equatable, Hashable, Sendable {
        case memoRecording
        case memoPlayback
        /// A live voice conversation: it outranks every other owner.
        case conversation
        case dictation
        /// Read Aloud and Read Replies Aloud outside a conversation.
        case speech
        case diagnostics

        var records: Bool { self == .memoRecording || self == .dictation || self == .diagnostics || self == .conversation }
        var plays: Bool { self == .memoPlayback || self == .speech }
    }

    private(set) var owner: Owner?
    /// Counts every time the session changes hands (`acquire` returns it), so a start that was abandoned can tell
    /// whether the session it took is still its own (`releaseAbandoned`).
    private(set) var grant = 0
    /// [talk] Memo playback or speech playing inside a conversation's session ("borrowed": the category is not changed).
    private(set) var borrower: Owner?
    /// Called when another owner takes the session from memo playback (recording starts): the player pauses.
    var onPlaybackPreempted: (() -> Void)?
    // [talk] The other owners' ways out, set once by `TalkWiring`.
    /// Speech (Read Aloud) lost the session.
    var onSpeechPreempted: (() -> Void)?
    /// A recording owner (memo, dictation, diagnostics) lost the session to a conversation, another recording or a player.
    var onRecordingPreempted: ((Owner) -> Void)?
    /// Memo playback or speech started while a conversation holds the session: the conversation mutes itself (T13).
    var onConversationBorrowed: ((Owner) -> Void)?
    /// A memo or a dictation wants the microphone a conversation holds: the conversation ends first (§6.8).
    var endConversation: (() async -> Void)?

    /// [talk] A conversation plays on the loudspeaker unless the person chose the earpiece (the bar's speaker button);
    /// headphones, Bluetooth, CarPlay and AirPlay always win. Back to on for every new conversation (owner, 2026-10-27:
    /// "it should auto turn on the speaker no matter what though unless you have headphones").
    private(set) var loudspeaker = true
    static let loudspeakerChanged = Notification.Name("hq.audio.loudspeakerChanged")
    private var routeObserver: (any NSObjectProtocol)?

    #if DEBUG
    /// Owners whose stand-in (the simulator's fixture recorder, capture or speaker) never touches the real session.
    var simulatedOwners: Set<Owner> = []
    /// The simulator's fixture recorder never touches the real session.
    var simulated: Bool {
        get { simulatedOwners.contains(.memoRecording) }
        set { if newValue { simulatedOwners.insert(.memoRecording) } else { simulatedOwners.remove(.memoRecording) } }
    }
    #endif

    private func isSimulated(_ owner: Owner) -> Bool {
        #if DEBUG
        return simulatedOwners.contains(owner)
        #else
        return false
        #endif
    }

    /// Takes the session for `owner`: who holds it changes now; the activation runs on the audio queue and is awaited.
    /// Recording stops memo playback first. A throw leaves `owner` set: the caller releases it. [gpt-live] `mode` is the
    /// recording mode: GPT-Live's WebRTC peer wants `.voiceChat` (the system's echo cancellation; it has none of its own).
    /// Returns this hold's `grant`.
    @discardableResult
    func acquire(_ owner: Owner, mode: AVAudioSession.Mode = .default) async throws -> Int {
        if self.owner == .conversation, owner != .conversation {
            if owner.plays {
                // Rule 2: played inside the conversation's session.
                borrower = owner
                VoiceEvents.note("audio session: \(owner.rawValue) plays inside the conversation")
                onConversationBorrowed?(owner)
                return grant
            }
            // Rule 3: one microphone. The conversation ends before this owner records.
            VoiceEvents.note("audio session: \(owner.rawValue) ends the conversation")
            await endConversation?()
        }
        if let current = self.owner, current != owner {
            switch current {
            case .memoPlayback: if owner != .memoPlayback { onPlaybackPreempted?() }
            case .speech: onSpeechPreempted?()
            // Whoever takes the session from a recording ends it, a player too (Read Aloud tapped during a hands-free
            // memo): the category is about to change under the recorder, which would go on "recording" dead air.
            case .memoRecording, .dictation, .diagnostics: onRecordingPreempted?(current)
            case .conversation: break
            }
        }
        if owner == .conversation, self.owner != .conversation, !loudspeaker {
            loudspeaker = true
            NotificationCenter.default.post(name: Self.loudspeakerChanged, object: nil)
        }
        self.owner = owner
        borrower = nil
        grant += 1
        let held = grant
        VoiceEvents.note("audio session: \(owner.rawValue) acquired")
        if isSimulated(owner) { return held }
        do {
            let speaker = loudspeaker
            try await AudioWork.run {
                try Self.activate(owner, mode: mode)
                if owner == .conversation { Self.applyLoudspeaker(speaker) }
            }
            if owner == .conversation { watchRoute() }
        } catch {
            VoiceEvents.note("audio session: \(owner.rawValue) failed: \(VoiceReport.scrub(error.localizedDescription))")
            throw error
        }
        return held
    }

    /// Gives the session back (only when `owner` still holds it); other apps' audio resumes. Never waits: the
    /// deactivation runs on the audio queue after anything asked before it (a recorder's stop above all).
    func release(_ owner: Owner) {
        if borrower == owner, self.owner != owner {
            borrower = nil
            VoiceEvents.note("audio session: \(owner.rawValue) done inside the conversation")
            return
        }
        guard self.owner == owner else { return }
        self.owner = nil
        borrower = nil
        if owner == .conversation { unwatchRoute() }
        VoiceEvents.note("audio session: \(owner.rawValue) released")
        if isSimulated(owner) { return }
        AudioWork.later { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    /// A start that was ended while its session came up (End or Stop during "Starting…"): its owner may have been
    /// released already, and an engine or recorder started after that turns the session on again by itself, so other
    /// apps' audio stayed paused and the microphone on. Gives the hold `grant` back as `release` does; with nobody
    /// holding the session now it is turned off again. A newer hold (another start meanwhile) is left alone.
    func releaseAbandoned(_ owner: Owner, grant: Int) {
        if self.owner == owner {
            if self.grant == grant { release(owner) }
            return
        }
        guard self.owner == nil, !isSimulated(owner) else { return }
        VoiceEvents.note("audio session: \(owner.rawValue) given back after a start that was ended")
        AudioWork.later { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    /// The bar's speaker button: the loudspeaker, or the earpiece. Only while the built-in route plays.
    func setLoudspeaker(_ on: Bool) {
        guard loudspeaker != on else { return }
        loudspeaker = on
        VoiceEvents.note("audio session: loudspeaker \(on ? "on" : "off")")
        NotificationCenter.default.post(name: Self.loudspeakerChanged, object: nil)
        guard owner == .conversation, !isSimulated(.conversation) else { return }
        AudioWork.later { Self.applyLoudspeaker(on) }
    }

    /// Every route change while a conversation holds the session puts the loudspeaker back if it is wanted: GPT-Live's
    /// WebRTC sets the category again for itself (without `.defaultToSpeaker`, so its replies came out of the earpiece),
    /// and unplugged headphones fall back to the earpiece.
    private func watchRoute() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let shared = AudioSessionCoordinator.shared
                guard shared.owner == .conversation, !shared.isSimulated(.conversation) else { return }
                let on = shared.loudspeaker
                AudioWork.later { Self.applyLoudspeaker(on) }
            }
        }
    }

    private func unwatchRoute() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
    }

    nonisolated enum SpeakerOverride: Equatable, Sendable { case speaker, clear }

    /// What to do to the output for `outputs` (the current route's port types, `AVAudioSession.Port` raw values):
    /// anything but the phone's own receiver and speaker is left alone; the receiver goes to the speaker when the
    /// loudspeaker is wanted, the speaker back to the receiver when it is not. Nil: nothing to do.
    nonisolated static func speakerOverride(outputs: [String], loudspeaker: Bool) -> SpeakerOverride? {
        let builtIn: Set = [AVAudioSession.Port.builtInReceiver.rawValue, AVAudioSession.Port.builtInSpeaker.rawValue]
        guard !outputs.isEmpty, outputs.allSatisfy(builtIn.contains) else { return nil }
        if loudspeaker, outputs.contains(AVAudioSession.Port.builtInReceiver.rawValue) { return .speaker }
        if !loudspeaker, outputs.contains(AVAudioSession.Port.builtInSpeaker.rawValue) { return .clear }
        return nil
    }

    /// On the audio queue. `.defaultToSpeaker` follows the choice (without it the earpiece is the default; with it the
    /// speaker), then the port is overridden if the route still disagrees. Idempotent, so the route changes it causes
    /// end here.
    private nonisolated static func applyLoudspeaker(_ on: Bool) {
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord else { return }
        if session.categoryOptions.contains(.defaultToSpeaker) != on {
            var options = session.categoryOptions
            if on { options.insert(.defaultToSpeaker) } else { options.remove(.defaultToSpeaker) }
            do {
                try session.setCategory(.playAndRecord, mode: session.mode, options: options)
            } catch {
                VoiceEvents.noteLater("audio session: loudspeaker option failed: \(VoiceReport.scrub(error.localizedDescription))")
            }
        }
        let outputs = session.currentRoute.outputs.map(\.portType.rawValue)
        let change = speakerOverride(outputs: outputs, loudspeaker: on)
        AppLog.trace("voice", "loudspeaker \(on ? "on" : "off"): route \(outputs.joined(separator: "+")), mode \(session.mode.rawValue), "
                     + "output volume \(String(format: "%.2f", session.outputVolume)), \(change.map { $0 == .speaker ? "to the loudspeaker" : "to the earpiece" } ?? "no change")")
        guard let change else { return }
        do {
            try session.overrideOutputAudioPort(change == .speaker ? .speaker : .none)
            VoiceEvents.noteLater("audio session: output \(change == .speaker ? "to the loudspeaker" : "to the earpiece")")
        } catch {
            VoiceEvents.noteLater("audio session: output override failed: \(VoiceReport.scrub(error.localizedDescription))")
            AppLog.note("voice", "loudspeaker override failed: \(AppLog.scrub(error.localizedDescription))")
        }
    }

    /// Whether `owner` plays or records right now (as the holder or inside a conversation).
    func holds(_ owner: Owner) -> Bool { self.owner == owner || borrower == owner }

    /// Media services were reset: nobody holds the session any more.
    func reset() { owner = nil; borrower = nil; unwatchRoute() }

    /// On the audio queue.
    private nonisolated static func activate(_ owner: Owner, mode: AVAudioSession.Mode) throws {
        let session = AVAudioSession.sharedInstance()
        switch owner {
        case .memoRecording, .conversation, .dictation, .diagnostics:
            try session.setCategory(.playAndRecord, mode: mode, options: [.allowBluetoothHFP, .defaultToSpeaker])
            // iOS mutes haptics while recording; the lock and cancel feedback would be silent without this (R3).
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        case .memoPlayback, .speech:
            // Plays with the silent switch on (as the web's transcript media); pauses other audio, never ducks it.
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        }
        try session.setActive(true)
    }
}
