// [quick-actions] Favorites' ways in and its tiles' ways out (docs/spec/3x-intents.md DECISION I22,
// docs/spec/3x-morepages.md §25). Routes actions, native live cards (Tasks, Goals, Needs You, Bots, Group Chats,
// Specific Sessions, Jobs, Kanban, Status, Usage), deeper targets (Prompts, Slash Commands, Quick Ask, Dashboard Pages,
// Files Folders, Web Links), and multi-step Routines.

import UIKit

@MainActor enum QuickActionsRouter {
    /// The page's sheet while it is up.
    private static weak var sheet: UINavigationController?

    /// The page as a sheet over the app, once its tabs are up (a shortcut may have launched it).
    static func present(from: String) async {
        AppLog.note("quick-actions", "open from \(from)")
        IntentsEvents.note("quick-actions open " + from)
        guard let root = await NewChatRouter.tabs() else {
            AppLog.note("quick-actions", "open: no tabs (signed out?)")
            return
        }
        MainTabController.launchRestorePending = false
        root.launchChatWatch = nil
        if let sheet, sheet.presentingViewController != nil, !sheet.isBeingDismissed {
            sheet.presentedViewController?.dismiss(animated: false)
            sheet.popToRootViewController(animated: false)
            return
        }
        guard await root.clearForRoute() else { return }
        let page = QuickActionsViewController(inSheet: true)
        let navigation = ChatSheet.wrap(page, title: IntentsText.quickActions, detents: [.medium(), .large()])
        navigation.sheetPresentationController?.selectedDetentIdentifier = .large
        navigation.view.accessibilityIdentifier = "quick-actions.sheet"
        sheet = navigation
        root.present(navigation, animated: true)
    }

    /// Whether the page's sheet is up (the debug state).
    static var isShown: Bool { sheet?.presentingViewController != nil }

    // MARK: What a tile finds around it

    /// The CURRENT gateway's bots, jobs, pages, pins, rooms, sessions, goals, task lists, dashboard pages, and boards.
    static func world(_ root: MainTabController? = MainTabController.current) -> QuickTileWorld {
        var world = QuickTileWorld()
        if let root, root.services.botsLoaded {
            world.bots = Dictionary(root.services.bots.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
        let jobs = JobShortcutCatalog.jobs()
        if !jobs.isEmpty { world.jobs = Set(jobs.map(\.key)) }
        if let pages = root?.pages {
            var byID: [String: String] = [:]
            for row in pages.quickActionChoices().flatMap({ $0.rows() }) where byID[row.id] == nil { byID[row.id] = row.title }
            world.pages = byID
        }
        if let store = FavoriteTiles.store(root) {
            let pins = ArtifactPins.of(accountId: store.account.id)
            world.pins = Dictionary(store.hidden.visible(pins.pins).map { ($0.id, pins.name($0)) }, uniquingKeysWith: { first, _ in first })
            world.dashboardPages = Dictionary(pins.pages.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
        if let groupStore = (root?.services as? GroupServices)?.groupStore {
            let rows = groupStore.rows()
            if !rows.isEmpty {
                world.rooms = Dictionary(rows.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            }
        }
        if let sessions = root?.services.sessions, !sessions.isEmpty {
            world.sessions = Dictionary(sessions.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        }
        if let taskStore = TasksHub.current {
            world.tasksEnabled = !TasksHub.isOff(taskStore.account)
            if taskStore.hasList {
                world.goals = Dictionary(taskStore.goals.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
                world.taskLists = Dictionary(taskStore.sections.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            }
        }
        if let boards = root?.pages?.kanbanStore?.boards?.boards, !boards.isEmpty {
            world.boards = Dictionary(boards.map { ($0.slug, KanbanModel.boardTitle(slug: $0.slug, name: $0.name)) }, uniquingKeysWith: { first, _ in first })
        }
        if let accountId = MorePages.context?.account.id, !accountId.isEmpty {
            world.currentGatewayId = accountId
        }
        return world
    }

    /// The bot's name on the current roster (nil: not on it, or not known yet).
    static func botName(_ profile: String?, root: MainTabController? = MainTabController.current) -> String? {
        guard let profile, let root else { return nil }
        return root.services.bots.first { $0.id == profile }?.name
    }

    // MARK: Running a tile

    enum Said: Equatable {
        case done(String)
        case failed(String)
    }

    /// Runs `tile` from `page`. A foreground tile closes the page's sheet first and goes; a background one keeps the
    /// page, updates `live` with inline spinner/result, and answers through `say`.
    static func run(_ tile: QuickTile, from page: QuickActionsViewController, live: FavoritesLiveModel? = nil,
                    say: @escaping (Said) -> Void) {
        let root = MainTabController.current
        let route = QuickTileRoute.make(tile, world: world(root))
        AppLog.note("quick-actions", "tap \(tile.kind)")
        IntentsEvents.note("quick-actions tap " + tile.kind)
        switch route {
        case .unavailable(let words):
            say(.failed(words))
        case .toggleSection(let id):
            page.toggleSection(id)
        case .quickAsk(let profile, let defaultOpen):
            let name = botName(profile, root: root) ?? tile.botName ?? profile
            page.presentQuickAsk(bot: profile, botName: name, defaultOpen: defaultOpen)
        case .runJob(let key, let name):
            guard let record = JobShortcutCatalog.jobs().first(where: { $0.key == key }) else {
                say(.failed("“\(name)” isn’t on this gateway."))
                return
            }
            live?.setRunning(tile.id, true)
            let time = BackgroundTime.begin("hq.quick-actions.run-job")
            Task {
                let ran = await Result.of { try await RunJobIntent.run(record, wait: false) }
                time.end()
                switch ran {
                case .success:
                    AppLog.note("quick-actions", "run job: started")
                    live?.recordFeedback(tile.id, ok: true, text: "Running")
                    say(.done("Running \(name)"))
                case .failure(let error):
                    AppLog.note("quick-actions", "run job: refused")
                    let reason = words(error)
                    live?.recordFeedback(tile.id, ok: false, text: "Failed")
                    say(.failed(reason))
                }
            }
        case .sendInBackground(let profile, let message):
            let name = botName(profile, root: root) ?? tile.botName ?? profile
            live?.setRunning(tile.id, true)
            let time = BackgroundTime.begin("hq.quick-actions.send")
            Task {
                let sent = await Result.of { try await AskBotIntent.send(profile: profile, name: name, message: message, wait: false) }
                time.end()
                switch sent {
                case .success(let answer):
                    AppLog.note("quick-actions", "send: sent")
                    live?.recordFeedback(tile.id, ok: true, text: "Sent")
                    say(.done("Sent to \(answer.target.name)"))
                case .failure(let error):
                    AppLog.note("quick-actions", "send: failed")
                    let reason = words(error)
                    live?.recordFeedback(tile.id, ok: false, text: "Failed")
                    say(.failed(reason))
                }
            }
        case .routine(let steps, let name):
            Task { await runRoutine(steps, tileId: tile.id, name: name, from: page, root: root, live: live, say: say) }
        default:
            Task { await go(route, tile: tile, from: page, root: root, say: say) }
        }
    }

    /// Runs a single job directly from a Live Job Card's inline Run Now button.
    static func runJobDirectly(key: String, name: String, tileId: String, live: FavoritesLiveModel?, say: @escaping (Said) -> Void) {
        guard let record = JobShortcutCatalog.jobs().first(where: { $0.key == key }) else {
            say(.failed("“\(name)” isn’t on this gateway."))
            return
        }
        live?.setRunning(tileId, true)
        let time = BackgroundTime.begin("hq.quick-actions.run-job")
        Task {
            let ran = await Result.of { try await RunJobIntent.run(record, wait: false) }
            time.end()
            switch ran {
            case .success:
                live?.recordFeedback(tileId, ok: true, text: "Running")
                say(.done("Running \(name)"))
            case .failure(let error):
                live?.recordFeedback(tileId, ok: false, text: "Failed")
                say(.failed(words(error)))
            }
        }
    }

    /// Runs a Needs You attention item directly when tapped inside the Needs You card.
    static func runAttention(_ item: FavoritesLiveModel.AttentionItem, from page: QuickActionsViewController, say: @escaping (Said) -> Void) {
        Task {
            if page.inSheet { await close(page) }
            guard let root = MainTabController.current else { return }
            switch item.kind {
            case .botInput(let profile), .botAttention(let profile), .botWorking(let profile):
                if let record = voiceRecord(profile) {
                    _ = OpenBotChatIntent.open(record)
                } else {
                    await NewChatRouter.open(NewChatLink(bot: profile, project: nil, message: nil, send: false))
                }
            case .taskWaiting(let id):
                _ = TasksHub.open(taskID: id, atReply: true)
            case .jobAttention(let key):
                openJob(key: key, root: root, from: page)
            }
        }
    }

    /// Runs all steps of a multi-action Routine tile. Background steps run sequentially first; if any foreground
    /// step is included, the last foreground step opens after the background work finishes.
    private static func runRoutine(_ steps: [QuickRoutineStep], tileId: String, name: String,
                                   from page: QuickActionsViewController, root: MainTabController?,
                                   live: FavoritesLiveModel?, say: @escaping (Said) -> Void) async {
        live?.setRunning(tileId, true)
        var succeeded = 0
        var lastError: String?
        var finalForeground: QuickRoutineStep?

        for step in steps {
            switch step.knownKind {
            case .runJob:
                if let key = step.job, let record = JobShortcutCatalog.jobs().first(where: { $0.key == key }) {
                    let ran = await Result.of { try await RunJobIntent.run(record, wait: false) }
                    if case .success = ran { succeeded += 1 }
                    else if case .failure(let err) = ran { lastError = words(err) }
                } else {
                    lastError = "“\(step.jobName ?? "Job")” isn’t on this gateway."
                }
            case .send:
                if let profile = step.bot, !profile.isEmpty,
                   let msg = step.message?.trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty {
                    let bName = botName(profile, root: root) ?? step.botName ?? profile
                    let sent = await Result.of { try await AskBotIntent.send(profile: profile, name: bName, message: msg, wait: false) }
                    if case .success = sent { succeeded += 1 }
                    else if case .failure(let err) = sent { lastError = words(err) }
                } else {
                    lastError = "A routine step is missing its bot or message."
                }
            case .slashCommand, .openPage, .openChat, .openTile:
                finalForeground = step
            case nil:
                break
            }
        }

        if let fg = finalForeground {
            live?.recordFeedback(tileId, ok: lastError == nil, text: lastError == nil ? "Done" : "Partial")
            if let lastError { say(.failed(lastError)) }
            if page.inSheet { await close(page) }
            guard let root = root ?? MainTabController.current else { return }
            switch fg.knownKind {
            case .slashCommand:
                if let profile = fg.bot, let cmd = fg.command {
                    await NewChatRouter.send(cmd, inBotChatOf: profile)
                }
            case .openPage:
                if let pageId = fg.page { _ = openPage(pageId, root: root) }
            case .openChat:
                if let profile = fg.bot, let record = voiceRecord(profile) { _ = OpenBotChatIntent.open(record) }
            case .openTile:
                if let pinId = fg.pin, let tiles = dashboard(root) {
                    tiles.loadViewIfNeeded()
                    try? await Task.sleep(for: .milliseconds(350))
                    _ = tiles.openTile(pinId: pinId)
                }
            default:
                break
            }
            return
        }

        if let lastError, succeeded == 0 {
            live?.recordFeedback(tileId, ok: false, text: "Failed")
            say(.failed(lastError))
        } else if let lastError {
            live?.recordFeedback(tileId, ok: false, text: "\(succeeded)/\(steps.count)")
            say(.failed("\(name): \(succeeded) of \(steps.count) ran (\(lastError))"))
        } else {
            live?.recordFeedback(tileId, ok: true, text: "Done")
            say(.done("\(name) (\(succeeded) \(succeeded == 1 ? "step" : "steps"))"))
        }
    }

    /// A foreground route: the page's sheet goes first (the route's own clearing then has nothing to ask about).
    private static func go(_ route: QuickTileRoute, tile: QuickTile, from page: QuickActionsViewController,
                           root: MainTabController?, say: @escaping (Said) -> Void) async {
        // A page tile pushed on the page's own stack (the page is a tab or a More page): it opens there.
        if case .page(let id) = route, !page.inSheet {
            guard let row = row(id, root: root), let next = row.make() else { return say(.failed(missingPage(tile))) }
            page.navigationController?.pushViewController(next, animated: true)
            return
        }
        // [favorites-live-tiles] A Dashboard tile, the page a tab or a More page: push Dashboard on Favorites' stack.
        if case .dashboardTile(let id) = route, !page.inSheet, let navigation = page.navigationController {
            guard let tiles = root?.pages?.makePinned() as? ArtifactsViewController else { return say(.failed(missingTile(tile))) }
            navigation.pushViewController(tiles, animated: true)
            await settled(navigation)
            tiles.loadViewIfNeeded()
            if !tiles.openTile(pinId: id) { say(.failed(missingTile(tile))) }
            return
        }
        if case .link(let url) = route {
            await UIApplication.shared.open(url)
            return
        }
        if page.inSheet { await close(page) }
        guard let root = root ?? MainTabController.current else { return }
        switch route {
        case .newChat(let link):
            await NewChatRouter.open(link)
        case .talk(let profile):
            await NewChatRouter.talk(profile)
        case .memo(let profile):
            guard let record = voiceRecord(profile) else { return notice(missingBot(tile), root: root) }
            RecordVoiceNoteIntent.queue(record)
        case .openChat(let profile):
            guard let record = voiceRecord(profile), OpenBotChatIntent.open(record) else { return notice(missingBot(tile), root: root) }
        case .sendInChat(let profile, let words):
            await NewChatRouter.send(words, inBotChatOf: profile)
        case .slashCommand(let profile, let command):
            await NewChatRouter.send(command, inBotChatOf: profile)
        case .newTask(let bot):
            TasksHub.newTask(bot: bot)
        case .page(let id):
            if !openPage(id, root: root) { notice(missingPage(tile), root: root) }
        case .search:
            await IntentsRuntime.shared.route("search", id: "", epoch: nil)
        case .dashboardTile(let id):
            guard let tiles = dashboard(root) else { return notice(missingTile(tile), root: root) }
            tiles.loadViewIfNeeded()
            try? await Task.sleep(for: .milliseconds(350))
            if !tiles.openTile(pinId: id) { notice(missingTile(tile), root: root) }
        case .tasksView(let key):
            guard let tasksPage = TasksHub.showPage() else { return notice("Tasks isn’t available on this gateway.", root: root) }
            tasksPage.loadViewIfNeeded()
            tasksPage.show(TodoView(key: key) ?? .today)
        case .goal(let id):
            if !TasksHub.openGoal(id) { notice("Couldn’t open that goal.", root: root) }
        case .needsYou:
            if let tasksPage = TasksHub.showPage() {
                tasksPage.loadViewIfNeeded()
                tasksPage.show(.today)
            } else {
                _ = openPage("bots", root: root)
            }
        case .groupChat(let key):
            if let model = root.services as? AppModel {
                model.openRoom(key, from: root)
            } else {
                notice("That group chat isn’t available.", root: root)
            }
        case .chatSession(let profile, let sessionId):
            if let summary = root.services.sessions.first(where: { $0.id == sessionId && (profile.isEmpty || $0.profile == profile) })
                ?? root.services.sessions.first(where: { $0.id == sessionId }) {
                root.sessionsViewController.openChat(summary)
            } else if !profile.isEmpty, let record = voiceRecord(profile) {
                _ = OpenBotChatIntent.open(record)
            } else {
                notice("That chat is no longer in your list.", root: root)
            }
        case .jobDetail(let key):
            openJob(key: key, root: root, from: page)
        case .kanban(let board, let status):
            if let store = root.pages?.kanbanStore {
                if let board, !board.isEmpty, board != store.boardKey { store.select(board: board) }
                if let status, !status.isEmpty { store.picked(status) }
            }
            if !openPage("kanban", root: root) { notice("Kanban isn’t available on this gateway.", root: root) }
        case .gatewayStatus:
            if !openPage("command-center", root: root) { notice("Status & Maintenance isn’t available.", root: root) }
        case .usage:
            if !openPage("usage", root: root) { notice("Usage isn’t available.", root: root) }
        case .dashboardPage(let id):
            guard let tiles = dashboard(root) else { return notice("Tiles isn’t available on this gateway.", root: root) }
            tiles.loadViewIfNeeded()
            tiles.showPage(id)
        case .filesFolder(let profile, let path):
            if let accountId = MorePages.context?.account.id {
                let targetProfile = profile?.nilIfEmpty ?? "default"
                MoreWorkspaceRoot.setChosen(path, account: accountId, profile: targetProfile)
            }
            if !openPage("files", root: root) { notice("Files isn’t available on this gateway.", root: root) }
        case .link, .runJob, .sendInBackground, .quickAsk, .routine, .toggleSection, .unavailable:
            break
        }
    }

    private static func openJob(key: String?, root: MainTabController, from page: QuickActionsViewController) {
        if let tab = root.placedTab(tagged: HQTab.jobs.rawValue) {
            root.show(tab)
            if let stack = tab as? UINavigationController {
                stack.popToRootViewController(animated: false)
                if let key, let jobsVC = stack.viewControllers.first as? JobsViewController {
                    jobsVC.loadViewIfNeeded()
                    jobsVC.openDetail(key)
                }
            }
            return
        }
        if openPage("jobs", root: root), let key {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if let moreStack = root.pages?.more?.navigationController,
                   let jobsVC = moreStack.topViewController as? JobsViewController {
                    jobsVC.openDetail(key)
                }
            }
        }
    }

    /// The push's (or pop's) animation done.
    private static func settled(_ navigation: UINavigationController) async {
        guard let coordinator = navigation.transitionCoordinator else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            if !coordinator.animate(alongsideTransition: nil, completion: { _ in done.resume() }) { done.resume() }
        }
    }

    private static func dashboard(_ root: MainTabController) -> ArtifactsViewController? {
        if let tiles = WidgetRouter.showTiles(root) { return tiles }
        guard openPage("pinned", root: root) else { return nil }
        func find(_ vc: UIViewController) -> ArtifactsViewController? {
            if let tiles = vc as? ArtifactsViewController, tiles.pinnedOnly, tiles.viewIfLoaded?.window != nil { return tiles }
            if let stack = vc as? UINavigationController, let top = stack.topViewController { return find(top) }
            for child in vc.children { if let hit = find(child) { return hit } }
            return nil
        }
        return find(root)
    }

    private static func close(_ page: QuickActionsViewController) async {
        guard let navigation = page.navigationController, navigation.presentingViewController != nil else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            navigation.dismiss(animated: true) { done.resume() }
        }
    }

    static func voiceRecord(_ profile: String) -> VoiceBotRecord? {
        let key = VoiceBotCatalog.key(profile: profile)
        let hits = VoiceBotCatalog.bots().filter { $0.key == key }
        let digest = ShortcutPolicy.digest()
        return hits.first { record in
            let parts = record.account.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return parts.count == 2 && ShortcutPolicy.accountDigest(url: parts[0], username: parts[1]) == digest
        } ?? hits.first
    }

    private static func row(_ id: String, root: MainTabController?) -> MoreRow? {
        root?.pages?.quickActionChoices().flatMap { $0.rows() }.first { $0.id == id }
    }

    @discardableResult static func openPage(_ id: String, root: MainTabController) -> Bool {
        if TabChoice.pageIDs.contains(id), let tab = root.placedTab(tagged: TabChoice.page(id).tag) {
            root.show(tab)
            _ = (tab as? UINavigationController)?.popToRootViewController(animated: false)
            return true
        }
        guard let more = root.pages?.more, let stack = more.navigationController, root.slotIndex(for: stack) != nil else { return false }
        root.show(stack)
        stack.popToRootViewController(animated: false)
        more.loadViewIfNeeded()
        if more.open(rowId: id) != nil { return true }
        guard let next = row(id, root: root)?.make() else { return false }
        stack.pushViewController(next, animated: true)
        return true
    }

    private static func missingBot(_ tile: QuickTile) -> String { "\(tile.botName ?? tile.bot ?? "That bot") isn’t on this gateway." }
    private static func missingPage(_ tile: QuickTile) -> String { "\(tile.pageName ?? tile.name) isn’t on this gateway." }
    private static func missingTile(_ tile: QuickTile) -> String { QuickTileRules.notOnDashboard(tile) }

    private static func notice(_ message: String, root: MainTabController) {
        let alert = UIAlertController(title: "Couldn’t Run That Action", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        (FailureAlert.topmost(root) ?? root).present(alert, animated: true)
    }

    static func words(_ error: Error) -> String {
        if let local = error as? LocalizedError, let text = local.errorDescription, !text.isEmpty { return text }
        return "That didn’t go through. Try again."
    }
}
