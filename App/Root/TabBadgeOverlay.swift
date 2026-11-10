import UIKit
import UIKit.UIGestureRecognizerSubclass

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
    /// From iOS's place on the icon's top-right: 3 pt in and 4 pt down keeps one or two digits inside the selected
    /// tab's grey pill (owner on 492). The bar's own badges take the same offset, for when they show.
    static let shift = UIOffset(horizontal: 3, vertical: 4)

    /// Whether the overlay draws the badges, each time that changes.
    var onChange: ((Bool) -> Void)?

    private weak var bar: UITabBar?
    private var badges: [UILabel] = []
    private var drawing: Bool?
    /// Each tab's button and icon, left to right, as found with no finger on the bar.
    private var icons: [(button: UIView, icon: UIView)] = []
    /// Each tab's badge origin, measured with the bar at rest.
    private var spots: [CGPoint] = []
    /// Runs while the bar is pressed or settling, to measure again once it is at rest.
    private var wait: CADisplayLink?
    private var waitStart: CFTimeInterval = 0
    private var calm = 0
    private var touching = false

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

    /// Each badge's origin from its icon's layout. iOS's place is 5 pt in from the icon's right edge and 2 pt below
    /// the button's top.
    private func measure() {
        spots = icons.map { tab in
            let icon = convert(tab.icon.bounds, from: tab.icon)
            let top = convert(tab.button.bounds, from: tab.button).minY
            return CGPoint(x: icon.maxX - 5 - Self.shift.horizontal, y: top + 2 + Self.shift.vertical)
        }
    }

    /// Puts every badge at its tab's measured place, with its count.
    private func place() {
        let items = bar?.items ?? []
        let values = drawing == true && icons.count == items.count ? items.map(\.badgeValue) : []
        while badges.count < values.count { badges.append(makeBadge()) }
        for (index, badge) in badges.enumerated() {
            guard index < values.count, index < spots.count, let value = values[index], !value.isEmpty else {
                badge.isHidden = true
                continue
            }
            badge.isHidden = false
            badge.text = value
            let height: CGFloat = 19.67
            let width = max(height, ceil(badge.intrinsicContentSize.width) + 8)
            badge.frame = CGRect(origin: spots[index], size: CGSize(width: width, height: height))
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
        badge.font = .systemFont(ofSize: 13)   // a11y-font-ok: iOS's own tab bar badge, which keeps its size too
        badge.textColor = .white
        badge.textAlignment = .center
        badge.backgroundColor = .systemRed
        badge.layer.cornerRadius = 19.67 / 2
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
