// More search, the phone's command palette (docs/spec/3x-morepages.md §18): More's bar magnifier unfolds a search
// field (`PageBarCapsule`); while something is typed the grouped rows give way to results in Go To, Bots, Sessions,
// Settings and Actions (`MoreSearch`); emptying the field or Cancel brings More back. A result opens on More's own
// stack and the query stays, so Back returns to the same results. Return opens the first result.

import UIKit

@MainActor
final class MoreSearchUI: NSObject, UISearchResultsUpdating, UISearchBarDelegate, UICollectionViewDelegate {
    private weak var host: UIViewController?
    private let sections: () -> [MoreSection]
    private(set) var capsule: PageBarCapsule?
    private var list: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private var groups: [MoreSearch.Group] = []
    private var rows: [String: MoreRow] = [:]          // the More rows on show, by id
    private var allSessions = false
    private var query = ""
    private static let showAll = "sessions/__show-all"

    init(host: UIViewController, sections: @escaping () -> [MoreSection]) {
        self.host = host
        self.sections = sections
        super.init()
        let capsule = PageBarCapsule.search(on: host, page: "more", placeholder: MoreSearch.fieldPlaceholder, updater: self)
        capsule.searchItem?.accessibilityLabel = MoreSearch.placeholder
        capsule.searchController?.searchBar.searchTextField.accessibilityLabel = MoreSearch.placeholder
        capsule.searchController?.searchBar.autocapitalizationType = .none
        capsule.searchController?.searchBar.autocorrectionType = .no
        capsule.searchController?.searchBar.returnKeyType = .go
        self.capsule = capsule
        host.navigationItem.rightBarButtonItems = [capsule.searchItem].compactMap { $0 } + (host.navigationItem.rightBarButtonItems ?? [])
        build(in: host.view)
    }

    /// The page shows again: a typed query unfolds the field with its results.
    func restore() { capsule?.restoreIfTyped() }

    // MARK: The results list

    private func build(in view: UIView) {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.backgroundColor = HQPalette.groupedPage
        list = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        list.translatesAutoresizingMaskIntoConstraints = false
        list.backgroundColor = HQPalette.groupedPage
        list.delegate = self
        list.keyboardDismissMode = .onDrag
        list.accessibilityIdentifier = "more.results"
        list.isHidden = true
        view.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: view.topAnchor), list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: view.trailingAnchor), list.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self else { return }
            if id == Self.showAll {
                var content = UIListContentConfiguration.cell().hqScaled()
                content.text = self.groups.first { $0.kind == .sessions }?.showAll
                content.textProperties.color = HQPalette.tint
                content.textProperties.font = HQFont.preferred(.body)
                cell.contentConfiguration = content
                cell.accessories = []
                cell.accessibilityIdentifier = "more.results.show-all"
                return
            }
            guard let (kind, item) = self.item(id) else { return }
            var content = UIListContentConfiguration.subtitleCell().hqScaled()
            content.text = item.title
            content.textProperties.font = HQFont.preferred(.body)
            content.textProperties.color = HQPalette.label
            content.secondaryText = item.detail.isEmpty ? nil : item.detail
            content.secondaryTextProperties.font = HQFont.preferred(.footnote)
            content.secondaryTextProperties.color = HQPalette.label2
            content.secondaryTextProperties.numberOfLines = 2
            content.textToSecondaryTextVerticalPadding = 2
            content.image = self.tile(kind, item)
            content.imageProperties.maximumSize = CGSize(width: 29, height: 29)
            content.imageToTextPadding = 14
            // A row whose text can wrap: 12 pt above and below.
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: content.directionalLayoutMargins.leading,
                                                                       bottom: 12, trailing: content.directionalLayoutMargins.trailing)
            cell.contentConfiguration = content
            cell.accessories = kind == .actions ? [] : [.hqDisclosure()]   // [mac] Stress test 2026-10-28 #51 (round 6): the quiet Mac chevron
            cell.accessibilityIdentifier = "more.result.\(kind.rawValue).\(item.id)"
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, path in
            var content = UIListContentConfiguration.header().hqScaled()
            content.text = self.flatMap { path.section < $0.groups.count ? $0.groups[path.section].kind.title : nil }
            header.contentConfiguration = content.hqMacSectionHeader()   // [mac] Stress test 2026-10-28 #52
            header.accessibilityIdentifier = self.flatMap { path.section < $0.groups.count ? "more.results.\($0.groups[path.section].kind.rawValue)" : nil }
        }
        dataSource = UICollectionViewDiffableDataSource<String, String>(collectionView: list) { cv, path, id in
            cv.dequeueConfiguredReusableCell(using: cell, for: path, item: id)
        }
        dataSource.supplementaryViewProvider = { cv, _, path in cv.dequeueConfiguredReusableSupplementary(using: header, for: path) }
    }

    private func item(_ id: String) -> (MoreSearch.Kind, MoreSearch.Item)? {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = MoreSearch.Kind(rawValue: parts[0]),
              let item = groups.first(where: { $0.kind == kind })?.rows.first(where: { $0.id == parts[1] }) else { return nil }
        return (kind, item)
    }

    func tile(_ kind: MoreSearch.Kind, _ item: MoreSearch.Item) -> UIImage {
        MoreViewController.tile(row(kind, item))
    }

    /// The result as a More row: a page's own row, else its kind's tile and symbol.
    private func row(_ kind: MoreSearch.Kind, _ item: MoreSearch.Item) -> MoreRow {
        if kind == .goTo, let row = rows[item.id] { return row }
        let colour: UIColor
        let symbol: String
        switch kind {
        case .goTo: colour = .systemBlue; symbol = item.symbol ?? "arrow.right"
        case .bots: colour = .systemIndigo; symbol = "person.crop.circle"
        case .sessions: colour = .systemTeal; symbol = "bubble.left.and.bubble.right"
        case .settings: colour = .systemGray; symbol = "gearshape"
        case .actions: colour = .systemOrange; symbol = item.symbol ?? "bolt"
        }
        return MoreRow(id: item.id, title: item.title, symbol: symbol, image: nil, tile: colour, make: { nil })
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] Mac polish #63 (Oct 31 Low 26): Open Quickly's picture for a result. A chat wears its bot's face and a bot
    /// its own, in both looks (every chat had one teal tile, every bot one indigo tile); in the Desktop Look a page, tab,
    /// setting or action is the look's outline glyph, as More and the sidebar draw them (`macGlyph`), not a bright
    /// tile. `glyph`: a template for the cell to tint.
    func quickPicture(_ kind: MoreSearch.Kind, _ item: MoreSearch.Item, side: CGFloat, traits: UITraitCollection) -> (image: UIImage?, glyph: Bool) {
        switch kind {
        case .bots, .sessions:
            // A chat's id is "profile|session".
            let profile = kind == .bots ? item.id : String(item.id.prefix { $0 != "|" })
            let id = profile.isEmpty ? "default" : profile
            let head = MorePages.context?.bots.first { $0.id == id }?.head
            return (BotFaces.shared.faceImage(profile: id, raw: head, side: side, scale: traits.displayScale,
                                              dark: traits.userInterfaceStyle == .dark, shape: .appIcon), false)
        case .goTo, .settings, .actions:
            guard Theme.isDesktop else { return (tile(kind, item), false) }
            return (MoreViewController.macGlyph(row(kind, item)), true)
        }
    }
    #endif

    // MARK: Searching

    func updateSearchResults(for searchController: UISearchController) {
        capsule?.updateSearchState()
        let text = searchController.searchBar.text ?? ""
        returnKey(searchController.searchBar)
        if text != query { allSessions = false }
        query = text
        refresh()
    }

    /// Return opens the first result. The capsule is the search bar's delegate; the field's own action is free.
    private var wiredReturn = false
    private func returnKey(_ bar: UISearchBar) {
        guard !wiredReturn else { return }
        wiredReturn = true
        bar.searchTextField.addAction(UIAction { [weak self] _ in self?.openFirst() }, for: .primaryActionTriggered)
    }

    private func openFirst() {
        guard let first = MoreSearch.first(groups) else { return }
        open(first.kind, first.item)
    }

    private func refresh() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, MorePages.context != nil else {
            groups = []
            list.isHidden = true
            list.backgroundView = nil
            return
        }
        groups = results(for: trimmed, allSessions: allSessions)
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for group in groups {
            snapshot.appendSections([group.kind.rawValue])
            snapshot.appendItems(group.rows.map { group.kind.rawValue + "/" + $0.id }, toSection: group.kind.rawValue)
            if group.showAll != nil { snapshot.appendItems([Self.showAll], toSection: group.kind.rawValue) }
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        list.isHidden = false
        if groups.isEmpty {
            let miss = UIContentUnavailableView(configuration: PageStates.searchMiss(trimmed))
            miss.accessibilityIdentifier = "more.results.miss"
            list.backgroundView = miss
        } else {
            list.backgroundView = nil
        }
    }

    /// What `query` finds, grouped; also what Open Quickly shows on the Mac (`MacOpenQuickly`).
    func results(for trimmed: String, allSessions: Bool = false) -> [MoreSearch.Group] {
        guard let context = MorePages.context else { return [] }
        let shown = sections().flatMap { $0.rows() }.filter { $0.card == nil }
        rows = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tabs = MainTabController.current?.placedTabs ?? []   // [mac-sidebar] every sidebar place
        var pages: [MoreSearch.Item] = tabs.enumerated().compactMap { index, tab in
            guard let title = tab.tabBarItem.title, title != "More" else { return nil }
            return MoreSearch.Item(id: "tab-\(index)", title: title, detail: "Tab", symbol: Self.tabSymbols[title])
        }
        // Audit 863 (08d-4): each page's own search words ("telegram" finds Messaging, "memory" Star Map).
        pages += shown.map { MoreSearch.Item(id: $0.id, title: $0.title, keywords: MorePages.keywords(for: $0.id)) }
        let bots = context.botChoices.map { bot in
            MoreSearch.Item(id: bot.id, title: bot.name, detail: bot.id == "default" || bot.id == bot.name ? "Bot" : "Bot · \(bot.id)",
                            keywords: [bot.id, bot.role ?? ""])
        }
        let sessions = context.services.sessions.filter { !Self.hiddenSession($0) }.map { session in
            MoreSearch.Item(id: session.profile + "|" + session.id, title: Self.sessionTitle(session),
                            detail: Self.sessionDetail(session, context: context), keywords: [session.preview ?? ""])
        }
        let hasKanban = Self.kanbanTab() != nil
        // Kanban Tab only shows once the board is known, as Settings' own search filters it. [kanban-tab-one] It lives on
        // Settings › Appearance › Tabs now, and is found while Artifacts has the tab too (it was hidden then, when
        // turning Kanban on is what it's for). [mac] Nor Thinking Bar where the Desktop Look hides it (Mac polish #37).
        let kanbanTabShown = TabOrderPage.kanbanChoice(context.services.account) != nil
        let settings = SettingsSearch.index().filter {
            if case .action = $0.target { return false }
            return ($0.target != .root(SettingsSearch.kanbanTabTarget) || kanbanTabShown) && SettingsRootModel.searchRowShown($0)
        }
        let facts = MoreSearch.ActionFacts(writable: !context.readOnly, kanban: hasKanban,
                                           commandCenter: rows["command-center"] != nil,
                                           version: (context.services as? SettingsServices)?.gatewayVersion)
        return MoreSearch.results(query: trimmed, pages: pages, bots: bots, sessions: sessions, settings: settings,
                                  actions: MoreSearch.actions(facts), allSessions: allSessions)
    }

    /// [mac] Stress test 2026-10-28 #61: what Open Quickly offers before anything is typed, the latest chats first.
    func recent(limit: Int = 8) -> [MoreSearch.Group] {
        guard let context = MorePages.context else { return [] }
        let latest = context.services.sessions.filter { !Self.hiddenSession($0) }
            .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
            .prefix(limit)
            .map { session in
                MoreSearch.Item(id: session.profile + "|" + session.id, title: Self.sessionTitle(session),
                                detail: Self.sessionDetail(session, context: context))
            }
        return latest.isEmpty ? [] : [MoreSearch.Group(kind: .sessions, rows: Array(latest), total: latest.count)]
    }

    private static let tabSymbols = ["Bots": "person.2", "Sessions": "bubble.left.and.bubble.right", "Jobs": "calendar.badge.clock",
                                     "Kanban": "rectangle.split.3x1", "Artifacts": "photo.on.rectangle"]

    private static func hiddenSession(_ session: SessionSummary) -> Bool {
        let title = session.title
        return title == RosterRules.botChatTitle || title.hasPrefix("Group: ")
    }

    private static func sessionTitle(_ session: SessionSummary) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled Chat" : title
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static func sessionDetail(_ session: SessionSummary, context: MorePages.Context) -> String {
        let bot = context.botName(session.profile)
        guard let date = session.lastActive else { return bot }
        return bot + " · " + day.string(from: date)
    }

    private static func kanbanTab() -> (index: Int, page: KanbanViewController)? {
        for (index, tab) in (MainTabController.current?.placedTabs ?? []).enumerated() {
            if let page = (tab as? UINavigationController)?.viewControllers.first as? KanbanViewController { return (index, page) }
        }
        return nil
    }

    // MARK: Opening

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        if id == Self.showAll {
            allSessions = true
            refresh()
            return
        }
        guard let (kind, item) = item(id) else { return }
        open(kind, item)
    }

    func open(_ kind: MoreSearch.Kind, _ item: MoreSearch.Item) {
        guard let host, let navigation = host.navigationController, let context = MorePages.context,
              navigation.topViewController === host, navigation.transitionCoordinator == nil else { return }
        capsule?.searchController?.searchBar.resignFirstResponder()
        switch kind {
        case .goTo:
            if item.id.hasPrefix("tab-"), let index = Int(item.id.dropFirst(4)) {
                selectTab(index)
            } else if let page = rows[item.id]?.make() {
                navigation.pushViewController(page, animated: true)
            }
        case .bots:
            guard let bot = context.bots.first(where: { $0.id == item.id }) else { return }
            Haptics.play(.soft)
            let chat = context.makeChat(context.services.chat(for: bot))
            chat.hidesBottomBarWhenPushed = true
            chat.navigationItem.largeTitleDisplayMode = .never
            ChatViewController.push(chat, on: navigation) {}
        case .sessions:
            guard let session = context.services.sessions.first(where: { $0.profile + "|" + $0.id == item.id }) else { return }
            MorePages.openChat(session, on: navigation)
        case .settings:
            guard let entry = SettingsSearch.index().first(where: { $0.id == item.id }) else { return }
            let root = openSettings(on: navigation, services: context.services) { router in
                // A row on Settings' first page is scrolled to and marked there, as Settings' own search does.
                if case .root(let id) = entry.target, id.hasPrefix("row:") { return }
                SettingsNavigator.open(entry.target, router: router, actions: SettingsFileActions(router: router))
            }
            if case .root(let id) = entry.target, id.hasPrefix("row:") { root.reveal(id) }
        case .actions:
            run(item.id, context: context, navigation: navigation)
        }
    }

    private func selectTab(_ index: Int) {
        guard let root = MainTabController.current, root.placedTabs.indices.contains(index) else { return }
        root.show(root.placedTabs[index])
    }

    /// Settings' root goes on More's stack first, so Back from the setting reads "Settings" as it does from More.
    @discardableResult
    private func openSettings(on navigation: UINavigationController, services: any AppServices,
                              then: (SettingsRouter) -> Void) -> SettingsRootController {
        let root = SettingsRootController(services: services)
        root.router.navigation = navigation
        let before = navigation.viewControllers.count
        navigation.setViewControllers(navigation.viewControllers + [root], animated: false)
        then(root.router)
        if navigation.viewControllers.count == before + 1 {
            // The setting lives on Settings' own first page: nothing more to push.
            root.loadViewIfNeeded()
        }
        return root
    }

    private func run(_ action: String, context: MorePages.Context, navigation: UINavigationController) {
        guard let host else { return }
        switch action {
        case "new-chat":
            // [customtabs] With Sessions hidden the new chat opens on Bots (its push goes there).
            guard let root = MainTabController.current, let organizer = root.sessionsViewController.organizer,
                  let stack = root.listStack(.sessions) else { return }
            root.show(stack)
            stack.popToRootViewController(animated: false)
            organizer.newChat(profile: context.botChoices.first?.id ?? "default")
        case "new-bot":
            NewBotFlow.present(from: host, services: context.services)
        case "new-task":
            guard let kanban = Self.kanbanTab() else { return }
            selectTab(kanban.index)
            kanban.page.navigationController?.popToRootViewController(animated: false)
            DispatchQueue.main.async { kanban.page.newTask() }
        case "restart-gateway", "update-hermes":
            if let page = rows["command-center"]?.make() { navigation.pushViewController(page, animated: true) }
        case "perf-logs":
            openSettings(on: navigation, services: context.services) { router in SettingsNavigator.openRoot("about", router: router) }
        default:
            break
        }
    }
}
