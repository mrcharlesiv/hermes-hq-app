// Connectors that need the owner (docs/spec/3x-capabilities.md §8.1): a server that keeps failing or needs a new
// sign-in. Kept 24 h per account so the More badge survives a relaunch; a failed read never creates or clears one.

import Foundation
import Observation

nonisolated struct ServerIssue: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case error, needsAuth = "needs-auth" }
    let profile: String
    let name: String
    let kind: Kind
    let seenAt: Date
    /// [13-3] The newest read that still found it (moved on at most hourly, so a sweep doesn't rewrite the set each time):
    /// the 24 h is counted from here. Counted from `seenAt`, a connector broken for over a day lost its badge while
    /// still broken. Nil in sets saved before it (then `seenAt`).
    var confirmedAt: Date? = nil

    /// What the 24 h lifetime is counted from.
    var lastSeen: Date { max(seenAt, confirmedAt ?? seenAt) }

    /// Still there on a read at `time`.
    func confirmed(at time: Date) -> ServerIssue {
        guard time.timeIntervalSince(lastSeen) >= ServerIssues.confirmStep else { return self }
        var copy = self
        copy.confirmedAt = time
        return copy
    }
}

@MainActor @Observable final class ServerIssues {
    static let shared = ServerIssues()
    static let didChange = Notification.Name("capabilities.serverIssues.didChange")
    static let lifetime: TimeInterval = 24 * 3600
    static let debounce: TimeInterval = 10
    nonisolated static let confirmStep: TimeInterval = 3600

    private var stored: [ServerIssue] = []
    @ObservationIgnored private var firstFailure: [String: Date] = [:]
    @ObservationIgnored private var account = ""
    @ObservationIgnored var defaults: UserDefaults = .standard
    @ObservationIgnored var now: () -> Date = { Date() }

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    /// Newest first, expired ones dropped.
    var issues: [ServerIssue] {
        let cutoff = now().addingTimeInterval(-Self.lifetime)
        return stored.filter { $0.lastSeen > cutoff }.sorted { $0.seenAt > $1.seenAt }
    }
    var count: Int { issues.count }

    var summary: String? {
        let live = issues
        guard let first = live.first else { return nil }
        if live.count > 1 { return "\(live.count) connectors need attention" }
        let title = ConnectorTitle.title(for: first.name)
        return first.kind == .needsAuth ? "\(title) needs you to sign in again" : "\(title) is unreachable"
    }

    private func key(_ account: String) -> String { "capabilities.serverIssues.\(account)" }

    /// Switching gateway swaps the set; "" (signed out) shows none.
    func use(account: String) {
        guard account != self.account else { return }
        self.account = account
        firstFailure = [:]
        var loaded: [ServerIssue] = []
        if !account.isEmpty, let data = defaults.data(forKey: key(account)), let decoded = try? JSONDecoder().decode([ServerIssue].self, from: data) {
            let cutoff = now().addingTimeInterval(-Self.lifetime)
            loaded = decoded.filter { $0.lastSeen > cutoff }
        }
        set(loaded)
    }

    /// Signing out of an account forgets its issues.
    func signOut(account: String) {
        defaults.removeObject(forKey: key(account))
        if account == self.account { firstFailure = [:]; set([]) }
    }

    static func kind(of server: McpServer) -> ServerIssue.Kind? {
        guard server.enabled else { return nil }
        if server.auth == "oauth", server.oauthTokensPresent == false { return .needsAuth }
        if server.status == "failed" { return .error }
        return nil
    }

    /// One successful read of a bot's servers: replaces that bot's issues.
    func report(profile: String, servers: [McpServer]) {
        let time = now()
        var next = issues.filter { $0.profile != profile }
        let old = Dictionary(uniqueKeysWithValues: stored.filter { $0.profile == profile }.map { ($0.name, $0) })
        var failing: Set<String> = []
        for server in servers {
            guard let kind = Self.kind(of: server) else { continue }
            let id = "\(profile)::\(server.name)"
            if kind == .error {
                failing.insert(id)
                if let was = old[server.name], was.kind == .error { next.append(was.confirmed(at: time)); continue }
                guard let first = firstFailure[id] else { firstFailure[id] = time; continue }
                // A gateway that has just restarted reports everything failed for a moment.
                guard time.timeIntervalSince(first) >= Self.debounce else { continue }
            }
            if let was = old[server.name], was.kind == kind { next.append(was.confirmed(at: time)) }
            else { next.append(ServerIssue(profile: profile, name: server.name, kind: kind, seenAt: time)) }
        }
        for id in firstFailure.keys where id.hasPrefix("\(profile)::") && !failing.contains(id) { firstFailure[id] = nil }
        set(next)
    }

    func clear(profile: String, name: String) {
        firstFailure["\(profile)::\(name)"] = nil
        set(issues.filter { !($0.profile == profile && $0.name == name) })
    }

    /// The bot was deleted.
    func forget(profile: String) {
        for id in firstFailure.keys where id.hasPrefix("\(profile)::") { firstFailure[id] = nil }
        set(issues.filter { $0.profile != profile })
    }

    private func set(_ next: [ServerIssue]) {
        let sorted = next.sorted { $0.seenAt > $1.seenAt }
        guard sorted != stored else { return }
        stored = sorted
        if !account.isEmpty {
            if sorted.isEmpty { defaults.removeObject(forKey: key(account)) }
            else if let data = try? JSONEncoder().encode(sorted) { defaults.set(data, forKey: key(account)) }
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
