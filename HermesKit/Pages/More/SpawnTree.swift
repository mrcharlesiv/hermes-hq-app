// Spawn Tree (docs/spec/3x-morepages.md §16, D-M13): the gateway's own list of running subagents, JSON-RPC
// `delegation.status` with `{"profile"?}` only (`AG/tui_gateway/contracts/billing_delegation_pets.py`), one call per
// bot. Here: the lenient decoder and the pure tree builder (grouped by bot, then by owning chat; orphans attach to the
// root, cycles are broken, repeated ids are dropped) with its words.

import Foundation

nonisolated struct SpawnRecord: Sendable, Equatable {
    var id: String
    var parentId: String?
    var depth: Int?
    var goal: String?
    var model: String?
    var startedAt: Double?
    var status: SpawnStatus
    var toolCount: Int?
    var ownerSession: String?

    init(id: String, parentId: String? = nil, depth: Int? = nil, goal: String? = nil, model: String? = nil, startedAt: Double? = nil,
         status: SpawnStatus = .running, toolCount: Int? = nil, ownerSession: String? = nil) {
        self.id = id; self.parentId = parentId; self.depth = depth; self.goal = goal; self.model = model
        self.startedAt = startedAt; self.status = status; self.toolCount = toolCount; self.ownerSession = ownerSession
    }

    /// nil for a record with no id (it cannot be a row).
    init?(json: JSONValue) {
        guard let id = json["subagent_id"]?.pgString, !id.isEmpty else { return nil }
        self.id = id
        parentId = json["parent_id"]?.pgString.flatMap { $0.isEmpty ? nil : $0 }
        depth = json["depth"]?.int
        goal = json["goal"]?.string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        model = json["model"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        startedAt = json["started_at"]?.pgSeconds
        status = SpawnStatus(raw: json["status"]?.string)
        toolCount = json["tool_count"]?.int.map { max(0, $0) }
        ownerSession = json["owner_agent_session_id"]?.pgString.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The web's four words (`V/i18n/en.ts` agents.status): Running / Failed / Done / Queued.
nonisolated enum SpawnStatus: String, Sendable, Equatable {
    case running, queued, done, failed

    init(raw: String?) {
        switch (raw ?? "").lowercased() {
        case "queued", "pending", "waiting", "starting": self = .queued
        case "done", "completed", "complete", "finished", "success", "succeeded": self = .done
        case "failed", "error", "errored", "interrupted", "timeout", "timed_out", "cancelled", "canceled", "killed": self = .failed
        default: self = .running
        }
    }

    var word: String {
        switch self { case .running: "Running"; case .queued: "Queued"; case .done: "Done"; case .failed: "Failed" }
    }
}

nonisolated struct DelegationStatus: Sendable, Equatable {
    var active: [SpawnRecord]
    var paused: Bool
    var maxDepth: Int?
    var maxChildren: Int?

    init(active: [SpawnRecord] = [], paused: Bool = false, maxDepth: Int? = nil, maxChildren: Int? = nil) {
        self.active = active; self.paused = paused; self.maxDepth = maxDepth; self.maxChildren = maxChildren
    }

    init(json: JSONValue) {
        active = (json["active"]?.array ?? []).compactMap(SpawnRecord.init(json:))
        paused = json["paused"]?.bool ?? false
        maxDepth = json["max_spawn_depth"]?.int
        maxChildren = json["max_concurrent_children"]?.int
    }
}

nonisolated struct SpawnTreeAPI: Sendable {
    let client: any GatewayClient

    /// `delegation.status` with `{"profile": id}` for a named bot and `{}` for the default one: no other key.
    @concurrent
    func status(profile: String?) async throws -> DelegationStatus {
        let status = DelegationStatus(json: try await client.call("delegation.status", MoreWire.profileParams(profile), timeout: .seconds(15)))
        AppLog.trace("pages", "spawn tree status \(AppLog.tag(profile)): \(status.active.count) active, paused \(status.paused)")
        return status
    }
}

nonisolated struct SpawnTree: Sendable, Equatable {
    struct Row: Sendable, Equatable, Identifiable {
        var id: String              // "<profile>|<subagent id>"
        var record: SpawnRecord
        /// Levels under the chat's root, as built from `parent_id`.
        var level: Int
        /// The indent drawn: `level` capped at `SpawnTree.maxIndent`.
        var indent: Int { min(level, SpawnTree.maxIndent) }
    }
    struct Chat: Sendable, Equatable, Identifiable {
        var id: String              // "<profile>|<session id>"
        var sessionId: String?
        var title: String
        var rows: [Row]
    }
    struct BotGroup: Sendable, Equatable, Identifiable {
        var id: String              // the profile
        var chats: [Chat]
        var count: Int { chats.reduce(0) { $0 + $1.rows.count } }
    }
    /// What the app knows about a chat: its bot and title.
    struct Session: Sendable, Equatable {
        var profile: String
        var title: String
    }

    static let maxIndent = 4
    static let indentWidth = 16.0

    var bots: [BotGroup] = []
    var paused = false

    var total: Int { bots.reduce(0) { $0 + $1.count } }
    var active: Int { bots.reduce(0) { sum, bot in sum + bot.chats.reduce(0) { $0 + $1.rows.count { $0.record.status == .running } } } }
    var isEmpty: Bool { total == 0 }

    /// "14 subagents · 9 active" (the page's own word: they are helpers a bot started, not your bots).
    var header: String { "\(total) \(total == 1 ? "subagent" : "subagents") · \(active) active" }

    /// Groups each bot's answer by bot, then by owning chat. A subagent listed under several bots (a gateway that
    /// serves every bot from one process answers the whole list for each) is kept once: under the bot that owns its
    /// chat when the app knows the chat, else under the first bot that listed it.
    static func build(answers: [(profile: String, status: DelegationStatus)], sessions: [String: Session]) -> SpawnTree {
        var owner: [String: String] = [:]           // subagent id → profile
        var order: [String] = []
        var records: [String: SpawnRecord] = [:]
        for (profile, status) in answers {
            for record in status.active where records[record.id] == nil {
                records[record.id] = record
                order.append(record.id)
                owner[record.id] = record.ownerSession.flatMap { sessions[$0]?.profile } ?? profile
            }
        }
        var profiles = answers.map(\.profile)
        for id in order { if let profile = owner[id], !profiles.contains(profile) { profiles.append(profile) } }

        var tree = SpawnTree()
        tree.paused = answers.contains { $0.status.paused }
        var seenProfiles = Set<String>()
        for profile in profiles where seenProfiles.insert(profile).inserted {
            let mine = order.filter { owner[$0] == profile }.compactMap { records[$0] }
            guard !mine.isEmpty else { continue }
            var chatOrder: [String] = []
            var byChat: [String: [SpawnRecord]] = [:]
            for record in mine {
                let key = record.ownerSession ?? ""
                if byChat[key] == nil { chatOrder.append(key) }
                byChat[key, default: []].append(record)
            }
            let chats = chatOrder.map { key -> Chat in
                let title = sessions[key]?.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let rows = flatten(byChat[key] ?? []).map { Row(id: profile + "|" + $0.record.id, record: $0.record, level: $0.level) }
                return Chat(id: profile + "|" + key, sessionId: key.isEmpty ? nil : key, title: (title?.isEmpty ?? true) ? "Chat" : title!, rows: rows)
            }
            tree.bots.append(BotGroup(id: profile, chats: chats))
        }
        return tree
    }

    /// The records in tree order (a parent, then its children by start time) with each one's level. A record whose
    /// parent is not in the list is a root; a cycle is entered at its earliest member, which becomes a root.
    static func flatten(_ records: [SpawnRecord]) -> [(record: SpawnRecord, level: Int)] {
        var byId: [String: SpawnRecord] = [:]
        var order: [String] = []
        for record in records where byId[record.id] == nil { byId[record.id] = record; order.append(record.id) }
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        func earlier(_ a: String, _ b: String) -> Bool {
            let x = byId[a]?.startedAt ?? .greatestFiniteMagnitude, y = byId[b]?.startedAt ?? .greatestFiniteMagnitude
            return x != y ? x < y : (position[a] ?? 0) < (position[b] ?? 0)
        }
        var children: [String: [String]] = [:]
        var roots: [String] = []
        for id in order {
            if let parent = byId[id]?.parentId, parent != id, byId[parent] != nil { children[parent, default: []].append(id) } else { roots.append(id) }
        }
        var out: [(record: SpawnRecord, level: Int)] = []
        var visited = Set<String>()
        func walk(_ start: String) {
            var stack = [(id: start, level: 0)]
            while let (id, level) = stack.popLast() {
                guard visited.insert(id).inserted, let record = byId[id] else { continue }
                out.append((record, level))
                for child in (children[id] ?? []).sorted(by: earlier).reversed() where !visited.contains(child) {
                    stack.append((child, level + 1))
                }
            }
        }
        for root in roots.sorted(by: earlier) { walk(root) }
        // What is left sits on a cycle (or hangs from one): enter each at its earliest member.
        while let next = order.filter({ !visited.contains($0) }).min(by: earlier) { walk(next) }
        return out
    }

    // MARK: Words

    /// 45 → "45s", 130 → "2m 10s", 3900 → "1h 5m", 93,600 → "1d 2h"; nil for a time that is not known.
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < 3.2e9 else { return nil }
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }

    static func tools(_ count: Int) -> String { count == 1 ? "1 tool" : "\(count) tools" }

    /// "Hermes 4 · 3 tools · running 2m 10s".
    static func detail(_ record: SpawnRecord, now: Double) -> String {
        var parts: [String] = []
        if let model = record.model { parts.append(ModelNames.displayModelName(model)) }   // the model's name, not its slug
        if let count = record.toolCount { parts.append(tools(count)) }
        switch record.status {
        case .running:
            if let time = duration(record.startedAt.map { now - $0 }) { parts.append("running \(time)") } else { parts.append("running") }
        case .queued: parts.append("queued")
        case .done: parts.append("done")
        case .failed: parts.append("failed")
        }
        return parts.joined(separator: " · ")
    }

    /// VoiceOver: "Read the networking changes. Running, 2 minutes. hermes-4, 7 tools. Level 2."
    static func spoken(_ row: Row, now: Double) -> String {
        var parts = [row.record.goal ?? "Subagent", row.record.status.word]
        if let model = row.record.model { parts.append(ModelNames.displayModelName(model)) }
        if let count = row.record.toolCount { parts.append(tools(count)) }
        if row.record.status == .running, let started = row.record.startedAt, now >= started {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.maximumUnitCount = 2
            if let time = formatter.string(from: now - started) { parts.append("for \(time)") }
        }
        if row.level > 0 { parts.append("level \(row.level + 1)") }
        return parts.joined(separator: ", ")
    }
}
