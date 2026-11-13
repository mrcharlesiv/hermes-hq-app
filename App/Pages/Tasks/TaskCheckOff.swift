// [task-check-off] Ticking a task off (owner 2026-11-12: "a really cool animation of it going away"; then "go straight
// to the fading away part … skip the stuff around the radio button"). The circle fills and the row turns to dust at
// once: the wind takes it up and to the right while the list closes under it. Under Reduce Motion it doesn't play:
// the circle fills, the name is struck, the row moves.

import UIKit

/// The beats' lengths, shared by the row and the list.
enum TaskCheckOff {
    /// The ticked row is drawn (circle filled, name struck) before its picture is taken: a few frames.
    static let tick: TimeInterval = 0.07
    /// The dust's front crossing the row; the list closes behind it.
    static let sweep: TimeInterval = 0.45
    /// How long the last grains stay in the air after the front has passed.
    static let drift: TimeInterval = 0.95
}

// MARK: - The dust

/// Turns a view's picture to dust: every grain of it goes to one of a few sheets, the sheets nearer the leading edge
/// let go first, and each drifts up and away on its own curve as it fades. Until a sheet lets go the sheets together
/// are the picture exactly, so the hand-over from the real view can't be seen.
enum TaskDust {
    private static let sheets = 28

    /// Plays over `source` (which the caller empties), in `host`'s coordinates. False when there was nothing to draw.
    @discardableResult
    static func play(over source: UIView, in host: UIView) -> Bool {
        let bounds = source.bounds
        guard source.window != nil, bounds.width >= 1, bounds.height >= 1 else { return false }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = min(2, source.traitCollection.displayScale)
        let picture = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            source.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        // A grain is a point across: finer reads as a fade, coarser as tiles.
        guard let whole = picture.cgImage, let parts = split(whole, grain: max(1, Int(format.scale))) else { return false }

        let cloud = UIView(frame: source.convert(bounds, to: host))
        cloud.isUserInteractionEnabled = false
        cloud.layer.zPosition = 50
        host.addSubview(cloud)

        let now = CACurrentMediaTime()
        let leadingToTrailing = source.effectiveUserInterfaceLayoutDirection == .leftToRight
        let wind: CGFloat = leadingToTrailing ? 1 : -1
        var rng = SystemRandomNumberGenerator()
        for (index, part) in parts.enumerated() {
            let sheet = CALayer()
            sheet.frame = cloud.bounds
            sheet.contents = part
            sheet.contentsGravity = .resize
            sheet.actions = ["position": NSNull(), "opacity": NSNull(), "transform": NSNull()]
            cloud.layer.addSublayer(sheet)

            let start = sheet.position
            let reach = CGPoint(x: wind * CGFloat.random(in: 50...150, using: &rng), y: -CGFloat.random(in: 24...90, using: &rng))
            let path = CGMutablePath()
            path.move(to: start)
            // The wind lifts first, then carries: the bend sits over the start.
            path.addQuadCurve(to: CGPoint(x: start.x + reach.x, y: start.y + reach.y),
                              control: CGPoint(x: start.x + reach.x * CGFloat.random(in: 0.05...0.35, using: &rng),
                                               y: start.y + reach.y * CGFloat.random(in: 0.7...1.15, using: &rng)))
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.calculationMode = .paced
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = CGFloat.random(in: -0.09...0.09, using: &rng)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = CGFloat.random(in: 1.0...1.08, using: &rng)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0.6, 0]
            fade.keyTimes = [0, 0.35, 0.7, 1]

            let flight = CAAnimationGroup()
            flight.animations = [move, turn, grow, fade]
            flight.duration = TaskCheckOff.drift * Double.random(in: 0.72...1, using: &rng)
            flight.beginTime = now + TaskCheckOff.sweep * Double(index) / Double(max(1, parts.count - 1))
            flight.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.3, 0.5, 1)   // taken at once, then hanging
            flight.fillMode = .both
            flight.isRemovedOnCompletion = false
            sheet.add(flight, forKey: "dust")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + TaskCheckOff.sweep + TaskCheckOff.drift + 0.05) { cloud.removeFromSuperview() }
        return true
    }

    /// The picture as `sheets` pictures of the same size, each grain (a square `grain` pixels across) in exactly one
    /// of them: mostly by how far along the row it is, with enough chance that the front is ragged.
    private static func split(_ image: CGImage, grain: Int) -> [CGImage]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        func canvas() -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info)
        }
        guard let source = canvas() else { return nil }
        source.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let from = source.data?.assumingMemoryBound(to: UInt32.self) else { return nil }
        var contexts: [CGContext] = []
        var pixels: [UnsafeMutablePointer<UInt32>] = []
        for _ in 0..<sheets {
            guard let context = canvas(), let data = context.data else { return nil }
            memset(data, 0, width * height * 4)
            contexts.append(context)
            pixels.append(data.assumingMemoryBound(to: UInt32.self))
        }
        var seed = UInt64.random(in: 1...UInt64.max)
        let spread = 0.26   // how much of a grain's sheet is chance
        for top in stride(from: 0, to: height, by: grain) {
            for left in stride(from: 0, to: width, by: grain) {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17   // xorshift: one draw a grain
                let chance = Double(seed >> 11) / Double(1 << 53)
                let along = Double(left) / Double(width)
                let to = pixels[min(sheets - 1, Int((along * (1 - spread) + chance * spread) * Double(sheets)))]
                for y in top..<min(height, top + grain) {
                    let row = y * width
                    for x in left..<min(width, left + grain) where from[row + x] != 0 { to[row + x] = from[row + x] }
                }
            }
        }
        let made = contexts.compactMap { $0.makeImage() }
        return made.count == sheets ? made : nil
    }
}
