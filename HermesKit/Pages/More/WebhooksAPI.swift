// More › Webhooks (docs/spec/3x-morepages.md §13): the wire shapes (`AG/hermes_cli/web_routers/ops.py`,
// `V/api/messaging.ts:150-195`), the New Webhook form's payload (absent keys are not sent) and the row's words.
// A webhook's secret is in the create answer only: `WebhookCreated` is handed to the sheet that shows it once and is
// never stored or logged.

import Foundation

nonisolated struct WebhookRoute: Sendable, Equatable, Identifiable {
    var name: String
    var description: String
    var events: [String]
    var skills: [String]
    var deliver: String
    var deliverOnly: Bool
    var prompt: String
    var enabled: Bool
    var secretSet: Bool
    var url: String
    var createdAt: Date?
    var id: String { name }

    init(name: String, description: String = "", events: [String] = [], skills: [String] = [], deliver: String = "log",
         deliverOnly: Bool = false, prompt: String = "", enabled: Bool = true, secretSet: Bool = false, url: String = "",
         createdAt: Date? = nil) {
        self.name = name; self.description = description; self.events = events; self.skills = skills; self.deliver = deliver
        self.deliverOnly = deliverOnly; self.prompt = prompt; self.enabled = enabled; self.secretSet = secretSet; self.url = url
        self.createdAt = createdAt
    }

    init?(json: JSONValue) {
        guard let name = json["name"]?.pgString?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        func strings(_ key: String) -> [String] {
            (json[key]?.array ?? []).compactMap(\.pgString).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let deliver = json["deliver"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        self.init(name: name, description: json["description"]?.string ?? "", events: strings("events"), skills: strings("skills"),
                  deliver: deliver.isEmpty ? "log" : deliver, deliverOnly: json["deliver_only"]?.bool ?? false,
                  prompt: json["prompt"]?.string ?? "",
                  // Default-on: only an explicit `false` turns a route off (`_webhook_route_summary`).
                  enabled: json["enabled"]?.bool ?? true, secretSet: json["secret_set"]?.bool ?? false,
                  url: json["url"]?.string ?? "", createdAt: MessagingDates.parse(json["created_at"]))
    }

    /// "push, pull_request → Telegram" / "All Events → Log Only": what it listens for, then where the result goes
    /// (UX study #105). The events stay the sender's own names.
    var summary: String {
        "\(events.isEmpty ? "All Events" : events.joined(separator: ", ")) → \(WebhookDeliver.label(deliver))"
    }

    /// `summary` as VoiceOver reads it: "to" in words, not "right arrow".
    var spokenSummary: String {
        "\(events.isEmpty ? "All Events" : events.joined(separator: ", ")) to \(WebhookDeliver.label(deliver))"
    }

    func matches(_ query: String) -> Bool {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !words.isEmpty else { return true }
        return ([name, description, deliver, WebhookDeliver.label(deliver)] + events).contains { $0.lowercased().contains(words) }
    }
}

nonisolated struct WebhooksAnswer: Sendable, Equatable {
    /// The receiver itself (a gateway platform) is on.
    var enabled: Bool
    var baseURL: String
    var subscriptions: [WebhookRoute]

    init(enabled: Bool, baseURL: String = "", subscriptions: [WebhookRoute] = []) {
        self.enabled = enabled; self.baseURL = baseURL; self.subscriptions = subscriptions
    }

    /// nil when the answer is not the webhooks object at all.
    init?(json: JSONValue) {
        guard json.object != nil, json["enabled"] != nil || json["subscriptions"] != nil else { return nil }
        var seen = Set<String>()
        self.init(enabled: json["enabled"]?.bool ?? false, baseURL: json["base_url"]?.string ?? "",
                  subscriptions: (json["subscriptions"]?.array ?? []).compactMap(WebhookRoute.init(json:)).filter { seen.insert($0.name).inserted })
    }
}

nonisolated struct WebhookEnableResult: Sendable, Equatable {
    var needsRestart: Bool
    var restartStarted: Bool
    var restartError: String?

    init(needsRestart: Bool, restartStarted: Bool, restartError: String? = nil) {
        self.needsRestart = needsRestart; self.restartStarted = restartStarted; self.restartError = restartError
    }

    init(json: JSONValue) {
        self.init(needsRestart: json["needs_restart"]?.bool ?? false, restartStarted: json["restart_started"]?.bool ?? false,
                  restartError: json["restart_error"]?.string)
    }

    /// The notice with Restart Gateway shows when a restart is needed and none is already on its way.
    var showsRestartNotice: Bool { needsRestart && !restartStarted }
}

/// The create answer: the route and its secret, shown once.
nonisolated struct WebhookCreated: Sendable {
    var name: String
    var url: String
    var secret: String

    init(name: String, url: String, secret: String) { self.name = name; self.url = url; self.secret = secret }

    init?(json: JSONValue) {
        guard json.object != nil else { return nil }
        self.init(name: json["name"]?.pgString ?? "", url: json["url"]?.string ?? "", secret: json["secret"]?.string ?? "")
    }
}

/// Where a webhook's result goes (`DELIVER_OPTIONS`, `deliverOptions`).
nonisolated enum WebhookDeliver {
    static let options = ["log", "telegram", "discord", "slack", "email", "github_comment"]

    static func label(_ deliver: String) -> String {
        switch deliver {
        case "log": return "Log Only"          // kept in the gateway's log, sent nowhere
        case "telegram": return "Telegram"
        case "discord": return "Discord"
        case "slack": return "Slack"
        case "email": return "Email"
        case "github_comment": return "GitHub Comment"
        default: return deliver.isEmpty ? "Log Only" : deliver
        }
    }

    /// A chat platform takes a chat to deliver to (`deliver_chat_id`).
    static func isChat(_ deliver: String) -> Bool { ["telegram", "discord", "slack"].contains(deliver) }
}

/// The New Webhook form.
nonisolated struct WebhookForm: Sendable, Equatable {
    var name = ""
    var description = ""
    var events = ""
    var skills = ""
    var deliver = "log"
    var deliverChatId = ""
    var deliverOnly = false
    var prompt = ""

    /// "a, b ,, c" → ["a","b","c"].
    static func list(_ typed: String) -> [String] {
        typed.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The name as the gateway will keep it: lower case, spaces as hyphens.
    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// `^[a-z0-9][a-z0-9_-]*$` (the gateway's rule).
    var nameIsValid: Bool { normalizedName.range(of: #"^[a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil }

    /// Payload-only delivery needs a real target: the gateway refuses it with Log.
    var canDeliverOnly: Bool { deliver != "log" }
    var canCreate: Bool { nameIsValid }

    /// `{"name","deliver","deliver_only", "description"?, "events"?, "skills"?, "deliver_chat_id"?, "prompt"?}`: the
    /// three the web always sends (`V/app/webhooks/index.tsx:230-238`); every other key only when it has a value.
    var payload: JSONValue {
        var out: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "deliver": .string(deliver),
            "deliver_only": .bool(deliverOnly && canDeliverOnly),
        ]
        let about = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !about.isEmpty { out["description"] = .string(about) }
        let eventList = Self.list(events)
        if !eventList.isEmpty { out["events"] = .array(eventList.map(JSONValue.string)) }
        let skillList = Self.list(skills)
        if !skillList.isEmpty { out["skills"] = .array(skillList.map(JSONValue.string)) }
        let chat = deliverChatId.trimmingCharacters(in: .whitespacesAndNewlines)
        if WebhookDeliver.isChat(deliver), !chat.isEmpty { out["deliver_chat_id"] = .string(chat) }
        let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { out["prompt"] = .string(words) }
        return .object(out)
    }
}

nonisolated enum WebhookWords {
    static let nameTaken = "A webhook with that name already exists."

    /// Why Create failed, in words: a 409 is the name being taken.
    static func createFailure(_ error: Error) -> String {
        PagesREST.status(error) == 409 ? nameTaken : PagesREST.reason(error)
    }

    static func toggleFailure(_ name: String, on: Bool) -> String { "Couldn’t turn “\(name)” \(on ? "on" : "off")" }
}

nonisolated struct WebhooksAPI: Sendable {
    let client: any GatewayClient

    func list() async throws -> WebhooksAnswer {
        let answer = try await PagesREST.json(client, "GET", "/api/webhooks", timeout: 30)
        guard let parsed = WebhooksAnswer(json: answer) else { throw PagesREST.unreadable(answer) }
        AppLog.trace("pages", "webhooks list: enabled \(parsed.enabled), \(parsed.subscriptions.count) routes")
        return parsed
    }

    func enable() async throws -> WebhookEnableResult {
        let result = WebhookEnableResult(json: try await PagesREST.json(client, "POST", "/api/webhooks/enable", timeout: 60))
        AppLog.trace("config", "webhooks enable: needs restart \(result.needsRestart), restart started \(result.restartStarted)")
        return result
    }

    func create(_ form: WebhookForm) async throws -> WebhookCreated {
        do {
            let answer = try await PagesREST.json(client, "POST", "/api/webhooks", json: form.payload, timeout: 30)
            guard let created = WebhookCreated(json: answer) else { throw PagesREST.unreadable(answer) }
            AppLog.trace("config", "webhook create \(AppLog.tag(created.name)) ok")
            return created
        } catch {
            AppLog.note("config", "webhook create failed: \(WebhookWords.createFailure(error))")
            throw error
        }
    }

    /// `PUT /api/webhooks/<name>/enabled` with `{"enabled": bool}`.
    func setEnabled(_ name: String, _ on: Bool) async throws {
        do {
            _ = try await PagesREST.json(client, "PUT", "/api/webhooks/\(PagesREST.segment(name))/enabled",
                                         json: .object(["enabled": .bool(on)]), timeout: 30)
            AppLog.trace("config", "webhook \(AppLog.tag(name)) set enabled \(on)")
        } catch {
            AppLog.note("config", "webhook \(AppLog.tag(name)) set enabled \(on) failed: \(PagesREST.reason(error))")
            throw error
        }
    }

    func delete(_ name: String) async throws {
        do {
            _ = try await PagesREST.send(client, "DELETE", "/api/webhooks/\(PagesREST.segment(name))", timeout: 30)
            AppLog.trace("config", "webhook \(AppLog.tag(name)) deleted")
        } catch {
            AppLog.note("config", "webhook \(AppLog.tag(name)) delete failed: \(PagesREST.reason(error))")
            throw error
        }
    }
}
