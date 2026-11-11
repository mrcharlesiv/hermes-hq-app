// More Accurate Words (docs/spec/3x-live-words.md §2.2). A larger speech model on this device (NVIDIA's Parakeet TDT
// 0.6B v2, English, run by FluidAudio on Core ML) hears a memo, Dictate or a Talk take instead of Apple's engine. On the
// owner's own memos it wrote about a third as many wrong words (the 2026-11-10 study in the spec).
//
// The model hears a recording, not a stream, so a listening hears the words so far again every half second: the audio
// not yet settled (14 s at most) goes through the model, and what it says replaces the pending words. Past 14 s the
// oldest part is cut at its quietest moment and its words settle. Ending the take hears the last part once more.
//
// Anything that keeps this from working (the switch off, a language other than English, the model not downloaded yet,
// an error) leaves Apple's engine, and past that the gateway (`LiveWords`). Never logs the words.

import CoreML
import FluidAudio
import Foundation
import Network
import Synchronization

/// What hears a stretch of 16 kHz mono sound: the words, "" for none, nil when it failed.
nonisolated protocol ParakeetHearing: Sendable {
    func words(_ samples: [Float]) async -> String?
}

@MainActor enum ParakeetWords {
    /// Settings › Voice › Live Words › More Accurate Words (on unless turned off).
    static let settingKey = "hq.voice.betterWords"
    static var isOn: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }
    /// What the model's files take (Preprocessor, Encoder, Decoder, JointDecision), for the words in Settings.
    nonisolated static let downloadSize = "470 MB"

    nonisolated enum Readiness: Equatable, Sendable {
        case unknown, checking
        /// The model isn't here and the network is cellular or Low Data: asked again when a chat next opens.
        case waitingForWiFi
        /// Downloading: the percent so far.
        case downloading(Int)
        /// On this device, being loaded (the first load after a download compiles it: up to a minute).
        case loading
        case ready
        /// A short fact for Voice Diagnostics ("English only", the error).
        case unavailable(String)
    }

    private(set) static var readiness: Readiness = .unknown
    private static var hearing: (any ParakeetHearing)?

    /// The model is English only: the person's first language decides.
    static var speaksEnglish: Bool {
        let first = Locale.preferredLanguages.first.map(Locale.init(identifier:)) ?? Locale.current
        return first.language.languageCode?.identifier == "en"
    }

    /// Loads the model, downloading it first when it isn't here (on Wi-Fi only). Cheap once checked.
    static func prepare() {
        guard isOn, readiness == .unknown || readiness == .waitingForWiFi else { return }
        #if targetEnvironment(simulator)
        set(.unavailable("not in the simulator"))
        #else
        guard speaksEnglish else { return set(.unavailable("English only")) }
        set(.checking)
        Task {
            let here = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2)
            if !here, await onMeteredNetwork() { return set(.waitingForWiFi) }
            set(here ? .loading : .downloading(0))
            do {
                let models = try await AsrModels.downloadAndLoad(version: .v2) { progress in
                    let percent = Int((progress.fractionCompleted * 100).rounded(.down))
                    Task { @MainActor in noteDownload(percent) }
                }
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                let engine = ParakeetEngine(manager: manager)
                // The first pass after a load is slow (Core ML warms up): spent here, not on the first words.
                _ = await engine.words([Float](repeating: 0, count: ParakeetCut.rate))
                keepOutOfBackups()
                guard isOn else { return }   // switched off while it loaded
                hearing = engine
                set(.ready)
            } catch {
                set(.unavailable("model didn’t load (\((error as NSError).domain) \((error as NSError).code))"))
            }
        }
        #endif
    }

    /// A new listening, or nil when the model isn't ready (Apple's engine listens then).
    static func listen(onText: @escaping @MainActor (LiveWordsText) -> Void) -> (any LiveWordsListening)? {
        guard isOn, readiness == .ready, let hearing else { return nil }
        return ParakeetLiveWords(hearing: hearing, onText: onText)
    }

    /// The switch: off lets the model go and deletes its download; on gets it again.
    static func setOn(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: settingKey)
        if on {
            if case .unavailable = readiness { readiness = .unknown }
            prepare()
        } else {
            hearing = nil
            let folder = AsrModels.defaultCacheDirectory(for: .v2)
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
            set(.unknown)
        }
    }

    /// One fact for Voice Diagnostics, nil when the switch is off.
    static var diagnosticsLine: String? {
        guard isOn else { return nil }
        switch readiness {
        case .unknown: return "larger model not checked yet"
        case .checking: return "larger model: checking"
        case .waitingForWiFi: return "larger model waits for Wi-Fi"
        case .downloading(let percent): return "larger model downloading (\(percent)%)"
        case .loading: return "larger model loading"
        case .ready: return "larger model (Parakeet, English)"
        case .unavailable(let why): return "larger model unavailable (\(why))"
        }
    }

    private static func noteDownload(_ percent: Int) {
        if case .downloading(let now) = readiness, percent > now, percent < 100 { set(.downloading(percent)) }
    }

    private static func set(_ value: Readiness) {
        guard readiness != value else { return }
        readiness = value
        switch value {
        case .unavailable(let why): AppLog.note("voice", "more accurate words unavailable: \(why)")
        case .ready: AppLog.trace("voice", "more accurate words ready")
        case .waitingForWiFi: AppLog.trace("voice", "more accurate words: the model waits for Wi-Fi")
        default: break
        }
        NotificationCenter.default.post(name: LiveWords.readinessChanged, object: nil)
    }

    /// The model can be downloaded again: it stays out of iCloud and computer backups.
    private static func keepOutOfBackups() {
        var folder = AsrModels.defaultCacheDirectory(for: .v2)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    /// Whether the network now is cellular, a hotspot or in Low Data Mode (no 470 MB download over those).
    private nonisolated static func onMeteredNetwork() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let answered = Mutex(false)
            monitor.pathUpdateHandler = { path in
                let first = answered.withLock { was -> Bool in
                    defer { was = true }
                    return !was
                }
                guard first else { return }
                monitor.cancel()
                continuation.resume(returning: path.isExpensive || path.isConstrained)
            }
            monitor.start(queue: .global(qos: .utility))
        }
    }

    #if DEBUG
    /// The bench: a whole recording through the model (FluidAudio cuts a long one into overlapping windows itself).
    static func hearWhole(_ samples: [Float]) async -> String? { await hearing?.words(samples) }

    /// Tests: a stand-in model, ready at once (nil: start from scratch).
    static func resetForTests(_ stand: (any ParakeetHearing)? = nil) {
        hearing = stand
        readiness = stand == nil ? .unknown : .ready
    }
    #endif
}

/// The model. `AsrManager` is an actor: passes wait their turn.
nonisolated final class ParakeetEngine: ParakeetHearing {
    private let manager: AsrManager

    init(manager: AsrManager) { self.manager = manager }

    func words(_ samples: [Float]) async -> String? {
        // The model wants a second of sound at least: a shorter stretch gets silence after it.
        var sound = samples
        if sound.count < ParakeetCut.rate { sound.append(contentsOf: [Float](repeating: 0, count: ParakeetCut.rate - sound.count)) }
        do {
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            return try await manager.transcribe(sound, decoderState: &state).text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            VoiceEvents.noteLater("more accurate words stopped (\((error as NSError).domain) \((error as NSError).code))")
            return nil
        }
    }
}

/// How a long take is cut into stretches the model hears whole.
nonisolated enum ParakeetCut {
    static let rate = 16_000
    /// The most unsettled sound a pass hears (the model's window is 15 s).
    static let limit = 14 * rate
    /// New sound a pass waits for after the last one.
    static let step = rate / 2
    /// The least sound worth a pass.
    static let least = rate * 4 / 5
    /// A cut leaves this much sound settled at least, and this much unsettled (the newest words keep changing).
    static let head = 6 * rate, tail = 2 * rate

    /// Where to cut `samples`: the middle of its quietest 0.2 s between `head` and `tail` from its end (a pause between
    /// words, usually between sentences), so no word is cut in two.
    static func pause(in samples: [Float]) -> Int {
        let frame = rate / 50, span = 10
        let from = min(head, samples.count / 2), to = max(from + 1, samples.count - tail)
        let first = from / frame, last = max(first + 1, to / frame - span)
        var energy = [Float](repeating: 0, count: last + span - first)
        for index in energy.indices {
            let start = (first + index) * frame, end = min(samples.count, start + frame)
            guard start < end else { break }
            var sum: Float = 0
            for sample in samples[start..<end] { sum += sample * sample }
            energy[index] = sum
        }
        var window = energy.prefix(span).reduce(0, +), best = window, bestAt = 0
        for index in 1..<max(1, energy.count - span + 1) {
            window += energy[index + span - 1] - energy[index - 1]
            // Ties go to the later pause: more settles, and less is heard again each pass.
            if window <= best { best = window; bestAt = index }
        }
        return min(samples.count, (first + bestAt) * frame + span * frame / 2)
    }
}

/// One take heard by the model, again and again as it grows (the header says how).
nonisolated final class ParakeetLiveWords: LiveWordsListening, @unchecked Sendable {
    private struct State {
        /// The sound not settled yet.
        var samples: [Float] = []
        /// How much of `samples` the last pass heard.
        var heard = 0
        var text = LiveWordsText()
        var closed = false, cancelled = false, failed = false
    }

    private enum Pass {
        case peek([Float]), settle([Float]), last([Float])
    }

    private let state = Mutex(State())
    private let hearing: any ParakeetHearing
    private let onText: @MainActor (LiveWordsText) -> Void
    private let work = Mutex<Task<Void, Never>?>(nil)

    init(hearing: any ParakeetHearing, onText: @escaping @MainActor (LiveWordsText) -> Void) {
        self.hearing = hearing
        self.onText = onText
        work.withLock { $0 = Task.detached(priority: .userInitiated) { [self] in await run() } }
    }

    func feed(_ samples: UnsafeBufferPointer<Int16>) {
        guard !samples.isEmpty else { return }
        state.withLock { s in
            guard !s.closed, !s.failed else { return }
            s.samples.reserveCapacity(s.samples.count + samples.count)
            for sample in samples { s.samples.append(Float(sample) / 32_768) }
        }
    }

    func finish() async -> String {
        let already = state.withLock { s -> Bool in
            defer { s.closed = true }
            return s.closed
        }
        let so: @Sendable () -> String = { [self] in state.withLock { $0.failed ? "" : $0.text.whole } }
        guard !already else { return so() }
        let work = self.work.withLock { $0 }
        return await LiveWordsWait.first(within: LiveWords.settleLimit, otherwise: so) {
            await work?.value
            return so()
        }
    }

    func cancel() {
        state.withLock { s in
            s.closed = true
            s.cancelled = true
        }
    }

    private func next() -> Pass? {
        state.withLock { s -> Pass? in
            if s.samples.count > ParakeetCut.limit { return .settle(s.samples) }
            if s.closed { return .last(s.samples) }
            guard s.samples.count >= ParakeetCut.least, s.samples.count - s.heard >= ParakeetCut.step else { return nil }
            s.heard = s.samples.count
            return .peek(s.samples)
        }
    }

    private func run() async {
        while !state.withLock({ $0.cancelled || $0.failed }) {
            guard let pass = next() else {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            switch pass {
            case .peek(let sound):
                guard let words = await hearing.words(sound) else { return fail() }
                show { s in
                    // A take that ended meanwhile is heard once more, whole: these words would only flicker.
                    guard !s.closed else { return false }
                    s.text.pending = words
                    return true
                }
            case .settle(let sound):
                let cut = ParakeetCut.pause(in: sound)
                guard let settled = await hearing.words(Array(sound[..<cut])),
                      let rest = await hearing.words(Array(sound[cut...])) else { return fail() }
                show { s in
                    s.text.settled = LiveWordsText.join(s.text.settled, settled)
                    s.text.pending = rest
                    s.samples.removeFirst(cut)
                    s.heard = sound.count - cut
                    return true
                }
            case .last(let sound):
                // Under a fifth of a second is a tap, not a word.
                let words = sound.count < ParakeetCut.rate / 5 ? "" : await hearing.words(sound)
                guard let words else { return fail() }
                show { s in
                    s.text.settled = LiveWordsText.join(s.text.settled, words)
                    s.text.pending = ""
                    s.samples = []
                    return true
                }
                return
            }
        }
    }

    private func show(_ change: (inout State) -> Bool) {
        let text = state.withLock { s -> LiveWordsText? in
            guard !s.cancelled, change(&s) else { return nil }
            return s.text
        }
        guard let text else { return }
        let onText = self.onText
        Task { @MainActor in onText(text) }
    }

    /// The model failed: no words from this take, so the gateway hears the recording.
    private func fail() { state.withLock { $0.failed = true } }
}
