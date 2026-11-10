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

    func menuNodes(for session: SessionSummary) -> [BotMenuNode] {
        let tiles: [BotMenuNode] = [
            .action(session.pinned ? "Unpin" : "Pin", session.pinned ? "pin.slash" : "pin") { [weak self] in self?.pin(session) },
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
        let main: [BotMenuNode] = [
            .action("Rename…", "pencil") { [weak self] in self?.rename(session) },
            .action("Branch in New Chat", "arrow.triangle.branch") { [weak self] in self?.branch(session) },
        ] + (store?.project(of: session).map { project in
            [BotMenuNode.action("New Chat in \(project.label)", "square.and.pencil") { [weak self] in
                self?.newChat(profile: session.profile, folder: project.root)
            }]
        } ?? []) + [
            BotMenuNode(title: "Move to Project", image: "folder", kind: .submenu(moveNodes(for: session))),
            BotMenuNode(title: "More", image: "ellipsis.circle", kind: .submenu(more)),
        ]
        // [manual-order] Sort By Manual: the chat's place in its group, without the drag (VoiceOver, Switch Control).
        let key = SessionListPipeline.key(session)
        let order: [BotMenuNode] = host?.chatMoves(key).map { moves in [
            .action("Move Up", "arrow.up", disabled: !moves.up) { [weak self] in self?.host?.moveChat(key, by: -1) },
            .action("Move Down", "arrow.down", disabled: !moves.down) { [weak self] in self?.host?.moveChat(key, by: 1) },
        ] } ?? []
        let end: [BotMenuNode] = [
            .action(session.archived ? "Unarchive" : "Archive", session.archived ? "tray.and.arrow.up" : "archivebox") { [weak self] in
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

    func uiMenu(for session: SessionSummary) -> UIMenu {
        BotMenuNode.uiMenu(menuNodes(for: session), title: SessionRowView.title(session)).menu
    }

    func contextMenu(for session: SessionSummary, key: String) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: key as NSString, previewProvider: nil) { [weak self] _ in
            self?.uiMenu(for: session)
        }
    }

    static func uiColor(_ index: Int) -> UIColor {
        let rgb = SessionColors.rgb(index)
        return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    // MARK: - Swipes

    func leadingActions(for session: SessionSummary) -> UISwipeActionsConfiguration {
        let read = UIContextualAction(style: .normal, title: session.unread ? "Read" : "Unread") { [weak self] _, _, done in
            self?.toggleRead(session)
            done(true)
        }
        read.image = UIImage(systemName: session.unread ? "envelope.open.fill" : "envelope.badge.fill")
        read.backgroundColor = HQPalette.tint
        read.accessibilityLabel = session.unread ? "Mark as Read" : "Mark as Unread"
        let pin = UIContextualAction(style: .normal, title: session.pinned ? "Unpin" : "Pin") { [weak self] _, _, done in
            self?.pin(session)
            done(true)
        }
        pin.image = UIImage(systemName: session.pinned ? "pin.slash.fill" : "pin.fill")
        pin.backgroundColor = .systemOrange
        let actions = UISwipeActionsConfiguration(actions: [read, pin])
        actions.performsFirstActionWithFullSwipe = true
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
        let archive = UIContextualAction(style: .normal, title: session.archived ? "Unarchive" : "Archive") { [weak self] _, _, done in
            done(true)
            self?.archive(session)
        }
        archive.image = UIImage(systemName: session.archived ? "tray.and.arrow.up.fill" : "archivebox.fill")
        archive.backgroundColor = .systemIndigo
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
        if let popover = sheet.popoverPresentationController { popover.sourceView = host.cell(forKey: key) ?? (surface ?? host).view }
        top.present(sheet, animated: true)
    }

    // MARK: - Compose (`S/stress-c-compose.ts`, `S/phone-new-chat.ts`)

    /// The bar's Compose: with one bot, a new chat with it; with more, Choose a Bot first (each bot's face), Hermes
    /// first, then the Bots list's order.
    /// [sessions-m9] `profile`: the picked chip's bot; the new chat is that bot's, with no chooser (§7.3).
    /// Filter › Project narrowed to one project: the new chat starts in it.
    func compose(profile: String? = nil) {
        if let only = store?.effectiveProjects, only.count == 1, let key = only.first, key != SessionProjects.homeKey {
            newChat(inProject: key, profile: profile)
            return
        }
        if let profile { newChat(profile: profile); return }
        // Under All the chooser also offers a project (No Project first): a chat can start in one without hunting
        // for a chat that already lives there.
        store?.loadProjects()
        let projects = (store?.projectEntries() ?? []).filter { $0.key != SessionProjects.homeKey }
        chooseBot(projects: projects) { [weak self] profile, project in
            // New Project…: the New Project alert for the bot picked, then the chat starts in the project made.
            if project == ChooseBotView.newProjectTag { self?.newProject(profile: profile, startsChat: true); return }
            if let project { self?.newChat(inProject: project, profile: profile) } else { self?.newChat(profile: profile) }
        }
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
    func newChat(inProject key: String, profile: String? = nil) {
        guard let store else { return }
        let holders = store.projectHolders(key: key)
        let label = holders.first?.project.label ?? store.projectEntries().first { $0.key == key }?.label
            ?? (key as NSString).lastPathComponent
        let start: (String) -> Void = { [weak self] profile in
            if let held = holders.first(where: { $0.profile == profile }) {
                self?.newChat(profile: profile, folder: held.project.root)
            } else {
                self?.addProjectThenChat(profile: profile, name: label, folder: key)
            }
        }
        if let profile { start(profile) } else { chooseBot(start) }
    }

    /// A bot without the project: `projects.create` for it with the project's name and folder, then the new chat there.
    /// A failure is said, not hidden: the chat never starts outside the project.
    private func addProjectThenChat(profile: String, name: String, folder: String) {
        guard let store else { return }
        let hud = slowHUD("Adding Project…")
        Task { [weak self] in
            defer { hud() }
            do {
                let project = try await store.createProject(name: name, folder: folder, profile: profile)
                hud()
                store.loadProjects(force: true, also: [profile])
                self?.newChat(profile: profile, folder: project.root)
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                let reason = SessionActionText.reason(error)
                let retry: (() -> Void)? = reason == SessionActionText.projectsUnsupported ? nil : { [weak self] in
                    self?.addProjectThenChat(profile: profile, name: name, folder: folder)
                }
                FailureAlert.present(title: "Couldn’t Start a New Chat", reason: reason, detail: SessionActionText.detail(error),
                                     from: self.host, retry: retry)
            }
        }
    }

    /// One bot: it is the answer. More: Choose a Bot first (Hermes first, then the Bots list's order); hidden bots left
    /// out, as the chips leave them out (Hermes is always offered).
    func chooseBot(_ picked: @escaping (String) -> Void) {
        chooseBot(projects: []) { profile, _ in picked(profile) }
    }

    /// `projects`: Compose's New Chat sheet, a Project choice above the bots (shown even with one bot).
    private func chooseBot(projects: [SessionProjectEntry], _ picked: @escaping (_ profile: String, _ project: String?) -> Void) {
        let bots = services.bots.filter { !$0.hidden || $0.id == "default" }
        guard bots.count > 1 || !projects.isEmpty, let host else { picked(bots.first?.id ?? "default", nil); return }
        let ordered = bots.filter { $0.id == "default" } + bots.filter { $0.id != "default" }
        // The sheet itself is dismissed, not `host.presentedViewController` (which can be nil or another controller: a
        // search the page keeps in its presentation context, a sheet still arriving), and the pick is delivered once,
        // even when UIKit drops the dismissal's completion (a tap during the sheet's own animation).
        final class Box { weak var sheet: UINavigationController?; var delivered = false }
        let box = Box()
        let deliver: (String, String?) -> Void = { id, project in
            guard !box.delivered else { return }
            box.delivered = true
            picked(id, project)
        }
        // [ui-sizing] The scaled root, as every hosted page: its bot names stayed 17 pt beside 75 pt faces at 150 %.
        let picker = UIHostingController(rootView: HQScaledRoot(ChooseBotView(bots: ordered, projects: projects) { bot, project in
            guard let sheet = box.sheet, sheet.presentingViewController != nil else { deliver(bot.id, project); return }
            sheet.dismiss(animated: true) { deliver(bot.id, project) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { deliver(bot.id, project) }
        }))
        picker.view.backgroundColor = HQPalette.sheetPage   // [glass] the glass shows around the rows
        let chooser = ChatSheet.wrap(picker, title: projects.isEmpty ? "Choose a Bot" : "New Chat")
        box.sheet = chooser
        host.present(chooser, animated: true)
    }

    /// A new chat in `profile`, started the way the Bots tab starts one (`AppModel.newChat(for:)`): the chat opens at
    /// once with no stored id and makes its session (`session.create`) as it opens. A gateway mints the session live
    /// and writes its row only with the first prompt, so a stored id taken here and opened as a listed chat names a
    /// row that does not exist yet.
    /// `folder`: a project's root; the chat starts there.
    func newChat(profile: String, folder: String? = nil) {
        Haptics.play(.soft)
        if let starter = services as? BotChatStarting, let bot = services.bots.first(where: { $0.id == profile }) {
            host?.openChat(model: starter.newChat(for: bot, folder: folder), fresh: true)
            return
        }
        guard let store else { return }
        run("Couldn’t Start a New Chat", {
            let made = try await store.newChat(profile: profile, folder: folder)
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

    func pin(_ session: SessionSummary) {
        guard let store else { return }
        Haptics.play(.selection)
        let pinned = !session.pinned
        run(pinned ? "Couldn’t Pin Chat" : "Couldn’t Unpin Chat", owner: session.owner) { try await store.setPinned(session, pinned) }
    }

    func toggleRead(_ session: SessionSummary) {
        Haptics.play(.selection)
        store?.setUnread(session, !session.unread)
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
                done: { [weak self] in MenusHUD.show("Unarchived", in: self?.surface?.view) },
                retry: { [weak self] in self?.archive(session) })
            return
        }
        let archiving = Task { try await store.setArchived(session, true) }
        let pill = store.readOnlyGateway ? nil : UndoPill.show(label: "Archived “\(SessionRowView.title(session))”",
                                                                    wayBack: SessionActionText.archivedWayBack, showsWayBack: !store.view.showArchived, in: surface) { [weak self] in
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
    func deleteProject(key: String, title: String) {
        guard let host, let store else { return }
        TextPrompt.confirm(title: "Delete “\(title)”?",
                           message: "Its chats and its folder are kept. Chats still in the folder will show under the folder’s name instead.",
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
        askNewProject { [weak self] name, folder in
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
        askNewProject(name: name, folder: folder) { [weak self] name, folder in
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
    private func askNewProject(name: String = "", folder: String = "", create made: @escaping (_ name: String, _ folder: String) -> Void) {
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
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(create)
        alert.preferredAction = create
        host.present(alert, animated: true)
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
            popover.sourceView = host.cell(forKey: key) ?? (surface ?? host).view
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

/// Choose a Bot (the web's scope sheet for Compose): each bot's face and name.
struct ChooseBotView: View {
    /// The Project picker's New Project… row (never a project's key, which is a folder path).
    static let newProjectTag = "\u{1F}new-project"
    var bots: [Bot]
    /// Compose's New Chat sheet: the projects to start in (none: the plain Choose a Bot list).
    var projects: [SessionProjectEntry] = []
    var pick: (Bot, _ project: String?) -> Void
    @State private var project: String?

    private var botsSection: some View {
        ForEach(bots) { bot in
            Button { pick(bot, project) } label: {
                // [ui-sizing 2026-11-09] A name-only row: a 32 pt face in a 44 pt row (× UI Scale), not the Bots list's
                // 50 pt face in a 58 pt row; four bots filled the half sheet on a 375 pt phone.
                HStack(spacing: 12) {
                    HeadImage(raw: bot.head, profile: bot.id, size: HQFont.scaled(32), working: false)
                    Text(bot.name).foregroundStyle(Color.hqLabel)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: HQFont.scaled(44))
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("choose-bot-\(bot.id)")
        }
    }

    var body: some View {
        List {
            // item 11: a Section whose header closure resolves to an EmptyView (rather than being left out) still
            // reserves a full header's height, which read as ~80 pt of blank space above the first row. Two
            // separate Sections, only one of them ever with a header, start the list right under the title.
            if projects.isEmpty {
                Section { botsSection }.hqSheetRows()
            } else {
                Section {
                    Picker(selection: $project) {
                        Text("No Project").tag(String?.none)
                        ForEach(projects) { entry in Text(entry.label).tag(Optional(entry.key)) }
                        // Polish 2026-10-24 (owner call): a chat can start in a project that doesn't exist yet.
                        Label("New Project…", systemImage: "folder.badge.plus").tag(Optional(Self.newProjectTag))
                    } label: {
                        Label("Project", systemImage: "folder").foregroundStyle(Color.hqLabel)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("choose-project")
                }
                .hqSheetRows()
                Section { botsSection } header: { HQSectionLabel { Text("Bot") } }.hqSheetRows()
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
    }
}
