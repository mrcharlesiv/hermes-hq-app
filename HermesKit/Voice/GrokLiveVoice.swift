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
    private var sessionGrant: Int?
    private var began = ContinuousClock.now
    private var openWaiter: CheckedContinuation<Bool, Never>?
    private var speaking = false
    private var lastPlaying: TimeInterval = 0
    private var levelTimer: Timer?
    /// [grok-live stages] What the session got through, for the log (docs/spec/3x-grok-live.md §5).
    private var stages = GrokLiveStages()
    private var observers: [NSObjectProtocol] = []
    private var restarting = false
    /// The provider can confirm setup before the audio engine has started. Deliver readiness only after both.
    private var audioStarted = false
    private var pendingStarted: LiveServerEvent?
    private var startupFailed = false
    private var startedDelivered = false
    /// When the player was last reset for queued voice that was not playing, and whether the engine was rebuilt for it.
    private var revivedAt: TimeInterval = -10
    private var rebuiltForSilence = false

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
        let coordinator = AudioSessionCoordinator.shared
        let beforeGrant = coordinator.grant
        do {
            let grant = try await coordinator.acquire(.conversation, mode: .voiceChat)
            guard !finished else {
                coordinator.releaseAbandoned(.conversation, grant: grant)
                throw CancellationError()
            }
            sessionGrant = grant
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if coordinator.owner == .conversation, coordinator.grant == beforeGrant + 1 {
                coordinator.releaseAbandoned(.conversation, grant: coordinator.grant)
            }
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
        send(GrokLiveWire.sessionUpdate(voice: session.voice, instructions: session.instructions, seeded: history.array?.isEmpty == false))
        GrokLiveWire.historyItems(history).forEach { send($0) }
        watchSetup()

        let audio = GrokLiveAudio()
        self.audio = audio
        observe()
        let heard = heardHandler
        do {
            try await AudioWork.run { try audio.start(heard: heard) }
        } catch {
            startupFailed = true
            AppLog.note("voice", "grok-live microphone failed: \(AppLog.scrub(String(describing: error)))")
            throw LiveVoiceError.failed(TalkEngineCapture.describe(error))
        }
        guard !finished else { throw CancellationError() }
        startLevels()
        audioStarted = true
        deliverStartedIfReady()
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
                let queued = audio.stop(keeping: true)
                do {
                    try audio.start(heard: heard)
                    audio.requeue(queued)
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
                if !self.startedDelivered { self.startupFailed = true }
                self.onDropped?("microphone_lost")
            }
            self.deliverStartedIfReady()
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
                            if !self.startedDelivered { self.startupFailed = true }
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
            self.startupFailed = true
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
            if !calls.ready { startupFailed = true; onDropped?(message); return }
        }
        perform(calls.receive(event, ms: Int(AppLog.ms(since: began))))
    }

    private func perform(_ actions: [GrokAction]) {
        for action in actions {
            switch action {
            case .event(let event):
                if case .started = event {
                    pendingStarted = event
                    deliverStartedIfReady()
                } else {
                    onEvent?(event)
                }
            case .send(let raw): send(raw)
            case .play(let pcm):
                guard let audio else { continue }
                speakerLevel = audio.play(pcm)
                lastPlaying = CACurrentMediaTime()
                setSpeaking(true)
            case .flushPlayback:
                stages.flushes += 1
                audio?.flush()
                speakerLevel = 0
                setSpeaking(false)
            }
        }
    }

    private func deliverStartedIfReady() {
        guard !finished, !startupFailed, !startedDelivered, !restarting, audioStarted, let event = pendingStarted else { return }
        pendingStarted = nil
        startedDelivered = true
        onEvent?(event)
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
        stages.unplayed = audio?.unplayed ?? 0
        if let played = audio?.played { stages.playedOut = played.out; stages.revived = played.revived }
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
            await AudioWork.perform { _ = audio.stop() }
        }
        if speaking { speaking = false; onSpeaking?(false) }
        if let grant = sessionGrant {
            sessionGrant = nil
            AudioSessionCoordinator.shared.releaseAbandoned(.conversation, grant: grant)
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
        unstick(audio, now: now)
    }

    /// The voice is queued and none of it is playing: the player is reset and given it again; still nothing after that,
    /// the engine is rebuilt (once a session) and given it again.
    private func unstick(_ audio: GrokLiveAudio, now: TimeInterval) {
        guard audio.isStalled, !restarting else { return }
        if now - revivedAt > 3 {
            revivedAt = now
            let pieces = audio.revive()
            AppLog.note("voice", "grok-live voice was queued and not playing: player started again with \(pieces) pieces at \(AppLog.ms(since: began)) ms")
        } else if now - revivedAt > 1, !rebuiltForSilence {
            rebuiltForSilence = true
            AppLog.note("voice", "grok-live voice still not playing: the audio engine is rebuilt")
            restart(why: "the voice was not playing")
        }
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
    /// Serializes all `AVAudioEngine`/`AVAudioPlayerNode` mutations and calls. Lock order is always `audioLock` → `lock`
    /// (buffer completion callbacks only acquire `lock`, never `audioLock`, so `player.stop()` cannot deadlock).
    private let audioLock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let lock = NSLock()
    /// The pieces of the voice queued and not yet played to their end, oldest first. Kept so a player that takes them and
    /// plays nothing can be reset and given them again (`revive`), or a rebuilt engine can (`requeue`).
    private var pending: [(id: Int, buffer: AVAudioPCMBuffer)] = []
    private var nextPiece = 0
    /// Bumped whenever the player is emptied: a completion from before then is not a piece played.
    private var generation = 0
    /// When the queue last moved (a piece ended, or the first piece joined an empty queue).
    private var progressAt: TimeInterval = 0
    private var _inputDescription = "not started"
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: GrokLiveWire.sampleRate, channels: 1, interleaved: true)!
    private let voiceFormat = AVAudioFormat(standardFormatWithSampleRate: GrokLiveWire.sampleRate, channels: 1)!

    var isPlaying: Bool { lock.withLock { !pending.isEmpty } }

    /// The head piece should have ended by now and has not: the player took the audio and is playing none of it. The
    /// owner's phone, builds 1058-1067: after the engine's own restart at a start (the loudspeaker switch), the hello was
    /// queued and stayed queued, "voice pieces played out 0"; it had only ever played once the person spoke, because a
    /// barge-in resets the player.
    static let stallGrace: TimeInterval = 0.6
    var isStalled: Bool {
        lock.withLock {
            guard let head = pending.first else { return false }
            let length = Double(head.buffer.frameLength) / head.buffer.format.sampleRate
            return CACurrentMediaTime() - progressAt > length + Self.stallGrace
        }
    }

    /// Whether the engine still runs after a configuration change.
    var isRunning: Bool { audioLock.withLock { engine?.isRunning ?? false } }

    /// The microphone's format and whether voice processing took, for the log.
    var inputDescription: String { lock.withLock { _inputDescription } }

    /// Starts the stopped engine again as it is (same tap, same voice processing). On `AudioWork.queue`.
    func resume() -> Bool {
        audioLock.withLock {
            guard let engine, let player, player.engine === engine else { return false }
            // The player is emptied and started afresh with the engine: left as it was, it reports playing and plays nothing.
            let keep = emptied()
            player.stop()
            engine.prepare()
            do {
                try engine.start()
            } catch {
                return false
            }
            guard player.engine === engine, engine.isRunning else { return false }
            player.play()
            schedule(keep, on: player, engine: engine)
            return true
        }
    }

    /// The player is stopped and started, and given the queued pieces again. Answers how many.
    func revive() -> Int {
        audioLock.withLock {
            guard let engine, let player, player.engine === engine else { return 0 }
            let keep = emptied()
            player.stop()
            if engine.isRunning { player.play() }
            schedule(keep, on: player, engine: engine)
            lock.withLock { revived += 1 }
            return keep.count
        }
    }

    /// Takes everything queued out of the bookkeeping (their completions no longer count) and hands it back.
    private func emptied() -> [AVAudioPCMBuffer] {
        lock.withLock {
            generation += 1
            let keep = pending.map(\.buffer)
            pending = []
            return keep
        }
    }

    /// Caller must hold `audioLock`.
    private func schedule(_ buffers: [AVAudioPCMBuffer], on player: AVAudioPlayerNode, engine: AVAudioEngine) {
        guard player.engine === engine else { return }
        for buffer in buffers {
            let (id, made) = lock.withLock { () -> (Int, Int) in
                nextPiece += 1
                if pending.isEmpty { progressAt = CACurrentMediaTime() }
                pending.append((nextPiece, buffer))
                return (nextPiece, generation)
            }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    guard made == self.generation, let index = self.pending.firstIndex(where: { $0.id == id }) else { return }
                    self.pending.remove(at: index)
                    self.playedOut += 1
                    self.progressAt = CACurrentMediaTime()
                }
            }
        }
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
        let description = "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(processing)"
        lock.withLock { _inputDescription = description }
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
        audioLock.withLock {
            self.engine = engine
            self.player = player
            self.speakerOnly = false
        }
    }

    /// Tests: the speaker side alone (a simulator has no microphone to start with), so the queue, the reset and the
    /// rebuild run against a real player.
    func startSpeakerOnly() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: voiceFormat)
        engine.prepare()
        try engine.start()
        player.play()
        audioLock.withLock {
            self.engine = engine
            self.player = player
            self.speakerOnly = true
        }
    }
    private var speakerOnly = false

    /// Queues one piece of the voice (PCM16 mono 24 kHz little-endian); answers its level.
    /// Pieces of the voice that came while there was no player to take them.
    var unplayed: Int { lock.withLock { dropped } }
    private var dropped = 0
    /// Pieces that played to their end, and times a stopped player was started again for a piece.
    var played: (out: Int, revived: Int) { lock.withLock { (playedOut, revived) } }
    private var playedOut = 0
    private var revived = 0

    func play(_ pcm: Data) -> Double {
        let count = pcm.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: voiceFormat, frameCapacity: AVAudioFrameCount(count)),
              let out = buffer.floatChannelData?[0] else {
            audioLock.withLock {
                if player == nil { lock.withLock { dropped += 1 } }
            }
            return 0
        }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                out[index] = Float(sample) / 32_768
            }
        }
        let level = TalkLevel.level(rms: TalkLevel.rms(UnsafeBufferPointer(start: out, count: count)))
        let scheduled: Bool = audioLock.withLock {
            guard let engine, let player, player.engine === engine else {
                lock.withLock { dropped += 1 }
                return false
            }
            schedule([buffer], on: player, engine: engine)
            // A player the engine left stopped takes buffers and plays none of them.
            if engine.isRunning, !player.isPlaying {
                lock.withLock { revived += 1 }
                player.play()
            }
            return true
        }
        return scheduled ? level : 0
    }

    /// Stops the voice now: everything queued is dropped, the player is ready for the next answer.
    func flush() {
        audioLock.withLock {
            guard let engine, let player, player.engine === engine else { return }
            _ = emptied()
            player.stop()
            if engine.isRunning { player.play() }
        }
    }

    /// Tests: the engine stops as it does for a hardware change (the loudspeaker switch just after a start).
    func stopEngineAsAHardwareChangeDoes() { audioLock.withLock { engine?.stop() } }

    /// `keeping`: what is queued is handed back, for the engine that replaces this one (`requeue`).
    @discardableResult
    func stop(keeping: Bool = false) -> [AVAudioPCMBuffer] {
        audioLock.withLock {
            let keep = emptied()
            let oldPlayer = self.player
            let oldEngine = self.engine
            let wasSpeakerOnly = self.speakerOnly
            self.player = nil
            self.engine = nil
            self.speakerOnly = false
            guard let oldEngine else { return [] }
            if let oldPlayer, oldPlayer.engine === oldEngine {
                oldPlayer.stop()
                oldEngine.detach(oldPlayer)
            }
            if !wasSpeakerOnly { oldEngine.inputNode.removeTap(onBus: 0) }
            oldEngine.stop()
            return keeping ? keep : []
        }
    }

    /// Queues pieces a stopped engine handed back.
    func requeue(_ buffers: [AVAudioPCMBuffer]) {
        guard !buffers.isEmpty else { return }
        audioLock.withLock {
            guard let engine, let player, player.engine === engine else { return }
            schedule(buffers, on: player, engine: engine)
        }
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
        send(GrokLiveWire.sessionUpdate(voice: session.voice, instructions: session.instructions, seeded: history.array?.isEmpty == false))
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
