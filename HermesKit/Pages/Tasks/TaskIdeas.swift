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

/// An auto-discovered connected app (direct MCP server or Composio app) on one or more bot profiles.
nonisolated struct TaskIdeasConnector: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    /// `"mcp"` or `"composio"`.
    var kind: String = "mcp"
    var bots: [String] = []

    init(id: String, name: String, kind: String = "mcp", bots: [String] = []) {
        self.id = id; self.name = name; self.kind = kind; self.bots = bots
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "mcp"
        bots = (try? c.decodeIfPresent([String].self, forKey: .bots)) ?? []
    }
}

/// Auto-discovered connectors and bot profiles from `GET /tasks/ideas` or `GET /tasks/ideas/sources`.
nonisolated struct TaskIdeasAvailableSources: Codable, Hashable, Sendable {
    var connectors: [TaskIdeasConnector] = []
    var bots: [String] = []

    init(connectors: [TaskIdeasConnector] = [], bots: [String] = []) {
        self.connectors = connectors; self.bots = bots
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connectors = (try? c.decodeIfPresent([TaskIdeasConnector].self, forKey: .connectors)) ?? []
        bots = (try? c.decodeIfPresent([String].self, forKey: .bots)) ?? []
    }
}

/// Pure formatting and toggle rules for Suggested Tasks' Where to Look controls (unit-tested).
nonisolated enum TaskIdeasSummary {
    static func prettyConnectorName(_ id: String) -> String {
        let slug = id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id
        let map = [
            "gmail": "Gmail", "googlecalendar": "Google Calendar", "google_calendar": "Google Calendar",
            "google-calendar": "Google Calendar", "googledrive": "Google Drive", "notion": "Notion",
            "slack": "Slack", "github": "GitHub", "linear": "Linear", "jira": "Jira",
            "asana": "Asana", "trello": "Trello", "airtable": "Airtable", "hubspot": "HubSpot",
            "salesforce": "Salesforce", "outlook": "Outlook", "todoist": "Todoist",
        ]
        if let hit = map[slug.lowercased()] { return hit }
        return slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Concise summary shown on the Suggested page banner and in Tasks Settings ("Chats, Memory, Gmail, Notion").
    static func activeSourcesLabel(sources: TodoIdeasSources, available: [TaskIdeasConnector]) -> String {
        var parts: [String] = []
        if sources.chats { parts.append("Chats") }
        if sources.memory { parts.append("Memory") }
        if sources.files { parts.append("Files") }
        if sources.web { parts.append("Web") }
        let byID = Dictionary(available.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for cid in sources.connectors {
            parts.append(byID[cid] ?? prettyConnectorName(cid))
        }
        return parts.isEmpty ? "No sources selected" : parts.joined(separator: ", ")
    }

    /// Concise label for the participating bots ("Hermes", "Hermes & Work", "Hermes, Work +1").
    static func activeBotsLabel(active: [String], bots: [(id: String, name: String)]) -> String {
        let names = active.map { id in bots.first { $0.id == id }?.name ?? id }
        switch names.count {
        case 0: return bots.first?.name ?? "Hermes"
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default: return "\(names[0]), \(names[1]) +\(names.count - 2)"
        }
    }

    /// Subtitle for the Recent Chats row in Where to Look.
    static func chatBotsSubtitle(sources: TodoIdeasSources, bots: [(id: String, name: String)]) -> String {
        guard sources.chats else { return "Off · blocked during runs" }
        guard bots.count > 1 else { return "Recent messages from your chats" }
        let allIDs = Set(bots.map(\.id))
        let picked = sources.chatBots.filter { allIDs.contains($0) }
        if picked.isEmpty || picked.count >= bots.count { return "All bots" }
        let excluded = bots.count - picked.count
        let names = picked.prefix(2).map { id in bots.first { $0.id == id }?.name ?? id }.joined(separator: ", ")
        let suffix = picked.count > 2 ? " +\(picked.count - 2)" : ""
        return "\(names)\(suffix) · \(excluded) \(excluded == 1 ? "bot" : "bots") excluded"
    }

    /// Toggles a connected app on or off. Turning on an app that lives on a bot not yet in `activeBots`
    /// automatically adds that bot to `activeBots` so multi-bot sweeps cover it seamlessly.
    static func toggleConnector(_ id: String, on: Bool, connector: TaskIdeasConnector?,
                                sources: inout TodoIdeasSources, activeBots: inout [String]) {
        if on {
            if !sources.connectors.contains(id) { sources.connectors.append(id) }
            if let owners = connector?.bots, !owners.isEmpty, !owners.contains(where: { activeBots.contains($0) }) {
                activeBots.append(owners[0])
            }
        } else {
            sources.connectors.removeAll { $0 == id }
        }
    }
}

/// `GET /tasks/ideas`.
nonisolated struct TaskIdeasPage: Codable, Hashable, Sendable {
    var on = false
    /// Primary bot that looks each day.
    var bot = "default"
    /// [task-ideas 0.9.86] Participating bots for multi-bot sweeps.
    var bots: [String]?
    /// "07:30", on the computer's clock.
    var at = "07:30"
    var max = 3
    /// [task-ideas 0.9.86] Active sources, instructions, and auto-discovered connectors.
    var sources: TodoIdeasSources?
    var note: String?
    var availableSources: TaskIdeasAvailableSources?
    var ideas: [TaskIdea] = []
    /// When the daily look last answered.
    var ranAt: String?
    /// Look Now is under way.
    var looking = false

    var activeBots: [String] {
        if let bots, !bots.isEmpty { return bots }
        return [bot]
    }

    enum CodingKeys: String, CodingKey {
        case on, bot, bots, at, max, sources, note, availableSources = "available_sources", ideas, ranAt = "ran_at", looking
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? false
        bot = (try? c.decodeIfPresent(String.self, forKey: .bot)) ?? "default"
        bots = try? c.decodeIfPresent([String].self, forKey: .bots)
        at = (try? c.decodeIfPresent(String.self, forKey: .at)) ?? "07:30"
        max = (try? c.decodeIfPresent(Int.self, forKey: .max)) ?? 3
        sources = try? c.decodeIfPresent(TodoIdeasSources.self, forKey: .sources)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        availableSources = try? c.decodeIfPresent(TaskIdeasAvailableSources.self, forKey: .availableSources)
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

    @concurrent
    func ideasSources() async throws -> TaskIdeasAvailableSources {
        try JSONDecoder().decode(TaskIdeasAvailableSources.self, from: try await PagesREST.send(client, "GET", Self.ideasBase + "/sources"))
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
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var closed = false
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
        guard !closed else { return }
        prepare()
        if !force, let at = lastReadAt, Date().timeIntervalSince(at) < 2 { return }
        loading = true
        onChange?()
        defer { loading = false; onChange?() }
        do {
            let fresh = try await api.ideas()
            guard !closed else { return }
            lastReadAt = Date()
            error = nil
            adopt(fresh)
            if fresh.looking { poll() } else { stopPolling() }
        } catch {
            guard !closed else { return }
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
    /// False when it couldn't come back (the notice says why).
    @discardableResult
    func restore(_ idea: TaskIdea) async -> Bool {
        if let pending = dismissing[idea.id], await !pending.value { return true }   // the dismiss never landed
        do {
            try await api.restoreIdea(idea.id)
            decided.remove(idea.id)
            await refresh(force: true)
            return true
        } catch {
            onNotice?("Couldn’t bring it back. \(PagesREST.reason(error))")
            return false
        }
    }

    /// Look Now; the page says Looking… and reads again every few seconds until the look answers (ten minutes at most).
    @discardableResult
    func lookNow() async -> Bool {
        do {
            _ = try await api.lookForIdeas()
            if var shownPage = page { shownPage.looking = true; page = shownPage; onChange?() }
            AppLog.note("tasks", "ideas look asked for")
            poll()
            return true
        } catch {
            onNotice?("Couldn’t look now. \(PagesREST.reason(error))")
            return false
        }
    }

    /// Stops any active "Look Now" poll (view disappeared, app backgrounded, or sign-out).
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Sign-out or gateway switch: stop polling and drop in-memory state.
    func forget() {
        closed = true
        stopPolling()
        for task in dismissing.values { task.cancel() }
        dismissing = [:]
        decided = []
        page = nil
        prepared = false
    }

    private func poll() {
        guard !closed, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            defer { self?.pollTask = nil }
            let started = Date()
            while !Task.isCancelled, let self, !self.closed, Date().timeIntervalSince(started) < 600 {
                do {
                    try await Task.sleep(for: .seconds(4))
                } catch {
                    break
                }
                guard !Task.isCancelled, !self.closed else { break }
                await self.refresh(force: true)
                if self.page?.looking != true { break }
            }
        }
    }
}
