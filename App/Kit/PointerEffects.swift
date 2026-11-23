// [m9/ipad] Pointer (trackpad / mouse) effects, system behaviours only (docs/spec/3x-ipad.md §4.9): list rows show
// the system hover, round buttons the system highlight. Nothing appears only on hover.
//
// [mac] The Mac draws no pointer effect (Catalyst honours a pointer interaction's cursor shape only), so moving the
// mouse over a row changed nothing. There the row under the pointer gets a faint fill of its own (`MacHover`: in at
// once, out in 60 ms, as the Desktop Look's hover), and a small round control a faint one of its shape behind it. Installed once per screen as
// it shows (`PushedPageTitles.didShow`, the right pane's stack included), so no list or cell has to opt in.

import SwiftUI
import UIKit

// Never mistake an already-visible hover overlay for the button's own background on the next mouse event.
private final class PointerFillView: UIView {}

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
        if let control = view as? UIControl { button(control, discovered: true) }
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
    /// [Mac AAA 2026-11-17] `pill`: as `capsule`, but in the Desktop Look the look's 4 pt box (`HQPill`'s rule).
    static func surface(_ view: UIView, radius: CGFloat? = nil, capsule: Bool = false, pill: Bool = false, above: UIView? = nil, host: UIView? = nil) {
        #if targetEnvironment(macCatalyst)
        MacHover.surface(view, shape: pill ? .pill : capsule ? .capsule : radius.map { .rounded($0) } ?? .own, above: above, host: host)
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
    /// [hover-shape] A control with its own `outline` takes it whatever its size (its tap area is larger than what it draws).
    static func button(_ control: UIControl, discovered: Bool = false) {
        // Decide from the live plate when the pointer arrives, not from a possibly zero size when the page is scanned.
        if let button = control as? UIButton, button.configuration != nil {
            button.isPointerInteractionEnabled = true
            #if targetEnvironment(macCatalyst)
            MacHover.button(button, discovered: discovered)
            #endif
            return
        }
        guard !(control is UITextField), !(control is UISwitch), !(control is UISegmentedControl), !(control is UISlider),
              !(control is UIRefreshControl) else { return }
        if let existing = control.interactions.first(where: { $0 is UIPointerInteraction }) as? UIPointerInteraction {
            // The control's deliberate choice outranks an earlier page scan. Never replace a system or custom delegate.
            guard !discovered, existing.delegate === ButtonPointer.scouted else { return }
            control.removeInteraction(existing)
        }
        control.addInteraction(UIPointerInteraction(delegate: discovered ? ButtonPointer.scouted : ButtonPointer.explicit))
        #if targetEnvironment(macCatalyst)
        MacHover.button(control, discovered: discovered)
        #endif
    }

    // MARK: Outlines

    /// [hover-shape] Owner 2026-11-22 (the Activity pill's hover, a capsule round its whole 44 pt tap area over the pill's
    /// 4 pt box: "this highlight isn't shaped properly … fix everywhere"): the pointer's fill (the Mac's) and highlight
    /// (the iPad's) take the shape the control DRAWS, never a guess from its bounds. `rect` is in the view's own space;
    /// `strong`: a button's fill (else a row's, fainter); `plate`: the view that draws the shape, which the Mac's fill
    /// goes inside, over its colour (a filled button's colour would otherwise cover a fill put under it).
    struct Outline: Equatable {
        var rect: CGRect
        var radius: CGFloat
        var corners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        var strong = true
        weak var plate: UIView?
    }

    private final class OutlineBox {
        var lastLayout: Outline?
        let make: @MainActor () -> Outline?
        init(_ make: @escaping @MainActor () -> Outline?) { self.make = make }
    }
    private static var outlineKey = 0

    /// A view whose drawn shape is not its own bounds nor a plate inside it (a 44 pt tap area over a 34 pt pill drawn
    /// beside it, a line over a frosted pill): its outline, asked each time the pointer comes. nil: no fill now.
    static func outline(_ view: UIControl, _ make: @escaping @MainActor () -> Outline?) {
        objc_setAssociatedObject(view, &outlineKey, OutlineBox(make), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if UIDevice.current.userInterfaceIdiom == .pad || DeviceWord.isMac { button(view) }
    }

    /// The plate may change under a stationary pointer: expanding the shelf, changing looks, or reusing a transcript row.
    static func outlineDidLayout(_ view: UIControl) {
        guard let box = objc_getAssociatedObject(view, &outlineKey) as? OutlineBox else { return }
        let next = box.make()
        guard next != box.lastLayout else { return }
        box.lastLayout = next
        #if targetEnvironment(macCatalyst)
        MacHover.refresh(view)
        #else
        view.interactions.compactMap { $0 as? UIPointerInteraction }.forEach { $0.invalidate() }
        #endif
    }

    static func hasOwnOutline(_ view: UIView) -> Bool { objc_getAssociatedObject(view, &outlineKey) != nil }

    /// The outline a view's own `outline` gives (nil when it has none, or none now).
    static func ownOutline(of view: UIView) -> Outline? {
        (objc_getAssociatedObject(view, &outlineKey) as? OutlineBox)?.make()
    }

    /// The shape `view` draws as a button: its own outline; else its own colour or border in its own corners; else the
    /// plate it draws inside itself (a configured button's background: the colour is a subview, the corners the
    /// button's own layer's); nil for a bare glyph or words.
    static func drawnOutline(of view: UIView) -> Outline? {
        if hasOwnOutline(view) { return ownOutline(of: view) }
        let box = view.bounds
        guard box.width > 0, box.height > 0 else { return nil }
        func clamp(_ radius: CGFloat, _ rect: CGRect) -> CGFloat { min(radius, min(rect.width, rect.height) / 2) }
        if draws(view) {
            return Outline(rect: box, radius: clamp(view.layer.cornerRadius, box), corners: view.layer.maskedCorners, plate: view)
        }
        // A plate: a coloured or bordered view inside it covering most of it (not a dot, a badge or a glyph).
        func find(_ parent: UIView, depth: Int) -> UIView? {
            for child in parent.subviews where !child.isHidden && child.alpha > 0.01 && !(child is PointerFillView)
                && !(child is UILabel) && !(child is UIImageView) && !(child is UIControl) {
                let frame = child.convert(child.bounds, to: view)
                if draws(child), frame.width >= box.width * 0.5, frame.height >= box.height * 0.5 { return child }
                if depth > 0, let deeper = find(child, depth: depth - 1) { return deeper }
            }
            return nil
        }
        guard let plate = find(view, depth: 2) else { return nil }
        let frame = plate.convert(plate.bounds, to: view)
        // The corners: the plate's own, else the nearest ancestor's that rounds it (a configured button rounds its own layer).
        var radius = plate.layer.cornerRadius
        var corners = plate.layer.maskedCorners
        var up = plate.superview
        while radius == 0, let here = up {
            if here.layer.cornerRadius > 0 { radius = here.layer.cornerRadius; corners = here.layer.maskedCorners }
            if here === view { break }
            up = here.superview
        }
        return Outline(rect: frame, radius: clamp(radius, frame), corners: corners, plate: plate)
    }

    /// Whether a view paints something of its own: a colour that shows, or a border.
    private static func draws(_ view: UIView) -> Bool {
        if view.layer.borderWidth > 0, let border = view.layer.borderColor, border.alpha > 0.01 { return true }
        guard let color = view.backgroundColor else { return false }
        return color.resolvedColor(with: view.traitCollection).cgColor.alpha > 0.01
    }

    /// No visible plate: keep a small glyph's affordance inside its target. An unlaid-out control found by the scout
    /// may since have become a whole row; only an explicitly interactive surface should light a large empty area.
    static func bareOutline(in box: CGRect, discovered: Bool) -> Outline? {
        guard !box.isEmpty else { return nil }
        if box.width > 72 || box.height > 72 {
            return discovered ? nil : Outline(rect: box, radius: HQShape.radius(8, .control))
        }
        if box.width > box.height * 1.25 { return Outline(rect: box, radius: box.height / 2) }
        let side = min(box.width, box.height)
        return Outline(rect: CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side), radius: side / 2)
    }

    /// The outline as a path in the view's space (the iPad pointer's highlight).
    static func path(_ outline: Outline) -> UIBezierPath {
        var corners: UIRectCorner = []
        if outline.corners.contains(.layerMinXMinYCorner) { corners.insert(.topLeft) }
        if outline.corners.contains(.layerMaxXMinYCorner) { corners.insert(.topRight) }
        if outline.corners.contains(.layerMinXMaxYCorner) { corners.insert(.bottomLeft) }
        if outline.corners.contains(.layerMaxXMaxYCorner) { corners.insert(.bottomRight) }
        return UIBezierPath(roundedRect: outline.rect, byRoundingCorners: corners,
                            cornerRadii: CGSize(width: outline.radius, height: outline.radius))
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
    static let scouted = ButtonPointer(discovered: true)
    static let explicit = ButtonPointer(discovered: false)
    private let discovered: Bool
    private init(discovered: Bool) { self.discovered = discovered }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard let view = interaction.view, view.window != nil else { return nil }
        // [hover-shape] The highlight takes the shape the control draws; a control that has grown past a small button
        // since it was swept (a pill that was 0 × 0 then) and draws nothing gets none.
        let parameters = UIPreviewParameters()
        let outline = PointerEffects.drawnOutline(of: view) ?? (PointerEffects.hasOwnOutline(view) ? nil : PointerEffects.bareOutline(in: view.bounds, discovered: discovered))
        guard let outline else { return nil }
        parameters.visiblePath = PointerEffects.path(outline)
        return UIPointerStyle(effect: .highlight(UITargetedPreview(view: view, parameters: parameters)))
    }
}

#if targetEnvironment(macCatalyst)
/// [mac] The hover the Mac doesn't draw: one fill view per list, moved to the row under the pointer.
@MainActor final class MacHover: NSObject {
    /// Faint enough that a row's text and the selected row's own colour read through it, light and dark.
    static let rowFill = tone(0.05)
    static let buttonFill = tone(0.08)
    /// While the mouse button is down: the same fill, deeper (a row's, a card's; a small button's).
    static let rowPressFill = tone(0.1)
    static let buttonPressFill = tone(0.14)

    /// [Mac AAA 2026-11-16] Under Increase Contrast a 5 % fill is all but invisible: the fills there are twice as deep.
    private static func tone(_ alpha: CGFloat) -> UIColor {
        UIColor { traits in
            let high = traits.accessibilityContrast == .high || HQAccessibility.overrides.contrast
            return UIColor.label.resolvedColor(with: traits).withAlphaComponent(high ? alpha * 2 : alpha)
        }
    }
    private static var key = 0

    /// What a control's fill is cut to: a disc round an icon button (a capsule when it is clearly wider than tall), the
    /// view's own corners, a capsule, or corners of a given radius.
    /// `pill`: a capsule with the Desktop Look off, its 4 pt box with it on (read when shown, so it follows the look).
    enum Shape { case button, scouted, own, capsule, pill, rounded(CGFloat) }

    private weak var list: UIScrollView?
    private weak var hovered: UIView?
    private let fill = PointerFillView()
    private var offset: NSKeyValueObservation?
    private var size: NSKeyValueObservation?
    private weak var recognizer: UIHoverGestureRecognizer?

    static func rows(_ list: UIScrollView) {
        guard objc_getAssociatedObject(list, &key) == nil else { return }
        let hover = MacHover(list: list)
        objc_setAssociatedObject(list, &key, hover, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    #if DEBUG
    /// [Mac AAA 2026-11-16] Tours: the hover on `row` as the pointer would put it there (tours can't move the pointer).
    static func debugHover(_ list: UIScrollView, row: UIView?) {
        rows(list)
        (objc_getAssociatedObject(list, &key) as? MacHover)?.show(row)
    }

    /// [Mac AAA 2026-11-17] Tours: a `surface`'s hover drawn as the pointer over it would draw it.
    static func debugHoverSurface(_ view: UIView, _ on: Bool = true) {
        (objc_getAssociatedObject(view, &key) as? ButtonHover)?.debugOver(on)
    }

    /// Tours: the hover installed on `view` and the fill it draws now, in `root`'s coordinates.
    static func debugHoverReport(_ view: UIView, in root: UIView) -> String {
        guard let hover = objc_getAssociatedObject(view, &key) as? ButtonHover else { return "no hover" }
        return hover.debugReport(in: root)
    }
    #endif

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

    static func button(_ control: UIControl, discovered: Bool = false) {
        surface(control, shape: discovered ? .scouted : .button)
    }

    static func refresh(_ view: UIView) {
        (objc_getAssociatedObject(view, &key) as? ButtonHover)?.refresh()
    }

    #if DEBUG
    /// [hover-shape] Tours: every control given a small button's hover, with its size then. One swept at 0 × 0 that has
    /// since grown past a small button is where the old capsule round a tap area came from.
    static func debugSweptReport(in root: UIView) -> String {
        var lines: [String] = []
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0 else { return }
            if let hover = objc_getAssociatedObject(view, &key) as? ButtonHover {
                let from = hover.installedSize, now = view.bounds.size
                if from == .zero && (now.width > 72 || now.height > 72) {
                    lines.append("  \(type(of: view)) \(view.accessibilityIdentifier ?? ""): \(from) → \(now)")
                }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return lines.joined(separator: "\n")
    }
    #endif

    /// A view that is not a small control (`PointerEffects.surface`), or a button that is not a `UIControl` (the
    /// composer's ☰, on glass): the fill in `shape`, over `above`, inside `host`.
    static func surface(_ view: UIView, shape: Shape, above: UIView? = nil, host: UIView? = nil) {
        if let existing = objc_getAssociatedObject(view, &key) {
            (existing as? ButtonHover)?.replaceScouted(with: shape, above: above, host: host)
            return
        }
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
        // [macpass-lists] A list laid out again under a still pointer (Tasks' table turning into its column as a task
        // opens) gave the hovered cell to another row: the fill stayed on it, a grey row nothing pointed at. It goes
        // to the row now under the pointer once the rows have settled.
        size = list.observe(\.contentSize) { [weak self] _, _ in
            MainActor.assumeIsolated { DispatchQueue.main.async { self?.update() } }
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
            UIView.animate(withDuration: HQMotion.hover, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { // motion-ok: hover fill fades opacity only
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
        // [Mac AAA 2026-11-16] A plain list's row whose selection is an inset rounded box (`MacSelection.listRow`): the
        // hover is that box too (it was a square band across the list, which the click then turned into the box).
        if let background = (row as? UICollectionViewCell)?.backgroundConfiguration, background.cornerRadius > 0,
           background.backgroundInsets != .zero {
            let inset = background.backgroundInsets
            fill.frame = row.bounds.inset(by: UIEdgeInsets(top: inset.top, left: inset.leading, bottom: inset.bottom, right: inset.trailing))
            fill.layer.cornerRadius = background.cornerRadius
            fill.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
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
                PointerEffects.button(control, discovered: true)
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
    private var shape: MacHover.Shape
    private let fill = PointerFillView()
    #if DEBUG
    let installedSize: CGSize
    #endif
    private var over = false
    private var pressed = false
    private var highlight: NSKeyValueObservation?

    init(_ view: UIView, shape: MacHover.Shape, above: UIView? = nil, host: UIView? = nil) {
        self.view = view
        self.shape = shape
        #if DEBUG
        self.installedSize = view.bounds.size
        #endif
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

    /// Keep one recognizer if a control configures its own surface after the window has already discovered it.
    func replaceScouted(with next: MacHover.Shape, above: UIView?, host: UIView?) {
        guard case .scouted = shape else { return }
        if case .scouted = next { return }
        shape = next
        self.above = above
        self.host = host
        refresh()
    }

    func refresh() {
        if over || pressed || (view as? UIControl)?.isHighlighted == true { show() }
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

    #if DEBUG
    func debugOver(_ on: Bool) {
        over = on
        show()
    }

    func debugReport(in root: UIView) -> String {
        let f = fill.superview.map { $0.convert(fill.frame, to: root) } ?? .zero
        return String(format: "shape %@, fill (%.1f, %.1f, %.1f × %.1f) radius %.1f alpha %.2f", String(describing: shape),
                      f.minX, f.minY, f.width, f.height, fill.layer.cornerRadius, fill.alpha)
    }
    #endif

    private func hide() {
        guard fill.alpha > 0 else { return }
        UIView.animate(withDuration: HQMotion.hover, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.fill.alpha = 0 }   // motion-ok: hover fill fades opacity only
    }

    private func show() {
        guard let view else { return }
        let control = view as? UIControl
        let down = pressed || control?.isHighlighted == true
        guard over || down, control?.isEnabled != false, !view.isHidden, view.isUserInteractionEnabled else { return hide() }
        var holder = host ?? view
        let box = holder.bounds
        let small: Bool
        fill.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        // [hover-shape] The shape the control draws (its own outline, else a swept button's plate), not a guess from
        // its box: the fill goes inside the plate, over its colour, in the plate's corners.
        let own = PointerEffects.hasOwnOutline(view)
        var drawn: PointerEffects.Outline?
        if own {
            guard let outline = PointerEffects.ownOutline(of: view) else { return hide() }
            drawn = outline
        } else {
            switch shape {
            case .button, .scouted: drawn = PointerEffects.drawnOutline(of: holder)
            default: break
            }
        }
        if let drawn {
            small = drawn.strong
            let target = drawn.plate ?? holder
            fill.frame = (own ? view : holder).convert(drawn.rect, to: target)
            fill.layer.cornerRadius = drawn.radius
            fill.layer.maskedCorners = drawn.corners
            holder = target
        } else {
            switch shape {
            case .button, .scouted:
                let discovered: Bool = if case .scouted = shape { true } else { false }
                guard let outline = PointerEffects.bareOutline(in: box, discovered: discovered) else { return hide() }
                small = true
                fill.frame = outline.rect
                fill.layer.cornerRadius = outline.radius
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
            case .pill:
                small = true
                fill.frame = box
                fill.layer.cornerRadius = HQShape.radius(box.height / 2, .capsule)
            case .rounded(let radius):
                small = false
                fill.frame = box
                // A plain UIButton can have a 17 pt layer radius without drawing a plate. Keep the requested tab/row shape.
                fill.layer.cornerRadius = radius
            }
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

    /// [Mac AAA 2026-11-16] An icon-only SwiftUI button's name: what VoiceOver says, and on the Mac the tip shown under
    /// the pointer. A UIKit button gets its tip from its label by itself (`MacToolTips`), but a SwiftUI button is not a
    /// view the window can find, so an `accessibilityLabel` alone showed no tip.
    /// [Mac AAA rest 2026-11-17] The tip on the Mac only: on the iPhone and iPad `help` is also VoiceOver's hint, so the
    /// button read its name twice; there it is the plain `accessibilityLabel` it was before the polish.
    @ViewBuilder func hqIconLabel(_ label: String) -> some View {
        #if targetEnvironment(macCatalyst)
        accessibilityLabel(label).help(label)
        #else
        accessibilityLabel(label)
        #endif
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
    /// [rest-hands 2026-11-17] P-2: the press deepens the fill on mouse-down, as UIKit's rows do (`MacHover`). Read from
    /// the app's mouse button (`MacMouseButton`), never from a gesture: a zero-distance drag on the row was tried with
    /// the real pointer and took the click and the drag from a Kanban card's list (the card neither opened nor moved).
    @State private var pressed = false
    @ObservedObject private var mouse = MacMouseButton.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                shape.fill(Color(uiColor: pressed ? MacHover.rowPressFill : MacHover.rowFill))
                    .opacity(over && on ? 1 : 0).allowsHitTesting(false)
            }
            .onHover { inside in
                over = inside
                if inside { MacMouseButton.shared.watch() } else { pressed = false }
            }
            .onChange(of: mouse.down) { _, down in pressed = down && over }
    }
}

/// [rest-hands 2026-11-17] Whether the mouse's main button is down in this app: an AppKit local monitor that only
/// looks (every event goes on unchanged), installed the first time a SwiftUI row is under the pointer.
@MainActor final class MacMouseButton: ObservableObject {
    static let shared = MacMouseButton()
    @Published private(set) var down = false
    private var monitor: AnyObject?

    func watch() {
        guard monitor == nil, let events = NSClassFromString("NSEvent"),
              let method = class_getClassMethod(events, NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:")) else { return }
        typealias Handler = @convention(block) (NSObject) -> NSObject?
        typealias Add = @convention(c) (AnyClass, Selector, UInt64, @escaping Handler) -> AnyObject?
        let add = unsafeBitCast(method_getImplementation(method), to: Add.self)
        let leftDown: UInt64 = 1 << 1, leftUp: UInt64 = 1 << 2
        monitor = add(events, NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:"), leftDown | leftUp) { event in
            let type = (event.value(forKey: "type") as? NSNumber)?.intValue
            MainActor.assumeIsolated { MacMouseButton.shared.down = type == 1 }
            return event
        }
    }
}
#endif
