// Value types of the activity stream (docs/spec/1x-activity.md §3): a chat's subagents, its task lists and its goal.
// Pure data, no Codable: the activity is live state and never reaches the disk (§3.2).

import Foundation

// MARK: - Subagents (§4, port of V:store/subagents.ts)

nonisolated enum SubagentStatus: String, Hashable, Sendable {
    case completed, failed, interrupted, queued, running

    var isTerminal: Bool { self == .completed || self == .failed || self == .interrupted }
    var isLive: Bool { self == .running || self == .queued }
}

nonisolated struct SubagentStreamEntry: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case progress, summary, thinking, tool }
    /// Seconds since 1970.
    var at: Double
    var isError: Bool
    var kind: Kind
    var text: String
}

nonisolated struct SubagentProgress: Hashable, Sendable, Identifiable {
    var id: String
    var parentId: String?
    var goal: String
    /// The child's own stored session id.
    var sessionId: String?
    var delegationId: String?
    var model: String?
    var status: SubagentStatus
    var taskCount: Int
    var taskIndex: Int
    /// Seconds since 1970 (a roster's `started_at` wins over the first event).
    var startedAt: Double
    var updatedAt: Double
    var durationSeconds: Double?
    var inputTokens: Double?
    var outputTokens: Double?
    var toolCount: Double?
    var filesRead: [String] = []
    var filesWritten: [String] = []
    /// Newest last, at most 24 (`SubagentRules.maxStream`).
    var stream: [SubagentStreamEntry] = []
    var summary: String?
    /// The tool running now; cleared on a terminal status.
    var currentTool: String?

    var isLive: Bool { status.isLive }
    /// A row the phone made from a `delegate_task` call (no gateway id behind it, §4.6).
    var isDelegateStandIn: Bool { id.hasPrefix("delegate-tool:") }
}

/// `subagent.tail` answer for one child (§2.2).
nonisolated struct SubagentTail: Hashable, Sendable {
    var available: Bool
    var text: String
    var truncated: Bool
}

// MARK: - Tasks (§5, port of V:lib/todos.ts)

nonisolated enum TodoStatus: String, Hashable, Sendable, CaseIterable {
    case pending, inProgress = "in_progress", completed, cancelled
}

nonisolated struct TodoItem: Hashable, Sendable, Identifiable {
    var id: String
    var content: String
    var status: TodoStatus
    var parent: String? = nil
}

/// A `merge: true` write's item: content optional so a status-only patch applies to an existing row.
nonisolated struct TodoPatch: Hashable, Sendable {
    var id: String
    var content: String?
    var status: TodoStatus
}

// MARK: - Goal (§6, `session.control`)

nonisolated enum GoalStatus: String, Hashable, Sendable { case active, paused, done }
nonisolated enum GoalVerdict: String, Hashable, Sendable { case blocked, `continue`, done, skipped, wait }

nonisolated struct GoalContract: Hashable, Sendable {
    var outcome = ""
    var verification = ""
    var constraints = ""
    var boundaries = ""
    var stopWhen = ""

    var isEmpty: Bool { [outcome, verification, constraints, boundaries, stopWhen].allSatisfy { $0.isEmpty } }
}

nonisolated struct GoalGate: Hashable, Sendable {
    var command: String
    var timeoutSeconds: Int
    var maxRetries: Int
    var attempts: Int
    var lastExitCode: Int?
}

nonisolated enum WaitBarrier: Hashable, Sendable {
    case until(at: Double, reason: String)
    case session(target: String, reason: String)
    case pid(target: Int, reason: String)

    var reason: String {
        switch self {
        case .until(_, let r), .session(_, let r), .pid(_, let r): return r
        }
    }
}

nonisolated struct GoalSnapshot: Hashable, Sendable {
    var title: String
    var status: GoalStatus
    var turnsUsed: Int
    var maxTurns: Int
    var contract: GoalContract
    var subgoals: [String]
    var gates: [GoalGate]
    var createdAt: Double?
    var updatedAt: Double?
    var pausedReason: String?
    var lastVerdict: GoalVerdict?
    var lastReason: String?
    var waitBarrier: WaitBarrier?
}

nonisolated struct ControlSnapshot: Hashable, Sendable {
    var goal: GoalSnapshot?
    /// Kept raw: loop and heartbeat are out of scope this round (§14 item 2).
    var loop: JSONValue?
    var heartbeat: JSONValue?
    var revision: String
    var updatedAt: Double
}

nonisolated enum ControlCapability: String, Hashable, Sendable { case unknown, supported, unsupported }

/// One chat's goal state (V:store/session-control.ts `SessionControlEntry`).
nonisolated struct ControlEntry: Hashable, Sendable {
    var capability: ControlCapability = .unknown
    var snapshot: ControlSnapshot?
    /// The action running now (every goal action is disabled meanwhile).
    var pendingAction: String?
    /// "Action failed: …" (≤ 240 characters), dismissed with its ✕.
    var actionError: String?
}

/// `session.control`'s `dispatch` envelope: every key present, any may be null (§2.2).
nonisolated struct ControlDispatch: Hashable, Sendable {
    var type: String?
    var output: String?
    var notice: String?
    var message: String?
    var display: String?
}

nonisolated enum SteerOutcome: Hashable, Sendable {
    case queued, rejected
}

// MARK: - One chat's activity

/// Everything the activity stream knows about one chat (by runtime id), as a value snapshot (§3.2).
nonisolated struct ChatActivity: Hashable, Sendable {
    /// All rows, terminal ones included, until the next `message.start` prunes them.
    var subagents: [SubagentProgress] = []
    /// nil = no live list (the Tasks chip is absent).
    var liveTodos: [TodoItem]? = nil
    /// "Previous tasks": the last authoritative snapshot.
    var retainedTodos: [TodoItem] = []
    var control = ControlEntry()
    /// A native `subagent.*` event arrived this turn (the `delegate_task` stand-ins stop, §4.6).
    var nativeSubagentEvents = false
    /// `subagent.tail` answers by subagent id (only while a child's detail is open).
    var tails: [String: SubagentTail] = [:]

    var liveSubagents: [SubagentProgress] { subagents.filter(\.isLive) }
    var hasLiveSubagents: Bool { subagents.contains(where: \.isLive) }
    var goal: GoalSnapshot? { control.snapshot?.goal }
}

// MARK: - Strict JSON readers (the web's `str` / `num` helpers: no coercion)

nonisolated enum ActivityJSON {
    /// A string value, else "".
    static func str(_ value: JSONValue?) -> String {
        if case .string(let s)? = value { return s }
        return ""
    }

    /// A finite number (never a numeric string).
    static func num(_ value: JSONValue?) -> Double? {
        if case .number(let n)? = value, n.isFinite { return n }
        return nil
    }

    /// An integer number (JSON `Number.isInteger`).
    static func int(_ value: JSONValue?) -> Int? {
        guard let n = num(value), n.rounded() == n, abs(n) < 9.007e15 else { return nil }
        return Int(n)
    }

    static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    /// An object, or a JSON string holding one (tool args and results arrive both ways).
    static func object(_ value: JSONValue?) -> [String: JSONValue] {
        switch value {
        case .object(let o)?: return o
        case .string(let s)?:
            if let parsed = ChatJSON.parse(string: s), case .object(let o) = parsed { return o }
            return [:]
        default: return [:]
        }
    }

    /// JavaScript's number-to-string for the few places the web prints a raw number ("Timed out after 9s",
    /// "612.3s", subagent ids): integers without a decimal point, others in their shortest form.
    static func jsNumber(_ n: Double) -> String {
        if n.rounded() == n, abs(n) < 1e15 { return String(Int64(n)) }
        var text = String(n)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text
    }
}
