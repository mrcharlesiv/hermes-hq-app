// [tasks-widget] The app's side of the Tasks widget (docs/tasks.md item 12): writes the Tasks page's first screen for
// each view the widget can show, worded by the page's own rules (`TodoViews.groups`, `.heading`, `.row`, `.openCount`,
// `.emptyText`, `TodoLists.dot`), into the store the widget reads (HomeWidgetsKit/TasksWidgetStore.swift). Each view
// holds a frame for now and for each moment in the next two days its words change by the clock (midnight, a due time, a
// bot's task growing stale), so the widget moves on by itself between the app's writes.
//
// Written whenever the Tasks list changes (the store is observed: a read, an edit here or on another device, Tasks
// turned off), when the app comes to the front, and from the background refresh and the pushed wake-up (`WidgetRefresh`),
// which read the list first (one small request; no web view). The list is the one the Tasks page shows: the gateway
// in use (docs/tasks.md rule 6), through `TasksHub`'s store. On the Mac, and in an identity without the widget
// extension, it does nothing.
//
// The check circle (`TaskCheckOffIntent`) runs here, in the app: the row shows ticked at once, the save goes through
// `TasksStore.setDone` (as the page's own circle: a repeating task rolls on to its next date, steps are left as they
// are), and a refused save puts the row back.

import UIKit
import WidgetKit

@MainActor
final class TasksWidgetWriter {
    static let shared = TasksWidgetWriter()
    nonisolated static let kind = "ai.hermes.hq.tasks"

    static var enabled: Bool { TileWidgetWriter.enabled }

    /// How far ahead frames are written, and at most how many a view keeps.
    nonisolated static let horizon: TimeInterval = 48 * 3600
    nonisolated static let maxFrames = 24
    /// The rows a frame keeps (the Extra Large widget shows about 10).
    nonisolated static let maxRows = 16

    /// This build has the widget extension (tests make their own writer with it on).
    let enabled: Bool
    /// The store the Tasks page shows (tests hand one in).
    private let currentStore: @MainActor () -> TasksStore?
    /// How long a row ticked on the widget stays ticked at least, before it moves (as the page's row does).
    var holdTicked: TimeInterval = 1

    init(enabled: Bool = TasksWidgetWriter.enabled, store: @escaping @MainActor () -> TasksStore? = { TasksHub.current }) {
        self.enabled = enabled
        self.currentStore = store
    }

    private var account: GatewayAccount?
    var accountKey: String? { account.map { TileWidgetIndex.key($0.id) } }
    private var bots: () -> [Bot] = { [] }
    private var observers: [NSObjectProtocol] = []
    private weak var watched: TasksStore?
    private var writePending = false
    /// Serial background queue for routine Keychain writes so `scheduleWrite()` never blocks the main thread.
    private static let ioQueue = DispatchQueue(label: "ai.hermes.hq.tasks-widget-io", qos: .utility)
    /// Tasks ticked on a widget whose save is on its way: shown ticked where they stood (as the page's `ticking`).
    private var ticking: [String: TodoTask] = [:]

    // MARK: Signed in and out

    /// Once at launch: the check circle's work, for an intent iOS hands the app (it may have launched for it).
    static func install() {
        #if !targetEnvironment(macCatalyst)
        guard enabled else { return }
        TasksWidgetActions.checkOff = { task, account in await shared.checkOffFromWidget(task, account: account) }
        #endif
    }

    func attach(account: GatewayAccount, bots: @escaping () -> [Bot]) {
        guard enabled else { return }
        detach()
        self.account = account
        self.bots = bots
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleWrite() }   // TasksHub reads the list then; the observation writes again
        })
        observers.append(center.addObserver(forName: SessionStrip.listChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleWrite() }   // a bot renamed: its name on rows and headings
        })
        scheduleWrite()
    }

    /// Sign-out (or a switch): the widget says "Open Hermes HQ"; no task stays where it reads. Synchronous for tests.
    func signedOut() {
        guard enabled else { return }
        detach()
        account = nil
        ticking = [:]
        if TasksWidgetStore.quiet(.signedOut, scheme: AppIdentity.current.urlScheme) { Self.reload() }
        #if DEBUG
        TileWidgetWriter.showProbe()
        #endif
        AppLog.note("widgets", "tasks widget: signed out")
    }

    /// Production sign-out: clears local state on `@MainActor` immediately and moves Keychain clearing off main.
    func signedOutAsync() {
        guard enabled else { return }
        detach()
        account = nil
        ticking = [:]
        let scheme = AppIdentity.current.urlScheme
        Self.ioQueue.async {
            let changed = TasksWidgetStore.quiet(.signedOut, scheme: scheme)
            if changed { Self.reload() }
            Task { @MainActor in
                #if DEBUG
                TileWidgetWriter.showProbe()
                #endif
                AppLog.note("widgets", "tasks widget: signed out")
            }
        }
    }

    private func detach() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        watched = nil
    }

    nonisolated static func reload() { WidgetCenter.shared.reloadTimelines(ofKind: kind) }

    // MARK: Watching the list

    /// The store the Tasks page shows, observed: any change to what the page draws writes the widget again.
    private func watch(_ store: TasksStore) {
        guard watched !== store else { return }
        watched = store
        track(store)
    }

    private func track(_ store: TasksStore) {
        withObservationTracking {
            _ = store.tasks
            _ = store.sections
            _ = store.settings
            _ = store.goals
            _ = store.hasList
            _ = store.needsAddOn
        } onChange: { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store, self.watched === store else { return }
                self.track(store)
                self.scheduleWrite()
            }
        }
    }

    private func scheduleWrite() {
        guard account != nil, !writePending else { return }
        writePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.writePending = false
            self.writeAsync(reason: "list changed")
        }
    }

    private nonisolated enum PreparedWrite: Sendable {
        case none
        case quiet(state: TasksWidgetIndex.State, scheme: String, account: String)
        case live(scheme: String, account: String, input: Input, botName: @Sendable (String?) -> String, now: Date)
    }

    private func prepareWrite(now: Date = Date()) -> PreparedWrite {
        guard enabled, let account, let key = accountKey else { return .none }
        let scheme = AppIdentity.current.urlScheme
        guard let store = currentStore(), store.account.id == account.id else { return .none }
        watch(store)
        store.prepare()
        let state: TasksWidgetIndex.State = TasksHub.isOff(store.account) ? .off
            : store.needsAddOn ? .needsAddOn : store.hasList ? .live : .noList
        guard state == .live else { return .quiet(state: state, scheme: scheme, account: key) }
        let roster = bots()
        let tasks = store.tasks.map { ticking[$0.id] ?? $0 }
        var profiles = Set(roster.map(\.id))
        profiles.insert("default")
        for task in tasks {
            if let helper = task.helper { profiles.insert(helper) }
            if let by = task.createdBy { profiles.insert(by) }
            if let offerBy = task.offer?.by { profiles.insert(offerBy) }
        }
        let namesByProfile = Dictionary(uniqueKeysWithValues: profiles.map { ($0, PagesNames.botName($0, bots: roster)) })
        let botName: @Sendable (String?) -> String = { profile in
            let id = profile ?? "default"
            return namesByProfile[id] ?? (id == "default" ? "Hermes" : id.capitalized)
        }
        let input = Input(tasks: tasks, sections: store.sections, bots: roster.map(\.id), sort: store.settings.sort,
                          paused: GoalViews.paused(store.goals), goals: store.goals, ticking: Set(ticking.keys))
        return .live(scheme: scheme, account: key, input: input, botName: botName, now: now)
    }

    private nonisolated static func performWrite(_ prep: PreparedWrite) -> (changed: Bool, logLine: String?) {
        switch prep {
        case .none:
            return (false, nil)
        case .quiet(let state, let scheme, let key):
            let changed = TasksWidgetStore.quiet(state, scheme: scheme, account: key)
            return (changed, changed ? state.rawValue : nil)
        case .live(let scheme, let key, let input, let botName, let now):
            let result = Self.persistLive(scheme: scheme, account: key, input: input, botName: botName, now: now)
            return (result.changed, result.changed ? "written, \(result.viewCount) views, \(result.openCount) open" : nil)
        }
    }

    /// Snapshots store state on `@MainActor`, then builds all widget views and writes Keychain off the main thread.
    private func writeAsync(reason: String, now: Date = Date()) {
        let prep = prepareWrite(now: now)
        guard case .none = prep else {
            Self.ioQueue.async {
                let result = Self.performWrite(prep)
                if result.changed {
                    Self.reload()
                    Task { @MainActor in
                        #if DEBUG
                        TileWidgetWriter.showProbe()
                        #endif
                        if let logLine = result.logLine { AppLog.note("widgets", "tasks widget (\(reason)): \(logLine)") }
                    }
                }
            }
            return
        }
    }

    /// Async write that awaits completion on `ioQueue` without blocking `@MainActor`.
    @discardableResult
    private func writeAsyncResult(reason: String, now: Date = Date()) async -> Bool {
        let prep = prepareWrite(now: now)
        if case .none = prep { return false }
        let result: (changed: Bool, logLine: String?) = await withCheckedContinuation { continuation in
            Self.ioQueue.async { continuation.resume(returning: Self.performWrite(prep)) }
        }
        #if DEBUG
        TileWidgetWriter.showProbe()
        #endif
        if result.changed {
            Self.reload()
            if let logLine = result.logLine { AppLog.note("widgets", "tasks widget (\(reason)): \(logLine)") }
        }
        return result.changed
    }

    /// The background refresh and the pushed wake-up: the list read, then written. Whether the widget changed.
    func refresh() async -> Bool {
        guard enabled, account != nil, let store = currentStore() else { return false }
        watch(store)
        store.prepare()
        if !TasksHub.isOff(store.account) { await store.refresh() }
        return await writeAsyncResult(reason: "refresh")
    }

    // MARK: Writing

    /// Synchronous write kept for unit tests; production runtime paths use `writeAsync` / `writeAsyncResult`.
    @discardableResult
    func write(reason: String, now: Date = Date()) -> Bool {
        let prep = prepareWrite(now: now)
        if case .none = prep { return false }
        let result = Self.performWrite(prep)
        #if DEBUG
        TileWidgetWriter.showProbe()
        #endif
        if result.changed {
            Self.reload()
            if let logLine = result.logLine { AppLog.note("widgets", "tasks widget (\(reason)): \(logLine)") }
        }
        return result.changed
    }

    nonisolated private static func persistLive(scheme: String, account key: String, input: Input,
                                                botName: (String?) -> String, now: Date) -> (changed: Bool, viewCount: Int, openCount: Int) {
        let choices = Self.choices(tasks: input.tasks, sections: input.sections)
        var changed = false
        for choice in choices {
            guard let view = TodoView(key: choice.id) else { continue }
            let made = Self.view(view, name: choice.name, input: input, botName: botName, now: now)
            switch TasksWidgetStore.saveView(made) {
            case .written: changed = true
            case .refused: break
            case .unchanged: break
            }
        }
        if TasksWidgetStore.keepViews(Set(choices.map(\.id))) { changed = true }
        let before = TasksWidgetStore.loadIndex()
        var index = TasksWidgetIndex(state: .live, scheme: scheme, account: key, views: choices, writtenAt: before?.writtenAt ?? now)
        if before.map({ var b = $0; b.writtenAt = index.writtenAt; return b }) != index {
            index.writtenAt = now
            changed = TasksWidgetStore.saveIndex(index) || changed
        }
        return (changed, choices.count, input.tasks.filter { !$0.isDone }.count)
    }

    /// What every frame is made from.
    nonisolated struct Input: Sendable {
        var tasks: [TodoTask]
        var sections: [TodoUserSection]
        var bots: [String]
        var sort: String
        var paused: Set<String>
        var goals: [Goal] = []
        var ticking: Set<String> = []
    }

    /// The Show choices, as the page's pills offer them (Goals draws cards, not tasks: left out).
    nonisolated static func choices(tasks: [TodoTask], sections: [TodoUserSection]) -> [TasksWidgetIndex.Choice] {
        var out = [TasksWidgetIndex.Choice(id: TodoView.today.key, name: "Today"),
                   TasksWidgetIndex.Choice(id: TodoView.upcoming.key, name: "Upcoming"),
                   TasksWidgetIndex.Choice(id: TodoView.inbox.key, name: "Inbox")]
        for list in sections { out.append(.init(id: TodoView.list(list.id).key, name: list.name, color: list.color)) }
        if TodoViews.showsBots(tasks) { out.append(.init(id: TodoView.bots.key, name: "Bots")) }
        return out
    }

    /// One view's frames: now, then each moment its words change, alike frames merged.
    nonisolated static func view(_ view: TodoView, name: String, input: Input, botName: (String?) -> String,
                                 now: Date, calendar: Calendar = .current) -> TasksWidgetView {
        var frames: [TasksWidgetFrame] = []
        for moment in [now] + moments(input.tasks, now: now, calendar: calendar) {
            var made = frame(view, input: input, botName: botName, at: moment, calendar: calendar)
            if let last = frames.last {
                made.at = last.at
                if made == last { continue }
                made.at = moment
            }
            frames.append(made)
            if frames.count >= maxFrames { break }
        }
        return TasksWidgetView(key: view.key, name: name, frames: frames)
    }

    /// When the page's words change by the clock alone: each midnight, each due time, each bot's task growing stale
    /// (`TodoSections.isStale`), each start day; within `horizon`, in order. Each moment is a second after the change.
    nonisolated static func moments(_ tasks: [TodoTask], now: Date, calendar: Calendar = .current) -> [Date] {
        let end = now.addingTimeInterval(horizon)
        var out = Set<Date>()
        var day = calendar.startOfDay(for: now)
        while let next = calendar.date(byAdding: .day, value: 1, to: day), next <= end {
            out.insert(next.addingTimeInterval(1))
            day = next
        }
        for task in tasks where !task.isDone {
            if let due = TodoDates.due(task.due, calendar: calendar), due.hasTime { out.insert(due.date.addingTimeInterval(1)) }
            if let rawStart = task.starts, let startDay = TodoDates.day(String(rawStart.prefix(10)), calendar: calendar) {
                out.insert(startDay.addingTimeInterval(1))
            }
            if task.status == "open", task.due == nil,
               let touched = TodoDates.moment(task.updatedAt) ?? TodoDates.moment(task.createdAt) {
                out.insert(touched.addingTimeInterval(TodoSections.staleAfter + 1))
            }
        }
        return out.filter { $0 > now && $0 <= end }.sorted()
    }

    /// The page's first screen for `view` at `at`: its groups in order (Done left out: the page folds it), each
    /// group's heading and rows in the page's words.
    nonisolated static func frame(_ view: TodoView, input: Input, botName: (String?) -> String, at now: Date,
                                  calendar: Calendar = .current) -> TasksWidgetFrame {
        let groups = TodoViews.groups(input.tasks, view: view, sections: input.sections, bots: input.bots, now: now,
                                      sort: input.sort, paused: input.paused, calendar: calendar)
        var sections: [TasksWidgetSection] = []
        var kept = 0
        var waiting = 0
        for group in groups where group.kind != .done {
            let heading = TodoViews.heading(group.kind, now: now, calendar: calendar, sections: input.sections, botName: botName)
            var rows: [TasksWidgetRow] = []
            for task in group.tasks {
                if TodoViews.waitsOnYou(task) { waiting += 1 }
                guard kept < maxRows else { continue }
                kept += 1
                // Align with Tasks page ("Colour means act"): no list colour dots; show Goal mark when task serves an active/paused goal.
                let goalColor = GoalViews.markGoal(task, goals: input.goals)?.tint
                rows.append(row(task, kind: group.kind, now: now, calendar: calendar, botName: botName, dot: nil,
                                goalColor: goalColor, ticked: input.ticking.contains(task.id)))
            }
            let left = group.tasks.count - rows.count
            sections.append(TasksWidgetSection(title: heading?.title, detail: heading?.detail, red: group.kind == .overdue,
                                               rows: rows, more: left + group.more))
        }
        while let last = sections.last, last.rows.isEmpty, sections.count > 1 {
            sections[sections.count - 2].more += last.more
            sections.removeLast()
        }
        let listName = { () -> String? in if case .list(let id) = view { return input.sections.first { $0.id == id }?.name }; return nil }()
        let count = TodoViews.openCount(input.tasks, view: view, sections: input.sections, now: now, calendar: calendar)
        return TasksWidgetFrame(at: now, count: count, waiting: waiting, sections: sections,
                                empty: TodoViews.emptyText(view, listName: listName))
    }

    nonisolated static func row(_ task: TodoTask, kind: TodoGroupKind, now: Date, calendar: Calendar, botName: (String?) -> String,
                                dot: TodoListColor?, goalColor: TodoListColor? = nil, ticked: Bool) -> TasksWidgetRow {
        let words = TodoViews.row(task, in: kind, now: now, calendar: calendar, botName: botName)
        return TasksWidgetRow(id: task.id, title: task.title.isEmpty ? "Untitled Task" : task.title, when: words.when,
                              late: words.late, steps: words.steps, repeats: words.repeats, priority: words.priority,
                              note: words.note, tone: words.tone.rawValue, dot: dot?.rawValue,
                              goalColor: goalColor?.rawValue, done: ticked)
    }

    // MARK: The check circle

    /// A row's circle on a widget: ticked at once, saved through the page's store, put back when refused. Task text
    /// never goes into the log (docs/tasks.md rule 6).
    func checkOff(_ id: String, account accountKey: String) async -> Bool {
        guard let store = await tick(id, account: accountKey) else { return false }
        return await save(id, store: store)
    }

    /// The intent's way in: the row ticked and written, then back to WidgetKit at once, so the widget redraws it ticked
    /// while the save runs on in the app (under a background task, so a launch for the intent isn't suspended first).
    /// WidgetKit only reads the widget's timeline again once `perform` returns: a save awaited inside it would show
    /// nothing until the row was already gone or back (seen on the simulator, 2026-11-19).
    func checkOffFromWidget(_ id: String, account accountKey: String) async -> Bool {
        guard let store = await tick(id, account: accountKey) else { return false }
        let time = BackgroundTime.begin("widgets.check-off") {
            AppLog.note("widgets", "tasks widget: check-off out of background time")
        }
        Task { @MainActor in
            _ = await self.save(id, store: store)
            time.end()
        }
        return true
    }

    /// The checks, then the row drawn ticked where it stands. The store, or nil when there's nothing to tick.
    private func tick(_ id: String, account accountKey: String) async -> TasksStore? {
        let state = UIApplication.shared.applicationState == .background ? "background" : "foreground"
        AppLog.note("widgets", "tasks widget: check-off asked (\(state))")
        guard let store = await storeWhenReady() else {
            AppLog.note("widgets", "tasks widget: check-off with no Tasks store in this launch (nobody signed in yet)")
            return nil
        }
        guard accountKey == self.accountKey else {
            AppLog.note("widgets", "tasks widget: check-off for another account, refused")
            await writeAsyncResult(reason: "another account")
            return nil
        }
        store.prepare()
        if !store.hasList { await store.refresh() }
        guard let task = store.task(id), !task.isDone, ticking[id] == nil else {
            AppLog.note("widgets", "tasks widget: check-off for a task not open on the list")
            await writeAsyncResult(reason: "task gone")
            return nil
        }
        ticking[id] = task
        await writeAsyncResult(reason: "ticked")
        return store
    }

    /// The page's own save (`setDone`), the ticked row held a moment, then written again: gone, or put back.
    private func save(_ id: String, store: TasksStore) async -> Bool {
        let started = Date()
        let saved = await store.setDone(id, true)
        // The ticked row stays a moment, as the page's does before it moves.
        let shown = Date().timeIntervalSince(started)
        if shown < holdTicked { try? await Task.sleep(for: .seconds(holdTicked - shown)) }
        ticking[id] = nil
        await writeAsyncResult(reason: saved ? "ticked, saved" : "ticked, refused: put back")
        AppLog.note("widgets", "tasks widget: check-off \(saved ? "saved" : "refused, the row put back") in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        return saved
    }

    /// The Tasks store once the app has one (a launch for the intent makes its tabs first): up to 10 s.
    private func storeWhenReady() async -> TasksStore? {
        for _ in 0..<50 {
            if account != nil, let store = currentStore() { return store }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }
}
