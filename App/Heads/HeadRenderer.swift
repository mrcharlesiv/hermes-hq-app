// Draws a Shapes head layout with Core Graphics, and caches the pictures so a scrolling list never redraws one.

import CoreGraphics
import UIKit

nonisolated enum HeadRenderer {
    /// Which layers of the picture to draw: everything, everything but the eyes, or the eyes alone (motion moves
    /// the eye layer over the body without redrawing either, as the web's `eyeLayers`).
    enum Parts: String, Sendable { case all, body, face, ground, moving }

    /// Draws `layout` into `ctx`, filling a `side`×`side` square at the context's origin (y down).
    static func draw(_ layout: ShapeHeadLayout, in ctx: CGContext, side: CGFloat, parts: Parts = .all) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.scaleBy(x: side / 1024, y: side / 1024)
        if let board = layout.board {
            let panel = SVGPathData.path(HeadGeometry.panel)
            if parts != .face {
                ctx.addPath(SVGPathData.path(HeadGeometry.frame))
                ctx.setFillColor(color(board.frame))
                ctx.fillPath()
                ctx.addPath(panel)
                ctx.setFillColor(color(board.panel))
                ctx.fillPath()
            }
            ctx.addPath(panel)
            ctx.clip()
        }
        if let p = layout.placement {
            ctx.concatenate(CGAffineTransform(a: p.k, b: 0, c: 0, d: p.k, tx: p.tx, ty: p.ty))
        }
        if parts != .face {
            let outline = outlinePath(layout.outline)
            ctx.addPath(outline)
            ctx.setFillColor(color(layout.fill))
            ctx.fillPath()
            if let rim = layout.rim {
                ctx.addPath(outline)
                ctx.setStrokeColor(color(rim))
                ctx.setLineWidth(14)
                ctx.strokePath()
            }
            for mark in layout.under { draw(mark, in: ctx) }
        }
        if parts != .body {
            for mark in layout.face { draw(mark, in: ctx) }
        }
    }

    static func outlinePath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for segment in HeadGeometry.spline(points).segments {
            path.addCurve(to: segment.to, control1: segment.c1, control2: segment.c2)
        }
        path.closeSubpath()
        return path
    }

    static func draw(_ mark: HeadMark, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        for step in mark.transform {
            switch step {
            case .translate(let x, let y): ctx.translateBy(x: x, y: y)
            case .scale(let k): ctx.scaleBy(x: k, y: k)
            case .rotate(let degrees, let cx, let cy):
                ctx.translateBy(x: cx, y: cy)
                ctx.rotate(by: degrees * .pi / 180)
                ctx.translateBy(x: -cx, y: -cy)
            }
        }
        let path: CGPath
        switch mark.primitive {
        case .path(let d): path = SVGPathData.path(d)
        case .rect(let x, let y, let w, let h, let rx):
            let r = max(0, min(rx, w / 2, h / 2))
            path = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        case .circle(let cx, let cy, let r):
            path = CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
        case .ellipse(let cx, let cy, let rx, let ry):
            path = CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry), transform: nil)
        }
        let style = mark.style
        if let fill = style.fill {
            ctx.addPath(path)
            ctx.setFillColor(color(fill, alpha: style.fillOpacity * style.opacity))
            ctx.fillPath()
        }
        if let stroke = style.stroke, style.strokeWidth > 0 {
            ctx.addPath(path)
            ctx.setStrokeColor(color(stroke, alpha: style.strokeOpacity * style.opacity))
            ctx.setLineWidth(style.strokeWidth)
            ctx.setLineCap(style.roundCap ? .round : .butt)
            ctx.setLineJoin(style.roundJoin ? .round : .miter)
            ctx.strokePath()
        }
    }

    static func color(_ rgb: HeadRGB, alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }

    /// A bitmap of the head, `side` points square at `scale` pixels per point.
    static func makeImage(_ layout: ShapeHeadLayout, side: CGFloat, scale: CGFloat, parts: Parts = .all) -> CGImage? {
        let pixels = max(1, Int((side * scale).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        draw(layout, in: ctx, side: CGFloat(pixels), parts: parts)
        return ctx.makeImage()
    }
}

nonisolated extension HeadRenderer {
    /// Any head as a bitmap, `side` points at `scale`: a Shapes layout, a dot-matrix head, or a themed head's markup,
    /// eyes only (`Head.plain`). Any thread.
    static func picture(_ head: Head, side: CGFloat, scale: CGFloat, dark: Bool, state: HeadState = .idle,
                        parts: Parts = .all) -> CGImage? {
        let head = head.plain
        if let record = head.themed { return makeImage(record, side: side, scale: scale, state: state, parts: parts) }
        if head.theme == .matrix {
            // Always the whole head: it blinks and glances by whole pictures (`HeadImageCache.matrixFrame`), not layers.
            let design = MatrixDesign(head)
            return MatrixHeadRenderer.makeImage(design, pose: state == .thinking ? .thinking(design) : .rest, side: side, scale: scale,
                                                dark: dark)
        }
        let layout = HeadGeometry.layout(head, state: state, compact: side < 64, darkPage: dark)
        return makeImage(layout, side: side, scale: scale, parts: parts)
    }

    /// A Robot, Dots, Orb, Pixel or Emoji head as a bitmap: ThemeHeadSVG's markup drawn by SVGMini. A small picture
    /// (< 64 pt) is the compact drawing, as the web's list rows.
    static func makeImage(_ record: HeadRecord, side: CGFloat, scale: CGFloat, state: HeadState, parts: Parts = .all) -> CGImage? {
        let svg = ThemeHeadSVG.svg(record, state: state == .idle ? nil : state, compact: side < 64, plain: true)
        guard let root = SVGMini.parse(svg) else { return nil }
        let pixels = max(1, Int((side * scale).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        let mode: SVGMini.Parts = switch parts {
        case .all: .all
        case .body: .body
        case .face: .face
        case .ground: .ground
        case .moving: .moving
        }
        SVGMini.draw(root, in: ctx, side: CGFloat(pixels), pixels: CGSize(width: pixels, height: pixels), parts: mode)
        return ctx.makeImage()
    }
}

/// A picture handed back from the drawing thread (a `CGImage` is immutable once made).
private nonisolated struct RenderedPicture: @unchecked Sendable {
    let image: CGImage?
}

/// One picture per (head, size, scale, appearance, state, parts), shared by every row that shows it.
final class HeadImageCache {
    static let shared = HeadImageCache()
    private let cache = NSCache<NSString, UIImage>()
    /// [moods] Each acting face's light pictures and masks (its faces are kept in `cache` as poses).
    private let acts: NSCache<NSString, MatrixActPictures.Box> = {
        let acts = NSCache<NSString, MatrixActPictures.Box>()
        acts.totalCostLimit = 12 << 20
        return acts
    }()
    private init() {
        cache.countLimit = 600
        // Bounded by bytes too: a 72 pt picture at 3× is ~187 KB, so 600 of them would hold ~100 MB. [moods] A face acting
        // out its bot's work holds up to eight faces more.
        cache.totalCostLimit = 32 << 20
    }

    private func key(_ head: Head, _ side: CGFloat, _ scale: CGFloat, _ dark: Bool, _ state: HeadState, _ parts: HeadRenderer.Parts) -> NSString {
        // A themed head looks the same on a dark page (only a black Shapes head follows the page).
        let dark = head.themed == nil && dark
        return "\(head.cacheKey)|\(Int((side * 100).rounded()))|\(scale)|\(dark ? "d" : "l")|\(state.rawValue)|\(parts.rawValue)" as NSString
    }

    /// A small picture (a list row, a header, < 64 pt) draws bolder eyes (`compact`, spec 02 §10.4 item 5).
    func image(for head: Head, side: CGFloat, scale: CGFloat, dark: Bool, state: HeadState = .idle,
               parts: HeadRenderer.Parts = .all) -> UIImage {
        let key = key(head, side, scale, dark, state, parts)
        if let hit = cache.object(forKey: key) { return hit }
        let dark = head.themed == nil && dark
        guard let cg = HeadRenderer.picture(head, side: side, scale: scale, dark: dark, state: state, parts: parts) else { return UIImage() }
        return store(cg, scale: scale, key: key)
    }

    private func store(_ cg: CGImage, scale: CGFloat, key: NSString) -> UIImage {
        let image = UIImage(cgImage: cg, scale: scale, orientation: .up)
        cache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
        return image
    }

    /// A dot-matrix head at one pose (a blink, a glance, a step of reading), drawn once and kept like any picture.
    /// [updates] `mark`: drawn as an update mark (`MatrixHead.coarseBelow`), kept apart from the same head drawn plain.
    func matrixFrame(for head: Head, pose: MatrixPose, side: CGFloat, scale: CGFloat, dark: Bool, mark: Bool = false) -> UIImage {
        let key = Self.matrixKey(head, side, scale, dark, mark, "pose " + pose.key)
        if let hit = cache.object(forKey: key) { return hit }
        guard let cg = MatrixHeadRenderer.makeImage(MatrixDesign(head), pose: pose, side: side, scale: scale, mark: mark, dark: dark)
        else { return UIImage() }
        return store(cg, scale: scale, key: key)
    }

    private static func matrixKey(_ head: Head, _ side: CGFloat, _ scale: CGFloat, _ dark: Bool, _ mark: Bool, _ what: String) -> NSString {
        "\(head.cacheKey)|\(Int((side * 100).rounded()))|\(scale)|\(dark ? "d" : "l")|\(mark ? "m|" : "")\(what)" as NSString
    }

    /// [moods] What a dot-matrix face needs to act out `mood`: each face of the act, the lit picture its light shows
    /// through and the effect's own masks, from the cache, or nil while any is still to be drawn (`actPictures`).
    func cachedActPictures(for head: Head, mood: BotMood, side: CGFloat, scale: CGFloat, dark: Bool,
                           mark: Bool = false) -> MatrixActPictures? {
        guard var pictures = acts.object(forKey: Self.matrixKey(head, side, scale, dark, mark, "act " + mood.rawValue))?.pictures
        else { return nil }
        for pose in MatrixAct.make(mood, design: MatrixDesign(head)).poses {
            guard let cg = cache.object(forKey: Self.matrixKey(head, side, scale, dark, mark, "pose " + pose.key))?.cgImage else { return nil }
            pictures.faces[pose] = cg
        }
        return pictures
    }

    /// [moods] `cachedActPictures`, drawing what's missing off the main thread (an act is up to eight faces and three
    /// light pictures: a few milliseconds a head, too long for a list's frame).
    func actPictures(for head: Head, mood: BotMood, side: CGFloat, scale: CGFloat, dark: Bool, mark: Bool = false) async -> MatrixActPictures {
        if let hit = cachedActPictures(for: head, mood: mood, side: side, scale: scale, dark: dark, mark: mark) { return hit }
        let drawn = await Task.detached(priority: .userInitiated) {
            MatrixActPictures.draw(MatrixDesign(head), mood: mood, side: side, scale: scale, mark: mark, dark: dark)
        }.value
        for (pose, cg) in drawn.faces { _ = store(cg, scale: scale, key: Self.matrixKey(head, side, scale, dark, mark, "pose " + pose.key)) }
        var light = drawn
        light.faces = [:]
        acts.setObject(MatrixActPictures.Box(light), forKey: Self.matrixKey(head, side, scale, dark, mark, "act " + mood.rawValue),
                       cost: light.cost)
        return drawn
    }

    /// The picture if it's already drawn.
    func cachedImage(for head: Head, side: CGFloat, scale: CGFloat, dark: Bool, state: HeadState = .idle,
                     parts: HeadRenderer.Parts = .all) -> UIImage? {
        cache.object(forKey: key(head, side, scale, dark, state, parts))
    }

    /// Draws several parts of one head off the main thread and caches them (a themed head is several times the work of
    /// a Shapes one, so a list of them would stutter if drawn in place).
    func images(for head: Head, side: CGFloat, scale: CGFloat, dark: Bool, state: HeadState,
                parts: [HeadRenderer.Parts]) async -> [UIImage] {
        let dark = head.themed == nil && dark
        let drawn = await Task.detached(priority: .userInitiated) { () -> [RenderedPicture] in
            parts.map { RenderedPicture(image: HeadRenderer.picture(head, side: side, scale: scale, dark: dark, state: state, parts: $0)) }
        }.value
        return zip(parts, drawn).map { part, picture in
            guard let cg = picture.image else { return UIImage() }
            return store(cg, scale: scale, key: key(head, side, scale, dark, state, part))
        }
    }

    private var boxes: [String: CGRect] = [:]

    /// Where the eyes are in an eyes-only picture, as fractions of the head: the middle of its opaque pixels, measured
    /// once per head (`eyeCentre`). The middle-ish default when there's nothing to measure.
    func eyeCentre(of eyes: UIImage, key: String) -> CGPoint {
        let box = eyeBox(of: eyes, key: key)
        return CGPoint(x: box.midX, y: box.midY)
    }

    /// The box round an eyes-only picture's opaque pixels, as fractions of the head (to the nearest 64th); an empty box
    /// at the middle-ish default when there's nothing to measure.
    func eyeBox(of eyes: UIImage, key: String) -> CGRect {
        if let hit = boxes[key] { return hit }
        var box = CGRect(x: 0.5, y: 0.45, width: 0, height: 0)
        if let cg = eyes.cgImage {
            let side = 64
            if let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue), let data = ctx.data {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
                let pixels = data.bindMemory(to: UInt8.self, capacity: side * side)
                var minX = side, maxX = -1, minY = side, maxY = -1
                for row in 0..<side {
                    for col in 0..<side where pixels[row * side + col] > 24 {
                        minX = min(minX, col); maxX = max(maxX, col); minY = min(minY, row); maxY = max(maxY, row)
                    }
                }
                // Row 0 of the buffer is the picture's top.
                let unit = 1 / Double(side)
                if maxX >= 0 { box = CGRect(x: Double(minX) * unit, y: Double(minY) * unit, width: Double(maxX + 1 - minX) * unit, height: Double(maxY + 1 - minY) * unit) }
            }
        }
        if boxes.count > 400 { boxes.removeAll() }
        boxes[key] = box
        return box
    }
}
