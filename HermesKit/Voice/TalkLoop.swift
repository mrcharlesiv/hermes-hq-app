// The conversation loop (docs/spec/3x-talk.md §4.2): a pure reducer. `TalkController` feeds it inputs and performs
// the effects; nothing here touches audio, the network or a clock. Rules follow the web app's
// `vendor/hermes/apps/desktop/src/app/chat/composer/hooks/use-voice-conversation.ts`.

import Foundation

nonisolated enum TalkHaptic: Sendable, Equatable { case error, warning }

nonisolated enum TalkLoopInput: Sendable, Equatable {
    /// The person asked for a conversation: the dock shows Starting….
    case start
    case micReady
    case micFailed(title: String, message: String, detail: String?)
    case level(Double)
    case takeEnded(file: URL, heardSpeech: Bool, meterFailed: Bool, ms: Int)
    case transcript(String)
    case transcribeFailed(reason: String, detail: String?)
    case turnRunning(Bool)
    case reply(SpokenReply?)
    /// The first audio of the reply left the speaker.
    case speechStarted
    case speechFinished
    /// `fatal`: nothing can be played at all (an unplayable format), so the conversation stops.
    case speechFailed(reason: String, fatal: Bool, detail: String? = nil)
    case bargeSpeech
    case bargeUtterance(file: URL?)
    case muteToggled
    /// Read Replies Aloud was switched (the bar's Speak Replies, the voice options, Settings). Off mid-reply stops the
    /// voice; the reply carries on as text.
    case speaksReplies(Bool)
    case sendNow
    case stopOrInterrupt
    case end
    case connection(open: Bool)
    case tick
    case interrupted(TalkPauseCause, detail: String?)
    case questionWaiting(Bool)
    case otherAudio(Bool)
    /// The chat cannot send any more (gone, signed out).
    case chatClosed(reason: String)
    /// Something else took the microphone, or the chat went away.
    case finish(TalkEnd)
}

nonisolated enum TalkLoopEffect: Sendable, Equatable {
    case beginTake
    case finishTake
    case cancelTake
    case transcribe(file: URL)
    case discard(file: URL)
    case submit(text: String, interrupted: Bool)
    case stopTurn
    case openSpeech(messageId: String)
    case feedSpeech(text: String)
    case finishSpeech
    case stopSpeech
    case armBarge
    case disarmBarge
    case haptic(TalkHaptic)
    case ended(TalkEnd)
}

nonisolated struct TalkLoopState: Sendable, Equatable {
    var status: TalkStatus = .idle
    /// Read Replies Aloud: off makes the conversation speech-to-text only (rule 7).
    var speaksReplies: Bool
    var bargeIn: Bool
    var stopPhrases: TalkStopWord.Config
    var clock: TalkClock

    var started = false
    var micReady = false
    var listened = false
    var muted = false
    /// The loop muted itself for a question (it un-mutes itself when the question is answered).
    var autoMuted = false
    var connectionOpen = true
    var lostSpeech = false
    var takeOpen = false
    var takeTainted = false
    var forceSend = false
    var turnRunning = false
    var bargeArmed = false
    /// Speech began during the bot's turn; the utterance is still being recorded.
    var awaitingBargeUtterance = false
    /// The words being transcribed came from a barge-in (the echo guard applies).
    var transcribingBarge = false
    var interruptedAt: TimeInterval?
    /// Words waiting for a stopped turn to end before they are sent (T16).
    var pendingSubmit: String?
    var pendingSince: TimeInterval = 0
    var transcribeFailures = 0
    var meterFailures = 0
    /// The reply being spoken, and how far along it is.
    var speech: Speech = .none
    var speechFinishSent = false
    /// A reply that was already there when the prompt went out, or that was cut off: never spoken.
    var ignoredMessageId: String?
    var lastReply: SpokenReply?
    /// What the bot has been saying this turn, for the echo guard.
    var spokenText = ""
    var silence: SilenceClock
    var silenceState: TalkSilence = .ok
    /// One turn's failure, shown as the dock's hint until the next state change (§6.4): one short line.
    var problem: String?
    /// The whole of that failure, scrubbed, for Copy Details (read only while `problem` is set).
    var problemDetail: String?
    var ended = false

    enum Speech: Sendable, Equatable {
        case none, open(String), speaking(String), done
        var messageId: String? {
            switch self {
            case .open(let id), .speaking(let id): id
            case .none, .done: nil
            }
        }
    }

    init(now: TimeInterval, speaksReplies: Bool, config: TalkConfig = TalkConfig(), clock: TalkClock = TalkClock()) {
        self.speaksReplies = speaksReplies
        bargeIn = config.bargeIn
        stopPhrases = config.stopPhrases
        self.clock = clock
        silence = SilenceClock(now: now, clock: clock)
    }

    /// What the dock draws.
    func view(name: String) -> TalkDockView {
        TalkDockState.view(status: status, muted: muted, reconnecting: !connectionOpen, lostSpeech: lostSpeech, silence: silenceState,
                           listened: listened, name: name, bargeIn: bargeIn)
    }
}

nonisolated enum TalkLoop {
    static let meterFailure = "The microphone isn’t giving a level, so %@ can’t tell when you stop talking."

    static func reduce(_ state: inout TalkLoopState, _ input: TalkLoopInput, now: TimeInterval, app: String = "Hermes HQ") -> [TalkLoopEffect] {
        guard !state.ended else {
            // A take or an utterance that arrives after the end is only cleaned up.
            switch input {
            case .takeEnded(let file, _, _, _): return [.discard(file: file)]
            case .bargeUtterance(let file?): return [.discard(file: file)]
            default: return []
            }
        }
        var effects: [TalkLoopEffect] = []
        let before = state.status

        func setStatus(_ status: TalkStatus) {
            if state.status != status { state.problem = nil }
            state.status = status
        }
        /// Back to waiting for the person: a new take, unless muted.
        func listen() {
            setStatus(.listening)
            state.awaitingBargeUtterance = false
            state.transcribingBarge = false
            if state.bargeArmed { state.bargeArmed = false; effects.append(.disarmBarge) }
            guard !state.muted, state.micReady, !state.takeOpen else { return }
            state.takeOpen = true
            state.takeTainted = !state.connectionOpen
            state.forceSend = false
            state.listened = true
            effects.append(.beginTake)
        }
        func arm() {
            guard state.bargeIn, !state.muted, !state.bargeArmed else { return }
            state.bargeArmed = true
            effects.append(.armBarge)
        }
        func end(_ reason: TalkEnd) {
            state.ended = true
            if state.speech != .none, state.speech != .done { effects.append(.stopSpeech) }
            if state.takeOpen || state.awaitingBargeUtterance { effects.append(.cancelTake) }
            if state.bargeArmed { effects.append(.disarmBarge) }
            state.takeOpen = false
            state.bargeArmed = false
            state.speech = .none
            effects.append(.ended(reason))
        }
        func stopSpeaking() {
            if state.speech != .none, state.speech != .done { effects.append(.stopSpeech) }
            state.speech = .none
            state.speechFinishSent = false
            state.ignoredMessageId = state.lastReply?.messageId
        }
        func submit(_ text: String) {
            let interrupted = state.interruptedAt.map { now - $0 <= TalkClock.interruptedLifetime } ?? false
            state.interruptedAt = nil
            state.pendingSubmit = nil
            state.ignoredMessageId = state.lastReply?.messageId
            state.speech = .none
            state.speechFinishSent = false
            state.spokenText = ""
            state.turnRunning = true
            state.transcribingBarge = false
            setStatus(.thinking)
            effects.append(.submit(text: text, interrupted: interrupted))
            arm()
        }
        /// The turn and its speech are both over.
        func turnDoneIfQuiet() {
            guard state.status == .thinking || state.status == .speaking, !state.turnRunning else { return }
            switch state.speech {
            case .none, .done: listen()
            case .open, .speaking:
                if !state.speechFinishSent { state.speechFinishSent = true; effects.append(.finishSpeech) }
            }
        }

        func setMuted(_ muted: Bool, auto: Bool) {
            state.muted = muted
            state.autoMuted = muted && auto
            state.silence.reset(now: now)
            state.silenceState = .ok
            if muted {
                if state.takeOpen { state.takeOpen = false; effects.append(.cancelTake) }
                if state.awaitingBargeUtterance { state.awaitingBargeUtterance = false; effects.append(.cancelTake) }
                if state.bargeArmed { state.bargeArmed = false; effects.append(.disarmBarge) }
                if state.status == .listening { state.problem = nil }
            } else {
                switch state.status {
                case .listening, .idle: if state.micReady { listen() }
                case .thinking, .speaking: arm()
                case .transcribing: break
                }
            }
        }
        switch input {
        case .start:
            state.started = true
            state.silence.reset(now: now)

        case .micReady:
            guard state.started, !state.micReady else { break }
            state.micReady = true
            state.silence.reset(now: now)
            listen()

        case .micFailed(let title, let message, let detail):
            end(.stopped(title: title, message: message, detail: detail))

        case .level(let level):
            state.silence.observe(status: state.status, level: level, muted: state.muted, now: now)
            if level >= TalkClock.speechLevel { state.silenceState = .ok }

        case .takeEnded(let file, let heardSpeech, let meterFailed, let ms):
            guard state.takeOpen else { effects.append(.discard(file: file)); break }
            state.takeOpen = false
            let forced = state.forceSend
            state.forceSend = false
            if state.muted { effects.append(.discard(file: file)); break }
            if state.takeTainted || !state.connectionOpen {
                // Rule 4: said while the gateway was away. Never transcribed, never sent.
                if heardSpeech || forced { state.lostSpeech = true }
                effects.append(.discard(file: file))
                listen()
                break
            }
            if meterFailed, ms < TalkClock.meterFailureMinMs {
                state.meterFailures += 1
                effects.append(.discard(file: file))
                if state.meterFailures >= TalkClock.meterFailureLimit {
                    end(.stopped(title: "", message: String(format: meterFailure, app), detail: nil))
                } else {
                    listen()
                }
                break
            }
            state.meterFailures = 0
            guard heardSpeech || forced else {
                effects.append(.discard(file: file))
                listen()
                break
            }
            state.lostSpeech = false
            state.transcribingBarge = false
            setStatus(.transcribing)
            effects.append(.transcribe(file: file))

        case .transcript(let raw):
            guard state.status == .transcribing, state.pendingSubmit == nil else { break }
            state.transcribeFailures = 0
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { listen(); break }
            if state.transcribingBarge, TalkEcho.isEcho(text, of: state.spokenText) {
                // The microphone heard the bot's own voice.
                state.interruptedAt = nil
                listen()
                break
            }
            if TalkStopWord.isStop(text, config: state.stopPhrases) { end(.said); break }
            if !state.connectionOpen {
                state.lostSpeech = true
                listen()
                break
            }
            if state.turnRunning {
                // The stopped turn is still unwinding: the words wait for it (at most `bargeSettle`).
                state.pendingSubmit = text
                state.pendingSince = now
                break
            }
            submit(text)

        case .transcribeFailed(let reason, let detail):
            guard state.status == .transcribing else { break }
            state.transcribeFailures += 1
            if state.transcribeFailures >= TalkClock.transcribeFailureLimit {
                end(.stopped(title: "Voice Transcription Failed", message: TalkDockState.shortReason(reason) ?? "\(HostWord.sentence) couldn’t turn speech into text.",
                             detail: TalkDockState.noticeDetail(reason: reason, detail: detail)))
                break
            }
            effects.append(.haptic(.error))
            listen()
            state.problem = TalkDockState.problemLine("Voice Transcription Failed", reason: reason)
            state.problemDetail = TalkDockState.problemDetail("Voice Transcription Failed", reason: reason, detail: detail)

        case .turnRunning(let running):
            let was = state.turnRunning
            state.turnRunning = running
            guard was, !running else { break }
            if let text = state.pendingSubmit {
                submit(text)
            } else {
                turnDoneIfQuiet()
            }

        case .reply(let reply):
            state.lastReply = reply
            guard state.status == .thinking || state.status == .speaking, state.speaksReplies,
                  let reply, reply.messageId != state.ignoredMessageId else { break }
            let clean = SpeechText.sanitizeForSpeech(reply.text)
            switch state.speech {
            case .none:
                guard !clean.isEmpty else { break }
                state.speech = .open(reply.messageId)
                state.speechFinishSent = false
                state.spokenText = clean
                effects.append(.openSpeech(messageId: reply.messageId))
                effects.append(.feedSpeech(text: reply.text))
            case .open(let id), .speaking(let id):
                guard id == reply.messageId, clean != state.spokenText else { break }
                state.spokenText = clean
                effects.append(.feedSpeech(text: reply.text))
            case .done:
                break
            }
            if !reply.pending, case let id? = state.speech.messageId, id == reply.messageId, !state.speechFinishSent {
                state.speechFinishSent = true
                effects.append(.finishSpeech)
            }

        case .speechStarted:
            guard case .open(let id) = state.speech else { break }
            state.speech = .speaking(id)
            if state.status == .thinking { setStatus(.speaking) }

        case .speechFinished:
            guard state.speech != .none else { break }
            state.speech = .done
            turnDoneIfQuiet()
            if state.turnRunning, state.status == .speaking { setStatus(.thinking) }

        case .speechFailed(let reason, let fatal, let detail):
            guard state.speech != .none else { break }
            if fatal {
                end(.stopped(title: "Voice Playback Failed", message: TalkDockState.shortReason(reason) ?? "\(HostWord.sentence) couldn’t make the reply’s speech.",
                             detail: TalkDockState.noticeDetail(reason: reason, detail: detail)))
                break
            }
            state.speech = .done
            effects.append(.haptic(.error))
            if state.turnRunning {
                if state.status == .speaking { setStatus(.thinking) }
            } else {
                listen()
            }
            state.problem = TalkDockState.problemLine("Voice Playback Failed", reason: reason)
            state.problemDetail = TalkDockState.problemDetail("Voice Playback Failed", reason: reason, detail: nil)

        case .bargeSpeech:
            guard state.bargeArmed, state.status == .thinking || state.status == .speaking else { break }
            state.bargeArmed = false            // the capture is recording the utterance now
            stopSpeaking()
            state.interruptedAt = now
            if state.turnRunning { effects.append(.stopTurn) }
            state.awaitingBargeUtterance = true
            setStatus(.listening)
            state.silence.reset(now: now)

        case .bargeUtterance(let file):
            guard state.awaitingBargeUtterance else {
                if let file { effects.append(.discard(file: file)) }
                break
            }
            state.awaitingBargeUtterance = false
            guard let file, !state.muted else {
                if let file { effects.append(.discard(file: file)) }
                listen()
                break
            }
            if !state.connectionOpen {
                state.lostSpeech = true
                effects.append(.discard(file: file))
                listen()
                break
            }
            state.transcribingBarge = true
            setStatus(.transcribing)
            effects.append(.transcribe(file: file))

        case .muteToggled:
            setMuted(!state.muted, auto: false)

        case .speaksReplies(let on):
            state.speaksReplies = on
            guard !on, state.speech != .none, state.speech != .done else { break }
            stopSpeaking()
            if state.status == .speaking { setStatus(.thinking) }
            turnDoneIfQuiet()

        case .sendNow:
            guard state.status == .listening, state.takeOpen || state.awaitingBargeUtterance, !state.muted, state.connectionOpen else { break }
            if state.takeOpen { state.forceSend = true }
            effects.append(.finishTake)

        case .stopOrInterrupt:
            switch state.status {
            case .thinking:
                stopSpeaking()
                if state.turnRunning { effects.append(.stopTurn) }
                listen()
            case .speaking:
                stopSpeaking()
                state.interruptedAt = now
                if state.turnRunning { effects.append(.stopTurn) }
                listen()
            default: break
            }

        case .end:
            end(.user)

        case .connection(let open):
            state.connectionOpen = open
            if !open, state.takeOpen { state.takeTainted = true }

        case .tick:
            if let text = state.pendingSubmit, now - state.pendingSince >= TalkClock.bargeSettle {
                state.turnRunning = false
                submit(text)
                break
            }
            state.silence.observe(status: state.status, level: 0, muted: state.muted, now: now)
            let silence = state.awaitingBargeUtterance ? .ok : state.silence.state(status: state.status, muted: state.muted, now: now)
            state.silenceState = silence
            if silence == .pause { end(.paused(.silence, detail: nil)) }

        case .interrupted(let cause, let detail):
            end(.paused(cause, detail: detail))

        case .questionWaiting(let waiting):
            if waiting {
                if !state.muted { setMuted(true, auto: true) }
            } else if state.muted, state.autoMuted {
                setMuted(false, auto: false)
            }

        case .otherAudio(let playing):
            // T13: the conversation mutes itself and stays muted until the person taps Mute.
            if playing {
                if state.muted { state.autoMuted = false } else { setMuted(true, auto: false) }
            }

        case .chatClosed(let reason):
            end(.stopped(title: "Voice Transcription Failed", message: "This chat can’t send right now.", detail: reason.isEmpty ? nil : reason))

        case .finish(let reason):
            end(reason)
        }

        if before != state.status, state.status == .thinking || state.status == .speaking { state.silenceState = .ok }
        return effects
    }
}
