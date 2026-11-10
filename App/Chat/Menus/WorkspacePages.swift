import UIKit

/// ⋯ › More › Files and Changes (parity 240 §8): the chat's folder as simple native lists in a sheet. Files lists the
/// folder (folders first; a folder opens its own list, a text file its text, a photo, PDF or other file Quick Look or
/// the share sheet); Changes lists the uncommitted changes with their added and removed lines, and a change opens its
/// diff. Read-only, as on the web's phone. A Markdown file reads formatted, with Preview | Source.
final class WorkspacePage: UITableViewController {
    enum Kind { case files, changes }

    private enum Content {
        case loading
        /// The chat has no working folder yet: nothing failed, so there is nothing to try again.
        case noFolder
        case failed(String)
        case entries([WorkspaceEntry])
        case changes([WorkspaceChange])
    }

    private let kind: Kind
    private let workspace: ChatWorkspace
    private let directory: String?
    /// Where a file that isn't text is downloaded from (the chat's account and profile); nil keeps such files closed.
    private let media: MediaContext?
    private var content: Content = .loading { didSet { render() } }
    private var load: Task<Void, Never>?
    /// [mac] Stress test 2026-10-28 #76: a ⌘R refresh ends in "Refreshed" (a list that hadn't changed showed no sign
    /// that anything happened; the pull's spinner never shows for a key).
    private var announceRefresh = false
    /// An entry to open once the folder has listed (a path a bot named whose name doesn't say file or folder).
    private var reveal: String?
    /// [transcript] The files card's own file, or one held for "Review in Changes" (§12, n20 F10): scrolled to and
    /// flashed once Changes has loaded; nothing when it doesn't match (`ChangedFiles.match`).
    private var highlight: String?
    /// [inspector] The Mac's right panel shows this list in the panel's own look (`InspectorLook`): no card, the path as
    /// a short grey trail above the rows, the panel's text size.
    private let panel: Bool

    init(kind: Kind, workspace: ChatWorkspace, directory: String?, media: MediaContext? = nil, reveal: String? = nil,
        highlight: String? = nil, panel: Bool = false) {
        self.panel = panel
        self.kind = kind
        self.workspace = workspace
        self.directory = directory
        self.media = media
        self.reveal = reveal
        self.highlight = highlight
        super.init(style: panel ? .plain : .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The page in its sheet (the ✕ leading, as every sheet).
    static func make(_ kind: Kind, workspace: ChatWorkspace, directory: String?, media: MediaContext? = nil, highlight: String? = nil) -> UINavigationController {
        let root = WorkspacePage(kind: kind, workspace: workspace, directory: directory, media: media, highlight: highlight)
        return ChatSheet.wrap(root, title: kind == .files ? "Files" : "Changes", detents: [.large()])
    }

    /// Files opened at a path a bot named in its reply (`FileLinks`): the file on top of its folder's list (Back shows
    /// the folder). A name without an extension may be a folder or a file (Makefile): the folder lists first, then
    /// opens it.
    static func make(path: String, workspace: ChatWorkspace, media: MediaContext?) -> UINavigationController {
        let (folder, name) = FileLinks.place(path)
        guard let name, !name.isEmpty else { return make(.files, workspace: workspace, directory: folder, media: media) }
        let sure = FileLinks.hasExtension(name)
        let root = WorkspacePage(kind: .files, workspace: workspace, directory: folder, media: media, reveal: sure ? nil : name)
        let sheet = ChatSheet.wrap(root, title: "Files", detents: [.large()])
        if sure { sheet.pushViewController(root.filePage(WorkspaceEntry(name: name, path: path, isDirectory: false)), animated: false) }
        AppLog.trace("chatui", "file link opened in Files (\(sure ? "file" : "folder or file"))")
        return sheet
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = kind == .files ? "workspace.files" : "workspace.changes"
        tableView.backgroundColor = HQPalette.sheetPage   // [desktoplook] the page follows the skin
        if panel { InspectorLook.dress(tableView) }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        if let directory, kind == .files, navigationController?.viewControllers.first !== self {
            title = (directory as NSString).lastPathComponent
        }
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        tableView.hqInstallRefresh(refresh)
        reload()
    }

    deinit { load?.cancel() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !panel { DesktopTableOutliner.attach(to: tableView) }   // Stress test 2026-10-28 #56: the look's outlined box, not iOS's card
        kindRoom = Self.refitKinds(in: tableView, fitted: kindRoom)   // [mac] Mac polish #113 (review)
    }

    /// [mac] Mac polish #113 (review): the room the rows' kinds were last fitted to (`refitKinds`).
    private var kindRoom: CGFloat = 0

    private func reload() {
        guard let directory, !directory.isEmpty else {
            content = .noFolder
            tableView.refreshControl?.endRefreshing()
            return
        }
        load?.cancel()
        if case .failed = content { content = .loading }
        let workspace = self.workspace, kind = self.kind
        load = Task { [weak self] in
            do {
                let next: Content = kind == .files ? .entries(try await workspace.list(directory))
                    : .changes(try await workspace.changes(in: directory))
                guard !Task.isCancelled else { return }
                self?.content = next
                if let self, self.announceRefresh {
                    self.announceRefresh = false
                    MenusHUD.show("Refreshed", in: self.navigationController?.view ?? self.view)
                }
                self?.revealNamed()
                self?.highlightNamed()
            } catch {
                guard !Task.isCancelled else { return }
                self?.content = .failed(MenusError.text(error))
                self?.announceRefresh = false   // the failure shows on the page
            }
            self?.tableView.refreshControl?.endRefreshing()
        }
    }

    private func render() {
        var empty: UIContentUnavailableConfiguration?
        switch content {
        case .loading:
            empty = .loading()
        case .noFolder:
            var config = UIContentUnavailableConfiguration.empty().hqScaled()
            config.image = UIImage(systemName: "folder")
            config.text = "No Folder Yet"
            config.secondaryText = kind == .files ? "This chat has no folder on \(HostWord.phrase) yet. Its files show here once it has one."
                : "This chat has no folder on \(HostWord.phrase) yet. Its changes show here once it has one."
            empty = config
        case .failed(let reason):
            var config = UIContentUnavailableConfiguration.empty().hqScaled()
            config.image = UIImage(systemName: "exclamationmark.triangle")
            config.text = kind == .files ? "Couldn’t Load Files" : "Couldn’t Load Changes"
            config.secondaryText = reason
            var retry = UIButton.Configuration.hqPush()
            retry.title = "Try Again"
            config.button = retry
            config.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.reload() }
            empty = config
        case .entries(let entries) where entries.isEmpty:
            var config = UIContentUnavailableConfiguration.empty().hqScaled()
            config.image = UIImage(systemName: "folder")
            config.text = "Empty Folder"
            empty = config
        case .changes(let changes) where changes.isEmpty:
            var config = UIContentUnavailableConfiguration.empty().hqScaled()
            config.image = UIImage(systemName: "checkmark.circle")
            config.text = "No Changes"
            config.secondaryText = "Nothing has changed in this chat’s folder since its last saved version."
            empty = config
        default:
            break
        }
        contentUnavailableConfiguration = empty
        if panel { tableView.tableHeaderView = empty == nil ? trail() : nil }
        tableView.reloadData()
    }

    /// [inspector] The folder as a trail above the panel's rows ("hermes › app"): its last three names, the folder
    /// itself in the label colour. The whole path was a monospaced header cut in the middle.
    private func trail() -> UIView? {
        guard let directory, case .entries = content else { return nil }
        let names = directory.split(separator: "/").suffix(3).map(String.init)
        guard let last = names.last else { return nil }
        let text = NSMutableAttributedString(string: names.dropLast().map { $0 + " › " }.joined(),
                                             attributes: [.foregroundColor: ChatPalette.label2])
        text.append(NSAttributedString(string: last, attributes: [.foregroundColor: ChatPalette.label]))
        let view = InspectorLook.summary(text)
        view.accessibilityLabel = directory
        return view
    }

    /// Opens the entry a bot's path named, once the list has it; says so when the folder doesn't.
    private func revealNamed() {
        guard let name = reveal, case .entries(let entries) = content else { return }
        reveal = nil
        if let entry = entries.first(where: { $0.name == name }) {
            open(entry, animated: true)
        } else {
            MenusHUD.show("Couldn’t find \(name) here", symbol: "questionmark.folder", in: navigationController?.view ?? view, seconds: 2.5)
        }
    }

    /// [transcript] The change a card named, once Changes has it (§12, n20 F10): scrolled to and flashed, as tapping
    /// a search result does. Quiet when it doesn't match — a path the card showed that this folder's Changes, for
    /// whatever reason (a different base, a path already committed), doesn't carry.
    private func highlightNamed() {
        guard let path = highlight, case .changes(let changes) = content else { return }
        highlight = nil
        guard let matched = ChangedFiles.match(path, in: changes.map(\.path)),
              let row = changes.firstIndex(where: { $0.path == matched }) else { return }
        let indexPath = IndexPath(row: row, section: 0)
        tableView.scrollToRow(at: indexPath, at: .middle, animated: true)
        tableView.selectRow(at: indexPath, animated: true, scrollPosition: .none)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.tableView.deselectRow(at: indexPath, animated: true)
        }
    }

    // MARK: Rows

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch content {
        case .entries(let entries): return entries.count
        case .changes(let changes): return changes.count
        default: return 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let directory, !panel else { return nil }
        // Stress test 2026-10-28 #77: the path headed the "No Changes" notice too, a header over nothing.
        switch content {
        case .entries(let entries) where !entries.isEmpty: return directory
        case .changes(let changes) where !changes.isEmpty: return directory
        default: return nil
        }
    }

    /// [mac] Stress test 2026-10-28 round 7: the folder path over the rows is a path, so it reads in the monospaced face
    /// (as Changes' diff and the text viewer do), at the header's own size and case.
    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard DeviceWord.isMac, let header = view as? UITableViewHeaderFooterView else { return }
        var config = (header.contentConfiguration as? UIListContentConfiguration) ?? header.defaultContentConfiguration()
        config.text = self.tableView(tableView, titleForHeaderInSection: section)
        config.textProperties.font = HQFont.monoFace(ofSize: config.textProperties.font.pointSize, weight: .regular)
        config.textProperties.transform = .none
        config.textProperties.lineBreakMode = .byTruncatingMiddle
        config.textProperties.numberOfLines = 1
        header.contentConfiguration = config
    }

    /// [mac] Mac polish 2026-11-06 #113: a Files row's kind and its chevron (or the chevron's room, `hqDisclosure`'s
    /// `keepsRoom`), side by side at the row's trailing edge. As the row's secondary text the kind dropped under a name
    /// that left it no room (README.md in the narrow inspector), a row taller than the rest; beside the chevron it keeps
    /// its line and the name is cut short in the middle instead, as the Finder cuts one. Both sit where the value and
    /// the lone chevron stood: a table puts a lone image 8 pt further in than any other accessory, so the stack keeps
    /// those 8 pt, and the chevron is centred by its frame as the lone one is. `busy`: a spinner in the chevron's place.
    /// `room` (`macKindRoom`, 0 for no limit): the most the kind may take. A longer one says its first word
    /// ("PowerPoint", "Environment"), and one still too long is cut at the end, so the name keeps the rest of the row.
    /// `keepsArrowRoom` false (`macKindFit`): a file row whose name needs it doesn't keep the hidden arrow's room.
    static func macKindAccessory(_ kind: String, room: CGFloat = 0, chevron: Bool, busy: Bool = false,
                                 keepsArrowRoom: Bool = true, font: UIFont? = nil) -> UIView {
        let label = UILabel()
        label.text = kind
        label.font = font ?? HQFont.preferred(.body)
        label.textColor = ChatPalette.label2
        if room > 0 {
            if label.intrinsicContentSize.width > room, let first = kind.split(separator: " ").first, first.count < kind.count {
                label.text = String(first)
            }
            // [mac-ui-issues] A word that still doesn't fit is left out, not cut ("CHANGELOG.md Mark…" in the inspector).
            if label.intrinsicContentSize.width > room + 0.5 { label.text = nil }
            label.lineBreakMode = .byTruncatingTail
            label.widthAnchor.constraint(lessThanOrEqualToConstant: room).isActive = true
        }
        let mark: UIView
        if busy {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            mark = spinner
        } else {
            let image = MacChevron.view()
            image.image = image.image?.withAlignmentRectInsets(.zero)
            image.alpha = chevron ? 1 : 0
            mark = image
        }
        let stack = UIStackView(arrangedSubviews: chevron || busy || keepsArrowRoom ? [label, mark] : [label])
        stack.alignment = .center
        stack.spacing = 16
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8)
        stack.frame.size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return stack
    }

    /// [mac] Mac polish 2026-11-06 #113 (review): the room a Files row's kind may take, a third of the row, so the name
    /// keeps most of it. In the narrow inspector "Markdown" left README.md a few letters, and #141's longer words
    /// ("PowerPoint Presentation", "Environment File") would have left a name almost none.
    static func macKindRoom(in table: UITableView) -> CGFloat {
        let margins = table.directionalLayoutMargins
        return max(0, ((table.bounds.width - margins.leading - margins.trailing) / 3).rounded(.down))
    }

    /// [mac] Mac polish #113 (follow-up): the kind's room in a row named `name` laid out by `row`, and whether a file's
    /// row keeps its hidden arrow's room. In the 340-pt inspector README.md was cut to "REA…E.md" beside a whole
    /// "Markdown" and an empty arrow's room: a name that fits whole beside its kind now gets that room first (the file
    /// row lets the arrow's room go, then the kind gives way to its first word or an ellipsis). A name too long to fit
    /// even so is cut in the middle beside its kind's third (`macKindRoom`), as before.
    static func macKindFit(in table: UITableView, name: String, kind: String, chevron: Bool,
                           row: UIListContentConfiguration, kindFont: UIFont? = nil) -> (room: CGFloat, keepsArrowRoom: Bool) {
        let third = macKindRoom(in: table)
        let margins = table.directionalLayoutMargins
        let font = row.textProperties.font
        func width(_ text: String, _ font: UIFont = font) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up) }
        // The row's width less the glyph, the name and the gaps around it, and the accessory's own 8 pt (a few points
        // spare, as the cell's own spacing is measured, not read).
        let lead = row.directionalLayoutMargins.leading + row.imageProperties.reservedLayoutSize.width + row.imageToTextPadding
        let spare = table.bounds.width - margins.leading - margins.trailing - lead - width(name)
            - row.directionalLayoutMargins.trailing - 8 - 8 - 4
        let arrow = 16 + (MacChevron.image?.size.width ?? 8)
        let natural = min(width(kind, kindFont ?? font), third)
        let least: CGFloat = 44
        if spare - arrow >= natural { return (min(third, spare - arrow), true) }
        if chevron { return spare - arrow >= least ? ((spare - arrow).rounded(.down), true) : (third, true) }
        if spare >= least { return (min(third, spare).rounded(.down), false) }
        return (third, true)
    }

    /// [mac] Mac polish #113 (review): the rows on show fit their kind (`macKindRoom`) again once the table's width
    /// changes, as when the window is resized. `fitted`: the room they were last fitted to; `include`: the rows to fit.
    /// Returns the room they are fitted to now.
    static func refitKinds(in table: UITableView, fitted: CGFloat, include: (IndexPath) -> Bool = { _ in true }) -> CGFloat {
        let room = macKindRoom(in: table)
        guard DeviceWord.isMac, room != fitted, !table.hasUncommittedUpdates else { return fitted }
        if let rows = table.indexPathsForVisibleRows?.filter(include), !rows.isEmpty { table.reconfigureRows(at: rows) }
        return room
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.accessibilityLabel = nil   // [mac] Mac polish #113: only a Mac Files row names itself (its kind is an accessory)
        var config = UIListContentConfiguration.subtitleCell().hqScaled()
        config.secondaryTextProperties.color = ChatPalette.label2
        config.textProperties.numberOfLines = 0
        switch content {
        case .entries(let entries) where DeviceWord.isMac:
            // [mac] Stress test 2026-10-28 #76: a Finder-like list row. One line at the list's height with the kind at
            // the trailing edge, one outline glyph style for folders and files (filled blue folders sat beside grey
            // outline files), and a chevron only where a click goes deeper (a folder). Hermes's folder listing has no
            // sizes or dates to show.
            let entry = entries[indexPath.row]
            let kind = MediaKinds.kindWord(entry.name, isDirectory: entry.isDirectory)   // [mac] Mac polish #141: "Log File", not "LOG"
            var row = UIListContentConfiguration.cell().hqScaled()
            row.text = entry.name
            row.textProperties.color = ChatPalette.label
            row.textProperties.numberOfLines = 1                     // [mac] Mac polish #113: the kind beside it (`macKindAccessory`)
            row.textProperties.lineBreakMode = .byTruncatingMiddle
            // [mac] Stress test 2026-10-31: the look's body, as Chat Info's rows have; the system's value cell kept
            // 17 pt, so under the Desktop Look this sheet's rows were a size bigger than every other sheet's.
            row.textProperties.font = panel ? InspectorLook.textFont : HQFont.preferred(.body)
            row.image = UIImage(systemName: entry.isDirectory ? "folder" : MediaKinds.glyph(MediaKinds.kind(ofName: entry.name)))
            row.imageProperties.tintColor = entry.isDirectory ? .tintColor : ChatPalette.label2
            row.imageProperties.reservedLayoutSize = CGSize(width: HQFont.scaled(22), height: 0)
            row.directionalLayoutMargins.top = panel ? 8 : 6
            row.directionalLayoutMargins.bottom = panel ? 8 : 6
            if panel {
                row.imageProperties.reservedLayoutSize = CGSize(width: HQFont.scaled(18), height: 0)
                row.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: InspectorLook.textFont)
                row.imageToTextPadding = 10
                cell.backgroundColor = .clear
            }
            cell.accessoryType = .none
            let kindFont = panel ? InspectorLook.detailFont : nil
            let fit = Self.macKindFit(in: tableView, name: entry.name, kind: kind, chevron: entry.isDirectory, row: row, kindFont: kindFont)
            cell.accessoryView = Self.macKindAccessory(kind, room: fit.room, chevron: entry.isDirectory, keepsArrowRoom: fit.keepsArrowRoom,
                                                       font: kindFont)
            cell.accessibilityLabel = "\(entry.name), \(kind)"
            cell.accessibilityIdentifier = "workspace.entry.\(entry.name)"
            cell.contentConfiguration = row
            return cell
        case .entries(let entries):
            let entry = entries[indexPath.row]
            config.text = entry.name
            config.image = UIImage(systemName: entry.isDirectory ? "folder.fill" : MediaKinds.glyph(MediaKinds.kind(ofName: entry.name)))
            config.imageProperties.tintColor = entry.isDirectory ? .tintColor : ChatPalette.label2
            cell.hqDisclosure()   // [mac] Stress test 2026-10-28 #51 (round 6): the quiet Mac chevron
            cell.accessibilityIdentifier = "workspace.entry.\(entry.name)"
        case .changes(let changes):
            let change = changes[indexPath.row]
            config.text = change.path
            // Item 18: leave out a zero side, as More › Changes does.
            config.secondaryText = "\(change.statusName) · \(MoreWorkspaceRoot.counts(added: change.added, removed: change.removed))"
            config.image = UIImage(systemName: change.status == "A" || change.status == "?" ? "plus.square"
                                   : change.status == "D" ? "minus.square" : "pencil.line")
            config.imageProperties.tintColor = change.status == "D" ? .systemRed : change.status == "A" || change.status == "?" ? .systemGreen : .tintColor
            cell.hqDisclosure()   // [mac] Stress test 2026-10-28 #51 (round 6): the quiet Mac chevron
            cell.accessibilityIdentifier = "workspace.change.\(change.path)"
        default:
            break
        }
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        Haptics.play(.selection)
        switch content {
        case .entries(let entries):
            open(entries[indexPath.row], animated: true)
        case .changes(let changes):
            let change = changes[indexPath.row]
            let workspace = self.workspace, directory = self.directory ?? ""
            navigationController?.pushViewController(WorkspaceTextPage(title: (change.path as NSString).lastPathComponent, diff: true) {
                let diff = try await workspace.diff(in: directory, file: change)
                return diff.isEmpty ? "No differences to show." : diff
            }, animated: true)
        default:
            break
        }
    }

    /// A folder opens its own list; a photo, PDF or other file that isn't text Quick Look; a text file its page.
    private func open(_ entry: WorkspaceEntry, animated: Bool) {
        if entry.isDirectory {
            let page = WorkspacePage(kind: .files, workspace: workspace, directory: entry.path, media: media, panel: panel)
            navigationController?.pushViewController(page, animated: animated)
        } else if Self.opensElsewhere(entry.name), media != nil {
            openElsewhere(entry)
        } else {
            navigationController?.pushViewController(filePage(entry), animated: animated)
        }
    }

    /// A text file's page: a Markdown file formatted (Preview | Source, as Artifacts reads a note; its links to other
    /// files open them here), anything else monospaced.
    private func filePage(_ entry: WorkspaceEntry) -> UIViewController {
        let workspace = self.workspace
        let read: () async throws -> String = {
            let file = try await workspace.readText(entry.path)
            if file.binary { throw WorkspaceTextPage.NotText() }
            return file.truncated ? file.text + "\n\n…" : file.text
        }
        // A file whose name doesn't say turns out not to be text: the page offers Quick Look instead.
        let fallback: (() -> Void)? = media == nil ? nil : { [weak self] in self?.openElsewhere(entry) }
        // Share hands over the file itself (report.md), not its words.
        let file: (() async throws -> Any)? = media.map { media in {
            try await MediaLoader.shared.file(path: entry.path, name: entry.name, context: media,
                                              progressKey: FilePreviewPresenter.progressKey(entry.path))
        } }
        guard Self.isMarkdown(entry.name) else {
            let page = WorkspaceTextPage(title: entry.name, diff: false, openElsewhere: fallback, loader: read)
            page.share = file
            return page
        }
        let viewer = ArtifactTextViewController(title: entry.name, markdown: true, language: nil, load: read)
        viewer.loadingText = "Loading \(entry.name)…"
        viewer.openInQuickLook = fallback
        viewer.shareItem = file
        viewer.linkOpener = { [weak self] target, fragment, from in
            let path = ArtifactLinks.linkedNotePath(from: entry.path, target: target)
            guard let self, !path.isEmpty else { return }
            if path == entry.path {
                if let fragment { from.scroll(toFragment: fragment) }   // a heading in this note: no new page
                return
            }
            let next = WorkspaceEntry(name: ArtifactLinks.name(path), path: path, isDirectory: false)
            if Self.opensElsewhere(next.name), self.media != nil { self.openElsewhere(next); return }
            let page = self.filePage(next)
            (page as? ArtifactTextViewController)?.pendingFragment = fragment
            from.navigationController?.pushViewController(page, animated: true)
        }
        return viewer
    }

    static func isMarkdown(_ name: String) -> Bool {
        ArtifactFiles.markdownExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    // MARK: Files that aren't text

    /// A photo, film, sound, PDF, sheet or archive by its name: never read as text.
    static func opensElsewhere(_ name: String) -> Bool {
        if HTMLPageSheet.opens(name: name) { return true }   // a page opens live (its scripts run), not as its source
        switch MediaKinds.kind(ofName: name) {
        case .image, .video, .audio, .pdf, .table, .archive: return true
        case .text, .folder, .other: return false
        }
    }

    /// Downloads the file ("Downloading…" while it comes), then Quick Look, or the share sheet for a type Quick Look
    /// can't show (as a file in a chat opens, FilePreviewPresenter).
    private func openElsewhere(_ entry: WorkspaceEntry) {
        guard let media else { return }
        // The sheet's navigation controller presents: this list may be under the text page that offered Quick Look.
        let host: UIViewController = navigationController ?? self
        let hud = MenusHUD.show("Downloading…", symbol: nil, in: host.view, seconds: nil)
        Task { [weak host] in
            do {
                let page = HTMLPageSheet.opens(name: entry.name)
                let url = try await MediaLoader.shared.file(path: entry.path, name: entry.name, context: media,
                                                            progressKey: FilePreviewPresenter.progressKey(entry.path), fresh: page)
                MenusHUD.hide(hud)
                guard let host, host.view.window != nil else { return }
                if page {
                    HTMLPageSheet.present(url, source: FilePreviewPresenter.pageSource(entry.path, media, from: host), from: host)
                } else {
                    FilePreviewPresenter.shared.openLocal(url, from: host, anchor: nil)
                }
            } catch {
                MenusHUD.hide(hud)
                guard !(error is CancellationError), let host, host.view.window != nil else { return }
                FilePreviewPresenter.alert((error as? MediaLoadError)?.fileMessage ?? MediaLoadError.unreachable.fileMessage, on: host)
            }
        }
    }
}

/// A file's text or a change's diff: monospace, selectable, read-only; a diff's added lines on a green wash and removed
/// on a red one, in the page's ink (green and red words on a white page read poorly). On the plain page and with Share
/// in the bar, as a Markdown file's page has (2026-10-29: this page was grey with Copy beside a white one with Share);
/// Share waits for the text.
final class WorkspaceTextPage: UIViewController {
    /// The loader's answer for a file that turns out not to be text.
    struct NotText: Error {}

    private let loader: () async throws -> String
    private let diff: Bool
    /// A file that isn't text opens there instead (Quick Look or the share sheet); nil: the page only says so.
    private let openElsewhere: (() -> Void)?
    private let textView = ChatLayoutManager.textView()   // a diff's lines washed across the page
    private var load: Task<Void, Never>?
    private var text: String?
    private var shareItem: UIBarButtonItem?
    /// What Share hands over (the file itself); nil, or a download that fails, shares the text.
    var share: (() async throws -> Any)?

    init(title: String, diff: Bool, openElsewhere: (() -> Void)? = nil, loader: @escaping () async throws -> String) {
        self.loader = loader
        self.diff = diff
        self.openElsewhere = openElsewhere
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { load?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.page
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 24, right: 16)
        textView.accessibilityIdentifier = diff ? "workspace.diff" : "workspace.text"
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), primaryAction: UIAction { [weak self] _ in
            self?.shareNow()
        })
        share.accessibilityLabel = "Share"
        share.accessibilityIdentifier = "workspace.share"
        share.isEnabled = false      // nothing to share while it loads, or after it couldn't
        navigationItem.rightBarButtonItem = share
        shareItem = share
        // The text follows a text-size change made while it is open.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (page: WorkspaceTextPage, _) in
            if let text = page.text { page.textView.attributedText = page.styled(text) }
        }
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading().hqScaled()
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.loader()
                guard !Task.isCancelled else { return }
                self.contentUnavailableConfiguration = nil
                self.text = text
                self.textView.attributedText = self.styled(text)
                self.shareItem?.isEnabled = true
            } catch {
                guard !Task.isCancelled else { return }
                self.contentUnavailableConfiguration = self.failed(error)
            }
        }
    }

    private func shareNow() {
        guard let text, let item = shareItem else { return }
        item.isEnabled = false
        let share = self.share
        Task { [weak self] in
            var what: Any = text
            if let share, let file = try? await share() { what = file }
            guard let self else { return }
            item.isEnabled = true
            let sheet = UIActivityViewController(activityItems: [what], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceItem = item
            self.present(sheet, animated: true)
        }
    }

    /// Why there is no text: a file that isn't text (with Open File when it can open elsewhere), or the read's error.
    private func failed(_ error: Error) -> UIContentUnavailableConfiguration {
        var config = UIContentUnavailableConfiguration.empty().hqScaled()
        guard error is NotText else {
            config.image = UIImage(systemName: "exclamationmark.triangle")
            config.text = "Couldn’t Open"
            config.secondaryText = MenusError.text(error)
            return config
        }
        config.image = UIImage(systemName: "doc")
        config.text = "Not a Text File"
        guard let openElsewhere else {
            config.secondaryText = "This file can’t be shown as text."
            return config
        }
        config.secondaryText = "This file can’t be shown as text. Open it in Quick Look or another app."
        var open = UIButton.Configuration.hqPush()
        open.title = "Open File"
        config.button = open
        config.buttonProperties.primaryAction = UIAction { _ in openElsewhere() }
        return config
    }

    private func styled(_ text: String) -> NSAttributedString {
        let font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: HQFont.mono(ofSize: 13, weight: .regular), compatibleWith: traitCollection)
        let out = NSMutableAttributedString()
        // Bounded: a huge file shows its first 400,000 characters (Share hands over the whole file).
        let shown = text.count > 400_000 ? String(text.prefix(400_000)) + "\n…" : text
        for line in shown.split(separator: "\n", omittingEmptySubsequences: false) {
            var color = ChatPalette.label
            var background: UIColor?
            if diff {
                if line.hasPrefix("+++") || line.hasPrefix("---") { color = ChatPalette.label2 }
                else if line.hasPrefix("+") { background = UIColor.systemGreen.withAlphaComponent(0.15) }
                else if line.hasPrefix("-") { background = UIColor.systemRed.withAlphaComponent(0.15) }
                else if line.hasPrefix("@@") { color = .systemBlue }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let background { attributes[.backgroundColor] = background; attributes[.lineWash] = true }
            // Each line ends with its own line break, so a wash stays on its line.
            out.append(NSAttributedString(string: line + "\n", attributes: attributes))
        }
        if out.length > 0 { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }
}

/// [mac] Stress test 2026-10-28 #39: ⌘R refreshes Files and Changes as a pull does (`KeyCommands.sheetRefresh`).
extension WorkspacePage: KeyRefreshing {
    var keyRefresh: (() -> Void)? {
        guard let control = tableView.hqKeyRefresh else { return nil }
        return { [weak self, weak control] in
            self?.announceRefresh = true
            control?.beginRefreshing()
            control?.sendActions(for: .valueChanged)
        }
    }
}
