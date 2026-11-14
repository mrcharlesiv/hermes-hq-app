// [tasks] Where Tasks lives in the app (docs/tasks.md): one store per signed-in gateway (the page, a task's alert, the
// chat's "Added to Tasks" card and the due reminders share it), the More row (Workspace › Tasks, a tab from Settings ›
// Tabs, a sidebar Tool on the Mac), opening a task from anywhere, and asking a bot about one in a chat.

import UIKit
import UserNotifications

@MainActor
enum TasksHub {
    private static var store: TasksStore?
    private static var installed = false

    /// This gateway's store (made on first use; a new gateway or sign-in makes a new one).
    static func store(_ context: MorePages.Context) -> TasksStore {
        if let store, store.account.id == context.account.id, store.api.client === context.client {
            store.readOnlyGateway = context.readOnly
            return store
        }
        let made = TasksStore(api: TasksAPI(client: context.client), account: context.account,
                              directory: PagesCache.directory(for: context.account))
        made.readOnlyGateway = context.readOnly
        made.onListChanged = { tasks in
            if made.settings.enabled { TaskReminders.sync(tasks) } else { TaskReminders.removeAll() }
        }
        made.onEnabledChanged = { on in noteEnabled(on, account: made.account) }
        store = made
        noteEnabled(made.settings.enabled, account: made.account)
        return made
    }

    static var current: TasksStore? { MorePages.context.map(store) }

    // MARK: On and off (Settings › Tasks)

    // Owner 2026-11-04: "We need a way for users to be able to turn off the tasks feature entirely." Kept per gateway
    // on this device too, so a launch with Tasks off never shows its row while the list is read.
    nonisolated static func offKey(_ accountID: String) -> String { "tasks.off.\(accountID)" }

    static func isOff(_ account: GatewayAccount) -> Bool { UserDefaults.standard.bool(forKey: offKey(account.id)) }

    /// The gateway said Tasks is on or off: More, the tabs and the Mac's Tools follow; off, this phone's due alerts go.
    static func noteEnabled(_ on: Bool, account: GatewayAccount) {
        guard isOff(account) == on else { return }
        UserDefaults.standard.set(!on, forKey: offKey(account.id))
        if !on { TaskReminders.removeAll() }
        AppLog.note("tasks", "tasks turned \(on ? "on" : "off")")
        PagesTabs.moreRowsChanged()
    }

    /// Settings › Tasks: saved on the gateway (every bot follows); a failed save puts the switch back.
    static func setEnabled(_ on: Bool) async {
        guard let store = current else { return }
        var next = store.settings
        next.enabled = on
        await store.saveSettings(next)
        if on { await store.refresh(force: true) }
    }

    /// The scope (All Bots or one bot) the Tasks page keeps, apart from Jobs and Artifacts'.
    nonisolated static func scopeKey(_ account: GatewayAccount) -> String { "pages.scope.tasks.\(account.id)" }

    static func install() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { foreground() }
        }
        center.addObserver(forName: NotificationHub.taskPushed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = Task { await current?.refresh(force: true) } }
        }
    }

    /// Back in front: the list is read (cheap: `?since=` answers `unchanged` when nothing moved). An add-on without
    /// Tasks is asked again only while the page shows.
    private static func foreground() {
        guard let store = current, !store.needsAddOn || TasksViewController.onScreen else { return }
        Task { await store.refresh() }
    }

    /// Sign-out: the list and this phone's due reminders go.
    static func signedOut() {
        store?.forget()
        store = nil
        TaskReminders.removeAll()
    }

    // MARK: Opening

    /// The Tasks page on show: its tab when it has one, else More's row. Returns the page.
    @discardableResult
    static func showPage() -> TasksViewController? {
        guard let root = MainTabController.current else { return nil }
        if let tab = root.placedTab(tagged: TabChoice.page("tasks").tag) {
            #if targetEnvironment(macCatalyst)
            if let split = root.split { split.switchPlace(to: tab) { root.show(tab) } } else { root.show(tab) }
            #else
            root.show(tab)
            #endif
            guard let stack = tab as? UINavigationController else { return nil }
            stack.popToRootViewController(animated: false)
            if let presented = stack.presentedViewController { presented.dismiss(animated: false) }
            return stack.viewControllers.first as? TasksViewController
        }
        guard let more = root.pages?.more, let stack = more.navigationController, let index = root.slotIndex(for: stack) else { return nil }
        if let presented = stack.presentedViewController { presented.dismiss(animated: false) }
        root.selectedIndex = index
        if let page = stack.topViewController as? TasksViewController { return page }
        stack.popToRootViewController(animated: false)
        more.loadViewIfNeeded()
        more.open(rowId: "tasks")
        return stack.topViewController as? TasksViewController
    }

    /// A task's alert or a chat card's row: the page, then that task's sheet (`atReply`: at its chat's newest end, for a
    /// reply's alert). False when there is no Tasks page to show.
    @discardableResult
    static func open(taskID: String?, atReply: Bool = false) -> Bool {
        guard let page = showPage() else { return false }
        guard let taskID else { return true }
        page.loadViewIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { page.openTask(taskID, atReply: atReply) }
        return true
    }

    // MARK: A task's chat named from outside

    private static var askedForList = false

    /// The task whose own chat `stored` is (the list on disk at a cold launch), so an alert or a link from that chat
    /// opens the task with its chat, not the chat bare (owner 2026-11-05: the alert "did not open back up in the task.
    /// It opened up in a new session"). Nil with Tasks off: the chat opens as any other.
    static func task(forChat stored: String) -> TodoTask? {
        guard let store = current, !isOff(store.account) else { return nil }
        store.prepare()
        return store.tasks.first { TaskChatLinks.link($0, account: store.account)?.sessionId == stored }
    }

    /// No list yet (none on disk): it is read once, and a waiting tap waits for it rather than guess.
    static func listPending() -> Bool {
        guard let store = current, !isOff(store.account) else { return false }
        store.prepare()
        if store.hasList { return false }
        if store.loading { return true }
        guard !askedForList else { return false }
        askedForList = true
        Task { await store.refresh() }
        return true
    }

    /// A chat card's Undo: the tasks it added are deleted. Returns whether they all went.
    static func undo(_ ids: [String], client: (any GatewayClient)?) async -> Bool {
        if let context = MorePages.context, client == nil || client === context.client {
            let store = store(context)
            var all = true
            for id in ids where !(await store.delete(id)) { all = false }
            return all
        }
        guard let client else { return false }
        let api = TasksAPI(client: client)
        var all = true
        for id in ids {
            do { try await api.delete(id) } catch { if PagesREST.status(error) != 404 { all = false } }
        }
        return all
    }

    // MARK: The task's own chat

    /// The task's own chat pushed over a task page standing alone (before the bots are known; with them the page is
    /// the chat itself: TaskPage). `question` goes out once the chat has opened: with the task's details the first
    /// time, the words alone after (`TaskPage.outgoing`).
    static func ask(_ question: String?, task: TodoTask, store: TasksStore, context: MorePages.Context,
                    on navigation: UINavigationController?) {
        guard let navigation, let model = TaskPage.chatModel(task, store: store, context: context) else { return }
        let chat = context.makeChat(model)   // the tap that asked played its own cue (the sheet's Ask, Ask to Help)
        chat.hidesBottomBarWhenPushed = true
        chat.navigationItem.largeTitleDisplayMode = .never
        ChatViewController.push(chat, on: navigation) {}
        let words = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        AppLog.note("tasks", "task chat pushed for \(AppLog.tag(model.profile)) (\(words.count) chars)")
        guard !words.isEmpty else { return }
        model.send(words)   // a task's chat not made yet waits for its open (LiveChatSession.opensOnFirstSend)
    }
}

/// Which chat is a task's own: the task's `chat` (add-on 0.9.37), else the one this device made for it (an older
/// add-on drops the field), else none yet.
@MainActor
enum TaskChatLinks {
    private static func key(_ account: GatewayAccount) -> String { "tasks.chats.\(account.id)" }

    static func link(_ task: TodoTask, account: GatewayAccount) -> TodoChat? {
        if let chat = task.chat { return chat }
        guard !task.chatKnown, let saved = UserDefaults.standard.dictionary(forKey: key(account))?[task.id] as? [String: String],
              let profile = saved["profile"], let session = saved["session_id"], !profile.isEmpty, !session.isEmpty else { return nil }
        return TodoChat(profile: profile, sessionId: session)
    }

    static func remember(_ chat: TodoChat, task: String, account: GatewayAccount) {
        var all = UserDefaults.standard.dictionary(forKey: key(account)) ?? [:]
        all[task] = ["profile": chat.profile, "session_id": chat.sessionId]
        UserDefaults.standard.set(all, forKey: key(account))
    }

    /// The bot with the task's context: its helper, else the bot whose chat it came from or that added it, else Hermes.
    static func bot(for task: TodoTask, bots: [Bot]) -> Bot? {
        let picks = [task.helper, task.source?.profile, task.createdBy, "default"].compactMap { $0 }
        for pick in picks { if let bot = bots.first(where: { $0.id == pick }) { return bot } }
        return bots.first
    }

    /// The session's own title: unique per task (a titled create with a taken title reopens that chat, so two devices
    /// making it at once land in one), within Hermes's 100 characters.
    nonisolated static func sessionTitle(_ task: TodoTask) -> String {
        let name = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = name.count > 70 ? String(name.prefix(69)) + "…" : name
        return "Task: \(short) · \(task.id.prefix(6))"
    }
}

// MARK: - The More row

extension MorePages {
    static func installTasks() {
        TasksHub.install()
        factories["tasks"] = { context in
            let store = TasksHub.store(context)
            return TasksViewController(store: store, context: context)
        }
    }
}

// MARK: - Due reminders on this phone

/// Your task, or one you share with a bot, rings on this device when it's due (a day alone at 9:00; pushes from the
/// computer cover a bot's news). Kept in step with the list each time it changes: one pending alert per such task.
@MainActor
enum TaskReminders {
    static let prefix = "hq.task."
    private static var lastSignature = ""

    static func sync(_ tasks: [TodoTask], now: Date = Date()) {
        let wanted = tasks.compactMap { task -> (TodoTask, Date)? in
            guard task.whoKind != .bot, !task.isDone, !TodoIDs.isLocal(task.id),
                  let when = TodoReminder.time(task), when > now else { return nil }
            return (task, when)
        }
        let signature = wanted.map { "\($0.0.id)|\($0.0.title)|\(TodoReminder.body($0.0))|\($0.1.timeIntervalSince1970)" }
            .sorted().joined(separator: "\n")
        guard signature != lastSignature else { return }
        lastSignature = signature
        let center = UNUserNotificationCenter.current()
        let items = wanted.map { (id: $0.0.id, title: $0.0.title, body: TodoReminder.body($0.0), profile: $0.0.helper,
                                  parts: TodoReminder.triggerParts($0.0, at: $0.1)) }
        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
            let keep = Set(items.map { prefix + $0.id })
            let stale = pending.filter { !keep.contains($0) }
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
            for item in items {
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.body
                content.sound = .default
                content.threadIdentifier = "hq.tasks"
                var info: [String: Any] = ["kind": "task", "task_id": item.id]
                if let profile = item.profile { info["profile"] = profile }
                content.userInfo = info
                let request = UNNotificationRequest(identifier: prefix + item.id, content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: item.parts, repeats: false))
                try? await center.add(request)
            }
            AppLog.note("tasks", "due reminders: \(items.count) set, \(stale.count) taken away")
        }
    }

    static func removeAll() {
        lastSignature = ""
        let center = UNUserNotificationCenter.current()
        Task {
            let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}
