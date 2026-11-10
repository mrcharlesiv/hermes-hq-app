// [sessions-m9] Session Info's rows (docs/spec/3x-sessions.md §10): a port of the web's `sessionInfoRows`
// (`S/phone-chat-menu-model.ts:81-113`). Pure: what the chat reports live, its stored row and the gateway link go in;
// the twelve rows, each only when it has a value, come out. The sheet draws them and Copy Session Info joins them.

import Foundation

/// What the stored row says about a chat (the Sessions list's row, or the one read by id when the list does not hold it).
nonisolated struct SessionInfoStoredRow: Hashable, Sendable {
    var model: String? = nil
    var cwd: String? = nil
    var gitBranch: String? = nil
    var actualCostUsd: Double? = nil
    var estimatedCostUsd: Double? = nil
    var messageCount: Int? = nil
    var source: String? = nil
    var handoffPlatform: String? = nil
}

nonisolated struct SessionInfoSource: Hashable, Sendable {
    /// The live model and provider ids (the loaded runtime's); nil for a chat not resumed yet.
    var model: String? = nil
    var provider: String? = nil
    var answeredBy: ModelFallback? = nil
    /// The reasoning effort as the app names it ("Extra High"), and Fast.
    var reasoning: String? = nil
    var fast = false
    var usage: SessionUsage? = nil
    /// The model's price as the ⋯ Model Prices row words it ("$0.15 in · $0.60 out", "Included"), when known.
    var price: String? = nil
    var row: SessionInfoStoredRow? = nil
    /// The chat's folder and branch as the runtime reports them; they win over the stored row's.
    var liveCwd: String? = nil
    var liveBranch: String? = nil
    /// The bot's profile id ("default" for Hermes).
    var profile: String? = nil
    var sessionId: String? = nil
    /// The gateway's host, and its link's words ("Connected", "Offline", "Reconnecting…").
    var gateway: String? = nil
    var gatewayNote: String? = nil
}

/// The display names in place of raw ids: the model and provider as the picker names them, the profile as the Bots
/// list does.
struct SessionInfoNames {
    var model: (String) -> String = { $0 }
    var provider: (String) -> String = { $0 }
    var profile: (String) -> String = { $0 }
}

nonisolated struct SessionInfoRow: Hashable, Sendable {
    var label: String
    var value: String
    var note: String? = nil
    var mono = false
    /// The row as Copy Session Info puts it, when that differs from "Label: value (note)" (the raw ids).
    var copy: String? = nil
    /// Tapping the row copies its value (the chat's id), whatever the row is called.
    var copiesValue = false
    /// A thin bar under the row, 0–1 (Context full, Cache read from cache); nil for none.
    var bar: Double? = nil

    var copyText: String { copy ?? "\(label): \(value)\(note.map { " (\($0))" } ?? "")" }

    /// `info.row.<label in lower-case, spaces as dashes>`.
    var identifier: String { "info.row." + label.lowercased().replacingOccurrences(of: " ", with: "-") }
}

enum SessionInfoRows {
    /// Below 1,000 as is; then one decimal with a capital K ("15.4K", "200K"); from a million with M ("1.5M").
    nonisolated static func count(_ value: Int) -> String {
        guard value >= 1_000 else { return String(value) }
        // K, M, B, T; a figure that rounds to 1000 of a unit moves up one ("1M", never "1000K"). Past the trillions
        // is a broken gateway's figure (stress round 1: 1e18 read "1000000000000M"): it is capped, not spelled out.
        var scaled = Double(value) / 1_000
        for suffix in ["K", "M", "B", "T"] {
            if scaled < 999.95 {
                var text = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), scaled)
                if text.hasSuffix(".0") { text.removeLast(2) }
                return text + suffix
            }
            scaled /= 1_000
        }
        return "999T+"
    }

    /// A model id as two ids are compared: lower-case, without a trailing "[…]" tag, the last path part.
    nonisolated static func bareModel(_ model: String) -> String {
        var text = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix("]"), let open = text.lastIndex(of: "[") { text = String(text[..<open]) }
        if let slash = text.lastIndex(of: "/") { text = String(text[text.index(after: slash)...]) }
        return text
    }

    private nonisolated static let sources: [String: String] = [
        "telegram": "Telegram", "discord": "Discord", "slack": "Slack", "whatsapp": "WhatsApp", "signal": "Signal",
        "imessage": "iMessage", "sms": "SMS", "email": "Email", "matrix": "Matrix", "mattermost": "Mattermost",
        "teams": "Microsoft Teams", "cron": "Scheduled job", "cli": "Terminal", "oneshot": "One-off run",
        "subagent": "Subagent", "webhook": "Webhook", "api": "API", "api_server": "API", "tool": "Tool",
    ]
    /// Sources that are this app or the desktop app: no Source row.
    private nonisolated static let ownSources: Set<String> = ["desktop", "dispatch", "tui", "ios", "app", ""]

    /// Where a chat came from, when not this app ("Telegram", "Scheduled job"); "" for the app's own.
    nonisolated static func sourceName(_ source: String?) -> String {
        let key = (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ownSources.contains(key) { return "" }
        if let known = sources[key] { return known }
        let spaced = key.split(whereSeparator: { $0 == "-" || $0 == "_" }).joined(separator: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// "$0.34"; four decimals below a cent ("$0.0042"). Always a point.
    nonisolated static func cost(_ value: Double) -> String {
        "$" + String(format: value < 0.01 ? "%.4f" : "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func rows(_ source: SessionInfoSource, names: SessionInfoNames = SessionInfoNames()) -> [SessionInfoRow] {
        var rows: [SessionInfoRow] = []
        func text(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        func named(_ id: String, _ name: (String) -> String) -> String { text(name(id)) ?? id }
        let live = text(source.model)
        let asked = live ?? text(source.row?.model)
        // A fallback speaks for the chat until its model is changed to another one.
        var answeredBy: ModelFallback?
        if let fallback = source.answeredBy,
           live == nil || [fallback.primary, fallback.fallback].contains(where: { bareModel($0) == bareModel(live ?? "") }) {
            answeredBy = fallback
        }
        if let answeredBy {
            let reason = text(answeredBy.reason).map { " (\($0))" } ?? ""
            func unavailable(_ id: String) -> String { "\(id) is unavailable on the gateway\(reason)" }
            rows.append(SessionInfoRow(label: "Answered By", value: named(answeredBy.fallback, names.model),
                                       note: unavailable(named(answeredBy.primary, names.model)),
                                       copy: "Answered By: \(answeredBy.fallback) (\(unavailable(answeredBy.primary)))"))
        }
        if let asked {
            let label = answeredBy == nil ? "Model" : "Chat Model"
            let provider = text(source.provider)
            rows.append(SessionInfoRow(label: label, value: named(asked, names.model), note: provider.map { named($0, names.provider) },
                                       copy: "\(label): \(asked)\(provider.map { " (\($0))" } ?? "")"))
        }
        let reasoning = [text(source.reasoning), source.fast ? "Fast" : nil].compactMap { $0 }
        if !reasoning.isEmpty { rows.append(SessionInfoRow(label: "Reasoning", value: reasoning.joined(separator: " · "))) }
        rows += usageRows(source.usage, storedCost: source.row?.actualCostUsd ?? source.row?.estimatedCostUsd,
                          storedCostIsActual: source.row?.actualCostUsd != nil, price: source.price)
        if let messages = source.row?.messageCount, messages > 0 { rows.append(SessionInfoRow(label: "Messages", value: String(messages))) }
        if let folder = text(source.liveCwd) ?? text(source.row?.cwd) {
            rows.append(SessionInfoRow(label: "Folder", value: folder, note: text(source.liveBranch) ?? text(source.row?.gitBranch), mono: true))
        }
        if let profile = text(source.profile) {
            let shown = named(profile, names.profile)
            rows.append(SessionInfoRow(label: "Bot", value: shown, copy: shown == profile ? nil : "Bot: \(shown) (\(profile))"))
        }
        let origin = sourceName(text(source.row?.handoffPlatform) ?? source.row?.source)
        if !origin.isEmpty { rows.append(SessionInfoRow(label: "Source", value: origin)) }
        if let gateway = text(source.gateway) { rows.append(SessionInfoRow(label: "Gateway", value: gateway, note: text(source.gatewayNote))) }
        if let id = text(source.sessionId) { rows.append(SessionInfoRow(label: "Chat ID", value: id, mono: true, copiesValue: true)) }   // UX study #73: was "Session ID"
        return rows
    }

    /// The chat's usage (tester 2026-10-27, "neater and in the session details"): Context with what is left,
    /// Tokens, Cache, Speed and Cost, each only when the gateway sent its figure. Session Info and Usage & Limits'
    /// This Chat both show these. `storedCost`: the stored row's, when the live usage has none.
    nonisolated static func usageRows(_ usage: SessionUsage?, storedCost: Double? = nil, storedCostIsActual: Bool = false,
                                      price: String? = nil) -> [SessionInfoRow] {
        var rows: [SessionInfoRow] = []
        if let usage, let max = usage.contextMax, max > 0 {
            let used = Swift.min(usage.contextUsed ?? 0, max)
            let percent = usage.contextPercent ?? Double(used) / Double(max) * 100
            let shown = Int(Swift.max(0, Swift.min(100, percent.isFinite ? percent : 0)).rounded())
            var note = "\(count(used)) of \(count(max)) · \(count(max - used)) left"
            if let times = usage.compressions, times > 0 { note += " · compressed \(times)×" }
            rows.append(SessionInfoRow(label: "Context", value: "\(usage.contextEstimated == true ? "~" : "")\(shown)%",
                                       note: note, bar: Double(shown) / 100))
        }
        if let usage, let total = usage.total, total > 0 {
            // In: everything sent (cache reads included), so in + out add up to the total; an older gateway without
            // `prompt` gives the uncached input only.
            let sent = (usage.prompt ?? 0) > 0 ? usage.prompt! : usage.input ?? 0
            var parts: [String] = []
            if sent > 0 || (usage.output ?? 0) > 0 { parts.append("\(count(sent)) in · \(count(usage.output ?? 0)) out") }
            if let reasoning = usage.reasoning, reasoning > 0 { parts.append("\(count(reasoning)) reasoning") }
            rows.append(SessionInfoRow(label: "Tokens", value: count(total), note: parts.isEmpty ? nil : parts.joined(separator: " · ")))
        }
        if let usage, let hit = usage.cacheHitPercent, let sent = usage.prompt, sent > 0 {
            let shown = Int(hit.rounded())
            var parts = ["~\(count(Int((Double(sent) * hit / 100).rounded()))) from cache"]
            if let fresh = usage.input, fresh > 0 { parts.append("\(count(fresh)) new") }
            rows.append(SessionInfoRow(label: "Cache", value: "\(shown)%", note: parts.joined(separator: " · "), bar: Double(shown) / 100))
        }
        if let usage {
            let calls = usage.calls.flatMap { $0 > 0 ? ($0 == 1 ? "1 call" : "\($0) calls") : nil }
            let latency = usage.secondsPerCall.map { "\(decimal($0, places: 1)) s a call" }
            if let speed = usage.tokensPerSecond {
                let note = [latency, calls].compactMap { $0 }
                rows.append(SessionInfoRow(label: "Speed", value: "\(decimal(speed, places: speed < 10 ? 1 : 0)) tokens/s",
                                           note: note.isEmpty ? nil : note.joined(separator: " · ")))
            } else if let count = usage.calls, count > 0 {
                rows.append(SessionInfoRow(label: "Calls", value: String(count), note: latency))
            }
        }
        let live = usage?.costUsd
        if let cost = live ?? storedCost, cost.isFinite, cost > 0 {
            var parts: [String] = []
            if live == nil, !storedCostIsActual { parts.append("Estimated") }
            if let price = price?.trimmingCharacters(in: .whitespaces), !price.isEmpty {
                parts.append(price == ModelPricesModel.included ? "Included in your plan"
                             : price == "Free" ? "Free model" : "\(price) per 1M")
            }
            rows.append(SessionInfoRow(label: "Cost", value: self.cost(cost), note: parts.isEmpty ? nil : parts.joined(separator: " · ")))
        }
        return rows
    }

    /// "82", "1.2": a point, the places given, a trailing ".0" kept off.
    nonisolated static func decimal(_ value: Double, places: Int) -> String {
        var text = String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value)
        if places > 0, text.hasSuffix("." + String(repeating: "0", count: places)) { text.removeLast(places + 1) }
        return text
    }

    /// Copy Session Info: every row as `Label: value (note)`, the model, provider and profile by their raw ids.
    nonisolated static func copyText(_ rows: [SessionInfoRow]) -> String { rows.map(\.copyText).joined(separator: "\n") }

    /// The gateway link's words under its host (`S/phone-header-state.ts:83-92`).
    nonisolated static func gatewayNote(_ state: ConnectionState) -> String {
        switch state {
        case .ready: "Connected"
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .offline: "Offline"
        case .signedOut: "Signed Out"   // as the field, the status line and Settings say it
        }
    }

    /// The host as a browser's `URL.host` reads it: with the port when the address names one.
    nonisolated static func host(_ url: URL) -> String {
        guard let host = url.host(), !host.isEmpty else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

extension SessionInfoStoredRow {
    init(_ row: SidebarSessionRow) {
        self.init(model: row.model, cwd: row.cwd, gitBranch: row.gitBranch, actualCostUsd: row.actualCostUsd,
                  estimatedCostUsd: row.estimatedCostUsd, messageCount: row.messageCount, source: row.source,
                  handoffPlatform: row.handoffPlatform)
    }
}

// MARK: - The chat's side (§10.3)

extension LiveChatSession {
    /// Asked once when Session Info opens: `session.usage` with the runtime id and the profile only. 3 s; any error
    /// (an older Hermes without the call, offline, a chat not resumed yet) leaves what the sheet already has.
    /// Then, when that usage has no context yet, the gateway's estimate (`session.context_breakdown`).
    func refreshUsage() async {
        guard runtimeSessionId != nil else { return }
        if let answer = try? await sessionCall("session.usage", timeout: .seconds(3), runtime: .required, params: { _ in [:] }),
           let usage = SessionUsage.decode(answer["usage"] ?? answer) {
            AppLog.trace("menus", "usage \(logIds): read, context max \(usage.contextMax ?? 0)")
            menus.usage = usage
        } else {
            AppLog.trace("menus", "usage \(logIds): no answer, sheet keeps what it had")
        }
        await refreshContextEstimate()
    }

    /// The gateway's status line: a fallback answered ("Answered By"), or the primary model is back.
    func noteModelFallback(_ p: JSONValue) {
        guard let text = p["text"]?.string else { return }
        if ModelFallback.restores(text) {
            if menus.answeredBy != nil { AppLog.trace("menus", "model fallback over in \(logIds): primary model back") }
            menus.answeredBy = nil
        } else if let fallback = ModelFallback.parse(text) {
            AppLog.trace("menus", "model fallback in \(logIds): answered by another model")
            menus.answeredBy = fallback
        }
    }
}

extension SessionStore {
    /// The chat's row in the Archived view's rows, when they are loaded.
    func archivedRow(id: String, profile: String) -> SidebarSessionRow? {
        archivedRows.first { $0.id == id && $0.profile == profile }
    }

    /// A chat's stored row read once by id (a chat the loaded lists do not hold: opened from a notification, a search
    /// hit outside the page). nil when the gateway does not answer with one.
    func fetchRow(id: String, profile: String) async -> SidebarSessionRow? {
        guard let data = try? await client.rest("GET", Self.path(id), query: [URLQueryItem(name: "profile", value: profile)], body: nil),
              let json = try? JSONValue.parse(data) else { return nil }
        let row = json["session"] ?? json
        guard var made = SidebarSessionRow(json: row) else { return nil }
        if made.profile.isEmpty { made.profile = profile }
        return made
    }
}
