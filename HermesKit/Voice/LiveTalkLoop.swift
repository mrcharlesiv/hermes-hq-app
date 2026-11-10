// The GPT-Live conversation (docs/spec/3x-gpt-live.md §4): a pure reducer beside `TalkLoop`. The voice model owns the
// microphone and the speaker; this decides when a delegation becomes a Hermes turn, what of the reply goes back to be
// spoken, and when the conversation ends. It drives the same `TalkLoopState` the standard engine does, so the dock, the
// away pill and the paused / stopped notices are shared. Rules follow
// `HA:apps/desktop/src/app/chat/composer/hooks/use-voice-live-conversation.ts`.

import Foundation

nonisolated enum LiveTalkInput: Sendable, Equatable {
    case start
    /// `session.started`: the voice is listening.
    case sessionReady
    /// The session could not open (the gateway's answer, the microphone, WebRTC).
    case sessionFailed(title: String, message: String, detail: String?)
    case transcript(LiveTranscriptFragment)
    case delegation(id: String)
    /// [grok-live] A delegation that carries its own request (Grok's `ask_agent` argument): the bubble is that text.
    case askAgent(id: String, request: String)
    /// `prompt.submit` was refused before the turn ran.
    case submitFailed
    /// The voice's own audio is playing (or stopped).
    case assistantSpeaking(Bool)
    /// The microphone's level, 0…1.
    case level(Double)
    case turnRunning(Bool)
    case reply(SpokenReply?)
    /// The chat's finished replies since the conversation started, oldest first (`ChatVoiceTurns.spokenReplies`).
    case recentReplies([SpokenReply])
    /// The tool the running turn is in (its row's title), or nil.
    case tool(String?)
    case muteToggled
    case sendNow
    case stopOrInterrupt
    case end
    case connection(open: Bool)
    case tick
    case interrupted(TalkPauseCause, detail: String?)
    case questionWaiting(Bool)
    case otherAudio(Bool)
    /// OpenAI said something went wrong; the session goes on.
    case vendorError(String)
    /// The session ended without the phone asking (`session.closed`, or the transport dropped).
    case closed(reason: String, usageSeconds: Double?)
    case finish(TalkEnd)
}

nonisolated enum LiveTalkEffect: Sendable, Equatable {
    /// A Hermes turn: `text` is the bubble and the stored row, `context` rides the model input (`surface: voice-live`).
    case submit(text: String, context: String)
    case stopTurn
    case speak(delegationId: String?, text: String)
    case think(delegationId: String?, text: String)
    case instruct(String)
    case setMuted(Bool)
    case closeSession
    case haptic(TalkHaptic)
    case ended(TalkEnd)
    /// GPT-Live went away without the person ending it: the conversation goes on with the standard engine.
    case fallBack(reason: String)
}

nonisolated struct LiveTalkState: Sendable, Equatable {
    /// [grok-live] Which voice runs: Grok takes a delegation's answer whole (one function output), so a reply is passed
    /// on once its turn is over instead of sentence by sentence.
    var engine: TalkEngine = .gptLive
    var wholeAnswers: Bool { engine == .grokLive }
    var transcript: [LiveTranscriptFragment] = []
    var assistantSpeaking = false
    /// The delegation Hermes is answering; late replies for an older one are not spoken.
    var delegationId: String?
    /// The reply being spoken and how much of its speech text has gone out.
    var spokenReplyId: String?
    var spokenLength = 0
    /// A reply that was already there when the delegation went out: never spoken.
    var ignoredReplyId: String?
    var lastTool: String?
    /// The newest tool not yet passed on, and when a progress note last went out: one a while into a long turn, then
    /// rarely, as each one is spoken.
    var pendingTool: String?
    var toolNoteAt: TimeInterval?
    /// Everything heard since the last delegation went out (both speakers): the next request is built from it.
    var heard: [LiveTranscriptFragment] = []
    /// The turn was seen running (or answered): idle afterwards means it is over.
    var turnObserved = false
    var submittedAt: TimeInterval = 0
    /// The person's words since their last pause, judged whole for the stop phrase.
    var utterance = ""
    var utteranceAt: TimeInterval?
    /// How much of each reply's speech text has gone to the voice, whichever way it went: a delegation's stream, a turn
    /// the voice did not ask for, or a catch-up of rows the chat only read from history. Owner, 2026-10-28: Hermes
    /// answered the juno and inbox bots' results in the gateway, the phone only read those replies later, and the
    /// voice, never told, kept saying "still waiting". One conversation's replies, so never trimmed (an id dropped
    /// would be said again).
    var passedOn: [String: Int] = [:]
    /// The newest speech texts passed on whole, flattened: a reply read again under another id is not said twice.
    var passedTexts: [String] = []
    /// Replies a catch-up has settled, with the length of their text then: not cleaned for speech again (ten times a
    /// second while anything streams) until that text changes.
    var caughtUp: [String: Int] = [:]
}

nonisolated enum LiveTalkLoop {
    /// An accepted delegation may sit this long before "idle and no reply" reads as a finished turn.
    static let submitSettleGrace: TimeInterval = 15
    /// Quiet after the person's last words before the utterance is judged as a whole ("stop" ends the chat; "stop the
    /// container" is a request).
    static let utteranceSettle: TimeInterval = 1.5
    /// A progress note waits this long into a turn, and this long after the last one.
    static let toolNoteAfter: TimeInterval = 20
    static let toolNoteEvery: TimeInterval = 45
    /// `heard` is bounded; a request is never this long.
    static let heardKeep = 400
    /// `delegationId` for a turn the voice did not ask for (a bot's message, a finished background job, a schedule):
    /// its answer is spoken too (with no delegation), and the wait is not counted as silence. Owner, build 407: the
    /// conversation paused on silence while a reply to the inbox bot's message sat unspoken.
    static let otherTurn = ""
    /// `passedTexts` is bounded.
    static let passedTextsKeep = 12
    /// A reply this long found inside one already said is a copy of it; a shorter one ("Done.") may just be the same words.
    static let copyWithin = 40

    static func reduce(_ state: inout TalkLoopState, _ live: inout LiveTalkState, _ input: LiveTalkInput, now: TimeInterval) -> [LiveTalkEffect] {
        guard !state.ended else { return [] }
        var effects: [LiveTalkEffect] = []
        let before = state.status

        func refreshStatus() {
            let next: TalkStatus
            if !state.micReady {
                next = .idle
            } else if live.assistantSpeaking {
                next = .speaking
            } else if live.delegationId != nil {
                next = .thinking
            } else {
                next = .listening
            }
            if next != state.status { state.problem = nil }
            state.status = next
        }
        func end(_ reason: TalkEnd) {
            state.ended = true
            live.delegationId = nil
            effects.append(.closeSession)
            effects.append(.ended(reason))
        }
        func setMuted(_ muted: Bool, auto: Bool) {
            guard state.muted != muted else { state.autoMuted = muted && auto && state.autoMuted; return }
            state.muted = muted
            state.autoMuted = muted && auto
            state.silence.reset(now: now)
            state.silenceState = .ok
            effects.append(.setMuted(muted))
        }
        func clearDelegation() {
            live.delegationId = nil
            refreshStatus()
        }
        /// Note how much of a reply has gone to the voice.
        func passed(_ id: String, upTo length: Int, of spoken: String) {
            let before = live.passedOn[id]
            guard before.map({ length > $0 }) ?? true else { return }
            live.passedOn[id] = length
            if length >= spoken.count, !spoken.isEmpty {
                live.passedTexts.append(flat(spoken))
                if live.passedTexts.count > passedTextsKeep { live.passedTexts.removeFirst(live.passedTexts.count - passedTextsKeep) }
            }
        }
        /// Replies the chat holds that nothing has passed on: a turn the phone never saw running (Hermes answering a bot's
        /// message, a background job's report, in the gateway), one under a "Message from" row (never the newest reply),
        /// or a delegation's answer that came after the delegation was let go. Said whole, as general session context.
        func catchUp(_ replies: [SpokenReply]) {
            for reply in replies where !reply.pending && live.caughtUp[reply.messageId] != reply.text.count {
                // The newest reply is the feed's while a delegation (or a turn the voice did not ask for) is open, unless
                // it was there before that went out (the feed never says it).
                if live.delegationId != nil, reply.messageId == state.lastReply?.messageId, reply.messageId != live.ignoredReplyId { continue }
                live.caughtUp[reply.messageId] = reply.text.count
                let spoken = speech(reply)
                let done = live.passedOn[reply.messageId] ?? 0
                guard done < spoken.count else { continue }
                let words = flat(spoken)
                if done == 0, live.passedTexts.contains(where: { $0 == words || (words.count >= copyWithin && $0.contains(words)) }) {
                    live.passedOn[reply.messageId] = spoken.count
                    continue
                }
                let rest = String(Array(spoken)[done...])
                effects.append(.speak(delegationId: nil, text: rest))
                passed(reply.messageId, upTo: spoken.count, of: spoken)
            }
        }

        /// Pass the reply on: whole sentences while it streams, the rest once the turn is over.
        func feed() {
            guard let delegation = live.delegationId, let reply = state.lastReply, reply.messageId != live.ignoredReplyId else { return }
            let id = delegation == otherTurn ? nil : delegation
            live.turnObserved = true
            let spoken = speech(reply)
            let characters = Array(spoken)
            if live.spokenReplyId != reply.messageId {
                live.spokenReplyId = reply.messageId
                live.spokenLength = 0
            }
            // What went out another way (a catch-up while this reply was not the newest) is not said again.
            live.spokenLength = max(live.spokenLength, min(live.passedOn[reply.messageId] ?? 0, characters.count))
            defer { passed(reply.messageId, upTo: live.spokenLength, of: spoken) }
            if reply.pending || state.turnRunning {
                if live.wholeAnswers { return }   // [grok-live] one answer, once the turn is over
                // The last ". " before the end: everything up to it is a finished sentence.
                var cut = live.spokenLength
                if characters.count >= 3 {
                    var index = characters.count - 3
                    while index >= live.spokenLength {
                        if characters[index] == ".", characters[index + 1] == " " { cut = index + 1; break }
                        index -= 1
                    }
                }
                if cut > live.spokenLength {
                    effects.append(.speak(delegationId: id, text: String(characters[live.spokenLength..<cut])))
                    live.spokenLength = cut
                }
                return
            }
            if characters.count > live.spokenLength {
                effects.append(.speak(delegationId: id, text: String(characters[live.spokenLength...])))
                live.spokenLength = characters.count
            }
            clearDelegation()
        }
        /// A progress note for the newest tool, when one is due.
        func noteTool() {
            guard let id = live.delegationId, id != otherTurn, let tool = live.pendingTool, now - live.submittedAt >= toolNoteAfter,
                  live.toolNoteAt.map({ now - $0 >= toolNoteEvery }) ?? true else { return }
            live.pendingTool = nil
            live.toolNoteAt = now
            effects.append(.think(delegationId: id, text: LiveVoiceWire.toolNote(tool)))
        }
        /// An idle chat after the grace with nothing spoken: the turn ended without words (tools only, an error, Stop).
        func settleIfQuiet() {
            guard let id = live.delegationId, !state.turnRunning,
                  live.turnObserved || now - live.submittedAt > submitSettleGrace else { return }
            if live.spokenLength == 0, id != otherTurn { effects.append(.think(delegationId: id, text: LiveVoiceWire.noSpokenResult)) }
            clearDelegation()
        }

        /// A delegation becomes a turn: `asked` is the request when the voice said it (Grok's tool argument), else
        /// everything the person said since the last one.
        func delegate(_ id: String, asked: String?) {
            let (lastTurn, context) = LiveVoiceWire.delegationPrompt(LiveVoiceWire.contextWindow(live.transcript))
            let request = asked.map(LiveVoiceWire.collapse) ?? LiveVoiceWire.spokenRequest(live.heard)
            let prompt = request.isEmpty ? lastTurn : request
            live.heard = []
            // The voice answers a bare "stop" itself and rarely delegates it; when it does, it ends the chat.
            if !prompt.isEmpty, TalkStopWord.isStop(prompt, config: state.stopPhrases) { end(.said); return }
            guard !prompt.isEmpty else { effects.append(.think(delegationId: id, text: LiveVoiceWire.noSpokenResult)); return }
            // A newer request supersedes the one still running: the answer spoken is for what was asked last. The chat
            // steers it into the running reply (or stops that reply when it can't), so the work done so far is kept
            // (owner, 2026-10-28: one thought split into two requests 3 s apart, and the second stopped the first's
            // searches). What the voice had begun saying of the reply so far is not caught up later.
            if state.turnRunning, let id = state.lastReply?.messageId, live.passedOn[id] != nil { live.passedOn[id] = .max }
            live.delegationId = id
            live.spokenReplyId = nil
            live.spokenLength = 0
            live.lastTool = nil
            live.pendingTool = nil
            live.toolNoteAt = nil
            live.turnObserved = false
            live.submittedAt = now
            live.ignoredReplyId = state.lastReply?.messageId
            effects.append(.submit(text: prompt, context: context))
            refreshStatus()
        }

        switch input {
        case .start:
            state.started = true
            state.silence.reset(now: now)

        case .sessionReady:
            guard state.started, !state.micReady else { break }
            state.micReady = true
            state.listened = true
            state.silence.reset(now: now)
            effects.append(.instruct(LiveVoiceWire.quietWhileWorking))
            if state.muted { effects.append(.setMuted(true)) }
            refreshStatus()

        case .sessionFailed(let title, let message, let detail):
            end(.stopped(title: title, message: message, detail: detail))

        case .transcript(let fragment):
            live.transcript.append(fragment)
            if live.transcript.count > LiveVoiceWire.transcriptKeep.limit {
                live.transcript.removeFirst(live.transcript.count - LiveVoiceWire.transcriptKeep.trimTo)
            }
            live.heard.append(fragment)
            if live.heard.count > heardKeep { live.heard.removeFirst(live.heard.count - heardKeep) }
            guard fragment.speaker == .user else { break }
            state.silence.reset(now: now)
            state.silenceState = .ok
            live.utterance += fragment.text
            live.utteranceAt = now

        case .delegation(let id):
            delegate(id, asked: nil)

        case .askAgent(let id, let request):
            delegate(id, asked: request)

        case .submitFailed:
            guard let id = live.delegationId, id != otherTurn else { break }
            effects.append(.speak(delegationId: id, text: LiveVoiceWire.couldNotReach))
            effects.append(.haptic(.error))
            clearDelegation()

        case .assistantSpeaking(let speaking):
            live.assistantSpeaking = speaking
            refreshStatus()

        case .level(let level):
            state.silence.observe(status: state.status, level: level, muted: state.muted, now: now)
            if level >= TalkClock.speechLevel { state.silenceState = .ok }

        case .turnRunning(let running):
            let started = running && !state.turnRunning
            state.turnRunning = running
            if started, live.delegationId == nil {
                live.delegationId = otherTurn
                live.spokenReplyId = nil
                live.spokenLength = 0
                live.lastTool = nil
                live.pendingTool = nil
                live.toolNoteAt = nil
                live.submittedAt = now
                live.ignoredReplyId = state.lastReply?.messageId
                refreshStatus()
            }
            if running, live.delegationId != nil { live.turnObserved = true }
            guard !running else { break }
            feed()
            settleIfQuiet()

        case .reply(let reply):
            state.lastReply = reply
            feed()

        case .recentReplies(let replies):
            guard state.micReady else { break }
            catchUp(replies)

        case .tool(let tool):
            guard let id = live.delegationId, let tool, tool != live.lastTool else { break }
            live.lastTool = tool
            live.pendingTool = tool
            noteTool()

        case .muteToggled:
            setMuted(!state.muted, auto: false)

        case .sendNow:
            guard state.micReady, !state.muted else { break }
            effects.append(.instruct(LiveVoiceWire.respondNow))

        case .stopOrInterrupt:
            if state.turnRunning { effects.append(.stopTurn) }
            if live.assistantSpeaking { effects.append(.instruct(LiveVoiceWire.stopTalking)) }
            if live.delegationId != nil {
                live.ignoredReplyId = state.lastReply?.messageId
                clearDelegation()
            }
            // What the voice was cut off saying is not caught up later (a reply begun is the one interrupted).
            if let id = state.lastReply?.messageId, live.passedOn[id] != nil { live.passedOn[id] = .max }

        case .end:
            end(.user)

        case .connection(let open):
            state.connectionOpen = open

        case .tick:
            if let at = live.utteranceAt, now - at >= utteranceSettle {
                let words = live.utterance
                live.utterance = ""
                live.utteranceAt = nil
                if TalkStopWord.isStop(words, config: state.stopPhrases) { end(.said); break }
            }
            noteTool()
            settleIfQuiet()
            state.silence.observe(status: state.status, level: 0, muted: state.muted, now: now)
            let silence = state.silence.state(status: state.status, muted: state.muted, now: now)
            state.silenceState = silence
            // Idle time is billed: a long silence ends the session as the standard engine pauses.
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
            if playing {
                if state.muted { state.autoMuted = false } else { setMuted(true, auto: false) }
            }

        case .vendorError(let message):
            effects.append(.haptic(.warning))
            state.problem = TalkDockState.problemLine(live.engine.title, reason: message)
            state.problemDetail = TalkDockState.problemDetail(live.engine.title, reason: message, detail: nil)

        case .closed(let reason, _):
            // Not the person's doing (their end is recorded first, and nothing comes after it): carry on without it.
            live.delegationId = nil
            effects.append(.fallBack(reason: reason))

        case .finish(let reason):
            end(reason)
        }

        if before != state.status, state.status == .thinking || state.status == .speaking { state.silenceState = .ok }
        return effects
    }
}

nonisolated extension LiveVoiceWire {
    /// Interrupt while the voice speaks: there is no "cancel" event in client delegation, so it is told.
    static let stopTalking = "The user interrupted. Stop speaking now and listen."
}

nonisolated extension LiveTalkLoop {
    /// What of a reply the voice is given: its words cleaned for speech, nothing for the bot's way of saying nothing.
    static func speech(_ reply: SpokenReply) -> String {
        Hydration.isSilentWords(reply.text) ? "" : SpeechText.sanitizeForSpeech(reply.text)
    }

    static func flat(_ text: String) -> String { LiveVoiceWire.collapse(text).lowercased() }
}
