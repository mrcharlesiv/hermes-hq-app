// [mac] Stress test 2026-10-28 #61: Open Quickly (⌘K) as a Mac's own: a panel floating in the middle of the window, not
// More's search field dropped over the list (it covered the gateway card, sat 10–12 pt left of the cards, had no focus
// ring in the Desktop Look and showed nothing until something was typed). The latest chats show before typing; typing
// searches what More's search finds (sessions, pages, bots, Settings, actions). ↑ and ↓ move the mark, Return opens the
// marked row, Esc or a click outside closes. A result opens as it does from More's search (`MoreSearchUI.open`).
// [mac-audit G] Owner 2026-11-02 (Mac audit #15): the panel leaves the tab on show alone until a result is picked, and a
// chat, a bot or a tab result opens on its own tab (`openOnOwnTab`), not on More. The panel stands near the window's
// top, a palette over the whole window. [keys] Mac UI check 2026-11-13 (K4): pages open as their Tool, settings in the
// Settings window, actions where their own key or button runs them; only what has no such home opens on More's stack.

import UIKit

#if targetEnvironment(macCatalyst)
@MainActor final class MacOpenQuickly: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let search: MoreSearchUI
    /// Picks More and its first page, as the tab click did, before a result opens from its stack.
    private let showMore: () -> Void
    /// Opens a result on its own tab (a chat on Sessions, a bot on Bots); false: it opens from More's stack.
    private let ownTab: (MoreSearch.Kind, MoreSearch.Item) -> Bool
    private let panel = UIView()
    /// [glass-mac] Owner 2026-10-30 "more Liquid Glass": in the iOS look the panel is glass, as Spotlight's is; the
    /// Desktop Look keeps its solid editor panel (`applyLook`).
    private let glassBack = UIVisualEffectView()
    /// [keys] Mac UI check 2026-11-13 (L13): a veil of the page's colour over the glass, as the app's pop-overs have
    /// (`SheetStyle`): glass alone let the page's words show through the card and the marked row.
    private let veil = UIView()
    private let fieldBox = UIView()
    private let field = UITextField()
    private let table = UITableView(frame: .zero, style: .plain)
    private var groups: [MoreSearch.Group] = []
    private var marked = IndexPath(row: 0, section: 0)
    private var tableHeight: NSLayoutConstraint!

    private static weak var shown: MacOpenQuickly?
    /// [mac] Stress test 2026-10-28 round 6: the panel's top, a fifth of the way down the window (see viewDidLoad).
    /// [mac-audit G] Mac audit #15: a tenth, just under the panes' bars, so it reads as the window's palette and not a
    /// drop-down hung off a list row.
    private var topFromWindow: NSLayoutConstraint?
    private static func topRoom(_ height: CGFloat) -> CGFloat { max(72, (height * 0.1).rounded()) }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let wanted = Self.topRoom(view.bounds.height)
        if let topFromWindow, topFromWindow.constant != wanted { topFromWindow.constant = wanted }
    }

    /// Opens the panel over the window (once: ⌘K again while it's up puts the caret back in its field).
    static func present(from host: UIViewController, search: MoreSearchUI,
                        ownTab: @escaping (MoreSearch.Kind, MoreSearch.Item) -> Bool, showMore: @escaping () -> Void) {
        if let shown {
            guard shown.closing else { shown.field.becomeFirstResponder(); return }
            shown.dismiss(animated: false)   // [mac-feel] fading out after Esc: gone now, a fresh panel takes its place
        }
        let panel = MacOpenQuickly(search: search, ownTab: ownTab, showMore: showMore)
        shown = panel
        host.hqShowPanel(panel)
    }

    private init(search: MoreSearchUI, ownTab: @escaping (MoreSearch.Kind, MoreSearch.Item) -> Bool, showMore: @escaping () -> Void) {
        self.search = search
        self.ownTab = ownTab
        self.showMore = showMore
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let outside = UITapGestureRecognizer(target: self, action: #selector(tappedOutside(_:)))
        outside.cancelsTouchesInView = false
        view.addGestureRecognizer(outside)

        panel.layer.cornerCurve = .continuous
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowRadius = 24
        panel.layer.shadowOffset = CGSize(width: 0, height: 10)
        panel.translatesAutoresizingMaskIntoConstraints = false
        glassBack.isUserInteractionEnabled = false
        glassBack.cornerConfiguration = .corners(radius: .fixed(Self.glassRadius))
        glassBack.translatesAutoresizingMaskIntoConstraints = false
        DesktopLayout.keepOwnLook(glassBack)   // the look's panel is `panel`'s own solid fill (`applyLook`)
        panel.addSubview(glassBack)
        veil.isUserInteractionEnabled = false
        veil.layer.cornerRadius = Self.glassRadius
        veil.layer.cornerCurve = .continuous
        veil.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(veil)
        panel.accessibilityIdentifier = "open-quickly"
        panel.accessibilityViewIsModal = true
        view.addSubview(panel)

        // The field in its own box, ringed in the accent while it has the caret (both looks).
        fieldBox.layer.cornerCurve = .continuous
        fieldBox.layer.borderWidth = 2
        fieldBox.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(fieldBox)
        let glass = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        glass.tintColor = HQPalette.label2
        glass.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: HQFont.preferred(.body))
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.setContentHuggingPriority(.required, for: .horizontal)
        fieldBox.addSubview(glass)
        field.font = HQFont.preferred(.body)
        field.textColor = HQPalette.label
        // [mac] Mac polish #69: the hint in the look's label 2, not the system's faint placeholder grey (about 2:1).
        field.attributedPlaceholder = NSAttributedString(string: MoreSearch.placeholder, attributes: [.foregroundColor: HQPalette.label2])
        field.accessibilityLabel = "Open Quickly"
        field.accessibilityIdentifier = "open-quickly.field"
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.borderStyle = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        field.addAction(UIAction { [weak self] _ in self?.typed() }, for: .editingChanged)
        field.addAction(UIAction { [weak self] _ in self?.openMarked() }, for: .primaryActionTriggered)
        field.addAction(UIAction { [weak self] _ in self?.ring() }, for: .editingDidBegin)
        field.addAction(UIAction { [weak self] _ in self?.ring() }, for: .editingDidEnd)
        fieldBox.addSubview(field)

        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.sectionHeaderTopPadding = 6
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 52
        table.accessibilityIdentifier = "open-quickly.results"
        table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        // Feel list B (2026-11-13): the pointer moves the mark, as in Commands and Models. It drew a grey bar of its
        // own while the blue mark stayed where the keys left it: two rows marked at once.
        MacHover.drawsOwnHover(table)
        table.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        table.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(table)

        tableHeight = table.heightAnchor.constraint(equalToConstant: 0)
        let width = panel.widthAnchor.constraint(equalToConstant: 640)
        width.priority = .defaultHigh
        // [mac] Stress test 2026-10-28 round 6: the panel was already centred on the window, but 90 pt under the top it
        // sat level with More's gateway card, its field beside the card, and read as a popover hung off the list
        // column. It now stands a fifth of the way down the window, as Spotlight's does, centred on the window.
        let top = panel.topAnchor.constraint(equalTo: view.topAnchor)
        top.priority = .defaultHigh
        topFromWindow = top
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            top,
            panel.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            width,
            panel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -80),
            glassBack.topAnchor.constraint(equalTo: panel.topAnchor), glassBack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            glassBack.leadingAnchor.constraint(equalTo: panel.leadingAnchor), glassBack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            veil.topAnchor.constraint(equalTo: panel.topAnchor), veil.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            veil.leadingAnchor.constraint(equalTo: panel.leadingAnchor), veil.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            fieldBox.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            fieldBox.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            fieldBox.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            glass.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 12),
            glass.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -8),
            field.topAnchor.constraint(equalTo: fieldBox.topAnchor, constant: 10),
            field.bottomAnchor.constraint(equalTo: fieldBox.bottomAnchor, constant: -10),
            table.topAnchor.constraint(equalTo: fieldBox.bottomAnchor, constant: 6),
            table.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 6),
            table.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
            table.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6),
            tableHeight,
        ])
        applyLook()
        typed()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (panel: MacOpenQuickly, _) in panel.recolor() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
        if !fadedIn { fadedIn = true; hqPanelAppeared() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if Self.shown === self { Self.shown = nil }
    }

    /// Light or dark changed, or the Desktop Look was turned on or off: the panel follows.
    private func recolor() { applyLook() }

    /// The panel's corners in the iOS look: the field's 8 pt box 12 pt inside it, concentric.
    private static let glassRadius: CGFloat = 20

    /// The iOS look: a glass panel (the system's own shadow and edge) under the page-coloured veil, with the field a
    /// faint well on it. The Desktop
    /// Look: the solid editor panel with its line and drawn shadow, as before.
    private func applyLook() {
        let desktop = Theme.isDesktop
        if desktop { if glassBack.effect != nil { glassBack.effect = nil } } else if !(glassBack.effect is UIGlassEffect) {
            glassBack.effect = UIGlassEffect(style: .regular)
        }
        glassBack.isHidden = desktop
        veil.isHidden = desktop   // L13: the Desktop Look's panel is solid already
        veil.backgroundColor = HQPalette.page.withAlphaComponent(0.94)
        // [mac] Stress test 2026-10-31: the Desktop Look's panel is the raised surface with the stronger line, over a
        // shadow dark enough to read on a dark page. In the editor colour with the pane line it was the page's own
        // colour, so the panel had no edge over the page behind it.
        let dark = traitCollection.userInterfaceStyle == .dark
        panel.backgroundColor = desktop ? ChatPalette.elevated : .clear
        panel.layer.cornerRadius = desktop ? HQShape.desktopRadius(.sheet) : Self.glassRadius
        panel.layer.borderWidth = desktop ? 1 : 0
        panel.layer.borderColor = ChatPalette.strokePrimary.resolvedColor(with: traitCollection).cgColor
        panel.layer.shadowOpacity = desktop ? (dark ? 0.6 : 0.25) : 0   // under see-through glass a drawn shadow would darken it
        fieldBox.backgroundColor = desktop ? ChatPalette.editor : Self.well
        fieldBox.layer.cornerRadius = desktop ? DesktopRows.radius : 8
        ring()
    }

    /// The field's well on the glass: a shade, so the box reads as a field without a solid grey slab.
    private static let well = UIColor { traits in
        UIColor.label.resolvedColor(with: traits).withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.1 : 0.05)
    }

    /// The field's edge, as the app's other search fields draw theirs (`DesktopSearch`): the Desktop Look's 1 pt line,
    /// and in the iOS look the well alone. [keys] Mac UI check 2026-11-13 (V35, L13): the 2 pt accent ring while it
    /// had the caret (always, while the panel is up) was the hardest line on the window; the caret says where typing goes.
    private func ring() {
        let desktop = Theme.isDesktop
        fieldBox.layer.borderColor = ChatPalette.strokeSecondary.resolvedColor(with: traitCollection).cgColor
        fieldBox.layer.borderWidth = desktop ? 1 : 0
    }

    // MARK: Results

    private func typed() {
        let query = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        groups = query.isEmpty ? search.recent() : search.results(for: query)
        marked = IndexPath(row: 0, section: 0)
        table.reloadData()
        table.backgroundView = groups.isEmpty ? emptyNote(query) : nil
        let room = min(max(view.bounds.height - Self.topRoom(view.bounds.height) - 80, 120), 460)
        tableHeight.constant = groups.isEmpty ? 80 : min(room, table.contentSize.height + 12)
        view.layoutIfNeeded()
        tableHeight.constant = groups.isEmpty ? 80 : min(room, table.contentSize.height + 12)
        if !groups.isEmpty { table.scrollToRow(at: marked, at: .none, animated: false) }
    }

    private func emptyNote(_ query: String) -> UIView {
        let note = UILabel()
        note.text = query.isEmpty ? "No recent chats" : "No results for \u{201C}\(query)\u{201D}"
        note.font = HQFont.preferred(.callout)
        note.textColor = HQPalette.label2
        note.textAlignment = .center
        return note
    }

    func numberOfSections(in tableView: UITableView) -> Int { groups.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { groups[section].rows.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        (field.text ?? "").isEmpty ? "Recent" : groups[section].kind.title
    }

    /// [mac] Mac polish #63: a heading is the look's section label: the Desktop Look's tracked capitals, as every other
    /// heading in that look, and More's search headings (`hqMacSectionHeader`) in the iOS look.
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView,
              let title = self.tableView(tableView, titleForHeaderInSection: section) else { return }
        var content = UIListContentConfiguration.header().hqScaled()
        if Theme.isDesktop {
            content.attributedText = NSAttributedString(string: title.uppercased(), attributes: DesktopLayout.labelAttributes())
        } else {
            content.text = title
        }
        header.contentConfiguration = content.hqMacSectionHeader()
        header.accessibilityLabel = title
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        let group = groups[indexPath.section]
        let item = group.rows[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell().hqScaled()
        content.text = item.title
        content.textProperties.font = HQFont.preferred(.body)
        content.textProperties.color = HQPalette.label
        content.secondaryText = item.detail.isEmpty ? nil : item.detail
        content.secondaryTextProperties.font = HQFont.preferred(.footnote)
        content.secondaryTextProperties.color = HQPalette.label2
        content.secondaryTextProperties.numberOfLines = 1
        let picture = search.quickPicture(group.kind, item, side: 24, traits: tableView.traitCollection)   // [mac] Mac polish #63
        content.image = picture.image
        if picture.glyph { content.imageProperties.tintColor = HQPalette.label2 }
        content.imageProperties.maximumSize = CGSize(width: 24, height: 24)
        content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 24)   // faces and glyphs in one column
        content.imageToTextPadding = 12
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "open-quickly.\(group.kind.rawValue).\(item.id)"
        cell.backgroundConfiguration = rowBackground(indexPath == marked)
        return cell
    }

    /// The marked row: the window's selection (`MacSelection`), in the accent, as the field has the focus.
    private func rowBackground(_ marked: Bool) -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.clear()
        if marked {
            background.backgroundColor = MacSelection.accent
            background.cornerRadius = MacSelection.radius
        }
        return background
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        marked = indexPath
        openMarked()
    }

    // MARK: Keys

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(moveUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(moveDown)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close)),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }   // before the field's own caret moves
        return commands
    }

    /// Only a pointer that moved: the panel opening under a resting pointer leaves the first result marked.
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .changed, let path = table.indexPathForRow(at: recognizer.location(in: table)),
              path != marked else { return }
        let old = marked
        marked = path
        for p in [old, path] { table.cellForRow(at: p)?.backgroundConfiguration = rowBackground(p == path) }
    }

    @objc private func moveUp() { move(by: -1) }
    @objc private func moveDown() { move(by: 1) }

    private func move(by step: Int) {
        let flat = groups.indices.flatMap { section in groups[section].rows.indices.map { IndexPath(row: $0, section: section) } }
        guard let at = flat.firstIndex(of: marked) else { return }
        let next = flat[max(0, min(flat.count - 1, at + step))]
        guard next != marked else { return }
        let old = marked
        marked = next
        for path in [old, next] { table.cellForRow(at: path)?.backgroundConfiguration = rowBackground(path == next) }
        table.scrollToRow(at: next, at: .none, animated: false)
    }

    private func openMarked() {
        guard marked.section < groups.count, marked.row < groups[marked.section].rows.count else { return }
        let kind = groups[marked.section].kind
        let item = groups[marked.section].rows[marked.row]
        AppLog.note("keys", "open quickly: \(kind.rawValue)")
        dismiss(animated: false) { [search, showMore, ownTab] in   // [mac-feel] at once: Return no longer waits for a fade-out
            if ownTab(kind, item) { return }
            showMore()
            search.open(kind, item)
        }
    }

    #if DEBUG
    /// MacShots' nav tour: the panel on show opens its marked row, as Return would.
    static func debugOpenMarked() { shown?.openMarked() }
    #endif

    /// [mac-feel] Fading out after Esc or a click outside (`hqHidePanel`).
    private var closing = false
    /// [mac-feel] The fade-in played (once: not again when a sheet over the panel goes).
    private var fadedIn = false

    @objc private func close() {
        guard !closing else { return }
        closing = true
        hqHidePanel()
    }

    @objc private func tappedOutside(_ recognizer: UITapGestureRecognizer) {
        if !panel.bounds.contains(recognizer.location(in: panel)) { close() }
    }
}
#endif

#if targetEnvironment(macCatalyst)
extension MacOpenQuickly {
    /// [mac-audit G] Mac audit #15: a chat result opens from Sessions (its row marked there), a bot from Bots, a tab
    /// result shows that tab, each picked as a sidebar click picks it (the right pane follows). False: a page, a
    /// setting, an action, or a list hidden from the sidebar (Settings › Tabs): it opens from More's stack as before.
    static func openOnOwnTab(_ root: MainTabController, _ kind: MoreSearch.Kind, _ item: MoreSearch.Item) -> Bool {
        func pick(_ tab: UIViewController) {
            guard root.selectedViewController !== tab else { return }
            if let split = root.split { split.switchPlace(to: tab) { root.pick(tab) } } else { root.pick(tab) }
        }
        switch kind {
        case .sessions:
            guard let tab = root.controller(for: .sessions),
                  let session = root.services.sessions.first(where: { $0.profile + "|" + $0.id == item.id }) else { return false }
            pick(tab)
            root.sessionsViewController.openChat(session)
            return true
        case .bots:
            guard let tab = root.controller(for: .bots), root.services.bots.contains(where: { $0.id == item.id }) else { return false }
            pick(tab)
            root.botsViewController.open(item.id)
            return true
        case .goTo:
            if item.id.hasPrefix("tab-"), let index = Int(item.id.dropFirst(4)), root.placedTabs.indices.contains(index) {
                pick(root.placedTabs[index])
                return true
            }
            // [keys] Mac UI check 2026-11-13 (K4): More is out of sight on the Mac, so a page opened on its stack showed
            // with no sidebar row marked. A page that is a Tool (or a place) opens as its sidebar row's click opens it; a
            // page that lives in the Settings window opens there, as its row in that window does.
            if let tab = toolTab(root, item.id) {
                pick(tab)
                (tab as? UINavigationController)?.popToRootViewController(animated: false)
                return true
            }
            guard let page = settingsWindowPage(root, item.id) else { return false }
            if let category = page.category { return MacSettingsWindow.open(category: category, then: page.open) }
            return MacSettingsWindow.open()
        case .settings:
            // K4: a setting opens in the Settings window (⌘,'s), as that window's own search opens it: a row on its
            // first page is scrolled to and marked, any other setting's page goes beside the categories.
            guard let entry = SettingsSearch.index().first(where: { $0.id == item.id }) else { return false }
            return MacSettingsWindow.open { router in
                // As the window's search: on the Mac Attachment Limit is a row of Chat Behavior, marked in place.
                let target: SettingsSearchEntry.Target = entry.target == .root("attachment-limit") ? .root("row:attachment-limit") : entry.target
                if case .root(let id) = target, id.hasPrefix("row:") {
                    MacSettingsWindow.root?.reveal(id)
                } else {
                    SettingsNavigator.open(target, router: router, actions: SettingsFileActions(router: router))
                }
            }
        case .actions:
            return runAction(root, item.id, pick: pick)
        }
    }

    /// The Tool (or place) showing More page `id`, as the sidebar lists it (`PagesTabs.pageTabs`).
    private static func toolTab(_ root: MainTabController, _ id: String) -> UIViewController? {
        root.placedTabs.first { $0.tabBarItem.accessibilityIdentifier == "tab-page-\(id)" }
    }

    /// A More page that is the Settings window's on the Mac: its category there and how it opens (`movedFromMore`,
    /// Settings › Hermes' and Bots & Tools' rows). Nil for any other page.
    private static func settingsWindowPage(_ root: MainTabController, _ id: String)
        -> (category: SettingsCategory?, open: (SettingsRouter) -> Void)? {
        switch id {
        case PagesTabs.settingsRowID:
            return (nil, { _ in })
        case "passwords":
            return (.gateway, { SettingsNavigator.openRoot("vault", router: $0) })
        case "capabilities", "connectors", ComposioRow.id:
            return (.tools, { SettingsNavigator.openRoot(id, router: $0) })
        case "profiles", "messaging", "webhooks", "import-sessions":
            guard let row = root.pages?.moreSections().flatMap({ $0.rows() }).first(where: { $0.id == id }) else { return nil }
            return (.tools, { router in if let page = row.make() { router.push(page) } })
        default:
            return nil
        }
    }

    /// K3, K4: an action result run where its own key, button or sidebar row runs it, not from More's hidden stack.
    /// False: More's own (`MoreSearchUI.run`).
    private static func runAction(_ root: MainTabController, _ id: String, pick: (UIViewController) -> Void) -> Bool {
        switch id {
        case "new-chat":
            // File › New Chat (⌘N): its bot and project, the right pane following (the result used the first bot).
            guard let app = UIApplication.shared.delegate as? AppDelegate else { return false }
            app.hqNewChat(nil)
            return true
        case "new-bot":
            // The sidebar's + New Bot.
            guard let organizer = root.botsViewController.organizer else { return false }
            organizer.newBot()
            return true
        case "new-task":
            guard let tab = root.placedTabs.first(where: { ($0 as? UINavigationController)?.viewControllers.first is KanbanViewController }),
                  let stack = tab as? UINavigationController, let board = stack.viewControllers.first as? KanbanViewController else { return false }
            pick(tab)
            stack.popToRootViewController(animated: false)
            DispatchQueue.main.async { board.newTask() }
            return true
        case "restart-gateway", "update-hermes":
            // Status & Maintenance, the sidebar's Tool, where both are.
            guard let tab = toolTab(root, "command-center") else { return false }
            pick(tab)
            (tab as? UINavigationController)?.popToRootViewController(animated: false)
            return true
        case "perf-logs":
            return MacSettingsWindow.open(category: .about) { SettingsNavigator.openRoot("about", router: $0) }
        default:
            return false
        }
    }
}
#endif

#if targetEnvironment(macCatalyst)
extension UIViewController {
    /// [mac-feel] Shows a Mac panel over the window (⌘K, Commands, Models). It is presented at once, so its field has
    /// the caret from the first frame and a key typed straight after the shortcut lands in it; the panel fades in on
    /// its own once it is on screen (`hqPanelAppeared`). The system's cross-dissolve gave the caret only when it ended and dropped the keys typed before then.
    func hqShowPanel(_ panel: UIViewController) {
        present(panel, animated: false)
    }

    /// [mac-feel] From the panel's `viewDidAppear`: its short fade-in. On what the panel holds, where the layers are in
    /// the window (a fade added before that never played) and UIKit's own end of the presentation leaves them alone.
    func hqPanelAppeared() {
        view.subviews.forEach { $0.hqFadeIn() }
    }

    /// [mac-feel] The panel on show goes without a pick (Esc, a click outside): a short fade of its own, taking no more
    /// clicks. A pick does not come here: it dismisses at once, so what was picked opens without waiting for a fade.
    func hqHidePanel(then done: (() -> Void)? = nil) {
        view.isUserInteractionEnabled = false
        view.hqFadeOut {
            guard self.presentingViewController != nil, !self.isBeingDismissed else { done?(); return }
            self.dismiss(animated: false, completion: done)
        }
    }
}
#endif
