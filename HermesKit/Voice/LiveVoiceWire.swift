// GPT-Live on the wire (docs/spec/3x-gpt-live.md §3): what the gateway answers, what OpenAI's `oai-events` data channel
// says, and what the phone sends back. A port of `HA:apps/desktop/src/lib/voice-live.ts` and the prompt shaping of
// `HA:apps/desktop/src/app/chat/composer/hooks/use-voice-live-conversation.ts`. Pure: no audio, no network, no UIKit.

import Foundation

/// Which conversation engine a Talk start uses.
nonisolated enum TalkEngine: String, Sendable, Equatable, CaseIterable {
    /// Microphone take → the gateway's speech to text → the turn → the gateway's speech (docs/spec/3x-talk.md).
    case standard = "chained"
    /// OpenAI's full-duplex `gpt-live-1`, which hands every real request to Hermes (`voice.voice_chat_mode: gpt-live`).
    case gptLive = "gpt-live"
    /// [grok-live] xAI's realtime voice over the add-on's client secret; its `ask_agent` tool is the delegation
    /// (docs/spec/3x-grok-live.md). Only ever this device's choice: no gateway mode names it.
    case grokLive = "grok-live"

    /// One of the full-duplex engines (the shared `LiveTalkLoop` runs it).
    var isLive: Bool { self != .standard }

    /// What Settings and the dock's problem line call it.
    var title: String {
        switch self {
        case .standard: "Standard"
        case .gptLive: "GPT-Live"
        case .grokLive: "Grok Live"
        }
    }

    /// `voice.voice_chat_mode` as the gateway spells it: `gpt-live` (or `gpt_live`, `gptlive`, `live`), else standard
    /// (`HA:tools/voice_live.py:107-111`).
    init(mode: String?) {
        let raw = (mode ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        self = ["gpt-live", "gptlive", "live"].contains(raw) ? .gptLive : .standard
    }
}

/// `GET /api/audio/voice-live/status`: non-secret, never contacts OpenAI (`HA:tools/voice_live.py:131-144`).
nonisolated struct LiveVoiceStatus: Sendable, Equatable {
    var mode: TalkEngine
    /// A key resolves on the gateway. Not proof OpenAI accepts it: the session start says that.
    var available: Bool
    var reason: String?
    var model: String
    var voice: String

    init(mode: TalkEngine, available: Bool, reason: String? = nil, model: String = "gpt-live-1", voice: String = "marin") {
        self.mode = mode
        self.available = available
        self.reason = reason
        self.model = model
        self.voice = voice
    }

    /// Nil for anything but an `ok` answer (an older gateway has no route: standard only).
    init?(json: JSONValue?) {
        guard let json, case .bool(true)? = json["ok"] else { return nil }
        mode = TalkEngine(mode: json["mode"]?.string)
        if case .bool(let on)? = json["available"] { available = on } else { available = false }
        reason = json["reason"]?.string
        model = json["model"]?.string ?? "gpt-live-1"
        voice = json["voice"]?.string ?? "marin"
    }
}

/// One piece of the live transcript (`session.input_transcript.delta` / `session.output_transcript.delta`).
nonisolated struct LiveTranscriptFragment: Sendable, Equatable {
    enum Speaker: String, Sendable { case user, assistant }
    var speaker: Speaker
    var text: String
    var startMs: Int
    var endMs: Int
}

/// What the `oai-events` channel says that the phone acts on. Everything else is `.other`.
nonisolated enum LiveServerEvent: Sendable, Equatable {
    case started(sessionId: String?)
    case transcript(LiveTranscriptFragment)
    case delegation(id: String)
    /// [grok-live] An `ask_agent` call: the request is the tool's argument, not the transcript.
    case askAgent(callId: String, request: String)
    /// The user talked over the voice or the vendor cancelled/truncated its spoken response before it finished.
    case bargeIn
    /// `context_injection_incomplete` (a late append after our own close) is expected noise and is dropped here.
    case error(message: String)
    case closed(reason: String, usageSeconds: Double?)
    case other(type: String)

    static func parse(_ raw: String) -> LiveServerEvent? {
        guard let json = try? JSONValue.parse(Data(raw.utf8)), let type = json["type"]?.string else { return nil }
        switch type {
        case "session.started":
            return .started(sessionId: json["session"]?["id"]?.string)
        case "session.input_transcript.delta", "session.output_transcript.delta":
            return .transcript(LiveTranscriptFragment(speaker: type == "session.input_transcript.delta" ? .user : .assistant,
                                                      text: json["delta"]?.string ?? "",
                                                      startMs: Self.int(json["start_ms"]), endMs: Self.int(json["end_ms"])))
        case "session.delegation.created":
            guard let id = json["delegation"]?["id"]?.string, !id.isEmpty else { return .other(type: type) }
            return .delegation(id: id)
        case "input_audio_buffer.speech_started", "response.cancelled":
            return .bargeIn
        case "response.done":
            let status = json["response"]?["status"]?.string
            if status == "cancelled" || status == "incomplete" { return .bargeIn }
            return .other(type: type)
        case "error":
            if json["error"]?["code"]?.string == "context_injection_incomplete" { return .other(type: type) }
            return .error(message: json["error"]?["message"]?.string ?? "GPT-Live error")
        case "session.closed":
            var seconds: Double?
            if case .number(let value)? = json["usage"]?["seconds"] { seconds = value }
            return .closed(reason: json["reason"]?.string ?? "closed", usageSeconds: seconds)
        default:
            return .other(type: type)
        }
    }

    private static func int(_ value: JSONValue?) -> Int {
        if case .number(let number)? = value, number.isFinite { return Int(number) }
        return 0
    }
}

nonisolated enum LiveVoiceWire {
    /// OpenAI's cap is 500 tokens per append; ~4 characters a token, with headroom (`voice-live.ts:75-76`).
    static let appendCharLimit = 1_400
    /// How much of the spoken conversation rides a delegation (`voice-live.ts:77-79`).
    static let contextWindowMs = 5 * 60_000
    static let contextMaxFragments = 80
    /// What a new session is seeded with (`toLiveHistory`). The desktop's 24 messages and 6,000 characters (`narrowSeed`)
    /// were about five replies of a working chat, each cut short: the owner, 2026-11-16, "it doesn't have the full
    /// context for what I've been talking about with that bot". The vendors publish no limit for the seed, so a session
    /// the wide one is refused for is asked for again with the narrow one.
    struct SeedBudget: Sendable, Equatable {
        var messages: Int
        var chars: Int
        var perTurn: Int
    }
    static let wideSeed = SeedBudget(messages: 40, chars: 12_000, perTurn: 1_500)
    static let narrowSeed = SeedBudget(messages: 24, chars: 6_000, perTurn: 1_200)
    static var historyMaxMessages: Int { wideSeed.messages }
    static var historyMaxChars: Int { wideSeed.chars }
    /// The transcript kept in memory (`voice-live.ts:407-409`).
    static let transcriptKeep = (limit: 2_000, trimTo: 1_500)
    /// `session.close` waits this long for `session.closed` before tearing down (`voice-live.ts:73`).
    static let closeTimeout: TimeInterval = 15
    /// ICE gathering is capped; the vendor answers with the candidates it has (`voice-live.ts:74` waits 10 s). Build 409:
    /// a start right after the phone woke waited ~8 s here for a slow interface (cellular, the VPN) to finish, against
    /// 0.5-2 s on other starts. No ICE servers are set, so every candidate is a host one and the first lands in
    /// milliseconds; OpenAI's own sample posts the offer without waiting at all.
    static let iceGatherTimeout: TimeInterval = 1.5
    /// Once the first candidate is in, the others get this long before the offer goes.
    static let iceGraceAfterFirst: TimeInterval = 0.3
    /// The session POST: the gateway allows 30 s for OpenAI, the desktop 45 s in all (`voice-live.ts:335`).
    static let sessionTimeout: TimeInterval = 45
    /// The gateway keeps this much of `voice_context` (`HA:tui_gateway/server.py`, `_VOICE_CONTEXT_MAX`).
    static let voiceContextLimit = 6_000
    static let statusPath = "/api/audio/voice-live/status"
    static let sessionPath = "/api/audio/voice-live/session"

    /// The session POST's body: the offer byte for byte, and the chat's seed when there is one.
    static func sessionBody(sdp: String, history: JSONValue) -> Data {
        var fields: [String: JSONValue] = ["sdp": .string(sdp)]
        if case .array(let items) = history, !items.isEmpty { fields["history"] = history }
        return (try? JSONValue.object(fields).encoded()) ?? Data()
    }

    /// The answer's SDP, or nil.
    static func answerSDP(_ data: Data) -> String? {
        guard let json = try? JSONValue.parse(data), json["ok"]?.bool != false,
              json["transport"]?["type"]?.string == "webrtc", let sdp = json["transport"]?["sdp"]?.string, !sdp.isEmpty else { return nil }
        return sdp
    }

    // MARK: Sent on the data channel

    static func thinking(delegationId: String?, _ content: String) -> String? {
        let text = String(collapse(content).prefix(appendCharLimit))
        guard !text.isEmpty else { return nil }
        return event(["type": "session.thinking.append", "content": .string(text), "delegation_id": id(delegationId)])
    }

    /// One `session.commentary.append` per chunk: the voice says them aloud, paraphrased.
    static func commentary(delegationId: String?, _ content: String) -> [String] {
        chunks(content).map { event(["type": "session.commentary.append", "content": .string($0), "delegation_id": id(delegationId)]) }
    }

    static func instructions(_ content: String) -> String? {
        let text = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(appendCharLimit))
        guard !text.isEmpty else { return nil }
        return event(["type": "session.instructions.append", "content": .string(text), "delegation_id": .null])
    }

    static func mute(_ muted: Bool) -> String { event(["type": .string(muted ? "session.input_audio.mute" : "session.input_audio.unmute")]) }
    static let close = #"{"type":"session.close"}"#

    /// "Respond now": full duplex has no turn boundary to press (`use-voice-live-conversation.ts:474-476`).
    static let respondNow = "The user has finished speaking. Respond now to what they said."

    // No bot name in what the voice hears or says (2026-10-27): the voice in Otto's chat that said "Hermes is still
    // working" or "I could not reach Hermes" told the owner their bot had handed the work to another bot.
    static func toolNote(_ tool: String) -> String {
        "Still working on it (\(tool)). Not done yet. Say nothing about this unless the user asks."
    }
    /// Sent once the session starts (owner, build 407: "the agent does use an odd amount of filler words while it is
    /// working"): the vendor persona asks for backchannels and a word while checking, and each one was spoken.
    /// Owner, 2026-11-18: the voice spoke of the bot as a separate party ("your agent") and narrated the wait
    /// ("Sending that…", "Still waiting on the answer"): it is one assistant, and delegating is how it does the work.
    static let quietWhileWorking = "No backchannels: do not say mm-hmm, okay, right or similar while the user is speaking; "
        + "stay silent until they finish. You are one assistant: speak in the first person, as the one doing the work. "
        + "Never speak of anyone else doing it, never name a bot or a helper, and never say you are passing a request on "
        + "or holding for an answer. While the work runs, say at most one short line such as \"Let me look.\", then stay "
        + "silent until the result arrives; if the user speaks meanwhile, answer them directly. Do not narrate progress "
        + "notes or tool names and do not fill silence with small talk. " + statusFromTheBackend
    /// Owner, 2026-10-28: asked "Progress?", the voice answered from memory ("still waiting on the login check") while
    /// the bot's result had come back a minute before; asked what it had found, it said "pending" three times.
    static let statusFromTheBackend = "When the user asks how something is going, what came back, or whether work is "
        + "happening, delegate it: only the work itself knows. Never say something is still pending or being checked "
        + "unless the latest update says so. When a result arrives, say that result briefly in your own words and "
        + "nothing else."
    /// Sent with a seeded session. The voice sees only the chat's last few messages and answered from those alone, or
    /// asked the person to explain what the bot already knew (owner, 2026-11-16); later it recapped them instead of
    /// the answer (2026-11-18). Names no bot (see `toolNote`).
    static let chatNote = "You are joining a chat that is already under way. The messages you were given are background "
        + "only, its latest part, shortened: never recap, summarize or list them. Delegated work has the whole chat and "
        + "everything remembered about the user. When the user refers to anything from before that you cannot see, do "
        + "not ask them to explain it and do not guess: delegate the request as they said it."
    /// Rides every delegation's `voice_context` (model input only), ahead of the spoken exchange. The owner, 2026-11-16,
    /// app closed and a voice chat going: the bot asked with a question card, which only a tap answers.
    static let spokenOnlyNote = "(From the app, not said by the user: they are talking with you by voice and are not looking at "
        + "the screen; the app may be closed. Do not ask with a question card or the clarify tool. If you need to know "
        + "something, ask it in your spoken reply in one short sentence, or make the sensible choice and say which you chose.)"

    /// `voice_context` as sent: the note, then the newest of the spoken exchange that fits the gateway's limit.
    static func voiceContext(_ exchange: String) -> String {
        guard !exchange.isEmpty else { return spokenOnlyNote }
        return spokenOnlyNote + "\n" + String(exchange.suffix(voiceContextLimit - spokenOnlyNote.count - 1))
    }

    /// A delegation made before the person had said a word is not run (`LiveTalkLoop`).
    static let nobodyAsked = "That was not sent: the user has not spoken yet, so nobody asked for it. Do not act on the "
        + "earlier messages. Wait for the person to speak."
    static let noSpokenResult = "That request finished without a spoken result."
    static let couldNotReach = "Sorry, that request didn't go through. Please try again."

    // MARK: Shaping

    /// A reply in append-sized pieces, cut on sentence ends (`chunkForCommentary`).
    static func chunks(_ text: String, limit: Int = appendCharLimit) -> [String] {
        let clean = collapse(text)
        guard !clean.isEmpty else { return [] }
        guard clean.count > limit else { return [clean] }
        var out: [String] = [], current = ""
        for sentence in sentences(clean) {
            if sentence.count > limit {
                if !current.isEmpty { out.append(current); current = "" }
                var rest = Substring(sentence)
                while !rest.isEmpty { out.append(String(rest.prefix(limit))); rest = rest.dropFirst(limit) }
                continue
            }
            let candidate = current.isEmpty ? sentence : current + " " + sentence
            if candidate.count > limit { out.append(current); current = sentence } else { current = candidate }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The Hermes turn a delegation becomes (`delegationPrompt`): `prompt` is what the person said last (the bubble and
    /// the stored row), `context` the recent spoken exchange, which rides the model input only.
    static func delegationPrompt(_ fragments: [LiveTranscriptFragment]) -> (prompt: String, context: String) {
        var turns: [(speaker: LiveTranscriptFragment.Speaker, text: String)] = []
        for fragment in fragments {
            if let last = turns.last, last.speaker == fragment.speaker {
                turns[turns.count - 1].text += fragment.text
            } else {
                turns.append((fragment.speaker, fragment.text))
            }
        }
        let lastUser = turns.last { $0.speaker == .user }.map { collapse($0.text) } ?? ""
        let transcript = turns.compactMap { turn -> String? in
            let words = collapse(turn.text)
            return words.isEmpty ? nil : "\(turn.speaker == .user ? "User" : "Voice assistant"): \(words)"
        }.joined(separator: "\n")
        return (lastUser.isEmpty ? String(transcript.suffix(400)) : lastUser, transcript)
    }

    /// The voice's turn this long or longer is an answer, not a backchannel ("mm-hmm", "let me check that").
    static let answerWords = 10

    /// What the person asked for: every word they said since the last delegation, joined across the voice's
    /// backchannels. Full duplex, the voice's "mm-hmm" mid-sentence split the person's words, and only the piece after
    /// it reached the chat (owner, build 407: "some random parts of what i say are put in the chat", stored as
    /// ". I think we should change them to 6.1 Terra too"). An answer from the voice in between starts it afresh.
    static func spokenRequest(_ heard: [LiveTranscriptFragment]) -> String {
        var turns: [(speaker: LiveTranscriptFragment.Speaker, text: String)] = []
        for fragment in heard {
            if let last = turns.last, last.speaker == fragment.speaker {
                turns[turns.count - 1].text += fragment.text
            } else {
                turns.append((fragment.speaker, fragment.text))
            }
        }
        var parts: [String] = []
        for turn in turns {
            let words = collapse(turn.text)
            if turn.speaker == .user {
                if !words.isEmpty { parts.append(words) }
            } else if words.split(separator: " ").count >= answerWords {
                parts = []
            }
        }
        let joined = parts.joined(separator: " ")
        return String(joined.drop { " .,;:!?-–—".contains($0) })
    }

    /// The recent conversation, oldest first, bounded by time and count (`contextWindow`).
    static func contextWindow(_ transcript: [LiveTranscriptFragment]) -> [LiveTranscriptFragment] {
        guard let last = transcript.last else { return [] }
        let floor = last.endMs - contextWindowMs
        return Array(transcript.filter { $0.endMs >= floor }.suffix(contextMaxFragments))
    }

    /// A new session's seed from the chat's text turns, newest kept first within the budget (`toLiveHistory`).
    static func history(_ turns: [(assistant: Bool, text: String)], budget seed: SeedBudget = wideSeed) -> JSONValue {
        var out: [JSONValue] = []
        var budget = seed.chars
        for turn in turns.reversed() {
            let text = String(collapse(turn.text).prefix(seed.perTurn))
            guard !text.isEmpty else { continue }
            if out.count >= seed.messages || budget - text.count < 0 { break }
            budget -= text.count
            out.insert(.object([
                "type": "message",
                "role": .string(turn.assistant ? "assistant" : "user"),
                "content": .array([.object(["type": .string(turn.assistant ? "output_text" : "input_text"), "text": .string(text)])]),
            ]), at: 0)
        }
        return .array(out)
    }

    // MARK: Helpers

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Split after `.`, `!` or `?` followed by white space (the desktop's `/(?<=[.!?])\s+/`), on collapsed text.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = [], current = ""
        var previous: Character?
        for character in text {
            if character == " ", let previous, ".!?".contains(previous) {
                out.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func id(_ delegationId: String?) -> JSONValue { delegationId.map { .string($0) } ?? .null }

    private static func event(_ fields: [String: JSONValue]) -> String {
        let data = (try? JSONValue.object(fields).encoded()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
