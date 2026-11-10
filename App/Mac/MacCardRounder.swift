// [mac-ui-issues] Owner 2026-11-09 ("are the settings designed properly for a Mac app, or too iOS-like?" … "do the
// pass, get it right"): in the iOS look every grouped card on the Mac kept iOS 26's 26 pt card ends, so a one-row card
// (most of Settings) was a capsule: an iPhone's row, not a Mac's group box. On the Mac a grouped card now has a group
// box's corners (`radius`), in Settings and on every other grouped page, so the app is one shape.
//
// How: the list clips each card's end rows through the cell's `cornerConfiguration` (iOS 26), which neither SwiftUI
// nor the list's layout lets a page choose. So, as the Desktop Look does for its 4 pt outline, the visible cells are
// given their corners after the list has laid them out: `MacSelection.fitCardCornersLater`, which never writes from
// inside the list's layout pass and gives up on a cell the list keeps taking back (Mac download 447). Public API only.
// The Desktop Look keeps its own outline: nothing here writes while it is on.

#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

@MainActor final class MacCardRounder: NSObject {
    /// App points: about 10 on the screen, a macOS group box's.
    static let radius: CGFloat = 13

    private weak var list: UICollectionView?
    private var watches: [NSKeyValueObservation] = []
    private var scheduled = false
    private static let key = malloc(1)!

    /// Once per list. Harmless in the Desktop Look (it writes nothing there) and after a change of look.
    static func attach(to list: UICollectionView) {
        if let existing = objc_getAssociatedObject(list, key) as? MacCardRounder { existing.schedule(); return }
        let rounder = MacCardRounder(list: list)
        objc_setAssociatedObject(list, key, rounder, .OBJC_ASSOCIATION_RETAIN)
    }

    private init(list: UICollectionView) {
        self.list = list
        super.init()
        watches = [
            list.observe(\.contentSize, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
            list.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
            list.observe(\.bounds, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
        ]
        schedule()
    }

    /// One pass per turn of the run loop, after the list's own layout.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduled = false
                self.fit()
            }
        }
    }

    private func fit() {
        guard !Theme.isDesktop, let list, list.window != nil else { return }
        for cell in list.visibleCells where cell is UICollectionViewListCell {
            MacSelection.fitCardCornersLater(cell, at: list.indexPath(for: cell), iosLook: true)
        }
    }
}

/// The same for the app's inset-grouped UITableViews (Files, Changes, Chat Info, Keyboard Shortcuts), attached where
/// the Desktop Look's outline is (`DesktopTableOutliner.attach`).
@MainActor final class MacTableRounder: NSObject {
    private weak var table: UITableView?
    private var watches: [NSKeyValueObservation] = []
    private var scheduled = false
    private static let key = malloc(1)!
    private static let countKey = malloc(1)!

    static func attach(to table: UITableView) {
        guard table.style == .insetGrouped else { return }
        if let existing = objc_getAssociatedObject(table, key) as? MacTableRounder { existing.schedule(); return }
        let rounder = MacTableRounder(table: table)
        objc_setAssociatedObject(table, key, rounder, .OBJC_ASSOCIATION_RETAIN)
    }

    private init(table: UITableView) {
        self.table = table
        super.init()
        watches = [
            table.observe(\.contentSize, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
            table.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
            table.observe(\.bounds, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
        ]
        schedule()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduled = false
                self.fit()
            }
        }
    }

    /// After the table's layout, only where a corner differs, and at most 8 writes a cell in 2 s: a cell the table
    /// keeps taking back is left as the table has it (as `MacSelection.fitCardCornersLater`, Mac download 447).
    private func fit() {
        guard !Theme.isDesktop, let table, table.window != nil else { return }
        for cell in table.visibleCells {
            guard let path = table.indexPath(for: cell) else { continue }
            let top = path.row == 0, foot = path.row == table.numberOfRows(inSection: path.section) - 1
            let wanted: [(UIRectCorner, CGFloat)] = [(.topLeft, top ? MacCardRounder.radius : 0), (.topRight, top ? MacCardRounder.radius : 0),
                                                     (.bottomLeft, foot ? MacCardRounder.radius : 0), (.bottomRight, foot ? MacCardRounder.radius : 0)]
            guard wanted.contains(where: { abs(cell.effectiveRadius(corner: $0.0) - $0.1) > 0.01 }) else { continue }
            let now = CACurrentMediaTime()
            var budget = (objc_getAssociatedObject(cell, Self.countKey) as? [Double]) ?? [now, 0]
            if now - budget[0] > 2 { budget = [now, 0] }
            budget[1] += 1
            objc_setAssociatedObject(cell, Self.countKey, budget, .OBJC_ASSOCIATION_RETAIN)
            guard budget[1] <= 8 else { continue }
            cell.cornerConfiguration = .corners(topLeftRadius: .fixed(wanted[0].1), topRightRadius: .fixed(wanted[1].1),
                                                bottomLeftRadius: .fixed(wanted[2].1), bottomRightRadius: .fixed(wanted[3].1))
        }
    }
}

/// Behind a SwiftUI grouped List / Form (`GroupedPageModifier`): finds the list it sits beside and rounds its cards.
struct MacCardProbe: UIViewRepresentable {
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
                            MacCardRounder.attach(to: list)
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
#endif

import SwiftUI

extension View {
    /// [mac-ui-issues] A grouped list's cards with the Mac's group-box corners (`MacCardRounder`); nothing off the Mac.
    @ViewBuilder func hqMacCardCorners() -> some View {
        #if targetEnvironment(macCatalyst)
        background(MacCardProbe())
        #else
        self
        #endif
    }
}
