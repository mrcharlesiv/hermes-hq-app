import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Pure geometry for placing a tab bar's count badge inside a capsule tab bar (iOS 26/27's floating glass bar and
/// `DesktopTabBar`'s `.glass` capsule). Every badge—1, 2 or 3+ characters, on wide or narrow icons, across 2–5 tabs
/// and any screen width—stays clear of the neighbouring tab's selection pill, inside its own tab's selection pill when
/// selected, and inside the outer capsule's rounded ends.
nonisolated enum TabBadgeLayout {
    struct Slot: Equatable, Sendable {
        /// The tab icon rect in bar coordinates.
        let icon: CGRect
        /// This tab's selection pill rect in bar coordinates (capsule of radius `min(w, h) / 2`).
        let pill: CGRect
        /// The selection pill rect of the tab immediately to the left, if any.
        let prevPill: CGRect?
        /// The selection pill rect of the tab immediately to the right, if any.
        let nextPill: CGRect?
        /// The outer bar capsule rect in bar coordinates, if known.
        let capsule: CGRect?

        init(icon: CGRect, pill: CGRect, prevPill: CGRect? = nil, nextPill: CGRect? = nil, capsule: CGRect? = nil) {
            self.icon = icon
            self.pill = pill
            self.prevPill = prevPill
            self.nextPill = nextPill
            self.capsule = capsule
        }
    }

    /// Standard badge height on the floating capsule bar (compact enough that 2–3 digit badges clear adjacent pills on
    /// narrow 5-tab iPhones without burying the icon).
    static let badgeHeight: CGFloat = 18
    /// Minimum Euclidean gap between a badge and an adjacent tab's selection pill.
    static let neighborGap: CGFloat = 6
    /// Minimum Euclidean inset keeping a badge inside its own tab's curved selection pill.
    static let ownPillInset: CGFloat = 2.5
    /// Minimum Euclidean inset keeping a badge inside the outer bar capsule.
    static let capsuleInset: CGFloat = 4
    /// How far inside the icon's right edge the badge's left edge prefers to sit before slot clamping kicks in.
    static let preferredIconOverlap: CGFloat = 8.5

    /// Computes the badge frame for `slot` and `badgeSize` (a pill of corner radius `badgeSize.height / 2`).
    static func frame(for slot: Slot, badgeSize: CGSize) -> CGRect {
        let w = max(badgeSize.width, badgeSize.height)
        let h = badgeSize.height
        let r = h / 2

        // Sit near the pill's top-right sweet spot: high enough to clear the neighbouring pill's wider mid-curve while
        // still clearing this tab's own curved top-right corner when selected.
        let topInset = min(4.0, max(1.0, (slot.pill.height - h) * 0.12))
        let minY = slot.pill.minY + topInset
        let badgeMidY = minY + r

        // Preferred position: tucked slightly onto the icon's upper-right edge.
        let preferredMinX = slot.icon.maxX - preferredIconOverlap

        // Upper bound on badge.maxX and lower bound on badge.minX from every capsule boundary.
        var maxAllowedX = CGFloat.greatestFiniteMagnitude
        var minAllowedX = -CGFloat.greatestFiniteMagnitude

        // 1. Inside this tab's own selection pill (curved top-right and top-left caps).
        let (ownMinX, ownMaxX) = horizontalBoundsInside(capsule: slot.pill, inset: ownPillInset, badgeMidY: badgeMidY, badgeRadius: r)
        maxAllowedX = min(maxAllowedX, ownMaxX)
        minAllowedX = max(minAllowedX, ownMinX)

        // 2. Inside the outer bar capsule, if provided.
        if let capsule = slot.capsule {
            let (capMinX, capMaxX) = horizontalBoundsInside(capsule: capsule, inset: capsuleInset, badgeMidY: badgeMidY, badgeRadius: r)
            maxAllowedX = min(maxAllowedX, capMaxX)
            minAllowedX = max(minAllowedX, capMinX)
        }

        // 3. Clear of the neighbouring tab's selection pill on the right.
        if let nextPill = slot.nextPill {
            let nextR = min(nextPill.width, nextPill.height) / 2
            let nextLeftCenterX = nextPill.minX + nextR
            let dy = abs(nextPill.midY - badgeMidY)
            let minCenterDist = nextR + r + neighborGap
            if dy < minCenterDist {
                let dx = sqrt(minCenterDist * minCenterDist - dy * dy)
                maxAllowedX = min(maxAllowedX, nextLeftCenterX + r - dx)
            }
        }

        // 4. Clear of the neighbouring tab's selection pill on the left.
        if let prevPill = slot.prevPill {
            let prevR = min(prevPill.width, prevPill.height) / 2
            let prevRightCenterX = prevPill.maxX - prevR
            let dy = abs(prevPill.midY - badgeMidY)
            let minCenterDist = prevR + r + neighborGap
            if dy < minCenterDist {
                let dx = sqrt(minCenterDist * minCenterDist - dy * dy)
                minAllowedX = max(minAllowedX, prevRightCenterX - r + dx)
            }
        }

        // Right-clamp wide badges so they grow inward rather than spilling into the neighbour's selection pill.
        let minX: CGFloat
        if maxAllowedX - minAllowedX < w {
            // Pathological squeeze: centre within the available span so neither side takes the full violation.
            minX = (minAllowedX + maxAllowedX - w) / 2
        } else {
            minX = max(minAllowedX, min(preferredMinX, maxAllowedX - w))
        }

        return CGRect(x: minX, y: minY, width: w, height: h)
    }

    /// The exact Euclidean distance between a badge capsule and an external pill capsule on its right (`> 0` = clear,
    /// `< 0` = overlapping). Used by tests to verify clearance.
    static func clearance(of badge: CGRect, fromRightPill pill: CGRect) -> CGFloat {
        let r = min(badge.width, badge.height) / 2
        let R = min(pill.width, pill.height) / 2
        let badgeRightCap = CGPoint(x: badge.maxX - r, y: badge.midY)
        let pillLeftCap = CGPoint(x: pill.minX + R, y: pill.midY)
        if badgeRightCap.x >= pillLeftCap.x {
            return -(badge.maxX - pill.minX)
        }
        return hypot(pillLeftCap.x - badgeRightCap.x, pillLeftCap.y - badgeRightCap.y) - (R + r)
    }

    /// How far a badge capsule sits inside an enclosing pill capsule (`> 0` = strictly inside, `< 0` = overhanging).
    static func inset(of badge: CGRect, inside pill: CGRect) -> CGFloat {
        let r = min(badge.width, badge.height) / 2
        let R = min(pill.width, pill.height) / 2
        let leftCenterX = pill.minX + R
        let rightCenterX = pill.maxX - R
        let topClear = badge.minY - pill.minY
        let bottomClear = pill.maxY - badge.maxY

        let badgeRightCapX = badge.maxX - r
        let rightClear: CGFloat
        if badgeRightCapX > rightCenterX {
            rightClear = (R - r) - hypot(badgeRightCapX - rightCenterX, badge.midY - pill.midY)
        } else {
            rightClear = min(topClear, bottomClear)
        }

        let badgeLeftCapX = badge.minX + r
        let leftClear: CGFloat
        if badgeLeftCapX < leftCenterX {
            leftClear = (R - r) - hypot(leftCenterX - badgeLeftCapX, badge.midY - pill.midY)
        } else {
            leftClear = min(topClear, bottomClear)
        }

        return min(topClear, bottomClear, leftClear, rightClear)
    }

    /// Horizontal `[minX, maxX]` span for a badge of radius `badgeRadius` centred vertically at `badgeMidY` so that
    /// both its left and right circular caps stay at least `inset` inside `capsule`.
    private static func horizontalBoundsInside(capsule: CGRect, inset: CGFloat, badgeMidY: CGFloat, badgeRadius r: CGFloat) -> (minX: CGFloat, maxX: CGFloat) {
        let capR = min(capsule.width, capsule.height) / 2
        let leftCenterX = capsule.minX + capR
        let rightCenterX = capsule.maxX - capR
        let dy = abs(capsule.midY - badgeMidY)
        let allowedDist = max(0, capR - r - inset)
        let dx = dy <= allowedDist ? sqrt(allowedDist * allowedDist - dy * dy) : 0
        return (leftCenterX - r - dx, rightCenterX + r + dx)
    }
}

/// [badges] The iPhone tab bar's count badges, drawn by the app above the bar's glass (owner 2026-10-30 on 500: when a
/// tab is picked "the red notification goes behind the icon for a second, and then moves back in front"). iOS 26 fades
/// its own badges while the glass selection slides under them and lets the magnified icon show through; these sit over
/// the whole bar, so they stay as they are. Each goes on its tab's icon, found among the bar's views by public type
/// only (`UIControl` buttons, their `UIImageView`). When those don't match the bar's items (another iOS), it draws
/// nothing and `onChange(false)` hands the badges back to the bar.
///
/// A badge never moves while the bar is pressed. A press stretches the bar and grows its icons without a layout pass:
/// 506 measured them part way through and left badges off their icons (owner: the dot "would sit in different spots
/// on the icons at different times"), and 509 followed them frame by frame, which read as the dot jumping up as a
/// finger landed and wobbling while the glass moved (owner on 509, screen recording). So each badge's place is measured
/// only with the bar at rest (no finger on it, every icon where its layout puts it, unscaled) and held until then.
@MainActor
final class TabBadgeOverlay: UIView {
    /// Fallback adjustment for UIKit's own badges when the overlay hands drawing back to the bar.
    static let shift = UIOffset(horizontal: 6, vertical: 2)

    /// Whether the overlay draws the badges, each time that changes.
    var onChange: ((Bool) -> Void)?

    private weak var bar: UITabBar?
    private var badges: [UILabel] = []
    private var drawing: Bool?
    /// Each tab's button and icon, left to right, as found with no finger on the bar.
    private var icons: [(button: UIView, icon: UIView)] = []
    /// Each tab's measured slot geometry (at rest), used by `place()` to fit any badge width cleanly.
    private(set) var slots: [TabBadgeLayout.Slot] = []
    /// Runs while the bar is pressed or settling, to measure again once it is at rest.
    private var wait: CADisplayLink?
    private var waitStart: CFTimeInterval = 0
    private var calm = 0
    private var touching = false
    private var lastBoundsSize: CGSize = .zero

    /// Visible badge frames by tab index (for unit tests).
    var badgeFramesForTests: [Int: CGRect] {
        var result: [Int: CGRect] = [:]
        for (index, badge) in badges.enumerated() where !badge.isHidden {
            result[index] = badge.frame
        }
        return result
    }

    init(bar: UITabBar) {
        self.bar = bar
        super.init(frame: bar.bounds)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        isUserInteractionEnabled = false
        // While a finger is on the bar iOS draws the moving glass from a view it puts in front of the bar's others,
        // this one too (measured on iOS 27); a higher z keeps the badges over it whatever the order.
        layer.zPosition = 100
        accessibilityElementsHidden = true       // VoiceOver reads the bar's own badges
        let watch = TouchWatch(target: nil, action: nil)
        watch.onTouch = { [weak self] down in self?.touched(down) }
        bar.addGestureRecognizer(watch)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview == nil { stopWaiting() }
        refresh()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            refresh()
        }
    }

    /// After the bar's layout and after a count changes. A layout can come with an animation (a tab picked, the bar
    /// coming back), so places are measured now only if the bar is at rest, else once it is.
    func refresh() {
        guard let bar, superview === bar else { return }
        bar.bringSubviewToFront(self)
        if wait == nil, !touching { lookUp() }
        if wait == nil, atRest() { measure() } else { startWaiting() }
        place()
    }

    /// Finds the tabs again.
    private func lookUp() {
        guard let bar else { return }
        bar.layoutIfNeeded()
        let items = bar.items ?? []
        icons = Self.icons(in: bar, besides: self)
        let fits = !items.isEmpty && icons.count == items.count
        if drawing != fits {
            drawing = fits
            onChange?(fits)
        }
    }

    /// No finger on the bar, and every icon unscaled and drawn where its layout puts it.
    private func atRest() -> Bool {
        guard !touching else { return false }
        let here = layer.presentation() ?? layer
        return icons.allSatisfy { tab in
            let laidOut = convert(tab.icon.bounds, from: tab.icon)
            let shown = tab.icon.layer.presentation().map { here.convert($0.bounds, from: $0) } ?? laidOut
            return abs(laidOut.width - tab.icon.bounds.width) < 0.5
                && abs(shown.midX - laidOut.midX) < 0.5 && abs(shown.midY - laidOut.midY) < 0.5
        }
    }

    /// Measures each tab's icon rect and selection pill rect from the bar at rest.
    private func measure() {
        guard !icons.isEmpty else { slots = []; return }
        let iconRects = icons.map { convert($0.icon.bounds, from: $0.icon) }
        let buttonRects = icons.map { convert($0.button.bounds, from: $0.button) }

        // Each tab button in iOS 26/27 sits inside the floating capsule at the selection pill's height (54 pt), while
        // the visible selection pill can be slightly wider than a single slot when 5 tabs crowd a phone bar (measured:
        // ~78 pt pill on 68.5 pt tab centres). Compute each tab's effective pill rect using the wider of its own button
        // rect and the observed selection pill size (or capsule-derived fallback) so clearance holds even if UIKit's
        // button frame is narrower than its drawn selection platter.
        let capsuleRect = measuredCapsule(from: buttonRects)
        let pillWidth = measuredSelectionPillWidth(buttonRects: buttonRects, capsule: capsuleRect)
        let pillRects: [CGRect] = buttonRects.map { button in
            let w = max(button.width, pillWidth)
            return CGRect(x: button.midX - w / 2, y: button.minY, width: w, height: button.height)
        }

        slots = icons.indices.map { index in
            TabBadgeLayout.Slot(
                icon: iconRects[index],
                pill: pillRects[index],
                prevPill: index > 0 ? pillRects[index - 1] : nil,
                nextPill: index + 1 < pillRects.count ? pillRects[index + 1] : nil,
                capsule: capsuleRect
            )
        }
    }

    /// Estimates the outer floating capsule rect from the buttons' union + standard 4 pt inset.
    private func measuredCapsule(from buttonRects: [CGRect]) -> CGRect? {
        guard let first = buttonRects.first, let last = buttonRects.last else { return nil }
        let inset: CGFloat = 4
        let minX = min(first.minX, last.minX) - inset
        let maxX = max(first.maxX, last.maxX) + inset
        let minY = buttonRects.map(\.minY).min()! - inset
        let maxY = buttonRects.map(\.maxY).max()! + inset
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Width of the selection pill across this bar: uses the actual selection view if present in the bar, otherwise
    /// the wider of the measured button width and iOS 26/27's overlapping pill width formula.
    private func measuredSelectionPillWidth(buttonRects: [CGRect], capsule: CGRect?) -> CGFloat {
        let maxButtonWidth = buttonRects.map(\.width).max() ?? 0
        // If iOS's buttons already overlap (width > step), buttonRect.width IS the pill width.
        if buttonRects.count > 1 {
            let step = buttonRects[1].midX - buttonRects[0].midX
            if maxButtonWidth > step + 1 { return maxButtonWidth }
        }
        // Otherwise check if the bar has a selection subview matching a pill's height around one of the buttons.
        if let bar, let buttonHeight = buttonRects.first?.height, buttonHeight > 0 {
            if let selectionWidth = Self.selectionPillWidth(in: bar, besides: self, buttonRects: buttonRects, pillHeight: buttonHeight) {
                return max(maxButtonWidth, selectionWidth)
            }
        }
        // Conservative fallback matching iOS 26/27's measured pill (78 pt on a 360 pt capsule with 5 tabs).
        if let capsule, !buttonRects.isEmpty {
            let room = max(0, capsule.width - 8)
            let estimated = min(DesktopTabBar.Glass.maxButtonWidth, room / CGFloat(buttonRects.count) + 8)
            return max(maxButtonWidth, estimated)
        }
        return maxButtonWidth
    }

    /// Looks for a selection pill subview inside `bar` (same height as a tab button, centred on one of the tabs, wider
    /// than a narrow slot button). Returns nil if UIKit's hierarchy doesn't expose one.
    private static func selectionPillWidth(in bar: UITabBar, besides overlay: UIView, buttonRects: [CGRect], pillHeight: CGFloat) -> CGFloat? {
        var best: CGFloat?
        func walk(_ view: UIView) {
            guard view !== overlay, !view.isHidden, view.alpha > 0.01 else { return }
            if !(view is UIControl) && !(view is UIImageView) && !(view is UILabel) {
                let rect = view.convert(view.bounds, to: bar)
                let heightMatches = abs(rect.height - pillHeight) <= 3
                let reasonableWidth = rect.width >= pillHeight && rect.width <= max(pillHeight * 2.5, (buttonRects.first?.width ?? 0) * 1.6)
                if heightMatches && reasonableWidth && buttonRects.contains(where: { abs($0.midX - rect.midX) <= 3 }) {
                    best = max(best ?? 0, rect.width)
                }
            }
            view.subviews.forEach(walk)
        }
        walk(bar)
        return best
    }

    /// Puts every badge at its tab's measured slot, fitting the current badge string cleanly inside every boundary.
    private func place() {
        let items = bar?.items ?? []
        let values = drawing == true && icons.count == items.count ? items.map(\.badgeValue) : []
        while badges.count < values.count { badges.append(makeBadge()) }
        for (index, badge) in badges.enumerated() {
            guard index < values.count, index < slots.count, let value = values[index], !value.isEmpty else {
                badge.isHidden = true
                continue
            }
            badge.isHidden = false
            badge.text = value
            let height = TabBadgeLayout.badgeHeight
            let width = max(height, ceil(badge.intrinsicContentSize.width) + 8)
            badge.frame = TabBadgeLayout.frame(for: slots[index], badgeSize: CGSize(width: width, height: height))
        }
    }

    private func touched(_ down: Bool) {
        touching = down
        startWaiting()
    }

    private func startWaiting() {
        calm = 0
        guard wait == nil, window != nil, bar?.isHidden == false else { return }
        // motion-ok: moves nothing; it only notices when iOS's own bar animation has finished
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        wait = link
        waitStart = CACurrentMediaTime()
    }

    private func stopWaiting() {
        wait?.invalidate()
        wait = nil
    }

    /// At rest for a few frames in a row (or, with no finger down, after 3 s whatever is still moving, such as the
    /// Jobs ring): find the tabs afresh (the picked tab or the order may have changed) and measure.
    @objc private func step(_ link: CADisplayLink) {
        if touching { waitStart = link.timestamp; calm = 0; return }
        calm = atRest() ? calm + 1 : 0
        guard calm >= 3 || link.timestamp - waitStart > 3 else { return }
        stopWaiting()
        lookUp()
        measure()
        place()
    }

    private func makeBadge() -> UILabel {
        let badge = UILabel()
        badge.font = .systemFont(ofSize: 12, weight: .semibold)   // a11y-font-ok: iOS's tab bar badge keeps a fixed compact size
        badge.textColor = .white
        badge.textAlignment = .center
        badge.backgroundColor = .systemRed
        badge.layer.cornerRadius = TabBadgeLayout.badgeHeight / 2
        badge.layer.cornerCurve = .continuous
        badge.clipsToBounds = true
        addSubview(badge)
        return badge
    }

    /// The bar's tab buttons left to right, each with its icon. The bar keeps two copies of each button (one for the
    /// selected look under the glass); one per place is kept.
    private static func icons(in bar: UITabBar, besides overlay: UIView) -> [(button: UIView, icon: UIView)] {
        var found: [(button: UIView, icon: UIView, x: CGFloat)] = []
        func walk(_ view: UIView) {
            guard view !== overlay, !view.isHidden else { return }
            if view is UIControl, let image = view.subviews.first(where: { $0 is UIImageView && !$0.isHidden }) {
                let x = view.convert(view.bounds, to: bar).midX
                if !found.contains(where: { abs($0.x - x) < 1 }) { found.append((view, image, x)) }
                return
            }
            view.subviews.forEach(walk)
        }
        walk(bar)
        return found.sorted { $0.x < $1.x }.map { ($0.button, $0.icon) }
    }
}

/// Tells the overlay when a finger is on the bar. It never recognizes, so the bar's own touches go on as before.
private final class TouchWatch: UIGestureRecognizer {
    var onTouch: ((Bool) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch?(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lifted(event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lifted(event) }

    private func lifted(_ event: UIEvent) {
        let left = event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? []
        guard left.isEmpty else { return }
        onTouch?(false)
        state = .failed
    }
}
