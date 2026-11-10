// The Lilac drawings: moonlit, soft, a little storybook. Spot colours: 0 is orchid, 1 is butter gold, 2 is seafoam; bare paper is pearl.
// Nothing here repeats a Rose drawing: the butterflies are swallowtails, the bows trail ribbons, the perfume is a moon, the shells come from the sea.

import CoreGraphics
import Foundation

nonisolated enum DoodleLilac {
    typealias K = DoodleKit

    static func all() -> [DoodleGlyph] {
        var list = [swan(), hangingMoon(), swallowtail(), crystals(), teapot(), moonPerfume(), clam(), lunaMoth(), streamingRibbon(), stackedCups(), jellyfish(), birdcage(),
                    harp(), parasol(), moonCup(), tearPerfume(), scallop(), conch(), whelk(), slippers(), wand(), moonKey(), cloud(), phases(), shootingStar(), constellation(),
                    lantern(), moonCandle(), dragonfly(), iris(), wisteria(), lavender(), lilyValley(), violet(), mushrooms(), seahorse(), starfish(), coral(), potion(), moonCard(),
                    sleepyCat(), amethyst(), pendant(), plume(), snowGlobe(), dove(), musicBox(), wings(), plainBow(), sugarBowl(), tinyButterfly(),
                    tinyStar(), tinyCrescent(), tinyHeart(), bubbles(), sparkleMark(), tinyPearl(), tinyPetal()]
        list += DoodleFillers.common().filter { ["dot"].contains($0.name) }
        list += extras() + littles()
        for i in list.indices {
            list[i].fixed = true
            list[i].done()
        }
        return list
    }

    static func swan() -> DoodleGlyph {
        var g = DoodleGlyph("swan", 0.28, 0.46, tilt: 5)
        g.must = true
        // Neck first, so the body tucks over its root.
        g.shape(-1, DoodlePath.taper([(36, 16), (46, 22), (54, 36), (50, 52), (40, 66), (40, 82)], 7, 15), 1.3)
        // The little crown on the head.
        g.shape(1, "^28,6 ^29,-3 ^34,2 ^38,-5 ^42,2 ^47,-3 ^47,7 z", 0.95)
        g.shape(-1, .ellipse(36, 14, 13, 10, rot: -6), 1.3)
        g.shape(1, "^24,10 ^4,18 ^25,20 z", 1.15)
        g.accent("^24,9 ^17,13 ^20,18 ^26,17 z")
        g.blot(.circle(31, 12, 1.7))
        // Body, tail turned up at the right.
        g.shape(-1, "^34,78 30,92 42,108 74,116 106,110 128,92 ^150,62 ^128,74 ^112,68 84,70 56,72 z", 1.5)
        // The raised wing, feather on feather.
        g.shape(-1, "^52,84 62,60 86,44 112,42 ^136,26 ^130,48 ^138,50 ^124,64 ^128,70 110,86 82,96 60,94 z", 1.35)
        g.tint(0, "^90,44 112,42 ^136,26 ^130,48 ^138,50 ^124,64 ^128,70 ^122,70 116,67 ^112,64 106,62 ^100,56 94,51 z")
        g.line("^90,44 94,51 ^100,56 106,62 ^112,64 116,67 ^122,70", 0.55)
        g.line("^62,84 78,66 ^100,56", 0.7)
        g.line("^74,90 92,74 ^112,64", 0.7)
        g.line("^88,92 104,80 ^122,68", 0.7)
        g.detail(0.26) { g in
            g.line("^100,56 ^120,44", 0.42)
            g.line("^112,64 ^130,48", 0.42)
            g.line("^60,90 ^68,78", 0.42)
            g.gel("^42,42 ^38,62", 0.9)
            g.hatch("^48,96 ^112,104 ^92,114 ^60,112 z", angle: 12, gap: 3, w: 0.42)
        }
        // Still water with a scatter of petals.
        g.line("^10,118 34,114 60,120 ^86,118", 0.85)
        g.line("^92,122 116,118 140,122 ^156,118", 0.85)
        g.line("^40,128 66,124 ^92,128", 0.6)
        g.line("^108,130 ^132,128", 0.6)
        g.shape(0, K.leaf((20, 104), (6, 108), belly: 7), 0.75)
        return g
    }

    static func hangingMoon() -> DoodleGlyph {
        var g = DoodleGlyph("hangingMoon", 0.24, 0.44, tilt: 8)
        g.must = true
        g.noFlip = true
        // It hangs from a bow on a thread, with stars and a pearl on threads of their own.
        g.line("^52,-22 ^50,6", 0.75)
        g.shape(0, "^52,-20 34,-30 ^28,-20 ^52,-20 ^74,-30 ^78,-20 z", 0.95)
        g.blot(.circle(52, -20, 2.4))
        g.shape(1, K.crescent(50, 50, 46, bite: 0.42, rot: -14), 1.55)
        g.detail(0.2) { g in
            // Soft craters in the belly of the moon.
            g.line(.circle(16, 48, 3.4), 0.5)
            g.line(.circle(20, 66, 2.4), 0.5)
            g.blot(.circle(13, 62, 1.1))
            g.blot(.circle(32, 80, 1.1))
            g.blot(.circle(44, 88, 1.4))
            g.gel("10,44 13,28 ^24,16", 1)
            g.hatch("^36,90 ^52,92 ^62,92 ^46,98 ^30,94 z", angle: 30, gap: 2.8, w: 0.42)
        }
        for (x, y0, y1, r, s) in [(58.0, 40.0, 78.0, 13.0, 0), (78.0, 26.0, 62.0, 10.0, -1), (94.0, 44.0, 92.0, 11.0, 1)] {
            g.line(.poly([(x, y0), (x, y1 - r * 0.8)]), 0.55)
            g.shape(s, DoodleFillers.starPath(x, y1, r), 1)
        }
        g.line("^70,46 ^70,98", 0.55)
        g.shape(-1, .circle(70, 103, 5.4), 0.85)
        return g
    }

    static func swallowtail() -> DoodleGlyph {
        var g = DoodleGlyph("swallowtail", 0.24, 0.44, tilt: 22)
        g.must = true
        g.noFlip = true
        g.mirror(60) { g in
            // Hindwing first, with its long tail.
            g.shape(1, "^60,58 44,58 24,62 12,76 16,92 28,100 ^26,124 ^36,108 ^42,96 54,84 ^60,68 z", 1.4)
            // Forewing over it.
            g.shape(0, "^60,44 46,24 22,6 ^-4,-2 -10,14 -6,36 8,56 32,64 ^60,56 z", 1.5)
            // Veins and the dark margin with its row of pearls.
            g.accent("^-4,-2 ^-10,14 ^-6,36 ^8,56 ^16,52 ^4,34 ^0,16 ^4,4 z")
            for (x, y, r) in [(-1.0, 14.0, 2), (2.0, 28.0, 2.4), (9.0, 42.0, 2.4), (18.0, 52.0, 2)] as [(Double, Double, Double)] {
                g.shape(-1, .circle(x, y, r), 0.42)
            }
            g.line("^58,48 30,30 ^8,8", 0.65)
            g.line("^58,50 34,44 ^6,28", 0.65)
            g.line("^58,53 38,56 ^16,48", 0.65)
            g.shape(-1, .ellipse(34, 18, 6.4, 4, rot: 34), 0.65)
            g.line("^58,62 40,70 ^24,78", 0.6)
            g.line("^58,66 46,78 ^36,92", 0.6)
            g.shape(0, .circle(26, 88, 5), 0.7)
            g.blot(.circle(26, 88, 1.8))
            g.detail(0.24) { g in
                g.stitch("^16,72 20,88 ^30,96", dash: 1.8, gap: 1.8, w: 0.42)
                g.gel("^20,22 ^40,34", 0.8)
            }
        }
        // Body, head, curling antennae.
        g.shape(1, .ellipse(60, 58, 3.8, 22), 1.1)
        g.detail(0.2) { g in
            for y in [50.0, 56.0, 62.0, 68.0] { g.line(.poly([(56.6, y), (63.4, y)]), 0.42) }
        }
        g.shape(1, .circle(60, 33, 4.2), 1)
        g.line("^58,30 48,14 ^40,10", 0.65)
        g.line("^62,30 72,14 ^80,10", 0.65)
        g.blot(.circle(40, 10, 1.5))
        g.blot(.circle(80, 10, 1.5))
        return g
    }

    static func crystals() -> DoodleGlyph {
        var g = DoodleGlyph("crystals", 0.22, 0.42, tilt: 10)
        g.must = true
        // A cluster of quartz points on a rough stone.
        func point(_ g: inout DoodleGlyph, sep: Int, x: Double, base: Double, tip: Double, w: Double, lean: Double, size: Double = 1.4) {
            let cx = x + lean, s = tip + w * 1.1
            let lb = (x - w, base), rb = (x + w, base)
            let lt = (cx - w * 0.92, s), rt = (cx + w * 0.92, s)
            let a = (cx - w * 0.14, s - w * 0.2)
            let t = (cx + w * 0.12, tip)
            g.shape(sep, .poly([lb, lt, t, rt, rb], closed: true), size)
            g.line(.poly([lt, a, t]), 0.65)
            g.line(.poly([a, rt]), 0.65)
            g.line(.poly([a, (x - w * 0.14, base)]), 0.65)
            g.detail(0.2) { g in
                g.gel(.poly([(cx - w * 0.6, s + 4), (x - w * 0.62, base - 8)]), 0.9)
                g.hatch(.poly([(cx + w * 0.34, s + 3), (cx + w * 0.86, s + 4), (x + w * 0.86, base), (x + w * 0.3, base)], closed: true), angle: 72, gap: 2.9, w: 0.42)
            }
        }
        point(&g, sep: 2, x: 20, base: 110, tip: 54, w: 11, lean: -9)
        point(&g, sep: 1, x: 88, base: 110, tip: 40, w: 12, lean: 10)
        point(&g, sep: 0, x: 54, base: 110, tip: -2, w: 19, lean: 0, size: 1.55)
        point(&g, sep: -1, x: 34, base: 112, tip: 46, w: 10, lean: -4)
        point(&g, sep: 0, x: 70, base: 112, tip: 58, w: 10, lean: 5)
        // The stone they grow from.
        g.shape(1, "^-2,106 10,98 ^26,104 ^42,96 ^60,104 ^78,96 ^96,102 ^108,98 ^118,110 112,124 88,130 40,132 8,126 z", 1.45)
        g.line("14,117 28,113 ^44,119", 0.6)
        g.line("62,121 78,115 ^94,119", 0.6)
        g.detail(0.2) { $0.speckle(12, 112, 104, 128, n: 16, r: 0.55, seed: 11) }
        g.shape(1, DoodleFillers.sparklePath(102, 20, 11), 0.85)
        g.shape(-1, DoodleFillers.sparklePath(12, 30, 7), 0.75)
        return g
    }

    static func teapot() -> DoodleGlyph {
        var g = DoodleGlyph("teapot", 0.22, 0.42, tilt: 7)
        g.must = true
        // Spout and handle under the body; a round moon-spotted belly; lid with a star finial.
        g.shape(-1, "^108,60 124,52 132,36 ^137,14 ^150,17 147,38 137,62 ^110,90 z", 1.4)
        g.band(1, outer: "^28,50 4,44 -8,60 -4,80 18,94 ^32,90 ^30,80 12,74 8,60 14,52 ^30,60 z", inner: "^28,50 ^28,50 ^28,50 z", 1.3, innerW: 0)
        g.shape(-1, "^22,46 10,70 14,96 34,116 68,124 98,116 118,96 122,70 ^110,46 z", 1.55)
        g.shape(0, "^22,46 ^110,46 ^119,62 92,68 66,70 40,68 ^13,62 z", 1)
        g.detail(0.2) { g in
            g.stitch("^19,57 42,62 66,63 90,62 ^114,57", dash: 2, gap: 2.2, w: 0.5)
            g.hatch("^88,72 ^118,68 ^112,96 ^88,114 ^76,118 z", angle: 66, gap: 3.2, w: 0.42)
            g.gel("^24,74 ^28,92", 1)
        }
        // Moon and stars painted on the belly.
        g.shape(1, DoodleFillers.starPath(66, 86, 15), 1)
        g.shape(0, DoodleFillers.starPath(92, 80, 6.4), 0.75)
        g.shape(0, DoodleFillers.starPath(38, 80, 5.6), 0.7)
        g.line("^28,102 36,98 44,102 52,98 60,102 68,98 76,102 84,98 92,102 ^102,98", 0.7)
        g.line("^38,110 46,106 54,110 62,106 70,110 78,106 86,110 ^92,106", 0.55)
        // Lid.
        g.shape(0, "^24,46 34,30 66,24 96,30 ^108,46 z", 1.35)
        g.shape(1, .ellipse(66, 25, 10, 3.5), 0.85)
        g.shape(1, DoodleFillers.starPath(66, 12, 10), 0.95)
        g.detail(0.2) { $0.gel("^38,38 ^54,31", 0.8) }
        // A wisp of steam, and a foot.
        g.shape(1, "^38,120 ^94,120 ^102,130 ^30,130 z", 1.15)
        g.line("138,6 146,-4 140,-14 ^148,-24", 0.75)
        return g
    }

    static func moonPerfume() -> DoodleGlyph {
        var g = DoodleGlyph("moonPerfume", 0.2, 0.38, tilt: 12)
        g.must = true
        // A round bottle, a tall cap, a bulb on a braided hose.
        g.line("18,58 4,52 -8,34 ^-4,20", 0.9)
        g.shape(0, .ellipse(-6, 12, 9, 11), 1.15)
        g.shape(1, "^46,28 ^70,28 ^72,40 ^44,40 z", 1.2)
        g.shape(0, "^44,0 58,-8 ^72,0 ^76,14 ^76,28 ^40,28 ^40,14 z", 1.35)
        g.detail(0.18) { g in
            g.line("^52,0 ^50,26", 0.42)
            g.line("^64,0 ^66,26", 0.42)
            g.gel("^46,8 ^45,20", 0.8)
        }
        g.shape(-1, .circle(58, 86, 47), 1.55)
        g.tint(0, "^14,96 28,88 46,92 66,86 84,90 ^102,86 96,112 76,128 50,132 26,120 z")
        g.line("^14,96 28,88 46,92 66,86 84,90 ^102,86", 0.75)
        g.shape(1, K.crescent(58, 76, 26, bite: 0.42, rot: -22), 1.2)
        g.shape(-1, DoodleFillers.starPath(64, 76, 8), 0.75)
        g.detail(0.18) { g in
            g.gel("18,76 22,60 ^32,50", 1.1)
            g.blot(.circle(24, 106, 1.4))
            g.blot(.circle(38, 118, 1.2))
            g.blot(.circle(84, 108, 1.4))
            g.blot(.circle(74, 118, 1))
        }
        // The tiny label tag on a thread.
        g.line("^44,40 28,46 ^24,54", 0.6)
        return g
    }

    static func tearPerfume() -> DoodleGlyph {
        var g = DoodleGlyph("tearPerfume", 0.13, 0.3, tilt: 12)
        // A teardrop bottle with a pointed stopper and a tassel.
        g.shape(0, "^28,-8 ^36,-2 34,10 ^28,18 ^22,10 20,-2 z", 1.2)
        g.shape(1, .rrect(21, 18, 14, 10, 1.5), 1.1)
        g.shape(-1, "28,28 44,44 54,66 50,88 28,104 6,88 2,66 12,44 z", 1.5)
        g.tint(0, "^4,76 ^52,76 50,88 28,104 6,88 z")
        g.line("^4,76 16,73 28,77 40,73 ^52,76", 0.6)
        g.line("28,34 20,54 ^16,82", 0.5)
        g.line("28,34 36,54 ^40,82", 0.5)
        g.detail(0.16) { $0.gel("^10,62 ^14,48", 1) }
        // The tassel, swinging off the neck.
        g.line("^21,24 6,30 ^-6,46", 0.7)
        g.shape(1, .circle(-7, 50, 4.2), 0.8)
        g.shape(1, "^-11,53 ^-3,53 ^0,74 ^-14,74 z", 0.85)
        for x in [-10.0, -7.0, -4.0] { g.line(.poly([(x, 56), (x * 1.1, 72)]), 0.42) }
        return g
    }

    static func clam() -> DoodleGlyph {
        var g = DoodleGlyph("clam", 0.2, 0.4, tilt: 8)
        g.must = true
        let hinge = (60.0, 96.0)
        // Lower shell, open, then the pearl, then the fan of the upper shell behind it.
        var top: [DoodlePath.Node] = []
        top += [.init(x: 12, y: 74, corner: true)]
        let n = 7
        for i in 0..<n {
            let a0 = 200.0 + Double(i) * 140 / Double(n), a1 = a0 + 70 / Double(n)
            let p0 = K.polar(60, 64, 54, a0), p1 = K.polar(60, 64, 57, a1)
            top.append(.init(x: p0.0, y: p0.1, corner: true))
            top.append(.init(x: p1.0, y: p1.1, corner: false))
        }
        top.append(.init(x: 110, y: 74, corner: true))
        top.append(.init(x: hinge.0, y: hinge.1, corner: true))
        g.shape(0, DoodlePath(nodes: top, closed: true), 1.5)
        for i in 1..<n {
            let a = 200.0 + Double(i) * 140 / Double(n)
            let p = K.polar(60, 64, 53, a)
            g.line(.poly([(hinge.0, hinge.1 - 6), p]), 0.7)
        }
        g.shape(-1, "^4,78 14,68 40,66 60,70 80,66 106,68 ^116,78 108,92 ^60,92 12,92 z", 1)
        g.accent(.ellipse(60, 79, 38, 8))
        g.shape(-1, .circle(60, 68, 15), 1.4)
        g.gel("50,66 52,60 ^58,57", 1)
        // The lower dish.
        g.shape(0, "^2,78 20,84 60,88 100,84 ^118,78 108,104 84,122 ^60,128 36,122 12,104 z", 1.5)
        for (x, _) in [(20.0, 0), (36.0, 0), (84.0, 0), (100.0, 0), (60.0, 0)] {
            g.line(.poly([(x, 88), (60 + (x - 60) * 0.42, 124)]), 0.65)
        }
        g.detail(0.2) { g in
            g.hatch("^88,92 ^108,88 ^96,108 ^78,120 z", angle: 66, gap: 3, w: 0.42)
            g.gel("^12,88 ^22,104", 0.9)
        }
        return g
    }

    static func lunaMoth() -> DoodleGlyph {
        var g = DoodleGlyph("lunaMoth", 0.18, 0.36, tilt: 14)
        g.noFlip = true
        g.mirror(50) { g in
            // Long trailing hindwings.
            g.shape(2, "^50,48 34,48 18,56 14,74 24,84 ^28,108 ^20,128 ^34,128 ^40,96 ^46,72 z", 1.35)
            g.shape(2, "^50,38 34,16 8,2 ^-6,6 ^-2,22 8,40 30,52 ^50,50 z", 1.45)
            g.line("^-6,6 8,2 ^34,16", 1.05)
            g.shape(1, .circle(24, 30, 5.4), 0.8)
            g.shape(1, .circle(30, 68, 4.6), 0.75)
            g.blot(.circle(24, 30, 2))
            g.blot(.circle(30, 68, 1.6))
            g.line("^46,44 ^10,14", 0.5)
            g.line("^46,54 26,60 ^20,76", 0.5)
            g.line("^46,60 36,88 ^28,118", 0.5)
            // Feathered antennae.
            g.line("^47,28 38,14 ^28,8", 0.7)
            g.detail(0.18) { g in
                for t in [0.25, 0.5, 0.75] {
                    let x = 47 - t * 19, y = 28 - t * 20
                    g.line(.poly([(x, y), (x - 6, y + 3)]), 0.42)
                    g.line(.poly([(x, y), (x + 2, y - 6)]), 0.42)
                }
            }
        }
        g.shape(-1, .ellipse(50, 42, 8, 19), 1.2)
        g.detail(0.18) { g in
            for y in [32.0, 38.0, 44.0, 50.0] { g.line(.poly([(44, y), (56, y)]), 0.42) }
        }
        return g
    }

    static func streamingRibbon() -> DoodleGlyph {
        var g = DoodleGlyph("streamingRibbon", 0.16, 0.38, tilt: 22)
        // One long satin ribbon waving in three runs. Where it folds back you see its underside, in shadow.
        let back1 = DoodlePath.taper([(74, 25), (66, 38), (50, 50), (34, 54)], 11, 12)
        let back2 = DoodlePath.taper([(118, 66), (110, 80), (94, 92), (78, 96)], 11, 12)
        g.shape(1, back1, 1.1)
        g.shade(back1)
        g.shape(1, back2, 1.1)
        g.shade(back2)
        // The notched tail at the top, then the first run.
        g.shape(0, "^-16,4 ^4,10 ^10,34 ^-10,30 ^-2,18 z", 1.25)
        g.shape(0, DoodlePath.taper([(2, 22), (22, 32), (46, 32), (64, 24), (78, 22)], 12, 13), 1.35)
        // The middle run.
        g.shape(0, DoodlePath.taper([(30, 52), (52, 60), (76, 66), (100, 66), (122, 62)], 13, 13), 1.35)
        // The last run and its notched tail.
        g.shape(0, DoodlePath.taper([(74, 96), (96, 106), (120, 112), (142, 108)], 13, 12), 1.35)
        g.shape(0, "^138,100 ^166,92 ^156,108 ^170,120 ^142,116 z", 1.25)
        g.detail(0.16) { g in
            g.line("^6,22 24,28 46,28 ^68,20", 0.42)
            g.line("^38,50 56,56 78,60 ^112,59", 0.42)
            g.line("^82,92 98,100 ^134,104", 0.42)
            g.gel("^26,36 ^38,37", 0.8)
            g.gel("^60,68 ^74,71", 0.8)
            g.gel("^104,112 ^116,114", 0.8)
        }
        return g
    }

    static func stackedCups() -> DoodleGlyph {
        var g = DoodleGlyph("stackedCups", 0.16, 0.36, tilt: 8)
        g.noFlip = true
        func cup(_ g: inout DoodleGlyph, y: Double, x: Double, sep: Int, trim: Int, w: Double) {
            let P = { (s: DoodlePath) in s.scaled(w, about: (50, 20)).moved(x - 50, y - 20) }
            g.shape(sep, P("^10,0 ^90,0 88,18 72,36 ^28,36 12,18 z"), 1.35)
            g.band(sep, outer: P("^88,6 106,4 112,14 104,26 ^80,30 ^82,22 98,20 102,14 98,11 ^88,13 z"), inner: P("^88,6 ^88,6 ^88,6 z"), 1.1, innerW: 0)
            g.tint(trim, P("^10,0 ^90,0 ^89,8 ^11,8 z"))
            g.line(P("^11,8 ^89,8"), 0.6)
            g.shape(trim, P("^20,36 ^80,36 ^86,42 ^14,42 z"), 1.05)
            g.detail(0.16) { g in
                g.hatch(P("^68,12 ^86,10 ^80,26 ^66,34 z"), angle: 62, gap: 2.8, w: 0.42)
            }
        }
        cup(&g, y: 96, x: 50, sep: -1, trim: 0, w: 1.15)
        g.shape(2, DoodleFillers.starPath(50, 118, 8), 0.75)
        cup(&g, y: 54, x: 42, sep: 0, trim: 1, w: 1)
        g.line("^26,72 32,68 38,72 44,68 50,72 ^56,68", 0.7)
        cup(&g, y: 16, x: 56, sep: 2, trim: 0, w: 0.86)
        g.shape(-1, DoodleFillers.sparklePath(56, 32, 7), 0.65)
        // The curl of steam off the top.
        g.line("54,8 60,-2 54,-10 ^60,-20", 0.7)
        return g
    }

    static func moonCup() -> DoodleGlyph {
        var g = DoodleGlyph("moonCup", 0.14, 0.32, tilt: 10)
        // A wide teacup with a moon on its side, a scalloped saucer, a spoon.
        g.band(1, outer: "^92,18 110,14 118,26 108,42 ^84,48 ^86,38 102,34 106,26 102,23 ^92,26 z", inner: "^92,18 ^92,18 ^92,18 z", 1.15, innerW: 0)
        g.shape(-1, "^8,10 ^96,10 94,34 80,58 ^24,58 10,34 z", 1.45)
        g.accent(.ellipse(52, 11, 44, 7.5))
        g.shape(0, .ellipse(52, 13, 39, 4.8), 0.8)
        g.shape(0, K.crescent(50, 36, 15, bite: 0.42, rot: -22), 0.95)
        g.shape(1, DoodleFillers.starPath(70, 28, 5.2), 0.7)
        g.shape(1, DoodleFillers.starPath(28, 26, 4.2), 0.65)
        g.detail(0.14) { $0.gel("^16,24 ^20,42", 1) }
        g.shape(0, "^-6,60 8,62 ^22,60 36,62 ^52,60 68,62 ^82,60 96,62 ^110,60 94,70 ^52,72 10,70 z", 1.3)
        return g
    }

    static func jellyfish() -> DoodleGlyph {
        var g = DoodleGlyph("jellyfish", 0.14, 0.38, tilt: 14)
        // A soft bell, frilly hem, ribbon arms and fine trailing threads.
        for (x, c) in [(16.0, 6.0), (30.0, -4.0), (70.0, 4.0), (84.0, -6.0)] {
            g.line(.spline([(x, 54), (x + c, 74), (x - c, 96), (x + c, 118), (x, 136)]), 0.65)
        }
        g.shape(0, "^38,56 34,74 42,90 36,108 ^42,126 ^50,110 54,92 48,74 ^50,56 z", 1.05)
        g.shape(2, "^54,56 62,74 54,92 60,112 ^52,134 ^68,112 72,90 68,72 ^66,56 z", 1.05)
        g.shape(-1, "^4,52 6,26 22,6 50,-2 78,6 94,26 ^96,52 86,58 ^76,52 66,58 ^56,52 46,58 ^36,52 26,58 ^16,52 z", 1.55)
        g.tint(0, "^4,52 6,40 ^20,44 ^36,40 ^50,44 ^66,40 ^82,44 ^94,40 ^96,52 86,58 ^76,52 66,58 ^56,52 46,58 ^36,52 26,58 ^16,52 z")
        g.line("^6,40 20,44 36,40 50,44 66,40 82,44 ^94,40", 0.55)
        g.shape(1, .ellipse(50, 22, 12, 9), 0.85)
        g.detail(0.2) { g in
            g.line("^38,22 ^62,22", 0.42)
            g.gel("14,30 22,16 ^34,8", 1.1)
            g.blot(.circle(26, 30, 1.2))
            g.blot(.circle(72, 30, 1.2))
            g.blot(.circle(78, 22, 0.9))
        }
        return g
    }

    static func birdcage() -> DoodleGlyph {
        var g = DoodleGlyph("birdcage", 0.15, 0.4, tilt: 6)
        g.noFlip = true
        // A domed cage, door ajar, a small bird on the swing.
        g.line(.circle(50, -4, 7), 1.1)
        g.shape(1, .circle(50, 7, 5), 0.95)
        // Bars.
        for x in [18.0, 34.0, 50.0, 66.0, 82.0] {
            let bow = (x - 50) * 0.32
            g.line(.spline([(50, 12), (50 + (x - 50) * 0.7 + bow * 0.2, 22), (x, 52), (x, 110)]), 0.9)
        }
        g.line("^4,64 4,40 18,20 ^50,10 82,20 96,40 ^96,64", 1.2)
        g.line("^4,64 ^4,110", 1.2)
        g.line("^96,64 ^96,110", 1.2)
        g.shape(1, .rrect(1, 62, 98, 5.4, 2), 1)
        // The swing and bird.
        g.line("^38,30 ^36,74", 0.6)
        g.line("^62,30 ^64,74", 0.6)
        g.line("^32,74 ^68,74", 1)
        g.shape(0, "^38,70 34,58 40,46 ^52,42 ^64,38 ^62,48 ^56,50 56,60 50,70 ^44,72 z", 1.2)
        g.shape(1, "^64,40 ^72,44 ^62,47 z", 0.8)
        g.blot(.circle(57, 44, 1.2))
        g.line("^38,70 ^26,84", 0.9)
        g.line("^42,52 ^52,62", 0.55)
        // The base with its scalloped skirt.
        g.shape(1, "^-2,110 ^102,110 ^106,122 ^-6,122 z", 1.35)
        g.shape(0, "^4,122 ^96,122 ^88,134 ^12,134 z", 1.2)
        g.detail(0.2) { g in
            g.stitch("^2,116 ^98,116", dash: 2, gap: 2, w: 0.5)
            g.blot(.circle(50, 128, 1.4))
        }
        return g
    }

    static func harp() -> DoodleGlyph {
        var g = DoodleGlyph("harp", 0.16, 0.36, tilt: 7)
        g.noFlip = true
        // The curved neck, the pillar and sound box, then the strings.
        for (i, x) in stride(from: 26.0, through: 76.0, by: 10).enumerated() {
            let yt = 22.0 + abs(x - 52) * 0.16 + (x > 60 ? (x - 60) * 0.9 : 0)
            let yb = 112.0 - (x - 16) * 0.88
            g.line(.poly([(x, yt), (x, 112 - (x - 16) * 0.86 + 0 * yb)]), 0.5)
            _ = i
        }
        g.shape(1, "^10,6 ^22,4 ^24,118 ^12,118 z", 1.35)
        g.shape(0, "^16,118 ^30,124 ^92,50 ^86,36 z", 1.4)
        g.shape(1, "^12,14 20,2 44,4 62,18 82,22 ^94,12 ^102,22 ^96,46 ^86,44 ^84,32 60,30 40,20 22,20 z", 1.4)
        g.shape(1, .circle(16, 2, 6), 1)
        g.shape(1, .rrect(6, 118, 28, 8, 2), 1.15)
        g.detail(0.16) { g in
            g.gel("^16,30 ^16,84", 0.8)
            g.stitch("^34,106 ^80,52", dash: 1.8, gap: 2, w: 0.5)
            g.blot(.circle(40, 92, 1.3))
            g.blot(.circle(58, 72, 1.3))
        }
        return g
    }

    static func parasol() -> DoodleGlyph {
        var g = DoodleGlyph("parasol", 0.13, 0.38, tilt: 24)
        // A ruffled parasol with a tall curled handle and bow.
        g.line("^56,40 ^56,128 54,138 46,142 ^40,134", 1.25)
        g.line("^56,2 ^56,-10", 1.2)
        g.shape(0, "^4,58 8,34 24,14 ^56,0 88,14 104,34 ^108,58 98,66 ^88,58 78,66 ^68,58 ^56,66 ^44,58 34,66 ^24,58 14,66 z", 1.5)
        g.tint(-1, "^56,0 ^36,58 ^44,58 ^56,66 ^68,58 ^76,58 z")
        g.line("^56,0 ^36,58", 0.75)
        g.line("^56,0 ^76,58", 0.75)
        g.line("^56,0 16,28 ^14,60", 0.75)
        g.line("^56,0 96,28 ^98,60", 0.75)
        g.detail(0.18) { g in
            g.gel("^24,26 ^38,12", 1)
            g.stitch("^10,52 30,50 ^44,52", dash: 1.8, gap: 1.8, w: 0.42)
            g.stitch("^68,52 84,50 ^102,52", dash: 1.8, gap: 1.8, w: 0.42)
        }
        g.shape(1, "^56,86 42,78 ^38,90 ^56,86 ^70,78 ^74,90 z", 0.95)
        g.blot(.circle(56, 86, 2))
        return g
    }

    static func scallop() -> DoodleGlyph {
        var g = DoodleGlyph("scallop", 0.1, 0.26, tilt: 26)
        let c = (50.0, 84.0)
        var nodes: [DoodlePath.Node] = [.init(x: 38, y: 94, corner: true), .init(x: 26, y: 88, corner: true)]
        let n = 7
        for i in 0..<n {
            let a0 = 188.0 + Double(i) * 164 / Double(n), a1 = a0 + 82 / Double(n)
            let p0 = K.polar(c.0, c.1 - 6, 54, a0), p1 = K.polar(c.0, c.1 - 6, 58, a1)
            nodes.append(.init(x: p0.0, y: p0.1, corner: true))
            nodes.append(.init(x: p1.0, y: p1.1, corner: false))
        }
        nodes.append(.init(x: 104, y: 72, corner: true))
        nodes.append(.init(x: 74, y: 88, corner: true))
        nodes.append(.init(x: 62, y: 94, corner: true))
        g.shape(2, DoodlePath(nodes: nodes, closed: true), 1.45)
        for i in 1..<n {
            let a = 188.0 + Double(i) * 164 / Double(n)
            let p = K.polar(c.0, c.1 - 6, 53, a)
            g.line(.poly([(c.0, c.1), p]), 0.7)
        }
        g.detail(0.12) { g in
            g.line(K.arc(50, 78, 38, 38, 195, 345), 0.42)
            g.line(K.arc(50, 78, 24, 24, 200, 340), 0.42)
        }
        return g
    }

    static func conch() -> DoodleGlyph {
        var g = DoodleGlyph("conch", 0.13, 0.32, tilt: 20)
        // Lying on its side: a pointed knobbly spire at the right, a wide pink lip curling open at the left.
        g.shape(1, "^126,34 ^108,26 ^104,16 ^92,24 ^84,8 ^72,20 ^60,2 ^46,18 28,20 ^38,70 ^84,62 ^106,48 z", 1.45)
        g.line("^104,16 110,32 ^106,48", 0.75)
        g.line("^84,8 92,34 ^84,62", 0.75)
        g.line("^60,2 70,36 ^60,68", 0.75)
        g.shape(0, "^44,14 20,10 2,24 -6,48 4,72 ^-2,92 ^22,80 44,76 ^62,70 54,50 ^56,30 z", 1.5)
        g.accent("^40,28 24,30 14,44 18,62 ^10,78 28,66 ^44,62 38,46 z")
        g.detail(0.14) { g in
            g.gel("^6,34 ^12,24", 0.9)
            g.hatch("^72,40 ^102,36 ^92,56 ^72,62 z", angle: 66, gap: 2.8, w: 0.42)
        }
        return g
    }

    static func whelk() -> DoodleGlyph {
        var g = DoodleGlyph("whelk", 0.08, 0.2, tilt: 40)
        // A turban shell: its whorl spirals in.
        g.shape(2, "^0,44 4,22 22,6 46,2 66,14 74,34 70,56 52,70 ^16,72 z", 1.4)
        var pts: [(Double, Double)] = []
        for i in 0...26 {
            let a = Double(i) * 22 - 90
            let r = 28 - Double(i) * 0.98
            pts.append(K.polar(40, 36, r, a))
        }
        g.line(.spline(pts), 0.8)
        g.detail(0.12) { g in
            g.gel("^12,26 ^22,14", 0.9)
            for a in stride(from: 10.0, through: 170.0, by: 26) {
                let p0 = K.polar(40, 36, 30, a), p1 = K.polar(40, 36, 35, a)
                g.line(.poly([p0, p1]), 0.42)
            }
        }
        return g
    }

    static func slippers() -> DoodleGlyph {
        var g = DoodleGlyph("slippers", 0.16, 0.36, tilt: 10)
        // A pair of ballet slippers, side by side, ribbons looping up.
        g.line("44,22 32,4 44,-12 62,-10 66,8 ^56,22", 0.85)
        g.line("56,22 72,4 90,0 ^100,14", 0.85)
        g.line("44,22 26,14 14,18 ^6,30", 0.85)
        g.mirror(50) { g in
            g.shape(0, "^44,28 30,22 16,34 8,62 8,92 14,112 24,122 34,118 42,100 46,70 ^48,42 z", 1.45)
            g.shape(-1, "^38,36 24,36 18,58 18,82 24,92 34,86 38,66 z", 0.9)
            g.shape(1, "^12,102 24,110 ^40,104 34,118 24,122 14,112 z", 0.8)
            g.detail(0.16) { g in
                g.stitch("^12,60 ^12,94", dash: 1.8, gap: 1.8, w: 0.42)
                g.gel("^10,62 ^14,44", 0.8)
            }
        }
        g.shape(1, "^50,30 42,24 ^40,34 ^50,30 ^58,24 ^60,34 z", 0.8)
        return g
    }

    static func wand() -> DoodleGlyph {
        var g = DoodleGlyph("wand", 0.14, 0.34, tilt: 34)
        // A slender stem, a ribbon wrap, a star with a star inside it.
        g.shape(-1, DoodlePath.taper([(36, 36), (28, 130)], 3.6, 5), 1.1)
        g.stitch("^34,50 ^29,118", dash: 3, gap: 4, w: 0.8)
        g.shape(1, DoodleFillers.starPath(38, 26, 30), 1.5)
        g.shape(0, DoodleFillers.starPath(38, 26, 14), 0.9)
        g.shape(0, "^32,58 18,66 ^10,80 ^24,76 ^32,70 ^46,80 ^58,78 ^46,66 z", 1.05)
        g.shape(-1, DoodleFillers.sparklePath(78, 2, 8), 0.75)
        g.blot(.circle(82, 30, 1.8))
        g.blot(.circle(-8, 8, 1.6))
        g.shape(-1, DoodleFillers.sparklePath(-6, 42, 5.6), 0.65)
        return g
    }

    static func moonKey() -> DoodleGlyph {
        var g = DoodleGlyph("moonKey", 0.1, 0.27, tilt: 40)
        // A skeleton key whose bow is a crescent and a star.
        g.shape(1, DoodlePath.taper([(30, 42), (30, 112)], 6, 6), 1.2)
        g.shape(1, "^30,96 ^54,96 ^54,104 ^46,104 ^46,110 ^54,110 ^54,118 ^30,118 z", 1.2)
        g.shape(1, .rrect(20, 46, 20, 7, 2), 1)
        g.shape(1, K.crescent(30, 22, 22, bite: 0.44, rot: -90), 1.35)
        g.shape(0, DoodleFillers.starPath(30, 20, 9), 0.85)
        g.detail(0.13) { $0.gel("^12,16 ^20,5", 0.8) }
        return g
    }

    static func cloud() -> DoodleGlyph {
        var g = DoodleGlyph("cloud", 0.12, 0.3, tilt: 6)
        g.shape(-1, "^12,62 0,52 4,38 18,34 22,18 40,10 56,16 66,6 88,10 96,26 110,30 118,46 110,60 ^96,64 z", 1.45)
        g.line("^22,18 28,28 ^26,36", 0.6)
        g.line("^66,6 62,16 ^68,24", 0.6)
        g.line("^96,26 92,34 ^96,40", 0.6)
        g.detail(0.14) { g in
            g.hatch("^40,54 ^108,48 ^96,62 ^44,62 z", angle: 12, gap: 2.8, w: 0.42)
            g.gel("^14,44 ^22,40", 0.8)
        }
        g.shape(1, DoodleFillers.starPath(30, 78, 6), 0.75)
        g.shape(0, DoodleFillers.starPath(84, 80, 7), 0.75)
        g.line("^30,64 ^30,73", 0.45)
        g.line("^84,64 ^84,73", 0.45)
        g.shape(-1, .circle(58, 76, 3.6), 0.6)
        g.line("^58,64 ^58,72", 0.45)
        return g
    }

    static func phases() -> DoodleGlyph {
        var g = DoodleGlyph("phases", 0.14, 0.34, tilt: 18)
        // The phases of the moon strung on a thread, full in the middle.
        g.line("^-14,28 8,18 ^60,10 112,18 ^134,28", 0.55)
        let xs: [Double] = [-4, 26, 60, 94, 124], ys: [Double] = [24, 16, 12, 16, 24]
        let rs: [Double] = [9, 12, 15, 12, 9]
        g.shape(1, .circle(xs[2], ys[2] + 14, rs[2]), 1.2)
        g.detail(0.16) { g in
            g.blot(.circle(xs[2] - 5, ys[2] + 11, 1.9))
            g.blot(.circle(xs[2] + 5, ys[2] + 18, 1.5))
            g.blot(.circle(xs[2] + 3, ys[2] + 6, 1))
        }
        g.shape(-1, .circle(xs[1], ys[1] + 12, rs[1]), 1)
        g.tint(1, K.crescent(xs[1], ys[1] + 12, rs[1], bite: 0.5).rotated(180, about: (xs[1], ys[1] + 12)))
        g.shape(-1, .circle(xs[3], ys[3] + 12, rs[3]), 1)
        g.tint(1, K.crescent(xs[3], ys[3] + 12, rs[3], bite: 0.5))
        g.shape(1, K.crescent(xs[0], ys[0] + 10, rs[0], bite: 0.5), 0.9)
        g.shape(1, K.crescent(xs[4], ys[4] + 10, rs[4], bite: 0.5, rot: 180), 0.9)
        return g
    }

    static func shootingStar() -> DoodleGlyph {
        var g = DoodleGlyph("shootingStar", 0.11, 0.3, tilt: 14)
        // A star with three ribbons of tail.
        g.shape(0, "^26,40 46,20 74,8 ^116,-10 ^106,3 ^124,1 92,18 66,28 48,42 ^34,56 z", 1.05)
        g.shape(2, "^36,60 56,50 82,48 ^124,34 ^114,46 ^130,48 92,62 66,64 ^42,74 z", 1.05)
        g.shape(1, DoodleFillers.starPath(24, 52, 22), 1.5)
        g.detail(0.13) { g in
            g.blot(.circle(102, 50, 1.6))
            g.blot(.circle(116, 14, 1.2))
            g.gel("^18,44 ^24,38", 0.8)
        }
        return g
    }

    static func constellation() -> DoodleGlyph {
        var g = DoodleGlyph("constellation", 0.11, 0.26, tilt: 16)
        let pts: [(Double, Double)] = [(4, 56), (26, 26), (58, 40), (84, 8), (104, 44), (72, 74)]
        g.stitch(.poly(pts), dash: 2.4, gap: 2.2, w: 0.6)
        g.stitch(.poly([pts[2], pts[5], pts[4]]), dash: 2.4, gap: 2.2, w: 0.6)
        for (i, p) in pts.enumerated() {
            let r = [6.5, 8.0, 5.4, 10.0, 6.0, 5.2][i]
            g.shape(i % 2 == 1 ? 1 : -1, DoodleFillers.sparklePath(p.0, p.1, r * 1.3), 0.72)
        }
        return g
    }

    static func lantern() -> DoodleGlyph {
        var g = DoodleGlyph("lantern", 0.13, 0.32, tilt: 10)
        g.noFlip = true
        // A pierced star lantern with a loop and a tassel.
        g.line(.circle(40, -6, 6), 1)
        g.shape(1, "^30,0 ^50,0 ^56,12 ^24,12 z", 1.2)
        g.shape(0, "^24,12 ^56,12 76,36 76,70 ^56,96 ^24,96 4,70 4,36 z", 1.5)
        g.line("^24,12 ^16,54 ^24,96", 0.75)
        g.line("^56,12 ^64,54 ^56,96", 0.75)
        g.shape(1, DoodleFillers.starPath(40, 54, 16), 1)
        for (x, y) in [(10.0, 42.0), (70.0, 42.0), (10.0, 66.0), (70.0, 66.0), (40.0, 22.0), (40.0, 86.0)] { g.shape(1, .circle(x, y, 2.6), 0.55) }
        g.shape(1, "^24,96 ^56,96 ^50,104 ^30,104 z", 1.1)
        g.line("^40,104 ^40,112", 0.8)
        g.shape(0, "^35,112 ^45,112 ^50,132 ^30,132 z", 0.95)
        g.detail(0.15) { g in
            for x in [34.0, 38.0, 42.0, 46.0] { g.line(.poly([(x, 116), (x + (x - 40) * 0.24, 130)]), 0.42) }
        }
        return g
    }

    static func moonCandle() -> DoodleGlyph {
        var g = DoodleGlyph("moonCandle", 0.12, 0.3, tilt: 8)
        g.shape(-1, "^18,34 ^44,34 ^46,92 ^16,92 z", 1.35)
        g.shape(-1, "^18,34 22,44 ^26,38 30,58 ^36,38 40,46 ^44,34 z", 0.75)
        g.shape(0, DoodleFillers.starPath(31, 68, 9), 0.75)
        g.line("^31,34 ^31,27", 0.8)
        g.shape(1, "31,6 38,16 36,25 31,28 26,25 24,16 z", 1.1)
        g.shape(-1, "31,16 34,21 31,26 28,21 z", 0.5)
        // The holder, a finger ring on a dish.
        g.band(1, outer: "^64,88 80,84 84,94 76,104 ^62,104 ^64,96 72,96 74,92 ^64,94 z", inner: "^64,88 ^64,88 ^64,88 z", 1, innerW: 0)
        g.shape(1, "^-4,92 ^68,92 62,106 44,112 ^18,112 2,106 z", 1.4)
        g.detail(0.14) { g in
            g.gel("^22,44 ^22,84", 0.8)
            g.stitch("^6,100 ^60,100", dash: 2, gap: 2, w: 0.42)
        }
        return g
    }

    static func dragonfly() -> DoodleGlyph {
        var g = DoodleGlyph("dragonfly", 0.11, 0.28, tilt: 38)
        g.mirror(50) { g in
            g.shape(2, "^47,26 26,10 4,4 ^-8,10 ^4,18 26,28 ^48,30 z", 1.05)
            g.shape(0, "^47,34 26,36 6,44 ^0,54 ^12,54 30,46 ^48,38 z", 1.05)
            g.line("^47,28 ^0,10", 0.42)
            g.line("^47,36 ^4,50", 0.42)
        }
        g.shape(1, DoodlePath.taper([(50, 28), (50, 112)], 4.2, 2.2), 1)
        g.detail(0.13) { g in
            for y in stride(from: 48.0, through: 106.0, by: 9) { g.line(.poly([(47, y), (53, y)]), 0.42) }
        }
        g.shape(1, .circle(50, 18, 5.6), 1)
        g.blot(.circle(47.6, 17, 1.3))
        g.blot(.circle(52.4, 17, 1.3))
        return g
    }

    static func iris() -> DoodleGlyph {
        var g = DoodleGlyph("iris", 0.16, 0.38, tilt: 10)
        // Long sword leaves, three falls, three standards.
        g.shape(2, K.leaf((36, 136), (16, 40), belly: 12, bias: 0.4), 1.15)
        g.shape(2, K.leaf((42, 136), (72, 60), belly: 12, bias: 0.4), 1.15)
        g.line("^40,136 ^40,66", 1.15)
        g.shape(0, "^40,26 30,8 ^40,-8 50,8 z", 1.25)
        g.shape(0, "^38,30 22,16 12,22 ^14,36 24,36 z", 1.2)
        g.shape(0, "^42,30 58,16 68,22 ^66,36 56,36 z", 1.2)
        // The falls curl down, with a gold beard.
        g.shape(0, "^40,36 18,30 2,42 2,62 14,64 26,50 ^38,44 z", 1.35)
        g.shape(0, "^40,36 62,30 78,42 78,62 66,64 54,50 ^42,44 z", 1.35)
        g.shape(0, "^34,38 ^46,38 52,58 40,78 28,58 z", 1.35)
        g.shape(1, "^37,40 ^43,40 44,52 40,62 36,52 z", 0.72)
        g.line("^16,38 ^8,54", 0.42)
        g.line("^64,38 ^72,54", 0.42)
        g.line("^40,8 ^40,22", 0.42)
        g.detail(0.16) { g in
            g.line("^20,120 ^24,70", 0.42)
            g.line("^52,118 ^64,76", 0.42)
        }
        return g
    }

    static func wisteria() -> DoodleGlyph {
        var g = DoodleGlyph("wisteria", 0.16, 0.38, tilt: 12)
        g.noFlip = true
        // A hanging raceme of little florets, smaller to the tip, with a sprig of leaves up top.
        g.line("^-8,6 20,4 ^48,8 ^78,2", 1.05)
        for (a, b) in [((14.0, 5.0), (0.0, 24.0)), ((28.0, 5.0), (10.0, 28.0)), ((64.0, 5.0), (86.0, 26.0)), ((54.0, 7.0), (72.0, 30.0))] as [((Double, Double), (Double, Double))] {
            g.shape(2, K.leaf(a, b, belly: 8), 0.95)
        }
        g.line("^40,8 ^40,126", 0.75)
        var y = 20.0, half = 22.0, row = 0
        while y < 126 {
            let n = max(1, Int(half / 7))
            for i in -n...n {
                let x = 40 + Double(i) * (half / Double(max(1, n))) + (row % 2 == 0 ? 0 : 2.2)
                let wob = Double(abs(i)) * -1.4
                let r = 4.9 - y * 0.018
                g.shape(row % 3 == 2 ? -1 : 0, .ellipse(x, y + wob, r * 1.25, r), 0.72)
            }
            y += 11.4 - y * 0.02
            half *= 0.86
            row += 1
        }
        return g
    }

    static func lavender() -> DoodleGlyph {
        var g = DoodleGlyph("lavender", 0.1, 0.28, tilt: 22)
        // Three stems tied with a ribbon.
        for (dx, h) in [(-16.0, 16.0), (0.0, 0.0), (16.0, 12.0)] {
            let top = 2 + h
            g.line(.poly([(30 + dx * 0.2, 110), (30 + dx, top + 30)]), 0.9)
            var i = 0.0
            while i < 6 {
                let y = top + i * 6.4
                g.shape(0, .ellipse(30 + dx - 3.8, y + 2, 3.7, 3.1, rot: -32), 0.55)
                g.shape(0, .ellipse(30 + dx + 3.8, y + 2, 3.7, 3.1, rot: 32), 0.55)
                i += 1
            }
            g.shape(0, .ellipse(30 + dx, top - 1, 3, 3.6), 0.55)
        }
        g.line("^26,82 ^10,70", 0.65)
        g.line("^34,88 ^50,74", 0.65)
        g.shape(1, "^30,88 16,80 ^14,92 ^30,88 ^44,80 ^46,92 z", 0.85)
        g.line("^30,88 22,104 ^16,112", 0.6)
        g.line("^30,88 38,104 ^44,110", 0.6)
        return g
    }

    static func lilyValley() -> DoodleGlyph {
        var g = DoodleGlyph("lilyValley", 0.12, 0.3, tilt: 16)
        // An arching stem of bells between two broad leaves.
        g.shape(2, K.leaf((36, 124), (2, 40), belly: 26, bias: 0.46), 1.2)
        g.line("^32,114 ^8,50", 0.42)
        g.shape(2, K.leaf((42, 124), (96, 60), belly: 22, bias: 0.46), 1.2)
        g.line("^46,114 ^88,66", 0.42)
        g.line("^40,124 34,70 46,26 70,10 ^92,18", 1)
        let bells: [(Double, Double, Double)] = [(92, 18, 6.2), (78, 12, 7), (60, 15, 7.6), (46, 26, 8), (38, 44, 8), (35, 62, 7.2)]
        for (x, y, r) in bells {
            g.line(.poly([(x, y), (x + 2, y + 5)]), 0.5)
            g.shape(-1, "^\(x + 2 - r),\(y + 5 + r * 1.3) \(x + 2 - r * 0.85),\(y + 5 + r * 0.3) \(x + 2),\(y + 4) \(x + 2 + r * 0.85),\(y + 5 + r * 0.3) ^\(x + 2 + r),\(y + 5 + r * 1.3) \(x + 2 + r * 0.45),\(y + 5 + r * 1.05) \(x + 2),\(y + 5 + r * 1.4) \(x + 2 - r * 0.45),\(y + 5 + r * 1.05) z", 0.85)
        }
        return g
    }

    static func violet() -> DoodleGlyph {
        var g = DoodleGlyph("violet", 0.08, 0.2, tilt: 24)
        g.shape(2, K.leaf((30, 58), (58, 84), belly: 20), 0.95)
        g.shape(2, K.leaf((30, 58), (2, 80), belly: 18), 0.95)
        g.line("^30,50 ^30,84", 0.85)
        // Five petals, the lowest with a gold eye.
        g.shape(0, "^30,28 16,20 8,6 20,0 ^28,12 z", 1.05)
        g.shape(0, "^30,28 44,20 52,6 40,0 ^32,12 z", 1.05)
        g.shape(0, "^30,30 14,28 2,34 6,46 ^26,38 z", 1.05)
        g.shape(0, "^30,30 46,28 58,34 54,46 ^34,38 z", 1.05)
        g.shape(0, "^28,34 18,46 22,58 38,58 42,46 ^32,34 z", 1.05)
        g.shape(1, .circle(30, 32, 3.4), 0.7)
        g.line("^30,40 ^30,52", 0.42)
        return g
    }

    static func mushrooms() -> DoodleGlyph {
        var g = DoodleGlyph("mushrooms", 0.13, 0.32, tilt: 9)
        // Two spotted caps in the grass, one small one leaning in.
        g.shape(-1, "^28,50 ^48,50 50,82 56,98 ^20,98 26,82 z", 1.3)
        g.shape(0, "^-2,54 6,24 38,4 70,24 ^78,54 58,58 38,56 18,58 z", 1.5)
        for (x, y, r) in [(22.0, 36.0, 5.0), (42.0, 22.0, 6.0), (58.0, 40.0, 4.4), (36.0, 46.0, 3.0)] { g.shape(-1, .circle(x, y, r), 0.6) }
        g.shape(-1, "^76,70 ^88,70 90,88 94,98 ^70,98 74,88 z", 1.1)
        g.shape(1, "^60,70 66,54 82,46 98,54 ^104,70 92,73 ^72,73 z", 1.3)
        g.shape(-1, .circle(82, 58, 3), 0.55)
        g.shape(-1, .circle(92, 63, 2.2), 0.5)
        g.line("^-6,99 ^108,99", 0.9)
        for (x, c) in [(2.0, -4.0), (12.0, 3.0), (62.0, -2.0), (102.0, 4.0)] { g.line(.poly([(x, 99), (x + c, 90)]), 0.6) }
        g.detail(0.15) { g in
            g.gel("^10,30 ^22,16", 1)
            g.line("^30,62 ^30,84", 0.42)
        }
        return g
    }

    static func seahorse() -> DoodleGlyph {
        var g = DoodleGlyph("seahorse", 0.14, 0.34, tilt: 12)
        // Curled tail, ridged back, a fin and a little crown of spines.
        g.shape(1, "^28,12 ^32,-2 ^38,8 ^44,-4 ^48,8 ^56,2 ^56,16 z", 0.95)
        g.shape(0, "^4,34 ^-8,26 ^-6,18 ^12,22 24,10 44,6 58,18 60,36 54,52 66,70 66,92 54,108 40,122 34,134 42,140 52,136 54,128 ^46,128 ^44,134 38,132 42,120 ^30,126 22,138 30,150 46,152 60,144 62,128 ^54,116 42,104 36,88 36,70 ^28,48 24,36 z", 1.5)
        g.blot(.circle(32, 22, 2.6))
        g.shape(-1, .circle(32, 22, 1), 0.2)
        // Spines down the back and a fin.
        for (x, y) in [(60.0, 30.0), (58.0, 46.0), (64.0, 62.0), (68.0, 80.0), (62.0, 100.0)] {
            g.line(.poly([(x, y), (x + 8, y - 2)]), 0.7)
        }
        g.shape(2, "^62,74 80,64 88,76 80,90 ^64,88 z", 1)
        g.line("^66,80 ^82,72", 0.42)
        g.line("^66,84 ^84,82", 0.42)
        g.detail(0.16) { g in
            for y in stride(from: 54.0, through: 104.0, by: 7) {
                g.line(.poly([(38 + (y - 54) * 0.02, y), (62 - abs(y - 76) * 0.14, y + 2)]), 0.42)
            }
        }
        return g
    }

    static func starfish() -> DoodleGlyph {
        var g = DoodleGlyph("starfish", 0.08, 0.2, tilt: 40)
        var nodes: [DoodlePath.Node] = []
        for i in 0..<5 {
            let a = -90.0 + Double(i) * 72
            let t = K.polar(40, 42, 40, a), n1 = K.polar(40, 42, 13, a + 36)
            let side = K.polar(40, 42, 26, a + 12)
            nodes.append(.init(x: t.0, y: t.1, corner: false))
            nodes.append(.init(x: side.0, y: side.1, corner: false))
            nodes.append(.init(x: n1.0, y: n1.1, corner: true))
        }
        g.shape(1, DoodlePath(nodes: nodes, closed: true), 1.4)
        g.detail(0.1) { g in
            for i in 0..<5 {
                let a = -90.0 + Double(i) * 72
                for r in [10.0, 17.0, 24.0, 30.0] {
                    let p = K.polar(40, 42, r, a)
                    g.blot(.circle(p.0, p.1, 1.5 - r * 0.02))
                }
            }
        }
        return g
    }

    static func coral() -> DoodleGlyph {
        var g = DoodleGlyph("coral", 0.1, 0.27, tilt: 8)
        func branch(_ g: inout DoodleGlyph, _ pts: [(Double, Double)], _ w0: Double, _ w1: Double) { g.shape(0, DoodlePath.taper(pts, w0, w1), 1.05) }
        branch(&g, [(44, 104), (42, 74), (24, 52), (20, 28)], 13, 6)
        branch(&g, [(30, 60), (12, 50), (2, 34)], 7, 4.4)
        branch(&g, [(44, 84), (52, 56), (48, 26), (54, 4)], 12, 5.6)
        branch(&g, [(50, 44), (34, 26), (36, 12)], 6.4, 4)
        branch(&g, [(46, 90), (66, 74), (84, 60), (86, 36)], 12, 6)
        branch(&g, [(72, 68), (92, 62), (102, 46)], 7, 4.2)
        branch(&g, [(82, 52), (70, 40), (68, 26)], 6, 4)
        g.shape(1, "^24,104 ^68,104 ^78,114 ^14,114 z", 1.15)
        g.detail(0.13) { g in
            g.speckle(24, 40, 80, 96, n: 14, r: 0.6, seed: 17)
        }
        return g
    }

    static func potion() -> DoodleGlyph {
        var g = DoodleGlyph("potion", 0.11, 0.28, tilt: 14)
        // A round flask, starry water, a cork, a tag.
        g.shape(1, "^27,-2 ^45,-2 ^47,12 ^25,12 z", 1.2)
        g.line("^29,-2 ^29,12", 0.42)
        g.shape(-1, "^26,12 ^46,12 ^46,30 62,44 72,66 66,90 48,102 ^24,102 6,90 0,66 10,44 ^26,30 z", 1.5)
        g.tint(0, "^2,60 ^70,60 72,66 66,90 48,102 ^24,102 6,90 0,66 z")
        g.line("^2,60 16,57 30,61 46,57 58,61 ^70,60", 0.7)
        g.shape(1, DoodleFillers.starPath(36, 78, 9), 0.8)
        g.shape(-1, DoodleFillers.sparklePath(54, 72, 5), 0.5)
        g.shape(-1, .circle(20, 72, 2), 0.42)
        g.shape(-1, .circle(46, 90, 1.6), 0.42)
        g.detail(0.14) { $0.gel("^12,52 ^18,44", 1) }
        g.line("^26,18 8,20 ^2,30", 0.55)
        g.shape(2, "^-8,30 ^12,30 ^12,44 ^-8,44 z", 0.8)
        return g
    }

    static func moonCard() -> DoodleGlyph {
        var g = DoodleGlyph("moonCard", 0.13, 0.32, tilt: 16)
        g.noFlip = true
        // An ornate fortune-style card with a great star over waves, no numbers, no named deck.
        g.shape(-1, .rrect(0, 0, 74, 112, 4), 1.5)
        g.line(.rrect(6, 6, 62, 100, 2), 0.6)
        g.tint(0, .rrect(6, 6, 62, 100, 2))
        g.shape(1, DoodleFillers.starPath(37, 42, 20), 1.1)
        g.shape(-1, .circle(37, 42, 3.6), 0.6)
        for (x, y) in [(16.0, 18.0), (58.0, 18.0), (16.0, 66.0), (58.0, 66.0)] { g.shape(1, DoodleFillers.sparklePath(x, y, 5), 0.5) }
        g.shape(2, "^6,78 18,72 30,78 44,72 56,78 ^68,74 ^68,106 ^6,106 z", 0.75)
        g.line("^6,90 18,84 30,90 44,84 56,90 ^68,86", 0.5)
        return g
    }

    static func sleepyCat() -> DoodleGlyph {
        var g = DoodleGlyph("sleepyCat", 0.16, 0.34, tilt: 6)
        // Curled on a cushion, tail round its nose.
        g.shape(0, "^-6,68 6,58 56,54 112,58 ^124,68 118,84 ^60,88 2,84 z", 1.45)
        g.detail(0.16) { g in
            g.stitch("^4,72 ^116,72", dash: 2.2, gap: 2, w: 0.42)
            g.shape(1, .circle(-6, 68, 3), 0.6)
            g.shape(1, .circle(124, 68, 3), 0.6)
        }
        g.shape(-1, "^22,60 8,46 14,26 ^12,8 ^26,16 38,14 ^52,6 ^52,24 72,18 96,26 110,44 ^104,62 z", 1.5)
        // Face tucked down, tail wrapped along the front.
        g.line("^20,32 26,35 ^32,33", 0.8)
        g.line("^38,31 44,34 ^50,32", 0.8)
        g.blot("^34,39 ^38,39 ^36,42 z")
        g.line("^36,42 32,46 ^29,44", 0.5)
        g.line("^36,42 40,46 ^43,44", 0.5)
        g.shape(-1, "^104,50 88,62 56,62 ^24,56 ^22,62 56,70 90,70 112,60 z", 1.05)
        g.line("^60,28 ^70,44", 0.6)
        g.line("^74,24 ^84,42", 0.6)
        g.line("^88,30 ^96,44", 0.6)
        // Zzz in a moony way.
        g.shape(1, K.crescent(72, -4, 7, bite: 0.42, rot: -20), 0.72)
        g.shape(-1, DoodleFillers.sparklePath(92, 6, 4.6), 0.5)
        return g
    }

    static func amethyst() -> DoodleGlyph {
        var g = DoodleGlyph("amethyst", 0.09, 0.24, tilt: 24)
        // A single long double-terminated point.
        g.shape(0, "^30,0 ^52,20 ^52,86 ^30,108 ^8,86 ^8,20 z", 1.45)
        g.line("^8,20 ^30,30 ^52,20", 0.7)
        g.line("^30,0 ^30,30 ^30,84 ^30,108", 0.7)
        g.line("^8,86 ^30,84 ^52,86", 0.7)
        g.tint(-1, "^8,20 ^30,30 ^30,0 z")
        g.detail(0.12) { g in
            g.hatch("^36,34 ^52,26 ^52,84 ^36,84 z", angle: 76, gap: 3, w: 0.42)
            g.gel("^14,34 ^14,62", 0.9)
        }
        return g
    }

    static func pendant() -> DoodleGlyph {
        var g = DoodleGlyph("pendant", 0.11, 0.28, tilt: 10)
        g.noFlip = true
        // A fine chain drops to a moonstone in a claw setting.
        g.stitch("^-6,0 10,30 ^38,56", dash: 2, gap: 1.4, w: 0.7)
        g.stitch("^86,0 70,30 ^42,56", dash: 2, gap: 1.4, w: 0.7)
        g.line(.circle(40, 58, 4), 0.85)
        g.shape(1, .ellipse(40, 86, 22, 26), 1.5)
        g.shape(-1, .ellipse(40, 86, 16, 20), 0.95)
        g.tint(2, K.crescent(40, 86, 14, bite: 0.5, rot: 30).scaled(0.95, about: (40, 86)))
        g.gel("30,78 33,72 ^38,69", 0.9)
        g.blot(.circle(40, 112, 2))
        g.line("^36,118 40,124 ^44,118", 0.65)
        g.detail(0.14) { g in
            g.blot(.circle(22, 74, 1.1))
            g.blot(.circle(58, 74, 1.1))
            g.blot(.circle(22, 98, 1.1))
            g.blot(.circle(58, 98, 1.1))
        }
        return g
    }

    static func plume() -> DoodleGlyph {
        var g = DoodleGlyph("plume", 0.12, 0.32, tilt: 30)
        // A quill: a long pen shaft curving through one sweeping vane, split in three places, downy at the root.
        let vane: DoodlePath = "^26,118 10,100 8,78 ^14,72 ^6,66 10,44 22,24 ^30,22 ^28,12 44,0 ^68,-14 ^70,4 ^78,6 66,28 ^58,30 ^62,40 50,62 ^40,62 ^44,74 34,96 ^30,110 z"
        g.shape(0, vane, 1.4)
        // Down at the root.
        g.line("^24,118 12,116 ^4,108", 0.7)
        g.line("^26,122 14,126 ^6,124", 0.7)
        g.line("^30,118 40,120 ^46,114", 0.7)
        // The shaft, drawn through and out to its cut nib.
        g.shape(-1, DoodlePath.taper([(10, 158), (24, 118), (36, 76), (50, 34), (68, -12)], 4, 1.2), 0.95)
        g.detail(0.14) { g in
            let spine: [(Double, Double)] = [(25, 112), (29, 98), (33, 84), (37, 70), (42, 56), (47, 42), (53, 28), (60, 12)]
            for (i, p) in spine.enumerated() {
                let k = 1 - Double(i) / 11
                g.line(.poly([p, (p.0 - 15 * k, p.1 - 9)]), 0.42)
                g.line(.poly([p, (p.0 + 13 * k, p.1 - 12)]), 0.42)
            }
        }
        return g
    }

    static func snowGlobe() -> DoodleGlyph {
        var g = DoodleGlyph("snowGlobe", 0.14, 0.32, tilt: 8)
        g.noFlip = true
        // A glass ball with a tiny pine-less cottage under a star, sitting on a ribboned base.
        g.shape(-1, .circle(50, 46, 44), 1.55)
        g.tint(2, "^10,62 22,56 44,60 66,56 ^90,62 84,76 64,88 36,88 16,76 z")
        g.line("^10,62 22,56 44,60 66,56 ^90,62", 0.7)
        g.shape(0, "^38,50 ^62,50 ^62,68 ^38,68 z", 1)
        g.shape(1, "^32,52 ^50,34 ^68,52 z", 1.05)
        g.shape(-1, .rrect(46, 56, 8, 12, 1.5), 0.6)
        g.shape(1, DoodleFillers.starPath(50, 20, 7.4), 0.75)
        for (x, y) in [(18.0, 34.0), (28.0, 18.0), (72.0, 22.0), (82.0, 38.0), (26.0, 46.0), (76.0, 48.0), (38.0, 34.0), (64.0, 36.0)] { g.blot(.circle(x, y, 1.1)) }
        g.detail(0.15) { $0.gel("14,38 20,20 ^34,8", 1.1) }
        g.shape(0, "^14,82 ^86,82 ^96,108 ^4,108 z", 1.5)
        g.tint(1, "^10,92 ^90,92 ^92.6,100 ^7.4,100 z")
        g.line("^10,92 ^90,92", 0.6)
        g.line("^7.4,100 ^92.6,100", 0.6)
        return g
    }

    static func dove() -> DoodleGlyph {
        var g = DoodleGlyph("dove", 0.12, 0.3, tilt: 16)
        // Flying left, a ribbon in its beak.
        g.shape(-1, "^98,50 ^122,36 ^122,50 ^130,50 ^116,64 84,72 ^68,66 z", 1.15)
        g.shape(-1, "^10,28 22,18 36,22 50,36 78,44 ^100,50 92,66 64,74 36,68 22,48 ^16,38 z", 1.45)
        g.shape(1, "^12,26 ^0,31 ^14,34 z", 1)
        g.blot(.circle(20, 26, 1.6))
        // The raised wing.
        g.shape(-1, "^40,44 44,18 ^60,-6 ^66,8 ^78,-4 ^80,14 ^92,10 86,32 64,50 z", 1.3)
        g.line("^52,40 ^60,18", 0.55)
        g.line("^62,44 ^74,20", 0.55)
        // Ribbon trails from the beak.
        g.shape(0, "^4,30 -8,42 2,54 -6,66 ^0,70 10,56 2,44 ^10,34 z", 0.9)
        g.detail(0.14) { g in
            g.hatch("^40,66 ^80,60 ^64,72 ^44,72 z", angle: 16, gap: 2.8, w: 0.42)
        }
        return g
    }

    static func musicBox() -> DoodleGlyph {
        var g = DoodleGlyph("musicBox", 0.15, 0.34, tilt: 7)
        g.noFlip = true
        // A carved box, lid up, a small dancer's skirt turning on a pin; a winding key.
        g.shape(0, "^4,4 ^92,4 ^96,30 ^0,30 z", 1.35)
        g.shape(-1, "^10,10 ^86,10 ^88,26 ^8,26 z", 0.75)
        g.line("^0,30 ^-2,40", 0.8)
        g.line("^96,30 ^98,40", 0.8)
        g.shape(0, .rrect(-4, 56, 104, 46, 3), 1.5)
        g.accent(.rrect(0, 46, 96, 13, 1))
        g.shape(1, .rrect(-4, 54, 104, 6, 1.5), 1)
        // The dancer.
        g.line("^48,52 ^48,40", 0.8)
        g.shape(1, .circle(48, 14, 4), 0.8)
        g.line("^48,18 ^48,28", 1.2)
        g.line("^48,20 38,14 ^36,8", 0.65)
        g.line("^48,20 58,14 ^60,8", 0.65)
        g.shape(-1, "^48,26 36,36 ^30,42 40,40 48,44 56,40 ^66,42 ^60,36 z", 0.85)
        g.line("^48,40 ^44,50", 0.65)
        g.shape(-1, DoodleFillers.starPath(48, 80, 10), 0.85)
        g.detail(0.16) { g in
            g.stitch("^6,68 ^90,68", dash: 2, gap: 1.8, w: 0.42)
            g.stitch("^6,94 ^90,94", dash: 2, gap: 1.8, w: 0.42)
            g.blot(.circle(22, 80, 1.6))
            g.blot(.circle(74, 80, 1.6))
        }
        g.line("^100,76 ^112,76", 1.1)
        g.shape(1, "^112,68 ^122,70 ^116,76 ^122,82 ^112,84 z", 0.9)
        g.line("^-14,100 ^112,100", 0)
        return g
    }

    static func wings() -> DoodleGlyph {
        var g = DoodleGlyph("wings", 0.13, 0.32, tilt: 16)
        g.noFlip = true
        // A pair of small angel wings: soft rounded feathers in three layers, with a star between.
        g.mirror(60) { g in
            g.shape(-1, "^54,50 42,22 22,6 ^2,2 -6,12 ^2,20 -10,28 ^0,38 -12,46 ^0,56 -8,66 ^8,72 2,84 ^20,84 18,96 ^36,90 ^50,76 z", 1.4)
            g.tint(0, "^42,22 22,6 ^2,2 -6,12 ^2,20 -10,28 ^0,38 ^22,40 ^38,42 z")
            g.line("^38,42 22,40 ^0,38", 0.6)
            g.line("^44,54 24,54 ^0,56", 0.55)
            g.line("^44,66 26,68 ^8,72", 0.55)
            g.line("^44,76 32,80 ^20,84", 0.55)
            g.detail(0.16) { g in
                g.line("^24,20 ^10,14", 0.42)
                g.line("^28,30 ^6,26", 0.42)
            }
        }
        g.shape(1, DoodleFillers.starPath(60, 56, 12), 1)
        return g
    }

    static func plainBow() -> DoodleGlyph {
        var g = DoodleGlyph("plainBow", 0.1, 0.26, tilt: 20)
        // A velvet bow with long notched tails: rounder and simpler than Rose's.
        g.shape(1, "^38,38 22,62 ^12,92 ^24,86 ^32,96 42,66 ^48,44 z", 1.1)
        g.shape(1, "^62,38 78,62 ^88,92 ^76,86 ^68,96 58,66 ^52,44 z", 1.1)
        g.shape(0, "^46,30 24,12 4,10 ^-2,28 4,48 24,48 z", 1.45)
        g.shape(0, "^54,30 76,12 96,10 ^102,28 96,48 76,48 z", 1.45)
        g.shape(0, .rrect(42, 22, 16, 24, 5), 1.25)
        g.line("^38,28 16,20 ^8,26", 0.5)
        g.line("^62,28 84,20 ^92,26", 0.5)
        g.detail(0.12) { g in
            g.gel("^10,16 ^20,14", 0.8)
            g.gel("^46,26 ^47,34", 0.7)
        }
        return g
    }

    static func sugarBowl() -> DoodleGlyph {
        var g = DoodleGlyph("sugarBowl", 0.11, 0.26, tilt: 10)
        // A lidded bowl with little wing handles and a heart-shaped spoon.
        g.line("^78,8 ^100,-6", 1)
        g.shape(1, DoodleFillers.heartPath(104, -10, 5).rotated(40, about: (104, -10)), 0.8)
        g.band(1, outer: "^4,34 -8,30 -12,42 -4,52 ^8,52 ^8,46 -2,44 -4,38 ^4,40 z", inner: "^4,34 ^4,34 ^4,34 z", 0.95, innerW: 0)
        g.band(1, outer: "^80,34 92,30 96,42 88,52 ^76,52 ^76,46 86,44 88,38 ^80,40 z", inner: "^80,34 ^80,34 ^80,34 z", 0.95, innerW: 0)
        g.shape(-1, "^2,26 ^82,26 84,44 72,64 ^12,64 0,44 z", 1.45)
        g.shape(1, "^10,64 ^74,64 ^80,72 ^4,72 z", 1.1)
        g.shape(0, "^0,26 14,12 ^42,6 70,12 ^84,26 z", 1.3)
        g.shape(1, .circle(42, 2, 5.4), 0.9)
        g.shape(0, DoodleFillers.heartPath(42, 45, 11), 0.85)
        g.detail(0.13) { $0.gel("^8,38 ^12,52", 0.8) }
        return g
    }

    static func tinyButterfly() -> DoodleGlyph {
        var g = DoodleGlyph("tinyButterfly", 0.05, 0.12, tilt: 40)
        g.mirror(30) { g in
            g.shape(1, "^28,28 14,28 6,38 12,50 ^26,40 z", 0.9)
            g.shape(0, "^28,24 16,8 2,6 ^-2,18 6,30 ^28,30 z", 1)
        }
        g.line("^30,16 ^30,42", 1.1)
        g.line("^30,16 ^22,4", 0.5)
        g.line("^30,16 ^38,4", 0.5)
        return g
    }

    // The marks in the gaps.

    static func tinyStar() -> DoodleGlyph {
        var g = DoodleGlyph("tinyStar", 0.02, 0.05, tilt: 40)
        g.shape(1, DoodleFillers.starPath(0, 0, 20), 0.8)
        return g
    }

    static func tinyCrescent() -> DoodleGlyph {
        var g = DoodleGlyph("tinyCrescent", 0.022, 0.055, tilt: 40)
        g.shape(1, K.crescent(0, 0, 20, bite: 0.42), 0.8)
        return g
    }

    static func tinyHeart() -> DoodleGlyph {
        var g = DoodleGlyph("tinyHeart", 0.02, 0.045, tilt: 30)
        g.shape(0, DoodleFillers.heartPath(0, 0, 18), 0.8)
        return g
    }

    static func bubbles() -> DoodleGlyph {
        var g = DoodleGlyph("bubbles", 0.03, 0.07, tilt: 14)
        g.line(.circle(10, 22, 9), 0.75)
        g.line(.circle(28, 8, 6), 0.7)
        g.line(.circle(26, 30, 3.6), 0.6)
        g.gel("6,18 8,16 ^11,16", 0.5)
        return g
    }

    static func sparkleMark() -> DoodleGlyph {
        var g = DoodleGlyph("sparkleMark", 0.022, 0.055, tilt: 12)
        g.shape(-1, DoodleFillers.sparklePath(0, 0, 20), 0.7)
        return g
    }

    static func tinyPearl() -> DoodleGlyph {
        var g = DoodleGlyph("tinyPearl", 0.016, 0.03, tilt: 12)
        g.shape(-1, .circle(0, 0, 12), 0.75)
        return g
    }

    static func tinyPetal() -> DoodleGlyph {
        var g = DoodleGlyph("tinyPetal", 0.02, 0.05, tilt: 80)
        g.shape(0, K.leaf((0, 0), (28, 8), belly: 12), 0.7)
        return g
    }
}
