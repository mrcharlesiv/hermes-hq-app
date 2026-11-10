// The one speaker for speech (docs/spec/3x-talk.md §4.4): a conversation's reply, Read Aloud and Read Replies Aloud
// all go through `TalkSpeaker`, so starting one stops the other. A session streams the reply's text to the gateway's
// speech socket as it arrives and plays the PCM that comes back; when the gateway cannot stream it falls back to one
// clip per sentence (§3.3, §3.4).
//
// `SpeechOutput` is the audio device: `EngineSpeechOutput` plays for real (inside the conversation's engine when there
// is one, so voice processing cancels the bot's own voice); `FixtureSpeechOutput` (DEBUG) makes no sound and keeps
// time from the bytes it was given. In a DEBUG build on the Simulator the real output is silent unless asked.
//
// Reading aloud always works (§7.7): the computer's voice (the gateway's) is always tried first. When it fails (an
// error answer from the speech routes, or no audio at all `VoiceWire.phoneVoiceAfter` after the reply is complete), the
// session goes on with the iPhone's own voice (`TalkPhoneVoice.swift`) from the sentence that failed, through the same
// output. An error answer is remembered per gateway and profile for 30 minutes, so later replies start on the iPhone's
// voice at once; a slow computer is never remembered. The explicit "iPhone Voice" choice starts there always.

import AVFAudio
import QuartzCore
import Foundation
import Synchronization

nonisolated enum SpeechOwner: String, Sendable, Equatable {
    case conversation
    case readAloud = "read-aloud"
    case repliesAloud = "replies-aloud"
    case diagnostics
}

nonisolated enum SpeechState: Equatable, Sendable {
    case idle
    /// Asked for; no audio yet.
    case preparing(String)
    /// Audio is leaving the speaker.
    case speaking(String)

    var messageId: String? {
        switch self {
        case .idle: nil
        case .preparing(let id), .speaking(let id): id
        }
    }
}

nonisolated enum SpeechOutcome: Equatable, Sendable {
    case done
    case stopped
    /// `fatal`: nothing this gateway says can be played here (an unplayable format).
    case failed(reason: String, fatal: Bool)
}

@MainActor protocol SpeechSession: AnyObject {
    var messageId: String { get }
    /// The first audio left the speaker.
    var onStarted: (() -> Void)? { get set }
    /// The whole reply so far (Markdown). Only the new part is sent.
    func append(_ fullTextSoFar: String)
    /// The reply is complete.
    func finish()
    var outcome: SpeechOutcome { get async }
}

@MainActor protocol TalkSpeaking: AnyObject {
    var state: SpeechState { get }
    var owner: SpeechOwner? { get }
    /// 0…1, for the dock's bars.
    var level: Double { get }
    var isAudible: Bool { get }
    /// Starts speaking a message; whatever was speaking stops first. `host` is the conversation's engine, when there is one.
    func open(messageId: String, profile: String?, client: any GatewayClient, owner: SpeechOwner, host: TalkPlaybackHost?) -> any SpeechSession
    func stop()
    /// The conversation's engine was rebuilt: what is still to be spoken plays through the new one.
    func rehost(_ host: TalkPlaybackHost?)
}

extension TalkSpeaking {
    func rehost(_ host: TalkPlaybackHost?) {}
}

extension Notification.Name {
    /// The speaker's state changed (object: the speaker).
    static let talkSpeechChanged = Notification.Name("hq.speech.changed")
}

/// The audio device a session plays through.
@MainActor protocol SpeechOutput: AnyObject {
    func begin(sampleRate: Double, channels: Int, host: TalkPlaybackHost?) async throws
    /// Little-endian int16 PCM in the format `begin` named.
    func schedule(_ pcm: Data)
    /// Seconds of scheduled audio not yet played.
    var pending: TimeInterval { get }
    /// Plays one clip to its end. Returns early when `stop()` is called.
    func playClip(_ clip: SpeechClip) async throws
    func stop()
    var level: Double { get }
}

// MARK: - The speaker

@MainActor final class TalkSpeaker: TalkSpeaking {
    static let shared = TalkSpeaker(output: EngineSpeechOutput())

    var output: any SpeechOutput
    private(set) var state: SpeechState = .idle {
        didSet { if state != oldValue { NotificationCenter.default.post(name: .talkSpeechChanged, object: self) } }
    }
    private(set) var owner: SpeechOwner?
    private var session: StreamSpeechSession?
    private var heldSession = false
    /// Sessions ever opened (the probe and tests read it).
    private(set) var opened = 0
    /// Sessions that asked the computer's voice first, and sessions that ever spoke with the iPhone's (tests read them).
    private(set) var gatewayTries = 0
    private(set) var phoneSessions = 0
    // What tests swap.
    var makePhoneRenderer: @MainActor () -> any PhoneSpeechRendering = { SystemPhoneSpeechRenderer() }
    var fallback = PhoneVoiceFallback.shared
    var choice: @MainActor () -> PhoneVoiceChoice = { PhoneVoiceChoice.current() }
    var phoneVoiceAfter = VoiceWire.phoneVoiceAfter

    init(output: any SpeechOutput) {
        self.output = output
    }

    var level: Double { if case .speaking = state { return output.level } else { return 0 } }
    var isAudible: Bool { if case .speaking = state { return true } else { return false } }

    func open(messageId: String, profile: String?, client: any GatewayClient, owner: SpeechOwner, host: TalkPlaybackHost?) -> any SpeechSession {
        stop()
        opened += 1
        let key = PhoneVoiceFallback.key(account: client.account.id, profile: profile)
        // Voice Diagnostics tests the computer's voice itself: never the iPhone's.
        let start: PhoneVoiceStart = owner == .diagnostics ? .gateway
            : choice() == .phone ? .chosen
            : fallback.isFailing(key) ? .remembered
            : .gateway
        if start == .gateway { gatewayTries += 1 }
        let made = StreamSpeechSession(messageId: messageId, profile: profile, client: client, owner: owner, host: host, speaker: self,
                                       key: key, start: start)
        session = made
        self.owner = owner
        state = .preparing(messageId)
        VoiceEvents.note("speech: \(owner.rawValue) opened")
        AppLog.trace("voice", "speech \(owner.rawValue) start: \(start)")
        made.begin()
        return made
    }

    func stop() {
        guard let current = session else { return }
        AppLog.trace("voice", "speech \(current.owner.rawValue) stop")
        current.stop()
    }

    func rehost(_ host: TalkPlaybackHost?) {
        guard owner == .conversation else { return }
        session?.rehost(host)
    }

    // Called by the session.

    func acquireIfNeeded(for session: StreamSpeechSession) async throws {
        guard session === self.session, session.owner != .conversation, !heldSession else { return }
        heldSession = true
        try await AudioSessionCoordinator.shared.acquire(.speech)
    }

    /// The session speaks with the iPhone's voice from here on. `tell`: the computer's voice failed (not a choice):
    /// the chat on screen says so once (`PhoneVoiceFallback.claimNotice`).
    func tookPhoneVoice(_ session: StreamSpeechSession, tell: Bool) {
        guard session === self.session else { return }
        phoneSessions += 1
        guard tell else { return }
        NotificationCenter.default.post(name: PhoneVoiceFallback.started, object: self,
                                        userInfo: ["account": session.accountId, "profile": session.profileName ?? "", "key": session.key])
    }

    func becameAudible(_ session: StreamSpeechSession) {
        guard session === self.session else { return }
        state = .speaking(session.messageId)
    }

    func ended(_ session: StreamSpeechSession, outcome: SpeechOutcome) {
        guard session === self.session else { return }
        self.session = nil
        owner = nil
        if heldSession {
            heldSession = false
            AudioSessionCoordinator.shared.release(.speech)
        }
        switch outcome {
        case .done: VoiceEvents.note("speech: finished")
        case .stopped: VoiceEvents.note("speech: stopped")
        case .failed(let reason, _): VoiceEvents.note("speech: failed: \(reason)")
        }
        state = .idle
    }
}

// MARK: - One spoken message

/// Where a session starts: the computer's voice, or the iPhone's because the person chose it or because the computer's
/// failed lately.
nonisolated enum PhoneVoiceStart: Sendable, Equatable { case gateway, chosen, remembered }

@MainActor final class StreamSpeechSession: SpeechSession {
    let messageId: String
    let owner: SpeechOwner
    var onStarted: (() -> Void)?
    private let profile: String?
    private let client: any GatewayClient
    private var host: TalkPlaybackHost?
    private var streamRate: Double?
    private weak var speaker: TalkSpeaker?

    private enum Mode { case connecting, streaming, draining, clips, phone, ended }
    private var mode: Mode = .connecting
    /// The reply so far as it was written, and how much of it went out (`SpeechFeed`).
    private var text = SpeechFeed()
    private var finished = false
    private var doneSent = false
    private var streamStarted = false
    private var audible = false
    private var socket: URLSessionWebSocketTask?
    private var feed: Timer?
    private var doneAt: CFTimeInterval?
    private var lastAudioAt: CFTimeInterval = 0
    /// The stream's channel count, and the bytes of a sample frame that has not wholly arrived yet.
    private var channels = 1
    private var carry = Data()
    private var work: Task<Void, Never>?
    private var result: SpeechOutcome?
    private var waiters: [CheckedContinuation<SpeechOutcome, Never>] = []
    // The clip fallback.
    private var clipQueue: [String] = []
    /// Clips asked for and not yet played: the iPhone's voice starts with them when the computer's fails.
    private var asked: [(sentence: String, clip: Task<SpeechClip, any Error>)] = []
    // The iPhone's voice (§7.7).
    let key: String
    private let start: PhoneVoiceStart
    private var finishedAt: CFTimeInterval?
    /// Seconds of the computer's streamed audio: about what was said before it broke.
    private var gatewaySeconds = 0.0
    /// Characters the computer already said, skipped by the iPhone's voice (whole sentences only).
    private var skipBudget = 0
    private var gatewayFailure: VoiceFailure?
    private var phoneRenderer: (any PhoneSpeechRendering)?
    /// Characters of speech per second, on the low side: a sentence is said twice rather than skipped.
    static let charactersPerSecond = 13.0

    init(messageId: String, profile: String?, client: any GatewayClient, owner: SpeechOwner, host: TalkPlaybackHost?, speaker: TalkSpeaker,
         key: String = "", start: PhoneVoiceStart = .gateway) {
        self.messageId = messageId
        self.profile = profile
        self.client = client
        self.owner = owner
        self.host = host
        self.speaker = speaker
        self.key = key
        self.start = start
    }

    var accountId: String { client.account.id }
    var profileName: String? { profile }
    /// The iPhone's voice may take over: never for Voice Diagnostics, which tests the computer's.
    private var phoneAllowed: Bool { owner != .diagnostics }

    private var output: (any SpeechOutput)? { speaker?.output }

    var outcome: SpeechOutcome {
        get async {
            if let result { return result }
            return await withCheckedContinuation { waiters.append($0) }
        }
    }

    func append(_ fullTextSoFar: String) {
        guard mode != .ended else { return }
        text.set(fullTextSoFar)
    }

    func finish() {
        guard mode != .ended else { return }
        finished = true
        if finishedAt == nil { finishedAt = CACurrentMediaTime() }
        pump()
    }

    // MARK: Stream

    func begin() {
        let timer = Timer(timeInterval: VoiceWire.feedInterval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pump() } }
        RunLoop.main.add(timer, forMode: .common)
        feed = timer
        if start == .gateway {
            work = Task { [weak self] in await self?.run() }
        } else {
            mode = .phone
            VoiceEvents.note(start == .chosen ? "speech: the \(DeviceWord.name) voice was chosen" : "speech: the computer voice failed lately, using the \(DeviceWord.name) voice")
            work = Task { [weak self] in await self?.runPhone(tell: self?.start == .remembered) }
        }
    }

    private func run() async {
        do {
            try await speaker?.acquireIfNeeded(for: self)
            guard mode == .connecting else { return }
            let task = try await VoiceGateway.speakSocket(client: client, profile: profile)
            guard mode == .connecting else { task.cancel(with: .normalClosure, reason: nil); return }
            socket = task
            task.resume()
            mode = .streaming
            pump()
            while mode == .streaming {
                let message = try await task.receive()
                guard mode == .streaming else { return }
                switch message {
                case .string(let text): await handle(VoiceWire.parse(text))
                case .data(let data): audio(data)
                @unknown default: break
                }
            }
        } catch {
            guard mode == .connecting || mode == .streaming else { return }
            let code = socket?.closeCode.rawValue ?? 0
            socket = nil
            if code == 4401 || code == 4403 { VoiceEvents.note("speech stream: ticket refused (\(code))") }
            if streamStarted {
                // The stream broke after it began: what already arrived is played. A normal close after `done` is the
                // end of the reply; anything else goes on with the iPhone's voice from about where it broke (§7.7), or
                // is said as that turn's playback failure (never a stuck "is speaking").
                let whole = doneSent && code == URLSessionWebSocketTask.CloseCode.normalClosure.rawValue
                VoiceEvents.note("speech stream: closed early (\(code))")
                let dropped = "The connection to your gateway dropped before the reply finished."
                if whole, tookPhoneVoiceForSilence() { return }
                if !whole, phoneAllowed {
                    // A dropped connection is not a broken voice: nothing is remembered and nothing is said about it.
                    takePhoneVoice(after: VoiceFailure(reason: dropped, detail: "stream closed \(code)"), remember: false, tell: false)
                } else {
                    await drain(then: whole ? .done : .failed(reason: dropped, fatal: false))
                }
            } else {
                VoiceEvents.note("speech stream: unavailable, using clips")
                await runClips()
            }
        }
    }

    private func handle(_ frame: VoiceWire.ServerFrame) async {
        switch frame {
        case .start(let rate, let channels):
            guard !streamStarted else { return }
            do {
                try await output?.begin(sampleRate: rate, channels: channels, host: host)
            } catch {
                complete(.failed(reason: "The speaker didn’t start. \(TalkEngineCapture.describe(error))", fatal: false))
                return
            }
            guard mode == .streaming else { return }
            streamStarted = true
            streamRate = rate
            self.channels = channels
            carry = Data()
            lastAudioAt = CACurrentMediaTime()
        case .end:
            closeSocket(stop: false)
            if tookPhoneVoiceForSilence() { return }
            await drain()
        case .fallback:
            closeSocket(stop: false)
            if streamStarted, audible { await drain() } else { await runClips() }
        case .unknown:
            break
        }
    }

    /// The reply has something a voice would say (not only a code block).
    private var hasWords: Bool { !SpeechText.sanitizeForSpeech(text.raw).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The computer's stream ended, as if whole, without a sound for a reply with words in it: its provider made
    /// nothing (a local or unset one; tester, 2026-11-08, "response is not read back"). The iPhone's voice
    /// reads it, and later replies start there for a while (§7.7). False when the stream played or had nothing to say.
    private func tookPhoneVoiceForSilence() -> Bool {
        guard !audible, doneSent, phoneAllowed, hasWords else { return false }
        takePhoneVoice(after: VoiceFailure(reason: "The voice on \(HostWord.phrase) made no sound.", detail: "stream ended with no audio"),
                       remember: true, tell: true)
        return true
    }

    private func audio(_ data: Data) {
        guard streamStarted, !data.isEmpty else { return }
        lastAudioAt = CACurrentMediaTime()
        // The gateway forwards its provider's chunks as they come: a sample may be split across two frames. The odd
        // bytes wait for the next frame (dropping them would shift every later sample by a byte: loud static).
        let whole = PCMCarry.take(&carry, adding: data, frameBytes: 2 * channels)
        guard !whole.isEmpty else { return }
        if let streamRate { gatewaySeconds += Double(whole.count) / (2 * Double(channels) * streamRate) }
        output?.schedule(whole)
        becomeAudible()
    }

    /// The engine this reply plays in was replaced (a route change). The old player never reports its buffers
    /// played, so the stream's output starts again on the new engine; what was already queued there is lost.
    func rehost(_ host: TalkPlaybackHost?) {
        self.host = host
        guard streamStarted, mode == .streaming || mode == .draining || mode == .phone, let streamRate else { return }
        VoiceEvents.note("speech: moved to the new audio route")
        let channels = self.channels
        Task { [weak self] in
            guard let self, self.mode == .streaming || self.mode == .draining || self.mode == .phone else { return }
            do {
                try await self.output?.begin(sampleRate: streamRate, channels: channels, host: host)
            } catch {
                self.complete(.failed(reason: "The speaker didn’t start. \(TalkEngineCapture.describe(error))", fatal: false))
            }
        }
    }

    private func becomeAudible() {
        guard !audible, mode != .ended else { return }
        audible = true
        speaker?.becameAudible(self)
        onStarted?()
    }

    /// Every 150 ms: new text goes out; `done` follows the last of it; the two guards watch the clock.
    private func pump() {
        // The reply is complete and the computer has said nothing at all for `phoneVoiceAfter`: the iPhone's voice reads
        // this reply (§7.7). Slow is not broken: the next reply asks the computer first again (nothing is remembered).
        let wait = speaker?.phoneVoiceAfter ?? VoiceWire.phoneVoiceAfter
        if !audible, phoneAllowed, let finishedAt, mode == .connecting || mode == .streaming || mode == .clips,
           CACurrentMediaTime() - finishedAt >= wait {
            takePhoneVoice(after: VoiceFailure(reason: "The voice on \(HostWord.phrase) didn’t answer in time.",
                                               detail: "no audio \(Int(wait)) s after the reply"), remember: false, tell: true)
            return
        }
        guard mode == .streaming, let socket else { return }
        if let next = text.nextStreamText(finished: finished) {
            socket.send(.string(VoiceWire.textFrame(next))) { _ in }
        }
        if finished, !doneSent {
            doneSent = true
            doneAt = CACurrentMediaTime()
            socket.send(.string(VoiceWire.doneFrame)) { _ in }
        }
        let now = CACurrentMediaTime()
        if !streamStarted, let doneAt, now - doneAt >= VoiceWire.startTimeout {
            // `done` went out and the gateway never began: speak it clip by clip.
            VoiceEvents.note("speech stream: no start after \(Int(VoiceWire.startTimeout)) s, using clips")
            closeSocket(stop: true)
            mode = .clips
            work = Task { [weak self] in await self?.runClips() }
        } else if streamStarted, doneSent, let doneAt, (output?.pending ?? 0) <= 0,
                  now - max(lastAudioAt, doneAt) >= VoiceWire.stallTimeout {
            // Only once the reply is complete: before `done` the gateway is quiet for as long as a tool runs.
            VoiceEvents.note("speech stream: no audio for \(Int(VoiceWire.stallTimeout)) s")
            closeSocket(stop: true)
            if !audible, phoneAllowed, hasWords {
                // Begun and then nothing: slow, not broken (nothing is remembered), but the reply is still read.
                takePhoneVoice(after: VoiceFailure(reason: "The voice on \(HostWord.phrase) didn’t answer in time.",
                                                   detail: "no audio \(Int(VoiceWire.stallTimeout)) s after start"), remember: false, tell: true)
                return
            }
            complete(.done)
        }
    }

    private func closeSocket(stop: Bool) {
        guard let socket else { return }
        self.socket = nil
        if stop { socket.send(.string(VoiceWire.stopFrame)) { _ in } }
        socket.cancel(with: .normalClosure, reason: nil)
    }

    /// Everything scheduled plays out, then the session is done.
    private func drain(then outcome: SpeechOutcome = .done) async {
        guard mode != .ended else { return }
        mode = .draining
        // What is scheduled plays out. Bounded by the clock: a player whose engine was replaced under it (a route
        // change) never reports its buffers played.
        let deadline = CACurrentMediaTime() + (output?.pending ?? 0) + 1.0
        while mode == .draining, (output?.pending ?? 0) > 0.01, CACurrentMediaTime() < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        if mode == .draining { complete(outcome) }
    }

    // MARK: Clips

    private func nextSentence() -> String? {
        clipQueue += text.nextSentences(finished: finished)
        return clipQueue.isEmpty ? nil : clipQueue.removeFirst()
    }

    private func fetch(_ sentence: String) -> Task<SpeechClip, any Error> {
        let client = self.client, profile = self.profile
        return Task { try await VoiceGateway.speak(client: client, text: sentence, profile: profile) }
    }

    /// One sentence at a time; the next one is fetched while the current one plays.
    private func runClips() async {
        guard mode != .ended else { return }
        mode = .clips
        while mode == .clips {
            while asked.count < 2, let sentence = nextSentence() { asked.append((sentence, fetch(sentence))) }
            guard let current = asked.first else {
                if finished, text.sentencesFlushed, clipQueue.isEmpty { complete(.done); return }
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            do {
                let clip = try await current.clip.value
                guard mode == .clips else { return }
                becomeAudible()
                try await output?.playClip(clip)
                guard mode == .clips else { return }
                asked.removeFirst()
            } catch {
                guard mode == .clips else { return }
                let failure = VoiceWire.failure(error, doing: "speak the reply")
                if phoneAllowed {
                    takePhoneVoice(after: failure, remember: true, tell: true)
                } else {
                    complete(.failed(reason: failure.reason, fatal: failure.detail == "unplayable"))
                }
                return
            }
        }
    }

    // MARK: The iPhone's voice (§7.7)

    /// The computer's voice failed: the rest of the reply is read by the iPhone's, starting with what was not said.
    /// `remember` (an error answer): later replies of this gateway and profile go straight to the iPhone's voice for a
    /// while. `tell`: the chat on screen says so, once.
    private func takePhoneVoice(after failure: VoiceFailure, remember: Bool, tell: Bool) {
        guard mode != .ended, mode != .phone else { return }
        VoiceEvents.note(PhoneVoiceWords.logLine(failure))
        AppLog.note("voice", "speech falls back to the phone's voice\(remember ? " (remembered 30 min)" : ""): computer voice failed")
        gatewayFailure = failure
        if remember { speaker?.fallback.remember(key) }
        closeSocket(stop: true)
        // A clip still being made is not waited for (a computer that never answers).
        clipQueue = asked.map(\.sentence) + clipQueue
        for item in asked { item.clip.cancel() }
        asked = []
        if streamStarted, gatewaySeconds > 0 { skipBudget = Int(gatewaySeconds * Self.charactersPerSecond) }
        let previous = work
        mode = .phone
        work = Task { [weak self] in await self?.runPhone(tell: tell) }
        previous?.cancel()
    }

    private func runPhone(tell: Bool) async {
        guard mode == .phone, let speaker else { return }
        speaker.tookPhoneVoice(self, tell: tell)
        do {
            try await speaker.acquireIfNeeded(for: self)
        } catch {
            complete(.failed(reason: VoiceWire.failure(error, doing: "speak the reply").reason, fatal: false))
            return
        }
        // What the computer already sent plays out first (bounded: a replaced engine never reports it played).
        let deadline = CACurrentMediaTime() + (output?.pending ?? 0) + 1.0
        while mode == .phone, (output?.pending ?? 0) > 0.01, CACurrentMediaTime() < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        let renderer = speaker.makePhoneRenderer()
        phoneRenderer = renderer
        var voiceChosen = false
        var format: (rate: Double, channels: Int)?
        while mode == .phone {
            guard let sentence = nextSentence() else {
                if finished, text.sentencesFlushed, clipQueue.isEmpty { await drain(); return }
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            if skipBudget > 0 {
                if sentence.count <= skipBudget {
                    skipBudget -= sentence.count + 1
                    continue
                }
                skipBudget = 0
            }
            if !voiceChosen {
                voiceChosen = true
                let voice = renderer.chooseVoice(for: SpeechText.sanitizeForSpeech(text.raw))
                VoiceEvents.note("speech: reading with the \(DeviceWord.name) voice (\(voice))")
            }
            do {
                for try await piece in renderer.render(sentence) {
                    guard mode == .phone else { return }
                    if format?.rate != piece.sampleRate || format?.channels != piece.channels {
                        if format != nil {
                            while mode == .phone, (output?.pending ?? 0) > 0.01 { try? await Task.sleep(for: .milliseconds(30)) }
                        }
                        try await output?.begin(sampleRate: piece.sampleRate, channels: piece.channels, host: host)
                        guard mode == .phone else { return }
                        format = (piece.sampleRate, piece.channels)
                        streamStarted = true
                        streamRate = piece.sampleRate
                        channels = piece.channels
                    }
                    for slice in PhonePCMConvert.slices(piece) { output?.schedule(slice) }
                    becomeAudible()
                }
            } catch {
                guard mode == .phone else { return }
                VoiceEvents.note("speech: the \(DeviceWord.name) voice failed: \(VoiceWire.failure(error, doing: "speak the reply").reason)")
                let reason = gatewayFailure?.reason ?? "The \(DeviceWord.name)’s voice couldn’t read this reply."
                // §7.7 "as before": an unplayable format still stops the conversation (§7.6).
                complete(.failed(reason: reason, fatal: gatewayFailure?.detail == "unplayable"))
                return
            }
            // Never far ahead of the voice: Stop and barge-in stay cheap.
            while mode == .phone, (output?.pending ?? 0) > 3 { try? await Task.sleep(for: .milliseconds(50)) }
        }
    }

    // MARK: End

    func stop() {
        guard mode != .ended else { return }
        closeSocket(stop: true)
        complete(.stopped)
    }

    private func complete(_ outcome: SpeechOutcome) {
        guard mode != .ended else { return }
        mode = .ended
        carry = Data()
        feed?.invalidate()
        feed = nil
        closeSocket(stop: false)
        output?.stop()
        phoneRenderer?.cancel()
        phoneRenderer = nil
        for item in asked { item.clip.cancel() }
        asked = []
        work?.cancel()
        result = outcome
        speaker?.ended(self, outcome: outcome)
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: outcome) }
    }
}

// MARK: - What is sent to be spoken

/// The reply's text on its way to the voice (§3.3, §3.4). The gateway's speech socket is given the reply as it was
/// written, a piece at a time, and cleans each sentence itself: Markdown cleaned on the phone is not stable while it
/// arrives (a link or a code span changes the earlier text when it closes), so a cleaned suffix would lose letters.
/// A reply that is already whole when it is first asked for (Read Aloud) is cleaned whole, as the web app does.
/// The clip fallback cuts sentences out of the written text and cleans each one after cutting.
nonisolated struct SpeechFeed: Sendable {
    private(set) var raw = ""
    /// Unicode scalars of `raw` already sent on the socket (scalars: a later combining mark never moves the count).
    private var streamed = 0
    private var cut = 0
    /// Written text not yet cut into sentences (the clip fallback).
    private var uncut = ""
    private(set) var sentencesFlushed = false

    init() {}

    mutating func set(_ fullTextSoFar: String) { raw = fullTextSoFar }

    private func suffix(from scalars: Int) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: raw.unicodeScalars.dropFirst(scalars))
        return String(view)
    }

    /// The next text frame for the speech socket, or nil when nothing is new.
    mutating func nextStreamText(finished: Bool) -> String? {
        let count = raw.unicodeScalars.count
        guard count > streamed else { return nil }
        if finished, streamed == 0 {
            streamed = count
            let whole = SpeechText.sanitizeForSpeech(raw)
            return whole.isEmpty ? nil : whole
        }
        let next = suffix(from: streamed)
        streamed = count
        return next
    }

    /// The sentences that are ready for the one-clip fallback, each cleaned for a voice.
    mutating func nextSentences(finished: Bool) -> [String] {
        guard !sentencesFlushed else { return [] }
        let count = raw.unicodeScalars.count
        if finished, cut == 0 {
            // Whole before anything was cut: cleaned whole, then cut.
            cut = count
            sentencesFlushed = true
            return SpeechText.cutSentences(SpeechText.sanitizeForSpeech(raw), flush: true).sentences
        }
        if count > cut {
            uncut += suffix(from: cut)
            cut = count
        }
        // A code block is never spoken and never cut through: one still being written waits for its end.
        let parts = SpeechText.withoutCodeBlocks(uncut)
        let made: [String]
        if parts.held.isEmpty {
            let pieces = SpeechText.cutSentences(parts.text, flush: finished)
            made = pieces.sentences
            uncut = pieces.rest
        } else {
            made = SpeechText.cutSentences(parts.text, flush: true).sentences
            uncut = finished ? "" : parts.held
        }
        if finished { sentencesFlushed = true }
        return made.map(SpeechText.sanitizeForSpeech).filter { !$0.isEmpty }
    }
}

/// Whole sample frames out of PCM that arrives in pieces of any length.
nonisolated enum PCMCarry {
    /// Adds `data` to what was left over and returns the whole frames; the rest stays in `carry`.
    static func take(_ carry: inout Data, adding data: Data, frameBytes: Int) -> Data {
        let frame = max(2, frameBytes)
        var bytes = Data()
        bytes.reserveCapacity(carry.count + data.count)
        bytes.append(carry)
        bytes.append(data)
        let usable = bytes.count - bytes.count % frame
        carry = Data(bytes.suffix(bytes.count - usable))
        return Data(bytes.prefix(usable))
    }
}

// MARK: - The real output

@MainActor final class EngineSpeechOutput: SpeechOutput {
    /// No sound leaves the Mac: the default for a DEBUG build on the Simulator (`-HQDebugTalkSpeaker silent`).
    nonisolated static let silent = Mutex<Bool>(EngineSpeechOutput.silentByDefault)
    nonisolated static var silentByDefault: Bool {
        #if DEBUG && targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private let box = SpeechEngineBox()
    private var clipPlayer: AVAudioPlayer?
    private var clipDelegate: ClipDelegate?
    private var clipWaiter: CheckedContinuation<Void, Never>?
    private var clipStarted: CFTimeInterval = 0

    var pending: TimeInterval { box.pending }

    var level: Double {
        if clipPlayer != nil {
            // A clip has no cheap meter on the main thread: a gentle movement shows it is speaking.
            let t = CACurrentMediaTime() - clipStarted
            return 0.45 + 0.25 * sin(t * 5.3) * sin(t * 1.7 + 0.6)
        }
        return box.level
    }

    func begin(sampleRate: Double, channels: Int, host: TalkPlaybackHost?) async throws {
        let box = self.box, silent = Self.silent.withLock { $0 }
        try await AudioWork.run { try box.begin(sampleRate: sampleRate, channels: channels, host: host, silent: silent) }
    }

    func schedule(_ pcm: Data) {
        let box = self.box
        box.willSchedule(bytes: pcm.count)
        AudioWork.later { box.schedule(pcm) }
    }

    func playClip(_ clip: SpeechClip) async throws {
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: clip.data, fileTypeHint: Self.typeHint(clip.mime))
        } catch {
            throw VoiceFailure(reason: VoiceWire.unplayable(clip.mime), detail: "unplayable")
        }
        let delegate = ClipDelegate { [weak self] in self?.clipEnded() }
        player.delegate = delegate
        if Self.silent.withLock({ $0 }) { player.volume = 0 }
        clipPlayer = player
        clipDelegate = delegate
        clipStarted = CACurrentMediaTime()
        let boxed = UncheckedPlayer(player)
        let started = await AudioWork.perform { boxed.value.prepareToPlay() && boxed.value.play() }
        guard started else {
            clipPlayer = nil
            clipDelegate = nil
            throw VoiceFailure(reason: VoiceWire.unplayable(clip.mime), detail: "unplayable")
        }
        guard clipPlayer === player else { return }   // stopped while it was starting
        await withCheckedContinuation { clipWaiter = $0 }
    }

    private func clipEnded() {
        clipPlayer = nil
        clipDelegate = nil
        let waiter = clipWaiter
        clipWaiter = nil
        waiter?.resume()
    }

    func stop() {
        let box = self.box
        AudioWork.later { box.stop() }
        box.cleared()
        if let player = clipPlayer {
            let boxed = UncheckedPlayer(player)
            AudioWork.later { boxed.value.stop() }
            clipEnded()
        }
    }

    /// The file type `AVAudioPlayer` is told to expect (nil: it looks at the bytes).
    private static func typeHint(_ mime: String) -> String? {
        switch VoiceWire.fileExtension(mime) {
        case "mp3": "public.mp3"
        case "wav": "com.microsoft.waveform-audio"
        case "m4a": "com.apple.m4a-audio"
        default: nil
        }
    }
}

private nonisolated struct UncheckedPlayer: @unchecked Sendable {
    let value: AVAudioPlayer
    init(_ value: AVAudioPlayer) { self.value = value }
}

private final class ClipDelegate: NSObject, AVAudioPlayerDelegate {
    private let ended: @MainActor () -> Void
    init(ended: @escaping @MainActor () -> Void) { self.ended = ended }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.ended() } }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.ended() } }
    }
}

/// The player node and (outside a conversation) its own engine. Engine calls only on `AudioWork.queue`; the counters
/// are read from the main thread.
nonisolated final class SpeechEngineBox: @unchecked Sendable {
    private struct Counters {
        var scheduledFrames = 0.0
        var playedFrames = 0.0
        var rate = 24_000.0
        var bytesPerFrame = 2.0
        var levels: [Double] = []
        var playing = 0
        var generation = 0
    }
    private let counters = Mutex(Counters())
    private var engine: AVAudioEngine?
    private var ownsEngine = false
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var channels = 1

    var pending: TimeInterval { counters.withLock { max(0, ($0.scheduledFrames - $0.playedFrames) / $0.rate) } }
    var level: Double { counters.withLock { $0.playing < $0.levels.count ? $0.levels[$0.playing] : 0 } }

    func begin(sampleRate: Double, channels: Int, host: TalkPlaybackHost?, silent: Bool) throws {
        stop()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) else {
            throw VoiceFailure(reason: "The speech format isn’t supported.", detail: nil)
        }
        self.format = format
        self.channels = channels
        counters.withLock {
            let generation = $0.generation + 1     // late callbacks of an earlier session count for nothing
            $0 = Counters()
            $0.generation = generation
            $0.rate = sampleRate
            $0.bytesPerFrame = Double(2 * channels)
        }
        if let host {
            // Inside the conversation's engine, so voice processing hears and cancels it.
            engine = host.engine
            player = host.player
            ownsEngine = false
            if host.player.outputFormat(forBus: 0).sampleRate != sampleRate || host.player.outputFormat(forBus: 0).channelCount != format.channelCount {
                host.engine.disconnectNodeOutput(host.player)
                host.engine.connect(host.player, to: host.engine.mainMixerNode, format: format)
            }
            if !host.engine.isRunning { try host.engine.start() }
            host.player.play()
        } else {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            if silent { engine.mainMixerNode.outputVolume = 0 }
            engine.prepare()
            try engine.start()
            player.play()
            self.engine = engine
            self.player = player
            ownsEngine = true
        }
    }

    /// On the main thread, before the buffer is handed to the audio queue: `pending` is right at once.
    func willSchedule(bytes: Int) {
        counters.withLock { $0.scheduledFrames += Double(bytes) / $0.bytesPerFrame }
    }

    func cleared() {
        counters.withLock {
            $0.generation += 1
            $0.scheduledFrames = 0
            $0.playedFrames = 0
            $0.levels = []
            $0.playing = 0
        }
    }

    func schedule(_ pcm: Data) {
        guard let player, let format else { return }
        let frames = pcm.count / (2 * channels)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let value = Float(Int16(littleEndian: samples[frame * channels + channel])) / 32_768
                    out[channel][frame] = value
                    sum += Double(value) * Double(value)
                }
            }
        }
        let level = TalkLevel.level(rms: (sum / Double(frames * channels)).squareRoot())
        let generation = counters.withLock { state -> Int in
            state.levels.append(level)
            return state.generation
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.counters.withLock { state in
                guard state.generation == generation else { return }
                state.playedFrames += Double(frames)
                state.playing += 1
            }
        }
    }

    func stop() {
        player?.stop()
        if ownsEngine { engine?.stop() }
        engine = nil
        player = nil
        ownsEngine = false
    }
}

// MARK: - The stand-in output

#if DEBUG
/// No audio objects at all: time passes as the bytes say (`-HQDebugTalkSpeaker fixture`).
@MainActor final class FixtureSpeechOutput: SpeechOutput {
    private var rate = 24_000.0
    private var channels = 1
    private var endsAt: CFTimeInterval = 0
    private var generation = 0
    /// What tests read.
    private(set) var begun = 0
    private(set) var scheduledBytes = 0
    /// The first megabyte of what was scheduled, byte for byte.
    private(set) var scheduled = Data()
    private(set) var clips = 0
    private(set) var stops = 0
    private(set) var lastFormat: (rate: Double, channels: Int)?
    /// A clip of an unknown length plays this long.
    var clipSeconds = 0.6

    var pending: TimeInterval { max(0, endsAt - CACurrentMediaTime()) }

    var level: Double {
        guard pending > 0 else { return 0 }
        let t = CACurrentMediaTime()
        return 0.45 + 0.25 * sin(t * 5.3) * sin(t * 1.7 + 0.6)
    }

    func begin(sampleRate: Double, channels: Int, host: TalkPlaybackHost?) async throws {
        begun += 1
        rate = sampleRate
        self.channels = channels
        lastFormat = (sampleRate, channels)
        endsAt = CACurrentMediaTime()
    }

    func schedule(_ pcm: Data) {
        scheduledBytes += pcm.count
        if scheduled.count < 1_048_576 { scheduled.append(pcm) }
        let seconds = Double(pcm.count) / (rate * 2 * Double(channels))
        endsAt = max(endsAt, CACurrentMediaTime()) + seconds
    }

    func playClip(_ clip: SpeechClip) async throws {
        guard VoiceWire.canPlay(clip.mime) else { throw VoiceFailure(reason: VoiceWire.unplayable(clip.mime), detail: "unplayable") }
        clips += 1
        let mine = generation
        endsAt = CACurrentMediaTime() + Self.seconds(of: clip, otherwise: clipSeconds)
        while mine == generation, pending > 0 {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    func stop() {
        stops += 1
        generation += 1
        endsAt = 0
    }

    /// A WAV says how long it is in its header.
    static func seconds(of clip: SpeechClip, otherwise: Double) -> Double {
        let data = clip.data
        guard data.count > 44, data.prefix(4) == Data("RIFF".utf8) else { return otherwise }
        let byteRate = data.subdata(in: 28..<32).withUnsafeBytes { Double(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard byteRate > 0 else { return otherwise }
        return min(30, Double(data.count - 44) / byteRate)
    }
}
#endif
