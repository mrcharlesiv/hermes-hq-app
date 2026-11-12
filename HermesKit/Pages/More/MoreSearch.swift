// More search, the phone's command palette (docs/spec/3x-morepages.md §18, D-M15; web `S/settings-ios-list.tsx:316-359`):
// what the More tab's magnifier finds, grouped Go To, Bots, Sessions, Settings, Actions. Pure: the page hands in what is
// on show right now (so a page hidden on this gateway is never offered) and gets rows back.

import Foundation

nonisolated enum MoreSearch {
    enum Kind: String, Sendable, CaseIterable {
        case goTo, bots, sessions, settings, actions
        var title: String {
            switch self {
            case .goTo: "Go To"
            case .bots: "Bots"
            case .sessions: "Sessions"
            case .settings: "Settings"
            case .actions: "Actions"
            }
        }
    }

    struct Item: Sendable, Hashable, Identifiable {
        /// Unique within its group.
        var id: String
        var title: String
        /// The secondary line: "Settings › Chat", "Bot", a session's bot and time.
        var detail: String = ""
        var keywords: [String] = []
        var symbol: String? = nil
    }

    struct Group: Sendable, Equatable {
        var kind: Kind
        var rows: [Item]
        /// How many matched in all (Sessions offers "Show All N" when it is more than the rows shown).
        var total: Int
        var showAll: String? { kind == .sessions && total > rows.count ? "Show All \(total)" : nil }
    }

    static let limit = 6
    static let placeholder = "Search Sessions, Pages and Actions"
    /// In the field itself: the full sentence does not fit an iPhone's search field beside its magnifier glyph.
    static let fieldPlaceholder = "Sessions, Pages and Actions"

    /// The web's extra words for More's pages (`S/settings-ios-list.tsx:327-331`), by More row id. [status-page] The web's
    /// Command Center words split between Status & Maintenance (its old name still finds it) and Usage.
    static let pageKeywords: [String: [String]] = [
        "files": ["files", "browse", "folder", "documents"],
        "review": ["review", "changes", "diff", "git"],
        "command-center": ["command center", "system", "status", "maintenance"],
        "usage": ["usage", "tokens", "cost"],
        "passwords": ["passwords", "logins", "cards", "addresses", "keys", "vault", "keychain", "1password", "bitwarden"],   // [passwords-page]
        "webhooks": ["webhooks", "hooks", "triggers"],
        "import-sessions": ["import", "claude", "codex", "conversation", "sessions"],
    ]

    static func normalize(_ text: String) -> String { SettingsSearch.normalize(text) }

    /// nil = no match. 0 the title starts with the query, 1 a title word starts with it, 2 it is inside the title,
    /// 3 only the keywords (or the detail) hold it. Every typed word must be found somewhere.
    static func score(_ query: String, title: String, keywords: [String] = [], detail: String = "") -> Int? {
        let wanted = normalize(query)
        let terms = wanted.split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return nil }
        let name = normalize(title)
        let all = normalize(([title, detail] + keywords).joined(separator: " "))
        guard terms.allSatisfy({ all.contains($0) }) else { return nil }
        if name.hasPrefix(wanted) { return 0 }
        let words = name.split(separator: " ")
        if terms.allSatisfy({ term in words.contains { $0.hasPrefix(term) } }) { return 1 }
        if terms.allSatisfy({ name.contains($0) }) { return 2 }
        return 3
    }

    /// Matching rows best first; rows of one score keep the order they came in. Duplicate ids are dropped.
    static func rank(_ items: [Item], query: String) -> [Item] {
        var seen = Set<String>()
        let scored = items.enumerated().compactMap { index, item -> (Int, Int, Item)? in
            guard seen.insert(item.id).inserted,
                  let score = score(query, title: item.title, keywords: item.keywords, detail: item.detail) else { return nil }
            return (score, index, item)
        }
        return scored.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    /// `pages`: the five tabs and every More row on show. `settings`: the Settings index. `allSessions`: after
    /// "Show All N". An empty query has no results (More shows as usual).
    static func results(query: String, pages: [Item], bots: [Item], sessions: [Item], settings: [SettingsSearchEntry],
                        actions: [Item], allSessions: Bool = false) -> [Group] {
        guard !normalize(query).isEmpty else { return [] }
        var groups: [Group] = []
        func add(_ kind: Kind, _ items: [Item], cap: Int = limit) {
            let ranked = rank(items, query: query)
            if !ranked.isEmpty { groups.append(Group(kind: kind, rows: Array(ranked.prefix(cap)), total: ranked.count)) }
        }
        add(.goTo, pages.map { item in
            var item = item
            item.keywords += pageKeywords[item.id] ?? []
            return item
        })
        add(.bots, bots)
        add(.sessions, sessions, cap: allSessions ? Int.max : limit)
        let found = SettingsSearch.results(query, in: settings, limit: limit)
        if !found.isEmpty {
            groups.append(Group(kind: .settings, rows: found.map {
                Item(id: $0.id, title: $0.label, detail: $0.context.isEmpty ? "Settings" : "Settings › " + $0.context)
            }, total: found.count))
        }
        add(.actions, actions)
        return groups
    }

    /// The first row Return opens.
    static func first(_ groups: [Group]) -> (kind: Kind, item: Item)? {
        groups.first.flatMap { group in group.rows.first.map { (group.kind, $0) } }
    }

    // MARK: Actions

    struct ActionFacts: Sendable, Equatable {
        var writable = true          // not a read-only gateway
        var kanban = false           // the Kanban page is on
        var commandCenter = false    // More lists Status & Maintenance (the gateway answers it)
        var version: String? = nil   // the gateway's Hermes version
    }

    /// "1.2.3" from "v1.2.3+abc" (`shortVersion`, `S/settings-ios-list.tsx:345`).
    static func shortVersion(_ version: String) -> String {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let cut = text.firstIndex(where: { $0 == "+" || $0 == "-" }) { text = String(text[..<cut]) }
        return text
    }

    /// Each action shows only where its feature exists and the gateway is writable.
    static func actions(_ facts: ActionFacts) -> [Item] {
        var out: [Item] = []
        if facts.writable {
            out.append(Item(id: "new-chat", title: "New Chat", keywords: ["chat", "message", "start", "compose"], symbol: "square.and.pencil"))
            out.append(Item(id: "new-bot", title: "New Bot", keywords: ["bot", "profile", "create", "add"], symbol: "plus.circle"))
            if facts.kanban {
                out.append(Item(id: "new-task", title: "New Task", keywords: ["kanban", "task", "card", "add"], symbol: "plus.rectangle.on.rectangle"))
            }
            if facts.commandCenter {
                out.append(Item(id: "restart-gateway", title: "Restart Gateway", keywords: ["restart", "reboot", "gateway"],
                                symbol: "arrow.clockwise"))
                let version = facts.version.map(shortVersion).flatMap { $0.isEmpty ? nil : "Hermes " + $0 } ?? ""
                out.append(Item(id: "update-hermes", title: "Update Hermes", detail: version,
                                keywords: ["update", "upgrade", "version"], symbol: "arrow.down.circle"))
            }
        }
        out.append(Item(id: "perf-logs", title: "Send Performance Logs", detail: "Settings › About",
                        keywords: ["performance", "logs", "diagnostics", "janky"], symbol: "waveform.path.ecg"))
        return out
    }
}
