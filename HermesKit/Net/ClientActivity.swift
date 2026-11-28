// Hermes Agent v0.23.4+ client identity & activity protocol (CanonicalClientIdentity, ClientActivityParams).
// Identity is sent as a separate `client.capabilities {client}` call right after `server_requests` so older gateways
// that refuse the unknown field keep `server_requests` working. Activity is sent only when the gateway answered
// `client_activity: true` on `client.capabilities`.

import Foundation

/// A client naming itself in `client.capabilities` (`CanonicalClientIdentity`).
nonisolated struct ClientIdentity: Sendable, Equatable {
    var name: String
    var kind: String
    var version: String?

    /// Validated against upstream rules: `name` matches `[a-z0-9][a-z0-9._-]{0,63}`, `version` is 1..64 printable
    /// ASCII characters without spaces, `kind` is 1..32 characters (`desktop` / `mobile`).
    static func current(bundle: Bundle = .main) -> ClientIdentity {
        #if targetEnvironment(macCatalyst)
        let name = "hermes-hq-mac"
        let kind = "desktop"
        #else
        let name = "hermes-hq-ios"
        let kind = "mobile"
        #endif
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let rawVersion: String? = switch (short?.trimmingCharacters(in: .whitespacesAndNewlines),
                                          build?.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case let (s?, b?) where !s.isEmpty && !b.isEmpty: "\(s)+\(b)"
        case let (s?, _) where !s.isEmpty: s
        case let (_, b?) where !b.isEmpty: b
        default: nil
        }
        return ClientIdentity(name: name, kind: kind, version: rawVersion.flatMap(sanitizedVersion))
    }

    static func sanitizedVersion(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else { return nil }
        return trimmed
    }

    var json: JSONValue {
        var obj: [String: JSONValue] = [
            "name": .string(name),
            "kind": .string(kind),
        ]
        if let version { obj["version"] = .string(version) }
        return .object(obj)
    }
}

/// One `client.activity` report (`ClientActivityParams`).
nonisolated struct ClientActivityReport: Sendable, Equatable {
    enum Basis: String, Sendable, Equatable { case system, page }

    var sessions: [String]
    var idleSeconds: Double
    var basis: Basis
    var canAlert: Bool = true
    var away: Bool = false

    var json: JSONValue {
        let bounded = Array(sessions.filter { !$0.isEmpty && $0.count <= 256 }.prefix(16))
        return .object([
            "sessions": .array(bounded.map(JSONValue.string)),
            "idle_seconds": .number(max(0, idleSeconds)),
            "basis": .string(basis.rawValue),
            "can_alert": .bool(canAlert),
            "away": .bool(away),
        ])
    }
}

/// Per-connection aggregator for `client.activity` reports (`ClientActivityParams`).
/// Tracks every visible chat pane on one shared gateway socket so closing one pane never wipes another
/// or marks the connection `away`, and computes `idle_seconds` from real user input.
nonisolated struct ClientActivityAggregator: Sendable {
    private var entries: [(token: UUID, sessionId: String)] = []
    private var lastInput: ContinuousClock.Instant
    private(set) var isAway = false

    init(now: ContinuousClock.Instant = .now) {
        self.lastInput = now
    }

    var sessions: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries where !entry.sessionId.isEmpty && entry.sessionId.count <= 256 {
            if seen.insert(entry.sessionId).inserted {
                out.append(entry.sessionId)
                if out.count == 16 { break }
            }
        }
        return out
    }

    mutating func setSession(_ sessionId: String?, token: UUID, now: ContinuousClock.Instant = .now) {
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.removeAll { $0.token == token }
        if let trimmed, !trimmed.isEmpty {
            entries.append((token, trimmed))
            lastInput = now
        }
    }

    mutating func noteInput(now: ContinuousClock.Instant = .now) {
        lastInput = now
    }

    mutating func setAway(_ away: Bool, now: ContinuousClock.Instant = .now) {
        isAway = away
        if !away { lastInput = now }
    }

    func report(now: ContinuousClock.Instant = .now) -> ClientActivityReport {
        if isAway {
            return ClientActivityReport(sessions: [], idleSeconds: 0, basis: .page, canAlert: false, away: true)
        }
        let elapsed = lastInput.duration(to: now)
        let seconds = max(0, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        return ClientActivityReport(sessions: sessions, idleSeconds: seconds.rounded(), basis: .page, canAlert: true, away: false)
    }
}

/// Optional capability adopted by `LiveGatewayClient` for reporting user presence to v0.23.4+ gateways.
nonisolated protocol ClientActivityReporting: AnyObject, Sendable {
    var supportsClientActivity: Bool { get }
    func setVisibleActivitySession(_ sessionId: String?, token: UUID)
    func noteActivityInput()
    func reportClientActivity(_ report: ClientActivityReport) async
}

nonisolated extension ClientActivityReporting {
    func setVisibleActivitySession(_ sessionId: String?, token: UUID) {}
    func noteActivityInput() {}
}
