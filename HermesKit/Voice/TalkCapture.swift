// The conversation's microphone (docs/spec/3x-talk.md §4.3): takes that end by themselves when the person pauses, the
// level the dock draws, and the barge-in monitor that hears the person start talking while the bot works or speaks.
//
// `TalkCaptureCore` is the part that decides: it is fed 16 kHz mono samples and owns the take, the pre-roll and the
// barge-in monitor. `TalkEngineCapture` feeds it from one `AVAudioEngine` with voice processing; `FixtureTalkCapture`
// (DEBUG) feeds it invented samples from a script, so tests exercise the same decisions without a microphone.
// Every engine call runs on `AudioWork.queue`, never on the main thread.

import AVFAudio
import QuartzCore
import Foundation
import os
import Synchronization

nonisolated struct TalkTake: Sendable, Equatable {
    var url: URL
    var ms: Int
    var heardSpeech: Bool
    var meterFailed: Bool
    /// [live words] What heard this take as it was said (docs/spec/3x-live-words.md): its words settle with `finish()`.
    var words: (any LiveWordsListening)? = nil

    static func == (a: TalkTake, b: TalkTake) -> Bool {
        a.url == b.url && a.ms == b.ms && a.heardSpeech == b.heardSpeech && a.meterFailed == b.meterFailed
            && a.words.map(ObjectIdentifier.init) == b.words.map(ObjectIdentifier.init)
    }
}

/// Why the microphone did not start (§5.7, §6.4).
nonisolated enum TalkCaptureError: Error, Equatable, Sendable {
    case denied
    case noMicrophone
    case busy
    case failed(String)
}

@MainActor protocol TalkCapturing: AnyObject {
    /// About 30 a second, 0…1.
    var onLevel: ((Double) -> Void)? { get set }
    /// End of speech, the idle window, the longest take, or `finishTake()`.
    var onTakeEnded: ((TalkTake) -> Void)? { get set }
    var onBargeSpeech: (() -> Void)? { get set }
    var onBargeUtterance: ((TalkTake?) -> Void)? { get set }
    /// The cause and a detail for the notice.
    var onInterrupted: ((TalkPauseCause, String) -> Void)? { get set }
    /// The engine was rebuilt on a new route (AirPods connected, headphones unplugged): `playbackHost` is a new one.
    var onEngineReplaced: (() -> Void)? { get set }
    /// Permission, session, engine. Throws `TalkCaptureError`.
    func prepare() async throws
    /// [live words] `words` hears the take as it's said (nil: the gateway transcribes it).
    func beginTake(silenceMs: Int, words: (any LiveWordsListening)?)
    /// [live words] The barge-in utterance being recorded is heard by `words` too, from its first sample.
    func hearUtterance(_ words: any LiveWordsListening)
    /// Send Now: ends the take (or a barge-in utterance) with whatever was said.
    func finishTake()
    func cancelTake()
    func armBarge(multiplier: Double?, silenceMs: Int)
    func disarmBarge()
    /// Whether the bot's audio is leaving the speaker (the barge-in trigger is stricter then).
    func setPlaying(_ playing: Bool)
    func shutDown() async
    /// Where the conversation's reply is played so voice processing cancels it (nil: the speaker uses its own engine).
    var playbackHost: TalkPlaybackHost? { get }
    /// Who holds the audio session while this microphone runs: a conversation, or Voice Diagnostics' test (§9.4).
    var audioOwner: AudioSessionCoordinator.Owner { get set }
}

/// What the conversation's engine is doing now, for Voice Diagnostics' "Voice processing" row. Written on the audio queue.
nonisolated enum TalkEngineFacts {
    static let voiceProcessing = Mutex<VoiceAudioFacts.Processing>(.off)
}

/// The conversation's engine and the player node attached to it. Touched only on `AudioWork.queue`.
nonisolated final class TalkPlaybackHost: @unchecked Sendable {
    let engine: AVAudioEngine
    let player: AVAudioPlayerNode
    init(engine: AVAudioEngine, player: AVAudioPlayerNode) {
        self.engine = engine
        self.player = player
    }
}

// MARK: - The deciding part

nonisolated final class TalkCaptureCore: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        case level(Double)
        case takeEnded(TalkTake)
        case bargeSpeech
        case bargeUtterance(TalkTake?)
    }

    private struct Take {
        var endpoint: TakeEndpoint
        var samples: [Int16] = []
        var sawSignal = false
        var fedMs = 0.0
    }

    private let lock = NSLock()
    private let clock: TalkClock
    let folder: URL
    private let emit: @Sendable (Event) -> Void
    private var take: Take?
    private var monitor: BargeMonitor?
    private var utterance: [Int16]?
    private var utteranceMs = 0.0
    /// [live words] What hears the open take, and the barge-in utterance, as the samples arrive.
    private var takeWords: (any LiveWordsListening)?
    private var utteranceWords: (any LiveWordsListening)?
    private var playing = false
    private var preRoll = PreRoll()
    private var nowMs = 0.0
    private var lastLevelMs = -1_000.0
    /// Samples ever fed: the stall watchdog compares it across two looks.
    private var fed = 0

    init(clock: TalkClock = TalkClock(), folder: URL = TalkCaptureCore.takesFolder, emit: @escaping @Sendable (Event) -> Void) {
        self.clock = clock
        self.folder = folder
        self.emit = emit
    }

    static var takesFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("talk", isDirectory: true)
    }

    /// Takes left by a run that was killed (called once at launch, off the main thread).
    static func emptyTakesFolder() {
        let folder = takesFolder
        AudioWork.later { try? FileManager.default.removeItem(at: folder) }
    }

    static func discard(_ file: URL) {
        AudioWork.later { try? FileManager.default.removeItem(at: file) }
    }

    var samplesFed: Int { lock.withLock { fed } }
    var isTakeOpen: Bool { lock.withLock { take != nil } }

    /// 16 kHz mono samples, in order. Called from the engine's tap (or the fixture's timer).
    func feed(_ samples: UnsafeBufferPointer<Int16>) {
        guard !samples.isEmpty else { return }
        let ms = Double(samples.count) / 16
        let rms = TalkLevel.rms(samples)
        let level = TalkLevel.level(rms: rms)
        var events: [Event] = []
        var saves: [Save] = []
        var hearing: (any LiveWordsListening)?
        lock.lock()
        nowMs += ms
        fed += samples.count
        if nowMs - lastLevelMs >= 30 {
            lastLevelMs = nowMs
            events.append(.level(level))
        }
        if take != nil {
            hearing = takeWords
            // [perf] In place: a copy out of `take` shares the buffer, so every append would copy the whole take.
            take!.samples.append(contentsOf: samples)
            take!.fedMs += ms
            if rms > 0 { take!.sawSignal = true }
            if take!.endpoint.feed(level: level, ms: ms) != nil {
                let open = take!
                take = nil
                events.append(.takeEnded(finish(open, write: open.endpoint.heardSpeech, saves: &saves)))
            }
        } else if var watching = monitor {
            if utterance != nil {
                hearing = utteranceWords
                utterance?.append(contentsOf: samples)
                utteranceMs += ms
            } else {
                preRoll.append(samples)
            }
            switch watching.feed(level: level, now: nowMs, playing: playing) {
            case .speech:
                utterance = preRoll.take()
                utteranceMs = Double(utterance?.count ?? 0) / 16
                monitor = watching
                events.append(.bargeSpeech)
            case .utteranceEnded:
                monitor = nil
                events.append(.bargeUtterance(finishUtterance(saves: &saves)))
            case nil:
                monitor = watching
            }
        } else {
            preRoll.append(samples)
        }
        lock.unlock()
        // [live words] Outside the lock: a listener only queues the samples, but the tap never waits on it.
        hearing?.feed(samples)
        write(saves)
        for event in events { emit(event) }
    }

    func beginTake(silenceMs: Int, words: (any LiveWordsListening)? = nil) {
        let dropped = lock.withLock { () -> [any LiveWordsListening] in
            let dropped = [takeWords, utteranceWords].compactMap { $0 }
            takeWords = words
            utteranceWords = nil
            monitor = nil
            utterance = nil
            var open = Take(endpoint: TakeEndpoint(silenceMs: Double(silenceMs), clock: clock))
            // [perf] Room for 10 s up front, so a typical take never reallocates on the tap thread.
            open.samples.reserveCapacity(min(160_000, Int(clock.longestTakeMs * 16)))
            take = open
            return dropped
        }
        dropped.forEach { $0.cancel() }
    }

    /// [live words] `words` hears the barge-in utterance being recorded: what it has so far (its pre-roll first), then
    /// each new sample. Nothing being recorded (it ended already): `words` is cancelled.
    func hearUtterance(_ words: any LiveWordsListening) {
        let attached = lock.withLock { () -> Bool in
            guard let samples = utterance, utteranceWords == nil else { return false }
            utteranceWords = words
            // Under the lock, so no newer sample can reach the listener before these.
            samples.withUnsafeBufferPointer { words.feed($0) }
            return true
        }
        if !attached { words.cancel() }
    }

    /// Send Now. An open take is ended as it is; a barge-in utterance being recorded is ended too.
    func finishTake() {
        var event: Event?
        var saves: [Save] = []
        lock.lock()
        if let open = take {
            take = nil
            event = .takeEnded(finish(open, write: true, saves: &saves))
        } else if utterance != nil {
            monitor = nil
            event = .bargeUtterance(finishUtterance(saves: &saves))
        }
        lock.unlock()
        write(saves)
        if let event { emit(event) }
    }

    func cancelTake() {
        let dropped = lock.withLock { () -> [any LiveWordsListening] in
            var dropped = [takeWords].compactMap { $0 }
            take = nil
            takeWords = nil
            if utterance != nil {
                utterance = nil
                monitor = nil
                dropped += [utteranceWords].compactMap { $0 }
                utteranceWords = nil
            }
            return dropped
        }
        dropped.forEach { $0.cancel() }
    }

    func armBarge(multiplier: Double?, silenceMs: Int) {
        let dropped = lock.withLock { () -> (any LiveWordsListening)? in
            guard take == nil else { return nil }
            defer { utteranceWords = nil }
            utterance = nil
            monitor = BargeMonitor(multiplier: multiplier, silenceMs: Double(silenceMs))
            return utteranceWords
        }
        dropped?.cancel()
    }

    /// The monitor goes; an utterance already being recorded finishes.
    func disarmBarge() {
        lock.withLock { if utterance == nil { monitor = nil } }
    }

    func setPlaying(_ playing: Bool) { lock.withLock { self.playing = playing } }

    /// The microphone gave nothing: the open take ends as a meter failure (the loop drops it, §4.2 rule 2).
    func stallTake() {
        var event: Event?
        var saves: [Save] = []
        lock.lock()
        if var open = take {
            take = nil
            open.sawSignal = false
            var ended = finish(open, write: false, saves: &saves)
            ended.words?.cancel()
            ended.words = nil
            event = .takeEnded(ended)
        }
        lock.unlock()
        if let event { emit(event) }
    }

    func reset() {
        let dropped = lock.withLock { () -> [any LiveWordsListening] in
            let dropped = [takeWords, utteranceWords].compactMap { $0 }
            take = nil
            monitor = nil
            utterance = nil
            takeWords = nil
            utteranceWords = nil
            playing = false
            return dropped
        }
        dropped.forEach { $0.cancel() }
    }

    /// A WAV to write once the lock is let go, before its event goes out.
    private typealias Save = (samples: [Int16], url: URL)

    /// Called with the lock held. The file is only queued in `saves`: encoding and writing it under the lock would hold
    /// up the tap and a main-thread `isTakeOpen`/`setPlaying` waiting on it.
    private func finish(_ open: Take, write: Bool, saves: inout [Save]) -> TalkTake {
        let url = folder.appendingPathComponent(UUID().uuidString.lowercased() + ".wav")
        if write, !open.samples.isEmpty { saves.append((open.samples, url)) }
        defer { takeWords = nil }
        return TalkTake(url: url, ms: Int(open.fedMs), heardSpeech: open.endpoint.heardSpeech, meterFailed: !open.sawSignal, words: takeWords)
    }

    /// Called with the lock held; the file is queued in `saves` as in `finish`.
    private func finishUtterance(saves: inout [Save]) -> TalkTake? {
        let words = utteranceWords
        defer {
            utterance = nil
            utteranceWords = nil
        }
        guard let samples = utterance, !samples.isEmpty else {
            words?.cancel()
            return nil
        }
        let url = folder.appendingPathComponent(UUID().uuidString.lowercased() + ".wav")
        saves.append((samples, url))
        return TalkTake(url: url, ms: Int(utteranceMs), heardSpeech: true, meterFailed: false, words: words)
    }

    /// Called without the lock: each file is new (a fresh UUID), so writes never race.
    private func write(_ saves: [Save]) {
        for item in saves { save(item.samples, to: item.url) }
    }

    private func save(_ samples: [Int16], to url: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? TalkWave.file(samples).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

// MARK: - What both captures share

/// The callbacks, the core and the stall watchdog. Subclasses bring the samples.
@MainActor class TalkCaptureBase: TalkCapturing {
    var onLevel: ((Double) -> Void)?
    var onTakeEnded: ((TalkTake) -> Void)?
    var onBargeSpeech: (() -> Void)?
    var onBargeUtterance: ((TalkTake?) -> Void)?
    var onInterrupted: ((TalkPauseCause, String) -> Void)?
    var onEngineReplaced: (() -> Void)?
    var playbackHost: TalkPlaybackHost? { nil }

    let clock: TalkClock
    private(set) var core: TalkCaptureCore!
    private var watchdog: Timer?
    private var lastFed = 0
    private var stalledSince: CFTimeInterval?
    private(set) var isShutDown = false
    /// Who holds the audio session while this microphone runs: a conversation, or Voice Diagnostics' 3 s test (§9.4).
    var audioOwner: AudioSessionCoordinator.Owner = .conversation
    /// A take that gets no samples for this long ends as a meter failure.
    static let stallAfter: TimeInterval = 0.6

    init(clock: TalkClock) {
        self.clock = clock
        core = TalkCaptureCore(clock: clock) { [weak self] event in
            // The main queue keeps the tap's order.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.deliver(event) } }
        }
    }

    private func deliver(_ event: TalkCaptureCore.Event) {
        guard !isShutDown else {
            if case .takeEnded(let take) = event { TalkCaptureCore.discard(take.url); take.words?.cancel() }
            if case .bargeUtterance(let take?) = event { TalkCaptureCore.discard(take.url); take.words?.cancel() }
            return
        }
        switch event {
        case .level(let level): onLevel?(level)
        case .takeEnded(let take): onTakeEnded?(take)
        case .bargeSpeech: onBargeSpeech?()
        case .bargeUtterance(let take): onBargeUtterance?(take)
        }
    }

    func prepare() async throws {}

    func beginTake(silenceMs: Int, words: (any LiveWordsListening)?) {
        core.beginTake(silenceMs: silenceMs, words: words)
        lastFed = core.samplesFed
        stalledSince = nil
        startWatchdog()
        takeBegan()
    }

    func hearUtterance(_ words: any LiveWordsListening) { core.hearUtterance(words) }

    func finishTake() { core.finishTake() }

    func cancelTake() {
        core.cancelTake()
        takeCancelled()
    }

    func armBarge(multiplier: Double?, silenceMs: Int) {
        core.armBarge(multiplier: multiplier, silenceMs: silenceMs)
        bargeArmed()
    }

    func disarmBarge() { core.disarmBarge() }
    func setPlaying(_ playing: Bool) { core.setPlaying(playing) }

    func shutDown() async {
        isShutDown = true
        watchdog?.invalidate()
        watchdog = nil
        core.reset()
    }

    // Hooks for the fixture.
    func takeBegan() {}
    func takeCancelled() {}
    func bargeArmed() {}

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkStall() } }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func checkStall() {
        guard core.isTakeOpen else { stalledSince = nil; return }
        let fed = core.samplesFed
        if fed != lastFed {
            lastFed = fed
            stalledSince = nil
            return
        }
        let now = CACurrentMediaTime()
        guard let since = stalledSince else { stalledSince = now; return }
        if now - since >= Self.stallAfter {
            stalledSince = nil
            VoiceEvents.note("microphone gave no audio for \(Int(Self.stallAfter * 1000)) ms")
            core.stallTake()
        }
    }
}

// MARK: - The real microphone

@MainActor final class TalkEngineCapture: TalkCaptureBase {
    nonisolated static let signposts = OSSignposter(subsystem: Signposts.subsystem, category: "talk")
    private let box = TalkEngineBox()
    private var observers: [any NSObjectProtocol] = []
    private var restarting = false

    override var playbackHost: TalkPlaybackHost? { box.host }

    override func prepare() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else { throw TalkCaptureError.denied }
        case .denied:
            throw TalkCaptureError.denied
        default:
            break
        }
        // Ended while iOS asked for the microphone, or while the session came up (End during "Starting…"): `shutDown`
        // has run, so nothing may start after it (the engine left the microphone on and other apps' audio paused).
        guard !isShutDown else { return }
        let interval = Self.signposts.beginInterval("talk.start")
        defer { Self.signposts.endInterval("talk.start", interval) }
        let grant: Int
        do {
            grant = try await AudioSessionCoordinator.shared.acquire(audioOwner)
        } catch {
            throw TalkCaptureError.failed(Self.describe(error))
        }
        guard !isShutDown else { AudioSessionCoordinator.shared.releaseAbandoned(audioOwner, grant: grant); return }
        let box = self.box, core = self.core!
        do {
            try await AudioWork.run { try box.start(core: core) }
        } catch let error as TalkCaptureError {
            throw error
        } catch {
            throw TalkCaptureError.failed(Self.describe(error))
        }
        guard !isShutDown else {
            await AudioWork.perform { box.stop() }
            AudioSessionCoordinator.shared.releaseAbandoned(audioOwner, grant: grant)
            return
        }
        observe()
    }

    override func shutDown() async {
        await super.shutDown()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let box = self.box
        await AudioWork.perform { box.stop() }
        AudioSessionCoordinator.shared.release(audioOwner)
    }

    nonisolated static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return VoiceReport.scrub("\(ns.localizedDescription) (\(ns.domain) \(ns.code))")
    }

    private func observe() {
        let center = NotificationCenter.default
        // The engine stops itself when the hardware changes (a headset, a sample-rate switch). Turning voice processing
        // on posts this too while the engine keeps running: rebuilding then turned it on again, which posted again, and
        // the microphone never ran long enough to be heard (build 303). A running engine is left alone.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart(why: "engine configuration changed", onlyIfStopped: true) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                self.restart(why: "the audio route changed")
            }
        })
    }

    private enum RestartOutcome: Sendable { case keptRunning, resumed, rebuilt, failed(String) }

    /// One retry on the new route. No input left, or the engine will not start again: the conversation pauses.
    /// A configuration change (`onlyIfStopped`) leaves a running engine alone and starts a stopped one again as it is
    /// before building a new one, which would turn voice processing on again and post another change.
    private func restart(why: String, onlyIfStopped: Bool = false) {
        guard !isShutDown, !restarting else { return }
        restarting = true
        let box = self.box, core = self.core!
        Task { [weak self] in
            let outcome: RestartOutcome = await AudioWork.perform {
                if onlyIfStopped {
                    if box.isRunning { return .keptRunning }
                    if box.resume() { return .resumed }
                }
                if AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty, AVAudioSession.sharedInstance().availableInputs?.isEmpty != false {
                    return .failed("no microphone is connected")
                }
                box.stop()
                do {
                    try box.start(core: core)
                    return .rebuilt
                } catch {
                    return .failed(TalkEngineCapture.describe(error))
                }
            }
            guard let self else { return }
            self.restarting = false
            guard !self.isShutDown else { return }
            switch outcome {
            case .keptRunning:
                VoiceEvents.note("microphone kept running: \(why)")
            case .resumed:
                VoiceEvents.note("microphone started again: \(why)")
            case .rebuilt:
                VoiceEvents.note("microphone restart: \(why)")
                self.onEngineReplaced?()
            case .failed(let failure):
                VoiceEvents.note("microphone restart: \(why)")
                self.onInterrupted?(.routeLost, failure)
            }
        }
    }
}

/// The engine, its tap and the reply's player node. Made, driven and stopped only on `AudioWork.queue`.
nonisolated final class TalkEngineBox: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let hostLock = NSLock()
    private var current: TalkPlaybackHost?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)

    var host: TalkPlaybackHost? { hostLock.withLock { current } }

    /// Whether the engine still runs after a configuration change. On `AudioWork.queue`.
    var isRunning: Bool { engine?.isRunning ?? false }

    /// Starts the stopped engine again as it is (same tap, same voice processing). On `AudioWork.queue`.
    func resume() -> Bool {
        guard let engine else { return false }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    func start(core: TalkCaptureCore) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            TalkEngineFacts.voiceProcessing.withLock { $0 = .on }
        } catch {
            // Not fatal (§4.3): the engine runs without it and the playback clamp still guards against echo.
            TalkEngineFacts.voiceProcessing.withLock { $0 = .unavailable }
            VoiceEvents.noteLater("voice processing unavailable: \(TalkEngineCapture.describe(error))")
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw TalkCaptureError.noMicrophone }
        guard let target, let converter = AVAudioConverter(from: format, to: target) else {
            throw TalkCaptureError.failed("The microphone’s format can’t be converted.")
        }
        self.converter = converter
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.convert(buffer, into: core)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            let ns = error as NSError
            // 561017449 ('!pri'): another app holds the microphone at a higher priority.
            if ns.code == 561_017_449 || ns.code == 561_145_187 { throw TalkCaptureError.busy }
            throw error
        }
        self.engine = engine
        hostLock.withLock { current = TalkPlaybackHost(engine: engine, player: player) }
    }

    func stop() {
        hostLock.withLock { current = nil }
        TalkEngineFacts.voiceProcessing.withLock { $0 = .off }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
    }

    /// On the tap's thread.
    private func convert(_ buffer: AVAudioPCMBuffer, into core: TalkCaptureCore) {
        guard let converter, let target, buffer.frameLength > 0 else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let once = BufferOnce(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            if let next = once.take() {
                state.pointee = .haveData
                return next
            }
            state.pointee = .noDataNow
            return nil
        }
        guard status != .error, out.frameLength > 0, let channels = out.int16ChannelData else { return }
        core.feed(UnsafeBufferPointer(start: channels[0], count: Int(out.frameLength)))
    }
}

/// Hands one buffer to the converter's input block, once.
nonisolated final class BufferOnce: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

// MARK: - The stand-in microphone (tests and UI tests)

#if DEBUG
/// What the stand-in microphone "hears": one step per take or per armed barge-in (`-HQDebugTalkScript`, §14.3).
nonisolated enum TalkFixtureStep: Equatable, Sendable {
    /// Speech for this many seconds, then quiet.
    case say(Double)
    case quiet
    /// Speech that only Send Now or the longest take ends.
    case hold
    case meterFail
    /// Speech while the bot works or speaks. `whenSpeaking`: it waits for the bot's audio first.
    case barge(Double, whenSpeaking: Bool)
    /// The engine does not start.
    case fail

    var isTake: Bool {
        switch self {
        case .say, .quiet, .hold, .meterFail: true
        case .barge, .fail: false
        }
    }

    /// `say:2;quiet;barge:1.5;barge-speaking:1;hold;meterfail;fail`
    static func parse(_ script: String) -> [TalkFixtureStep] {
        script.split(separator: ";").compactMap { raw in
            let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
            guard let name = parts.first else { return nil }
            let seconds = parts.count > 1 ? Double(parts[1]) ?? 1 : 1
            switch name {
            case "say": return .say(max(0.1, seconds))
            case "quiet": return .quiet
            case "hold": return .hold
            case "meterfail": return .meterFail
            case "barge": return .barge(max(0.4, seconds), whenSpeaking: false)
            case "barge-speaking": return .barge(max(0.4, seconds), whenSpeaking: true)
            case "fail": return .fail
            default: return nil
            }
        }
    }
}

@MainActor final class FixtureTalkCapture: TalkCaptureBase {
    /// The steps still to play, shared by every conversation of this launch.
    static var script: [TalkFixtureStep] = []
    static var permission = "granted"
    static var startDelay: TimeInterval = 0.08

    private var feeder: Timer?
    private var lastTick: CFTimeInterval = 0
    private var phase = 0.0
    /// What the microphone hears now: seconds of speech left, then quiet. nil amplitude feeds nothing (a dead meter).
    private var speechLeft = 0.0
    private var leadIn = 0.0
    private var dead = false
    private var holding = false
    private var playing = false
    private var pendingBarge: Double?
    private var bargeDelay = 0.0
    private var bargeWaitsForSpeaking = false

    override func prepare() async throws {
        if Self.script.first == .fail {
            Self.script.removeFirst()
            throw TalkCaptureError.failed("The stand-in microphone was told to fail.")
        }
        switch Self.permission {
        case "denied": throw TalkCaptureError.denied
        case "undetermined":
            try? await Task.sleep(for: .milliseconds(300))
            Self.permission = "granted"
        default: break
        }
        guard !isShutDown else { return }   // ended while "iOS" asked for the microphone: nothing to take
        AudioSessionCoordinator.shared.simulatedOwners.insert(audioOwner)
        let grant = (try? await AudioSessionCoordinator.shared.acquire(audioOwner)) ?? 0
        try? await Task.sleep(for: .seconds(Self.startDelay))
        guard !isShutDown else { AudioSessionCoordinator.shared.releaseAbandoned(audioOwner, grant: grant); return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        feeder = timer
    }

    override func shutDown() async {
        await super.shutDown()
        feeder?.invalidate()
        feeder = nil
        AudioSessionCoordinator.shared.release(audioOwner)
    }

    override func setPlaying(_ playing: Bool) {
        super.setPlaying(playing)
        self.playing = playing
    }

    override func takeBegan() {
        pendingBarge = nil
        dead = false
        holding = false
        speechLeft = 0
        leadIn = 0
        guard let step = Self.script.first, step.isTake else { return }   // nothing scripted: quiet
        Self.script.removeFirst()
        switch step {
        case .say(let seconds):
            leadIn = 0.25
            speechLeft = seconds
        case .hold:
            leadIn = 0.25
            holding = true
        case .meterFail:
            dead = true
        default:
            break
        }
    }

    override func takeCancelled() {
        speechLeft = 0
        holding = false
        dead = false
        pendingBarge = nil
    }

    override func bargeArmed() {
        speechLeft = 0
        holding = false
        dead = false
        guard case .barge(let seconds, let whenSpeaking)? = Self.script.first else { return }
        Self.script.removeFirst()
        pendingBarge = seconds
        bargeWaitsForSpeaking = whenSpeaking
        // Past the monitor's calibration (400 ms) and, while the bot speaks, its grace (500 ms).
        bargeDelay = 0.7
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = min(0.5, max(0, now - lastTick))
        lastTick = now
        guard elapsed > 0, !dead else { return }
        var amplitude = 0.002          // room noise: a real level, well under speech
        if let seconds = pendingBarge {
            if !bargeWaitsForSpeaking || playing { bargeDelay -= elapsed }
            if bargeDelay <= 0 {
                pendingBarge = nil
                speechLeft = seconds
            }
        } else if leadIn > 0 {
            leadIn -= elapsed
        } else if holding {
            amplitude = 0.2
        } else if speechLeft > 0 {
            speechLeft -= elapsed
            amplitude = 0.2
        }
        let count = max(1, Int(elapsed * 16_000))
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            phase += 2 * .pi * 220 / 16_000
            samples[index] = Int16(amplitude * 32_767 * sin(phase))
        }
        if phase > 2_000 * .pi { phase = phase.truncatingRemainder(dividingBy: 2 * .pi) }
        samples.withUnsafeBufferPointer { core.feed($0) }
    }
}
#endif
