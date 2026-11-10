// [m9/ipad] Pointer (trackpad / mouse) effects, system behaviours only (docs/spec/3x-ipad.md §4.9): list rows show
// the system hover, round buttons the system highlight. Nothing appears only on hover.
//
// [mac] The Mac draws no pointer effect (Catalyst honours a pointer interaction's cursor shape only), so moving the
// mouse over a row changed nothing. There the row under the pointer gets a faint fill of its own (`MacHover`: in at
// once, out in 60 ms, as the Desktop Look's hover), and a small round control a faint one of its shape behind it. Installed once per screen as
// it shows (`PushedPageTitles.didShow`, the right pane's stack included), so no list or cell has to opt in.

import UIKit

@MainActor enum PointerEffects {
    /// Rows of the screen's lists and its small round controls answer the pointer from now on.
    static func install(in screen: UIViewController) {
        guard UIDevice.current.userInterfaceIdiom == .pad, let view = screen.viewIfLoaded else { return }
        walk(view, depth: 6)
    }

    private static func walk(_ view: UIView, depth: Int) {
        if let list = view as? UICollectionView {
            rows(list)
            return
        }
        if let table = view as? UITableView, !(table.transform.d < 0) {   // not the chat's inverted transcript
            rows(table)
            return
        }
        if let control = view as? UIControl { button(control) }
        guard depth > 0 else { return }
        for child in view.subviews { walk(child, depth: depth - 1) }
    }

    /// One interaction on the list: the row under the pointer gets the system's hover effect.
    static func rows(_ list: UIScrollView) {
        guard !list.interactions.contains(where: { ($0 as? UIPointerInteraction)?.delegate is RowPointer }) else { return }
        list.addInteraction(UIPointerInteraction(delegate: RowPointer.shared))
        #if targetEnvironment(macCatalyst)
        MacHover.rows(list)
        #endif
    }

    /// A small round control (composer buttons, the jump button, a Find arrow): the system's highlight.
    static func button(_ control: UIControl) {
        if let button = control as? UIButton, button.configuration != nil {
            button.isPointerInteractionEnabled = true
            #if targetEnvironment(macCatalyst)
            if button.bounds.width <= 72, button.bounds.height <= 72 { MacHover.button(button) }
            #endif
            return
        }
        guard !(control is UITextField), !(control is UISwitch), !(control is UISegmentedControl), !(control is UISlider),
              !(control is UIRefreshControl), control.bounds.width <= 72, control.bounds.height <= 72,
              !control.interactions.contains(where: { $0 is UIPointerInteraction }) else { return }
        control.addInteraction(UIPointerInteraction(delegate: ButtonPointer.shared))
        #if targetEnvironment(macCatalyst)
        MacHover.button(control)
        #endif
    }
}

final class RowPointer: NSObject, UIPointerInteractionDelegate {
    static let shared = RowPointer()

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        guard let cell = Self.cell(interaction.view, at: request.location) else { return nil }
        return UIPointerRegion(rect: cell.frame, identifier: ObjectIdentifier(cell))
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard let cell = Self.cell(interaction.view, at: CGPoint(x: region.rect.midX, y: region.rect.midY)), cell.window != nil else { return nil }
        return UIPointerStyle(effect: .hover(UITargetedPreview(view: cell), preferredTintMode: .overlay, prefersShadow: false,
                                             prefersScaledContent: false))
    }

    /// The tappable row at `point` (a header, a skeleton or a plain text row gets no effect).
    static func cell(_ view: UIView?, at point: CGPoint) -> UIView? {
        if let list = view as? UICollectionView, let path = list.indexPathForItem(at: point), let cell = list.cellForItem(at: path) {
            let allowed = list.delegate?.collectionView?(list, shouldHighlightItemAt: path) ?? true
            return allowed ? cell : nil
        }
        if let table = view as? UITableView, let path = table.indexPathForRow(at: point), let cell = table.cellForRow(at: path) {
            let allowed = table.delegate?.tableView?(table, shouldHighlightRowAt: path) ?? (cell.selectionStyle != .none)
            return allowed ? cell : nil
        }
        return nil
    }
}

private final class ButtonPointer: NSObject, UIPointerInteractionDelegate {
    static let shared = ButtonPointer()

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard let view = interaction.view, view.window != nil else { return nil }
        return UIPointerStyle(effect: .highlight(UITargetedPreview(view: view)))
    }
}

#if targetEnvironment(macCatalyst)
/// [mac] The hover the Mac doesn't draw: one fill view per list, moved to the row under the pointer.
@MainActor final class MacHover: NSObject {
    /// Faint enough that a row's text and the selected row's own colour read through it, light and dark.
    static let rowFill = UIColor.label.withAlphaComponent(0.05)
    static let buttonFill = UIColor.label.withAlphaComponent(0.08)
    private static var key = 0

    private weak var list: UIScrollView?
    private weak var hovered: UIView?
    private let fill = UIView()
    private var offset: NSKeyValueObservation?
    private weak var recognizer: UIHoverGestureRecognizer?

    static func rows(_ list: UIScrollView) {
        guard objc_getAssociatedObject(list, &key) == nil else { return }
        let hover = MacHover(list: list)
        objc_setAssociatedObject(list, &key, hover, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static var ownKey = 0

    /// A cell that draws its own hover (a pinned bot's tile: a halo round the face, owner 2026-10-28): the list's
    /// square fill skips it and tells it instead, true as the pointer comes in and false as it leaves.
    static func ownsHover(_ cell: UIView, _ changed: @escaping @MainActor (Bool) -> Void) {
        objc_setAssociatedObject(cell, &ownKey, OwnHover(changed), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static func own(_ view: UIView?) -> OwnHover? {
        view.flatMap { objc_getAssociatedObject($0, &ownKey) as? OwnHover }
    }

    private final class OwnHover {
        let changed: @MainActor (Bool) -> Void
        init(_ changed: @escaping @MainActor (Bool) -> Void) { self.changed = changed }
    }

    static func button(_ control: UIControl) {
        guard objc_getAssociatedObject(control, &key) == nil else { return }
        let hover = ButtonHover(control)
        objc_setAssociatedObject(control, &key, hover, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private init(list: UIScrollView) {
        self.list = list
        super.init()
        fill.isUserInteractionEnabled = false
        fill.backgroundColor = Self.rowFill
        fill.accessibilityElementsHidden = true
        let recognizer = UIHoverGestureRecognizer(target: self, action: #selector(moved(_:)))
        recognizer.cancelsTouchesInView = false
        list.addGestureRecognizer(recognizer)
        self.recognizer = recognizer
        // A wheel scroll under a still pointer moves the rows, not the pointer: the fill follows the row now under it.
        offset = list.observe(\.contentOffset) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    @objc private func moved(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed: update()
        default: show(nil)
        }
    }

    private func update() {
        guard let list, let recognizer, recognizer.state == .began || recognizer.state == .changed else { return }
        show(RowPointer.cell(list, at: recognizer.location(in: list)))
    }

    private func show(_ cell: UIView?) {
        let row = cell.flatMap { ($0 as? UICollectionViewCell)?.isSelected == true || ($0 as? UITableViewCell)?.isSelected == true ? nil : $0 }
        let ownsRow = Self.own(row) != nil
        guard row !== hovered || (ownsRow ? false : fill.superview !== row) else { return }
        if let old = hovered, old !== row { Self.own(old)?.changed(false) }
        hovered = row
        if let row, ownsRow {
            fill.layer.removeAllAnimations()
            fill.removeFromSuperview()
            Self.own(row)?.changed(true)
            return
        }
        guard let row else {
            UIView.animate(withDuration: 0.06, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { // motion-ok: hover fill fades opacity only
                self.fill.alpha = 0
            } completion: { [weak self] done in if done, self?.hovered == nil { self?.fill.removeFromSuperview() } }
            return
        }
        fill.layer.removeAllAnimations()
        fill.alpha = 1
        fill.frame = row.bounds
        fill.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // The row's own rounding (an inset group's first and last rows), from the background view that draws it.
        let shape = row.subviews.first { $0 !== fill && $0.layer.cornerRadius > 0 }?.layer
        fill.layer.cornerRadius = shape?.cornerRadius ?? 0
        fill.layer.maskedCorners = shape?.maskedCorners ?? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        fill.layer.cornerCurve = .continuous
        // Over the row's background, under its text.
        if let content = (row as? UICollectionViewCell)?.contentView ?? (row as? UITableViewCell)?.contentView {
            row.insertSubview(fill, belowSubview: content)
        } else {
            row.addSubview(fill)
        }
    }
}

/// [mac] Tester 2026-11-09: "mouse hover states are missing in a few places". Hover was installed as a page landed
/// in a navigation stack, so a sheet, a popover, the right panel's tabs and anything added after the page showed never
/// got it. Each window now watches the pointer: the list and the small controls under it take the same hover the
/// pages' own do, the first time the pointer reaches them (`PointerEffects.rows` and `.button` install once).
@MainActor final class MacHoverScout: NSObject {
    private static var key = 0
    private static var started = false
    private var last: CFTimeInterval = 0
    private weak var lastHit: UIView?

    /// Every window, as it shows, from now on.
    static func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(listener, selector: #selector(windowShown(_:)),
                                               name: UIWindow.didBecomeVisibleNotification, object: nil)
        for scene in UIApplication.shared.connectedScenes { (scene as? UIWindowScene)?.windows.forEach(watch) }
    }

    private static let listener = MacHoverScout()

    @objc private func windowShown(_ note: Notification) {
        (note.object as? UIWindow).map(Self.watch)
    }

    private static func watch(_ window: UIWindow) {
        guard objc_getAssociatedObject(window, &key) == nil else { return }
        let scout = MacHoverScout()
        let recognizer = UIHoverGestureRecognizer(target: scout, action: #selector(moved(_:)))
        recognizer.cancelsTouchesInView = false
        window.addGestureRecognizer(recognizer)
        objc_setAssociatedObject(window, &key, scout, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @objc private func moved(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed, let window = recognizer.view as? UIWindow else { return }
        let now = CACurrentMediaTime()
        guard now - last > 0.05 else { return }   // a hit test at most twenty times a second
        last = now
        guard let hit = window.hitTest(recognizer.location(in: window), with: nil), hit !== lastHit else { return }
        lastHit = hit
        var view: UIView? = hit
        while let here = view, !(here is UIWindow) {
            if let list = here as? UICollectionView {
                PointerEffects.rows(list)
            } else if let table = here as? UITableView, !(table.transform.d < 0) {   // not the chat's inverted transcript
                PointerEffects.rows(table)
            } else if let control = here as? UIControl {
                PointerEffects.button(control)
            }
            view = here.superview
        }
    }
}

/// [mac] A small round control's hover: a faint fill of its own shape behind it.
@MainActor private final class ButtonHover: NSObject {
    private weak var control: UIControl?
    private let fill = UIView()

    init(_ control: UIControl) {
        self.control = control
        super.init()
        fill.isUserInteractionEnabled = false
        fill.backgroundColor = MacHover.buttonFill
        fill.alpha = 0
        let recognizer = UIHoverGestureRecognizer(target: self, action: #selector(moved(_:)))
        control.addGestureRecognizer(recognizer)
    }

    @objc private func moved(_ recognizer: UIHoverGestureRecognizer) {
        guard let control else { return }
        switch recognizer.state {
        case .began, .changed:
            guard control.isEnabled, !control.isHidden else { return }
            // A disc round an icon button; a capsule (the control's own shape) for one clearly wider than it is tall.
            // Owner 2026-11-03: a circle as wide as the composer's model bubble stuck out above and below it ("looks
            // really weird").
            let box = control.bounds
            if box.width > box.height * 1.25 {
                fill.frame = box
                fill.layer.cornerRadius = box.height / 2
            } else {
                let side = max(box.width, box.height)
                fill.frame = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
                fill.layer.cornerRadius = side / 2
            }
            if fill.superview !== control { control.insertSubview(fill, at: 0) }
            fill.layer.removeAllAnimations()
            fill.alpha = 1
        default:
            UIView.animate(withDuration: 0.06, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.fill.alpha = 0 }   // motion-ok: hover fill fades opacity only
        }
    }
}
#endif
