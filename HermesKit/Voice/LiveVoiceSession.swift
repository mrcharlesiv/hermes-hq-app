// The GPT-Live session's transport (docs/spec/3x-gpt-live.md §5): a WebRTC peer that sends the microphone to OpenAI,
// plays the voice, and carries the `oai-events` data channel. The gateway trades the offer for OpenAI's answer, so no
// OpenAI key is ever on the phone (`HA:tools/voice_live.py:162-186`). A port of `HA:apps/desktop/src/lib/voice-live.ts`.
//
// `AudioSessionCoordinator` stays the only owner of AVAudioSession: WebRTC runs on manual audio and is told when the
// session it plays and records on is active.

import AVFAudio
import Foundation
@preconcurrency import WebRTC

nonisolated enum LiveVoiceError: Error, Equatable, Sendable {
    case denied
    case noMicrophone
    /// The gateway or OpenAI refused the session: the gateway's own words.
    case refused(status: Int, detail: String)
    case failed(String)
}

/// What `TalkController` drives. Callbacks arrive on the main actor.
@MainActor protocol LiveVoiceTransport: AnyObject {
    var onEvent: ((LiveServerEvent) -> Void)? { get set }
    /// The transport went away without `session.closed` (the network, the peer).
    var onDropped: ((String) -> Void)? { get set }
    /// The microphone's level, about five a second, 0…1.
    var onMicLevel: ((Double) -> Void)? { get set }
    /// The voice's audio started or stopped.
    var onSpeaking: ((Bool) -> Void)? { get set }
    /// The voice's level, 0…1 (the bars while it speaks).
    var speakerLevel: Double { get }
    /// Permission, the audio session, the peer and its offer; `exchange` trades the offer for the answer (the gateway).
    func start(history: JSONValue, exchange: @escaping @MainActor (String) async throws -> String) async throws
    func send(_ event: String)
    func setMuted(_ muted: Bool)
    /// Asks for `session.closed`, waits for it (at most `LiveVoiceWire.closeTimeout`), then lets everything go.
    func close() async
    // [grok-live] What the loop asks the voice to say, note or do. GPT-Live's defaults below send its own events;
    // Grok's transport answers its `ask_agent` calls instead.
    func speak(delegationId: String?, text: String)
    func think(delegationId: String?, text: String)
    func instruct(_ text: String)
}

extension LiveVoiceTransport {
    /// One `session.commentary.append` per chunk: the voice says them aloud, paraphrased.
    func speak(delegationId: String?, text: String) {
        LiveVoiceWire.commentary(delegationId: delegationId, text).forEach { send($0) }
    }

    func think(delegationId: String?, text: String) {
        if let event = LiveVoiceWire.thinking(delegationId: delegationId, text) { send(event) }
    }

    func instruct(_ text: String) {
        if let event = LiveVoiceWire.instructions(text) { send(event) }
    }
}

// MARK: - The real one

@MainActor final class WebRTCLiveVoice: LiveVoiceTransport {
    var onEvent: ((LiveServerEvent) -> Void)?
    var onDropped: ((String) -> Void)?
    var onMicLevel: ((Double) -> Void)?
    var onSpeaking: ((Bool) -> Void)?
    private(set) var speakerLevel = 0.0

    private var core: WebRTCLiveCore?
    private var track: RTCAudioTrack?
    private var statsTimer: Timer?
    private var speaking = false
    private var lastLoud: TimeInterval = 0
    private var holdsSession = false
    private var finished = false
    private var closedWaiter: CheckedContinuation<Void, Never>?
    private var sawClosed = false

    /// The voice counts as speaking while its raw `audioLevel` is above this, and for `speakingHangover` after.
    static let speakingLevel = 0.01
    static let speakingHangover: TimeInterval = 0.4

    #if DEBUG
    /// Tests on a Mac with no microphone: no permission, no audio session, only the peer and its channel.
    static var withoutAudio = false
    #endif

    /// One factory for the app, made on first use (it starts WebRTC's threads).
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    func start(history: JSONValue, exchange: @escaping @MainActor (String) async throws -> String) async throws {
        AppLog.trace("voice", "gpt-live transport starting")
        #if DEBUG
        if Self.withoutAudio { return try await connect(exchange: exchange) }
        #endif
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else {
                AppLog.note("voice", "gpt-live start refused: microphone permission denied")
                throw LiveVoiceError.denied
            }
        case .denied:
            AppLog.note("voice", "gpt-live start refused: microphone permission denied")
            throw LiveVoiceError.denied
        default:
            break
        }
        // WebRTC sets the category again when its audio starts; with its own options (no `.defaultToSpeaker`) the
        // replies came out of the earpiece. The coordinator also puts the loudspeaker back on each route change.
        let config = RTCAudioSessionConfiguration.webRTC()
        config.categoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
        RTCAudioSessionConfiguration.setWebRTC(config)
        let rtc = RTCAudioSession.sharedInstance()
        rtc.useManualAudio = true
        rtc.isAudioEnabled = false
        do {
            try await AudioSessionCoordinator.shared.acquire(.conversation, mode: .voiceChat)
            guard !finished else {
                // Closed while the session was being activated: `tearDown` already ran without it.
                AudioSessionCoordinator.shared.release(.conversation)
                throw CancellationError()
            }
            holdsSession = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AudioSessionCoordinator.shared.release(.conversation)
            AppLog.note("voice", "gpt-live start failed: audio session \(AppLog.scrub(String(describing: error)))")
            throw LiveVoiceError.failed(TalkEngineCapture.describe(error))
        }
        guard AVAudioSession.sharedInstance().isInputAvailable else {
            AppLog.note("voice", "gpt-live start refused: no microphone")
            throw LiveVoiceError.noMicrophone
        }
        rtc.audioSessionDidActivate(AVAudioSession.sharedInstance())
        rtc.isAudioEnabled = true
        do {
            try await connect(exchange: exchange)
            AppLog.trace("voice", "gpt-live transport connected")
        } catch {
            AppLog.note("voice", "gpt-live connect failed: \(AppLog.scrub(String(describing: error)))")
            throw error
        }
    }

    /// The peer, its microphone track and event channel, the offer for the answer.
    private func connect(exchange: @escaping @MainActor (String) async throws -> String) async throws {
        guard !finished else { throw CancellationError() }
        let core = WebRTCLiveCore()
        self.core = core
        core.onMessage = { [weak self] raw in
            guard let self, !self.finished, let event = LiveServerEvent.parse(raw) else { return }
            if case .closed = event { self.sawClosed = true; self.closedWaiter?.resume(); self.closedWaiter = nil }
            self.onEvent?(event)
        }
        core.onDropped = { [weak self] why in
            guard let self, !self.finished, !self.sawClosed else { return }
            AppLog.note("voice", "gpt-live transport dropped: \(why)")
            self.onDropped?(why)
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = Self.factory.peerConnection(with: RTCConfiguration(), constraints: constraints, delegate: core) else {
            throw LiveVoiceError.failed("WebRTC could not make a connection.")
        }
        core.peer = peer
        let source = Self.factory.audioSource(with: constraints)
        let track = Self.factory.audioTrack(with: source, trackId: "hq-mic")
        self.track = track
        peer.add(track, streamIds: ["hq-voice"])
        // The data channel is made before the offer so its m-line is negotiated.
        guard let channel = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration()) else {
            throw LiveVoiceError.failed("WebRTC could not open the event channel.")
        }
        channel.delegate = core
        core.channel = channel

        // [diagnostics] each step's time: a slow start says which step it was (build 409: 9.7 s, none logged).
        let began = ContinuousClock.now
        let offer = try await core.makeOffer()
        let offered = AppLog.ms(since: began)
        let gather = await core.gatherIce(timeout: LiveVoiceWire.iceGatherTimeout)
        let gatheredMs = AppLog.ms(since: began)
        guard !finished else { throw CancellationError() }
        let local = peer.localDescription?.sdp ?? offer
        let answer = try await exchange(local)
        let exchangedMs = AppLog.ms(since: began)
        guard !finished else { throw CancellationError() }
        try await core.setAnswer(answer)
        AppLog.note("voice", "gpt-live start steps: offer \(offered) ms, routes \(gatheredMs - offered) ms (\(gather.how), "
            + "\(gather.candidates) found), session \(exchangedMs - gatheredMs) ms, answer \(AppLog.ms(since: began) - exchangedMs) ms")
        startStats()
    }

    func send(_ event: String) {
        core?.send(event)
    }

    func setMuted(_ muted: Bool) {
        track?.isEnabled = !muted
        send(LiveVoiceWire.mute(muted))
    }

    func close() async {
        guard !finished else { return }
        if let core, core.isOpen, !sawClosed {
            core.send(LiveVoiceWire.close)
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                closedWaiter = waiter
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(LiveVoiceWire.closeTimeout))
                    self?.closedWaiter?.resume()
                    self?.closedWaiter = nil
                }
            }
            AppLog.trace("voice", "gpt-live close: \(sawClosed ? "the gateway confirmed" : "timed out waiting, closing anyway")")
        }
        tearDown()
    }

    private func tearDown() {
        guard !finished else { return }
        AppLog.trace("voice", "gpt-live transport stopped")
        finished = true
        statsTimer?.invalidate()
        statsTimer = nil
        track?.isEnabled = false
        core?.shutDown()
        core = nil
        track = nil
        if speaking { speaking = false; onSpeaking?(false) }
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        if holdsSession {
            holdsSession = false
            rtc.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
            AudioSessionCoordinator.shared.release(.conversation)
        }
    }

    // MARK: Levels

    private func startStats() {
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pollStats() } }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func pollStats() {
        core?.levels { [weak self] mic, voice in
            guard let self, !self.finished else { return }
            // WebRTC's `audioLevel` is linear (1 = full scale): put on the web meter's scale the bars and the silence
            // clock read.
            self.onMicLevel?(TalkLevel.level(rms: mic))
            self.speakerLevel = TalkLevel.level(rms: voice)
            let now = CACurrentMediaTime()
            if voice > Self.speakingLevel { self.lastLoud = now }
            let speaking = now - self.lastLoud < Self.speakingHangover
            if speaking != self.speaking {
                self.speaking = speaking
                self.onSpeaking?(speaking)
            }
        }
    }
}

/// The WebRTC delegates. WebRTC calls them on its own threads; everything is handed to the main queue.
nonisolated final class WebRTCLiveCore: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    var peer: RTCPeerConnection?
    var channel: RTCDataChannel?
    @MainActor var onMessage: ((String) -> Void)?
    @MainActor var onDropped: ((String) -> Void)?
    private let lock = NSLock()
    private var gatherWaiters: [CheckedContinuation<Void, Never>] = []
    private var gathered = false
    private var candidates = 0
    /// How gathering ended, for the start's timing line: "complete", "first route + grace" or "capped".
    private var gatherHow = "capped"

    var isOpen: Bool { channel?.readyState == .open }

    func send(_ text: String) {
        guard let channel, channel.readyState == .open else { return }
        channel.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
    }

    func makeOffer() async throws -> String {
        guard let peer else { throw LiveVoiceError.failed("No WebRTC connection.") }
        let constraints = RTCMediaConstraints(mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue],
                                              optionalConstraints: nil)
        let sdp: String = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: constraints) { description, error in
                guard let description else {
                    continuation.resume(throwing: LiveVoiceError.failed(error.map { "\($0.localizedDescription)" } ?? "No offer."))
                    return
                }
                peer.setLocalDescription(description) { error in
                    if let error { continuation.resume(throwing: LiveVoiceError.failed(error.localizedDescription)) }
                    else { continuation.resume(returning: description.sdp) }
                }
            }
        }
        return sdp
    }

    /// Waits for ICE gathering to complete, `LiveVoiceWire.iceGraceAfterFirst` after the first candidate, or at most
    /// `timeout`: OpenAI answers with the candidates it has. Returns how it ended and how many candidates there were.
    func gatherIce(timeout: TimeInterval) async -> (how: String, candidates: Int) {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !gathered && peer?.iceGatheringState == .complete { gathered = true; gatherHow = "complete" }
            if gathered {
                lock.unlock()
                waiter.resume()
                return
            }
            gatherWaiters.append(waiter)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finishGathering("capped") }
        }
        return gatherResult()
    }

    private func gatherResult() -> (how: String, candidates: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (gatherHow, candidates)
    }

    private func finishGathering(_ how: String) {
        lock.lock()
        guard !gathered else { lock.unlock(); return }
        gathered = true
        gatherHow = how
        let waiters = gatherWaiters
        gatherWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func setAnswer(_ sdp: String) async throws {
        guard let peer else { throw LiveVoiceError.failed("No WebRTC connection.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in
                if let error { continuation.resume(throwing: LiveVoiceError.failed(error.localizedDescription)) }
                else { continuation.resume() }
            }
        }
    }

    /// The microphone's level (`media-source`) and the voice's (`inbound-rtp`), each 0…1, on the main actor.
    func levels(_ done: @escaping @MainActor (Double, Double) -> Void) {
        guard let peer else { return }
        peer.statistics { report in
            var mic = 0.0, voice = 0.0
            for stats in report.statistics.values where (stats.values["kind"] as? String) == "audio" {
                let level = (stats.values["audioLevel"] as? NSNumber)?.doubleValue ?? 0
                if stats.type == "media-source" { mic = level } else if stats.type == "inbound-rtp" { voice = level }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(mic, voice) } }
        }
    }

    func shutDown() {
        channel?.delegate = nil
        channel?.close()
        peer?.delegate = nil
        peer?.close()
        channel = nil
        peer = nil
        finishGathering("closed")
    }

    private func dropped(_ why: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onDropped?(why) } }
    }

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .closed { dropped("connection_lost") }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary else { return }
        let text = String(decoding: buffer.data, as: UTF8.self)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onMessage?(text) } }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .disconnected { dropped("connection_lost") }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { finishGathering("complete") }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        lock.lock()
        candidates += 1
        let first = candidates == 1
        lock.unlock()
        guard first else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + LiveVoiceWire.iceGraceAfterFirst) { [weak self] in
            self?.finishGathering("first route + grace")
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - Stand-ins

/// The standard engine's microphone slot while GPT-Live holds the real one: it does nothing.
@MainActor final class LiveInertCapture: TalkCapturing {
    var onLevel: ((Double) -> Void)?
    var onTakeEnded: ((TalkTake) -> Void)?
    var onBargeSpeech: (() -> Void)?
    var onBargeUtterance: ((TalkTake?) -> Void)?
    var onInterrupted: ((TalkPauseCause, String) -> Void)?
    var onEngineReplaced: (() -> Void)?
    var playbackHost: TalkPlaybackHost? { nil }
    var audioOwner: AudioSessionCoordinator.Owner = .conversation
    func prepare() async throws {}
    func beginTake(silenceMs: Int, words: (any LiveWordsListening)?) { words?.cancel() }
    func hearUtterance(_ words: any LiveWordsListening) { words.cancel() }
    func finishTake() {}
    func cancelTake() {}
    func armBarge(multiplier: Double?, silenceMs: Int) {}
    func disarmBarge() {}
    func setPlaying(_ playing: Bool) {}
    func shutDown() async {}
}

#if DEBUG
/// Tests and UI tests: a scripted GPT-Live session. `script` is played on start; `respond` answers a sent event.
@MainActor final class FixtureLiveVoice: LiveVoiceTransport {
    var onEvent: ((LiveServerEvent) -> Void)?
    var onDropped: ((String) -> Void)?
    var onMicLevel: ((Double) -> Void)?
    var onSpeaking: ((Bool) -> Void)?
    var speakerLevel = 0.0

    /// What every fixture session does: fail, or open and play these events (seconds after the answer, raw JSON).
    static var failWith: LiveVoiceError?
    static var script: [(after: TimeInterval, raw: String)] = [(0.2, #"{"type":"session.started","session":{"id":"sess_fixture"}}"#)]
    /// Everything any fixture session sent, oldest first (the probe and the tests read it).
    static var sent: [String] = []
    static var exchanged: [String] = []

    private var closed = false

    func start(history: JSONValue, exchange: @escaping @MainActor (String) async throws -> String) async throws {
        if let error = Self.failWith { throw error }
        let offer = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=hq-fixture\r\nt=0 0\r\n"
        let answer = try await exchange(offer)
        Self.exchanged.append(answer)
        for step in Self.script {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(step.after))
                guard let self, !self.closed, let event = LiveServerEvent.parse(step.raw) else { return }
                self.onEvent?(event)
            }
        }
    }

    func send(_ event: String) { Self.sent.append(event) }
    func setMuted(_ muted: Bool) { send(LiveVoiceWire.mute(muted)) }

    func close() async {
        guard !closed else { return }
        send(LiveVoiceWire.close)
        closed = true
    }

    /// Plays one event now, as OpenAI would.
    func play(_ raw: String) {
        guard !closed, let event = LiveServerEvent.parse(raw) else { return }
        onEvent?(event)
    }
}
#endif
