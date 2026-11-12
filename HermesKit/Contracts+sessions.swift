// [sessions-m9] Sessions: Filter & Sort, chips, the pending line, Session Info (docs/spec/3x-sessions.md §3).
// The choices a user makes in the Filter & Sort menu (kept per gateway account on the device), a chat's status, the
// row's pending line, and the usage and fallback a chat reports for Session Info. Pure values.

import Foundation

// MARK: - What the user chose (§3.2)

/// Sort By (`V/store/layout.ts` orderings). Manual is the order the user dragged the rows into (kept on the device,
/// `SessionsDeviceState.chatOrder`); a drag picks it, as on the desktop.
nonisolated enum SessionSortBy: String, Codable, CaseIterable, Sendable { case updated, created, status, tokens, cost, manual }

/// Group By. Bot (the web phone left it out, `S/ui-lists/filter-menu.ts:90-91`) asked for by a tester, 2026-10-29: one
/// group per bot, as the desktop's All Profiles grouping.
nonisolated enum SessionGroupBy: String, Codable, CaseIterable, Sendable { case date, project, bot, status }

/// Row Detail: what the row's trailing text and second line may show (`PHONE_ROW_DETAIL`). Menu order.
nonisolated enum SessionRowDetail: String, Codable, CaseIterable, Sendable { case time = "updated", preview, tokens, cost }

/// A chat's one status (`V/store/session-dot-state.ts:89-98`), in menu order and sort rank 0…4.
nonisolated enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case needsInput = "needs-input", working, unread, draft, idle

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 4 }
}

nonisolated struct SessionsViewPrefs: Codable, Hashable, Sendable {
    var sortBy: SessionSortBy = .updated
    var groupBy: SessionGroupBy = .date
    var rowDetail: Set<SessionRowDetail> = [.preview, .time]
    var statusFilter: Set<SessionStatus> = []
    /// Project keys (`SessionProjects.key`).
    var projectFilter: Set<String> = []
    var showArchived = false
    /// [sessions-fresh] Show › Bot Faces: the face on Pinned's and Recent's rows (the chips keep theirs).
    var botFaces = true
    /// Show › Project Chats in Recent: off lists under "Recent" only the chats outside every project (Home's); a
    /// project's chats then show on its card alone (tester, 2026-11-08: "hide it from Recent too").
    var projectChatsInRecent = true
    /// Row Detail › Preview under Group By Recent: one line of the last message under each Recent (and project card)
    /// chat's title. Its own setting, off by default, so the one-line Recent rows stay as they were; the other
    /// groupings keep `rowDetail`'s Preview (a tester, 2026-11-12: "toggling previews doesn't do anything").
    var recentPreview = false

    init() {}

    /// What the rows show: `rowDetail`, with Preview from `recentPreview` under Group By Recent.
    var shownDetail: Set<SessionRowDetail> {
        guard SessionListPipeline.isFresh(self) else { return rowDetail }
        return recentPreview ? rowDetail.union([.preview]) : rowDetail.subtracting([.preview])
    }

    private enum CodingKeys: String, CodingKey { case sortBy, groupBy, rowDetail, statusFilter, projectFilter, showArchived, botFaces, projectChatsInRecent, recentPreview }

    /// Lenient: a value this build does not know (a file from a newer one) reads as that field's default, never an error.
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        if let raw = try? c.decodeIfPresent(String.self, forKey: .sortBy), let value = SessionSortBy(rawValue: raw) { sortBy = value }
        if let raw = try? c.decodeIfPresent(String.self, forKey: .groupBy), let value = SessionGroupBy(rawValue: raw) { groupBy = value }
        if let raw = try? c.decodeIfPresent([String].self, forKey: .rowDetail) { rowDetail = Set(raw.compactMap(SessionRowDetail.init(rawValue:))) }
        if let raw = try? c.decodeIfPresent([String].self, forKey: .statusFilter) { statusFilter = Set(raw.compactMap(SessionStatus.init(rawValue:))) }
        if let raw = try? c.decodeIfPresent([String].self, forKey: .projectFilter) { projectFilter = Set(raw) }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: .showArchived) { showArchived = value }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: .botFaces) { botFaces = value }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: .projectChatsInRecent) { projectChatsInRecent = value }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: .recentPreview) { recentPreview = value }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sortBy.rawValue, forKey: .sortBy)
        try c.encode(groupBy.rawValue, forKey: .groupBy)
        try c.encode(SessionRowDetail.allCases.filter(rowDetail.contains).map(\.rawValue), forKey: .rowDetail)
        try c.encode(SessionStatus.allCases.filter(statusFilter.contains).map(\.rawValue), forKey: .statusFilter)
        try c.encode(projectFilter.sorted(), forKey: .projectFilter)
        try c.encode(showArchived, forKey: .showArchived)
        try c.encode(botFaces, forKey: .botFaces)
        try c.encode(projectChatsInRecent, forKey: .projectChatsInRecent)
        try c.encode(recentPreview, forKey: .recentPreview)
    }
}

// MARK: - The row's pending line (§9.4)

/// What a chat's row says before its last message: a send that may never have arrived, else words waiting in the field.
nonisolated struct SessionPending: Hashable, Sendable {
    var failed: Bool
    var text: String

    /// `rowPending` (`S/ui-lists/row-pending.ts:15-20`): the lost send first, then a non-empty trimmed draft.
    static func pending(lost: String?, draft: String?) -> SessionPending? {
        if let lost { return SessionPending(failed: true, text: lost.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let typed = (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? nil : SessionPending(failed: false, text: typed)
    }

    var prefix: String { failed ? "Not Delivered:" : "Draft:" }
}

// MARK: - Mark All as Read (§5.6)

/// One chat whose `unread:false` write failed.
nonisolated struct SessionWriteFailure: Hashable, Sendable {
    var id: String
    var profile: String
    var reason: String

    /// The alert's reason (`filter-apply.ts:66`): the first failure's; with more than one, "<n> chats: <reason>".
    static func alertReason(_ failures: [SessionWriteFailure]) -> String {
        guard let first = failures.first else { return "" }
        return failures.count > 1 ? "\(failures.count) chats: \(first.reason)" : first.reason
    }
}

// MARK: - The reconnect probe (§11)

/// `sidebarProbeStats` (`S/sidebar-probe.ts:68-71`): limit-1 probes sent, full reads they saved, full reads made.
/// [perf-returns] `top`: short top-page reads made instead of a full read (docs/spec/3x-sessions.md §11.5).
nonisolated struct SidebarProbeStats: Hashable, Sendable {
    var probes = 0
    var skipped = 0
    var full = 0
    var top = 0

    var text: String { "probes=\(probes) skipped=\(skipped) full=\(full) top=\(top)" }
}

// MARK: - Session Info (§10.3)

/// A chat's usage as the gateway reports it (`AG/tui_gateway/contracts/common.py` Usage); every field optional, a value
/// that is not a finite number reads as absent.
nonisolated struct SessionUsage: Hashable, Sendable {
    var total: Int?
    var input: Int?
    var output: Int?
    var contextUsed: Int?
    var contextMax: Int?
    var contextPercent: Double?
    var contextEstimated: Bool?
    var costUsd: Double?
    // Tester 2026-10-27: the usage card. `input` is the uncached input only; `prompt` is everything sent
    // (input + cache reads + cache writes, H:agent/usage_pricing.py `CanonicalUsage.prompt_tokens`).
    var prompt: Int?
    var reasoning: Int?
    var calls: Int?
    var compressions: Int?
    /// Share of `prompt` read from the provider's cache, 0–100; absent when nothing was read from it.
    var cacheHitPercent: Double?
    /// Over the last ten calls (`avg_tps`, `avg_latency_s`); absent where the provider gives no timings (Codex).
    var tokensPerSecond: Double?
    var secondsPerCall: Double?

    /// nil unless an object.
    static func decode(_ json: JSONValue?) -> SessionUsage? {
        guard let o = json?.object else { return nil }
        func count(_ key: String) -> Int? {
            guard case .number(let n)? = o[key], n.isFinite, n >= 0 else { return nil }
            return Int(exactly: n.rounded(.towardZero))
        }
        func number(_ key: String) -> Double? {
            guard case .number(let n)? = o[key], n.isFinite else { return nil }
            return n
        }
        func positive(_ key: String) -> Double? { number(key).flatMap { $0 > 0 ? $0 : nil } }
        return SessionUsage(total: count("total"), input: count("input"), output: count("output"), contextUsed: count("context_used"),
                            contextMax: count("context_max"), contextPercent: number("context_percent"),
                            contextEstimated: o["context_estimated"]?.bool, costUsd: number("cost_usd"),
                            prompt: count("prompt"), reasoning: count("reasoning"), calls: count("calls"),
                            compressions: count("compressions"),
                            cacheHitPercent: number("cache_hit_pct").flatMap { $0 >= 0 ? Swift.min(100, $0) : nil },
                            tokensPerSecond: positive("avg_tps"), secondsPerCall: positive("avg_latency_s"))
    }
}

/// The gateway answered with another model (`S/phone-notices.ts:232-237`).
nonisolated struct ModelFallback: Hashable, Sendable {
    var primary: String
    var fallback: String
    var reason: String?

    private static let model = JSRegex(#"Model fallback:\s*(\S+) via (\S+) unavailable(?: \(([^)]*)\))?; using (\S+) via (\S+?)\.(?:\s|$)"#)
    private static let provider = JSRegex(#"Provider fallback:\s*(\S+) unavailable; using (\S+) for this response"#)

    /// The gateway's status line, both shapes; nil for anything else.
    static func parse(_ text: String) -> ModelFallback? {
        if let groups = model.exec(text)?.groups, groups.count > 4, !groups[1].isEmpty, !groups[4].isEmpty {
            return ModelFallback(primary: groups[1], fallback: groups[4], reason: groups[3].isEmpty ? nil : groups[3])
        }
        if let groups = provider.exec(text)?.groups, groups.count > 2, !groups[1].isEmpty, !groups[2].isEmpty {
            return ModelFallback(primary: groups[1], fallback: groups[2], reason: nil)
        }
        return nil
    }

    /// "Primary model restored:" ends a fallback.
    static func restores(_ text: String) -> Bool { text.contains("Primary model restored:") }
}
