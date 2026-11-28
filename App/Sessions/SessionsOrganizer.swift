// The Sessions rows' actions (spec 02 §9; the web's `S/ui-lists/session-menu.ts`, `session-swipe.ts`,
// `session-work.ts`, `archive-undo.ts`): one menu for the row's long press and the More swipe — tiles Pin ·
// Unread · Share; Rename…, Branch in New Chat, Move to Project ›, More › (Color, Export Chat, Copy Chat ID);
// Archive; Delete Chat — and the swipes (leading Unread/Read with a full swipe, Pin; trailing More, Delete, Archive,
// Archive outermost and the full swipe, as iOS Mail: UX study #66). Archive never asks and offers Undo; Delete asks with an action sheet. Every write
// goes through `SessionStore` (SessionStore+Actions.swift).

import SwiftUI
import UIKit

/// What the Sessions list needs from the app for the row actions. AppModel adopts it.
@MainActor protocol SessionsServices: AnyObject {
    var sessionStore: SessionStore? { get }
}

/// [sessions-m9] Mark All as Read also clears every bot's own chat, as the web does (docs/spec/3x-sessions.md §5.6).
@MainActor protocol SessionsBotReads: AnyObject {
    func markAllBotChatsRead()
}

extension AppModel: SessionsServices {}

@MainActor final class SessionsOrganizer {
    weak var host: SessionsViewController?
    let services: any AppServices
    let sessionsServices: any SessionsServices
    private var sharing = false

    init(host: SessionsViewController, services: any AppServices, sessionsServices: any SessionsServices) {
        self.host = host
        self.services = services
        self.sessionsServices = sessionsServices
    }

    var store: SessionStore? { sessionsServices.sessionStore }

    /// Where a row's HUD, Undo pill and popover show: the page its row is on (the list, or the Other Apps page pushed
    /// over it).
    var surface: UIViewController? { host?.navigationController?.topViewController ?? host }

    // MARK: - The menu

    /// `row`: the list item the menu was opened on (a chat's second row in its project has an id of its own), so Move
    /// Up / Move Down act in the group that row is in; nil is the chat's own row.
    func menuNodes(for session: SessionSummary, row: String? = nil) -> [BotMenuNode] {
        let tiles: [BotMenuNode] = [
            .action(Self.pinned(session) ? "Unpin" : "Pin", Self.pinned(session) ? "pin.slash" : "pin") { [weak self] in self?.pin(session) },
            // UX study 2026-10-19 #35: a verb, as the Bots menus say it; "Mark Read" (not "Mark as Read") fits a third of
            // the tile row at Extra Large text. The swipe buttons keep their short titles.
            .action(Self.readTitle(unread: session.unread), session.unread ? "envelope.open" : "envelope.badge") { [weak self] in
                self?.toggleRead(session)
            },
            .action(MenuWords.share, "square.and.arrow.up") { [weak self] in self?.share(session) },
        ]
        var palette: [BotMenuNode] = []
        let swatches = SessionColors.names.indices.map { index in
            BotMenuNode(title: SessionColors.names[index], checked: session.color == index, color: Self.uiColor(index),
                        identifier: "session-color-\(SessionColors.names[index])", kind: .action({ [weak self] in self?.setColor(session, index) }))
        }
        // Six to a row so all twelve show (a palette row scrolls the rest away); "Color" heads the first.
        for start in stride(from: 0, to: swatches.count, by: 6) {
            palette.append(BotMenuNode(title: start == 0 ? "Color" : "", kind: .palette(Array(swatches[start..<min(start + 6, swatches.count)]))))
        }
        palette.append(.action("No Color", "circle.slash", checked: session.color == nil) { [weak self] in self?.setColor(session, nil) })
        let more: [BotMenuNode] = [
            BotMenuNode(title: "", kind: .inline(palette)),
            .action(Self.exportTitle, "square.and.arrow.down") { [weak self] in self?.exportJSON(session) },
            .action("Copy Chat ID", "doc.on.doc") { [weak self] in self?.copyID(session) },
        ]
        let shortcut = BotChatsUnder.shortcutNode(session, services: services)
        let main: [BotMenuNode] = [shortcut].compactMap { $0 } + [
            .action("Rename…", "pencil") { [weak self] in self?.rename(session) },
            .action("Branch in New Chat", "arrow.triangle.branch") { [weak self] in self?.branch(session) },
            FavoritesPinAction.sessionNode(session, from: host),
        ] + (store?.project(of: session).map { project in
            [BotMenuNode.action("New Chat in \(project.label)", "square.and.pencil") { [weak self] in
                self?.newChat(profile: session.profile, folder: project.root)
            }]
        } ?? []) + [
            BotMenuNode(title: "Move to Project", image: "folder", kind: .submenu(moveNodes(for: session))),
            BotMenuNode(title: "More", image: "ellipsis.circle", kind: .submenu(more)),
        ]
        // [manual-order] Sort By Manual: the chat's place in its group, without the drag (VoiceOver, Switch Control).
        // [pinned-in-project] Opened on a pinned chat's row in its project card, they move it there, not in Pinned.
        let item = row ?? SessionListPipeline.key(session)
        let order: [BotMenuNode] = host?.chatMoves(item).map { moves in [
            .action("Move Up", "arrow.up", disabled: !moves.up) { [weak self] in self?.host?.moveChat(item, by: -1) },
            .action("Move Down", "arrow.down", disabled: !moves.down) { [weak self] in self?.host?.moveChat(item, by: 1) },
        ] } ?? []
        let end: [BotMenuNode] = prMarkNodes(for: session) + [
            .action(archiveWords(session).menu, archiveWords(session).symbol) { [weak self] in
                self?.archive(session)
            },
        ]
        // [safer-deletes] Delete Chat alone at the end, as the Bots, Jobs and Kanban menus keep Delete (owner 2026-11-03:
        // "destructive actions sit next to everyday ones").
        let delete: [BotMenuNode] = [
            .action("Delete Chat", "trash", destructive: true) { [weak self] in self?.confirmDelete(session) },
        ]
        return [
            BotMenuNode(title: "", kind: .tiles(tiles)),
            BotMenuNode(title: "", kind: .inline(main)),
        ] + (order.isEmpty ? [] : [BotMenuNode(title: "", kind: .inline(order))]) + [
            BotMenuNode(title: "", kind: .inline(end)),
            BotMenuNode(title: "", destructive: true, kind: .inline(delete)),
        ]
    }

    // [mac-audit K] Owner 2026-11-02: the Mac's menus say each action one way: "Mark as Read" as the chat's ⋯, the
    // Chat menu and the Bots menus do (the Mac's menu shows rows, not the phone's narrow tiles), and "Export Chat…" as
    // the ⋯ and the Chat menu do (a save panel follows).
    #if targetEnvironment(macCatalyst)
    private static func readTitle(unread: Bool) -> String { unread ? "Mark as Read" : "Mark as Unread" }
    private static let exportTitle = "Export Chat…"
    #else
    private static func readTitle(unread: Bool) -> String { unread ? "Mark Read" : "Mark Unread" }
    private static let exportTitle = "Export Chat"
    #endif

    /// Move to Project ›: the profile's projects (read as the submenu opens), each but the chat's own, then New Project….
    private func moveNodes(for session: SessionSummary) -> [BotMenuNode] {
        let newProject = BotMenuNode.action("New Project…", "folder.badge.plus") { [weak self] in self?.newProjectThenMove(session) }
        let load: @MainActor (@escaping @MainActor ([BotMenuNode]) -> Void) -> Void = { [weak self] completion in
            guard let self, let store = self.store else { completion([newProject]); return }
            Task { @MainActor in
                _ = try? await store.projects(for: session.profile)
                let targets = store.moveTargets(for: session) ?? []
                let rows = targets.map { project in
                    BotMenuNode.action(project.label, nil) { [weak self] in self?.move(session, to: project) }
                }
                completion(rows.isEmpty ? [newProject] : rows + [BotMenuNode(title: "", kind: .inline([newProject]))])
            }
        }
        return [BotMenuNode(title: "", kind: .deferred(load))]
    }

    func uiMenu(for session: SessionSummary, row: String? = nil) -> UIMenu {
        BotMenuNode.uiMenu(menuNodes(for: session, row: row), title: SessionRowView.title(session)).menu
    }

    /// `row`: the list item held (see `menuNodes(for:row:)`).
    func contextMenu(for session: SessionSummary, key: String, row: String? = nil) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: key as NSString, previewProvider: nil) { [weak self] _ in
            self?.lentAnchor = nil
            return self?.uiMenu(for: session, row: row)
        }
    }

    /// [Mac UI check 2026-11-13] A chat's menu shown away from this list (the Mac sidebar's chat under its bot): the
    /// same actions, and a sheet one of them opens (Share…) points at `anchor` while the list's own row isn't on screen.
    func uiMenu(for session: SessionSummary, anchor: UIView) -> UIMenu {
        lentAnchor = anchor
        return uiMenu(for: session)
    }

    /// The row a menu shown elsewhere came from (`uiMenu(for:anchor:)`).
    private weak var lentAnchor: UIView?

    /// Where a sheet for row `key` points: its cell while on screen, else the lent row, else the page.
    private func anchor(forKey key: String) -> UIView? {
        guard let host else { return nil }
        if let cell = host.cell(forKey: key), cell.window != nil { return cell }
        if let lentAnchor, lentAnchor.window != nil { return lentAnchor }
        return (surface ?? host).view
    }

    static func uiColor(_ index: Int) -> UIColor {
        let rgb = SessionColors.rgb(index)
        return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    // MARK: - Swipes

    func leadingActions(for session: SessionSummary, quickPR: UIContextualAction? = nil) -> UISwipeActionsConfiguration {
        let read = UIContextualAction(style: .normal, title: session.unread ? "Read" : "Unread") { [weak self] _, _, done in
            self?.toggleRead(session)
            done(true)
        }
        read.image = UIImage(systemName: session.unread ? "envelope.open.fill" : "envelope.badge.fill")
        read.backgroundColor = HQPalette.tint
        read.accessibilityLabel = session.unread ? "Mark as Read" : "Mark as Unread"
        let pin = UIContextualAction(style: .normal, title: Self.pinned(session) ? "Unpin" : "Pin") { [weak self] _, _, done in
            self?.pin(session)
            done(true)
        }
        pin.image = UIImage(systemName: Self.pinned(session) ? "pin.slash.fill" : "pin.fill")
        pin.backgroundColor = .systemOrange
        var list = [read, pin]
        if let quickPR { list.insert(quickPR, at: 0) }
        let actions = UISwipeActionsConfiguration(actions: list)
        actions.performsFirstActionWithFullSwipe = quickPR == nil
        return actions
    }

    /// Trailing, outermost first for UIKit: Archive, Delete, More. A full swipe archives (UX study #66), as Mail's does.
    func trailingActions(for session: SessionSummary, key: String) -> UISwipeActionsConfiguration {
        let delete = UIContextualAction(style: .normal, title: "Delete") { [weak self] _, _, done in
            done(true)
            self?.confirmDelete(session)
        }
        delete.image = UIImage(systemName: "trash.fill")
        delete.backgroundColor = .systemRed
        let archive = UIContextualAction(style: .normal, title: archiveWords(session).swipe) { [weak self] _, _, done in
            done(true)
            self?.archive(session)
        }
        archive.image = UIImage(systemName: archiveWords(session).symbol + ".fill")
        archive.backgroundColor = Theme.inkSwipe(.systemIndigo)   // [paper-ink]
        let more = UIContextualAction(style: .normal, title: "More") { [weak self] _, _, done in
            done(true)
            RowMoreMenu.afterSwipe { self?.openMenu(key: key) }
        }
        more.image = UIImage(systemName: "ellipsis.circle.fill")
        more.backgroundColor = .systemGray
        // UX study #66: Archive outermost, and the full swipe (it asks nothing and offers Undo, as Mail); Delete inside it.
        let actions = UISwipeActionsConfiguration(actions: [archive, delete, more])
        actions.performsFirstActionWithFullSwipe = true
        return actions
    }

    /// The More swipe: the long press's menu as a pull-down from the row's end (`RowMoreMenu`); a row not on screen gets
    /// it as an action sheet, submenus as sheets of their own.
    func openMenu(key: String) {
        guard let session = host?.session(forKey: key) else { return }
        if RowMoreMenu.open(uiMenu(for: session), from: host?.cell(forKey: key)) { return }
        presentSheet(title: SessionRowView.title(session), nodes: menuNodes(for: session), key: key)
    }

    private func presentSheet(title: String?, nodes: [BotMenuNode], key: String) {
        guard let host, let top = FailureAlert.topmost(host) else { return }
        // A submenu read on open (Move to Project ›): read it, then show it.
        if nodes.count == 1, case .deferred(let load) = nodes[0].kind {
            load { [weak self] children in self?.presentSheet(title: title, nodes: children, key: key) }
            return
        }
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        sheet.view.accessibilityIdentifier = "session-more-sheet"
        func add(_ nodes: [BotMenuNode]) {
            for node in nodes where !node.disabled {
                switch node.kind {
                case .action(let run):
                    let name = node.checked ? "\(node.title) ✓" : node.title
                    sheet.addAction(UIAlertAction(title: name, style: node.destructive ? .destructive : .default) { _ in run() })
                case .submenu(let children):
                    sheet.addAction(UIAlertAction(title: node.title + "…", style: .default) { [weak self] _ in
                        self?.presentSheet(title: node.title, nodes: children, key: key)
                    })
                case .inline(let children), .tiles(let children), .palette(let children):
                    add(children)
                case .deferred:
                    break
                }
            }
        }
        add(nodes)
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            let cell = host.cell(forKey: key)
            let source = cell ?? (surface ?? host).view
            popover.sourceView = source
            if let source { popover.sourceRect = source.bounds }
            if cell == nil { popover.permittedArrowDirections = [] }
        }
        top.present(sheet, animated: true)
    }

    // MARK: - Compose (`S/stress-c-compose.ts`, `S/phone-new-chat.ts`)

    /// The bar's Compose (and the empty page's New Chat, ⇧⌘N): the one New Chat sheet. The bot is a lit pill (the
    /// picked chip's, else the bot the sheet started with last); a tap on a project's row starts the chat there
    /// (Start Chat for none, New Project… last). Tester 2026-11-10; owner: "There should be one go-to".
    /// Filter › Project narrowed to one project: the new chat starts in it, with no sheet.
    /// `asksProject`: a caller that is the go-to. Without it a `profile` starts its chat in no project at once (⌘N, a
    /// Home card's New Chat row); so does a picked chip with Settings › Chat › New Chat Asks for a Project off.
    func compose(profile: String? = nil, asksProject: Bool = false) {
        if let only = store?.effectiveProjects, only.count == 1, let key = only.first, key != SessionProjects.homeKey {
            newChat(inProject: key, profile: profile)
            return
        }
        if let profile, !(asksProject && NewChatProjectChoice.isOn) { newChat(profile: profile); return }
        store?.loadProjects()
        // [own-folder] Saved projects, then the folders Hermes found that are no bot's own working folder.
        presentNewChat(projects: store?.newChatEntries() ?? [], picked: profile)
    }

    /// The New Chat sheet. The sheet itself is dismissed, and the pick delivered once, as `chooseBot` does.
    private func presentNewChat(projects: [SessionProjectEntry], picked: String?) {
        // Hidden bots are left out, as the chips leave them out (Hermes and the picked chip's bot are always offered).
        let bots = services.bots.filter { !$0.hidden || $0.id == "default" || $0.id == picked }
        let ordered = bots.filter { $0.id == "default" } + bots.filter { $0.id != "default" }
        guard let host, !ordered.isEmpty else { newChat(profile: picked ?? "default"); return }
        final class Box { weak var sheet: UINavigationController?; var delivered = false; var bot = "" }
        let box = Box()
        let start: (String, String?) -> Void = { [weak self] bot, project in
            guard !box.delivered else { return }
            box.delivered = true
            // New Project…: the New Project alert for the lit bot, then the chat starts in the project made.
            if project == NewChatSheetView.newProjectTag {
                NewChatLast.note(bot: bot, project: NewChatLast.project(for: bot).flatMap { $0 == NewChatLast.none ? nil : $0 })
                self?.newProject(profile: bot, startsChat: true)
                return
            }
            NewChatLast.note(bot: bot, project: project)
            if let project { self?.newChat(inProject: project, profile: bot) } else { self?.newChat(profile: bot) }
        }
        let opensOn = NewChatLast.opensOn(picked: picked, last: NewChatLast.bot, among: ordered.map(\.id))
        let pick: (String, String?) -> Void = { bot, project in
            guard let sheet = box.sheet, sheet.presentingViewController != nil else { start(bot, project); return }
            sheet.dismiss(animated: true) { start(bot, project) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { start(bot, project) }
        }
        // A bot's recent projects: the ones the sheet started for it, then the ones its newest chats are in.
        let chats = (store?.sessions ?? []).sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        let byProfile = store?.projectsByProfile ?? [:]
        // [favorite-in-new-chat] Favorites lead the short list (in the order they were starred), ahead of the recent ones.
        let favorites = store?.device.favoriteProjects ?? []
        let recent: (String) -> [String] = { bot in
            favorites + NewChatLast.recents(for: bot) + chats.filter { $0.profile == bot }.map {
                SessionProjects.key(cwd: $0.cwd, profile: bot, projectsByProfile: byProfile)
            }
        }
        // All Projects: every project, A to Z, on a page of its own in the sheet (which goes to its full height).
        let showAll: (String) -> Void = { bot in
            guard let sheet = box.sheet else { return }
            let name = ordered.first { $0.id == bot }?.name ?? "this bot"
            let all = NewChatKeysPage(rootView: AnyView(HQScaledRoot(NewChatAllProjectsView(projects: projects, botName: name,
                                                                                           last: NewChatLast.project(for: bot)) { pick(bot, $0) })))
            let allTitle = NewChatSheetView.allTitle(projects)
            // [Mac UI check 2026-11-13] C2: Escape here goes back one step to the sheet's first page, not out of the sheet.
            all.onEscape = { [weak all] in all?.navigationController?.popViewController(animated: true) }
            all.view.backgroundColor = HQPalette.sheetPage
            all.title = allTitle
            all.navigationItem.largeTitleDisplayMode = .never
            sheet.sheetPresentationController?.animateChanges { sheet.sheetPresentationController?.selectedDetentIdentifier = .large }
            sheet.pushViewController(all, animated: true)
        }
        box.bot = opensOn
        let view = NewChatSheetView(bots: ordered, projects: projects, bot: opensOn, recent: recent, start: pick, showAll: showAll,
                                    onBot: { box.bot = $0 })
        let page = NewChatKeysPage(rootView: AnyView(HQScaledRoot(view)))
        // [Mac UI check 2026-11-13] C2: Return starts the chat with the lit bot, as the Start Chat button at the foot does.
        page.onReturn = { pick(box.bot, nil) }
        page.view.backgroundColor = HQPalette.sheetPage   // [glass] the glass shows around the rows
        // The sheet is as tall as its rows (New Project…, the last one, is on show without a scroll) up to the full
        // height: the title bar, the pills, Start Chat and the heading, then the projects, All Projects and New Project….
        let listed = NewChatLast.shown(all: projects.map(\.key), recent: favorites)
        let folderHeading = projects.contains { $0.isFolder && listed.keys.contains($0.key) } ? 1 : 0   // [own-folder]
        let rows = CGFloat(listed.keys.count + (listed.more ? 1 : 0) + 1 + folderHeading)
        let fit = UISheetPresentationController.Detent.custom(identifier: .init("new-chat.fit")) { context in
            min(280 + rows * HQFont.scaled(44), context.maximumDetentValue)
        }
        // [ipad-polish] Two panes: a pop-over off the compose button, as tall as its rows.
        PanePopover.hangNext(on: host.composeAnchor?.bar, rect: host.composeAnchor?.rect, arrow: .up, from: host,
                             size: CGSize(width: 400, height: 640), bar: false)
        let sheet = ChatSheet.wrap(page, title: "New Chat", detents: [fit, .large()])
        box.sheet = sheet
        host.present(sheet, animated: true)
    }

    /// [cmd-n] ⌘N: a new chat with the bot Settings › Chat › New Chat (⌘N) names (Hermes unless changed), no chooser;
    /// Filter › Project on one project still starts it there. Ask Every Time is `compose()`, which ⇧⌘N always is.
    /// The project there (owner 2026-11-02) wins over Filter › Project; a project no bot has any more is left out.
    func composeWithKeyBot() {
        let profile = NewChatKeyBot.profile(among: services.bots.map(\.id))
        let keys = (store?.projectEntries() ?? []).map(\.key).filter { $0 != SessionProjects.homeKey }
        if let project = NewChatKeyBot.project(among: keys) {
            newChat(inProject: project, profile: profile)   // Ask Every Time: Choose a Bot, then the chat in the project
            return
        }
        compose(profile: profile)
    }

    /// [cmd-n] ⌥⌘N (New Chat Here): a new chat with the open chat's bot, in the project that holds its folder (Home when
    /// none does). Owner 2026-11-02: "Any others we should have?"
    func newChat(like chat: LiveChatSession) {
        let profile = chat.profile.isEmpty ? "default" : chat.profile
        let key = store.map { SessionProjects.key(cwd: chat.workingDirectory, profile: profile, projectsByProfile: $0.projectsByProfile) }
            ?? SessionProjects.homeKey
        if key == SessionProjects.homeKey { newChat(profile: profile) } else { newChat(inProject: key, profile: profile) }
    }

    /// A project's New Chat (its header's +, Compose with Filter › Project on one project): a new chat in the
    /// project's folder, with the picked chip's bot, else Choose a Bot (every bot). A bot without the project is given
    /// it first (same name and folder), so the chat lists under the project rather than under Home.
    /// [project-default-bot] With no bot picked the project's default bot starts the chat at once (`ProjectDefaultBot`);
    /// `asks` (New Chat With…, a card's Other Bots…) always opens the chooser.
    func newChat(inProject key: String, profile: String? = nil, asks: Bool = false) {
        guard let store else { return }
        let holders = store.projectHolders(key: key)
        let label = holders.first?.project.label ?? store.projectEntries().first { $0.key == key }?.label
            ?? (key as NSString).lastPathComponent
        // [project-new-chat-model] Project Settings › New Chats: the model and reasoning the chat starts with (read as
        // the chat starts, so a choice made a moment ago counts); nothing chosen adds nothing to `session.create`.
        let start: (String) -> Void = { [weak self] profile in
            let chosen = self?.store?.projectNewChat(key).createParams ?? [:]
            if let held = holders.first(where: { $0.profile == profile }) {
                self?.newChat(profile: profile, folder: held.project.root, start: chosen)
            } else if !holders.isEmpty, holders.allSatisfy({ $0.project.isAuto == true }) {
                // [own-folder] A folder Hermes found, saved by nobody: the chat starts there and no project is made.
                self?.newChat(profile: profile, folder: key, start: chosen)
            } else {
                self?.addProjectThenChat(profile: profile, name: label, folder: key, start: chosen)
            }
        }
        // [sessions-ux] The chooser says which project the chat starts in, the project's own bots first (it read
        // "Choose a Bot" over every bot, Hermes first, with no word of the project).
        if let profile { start(profile); return }
        let usual = projectDefaultBot(key: key)
        if !asks, let usual { start(usual); return }
        chooseBot(project: (label, holders.map(\.profile)), usual: (usual, { [weak self] bot in
            self?.store?.setProjectBotChoice(key, bot)
        }), start)
    }

    /// [project-default-bot] The bot a project's New Chat starts with; nil asks.
    func projectDefaultBot(key: String) -> String? {
        guard let store else { return nil }
        let bots = services.bots
        let own = store.projectHolders(key: key).map(\.profile).filter { id in
            bots.contains { $0.id == id && (!$0.hidden || id == "default") }
        }
        return ProjectDefaultBot.resolve(stored: store.projectBotChoice(key), own: own, bots: bots.map(\.id))
    }

    /// [project-default-bot] The bots a project's Default Bot menu offers: Hermes first, hidden ones left out (the one
    /// chosen stays).
    func projectBotChoices(key: String) -> [(id: String, name: String)] {
        let usual = projectDefaultBot(key: key)
        let bots = services.bots.filter { !$0.hidden || $0.id == "default" || $0.id == usual }
        return (bots.filter { $0.id == "default" } + bots.filter { $0.id != "default" }).map { ($0.id, $0.name) }
    }

    /// A bot without the project: `projects.create` for it with the project's name and folder, then the new chat there.
    /// A failure is said, not hidden: the chat never starts outside the project.
    private func addProjectThenChat(profile: String, name: String, folder: String, start: [String: JSONValue] = [:]) {
        guard let store else { return }
        let hud = slowHUD("Adding Project…")
        Task { [weak self] in
            defer { hud() }
            do {
                let project = try await store.createProject(name: name, folder: folder, profile: profile)
                hud()
                store.loadProjects(force: true, also: [profile])
                self?.newChat(profile: profile, folder: project.root, start: start)
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                let reason = SessionActionText.reason(error)
                let retry: (() -> Void)? = reason == SessionActionText.projectsUnsupported ? nil : { [weak self] in
                    self?.addProjectThenChat(profile: profile, name: name, folder: folder, start: start)
                }
                FailureAlert.present(title: "Couldn’t Start a New Chat", reason: reason, detail: SessionActionText.detail(error),
                                     from: self.host, retry: retry)
            }
        }
    }

    /// One bot: it is the answer. More: Choose a Bot first (Hermes first, then the Bots list's order); hidden bots left
    /// out, as the chips leave them out (Hermes is always offered).
    /// `project`: a project's New Chat: its name (the sheet is "New Chat", its first heading "In <project>") and the
    /// bots that have it, which are listed first; the others follow under "Other Bots".
    /// [project-default-bot] `usual`: the project's default bot (its row says Default) and what a hold on a row's Make
    /// Default calls.
    func chooseBot(project: (name: String, bots: [String])? = nil,
                   usual: (bot: String?, set: (String) -> Void)? = nil, _ picked: @escaping (String) -> Void) {
        let bots = services.bots.filter { !$0.hidden || $0.id == "default" || project?.bots.contains($0.id) == true }
        guard bots.count > 1, let host else { picked(bots.first?.id ?? "default"); return }
        let ordered = bots.filter { $0.id == "default" } + bots.filter { $0.id != "default" }
        var groups = [ChooseBotView.Group(title: nil, bots: ordered)]
        if let project {
            let own = ordered.filter { project.bots.contains($0.id) }, others = ordered.filter { !project.bots.contains($0.id) }
            groups = own.isEmpty ? [.init(title: "In \(project.name)", bots: ordered)]
                : [.init(title: "In \(project.name)", bots: own)] + (others.isEmpty ? [] : [.init(title: "Other Bots", bots: others)])
        }
        // The sheet itself is dismissed, not `host.presentedViewController` (which can be nil or another controller: a
        // search the page keeps in its presentation context, a sheet still arriving), and the pick is delivered once,
        // even when UIKit drops the dismissal's completion (a tap during the sheet's own animation).
        final class Box { weak var sheet: UINavigationController?; var delivered = false }
        let box = Box()
        let deliver: (String) -> Void = { id in
            guard !box.delivered else { return }
            box.delivered = true
            picked(id)
        }
        // [ui-sizing] The scaled root, as every hosted page: its bot names stayed 17 pt beside 75 pt faces at 150 %.
        let picker = UIHostingController(rootView: HQScaledRoot(ChooseBotView(groups: groups, usual: usual?.bot,
                                                                                  project: project?.name, setUsual: usual?.set) { bot in
            guard let sheet = box.sheet, sheet.presentingViewController != nil else { deliver(bot.id); return }
            sheet.dismiss(animated: true) { deliver(bot.id) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { deliver(bot.id) }
        }))
        picker.view.backgroundColor = HQPalette.sheetPage   // [glass] the glass shows around the rows
        let chooser = ChatSheet.wrap(picker, title: project == nil ? "Choose a Bot" : "New Chat")
        box.sheet = chooser
        host.present(chooser, animated: true)
    }

    /// A new chat in `profile`, started the way the Bots tab starts one (`AppModel.newChat(for:)`): the chat opens at
    /// once with no stored id and makes its session (`session.create`) as it opens. A gateway mints the session live
    /// and writes its row only with the first prompt, so a stored id taken here and opened as a listed chat names a
    /// row that does not exist yet.
    /// `folder`: a project's root; the chat starts there.
    /// [project-new-chat-model] `start`: what the project's settings add to `session.create`.
    func newChat(profile: String, folder: String? = nil, start: [String: JSONValue] = [:]) {
        Haptics.play(.soft)
        if let starter = services as? BotChatStarting, let bot = services.bots.first(where: { $0.id == profile }) {
            let chat = start.isEmpty ? starter.newChat(for: bot, folder: folder) : starter.newChat(for: bot, folder: folder, start: start)
            host?.openChat(model: chat, fresh: true)
            return
        }
        guard let store else { return }
        run("Couldn’t Start a New Chat", {
            let made = try await store.newChat(profile: profile, folder: folder, start: start)
            let summary = SessionSummary(id: made.storedId, profile: made.profile, title: "New Chat", preview: nil, lastActive: Date(),
                                         source: nil, unread: false, isRunning: false)
            self.host?.openChat(summary, fresh: true)
        })
    }

    // MARK: - Actions

    /// Runs a write; a failure shows the "Couldn’t …" alert (Try Again runs `retry`, default the same write).
    private func run(_ title: String, owner: String? = nil, _ work: @escaping () async throws -> Void, done: (() -> Void)? = nil,
                     failed: (() -> Void)? = nil, retry: (() -> Void)? = nil) {
        Task { [weak self] in
            do {
                try await work()
                done?()
            } catch is CancellationError {
            } catch {
                failed?()
                guard let self else { return }
                FailureAlert.present(title: title, reason: SessionActionText.reason(error, owner: owner), detail: SessionActionText.detail(error), from: self.host) { [weak self] in
                    if let retry { retry() } else { self?.run(title, owner: owner, work, done: done, failed: failed) }
                }
            }
        }
    }

    /// [pr-manage] On a coding project's page: the owner's own label on the chat's code changes (owner 2026-11-19:
    /// "How do I mark a PR as closed"). Mark as Closed where nothing is merged; Reopen takes the mark back. A label
    /// only, so it says nothing of branches. Not shown on a gateway that takes no marks.
    func prMarkNodes(for session: SessionSummary) -> [BotMenuNode] {
        guard onProjectPage, let store, store.prManage, store.isCodingSession(profile: session.profile, cwd: session.cwd) else { return [] }
        let status = store.pullRequest(profile: session.profile, id: session.id) ?? session.pullRequest
        if status?.manual == true {
            return [BotMenuNode(title: "Reopen", image: "arrow.uturn.backward.circle", identifier: "sessions.row.prReopen",
                                kind: .action({ [weak self] in self?.markPRClosed(session, false) }))]
        }
        // [pr-multi] An add-on that lists items (0.9.75) labels an open pull request too; an older one doesn't.
        let marks: Set<SessionPRStatus.State> = status?.items != nil ? [.draft, .open, .none, .unknown] : [.draft, .none, .unknown]
        guard let state = status?.state, marks.contains(state) else { return [] }
        return [BotMenuNode(title: "Mark as Closed", image: "xmark.circle", identifier: "sessions.row.prClose",
                            kind: .action({ [weak self] in self?.markPRClosed(session, true) }))]
    }

    func markPRClosed(_ session: SessionSummary, _ closed: Bool) {
        guard let store else { return }
        Haptics.play(.selection)
        run(closed ? "Couldn’t Mark as Closed" : "Couldn’t Reopen", owner: session.owner) { try await store.setPRClosed(session, closed) }
    }

    /// [project-pins] Pinned as the row shows it: everywhere, or on this project's page alone.
    static func pinned(_ session: SessionSummary) -> Bool { session.pinned || session.projectPinned }

    func pin(_ session: SessionSummary) {
        guard let store else { return }
        // [project-pins] On a project's page: a chat pinned there alone unpins there; with Pins Stay in Project on, an
        // unpinned chat pins there alone. A chat pinned everywhere still unpins everywhere (it says so wherever it is).
        if onProjectPage, let key = host?.projectPageKey {
            if session.projectPinned || (!session.pinned && store.isProjectPinsLocal(key)) {
                Haptics.play(.selection)
                store.setProjectPinned(session, project: key, !session.projectPinned)
                return
            }
        }
        Haptics.play(.selection)
        let pinned = !session.pinned
        run(pinned ? "Couldn’t Pin Chat" : "Couldn’t Unpin Chat", owner: session.owner) { try await store.setPinned(session, pinned) }
    }

    func toggleRead(_ session: SessionSummary) {
        Haptics.play(.selection)
        store?.setUnread(session, !session.unread)
    }

    /// [three-piles] On a project's page an archived chat is in its Done pile, so there the verb is Done (and Not Done
    /// to take it back out); everywhere else it is Archive and Unarchive. The same write either way.
    var onProjectPage: Bool { host?.isProjectPage == true && surface === host }
    func archiveWords(_ session: SessionSummary) -> (menu: String, swipe: String, symbol: String) {
        if onProjectPage {
            return session.archived ? ("Mark as Not Done", "Not Done", "arrow.uturn.backward.circle") : ("Mark as Done", "Done", "checkmark.circle")
        }
        return session.archived ? ("Unarchive", "Unarchive", "tray.and.arrow.up") : ("Archive", "Archive", "archivebox")
    }

    /// Archive asks nothing: the row goes and "Archived “<title>” · Undo" shows at the tap, with Filter › Archived as
    /// the way back drawn under it (not while Show › Archived is on: the row comes back marked). An Undo tapped before
    /// the gateway answered waits for the archive, then unarchives. On an archived row the same verb unarchives (no
    /// pill: "Unarchived" shows once the gateway has it).
    func archive(_ session: SessionSummary) {
        guard let store else { return }
        Haptics.play(.selection)
        if session.archived {
            run("Couldn’t Unarchive Chat", owner: session.owner, { try await store.setArchived(session, false) },
                done: { [weak self] in MenusHUD.show(self?.onProjectPage == true ? "Back in Active" : "Unarchived", in: self?.surface?.view) },
                retry: { [weak self] in self?.archive(session) })
            return
        }
        let archiving = Task { try await store.setArchived(session, true) }
        let page = onProjectPage
        let pill = store.readOnlyGateway ? nil : UndoPill.show(label: "\(page ? "Done" : "Archived") “\(SessionRowView.title(session))”",
                                                                    wayBack: page ? SessionActionText.doneWayBack : SessionActionText.archivedWayBack,
                                                                    showsWayBack: page || !store.view.showArchived, in: surface) { [weak self] in
            Task { [weak self] in
                guard (try? await archiving.value) != nil else { return }     // it failed: the row is back already
                var archived = session
                archived.archived = true
                self?.run("Couldn’t Unarchive Chat", owner: session.owner) { try await store.setArchived(archived, false) }
            }
        }
        Task { [weak self] in
            do {
                try await archiving.value
                MainTabController.current?.leaveDetailChat(profile: session.profile, sessionId: session.id)   // [m9/ipad]
            } catch {
                pill?.dismiss(animated: true)
                guard let self else { return }
                FailureAlert.present(title: "Couldn’t Archive Chat", reason: SessionActionText.reason(error, owner: session.owner), detail: SessionActionText.detail(error), from: self.host) { [weak self] in
                    self?.archive(session)
                }
            }
        }
    }

    /// Delete always asks, as an action sheet from the row; then the row dims with a spinner and closes up when the
    /// gateway has deleted it (a failure undims it and says why).
    func confirmDelete(_ session: SessionSummary) {
        guard let host else { return }
        let key = SessionsViewController.key(session)
        TextPrompt.confirm(title: "Delete “\(SessionRowView.title(session))”?", message: SessionActionText.deleteMessage, action: "Delete Chat",
                           style: .actionSheet, from: host, sourceView: host.cell(forKey: key)) { [weak self] in
            self?.delete(session)
        }
    }

    private func delete(_ session: SessionSummary) {
        guard let store else { return }
        let key = SessionsViewController.key(session)
        host?.setBusy(key, true)
        run("Couldn’t Delete Chat", owner: session.owner, { try await store.delete(session) },
            done: { [weak self] in
                Haptics.play(.success)
                self?.host?.setBusy(key, false)
                MainTabController.current?.leaveDetailChat(profile: session.profile, sessionId: session.id)   // [m9/ipad]
            },
            failed: { [weak self] in self?.host?.setBusy(key, false) },
            retry: { [weak self] in self?.delete(session) })
    }

    /// Rename… : a prompt with the title, Save off until it changes.
    func rename(_ session: SessionSummary) {
        guard let host, let store else { return }
        TextPrompt.present(title: "Rename Chat", text: session.title, placeholder: "Untitled Chat", action: "Save", requireChange: true,
                           identifier: "session.rename", selectText: true, from: host) { [weak self] text in
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard typed != session.title.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            self?.run("Couldn’t Rename Chat", owner: session.owner, { try await store.rename(session, to: typed) }, done: {
                Haptics.play(.success)
            })
        }
    }

    /// A project header's hold › Rename Project…: the new name goes to every bot that holds the project's folder.
    func renameProject(key: String, title: String) {
        guard let host, let store else { return }
        TextPrompt.present(title: "Rename Project", text: title, placeholder: "Project Name", action: "Save", requireChange: true,
                           identifier: "project.rename", selectText: true, from: host) { [weak self] text in
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty, typed != title.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            self?.run("Couldn’t Rename Project", { try await store.renameProject(key: key, to: typed) }, done: {
                Haptics.play(.success)
                store.loadProjects(force: true)
            })
        }
    }

    /// A project header's hold › Delete Project…: asked first; the chats and the folder are kept.
    func deleteProject(key: String, title: String, showFolder: Bool = false) {
        guard let host, let store else { return }
        let folder = showFolder && !key.hasPrefix("id:") ? "Folder: \(key)\n\n" : ""
        let scope = showFolder ? "It is removed for every bot that has it.\n\n" : ""
        TextPrompt.confirm(title: "Delete “\(title)”?",
                           message: folder + scope + "Its chats and its folder are kept. Chats still in the folder will show under the folder’s name instead.",
                           action: "Delete Project", from: host) { [weak self] in
            self?.run("Couldn’t Delete Project", { try await store.deleteProject(key: key) }, done: { [weak self] in
                Haptics.play(.success)
                MenusHUD.show("Deleted \(title)", in: self?.surface?.view)
                store.loadProjects(force: true)
            })
        }
    }

    func setColor(_ session: SessionSummary, _ color: Int?) {
        Haptics.play(.selection)
        store?.setColor(session, color)
    }

    func copyID(_ session: SessionSummary) {
        UIPasteboard.general.string = session.id
        #if DEBUG
        DebugHooks.recordText(session.id, as: "copy.txt")
        #endif
        Haptics.play(.success)
        MenusHUD.show("Copied", in: surface?.view)
    }

    func move(_ session: SessionSummary, to project: SessionProject) {
        guard let store else { return }
        run("Couldn’t Move Chat", { try await store.move(session, to: project) }) { [weak self] in
            Haptics.play(.success)
            MenusHUD.show("Moved to \(project.label)", in: self?.surface?.view)
        }
    }

    /// [drag-to-project] A chat dropped on a project's group (`key`, `SessionProjects.key`): its bot's project there, and a
    /// bot without one is given it first (same name and folder), as a project's New Chat does, so the chat lists under
    /// the project it was dropped on.
    func move(_ session: SessionSummary, toProject key: String, label: String) {
        guard let store else { return }
        if let held = store.projectHolders(key: key).first(where: { $0.profile == session.profile }) {
            move(session, to: held.project)
            return
        }
        run("Couldn’t Move Chat", {
            let project = try await store.createProject(name: label, folder: key, profile: session.profile)
            store.loadProjects(force: true, also: [session.profile])
            try await store.move(session, to: project)
        }, done: { [weak self] in
            Haptics.play(.success)
            MenusHUD.show("Moved to \(label)", in: self?.surface?.view)
        })
    }

    /// Move to Project › New Project…: a name and a folder on the gateway's computer (a project holds chats by
    /// folder), then the chat moves into it.
    func newProjectThenMove(_ session: SessionSummary) {
        guard let store else { return }
        askNewProject(profile: session.profile) { [weak self] name, folder in
            self?.run("Couldn’t Move Chat", {
                let project = try await store.createProject(name: name, folder: folder, profile: session.profile)
                try await store.move(session, to: project)
            }, done: { [weak self] in
                Haptics.play(.success)
                MenusHUD.show("Moved to \(name.trimmingCharacters(in: .whitespacesAndNewlines))", in: self?.surface?.view)
            })
        }
    }

    /// [sessions-m9] Filter › Project › New Project… (docs/spec/3x-sessions.md §8): the same alert; the project is the
    /// picked chip's bot's, else (with more than one bot) the bot chosen first. It is only created, never turned on as
    /// a filter.
    func newProjectFromFilter(profile: String?) {
        if let profile { newProject(profile: profile) } else { chooseBot { [weak self] profile in self?.newProject(profile: profile) } }
    }

    /// `name`, `folder`: what was typed before a failure (Try Again brings it back).
    /// `startsChat`: the New Chat sheet's New Project…: a new chat opens in the project once it is made.
    func newProject(profile: String, name: String = "", folder: String = "", startsChat: Bool = false) {
        guard let store else { return }
        askNewProject(profile: profile, name: name, folder: folder) { [weak self] name, folder in
            // A slow gateway: "Creating Project…" once the call has taken 400 ms, until it answers (30 s at most).
            let hud = self?.slowHUD("Creating Project…") ?? {}
            Task { [weak self] in
                defer { hud() }
                do {
                    let project = try await store.createProject(name: name, folder: folder, profile: profile)
                    hud()
                    // The bot it was made for is read again whether or not it owns a listed chat.
                    store.loadProjects(force: true, also: [profile])
                    if startsChat { self?.newChat(profile: profile, folder: project.root); return }
                    Haptics.play(.success)
                    MenusHUD.show("Created \(project.label)", in: self?.surface?.view)
                } catch is CancellationError {
                } catch {
                    guard let self else { return }
                    let reason = SessionActionText.reason(error)
                    // A gateway without projects cannot be asked again to any use.
                    let retry: (() -> Void)? = reason == SessionActionText.projectsUnsupported ? nil : { [weak self] in
                        self?.newProject(profile: profile, name: name, folder: folder, startsChat: startsChat)
                    }
                    FailureAlert.present(title: "Couldn’t Create Project", reason: reason, detail: SessionActionText.detail(error),
                                         from: self.host, retry: retry)
                }
            }
        }
    }

    /// The New Project alert: Create is off until the name has text. The folder is optional: left empty, the app makes
    /// one named after the project (its placeholder says where, as the name is typed).
    /// [new-project-folder] Choose Folder… browses `profile`'s folders on the gateway's computer and comes back here
    /// with the pick in Folder (and, with no name typed yet, the folder's own name in Name).
    private func askNewProject(profile: String, name: String = "", folder: String = "",
                               create made: @escaping (_ name: String, _ folder: String) -> Void) {
        guard let host = FailureAlert.topmost(host) else { return }
        let alert = UIAlertController(title: "New Project",
                                      message: "A project holds the chats in its folder on \(HostWord.phrase). Leave Folder empty to make a new one.",
                                      preferredStyle: .alert)
        func trimmed(_ field: UITextField?) -> String { (field?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func autoPlaceholder(_ name: String) -> String {
            name.isEmpty ? "Folder (optional)" : SessionProject.autoFolder(name: name)
        }
        alert.addTextField { field in
            field.placeholder = "Name"
            field.text = name
            field.autocapitalizationType = .words
            field.accessibilityIdentifier = "project.name"
        }
        alert.addTextField { field in
            field.placeholder = autoPlaceholder(name.trimmingCharacters(in: .whitespacesAndNewlines))
            field.text = folder
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.accessibilityIdentifier = "project.folder"
        }
        let create = UIAlertAction(title: "Create", style: .default) { [weak alert] _ in
            made(alert?.textFields?[0].text ?? "", alert?.textFields?[1].text ?? "")
        }
        create.isEnabled = !trimmed(alert.textFields?.first).isEmpty
        alert.textFields?.first?.addAction(UIAction { [weak alert, weak create] _ in
            let name = trimmed(alert?.textFields?.first)
            create?.isEnabled = !name.isEmpty
            alert?.textFields?.last?.placeholder = autoPlaceholder(name)
        }, for: .editingChanged)
        let browse = UIAlertAction(title: "Choose Folder…", style: .default) { [weak self, weak alert] _ in
            let typedName = alert?.textFields?.first?.text ?? "", typedFolder = alert?.textFields?.last?.text ?? ""
            self?.chooseProjectFolder(profile: profile, typed: typedFolder) { [weak self] picked in
                let named = typedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? picked.map(ProjectFolderWords.suggestedName(folder:)) ?? typedName : typedName
                self?.askNewProject(profile: profile, name: named, folder: picked ?? typedFolder, create: made)
            }
        }
        browse.accessibilityIdentifier = "project.choose-folder"
        alert.addAction(browse)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(create)
        alert.preferredAction = create
        host.present(alert, animated: true)
    }

    /// [new-project-folder] The folder browser, as a sheet. `done`: the picked folder, or nil when the sheet was
    /// closed without one. Delivered once, after the sheet has gone (the alert that follows needs a free presenter).
    private func chooseProjectFolder(profile: String, typed: String, done: @escaping (String?) -> Void) {
        guard let store, let host = FailureAlert.topmost(host) else { done(nil); return }
        let workspace = ChatWorkspace(client: store.client, profile: profile.isEmpty || profile == "default" ? nil : profile)
        final class Box { weak var sheet: UINavigationController?; var delivered = false; var picked: String? }
        let box = Box()
        // Whichever notices the sheet gone first (the dismissal's completion, the page's own disappearance, the
        // timer for a completion UIKit dropped) delivers the same answer: the pick, or nil for a plain close.
        let deliver: () -> Void = {
            guard !box.delivered else { return }
            box.delivered = true
            done(box.picked)
        }
        let picker = ProjectFolderPickerHost(rootView: ProjectFolderPickerView(
            browser: ProjectFolderBrowser(workspace: workspace, typed: typed)) { picked in
                Haptics.play(.selection)
                box.picked = picked
                guard let sheet = box.sheet, sheet.presentingViewController != nil else { deliver(); return }
                sheet.dismiss(animated: true) { deliver() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { deliver() }
            })
        picker.closed = deliver
        let sheet = ChatSheet.wrap(picker, title: "Choose Folder")
        box.sheet = sheet
        host.present(sheet, animated: true)
    }

    /// Branch in New Chat: the gateway copies the chat into a new one, which opens.
    func branch(_ session: SessionSummary) {
        guard let store else { return }
        let hud = slowHUD("Branching…")
        run("Couldn’t Branch Chat", {
            defer { hud() }
            let made = try await store.branch(session)
            var opened = session
            opened.id = made.storedId
            opened.profile = made.profile
            opened.unread = false
            opened.pinned = false
            opened.archived = false
            opened.color = nil
            opened.searchSnippet = nil
            opened.lastActive = Date()
            self.host?.openChat(opened)
        })
    }

    /// Share: the whole chat as text through the share sheet; "Preparing to Share…" once it takes over 400 ms.
    func share(_ session: SessionSummary) {
        guard let store, !sharing else { return }
        sharing = true
        let hud = slowHUD("Preparing to Share…")
        let bot = host?.ownerName(of: session) ?? "Hermes"
        Task { [weak self] in
            defer { self?.sharing = false }
            do {
                let text = try await store.transcriptText(session, botName: bot)
                hud()
                #if DEBUG
                DebugHooks.recordText(text, as: "share.txt")
                #endif
                self?.present(items: [TranscriptShareItem(text: text, title: session.title)], key: SessionsViewController.key(session))
            } catch {
                hud()
                guard let self else { return }
                FailureAlert.present(title: "Couldn’t Share Chat", reason: SessionActionText.reason(error), detail: SessionActionText.detail(error), from: self.host) { [weak self] in
                    self?.share(session)
                }
            }
        }
    }

    /// Export Chat: the stored chat as a .json file through the share sheet (Save to Files, AirDrop…).
    func exportJSON(_ session: SessionSummary) {
        guard let store else { return }
        let hud = slowHUD("Preparing Export…")
        run("Couldn’t Export Chat", {
            defer { hud() }
            let data = try await store.exportJSON(session)
            let folder = FileManager.default.temporaryDirectory.appending(path: "session-export", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: SessionActionText.exportFilename(sessionId: session.id, title: session.title))
            try data.write(to: url, options: .atomic)
            #if DEBUG
            DebugHooks.recordText(url.lastPathComponent + "\n" + (String(data: data, encoding: .utf8) ?? ""), as: "export.txt")
            #endif
            self.present(items: [url], key: SessionsViewController.key(session))
        })
    }

    private func present(items: [Any], key: String) {
        guard let host, let top = FailureAlert.topmost(host) else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = anchor(forKey: key)
        }
        top.present(sheet, animated: true)
    }

    /// A HUD that shows only when the work takes longer than 400 ms; the returned stop takes it down.
    private func slowHUD(_ text: String) -> () -> Void {
        let box = SlowHUDBox()
        let view = host?.view
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard !box.stopped else { return }
            box.shown = MenusHUD.show(text, symbol: nil, in: view, seconds: nil)
        }
        return {
            box.stopped = true
            MenusHUD.hide(box.shown)
        }
    }
}

private final class SlowHUDBox {
    var shown: UIView?
    var stopped = false
}

/// Choose a Bot: each bot's face and name (a project's New Chat with no bot picked, New Project… from the filter).
struct ChooseBotView: View {
    struct Group { var title: String?; var bots: [Bot] }
    var groups: [Group]
    /// [project-default-bot] The project's default bot: its row says Default. A hold on a row offers Make Default
    /// (`setUsual`), which leaves the sheet open.
    @State var usual: String? = nil
    var project: String? = nil
    var setUsual: ((String) -> Void)? = nil
    var pick: (Bot) -> Void

    var body: some View {
        List {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
            Section {
                ForEach(group.bots) { bot in
                    Button { pick(bot) } label: {
                        // [ui-sizing 2026-11-09] A name-only row: a 32 pt face in a 44 pt row (× UI Scale), not the Bots
                        // list's 50 pt face in a 58 pt row; four bots filled the half sheet on a 375 pt phone.
                        HStack(spacing: 12) {
                            HeadImage(raw: bot.head, profile: bot.id, size: HQFont.scaled(32), working: false)
                            Text(bot.name).foregroundStyle(Color.hqLabel)
                            Spacer(minLength: 0)
                            if usual == bot.id {
                                Text("Default").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                    .accessibilityIdentifier("choose-bot-default-mark")
                            }
                        }
                        .frame(minHeight: HQFont.scaled(44))
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("choose-bot-\(bot.id)")
                    .contextMenu {
                        if let setUsual, usual != bot.id {
                            Button {
                                Haptics.play(.selection)
                                usual = bot.id
                                setUsual(bot.id)
                            } label: {
                                Label(project.map { "Make Default for \($0)" } ?? "Make Default", systemImage: "checkmark.circle")
                            }
                            .accessibilityIdentifier("choose-bot-make-default")
                        }
                    }
                }
            } header: {
                if let title = group.title { Text(title).accessibilityIdentifier("choose-bot-heading") }
            }
            .hqSheetRows()
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
    }
}

/// Compose's New Chat sheet (owner 2026-11-10, "one go-to"; 2026-11-11, "without overwhelm"): the bots as pills, one
/// lit; under "In a project (optional)" the projects (all of them while there are few, else the lit bot's five most
/// recent and All Projects), then New Project…; Start Chat, the usual case, at the foot of the sheet. A tap on a pill
/// changes the bot; the button or a project's row starts the chat.
struct NewChatSheetView: View {
    /// The New Project… row (never a project's key, which is a folder path).
    static let newProjectTag = "\u{1F}new-project"
    var bots: [Bot]
    var projects: [SessionProjectEntry]
    @State var bot: String
    /// The lit bot's recent projects, newest first.
    var recent: (String) -> [String] = { _ in [] }
    /// `project`: nil (no project), a project's key, or `newProjectTag`.
    var start: (_ bot: String, _ project: String?) -> Void
    var showAll: (_ bot: String) -> Void = { _ in }
    /// The lit bot changed (the sheet's Return starts the chat with it).
    var onBot: (_ bot: String) -> Void = { _ in }

    private var faceSize: CGFloat { Theme.isDesktop ? HQFont.scaled(20) : HQFont.scaled(24) }
    private static let rowInsets = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
    /// The bot pills' room inside their card (owner 2026-11-22: 2pt left them pressed against the card's sides). The
    /// same 8 all round, so the pills sit centred with an even rim; on the phone it is the strip's content inset, so a
    /// scrolled pill still slides out under the card's edge.
    private static let pillInset = EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)

    private var botName: String { bots.first { $0.id == bot }?.name ?? "Hermes" }

    /// [own-folder] The row and the page that hold every entry: named for what they hold.
    static func allTitle(_ entries: [SessionProjectEntry]) -> String {
        entries.contains(where: \.isFolder) ? "All Projects and Folders" : "All Projects"
    }

    private func entryRow(_ key: String, last: String?) -> some View {
        Group {
            if let entry = projects.first(where: { $0.key == key }) {
                NewChatProjectRow(title: entry.label, last: NewChatLast.marks(stored: last, row: key)) { start(bot, key) }
                    .listRowInsets(Self.rowInsets)
                    .accessibilityIdentifier("new-chat-\(entry.isFolder ? "folder" : "project")-\(entry.label)")
            }
        }
    }

    private var newProjectRow: some View {
        Button { start(bot, Self.newProjectTag) } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.plus").frame(width: HQFont.scaled(24))
                Text("New Project…")
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.hqTintText)
            .frame(height: HQFont.scaled(44))
            .contentShape(Rectangle())
        }
        .listRowInsets(Self.rowInsets)
        .accessibilityIdentifier("new-chat-project-new")
    }

    @ViewBuilder private var botPills: some View {
        ForEach(bots) { item in
            SessionPill(caption: item.name, name: item.name, picked: bot == item.id,
                        identifier: "new-chat-bot-\(item.id)", hasFace: true) {
                bot = item.id
            } face: {
                HeadImage(raw: item.head, profile: item.id, size: faceSize, working: false)
            }
            .id(item.id)
        }
    }

    var body: some View {
        let listed = NewChatLast.shown(all: projects.map(\.key), recent: recent(bot))
        let last = NewChatLast.project(for: bot)
        // [own-folder] Saved projects under their heading; folders Hermes found (nobody saved them) under their own.
        let folderKeys = Set(projects.filter(\.isFolder).map(\.key))
        let shownProjects = listed.keys.filter { !folderKeys.contains($0) }
        let shownFolders = listed.keys.filter { folderKeys.contains($0) }
        let hasProjects = projects.count > folderKeys.count
        List {
            Section {
                if DeviceWord.isMac {
                    // Mac pass 2026-11-14: a plain mouse wheel can't move a sideways strip, so a bot past the sheet's
                    // edge (Finance, cut in half with five bots) was out of reach without a trackpad. On the Mac the
                    // pills wrap to another line, as the job editor's faces do (FEEL-LIST #32).
                    PagesFlowLayout(spacing: 8, lineSpacing: 8) { botPills }
                        .padding(Self.pillInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .hqDesktopBareRow()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) { botPills }
                                .padding(Self.pillInset)
                        }
                        .scrollIndicators(.hidden)
                        .onAppear { proxy.scrollTo(bot, anchor: .center) }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .hqDesktopBareRow()
                }
            } header: { HQSectionLabel { Text("Bot") } }
            let allRow = Button { showAll(bot) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder").foregroundStyle(Color.hqLabel3).frame(width: HQFont.scaled(24))
                    Text(Self.allTitle(projects)).foregroundStyle(Color.hqLabel2)
                    Spacer(minLength: 8)
                    Text("\(projects.count)").foregroundStyle(Color.hqLabel2)
                    Image(systemName: "chevron.right").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel3)
                }
                .frame(height: HQFont.scaled(44))
                .contentShape(Rectangle())
            }
            .listRowInsets(Self.rowInsets)
            .accessibilityIdentifier("new-chat-project-all")
            Section {
                ForEach(shownProjects, id: \.self) { entryRow($0, last: last) }
                if listed.more, shownFolders.isEmpty { allRow }
                // With no saved project the row that makes one stands in their place.
                if !hasProjects { newProjectRow }
            } header: { HQSectionLabel { Text("In a project ") + Text("(optional)").fontWeight(.regular) } }
            .hqSheetRows()
            if !shownFolders.isEmpty {
                Section {
                    ForEach(shownFolders, id: \.self) { entryRow($0, last: last) }
                    if listed.more { allRow }
                } header: { HQSectionLabel { Text("In a folder") } }
                .hqSheetRows()
            }
            if hasProjects {
                Section { newProjectRow }.hqSheetRows()
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, HQFont.scaled(44))
        .listSectionSpacing(.compact)
        .onChange(of: bot) { _, now in onBot(now) }
        // Start Chat stays at the foot of the sheet, under the thumb, however long the list is (owner 2026-11-11).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { start(bot, nil) } label: {
                Text("Start Chat")
                    .font(Font.hq(.body).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: HQFont.scaled(34))
            }
            .hqProminentButtonStyle()
            .buttonBorderShape(.capsule)
            .padding(.horizontal, ListGutter.side)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .accessibilityLabel("Start Chat with \(botName)")
            .accessibilityIdentifier("new-chat-start")
        }
    }
}

/// One project in the New Chat sheet: its name, and "Last used" on the one the lit bot started in last.
private struct NewChatProjectRow: View {
    var title: String
    var last: Bool
    /// The sheet keeps a name to one line (it is as tall as its rows); All Projects, which scrolls, gives it two.
    var lines = 1
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "folder").foregroundStyle(Color.hqLabel2).frame(width: HQFont.scaled(24))
                // A long name is cut in the middle, so two that start alike ("acme-platform-…-web", "…-api") still
                // read apart (owner 2026-11-11: "Test for very long project titles"). VoiceOver reads it whole.
                Text(title).foregroundStyle(Color.hqLabel).lineLimit(lines).truncationMode(.middle)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if last {
                    Text("Last used")
                        .font(Font.hq(.caption2).weight(.semibold))
                        .foregroundStyle(Color.hqTintText)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.hqTint.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .padding(.vertical, lines > 1 ? 6 : 0)
            .frame(minHeight: HQFont.scaled(44))
            .frame(height: lines > 1 ? nil : HQFont.scaled(44))
            .contentShape(Rectangle())
        }
    }
}

/// All Projects: every project A to Z with a search field; a tap starts the chat there with the sheet's lit bot.
struct NewChatAllProjectsView: View {
    var projects: [SessionProjectEntry]
    var botName: String
    var last: String?
    var start: (String) -> Void
    @State private var query = ""

    private var rows: [SessionProjectEntry] {
        let sorted = projects.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? sorted : sorted.filter { $0.label.localizedCaseInsensitiveContains(words) }
    }

    /// [own-folder] The list holds folders Hermes found as well as saved projects.
    private var mixed: Bool { projects.contains(where: \.isFolder) }

    private func row(_ entry: SessionProjectEntry) -> some View {
        NewChatProjectRow(title: entry.label, last: NewChatLast.marks(stored: last, row: entry.key), lines: 2) { start(entry.key) }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .accessibilityIdentifier("new-chat-all-\(entry.label)")
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.hqLabel2)
                    TextField(mixed ? "Search projects and folders" : "Search projects", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("new-chat-all-search")
                }
                .frame(height: HQFont.scaled(40))
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            }
            .hqSheetRows()
            // [own-folder] Saved projects, then the folders Hermes found, each A to Z under its own heading.
            let saved = rows.filter { !$0.isFolder }, folders = rows.filter(\.isFolder)
            if !saved.isEmpty || folders.isEmpty {
                Section {
                    ForEach(saved) { row($0) }
                    if rows.isEmpty { Text(mixed ? "Nothing matches." : "No projects match.").foregroundStyle(Color.hqLabel2) }
                } header: { if mixed, !saved.isEmpty { HQSectionLabel { Text("Projects") } } }
                  footer: { if folders.isEmpty { HQSectionFooter { Text("Starts the chat with \(botName).") } } }
                .hqSheetRows()
            }
            if !folders.isEmpty {
                Section {
                    ForEach(folders) { row($0) }
                } header: { HQSectionLabel { Text("Folders") } }
                  footer: { HQSectionFooter { Text("Starts the chat with \(botName).") } }
                .hqSheetRows()
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, HQFont.scaled(40))
        .listSectionSpacing(.compact)
    }
}

/// [Mac UI check 2026-11-13] C2: a New Chat sheet page that takes the keyboard: Return starts the chat (`onReturn`), and
/// on a pushed page Escape goes back one step (`onEscape`) instead of the app's Escape closing the whole sheet. It
/// takes the keyboard as it shows, so its keys reach it with nothing focused in the sheet.
final class NewChatKeysPage: UIHostingController<AnyView> {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if presentedViewController == nil { becomeFirstResponder() }
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        if onReturn != nil {
            let start = UIKeyCommand(title: "Start Chat", action: #selector(returnPressed), input: "\r")
            start.wantsPriorityOverSystemBehavior = true
            commands.append(start)
        }
        // [macpass] 2026-11-14: on the sheet's first page too. This page holds the keyboard, and the SwiftUI host under
        // it took Escape without doing anything, so the menu's Escape (Close) never closed the sheet.
        let back = UIKeyCommand(title: onEscape == nil ? "Close" : "Back", action: #selector(hqEscape(_:)), input: UIKeyCommand.inputEscape)
        back.wantsPriorityOverSystemBehavior = true
        commands.append(back)
        return commands
    }

    @objc private func returnPressed() { onReturn?() }

    /// The app's Escape (`KeyCommands.escape`) stops here first while this page is in the responder chain: a pushed
    /// page goes back a step, the first page closes the sheet.
    @objc func hqEscape(_ sender: Any?) {
        if let onEscape { onEscape(); return }
        (navigationController ?? self).presentingViewController?.dismiss(animated: true)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(hqEscape(_:)) { return presentedViewController == nil }
        return super.canPerformAction(action, withSender: sender)
    }
}
