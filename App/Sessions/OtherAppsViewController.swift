// The Other Apps page (Sessions › Other Apps, Show › Outside Chats on): a section per messaging platform, the platform
// with the newest chat first, its chats newest first (`SessionStore.appSections`). It is the Sessions list's own list
// for those chats: the same rows in each look, headers and hairlines as the list draws them, and the same row actions
// (the long-press menu, the swipes) from the list's `SessionsOrganizer`, with pull to refresh. With Show ›
// Archived the archived platform chats are listed here too, marked.

import SwiftUI
import UIKit

final class OtherAppsViewController: UIViewController, UICollectionViewDelegate {
    private weak var list: SessionsViewController?
    private let store: SessionStore
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private var sections: [SessionGroup] = []
    private var sessionsByID: [String: SessionSummary] = [:]
    private var signatures: [String: Int] = [:]
    private var ringedKeys: Set<String> = []
    private var reloadPending = false
    private var refreshGeneration = 0
    private var lookObserver: NSObjectProtocol?

    init(list: SessionsViewController, store: SessionStore) {
        self.list = list
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = "Other Apps"
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let lookObserver { NotificationCenter.default.removeObserver(lookObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.page            // the list's page colour, in each look and theme
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = HQPalette.page
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "otherApps.list"
        view.addSubview(collectionView)
        PageBackdrop.install(in: self, clearing: [collectionView])   // [backdrop] Theme › App Background
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.pulledToRefresh() }, for: .valueChanged)
        collectionView.hqInstallRefresh(refresh)
        configureDataSource()
        lookObserver = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isViewLoaded else { return }
                self.signatures = [:]
                self.collectionView.collectionViewLayout.invalidateLayout()
                self.reload(animated: false, redrawAll: true)
            }
        }
        reload(animated: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        list?.otherAppsWillShow(self)        // Back reads "Sessions" here, not the unread count
        reload(animated: false)
        if let selected = collectionView.indexPathsForSelectedItems {
            for path in selected { collectionView.deselectItem(at: path, animated: animated) }
        }
    }

    // MARK: Layout (the Sessions list's)

    private func makeLayout() -> UICollectionViewLayout {
        let cards = UICollectionViewCompositionalLayout { [weak self] _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.backgroundColor = .clear
            config.headerMode = .supplementary
            config.headerTopPadding = 0
            config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                guard let self, let organizer = self.list?.organizer, let key = self.dataSource.itemIdentifier(for: indexPath),
                      self.list?.isBusy(key) != true, let session = self.sessionsByID[key] else { return nil }
                return organizer.leadingActions(for: session)
            }
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                guard let self, let organizer = self.list?.organizer, let key = self.dataSource.itemIdentifier(for: indexPath),
                      self.list?.isBusy(key) != true, let session = self.sessionsByID[key] else { return nil }
                return organizer.trailingActions(for: session, key: key)
            }
            config.separatorConfiguration.color = HQPalette.separator
            config.itemSeparatorHandler = { [weak self] indexPath, separator in
                var separator = separator
                separator.topSeparatorVisibility = .hidden
                separator.bottomSeparatorVisibility = Theme.isDesktop ? .hidden : .visible   // [desktoplook2] no rules
                if WorkingArc.ringHidesSeparator(indexPath, ringed: { self?.ringed($0) == true }) {
                    separator.bottomSeparatorVisibility = .hidden
                }
                separator.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: 72, bottom: 0, trailing: 20)
                return separator
            }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            section.boundarySupplementaryItems.forEach { $0.pinToVisibleBounds = false }
            BackdropCards.card(section, on: BackdropCards.on(self), header: true)   // [backdrop-cards]
            return section
        }
        BackdropCards.register(in: cards)   // [backdrop-cards]
        return cards
    }

    private func ringed(_ indexPath: IndexPath) -> Bool {
        guard let key = dataSource.itemIdentifier(for: indexPath) else { return false }
        return ringedKeys.contains(key)
    }

    private func configureDataSource() {
        let rowRegistration = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, id in
            guard let self, let list = self.list, let session = self.sessionsByID[id] else { return }
            let owner = list.owner(of: session)
            let busy = list.isBusy(id)
            let detail = list.rowDetail
            let muted = BotMuteCenter.shared.isMuted(session.profile)
            cell.contentConfiguration = UIHostingConfiguration {
                SessionRowView(session: session, ownerName: owner.name, ownerHead: owner.head,
                               time: ListTime.string(session.lastActive), busy: busy, detail: detail, muted: muted,
                               titleLines: 2)
            }
            .margins(.all, 0)
            cell.accessibilityIdentifier = "session-row-\(session.id)"
            cell.configurationUpdateHandler = { cell, state in
                #if targetEnvironment(macCatalyst)
                if DeviceWord.isMac { cell.backgroundConfiguration = MacSelection.listRow(state); return }   // [mac] Stress test 2026-10-28 #54
                #endif
                if Theme.isDesktop { cell.backgroundConfiguration = DesktopLayout.rowBackground(state); return }   // [desktoplook2]
                var background = UIBackgroundConfiguration.clear()
                background.backgroundColor = state.isHighlighted || state.isSelected ? HQPalette.cellPressed : .clear
                cell.backgroundConfiguration = background
            }
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, indexPath in
            guard let self, indexPath.section < self.sections.count else { return }
            let section = self.sections[indexPath.section]
            let title = section.title, source = section.source
            let first = indexPath.section == 0
            header.contentConfiguration = UIHostingConfiguration { SessionDateHeaderView(title: title, source: source, first: first) }.margins(.all, 0)
            header.backgroundConfiguration = .clear()
        }
        dataSource = UICollectionViewDiffableDataSource<String, String>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: rowRegistration, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    // MARK: Reload

    /// The list changed (the store, the roster, a mute): one reload on the next turn of the run loop.
    func setNeedsReload() {
        guard isViewLoaded, !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            self.reload(animated: self.view.window != nil)
        }
    }

    private func reload(animated: Bool, redrawAll: Bool = false) {
        guard isViewLoaded, let list else { return }
        sections = store.appSections()
        let rows = sections.flatMap(\.sessions)
        sessionsByID = Dictionary(rows.map { (SessionsViewController.key($0), $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for section in sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.sessions.map(SessionsViewController.key), toSection: section.id)
        }
        var next: [String: Int] = [:]
        for id in snapshot.itemIdentifiers {
            guard let session = sessionsByID[id] else { continue }
            var hasher = Hasher()
            hasher.combine(session)
            hasher.combine(ListTime.string(session.lastActive))
            let owner = list.owner(of: session)
            hasher.combine(owner.name)
            hasher.combine(owner.head)
            hasher.combine(list.isBusy(id))
            hasher.combine(list.rowDetail)
            hasher.combine(BotMuteCenter.shared.isMuted(session.profile))
            next[id] = hasher.finalize()
        }
        let changed = snapshot.itemIdentifiers.filter { id in redrawAll || signatures[id].map { $0 != next[id] } ?? false }
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }
        if redrawAll { snapshot.reloadSections(snapshot.sectionIdentifiers) }
        signatures = next
        dataSource.apply(snapshot, animatingDifferences: animated && !HQMotion.reduced)
        let rings = Set(rows.filter { SessionRowView.showsArc($0, busy: list.isBusy(SessionsViewController.key($0))) }.map(SessionsViewController.key))
        if rings != ringedKeys {
            ringedKeys = rings
            if !Theme.isDesktop { collectionView.collectionViewLayout.invalidateLayout() }
        }
        if rows.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty().hqScaled()
            empty.image = UIImage(systemName: "tray")
            empty.text = "No Chats From Other Apps"
            contentUnavailableConfiguration = BackdropState.wrap(empty)   // [backdrop-cards]
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    // MARK: Rows

    func session(forKey key: String) -> SessionSummary? { sessionsByID[key] }

    func cell(forKey key: String) -> UIView? {
        guard isViewLoaded, let indexPath = dataSource.indexPath(for: key) else { return nil }
        return collectionView.cellForItem(at: indexPath)
    }

    private func open(_ key: String) {
        guard let session = sessionsByID[key], list?.isBusy(key) != true else { return }
        list?.openChat(session)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        open(id)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let id = dataSource.itemIdentifier(for: indexPath),
              let session = sessionsByID[id], list?.isBusy(id) != true, let organizer = list?.organizer else { return nil }
        return organizer.contextMenu(for: session, key: id)
    }

    // MARK: Pull to refresh

    private func pulledToRefresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let started = Date()
        let store = store
        Task { [weak self] in
            if store.view.showArchived { _ = await store.loadArchived() }
            await store.refresh()
            let wait = max(0, 0.6 - Date().timeIntervalSince(started))
            try? await Task.sleep(for: .seconds(wait))
            guard let self, self.refreshGeneration == generation else { return }
            self.endRefreshing()
        }
        // Never spin forever if the gateway doesn't answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.refreshGeneration == generation else { return }
            self.endRefreshing()
        }
    }

    private func endRefreshing() {
        if collectionView.refreshControl?.isRefreshing == true { collectionView.refreshControl?.endRefreshing() }
    }
}
