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
        let list = JSONValue.array(sections.map { .object(["id": .string(TodoIDs.isLocal($0.id) ? "" : $0.id), "name": .string($0.name)]) })
        let data = try await PagesREST.send(client, "PUT", Self.base + "/sections", json: .object(["sections": list]))
        struct Answer: Decodable { var sections: [TodoUserSection] }
        return try JSONDecoder().decode(Answer.self, from: data).sections
    }

    /// `POST /tasks/prep-job/{profile}`: that bot's "Task prep" scheduled job made, or removed, to match its open prep
    /// tasks (hermes-hq-push 0.9.32). A failure is only logged: the bot's own task tools reconcile it again.
    @concurrent
    func reconcilePrep(_ profile: String) async {
        do { _ = try await PagesREST.send(client, "POST", Self.base + "/prep-job/" + PagesREST.segment(profile), timeout: 30) }
        catch { AppLog.note("tasks", "prep job for \(profile) not reconciled: \(PagesREST.reason(error))") }
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
}

@MainActor @Observable
final class TasksStore {
    let api: TasksAPI
    let account: GatewayAccount
    let directory: URL?
    var readOnlyGateway = false

    /// Every task (optimistic edits applied).
    private(set) var tasks: [TodoTask] = []
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

    @ObservationIgnored var onChange: (() -> Void)?
    /// A write failed or gave way: plain words for a notice.
    @ObservationIgnored var onNotice: ((String) -> Void)?
    /// The task the last notice is about; nil when it is about the list as a whole (its settings or sections). The Mac's
    /// two panes say it on the task beside the list only when it is that task (Mac polish #44).
    @ObservationIgnored private(set) var noticeTask: String?
    /// A refresh failed while a list shows (the page says "Couldn’t refresh. Showing what was saved.", as Jobs does).
    @ObservationIgnored var onRefreshFailed: ((String) -> Void)?
    /// Why the last `add` failed, in words (New Task's sheet says it on its own line; nil when it worked).
    @ObservationIgnored private(set) var addFailure: String?
    /// Every list change (local reminders follow it).
    @ObservationIgnored var onListChanged: (([TodoTask]) -> Void)?

    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var inFlight: [String: Int] = [:]
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var lastReadAt: Date?
    @ObservationIgnored private var sectionsWriting = false
    /// [13-5] Forgotten at sign-out or a switch: an answer still on its way neither writes tasks.json again nor resets
    /// the phone's due reminders to this account's tasks.
    @ObservationIgnored private var closed = false

    init(api: TasksAPI, account: GatewayAccount, directory: URL?) {
        self.api = api
        self.account = account
        self.directory = directory
    }

    // MARK: Cache

    private var cacheURL: URL? { directory?.appending(path: "tasks.json") }

    /// The page is about to draw: paint the list from disk.
    func prepare() {
        guard !prepared, !closed else { return }
        prepared = true
        guard !hasList, let url = cacheURL, let cached = PagesCache.read(PagesCached<TodoSnapshot>.self, url) else { return }
        tasks = cached.value.tasks
        settings = cached.value.settings
        sections = cached.value.sections ?? []
        sectionsSupported = cached.value.sections != nil
        pagesSupported = cached.value.pages == true
        ideasCount = cached.value.ideas
        rev = cached.value.rev
        hasList = true
        changed()
    }

    private func save() {
        guard !closed, let url = cacheURL else { return }
        let snapshot = TodoSnapshot(rev: rev, tasks: tasks.filter { !TodoIDs.isLocal($0.id) }, settings: settings,
                                    sections: sectionsSupported ? sections.filter { !TodoIDs.isLocal($0.id) } : nil,
                                    pages: pagesSupported, ideas: ideasCount)
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
            ideasCount = answer.ideas
            if !sectionsWriting {
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

    /// A read's list, keeping tasks that have a write on its way and ones added here and not yet answered.
    private func adopt(_ fresh: [TodoTask], rev: Int, settings: TodoSettings?) {
        var next = fresh
        for local in tasks where inFlight[local.id] != nil || TodoIDs.isLocal(local.id) {
            if let at = next.firstIndex(where: { $0.id == local.id }) { next[at] = local } else { next.append(local) }
        }
        tasks = next
        self.rev = rev
        if let settings { self.settings = settings }
        hasList = true
        save()
        changed()
    }

    /// [task-ideas] The Ideas page read or decided: the switch's count follows it at once.
    func ideasRead(_ count: Int) {
        guard ideasCount != nil, ideasCount != count else { return }
        ideasCount = count
        save()
        onChange?()
    }

    // MARK: Writes

    private func refuse(quiet: Bool = false, about task: String? = nil) -> Bool {
        guard readOnlyGateway else { return false }
        if !quiet { notice(JobsStore.readOnlyNotice, about: task) }
        return true
    }

    private func notice(_ text: String, about task: String? = nil) {
        noticeTask = task
        onNotice?(text)
    }

    private func put(_ task: TodoTask) {
        if let at = tasks.firstIndex(where: { $0.id == task.id }) { tasks[at] = task } else { tasks.append(task) }
    }

    private func begin(_ id: String) { inFlight[id, default: 0] += 1 }
    private func end(_ id: String) {
        let left = (inFlight[id] ?? 1) - 1
        inFlight[id] = left > 0 ? left : nil
    }

    /// Adds a task: shown at once, then swapped for the gateway's (its id, rev and times). nil when it failed, with
    /// the reason in `addFailure`. `quiet`: no notice of its own (Import from Reminders sums its adds up in one).
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
        if let data = try? JSONValue.object(draft).encoded(), let shown = try? JSONDecoder().decode(TodoTask.self, from: data) {
            tasks.append(shown)
            changed()
        }
        do {
            let made = try await api.create(fields)
            tasks.removeAll { $0.id == localID }
            put(made)
            save()
            changed()
            reconcilePrep(TodoEdits.prepBots(before: nil, after: made, fields: nil))
            return made
        } catch {
            tasks.removeAll { $0.id == localID }
            changed()
            let reason = PagesREST.reason(error)
            addFailure = reason
            if !quiet { notice("Couldn’t add the task. \(reason)") }
            return nil
        }
    }

    /// Changes a task's fields (wire names). The change shows at once; a 409 re-sends it on the current rev when the
    /// other edit left these fields alone, and otherwise shows the current version.
    /// `touch`: the shown task counts as changed now (Keep, which sends no fields).
    @discardableResult
    func patch(_ id: String, _ fields: [String: JSONValue], touch: Bool = false) async -> Bool {
        guard !refuse(about: id), let base = task(id) else { return false }
        guard !TodoIDs.isLocal(id) else { notice("This task is still being added. Try again in a moment.", about: id); return false }
        if var shown = TodoEdits.applying(fields, to: base) {
            if touch { shown.updatedAt = TodoDates.now() }
            put(shown); changed()
        }
        begin(id)
        defer { end(id) }
        do {
            let answer = try await api.patch(id, rev: base.rev, fields: fields)
            put(answer)
            save()
            changed()
            reconcilePrep(TodoEdits.prepBots(before: base, after: answer, fields: Set(fields.keys)))
            return true
        } catch {
            if let current = TasksAPI.conflict(error) {
                switch TodoEdits.resolve(base: base, current: current, fields: fields) {
                case .resend(let rev):
                    if let answer = try? await api.patch(id, rev: rev, fields: fields) {
                        put(answer); save(); changed()
                        reconcilePrep(TodoEdits.prepBots(before: base, after: answer, fields: Set(fields.keys)))
                        return true
                    }
                    put(current); save(); changed()
                    notice("This task changed somewhere else. Showing the latest.", about: id)
                    return false
                case .theirs:
                    put(current); save(); changed()
                    notice("This task changed somewhere else. Showing the latest.", about: id)
                    return false
                }
            }
            if PagesREST.status(error) == 404 {
                tasks.removeAll { $0.id == id }
                save(); changed()
                notice("This task was deleted somewhere else.", about: id)
                return false
            }
            put(base)
            changed()
            notice("Couldn’t save the change. \(PagesREST.reason(error))", about: id)
            return false
        }
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

    /// Deletes a task (a chat card's Undo too: the task may not be in the list yet).
    @discardableResult
    func delete(_ id: String) async -> Bool {
        guard !refuse(about: id) else { return false }
        let at = tasks.firstIndex { $0.id == id }
        let removed = at.map { tasks.remove(at: $0) }
        if removed != nil { changed() }
        do {
            try await api.delete(id)
            save()
            reconcilePrep(TodoEdits.prepBots(before: removed, after: nil, fields: nil))
            return true
        } catch {
            if PagesREST.status(error) == 404 { save(); return true }
            if let removed, let at { tasks.insert(removed, at: min(at, tasks.count)); changed() }
            notice("Couldn’t delete the task. \(PagesREST.reason(error))", about: id)
            return false
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
        let before = sections, beforeTasks = tasks
        let kept = Set(next.map(\.id))
        sections = next
        tasks = tasks.map { task in
            guard let id = task.section, !kept.contains(id) else { return task }
            var task = task; task.section = nil; return task
        }
        changed()
        sectionsWriting = true
        defer { sectionsWriting = false }
        do {
            let saved = try await api.saveSections(next)
            sections = saved
            save()
            changed()
            Task { await refresh(force: true) }
            return saved
        } catch {
            sections = before
            tasks = beforeTasks
            changed()
            notice("Couldn’t save your sections. \(PagesREST.reason(error))")
            return nil
        }
    }

    /// Adds a section at the end; returns it (with the gateway's id).
    func addSection(named name: String) async -> TodoUserSection? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let draft = TodoUserSection(id: TodoIDs.local(), name: String(clean.prefix(60)))
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
        tasks = []
        sections = []
        rev = 0
        hasList = false
        prepared = false
        readGeneration += 1             // a read on its way is dropped
        changed()
        closed = true
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
                        notes: String = "", steps: [TodoStep] = [], source: TodoSource? = TodoSource(kind: "app")) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "title": .string(title), "who": .string(who.rawValue), "notes": .string(notes), "prep": .bool(prep && who != .me),
            "steps": Self.steps(steps), "due": optional(due), "repeat": optional(who == .me ? repeatRule : nil),
        ]
        body["bot"] = who == .me ? .null : optional(bot ?? "default")
        if let source {
            var object: [String: JSONValue] = ["kind": .string(source.kind)]
            if let profile = source.profile { object["profile"] = .string(profile) }
            if let session = source.sessionId { object["session_id"] = .string(session) }
            if let reminder = source.reminderId { object["reminder_id"] = .string(reminder) }
            body["source"] = .object(object)
        }
        return body
    }
}
