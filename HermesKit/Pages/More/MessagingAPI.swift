// More › Messaging (docs/spec/3x-morepages.md §12): the wire shapes, the request bodies with exactly the keys the
// gateway lists (`AG/hermes_cli/web_routers/messaging.py`, `ops.py`; `V/api/messaging.ts`), and the status rule a
// platform's row and page read. Decoded leniently: a row without an id is skipped, repeats are dropped.
// A key's value only ever travels in a PUT body: never in a URL, never to the log.

import Foundation

// MARK: - Shapes

nonisolated struct MessagingEnvVar: Sendable, Equatable, Identifiable {
    var key: String
    var prompt: String
    var description: String
    var isPassword: Bool
    var isSet: Bool
    var redactedValue: String?
    var required: Bool
    var advanced: Bool
    var url: String?
    var id: String { key }

    init(key: String, prompt: String = "", description: String = "", isPassword: Bool = false, isSet: Bool = false,
         redactedValue: String? = nil, required: Bool = false, advanced: Bool = false, url: String? = nil) {
        self.key = key; self.prompt = prompt; self.description = description; self.isPassword = isPassword
        self.isSet = isSet; self.redactedValue = redactedValue; self.required = required; self.advanced = advanced; self.url = url
    }

    init?(json: JSONValue) {
        guard let key = json["key"]?.string?.trimmingCharacters(in: .whitespaces), !key.isEmpty else { return nil }
        self.init(key: key, prompt: json["prompt"]?.string ?? "", description: json["description"]?.string ?? "",
                  isPassword: json["is_password"]?.bool ?? false, isSet: json["is_set"]?.bool ?? false,
                  redactedValue: json["redacted_value"]?.string, required: json["required"]?.bool ?? false,
                  advanced: json["advanced"]?.bool ?? false, url: json["url"]?.string)
    }

    /// The row's label: the gateway's prompt, or the key when it has none.
    var label: String {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? key : text
    }

    /// The same key as the Settings key page reads it.
    var info: EnvVarInfo {
        EnvVarInfo(key: key, description: description, isPassword: isPassword, isSet: isSet, advanced: advanced,
                   redactedValue: redactedValue, url: url)
    }
}

nonisolated struct MessagingPlatform: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var description: String
    var docsURL: String?
    var configured: Bool
    var enabled: Bool
    var gatewayRunning: Bool
    var state: String?
    var errorCode: String?
    var errorMessage: String?
    var updatedAt: String?
    var envVars: [MessagingEnvVar]

    init(id: String, name: String = "", description: String = "", docsURL: String? = nil, configured: Bool = false,
         enabled: Bool = false, gatewayRunning: Bool = false, state: String? = nil, errorCode: String? = nil,
         errorMessage: String? = nil, updatedAt: String? = nil, envVars: [MessagingEnvVar] = []) {
        self.id = id; self.name = name.isEmpty ? id : name; self.description = description; self.docsURL = docsURL
        self.configured = configured; self.enabled = enabled; self.gatewayRunning = gatewayRunning; self.state = state
        self.errorCode = errorCode; self.errorMessage = errorMessage; self.updatedAt = updatedAt; self.envVars = envVars
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.pgString?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        var seen = Set<String>()
        let vars = (json["env_vars"]?.array ?? []).compactMap(MessagingEnvVar.init(json:)).filter { seen.insert($0.key).inserted }
        self.init(id: id, name: json["name"]?.string ?? "", description: json["description"]?.string ?? "",
                  docsURL: json["docs_url"]?.string, configured: json["configured"]?.bool ?? false,
                  enabled: json["enabled"]?.bool ?? false, gatewayRunning: json["gateway_running"]?.bool ?? false,
                  state: json["state"]?.string, errorCode: json["error_code"]?.pgString,
                  errorMessage: json["error_message"]?.string, updatedAt: json["updated_at"]?.pgString, envVars: vars)
    }

    /// `{"platforms":[…]}`: bad rows skipped, a repeated id kept once (a list must never trap on a duplicate).
    static func list(_ json: JSONValue) -> [MessagingPlatform] {
        var seen = Set<String>()
        return (json["platforms"]?.array ?? []).compactMap(MessagingPlatform.init(json:)).filter { seen.insert($0.id).inserted }
    }

    var keys: [MessagingEnvVar] { envVars.filter { !$0.advanced } }
    var advancedKeys: [MessagingEnvVar] { envVars.filter(\.advanced) }
    var status: MessagingStatus { MessagingStatus(self) }

    /// The setup guide, only when it is a real web link.
    var guide: URL? {
        guard let docsURL, let url = URL(string: docsURL), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    /// SF symbol per platform id; the generic one otherwise.
    var symbol: String {
        switch id.lowercased() {
        case "telegram": return "paperplane.fill"
        case "discord": return "gamecontroller.fill"
        case "slack": return "number"
        case "email": return "envelope.fill"
        case "sms": return "message.fill"
        case "whatsapp": return "phone.bubble.fill"
        case "signal": return "bubble.left.fill"
        case "matrix": return "square.grid.3x3.fill"
        case "webhook": return "arrow.triangle.turn.up.right.diamond.fill"
        case "api_server": return "server.rack"
        case "homeassistant": return "house.fill"
        default: return "bubble.left.and.bubble.right"
        }
    }

    func matches(_ query: String) -> Bool {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !words.isEmpty else { return true }
        return [id, name, description, status.text].contains { $0.lowercased().contains(words) }
    }
}

/// A platform's status line (spec §12; tones `V/lib/platform-status.ts`, words `V/i18n/en.ts` messaging.states, and
/// the phone's "Status unknown" for a platform the running gateway never reported on, `S/messaging-state.ts`).
nonisolated struct MessagingStatus: Sendable, Equatable {
    enum Tone: Sendable, Equatable {
        case good, muted, warn, bad

        /// Item 22: error leads (Status & Maintenance's "1 Issue" sends people here to fix it), then needs setup / other
        /// problems, then connected, then off.
        var sortRank: Int {
            switch self {
            case .bad: return 0
            case .warn: return 1
            case .good: return 2
            case .muted: return 3
            }
        }
    }
    var text: String
    var tone: Tone

    init(text: String, tone: Tone) { self.text = text; self.tone = tone }

    init(_ platform: MessagingPlatform) {
        let state = platform.state?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let error = platform.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !platform.configured {
            self.init(text: "Needs setup", tone: .warn)
        } else if !platform.enabled {
            self.init(text: "Off", tone: .muted)
        } else if !error.isEmpty {
            self.init(text: error, tone: .bad)
        } else if !platform.gatewayRunning {
            self.init(text: state == "startup_failed" ? "Startup failed" : "Not running", tone: state == "startup_failed" ? .bad : .warn)
        } else {
            switch state {
            case "connected": self.init(text: "Connected", tone: .good)
            case "connecting": self.init(text: "Connecting…", tone: .warn)
            case "retrying": self.init(text: "Retrying…", tone: .warn)
            case "fatal": self.init(text: "Error", tone: .bad)
            case "startup_failed": self.init(text: "Startup failed", tone: .bad)
            case "pending_restart":
                // Running, but never reported on: unknown, with no advice to restart a healthy gateway.
                self.init(text: platform.updatedAt == nil ? "Status unknown" : "Restart needed", tone: .warn)
            case "", "status_unknown": self.init(text: "Status unknown", tone: .warn)
            case "disabled": self.init(text: "Off", tone: .muted)
            case "not_configured": self.init(text: "Needs setup", tone: .warn)
            case "gateway_stopped": self.init(text: "Not running", tone: .warn)
            default: self.init(text: MessagingStatus.titled(state), tone: .warn)
            }
        }
    }

    /// "some_new_state" → "Some New State".
    static func titled(_ state: String) -> String {
        state.split(whereSeparator: { $0 == "_" || $0 == " " }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

nonisolated struct PairingPerson: Sendable, Equatable, Identifiable {
    var platform: String
    var userId: String
    var userName: String?
    var requestId: String?
    var ageMinutes: Double?
    var id: String { "\(platform):\(userId)" }
    var name: String {
        let text = userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? userId : text
    }

    init(platform: String, userId: String, userName: String? = nil, requestId: String? = nil, ageMinutes: Double? = nil) {
        self.platform = platform; self.userId = userId; self.userName = userName; self.requestId = requestId; self.ageMinutes = ageMinutes
    }

    init?(json: JSONValue) {
        guard let platform = json["platform"]?.string?.lowercased(), !platform.isEmpty,
              let user = json["user_id"]?.pgString, !user.isEmpty else { return nil }
        self.init(platform: platform, userId: user, userName: json["user_name"]?.pgString, requestId: json["request_id"]?.pgString,
                  ageMinutes: json["age_minutes"]?.double.flatMap { $0.isFinite ? $0 : nil })
    }

    /// "Just now", "12 min ago", "3 hr ago", "2 days ago" (`waitingSince`).
    var age: String? {
        guard let ageMinutes else { return nil }
        let minutes = Int(max(0, ageMinutes))
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 60 * 48 { return "\(minutes / 60) hr ago" }
        return "\(minutes / 1440) days ago"
    }
}

nonisolated struct MessagingPairing: Sendable, Equatable {
    var pending: [PairingPerson] = []
    var approved: [PairingPerson] = []

    init(pending: [PairingPerson] = [], approved: [PairingPerson] = []) { self.pending = pending; self.approved = approved }

    init(json: JSONValue) {
        func people(_ key: String, needsRequest: Bool) -> [PairingPerson] {
            var seen = Set<String>()
            return (json[key]?.array ?? []).compactMap(PairingPerson.init(json:))
                .filter { !needsRequest || !($0.requestId ?? "").isEmpty }
                .filter { seen.insert($0.id).inserted }
        }
        pending = people("pending", needsRequest: true)
        approved = people("approved", needsRequest: false)
    }

    func pending(for platform: String) -> [PairingPerson] { pending.filter { $0.platform == platform.lowercased() } }
    func approved(for platform: String) -> [PairingPerson] { approved.filter { $0.platform == platform.lowercased() } }
}

nonisolated struct MessagingTestResult: Sendable, Equatable {
    var ok: Bool
    var message: String

    init(ok: Bool, message: String) { self.ok = ok; self.message = message }

    init(json: JSONValue) {
        ok = json["ok"]?.bool ?? false
        let text = json["message"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        message = text.isEmpty ? (ok ? "Connected." : "The gateway gave no answer for this test.") : text
    }
}

// MARK: - Telegram onboarding shapes

nonisolated struct TelegramSetupStart: Sendable, Equatable {
    var pairingId: String
    var deepLink: String
    var qrPayload: String
    var suggestedUsername: String?
    var expiresAt: Date?

    init(pairingId: String, deepLink: String, qrPayload: String, suggestedUsername: String? = nil, expiresAt: Date? = nil) {
        self.pairingId = pairingId; self.deepLink = deepLink; self.qrPayload = qrPayload
        self.suggestedUsername = suggestedUsername; self.expiresAt = expiresAt
    }

    init?(json: JSONValue) {
        guard let id = json["pairing_id"]?.pgString, !id.isEmpty else { return nil }
        let link = json["deep_link"]?.string ?? ""
        let payload = json["qr_payload"]?.string ?? ""
        guard !link.isEmpty || !payload.isEmpty else { return nil }
        self.init(pairingId: id, deepLink: link.isEmpty ? payload : link, qrPayload: payload.isEmpty ? link : payload,
                  suggestedUsername: json["suggested_username"]?.string, expiresAt: MessagingDates.parse(json["expires_at"]))
    }

    /// The link Open Telegram follows: Telegram's own schemes and web links only.
    var openURL: URL? {
        guard let url = URL(string: deepLink), let scheme = url.scheme?.lowercased(), ["https", "tg"].contains(scheme) else { return nil }
        return url
    }
}

nonisolated enum TelegramSetupStatus: Sendable, Equatable {
    case waiting
    case ready(botUsername: String?, ownerUserId: String?)

    init(json: JSONValue) {
        if json["status"]?.string == "ready" {
            let owner = json["owner_user_id"]?.pgString.flatMap { TelegramSetup.isUserId($0) ? $0 : nil }
            self = .ready(botUsername: json["bot_username"]?.string, ownerUserId: owner)
        } else {
            self = .waiting
        }
    }
}

nonisolated struct TelegramSetupApplied: Sendable, Equatable {
    var botUsername: String?
    var needsRestart: Bool
    var restartStarted: Bool
    var restartError: String?

    init(botUsername: String? = nil, needsRestart: Bool = false, restartStarted: Bool = false, restartError: String? = nil) {
        self.botUsername = botUsername; self.needsRestart = needsRestart; self.restartStarted = restartStarted; self.restartError = restartError
    }

    init(json: JSONValue) {
        self.init(botUsername: json["bot_username"]?.string, needsRestart: json["needs_restart"]?.bool ?? false,
                  restartStarted: json["restart_started"]?.bool ?? false, restartError: json["restart_error"]?.string)
    }
}

nonisolated enum MessagingDates {
    /// An ISO 8601 time (with or without fractions, with or without a zone: none reads as UTC) or epoch seconds.
    static func parse(_ value: JSONValue?) -> Date? {
        guard let value else { return nil }
        if case .number(let seconds) = value, seconds.isFinite, seconds > 0 { return Date(timeIntervalSince1970: seconds) }
        guard var text = value.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = Double(text), seconds > 0 { return Date(timeIntervalSince1970: seconds) }
        let hasZone = text.hasSuffix("Z") || text.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        if !hasZone { text += "Z" }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

// MARK: - Bodies (exact keys)

nonisolated enum MessagingBodies {
    /// `{"enabled": bool}` and nothing else.
    static func enabled(_ on: Bool) -> JSONValue { .object(["enabled": .bool(on)]) }

    /// `{"env": {KEY: "value"}}`.
    static func env(_ key: String, _ value: String) -> JSONValue { .object(["env": .object([key: .string(value)])]) }

    /// `{"clear_env": ["KEY"]}`.
    static func clear(_ key: String) -> JSONValue { .object(["clear_env": .array([.string(key)])]) }

    /// `{"platform","request_id","profile"?}`: these two routes read the profile off the body, not the query
    /// (`V/api/messaging.ts:128-131`).
    static func approve(platform: String, requestId: String, profile: String?) -> JSONValue {
        MoreWire.profileParams(profile, ["platform": .string(platform), "request_id": .string(requestId)])
    }

    /// `{"platform","user_id","profile"?}`.
    static func revoke(platform: String, userId: String, profile: String?) -> JSONValue {
        MoreWire.profileParams(profile, ["platform": .string(platform), "user_id": .string(userId)])
    }

    /// `{}` or `{"bot_name": "…"}`.
    static func telegramStart(botName: String?) -> JSONValue {
        let name = botName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .object(name.isEmpty ? [:] : ["bot_name": .string(name)])
    }

    /// `{"allowed_user_ids": ["…"], "profile"?}`.
    static func telegramApply(allowed: [String], profile: String?) -> JSONValue {
        MoreWire.profileParams(profile, ["allowed_user_ids": .array(allowed.map(JSONValue.string))])
    }
}

// MARK: - API

nonisolated struct MessagingAPI: Sendable {
    let client: any GatewayClient

    func platforms(profile: String?) async throws -> [MessagingPlatform] {
        let answer = try await PagesREST.json(client, "GET", "/api/messaging/platforms", query: MoreWire.profileQuery(profile), timeout: 30)
        guard answer["platforms"]?.array != nil else { throw PagesREST.unreadable(answer) }
        let list = MessagingPlatform.list(answer)
        AppLog.trace("pages", "messaging platforms \(AppLog.tag(profile)): \(list.count), \(MessagingIssues.failing(list).count) failing")
        return list
    }

    /// Returns `hot_served`: the running gateway took the change at once, no restart needed.
    @discardableResult
    func update(_ platform: String, body: JSONValue, profile: String?) async throws -> Bool {
        let start = ContinuousClock.now
        do {
            let answer = try await PagesREST.json(client, "PUT", "/api/messaging/platforms/\(PagesREST.segment(platform))",
                                                  query: MoreWire.profileQuery(profile), json: body, timeout: 30)
            let hotServed = answer["hot_served"]?.bool ?? false
            AppLog.trace("config", "messaging \(platform) update ok in \(AppLog.ms(since: start)) ms, hot served \(hotServed)")
            return hotServed
        } catch {
            AppLog.note("config", "messaging \(platform) update failed after \(AppLog.ms(since: start)) ms: \(PagesREST.reason(error))")
            throw error
        }
    }

    func test(_ platform: String, profile: String?) async throws -> MessagingTestResult {
        let start = ContinuousClock.now
        do {
            let answer = try await PagesREST.json(client, "POST", "/api/messaging/platforms/\(PagesREST.segment(platform))/test",
                                                  query: MoreWire.profileQuery(profile), timeout: 45)
            let result = MessagingTestResult(json: answer)
            AppLog.trace("config", "messaging \(platform) test in \(AppLog.ms(since: start)) ms: \(result.ok)")
            return result
        } catch {
            AppLog.note("config", "messaging \(platform) test failed after \(AppLog.ms(since: start)) ms: \(PagesREST.reason(error))")
            throw error
        }
    }

    func pairing(profile: String?) async throws -> MessagingPairing {
        MessagingPairing(json: try await PagesREST.json(client, "GET", "/api/pairing", query: MoreWire.profileQuery(profile), timeout: 30))
    }

    func approve(platform: String, requestId: String, profile: String?) async throws {
        do {
            _ = try await PagesREST.json(client, "POST", "/api/pairing/approve",
                                         json: MessagingBodies.approve(platform: platform, requestId: requestId, profile: profile), timeout: 30)
            AppLog.trace("config", "pairing \(platform) approve \(AppLog.tag(requestId)) ok")
        } catch {
            AppLog.note("config", "pairing \(platform) approve \(AppLog.tag(requestId)) failed: \(PagesREST.reason(error))")
            throw error
        }
    }

    func revoke(platform: String, userId: String, profile: String?) async throws {
        do {
            _ = try await PagesREST.json(client, "POST", "/api/pairing/revoke",
                                         json: MessagingBodies.revoke(platform: platform, userId: userId, profile: profile), timeout: 30)
            AppLog.trace("config", "pairing \(platform) revoke \(AppLog.tag(userId)) ok")
        } catch {
            AppLog.note("config", "pairing \(platform) revoke \(AppLog.tag(userId)) failed: \(PagesREST.reason(error))")
            throw error
        }
    }

    // Telegram: every call of one flow carries the same profile scope (`V/api/messaging.ts:60-63`).

    func telegramStart(botName: String?, profile: String?) async throws -> TelegramSetupStart {
        do {
            let answer = try await PagesREST.json(client, "POST", "/api/messaging/telegram/onboarding/start",
                                                  query: MoreWire.profileQuery(profile), json: MessagingBodies.telegramStart(botName: botName), timeout: 45)
            guard let start = TelegramSetupStart(json: answer) else { throw PagesMessageError("Telegram’s setup service gave an answer that couldn’t be read.") }
            AppLog.trace("config", "telegram setup start \(AppLog.tag(start.pairingId)) ok")
            return start
        } catch {
            AppLog.note("config", "telegram setup start failed: \(PagesREST.reason(error))")
            throw error
        }
    }

    func telegramStatus(_ pairingId: String, profile: String?) async throws -> TelegramSetupStatus {
        TelegramSetupStatus(json: try await PagesREST.json(client, "GET", "/api/messaging/telegram/onboarding/\(PagesREST.segment(pairingId))",
                                                           query: MoreWire.profileQuery(profile), timeout: 20))
    }

    func telegramApply(_ pairingId: String, allowed: [String], profile: String?) async throws -> TelegramSetupApplied {
        do {
            let applied = TelegramSetupApplied(json: try await PagesREST.json(
                client, "POST", "/api/messaging/telegram/onboarding/\(PagesREST.segment(pairingId))/apply",
                query: MoreWire.profileQuery(profile), json: MessagingBodies.telegramApply(allowed: allowed, profile: profile), timeout: 60))
            AppLog.trace("config", "telegram setup apply \(AppLog.tag(pairingId)) ok, \(allowed.count) allowed")
            return applied
        } catch {
            AppLog.note("config", "telegram setup apply \(AppLog.tag(pairingId)) failed: \(PagesREST.reason(error))")
            throw error
        }
    }

    func telegramCancel(_ pairingId: String, profile: String?) async throws {
        _ = try await PagesREST.send(client, "DELETE", "/api/messaging/telegram/onboarding/\(PagesREST.segment(pairingId))",
                                     query: MoreWire.profileQuery(profile), timeout: 15)
        AppLog.trace("config", "telegram setup \(AppLog.tag(pairingId)) cancelled")
    }
}

// MARK: - Telegram onboarding state machine

/// "Set Up with Telegram" from start to Finish (spec §12): start → waiting (polled every 2 s until `expires_at`) →
/// ready → applying → applied. An expired or forgotten pairing says so and offers Start Again. Leaving before Finish
/// sends the DELETE.
@MainActor @Observable
final class TelegramSetup {
    enum Phase: Equatable {
        case idle
        case starting
        case waiting(TelegramSetupStart)
        case ready(botUsername: String?, ownerUserId: String?)
        case applying
        case applied(TelegramSetupApplied)
        case expired
        /// Start failed: the reason, with Try Again.
        case failed(String)
    }

    /// What the machine calls; the page wires these to `MessagingAPI` with one profile for the whole flow.
    struct Calls: Sendable {
        var start: @Sendable () async throws -> TelegramSetupStart
        var status: @Sendable (String) async throws -> TelegramSetupStatus
        var apply: @Sendable (String, [String]) async throws -> TelegramSetupApplied
        var cancel: @Sendable (String) async throws -> Void
    }

    private(set) var phase: Phase = .idle
    /// A status read that failed while waiting ("Still waiting for Telegram…"), or a refused Finish.
    private(set) var notice: String?
    private(set) var expiresAt: Date?

    @ObservationIgnored var interval: Duration = .seconds(2)
    @ObservationIgnored var now: @Sendable () -> Date = { Date() }
    @ObservationIgnored var onApplied: ((TelegramSetupApplied) -> Void)?
    /// Finish was refused and the sheet is back to ready with the reason (the app's error tap).
    @ObservationIgnored var onFinishRefused: (() -> Void)?
    @ObservationIgnored private let calls: Calls
    @ObservationIgnored private var pairingId: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private(set) var cancelTask: Task<Void, Never>?

    init(calls: Calls) { self.calls = calls }

    static let expiredText = "This link expired. Start again."

    /// Telegram user ids are whole numbers (`TELEGRAM_USER_ID_RE`).
    nonisolated static func isUserId(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 20 && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// "42, 43" → ["42","43"]; nil when any piece is not a number or nothing is left.
    nonisolated static func userIds(_ typed: String) -> [String]? {
        let pieces = typed.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
        guard !pieces.isEmpty, pieces.allSatisfy(isUserId) else { return nil }
        var seen = Set<String>()
        return pieces.filter { seen.insert($0).inserted }
    }

    /// The gateway no longer knows this pairing (404), or says it expired (410).
    nonisolated static func isTerminal(_ error: Error) -> Bool {
        guard let status = (error as? HTTPError)?.status else { return false }
        return status == 404 || status == 410
    }

    func start() {
        switch phase {
        case .idle, .expired, .failed: break
        default: return
        }
        task?.cancel()
        forget()
        phase = .starting
        notice = nil
        task = Task { [weak self, calls] in
            do {
                let started = try await calls.start()
                guard let self, !Task.isCancelled else {
                    // Closed while starting: the pairing just made is given back.
                    try? await calls.cancel(started.pairingId)
                    return
                }
                self.pairingId = started.pairingId
                self.expiresAt = started.expiresAt
                self.phase = .waiting(started)
                await self.poll(started)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed(PagesREST.reason(error))
            }
        }
    }

    private func poll(_ started: TelegramSetupStart) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, case .waiting = phase else { return }
            if let expiresAt, now() >= expiresAt { expire(); return }
            do {
                let status = try await calls.status(started.pairingId)
                guard !Task.isCancelled, case .waiting = phase else { return }
                notice = nil
                if case .ready(let bot, let owner) = status {
                    phase = .ready(botUsername: bot, ownerUserId: owner)
                    return
                }
            } catch {
                guard !Task.isCancelled, case .waiting = phase else { return }
                if Self.isTerminal(error) || (expiresAt.map { now() >= $0 } ?? false) { expire(); return }
                notice = "Still waiting for Telegram. \(PagesREST.reason(error))"
            }
        }
    }

    private func expire() {
        // The gateway has already dropped it (or will on its own): nothing to DELETE.
        pairingId = nil
        phase = .expired
        notice = nil
    }

    /// Finish: saves the bot with the people allowed to message it.
    func finish(allowed: [String]) {
        guard case .ready(let bot, let owner) = phase, let pairingId else { return }
        guard !allowed.isEmpty else { notice = "Add at least one Telegram user ID."; return }
        phase = .applying
        notice = nil
        task = Task { [weak self, calls] in
            do {
                let applied = try await calls.apply(pairingId, allowed)
                guard let self else { return }
                self.pairingId = nil
                self.phase = .applied(applied)
                self.onApplied?(applied)
            } catch {
                guard let self, !Task.isCancelled else { return }
                if Self.isTerminal(error) { self.expire(); return }
                self.phase = .ready(botUsername: bot, ownerUserId: owner)
                self.notice = PagesREST.reason(error)
                self.onFinishRefused?()
            }
        }
    }

    /// The sheet closed. Before Finish this gives the pairing back (DELETE); after it there is nothing to undo.
    func close() {
        if case .applying = phase { return }      // Finish is on its way: let it land.
        task?.cancel()
        task = nil
        forget()
        if case .applied = phase { return }
        phase = .idle
        notice = nil
    }

    private func forget() {
        guard let id = pairingId else { return }
        pairingId = nil
        cancelTask = Task { [calls] in try? await calls.cancel(id) }
    }

    /// "9:41" left on the link at `date`; nil once it has run out or when the gateway gave no time.
    func remaining(at date: Date) -> String? {
        guard let expiresAt else { return nil }
        let seconds = Int(expiresAt.timeIntervalSince(date).rounded(.down))
        guard seconds > 0 else { return nil }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
