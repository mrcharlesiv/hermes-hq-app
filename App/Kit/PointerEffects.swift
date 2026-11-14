// [m9/ipad] Pointer (trackpad / mouse) effects, system behaviours only (docs/spec/3x-ipad.md §4.9): list rows show
// the system hover, round buttons the system highlight. Nothing appears only on hover.
//
// [mac] The Mac draws no pointer effect (Catalyst honours a pointer interaction's cursor shape only), so moving the
// mouse over a row changed nothing. There the row under the pointer gets a faint fill of its own (`MacHover`: in at
// once, out in 60 ms, as the Desktop Look's hover), and a small round control a faint one of its shape behind it. Installed once per screen as
// it shows (`PushedPageTitles.didShow`, the right pane's stack included), so no list or cell has to opt in.

import SwiftUI
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

    /// [mac] Feel list B (2026-11-13): a card, a chip or a wide control (a file card, a link chip, the model bubble, the
    /// chat's title) answers the pointer too: a faint fill of its own shape under the pointer, a little deeper while
    /// the mouse button is down. `above`: the view's own backing, which the fill goes over (else it goes under
    /// everything); `host`: the view the fill is drawn in and takes its size from, when that is not the view itself (a
    /// glass view's content view, the circle inside a larger tap area).
    /// Nothing on the iPhone and the iPad, which draw the system's effect.
    static func surface(_ view: UIView, radius: CGFloat? = nil, capsule: Bool = false, above: UIView? = nil, host: UIView? = nil) {
        #if targetEnvironment(macCatalyst)
        MacHover.surface(view, shape: capsule ? .capsule : radius.map { .rounded($0) } ?? .own, above: above, host: host)
        #endif
    }

    /// The press of a `surface` that is not a `UIControl` (a control's is read from `isHighlighted`).
    static func press(_ view: UIView, _ down: Bool) {
        #if targetEnvironment(macCatalyst)
        MacHover.press(view, down)
        #endif
    }

    /// A `surface` that is a row of a rounded card which does not clip its rows: its fill spans the card and takes the
    /// card's corners where the row is the first or the last. `card` is in the row's superview.
    static func fit(_ row: UIView, card: CGRect, radius: CGFloat) {
        #if targetEnvironment(macCatalyst)
        MacHover.fit(row, card: card, radius: radius)
        #endif
    }

    /// The opacity a pressed card or chip dims to. The Mac's press is the deeper fill (`surface`), so nothing dims there:
    /// a card that lit up under the pointer and then went dark under the click read as two different answers.
    static func dim(_ pressed: Bool, to alpha: CGFloat) -> CGFloat {
        #if targetEnvironment(macCatalyst)
        return 1
        #else
        return pressed ? alpha : 1
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
    /// While the mouse button is down: the same fill, deeper (a row's, a card's; a small button's).
    static let rowPressFill = UIColor.label.withAlphaComponent(0.1)
    static let buttonPressFill = UIColor.label.withAlphaComponent(0.14)
    private static var key = 0

    /// What a control's fill is cut to: a disc round an icon button (a capsule when it is clearly wider than tall), the
    /// view's own corners, a capsule, or corners of a given radius.
    enum Shape { case button, own, capsule, rounded(CGFloat) }

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

    /// A control that draws its own hover (the Mac sidebar's Search and New Chat wells): it gets no disc. A list whose
    /// pointer moves its own mark (Open Quickly): its rows get no fill.
    static func drawsOwnHover(_ view: UIView) {
        guard objc_getAssociatedObject(view, &key) == nil else { return }
        objc_setAssociatedObject(view, &key, NSNull(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func button(_ control: UIControl) {
        guard objc_getAssociatedObject(control, &key) == nil else { return }
        let hover = ButtonHover(control, shape: .button)
        objc_setAssociatedObject(control, &key, hover, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// A view that is not a small control (`PointerEffects.surface`), or a button that is not a `UIControl` (the
    /// composer's ☰, on glass): the fill in `shape`, over `above`, inside `host`.
    static func surface(_ view: UIView, shape: Shape, above: UIView? = nil, host: UIView? = nil) {
        guard objc_getAssociatedObject(view, &key) == nil else { return }
        let hover = ButtonHover(view, shape: shape, above: above, host: host)
        objc_setAssociatedObject(view, &key, hover, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// The press of a view that is not a `UIControl` (a control's is read from `isHighlighted`).
    static func press(_ view: UIView, _ down: Bool) {
        (objc_getAssociatedObject(view, &key) as? ButtonHover)?.press(down)
    }

    /// A row of a rounded card that does not clip its rows (the chat's changed-files and tasks cards): the row's fill
    /// spans the card and takes the card's corners where the row is its first or last. `card` is in the row's superview.
    static func fit(_ row: UIView, card: CGRect, radius: CGFloat) {
        (objc_getAssociatedObject(row, &key) as? ButtonHover)?.card = (card, radius)
    }

    private init(list: UIScrollView) {
        self.list = list
        super.init()
        // Feel list B (2026-11-13): a click marks its row as the button goes down, as the sidebar's and the chat's do.
        // The scroll view held every touch back for a moment in case it was the start of a scroll, so a quick click
        // showed nothing until it was let go; on the Mac a scroll is the wheel or the trackpad, never a press.
        list.delaysContentTouches = false
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

/// [mac] A control's hover and press: a faint fill of its own shape behind it, deeper while the mouse button is down.
@MainActor private final class ButtonHover: NSObject {
    private weak var view: UIView?
    private weak var above: UIView?
    private weak var host: UIView?
    private let shape: MacHover.Shape
    private let fill = UIView()
    private var over = false
    private var pressed = false
    private var highlight: NSKeyValueObservation?

    init(_ view: UIView, shape: MacHover.Shape, above: UIView? = nil, host: UIView? = nil) {
        self.view = view
        self.shape = shape
        self.above = above
        self.host = host
        super.init()
        fill.isUserInteractionEnabled = false
        fill.accessibilityElementsHidden = true
        fill.alpha = 0
        fill.layer.cornerCurve = .continuous
        let recognizer = UIHoverGestureRecognizer(target: self, action: #selector(moved(_:)))
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        // The press: a control says so itself (a menu button stays down while its menu is open).
        if let control = view as? UIControl {
            highlight = control.observe(\.isHighlighted) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.show() }
            }
        }
    }

    func press(_ down: Bool) {
        guard pressed != down else { return }
        pressed = down
        show()
    }

    /// The card this row sits in (its frame in the row's superview) and the card's rounding.
    var card: (frame: CGRect, radius: CGFloat)?

    @objc private func moved(_ recognizer: UIHoverGestureRecognizer) {
        over = recognizer.state == .began || recognizer.state == .changed
        show()
    }

    private func show() {
        guard let view else { return }
        let control = view as? UIControl
        let down = pressed || control?.isHighlighted == true
        guard over || down, control?.isEnabled != false, !view.isHidden, view.isUserInteractionEnabled else {
            guard fill.alpha > 0 else { return }
            UIView.animate(withDuration: 0.06, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.fill.alpha = 0 }   // motion-ok: hover fill fades opacity only
            return
        }
        let holder = host ?? view
        let box = holder.bounds
        let small: Bool
        switch shape {
        case .button:
            small = true
            // A disc round an icon button; a capsule (the control's own shape) for one clearly wider than it is tall.
            // Owner 2026-11-03: a circle as wide as the composer's model bubble stuck out above and below it ("looks
            // really weird").
            if box.width > box.height * 1.25 {
                fill.frame = box
                fill.layer.cornerRadius = box.height / 2
            } else {
                let side = max(box.width, box.height)
                fill.frame = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
                fill.layer.cornerRadius = side / 2
            }
        case .own:
            small = false
            if let card {
                // A row of a card: the card's width, and the card's corners where the row meets them.
                fill.frame = CGRect(x: card.frame.minX - view.frame.minX, y: 0, width: card.frame.width, height: box.height)
                var corners: CACornerMask = []
                if abs(view.frame.minY - card.frame.minY) < 1 { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
                if abs(view.frame.maxY - card.frame.maxY) < 1 { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
                fill.layer.cornerRadius = corners.isEmpty ? 0 : card.radius
                fill.layer.maskedCorners = corners
            } else {
                fill.frame = box
                fill.layer.cornerRadius = holder.layer.cornerRadius
                fill.layer.maskedCorners = holder.layer.maskedCorners
            }
        case .capsule:
            small = true   // a pill beside the icon buttons (the composer's model bubble) answers as strongly as they do
            fill.frame = box
            fill.layer.cornerRadius = box.height / 2
        case .rounded(let radius):
            small = false
            fill.frame = box
            fill.layer.cornerRadius = radius
        }
        fill.backgroundColor = small ? (down ? MacHover.buttonPressFill : MacHover.buttonFill)
                                     : (down ? MacHover.rowPressFill : MacHover.rowFill)
        if let above, above.superview === holder {
            let subviews = holder.subviews
            if fill.superview !== holder || subviews.firstIndex(of: fill) != subviews.firstIndex(of: above).map({ $0 + 1 }) {
                holder.insertSubview(fill, aboveSubview: above)
            }
        } else if fill.superview !== holder {
            holder.insertSubview(fill, at: 0)
        }
        fill.layer.removeAllAnimations()
        fill.alpha = 1
    }
}
#endif

// MARK: - SwiftUI

extension View {
    /// [mac] Feel list B (2026-11-13): a SwiftUI button, card or row lit under the pointer, as the app's lists are
    /// (`.hoverEffect` only shapes the iPad's pointer; the Mac draws nothing for it). `on` false: no fill (the chosen
    /// row of a column, which has its own mark). Nothing on the iPhone and the iPad.
    func hqPointerFill(_ radius: CGFloat = 8, on: Bool = true) -> some View {
        hqPointerFill(RoundedRectangle(cornerRadius: radius, style: .continuous), on: on)
    }

    @ViewBuilder func hqPointerFill<Outline: Shape>(_ shape: Outline, on: Bool = true) -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(MacPointerFill(shape: shape, on: on))
        #else
        self
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private struct MacPointerFill<Outline: Shape>: ViewModifier {
    let shape: Outline
    let on: Bool
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .overlay { shape.fill(Color(uiColor: MacHover.rowFill)).opacity(over && on ? 1 : 0).allowsHitTesting(false) }
            .onHover { over = $0 }
    }
}
#endif
