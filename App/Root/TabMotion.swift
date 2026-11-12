// [tabmotion] A tab icon's motion when it is tapped (owner 2026-10-30: "a very subtle animation that is congruent
// to the type of image used in the icon … it can't just be like a bounce … that icon is animating in a way that it
// should animate"). Each icon moves the part of its picture that would move:
//   Bots            the robot's antenna springs, it blinks and glances aside
//   Sessions        a typing indicator runs twice through the front bubble
//   Jobs            the clock swells over the calendar while its minute hand spins round once
//   Kanban          the columns pull up and drop their cards again, left to right
//   Artifacts       the photo's sun sets behind the hills and rises again, glowing
//   More            the outer dots swing a full turn round the middle one, reaching out, and settle back in a row
//   Settings        the gear winds back and spins three quarters of a turn
//   Capabilities    the four squares trade places round the grid, twice
//   Connectors      the plug pulls back, pushes its prongs into the socket, buzzes with sparks and comes out
//   Bot Profiles    the person ducks into the circle, pops back up and nods
//   Messaging       the bubble pulls into its tail and pops back out, wobbling
//   Files           a page rises out of the folder and drops back in
//   Changes         the plus turns over, swelling, and the minus stretches out after it (Mac polish #65: the +/−)
//   Status & Maint. the needle revs into the red and drops back
//   Spawn Tree      a signal runs round the tree, each node swelling as it arrives
//   Star Map        the stars twinkle in turn, shrinking, turning and flaring (the Mac's one star the same: #64)
//   Webhooks        the arrow drives off the sign and the next one comes in behind it
//   Import Sessions the front square drops onto the one behind and springs back
//   Pinned          the pin pulls out, leaning back, jabs into the board with a tap and wobbles still
//   Tiles           the tiles jiggle in turn, as in Edit Tiles, the tall one swelling last, and settle
// Owner on the first cut: "Yours are definitely subtle lol"; on the second: "Jobs isn't enough. I can't even tell that
// the more icon [does] anything at all … They can animate more". On a real tap the system bar's glass lens swells over
// the icon for about 0.4 s, so each motion does its most after that.
// The motion is drawn as frames from the icon's own picture (the drawn glyphs in another pose, or the symbol as its bar
// draws it with the moving part redrawn), with room round it for a part moving past its edge, and played once over the
// icon, which then shows its still image again. The first and last frames are that still image, so nothing jumps.
// Under Reduce Motion nothing plays.

import UIKit

@MainActor
enum TabMotion {
    enum Kind {
        case bot, kanban, typing, clock, sunrise, spread
        case gear, grid, plug, person, message, folder, branch, gauge, tree, sparkles, sign, stack, pin, tiles, terminal, checklist, bag
        case changes, star, bars
    }

    /// Plays the tap motion of the icon `view` shows, drawn from `source` (the tab's own image: the bar item's, or the
    /// app's bars' redrawn outline). Nothing for an icon with no motion, such as the turning Jobs ring.
    static func play(in view: UIImageView, source: UIImage?) {
        guard !HQMotion.reduced, view.window != nil, let source, let kind = kind(of: source),
              let motion = motion(kind, source: source, in: view) else {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "HQDebugTabMotionDump") {
                let name = source.map { TabIcons.symbolName(of: $0) ?? "\($0.size)" } ?? "nil"
                NSLog("[tabmotion] none for %@ (%@)", name, source.flatMap { kind(of: $0) }.map { "\($0)" } ?? "no kind")
                if let contents = view.layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-motion")
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? UIImage(cgImage: contents as! CGImage).pngData()?.write(to: folder.appendingPathComponent("failed-\(name).png"))
                }
            }
            #endif
            return
        }
        // The frames play in a view of their own over the icon, which shows nothing meanwhile: the system bar sizes an
        // icon's view to the images it plays, so frames with room round them would leave it that much bigger (and
        // frames the size of the bar's raster left it an eighth smaller after every tap; owner 2026-10-31: "why did
        // the icon look so much smaller than all the rest?"). A subview, it moves, scales and fades with the icon (the
        // bar's selection lens). The frames come in the icon's colour: the system bar drew a view cut to them by a
        // mask layer as a solid square once its lens let go, and image views don't tint the images they play.
        view.stopAnimating()
        view.subviews.filter { $0 is Overlay }.forEach { $0.removeFromSuperview() }
        let frames = tinted(motion, view.tintColor.resolvedColor(with: view.traitCollection))
        // On whole pixels, so the frames are as sharp as the icon.
        let pixel = { (value: CGFloat) in (value * motion.scale).rounded() / motion.scale }
        let overlay = Overlay(frame: CGRect(x: pixel(view.bounds.midX + motion.shift - motion.size.width / 2),
                                            y: pixel(view.bounds.midY - motion.size.height / 2),
                                            width: motion.size.width, height: motion.size.height))
        overlay.isUserInteractionEnabled = false
        overlay.contentMode = .center
        overlay.image = frames.last
        overlay.animationImages = frames
        overlay.animationDuration = motion.duration
        overlay.animationRepeatCount = 1
        view.addSubview(overlay)
        view.animationImages = [motion.blank]
        view.animationDuration = motion.duration
        view.animationRepeatCount = 1
        view.startAnimating()
        overlay.startAnimating()
        finish(overlay, over: view, blank: motion.blank, after: motion.duration + 0.05)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugTabMotionDump") { dump(motion, kind: kind, view: view) }
        #endif
    }

    /// Takes the overlay away once the icon has finished playing its blank, so the icon shows its own image again with
    /// nothing missing in between. Both start together, but their clocks start when the screen next draws, which can
    /// come late under load while the new tab's page is set up; the overlay holds the still image meanwhile.
    private static func finish(_ overlay: Overlay, over view: UIImageView, blank: UIImage, after delay: TimeInterval, tries: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view, weak overlay] in
            guard let overlay else { return }
            guard let view, overlay.superview === view else { return overlay.removeFromSuperview() }
            let playing = view.isAnimating && view.animationImages?.first === blank
            if playing, tries < 30 { return finish(overlay, over: view, blank: blank, after: 1 / fps, tries: tries + 1) }
            overlay.removeFromSuperview()
            // Let go of the blank too, so nothing of the motion stays with the view.
            guard view.animationImages?.first === blank else { return }
            view.stopAnimating()
            view.animationImages = nil
        }
    }

    /// The view the frames play in, over the icon.
    private final class Overlay: UIImageView {}

    /// A motion's frames in a colour, kept for the few colours its tab shows in (the system bar plays a tap in both
    /// its tinted and its plain copy of the icon). About 5 MB each, so a few at most.
    private static var tints: [(frame: CGImage, colour: UIColor, frames: [UIImage])] = []

    private static func tinted(_ motion: Motion, _ colour: UIColor) -> [UIImage] {
        guard let key = motion.frames.first else { return [] }
        if let kept = tints.first(where: { $0.frame === key && $0.colour == colour }) { return kept.frames }
        let frames = motion.frames.map { frame -> UIImage in
            let rect = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            guard let ctx = CGContext(data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return UIImage() }
            ctx.draw(frame, in: rect)
            ctx.setBlendMode(.sourceIn)
            ctx.setFillColor(colour.cgColor)
            ctx.fill(rect)
            return ctx.makeImage().map { UIImage(cgImage: $0, scale: motion.scale, orientation: .up) } ?? UIImage()
        }
        if tints.count >= 4 { tints.removeFirst() }
        tints.append((key, colour, frames))
        return frames
    }

    #if DEBUG
    /// `-HQDebugTabMotionDump YES`: each motion played, as a strip of its frames in black on white, and beside it the
    /// view's still image as the view draws it, in tmp/tab-motion/ (frames checked against the icon at rest).
    private static func dump(_ motion: Motion, kind: Kind, view: UIImageView) {
        let size = motion.size, gap: CGFloat = 4
        let format = UIGraphicsImageRendererFormat()
        format.scale = motion.scale
        let strip = UIGraphicsImageRenderer(size: CGSize(width: (size.width + gap) * CGFloat(motion.frames.count + 1), height: size.height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: context.format.bounds.size))
            for (index, frame) in motion.frames.enumerated() {
                UIImage(cgImage: frame, scale: motion.scale, orientation: .up).withTintColor(.black)
                    .draw(at: CGPoint(x: (size.width + gap) * CGFloat(index + 1), y: 0))
            }
            context.cgContext.translateBy(x: (size.width - view.bounds.width) / 2, y: (size.height - view.bounds.height) / 2)
            view.layer.render(in: context.cgContext)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-motion")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(kind)-\(Int(size.width))x\(Int(size.height))-\(view.bounds.width)x\(view.bounds.height).png"
        try? strip.pngData()?.write(to: folder.appendingPathComponent(name))
        NSLog("[tabmotion] %@ frames %d size %@ view %@ shift %@", name, motion.frames.count, NSCoder.string(for: size), NSCoder.string(for: view.bounds), "\(motion.shift)")
    }
    #endif

    /// The system tab bar's icon views for the tab at `index`. The bar keeps a second copy of each tab for the look
    /// under its glass selection; both play. Found by public types as `TabBadgeOverlay` finds them, and none when the
    /// bar's buttons don't match its items (another iOS).
    static func barIcons(in bar: UITabBar, at index: Int) -> [UIImageView] {
        var places: [(x: CGFloat, icons: [UIImageView])] = []
        func walk(_ view: UIView) {
            if view is UIControl {
                let images = view.subviews.compactMap { $0 as? UIImageView }
                if let icon = images.first(where: { !$0.isHidden }) ?? images.first {
                    let x = view.convert(view.bounds, to: bar).midX
                    if let place = places.firstIndex(where: { abs($0.x - x) < 1 }) { places[place].icons.append(icon) } else { places.append((x, [icon])) }
                    return
                }
            }
            view.subviews.forEach(walk)
        }
        walk(bar)
        guard places.count == bar.items?.count, places.indices.contains(index) else { return [] }
        places.sort { $0.x < $1.x }
        if bar.effectiveUserInterfaceLayoutDirection == .rightToLeft { places.reverse() }
        return places[index].icons
    }

    static func kind(of source: UIImage) -> Kind? {
        if TabIcons.spinner(of: source) != nil { return nil }       // the running Jobs ring turns already
        if source === TabIcons.jobs { return .clock }
        if let glyph = TabIcons.glyph(of: source) { return glyph.shape == .bot ? .bot : .kanban }
        // The system bar's symbol (filled, or bold) and the app's bars' outline (`TabIcons.barSymbol`).
        switch TabIcons.symbolName(of: source) {
        case "bubble.left.and.bubble.right", "bubble.left.and.bubble.right.fill": return .typing
        case "calendar.badge.clock": return .clock
        case "photo.on.rectangle", "photo.on.rectangle.fill": return .sunrise
        case "ellipsis", "ellipsis.circle", "ellipsis.circle.fill": return .spread
        case "gearshape", "gearshape.fill": return .gear
        case "square.grid.2x2", "square.grid.2x2.fill": return .grid
        case "powerplug", "powerplug.fill": return .plug
        case "person.crop.circle", "person.crop.circle.fill": return .person
        case "message", "message.fill": return .message
        case "folder", "folder.fill": return .folder
        case "arrow.triangle.branch": return .branch
        case "plus.forwardslash.minus": return .changes   // Mac polish #65: Changes' +/−
        case "gauge.with.needle.fill", "gauge.with.dots.needle.67percent": return .gauge
        case "point.3.connected.trianglepath.dotted", "point.3.filled.connected.trianglepath.dotted": return .tree
        case "sparkles": return .sparkles
        case "star", "star.fill": return .star   // [mac] Mac polish #64: Star Map's star
        case "arrow.triangle.turn.up.right.diamond", "arrow.triangle.turn.up.right.diamond.fill": return .sign
        case "square.and.arrow.down.on.square", "square.and.arrow.down.on.square.fill": return .stack
        case "pin", "pin.fill": return .pin
        case "rectangle.3.group", "rectangle.3.group.fill": return .tiles
        case "apple.terminal", "apple.terminal.fill", "terminal", "terminal.fill": return .terminal
        case "checklist", "checklist.checked": return .checklist   // [tasks]
        case "bag", "bag.fill": return .bag   // [marketplace-row]
        case "app.connected.to.app.below.fill": return .bag   // [composio-row] Composio: lifts and swings as the bag does
        case "key", "key.fill": return .bag   // [passwords-page] Passwords had no motion as a tab (TabMotionTests failed on main)
        case "chart.bar", "chart.bar.fill": return .bars   // Usage, a Tool on the Mac (owner 2026-11-07)
        default: return nil
        }
    }

    // MARK: Frames

    struct Motion {
        /// Coverage only, `size` at `scale`.
        let frames: [CGImage]
        /// The frames' size in points: the icon's image with room round it.
        let size: CGSize
        let scale: CGFloat
        let duration: TimeInterval
        /// Nothing, the size of the icon's view: what the icon shows meanwhile.
        var blank: UIImage
        /// How far right of the view's middle the frames' middle goes, in points (`inkShift`).
        var shift: CGFloat = 0
    }

    private static let fps: Double = 60

    /// Made once per icon and size: the bar's tabs (a few looks, two sizes at most) keep theirs. One serves every
    /// colour (`tinted`). About 5 MB each, so a few at most, and none kept through a memory warning.
    private static var made: [(source: UIImage, size: CGSize, scale: CGFloat, bold: Bool, motion: Motion)] = [] {
        didSet { if oldValue.isEmpty, !made.isEmpty { forgetOnMemoryWarning() } }
    }

    private static var memoryWatch: NSObjectProtocol?

    private static func forgetOnMemoryWarning() {
        guard memoryWatch == nil else { return }
        memoryWatch = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { made.removeAll(); tints.removeAll() }
        }
    }

    static func motion(_ kind: Kind, source: UIImage, in view: UIImageView) -> Motion? {
        let scale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 3
        let bold = view.traitCollection.legibilityWeight == .bold
        let art: SymbolArt
        var raster: UIImage?
        switch kind {
        case .bot, .kanban:
            guard let rest = TabIcons.glyph(of: source)?.image(.rest) else { return nil }
            art = SymbolArt(symbol: rest, origin: .zero, size: rest.size, scale: scale, room: 0)
        case .clock where source === TabIcons.jobs:
            let jobs = TabIcons.jobsArt
            art = SymbolArt(symbol: jobs.symbol, origin: jobs.origin, size: jobs.size, scale: scale)
        default:
            raster = barRaster(in: view)
            guard let shown = raster ?? shownSymbol(in: view) else { return nil }
            // The More dots swing round past the plain ellipsis's top and bottom, the Messaging bubble pops back
            // about 30% bigger from its tail, and the pin lifts a quarter of its height, leaning.
            let room: CGFloat = switch kind { case .spread: 0.6; case .message, .pin, .terminal, .stack, .checklist, .bag: 0.4; default: 0.25 }
            art = SymbolArt(symbol: shown, origin: .zero, size: shown.size, scale: scale, room: room)
        }
        if let kept = made.first(where: { $0.source === source && $0.size == art.size && $0.scale == scale && $0.bold == bold }) {
            return kept.motion
        }
        let motion: Motion?
        switch kind {
        case .bot, .kanban: motion = TabIcons.glyph(of: source).flatMap { glyphMotion($0, kind: kind, art: art) }
        case .typing: motion = typing(art)
        case .clock: motion = clock(art)
        case .sunrise: motion = sunrise(art)
        case .spread: motion = spread(art)
        case .gear: motion = gear(art)
        case .grid: motion = grid(art)
        case .plug: motion = plug(art)
        case .person: motion = person(art)
        case .message: motion = message(art)
        case .folder: motion = folder(art)
        case .branch: motion = branch(art)
        case .gauge: motion = gauge(art)
        case .tree: motion = tree(art)
        case .sparkles: motion = sparkles(art)
        case .changes: motion = changes(art)
        case .star: motion = star(art)
        case .sign: motion = sign(art)
        case .stack: motion = stack(art)
        case .pin: motion = pin(art)
        case .terminal: motion = terminal(art)
        case .checklist: motion = checklist(art)
        case .bag: motion = bag(art)
        case .bars: motion = bars(art)
        case .tiles: motion = tiles(art)
        }
        guard var motion else { return nil }
        // The icon's blank keeps the view's own size, as the bar sizes the view to the images it plays (the raster is
        // smaller).
        if let raster {
            motion.blank = SymbolArt.blank(view.bounds.size, scale: scale)
            motion.shift = inkShift(raster)
        }
        if made.count >= 6 { made.removeFirst() }
        made.append((source, art.size, scale, bold, motion))
        return motion
    }

    /// The symbol as the system bar draws it. The bar shrinks a symbol's icon view (to about 0.87) and holds the symbol
    /// as a raster of the size it shows at, which it draws at that size in the middle of the view; so this is that
    /// raster, and the frames, played over the view in a view of their own, are its size (stretched over the view's
    /// bounds they came out about 15% bigger than the icon). Nil where the view's layer holds the whole image at its
    /// own size (the app's own bars), which draw `shownSymbol`.
    private static func barRaster(in view: UIImageView) -> UIImage? {
        guard view.image?.isSymbolImage == true, let contents = view.layer.contents,
              CFGetTypeID(contents as CFTypeRef) == CGImage.typeID, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let raster = contents as! CGImage
        let scale = view.layer.contentsScale
        let size = CGSize(width: CGFloat(raster.width) / scale, height: CGFloat(raster.height) / scale)
        guard abs(size.width - view.bounds.width) > 0.5 || abs(size.height - view.bounds.height) > 0.5 else { return nil }
        return UIImage(cgImage: raster, scale: scale, orientation: .up)
    }

    /// How far right the frames go so that their drawing sits where the bar shows it, in points. Some rasters carry
    /// clear columns at a side (on the right of Sessions' bubbles and Artifacts' photo, on the left of Import Sessions'
    /// squares), and the bar puts the drawing itself in the middle of the view across, though not down (Sessions' clear
    /// rows at the bottom count). Measured on screen: unshifted, those frames ended 1 to 3 pixels off the icon.
    private static func inkShift(_ raster: UIImage) -> CGFloat {
        guard let image = raster.cgImage, image.width > 0, image.height > 0,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        let inked = (0..<image.width).filter { x in (0..<image.height).contains { y in bytes[(y * image.width + x) * 4 + 3] > 0 } }
        guard let left = inked.first, let right = inked.last else { return 0 }
        return CGFloat((image.width - 1 - right) - left) / 2 / raster.scale
    }

    /// The symbol the view draws: its image with the view's preferred configuration and traits (Bold Text).
    private static func shownSymbol(in view: UIImageView) -> UIImage? {
        guard var image = view.image, image.isSymbolImage else { return nil }
        if let preferred = view.preferredSymbolConfiguration { image = image.applyingSymbolConfiguration(preferred) ?? image }
        if let config = image.symbolConfiguration { image = image.withConfiguration(config.withTraitCollection(view.traitCollection)) }
        return image
    }

    /// Frames for `duration` seconds at 60 a second, each the art (or with `base` false, nothing) with `change` drawn
    /// over it at that time; the first and last the art at rest.
    private static func frames(_ art: SymbolArt, duration: TimeInterval, base: Bool = true, _ change: (CGFloat, CGContext) -> Void) -> Motion? {
        guard let still = art.frame({ _ in }) else { return nil }
        let count = Int((duration * fps).rounded()) + 1
        var frames: [CGImage] = [still]
        frames.reserveCapacity(count)
        for index in 1..<(count - 1) {
            let t = CGFloat(Double(index) / fps)
            guard let frame = art.frame(base: base, { change(t, $0) }) else { return nil }
            frames.append(frame)
        }
        frames.append(still)
        return Motion(frames: frames, size: art.canvas, scale: art.scale, duration: Double(count) / fps, blank: art.blank())
    }

    // MARK: Bots and Kanban (drawn glyphs in another pose)

    private static func glyphMotion(_ glyph: TabIcons.Glyph, kind: Kind, art: SymbolArt) -> Motion? {
        if kind == .bot {
            // The antenna springs as if pinged, swinging each way and settling; the eyes blink as it does, then glance
            // aside and back, as a robot looking round at the tap would.
            return frames(art, duration: 1.05, base: false) { t, _ in
                var pose = TabIcons.Pose.rest
                pose.antenna = 0.5 * exp(-t / 0.3) * sin(2 * .pi * t / 0.32)
                pose.eyes = 1 - 0.96 * Ease.bump(t, from: 0.08, length: 0.2)
                pose.look = 1.5 * Ease.smooth((t - 0.36) / 0.1) * (1 - Ease.smooth((t - 0.76) / 0.12))
                glyph.image(pose).draw(at: .zero)
            }
        }
        // Each column pulls up to a stub and drops back to its length with a little give, left to right: cards being
        // dealt into the columns again.
        return frames(art, duration: 1, base: false) { t, _ in
            var pose = TabIcons.Pose.rest
            pose.columns = (0..<3).map { column in
                let u = t - 0.09 * CGFloat(column)
                if u <= 0 { return 1 }
                if u < 0.14 { return 1 - 0.85 * Ease.smooth(u / 0.14) }
                return 0.15 + 0.85 * Ease.spring(u - 0.14, damping: 0.45, frequency: 20)
            }
            glyph.image(pose).draw(at: .zero)
        }
    }

    // MARK: Symbols (parts redrawn over the symbol's own drawing)
    //
    // The moving part is found in the symbol as drawn, by shape: the system bar's symbols ignore palette colours, so
    // their layers can't be drawn apart. SF Symbols leaves a gap round a part in front, so most parts are pieces of
    // their own; a filled symbol's details are holes cut through it, an outline's are ink.

    /// The part in front that holds the symbol's rightmost ink: the filled bubble or photo, a piece of its own; or for
    /// an outline, whose line runs into the one behind at tab sizes, the room inside its line (past its right edge,
    /// inward). `solid` tells which.
    private static func frontPart(of whole: InkMap) -> (map: InkMap, solid: Bool)? {
        guard let seed = whole.rightmost(), let all = whole.bounds() else { return nil }
        var inside = seed
        while inside.x > all.minX, whole.ink(at: inside) { inside.x -= 1 / whole.scale }
        let solid = seed.x - inside.x > all.width * 0.2
        guard let map = solid ? whole.piece(from: seed, ink: true) : whole.piece(from: inside, ink: false, maxArea: all.width * all.height * 0.6) else { return nil }
        return (map, solid)
    }

    /// Sessions: three typing dots come up in the front bubble, a wave runs through them twice, and they go.
    private static func typing(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let part = frontPart(of: whole), let box = part.map.bounds() else { return nil }
        let front = part.map, solid = part.solid, pixel = 1 / whole.scale
        // The body is the rows at least 60 % as wide as the bubble; the tail below it is narrower.
        var bottom = box.maxY
        while bottom > box.midY, front.width(atY: bottom - pixel / 2) < box.width * 0.6 { bottom -= pixel }
        let body = CGRect(x: box.minX, y: box.minY, width: box.width, height: bottom - box.minY)
        let dot = min(body.height * (solid ? 0.2 : 0.28), body.width / 5.4)
        let step = dot * 1.6, lift = dot * (solid ? 0.8 : 0.65)
        return frames(art, duration: 1.3) { t, ctx in
            ctx.setBlendMode(solid ? .clear : .normal)
            for index in 0..<3 {
                let i = CGFloat(index)
                let grow = Ease.backOut(Ease.clamp((t - 0.04 - 0.05 * i) / 0.14))
                let fade = 1 - Ease.smooth(Ease.clamp((t - 1.05 - 0.05 * i) / 0.13))
                let radius = dot / 2 * grow * fade
                guard radius > 0.05 else { continue }
                let hop = (Ease.bump(t, from: 0.2 + 0.1 * i, length: 0.26) + Ease.bump(t, from: 0.62 + 0.1 * i, length: 0.26)) * lift
                ctx.fillEllipse(in: circle(CGPoint(x: body.midX + (i - 1) * step, y: body.midY - hop), radius))
            }
        }
    }

    /// Jobs: the clock badge swells out over the calendar, its minute hand spinning once round, and shrinks back with
    /// a little give; the hour hand stays. (The first cuts only spun the hand: "Jobs isn't enough"; three turns were
    /// "too long", and two still "feels longer than the other ones": one turn, done in Bots' time.)
    private static func clock(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let seed = whole.rightmost(), let disc = whole.piece(from: seed, ink: true),
              let box = disc.bounds() else { return nil }
        let centre = CGPoint(x: box.midX, y: box.midY), radius = box.width / 2, pixel = 1 / whole.scale
        // The hands are the clear parts inside the disc: the minute hand up, the hour hand left, round-capped, meeting
        // at a pivot a hair off the disc's centre.
        guard let hands = disc.bounds(ink: false, within: radius * 0.85, of: centre) else { return nil }
        let width = disc.run(ink: false, atY: centre.y - radius * 0.35, from: centre.x - radius * 0.4, to: centre.x + radius * 0.4)
        guard width > 0 else { return nil }
        let pivot = CGPoint(x: hands.maxX - width / 2, y: hands.maxY - width / 2)
        let minute = pivot.y - (hands.minY + width / 2), hour = pivot.x - (hands.minX + width / 2)
        guard minute > width, hour > width else { return nil }
        // The gap the symbol leaves round the clock, out from it towards the calendar (up and left).
        var gap = radius * 0.25, out = radius + pixel
        while out < radius * 1.8 {
            if whole.ink(at: CGPoint(x: centre.x - out * 0.7071, y: centre.y - out * 0.7071)) { gap = out - radius; break }
            out += pixel
        }
        // It grows from its outer corner, so it spreads over the calendar and stays inside the icon's bottom right.
        let corner = CGPoint(x: box.maxX, y: box.maxY)
        return frames(art, duration: 0.95) { t, ctx in
            let grow = Ease.backOut(Ease.clamp((t - 0.1) / 0.25)) * (1 - Ease.spring(t - 0.45, damping: 0.5, frequency: 13))
            let size = 1 - 0.12 * Ease.bump(t, from: 0, length: 0.2) + 0.5 * grow
            let angle = 2 * .pi * Ease.smooth((t - 0.1) / 0.5)
            let middle = CGPoint(x: corner.x + (centre.x - corner.x) * size, y: corner.y + (centre.y - corner.y) * size)
            let pin = CGPoint(x: middle.x + (pivot.x - centre.x) * size, y: middle.y + (pivot.y - centre.y) * size)
            // The clock at rest cleared, then room cut for it where it is now, the face filled and the hands cut again.
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: circle(centre, radius + pixel))
            ctx.fillEllipse(in: circle(middle, radius * size + gap * min(size, 1.2)))
            ctx.setBlendMode(.normal)
            ctx.fillEllipse(in: circle(middle, radius * size))
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(width * size)
            ctx.setLineCap(.round)
            ctx.move(to: pin)
            ctx.addLine(to: CGPoint(x: pin.x - hour * size, y: pin.y))
            ctx.move(to: pin)
            ctx.addLine(to: CGPoint(x: pin.x + minute * size * sin(angle), y: pin.y - minute * size * cos(angle)))
            ctx.strokePath()
        }
    }

    /// Artifacts: the photo's sun sinks behind the hills, stays down a beat, and rises past its place, swelling as it
    /// clears them, then settles.
    private static func sunrise(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = frontPart(of: whole)?.map.bounds() else { return nil }
        // The sun is a round hole in the filled photo, a round dot in the outline one, a third of the way across and
        // down; the hills below it are the same (a hole or ink), so the sun merges into them as it sets.
        let middle = CGPoint(x: box.minX + box.width * 0.35, y: box.minY + box.height * 0.38)
        let hole = !whole.ink(at: middle)
        guard let sun = whole.piece(from: middle, ink: !hole, maxArea: box.width * box.height * 0.15)?.bounds(),
              sun.width > 1, abs(sun.width - sun.height) < sun.width * 0.2 else { return nil }
        let radius = sun.width / 2, home = CGPoint(x: sun.midX, y: sun.midY)
        let drop = box.height * 0.45
        let inside = box.insetBy(dx: box.height * 0.08, dy: box.height * 0.08)
        return frames(art, duration: 1.15) { t, ctx in
            let sink = t < 0.3 ? Ease.smooth(t / 0.3) : t < 0.42 ? 1 : 1 - Ease.spring(t - 0.42, damping: 0.45, frequency: 12)
            let glow = 1 + 0.25 * Ease.bump(t, from: 0.5, length: 0.45)
            // The sun's place filled back (a hole) or cleared (a dot), then the sun drawn lower.
            ctx.setBlendMode(hole ? .normal : .clear)
            ctx.fillEllipse(in: circle(home, radius * 1.15))
            ctx.setBlendMode(hole ? .clear : .normal)
            ctx.clip(to: inside)
            ctx.fillEllipse(in: circle(CGPoint(x: home.x, y: home.y + drop * sink), radius * glow))
        }
    }

    /// More: the outer dots swing a full turn round the middle one, reaching out as they go, and settle back in a row
    /// with a little give, the middle dot pulsing. (The first cuts parted them, mostly while the bar's lens covered
    /// them: "I can't even tell that the more icon [does] anything at all"; dots running along their row read as
    /// standing still, as one dot looks like the next.)
    private static func spread(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        // The middle dot sits at the middle: cut through the circle (ellipsis.circle.fill), or ink on nothing (the
        // outline circle and the plain ellipsis). The other two are the pieces of the same kind and size along its row,
        // not the circle's ring or the room around the filled one.
        let middle = CGPoint(x: box.midX, y: box.midY)
        let holes = !whole.ink(at: middle)
        guard let dot = whole.piece(from: middle, ink: !holes, maxArea: art.size.width * art.size.height * 0.25)?.bounds() else { return nil }
        let size = dot.width, y = dot.midY, pixel = 1 / whole.scale
        let row = whole.runs(ink: !holes, atY: y, from: 0, to: art.size.width - pixel)
        let dots = row.filter {
            guard let piece = whole.piece(from: CGPoint(x: ($0.lowerBound + $0.upperBound) / 2, y: y), ink: !holes, maxArea: dot.width * dot.height * 2)?.bounds() else { return false }
            return abs(piece.width - dot.width) < dot.width * 0.3 && abs(piece.height - dot.height) < dot.height * 0.3
        }
        guard size > 0, dots.count == 3 else { return nil }
        let centres = dots.map { ($0.lowerBound + $0.upperBound) / 2 }
        let spacing = (centres[2] - centres[0]) / 2, hub = CGPoint(x: centres[1], y: y)
        guard spacing > size else { return nil }
        // A turn and a little back first, so it winds up; the plain ellipsis swings into the room round its image.
        return frames(art, duration: 1.4) { t, ctx in
            let angle = t < 0.16 ? -0.35 * Ease.smooth(t / 0.16) : -0.35 + (2 * .pi + 0.35) * Ease.spring(t - 0.16, damping: 0.55, frequency: 7.5)
            let reach = spacing * (1 + 0.3 * Ease.bump(t, from: 0.12, length: 0.75))
            let pulse = 1 + 0.3 * Ease.bump(t, from: 0.1, length: 0.5)
            ctx.setBlendMode(holes ? .normal : .clear)
            for x in centres { ctx.fillEllipse(in: circle(CGPoint(x: x, y: y), size / 2 * 1.15)) }
            ctx.setBlendMode(holes ? .clear : .normal)
            ctx.fillEllipse(in: circle(hub, size / 2 * pulse))
            for side in [-1, 1] as [CGFloat] {
                ctx.fillEllipse(in: circle(CGPoint(x: hub.x + side * reach * cos(angle), y: hub.y + side * reach * sin(angle)), size / 2))
            }
        }
    }

    /// Settings: the gear winds back a little and spins three quarters of a turn, running past and settling. It has
    /// eight teeth, so six teeth on it looks the same as at rest. At its fastest it turns about 14° a frame: near 22°
    /// (half a tooth) the eye can't tell which way it turns, and it looks still or running backwards.
    private static func gear(_ art: SymbolArt) -> Motion? {
        guard let box = art.probe()?.bounds() else { return nil }
        let centre = CGPoint(x: box.midX, y: box.midY)
        let turn: CGFloat = 1.5 * .pi, back: CGFloat = 0.3
        return frames(art, duration: 1.6, base: false) { t, ctx in
            let angle = t < 0.2 ? -back * Ease.smooth(t / 0.18) : -back + (turn + back) * Ease.spring(t - 0.2, damping: 0.6, frequency: 6)
            art.drawSymbol(ctx, .about(centre, rotation: angle))
        }
    }

    /// Capabilities: the four squares move round the grid one place, clockwise, shrinking as they go, and again.
    private static func grid(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        let squares = whole.pieces(ink: true, minArea: box.width * box.height * 0.04)
        guard squares.count == 4 else { return nil }
        let centre = CGPoint(x: box.midX, y: box.midY)
        // Clockwise from the top left.
        let order = squares.compactMap { piece in piece.bounds().map { (piece, CGPoint(x: $0.midX, y: $0.midY)) } }
            .sorted { atan2($0.1.y - centre.y, $0.1.x - centre.x) < atan2($1.1.y - centre.y, $1.1.x - centre.x) }
        guard order.count == 4 else { return nil }
        let places = order.map(\.1), parts = order.map { art.part($0.0) }
        return frames(art, duration: 1.45, base: false) { t, ctx in
            let along = Ease.backOut(Ease.clamp((t - 0.15) / 0.38)) + Ease.backOut(Ease.clamp((t - 0.72) / 0.38))
            let from = Int(along.rounded(.down)), between = along - along.rounded(.down)
            for (index, part) in parts.enumerated() {
                let a = places[(index + from) % 4], b = places[(index + from + 1) % 4]
                let to = CGPoint(x: a.x + (b.x - a.x) * between, y: a.y + (b.y - a.y) * between)
                let size = 1 - 0.3 * sin(.pi * Ease.clamp(between))
                ctx.draw(part, .about(places[index], scale: size, move: CGPoint(x: to.x - places[index].x, y: to.y - places[index].y)))
            }
        }
    }

    /// Connectors: the plug pulls back, then pushes its prongs into the socket on its right (they go in out of sight),
    /// buzzes there with sparks at the socket, and comes back out with a little give.
    private static func plug(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds(), let tip = whole.rightmost() else { return nil }
        let wall = box.maxX + 2 / whole.scale, reach = box.width * 0.3, back = box.width * 0.1, line = box.height * 0.1
        let room = CGRect(x: -art.pad, y: -art.pad, width: wall + art.pad, height: art.size.height + art.pad * 2)
        return frames(art, duration: 1.5, base: false) { t, ctx in
            let x: CGFloat
            if t < 0.2 { x = -back * Ease.smooth(t / 0.2) }
            else if t < 0.38 { let q = Ease.clamp((t - 0.2) / 0.18); x = -back + (back + reach) * q * q }
            else if t < 0.9 { x = reach + box.width * 0.025 * sin(2 * .pi * 15 * (t - 0.38)) * exp(-(t - 0.38) / 0.25) }
            else { x = reach * (1 - Ease.spring(t - 0.9, damping: 0.5, frequency: 12)) }
            ctx.saveGState()
            ctx.clip(to: room)
            art.drawSymbol(ctx, CGAffineTransform(translationX: x, y: 0))
            ctx.restoreGState()
            guard t > 0.38, t < 0.66 else { return }
            // Sparks: three short strokes fanning out from the socket, flying out and shrinking.
            let u = (t - 0.38) / 0.28
            ctx.setLineWidth(line)
            ctx.setLineCap(.round)
            for angle in [-0.9, 0, 0.9] as [CGFloat] {
                let near = box.height * (0.12 + 0.15 * u), far = near + box.height * 0.22 * (1 - u)
                ctx.move(to: CGPoint(x: wall + cos(angle) * near, y: tip.y + sin(angle) * near))
                ctx.addLine(to: CGPoint(x: wall + cos(angle) * far, y: tip.y + sin(angle) * far))
            }
            ctx.strokePath()
        }
    }

    /// Bot Profiles: the person ducks down into the circle, pops back up past its place, settles and nods once.
    private static func person(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        let pixel = 1 / whole.scale
        let centre = CGPoint(x: box.midX, y: box.midY), radius = min(box.width, box.height) / 2
        // The rim: the ink in from the circle's top or bottom, whichever is thinner (the filled circle's band below
        // the shoulders, the outline's ring at the top).
        func rim(from start: CGFloat, by step: CGFloat) -> CGFloat {
            var y = start, run: CGFloat = 0
            // Past the soft edge (at the bar's sizes the outermost pixel can be under half ink), then the ink.
            while abs(y - start) < radius * 0.15, !whole.ink(at: CGPoint(x: centre.x, y: y)) { y += step }
            while run < radius, whole.ink(at: CGPoint(x: centre.x, y: y)) { y += step; run += pixel }
            return run
        }
        let edge = min(rim(from: box.minY + pixel / 2, by: pixel), rim(from: box.maxY - pixel / 2, by: -pixel))
        guard edge > pixel * 2, edge < radius * 0.4 else { return nil }
        let inner = radius - edge - pixel * 2
        // Inside the rim the filled circle is ink with the person cut out of it; the outline is empty, the person ink.
        let filled = whole.ink(at: CGPoint(x: centre.x - inner * 0.6, y: centre.y - inner * 0.6))
        let figure = art.shape((filled ? whole.inverted() : whole).within { hypot($0.x - centre.x, $0.y - centre.y) < inner })
        return frames(art, duration: 1.45) { t, ctx in
            var drop = t < 0.34 ? 0.6 * Ease.smooth(t / 0.22) : 0.6 * (1 - Ease.spring(t - 0.34, damping: 0.42, frequency: 13))
            drop -= 0.12 * Ease.bump(t, from: 1.02, length: 0.3)
            ctx.setBlendMode(filled ? .normal : .clear)
            ctx.fillEllipse(in: circle(centre, filled ? inner + pixel * 2 : inner))
            ctx.addEllipse(in: circle(centre, inner))
            ctx.clip()
            figure.draw(at: CGPoint(x: 0, y: drop * inner), blendMode: filled ? .destinationOut : .normal, alpha: 1)
        }
    }

    /// Messaging: the bubble pulls into its tail, pops back out past its size and wobbles as it settles.
    private static func message(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        let pixel = 1 / whole.scale
        // The tail's tip: the lowest ink, its left end.
        guard let low = whole.runs(ink: true, atY: box.maxY - pixel / 2, from: box.minX, to: box.maxX - pixel).first else { return nil }
        let tip = CGPoint(x: low.lowerBound, y: box.maxY)
        return frames(art, duration: 1.4, base: false) { t, ctx in
            let size = t < 0.36 ? 1 - 0.8 * Ease.smooth(t / 0.3) : 0.2 + 0.8 * Ease.spring(t - 0.36, damping: 0.4, frequency: 13)
            let wobble = t < 0.36 ? 0 : 0.08 * sin(2 * .pi * (t - 0.36) / 0.32) * exp(-(t - 0.36) / 0.35)
            art.drawSymbol(ctx, .about(tip, scale: size * (1 + wobble), scaleY: size * (1 - wobble)))
        }
    }

    /// Files: a page rises out of the folder, past its top, sways and drops back in; the folder takes it with a dip.
    private static func folder(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        let pixel = 1 / whole.scale
        // Down a column right of the tab: the filled folder is ink with its front's top edge cut through it as a line,
        // then the front; the outline is its top edge, the room behind, the front's top edge in ink, then the room in
        // front. Either way the longest run is the front and the one before it the front's top edge.
        let column = whole.column(atX: box.minX + box.width * 0.62, from: box.minY, to: box.maxY - pixel)
        guard let front = column.indices.max(by: { column[$0].to - column[$0].from < column[$1].to - column[$1].from }), front > 0 else { return nil }
        let top = column[front - 1].from, weight = column[front - 1].to - column[front - 1].from
        guard weight > pixel * 2, weight < box.height * 0.2 else { return nil }
        let sheet = CGSize(width: box.width * 0.56, height: box.height * 0.78)
        let left = box.midX - sheet.width / 2 + box.width * 0.04
        let tucked = top + weight, out = box.minY - box.height * 0.2
        let behind = CGRect(x: -art.pad, y: -art.pad, width: art.size.width + art.pad * 2, height: top + art.pad)
        return frames(art, duration: 1.5, base: false) { t, ctx in
            let rise = t < 0.9 ? Ease.backOut(Ease.clamp((t - 0.12) / 0.36)) : 1 - Ease.smooth((t - 0.9) / 0.3)
            let sway = 0.1 * sin(2 * .pi * (t - 0.48) / 0.42) * Ease.bump(t, from: 0.48, length: 0.42)
            let dip = Ease.bump(t, from: 1.16, length: 0.26)
            art.drawSymbol(ctx, .about(CGPoint(x: box.midX, y: box.maxY), scale: 1 + 0.04 * dip, scaleY: 1 - 0.1 * dip))
            let page = CGRect(x: left, y: tucked + (out - tucked) * rise, width: sheet.width, height: sheet.height)
            guard page.minY < top else { return }
            // Behind the front: only above its top edge. The page hides what is behind it, and has an edge and two
            // lines of writing in the symbol's weight.
            ctx.clip(to: behind)
            ctx.concatenate(.about(CGPoint(x: page.midX, y: page.maxY), rotation: sway))
            ctx.setBlendMode(.clear)
            ctx.addPath(UIBezierPath(roundedRect: page, cornerRadius: weight).cgPath)
            ctx.fillPath()
            ctx.setBlendMode(.normal)
            ctx.setLineWidth(weight)
            ctx.addPath(UIBezierPath(roundedRect: page.insetBy(dx: weight / 2, dy: weight / 2), cornerRadius: weight / 2).cgPath)
            ctx.strokePath()
            ctx.setLineWidth(weight * 0.85)
            ctx.setLineCap(.round)
            for share in [0.3, 0.48] as [CGFloat] {
                ctx.move(to: CGPoint(x: page.minX + page.width * 0.24, y: page.minY + page.height * share))
                ctx.addLine(to: CGPoint(x: page.maxX - page.width * 0.24, y: page.minY + page.height * share))
            }
            ctx.strokePath()
        }
    }

    /// Changes: the branch's two arms swing in together over the trunk, then fork out past their places and settle,
    /// and flick in once more.
    private static func branch(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        let pixel = 1 / whole.scale, low = box.maxY - box.height * 0.15
        guard let trunk = whole.runs(ink: true, atY: low, from: box.minX, to: box.maxX - pixel).max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }) else { return nil }
        let line = trunk.upperBound - trunk.lowerBound
        // The fork: going up the trunk, the first row where the arms part.
        var fork = low
        while fork > box.minY + box.height * 0.25, whole.width(atY: fork) < line * 1.6 { fork -= pixel }
        guard line > pixel * 2, fork > box.minY + box.height * 0.25 else { return nil }
        // On the pixel grid, so the cut between the arms and the stem leaves no seam at rest.
        let grid = { (value: CGFloat) in (value * art.scale).rounded() / art.scale }
        let pivot = CGPoint(x: grid((trunk.lowerBound + trunk.upperBound) / 2), y: grid(fork + line * 0.6))
        let all = CGRect(origin: .zero, size: art.size)
        let left = art.region(CGRect(x: all.minX, y: all.minY, width: pivot.x, height: pivot.y))
        let right = art.region(CGRect(x: pivot.x, y: all.minY, width: all.maxX - pivot.x, height: pivot.y))
        let stem = art.region(CGRect(x: all.minX, y: pivot.y, width: all.width, height: all.maxY - pivot.y))
        return frames(art, duration: 1.45, base: false) { t, ctx in
            var close = t < 0.36 ? 0.5 * Ease.smooth(t / 0.26) : 0.5 * (1 - Ease.spring(t - 0.36, damping: 0.38, frequency: 14))
            close += 0.16 * Ease.bump(t, from: 0.98, length: 0.26)
            stem.draw(at: .zero)
            ctx.draw(left, .about(pivot, rotation: close))
            ctx.draw(right, .about(pivot, rotation: -close))
            // The trunk up to the fork, over the cut, which opens a wedge as the arms turn.
            ctx.setLineWidth(line)
            ctx.setLineCap(.round)
            ctx.move(to: pivot)
            ctx.addLine(to: CGPoint(x: pivot.x, y: fork))
            ctx.strokePath()
        }
    }

    /// Status & Maintenance: the needle dips, sweeps round into the red, revs there and drops back with a bounce.
    private static func gauge(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        let centre = CGPoint(x: box.midX, y: box.midY)
        // The needle and its hub, at the middle: cut out of the filled dial, ink in the outline one.
        let cut = !whole.ink(at: centre)
        guard let needle = whole.piece(from: centre, ink: !cut, maxArea: box.width * box.height * 0.2) else { return nil }
        let part = cut ? art.shape(needle) : art.part(needle), wider = art.shape(needle.grown(by: 6))
        return frames(art, duration: 1.55) { t, ctx in
            let angle: CGFloat
            if t < 0.15 { angle = -0.25 * Ease.smooth(t / 0.15) }
            else if t < 0.42 { angle = -0.25 + 2.15 * Ease.smooth((t - 0.15) / 0.27) }
            else if t < 0.9 { angle = 1.9 + 0.13 * sin(2 * .pi * 12 * (t - 0.42)) * (1 - Ease.smooth((t - 0.42) / 0.48)) }
            else { angle = 1.9 * (1 - Ease.spring(t - 0.9, damping: 0.42, frequency: 11)) }
            wider.draw(at: .zero, blendMode: cut ? .normal : .destinationOut, alpha: 1)
            ctx.draw(part, .about(centre, rotation: angle), blend: cut ? .destinationOut : .normal)
        }
    }

    /// Spawn Tree: a signal runs from the top left node down to the bottom one, up to the top right and back across,
    /// each dot swelling as it passes and each node as it arrives (the bottom one, spawned, most).
    private static func tree(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe() else { return nil }
        let pieces = whole.pieces(ink: true, minArea: 0.05).compactMap { piece in
            piece.bounds().map { (part: art.part(piece), wider: art.shape(piece.grown(by: 5)), centre: CGPoint(x: $0.midX, y: $0.midY), area: piece.area) }
        }.sorted { $0.area > $1.area }
        guard pieces.count >= 6 else { return nil }
        let nodes = pieces.prefix(3).sorted { $0.centre.y < $1.centre.y }
        let tops = nodes.prefix(2).sorted { $0.centre.x < $1.centre.x }
        let path = [tops[0].centre, nodes[2].centre, tops[1].centre, tops[0].centre]
        // Where a dot lies along the path: 0 at the top left node, 1 at the bottom, 2 at the top right, 3 back.
        func along(_ point: CGPoint) -> CGFloat {
            var best = (distance: CGFloat.infinity, at: CGFloat(0))
            for leg in 0..<3 {
                let a = path[leg], b = path[leg + 1], dx = b.x - a.x, dy = b.y - a.y
                let u = Ease.clamp(((point.x - a.x) * dx + (point.y - a.y) * dy) / max(dx * dx + dy * dy, 0.0001))
                let distance = hypot(point.x - a.x - dx * u, point.y - a.y - dy * u)
                if distance < best.distance { best = (distance, CGFloat(leg) + u) }
            }
            return best.at
        }
        let when = { (at: CGFloat) in 0.15 + 0.32 * at }
        // Each piece's swell over time: a node at its stop (the top left at both ends), a dot as the signal passes.
        let swells: [(CGFloat) -> CGFloat] = pieces.enumerated().map { index, piece in
            guard index < 3 else {
                let at = along(piece.centre)
                return { t in Ease.bump(t, from: when(at) - 0.1, length: 0.24) }
            }
            if piece.centre == tops[0].centre {
                return { t in 0.3 * Ease.bump(t, from: when(0) - 0.06, length: 0.32) + 0.22 * Ease.bump(t, from: when(3) - 0.06, length: 0.32) }
            }
            let at: CGFloat = piece.centre == nodes[2].centre ? 1 : 2, size: CGFloat = at == 1 ? 0.45 : 0.35
            return { t in size * Ease.bump(t, from: when(at) - 0.06, length: 0.32) }
        }
        return frames(art, duration: 1.45) { t, ctx in
            let moving = pieces.indices.compactMap { index -> (Int, CGFloat)? in
                let swell = swells[index](t)
                return swell > 0.001 ? (index, swell) : nil
            }
            // All moved pieces out first, then each drawn swollen, so one doesn't cut into its neighbour.
            for (index, _) in moving { pieces[index].wider.draw(at: .zero, blendMode: .destinationOut, alpha: 1) }
            for (index, swell) in moving { ctx.draw(pieces[index].part, .about(pieces[index].centre, scale: 1 + swell)) }
        }
    }

    /// Star Map: the stars twinkle in turn, small to big: each shrinks as it turns, then flares past its size and
    /// settles a quarter turn round (a four-pointed star looks the same).
    private static func sparkles(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe() else { return nil }
        let stars = whole.pieces(ink: true, minArea: 0.05).map { ($0, $0.area) }.sorted { $0.1 < $1.1 }.compactMap { star, _ in
            star.bounds().map { (part: art.part(star), wider: art.shape(star.grown(by: 6)), centre: CGPoint(x: $0.midX, y: $0.midY)) }
        }
        guard stars.count == 3 else { return nil }
        let starts: [CGFloat] = [0.12, 0.3, 0.48]
        return frames(art, duration: 1.45) { t, ctx in
            var moved: [(UIImage, CGAffineTransform)] = []
            for (index, star) in stars.enumerated() {
                let u = t - starts[index]
                guard u > 0 else { continue }
                let size: CGFloat, turn: CGFloat
                if u < 0.18 {
                    let k = Ease.smooth(u / 0.18)
                    size = 1 - 0.75 * k
                    turn = .pi / 4 * k
                } else {
                    let k = Ease.spring(u - 0.18, damping: 0.38, frequency: 15)
                    size = 0.25 + 0.75 * k
                    turn = .pi / 4 * (1 + k)
                }
                star.wider.draw(at: .zero, blendMode: .destinationOut, alpha: 1)
                moved.append((star.part, .about(star.centre, scale: size, rotation: turn)))
            }
            for (part, transform) in moved { ctx.draw(part, transform) }
        }
    }

    /// Changes (Mac polish #65): the plus springs out of its corner turning a quarter (it looks the same after one),
    /// swelling past an ×, and the minus slides out of its own a beat later, stretching along its line; each settles
    /// back with a spring. Where the three marks touch (a tiny size) the whole lifts and drops instead.
    private static func changes(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        // The plus top left, the minus bottom right, the line between them.
        let marks = whole.pieces(ink: true, minArea: box.width * box.height * 0.01).compactMap { piece in
            piece.bounds().map { (piece: piece, centre: CGPoint(x: $0.midX, y: $0.midY)) }
        }
        guard marks.count == 3, let plus = marks.min(by: { $0.centre.x + $0.centre.y < $1.centre.x + $1.centre.y }),
              let minus = marks.max(by: { $0.centre.x + $0.centre.y < $1.centre.x + $1.centre.y }) else { return drop(art) }
        let plusPart = art.part(plus.piece), plusRoom = art.shape(plus.piece.grown(by: 6))
        let minusPart = art.part(minus.piece), minusRoom = art.shape(minus.piece.grown(by: 6))
        // Out along the line between them, away from the middle.
        let reach = CGPoint(x: box.width * 0.16, y: box.height * 0.16)
        return frames(art, duration: 1.3) { t, ctx in
            let turn = .pi / 2 * Ease.spring(t - 0.1, damping: 0.5, frequency: 10)
            let out = Ease.bump(t, from: 0.1, length: 0.5), slide = Ease.bump(t, from: 0.35, length: 0.5)
            plusRoom.draw(at: .zero, blendMode: .destinationOut, alpha: 1)
            minusRoom.draw(at: .zero, blendMode: .destinationOut, alpha: 1)
            ctx.draw(plusPart, .about(plus.centre, scale: 1 + 0.3 * out, rotation: turn, move: CGPoint(x: -reach.x * out, y: -reach.y * out)))
            ctx.draw(minusPart, .about(minus.centre, scale: 1 + 0.5 * slide, scaleY: 1, move: CGPoint(x: reach.x * slide, y: reach.y * slide)))
        }
    }

    /// Star Map's one star on the Mac (Mac polish #64): it shrinks turning a tenth of a turn, then flares back past its
    /// size and on to a fifth, where a five-pointed star looks as it started. It turns about its own middle, which sits
    /// lower than its box's (the box runs from the top point down to the two lower points, cos 36° of the way).
    private static func star(_ art: SymbolArt) -> Motion? {
        guard let box = art.probe()?.bounds() else { return nil }
        let centre = CGPoint(x: box.midX, y: box.minY + box.height / (1 + cos(.pi / 5)))
        return frames(art, duration: 1.2, base: false) { t, ctx in
            let u = t - 0.1
            let size: CGFloat, turn: CGFloat
            if u < 0.2 {
                let k = Ease.smooth(u / 0.2)
                (size, turn) = (1 - 0.55 * k, .pi / 5 * k)
            } else {
                let k = Ease.spring(u - 0.2, damping: 0.38, frequency: 15)
                (size, turn) = (0.45 + 0.55 * k, .pi / 5 * (1 + k))
            }
            art.drawSymbol(ctx, .about(centre, scale: size, rotation: turn))
        }
    }

    /// Webhooks: the turn arrow drives off up and to the right, out of the sign, and the next comes in behind it from
    /// the bottom left, running a touch past its place.
    private static func sign(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        let pixel = 1 / whole.scale
        // The room round the diamond, from the image's corner, which it doesn't reach; the sign is the rest.
        guard let outside = whole.piece(from: CGPoint(x: pixel / 2, y: pixel / 2), ink: false) else { return nil }
        let shape = outside.inverted()
        let filled = whole.intersecting(shape).area > shape.area * 0.6
        // The arrow: the biggest piece clear of the sign's edge (a hole in the filled sign, ink in the outline).
        let inner = box.insetBy(dx: pixel * 3, dy: pixel * 3)
        let inside = { (piece: InkMap) in piece.bounds().map { inner.contains($0) } ?? false }
        guard let arrow = whole.pieces(ink: !filled, minArea: 0.05).filter(inside).max(by: { $0.area < $1.area }) else { return nil }
        // Where it may show: inside the sign's edge (the filled sign keeps a band round its edge).
        let room: InkMap
        if filled {
            room = shape.shrunk(by: Int(box.width * 0.07 * whole.scale)).union(arrow.grown(by: 3))
        } else {
            guard let edge = whole.pieces(ink: true).filter({ !inside($0) }).max(by: { $0.area < $1.area }) else { return nil }
            room = shape.subtracting(edge.grown(by: 2)).union(arrow.grown(by: 3))
        }
        guard let roomMask = room.clipMask() else { return nil }
        let part = filled ? art.shape(arrow) : art.part(arrow), wider = art.shape(arrow.grown(by: 6))
        let travel = CGPoint(x: box.width * 0.55, y: -box.height * 0.55)
        return frames(art, duration: 1.35) { t, ctx in
            let along = t < 0.2 ? -0.06 * Ease.smooth(t / 0.18) : -0.06 + 1.06 * Ease.spring(t - 0.2, damping: 0.55, frequency: 9)
            wider.draw(at: .zero, blendMode: filled ? .normal : .destinationOut, alpha: 1)
            ctx.clip(to: roomMask, size: art.size)
            for k in [along, along - 1] {
                ctx.draw(part, CGAffineTransform(translationX: travel.x * k, y: travel.y * k), blend: filled ? .destinationOut : .normal)
            }
        }
    }

    /// [tiles] Tiles (owner 2026-11-03, the Dashboard renamed; the first jiggle was too small to see: "The Tiles icon
    /// doesn't animate like the others"): the three tiles flip over in turn like cards, each turning edge-on and back
    /// round its own middle (so none runs into the next), then settle with a little give.
    private static func tiles(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        let pieces = whole.pieces(ink: true, minArea: box.width * box.height * 0.04)
        guard pieces.count == 3 else { return nil }
        // Left to right, top to bottom: the two small tiles, then the tall one.
        let order = pieces.compactMap { piece in piece.bounds().map { (piece, $0) } }
            .sorted { ($0.1.minX, $0.1.minY) < ($1.1.minX, $1.1.minY) }
        guard order.count == 3 else { return nil }
        let parts = order.map { art.part($0.0) }, centres = order.map { CGPoint(x: $0.1.midX, y: $0.1.midY) }
        return frames(art, duration: 1.3, base: false) { t, ctx in
            for (index, part) in parts.enumerated() {
                let start = 0.08 + CGFloat(index) * 0.12, length: CGFloat = 0.42
                let u = Ease.clamp((t - start) / length)
                // Edge-on halfway (never quite nothing: the tile stays a line), its near edge taller as a card's is while it
                // turns, then a small swell as it lands.
                let turn = max(abs(cos(u * .pi)), 0.06)
                let swell = u < 1 ? 0 : 0.07 * (1 - Ease.spring(t - start - length, damping: 0.45, frequency: 16))
                let centre = centres[index]
                let move = CGAffineTransform(translationX: centre.x, y: centre.y)
                    .scaledBy(x: turn * (1 + swell), y: 1 + swell + 0.12 * sin(u * .pi)).translatedBy(x: -centre.x, y: -centre.y)
                ctx.draw(part, move)
            }
        }
    }

    /// [terminal] Terminal (a tab since 0.9.25, found with no motion by TabMotionTests 2026-11-03): the window is typed
    /// on, pressing down three times like a key, quicker each time, then hops up and springs back.
    private static func terminal(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        let base = CGPoint(x: box.midX, y: box.maxY)
        return frames(art, duration: 1.2, base: false) { t, ctx in
            let press = [(0.04, 0.16), (0.22, 0.13), (0.37, 0.11)].map { Ease.bump(t, from: $0.0, length: $0.1) }.reduce(0, +)
            let hop = Ease.bump(t, from: 0.5, length: 0.26)
            let settle = t < 0.76 ? 0 : 0.1 * (1 - Ease.spring(t - 0.76, damping: 0.4, frequency: 18))
            let squash = 0.2 * press - settle
            art.drawSymbol(ctx, .about(base, scale: 1 + squash * 0.5, scaleY: 1 - squash, move: CGPoint(x: 0, y: -box.height * 0.28 * hop)))
        }
    }

    /// [tasks] Tasks: the list hops, tipping as if a box were ticked, and lands with a little squash.
    private static func checklist(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        let base = CGPoint(x: box.midX, y: box.maxY)
        return frames(art, duration: 1.0, base: false) { t, ctx in
            let hop = Ease.bump(t, from: 0.05, length: 0.4)
            let tip = -0.16 * Ease.bump(t, from: 0.1, length: 0.3)
            let settle = t < 0.45 ? 0 : 0.12 * (1 - Ease.spring(t - 0.45, damping: 0.4, frequency: 16))
            art.drawSymbol(ctx, .about(base, scale: 1 + settle * 0.5, scaleY: 1 - settle, rotation: tip,
                                       move: CGPoint(x: 0, y: -box.height * 0.3 * hop)))
        }
    }

    /// Usage's chart: each bar grows up from the baseline in turn and lands with a small swell, a chart drawing itself.
    /// Bars that merge at a small size: the whole chart hops, as Tasks' list does.
    private static func bars(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        let order = whole.pieces(ink: true, minArea: box.width * box.height * 0.03)
            .compactMap { piece in piece.bounds().map { (piece, $0) } }
            .sorted { $0.1.minX < $1.1.minX }
        guard order.count >= 2 else { return checklist(art) }
        let parts = order.map { art.part($0.0) }, base = box.maxY
        return frames(art, duration: 1.2, base: false) { t, ctx in
            for (index, part) in parts.enumerated() {
                let start = 0.06 + CGFloat(index) * 0.12, length: CGFloat = 0.36
                let u = Ease.clamp((t - start) / length)
                let height = u < 1 ? 0.2 + 0.8 * Ease.smooth(u) : 1 + 0.08 * (1 - Ease.spring(t - start - length, damping: 0.45, frequency: 16))
                ctx.draw(part, CGAffineTransform(translationX: 0, y: base).scaledBy(x: 1, y: height).translatedBy(x: 0, y: -base))
            }
        }
    }

    /// Import Sessions where its squares can't be told apart: the whole stack lifts, drops into place squashing a
    /// little, and springs back.
    private static func drop(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        let base = CGPoint(x: box.midX, y: box.maxY)
        return frames(art, duration: 1.2, base: false) { t, ctx in
            let lift: CGFloat
            if t < 0.22 { lift = Ease.smooth(t / 0.22) }
            else if t < 0.4 { let q = Ease.clamp((t - 0.22) / 0.18); lift = 1 - q * q }
            else { lift = 0 }
            let squash = t < 0.4 ? 0 : 0.18 * (1 - Ease.spring(t - 0.4, damping: 0.4, frequency: 16))
            art.drawSymbol(ctx, .about(base, scale: 1 + squash * 0.5, scaleY: 1 - squash, move: CGPoint(x: 0, y: -box.height * 0.3 * lift)))
        }
    }

    /// Import Sessions: the front square lifts, drops onto the one behind (the stack becomes one) and springs back.
    private static func stack(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let seed = whole.rightmost(), let back = whole.piece(from: seed, ink: true),
              let behind = back.bounds() else { return nil }
        let front = whole.subtracting(back), pixel = 1 / whole.scale
        // The outline's two squares touch at tab sizes (Desktop Look, the Mac's sidebar): the whole stack drops instead.
        guard back.area < whole.area * 0.6 else { return drop(art) }
        guard let ahead = front.bounds() else { return nil }
        let shift = CGPoint(x: behind.maxX - ahead.maxX, y: behind.maxY - ahead.maxY)
        guard shift.x > pixel * 6, shift.y > pixel * 6 else { return nil }
        // The gap the symbol leaves round the front square: along the back square's top edge, from the front's side.
        let row = whole.runs(ink: false, atY: behind.minY + pixel * 3, from: ahead.maxX - pixel * 3, to: behind.maxX - pixel)
        let gap = row.first.map { ($0.upperBound - $0.lowerBound) * 0.9 } ?? ahead.width * 0.06
        // What the front hides as it goes: its square (with the room inside an outline one) and the arrow, and the gap.
        let square = CGRect(x: ahead.minX, y: ahead.maxY - ahead.width, width: ahead.width, height: ahead.width)
        let grown = art.shape(front.grown(by: Int(gap * whole.scale)))
        let cover = art.render { ctx in
            ctx.addPath(UIBezierPath(roundedRect: square.insetBy(dx: -gap, dy: -gap), cornerRadius: square.width * 0.2 + gap).cgPath)
            ctx.fillPath()
            grown.draw(at: .zero)
        }
        let backPart = art.part(back), frontPart = art.part(front)
        return frames(art, duration: 1.4, base: false) { t, ctx in
            let drop: CGFloat
            if t < 0.2 { drop = -0.35 * Ease.smooth(t / 0.2) }
            else if t < 0.44 { let q = Ease.clamp((t - 0.2) / 0.24); drop = -0.35 + 1.35 * q * q }
            else if t < 0.6 { drop = 1 }
            else { drop = 1 - Ease.spring(t - 0.6, damping: 0.45, frequency: 12) }
            let move = CGAffineTransform(translationX: shift.x * drop, y: shift.y * drop)
            backPart.draw(at: .zero)
            ctx.draw(cover, move, blend: .destinationOut)
            ctx.draw(frontPart, move)
        }
    }

    /// Pinned (a tab since 556, after the others had theirs; owner 2026-11-01: "the icon doesn't animate like the
    /// others"): the pin pulls up out of the board, leaning back, then jabs down into it, squashing a little as it hits
    /// with two short strokes flying out either side of its point, and wobbles still about its point.
    /// [marketplace-row] The Marketplace bag: picked up by its handle, it swings and settles back down.
    private static func bag(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        let handle = CGPoint(x: box.midX, y: box.minY)
        let lift = box.height * 0.22
        return frames(art, duration: 1.0, base: false) { t, ctx in
            let y: CGFloat, swing: CGFloat, squash: CGFloat
            if t < 0.2 {
                let q = Ease.smooth(t / 0.2)
                (y, swing, squash) = (-lift * q, 0, 0)
            } else if t < 0.62 {
                let u = t - 0.2
                (y, swing, squash) = (-lift, 0.32 * exp(-u / 0.16) * sin(2 * .pi * u / 0.21), 0)
            } else {
                let q = Ease.clamp((t - 0.62) / 0.14)
                (y, swing, squash) = (-lift * (1 - q * q), 0, Ease.bump(t, from: 0.74, length: 0.14))
            }
            // It swings from the handle and squashes onto its base.
            let point = squash > 0 ? CGPoint(x: box.midX, y: box.maxY) : CGPoint(x: handle.x, y: handle.y + y)
            art.drawSymbol(ctx, .about(point, scaleY: 1 - 0.12 * squash, rotation: swing).translatedBy(x: 0, y: y))
        }
    }

    private static func pin(_ art: SymbolArt) -> Motion? {
        guard let whole = art.probe(), let box = whole.bounds() else { return nil }
        let pixel = 1 / whole.scale
        // The point: the middle of the ink in the symbol's bottom row.
        let bottom = whole.runs(ink: true, atY: box.maxY - pixel / 2, from: box.minX, to: box.maxX - pixel)
        guard let first = bottom.first, let last = bottom.last else { return nil }
        let tip = CGPoint(x: (first.lowerBound + last.upperBound) / 2, y: box.maxY)
        let lift = box.height * 0.26, lean: CGFloat = -0.2, line = box.height * 0.09
        return frames(art, duration: 1.1, base: false) { t, ctx in
            let y: CGFloat, tilt: CGFloat, squash: CGFloat
            if t < 0.22 {
                let q = Ease.smooth(t / 0.22)
                (y, tilt, squash) = (-lift * q, lean * q, 0)
            } else if t < 0.34 {
                let q = Ease.clamp((t - 0.22) / 0.12)
                (y, tilt, squash) = (-lift * (1 - q * q), lean * (1 - q), 0)
            } else {
                let u = t - 0.34
                (y, tilt, squash) = (0, 0.16 * exp(-u / 0.2) * sin(2 * .pi * u / 0.2), Ease.bump(t, from: 0.33, length: 0.14))
            }
            let point = CGPoint(x: tip.x, y: tip.y + y)
            art.drawSymbol(ctx, .about(point, scaleY: 1 - 0.14 * squash, rotation: tilt).translatedBy(x: 0, y: y))
            guard t > 0.34, t < 0.62 else { return }
            // The tap: a short stroke each side of the point, flying out and shrinking.
            let u = (t - 0.34) / 0.28
            ctx.setLineWidth(line * (1 - 0.5 * u))
            ctx.setLineCap(.round)
            for side in [-1, 1] as [CGFloat] {
                let near = box.width * (0.16 + 0.2 * u), far = near + box.width * 0.22 * (1 - u)
                let angle: CGFloat = -0.35
                ctx.move(to: CGPoint(x: tip.x + side * cos(angle) * near, y: tip.y - line + sin(angle) * near))
                ctx.addLine(to: CGPoint(x: tip.x + side * cos(angle) * far, y: tip.y - line + sin(angle) * far))
            }
            ctx.strokePath()
        }
    }
}

private func circle(_ centre: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
}

private extension CGAffineTransform {
    /// About `point`: scaled (by `scaleY` up and down, when given), turned, then moved by `move`.
    static func about(_ point: CGPoint, scale: CGFloat = 1, scaleY: CGFloat? = nil, rotation: CGFloat = 0, move: CGPoint = .zero) -> CGAffineTransform {
        CGAffineTransform(translationX: point.x + move.x, y: point.y + move.y).rotated(by: rotation)
            .scaledBy(x: scale, y: scaleY ?? scale).translatedBy(x: -point.x, y: -point.y)
    }
}

private extension CGContext {
    /// `image` (one of the art's, in its points) drawn moved by `transform`.
    func draw(_ image: UIImage, _ transform: CGAffineTransform, blend: CGBlendMode = .normal) {
        saveGState()
        concatenate(transform)
        image.draw(at: .zero, blendMode: blend, alpha: 1)
        restoreGState()
    }

    /// From here on, paints only where `mask` (an `InkMap.clipMask`, `size` points) is white.
    func clip(to mask: CGImage, size: CGSize) {
        // Core Graphics lays the mask upward; flipped about its height for this flipped (UIKit) context.
        translateBy(x: 0, y: size.height)
        scaleBy(x: 1, y: -1)
        clip(to: CGRect(origin: .zero, size: size), mask: mask)
        scaleBy(x: 1, y: -1)
        translateBy(x: 0, y: -size.height)
    }
}

/// A tab symbol as the icon view draws it: a fine map of where it has ink, and frames of the whole with parts
/// redrawn, with room round it.
private struct SymbolArt {
    let symbol: UIImage
    /// Where the symbol sits in the icon's image, and that image's size (the Jobs tab's plain image has room around it).
    let origin: CGPoint
    let size: CGSize
    let scale: CGFloat
    /// Room the frames have round the image each way for a part moving past its edge (`room` of its longer side).
    let pad: CGFloat
    /// The symbol in black.
    let ink: UIImage

    init(symbol: UIImage, origin: CGPoint, size: CGSize, scale: CGFloat, room: CGFloat = 0.25) {
        self.symbol = symbol
        self.origin = origin
        self.size = size
        self.scale = scale
        pad = (max(size.width, size.height) * room).rounded()
        ink = symbol.withTintColor(.black)
    }

    /// The frames' size: the image and its room.
    var canvas: CGSize { CGSize(width: size.width + pad * 2, height: size.height + pad * 2) }

    /// Where the symbol has ink, at 12 pixels a point.
    func probe() -> InkMap? { InkMap(size: size, scale: 12) { _ in ink.draw(at: origin) } }

    /// Nothing, the image's size.
    func blank() -> UIImage { Self.blank(size, scale: scale) }

    static func blank(_ size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in }
    }
    func drawSymbol(_ ctx: CGContext, _ transform: CGAffineTransform) {
        ctx.saveGState()
        ctx.concatenate(transform)
        ink.draw(at: origin)
        ctx.restoreGState()
    }

    /// A frame: the whole symbol (or with `base` false, nothing), then `change` over it (filling in black, or
    /// clearing), in the image's points. Only its coverage counts (the overlay gives it the icon's colour), but it is
    /// kept in colour: Core Animation showed a grey-and-alpha image as solid, and an alpha-only context makes an
    /// image mask, which paints where it is clear.
    func frame(base: Bool = true, _ change: (CGContext) -> Void) -> CGImage? {
        let width = Int((canvas.width * scale).rounded(.up)), height = Int((canvas.height * scale).rounded(.up))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // UIKit's way up, in points, the image's corner `pad` in.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: pad, y: pad)
        ctx.interpolationQuality = .high
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.setStrokeColor(UIColor.black.cgColor)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        if base { ink.draw(at: origin) }
        change(ctx)
        return ctx.makeImage()
    }

    /// The symbol's own drawing (its soft edges) where `map` has ink, a little past it; the image's size. A part is
    /// erased from its place with the map grown by 6 (half a point), past the soft edge of the bar's stretched raster,
    /// or a grey outline stays behind.
    func part(_ map: InkMap) -> UIImage {
        let mask = shape(map.grown(by: 5))
        return render { _ in
            ink.draw(at: origin)
            mask.draw(at: .zero, blendMode: .destinationIn, alpha: 1)
        }
    }

    /// `map`'s ink in black at the frames' scale (drawn each frame, it is the size they are).
    func shape(_ map: InkMap) -> UIImage {
        let image = map.image()
        return render { _ in image?.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// The symbol's drawing within `rect`; the image's size.
    func region(_ rect: CGRect) -> UIImage {
        render { ctx in
            ctx.clip(to: rect)
            ink.draw(at: origin)
        }
    }

    /// An image the size of the symbol's, drawn by `draw` in black.
    func render(_ draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.interpolationQuality = .high
            context.cgContext.setFillColor(UIColor.black.cgColor)
            draw(context.cgContext)
        }
    }
}

/// An image's ink (alpha at least half) on a fine grid, read in points.
private struct InkMap {
    let width: Int
    let height: Int
    let scale: CGFloat
    private var inked: [Bool]

    init?(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        guard let image = UIGraphicsImageRenderer(size: size, format: format).image(actions: { draw($0.cgContext) }).cgImage else { return nil }
        width = image.width
        height = image.height
        self.scale = scale
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        inked = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] >= 128 }
    }

    private init(width: Int, height: Int, scale: CGFloat, inked: [Bool]) {
        self.width = width
        self.height = height
        self.scale = scale
        self.inked = inked
    }

    /// Square points of ink.
    var area: CGFloat { CGFloat(inked.lazy.filter { $0 }.count) / (scale * scale) }

    private func ink(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height && inked[y * width + x]
    }

    func ink(at point: CGPoint) -> Bool { ink(Int(point.x * scale), Int(point.y * scale)) }

    /// The box around every inked pixel, nil with none.
    func bounds() -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height { for x in 0..<width where ink(x, y) {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        return maxX < 0 ? nil : rect(minX, minY, maxX, maxY)
    }

    /// The box around the pixels that are (or, `ink` false, aren't) inked within `radius` of `centre`.
    func bounds(ink wanted: Bool, within radius: CGFloat, of centre: CGPoint) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        let c = (x: centre.x * scale, y: centre.y * scale), r = radius * scale
        for y in max(0, Int(c.y - r))..<min(height, Int(c.y + r) + 1) {
            for x in max(0, Int(c.x - r))..<min(width, Int(c.x + r) + 1) {
                let dx = CGFloat(x) + 0.5 - c.x, dy = CGFloat(y) + 0.5 - c.y
                guard dx * dx + dy * dy < r * r, ink(x, y) == wanted else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : rect(minX, minY, maxX, maxY)
    }

    /// From the leftmost to the rightmost inked pixel on the row at `y`.
    func width(atY y: CGFloat) -> CGFloat {
        let row = Int(y * scale)
        guard let first = (0..<width).first(where: { ink($0, row) }), let last = (0..<width).last(where: { ink($0, row) }) else { return 0 }
        return CGFloat(last - first + 1) / scale
    }

    /// The longest run of pixels that are (or aren't) inked on the row at `y`, between `from` and `to`.
    func run(ink wanted: Bool, atY y: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
        let row = Int(y * scale)
        var best = 0, current = 0
        for x in Int(from * scale)...Int(to * scale) {
            current = ink(x, row) == wanted ? current + 1 : 0
            best = max(best, current)
        }
        return CGFloat(best) / scale
    }

    /// The middle of the rightmost column with ink.
    func rightmost() -> CGPoint? {
        for x in stride(from: width - 1, through: 0, by: -1) {
            let rows = (0..<height).filter { ink(x, $0) }
            if let first = rows.first, let last = rows.last { return CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(first + last) / 2 + 0.5) / scale) }
        }
        return nil
    }

    /// The runs of pixels that are (or aren't) inked along the row at `y`, between `from` and `to`.
    func runs(ink wanted: Bool, atY y: CGFloat, from: CGFloat, to: CGFloat) -> [ClosedRange<CGFloat>] {
        let row = Int(y * scale)
        var found: [ClosedRange<CGFloat>] = [], start: Int?
        let last = Int(to * scale)
        for x in Int(from * scale)...last {
            let match = ink(x, row) == wanted
            if match, start == nil { start = x }
            if let begun = start, !match || x == last {
                found.append(CGFloat(begun) / scale...CGFloat(match ? x + 1 : x) / scale)
                start = nil
            }
        }
        return found
    }

    /// Down the column at `x` from `from` to `to`: each run of ink or of none, in order.
    func column(atX x: CGFloat, from: CGFloat, to: CGFloat) -> [(ink: Bool, from: CGFloat, to: CGFloat)] {
        let column = Int(x * scale)
        var found: [(ink: Bool, from: CGFloat, to: CGFloat)] = []
        for y in Int(from * scale)...Int(to * scale) {
            let here = ink(column, y)
            if let last = found.last, last.ink == here { found[found.count - 1].to = CGFloat(y + 1) / scale }
            else { found.append((here, CGFloat(y) / scale, CGFloat(y + 1) / scale)) }
        }
        return found
    }

    /// The pixels joined to `seed` that are (or aren't) inked, as a map of their own (them inked, nothing else); nil
    /// when the seed isn't such a pixel, or when there are more than `maxArea` square points of them (it ran out
    /// into something bigger).
    func piece(from seed: CGPoint, ink wanted: Bool, maxArea: CGFloat = .infinity) -> InkMap? {
        let start = (Int(seed.x * scale), Int(seed.y * scale))
        guard start.0 >= 0, start.1 >= 0, start.0 < width, start.1 < height, ink(start.0, start.1) == wanted else { return nil }
        let most = maxArea.isFinite ? Int(maxArea * scale * scale) : Int.max
        var mine = [Bool](repeating: false, count: width * height), count = 1, stack = [start]
        mine[start.1 * width + start.0] = true
        while let (x, y) = stack.popLast() {
            for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
            where nx >= 0 && ny >= 0 && nx < width && ny < height && !mine[ny * width + nx] && ink(nx, ny) == wanted {
                mine[ny * width + nx] = true
                count += 1
                if count > most { return nil }
                stack.append((nx, ny))
            }
        }
        return InkMap(width: width, height: height, scale: scale, inked: mine)
    }

    /// Every piece of pixels that are (or aren't) inked, joined side to side, each as a map of its own; none smaller
    /// than `minArea` square points (specks of a soft edge).
    func pieces(ink wanted: Bool, minArea: CGFloat = 0) -> [InkMap] {
        var taken = [Bool](repeating: false, count: inked.count), found: [InkMap] = []
        let least = Int(minArea * scale * scale)
        for start in inked.indices where inked[start] == wanted && !taken[start] {
            var mine = [Bool](repeating: false, count: inked.count), stack = [start], count = 1
            taken[start] = true
            mine[start] = true
            while let index = stack.popLast() {
                let x = index % width
                for next in [x > 0 ? index - 1 : -1, x < width - 1 ? index + 1 : -1, index - width, index + width]
                where next >= 0 && next < inked.count && !taken[next] && inked[next] == wanted {
                    taken[next] = true
                    mine[next] = true
                    count += 1
                    stack.append(next)
                }
            }
            if count >= least { found.append(InkMap(width: width, height: height, scale: scale, inked: mine)) }
        }
        return found
    }

    /// Inked within `r` pixels (a square round each) of an inked pixel.
    func grown(by r: Int) -> InkMap {
        guard r > 0 else { return self }
        var across = [Bool](repeating: false, count: inked.count), out = across
        var sums = [Int](repeating: 0, count: max(width, height) + 1)
        for y in 0..<height {
            for x in 0..<width { sums[x + 1] = sums[x] + (inked[y * width + x] ? 1 : 0) }
            for x in 0..<width { across[y * width + x] = sums[min(width, x + r + 1)] - sums[max(0, x - r)] > 0 }
        }
        for x in 0..<width {
            for y in 0..<height { sums[y + 1] = sums[y] + (across[y * width + x] ? 1 : 0) }
            for y in 0..<height { out[y * width + x] = sums[min(height, y + r + 1)] - sums[max(0, y - r)] > 0 }
        }
        return InkMap(width: width, height: height, scale: scale, inked: out)
    }

    /// Inked only where every pixel within `r` (a square round it) is.
    func shrunk(by r: Int) -> InkMap { inverted().grown(by: r).inverted() }

    func inverted() -> InkMap { InkMap(width: width, height: height, scale: scale, inked: inked.map { !$0 }) }

    func union(_ other: InkMap) -> InkMap { InkMap(width: width, height: height, scale: scale, inked: zip(inked, other.inked).map { $0 || $1 }) }

    func intersecting(_ other: InkMap) -> InkMap { InkMap(width: width, height: height, scale: scale, inked: zip(inked, other.inked).map { $0 && $1 }) }

    func subtracting(_ other: InkMap) -> InkMap { InkMap(width: width, height: height, scale: scale, inked: zip(inked, other.inked).map { $0 && !$1 }) }

    /// Only the inked pixels whose middles pass `keep`.
    func within(_ keep: (CGPoint) -> Bool) -> InkMap {
        var kept = inked
        for y in 0..<height { for x in 0..<width where kept[y * width + x] {
            if !keep(CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)) { kept[y * width + x] = false }
        } }
        return InkMap(width: width, height: height, scale: scale, inked: kept)
    }

    /// Black where inked, clear elsewhere, at the map's own fine scale.
    func image() -> UIImage? {
        var bytes = [UInt8](repeating: 0, count: inked.count * 4)
        for index in inked.indices where inked[index] { bytes[index * 4 + 3] = 255 }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }

    /// White where inked, black elsewhere: a mask to clip to.
    func clipMask() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(inked.map { $0 ? UInt8(255) : 0 }) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    private func rect(_ minX: Int, _ minY: Int, _ maxX: Int, _ maxY: Int) -> CGRect {
        CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}

/// The curves the motions move on, `t` in seconds.
private enum Ease {
    static func clamp(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }

    static func smooth(_ x: CGFloat) -> CGFloat {
        let x = clamp(x)
        return x * x * (3 - 2 * x)
    }

    /// Up past 1 a touch and back (a dot popping in).
    static func backOut(_ x: CGFloat) -> CGFloat {
        let c: CGFloat = 1.6, u = x - 1
        return 1 + (c + 1) * u * u * u + c * u * u
    }

    /// 0 → 1 → 0 over `length` seconds from `from`.
    static func bump(_ t: CGFloat, from: CGFloat, length: CGFloat) -> CGFloat {
        let u = (t - from) / length
        guard u > 0, u < 1 else { return 0 }
        return sin(.pi * u)
    }

    /// A spring let go at 0 towards 1, still at the start: `damping` below 1 carries it past 1 and back.
    static func spring(_ t: CGFloat, damping: CGFloat, frequency: CGFloat) -> CGFloat {
        guard t > 0 else { return 0 }
        let ringing = frequency * sqrt(1 - damping * damping)
        return 1 - exp(-damping * frequency * t) * (cos(ringing * t) + damping * frequency / ringing * sin(ringing * t))
    }
}
