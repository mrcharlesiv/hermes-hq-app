// Feeding `ServerIssues` from every bot (docs/spec/3x-capabilities.md §8.2), and what the More row says and opens
// (§8.3, §8.5).

import UIKit

@MainActor final class ServerIssueSweep {
    static let shared = ServerIssueSweep()
    /// DECISION 8.2-a: at most 30 bots per sweep.
    static let limit = 30

    private weak var model: AppModel?
    private weak var store: CapabilitiesStore?
    private var task: Task<Void, Never>?
    private var lastSweep: Date?
    private var linkTimer: Task<Void, Never>?
    private var wasConnected = false
    private var rosterCount = -1
    /// [perf] The app went to the background since the last ready tick: the link-up that follows (every background
    /// pauses the link) is the foreground rule's, sweeping only when the last sweep is 10 min old (§8.2).
    private var resumedFromBackground = false

    /// A new gateway is in use: sweep when its link comes up, and again when the roster changes.
    func start(model: AppModel, store: CapabilitiesStore) {
        task?.cancel(); task = nil
        self.model = model
        self.store = store
        lastSweep = nil
        wasConnected = false
        rosterCount = -1
        resumedFromBackground = false
        linkTimer?.cancel()
        // [offline] §6.9 via 3x §17.4: the watch slows three times in Low Power Mode or when the phone is hot.
        linkTimer = PowerPolls.loop(every: .seconds(2), floor: .zero) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard let model else { linkTimer?.cancel(); linkTimer = nil; return }
        let connected = model.connection == .ready
        let count = model.bots.count
        defer { wasConnected = connected; rosterCount = count }
        guard connected, UIApplication.shared.applicationState == .active else { return }
        // The roster is in: link-up, a roster change, or a second read ≥ 10 s after the first so a failure that
        // lasts becomes an issue (the debounce needs two reads).
        let due = Self.isDue(wasConnected: wasConnected, rosterChanged: rosterCount >= 0 && rosterCount != count, lastSweep: lastSweep,
                             secondPass: secondPass, resumed: resumedFromBackground)
        resumedFromBackground = false
        if due, count > 0 { sweep() }
    }

    /// Link-up (a first connect, or a drop while in the foreground), a roster change, no sweep yet, or the second read.
    /// A link-up after a return from the background only when the last sweep is 10 min old.
    static func isDue(wasConnected: Bool, rosterChanged: Bool, lastSweep: Date?, secondPass: Bool, resumed: Bool, now: Date = Date()) -> Bool {
        let stale = lastSweep.map { now.timeIntervalSince($0) >= 600 } ?? true
        return (!wasConnected && (!resumed || stale)) || rosterChanged || lastSweep == nil
            || (secondPass && now.timeIntervalSince(lastSweep ?? .distantPast) >= ServerIssues.debounce + 2)
    }

    private var secondPass = false

    func appActive(_ active: Bool) {
        guard active else { resumedFromBackground = true; task?.cancel(); task = nil; return }
        if let lastSweep, Date().timeIntervalSince(lastSweep) < 600 { return }
        if model?.connection == .ready { sweep() }
    }

    static func order(_ bots: [Bot]) -> [String] {
        var ids = bots.map(\.id)
        if let index = ids.firstIndex(of: "default") { ids.remove(at: index); ids.insert("default", at: 0) }
        return Array(ids.prefix(limit))
    }

    /// One bot's servers with their live status; nil when either read failed.
    private static func read(_ profile: String, store: CapabilitiesStore) async -> [McpServer]? {
        // [offline] §6.2: one quick retry, none while the gateway cannot be reached.
        guard var list = try? await QueryRetry.read({ try await store.mcpServers(profile) }),
              let status = try? await QueryRetry.read({ try await store.mcpStatus(profile) }) else { return nil }
        for i in list.indices {
            if let row = status[list[i].name] { list[i].status = row.status; list[i].tools = row.tools }
        }
        return list
    }

    func sweep() {
        guard task == nil, let model, let store else { return }
        let profiles = Self.order(model.bots)
        guard !profiles.isEmpty else { return }
        let first = lastSweep == nil
        lastSweep = Date()
        let start = ContinuousClock.now
        AppLog.trace("connect", "server issue sweep started for \(profiles.count) bot(s)")
        task = Task { [weak self] in
            var sawFailure = false
            var read = 0, failedReads = 0
            // Two bots at a time; a failed read never creates or clears an issue.
            var index = 0
            while index < profiles.count, !Task.isCancelled {
                let pair = Array(profiles[index..<min(index + 2, profiles.count)])
                index += 2
                async let first = Self.read(pair[0], store: store)
                async let second = pair.count > 1 ? Self.read(pair[1], store: store) : nil
                let results = [(pair[0], await first), (pair.count > 1 ? pair[1] : "", await second)]
                for (profile, list) in results {
                    guard !profile.isEmpty, !Task.isCancelled else { continue }
                    guard let list else { failedReads += 1; continue }
                    read += 1
                    if list.contains(where: { $0.enabled && $0.status == "failed" }) { sawFailure = true }
                    ServerIssues.shared.report(profile: profile, servers: list)
                }
            }
            guard let self else { return }
            self.task = nil
            // A failure seen once is read again after the debounce; a second pass does not ask for a third.
            self.secondPass = first && sawFailure
            if !first { self.secondPass = false }
            AppLog.trace("connect", "server issue sweep finished in \(AppLog.ms(since: start)) ms: \(read) read, \(failedReads) failed, issues=\(ServerIssues.shared.count)")
        }
    }
}

@MainActor enum CapabilitiesIssues {
    /// "1 Issue" / "2 Issues" in red, spoken as the summary ("Capabilities, GitHub is unreachable").
    static func moreStatus() -> MoreRowStatus? {
        let issues = ServerIssues.shared
        let count = issues.count
        guard count > 0, let summary = issues.summary else { return nil }
        return MoreRowStatus(text: count == 1 ? "1 Issue" : "\(count) Issues", isIssue: true, spoken: summary)
    }
}
