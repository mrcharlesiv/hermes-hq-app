// The Star Map's Map (docs/spec/3x-morepages.md §17): a SwiftUI `Canvas` over the layout from
// HermesKit/Pages/More/StarMapLayout.swift. One finger pans, a pinch zooms about the fingers, a double tap frames the
// cluster under it (again: the whole map), a tap opens the nearest star within a 44 pt target. Only what is in view is
// drawn. VoiceOver gets one element per cluster, never thousands of stars; the List is its real path.

import SwiftUI
import UIKit

/// Category colours: the More tiles' hues (`S/phone-tab-bar.tsx:924-927`) and their system neighbours, all readable as
/// small dots on the light and the dark page. `StarMapLayout.paletteCount` of them.
enum StarMapPalette {
    static let hues: [UInt32] = [0x5E5CE6, 0x30B94D, 0x0A84FF, 0x00A2B8, 0x8E5CD9, 0xE5446D,
                                 0xA2845E, 0xF0902A, 0xC9A000, 0xE0483E, 0x1FAE8C, 0x7A8CA8]
    static let colors: [Color] = hues.map { Color(uiColor: MorePages.color($0)) }
    static func color(_ slot: Int) -> Color { colors[((slot % colors.count) + colors.count) % colors.count] }
}

/// The Map's view state: where it is looked at from, and how far its stars have flown in.
@MainActor @Observable
final class StarMapStage {
    var camera = StarMapCamera()
    /// The camera once a gesture or a move has ended: what the VoiceOver elements follow, so they are not laid out
    /// again on every frame of a pan.
    private(set) var settled = StarMapCamera()
    /// 0 → 1 as the stars fly out from their cluster's centre on the first show (1 at once under Reduce Motion).
    var appear: CGFloat = 1
    private(set) var layout = StarMapLayout()
    private(set) var size: CGSize = .zero
    /// The part of the canvas under the tab bar: nothing is framed there.
    private(set) var bottomInset: CGFloat = 0
    private(set) var fit: CGFloat = 1
    /// How much larger than at the standard text size the names are drawn.
    private(set) var names: CGFloat = 1
    @ObservationIgnored private var framed = -1
    @ObservationIgnored private var flewIn = false
    @ObservationIgnored var onFramed: (() -> Void)?

    var floor: CGFloat { StarMapCamera.floor(fit: fit) }
    private var usable: CGSize { CGSize(width: size.width, height: max(1, size.height - bottomInset)) }

    /// The page's layout or the canvas's size changed: a new layout (graph, bot or filter) is framed once.
    func show(_ layout: StarMapLayout, generation: Int, size: CGSize, bottomInset: CGFloat, names: CGFloat = 1) {
        let resized = size != self.size || bottomInset != self.bottomInset || names != self.names
        self.names = names
        self.size = size
        self.bottomInset = bottomInset
        guard size.width > 1, size.height > 1 else { return }
        if generation != framed {
            framed = generation
            self.layout = layout
            fit = layout.whole(in: usable, most: 8, names: names).scale
            camera = whole()
            settled = camera
            if !flewIn, !layout.stars.isEmpty {
                flewIn = true
                if !HQMotion.reduced {
                    appear = 0
                    HQMotion.withAnimation(.easeOut(duration: 0.7)) { appear = 1 }
                }
            }
            onFramed?()
        } else if resized {
            fit = layout.whole(in: usable, most: 8, names: names).scale
            camera.scale = max(floor, camera.scale)
            settled = camera
        }
    }

    /// The whole map in view: at 1× when it fits, smaller when it does not.
    func whole() -> StarMapCamera {
        var camera = layout.whole(in: usable, names: names)
        // The camera's centre is the middle of the whole canvas; the usable part ends above the tab bar.
        camera.center.y += bottomInset / 2 / camera.scale
        return camera
    }

    /// A gesture ended.
    func settle() { if settled != camera { settled = camera } }

    private func framing(_ rect: CGRect, most: CGFloat) -> StarMapCamera {
        let scale = min(most, max(floor, StarMapLayout.fit(rect, in: usable)))
        // The camera's centre is the middle of the whole canvas; the usable part ends above the tab bar.
        return StarMapCamera(scale: scale, center: CGPoint(x: rect.midX, y: rect.midY + bottomInset / 2 / scale))
    }

    // MARK: Gestures

    func pan(by translation: CGSize) {
        camera.pan(by: translation)
        camera.clamp(to: layout.bounds)
    }

    func pinch(by factor: CGFloat, at anchor: CGPoint) {
        camera.zoom(by: factor, at: anchor, in: size, floor: floor)
        camera.clamp(to: layout.bounds)
    }

    /// A flick: the map glides a little further (not under Reduce Motion).
    func glide(velocity: CGPoint) {
        guard !HQMotion.reduced, hypot(velocity.x, velocity.y) > 250 else { return }
        var next = camera
        next.pan(by: CGSize(width: velocity.x * 0.16, height: velocity.y * 0.16))
        next.clamp(to: layout.bounds)
        HQMotion.withAnimation(.easeOut(duration: 0.45)) { camera = next }
        settled = next
    }

    /// The star a tap at `point` means: the nearest within a 44 pt target.
    func star(at point: CGPoint) -> StarMapLayout.Star? {
        layout.hit(camera.world(point, in: size), reach: 22 / camera.scale).map { layout.stars[$0] }
    }

    /// Double tap: frame the cluster under the finger; when it already is framed (or there is none), the whole map.
    func doubleTap(at point: CGPoint) {
        var next = whole()
        if let index = layout.cluster(at: camera.world(point, in: size), reach: 30 / camera.scale) {
            let target = framing(cluster: index)
            if abs(target.scale - camera.scale) > 0.05 * camera.scale
                || hypot(target.center.x - camera.center.x, target.center.y - camera.center.y) * camera.scale > 24 {
                next = target
            }
        }
        move(to: next)
    }

    func zoom(toCluster index: Int) {
        guard layout.clusters.indices.contains(index) else { return }
        move(to: framing(cluster: index))
    }

    func zoom(by factor: CGFloat) {
        var next = camera
        next.zoom(by: factor, at: CGPoint(x: size.width / 2, y: size.height / 2), in: size, floor: floor)
        move(to: next)
    }

    /// A zoom key or button (round 2 #37): in or out a step about the middle; Fit is the whole map.
    func zoom(_ step: ZoomStep) {
        if let factor = step.factor { zoom(by: factor) } else { move(to: whole()) }
    }

    private func framing(cluster index: Int) -> StarMapCamera {
        let cluster = layout.clusters[index]
        let rect = CGRect(x: cluster.center.x - cluster.radius, y: cluster.center.y - cluster.radius,
                          width: cluster.radius * 2, height: cluster.radius * 2)
        return framing(rect.insetBy(dx: -28, dy: -28), most: StarMapCamera.maxZoom)
    }

    private func move(to next: StarMapCamera) {
        // Reduce Motion: the map is simply at its new place (HQMotion gives no animation then).
        HQMotion.withAnimation(.easeInOut(duration: 0.35)) { camera = next }
        settled = next
    }
}

// MARK: - The view

struct StarMapCanvas: View {
    let stage: StarMapStage
    var layout: StarMapLayout
    var generation: Int
    var onStar: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Names on the map grow with the text size up to here: past it they would crowd out the stars they name (the
    /// List has every name at the full size).
    static let largestNames = DynamicTypeSize.xxxLarge

    var body: some View {
        GeometryReader { proxy in
            let size = CGSize(width: proxy.size.width, height: proxy.size.height + proxy.safeAreaInsets.bottom)
            let inset = proxy.safeAreaInsets.bottom
            let category = UIContentSizeCategory(min(typeSize, Self.largestNames))
            let names = UIFontMetrics(forTextStyle: .caption1).scaledValue(for: 1000, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)) / 1000
            ZStack(alignment: .topLeading) {
                StarMapDrawing(layout: stage.layout, scale: stage.camera.scale, centerX: stage.camera.center.x,
                               centerY: stage.camera.center.y, appear: stage.appear, style: .current())
                    .dynamicTypeSize(...Self.largestNames)
                    .accessibilityHidden(true)
                StarMapTouches(stage: stage, onStar: onStar)
                StarMapClusterElements(stage: stage)
                #if DEBUG
                StarMapDebugElements(stage: stage)
                #endif
            }
            .overlay(alignment: .topTrailing) {
                if DeviceWord.isMac { StarMapZoomButtons(stage: stage).padding(12) }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .ignoresSafeArea(.container, edges: .bottom)
            .onAppear { stage.show(layout, generation: generation, size: size, bottomInset: inset, names: names) }
            .onChange(of: generation) { stage.show(layout, generation: generation, size: size, bottomInset: inset, names: names) }
            .onChange(of: names) { stage.show(layout, generation: generation, size: size, bottomInset: inset, names: names) }
            .onChange(of: size) { stage.show(layout, generation: generation, size: size, bottomInset: inset, names: names) }
        }
    }
}

/// Colours and fonts the drawing uses, read from the theme on the main actor before the canvas draws.
struct StarMapStyle {
    var label: Color
    var secondary: Color
    var page: Color
    var clusterFont: Font
    var starFont: Font
    var hairline: CGFloat

    static func current() -> StarMapStyle {
        StarMapStyle(label: .hqLabel, secondary: .hqLabel2, page: .hqGroupedPage,
                     clusterFont: Font.hq(.caption).weight(.semibold), starFont: Font.hq(.caption2),
                     hairline: 1 / max(1, UITraitCollection.current.displayScale))
    }
}

/// The canvas. `Animatable`, so a double tap's move and the fly-in are drawn frame by frame.
struct StarMapDrawing: View, @MainActor Animatable {
    var layout: StarMapLayout
    var scale: CGFloat
    var centerX: CGFloat
    var centerY: CGFloat
    var appear: CGFloat
    var style: StarMapStyle

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(scale, appear), AnimatablePair(centerX, centerY)) }
        set {
            scale = newValue.first.first
            appear = newValue.first.second
            centerX = newValue.second.first
            centerY = newValue.second.second
        }
    }

    var body: some View {
        let layout = layout, style = style, appear = min(1, max(0, appear))
        let camera = StarMapCamera(scale: max(0.01, scale), center: CGPoint(x: centerX, y: centerY))
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            #if DEBUG
            let started = StarMapProbe.isRunning ? CACurrentMediaTime() : 0
            #endif
            let drawn = Self.draw(&context, size: size, layout: layout, camera: camera, appear: appear, style: style)
            #if DEBUG
            StarMapProbe.noteDrawn(stars: drawn)
            if started > 0 { StarMapProbe.noteDraw(seconds: CACurrentMediaTime() - started) }
            #endif
        }
        .background(style.page)
    }

    /// Most star names drawn at once: the most used in view come first.
    static let labelLimit = 60
    /// Most links drawn at once.
    static let edgeLimit = 1500
    /// Above this many stars in view the soft halos are left out.
    static let haloLimit = 500

    /// Draws what is in view; returns how many stars that was.
    @discardableResult
    static func draw(_ context: inout GraphicsContext, size: CGSize, layout: StarMapLayout, camera: StarMapCamera,
                     appear: CGFloat, style: StarMapStyle) -> Int {
        guard !layout.stars.isEmpty else { return 0 }
        let visible = camera.visible(in: size, margin: 28)
        // Fly-in: a star starts at its cluster's centre.
        func place(_ star: StarMapLayout.Star) -> CGPoint {
            guard appear < 1 else { return camera.screen(star.point, in: size) }
            let center = layout.clusters[star.cluster].center
            return camera.screen(CGPoint(x: center.x + (star.point.x - center.x) * appear,
                                         y: center.y + (star.point.y - center.y) * appear), in: size)
        }

        // Links: hairlines at 25 %.
        // With more than a few hundred in view they would be a grey fog: then they are drawn fainter, and no more
        // than `edgeLimit` of them.
        if !layout.edges.isEmpty {
            var lines = Path()
            var count = 0
            for edge in layout.edges {
                let a = layout.stars[Int(edge.a)], b = layout.stars[Int(edge.b)]
                if max(a.point.x, b.point.x) < visible.minX || min(a.point.x, b.point.x) > visible.maxX
                    || max(a.point.y, b.point.y) < visible.minY || min(a.point.y, b.point.y) > visible.maxY { continue }
                lines.move(to: place(a))
                lines.addLine(to: place(b))
                count += 1
                if count >= edgeLimit { break }
            }
            let calm = count <= 250 ? 1 : max(0.3, (250 / CGFloat(count)).squareRoot())
            context.stroke(lines, with: .color(style.secondary.opacity(0.25 * calm * appear)), lineWidth: style.hairline)
        }

        // Stars: one path per colour.
        let inView = layout.stars(in: visible)
        let slots = StarMapPalette.colors.count
        var dots = [Path](repeating: Path(), count: slots)
        var halos = [Path](repeating: Path(), count: slots)
        var rings = Path()
        let withHalos = inView.count <= haloLimit
        for member in inView {
            let star = layout.stars[Int(member)]
            let point = place(star)
            let radius = camera.starRadius(star.radius)
            let slot = ((layout.clusters[star.cluster].color % slots) + slots) % slots
            let box = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            if radius < 1.1 { dots[slot].addRect(box) } else { dots[slot].addEllipse(in: box) }
            if withHalos, star.useCount > 0 { halos[slot].addEllipse(in: box.insetBy(dx: -radius * 0.9, dy: -radius * 0.9)) }
            // A pinned star's ring, once the star is large enough on screen to carry one.
            if star.pinned, radius >= 2 { rings.addEllipse(in: box.insetBy(dx: -2.5, dy: -2.5)) }
        }
        for slot in 0..<slots where !dots[slot].isEmpty {
            let color = StarMapPalette.colors[slot]
            if !halos[slot].isEmpty { context.fill(halos[slot], with: .color(color.opacity(0.16 * appear))) }
            context.fill(dots[slot], with: .color(color.opacity(appear)))
        }
        if !rings.isEmpty { context.stroke(rings, with: .color(style.label.opacity(0.7 * appear)), lineWidth: 1) }

        // Cluster names, on the outer side of each cluster (the far side from the middle of the ring).
        var taken: [CGRect] = []
        for cluster in layout.clusters {
            let edge = camera.screen(CGPoint(x: cluster.center.x + cluster.labelSide.x * cluster.radius,
                                             y: cluster.center.y + cluster.labelSide.y * cluster.radius), in: size)
            let point = CGPoint(x: edge.x + cluster.labelSide.x * StarMapLayout.labelDrop, y: edge.y + cluster.labelSide.y * StarMapLayout.labelDrop)
            guard point.x > -120, point.x < size.width + 120, point.y > -30, point.y < size.height + 30 else { continue }
            let anchor = cluster.labelAnchor
            let text = context.resolve(Text(cluster.title).font(style.clusterFont).foregroundStyle(style.secondary.opacity(appear)))
            let measured = text.measure(in: CGSize(width: 240, height: 60))
            // A name that would run into a neighbour's (larger text sizes) moves further out until it is clear.
            var place = point
            var box = CGRect(x: place.x - measured.width * anchor.x, y: place.y - measured.height * anchor.y,
                             width: measured.width, height: measured.height)
            var tries = 0
            while tries < 6, taken.contains(where: { $0.intersects(box.insetBy(dx: -2, dy: 0)) }) {
                tries += 1
                place = CGPoint(x: place.x + cluster.labelSide.x * 8, y: place.y + cluster.labelSide.y * 8)
                box.origin = CGPoint(x: place.x - measured.width * anchor.x, y: place.y - measured.height * anchor.y)
            }
            taken.append(box)
            context.draw(text, at: place, anchor: UnitPoint(x: anchor.x, y: anchor.y))
        }

        // Star names above 1.6×: the most used first, and a name is left out where it would run into one already drawn.
        if camera.scale > StarMapCamera.labelZoom, appear >= 1 {
            let fade = min(1, (camera.scale - StarMapCamera.labelZoom) / 0.25)
            let ranked = inView.sorted {
                let a = layout.stars[Int($0)], b = layout.stars[Int($1)]
                return a.useCount != b.useCount ? a.useCount > b.useCount : $0 < $1
            }.prefix(labelLimit)
            for member in ranked {
                let star = layout.stars[Int(member)]
                let point = camera.screen(star.point, in: size)
                let name = star.label.count > 24 ? star.label.prefix(23) + "…" : star.label
                let text = context.resolve(Text(name).font(style.starFont).foregroundStyle(style.label.opacity(0.9 * fade)))
                let measured = text.measure(in: CGSize(width: 260, height: 60))
                let top = point.y + camera.starRadius(star.radius) + 3
                let box = CGRect(x: point.x - measured.width / 2, y: top, width: measured.width, height: measured.height)
                if taken.contains(where: { $0.intersects(box.insetBy(dx: -4, dy: -1)) }) { continue }
                taken.append(box)
                context.draw(text, at: CGPoint(x: point.x, y: top), anchor: .top)
            }
        }
        return inView.count
    }
}

/// [mac] A mouse has no pinch (round 2 #37): Zoom In, Zoom Out and Whole Map at the map's top corner. = / - / 0 and
/// the scroll wheel do the same (`StarMapTouchView`).
struct StarMapZoomButtons: View {
    let stage: StarMapStage

    var body: some View {
        VStack(spacing: 0) {
            button("plus.magnifyingglass", "Zoom In", "starmap.zoomIn", .zoomIn)
            Divider().frame(width: 28)
            button("minus.magnifyingglass", "Zoom Out", "starmap.zoomOut", .zoomOut)
            Divider().frame(width: 28)
            button("arrow.up.left.and.arrow.down.right", "Whole Map", "starmap.whole", .fit)
        }
        .hqGlassEffect(in: Capsule())
    }

    private func button(_ symbol: String, _ label: String, _ identifier: String, _ step: ZoomStep) -> some View {
        Button { stage.zoom(step) } label: {
            Image(systemName: symbol)
                .font(Font.hq(.body))
                .foregroundStyle(Color.hqLabel)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Touches

/// Pan, pinch, tap and double tap, as UIKit recognizers (a pinch zooms about the fingers and pans with them).
struct StarMapTouches: UIViewRepresentable {
    let stage: StarMapStage
    var onStar: (String) -> Void

    func makeUIView(context: Context) -> StarMapTouchView { StarMapTouchView(stage: stage) }
    func updateUIView(_ view: StarMapTouchView, context: Context) { view.onStar = onStar }
}

final class StarMapTouchView: UIView, UIGestureRecognizerDelegate {
    private let stage: StarMapStage
    var onStar: ((String) -> Void)?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    private lazy var doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))

    init(stage: StarMapStage) {
        self.stage = stage
        super.init(frame: .zero)
        backgroundColor = .clear
        pan.maximumNumberOfTouches = 2
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        for recognizer in [pan, pinch, tap, doubleTap] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
        #if targetEnvironment(macCatalyst)
        wheels.forEach(addGestureRecognizer)
        #endif
        isAccessibilityElement = true
        accessibilityIdentifier = "starmap.canvas"
        accessibilityLabel = "Star Map"
        accessibilityTraits = .adjustable
        accessibilityHint = "Swipe up or down to zoom. The List shows every skill."
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// While the Map is on show a drag anywhere on it pans the map, so the stack's swipe-back from the middle of the
    /// page is off (as on the app's editors); the swipe from the screen's edge and the Back button stay.
    private weak var stack: UINavigationController?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            var responder: UIResponder? = self
            while let next = responder?.next, !(next is UINavigationController) { responder = next }
            stack = responder?.next as? UINavigationController
            stack?.interactiveContentPopGestureRecognizer?.isEnabled = false
            #if targetEnvironment(macCatalyst)
            DispatchQueue.main.async { [weak self] in if self?.window != nil { _ = self?.becomeFirstResponder() } }
            #endif
        } else {
            stack?.interactiveContentPopGestureRecognizer?.isEnabled = true
            stack = nil
        }
    }

    /// The zoom, spoken as a percentage (the UI tests read it too).
    override var accessibilityValue: String? {
        get { "\(Int((stage.camera.scale * 100).rounded())) percent" }
        set {}
    }

    /// The part clear of the tab bar (the map itself is drawn on under it).
    override var accessibilityFrame: CGRect {
        get {
            var clear = bounds
            clear.size.height = max(1, clear.height - stage.bottomInset)
            return UIAccessibility.convertToScreenCoordinates(clear, in: self)
        }
        set {}
    }

    override func accessibilityIncrement() { stage.zoom(by: 1.5) }
    override func accessibilityDecrement() { stage.zoom(by: 1 / 1.5) }

    #if targetEnvironment(macCatalyst)
    // MARK: Mouse and keys ([mac] round 2 #37)

    /// A trackpad's two-finger scroll pans the map, as a drag does; a mouse wheel, or any scroll with ⌘ held, zooms
    /// about the pointer, as in Maps. A trackpad pinch stays the pinch above.
    private lazy var wheels: [UIPanGestureRecognizer] = [UIScrollTypeMask.continuous, .discrete].map { types in
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheeled(_:)))
        wheel.allowedScrollTypesMask = types
        wheel.allowedTouchTypes = []   // scrolls only: a click and a drag stay the pan above
        return wheel
    }
    private var wheelLast = CGPoint.zero

    @objc private func wheeled(_ wheel: UIPanGestureRecognizer) {
        let at = wheel.translation(in: self)
        if wheel.state == .began { wheelLast = .zero; _ = becomeFirstResponder() }
        let moved = CGSize(width: at.x - wheelLast.x, height: at.y - wheelLast.y)
        wheelLast = at
        switch wheel.state {
        case .began, .changed:
            if wheel.allowedScrollTypesMask == .discrete || wheel.modifierFlags.contains(.command) {
                let factor = ZoomStep.scrollFactor(moved.height, discrete: wheel.allowedScrollTypesMask == .discrete)
                if factor != 1 { stage.pinch(by: factor, at: wheel.location(in: self)) }
            } else {
                stage.pan(by: moved)
            }
        case .ended, .cancelled, .failed:
            stage.settle()
        default: break
        }
    }

    /// The map holds the keyboard while it is on show (and after a click on it), so = / - / 0 reach it.
    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [("=", [], "Zoom In"), ("+", .shift, "Zoom In"), ("-", [], "Zoom Out"), ("0", [], "Whole Map")]
            .map { (input: String, flags: UIKeyModifierFlags, title: String) in
                let command = UIKeyCommand(title: title, action: #selector(zoomKey(_:)), input: input, modifierFlags: flags)
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
    }

    @objc private func zoomKey(_ command: UIKeyCommand) {
        guard let step = command.input.flatMap(ZoomStep.forKey) else { return }
        stage.zoom(step)
    }
    #endif

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        #if targetEnvironment(macCatalyst)
        if recognizer.state == .began { _ = becomeFirstResponder() }
        #endif
        switch recognizer.state {
        case .changed:
            let moved = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            stage.pan(by: CGSize(width: moved.x, height: moved.y))
        case .ended:
            if pinch.state == .possible || pinch.state == .failed {
                stage.glide(velocity: recognizer.velocity(in: self))
            }
            stage.settle()
        case .cancelled, .failed:
            stage.settle()
        default: break
        }
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .ended || recognizer.state == .cancelled { stage.settle() }
        guard recognizer.state == .changed, recognizer.scale.isFinite, recognizer.scale > 0 else { return }
        stage.pinch(by: recognizer.scale, at: recognizer.location(in: self))
        recognizer.scale = 1
    }

    /// A tap waits to see that it is not the first of a double tap (in a cluster every point is near some star).
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        #if targetEnvironment(macCatalyst)
        _ = becomeFirstResponder()
        #endif
        guard recognizer.state == .ended, let star = stage.star(at: recognizer.location(in: self)) else { return }
        onStar?(star.id)
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        stage.doubleTap(at: recognizer.location(in: self))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view === self
    }

    /// The map's pan goes first over the stack's swipe-back from anywhere on the page…
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pan && other.view !== self && !(other is UIScreenEdgePanGestureRecognizer) && other is UIPanGestureRecognizer
    }

    /// …and gives way to the swipe-back from the screen's edge.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pan && other is UIScreenEdgePanGestureRecognizer
    }
}

// MARK: - VoiceOver

/// One element per cluster in view ("Coding, 42 skills"); activating it frames the cluster.
struct StarMapClusterElements: View {
    let stage: StarMapStage
    static let limit = 40

    var body: some View {
        let layout = stage.layout, camera = stage.settled, size = stage.size
        let visible = camera.visible(in: size)
        ForEach(Array(layout.clusters.enumerated().prefix(Self.limit)), id: \.element.category) { index, cluster in
            if visible.contains(cluster.center) {
                let point = camera.screen(cluster.center, in: size)
                let side = min(max(44, cluster.radius * 2 * camera.scale), min(size.width, size.height))
                Color.clear
                    .frame(width: side, height: side)
                    .contentShape(Rectangle())
                    .accessibilityElement()
                    .accessibilityLabel(StarMapRules.clusterSpoken(title: cluster.title, count: cluster.count, memory: cluster.isMemory))
                    .accessibilityHint("Zooms to this group")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { stage.zoom(toCluster: index) }
                    .accessibilityIdentifier("starmap.cluster.\(cluster.category)")
                    .position(point)
                    .allowsHitTesting(false)
            }
        }
    }
}
