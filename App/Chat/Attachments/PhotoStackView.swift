import UIKit

// Several photos in one message as a stack you swipe through (owner 2026-10-30: "when there are multiple images sent by
// a user or bot … make them beautifully sit on top of each other where you can swipe through them"). One card per
// photo, each its own photo's shape inside the box `MediaLayout.stack` measured (a pile of prints, never letterboxed),
// so the row never changes height; the two cards under the top one fan out a few degrees either way. Swipe left and the top card follows the finger, tilting from where it was held,
// flies off and tucks in at the back; swipe right and the bottom card slides out from under the pile and lands on top.
// It goes round (after the last photo comes the first), springs back from a short drag, and ticks once per flip. Each
// card carries its own "2/5". A tap opens the viewer on the top photo, and closing the viewer on another one leaves
// that one on top (`show`), so the zoom lands on it. VoiceOver: one adjustable element. The Mac: a trackpad's
// two-finger swipe, and ‹ › over the photo on hover. Reduce Motion: the photos cross-fade.

final class PhotoStackView: UIView, UIGestureRecognizerDelegate {
    /// A tile made by the media view (its host, hold menu and drag out).
    var makeTile: (() -> MediaTileView)?
    /// VoiceOver's activate and the Mac's Return: the viewer on the top photo.
    var onOpen: (() -> Void)?
    /// 0 at rest, up to 1 while a card is mid-flip: the bubble's time capsule fades with it.
    var onMotion: ((CGFloat) -> Void)?
    /// The pile came to rest (a new top card, or the same one back in place): the time's capsule follows the top card.
    var onSettle: (() -> Void)?

    private(set) var items: [MediaItem] = []
    /// The photo on top (an index into `items`).
    private(set) var top = 0
    private var cards: [StackCardView] = []
    /// The stack's box (every card fits inside it, centred).
    private var card = CGRect.zero
    /// Each card's size (`cardSize`).
    private var sizes: [CGSize] = []
    private var radius: CGFloat = 12
    /// Which top photo each message's stack shows, so a cell scrolled away and back (or reused) keeps it.
    private static var remembered: [String: Int] = [:]
    private var key = ""

    private let pan = UIPanGestureRecognizer()
    /// +1 when the card was taken above its middle, -1 below: which way it tilts as it is dragged.
    private var grab: CGFloat = 1
    private var dragging = false
    /// Bumped by every flip and interruption: a finished animation from an older one changes nothing.
    private var generation = 0
    private var moving = false
    #if targetEnvironment(macCatalyst)
    private var arrows: [UIButton] = []
    #endif

    /// The cards' fan: the second card's turn (radians; the third turns the other way), from the card's size so their
    /// corners stay within the room `MediaLayout.stackPadY` keeps above and below and ~10 pt beside.
    private var fan: CGFloat = 0
    /// How far a card dragged a whole card's width tilts.
    private static let tilt: CGFloat = 12 * .pi / 180
    /// A flip needs the card dragged this share of its width, or a flick.
    private static let commitShare: CGFloat = 0.28
    private static let flickSpeed: CGFloat = 450

    var tiles: [MediaTileView] { cards.map(\.tile) }
    var topTile: MediaTileView? { cards.indices.contains(top) ? cards[top].tile : nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.delegate = self
        #if targetEnvironment(macCatalyst)
        // [mac] The trackpad's two-finger swipe flips; a click-drag still drags the photo out (stress test #19).
        pan.allowedScrollTypesMask = .continuous
        pan.allowedTouchTypes = []
        #endif
        addGestureRecognizer(pan)
        isAccessibilityElement = true
        accessibilityTraits = [.image, .adjustable]
        #if targetEnvironment(macCatalyst)
        makeArrows()
        #endif
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: PhotoStackView, _) in
            view.cards.forEach { $0.restyle() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Configure

    /// Lays out `group` (its frame in the media view, `stack` the box its cards fit in). `key` names the message's stack for the
    /// remembered top photo. A configure mid-flip (a streaming reply re-laid out) leaves the cards where they are.
    func configure(_ group: MediaGroupLayout, key: String) {
        frame = group.frame
        let card = group.stack ?? CGRect(origin: .zero, size: group.frame.size)
        let newItems = group.tiles.map(\.item)
        let sizes = newItems.map { Self.cardSize($0, in: card.size) }
        let sameShape = card == self.card && sizes == self.sizes
        self.card = card
        self.sizes = sizes
        radius = group.radius ?? 12
        items = newItems
        fan = Self.fan(for: card.size)
        if key != self.key {
            self.key = key
            finishMotion()
            top = Self.remembered[key] ?? 0
        }
        top = items.isEmpty ? 0 : min(top, items.count - 1)

        while cards.count < items.count, let tile = makeTile?() {
            let made = StackCardView(tile: tile)
            insertSubview(made, at: 0)
            cards.append(made)
        }
        while cards.count > items.count {
            let gone = cards.removeLast()
            gone.tile.prepareForReuse()
            gone.removeFromSuperview()
        }
        let n = items.count
        for (i, view) in cards.enumerated() {
            let size = sizes[i]
            if !sameShape || view.bounds.size != size {
                let kept = view.transform
                view.transform = .identity
                view.bounds = CGRect(origin: .zero, size: size)
                let at = frame(of: size)
                view.center = CGPoint(x: at.midX, y: at.midY)
                view.transform = kept
            }
            view.radius = radius
            view.count = "\(i + 1)/\(n)"
            view.tile.deferred = !Self.loads(depth: depth(i), count: n)
            view.tile.configure(items[i], frame: CGRect(origin: .zero, size: size), autoFit: true)
        }
        if !dragging && !moving { rest() }
        updateAccessibility()
    }

    func prepareForReuse() {
        finishMotion()
        for view in cards { view.tile.prepareForReuse() }
    }

    /// Brings photo `index` to the top at once (the viewer closing on it: its zoom lands on the top card).
    func show(_ index: Int) {
        guard items.indices.contains(index), index != top || moving || dragging else { return }
        finishMotion()
        top = index
        remember()
        rest()
        updateAccessibility()
    }

    /// A card's size: its photo's own shape fitted inside the stack's box (the photos' middle shape), so photos of
    /// different shapes pile up like prints instead of showing bands; never under half the box either way (a photo
    /// narrower than that shows whole on a blur of itself, `MediaTileView`). Unknown sizes take the whole box.
    static func cardSize(_ item: MediaItem, in box: CGSize) -> CGSize {
        guard let w = item.attachment.pixelWidth, let h = item.attachment.pixelHeight, w > 0, h > 0,
              box.width > 0, box.height > 0 else { return box }
        let aspect = CGFloat(w) / CGFloat(h)
        let fitted = aspect >= box.width / box.height
            ? CGSize(width: box.width, height: box.width / aspect)
            : CGSize(width: box.height * aspect, height: box.height)
        return CGSize(width: max(fitted.width, box.width / 2).rounded(), height: max(fitted.height, box.height / 2).rounded())
    }

    /// The top card at rest, in the stack's coordinates.
    var topCardFrame: CGRect { sizes.indices.contains(top) ? frame(of: sizes[top]) : card }

    /// A card of `size` at rest: centred in the box, on whole points.
    private func frame(of size: CGSize) -> CGRect {
        CGRect(x: card.minX + ((card.width - size.width) / 2).rounded(), y: card.minY + ((card.height - size.height) / 2).rounded(),
               width: size.width, height: size.height)
    }

    /// How far in the top card's bottom-trailing corner sits from the box's (zero or less either way).
    var cornerOffset: CGVector {
        let top = topCardFrame
        return CGVector(dx: top.maxX - card.maxX, dy: top.maxY - card.maxY)
    }

    /// The second card's turn for a card of `size`: as much of 4.5° as keeps its corners inside the room around it.
    static func fan(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 0 }
        let room = (vertical: MediaLayout.stackPadY - 2, sideways: CGFloat(10))
        var degrees: CGFloat = 4.5
        while degrees > 1 {
            let a = degrees * .pi / 180, s = rest(1, fan: a).scale
            let tall = s * (size.width * sin(a) + size.height * cos(a)), wide = s * (size.width * cos(a) + size.height * sin(a))
            if (tall - size.height) / 2 <= room.vertical && (wide - size.width) / 2 <= room.sideways { break }
            degrees -= 0.25
        }
        return degrees * .pi / 180
    }

    // MARK: Poses

    /// Where a card at `depth` under the top one rests: the top one straight, the next turned one way and the third the
    /// other, a touch smaller; any deeper ones wait out of sight under the third.
    private static func rest(_ depth: Int, fan: CGFloat) -> Pose {
        switch depth {
        case 0: Pose()
        case 1: Pose(angle: fan, scale: 0.985, pill: 0)
        default: Pose(angle: -fan * 0.8, scale: 0.97, alpha: depth == 2 ? 1 : 0, pill: 0)
        }
    }

    private func rest(_ depth: Int) -> Pose { Self.rest(depth, fan: fan) }

    private func depth(_ i: Int) -> Int { (i - top + items.count) % max(1, items.count) }

    /// [perf] Whether the card at `depth` loads its photo: the three you see, the one a left swipe brings up under them
    /// (it fades in with the drag) and the bottom one a right swipe pulls out. The rest wait (`MediaTileView.deferred`),
    /// so a 16-photo stack doesn't download and decode 16 pictures to show three.
    static func loads(depth: Int, count: Int) -> Bool { depth <= 3 || depth == count - 1 }

    private func loadNearTop() {
        for (i, view) in cards.enumerated() { view.tile.deferred = !Self.loads(depth: depth(i), count: cards.count) }
    }

    /// Every card at rest, in pile order (the top one in front), only the top one taking touches.
    private func rest() {
        loadNearTop()
        for (i, view) in cards.enumerated() {
            let d = depth(i)
            view.apply(rest(d))
            view.isHidden = rest(d).alpha == 0
            view.tile.isUserInteractionEnabled = d == 0
        }
        order()
        #if targetEnvironment(macCatalyst)
        placeArrows()
        #endif
        onSettle?()
    }

    private func order() {
        let n = cards.count
        guard n > 0 else { return }
        for d in stride(from: n - 1, through: 0, by: -1) { bringSubviewToFront(cards[(top + d) % n]) }
        #if targetEnvironment(macCatalyst)
        arrows.forEach { bringSubviewToFront($0) }
        #endif
    }

    // MARK: Dragging

    /// Mostly sideways only: the chat keeps every vertical drag. (The view's own method, which the pan's delegate shares.)
    override func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool {
        guard gr === pan else { return super.gestureRecognizerShouldBegin(gr) }
        guard items.count > 1 else { return false }
        let v = pan.velocity(in: self)
        return abs(v.x) > abs(v.y) * 1.2
    }

    /// A sideways drag on the photos is theirs: the chat's full-width swipe back waits for it to fail.
    func gestureRecognizer(_ gr: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard gr === pan else { return false }
        var responder: UIResponder? = self
        while let r = responder {
            if let nav = r as? UINavigationController { return other === nav.interactiveContentPopGestureRecognizer }
            responder = r.next
        }
        return false
    }

    @objc private func panned(_ gr: UIPanGestureRecognizer) {
        let t = gr.translation(in: self)
        switch gr.state {
        case .began:
            finishMotion()
            dragging = true
            let start = CGPoint(x: gr.location(in: self).x - t.x, y: gr.location(in: self).y - t.y)
            grab = start.y <= card.midY ? 1 : -1
            for view in cards { view.isHidden = false }
            cards.forEach { $0.tile.isUserInteractionEnabled = false }
            follow(t)
        case .changed:
            follow(t)
        case .ended:
            dragging = false
            let v = gr.velocity(in: self)
            let flicked = abs(v.x) > Self.flickSpeed && v.x * t.x > 0 && abs(t.x) > 8
            let flickedBack = abs(v.x) > Self.flickSpeed && v.x * t.x < 0
            let far = abs(t.x) > card.width * Self.commitShare && !flickedBack
            if HQMotion.reduced {
                if abs(t.x) > 24 || flicked { flip(forward: t.x < 0) } else { rest(); onMotion?(0) }
            } else if flicked || far {
                if t.x < 0 { throwTop(from: t, velocity: v) } else { pullBottom(from: t, velocity: v) }
            } else {
                springBack(from: t, velocity: v)
            }
        default:
            dragging = false
            springBack(from: t, velocity: .zero)
        }
    }

    /// The pile under the finger: dragging left takes the top card with it and the ones under it rise a place;
    /// dragging right draws the bottom card out from under the pile and the rest settle a place deeper.
    private func follow(_ t: CGPoint) {
        guard !HQMotion.reduced, cards.count > 1 else { return }
        let n = cards.count, w = max(1, card.width)
        let lift = t.y * 0.18
        let p = min(1, abs(t.x) / (w * 0.6))
        let bottom = (top - 1 + n) % n
        for (i, view) in cards.enumerated() {
            let d = depth(i)
            var pose: Pose
            if t.x <= 0 {
                if d == 0 {
                    pose = Pose(x: t.x, y: lift, angle: t.x / w * Self.tilt * grab)
                } else {
                    pose = .mix(rest(d), rest(d - 1), p)
                }
            } else if i == bottom {
                let base = rest(min(d, 2))
                pose = base
                pose.x = t.x
                pose.y = lift
                pose.angle = base.angle + (t.x / w * Self.tilt * grab - base.angle) * p
                pose.scale = base.scale + (1 - base.scale) * p
                pose.alpha = 1
                pose.pill = p
            } else {
                pose = .mix(rest(d), rest(d + 1), p)
            }
            view.apply(pose)
        }
        onMotion?(p)
    }

    // MARK: Flipping

    /// The next (`forward`) or previous photo, as a swipe would bring it: the Mac's ‹ ›, VoiceOver, Reduce Motion.
    func flip(forward: Bool) {
        guard items.count > 1 else { return }
        if HQMotion.reduced {
            finishMotion()
            top = (top + (forward ? 1 : items.count - 1)) % items.count
            flipped()
            UIView.transition(with: self, duration: HQMotion.fade, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.rest()
            }
            onMotion?(0)
            return
        }
        finishMotion()
        grab = 1
        if forward { throwTop(from: .zero, velocity: .zero) } else { pullBottom(from: .zero, velocity: .zero) }
    }

    /// The top card flies off to the left (on with the finger's speed), goes under the pile and settles at the back;
    /// the cards under it each rise a place meanwhile.
    private func throwTop(from t: CGPoint, velocity v: CGPoint) {
        let n = cards.count, old = top
        guard n > 1 else { return }
        top = (top + 1) % n
        flipped()
        let flying = cards[old]
        let out = Pose(x: -(card.width + 16), y: t.y * 0.18 + 6 * grab, angle: -Self.tilt * grab, pill: 1)
        travel(flying, to: out, from: t.x, velocity: v.x) { [weak self] in
            guard let self else { return Pose() }
            self.order()
            return self.rest(self.depth(old))
        }
    }

    /// The bottom card slides out to the right from under the pile, comes over it and lands on top; the others each
    /// go a place deeper meanwhile.
    private func pullBottom(from t: CGPoint, velocity v: CGPoint) {
        let n = cards.count
        guard n > 1 else { return }
        top = (top - 1 + n) % n
        flipped()
        let pulled = cards[top]
        pulled.isHidden = false
        let out = Pose(x: card.width + 16, y: t.y * 0.18 - 6 * grab, angle: Self.tilt * grab, pill: 0.6)
        travel(pulled, to: out, from: t.x, velocity: v.x) { [weak self] in
            guard let self else { return Pose() }
            self.order()
            return self.rest(0)
        }
    }

    /// The flip's motion: every other card springs to its new place while `mover` goes out to `out`, then (with the pile
    /// re-ordered by `landing`) springs to where `landing` says.
    private func travel(_ mover: StackCardView, to out: Pose, from x: CGFloat, velocity vx: CGFloat, landing: @escaping () -> Pose) {
        let gen = beginMotion()
        for view in cards where view !== mover { view.isHidden = false }
        let others = cards.enumerated().filter { $0.element !== mover }
        HQMotion.spring(duration: 0.5, damping: 0.82) {
            for (i, view) in others { view.apply(self.rest(self.depth(i))) }
            self.onMotion?(1)
        }
        let distance = max(1, abs(out.x - x))
        let toward = vx * (out.x - x >= 0 ? 1 : -1)
        HQMotion.spring(duration: 0.26, damping: 1, velocity: min(12, max(0, toward / distance))) {
            mover.apply(out)
        } completion: { _ in
            guard gen == self.generation else { return }
            let target = landing()
            HQMotion.spring(duration: 0.5, damping: 0.8) {
                mover.apply(target)
            } completion: { _ in
                guard gen == self.generation else { return }
                self.endMotion()
            }
        }
    }

    /// A drag that wasn't far or fast enough: everything springs back, the finger's speed carried into it.
    private func springBack(from t: CGPoint, velocity v: CGPoint) {
        let gen = beginMotion()
        let toward = t.x == 0 ? 0 : max(0, -v.x / t.x)
        HQMotion.spring(duration: 0.45, damping: 0.78, velocity: min(10, toward)) {
            for (i, view) in self.cards.enumerated() { view.apply(self.rest(self.depth(i))) }
            self.onMotion?(0)
        } completion: { _ in
            guard gen == self.generation else { return }
            self.endMotion()
        }
    }

    private func flipped() {
        loadNearTop()
        remember()
        Haptics.play(.selection)
        updateAccessibility()
        AppLog.trace("chatui", "photo stack flipped to \(top + 1) of \(items.count)")
    }

    private func remember() {
        if Self.remembered.count > 2000 { Self.remembered.removeAll() }
        Self.remembered[key] = top
    }

    private func beginMotion() -> Int {
        generation += 1
        moving = true
        return generation
    }

    private func endMotion() {
        moving = false
        rest()
        UIView.animate(withDuration: HQMotion.fade) { self.onMotion?(0) }   // motion-ok: a fade
    }

    /// Stops a flip where it would have ended (a new drag, a configure for another message, the viewer closing).
    private func finishMotion() {
        guard moving else { return }
        generation += 1
        moving = false
        for view in cards { view.layer.removeAllAnimations() }
        rest()
        onMotion?(0)
    }

    // MARK: Accessibility

    private func updateAccessibility() {
        let n = items.count
        accessibilityLabel = n == 1 ? items.first?.label : "\(n) photos"
        accessibilityValue = items.indices.contains(top) ? "\(top + 1) of \(n), \(items[top].label)" : nil
        accessibilityHint = "Opens the photo"   // VoiceOver says itself that a swipe up or down flips (adjustable)
    }

    override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(card, in: self) }
        set { super.accessibilityFrame = newValue }
    }

    override func accessibilityIncrement() { flip(forward: true) }
    override func accessibilityDecrement() { flip(forward: false) }

    override func accessibilityActivate() -> Bool {
        onOpen?()
        return true
    }

    // MARK: [mac] Arrows

    #if targetEnvironment(macCatalyst)
    /// [mac] ‹ and › at the top card's sides, shown while the pointer is over the stack.
    private func makeArrows() {
        for forward in [false, true] {
            let button = UIButton(configuration: Self.arrowConfig(forward: forward), primaryAction: UIAction { [weak self] _ in self?.flip(forward: forward) })
            button.sizeToFit()
            button.alpha = 0
            button.toolTip = forward ? "Next Photo" : "Previous Photo"
            button.accessibilityLabel = forward ? "Next Photo" : "Previous Photo"
            button.isAccessibilityElement = false   // the stack itself flips for VoiceOver
            addSubview(button)
            arrows.append(button)
        }
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        registerForTraitChanges([ThemeGenerationTrait.self]) { (view: PhotoStackView, _) in view.restyleArrows() }
    }

    /// [glass-mac] Owner 2026-10-30 "more Liquid Glass": the photo viewer's own arrows (`PhotoPagerArrows`), a glass
    /// capsule round a chevron, so the stack and the viewer page with one button. The Desktop Look has no glass: there
    /// the dark disc it had, which reads on any photo (the look's clear outlined button would not).
    private static func arrowConfig(forward: Bool) -> UIButton.Configuration {
        let image = UIImage(systemName: forward ? "chevron.right" : "chevron.left",
                            withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .large))
        guard Theme.isDesktop else {
            var config = UIButton.Configuration.glass()   // glass-ok: the look is handled just above (restyleArrows)
            config.image = image
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
            return config
        }
        var config = UIButton.Configuration.plain()
        config.image = image
        config.baseForegroundColor = .white
        config.background.backgroundColor = UIColor(white: 0, alpha: 0.45)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        return config
    }

    /// The look was turned on or off: the arrows take its button.
    private func restyleArrows() {
        for (button, forward) in zip(arrows, [false, true]) {
            button.configuration = Self.arrowConfig(forward: forward)
            button.sizeToFit()
        }
        placeArrows()
    }

    private func placeArrows() {
        let top = topCardFrame
        for (button, forward) in zip(arrows, [false, true]) {
            let half = button.bounds.width / 2
            button.center = CGPoint(x: forward ? top.maxX - 8 - half : top.minX + 8 + half, y: top.midY)
        }
    }

    @objc private func hovered(_ gr: UIHoverGestureRecognizer) {
        let shown: CGFloat = (gr.state == .began || gr.state == .changed) && items.count > 1 ? 1 : 0
        guard arrows.first?.alpha != shown else { return }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {   // motion-ok: a fade
            self.arrows.forEach { $0.alpha = shown }
        }
    }
    #endif
}

/// One card's place: moved, turned and scaled about its centre, faded, with its "2/5" shown or not.
private struct Pose {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var angle: CGFloat = 0
    var scale: CGFloat = 1
    var alpha: CGFloat = 1
    var pill: CGFloat = 1

    var transform: CGAffineTransform {
        CGAffineTransform(translationX: x, y: y).rotated(by: angle).scaledBy(x: scale, y: scale)
    }

    static func mix(_ a: Pose, _ b: Pose, _ t: CGFloat) -> Pose {
        func m(_ u: CGFloat, _ v: CGFloat) -> CGFloat { u + (v - u) * t }
        return Pose(x: m(a.x, b.x), y: m(a.y, b.y), angle: m(a.angle, b.angle), scale: m(a.scale, b.scale),
                    alpha: m(a.alpha, b.alpha), pill: m(a.pill, b.pill))
    }
}

/// A photo card in the stack: the tile with rounded corners, a soft shadow under it, and its place in the pile
/// ("2/5", top trailing, in the time capsule's dim look).
private final class StackCardView: UIView {
    let tile: MediaTileView
    private let pill = UIView()
    private let label = UILabel()

    var radius: CGFloat = 12 {
        didSet { guard radius != oldValue else { return }; tile.layer.cornerRadius = radius; setNeedsLayout() }
    }

    var count = "" {
        didSet { guard count != oldValue else { return }; label.text = count; setNeedsLayout() }
    }

    init(tile: MediaTileView) {
        self.tile = tile
        super.init(frame: .zero)
        clipsToBounds = false
        tile.layer.cornerRadius = radius
        tile.layer.cornerCurve = .continuous
        addSubview(tile)
        pill.backgroundColor = UIColor(white: 0, alpha: 0.45)
        pill.isUserInteractionEnabled = false
        label.font = HQFont.digits(11, weight: .semibold, like: .caption2, cap: 15)
        label.adjustsFontForContentSizeCategory = true   // [a11y] follows a live text-size change
        label.textColor = .white
        label.textAlignment = .center
        pill.addSubview(label)
        addSubview(pill)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1.5)
        layer.shadowRadius = 5
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The shadow is darker in the dark, where it only shows over the card under it.
    func restyle() {
        layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0.45 : 0.16
    }

    func apply(_ pose: Pose) {
        transform = pose.transform
        alpha = pose.alpha
        pill.alpha = pose.pill
        if pose.alpha > 0 { isHidden = false }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tile.frame = bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
        let size = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        let h = ceil(size.height) + 6, w = max(h, ceil(size.width) + 12)
        // In from the top trailing corner, further in past a round one (as the time's capsule is).
        let inset = 6 + ChatMetrics.timeShift(corner: radius, trailing: 6, bottom: 6, round: h / 2)
        pill.frame = CGRect(x: bounds.width - inset - w, y: inset, width: w, height: h)
        pill.layer.cornerRadius = h / 2
        label.frame = pill.bounds
    }
}
