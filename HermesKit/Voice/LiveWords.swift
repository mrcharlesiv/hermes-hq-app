// Words as you speak (docs/spec/3x-live-words.md). Apple's on-device speech engine (`SpeechAnalyzer` with
// `SpeechTranscriber`, or `DictationTranscriber` on a device that doesn't offer it) hears the same samples a voice memo
// or a Talk take records and says the words so far while the person speaks. The words it settles on are what goes: a
// memo carries them (no paid transcription), and a Talk turn is sent without the gateway's speech to text.
//
// Anything that keeps this from working (Live Words off, a language or device it doesn't support, the model still
// downloading, an error while listening) leaves the old way: the gateway turns the recording into text once it ends.
// Never logs the words: VoiceEvents and AppLog get short facts only.

import AVFAudio
import Foundation
import Speech
import Synchronization

/// What has been heard so far: the words the engine settled on, then the ones it may still change.
nonisolated struct LiveWordsText: Equatable, Sendable {
    var settled = ""
    var pending = ""

    var whole: String { Self.join(settled, pending) }
    var isEmpty: Bool { whole.isEmpty }

    /// Two runs of words with one space between them (the engine's segments carry their own spacing, or none).
    static func join(_ head: String, _ tail: String) -> String {
        let a = head.trimmingCharacters(in: .whitespacesAndNewlines), b = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}

/// One listening: fed samples from any thread, the words out on the main actor as they change.
nonisolated protocol LiveWordsListening: AnyObject, Sendable {
    /// 16 kHz mono samples, in order (a tap's thread, the fixture's timer).
    func feed(_ samples: UnsafeBufferPointer<Int16>)
    /// Stops listening and settles the words ("" when none were heard or the engine failed). Never waits longer than
    /// `LiveWords.settleLimit`: past it, the words heard so far.
    func finish() async -> String
    /// Stops listening; the words are thrown away.
    func cancel()
}

@MainActor enum LiveWords {
    /// Settings › Voice › Live Words (on unless turned off).
    static let settingKey = "hq.voice.liveWords"
    static var isOn: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    /// The longest a take's end waits for the engine to settle its words (it takes ~0.1 s; the gateway took seconds).
    nonisolated static let settleLimit: Double = 1.5
    /// The samples every listener is fed: what `TalkCaptureCore` and `LiveWordsMic` give.
    nonisolated static let sampleRate: Double = 16_000

    /// Where this device stands, checked once per launch (`prepare`).
    nonisolated enum Readiness: Equatable, Sendable {
        case unknown, checking, downloading
        case ready(LiveWordsEngine)
        /// Short facts for Voice Diagnostics ("language not offered", "device not supported", the error).
        case unavailable(String)
    }

    private(set) static var readiness: Readiness = .unknown
    /// Posted when `readiness` changes.
    static let readinessChanged = Notification.Name("hq.voice.liveWords.readiness")

    #if DEBUG
    /// `-HQDebugLiveWords "<words>"`: every listening "hears" these words, a few a second (simulators have no engine).
    static var debugScript: String?
    /// `-HQDebugLiveWordsFile <wav>`: a memo's live words come from this recording instead of the microphone.
    static var debugFile: URL?
    #endif

    /// Whether listeners can start now (Live Words on and the engine ready).
    static var canListen: Bool {
        #if DEBUG
        if debugScript != nil { return isOn }
        #endif
        if case .ready = readiness { return isOn }
        return false
    }

    /// Checks whether this device can hear words in the person's language, and starts the model's download when that's
    /// all it lacks (Apple's shared model: other apps may have it already). Cheap once checked.
    static func prepare() {
        guard isOn, readiness == .unknown else { return }
        #if DEBUG
        if debugScript != nil { return }
        #endif
        set(.checking)
        Task {
            let found = await LiveWordsEngine.find()
            set(found)
            if found == .downloading {
                let installed = await LiveWordsEngine.download()
                set(installed)
            }
        }
    }

    /// A new listening, or nil when Live Words is off or can't run here (the gateway's speech to text is used then).
    /// `onText` gets the words each time they change, on the main actor.
    /// The words, shown and settled, are tidied: no "uh" or "um", the person's fixes and names written (`LiveWordsTidy`).
    static func listen(onText: @escaping @MainActor (LiveWordsText) -> Void) -> (any LiveWordsListening)? {
        guard isOn else { return nil }
        let tidy = LiveWordsVocabulary.tidy()
        let shown: @MainActor (LiveWordsText) -> Void = { onText(tidy.apply($0)) }
        #if DEBUG
        if let debugScript { return TidiedLiveWords(ScriptedLiveWords(script: debugScript, onText: shown), tidy: tidy) }
        #endif
        guard case .ready(let engine) = readiness else {
            prepare()
            return nil
        }
        return TidiedLiveWords(SpeechLiveWords(engine: engine, onText: shown), tidy: tidy)
    }

    /// One fact for Voice Diagnostics.
    static var diagnosticsLine: String {
        guard isOn else { return "off" }
        switch readiness {
        case .unknown: return "not checked yet"
        case .checking: return "checking"
        case .downloading: return "downloading the speech model"
        case .ready(let engine): return "on this device (\(engine.locale.identifier)\(engine.dictation ? ", dictation model" : ""))"
        case .unavailable(let why): return "gateway (\(why))"
        }
    }

    private static func set(_ value: Readiness) {
        guard readiness != value else { return }
        readiness = value
        // AppLog, not VoiceEvents: the check runs by itself (a chat opening), not in a voice action's order of events.
        if case .unavailable(let why) = value { AppLog.note("voice", "live words unavailable: \(why)") }
        if case .ready(let engine) = value { AppLog.trace("voice", "live words ready (\(engine.locale.identifier)\(engine.dictation ? ", dictation model" : ""))") }
        NotificationCenter.default.post(name: readinessChanged, object: nil)
    }

    #if DEBUG
    /// Tests: start from scratch.
    static func resetForTests(_ value: Readiness = .unknown) { readiness = value }
    #endif
}

/// The language and model a listener uses, and the sample format the engine wants.
nonisolated struct LiveWordsEngine: Equatable, @unchecked Sendable {
    var locale: Locale
    /// `DictationTranscriber`: the device doesn't offer `SpeechTranscriber`.
    var dictation: Bool
    var format: AVAudioFormat

    static func == (a: LiveWordsEngine, b: LiveWordsEngine) -> Bool {
        a.locale == b.locale && a.dictation == b.dictation && a.format == b.format
    }

    /// The model for `locale` (nothing heard yet).
    func module() -> any SpeechModule { Self.module(locale: locale, dictation: dictation) }

    static func module(locale: Locale, dictation: Bool) -> any SpeechModule {
        dictation
            ? DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            : SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    /// The first of the person's languages (the app's own, then the phone's list) the device can hear.
    private static func pick() async -> (locale: Locale, dictation: Bool)? {
        let dictation = !SpeechTranscriber.isAvailable
        var wanted = [Locale.current]
        for id in Locale.preferredLanguages.prefix(4) { wanted.append(Locale(identifier: id)) }
        for wish in wanted {
            let found = dictation ? await DictationTranscriber.supportedLocale(equivalentTo: wish)
                : await SpeechTranscriber.supportedLocale(equivalentTo: wish)
            if let found { return (found, dictation) }
        }
        return nil
    }

    /// The language to hear, and whether its model is installed.
    static func find() async -> LiveWords.Readiness {
        guard let (locale, dictation) = await pick() else { return .unavailable("language not offered") }
        let module = module(locale: locale, dictation: dictation)
        switch await AssetInventory.status(forModules: [module]) {
        case .unsupported: return .unavailable("device not supported")
        case .supported, .downloading: return .downloading
        case .installed:
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                return .unavailable("no audio format")
            }
            return .ready(LiveWordsEngine(locale: locale, dictation: dictation, format: format))
        @unknown default: return .unavailable("unknown model status")
        }
    }

    /// Installs the model `find` said was missing, then checks again.
    static func download() async -> LiveWords.Readiness {
        guard let (locale, dictation) = await pick() else { return .unavailable("language not offered") }
        do {
            // The app asks for the language first: the system installs models only for languages an app reserved.
            _ = try? await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module(locale: locale, dictation: dictation)]) {
                try await request.downloadAndInstall()
            }
        } catch {
            return .unavailable("model download failed (\((error as NSError).domain) \((error as NSError).code))")
        }
        return await find()
    }
}

// MARK: - The engine

/// One `SpeechAnalyzer` for one take. Samples are queued as they come (the analyzer starts a moment later and catches up),
/// converted to the engine's format when it isn't 16 kHz mono Int16.
nonisolated final class SpeechLiveWords: LiveWordsListening, @unchecked Sendable {
    private struct State {
        var text = LiveWordsText()
        var closed = false
        var failed = false
    }

    /// Shared with the tasks that read results and settle the words (a `Mutex` can't be shared by reference).
    private final class Shared: @unchecked Sendable {
        private let lock = NSLock()
        private var value = State()
        func withLock<T>(_ body: (inout State) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    private let state = Shared()
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzer: SpeechAnalyzer
    private let converter: AVAudioConverter?
    private let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: LiveWords.sampleRate, channels: 1, interleaved: true)!
    private let target: AVAudioFormat
    private let converterLock = NSLock()
    private var reading: Task<Void, Never>?
    private var starting: Task<Void, Never>?

    init(engine: LiveWordsEngine, onText: @escaping @MainActor (LiveWordsText) -> Void) {
        let module = engine.module()
        target = engine.format
        converter = engine.format == source ? nil : AVAudioConverter(from: source, to: engine.format)
        analyzer = SpeechAnalyzer(modules: [module], options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        let state = self.state
        let heard: @Sendable (String, Bool) -> Void = { words, final in
            let text = state.withLock { s -> LiveWordsText? in
                guard !s.closed || final else { return nil }
                if final {
                    s.text.settled = LiveWordsText.join(s.text.settled, words)
                    s.text.pending = ""
                } else {
                    s.text.pending = words
                }
                return s.text
            }
            if let text { Task { @MainActor in onText(text) } }
        }
        reading = Task.detached(priority: .userInitiated) {
            do {
                if let speech = module as? SpeechTranscriber {
                    for try await result in speech.results { heard(String(result.text.characters), result.isFinal) }
                } else if let dictation = module as? DictationTranscriber {
                    for try await result in dictation.results { heard(String(result.text.characters), result.isFinal) }
                }
            } catch is CancellationError {
            } catch {
                state.withLock { $0.failed = true }
                VoiceEvents.noteLater("live words stopped (\((error as NSError).domain) \((error as NSError).code))")
            }
        }
        let analyzer = self.analyzer, format = engine.format
        starting = Task.detached(priority: .userInitiated) {
            do {
                try await analyzer.prepareToAnalyze(in: format)
                try await analyzer.start(inputSequence: stream)
            } catch {
                state.withLock { $0.failed = true }
                VoiceEvents.noteLater("live words didn’t start (\((error as NSError).domain) \((error as NSError).code))")
            }
        }
    }

    func feed(_ samples: UnsafeBufferPointer<Int16>) {
        guard !samples.isEmpty, !state.withLock({ $0.closed || $0.failed }),
              let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.int16ChannelData?[0], let base = samples.baseAddress else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        channel.update(from: base, count: samples.count)
        guard let converter else {
            input.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let capacity = AVAudioFrameCount(Double(samples.count) * target.sampleRate / source.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let once = BufferOnce(buffer)
        var error: NSError?
        let status = converterLock.withLock {
            converter.convert(to: out, error: &error) { _, state in
                if let next = once.take() {
                    state.pointee = .haveData
                    return next
                }
                state.pointee = .noDataNow
                return nil
            }
        }
        guard status != .error, out.frameLength > 0 else { return }
        input.yield(AnalyzerInput(buffer: out))
    }

    func finish() async -> String {
        let already = state.withLock { s -> Bool in
            defer { s.closed = true }
            return s.closed
        }
        guard !already else { return state.withLock { $0.text.whole } }
        input.finish()
        let analyzer = self.analyzer, starting = self.starting, reading = self.reading, state = self.state
        return await LiveWordsWait.first(within: LiveWords.settleLimit, otherwise: { state.withLock { $0.text.whole } }) {
            await starting?.value
            if !state.withLock({ $0.failed }) { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
            await reading?.value
            return state.withLock { $0.failed && $0.text.isEmpty ? "" : $0.text.whole }
        }
    }

    func cancel() {
        let already = state.withLock { s -> Bool in
            defer { s.closed = true }
            return s.closed
        }
        guard !already else { return }
        input.finish()
        reading?.cancel()
        let analyzer = self.analyzer
        Task.detached { await analyzer.cancelAndFinishNow() }
    }
}

/// The first of a piece of work and a deadline (the work isn't waited for past it).
nonisolated enum LiveWordsWait {
    static func first<T: Sendable>(within seconds: Double, otherwise: @escaping @Sendable () -> T,
                                   _ work: @escaping @Sendable () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            let once = Mutex<CheckedContinuation<T, Never>?>(continuation)
            let resume: @Sendable (T) -> Void = { value in once.withLock { $0.take() }?.resume(returning: value) }
            Task.detached { resume(await work()) }
            Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                resume(otherwise())
            }
        }
    }
}

// MARK: - A voice memo's microphone

/// A voice memo's second listener on the microphone: `MemoRecorder`'s AVAudioRecorder writes the file, and this tap
/// gives the same sound to Live Words as 16 kHz mono. No voice processing (the recorder shares the session as it is).
/// Anything that fails here only means no live words. Every call on `AudioWork.queue`.
nonisolated final class LiveWordsMic: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: LiveWords.sampleRate, channels: 1, interleaved: true)!
    #if DEBUG
    private var fileTimer: DispatchSourceTimer?
    #endif

    /// Starts feeding `listener`. False when the microphone gave no usable format or the engine didn't start.
    func start(_ listener: any LiveWordsListening) -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let converter = AVAudioConverter(from: format, to: target) else { return false }
        self.converter = converter
        let target = self.target
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard buffer.frameLength > 0 else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
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
            guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return }
            listener.feed(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            VoiceEvents.noteLater("live words microphone didn’t start (\((error as NSError).code))")
            return false
        }
        self.engine = engine
        return true
    }

    #if DEBUG
    /// `-HQDebugLiveWordsFile`: feeds a recording at its own pace (the Mac has no microphone to test with). Each tick
    /// feeds what the clock says is due, so a late timer (a busy machine) catches up instead of slowing the speech.
    func start(file: URL, _ listener: any LiveWordsListening) -> Bool {
        guard let audio = try? AVAudioFile(forReading: file),
              let converter = AVAudioConverter(from: audio.processingFormat, to: target) else { return false }
        let timer = DispatchSource.makeTimerSource(queue: AudioWork.queue)
        let target = self.target, chunk: AVAudioFrameCount = 1600, rate = audio.processingFormat.sampleRate
        let started = DispatchTime.now().uptimeNanoseconds
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            let due = min(audio.length, AVAudioFramePosition(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 * rate))
            while audio.framePosition < due {
                let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), due - audio.framePosition))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: count),
                      (try? audio.read(into: buffer, frameCount: count)) != nil, buffer.frameLength > 0,
                      let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / rate) + 64)
                else { break }
                let once = BufferOnce(buffer)
                var error: NSError?
                _ = converter.convert(to: out, error: &error) { _, state in
                    if let next = once.take() { state.pointee = .haveData; return next }
                    state.pointee = .noDataNow
                    return nil
                }
                if out.frameLength > 0, let channel = out.int16ChannelData {
                    listener.feed(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
                }
            }
            if audio.framePosition >= audio.length { self?.fileTimer?.cancel() }
        }
        fileTimer = timer
        timer.resume()
        return true
    }
    #endif

    func stop() {
        #if DEBUG
        fileTimer?.cancel()
        fileTimer = nil
        #endif
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
    }
}

// MARK: - The stand-in (simulators: Apple's engine doesn't run there)

#if DEBUG
/// "Hears" a script, a word every 0.28 s, the newest two words pending; `finish` settles the whole script (the real
/// engine settles everything said, and tests assert the words exactly).
nonisolated final class ScriptedLiveWords: LiveWordsListening, @unchecked Sendable {
    private let words: [String]
    private let shown = Mutex(0)
    private let closed = Mutex(false)
    private let onText: @MainActor (LiveWordsText) -> Void

    init(script: String, onText: @escaping @MainActor (LiveWordsText) -> Void) {
        words = script.split(separator: " ").map(String.init)
        self.onText = onText
        Task { @MainActor [weak self] in self?.step() }
    }

    @MainActor private func step() {
        guard !closed.withLock({ $0 }) else { return }
        let count = shown.withLock { n -> Int in
            n = min(words.count, n + 1)
            return n
        }
        let settled = max(0, count - 2)
        onText(LiveWordsText(settled: words[0..<settled].joined(separator: " "), pending: words[settled..<count].joined(separator: " ")))
        guard count < words.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in MainActor.assumeIsolated { self?.step() } }
    }

    func feed(_ samples: UnsafeBufferPointer<Int16>) {}

    func finish() async -> String {
        closed.withLock { $0 = true }
        return words.joined(separator: " ")
    }

    func cancel() { closed.withLock { $0 = true } }
}
#endif
