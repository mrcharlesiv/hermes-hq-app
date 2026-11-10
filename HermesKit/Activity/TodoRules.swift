// Task-list rules (docs/spec/1x-activity.md §5.2), ported from V:lib/todos.ts and V:store/todos.ts. `TodoState` is one
// chat's live list, its retained ("Previous tasks") list and the revision watermark; the 4 s linger after a list
// finishes is a deadline the store's clock checks (injectable for tests).

import Foundation

nonisolated enum TodoRules {
    static let finishedLinger: Double = 4

    static func isTodoTool(_ name: String?) -> Bool { name == "todo" || name == "todo_list" }

    static func active(_ todos: [TodoItem]) -> Bool {
        todos.contains { $0.status == .pending || $0.status == .inProgress }
    }

    // MARK: Parse

    private static func status(_ value: JSONValue?) -> TodoStatus? {
        guard case .string(let s)? = value else { return nil }
        return TodoStatus(rawValue: s)
    }

    /// `String(item.id ?? '')`: strings as they are, numbers in JavaScript's form.
    private static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s)?: return s
        case .number(let n)?: return ActivityJSON.jsNumber(n)
        case .bool(let b)?: return b ? "true" : "false"
        default: return ""
        }
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func parseArray(_ values: [JSONValue]) -> [TodoItem] {
        values.compactMap { value in
            guard case .object(let item) = value, let status = status(item["status"]) else { return nil }
            let id = trimmed(text(item["id"])), content = trimmed(text(item["content"])), parent = trimmed(text(item["parent"]))
            guard !id.isEmpty, !content.isEmpty else { return nil }
            return TodoItem(id: id, content: content, status: status, parent: parent.isEmpty || parent == id ? nil : parent)
        }
    }

    private static func parsePatchArray(_ values: [JSONValue]) -> [TodoPatch] {
        values.compactMap { value in
            guard case .object(let item) = value, let status = status(item["status"]) else { return nil }
            let id = trimmed(text(item["id"]))
            guard !id.isEmpty else { return nil }
            let content = trimmed(text(item["content"]))
            return TodoPatch(id: id, content: content.isEmpty ? nil : content, status: status)
        }
    }

    /// An array, a JSON string of one, or `{todos: …}` (≤ 2 levels deep); nil when it is none of them.
    static func parseTodos(_ value: JSONValue?, depth: Int = 0) -> [TodoItem]? {
        guard depth <= 2, let value else { return nil }
        switch value {
        case .array(let a): return parseArray(a)
        case .string(let s):
            guard !trimmed(s).isEmpty, let parsed = ChatJSON.parse(string: s) else { return nil }
            return parseTodos(parsed, depth: depth + 1)
        case .object(let o):
            guard let todos = o["todos"] else { return nil }
            return parseTodos(todos, depth: depth + 1)
        default: return nil
        }
    }

    static func parsePatch(_ value: JSONValue?, depth: Int = 0) -> [TodoPatch]? {
        guard depth <= 2, let value else { return nil }
        switch value {
        case .array(let a): return parsePatchArray(a)
        case .string(let s):
            guard !trimmed(s).isEmpty, let parsed = ChatJSON.parse(string: s) else { return nil }
            return parsePatch(parsed, depth: depth + 1)
        case .object(let o):
            guard let todos = o["todos"] else { return nil }
            return parsePatch(todos, depth: depth + 1)
        default: return nil
        }
    }

    /// `parseTodoRevision`: a safe non-negative integer `revision`, looked for in the value and its `result`.
    static func parseRevision(_ value: JSONValue?, depth: Int = 0) -> Int? {
        guard depth <= 2, let value else { return nil }
        switch value {
        case .string(let s):
            guard !trimmed(s).isEmpty, let parsed = ChatJSON.parse(string: s) else { return nil }
            return parseRevision(parsed, depth: depth + 1)
        case .object(let o):
            if let r = ActivityJSON.int(o["revision"]), r >= 0 { return r }
            return o["result"] != nil ? parseRevision(o["result"], depth: depth + 1) : nil
        default: return nil
        }
    }

    // MARK: Order and merge

    /// Parents before children, `[item, depth]`; dangling parents go to the top level and cycle members are appended
    /// flat (`todoTree`).
    static func tree(_ todos: [TodoItem]) -> [(item: TodoItem, depth: Int)] {
        let ids = Set(todos.map(\.id))
        var kids: [String: [TodoItem]] = [:]
        var roots: [TodoItem] = []
        for t in todos {
            if let parent = t.parent, ids.contains(parent), parent != t.id { kids[parent, default: []].append(t) } else { roots.append(t) }
        }
        var out: [(TodoItem, Int)] = []
        var seen = Set<String>()
        func walk(_ item: TodoItem, _ depth: Int) {
            guard seen.insert(item.id).inserted else { return }
            out.append((item, depth))
            for kid in kids[item.id] ?? [] { walk(kid, depth + 1) }
        }
        for root in roots { walk(root, 0) }
        for t in todos where !seen.contains(t.id) {
            seen.insert(t.id)
            out.append((t, 0))
        }
        return out.map { (item: $0.0, depth: $0.1) }
    }

    /// `TodoStore.write(merge=True)`: update by id, append unknown ids.
    static func merge(_ current: [TodoItem], _ patch: [TodoPatch]) -> [TodoItem] {
        var next = current
        var index: [String: Int] = [:]
        for (i, item) in next.enumerated() { index[item.id] = i }
        for p in patch {
            if let i = index[p.id] {
                if let content = p.content, !content.isEmpty { next[i].content = content }
                next[i].status = p.status
            } else {
                let content = p.content.map(trimmed) ?? ""
                next.append(TodoItem(id: p.id, content: content.isEmpty ? "(no description)" : content, status: p.status))
                index[p.id] = next.count - 1
            }
        }
        return next
    }

    /// `nextTodosFromToolEvent`: a full list from `todos` / `result`, else `args` (a merge patch when `merge: true`).
    static func nextTodos(current: [TodoItem], payload: JSONValue) -> [TodoItem]? {
        if let full = parseTodos(payload["todos"]) ?? parseTodos(payload["result"]) { return full }
        let args = payload["args"] ?? payload["arguments"]
        if case .object(let o)? = args, o["merge"] == .bool(true) {
            guard let patch = parsePatch(args), !patch.isEmpty else { return nil }
            return merge(current, patch)
        }
        return parseTodos(args)
    }

    // MARK: Words

    /// "Tasks 1/3": every item counts, cancelled included (V:app/chat/composer/status-stack/index.tsx:86-88).
    static func chipWords(_ todos: [TodoItem], previous: Bool) -> String {
        let done = todos.filter { $0.status == .completed }.count
        return "\(previous ? "Previous tasks" : "Tasks") \(done)/\(todos.count)"
    }
}

/// One chat's task lists (V:store/todos.ts for one session).
nonisolated struct TodoState: Hashable, Sendable {
    /// nil = no live list.
    private(set) var live: [TodoItem]?
    private(set) var retained: [TodoItem] = []
    private(set) var revision: Int?
    /// When a finished live list goes away (seconds since 1970).
    private(set) var dropAt: Double?

    /// `acceptRevision`: an older versioned snapshot is ignored; an unversioned one applies and leaves the watermark.
    private mutating func accept(_ revision: Int?) -> Bool {
        guard let revision else { return true }
        if let current = self.revision, revision < current { return false }
        self.revision = revision
        return true
    }

    /// `setSessionTodos`.
    @discardableResult
    mutating func set(_ todos: [TodoItem], revision: Int?, now: Double) -> Bool {
        let before = self
        guard accept(revision) else { return false }
        if revision != nil { retained = todos }
        live = todos
        dropAt = TodoRules.active(todos) ? nil : now + TodoRules.finishedLinger
        return self != before
    }

    /// The linger is over: the finished live list goes (the retained one stays).
    @discardableResult
    mutating func expire(now: Double) -> Bool {
        guard let dropAt, now >= dropAt else { return false }
        live = nil
        self.dropAt = nil
        return true
    }

    /// Turn end: a still-active live list is dropped (`clearActiveSessionTodos`).
    @discardableResult
    mutating func dropActive() -> Bool {
        guard let live, TodoRules.active(live) else { return false }
        self.live = nil
        dropAt = nil
        return true
    }

    /// Stop: everything goes, the watermark too.
    @discardableResult
    mutating func clear() -> Bool {
        let before = self
        self = TodoState()
        return self != before
    }

    /// `restoreSessionTodosFromSnapshot` (`session.resume` / `activate` `todo_state`): an empty list at revision 0 or
    /// none is not a snapshot; a running chat applies it; an idle one applies only a finished list, otherwise it keeps
    /// the retained copy and drops the live one.
    ///
    /// Native (verify round 2): an idle chat with no live list on screen takes a finished list straight as Previous
    /// tasks (folded). The web made it the live list — opened, then folding into Previous tasks 4 s later — so every
    /// open of such a chat slid the transcript up under an opened card and back down again (the owner's "bounces
    /// before settling", build 223). A finished list already showing (its turn just ended on screen) keeps its linger.
    @discardableResult
    mutating func restore(_ snapshot: JSONValue, running: Bool, now: Double) -> Bool {
        guard let todos = TodoRules.parseTodos(snapshot) else { return false }
        let revision = TodoRules.parseRevision(snapshot)
        if todos.isEmpty && (revision == nil || revision == 0) { return false }
        if running || (!TodoRules.active(todos) && live != nil) {
            return set(todos, revision: revision, now: now)
        }
        let before = self
        guard accept(revision) else { return false }
        if revision != nil { retained = todos }
        live = nil
        dropAt = nil
        return self != before
    }
}
