// Wire shapes for the Jobs, Kanban and Artifacts pages (docs/spec/1x-pages.md §3.1, §4.1, §5.2). REST only. Decoded
// leniently from `JSONValue` (unknown keys ignored, every documented key optional, spec 02 §0.2); each type is also
// `Codable` for the pages' disk caches.

import Foundation

// MARK: - Shared helpers

nonisolated extension JSONValue {
    /// A string, or a number written as one ("chat_id": 100000001 → "100000001"); nil for null/absent/empty "None".
    var pgString: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n && abs(n) < 9.007e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    /// Seconds since the epoch from a number or numeric string; nil when absent or not positive.
    var pgSeconds: Double? {
        guard let value = double, value.isFinite, value > 0 else { return nil }
        return value
    }
}

/// Paths and errors the pages share.
nonisolated enum PagesREST {
    /// One path segment, percent-encoded like `encodeURIComponent` (a job id "job/1" → "job%2F1").
    static func segment(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    /// `GatewayClient.rest`, with the live client's longer timeout when asked (Run Now waits up to 120 s, D-P6).
    static func send(_ client: any GatewayClient, _ method: String, _ path: String, query: [URLQueryItem] = [],
                     json: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        let body = try json.map { try $0.encoded() }
        if let timeout, let live = client as? LiveGatewayClient {
            return try await live.rest(method, path, query: query, body: body, timeout: timeout)
        }
        return try await client.rest(method, path, query: query, body: body)
    }

    /// The answer parsed off the main thread (a board, a task's events, run history, a 16 MiB data URL).
    @concurrent
    static func json(_ client: any GatewayClient, _ method: String, _ path: String, query: [URLQueryItem] = [],
                     json: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> JSONValue {
        let data = try await send(client, method, path, query: query, json: json, timeout: timeout)
        if data.isEmpty { return .null }
        return try JSONValue.parse(data)
    }

    /// The gateway's own reason for a refused request, in words (the web's `errText`, spec §2.2): FastAPI's
    /// `{"detail": "…"}`; an object `detail` shows its `message`; transport failures their own text.
    static func reason(_ error: Error) -> String {
        if let http = error as? HTTPError {
            if isUnknownRoute(http) { return MoreWire.olderHermes }
            return detail(http) ?? "The gateway couldn’t do that."
        }
        if let failure = error as? GatewayFailure { return failure.message }
        if let rpc = error as? RPCError { return rpc.plainReason }
        if error is CancellationError { return "Cancelled." }
        // Verify round 2: a gateway that can't be reached (a sleeping Mac, Tailscale off) is not a refusal: the app's
        // own can't-reach words, never "The gateway couldn't do that."
        if let transport = transportReason(error) { return transport }
        if let local = error as? LocalizedError, let text = local.errorDescription, !text.isEmpty { return text }
        return "The gateway couldn’t do that."
    }

    /// The words for a request that never got an answer (NSURLErrorDomain), nil for anything else.
    static func transportReason(_ error: Error) -> String? {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return nil }
        if ns.code == NSURLErrorCancelled { return "Cancelled." }
        return GatewayFailure.transport(domain: ns.domain, code: ns.code).message
    }

    /// `detail` of an HTTP error body (a string, or an object's `message`); nil when there is none.
    static func detail(_ http: HTTPError) -> String? {
        guard let body = http.body, let data = body.data(using: .utf8), let value = try? JSONValue.parse(data) else {
            let text = http.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty || text.hasPrefix("<") || text.count > 300 ? nil : text
        }
        if let detail = value["detail"] {
            if let text = detail.string, !text.isEmpty { return text }
            if let message = detail["message"]?.string, !message.isEmpty { return message }
            return nil
        }
        if let error = value["error"]?.string, !error.isEmpty { return error }
        return nil
    }

    static func status(_ error: Error) -> Int? { (error as? HTTPError)?.status }

    /// A 404/405 for the route itself (FastAPI's bare "Not Found" / "Method Not Allowed", or no reason at all), not a
    /// named thing that is gone ("Session not found" keeps its own words): this Hermes doesn't have the page.
    static func isUnknownRoute(_ http: HTTPError) -> Bool {
        guard http.status == 404 || http.status == 405 else { return false }
        guard let text = detail(http)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return true }
        return text == "not found" || text == "method not allowed"
    }

    /// The error for an answer that isn't the expected shape: an empty one (`{}`, `[]` or nothing, as a Hermes without
    /// the route may send) is "Not available on this Hermes"; anything else couldn't be read.
    static func unreadable(_ answer: JSONValue) -> PagesMessageError {
        switch answer {
        case .null: return PagesMessageError(MoreWire.olderHermes)
        case .object(let fields) where fields.isEmpty: return PagesMessageError(MoreWire.olderHermes)
        case .array(let rows) where rows.isEmpty: return PagesMessageError(MoreWire.olderHermes)
        default: return PagesMessageError("The gateway’s answer couldn’t be read.")
        }
    }

    /// Sent but not answered in time, or a gateway/edge timeout: the work may still be running server-side.
    static func isSlowAnswer(_ error: Error) -> Bool {
        if let failure = error as? GatewayFailure { return failure == .timeout }
        if let status = status(error) { return status == 502 || status == 504 || status == 524 }
        if let url = error as? URLError { return url.code == .timedOut }
        return false
    }
}

/// A reason in words, for failures the app finds itself (an unreadable answer, a refused estimate).
nonisolated struct PagesMessageError: Error, LocalizedError, Sendable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Jobs (§3.1)

nonisolated struct CronSchedule: Codable, Sendable, Hashable {
    var kind: String?
    var expr: String?
    var display: String?
    var minutes: Double?
    var runAt: String?

    init(kind: String? = nil, expr: String? = nil, display: String? = nil, minutes: Double? = nil, runAt: String? = nil) {
        self.kind = kind; self.expr = expr; self.display = display; self.minutes = minutes; self.runAt = runAt
    }

    init?(json: JSONValue?) {
        guard let json, case .object = json else { return nil }
        kind = json["kind"]?.string
        expr = json["expr"]?.string
        display = json["display"]?.string
        minutes = json["minutes"]?.double
        runAt = json["run_at"]?.string
    }
}

nonisolated struct CronOrigin: Codable, Sendable, Hashable {
    var platform: String?
    var chatId: String?
    var chatName: String?
    var threadId: String?

    init(platform: String? = nil, chatId: String? = nil, chatName: String? = nil, threadId: String? = nil) {
        self.platform = platform; self.chatId = chatId; self.chatName = chatName; self.threadId = threadId
    }

    init?(json: JSONValue?) {
        guard let json, case .object = json else { return nil }
        platform = json["platform"]?.pgString
        chatId = json["chat_id"]?.pgString
        chatName = json["chat_name"]?.pgString
        threadId = json["thread_id"]?.pgString
    }
}

nonisolated struct CronJob: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String?
    var prompt: String?
    var script: String?
    var noAgent: Bool = false
    var schedule: CronSchedule?
    var scheduleDisplay: String?
    var enabled: Bool?
    var state: String?
    var nextRunAt: String?
    var lastRunAt: String?
    var lastStatus: String?
    var lastError: String?
    var deliver: String?
    var origin: CronOrigin?
    var model: String?
    var provider: String?
    var profile: String?
    var profileName: String?
    var hermesHome: String?
    /// The job's latest run attempt (`latest_execution`, Hermes 0.21+): its status (claimed, running, completed,
    /// failed, unknown) and when the scheduler claimed it. Hermes never stores a "running" state, so this is how a
    /// run the scheduler started shows.
    var latestRunStatus: String?
    var latestRunClaimedAt: String?
    /// A bot is still working on what the latest run handed it ("queued" or "claimed"). A Bot Chat job's run closes
    /// at the handoff, so Hermes's list can't say this: `JobsStore` sets it from the Hermes HQ add-on (0.9.2+).
    var botWorking: String?

    init(id: String) { self.id = id }

    init?(json: JSONValue) {
        guard let id = json["id"]?.pgString, !id.isEmpty else { return nil }
        self.id = id
        name = json["name"]?.string
        prompt = json["prompt"]?.string
        script = json["script"]?.string
        noAgent = json["no_agent"]?.bool ?? false
        schedule = CronSchedule(json: json["schedule"])
        scheduleDisplay = json["schedule_display"]?.string
        enabled = json["enabled"]?.bool
        state = json["state"]?.string
        nextRunAt = json["next_run_at"]?.string
        lastRunAt = json["last_run_at"]?.string
        lastStatus = json["last_status"]?.string
        lastError = json["last_error"]?.string
        deliver = json["deliver"]?.string
        origin = CronOrigin(json: json["origin"])
        model = json["model"]?.string
        provider = json["provider"]?.string
        profile = json["profile"]?.string
        profileName = json["profile_name"]?.string
        hermesHome = json["hermes_home"]?.string
        latestRunStatus = json["latest_execution"]?["status"]?.string
        latestRunClaimedAt = json["latest_execution"]?["claimed_at"]?.string
    }

    /// The profile that owns the job: per-job calls name it (§3.1).
    var owner: String {
        if let profile, !profile.isEmpty { return profile }
        if let profileName, !profileName.isEmpty { return profileName }
        return "default"
    }

    /// `<profile>|<id>`: ids repeat across profiles (§3.2).
    var key: String { owner + "|" + id }

    static func list(_ json: JSONValue) -> [CronJob] {
        let rows = json.array ?? json["jobs"]?.array ?? []
        return rows.compactMap(CronJob.init(json:))
    }
}

/// One row of a job's run history (`GET /api/cron/jobs/<id>/runs`).
nonisolated struct CronRun: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var source: String?
    var title: String?
    var preview: String?
    var messageCount: Int?
    var startedAt: Double?
    var lastActive: Double?
    var endedAt: Double?
    var isActive: Bool = false
    var profile: String?

    init(id: String) { self.id = id }

    init?(json: JSONValue) {
        guard let id = json["id"]?.pgString, !id.isEmpty else { return nil }
        self.id = id
        source = json["source"]?.string
        title = json["title"]?.string
        preview = json["preview"]?.string
        messageCount = json["message_count"]?.int
        startedAt = json["started_at"]?.pgSeconds
        lastActive = json["last_active"]?.pgSeconds
        endedAt = json["ended_at"]?.pgSeconds
        isActive = json["is_active"]?.bool ?? false
        profile = json["profile"]?.string
    }

    static func list(_ json: JSONValue) -> [CronRun] {
        (json["runs"]?.array ?? json.array ?? []).compactMap(CronRun.init(json:))
    }

    /// What tapping the row opens (§3.7).
    enum Opens: Equatable, Sendable { case chat, document(stem: String), nothing }
    var opens: Opens {
        guard source == "cron_output" else { return .chat }
        // cron_output:<job>:<stem> | cron_output:<job>:exec:<n> | cron_output:<job>:latest
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "cron_output" else { return .nothing }
        if parts.count >= 4 && parts[2] == "exec" { return .nothing }
        let stem = parts[2...].joined(separator: ":")
        if stem == "latest" || stem.isEmpty { return .nothing }
        return .document(stem: stem)
    }
}

// MARK: - Kanban (§4.1)

nonisolated struct KanbanDiagnosticAction: Codable, Sendable, Hashable {
    var kind: String
    var label: String
    var command: String?
}

nonisolated struct KanbanDiagnostic: Codable, Sendable, Hashable {
    var kind: String
    var severity: String
    var title: String
    var detail: String
    var count: Int
    var lastSeenAt: Double?
    var actions: [KanbanDiagnosticAction]

    init?(json: JSONValue) {
        guard case .object = json else { return nil }
        kind = json["kind"]?.string ?? ""
        severity = json["severity"]?.string ?? "warning"
        title = json["title"]?.string ?? ""
        detail = json["detail"]?.pgString ?? ""
        count = json["count"]?.int ?? 1
        lastSeenAt = json["last_seen_at"]?.pgSeconds
        actions = (json["actions"]?.array ?? []).compactMap { action in
            guard let kind = action["kind"]?.string else { return nil }
            return KanbanDiagnosticAction(kind: kind, label: action["label"]?.string ?? kind,
                                          command: action["payload"]?["command"]?.pgString)
        }
    }
}

nonisolated struct KanbanTask: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var status: String
    var assignee: String?
    var priority: Int?
    var createdAt: Double?
    var completedAt: Double?
    var startedAt: Double?
    var currentRunStartedAt: Double?
    var blockKind: String?
    var commentCount: Int?
    var body: String?
    var latestSummary: String?
    var result: String?
    var createdBy: String?
    var workspacePath: String?
    var workspaceKind: String?
    var modelOverride: String?
    var reasoningEffort: String?
    var lastFailureError: String?
    var consecutiveFailures: Int?
    var diagnostics: [KanbanDiagnostic]?
    /// Set by an optimistic edit on the phone (never by the gateway): R21's "still exactly what this write left".
    var editToken: Int = 0

    init(id: String, title: String, status: String) { self.id = id; self.title = title; self.status = status }

    init?(json: JSONValue) {
        guard let id = json["id"]?.pgString, !id.isEmpty else { return nil }
        self.id = id
        title = json["title"]?.string ?? ""
        status = json["status"]?.string ?? "todo"
        assignee = json["assignee"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        priority = json["priority"]?.int
        createdAt = json["created_at"]?.pgSeconds
        completedAt = json["completed_at"]?.pgSeconds
        startedAt = json["started_at"]?.pgSeconds
        currentRunStartedAt = json["current_run_started_at"]?.pgSeconds
        blockKind = json["block_kind"]?.string
        commentCount = json["comment_count"]?.int
        body = json["body"]?.string
        latestSummary = json["latest_summary"]?.string
        result = json["result"]?.string
        createdBy = json["created_by"]?.string
        workspacePath = json["workspace_path"]?.string
        workspaceKind = json["workspace_kind"]?.string
        modelOverride = json["model_override"]?.string
        reasoningEffort = json["reasoning_effort"]?.string
        lastFailureError = json["last_failure_error"]?.string
        consecutiveFailures = json["consecutive_failures"]?.int
        diagnostics = json["diagnostics"]?.array?.compactMap(KanbanDiagnostic.init(json:))
    }
}

nonisolated struct KanbanColumn: Codable, Sendable, Hashable {
    var name: String
    var tasks: [KanbanTask]
}

nonisolated struct KanbanBoard: Codable, Sendable, Hashable {
    var columns: [KanbanColumn]
    var assignees: [String] = []
    var latestEventId: Int?

    init(columns: [KanbanColumn], assignees: [String] = [], latestEventId: Int? = nil) {
        self.columns = columns; self.assignees = assignees; self.latestEventId = latestEventId
    }

    init(json: JSONValue) {
        columns = (json["columns"]?.array ?? []).compactMap { column in
            guard let name = column["name"]?.string else { return nil }
            return KanbanColumn(name: name, tasks: (column["tasks"]?.array ?? []).compactMap(KanbanTask.init(json:)))
        }
        assignees = (json["assignees"]?.array ?? []).compactMap(\.string)
        latestEventId = json["latest_event_id"]?.int
    }

    var allTasks: [KanbanTask] { columns.flatMap(\.tasks) }
    func task(_ id: String) -> KanbanTask? { allTasks.first { $0.id == id } }
}

nonisolated struct KanbanBoardMeta: Codable, Sendable, Hashable, Identifiable {
    var slug: String
    var name: String?
    var total: Int?
    var isCurrent: Bool = false
    var id: String { slug }
}

nonisolated struct KanbanBoards: Codable, Sendable, Hashable {
    var boards: [KanbanBoardMeta]
    var current: String

    init(boards: [KanbanBoardMeta], current: String) { self.boards = boards; self.current = current }

    init(json: JSONValue) {
        boards = (json["boards"]?.array ?? []).compactMap { meta in
            guard let slug = meta["slug"]?.string else { return nil }
            return KanbanBoardMeta(slug: slug, name: meta["name"]?.string, total: meta["total"]?.int,
                                   isCurrent: meta["is_current"]?.bool ?? false)
        }
        current = json["current"]?.string ?? boards.first(where: \.isCurrent)?.slug ?? ""
    }

    /// Σ total (§4.2's "a board holds a task").
    var taskCount: Int { boards.reduce(0) { $0 + ($1.total ?? 0) } }
}

nonisolated struct KanbanProfile: Codable, Sendable, Hashable {
    var name: String
    var isDefault: Bool = false
}

nonisolated struct KanbanComment: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var author: String
    var body: String
    var createdAt: Double?
}

nonisolated struct KanbanEvent: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var kind: String
    var payload: JSONValue
    var createdAt: Double?
}

nonisolated struct KanbanTaskRun: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var profile: String?
    var status: String
    var outcome: String?
    var summary: String?
    var error: String?
    var startedAt: Double?
    var endedAt: Double?
}

nonisolated struct KanbanAttachment: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var filename: String
    var size: Int?
}

nonisolated struct KanbanTaskDetail: Sendable, Hashable {
    var task: KanbanTask
    var comments: [KanbanComment]
    var events: [KanbanEvent]
    var runs: [KanbanTaskRun]
    /// nil when the plugin's answer has no `attachments` key (an older plugin, §4.6.9).
    var attachments: [KanbanAttachment]?
    var parents: [String]
    var children: [String]
    var linkTitles: [String: String]

    init?(json: JSONValue) {
        guard let taskJSON = json["task"], let task = KanbanTask(json: taskJSON) else { return nil }
        self.task = task
        comments = (json["comments"]?.array ?? []).compactMap { item in
            guard let id = item["id"]?.pgString else { return nil }
            return KanbanComment(id: id, author: item["author"]?.string ?? "", body: item["body"]?.string ?? "",
                                 createdAt: item["created_at"]?.pgSeconds)
        }
        events = (json["events"]?.array ?? []).compactMap { item in
            guard let id = item["id"]?.pgString else { return nil }
            return KanbanEvent(id: id, kind: item["kind"]?.string ?? "", payload: item["payload"] ?? .null,
                               createdAt: item["created_at"]?.pgSeconds)
        }
        runs = (json["runs"]?.array ?? []).compactMap { item in
            guard let id = item["id"]?.pgString else { return nil }
            return KanbanTaskRun(id: id, profile: item["profile"]?.string, status: item["status"]?.string ?? "",
                                 outcome: item["outcome"]?.string, summary: item["summary"]?.string,
                                 error: item["error"]?.string, startedAt: item["started_at"]?.pgSeconds,
                                 endedAt: item["ended_at"]?.pgSeconds)
        }
        if let list = json["attachments"], !list.isNull {
            attachments = (list.array ?? []).compactMap { item in
                guard let id = item["id"]?.pgString else { return nil }
                return KanbanAttachment(id: id, filename: item["filename"]?.string ?? id, size: item["size"]?.int)
            }
        }
        parents = (json["links"]?["parents"]?.array ?? []).compactMap(\.pgString)
        children = (json["links"]?["children"]?.array ?? []).compactMap(\.pgString)
        var titles: [String: String] = [:]
        for linked in json["link_tasks"]?.array ?? [] {
            if let id = linked["id"]?.pgString, let title = linked["title"]?.string { titles[id] = title }
        }
        linkTitles = titles
    }
}

// MARK: - Artifacts (§5)

/// A session row the Artifacts index reads (`GET /api/profiles/sessions`).
nonisolated struct ArtifactSessionRow: Codable, Sendable, Hashable {
    var id: String
    var profile: String?
    var title: String?
    var preview: String?
    var messageCount: Int?
    var lastActive: Double?
    var startedAt: Double?
    /// `cwd` as sent: nil when the row has no `cwd` key, "" when present and empty (§5.4 phone fixes).
    var cwd: String?
    var cwdPresent: Bool = false

    init(id: String, profile: String? = nil, title: String? = nil, preview: String? = nil, messageCount: Int? = nil,
         lastActive: Double? = nil, startedAt: Double? = nil, cwd: String? = nil, cwdPresent: Bool = false) {
        self.id = id; self.profile = profile; self.title = title; self.preview = preview; self.messageCount = messageCount
        self.lastActive = lastActive; self.startedAt = startedAt; self.cwd = cwd; self.cwdPresent = cwdPresent
    }

    init?(json: JSONValue, listedProfile: String?) {
        guard let id = json["id"]?.pgString, !id.isEmpty else { return nil }
        self.id = id
        let stamped = json["profile"]?.string ?? json["profile_name"]?.string
        profile = (stamped?.isEmpty == false ? stamped : nil) ?? listedProfile
        title = json["title"]?.string
        preview = json["preview"]?.string
        messageCount = json["message_count"]?.int
        lastActive = json["last_active"]?.double
        startedAt = json["started_at"]?.double
        if let object = json.object, let value = object["cwd"] {
            cwdPresent = true
            cwd = value.string ?? ""
        }
    }

    /// title → preview → "Untitled session" (`artifact-utils.ts:115-117`).
    var displayTitle: String {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !t.isEmpty { return t }
        let p = preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return p.isEmpty ? "Untitled session" : p
    }

    /// The row says it has no working directory (the key is present and empty).
    var lacksCwd: Bool { cwdPresent && (cwd?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }

    var recency: Double { max(lastActive ?? 0, startedAt ?? 0) }
}

nonisolated struct ArtifactRecord: Codable, Sendable, Hashable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable { case image, file, link }
    var id: String            // "<profile>\u{1F}<sessionId>:<value>" (profile "default" when unset; ids repeat across profiles)
    var kind: Kind
    var value: String
    var href: String
    var label: String
    var sessionId: String
    var profile: String?
    var sessionTitle: String
    var timestamp: Double     // ms
    /// [morepages] How many times this chat named the file or link (3x-morepages §2, D-M2): the row shows "×N" past 1.
    var repeats: Int = 1
}

// [morepages] An index kept by an older build has no `repeats`: it reads as 1 (in an extension, so the memberwise
// initialiser stays).
nonisolated extension ArtifactRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        value = try c.decode(String.self, forKey: .value)
        href = try c.decode(String.self, forKey: .href)
        label = try c.decode(String.self, forKey: .label)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
        sessionTitle = try c.decode(String.self, forKey: .sessionTitle)
        timestamp = try c.decode(Double.self, forKey: .timestamp)
        repeats = max(1, (try? c.decodeIfPresent(Int.self, forKey: .repeats)) ?? 1)
    }

    /// "×3" on a file or link row named more than once; nil for one mention and for images (the grid is its own list).
    var repeatBadge: String? { kind != .image && repeats > 1 ? "×\(repeats)" : nil }
    /// The badge in words, for VoiceOver and the top of the row's ⋯ menu: "Mentioned 3 times" ([pins] in one chat or
    /// several: a file at a full path is one row for every chat that named it).
    var repeatSpoken: String? { kind != .image && repeats > 1 ? "Mentioned \(repeats) times" : nil }
}
