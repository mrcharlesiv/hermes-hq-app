// [first-run] The stage: one set of dots that lives above the first run's screens for as long as the flow is on show and
// never restarts between them (the mock's "stage" section, build/first-run/spec/prototype.src.html). The dots are the
// land of a globe that turns to face the person, then the LEDs of a dot-matrix face that isn't lit yet, then they light
// in the head's own colour and run together into the face the app really shows. `under` sits below the words (stars,
// the air round the globe, the glow); `over` above them (the globe, the dots, the message arcs, the mark, the face).
// `touch` keeps only the globe's drag (Hello) and the face's tap (Hermes is here); every other touch goes through.
//
// One display link at 60 fps drives it, stopped while the flow is off screen, in the background, or on a screen the
// stage stands down for. Under Reduce Motion and Low Power Mode (`HQMotion.decorativeStill`) it is the mock's still
// mode: no travelling dots, no camera kick, no flash, each beat shown at rest and cross-faded.

import UIKit
import UIKit.UIGestureRecognizerSubclass

private let easeOut = ArrivalWorld.Ease.out
private let easeInOut = ArrivalWorld.Ease.inOut

/// Where the stage's mock points land on the screen, for the screens that place words and the face under it.
@MainActor @Observable final class ArrivalLayout {
    /// Points per mock point (1 on a 6.3" phone, less on a small one).
    var k: Double = 1
    /// The words never cover the stage at the accessibility sizes: the stage stands down there.
    var standsDown = false

    /// How far below the top of the safe area a mock `y` lands (the mock's status bar is 54 pt).
    func belowSafeTop(_ y: Double) -> CGFloat { CGFloat(max(0, (y - 54) * k)) }
}

@MainActor final class ArrivalStage: NSObject {
    enum Mode { case stars, globe, led, burst, gone }

    let under = ArrivalLayerView(frame: .zero)
    let over = ArrivalLayerView(frame: .zero)
    let touch = ArrivalTouchView(frame: .zero)
    let layout = ArrivalLayout()
    /// The mock's still mode (Reduce Motion, Low Power Mode), read at each beat.
    private(set) var still = HQMotion.decorativeStill

    // MARK: Geometry

    private var k = 1.0, ox = 0.0, oy = 0.0
    private var size = CGSize.zero
    private var pixelScale = 3.0

    // MARK: The dots (parallel arrays, made once)

    let place: ArrivalWorld.Place
    private let world: [ArrivalWorld.Dot]
    private let stars: [ArrivalWorld.Star]
    let count: Int
    private var px: [Double], py: [Double], pr: [Double], pa: [Double], pc: [SIMD3<Double>]
    private var fx: [Double], fy: [Double], fr: [Double], fa: [Double], fc: [SIMD3<Double>]
    private var t0: [Double], dur: [Double], sw: [Double]
    private var hasFrom = false
    private(set) var cell: [Int], prim: [Bool]
    private var bx: [Double], by: [Double]
    private var random = ArrivalWorld.Random(state: 7)

    private(set) var mode: Mode = .stars
    var gp = ArrivalWorld.Globe()
    var lp = ArrivalWorld.Leds()

    // MARK: The face, the light, the camera (tweened by key path)

    var faceX = 195.0, faceY = 300.0, faceR = 106.0, faceA = 0.0, faceLid = 1.0, faceGX = 0.0, faceGY = 0.0
    var faceSc = 1.0, faceHop = 0.0
    private var facePX = 0.0, facePY = 0.0, faceTX = 0.0, faceTY = 0.0, faceBT = -1e9
    var glow = 0.0, flash = 0.0, camZ = 0.0, markA = 0.0
    private var bodyA = 0.0
    private var rotA = 0.0, rotV = 0.0, dragging = false
    private var settleT = 0.0, lastT = 0.0
    /// The real face (Hermes is here): moved with the hop and the finger it watches, once it has taken over.
    weak var realFace: UIView?

    private struct Ring { var cx, cy, r0, r1, dur, a: Double; var col: SIMD3<Double>; var shock: Bool; var t0: Double }
    private struct Arc { var a, b: SIMD3<Double>; var dur, alpha, om, t0: Double }
    private var rings: [Ring] = []
    private var arcs: [Arc] = []

    // MARK: Colours (0…255): the app's ink and tint, the head's own accent

    private var dark = true
    private var mono = SIMD3<Double>(245, 245, 247), tint = SIMD3<Double>(76, 134, 254)
    private(set) var accent = SIMD3<Double>(176, 48, 85)
    private var hot = SIMD3<Double>(255, 222, 230), spark = SIMD3<Double>(236, 112, 146)

    // MARK: Time

    typealias Key = ReferenceWritableKeyPath<ArrivalStage, Double>
    private final class Tween {
        let token: Int, start: Double, length: Double, ease: ArrivalWorld.Ease
        let keys: [Key], from: [Double], to: [Double]
        var done: CheckedContinuation<Void, Error>?
        init(token: Int, start: Double, length: Double, ease: ArrivalWorld.Ease, keys: [Key], from: [Double], to: [Double],
             done: CheckedContinuation<Void, Error>?) {
            self.token = token; self.start = start; self.length = length; self.ease = ease
            self.keys = keys; self.from = from; self.to = to; self.done = done
        }
    }
    private var tweens: [Tween] = []
    private(set) var token = 0
    private var script: Task<Void, Never>?
    private var side: [UUID: Task<Void, Never>] = [:]
    private static let maxArcs = 16
    private static let maxRings = 32

    private var link: CADisplayLink?
    private var attached = false, active = true, shown = false
    /// In still mode the link runs only until this time (ms) after a change, then rests.
    private var stillUntil = 0.0
    /// Sounds are on (a test can turn them off).
    var sounds = true

    /// Test-visible counts for verifying zero leaked continuations or unbounded growth.
    var activeTweenCount: Int { tweens.count }
    var activeSideTaskCount: Int { side.count }
    var activeArcCount: Int { arcs.count }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        link?.invalidate()
        link = nil
        script?.cancel()
        for task in side.values { task.cancel() }
        for tween in tweens {
            tween.done?.resume(throwing: CancellationError())
            tween.done = nil
        }
    }

    init(place: ArrivalWorld.Place = .current) {
        self.place = place
        var r = ArrivalWorld.Random()
        var dots: [ArrivalWorld.Dot] = []
        if let land = ArrivalWorld.Land.bundled { dots = ArrivalWorld.dots(land: land, random: &r) }
        let n = dots.count
        world = dots
        stars = ArrivalWorld.stars(random: &r)
        count = n
        let xs = dots.map(\.hx), ys = dots.map(\.hy)
        let rs = dots.map { 0.5 + $0.hs * 0.9 }, al = dots.map { (0.05 + 0.3 * $0.hs) * 0.8 }
        let cs = [SIMD3<Double>](repeating: SIMD3(245, 245, 247), count: n)
        px = xs; py = ys; pr = rs; pa = al; pc = cs
        fx = xs; fy = ys; fr = rs; fa = al; fc = cs
        t0 = Array(repeating: 0, count: n); dur = Array(repeating: 1, count: n)
        sw = Array(repeating: 0, count: n)
        cell = Array(repeating: 0, count: n); prim = Array(repeating: false, count: n)
        bx = Array(repeating: 0, count: n); by = Array(repeating: 0, count: n)
        super.init()
        gp.tilt = place.tilt
        rotA = place.restRotation - 2.7
        touch.stage = self
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        touch.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        touch.addGestureRecognizer(tap)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(wentAway), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(cameBack), name: UIApplication.willEnterForegroundNotification, object: nil)
        ArrivalSound.prepare()
    }

    // MARK: - Placing it

    /// Lays the three views over `bounds` (the flow's whole view). The mock's 390 × 844 phone is centred across and
    /// its status bar (54 pt) lines up with the safe area's top.
    func fit(bounds: CGRect, safeTop: CGFloat, safeBottom: CGFloat, scale: CGFloat, traits: UITraitCollection) {
        for view in [under, over, touch] { view.frame = bounds }
        size = bounds.size
        pixelScale = Double(scale)
        let tall = Double(bounds.height - safeTop - safeBottom) + 54 + 34
        k = min(1, Double(bounds.width) / ArrivalWorld.phone.width, tall / ArrivalWorld.phone.height)
        ox = Double(bounds.width) / 2 - 195 * k
        oy = Double(safeTop) - 54 * k
        if layout.k != k { layout.k = k }
        let standsDown = traits.preferredContentSizeCategory.isAccessibilityCategory
        if layout.standsDown != standsDown { layout.standsDown = standsDown; applyAlpha(animated: true) }
        colours(traits)
        if !running { drawOnce() }
    }

    func colours(_ traits: UITraitCollection) {
        dark = traits.userInterfaceStyle == .dark
        mono = Self.rgb(HQPalette.label.resolvedColor(with: traits))
        tint = Self.rgb(HQPalette.tint.resolvedColor(with: traits))
    }

    /// The head's own colour (`HeadTones.accent`): the LEDs light in it, the glow and the sparks are made from it.
    func setAccent(_ colour: HeadRGB) {
        accent = SIMD3(colour.red * 255, colour.green * 255, colour.blue * 255)
        hot = accent + (SIMD3(255, 255, 255) - accent) * 0.86
        spark = SIMD3(min(255, accent.x * 1.34 + 8), min(255, accent.y * 2.33 + 24), min(255, accent.z * 1.72 + 16))
    }

    private static func rgb(_ colour: UIColor) -> SIMD3<Double> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Double(r) * 255, Double(g) * 255, Double(b) * 255)
    }

    @inline(__always) private func toView(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * k, y: oy + y * k) }

    /// Where a mock point lands in the stage's views (the flow's whole view).
    func viewPoint(x: Double, y: Double) -> CGPoint { toView(x, y) }
    @inline(__always) private func toMock(_ p: CGPoint) -> (x: Double, y: Double) { ((Double(p.x) - ox) / k, (Double(p.y) - oy) / k) }

    // MARK: - Showing and resting

    /// The stage on show (an arrival screen) or standing down (any screen this first run doesn't redraw): it fades,
    /// and rests once gone. Leaving drawn screens cancels in-flight beats/side loops and drains pending tweens.
    func setShown(_ on: Bool, animated: Bool) {
        guard on != shown else { return }
        shown = on
        if on {
            startIfDue()
        } else {
            cancelWork()
        }
        applyAlpha(animated: animated)
    }

    private func applyAlpha(animated: Bool) {
        let alpha: CGFloat = shown && !layout.standsDown ? 1 : 0
        let change = { for view in [self.under, self.over] { view.alpha = alpha } }
        if animated {
            // motion-ok: opacity only (the stage fading in or out).
            UIView.animate(withDuration: 0.35, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: change) { _ in
                if alpha == 0 { self.stopIfIdle() }
            }
        } else {
            change()
            if alpha == 0 { stopIfIdle() }
        }
    }

    func windowChanged(_ inWindow: Bool) {
        attached = inWindow
        if inWindow { startIfDue() } else { stop() }
    }

    @objc private func wentAway() { active = false; pauseLink() }
    @objc private func cameBack() { active = true; startIfDue() }

    private var running: Bool { link != nil }

    private func startIfDue() {
        guard link == nil, attached, active, shown, !layout.standsDown else { return }
        // motion-ok: the stage's one clock; in still mode (HQMotion.decorativeStill) it rests between beats.
        let link = CADisplayLink(target: ArrivalLinkTarget(self), selector: #selector(ArrivalLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastT = Self.ms()
    }

    private func pauseLink() {
        link?.invalidate()
        link = nil
    }

    /// Stops animation and tears down all running scripts, side tasks, suspended tween continuations, and transient effects
    /// so `ArrivalStage` (and its Metal buffers) can never be retained by a suspended continuation.
    func stop() {
        pauseLink()
        cancelWork()
    }

    private func cancelWork() {
        token += 1
        script?.cancel()
        script = nil
        for task in side.values { task.cancel() }
        side.removeAll()
        let old = tweens
        tweens.removeAll()
        for tween in old {
            tween.done?.resume(throwing: CancellationError())
            tween.done = nil
        }
        rings.removeAll()
        arcs.removeAll()
    }

    private func stopIfIdle() {
        if !shown || layout.standsDown { stop() }
    }

    /// Keeps the link running a little after a change in still mode (it rests between beats otherwise).
    private func wake(for ms: Double = 700) {
        stillUntil = max(stillUntil, Self.ms() + ms)
        startIfDue()
    }

    static func ms() -> Double { CACurrentMediaTime() * 1000 }

    // MARK: - Touches

    /// Hello: the globe takes a drag. Hermes is here: the face takes a tap. Nothing else.
    var dragsGlobe = false
    var tapsFace = false
    var onFaceTap: (() -> Void)?

    func takesTouch(at point: CGPoint) -> Bool {
        guard shown, !layout.standsDown else { return false }
        let m = toMock(point)
        if dragsGlobe, mode == .globe {
            let dx = m.x - 195, dy = m.y - 261
            return dx * dx + dy * dy <= 135 * 135
        }
        if tapsFace {
            let dx = m.x - faceX, dy = m.y - faceY
            return dx * dx + dy * dy <= faceR * faceR
        }
        return false
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard dragsGlobe else { return }
        switch pan.state {
        case .began: dragging = true
        case .changed:
            let d = Double(pan.translation(in: touch).x) / k
            pan.setTranslation(.zero, in: touch)
            rotA -= d * 0.011
            rotV = -d * 0.5
        default: dragging = false
        }
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard tapsFace else { return }
        onFaceTap?()
    }

    /// Where a finger is on the screen (nil: lifted); the face watches it.
    func watch(_ point: CGPoint?) {
        guard let point else { faceTX = 0; faceTY = 0; return }
        let m = toMock(point)
        faceTX = ArrivalWorld.clamp((m.x - faceX) / 640, -0.055, 0.055)
        faceTY = ArrivalWorld.clamp((m.y - faceY) / 760, -0.04, 0.055)
    }

    // MARK: - Time: tweens, sleeps, beats

    /// Starts a new beat: whatever the last one left running stops (its tweens end where they are).
    func begin(_ body: @escaping @MainActor (ArrivalStage) async throws -> Void) {
        token += 1
        script?.cancel()
        for task in side.values { task.cancel() }
        side.removeAll()
        // As the mock's `tw`: the old beat's tweens stop where they are, and their waiters are let go.
        let old = tweens
        tweens.removeAll()
        for tween in old { tween.done?.resume(throwing: CancellationError()); tween.done = nil }
        still = HQMotion.decorativeStill
        if still { wake() }
        script = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await body(self)
        }
    }

    /// Something to run beside the beat (the mock's un-awaited chains); stops with the beat and prunes itself on finish.
    func spawn(_ body: @escaping @MainActor () async throws -> Void) {
        let id = UUID()
        side[id] = Task { @MainActor [weak self] in
            defer { self?.side.removeValue(forKey: id) }
            try? await body()
        }
    }

    func sleep(_ ms: Double) async throws {
        if still { try Task.checkCancellation(); return }
        try await Task.sleep(nanoseconds: UInt64(max(0, ms) * 1_000_000))
    }

    /// The mock's `tw`: moves these numbers to these values; ends early (throwing) when the beat moves on.
    func tw(_ pairs: [(Key, Double)], _ length: Double = 600, _ ease: ArrivalWorld.Ease = .out) async throws {
        if still {
            for (key, value) in pairs { self[keyPath: key] = value }
            wake()
            return
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            tweens.append(Tween(token: token, start: Self.ms(), length: length, ease: ease, keys: pairs.map(\.0),
                                from: pairs.map { self[keyPath: $0.0] }, to: pairs.map(\.1), done: done))
        }
    }

    /// `tw` without waiting for it.
    func twGo(_ pairs: [(Key, Double)], _ length: Double = 600, _ ease: ArrivalWorld.Ease = .out) {
        if still {
            for (key, value) in pairs { self[keyPath: key] = value }
            wake()
            return
        }
        tweens.append(Tween(token: token, start: Self.ms(), length: length, ease: ease, keys: pairs.map(\.0),
                            from: pairs.map { self[keyPath: $0.0] }, to: pairs.map(\.1), done: nil))
    }

    func cue(_ cue: ArrivalSound.Cue) {
        guard !still, sounds else { return }
        ArrivalSound.play(cue)
    }

    func ring(_ cx: Double, _ cy: Double, _ r0: Double, _ r1: Double, _ length: Double, _ a: Double,
              _ col: SIMD3<Double>? = nil, shock: Bool = false) {
        guard !still, active, shown else { return }
        let now = Self.ms()
        rings.removeAll { now >= $0.t0 + $0.dur }
        if rings.count >= Self.maxRings { rings.removeFirst(rings.count - Self.maxRings + 1) }
        rings.append(Ring(cx: cx, cy: cy, r0: r0, r1: r1, dur: length, a: a, col: col ?? mono, shock: shock, t0: now))
    }

    /// A message crossing the globe: a great circle, lifted off the ground in the middle, gone where the globe hides it.
    func arc(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ length: Double, alpha: Double = 1) async throws {
        guard !still else { return }
        if active && shown {
            let now = Self.ms()
            arcs.removeAll { now >= $0.t0 + $0.dur * 1.4 }
            if arcs.count >= Self.maxArcs { arcs.removeFirst(arcs.count - Self.maxArcs + 1) }
            let dot = ArrivalWorld.clamp(a.x * b.x + a.y * b.y + a.z * b.z, -1, 1)
            arcs.append(Arc(a: a, b: b, dur: length, alpha: alpha, om: acos(dot), t0: now))
        }
        try await sleep(length)
    }

    func project(_ u: SIMD3<Double>) -> (x: Double, y: Double) {
        let p = gp.project(u)
        return (p.x, p.y)
    }

    var tintColour: SIMD3<Double> { tint }

    // MARK: - Modes

    func setMode(_ next: Mode, dur length: Double = 900, stagger: Double = 0, swirl: Double = 0) {
        let now = Self.ms()
        for i in 0..<count {
            fx[i] = px[i]; fy[i] = py[i]; fr[i] = pr[i]; fa[i] = pa[i]; fc[i] = pc[i]
            t0[i] = now + stagger * random.next()
            dur[i] = length
            sw[i] = swirl * (random.next() - 0.5) * 2
        }
        hasFrom = true
        mode = next
        settleT = now + length + stagger
        if still { wake() }
    }

    /// What every beat does first: nothing left over from the one before.
    func prep(keepFace: Bool = false) {
        rings.removeAll(keepingCapacity: true)
        arcs.removeAll(keepingCapacity: true)
        lp.scan = nil
        faceTX = 0; faceTY = 0
        dragsGlobe = false; tapsFace = false
        if !keepFace {
            if faceA > 0 { twGo([(\.faceA, 0)], 220) }
            if glow > 0 { twGo([(\.glow, 0)], 300) }
        }
    }

    func toGlobe(cx: Double, cy: Double, r: Double, dur length: Double = 1100, stagger: Double = 450, swirl: Double = 0.3) {
        if mode != .globe {
            gp.cx = cx; gp.cy = cy; gp.r = r
            setMode(.globe, dur: length, stagger: stagger, swirl: swirl)
        } else {
            twGo([(\.gp.cx, cx), (\.gp.cy, cy), (\.gp.r, r)], 700, .inOut)
        }
        if markA < 1 { twGo([(\.markA, 1)], 500) }
    }

    /// Each LED takes the nearest dot it can see; the rest of the world folds in behind them and goes dark.
    func toLED(cx: Double, cy: Double, pitch: Double, dur length: Double, stagger: Double, swirl: Double) {
        lp = ArrivalWorld.Leds(cx: cx, cy: cy, pitch: pitch)
        let cells = ArrivalWorld.cells
        let centres = cells.map { SIMD2(cx + $0.dx * pitch, cy + $0.dy * pitch) }
        var order = Array(cells.indices)
        for i in stride(from: order.count - 1, to: 0, by: -1) {
            let j = Int(random.next() * Double(i + 1)) % (i + 1)
            order.swapAt(i, j)
        }
        let points = (0..<count).map { SIMD2(px[$0], py[$0]) }
        let assigned = ArrivalWorld.assign(cellCentres: centres, dots: points, alphas: pa, order: order)
        cell = assigned.cell
        prim = assigned.prim
        setMode(.led, dur: length, stagger: stagger, swirl: swirl)
        if markA > 0 { twGo([(\.markA, 0)], 250) }
    }

    /// The LEDs let go: each lit one flies off along its own direction from the middle.
    func letGo() {
        let cells = ArrivalWorld.cells
        for i in 0..<count where prim[i] {
            let cl = cells[cell[i]]
            let angle = atan2(cl.dy, cl.dx) + (random.next() - 0.5) * 0.5
            bx[i] = cos(angle); by[i] = sin(angle)
        }
        setMode(.burst, dur: 1150, stagger: 320)
    }

    /// Hello, fresh: the globe comes round to them from a little way off.
    func resetSpin() { rotA = place.restRotation - 2.7; rotV = 0 }

    func scan(_ on: Bool) {
        lp.scan = on ? Self.ms() : nil
        if on { cue(.scan) }
    }

    func boopRing() { ring(faceX, faceY, faceR, faceR * 1.5, 700, 0.5, accent, shock: true); faceBT = Self.ms() }

    // MARK: - The frame

    fileprivate func tick() {
        let now = Self.ms()
        if still && now > stillUntil && tweens.isEmpty { draw(now); pauseLink(); return }
        draw(now)
    }

    private func drawOnce() {
        guard size.width > 0, attached else { return }
        draw(Self.ms())
    }

    private func draw(_ now: Double) {
        let dt = min(50, max(0, now - lastT))
        lastT = now
        if still { rotA = place.restRotation + 0.14 }
        else if !dragging {
            rotV += ((place.restRotation + 0.2 * sin(now / 2600) - rotA) * 5.5 - rotV * 4.2) * dt / 1000
            rotA += rotV * dt / 1000
        }
        gp.rot = rotA
        stepTweens(now)
        bodyA = still ? (mode == .globe ? 1 : 0) : bodyA + ((mode == .globe ? 1 : 0) - bodyA) * min(1, dt / (mode == .globe ? 620 : 300))
        facePX += (faceTX - facePX) * min(1, dt / 110)
        facePY += (faceTY - facePY) * min(1, dt / 110)
        rings.removeAll { now >= $0.t0 + $0.dur }
        arcs.removeAll { now >= $0.t0 + $0.dur * 1.4 }
        if let face = realFace {
            let d = faceR * 2
            face.transform = CGAffineTransform(translationX: CGFloat(facePX * d * 0.6 * k), y: CGFloat((facePY * d * 0.6 + faceHop) * k))
                .scaledBy(x: CGFloat(faceSc), y: CGFloat(faceSc))
        }
        guard size.width > 0, under.alpha > 0 || over.alpha > 0 else { return }
        var uniforms = ArrivalUniforms(view: SIMD4(Float(size.width), Float(size.height), Float(k), Float(pixelScale)),
                                       place: SIMD4(Float(ox), Float(oy), 195, Float(faceY)),
                                       zoom: SIMD4(Float(1 + camZ), 0, 0, 0))
        if under.begin() { drawUnder(now); under.commit(uniforms: uniforms) }
        uniforms.zoom.x = Float(1 + camZ)
        if over.begin() { drawOver(now); over.commit(uniforms: uniforms) }
    }

    private func stepTweens(_ now: Double) {
        guard !tweens.isEmpty else { return }
        var i = 0
        while i < tweens.count {
            let tween = tweens[i]
            let q = ArrivalWorld.clamp((now - tween.start) / tween.length)
            let e = tween.ease(q)
            for j in 0..<tween.keys.count { self[keyPath: tween.keys[j]] = tween.from[j] + (tween.to[j] - tween.from[j]) * e }
            if q >= 1 {
                tweens.remove(at: i)
                tween.done?.resume()
                tween.done = nil
            } else {
                i += 1
            }
        }
    }

    @inline(__always) private func col(_ c: SIMD3<Double>, _ a: Double) -> SIMD4<Float> {
        SIMD4(Float(c.x / 255), Float(c.y / 255), Float(c.z / 255), Float(max(0, min(1, a))))
    }

    private func drawUnder(_ now: Double) {
        let drift = still ? 0 : now
        let starAlpha = dark ? 1.0 : 0.45
        for s in stars {
            var x = s.x, y = s.y + (drift * 0.0016 * (0.3 + s.s)).truncatingRemainder(dividingBy: 844)
            if y > 844 { y -= 844 }
            for r in rings where r.shock {
                let dx = x - r.cx, dy = y - r.cy, d = max((dx * dx + dy * dy).squareRoot(), 1)
                let reach = ArrivalWorld.mix(r.r0, r.r1 * 1.7, easeOut((now - r.t0) / r.dur))
                let w = 1 - abs(d - reach) / 46
                if w > 0 {
                    let push = w * 15 * (1 - (now - r.t0) / r.dur)
                    x += dx / d * push; y += dy / d * push
                }
            }
            let a = (0.05 + 0.26 * s.s) * (0.6 + 0.4 * sin(drift * 0.0012 + s.ph)) * starAlpha
            under.add(.disc, x: x, y: y, extent: 0.5 + s.s * 0.8, c0: col(mono, a))
        }
        if bodyA > 0.01 {
            let air = dark ? SIMD3<Double>(170, 195, 255) : SIMD3<Double>(40, 80, 170), al = (dark ? 0.16 : 0.07) * bodyA
            under.add(.glow, x: gp.cx, y: gp.cy, extent: gp.r * 1.42, p: SIMD4(Float(gp.r * 0.92), Float(gp.r * 1.42), 0.35, 0),
                      c0: col(air, al), c1: col(air, al * 0.36), c2: col(air, 0))
        }
        if glow > 0.01 {
            let al = (dark ? 0.4 : 0.2) * glow, lifted = SIMD3(min(255, accent.x * 1.08), min(255, accent.y * 1.08), min(255, accent.z * 1.08))
            under.add(.glow, x: faceX, y: faceY, extent: faceR * 2.8, p: SIMD4(Float(faceR * 0.3), Float(faceR * 2.8), 0.45, 0),
                      c0: col(lifted, al), c1: col(accent, al * 0.42), c2: col(accent, 0))
        }
        if flash > 0.01 {
            let c = dark ? hot : accent, a = (dark ? 0.3 : 0.16) * flash
            under.add(.glow, x: faceX, y: faceY, extent: 620, p: SIMD4(0, 620, 0.5, 0),
                      c0: col(c, a), c1: col((c + accent) / 2, a / 2), c2: col(accent, 0))
        }
    }

    private func drawOver(_ now: Double) {
        if bodyA > 0.01 {
            let stops: [SIMD3<Double>] = dark ? [SIMD3(0x1d, 0x24, 0x33), SIMD3(0x11, 0x15, 0x1d), SIMD3(0x0a, 0x0d, 0x12)]
                                             : [SIMD3(255, 255, 255), SIMD3(0xf1, 0xf3, 0xf7), SIMD3(0xe3, 0xe6, 0xee)]
            over.add(.globe, x: gp.cx, y: gp.cy, extent: gp.r, p: SIMD4(Float(-gp.r * 0.36), Float(-gp.r * 0.42), Float(gp.r * 0.08), 0),
                     c0: col(stops[0], bodyA), c1: col(stops[1], bodyA), c2: col(stops[2], bodyA))
            over.add(.ring, x: gp.cx, y: gp.cy, extent: gp.r + 0.5, p: SIMD4(1, 0, 0, 0),
                     c0: col(dark ? SIMD3(190, 210, 255) : SIMD3(20, 40, 90), (dark ? 0.22 : 0.12) * bodyA))
        }
        let bloom = dark && mode == .led && lp.ign != nil
        let additive: Float = bloom ? 1 : 0
        let cells = ArrivalWorld.cells
        let faceSpot = (x: faceX, y: faceY, r: faceR)
        for i in 0..<count {
            let tg: ArrivalWorld.Target
            switch mode {
            case .stars: tg = ArrivalWorld.star(world[i], now: still ? 0 : now, mono: mono)
            case .globe: tg = ArrivalWorld.globe(world[i], gp, mono: mono)
            case .led: tg = ArrivalWorld.led(cell: cells[cell[i]], prim: prim[i], lp, now: now, still: still, mono: mono, accent: accent, hot: hot)
            case .burst: tg = ArrivalWorld.burst(world[i], prim: prim[i], bx: bx[i], by: by[i], face: faceSpot, accent: accent, spark: spark)
            case .gone: tg = ArrivalWorld.Target(x: faceX, y: faceY, r: 0.5, a: 0, c: accent)
            }
            let q = still || !hasFrom ? 1 : ArrivalWorld.clamp((now - t0[i]) / dur[i])
            if q >= 1 {
                px[i] = tg.x; py[i] = tg.y; pr[i] = tg.r; pa[i] = tg.a; pc[i] = tg.c
            } else {
                let e = easeInOut(q), off = sin(Double.pi * e) * sw[i], dx = tg.x - fx[i], dy = tg.y - fy[i]
                px[i] = fx[i] + dx * e - dy * off
                py[i] = fy[i] + dy * e + dx * off
                pr[i] = ArrivalWorld.mix(fr[i], tg.r, e)
                pa[i] = ArrivalWorld.mix(fa[i], tg.a, e)
                pc[i] = fc[i] + (tg.c - fc[i]) * e
            }
            guard pa[i] > 0.012 else { continue }
            if bloom && tg.g > 0.02 {
                over.add(.disc, x: px[i], y: py[i], extent: pr[i] * 2.7, p: SIMD4(0, 0, 0, 1), c0: col(pc[i], pa[i] * 0.13 * tg.g))
            }
            over.add(.disc, x: px[i], y: py[i], extent: pr[i], p: SIMD4(0, 0, 0, additive), c0: col(pc[i], pa[i]))
        }
        let gs = ArrivalWorld.clamp(gp.r / 116, 0.5, 1)
        if bodyA > 0.5 { for arc in arcs { drawArc(arc, now: now, gs: gs) } }
        if markA > 0.01 && bodyA > 0.3 {
            let m = gp.project(place.you)
            let settled = still ? 1 : ArrivalWorld.clamp((now - settleT + 350) / 350)   // not before the land is in place
            let al = markA * bodyA * ArrivalWorld.clamp(m.z * 4) * settled
            if al > 0.01 {
                // A soft light over their part of the world, not a pin (owner 2026-11-23: the pin read as a city, and
                // the clock only knows the time zone): about a time zone wide, breathing slowly.
                let breath = still ? 0 : sin(now / 1500)
                let radius = gp.r * (0.31 + 0.025 * breath)
                over.add(.glow, x: m.x, y: m.y, extent: radius, p: SIMD4(0, Float(radius), 0.45, 0),
                         c0: col(tint, al * (0.62 + 0.08 * breath)), c1: col(tint, al * 0.26), c2: col(tint, 0))
            }
        }
        for r in rings {
            let q = (now - r.t0) / r.dur
            over.add(.ring, x: r.cx, y: r.cy, extent: ArrivalWorld.mix(r.r0, r.r1, easeOut(q)) + 0.75,
                     p: SIMD4(1.5, 0, 0, 0), c0: col(r.col, r.a * (1 - q) * (1 - q)))
        }
        if faceA > 0.005 {
            let radius = faceR * faceSc, d = radius * 2, x0 = faceX - radius, y0 = faceY + faceHop - radius
            over.add(.disc, x: faceX, y: faceY + faceHop, extent: radius, c0: col(accent, faceA))
            var lid = faceLid
            if !still && faceA > 0.99 && lid < 0.05 {
                let b = now - faceBT < 180 ? now - faceBT : now.truncatingRemainder(dividingBy: 4100)
                if b < 180 { lid = sin(b / 180 * .pi) }
            }
            let eye = dark ? SIMD3<Double>(26, 26, 26) : SIMD3<Double>(255, 255, 255)
            for ex in [0.545, 0.755] {
                let cx = x0 + (ex + faceGX + facePX) * d, cy = y0 + (0.34 + faceGY + facePY) * d
                let w = 0.072 * d, h = max(0.175 * d * (1 - lid), w * 0.3)
                over.add(.capsule, x: cx, y: cy, extent: h / 2 + 1, p: SIMD4(Float(max(0, (h - w) / 2)), Float(w / 2), Float(Double.pi / 2 - 0.3), 0),
                         c0: col(eye, faceA))
            }
        }
    }

    private func drawArc(_ arc: Arc, now: Double, gs: Double) {
        let q = (now - arc.t0) / arc.dur
        let head = easeInOut(ArrivalWorld.clamp(q))
        let fade = q > 1 ? ArrivalWorld.clamp(1 - (q - 1) / 0.4) : 1
        let so = sin(arc.om) == 0 ? 1 : sin(arc.om)
        func at(_ t: Double) -> (x: Double, y: Double, z: Double, rim: Double) {
            let wa = sin((1 - t) * arc.om) / so, wb = sin(t * arc.om) / so
            return gp.project(arc.a * wa + arc.b * wb, alt: 1 + 0.32 * sin(Double.pi * t))
        }
        let line = col(tint, arc.alpha * fade * 0.34 * bodyA)
        var pen = false
        var last = (x: 0.0, y: 0.0)
        for step in 0...48 {
            let pt = at(head * Double(step) / 48)
            if pt.z < 0 && pt.rim < 1 { pen = false; continue }
            if pen {
                let dx = pt.x - last.x, dy = pt.y - last.y, half = (dx * dx + dy * dy).squareRoot() / 2
                over.add(.capsule, x: (pt.x + last.x) / 2, y: (pt.y + last.y) / 2, extent: half + 0.65,
                         p: SIMD4(Float(half), 0.65, Float(atan2(dy, dx)), 0), c0: line)
            }
            last = (pt.x, pt.y)
            pen = true
        }
        for step in 0..<40 {
            let t = head - Double(step) * 0.011
            if t < 0 { break }
            let pt = at(t)
            if pt.z < 0 && pt.rim < 1 { continue }
            let c = step < 3 ? SIMD3<Double>(255, 255, 255) : tint
            over.add(.disc, x: pt.x, y: pt.y, extent: (3.5 - Double(step) * 0.065) * max(gs, 0.66),
                     c0: col(c, arc.alpha * fade * (1 - Double(step) / 40) * bodyA))
        }
    }

    // MARK: - Tests

    /// Where every dot would sit if the current mode were at rest now (the unit tests read it).
    func restingTargets(now: Double = 0) -> [ArrivalWorld.Target] {
        let cells = ArrivalWorld.cells
        return (0..<count).map { i in
            switch mode {
            case .stars: ArrivalWorld.star(world[i], now: now, mono: mono)
            case .globe: ArrivalWorld.globe(world[i], gp, mono: mono)
            case .led: ArrivalWorld.led(cell: cells[cell[i]], prim: prim[i], lp, now: now, still: true, mono: mono, accent: accent, hot: hot)
            case .burst: ArrivalWorld.burst(world[i], prim: prim[i], bx: bx[i], by: by[i], face: (faceX, faceY, faceR), accent: accent, spark: spark)
            case .gone: ArrivalWorld.Target(x: faceX, y: faceY, r: 0.5, a: 0, c: accent)
            }
        }
    }

    /// Seeds the dots' current spots (tests: as if they had been drawn there).
    func seed(dotsAt targets: [ArrivalWorld.Target]) {
        for (i, t) in targets.enumerated() where i < count { px[i] = t.x; py[i] = t.y; pa[i] = t.a }
    }
}

/// Holds the stage weakly for its display link (a link retains its target).
private final class ArrivalLinkTarget: NSObject {
    weak var stage: ArrivalStage?
    init(_ stage: ArrivalStage) { self.stage = stage }
    @objc func tick(_ link: CADisplayLink) {
        guard let stage else { link.invalidate(); return }
        stage.tick()
    }
}

/// The stage's touch surface: it claims only the touches the stage keeps (the globe, the face).
final class ArrivalTouchView: UIView {
    weak var stage: ArrivalStage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { stage?.takesTouch(at: point) ?? false }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        stage?.windowChanged(window != nil)
    }
}

/// Watches a finger anywhere on the screen (the face follows it) without ever taking the touch from what is under it.
final class ArrivalWatchGesture: UIGestureRecognizer {
    var onMove: ((CGPoint?) -> Void)?
    /// The view whose points `onMove` gets (the stage's).
    weak var space: UIView?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { onMove?(touch.location(in: space ?? view)) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { onMove?(touch.location(in: space ?? view)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onMove?(nil)
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onMove?(nil)
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
