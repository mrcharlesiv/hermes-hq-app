// Small authoring helpers shared by the drawing sets.

import CoreGraphics
import Foundation

nonisolated enum DoodleKit {
    /// A point `r` from the centre at `deg` degrees (0 is +x, turning clockwise on screen since y runs down).
    @inline(__always) static func polar(_ cx: Double, _ cy: Double, _ r: Double, _ deg: Double) -> (Double, Double) {
        (cx + r * cos(deg * .pi / 180), cy + r * sin(deg * .pi / 180))
    }

    static func arcPoints(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ from: Double, _ to: Double, count: Int = 8) -> [(Double, Double)] {
        (0...count).map { i in
            let a = (from + (to - from) * Double(i) / Double(count)) * .pi / 180
            return (cx + rx * cos(a), cy + ry * sin(a))
        }
    }

    /// A curve along part of an ellipse.
    static func arc(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ from: Double, _ to: Double, count: Int = 8) -> DoodlePath {
        .spline(arcPoints(cx, cy, rx, ry, from, to, count: count))
    }

    /// A regular polygon, corners sharp.
    static func gon(_ cx: Double, _ cy: Double, _ r: Double, sides: Int, rot: Double = -90) -> DoodlePath {
        .poly((0..<sides).map { polar(cx, cy, r, rot + 360 * Double($0) / Double(sides)) }, closed: true)
    }

    /// A scalloped puff, for pom-poms, foam, clouds and blossoms. `n` bumps round an ellipse.
    static func puff(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, n: Int, depth: Double = 0.16) -> DoodlePath {
        var nodes: [DoodlePath.Node] = []
        for i in 0..<n {
            let a0 = 2 * .pi * Double(i) / Double(n), a1 = 2 * .pi * (Double(i) + 0.5) / Double(n)
            nodes.append(.init(x: cx + rx * cos(a0), y: cy + ry * sin(a0), corner: true))
            nodes.append(.init(x: cx + rx * (1 + depth) * cos(a1), y: cy + ry * (1 + depth) * sin(a1), corner: false))
        }
        return DoodlePath(nodes: nodes, closed: true)
    }

    /// A pointed petal or leaf from `a` to `b`, `belly` wide.
    static func leaf(_ a: (Double, Double), _ b: (Double, Double), belly: Double, bias: Double = 0.5) -> DoodlePath {
        let dx = b.0 - a.0, dy = b.1 - a.1, l = max(1e-6, hypot(dx, dy))
        let nx = -dy / l * belly / 2, ny = dx / l * belly / 2
        let mx = a.0 + dx * bias, my = a.1 + dy * bias
        return DoodlePath(nodes: [.init(x: a.0, y: a.1, corner: true), .init(x: mx + nx, y: my + ny, corner: false),
                                  .init(x: b.0, y: b.1, corner: true), .init(x: mx - nx, y: my - ny, corner: false)], closed: true)
    }
}

nonisolated extension DoodleGlyph {
    /// A criss-cross of straight strokes clipped to an ellipse: racket strings, snowshoe webbing, a net.
    mutating func strings(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, gapX: Double, gapY: Double, w: Double = 0.45) {
        var x = cx - rx + gapX
        while x < cx + rx - gapX * 0.4 {
            let t = (x - cx) / rx
            let h = ry * (1 - t * t).squareRoot()
            line(.poly([(x, cy - h), (x, cy + h)]), w)
            x += gapX
        }
        var y = cy - ry + gapY
        while y < cy + ry - gapY * 0.4 {
            let t = (y - cy) / ry
            let h = rx * (1 - t * t).squareRoot()
            line(.poly([(cx - h, y), (cx + h, y)]), w)
            y += gapY
        }
    }

    /// Dimples or speckles scattered in a box, seeded, each a tiny blot.
    mutating func speckle(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, n: Int, r: Double = 0.8, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<n { blot(.circle(rng.next(x0, x1), rng.next(y0, y1), r * rng.next(0.7, 1.15))) }
    }
}

nonisolated extension DoodleKit {
    /// A crescent with sharp tips, opening to the right before rotation. `bite` is how far the inner circle sits towards the opening.
    static func crescent(_ cx: Double, _ cy: Double, _ r: Double, bite: Double = 0.46, rot: Double = 0) -> DoodlePath {
        let tipDeg = 62.0
        let tipA = polar(cx, cy, r, tipDeg)
        let ic = (cx + r * bite, cy)
        let ir = hypot(tipA.0 - ic.0, tipA.1 - ic.1)
        var nodes: [DoodlePath.Node] = []
        // Outer, from lower tip round the back to the upper tip.
        let outerSteps = 10
        for i in 0...outerSteps {
            let a = tipDeg + (360 - 2 * tipDeg) * Double(i) / Double(outerSteps)
            let p = polar(cx, cy, r, a)
            nodes.append(.init(x: p.0, y: p.1, corner: i == 0 || i == outerSteps))
        }
        // Inner, back from upper tip to lower tip.
        let u = atan2(-(tipA.1 - cy), tipA.0 - ic.0) * 180 / .pi
        let l = atan2(tipA.1 - cy, tipA.0 - ic.0) * 180 / .pi
        let from = (u + 360).truncatingRemainder(dividingBy: 360), to = l
        let innerSteps = 8
        for i in 1..<innerSteps {
            let a = from + (to - from) * Double(i) / Double(innerSteps)
            let p = polar(ic.0, ic.1, ir, a)
            nodes.append(.init(x: p.0, y: p.1, corner: false))
        }
        let path = DoodlePath(nodes: nodes, closed: true)
        return rot == 0 ? path : path.rotated(rot, about: (cx, cy))
    }
}
