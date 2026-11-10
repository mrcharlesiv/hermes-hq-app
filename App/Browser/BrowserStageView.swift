import UIKit

// The live page and its touches (port of the web app's trackpad.ts): the page is drawn to fit, two fingers pinch to zoom
// and pan it. Holding the browser, the screen is a trackpad: one finger moves a drawn pointer from where it is, a tap
// clicks there, a still hold then a drag presses and drags, two fingers scroll with a fling. Watching, one finger pans a
// zoomed page, a double tap zooms in or back out, and a single tap says how to take control. Frames arrive decoded; the
// stage only sets its layer's contents.

@MainActor protocol BrowserStageHost: AnyObject {
    /// This phone holds the browser.
    var stageHasControl: Bool { get }
    /// One input message (the session adds the claim epoch).
    func stageSend(_ input: BrowserInput)
    /// A tap is about to click (holding): the field under the pointer may raise the keyboard in the same touch.
    func stageWillTap()
    /// A zoom settled at this level (frames can be sized for it).
    func stageZoomed()
    /// A single tap while only watching.
    func stageWatchTap()
}

final class BrowserStageView: UIView {
    typealias M = BrowserTrackpadMath
    weak var host: BrowserStageHost?

    private let pageLayer = CALayer()
    private let cursor = UIImageView()
    private let clickRing = UIView()
    /// The page's CSS size the frames show (nil before the first).
    private(set) var pageSize: CGSize?
    private(set) var drawn = M.View()
    private var pointer = CGPoint(x: 0.5, y: 0.5)
    private(set) var hasFrame = false

    // Gesture state
    private struct One { var touch: UITouch; var start: CGPoint; var last: CGPoint; var moved = false; var armed = false }
    private struct Two { var mid: CGPoint; var distance: CGFloat; var time: TimeInterval; var vx: CGFloat = 0; var vy: CGFloat = 0
                         var mode: Mode = .undecided; var base: M.View
                         enum Mode { case undecided, zoom, scroll } }
    private var one: One?
    private var two: Two?
    private var holdTimer: Timer?
    private var tapTimer: Timer?
    private var lastTap: TimeInterval = 0
    private var pressed = false
    private var pendingMove = false
    private var scroll = CGVector.zero
    private var link: CADisplayLink?
    private var fling: CADisplayLink?
    private var flingVelocity = CGVector.zero
    private var flingLast: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = true
        backgroundColor = .secondarySystemBackground
        pageLayer.contentsGravity = .resize
        pageLayer.isOpaque = true
        pageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        layer.addSublayer(pageLayer)
        cursor.image = Self.cursorImage
        cursor.frame = CGRect(x: 0, y: 0, width: 22, height: 26)
        cursor.layer.shadowColor = UIColor.black.cgColor
        cursor.layer.shadowOpacity = 0.35
        cursor.layer.shadowRadius = 2
        cursor.layer.shadowOffset = CGSize(width: 0, height: 1)
        cursor.isHidden = true
        cursor.isUserInteractionEnabled = false
        clickRing.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        clickRing.layer.cornerRadius = 14
        clickRing.backgroundColor = tintColor
        clickRing.alpha = 0
        clickRing.isUserInteractionEnabled = false
        addSubview(clickRing)
        addSubview(cursor)
        isAccessibilityElement = true
        accessibilityTraits = [.image, .allowsDirectInteraction]
        accessibilityIdentifier = "browser.stage"
        #if targetEnvironment(macCatalyst)
        wheels.forEach(addGestureRecognizer)
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] A trackpad's two-finger scroll or a mouse wheel brings no touches, only these recognizers. They do what two
    /// fingers do: a zoomed view pans first, and holding the browser, the rest scrolls the page. A mouse's wheel
    /// scrolls the page 40 pixels a line (10 points here), as a browser does (by travel a line moved a few pixels).
    private lazy var wheels: [UIPanGestureRecognizer] = [UIScrollTypeMask.continuous, .discrete].map { types in
        let pan = UIPanGestureRecognizer(target: self, action: #selector(wheeled(_:)))
        pan.allowedScrollTypesMask = types
        pan.allowedTouchTypes = []   // scrolls only: a click and a drag stay the trackpad's
        return pan
    }
    private var wheelLast = CGPoint.zero
    private static let pixelsPerWheelPoint: CGFloat = 4

    @objc private func wheeled(_ recognizer: UIPanGestureRecognizer) {
        let now = recognizer.translation(in: self)
        if recognizer.state == .began { wheelLast = .zero; stopFling() }
        let dx = now.x - wheelLast.x, dy = now.y - wheelLast.y
        wheelLast = now
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        if control, recognizer.allowedScrollTypesMask == .discrete {
            // Content moving up scrolls the page down, as in `scrollDelta`.
            scroll.dx -= dx * Self.pixelsPerWheelPoint
            scroll.dy -= dy * Self.pixelsPerWheelPoint
            schedule()
            return
        }
        let left = pan(dx, dy)
        guard control else { return }
        let delta = M.scrollDelta(dx: left.dx, dy: left.dy, drawn: drawn.drawnSize, page: pageSize)
        scroll.dx += delta.dx
        scroll.dy += delta.dy
        schedule()
    }
    #endif

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        link?.invalidate()
        fling?.invalidate()
        holdTimer?.invalidate()
        tapTimer?.invalidate()
    }

    /// Audit 09-2: the page hides while the app isn't in front, so the app switcher never shows it (as the Screen's
    /// picture does, spec 3x-screen D17).
    var covered = false { didSet { pageLayer.isHidden = covered } }

    /// The pointer drawn (only while this phone holds the browser and a page shows).
    var showsCursor = false { didSet { cursor.isHidden = !showsCursor || !hasFrame; placeCursor() } }

    func show(_ image: CGImage, pageSize size: CGSize) {
        let first = !hasFrame
        hasFrame = true
        pageLayer.contents = image
        if pageSize != size {
            pageSize = size
            relayout()
        } else if first {
            relayout()
        }
        if first { cursor.isHidden = !showsCursor }
    }

    func clear() {
        pageLayer.contents = nil
        hasFrame = false
        pageSize = nil
        cursor.isHidden = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        relayout()
    }

    /// Fit again (the stage or the page changed size), keeping the zoom where it can.
    func relayout() {
        apply(M.place(stage: bounds.size, page: pageSize, zoom: drawn.zoom, x: drawn.x, y: drawn.y))
    }

    /// Back to the whole page.
    func fit() {
        apply(M.place(stage: bounds.size, page: pageSize, zoom: 1, x: 0, y: 0))
        host?.stageZoomed()
    }

    private func apply(_ view: M.View) {
        drawn = view
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.frame = view.frame
        CATransaction.commit()
        placeCursor()
    }

    private func placeCursor() {
        let size = drawn.drawnSize
        cursor.frame.origin = CGPoint(x: drawn.x + pointer.x * size.width - 2, y: drawn.y + pointer.y * size.height - 2)
    }

    private func flashClick() {
        guard !HQMotion.reduced else { return }
        clickRing.center = CGPoint(x: cursor.frame.minX + 2, y: cursor.frame.minY + 2)
        clickRing.backgroundColor = tintColor
        clickRing.alpha = 0.45
        clickRing.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.clickRing.alpha = 0
            self.clickRing.transform = .identity
        }
    }

    private func setPressed(_ on: Bool) {
        pressed = on
        let to: CGAffineTransform = on ? CGAffineTransform(scaleX: 0.85, y: 0.85) : .identity
        HQMotion.animate(0.12, changes: { self.cursor.transform = to })
    }

    private var control: Bool { host?.stageHasControl ?? false }
    private var at: (x: Double, y: Double) { (Double(pointer.x), Double(pointer.y)) }

    // MARK: Batched sends (one per display frame)

    private func schedule() {
        guard link == nil else { return }
        let link = CADisplayLink(target: DisplayTarget { [weak self] in self?.flush() }, selector: #selector(DisplayTarget.tick))   // motion-ok: batches pointer events per frame; nothing on screen moves by itself
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func flush() {
        link?.invalidate(); link = nil
        if pendingMove { pendingMove = false; host?.stageSend(.move(x: at.x, y: at.y)) }
        if scroll.dx != 0 || scroll.dy != 0 {
            host?.stageSend(.scroll(x: at.x, y: at.y, dx: Int(scroll.dx.rounded()), dy: Int(scroll.dy.rounded())))
            scroll = .zero
        }
    }

    private func stopFling() { fling?.invalidate(); fling = nil }

    private func lift() {
        guard pressed else { return }
        setPressed(false)
        host?.stageSend(.up(x: at.x, y: at.y))
    }

    private func reset() { holdTimer?.invalidate(); holdTimer = nil; one = nil; two = nil }

    /// Pans a zoomed view; returns the travel it couldn't take (it hit an edge).
    @discardableResult private func pan(_ dx: CGFloat, _ dy: CGFloat) -> CGVector {
        let next = M.place(stage: bounds.size, page: pageSize, zoom: drawn.zoom, x: drawn.x + dx, y: drawn.y + dy)
        let left = CGVector(dx: dx - (next.x - drawn.x), dy: dy - (next.y - drawn.y))
        if next.x != drawn.x || next.y != drawn.y { apply(next) }
        return left
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopFling()
        let all = event?.touches(for: self) ?? touches
        let active = all.filter { $0.phase != .ended && $0.phase != .cancelled }
        if active.count >= 2 {
            holdTimer?.invalidate()
            if control { lift() }
            one = nil
            let (mid, distance) = midpoint(Array(active.prefix(2)))
            two = Two(mid: mid, distance: distance, time: event?.timestamp ?? 0, base: drawn)
            return
        }
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        one = One(touch: touch, start: point, last: point)
        guard control else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: M.holdSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, var held = self.one, !held.moved else { return }
                held.armed = true
                self.one = held
                self.setPressed(true)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = (event?.touches(for: self) ?? touches).filter { $0.phase != .ended && $0.phase != .cancelled }
        if var t = two, active.count >= 2 {
            let (mid, distance) = midpoint(Array(active.prefix(2)))
            let factor = distance / t.distance
            if t.mode == .undecided {
                if abs(factor - 1) > M.pinchStart { t.mode = .zoom }
                else if hypot(mid.x - t.mid.x, mid.y - t.mid.y) > M.tapSlop { t.mode = control ? .scroll : .zoom }
                else { two = t; return }
            }
            if t.mode == .zoom {
                let zoomed = M.zoom(t.base, by: factor, about: t.mid, stage: bounds.size, page: pageSize)
                apply(M.place(stage: bounds.size, page: pageSize, zoom: zoomed.zoom, x: zoomed.x + mid.x - t.mid.x, y: zoomed.y + mid.y - t.mid.y))
                two = t
                return
            }
            let now = event?.timestamp ?? t.time
            let dt = max(0.001, now - t.time) * 1000
            let left = pan(mid.x - t.mid.x, mid.y - t.mid.y)   // a zoomed view pans first; the rest scrolls the page
            let delta = M.scrollDelta(dx: left.dx, dy: left.dy, drawn: drawn.drawnSize, page: pageSize)
            scroll.dx += delta.dx
            scroll.dy += delta.dy
            t.mid = mid; t.time = now; t.vx = delta.dx / dt; t.vy = delta.dy / dt
            two = t
            schedule()
            return
        }
        guard var o = one, active.count == 1, let touch = active.first else { return }
        let now = touch.location(in: self)
        if !o.moved && hypot(now.x - o.start.x, now.y - o.start.y) < M.tapSlop { return }
        let dx = now.x - o.last.x, dy = now.y - o.last.y
        o.last = now
        if !o.moved {
            o.moved = true
            holdTimer?.invalidate()
            if control && o.armed && !pressed { pressed = true; host?.stageSend(.down(x: at.x, y: at.y)) }
        }
        one = o
        guard control else { pan(dx, dy); return }       // watching: a finger moves a zoomed view
        pointer = M.move(pointer, dx: dx, dy: dy, drawn: drawn.drawnSize)
        let follow = M.follow(pointer: pointer, view: drawn, stage: bounds.size)
        if follow.dx != 0 || follow.dy != 0 { pan(follow.dx, follow.dy) }
        placeCursor()
        pendingMove = true
        schedule()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let remaining = (event?.touches(for: self) ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
        if let t = two {
            if remaining.count < 2 {
                if t.mode == .zoom { host?.stageZoomed() }
                else if t.mode == .scroll, hypot(t.vx, t.vy) > M.flingStop { startFling(CGVector(dx: t.vx, dy: t.vy)) }
                two = nil
            }
            if remaining.isEmpty { reset() }
            return
        }
        guard let o = one, remaining.isEmpty else { return }
        holdTimer?.invalidate()
        let tapped = !o.moved
        if !control {
            reset()
            guard tapped else { return }
            let now = CACurrentMediaTime()
            if now - lastTap < M.doubleTapSeconds {        // double tap: zoom in about the finger, or back to the whole page
                lastTap = 0
                tapTimer?.invalidate()
                apply(drawn.zoom > 1.05 ? M.place(stage: bounds.size, page: pageSize, zoom: 1, x: 0, y: 0)
                                        : M.zoom(drawn, by: M.doubleTapZoom, about: o.start, stage: bounds.size, page: pageSize))
                host?.stageZoomed()
                return
            }
            lastTap = now
            if M.fraction(o.start, in: drawn) != nil {
                tapTimer = Timer.scheduledTimer(withTimeInterval: M.doubleTapSeconds, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.host?.stageWatchTap() }
                }
            }
            return
        }
        if link != nil { flush() }
        if pressed { lift() }
        else if tapped {
            host?.stageWillTap()
            host?.stageSend(.tap(x: at.x, y: at.y))
            flashClick()
        }
        reset()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopFling()
        link?.invalidate(); link = nil
        pendingMove = false
        scroll = .zero
        if control { lift() }
        reset()
    }

    private func startFling(_ velocity: CGVector) {
        flingVelocity = velocity
        flingLast = CACurrentMediaTime()
        let link = CADisplayLink(target: DisplayTarget { [weak self] in self?.flingStep() }, selector: #selector(DisplayTarget.tick))   // motion-ok: scroll momentum from the user's own flick, as a system scroll view keeps
        link.add(to: .main, forMode: .common)
        fling = link
    }

    private func flingStep() {
        let now = CACurrentMediaTime()
        let dt = min(48, (now - flingLast) * 1000)
        flingLast = now
        scroll.dx += flingVelocity.dx * dt
        scroll.dy += flingVelocity.dy * dt
        flingVelocity.dx *= M.flingDecay
        flingVelocity.dy *= M.flingDecay
        flush()
        if hypot(flingVelocity.dx, flingVelocity.dy) <= M.flingStop / 4 { stopFling() }
    }

    private func midpoint(_ touches: [UITouch]) -> (CGPoint, CGFloat) {
        let a = touches[0].location(in: self), b = touches[1].location(in: self)
        return (CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), max(1, hypot(a.x - b.x, a.y - b.y)))
    }

    /// The pointer: white arrow, black outline (the screencast has no cursor of its own).
    static let cursorImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 22, height: 26)).image { context in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 2, y: 1.5))
            path.addLine(to: CGPoint(x: 2, y: 20.7))
            path.addLine(to: CGPoint(x: 7, y: 16.1))
            path.addLine(to: CGPoint(x: 10.4, y: 23.7))
            path.addLine(to: CGPoint(x: 13.7, y: 22.2))
            path.addLine(to: CGPoint(x: 10.3, y: 14.8))
            path.addLine(to: CGPoint(x: 17.1, y: 14.4))
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = 1.6
            UIColor.white.setFill()
            UIColor.black.setStroke()
            path.fill()
            path.stroke()
        }
    }()
}

/// A display link target that doesn't keep its owner alive.
final class DisplayTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func tick() { action() }
}
