// [tasks] Where Tasks lives in the app (docs/tasks.md): one store per signed-in gateway (the page, a task's alert, the
// chat's "Added to Tasks" card and the due reminders share it), the More row (Workspace › Tasks, a tab from Settings ›
// Tabs, a sidebar Tool on the Mac), opening a task from anywhere, and asking a bot about one in a chat.

import UIKit
import UserNotifications

@MainActor
enum TasksHub {
    private static var store: TasksStore?
    private static var ideasStore: (store: ObjectIdentifier, ideas: TaskIdeasStore)?
    private static var installed = false

    /// This gateway's store (made on first use; a new gateway or sign-in makes a new one).
    static func store(_ context: MorePages.Context) -> TasksStore {
        if let store, store.account.id == context.account.id, store.api.client === context.client {
            store.readOnlyGateway = context.readOnly
            return store
        }
        ideasStore?.ideas.forget()
        ideasStore = nil
        TodoTaskStates.forget()   // [chat-mark-done] the chat's close cards read this gateway's list, not the last one's
        let made = TasksStore(api: TasksAPI(client: context.client), account: context.account,
                              directory: PagesCache.directory(for: context.account))
        made.readOnlyGateway = context.readOnly
        made.onListChanged = { tasks in
            let accountKey = TileWidgetIndex.key(made.account.id)
            if made.settings.enabled { TaskReminders.sync(tasks, account: accountKey) }
            else { TaskReminders.removeAll(account: accountKey) }
        }
        made.onEnabledChanged = { on in noteEnabled(on, account: made.account) }
        made.onPlanTaken = { [weak made] offer in if let made { GoalPlanTaken.tell(offer, store: made) } }
        store = made
        noteEnabled(made.settings.enabled, account: made.account)
        return made
    }

    /// Shared Suggested Tasks (`TaskIdeasStore`) for `store` so Overview and pushed Suggested views stay instantly in sync.
    static func ideas(for store: TasksStore) -> TaskIdeasStore {
        let id = ObjectIdentifier(store)
        if let cached = ideasStore, cached.store == id { return cached.ideas }
        ideasStore?.ideas.forget()
        let made = TaskIdeasStore(api: store.api, directory: store.directory)
        ideasStore = (id, made)
        return made
    }

    static var current: TasksStore? { MorePages.context.map(store) }

    /// Live `tasks.changed` socket event from the gateway.
    static func tasksChanged(for account: GatewayAccount?) {
        guard let account, let store, store.account.id == account.id else { return }
        store.tasksChanged()
    }

    /// Gateway reconnected (`gateway.ready`): replay any queued offline mutations and refresh.
    static func gatewayReady(for account: GatewayAccount?) {
        guard let account, let store, store.account.id == account.id else { return }
        store.gatewayReady()
    }

    // MARK: On and off (Settings › Tasks)

    // Owner 2026-11-04: "We need a way for users to be able to turn off the tasks feature entirely." Kept per gateway
    // on this device too, so a launch with Tasks off never shows its row while the list is read.
    nonisolated static func offKey(_ accountID: String) -> String { "tasks.off.\(accountID)" }

    static func isOff(_ account: GatewayAccount) -> Bool { UserDefaults.standard.bool(forKey: offKey(account.id)) }

    /// The gateway said Tasks is on or off: More, the tabs and the Mac's Tools follow; off, this phone's due alerts go.
    static func noteEnabled(_ on: Bool, account: GatewayAccount) {
        guard isOff(account) == on else { return }
        UserDefaults.standard.set(!on, forKey: offKey(account.id))
        if !on { TaskReminders.removeAll(account: TileWidgetIndex.key(account.id)) }
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
        // [goals step 3] A chat names a goal's card the app hasn't read: the list is read again (once per card).
        center.addObserver(forName: TodoOfferStates.wanted, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = Task { await current?.refresh(force: true) } }
        }
        // [chat-mark-done] A chat's close card names a task the list hasn't shown yet (or a newer offer on it).
        center.addObserver(forName: TodoTaskStates.wanted, object: nil, queue: .main) { _ in
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
        ideasStore?.ideas.forget()
        ideasStore = nil
        store?.forget()
        store = nil
        tapRead = nil
        TodoOfferStates.forget()
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
        // [goals step 4] Two panes (an iPad): Tasks shows in the right pane, beside More, not on More's own stack. A
        // check-in's push (and a task's alert) found no page there and did nothing.
        if let page = more.openedPageOnScreen as? TasksViewController {
            if let stack = page.navigationController, stack.topViewController !== page { stack.popToViewController(page, animated: false) }
            if let presented = page.presentedViewController { presented.dismiss(animated: false) }
            return page
        }
        stack.popToRootViewController(animated: false)
        more.loadViewIfNeeded()
        let opened = more.open(rowId: "tasks")
        return stack.topViewController as? TasksViewController ?? opened as? TasksViewController
    }

    /// Runs `work` once `page`'s navigation / modal transition finishes (no hardcoded 0.45 s sleep).
    private static func afterTransition(on page: TasksViewController, token: Int, _ work: @escaping @MainActor () -> Void) {
        let run: @MainActor () -> Void = {
            guard token == openToken else { return }
            work()
        }
        if let coordinator = page.transitionCoordinator ?? page.navigationController?.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in
                DispatchQueue.main.async { run() }
            }
        } else {
            DispatchQueue.main.async { run() }
        }
    }

    /// The New Task sheet over the Tasks page: a widget's New Task, and [quick-actions] an Add Task tile (its bot chosen).
    static func newTask(bot: String? = nil) {
        guard let page = showPage() else { return }
        page.loadViewIfNeeded()
        openToken += 1
        let token = openToken
        afterTransition(on: page, token: token) { page.newTask(bot: bot) }
    }

    @discardableResult
    static func open(taskID: String?, atReply: Bool = false) -> Bool {
        guard let page = showPage() else { return false }
        guard let taskID else { return true }
        page.loadViewIfNeeded()
        // [notify] Only the newest way in opens (audit 2026-11-19: two alerts tapped quickly, or a chat opened in the
        // meantime, and the older task came up over it).
        openToken += 1
        let token = openToken
        afterTransition(on: page, token: token) { page.openTask(taskID, atReply: atReply) }
        return true
    }

    private static var openToken = 0

    /// Another place was opened (a chat's alert for a bot's or a Sessions chat): a task still to open after the page's
    /// turn doesn't come up over it.
    static func cancelPendingOpen() { openToken += 1 }

    /// [goals step 3/4] A goal from outside (a check-in's push, a chat card's Change): the Tasks page, then the goal's
    /// page (`chat`: at its chat, the goal as its bar). False when there is no Tasks page to show. [goals step 6]
    /// `plan`: a goal's new first lead is asked for a plan in its chat, your bubble these words (`TasksViewController.openGoal`).
    @discardableResult
    static func openGoal(_ id: String, chat: Bool = false, plan: String? = nil) -> Bool {
        guard let page = showPage() else { return false }
        page.loadViewIfNeeded()
        openToken += 1
        let token = openToken
        afterTransition(on: page, token: token) { page.openGoal(id, chat: chat, plan: plan) }
        return true
    }

    // MARK: A task's chat named from outside

    /// [notify] The read a tap asked for (audit 2026-11-19): per store and per chat, so a failed read, another
    /// gateway's store or a later tap asks again (one flag for the app's life stopped every read after the first).
    private static var tapRead: (store: ObjectIdentifier, stored: String, at: Date, done: Bool)?

    /// The task whose own chat `stored` is (the list on disk at a cold launch), so an alert or a link from that chat
    /// opens the task with its chat, not the chat bare (owner 2026-11-05: the alert "did not open back up in the task.
    /// It opened up in a new session"). Nil with Tasks off: the chat opens as any other.
    static func task(forChat stored: String) -> TodoTask? {
        guard let store = current, !isOff(store.account) else { return nil }
        store.prepare()
        return store.tasks.first { TaskChatLinks.link($0, account: store.account)?.sessionId == stored }
    }

    /// A chat no task in hand names (no list yet, or one read before the task's chat was made, on another device or
    /// while this phone was away): the list is read once for this tap, and the tap waits for it rather than guess the
    /// chat is a bot's or open it bare (audit 2026-11-19: a task's reply opened in its bot's own chat).
    static func listPending(for stored: String) -> Bool {
        guard let store = current, !isOff(store.account), !store.needsAddOn else { return false }
        store.prepare()
        let id = ObjectIdentifier(store)
        if let read = tapRead, read.store == id, read.stored == stored, Date().timeIntervalSince(read.at) < 30 {
            return !read.done
        }
        tapRead = (id, stored, Date(), false)
        Task {
            await store.refresh(force: true)
            if let read = tapRead, read.store == id, read.stored == stored { tapRead?.done = true }
        }
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

    /// [task-lists] A chat card's answer to a bot's offer. Through the page's store when the chat is on its gateway (the
    /// Tasks page shows the same at once), else straight to that gateway.
    static func answerOffer(_ id: String, _ action: TodoOfferAction, list: Bool, plan: Bool = true, inGoal: Bool = true,
                            client: (any GatewayClient)?) async -> Bool {
        if let context = MorePages.context, client == nil || client === context.client {
            let store = store(context)
            if !store.offers.contains(where: { $0.id == id }) { await store.refresh(force: true) }
            if store.offers.contains(where: { $0.id == id }) { return await store.answerOffer(id, action, list: list, plan: plan, inGoal: inGoal) }
        }
        guard let client = client ?? MorePages.context?.client else { return false }
        let isGoal = TodoOfferStates.live(id).offer?.isGoal == true
        do {
            let answer = try await TasksAPI(client: client).answerOffer(id, action: action, list: list, goal: isGoal ? (plan, inGoal) : nil)
            if TodoOfferStates.note([answer.offer], whole: false) {
                NotificationCenter.default.post(name: TodoOfferStates.changed, object: nil)
            }
            await current?.refresh(force: true)
            return true
        } catch {
            AppLog.note("tasks", "offer not answered: \(PagesREST.reason(error))")
            return false
        }
    }

    /// [chat-mark-done] A chat card's Mark Done, Keep Open or Undo on a bot's offer to close a task: the same store calls
    /// the task's page makes (`TodoSheet.markDone`, `TasksStore.keepOpen`, `TodoSheet.reopen`), so the page and the list
    /// show it at once. A refused save gives the store's own words for why.
    static func closeTask(_ id: String, _ action: TodoCloseCards.Action, client: (any GatewayClient)?) async -> (ok: Bool, reason: String?) {
        guard let context = MorePages.context, client == nil || client === context.client else {
            return (false, "Open the task on the Tasks page of the computer it’s on.")
        }
        let store = store(context)
        if store.task(id) == nil { await store.refresh(force: true) }
        guard store.task(id) != nil else { return (false, "This task is no longer on your list.") }
        store.lastNotice = nil
        let ok: Bool
        switch action {
        case .markDone: ok = await store.setDone(id, true)
        case .keepOpen: ok = await store.keepOpen(id)
        case .reopen: ok = await store.setDone(id, false)
        }
        if ok, action == .reopen { TodoTaskStates.noteReopened(id) }
        return (ok, ok ? nil : store.lastNotice ?? "Couldn’t save the change.")
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
    private static func key(_ account: GatewayAccount) -> String {
        #if DEBUG
        _ = debugReset
        #endif
        return "tasks.chats.\(account.id)"
    }

    #if DEBUG
    /// `-HQDebugResetTaskChats YES`: this device's task-chat links go at launch (a UI test's task starts with none).
    private static let debugReset: Void = {
        guard UserDefaults.standard.bool(forKey: "HQDebugResetTaskChats") else { return }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("tasks.chats.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }()
    #endif

    /// [notify] A chat this device made whose link the gateway hasn't taken yet (audit 2026-11-19: the save failed, and
    /// the task's `chat: null` then hid the chat it had: the task opened with no conversation, its alert found no task)
    /// counts until a save lands (`unsaved`, saved again on each open: `TaskPage.chatModel`).
    static func link(_ task: TodoTask, account: GatewayAccount) -> TodoChat? {
        if let chat = task.chat { return chat }
        guard let saved = UserDefaults.standard.dictionary(forKey: key(account))?[task.id] as? [String: String],
              !task.chatKnown || saved["unsaved"] == "1",
              let profile = saved["profile"], let session = saved["session_id"], !profile.isEmpty, !session.isEmpty else { return nil }
        return TodoChat(profile: profile, sessionId: session)
    }

    /// Whether the task's link is this device's alone, its save to the gateway still owed.
    static func unsaved(_ task: TodoTask, account: GatewayAccount) -> Bool {
        task.chat == nil && (UserDefaults.standard.dictionary(forKey: key(account))?[task.id] as? [String: String])?["unsaved"] == "1"
    }

    static func remember(_ chat: TodoChat, task: String, account: GatewayAccount, unsaved: Bool = false) {
        var all = UserDefaults.standard.dictionary(forKey: key(account)) ?? [:]
        var entry = ["profile": chat.profile, "session_id": chat.sessionId]
        if unsaved { entry["unsaved"] = "1" }
        all[task] = entry
        UserDefaults.standard.set(all, forKey: key(account))
    }

    /// The gateway took the link: it is the task's own now (a later `chat: null` from the gateway is believed again).
    static func saved(task: String, account: GatewayAccount) {
        var all = UserDefaults.standard.dictionary(forKey: key(account)) ?? [:]
        guard var entry = all[task] as? [String: String], entry["unsaved"] != nil else { return }
        entry["unsaved"] = nil
        all[task] = entry
        UserDefaults.standard.set(all, forKey: key(account))
    }

    /// Clears the local chat link when a task is reassigned to a different bot so the new bot starts its own chat.
    static func clear(task: String, account: GatewayAccount) {
        var all = UserDefaults.standard.dictionary(forKey: key(account)) ?? [:]
        guard all.removeValue(forKey: task) != nil else { return }
        UserDefaults.standard.set(all, forKey: key(account))
    }

    /// The link saved to the task on the gateway; on failure it stays this device's (`unsaved`) and is tried again.
    static func save(_ chat: TodoChat, task: String, store: TasksStore, account: GatewayAccount) {
        Task { @MainActor in
            if await store.patch(task, ["chat": chat.json]) {
                saved(task: task, account: account)
            } else {
                AppLog.note("tasks", "task chat link not saved yet")
            }
        }
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
/// computer cover a bot's news). Kept in step with the list each time it changes: sorted by soonest fire date and
/// capped below iOS's 64 pending local notification limit, serialized so remove/add never race, and scoped per gateway.
@MainActor
enum TaskReminders {
    nonisolated static let prefix = "hq.task."
    /// Below iOS's hard 64 pending local notification ceiling, leaving headroom for non-task local alerts.
    nonisolated static let maxPending = 60

    private static var lastSignatures: [String: String] = [:]
    private static var syncTail: Task<Void, Never>?

    nonisolated static func accountPrefix(_ account: String?) -> String {
        guard let account, !account.isEmpty else { return prefix }
        return "\(prefix)\(account)."
    }

    /// Selects the soonest `limit` future reminders in deterministic fire order (pure: tested directly).
    nonisolated static func select(_ tasks: [TodoTask], now: Date = Date(), limit: Int = maxPending,
                                   calendar: Calendar = .current) -> [(task: TodoTask, when: Date)] {
        tasks.compactMap { task -> (TodoTask, Date)? in
            guard task.whoKind != .bot, !task.isDone, !TodoIDs.isLocal(task.id),
                  let when = TodoReminder.time(task, calendar: calendar), when > now else { return nil }
            return (task, when)
        }
        .sorted { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.id < b.0.id }
        .prefix(max(0, limit))
        .map { $0 }
    }

    private static func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = syncTail
        syncTail = Task {
            await previous?.value
            await work()
        }
    }

    static func sync(_ tasks: [TodoTask], account: String? = nil, now: Date = Date()) {
        let scope = accountPrefix(account)
        let wanted = select(tasks, now: now, limit: maxPending)
        let signature = wanted.map { "\($0.task.id)|\($0.task.title)|\(TodoReminder.body($0.task))|\($0.when.timeIntervalSince1970)" }
            .joined(separator: "\n")
        guard signature != lastSignatures[scope] else { return }
        lastSignatures[scope] = signature
        let items = wanted.map { (id: $0.task.id, title: $0.task.title, body: TodoReminder.body($0.task), profile: $0.task.helper,
                                  parts: TodoReminder.triggerParts($0.task, at: $0.when)) }
        enqueue {
            let center = UNUserNotificationCenter.current()
            let allPending = await center.pendingNotificationRequests().map(\.identifier)
            // Only manage this gateway's scoped reminders (plus any legacy unscoped `hq.task.<id>` ones).
            let pending = allPending.filter { id in
                if id.hasPrefix(scope) { return true }
                // Legacy identifier has no account segment (`hq.task.<taskId>` without a third dot).
                if account != nil, id.hasPrefix(prefix) {
                    let rest = id.dropFirst(prefix.count)
                    return !rest.contains(".")
                }
                return false
            }
            let keep = Set(items.map { scope + $0.id })
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
                let request = UNNotificationRequest(identifier: scope + item.id, content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: item.parts, repeats: false))
                try? await center.add(request)
            }
            AppLog.note("tasks", "due reminders: \(items.count) set, \(stale.count) taken away")
        }
    }

    static func removeAll(account: String? = nil) {
        let scope = accountPrefix(account)
        if account == nil { lastSignatures.removeAll() } else { lastSignatures[scope] = nil }
        enqueue {
            let center = UNUserNotificationCenter.current()
            let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(scope) }
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        }
    }
}
