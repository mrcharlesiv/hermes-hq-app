// Grok Live on the wire (docs/spec/3x-grok-live.md §3): the add-on's two routes, xAI's realtime events, and what the
// phone sends back. Pure: no audio, no network, no UIKit. `GrokLiveCalls` is the session's own small state (which
// `ask_agent` calls wait for an answer, whether a response is in flight, the transcripts being built); the transport
// feeds it and does what it says.

import Foundation

/// `GET …/voice/grok-live/status`: whether the add-on can open a Grok Live session for this bot. Never contacts xAI.
nonisolated struct GrokLiveStatus: Sendable, Equatable {
    var available: Bool
    /// "subscription" (SuperGrok / X Premium+ login on the computer) or "api_key".
    var auth: String?
    var reason: String?
    var model: String?
    var voice: String?

    init(available: Bool, auth: String? = nil, reason: String? = nil, model: String? = nil, voice: String? = nil) {
        self.available = available
        self.auth = auth
        self.reason = reason
        self.model = model
        self.voice = voice
    }

    /// Nil for anything but an `ok` answer (an older add-on has no route: 404, standard only).
    init?(json: JSONValue?) {
        guard let json, case .bool(true)? = json["ok"] else { return nil }
        available = json["available"]?.bool ?? false
        auth = json["auth"]?.string
        reason = json["reason"]?.string
        model = json["model"]?.string
        voice = json["voice"]?.string
    }
}

/// `POST …/voice/grok-live/session`: a short-lived client secret and what the session is set up with.
nonisolated struct GrokLiveSession: Sendable, Equatable {
    var clientSecret: String
    var url: URL
    var voice: String?
    var instructions: String?
    var auth: String?
    var expiresAt: Double?

    init?(json: JSONValue?) {
        guard let json, json["ok"]?.bool != false,
              let secret = json["client_secret"]?.string ?? json["client_secret"]?["value"]?.string, !secret.isEmpty,
              let raw = json["url"]?.string, let url = URL(string: raw), ["wss", "ws"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        clientSecret = secret
        self.url = url
        voice = json["voice"]?.string
        instructions = json["instructions"]?.string
        auth = json["auth"]?.string
        expiresAt = json["expires_at"]?.double
    }
}

/// What xAI's realtime socket says that the phone acts on. Everything else is `.other`.
nonisolated enum GrokServerEvent: Sendable, Equatable {
    case sessionCreated
    case sessionUpdated
    /// The person's words: `final` is the whole item's transcript (`.completed`), else a piece of it.
    case inputTranscript(itemId: String, text: String, final: Bool)
    case outputTranscript(String)
    case audio(Data)
    case speechStarted
    case responseCreated
    case responseDone
    case functionCall(callId: String, name: String, arguments: String)
    case error(message: String, code: String?)
    case ping
    case other(type: String)

    static func parse(_ raw: String) -> GrokServerEvent? {
        guard let json = try? JSONValue.parse(Data(raw.utf8)), let type = json["type"]?.string else { return nil }
        switch type {
        case "session.created": return .sessionCreated
        case "session.updated": return .sessionUpdated
        case "conversation.item.input_audio_transcription.delta", "conversation.item.input_audio_transcription.updated":
            return .inputTranscript(itemId: json["item_id"]?.string ?? "", text: json["delta"]?.string ?? json["transcript"]?.string ?? "",
                                    final: false)
        case "conversation.item.input_audio_transcription.completed":
            return .inputTranscript(itemId: json["item_id"]?.string ?? "", text: json["transcript"]?.string ?? "", final: true)
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            return .outputTranscript(json["delta"]?.string ?? "")
        case "response.output_audio.delta", "response.audio.delta":
            guard let base64 = json["delta"]?.string, let data = Data(base64Encoded: base64), !data.isEmpty else { return .other(type: type) }
            return .audio(data)
        case "input_audio_buffer.speech_started": return .speechStarted
        case "response.created": return .responseCreated
        case "response.done", "response.cancelled": return .responseDone
        case "response.function_call_arguments.done":
            guard let id = json["call_id"]?.string, !id.isEmpty else { return .other(type: type) }
            return .functionCall(callId: id, name: json["name"]?.string ?? "", arguments: json["arguments"]?.string ?? "")
        case "error":
            return .error(message: json["error"]?["message"]?.string ?? json["message"]?.string ?? "Grok Live error",
                          code: json["error"]?["code"]?.string ?? json["error"]?["type"]?.string)
        case "ping": return .ping
        default: return .other(type: type)
        }
    }
}

nonisolated enum GrokLiveWire {
    static let route = "/api/plugins/hermes-hq-push/voice/grok-live"
    static let statusPath = route + "/status"
    static let sessionPath = route + "/session"
    /// The session POST asks the add-on, which asks xAI for a client secret.
    static let sessionTimeout: TimeInterval = 30
    /// The socket's first word (`session.created`) must come within this.
    static let openTimeout: TimeInterval = 15
    /// xAI's confirmation of the setup (`session.updated`) must come within this, or the standard engine takes over.
    static let setupTimeout: TimeInterval = 5
    static let setupTimeoutReason = "Grok Live didn’t confirm the voice setup."
    static let sampleRate = 24_000.0
    /// The answer a function call returns is kept under this many characters.
    static let answerLimit = 4_000
    static let toolName = "ask_agent"
    /// The WebSocket subprotocol that carries the client secret.
    static func subprotocol(_ secret: String) -> String { "xai-client-secret.\(secret)" }

    // MARK: Sent

    static func sessionUpdate(voice: String?, instructions: String?) -> String {
        var session: [String: JSONValue] = [
            "turn_detection": ["type": "server_vad"],
            "audio": [
                "input": ["format": ["type": "audio/pcm", "rate": .number(sampleRate)]],
                "output": ["format": ["type": "audio/pcm", "rate": .number(sampleRate)]],
            ],
            "tools": [[
                "type": "function",
                "name": .string(toolName),
                "description": "Send the person's request to their agent, which does the real work (tools, files, accounts, memory). Returns the agent's answer.",
                "parameters": [
                    "type": "object",
                    "properties": ["request": ["type": "string", "description": "The full request in the person's words"]],
                    "required": ["request"],
                ],
            ]],
        ]
        if let voice, !voice.isEmpty { session["voice"] = .string(voice) }
        if let instructions, !instructions.isEmpty { session["instructions"] = .string(instructions) }
        return event(["type": "session.update", "session": .object(session)])
    }

    /// The chat's seed (`LiveVoiceWire.history`'s message items), one `conversation.item.create` each.
    static func historyItems(_ history: JSONValue) -> [String] {
        (history.array ?? []).map { event(["type": "conversation.item.create", "item": $0]) }
    }

    static func append(_ pcm: Data) -> String {
        event(["type": "input_audio_buffer.append", "audio": .string(pcm.base64EncodedString())])
    }

    /// The agent's answer to an `ask_agent` call (`output` is a JSON string, as function outputs are).
    static func functionOutput(callId: String, answer: String, note: String? = nil) -> String {
        var fields: [String: JSONValue] = ["answer": .string(String(answer.prefix(answerLimit)))]
        if let note { fields["note"] = .string(note) }
        let output = String(decoding: (try? JSONValue.object(fields).encoded()) ?? Data(), as: UTF8.self)
        return event(["type": "conversation.item.create",
                      "item": ["type": "function_call_output", "call_id": .string(callId), "output": .string(output)]])
    }

    /// Something the agent said that the person did not ask for this moment (a bot's message, a finished job).
    static func agentSays(_ text: String) -> String {
        let words = String(LiveVoiceWire.collapse(text).prefix(answerLimit))
        return event(["type": "conversation.item.create",
                      "item": ["type": "message", "role": "user",
                               "content": [["type": "input_text",
                                            "text": .string("(Not from the person — your agent says:) \(words). Tell the person this briefly.")]]]])
    }

    static func responseCreate(instructions: String? = nil) -> String {
        guard let instructions, !instructions.isEmpty else { return #"{"type":"response.create"}"# }
        return event(["type": "response.create", "response": ["instructions": .string(instructions)]])
    }

    static let responseCancel = #"{"type":"response.cancel"}"#

    // Notes inside a function output (never naming a bot).
    static let noWordsNote = "The agent finished without a reply."
    static let notSentNote = "The request didn't go through. Tell the person to try again."
    static let replacedNote = "Replaced by the person's newer request."

    /// `{"request": "..."}` → the request, collapsed; nil when unreadable or empty.
    static func request(fromArguments arguments: String) -> String? {
        guard let json = try? JSONValue.parse(Data(arguments.utf8)), let text = json["request"]?.string else { return nil }
        let words = LiveVoiceWire.collapse(text)
        return words.isEmpty ? nil : words
    }

    static func event(_ fields: [String: JSONValue]) -> String {
        String(decoding: (try? JSONValue.object(fields).encoded()) ?? Data(), as: UTF8.self)
    }
}

/// What the transport does with an event or a request of the loop.
nonisolated enum GrokAction: Sendable, Equatable {
    case event(LiveServerEvent)
    case send(String)
    case play(Data)
    /// Stop the voice's audio now and drop what is queued (the person spoke over it).
    case flushPlayback
}

/// The session's own bookkeeping, apart from audio and the socket (tests drive it directly).
nonisolated struct GrokLiveCalls: Sendable, Equatable {
    /// `ask_agent` calls waiting for their output, oldest first.
    var open: [String] = []
    var responseInFlight = false
    var ready = false
    /// The person's words per input item so far (deltas), so a `.completed` adds only what is new.
    var heardItems: [String: String] = [:]

    /// A server event: what the transport should do. `ms` is the session's clock, for the transcript's times.
    mutating func receive(_ event: GrokServerEvent, ms: Int) -> [GrokAction] {
        switch event {
        case .sessionCreated, .other:
            return []
        case .ping:
            return []
        case .sessionUpdated:
            guard !ready else { return [] }
            ready = true
            return [.event(.started(sessionId: nil))]
        case .inputTranscript(let item, let text, let final):
            let before = heardItems[item] ?? ""
            var piece: String
            if final {
                piece = text.hasPrefix(before) ? String(text.dropFirst(before.count)) : (before.isEmpty ? text : "")
                heardItems[item] = nil
                if !piece.hasSuffix(" ") { piece += " " }
            } else {
                piece = text
                heardItems[item] = before + text
            }
            guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
            return [.event(.transcript(LiveTranscriptFragment(speaker: .user, text: piece, startMs: ms, endMs: ms)))]
        case .outputTranscript(let text):
            guard !text.isEmpty else { return [] }
            return [.event(.transcript(LiveTranscriptFragment(speaker: .assistant, text: text, startMs: ms, endMs: ms)))]
        case .audio(let data):
            return [.play(data)]
        case .speechStarted:
            // Barge-in: the voice stops at once, here and at xAI.
            var actions: [GrokAction] = [.flushPlayback]
            if responseInFlight { actions.append(.send(GrokLiveWire.responseCancel)) }
            return actions
        case .responseCreated:
            responseInFlight = true
            return []
        case .responseDone:
            responseInFlight = false
            return []
        case .functionCall(let id, let name, let arguments):
            guard name == GrokLiveWire.toolName else {
                return [.send(GrokLiveWire.functionOutput(callId: id, answer: "", note: "No such tool.")), .send(GrokLiveWire.responseCreate())]
            }
            // A newer request supersedes the open one (the loop does the same with the chat's turn).
            var actions = open.map { GrokAction.send(GrokLiveWire.functionOutput(callId: $0, answer: "", note: GrokLiveWire.replacedNote)) }
            open = [id]
            actions.append(.event(.askAgent(callId: id, request: GrokLiveWire.request(fromArguments: arguments) ?? "")))
            return actions
        case .error(let message, _):
            return [.event(.error(message: message))]
        }
    }

    /// The loop's `.speak`: an open call's answer, else news from the agent.
    mutating func speak(delegationId id: String?, text: String) -> [GrokAction] {
        if let id, let index = open.firstIndex(of: id) {
            open.remove(at: index)
            let output = text == LiveVoiceWire.couldNotReach
                ? GrokLiveWire.functionOutput(callId: id, answer: "", note: GrokLiveWire.notSentNote)
                : GrokLiveWire.functionOutput(callId: id, answer: text)
            return [.send(output), .send(GrokLiveWire.responseCreate())]
        }
        guard !LiveVoiceWire.collapse(text).isEmpty else { return [] }
        return [.send(GrokLiveWire.agentSays(text)), .send(GrokLiveWire.responseCreate())]
    }

    /// The loop's `.think`: only "ended without words" answers the call; progress notes stay out of Grok's ears.
    mutating func think(delegationId id: String?, text: String) -> [GrokAction] {
        guard text == LiveVoiceWire.noSpokenResult, let id, let index = open.firstIndex(of: id) else { return [] }
        open.remove(at: index)
        return [.send(GrokLiveWire.functionOutput(callId: id, answer: "", note: GrokLiveWire.noWordsNote)), .send(GrokLiveWire.responseCreate())]
    }

    /// The loop's `.instruct`: Send Now asks for a response, Interrupt cancels one; the GPT-Live persona note is not sent
    /// (the add-on's instructions carry it).
    mutating func instruct(_ text: String) -> [GrokAction] {
        switch text {
        case LiveVoiceWire.quietWhileWorking:
            return []
        case LiveVoiceWire.stopTalking:
            return [.flushPlayback, .send(GrokLiveWire.responseCancel)]
        default:
            return [.send(GrokLiveWire.responseCreate(instructions: text))]
        }
    }
}

/// [grok-live stages] What one Grok Live session got through, for the log: whether xAI confirmed the setup, how much
/// of the microphone went out (and how much was held back waiting for that), and the first of each thing that came
/// back. `note` answers a line to log the first time each stage is reached.
nonisolated struct GrokLiveStages: Sendable, Equatable {
    var confirmedMs: Int?
    /// Microphone pieces sent to xAI, and those dropped because the setup was not confirmed yet.
    var sent = 0
    var held = 0
    var firstAudioMs: Int?
    var audioChunks = 0
    var firstHeardMs: Int?
    var firstReplyWordsMs: Int?
    var firstToolMs: Int?
    var toolCalls = 0
    var errors = 0

    mutating func note(_ event: GrokServerEvent, ready: Bool, ms: Int) -> String? {
        switch event {
        case .sessionUpdated:
            guard confirmedMs == nil else { return nil }
            confirmedMs = ms
            return "grok-live setup confirmed at \(ms) ms"
        case .audio:
            audioChunks += 1
            guard firstAudioMs == nil else { return nil }
            firstAudioMs = ms
            return "grok-live first voice audio back at \(ms) ms"
        case .inputTranscript(_, let text, _):
            guard firstHeardMs == nil, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            firstHeardMs = ms
            return "grok-live first words heard at \(ms) ms"
        case .outputTranscript(let text):
            guard firstReplyWordsMs == nil, !text.isEmpty else { return nil }
            firstReplyWordsMs = ms
            return "grok-live first reply words at \(ms) ms"
        case .functionCall(_, let name, _):
            toolCalls += 1
            guard firstToolMs == nil else { return nil }
            firstToolMs = ms
            return "grok-live first tool call (\(name == GrokLiveWire.toolName ? name : "other")) at \(ms) ms, handed to the bot"
        case .error:
            errors += 1
            return nil
        default:
            return nil
        }
    }

    func summary(ready: Bool) -> String {
        func at(_ ms: Int?) -> String { ms.map { "\($0) ms" } ?? "never" }
        return "setup confirmed \(ready ? at(confirmedMs) : "no"), mic pieces sent \(sent) (held before setup \(held)), "
            + "voice audio back \(audioChunks) (first \(at(firstAudioMs))), words heard first \(at(firstHeardMs)), "
            + "reply words first \(at(firstReplyWordsMs)), tool calls \(toolCalls) (first \(at(firstToolMs))), errors \(errors)"
    }
}
