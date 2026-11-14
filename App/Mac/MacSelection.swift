// [mac] Stress test 2026-10-28 #54: one source-list selection on the Mac. The sidebar drew a rounded inset grey pill,
// More a square band inside its card (the card's border round it), Bots and Sessions an inset box (Desktop Look) or
// an edge-to-edge band (iOS look), and none was ever the accent; the Desktop Look's navy on near-black barely showed.
// Now every list row the window's lists mark (sidebar, Bots, Sessions, Jobs, Artifacts, Kanban, More) is the same
// rounded box inset in its row: the accent while its pane has the focus (the last click landed there), grey otherwise,
// as a Mac's source lists are. A press alone is grey.

import UIKit

#if targetEnvironment(macCatalyst)
@MainActor enum MacSelection {
    enum Pane { case sidebar, list, detail }

    /// Where the last click landed. [mac] Stress test 2026-10-28 #54 (round 2): the sidebar starts with it (the window
    /// opens with the sidebar's tab as its one mark, which drew grey until something was clicked), and a tab chosen by
    /// ⌘1… gives it back (`focus(on:)`).
    private(set) static var focus: Pane = .sidebar

    /// A pane takes the focus without a click (a tab chosen from the keyboard or the sidebar's own action).
    static func focus(on pane: Pane) {
        guard pane != focus, let split = KeyCommands.root?.split, split.isViewLoaded else { focus = pane; return }
        focus = pane
        split.macSidebar.focusChanged()
        refresh(split.tabs.view)
    }

    /// The box's room inside its row and its corners: the Desktop Look's 4 pt radius is its brand, the iOS look's
    /// rounder one matches its cards.
    static var insets: NSDirectionalEdgeInsets { DesktopRows.pressInset }
    static var radius: CGFloat { Theme.isDesktop ? DesktopRows.radius : 8 }

    /// [sidebar-intent] Whether the window is the one in front. Behind another window (or another app) its one accent
    /// mark stayed as bright as in front, the loudest thing on a screen it no longer had; a Mac's source lists go
    /// grey there. The sidebar hears the change (`MacSidebar`, the window's active-appearance trait) and says so here.
    private(set) static var windowActive = true

    static func windowActive(_ active: Bool) {
        guard active != windowActive else { return }
        windowActive = active
        guard let split = KeyCommands.root?.split, split.isViewLoaded else { return }
        split.macSidebar.focusChanged()
        refresh(split.tabs.view)
    }

    /// The pane whose mark is the accent: the one the last click landed in, while the window is in front.
    static func emphasized(_ pane: Pane) -> Bool { windowActive && focus == pane }

    /// The fill for a row: nil at rest.
    static func fill(selected: Bool, pressed: Bool, in pane: Pane) -> UIColor? {
        if selected { return emphasized(pane) ? accent : grey }
        return pressed ? grey : nil
    }

    /// The accent, soft enough that the row's own label and grey text still read on it (the rows draw their own
    /// colours; a Mac's white-on-accent would need every row redrawn).
    static let accent = UIColor { traits in
        // [message-colour] The message colour where one is picked (owner 2026-11-11), else the tint.
        HQPalette.chosenRow.resolvedColor(with: traits).withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.42 : 0.24)
    }
    /// The unfocused mark and a press: the sidebar's grey.
    static let grey = UIColor { traits in
        UIColor.label.resolvedColor(with: traits).withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.14 : 0.09)
    }

    /// [mac] Stress test 2026-10-28 round 7: the unfocused mark on a grouped card in the iOS look, opaque: the Mac's own
    /// unemphasized selection (220 grey in light, 70 in dark). The see-through grey over the white card came to
    /// (232,233,233) on the (236,236,236) page, so the selected row hardly showed and looked as if it had lost its card.
    static let unemphasized = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 70 / 255, alpha: 1) : UIColor(white: 220 / 255, alpha: 1)
    }

    /// A plain list's row (Bots, Sessions, Jobs, Artifacts, Kanban; More in the Desktop Look).
    static func listRow(_ state: UICellConfigurationState) -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.clear()
        if let fill = fill(selected: state.isSelected, pressed: state.isHighlighted, in: .list) {
            background.backgroundColor = fill
            background.backgroundInsets = insets
            background.cornerRadius = radius
        }
        return background
    }

    /// A row in a grouped card (More, both looks). [mac] Stress test 2026-10-28 #54 (round 6): the mark fills the row to
    /// the card's own shape. A smaller-radius box inside the card left slivers of card round it in the iOS look (worst
    /// in the one-row Settings card, whose corners are nearly a capsule), and the Desktop Look's 4 pt inset left a dark
    /// strip inside the card's outline. The iOS look's card takes the mark's colour over its own, in the corners the
    /// system gives the row (round at a card's top and foot); the Desktop Look's outlined card gets a box the row's full
    /// size under its outline, rounded at the card's first and last rows.
    static func groupedRow(_ cell: UICollectionViewCell, _ state: UICellConfigurationState) -> UIBackgroundConfiguration {
        let fill = fill(selected: state.isSelected, pressed: state.isHighlighted, in: .list)
        if Theme.isDesktop {
            fitCardCornersLater(cell)   // a configuration update runs inside the list's layout pass (Mac download 447 crash)
            var background = UIBackgroundConfiguration.clear()
            guard let fill else { return background }
            let mark = MarkView()
            mark.box.backgroundColor = fill
            mark.box.layer.cornerRadius = DesktopRows.radius
            mark.box.layer.maskedCorners = cardCorners(of: cell)
            mark.inset = .zero
            background.customView = mark
            // [mac] Stress test 2026-10-28 round 7: the inset-grouped list clipped the mark to its own card radius (a
            // ~14 pt capsule on the one-row Settings card) inside the look's 4 pt outline, leaving slivers at every
            // corner. The background takes the outline's radius, so the list's clip and the mark's corners match it.
            background.cornerRadius = DesktopRows.radius
            return background
        }
        var background = cell.defaultBackgroundConfiguration()
        guard let fill else { return background }
        // [mac] Stress test 2026-10-28 round 7: selected without the focus, the card is the Mac's unemphasized grey.
        if state.isSelected, !emphasized(.list) {
            background.backgroundColor = unemphasized
            return background
        }
        // A coloured skin's card under the mark, as its rows take (SkinListCards).
        let card = SkinListCards.skinned(cell.traitCollection) ? HQPalette.card : background.resolvedBackgroundColor(for: cell.tintColor)
        background.backgroundColor = UIColor { traits in
            over(card.resolvedColor(with: traits), fill.resolvedColor(with: traits))
        }
        return background
    }

    /// `top` drawn over `bottom` (the mark's see-through fill over the card), as one opaque colour.
    private static func over(_ bottom: UIColor, _ top: UIColor) -> UIColor {
        var (br, bg, bb, ba): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (tr, tg, tb, ta): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        bottom.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        top.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        let alpha = ta + ba * (1 - ta)
        guard alpha > 0 else { return .clear }
        func mix(_ t: CGFloat, _ b: CGFloat) -> CGFloat { (t * ta + b * ba * (1 - ta)) / alpha }
        return UIColor(red: mix(tr, br), green: mix(tg, bg), blue: mix(tb, bb), alpha: alpha)
    }

    /// [mac] Stress test 2026-10-28 round 8: the Desktop Look's outlined card clips its rows to its own 4 pt corners.
    /// The inset-grouped list clips each card's end rows itself, through the cell's `cornerConfiguration` (iOS 26: the
    /// layer's own corner radius stays 0, so round 7's background radius changed nothing), at the system card's large
    /// radius: on the one-row Settings card a capsule, so a selected row's fill left dark wedges and slivers of the
    /// outline at its corners. The cell now takes the outline's corners: round at the card's first and last rows,
    /// square where it meets another row.
    /// A bare row (a segmented strip standing on the page, `hqDesktopBareRow`) is not clipped at all.
    /// [mac] Stress test 2026-10-28 round 9: `path` is the row's place when the caller has it (a cell taking its layout
    /// attributes isn't always in its list yet). With no place to read, nothing is written: the fallback (every corner
    /// round) put 4 pt corners on rows the list then gave its own 22 pt card ends.
    /// [mac] Mac download 447 crash (2026-10-29): written from inside the list's own layout pass (a cell taking its
    /// attributes, a scroll), each write re-ran the pass, the list put its corners back, and the passes nested until
    /// UIKit's assertion. The write now waits for the pass to end (one per cell per turn of the run loop), and a cell
    /// the list keeps taking back is left with the list's corners rather than fought over.
    static func fitCardCornersLater(_ cell: UICollectionViewCell, bare: Bool = false, at path: IndexPath? = nil, iosLook: Bool = false) {
        guard !cell.hqCornerFitPending else { return }
        cell.hqCornerFitPending = true
        DispatchQueue.main.async { [weak cell] in
            MainActor.assumeIsolated {
                guard let cell else { return }
                cell.hqCornerFitPending = false
                // [mac-ui-issues] `iosLook`: the iOS look's own Mac card corners (`MacCardRounder`), only while that look is on.
                guard Theme.isDesktop != iosLook, cell.window != nil else { return }
                let now = CACurrentMediaTime()
                var budget = cell.hqCornerFitBudget
                if now - budget.since > 2 { budget = (now, 0) }
                guard budget.count < 8 else {
                    if budget.count == 8 { AppLog.note("mac", "card corners: the list keeps taking a row's corners back; left as the list has them") }
                    budget.count += 1
                    cell.hqCornerFitBudget = budget
                    return
                }
                budget.count += 1
                cell.hqCornerFitBudget = budget
                fitCardCorners(cell, bare: bare, at: path, cardRadius: iosLook ? MacCardRounder.radius : DesktopRows.radius)
            }
        }
    }

    static func fitCardCorners(_ cell: UICollectionViewCell, bare: Bool = false, at path: IndexPath? = nil, cardRadius: CGFloat = DesktopRows.radius) {
        let corners: CACornerMask
        if bare { corners = [] } else if let found = cardCornersIfKnown(of: cell, at: path) { corners = found } else { return }
        func want(_ corner: CACornerMask) -> CGFloat { corners.contains(corner) ? cardRadius : 0 }
        let pairs: [(UIRectCorner, CACornerMask)] = [(.topLeft, .layerMinXMinYCorner), (.topRight, .layerMaxXMinYCorner),
                                                     (.bottomLeft, .layerMinXMaxYCorner), (.bottomRight, .layerMaxXMaxYCorner)]
        // Written only when it differs: the cell lays out again after each write.
        guard pairs.contains(where: { abs(cell.effectiveRadius(corner: $0.0) - want($0.1)) > 0.01 }) else { return }
        func radius(_ corner: CACornerMask) -> UICornerRadius { .fixed(want(corner)) }
        cell.cornerConfiguration = .corners(topLeftRadius: radius(.layerMinXMinYCorner), topRightRadius: radius(.layerMaxXMinYCorner),
                                            bottomLeftRadius: radius(.layerMinXMaxYCorner), bottomRightRadius: radius(.layerMaxXMaxYCorner))
    }

    /// The corners of the card a row has: round at the top of its section's first row and the foot of its last.
    private static func cardCorners(of cell: UICollectionViewCell) -> CACornerMask {
        cardCornersIfKnown(of: cell) ?? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }

    private static func cardCornersIfKnown(of cell: UICollectionViewCell, at known: IndexPath? = nil) -> CACornerMask? {
        guard let list = sequence(first: cell.superview, next: { $0?.superview }).lazy.compactMap({ $0 as? UICollectionView }).first,
              let path = known ?? list.indexPath(for: cell), path.section < list.numberOfSections else { return nil }
        var corners: CACornerMask = []
        if path.item == 0 { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if path.item == list.numberOfItems(inSection: path.section) - 1 { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        return corners
    }

    // MARK: Focus

    /// Watches where clicks land, without taking any: a recognizer that asks for every touch and refuses it.
    static func install(on window: UIWindow) {
        let watch = UITapGestureRecognizer()
        watch.delegate = FocusWatch.shared
        watch.cancelsTouchesInView = false
        window.addGestureRecognizer(watch)
    }

    fileprivate static func clicked(_ view: UIView) {
        guard let split = KeyCommands.root?.split, split.isViewLoaded else { return }
        let pane: Pane
        if view.isDescendant(of: split.macSidebar) {
            pane = .sidebar
        } else if view.isDescendant(of: split.tabs.view) {
            pane = .list
        } else if view.isDescendant(of: split.detail.view) {
            pane = .detail
        } else {
            return   // a sheet or a menu over the window: the panes keep their focus
        }
        guard pane != focus else { return }
        focus = pane
        split.macSidebar.focusChanged()
        refresh(split.tabs.view)
    }

    /// The lists' marked rows take the new colour.
    private static func refresh(_ view: UIView) {
        if let list = view as? UICollectionView {
            for cell in list.visibleCells { cell.setNeedsUpdateConfiguration() }
            return
        }
        for child in view.subviews where !child.isHidden { refresh(child) }
    }

    /// The grouped row's box, inset in the card.
    private final class MarkView: UIView {
        let box = UIView()
        /// The box's room inside the row (none for a card's row, #54 round 6).
        var inset = MacSelection.insets
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            box.layer.cornerRadius = MacSelection.radius
            box.layer.cornerCurve = .continuous
            addSubview(box)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func layoutSubviews() {
            super.layoutSubviews()
            box.frame = bounds.inset(by: UIEdgeInsets(top: inset.top, left: inset.leading, bottom: inset.bottom, right: inset.trailing))
        }
    }
}

/// [mac] Stress test 2026-10-28 round 8: More's row. The list writes its card corners onto the cell as it lays the
/// cell out, after any configuration handler, so the Desktop Look's 4 pt corners are put back each time it does.
final class MacCardCell: UICollectionViewListCell {
    override func layoutSubviews() {
        super.layoutSubviews()
        if Theme.isDesktop { MacSelection.fitCardCornersLater(self) }
    }

    /// [mac] Stress test 2026-10-28 round 9: the list writes a multi-row card's end corners (22 pt) as it applies the
    /// row's layout attributes, after the row's last layout, so a card's first or last row kept them (Bot Profiles,
    /// Messaging, Status & Maintenance, Import Sessions: a dark wedge between the 4 pt outline and the selection's corner).
    /// Each write is answered with the outline's corners, at the place the attributes give.
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if Theme.isDesktop { MacSelection.fitCardCornersLater(self, at: layoutAttributes.indexPath) }
    }
}

private extension UICollectionViewCell {
    private static let pendingKey = malloc(1)!
    private static let budgetKey = malloc(1)!

    var hqCornerFitPending: Bool {
        get { (objc_getAssociatedObject(self, Self.pendingKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, Self.pendingKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    /// Writes since `since` (two-second windows).
    var hqCornerFitBudget: (since: CFTimeInterval, count: Int) {
        get { (objc_getAssociatedObject(self, Self.budgetKey) as? [Double]).map { ($0[0], Int($0[1])) } ?? (0, 0) }
        set { objc_setAssociatedObject(self, Self.budgetKey, [newValue.since, Double(newValue.count)], .OBJC_ASSOCIATION_RETAIN) }
    }
}

@MainActor private final class FocusWatch: NSObject, UIGestureRecognizerDelegate {
    static let shared = FocusWatch()
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let view = touch.view { MacSelection.clicked(view) }
        return false
    }
}
#endif
