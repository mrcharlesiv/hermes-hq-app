// Small game-world marks that took the place of the generic squiggles and sparkles.

import CoreGraphics
import Foundation

nonisolated extension DoodleGaming {
    static func tinyGem() -> DoodleGlyph {
        var g = DoodleGlyph("tinyGem", 0.03, 0.07, tilt: 26)
        g.shape(2, "^8,0 ^28,0 ^36,12 ^18,38 ^0,12 z", 0.85)
        g.line("^0,12 ^36,12", 0.55)
        g.line("^12,12 ^18,38 ^24,12", 0.5)
        return g
    }

    static func tinyFlask() -> DoodleGlyph {
        var g = DoodleGlyph("tinyFlask", 0.03, 0.07, tilt: 30)
        g.shape(-1, "^12,0 ^24,0 ^24,12 34,24 34,36 ^28,42 ^8,42 2,36 2,24 ^12,12 z", 0.85)
        g.tint(1, "^3,26 ^33,26 34,36 ^28,42 ^8,42 2,36 z")
        g.line("^3,26 ^33,26", 0.5)
        g.line("^9,0 ^27,0", 1)
        return g
    }

    static func roundButton() -> DoodleGlyph {
        var g = DoodleGlyph("roundButton", 0.022, 0.05, tilt: 0)
        g.shape(-1, .circle(12, 12, 12), 0.75)
        g.shape(1, .circle(12, 12, 7.4), 0.6)
        return g
    }

    static func plusOne() -> DoodleGlyph {
        var g = DoodleGlyph("plusOne", 0.03, 0.065, tilt: 16)
        g.line("^0,14 ^16,14", 1.05)
        g.line("^8,6 ^8,22", 1.05)
        g.line("^24,8 ^31,1 ^31,27", 1.05)
        return g
    }

    static func pixelArrow() -> DoodleGlyph {
        var g = DoodleGlyph("pixelArrow", 0.03, 0.065, tilt: 90)
        g.pixels(["...0...", "..000..", ".00000.", "0000000", "..000..", "..000.."], x: 0, y: 0, cell: 6, w: 0.75)
        return g
    }

    static func levelBars() -> DoodleGlyph {
        var g = DoodleGlyph("levelBars", 0.03, 0.065, tilt: 8)
        for (i, h) in [8.0, 15.0, 22.0, 30.0].enumerated() {
            let x = Double(i) * 10
            g.shape(i == 3 ? 2 : 0, .poly([(x, 30), (x, 30 - h), (x + 7, 30 - h), (x + 7, 30)], closed: true), 0.65)
        }
        return g
    }

    static func tinySword() -> DoodleGlyph {
        var g = DoodleGlyph("tinySword", 0.035, 0.08, tilt: 44)
        g.shape(-1, "^12,0 ^18,8 ^18,36 ^6,36 ^6,8 z", 0.75)
        g.line("^0,37 ^24,37", 1.15)
        g.line("^12,38 ^12,50", 1.25)
        return g
    }

    static func cableSquiggle() -> DoodleGlyph {
        var g = DoodleGlyph("cableSquiggle", 0.04, 0.085, tilt: 40)
        g.line("0,18 8,6 18,6 22,16 18,24 26,28 36,20 44,8 52,10 ^56,16", 0.72)
        g.shape(2, "^54,12 ^64,6 ^68,12 ^58,18 z", 0.65)
        return g
    }
}
