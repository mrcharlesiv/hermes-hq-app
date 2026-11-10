// The small marks that go in the gaps.

import CoreGraphics
import Foundation

nonisolated enum DoodleFillers {
    /// A hand's five-point star.
    static func starPath(_ cx: Double, _ cy: Double, _ r: Double, inner: Double = 0.44) -> DoodlePath {
        var pts: [(Double, Double)] = []
        for i in 0..<10 {
            let a = Double(i) / 10 * 2 * .pi - .pi / 2
            let k = i % 2 == 0 ? r : r * inner
            pts.append((cx + k * cos(a), cy + k * sin(a)))
        }
        return .poly(pts, closed: true)
    }

    /// A four-point sparkle with curved sides.
    static func sparklePath(_ cx: Double, _ cy: Double, _ r: Double, _ k: Double = 0.16) -> DoodlePath {
        let n = r * k
        return DoodlePath(nodes: [
            .init(x: cx, y: cy - r, corner: true), .init(x: cx + n, y: cy - n, corner: false),
            .init(x: cx + r, y: cy, corner: true), .init(x: cx + n, y: cy + n, corner: false),
            .init(x: cx, y: cy + r, corner: true), .init(x: cx - n, y: cy + n, corner: false),
            .init(x: cx - r, y: cy, corner: true), .init(x: cx - n, y: cy - n, corner: false),
        ], closed: true)
    }

    static func heartPath(_ cx: Double, _ cy: Double, _ r: Double) -> DoodlePath {
        let p: DoodlePath = "^0,-0.45 0.34,-0.95 0.86,-0.92 1.06,-0.42 0.72,0.2 ^0,0.98 -0.72,0.2 -1.06,-0.42 -0.86,-0.92 -0.34,-0.95 z"
        return p.scaled(r).moved(cx, cy)
    }

    static func dot() -> DoodleGlyph {
        var g = DoodleGlyph("dot", 0.007, 0.013, tilt: 0)
        g.blot(.circle(0, 0, 10))
        return g
    }

    /// A little dab of bare paper with a ring round it.
    static func pearl() -> DoodleGlyph {
        var g = DoodleGlyph("pearl", 0.014, 0.026, tilt: 0)
        g.weight = 0.2
        g.shape(-1, .circle(0, 0, 10), 0.7)
        return g
    }

    static func ring() -> DoodleGlyph {
        var g = DoodleGlyph("ring", 0.012, 0.022, tilt: 0)
        g.weight = 0.15
        g.line(.circle(0, 0, 10), 0.8)
        return g
    }

    static func plus() -> DoodleGlyph {
        var g = DoodleGlyph("plus", 0.018, 0.034, tilt: 40)
        g.weight = 0.6
        g.line("^10,0 ^10,20", 0.85)
        g.line("^0,10 ^20,10", 0.85)
        return g
    }

    static func cross() -> DoodleGlyph {
        var g = DoodleGlyph("cross", 0.016, 0.03, tilt: 20)
        g.weight = 0.6
        g.line("^0,0 ^16,16", 0.85)
        g.line("^16,0 ^0,16", 0.85)
        return g
    }

    static func sparkle() -> DoodleGlyph {
        var g = DoodleGlyph("sparkle", 0.024, 0.065, tilt: 16)
        g.shape(-1, sparklePath(0, 0, 20), 0.8)
        return g
    }

    static func sparkleSolid() -> DoodleGlyph {
        var g = DoodleGlyph("sparkleSolid", 0.016, 0.04, tilt: 16)
        g.blot(sparklePath(0, 0, 20))
        return g
    }

    static func star() -> DoodleGlyph {
        var g = DoodleGlyph("star", 0.024, 0.07, tilt: 40)
        g.shape(1, starPath(0, 0, 20), 0.8)
        return g
    }

    static func squiggle() -> DoodleGlyph {
        var g = DoodleGlyph("squiggle", 0.03, 0.08, tilt: 60)
        g.line("0,0 6,-5 12,0 18,5 24,0 30,-5 36,0", 0.85)
        return g
    }

    static func dashes() -> DoodleGlyph {
        var g = DoodleGlyph("dashes", 0.02, 0.05, tilt: 60)
        g.line("^0,0 ^3,10", 0.85)
        g.line("^9,-3 ^12,9", 0.85)
        g.line("^18,0 ^21,10", 0.85)
        return g
    }

    static func triDots() -> DoodleGlyph {
        var g = DoodleGlyph("triDots", 0.018, 0.036, tilt: 60)
        g.blot(.circle(0, 0, 2.8))
        g.blot(.circle(12, -3, 2.1))
        g.blot(.circle(7, 9, 2.4))
        return g
    }

    static func spiral() -> DoodleGlyph {
        var g = DoodleGlyph("spiral", 0.03, 0.08, tilt: 90)
        var p: [(Double, Double)] = []
        for i in 0..<26 {
            let a = Double(i) * 0.62, r = 1.5 + Double(i) * 0.68
            p.append((r * cos(a), r * sin(a)))
        }
        g.line(.spline(p), 0.8)
        return g
    }

    static func common() -> [DoodleGlyph] {
        [dot(), pearl(), ring(), plus(), cross(), sparkle(), sparkleSolid(), star(), squiggle(), dashes(), triDots()]
    }

    static func leaf() -> DoodleGlyph {
        var g = DoodleGlyph("leaf", 0.03, 0.08, tilt: 80)
        g.shape(0, "^0,20 6,8 18,2 ^32,0 28,12 16,20 z", 0.85)
        g.line("^-5,25 ^24,6", 0.55)
        g.line("^10,14 ^6,8", 0.4)
        g.line("^16,10 ^20,15", 0.4)
        return g
    }

    /// A small stone: no two the same way up.
    static func pebble() -> DoodleGlyph {
        var g = DoodleGlyph("pebble", 0.016, 0.034, tilt: 90)
        g.weight = 0.5
        g.shape(1, "2,8 8,2 18,1 26,7 25,15 15,19 5,17 z", 0.8)
        return g
    }

    /// Three berries on a twig.
    static func berries() -> DoodleGlyph {
        var g = DoodleGlyph("berries", 0.03, 0.065, tilt: 70)
        g.line("^0,0 10,8 ^18,20", 0.7)
        g.line("^10,8 ^20,6", 0.6)
        g.shape(2, .circle(21, 24, 5), 0.8)
        g.shape(2, .circle(25, 6, 5), 0.8)
        g.shape(2, .circle(9, 21, 4.5), 0.8)
        return g
    }

    /// A winged seed, the kind that spins down.
    static func seed() -> DoodleGlyph {
        var g = DoodleGlyph("seed", 0.026, 0.055, tilt: 90)
        g.shape(1, "^0,0 10,-5 26,-7 ^36,-2 24,3 10,3 z", 0.75)
        g.blot(.ellipse(2, -0.5, 3, 2.2))
        return g
    }

    /// One small coin: for the Gaming holes.
    static func coin() -> DoodleGlyph {
        var g = DoodleGlyph("coin", 0.03, 0.07, tilt: 20)
        g.weight = 0.4
        g.shape(1, .circle(20, 20, 20), 0.9)
        g.line(.circle(20, 20, 13.5), 0.55)
        g.blot(starPath(20, 20.5, 8.5))
        return g
    }

    static func tuft() -> DoodleGlyph {
        var g = DoodleGlyph("tuft", 0.024, 0.06, tilt: 10)
        g.line("^4,18 ^0,4", 0.8)
        g.line("^9,18 ^9,0", 0.8)
        g.line("^14,18 ^19,5", 0.8)
        return g
    }

    static func bolt() -> DoodleGlyph {
        var g = DoodleGlyph("bolt", 0.035, 0.1, tilt: 24)
        g.shape(1, "^30,0 ^6,36 ^22,36 ^12,66 ^44,24 ^28,24 ^40,0 z", 0.9)
        return g
    }

    static func pixelHeart() -> DoodleGlyph {
        var g = DoodleGlyph("pixelHeart", 0.03, 0.075, tilt: 22)
        g.pixels([".00.00.", "0000000", "0000000", ".00000.", "..000..", "...0..."], x: 0, y: 0, cell: 6, w: 0.75)
        return g
    }

    static func dpad() -> DoodleGlyph {
        var g = DoodleGlyph("dpad", 0.03, 0.06, tilt: 30)
        g.weight = 0.6
        g.shape(1, "^14,0 ^26,0 ^26,14 ^40,14 ^40,26 ^26,26 ^26,40 ^14,40 ^14,26 ^0,26 ^0,14 ^14,14 z", 0.8)
        return g
    }
}
