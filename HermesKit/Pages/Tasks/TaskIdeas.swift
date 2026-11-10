// [task-ideas] The Tasks page's Ideas (hermes-hq-push 0.9.39). Owner 2026-11-05: "you land on the main tasks page but
// you can click the additional tab/page to see tasks that your agent suggests could be started based on all of your
// context … maybe a daily cron that searches all past activity and stuff it has access to (in a safe way)". Once
// you turn it on, one bot looks over your recent chats (and whatever else it can reach) each day and suggests a few
// tasks; that run can't add tasks itself. An idea is never a task until you add it; a dismissed one isn't offered
// again.

import Foundation
import Observation

/// One suggested task.
nonisolated struct TaskIdea: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var createdAt: String = ""
    /// The bot that would help (or that looked, for your own).
    var bot: String = "default"
    var title: String = ""
    /// What the bot saw, and why now.
    var why: String = ""
    /// Where it came from, in a few words ("Chat with Finance, Mon").
    var source: String = ""
    /// "me" | "together" | "bot".
    var who: String = "me"
    /// What the bot would do to help, in a line ("" for your own).
    var help: String = ""
    var state: String = "new"
    var taskID: String?

    enum CodingKeys: String, CodingKey {
        case id, createdAt = "created_at", bot, title, why, source, who, help, state, taskID = "task_id"
    }

    init(id: String, title: String, why: String = "", source: String = "", who: String = "me", help: String = "", bot: String = "default") {
        self.id = id; self.title = title; self.why = why; self.source = source; self.who = who; self.help = help; self.bot = bot
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? ""
        bot = (try? c.decodeIfPresent(String.self, forKey: .bot)) ?? "default"
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        why = (try? c.decodeIfPresent(String.self, forKey: .why)) ?? ""
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? ""
        who = (try? c.decodeIfPresent(String.self, forKey: .who)) ?? "me"
        help = (try? c.decodeIfPresent(String.self, forKey: .help)) ?? ""
        state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? "new"
        taskID = try? c.decodeIfPresent(String.self, forKey: .taskID)
    }

    /// A bot can take part of it, so it can be added with that bot starting.
    var botHelps: Bool { who != "me" }
}

/// `GET /tasks/ideas`.
nonisolated struct TaskIdeasPage: Codable, Hashable, Sendable {
    var on = false
    /// The bot that looks each day.
    var bot = "default"
    /// "07:30", on the computer's clock.
    var at = "07:30"
    var max = 3
    var ideas: [TaskIdea] = []
    /// When the daily look last answered.
    var ranAt: String?
    /// Look Now is under way.
    var looking = false

    enum CodingKeys: String, CodingKey { case on, bot, at, max, ideas, ranAt = "ran_at", looking }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? false
        bot = (try? c.decodeIfPresent(String.self, forKey: .bot)) ?? "default"
        at = (try? c.decodeIfPresent(String.self, forKey: .at)) ?? "07:30"
        max = (try? c.decodeIfPresent(Int.self, forKey: .max)) ?? 3
        // One bad idea never loses the page.
        if let raw = try? c.decodeIfPresent([JSONValue].self, forKey: .ideas) {
            ideas = raw.compactMap { value in (try? value.encoded()).flatMap { try? JSONDecoder().decode(TaskIdea.self, from: $0) } }
        }
        ranAt = try? c.decodeIfPresent(String.self, forKey: .ranAt)
        looking = (try? c.decodeIfPresent(Bool.self, forKey: .looking)) ?? false
    }
}

extension TasksAPI {
    private static var ideasBase: String { base + "/ideas" }

    @concurrent
    func ideas() async throws -> TaskIdeasPage {
        try JSONDecoder().decode(TaskIdeasPage.self, from: try await PagesREST.send(client, "GET", Self.ideasBase))
    }

    /// The idea becomes a task (or the open one that's the same thing). `start`: its bot starts on its part now.
    @concurrent
    func addIdea(_ id: String, start: Bool) async throws -> TodoTask {
        let data = try await PagesREST.send(client, "POST", Self.ideasBase + "/" + PagesREST.segment(id) + "/add",
                                            json: .object(["start": .bool(start)]), timeout: 30)
        return try Self.task(data)
    }

    @concurrent
    func dismissIdea(_ id: String) async throws {
        _ = try await PagesREST.send(client, "POST", Self.ideasBase + "/" + PagesREST.segment(id) + "/dismiss")
    }

    @concurrent
    func restoreIdea(_ id: String) async throws {
        _ = try await PagesREST.send(client, "POST", Self.ideasBase + "/" + PagesREST.segment(id) + "/restore")
    }

    /// Look Now: the daily look runs at its next tick. false: one was asked for in the last 15 minutes.
    @concurrent
    func lookForIdeas() async throws -> Bool {
        let data = try await PagesREST.send(client, "POST", Self.ideasBase + "/run", timeout: 30)
        return (try? JSONValue.parse(data))?["started"]?.bool ?? false
    }
}

/// The Ideas page's data: painted from disk, then read; a decision shows at once and is undone if the gateway refuses.
@MainActor @Observable
final class TaskIdeasStore {
    let api: TasksAPI
    let directory: URL?

    private(set) var page: TaskIdeasPage?
    private(set) var error: String?
    private(set) var loading = false
    /// Added or dismissed here, gone from the page before the gateway answers.
    private(set) var decided: Set<String> = []

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onNotice: ((String) -> Void)?
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var lastReadAt: Date?
    @ObservationIgnored private var polling = false
    /// Dismisses still on their way, by idea: an Undo waits for its dismiss to land before it asks for the idea back
    /// (sent at once, the restore could reach the gateway first and the dismiss then win).
    @ObservationIgnored private var dismissing: [String: Task<Bool, Never>] = [:]

    init(api: TasksAPI, directory: URL?) {
        self.api = api
        self.directory = directory
    }

    private var cacheURL: URL? { directory?.appending(path: "task-ideas.json") }

    /// The new ideas still to decide, newest first.
    var shown: [TaskIdea] { (page?.ideas ?? []).filter { !decided.contains($0.id) } }

    func prepare() {
        guard !prepared else { return }
        prepared = true
        guard page == nil, let url = cacheURL, let cached = PagesCache.read(PagesCached<TaskIdeasPage>.self, url) else { return }
        page = cached.value
        onChange?()
    }

    private func adopt(_ fresh: TaskIdeasPage) {
        page = fresh
        decided = decided.filter { id in fresh.ideas.contains { $0.id == id } }
        if let url = cacheURL { PagesCache.write(PagesCached(at: Date().timeIntervalSince1970, value: fresh), to: url) }
        onChange?()
    }

    func refresh(force: Bool = false) async {
        prepare()
        if !force, let at = lastReadAt, Date().timeIntervalSince(at) < 2 { return }
        loading = true
        onChange?()
        defer { loading = false; onChange?() }
        do {
            let fresh = try await api.ideas()
            lastReadAt = Date()
            error = nil
            adopt(fresh)
            if fresh.looking { poll() }
        } catch {
            self.error = PagesREST.reason(error)
        }
    }

    /// Saves Ideas on or off (and the rest of Tasks Settings with it) and reads the page again.
    func setOn(_ on: Bool, tasks: TasksStore) async {
        var next = tasks.settings
        next.ideas = on
        if var shownPage = page { shownPage.on = on; page = shownPage; onChange?() }
        await tasks.saveSettings(next)
        await refresh(force: true)
    }

    /// The idea becomes a task; nil (and the idea back) when it failed.
    func add(_ idea: TaskIdea, start: Bool) async -> TodoTask? {
        decided.insert(idea.id)
        onChange?()
        do {
            let task = try await api.addIdea(idea.id, start: start)
            AppLog.note("tasks", "idea added\(start ? ", its bot starting" : "")")
            await refresh(force: true)
            return task
        } catch {
            decided.remove(idea.id)
            onChange?()
            onNotice?("Couldn’t add it. \(PagesREST.reason(error))")
            return nil
        }
    }

    func dismiss(_ idea: TaskIdea) async -> Bool {
        decided.insert(idea.id)
        onChange?()
        let api = api, id = idea.id
        let request = Task { () -> Bool in
            do {
                try await api.dismissIdea(id)
                return true
            } catch {
                self.dismissFailed(id, error)
                return false
            }
        }
        dismissing[id] = request
        let ok = await request.value
        if dismissing[id] == request { dismissing[id] = nil }
        if ok { AppLog.note("tasks", "idea dismissed") }
        return ok
    }

    private func dismissFailed(_ id: String, _ error: Error) {
        decided.remove(id)
        onChange?()
        onNotice?("Couldn’t dismiss it. \(PagesREST.reason(error))")
    }

    /// Undo a dismiss: after the dismiss has landed (one that failed has already put the idea back).
    func restore(_ idea: TaskIdea) async {
        if let pending = dismissing[idea.id], await !pending.value { return }
        do {
            try await api.restoreIdea(idea.id)
            decided.remove(idea.id)
            await refresh(force: true)
        } catch {
            onNotice?("Couldn’t bring it back. \(PagesREST.reason(error))")
        }
    }

    /// Look Now; the page says Looking… and reads again every few seconds until the look answers (ten minutes at most).
    func lookNow() async {
        do {
            _ = try await api.lookForIdeas()
            if var shownPage = page { shownPage.looking = true; page = shownPage; onChange?() }
            AppLog.note("tasks", "ideas look asked for")
            poll()
        } catch {
            onNotice?("Couldn’t look now. \(PagesREST.reason(error))")
        }
    }

    private func poll() {
        guard !polling else { return }
        polling = true
        Task { [weak self] in
            let started = Date()
            while let self, Date().timeIntervalSince(started) < 600 {
                try? await Task.sleep(for: .seconds(4))
                await self.refresh(force: true)
                if self.page?.looking != true { break }
            }
            self?.polling = false
        }
    }
}
