// Phone Calls (Beta): the app talks to samplehost itself with the owner's own API key. No gateway, add-on or runtime is
// involved. Every request and field below is taken from samplehost's v2 reference (developers.samplehost.com); the doc for
// each is named beside it. The key lives only in this device's Keychain (PhoneKeyStore) and in the Authorization
// header of requests to api.samplehost.com. It is never logged, put in a URL, a crash report, UserDefaults or the gateway.

import CryptoKit
import Foundation
import Security

// MARK: - Where requests go

nonisolated enum samplehostEndpoint {
    /// Release builds only ever use this.
    static let production = URL(string: "https://api.samplehost.com/v2")!

    /// The API base. DEBUG builds (UI tests) may point it at a loopback fake with the launch environment
    /// `HQ_SAMPLEHOST_BASE_URL=https://127.0.0.1:<port>/v2`; anything else is ignored. Release compiles the override out.
    static func base(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        #if DEBUG
        if let raw = environment["HQ_SAMPLEHOST_BASE_URL"], let url = loopback(raw) { return url }
        #endif
        return production
    }

    /// An HTTPS URL on 127.0.0.1 with no credentials or query, else nil.
    static func loopback(_ raw: String) -> URL? {
        guard let parts = URLComponents(string: raw), parts.scheme == "https", parts.host == "127.0.0.1",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else { return nil }
        return url
    }

    /// True only for HTTPS requests to the configured base's own host and port.
    static func allowed(_ url: URL, base: URL) -> Bool {
        url.scheme == "https" && url.host == base.host && url.port == base.port && url.user == nil && url.password == nil
    }
}

// MARK: - Errors

nonisolated enum samplehostError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 401/403: samplehost refused the key.
    case badKey
    /// samplehost's own readable words (`errors[].detail`), with the key removed if it was ever echoed.
    case provider(String)
    /// Call Control error 90018 "Call has already ended" (hangup-call reference).
    case callEnded
    case network
    case unexpected(Int)
    /// A URL that is not HTTPS to the samplehost host; never sent.
    case refusedURL
    /// The app's own words for why it stopped (shown as they are).
    case refused(String)

    var description: String { phoneMessage(self) }
}

/// What the screen shows for a failure. Never a raw body and never the key.
nonisolated func phoneMessage(_ error: Error) -> String {
    switch error as? samplehostError {
    case .badKey: return "samplehost didn't accept this API key. Check it in the samplehost portal and try again."
    case .provider(let detail): return "samplehost: \(detail)"
    case .callEnded: return "This call has already ended."
    case .network: return "Couldn't reach samplehost. Check your connection and try again."
    case .unexpected(let status): return "samplehost answered with an unexpected error (\(status)). Try again."
    case .refusedURL: return "Phone Calls only talks to api.samplehost.com over HTTPS."
    case .refused(let words): return words
    case nil: return "The phone request couldn't be completed. Try again."
    }
}

// MARK: - Responses (only the fields the app reads)

/// list-phone-numbers: `data[]` of PhoneNumberDetailed (`id`, `phone_number`, `status`, `connection_id`, `connection_name`).
nonisolated struct samplehostNumber: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let phone_number: String
    var status: String? = nil
    var connection_id: String? = nil
    var connection_name: String? = nil
}

/// list-assistants: `data[]` of Assistant (`id`, `name`).
nonisolated struct samplehostAssistant: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
}

/// get-conversation-messages: ConversationMessage (`role`, `text`, `tool_calls[]`, `created_at`, `sent_at`).
nonisolated struct samplehostMessage: Decodable, Sendable, Equatable {
    nonisolated struct ToolCall: Decodable, Sendable, Equatable {
        nonisolated struct Function: Decodable, Sendable, Equatable {
            let name: String
            var arguments: String? = nil
        }
        let id: String
        var type: String? = nil
        let function: Function
    }
    let role: String
    var text: String? = nil
    var tool_calls: [ToolCall]? = nil
    var created_at: String? = nil
    var sent_at: String? = nil
}

private nonisolated struct DataList<T: Decodable>: Decodable { let data: [T] }
private nonisolated struct PaginationMeta: Decodable { var total_pages: Int? = nil }
private nonisolated struct PagedDataList<T: Decodable>: Decodable {
    let data: [T]
    var meta: PaginationMeta? = nil
}
private nonisolated struct DataOne<T: Decodable>: Decodable { let data: T }
/// get-insights-for-a-conversation: a completed run may contain plain text or structured results.
nonisolated struct samplehostConversationInsight: Decodable {
    private struct Entry: Decodable {
        let result: String?

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            result = try? fields.decode(String.self, forKey: .result)
        }

        private enum CodingKeys: String, CodingKey { case result }
    }

    let status: String
    private let conversation_insights: [Entry]?

    static func summary(in data: Data) throws -> String? {
        let rows = try JSONDecoder().decode(DataList<Self>.self, from: data).data
        return rows.lazy.filter { $0.status == "completed" }
            .compactMap { row in
                row.conversation_insights?.lazy.compactMap { entry -> String? in
                    guard let words = entry.result?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !words.isEmpty else { return nil }
                    if let start = words.first, "{[".contains(start),
                       (try? JSONSerialization.jsonObject(with: Data(words.utf8))) != nil { return nil }
                    return words
                }.first
            }.first
    }
}

/// dial: `data.call_control_id`, `data.call_leg_id`, `data.call_session_id` (proven on a real call, 2026-11-21).
nonisolated struct samplehostDialed: Decodable, Sendable, Equatable {
    let call_control_id: String
    var call_leg_id: String? = nil
    var call_session_id: String? = nil
}
private nonisolated struct ConversationRow: Decodable { let id: String }

/// retrieve-a-call-status: `is_alive`, and after the end, for a while, `start_time`, `end_time`, `call_duration` (seconds).
nonisolated struct samplehostCallStatus: Decodable, Sendable, Equatable {
    var is_alive: Bool? = nil
    var start_time: String? = nil
    var end_time: String? = nil
    var call_duration: Int? = nil

    init(is_alive: Bool? = nil, start_time: String? = nil, end_time: String? = nil, call_duration: Int? = nil) {
        self.is_alive = is_alive; self.start_time = start_time; self.end_time = end_time; self.call_duration = call_duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        is_alive = try? c.decodeIfPresent(Bool.self, forKey: .is_alive)
        start_time = try? c.decodeIfPresent(String.self, forKey: .start_time)
        end_time = try? c.decodeIfPresent(String.self, forKey: .end_time)
        call_duration = (try? c.decodeIfPresent(Int.self, forKey: .call_duration))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .call_duration)).map { Int($0.rounded()) }
    }
    private enum CodingKeys: String, CodingKey { case is_alive, start_time, end_time, call_duration }
}

/// get-an-assistant: the fields Check my setup, call optimization, and the recording switch read. `telephony_settings`
/// stays raw JSON so it can be sent back whole (update-an-assistant).
nonisolated struct samplehostAssistantDetail: Sendable, Equatable {
    var id: String
    var name: String?
    var model: String?
    var greeting: String?
    var enabledFeatures: [String]
    /// The whole `telephony_settings` object as samplehost sent it (nil when absent).
    var telephonyJSON: Data?
    var transcriptionModel: String?
    var interruptionEnabled: Bool?
    var userIdleTimeoutSecs: Int?
    var userIdleReplySecs: Int?
    var noiseSuppression: String?

    /// `telephony_settings.recording_settings.enabled`. samplehost's default is true (update-an-assistant reference).
    var recordingOn: Bool? {
        guard let settings = telephony else { return nil }
        return ((settings["recording_settings"] as? [String: Any])?["enabled"] as? Bool) ?? true
    }
    var telephony: [String: Any]? { telephonyJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] }

    /// Suboptimal stored settings observed on an existing assistant that affect live call fluidity.
    var callQualityIssues: [String] {
        var issues: [String] = []
        if let stt = transcriptionModel, !stt.isEmpty, stt != "deepgram/flux" {
            issues.append("speech recognition uses \(stt) instead of deepgram/flux")
        }
        if interruptionEnabled == false {
            issues.append("interruptions are turned off")
        }
        if let timeout = userIdleTimeoutSecs, timeout < 60 {
            issues.append("silence timeout is only \(timeout)s")
        }
        if let reply = userIdleReplySecs, reply > 6 {
            issues.append("silent-pickup wait is \(reply)s")
        }
        if let noise = noiseSuppression, !noise.isEmpty, noise != "aicoustics" {
            issues.append("noise suppression uses \(noise) instead of aicoustics")
        }
        return issues
    }

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
        name = json["name"] as? String
        model = json["model"] as? String
        greeting = json["greeting"] as? String
        enabledFeatures = (json["enabled_features"] as? [Any] ?? []).compactMap { $0 as? String }
        let telephonyDict = json["telephony_settings"] as? [String: Any]
        telephonyJSON = telephonyDict.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        transcriptionModel = (json["transcription"] as? [String: Any])?["model"] as? String
        interruptionEnabled = (json["interruption_settings"] as? [String: Any])?["enable"] as? Bool
        userIdleTimeoutSecs = telephonyDict?["user_idle_timeout_secs"] as? Int
        userIdleReplySecs = telephonyDict?["user_idle_reply_secs"] as? Int
        noiseSuppression = telephonyDict?["noise_suppression"] as? String
    }
}

/// list-call-control-applications: `data[]` (`id`, `application_name`, `active`).
nonisolated struct samplehostCallControlAppSummary: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    var application_name: String? = nil
    var active: Bool? = nil
}

/// get-balance: `data.balance` (string dollars), `data.currency`.
nonisolated struct samplehostBalance: Decodable, Sendable, Equatable {
    let balance: String
    var currency: String? = nil
    var amount: Double? { Double(balance) }
}

/// retrieve-a-call-control-application: `active`, `application_name`, `outbound.outbound_voice_profile_id`.
nonisolated struct samplehostCallControlApp: Decodable, Sendable, Equatable {
    nonisolated struct Outbound: Decodable, Sendable, Equatable { var outbound_voice_profile_id: String? = nil }
    var active: Bool? = nil
    var application_name: String? = nil
    var outbound: Outbound? = nil
}

/// retrieve-an-outbound-voice-profile: `enabled`, `whitelisted_destinations` (country codes such as "US").
nonisolated struct samplehostVoiceProfile: Decodable, Sendable, Equatable {
    var enabled: Bool? = nil
    var whitelisted_destinations: [String]? = nil
}

// MARK: - The dial request

/// What the owner approved on the confirm sheet, plus the saved setup.
nonisolated struct PhoneDialRequest: Sendable, Equatable {
    let to: String
    let from: String
    let connectionID: String
    let assistantID: String
    let purpose: String
    /// dial `command_id`: samplehost ignores another Dial with the same one, so a retry never places a second call.
    let commandID: String
    /// Said on calls ("calling on behalf of Alex"); empty: no name.
    var ownerName: String = ""
    /// Who is being called (person or business name, when known).
    var calleeName: String = ""
    /// The assistant's recording setting, as made to match the switch just before dialing.
    var recorded: Bool = false
    var voicemail: PhoneVoicemailChoice = .hangUp
}

/// The call form's "If voicemail answers".
nonisolated enum PhoneVoicemailChoice: String, Codable, Sendable, CaseIterable {
    case hangUp = "hangup"
    case leaveMessage = "leave"
    var title: String { self == .hangUp ? "Hang up" : "Leave a short message" }
}

nonisolated enum PhoneLimits {
    /// dial `time_limit_secs` (30 to 14400): the one safety stop, so a stuck call can't bill for hours. samplehost hangs the
    /// leg up then. The assistant's own `time_limit_secs` only stops the assistant and leaves the leg billed.
    static let callSeconds = 1800
    /// dial `timeout_secs`: how long it may ring before samplehost gives up (default 30).
    static let ringSeconds = 45
    /// The words for the safety stop wherever it shows.
    static let safetyStopNote = "30-minute safety stop"
    static let stayCopy = "The assistant stays on until the job is done. Safety stop at 30 minutes."
    /// Never resolves (RFC 2606 `.invalid`), so the ask_owner webhook sends nothing anywhere. See PhoneAskOwner.
    static let askOwnerURL = "https://ask-owner.invalid/hermes-hq"
}

/// The ask_owner tool and the per-call instructions.
///
/// samplehost has no tool type that works on a phone call without a server: client-side tools are WebRTC only
/// ("They are not available for SIP/phone-call-based conversations", docs/inference/ai-assistants/client-side-tools),
/// and dial's per-call `assistant.tools` accepts only book_appointment, check_availability, webhook, hangup, transfer
/// and retrieval (dial reference, CallAssistantRequest.tools). So ask_owner is a `webhook` tool aimed at an address
/// that never resolves: the assistant's call is still recorded in the conversation (get-conversation-messages,
/// `tool_calls[].id/function.name/arguments`), the app reads it from there, and the owner's answer goes back with
/// ai_assistant_add_messages. The instructions tell the assistant that the tool's own result is not the answer.
nonisolated enum PhoneAskOwner {
    static let name = "ask_owner"
    static let answerPrefix = "The owner answered"
    /// The assistant the app makes for an account that has none (Settings > Phone Calls > Create Assistant).
    static let assistantName = "Hermes HQ Caller"
    /// Its stored instructions; every call replaces them with `instructions(purpose:)`.
    static let baseInstructions = "You are a polite voice assistant placing short phone calls on behalf of the owner of this "
        + "account. Each call gives you its purpose. Be honest that you are an AI assistant if asked."

    /// The prefix of the message an unprompted owner message goes in (wire-proven 2026-11-21).
    static let ownerMessagePrefix = "Message from the owner, sent during the call: "

    /// Empty greeting on dial and assistant creation: tells samplehost to wait for the person who answers to speak first
    /// instead of playing a context-free canned line over their "Hello?". Combined with `user_idle_reply_secs`, the
    /// assistant opens naturally and immediately with full context once they pick up (or after brief pickup silence).
    static let dialGreeting = ""

    /// Recommended samplehost transcription settings for fluid telephony turn-taking (`deepgram/flux`, CreateAssistantRequest).
    static var recommendedTranscription: [String: Any] {
        [
            "model": "deepgram/flux",
            "language": "auto",
            "settings": [
                "eot_threshold": 0.55,
                "eager_eot_threshold": 0.35,
                "eot_timeout_ms": 3000,
            ] as [String: Any],
        ]
    }

    /// Recommended samplehost interruption settings so callers can naturally interrupt without awkward stalls.
    static var recommendedInterruption: [String: Any] {
        [
            "enable": true,
            "disable_greeting_interruption": false,
            "interrupt_prediction_threshold": 0.4,
        ]
    }

    /// Recommended samplehost telephony settings (`aicoustics` STT-optimized noise suppression, responsive pickup check-in).
    static func recommendedTelephony(recording: Bool) -> [String: Any] {
        [
            "noise_suppression": "aicoustics",
            "time_limit_secs": PhoneLimits.callSeconds,
            "user_idle_timeout_secs": 180,
            "user_idle_reply_secs": 5,
            "recording_settings": ["enabled": recording],
        ]
    }

    static func instructions(purpose: String, ownerName: String = "", calleeName: String = "",
                             recorded: Bool = false, voicemail: PhoneVoicemailChoice = .hangUp,
                             now: Date = Date()) -> String {
        let given = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let callee = calleeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = given.isEmpty ? "the owner" : given
        let callingOwnerDirectly = !given.isEmpty && !callee.isEmpty
            && given.caseInsensitiveCompare(callee) == .orderedSame
        let roleBlock: String
        if callingOwnerDirectly {
            roleBlock = """
            You are \(owner)'s AI voice assistant calling \(owner) directly on the phone. Speak warmly and directly to \
            \(owner) as their own assistant: never say you are "calling on behalf of \(owner)".
            """
        } else {
            let targetLine = callee.isEmpty ? "" : " You are calling \(callee)."
            roleBlock = """
            You are an AI voice assistant placing an outbound phone call on behalf of \(owner).\(targetLine) Usually \
            the person who answers is not \(owner) (\(owner) can follow a live transcript and send you messages). \
            However, if the goal below is to call \(owner) directly, or if \(owner) themselves answers, speak directly \
            to them as their assistant instead of saying you are calling on their behalf.
            """
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let localTime = formatter.string(from: now)
        let recordedRule = recorded
            ? "\n- This call is recorded: briefly mention in your very first turn that the call is recorded."
            : ""
        let onVoicemail = voicemail == .hangUp
            ? "hang up right away using the hangup tool without saying anything"
            : "wait for the beep or tone, leave one short message, then hang up. Say who you are and who you are calling for, "
                + "then the reason in one plain sentence of your own: never read \(owner)'s words out as written, and fix any "
                + "typos or shorthand. Do not ask anyone to call back unless \(owner)'s words ask for a call back. If \(owner)'s "
                + "words say this is a test, say it is a test call and that no reply is needed"
        return """
        \(roleBlock)
        Current local time: \(localTime).

        Why you are calling, in \(owner)'s words: \(purpose)

        How to run the call:
        - Wait for the person who answers to speak first (or begin naturally if the line is quiet after pickup). On your \
        very first turn, respond naturally to how they answered, briefly introduce yourself, and immediately state why \
        you are calling in one clear, plain sentence using the context above. Never open with a generic greeting that \
        leaves out the reason for the call, and never read \(owner)'s notes or typos verbatim.\(recordedRule)
        - Keep the conversation fluid and natural: speak in short turns (1 to 2 sentences at a time), pause to listen, \
        and adapt immediately if the other person interrupts or steers the conversation. Never deliver long monologues \
        or spell out raw URLs or formatting.
        - If asked, say honestly that you are an AI assistant for \(owner).
        - Stay on the call until the goal is done or clearly cannot be done. Do not end the call just because it is \
        taking long. Before ending, briefly confirm any key outcome (times, confirmation details, or next steps), say a \
        natural goodbye, and call the hangup tool.
        - Never invent facts about \(owner) (dates, preferences, payment details, addresses). When speaking with someone \
        other than \(owner) and you need a decision or fact only \(owner) has, briefly tell them you are checking with \
        \(owner) and it will take a moment, then call the \(Self.name) tool once with one short question and, when there \
        are clear options, up to four short choices. The tool only sends the question; its result is a receipt, never \
        the answer, and may read like an error. Never mention tool errors or technical problems aloud, never call \
        \(Self.name) twice for the same question, and never ask a third party to answer for \(owner). Keep them on the \
        line politely until a message arrives starting with "\(answerPrefix)", then relay that answer right away. (If \
        you are speaking directly with \(owner), just ask them aloud instead of calling \(Self.name).)
        - A message that starts with "Message from the owner" is a live instruction from \(owner): follow it right away.
        - If a voicemail greeting or automated recording answers instead of a person, \(onVoicemail).
        """
    }

    /// dial reference: WebhookTool (`type`, `timeout_ms`, `webhook`) with CallControlWebhookToolParams (`name`,
    /// `description`, `url`, `method`, `body_parameters`), and HangupTool (`type`, `hangup.description`).
    static var tools: [[String: Any]] {
        [
            ["type": "webhook",
             "timeout_ms": 2000,
             "webhook": [
                "name": name,
                "description": "Ask the owner a question during the call. Returns no answer itself: the owner's "
                    + "answer arrives later as a message starting with \"\(answerPrefix)\".",
                "url": PhoneLimits.askOwnerURL,
                "method": "POST",
                "body_parameters": [
                    "type": "object",
                    "properties": [
                        "question": ["type": "string", "description": "One short question for the owner."],
                        "choices": ["type": "array", "items": ["type": "string"],
                                    "description": "Up to four short answers the owner can tap. Optional."],
                    ],
                    "required": ["question"],
                ] as [String: Any],
             ] as [String: Any]],
            ["type": "hangup",
             "hangup": ["description": "Hang up when the conversation is finished."]],
        ]
    }

    /// The tool message's text: carries the tool call id so a reopened sheet knows the question was answered.
    static func toolAnswer(_ answer: String, toolCallID: String) -> String {
        "\(answerPrefix) (ref \(toolCallID)): \(answer)"
    }
}

// MARK: - The client

/// One owner's samplehost key. `description`, `debugDescription` and the mirror never show it.
nonisolated struct samplehostAPI: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let key: String
    let base: URL
    private let session: URLSession

    init(key: String, base: URL = samplehostEndpoint.base(), session: URLSession = samplehostAPI.session) {
        self.key = key; self.base = base; self.session = session
    }

    var description: String { "samplehostAPI(\(base.host ?? "?"))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["base": base]) }

    /// Ephemeral: no cache, cookies or credential store; redirects are refused so the header never follows one.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: samplehostNoRedirects(), delegateQueue: nil)
    }()

    // MARK: Requests

    /// list-phone-numbers: `GET /v2/phone_numbers?page[size]=250` (read-only; samplehost's own suggested key check).
    func phoneNumbers() async throws -> [samplehostNumber] {
        let data = try await send("GET", ["phone_numbers"], query: [("page[size]", "250")])
        let list = try decode(DataList<samplehostNumber>.self, data).data
        return list.filter { $0.status == nil || $0.status == "active" }
    }

    /// list-assistants: `GET /v2/ai/assistants`.
    func assistants() async throws -> [samplehostAssistant] {
        try decode(DataList<samplehostAssistant>.self, try await send("GET", ["ai", "assistants"])).data
    }

    /// create-an-assistant: `POST /v2/ai/assistants` configured for fluid telephony out of the box (`enabled_features`,
    /// empty `greeting`, `deepgram/flux` turn-taking transcription, natural interruptions, `aicoustics` noise
    /// suppression, and responsive idle-pickup check-in) with an `Idempotency-Key`, so a retried tap never makes two.
    func createAssistant(idempotencyKey: String) async throws -> samplehostAssistant {
        let body: [String: Any] = [
            "name": PhoneAskOwner.assistantName,
            "instructions": PhoneAskOwner.baseInstructions,
            "enabled_features": ["telephony"],
            "greeting": PhoneAskOwner.dialGreeting,
            "transcription": PhoneAskOwner.recommendedTranscription,
            "interruption_settings": PhoneAskOwner.recommendedInterruption,
            "telephony_settings": PhoneAskOwner.recommendedTelephony(recording: false),
        ]
        let data = try await send("POST", ["ai", "assistants"], body: try JSONSerialization.data(withJSONObject: body),
                                  headers: ["Idempotency-Key": idempotencyKey])
        if let wrapped = try? JSONDecoder().decode(DataOne<samplehostAssistant>.self, from: data) { return wrapped.data }
        return try decode(samplehostAssistant.self, data)
    }

    /// dial: `POST /v2/calls` with `connection_id`, `from`, `to`, `timeout_secs`, `time_limit_secs`, `command_id`,
    /// `answering_machine_detection: "premium"` and `assistant` (CallAssistantRequest: `id`, empty `greeting` so the
    /// assistant waits for pickup before opening with full context, `instructions`, `tools`).
    func dial(_ request: PhoneDialRequest, now: Date = Date()) async throws -> samplehostDialed {
        let body: [String: Any] = [
            "connection_id": request.connectionID,
            "from": request.from,
            "to": request.to,
            "timeout_secs": PhoneLimits.ringSeconds,
            "time_limit_secs": PhoneLimits.callSeconds,
            "command_id": request.commandID,
            "answering_machine_detection": "premium",
            "assistant": [
                "id": request.assistantID,
                "greeting": PhoneAskOwner.dialGreeting,
                "instructions": PhoneAskOwner.instructions(purpose: request.purpose, ownerName: request.ownerName,
                                                           calleeName: request.calleeName, recorded: request.recorded,
                                                           voicemail: request.voicemail, now: now),
                "tools": PhoneAskOwner.tools,
            ] as [String: Any],
        ]
        let data = try await send("POST", ["calls"], body: try JSONSerialization.data(withJSONObject: body))
        return try decode(DataOne<samplehostDialed>.self, data).data
    }

    /// list-conversations: `GET /v2/ai/conversations?metadata->call_control_id=eq.<id>&limit=1`. nil until samplehost has
    /// made the call's conversation (after pickup).
    func conversationID(callControlID: String) async throws -> String? {
        let data = try await send("GET", ["ai", "conversations"],
                                  query: [("metadata->call_control_id", "eq." + callControlID), ("limit", "1")])
        return try decode(DataList<ConversationRow>.self, data).data.first?.id
    }

    /// get-conversation-messages: `GET /v2/ai/conversations/{id}/messages?page[size]=100`, paging through additional
    /// pages (up to 5 pages / 500 rows) when samplehost reports `meta.total_pages > 1`.
    func messages(conversationID: String) async throws -> [samplehostMessage] {
        let firstData = try await send("GET", ["ai", "conversations", conversationID, "messages"], query: [("page[size]", "100")])
        let first = try decode(PagedDataList<samplehostMessage>.self, firstData)
        var all = first.data
        let totalPages = min(first.meta?.total_pages ?? 1, 5)
        if totalPages > 1 {
            for page in 2...totalPages {
                let pageData = try await send("GET", ["ai", "conversations", conversationID, "messages"],
                                              query: [("page[size]", "100"), ("page[number]", "\(page)")])
                all.append(contentsOf: try decode(PagedDataList<samplehostMessage>.self, pageData).data)
            }
        }
        return all
    }

    /// get-insights-for-a-conversation: `GET /v2/ai/conversations/{id}/conversations-insights`.
    func conversationSummary(conversationID: String) async throws -> String? {
        let data = try await send("GET", ["ai", "conversations", conversationID, "conversations-insights"], timeout: 3)
        return try samplehostConversationInsight.summary(in: data).map(redact)
    }

    /// add-messages-to-ai-assistant: `POST /v2/calls/{id}/actions/ai_assistant_add_messages` with one `tool` message
    /// per tool call id (`tool_call_id`, `content`), so a question the model asked twice is answered for both, and one
    /// `system` message, `trigger_response: true` and `command_id`. The system message is there because GPT Live
    /// assistants never receive injected `tool` records (same reference). `quiet`: the tool results alone, no system
    /// message and no new reply (a late repeat of a question already answered).
    func deliverAnswer(callControlID: String, toolCallIDs: [String], question: String, answer: String, commandID: String,
                       quiet: Bool = false) async throws {
        var messages: [[String: Any]] = toolCallIDs.map {
            ["role": "tool", "tool_call_id": $0, "content": PhoneAskOwner.toolAnswer(answer, toolCallID: $0)]
        }
        if !quiet {
            messages.append(["role": "system",
                             "content": "\(PhoneAskOwner.answerPrefix) your question \"\(question)\": \(answer). Tell the person now, then continue."])
        }
        let body: [String: Any] = ["messages": messages, "trigger_response": !quiet, "command_id": commandID]
        _ = try await send("POST", ["calls", callControlID, "actions", "ai_assistant_add_messages"],
                           body: try JSONSerialization.data(withJSONObject: body))
    }

    /// add-messages-to-ai-assistant with one `system` message "Message from the owner, sent during the call: …" and
    /// `trigger_response: true` (proven 2026-11-21: the assistant acted on it within about 2 seconds).
    func sendOwnerMessage(callControlID: String, text: String, commandID: String) async throws {
        let body: [String: Any] = [
            "messages": [["role": "system", "content": PhoneAskOwner.ownerMessagePrefix + text]],
            "trigger_response": true,
            "command_id": commandID,
        ]
        _ = try await send("POST", ["calls", callControlID, "actions", "ai_assistant_add_messages"],
                           body: try JSONSerialization.data(withJSONObject: body))
    }

    /// hangup-call: `POST /v2/calls/{id}/actions/hangup` with `command_id` (samplehost ignores a repeat). An already
    /// ended call (error 90018) counts as done.
    func hangup(callControlID: String, commandID: String) async throws {
        do {
            _ = try await send("POST", ["calls", callControlID, "actions", "hangup"],
                               body: try JSONSerialization.data(withJSONObject: ["command_id": commandID]))
        } catch samplehostError.callEnded { }
    }

    /// retrieve-a-call-status: `GET /v2/calls/{id}` → `data.is_alive`. nil when samplehost no longer knows the call (404).
    func isAlive(callControlID: String) async throws -> Bool? {
        try await callStatus(callControlID: callControlID)?.is_alive
    }

    /// retrieve-a-call-status: `GET /v2/calls/{id}` → `is_alive`, and after the end `start_time`, `end_time`,
    /// `call_duration`. nil on 404 (samplehost forgot the call).
    func callStatus(callControlID: String) async throws -> samplehostCallStatus? {
        let result = await Result.of { try await send("GET", ["calls", callControlID]) }
        if case .failure(samplehostError.unexpected(404)) = result { return nil }
        return try decode(DataOne<samplehostCallStatus>.self, result.get()).data
    }

    /// list-call-events: `GET /v2/call_events?filter[leg_id]=<leg>&filter[type]=webhook&page[size]=50`. samplehost logs every
    /// webhook event it would have sent; without `filter[type]=webhook` our own commands flood the list. The log lags
    /// the call by 10 to 30 seconds, so it is read for the outcome, not for anything live.
    func callEvents(legID: String) async throws -> [PhoneCallEvent] {
        let data = try await send("GET", ["call_events"],
                                  query: [("filter[leg_id]", legID), ("filter[type]", "webhook"), ("page[size]", "50")])
        return try decode(DataList<PhoneCallEvent>.self, data).data
    }

    /// get-an-assistant: `GET /v2/ai/assistants/{id}` (`name`, `model`, `greeting`, `enabled_features`,
    /// `telephony_settings`). Answers the object itself or wrapped in `data`.
    func assistant(id: String) async throws -> samplehostAssistantDetail {
        let data = try await send("GET", ["ai", "assistants", id])
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw samplehostError.unexpected(200) }
        if object["id"] == nil, let inner = object["data"] as? [String: Any] { object = inner }
        return samplehostAssistantDetail(json: object)
    }

    /// update-an-assistant: `POST /v2/ai/assistants/{id}` with `{"telephony_settings": <the whole object>}`. Proven
    /// 2026-11-21: sending back the whole object read from get-an-assistant keeps greeting, model, tools and
    /// instructions. Merge-vs-replace is undocumented and the object holds `default_texml_app_id`, so it is never sent
    /// partial.
    func updateTelephony(assistantID: String, telephony: [String: Any]) async throws {
        let body: [String: Any] = ["telephony_settings": telephony]
        _ = try await send("POST", ["ai", "assistants", assistantID], body: try JSONSerialization.data(withJSONObject: body))
    }

    /// Makes the assistant's recording match `on`: get-an-assistant, compare, and update-an-assistant with the whole
    /// `telephony_settings` (only `recording_settings.enabled` changed) only when it differs. Answers whether it wrote.
    @discardableResult
    func matchRecording(assistantID: String, on: Bool) async throws -> Bool {
        let detail = try await assistant(id: assistantID)
        guard var telephony = detail.telephony else {
            throw samplehostError.provider("The assistant has no telephony settings. Turn on telephony for it in the samplehost portal.")
        }
        guard detail.recordingOn != on else { return false }
        var recording = telephony["recording_settings"] as? [String: Any] ?? [:]
        recording["enabled"] = on
        telephony["recording_settings"] = recording
        try await updateTelephony(assistantID: assistantID, telephony: telephony)
        return true
    }

    /// Upgrades an existing assistant with fluid telephony defaults (`deepgram/flux` turn-taking, interruptions,
    /// `aicoustics` noise suppression, responsive pickup check-in, empty greeting) while keeping existing
    /// `telephony_settings` keys (such as `default_texml_app_id`) and matching `recording`.
    func optimizeAssistant(id assistantID: String, recording: Bool) async throws {
        let detail = try await assistant(id: assistantID)
        var features = detail.enabledFeatures
        if !features.contains("telephony") { features.append("telephony") }
        var telephony = detail.telephony ?? [:]
        telephony["noise_suppression"] = "aicoustics"
        telephony["time_limit_secs"] = PhoneLimits.callSeconds
        telephony["user_idle_timeout_secs"] = 180
        telephony["user_idle_reply_secs"] = 5
        var rec = telephony["recording_settings"] as? [String: Any] ?? [:]
        rec["enabled"] = recording
        telephony["recording_settings"] = rec
        let body: [String: Any] = [
            "enabled_features": features,
            "greeting": PhoneAskOwner.dialGreeting,
            "transcription": PhoneAskOwner.recommendedTranscription,
            "interruption_settings": PhoneAskOwner.recommendedInterruption,
            "telephony_settings": telephony,
        ]
        _ = try await send("POST", ["ai", "assistants", assistantID], body: try JSONSerialization.data(withJSONObject: body))
    }

    /// list-call-control-applications: `GET /v2/call_control_applications?page[size]=250`.
    func callControlApps() async throws -> [samplehostCallControlAppSummary] {
        let data = try await send("GET", ["call_control_applications"], query: [("page[size]", "250")])
        return try decode(DataList<samplehostCallControlAppSummary>.self, data).data.filter { $0.active != false }
    }

    /// get-balance: `GET /v2/balance`.
    func balance() async throws -> samplehostBalance {
        try decode(DataOne<samplehostBalance>.self, try await send("GET", ["balance"])).data
    }

    /// retrieve-a-call-control-application: `GET /v2/call_control_applications/{id}`.
    func callControlApp(id: String) async throws -> samplehostCallControlApp {
        try decode(DataOne<samplehostCallControlApp>.self, try await send("GET", ["call_control_applications", id])).data
    }

    /// retrieve-an-outbound-voice-profile: `GET /v2/outbound_voice_profiles/{id}`.
    func voiceProfile(id: String) async throws -> samplehostVoiceProfile {
        try decode(DataOne<samplehostVoiceProfile>.self, try await send("GET", ["outbound_voice_profiles", id])).data
    }

    /// list-phone-numbers with every status (Check my setup says why a number can't call).
    func allPhoneNumbers() async throws -> [samplehostNumber] {
        try decode(DataList<samplehostNumber>.self, try await send("GET", ["phone_numbers"], query: [("page[size]", "250")])).data
    }

    // MARK: Transport

    /// Builds `base/segments…?query` with every segment and query part strictly percent-encoded.
    func url(_ segments: [String], query: [(String, String)] = []) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let path = parts.percentEncodedPath.hasSuffix("/") ? String(parts.percentEncodedPath.dropLast()) : parts.percentEncodedPath
        parts.percentEncodedPath = path + "/" + segments.map(Self.escape).joined(separator: "/")
        parts.percentEncodedQuery = query.isEmpty ? nil : query.map { Self.escape($0.0) + "=" + Self.escape($0.1) }.joined(separator: "&")
        return parts.url
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    private func send(_ method: String, _ segments: [String], query: [(String, String)] = [], body: Data? = nil,
                      headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> Data {
        guard let url = url(segments, query: query), samplehostEndpoint.allowed(url, base: base) else { throw samplehostError.refusedURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw samplehostError.network }
        guard let http = response as? HTTPURLResponse else { throw samplehostError.network }
        if (200..<300).contains(http.statusCode) { return data }
        throw failure(status: http.statusCode, data)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw samplehostError.unexpected(200) }
    }

    /// samplehost's error body: `{"errors":[{"code","title","detail"}]}` (Call Control, Numbers) or FastAPI's
    /// `{"detail":[{"msg"}]}` / `{"detail":"…"}` (AI endpoints, HTTPValidationError).
    func failure(status: Int, _ data: Data) -> samplehostError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let errors = object?["errors"] as? [[String: Any]] ?? []
        if errors.contains(where: { "\($0["code"] ?? "")" == "90018" }) { return .callEnded }
        if status == 401 || status == 403 { return .badKey }
        var words = errors.compactMap { ($0["detail"] as? String) ?? ($0["title"] as? String) }
        if words.isEmpty, let detail = object?["detail"] as? String { words = [detail] }
        if words.isEmpty, let details = object?["detail"] as? [[String: Any]] { words = details.compactMap { $0["msg"] as? String } }
        let text = redact(words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " "))
        if status == 404, text.isEmpty { return .unexpected(404) }
        guard !text.isEmpty else { return .unexpected(status) }
        return .provider(String(text.prefix(300)))
    }

    /// Removes the key from text samplehost sent back, should it ever be echoed.
    func redact(_ text: String) -> String {
        key.count >= 4 ? text.replacingOccurrences(of: key, with: "•••") : text
    }
}

private nonisolated final class samplehostNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Keychain

/// The owner's samplehost setup for one signed-in HQ account.
nonisolated struct PhoneSetup: Codable, Equatable, Sendable {
    var apiKey: String
    var fromNumber: String? = nil
    var connectionID: String? = nil
    var assistantID: String? = nil
    var assistantName: String? = nil
    /// Settings › "Your name (said on calls)". Not secret; kept in the same item for simplicity.
    var ownerName: String? = nil
    /// Settings › Record calls (nil: off). Optional so an item saved before these switches still reads.
    var recordCalls: Bool? = nil
    /// Settings › Send call results to the chat (nil: on).
    var sendResults: Bool? = nil

    var records: Bool { recordCalls ?? false }
    var sendsResults: Bool { sendResults ?? true }
    var name: String { (ownerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    var ready: Bool {
        [fromNumber, connectionID, assistantID].allSatisfy { !($0 ?? "").isEmpty }
    }
}

/// One Keychain item per HQ account (`kSecClassGenericPassword`, `AfterFirstUnlockThisDeviceOnly`, never synced).
/// The item's account is a hash of the HQ account's id, so another sign-in never reads this one's key.
nonisolated struct PhoneKeyStore: Sendable {
    let service: String
    static let app = PhoneKeyStore(service: AppIdentity.current.keychainService + ".samplehost")

    func itemAccount(_ hqAccountID: String) -> String {
        "samplehost-" + SHA256.hash(data: Data(hqAccountID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func query(_ hqAccountID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: itemAccount(hqAccountID), kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    func load(for hqAccountID: String) -> PhoneSetup? {
        var q = query(hqAccountID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let setup = try? JSONDecoder().decode(PhoneSetup.self, from: data), !setup.apiKey.isEmpty else { return nil }
        return setup
    }

    func save(_ setup: PhoneSetup, for hqAccountID: String) throws {
        let data = try JSONEncoder().encode(setup)
        SecItemDelete(query(hqAccountID) as CFDictionary)
        var add = query(hqAccountID)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw PhoneKeyStoreError.keychain(status) }
    }

    func delete(for hqAccountID: String) {
        SecItemDelete(query(hqAccountID) as CFDictionary)
    }

    /// Every account's item (DEBUG `-HQDebugResetAccounts`, tests).
    func removeAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

nonisolated enum PhoneKeyStoreError: Error, Equatable { case keychain(OSStatus) }
