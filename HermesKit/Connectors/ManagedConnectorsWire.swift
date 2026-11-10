// Managed apps: the apps a bot reaches through its Nous account (the Hermes desktop app's Connectors page, hosted
// half). Wire shapes are `tui_gateway/contracts/connectors.py` and `connectors_operation.py`; the joins and the
// state words are ports of the desktop's `capabilities/connectors/data/join.ts` and `derive.ts`. No UIKit here.

import Foundation

// MARK: - Errors

/// `ConnectorErrorReason`: the gateway puts one in `error.data.reason` on every connector refusal.
nonisolated enum ConnectorErrorReason: String, CaseIterable, Sendable {
    case invalidParams = "INVALID_PARAMS"
    case notOwner = "NOT_OWNER"
    case unsupportedRuntime = "UNSUPPORTED_RUNTIME"
    case connectorRequestFailed = "CONNECTOR_REQUEST_FAILED"
    case invalidConnectorResponse = "INVALID_CONNECTOR_RESPONSE"
    case unknownTarget = "UNKNOWN_TARGET"
    case linkStillValid = "LINK_STILL_VALID"
    case reissueRefused = "REISSUE_REFUSED"
    case unknownOperation = "UNKNOWN_OPERATION"
    case invalidAnswer = "INVALID_ANSWER"
    case needsNousAuth = "NEEDS_NOUS_AUTH"
    case connectorNotFound = "CONNECTOR_NOT_FOUND"
    case toolsUnavailable = "TOOLS_UNAVAILABLE"
    case connectorsUnavailable = "CONNECTORS_UNAVAILABLE"
    case catalogUnavailable = "CATALOG_UNAVAILABLE"
    case accountsUnavailable = "ACCOUNTS_UNAVAILABLE"
    case connectionNotFound = "CONNECTION_NOT_FOUND"
    case policyUnavailable = "POLICY_UNAVAILABLE"
    case policyConflict = "POLICY_CONFLICT"
    case forbiddenScope = "FORBIDDEN_SCOPE"
    case orgRequired = "ORG_REQUIRED"
    case orgAccessDenied = "ORG_ACCESS_DENIED"
    case invalidPolicy = "INVALID_POLICY"
    case aliasTaken = "ALIAS_TAKEN"

    /// The plain sentence for this refusal. Every reason has one; none names a code.
    var words: String {
        switch self {
        case .invalidParams: "Hermes didn’t accept this request. Update Hermes, then try again."
        case .notOwner: "This can only be changed from the place it was started."
        case .unsupportedRuntime: "This bot’s apps are managed on the computer it runs on."
        case .connectorRequestFailed: "The connector service didn’t answer. Try again."
        case .invalidConnectorResponse: "The connector service sent an answer Hermes couldn’t read. Try again later."
        case .unknownTarget: "That sign-in is no longer open. Connect again."
        case .linkStillValid: "The sign-in link is still open. Finish the sign-in in your browser, or open the link again."
        case .reissueRefused: "This sign-in can’t be started again. Close it, then connect again."
        case .unknownOperation: "That sign-in has already ended."
        case .invalidAnswer: "That answer wasn’t accepted. Try again."
        case .needsNousAuth: "Sign in to Nous to use managed apps."
        case .connectorNotFound: "This app is no longer in the catalog."
        case .toolsUnavailable: "Tool list unavailable."
        case .connectorsUnavailable: "Managed apps are not available for this account yet."
        case .catalogUnavailable: "The app catalog is unavailable right now. Try again later."
        case .accountsUnavailable: "Nous could not reach your connected accounts right now. Try again later."
        case .connectionNotFound: "That sign-in was already removed."
        case .policyUnavailable: "Rules cannot be changed right now."
        case .policyConflict: "Someone changed this rule while you were editing."
        case .forbiddenScope: "This account isn’t allowed to change connector rules."
        case .orgRequired: "Select an organization in Nous to manage connector rules."
        case .orgAccessDenied: "This account cannot manage connectors for this organization."
        case .invalidPolicy: "That change isn’t allowed by your connector rules."
        case .aliasTaken: AccountWords.aliasTaken
        }
    }
}

/// A connector call that failed, read once from whatever was thrown.
nonisolated struct ConnectorFailure: Error, Sendable, Equatable {
    var reason: ConnectorErrorReason?
    var code: Int?
    var message: String
    /// The gateway does not know the method (a Hermes from before managed apps).
    var tooOld: Bool { code == -32601 || message.lowercased().contains("unknown method") || message.lowercased().contains("method not found") }

    init(reason: ConnectorErrorReason?, code: Int?, message: String) {
        self.reason = reason; self.code = code; self.message = message
    }

    init(_ error: Error) {
        if let failure = error as? ConnectorFailure { self = failure; return }
        if let rpc = error as? RPCError {
            let raw = rpc.data?["reason"]?.string ?? ""
            self.init(reason: ConnectorErrorReason(rawValue: raw), code: rpc.code, message: rpc.message)
            return
        }
        self.init(reason: nil, code: nil, message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
    }

    static var tooOldWords: String { "This gateway’s Hermes doesn’t have managed apps yet. Update Hermes on \(HostWord.updateTarget) to use them." }

    /// What the person reads. `fallback` is the sentence for a failure with no reason (a dropped link, a timeout).
    func words(fallback: String = "Something went wrong. Try again.") -> String {
        if let reason { return reason.words }
        if tooOld { return Self.tooOldWords }
        if let code {
            let rpc = RPCError(code: code, message: message, data: nil)
            if rpc.isTimeout || rpc.isConnectionLost || rpc.isNotConnected { return "Can’t reach your gateway right now. Try again when it’s back." }
        }
        return fallback
    }
}

// MARK: - Rows

nonisolated struct ConnectorListRow: Sendable, Equatable {
    var connector: String
    var enabled: Bool
    var connected: Bool
    var connectionStatus: String?
    var statusReason: String?
    var gatewayDisabledTools: [String]
}

nonisolated struct ConnectorListResult: Sendable, Equatable {
    var available: Bool
    var connectors: [ConnectorListRow]
}

nonisolated struct ConnectorCatalogRow: Sendable, Equatable, Identifiable {
    var slug: String
    var name: String
    var description: String
    var category: String
    var logoURL: String?
    var id: String { slug }
}

nonisolated struct ConnectorAccountRow: Sendable, Equatable, Identifiable {
    var connectionId: String
    var connector: String
    var status: String
    var statusReason: String?
    var label: String
    var alias: String?
    var active: Bool
    var createdAt: String
    var updatedAt: String
    /// Retired by a reconnect that replaced it: kept, never used (`isRetired`).
    var disabled: Bool = false
    var id: String { connectionId }
    /// `accountName`: the name the person gave it, else the account the app reports.
    var name: String { alias ?? label }
    /// The status a reconnect repairs (`STATUS_VIEW`); `pending` waits for a sign-in and `active` needs nothing.
    var needsReconnect: Bool { ["expired", "failed", "inactive", "revoked"].contains(status) }
    /// The status badge (`accounts.status`), nil while active.
    var statusWords: String? {
        if disabled { return "Replaced by a reconnect" }
        switch status {
        case "active": return nil
        case "expired": return "Access expired"
        case "failed": return "Couldn’t connect"
        case "inactive": return "Inactive"
        case "pending": return "Waiting for sign-in"
        case "revoked": return "Access revoked"
        default: return status.capitalized
        }
    }

    /// The gateway's account-name format (`ConnectorAlias`): lowercase letters, numbers and dashes, up to 32.
    nonisolated static func aliasValid(_ alias: String) -> Bool {
        alias.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,31}/) != nil
    }

    /// `aliasProblem`: why `alias` cannot name an account among `accounts` (the words), or nil. `self` is the one renamed.
    nonisolated static func aliasProblem(_ alias: String, among accounts: [ConnectorAccountRow], renaming id: String? = nil) -> String? {
        guard aliasValid(alias) else { return AccountWords.aliasInvalid }
        return accounts.contains { $0.alias == alias && $0.connectionId != id } ? AccountWords.aliasTaken : nil
    }
}

/// The desktop's words for named accounts (`en_connector_accounts.ts`), in the app's Title Case on buttons.
nonisolated enum AccountWords {
    static let aliasHint = "Lowercase letters, numbers and dashes, up to 32. For example work or home."
    static let aliasInvalid = "Use lowercase letters, numbers and dashes, starting with a letter or number."
    static let aliasTaken = "That name is already used."
    static let renameGone = "That account is no longer there. It was removed or replaced by a reconnect."
    static let removeBody = "Hermes stops acting as this account. Your other accounts stay connected."
    static func removeTitle(app: String, name: String) -> String { "Remove the \(name) \(app) account?" }
    static func retired(_ count: Int) -> String { "\(count) retired" }

    /// A refused rename or add, in words (`refusal`): a taken name, a bad name, a gone account, else the reason's words.
    static func refusal(_ failure: ConnectorFailure) -> String {
        switch failure.reason {
        case .invalidParams: return aliasInvalid
        case .connectionNotFound: return renameGone
        default: return failure.words(fallback: "That change was not saved.")
        }
    }
}

nonisolated struct ConnectorTool: Sendable, Equatable, Identifiable {
    var slug: String
    var name: String
    var description: String
    var facet: String
    var hints: [String]
    var categories: [String]
    var deprecated: Bool
    var id: String { slug }
}

nonisolated struct ConnectorToolsResult: Sendable, Equatable {
    var connector: String
    var stale: Bool
    var tools: [ConnectorTool]
}

// MARK: - Policy

nonisolated struct ConnectorPolicyRules: Sendable, Equatable {
    /// nil = every app allowed (unrestricted / deny mode); an empty set = none (deny-all).
    var allowed: Set<String>?
    var denied: Set<String>
    var revision: String
    var tagsEnable: [String]
    var tagsDisable: [String]
    var tools: [String: [String]]

    func allows(_ slug: String) -> Bool { (allowed == nil || allowed!.contains(slug)) && !denied.contains(slug) }
}

nonisolated struct ConnectorPolicyView: Sendable, Equatable {
    var member: ConnectorPolicyRules?
    var others: [ConnectorPolicyRules]

    static let empty = ConnectorPolicyView(member: nil, others: [])

    func memberEnables(_ slug: String) -> Bool { member?.allows(slug) ?? true }
    func orgLocks(_ slug: String) -> Bool { others.contains { !$0.allows(slug) } }
    func memberDisabledTools(_ slug: String) -> [String] { member?.tools[slug] ?? [] }
    var memberRevision: String? { member?.revision }

    /// Tools the organisation (or a role) turned off, by list or by hint tag; the member cannot turn them on.
    func orgLockedTools(_ slug: String, tools: [ConnectorTool]) -> Set<String> {
        var locked = Set<String>()
        for rules in others {
            locked.formUnion(rules.tools[slug] ?? [])
            for tool in tools {
                let hints = Set(tool.hints)
                let disabledByTag = rules.tagsDisable.contains { hints.contains($0) }
                let missingEnabled = !rules.tagsEnable.isEmpty && !rules.tagsEnable.contains { hints.contains($0) }
                if disabledByTag || missingEnabled { locked.insert(tool.slug) }
            }
        }
        return locked
    }
}

// MARK: - Connection operation

nonisolated enum ConnectionTargetState: String, Sendable {
    case pending, initiated, connected, skipped, failed, expired
    case notConnected = "not_connected"
}

nonisolated struct ConnectionTarget: Sendable, Equatable {
    var name: String
    var state: ConnectionTargetState
    var detail: String
    var connectURL: String?
    var connectionId: String
}

nonisolated struct ConnectionOperation: Sendable, Equatable {
    var opId: String
    var connectors: [String]
    var seq: Int
    var deadlineAt: Double
    var settled: Bool
    var settledBy: String?
    var targets: [ConnectionTarget]

    func target(_ slug: String) -> ConnectionTarget? { targets.first { $0.name == slug } }
    var link: String? { targets.first { $0.connectURL != nil }?.connectURL }
    /// Still asks something of the person: open, or settled without every app connected.
    var stillOpen: Bool { !settled || !targets.allSatisfy { $0.state == .connected } }

    /// `applySnapshot` (account-operations.ts): a broadcast must be newer than what is held, a reply at least as new.
    /// A broadcast never carries the link or the account id, so those are kept from the held row unless the row was
    /// re-issued (it moved to `initiated` again: the old link is dead). A row that left `initiated` has no live link.
    func applying(_ snapshot: ConnectionOperation, broadcast: Bool) -> ConnectionOperation? {
        guard snapshot.opId == opId, broadcast ? snapshot.seq > seq : snapshot.seq >= seq else { return nil }
        var next = self
        next.seq = snapshot.seq
        next.deadlineAt = snapshot.deadlineAt
        next.settled = snapshot.settled
        next.settledBy = snapshot.settledBy
        next.targets = snapshot.targets.map { target in
            guard let held = targets.first(where: { $0.name == target.name }) else { return target }
            var row = target
            let reissued = target.state == .initiated && held.state != .initiated
            if row.connectURL == nil, !reissued, target.state == .initiated { row.connectURL = held.connectURL }
            if row.connectionId.isEmpty { row.connectionId = held.connectionId }
            return row
        }
        return next
    }
}

// MARK: - Decoding

nonisolated enum ManagedWire {
    static func text(_ value: JSONValue?) -> String? {
        guard let s = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func list(_ value: JSONValue) -> ConnectorListResult {
        let rows = (value["connectors"]?.array ?? []).compactMap { row -> ConnectorListRow? in
            guard let slug = text(row["connector"]) else { return nil }
            return ConnectorListRow(connector: slug, enabled: row["enabled"]?.bool ?? true, connected: row["connected"]?.bool ?? false,
                                    connectionStatus: text(row["connection_status"]), statusReason: text(row["status_reason"]),
                                    gatewayDisabledTools: (row["gateway_disabled_tools"]?.array ?? []).compactMap { text($0) })
        }
        return ConnectorListResult(available: value["available"]?.bool ?? !rows.isEmpty, connectors: rows)
    }

    static func catalog(_ value: JSONValue) -> [ConnectorCatalogRow] {
        var seen = Set<String>()
        return (value["connectors"]?.array ?? []).compactMap { row in
            guard let slug = text(row["slug"]), seen.insert(slug).inserted else { return nil }
            return ConnectorCatalogRow(slug: slug, name: text(row["name"]) ?? ManagedWire.title(slug), description: text(row["description"]) ?? "",
                                       category: text(row["category"]) ?? "", logoURL: text(row["logo_url"]))
        }
    }

    static func accounts(_ value: JSONValue) -> [ConnectorAccountRow] {
        (value["accounts"]?.array ?? []).compactMap { row in
            guard let id = text(row["connection_id"]), let connector = text(row["connector"]) else { return nil }
            return ConnectorAccountRow(connectionId: id, connector: connector, status: text(row["status"]) ?? "active",
                                       statusReason: text(row["status_reason"]), label: text(row["label"]) ?? "", alias: text(row["alias"]),
                                       active: row["active"]?.bool ?? false, createdAt: text(row["created_at"]) ?? "",
                                       updatedAt: text(row["updated_at"]) ?? "", disabled: row["disabled"]?.bool ?? false)
        }
    }

    /// The gateway names accounts (rename, add another, connect by name): its rows carry the `alias` key, even when
    /// null. A Hermes from before account names sends no such key. Nil when there is no row to tell by.
    static func accountsNamed(_ value: JSONValue) -> Bool? {
        guard let rows = value["accounts"]?.array, let first = rows.first?.object else { return nil }
        return first["alias"] != nil
    }

    static func tools(_ value: JSONValue) -> ConnectorToolsResult {
        let tools = (value["tools"]?.array ?? []).compactMap { row -> ConnectorTool? in
            guard let slug = text(row["slug"]) else { return nil }
            return ConnectorTool(slug: slug, name: text(row["name"]) ?? slug, description: text(row["description"]) ?? "",
                                 facet: text(row["facet"]) ?? "unclassified", hints: (row["hints"]?.array ?? []).compactMap { text($0) },
                                 categories: (row["categories"]?.array ?? []).compactMap { text($0) }, deprecated: row["deprecated"]?.bool ?? false)
        }
        return ConnectorToolsResult(connector: text(value["connector"]) ?? "", stale: value["stale"]?.bool ?? false, tools: tools)
    }

    /// `readPolicy` (join.ts): the member layer is what this person may change; every other layer locks.
    static func policy(_ value: JSONValue) -> ConnectorPolicyView {
        let layers = value["layers"]?.array ?? []
        let member = layers.first { $0["kind"]?.string == "member" }.map(rules)
        let others = layers.filter { $0["kind"]?.string != "member" }.map(rules)
        return ConnectorPolicyView(member: member, others: others)
    }

    static func rules(_ layer: JSONValue) -> ConnectorPolicyRules {
        let body = layer["body"] ?? .null
        let revision = text(layer["revision"]) ?? ""
        let strings: (JSONValue?) -> [String] = { ($0?.array ?? []).compactMap { text($0) } }
        var tools: [String: [String]] = [:]
        for (slug, list) in body["tools"]?.object ?? [:] { tools[slug] = strings(list) }
        let enable = strings(body["tags"]?["enable"]), disable = strings(body["tags"]?["disable"])
        switch body["mode"]?.string {
        case "deny-all":
            return ConnectorPolicyRules(allowed: [], denied: [], revision: revision, tagsEnable: [], tagsDisable: [], tools: [:])
        case "allow":
            return ConnectorPolicyRules(allowed: Set(strings(body["connectors"])), denied: [], revision: revision, tagsEnable: enable,
                                        tagsDisable: disable, tools: tools)
        case "deny":
            return ConnectorPolicyRules(allowed: nil, denied: Set(strings(body["disabled_connectors"])), revision: revision, tagsEnable: enable,
                                        tagsDisable: disable, tools: tools)
        default:
            return ConnectorPolicyRules(allowed: nil, denied: [], revision: revision, tagsEnable: [], tagsDisable: [], tools: [:])
        }
    }

    /// `connectors.connect` / `connectors.operation.status` / a `connection.update` payload.
    static func operation(_ value: JSONValue, connectors: [String] = []) -> ConnectionOperation? {
        guard let opId = text(value["op_id"]) else { return nil }
        let targets = (value["targets"]?.array ?? []).compactMap { row -> ConnectionTarget? in
            guard let name = text(row["name"]) else { return nil }
            return ConnectionTarget(name: name, state: ConnectionTargetState(rawValue: text(row["state"]) ?? "") ?? .pending,
                                    detail: text(row["detail"]) ?? "", connectURL: text(row["connect_url"]),
                                    connectionId: text(row["connection_id"]) ?? "")
        }
        return ConnectionOperation(opId: opId, connectors: connectors.isEmpty ? targets.map(\.name) : connectors, seq: value["seq"]?.int ?? 0,
                                   deadlineAt: value["deadline_at"]?.double ?? 0,
                                   settled: value["settled"]?.bool ?? (value["settled_at"].map { !$0.isNull } ?? false),
                                   settledBy: text(value["settled_by"]), targets: targets)
    }

    /// `connectorTitle`: "google_calendar" → "Google Calendar".
    static func title(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
