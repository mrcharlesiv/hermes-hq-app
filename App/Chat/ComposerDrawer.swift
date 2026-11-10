import UIKit

// [composer-drawers] The slash drawer and the @ drawer (docs/spec/3x-composer.md §9, §10): one glass panel directly
// above the composer, as wide as the composer's row, riding the keyboard with it. It is a plain subview of the chat
// (never a popover, a sheet or an input accessory), so opening, updating and closing it never moves the keyboard and
// never takes focus from the field: nothing here calls becomeFirstResponder, resignFirstResponder or
// reloadInputViews, and the composer's frame is untouched (the panel overlays the transcript). What it shows is
// `ComposerDrawerModel`'s; this file draws it and runs the calls.

/// What the drawer needs from its chat screen.
@MainActor struct ComposerDrawerHost {
    /// The commands catalog (cached for 1 h by the chat), and the newest one this profile has seen.
    var loadCatalog: () async throws -> CommandsCatalog
    /// [mac-audit] The same list read fresh from Hermes (past the 1 h cache): the empty drawer's Check Again. nil = the
    /// cached read.
    var loadFreshCatalog: (() async throws -> CommandsCatalog)? = nil
    var latestCatalog: () -> CommandsCatalog?
    var isBotChat: () -> Bool
    /// This chat's bot (its profile; "" for the main bot).
    var ownProfile: () -> String
    /// The Bots list (profile, display name, head record).
    var bots: () -> [(bot: ComposerDrawerModel.BotEntry, head: JSONValue?)]
    /// This bot's recent chats for "/resume <q>".
    var recentChats: () -> [ComposerDrawerModel.RecentChat]
    /// Runs a picked command now, through the field's own send path (the field ends empty).
    var sendCommand: (String) -> Void
    var openModels: () -> Void
    var openChat: (String) -> Void
    /// A group room's composer is text only: no drawer.
    var enabled: () -> Bool
    /// [favorite-commands] Starred commands ("/name", in starred order; starred in the Commands sheet, §9.7).
    var favoriteCommands: () -> [String] = { [] }
    /// [favorite-commands] Stars or unstars a command ("/name") in the store the Commands sheet's star writes; nil = no
    /// store (no hold menu or swipe on the rows).
    var toggleFavoriteCommand: ((String) -> Void)?
}

final class ComposerDrawerController: NSObject, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate,
                                      UIEditMenuInteractionDelegate {
    let panel = ComposerDrawerPanel()
    /// [favorite-commands] A command row's hold menu (Favorite / Unfavorite), and the row it is for.
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var menuRow: IndexPath?
    private weak var composer: ComposerView?
    private let completing: any ChatCompleting
    private let host: ComposerDrawerHost

    private(set) var mode: ComposerDrawerModel.Mode = .closed
    private var sections: [ComposerDrawerModel.Section] = []
    /// The row picked from the hardware keyboard (none when the drawer opens).
    private var highlighted: IndexPath?
    /// [favorite-commands] The row under the pointer (Mac): it shows its hollow star, to click without picking the row.
    private var hovered: IndexPath?
    /// The starred commands as the rows were last drawn ("/name", normalized).
    private var starred: Set<String> = []
    /// Escape, a tap on the transcript or a finished option closed the drawer for exactly this text; the next change
    /// may open it again.
    private var closedFor: String?

    // The catalog
    private var catalog: CommandsCatalog?
    private var catalogTask: Task<Void, Never>?
    private var catalogRead = false
    private var catalogFailed = false

    // Gateway answers
    private var gate = CompletionGate()
    private var memory = CompletionMemory()
    private var unsupported: Set<String> = []
    private var debounce: Task<Void, Never>?
    private var lastMentionLog: Date?
    /// Whether the chat's folder lists on the gateway computer, by folder (checked at most every 30 s).
    private var folderChecks: [String: (at: Date, readable: Bool?)] = [:]
    static let debounceDelay: Duration = .milliseconds(60)
    static let folderCheckFor: TimeInterval = 30

    var isOpen: Bool { !panel.isHidden }

    init(composer: ComposerView, completing: any ChatCompleting, host: ComposerDrawerHost) {
        self.composer = composer
        self.completing = completing
        self.host = host
        super.init()
        panel.isHidden = true
        panel.table.dataSource = self
        panel.table.delegate = self
        catalog = host.latestCatalog()
        let field = composer.textView as? ComposerTextView
        field?.drawerOpen = { [weak self] in self?.isOpen ?? false }
        field?.onDrawerKey = { [weak self] key in self?.key(key) }
        field?.onHardwareReturnPick = { [weak self] in self?.pickHighlighted() ?? false }
        composer.onDrawerInput = { [weak self] in self?.refreshFromInput() }
        panel.onTraitsChange = { [weak self] in self?.reload() }
        if host.toggleFavoriteCommand != nil {
            panel.table.addInteraction(editMenu)
            panel.table.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(rowPressed(_:))))
            #if targetEnvironment(macCatalyst)
            panel.table.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(rowHovered(_:))))
            #endif
        }
    }

    /// A tap on the transcript closes the drawer (the tap still reaches the transcript).
    func watchTaps(on view: UIView) {
        let tap = UITapGestureRecognizer(target: self, action: #selector(transcriptTapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func transcriptTapped() { if isOpen { close() } }

    /// Escape, a tap on the transcript: the drawer closes and the words stay.
    func close() {
        guard let composer else { return }
        if isOpen { AppLog.trace("composer", "\(modeKind) drawer dismissed (escape or tap)") }
        closedFor = composer.text
        refresh()
    }

    // MARK: Following the field

    /// What `refresh` last read from the field.
    struct InputKey: Equatable {
        var text: String
        var caret: NSRange
        var enabled: Bool
        var closedFor: String?
    }
    private var lastInput: InputKey?
    /// Refreshes run (tests).
    private(set) var refreshCount = 0

    /// [perf] The field reports each keystroke twice (the selection moved, the text changed): the second, reading the
    /// same text and caret, does nothing. Every other refresh (a close, an answer, a failed folder) always runs.
    private func refreshFromInput() {
        guard let composer else { return }
        let key = InputKey(text: composer.text, caret: composer.textView.selectedRange, enabled: host.enabled(), closedFor: closedFor)
        guard key != lastInput else { return }
        refresh()
    }

    func refresh() {
        guard let composer else { return }
        refreshCount += 1
        let text = composer.text
        if let closedFor, closedFor != text { self.closedFor = nil }
        let caret = composer.textView.selectedRange
        lastInput = InputKey(text: text, caret: caret, enabled: host.enabled(), closedFor: closedFor)
        var next: ComposerDrawerModel.Mode = .closed
        if host.enabled(), closedFor == nil, caret.length == 0 {
            next = ComposerDrawerModel.mode(text: text, caret: caret.location)
        }
        // A command or skill drawer that opens again after the catalog failed tries it again.
        if catalogFailed, Self.wantsCatalog(next), !Self.wantsCatalog(mode) { catalogFailed = false }
        mode = next
        wantRemote()
        show(content())
    }

    private static func wantsCatalog(_ mode: ComposerDrawerModel.Mode) -> Bool {
        switch mode {
        case .slash, .skill: true
        case .closed, .at: false
        }
    }

    /// The gateway query the current mode wants ("slash|/mo", "path|@file:src/"), if any.
    private var remoteKey: String? {
        switch mode {
        case .slash(let text):
            guard text.count > 1 else { return nil }
            let name = SlashCommand.parse(text).name
            if text.contains(where: { $0.isWhitespace }), ComposerDrawerModel.chatCommands.contains(name) { return nil }
            return "slash|" + text
        case .at(let word, _):
            guard !word.isEmpty else { return nil }
            if ComposerDrawerModel.isFolderQuery(word), folderMissing(for: word) { return nil }
            return "path|@" + word
        case .skill, .closed:
            return nil
        }
    }

    private func method(_ key: String) -> String { key.hasPrefix("slash|") ? "complete.slash" : "complete.path" }

    private func wantRemote() {
        let key = remoteKey
        let usable = key.map { !unsupported.contains(method($0)) && completing.completionsOnline } ?? false
        gate.want(usable ? key : nil)
        debounce?.cancel()
        guard usable, let key, memory.wantsAsk(key) else { return }
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceDelay)
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }

    /// Sends the wanted query when nothing is out (one call in flight).
    private func pump() {
        guard let key = gate.next(skip: { [memory] in !memory.wantsAsk($0) }) else { return }
        let method = method(key)
        let query = String(key.drop(while: { $0 != "|" }).dropFirst())
        Task { [weak self, completing] in
            var answer: ComposerDrawerModel.Answer?
            var failure: Error?
            do {
                answer = method == "complete.slash" ? try await completing.completeSlash(query) : try await completing.completePath(query)
            } catch {
                failure = error
            }
            guard let self else { return }
            let current = self.gate.finished(key)
            if let answer {
                self.memory.remember(key, answer)
            } else if let failure {
                self.failed(key, method: method, error: failure)
            }
            if current { self.show(self.content()) }
            self.pump()
        }
    }

    private func failed(_ key: String, method: String, error: Error) {
        if let rpc = error as? RPCError, rpc.code == -32601 {
            unsupported.insert(method)   // an older gateway: local rows only from now on, never an error
        } else {
            memory.fail(key)             // asked again a few seconds on, when the field asks for it again
        }
        guard method == "complete.path" else { return }
        let now = Date()
        if lastMentionLog.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            lastMentionLog = now
            AppLog.note("composer", "Mentions didn’t load: \(error)")
        }
    }

    // MARK: What shows

    private func ensureCatalog(fresh: Bool = false) {
        guard !catalogRead, catalogTask == nil, !catalogFailed else { return }
        let load = fresh ? host.loadFreshCatalog ?? host.loadCatalog : host.loadCatalog
        catalogTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fresh = try await load()
                self.catalog = fresh
            } catch is CancellationError {
            } catch {
                AppLog.note("composer", "Commands didn’t load: \(error)")
                // Not read: the next "/" asks again (a gateway that was briefly away left the drawer dead for the
                // whole chat). Until then the drawer says it failed, or keeps the catalog it already had.
                self.catalogTask = nil
                self.catalogFailed = true
                if self.catalog == nil, self.mode.isOpen { self.show(self.content()) }
                return
            }
            self.catalogRead = true
            self.catalogTask = nil
            if self.mode.isOpen { self.show(self.content()) }
        }
    }

    private func folderMissing(for word: String) -> Bool {
        guard let folder = completing.completionFolder else { return true }
        let now = Date()
        if let check = folderChecks[folder], now.timeIntervalSince(check.at) < Self.folderCheckFor {
            return check.readable == false
        }
        folderChecks[folder] = (now, nil)
        Task { [weak self, completing] in
            let readable = await completing.completionFolderReadable(folder)
            guard let self else { return }
            self.folderChecks[folder] = (Date(), readable)
            if !readable { self.refresh() }
        }
        return false
    }

    private func content() -> [ComposerDrawerModel.Section]? {
        switch mode {
        case .closed:
            return nil
        case .slash(let text):
            ensureCatalog()
            let remote = remoteKey.flatMap { memory.answer($0) }
            return ComposerDrawerModel.slashSections(text: text, catalog: catalog,
                                                     catalogLoading: catalog == nil && !catalogFailed, catalogFailed: catalogFailed,
                                                     isBotChat: host.isBotChat(),
                                                     remote: remote, recent: host.recentChats(), favorites: host.favoriteCommands())
        case .skill(let word, let range):
            ensureCatalog()
            return ComposerDrawerModel.skillSections(word: word, range: range, catalog: catalog, isBotChat: host.isBotChat())
        case .at(let word, let range):
            let key = remoteKey
            let remote = key.flatMap { memory.answer($0) }
            let failed = key.map { (remote == nil && memory.failed($0)) || unsupported.contains(method($0)) } ?? false
            let offline = !completing.completionsOnline
            let missing = ComposerDrawerModel.isFolderQuery(word) && folderMissing(for: word)
            return ComposerDrawerModel.atSections(word: word, range: range, bots: host.bots().map(\.bot), own: host.ownProfile(),
                                                  remote: remote, waiting: key != nil, failed: failed || offline,
                                                  folderMissing: missing, previous: isOpen ? sections : nil)
        }
    }

    /// For logs: "slash", "@" or "skill" (the mode `show` is drawing).
    private var modeKind: String {
        switch mode {
        case .slash: return "slash"
        case .at: return "@"
        case .skill: return "skill"
        case .closed: return "closed"
        }
    }

    /// For logs only: the kind of drawer last shown, kept while it is open so the close branch below (reached after
    /// `refresh()` has already moved `mode` on to `.closed`) still knows what it is closing.
    private var openKind: String?

    private func show(_ next: [ComposerDrawerModel.Section]?, keepHighlight: Bool = false) {
        guard let next, !next.isEmpty else {
            if isOpen {
                panel.isHidden = true
                sections = []
                highlighted = nil
                panel.table.reloadData()
                AppLog.trace("composer", "\(openKind ?? "drawer") closed: no matches")
                openKind = nil
            }
            return
        }
        let opening = !isOpen
        if next != sections || opening {
            // A star (keepHighlight) leaves the marked row marked; typing starts over.
            let markedId = keepHighlight ? highlighted.flatMap { row(at: $0) }?.id : nil
            sections = next
            highlighted = markedId.flatMap { id in path(where: { $0.id == id }) }
            hovered = nil
            if case .at = mode { panel.isAt = true } else { panel.isAt = false }
            reload()
        }
        if opening {
            panel.isHidden = false
            panel.superview?.bringSubviewToFront(panel)
            // VoiceOver stays in the field; the count is said once per opening, never per keystroke.
            let count = Set(sections.flatMap(\.rows).filter(\.tappable).map(\.action)).count   // Favorites lists some twice
            if count > 0 { HQAnnounce.say(panel.isAt ? "\(count) suggestions" : "\(count) commands") }
            AppLog.trace("composer", "\(modeKind) drawer opened: \(sections.reduce(0) { $0 + $1.rows.count }) rows")
        }
        openKind = modeKind
    }

    private func reload() {
        starred = Set(host.favoriteCommands().map(SlashCatalog.normalize))
        panel.table.reloadData()
        panel.table.layoutIfNeeded()
        panel.fitHeight(rows: sections.reduce(0) { $0 + $1.rows.count })
    }

    // MARK: Hardware keys (§9.5)

    private var flatRows: [IndexPath] {
        sections.enumerated().flatMap { s, section in
            section.rows.enumerated().compactMap { r, row in row.tappable ? IndexPath(row: r, section: s) : nil }
        }
    }

    private func row(at path: IndexPath) -> ComposerDrawerModel.Row? {
        guard sections.indices.contains(path.section), sections[path.section].rows.indices.contains(path.row) else { return nil }
        return sections[path.section].rows[path.row]
    }

    private func path(where match: (ComposerDrawerModel.Row) -> Bool) -> IndexPath? {
        for (s, section) in sections.enumerated() {
            if let r = section.rows.firstIndex(where: match) { return IndexPath(row: r, section: s) }
        }
        return nil
    }

    private func key(_ key: ComposerTextView.DrawerKey) {
        let rows = flatRows
        guard isOpen, !rows.isEmpty else { return }
        switch key {
        case .down:
            let index = highlighted.flatMap { rows.firstIndex(of: $0) }.map { min($0 + 1, rows.count - 1) } ?? 0
            setHighlight(rows[index])
        case .up:
            guard let current = highlighted.flatMap({ rows.firstIndex(of: $0) }) else { return }
            setHighlight(current == 0 ? nil : rows[current - 1])
        case .tab:
            pick(at: highlighted ?? rows[0])
        }
    }

    private func setHighlight(_ path: IndexPath?) {
        let old = highlighted
        highlighted = path
        let paths = [old, path].compactMap { $0 }.filter { $0.section < sections.count && $0.row < sections[$0.section].rows.count }
        panel.table.reconfigureRows(at: paths)
        if let path { panel.table.scrollToRow(at: path, at: .none, animated: false) }
    }

    /// Return with a highlighted row picks it (true); otherwise Return does what it always does.
    func pickHighlighted() -> Bool {
        guard isOpen, let highlighted else { return false }
        pick(at: highlighted)
        return true
    }

    // MARK: Picks

    private func pick(at path: IndexPath) {
        guard path.section < sections.count, path.row < sections[path.section].rows.count else { return }
        pick(sections[path.section].rows[path.row])
    }

    private func setField(_ text: String, caret: Int) {
        guard let composer else { return }
        composer.text = text
        composer.textView.selectedRange = NSRange(location: caret, length: 0)
        refresh()
    }

    private func pick(_ row: ComposerDrawerModel.Row) {
        guard row.tappable, let composer else { return }
        Haptics.play(.selection)
        highlighted = nil
        switch row.action {
        case .command(let command, let skill):
            let name = SlashCatalog.bareName(command)
            let action: SlashCatalog.PickAction = skill ? .insert
                : SlashCatalog.sheetOnly.contains(name) ? .send   // /help opens the commands list whatever follows it
                : SlashCatalog.pickAction(SlashCatalog.Row(command: command, description: "", skill: false), catalog: catalog)
            switch action {
            case .send:
                host.sendCommand(command)
            case .models:
                setField("", caret: 0)
                host.openModels()
            case .insert:
                let text = command + " "
                setField(text, caret: (text as NSString).length)
            }
        case .option(let prefix, let text):
            let (edit, keepOpen) = ComposerDrawerModel.applyOption(prefix: prefix, text: text)
            if !keepOpen { closedFor = edit.text }
            setField(edit.text, caret: edit.caret)
        case .skill(let command, let range):
            let edit = ComposerDrawerModel.applySkill(command, range: range, in: composer.text)
            setField(edit.text, caret: edit.caret)
        case .openChat(let id):
            setField("", caret: 0)
            host.openChat(id)
        case .mention(let ref, let range):
            let edit = ComposerDrawerModel.applyMention(ref, range: range, in: composer.text)
            setField(edit.text, caret: edit.caret)
        case .checkAgain:
            // [mac-audit] The empty list read again: "Loading commands…" shows until Hermes answers, then its commands
            // or the same note. A read already under way (the list shown was the last one seen) answers instead.
            guard catalogTask == nil else { return }
            catalog = nil
            catalogRead = false
            catalogFailed = false
            ensureCatalog(fresh: true)
            show(content())
        case .none:
            break
        }
    }

    // MARK: Table

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let title = sections[section].title else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: ComposerDrawerHeader.reuse) as? ComposerDrawerHeader
        header?.configure(title)
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        sections[section].title == nil ? (section == 0 ? 4 : 8) : UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { nil }
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { section == sections.count - 1 ? 4 : 0 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ComposerDrawerCell.reuse, for: indexPath) as! ComposerDrawerCell
        let row = sections[indexPath.section].rows[indexPath.row]
        var head: UIImage?
        if let profile = row.bot {
            let raw = host.bots().first { $0.bot.profile == profile }?.head
            head = BotFaces.shared.headImage(profile: profile, raw: raw, side: 24, scale: tableView.traitCollection.displayScale,
                                             dark: tableView.traitCollection.userInterfaceStyle == .dark)
        }
        cell.configure(row, face: ComposerDrawerModel.titleFace(row), head: head, highlighted: indexPath == highlighted)
        // [favorite-commands] Owner 2026-10-31 "Need to be able to favorite the / commands": a star on a command row.
        // Filled and always there on a favourite; hollow on the Mac's row under the pointer or marked from the keys.
        // A click on it stars or unstars without picking the row. The iPhone shows the filled star only (its hold menu
        // and leading swipe add one, as before).
        if host.toggleFavoriteCommand != nil, let command = ComposerDrawerModel.favoriteCommand(row) {
            let on = starred.contains(command)
            let hollow = DeviceWord.isMac && (indexPath == highlighted || indexPath == hovered)
            cell.setStar(on ? true : (hollow ? false : nil), command: command) { [weak self, weak cell] in
                guard let self, let cell, let path = self.panel.table.indexPath(for: cell) else { return }
                self.favoriteToggle(at: path)?.run()
            }
        } else {
            cell.setStar(nil, command: "", action: nil)
        }
        return cell
    }

    // MARK: Favorite / Unfavorite (§9.7)

    /// A command row's star, as Sessions pins a chat: the hold menu and a leading swipe. The same store as the Commands
    /// sheet's star, and the drawer redraws at once (its Favorites section follows).
    private func favoriteToggle(at indexPath: IndexPath) -> (command: String, title: String, image: String, short: String, run: () -> Void)? {
        guard let toggle = host.toggleFavoriteCommand, sections.indices.contains(indexPath.section),
              sections[indexPath.section].rows.indices.contains(indexPath.row),
              let command = ComposerDrawerModel.favoriteCommand(sections[indexPath.section].rows[indexPath.row]) else { return nil }
        let favorited = host.favoriteCommands().map(SlashCatalog.normalize).contains(command)
        let wording = ComposerDrawerModel.favoriteAction(favorited: favorited)
        let id = sections[indexPath.section].rows[indexPath.row].id
        return (command, wording.title, wording.image, wording.short, { [weak self] in
            toggle(command)
            AppLog.trace("composer", "drawer: \(command) \(favorited ? "unstarred" : "starred")")
            Haptics.play(.selection)
            guard let self, self.mode.isOpen else { return }
            // The row keeps its place on screen and its mark while Favorites grows or shrinks above it.
            let table = self.panel.table
            let before = self.path(where: { $0.id == id }).map { table.convert(table.rectForRow(at: $0), to: nil).minY }
            self.show(self.content(), keepHighlight: true)
            self.reload()   // the stars, even where the sections came back the same
            if let before, let path = self.path(where: { $0.id == id }) { table.hqHoldRow(at: path, onScreenAt: before) }
        })
    }

    /// The hold menu is an edit menu (the callout over the row), not a context menu: a context menu takes the keyboard
    /// down while it is up and puts it back after (measured 2026-10-27, `ComposerUITests.test24`), the jump §9.4 rules
    /// out; the edit menu leaves the field focused.
    @objc private func rowPressed(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began else { return }
        let point = press.location(in: panel.table)
        guard let indexPath = panel.table.indexPathForRow(at: point), favoriteToggle(at: indexPath) != nil else { return }
        menuRow = indexPath
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let indexPath = menuRow, let item = favoriteToggle(at: indexPath) else { return nil }
        let action = UIAction(title: item.title, image: UIImage(systemName: item.image)) { _ in item.run() }
        action.accessibilityIdentifier = "drawer.favorite.\(item.command)"
        return UIMenu(children: [action])
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        menuRow = nil
    }

    #if targetEnvironment(macCatalyst)
    /// [favorite-commands] The row under the pointer shows its hollow star.
    @objc private func rowHovered(_ hover: UIHoverGestureRecognizer) {
        var path: IndexPath?
        if hover.state == .began || hover.state == .changed {
            path = panel.table.indexPathForRow(at: hover.location(in: panel.table))
            if let p = path, row(at: p).flatMap(ComposerDrawerModel.favoriteCommand) == nil { path = nil }
        }
        guard path != hovered else { return }
        let old = hovered
        hovered = path
        let paths = [old, path].compactMap { $0 }.filter { row(at: $0) != nil }
        panel.table.reconfigureRows(at: paths)
    }

    /// [mac] Stress test 2026-10-28 #16: a right-click (or Control-click) stars a row, as the hold and the swipe do on
    /// the iPhone. The Mac has no on-screen keyboard to take down, the reason the iPhone keeps to an edit menu.
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        guard let item = favoriteToggle(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let action = UIAction(title: item.title, image: UIImage(systemName: item.image)) { _ in item.run() }
            action.accessibilityIdentifier = "drawer.favorite.\(item.command)"
            return UIMenu(children: [action])
        }
    }
    #endif

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = favoriteToggle(at: indexPath) else { return nil }
        let action = UIContextualAction(style: .normal, title: item.short) { _, _, done in
            item.run()
            done(true)
        }
        action.image = UIImage(systemName: item.image + ".fill")
        action.backgroundColor = .systemYellow
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        sections[indexPath.section].rows[indexPath.row].tappable
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        pick(at: indexPath)
    }
}

// MARK: - The panel

/// The glass panel (radius 18): a plain table of rows. In the Desktop Look the app's glass pass makes it a flat,
/// outlined box on the editor surface (ThemeChrome `solidify`), like every other panel the chat floats.
final class ComposerDrawerPanel: UIView {
    let glass: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .corners(radius: .fixed(18))
        view.clipsToBounds = true
        return view
    }()
    let table = UITableView(frame: .zero, style: .plain)
    /// The @ drawer (VoiceOver names the list "Suggestions").
    var isAt = false { didSet { glass.accessibilityLabel = isAt ? "Suggestions" : "Commands" } }
    var onTraitsChange: (() -> Void)?
    private(set) var heightConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "composer.drawer"
        addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 52
        table.sectionHeaderTopPadding = 0
        table.sectionHeaderHeight = UITableView.automaticDimension
        table.estimatedSectionHeaderHeight = 28
        table.keyboardDismissMode = .none
        table.showsVerticalScrollIndicator = true
        table.register(ComposerDrawerCell.self, forCellReuseIdentifier: ComposerDrawerCell.reuse)
        table.register(ComposerDrawerHeader.self, forHeaderFooterViewReuseIdentifier: ComposerDrawerHeader.reuse)
        table.accessibilityIdentifier = "composer.drawer.list"
        glass.contentView.addSubview(table)
        glass.accessibilityContainerType = .list
        glass.accessibilityLabel = "Commands"
        heightConstraint = heightAnchor.constraint(equalToConstant: 52)
        // Low: the drawer gives way to everything that places the composer (the keyboard-follow constraints are not
        // required), so a tall drawer never pushes the field down (verify: at AX XXXL a 999 height moved it under the keys).
        heightConstraint.priority = UILayoutPriority(200)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            table.topAnchor.constraint(equalTo: glass.contentView.topAnchor), table.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            heightConstraint,
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, ThemeGenerationTrait.self, UITraitUserInterfaceStyle.self]) {
            (view: ComposerDrawerPanel, _) in view.onTraitsChange?()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The panel's height: its rows, at most 5.5 of them (the screen's own room above the composer caps it further:
    /// a required limit keeps the field and 44 pt of transcript visible).
    func fitHeight(rows: Int) {
        let content = table.contentSize.height
        var unit: CGFloat = 52
        if rows > 0, table.numberOfSections > 0 {
            let first = (0..<table.numberOfSections).first { table.numberOfRows(inSection: $0) > 0 }
            if let first { unit = max(DeviceWord.isMac ? 30 : 44, table.rectForRow(at: IndexPath(row: 0, section: first)).height) }
        }
        // [mac-popups] The Mac's one-line rows are short: more of them before the list scrolls.
        let height = ceil(min(content, unit * (DeviceWord.isMac ? 8.5 : 5.5)))
        table.isScrollEnabled = content > height + 0.5
        if abs(heightConstraint.constant - height) > 0.5 { heightConstraint.constant = height }
    }
}

final class ComposerDrawerHeader: UITableViewHeaderFooterView {
    static let reuse = "drawer.header"

    func configure(_ title: String) {
        var content = UIListContentConfiguration.header().hqScaled()
        content.text = title
        content.textProperties.font = HQFont.preferred(.footnote)
        content.textProperties.color = ChatPalette.label2
        content.textProperties.transform = .none
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 2, trailing: 16)
        #if targetEnvironment(macCatalyst)
        // [mac-popups] The Mac pop-overs' section names (MacPickHeader): the Desktop Look's tracked capitals.
        if Theme.isDesktop {
            content.attributedText = NSAttributedString(string: title.uppercased(), attributes: DesktopLayout.labelAttributes())
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16)
        }
        #endif
        contentConfiguration = content.hqMacSectionHeader()   // [mac] Stress test 2026-10-28 #52
        backgroundConfiguration = .clear()
        accessibilityTraits = .header
    }
}

/// A row: the command in semibold Body (as the Commands sheet's rows), a ref in monospaced Body, its description in
/// Subheadline under it (two lines, then cut).
final class ComposerDrawerCell: UITableViewCell {
    static let reuse = "drawer.row"
    private var marked = false
    private lazy var star: UIButton = {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.contentInsets = .zero
        button.configuration = config
        button.addAction(UIAction { [weak self] _ in self?.onStar?() }, for: .primaryActionTriggered)
        return button
    }()
    private var onStar: (() -> Void)?

    /// [favorite-commands] `state`: true a filled star, false a hollow one, nil none. The button is the accessory (a
    /// command row never has a spinner): 44 pt on the iPhone, the row's height on the Mac.
    func setStar(_ state: Bool?, command: String, action: (() -> Void)?) {
        onStar = action
        guard let state else {
            if accessoryView === star { accessoryView = nil }
            return
        }
        let side: CGFloat = DeviceWord.isMac ? 30 : 44
        star.frame = CGRect(x: 0, y: 0, width: side, height: side)
        let font = HQFont.preferred(DeviceWord.isMac ? .subheadline : .body)
        // The colour baked into the image: inside the drawer's glass a tint drew black in the iOS look.
        let colour = (state ? ChatPalette.tint : ChatPalette.label2).resolvedColor(with: traitCollection)
        star.configuration?.image = UIImage(systemName: state ? "star.fill" : "star", withConfiguration: UIImage.SymbolConfiguration(font: font))?
            .withTintColor(colour, renderingMode: .alwaysOriginal)
        star.accessibilityLabel = "Favorite \(command)"
        star.accessibilityTraits = state ? [.button, .selected] : .button
        star.accessibilityIdentifier = "drawer.star.\(command)"
        star.toolTip = ComposerDrawerModel.favoriteAction(favorited: state).title
        accessoryView = star
    }

    func configure(_ row: ComposerDrawerModel.Row, face: ComposerDrawerModel.TitleFace, head: UIImage?, highlighted: Bool) {
        marked = highlighted
        // [mac-audit] Check Again reads as the action it is (the sheets' push buttons are tinted), unless marked.
        let titleColor = row.action == .checkAgain && !highlighted ? ChatPalette.tintText : ChatPalette.label
        var content = UIListContentConfiguration.subtitleCell().hqScaled()
        let body = HQFont.preferred(.body, compatibleWith: traitCollection)
        let titleFont: UIFont
        switch face {
        case .command: titleFont = HQFont.face(size: body.pointSize, weight: .semibold, family: ThemeTable.current.state.desktopLook
                                                   ? ThemeTable.current.state.skin.sansFamily : nil)
        case .ref: titleFont = HQFont.monoFace(ofSize: body.pointSize)
        case .plain: titleFont = body
        }
        if let parent = row.parent {
            let text = NSMutableAttributedString(string: parent, attributes: [.font: titleFont, .foregroundColor: ChatPalette.label2])
            text.append(NSAttributedString(string: row.title, attributes: [.font: HQFont.monoFace(ofSize: body.pointSize, weight: .semibold),
                                                                            .foregroundColor: ChatPalette.label]))
            content.attributedText = text
        } else {
            content.text = row.title
            content.textProperties.font = titleFont
            content.textProperties.color = row.tappable ? titleColor : ChatPalette.label2
        }
        content.textProperties.numberOfLines = row.tappable ? 1 : 0
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        content.secondaryText = row.detail.isEmpty ? nil : row.detail
        content.secondaryTextProperties.font = HQFont.preferred(.subheadline, compatibleWith: traitCollection)
        content.secondaryTextProperties.color = ChatPalette.label2
        content.secondaryTextProperties.numberOfLines = 2
        content.textToSecondaryTextVerticalPadding = 2
        content.image = head
        content.imageProperties.maximumSize = CGSize(width: 24, height: 24)
        content.imageToTextPadding = 10
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        #if targetEnvironment(macCatalyst)
        // [mac-popups] One line a row on the Mac, as its pop-overs (MacPickPanel) and a Mac's completion lists: the
        // command, then what it does in grey beside it, cut at the edge. Notes (no command) keep their wrapping line.
        if row.tappable {
            let line = NSMutableAttributedString(attributedString: content.attributedText ?? NSAttributedString(
                string: row.title, attributes: [.font: titleFont, .foregroundColor: titleColor]))
            if !row.detail.isEmpty {
                line.append(NSAttributedString(string: "   " + row.detail, attributes: [.font: MacType.row, .foregroundColor: ChatPalette.label2]))
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            content.attributedText = line
            content.secondaryText = nil
            content.textProperties.numberOfLines = 1
            content.textProperties.lineBreakMode = .byTruncatingTail
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        }
        #endif
        contentConfiguration = content
        if row.spinner {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            accessoryView = spinner
        } else if accessoryView !== star {
            accessoryView = nil
        }
        backgroundColor = .clear
        selectionStyle = row.tappable ? .default : .none
        isAccessibilityElement = true
        accessibilityLabel = row.spokenLabel
        accessibilityTraits = row.tappable ? .button : .staticText
        accessibilityIdentifier = row.tappable ? "drawer.row.\(row.parent ?? "")\(row.title)" : "drawer.note"
        setNeedsUpdateConfiguration()
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.clear()
        if state.isHighlighted || marked {
            background.backgroundColor = ChatPalette.fill3
            background.cornerRadius = Theme.isDesktop ? 4 : 10
            background.backgroundInsets = NSDirectionalEdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6)
            #if targetEnvironment(macCatalyst)
            // [mac-popups] The window's selection, as the pop-overs mark their rows.
            background.backgroundColor = MacSelection.accent
            background.cornerRadius = MacSelection.radius
            #endif
        }
        backgroundConfiguration = background
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        #if targetEnvironment(macCatalyst)
        contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: MacPickPanel.rowHeight).isActive = true   // [mac-popups]
        #else
        contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

extension AppModel {
    /// [composer-drawers] "/resume <q>": that chat opens in this one's place (as a listed chat opens).
    func openChat(_ summary: SessionSummary, replacing screen: UIViewController) {
        let next = makeChatScreen(chat(for: summary))
        next.hidesBottomBarWhenPushed = true
        next.navigationItem.largeTitleDisplayMode = .never
        guard let navigation = screen.navigationController else { return }
        var stack = navigation.viewControllers
        if let index = stack.firstIndex(where: { $0 === screen }) { stack.remove(at: index) }
        stack.append(next)
        navigation.setViewControllers(stack, animated: true)
    }
}
