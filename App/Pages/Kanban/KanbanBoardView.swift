// [mac-tools] Owner 2026-11-09 ("look at the design for every tool. They need a lot of work"; "Yes go ahead with what
// you sketched"): on the Mac, Kanban is a real board. One column per status across the window, each task a card, a card
// dragged onto another column moves the task there. The iPhone and iPad keep the status chips and one list
// (`KanbanViewController`'s collection view); this view stands over it on the Mac only.
//
// A column scrolls its own cards; the board scrolls sideways only when the window is too narrow for every column at
// its narrowest. The statuses the board sets itself (Scheduled, Running, Review: `KanbanModel.lockedColumns`) take no
// drop and say why in their header's tooltip. The gateway has no order inside a status, so a card can't be dropped
// back into its own column.

import SwiftUI
import UIKit

struct KanbanBoardColumn: Equatable {
    var status: String
    var ids: [String]
}

@MainActor final class KanbanBoardView: UIView {
    /// What a card draws.
    var row: (String) -> KanbanRowModel? = { _ in nil }
    var onOpen: (String) -> Void = { _ in }
    /// A card dropped on another column: the task's id and that column's status.
    var onMove: (String, String) -> Void = { _, _ in }
    var menu: (String, UIView?) -> UIMenu? = { _, _ in nil }
    /// The status a task is in now (a drop on its own column is refused).
    var statusOf: (String) -> String? = { _ in nil }

    /// The card of the task the panel beside the board shows.
    var selected: String? {
        didSet {
            guard selected != oldValue else { return }
            for column in columns { column.reconfigure([oldValue, selected].compactMap { $0 }) }
        }
    }

    private let scroll = UIScrollView()
    private var columns: [KanbanBoardColumnView] = []

    static let gap: CGFloat = 10
    static let margin: CGFloat = 16
    /// The narrowest a column gets before the board scrolls sideways instead.
    static var narrowest: CGFloat { HQFont.scaled(212) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.alwaysBounceHorizontal = false
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.accessibilityIdentifier = "kanban.board.columns"
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `changed`: cards to draw again (their words changed).
    func apply(_ next: [KanbanBoardColumn], changed: Set<String>, animated: Bool) {
        if columns.map(\.status) != next.map(\.status) {
            columns.forEach { $0.removeFromSuperview() }
            columns = next.map { KanbanBoardColumnView(status: $0.status, board: self) }
            columns.forEach(scroll.addSubview)
            setNeedsLayout()
        }
        for (view, column) in zip(columns, next) { view.apply(column.ids, changed: changed, animated: animated) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        guard !columns.isEmpty else { return }
        let count = CGFloat(columns.count)
        let room = bounds.width - Self.margin * 2 - Self.gap * (count - 1)
        let width = max(Self.narrowest, (room / count).rounded(.down))
        let height = max(0, bounds.height - 4 - Self.margin)
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let total = Self.margin * 2 + width * count + Self.gap * (count - 1)
        for (index, column) in columns.enumerated() {
            let x = Self.margin + CGFloat(index) * (width + Self.gap)
            column.frame = CGRect(x: rightToLeft ? total - x - width : x, y: 4, width: width, height: height)
        }
        let size = CGSize(width: max(total, bounds.width), height: bounds.height)
        if scroll.contentSize != size { scroll.contentSize = size }
    }

    /// The card of `id`, when it is on screen (a menu's or an alert's anchor).
    func card(_ id: String) -> UIView? {
        for column in columns { if let cell = column.cell(id) { return cell } }
        return nil
    }
}

/// One status: its header (dot, name, count), and its cards in a list of their own.
@MainActor final class KanbanBoardColumnView: UIView, UICollectionViewDelegate, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    let status: String
    private weak var board: KanbanBoardView?
    private let panel = UIView()
    private let dot = UIView()
    private let name = UILabel()
    private let count = UILabel()
    private let lock = UIImageView()
    private let empty = UILabel()
    private var list: UICollectionView!
    private var data: UICollectionViewDiffableDataSource<Int, String>!
    private var ids: [String] = []
    private var dropping = false {
        didSet {
            guard dropping != oldValue else { return }
            // A tick as the column lights for a card held over it, as a list's drop target does (Sessions' projects).
            if dropping { Haptics.play(.selection) }
            paint()
        }
    }

    init(status: String, board: KanbanBoardView) {
        self.status = status
        self.board = board
        super.init(frame: .zero)
        accessibilityIdentifier = "kanban.column.\(status)"
        panel.layer.cornerCurve = .continuous
        addSubview(panel)

        dot.layer.cornerRadius = 4
        dot.backgroundColor = UIColor(KanbanTone.color(status))
        name.text = KanbanModel.label(status)
        name.font = MacType.sectionHeader
        name.textColor = HQPalette.label
        name.adjustsFontForContentSizeCategory = true
        name.accessibilityTraits = .header
        count.font = HQFont.preferred(.subheadline)
        count.textColor = HQPalette.label2
        count.adjustsFontForContentSizeCategory = true
        lock.image = UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2))
        lock.tintColor = HQPalette.label3
        lock.isHidden = !KanbanModel.isLocked(status)
        lock.accessibilityLabel = KanbanModel.lockedReason(status)
        lock.isAccessibilityElement = !lock.isHidden
        let header = UIStackView(arrangedSubviews: [dot, name, lock, UIView(), count])
        header.spacing = 7
        header.alignment = .center
        header.setCustomSpacing(5, after: name)
        header.translatesAutoresizingMaskIntoConstraints = false
        if KanbanModel.isLocked(status) {
            header.addInteraction(UIToolTipInteraction(defaultToolTip: KanbanModel.lockedReason(status)))
        }
        addSubview(header)

        let layout = UICollectionViewCompositionalLayout { _, _ in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(64))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 8
            section.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 8, bottom: 10, trailing: 8)
            return section
        }
        list = UICollectionView(frame: .zero, collectionViewLayout: layout)
        list.backgroundColor = .clear
        list.delegate = self
        list.dragDelegate = self
        list.dropDelegate = self
        list.dragInteractionEnabled = true
        list.alwaysBounceVertical = false
        list.contentInsetAdjustmentBehavior = .never
        list.translatesAutoresizingMaskIntoConstraints = false
        list.accessibilityIdentifier = "kanban.column.\(status).cards"
        addSubview(list)

        empty.text = "No tasks"
        empty.font = HQFont.preferred(.footnote)
        empty.textColor = HQPalette.label3
        empty.adjustsFontForContentSizeCategory = true
        empty.textAlignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            list.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 22),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        let cell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self, let row = self.board?.row(id) else { return }
            let chosen = self.board?.selected == id
            cell.contentConfiguration = UIHostingConfiguration { KanbanCardView(row: row, selected: chosen) }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
            cell.accessibilityIdentifier = "kanban-task-\(id)"
        }
        data = UICollectionViewDiffableDataSource<Int, String>(collectionView: list) { list, path, id in
            list.dequeueConfiguredReusableCell(using: cell, for: path, item: id)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: KanbanBoardColumnView, _) in view.paint() }
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A shade off the page: the cards stand on it, a step lighter again in dark and white in light.
    private static let panelFill = UIColor { @Sendable traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.045) : UIColor(white: 0, alpha: 0.04)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        panel.frame = bounds
    }

    /// The column's own panel: a shade lighter than the page with rounded corners; in the Desktop Look an outlined box
    /// with that look's square corners. A drop about to land draws the tint edge.
    private func paint() {
        let desktop = Theme.isDesktop
        panel.layer.cornerRadius = desktop ? 3 : 12
        panel.backgroundColor = desktop ? .clear : Self.panelFill
        panel.layer.borderWidth = dropping ? 2 : desktop ? 1 : 0
        panel.layer.borderColor = (dropping ? HQPalette.tint : UIColor(Color.hqStroke)).resolvedColor(with: traitCollection).cgColor
    }

    func apply(_ next: [String], changed: Set<String>, animated: Bool) {
        ids = next
        count.text = "\(next.count)"
        empty.isHidden = !next.isEmpty
        accessibilityLabel = "\(KanbanModel.label(status)), \(next.count) \(next.count == 1 ? "task" : "tasks")"
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(next)
        snapshot.reconfigureItems(next.filter(changed.contains))
        data.apply(snapshot, animatingDifferences: animated && window != nil && !HQMotion.reduced)
    }

    func reconfigure(_ some: [String]) {
        var snapshot = data.snapshot()
        let mine = some.filter { snapshot.indexOfItem($0) != nil }
        guard !mine.isEmpty else { return }
        snapshot.reconfigureItems(mine)
        data.apply(snapshot, animatingDifferences: false)
    }

    func cell(_ id: String) -> UIView? {
        data.indexPath(for: id).flatMap { list.cellForItem(at: $0) }
    }

    // MARK: Clicks and menus

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        if let id = data.itemIdentifier(for: indexPath) { board?.onOpen(id) }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first, let id = data.itemIdentifier(for: path) else { return nil }
        let cell = collectionView.cellForItem(at: path)
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            self?.board?.menu(id, cell)
        }
    }

    // MARK: Drag a card to another column

    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard let id = data.itemIdentifier(for: indexPath) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: (board?.row(id)?.title ?? id) as NSString))
        item.localObject = KanbanCardDrag(id: id)
        return [item]
    }

    func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
        guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds, cornerRadius: Theme.isDesktop ? 3 : KanbanCardView.radius)
        return parameters
    }

    /// The task a drag carries, when this column may take it: another status's card, and a status a person may set.
    private func taken(_ session: UIDropSession) -> String? {
        guard !KanbanModel.isLocked(status), status != "archived",
              let id = (session.localDragSession?.items.first?.localObject as? KanbanCardDrag)?.id,
              let from = board?.statusOf(id), from != status else { return nil }
        return id
    }

    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        session.localDragSession?.items.first?.localObject is KanbanCardDrag
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        let allowed = taken(session) != nil
        dropping = allowed
        return UICollectionViewDropProposal(operation: allowed ? .move : .forbidden, intent: .unspecified)
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidExit session: UIDropSession) { dropping = false }
    func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: UIDropSession) { dropping = false }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        dropping = false
        guard let id = taken(coordinator.session) else { return }
        board?.onMove(id, status)
    }
}

/// What a card's drag carries inside the app.
private final class KanbanCardDrag {
    let id: String
    init(id: String) { self.id = id }
}

/// A task's card: the title, then the assignee's head and the meta line under it.
struct KanbanCardView: View {
    var row: KanbanRowModel
    var selected: Bool
    static let radius: CGFloat = 9

    var body: some View {
        let _ = Theme.touch()
        let desktop = Theme.isDesktop
        let shape = RoundedRectangle(cornerRadius: desktop ? 3 : Self.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Text(row.title.isEmpty ? row.id : row.title)
                .font(Font.hq(.subheadline).weight(.medium))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top, spacing: 6) {
                face
                meta.padding(.top, 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(shape.fill(desktop ? Color.hqFill3 : Color(uiColor: HQPalette.card)))
        .overlay(shape.strokeBorder(selected ? Color.hqTint : Color(uiColor: desktop ? UIColor(Color.hqStroke) : HQPalette.cardEdge),
                                    lineWidth: selected ? 2 : 1))
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title). \(row.bits.map(\.text).joined(separator: ", "))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var face: some View {
        if let who = row.assignee {
            HeadImage(raw: row.head, profile: who, size: 18)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.hqLabel3, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: 18, height: 18)
        }
    }

    /// One run of text that wraps as text does (the list's flow of bits left a dot hanging at a line's end in a
    /// column this narrow).
    private var meta: some View {
        var line = Text("")
        for (index, bit) in row.bits.enumerated() {
            line = line + Text(bit.text).fontWeight(bit.alert ? .semibold : .regular).foregroundColor(bit.alert ? Color.hqRed : Color.hqLabel2)
            if index < row.bits.count - 1 { line = line + Text(" · ").foregroundColor(Color.hqLabel2) }
        }
        return line
            .font(Font.hq(.footnote))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
