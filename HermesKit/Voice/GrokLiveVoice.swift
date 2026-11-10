// The Grok Live session's transport (docs/spec/3x-grok-live.md §5): a WebSocket to xAI's realtime API opened with the
// add-on's short-lived client secret, the microphone as 24 kHz PCM16 appends, and the voice's PCM16 played through the
// same voice-processing engine (the system's echo cancellation). `GrokLiveCalls` decides what each event means.
//
// `AudioSessionCoordinator` stays the only owner of AVAudioSession (owner `.conversation`, mode `.voiceChat`).

import AVFAudio
import QuartzCore
import Foundation

@MainActor final class GrokLiveVoice: LiveVoiceTransport {
    var onEvent: ((LiveServerEvent) -> Void)?
    var onDropped: ((String) -> Void)?
    var onMicLevel: ((Double) -> Void)?
    var onSpeaking: ((Bool) -> Void)?
    private(set) var speakerLevel = 0.0

    private var calls = GrokLiveCalls()
    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var audio: GrokLiveAudio?
    private var muted = false
    private var finished = false
    private var holdsSession = false
    private var began = ContinuousClock.now
    private var openWaiter: CheckedContinuation<Bool, Never>?
    private var speaking = false
    private var lastPlaying: TimeInterval = 0
    private var levelTimer: Timer?
    /// [grok-live stages] What the session got through, for the log (docs/spec/3x-grok-live.md §5).
    private var stages = GrokLiveStages()
    private var observers: [NSObjectProtocol] = []
    private var restarting = false

    /// The voice counts as speaking while audio is queued, and this long after.
    static let speakingHangover: TimeInterval = 0.3

    func start(history: JSONValue, exchange: @escaping @MainActor (String) async throws -> String) async throws {
        AppLog.trace("voice", "grok-live transport starting")
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else { throw LiveVoiceError.denied }
        case .denied:
            throw LiveVoiceError.denied
        default:
            break
        }
        do {
            try await AudioSessionCoordinator.shared.acquire(.conversation, mode: .voiceChat)
            guard !finished else {
                AudioSessionCoordinator.shared.release(.conversation)
                throw CancellationError()
            }
            holdsSession = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AudioSessionCoordinator.shared.release(.conversation)
            AppLog.note("voice", "grok-live start failed: audio session \(AppLog.scrub(String(describing: error)))")
            throw LiveVoiceError.failed(TalkEngineCapture.describe(error))
        }
        guard AVAudioSession.sharedInstance().isInputAvailable else { throw LiveVoiceError.noMicrophone }

        let began = ContinuousClock.now
        let answer = try await exchange("")
        guard !finished else { throw CancellationError() }
        guard let session = GrokLiveSession(json: try? JSONValue.parse(Data(answer.utf8))) else {
            throw LiveVoiceError.failed("Your gateway’s Grok Live answer wasn’t understood.")
        }
        let issuedMs = AppLog.ms(since: began)
        try await connect(session)
        let openMs = AppLog.ms(since: began)
        send(GrokLiveWire.sessionUpdate(voice: session.voice, instructions: session.instructions))
        GrokLiveWire.historyItems(history).forEach { send($0) }
        watchSetup()

        let audio = GrokLiveAudio()
        self.audio = audio
        observe()
        let heard = heardHandler
        do {
            try await AudioWork.run { try audio.start(heard: heard) }
        } catch {
            AppLog.note("voice", "grok-live microphone failed: \(AppLog.scrub(String(describing: error)))")
            throw LiveVoiceError.failed(TalkEngineCapture.describe(error))
        }
        guard !finished else { throw CancellationError() }
        startLevels()
        AppLog.note("voice", "grok-live start steps: session \(issuedMs) ms, socket \(openMs - issuedMs) ms, "
            + "audio \(AppLog.ms(since: began) - openMs) ms, microphone \(audio.inputDescription)")
        // The speaker switch right after the start can stop the engine before (or without) a notification.
        Task { @MainActor [weak self] in
            for wait in [1.0, 2.0] {
                try? await Task.sleep(for: .seconds(wait))
                self?.restart(why: "check after start", onlyIfStopped: true)
            }
        }
    }

    private var heardHandler: @Sendable (Data, Double) -> Void {
        { [weak self] pcm, level in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(pcm, level: level) } }
        }
    }

    // MARK: Engine restarts

    /// The engine stops itself when the hardware changes: the loudspeaker switch the audio session makes just after the
    /// start, a headset, a sample-rate switch. Builds 647-773 never started it again, so the microphone and the voice
    /// went quiet the moment the call began (2026-11-04). Same rules as the standard engine (`TalkEngineCapture`).
    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart(why: "engine configuration changed", onlyIfStopped: true) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                self?.restart(why: "the audio route changed")
            }
        })
    }

    private enum RestartOutcome: Sendable { case keptRunning, resumed, rebuilt, failed(String) }

    /// A running engine is left alone on a configuration change (turning voice processing on posts one too); a stopped
    /// one starts again as it is, else is rebuilt once. No microphone left: the session ends as a dropped one.
    private func restart(why: String, onlyIfStopped: Bool = false) {
        guard !finished, !restarting, let audio else { return }
        restarting = true
        let heard = heardHandler
        Task { @MainActor [weak self] in
            let outcome: RestartOutcome = await AudioWork.perform {
                if onlyIfStopped {
                    if audio.isRunning { return .keptRunning }
                    if audio.resume() { return .resumed }
                }
                let session = AVAudioSession.sharedInstance()
                if session.currentRoute.inputs.isEmpty, session.availableInputs?.isEmpty != false {
                    return .failed("no microphone is connected")
                }
                audio.stop()
                do {
                    try audio.start(heard: heard)
                    return .rebuilt
                } catch {
                    return .failed(TalkEngineCapture.describe(error))
                }
            }
            guard let self else { return }
            self.restarting = false
            guard !self.finished, self.audio === audio else { return }
            switch outcome {
            case .keptRunning:
                AppLog.trace("voice", "grok-live microphone kept running: \(why)")
            case .resumed:
                AppLog.note("voice", "grok-live microphone started again: \(why)")
            case .rebuilt:
                AppLog.note("voice", "grok-live microphone rebuilt: \(why), \(audio.inputDescription)")
            case .failed(let detail):
                AppLog.note("voice", "grok-live microphone lost (\(why)): \(AppLog.scrub(detail))")
                self.onDropped?("microphone_lost")
            }
        }
    }

    /// Opens the socket and waits for its first word (`session.created`).
    private func connect(_ session: GrokLiveSession) async throws {
        self.began = ContinuousClock.now
        let urlSession = URLSession(configuration: .default)
        let socket = urlSession.webSocketTask(with: session.url, protocols: [GrokLiveWire.subprotocol(session.clientSecret)])
        socket.maximumMessageSize = 16 << 20
        self.urlSession = urlSession
        self.socket = socket
        socket.resume()
        receive(socket)
        let opened = await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
            openWaiter = waiter
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(GrokLiveWire.openTimeout))
                self?.openWaiter?.resume(returning: false)
                self?.openWaiter = nil
            }
        }
        guard !finished else { throw CancellationError() }
        guard opened else { throw LiveVoiceError.failed("Grok Live didn’t answer.") }
    }

    private func receive(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.finished, self.socket === socket else { return }
                    switch result {
                    case .success(let message):
                        switch message {
                        case .string(let text): self.received(text)
                        case .data(let data): self.received(String(decoding: data, as: UTF8.self))
                        @unknown default: break
                        }
                        self.receive(socket)
                    case .failure(let error):
                        let why = socket.closeCode == .invalid ? (error as NSError).localizedDescription : "closed \(socket.closeCode.rawValue)"
                        AppLog.note("voice", "grok-live socket dropped: \(AppLog.scrub(why))")
                        if let waiter = self.openWaiter {
                            self.openWaiter = nil
                            waiter.resume(returning: false)
                        } else {
                            self.onDropped?("connection_lost")
                        }
                    }
                }
            }
        }
    }

    /// xAI must confirm the setup (`session.updated`) within `GrokLiveWire.setupTimeout`; until then the microphone
    /// sends nothing, so a missing confirmation would leave Talk listening to no one. Not confirmed: say so and let the
    /// standard engine take over.
    private func watchSetup() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(GrokLiveWire.setupTimeout))
            guard let self, !self.finished, !self.calls.ready else { return }
            AppLog.note("voice", "grok-live setup not confirmed after \(Int(GrokLiveWire.setupTimeout)) s: "
                + "\(self.stages.summary(ready: false))")
            self.onDropped?(GrokLiveWire.setupTimeoutReason)
        }
    }

    private func received(_ raw: String) {
        guard let event = GrokServerEvent.parse(raw) else { return }
        if let line = stages.note(event, ready: calls.ready, ms: Int(AppLog.ms(since: began))) { AppLog.note("voice", line) }
        if event == .sessionCreated, let waiter = openWaiter {
            openWaiter = nil
            waiter.resume(returning: true)
        }
        if case .error(let message, let code) = event {
            AppLog.note("voice", "grok-live error \(code ?? "?"): \(AppLog.scrub(message))")
            // Before the session is set up nothing works: carry on with the standard engine.
            if !calls.ready { onDropped?(message); return }
        }
        perform(calls.receive(event, ms: Int(AppLog.ms(since: began))))
    }

    private func perform(_ actions: [GrokAction]) {
        for action in actions {
            switch action {
            case .event(let event): onEvent?(event)
            case .send(let raw): send(raw)
            case .play(let pcm):
                guard let audio else { continue }
                speakerLevel = audio.play(pcm)
                lastPlaying = CACurrentMediaTime()
                setSpeaking(true)
            case .flushPlayback:
                audio?.flush()
                speakerLevel = 0
                setSpeaking(false)
            }
        }
    }

    private func heard(_ pcm: Data, level: Double) {
        guard !finished else { return }
        onMicLevel?(level)
        guard !muted else { return }
        guard calls.ready else { stages.held += 1; return }
        if stages.sent == 0 { AppLog.note("voice", "grok-live first microphone audio sent at \(AppLog.ms(since: began)) ms") }
        stages.sent += 1
        send(GrokLiveWire.append(pcm))
    }

    func send(_ event: String) {
        guard !finished, let socket else { return }
        socket.send(.string(event)) { error in
            if let error { AppLog.trace("voice", "grok-live send failed: \((error as NSError).code)") }
        }
    }

    /// Mute stops the appends; xAI hears nothing until it is lifted.
    func setMuted(_ muted: Bool) {
        if muted != self.muted { AppLog.trace("voice", "grok-live microphone \(muted ? "muted" : "unmuted")") }
        self.muted = muted
    }

    func speak(delegationId: String?, text: String) { perform(calls.speak(delegationId: delegationId, text: text)) }
    func think(delegationId: String?, text: String) { perform(calls.think(delegationId: delegationId, text: text)) }
    func instruct(_ text: String) { perform(calls.instruct(text)) }

    func close() async {
        guard !finished else { return }
        AppLog.trace("voice", "grok-live transport stopped")
        AppLog.note("voice", "grok-live summary: \(stages.summary(ready: calls.ready))")
        finished = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        openWaiter?.resume(returning: false)
        openWaiter = nil
        levelTimer?.invalidate()
        levelTimer = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        urlSession?.finishTasksAndInvalidate()
        urlSession = nil
        if let audio {
            self.audio = nil
            await AudioWork.perform { audio.stop() }
        }
        if speaking { speaking = false; onSpeaking?(false) }
        if holdsSession {
            holdsSession = false
            AudioSessionCoordinator.shared.release(.conversation)
        }
    }

    // MARK: Speaking

    private func startLevels() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pollPlayback() } }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func pollPlayback() {
        guard let audio, !finished else { return }
        let now = CACurrentMediaTime()
        if audio.isPlaying { lastPlaying = now } else { speakerLevel *= 0.5 }
        setSpeaking(now - lastPlaying < Self.speakingHangover)
    }

    private func setSpeaking(_ on: Bool) {
        guard on != speaking else { return }
        speaking = on
        onSpeaking?(on)
    }
}

/// The microphone and the speaker: one AVAudioEngine with voice processing on its input. Start and stop on
/// `AudioWork.queue`; `play` and `flush` from anywhere.
nonisolated final class GrokLiveAudio: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let lock = NSLock()
    private var queued = 0
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: GrokLiveWire.sampleRate, channels: 1, interleaved: true)!
    private let voiceFormat = AVAudioFormat(standardFormatWithSampleRate: GrokLiveWire.sampleRate, channels: 1)!

    var isPlaying: Bool { lock.withLock { queued > 0 } }

    /// Whether the engine still runs after a configuration change. On `AudioWork.queue`.
    var isRunning: Bool { engine?.isRunning ?? false }

    /// The microphone's format and whether voice processing took, for the log.
    private(set) var inputDescription = "not started"

    /// Starts the stopped engine again as it is (same tap, same voice processing). On `AudioWork.queue`.
    func resume() -> Bool {
        guard let engine, let player else { return false }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            return false
        }
        player.play()
        return true
    }

    /// `heard` gets each piece of the microphone as PCM16 mono 24 kHz little-endian, with its level (0…1).
    func start(heard: @escaping @Sendable (Data, Double) -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var processing = "voice processing on"
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            processing = "no voice processing"
            VoiceEvents.noteLater("grok-live voice processing unavailable: \(TalkEngineCapture.describe(error))")
        }
        let format = input.outputFormat(forBus: 0)
        inputDescription = "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(processing)"
        guard format.sampleRate > 0, format.channelCount > 0 else { throw LiveVoiceError.noMicrophone }
        let target = micFormat
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw LiveVoiceError.failed("The microphone’s format can’t be converted.")
        }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: voiceFormat)
        // About 100 ms a piece at the hardware's rate.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, _ in
            guard buffer.frameLength > 0 else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            let once = BufferOnce(buffer)
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, state in
                if let next = once.take() { state.pointee = .haveData; return next }
                state.pointee = .noDataNow
                return nil
            }
            guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return }
            let samples = UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))
            heard(Data(buffer: samples), TalkLevel.level(rms: TalkLevel.rms(samples)))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        player.play()
        self.engine = engine
        self.player = player
    }

    /// Queues one piece of the voice (PCM16 mono 24 kHz little-endian); answers its level.
    func play(_ pcm: Data) -> Double {
        guard let player else { return 0 }
        let count = pcm.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: voiceFormat, frameCapacity: AVAudioFrameCount(count)),
              let out = buffer.floatChannelData?[0] else { return 0 }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                out[index] = Float(sample) / 32_768
            }
        }
        lock.withLock { queued += 1 }
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.queued = max(0, self.queued - 1) }
        }
        return TalkLevel.level(rms: TalkLevel.rms(UnsafeBufferPointer(start: out, count: count)))
    }

    /// Stops the voice now: everything queued is dropped, the player is ready for the next answer.
    func flush() {
        guard let player else { return }
        player.stop()
        lock.withLock { queued = 0 }
        player.play()
    }

    func stop() {
        guard let engine else { return }
        player?.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        player = nil
        lock.withLock { queued = 0 }
    }
}

#if DEBUG
/// Tests: a scripted Grok Live session. `script` is played (raw xAI events) once the add-on's answer is in.
@MainActor final class FixtureGrokLiveVoice: LiveVoiceTransport {
    var onEvent: ((LiveServerEvent) -> Void)?
    var onDropped: ((String) -> Void)?
    var onMicLevel: ((Double) -> Void)?
    var onSpeaking: ((Bool) -> Void)?
    var speakerLevel = 0.0

    static var failWith: LiveVoiceError?
    static var script: [(after: TimeInterval, raw: String)] = [(0.1, #"{"type":"session.updated"}"#)]
    /// Everything any fixture session sent, oldest first.
    static var sent: [String] = []
    static var flushes = 0
    static var played = 0
    static var sessions: [GrokLiveSession] = []

    private var calls = GrokLiveCalls()
    private var muted = false
    private var closed = false

    func start(history: JSONValue, exchange: @escaping @MainActor (String) async throws -> String) async throws {
        if let error = Self.failWith { throw error }
        let answer = try await exchange("")
        guard let session = GrokLiveSession(json: try? JSONValue.parse(Data(answer.utf8))) else {
            throw LiveVoiceError.failed("Your gateway’s Grok Live answer wasn’t understood.")
        }
        Self.sessions.append(session)
        send(GrokLiveWire.sessionUpdate(voice: session.voice, instructions: session.instructions))
        GrokLiveWire.historyItems(history).forEach { send($0) }
        for step in Self.script {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(step.after))
                self?.play(step.raw)
            }
        }
    }

    func send(_ event: String) { Self.sent.append(event) }
    func setMuted(_ muted: Bool) { self.muted = muted }
    func speak(delegationId: String?, text: String) { perform(calls.speak(delegationId: delegationId, text: text)) }
    func think(delegationId: String?, text: String) { perform(calls.think(delegationId: delegationId, text: text)) }
    func instruct(_ text: String) { perform(calls.instruct(text)) }

    func close() async { closed = true }

    /// One microphone piece, as the engine would hand it over (sent only while unmuted).
    func hear(_ pcm: Data) {
        guard !closed, !muted, calls.ready else { return }
        send(GrokLiveWire.append(pcm))
    }

    /// Plays one xAI event now.
    func play(_ raw: String) {
        guard !closed, let event = GrokServerEvent.parse(raw) else { return }
        perform(calls.receive(event, ms: 0))
    }

    private func perform(_ actions: [GrokAction]) {
        for action in actions {
            switch action {
            case .event(let event): onEvent?(event)
            case .send(let raw): send(raw)
            case .play: Self.played += 1
            case .flushPlayback: Self.flushes += 1
            }
        }
    }
}
#endif
