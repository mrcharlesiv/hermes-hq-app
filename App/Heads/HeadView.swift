// A bot's head on screen: two cached pictures, the head without its eyes and the eyes alone, so motion is only
// transforms and nothing is redrawn. At rest it blinks and a Shapes head glances about now and then (`motion.ts`);
// while its bot works a robot sways and looks up, a pixel creature bobs (spec 02 §10.5, `bot-head.css`). A dot-matrix
// head is one picture swapped for another pose (each drawn once): it blinks and glances in whole LED steps and a light
// runs over it now and then. [moods] While its bot is at something, a dot-matrix, Shapes or Dots face acts it out
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
    /// A dot-matrix head's light over its LEDs (an idle shimmer, the scan while working): a band of light masked by the
    /// head's own picture, so the dots light up and nothing is redrawn.
    private let sheen = CAGradientLayer()
    private let sheenMask = CALayer()
    /// Where a dot-matrix head's eyes are now (a glance leaves them there; a blink closes them there).
    private var matrixPose = MatrixPose.rest
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
    /// The head and size the jelly was drawn for: another head drops it at once (a reused row), this one settles it.
    private var jellyKey = ""
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
        mover.anchorPoint = CGPoint(x: 0.5, y: 0.94)
        stage.addSublayer(groundLayer)
        stage.addSublayer(mover)
        mover.addSublayer(bodyLayer)
        mover.addSublayer(gazeLayer)
        gazeLayer.addSublayer(eyesLayer)
        sheenMask.contentsGravity = .resize
        sheenMask.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        sheen.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "locations": NSNull(), "colors": NSNull(),
                         "startPoint": NSNull(), "endPoint": NSNull()]
        sheen.mask = sheenMask
        sheen.locations = Self.sheenAway
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
        stage.actions = ["bounds": NSNull(), "position": NSNull()]
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

    /// Whether the face is taken up with its bot (off the idle clock): a face that plays the routines acting, another
    /// face busy.
    private var acting: Bool { isMatrix || playsRoutines ? shownMood != nil : busy }

    /// [moods] A Shapes or Dots head: it acts out its bot's doings with the routines itself (a dot-matrix head does too,
    /// through its act); the other themes keep their own work motion.
    private var playsRoutines: Bool { !isMatrix && (head.themed == nil || head.themed?.theme == "dots") }

    /// The web's per-head offset: `(name.length · 0.7) % 5` seconds.
    static func phase(for name: String) -> Double { (Double(name.count) * 0.7).truncatingRemainder(dividingBy: 5) }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }

    override func layoutSubviews() {
        super.layoutSubviews()
        stage.bounds = bounds
        stage.position = CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.94)
        groundLayer.frame = stage.bounds
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

    /// How this head moves at rest (`movesFor`): a Shapes head by its parts; another theme blinks when it has eyes; a
    /// dot-matrix head blinks and glances.
    private var moves: (blinks: Bool, glance: Double) {
        if isMatrix { return (true, 1) }
        guard let record = head.themed else { return HeadGeometry.motion(head) }
        return (Self.hasFace(record), 0)
    }

    private var isMatrix: Bool { head.theme == .matrix }

    /// Whether there are eyes for the idle clock to move: a dot-matrix head's are in its one picture.
    private var hasIdleFace: Bool { isMatrix || !eyesLayer.isHidden }

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
        let layered = !still && (themed ? (working && (themedWorkMotion || playsRoutines)) || moves.blinks
            : working || moves.blinks || moves.glance > 0)
        let key = "\(head.cacheKey)|\(side)|\(scale)|\(themed ? false : dark)|\(working)|\(layered)"
        if key != drawnKey {
            drawnKey = key
            let cache = HeadImageCache.shared
            let state: HeadState = working && !playsRoutines ? .thinking : .idle
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
        if jellyKey != "\(head.cacheKey)|\(side)" { dropJelly() }
        gazeLayer.removeAllAnimations()
        gazeLayer.transform = CATransform3DIdentity
        // A dot-matrix head shown here before: its swaps and its light go with it.
        bodyLayer.removeAllAnimations()
        sheen.removeAllAnimations()
        sheen.isHidden = true
        sheenMask.contents = nil
        clearAct()
        updateMotion()
    }

    // MARK: The dot-matrix head

    /// A dot-matrix head: its picture at rest, and the same picture as the mask its light runs through (what its bot
    /// is doing plays over it: `syncAct`).
    private func showMatrix(side: CGFloat, scale: CGFloat, dark: Bool) {
        let key = "\(head.cacheKey)|\(side)|\(scale)|\(dark)|matrix"
        guard key != drawnKey else { return }
        drawnKey = key
        matrixPose = .rest
        let picture = matrixFrame(matrixPose)?.cgImage
        groundLayer.contents = nil
        eyesLayer.contents = nil
        eyesLayer.isHidden = true
        gazeLayer.removeAllAnimations()
        gazeLayer.transform = CATransform3DIdentity
        // Whatever moved the head shown before (a Shapes head breathing, a robot swaying) stops; `updateMotion` starts
        // this one's.
        stage.removeAllAnimations()
        mover.removeAllAnimations()
        eyesLayer.removeAllAnimations()
        moving = false
        dropJelly()
        bodyLayer.removeAllAnimations()
        bodyLayer.contents = picture
        sheenMask.contents = picture
        for layer in [bodyLayer, sheenMask] { layer.contentsScale = scale }
        // White light on glowing LEDs; on a light page a softer white, so coloured dots brighten without washing out.
        let light = UIColor.white.withAlphaComponent(dark ? 0.62 : 0.45).cgColor
        sheen.colors = [UIColor.white.withAlphaComponent(0).cgColor, light, UIColor.white.withAlphaComponent(0).cgColor]
        sheen.removeAllAnimations()
        sheen.locations = Self.sheenAway
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

    /// Where the band of light rests: off the head (every stop before the start).
    private static let sheenAway: [NSNumber] = [-0.5, -0.25, 0]

    /// A dot-matrix blink: the lids drop a row, shut and lift again (0.2 s), as three whole pictures.
    private func blinkMatrix() {
        var half = matrixPose, shut = matrixPose
        half.lids = 1
        shut.lids = 2
        let frames = [half, shut, half].compactMap { matrixFrame($0)?.cgImage }
        guard frames.count == 3 else { return }
        let blink = CAKeyframeAnimation(keyPath: "contents")   // motion-ok: heads are still under Reduce Motion (isStill)
        blink.values = frames
        blink.keyTimes = [0, 0.28, 0.72, 1]
        blink.calculationMode = .discrete
        blink.duration = 0.2
        bodyLayer.add(blink, forKey: "blink")
    }

    /// A dot-matrix glance: the eyes jump a dot to the side or up (as LEDs do), and stay there. The rest spots read
    /// as: far left, right, up, up and left.
    private func glanceMatrix(to spot: CGPoint) {
        let gaze = spot.x <= -0.1 ? -1 : spot.x <= -0.05 ? 1 : 0
        matrixPose = MatrixPose(gaze: gaze, lift: spot.y < -0.005 ? -1 : 0)
        guard let picture = matrixFrame(matrixPose)?.cgImage else { return }
        bodyLayer.removeAnimation(forKey: "blink")
        bodyLayer.contents = picture
    }

    /// Now and then at rest, a light runs across the LEDs (1.1 s, corner to corner).
    func shimmer() {
        guard idleEligible, isMatrix, sheenMask.contents != nil else { return }
        sheen.startPoint = CGPoint(x: 0, y: 0.15)
        sheen.endPoint = CGPoint(x: 1, y: 0.85)
        sheen.isHidden = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.sheen.animation(forKey: "work") == nil, self.sheen.animation(forKey: "shimmer") == nil else { return }
            self.sheen.isHidden = true
        }
        let sweep = CABasicAnimation(keyPath: "locations")   // motion-ok: heads are still under Reduce Motion (isStill)
        sweep.fromValue = [-0.6, -0.35, -0.1]
        sweep.toValue = [1.1, 1.35, 1.6]
        sweep.duration = 1.1
        sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.35, 1)
        sheen.add(sweep, forKey: "shimmer")
        CATransaction.commit()
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

    /// The act stops and the face looks ahead again.
    private func endAct() {
        clearAct()
        matrixPose = .rest
        bodyLayer.contents = matrixFrame(.rest)?.cgImage
    }

    /// Whatever an act left: its swaps, its moves, its light. `settle`: the body eases back to standing (not when another
    /// act takes over: that one eases in from where it is).
    private func clearAct(settle: Bool = true) {
        let moved: [(CALayer, CATransform3D)] = !settle ? [] : [stage, gazeLayer, eyesLayer].compactMap { layer in
            guard layer.animation(forKey: "act") != nil || layer.animation(forKey: "act.lids") != nil,
                  let shown = layer.presentation()?.transform else { return nil }
            return (layer, shown)
        }
        actKey = ""
        bodyLayer.removeAnimation(forKey: "act")
        for layer in [stage, gazeLayer, eyesLayer] {
            for key in Self.actKeys { layer.removeAnimation(forKey: key) }
        }
        flareMask.sublayers?.forEach { $0.removeFromSuperlayer() }
        flare.isHidden = true
        flare.contents = nil
        for (layer, shown) in moved where !CATransform3DEqualToTransform(shown, layer.transform) {
            bridge(layer, "transform", from: NSValue(caTransform3D: shown), to: NSValue(caTransform3D: layer.transform), key: "act.end")
        }
        // Another act taking over moves the jelly on from where it is (`playJelly`); else it settles, then the picture shows.
        if settle { settleJelly() }
    }

    private static let actKeys = ["act", "act.bridge", "act.end", "act.lids", "act.seen"]

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
        moveBody(loop, begin: begin, once: act.once, from: shown)
    }

    // MARK: [moods] The body, for every face that plays the routines

    /// The body at `body`, as the stage's transform: squashed from where it stands, tipped, turned and tilted about its
    /// middle with a little depth, then moved. A `solid` body (FaceSolid) turns and tips in its own outline instead.
    private func bodyTransform(_ body: FaceBody, solid: Bool = false) -> CATransform3D {
        let side = bounds.width, middle = side * 0.44   // from where it stands (the stage's anchor) up to its middle
        let degree = Double.pi / 180, squash = body.squash * (isSoft ? 1.6 : 1)
        var depth = CATransform3DIdentity
        depth.m34 = -1 / (side * 2.5)
        let turns = solid ? [] : [CATransform3DMakeRotation(-body.tip * degree, 1, 0, 0), CATransform3DMakeRotation(body.turn * degree, 0, 1, 0)]
        let steps = [CATransform3DMakeScale(1 + squash, 1 - squash, 1), CATransform3DMakeTranslation(0, middle, 0)] + turns
            + [CATransform3DMakeRotation(body.roll * degree, 0, 0, 1), depth, CATransform3DMakeTranslation(body.x * side, body.y * side - middle, 0)]
        return steps.dropFirst().reduce(steps[0]) { CATransform3DConcat($0, $1) }
    }

    /// Plays `loop`'s body on the stage from `begin` (as `samples` of it, if given), easing in from `shown` (where the
    /// last act left it).
    private func moveBody(_ loop: FaceLoop, samples given: [(at: Double, body: FaceBody, eyes: FaceEyes)]? = nil, begin: CFTimeInterval,
                          once: Bool, from shown: CATransform3D?, solid: Bool = false) {
        let samples = given ?? loop.samples()
        stage.removeAnimation(forKey: "act.end")
        let move = CAKeyframeAnimation(keyPath: "transform")   // motion-ok: still under Reduce Motion (syncAct, syncFace)
        move.values = samples.map { NSValue(caTransform3D: bodyTransform($0.body, solid: solid)) }
        move.keyTimes = samples.map { NSNumber(value: $0.at / loop.period) }
        settle(move, period: loop.period, begin: begin, once: once)
        stage.add(move, forKey: "act")
        if let shown {
            let then = samples[Self.sample(in: samples, at: CACurrentMediaTime() + Self.bridgeLength - begin, period: loop.period, once: once)]
            bridge(stage, "transform", from: NSValue(caTransform3D: shown), to: NSValue(caTransform3D: bodyTransform(then.body, solid: solid)))
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
            return (ring, both)
        }
        switch effect {
        case .orbit, .radar:
            // A comet round the outline (its lit picture is the edge only), or a radar's sweep over the whole head: a
            // conic light, bright at its leading edge and fading behind, turning about the middle.
            let sweep = CAGradientLayer()
            sweep.type = .conic
            let reach = side * 1.5
            sweep.frame = CGRect(x: (side - reach) / 2, y: (side - reach) / 2, width: reach, height: reach)
            sweep.startPoint = CGPoint(x: 0.5, y: 0.5)
            sweep.endPoint = CGPoint(x: 0.5, y: 0)
            let tail = effect == .orbit ? 0.3 : 0.2
            sweep.colors = [clear, clear, white]
            sweep.locations = [0, NSNumber(value: 1 - tail), 1]
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")   // motion-ok: still under Reduce Motion (syncAct)
            turn.fromValue = 0
            turn.toValue = 2 * Double.pi
            time(turn, effect == .orbit ? 1.8 : 1.4, 0)
            sweep.add(turn, forKey: "act")
            return [sweep]
        case .scan:
            // A line of light down the face, a line read.
            let band = CAGradientLayer()
            let height = side * 0.32
            band.frame = CGRect(x: 0, y: -height, width: side, height: height)
            band.colors = [clear, white, clear]
            band.locations = [0, 0.5, 1]
            let down = CABasicAnimation(keyPath: "position.y")   // motion-ok: still under Reduce Motion (syncAct)
            down.fromValue = -height / 2
            down.toValue = side + height / 2
            down.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            time(down, 1.6, 0)
            band.add(down, forKey: "act")
            return [band]
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
                time(fall, index == 0 ? 1.5 : 2.4, 0)
                drop.add(fall, forKey: "act")
                return drop
            }
        case .typing:
            // LED by LED along each line in turn, then both clear (each of writing's routines is two lines and a pause).
            let period = 2 * MatrixAct.lineLength + MatrixAct.typingPause
            return MatrixActMasks.typingLines(design).enumerated().map { index, line in
                let count = line.last - line.first + 1
                let bar = CALayer()
                bar.backgroundColor = white
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
        case .pointer:
            // A spot of light gliding from stop to stop, and a ripple each time it lands (a click); the eyes follow it
            // (each of browsing's routines goes round the stops once).
            let stops = MatrixAct.stops.map { CGPoint(x: $0.x * side, y: $0.y * side) }
            let length = MatrixAct.stopLength, travel = 0.35, period = Double(stops.count) * length
            let spot = CAGradientLayer()
            spot.type = .radial
            spot.colors = [white, UIColor.white.withAlphaComponent(0.55).cgColor, clear]
            spot.locations = [0, 0.4, 1]
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
            let click = CAShapeLayer()
            let reach = side * 0.24
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
            time(hops, period, travel)
            let grow = CAKeyframeAnimation(keyPath: "transform.scale")   // motion-ok: still under Reduce Motion (syncAct)
            grow.values = [0.25, 1.1, 1.1]
            grow.keyTimes = [0, 0.55, 1]
            grow.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear)]
            let fade = opacity([0.95, 0, 0], at: [0, 0.55 * length, length], over: length)
            grow.duration = length
            fade.duration = length
            let pop = CAAnimationGroup()
            pop.animations = [grow, fade]
            time(pop, length, travel)
            click.add(hops, forKey: "act.where")
            click.add(pop, forKey: "act")
            return [spot, click]
        case .waves:
            // Rings from the far side, going out the way the face turns.
            let origin = CGPoint(x: design.facing > 0 ? side * 0.1 : side * 0.9, y: side * 0.5)
            return (0..<3).map { index in
                let (wave, out) = ring(at: origin, from: pitch, to: side * 1.05, width: pitch * 1.4, over: 1.5)
                time(out, 1.5, Double(index) * 0.5)
                wave.add(out, forKey: "act")
                return wave
            }
        case .sparkle:
            // Three sets of LEDs twinkling in turn.
            return pictures.masks.enumerated().map { index, mask in
                let twinkle = CALayer()
                twinkle.contents = mask
                twinkle.contentsGravity = .resize
                twinkle.frame = CGRect(x: 0, y: 0, width: side, height: side)
                twinkle.opacity = 0
                let blink = opacity([0, 1, 0, 0], at: [0, 0.2, 0.6, 1.2], over: 1.2)
                time(blink, 1.2, Double(index) * 0.4)
                twinkle.add(blink, forKey: "act")
                return twinkle
            }
        case .pulse, .flash:
            // A soft glow over the head as it dips in each nod, or a flash as it lands from each hop (the routines' marks).
            let light = whole()
            let (peak, rise, fall) = effect == .pulse ? (0.3, 0.1, 0.2) : (0.55, 0.03, 0.22)
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
            return [light]
        case .burst:
            // A flash as it jumps, two rings out from the middle, then sparkles.
            let light = whole()
            let flash = opacity([0.85, 0], at: [0, 0.45], over: 0.45)
            time(flash, 0.45, 0)
            light.add(flash, forKey: "act")
            let middle = CGPoint(x: side * 0.5, y: side * 0.5)
            let rings: [CALayer] = [0.05, 0.3].map { delay in
                let (wave, out) = ring(at: middle, from: pitch, to: side * 0.78, width: pitch * 1.6, over: 0.75)
                time(out, 0.75, delay)
                wave.add(out, forKey: "act")
                return wave
            }
            let sparkles: [CALayer] = pictures.masks.enumerated().map { index, mask in
                let twinkle = CALayer()
                twinkle.contents = mask
                twinkle.contentsGravity = .resize
                twinkle.frame = CGRect(x: 0, y: 0, width: side, height: side)
                twinkle.opacity = 0
                let blink = opacity([0, 1, 0], at: [0, 0.2, 0.7], over: 0.7)
                time(blink, 0.7, 0.5 + Double(index) * 0.28)
                twinkle.add(blink, forKey: "act")
                return twinkle
            }
            return [light] + rings + sparkles
        case .flicker:
            // The panel stutters with the glitch.
            let light = whole()
            let stutter = opacity([0.7, 0, 0.5, 0, 0.8, 0, 0.4, 0], at: [0, 0.07, 0.14, 0.21, 0.28, 0.35, 0.42, 0.49, loop.period],
                                  over: loop.period, discrete: true)
            time(stutter, loop.period, 0)
            light.add(stutter, forKey: "act")
            return [light]
        }
    }

    // MARK: [moods] A Shapes or Dots face acting it out

    /// Starts, swaps or stops the routines a Shapes or Dots face plays: the body as a dot-matrix head's, the eyes
    /// gliding about (a Shapes head's) or stepping a lamp at a time (a Dots head's), narrowing and blinking. Always its
    /// own eyes. Nothing moves under Reduce Motion.
    private func syncFace(still: Bool) {
        let side = bounds.width
        guard let mood = shownMood, !still, window != nil, side > 0, !showsPhoto, !drawnKey.isEmpty else {
            if !actKey.isEmpty { clearAct() }
            return
        }
        let key = "\(mood.rawValue)|\(drawnKey)"
        guard key != actKey else { return }
        let shown = stage.presentation()?.transform, looking = gazeLayer.presentation()?.transform
        if !actKey.isEmpty { clearAct(settle: false) }
        actKey = key
        let (begin, seed) = actClock()
        let loop = FaceLoop(mood, facing: head.themed?.facing ?? MatrixHead.facing(seed: head.seed), seed: seed)
        playFace(loop, begin: begin, once: mood.once, from: shown, looking: looking)
    }

    private func playFace(_ loop: FaceLoop, begin: CFTimeInterval, once: Bool, from shown: CATransform3D?, looking: CATransform3D?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // A Dots face's lamps step; a Shapes head is soft, so it moves on springs (FaceLoop.softSamples).
        let lamps = head.themed != nil
        let samples = lamps ? loop.samples() : loop.softSamples(once: once), side = bounds.width, period = loop.period
        let jelly = playJelly(loop, samples: samples, begin: begin, once: once)
        moveBody(loop, samples: samples, begin: begin, once: once, from: shown, solid: jelly != nil)
        guard !eyesLayer.isHidden else { return }
        for layer in [gazeLayer, eyesLayer] { layer.removeAnimation(forKey: "act.end") }
        gazeLayer.transform = CATransform3DIdentity
        func moments(_ times: [Double]) -> [NSNumber] { times.map { NSNumber(value: $0 / period) } }
        // Where the eyes look (a Dots face's also sliding toward where the body turns and tips, as on something round).
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
            // Only where they look: a Shapes head is flat, so as it turns its edge comes in toward the eyes already. They
            // look well across a soft head, as far as its edge allows, and ride its wobble (moved, never squashed: always
            // its own normal eyes).
            let reach = (HeadGeometry.layout(head, compact: side < 64, darkPage: nil).placement?.k ?? 1) * moves.glance * side
            let eyes = CGPoint(x: eyeCentre.x * bounds.width, y: eyeCentre.y * bounds.height)
            var far = (left: 0.065 * reach, right: 0.065 * reach, up: 0.055 * reach, down: 0.055 * reach)
            if let jelly {
                let box = CGRect(x: eyeBox.minX * bounds.width, y: eyeBox.minY * bounds.height,
                                 width: eyeBox.width * bounds.width, height: eyeBox.height * bounds.height)
                let room = FaceJelly.room(for: box, in: jelly.outline, margin: 0.055 * side)
                far = (min(0.13 * reach, room.left), min(0.13 * reach, room.right), min(0.11 * reach, room.up), min(0.11 * reach, room.down))
            }
            // How far a look goes changes smoothly through the middle, so the eyes keep their speed as they cross it even
            // where one side has less room.
            func travel(_ v: Double, _ back: Double, _ ahead: Double) -> Double {
                let k = (v + 0.3) / 0.6, past = k >= 1 ? v : k <= 0 ? 0 : 0.6 * (k * k * k - k * k * k * k / 2)
                return back * v + (ahead - back) * past
            }
            // On a solid body they ride round its front as it turns and tips: across, narrower toward its edge, and
            // gone round its back. A look turns them a little further round the same front, so they never leave it.
            // Leading the head round, a look may go a little past all the way (eased to a limit, never cut off at it).
            func beyond(_ v: Double) -> Double { abs(v) <= 1 ? v : (v < 0 ? -1 : 1) * (1 + 0.35 * tanh((abs(v) - 1) / 0.35)) }
            let seats = samples.map { sample in
                jelly.map { jelly in
                    jelly.solid.seat(eyes, turn: sample.body.turn + beyond(sample.eyes.x) * FaceEyes.across * moves.glance,
                                     tip: sample.body.tip + beyond(sample.eyes.y) * FaceEyes.down * moves.glance)
                }
            }
            let around = CGPoint(x: eyes.x - bounds.midX, y: eyes.y - bounds.midY)
            look.values = samples.enumerated().map { i, sample in
                let ex = min(max(sample.eyes.x, -1), 1), ey = min(max(sample.eyes.y, -1), 1)
                var x = jelly == nil ? travel(ex, far.left, far.right) : 0, y = jelly == nil ? travel(ey, far.up, far.down) : 0
                if let jelly, i < jelly.wobble.count {
                    let wobble = jelly.wobble[i], dx = eyes.x - jelly.foot.x, dy = eyes.y - jelly.foot.y
                    x += wobble.squash * dx - wobble.lean * dy
                    y -= wobble.squash * dy
                }
                guard let seat = seats[i] else { return NSValue(caTransform3D: CATransform3DMakeTranslation(x, y, 0)) }
                let shape = CATransform3DMakeScale(min(max(seat.wide, 0.05), 1.2), min(max(seat.high, 0.05), 1.2), 1)
                let placed = CATransform3DConcat(CATransform3DMakeTranslation(-around.x, -around.y, 0), shape)
                return NSValue(caTransform3D: CATransform3DConcat(placed, CATransform3DMakeTranslation(around.x + x + seat.dx, around.y + y + seat.dy, 0)))
            }
            look.keyTimes = moments(samples.map(\.at))
            if seats.contains(where: { ($0?.facing ?? 1) < 0.3 }) {
                let seen = CAKeyframeAnimation(keyPath: "opacity")   // motion-ok: still under Reduce Motion (syncFace)
                seen.values = seats.map { seat in
                    let k = min(max(((seat?.facing ?? 1) - 0.05) / 0.25, 0), 1)
                    return k * k * (3 - 2 * k)
                }
                seen.keyTimes = look.keyTimes
                settle(seen, period: period, begin: begin, once: once)
                gazeLayer.add(seen, forKey: "act.seen")
            }
        }
        settle(look, period: period, begin: begin, once: once)
        gazeLayer.add(look, forKey: "act")
        if let looking, let values = look.values, !values.isEmpty, !lamps {
            // Into where the eyes will be once the bridge is over.
            let then = Self.sample(in: samples, at: CACurrentMediaTime() + Self.bridgeLength - begin, period: period, once: once)
            bridge(gazeLayer, "transform", from: NSValue(caTransform3D: looking), to: values[min(then, values.count - 1)])
        }
        // Narrowing and blinking, about the eyes' own middle. A Dots face's lamps only shut (squashed for a moment, as
        // its idle blink): lamps held half squashed read as a fault, not a look.
        let stepped = lamps && head.themed?.pattern == "face"
        let dx = (eyeCentre.x - 0.5) * bounds.width, dy = (eyeCentre.y - 0.5) * bounds.height
        let lids = CAKeyframeAnimation(keyPath: "transform")   // motion-ok: still under Reduce Motion (syncFace)
        lids.values = samples.map { sample in
            let shut = min(max(sample.eyes.lids, 0), 1)
            let open = stepped ? (shut >= 0.75 ? 0.08 : 1) : 1 - 0.9 * shut
            var t = CATransform3DMakeTranslation(dx, dy, 0)
            t = CATransform3DScale(t, 1, open, 1)
            return NSValue(caTransform3D: CATransform3DTranslate(t, -dx, -dy, 0))
        }
        lids.keyTimes = moments(samples.map(\.at))
        settle(lids, period: period, begin: begin, once: once)
        eyesLayer.add(lids, forKey: "act.lids")
    }

    // MARK: [moods] A soft body (a Shapes head's, while it acts)

    /// Whether this head's body is soft: a Shapes head out of a board.
    private var isSoft: Bool { !isMatrix && head.themed == nil && head.tile == .none }

    /// Shows the body as its outline and starts its jelly: a solid body turning and tipping (FaceSolid), squashing and
    /// leaning on after each move (FaceJelly). Easing in from where a jelly playing before
    /// shows, or from the body's picture. The wobble at each of the loop's samples, where it bends from (its foot), its
    /// outline at rest (this view's points) and the solid, for the eyes to ride and keep inside; nil on a hard head.
    private func playJelly(_ loop: FaceLoop, samples: [(at: Double, body: FaceBody, eyes: FaceEyes)], begin: CFTimeInterval,
                           once: Bool) -> (wobble: [FaceJelly], foot: CGPoint, outline: [CGPoint], solid: FaceSolid)? {
        let side = bounds.width
        let layout = HeadGeometry.layout(head, compact: side < 64, darkPage: traitCollection.userInterfaceStyle == .dark)
        guard isSoft, layout.board == nil, layout.outline.count > 2 else {
            dropJelly()
            return nil
        }
        let place = layout.placement ?? HeadPlacement(k: 1, tx: 0, ty: 0), unit = side / 1024
        let points = layout.outline.map { CGPoint(x: (place.k * $0.x + place.tx) * unit, y: (place.k * $0.y + place.ty) * unit) }
        let foot = CGPoint(x: points.map(\.x).reduce(0, +) / Double(points.count), y: points.map(\.y).max() ?? side)
        let solid = FaceSolid(outline: points, side: side), still = HeadRenderer.outlinePath(solid.edge(solid.rest))
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
        // The edge: the solid seen turned and tipped at every sample, smoothed so it never flickers, worked out off the
        // main thread; till then it shows as it stands.
        let poses = samples.map { (at: $0.at, turn: $0.body.turn, tip: $0.body.tip) }
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
                // Into where the act will be once the bridge is over.
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
            // Into where the new act will be once the bridge is over.
            let then = Self.sample(in: samples, at: CACurrentMediaTime() + Self.bridgeLength - begin, period: loop.period, once: once)
            bridge(jellyLayer, "path", from: shownPath, to: still, key: "act.bridge.path")
            bridge(jellyLayer, "transform", from: NSValue(caTransform3D: shownBend), to: NSValue(caTransform3D: bend(wobble[then])))
        }
        return (wobble, foot, points, solid)
    }

    /// The act is over: the jelly eases back to the body's own outline, then the body's picture shows again.
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bridgeLength) { [weak self] in
            guard let self, self.actKey.isEmpty else { return }
            self.dropJelly()
        }
    }

    /// No jelly: the body's picture shows.
    private func dropJelly() {
        jellyLayer.removeAllAnimations()
        jellyLayer.isHidden = true
        bodyLayer.isHidden = false
    }

    // MARK: Idle life (blinks and glances, from HeadIdleMotion's one timer)

    /// Whether the idle timer should visit this head now.
    var idleEligible: Bool {
        !acting && window != nil && !isHidden && alpha > 0.01 && hasIdleFace && !HeadMotionSettings.shared.isStill && !showsPhoto
    }
    var glances: Bool { moves.glance > 0 }
    /// Whether a light runs over this head now and then (a dot-matrix head).
    var shimmers: Bool { isMatrix }

    /// A blink: the eyes squash to a line and open again in 0.19 s, about their own centre.
    func blink() {
        guard idleEligible, moves.blinks else { return }
        if isMatrix { blinkMatrix(); return }
        let dy = (eyeCentre.y - 0.5) * bounds.height
        func squash(_ k: CGFloat) -> NSValue {
            var t = CATransform3DMakeTranslation(0, dy, 0)
            t = CATransform3DScale(t, 1, k, 1)
            t = CATransform3DTranslate(t, 0, -dy, 0)
            return NSValue(caTransform3D: t)
        }
        let blink = CAKeyframeAnimation(keyPath: "transform")   // motion-ok: heads are still under Reduce Motion (isStill)
        blink.values = [squash(1), squash(0.08), squash(1)]
        blink.keyTimes = [0, 0.42, 1]
        blink.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        blink.duration = 0.19
        eyesLayer.add(blink, forKey: "blink")
    }

    /// A glance: the eyes move to one of the rest spots (fractions of the head) in 0.42 s and stay there.
    func glance(to spot: CGPoint) {
        guard idleEligible, glances else { return }
        if isMatrix { glanceMatrix(to: spot); return }
        let reach = moves.glance * (HeadGeometry.layout(head, compact: bounds.width < 64, darkPage: nil).placement?.k ?? 1) * bounds.width
        let target = CATransform3DMakeTranslation(spot.x * reach, spot.y * reach, 0)
        let move = CABasicAnimation(keyPath: "transform")   // motion-ok: heads are still under Reduce Motion (isStill)
        move.fromValue = NSValue(caTransform3D: gazeLayer.presentation()?.transform ?? gazeLayer.transform)
        move.toValue = NSValue(caTransform3D: target)
        move.duration = 0.42
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.35, 0, 0.25, 1)
        gazeLayer.transform = target
        gazeLayer.add(move, forKey: "glance")
    }

    private var moving = false
    private func updateMotion() {
        let still = HeadMotionSettings.shared.isStill
        // [photoheads] a photo keeps still: off the idle clock, no working motion. [moods] A face taken up with its bot
        // is off it too: a dot-matrix face plays its act instead.
        if !acting, !still, window != nil, hasIdleFace, !showsPhoto { HeadIdleMotion.shared.add(self) } else { HeadIdleMotion.shared.remove(self) }
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

/// A head's idle life (`motion.ts`): smooth blinks and glances at each head's own random moments, from one timer that
/// sleeps until the next head on screen is due, with nothing running in between.
final class HeadIdleMotion {
    static let shared = HeadIdleMotion()
    /// Where a Shapes head's eyes rest, as fractions of the head's width (`GLANCES`).
    static let glances: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: -0.146, y: 0.025), CGPoint(x: -0.078, y: 0.078),
                                     CGPoint(x: -0.02, y: -0.012), CGPoint(x: -0.11, y: -0.02)]
    private struct Entry {
        weak var view: HeadView?
        var blinkAt: CFTimeInterval
        var glanceAt: CFTimeInterval
        var glance = 0
        /// When a light next runs over a dot-matrix head.
        var shimmerAt: CFTimeInterval
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var timer: Timer?

    private static func between(_ low: Double, _ high: Double) -> Double { Double.random(in: low..<high) }

    func add(_ view: HeadView) {
        let id = ObjectIdentifier(view)
        guard entries[id] == nil else { return }
        let now = CACurrentMediaTime()
        let entry = Entry(view: view, blinkAt: now + Self.between(1.2, 6), glanceAt: now + Self.between(1.8, 5),
                          shimmerAt: now + Self.between(2.5, 14))
        entries[id] = entry
        // [perf] Build 297: the clock already wakes before this head's first blink or glance: nothing to re-plan (every
        // face on the Bots list joins at once as the list comes back, each re-planning took the pop's first frame).
        if let timer, timer.isValid, timer.fireDate.timeIntervalSinceNow + now <= Self.due(entry, view) { return }
        schedule()
    }

    func remove(_ view: HeadView) {
        guard entries.removeValue(forKey: ObjectIdentifier(view)) != nil else { return }
        schedule()
    }

    /// Re-plans after Reduce Motion or Low Power Mode changes.
    func reschedule() { schedule() }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard !HeadMotionSettings.shared.isStill else { return }
        entries = entries.filter { $0.value.view != nil }
        var soonest = Double.infinity
        for entry in entries.values {
            guard let view = entry.view else { continue }
            soonest = min(soonest, Self.due(entry, view))
        }
        guard soonest.isFinite else { return }
        let timer = Timer(timeInterval: max(0.04, soonest - CACurrentMediaTime()), repeats: false) { _ in
            MainActor.assumeIsolated { HeadIdleMotion.shared.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// When this head next has something to do.
    private static func due(_ entry: Entry, _ view: HeadView) -> CFTimeInterval {
        min(entry.blinkAt, view.glances ? entry.glanceAt : .infinity, view.shimmers ? entry.shimmerAt : .infinity)
    }

    private func tick() {
        timer = nil
        let now = CACurrentMediaTime()
        for (id, var entry) in entries {
            guard let view = entry.view else { entries[id] = nil; continue }
            if now >= entry.blinkAt {
                view.blink()
                // Now and then a double blink.
                if Double.random(in: 0..<1) < 0.15 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak view] in view?.blink() }
                }
                entry.blinkAt = now + Self.between(4.2, 9.4)
            }
            if view.glances, now >= entry.glanceAt {
                // Somewhere new, and now and then back to rest.
                let others = Self.glances.count - 1
                var next = Double.random(in: 0..<1) < 0.25 ? 0 : 1 + Int.random(in: 0..<others)
                if next == entry.glance { next = next != 0 ? 0 : 1 + Int.random(in: 0..<others) }
                entry.glance = next
                view.glance(to: Self.glances[next])
                entry.glanceAt = now + Self.between(3.4, 8)
            }
            if view.shimmers, now >= entry.shimmerAt {
                view.shimmer()
                entry.shimmerAt = now + Self.between(9, 22)
            }
            entries[id] = entry
        }
        schedule()
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
        HeadIdleMotion.shared.reschedule()
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
