// More Accurate Words (docs/spec/3x-live-words.md §2.2). A larger speech model on this device (NVIDIA's Parakeet TDT
// 0.6B v2, English, run by FluidAudio on Core ML) hears a memo, Dictate or a Talk take instead of Apple's engine. On the
// owner's own memos it wrote about a third as many wrong words (the 2026-11-10 study in the spec).
//
// The model hears a recording, not a stream, so a listening hears the words so far again every half second: the audio
// not yet settled (14 s at most) goes through the model, and what it says replaces the pending words. Past 14 s the
// oldest part is cut at its quietest moment and its words settle. Ending the take hears the last part once more.
//
// The model is costly to hold (the owner's logs, 2026-11-18: loading it took some 800 MB at its peak on every launch,
// and on some runs the app then sat at 2 GB and more until it was next started), and it used to load whenever a chat
// opened. Now it is fetched and loaded for people who talk: at the first memo, Dictate or Talk take, and from then on
// a few seconds after a chat opens while the mic was used within the last `usedWindow`. It is let go when iOS says
// memory is short, and in the background when the app is holding too much; the next take brings it back.
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

    /// Why the model is asked for: a chat opened (only people who talk get it then), or the mic or its settings are
    /// in use.
    nonisolated enum Ask: Sendable { case chatOpened, use }

    /// When a take last asked for words on this device.
    static let usedKey = "hq.voice.betterWordsUsedAt"
    /// How long after the last take a chat opening still loads the model ahead of the next one.
    nonisolated static let usedWindow: TimeInterval = 7 * 86_400
    /// A chat opening waits this long before the load, so the chat's own opening isn't slowed by it.
    static var openDelay: Duration = .seconds(4)
    /// After iOS said memory was short, a chat opening doesn't load the model again for this long (a take still does).
    nonisolated static let pressureRest: TimeInterval = 600
    /// In the background the model is let go when the app holds more than this.
    nonisolated static let backgroundCeilingMB = 1_000
    private static var letGoAt: Date?
    /// Counts loads asked for, so one that was let go or switched off while it ran isn't kept.
    private static var loadGeneration = 0
    /// Generation of the currently installed `loadTask` so an older task's `defer` never clears a newer one.
    private static var activeLoadGeneration = 0
    /// Serializes model loads and cache removals so rapid off/on toggles never run two Core ML loads at once.
    private static var loadTask: Task<Void, Never>?
    private static var deleteTask: Task<Void, Never>?

    /// Whether a chat opening should load the model: the mic was used lately, and memory wasn't just short.
    nonisolated static func loadsOnOpen(lastUsed: Date?, letGo: Date?, now: Date = Date()) -> Bool {
        guard let lastUsed, now.timeIntervalSince(lastUsed) < usedWindow else { return false }
        if let letGo, now.timeIntervalSince(letGo) < pressureRest { return false }
        return true
    }

    /// A take asked for words: remembered (at most once an hour), so chats load the model ahead from now on.
    private static func noteUse(now: Date = Date()) {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: usedKey) as? Date, now.timeIntervalSince(last) < 3_600 { return }
        defaults.set(now, forKey: usedKey)
    }

    /// Memory is short (`pressure`), or the app went to the background holding `footprintMB`: the model is let go
    /// unless it is loading. A take that is listening keeps its own hold until it ends. True when it was let go.
    @discardableResult
    static func letGo(pressure: Bool, footprintMB: Int? = nil, now: Date = Date()) -> Bool {
        guard hearing != nil, readiness == .ready else { return false }
        if !pressure {
            guard let footprintMB, footprintMB > backgroundCeilingMB else { return false }
        }
        hearing = nil
        loadGeneration += 1
        if pressure { letGoAt = now }
        AppLog.note("voice", "more accurate words let go (\(pressure ? "memory short" : "background"), app at \(footprintMB.map(String.init) ?? "?") MB)")
        set(.unknown)
        return true
    }

    /// The model is English only: the language chosen for this device's words decides, else the person's first.
    static var speaksEnglish: Bool {
        let first = (LiveWords.language ?? Locale.preferredLanguages.first).map(Locale.init(identifier:)) ?? Locale.current
        return first.language.languageCode?.identifier == "en"
    }

    /// The language for this device's words changed: the model is let go and asked again (it may now be the wrong one,
    /// or the right one). Its download stays.
    static func languageChanged() {
        hearing = nil
        loadGeneration += 1
        loadTask?.cancel()
        set(.unknown)
    }

    /// Loads the model, downloading it first when it isn't here (on Wi-Fi only). Cheap once checked. A chat opening
    /// (`.chatOpened`) does it only for someone who used the mic lately, and after a short wait.
    static func prepare(_ ask: Ask = .use) {
        guard isOn, readiness == .unknown || readiness == .waitingForWiFi else { return }
        let opened = ask == .chatOpened
        if opened {
            guard loadsOnOpen(lastUsed: UserDefaults.standard.object(forKey: usedKey) as? Date, letGo: letGoAt) else { return }
        }
        #if targetEnvironment(simulator)
        let hasDebugLoader: Bool
        #if DEBUG
        hasDebugLoader = debugLoader != nil
        #else
        hasDebugLoader = false
        #endif
        if !hasDebugLoader {
            set(.unavailable("not in the simulator"))
            return
        }
        #endif
        guard speaksEnglish else { return set(.unavailable("English only")) }
        set(.checking)
        let previousLoad = loadTask
        let previousDelete = deleteTask
        loadGeneration += 1
        let generation = loadGeneration
        activeLoadGeneration = generation
        loadTask = Task {
            defer { if activeLoadGeneration == generation { loadTask = nil } }
            await previousLoad?.value
            await previousDelete?.value
            guard isOn, !Task.isCancelled, generation == loadGeneration else { return }
            if opened {
                try? await Task.sleep(for: openDelay)
                guard isOn, !Task.isCancelled, generation == loadGeneration else { return }
            }
            let started = Date(), before = MemoryFootprint.sample()?.mb
            let here = modelsExistOnDisk()
            if !here {
                let metered = await checkMeteredNetwork()
                guard isOn, !Task.isCancelled, generation == loadGeneration else { return }
                if metered { return set(.waitingForWiFi) }
            }
            guard isOn, !Task.isCancelled, generation == loadGeneration else { return }
            set(here ? .loading : .downloading(0))
            do {
                let engine = try await loadEngine(generation: generation)
                guard isOn, !Task.isCancelled, generation == loadGeneration else { return }
                // The first pass after a load is slow (Core ML warms up): spent here, not on the first words.
                _ = await engine.words([Float](repeating: 0, count: ParakeetCut.rate))
                guard isOn, !Task.isCancelled, generation == loadGeneration else { return }
                keepOutOfBackups()
                hearing = engine
                // [diagnostics] What the load cost: the logs showed 800 MB to over 2 GB with nothing to say why.
                let after = MemoryFootprint.sample()
                AppLog.note("voice", "more accurate words loaded in \(Int(Date().timeIntervalSince(started))) s (\(opened ? "chat opened" : "in use")\(here ? "" : ", downloaded")): app \(before.map(String.init) ?? "?") → \(after.map { String($0.mb) } ?? "?") MB")
                set(.ready)
            } catch {
                guard isOn, !Task.isCancelled, generation == loadGeneration else { return }
                set(.unavailable("model didn’t load (\((error as NSError).domain) \((error as NSError).code))"))
            }
        }
    }

    private static func modelsExistOnDisk() -> Bool {
        #if DEBUG
        if let debugModelsExist { return debugModelsExist() }
        #endif
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2)
    }

    private static func checkMeteredNetwork() async -> Bool {
        #if DEBUG
        if let debugMeteredNetwork { return await debugMeteredNetwork() }
        #endif
        return await onMeteredNetwork()
    }

    private static func loadEngine(generation: Int) async throws -> any ParakeetHearing {
        #if DEBUG
        if let debugLoader { return try await debugLoader() }
        #endif
        let models = try await AsrModels.downloadAndLoad(version: .v2) { progress in
            let percent = Int((progress.fractionCompleted * 100).rounded(.down))
            Task { @MainActor in noteDownload(percent, generation: generation) }
        }
        guard isOn, !Task.isCancelled, generation == loadGeneration else { throw CancellationError() }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return ParakeetEngine(manager: manager)
    }

    /// A new listening, or nil when the model isn't ready (Apple's engine listens then).
    static func listen(onText: @escaping @MainActor (LiveWordsText) -> Void) -> (any LiveWordsListening)? {
        guard isOn else { return nil }
        noteUse()
        guard readiness == .ready, let hearing else {
            prepare(.use)   // not here yet (never asked for, or let go): this take gets Apple's engine, the next the model
            return nil
        }
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
            loadGeneration += 1
            loadTask?.cancel()
            let previousDelete = deleteTask
            let folder = AsrModels.defaultCacheDirectory(for: .v2)
            deleteTask = Task.detached(priority: .utility) {
                await previousDelete?.value
                try? FileManager.default.removeItem(at: folder)
            }
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

    private static func noteDownload(_ percent: Int, generation: Int) {
        guard isOn, generation == loadGeneration else { return }
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
    /// Tests: injectable async loader & network/disk probes so `prepare` can be exercised on Simulator.
    static var debugLoader: (@MainActor () async throws -> any ParakeetHearing)?
    static var debugModelsExist: (() -> Bool)?
    static var debugMeteredNetwork: (() async -> Bool)?

    /// The bench: a whole recording through the model (FluidAudio cuts a long one into overlapping windows itself).
    static func hearWhole(_ samples: [Float]) async -> String? { await hearing?.words(samples) }

    /// Tests: a stand-in model, ready at once (nil: start from scratch).
    static func resetForTests(_ stand: (any ParakeetHearing)? = nil) {
        loadGeneration += 1
        activeLoadGeneration = loadGeneration
        loadTask?.cancel()
        loadTask = nil
        deleteTask = nil
        debugLoader = nil
        debugModelsExist = nil
        debugMeteredNetwork = nil
        hearing = stand
        readiness = stand == nil ? .unknown : .ready
        letGoAt = nil
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
