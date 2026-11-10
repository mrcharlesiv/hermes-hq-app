// A row's More swipe opens the row's own hold menu as a pull-down from the row's trailing end, where More was (owner
// 2026-10-30, Sessions: "this looks like shit"). An action sheet given a source view is drawn by iOS 26 as a popover of
// big glass capsules with the row's title wrapped over it; the sheet stays only for a row that isn't on screen. Sessions
// (and its Other Apps page), Bots, the Bots list's rooms and Kanban share this, so every list's More opens alike.

import UIKit

@MainActor enum RowMoreMenu {
    /// Opens `menu` from the trailing end of `row` (a cell on screen). False when the row isn't in a window: the caller
    /// shows its sheet instead.
    @discardableResult
    static func open(_ menu: UIMenu, from row: UIView?) -> Bool {
        guard let row, row.window != nil, let container = row.superview else { return false }
        // One anchor at a time: a second More before the first menu closed takes over.
        container.subviews.compactMap { $0 as? AnchorButton }.forEach { $0.removeFromSuperview() }
        let anchor = AnchorButton(row: row)
        // The width of a swipe button at the row's end, the row's full height: the menu hangs under (or over) the row,
        // its trailing edge lined up with the row's content, and covers no other row.
        let width: CGFloat = 44
        let inset: CGFloat = 16
        let frame = row.frame
        let x = row.effectiveUserInterfaceLayoutDirection == .rightToLeft ? frame.minX + inset : frame.maxX - inset - width
        anchor.frame = CGRect(x: x, y: frame.minY, width: width, height: frame.height)
        anchor.menu = menu
        container.addSubview(anchor)
        anchor.performPrimaryAction()
        // A menu that never showed (a row scrolled away in the same turn) leaves no button behind over the row.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak anchor] in
            if let anchor, !anchor.shown { anchor.removeFromSuperview() }
        }
        return true
    }

    /// Runs `open` once the swiped row has slid back (at once under Reduce Motion): a menu over a row still sliding
    /// lands beside where it ends up.
    static func afterSwipe(_ open: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (HQMotion.reduced ? 0 : 0.35)) { open() }
    }

    /// An empty, invisible button that only holds the menu while it's open; the row stays pressed meanwhile, so the
    /// menu reads as that row's.
    private final class AnchorButton: UIButton {
        private weak var row: UIView?
        fileprivate var shown = false

        init(row: UIView) {
            self.row = row
            super.init(frame: .zero)
            showsMenuAsPrimaryAction = true
            isAccessibilityElement = false
            accessibilityIdentifier = "row-more-anchor"
        }

        @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                             animator: (any UIContextMenuInteractionAnimating)?) {
            super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
            shown = true
            (row as? UICollectionViewCell)?.isHighlighted = true
        }

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
                                             animator: (any UIContextMenuInteractionAnimating)?) {
            super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
            let done: () -> Void = { [weak self] in
                (self?.row as? UICollectionViewCell)?.isHighlighted = false
                self?.removeFromSuperview()
            }
            if let animator { animator.addCompletion(done) } else { done() }
        }
    }
}
