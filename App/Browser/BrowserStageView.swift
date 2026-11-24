import UIKit

// The live page and its touches (port of the web app's trackpad.ts): the page is drawn to fit, two fingers pinch to zoom
// and pan it. Holding the browser, the screen is a trackpad: one finger moves a drawn pointer from where it is, a tap
// clicks there, a still hold (or a quick double-tap and drag) presses and drags, two fingers scroll with a fling.
// Watching, one finger pans a zoomed page, a double tap zooms in or back out, and a single tap says how to take control.
// Frames arrive decoded; the stage only sets its layer's contents.
//
// A mouse or a trackpad's pointer (the Mac; an iPad's) points for itself: the page's pointer is under the cursor, a
// click clicks there and pressing then moving drags at once (`BrowserOneFinger.Kind.direct`). What a finger and a
// pointer send is decided in `BrowserOneFinger` (HermesKit), which the tests drive without touches.

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
    private let dragRing = UIView()
    private let clickRing = UIView()
    /// The page's CSS size the frames show (nil before the first).
    private(set) var pageSize: CGSize?
    private(set) var drawn = M.View()
    private var pointer = CGPoint(x: 0.5, y: 0.5)
    private(set) var hasFrame = false

    // Gesture state
    private struct One { var touch: UITouch?; var start: CGPoint; var last: CGPoint; var press: BrowserOneFinger
                         var moved: Bool { press.moved } }
    private struct Two { var mid: CGPoint; var distance: CGFloat; var time: TimeInterval; var vx: CGFloat = 0; var vy: CGFloat = 0
                         var mode: Mode = .undecided; var base: M.View
                         enum Mode { case undecided, zoom, scroll } }
    private var one: One?
    private var two: Two?
    private var holdTimer: Timer?
    private var tapTimer: Timer?
    private var lastTap: TimeInterval = 0
    /// The last trackpad click while holding control: a quick second touch near it arms double-tap-and-drag.
    private var lastControlTap: (time: TimeInterval, point: CGPoint)?
    /// The last thing that pointed was a mouse or a trackpad's pointer: its own cursor shows where, so the drawn one hides.
    private var pointing = DeviceWord.isMac { didSet { if pointing != oldValue { showCursorIfWanted() } } }
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
        cursor.bounds = CGRect(x: 0, y: 0, width: 22, height: 26)
        // Anchor at the arrow tip so scaling for a press keeps the tip pinned to the pointer and `center` stays legal
        // under a non-identity transform.
        cursor.layer.anchorPoint = CGPoint(x: 2.0 / 22.0, y: 2.0 / 26.0)
        cursor.layer.shadowColor = UIColor.black.cgColor
        cursor.layer.shadowOpacity = 0.35
        cursor.layer.shadowRadius = 2
        cursor.layer.shadowOffset = CGSize(width: 0, height: 1)
        cursor.isHidden = true
        cursor.isUserInteractionEnabled = false
        dragRing.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        dragRing.layer.cornerRadius = 14
        dragRing.layer.borderWidth = 2
        dragRing.alpha = 0
        dragRing.isHidden = true
        dragRing.isUserInteractionEnabled = false
        styleDragRing()
        clickRing.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        clickRing.layer.cornerRadius = 14
        clickRing.backgroundColor = tintColor
        clickRing.alpha = 0
        clickRing.isUserInteractionEnabled = false
        addSubview(dragRing)
        addSubview(clickRing)
        addSubview(cursor)
        isAccessibilityElement = true
        accessibilityTraits = [.image, .allowsDirectInteraction]
        accessibilityIdentifier = "browser.stage"
        #if targetEnvironment(macCatalyst)
        wheels.forEach(addGestureRecognizer)
        #endif
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (stage: BrowserStageView, _) in stage.styleDragRing() }
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        styleDragRing()
    }

    private func styleDragRing() {
        dragRing.backgroundColor = tintColor.withAlphaComponent(0.22)
        dragRing.layer.borderColor = tintColor.cgColor
    }

    /// A mouse or a trackpad's pointer moving over the page with no button down: the page's pointer follows it, so the
    /// page shows what is under the cursor (a menu that opens on hover, a link's underline) and a click lands there.
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed, one == nil, two == nil else { return }
        pointing = true
        guard control, let now = M.clamped(recognizer.location(in: self), in: drawn), now != pointer else { return }
        pointer = now
        placeCursor()
        pendingMove = true
        schedule()
    }

    /// A touch from a mouse or a trackpad's pointer (always, on the Mac).
    private static func points(_ touch: UITouch) -> Bool { DeviceWord.isMac || touch.type == .indirectPointer }

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
    var showsCursor = false {
        didSet {
            showCursorIfWanted()
            placeCursor()
            if !showsCursor { dropLocalPress() }
        }
    }

    private func showCursorIfWanted() {
        let hidden = !showsCursor || !hasFrame || pointing
        cursor.isHidden = hidden
        dragRing.isHidden = hidden
    }

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
        if first { showCursorIfWanted() }
    }

    func clear() {
        pageLayer.contents = nil
        hasFrame = false
        pageSize = nil
        cursor.isHidden = true
        dragRing.isHidden = true
        dropLocalPress()
    }

    private func dropLocalPress() {
        holdTimer?.invalidate(); holdTimer = nil
        lastControlTap = nil
        if !control { one = nil }
        setPressed(false)
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

    private var pointerPoint: CGPoint {
        let size = drawn.drawnSize
        return CGPoint(x: drawn.x + pointer.x * size.width, y: drawn.y + pointer.y * size.height)
    }

    private func placeCursor() {
        let tip = pointerPoint
        cursor.center = tip
        dragRing.center = tip
    }

    private func flashClick() {
        guard !HQMotion.reduced else { return }
        clickRing.center = pointerPoint
        clickRing.backgroundColor = tintColor
        clickRing.alpha = 0.45
        clickRing.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        UIView.animate(withDuration: HQMotion.move, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.clickRing.alpha = 0
            self.clickRing.transform = .identity
        }
    }

    /// The drawn pointer looks pressed (a little smaller, with a grab ring around the tip) or not. Only a look:
    /// `BrowserOneFinger` knows whether the page's button is down.
    private func setPressed(_ on: Bool) {
        let cursorTo: CGAffineTransform = on ? CGAffineTransform(scaleX: 0.85, y: 0.85) : .identity
        if on {
            dragRing.center = pointerPoint
            if dragRing.alpha == 0, !HQMotion.reduced {
                dragRing.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
            }
        }
        HQMotion.animate(HQMotion.quick, changes: {
            self.cursor.transform = cursorTo
            self.dragRing.alpha = on ? 1 : 0
            self.dragRing.transform = on ? .identity : CGAffineTransform(scaleX: 0.7, y: 0.7)
        }, reduced: {
            self.cursor.transform = .identity
            self.dragRing.alpha = on ? 1 : 0
            self.dragRing.transform = .identity
        })
    }

    #if DEBUG
    var debugCursorCenter: CGPoint { cursor.center }
    var debugDragRingVisible: Bool { dragRing.alpha > 0.5 && !dragRing.isHidden }
    func debugTouchBegan(at point: CGPoint, points: Bool = false, now: TimeInterval) {
        singleBegan(touch: nil, at: point, points: points, now: now)
    }
    func debugHoldFired() { singleHoldFired() }
    func debugTouchMoved(to point: CGPoint) { singleMoved(to: point) }
    func debugTouchEnded(now: TimeInterval) { singleEnded(now: now) }
    func debugTouchCancelled() { singleCancelled() }
    func debugFlush() { flush() }
    #endif

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

    /// What `BrowserOneFinger` decided, sent: the pointer's look, haptic cue, the page's button, a click.
    private func run(_ outs: [BrowserOneFinger.Out]) {
        for out in outs {
            switch out {
            case .look(let on): setPressed(on)
            case .haptic: Haptics.play(.selection)
            case .down: host?.stageSend(.down(x: at.x, y: at.y))
            case .up: host?.stageSend(.up(x: at.x, y: at.y))
            case .tap:
                host?.stageWillTap()
                host?.stageSend(.tap(x: at.x, y: at.y))
                flashClick()
            }
        }
    }

    /// The finger is taken away without a click (a second finger, a cancelled touch): a held button is let go.
    private func lift() {
        guard var held = one else { return }
        if link != nil, held.press.buttonDown { flush() }   // the pointer's last place first, then the button comes up there
        run(held.press.cancelled())
        one = held
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
            lastControlTap = nil
            if control { lift() }
            one = nil
            let (mid, distance) = midpoint(Array(active.prefix(2)))
            two = Two(mid: mid, distance: distance, time: event?.timestamp ?? 0, base: drawn)
            return
        }
        guard let touch = touches.first else { return }
        singleBegan(touch: touch, at: touch.location(in: self), points: Self.points(touch), now: CACurrentMediaTime())
    }

    private func singleBegan(touch: UITouch?, at point: CGPoint, points: Bool, now: TimeInterval) {
        holdTimer?.invalidate(); holdTimer = nil
        pointing = points
        let armed = control && !points && M.isDoubleTapDrag(previous: lastControlTap, at: point, now: now)
        lastControlTap = nil
        one = One(touch: touch, start: point, last: point, press: BrowserOneFinger(kind: points ? .direct : .trackpad, armed: armed))
        guard control else { return }
        if points {
            // The page's pointer goes under the cursor before anything else: a click or a press lands where it is.
            if let now = M.clamped(point, in: drawn), now != pointer {
                pointer = now
                placeCursor()
                pendingMove = true
                schedule()
            }
        }
        holdTimer = Timer.scheduledTimer(withTimeInterval: M.holdSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.singleHoldFired() }
        }
    }

    private func singleHoldFired() {
        holdTimer?.invalidate(); holdTimer = nil
        guard control, var held = one else { return }
        // Rebase `last` to the finger's live location so tiny wobble within `tapSlop` before the hold doesn't jump
        // the pointer on the first drag sample.
        if let touch = held.touch { held.last = touch.location(in: self) }
        let outs = held.press.held()
        one = held
        guard !outs.isEmpty else { return }
        if link != nil { flush() }
        run(outs)
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
        guard active.count == 1, let touch = active.first else { return }
        singleMoved(to: touch.location(in: self))
    }

    private func singleMoved(to now: CGPoint) {
        guard var o = one else { return }
        let slop = o.press.kind == .direct ? M.directDragSlop : M.tapSlop
        if !o.moved && !o.press.buttonDown && hypot(now.x - o.start.x, now.y - o.start.y) < slop {
            o.last = now
            one = o
            return
        }
        let dx = now.x - o.last.x, dy = now.y - o.last.y
        o.last = now
        if !o.moved {
            holdTimer?.invalidate(); holdTimer = nil
            let outs = o.press.travelled()
            if control {
                if link != nil, outs.contains(.down) { flush() }   // the page's pointer is in place before its button goes down
                run(outs)
            }
        }
        one = o
        guard control else { pan(dx, dy); return }       // watching: a finger moves a zoomed view
        if o.press.kind == .direct {
            pointer = M.clamped(now, in: drawn) ?? pointer
        } else {
            pointer = M.move(pointer, dx: dx, dy: dy, drawn: drawn.drawnSize)
        }
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
        guard remaining.isEmpty else { return }
        singleEnded(now: CACurrentMediaTime())
    }

    private func singleEnded(now: TimeInterval) {
        guard var o = one else { return }
        holdTimer?.invalidate(); holdTimer = nil
        let tapped = !o.moved
        if !control {
            reset()
            guard tapped else { return }
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
        let outs = o.press.lifted()
        run(outs)
        if o.press.kind == .trackpad, outs.contains(.tap) {
            lastControlTap = (now, o.start)
        } else {
            lastControlTap = nil
        }
        reset()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        singleCancelled()
    }

    private func singleCancelled() {
        stopFling()
        link?.invalidate(); link = nil
        pendingMove = false
        scroll = .zero
        lastControlTap = nil
        if control { lift() } else { setPressed(false) }
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
