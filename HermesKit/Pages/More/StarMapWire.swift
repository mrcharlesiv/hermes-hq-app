// More › Star Map (docs/spec/3x-morepages.md §17): the wire shapes of `GET /api/learning/graph` and
// `GET /api/learning/node` (`AG/agent/learning_graph.py` `build_learning_graph`, `AG/agent/learning_mutations.py`
// `node_detail`; `V/types/hermes.ts:863-905`), decoded leniently off the main thread, and the page's pure rules: the
// filters, the subtitle, the List's sections and the words of a row.

import Foundation

// MARK: - Wire

nonisolated struct StarMapNode: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case skill, memory }

    var id: String
    var label: String
    var kind: Kind
    var category: String
    var useCount: Int
    var state: String
    var createdBy: String?
    var pinned: Bool
    var timestamp: Double?
    var memorySource: String?

    init(id: String, label: String? = nil, kind: Kind = .skill, category: String = "general", useCount: Int = 0,
         state: String = "active", createdBy: String? = nil, pinned: Bool = false, timestamp: Double? = nil,
         memorySource: String? = nil) {
        self.id = id; self.label = label ?? id; self.kind = kind; self.category = category; self.useCount = useCount
        self.state = state; self.createdBy = createdBy; self.pinned = pinned; self.timestamp = timestamp
        self.memorySource = memorySource
    }

    /// Nil for a row with no id (skipped). Everything else has a default: a missing label is the id, a missing
    /// category is the gateway's own fallback "general", a count written as a string still counts.
    init?(json: JSONValue) {
        guard case .object = json, let id = json["id"]?.pgString?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        self.id = id
        let label = json["label"]?.pgString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.label = label.isEmpty ? id : label
        kind = json["kind"]?.string == "memory" ? .memory : .skill
        let category = json["category"]?.pgString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.category = category.isEmpty ? (kind == .memory ? "memory" : "general") : category
        useCount = max(0, json["useCount"]?.int ?? 0)
        let state = json["state"]?.string ?? ""
        self.state = state.isEmpty ? "active" : state
        let createdBy = json["createdBy"]?.string ?? ""
        self.createdBy = createdBy.isEmpty ? nil : createdBy
        pinned = StarMapNode.truthy(json["pinned"])
        timestamp = json["timestamp"]?.pgSeconds
        memorySource = json["memorySource"]?.string
    }

    static func truthy(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return ["true", "1", "yes"].contains(s.lowercased())
        default: return false
        }
    }
}

nonisolated struct StarMapEdge: Hashable, Sendable {
    var source: String
    var target: String
}

/// Freeform memory shown as a card in the List (`V/types/hermes.ts` `StarmapMemoryCard`).
nonisolated struct StarMapMemoryCard: Identifiable, Hashable, Sendable {
    /// Its place in the answer: cards have no id of their own, and two may hold the same text.
    var id: Int
    var source: String
    var title: String
    var body: String
    var timestamp: Double?
}

nonisolated struct StarMapGraph: Sendable, Equatable {
    var nodes: [StarMapNode] = []
    var edges: [StarMapEdge] = []
    var memory: [StarMapMemoryCard] = []

    var isEmpty: Bool { nodes.isEmpty && memory.isEmpty }

    init(nodes: [StarMapNode] = [], edges: [StarMapEdge] = [], memory: [StarMapMemoryCard] = []) {
        self.nodes = nodes; self.edges = edges; self.memory = memory
    }

    /// The answer of `/api/learning/graph`. Throws when it is not a graph at all (not an object, or no `nodes` list);
    /// inside it a bad row is skipped: a node without an id, a second node with an id already seen (the first wins),
    /// an edge whose ends are not both nodes or that joins a node to itself, an edge seen before in either direction,
    /// a memory card with neither title nor body.
    init(json: JSONValue) throws {
        guard case .object = json, let rows = json["nodes"]?.array else {
            throw PagesREST.unreadable(json)
        }
        var seen = Set<String>()
        for row in rows {
            guard let node = StarMapNode(json: row), seen.insert(node.id).inserted else { continue }
            nodes.append(node)
        }
        var pairs = Set<StarMapEdge>()
        for row in json["edges"]?.array ?? [] {
            guard let a = row["source"]?.pgString, let b = row["target"]?.pgString, a != b, seen.contains(a), seen.contains(b) else { continue }
            guard pairs.insert(StarMapEdge(source: min(a, b), target: max(a, b))).inserted else { continue }
            edges.append(StarMapEdge(source: a, target: b))
        }
        for row in json["memory"]?.array ?? [] {
            guard case .object = row else { continue }
            let title = row["title"]?.pgString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let body = row["body"]?.pgString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty || !body.isEmpty else { continue }
            memory.append(StarMapMemoryCard(id: memory.count, source: row["source"]?.string ?? "memory", title: title, body: body,
                                            timestamp: row["timestamp"]?.pgSeconds))
        }
    }
}

/// What a star says (`node_detail`: `{"ok","kind","id","label","content"}`).
nonisolated struct StarMapNodeDetail: Sendable, Equatable {
    var label: String?
    var content: String

    init(label: String? = nil, content: String) { self.label = label; self.content = content }

    init(json: JSONValue) throws {
        guard case .object = json else { throw PagesREST.unreadable(json) }
        label = json["label"]?.pgString
        content = (json["content"]?.pgString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum StarMapAPI {
    static let graphPath = "/api/learning/graph"
    static let nodePath = "/api/learning/node"

    /// `GET /api/learning/graph[?profile=]`, read and decoded off the main thread.
    @concurrent
    static func graph(_ client: any GatewayClient, profile: String?) async throws -> StarMapGraph {
        let graph = try StarMapGraph(json: try await PagesREST.json(client, "GET", graphPath, query: MoreWire.profileQuery(profile)))
        AppLog.trace("pages", "star map graph: \(graph.nodes.count) nodes, \(graph.edges.count) edges, \(graph.memory.count) memory cards")
        return graph
    }

    static func nodeQuery(id: String, profile: String?) -> [URLQueryItem] {
        [URLQueryItem(name: "id", value: id)] + MoreWire.profileQuery(profile)
    }

    /// `GET /api/learning/node?id=…[&profile=]`. A 404 means the node is gone (`isMissing`).
    @concurrent
    static func node(_ client: any GatewayClient, id: String, profile: String?) async throws -> StarMapNodeDetail {
        try StarMapNodeDetail(json: try await PagesREST.json(client, "GET", nodePath, query: nodeQuery(id: id, profile: profile)))
    }

    static func isMissing(_ error: Error) -> Bool { PagesREST.status(error) == 404 }
}

// MARK: - Rules

/// The filter menu: All · Used · Learned.
nonisolated enum StarMapFilter: String, CaseIterable, Identifiable, Sendable {
    case all, used, learned

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .used: "Used"
        case .learned: "Learned"
        }
    }

    /// Used: the skill ran at least once. Learned: the web's "learned" badge (`V/app/starmap/text.ts:26`): a skill
    /// Hermes wrote itself (`createdBy == "agent"`) or was taught with /learn (`"learn"`). Memories are neither.
    func matches(_ node: StarMapNode) -> Bool {
        switch self {
        case .all: true
        case .used: node.useCount > 0
        case .learned: node.kind == .skill && (node.createdBy == "agent" || node.createdBy == "learn")
        }
    }
}

/// One category of the List ("Coding · 12").
nonisolated struct StarMapSection: Identifiable, Sendable, Equatable {
    var category: String
    var title: String
    var nodes: [StarMapNode]
    var id: String { category }
    var header: String { "\(title) · \(nodes.count)" }
}

nonisolated enum StarMapRules {
    /// The skills a filter keeps, grouped by category: larger categories first (then by name), and inside each the
    /// most used first (then by name). Memory nodes are not rows here: the List shows them as the Memory cards.
    static func sections(_ nodes: [StarMapNode], filter: StarMapFilter) -> [StarMapSection] {
        var groups: [String: [StarMapNode]] = [:]
        for node in nodes where node.kind == .skill && filter.matches(node) { groups[node.category, default: []].append(node) }
        return groups.map { category, rows in
            StarMapSection(category: category, title: categoryTitle(category), nodes: rows.sorted {
                if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
                let order = $0.label.localizedCaseInsensitiveCompare($1.label)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            })
        }
        .sorted { $0.nodes.count != $1.nodes.count ? $0.nodes.count > $1.nodes.count : $0.category < $1.category }
    }

    /// The nodes the Map draws under a filter (memories are stars too, in their own "Memory" cluster).
    static func stars(_ nodes: [StarMapNode], filter: StarMapFilter) -> [StarMapNode] { nodes.filter(filter.matches) }

    /// "N skills across M categories" (`V/i18n/en.ts` starmap.subtitle).
    static func subtitle(skills: Int, categories: Int) -> String {
        "\(skills) \(skills == 1 ? "skill" : "skills") across \(categories) \(categories == 1 ? "category" : "categories")"
    }

    static func subtitle(_ sections: [StarMapSection]) -> String {
        subtitle(skills: sections.reduce(0) { $0 + $1.nodes.count }, categories: sections.count)
    }

    static func usedLine(_ count: Int) -> String {
        count <= 0 ? "Not used yet" : count == 1 ? "Used 1 time" : "Used \(count) times"
    }

    /// "software-development" → "Software Development"; a name that already has capitals or spaces is kept.
    static func categoryTitle(_ raw: String) -> String {
        let words = raw.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " || $0 == "/" })
        guard !words.isEmpty else { return "General" }
        return words.map { word in
            word.contains(where: \.isUppercase) ? String(word) : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    static func kindWord(_ node: StarMapNode) -> String {
        node.kind == .memory ? (node.memorySource == "profile" ? "Profile Memory" : "Memory") : "Skill"
    }

    static func stateWord(_ state: String) -> String { categoryTitle(state) }

    /// Who made it, nil when the gateway does not say.
    static func createdByWord(_ createdBy: String?) -> String? {
        switch createdBy {
        case nil, "": nil
        case "agent": "Hermes"
        case "learn": "Taught by You"
        case "user": "You"
        case "memory": "Memory"
        case let other?: categoryTitle(other)
        }
    }

    /// "Coding, 42 skills" (the Map's one VoiceOver element per cluster).
    static func clusterSpoken(title: String, count: Int, memory: Bool) -> String {
        memory ? "\(title), \(count) \(count == 1 ? "memory" : "memories")" : "\(title), \(count) \(count == 1 ? "skill" : "skills")"
    }

    /// A memory card's body is folded at 4 lines; Show More is offered only when that can hide something.
    static func folds(_ body: String) -> Bool {
        body.count > 140 || body.reduce(0) { $0 + ($1.isNewline ? 1 : 0) } >= 4
    }
}
