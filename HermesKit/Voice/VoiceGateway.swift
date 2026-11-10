// The gateway calls live voice makes (docs/spec/3x-talk.md §3): the voice settings a conversation reads, speech to
// text, text to speech (one clip, and the streamed socket's address and frames), the warm-up leases and the
// ElevenLabs voice list. Every body lists every key it sends: Hermes rejects unknown parameters.
//
// Never called from anywhere (§3.8): the gateway's own voice engine and wake word. `scripts/check-talk-guards.sh`
// and `TalkGuardTests` fail if one of those paths appears in the app's sources.

import Foundation

/// A gateway whose speech socket can be dialled (`LiveGatewayClient`).
nonisolated protocol GatewayVoiceSockets: AnyObject, Sendable {
    func voiceSocket(path: String, query: [URLQueryItem]) async throws -> URLSessionWebSocketTask
}

extension LiveGatewayClient: GatewayVoiceSockets {}

/// Why a voice call failed: `reason` in words a person reads, `detail` for Copy Details.
nonisolated struct VoiceFailure: Error, Equatable, Sendable {
    var reason: String
    var detail: String?
}

nonisolated struct SpeechClip: Sendable, Equatable {
    var data: Data
    var mime: String
}

nonisolated enum VoiceWire {
    static let speakStream = "/api/audio/speak-stream"
    /// One PCM frame is small; a message this large is not speech.
    static let maxMessage = 4 * 1024 * 1024
    static let transcribeTimeout: TimeInterval = 45
    static let speakTimeout: TimeInterval = 60
    static let leaseTimeout: TimeInterval = 180
    /// New reply text reaches the speech socket at most this often.
    static let feedInterval: TimeInterval = 0.15
    /// After `done`, a stream that says nothing at all for this long is spoken clip by clip instead. Long on purpose:
    /// the gateway says `start` only with its first audio, and a whole sentence is made first (a cold local voice
    /// takes seconds). Shorter than Read Aloud's own 15 s "didn't answer" so the clips still get their chance.
    static let startTimeout: TimeInterval = 10
    /// After `done`: no audio and no `end` for this long ends the reply. Never before `done` (a tool may be running).
    static let stallTimeout: TimeInterval = 15
    /// The one wait before the iPhone's voice takes over from a computer that has said nothing (§7.7): counted from the
    /// moment the reply is complete (Read Aloud: at once), so a long reply still being written never trips it. Generous
    /// on purpose: Hermes makes a whole first sentence before any audio, and a cold local voice (NeuTTS, Piper,
    /// KittenTTS loading its model on a modest computer) can take 10–15 s for it; 20 s leaves room for that and for the
    /// clip route's turn after the stream's own 10 s. A slow computer is never remembered as failing: only an error
    /// answer is (`PhoneVoiceFallback`), so the next reply asks the computer first again.
    static let phoneVoiceAfter: TimeInterval = 20

    /// `ws(s)://<host>/<prefix>/api/audio/…?profile=<p>&ticket=<t>`: the gateway's own scheme, its path prefix kept.
    static func socketURL(base: URL, path: String, query: [URLQueryItem], ticket: String) -> URL? {
        guard path.hasPrefix("/api/audio/"), !path.contains("?"), !path.contains("#"), !path.contains(".."),
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        switch parts.scheme?.lowercased() {
        case "https": parts.scheme = "wss"
        case "http": parts.scheme = "ws"
        default: return nil
        }
        let prefix = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        parts.path = prefix + path
        parts.user = nil
        parts.password = nil
        parts.fragment = nil
        parts.queryItems = query.filter { $0.name != "ticket" && $0.name != "token" } + [URLQueryItem(name: "ticket", value: ticket)]
        return parts.url
    }

    static func profileQuery(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    // MARK: Leases

    enum Lease: String, Sendable { case conversation, readAloud = "read-aloud", voiceInput = "voice-input" }
    enum LeaseKind: String, Sendable { case tts, stt }

    /// A random id made once for this install (`hq.voice.installId`).
    static func installId(defaults: UserDefaults = .standard) -> String {
        let key = "hq.voice.installId"
        if let saved = defaults.string(forKey: key), UUID(uuidString: saved) != nil { return saved }
        let made = UUID().uuidString.lowercased()
        defaults.set(made, forKey: key)
        return made
    }

    static func leaseName(_ lease: Lease, installId: String) -> String { "hqnative:\(lease.rawValue):\(installId)" }

    static func leaseBody(active: Bool, name: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["active": active, "lease": name], options: [.sortedKeys])) ?? Data()
    }

    // MARK: Clips

    static let playable: Set<String> = ["audio/mpeg", "audio/wav", "audio/x-wav", "audio/flac", "audio/mp4", "audio/aac"]

    static func canPlay(_ mime: String) -> Bool {
        playable.contains(mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "")
    }

    static func unplayable(_ mime: String) -> String {
        "Your gateway’s voice uses a format \(DeviceWord.subject) can’t play (\(mime.isEmpty ? "unknown" : mime)). Pick another Text to Speech provider in Settings › Voice."
    }

    /// The file extension `AVAudioPlayer` wants for a clip of this kind.
    static func fileExtension(_ mime: String) -> String {
        switch mime.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) ?? "" {
        case "audio/mpeg": "mp3"
        case "audio/wav", "audio/x-wav": "wav"
        case "audio/flac": "flac"
        case "audio/aac": "aac"
        default: "m4a"
        }
    }

    /// `data:<mime>;base64,<bytes>` → the bytes and the mime named in the URL.
    static func decodeDataURL(_ url: String) -> (data: Data, mime: String)? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let head = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        guard head.hasSuffix(";base64") else { return nil }
        let mime = String(head.dropLast(7))
        guard let data = Data(base64Encoded: String(url[url.index(after: comma)...]), options: [.ignoreUnknownCharacters]), !data.isEmpty else { return nil }
        return (data, mime)
    }

    // MARK: The speech socket's frames

    static func textFrame(_ text: String) -> String { json(["text": text]) }
    static let doneFrame = "{\"done\":true}"
    static let stopFrame = "{\"stop\":true}"

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    enum ServerFrame: Equatable, Sendable {
        case start(sampleRate: Double, channels: Int)
        case end
        case fallback
        case unknown
    }

    /// A text frame from the server. A `start` with a rate or channel count no phone could play is `unknown`.
    static func parse(_ text: String) -> ServerFrame {
        guard let value = try? JSONValue.parse(Data(text.utf8)), let type = value["type"]?.string else { return .unknown }
        switch type {
        case "start":
            let rate = value["sample_rate"]?.double ?? 24_000
            let channels = value["channels"]?.int ?? 1
            guard rate >= 8_000, rate <= 96_000, channels >= 1, channels <= 2 else { return .unknown }
            return .start(sampleRate: rate, channels: channels)
        case "end": return .end
        case "fallback": return .fallback
        default: return .unknown
        }
    }

    /// The gateway's own reason from an error answer, word for word, else the status in plain words.
    static func failure(_ error: any Error, doing what: String) -> VoiceFailure {
        if let failure = error as? VoiceFailure { return failure }
        if let http = error as? HTTPError {
            let parsed = http.body.flatMap { try? JSONValue.parse(Data($0.utf8)) }
            let said = parsed.flatMap { $0["detail"]?.string ?? $0["error"]?.string }
            let body = http.body.map { String($0.prefix(600)) } ?? ""
            let detail = "HTTP \(http.status)" + (body.isEmpty ? "" : "\n" + VoiceReport.scrub(body))
            if let said, !said.isEmpty { return VoiceFailure(reason: said, detail: detail) }
            return VoiceFailure(reason: "Couldn’t \(what). \(http.plainWords)", detail: detail)
        }
        if let rpc = error as? RPCError { return VoiceFailure(reason: rpc.message, detail: nil) }
        if let localized = error as? LocalizedError, let text = localized.errorDescription { return VoiceFailure(reason: text, detail: nil) }
        return VoiceFailure(reason: "Couldn’t \(what). Check your connection, then try again.", detail: String(describing: type(of: error)))
    }
}

/// The calls. Stateless but for the voice settings kept 60 s per account and profile.
nonisolated enum VoiceGateway {
    private struct Kept: Sendable { var config: TalkConfig; var at: Date }
    private static let kept = Locked<[String: Kept]>([:])
    static let configLifetime: TimeInterval = 60

    private static func key(_ client: any GatewayClient, _ profile: String?) -> String { "\(client.account.id)|\(profile ?? "")" }

    /// The voice settings a conversation or a dictation needs (§3.1). A failed read answers the defaults: Talk is
    /// never blocked by it (the first transcription says what is wrong).
    static func config(client: any GatewayClient, profile: String?, now: Date = Date()) async -> TalkConfig {
        let key = key(client, profile)
        // "Speech to Text is off" is never answered from memory: the person may have just turned it on.
        if let hit = kept.value[key], now.timeIntervalSince(hit.at) < configLifetime, hit.config.sttEnabled { return hit.config }
        // [load-cache] maxAge 0: shares a read in flight only (the rule above keeps "off" from being reused).
        guard let data = try? await client.configData(VoiceWire.profileQuery(profile), maxAge: 0),
              let value = try? JSONValue.parse(data) else {
            AppLog.trace("voice", "voice config read failed: using defaults")
            return TalkConfig()
        }
        let config = TalkConfig(config: value)
        kept.mutate { $0[key] = Kept(config: config, at: now) }
        return config
    }

    /// What is already known without asking (the voice options menu reads it). Unknown is nil and counts as on.
    static func knownConfig(client: any GatewayClient, profile: String?) -> TalkConfig? {
        kept.value[key(client, profile)]?.config
    }

    /// Settings changed (any save of the gateway's settings: `GatewaySettingsAPI.saveConfig`), or the account went.
    static func forgetConfig() {
        kept.mutate { $0.removeAll() }
        forgetLiveStatus()   // [gpt-live] a key or the mode may have changed
        forgetGrokStatus()   // [grok-live]
        // A save may have fixed the computer's voice: the next reply asks it again (§7.7).
        PhoneVoiceFallback.shared.forget()
    }

    /// Speech to text (§3.2). Empty words are an answer, not a failure.
    static func transcribe(client: any GatewayClient, file: URL, mime: String, profile: String?) async -> Result<String, VoiceFailure> {
        guard let transfers = client as? any GatewayTransfers else {
            return .failure(VoiceFailure(reason: "This gateway can’t transcribe.", detail: nil))
        }
        do {
            let (body, _) = try await MemoUploader.transcribeBody(file: file, mime: mime)
            if Task.isCancelled { return .failure(VoiceFailure(reason: "Cancelled.", detail: nil)) }
            let data = try await transfers.transfer("POST", "/api/audio/transcribe", query: VoiceWire.profileQuery(profile), body: body,
                                                    contentType: "application/json", timeout: VoiceWire.transcribeTimeout)
            guard let answer = try? JSONValue.parse(data), answer.object != nil else {
                return .failure(VoiceFailure(reason: "Your gateway’s answer wasn’t understood.", detail: VoiceReport.scrub(String(decoding: data.prefix(300), as: UTF8.self))))
            }
            if answer["ok"]?.bool == false {
                let said = answer["detail"]?.string ?? answer["error"]?.string ?? "The gateway could not transcribe that."
                AppLog.note("voice", "transcribe refused by the gateway")
                return .failure(VoiceFailure(reason: said, detail: nil))
            }
            return .success((answer["transcript"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            AppLog.note("voice", "transcribe failed: \(GatewayFailure.from(error).code)")
            return .failure(VoiceWire.failure(error, doing: "transcribe what you said"))
        }
    }

    /// One clip of speech (§3.4). Throws `VoiceFailure`; an unplayable kind is named in the reason.
    static func speak(client: any GatewayClient, text: String, profile: String?) async throws -> SpeechClip {
        guard let transfers = client as? any GatewayTransfers else { throw VoiceFailure(reason: "This gateway can’t speak.", detail: nil) }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["text": text])
            let data = try await transfers.transfer("POST", "/api/audio/speak", query: VoiceWire.profileQuery(profile), body: body,
                                                    contentType: "application/json", timeout: VoiceWire.speakTimeout)
            guard let answer = try? JSONValue.parse(data), answer.object != nil else {
                throw VoiceFailure(reason: "Your gateway’s answer wasn’t understood.", detail: nil)
            }
            if answer["ok"]?.bool == false {
                throw VoiceFailure(reason: answer["detail"]?.string ?? answer["error"]?.string ?? "The gateway could not make speech.", detail: nil)
            }
            guard let url = answer["data_url"]?.string, let decoded = VoiceWire.decodeDataURL(url) else {
                throw VoiceFailure(reason: "Your gateway sent no audio.", detail: nil)
            }
            let mime = answer["mime_type"]?.string ?? decoded.mime
            guard VoiceWire.canPlay(mime) else {
                AppLog.note("voice", "speak clip unplayable: \(mime.isEmpty ? "unknown" : mime)")
                throw VoiceFailure(reason: VoiceWire.unplayable(mime), detail: "unplayable")
            }
            return SpeechClip(data: decoded.data, mime: mime)
        } catch {
            throw VoiceWire.failure(error, doing: "speak the reply")
        }
    }

    /// One line of lease calls per gateway and kind: a hold and its release reach the gateway in the order asked.
    private static let leaseLines = Locked<[String: Task<Void, Never>]>([:])

    /// Hold or release a warm-up lease (§3.5): fired and forgotten; a failure is only logged. `profile`: the bot whose
    /// voice is warmed (the gateway resolves the provider inside that profile).
    static func lease(client: any GatewayClient, kind: VoiceWire.LeaseKind, lease: VoiceWire.Lease, active: Bool, profile: String? = nil) {
        guard let transfers = client as? any GatewayTransfers else { return }
        let name = VoiceWire.leaseName(lease, installId: VoiceWire.installId())
        let body = VoiceWire.leaseBody(active: active, name: name)
        let query = VoiceWire.profileQuery(profile)
        let line = "\(client.account.id)|\(kind.rawValue)"
        leaseLines.mutate { lines in
            let before = lines[line]
            lines[line] = Task.detached(priority: .utility) {
                await before?.value
                do {
                    _ = try await transfers.transfer("POST", "/api/audio/\(kind.rawValue)-lease", query: query, body: body,
                                                     contentType: "application/json", timeout: VoiceWire.leaseTimeout)
                    AppLog.trace("voice", "\(kind.rawValue) lease \(active ? "hold" : "release"): \(lease.rawValue)")
                } catch {
                    VoiceEvents.noteLater("\(kind.rawValue) lease \(active ? "hold" : "release") failed: \(VoiceWire.failure(error, doing: "warm up voice").reason)")
                    AppLog.note("voice", "\(kind.rawValue) lease \(active ? "hold" : "release") failed: \(GatewayFailure.from(error).code)")
                }
            }
        }
    }

    nonisolated struct Voice: Equatable, Sendable { var label: String; var id: String }

    /// The ElevenLabs voices the gateway can list (§3.7). nil when it cannot (no key, no network).
    /// `profile`: whose ElevenLabs key lists them. Settings › Voice edits the gateway's own settings, so it asks with none.
    static func elevenLabsVoices(client: any GatewayClient, profile: String? = nil) async -> [Voice]? {
        guard let data = try? await client.rest("GET", "/api/audio/elevenlabs/voices", query: VoiceWire.profileQuery(profile), body: nil),
              let value = try? JSONValue.parse(data), value["available"]?.bool != false,
              let list = value["voices"]?.array else { return nil }
        return list.compactMap { item in
            guard let id = item["voice_id"]?.string, !id.isEmpty else { return nil }
            return Voice(label: item["label"]?.string ?? item["name"]?.string ?? id, id: id)
        }
    }

    /// The streamed speech socket (§3.3), not yet resumed.
    static func speakSocket(client: any GatewayClient, profile: String?) async throws -> URLSessionWebSocketTask {
        guard let sockets = client as? any GatewayVoiceSockets else { throw VoiceFailure(reason: "This gateway can’t stream speech.", detail: nil) }
        return try await sockets.voiceSocket(path: VoiceWire.speakStream, query: VoiceWire.profileQuery(profile))
    }
}

// [gpt-live] The two GPT-Live calls (docs/spec/3x-gpt-live.md §3.1). The gateway holds the OpenAI key; neither call
// sends it anywhere near the phone.
nonisolated extension VoiceGateway {
    private struct KeptStatus: Sendable { var status: LiveVoiceStatus?; var at: Date }
    private static let keptStatus = Locked<[String: KeptStatus]>([:])

    /// `LiveVoiceWire.statusPath`: nil when the gateway has no such route (older than v0.22.5) or did not
    /// answer. Kept as long as the voice settings.
    static func liveStatus(client: any GatewayClient, profile: String?, now: Date = Date()) async -> LiveVoiceStatus? {
        let key = "\(client.account.id)|\(profile ?? "")"
        if let hit = keptStatus.value[key], now.timeIntervalSince(hit.at) < configLifetime { return hit.status }
        let data = try? await client.rest("GET", LiveVoiceWire.statusPath, query: VoiceWire.profileQuery(profile), body: nil)
        let status = LiveVoiceStatus(json: data.flatMap { try? JSONValue.parse($0) })
        keptStatus.mutate { $0[key] = KeptStatus(status: status, at: now) }
        return status
    }

    /// What is already known without asking (the conversation bar's engine row reads it).
    static func knownLiveStatus(client: any GatewayClient, profile: String?) -> LiveVoiceStatus? {
        keptStatus.value["\(client.account.id)|\(profile ?? "")"]?.status
    }

    static func forgetLiveStatus() { keptStatus.mutate { $0.removeAll() } }

    /// `LiveVoiceWire.sessionPath`: trades the phone's offer for OpenAI's answer. Throws `VoiceFailure` with
    /// the gateway's own words (no key: 503; OpenAI refused: 502).
    static func liveSession(client: any GatewayClient, profile: String?, sdp: String, history: JSONValue) async throws -> String {
        guard let transfers = client as? any GatewayTransfers else { throw VoiceFailure(reason: "This gateway can’t start GPT-Live.", detail: nil) }
        let data: Data
        do {
            data = try await transfers.transfer("POST", LiveVoiceWire.sessionPath, query: VoiceWire.profileQuery(profile),
                                                body: LiveVoiceWire.sessionBody(sdp: sdp, history: history),
                                                contentType: "application/json", timeout: LiveVoiceWire.sessionTimeout)
        } catch {
            AppLog.note("voice", "gpt-live session start failed: \(GatewayFailure.from(error).code)")
            throw VoiceWire.failure(error, doing: "start GPT-Live")
        }
        guard let answer = LiveVoiceWire.answerSDP(data) else {
            let said = (try? JSONValue.parse(data)).flatMap { $0["detail"]?.string ?? $0["error"]?.string }
            AppLog.note("voice", "gpt-live session start: answer not understood")
            throw VoiceFailure(reason: said ?? "Your gateway’s answer wasn’t understood.",
                               detail: VoiceReport.scrub(String(decoding: data.prefix(300), as: UTF8.self)))
        }
        AppLog.trace("voice", "gpt-live session started")
        return answer
    }
}

// [grok-live] The add-on's two Grok Live calls (docs/spec/3x-grok-live.md §3.1). The xAI login or key stays on the
// computer; the phone gets a short-lived client secret for one session.
nonisolated extension VoiceGateway {
    private struct KeptGrok: Sendable { var status: GrokLiveStatus?; var at: Date }
    private static let keptGrok = Locked<[String: KeptGrok]>([:])

    /// `GrokLiveWire.statusPath`: nil when the add-on has no such route (older than 0.9.26: 404) or did not answer.
    /// Kept as long as the voice settings.
    static func grokStatus(client: any GatewayClient, profile: String?, now: Date = Date()) async -> GrokLiveStatus? {
        let key = "\(client.account.id)|\(profile ?? "")"
        if let hit = keptGrok.value[key], now.timeIntervalSince(hit.at) < configLifetime { return hit.status }
        let data = try? await client.rest("GET", GrokLiveWire.statusPath, query: VoiceWire.profileQuery(profile), body: nil)
        let status = GrokLiveStatus(json: data.flatMap { try? JSONValue.parse($0) })
        keptGrok.mutate { $0[key] = KeptGrok(status: status, at: now) }
        return status
    }

    static func knownGrokStatus(client: any GatewayClient, profile: String?) -> GrokLiveStatus? {
        keptGrok.value["\(client.account.id)|\(profile ?? "")"]?.status
    }

    static func forgetGrokStatus() { keptGrok.mutate { $0.removeAll() } }

    /// `GrokLiveWire.sessionPath`: the add-on's answer as text, checked to hold a session. Throws `VoiceFailure` with
    /// the add-on's own words (no credentials: 503; xAI refused: 502).
    static func grokSession(client: any GatewayClient, profile: String?) async throws -> String {
        guard let transfers = client as? any GatewayTransfers else { throw VoiceFailure(reason: "This gateway can’t start Grok Live.", detail: nil) }
        let data: Data
        do {
            data = try await transfers.transfer("POST", GrokLiveWire.sessionPath, query: VoiceWire.profileQuery(profile), body: Data("{}".utf8),
                                                contentType: "application/json", timeout: GrokLiveWire.sessionTimeout)
        } catch {
            AppLog.note("voice", "grok-live session start failed: \(GatewayFailure.from(error).code)")
            throw VoiceWire.failure(error, doing: "start Grok Live")
        }
        guard GrokLiveSession(json: try? JSONValue.parse(data)) != nil else {
            let said = (try? JSONValue.parse(data)).flatMap { $0["detail"]?.string ?? $0["error"]?.string }
            AppLog.note("voice", "grok-live session start: answer not understood")
            throw VoiceFailure(reason: said ?? "Your gateway’s answer wasn’t understood.", detail: nil)
        }
        AppLog.trace("voice", "grok-live session issued")
        return String(decoding: data, as: UTF8.self)
    }
}
