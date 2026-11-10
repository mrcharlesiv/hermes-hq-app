// [manual-order] The Sessions list's hand-picked orders (tester and the owner, Nous Discord 2026-10-29):
// hold a chat and drag it to a new place in its group (Sort By becomes Manual, as the desktop's drag picks Manual), or
// its menu's Move Up / Move Down under Manual; a project's or bot's header holds Add to Favorites (projects), Move Up,
// Move Down and Reorder…, which opens the Reorder page. Orders are kept on the device per account (`SessionStore`).
// [drag-to-project] Under Group By Project a chat dragged onto another project (its header, or its rows) moves there,
// as Move to Project does (owner 2026-10-30); the project's header lights up while the chat is held over it.

import UIKit

/// What a row drag carries (a drop from anywhere else is refused).
private let rowDrag = "sessions.row-drag"

extension SessionsViewController {
    // MARK: - Groups

    /// The project keys (or bot profiles) of the groups drawn, in their order.
    func shownGroupKeys(bots: Bool) -> [String] {
        groups.compactMap { bots ? SessionListPipeline.botProfile($0.id) : SessionListPipeline.projectKey($0.id) }
    }

    /// A project or bot group's header actions; nil for any other group.
    func headerOrder(for group: SessionGroup, section: Int) -> SessionHeaderOrder? {
        let bots: Bool, key: String
        if let project = SessionListPipeline.projectKey(group.id) { bots = false; key = project }
        else if let profile = SessionListPipeline.botProfile(group.id) { bots = true; key = profile }
        else { return nil }
        let favorites = bots ? [] : store?.favoriteProjects ?? []
        let favorite = favorites.contains(key)
        // A favorite moves among the favorites, the rest among the rest.
        let lane = shownGroupKeys(bots: bots).filter { favorites.contains($0) == favorite }
        let index = lane.firstIndex(of: key) ?? 0
        return SessionHeaderOrder(
            favorite: favorite,
            onFavorite: bots ? nil : { [weak self] in self?.setFavoriteProject(key, !favorite) },
            onMoveUp: index > 0 ? { [weak self] in self?.moveGroup(key, by: -1, bots: bots) } : nil,
            onMoveDown: index < lane.count - 1 ? { [weak self] in self?.moveGroup(key, by: 1, bots: bots) } : nil,
            reorderTitle: bots ? "Reorder Bots…" : "Reorder Projects…",
            onReorder: { [weak self] in self?.openGroupOrder(bots: bots) })
    }

    func setFavoriteProject(_ key: String, _ on: Bool) {
        Haptics.play(.selection)
        store?.setFavoriteProject(key, on)
        reload(animated: true)
    }

    func moveGroup(_ key: String, by delta: Int, bots: Bool) {
        Haptics.play(.selection)
        store?.moveGroup(key, by: delta, shown: shownGroupKeys(bots: bots), bots: bots)
        reload(animated: true)
    }

    /// The Reorder page's rows: the groups as the list draws them, then the projects (or bots) with no chat listed now.
    private func groupOrderItems(bots: Bool) -> [SessionGroupOrderPage.Item] {
        guard let store else { return [] }
        var titles: [String: String] = [:]
        var all: [String] = []
        if bots {
            for bot in chipBots { titles[bot.id] = bot.name; all.append(bot.id) }
        } else {
            for entry in store.projectEntries(order: chipBots.map(\.id)) { titles[entry.key] = entry.label; all.append(entry.key) }
        }
        let shown = shownGroupKeys(bots: bots)
        for group in groups {
            guard let key = bots ? SessionListPipeline.botProfile(group.id) : SessionListPipeline.projectKey(group.id) else { continue }
            if titles[key] == nil { titles[key] = group.title }
        }
        let keys = shown + all.filter { !shown.contains($0) }
        return keys.map { SessionGroupOrderPage.Item(key: $0, title: titles[$0] ?? $0) }
    }

    /// Filter › Group By › Reorder Projects… (or Reorder Bots…), or a header's hold menu.
    func openGroupOrder(bots: Bool) {
        guard let store else { return }
        let custom = !(bots ? store.device.botGroupOrder : store.device.projectOrder).isEmpty
        let sheet = SessionGroupOrderPage.sheet(
            bots: bots, items: groupOrderItems(bots: bots), favorites: bots ? [] : store.favoriteProjects, custom: custom,
            onOrder: { [weak self] keys in
                self?.store?.setGroupOrder(keys, bots: bots)
                self?.reload(animated: false)
            },
            onFavorite: { [weak self] key, on in
                self?.store?.setFavoriteProject(key, on)
                self?.reload(animated: false)
            },
            onDefault: { [weak self] in
                guard let self else { return [] }
                self.store?.setGroupOrder([], bots: bots)
                self.reload(animated: false)
                return self.groupOrderItems(bots: bots)
            })
        present(sheet, animated: true)
    }

    // MARK: - Chats

    /// Rows move while the list has groups to move them in: not while searching, nor under Sort By Tokens or Cost (one
    /// run with no headers, which a drag into Manual would turn into date groups under the finger).
    var rowsReorder: Bool {
        guard let store, organizer != nil, !searching else { return false }
        return !SessionListPipeline.isFlat(store.view)
    }

    /// The chat rows of a section, in their drawn order (no Show More, no Other Apps row).
    private func rowKeys(_ section: Int) -> [String] {
        guard section < groups.count else { return [] }
        return groups[section].sessions.map(SessionListPipeline.key)
    }

    /// Every drawn chat, in list order: a drag from another sort starts Manual from what is on screen, so nothing else
    /// moves.
    private var drawnKeys: [String] {
        var seen = Set<String>()     // [project-cards] a chat in New for You and its project is one place in the order
        return groups.flatMap { $0.sessions.map(SessionListPipeline.key) }.filter { seen.insert($0).inserted }
    }

    /// Under Manual, a row's menu offers Move Up / Move Down inside its group.
    func chatMoves(_ key: String) -> (up: Bool, down: Bool)? {
        guard rowsReorder, store?.view.sortBy == .manual, let path = dataSource.indexPath(for: key) else { return nil }
        let keys = rowKeys(path.section)
        guard let index = keys.firstIndex(of: key) else { return nil }
        return (index > 0, index < keys.count - 1)
    }

    func moveChat(_ key: String, by delta: Int) {
        guard let path = dataSource.indexPath(for: key) else { return }
        let keys = rowKeys(path.section)
        guard let from = keys.firstIndex(of: key), keys.indices.contains(from + delta) else { return }
        Haptics.play(.selection)
        store?.reorderChats(SessionManualOrder.moved(keys, from: from, to: from + delta), drawn: drawnKeys)
        reload(animated: true)
    }
}

extension SessionsViewController: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        // [project-cards] A chat's second row (in its project) stays put: its first row is the one to drag.
        guard rowsReorder, let key = dataSource.itemIdentifier(for: indexPath), !Self.isCopy(key), self.session(forKey: key) != nil, !isBusy(key),
              rowKeys(indexPath.section).count > 1 || projectDrops else { return [] }
        session.localContext = rowDrag
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = key
        return [item]
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
        true
    }

    func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
        guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds.insetBy(dx: 6, dy: 2), cornerRadius: 14)   // as the Bots rows
        return parameters
    }

    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        session.localDragSession?.localContext as? String == rowDrag
    }

    /// The drag's row and where it would land: inside its own group, among the chats (past the last one is the last).
    private func dropPlace(_ session: UIDropSession, _ destination: IndexPath?) -> (key: String, from: Int, to: Int, section: Int)? {
        guard session.localDragSession?.localContext as? String == rowDrag,
              let key = session.localDragSession?.items.first?.localObject as? String,
              let source = dataSource.indexPath(for: key), let destination, destination.section == source.section else { return nil }
        let keys = rowKeys(source.section)
        guard keys.count > 1, let from = keys.firstIndex(of: key) else { return nil }
        return (key, from, min(destination.item, keys.count - 1), source.section)
    }

    // MARK: Onto another project

    /// Chats move between projects by drag while the list is grouped by project.
    private var projectDrops: Bool { store?.view.groupBy == .project }

    /// The group under the finger: the last one whose top (its header, else its first row) is above it, so a folded
    /// project is its header and an open one its header and rows.
    private func section(at point: CGPoint) -> Int? {
        let kind = UICollectionView.elementKindSectionHeader
        var found: Int?
        for section in 0..<min(collectionView.numberOfSections, groups.count) {
            let top = drawsHeader(section)
                ? collectionView.layoutAttributesForSupplementaryElement(ofKind: kind, at: IndexPath(item: 0, section: section))?.frame.minY
                : collectionView.numberOfItems(inSection: section) > 0
                    ? collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: section))?.frame.minY : nil
            guard let top else { continue }
            if top > point.y { break }
            found = section
        }
        return found
    }

    /// The project a dragged chat is held over, when it would move there: not Home (a chat leaves a project only by its
    /// folder), not the project it is in already, and not one a bot can't be given (no folder to give it).
    private func dropProject(_ session: UIDropSession) -> (key: String, label: String, section: Int)? {
        guard projectDrops, rowsReorder, session.localDragSession?.localContext as? String == rowDrag,
              let key = session.localDragSession?.items.first?.localObject as? String, let chat = self.session(forKey: key),
              let store, let section = section(at: session.location(in: collectionView)),
              let project = SessionListPipeline.projectKey(groups[section].id), project != SessionProjects.homeKey else { return nil }
        let current = store.project(of: chat).map { SessionProjects.key($0, profile: chat.profile) } ?? SessionProjects.homeKey
        guard project != current else { return nil }
        let held = store.projectHolders(key: project).contains { $0.profile == chat.profile }
        guard held || !project.hasPrefix("id:") else { return nil }
        return (project, groups[section].title, section)
    }

    /// Lights the project's header (nil: none), with a tick as it changes, as a list's drop target does.
    private func showDropTarget(_ section: Int?) {
        let id = section.map { groups[$0].id }
        guard id != dropTargetGroup else { return }
        if id != nil { Haptics.play(.selection) }
        dropTargetGroup = id
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        // Over another project: no gap opens among its rows (the chat takes its place by the list's sort), its header
        // lights up instead.
        if let target = dropProject(session) {
            showDropTarget(target.section)
            return UICollectionViewDropProposal(operation: .move, intent: .unspecified)
        }
        showDropTarget(nil)
        return dropPlace(session, destinationIndexPath) == nil
            ? UICollectionViewDropProposal(operation: .forbidden)
            : UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidExit session: UIDropSession) {
        showDropTarget(nil)
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: UIDropSession) {
        showDropTarget(nil)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        if let target = dropProject(coordinator.session) {
            showDropTarget(nil)
            guard let item = coordinator.items.first?.dragItem, let key = item.localObject as? String,
                  let chat = session(forKey: key) else { return }
            // The row shrinks into the project's header (into the finger when the header has scrolled off), then the
            // move runs; the row joins the project once the gateway has moved it.
            let kind = UICollectionView.elementKindSectionHeader
            let header = collectionView.layoutAttributesForSupplementaryElement(ofKind: kind, at: IndexPath(item: 0, section: target.section))?.frame
            let point = coordinator.session.location(in: collectionView)
            let center = header.flatMap { collectionView.bounds.intersects($0) ? CGPoint(x: point.x, y: $0.midY) : nil } ?? point
            coordinator.drop(item, to: UIDragPreviewTarget(container: collectionView, center: center,
                                                           transform: CGAffineTransform(scaleX: 0.2, y: 0.2)))
            organizer?.move(chat, toProject: target.key, label: target.label)
            return
        }
        guard let place = dropPlace(coordinator.session, coordinator.destinationIndexPath),
              let item = coordinator.items.first?.dragItem else { return }
        guard place.from != place.to else { return }
        let keys = SessionManualOrder.moved(rowKeys(place.section), from: place.from, to: place.to)
        Haptics.play(.selection)
        store?.reorderChats(keys, drawn: drawnKeys)
        reload(animated: true)
        if let landed = dataSource.indexPath(for: place.key) { coordinator.drop(item, toItemAt: landed) }
    }
}
