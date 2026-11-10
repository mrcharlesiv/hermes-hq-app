// The Kanban plugin's REST calls (docs/spec/1x-pages.md §4.1): `/api/plugins/kanban/*`, with `?board=<slug>` only
// for a board other than the server's current one ('' = current). Every write names the board it started on; a
// successful create/patch/delete/reassign/reclaim nudges the dispatcher 400 ms later (debounced per board,
// fire-and-forget).

import Foundation

nonisolated struct KanbanAPI: Sendable {
    static let base = "/api/plugins/kanban"
    let client: any GatewayClient
    let nudger: KanbanNudger

    init(client: any GatewayClient, nudger: KanbanNudger? = nil) {
        self.client = client
        self.nudger = nudger ?? KanbanNudger(client: client)
    }

    private func q(_ board: String, _ extra: [URLQueryItem] = []) -> [URLQueryItem] {
        board.isEmpty ? extra : extra + [URLQueryItem(name: "board", value: board)]
    }

    private func taskPath(_ id: String, _ tail: String = "") -> String { Self.base + "/tasks/" + PagesREST.segment(id) + tail }

    // MARK: Reads (decoded off the main thread: the board is polled every 30 s, a task can hold thousands of events)

    @concurrent
    func boards(timeout: TimeInterval? = nil) async throws -> KanbanBoards {
        KanbanBoards(json: try await PagesREST.json(client, "GET", Self.base + "/boards", timeout: timeout))
    }

    @concurrent
    func board(_ board: String) async throws -> KanbanBoard {
        KanbanBoard(json: try await PagesREST.json(client, "GET", Self.base + "/board", query: q(board)))
    }

    @concurrent
    func task(_ id: String, board: String) async throws -> KanbanTaskDetail {
        let json = try await PagesREST.json(client, "GET", taskPath(id), query: q(board))
        guard let detail = KanbanTaskDetail(json: json) else { throw PagesMessageError("The gateway sent a task this app can’t read.") }
        return detail
    }

    @concurrent
    func log(_ id: String, board: String) async throws -> (exists: Bool, content: String) {
        let json = try await PagesREST.json(client, "GET", taskPath(id, "/log"), query: q(board, [URLQueryItem(name: "tail", value: "16384")]))
        return (json["exists"]?.bool ?? false, json["content"]?.string ?? "")
    }

    @concurrent
    func profiles() async throws -> [KanbanProfile] {
        let json = try await PagesREST.json(client, "GET", Self.base + "/profiles")
        return (json["profiles"]?.array ?? []).compactMap { row in
            guard let name = row["name"]?.string else { return nil }
            return KanbanProfile(name: name, isDefault: row["is_default"]?.bool ?? false)
        }
    }

    /// The board's fallback for unassigned Ready cards (`default_assignee`, '' when unset) and New Task's preselection.
    @concurrent
    func orchestration() async throws -> (fallback: String, resolved: String) {
        let json = try await PagesREST.json(client, "GET", Self.base + "/orchestration")
        let fallback = (json["default_assignee"]?.string ?? "").pgTrim
        let resolved = (json["resolved_default_assignee"]?.string ?? "").pgTrim
        return (fallback, resolved.isEmpty ? "default" : resolved)
    }

    func attachment(_ id: String, board: String) async throws -> Data {
        try await PagesREST.send(client, "GET", Self.base + "/attachments/" + PagesREST.segment(id), query: q(board), timeout: 120)
    }

    // MARK: Writes

    struct Created: Sendable { var task: KanbanTask?; var warning: String? }

    func create(_ body: JSONValue, board: String) async throws -> Created {
        let json = try await PagesREST.json(client, "POST", Self.base + "/tasks", query: q(board), json: body)
        nudger.nudge(board)
        return Created(task: json["task"].flatMap(KanbanTask.init(json:)), warning: json["warning"]?.string)
    }

    @discardableResult
    func patch(_ id: String, _ body: JSONValue, board: String) async throws -> KanbanTask? {
        let json = try await PagesREST.json(client, "PATCH", taskPath(id), query: q(board), json: body)
        nudger.nudge(board)
        return json["task"].flatMap(KanbanTask.init(json:))
    }

    func delete(_ id: String, board: String) async throws {
        _ = try await PagesREST.send(client, "DELETE", taskPath(id), query: q(board))
        nudger.nudge(board)
    }

    func comment(_ id: String, body: String, board: String) async throws {
        _ = try await PagesREST.send(client, "POST", taskPath(id, "/comments"), query: q(board), json: ["author": "desktop", "body": .string(body)])
    }

    func reassign(_ id: String, profile: String, board: String) async throws {
        _ = try await PagesREST.send(client, "POST", taskPath(id, "/reassign"), query: q(board),
                                     json: ["profile": .string(profile), "reclaim_first": true])
        nudger.nudge(board)
    }

    func reclaim(_ id: String, board: String) async throws {
        _ = try await PagesREST.send(client, "POST", taskPath(id, "/reclaim"), query: q(board), json: .object([:]))
        nudger.nudge(board)
    }

    /// Makes a model call on the gateway: only on an explicit tap.
    func estimate(_ id: String, board: String) async throws -> String {
        let json = try await PagesREST.json(client, "POST", taskPath(id, "/estimate"), query: q(board), json: .object([:]), timeout: 120)
        guard json["ok"]?.bool == true else {
            throw PagesMessageError(json["reason"]?.string ?? "Couldn’t estimate this task.")
        }
        let tokens = json["est_tokens"]?.double ?? 0
        let compact: String
        if tokens >= 1_000_000 { compact = String(format: "%gM", (tokens / 100_000).rounded() / 10) }
        else if tokens >= 1000 { compact = String(format: "%gK", (tokens / 100).rounded() / 10) }
        else { compact = String(Int(tokens)) }
        let complexity = json["complexity"]?.string ?? ""
        return "About \(compact) tokens\(complexity.isEmpty ? "" : " · \(complexity)")"
    }
}

/// The dispatcher nudge: one `POST /dispatch` per board, 400 ms after the last successful write to it.
nonisolated final class KanbanNudger: @unchecked Sendable {
    private let client: any GatewayClient
    private let lock = NSLock()
    private var timers: [String: Task<Void, Never>] = [:]
    let delay: Duration

    init(client: any GatewayClient, delay: Duration = .milliseconds(400)) {
        self.client = client
        self.delay = delay
    }

    func nudge(_ board: String) {
        lock.lock(); defer { lock.unlock() }
        timers[board]?.cancel()
        let client = self.client, delay = self.delay
        timers[board] = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let query = board.isEmpty ? [] : [URLQueryItem(name: "board", value: board)]
            _ = try? await PagesREST.send(client, "POST", KanbanAPI.base + "/dispatch", query: query, json: .object([:]))
        }
    }
}

/// Is Kanban on? (§4.2, D-P2): the gateway's Kanban API answers and a board holds a task.
nonisolated enum KanbanAvailability: String, Codable, Sendable {
    case on        // tab 3 = Kanban; More › Workspace › Artifacts
    case unused    // API present, no tasks: tab 3 = Artifacts; More › Workspace › Kanban
    case absent    // 404/403: tab 3 = Artifacts; no Kanban anywhere

    /// nil on a transport failure (keep the last decision).
    static func probe(_ client: any GatewayClient) async -> KanbanAvailability? {
        do {
            let boards = try await KanbanAPI(client: client).boards(timeout: 10)
            let result: KanbanAvailability = boards.taskCount > 0 ? .on : .unused
            AppLog.trace("pages", "kanban availability probe: \(result.rawValue) (\(boards.taskCount) tasks)")
            return result
        } catch {
            if let status = PagesREST.status(error), status == 404 || status == 403 {
                AppLog.trace("pages", "kanban availability probe: absent (status \(status))")
                return .absent
            }
            AppLog.note("pages", "kanban availability probe failed, keeping last decision: \(PagesREST.reason(error))")
            return nil
        }
    }
}
