// [quick-actions] Add Action and Set Up (docs/spec/3x-morepages.md §25 Q4, Q5, Q15–Q21):
// Lists Chats, Work & Prompts, Live Widgets, Dashboard Tiles, Pages & Shortcuts, and Organization with live search;
// Set Up configures each kind's target (bot, project, message, job, task view, goal, group chat, session, kanban board,
// saved prompt, slash command, folder, URL, routine steps) plus Look (Name, Size, Height, Bot Avatar, Icon, Color)
// under a live preview.

import SwiftUI
import UIKit

// MARK: - Add Action

struct QuickActionChoice: Identifiable {
    var id: String
    var kind: QuickTileKind
    var title: String
    var detail: String
    var symbol: String
    var color: UIColor
    var page: (id: String, title: String)? = nil
    var pin: ArtifactPin? = nil

    static let chats: [QuickActionChoice] = [
        choice(.newChat, "New Chat", "bot · project · words"),
        choice(.memo, "Voice Memo", "bot"),
        choice(.talk, "Talk", "bot"),
        choice(.send, "Send a Message", "bot · words"),
        choice(.openChat, "Open a Chat", "bot"),
    ]

    static let work: [QuickActionChoice] = [
        choice(.addTask, "Add Task", "bot"),
        choice(.runJob, "Run Job", "job"),
    ]

    static let liveWidgets: [QuickActionChoice] = [
        choice(.tasks, "Tasks List", "live checklist with check-off"),
        choice(.goal, "Goal Progress", "ring, pace, and next step"),
        choice(.needsYou, "Needs You", "approvals, waiting tasks, active bots"),
        choice(.approvals, "Approvals & Questions", "one-tap Allow / Deny & answers"),
        choice(.activeRuns, "Active Now", "running bots & helpers"),
        choice(.inlineAsk, "Inline Ask", "ask a bot right on Favorites"),
        choice(.livePeek, "Browser & Screen", "watch bots browse or use screen"),
        choice(.botCard, "Live Bot Card", "avatar, status, Memo & Talk"),
        choice(.groupChat, "Group Chat", "live room card"),
        choice(.chatSession, "Specific Chat", "pin an ongoing thread"),
        choice(.jobCard, "Job Status / Upcoming", "live status and Run Now"),
        choice(.kanban, "Kanban Board", "live column counts & cards"),
        choice(.gatewayStatus, "Gateway Status", "health, sessions, platforms"),
        choice(.usage, "Usage Overview", "tokens, cost & sparkline"),
    ]

    static let shortcuts: [QuickActionChoice] = [
        choice(.quickAsk, "Quick Ask…", "prompt right on Favorites"),
        choice(.prompt, "Saved Prompt", "from your prompt library"),
        choice(.slashCommand, "Slash Command", "run a favorite command"),
        choice(.routine, "Routine", "run several steps at once"),
        choice(.dashboardPage, "Dashboard Page", "jump to a Tiles page"),
        choice(.filesFolder, "Files Folder", "open a specific folder"),
        choice(.link, "Web Link", "open any URL"),
    ]

    static let organize: [QuickActionChoice] = [
        choice(.section, "Section Header", "collapsible group divider"),
    ]

    private static func choice(_ kind: QuickTileKind, _ title: String, _ detail: String) -> QuickActionChoice {
        QuickActionChoice(id: kind.rawValue, kind: kind, title: title, detail: detail, symbol: kind.defaultLook.symbol,
                          color: QuickTileLook.color(kind.defaultLook.color))
    }

    static func pages(_ sections: [MoreSection]) -> [QuickActionChoice] {
        var out: [QuickActionChoice] = []
        for section in sections {
            for row in section.rows() {
                out.append(QuickActionChoice(id: "page." + row.id, kind: .page, title: row.title, detail: section.header ?? "page",
                                             symbol: row.symbol ?? QuickTileKind.page.defaultLook.symbol, color: row.tile,
                                             page: (row.id, row.title)))
            }
        }
        out.append(QuickActionChoice(id: QuickTileKind.search.rawValue, kind: .search, title: "Search Chats", detail: "page",
                                     symbol: QuickTileKind.search.defaultLook.symbol,
                                     color: QuickTileLook.color(QuickTileKind.search.defaultLook.color)))
        return out
    }

    static func dashboardTiles(_ pins: [ArtifactPin], names: [String: String], on list: QuickTileList) -> [QuickActionChoice] {
        let added = list.pins
        return pins.filter { !added.contains($0.id) }.map { pin in
            var named = pin
            named.title = names[pin.id] ?? pin.name
            return QuickActionChoice(id: "tile." + pin.id, kind: .dashboardTile, title: named.name, detail: "tile",
                                     symbol: PinCardView.glyph(pin), color: HQPalette.tint, pin: named)
        }
    }

    var identifier: String { pin.map { "quick.add.tile.\($0.label)" } ?? "quick.add.\(id)" }

    func newTile() -> QuickTile {
        var tile = QuickTile(kind: kind)
        if let pin {
            tile.pin = pin.id
            tile.pinName = pin.name
            tile.name = pin.name
            tile.symbol = QuickTileLook.symbol(symbol)
        }
        if let page {
            tile.page = page.id
            tile.pageName = page.title
            tile.name = page.title
            tile.symbol = QuickTileLook.symbol(symbol)
        }
        if kind == .newChat || kind == .quickAsk { tile.flag = true }
        if kind == .send || kind == .prompt { tile.flag = false }
        if kind.needsBot, let first = MainTabController.current?.services.bots.first {
            tile.bot = first.id
            tile.botName = first.name
            if kind == .openChat || kind == .botCard { tile.name = first.name }
            if kind == .quickAsk || kind == .inlineAsk { tile.name = "Ask \(first.name)" }
        }
        if kind == .runJob, let job = JobShortcutCatalog.jobs().first {
            tile.job = job.key
            tile.jobName = job.name
            tile.name = job.name
        }
        if kind == .tasks {
            tile.taskView = "today"
            tile.taskViewName = "Today"
            tile.name = "Today"
            tile.wide = true
        }
        if kind == .goal, let firstGoal = TasksHub.current?.goals.first(where: { $0.state == .active }) ?? TasksHub.current?.goals.first {
            tile.goalId = firstGoal.id
            tile.goalName = firstGoal.title
            tile.name = firstGoal.title
            tile.wide = true
        }
        if kind == .needsYou || kind == .botCard || kind == .kanban || kind == .usage || kind == .jobCard
            || kind == .approvals || kind == .activeRuns || kind == .inlineAsk || kind == .livePeek {
            tile.wide = true
        }
        if kind == .groupChat, let room = (MainTabController.current?.services as? GroupServices)?.groupStore?.rows().first {
            tile.roomKey = room.id
            tile.roomName = room.name
            tile.name = room.name
        }
        if kind == .chatSession, let session = MainTabController.current?.services.sessions.first {
            tile.sessionId = session.id
            tile.sessionTitle = session.title
            tile.bot = session.profile
            tile.botName = QuickActionsRouter.botName(session.profile)
            tile.name = session.title.isEmpty ? "Chat" : session.title
        }
        if kind == .prompt, let firstPrompt = PromptLibrary.shared.prompts.first {
            tile.promptId = firstPrompt.id.uuidString
            tile.message = firstPrompt.text
            tile.name = firstPrompt.displayTitle
        }
        if kind == .slashCommand {
            let favs = MorePages.context.map { CommandFavorites(accountId: $0.account.id).commands } ?? []
            let cmd = favs.first ?? "/status"
            tile.command = cmd
            tile.name = cmd
        }
        if kind == .usage {
            tile.days = 7
        }
        if kind == .dashboardPage {
            tile.dashboardPageId = DashboardPage.mainId
            tile.dashboardPageName = DashboardPage.main.name
            tile.name = DashboardPage.main.name
        }
        if kind == .filesFolder, let proj = ProjectShortcutCatalog.projects().first {
            tile.folderPath = proj.key
            tile.folderName = proj.name
            tile.name = proj.name
        }
        if kind == .routine {
            tile.name = "Morning Routine"
            tile.steps = []
        }
        if kind == .section {
            tile.name = "My Section"
        }
        return tile
    }

    func matches(_ words: String) -> Bool {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(words) || detail.localizedCaseInsensitiveContains(words)
    }
}

enum QuickActionAddSheet {
    static func make(choices: @escaping () -> [MoreSection], tiles: [QuickActionChoice] = [], source: FavoriteTiles? = nil,
                     onAdd: @escaping (QuickTile) -> Void) -> UINavigationController {
        let host = QuickActionAddHost(pages: QuickActionChoice.pages(choices()), tiles: tiles, source: source, onAdd: onAdd)
        let navigation = ChatSheet.wrap(host, title: "Add Action", detents: [.large()])
        navigation.view.accessibilityIdentifier = "quick-actions.add-sheet"
        return navigation
    }
}

final class QuickActionAddHost: UIHostingController<HQScaledRoot<QuickActionAddView>> {
    init(pages: [QuickActionChoice], tiles: [QuickActionChoice] = [], source: FavoriteTiles? = nil, onAdd: @escaping (QuickTile) -> Void) {
        let pictures = source.map(FavoriteTilePictures.init)
        var view = QuickActionAddView(pages: pages, tiles: tiles, pictures: pictures)
        weak var weakSelf: QuickActionAddHost?
        view.choose = { choice in weakSelf?.setUp(choice) }
        self.onAdd = onAdd
        self.pictures = pictures
        super.init(rootView: HQScaledRoot(view))
        weakSelf = self
    }

    private let onAdd: (QuickTile) -> Void
    private let pictures: FavoriteTilePictures?

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func setUp(_ choice: QuickActionChoice) {
        PagesHaptics.selection()
        let setup = QuickActionSetup.page(tile: choice.newTile(), isNew: true, pictures: pictures) { [weak self] tile in
            guard let self else { return }
            PagesHaptics.success()
            self.onAdd(tile)
            let sheet = self.navigationController ?? self
            (sheet.presentingViewController ?? sheet).dismiss(animated: true)
        }
        navigationController?.pushViewController(setup, animated: true)
    }
}

struct QuickActionAddView: View {
    var pages: [QuickActionChoice]
    var tiles: [QuickActionChoice] = []
    var pictures: FavoriteTilePictures? = nil
    var choose: (QuickActionChoice) -> Void = { _ in }
    @State private var words = ""

    var body: some View {
        let allGroups = [QuickActionChoice.chats, QuickActionChoice.work, tiles,
                         QuickActionChoice.liveWidgets, QuickActionChoice.shortcuts, pages, QuickActionChoice.organize]
        List {
            group("Chats", QuickActionChoice.chats)
            group("Work", QuickActionChoice.work)
            group("Dashboard Tiles", tiles)
            group("Live Widgets", QuickActionChoice.liveWidgets)
            group("Smart Actions & Shortcuts", QuickActionChoice.shortcuts)
            group("Pages", pages)
            group("Organize", QuickActionChoice.organize)
            if allGroups.allSatisfy({ $0.allSatisfy { !$0.matches(words) } }) {
                Text("No actions or pages match “\(words)”.")
                    .font(Font.hq(.body))
                    .foregroundStyle(Color.hqLabel2)
                    .listRowBackground(Color.clear)
            }
        }
        .searchable(text: $words, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search actions and pages")
        .hqGroupedPage()
    }

    @ViewBuilder private func group(_ title: String, _ choices: [QuickActionChoice]) -> some View {
        let shown = choices.filter { $0.matches(words) }
        if !shown.isEmpty {
            Section {
                ForEach(shown) { choice in
                    Button { choose(choice) } label: {
                        HStack(spacing: 12) {
                            if let pin = choice.pin {
                                DashboardTileThumb(pin: pin, pictures: pictures, side: HQFont.scaled(29))
                            } else {
                                QuickTileIcon(symbol: choice.symbol, color: choice.color, side: HQFont.scaled(29))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(choice.title).font(Font.hq(.body)).foregroundStyle(Color.hqLabel)
                                Text(choice.detail).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward").font(Font.hq(.footnote).weight(.semibold))
                                .foregroundStyle(Color.hqLabel3)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(choice.title), \(choice.detail)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier(choice.identifier)
                }
            } header: { HQSectionLabel { Text(title) } }
            .hqSheetRows()
        }
    }
}

// MARK: - Set Up

@MainActor @Observable
final class QuickActionDraft {
    var tile: QuickTile
    let original: QuickTile
    let isNew: Bool
    var nameTouched: Bool

    let bots: [(id: String, name: String)]
    let jobs: [JobShortcutRecord]
    let taskViews: [(key: String, name: String)]
    let goals: [(id: String, title: String)]
    let rooms: [(id: String, name: String)]
    let sessions: [(id: String, title: String, profile: String)]
    let boards: [(slug: String, title: String)]
    let dashboardPages: [(id: String, name: String)]
    let savedPrompts: [SavedPrompt]
    let favoriteCommands: [String]
    let pagesChoices: [(id: String, title: String)]
    let pinChoices: [(id: String, name: String)]
    @ObservationIgnored let pictures: FavoriteTilePictures?
    @ObservationIgnored let previewLive = FavoritesLiveModel()

    init(tile: QuickTile, isNew: Bool, pictures: FavoriteTilePictures? = nil) {
        var tile = tile
        self.pictures = pictures
        if tile.known == .dashboardTile, tile.name == tile.pinName,
           let now = pictures?.source.pin(tile.pin).map({ pictures?.source.pins.name($0) ?? $0.name }) {
            tile.name = now
            tile.pinName = now
        }
        self.tile = tile
        original = tile
        self.isNew = isNew
        nameTouched = !isNew && !(tile.known == .dashboardTile && tile.name == tile.pinName)

        let roster = MainTabController.current?.services.bots.map { (id: $0.id, name: $0.name) } ?? []
        if let bot = tile.bot, !bot.isEmpty, !roster.contains(where: { $0.id == bot }) {
            bots = roster + [(id: bot, name: tile.botName ?? bot)]
        } else {
            bots = roster
        }

        var seenJobs = Set<String>()
        var jobs = JobShortcutCatalog.jobs().filter { seenJobs.insert($0.key).inserted }
        if let job = tile.job, !job.isEmpty, !jobs.contains(where: { $0.key == job }) {
            jobs.append(JobShortcutRecord(key: job, id: job, owner: "", name: tile.jobName ?? tile.name, account: ""))
        }
        self.jobs = jobs

        // Tasks views
        var views: [(key: String, name: String)] = [
            ("today", "Today"),
            ("upcoming", "Upcoming"),
            ("inbox", "Inbox"),
            ("bots", "Bots’ Tasks"),
        ]
        if let store = TasksHub.current {
            store.prepare()
            for section in store.sections {
                views.append(("list:\(section.id)", section.name))
            }
        }
        taskViews = views

        // Goals
        if let store = TasksHub.current {
            store.prepare()
            goals = store.goals.map { (id: $0.id, title: $0.title.isEmpty ? "Untitled Goal" : $0.title) }
        } else {
            goals = []
        }

        // Group chats
        rooms = ((MainTabController.current?.services as? GroupServices)?.groupStore?.rows() ?? [])
            .map { (id: $0.id, name: $0.name) }

        // Recent sessions
        sessions = (MainTabController.current?.services.sessions ?? []).prefix(40)
            .map { (id: $0.id, title: $0.title.isEmpty ? "Chat" : $0.title, profile: $0.profile) }

        // Kanban boards
        if let store = MainTabController.current?.pages?.kanbanStore {
            store.prepare()
            boards = (store.boards?.boards ?? []).map { (slug: $0.slug, title: KanbanModel.boardTitle(slug: $0.slug, name: $0.name)) }
        } else {
            boards = []
        }

        // Dashboard pages & pins
        if let store = FavoriteTiles.store() {
            let pins = ArtifactPins.of(accountId: store.account.id)
            dashboardPages = pins.pages.map { (id: $0.id, name: $0.name) }
            pinChoices = store.hidden.visible(pins.pins).map { (id: $0.id, name: pins.name($0)) }
        } else {
            dashboardPages = [(DashboardPage.mainId, DashboardPage.main.name)]
            pinChoices = []
        }

        savedPrompts = PromptLibrary.shared.prompts
        let favCmds = MorePages.context.map { CommandFavorites(accountId: $0.account.id).commands } ?? []
        let defaults = ["/status", "/usage", "/model", "/clear", "/compact", "/help"]
        favoriteCommands = favCmds + defaults.filter { !favCmds.contains($0) }

        pagesChoices = (MainTabController.current?.pages?.quickActionChoices() ?? [])
            .flatMap { $0.rows() }
            .map { (id: $0.id, title: $0.title) }
    }

    var kind: QuickTileKind? { tile.known }

    var projects: [ProjectShortcutRecord] {
        let account = tile.bot.flatMap(QuickActionsRouter.voiceRecord)?.account
        var seen = Set<String>()
        return ProjectShortcutCatalog.projects().filter { (account == nil || $0.account == account) && seen.insert($0.key).inserted }
    }

    var bot: String {
        get { tile.bot ?? "" }
        set {
            tile.bot = newValue.isEmpty ? nil : newValue
            tile.botName = bots.first { $0.id == newValue }?.name
            if !nameTouched {
                if kind == .openChat || kind == .botCard { tile.name = tile.botName ?? tile.name }
                if kind == .quickAsk || kind == .inlineAsk, let b = tile.botName { tile.name = "Ask \(b)" }
            }
            if let project = tile.project, !projects.contains(where: { $0.key == project }) {
                tile.project = nil
                tile.projectName = nil
            }
        }
    }

    var project: String {
        get { tile.project ?? "" }
        set {
            tile.project = newValue.isEmpty ? nil : newValue
            tile.projectName = projects.first { $0.key == newValue }?.name
        }
    }

    var job: String {
        get { tile.job ?? "" }
        set {
            tile.job = newValue.isEmpty ? nil : newValue
            tile.jobName = jobs.first { $0.key == newValue }?.name
            if !nameTouched {
                if let name = tile.jobName { tile.name = name }
                else if kind == .jobCard { tile.name = "Upcoming Jobs" }
            }
        }
    }

    var taskView: String {
        get { tile.taskView ?? "today" }
        set {
            tile.taskView = newValue
            let label = taskViews.first { $0.key == newValue }?.name ?? "Today"
            tile.taskViewName = label
            if !nameTouched { tile.name = label }
        }
    }

    var goalId: String {
        get { tile.goalId ?? "" }
        set {
            tile.goalId = newValue.isEmpty ? nil : newValue
            tile.goalName = goals.first { $0.id == newValue }?.title
            if !nameTouched, let title = tile.goalName { tile.name = title }
        }
    }

    var roomKey: String {
        get { tile.roomKey ?? "" }
        set {
            tile.roomKey = newValue.isEmpty ? nil : newValue
            tile.roomName = rooms.first { $0.id == newValue }?.name
            if !nameTouched, let name = tile.roomName { tile.name = name }
        }
    }

    var sessionId: String {
        get { tile.sessionId ?? "" }
        set {
            tile.sessionId = newValue.isEmpty ? nil : newValue
            if let hit = sessions.first(where: { $0.id == newValue }) {
                tile.sessionTitle = hit.title
                tile.bot = hit.profile
                tile.botName = bots.first { $0.id == hit.profile }?.name ?? hit.profile
                if !nameTouched { tile.name = hit.title }
            }
        }
    }

    var boardSlug: String {
        get { tile.boardSlug ?? "" }
        set {
            tile.boardSlug = newValue.isEmpty ? nil : newValue
            tile.boardName = boards.first { $0.slug == newValue }?.title
            if !nameTouched { tile.name = tile.boardName ?? "Kanban" }
        }
    }

    var columnStatus: String {
        get { tile.columnStatus ?? "" }
        set { tile.columnStatus = newValue.isEmpty ? nil : newValue }
    }

    var dashboardPageId: String {
        get { tile.dashboardPageId ?? DashboardPage.mainId }
        set {
            tile.dashboardPageId = newValue
            let name = dashboardPages.first { $0.id == newValue }?.name ?? "Main"
            tile.dashboardPageName = name
            if !nameTouched { tile.name = name }
        }
    }

    var command: String {
        get { tile.command ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            tile.command = trimmed.isEmpty ? nil : (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
            if !nameTouched, let cmd = tile.command { tile.name = cmd }
        }
    }

    var urlString: String {
        get { tile.url ?? "" }
        set {
            tile.url = newValue.isEmpty ? nil : newValue
            if !nameTouched, let host = QuickTileRoute.normalizedURL(newValue)?.host {
                tile.name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
        }
    }

    var folderPath: String {
        get { tile.folderPath ?? "" }
        set {
            tile.folderPath = newValue.isEmpty ? nil : newValue
            let base = (newValue as NSString).lastPathComponent
            tile.folderName = base.isEmpty ? nil : base
            if !nameTouched, !base.isEmpty { tile.name = base }
        }
    }

    var days: Int {
        get { tile.days ?? 7 }
        set { tile.days = newValue }
    }

    var showAvatar: Bool {
        get { tile.showAvatar == true }
        set { tile.showAvatar = newValue ? true : nil }
    }

    var tileSize: QuickTileSize {
        get { tile.effectiveSize }
        set {
            tile.wide = newValue.isWideSpan
            tile.size = (newValue == .small || newValue == .wide) ? nil : newValue
            if newValue == .mini || newValue.rowSpan > 1 || kind?.supportsShort == false {
                tile.short = false
            }
        }
    }

    var name: String {
        get { tile.name }
        set {
            tile.name = newValue
            nameTouched = true
        }
    }

    var message: String {
        get { tile.message ?? "" }
        set { tile.message = newValue.isEmpty ? nil : newValue }
    }

    var flag: Bool {
        get { tile.flag ?? false }
        set { tile.flag = newValue }
    }

    var routineSteps: [QuickRoutineStep] {
        get { tile.steps ?? [] }
        set { tile.steps = newValue.isEmpty ? nil : newValue }
    }

    func pickSavedPrompt(_ prompt: SavedPrompt) {
        tile.promptId = prompt.id.uuidString
        tile.message = prompt.text
        if !nameTouched { tile.name = prompt.displayTitle }
    }

    func addRoutineStep(_ kind: QuickRoutineStep.StepKind) {
        var step = QuickRoutineStep(kind: kind)
        if let firstBot = bots.first {
            step.bot = firstBot.id
            step.botName = firstBot.name
        }
        switch kind {
        case .runJob:
            if let j = jobs.first { step.job = j.key; step.jobName = j.name }
        case .send:
            step.message = ""
        case .slashCommand:
            step.command = favoriteCommands.first ?? "/status"
        case .openPage:
            if let p = pagesChoices.first { step.page = p.id; step.pageName = p.title }
        case .openChat:
            break
        case .openTile:
            if let p = pinChoices.first { step.pin = p.id; step.pinName = p.name }
        }
        var current = routineSteps
        current.append(step)
        routineSteps = current
    }

    var canSave: Bool {
        guard !tile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let kind else { return false }
        if kind.needsBot, (tile.bot ?? "").isEmpty { return false }
        if (kind == .send || kind == .prompt), (tile.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if kind == .slashCommand, (tile.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if kind == .runJob, (tile.job ?? "").isEmpty { return false }
        if kind == .page, (tile.page ?? "").isEmpty { return false }
        if kind == .dashboardTile, (tile.pin ?? "").isEmpty { return false }
        if kind == .goal, (tile.goalId ?? "").isEmpty { return false }
        if kind == .groupChat, (tile.roomKey ?? "").isEmpty { return false }
        if kind == .chatSession, (tile.sessionId ?? "").isEmpty { return false }
        if kind == .filesFolder, (tile.folderPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if kind == .link, QuickTileRoute.normalizedURL(tile.url ?? "") == nil { return false }
        if kind == .routine, routineSteps.isEmpty { return false }
        return true
    }

    var hasChanges: Bool { tile != original }

    var finished: QuickTile {
        var tile = tile
        tile.name = tile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let words = tile.message?.trimmingCharacters(in: .whitespacesAndNewlines) { tile.message = words.isEmpty ? nil : words }
        if tile.known == .dashboardTile, !nameTouched { tile.pinName = tile.name }
        return tile
    }
}

enum QuickActionSetup {
    static func page(tile: QuickTile, isNew: Bool, pictures: FavoriteTilePictures? = nil,
                     onSave: @escaping (QuickTile) -> Void) -> UIViewController {
        QuickActionSetupHost(draft: QuickActionDraft(tile: tile, isNew: isNew, pictures: pictures), onSave: onSave)
    }

    static func sheet(editing tile: QuickTile, pictures: FavoriteTilePictures? = nil,
                      onSave: @escaping (QuickTile) -> Void) -> UINavigationController {
        let host = QuickActionSetupHost(draft: QuickActionDraft(tile: tile, isNew: false, pictures: pictures), onSave: onSave)
        let navigation = ChatSheet.wrap(host, title: "Edit Action", detents: [.large()])
        host.installCancel()
        SheetEditGuard.install(on: navigation)
        navigation.view.accessibilityIdentifier = "quick-actions.setup-sheet"
        return navigation
    }
}

final class QuickActionSetupHost: UIHostingController<HQScaledRoot<QuickActionSetupView>>, EditingPage {
    let draft: QuickActionDraft
    private let onSave: (QuickTile) -> Void
    private var saveItem: UIBarButtonItem!

    init(draft: QuickActionDraft, onSave: @escaping (QuickTile) -> Void) {
        self.draft = draft
        self.onSave = onSave
        super.init(rootView: HQScaledRoot(QuickActionSetupView(draft: draft)))
        title = draft.isNew ? "Set Up" : "Edit Action"
        navigationItem.largeTitleDisplayMode = .never
        saveItem = UIBarButtonItem(title: draft.isNew ? "Add" : "Save", primaryAction: UIAction { [weak self] _ in self?.save() })
        saveItem.style = .prominent
        saveItem.accessibilityIdentifier = "quick.setup.save"
        navigationItem.rightBarButtonItem = saveItem
        updateSave()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var hasChanges: Bool { !draft.isNew && draft.hasChanges }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + (draft.canSave ? [.save(draft.isNew ? "Add" : "Save", #selector(saveFromKeyboard))] : [])
    }
    override var canBecomeFirstResponder: Bool { true }
    @objc private func saveFromKeyboard() { save() }

    func installCancel() {
        let close = UIBarButtonItem.hqClose(.cancel, action: UIAction { [weak self] _ in
            guard let self else { return }
            self.view.endEditing(true)
            self.confirmLeaving { [weak self] in self?.dismiss(animated: true) }
        })
        close.accessibilityIdentifier = "sheet.close"
        navigationItem.hqPlaceFormClose(close)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "quick.setup"
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = draft.tile
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateSave(); self?.observe() }
        }
    }

    private func updateSave() {
        saveItem.setProminentEnabled(draft.canSave)
        if let navigation = navigationController { EditingGuard.refreshLock(navigation) }
    }

    private func save() {
        guard draft.canSave else { return }
        view.endEditing(true)
        let tile = draft.finished
        if draft.isNew {
            onSave(tile)
        } else {
            PagesHaptics.success()
            onSave(tile)
            dismiss(animated: true)
        }
    }
}

struct QuickActionSetupView: View {
    @Bindable var draft: QuickActionDraft
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Form {
            Section {
                preview
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .hqDesktopBareRow()
            }
            if let kind = draft.kind { details(kind) }
            look
        }
        .hqGroupedPage()
    }

    @ViewBuilder private var preview: some View {
        if draft.kind == .dashboardTile {
            DashboardTilePreview(tile: draft.tile, pictures: draft.pictures, stacked: typeSize >= .accessibility3)
        } else if draft.kind == .section {
            FavoriteSectionHeaderView(title: draft.tile.name, collapsed: false, itemCount: 0, editing: false)
                .padding(.horizontal, 12)
                .accessibilityIdentifier("quick.setup.preview")
        } else if let kind = draft.kind, kind.isLiveCard {
            liveCardPreview(kind)
        } else {
            actionPreview
        }
    }

    private func liveCardPreview(_ kind: QuickTileKind) -> some View {
        let size = draft.tileSize
        let width: CGFloat? = (size.isWideSpan || typeSize >= .accessibility3) ? nil : HQFont.scaled(186)
        let height: CGFloat = size.rowSpan > 1
            ? HQFont.scaled(220)
            : (QuickTileLayout.usesCompactWideHeight(draft.tile) ? HQFont.scaled(134) : HQFont.scaled(160))
        return HStack {
            Spacer(minLength: 0)
            Group {
                switch kind {
                case .tasks: FavoriteTasksCard(tile: draft.tile, model: draft.previewLive, size: size, dimmed: false, onOpenTask: { _ in }, onAddTask: {})
                case .goal: FavoriteGoalCard(tile: draft.tile, model: draft.previewLive, size: size, dimmed: false)
                case .needsYou: FavoriteNeedsYouCard(tile: draft.tile, model: draft.previewLive, size: size, onSelect: { _ in })
                case .botCard: FavoriteBotCard(tile: draft.tile, model: draft.previewLive, size: size, dimmed: false, onMemo: {}, onTalk: {}, onNewChat: {})
                case .groupChat: FavoriteGroupChatCard(tile: draft.tile, model: draft.previewLive, size: size, dimmed: false)
                case .chatSession: FavoriteChatSessionCard(tile: draft.tile, model: draft.previewLive, size: size, dimmed: false)
                case .jobCard: FavoriteJobCard(tile: draft.tile, model: draft.previewLive, size: size, dimmed: false, onRunNow: { _, _ in })
                case .kanban: FavoriteKanbanCard(tile: draft.tile, model: draft.previewLive, size: size, dimmed: false)
                case .gatewayStatus: FavoriteGatewayStatusCard(tile: draft.tile, model: draft.previewLive, size: size)
                case .usage: FavoriteUsageCard(tile: draft.tile, model: draft.previewLive, size: size)
                case .approvals: FavoriteApprovalsCard(tile: draft.tile, model: draft.previewLive, size: size, onOpenBot: { _ in })
                case .activeRuns: FavoriteActiveRunsCard(tile: draft.tile, model: draft.previewLive, size: size, onOpenBot: { _ in })
                case .inlineAsk: FavoriteInlineAskCard(tile: draft.tile, model: draft.previewLive, size: size, dimmed: false, onOpenChat: { _ in })
                case .livePeek: FavoriteLivePeekCard(tile: draft.tile, model: draft.previewLive, size: size, onOpenBrowser: { _ in }, onOpenScreen: { _ in })
                default: EmptyView()
                }
            }
            .frame(maxWidth: width ?? .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: QuickTileCell.radius, style: .continuous)
                .fill(Color(uiColor: HQPalette.sheetCard)))
            .overlay {
                if Theme.isDesktop {
                    RoundedRectangle(cornerRadius: QuickTileCell.radius, style: .continuous)
                        .stroke(Color(uiColor: HQPalette.cardEdge), lineWidth: 1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview: \(draft.tile.name)")
        .accessibilityIdentifier("quick.setup.preview")
    }

    private var actionPreview: some View {
        let tile = draft.tile
        let subtitle = tile.subtitle(botName: draft.bots.first { $0.id == tile.bot }?.name)
        let avatar: (profile: String, head: JSONValue?)? = (tile.showAvatar == true && tile.bot != nil)
            ? (tile.bot!, draft.previewLive.bot(tile.bot)?.head) : nil
        return HStack {
            Spacer(minLength: 0)
            Group {
                if tile.effectiveSize == .mini && typeSize < .accessibility3 {
                    QuickTileMiniFace(name: tile.name, symbol: tile.symbol, color: QuickTileLook.color(tile.tint), botAvatar: avatar)
                        .frame(width: HQFont.scaled(86), height: HQFont.scaled(80))
                } else {
                    QuickTileFace(name: tile.name, subtitle: subtitle, symbol: tile.symbol, color: QuickTileLook.color(tile.tint),
                                  stacked: typeSize >= .accessibility3, short: tile.short, botAvatar: avatar)
                        .frame(maxWidth: tile.wide || typeSize >= .accessibility3 ? .infinity : HQFont.scaled(176))
                }
            }
            .background(RoundedRectangle(cornerRadius: QuickTileCell.radius, style: .continuous)
                .fill(Color(uiColor: HQPalette.sheetCard)))
            .overlay {
                if Theme.isDesktop {
                    RoundedRectangle(cornerRadius: QuickTileCell.radius, style: .continuous)
                        .stroke(Color(uiColor: HQPalette.cardEdge), lineWidth: 1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview: \(tile.name), \(subtitle)")
        .accessibilityIdentifier("quick.setup.preview")
    }

    @ViewBuilder private func details(_ kind: QuickTileKind) -> some View {
        if kind.needsBot || kind == .addTask || kind == .filesFolder || kind == .livePeek {
            Section {
                Picker("Bot", selection: $draft.bot) {
                    if kind == .livePeek { Text("Any Active Bot").tag("") }
                    else if kind == .addTask || kind == .filesFolder { Text("None").tag("") }
                    ForEach(draft.bots, id: \.id) { bot in Text(bot.name).tag(bot.id) }
                }
                .hqMenuPicker()
                .accessibilityIdentifier("quick.setup.bot")
                if kind == .newChat {
                    Picker("Project", selection: $draft.project) {
                        Text("None").tag("")
                        ForEach(draft.projects, id: \.key) { project in Text(project.name).tag(project.key) }
                    }
                    .hqMenuPicker()
                    .accessibilityIdentifier("quick.setup.project")
                }
            } header: { HQSectionLabel { Text(kind == .addTask ? "Task For" : "Bot") } }
            .hqSheetRows()
        }

        if kind == .newChat || kind == .send || kind == .prompt {
            Section {
                if kind == .prompt, !draft.savedPrompts.isEmpty {
                    Menu {
                        ForEach(draft.savedPrompts) { prompt in
                            Button(prompt.displayTitle) { draft.pickSavedPrompt(prompt) }
                        }
                    } label: {
                        LabeledContent("Saved Prompt") {
                            Text("Choose…").foregroundStyle(Color.hqTintText)
                        }
                    }
                }
                TextField(kind == .newChat ? "First Message (Optional)" : "Message", text: $draft.message, axis: .vertical)
                    .lineLimit(1...5)
                    .accessibilityIdentifier("quick.setup.message")
                if kind == .newChat, !draft.message.isEmpty {
                    Toggle("Send It", isOn: $draft.flag).accessibilityIdentifier("quick.setup.send")
                }
                if kind == .send || kind == .prompt {
                    Toggle("Open the Chat", isOn: $draft.flag).accessibilityIdentifier("quick.setup.open")
                }
            } header: { HQSectionLabel { Text(kind == .prompt ? "Prompt" : "Message") } }
            .hqSheetRows()
        }

        if kind == .quickAsk {
            Section {
                Toggle("Open Chat by Default", isOn: $draft.flag)
            } header: { HQSectionLabel { Text("Behavior") } }
            .hqSheetRows()
        }

        if kind == .slashCommand {
            Section {
                TextField("/status", text: $draft.command)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !draft.favoriteCommands.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(draft.favoriteCommands, id: \.self) { cmd in
                                Button {
                                    PagesHaptics.selection()
                                    draft.command = cmd
                                } label: {
                                    Text(cmd)
                                        .font(Font.hq(.footnote).weight(.medium))
                                        .foregroundStyle(draft.command == cmd ? Color.white : Color.hqLabel)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Capsule().fill(draft.command == cmd ? Color.hqTint : Color.hqFill3))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: { HQSectionLabel { Text("Command") } }
            .hqSheetRows()
        }

        if kind == .runJob || kind == .jobCard {
            Section {
                Picker("Job", selection: $draft.job) {
                    if kind == .jobCard { Text("All Upcoming Jobs").tag("") }
                    else if draft.job.isEmpty { Text("Choose").tag("") }
                    ForEach(draft.jobs, id: \.key) { job in Text(job.name).tag(job.key) }
                }
                .hqMenuPicker()
                .accessibilityIdentifier("quick.setup.job")
                if draft.jobs.isEmpty {
                    Text("Open Jobs once, and its jobs are listed here.")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                }
            } header: { HQSectionLabel { Text("Job") } }
            .hqSheetRows()
        }

        if kind == .tasks {
            Section {
                Picker("View", selection: $draft.taskView) {
                    ForEach(draft.taskViews, id: \.key) { view in Text(view.name).tag(view.key) }
                }
                .hqMenuPicker()
            } header: { HQSectionLabel { Text("Tasks List") } }
            .hqSheetRows()
        }

        if kind == .goal {
            Section {
                Picker("Goal", selection: $draft.goalId) {
                    if draft.goalId.isEmpty { Text("Choose").tag("") }
                    ForEach(draft.goals, id: \.id) { goal in Text(goal.title).tag(goal.id) }
                }
                .hqMenuPicker()
                if draft.goals.isEmpty {
                    Text("Create a goal in Tasks › Goals to pin it here.")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                }
            } header: { HQSectionLabel { Text("Goal") } }
            .hqSheetRows()
        }

        if kind == .groupChat {
            Section {
                Picker("Group Chat", selection: $draft.roomKey) {
                    if draft.roomKey.isEmpty { Text("Choose").tag("") }
                    ForEach(draft.rooms, id: \.id) { room in Text(room.name).tag(room.id) }
                }
                .hqMenuPicker()
                if draft.rooms.isEmpty {
                    Text("Group chats appear here once you have one in Bots.")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                }
            } header: { HQSectionLabel { Text("Group Chat") } }
            .hqSheetRows()
        }

        if kind == .chatSession {
            Section {
                Picker("Chat", selection: $draft.sessionId) {
                    if draft.sessionId.isEmpty { Text("Choose").tag("") }
                    ForEach(draft.sessions, id: \.id) { session in Text(session.title).tag(session.id) }
                }
                .hqMenuPicker()
            } header: { HQSectionLabel { Text("Conversation") } }
            .hqSheetRows()
        }

        if kind == .kanban {
            Section {
                Picker("Board", selection: $draft.boardSlug) {
                    Text("Current Board").tag("")
                    ForEach(draft.boards, id: \.slug) { b in Text(b.title).tag(b.slug) }
                }
                .hqMenuPicker()
                Picker("Column", selection: $draft.columnStatus) {
                    Text("All Active").tag("")
                    ForEach(KanbanModel.statusOrder, id: \.self) { status in
                        Text(KanbanModel.label(status)).tag(status)
                    }
                }
                .hqMenuPicker()
            } header: { HQSectionLabel { Text("Kanban") } }
            .hqSheetRows()
        }

        if kind == .usage {
            Section {
                LabeledContent("Period") {
                    HQSegmentedPicker("Period", options: [("7d", 7), ("30d", 30), ("90d", 90)], selection: $draft.days, wholeLabels: true)
                        .fixedSize()
                }
            } header: { HQSectionLabel { Text("Usage") } }
            .hqSheetRows()
        }

        if kind == .dashboardPage {
            Section {
                Picker("Dashboard Page", selection: $draft.dashboardPageId) {
                    ForEach(draft.dashboardPages, id: \.id) { page in Text(page.name).tag(page.id) }
                }
                .hqMenuPicker()
            } header: { HQSectionLabel { Text("Tiles Page") } }
            .hqSheetRows()
        }

        if kind == .filesFolder {
            Section {
                TextField("/path/to/folder", text: $draft.folderPath)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !draft.projects.isEmpty {
                    Menu {
                        ForEach(draft.projects, id: \.key) { proj in
                            Button(proj.name) { draft.folderPath = proj.key }
                        }
                    } label: {
                        LabeledContent("Project Folder") {
                            Text("Choose…").foregroundStyle(Color.hqTintText)
                        }
                    }
                }
            } header: { HQSectionLabel { Text("Folder") } }
            .hqSheetRows()
        }

        if kind == .link {
            Section {
                TextField("https://example.com", text: $draft.urlString)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: { HQSectionLabel { Text("Web Address") } }
            .hqSheetRows()
        }

        if kind == .routine {
            routineSection
        }
    }

    private var routineSection: some View {
        Section {
            ForEach(Array(draft.routineSteps.enumerated()), id: \.element.id) { index, step in
                routineStepRow(index: index, step: step)
            }
            .onDelete { offsets in
                var steps = draft.routineSteps
                steps.remove(atOffsets: offsets)
                draft.routineSteps = steps
            }
            Menu {
                ForEach(QuickRoutineStep.StepKind.allCases, id: \.self) { stepKind in
                    Button { draft.addRoutineStep(stepKind) } label: {
                        Label(stepKind.title, systemImage: stepKind.symbol)
                    }
                }
            } label: {
                Label("Add Step", systemImage: "plus.circle.fill")
                    .foregroundStyle(Color.hqTintText)
            }
        } header: { HQSectionLabel { Text("Steps") } } footer: {
            Text("Background steps (Run Job, Send Message) run in order. An Open step runs last.")
                .font(Font.hq(.footnote))
                .foregroundStyle(Color.hqLabel2)
        }
        .hqSheetRows()
    }

    @ViewBuilder private func routineStepRow(index: Int, step: QuickRoutineStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: step.knownKind?.symbol ?? "bolt.fill")
                    .font(Font.hq(.footnote).weight(.semibold))
                    .foregroundStyle(Color.hqTint)
                Text("\(index + 1). \(step.knownKind?.title ?? "Step")")
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .foregroundStyle(Color.hqLabel)
                Spacer()
                Button(role: .destructive) {
                    var steps = draft.routineSteps
                    if steps.indices.contains(index) { steps.remove(at: index); draft.routineSteps = steps }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(Color.hqRed)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove step \(index + 1)")
            }
            switch step.knownKind {
            case .runJob:
                Picker("Job", selection: Binding(
                    get: { step.job ?? "" },
                    set: { val in
                        var steps = draft.routineSteps
                        guard steps.indices.contains(index) else { return }
                        steps[index].job = val
                        steps[index].jobName = draft.jobs.first { $0.key == val }?.name
                        draft.routineSteps = steps
                    }
                )) {
                    ForEach(draft.jobs, id: \.key) { j in Text(j.name).tag(j.key) }
                }
                .hqMenuPicker()
            case .send:
                Picker("Bot", selection: Binding(
                    get: { step.bot ?? "" },
                    set: { val in
                        var steps = draft.routineSteps
                        guard steps.indices.contains(index) else { return }
                        steps[index].bot = val
                        steps[index].botName = draft.bots.first { $0.id == val }?.name
                        draft.routineSteps = steps
                    }
                )) {
                    ForEach(draft.bots, id: \.id) { b in Text(b.name).tag(b.id) }
                }
                .hqMenuPicker()
                TextField("Message", text: Binding(
                    get: { step.message ?? "" },
                    set: { val in
                        var steps = draft.routineSteps
                        guard steps.indices.contains(index) else { return }
                        steps[index].message = val
                        draft.routineSteps = steps
                    }
                ))
            case .slashCommand:
                Picker("Bot", selection: Binding(
                    get: { step.bot ?? "" },
                    set: { val in
                        var steps = draft.routineSteps
                        guard steps.indices.contains(index) else { return }
                        steps[index].bot = val
                        steps[index].botName = draft.bots.first { $0.id == val }?.name
                        draft.routineSteps = steps
                    }
                )) {
                    ForEach(draft.bots, id: \.id) { b in Text(b.name).tag(b.id) }
                }
                .hqMenuPicker()
                TextField("/status", text: Binding(
                    get: { step.command ?? "" },
                    set: { val in
                        var steps = draft.routineSteps
                        guard steps.indices.contains(index) else { return }
                        steps[index].command = val
                        draft.routineSteps = steps
                    }
                ))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            case .openPage:
                Picker("Page", selection: Binding(
                    get: { step.page ?? "" },
                    set: { val in
                        var steps = draft.routineSteps
                        guard steps.indices.contains(index) else { return }
                        steps[index].page = val
                        steps[index].pageName = draft.pagesChoices.first { $0.id == val }?.title
                        draft.routineSteps = steps
                    }
                )) {
                    ForEach(draft.pagesChoices, id: \.id) { p in Text(p.title).tag(p.id) }
                }
                .hqMenuPicker()
            case .openChat:
                Picker("Bot", selection: Binding(
                    get: { step.bot ?? "" },
                    set: { val in
                        var steps = draft.routineSteps
                        guard steps.indices.contains(index) else { return }
                        steps[index].bot = val
                        steps[index].botName = draft.bots.first { $0.id == val }?.name
                        draft.routineSteps = steps
                    }
                )) {
                    ForEach(draft.bots, id: \.id) { b in Text(b.name).tag(b.id) }
                }
                .hqMenuPicker()
            case .openTile:
                Picker("Tile", selection: Binding(
                    get: { step.pin ?? "" },
                    set: { val in
                        var steps = draft.routineSteps
                        guard steps.indices.contains(index) else { return }
                        steps[index].pin = val
                        steps[index].pinName = draft.pinChoices.first { $0.id == val }?.name
                        draft.routineSteps = steps
                    }
                )) {
                    ForEach(draft.pinChoices, id: \.id) { p in Text(p.name).tag(p.id) }
                }
                .hqMenuPicker()
            case nil:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }

    private var look: some View {
        Group {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $draft.name)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("quick.setup.name")
                }
                if draft.kind != .section {
                    if draft.kind?.isWidget == true {
                        LabeledContent("Size") {
                            HQSegmentedPicker("Size", options: [("Small", QuickTileSize.small), ("Wide", .wide), ("Large", .large)],
                                              selection: $draft.tileSize, wholeLabels: true)
                                .fixedSize()
                                .accessibilityIdentifier("quick.setup.size")
                        }
                        Picker("Layout Shape", selection: $draft.tileSize) {
                            ForEach(QuickTileSize.choices(for: draft.kind ?? .dashboardTile, wideScreen: true), id: \.self) { opt in
                                Label(opt.title, systemImage: opt.symbol).tag(opt)
                            }
                        }
                        .hqMenuPicker()
                    } else {
                        LabeledContent("Size") {
                            HQSegmentedPicker("Size", options: [("Mini", QuickTileSize.mini), ("Small", .small), ("Wide", .wide)],
                                              selection: $draft.tileSize, wholeLabels: true)
                                .fixedSize()
                                .accessibilityIdentifier("quick.setup.size")
                        }
                        if draft.tileSize != .mini {
                            LabeledContent("Height") {
                                HQSegmentedPicker("Height", options: [("Tall", false), ("Short", true)], selection: $draft.tile.short,
                                                  wholeLabels: true)
                                    .fixedSize()
                                    .accessibilityIdentifier("quick.setup.height")
                            }
                        }
                    }
                }
                if draft.kind?.supportsAvatarOption == true, !(draft.tile.bot ?? "").isEmpty {
                    Toggle("Use Bot Face", isOn: $draft.showAvatar)
                }
            } header: { HQSectionLabel { Text("Look") } }
            .hqSheetRows()
            if draft.kind?.supportsCustomLook == true { iconAndColor }
        }
    }

    private var iconAndColor: some View {
        Group {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: HQFont.scaled(44)), spacing: 8)], spacing: 8) {
                    ForEach(QuickTileLook.symbols, id: \.self) { symbol in symbolButton(symbol) }
                }
                .padding(.vertical, 6)
            } header: { HQSectionLabel { Text("Icon") } }
            .hqSheetRows()
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: HQFont.scaled(40)), spacing: 8)], spacing: 8) {
                    ForEach(QuickTileColor.allCases, id: \.self) { color in colorButton(color) }
                }
                .padding(.vertical, 6)
            } header: { HQSectionLabel { Text("Color") } }
            .hqSheetRows()
        }
    }

    private func symbolButton(_ symbol: String) -> some View {
        let chosen = draft.tile.symbol == symbol
        return Button {
            if !chosen { PagesHaptics.selection() }
            draft.tile.symbol = symbol
        } label: {
            Image(systemName: symbol)
                .font(Font.hq(.title3))
                .foregroundStyle(chosen ? Color.white : Color.hqLabel)
                .frame(width: HQFont.scaled(44), height: HQFont.scaled(44))
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(chosen ? Color(uiColor: QuickTileLook.color(draft.tile.tint)) : Color.hqFill3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("quick.setup.symbol.\(symbol)")
    }

    private func colorButton(_ color: QuickTileColor) -> some View {
        let chosen = draft.tile.tint == color
        return Button {
            if !chosen { PagesHaptics.selection() }
            draft.tile.color = color.rawValue
        } label: {
            Circle()
                .fill(Color(uiColor: QuickTileLook.color(color)))
                .frame(width: HQFont.scaled(32), height: HQFont.scaled(32))
                .padding(3)
                .overlay { if chosen { Circle().stroke(Color.hqLabel, lineWidth: 2) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(QuickTileLook.colorName(color))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("quick.setup.color.\(color.rawValue)")
    }
}
