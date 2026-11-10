import UIKit

// One shared ticker drives every braille spinner on screen (docs/spec/1x-activity.md §7.4): frames of the vendor's
// `unicode-animations` 1.0.3 package, one glyph at a time in a fixed-size label so a chip never resizes and no column of
// frames ever shows (M:native-glass-chip-spinner.md). Paused while nothing is on screen or the app is inactive; Reduce
// Motion draws a still ⠿. A second shared clock ticks once a second for the elapsed timers.

enum GlyphFrames {
    static let braille = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏").map(String.init)
    static let breathe = Array("⠀⠂⠌⡑⢕⢝⣫⣟⣿⣟⣫⢝⢕⡑⠌⠂⠀").map(String.init)
    /// The subagent purple (V:styles.css:249).
    static let purple = UIColor(red: 0x9E / 255, green: 0x94 / 255, blue: 0xD5 / 255, alpha: 1)
}

/// The 80 ms (braille) / 100 ms (breathe) frame clocks: one timer per style, running only while a spinner of that
/// style can be seen (in a window, neither it nor any view above it hidden or transparent) and the app is active. A
/// timer that finds nothing to turn stops itself; showing a spinner (or a piece that holds one) starts it again.
final class GlyphTicker {
    static let shared = GlyphTicker()
    private var spinners = NSHashTable<GlyphSpinner>.weakObjects()
    private var timers: [GlyphSpinner.Style: Timer] = [:]
    private var observers: [NSObjectProtocol] = []
    private var appActive = true
    private var updateQueued = false

    private init() {
        let center = NotificationCenter.default
        #if targetEnvironment(macCatalyst)
        // [mac] Mac polish #84: beside another app the window stays in view when it is not frontmost, and a reply's
        // spinner stood still while its timer counted. They pause only when the app is hidden or its window minimized.
        let (resumes, pauses) = (UIApplication.willEnterForegroundNotification, UIApplication.didEnterBackgroundNotification)
        #else
        let (resumes, pauses) = (UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification)
        #endif
        observers.append(center.addObserver(forName: resumes, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appActive = true; self?.update() }
        })
        observers.append(center.addObserver(forName: pauses, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appActive = false; self?.update() }
        })
        observers.append(center.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for spinner in self.spinners.allObjects { spinner.resetFrame() }
                self.update()
            }
        })
    }

    func add(_ spinner: GlyphSpinner) { spinners.add(spinner); setNeedsUpdate() }
    func remove(_ spinner: GlyphSpinner) { spinners.remove(spinner); setNeedsUpdate() }

    /// Something that may show or hide a spinner changed (its own `isHidden`, a shelf piece, a cell): the timers are
    /// checked once the current layout and animations have been set up.
    func setNeedsUpdate() {
        guard !updateQueued else { return }
        updateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateQueued = false
            self.update()
        }
    }

    private func update() {
        for style in [GlyphSpinner.Style.braille, .breathe] {
            let wanted = appActive && !HQMotion.reduced
                && spinners.allObjects.contains { $0.style == style && $0.isShowing }
            if wanted, timers[style] == nil {
                let t = Timer(timeInterval: style == .braille ? 0.08 : 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fire(style) }
                }
                RunLoop.main.add(t, forMode: .common)
                timers[style] = t
            } else if !wanted, let t = timers[style] {
                t.invalidate()
                timers[style] = nil
            }
        }
    }

    private func fire(_ style: GlyphSpinner.Style) {
        var any = false
        for spinner in spinners.allObjects where spinner.style == style && spinner.isShowing {
            spinner.advance()
            any = true
        }
        if !any, let t = timers[style] {
            // Nothing of this style can be seen (its piece faded, its cell went back to the pool): pause.
            t.invalidate()
            timers[style] = nil
        }
    }
}

/// One spinner glyph. Fixed size: it never changes the width of what holds it.
final class GlyphSpinner: UILabel {
    enum Style { case braille, breathe }
    let style: Style
    private var index = 0
    private var frames: [String] { style == .braille ? GlyphFrames.braille : GlyphFrames.breathe }

    /// `prescaled`: `size` was read from a themed font, so UI Scale is already in it.
    init(style: Style = .braille, color: UIColor = GlyphFrames.purple, size: CGFloat = 15, prescaled: Bool = false) {
        self.style = style
        super.init(frame: .zero)
        font = prescaled ? HQFont.monoFace(ofSize: size, weight: .regular) : HQFont.mono(ofSize: size, weight: .regular)
        textColor = color
        textAlignment = .center
        isAccessibilityElement = false
        text = HQMotion.reduced ? "⠿" : frames[0]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHidden: Bool {
        didSet { if isHidden != oldValue { GlyphTicker.shared.setNeedsUpdate() } }
    }

    /// In a window, and neither it nor any view above it hidden or fully transparent.
    var isShowing: Bool {
        guard window != nil else { return false }
        var view: UIView? = self
        while let v = view {
            if v.isHidden || v.alpha < 0.01 { return false }
            view = v.superview
        }
        return true
    }

    /// Reduce Motion turned on or off: a still ⠿, or the first frame.
    func resetFrame() {
        index = 0
        UIView.performWithoutAnimation { text = HQMotion.reduced ? "⠿" : frames[0] }
    }

    override var intrinsicContentSize: CGSize {
        let side = ceil(font.lineHeight)
        return CGSize(width: side, height: side)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { GlyphTicker.shared.add(self) } else { GlyphTicker.shared.remove(self) }
    }

    fileprivate func advance() {
        guard !HQMotion.reduced else { return }
        index = (index + 1) % frames.count
        UIView.performWithoutAnimation { text = frames[index] }
    }
}

/// The 1 s clock for elapsed timers (one for the whole app; subscribers are weak).
final class ActivityClock {
    static let shared = ActivityClock()
    private var handlers: [ObjectIdentifier: (weak: AnyObject?, run: () -> Void)] = [:]
    private var timer: Timer?

    func subscribe(_ owner: AnyObject, _ run: @escaping () -> Void) {
        handlers[ObjectIdentifier(owner)] = (owner, run)
        if timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.fire() } }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func unsubscribe(_ owner: AnyObject) {
        handlers[ObjectIdentifier(owner)] = nil
        if handlers.isEmpty { timer?.invalidate(); timer = nil }
    }

    private func fire() {
        for (key, entry) in handlers {
            if entry.weak == nil { handlers[key] = nil; continue }
            entry.run()
        }
        if handlers.isEmpty { timer?.invalidate(); timer = nil }
    }
}

/// The desktop's `shimmer` on running text (tw-shimmer 0.4.12, V:styles.css:3): a band `4ch + 80px` wide leaning 15°,
/// one pass taking (200 + band + 200·tan 15°) / 200 s with a 100 ms rest after it, its edges on the package's 17-stop
/// sine falloff. Light: the band fades the text to a fifth of its alpha (`alpha * 0.2`). Dark: it lights the text up
/// (`l ≥ 0.8, alpha + 0.4`, drawn as the primary label over the text's own shape). Every shimmer runs on one clock, so
/// a cell laid out again doesn't restart its pass. Off under Reduce Motion (the desktop has no gate; iOS asks for one).
enum Shimmer {
    private static let name = "shimmer"
    private static let speed: CGFloat = 200, track: CGFloat = 200, rest: CFTimeInterval = 0.1
    private static let lean = tan(15 * CGFloat.pi / 180)
    /// The stops, as a share of the band from its centre, and how much of the resting colour each holds.
    private static let stops: [CGFloat] = [-0.5, -0.44, -0.37, -0.31, -0.25, -0.19, -0.12, -0.06, 0, 0.06, 0.12, 0.19, 0.25, 0.31, 0.37, 0.44, 0.5]
    private static let resting: [CGFloat] = [1, 0.96, 0.83, 0.67, 0.5, 0.33, 0.17, 0.04, 0, 0.04, 0.17, 0.33, 0.5, 0.67, 0.83, 0.96, 1]

    /// `4ch + 80px`: four widths of the text's "0".
    static func band(_ font: UIFont?) -> CGFloat {
        4 * ("0" as NSString).size(withAttributes: [.font: font ?? HQFont.scaled(13, like: .footnote, cap: 22)]).width + 80
    }

    /// `contentToken`: changes whenever the view's drawing does (`TextDrawView.drawGeneration`). [perf] With one, the dark
    /// glow re-snapshots the text only when it changed; without one, on every call (the text may have changed in place).
    static func set(_ on: Bool, on view: UIView, font: UIFont? = nil, contentToken: Int? = nil) {
        let dark = view.traitCollection.userInterfaceStyle == .dark
        let glow = view.layer.sublayers?.first { $0.name == name }
        guard on, !HQMotion.reduced, view.bounds.width > 0, view.bounds.height > 0 else {
            if view.layer.mask?.name == name { view.layer.mask = nil }
            glow?.removeFromSuperlayer()
            return
        }
        let spread = band(font ?? (view as? UILabel)?.font)
        let size = view.bounds.size
        let traits = view.traitCollection
        let key = "\(dark) \(size.width) \(size.height) \(spread) \(traits[ThemeGenerationTrait.self]) \(traits.displayScale)"
        if dark, let glow, glow.value(forKey: "key") as? String == key {
            if let contentToken, glow.value(forKey: "token") as? Int == contentToken { return }
            glow.sublayers?.first?.mask?.contents = shape(of: view, without: glow)
            glow.setValue(contentToken, forKey: "token")
            return
        }
        if !dark, let mask = view.layer.mask, mask.name == name, mask.value(forKey: "key") as? String == key { return }
        if view.layer.mask?.name == name { view.layer.mask = nil }
        glow?.removeFromSuperlayer()

        let sweep = sweep(size: size, spread: spread, dark: dark)
        if dark {
            let layer = CALayer(), ink = CALayer(), shape = CALayer()
            layer.name = name
            layer.frame = view.bounds
            ink.frame = view.bounds
            ink.backgroundColor = ChatPalette.label.resolvedColor(with: view.traitCollection).cgColor
            shape.frame = view.bounds
            shape.contents = self.shape(of: view, without: nil)
            shape.contentsScale = view.traitCollection.displayScale
            ink.mask = shape
            layer.addSublayer(ink)
            layer.mask = sweep
            layer.setValue(key, forKey: "key")
            layer.setValue(contentToken, forKey: "token")
            view.layer.addSublayer(layer)
        } else {
            sweep.name = name
            sweep.setValue(key, forKey: "key")
            view.layer.mask = sweep
        }
    }

    /// The moving band: as a mask, opaque where the text rests (light) or clear there (dark, over the text).
    private static func sweep(size: CGSize, spread: CGFloat, dark: Bool) -> CAGradientLayer {
        let slack = size.height / 2 * lean + 1
        let reach = size.width + slack                      // the width the band must cross besides itself
        let width = 2 * reach + spread + 2 * slack
        let layer = CAGradientLayer()
        layer.startPoint = CGPoint(x: 0, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.colors = resting.map { r in UIColor(white: 0, alpha: dark ? 1 - r : r + (1 - r) * 0.2).cgColor }
        layer.locations = stops.map { NSNumber(value: Double((slack + reach + spread * ($0 + 0.5)) / width)) }
        layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: size.height)
        layer.transform = CATransform3DMakeAffineTransform(CGAffineTransform(a: 1, b: 0, c: -lean, d: 1, tx: 0, ty: 0))
        let from = -slack - spread - reach - slack, to = -slack
        layer.position = CGPoint(x: from, y: size.height / 2)
        let pass = CFTimeInterval((track + spread + track * lean) / speed)
        let move = CABasicAnimation(keyPath: "position.x")   // motion-ok: off under Reduce Motion (`set`'s guard)
        move.fromValue = from
        move.toValue = to
        move.duration = pass
        let lap = CAAnimationGroup()
        lap.animations = [move]
        lap.duration = pass + rest
        lap.repeatCount = .infinity
        lap.timeOffset = fmod(CACurrentMediaTime(), pass + rest)
        lap.isRemovedOnCompletion = false
        layer.add(lap, forKey: name)
        return layer
    }

    /// How many snapshots `shape(of:)` has drawn (tests).
    private(set) static var snapshotCount = 0

    /// The view's own drawing, for the dark band to light up only the text.
    private static func shape(of view: UIView, without glow: CALayer?) -> CGImage? {
        snapshotCount += 1
        glow?.isHidden = true
        defer { glow?.isHidden = false }
        func draw(_ layer: CALayer) { layer.displayIfNeeded(); layer.sublayers?.forEach(draw) }   // this pass's text, not the last
        view.layoutIfNeeded()
        draw(view.layer)
        let format = UIGraphicsImageRendererFormat(for: view.traitCollection)
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { ctx in
            view.layer.render(in: ctx.cgContext)
        }.cgImage
    }
}
