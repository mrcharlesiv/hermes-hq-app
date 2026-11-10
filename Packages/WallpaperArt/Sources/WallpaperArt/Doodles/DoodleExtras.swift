// More small and mid-size drawings for the five newer sets, so they are as thick with drawings as the first three.

import CoreGraphics
import Foundation

nonisolated extension DoodlePeaks {
    static func extras() -> [DoodleGlyph] {
        [woolSock(), trailSign(), chalkBag(), beacon(), pinecone(), snowboard(), stormLantern(), ptarmigan()]
    }

    static func woolSock() -> DoodleGlyph {
        var g = DoodleGlyph("woolSock", 0.09, 0.22, tilt: 20)
        // A thick hiking sock: ribbed cuff, a band, a darned heel and toe.
        let body: DoodlePath = "^22,4 ^60,4 ^61,56 66,66 ^94,74 106,84 106,98 94,106 ^46,106 28,100 20,82 z"
        g.shape(-1, body, 1.4)
        g.tint(2, "^22,4 ^60,4 ^60,24 ^21,24 z")
        g.tint(0, "^21,32 ^60,32 ^61,42 ^21,42 z")
        g.tint(0, "^88,72 94,74 106,84 106,98 94,106 ^84,106 z")
        g.tint(1, "^20,82 ^28,72 44,74 50,90 ^46,106 28,100 z")
        g.line("^21,24 ^60,24", 0.6)
        g.line("^21,32 ^60,32", 0.5)
        g.line("^21,42 ^61,42", 0.5)
        g.line("^88,72 ^84,106", 0.5)
        g.detail(0.13) { g in
            for x in stride(from: 28.0, through: 54, by: 6.5) { g.line(.poly([(x, 7), (x, 21)]), 0.42) }
            g.gel("^28,50 ^27,66", 0.8)
        }
        return g
    }

    static func trailSign() -> DoodleGlyph {
        var g = DoodleGlyph("trailSign", 0.11, 0.26, tilt: 7)
        g.noFlip = true
        // A wooden post with two blank arrow boards, grass and a stone at its foot.
        g.shape(1, "^46,4 ^60,4 ^61,112 ^45,112 z", 1.35)
        g.shape(0, "^12,16 ^84,16 ^102,29 ^84,42 ^12,42 z", 1.4)
        g.shape(-1, "^94,50 ^24,50 ^6,63 ^24,76 ^94,76 z", 1.4)
        g.blot(.circle(53, 22, 1.5))
        g.blot(.circle(53, 69, 1.5))
        g.detail(0.13) { g in
            g.line("^22,25 34,23 44,26 ^62,24", 0.55)
            g.line("^22,33 38,32 ^70,33", 0.55)
            g.line("^28,60 44,58 ^78,60", 0.55)
            g.line("^28,68 40,67 ^62,68", 0.55)
            g.line("^48,84 ^50,104", 0.42)
            g.line("^57,90 ^56,108", 0.42)
        }
        g.shape(2, "^62,112 70,100 86,98 94,106 ^96,114 z", 1.15)
        g.line("^26,112 ^30,100", 0.75)
        g.line("^34,112 ^34,96", 0.75)
        g.line("^40,112 ^44,102", 0.75)
        g.line("^16,114 ^102,114", 0.8)
        return g
    }

    static func chalkBag() -> DoodleGlyph {
        var g = DoodleGlyph("chalkBag", 0.09, 0.22, tilt: 12)
        // A climber's chalk bag: fleece rim, drawcord with a toggle, a white hand print of dust.
        g.shape(2, "^14,32 ^76,32 84,68 74,100 ^20,100 8,70 z", 1.45)
        g.shape(-1, .rrect(6, 18, 82, 18, 6), 1.2)
        g.line("^40,18 34,6 44,0 ^52,12", 0.8)
        g.shape(1, .rrect(44, 8, 8, 12, 2), 0.85)
        g.band(1, outer: "^84,44 ^100,42 ^102,66 ^82,70 ^83,62 ^94,60 ^93,50 ^84,52 z", inner: "^84,44 ^84,44 ^84,44 z", 1, innerW: 0)
        g.detail(0.13) { g in
            g.speckle(12, 22, 84, 32, n: 18, r: 0.55, seed: 61)
            g.stitch("^18,92 ^76,92", dash: 2.4, gap: 2.2, w: 0.42)
            g.hatch("^60,42 ^76,42 ^80,70 ^68,92 ^56,92 z", angle: 70, gap: 3, w: 0.42)
        }
        g.gel("^22,50 ^20,72", 0.9)
        return g
    }

    static func beacon() -> DoodleGlyph {
        var g = DoodleGlyph("beacon", 0.09, 0.22, tilt: 12)
        // A rescue beacon on its harness: a stubby antenna, a little screen with a direction arrow, one big button.
        g.line("^4,70 -4,40 ^12,8", 0.8)
        g.line("^100,70 106,40 ^88,8", 0.8)
        g.shape(1, "^60,10 ^68,-8 ^74,-6 ^68,12 z", 1)
        g.shape(1, .rrect(16, 8, 72, 104, 13), 1.5)
        g.shape(-1, .rrect(26, 20, 52, 38, 4), 1.1)
        g.blot("^52,26 ^62,40 ^56,40 ^56,50 ^48,50 ^48,40 ^42,40 z")
        g.shape(2, .circle(52, 84, 13), 1.2)
        g.shape(-1, .circle(52, 84, 5), 0.7)
        g.blot(.circle(30, 68, 1.8))
        g.blot(.circle(74, 68, 1.8))
        g.detail(0.13) { g in
            g.gel("^24,24 ^23,44", 0.9)
            g.line("^30,100 ^36,104", 0.42)
            g.line("^68,104 ^74,100", 0.42)
        }
        return g
    }

    static func pinecone() -> DoodleGlyph {
        var g = DoodleGlyph("pinecone", 0.08, 0.2, tilt: 26)
        // Overlapping scales, rows offset, with a twig of needles at the top.
        g.shape(0, "50,16 70,28 80,54 74,82 50,106 26,82 20,54 30,28 z", 1.45)
        for (y, row) in [(32.0, [36.0, 50, 64]), (46, [28, 43, 57, 72]), (61, [26, 41, 59, 74]), (76, [32, 50, 68]), (90, [42, 58])] {
            for x in row { g.line(.spline([(x - 7.5, y - 3), (x - 4, y + 5), (x, y + 8), (x + 4, y + 5), (x + 7.5, y - 3)]), 0.7) }
        }
        g.shape(1, "^46,4 ^54,4 ^55,18 ^45,18 z", 1)
        for (a, b) in [((50.0, 8.0), (26.0, 2.0)), ((50, 8), (34, -8)), ((50, 8), (66, -8)), ((50, 8), (74, 2))] {
            g.line(.poly([a, b]), 0.9)
        }
        g.detail(0.12) { $0.gel("^28,50 ^30,38", 0.8) }
        return g
    }

    static func snowboard() -> DoodleGlyph {
        var g = DoodleGlyph("snowboard", 0.12, 0.3, tilt: 40)
        // A twin-tip board, a band of colour, two straps.
        let board: DoodlePath = "^20,20 26,4 40,0 54,4 ^60,20 ^60,130 54,146 40,150 26,146 ^20,130 z"
        g.shape(2, board, 1.5)
        g.tint(0, "^20,56 ^60,44 ^60,70 ^20,82 z")
        g.tint(1, "^20,100 ^60,88 ^60,96 ^20,108 z")
        g.line("^20,56 ^60,44", 0.55)
        g.line("^20,82 ^60,70", 0.55)
        for y in [34.0, 112.0] {
            g.accent(.rrect(14, y, 52, 7, 3))
            g.accent(.rrect(14, y + 11, 52, 5, 2.5))
        }
        g.detail(0.16) { $0.gel("^28,10 ^26,26", 0.9) }
        return g
    }

    static func stormLantern() -> DoodleGlyph {
        var g = DoodleGlyph("stormLantern", 0.09, 0.24, tilt: 10)
        // A hut lantern with a wire bail, a caged glass and a low flame.
        g.line("^22,34 10,16 30,0 ^60,0 80,16 ^68,34", 1)
        g.shape(1, "^28,20 ^62,20 ^72,34 ^18,34 z", 1.25)
        g.shape(-1, "^24,34 ^66,34 74,54 68,78 ^22,78 16,54 z", 1.3)
        g.shape(2, "45,44 54,56 50,70 45,74 40,70 36,56 z", 1)
        g.shape(-1, "45,56 49,64 45,72 41,64 z", 0.5)
        g.line("^24,34 ^22,78", 0.75)
        g.line("^66,34 ^68,78", 0.75)
        g.line("^16,54 ^74,54", 0.65)
        g.shape(1, "^14,78 ^76,78 ^84,104 ^6,104 z", 1.45)
        g.shape(0, "^12,88 ^78,88 ^80,96 ^10,96 z", 0.8)
        g.detail(0.13) { $0.gel("^26,42 ^24,66", 0.8) }
        return g
    }

    static func ptarmigan() -> DoodleGlyph {
        var g = DoodleGlyph("ptarmigan", 0.1, 0.24, tilt: 8)
        // A round snow grouse in its winter coat, stepping along with feathered feet.
        g.shape(-1, "^6,20 18,10 32,12 40,24 44,38 64,40 88,50 ^116,36 ^108,58 ^116,60 96,80 70,92 42,90 22,76 16,54 18,34 ^10,28 z", 1.5)
        g.tint(1, "^24,14 32,12 40,24 44,38 64,40 72,44 56,50 36,46 26,34 z")
        g.tint(0, "^92,50 ^116,36 ^108,58 ^116,60 96,80 ^84,66 z")
        g.blot("^6,20 ^14,16 ^14,24 ^10,28 z")
        g.accent(.circle(22, 20, 2.2))
        g.shape(2, "^18,12 24,8 30,12 ^24,15 z", 0.7)
        g.line("^48,62 64,72 ^84,66", 0.6)
        g.line("^56,56 70,62 ^88,56", 0.6)
        for x in [42.0, 62.0] {
            g.shape(-1, "^\(x),88 ^\(x + 10),88 ^\(x + 8),104 ^\(x + 14),108 ^\(x - 4),108 ^\(x + 1),104 z", 0.9)
        }
        g.detail(0.13) { g in
            g.speckle(28, 16, 60, 46, n: 12, r: 0.6, seed: 73)
            g.line("^-6,110 ^36,110", 0.55)
            g.line("^74,110 ^96,110", 0.55)
        }
        return g
    }
}

nonisolated extension DoodleSports {
    static func extras() -> [DoodleGlyph] {
        [hurdle(), punchingBag(), ballPump(), clipboard(), cornerFlag(), oars(), foamFinger(), ballCan()]
    }

    static func hurdle() -> DoodleGlyph {
        var g = DoodleGlyph("hurdle", 0.1, 0.24, tilt: 7)
        // A track hurdle: a striped top board on two uprights, long feet.
        g.shape(-1, .rrect(14, 28, 8, 62, 2), 1.1)
        g.shape(-1, .rrect(98, 28, 8, 62, 2), 1.1)
        g.line("^-2,92 ^40,92", 1.5)
        g.line("^82,92 ^124,92", 1.5)
        g.shape(-1, .rrect(4, 16, 112, 22, 2.5), 1.4)
        for x in [8.0, 40, 72, 100] { g.tint(0, .poly([(x, 17), (x + 14, 17), (x + 8, 37), (x - 6, 37)], closed: true)) }
        g.shape(1, .rrect(22, 66, 76, 4, 1), 0.7)
        g.detail(0.13) { g in
            g.line("^-10,100 ^16,100", 0.5)
            g.line("^106,100 ^132,100", 0.5)
        }
        return g
    }

    static func punchingBag() -> DoodleGlyph {
        var g = DoodleGlyph("punchingBag", 0.11, 0.27, tilt: 8)
        // A heavy bag on its chains: leather body, stitched bands, a swivel at the top.
        g.line("^40,18 ^50,2", 0.9)
        g.line("^62,18 ^52,2", 0.9)
        g.line("^22,20 ^51,2", 0.9)
        g.line("^80,20 ^51,2", 0.9)
        g.shape(1, .circle(51, -2, 4.6), 0.95)
        g.shape(0, "^18,20 ^84,20 88,30 ^88,122 82,134 ^20,134 14,122 ^14,30 z", 1.6)
        g.shape(2, .rrect(13, 46, 76, 13, 1.5), 1.1)
        g.shape(2, .rrect(13, 104, 76, 11, 1.5), 1.05)
        g.detail(0.15) { g in
            g.stitch("^22,68 ^22,98", dash: 2.4, gap: 2.2, w: 0.42)
            g.stitch("^80,68 ^80,98", dash: 2.4, gap: 2.2, w: 0.42)
            g.hatch("^62,62 ^86,62 ^86,102 ^62,102 z", angle: 72, gap: 3, w: 0.42)
            g.gel("^26,26 ^25,42", 1)
            g.gel("^28,68 ^27,94", 1)
        }
        return g
    }

    static func ballPump() -> DoodleGlyph {
        var g = DoodleGlyph("ballPump", 0.1, 0.24, tilt: 16)
        // A hand pump: a T-handle, a barrel with a foot plate, a hose and its needle.
        g.shape(1, .rrect(8, 2, 44, 9, 4), 1.2)
        g.shape(-1, .rrect(27, 10, 6, 28, 1), 0.9)
        g.shape(2, "^20,36 ^40,36 ^41,104 ^19,104 z", 1.4)
        g.shape(1, .rrect(17, 34, 26, 7, 2), 0.9)
        g.shape(1, "^4,104 ^56,104 ^60,114 ^0,114 z", 1.2)
        g.line("^41,92 66,92 84,78 96,84 ^104,72", 1.05)
        g.shape(1, "^100,74 ^108,68 ^112,74 ^104,80 z", 0.85)
        g.line("^108,70 ^118,60", 0.8)
        g.detail(0.13) { g in
            g.gel("^25,46 ^25,92", 0.9)
            g.line("^20,60 ^41,60", 0.42)
            g.line("^20,72 ^41,72", 0.42)
        }
        return g
    }

    static func clipboard() -> DoodleGlyph {
        var g = DoodleGlyph("clipboard", 0.11, 0.26, tilt: 12)
        // A coach's clipboard with a play sketched out: crosses, rings and one looping arrow.
        g.shape(1, .rrect(6, 12, 92, 116, 6), 1.5)
        g.shape(-1, .rrect(14, 24, 76, 96, 2), 1.1)
        g.shape(0, "^36,6 ^68,6 ^72,20 ^76,28 ^28,28 ^32,20 z", 1.2)
        g.blot(.circle(52, 14, 2))
        for (x, y) in [(28.0, 46.0), (60, 42), (76, 62)] { g.line(.circle(x, y, 4.2), 0.8) }
        for (x, y) in [(30.0, 94.0), (52, 104), (74, 98)] {
            g.line(.poly([(x - 4, y - 4), (x + 4, y + 4)]), 0.9)
            g.line(.poly([(x - 4, y + 4), (x + 4, y - 4)]), 0.9)
        }
        g.line("^30,84 22,68 36,58 54,70 ^70,76", 0.7)
        g.blot("^76,78 ^66,80 ^69,71 z")
        return g
    }

    static func cornerFlag() -> DoodleGlyph {
        var g = DoodleGlyph("cornerFlag", 0.1, 0.26, tilt: 7)
        // A pitch's corner flag, its pennant blowing, the curve of the white line at its foot.
        g.shape(1, .rrect(26, 2, 6, 110, 2), 1.15)
        for y in stride(from: 14.0, through: 100, by: 18) { g.tint(-1, .rrect(26, y, 6, 8, 0)) }
        g.shape(0, "^32,6 58,4 78,14 ^104,12 90,28 ^100,44 70,42 52,50 ^32,46 z", 1.35)
        g.tint(2, "^32,6 ^62,5 ^62,47 ^32,46 z")
        g.line("^62,5 ^62,47", 0.5)
        g.detail(0.13) { $0.gel("^38,12 ^50,11", 0.8) }
        g.line("^-10,112 14,112 ^60,112", 1)
        g.line("^4,126 34,118 ^60,114", 0.9)
        g.line("^-6,104 ^-2,112", 0.55)
        g.line("^12,102 ^12,112", 0.55)
        return g
    }

    static func oars() -> DoodleGlyph {
        var g = DoodleGlyph("oars", 0.12, 0.3, tilt: 10)
        // Crossed rowing oars, one blade striped.
        func oar(_ g: inout DoodleGlyph, _ a: (Double, Double), _ b: (Double, Double), sep: Int, stripe: Bool) {
            let dx = b.0 - a.0, dy = b.1 - a.1
            let l = hypot(dx, dy)
            let ux = dx / l, uy = dy / l, nx = -uy, ny = ux
            func P(_ along: Double, _ off: Double) -> (Double, Double) { (a.0 + ux * along + nx * off, a.1 + uy * along + ny * off) }
            g.shape(-1, .poly([P(0, -2.6), P(l - 30, -2.6), P(l - 30, 2.6), P(0, 2.6)], closed: true), 1.2)
            g.shape(1, .poly([P(-8, -3.6), P(8, -3.6), P(8, 3.6), P(-8, 3.6)], closed: true), 1)
            var blade = DoodlePath.spline([P(l - 34, -2.6), P(l - 20, -9), P(l, -11), P(l + 6, 0), P(l, 11), P(l - 20, 9), P(l - 34, 2.6)])
            blade.closed = true
            g.shape(sep, blade, 1.35)
            if stripe { g.tint(2, .poly([P(l - 12, -11), P(l - 4, -11), P(l - 4, 11), P(l - 12, 11)], closed: true)) }
            g.line(.poly([P(l - 30, 0), P(l - 2, 0)]), 0.42)
        }
        oar(&g, (6, 128), (106, 18), sep: 0, stripe: false)
        oar(&g, (106, 128), (6, 18), sep: 1, stripe: true)
        return g
    }

    static func foamFinger() -> DoodleGlyph {
        var g = DoodleGlyph("foamFinger", 0.11, 0.27, tilt: 12)
        g.noFlip = true
        // The big foam hand from the stands: one finger up, a thumb, a star where the number would go.
        g.shape(2, "32,12 42,4 52,12 ^54,50 ^66,46 ^72,52 ^80,48 ^86,54 ^94,52 100,62 98,82 88,106 ^32,106 ^22,84 ^10,66 ^12,54 ^20,54 ^32,68 z", 1.5)
        g.line("^54,50 ^54,66", 0.7)
        g.line("^72,52 ^72,66", 0.7)
        g.line("^86,54 ^86,66", 0.7)
        g.shape(-1, DoodleFillers.starPath(62, 84, 12), 0.9)
        g.shape(1, .rrect(28, 106, 64, 16, 2), 1.3)
        g.detail(0.13) { g in
            g.gel("^38,16 ^38,44", 1)
            g.line("^34,114 ^86,114", 0.42)
        }
        return g
    }

    static func ballCan() -> DoodleGlyph {
        var g = DoodleGlyph("ballCan", 0.11, 0.27, tilt: 12)
        // A clear can of three tennis balls with a pull-off lid.
        g.shape(-1, .rrect(14, 12, 62, 118, 6), 1.5)
        for (y, flip) in [(34.0, false), (70, true), (106, false)] {
            g.shape(0, .circle(45, y, 25), 1.25)
            let s: Double = flip ? -1 : 1
            g.line(.spline([(24, y - 8 * s), (36, y - 4 * s), (42, y + 8 * s), (46, y + 24 * s)]), 0.8)
            g.line(.spline([(66, y - 8 * s), (58, y - 12 * s), (52, y - 18 * s), (50, y - 24 * s)]), 0.8)
        }
        g.shape(2, .rrect(10, 2, 70, 15, 4), 1.35)
        g.shape(1, .rrect(10, 122, 70, 12, 3), 1.2)
        g.detail(0.13) { g in
            g.gel("^20,22 ^20,60", 1.1)
            g.line("^60,5 ^60,14", 0.42)
            g.line("^68,5 ^68,14", 0.42)
        }
        return g
    }
}

nonisolated extension DoodleLilac {
    static func extras() -> [DoodleGlyph] {
        [pearlStrand(), handMirror(), starJar(), pocketWatch(), sandDollar(), bellFlower(), sealedLetter(), heartLock()]
    }

    static func pearlStrand() -> DoodleGlyph {
        var g = DoodleGlyph("pearlStrand", 0.1, 0.26, tilt: 16)
        // A looped string of pearls, big to small, with a drop in the middle and a little clasp.
        let pts = K.arcPoints(56, 40, 50, 54, 170, 10, count: 19)
        for (i, p) in pts.enumerated() {
            let t = abs(Double(i) - 9) / 9
            let r = 6.8 - 3 * t
            g.shape(-1, .circle(p.0, p.1, r), 0.95)
            if r > 5 { g.gel(.circle(p.0 - 1.8, p.1 - 1.8, 0.7), 0.5) }
        }
        g.shape(1, .rrect(52, 94, 8, 7, 2), 0.8)
        g.shape(0, "56,100 64,114 60,124 ^56,126 52,124 48,114 z", 1.1)
        g.gel("^52,112 ^53,118", 0.7)
        g.shape(1, .rrect(2, 44, 10, 7, 2), 0.8)
        g.shape(1, .rrect(100, 44, 10, 7, 2), 0.8)
        return g
    }

    static func handMirror() -> DoodleGlyph {
        var g = DoodleGlyph("handMirror", 0.11, 0.27, tilt: 26)
        // An oval looking-glass with a scrolled frame, a turned handle and a streak of shine.
        g.shape(1, "^38,88 ^54,88 ^56,108 ^52,116 ^56,124 ^54,146 46,152 ^38,146 ^36,124 ^40,116 ^36,108 z", 1.35)
        g.shape(0, .ellipse(46, 46, 42, 48), 1.5)
        g.shape(-1, .ellipse(46, 46, 32, 38), 1.15)
        g.tint(2, .ellipse(46, 50, 26, 30))
        g.gel("^28,36 ^42,20", 1.4)
        g.gel("^34,44 ^50,24", 0.9)
        g.shape(1, DoodleFillers.starPath(46, 2, 7), 0.75)
        g.detail(0.14) { g in
            for a in stride(from: 15.0, to: 360, by: 30) {
                let p = K.polar(46, 46, 37, a)
                g.blot(.circle(p.0, p.1 * 1.0 + (a > 180 ? -2 : 2), 1))
            }
            g.line("^36,132 ^56,132", 0.42)
        }
        return g
    }

    static func starJar() -> DoodleGlyph {
        var g = DoodleGlyph("starJar", 0.1, 0.26, tilt: 10)
        // A glass jar of caught stars, corked and tied with a ribbon.
        g.shape(1, "^28,4 ^62,4 ^64,20 ^26,20 z", 1.2)
        g.shape(-1, "^24,20 ^66,20 ^66,30 82,44 ^84,104 76,114 ^14,114 6,104 ^8,44 24,30 z", 1.5)
        for (x, y, r, s) in [(30.0, 62.0, 11.0, 1), (56, 50, 9, 0), (62, 80, 12, 1), (30, 92, 9, 0), (46, 76, 6, 2), (66, 100, 6, 0)] {
            g.shape(s, DoodleFillers.starPath(x, y, r), 0.8)
        }
        g.shape(0, "^24,24 ^66,24 ^66,31 ^24,31 z", 0.9)
        g.shape(0, "^62,28 ^78,18 ^82,26 ^70,34 z", 0.85)
        g.shape(0, "^66,32 ^84,38 ^78,46 ^64,38 z", 0.85)
        g.detail(0.13) { g in
            g.gel("^14,50 ^13,92", 1.1)
            g.line("^32,8 ^32,16", 0.42)
            g.line("^44,8 ^44,16", 0.42)
            g.blot(.circle(46, 100, 1.2))
            g.blot(.circle(44, 42, 1.2))
        }
        return g
    }

    static func pocketWatch() -> DoodleGlyph {
        var g = DoodleGlyph("pocketWatch", 0.1, 0.25, tilt: 18)
        // A fob watch, its lid hinged open behind, a chain trailing away.
        g.shape(0, .circle(82, 72, 34), 1.2)
        g.shape(1, .circle(52, 72, 40), 1.55)
        g.shape(-1, .circle(52, 72, 31), 1.1)
        g.shape(1, .rrect(46, 22, 12, 12, 3), 1.05)
        g.band(1, outer: .circle(52, 14, 9), inner: .circle(52, 14, 5), 1, innerW: 0.7)
        for h in 0..<12 {
            let a = Double(h) * 30
            g.line(.poly([K.polar(52, 72, 25, a), K.polar(52, 72, h % 3 == 0 ? 30 : 28, a)]), h % 3 == 0 ? 0.8 : 0.45)
        }
        g.line("^52,72 ^52,50", 0.9)
        g.line("^52,72 ^68,82", 1)
        g.blot(.circle(52, 72, 2.2))
        var last: (Double, Double) = (58, 6)
        for i in 1...6 {
            let t = Double(i)
            let p: (Double, Double) = (56 + t * 7.4, 10 - sin(t * 0.9) * 6 + t * 1.2)
            g.line(.circle(p.0, p.1, 3), 0.55)
            last = p
        }
        _ = last
        g.detail(0.14) { $0.gel("^24,58 ^34,44", 0.9) }
        return g
    }

    static func sandDollar() -> DoodleGlyph {
        var g = DoodleGlyph("sandDollar", 0.08, 0.2, tilt: 40)
        // A round pale shell with its five-petal flower, and small slots.
        g.shape(-1, K.puff(50, 50, 46, 45, n: 22, depth: 0.03), 1.45)
        for a in stride(from: -90.0, to: 270, by: 72) {
            let tip = K.polar(50, 50, 32, a), base = K.polar(50, 50, 7, a)
            g.shape(0, K.leaf(base, tip, belly: 13), 0.8)
            g.line(.poly([K.polar(50, 50, 10, a), K.polar(50, 50, 28, a)]), 0.42)
            let slot = K.polar(50, 50, 38, a + 36)
            g.blot(.ellipse(slot.0, slot.1, 2.4, 1.2, rot: a + 126))
        }
        g.blot(.circle(50, 50, 2))
        g.detail(0.12) { $0.speckle(12, 14, 88, 88, n: 16, r: 0.42, seed: 83) }
        return g
    }

    static func bellFlower() -> DoodleGlyph {
        var g = DoodleGlyph("bellFlower", 0.1, 0.27, tilt: 10)
        // An arching stem of hanging bells, buds at the tip.
        g.line("^10,136 16,92 30,50 58,18 ^96,8", 1.15)
        g.shape(2, K.leaf((14, 110), (-16, 92), belly: 14), 1)
        g.shape(2, K.leaf((18, 90), (46, 80), belly: 13), 1)
        func bell(_ g: inout DoodleGlyph, _ x: Double, _ y: Double, _ k: Double) {
            let P = { (s: DoodlePath) in s.scaled(k, about: (0, 0)).moved(x, y) }
            g.line(.poly([(x, y - 8 * k), (x, y)]), 0.7)
            g.shape(0, P("^-5,0 ^5,0 15,18 17,30 ^22,38 ^11,35 ^6,42 ^0,36 ^-6,42 ^-11,35 ^-22,38 -17,30 -15,18 z"), 1.2)
            g.line(P("^0,4 ^0,34"), 0.42)
            g.line(P("^-7,8 ^-10,30"), 0.42)
        }
        bell(&g, 34, 54, 1)
        bell(&g, 60, 26, 0.92)
        bell(&g, 86, 18, 0.7)
        g.shape(0, .ellipse(100, 16, 5, 7), 0.8)
        return g
    }

    static func sealedLetter() -> DoodleGlyph {
        var g = DoodleGlyph("sealedLetter", 0.1, 0.25, tilt: 18)
        // A sealed envelope: a pale flap, a wax seal with a star, a sprig under the wax.
        g.shape(-1, .rrect(2, 16, 116, 78, 4), 1.5)
        g.line("^4,92 ^46,56", 0.6)
        g.line("^116,92 ^74,56", 0.6)
        g.shape(0, "^2,18 ^60,62 ^118,18 ^116,16 ^4,16 z", 1.25)
        g.shape(2, K.leaf((58, 62), (38, 74), belly: 8), 0.75)
        g.shape(2, K.leaf((62, 62), (82, 74), belly: 8), 0.75)
        g.shape(1, K.puff(60, 58, 14, 14, n: 9, depth: 0.08), 1.2)
        g.shape(-1, DoodleFillers.starPath(60, 58, 7), 0.65)
        g.detail(0.13) { g in
            g.stitch("^10,86 ^38,86", dash: 2, gap: 2, w: 0.42)
            g.stitch("^82,86 ^110,86", dash: 2, gap: 2, w: 0.42)
        }
        return g
    }

    static func heartLock() -> DoodleGlyph {
        var g = DoodleGlyph("heartLock", 0.08, 0.2, tilt: 16)
        // A little heart-shaped padlock: a shackle, a keyhole.
        g.band(1, outer: "^22,48 22,20 34,4 ^52,4 ^66,4 76,20 ^76,48 ^64,48 64,24 58,16 ^40,16 34,24 ^34,48 z", inner: "^22,48 ^22,48 ^22,48 z", 1.25, innerW: 0)
        g.shape(0, DoodleFillers.heartPath(49, 70, 40), 1.5)
        g.blot(.circle(49, 66, 5))
        g.blot("^46,68 ^52,68 ^54,84 ^44,84 z")
        g.detail(0.12) { $0.gel("^22,56 ^30,48", 1) }
        return g
    }
}

nonisolated extension DoodleTravel {
    static func extras() -> [DoodleGlyph] {
        [snorkel(), binoculars(), mapPin(), sandcastle(), carryOn(), kayak(), canteen(), kite()]
    }

    static func snorkel() -> DoodleGlyph {
        var g = DoodleGlyph("snorkel", 0.11, 0.26, tilt: 14)
        // A dive mask with its strap, a J-shaped snorkel beside it.
        g.shape(2, DoodlePath.taper([(104, 8), (104, 72), (96, 92), (76, 100), (62, 96)], 10, 10), 1.3)
        g.tint(0, .rrect(99, 2, 10, 14, 1))
        g.tint(0, .rrect(99, 26, 10, 8, 0))
        g.shape(0, "^52,88 ^64,88 ^70,102 ^52,104 z", 1)
        g.line("^0,44 -8,24 ^14,8", 1.5)
        g.line("^86,40 94,24 ^78,10", 1.5)
        g.shape(1, "^4,28 ^84,28 90,50 78,70 ^56,70 ^44,58 ^32,70 ^12,70 0,50 z", 1.5)
        g.shape(-1, "^10,34 ^40,34 ^42,52 ^32,62 ^14,62 6,50 z", 1)
        g.shape(-1, "^48,34 ^78,34 82,50 74,62 ^56,62 ^46,52 z", 1)
        g.tint(2, "^12,48 ^38,48 ^32,62 ^14,62 z")
        g.tint(2, "^50,48 ^80,48 74,62 ^56,62 z")
        g.gel("^14,38 ^20,44", 1)
        g.gel("^54,38 ^60,44", 1)
        return g
    }

    static func binoculars() -> DoodleGlyph {
        var g = DoodleGlyph("binoculars", 0.1, 0.25, tilt: 14)
        // Field glasses, a strap looping off.
        g.line("^10,24 -4,8 22,-8 ^50,2", 0.8)
        for x in [6.0, 66.0] {
            g.shape(1, "^\(x + 6),8 ^\(x + 34),8 ^\(x + 36),24 ^\(x + 4),24 z", 1.3)
            g.shape(0, "^\(x + 2),24 ^\(x + 38),24 ^\(x + 44),92 ^\(x - 4),92 z", 1.5)
            g.shape(1, .rrect(x - 6, 92, 52, 14, 3), 1.35)
            g.line(.poly([(x + 1, 44), (x + 39, 44)]), 0.5)
            g.line(.poly([(x, 66), (x + 41, 66)]), 0.5)
            g.detail(0.13) { g in
                g.gel(.poly([(x + 8, 30), (x + 7, 40)]), 0.9)
                g.hatch(.poly([(x + 26, 46), (x + 38, 46), (x + 40, 64), (x + 26, 64)], closed: true), angle: 80, gap: 2.8, w: 0.42)
            }
        }
        g.shape(-1, .rrect(46, 30, 20, 24, 3), 1.2)
        g.shape(2, .circle(56, 42, 6), 0.8)
        return g
    }

    static func mapPin() -> DoodleGlyph {
        var g = DoodleGlyph("mapPin", 0.08, 0.2, tilt: 14)
        // A map pin standing on its dashed route, its hole showing a sun.
        g.stitch("^-18,120 8,112 ^26,116", dash: 3, gap: 3, w: 0.8)
        g.stitch("^62,116 84,110 ^116,118", dash: 3, gap: 3, w: 0.8)
        g.line(.ellipse(44, 118, 15, 4.2), 0.6)
        g.shape(2, "44,116 28,86 12,62 8,38 18,14 44,2 70,14 80,38 76,62 60,86 z", 1.55)
        g.shape(-1, .circle(44, 40, 17), 1.1)
        g.shape(1, .circle(44, 40, 8), 0.8)
        g.detail(0.12) { $0.gel("^18,44 ^24,22", 1.1) }
        return g
    }

    static func sandcastle() -> DoodleGlyph {
        var g = DoodleGlyph("sandcastle", 0.12, 0.28, tilt: 6)
        g.noFlip = true
        // Three bucket-turned towers with a door and a paper flag, a little spade stuck beside them.
        func tower(_ g: inout DoodleGlyph, x: Double, w: Double, top: Double) {
            let b = 104.0
            let t = 5.0
            g.shape(1, .poly([(x, top), (x + w * 0.2, top), (x + w * 0.2, top + t), (x + w * 0.4, top + t), (x + w * 0.4, top), (x + w * 0.6, top), (x + w * 0.6, top + t), (x + w * 0.8, top + t), (x + w * 0.8, top), (x + w, top), (x + w + 2, b), (x - 2, b)], closed: true), 1.4)
            g.line(.poly([(x - 0.5, top + 18), (x + w + 0.5, top + 18)]), 0.5)
        }
        tower(&g, x: 6, w: 30, top: 50)
        tower(&g, x: 74, w: 30, top: 42)
        tower(&g, x: 34, w: 42, top: 22)
        g.shape(-1, "^46,104 ^46,84 55,76 64,84 ^64,104 z", 1)
        g.line("^55,22 ^55,0", 0.9)
        g.shape(0, "^55,0 ^76,6 ^55,13 z", 1)
        g.blot(.rrect(50, 42, 4, 6, 1))
        g.blot(.rrect(58, 42, 4, 6, 1))
        g.shape(0, "^112,84 ^126,84 ^128,100 119,108 ^110,100 z", 1.15)
        g.line("^119,84 ^119,58", 1.2)
        g.line("^112,58 ^126,58", 1.2)
        g.line("^-12,106 40,104 ^136,108", 1)
        g.detail(0.14) { g in
            g.speckle(10, 72, 100, 100, n: 26, r: 0.55, seed: 91)
            g.line("^6,114 ^28,112", 0.5)
            g.line("^88,114 ^112,114", 0.5)
        }
        return g
    }

    static func carryOn() -> DoodleGlyph {
        var g = DoodleGlyph("carryOn", 0.11, 0.27, tilt: 8)
        // A wheeled cabin bag: telescopic handle up, ribbed shell, a tag and stickers from nowhere.
        g.line("^28,30 ^28,0", 1.2)
        g.line("^60,30 ^60,0", 1.2)
        g.shape(1, .rrect(22, -6, 44, 9, 4), 1.2)
        g.shape(0, .rrect(6, 28, 76, 96, 10), 1.6)
        for x in [22.0, 44, 66] { g.line(.poly([(x, 36), (x, 116)]), 0.65) }
        g.shape(-1, .rrect(32, 22, 24, 9, 3), 1)
        g.shape(1, "^80,46 ^96,42 ^102,60 ^88,66 z", 0.95)
        g.line("^82,44 ^80,38", 0.6)
        g.shape(2, .circle(30, 88, 9), 0.75)
        g.shape(-1, DoodleFillers.starPath(58, 62, 9), 0.7)
        for x in [20.0, 68] {
            g.accent(.circle(x, 128, 7))
            g.blot(.circle(x, 128, 1))
        }
        g.detail(0.14) { $0.gel("^12,40 ^12,70", 1) }
        return g
    }

    static func kayak() -> DoodleGlyph {
        var g = DoodleGlyph("kayak", 0.13, 0.32, tilt: 8)
        g.noTuck = true
        // A kayak seen from the side, ends turned up, a seat rim, the paddle resting across it.
        let shaft = DoodlePath.poly([(20, 12), (116, 78)])
        g.shape(1, K.leaf((10, 4), (30, 18), belly: 9), 1.15)
        g.line(shaft, 1.3)
        g.shape(0, "^-10,36 8,48 40,54 ^96,54 128,48 ^148,34 138,60 112,74 ^28,74 2,60 z", 1.55)
        g.tint(2, "^-10,36 8,48 ^22,52 ^28,74 2,60 z")
        g.tint(2, "^148,34 128,48 ^114,52 ^112,74 138,60 z")
        g.shape(1, "^50,54 56,44 ^84,44 90,54 z", 1.15)
        g.shape(1, K.leaf((106, 72), (124, 86), belly: 9), 1.15)
        g.line("^-16,86 2,82 ^22,86", 0.8)
        g.line("^40,88 58,84 ^80,88", 0.7)
        g.line("^126,92 ^150,90", 0.6)
        g.detail(0.14) { g in
            g.gel("^14,58 ^36,62", 0.9)
            g.line("^4,62 ^136,62", 0.42)
        }
        return g
    }

    static func canteen() -> DoodleGlyph {
        var g = DoodleGlyph("canteen", 0.09, 0.22, tilt: 12)
        // A round felt-covered flask on a webbing strap, the cap on a little chain.
        g.line("^40,10 12,18 -6,50 ^4,84", 1)
        g.line("^60,10 88,18 106,50 ^96,84", 1)
        g.shape(1, .rrect(40, 0, 20, 14, 2), 1.25)
        g.shape(0, .circle(50, 62, 46), 1.6)
        g.shape(-1, .ellipse(50, 62, 30, 30), 0.9)
        g.tint(2, .ellipse(50, 62, 30, 30))
        g.shape(-1, DoodleFillers.starPath(50, 62, 12), 0.7)
        g.detail(0.13) { g in
            g.stitch(.circle(50, 62, 40), dash: 2.4, gap: 2.2, w: 0.42)
            g.gel("^12,50 ^20,32", 1)
        }
        return g
    }

    static func kite() -> DoodleGlyph {
        var g = DoodleGlyph("kite", 0.11, 0.28, tilt: 14)
        // A diamond beach kite in four colours, a wandering tail with little bows.
        g.shape(-1, "^52,0 ^92,48 ^52,108 ^12,48 z", 1.5)
        g.tint(0, "^52,0 ^92,48 ^52,48 z")
        g.tint(2, "^12,48 ^52,48 ^52,108 z")
        g.tint(1, "^52,48 ^92,48 ^52,108 z")
        g.line("^52,0 ^52,108", 0.8)
        g.line("^12,48 ^92,48", 0.8)
        g.line("^52,108 64,122 48,136 ^62,152", 0.8)
        for (x, y, s) in [(60.0, 118.0, 0), (50, 134, 2), (60, 150, 1)] {
            g.shape(s, .poly([(x - 8, y - 5), (x, y), (x - 8, y + 5)], closed: true), 0.7)
            g.shape(s, .poly([(x + 8, y - 5), (x, y), (x + 8, y + 5)], closed: true), 0.7)
        }
        g.detail(0.13) { $0.gel("^46,18 ^34,32", 0.9) }
        return g
    }
}

nonisolated extension DoodleCafe {
    static func extras() -> [DoodleGlyph] {
        [gooseneck(), readingGlasses(), inkBottle(), headphones(), cassette(), sugarShaker(), jarCandle(), stickyNotes()]
    }

    static func gooseneck() -> DoodleGlyph {
        var g = DoodleGlyph("gooseneck", 0.12, 0.29, tilt: 8)
        g.noFlip = true
        // A pour-over kettle: a long swan neck, a flat lid with a knob, a looped handle.
        g.band(1, outer: "^84,30 104,20 118,34 116,58 ^100,76 ^92,70 106,54 108,38 102,30 ^86,40 z", inner: "^84,30 ^84,30 ^84,30 z", 1.25, innerW: 0)
        g.shape(-1, DoodlePath.taper([(36, 84), (18, 74), (12, 50), (6, 28), (-10, 20)], 10, 4), 1.25)
        g.shape(-1, "^28,32 ^88,32 92,60 96,92 ^88,108 ^28,108 ^20,92 24,60 z", 1.55)
        g.shape(0, "^26,28 ^90,28 ^88,36 ^28,36 z", 1.2)
        g.accent(.ellipse(58, 18, 6, 6))
        g.line("^58,24 ^58,28", 0.9)
        g.line("^21,90 ^95,90", 0.55)
        g.line("^-16,26 -20,38 ^-16,48", 0.65)
        g.detail(0.14) { g in
            g.gel("^32,44 ^30,82", 1.1)
            g.hatch("^74,42 ^90,42 ^94,88 ^76,88 z", angle: 80, gap: 3, w: 0.42)
        }
        return g
    }

    static func readingGlasses() -> DoodleGlyph {
        var g = DoodleGlyph("readingGlasses", 0.09, 0.22, tilt: 20)
        // Round tortoiseshell reading glasses, one arm folded across.
        g.line("^2,30 -10,14 ^-18,12", 1.2)
        g.line("^118,30 98,12 ^78,8", 1.2)
        for x in [28.0, 92.0] {
            g.shape(0, .circle(x, 44, 26), 1.3)
            g.shape(-1, .circle(x, 44, 19), 1)
            g.gel(.poly([(x - 10, 38), (x - 3, 31)]), 1)
        }
        g.line("^52,38 60,34 ^68,38", 1.2)
        g.detail(0.13) { g in
            for a in stride(from: 20.0, to: 360, by: 45) {
                g.blot(.circle(K.polar(28, 44, 22.5, a).0, K.polar(28, 44, 22.5, a).1, 1))
                g.blot(.circle(K.polar(92, 44, 22.5, a + 18).0, K.polar(92, 44, 22.5, a + 18).1, 1))
            }
        }
        return g
    }

    static func inkBottle() -> DoodleGlyph {
        var g = DoodleGlyph("inkBottle", 0.1, 0.25, tilt: 10)
        // A square bottle of ink, its neck open, a fountain pen leaning in it.
        g.shape(1, DoodlePath.taper([(36, 54), (66, 0)], 7, 9), 1.25)
        g.shape(2, "^62,8 ^74,14 ^84,-14 z", 1)
        g.shape(-1, "^22,34 ^56,34 ^56,44 ^76,54 ^78,104 ^0,104 ^2,54 ^22,44 z", 1.5)
        g.accent("^3,66 ^77,66 ^78,100 ^2,100 z")
        g.shape(-1, .rrect(16, 72, 46, 22, 2), 0.9)
        g.line("^22,80 34,78 ^54,80", 0.5)
        g.line("^22,87 34,86 ^48,87", 0.5)
        g.gel("^8,54 ^6,62", 0.9)
        g.blot(.ellipse(92, 104, 5, 2))
        return g
    }

    static func headphones() -> DoodleGlyph {
        var g = DoodleGlyph("headphones", 0.11, 0.27, tilt: 14)
        // Big padded headphones, a curled cord.
        g.band(1, outer: "^4,64 6,28 28,4 ^60,-4 ^92,4 114,28 ^116,64 ^106,64 104,34 86,14 ^60,8 ^34,14 16,34 ^14,64 z", inner: "^4,64 ^4,64 ^4,64 z", 1.3, innerW: 0)
        for (x, m) in [(8.0, 1.0), (112, -1)] {
            g.shape(0, .rrect(x - 11, 54, 22, 48, 9), 1.5)
            g.shape(2, .rrect(x + 3 * m - 4, 62, 8, 32, 3), 0.85)
        }
        g.line("^8,102 4,114 14,116 10,124 20,124 ^18,134", 0.7)
        g.detail(0.13) { g in
            g.gel("^2,62 ^2,84", 0.8)
            g.stitch("^28,12 60,3 ^92,12", dash: 2.2, gap: 2.2, w: 0.42)
        }
        return g
    }

    static func cassette() -> DoodleGlyph {
        var g = DoodleGlyph("cassette", 0.1, 0.25, tilt: 20)
        // A mix tape: a hand-squiggled label, two reels, the worn trapezoid at its foot.
        g.shape(2, .rrect(0, 0, 124, 80, 5), 1.55)
        g.shape(-1, .rrect(8, 8, 108, 46, 2), 1.05)
        g.tint(0, .rrect(8, 8, 108, 8, 0))
        g.line("^16,24 34,22 52,25 ^84,23", 0.6)
        g.accent(.rrect(30, 30, 64, 20, 9))
        for x in [42.0, 82] {
            g.shape(-1, .circle(x, 40, 7.4), 0.8)
            g.blot(.circle(x, 40, 1.8))
        }
        g.shape(1, "^28,80 ^36,60 ^88,60 ^96,80 z", 1.2)
        for x in [44.0, 80] { g.blot(.circle(x, 71, 2)) }
        g.blot(.circle(6, 6, 1.1))
        g.blot(.circle(118, 6, 1.1))
        return g
    }

    static func sugarShaker() -> DoodleGlyph {
        var g = DoodleGlyph("sugarShaker", 0.09, 0.23, tilt: 10)
        // A diner sugar pourer: ribbed glass, a steel cap and flap.
        g.shape(-1, "^22,30 ^68,30 ^78,50 ^78,106 ^68,116 ^22,116 ^12,106 ^12,50 z", 1.5)
        g.tint(0, "^12,62 ^78,62 ^78,106 ^68,116 ^22,116 ^12,106 z")
        g.line("^12,62 22,60 34,63 48,60 62,63 ^78,61", 0.6)
        g.shape(1, "^20,18 ^70,18 ^76,34 ^14,34 z", 1.35)
        g.shape(1, "^38,4 ^56,4 ^62,18 ^32,18 z", 1.2)
        g.shape(2, "^56,4 ^76,-4 ^80,4 ^62,12 z", 0.9)
        for x in [24.0, 36, 48, 60, 70] { g.line(.poly([(x, 40), (x + (x - 45) * 0.04, 110)]), 0.45) }
        g.detail(0.13) { g in
            g.gel("^18,46 ^18,84", 1)
            g.speckle(16, 70, 74, 110, n: 20, r: 0.5, seed: 97)
        }
        return g
    }

    static func jarCandle() -> DoodleGlyph {
        var g = DoodleGlyph("jarCandle", 0.08, 0.2, tilt: 8)
        // A jar candle with a paper label, its flame up.
        g.line("^44,44 ^44,36", 0.9)
        g.shape(2, "44,4 53,18 50,32 44,38 38,32 35,18 z", 1.1)
        g.shape(-1, "44,18 48,26 44,34 40,26 z", 0.5)
        g.shape(-1, .rrect(10, 40, 68, 74, 8), 1.5)
        g.tint(0, .rrect(11, 52, 66, 60, 6))
        g.line("^11,52 ^77,52", 0.6)
        g.shape(-1, .rrect(22, 66, 44, 30, 2), 0.95)
        g.shape(1, K.leaf((36, 90), (52, 72), belly: 9), 0.75)
        g.detail(0.12) { g in
            g.gel("^16,50 ^16,68", 0.9)
            g.line("^38,92 ^46,92", 0.42)
        }
        return g
    }

    static func stickyNotes() -> DoodleGlyph {
        var g = DoodleGlyph("stickyNotes", 0.08, 0.21, tilt: 16)
        // A pad of sticky notes with a curling corner, a drawn cup on the top one, a paperclip.
        g.shape(1, "^10,18 ^100,14 ^104,96 ^14,100 z", 1.2)
        g.shape(0, "^4,8 ^94,4 ^98,70 80,92 ^8,92 z", 1.4)
        g.shape(-1, "^98,70 84,74 ^80,92 z", 1)
        g.shade("^98,70 84,74 ^80,92 z")
        g.line("^30,44 ^62,44 60,64 ^34,64 z", 0.8)
        g.line("^62,48 72,48 70,58 ^61,58", 0.8)
        g.line("^40,38 44,30 ^40,24", 0.55)
        g.line("^52,38 56,30 ^52,24", 0.55)
        g.line("^20,76 40,74 ^68,76", 0.55)
        g.line("^78,-8 ^74,18 80,24 ^86,18 ^90,-4 84,-10 ^80,-4 ^78,12", 0.7)
        return g
    }
}

// Small things and marks: the drawings that thicken the ground between the bigger ones.

nonisolated extension DoodlePeaks {
    static func littles() -> [DoodleGlyph] {
        [tinyFlag(), tinyTent(), tinyLoop()]
    }

    static func tinyFlag() -> DoodleGlyph {
        var g = DoodleGlyph("tinyFlag", 0.03, 0.06, tilt: 10)
        g.line("^10,4 ^10,60", 1.3)
        g.shape(2, "^10,4 ^46,14 ^10,28 z", 1)
        return g
    }

    static func tinyTent() -> DoodleGlyph {
        var g = DoodleGlyph("tinyTent", 0.03, 0.065, tilt: 8)
        g.shape(0, "^30,4 ^60,48 ^0,48 z", 1.1)
        g.shape(-1, "^30,20 ^40,48 ^20,48 z", 0.8)
        return g
    }

    static func tinyLoop() -> DoodleGlyph {
        var g = DoodleGlyph("tinyLoop", 0.03, 0.06, tilt: 30)
        g.line("^0,30 14,10 34,10 44,28 32,44 16,36 24,20 42,20 ^66,30", 1.1)
        return g
    }
}

nonisolated extension DoodleSports {
    static func littles() -> [DoodleGlyph] {
        [tapeRoll(), dart(), starPatch(), cueChalk(), playArrow(), tinyFlagMark()]
    }

    static func tapeRoll() -> DoodleGlyph {
        var g = DoodleGlyph("tapeRoll", 0.06, 0.125, tilt: 24)
        // A roll of athletic tape with its loose end.
        g.shape(-1, "^36,62 ^106,66 ^102,78 ^112,84 ^36,76 z", 1.1)
        g.shape(-1, .circle(40, 40, 36), 1.45)
        g.shape(0, .circle(40, 40, 15), 1.1)
        g.detail(0.09) { g in
            g.line(.circle(40, 40, 25), 0.42)
            g.gel("^14,30 ^22,16", 0.9)
        }
        return g
    }

    static func dart() -> DoodleGlyph {
        var g = DoodleGlyph("dart", 0.06, 0.125, tilt: 34)
        // A single dart: flights, barrel, point.
        g.shape(0, "^4,4 ^26,14 ^36,36 ^14,26 z", 1.1)
        g.shape(2, "^4,4 ^14,26 ^36,36 ^26,14 z", 0.7)
        g.shape(1, DoodlePath.taper([(34, 34), (66, 66)], 6, 10), 1.25)
        g.line("^66,66 ^98,98", 1.1)
        return g
    }

    static func starPatch() -> DoodleGlyph {
        var g = DoodleGlyph("starPatch", 0.06, 0.125, tilt: 20)
        // A sew-on team patch.
        g.shape(1, DoodleKit.gon(50, 50, 46, sides: 6, rot: 0), 1.45)
        g.shape(2, DoodleFillers.starPath(50, 50, 30), 1.05)
        g.detail(0.09) { $0.stitch(DoodleKit.gon(50, 50, 38, sides: 6, rot: 0), dash: 2.4, gap: 2.4, w: 0.42) }
        return g
    }

    static func cueChalk() -> DoodleGlyph {
        var g = DoodleGlyph("cueChalk", 0.06, 0.12, tilt: 20)
        // A cube of cue chalk with its worn hollow.
        g.shape(1, "^10,28 ^40,10 ^78,20 ^48,40 z", 1.2)
        g.shape(0, "^10,28 ^48,40 ^48,84 ^10,70 z", 1.25)
        g.shape(-1, "^48,40 ^78,20 ^78,62 ^48,84 z", 1.25)
        g.accent(.ellipse(44, 25, 10, 5))
        return g
    }

    static func playArrow() -> DoodleGlyph {
        var g = DoodleGlyph("playArrow", 0.03, 0.065, tilt: 24)
        g.line("^0,44 12,18 36,14 ^58,28", 1.2)
        g.blot("^66,36 ^50,34 ^60,20 z")
        return g
    }

    static func tinyFlagMark() -> DoodleGlyph {
        var g = DoodleGlyph("tinyFlagMark", 0.028, 0.055, tilt: 12)
        g.line("^10,4 ^10,62", 1.3)
        g.shape(0, "^10,4 ^44,12 ^34,20 ^44,30 ^10,30 z", 1)
        return g
    }
}

nonisolated extension DoodleLilac {
    static func littles() -> [DoodleGlyph] {
        [hairPin(), cowrie(), starRing(), thimble(), tinyWave(), tinyDiamond()]
    }

    static func hairPin() -> DoodleGlyph {
        var g = DoodleGlyph("hairPin", 0.06, 0.125, tilt: 38)
        // A long hair pin with a star and two pearls on it.
        g.line("^44,40 ^40,128", 1.1)
        g.line("^56,40 ^54,120", 1.1)
        g.shape(1, DoodleFillers.starPath(50, 26, 24), 1.25)
        g.shape(-1, .circle(50, 26, 6), 0.75)
        g.shape(-1, .circle(20, 48, 6), 0.8)
        g.shape(-1, .circle(80, 48, 6), 0.8)
        return g
    }

    static func cowrie() -> DoodleGlyph {
        var g = DoodleGlyph("cowrie", 0.06, 0.12, tilt: 40)
        // A cowrie, its toothed slit down the middle.
        g.shape(-1, "50,4 76,18 84,50 72,84 50,96 28,84 16,50 24,18 z", 1.45)
        g.tint(0, "50,4 76,18 84,50 72,84 50,96 ^60,70 ^60,30 z")
        g.line("^50,12 54,50 ^50,88", 0.9)
        g.detail(0.09) { g in
            for y in stride(from: 24.0, through: 76, by: 11) {
                g.line(.poly([(46, y), (54, y)]), 0.5)
            }
            g.gel("^28,36 ^26,58", 0.9)
        }
        return g
    }

    static func starRing() -> DoodleGlyph {
        var g = DoodleGlyph("starRing", 0.06, 0.125, tilt: 22)
        // A slim ring with a star-cut stone.
        g.band(1, outer: .circle(46, 68, 34), inner: .circle(46, 68, 25), 1.25, innerW: 0.8)
        g.shape(0, "^46,6 ^68,24 ^46,46 ^24,24 z", 1.25)
        g.line("^24,24 ^68,24", 0.5)
        g.line("^46,6 ^38,24 ^46,46 ^54,24 z", 0.42)
        return g
    }

    static func thimble() -> DoodleGlyph {
        var g = DoodleGlyph("thimble", 0.06, 0.115, tilt: 16)
        // A silver thimble and a dot-punched crown, a thread beside it.
        g.shape(-1, "^24,14 44,4 ^64,14 ^78,84 ^10,84 z", 1.4)
        g.shape(2, .rrect(6, 80, 76, 12, 3), 1.1)
        g.detail(0.09) { g in
            for (x, y) in [(36.0, 18.0), (46, 14), (56, 18), (32, 30), (44, 28), (56, 30), (28, 44), (42, 42), (56, 44), (66, 42), (24, 58), (40, 58), (54, 58), (68, 58)] {
                g.blot(.circle(x, y, 1.2))
            }
        }
        g.line("^84,82 96,66 ^88,50", 0.65)
        return g
    }

    static func tinyWave() -> DoodleGlyph {
        var g = DoodleGlyph("tinyWave", 0.03, 0.06, tilt: 16)
        g.line("^0,20 12,8 24,20 36,8 48,20 ^60,8", 1.1)
        return g
    }

    static func tinyDiamond() -> DoodleGlyph {
        var g = DoodleGlyph("tinyDiamond", 0.024, 0.05, tilt: 24)
        g.shape(0, "^24,0 ^48,30 ^24,60 ^0,30 z", 1)
        return g
    }
}

nonisolated extension DoodleTravel {
    static func littles() -> [DoodleGlyph] {
        [filmRoll(), bottleMessage(), paperPlane(), cocktail(), tinyCompass(), tinySail()]
    }

    static func filmRoll() -> DoodleGlyph {
        var g = DoodleGlyph("filmRoll", 0.06, 0.125, tilt: 22)
        // A roll of film with its strip pulled out.
        g.shape(0, "^52,30 ^112,30 ^112,74 ^52,74 z", 1.25)
        for x in stride(from: 58.0, through: 106, by: 10) {
            g.blot(.rrect(x, 33, 4.4, 3.2, 0.6))
            g.blot(.rrect(x, 68, 4.4, 3.2, 0.6))
        }
        g.shape(-1, .rrect(10, 16, 44, 72, 4), 1.4)
        g.shape(1, .rrect(6, 8, 52, 12, 2), 1.15)
        g.shape(1, .rrect(6, 84, 52, 12, 2), 1.15)
        g.shape(2, .rrect(22, -2, 20, 10, 1.5), 0.9)
        return g
    }

    static func bottleMessage() -> DoodleGlyph {
        var g = DoodleGlyph("bottleMessage", 0.07, 0.125, tilt: 30)
        // A corked bottle with a rolled note inside, floating.
        g.shape(1, .rrect(102, 26, 16, 16, 2), 1.1)
        g.shape(2, "^10,14 ^76,14 ^90,28 ^104,28 ^104,40 ^90,40 ^76,56 ^10,56 2,44 ^2,26 z", 1.45)
        g.shape(-1, "^24,28 ^62,24 ^64,42 ^26,46 z", 1)
        g.line("^32,34 ^54,32", 0.42)
        g.line("^32,39 ^48,38", 0.42)
        g.gel("^10,22 ^26,20", 0.9)
        g.line("^-8,66 8,62 ^24,66", 0.8)
        g.line("^46,68 62,64 ^88,68", 0.8)
        return g
    }

    static func paperPlane() -> DoodleGlyph {
        var g = DoodleGlyph("paperPlane", 0.06, 0.125, tilt: 18)
        // A folded paper plane and its looping dashed path.
        g.shape(-1, "^4,48 ^108,4 ^62,88 ^46,62 z", 1.4)
        g.shape(0, "^46,62 ^108,4 ^52,86 z", 1)
        g.line("^46,62 ^108,4", 0.6)
        g.stitch("^0,74 -14,92 ^12,108", dash: 3, gap: 3, w: 0.7)
        return g
    }

    static func cocktail() -> DoodleGlyph {
        var g = DoodleGlyph("cocktail", 0.06, 0.125, tilt: 10)
        // A tall beach drink with a paper parasol and a slice on the rim.
        g.shape(0, "^12,46 ^68,46 ^58,108 ^22,108 z", 1.45)
        g.tint(1, "^18,80 ^62,80 ^58,108 ^22,108 z")
        g.shape(1, .circle(70, 44, 12), 1)
        g.line("^40,52 ^22,16", 0.8)
        g.shape(2, "^2,22 16,6 ^38,4 ^40,12 z", 1)
        g.detail(0.09) { $0.gel("^20,56 ^24,84", 0.9) }
        return g
    }

    static func tinyCompass() -> DoodleGlyph {
        var g = DoodleGlyph("tinyCompass", 0.028, 0.06, tilt: 30)
        g.shape(2, "^30,0 ^38,22 ^60,30 ^38,38 ^30,60 ^22,38 ^0,30 ^22,22 z", 1)
        return g
    }

    static func tinySail() -> DoodleGlyph {
        var g = DoodleGlyph("tinySail", 0.03, 0.065, tilt: 10)
        g.shape(0, "^28,0 ^52,40 ^28,40 z", 1)
        g.shape(1, "^4,46 ^60,46 ^50,60 ^14,60 z", 1)
        return g
    }
}

nonisolated extension DoodleCafe {
    static func littles() -> [DoodleGlyph] {
        [macaron(), sugarPacket(), cherryPair(), bookmark(), tinyCup(), tinyBook()]
    }

    static func macaron() -> DoodleGlyph {
        var g = DoodleGlyph("macaron", 0.06, 0.125, tilt: 22)
        // Two domes, a ruffled foot on each, a cream filling.
        g.shape(-1, .rrect(8, 42, 84, 14, 5), 1.15)
        g.shape(2, "^6,42 12,20 34,8 ^66,8 88,20 ^94,42 z", 1.4)
        g.shape(2, "^6,56 ^94,56 88,74 ^66,84 ^34,84 12,74 z", 1.4)
        g.detail(0.09) { g in
            g.gel("^24,24 ^40,16", 0.9)
            g.stitch("^8,38 ^92,38", dash: 2, gap: 2, w: 0.42)
        }
        return g
    }

    static func sugarPacket() -> DoodleGlyph {
        var g = DoodleGlyph("sugarPacket", 0.06, 0.125, tilt: 28)
        // A paper sugar sachet, its end torn, a spill of grains.
        g.shape(-1, "^4,6 ^44,4 ^48,10 ^56,4 ^62,10 ^68,6 ^70,62 ^6,66 z", 1.4)
        g.tint(0, "^5,24 ^69,22 ^69,44 ^6,46 z")
        g.shape(-1, K.puff(37, 34, 12, 8, n: 7, depth: 0.14), 0.7)
        g.detail(0.09) { $0.speckle(70, 8, 92, 30, n: 8, r: 0.8, seed: 41) }
        return g
    }

    static func cherryPair() -> DoodleGlyph {
        var g = DoodleGlyph("cherryPair", 0.06, 0.12, tilt: 18)
        // Two cherries on one stem, a leaf at the fork.
        g.line("^26,56 38,26 ^62,6", 1)
        g.line("^74,62 72,32 ^62,6", 1)
        g.shape(1, K.leaf((62, 6), (94, 12), belly: 12), 1)
        g.shape(2, .circle(24, 74, 20), 1.35)
        g.shape(2, .circle(74, 80, 20), 1.35)
        g.detail(0.09) { g in
            g.gel("^12,68 ^18,60", 0.9)
            g.gel("^62,74 ^68,66", 0.9)
        }
        return g
    }

    static func bookmark() -> DoodleGlyph {
        var g = DoodleGlyph("bookmark", 0.07, 0.125, tilt: 18)
        // A swallow-tailed ribbon bookmark with a stitched edge and a small heart.
        g.shape(0, "^8,2 ^52,2 ^52,118 ^30,100 ^8,118 z", 1.4)
        g.shape(-1, DoodleFillers.heartPath(30, 38, 13), 0.8)
        g.detail(0.09) { g in
            g.stitch("^14,8 ^14,104", dash: 2.4, gap: 2.4, w: 0.42)
            g.stitch("^46,8 ^46,104", dash: 2.4, gap: 2.4, w: 0.42)
        }
        return g
    }

    static func tinyCup() -> DoodleGlyph {
        var g = DoodleGlyph("tinyCup", 0.03, 0.065, tilt: 10)
        g.shape(-1, "^4,8 ^48,8 44,36 ^34,44 ^18,44 8,36 z", 1.1)
        g.line("^48,14 60,14 58,28 ^46,30", 0.95)
        return g
    }

    static func tinyBook() -> DoodleGlyph {
        var g = DoodleGlyph("tinyBook", 0.03, 0.065, tilt: 18)
        g.shape(1, "^6,4 ^48,4 ^48,56 ^6,56 z", 1.1)
        g.line("^14,4 ^14,56", 0.8)
        return g
    }
}
