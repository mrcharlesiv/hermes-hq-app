// [tasks] The Tasks page's data (docs/tasks.md): the list painted from disk at once, then read from the add-on
// (`?since=<rev>` answers `unchanged` when nothing moved); optimistic writes that carry the task's rev, re-sent on a 409
// when the other edit touched other fields, or giving way to it when it touched the same ones (TodoEdits.resolve).
// Read on appear, on foreground, after a task push and after each write.

import Foundation
import Observation

/// The add-on's routes.
nonisolated struct TasksAPI: Sendable {
    static let base = PushPolicy.route + "/tasks"
    let client: any GatewayClient

    private func path(_ id: String) -> String { Self.base + "/" + PagesREST.segment(id) }

    @concurrent
    func list(since: Int?) async throws -> TodoListAnswer {
        let query = since.map { [URLQueryItem(name: "since", value: String($0))] } ?? []
        let data = try await PagesREST.send(client, "GET", Self.base, query: query)
        return try JSONDecoder().decode(TodoListAnswer.self, from: data)
    }

    @concurrent
    func create(_ fields: [String: JSONValue]) async throws -> TodoTask {
        try Self.task(try await PagesREST.send(client, "POST", Self.base, json: .object(fields)))
    }

    /// [tasks-first] `POST /tasks/{id}/attach` (hermes-hq-push 0.9.53): your own link, or a file as base64. The
    /// answer is the task with it in `made`.
    @concurrent
    func attach(_ id: String, _ body: [String: JSONValue]) async throws -> TodoTask {
        try Self.task(try await PagesREST.send(client, "POST", path(id) + "/attach", json: .object(body), timeout: 120))
    }

    /// Encodes a file attachment as base64 off the main actor before sending `POST /tasks/{id}/attach`.
    @concurrent
    func attachFile(_ id: String, name: String, data: Data) async throws -> TodoTask {
        let encoded = data.base64EncodedString()
        return try await attach(id, ["kind": "file", "name": .string(name), "data": .string(encoded)])
    }

    /// `DELETE /tasks/{id}/made/{made}`: takes a file, link or note off the task.
    @concurrent
    func detach(_ id: String, made: String) async throws -> TodoTask {
        try Self.task(try await PagesREST.send(client, "DELETE", path(id) + "/made/" + made))
    }

    @concurrent
    func patch(_ id: String, rev: Int, fields: [String: JSONValue]) async throws -> TodoTask {
        var body = fields
        body["rev"] = .number(Double(rev))
        return try Self.task(try await PagesREST.send(client, "PATCH", path(id), json: .object(body)))
    }

    @concurrent
    func delete(_ id: String) async throws {
        _ = try await PagesREST.send(client, "DELETE", path(id))
    }

    @concurrent
    func settings() async throws -> TodoSettings {
        try JSONDecoder().decode(TodoSettings.self, from: try await PagesREST.send(client, "GET", Self.base + "/settings"))
    }

    @concurrent
    func saveSettings(_ settings: TodoSettings) async throws -> TodoSettings {
        let body = try JSONValue.parse(JSONEncoder().encode(settings))
        let data = try await PagesREST.send(client, "PUT", Self.base + "/settings", json: body)
        return (try? JSONDecoder().decode(TodoSettings.self, from: data)) ?? settings
    }

    /// `PUT /tasks/sections`: your sections, the whole list in order (hermes-hq-push 0.9.36). One left out is deleted;
    /// its tasks stay, under no section.
    @concurrent
    func saveSections(_ sections: [TodoUserSection]) async throws -> [TodoUserSection] {
        // [task-lists] Each list whole (colour, icon, bot, rules): 0.9.55 keeps them, an older add-on reads only id
        // and name. `checked_at` is the gateway's own.
        let list = JSONValue.array(sections.map { section -> JSONValue in
            guard case .object(var object)? = try? JSONValue.parse(JSONEncoder().encode(section)) else {
                return .object(["id": .string(section.id), "name": .string(section.name)])
            }
            object["id"] = .string(TodoIDs.isLocal(section.id) ? "" : section.id)
            object["checked_at"] = nil
            return .object(object)
        })
        let data = try await PagesREST.send(client, "PUT", Self.base + "/sections", json: .object(["sections": list]))
        struct Answer: Decodable { var sections: [TodoUserSection] }
        return try JSONDecoder().decode(Answer.self, from: data).sections
    }

    /// [task-lists] `POST /tasks/offers/{id}` (hermes-hq-push 0.9.55): your tap on a bot's offer. `list` false with
    /// `accept` is "Add, No List".
    @concurrent
    func answerOffer(_ id: String, action: TodoOfferAction, list: Bool = true, goal: (plan: Bool, inGoal: Bool)? = nil) async throws -> TodoOfferAnswer {
        var fields: [String: JSONValue] = ["action": .string(action.rawValue), "list": .bool(list)]
        // [goals step 3] A goal's offer (0.9.66): "Keep the Goal, No Plan" and "Just Tasks". Sent only for one, so a
        // list offer's answer is as it was.
        if let goal { fields["plan"] = .bool(goal.plan); fields["in_goal"] = .bool(goal.inGoal) }
        let body: JSONValue = .object(fields)
        let data = try await PagesREST.send(client, "POST", Self.base + "/offers/" + PagesREST.segment(id), json: body)
        return try JSONDecoder().decode(TodoOfferAnswer.self, from: data)
    }

    /// `POST /tasks/prep-job/{profile}`: that bot's "Task prep" scheduled job made, or removed, to match its open prep
    /// tasks (hermes-hq-push 0.9.32). A failure is only logged: the bot's own task tools reconcile it again.
    @concurrent
    func reconcilePrep(_ profile: String) async {
        do { _ = try await PagesREST.send(client, "POST", Self.base + "/prep-job/" + PagesREST.segment(profile), timeout: 30) }
        catch { AppLog.note("tasks", "prep job for \(profile) not reconciled: \(PagesREST.reason(error))") }
    }

    /// [goals step 5] `/status`: whether this add-on draws Goal Pages (0.9.66's `goal_pages`); nil when it couldn't be read.
    @concurrent
    func addOnDrawsGoalPages() async -> Bool? {
        guard let data = try? await PagesREST.send(client, "GET", PushPolicy.route + "/status", timeout: 15),
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (body["goal_pages"] as? Bool) == true
    }

    /// [goals step 5] `GET /goals/{id}/page`: the goal's Goal Page (hermes-hq-push 0.9.66), HTML the add-on draws.
    @concurrent
    func goalPage(_ id: String, names: [String: String]) async throws -> Data {
        let object = JSONValue.object(names.mapValues { .string($0) })
        let names = (try? object.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return try await PagesREST.send(client, "GET", GoalsAPI.base + "/" + PagesREST.segment(id) + "/page",
                                        query: [URLQueryItem(name: "names", value: names)], timeout: 20)
    }

    /// `/status`: whether this add-on serves Tasks (0.9.32's `tasks`); nil when it couldn't be read.
    @concurrent
    func addOnServesTasks() async -> Bool? {
        guard let data = try? await PagesREST.send(client, "GET", PushPolicy.route + "/status", timeout: 15),
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return PushPolicy.tasks(body)
    }

    /// `GET /tasks/{id}/page`: the task's Task Page (hermes-hq-push 0.9.38), HTML drawn from the task and what its bot
    /// wrote on it. `names`: the bots' names as the app shows them, by profile.
    @concurrent
    func page(_ id: String, names: [String: String]) async throws -> Data {
        let object = JSONValue.object(names.mapValues { .string($0) })
        let names = (try? object.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return try await PagesREST.send(client, "GET", path(id) + "/page", query: [URLQueryItem(name: "names", value: names)], timeout: 20)
    }

    /// A route's task answer: the task itself, or `{task: …}`.
    static func task(_ data: Data) throws -> TodoTask {
        if let task = try? JSONDecoder().decode(TodoTask.self, from: data) { return task }
        let json = try JSONValue.parse(data)
        // A 409's `{task}`, as FastAPI sends it (`{"detail": {"task": …}}`) or bare.
        for inner in [json["task"], json["detail"]?["task"]].compactMap({ $0 }) {
            if let task = try? JSONDecoder().decode(TodoTask.self, from: inner.encoded()) { return task }
        }
        throw PagesMessageError("The gateway sent a task this app can’t read.")
    }

    /// A 409's current task (`{detail: {task: <current>}}`), nil for any other failure.
    static func conflict(_ error: Error) -> TodoTask? {
        guard let http = error as? HTTPError, http.status == 409, let body = http.body?.data(using: .utf8) else { return nil }
        return try? task(body)
    }
}

/// What the disk cache keeps.
nonisolated struct TodoSnapshot: Codable, Sendable {
    var rev: Int
    var tasks: [TodoTask]
    var settings: TodoSettings
    var sections: [TodoUserSection]?
    var pages: Bool?
    var ideas: Int?
    var fields: Bool?
    var files: Bool?
    var lists: Bool?
    var offers: [TodoOffer]?
    /// [goals] nil: the add-on keeps no goals.
    var goals: [Goal]?
    /// [goals step 3] The add-on puts bots on goals (0.9.66), and draws Goal Pages.
    var goalBots: Bool?
    var goalPages: Bool?
    /// [goals step 3] Goals' offers seen here (a goal's chat card is told only the offer's id; this keeps what it was
    /// after the gateway lets it go).
    var seenOffers: [TodoOffer]?
    /// Custom interval / after-completion recurrence supported by the add-on.
    var customRepeat: Bool?
}

/// `POST /tasks/offers/{id}`'s answer.
nonisolated struct TodoOfferAnswer: Decodable, Sendable {
    var rev: Int
    var offer: TodoOffer
    var sections: [TodoUserSection]
    /// [goals step 3] Every goal after the answer (0.9.66; an older add-on sends none).
    var goals: [Goal]?
}

/// A task mutation queued while the gateway was unreachable (replayed in FIFO order on reconnect / refresh).
nonisolated struct TodoPendingOp: Codable, Equatable, Sendable, Identifiable {
    enum Kind: Codable, Equatable, Sendable {
        case add(localID: String, fields: [String: JSONValue])
        case patch(id: String, fields: [String: JSONValue], touch: Bool)
        case delete(id: String)
        case saveSections(sections: [TodoUserSection])
        case answerOffer(id: String, action: TodoOfferAction, list: Bool, goalPlan: Bool?, goalInGoal: Bool?)
    }

    var id: String = UUID().uuidString
    var kind: Kind
    var createdAt: TimeInterval = Date().timeIntervalSince1970
    var baseFields: [String: JSONValue]? = nil
}

@MainActor @Observable
final class TasksStore {
    let api: TasksAPI
    let account: GatewayAccount
    let directory: URL?
    var readOnlyGateway = false { didSet { TodoTaskStates.noteReadOnly(readOnlyGateway) } }

    /// Every task (optimistic edits applied). [chat-mark-done] The chat's close cards read a copy (`TodoTaskStates`).
    private(set) var tasks: [TodoTask] = [] { didSet { TodoTaskStates.note(tasks) } }
    private(set) var settings = TodoSettings() {
        didSet { if oldValue.enabled != settings.enabled { onEnabledChanged?(settings.enabled) } }
    }
    /// Tasks was turned on or off (here, on another device, or read back after a failed save).
    @ObservationIgnored var onEnabledChanged: ((Bool) -> Void)?
    private(set) var rev = 0
    /// Your own sections, in order.
    private(set) var sections: [TodoUserSection] = []
    /// The add-on keeps sections (0.9.36+); an older one is asked to update before the first is made.
    private(set) var sectionsSupported = false
    /// The add-on draws Task Pages (0.9.38+): a task a bot works on offers its page.
    private(set) var pagesSupported = false
    /// [tasks-first] The add-on keeps a task's priority, tags, alert and start day, and a shared task can repeat
    /// (0.9.53+): the task's page shows those rows only then (an older add-on would drop them on the floor).
    private(set) var fieldsSupported = false
    /// The add-on takes your own files and links on a task (0.9.53+).
    private(set) var filesSupported = false
    /// [task-lists] The add-on keeps a list's colour, icon, bot and rules, and bots' offers (0.9.55+): the Edit List
    /// sheet shows those rows only then.
    private(set) var listsSupported = false
    /// Bots' offers of a list or a batch of tasks: the ones that wait, and the last day's answered ones.
    private(set) var offers: [TodoOffer] = []
    /// [goals] Every goal, any status (optimistic edits applied); docs/goals.md.
    private(set) var goals: [Goal] = [] { didSet { TodoOfferStates.noteGoals(goals) } }
    /// [goals] The add-on keeps goals (`goals` in `GET /tasks`). Without it the page offers the update in Goals' place
    /// (`goalsNeedAddOn`). Public from hermes-hq-push 0.9.73 as re-published 2026-11-20 and 0.9.74; the "0.9.65" and
    /// "0.9.66" named here and in goals.py were only ever installed on the owner's computer (PushPolicy.goals).
    private(set) var goalsSupported = false
    /// [goals-addon] Tasks work but the add-on keeps no goals: an add-on from before Goals was published. The Goals
    /// pill stays and says to update the add-on (a public tester, 2026-11-20: "can't see Goals in Tasks").
    var goalsNeedAddOn: Bool { hasList && !needsAddOn && !goalsSupported }
    /// [goals step 3] The add-on puts bots on goals (`goal_bots`, with Goals in the public add-on): a lead, helpers,
    /// offers, the check-in.
    private(set) var goalBotsSupported = false
    /// [goals step 5] The add-on draws Goal Pages (`goal_pages` in `/status`).
    private(set) var goalPagesSupported = false
    /// Custom interval / after-completion recurrence (`custom_repeat: true` in `GET /tasks`).
    private(set) var customRepeatSupported = false
    /// [goals step 3] Goal offers seen here, by id (newest kept, 80 at most): what a goal's chat card draws once the
    /// gateway has let the offer go ("Answered").
    @ObservationIgnored private var seenOffers: [String: TodoOffer] = [:]
    @ObservationIgnored private var goalPagesAsked = false
    /// [task-ideas] New ideas to decide; nil when the add-on has no Ideas (older than 0.9.39), and the page keeps its
    /// Add a task row instead of the To Do | Ideas switch.
    private(set) var ideasCount: Int?
    /// A list is in hand (from disk or the gateway).
    private(set) var hasList = false
    /// The last read failed (shown only when there is no list).
    private(set) var error: String?
    private(set) var loading = false
    /// The add-on on the computer predates Tasks.
    private(set) var needsAddOn = false
    /// Pending offline mutations waiting to sync when the gateway is reachable again.
    private(set) var pendingCount = 0

    @ObservationIgnored var onChange: (() -> Void)?
    /// A write failed or gave way: plain words for a notice.
    @ObservationIgnored var onNotice: ((String) -> Void)?
    /// The task the last notice is about; nil when it is about the list as a whole (its settings or sections). The Mac's
    /// two panes say it on the task beside the list only when it is that task (Mac polish #44).
    @ObservationIgnored private(set) var noticeTask: String?
    /// [chat-mark-done] The last notice's words: a chat card's refused save says why under the chat's bar (the card
    /// clears it before its write).
    @ObservationIgnored var lastNotice: String?
    /// A refresh failed while a list shows (the page says "Couldn’t refresh. Showing what was saved.", as Jobs does).
    @ObservationIgnored var onRefreshFailed: ((String) -> Void)?
    /// Why the last `add` failed, in words (New Task's sheet says it on its own line; nil when it worked).
    @ObservationIgnored private(set) var addFailure: String?
    /// Every list change (local reminders follow it).
    @ObservationIgnored var onListChanged: (([TodoTask]) -> Void)?

    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var inFlight: [String: Int] = [:]
    /// Tasks whose `DELETE` is in flight: `adopt()` never resurrects them while the request is pending.
    @ObservationIgnored private var deleting: Set<String> = []
    /// Per-task serialized write tail so concurrent edits on one task execute in order with up-to-date revs.
    @ObservationIgnored private var taskQueue: [String: Task<Void, Never>] = [:]
    /// Monotonic edit token per task so an earlier failed write never rolls back a newer optimistic edit.
    @ObservationIgnored private var taskEditToken: [String: Int] = [:]
    /// Newest confirmed server snapshot for a task while subsequent queued writes are still running.
    @ObservationIgnored private var serverTask: [String: TodoTask] = [:]
    /// Persisted offline write queue (FIFO).
    @ObservationIgnored private var pendingOps: [TodoPendingOp] = []
    @ObservationIgnored private var flushingPending = false
    /// ID of the pending op currently in flight in `flushPending()`, so `enqueueOffline` never folds a newer edit into it.
    @ObservationIgnored private var flushingOpID: String?
    /// Throttle timer for live `tasks.changed` socket events.
    @ObservationIgnored private var changedRefreshTask: Task<Void, Never>?
    /// Background task replaying queued offline changes after `gateway.ready`.
    @ObservationIgnored private var gatewayReadyTask: Task<Void, Never>?
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var lastReadAt: Date?
    @ObservationIgnored private var sectionsWriting = false
    @ObservationIgnored private var offersWriting = 0
    /// [goals] Goals with a write on its way (by id): a read that left before it landed doesn't take it back.
    @ObservationIgnored private var goalsInFlight: [String: Int] = [:]
    private var goalsAPI: GoalsAPI { GoalsAPI(client: api.client) }
    /// [13-5] Forgotten at sign-out or a switch: an answer still on its way neither writes tasks.json again nor resets
    /// the phone's due reminders to this account's tasks.
    @ObservationIgnored private var closed = false

    init(api: TasksAPI, account: GatewayAccount, directory: URL?) {
        self.api = api
        self.account = account
        self.directory = directory
    }

    // MARK: Cache & Offline Queue

    private var cacheURL: URL? { directory?.appending(path: "tasks.json") }
    private var pendingURL: URL? { directory?.appending(path: "tasks-pending.json") }

    /// True for transport / reachability failures (not HTTP 4xx/5xx server refusals or cancellation).
    nonisolated static func isOfflineError(_ error: Error) -> Bool {
        PagesREST.transportReason(error) != nil && (error as NSError).code != NSURLErrorCancelled
    }

    private var pendingTaskIDs: Set<String> {
        var ids = Set<String>()
        for op in pendingOps {
            switch op.kind {
            case .add(let localID, _): ids.insert(localID)
            case .patch(let id, _, _): ids.insert(id)
            case .delete(let id): ids.insert(id)
            case .saveSections, .answerOffer: break
            }
        }
        return ids
    }

    private var pendingDeletedIDs: Set<String> {
        Set(pendingOps.compactMap { if case .delete(let id) = $0.kind { return id }; return nil })
    }

    private var hasPendingSections: Bool {
        pendingOps.contains { if case .saveSections = $0.kind { return true }; return false }
    }

    private var hasPendingOffers: Bool {
        pendingOps.contains { if case .answerOffer = $0.kind { return true }; return false }
    }

    private func savePending() {
        pendingCount = pendingOps.count
        guard !closed, let url = pendingURL else { return }
        if pendingOps.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            PagesCache.write(PagesCached(at: Date().timeIntervalSince1970, value: pendingOps), to: url)
        }
    }

    private nonisolated static func baselineFields(for fields: [String: JSONValue], from task: TodoTask) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in fields.keys where key != "rev" {
            out[key] = TodoEdits.value(key, of: task)
        }
        return out
    }

    private func enqueueOffline(_ kind: TodoPendingOp.Kind, baseFields: [String: JSONValue]? = nil,
                                quiet: Bool = false, about taskID: String? = nil) {
        switch kind {
        case .patch(let id, let fields, let touch):
            // Fold into an existing queued `.add` for a local task, or coalesce into the last queued `.patch` for `id`,
            // skipping whichever op is currently in flight so removing it by ID never drops newer edits.
            if let idx = pendingOps.lastIndex(where: {
                guard $0.id != flushingOpID else { return false }
                if case .add(let localID, _) = $0.kind { return localID == id }
                return false
            }), case .add(let localID, var addFields) = pendingOps[idx].kind {
                for (k, v) in fields { addFields[k] = v }
                pendingOps[idx].kind = .add(localID: localID, fields: addFields)
            } else if let idx = pendingOps.lastIndex(where: {
                guard $0.id != flushingOpID else { return false }
                if case .patch(let existingID, _, _) = $0.kind { return existingID == id }
                return false
            }), case .patch(_, var existingFields, let existingTouch) = pendingOps[idx].kind {
                if let baseFields, !baseFields.isEmpty {
                    var merged = pendingOps[idx].baseFields ?? [:]
                    for (k, v) in baseFields where merged[k] == nil { merged[k] = v }
                    pendingOps[idx].baseFields = merged
                }
                for (k, v) in fields { existingFields[k] = v }
                pendingOps[idx].kind = .patch(id: id, fields: existingFields, touch: existingTouch || touch)
            } else {
                pendingOps.append(TodoPendingOp(kind: kind, baseFields: baseFields))
            }
        case .delete(let id):
            // Deleting a task added offline cancels the pending add + patches cleanly with zero network traffic.
            if pendingOps.contains(where: { if case .add(let localID, _) = $0.kind { return localID == id }; return false }) {
                pendingOps.removeAll {
                    switch $0.kind {
                    case .add(let localID, _): return localID == id
                    case .patch(let pid, _, _): return pid == id
                    default: return false
                    }
                }
            } else {
                pendingOps.removeAll { if case .patch(let pid, _, _) = $0.kind { return pid == id }; return false }
                pendingOps.append(TodoPendingOp(kind: kind))
            }
        case .saveSections:
            pendingOps.removeAll { if case .saveSections = $0.kind { return true }; return false }
            pendingOps.append(TodoPendingOp(kind: kind))
        case .add, .answerOffer:
            pendingOps.append(TodoPendingOp(kind: kind))
        }
        savePending()
        save()
        changed()
        if !quiet { notice("Saved offline. Will sync when connected.", about: taskID) }
    }

    /// Replays queued offline writes in FIFO order. Stops immediately if the gateway is still unreachable.
    func flushPending() async {
        guard !closed, !flushingPending, !pendingOps.isEmpty, !readOnlyGateway else { return }
        flushingPending = true
        defer {
            flushingPending = false
            flushingOpID = nil
        }
        var idMap: [String: String] = [:]
        var replayedAny = false

        while !closed, let op = pendingOps.first {
            let opID = op.id
            flushingOpID = opID
            defer { if flushingOpID == opID { flushingOpID = nil } }
            do {
                switch op.kind {
                case .add(let localID, let fields):
                    let made = try await api.create(fields)
                    guard !closed else { break }
                    // If the user deleted `localID` while `api.create` was in flight, the `.add` op was removed from
                    // `pendingOps`: do not resurrect `made` locally and best-effort remove the server orphan.
                    guard pendingOps.contains(where: { $0.id == opID }) else {
                        try? await api.delete(made.id)
                        replayedAny = true
                        continue
                    }
                    idMap[localID] = made.id
                    tasks.removeAll { $0.id == localID }
                    put(made)
                    reconcilePrep(TodoEdits.prepBots(before: nil, after: made, fields: nil))
                case .patch(let rawID, let fields, let touch):
                    let id = idMap[rawID] ?? rawID
                    guard let current = task(id), !TodoIDs.isLocal(id) else {
                        pendingOps.removeAll { $0.id == opID }; savePending(); continue
                    }
                    let rawBase = serverTask[id] ?? current
                    let base = op.baseFields.flatMap { TodoEdits.applying($0, to: rawBase) } ?? rawBase
                    do {
                        let answer = try await api.patch(id, rev: current.rev, fields: fields)
                        guard !closed else { break }
                        guard pendingOps.contains(where: { $0.id == opID }) else { continue }
                        serverTask[id] = answer
                        put(answer)
                        reconcilePrep(TodoEdits.prepBots(before: base, after: answer, fields: Set(fields.keys)))
                    } catch {
                        guard !closed else { break }
                        if let latest = TasksAPI.conflict(error) {
                            if let resolved = TodoEdits.resolveFields(base: base, current: latest, fields: fields) {
                                do {
                                    let answer = try await api.patch(id, rev: resolved.rev, fields: resolved.fields)
                                    guard !closed else { break }
                                    guard pendingOps.contains(where: { $0.id == opID }) else { continue }
                                    serverTask[id] = answer
                                    put(answer)
                                    reconcilePrep(TodoEdits.prepBots(before: base, after: answer, fields: Set(resolved.fields.keys)))
                                } catch let retryError {
                                    guard !closed else { break }
                                    if Self.isOfflineError(retryError) {
                                        if let idx = pendingOps.firstIndex(where: { $0.id == opID }) {
                                            serverTask[id] = latest
                                            let shown = TodoEdits.applying(resolved.fields, to: latest) ?? latest
                                            put(shown)
                                            pendingOps[idx].kind = .patch(id: rawID, fields: resolved.fields, touch: touch)
                                            pendingOps[idx].baseFields = Self.baselineFields(for: resolved.fields, from: latest)
                                            savePending()
                                        }
                                        throw retryError
                                    } else if let newer = TasksAPI.conflict(retryError) {
                                        if pendingOps.contains(where: { $0.id == opID }) {
                                            serverTask[id] = newer
                                            put(newer)
                                            notice("This task changed somewhere else. Showing the latest.", about: id)
                                        }
                                    } else if PagesREST.status(retryError) == 404 {
                                        tasks.removeAll { $0.id == id }
                                    } else {
                                        throw retryError
                                    }
                                }
                            } else if pendingOps.contains(where: { $0.id == opID }) {
                                serverTask[id] = latest
                                put(latest)
                                notice("This task changed somewhere else. Showing the latest.", about: id)
                            }
                        } else if PagesREST.status(error) == 404 {
                            tasks.removeAll { $0.id == id }
                        } else {
                            throw error
                        }
                    }
                case .delete(let rawID):
                    let id = idMap[rawID] ?? rawID
                    if !TodoIDs.isLocal(id) {
                        do { try await api.delete(id) }
                        catch { if PagesREST.status(error) != 404 { throw error } }
                    }
                    guard !closed else { break }
                    tasks.removeAll { $0.id == id }
                case .saveSections(let next):
                    let saved = try await api.saveSections(next)
                    guard !closed else { break }
                    if pendingOps.contains(where: { $0.id == opID }) {
                        sections = saved
                    }
                case .answerOffer(let id, let action, let list, let plan, let inGoal):
                    let goal: (plan: Bool, inGoal: Bool)? = (plan != nil && inGoal != nil) ? (plan!, inGoal!) : nil
                    do {
                        let answer = try await api.answerOffer(id, action: action, list: list, goal: goal)
                        guard !closed else { break }
                        if let now = offers.firstIndex(where: { $0.id == id }) { offers[now] = answer.offer }
                        noteOffers(whole: false)
                        if !hasPendingSections { sections = answer.sections }
                        if let goals = answer.goals { adoptGoals(goals) }
                    } catch {
                        guard !closed else { break }
                        if PagesREST.status(error) != 409 && PagesREST.status(error) != 404 { throw error }
                    }
                }
                guard !closed else { break }
                pendingOps.removeAll { $0.id == opID }
                replayedAny = true
                savePending()
                save()
                changed()
            } catch {
                guard !closed else { break }
                if Self.isOfflineError(error) { break }
                // Permanent server refusal: drop this op and notify so the rest of the queue isn't blocked forever.
                let wasPresent = pendingOps.contains { $0.id == opID }
                pendingOps.removeAll { $0.id == opID }
                savePending()
                if wasPresent {
                    notice("Couldn’t sync an offline change. \(PagesREST.reason(error))")
                }
            }
        }
        if replayedAny { lastReadAt = nil }
    }

    /// Live `tasks.changed` socket event: throttled forced refresh (at most every 2 s).
    func tasksChanged() {
        guard !closed, changedRefreshTask == nil else { return }
        changedRefreshTask = Task { [weak self] in
            defer { self?.changedRefreshTask = nil }
            try? await Task.sleep(for: .seconds(1))
            guard let self, !self.closed else { return }
            await self.refresh(force: true)
        }
    }

    /// Gateway reconnected (`gateway.ready`): replay any queued offline mutations, then refresh.
    func gatewayReady() {
        guard !closed else { return }
        gatewayReadyTask?.cancel()
        gatewayReadyTask = Task { [weak self] in
            guard let self, !self.closed else { return }
            await self.flushPending()
            guard !self.closed, !Task.isCancelled else { return }
            await self.refresh(force: true)
        }
    }

    /// The page is about to draw: paint the list from disk.
    func prepare() {
        guard !prepared, !closed else { return }
        prepared = true
        if let pendingURL, let queued = PagesCache.read(PagesCached<[TodoPendingOp]>.self, pendingURL) {
            pendingOps = queued.value
            pendingCount = pendingOps.count
        }
        guard !hasList, let url = cacheURL, let cached = PagesCache.read(PagesCached<TodoSnapshot>.self, url) else { return }
        tasks = cached.value.tasks
        settings = cached.value.settings
        sections = cached.value.sections ?? []
        sectionsSupported = cached.value.sections != nil
        pagesSupported = cached.value.pages == true
        fieldsSupported = cached.value.fields == true
        filesSupported = cached.value.files == true
        listsSupported = cached.value.lists == true
        offers = Self.once(cached.value.offers ?? [])
        goals = cached.value.goals ?? []
        goalsSupported = cached.value.goals != nil
        goalBotsSupported = goalsSupported && cached.value.goalBots == true
        goalPagesSupported = goalBotsSupported && cached.value.goalPages == true
        customRepeatSupported = cached.value.customRepeat == true
        for offer in cached.value.seenOffers ?? [] { seenOffers[offer.id] = offer }
        if !seenOffers.isEmpty { _ = TodoOfferStates.note(Array(seenOffers.values), whole: false) }
        noteOffers(whole: false)
        ideasCount = cached.value.ideas
        rev = cached.value.rev
        hasList = true
        changed()
    }

    private func save() {
        guard !closed, let url = cacheURL else { return }
        let queuedLocals = pendingTaskIDs
        let snapshot = TodoSnapshot(rev: rev,
                                    tasks: tasks.filter { !TodoIDs.isLocal($0.id) || queuedLocals.contains($0.id) },
                                    settings: settings,
                                    sections: sectionsSupported ? sections.filter { !TodoIDs.isLocal($0.id) || hasPendingSections } : nil,
                                    pages: pagesSupported, ideas: ideasCount, fields: fieldsSupported, files: filesSupported,
                                    lists: listsSupported, offers: offers,
                                    goals: goalsSupported ? goals.filter { !TodoIDs.isLocal($0.id) } : nil,
                                    goalBots: goalBotsSupported, goalPages: goalPagesSupported,
                                    seenOffers: seenOffers.isEmpty ? nil : Array(seenOffers.values),
                                    customRepeat: customRepeatSupported)
        PagesCache.write(PagesCached(at: Date().timeIntervalSince1970, value: snapshot), to: url)
    }

    private func changed() {
        guard !closed else { return }
        onChange?()
        onListChanged?(tasks)
    }

    // MARK: Reads

    func task(_ id: String) -> TodoTask? { tasks.first { $0.id == id } }

    /// Reads the list. `force` skips `?since=` (a push said something changed that the rev may not show yet).
    func refresh(force: Bool = false) async {
        guard !closed else { return }
        prepare()
        if !pendingOps.isEmpty { await flushPending() }
        if !force, let at = lastReadAt, Date().timeIntervalSince(at) < 2 { return }
        readGeneration += 1
        let generation = readGeneration
        loading = true
        onChange?()
        defer { if generation == readGeneration { loading = false; onChange?() } }
        do {
            let answer = try await api.list(since: hasList && !force && rev > 0 ? rev : nil)
            guard generation == readGeneration else { return }
            lastReadAt = Date()
            if answer.unchanged { error = nil; needsAddOn = false; return }
            guard let fresh = answer.tasks else {
                // An add-on with no Tasks answers an empty object (or a page of its own).
                needsAddOn = await api.addOnServesTasks() != true
                if !needsAddOn { error = MoreWire.olderHermes }
                return
            }
            needsAddOn = false
            error = nil
            pagesSupported = answer.pages
            fieldsSupported = answer.fields
            filesSupported = answer.files
            listsSupported = answer.lists
            if offersWriting == 0 && !hasPendingOffers { offers = Self.once(answer.offers); noteOffers(whole: answer.lists) }
            ideasCount = answer.ideas
            adoptGoals(answer.goals)
            goalBotsSupported = goalsSupported && answer.goalBots
            customRepeatSupported = answer.customRepeat
            if !goalBotsSupported { goalPagesSupported = false; goalPagesAsked = false }
            else if !goalPagesAsked {
                goalPagesAsked = true
                let api = api
                Task { [weak self] in
                    let draws = await api.addOnDrawsGoalPages()
                    guard let self, !self.closed else { return }
                    if let draws { self.goalPagesSupported = draws && self.goalBotsSupported; self.save(); self.onChange?() }
                    else { self.goalPagesAsked = false }
                }
            }
            if !sectionsWriting && !hasPendingSections {
                sections = answer.sections ?? []
                sectionsSupported = answer.sections != nil
            }
            adopt(fresh, rev: answer.rev, settings: answer.settings)
        } catch {
            guard generation == readGeneration else { return }
            if let http = error as? HTTPError, PagesREST.isUnknownRoute(http) {
                needsAddOn = await api.addOnServesTasks() != true
                self.error = needsAddOn ? nil : PagesREST.reason(error)
            } else {
                self.error = PagesREST.reason(error)
            }
            if hasList, !needsAddOn, let reason = self.error { onRefreshFailed?(reason) }
        }
    }

    /// A read's list, keeping tasks that have a write on its way and ones added here and not yet answered,
    /// and never resurrecting tasks whose delete is in flight or queued offline.
    private func adopt(_ fresh: [TodoTask], rev: Int, settings: TodoSettings?) {
        let suppressedDeletes = deleting.union(pendingDeletedIDs)
        let pendingIDs = pendingTaskIDs
        var next = fresh.filter { !suppressedDeletes.contains($0.id) }
        let places = Dictionary(next.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for local in tasks {
            guard !suppressedDeletes.contains(local.id) else { continue }
            let inHand = inFlight[local.id] != nil || TodoIDs.isLocal(local.id) || pendingIDs.contains(local.id)
            if let at = places[local.id] {
                // [tasks-first] A read that left before a change landed carries the task as it was (an older rev): it
                // never takes the change back.
                if inHand || next[at].rev < local.rev { next[at] = local }
            } else if inHand {
                next.append(local)
            }
        }
        tasks = next
        self.rev = rev
        if let settings { self.settings = settings }
        hasList = true
        TodoTaskStates.noteRead()   // [chat-mark-done] the gateway's list, not the one on disk
        save()
        changed()
    }

    /// [goals] A read's goals, keeping ones with a write on its way and ones added here and not yet answered (nil: the
    /// add-on keeps none).
    private func adoptGoals(_ fresh: [Goal]?) {
        guard let fresh else { goalsSupported = false; goals = []; return }
        goalsSupported = true
        var next = fresh
        let places = Dictionary(next.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for local in goals {
            let inHand = goalsInFlight[local.id] != nil || TodoIDs.isLocal(local.id)
            if let at = places[local.id] {
                if inHand || next[at].rev < local.rev { next[at] = local }
            } else if inHand {
                next.append(local)
            }
        }
        goals = next
    }

    /// [task-ideas] The Ideas page read or decided: the switch's count follows it at once.
    func ideasRead(_ count: Int) {
        guard ideasCount != nil, ideasCount != count else { return }
        ideasCount = count
        save()
        onChange?()
    }

    // MARK: Writes

    /// Acceptance is conditional on the exact revision shown. Never retry a conflict: the suggestion may have changed.
    func acceptSuggestedTitle(_ id: String, suggestion: String, forTitle: String) async -> Bool {
        guard !refuse(about: id) else { return false }
        guard inFlight[id] == nil else {
            notice("This task is being saved. Try again in a moment.", about: id)
            return false
        }
        guard let base = task(id), !TodoIDs.isLocal(id),
              base.title == forTitle, base.currentSuggestedTitle == suggestion else {
            notice("This suggestion is no longer current.", about: id)
            return false
        }
        begin(id)
        defer { end(id) }
        do {
            let answer = try await api.patch(id, rev: base.rev, fields: ["title": .string(suggestion)])
            put(answer); save(); changed()
            guard answer.title == suggestion else {
                notice("Couldn’t save the suggested title. Showing the saved task.", about: id)
                return false
            }
            return true
        } catch {
            if let current = TasksAPI.conflict(error) {
                put(current); save(); changed()
                notice("This task changed somewhere else. Showing the latest.", about: id)
            } else if PagesREST.status(error) == 404 {
                tasks.removeAll { $0.id == id }; save(); changed()
                notice("This task was deleted somewhere else.", about: id)
            } else {
                notice("Couldn’t save the suggested title. \(PagesREST.reason(error))", about: id)
            }
            return false
        }
    }

    private func refuse(quiet: Bool = false, about task: String? = nil) -> Bool {
        guard readOnlyGateway else { return false }
        if !quiet { notice(JobsStore.readOnlyNotice, about: task) }
        return true
    }

    private func notice(_ text: String, about task: String? = nil) {
        noticeTask = task
        lastNotice = text
        onNotice?(text)
    }

    private func put(_ task: TodoTask) {
        if let at = tasks.firstIndex(where: { $0.id == task.id }) { tasks[at] = task } else { tasks.append(task) }
    }

    private func begin(_ id: String) { inFlight[id, default: 0] += 1 }
    private func end(_ id: String) {
        let left = (inFlight[id] ?? 1) - 1
        inFlight[id] = left > 0 ? left : nil
        if left <= 0 { serverTask[id] = nil }
    }

    private func nextEditToken(_ id: String) -> Int {
        let next = (taskEditToken[id] ?? 0) + 1
        taskEditToken[id] = next
        return next
    }

    /// Serializes network writes per task id so concurrent edits never race with stale revs.
    private func serializeTaskWrite<T>(_ id: String, _ work: @escaping @MainActor () async -> T) async -> T {
        let previous = taskQueue[id]
        var result: T!
        let next = Task { @MainActor in
            await previous?.value
            result = await work()
        }
        taskQueue[id] = next
        await next.value
        if taskQueue[id] == next { taskQueue[id] = nil }
        return result
    }

    /// Restores only the fields `keys` from `base` onto the live task when another edit landed after this one.
    private func restoreFields(_ keys: Set<String>, from base: TodoTask, on id: String, touch: Bool) {
        guard let current = task(id) else { return }
        var revert: [String: JSONValue] = [:]
        for key in keys where key != "rev" {
            revert[key] = TodoEdits.value(key, of: base)
        }
        if touch { revert["updated_at"] = TodoWire.optional(base.updatedAt) }
        if let restored = TodoEdits.applying(revert, to: current) { put(restored) }
    }

    /// Adds a task: shown at once, then swapped for the gateway's (its id, rev and times). On transport failure,
    /// queues offline and keeps the local task; nil when the server refused it, with the reason in `addFailure`.
    @discardableResult
    func add(_ fields: [String: JSONValue], quiet: Bool = false) async -> TodoTask? {
        addFailure = nil
        guard !refuse(quiet: quiet) else { addFailure = JobsStore.readOnlyNotice; return nil }
        var draft = fields
        let localID = TodoIDs.local()
        draft["id"] = .string(localID)
        draft["created_at"] = .string(TodoDates.now())
        draft["updated_at"] = draft["created_at"]
        draft["created_by"] = .string("you")
        let shown: TodoTask? = (try? JSONValue.object(draft).encoded()).flatMap { try? JSONDecoder().decode(TodoTask.self, from: $0) }
        if let shown {
            tasks.append(shown)
            changed()
        }
        do {
            let made = try await api.create(fields)
            guard !closed else { return nil }
            tasks.removeAll { $0.id == localID }
            put(made)
            save()
            changed()
            reconcilePrep(TodoEdits.prepBots(before: nil, after: made, fields: nil))
            return made
        } catch {
            guard !closed else { return nil }
            if Self.isOfflineError(error), let shown {
                enqueueOffline(.add(localID: localID, fields: fields), quiet: quiet)
                return shown
            }
            tasks.removeAll { $0.id == localID }
            changed()
            let reason = PagesREST.reason(error)
            addFailure = reason
            if !quiet { notice("Couldn’t add the task. \(reason)") }
            return nil
        }
    }

    /// Changes a task's fields (wire names). The change shows at once; concurrent edits to the same task serialize
    /// in order; a 409 re-sends on the current rev (including 3-way step merges) when non-conflicting, and transport
    /// failures queue offline. `touch`: the shown task counts as changed now (Keep, which sends no fields).
    @discardableResult
    func patch(_ id: String, _ fields: [String: JSONValue], touch: Bool = false) async -> Bool {
        guard !refuse(about: id), let initialBase = task(id) else { return false }
        let fields = GoalViews.withMilestoneRule(fields, task: initialBase)   // [goals] another goal: no milestone of the last one
        if TodoIDs.isLocal(id) {
            // Allow editing a task that was added offline by folding the patch into its pending `.add`.
            if pendingTaskIDs.contains(id) {
                if var shown = TodoEdits.applying(fields, to: initialBase) {
                    if touch { shown.updatedAt = TodoDates.now() }
                    put(shown)
                }
                enqueueOffline(.patch(id: id, fields: fields, touch: touch), quiet: true, about: id)
                return true
            }
            notice("This task is still being added. Try again in a moment.", about: id)
            return false
        }
        let token = nextEditToken(id)
        if var shown = TodoEdits.applying(fields, to: initialBase) {
            if touch { shown.updatedAt = TodoDates.now() }
            put(shown); changed()
        }
        begin(id)
        return await serializeTaskWrite(id) { [self] in
            defer { self.end(id) }
            guard !self.closed else { return false }
            let base = self.serverTask[id] ?? initialBase
            var sendFields = fields
            // If an earlier queued write changed `steps` on this task, 3-way merge our step edits onto `base`.
            if let rawSteps = fields["steps"], base.steps != initialBase.steps,
               let data = try? rawSteps.encoded(),
               let ours = try? JSONDecoder().decode([TodoStep].self, from: data),
               let merged = TodoEdits.mergeSteps(base: initialBase.steps, current: base.steps, ours: ours) {
                sendFields["steps"] = TodoWire.steps(merged)
            }
            do {
                let answer = try await self.api.patch(id, rev: base.rev, fields: sendFields)
                guard !self.closed else { return false }
                self.serverTask[id] = answer
                if self.taskEditToken[id] == token {
                    self.put(answer)
                } else if var live = self.task(id) {
                    live.rev = answer.rev
                    self.put(live)
                }
                self.save()
                self.changed()
                self.reconcilePrep(TodoEdits.prepBots(before: base, after: answer, fields: Set(sendFields.keys)))
                return true
            } catch {
                guard !self.closed else { return false }
                if Self.isOfflineError(error) {
                    let baseline = Self.baselineFields(for: sendFields, from: base)
                    self.enqueueOffline(.patch(id: id, fields: sendFields, touch: touch), baseFields: baseline, about: id)
                    return true
                }
                if let current = TasksAPI.conflict(error) {
                    if let resolved = TodoEdits.resolveFields(base: base, current: current, fields: sendFields) {
                        do {
                            let answer = try await self.api.patch(id, rev: resolved.rev, fields: resolved.fields)
                            guard !self.closed else { return false }
                            self.serverTask[id] = answer
                            if self.taskEditToken[id] == token {
                                self.put(answer)
                            } else if var live = self.task(id) {
                                live.rev = answer.rev
                                self.put(live)
                            }
                            self.save(); self.changed()
                            self.reconcilePrep(TodoEdits.prepBots(before: base, after: answer, fields: Set(resolved.fields.keys)))
                            return true
                        } catch let retryError {
                            guard !self.closed else { return false }
                            if Self.isOfflineError(retryError) {
                                self.serverTask[id] = current
                                if var live = self.task(id) {
                                    live.rev = current.rev
                                    self.put(live)
                                }
                                let baseline = Self.baselineFields(for: resolved.fields, from: current)
                                self.enqueueOffline(.patch(id: id, fields: resolved.fields, touch: touch), baseFields: baseline, about: id)
                                return true
                            }
                            if let newer = TasksAPI.conflict(retryError) {
                                self.applyConflictSnapshot(newer, id: id, token: token, keys: Set(resolved.fields.keys), touch: touch)
                                return false
                            }
                            if PagesREST.status(retryError) == 404 {
                                self.tasks.removeAll { $0.id == id }
                                self.save(); self.changed()
                                self.notice("This task was deleted somewhere else.", about: id)
                                return false
                            }
                            if self.taskEditToken[id] == token {
                                self.put(current)
                            } else {
                                self.restoreFields(Set(resolved.fields.keys), from: current, on: id, touch: touch)
                            }
                            self.save(); self.changed()
                            self.notice("Couldn’t save the change. \(PagesREST.reason(retryError))", about: id)
                            return false
                        }
                    }
                    self.applyConflictSnapshot(current, id: id, token: token, keys: Set(sendFields.keys), touch: touch)
                    return false
                }
                if PagesREST.status(error) == 404 {
                    self.tasks.removeAll { $0.id == id }
                    self.save(); self.changed()
                    self.notice("This task was deleted somewhere else.", about: id)
                    return false
                }
                if self.taskEditToken[id] == token {
                    self.put(base)
                } else {
                    self.restoreFields(Set(sendFields.keys), from: base, on: id, touch: touch)
                }
                self.changed()
                self.notice("Couldn’t save the change. \(PagesREST.reason(error))", about: id)
                return false
            }
        }
    }

    private func applyConflictSnapshot(_ current: TodoTask, id: String, token: Int, keys: Set<String>, touch: Bool) {
        serverTask[id] = current
        if taskEditToken[id] == token {
            put(current)
        } else {
            restoreFields(keys, from: current, on: id, touch: touch)
        }
        save(); changed()
        notice("This task changed somewhere else. Showing the latest.", about: id)
    }

    /// Ticks a task done (or opens it again). false when the gateway didn't take it (the task shows as it was).
    @discardableResult
    func setDone(_ id: String, _ done: Bool) async -> Bool {
        await patch(id, ["status": .string(done ? "done" : "open")])
    }

    /// Keep ("Still Need These?"): nothing about the task changes, but the gateway stamps it touched, so it leaves
    /// the group for another two weeks.
    @discardableResult
    func keep(_ id: String) async -> Bool {
        await patch(id, [:], touch: true)
    }

    /// Ticks one step.
    /// False when the gateway refused it.
    @discardableResult
    func setStep(_ taskID: String, step: String, done: Bool) async -> Bool {
        guard let task = task(taskID) else { return false }
        let steps = task.steps.map { s -> TodoStep in var s = s; if s.id == step { s.done = done }; return s }
        return await patch(taskID, ["steps": TodoWire.steps(steps)])
    }

    // MARK: Your own files and links ([tasks-first], hermes-hq-push 0.9.53)

    /// The largest file a task takes (the add-on's own cap).
    nonisolated static let fileLimit = 10 * 1024 * 1024

    /// Puts a link on the task. False when the gateway refused it (the notice has said why).
    @discardableResult
    func attachLink(_ id: String, url: String, title: String = "") async -> Bool {
        await attach(id, ["kind": "link", "url": .string(url), "title": .string(title)])
    }

    /// Puts a file on the task: its bytes are base64-encoded off main and kept on the computer running Hermes.
    @discardableResult
    func attachFile(_ id: String, name: String, data: Data) async -> Bool {
        guard data.count <= Self.fileLimit else {
            notice("That file is over 10 MB. A task takes files up to 10 MB.", about: id)
            return false
        }
        guard !refuse(about: id), task(id) != nil else { return false }
        guard filesSupported else {
            notice("Files and links on a task need the newest HQ add-on on your computer (0.9.53 or later).", about: id)
            return false
        }
        let token = nextEditToken(id)
        begin(id)
        return await serializeTaskWrite(id) { [self] in
            defer { self.end(id) }
            do {
                let answer = try await self.api.attachFile(id, name: name, data: data)
                self.serverTask[id] = answer
                if self.taskEditToken[id] == token { self.put(answer) }
                else if var live = self.task(id) { live.rev = answer.rev; live.made = answer.made; self.put(live) }
                self.save()
                self.changed()
                return true
            } catch {
                self.notice("Couldn’t add it. \(PagesREST.reason(error))", about: id)
                return false
            }
        }
    }

    private func attach(_ id: String, _ body: [String: JSONValue]) async -> Bool {
        guard !refuse(about: id), task(id) != nil else { return false }
        guard filesSupported else {
            notice("Files and links on a task need the newest HQ add-on on your computer (0.9.53 or later).", about: id)
            return false
        }
        let token = nextEditToken(id)
        begin(id)
        return await serializeTaskWrite(id) { [self] in
            defer { self.end(id) }
            do {
                let answer = try await self.api.attach(id, body)
                self.serverTask[id] = answer
                if self.taskEditToken[id] == token { self.put(answer) }
                else if var live = self.task(id) { live.rev = answer.rev; live.made = answer.made; self.put(live) }
                self.save()
                self.changed()
                return true
            } catch {
                self.notice("Couldn’t add it. \(PagesREST.reason(error))", about: id)
                return false
            }
        }
    }

    /// Takes a file, link or note off the task (shown at once; put back if the gateway refuses without clobbering newer edits).
    @discardableResult
    func detach(_ id: String, made: String) async -> Bool {
        guard !refuse(about: id), let before = task(id) else { return false }
        let removedItem = before.made.first { $0.id == made }
        let removedIndex = before.made.firstIndex { $0.id == made }
        let token = nextEditToken(id)
        var shown = before
        shown.made.removeAll { $0.id == made }
        put(shown); changed()
        begin(id)
        return await serializeTaskWrite(id) { [self] in
            defer { self.end(id) }
            guard !self.closed else { return false }
            do {
                let answer = try await self.api.detach(id, made: made)
                guard !self.closed else { return false }
                self.serverTask[id] = answer
                if self.taskEditToken[id] == token { self.put(answer) }
                else if var live = self.task(id) { live.rev = answer.rev; live.made = answer.made; self.put(live) }
                self.save()
                self.changed()
                return true
            } catch {
                guard !self.closed else { return false }
                if self.taskEditToken[id] == token {
                    self.put(before)
                } else if var live = self.task(id), let removedItem, !live.made.contains(where: { $0.id == made }) {
                    live.made.insert(removedItem, at: min(removedIndex ?? live.made.count, live.made.count))
                    self.put(live)
                }
                self.changed()
                self.notice("Couldn’t remove it. \(PagesREST.reason(error))", about: id)
                return false
            }
        }
    }

    /// Deletes a task (a chat card's Undo too: the task may not be in the list yet). Tracked in `inFlight` + `deleting`
    /// so a concurrent `refresh()` never resurrects it, and queued offline on transport failure.
    @discardableResult
    func delete(_ id: String) async -> Bool {
        guard !refuse(about: id) else { return false }
        let at = tasks.firstIndex { $0.id == id }
        let removed = at.map { tasks.remove(at: $0) }
        if removed != nil { changed() }
        if TodoIDs.isLocal(id), pendingTaskIDs.contains(id) {
            enqueueOffline(.delete(id: id), quiet: true, about: id)
            return true
        }
        deleting.insert(id)
        begin(id)
        return await serializeTaskWrite(id) { [self] in
            defer {
                self.deleting.remove(id)
                self.end(id)
            }
            guard !self.closed else { return false }
            do {
                try await self.api.delete(id)
                guard !self.closed else { return false }
                self.save()
                self.reconcilePrep(TodoEdits.prepBots(before: removed, after: nil, fields: nil))
                return true
            } catch {
                guard !self.closed else { return false }
                if PagesREST.status(error) == 404 { self.save(); return true }
                if Self.isOfflineError(error) {
                    self.enqueueOffline(.delete(id: id), about: id)
                    return true
                }
                if let removed, let at, !self.tasks.contains(where: { $0.id == id }) {
                    self.tasks.insert(removed, at: min(at, self.tasks.count))
                    self.changed()
                }
                self.notice("Couldn’t delete the task. \(PagesREST.reason(error))", about: id)
                return false
            }
        }
    }

    /// false when it wasn't saved (the settings are back as they were).
    @discardableResult
    func saveSettings(_ next: TodoSettings) async -> Bool {
        guard !refuse() else { return false }
        let before = settings
        settings = next
        onChange?()
        do {
            settings = try await api.saveSettings(next)
            save()
            onChange?()
            return true
        } catch {
            settings = before
            onChange?()
            notice("Couldn’t save Tasks settings. \(PagesREST.reason(error))")
            return false
        }
    }

    // MARK: Goals ([goals], hermes-hq-push 0.9.65)

    func goal(_ id: String) -> Goal? { goals.first { $0.id == id } }

    private func putGoal(_ goal: Goal) {
        if let at = goals.firstIndex(where: { $0.id == goal.id }) { goals[at] = goal } else { goals.append(goal) }
    }

    /// [goals set-up] A plan offer this device accepted (the gateway's answer): the app tells the goal's lead once.
    @ObservationIgnored var onPlanTaken: ((TodoOffer) -> Void)?

    /// Why the last `addGoal` failed, in words (New Goal says it on its own line; nil when it worked).
    @ObservationIgnored private(set) var addGoalFailure: String?

    /// Adds a goal (`GoalWire.newGoal`'s body): shown at once, then swapped for the gateway's. nil when it failed.
    @discardableResult
    func addGoal(_ fields: [String: JSONValue]) async -> Goal? {
        addGoalFailure = nil
        guard !refuse() else { addGoalFailure = JobsStore.readOnlyNotice; return nil }
        guard goalsSupported else {
            addGoalFailure = "Goals need the newest HQ add-on on your computer (0.9.74 or later)."   // [goals-addon] PushPolicy.goals
            notice(addGoalFailure ?? "")
            return nil
        }
        let localID = TodoIDs.local()
        let stamp = TodoDates.now()
        var shown = GoalWire.applying(fields, to: Goal(id: localID, rev: 0, title: "", color: nil, position: Date().timeIntervalSince1970,
                                                       createdAt: stamp, updatedAt: stamp))
        if shown.color == nil { shown.color = GoalViews.nextColor(goals).rawValue }
        goals.append(shown)
        changed()
        // [goals set-up] One write: POST /goals takes the lead, helpers, adds and review. An add-on from before that
        // ignores them, and what it left out goes in a PATCH right after (as it all did before).
        do {
            var made = try await goalsAPI.create(GoalWire.createBody(fields))
            let left = GoalWire.teamLeft(fields, made: made)
            if !left.isEmpty, let led = try? await goalsAPI.patch(made.id, rev: made.rev, fields: left) { made = led }
            goals.removeAll { $0.id == localID }
            putGoal(made)
            save()
            changed()
            return made
        } catch {
            goals.removeAll { $0.id == localID }
            changed()
            let reason = PagesREST.reason(error)
            addGoalFailure = reason
            notice("Couldn’t add the goal. \(reason)")
            return nil
        }
    }

    /// Changes a goal's fields (wire names: `title`, `why`, `color`, `position`, `due`, `status`, `measure`,
    /// `measure_now`, `milestones`). Shown at once; a 409 re-sends it on the current rev when the other edit left these
    /// fields alone, else the current goal shows. A milestone taken out takes its tasks to no milestone here too.
    @discardableResult
    func patchGoal(_ id: String, _ fields: [String: JSONValue]) async -> Bool {
        guard !refuse(), let base = goal(id) else { return false }
        guard !TodoIDs.isLocal(id) else { notice("This goal is still being added. Try again in a moment."); return false }
        putGoal(GoalWire.applying(fields, to: base))
        let released: [String: (goal: String?, milestone: String?)] = fields["milestones"] != nil
            ? releaseTasks(of: id, keeping: Set(goal(id)?.milestones.map(\.id) ?? []))
            : [:]
        changed()
        goalsInFlight[id, default: 0] += 1
        defer {
            let left = (goalsInFlight[id] ?? 1) - 1
            goalsInFlight[id] = left > 0 ? left : nil
        }
        // A milestone made here goes without its local id; the gateway's answer brings the real one.
        do {
            let answer = try await goalsAPI.patch(id, rev: base.rev, fields: fields)
            putGoal(answer)
            save()
            changed()
            return true
        } catch {
            if let current = GoalsAPI.conflict(error) {
                if case .resend(let rev) = GoalWire.resolve(base: base, current: current, fields: fields),
                   let answer = try? await goalsAPI.patch(id, rev: rev, fields: fields) {
                    putGoal(answer); save(); changed()
                    return true
                }
                putGoal(current); restoreReleasedTasks(released); save(); changed()
                notice("This goal changed somewhere else. Showing the latest.")
                return false
            }
            if PagesREST.status(error) == 404 {
                goals.removeAll { $0.id == id }
                _ = releaseTasks(of: id, keeping: nil)
                save(); changed()
                notice("This goal was deleted somewhere else.")
                return false
            }
            putGoal(base)
            restoreReleasedTasks(released)
            changed()
            notice("Couldn’t save the change. \(PagesREST.reason(error))")
            return false
        }
    }

    /// Deletes a goal. Its tasks stay, with no goal and no milestone (the gateway clears them too).
    @discardableResult
    func deleteGoal(_ id: String) async -> Bool {
        guard !refuse() else { return false }
        let at = goals.firstIndex { $0.id == id }
        let removed = at.map { goals.remove(at: $0) }
        let released = releaseTasks(of: id, keeping: nil)
        changed()
        do {
            try await goalsAPI.delete(id)
            save()
            return true
        } catch {
            if PagesREST.status(error) == 404 { save(); return true }
            if let removed, let at { goals.insert(removed, at: min(at, goals.count)) }
            restoreReleasedTasks(released)
            changed()
            notice("Couldn’t delete the goal. \(PagesREST.reason(error))")
            return false
        }
    }

    /// The goal's tasks lose their milestone when it isn't in `keeping`; with `keeping` nil they lose the goal too.
    /// Returns only the affected tasks' prior `(goal, milestone)` so a rollback never clobbers unrelated task edits.
    @discardableResult
    private func releaseTasks(of goal: String, keeping: Set<String>?) -> [String: (goal: String?, milestone: String?)] {
        var prior: [String: (goal: String?, milestone: String?)] = [:]
        tasks = tasks.map { task in
            guard task.goal == goal else { return task }
            var task = task
            if let keeping {
                if let milestone = task.milestone, !keeping.contains(milestone) {
                    prior[task.id] = (task.goal, milestone)
                    task.milestone = nil
                }
            } else {
                prior[task.id] = (task.goal, task.milestone)
                task.goal = nil
                task.milestone = nil
            }
            return task
        }
        return prior
    }

    /// Restores only `(goal, milestone)` on tasks that haven't been reassigned to another goal/milestone since.
    private func restoreReleasedTasks(_ prior: [String: (goal: String?, milestone: String?)]) {
        guard !prior.isEmpty else { return }
        tasks = tasks.map { task in
            guard let old = prior[task.id] else { return task }
            var task = task
            if task.goal == nil { task.goal = old.goal }
            if task.goal == old.goal && task.milestone == nil { task.milestone = old.milestone }
            return task
        }
    }

    /// [goals step 4] The stall question's Keep Going (`keep: true`). False on an add-on before 0.9.66, which keeps no
    /// `kept_at` (the page keeps it on this device instead, `GoalKeptHere`).
    @discardableResult
    func keepGoing(_ id: String) async -> Bool {
        guard goalBotsSupported else { return false }
        return await patchGoal(id, ["keep": .bool(true)])
    }

    /// [goals step 4] Mark Done / Not Yet on the lead's "this looks done".
    @discardableResult
    func answerLooksDone(_ id: String, done: Bool) async -> Bool {
        await patchGoal(id, ["offer_answer": .string(done ? "done" : "keep")])
    }

    /// Puts a task in a goal (nil: no goal), under one of its milestones or none.
    @discardableResult
    func setGoal(_ taskID: String, goal: String?, milestone: String? = nil) async -> Bool {
        await patch(taskID, GoalViews.assign(goal: goal, milestone: milestone, goals: goals))
    }

    // MARK: Sections

    /// Saves your sections (the whole list, in order). Shown at once; a section left out takes its tasks back to no
    /// section. Returns the saved list (new ones with their ids), nil when it failed.
    @discardableResult
    func saveSections(_ next: [TodoUserSection]) async -> [TodoUserSection]? {
        guard !refuse() else { return nil }
        guard sectionsSupported else {
            notice("Sections need the newest HQ add-on on your computer (0.9.36 or later).")
            return nil
        }
        let before = sections
        let kept = Set(next.map(\.id))
        var clearedSections: [String: String] = [:]
        sections = next
        tasks = tasks.map { task in
            guard let id = task.section, !kept.contains(id) else { return task }
            clearedSections[task.id] = id
            var task = task; task.section = nil; return task
        }
        changed()
        sectionsWriting = true
        defer { sectionsWriting = false }
        do {
            let saved = try await api.saveSections(next)
            guard !closed else { return nil }
            sections = saved
            save()
            changed()
            Task { [weak self] in await self?.refresh(force: true) }
            return saved
        } catch {
            guard !closed else { return nil }
            if Self.isOfflineError(error) {
                enqueueOffline(.saveSections(sections: next))
                return next
            }
            sections = before
            if !clearedSections.isEmpty {
                tasks = tasks.map { task in
                    guard task.section == nil, let old = clearedSections[task.id] else { return task }
                    var task = task; task.section = old; return task
                }
            }
            changed()
            notice("Couldn’t save your sections. \(PagesREST.reason(error))")
            return nil
        }
    }

    /// [task-lists] One list changed (its name, colour, icon, bot or rules); the others stay as they are.
    @discardableResult
    func saveSection(_ section: TodoUserSection) async -> Bool {
        guard sections.contains(where: { $0.id == section.id }) else { return false }
        return await saveSections(sections.map { $0.id == section.id ? section : $0 }) != nil
    }

    /// Each offer once, the first of an id kept: an id sent twice would be two rows with one identity, which the
    /// list refuses (a crash, seen on the Mac against the stand-in gateway).
    nonisolated static func once(_ offers: [TodoOffer]) -> [TodoOffer] {
        var seen = Set<String>()
        return offers.filter { seen.insert($0.id).inserted }
    }

    /// The chats' offer cards hear what the offers are now. [goals step 3] Goal offers are kept here too, so a goal's
    /// chat card (told only an id) still draws once the gateway has let one go.
    private func noteOffers(whole: Bool) {
        for offer in offers where offer.isGoal { seenOffers[offer.id] = offer }
        if seenOffers.count > 80 {
            let oldest = seenOffers.values.sorted { (TodoDates.moment($0.at) ?? .distantPast) < (TodoDates.moment($1.at) ?? .distantPast) }
            for offer in oldest.prefix(seenOffers.count - 80) { seenOffers[offer.id] = nil }
        }
        if TodoOfferStates.note(offers, whole: whole) { NotificationCenter.default.post(name: TodoOfferStates.changed, object: nil) }
    }

    /// [task-lists] Your tap on a bot's offer. The card changes at once; the list is read again for the tasks and
    /// the list it made, moved or took back. False when the gateway refused it (the card shows as it was).
    @discardableResult
    func answerOffer(_ id: String, _ action: TodoOfferAction, list: Bool = true, plan: Bool = true, inGoal: Bool = true) async -> Bool {
        guard !refuse(), let at = offers.firstIndex(where: { $0.id == id }) else { return false }
        let before = offers[at]
        var shown = before
        switch action {
        case .accept where before.isGoal:
            // [goals step 3] "Keep the Goal, No Plan" on a plan declines it (as the gateway does).
            if before.kind == "plan", !plan { shown.state = "declined" } else { shown.state = "accepted"; shown.plan = plan; shown.inGoal = inGoal }
        case .accept: shown.state = "accepted"; shown.listed = list || !before.isNew
        case .decline: shown.state = "declined"
        case .move: shown.moveState = "moved"
        case .leave: shown.moveState = "left"
        case .undo: shown.state = "undone"
        }
        offers[at] = shown
        noteOffers(whole: false)
        changed()
        offersWriting += 1
        var holdingOfferWrite = true
        defer { if holdingOfferWrite { offersWriting -= 1 } }
        do {
            let answer = try await api.answerOffer(id, action: action, list: list, goal: before.isGoal ? (plan, inGoal) : nil)
            guard !closed else { return false }
            if let now = offers.firstIndex(where: { $0.id == id }) { offers[now] = answer.offer }
            noteOffers(whole: false)
            if !sectionsWriting { sections = answer.sections }
            if let goals = answer.goals { adoptGoals(goals) }
            save()
            changed()
            // [goals set-up] This device took a plan: its lead is told, once (`GoalPlanTold`). Only here, on the
            // gateway's yes to this tap: another device's answer reaches this one as a 409 or a read, never as this.
            if action == .accept, answer.offer.kind == "plan", answer.offer.state == "accepted" { onPlanTaken?(answer.offer) }
            // Release `offersWriting` BEFORE the forced refresh so `refresh()` actually updates `offers`.
            offersWriting -= 1
            holdingOfferWrite = false
            lastReadAt = nil
            await refresh(force: true)
            return true
        } catch {
            guard !closed else { return false }
            if Self.isOfflineError(error) {
                offersWriting -= 1
                holdingOfferWrite = false
                enqueueOffline(.answerOffer(id: id, action: action, list: list,
                                            goalPlan: before.isGoal ? plan : nil,
                                            goalInGoal: before.isGoal ? inGoal : nil))
                return true
            }
            // [goals step 3] Answered on another device first (a 409): the card shows what became of it.
            if PagesREST.status(error) == 409 {
                if let now = offers.firstIndex(where: { $0.id == id }) { offers[now] = before }
                offersWriting -= 1
                holdingOfferWrite = false
                lastReadAt = nil
                Task { await refresh(force: true) }   // after this write is off the books, so the read takes the offers
                notice("That was already answered on another device.")
                return false
            }
            if let now = offers.firstIndex(where: { $0.id == id }) { offers[now] = before }
            noteOffers(whole: false)
            changed()
            offersWriting -= 1
            holdingOfferWrite = false
            notice("Couldn’t do that. \(PagesREST.reason(error))")
            Task { await refresh(force: true) }
            return false
        }
    }

    /// [task-lists] "Keep Open" on a bot's offer to close a task: the offer leaves the row, and the bot isn't to ask
    /// again.
    @discardableResult
    func keepOpen(_ id: String) async -> Bool {
        guard let base = task(id), var offer = base.offer else { return false }
        offer.kept = true
        guard let value = try? JSONValue.parse(JSONEncoder().encode(offer)) else { return false }
        // `offer` is what the row shows at once; the gateway reads only `keep_open`.
        return await patch(id, ["keep_open": .bool(true), "offer": value])
    }

    /// Adds a section at the end; returns it (with the gateway's id).
    func addSection(named name: String) async -> TodoUserSection? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        // [task-lists] A new list takes the first colour no list has (0.9.55+; an older add-on keeps only the name).
        let draft = TodoUserSection(id: TodoIDs.local(), name: String(clean.prefix(60)),
                                    color: listsSupported ? TodoLists.nextColor(sections).rawValue : nil)
        guard let saved = await saveSections(sections + [draft]) else { return nil }
        return saved.last { $0.name == draft.name } ?? saved.last
    }

    /// Moves tasks into `section` (nil: no section), at the end of it in the order given, or at `position` for one
    /// dragged task. False when any of them couldn't move (the notice has said why).
    @discardableResult
    func move(_ ids: [String], to section: String?, position: Double? = nil) async -> Bool {
        guard !refuse() else { return false }
        guard sectionsSupported else {
            notice("Sections need the newest HQ add-on on your computer (0.9.36 or later).")
            return false
        }
        var next = position ?? ((tasks.filter { $0.section == section && !ids.contains($0.id) }.map(\.order).max() ?? Date().timeIntervalSince1970) + 1)
        // Not `withTaskGroup`: optimized builds abort when a child finishes into a destroyed group (ChildTasks.swift).
        return await withChildTasks(of: Bool.self) { group in
            for id in ids {
                guard let task = task(id) else { continue }
                var fields: [String: JSONValue] = ["position": .number(next)]
                if task.section != section { fields["section"] = TodoWire.optional(section) }
                next += 1
                let body = fields
                group.addTask { await self.patch(id, body) }
            }
            var moved = true
            while let ok = await group.next() { moved = moved && ok }
            return moved
        }
    }

    /// Reschedules one or more tasks to `date` (nil clears due date). When `preserveTime` is true, each task with an
    /// existing due time keeps its hour and minute on the new day.
    @discardableResult
    func reschedule(_ ids: [String], to date: Date?, hasTime: Bool = false, preserveTime: Bool = false,
                    calendar: Calendar = .current) async -> Bool {
        guard !refuse() else { return false }
        return await withChildTasks(of: Bool.self) { group in
            for id in ids {
                guard let task = task(id) else { continue }
                let dueValue: JSONValue = date.map { day in
                    let wire = preserveTime
                        ? TodoViews.rescheduledDue(for: task, onto: day, preserveTime: true, calendar: calendar)
                        : TodoDates.wire(day, hasTime: hasTime, calendar: calendar)
                    return .string(wire)
                } ?? .null
                group.addTask { await self.patch(id, ["due": dueValue]) }
            }
            var ok = true
            while let one = await group.next() { ok = ok && one }
            return ok
        }
    }

    /// Updates priority across one or more tasks.
    @discardableResult
    func setPriority(_ ids: [String], priority: Int) async -> Bool {
        guard !refuse(), fieldsSupported else { return false }
        return await withChildTasks(of: Bool.self) { group in
            for id in ids where task(id) != nil {
                group.addTask { await self.patch(id, ["priority": .number(Double(priority))]) }
            }
            var ok = true
            while let one = await group.next() { ok = ok && one }
            return ok
        }
    }

    /// Updates the goal (and optional milestone) across one or more tasks.
    @discardableResult
    func setGoal(_ ids: [String], goal: String?, milestone: String? = nil) async -> Bool {
        guard !refuse(), goalsSupported else { return false }
        let fields = GoalViews.assign(goal: goal, milestone: milestone, goals: goals)
        return await withChildTasks(of: Bool.self) { group in
            for id in ids where task(id) != nil {
                group.addTask { await self.patch(id, fields) }
            }
            var ok = true
            while let one = await group.next() { ok = ok && one }
            return ok
        }
    }

    /// Duplicates a task (fresh unticked steps, same metadata, new open task).
    @discardableResult
    func duplicate(_ id: String) async -> TodoTask? {
        guard let source = task(id) else { return nil }
        let body = TodoWire.duplicate(source, fieldsSupported: fieldsSupported, goalsSupported: goalsSupported)
        return await add(body)
    }

    /// Group By and Sort By (kept with the other Tasks settings on the gateway).
    /// False when the gateway refused it.
    @discardableResult
    func setLayout(group: String? = nil, sort: String? = nil) async -> Bool {
        var next = settings
        if let group { next.group = group }
        if let sort { next.sort = sort }
        guard next != settings else { return true }
        return await saveSettings(next)
    }

    /// After a change this app made: the bots whose "Task prep" job it may start or end (their own tools do it for theirs).
    private func reconcilePrep(_ bots: [String]) {
        guard !bots.isEmpty else { return }
        let api = api
        Task { for bot in bots { await api.reconcilePrep(bot) } }
    }

    /// Signed out or switched away: forget the list in memory (the cache folder is purged with the account's).
    func forget() {
        closed = true
        changedRefreshTask?.cancel()
        changedRefreshTask = nil
        gatewayReadyTask?.cancel()
        gatewayReadyTask = nil
        for task in taskQueue.values { task.cancel() }
        taskQueue = [:]
        tasks = []
        sections = []
        goals = []
        pendingOps = []
        pendingCount = 0
        deleting = []
        serverTask = [:]
        taskEditToken = [:]
        rev = 0
        hasList = false
        prepared = false
        readGeneration += 1             // a read on its way is dropped
        onChange?()
        onListChanged?(tasks)
        TodoTaskStates.forget()         // [chat-mark-done]
    }
}

/// Fields as the routes take them.
nonisolated enum TodoWire {
    static func steps(_ steps: [TodoStep]) -> JSONValue {
        .array(steps.map { .object(["id": .string($0.id), "title": .string($0.title), "who": .string($0.who), "done": .bool($0.done)]) })
    }

    static func optional(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }

    /// A new task's body.
    static func newTask(title: String, who: TodoWho, bot: String?, due: String?, repeatRule: String?, prep: Bool,
                        notes: String = "", steps: [TodoStep] = [], source: TodoSource? = TodoSource(kind: "app"),
                        goal: String? = nil, milestone: String? = nil) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "title": .string(title), "who": .string(who.rawValue), "notes": .string(notes), "prep": .bool(prep && who != .me),
            "steps": Self.steps(steps), "due": optional(due), "repeat": optional(who == .bot ? nil : repeatRule),
        ]
        body["bot"] = who == .me ? .null : optional(bot ?? "default")
        if let source {
            var object: [String: JSONValue] = ["kind": .string(source.kind)]
            if let profile = source.profile { object["profile"] = .string(profile) }
            if let session = source.sessionId { object["session_id"] = .string(session) }
            if let reminder = source.reminderId { object["reminder_id"] = .string(reminder) }
            body["source"] = .object(object)
        }
        // [goals] Added on a goal's page: it starts in that goal (and the milestone it was added under). Sent only
        // then, so an older add-on never sees the keys.
        if let goal {
            body["goal"] = .string(goal)
            if let milestone { body["milestone"] = .string(milestone) }
        }
        return body
    }

    /// Builds a clean `POST /tasks` body cloning `task` as a fresh open task with unticked steps.
    static func duplicate(_ task: TodoTask, fieldsSupported: Bool, goalsSupported: Bool) -> [String: JSONValue] {
        let freshSteps = task.steps.map { TodoStep(id: TodoIDs.make(), title: $0.title, who: $0.who, done: false) }
        var body = newTask(
            title: task.title,
            who: task.whoKind,
            bot: task.helper,
            due: task.due,
            repeatRule: task.whoKind == .bot || (task.whoKind == .together && !fieldsSupported) ? nil : task.repeatRule,
            prep: task.prep,
            notes: task.notes,
            steps: freshSteps,
            source: TodoSource(kind: "app"),
            goal: goalsSupported ? task.goal : nil,
            milestone: goalsSupported ? task.milestone : nil
        )
        if let section = task.section { body["section"] = .string(section) }
        if fieldsSupported {
            if task.priority > 0 { body["priority"] = .number(Double(task.priority)) }
            if !task.tags.isEmpty { body["tags"] = .array(task.tags.map(JSONValue.string)) }
            if let starts = task.starts { body["starts"] = .string(starts) }
            if let alert = task.alert { body["alert"] = .number(Double(alert)) }
        }
        return body
    }
}
