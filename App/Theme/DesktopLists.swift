// desktoplook2: grouped lists in the Desktop Look (phone-ui-desktop.css:139-155): a group of rows is a flat 4 pt
// outlined box on the page, not a filled iOS card. One mechanism for the app's own UIKit lists and SwiftUI's List /
// Form (whose sections cannot be reshaped from outside): the rows draw no card (clear background, the press as the
// desktop's inset box) and one stroke per section is laid over the list, following its items' frames as it scrolls.
// Public API only (layout attributes, cell background configurations, KVO on the scroll view). Nothing here is
// attached with the look off, and turning the look off takes it away again.

import ObjectiveC
import SwiftUI
import UIKit

@MainActor final class DesktopListOutliner: NSObject {
    private weak var list: UICollectionView?
    private let stroke = CAShapeLayer()
    private var watches: [NSKeyValueObservation] = []
    private var scheduled = false
    /// SwiftUI's cells: their rows are drawn by SwiftUI, only their background is ours to clear.
    private let foreign: Bool
    /// Which sections are boxed (a page mixing a chip strip with grouped rows boxes only the rows).
    var boxes: (Int) -> Bool = { _ in true }
    private static let key = malloc(1)!

    private init(list: UICollectionView) {
        self.list = list
        // A UIKit diffable data source lives in UIKit's bundle too, so a list the app drives through its delegate is ours.
        foreign = Bundle(for: type(of: list)) != .main && !(list.dataSource.map { Bundle(for: type(of: $0)) == .main } ?? false)
            && !(list.delegate.map { Bundle(for: type(of: $0)) == .main } ?? false)
        super.init()
        stroke.name = "hq.desktop.outline"
        stroke.fillColor = nil
        stroke.lineWidth = 1
        stroke.zPosition = 50
        stroke.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        list.layer.addSublayer(stroke)
        watches = [
            list.observe(\.contentSize, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
            list.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.update() } },
            list.observe(\.bounds, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
        ]
        update()
    }

    /// Attaches (once) to a list while the look is on.
    @discardableResult static func attach(to list: UICollectionView) -> DesktopListOutliner? {
        guard Theme.isDesktop else { return nil }
        if let existing = objc_getAssociatedObject(list, key) as? DesktopListOutliner { existing.schedule(); return existing }
        let outliner = DesktopListOutliner(list: list)
        objc_setAssociatedObject(list, key, outliner, .OBJC_ASSOCIATION_RETAIN)
        return outliner
    }

    /// Every list in the window after a theme change: lists whose outliner is attached redraw or go away.
    static func refreshAll(in root: UIView) {
        if let list = root as? UICollectionView, let outliner = objc_getAssociatedObject(list, key) as? DesktopListOutliner {
            outliner.update()
        }
        if let table = root as? UITableView { DesktopTableOutliner.refresh(table) }
        for child in root.subviews { refreshAll(in: child) }
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.update()
            }
        }
    }

    private func detach() {
        guard let list else { return }
        stroke.removeFromSuperlayer()
        watches.removeAll()
        if foreign { for cell in list.visibleCells { cell.setNeedsUpdateConfiguration() } }
        objc_setAssociatedObject(list, Self.key, nil, .OBJC_ASSOCIATION_RETAIN)
    }

    func update() {
        guard let list else { return }
        guard Theme.isDesktop else { detach(); return }
        // First, so a row SwiftUI drew clear is known bare before the boxes are drawn (after, its first pass boxed it).
        if foreign { clearCards(in: list) }
        let visible = list.bounds.insetBy(dx: 0, dy: -400)
        let path = UIBezierPath()
        let layout = list.collectionViewLayout
        for section in 0..<list.numberOfSections {
            let count = list.numberOfItems(inSection: section)
            guard count > 0, boxes(section),
                  let first = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: section)),
                  let last = layout.layoutAttributesForItem(at: IndexPath(item: count - 1, section: section)) else { continue }
            var box = first.frame.union(last.frame)
            guard box.intersects(visible), box.height > 1 else { continue }
            if Self.isBare(section: section, in: list, count: count) { continue }
            box = box.insetBy(dx: 0.5, dy: 0.5)
            path.append(UIBezierPath(roundedRect: box, cornerRadius: DesktopRows.radius))
        }
        stroke.frame = CGRect(origin: .zero, size: list.contentSize)
        stroke.path = path.cgPath
        stroke.strokeColor = ChatPalette.strokeSecondary.resolvedColor(with: list.traitCollection).cgColor
    }

    /// A section whose rows all draw nothing behind them (a grid, a button standing alone, a page's title over its
    /// action tiles) gets no box. 2026-10-30: only a one-row section was looked at, so a job page's title and Run Now /
    /// Pause tiles (two clear rows) were boxed together, the tiles pressed against the box's sides.
    private static func isBare(section: Int, in list: UICollectionView, count: Int) -> Bool {
        guard count <= 8 else { return false }
        for item in 0..<count {
            guard let cell = list.cellForItem(at: IndexPath(item: item, section: section)) as? UICollectionViewListCell,
                  cell.hqBareRow else { return false }
        }
        return true
    }

    /// SwiftUI's rows keep its grouped card colour: in the look the card is the page (flat), and a press is the
    /// desktop's inset box.
    private func clearCards(in list: UICollectionView) {
        for cell in list.visibleCells {
            guard let cell = cell as? UICollectionViewListCell else { continue }
            #if targetEnvironment(macCatalyst)
            // [mac] Stress test 2026-10-28 round 8: the rows clip to the outline's 4 pt corners, not the system card's
            // large ones (which cut the ends off a segmented strip standing in a one-row section: Import Sessions, and
            // Command Center while it had tabs); a bare row isn't clipped.
            // Mac download 447 crash: this runs on every scroll, inside the list's layout pass; the write waits for it.
            MacSelection.fitCardCornersLater(cell, bare: cell.hqBareRow)
            #else
            // 2026-10-30 (job page): a bare row keeps the list's 26 pt card ends as a clip, which cut the first glyph of
            // a title on the first row and the outer corners of action tiles on the last. Bare rows aren't clipped.
            if cell.hqBareRow { Self.unclipLater(cell) }
            #endif
            var background = cell.backgroundConfiguration ?? UIBackgroundConfiguration.listCell()
            let pressed = cell.isHighlighted || cell.isSelected
            let wanted: UIColor = pressed ? HQPalette.cellPressed : .clear
            // A row SwiftUI drew clear on purpose (listRowBackground(Color.clear)) stays bare.
            if background.backgroundColor == .clear, background.customView == nil, !cell.hqDesktopCleared {
                cell.hqBareRow = true
            }
            if background.backgroundColor != wanted || background.cornerRadius != DesktopRows.radius {
                background.backgroundColor = wanted
                background.backgroundColorTransformer = nil
                background.cornerRadius = DesktopRows.radius
                background.backgroundInsets = pressed ? DesktopRows.pressInset : .zero
                background.visualEffect = nil
                cell.backgroundConfiguration = background
                cell.hqDesktopCleared = true
            }
        }
    }
}

#if !targetEnvironment(macCatalyst)
extension DesktopListOutliner {
    /// As the Mac's `MacSelection.fitCardCornersLater` (Mac download 447): written after the list's layout pass, only
    /// when it differs, and a cell the list keeps taking back is left with the list's corners.
    fileprivate static func unclipLater(_ cell: UICollectionViewListCell) {
        guard !cell.hqUnclipPending else { return }
        cell.hqUnclipPending = true
        DispatchQueue.main.async { [weak cell] in
            MainActor.assumeIsolated {
                guard let cell else { return }
                cell.hqUnclipPending = false
                guard Theme.isDesktop, cell.window != nil, cell.hqBareRow else { return }
                let corners: [UIRectCorner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
                guard corners.contains(where: { cell.effectiveRadius(corner: $0) > 0.01 }) else { return }
                let now = CACurrentMediaTime()
                var budget = cell.hqUnclipBudget
                if now - budget.since > 2 { budget = (now, 0) }
                budget.count += 1
                cell.hqUnclipBudget = budget
                guard budget.count <= 8 else { return }
                cell.cornerConfiguration = .corners(radius: .fixed(0))
            }
        }
    }
}

private let unclipPendingKey = malloc(1)!
private let unclipBudgetKey = malloc(1)!
extension UICollectionViewListCell {
    fileprivate var hqUnclipPending: Bool {
        get { (objc_getAssociatedObject(self, unclipPendingKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, unclipPendingKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
    fileprivate var hqUnclipBudget: (since: CFTimeInterval, count: Int) {
        get { (objc_getAssociatedObject(self, unclipBudgetKey) as? [Double]).map { ($0[0], Int($0[1])) } ?? (0, 0) }
        set { objc_setAssociatedObject(self, unclipBudgetKey, [newValue.since, Double(newValue.count)], .OBJC_ASSOCIATION_RETAIN) }
    }
}
#endif

private let clearedKey = malloc(1)!
private let bareKey = malloc(1)!
extension UICollectionViewListCell {
    fileprivate var hqDesktopCleared: Bool {
        get { (objc_getAssociatedObject(self, clearedKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, clearedKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
    /// Set by `.hqDesktopBareRow()` (or found by the outliner): the section draws no box.
    var hqBareRow: Bool {
        get { (objc_getAssociatedObject(self, bareKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, bareKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}

/// Put behind a SwiftUI List / Form in the look (GroupedPageModifier): finds the list it sits beside and attaches
/// the outliner.
struct DesktopListProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ view: ProbeView, context: Context) { view.find() }

    final class ProbeView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            find()
        }

        func find() {
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.window != nil else { return }
                    var ancestor = self.superview
                    for _ in 0..<6 {
                        guard let current = ancestor else { return }
                        if let list = Self.firstList(in: current, depth: 6) {
                            DesktopListOutliner.attach(to: list)
                            return
                        }
                        ancestor = current.superview
                    }
                }
            }
        }

        private static func firstList(in view: UIView, depth: Int) -> UICollectionView? {
            if let list = view as? UICollectionView { return list }
            guard depth > 0 else { return nil }
            for child in view.subviews { if let found = firstList(in: child, depth: depth - 1) { return found } }
            return nil
        }
    }
}

/// `.hqDesktopBareRow()`: marks the list cell it sits in as bare.
struct DesktopBareRowMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> Marker { Marker() }
    func updateUIView(_ view: Marker, context: Context) { view.mark() }

    final class Marker: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            mark()
        }

        func mark() {
            var view = superview
            while let current = view {
                if let cell = current as? UICollectionViewListCell {
                    guard !cell.hqBareRow else { return }
                    cell.hqBareRow = true
                    // The list's outline may already be drawn round this row: draw it again without.
                    var up = cell.superview
                    while let next = up, !(next is UICollectionView) { up = next.superview }
                    if let list = up as? UICollectionView { DesktopListOutliner.attach(to: list) }
                    return
                }
                view = current.superview
            }
        }
    }
}

/// Stress test 2026-10-28 #56: the same outlined groups for the app's grouped UITableViews (Chat Info, the Files and
/// Changes sheet, More › Files and Changes), which kept iOS's grey 20 pt cards beside the look's outlined boxes. The
/// rows draw no card (the desktop's inset box when pressed) and one 1 pt stroke goes round each section's rows. Attach
/// from the page's `viewDidLayoutSubviews` (it also catches rows drawn after a reload); with the look off nothing is
/// attached, and the look going off puts every row's own background back.
@MainActor final class DesktopTableOutliner: NSObject {
    private weak var table: UITableView?
    private let stroke = CAShapeLayer()
    private var watches: [NSKeyValueObservation] = []
    private var scheduled = false
    private static let key = malloc(1)!
    private static let cellKey = malloc(1)!

    private init(table: UITableView) {
        self.table = table
        super.init()
        stroke.name = "hq.desktop.outline"
        stroke.fillColor = nil
        stroke.lineWidth = 1
        stroke.zPosition = 50
        stroke.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        table.layer.addSublayer(stroke)
        // Mac polish 2026-11-06 #127: every change the table reports redraws a moment later, never at once. The table
        // moves its offset while it is laying out its rows (a reload, a height settling), and reading its rows then is
        // refused (UIKit's "visibleCells while they were in the process of being updated", 90 times in a tour). The
        // stroke is in the table's content, so it scrolls with the rows meanwhile, and boxes are drawn 400 pt past what
        // shows, so one drawn a moment late is never seen.
        watches = [
            table.observe(\.contentSize, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
            table.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
            table.observe(\.bounds, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
        ]
    }

    /// Attaches (once) while the look is on; again later only redraws.
    /// [mac] Stress test 2026-10-28 #9: `bare` names the sections that stand on the page with no box (an empty or error
    /// state, which read as a card near the top in the look while the iOS look drew none).
    static func attach(to table: UITableView, bare: ((Int) -> Bool)? = nil) {
        #if targetEnvironment(macCatalyst)
        MacTableRounder.attach(to: table)   // [mac-ui-issues] the iOS look's cards as Mac group boxes
        #endif
        if let existing = objc_getAssociatedObject(table, key) as? DesktopTableOutliner {
            if let bare { existing.bareSection = bare }
            // #127 (review): the page's layout pass comes after the table's, which made the rows a scroll brought in, so
            // reading them here is allowed and they lose iOS's grey card before they are drawn (a moment later, they
            // showed it for a frame). Only a table with updates still pending waits for the moment after.
            if table.hasUncommittedUpdates { existing.schedule() } else { existing.update() }
            return
        }
        guard Theme.isDesktop else { return }
        let outliner = DesktopTableOutliner(table: table)
        outliner.bareSection = bare ?? { _ in false }
        objc_setAssociatedObject(table, key, outliner, .OBJC_ASSOCIATION_RETAIN)
        // The first drawing at once (pages attach from `viewDidLayoutSubviews`, once the table has laid out its rows), so
        // the rows never show iOS's grey cards for a frame. #127: only here, once the bare sections are known (`init` drew
        // too, before them).
        outliner.update()
    }

    /// Sections drawn with no box and no row card.
    private var bareSection: (Int) -> Bool = { _ in false }

    /// After a theme change (`DesktopListOutliner.refreshAll`): an attached table redraws, or lets go.
    static func refresh(_ table: UITableView) {
        (objc_getAssociatedObject(table, key) as? DesktopTableOutliner)?.update()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.update()
            }
        }
    }

    func update() {
        guard let table else { return }
        let desktop = Theme.isDesktop
        for cell in table.visibleCells {
            // A bare section's row keeps the clear background its page gave it (#9).
            if desktop, let path = table.indexPath(for: cell), bareSection(path.section) { continue }
            Self.bare(cell, desktop: desktop)
        }
        guard desktop else {
            stroke.removeFromSuperlayer()
            watches.removeAll()
            objc_setAssociatedObject(table, Self.key, nil, .OBJC_ASSOCIATION_RETAIN)
            return
        }
        let visible = table.bounds.insetBy(dx: 0, dy: -400)
        let path = UIBezierPath()
        for section in 0..<table.numberOfSections {
            let count = table.numberOfRows(inSection: section)
            guard count > 0, !bareSection(section) else { continue }
            let box = table.rectForRow(at: IndexPath(row: 0, section: section))
                .union(table.rectForRow(at: IndexPath(row: count - 1, section: section)))
            guard box.intersects(visible), box.height > 1 else { continue }
            path.append(UIBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerRadius: DesktopRows.radius))
        }
        stroke.frame = CGRect(origin: .zero, size: table.contentSize)
        stroke.path = path.cgPath
        stroke.strokeColor = ChatPalette.strokeSecondary.resolvedColor(with: table.traitCollection).cgColor
    }

    /// A row's card: none in the look (the inset box when pressed), its own background again with the look off.
    private static func bare(_ cell: UITableViewCell, desktop: Bool) {
        let marked = objc_getAssociatedObject(cell, cellKey) != nil
        if desktop, !marked {
            let own = cell.backgroundConfiguration
            objc_setAssociatedObject(cell, cellKey, true, .OBJC_ASSOCIATION_RETAIN)
            cell.configurationUpdateHandler = { cell, state in
                if Theme.isDesktop {
                    cell.backgroundConfiguration = DesktopLayout.rowBackground(state)
                } else {
                    cell.backgroundConfiguration = own?.updated(for: state)
                }
            }
        }
        if marked || desktop { cell.setNeedsUpdateConfiguration() }
    }
}
