// A bot's head on screen: two cached pictures, the head without its eyes and the eyes alone, so motion is only
// transforms and nothing is redrawn. At rest it keeps still, looking to the right, at the words beside it (owner,
// 2026-11-16: "The bot faces need to all be still when not in use ... all look to the right ... so that they are
// looking at the text on the screen"): no blinks, glances or light of its own. While its bot works a robot sways and
// looks up, a pixel creature bobs (spec 02 §10.5, `bot-head.css`). A dot-matrix head is one picture swapped for
// another pose (each drawn once). [moods] While its bot is at something, a dot-matrix, Shapes or Dots face acts it out
// (FaceRoutines): the body turns, tips, hops and squashes in 3D, the eyes look about, narrow and blink (a
// dot-matrix head's a LED at a time, a Dots head's a lamp at a time), and over a dot-matrix head's LEDs a light plays
// (`MatrixAct`: a comet round the outline while thinking, code rain while running a command, a radar sweep while
// searching). Every face is drawn eyes only, the normal ones (`Head.plain`). Still under Reduce Motion and Low Power
// Mode.

import SwiftUI
import UIKit

final class HeadView: UIView {
    private(set) var head: Head = .defaultHead(profile: "default")
    private(set) var working = false
    /// Seconds into the working rhythm, so a list of busy bots doesn't breathe in unison.
    private var phase: Double = 0

    private let stage = CALayer()
    /// A themed head's still part (frame, tile, a robot's shoulders); the body moves over it, as `.dh-body` does.
    private let groundLayer = CALayer()
    /// Stationary clip wrapper around `mover`: clips tiled heads (Robot, Pixel, Orb, Glyph, boarded Shapes) to their
    /// inner tile panel without touching `groundLayer`'s outer frame.
    private let moverClip = CALayer()
    /// The body and the eyes together: what a working robot sways and a pixel creature bobs.
    private let mover = CALayer()
    private let bodyLayer = CALayer()
    /// Holds the eyes where a glance left them; the eyes inside it blink and read.
    private let gazeLayer = CALayer()
    private let eyesLayer = CALayer()
    private var drawnKey = ""
    /// Where the eyes are, as a fraction of the head (a blink closes them in place).
    private var eyeCentre = CGPoint(x: 0.5, y: 0.45)
    /// The box round the eyes, as fractions of the head (how far they can look before they leave the face).
    private var eyeBox = CGRect(x: 0.5, y: 0.45, width: 0, height: 0)
    /// [moods] A dot-matrix head's dynamic 3D specular glint over its LEDs while acting: hidden at rest.
    private let sheen = CAGradientLayer()
    private let sheenMask = CALayer()
    /// [moods] The bot whose doings this face acts out (its row, its tile, its chip, its chat's header), told by
    /// `BotMoods`; nil acts out nothing but `working`.
    private(set) var moodProfile: String?
    /// The act playing now: its mood, the pictures it's drawn for and whether it keeps still ("" none).
    private var actKey = ""
    /// A dot-matrix head with every LED at full light, shown through the masks an act moves, so its LEDs flare.
    private let flare = CALayer()
    private let flareMask = CALayer()
    /// [moods] A Shapes head's body drawn as its own outline while it acts, so it can wobble like jelly (FaceJelly), over
    /// the body's picture, which it hides till it's done. Never on a head in a board.
    private let jellyLayer = CAShapeLayer()
    /// Independent 3D-seated GPU pill layers for a soft Shapes head's normal slit eyes while acting: mathematically
    /// perfect rounded capsules at every blink/squint openness (no pinched corners), with true near/far depth scale,
    /// top-down weighted eyelids, subtle gaze convergence, velocity lean, micro-saccades, and 1-frame blink stagger.
    private let leftEyeLayer = CALayer()
    private let rightEyeLayer = CALayer()
    /// The head and size the jelly was drawn for: another head drops it at once (a reused row), this one settles it.
    private var jellyKey = ""
    /// Cached 3D cushion geometry per (head, size) so mood switches start instantly.
    private static var solidCache: [String: FaceSolid] = [:]
    // [photoheads] The bot this face belongs to when it came through `configure(raw:profile:working:)`: only then may
    // a photo the bot wears be drawn over the head (docs/spec/3x-photoheads.md §4.5).
    private(set) var faceProfile: String?
    private var photoView: UIImageView?
    /// Whether the bot's photo is what shows (the head under it is hidden and still).
    var showsPhoto: Bool { photoView?.isHidden == false }
    /// [updates] An update mark (an update line's faces, its card's member faces): a small dot-matrix head is drawn on
    /// its coarser drawn grid (`MatrixHead.coarseBelow`). Every other head draws as ever.
    let mark: Bool

    override convenience init(frame: CGRect) {
        self.init(frame: frame, mark: false)
    }

    init(frame: CGRect, mark: Bool) {
        self.mark = mark
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        stage.anchorPoint = CGPoint(x: 0.5, y: 0.94)
        for layer in [groundLayer, mover, bodyLayer, gazeLayer, eyesLayer] {
            layer.contentsGravity = .resize
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "transform": NSNull()]
        }
        moverClip.actions = ["bounds": NSNull(), "position": NSNull(), "mask": NSNull()]
        mover.anchorPoint = CGPoint(x: 0.5, y: 0.94)
        stage.addSublayer(groundLayer)
        stage.addSublayer(moverClip)
        moverClip.addSublayer(mover)
        mover.addSublayer(bodyLayer)
        mover.addSublayer(gazeLayer)
        gazeLayer.addSublayer(eyesLayer)
        sheenMask.contentsGravity = .resize
        sheenMask.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        sheen.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "locations": NSNull(), "colors": NSNull(),
                         "startPoint": NSNull(), "endPoint": NSNull()]
        sheen.mask = sheenMask
        sheen.isHidden = true
        mover.addSublayer(sheen)
        // [moods]
        flare.contentsGravity = .resize
        flareMask.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        flare.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        flare.mask = flareMask
        flare.isHidden = true
        mover.insertSublayer(flare, below: sheen)
        jellyLayer.actions = ["path": NSNull(), "transform": NSNull(), "hidden": NSNull(), "fillColor": NSNull(),
                              "strokeColor": NSNull(), "lineWidth": NSNull(), "bounds": NSNull(), "position": NSNull()]
        jellyLayer.isHidden = true
        mover.insertSublayer(jellyLayer, above: bodyLayer)
        for eye in [leftEyeLayer, rightEyeLayer] {
            eye.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull(), "cornerRadius": NSNull(),
                           "opacity": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
            eye.cornerCurve = .circular
            eye.isHidden = true
            gazeLayer.addSublayer(eye)
        }
        stage.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
        layer.addSublayer(stage)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitDisplayScale.self]) { (view: HeadView, _) in
            view.refresh()
        }
        HeadMotionSettings.shared.register(self)
    }

    convenience init(side: CGFloat, mark: Bool = false) {
        self.init(frame: CGRect(x: 0, y: 0, width: side, height: side), mark: mark)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows a bot's face: the photo it wears, else its saved Shapes head (raw `ui_meta["dispatch-head"]`) or the
    /// default for its profile. [moods] `follows`: the face acts out what the bot is doing (`follow`).
    func configure(raw: JSONValue?, profile: String, working: Bool = false, follows: Bool = false) {
        let followed = setFollowed(follows ? profile : nil)
        apply(head: Head.resolve(raw, profile: profile), working: working, phase: Self.phase(for: profile))
        if followed { refresh() }
        // [photoheads] this entry point is the one that may show a photo
        if faceProfile != profile {
            faceProfile = profile
            BotFaces.shared.register(self)
        }
        syncPhoto()
    }

    /// Shows this head and never a photo (Edit Head's preview, New Bot: the head being made; SwiftUI's `HeadImage`
    /// draws a photo itself). [moods] `follows`: the bot whose doings the face acts out.
    func configure(head: Head, working: Bool = false, phase: Double = 0, follows profile: String? = nil) {
        let followed = setFollowed(profile)
        apply(head: head, working: working, phase: phase)
        if followed { refresh() }
        if faceProfile != nil {       // [photoheads]
            faceProfile = nil
            syncPhoto()
        }
    }

    private func apply(head: Head, working: Bool, phase: Double) {
        let head = head.plain
        let changed = head != self.head || working != self.working
        self.head = head
        self.working = working
        self.phase = phase
        if changed { refresh() }
    }

    /// [moods] Has this face act out what `profile`'s bot is doing (nil: no more).
    func follow(_ profile: String?) {
        if setFollowed(profile) { refresh() }
    }

    /// Whether the bot followed changed.
    private func setFollowed(_ profile: String?) -> Bool {
        guard profile != moodProfile else { return false }
        if let moodProfile { BotMoods.shared.unregister(self, profile: moodProfile) }
        moodProfile = profile
        if let profile { BotMoods.shared.register(self, profile: profile) }
        return true
    }

    /// [moods] The bot's mood changed (told by `BotMoods`).
    func moodChanged() { refresh() }

    /// [moods] What the bot is up to, as far as this face hears.
    private var heardMood: BotMood? { posedMood ?? moodProfile.flatMap { BotMoods.shared.mood(for: $0) } }

    /// [model-panel] A mood this face acts out whatever its bot is doing (the model panel's face thinks as hard as you
    /// set it to); nil: its bot's own.
    var posedMood: BotMood? {
        didSet {
            guard posedMood != oldValue else { return }
            posedSince = CACurrentMediaTime()
            refresh()
        }
    }
    private var posedSince: CFTimeInterval = 0

    /// [moods] What a dot-matrix face acts out now: what its bot is doing, else thinking while it works.
    private var shownMood: BotMood? { heardMood ?? (working ? .thinking : nil) }

    /// Whether a face moves as working: its bot's turn, or (a face that follows its bot) a step it's on.
    private var busy: Bool {
        if working { return true }
        guard let mood = heardMood else { return false }
        return !mood.once && mood != .asking
    }

    /// [moods] Every non-matrix theme acts out its bot's doings with `FaceRoutines` (Shapes with 3D solid jelly + GPU
    /// pill eyes, Dots with stepped lamps, Robot/Orb/Pixel/Glyph with theme-tailored motion over their still tile/shoulders).
    private var playsRoutines: Bool { !isMatrix }

    /// The web's per-head offset: `(name.length · 0.7) % 5` seconds.
    static func phase(for name: String) -> Double { (Double(name.count) * 0.7).truncatingRemainder(dividingBy: 5) }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }

    override func layoutSubviews() {
        super.layoutSubviews()
        stage.bounds = bounds
        stage.position = CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.94)
        groundLayer.frame = stage.bounds
        moverClip.frame = stage.bounds
        mover.bounds = bounds
        mover.position = CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.94)
        bodyLayer.frame = stage.bounds
        jellyLayer.frame = stage.bounds
        gazeLayer.frame = stage.bounds
        eyesLayer.frame = stage.bounds
        sheen.frame = stage.bounds
        sheenMask.frame = sheen.bounds
        flare.frame = stage.bounds
        flareMask.frame = flare.bounds
        layoutPhoto()       // [photoheads]
        refresh()
    }

    // MARK: [photoheads] The photo over the head

    /// Shows the bot's photo, or takes it away and brings the head back (told by `BotFaces` when the face changes).
    /// A photo is an app-icon tile, never a circle; it does not blink, glance or bob.
    func syncPhoto() {
        let image = faceProfile.flatMap { BotFaces.shared.photo(for: $0) }
        let was = showsPhoto
        if let image {
            let view = photoView ?? makePhotoView()
            if view.image !== image { view.image = image }
            view.isHidden = false
        } else if let photoView {
            photoView.isHidden = true
            photoView.image = nil
        }
        guard was != showsPhoto else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)       // no cross-fade
        stage.isHidden = showsPhoto
        CATransaction.commit()
        layoutPhoto()
        if showsPhoto { updateMotion() } else { refresh() }
    }

    private func makePhotoView() -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerCurve = .continuous
        view.accessibilityIgnoresInvertColors = true
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        addSubview(view)
        photoView = view
        return view
    }

    private func layoutPhoto() {
        guard let photoView else { return }
        photoView.frame = bounds
        photoView.layer.cornerRadius = bounds.width * BotFaces.cornerShare
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateMotion()
    }

    /// Reduce Motion or Low Power Mode changed (or the app came back): redraw as one or two layers, start or stop motion.
    func motionSettingsChanged() { refresh() }

    /// How this head's eyes can move while it acts (`movesFor`): whether it has eyes to shut, and how far they look (a
    /// Shapes head by its parts).
    private var moves: (blinks: Bool, glance: Double) {
        if isMatrix { return (true, 1) }
        guard let record = head.themed else { return HeadGeometry.motion(head) }
        return (Self.hasFace(record), 0)
    }

    private var isMatrix: Bool { head.theme == .matrix }

    /// Whether a themed head draws eyes (`dh-face`): robots and pixel creatures always, an orb or a ring/bloom pattern
    /// with Eyes on, a dots face; never an emoji.
    static func hasFace(_ record: HeadRecord) -> Bool {
        switch record.theme {
        case "robot", "pixel": true
        case "orb": record.eyes
        case "dots": record.pattern == "face" || (record.eyes && (record.pattern == "ring" || record.pattern == "bloom"))
        default: false
        }
    }

    /// The themed heads that move while working (`bot-head.css`): robots and emoji sway, pixel creatures bob.
    private var themedWorkMotion: Bool {
        guard let theme = head.themed?.theme else { return false }
        return theme == "robot" || theme == "glyph" || theme == "pixel"
    }

    private func refresh() {
        let side = bounds.width
        guard side > 0 else { return }
        // [photoheads] A photo covers the head: nothing to draw until it goes (`syncPhoto` calls back here then).
        if showsPhoto { updateMotion(); return }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let dark = traitCollection.userInterfaceStyle == .dark
        // Two layers whenever the head may move (working, or blinking and glancing at rest); one picture otherwise.
        let still = HeadMotionSettings.shared.isStill
        if isMatrix {
            showMatrix(side: side, scale: scale, dark: dark)
            updateMotion()
            return
        }
        let themed = head.themed != nil
        let working = playsRoutines ? shownMood != nil : busy
        let layered = !still && (themed ? working || moves.blinks : working || moves.blinks || moves.glance > 0)
        let state: HeadState = working && !playsRoutines ? .thinking : .idle
        let key = "\(head.cacheKey)|\(side)|\(scale)|\(themed ? false : dark)|\(state.rawValue)|\(layered)"
        if key != drawnKey {
            drawnKey = key
            let cache = HeadImageCache.shared
            let face = themed ? moves.blinks : true
            let parts: [HeadRenderer.Parts] = !layered ? [.all] : themed ? [.ground, .moving] + (face ? [.face] : []) : [.body, .face]
            let cached = parts.map { cache.cachedImage(for: head, side: side, scale: scale, dark: dark, state: state, parts: $0) }
            if themed, cached.contains(where: { $0 == nil }) {
                // Drawn off the main thread; the picture before it stays until this lands.
                let head = self.head
                Task { [weak self] in
                    let images = await cache.images(for: head, side: side, scale: scale, dark: dark, state: state, parts: parts)
                    guard let self, self.drawnKey == key else { return }
                    self.show(images, parts: parts, scale: scale, side: side, state: state)
                }
            } else {
                let images = zip(parts, cached).map { part, hit in
                    hit ?? cache.image(for: head, side: side, scale: scale, dark: dark, state: state, parts: part)
                }
                show(images, parts: parts, scale: scale, side: side, state: state)
            }
        }
        updateMotion()
    }

    private func show(_ images: [UIImage], parts: [HeadRenderer.Parts], scale: CGFloat, side: CGFloat, state: HeadState) {
        func picture(_ part: HeadRenderer.Parts) -> UIImage? { parts.firstIndex(of: part).map { images[$0] } }
        groundLayer.contents = picture(.ground)?.cgImage
        bodyLayer.contents = (picture(.all) ?? picture(.moving) ?? picture(.body))?.cgImage
        if let eyes = picture(.face) {
            eyesLayer.contents = eyes.cgImage
            eyesLayer.isHidden = false
            eyeBox = HeadImageCache.shared.eyeBox(of: eyes, key: "\(head.cacheKey)|\(state.rawValue)|\(side < 64)")
            eyeCentre = CGPoint(x: eyeBox.midX, y: eyeBox.midY)
        } else {
            eyesLayer.contents = nil
            eyesLayer.isHidden = true
        }
        for layer in [groundLayer, bodyLayer, eyesLayer] { layer.contentsScale = scale }
        if !usesGroundedMover {
            moverClip.mask = nil
        } else if bounds.width > 0 {
            let clip = (moverClip.mask as? CAShapeLayer) ?? CAShapeLayer()
            clip.frame = moverClip.bounds
            var scale = CGAffineTransform(scaleX: bounds.width / 1024, y: bounds.height / 1024)
            clip.path = SVGPathData.path(HeadGeometry.panel).copy(using: &scale)
            moverClip.mask = clip
        }
        if jellyKey != "\(head.cacheKey)|\(side)" { dropJelly() }
        gazeLayer.removeAllAnimations()
        // A drawn head's eyes rest over to the right (a Shapes head's are drawn there already).
        let look = state == .idle ? head.themed.map { ThemeHeadSVG.restLook($0, compact: side < 64) * side / 1024 } ?? 0 : 0
        gazeLayer.transform = CATransform3DMakeTranslation(look, 0, 0)
        // A dot-matrix head shown here before: its swaps and its light go with it.
        bodyLayer.removeAllAnimations()
        sheen.removeAllAnimations()
        sheen.isHidden = true
        sheenMask.contents = nil
        clearAct()
        updateMotion()
    }

    // MARK: The dot-matrix head

    /// A dot-matrix head: its picture at rest (what its bot is doing plays over it: `syncAct`).
    private func showMatrix(side: CGFloat, scale: CGFloat, dark: Bool) {
        let key = "\(head.cacheKey)|\(side)|\(scale)|\(dark)|matrix"
        guard key != drawnKey else { return }
        drawnKey = key
        let picture = matrixFrame(.look)?.cgImage
        groundLayer.contents = nil
        eyesLayer.contents = nil
        eyesLayer.isHidden = true
        gazeLayer.removeAllAnimations()
        gazeLayer.transform = CATransform3DIdentity
        // Whatever moved the head shown before (a Shapes head breathing, a robot swaying) stops; `updateMotion` starts
        // this one's.
        stage.removeAllAnimations()
        stage.transform = CATransform3DIdentity
        moverClip.mask = nil
        mover.removeAllAnimations()
        mover.transform = CATransform3DIdentity
        eyesLayer.removeAllAnimations()
        moving = false
        dropJelly()
        bodyLayer.removeAllAnimations()
        bodyLayer.contents = picture
        sheenMask.contents = picture
        for layer in [bodyLayer, sheenMask] { layer.contentsScale = scale }
        sheen.removeAllAnimations()
        sheen.isHidden = true
    }

    /// The head at `pose`, at this view's size, scale and page (drawn once per head, then from the shared cache).
    private func matrixFrame(_ pose: MatrixPose) -> UIImage? {
        let side = bounds.width
        guard side > 0 else { return nil }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let image = HeadImageCache.shared.matrixFrame(for: head, pose: pose, side: side, scale: scale,
                                                      dark: traitCollection.userInterfaceStyle == .dark, mark: mark)
        return image.cgImage == nil ? nil : image
    }

    // MARK: [moods] Acting out what the bot is doing

    /// Starts, swaps or stops the act a dot-matrix face plays: what its bot is doing, kept to one still face under
    /// Reduce Motion. The act's pictures are drawn off the main thread the first time; the face stays as it is till then.
    private func syncAct(still: Bool) {
        let side = bounds.width
        guard let mood = shownMood, window != nil, side > 0, !showsPhoto, !drawnKey.isEmpty else {
            if !actKey.isEmpty { endAct() }
            return
        }
        let key = "\(mood.rawValue)|\(drawnKey)|\(still)"
        guard key != actKey else { return }
        let shown = stage.presentation()?.transform
        if !actKey.isEmpty { clearAct(settle: false) }
        actKey = key
        let act = MatrixAct.make(mood, design: MatrixDesign(head))
        if still {
            bodyLayer.contents = matrixFrame(act.still)?.cgImage
            return
        }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let dark = traitCollection.userInterfaceStyle == .dark
        let (begin, seed) = actClock()
        let loop = FaceLoop(mood, facing: act.design.facing, seed: seed)
        let cache = HeadImageCache.shared
        if let pictures = cache.cachedActPictures(for: head, mood: mood, side: side, scale: scale, dark: dark, mark: mark) {
            play(act, loop, pictures, begin: begin, scale: scale, from: shown)
            return
        }
        let head = self.head, mark = self.mark
        Task { [weak self] in
            let pictures = await cache.actPictures(for: head, mood: mood, side: side, scale: scale, dark: dark, mark: mark)
            guard let self, self.actKey == key else { return }
            self.play(act, loop, pictures, begin: begin, scale: scale, from: shown)
        }
    }

    /// [moods] When the act began (from when the bot began this, so its row and its chat's header move together and a
    /// face shown later joins in) and the order its routines go in: the bot's and the step's own, else the head's.
    private func actClock() -> (begin: CFTimeInterval, seed: Int) {
        if posedMood != nil { return (posedSince, head.seed) }
        guard let profile = moodProfile, let since = BotMoods.shared.since(profile) else {
            return (CACurrentMediaTime() - phase, head.seed)
        }
        var seed = 5381
        for byte in profile.utf8 { seed = seed &* 33 &+ Int(byte) }
        return (since, seed &+ Int((since * 10).rounded()))
    }

    /// The act stops and the face is as it rests again.
    private func endAct() {
        clearAct()
        bodyLayer.contents = matrixFrame(.look)?.cgImage
    }

    /// Whatever an act left: its swaps, its moves, its light. `settle`: the body eases back to standing (not when another
    /// act takes over: that one eases in from where it is).
    private func clearAct(settle: Bool = true) {
        let moved: [(CALayer, CATransform3D)] = !settle ? [] : [stage, mover, gazeLayer, eyesLayer].compactMap { layer in
            guard layer.animation(forKey: "act") != nil || layer.animation(forKey: "act.lids") != nil
                    || layer.animation(forKey: "act.jelly") != nil,
                  let shown = layer.presentation()?.transform else { return nil }
            return (layer, shown)
        }
        actKey = ""
        bodyLayer.removeAnimation(forKey: "act")
        for layer in [stage, mover, gazeLayer, eyesLayer] {
            for key in Self.actKeys { layer.removeAnimation(forKey: key) }
        }
        if settle && !isMatrix && bounds.width > 0 {
            let look = head.themed.map { ThemeHeadSVG.restLook($0, compact: bounds.width < 64) * bounds.width / 1024 } ?? 0
            gazeLayer.transform = CATransform3DMakeTranslation(look, 0, 0)
        }
        if !settle || jellyLayer.isHidden {
            for eye in [leftEyeLayer, rightEyeLayer] {
                eye.removeAllAnimations()
                eye.isHidden = true
            }
            if eyesLayer.contents != nil { eyesLayer.isHidden = false }
        }
        flareMask.sublayers?.forEach { $0.removeFromSuperlayer() }
        flare.isHidden = true
        flare.contents = nil
        if sheen.animation(forKey: "act.glint") != nil {
            sheen.removeAnimation(forKey: "act.glint")
            sheen.isHidden = true
        }
        for (layer, shown) in moved where !CATransform3DEqualToTransform(shown, layer.transform) {
            bridge(layer, "transform", from: NSValue(caTransform3D: shown), to: NSValue(caTransform3D: layer.transform), key: "act.end")
        }
        // Another act taking over moves the jelly on from where it is (`playJelly`); else it settles, then the picture shows.
        if settle { settleJelly() }
    }

    private static let actKeys = ["act", "act.bridge", "act.end", "act.lids", "act.seen", "act.jelly", "act.glint"]

    private func play(_ act: MatrixAct, _ loop: FaceLoop, _ pictures: MatrixActPictures, begin: CFTimeInterval, scale: CGFloat,
                      from shown: CATransform3D?) {
        let frames = act.frames(loop)
        let images = frames.compactMap { pictures.faces[$0.pose] ?? matrixFrame($0.pose)?.cgImage }
        guard images.count == frames.count, let first = images.first else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let period = loop.period
        func time(_ animation: CAAnimation, _ duration: Double, after offset: Double = 0) {
            animation.duration = duration
            animation.beginTime = begin + offset
            animation.isRemovedOnCompletion = false
            if act.once { animation.fillMode = .forwards } else { animation.repeatCount = .infinity }
        }
        if images.count == 1 {
            bodyLayer.contents = first
        } else {
            let faces = CAKeyframeAnimation(keyPath: "contents")   // motion-ok: still under Reduce Motion (syncAct)
            faces.values = images
            faces.keyTimes = frames.map { NSNumber(value: $0.at / period) } + [1]
            faces.calculationMode = .discrete
            time(faces, period)
            bodyLayer.add(faces, forKey: "act")
        }
        if let effect = act.effect, let lit = pictures.lit {
            flare.contents = lit
            flare.contentsScale = scale
            flare.isHidden = false
            for layer in effectLayers(effect, act: act, loop: loop, pictures: pictures, time: time) {
                layer.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "path": NSNull(), "transform": NSNull()]
                flareMask.addSublayer(layer)
            }
        }
        // 60 fps critically damped spring body + subtle 38% elastic follow-through on `mover` + dynamic 3D glint,
        // so dot-matrix heads move with fluid physical weight while keeping every LED dot razor-crisp.
        let samples = loop.softSamples(once: act.once)
        moveBody(loop, samples: samples, begin: begin, once: act.once, from: shown)
        playMatrixElastic(samples, period: period, begin: begin, once: act.once)
        playMatrixGlint(samples, period: period, begin: begin, once: act.once)
    }

    /// Subtle elastic squash & lean follow-through on a dot-matrix head's `mover` layer: gives hops, landings, nods and
    /// quick turns physical weight without distorting the LEDs into rubber.
    private func playMatrixElastic(_ samples: [(at: Double, body: FaceBody, eyes: FaceEyes)], period: Double,
                                   begin: CFTimeInterval, once: Bool) {
        let wobble = FaceJelly.follow(samples, period: period, once: once)
        let shownMover = mover.presentation()?.transform
        mover.removeAnimation(forKey: "act.end")
        func elastic(_ j: FaceJelly) -> CATransform3D {
            let sq = j.squash * 0.38, ln = j.lean * 0.36
            var t = CATransform3DMakeScale(1 + sq, 1 - sq, 1)
            t.m21 = -ln
            return t
        }
        let anim = CAKeyframeAnimation(keyPath: "transform")   // motion-ok: still under Reduce Motion (syncAct)
        anim.values = wobble.map { NSValue(caTransform3D: elastic($0)) }
        anim.keyTimes = samples.map { NSNumber(value: $0.at / period) }
        settle(anim, period: period, begin: begin, once: once)
        mover.add(anim, forKey: "act.jelly")
        if let shownMover, !CATransform3DEqualToTransform(shownMover, CATransform3DIdentity) {
            let then = Self.sample(in: samples, at: CACurrentMediaTime() + Self.bridgeLength - begin, period: period, once: once)
            bridge(mover, "transform", from: NSValue(caTransform3D: shownMover),
                   to: NSValue(caTransform3D: elastic(wobble[min(then, wobble.count - 1)])))
        }
    }

    /// Dynamic 3D specular light rolling across a dot-matrix head's LEDs as it turns and tips (masked by `sheenMask`,
    /// zero extra bitmaps): turning right rolls the highlight left across the dome, giving real 3D physicality.
    private func playMatrixGlint(_ samples: [(at: Double, body: FaceBody, eyes: FaceEyes)], period: Double,
                                 begin: CFTimeInterval, once: Bool) {
        guard sheenMask.contents != nil else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        let peak = UIColor.white.withAlphaComponent(dark ? 0.36 : 0.24).cgColor
        let clear = UIColor.white.withAlphaComponent(0).cgColor
        sheen.removeAllAnimations()
        sheen.type = .radial
        sheen.colors = [peak, clear]
        sheen.locations = [0, 1]
        sheen.isHidden = false
        let facing = Double(MatrixHead.shownFacing)
        func spot(_ b: FaceBody) -> (start: CGPoint, end: CGPoint) {
            let cx = min(max(0.5 + 0.16 * facing - b.turn / 110, 0.12), 0.88)
            let cy = min(max(0.32 - b.tip / 110, 0.1), 0.78)
            return (CGPoint(x: cx, y: cy), CGPoint(x: cx + 0.56, y: cy + 0.56))
        }
        let points = samples.map { spot($0.body) }
        let startAnim = CAKeyframeAnimation(keyPath: "startPoint")   // motion-ok: still under Reduce Motion (syncAct)
        startAnim.values = points.map { NSValue(cgPoint: $0.start) }
        startAnim.duration = period
        let endAnim = CAKeyframeAnimation(keyPath: "endPoint")       // motion-ok: still under Reduce Motion (syncAct)
        endAnim.values = points.map { NSValue(cgPoint: $0.end) }
        endAnim.duration = period
        let times = samples.map { NSNumber(value: $0.at / period) }
        startAnim.keyTimes = times
        endAnim.keyTimes = times
        if let first = points.first {
            sheen.startPoint = first.start
            sheen.endPoint = first.end
        }
        let group = CAAnimationGroup()
        group.animations = [startAnim, endAnim]
        settle(group, period: period, begin: begin, once: once)
        sheen.add(group, forKey: "act.glint")
    }

    // MARK: [moods] The body, for every face that plays the routines

    /// The body at `body`, as the stage's transform: squashed from where it stands, tipped, turned and tilted about its
    /// middle with a little depth, then moved. A `solid` body (FaceSolid) turns and tips in its own outline instead.
    private func bodyTransform(_ body: FaceBody, solid: Bool = false) -> CATransform3D {
        let side = bounds.width, middle = side * 0.44   // from where it stands (the stage's anchor) up to its middle
        let degree = Double.pi / 180, squash = body.squash * (isSoft && !solid ? 1.4 : 1)
        var depth = CATransform3DIdentity
        depth.m34 = -1 / (side * 2.5)
        let turns = solid ? [] : [CATransform3DMakeRotation(-body.tip * degree, 1, 0, 0), CATransform3DMakeRotation(body.turn * degree, 0, 1, 0)]
        let steps = [CATransform3DMakeScale(1 + squash, 1 - squash, 1), CATransform3DMakeTranslation(0, middle, 0)] + turns
            + [CATransform3DMakeRotation(body.roll * degree, 0, 0, 1), depth, CATransform3DMakeTranslation(body.x * side, body.y * side - middle, 0)]
        return steps.dropFirst().reduce(steps[0]) { CATransform3DConcat($0, $1) }
    }

    /// Plays `loop`'s body on `target` (`stage` for bare/Dots heads, `mover` for framed/robot heads whose tile or
    /// shoulders stay grounded) from `begin`, easing in from `shown`.
    private func moveBody(_ loop: FaceLoop, samples given: [(at: Double, body: FaceBody, eyes: FaceEyes)]? = nil,
                          on target: CALayer? = nil, scale: Double = 1, discrete: Bool = false,
                          begin: CFTimeInterval, once: Bool, from shown: CATransform3D?, solid: Bool = false) {
        let layer = target ?? stage
        let samples = given ?? loop.samples()
        func scaled(_ b: FaceBody) -> FaceBody {
            guard scale != 1 else { return b }
            return FaceBody(x: b.x * scale, y: b.y * scale, roll: b.roll * scale, turn: b.turn * scale,
                            tip: b.tip * scale, squash: b.squash * scale)
        }
        layer.removeAnimation(forKey: "act.end")
        layer.transform = CATransform3DIdentity
        let move = CAKeyframeAnimation(keyPath: "transform")   // motion-ok: still under Reduce Motion (syncAct, syncFace)
        move.values = samples.map { NSValue(caTransform3D: bodyTransform(scaled($0.body), solid: solid)) }
        move.keyTimes = samples.map { NSNumber(value: $0.at / loop.period) }
        if discrete { move.calculationMode = .discrete }
        settle(move, period: loop.period, begin: begin, once: once)
        layer.add(move, forKey: "act")
        if let shown {
            let then = samples[Self.sample(in: samples, at: CACurrentMediaTime() + Self.bridgeLength - begin, period: loop.period, once: once)]
            bridge(layer, "transform", from: NSValue(caTransform3D: shown),
                   to: NSValue(caTransform3D: bodyTransform(scaled(then.body), solid: solid)))
        }
    }

    /// Which of `samples` (of a loop `period` long) plays `t` seconds in: over and over, or once and held.
    private static func sample(in samples: [(at: Double, body: FaceBody, eyes: FaceEyes)], at t: Double, period: Double, once: Bool) -> Int {
        var t = once ? min(max(t, 0), period) : t.truncatingRemainder(dividingBy: period)
        if t < 0 { t += period }
        return samples.lastIndex { $0.at <= t } ?? 0
    }

    /// An act's animation over its whole loop from `begin`: over and over, or once and held.
    private func settle(_ animation: CAAnimation, period: Double, begin: CFTimeInterval, once: Bool) {
        animation.duration = period
        animation.beginTime = begin
        animation.isRemovedOnCompletion = false
        if once { animation.fillMode = .forwards } else { animation.repeatCount = .infinity }
    }

    private static let bridgeLength = 0.3

    /// Eases `layer` from where it shows (`from`) into what plays from now on (`to`, `bridgeLength` from now), so a new
    /// act doesn't jump. Added after the act's own animation, it shows over it until it's done.
    private func bridge(_ layer: CALayer, _ keyPath: String, from: Any, to: Any, key: String = "act.bridge") {
        let ease = CABasicAnimation(keyPath: keyPath)   // motion-ok: still under Reduce Motion (syncAct, syncFace)
        ease.fromValue = from
        ease.toValue = to
        ease.duration = Self.bridgeLength
        ease.beginTime = CACurrentMediaTime()
        ease.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
        layer.add(ease, forKey: key)
    }

    /// The masks an effect moves over the lit LEDs: white where they flare.
    private func effectLayers(_ effect: MatrixAct.Effect, act: MatrixAct, loop: FaceLoop, pictures: MatrixActPictures,
                              time: (CAAnimation, Double, Double) -> Void) -> [CALayer] {
        let side = bounds.width, pitch = side / CGFloat(MatrixHead.grid)
        let design = MatrixDesign(head)
        let white = UIColor.white.cgColor, clear = UIColor.white.withAlphaComponent(0).cgColor
        func whole() -> CALayer {
            let layer = CALayer()
            layer.frame = CGRect(x: 0, y: 0, width: side, height: side)
            layer.backgroundColor = white
            layer.opacity = 0
            return layer
        }
        func opacity(_ values: [Double], at seconds: [Double], over duration: Double, discrete: Bool = false) -> CAKeyframeAnimation {
            let fade = CAKeyframeAnimation(keyPath: "opacity")   // motion-ok: still under Reduce Motion (syncAct)
            fade.values = values
            fade.keyTimes = seconds.map { NSNumber(value: $0 / duration) }
            if discrete { fade.calculationMode = .discrete }
            return fade
        }
        func ring(at centre: CGPoint, from small: CGFloat, to big: CGFloat, width: CGFloat, over duration: Double) -> (CAShapeLayer, CAAnimation) {
            let ring = CAShapeLayer()
            ring.frame = CGRect(x: 0, y: 0, width: side, height: side)
            ring.fillColor = nil
            ring.strokeColor = white
            ring.lineWidth = width
            ring.opacity = 0
            func circle(_ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r), transform: nil) }
            ring.path = circle(small)
            let grow = CABasicAnimation(keyPath: "path")   // motion-ok: still under Reduce Motion (syncAct)
            grow.fromValue = circle(small)
            grow.toValue = circle(big)
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let fade = CAKeyframeAnimation(keyPath: "opacity")   // motion-ok: still under Reduce Motion (syncAct)
            fade.values = [1, 0.85, 0]
            fade.keyTimes = [0, 0.55, 1]
            grow.duration = duration
            fade.duration = duration
            let both = CAAnimationGroup()
            both.animations = [grow, fade]
            both.duration = duration
            return (ring, both)
        }
        switch effect {
        case .orbit:
            // Dual-harmonic comets round the outline: primary bright comet + softer counter-orbiting halo.
            func comet(tail: Double, duration: Double, reverse: Bool, opacity: Float) -> CAGradientLayer {
                let sweep = CAGradientLayer()
                sweep.type = .conic
                let reach = side * 1.5
                sweep.frame = CGRect(x: (side - reach) / 2, y: (side - reach) / 2, width: reach, height: reach)
                sweep.startPoint = CGPoint(x: 0.5, y: 0.5)
                sweep.endPoint = CGPoint(x: 0.5, y: 0)
                sweep.colors = reverse ? [white, clear, clear] : [clear, clear, white]
                sweep.locations = reverse ? [0, NSNumber(value: tail), 1] : [0, NSNumber(value: 1 - tail), 1]
                sweep.opacity = opacity
                let turn = CABasicAnimation(keyPath: "transform.rotation.z")   // motion-ok: still under Reduce Motion (syncAct)
                turn.fromValue = 0
                turn.toValue = reverse ? -2 * Double.pi : 2 * Double.pi
                time(turn, duration, 0)
                sweep.add(turn, forKey: "act")
                return sweep
            }
            return [comet(tail: 0.34, duration: 1.8, reverse: false, opacity: 1),
                    comet(tail: 0.24, duration: 2.7, reverse: true, opacity: 0.45)]
        case .radar:
            // Rotating radar sweep over the head PLUS two crisp target "ping" blips that flare as the beam crosses them.
            let sweep = CAGradientLayer()
            sweep.type = .conic
            let reach = side * 1.5
            sweep.frame = CGRect(x: (side - reach) / 2, y: (side - reach) / 2, width: reach, height: reach)
            sweep.startPoint = CGPoint(x: 0.5, y: 0.5)
            sweep.endPoint = CGPoint(x: 0.5, y: 0)
            sweep.colors = [clear, clear, white]
            sweep.locations = [0, 0.78, 1]
            let sweepDuration = 1.4
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")   // motion-ok: still under Reduce Motion (syncAct)
            turn.fromValue = 0
            turn.toValue = 2 * Double.pi
            time(turn, sweepDuration, 0)
            sweep.add(turn, forKey: "act")
            let blips: [CALayer] = [(CGPoint(x: 0.74, y: 0.32), 0.16), (CGPoint(x: 0.28, y: 0.72), 0.62)].map { pos, phase in
                let dot = CAGradientLayer()
                dot.type = .radial
                dot.colors = [white, clear]
                dot.locations = [0, 1]
                dot.startPoint = CGPoint(x: 0.5, y: 0.5)
                dot.endPoint = CGPoint(x: 1, y: 1)
                dot.bounds = CGRect(x: 0, y: 0, width: side * 0.28, height: side * 0.28)
                dot.position = CGPoint(x: pos.x * side, y: pos.y * side)
                dot.opacity = 0
                let ping = opacity([0, 1, 0.35, 0, 0], at: [0, 0.06, 0.28, 0.62, sweepDuration], over: sweepDuration)
                time(ping, sweepDuration, phase * sweepDuration)
                dot.add(ping, forKey: "act")
                return dot
            }
            return [sweep] + blips
        case .scan:
            // A soft horizontal reading beam stepping down line by line while a bright focus spot sweeps left-to-right.
            let band = CAGradientLayer()
            let height = side * 0.28
            band.frame = CGRect(x: 0, y: -height, width: side, height: height)
            band.colors = [clear, UIColor.white.withAlphaComponent(0.65).cgColor, clear]
            band.locations = [0, 0.5, 1]
            let down = CABasicAnimation(keyPath: "position.y")   // motion-ok: still under Reduce Motion (syncAct)
            down.fromValue = side * 0.2
            down.toValue = side * 0.85
            down.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            time(down, 3.45, 0)
            band.add(down, forKey: "act")
            let spot = CAGradientLayer()
            spot.type = .radial
            spot.colors = [white, clear]
            spot.locations = [0, 1]
            spot.startPoint = CGPoint(x: 0.5, y: 0.5)
            spot.endPoint = CGPoint(x: 1, y: 1)
            spot.bounds = CGRect(x: 0, y: 0, width: side * 0.38, height: side * 0.26)
            spot.position = CGPoint(x: side * 0.2, y: side * 0.36)
            let scanPeriod = 3.45
            let trace = CAKeyframeAnimation(keyPath: "position")   // motion-ok: still under Reduce Motion (syncAct)
            let rows: [CGFloat] = [0.36, 0.56, 0.74]
            var pts: [CGPoint] = [], times: [Double] = []
            for (i, ry) in rows.enumerated() {
                let t0 = Double(i) * 1.15
                pts += [CGPoint(x: side * 0.18, y: side * ry), CGPoint(x: side * 0.82, y: side * ry)]
                times += [t0, t0 + 0.92]
            }
            pts.append(pts[0])
            times.append(scanPeriod)
            trace.values = pts.map { NSValue(cgPoint: $0) }
            trace.keyTimes = times.map { NSNumber(value: $0 / scanPeriod) }
            time(trace, scanPeriod, 0)
            spot.add(trace, forKey: "act")
            return [band, spot]
        case .rain:
            // Streaks falling a LED at a time, two speeds; each picture is two heads tall and loops a head's height.
            return pictures.masks.enumerated().map { index, mask in
                let drop = CALayer()
                drop.contents = mask
                drop.contentsGravity = .resize
                drop.frame = CGRect(x: 0, y: -side, width: side, height: side * 2)
                drop.opacity = index == 0 ? 1 : 0.65
                let grid = MatrixHead.grid, top = drop.position.y
                let fall = CAKeyframeAnimation(keyPath: "position.y")   // motion-ok: still under Reduce Motion (syncAct)
                fall.values = (0..<grid).map { top + CGFloat($0) * pitch }
                fall.keyTimes = (0...grid).map { NSNumber(value: Double($0) / Double(grid)) }
                fall.calculationMode = .discrete
                time(fall, index == 0 ? 1.4 : 2.2, 0)
                drop.add(fall, forKey: "act")
                return drop
            }
        case .typing:
            // LED by LED along each line in turn, with a crisp blinking cursor leading the active tip, then both clear.
            let period = 2 * MatrixAct.lineLength + MatrixAct.typingPause
            let lines = MatrixActMasks.typingLines(design)
            var out: [CALayer] = lines.enumerated().map { index, line in
                let count = line.last - line.first + 1
                let bar = CALayer()
                bar.backgroundColor = UIColor.white.withAlphaComponent(0.75).cgColor
                bar.anchorPoint = CGPoint(x: 0, y: 0.5)
                bar.frame = CGRect(x: CGFloat(line.first) * pitch, y: CGFloat(line.row) * pitch, width: 0, height: pitch)
                let start = Double(index) * MatrixAct.lineLength
                let typed = CAKeyframeAnimation(keyPath: "bounds.size.width")   // motion-ok: still under Reduce Motion (syncAct)
                typed.values = (0...count).map { CGFloat($0) * pitch }
                typed.keyTimes = [0] + (1...count).map { NSNumber(value: (start + Double($0) * MatrixAct.lineLength / Double(count + 1)) / period) } + [1]
                typed.calculationMode = .discrete
                time(typed, period, 0)
                bar.add(typed, forKey: "act")
                return bar
            }
            if let first = lines.first {
                let cursor = CALayer()
                cursor.backgroundColor = white
                cursor.bounds = CGRect(x: 0, y: 0, width: pitch * 1.15, height: pitch * 1.15)
                cursor.position = CGPoint(x: (CGFloat(first.first) + 0.5) * pitch, y: (CGFloat(first.row) + 0.5) * pitch)
                var pos: [CGPoint] = [], ks: [Double] = []
                for (index, line) in lines.enumerated() {
                    let count = line.last - line.first + 1
                    let start = Double(index) * MatrixAct.lineLength
                    for step in 0...count {
                        let col = min(line.first + step, line.last)
                        pos.append(CGPoint(x: (CGFloat(col) + 0.5) * pitch, y: (CGFloat(line.row) + 0.5) * pitch))
                        ks.append((start + Double(step) * MatrixAct.lineLength / Double(count + 1)) / period)
                    }
                }
                let move = CAKeyframeAnimation(keyPath: "position")   // motion-ok: still under Reduce Motion (syncAct)
                move.values = pos.map { NSValue(cgPoint: $0) }
                move.keyTimes = ks.map { NSNumber(value: $0) } + [1]
                move.calculationMode = .discrete
                time(move, period, 0)
                let blink = opacity([1, 0.25, 1], at: [0, 0.22, 0.44], over: 0.44)
                time(blink, 0.44, 0)
                cursor.add(move, forKey: "act")
                cursor.add(blink, forKey: "act.blink")
                out.append(cursor)
            }
            return out
        case .pointer:
            // A spot of light gliding from stop to stop, and double concentric click ripples each time it lands.
            let stops = MatrixAct.stops.map { CGPoint(x: $0.x * side, y: $0.y * side) }
            let length = MatrixAct.stopLength, travel = 0.35, period = Double(stops.count) * length
            let spot = CAGradientLayer()
            spot.type = .radial
            spot.colors = [white, UIColor.white.withAlphaComponent(0.6).cgColor, clear]
            spot.locations = [0, 0.42, 1]
            spot.startPoint = CGPoint(x: 0.5, y: 0.5)
            spot.endPoint = CGPoint(x: 1, y: 1)
            spot.bounds = CGRect(x: 0, y: 0, width: side * 0.42, height: side * 0.42)
            spot.position = stops[stops.count - 1]
            let glide = CAKeyframeAnimation(keyPath: "position")   // motion-ok: still under Reduce Motion (syncAct)
            var points: [CGPoint] = [], seconds: [Double] = []
            for (index, stop) in stops.enumerated() {
                points += [stops[(index + stops.count - 1) % stops.count], stop]
                seconds += [Double(index) * length, Double(index) * length + travel]
            }
            points.append(stops[stops.count - 1])
            seconds.append(period)
            glide.values = points.map { NSValue(cgPoint: $0) }
            glide.keyTimes = seconds.map { NSNumber(value: $0 / period) }
            glide.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: points.count - 1)
            time(glide, period, 0)
            spot.add(glide, forKey: "act")
            let ripples: [CALayer] = [(0.0, 1.0, 0.24), (0.14, 0.65, 0.32)].map { delay, peak, reachShare in
                let click = CAShapeLayer()
                let reach = side * reachShare
                click.bounds = CGRect(x: 0, y: 0, width: reach * 2, height: reach * 2)
                click.path = CGPath(ellipseIn: click.bounds.insetBy(dx: pitch, dy: pitch), transform: nil)
                click.fillColor = nil
                click.strokeColor = white
                click.lineWidth = pitch * 1.3
                click.opacity = 0
                click.position = stops[0]
                let hops = CAKeyframeAnimation(keyPath: "position")   // motion-ok: still under Reduce Motion (syncAct)
                hops.values = stops.map { NSValue(cgPoint: $0) }
                hops.keyTimes = (0...stops.count).map { NSNumber(value: Double($0) / Double(stops.count)) }
                hops.calculationMode = .discrete
                time(hops, period, travel + delay)
                let grow = CAKeyframeAnimation(keyPath: "transform.scale")   // motion-ok: still under Reduce Motion (syncAct)
                grow.values = [0.22, 1.12, 1.12]
                grow.keyTimes = [0, 0.55, 1]
                grow.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear)]
                let fade = opacity([peak, 0, 0], at: [0, 0.55 * length, length], over: length)
                grow.duration = length
                fade.duration = length
                let pop = CAAnimationGroup()
                pop.animations = [grow, fade]
                time(pop, length, travel + delay)
                click.add(hops, forKey: "act.where")
                click.add(pop, forKey: "act")
                return click
            }
            return [spot] + ripples
        case .waves:
            // Directional transmission rings going out the way the face turns.
            let origin = CGPoint(x: design.facing > 0 ? side * 0.1 : side * 0.9, y: side * 0.5)
            return (0..<3).map { index in
                let (wave, out) = ring(at: origin, from: pitch, to: side * 1.08, width: pitch * 1.5, over: 1.45)
                time(out, 1.45, Double(index) * 0.48)
                wave.add(out, forKey: "act")
                return wave
            }
        case .sparkle:
            // Three sets of LED constellations twinkling in staggered rhythm + a soft warm breathing core glow.
            let core = CAGradientLayer()
            core.type = .radial
            core.colors = [UIColor.white.withAlphaComponent(0.32).cgColor, clear]
            core.locations = [0, 1]
            core.startPoint = CGPoint(x: 0.5, y: 0.5)
            core.endPoint = CGPoint(x: 1, y: 1)
            core.frame = CGRect(x: 0, y: 0, width: side, height: side)
            let breathe = opacity([0.2, 0.9, 0.2], at: [0, 0.9, 1.8], over: 1.8)
            time(breathe, 1.8, 0)
            core.add(breathe, forKey: "act")
            let twinkles: [CALayer] = pictures.masks.enumerated().map { index, mask in
                let twinkle = CALayer()
                twinkle.contents = mask
                twinkle.contentsGravity = .resize
                twinkle.frame = CGRect(x: 0, y: 0, width: side, height: side)
                twinkle.opacity = 0
                let blink = opacity([0, 1, 0, 0], at: [0, 0.18, 0.58, 1.14], over: 1.14)
                time(blink, 1.14, Double(index) * 0.38)
                twinkle.add(blink, forKey: "act")
                return twinkle
            }
            return [core] + twinkles
        case .pulse, .flash:
            // Replying: a warm soft glow + gentle voice-ripple ring on each nod beat; Asking: an inquiring beacon ring
            // + crisp flash on each hop landing.
            let light = whole()
            let (peak, rise, fall) = effect == .pulse ? (0.34, 0.1, 0.22) : (0.58, 0.03, 0.22)
            var values = [0.0], seconds = [0.0]
            for mark in loop.marks where mark - rise > seconds[seconds.count - 1] && mark + fall < loop.period {
                values += [0, peak, 0]
                seconds += [mark - rise, mark, mark + fall]
            }
            values.append(0)
            seconds.append(loop.period)
            let glow = opacity(values, at: seconds, over: loop.period)
            time(glow, loop.period, 0)
            light.add(glow, forKey: "act")
            let middle = CGPoint(x: side * 0.5, y: side * 0.5)
            let ringDuration = effect == .pulse ? 0.55 : 0.62
            let beatRings: [CALayer] = loop.marks.prefix(6).map { mark in
                let (wave, out) = ring(at: middle, from: pitch * 1.4, to: side * 0.72,
                                       width: pitch * (effect == .pulse ? 1.5 : 1.7), over: ringDuration)
                let pad = CAAnimationGroup()
                pad.animations = [out]
                pad.duration = loop.period
                out.beginTime = mark
                time(pad, loop.period, 0)
                wave.add(pad, forKey: "act")
                return wave
            }
            return [light] + beatRings
        case .burst:
            // A bright flash as it jumps, three concentric celebration rings, then staggered sparkles.
            let light = whole()
            let flash = opacity([0.9, 0], at: [0, 0.45], over: 0.45)
            time(flash, 0.45, 0)
            light.add(flash, forKey: "act")
            let middle = CGPoint(x: side * 0.5, y: side * 0.5)
            let rings: [CALayer] = [0.04, 0.24, 0.52].map { delay in
                let (wave, out) = ring(at: middle, from: pitch, to: side * 0.84, width: pitch * 1.6, over: 0.72)
                time(out, 0.72, delay)
                wave.add(out, forKey: "act")
                return wave
            }
            let sparkles: [CALayer] = pictures.masks.enumerated().map { index, mask in
                let twinkle = CALayer()
                twinkle.contents = mask
                twinkle.contentsGravity = .resize
                twinkle.frame = CGRect(x: 0, y: 0, width: side, height: side)
                twinkle.opacity = 0
                let blink = opacity([0, 1, 0], at: [0, 0.2, 0.72], over: 0.72)
                time(blink, 0.72, 0.48 + Double(index) * 0.26)
                twinkle.add(blink, forKey: "act")
                return twinkle
            }
            return [light] + rings + sparkles
        case .flicker:
            // The panel stutters sharply with the glitch, then dims softly as the bot droops.
            let light = whole()
            let stutter = opacity([0.75, 0, 0.55, 0, 0.85, 0, 0.45, 0], at: [0, 0.07, 0.14, 0.21, 0.28, 0.35, 0.42, 0.49, loop.period],
                                  over: loop.period, discrete: true)
            time(stutter, loop.period, 0)
            light.add(stutter, forKey: "act")
            return [light]
        }
    }

    // MARK: [moods] A Shapes, Dots, or themed face acting it out

    /// Starts, swaps or stops the routines a non-matrix face plays: soft Shapes heads use 3D solid jelly + independent
    /// GPU pill eyes; Dots step a lamp at a time; Robot, Orb, Pixel and Glyph act over their grounded tile/shoulders.
    /// Nothing moves under Reduce Motion.
    private func syncFace(still: Bool) {
        let side = bounds.width
        guard let mood = shownMood, !still, window != nil, side > 0, !showsPhoto, !drawnKey.isEmpty else {
            if !actKey.isEmpty { clearAct() }
            return
        }
        let key = "\(mood.rawValue)|\(drawnKey)"
        guard key != actKey else { return }
        let grounded = usesGroundedMover
        let shown = (grounded ? mover : stage).presentation()?.transform
        let looking = gazeLayer.presentation()?.transform
        if !actKey.isEmpty { clearAct(settle: false) }
        actKey = key
        let (begin, seed) = actClock()
        let loop = FaceLoop(mood, facing: MatrixHead.shownFacing, seed: seed)
        playFace(loop, begin: begin, once: mood.once, from: shown, looking: looking)
    }

    /// Framed/tiled themes whose `groundLayer` (tile frame, robot shoulders) stays anchored while `mover` acts inside it.
    private var usesGroundedMover: Bool {
        if let theme = head.themed?.theme { return theme != "dots" }
        return head.tile != .none
    }

    private func playFace(_ loop: FaceLoop, begin: CFTimeInterval, once: Bool, from shown: CATransform3D?, looking: CATransform3D?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let theme = head.themed?.theme
        let lamps = theme == "dots"
        let isPixel = theme == "pixel"
        let samples = isPixel ? loop.samples(rate: 12) : loop.softSamples(once: once)
        let side = bounds.width, period = loop.period
        let jelly = playJelly(loop, samples: samples, begin: begin, once: once)
        let grounded = usesGroundedMover
        let bodyScale: Double = switch theme {
        case "robot": 0.65
        case "pixel": 0.72
        case "orb": 0.62
        case "glyph": 0.78
        case nil: head.tile != .none ? 0.72 : 1.0
        default: 1.0
        }
        moveBody(loop, samples: samples, on: grounded ? mover : stage, scale: bodyScale, discrete: isPixel,
                 begin: begin, once: once, from: shown, solid: jelly != nil)
        guard !eyesLayer.isHidden || jelly != nil else { return }
        for layer in [gazeLayer, eyesLayer] { layer.removeAnimation(forKey: "act.end") }
        gazeLayer.transform = CATransform3DIdentity
        func moments(_ times: [Double]) -> [NSNumber] { times.map { NSNumber(value: $0 / period) } }

        // Soft Shapes heads: independent 3D-seated GPU pill normal slit eyes! Each eye wraps individually round the 3D
        // cushion (far eye narrows and slips behind first during turns & pirouettes) with crisp rounded capsules.
        if let jelly {
            playVectorEyes(jelly: jelly, samples: samples, period: period, begin: begin, once: once)
            return
        }
        for eye in [leftEyeLayer, rightEyeLayer] {
            eye.removeAllAnimations()
            eye.isHidden = true
        }
        if eyesLayer.contents != nil { eyesLayer.isHidden = false }

        // Bitmap eyes (Dots lamps, Robot visor, Pixel, Orb, boarded Shapes).
        let look = CAKeyframeAnimation(keyPath: "transform")   // motion-ok: still under Reduce Motion (syncFace)
        if lamps {
            // A lamp at a time, and only across on a small head (a lamp is a big step there).
            let compact = side < 64, pitch = side * (compact ? 158 : 86) / 1024
            var steps: [CGPoint] = [], times: [Double] = []
            for sample in samples {
                let x = sample.eyes.x + sample.body.turn / 22, y = sample.eyes.y + sample.body.tip / 30
                let step = CGPoint(x: x >= 0.35 ? 1 : x <= -0.35 ? -1 : 0, y: compact ? 0 : y >= 0.35 ? 1 : y <= -0.35 ? -1 : 0)
                if steps.last != step {
                    steps.append(step)
                    times.append(sample.at)
                }
            }
            times[0] = 0
            look.values = steps.map { NSValue(caTransform3D: CATransform3DMakeTranslation($0.x * pitch, $0.y * pitch, 0)) }
            look.keyTimes = moments(times) + [1]
            look.calculationMode = .discrete
        } else {
            let reachFactor: Double = switch theme {
            case "robot": 0.048
            case "pixel": 0.04
            case "orb": 0.06
            default: 0.065 * moves.glance * (HeadGeometry.layout(head, compact: side < 64, darkPage: nil).placement?.k ?? 1)
            }
            let rx = reachFactor * side, ry = reachFactor * 0.85 * side
            look.values = samples.map { sample in
                let ex = min(max(sample.eyes.x, -1), 1), ey = min(max(sample.eyes.y, -1), 1)
                return NSValue(caTransform3D: CATransform3DMakeTranslation(ex * rx, ey * ry, 0))
            }
            look.keyTimes = moments(samples.map(\.at))
            if isPixel { look.calculationMode = .discrete }
        }
        settle(look, period: period, begin: begin, once: once)
        gazeLayer.add(look, forKey: "act")
        if let looking, let values = look.values, !values.isEmpty, !lamps, !isPixel {
            let then = Self.sample(in: samples, at: CACurrentMediaTime() + Self.bridgeLength - begin, period: period, once: once)
            bridge(gazeLayer, "transform", from: NSValue(caTransform3D: looking), to: values[min(then, values.count - 1)])
        }
        // Narrowing, widening and blinking, about the eyes' own middle.
        let stepped = (lamps && head.themed?.pattern == "face") || isPixel
        let dx = (eyeCentre.x - 0.5) * bounds.width, dy = (eyeCentre.y - 0.5) * bounds.height
        let lids = CAKeyframeAnimation(keyPath: "transform")   // motion-ok: still under Reduce Motion (syncFace)
        lids.values = samples.map { sample in
            let shut = min(max(sample.eyes.lids, 0), 1)
            let wideBoost = stepped ? 0 : min(max(sample.eyes.wide, 0), 1) * 0.14
            let open = stepped ? (shut >= 0.72 ? 0.08 : 1) : max(0.08, (1 + wideBoost) * (1 - 0.9 * shut))
            let blinkW = stepped ? 1 : 1 + 0.1 * shut
            var t = CATransform3DMakeTranslation(dx, dy, 0)
            t = CATransform3DScale(t, blinkW, open, 1)
            return NSValue(caTransform3D: CATransform3DTranslate(t, -dx, -dy, 0))
        }
        lids.keyTimes = moments(samples.map(\.at))
        if stepped { lids.calculationMode = .discrete }
        settle(lids, period: period, begin: begin, once: once)
        eyesLayer.add(lids, forKey: "act.lids")
    }

    /// Independent 3D-seated GPU pill eyes for a soft Shapes head while acting:
    /// - True rounded-capsule `bounds` + `cornerRadius = min(w, h) / 2` (never pinched during blinks/squints)
    /// - Top-down weighted eyelid closure (upper lid drops ~72%, lower lid lifts ~28%)
    /// - Near/far 3D camera-distance perspective scaling + per-eye cushion wrap & backface hide
    /// - Subtle stereo convergence when focusing closely vs widening when gazing up/out
    /// - Organic saccade velocity lean + 3D dome curvature micro-tilt
    /// - Loop-locked living micro-drift, subtle eye-breath, and 1-frame (~17 ms) natural left/right blink stagger
    private func playVectorEyes(jelly: (wobble: [FaceJelly], foot: CGPoint, outline: [CGPoint], solid: FaceSolid, layout: ShapeHeadLayout),
                                samples: [(at: Double, body: FaceBody, eyes: FaceEyes)], period: Double,
                                begin: CFTimeInterval, once: Bool) {
        let side = bounds.width
        let layout = jelly.layout
        let place = layout.placement ?? HeadPlacement(k: 1, tx: 0, ty: 0), unit = side / 1024
        let shape = HeadGeometry.form(head.form, seed: head.seed)
        let (fx, fy, faceSize) = shape.face
        let s = HeadGeometry.unit * faceSize, bold = side < 64 ? 1.2 : 1.0
        let gap = 0.2 * s * place.k * unit
        let eyeW = 0.15 * s * bold * place.k * unit
        let eyeH = 0.38 * s * place.k * unit
        let cx = (place.k * (512 + fx * HeadGeometry.unit) + place.tx) * unit
        let cy = (place.k * (512 + fy * HeadGeometry.unit) + place.ty) * unit
        let eyeColor = HeadRenderer.color(layout.eyeColor)
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let times = samples.map { NSNumber(value: $0.at / period) }
        func beyond(_ v: Double) -> Double { abs(v) <= 1 ? v : (v < 0 ? -1 : 1) * (1 + 0.35 * tanh((abs(v) - 1) / 0.35)) }
        let glance = moves.glance
        let count = samples.count

        // Smooth horizontal gaze velocity for natural saccade lean (follow-through into eye darts).
        let gazeVelX: [Double] = (0..<count).map { i in
            let prev = once ? max(0, i - 1) : (i - 1 + count) % count
            let next = once ? min(count - 1, i + 1) : (i + 1) % count
            let dt = max(abs(samples[next].at - samples[prev].at), 1.0 / 60.0)
            let dx = (samples[next].eyes.x - samples[prev].eyes.x) + (samples[next].body.turn - samples[prev].body.turn) / FaceEyes.across
            return dx / dt
        }
        // Loop-locked integer harmonics for subtle living micro-drift and eye-breath (zero seam on loop wrap).
        let driftK1 = once ? 0.0 : max(1, (period / 2.9).rounded())
        let driftK2 = once ? 0.0 : max(1, (period / 4.7).rounded())
        let breathK = once ? 0.0 : max(1, (period / 3.4).rounded())

        eyesLayer.isHidden = true
        let configs: [(CALayer, CGPoint, Double, Int)] = [
            (leftEyeLayer, CGPoint(x: cx - gap, y: cy), -1, 0),
            (rightEyeLayer, CGPoint(x: cx + gap, y: cy), 1, 1),   // 1-frame (~17 ms) natural blink stagger
        ]
        for (eyeLayer, restPoint, sideSign, blinkLag) in configs {
            let prevPos = eyeLayer.isHidden ? nil : eyeLayer.presentation()?.position
            let prevBounds = eyeLayer.isHidden ? nil : eyeLayer.presentation()?.bounds
            let prevRadius = eyeLayer.isHidden ? nil : eyeLayer.presentation()?.cornerRadius
            let prevTrans = eyeLayer.isHidden ? nil : eyeLayer.presentation()?.transform
            eyeLayer.removeAllAnimations()
            eyeLayer.bounds = CGRect(x: 0, y: 0, width: eyeW, height: eyeH)
            eyeLayer.cornerRadius = min(eyeW, eyeH) / 2
            eyeLayer.backgroundColor = eyeColor
            eyeLayer.contentsScale = scale
            eyeLayer.position = restPoint
            eyeLayer.transform = CATransform3DIdentity
            eyeLayer.opacity = 1
            eyeLayer.isHidden = false

            // 5-tap Gaussian smoothing on `lids` with 1-frame natural inter-eye stagger.
            let smoothLids: [Double] = (0..<count).map { i in
                func lid(_ idx: Int) -> Double {
                    let sIdx = idx - blinkLag
                    let j = once ? min(max(sIdx, 0), count - 1) : ((sIdx % count) + count) % count
                    return min(max(samples[j].eyes.lids, 0), 1)
                }
                return 0.12 * lid(i - 2) + 0.22 * lid(i - 1) + 0.32 * lid(i) + 0.22 * lid(i + 1) + 0.12 * lid(i + 2)
            }

            var positions: [NSValue] = []
            var boundsList: [NSValue] = []
            var radii: [Double] = []
            var transforms: [NSValue] = []
            var opacities: [Double] = []
            var needsFade = false

            for (i, sample) in samples.enumerated() {
                let totalTurn = sample.body.turn + beyond(sample.eyes.x) * FaceEyes.across * glance
                let totalTip = sample.body.tip + beyond(sample.eyes.y) * FaceEyes.down * glance
                let seat = jelly.solid.seat(restPoint, turn: totalTurn, tip: totalTip)
                var wx = 0.0, wy = 0.0
                if i < jelly.wobble.count {
                    let w = jelly.wobble[i]
                    let dx = restPoint.x - jelly.foot.x, dy = restPoint.y - jelly.foot.y
                    wx = w.squash * dx - w.lean * dy
                    wy = -w.squash * dy
                }
                // Subtle stereo gaze convergence: draw ~5% closer when leaning in closely, widen slightly gazing up.
                let focus = min(max(sample.body.tip / 20, -0.5), 1.0)
                let convergeX = -sideSign * gap * 0.055 * focus
                // Living loop-locked micro-drift & eye-breath (subtle organic life during held poses).
                let phase = sample.at / max(period, 1e-6)
                let driftX = once ? 0 : side * 0.005 * sin(2 * Double.pi * driftK1 * phase + 0.35 * sideSign)
                let driftY = once ? 0 : side * 0.004 * cos(2 * Double.pi * driftK2 * phase)
                let eyeBreath = once ? 0 : 0.025 * sin(2 * Double.pi * breathK * phase)

                let shut = smoothLids[i]
                let wideBoost = min(max(sample.eyes.wide, 0), 1) * 0.16
                let asym = min(max(sample.eyes.tilt, -1), 1) * 0.075 * sideSign

                // True capsule dimensions (near/far perspective depth + foreshortening + volume-preserving blink).
                let depthScale = seat.scale
                let baseW = eyeW * min(max(seat.wide * depthScale, 0.12), 1.25)
                let baseH = eyeH * min(max(seat.high * depthScale, 0.2), 1.25)
                let w = max(eyeW * 0.22, baseW * (1 + 0.16 * shut - 0.04 * wideBoost))
                let openFactor = max(0.0, (1 + wideBoost + asym + eyeBreath) * (1 - 0.90 * shut))
                let h = max(eyeW * 0.42, baseH * openFactor)

                // Top-down weighted eyelid closure: upper lid drops ~72%, lower lid lifts ~28%; perk lifts slightly up.
                let lidDropY = (baseH - h) * 0.22 * shut - wideBoost * baseH * 0.06

                positions.append(NSValue(cgPoint: CGPoint(x: restPoint.x + seat.dx + wx + convergeX + driftX,
                                                          y: restPoint.y + seat.dy + wy + lidDropY + driftY)))
                boundsList.append(NSValue(cgRect: CGRect(x: 0, y: 0, width: w, height: h)))
                radii.append(min(w, h) / 2)

                // Organic micro-tilt: saccade velocity lean + 3D dome contour alignment + curious asymmetry (clamped ±7°).
                let saccadeTilt = tanh(gazeVelX[i] * 0.11) * 0.08
                let domeTilt = 0.045 * min(max(sample.eyes.x, -1), 1) * min(max(sample.eyes.y, -1), 1)
                let curiousTilt = 0.04 * min(max(sample.eyes.tilt, -1), 1)
                let angle = min(max(saccadeTilt + domeTilt + curiousTilt, -0.13), 0.13)
                transforms.append(NSValue(caTransform3D: CATransform3DMakeRotation(angle, 0, 0, 1)))

                let k = min(max((seat.facing - 0.05) / 0.25, 0), 1)
                let op = k * k * (3 - 2 * k)
                if op < 0.99 { needsFade = true }
                opacities.append(op)
            }

            let posAnim = CAKeyframeAnimation(keyPath: "position")   // motion-ok: still under Reduce Motion (syncFace)
            posAnim.values = positions
            posAnim.keyTimes = times
            posAnim.calculationMode = .cubic
            settle(posAnim, period: period, begin: begin, once: once)
            eyeLayer.add(posAnim, forKey: "act")

            let boundsAnim = CAKeyframeAnimation(keyPath: "bounds")  // motion-ok: still under Reduce Motion (syncFace)
            boundsAnim.values = boundsList
            boundsAnim.keyTimes = times
            settle(boundsAnim, period: period, begin: begin, once: once)
            eyeLayer.add(boundsAnim, forKey: "act.lids")

            let radiusAnim = CAKeyframeAnimation(keyPath: "cornerRadius") // motion-ok: still under Reduce Motion (syncFace)
            radiusAnim.values = radii
            radiusAnim.keyTimes = times
            settle(radiusAnim, period: period, begin: begin, once: once)
            eyeLayer.add(radiusAnim, forKey: "act.radius")

            let rotAnim = CAKeyframeAnimation(keyPath: "transform")  // motion-ok: still under Reduce Motion (syncFace)
            rotAnim.values = transforms
            rotAnim.keyTimes = times
            settle(rotAnim, period: period, begin: begin, once: once)
            eyeLayer.add(rotAnim, forKey: "act.tilt")

            if needsFade {
                let fadeAnim = CAKeyframeAnimation(keyPath: "opacity")   // motion-ok: still under Reduce Motion (syncFace)
                fadeAnim.values = opacities
                fadeAnim.keyTimes = times
                settle(fadeAnim, period: period, begin: begin, once: once)
                eyeLayer.add(fadeAnim, forKey: "act.seen")
            }

            if let prevPos, let prevBounds, let prevRadius, let prevTrans {
                let then = Self.sample(in: samples, at: CACurrentMediaTime() + Self.bridgeLength - begin, period: period, once: once)
                let idx = min(then, positions.count - 1)
                bridge(eyeLayer, "position", from: NSValue(cgPoint: prevPos), to: positions[idx], key: "act.bridge")
                bridge(eyeLayer, "bounds", from: NSValue(cgRect: prevBounds), to: boundsList[idx], key: "act.bridge.bounds")
                bridge(eyeLayer, "cornerRadius", from: prevRadius, to: radii[idx], key: "act.bridge.radius")
                bridge(eyeLayer, "transform", from: NSValue(caTransform3D: prevTrans), to: transforms[idx], key: "act.bridge.shape")
            }
        }
    }

    // MARK: [moods] A soft body (a Shapes head's, while it acts)

    /// Whether this head's body is soft: a Shapes head out of a board.
    private var isSoft: Bool { !isMatrix && head.themed == nil && head.tile == .none }

    /// Cached 3D cushion geometry for `(head, side)` so mood transitions never stall recomputing rest rings.
    private static func cachedSolid(key: String, outline: [CGPoint], side: Double) -> FaceSolid {
        if let hit = solidCache[key] { return hit }
        if solidCache.count > 64 { solidCache.removeAll() }
        let made = FaceSolid(outline: outline, side: side)
        solidCache[key] = made
        return made
    }

    /// Shows the body as its outline and starts its jelly: a solid body turning and tipping (FaceSolid), squashing and
    /// leaning on after each move (FaceJelly). Easing in from where a jelly playing before shows, or from the body's
    /// picture.
    private func playJelly(_ loop: FaceLoop, samples: [(at: Double, body: FaceBody, eyes: FaceEyes)], begin: CFTimeInterval,
                           once: Bool) -> (wobble: [FaceJelly], foot: CGPoint, outline: [CGPoint], solid: FaceSolid, layout: ShapeHeadLayout)? {
        let side = bounds.width
        let layout = HeadGeometry.layout(head, compact: side < 64, darkPage: traitCollection.userInterfaceStyle == .dark)
        guard isSoft, layout.board == nil, layout.outline.count > 2 else {
            dropJelly()
            return nil
        }
        let place = layout.placement ?? HeadPlacement(k: 1, tx: 0, ty: 0), unit = side / 1024
        let points = layout.outline.map { CGPoint(x: (place.k * $0.x + place.tx) * unit, y: (place.k * $0.y + place.ty) * unit) }
        let foot = CGPoint(x: points.map(\.x).reduce(0, +) / Double(points.count), y: points.map(\.y).max() ?? side)
        let solidKey = "\(head.cacheKey)|\(Int((side * 100).rounded()))"
        let solid = Self.cachedSolid(key: solidKey, outline: points, side: side)
        let still = HeadRenderer.outlinePath(solid.edge(solid.rest))
        // From the picture, the outline at rest (the same points as every edge it moves through, so one morphs into the next).
        let shownPath = jellyLayer.isHidden ? still : jellyLayer.presentation()?.path
        let shownBend = jellyLayer.isHidden ? CATransform3DIdentity : jellyLayer.presentation()?.transform
        for key in ["act.end", "act.end.bend"] { jellyLayer.removeAnimation(forKey: key) }
        jellyKey = "\(head.cacheKey)|\(side)"
        jellyLayer.path = still
        jellyLayer.transform = CATransform3DIdentity
        jellyLayer.fillColor = HeadRenderer.color(layout.fill)
        jellyLayer.strokeColor = layout.rim.map { HeadRenderer.color($0) }
        jellyLayer.lineWidth = layout.rim == nil ? 0 : 14 * place.k * unit
        jellyLayer.contentsScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        jellyLayer.isHidden = false
        bodyLayer.isHidden = true

        // The edge: the solid seen turned and tipped at 30 keyframes/s (Core Animation interpolates cleanly to 60/120 Hz),
        // smoothed so it never boils or flickers, worked out off the main thread.
        let pathSamples: [(at: Double, turn: Double, tip: Double)] = samples.enumerated().compactMap { i, s in
            (i % 2 == 0 || i == samples.count - 1) ? (at: s.at, turn: s.body.turn, tip: s.body.tip) : nil
        }
        let poses = pathSamples
        let act = actKey, period = loop.period
        Task { [weak self] in
            let edges = await Task.detached(priority: .userInitiated) {
                solid.smoothed(solid.reaches(poses.map { ($0.turn, $0.tip) }), loop: !once).map(solid.edge)
            }.value
            guard let self, self.actKey == act, !self.jellyLayer.isHidden else { return }
            let paths = edges.map(HeadRenderer.outlinePath)
            let turning = CAKeyframeAnimation(keyPath: "path")   // motion-ok: still under Reduce Motion (syncFace)
            turning.values = paths
            turning.keyTimes = poses.map { NSNumber(value: $0.at / period) }
            self.settle(turning, period: period, begin: begin, once: once)
            let shown = self.jellyLayer.presentation()?.path
            self.jellyLayer.removeAnimation(forKey: "act.bridge.path")
            self.jellyLayer.add(turning, forKey: "act.path")
            if let shown {
                let soon = CACurrentMediaTime() + Self.bridgeLength - begin
                var t = once ? min(max(soon, 0), period) : soon.truncatingRemainder(dividingBy: period)
                if t < 0 { t += period }
                let then = poses.lastIndex { $0.at <= t } ?? 0
                self.bridge(self.jellyLayer, "path", from: shown, to: paths[then], key: "act.bridge.path")
            }
        }
        // The body: squashed and leant from its foot.
        let wobble = FaceJelly.follow(samples, period: loop.period, once: once)
        let pivot = CGPoint(x: foot.x - bounds.midX, y: foot.y - bounds.midY)
        func bend(_ jelly: FaceJelly) -> CATransform3D {
            var shape = CATransform3DMakeScale(1 + jelly.squash, 1 - jelly.squash, 1)
            shape.m21 = -jelly.lean
            let there = CATransform3DConcat(CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0), shape)
            return CATransform3DConcat(there, CATransform3DMakeTranslation(pivot.x, pivot.y, 0))
        }
        let shape = CAKeyframeAnimation(keyPath: "transform")   // motion-ok: still under Reduce Motion (syncFace)
        shape.values = wobble.map { NSValue(caTransform3D: bend($0)) }
        shape.keyTimes = samples.map { NSNumber(value: $0.at / loop.period) }
        settle(shape, period: loop.period, begin: begin, once: once)
        jellyLayer.add(shape, forKey: "act")
        if let shownPath, let shownBend {
            let then = Self.sample(in: samples, at: CACurrentMediaTime() + Self.bridgeLength - begin, period: loop.period, once: once)
            bridge(jellyLayer, "path", from: shownPath, to: still, key: "act.bridge.path")
            bridge(jellyLayer, "transform", from: NSValue(caTransform3D: shownBend), to: NSValue(caTransform3D: bend(wobble[then])))
        }
        return (wobble, foot, points, solid, layout)
    }

    /// The act is over: the jelly and GPU pill eyes ease smoothly back to rest, then the body's picture shows again.
    private func settleJelly() {
        guard !jellyLayer.isHidden else { return }
        let shownPath = jellyLayer.presentation()?.path, shownBend = jellyLayer.presentation()?.transform
        for key in ["act", "act.path", "act.bridge", "act.bridge.path"] { jellyLayer.removeAnimation(forKey: key) }
        if let shownPath, let rest = jellyLayer.path {
            bridge(jellyLayer, "path", from: shownPath, to: rest, key: "act.end")
        }
        if let shownBend {
            bridge(jellyLayer, "transform", from: NSValue(caTransform3D: shownBend), to: NSValue(caTransform3D: CATransform3DIdentity),
                   key: "act.end.bend")
        }
        for eye in [leftEyeLayer, rightEyeLayer] where !eye.isHidden {
            let shownPos = eye.presentation()?.position, shownBounds = eye.presentation()?.bounds
            let shownRadius = eye.presentation()?.cornerRadius, shownTrans = eye.presentation()?.transform
            eye.removeAllAnimations()
            if let shownPos {
                bridge(eye, "position", from: NSValue(cgPoint: shownPos), to: NSValue(cgPoint: eye.position), key: "act.end")
            }
            if let shownBounds {
                bridge(eye, "bounds", from: NSValue(cgRect: shownBounds), to: NSValue(cgRect: eye.bounds), key: "act.end.bounds")
            }
            if let shownRadius {
                bridge(eye, "cornerRadius", from: shownRadius, to: eye.cornerRadius, key: "act.end.radius")
            }
            if let shownTrans {
                bridge(eye, "transform", from: NSValue(caTransform3D: shownTrans), to: NSValue(caTransform3D: CATransform3DIdentity),
                       key: "act.end.shape")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bridgeLength) { [weak self] in
            guard let self, self.actKey.isEmpty else { return }
            self.dropJelly()
        }
    }

    /// No jelly: the body's picture shows.
    private func dropJelly() {
        jellyLayer.removeAllAnimations()
        jellyLayer.isHidden = true
        for eye in [leftEyeLayer, rightEyeLayer] {
            eye.removeAllAnimations()
            eye.isHidden = true
        }
        bodyLayer.isHidden = false
        if eyesLayer.contents != nil { eyesLayer.isHidden = false }
    }

    // MARK: Motion while the bot works

    private var moving = false
    private func updateMotion() {
        let still = HeadMotionSettings.shared.isStill
        // Nothing moves at rest. [photoheads] A photo keeps still while its bot works too.
        if isMatrix {
            syncAct(still: still)
            return
        }
        if playsRoutines {
            if moving {
                moving = false
                mover.removeAllAnimations()
                eyesLayer.removeAnimation(forKey: "look")
            }
            syncFace(still: still)
            return
        }
        let shouldMove = busy && window != nil && !still && bounds.width > 0 && themedWorkMotion && !showsPhoto
        if shouldMove == moving, !shouldMove || mover.animation(forKey: "work") != nil { return }
        moving = shouldMove
        mover.removeAllAnimations()
        eyesLayer.removeAllAnimations()
        guard shouldMove, let record = head.themed else { return }
        let now = CACurrentMediaTime()
        switch record.theme {
        case "robot", "glyph":
            // dh-sway (rotate −2° at 50 % of 2.6 s, from the bottom); a robot's eyes also look up and over (dh-look).
            let sway = CAKeyframeAnimation(keyPath: "transform.rotation.z")   // motion-ok: heads are still under Reduce Motion (isStill)
            sway.values = [0, -2 * Double.pi / 180, 0]
            sway.keyTimes = [0, 0.5, 1]
            sway.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            sway.duration = 2.6
            sway.repeatCount = .infinity
            sway.beginTime = now - phase
            mover.add(sway, forKey: "work")
            guard record.theme == "robot" else { return }
            // The look is in the face's own units, which the robot's visor scales by k.
            let k = ThemeHeadSVG.round(ThemeHeadSVG.geometry(record.shape, seed: record.seed).k * 100) / 100
            let unit = bounds.width / 1024 * k
            let look = CAKeyframeAnimation(keyPath: "transform.translation")   // motion-ok: heads are still under Reduce Motion (isStill)
            look.values = [CGSize.zero, CGSize(width: 22 * unit, height: -26 * unit), CGSize(width: 22 * unit, height: -26 * unit), CGSize.zero]
                .map { NSValue(cgSize: $0) }
            look.keyTimes = [0, 0.4, 0.6, 1]
            look.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
            look.duration = 2.6
            look.repeatCount = .infinity
            look.beginTime = now - phase
            eyesLayer.add(look, forKey: "look")
        case "pixel":
            // dh-bob: up 24 units and back in two held steps a second.
            let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")   // motion-ok: heads are still under Reduce Motion (isStill)
            bob.values = [0, -24 * bounds.width / 1024, 0]
            bob.keyTimes = [0, 0.5, 1]
            bob.calculationMode = .discrete
            bob.duration = 1
            bob.repeatCount = .infinity
            bob.beginTime = now - phase
            mover.add(bob, forKey: "work")
        default:
            break
        }
    }
}

/// Whether heads may move (not under Reduce Motion, Low Power Mode or heat), observed once for every `HeadView`.
///
/// Block observers on the main queue only: `NSProcessInfoPowerStateDidChange` is posted on a background queue, and a
/// main-actor `@objc` selector observer traps there under Swift 6's isolation checks (Low Power Mode turning on or
/// off, which iOS also does by itself at 80 % charge, crashed the app).
final class HeadMotionSettings {
    static let shared = HeadMotionSettings()

    /// True while heads must keep still.
    private(set) var isStill: Bool
    private let views = NSHashTable<HeadView>.weakObjects()
    private var tokens: [NSObjectProtocol] = []

    private init() {
        isStill = Self.readStill()
        let center = NotificationCenter.default
        let names: [Notification.Name] = [UIAccessibility.reduceMotionStatusDidChangeNotification,
                                          .NSProcessInfoPowerStateDidChange,
                                          PowerState.changed,   // [settings] Low Power Mode or heat, through the one service
                                          UIApplication.willEnterForegroundNotification]
        tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { HeadMotionSettings.shared.update() }
            }
        }
    }

    private static func readStill() -> Bool {
        HQMotion.decorativeStill   // [settings] Reduce Motion, Low Power Mode or a hot phone (3x-settings §3)
    }

    /// Adds a view to tell about changes (held weakly; a freed view simply drops out).
    func register(_ view: HeadView) { views.add(view) }

    /// Re-reads the settings and tells every live head.
    func update() {
        isStill = Self.readStill()
        for view in views.allObjects { view.motionSettingsChanged() }
    }
}

/// A bot's head in SwiftUI. At rest it is a cached picture (cheap in list cells); while working it hosts a `HeadView`.
struct HeadImage: View {
    var head: Head
    var size: CGFloat
    var working: Bool = false
    var phase: Double = 0
    /// [photoheads] Set by the `raw:profile:` and `head:profile:` initialisers only: the bot whose photo, when it wears
    /// one, is drawn instead of the head (docs/spec/3x-photoheads.md §4.5). A caller that passes a `Head` alone never
    /// gets a photo (Edit Bot's staged removal).
    private var profile: String?
    /// [moods] The face acts out what the bot is doing (a bot's row, tile or chip): `HeadView.follow`.
    private var moods = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    init(head: Head, size: CGFloat, working: Bool = false, phase: Double = 0) {
        self.head = head; self.size = size; self.working = working; self.phase = phase
    }

    init(raw: JSONValue?, profile: String, size: CGFloat, working: Bool = false, moods: Bool = false) {
        self.init(head: Head.resolve(raw, profile: profile), size: size, working: working, phase: HeadView.phase(for: profile))
        self.profile = profile
        self.moods = moods
    }

    /// A head the caller already resolved (the Sessions chips resolve theirs once), still showing the bot's photo when
    /// it wears one: the chips drew the head over a tester's picture without it.
    init(head: Head, profile: String, size: CGFloat, working: Bool = false, phase: Double = 0, moods: Bool = false) {
        self.init(head: head, size: size, working: working, phase: phase)
        self.profile = profile
        self.moods = moods
    }

    /// [photoheads] The bot's photo when it wears one. Reading `version` has this face drawn again when one arrives or goes.
    private var photo: UIImage? {
        guard let profile else { return nil }
        _ = BotFaces.shared.version
        return BotFaces.shared.photo(for: profile)
    }

    var body: some View {
        Group {
            if let photo {
                // An app-icon tile (22.37 % of the width), never a circle; aspect-filled like `object-fit: cover`.
                Image(uiImage: photo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * BotFaces.cornerShare, style: .continuous))
                    .accessibilityIgnoresInvertColors()
            } else if working || moods || size >= 32 {
                HeadViewRepresentable(head: head, working: working, phase: phase, follows: moods ? profile : nil)
            } else {
                SmallHeadPicture(head: head, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// [perf] A head under 32 pt (More pages, ConnectApps, the group pickers): a Shapes head draws in place on first
/// paint, as everywhere else; a themed head (an SVG generated, parsed and drawn: several times the work) arrives off
/// the main thread, with a soft tile until it lands, as `HeadView` and the Edit Head strips already do.
private struct SmallHeadPicture: View {
    var head: Head
    var size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    /// The off-main picture with the key it was drawn for, so a reused view never shows another head's face.
    @State private var drawn: (key: String, image: UIImage)?

    var body: some View {
        let dark = colorScheme == .dark
        // A themed head looks the same on a dark page (HeadImageCache's key ignores `dark` for it too).
        let key = "\(head.cacheKey)|\(size)|\(displayScale)|\(head.themed == nil && dark)"
        let cache = HeadImageCache.shared
        let picture = cache.cachedImage(for: head, side: size, scale: displayScale, dark: dark)
            ?? (drawn?.key == key ? drawn?.image : nil)
            ?? (head.themed == nil ? cache.image(for: head, side: size, scale: displayScale, dark: dark) : nil)
        Group {
            if let picture {
                Image(uiImage: picture).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Color(uiColor: .tertiarySystemFill))
            }
        }
        .task(id: key) {
            guard head.themed != nil,
                  cache.cachedImage(for: head, side: size, scale: displayScale, dark: dark) == nil else { return }
            // `images(for:)` stores the picture in the shared cache too, so the next row with this head hits.
            let images = await cache.images(for: head, side: size, scale: displayScale, dark: dark, state: .idle, parts: [.all])
            guard !Task.isCancelled, let image = images.first else { return }
            drawn = (key, image)
        }
    }
}

private struct HeadViewRepresentable: UIViewRepresentable {
    var head: Head
    var working: Bool
    var phase: Double
    var follows: String?
    func makeUIView(context: Context) -> HeadView { HeadView(frame: .zero) }
    func updateUIView(_ view: HeadView, context: Context) { view.configure(head: head, working: working, phase: phase, follows: follows) }
}
