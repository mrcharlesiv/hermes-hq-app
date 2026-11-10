import UIKit

/// The picture of the bot's screen and the touches on it (docs/spec/3x-screen.md §5.5). Watching: pinch, pan and
/// double tap shape the local view. In control the picture is a relative trackpad: the rules live in `ScreenGesture`
/// (pure, unit-tested); this view feeds it touches and turns its actions into pointer messages.
final class ScreenStageView: UIView {
    /// `PointerEvent(mask, x, y)` for the bot's screen.
    var onPointer: ((UInt8, Int, Int) -> Void)?
    /// The local view changed (`committed` false while fingers still shape it).
    var onView: ((ScreenView, Bool) -> Void)?
    var onHoldArmed: (() -> Void)?
    /// A touch began (the person is using the picture).
    var onTouch: (() -> Void)?

    private let pictureLayer = CALayer()
    private let dimLayer = CALayer()
    private let ring = CAShapeLayer()
    private var gesture = ScreenGesture()
    private var framebuffer: (width: Int, height: Int) = (0, 0)
    private var held: UInt8 = 0
    private var holdTimer: Timer?
    private var moveLink: CADisplayLink?
    private var movePending = false
    private var active: [UITouch] = []

    /// This phone holds the lease and the stream is live: touches drive the pointer.
    var control = false {
        didSet {
            guard control != oldValue else { return }
            if control { gesture.resetPointer() } else { dropTouches() }
            refreshAccessibility()
        }
    }

    var botName = "" { didSet { refreshAccessibility() } }
    var screenLabel = "" { didSet { refreshAccessibility() } }
    /// The picture is dimmed while a stream is being attached over it.
    var dimmed = false { didSet { dimLayer.isHidden = !dimmed } }
    /// The picture is hidden (the app switcher must not show another computer's screen, DECISION D17).
    var covered = false { didSet { pictureLayer.isHidden = covered } }

    var view: ScreenView { gesture.view }
    var tappedRow: CGFloat? { gesture.tapped?.fy }
    var hasPicture: Bool { pictureLayer.contents != nil }
    var aspect: CGFloat { framebuffer.height > 0 ? CGFloat(framebuffer.width) / CGFloat(framebuffer.height) : 16.0 / 10.0 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        clipsToBounds = true
        pictureLayer.contentsGravity = .resize
        pictureLayer.minificationFilter = .trilinear
        pictureLayer.magnificationFilter = .linear
        pictureLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(pictureLayer)
        dimLayer.backgroundColor = UIColor.black.withAlphaComponent(0.4).cgColor
        dimLayer.isHidden = true
        dimLayer.actions = ["hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(dimLayer)
        ring.fillColor = UIColor.white.cgColor
        ring.strokeColor = UIColor.black.withAlphaComponent(0.6).cgColor
        ring.lineWidth = 1
        ring.path = UIBezierPath(ovalIn: CGRect(x: -7, y: -7, width: 14, height: 14)).cgPath
        ring.opacity = 0
        ring.actions = ["position": NSNull()]
        layer.addSublayer(ring)
        isAccessibilityElement = true
        accessibilityIdentifier = "screen.stage"
        refreshAccessibility()
        #if targetEnvironment(macCatalyst)
        wheels.forEach(addGestureRecognizer)
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] A trackpad's two-finger scroll or a mouse wheel brings no touches, only these recognizers. In control they
    /// turn the wheel on the bot's screen: a trackpad one step per `wheelTravel` points, as two fingers do on the
    /// iPhone; a mouse one step per line it turns (`wheelLine` points each), as any remote-screen app does (by travel
    /// it took two or three notches).
    private lazy var wheels: [UIPanGestureRecognizer] = [UIScrollTypeMask.continuous, .discrete].map { types in
        let pan = UIPanGestureRecognizer(target: self, action: #selector(wheeled(_:)))
        pan.allowedScrollTypesMask = types
        pan.allowedTouchTypes = []   // scrolls only: a click and a drag stay the trackpad's
        return pan
    }
    private var wheelLast: CGFloat = 0
    private var wheelScrolled: CGFloat = 0
    private static let wheelLine: CGFloat = 10

    @objc private func wheeled(_ pan: UIPanGestureRecognizer) {
        let y = pan.translation(in: self).y
        if pan.state == .began { wheelLast = 0; wheelScrolled = 0; onTouch?() }
        let moved = wheelLast - y   // content moving up turns the wheel down, as fingers moving up do
        wheelLast = y
        // ⌘-scroll zooms about the pointer, watching or in control (round 2 #37: a mouse has no pinch); a plain scroll
        // stays the bot's wheel.
        if pan.modifierFlags.contains(.command) {
            guard framebuffer.width > 0 else { return }
            if pan.state == .began || pan.state == .changed, moved != 0 {
                let factor = ZoomStep.scrollFactor(-moved, discrete: pan.allowedScrollTypesMask == .discrete)
                setView(ScreenViewMath.zoomAbout(gesture.view, factor: factor, at: pan.location(in: self),
                                                 width: bounds.width, height: bounds.height), animated: false)
                onView?(gesture.view, false)
            } else if pan.state == .ended || pan.state == .cancelled {
                onView?(gesture.view, true)
            }
            return
        }
        guard control, framebuffer.width > 0, pan.state == .began || pan.state == .changed, moved != 0 else { return }
        if pan.allowedScrollTypesMask == .discrete {
            let lines = max(1, Int((abs(moved) / Self.wheelLine).rounded()))
            apply(Array(repeating: .wheel(down: moved > 0), count: lines))
            return
        }
        wheelScrolled += moved
        var steps: [ScreenGesture.Action] = []
        while abs(wheelScrolled) >= ScreenViewMath.wheelTravel {
            let down = wheelScrolled > 0
            steps.append(.wheel(down: down))
            wheelScrolled -= (down ? 1 : -1) * ScreenViewMath.wheelTravel
        }
        apply(steps)
    }
    #endif

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        holdTimer?.invalidate()
        moveLink?.invalidate()
    }

    private var context: ScreenGesture.Context {
        ScreenGesture.Context(control: control, stage: bounds.size, aspect: aspect, framebuffer: framebuffer)
    }

    // MARK: Picture

    func show(_ image: CGImage, width: Int, height: Int) {
        let resized = width != framebuffer.width || height != framebuffer.height
        framebuffer = (width, height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureLayer.contents = image
        if resized {
            gesture.clampPointer(context)
            gesture.relayout(context)
            place()
        }
        CATransaction.commit()
    }

    func clearPicture() {
        pictureLayer.contents = nil
        framebuffer = (0, 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gesture.relayout(context)
        place()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureLayer.frame = ScreenViewMath.drawn(stage: bounds.size, aspect: aspect, view: gesture.view)
        dimLayer.frame = bounds
        ring.position = gesture.pointer.point(in: pictureLayer.frame)
        CATransaction.commit()
    }

    /// Sets the local view (Fit, compact typing). Animated unless Reduce Motion is on.
    func setView(_ next: ScreenView, animated: Bool) {
        gesture.setView(next, context)
        if animated, !HQMotion.reduced {
            let target = ScreenViewMath.drawn(stage: bounds.size, aspect: aspect, view: gesture.view)
            let move = CABasicAnimation(keyPath: "bounds.size")
            move.fromValue = pictureLayer.bounds.size
            move.toValue = target.size
            let slide = CABasicAnimation(keyPath: "position")
            slide.fromValue = pictureLayer.position
            slide.toValue = CGPoint(x: target.midX, y: target.midY)
            for animation in [move, slide] { animation.duration = 0.22 }
            pictureLayer.add(move, forKey: "fit.size")
            pictureLayer.add(slide, forKey: "fit.position")
        }
        place()
    }

    /// Test and accessibility seam: where the pointer is, in framebuffer pixels.
    var pointerPixel: (x: Int, y: Int) { gesture.pointer.pixel(framebuffer) }

    // MARK: Touches

    private func points() -> [CGPoint] { active.map { $0.location(in: self) } }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard framebuffer.width > 0 else { return }
        active.append(contentsOf: touches.filter { !active.contains($0) })
        onTouch?()
        apply(gesture.began(points(), now: ProcessInfo.processInfo.systemUptime, context))
        armHold()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !active.isEmpty else { return }
        apply(gesture.moved(points(), context))
        armHold()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !active.isEmpty else { return }
        active.removeAll { touches.contains($0) }
        apply(gesture.ended(remaining: active.count, now: ProcessInfo.processInfo.systemUptime, context))
        armHold()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !active.isEmpty else { return }
        active.removeAll()
        apply(gesture.cancelled())
        armHold()
    }

    /// Control ended, the stream closed or the view is going away: forget touches and let go of a held button.
    func dropTouches() {
        active.removeAll()
        holdTimer?.invalidate()
        holdTimer = nil
        movePending = false
        // Off the run loop now, not at deinit; the next move builds a fresh link.
        moveLink?.invalidate()
        moveLink = nil
        _ = gesture.drop()
        held = 0
        showRing(false)
    }

    private func armHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        guard let deadline = gesture.holdDeadline else { return }
        let wait = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        holdTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.holdTimer = nil
                // A timer may fire a hair early: the hold is due whenever its own timer says so.
                let now = max(ProcessInfo.processInfo.systemUptime, self.gesture.holdDeadline ?? 0)
                self.apply(self.gesture.holdFired(now: now))
            }
        }
    }

    private func apply(_ actions: [ScreenGesture.Action]) {
        for action in actions {
            switch action {
            case .pointerMoved:
                ring.position = gesture.pointer.point(in: pictureLayer.frame)
                scheduleMove()
            case .buttons(let mask):
                sendPosition()
                held = mask
                sendPosition()
            case .click(let mask):
                sendPosition()
                send(held | mask)
                send(held)
            case .wheel(let down):
                movePending = false
                send(held | (down ? 16 : 8))
                send(held)
            case .view(_, let committed):
                place()
                onView?(gesture.view, committed)
            case .holdArmed:
                onHoldArmed?()
            case .tapped:
                break
            case .touching(let on):
                showRing(on)
            }
        }
    }

    private func send(_ mask: UInt8) {
        guard control, framebuffer.width > 0 else { return }
        let at = gesture.pointer.pixel(framebuffer)
        onPointer?(mask, at.x, at.y)
    }

    private func sendPosition() {
        movePending = false
        send(held)
    }

    /// Moves go out at most once per display frame; the last position always goes before a button changes.
    private func scheduleMove() {
        movePending = true
        if moveLink == nil {
            // A weak proxy: a display link keeps its target alive, and the stage (with its last frame) must not outlive the screen.
            let link = CADisplayLink(target: DisplayTarget { [weak self] in self?.flushMove() }, selector: #selector(DisplayTarget.tick))   // motion-ok: not an animation: paces pointer moves to the display
            link.add(to: .main, forMode: .common)
            moveLink = link
        }
        moveLink?.isPaused = false
    }

    private func flushMove() {
        moveLink?.isPaused = true
        guard movePending else { return }
        sendPosition()
    }

    #if DEBUG
    /// Test seam: a pointer move as a pan in control makes one.
    func debugScheduleMove() { scheduleMove() }
    var debugHasMoveLink: Bool { moveLink != nil }
    #endif

    private func showRing(_ on: Bool) {
        ring.removeAllAnimations()
        ring.position = gesture.pointer.point(in: pictureLayer.frame)
        if on || HQMotion.reduced {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.opacity = on ? 0.9 : 0
            CATransaction.commit()
        } else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = ring.presentation()?.opacity ?? ring.opacity
            fade.toValue = 0
            fade.duration = 0.3
            ring.opacity = 0
            ring.add(fade, forKey: "fade")
        }
    }

    // MARK: Accessibility (§6.3)

    private func refreshAccessibility() {
        accessibilityLabel = botName.isEmpty ? "The bot’s screen" : "\(botName)’s screen"
        accessibilityTraits = control ? [.allowsDirectInteraction] : [.image]
        let zoom = [
            UIAccessibilityCustomAction(name: "Zoom in") { [weak self] _ in self?.zoom(by: 1.5) ?? false },
            UIAccessibilityCustomAction(name: "Zoom out") { [weak self] _ in self?.zoom(by: 1 / 1.5) ?? false },
            UIAccessibilityCustomAction(name: "Fit screen") { [weak self] _ in self?.fit() ?? false },
        ]
        let pointer = [
            UIAccessibilityCustomAction(name: "Click") { [weak self] _ in self?.act(.click(1)) ?? false },
            UIAccessibilityCustomAction(name: "Right-click") { [weak self] _ in self?.act(.click(4)) ?? false },
            UIAccessibilityCustomAction(name: "Scroll up") { [weak self] _ in self?.act(.wheel(down: false)) ?? false },
            UIAccessibilityCustomAction(name: "Scroll down") { [weak self] _ in self?.act(.wheel(down: true)) ?? false },
        ]
        accessibilityCustomActions = control ? pointer + zoom : zoom
    }

    private func act(_ action: ScreenGesture.Action) -> Bool {
        guard control, framebuffer.width > 0 else { return false }
        apply([action])
        return true
    }

    /// Zooms by `factor` about the middle (VoiceOver, and the Mac's = / - keys and Zoom buttons).
    @discardableResult func zoom(by factor: CGFloat) -> Bool {
        guard framebuffer.width > 0 else { return false }
        let next = ScreenViewMath.zoomAbout(gesture.view, factor: factor, at: CGPoint(x: bounds.midX, y: bounds.midY),
                                            width: bounds.width, height: bounds.height)
        setView(next, animated: true)
        onView?(gesture.view, true)
        return true
    }

    @discardableResult func fit() -> Bool {
        setView(.fit, animated: true)
        onView?(gesture.view, true)
        return true
    }
}
