// More › Workspace › Files and Review (docs/spec/3x-morepages.md §11, D-M10): the gateway computer's folders and a
// project's uncommitted changes, read-only. Pushed on More's stack. They read through the chat's own workspace calls
// (`HermesKit/Chat/ChatWorkspace.swift`) and show text and diffs in the chat's `WorkspaceTextPage`; what is added here
// is the root (chosen folder → the last chat's folder → the gateway's default, `MoreWorkspaceRoot`), the root's header
// row with its menu, the bot picker, the folder chooser, the web's folder-error words, the large-file notice and
// opening files that are not text. Nothing on these pages writes: every request is a GET.

import CryptoKit
import SwiftUI
import UIKit

extension MorePages {
    static func installFilesReview() {
        factories["files"] = { context in MoreWorkspaceController(space: MoreWorkspace(context: context, kind: .files), mode: .root) }
        factories["review"] = { context in MoreWorkspaceController(space: MoreWorkspace(context: context, kind: .review), mode: .root) }
        #if DEBUG
        // UI tests start from no chosen folder, no remembered chat and the default bot (`-HQFilesForgetFolders YES`).
        if UserDefaults.standard.bool(forKey: "HQFilesForgetFolders") {
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix("pages.filesRoot.") || key.hasPrefix("pages.filesChat.") || key.hasPrefix("pages.more.bot.workspace.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        #endif
    }
}

// MARK: - The chat last on screen

/// Remembers the chat last on screen and its folder (the second choice for the Files root). `MainTabController`
/// reports the chat on show; the folder is read again from the live chat when Files opens, because a chat often
/// learns its folder only after it has opened.
@MainActor
enum MoreChatFolder {
    private static weak var live: LiveChatSession?

    static func note(_ session: LiveChatSession, account: String) {
        live = session
        record(session).write(account: account)
    }

    private static func record(_ session: LiveChatSession) -> MoreChatFolderRecord {
        MoreChatFolderRecord(profile: session.profile.isEmpty ? "default" : session.profile,
                             sessionId: session.storedSessionId ?? session.resolvedStoredId,
                             cwd: MoreWorkspaceRoot.folder(session.workingDirectory), title: session.menus.isBotChat ? nil : session.title)
    }

    static func current(account: String) -> MoreChatFolderRecord? {
        guard var saved = MoreChatFolderRecord.read(account: account) else { return nil }
        if let live {
            let now = record(live)
            if now.profile == saved.profile, now.sessionId == saved.sessionId || saved.sessionId == nil, now != saved {
                if now.cwd == nil { saved.title = now.title ?? saved.title; saved.sessionId = now.sessionId ?? saved.sessionId } else { saved = now }
                saved.write(account: account)
            }
        }
        return saved
    }
}

// MARK: - What the pages of one visit share

@MainActor
final class MoreWorkspace {
    enum Kind { case files, review }

    let context: MorePages.Context
    let kind: Kind
    private(set) var profile: String
    private(set) var root: MoreWorkspaceRoot.Root?
    private(set) var chatTitle: String?
    /// The gateway user's home, for "~" in paths; nil until `/api/profiles` answered (or when it is not under ".hermes").
    private(set) var home: String?
    private var homeAsked = false
    var onHome: (() -> Void)?

    init(context: MorePages.Context, kind: Kind) {
        self.context = context
        self.kind = kind
        profile = MoreBotChoice.read("workspace", context: context)
    }

    var row: String { kind == .files ? "files" : "review" }
    var title: String { kind == .files ? "Files" : "Changes" }   // the chat ⋯ menu's word for the same list
    var workspace: ChatWorkspace {
        ChatWorkspace(client: context.client, profile: profile.isEmpty || profile == "default" ? nil : profile)
    }
    var chosen: String? { MoreWorkspaceRoot.chosen(account: context.account.id, profile: profile) }
    var bots: [Bot] { context.botChoices }

    func setProfile(_ next: String) {
        profile = next
        MoreBotChoice.save(next, page: "workspace", context: context)
        root = nil
    }

    func setChosen(_ path: String?) {
        MoreWorkspaceRoot.setChosen(path, account: context.account.id, profile: profile)
        root = nil
    }

    /// The root by precedence; asks the gateway only when nothing is chosen and the last chat has no folder.
    func resolveRoot() async throws -> MoreWorkspaceRoot.Root? {
        let chat = MoreChatFolder.current(account: context.account.id)
        let chatFolder = chat?.folder(for: profile, sessions: context.services.sessions)
        chatTitle = chatFolder == nil ? nil : chat?.title
        var gateway: String?
        if MoreWorkspaceRoot.needsGatewayDefault(chosen: chosen, chatFolder: chatFolder) {
            let json = try await PagesREST.json(context.client, "GET", "/api/fs/default-cwd", query: MoreWire.profileQuery(profile))
            gateway = json["cwd"]?.string
        }
        root = MoreWorkspaceRoot.resolve(chosen: chosen, chatFolder: chatFolder, gatewayDefault: gateway)
        return root
    }

    func askHome() {
        guard !homeAsked else { return }
        homeAsked = true
        let client = context.client
        Task { [weak self] in
            guard let json = try? await PagesREST.json(client, "GET", "/api/profiles"),
                  let home = MoreWorkspaceRoot.gatewayHome(profiles: json) else { return }
            self?.home = home
            self?.onHome?()
        }
    }

    func display(_ path: String) -> String { MoreWorkspaceRoot.display(path, home: home) }

    /// Whether `path` is inside a repository: nil when the gateway cannot say.
    func isRepository(_ path: String) async -> Bool? {
        guard let json = try? await PagesREST.json(context.client, "GET", "/api/fs/git-root",
                                                   query: [URLQueryItem(name: "path", value: path)] + MoreWire.profileQuery(profile)),
              json.object != nil, let root = json["root"] else { return nil }
        return root.string?.isEmpty == false
    }

    func download(_ path: String) async throws -> Data {
        try await PagesREST.send(context.client, "GET", "/api/fs/download",
                                 query: [URLQueryItem(name: "path", value: path)] + MoreWire.profileQuery(profile), timeout: 120)
    }

    /// [mac-audit] The repository `path` is in (Changes names its files from there); nil when the gateway cannot say.
    func gitRoot(_ path: String) async -> String? {
        let json = try? await PagesREST.json(context.client, "GET", "/api/fs/git-root",
                                             query: [URLQueryItem(name: "path", value: path)] + MoreWire.profileQuery(profile))
        return json?["root"]?.nonEmptyString
    }

    /// [mac-audit] A file downloaded into the cache (`cacheURL`) for Share…, Save As…, Quick Look or a drag out of the app.
    /// [mac] Mac polish 2026-11-06 #47: on the Mac, streamed to disk up to a chat file card's limit (512 MB,
    /// `MediaLoader.fileCeiling`), as the card's own download is. Read whole into memory it stopped at the gateway
    /// answers' 32 MB, so an 80 MB file dragged to the Finder dropped nothing, and Save As… and Share… said it was too
    /// large. The iPhone and iPad keep the 32 MB read and its "too large to open on your phone" (D-P9): a tap there
    /// shouldn't quietly fetch half a gigabyte over mobile data.
    func fetch(_ path: String) async throws -> URL {
        let url = cacheURL(path)
        guard DeviceWord.isMac, let client = context.client as? GatewayFileTransfers else {
            // The iPhone and iPad, or a client that can't stream (a test's stand-in): read whole, as before.
            let data = try await download(path)
            try await ArtifactFiles.save(data, to: url)
            return url
        }
        _ = try await client.download("/api/fs/download", query: [URLQueryItem(name: "path", value: path)] + MoreWire.profileQuery(profile),
                                      to: url, ceiling: MediaLoader.fileCeiling, priority: URLSessionTask.highPriority, progress: nil)
        return url
    }

    /// Where a downloaded file is kept for Quick Look and Share (Caches: the system may purge it).
    func cacheURL(_ path: String) -> URL {
        let digest = SHA256.hash(data: Data("\(profile)|\(path)".utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "_")
        return PagesCache.directory(for: context.account, root: PagesCache.previewRoot)
            .appending(path: "workspace-" + digest).appending(path: name.isEmpty ? "file" : name)
    }

    /// The words for a file that could not be opened; the too-large words for a 413 or an answer past the app's limit.
    static func openFailure(_ error: Error) -> String {
        if let failure = error as? GatewayFailure, failure == .responseTooLarge { return ArtifactFiles.tooLargeText }
        if PagesREST.status(error) == 413 { return ArtifactFiles.tooLargeText }
        return PagesREST.reason(error)
    }
}

// MARK: - The list page (root, a folder, the folder chooser)

final class MoreWorkspaceController: UITableViewController {
    enum Mode: Equatable {
        /// The page More pushes: the header rows, then the root's files or changes.
        case root
        /// A folder under the root (Files).
        case folder(String)
        /// Choose Folder…: folders only, with Use This Folder in the bar.
        case chooser(String)
    }

    private enum Content {
        case loading
        case entries([WorkspaceEntry])
        case changes([WorkspaceChange])
        case state(MoreWorkspaceRoot.Words, symbol: String, retry: Bool, choose: Bool)
    }

    private enum HeaderRow { case bot, root }

    private let space: MoreWorkspace
    private let mode: Mode
    private var content: Content = .loading
    private var load: Task<Void, Never>?
    private var opening: Task<Void, Never>?
    private var busyPath: String?
    private var firstReadNoted = false
    /// [mac-audit] Changes: the repository its paths are named from (asked once the list is read, on the Mac).
    private var repoRoot: String?
    /// [mac-tools] The Mac's table (`MacFilesTable.swift`): the trail and columns at the top, one-line rows, a folder
    /// opened in place, the bot and the folder's menu in the bar. Not the folder chooser, which stays a list of cards.
    let isTable: Bool
    /// [mac-tools] The folder under the root the table is showing (nil: the root itself).
    private var browsed: String?
    /// [mac-tools] The file whose page is in the pane beside the table, and that page: its row stays marked.
    private var markedPath: String?
    private weak var markedPage: UIViewController?
    private let tableHeader = MacFilesHeaderView()
    private var barBotButton: UIButton?
    private static let live = NSHashTable<MoreWorkspaceController>.weakObjects()
    /// Chooser pages: called with the folder to use.
    var onUse: ((String) -> Void)?
    private var useItem: UIBarButtonItem?

    init(space: MoreWorkspace, mode: Mode) {
        self.space = space
        self.mode = mode
        if case .chooser = mode { isTable = false } else { isTable = DeviceWord.isMac }
        super.init(style: isTable ? .plain : .insetGrouped)
        navigationItem.largeTitleDisplayMode = .never
        if isTable { Self.live.add(self) }
        switch mode {
        case .root: title = space.title
        case .folder(let path), .chooser(let path): title = MoreWorkspaceRoot.name(path)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { load?.cancel(); opening?.cancel() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if isTable { fitStateRow(); return }   // [mac-tools] a table on the page: no card outline, no form width
        // Stress test 2026-10-28 #56: the look's outlined box, not iOS's card.
        // [mac] Stress test 2026-10-28 #9: a page's state (empty, failed, loading) stands on the page with no box.
        DesktopTableOutliner.attach(to: tableView) { [weak self] section in self?.isStateSection(section) ?? false }
        MacForm.capReadableWidth(tableView)          // [mac] Stress test 2026-10-28 #8: Files and Changes at the form's width
        fitStateRow()
        // [mac] Mac polish #113 (review): the files' kinds fit the row again after a resize (not the header rows).
        kindRoom = WorkspacePage.refitKinds(in: tableView, fitted: kindRoom) { [contentSection] in $0.section == contentSection }
    }

    /// [mac] Mac polish #113 (review): the room the rows' kinds were last fitted to (`WorkspacePage.refitKinds`).
    private var kindRoom: CGFloat = 0

    private func isStateSection(_ section: Int) -> Bool {
        guard section == contentSection else { return false }
        switch content {
        case .loading, .state: return true
        case .entries, .changes: return false
        }
    }

    /// [mac] Stress test 2026-10-28 #9: the state row's height on the Mac: the room left under the header rows, so its
    /// words sit centred there with the one lift every page's state has (they stood in a 36 pt-padded card at the top).
    private var stateRowHeight: CGFloat?

    private func fitStateRow() {
        guard DeviceWord.isMac, isViewLoaded, tableView.numberOfSections > contentSection else { return }
        var next: CGFloat?
        if isStateSection(contentSection) {
            // The rows above (with the table's header view) and the gap a grouped table leaves before the section.
            let above = contentSection > 0 ? tableView.rect(forSection: contentSection - 1).maxY : (tableView.tableHeaderView?.frame.height ?? 0)
            let room = tableView.bounds.height - tableView.adjustedContentInset.top - tableView.adjustedContentInset.bottom
                - above - 2 * MacInset.top - (isTable ? MacFilesHeaderView.height(columns: false) : 0)
            next = max(240, room.rounded())
        }
        guard next != stateRowHeight else { return }
        if let old = stateRowHeight, let new = next, abs(old - new) < 1 { return }
        stateRowHeight = next
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.section == contentSection, isStateSection(indexPath.section), let stateRowHeight { return stateRowHeight }
        // [mac] Stress test 2026-10-28 round 7: the Bot row at the row height itself. Self-sized, the table added its
        // separator's pixel under the row's own height, so it stood 1 pt taller than on Messaging, Star Map, Connectors.
        if DeviceWord.isMac, indexPath.section < contentSection, headerRows[indexPath.section] == .bot { return MoreBotPicker.macHeight }
        if isTable { return MacFilesTable.rowHeight }
        return UITableView.automaticDimension
    }

    private var isChooser: Bool { if case .chooser = mode { return true } else { return false } }
    private var showsChanges: Bool { mode == .root && space.kind == .review }
    private var headerRows: [HeaderRow] {
        guard mode == .root, !isTable else { return [] }   // [mac-tools] the table has them in its bar
        return (space.bots.count > 1 ? [.bot] : []) + [.root]
    }
    /// The folder this page lists (the root's, once resolved).
    private var directory: String? {
        switch mode {
        case .root: return browsed ?? space.root?.path
        case .folder(let path), .chooser(let path): return path
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = isChooser ? "workspace.chooser" : showsChanges ? "more.review" : "more.files"
        tableView.backgroundColor = isTable ? HQPalette.page : HQPalette.groupedPage
        if !isTable { PageBackdrop.install(behind: tableView) }   // [backdrop] Theme › App Background
        // Cards 16 pt in, as the More root and the other More pages (the system's 20 pt made the edges jump).
        viewRespectsSystemMinimumLayoutMargins = false
        // [mac] Stress test 2026-10-28 #53: the Mac's one page inset (20), as Messaging and Capabilities.
        let side = DeviceWord.isMac ? MacInset.side : 16
        tableView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: side, bottom: 0, trailing: side)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "state")
        tableView.register(MoreWorkspaceRootCell.self, forCellReuseIdentifier: "root")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "bot")
        tableView.register(MacFileRowCell.self, forCellReuseIdentifier: "file")
        tableView.rowHeight = UITableView.automaticDimension
        // UX study #174, item 9: a grouped table with no header view leaves a system gap above the first card; a
        // header this tall instead matches the one top inset every pushed More page uses (MorePageMetrics.topGap).
        // [mac] Stress test 2026-10-28 #53: on the Mac the page's 16 pt under the bar (the Bot card touched the bar).
        tableView.tableHeaderView = isTable ? nil : UIView(frame: CGRect(x: 0, y: 0, width: 0,
                                                         height: DeviceWord.isMac ? MacInset.top : MorePageMetrics.topGap))
        if isTable { installTable() }
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        tableView.hqInstallRefresh(refresh)
        #if targetEnvironment(macCatalyst)
        // [mac-audit] Owner 2026-11-02 (Mac audit J2): a file drags out to the Finder or another app, as a chat's file card.
        if !isChooser {
            tableView.dragDelegate = self
            tableView.dragInteractionEnabled = true
        }
        #endif
        if isChooser {
            let item = UIBarButtonItem(title: "Use This Folder", primaryAction: UIAction(title: "Use This Folder") { [weak self] _ in
                guard let self, let directory = self.directory else { return }
                PagesHaptics.success()
                self.onUse?(directory)
            })
            item.style = .prominent
            item.accessibilityIdentifier = "workspace.use-folder"
            navigationItem.rightBarButtonItem = item
            useItem = item
        }
        if mode == .root {
            space.onHome = { [weak self] in self?.reloadHeader() }
            space.askHome()
        }
        reload()
    }

    // MARK: Loading

    /// Reads the root again (after a new folder or bot) and then its entries.
    func reload() {
        load?.cancel()
        opening?.cancel()
        busyPath = nil
        if case .state = content { content = .loading }
        if mode == .root, space.root == nil { content = .loading }
        tableView.reloadData()
        if isTable { fillTableHeader() }
        let space = self.space, mode = self.mode
        load = Task { [weak self] in
            defer { self?.tableView.refreshControl?.endRefreshing() }
            var directory = self?.directory
            if mode == .root {
                do {
                    let root = try await space.resolveRoot()?.path
                    // [mac-tools] The folder being browsed, while it is still under the root.
                    if let self, let browsed = self.browsed, let root, Self.isUnder(browsed, root) { directory = browsed }
                    else { self?.browsed = nil; directory = root }
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    let missing = self.noteFirstRead(error)
                    self.show(.state(.init(title: missing ? MoreWire.notAvailableTitle : space.kind == .files ? "Couldn’t Load Files" : "Couldn’t Load Changes",
                                           body: missing ? MoreWire.notAvailableBody(space.title) : PagesREST.reason(error)),
                                     symbol: "exclamationmark.triangle", retry: !missing, choose: !missing))   // [mac] Stress test 2026-10-28 #10
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.reloadHeader()
                AppLog.trace("pages", "workspace \(space.kind == .files ? "files" : "review") root resolved: \(space.root?.source ?? .gateway)")
            }
            guard let directory else {
                self?.show(.state(.init(title: "No Folder Yet", body: "Choose a folder on \(HostWord.phrase) to browse."),
                                  symbol: "folder.badge.questionmark", retry: false, choose: true))
                return
            }
            await self?.read(directory)
        }
    }

    private func read(_ directory: String) async {
        let space = self.space
        do {
            if showsChanges {
                let changes = MoreWorkspaceRoot.deduped(try await space.workspace.changes(in: directory))
                guard !Task.isCancelled else { return }
                noteFirstRead(nil)
                if changes.isEmpty {
                    // Hermes answers an empty list for a folder that is not a repository: ask which it is.
                    let repository = await space.isRepository(directory)
                    guard !Task.isCancelled else { return }
                    if repository == false {
                        show(.state(MoreWorkspaceRoot.notGit, symbol: "arrow.triangle.branch", retry: false, choose: true))
                    } else {
                        show(.state(MoreWorkspaceRoot.noChanges, symbol: "checkmark.circle", retry: false, choose: false))
                    }
                    AppLog.trace("pages", "workspace review: 0 changes, is repository \(repository.map(String.init) ?? "unknown")")
                } else {
                    // [mac-audit] Copy Path, Save As… and a drag need each file's whole path: the repository's root.
                    if DeviceWord.isMac, repoRoot == nil { repoRoot = await space.gitRoot(directory) }
                    guard !Task.isCancelled else { return }
                    show(.changes(changes))
                    AppLog.trace("pages", "workspace review: \(changes.count) changes")
                }
            } else {
                var entries = MoreWorkspaceRoot.deduped(try await space.workspace.list(directory))
                guard !Task.isCancelled else { return }
                noteFirstRead(nil)
                if isChooser { entries = entries.filter(\.isDirectory) }
                if entries.isEmpty && !isChooser {
                    show(.state(.init(title: "Empty Folder", body: "There is nothing in this folder."), symbol: "folder", retry: false, choose: false))
                } else {
                    show(.entries(entries))
                }
                AppLog.trace("pages", "workspace files\(isChooser ? " (chooser)" : ""): \(entries.count) entries")
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            let reason = (error as? MenusError)?.message ?? PagesREST.reason(error)
            if !(error is MenusError), noteFirstRead(error) {
                // [mac] Stress test 2026-10-28 #10: the page's own line, and no Try Again for a page Hermes doesn't have.
                show(.state(.init(title: MoreWire.notAvailableTitle, body: MoreWire.notAvailableBody(space.title)),
                            symbol: "exclamationmark.triangle", retry: false, choose: false))
            } else if showsChanges {
                if MoreWorkspaceRoot.isNotGit(reason: reason) {
                    show(.state(MoreWorkspaceRoot.notGit, symbol: "arrow.triangle.branch", retry: false, choose: true))
                } else {
                    show(.state(.init(title: "Couldn’t Load Changes", body: reason), symbol: "exclamationmark.triangle", retry: true, choose: false))
                }
            } else {
                let words = MoreWorkspaceRoot.folderErrorText(reason, chatFolder: mode == .root && space.root?.source == .chat)
                show(.state(words, symbol: "exclamationmark.triangle", retry: true, choose: mode == .root))
            }
        }
    }

    /// The page's first read answered (or failed): a gateway without the route loses its More row. True when missing.
    @discardableResult
    private func noteFirstRead(_ error: Error?) -> Bool {
        guard mode == .root else { return false }
        if firstReadNoted && error == nil { return false }
        firstReadNoted = true
        return MorePages.noteRead(space.row, error: error)
    }

    private func show(_ next: Content) {
        content = next
        if case .state(_, _, let retry, _) = next, isChooser { useItem?.isEnabled = !retry }
        else if isChooser { useItem?.isEnabled = true }
        tableView.reloadData()
        if isTable { fillTableHeader(); restoreMark() }
    }

    private func reloadHeader() {
        if isTable, isViewLoaded { fillTableHeader(); return }
        guard isViewLoaded, !headerRows.isEmpty else { return }
        tableView.reloadData()
    }

    // MARK: The Mac's table

    private static func isUnder(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private var tableColumns: [(String, MacFilesTable.Column)] {
        showsChanges ? [("Status", .status), ("Lines", .lines)] : [("Kind", .kind)]
    }

    private func installTable() {
        tableView.separatorStyle = .none
        tableView.sectionHeaderTopPadding = 0
        tableView.rowHeight = MacFilesTable.rowHeight
        tableHeader.onCrumb = { [weak self] path in self?.browse(path) }
        ListBarAppearance.apply(to: navigationItem)
        var button: UIButton?
        if space.bots.count > 1 {
            let made = MacToolBar.popUp(identifier: "more.bot-picker")
            made.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.botMenu().children ?? []) }])
            button = made
            barBotButton = made
        }
        navigationItem.leftBarButtonItem = MacToolBar.lead(title: space.title, popUp: button)
        navigationItem.titleView = UIView()   // the middle stays empty; `title` still names the page (VoiceOver)
        let folder = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"),
                                     menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.rootMenu().children ?? []) }]))
        folder.accessibilityLabel = "Folder Options"
        folder.accessibilityIdentifier = "workspace.root.menu"
        let again = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), primaryAction: UIAction { [weak self] _ in self?.reload() })
        again.accessibilityLabel = "Refresh"
        again.accessibilityIdentifier = "workspace.refresh"
        navigationItem.rightBarButtonItems = [folder, again]
        fillTableHeader()
    }

    /// The trail from the root's folder down to the one listed, the count, and the columns (none over a state).
    private func fillTableHeader() {
        if let barBotButton {
            MacToolBar.setTitle(space.context.botName(space.profile), on: barBotButton)
            barBotButton.accessibilityLabel = "Bot: \(space.context.botName(space.profile))"
        }
        var crumbs: [MacFilesHeaderView.Crumb] = []
        if let root = space.root?.path {
            // The root's whole path and where it comes from ("The folder of …") are its tip.
            let source = space.root.map { MoreWorkspaceRoot.sourceLine($0.source, chatTitle: space.chatTitle) } ?? ""
            crumbs.append(.init(name: MoreWorkspaceRoot.name(root), path: root,
                                tip: space.display(root) + (source.isEmpty ? "" : "\n" + source)))
            if let browsed, Self.isUnder(browsed, root), browsed != root {
                var path = root
                for part in browsed.dropFirst(root.count).split(separator: "/") {
                    path = (path.hasSuffix("/") ? path : path + "/") + part
                    crumbs.append(.init(name: String(part), path: path))
                }
            }
        } else if case .loading = content {
            crumbs.append(.init(name: "Finding the Folder…", path: nil))
        } else {
            crumbs.append(.init(name: "No Folder", path: nil))
        }
        var count = "", columns: [(String, MacFilesTable.Column)]?
        switch content {
        case .entries(let entries):
            count = entries.count == 1 ? "1 item" : "\(entries.count) items"
            columns = tableColumns
        case .changes(let changes):
            count = changes.count == 1 ? "1 changed file" : "\(changes.count) changed files"
            columns = tableColumns
        case .loading, .state:
            break
        }
        tableHeader.set(crumbs: crumbs, count: count, columns: columns)
        let height = MacFilesHeaderView.height(columns: columns != nil)
        if tableHeader.frame.height != height {
            tableHeader.frame.size.height = height
            UIView.performWithoutAnimation { tableView.beginUpdates(); tableView.endUpdates() }
        }
    }

    /// Lists `path` in place (a folder's row, or a folder in the trail).
    private func browse(_ path: String) {
        guard isTable, mode == .root, let root = space.root?.path, Self.isUnder(path, root) else { return }
        PagesHaptics.selection()
        browsed = path == root ? nil : path
        content = .loading
        tableView.reloadData()
        fillTableHeader()
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
        opening?.cancel()
        busyPath = nil
        load?.cancel()
        load = Task { [weak self] in await self?.read(path) }
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        isTable && section == contentSection ? tableHeader : nil
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard isTable, section == contentSection else { return UITableView.automaticDimension }
        var columns = false
        switch content {
        case .entries, .changes: columns = true
        case .loading, .state: break
        }
        return MacFilesHeaderView.height(columns: columns)
    }

    /// The row of the file on show beside the table, marked again after the rows were made again.
    private func restoreMark() {
        guard isTable, let markedPath else { return }
        var row: Int?
        switch content {
        case .entries(let entries): row = entries.firstIndex { $0.path == markedPath }
        case .changes(let changes): row = changes.firstIndex { $0.path == markedPath }
        case .loading, .state: break
        }
        guard let row else { return }
        tableView.selectRow(at: IndexPath(row: row, section: contentSection), animated: false, scrollPosition: .none)
    }

    private func mark(_ path: String?, page: UIViewController?) {
        markedPath = path
        markedPage = page
        // The file beside the table closes (the table takes the window back), as a task beside Kanban's board.
        if let page, page.navigationItem.leftBarButtonItems?.isEmpty ?? true {
            let close = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { _ in
                MainTabController.current?.split?.closeDetail(animated: true)
            })
            close.accessibilityLabel = "Close File"
            close.accessibilityIdentifier = "workspace.file.close"
            page.navigationItem.leftBarButtonItem = close
        }
        if path == nil, let selected = tableView.indexPathForSelectedRow { tableView.deselectRow(at: selected, animated: false) }
        else { restoreMark() }
    }

    /// The right pane shows `root` now: a table whose file is no longer the one on show drops its mark.
    static func markOnShow(_ root: UIViewController?, keepsSelection: Bool) {
        for page in live.allObjects where page.isViewLoaded && page.markedPath != nil {
            if !keepsSelection || page.markedPage == nil || page.markedPage !== root { page.mark(nil, page: nil) }
        }
    }

    private func fileCell(_ indexPath: IndexPath) -> MacFileRowCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "file", for: indexPath) as! MacFileRowCell
        cell.striped = indexPath.row % 2 == 1
        cell.selectionStyle = .default
        return cell
    }

    // MARK: Choosing

    private func chooseFolder() {
        let start = space.root.flatMap { MoreWorkspaceRoot.parent($0.path) ?? $0.path } ?? space.home ?? "/"
        pushChooser(start, animated: true)
    }

    private func pushChooser(_ path: String, animated: Bool) {
        let page = MoreWorkspaceController(space: space, mode: .chooser(path))
        page.onUse = onUse ?? { [weak self] chosen in
            guard let self else { return }
            self.space.setChosen(chosen)
            self.browsed = nil
            self.navigationController?.popToViewController(self, animated: true)
            // [mac-tools] The chooser stood in the pane beside the table: it leaves with the choice.
            if self.isTable { MainTabController.current?.split?.closeDetail(animated: true) }
            self.reload()
        }
        navigationController?.pushViewController(page, animated: animated)
    }

    private func rootMenu() -> UIMenu {
        var actions: [UIMenuElement] = [UIAction(title: "Choose Folder…", image: UIImage(systemName: "folder")) { [weak self] _ in
            self?.chooseFolder()
        }]
        if space.chosen != nil {
            actions.append(UIAction(title: "Use Chat’s Folder", image: UIImage(systemName: "bubble.left")) { [weak self] _ in
                guard let self else { return }
                PagesHaptics.selection()
                self.space.setChosen(nil)
                self.browsed = nil
                self.reload()
            })
        }
        return UIMenu(children: actions)
    }

    private func botMenu() -> UIMenu {
        UIMenu(children: space.bots.map { bot in
            UIAction(title: bot.name, state: bot.id == space.profile ? .on : .off) { [weak self] _ in
                guard let self, bot.id != self.space.profile else { return }
                PagesHaptics.selection()
                self.space.setProfile(bot.id)
                self.browsed = nil
                self.reload()
            }
        })
    }

    // MARK: Rows

    /// Each header row is a card of its own: the bot is not a property of the folder (UX study #49).
    private var contentSection: Int { headerRows.count }
    /// Chooser pages list the enclosing folder first, so any folder on the computer can be reached.
    private var parentRow: String? { isChooser ? directory.flatMap(MoreWorkspaceRoot.parent) : nil }

    override func numberOfSections(in tableView: UITableView) -> Int { contentSection + 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section < contentSection { return 1 }
        switch content {
        case .loading, .state: return 1
        case .entries(let entries): return entries.count + (parentRow == nil ? 0 : 1) + (isChooser && entries.isEmpty ? 1 : 0)
        case .changes(let changes): return changes.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard section == contentSection, isChooser else { return nil }
        return directory.map(space.display)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == contentSection else { return nil }
        if isChooser { return "Files and Changes will show the folder you choose." }
        if isTable { return nil }   // [mac-tools] the count is beside the trail
        if case .changes(let changes) = content { return changes.count == 1 ? "1 changed file" : "\(changes.count) changed files" }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section < contentSection {
            switch headerRows[indexPath.section] {
            case .bot: return botCell(indexPath)
            case .root: return rootCell(indexPath)
            }
        }
        switch content {
        case .loading:
            return stateCell(indexPath, configuration: .loading(), identifier: "workspace.loading")
        case .state(let words, let symbol, let retry, let choose):
            var config = UIContentUnavailableConfiguration.empty().hqScaled()
            config.image = UIImage(systemName: symbol)
            config.text = words.title
            config.secondaryText = words.body
            if retry {
                var button = UIButton.Configuration.hqMacPush(or: .borderedProminent(), capsule: true)   // [mac] Stress test 2026-10-28 #55 (round 6)
                button.title = "Try Again"
                config.button = button
                config.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.reload() }
            }
            if choose && !isChooser {
                var button = UIButton.Configuration.hqMacPush(or: retry ? .plain() : .borderedProminent(), capsule: true)   // [mac] Stress test 2026-10-28 #55 (round 6)
                button.title = "Choose Folder…"
                let action = UIAction { [weak self] _ in self?.chooseFolder() }
                if retry { config.secondaryButton = button; config.secondaryButtonProperties.primaryAction = action }
                else { config.button = button; config.buttonProperties.primaryAction = action }
            }
            return stateCell(indexPath, configuration: config, identifier: "workspace.state")
        case .entries(let entries) where isTable:
            let entry = entries[indexPath.row]
            let cell = fileCell(indexPath)
            let kind = MediaKinds.kindWord(entry.name, isDirectory: entry.isDirectory)
            cell.set(symbol: entry.isDirectory ? "folder" : MediaKinds.glyph(MediaKinds.kind(ofName: entry.name)),
                     tint: entry.isDirectory ? HQPalette.tint : HQPalette.label2,
                     name: NSAttributedString(string: entry.name, attributes: [.font: MacFilesTable.text, .foregroundColor: HQPalette.label]),
                     columns: [(NSAttributedString(string: kind, attributes: [.font: MacFilesTable.text, .foregroundColor: HQPalette.label2]),
                                .kind)],
                     busy: busyPath == entry.path)
            cell.accessibilityIdentifier = "workspace.entry.\(entry.name)"
            cell.accessibilityLabel = "\(entry.name), \(kind)"
            return cell
        case .changes(let changes) where isTable:
            let change = changes[indexPath.row]
            let cell = fileCell(indexPath)
            let letter = MoreWorkspaceRoot.statusLetter(change.status)
            let added = letter == "A" || letter == "?", deleted = letter == "D"
            // The file's name in the label colour, its folder before it in grey ("src/" then "app.js").
            let folder = (change.path as NSString).deletingLastPathComponent
            let name = NSMutableAttributedString()
            if !folder.isEmpty {
                name.append(NSAttributedString(string: folder + "/", attributes: [.font: MacFilesTable.text, .foregroundColor: HQPalette.label2]))
            }
            name.append(NSAttributedString(string: (change.path as NSString).lastPathComponent,
                                           attributes: [.font: MacFilesTable.text, .foregroundColor: HQPalette.label]))
            let lines = NSMutableAttributedString()
            if change.added > 0 || change.removed == 0 {
                lines.append(NSAttributedString(string: "+\(max(0, change.added))", attributes: [.font: MacFilesTable.text, .foregroundColor: UIColor.systemGreen]))
            }
            if change.removed > 0 {
                lines.append(NSAttributedString(string: (lines.length > 0 ? " " : "") + "−\(change.removed)",
                                                attributes: [.font: MacFilesTable.text, .foregroundColor: HQPalette.red]))
            }
            cell.set(symbol: MoreWorkspaceRoot.statusSymbol(change.status),
                     tint: deleted ? HQPalette.red : added ? .systemGreen : HQPalette.orange,
                     name: name,
                     columns: [(NSAttributedString(string: change.statusName, attributes: [.font: MacFilesTable.text, .foregroundColor: HQPalette.label2]),
                                .status), (lines, .lines)],
                     busy: false)
            cell.accessibilityIdentifier = "workspace.change.\(change.path)"
            cell.accessibilityLabel = "\(change.path), \(change.statusName), \(change.added) added, \(change.removed) removed"
            return cell
        case .entries(let entries):
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            var config = UIListContentConfiguration.cell().hqScaled()
            config.textProperties.numberOfLines = 0
            config.textProperties.font = HQFont.preferred(.body)
            config.textProperties.color = HQPalette.label
            config.directionalLayoutMargins.top = 12
            config.directionalLayoutMargins.bottom = 12
            cell.accessoryView = nil
            cell.accessibilityLabel = nil   // [mac] Mac polish #113: only a Mac file row names itself (its kind is an accessory)
            if let parent = parentRow, indexPath.row == 0 {
                config.text = "Enclosing Folder"
                config.secondaryText = space.display(parent)
                config.secondaryTextProperties.color = HQPalette.label2
                config.image = UIImage(systemName: "arrow.turn.left.up")
                config.imageProperties.tintColor = HQPalette.label2
                cell.hqDisclosure()   // [mac] Stress test 2026-10-28 #51 (round 6): the quiet Mac chevron
                cell.accessibilityIdentifier = "workspace.parent"
            } else if isChooser && entries.isEmpty {
                config.text = "No folders here"
                config.textProperties.color = HQPalette.label2
                cell.hqDisclosure(false)
                cell.selectionStyle = .none
                cell.accessibilityIdentifier = "workspace.no-folders"
            } else {
                let entry = entries[indexPath.row - (parentRow == nil ? 0 : 1)]
                config.text = entry.name
                config.image = UIImage(systemName: entry.isDirectory ? "folder.fill" : MoreWorkspaceRoot.opening(name: entry.name) == .text ? "doc.text" : "doc")
                config.imageProperties.tintColor = entry.isDirectory ? HQPalette.tint : HQPalette.label2
                cell.hqDisclosure()   // [mac] Stress test 2026-10-28 #51 (round 6): the quiet Mac chevron
                if DeviceWord.isMac {
                    // [mac] Stress test 2026-10-31 (#76 again): the chat's Files sheet's Finder-like row here too. One
                    // outline glyph style, the kind at the trailing edge, and a chevron only on a folder; this page
                    // still drew filled folders and a chevron on every file.
                    let kind = MediaKinds.kindWord(entry.name, isDirectory: entry.isDirectory)   // [mac] Mac polish #141: "Log File", not "LOG"
                    var row = UIListContentConfiguration.cell().hqScaled()
                    row.text = entry.name
                    row.textProperties.font = HQFont.preferred(.body)
                    row.textProperties.color = HQPalette.label
                    row.textProperties.numberOfLines = 1                     // [mac] Mac polish #113: the kind beside it, as the chat's Files
                    row.textProperties.lineBreakMode = .byTruncatingMiddle
                    row.image = UIImage(systemName: entry.isDirectory ? "folder" : MediaKinds.glyph(MediaKinds.kind(ofName: entry.name)))
                    row.imageProperties.tintColor = entry.isDirectory ? HQPalette.tint : HQPalette.label2
                    row.imageProperties.reservedLayoutSize = CGSize(width: HQFont.scaled(22), height: 0)
                    row.directionalLayoutMargins.top = config.directionalLayoutMargins.top
                    row.directionalLayoutMargins.bottom = config.directionalLayoutMargins.bottom
                    config = row
                    cell.accessoryType = .none
                    let fit = WorkspacePage.macKindFit(in: tableView, name: entry.name, kind: kind, chevron: entry.isDirectory, row: row)
                    cell.accessoryView = WorkspacePage.macKindAccessory(kind, room: fit.room, chevron: entry.isDirectory,
                                                                        busy: busyPath == entry.path, keepsArrowRoom: fit.keepsArrowRoom)
                    cell.accessibilityLabel = "\(entry.name), \(kind)"
                }
                cell.selectionStyle = .default
                if busyPath == entry.path, !DeviceWord.isMac {
                    let spinner = UIActivityIndicatorView(style: .medium)
                    spinner.startAnimating()
                    cell.accessoryView = spinner
                }
                cell.accessibilityIdentifier = "workspace.entry.\(entry.name)"
            }
            cell.contentConfiguration = config
            cell.backgroundConfiguration = nil
            return cell
        case .changes(let changes):
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            let change = changes[indexPath.row]
            let letter = MoreWorkspaceRoot.statusLetter(change.status)
            var config = UIListContentConfiguration.subtitleCell().hqScaled()
            config.text = change.path
            config.textProperties.numberOfLines = 0
            config.textProperties.font = HQFont.preferred(.body)
            config.textProperties.color = HQPalette.label
            config.secondaryText = "\(change.statusName) · \(MoreWorkspaceRoot.counts(added: change.added, removed: change.removed))"
            config.secondaryTextProperties.color = HQPalette.label2
            config.secondaryTextProperties.font = HQFont.preferred(.subheadline)
            config.directionalLayoutMargins.top = 12
            config.directionalLayoutMargins.bottom = 12
            let added = letter == "A" || letter == "?", deleted = letter == "D"
            config.image = UIImage(systemName: MoreWorkspaceRoot.statusSymbol(change.status))
            config.imageProperties.tintColor = deleted ? HQPalette.red : added ? .systemGreen : HQPalette.orange
            cell.contentConfiguration = config
            cell.backgroundConfiguration = nil
            cell.accessoryView = nil
            cell.hqDisclosure()   // [mac] Stress test 2026-10-28 #51 (round 6): the quiet Mac chevron
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "workspace.change.\(change.path)"
            cell.accessibilityLabel = "\(change.path), \(change.statusName), \(change.added) added, \(change.removed) removed"
            return cell
        }
    }

    private func stateCell(_ indexPath: IndexPath, configuration: UIContentUnavailableConfiguration, identifier: String) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "state", for: indexPath)
        var config = configuration
        // [mac] Stress test 2026-10-28 #9: in the row that fills the page, lifted as every page's state is.
        config.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 36, leading: 16, bottom: 36 + (DeviceWord.isMac ? 2 * MacInset.emptyLift : 0), trailing: 16)
        cell.contentConfiguration = config
        cell.backgroundConfiguration = .clear()
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = identifier
        return cell
    }

    private func menuButton(_ symbol: String, menu: UIMenu, label: String, identifier: String,
                            textStyle: UIFont.TextStyle = .body, leading: CGFloat = 10) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: textStyle))
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: leading, bottom: 10, trailing: 0)
        let button = UIButton(configuration: config)
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        button.tintColor = HQPalette.label2
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.sizeToFit()
        return button
    }

    private func rootCell(_ indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "root", for: indexPath) as! MoreWorkspaceRootCell
        if let root = space.root {
            cell.set(name: MoreWorkspaceRoot.name(root.path), path: space.display(root.path),
                     source: MoreWorkspaceRoot.sourceLine(root.source, chatTitle: space.chatTitle))
        } else if case .loading = content {
            cell.set(name: "Finding the Folder…", path: "", source: "")
        } else {
            cell.set(name: "No Folder", path: "", source: "Choose a folder to browse.")
        }
        // The bare ⋯ every row uses (the circled one is for bar buttons).
        cell.accessoryView = menuButton("ellipsis", menu: rootMenu(), label: "Folder Options", identifier: "workspace.root.menu")
        cell.accessibilityIdentifier = "workspace.root"
        return cell
    }

    private func botCell(_ indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "bot", for: indexPath)
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #55: the Bot picker row Capabilities, Messaging and Star Map draw (`MoreBotPicker`),
        // the same part, not a UIKit look-alike with its own text sizes.
        let selection = Binding<String>(get: { [weak self] in self?.space.profile ?? "" }, set: { [weak self] id in
            guard let self, id != self.space.profile else { return }
            PagesHaptics.selection()
            self.space.setProfile(id)
            self.reload()
        })
        cell.contentConfiguration = UIHostingConfiguration {
            MoreBotPicker(bots: space.bots, selection: selection, row: true)
        }
        .margins(.vertical, 0)   // [mac] Stress test 2026-10-28 round 6: the row sets its own height (`MoreBotPicker.macHeight`)
        // [mac] Stress test 2026-10-28 round 7: the List rows' own sides (16 leading, 6 trailing, `MoreBotPicker`), not the
        // table cell's layout margins, which put the label and menu 4 pt further in than on the other pages.
        .margins(.horizontal, 0)
        cell.accessoryView = nil
        cell.accessibilityIdentifier = "workspace.bot"
        return cell
        #else
        var config = UIListContentConfiguration.valueCell().hqScaled()
        config.text = "Bot"
        config.textProperties.font = HQFont.preferred(.body)
        config.textProperties.color = HQPalette.label
        // [ui-hunt] As MoreBotPicker draws it on Messaging, Star Map and Import Sessions: the bot's face, its name and
        // the chevrons in grey, as every menu row draws its value (this row had no face; UX study #102: one grey style).
        if let bot = space.bots.first(where: { $0.id == space.profile }) {
            let dark = traitCollection.userInterfaceStyle == .dark, scale = traitCollection.displayScale
            let face = BotFaces.shared.readyFace(profile: bot.id, raw: bot.head, side: 28, scale: scale, dark: dark, shape: .square)
            config.image = face?.image ?? BotFaces.shared.headImage(profile: bot.id, raw: bot.head, side: 28, scale: scale, dark: dark)
            config.imageProperties.maximumSize = CGSize(width: 28, height: 28)
            config.imageProperties.cornerRadius = face?.isPhoto == true ? 14 : 0     // a photo is a circle; a head keeps its shape
            config.imageToTextPadding = 12
        }
        config.secondaryText = space.context.botName(space.profile)
        config.secondaryTextProperties.color = HQPalette.label2
        config.secondaryTextProperties.font = HQFont.preferred(.body)
        config.prefersSideBySideTextAndSecondaryText = traitCollection.preferredContentSizeCategory.isAccessibilityCategory == false
        cell.contentConfiguration = config
        // The small grey chevrons beside the name, as a menu Picker draws its value (UX study #94: a body-sized pair in
        // label3 stood apart from the name). The whole row opens the menu (didSelectRowAt).
        let picker = menuButton("chevron.up.chevron.down", menu: botMenu(), label: "Choose Bot", identifier: "more.bot-picker",
                                textStyle: .footnote, leading: 4)
        cell.accessoryView = picker
        cell.accessibilityIdentifier = "workspace.bot"
        return cell
        #endif
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if !isTable { tableView.deselectRow(at: indexPath, animated: true) }   // [mac-tools] the table marks the file on show
        if indexPath.section < contentSection {
            // The whole row opens its menu, not just the button at its end.
            (tableView.cellForRow(at: indexPath)?.accessoryView as? UIButton)?.performPrimaryAction()
            return
        }
        switch content {
        case .entries(let entries):
            if let parent = parentRow, indexPath.row == 0 {
                PagesHaptics.selection()
                pushChooser(parent, animated: true)
                return
            }
            let index = indexPath.row - (parentRow == nil ? 0 : 1)
            guard entries.indices.contains(index) else { return }
            let entry = entries[index]
            PagesHaptics.selection()
            if isChooser {
                pushChooser(entry.path, animated: true)
            } else if entry.isDirectory, isTable {
                browse(entry.path)   // [mac-tools] in place, the trail leads back
            } else if entry.isDirectory {
                navigationController?.pushViewController(MoreWorkspaceController(space: space, mode: .folder(entry.path)), animated: true)
            } else {
                open(entry)
            }
        case .changes(let changes):
            guard changes.indices.contains(indexPath.row), let directory else { return }
            let change = changes[indexPath.row]
            PagesHaptics.selection()
            let workspace = space.workspace
            let page = MoreWorkspaceTextPage(title: (change.path as NSString).lastPathComponent, diff: true, notice: nil) {
                let diff = try await workspace.diff(in: directory, file: change)
                return diff.isEmpty ? "No differences to show." : diff
            }
            navigationController?.pushViewController(page, animated: true)
            if isTable { mark(change.path, page: page) }
        default:
            break
        }
    }

    // MARK: The row's menu and drag (Mac)

    /// [mac-audit] What a Files or Changes row holds.
    private enum RowFile {
        case entry(WorkspaceEntry)
        case change(WorkspaceChange)
    }

    private func rowFile(at indexPath: IndexPath) -> RowFile? {
        guard indexPath.section == contentSection, !isChooser else { return nil }
        switch content {
        case .entries(let entries):
            return entries.indices.contains(indexPath.row) ? .entry(entries[indexPath.row]) : nil
        case .changes(let changes):
            return changes.indices.contains(indexPath.row) ? .change(changes[indexPath.row]) : nil
        default:
            return nil
        }
    }

    /// A changed file's whole path (the list names it from the repository's root; the page's folder if that's unknown).
    private func fullPath(_ change: WorkspaceChange) -> String? {
        if change.path.hasPrefix("/") { return change.path }
        guard let base = repoRoot ?? directory else { return nil }
        return (base.hasSuffix("/") ? base : base + "/") + change.path
    }

    /// The file a row stands for, when it has one to hand over (not a folder, not a deleted change).
    private func handedPath(_ file: RowFile) -> String? {
        switch file {
        case .entry(let entry): return entry.isDirectory ? nil : entry.path
        case .change(let change): return MoreWorkspaceRoot.statusLetter(change.status) == "D" ? nil : fullPath(change)
        }
    }

    /// [mac-audit] Owner 2026-11-02 (Mac audit J2): a row's right-click menu on the Mac: Open (as a click), Save As…,
    /// Copy Path, Share… (a folder: Open and Copy Path; a deleted file: Open and Copy Path). The phone has no menu here.
    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        guard DeviceWord.isMac, let file = rowFile(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.rowMenu(file, at: indexPath)
        }
    }

    func rowMenu(at indexPath: IndexPath) -> UIMenu? { rowFile(at: indexPath).map { rowMenu($0, at: indexPath) } }

    private func rowMenu(_ file: RowFile, at indexPath: IndexPath) -> UIMenu {
        let open = UIAction(title: "Open", image: UIImage(systemName: "arrow.up.right.square")) { [weak self] _ in
            guard let self else { return }
            self.tableView(self.tableView, didSelectRowAt: indexPath)
        }
        let shown: String?
        switch file {
        case .entry(let entry): shown = entry.path
        case .change(let change): shown = fullPath(change)
        }
        var items: [UIMenuElement] = [open]
        if let path = handedPath(file) {
            let name = (path as NSString).lastPathComponent
            items.append(FileSaver.action { [weak self] in
                self?.handOver(path, failure: "Couldn’t Save This File") { url, host in FileSaver.present(url, from: host) }
            })
            items.append(UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copy(path) })
            items.append(UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.handOver(path, failure: "Couldn’t Share This File") { [weak self] url, host in
                    let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    if let popover = sheet.popoverPresentationController {
                        // The row (found again: the list may have been read again since the menu opened).
                        let row = self?.row(showing: path)
                        popover.sourceView = row ?? host.view
                        if let row { popover.sourceRect = row.bounds }
                    }
                    host.present(sheet, animated: true)
                }
            })
            AppLog.trace("pages", "workspace row menu (\(name.isEmpty ? "file" : "." + (name as NSString).pathExtension))")
        } else if let shown {
            items.append(UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copy(shown) })
        }
        return UIMenu(children: items)
    }

    private func copy(_ path: String) {
        UIPasteboard.general.string = path
        PagesHaptics.success()
        PagesHUD.show("Copied", symbol: "doc.on.doc", from: self)
    }

    /// The row showing `path` now, if it's on screen.
    private func row(showing path: String) -> UIView? {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            if let file = rowFile(at: indexPath), handedPath(file) == path { return tableView.cellForRow(at: indexPath) }
        }
        return nil
    }

    /// Downloads `path` (the row's spinner while it does, a newer one supersedes it) and hands the file over.
    private func handOver(_ path: String, failure: String, _ deliver: @escaping (URL, UIViewController) -> Void) {
        opening?.cancel()
        setBusy(path)
        let space = self.space
        opening = Task { [weak self] in
            do {
                let url = try await space.fetch(path)
                guard !Task.isCancelled, let self else { return }
                self.setBusy(nil)
                deliver(url, self)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self else { return }
                self.setBusy(nil)
                FailureAlert.present(title: failure, reason: MoreWorkspace.openFailure(error), from: self, whole: true)
            }
        }
    }

    // MARK: Opening a file

    private func setBusy(_ path: String?) {
        let old = busyPath
        busyPath = path
        guard case .entries(let entries) = content else { return }
        let rows = [old, path].compactMap { $0 }.compactMap { target in entries.firstIndex { $0.path == target } }
            .map { IndexPath(row: $0 + (parentRow == nil ? 0 : 1), section: contentSection) }
        if !rows.isEmpty { tableView.reloadRows(at: rows, with: .none) }
        if isTable, path == nil, markedPath != nil { restoreMark() }
    }

    /// A click that opened nothing beside the table: the row it selected is let go, and the open file's marked again.
    private func restoreOrClearMark() {
        if let selected = tableView.indexPathForSelectedRow { tableView.deselectRow(at: selected, animated: false) }
        restoreMark()
    }

    /// A text file is read and shown (with the notice when only its start is shown); anything else is downloaded
    /// and opened in Quick Look. A newer tap supersedes the one before it.
    private func open(_ entry: WorkspaceEntry) {
        opening?.cancel()
        setBusy(entry.path)
        let space = self.space
        opening = Task { [weak self] in
            do {
                if MoreWorkspaceRoot.opening(name: entry.name) == .text {
                    let file = try await space.workspace.readText(entry.path)
                    guard !Task.isCancelled, let self else { return }
                    if !file.binary {
                        // A Markdown file reads formatted (Preview | Source), as in the chat's Files; one the gateway
                        // cut short is downloaded whole first when the viewer can take it (it read raw before); if that
                        // fails, its start reads as before.
                        var markdown: String?
                        if WorkspacePage.isMarkdown(entry.name) {
                            if !file.truncated {
                                markdown = file.text
                            } else if let size = file.byteSize, size <= ArtifactFiles.textLimit {
                                markdown = (try? await space.download(entry.path)).flatMap { String(data: $0, encoding: .utf8) }
                                guard !Task.isCancelled else { return }
                            }
                        }
                        self.setBusy(nil)
                        let share: () async throws -> Any = {
                            // Mac polish #47: a file shown only in part is fetched whole as Save As… fetches it (streamed on the Mac).
                            if file.truncated { return try await space.fetch(entry.path) }
                            let url = space.cacheURL(entry.path)
                            try await ArtifactFiles.save(Data(file.text.utf8), to: url)
                            return url
                        }
                        if let markdown {
                            let viewer = ArtifactTextViewController(title: entry.name, markdown: true, language: nil) { markdown }
                            viewer.shareItem = share
                            self.navigationController?.pushViewController(viewer, animated: true)
                            if self.isTable { self.mark(entry.path, page: viewer) }
                            return
                        }
                        let notice = file.truncated ? MoreWorkspaceRoot.truncatedNotice(byteSize: file.byteSize) : nil
                        let page = MoreWorkspaceTextPage(title: entry.name, diff: false, notice: notice) { file.text }
                        page.share = share
                        self.navigationController?.pushViewController(page, animated: true)
                        if self.isTable { self.mark(entry.path, page: page) }
                        return
                    }
                }
                let url = try await space.fetch(entry.path)   // Mac polish #47: streamed on the Mac, past 32 MB too
                guard !Task.isCancelled, let self else { return }
                self.setBusy(nil)
                if self.isTable { self.restoreOrClearMark() }   // it opens in a window of its own: the mark stays where it was
                QuickLookPresenter.present(url: url, from: self)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self else { return }
                self.setBusy(nil)
                if self.isTable { self.restoreOrClearMark() }
                FailureAlert.present(title: "Couldn’t Open This File", reason: MoreWorkspace.openFailure(error), from: self, whole: true)
            }
        }
    }
}

#if targetEnvironment(macCatalyst)
/// [mac-audit] Owner 2026-11-02 (Mac audit J2): a Files or Changes row dragged out of the app is its file, downloaded
/// when the drop asks for it (FileSaver.dragProvider, as a chat's file card); folders and deleted files don't lift.
extension MoreWorkspaceController: UITableViewDragDelegate {
    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        dragItems(at: indexPath)
    }

    func dragItems(at indexPath: IndexPath) -> [UIDragItem] {
        guard let file = rowFile(at: indexPath), let path = handedPath(file) else { return [] }
        let space = self.space
        let name = (path as NSString).lastPathComponent
        AppLog.trace("pages", "workspace file drag started")
        // Mac polish 2026-11-06 #47: a drop that gets nothing says why, in the page's own alert (as Save As… does).
        let failed: @MainActor (Error) -> Void = { [weak self] error in
            guard let self, (self.view.window ?? self.navigationController?.view.window) != nil else { return }
            FailureAlert.present(title: "Couldn’t Drop This File", reason: MoreWorkspace.openFailure(error), from: self, whole: true)
        }
        return [UIDragItem(itemProvider: FileSaver.dragProvider(name: name.isEmpty ? "file" : name, failed: failed) {
            try await space.fetch(path)
        })]
    }
}
#endif

// MARK: - The root's header row

/// The folder shown: its name, its path (home as "~", cut in the middle when long) and where it comes from.
final class MoreWorkspaceRootCell: UITableViewCell {
    private let nameLabel = UILabel()
    private let pathLabel = UILabel()
    private let sourceLabel = UILabel()
    private let icon = UIImageView()
    private let row = UIStackView()
    /// [folder-card] Owner 2026-11-10 (design pick 27): the name and the path share a line when both fit whole, so the
    /// card is two lines (name and path, then where the folder comes from) where it was three or four. A path too
    /// long for that keeps its own lines under the name, wrapping after a '/', never cut.
    private let head = UIStackView()

    override func layoutSubviews() {
        super.layoutSubviews()
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let room = head.bounds.width
        let name = nameLabel.intrinsicContentSize.width
        let path = (pathLabel.text ?? "").replacingOccurrences(of: "\u{200B}", with: "")
        let pathWidth = pathLabel.isHidden ? 0 : ceil((path as NSString).size(withAttributes: [.font: pathLabel.font as Any]).width)
        let beside = !large && room > 0 && name + 8 + pathWidth <= room
        let axis: NSLayoutConstraint.Axis = beside ? .horizontal : .vertical
        if head.axis != axis {
            head.axis = axis
            head.alignment = beside ? .firstBaseline : .fill
            head.spacing = beside ? 8 : 2
            setNeedsLayout()
        }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        icon.tintColor = HQPalette.tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        nameLabel.font = HQFont.preferred(.headline)
        nameLabel.textColor = HQPalette.label
        nameLabel.numberOfLines = 2
        // [mac] Stress test 2026-10-28 round 6: a folder path is monospaced, as Chat Info draws one ("/fixture" was
        // proportional here and monospaced there).
        pathLabel.font = HQFont.monoFace(ofSize: HQFont.preferred(.subheadline).pointSize)
        pathLabel.textColor = HQPalette.label2
        pathLabel.lineBreakMode = .byWordWrapping          // a long path wraps after a '/' (see `set`); it is never cut
        pathLabel.numberOfLines = 0
        sourceLabel.font = HQFont.preferred(.footnote)
        sourceLabel.textColor = HQPalette.label2
        sourceLabel.numberOfLines = 0
        for label in [nameLabel, pathLabel, sourceLabel] { label.adjustsFontForContentSizeCategory = true; label.lineBreakStrategy = [] }
        pathLabel.adjustsFontForContentSizeCategory = false   // its monospaced font is set again in applyTextSize
        head.axis = .vertical
        head.spacing = 2
        head.addArrangedSubview(nameLabel)
        head.addArrangedSubview(pathLabel)
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let words = UIStackView(arrangedSubviews: [head, sourceLabel])
        words.axis = .vertical
        words.spacing = 2
        row.addArrangedSubview(icon)
        row.addArrangedSubview(words)
        row.translatesAutoresizingMaskIntoConstraints = false
        applyTextSize()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: MoreWorkspaceRootCell, _) in cell.applyTextSize() }
        contentView.addSubview(row)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// At accessibility sizes the folder sits above the words, which get the card's width, and stops growing at
    /// 28 pt (UX study #98: beside a quarter-width icon the path broke letter by letter).
    private func applyTextSize() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let symbol = large ? UIImage.SymbolConfiguration(pointSize: 28) : UIImage.SymbolConfiguration(textStyle: .title3)
        // [mac] Mac polish 2026-11-06 #114: the outline folder the rows under it have (Stress test 2026-10-28 #76), not
        // a filled one above them.
        icon.image = UIImage(systemName: DeviceWord.isMac ? "folder" : "folder.fill", withConfiguration: symbol)
        pathLabel.font = HQFont.monoFace(ofSize: HQFont.preferred(.subheadline).pointSize)
        row.axis = large ? .vertical : .horizontal
        row.alignment = large ? .leading : .center
        row.spacing = large ? 8 : 14
    }

    func set(name: String, path: String, source: String) {
        nameLabel.text = name
        // A break is allowed only after a '/', so a folder's name is never split mid-word; VoiceOver reads the path.
        pathLabel.text = path.replacingOccurrences(of: "/", with: "/\u{200B}")
        pathLabel.accessibilityLabel = path
        pathLabel.isHidden = path.isEmpty
        pathLabel.accessibilityIdentifier = "workspace.root.path"
        nameLabel.accessibilityIdentifier = "workspace.root.name"
        sourceLabel.text = source
        sourceLabel.isHidden = source.isEmpty
        sourceLabel.accessibilityIdentifier = "workspace.root.source"
    }
}

// MARK: - A file's text or a change's diff

/// The chat's `WorkspaceTextPage` (monospace, selectable, a diff's lines tinted) with what More adds around it: the
/// notice when only a file's start is shown, and Share in the bar.
final class MoreWorkspaceTextPage: UIViewController {
    private let diff: Bool
    private let notice: String?
    private let loader: () async throws -> String
    private var text: String?
    /// What Share hands over (a file URL); nil shares the text itself.
    var share: (() async throws -> Any)?
    private var shareItem: UIBarButtonItem?

    init(title: String, diff: Bool, notice: String?, loader: @escaping () async throws -> String) {
        self.diff = diff
        self.notice = notice
        self.loader = loader
        super.init(nibName: nil, bundle: nil)
        self.title = title
        navigationItem.largeTitleDisplayMode = .never
        hidesBottomBarWhenPushed = true   // as a Markdown file's page (Preview | Source) and Artifacts' viewer do
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.page
        view.accessibilityIdentifier = diff ? "more.review.diff" : "more.files.text"
        let loader = self.loader
        let page = WorkspaceTextPage(title: title ?? "", diff: diff) { [weak self] in
            let text = try await loader()
            self?.text = text
            self?.shareItem?.isEnabled = true
            if text.utf16.count > Self.spokenLimit { self?.boundSpokenValue(text) }
            return text
        }
        addChild(page)
        page.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page.view)
        var top = page.view.topAnchor.constraint(equalTo: view.topAnchor)
        if let notice {
            let banner = Self.banner(notice)
            view.addSubview(banner)
            NSLayoutConstraint.activate([
                banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            top = page.view.topAnchor.constraint(equalTo: banner.bottomAnchor)
        }
        NSLayoutConstraint.activate([
            top,
            page.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        page.didMove(toParent: self)

        let item = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), primaryAction: UIAction { [weak self] _ in self?.shareNow() })
        item.accessibilityLabel = "Share"
        item.accessibilityIdentifier = "workspace.share"
        item.isEnabled = false
        navigationItem.rightBarButtonItem = item
        shareItem = item
    }

    /// A very long file's text is not handed to assistive apps as one value (hundreds of kilobytes in one string stall
    /// them); they get its start, and the text itself stays readable line by line.
    static let spokenLimit = 20_000

    private func boundSpokenValue(_ text: String) {
        let start = String(text.prefix(2_000))
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let field = self?.children.first?.view.subviews.compactMap({ $0 as? UITextView }).first else { return }
            field.accessibilityValue = start + "…"
        }
    }

    /// "Showing the first 512 KB of 3 MB." under the bar, above the text.
    private static func banner(_ text: String) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = HQFont.preferred(.footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = HQPalette.label2
        label.numberOfLines = 0
        label.accessibilityIdentifier = "workspace.truncated"
        label.translatesAutoresizingMaskIntoConstraints = false
        let line = UIView()
        line.backgroundColor = HQPalette.separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let banner = UIView()
        banner.backgroundColor = HQPalette.groupedPage     // a band above the text's plain page
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(label)
        banner.addSubview(line)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: banner.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: banner.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: banner.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            line.heightAnchor.constraint(equalToConstant: 0.5),
            line.bottomAnchor.constraint(equalTo: banner.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
        ])
        return banner
    }

    private func shareNow() {
        guard let text, let item = shareItem else { return }
        item.isEnabled = false
        let share = self.share
        Task { [weak self] in
            var what: Any = text
            var failure: Error?
            if let share {
                do { what = try await share() } catch { failure = error }
            }
            guard let self else { return }
            item.isEnabled = true
            if let failure {
                FailureAlert.present(title: "Couldn’t Share This File", reason: MoreWorkspace.openFailure(failure), from: self, whole: true)
                return
            }
            let sheet = UIActivityViewController(activityItems: [what], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceItem = item
            self.present(sheet, animated: true)
        }
    }
}

#if DEBUG && targetEnvironment(macCatalyst)
extension MoreWorkspaceController {
    /// [mac-tools] `-HQDebugMacShotsFilesTable`: a click on the row named `name` (a change's path), or on a crumb.
    func debugClick(_ name: String) {
        var row: Int?
        switch content {
        case .entries(let entries): row = entries.firstIndex { $0.name == name }
        case .changes(let changes): row = changes.firstIndex { $0.path == name }
        case .loading, .state: break
        }
        guard let row else { print("files tour: no row \(name)"); return }
        let path = IndexPath(row: row, section: contentSection)
        tableView.selectRow(at: path, animated: false, scrollPosition: .none)
        tableView(tableView, didSelectRowAt: path)
    }

    func debugCrumb(_ index: Int) {
        guard let root = space.root?.path, index == 0 else { return }
        browse(root)
    }

    /// [mac-audit] `-HQDebugMacShotsFiles` (MacShots): each list row's menu and drag provider, as (label, menu, provider).
    func debugRows() -> [(String, UIMenu, NSItemProvider?)] {
        guard tableView.numberOfSections > 0 else { return [] }
        let section = tableView.numberOfSections - 1
        return (0..<tableView.numberOfRows(inSection: section)).compactMap { row in
            let path = IndexPath(row: row, section: section)
            guard let menu = rowMenu(at: path) else { return nil }
            let label = (tableView.cellForRow(at: path)?.contentConfiguration as? UIListContentConfiguration)?.text ?? "row \(row)"
            return (label, menu, dragItems(at: path).first?.itemProvider)
        }
    }
}
#endif
