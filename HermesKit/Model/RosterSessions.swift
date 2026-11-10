// Sessions tab data (spec 02 §9): the sidebar answer, its rows, the client-side filters, row words, unread rules and
// the date groups. Pure.

import Foundation

// MARK: - Wire

/// One session row of `GET /api/profiles/sessions/sidebar` (`V/types/hermes.ts:546-640`). Times are unix seconds.
nonisolated struct SidebarSessionRow: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var title: String?
    var preview: String?
    var source: String?
    var startedAt: Double?
    var lastActive: Double?
    var endedAt: Double?
    var messageCount: Int?
    var toolCallCount: Int?
    var model: String?
    var cwd: String?
    var profile: String
    var isDefaultProfile: Bool?
    var isActive: Bool?
    var archived: Bool?
    var pinned: Bool?
    /// Server read watermark (`last_active > last_read_at`; never-touched reads as read).
    var unread: Bool?
    var hidden: Bool?
    var lineageRootId: String?
    var parentSessionId: String?
    // [sessions-m9] Row Detail, Sort By and Session Info (docs/spec/3x-sessions.md §3.1). Optional: an older cache
    // file without these keys still loads; a missing, null, non-numeric, negative or non-finite value reads as absent.
    var inputTokens: Int?
    var outputTokens: Int?
    var actualCostUsd: Double?
    var estimatedCostUsd: Double?
    var gitBranch: String?
    var handoffPlatform: String?
    /// 'pending' | 'in_progress' | 'completed' | 'failed': only a finished handoff names its origin on the row.
    var handoffState: String?
    // [/sessions-m9]
    /// The sign-in Hermes stamped on the chat (`user_id`: "nous:<id>", "basic:<username>" for the old password sign-in),
    /// so a refused edit can say whose it is (SessionActionText.refused(owner:)). Optional: older caches lack it.
    var userId: String?

    init(id: String, profile: String, title: String? = nil, preview: String? = nil, source: String? = nil,
         lastActive: Double? = nil, messageCount: Int? = nil, pinned: Bool? = nil, unread: Bool? = nil, hidden: Bool? = nil) {
        self.id = id; self.profile = profile; self.title = title; self.preview = preview; self.source = source
        self.lastActive = lastActive; self.messageCount = messageCount; self.pinned = pinned; self.unread = unread
        self.hidden = hidden
    }

    init?(json: JSONValue) {
        guard let o = json.object, let id = RosterText.trimmed(o["id"]) else { return nil }
        self.id = id
        title = o["title"].flatMap { $0.isNull ? nil : RosterText.text($0) }
        preview = o["preview"].flatMap { $0.isNull ? nil : RosterText.text($0) }
        source = RosterText.trimmed(o["source"])
        startedAt = RosterText.number(o["started_at"])
        lastActive = RosterText.number(o["last_active"])
        endedAt = RosterText.number(o["ended_at"])
        messageCount = RosterText.count(o["message_count"])
        toolCallCount = RosterText.count(o["tool_call_count"])
        model = RosterText.trimmed(o["model"])
        cwd = RosterText.trimmed(o["cwd"])
        profile = RosterText.trimmed(o["profile"]) ?? RosterText.trimmed(o["profile_name"]) ?? "default"
        isDefaultProfile = o["is_default_profile"]?.bool
        isActive = o["is_active"]?.bool
        archived = o["archived"]?.bool
        pinned = o["pinned"]?.bool
        unread = o["unread"]?.bool
        hidden = o["hidden"]?.bool
        lineageRootId = RosterText.trimmed(o["_lineage_root_id"])
        parentSessionId = RosterText.trimmed(o["parent_session_id"])
        // [sessions-m9]
        func amount(_ key: String) -> Double? { RosterText.number(o[key]).flatMap { $0 >= 0 ? $0 : nil } }
        inputTokens = RosterText.count(o["input_tokens"]).flatMap { $0 >= 0 ? $0 : nil }
        outputTokens = RosterText.count(o["output_tokens"]).flatMap { $0 >= 0 ? $0 : nil }
        actualCostUsd = amount("actual_cost_usd")
        estimatedCostUsd = amount("estimated_cost_usd")
        gitBranch = RosterText.trimmed(o["git_branch"])
        handoffPlatform = RosterText.trimmed(o["handoff_platform"])
        handoffState = RosterText.trimmed(o["handoff_state"])
        // [/sessions-m9]
        userId = RosterText.trimmed(o["user_id"])
    }

    // [sessions-m9] Sort By Tokens / Cost (`V/store/sidebar-sort.ts`).
    /// `input_tokens + output_tokens`, never overflowing.
    var totalTokens: Int {
        let (sum, overflow) = (inputTokens ?? 0).addingReportingOverflow(outputTokens ?? 0)
        return overflow ? Int.max : max(0, sum)
    }
    /// The actual cost, else the estimate, else 0 (`sessionCostUsd`).
    var costUsd: Double { actualCostUsd ?? estimatedCostUsd ?? 0 }

    /// The row's recency, seconds (`last_active || started_at`).
    var recency: Double { (lastActive ?? 0) > 0 ? lastActive! : (startedAt ?? 0) }
}

/// A decoded sidebar answer. A slice whose scan failed comes back without `sessions` (`{"failed":true,"retry":true}`):
/// its `rows` is nil, which reads as "Retry", never as "No sessions".
nonisolated struct SidebarPayload: Sendable, Hashable {
    nonisolated struct Slice: Sendable, Hashable {
        var rows: [SidebarSessionRow]?
        var total: Int?
        var failed: Bool { rows == nil }
    }
    var recents: Slice
    var cron: Slice
    var messaging: Slice
    /// Per-profile scan errors (`errors[].profile`).
    var failedProfiles: [String]
    /// What a limit-1 probe can compare (`S/sidebar-probe.ts`); nil for an unhealthy answer.
    var fingerprint: String?

    nonisolated enum DecodeError: Error, CustomStringConvertible {
        case notASidebar
        var description: String { "The gateway's sessions list was not readable." }
    }

    static func decode(_ json: JSONValue) throws -> SidebarPayload {
        guard json.object != nil else { throw DecodeError.notASidebar }
        func slice(_ key: String) -> Slice {
            guard let o = json[key]?.object, let rows = o["sessions"]?.array else { return Slice(rows: nil, total: nil) }
            return Slice(rows: rows.compactMap(SidebarSessionRow.init(json:)), total: RosterText.count(o["total"]))
        }
        let failed = (json["errors"]?.array ?? []).compactMap { RosterText.trimmed($0["profile"]) }
        return SidebarPayload(recents: slice("recents"), cron: slice("cron"), messaging: slice("messaging"),
                              failedProfiles: failed, fingerprint: SidebarFingerprint.of(json))
    }

    /// Decode raw bytes off the main thread (the owner's answer is ~570 KB).
    @concurrent static func decode(data: Data) async throws -> SidebarPayload {
        try decode(JSONValue.parse(data))
    }

    /// An older gateway's three per-slice answers (`GET /api/profiles/sessions`, `{sessions, errors?, storage?, …}`)
    /// assembled into the sidebar shape (`listSidebarSessionsLegacy`, `V/api/sessions.ts:252-290`): each page becomes
    /// its slice, the slices' errors and storage notes are also reported at the top.
    @concurrent static func decodeLegacy(recents: Data, cron: Data, messaging: Data) async throws -> SidebarPayload {
        try assembleLegacy(recents: JSONValue.parse(recents), cron: JSONValue.parse(cron), messaging: JSONValue.parse(messaging))
    }

    static func assembleLegacy(recents: JSONValue, cron: JSONValue, messaging: JSONValue) throws -> SidebarPayload {
        var root: [String: JSONValue] = [:]
        var errors: [JSONValue] = []
        var storage: [String: JSONValue] = [:]
        for (key, page) in [("recents", recents), ("cron", cron), ("messaging", messaging)] {
            guard let slice = page.object else { throw DecodeError.notASidebar }
            if let found = slice["errors"]?.array { errors += found }
            if let notes = slice["storage"]?.object { storage.merge(notes) { first, _ in first } }
            root[key] = .object(slice.filter { $0.key != "storage" })
        }
        if !errors.isEmpty { root["errors"] = .array(errors) }
        if !storage.isEmpty { root["storage"] = .object(storage) }
        return try decode(.object(root))
    }
}

/// `sidebarFingerprint` (`S/sidebar-probe.ts:43-62`): each slice's newest row and pinned rows, plus the usage totals.
nonisolated enum SidebarFingerprint {
    static func of(_ data: JSONValue) -> String? {
        guard let root = data.object else { return nil }
        if let errors = root["errors"]?.array, !errors.isEmpty { return nil }
        if let failed = root["profiles_failed"], RosterText.truthy(failed) { return nil }
        if let storage = root["storage"]?.object, !storage.isEmpty { return nil }
        var parts: [String] = []
        for key in ["recents", "cron", "messaging"] {
            guard let slice = root[key]?.object, let sessions = slice["sessions"]?.array else { return nil }
            if let errors = slice["errors"]?.array, !errors.isEmpty { return nil }
            if RosterText.truthy(slice["profiles_failed"]) || RosterText.truthy(slice["retry"]) { return nil }
            let rows = sessions.compactMap(\.object)
            func recency(_ row: [String: JSONValue]) -> Double { RosterText.number(row["last_active"] ?? row["started_at"]) ?? 0 }
            var newest: [String: JSONValue]?
            for row in rows where newest == nil || recency(row) > recency(newest!) { newest = row }
            let pinned = rows.filter { $0["pinned"]?.bool == true }.map { stable(.object($0), drop: ["is_active"]) }.sorted()
            parts.append(key)
            parts.append(newest.map { stable(.object($0), drop: ["is_active"]) } ?? "")
            parts.append(pinned.joined(separator: "\n"))
        }
        parts.append(stable(root["recents"]?["profiles_usage"] ?? .null))
        return parts.joined(separator: "\u{0}")
    }

    /// JSON with sorted keys (top-level keys in `drop` left out).
    static func stable(_ value: JSONValue, drop: Set<String> = []) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return RosterText.numberText(n)
        case .string(let s): return quote(s)
        case .array(let a): return "[" + a.map { stable($0) }.joined(separator: ",") + "]"
        case .object(let o):
            return "{" + o.keys.filter { !drop.contains($0) }.sorted().map { "\(quote($0)):\(stable(o[$0]!))" }.joined(separator: ",") + "}"
        }
    }

    private static func quote(_ s: String) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\(s)\""
    }
}

/// [perf-returns] A reconnect's short top page merged into the rows already loaded (docs/spec/3x-sessions.md §11.5).
/// The gateway answers a slice with its newest `limit` rows by recency, plus every pinned row past them
/// (`_pinned_window`, `AG/hermes_cli/web_routers/profiles.py:245-252`).
nonisolated enum SidebarTopPage {
    /// - A page with fewer rows than its limit is the whole slice: it replaces the old rows outright.
    /// - Otherwise its newest `limit` rows are the window, and the window's oldest recency the floor. Page rows replace
    ///   or join the old rows by (id, profile); an old row absent from the page at or above the floor is gone (moved,
    ///   archived, deleted or emptied near the top); an old row below the floor is kept, as it was, until the next full
    ///   read. Every pin comes back with the page, so a kept row the page left out is no longer pinned.
    static func merge(_ old: [SidebarSessionRow], page: [SidebarSessionRow], limit: Int) -> [SidebarSessionRow] {
        guard limit > 0, page.count >= limit else { return page }
        let window = page.enumerated().sorted { a, b in
            a.element.recency != b.element.recency ? a.element.recency > b.element.recency : a.offset < b.offset
        }.prefix(limit)
        let floor = window.map(\.element.recency).min() ?? 0
        let fresh = Set(page.map { key($0) })
        var out = page
        for var row in old where !fresh.contains(key(row)) && row.recency < floor {
            if row.pinned == true { row.pinned = false }
            out.append(row)
        }
        // Newest first, as a read answers (ties keep the page's order, then the old order).
        return out.enumerated().sorted { a, b in
            a.element.recency != b.element.recency ? a.element.recency > b.element.recency : a.offset < b.offset
        }.map(\.element)
    }

    private static func key(_ row: SidebarSessionRow) -> String { row.profile + "\u{0}" + row.id }
}

// MARK: - Row rules

nonisolated enum SessionRules {
    /// Sources a bot runs on its own (`S/session-runs.ts:17`); hidden from the dated list unless Show › Background Runs.
    static let runSources: Set<String> = ["tool", "oneshot", "subagent", "kanban"]

    static func isBackgroundRun(_ row: SidebarSessionRow) -> Bool { runSources.contains(row.source ?? "") || isProbe(row) }

    /// A script's check that the gateway answers ("Do not use tools. Reply with exactly ROUTE_OK."), sent from a
    /// terminal or a test client rather than as a `oneshot` run, so it lands as an ordinary chat: hidden like a run.
    /// Only a short chat with no tool calls whose first message (`preview`) is such an order, and never one from this
    /// app (`desktop`) or a messaging platform, where a person typed it.
    static func isProbe(_ row: SidebarSessionRow) -> Bool {
        let source = ChatSource.id(row.source)
        guard source != "desktop", !ChatSource.isMessaging(source), (row.toolCallCount ?? 0) == 0,
              (row.messageCount ?? 0) <= 6,
              let first = row.preview?.trimmingCharacters(in: .whitespacesAndNewlines), first.count <= 160
        else { return false }
        return probeToken.test(first) || probeExactly.test(first)
    }

    private static let probeLead = #"^(?i:(?:do not|don't) (?:use|call) (?:any )?tools?[.,;:!]?\s+)?(?i:please\s+)?"#
        + #"(?i:reply|respond|answer|say|return|output|print)(?i: with)?"#
    /// "Return ROUTE_OK", "Reply with only PONG", "Say exactly: READY" (the answer in capitals, as scripts write it).
    private static let probeToken = JSRegex(probeLead + #"(?i: exactly| only| just)?:?\s+["'`]?[A-Z][A-Z0-9_]{1,40}["'`]?[.!]?$"#)
    /// "Reply with exactly the word ok".
    private static let probeExactly = JSRegex(probeLead + #" (?i:exactly)\b.{0,60}$"#)

    /// Bot Chats never show on Sessions (§9.2): the gateway hides them; a row that still says so is dropped.
    static func isBotChat(_ row: SidebarSessionRow) -> Bool {
        // [groups] A group chat member's hidden session (`Group: …`) is plumbing too, should an older gateway list it.
        let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return row.hidden == true || title == RosterRules.botChatTitle || GroupKeys.isPlumbingTitle(title)
    }

    private static let markupOnly = JSRegex(#"^<[\w:-]+>\s*[{\[<]"#)
    private static let whitespaceRun = JSRegex(#"\s+"#)
    private static let profileSlug = JSRegex(#"^[a-z0-9][a-z0-9_-]*$"#)
    private static func words(_ text: String?) -> String {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return markupOnly.test(t) ? "" : t
    }

    /// A row's title on the phone (`V/lib/chat-runtime.ts` sessionTitle as gated by `B/stress-d-gates.ts:134`,
    /// `B/stress-c-gates.ts:149-152`, r6-31): title, else preview, else "Untitled Chat"; a model-switch note reworded.
    static func title(_ row: SidebarSessionRow, model: (String) -> String = { $0 }) -> String {
        var base = words(row.title)
        if base.isEmpty { base = words(row.preview) }
        if base.isEmpty { base = "Untitled Chat" }
        let shown = RosterPreview.rowPreview(base, model: model)
        return shown.isEmpty ? "Untitled Chat" : shown
    }

    /// The preview after the owner's name (`rowDetail`): rowPreview on one line; nil when empty.
    static func preview(_ row: SidebarSessionRow, model: (String) -> String = { $0 }) -> String? {
        let line = whitespaceRun.replaceAll(RosterPreview.rowPreview(row.preview, model: model), " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    /// `maple-revenue-operator` → `Maple Revenue Operator` (`S/list-helpers.ts:111-115`); anything else as it is.
    static func readableProfileName(_ label: String) -> String {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profileSlug.test(text) else { return text }
        return RosterRules.titleCase(text)
    }

    /// The owner bot's name on a Sessions row (`profileDisplayName`, `S/audit-c-format.ts:401-407`).
    static func ownerName(profile: String, displayNames: [String: String]) -> String {
        let id = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if let shown = RosterText.nonBlank(displayNames[id]) { return shown }
        if id.isEmpty || id == "default" { return "Hermes" }
        return readableProfileName(id)
    }
}

// MARK: - Unread (§9.3)

/// Device-local unread state for listed sessions: "seen" watermarks (seeded on first sight so a fresh install shows
/// nothing), explicit markers, and rows cleared locally without a server write.
nonisolated struct SessionUnreadState: Codable, Sendable, Hashable {
    /// Profile → session id → the `message_count` this device has seen.
    var seen: [String: [String: Int]] = [:]
    /// Profile → explicitly unread ids.
    var markers: [String: [String]] = [:]
    /// Session id → `last_active` when the dot was cleared on this device only (read-only gateway); the server's
    /// `unread` is ignored until the session moves past it.
    var localReads: [String: Double] = [:]

    static let maxSeenPerProfile = 2000

    init() {}

    /// Seed watermarks for rows seen for the first time.
    mutating func observe(_ rows: [SidebarSessionRow]) {
        for row in rows {
            guard let count = row.messageCount, seen[row.profile]?[row.id] == nil else { continue }
            seen[row.profile, default: [:]][row.id] = count
        }
        for (profile, map) in seen where map.count > Self.maxSeenPerProfile {
            let live = Set(rows.filter { $0.profile == profile }.map(\.id))
            seen[profile] = map.filter { live.contains($0.key) }
        }
    }

    /// Unread when the server says so (not overridden), an explicit marker exists, or (non-messaging rows) the
    /// stored count passed the seen watermark. The selected chat skips the local half (markers and watermark) like
    /// the web's `recomputeUnread`; the server's flag still counts (`session-dot-state.ts`).
    func isUnread(_ row: SidebarSessionRow, messaging: Bool = false, serverOverride: Bool? = nil, selected: Bool = false) -> Bool {
        if !selected, markers[row.profile]?.contains(row.id) == true { return true }
        if messaging { return false }
        var server = serverOverride ?? row.unread ?? false
        if server, let cleared = localReads[row.id], (row.lastActive ?? 0) <= cleared { server = false }
        if server { return true }
        if selected { return false }
        if let count = row.messageCount, let watermark = seen[row.profile]?[row.id], count > watermark { return true }
        return false
    }

    /// Opening a row clears its local state.
    mutating func opened(_ row: SidebarSessionRow, clearServerLocally: Bool) {
        if let count = row.messageCount { seen[row.profile, default: [:]][row.id] = count }
        if var bucket = markers[row.profile] {
            bucket.removeAll { $0 == row.id }
            markers[row.profile] = bucket.isEmpty ? nil : bucket
        }
        if clearServerLocally { localReads[row.id] = row.lastActive ?? 0 }
    }
}

// MARK: - Date groups (`V/lib/time.ts` calendarBucket, `V/lib/session-date-groups.ts` as gated by r6-41)

nonisolated enum SessionDateGroups {
    nonisolated enum Kind: String, Sendable, Hashable { case today, yesterday, thisWeek, lastWeek, thisMonth, month, monthYear }

    nonisolated struct Bucket: Sendable, Hashable {
        var key: String
        var kind: Kind
        /// The nominal day the bucket was computed from (month labels).
        var at: Date
        var label: String
    }

    nonisolated struct Group<Item: Sendable & Hashable>: Sendable, Hashable {
        var bucket: Bucket
        var items: [Item]
    }

    /// The human day ends at 4 AM: a 12:30 AM session groups with the evening before.
    static let rolloverHour = 4

    static func nominalDayStart(_ date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date.addingTimeInterval(-Double(rolloverHour) * 3600))
    }

    /// The coarse calendar range of a time: Earlier today → Yesterday → Earlier this week → Last week → Earlier this
    /// month → "September" → "September 2025".
    static func bucket(seconds: Double, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> Bucket {
        let nominal = nominalDayStart(Date(timeIntervalSince1970: seconds), calendar: calendar)
        let today = nominalDayStart(now, calendar: calendar)
        let dayDiff = calendar.dateComponents([.day], from: nominal, to: today).day ?? 0
        if dayDiff <= 0 { return Bucket(key: "today", kind: .today, at: nominal, label: "Earlier today") }
        if dayDiff == 1 { return Bucket(key: "yesterday", kind: .yesterday, at: nominal, label: "Yesterday") }
        let weekdayToday = calendar.component(.weekday, from: today)            // 1 = Sunday
        let back = (weekdayToday - calendar.firstWeekday + 7) % 7
        let weekStart = calendar.date(byAdding: .day, value: -back, to: today) ?? today
        if nominal >= weekStart { return Bucket(key: "this-week", kind: .thisWeek, at: nominal, label: "Earlier this week") }
        let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
        if nominal >= lastWeekStart { return Bucket(key: "last-week", kind: .lastWeek, at: nominal, label: "Last week") }
        let y = calendar.component(.year, from: nominal), m = calendar.component(.month, from: nominal)
        let sameYear = y == calendar.component(.year, from: today)
        if sameYear && m == calendar.component(.month, from: today) {
            return Bucket(key: "this-month", kind: .thisMonth, at: nominal, label: "Earlier this month")
        }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if sameYear {
            return Bucket(key: "m-\(y)-\(m)", kind: .month, at: nominal, label: nominal.formatted(style.month(.wide)))
        }
        return Bucket(key: "my-\(y)-\(m)", kind: .monthYear, at: nominal, label: nominal.formatted(style.month(.wide).year()))
    }

    /// Items (already newest first) split under a label per calendar range; on the phone every group is labelled,
    /// the newest too. An item whose range was already emitted (out-of-order input) stays in the group above it.
    static func group<Item: Sendable & Hashable>(_ items: [Item], seconds: (Item) -> Double, now: Date = Date(),
                                                 calendar: Calendar = .current, locale: Locale = .current) -> [Group<Item>] {
        var groups: [Group<Item>] = []
        var emitted = Set<String>()
        for item in items {
            let bucket = self.bucket(seconds: seconds(item), now: now, calendar: calendar, locale: locale)
            if groups.last?.bucket.key == bucket.key || emitted.contains(bucket.key), !groups.isEmpty {
                groups[groups.count - 1].items.append(item)
            } else {
                emitted.insert(bucket.key)
                groups.append(Group(bucket: bucket, items: [item]))
            }
        }
        return groups
    }
}
