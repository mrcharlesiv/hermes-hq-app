// The Cafe drawings. Spot colours: 0 is caramel, 1 is sage, 2 is terracotta; bare paper is warm cream.

import CoreGraphics
import Foundation

nonisolated enum DoodleCafe {
    typealias K = DoodleKit

    static func all() -> [DoodleGlyph] {
        var list = [mokaPot(), latteCup(), recordPlayer(), croissant(), monstera(), cakeDome(), bookStack(), pencilCup(), espressoMachine(), typewriter(), frenchPress(), dripper(),
                    takeaway(), grinder(), openBook(), pothos(), cactusPot(), snakePlant(), vinyl(), cakeSlice(), pencil(), eraser(), notebook(), donut(), cookie(), muffin(), bagel(), pretzel(),
                    cinnamonRoll(), toast(), waffle(), tart(), baguette(), milkJug(), sugarBowl(), spoonFork(), teabag(), teaTin(), honeyJar(), coffeeBag(), jamJar(), catLoaf(), deskLamp(),
                    wallClock(), chalkboard(), radio(), bistroChair(), scoop(),
                    coffeeBean(), crumbs(), sugarCube(), tinyLeaf(), steamCurl(), tinyNote(), tinyStar(), tinyHeart()]
        list += DoodleFillers.common().filter { ["dot"].contains($0.name) }
        list += extras() + littles()
        for i in list.indices {
            list[i].fixed = true
            list[i].done()
        }
        return list
    }

    static func mokaPot() -> DoodleGlyph {
        var g = DoodleGlyph("mokaPot", 0.26, 0.44, tilt: 10)
        g.must = true
        g.noFlip = true
        g.noTuck = true
        // The space inside the handle stays open.
        g.keepClear("^-10,36 ^16,36 ^14,76 ^-10,76 z")
        // A faceted stovetop pot: base, waist, spouted top, a black handle and a knob.
        let facets: [Double] = [18, 30, 44, 56, 70, 82]
        g.shape(-1, "^12,76 ^82,76 ^92,132 ^2,132 z", 1.6)
        for (i, x) in facets.enumerated() {
            let bot = 47 + (x - 47) * 1.28
            g.line(.poly([(x, 77), (bot, 131)]), 0.65)
            _ = i
        }
        g.shape(-1, "^18,20 ^62,20 ^84,12 ^80,28 ^76,66 ^16,66 ^22,20 z", 1.6)
        for x in [32.0, 46.0, 60.0] { g.line(.poly([(x, 21), (x + (x - 46) * 0.2, 65)]), 0.65) }
        g.shape(0, "^12,64 ^82,64 ^84,78 ^10,78 z", 1.3)
        g.line("^10,71 ^84,71", 0.5)
        // Lid and its knob.
        g.shape(-1, "^18,20 30,8 ^48,4 ^62,8 ^74,20 z", 1.35)
        g.accent(.circle(48, -2, 6.4))
        g.line("^48,4 ^48,6", 0)
        // The handle.
        g.shape(-1, "^12,20 ^26,20 ^26,40 ^12,40 z", 1.1)
        g.blot(.circle(19, 25, 1.5))
        g.blot(.circle(19, 35, 1.5))
        let grip: DoodlePath = "^14,22 ^-4,22 -15,30 -19,46 -16,68 -10,76 ^-3,74 -5,58 -4,44 2,37 ^14,36 z"
        g.shape(1, grip, 1.4)
        g.accent(grip)
        g.gel("^-11,38 ^-13,60", 0.7)
        g.detail(0.22) { g in
            g.gel("^24,30 ^22,58", 1)
            g.gel("^16,86 ^12,120", 1)
            g.hatch("^70,84 ^84,84 ^90,130 ^74,130 z", angle: 76, gap: 3, w: 0.42)
            g.hatch("^62,26 ^76,26 ^74,62 ^62,62 z", angle: 76, gap: 3, w: 0.42)
            g.blot(.circle(47, 104, 2.6))
        }
        // A curl of steam.
        g.line("86,4 92,-6 86,-16 ^92,-26", 0.8)
        return g
    }

    static func latteCup() -> DoodleGlyph {
        var g = DoodleGlyph("latteCup", 0.26, 0.44, tilt: 11)
        g.must = true
        // A wide cup seen a little from above, a leaf poured in the crema, a saucer with a biscuit.
        g.shape(-1, .ellipse(62, 88, 66, 18), 1.45)
        g.line(.ellipse(62, 86, 44, 10), 0.55)
        g.band(2, outer: "^106,28 126,26 136,42 126,62 ^100,70 ^102,58 118,52 122,42 118,36 ^108,38 z", inner: "^106,28 ^106,28 ^106,28 z", 1.35, innerW: 0)
        g.shape(2, "^12,22 ^112,22 110,48 96,78 80,90 ^44,90 28,78 14,48 z", 1.6)
        g.shape(-1, .ellipse(62, 22, 50, 15), 1.35)
        g.shape(0, .ellipse(62, 23, 44, 11.4), 0.9)
        // The poured leaf.
        g.shape(-1, "^28,23 40,14 62,13 86,17 ^98,24 84,30 62,32 40,30 z", 0.6)
        g.tint(0, "^46,23 52,18 62,19 ^78,23 62,27 52,28 z")
        g.line("^38,23 ^88,23", 0.6)
        for x in [50.0, 60.0, 70.0] {
            g.line(.poly([(x, 23), (x + 4, 17)]), 0.45)
            g.line(.poly([(x, 23), (x + 4, 29)]), 0.45)
        }
        g.detail(0.22) { g in
            g.hatch("^86,44 ^106,40 ^96,74 ^78,86 z", angle: 66, gap: 3.2, w: 0.42)
            g.gel("^22,44 ^30,66", 1.2)
            g.stitch("^24,62 62,70 ^98,62", dash: 2, gap: 2, w: 0.42)
        }
        // A biscuit on the saucer.
        g.shape(0, .rrect(-4, 84, 22, 10, 2.5), 0.9)
        g.line("^0,89 ^14,89", 0.42)
        g.line("54,6 60,-6 54,-16 ^60,-26", 0.8)
        g.line("74,6 80,-4 74,-12 ^80,-22", 0.65)
        return g
    }

    static func recordPlayer() -> DoodleGlyph {
        var g = DoodleGlyph("recordPlayer", 0.3, 0.46, tilt: 10)
        g.must = true
        // A wood case, a platter with its record, a tone arm, two knobs, and the lid propped behind.
        g.shape(1, "^12,6 ^136,6 ^140,30 ^8,30 z", 1.1)
        g.line("^20,12 ^128,12", 0.42)
        g.shape(0, .rrect(0, 28, 150, 74, 5), 1.6)
        g.shape(-1, .rrect(6, 34, 138, 60, 2.5), 0.9)
        g.accent(.circle(58, 64, 28))
        g.detail(0.26) { g in
            g.gel(K.arc(58, 64, 22, 22, 200, 280), 0.6)
            g.gel(K.arc(58, 64, 16, 16, 20, 90), 0.5)
        }
        g.shape(2, .circle(58, 64, 9.6), 0.9)
        g.blot(.circle(58, 64, 1.6))
        // Tone arm.
        g.shape(1, .circle(124, 46, 7.6), 1.05)
        g.line("^124,46 ^114,74 ^88,78", 1.2)
        g.shape(1, "^92,73 ^78,73 ^76,83 ^92,83 z", 0.95)
        g.blot(.circle(124, 46, 1.8))
        // Knobs.
        g.shape(2, .circle(112, 88, 4.4), 0.8)
        g.shape(2, .circle(128, 88, 4.4), 0.8)
        g.line("^8,102 ^0,110", 0)
        g.blot(.rrect(12, 102, 16, 6, 1.5))
        g.blot(.rrect(122, 102, 16, 6, 1.5))
        g.detail(0.26) { g in
            g.hatch("^4,84 ^6,94 ^56,94 ^56,92 z", angle: 80, gap: 4, w: 0.42)
            g.line("^6,96 ^144,96", 0.42)
        }
        // A little note floating off.
        g.line("^142,0 ^142,-16 ^154,-20 ^154,-6", 0.8)
        g.blot(.ellipse(139, 0, 3.4, 2.6))
        g.blot(.ellipse(151, -6, 3.4, 2.6))
        return g
    }

    static func croissant() -> DoodleGlyph {
        var g = DoodleGlyph("croissant", 0.22, 0.42, tilt: 18)
        g.must = true
        // A fat crescent of laminated pastry, segment by segment.
        g.shape(0, "^4,76 ^-4,66 6,50 20,44 ^32,34 ^44,18 60,12 ^78,14 94,22 ^104,36 ^118,46 130,54 ^138,68 ^126,78 ^114,72 ^100,62 ^86,56 66,54 ^46,58 ^32,70 ^16,80 z", 1.55)
        for (a, b) in [("^20,44 28,58 ^32,70", 0), ("^44,18 52,38 ^46,58", 1), ("^78,14 76,34 ^66,54", 2), ("^104,36 96,48 ^86,56", 3), ("^118,46 118,60 ^114,72", 4)] as [(DoodlePath, Int)] {
            g.line(a, 1)
            _ = b
        }
        g.detail(0.2) { g in
            g.line("^28,40 36,50 ^38,62", 0.42)
            g.line("^60,14 62,34 ^56,54", 0.42)
            g.line("^92,22 88,38 ^76,54", 0.42)
            g.line("^8,56 12,68 ^12,76", 0.42)
            g.gel("^52,20 ^66,16", 1.1)
            g.gel("^86,26 ^96,32", 0.9)
            g.hatch("^40,62 ^66,56 ^86,60 ^70,70 ^46,70 z", angle: 16, gap: 3, w: 0.42)
        }
        g.speckle(30, 70, 110, 90, n: 7, r: 0.8, seed: 61)
        return g
    }

    static func monstera() -> DoodleGlyph {
        var g = DoodleGlyph("monstera", 0.26, 0.46, tilt: 9)
        g.must = true
        // A big split leaf plant in a stripy pot.
        func leaf(_ g: inout DoodleGlyph, cx: Double, cy: Double, r: Double, rot: Double, sep: Int) {
            func T(_ p: DoodlePath) -> DoodlePath { p.scaled(r / 40, about: (0, 0)).rotated(rot, about: (0, 0)).moved(cx, cy) }
            g.shape(sep, T("^0,-44 16,-40 ^30,-30 ^20,-22 ^38,-16 ^24,-8 ^42,2 ^24,8 ^36,20 ^16,20 ^20,32 ^0,44 ^-20,32 ^-16,20 ^-36,20 ^-24,8 ^-42,2 ^-24,-8 ^-38,-16 ^-20,-22 ^-30,-30 -16,-40 z"), 1.3)
            g.line(T("^0,-40 ^0,44"), 0.8)
            for (y, dx) in [(-22.0, 18.0), (-8.0, 22.0), (8.0, 22.0), (22.0, 16.0)] {
                g.line(T(.poly([(0, y + 8), (dx, y)])), 0.5)
                g.line(T(.poly([(0, y + 8), (-dx, y)])), 0.5)
            }
        }
        g.line("^50,110 40,68 ^28,46", 1.1)
        g.line("^56,110 70,70 ^92,52", 1.1)
        g.line("^52,110 ^52,32", 1.1)
        leaf(&g, cx: 26, cy: 40, r: 26, rot: -30, sep: 1)
        leaf(&g, cx: 94, cy: 46, r: 26, rot: 36, sep: 1)
        leaf(&g, cx: 54, cy: 20, r: 32, rot: 4, sep: 1)
        // Pot.
        g.shape(2, "^22,104 ^88,104 ^80,158 ^30,158 z", 1.55)
        g.shape(2, .rrect(16, 96, 78, 13, 2.5), 1.35)
        g.tint(-1, "^24.4,122 ^85.6,122 ^84,134 ^26,134 z")
        g.line("^24.4,122 ^85.6,122", 0.6)
        g.line("^26,134 ^84,134", 0.6)
        g.detail(0.24) { $0.hatch("^68,112 ^84,112 ^78,154 ^68,154 z", angle: 76, gap: 3, w: 0.42) }
        return g
    }

    static func cakeDome() -> DoodleGlyph {
        var g = DoodleGlyph("cakeDome", 0.24, 0.44, tilt: 9)
        g.must = true
        g.noFlip = true
        // A glass cloche over a layer cake on a pedestal.
        g.shape(-1, .ellipse(60, 112, 52, 8), 1.35)
        g.shape(-1, "^52,116 ^68,116 ^70,136 ^50,136 z", 1.25)
        g.shape(-1, "^34,136 ^86,136 ^92,144 ^28,144 z", 1.25)
        g.shape(2, "^24,66 ^96,66 ^96,106 ^24,106 z", 1.45)
        g.tint(-1, "^24,84 ^96,84 ^96,90 ^24,90 z")
        g.line("^24,84 ^96,84", 0.6)
        g.line("^24,90 ^96,90", 0.6)
        g.shape(-1, "^22,66 24,56 ^60,50 96,56 ^98,66 90,74 ^80,68 70,80 ^60,70 50,76 ^40,68 30,76 z", 1.2)
        g.shape(0, .circle(60, 44, 7), 1)
        g.line("^60,37 66,28 ^72,26", 0.65)
        g.shape(1, K.leaf((66, 28), (78, 22), belly: 5), 0.6)
        g.detail(0.2) { g in
            g.speckle(30, 94, 90, 104, n: 10, r: 0.6, seed: 71)
            g.line("^84,94 ^94,94", 0.42)
        }
        // The dome is only a line and a glint, so what is under it stays visible.
        g.line("^4,110 4,62 18,26 ^60,10 102,26 116,62 ^116,110", 1.2)
        g.shape(0, .circle(60, 4, 6.4), 1)
        g.gel("^14,62 ^24,34", 1.1)
        g.gel("^92,36 ^96,44", 0.8)
        return g
    }

    static func bookStack() -> DoodleGlyph {
        var g = DoodleGlyph("bookStack", 0.22, 0.42, tilt: 9)
        g.must = true
        // Three fat books, spines to us, reading glasses resting on top, a ribbon marker.
        func book(_ g: inout DoodleGlyph, x: Double, y: Double, w: Double, h: Double, sep: Int) {
            g.shape(-1, .rrect(x + 3, y + 2, w, h - 4, 1), 0.9)
            g.detail(0.2) { g in
                g.line(.poly([(x + w, y + h * 0.36), (x + w + 2.6, y + h * 0.36)]), 0.42)
                g.line(.poly([(x + w, y + h * 0.66), (x + w + 2.6, y + h * 0.66)]), 0.42)
            }
            g.shape(sep, .rrect(x, y, w, h, 3), 1.45)
            g.line(.poly([(x + 9, y), (x + 9, y + h)]), 0.65)
            g.line(.poly([(x + w - 9, y), (x + w - 9, y + h)]), 0.65)
        }
        book(&g, x: 0, y: 74, w: 124, h: 28, sep: 1)
        g.line("^30,84 ^92,84", 1)
        g.line("^40,92 ^82,92", 0.6)
        book(&g, x: 14, y: 46, w: 108, h: 28, sep: 2)
        g.shape(-1, .rrect(46, 52, 44, 16, 1.5), 0.75)
        g.line("^52,60 ^84,60", 0.6)
        book(&g, x: 6, y: 20, w: 100, h: 26, sep: 0)
        g.shape(1, DoodleFillers.starPath(56, 33, 7), 0.6)
        g.shape(1, "^86,46 ^92,46 ^92,62 ^89,58 ^86,62 z", 0.6)
        // Glasses.
        g.line(.circle(36, 8, 10), 1.2)
        g.line(.circle(66, 8, 10), 1.2)
        g.line("^46,7 51,4 ^56,7", 1)
        g.line("^76,6 ^98,14", 1)
        g.line("^26,6 ^14,14", 0.9)
        g.gel("^30,6 ^34,2", 0.7)
        g.gel("^60,6 ^64,2", 0.7)
        return g
    }

    static func pencilCup() -> DoodleGlyph {
        var g = DoodleGlyph("pencilCup", 0.2, 0.42, tilt: 10)
        g.must = true
        // A tin of pencils, a brush, a pair of scissors' loops, all leaning differently.
        func pen(_ g: inout DoodleGlyph, x0: Double, x1: Double, top: Double, sep: Int) {
            let a = atan2(x1 - x0, 60.0 - top)
            let w = 5.0
            let cx = cos(a) * w, sy = sin(a) * w
            let t = (x1, top)
            let bl = (x1 - cx + sin(a) * 12, top + 12 * cos(a) + sy * 0.6)
            let br = (x1 + cx + sin(a) * 12, top + 12 * cos(a) - sy * 0.6)
            let b0 = (x0 - cx, 60.0), b1 = (x0 + cx, 60.0)
            g.shape(sep, .poly([bl, br, b1, b0], closed: true), 1.15)
            g.shape(-1, .poly([t, br, bl], closed: true), 0.9)
            g.blot(.poly([t, (t.0 + (br.0 - t.0) * 0.4, t.1 + (br.1 - t.1) * 0.4), (t.0 + (bl.0 - t.0) * 0.4, t.1 + (bl.1 - t.1) * 0.4)], closed: true))
        }
        pen(&g, x0: 24, x1: 8, top: 0, sep: 1)
        pen(&g, x0: 64, x1: 82, top: -2, sep: 0)
        pen(&g, x0: 48, x1: 52, top: -16, sep: 2)
        // A paint brush.
        g.shape(1, DoodlePath.taper([(34, 60), (32, 8)], 5, 3.4), 1)
        g.shape(0, "^28,8 ^37,8 ^38,-8 33,-20 ^27,-8 z", 1.05)
        g.line("^28,6 ^37,6", 0.42)
        // Scissor loops.
        g.line(.ellipse(72, 28, 7, 9), 1)
        g.line("^70,37 ^66,60", 0.9)
        // The tin itself.
        g.shape(-1, "^8,54 ^88,54 ^82,132 ^14,132 z", 1.6)
        g.shape(0, "^9.4,70 ^86.6,70 ^84,112 ^12,112 z", 1)
        g.shape(-1, .rrect(26, 80, 44, 22, 1.5), 0.75)
        g.line("^32,88 ^64,88", 0.8)
        g.line("^36,95 ^60,95", 0.5)
        g.accent(.ellipse(48, 55, 40, 4.4))
        g.detail(0.2) { g in
            g.hatch("^66,118 ^82,118 ^80,130 ^68,130 z", angle: 66, gap: 2.8, w: 0.42)
            g.gel("^16,62 ^17,68", 0.9)
            g.gel("^18,116 ^19,126", 0.9)
        }
        return g
    }

    static func espressoMachine() -> DoodleGlyph {
        var g = DoodleGlyph("espressoMachine", 0.24, 0.44, tilt: 9)
        g.must = true
        g.noFlip = true
        // A boxy home machine: gauge, group head, portafilter, a steam wand, cups warming on top.
        for (x, s) in [(20.0, 2), (44.0, 0), (70.0, 2)] {
            g.shape(s, "^\(x),-14 ^\(x + 20),-14 ^\(x + 17),2 ^\(x + 3),2 z", 1.05)
        }
        g.shape(-1, .rrect(4, 2, 112, 44, 3), 1.55)
        g.shape(-1, .rrect(4, 104, 112, 18, 3), 1.5)
        g.shape(2, .rrect(10, 44, 16, 62, 1), 1.3)
        g.shape(2, .rrect(94, 44, 16, 62, 1), 1.3)
        g.accent(.rrect(26, 46, 68, 58, 1))
        g.shape(-1, .circle(30, 24, 13), 1.15)
        g.line(.poly([(30, 24), (37, 18)]), 0.9)
        g.blot(.circle(30, 24, 1.8))
        g.detail(0.2) { g in
            for i in 0..<9 {
                let a = 150.0 + Double(i) * 30
                g.line(.poly([K.polar(30, 24, 8.8, a), K.polar(30, 24, 11.4, a)]), 0.42)
            }
            g.stitch("^10,114 ^110,114", dash: 3.4, gap: 2.8, w: 0.6)
        }
        g.shape(1, .circle(60, 14, 5.4), 0.95)
        g.shape(1, .circle(76, 14, 5.4), 0.95)
        g.shape(0, .circle(92, 14, 5.4), 0.95)
        g.line("^52,32 ^100,32", 0.5)
        g.line("^52,38 ^88,38", 0.5)
        // The group and handle, and a tiny cup catching two threads.
        g.shape(-1, .rrect(46, 46, 28, 12, 2), 1.05)
        g.shape(-1, .rrect(48, 58, 24, 7, 1.5), 1)
        g.shape(1, "^72,59 ^96,62 ^96,68 ^72,65 z", 1)
        g.line("^56,65 ^56,84", 0.6)
        g.line("^64,65 ^64,84", 0.6)
        g.shape(-1, "^44,84 ^76,84 ^72,102 ^48,102 z", 1)
        g.line("^76,88 84,88 84,96 ^74,97", 0.75)
        // The steam wand.
        g.line("^32,48 ^30,88", 1)
        g.shape(1, .rrect(27, 86, 7, 7, 1.5), 0.7)
        return g
    }

    static func typewriter() -> DoodleGlyph {
        var g = DoodleGlyph("typewriter", 0.24, 0.44, tilt: 9)
        g.must = true
        g.noFlip = true
        // A sheet in a portable, rows of round keys, a carriage lever.
        g.shape(-1, "^34,-18 ^102,-18 ^104,34 ^32,34 z", 1.3)
        g.line("^44,-6 ^92,-6", 0.9)
        g.line("^44,4 ^86,4", 0.55)
        g.line("^44,12 ^92,12", 0.55)
        g.line("^44,20 ^74,20", 0.55)
        g.shape(1, .rrect(10, 26, 116, 13, 6), 1.4)
        g.shape(1, .rrect(0, 28, 11, 9, 2.5), 1)
        g.shape(1, .rrect(125, 28, 11, 9, 2.5), 1)
        g.line("^-2,28 ^-14,14", 1.15)
        g.blot(.circle(-14, 13, 2.6))
        g.shape(0, "^10,38 ^126,38 ^140,108 ^-4,108 z", 1.6)
        g.accent(.rrect(42, 40, 52, 11, 1))
        g.detail(0.2) { g in
            for i in 0..<7 {
                let a = 200.0 + Double(i) * 23
                let p = K.polar(68, 56, 22, a)
                g.line(.poly([(68, 51), p]), 0.42)
            }
        }
        // Keys.
        for (r, n) in [(0, 9), (1, 9), (2, 8)] {
            let y = 64 + Double(r) * 11.4
            let w = 92 + Double(r) * 8
            for i in 0..<n {
                let x = 68 - w / 2 + (Double(i) + 0.5) * w / Double(n)
                g.shape(-1, .circle(x, y, 4), 0.75)
            }
        }
        g.shape(-1, .rrect(36, 96, 64, 7, 3), 0.8)
        g.blot(.rrect(4, 108, 16, 5, 1.5))
        g.blot(.rrect(116, 108, 16, 5, 1.5))
        return g
    }

    static func frenchPress() -> DoodleGlyph {
        var g = DoodleGlyph("frenchPress", 0.18, 0.26, tilt: 7)
        g.noFlip = true
        // A glass beaker in a metal frame, coffee below, the plunger pulled up.
        g.line("^44,-20 ^44,18", 1.2)
        g.shape(1, .circle(44, -24, 6.4), 1.05)
        g.shape(2, "^12,10 ^76,10 ^80,20 ^8,20 z", 1.4)
        g.shape(-1, .rrect(10, 20, 68, 92, 3), 1.55)
        g.tint(0, .rrect(11, 46, 66, 66, 2))
        g.line("^11,46 ^77,46", 0.9)
        g.shape(1, "^12,30 ^76,30 ^76,36 ^12,36 z", 0.75)
        g.line("^44,20 ^44,30", 0.8)
        g.band(1, outer: "^78,30 100,28 110,44 106,76 ^78,92 ^78,82 96,70 100,46 94,38 ^78,40 z", inner: "^78,30 ^78,30 ^78,30 z", 1.3, innerW: 0)
        g.shape(2, .rrect(6, 110, 76, 11, 2.5), 1.35)
        g.line("^4,48 ^2,110", 0)
        g.detail(0.18) { g in
            g.gel("^18,50 ^18,100", 1.1)
            g.speckle(24, 54, 70, 104, n: 10, r: 0.7, seed: 81)
            g.line("^62,24 ^70,24", 0.42)
        }
        g.line("^30,20 ^30,110", 0.6)
        g.line("^58,20 ^58,110", 0.6)
        return g
    }

    static func dripper() -> DoodleGlyph {
        var g = DoodleGlyph("dripper", 0.14, 0.26, tilt: 7)
        g.noFlip = true
        // A gooseneck kettle pouring into a cone over a carafe.
        g.shape(-1, "^20,92 ^74,92 90,120 ^86,130 ^8,130 ^4,120 z", 1.5)
        g.tint(0, "^12,108 ^82,108 ^90,120 ^86,130 ^8,130 ^4,120 z")
        g.line("^12,108 ^82,108", 0.75)
        g.shape(2, "^18,62 ^76,62 ^58,88 ^36,88 z", 1.4)
        g.line("^34,62 ^44,88", 0.5)
        g.line("^60,62 ^50,88", 0.5)
        g.shape(2, .rrect(26, 88, 42, 6, 2), 1.15)
        g.shape(-1, "^14,54 ^80,54 ^78,62 ^16,62 z", 0.8)
        g.line("^47,94 ^47,100", 0.7)
        // Kettle.
        g.shape(1, "^86,28 98,10 ^124,8 ^138,18 ^142,48 ^84,50 z", 1.5)
        g.line("^86,40 72,30 ^68,12 ^50,4 ^46,14", 1.45)
        g.line("^46,14 ^48,18", 1.2)
        g.line("^112,8 ^112,0", 1.1)
        g.blot(.circle(112, -2, 3))
        g.line("^138,14 154,14 158,28 ^142,42", 1.2)
        g.stitch("^46,20 ^46,52", dash: 3, gap: 2, w: 0.75)
        g.detail(0.2) { g in
            g.gel("^94,20 ^90,38", 1)
            g.hatch("^122,16 ^138,20 ^140,46 ^122,48 z", angle: 76, gap: 3, w: 0.42)
        }
        return g
    }

    static func takeaway() -> DoodleGlyph {
        var g = DoodleGlyph("takeaway", 0.13, 0.24, tilt: 14)
        // A paper cup, ribbed sleeve, lid with a sip hole.
        g.shape(-1, "^8,18 ^64,18 ^54,110 ^18,110 z", 1.5)
        g.shape(0, "^10.6,44 ^61.4,44 ^57.6,80 ^14.4,80 z", 1.25)
        g.detail(0.13) { g in
            for x in stride(from: 18.0, through: 54.0, by: 6) { g.line(.poly([(x, 46), (x + (36 - x) * 0.06, 78)]), 0.42) }
            g.gel("^14,24 ^15,40", 0.9)
        }
        g.shape(2, DoodleFillers.heartPath(36, 60, 8), 0.65)
        g.shape(2, "^2,10 ^70,10 ^72,20 ^0,20 z", 1.25)
        g.shape(2, "^10,10 16,2 ^56,2 ^62,10 z", 1.15)
        g.blot(.ellipse(46, 6, 4, 1.8))
        return g
    }

    static func grinder() -> DoodleGlyph {
        var g = DoodleGlyph("grinder", 0.13, 0.26, tilt: 7)
        g.noFlip = true
        // A wooden box mill with a little drawer and a crank.
        g.line("^46,22 ^46,2 ^84,-6", 1.35)
        g.shape(2, .circle(88, -8, 7), 1.05)
        g.shape(1, "^22,30 28,18 ^46,14 64,18 ^70,30 z", 1.4)
        g.blot(.circle(46, 12, 3.2))
        g.shape(1, "^24,30 ^68,30 ^64,44 ^28,44 z", 1.25)
        g.shape(0, .rrect(4, 44, 84, 62, 3), 1.55)
        g.line("^4,54 ^88,54", 0.6)
        g.shape(-1, .rrect(20, 66, 52, 28, 2), 1.05)
        g.shape(1, .circle(46, 80, 4), 0.8)
        g.detail(0.16) { g in
            g.line("^8,62 ^16,62", 0.42)
            g.line("^76,72 ^84,72", 0.42)
            g.line("^8,94 ^16,94", 0.42)
            g.hatch("^76,58 ^86,58 ^86,104 ^76,104 z", angle: 78, gap: 2.8, w: 0.42)
        }
        g.blot(.circle(10, 110, 2.2))
        g.blot(.circle(82, 110, 2.2))
        return g
    }

    static func openBook() -> DoodleGlyph {
        var g = DoodleGlyph("openBook", 0.14, 0.25, tilt: 12)
        // An open book with squiggled text, a ribbon, soft curled pages.
        g.shape(2, "^-4,16 ^124,16 ^128,86 ^60,86 ^-8,86 z", 1.4)
        g.shape(-1, "^0,12 20,6 44,8 ^60,18 76,8 100,6 ^120,12 ^122,78 100,72 76,74 ^60,82 44,74 20,72 ^-2,78 z", 1.45)
        g.line("^60,18 ^60,82", 0.9)
        for y in [22.0, 32.0, 42.0, 52.0, 62.0] {
            g.line(.spline([(8, y), (20, y - 2), (32, y + 1), (50, y + 1)]), 0.55)
            g.line(.spline([(70, y + 1), (86, y - 1), (100, y + 1), (112, y - 1)]), 0.55)
        }
        g.shape(0, "^70,78 ^78,76 ^78,100 ^74,94 ^70,100 z", 0.8)
        return g
    }

    static func pothos() -> DoodleGlyph {
        var g = DoodleGlyph("pothos", 0.15, 0.26, tilt: 6)
        g.noFlip = true
        // A hanging pot on cords, a trailing vine with heart leaves.
        g.line("^46,-16 ^10,36", 0.7)
        g.line("^46,-16 ^82,36", 0.7)
        g.line(.circle(46, -22, 5), 0.85)
        g.shape(2, "^8,36 ^84,36 76,66 ^56,76 ^36,76 16,66 z", 1.5)
        g.line("^10,46 ^82,46", 0.5)
        g.shape(1, K.leaf((30, 36), (14, 18), belly: 16), 1)
        g.shape(1, K.leaf((46, 36), (46, 12), belly: 16), 1)
        g.shape(1, K.leaf((62, 36), (78, 18), belly: 16), 1)
        // Two trailing vines.
        g.line("20,40 6,68 12,96 ^2,128", 0.75)
        g.line("74,40 90,62 84,92 92,116 ^84,136", 0.75)
        for (x, y, a) in [(6.0, 68.0, -60.0), (12.0, 92.0, 40.0), (6.0, 116.0, -50.0), (90.0, 62.0, 40.0), (86.0, 88.0, -50.0), (90.0, 112.0, 50.0), (84.0, 136.0, -10.0)] {
            let p = DoodleFillers.heartPath(0, 0, 8.6).rotated(a + 180, about: (0, 0)).moved(x, y)
            g.shape(1, p, 0.85)
        }
        return g
    }

    static func cactusPot() -> DoodleGlyph {
        var g = DoodleGlyph("cactusPot", 0.09, 0.22, tilt: 7)
        g.noFlip = true
        // A round barrel cactus with a flower in a small painted pot.
        g.shape(1, .ellipse(30, 32, 25, 28), 1.4)
        for x in [16.0, 30.0, 44.0] { g.line(.ellipse(30, 32, abs(x - 30) + 0.5, 27), 0.42) }
        g.shape(2, K.puff(30, 4, 6, 5, n: 5), 0.75)
        g.shape(2, "^8,54 ^52,54 ^46,86 ^14,86 z", 1.4)
        g.shape(-1, .rrect(4, 50, 52, 9, 1.5), 1.1)
        g.stitch("^12,70 ^48,70", dash: 2, gap: 2, w: 0.7)
        return g
    }

    static func snakePlant() -> DoodleGlyph {
        var g = DoodleGlyph("snakePlant", 0.13, 0.25, tilt: 6)
        g.noFlip = true
        // Upright sword leaves, banded, in a basket.
        let leaves: [((Double, Double), (Double, Double), Double)] = [((20, 78), (2, 10), 12), ((62, 78), (82, 14), 12), ((32, 78), (26, -14), 14), ((50, 78), (58, -8), 14), ((42, 78), (40, 14), 11)]
        for (i, (a, b, w)) in leaves.enumerated() {
            g.shape(1, K.leaf(a, b, belly: w * 1.3, bias: 0.46), 1.15)
            let mx = (a.0 + b.0) / 2, my = (a.1 + b.1) / 2
            for t in [-0.3, -0.1, 0.1, 0.3] {
                let x = mx + (b.0 - a.0) * t, y = my + (b.1 - a.1) * t
                g.line(.poly([(x - w * 0.26, y - 1), (x + w * 0.26, y + 2)]), 0.42)
            }
            _ = i
        }
        g.shape(0, "^8,74 ^76,74 ^68,124 ^16,124 z", 1.5)
        for y in [84.0, 94.0, 104.0, 114.0] { g.line(.poly([(8 + (y - 74) * 0.16, y), (76 - (y - 74) * 0.16, y)]), 0.5) }
        return g
    }

    static func vinyl() -> DoodleGlyph {
        var g = DoodleGlyph("vinyl", 0.13, 0.24, tilt: 18)
        // A record sliding out of a plain sleeve with a blob design.
        g.accent(.circle(84, 50, 44))
        g.shape(2, .circle(84, 50, 15), 0.85)
        g.blot(.circle(84, 50, 2))
        g.gel(K.arc(84, 50, 34, 34, 300, 360), 0.8)
        g.gel(K.arc(84, 50, 26, 26, 310, 355), 0.6)
        g.shape(0, .rrect(0, 0, 96, 100, 2), 1.5)
        g.shape(-1, .circle(48, 48, 26), 1)
        g.tint(1, "^30,48 38,34 ^48,44 ^58,32 ^68,50 60,66 ^48,58 ^36,66 z")
        g.line("^10,88 ^56,88", 0.7)
        g.line("^68,88 ^86,88", 0.5)
        return g
    }

    static func cakeSlice() -> DoodleGlyph {
        var g = DoodleGlyph("cakeSlice", 0.13, 0.32, tilt: 10)
        // A wedge with cream between its layers, a cherry on top, fork marks on the plate.
        g.shape(-1, .ellipse(50, 84, 56, 9), 1.2)
        g.shape(2, "^12,44 ^90,28 ^90,84 ^12,84 z", 1.45)
        g.tint(-1, "^12,60 ^90,48 ^90,54 ^12,66 z")
        g.line("^12,60 ^90,48", 0.65)
        g.line("^12,66 ^90,54", 0.65)
        g.shape(-1, "^4,44 ^12,44 ^90,28 96,36 ^80,48 ^68,36 ^50,50 ^38,42 ^26,54 ^14,48 z", 1.1)
        g.shape(2, .circle(58, 26, 8), 1)
        g.line("^58,18 ^68,6", 0.75)
        g.gel("^54,24 ^56,21", 0.7)
        g.detail(0.14) { $0.speckle(18, 68, 84, 80, n: 8, r: 0.6, seed: 91) }
        return g
    }

    static func pencil() -> DoodleGlyph {
        var g = DoodleGlyph("pencil", 0.1, 0.36, tilt: 46)
        g.shape(1, .rrect(0, 0, 12, 12, 3.4), 1.1)
        g.shape(-1, .rrect(0, 10, 12, 8, 1), 0.9)
        g.line("^0,14 ^12,14", 0.42)
        g.shape(0, "^0,18 ^12,18 ^12,112 ^0,112 z", 1.25)
        g.line("^4,18 ^4,112", 0.42)
        g.line("^8,18 ^8,112", 0.42)
        g.shape(-1, "^0,112 ^12,112 ^6,132 z", 1.05)
        g.blot("^4.4,126 ^7.6,126 ^6,132 z")
        return g
    }

    static func eraser() -> DoodleGlyph {
        var g = DoodleGlyph("eraser", 0.05, 0.13, tilt: 34)
        g.shape(-1, "^0,12 ^60,0 ^74,18 ^14,32 z", 1.2)
        g.shape(2, "^26,6.8 ^60,0 ^74,18 ^38,26.6 z", 0.8)
        g.shape(-1, "^0,12 ^14,32 ^14,44 ^0,24 z", 1)
        g.shape(2, "^14,32 ^74,18 ^74,30 ^14,44 z", 1)
        return g
    }

    static func notebook() -> DoodleGlyph {
        var g = DoodleGlyph("notebook", 0.11, 0.3, tilt: 14)
        g.noFlip = true
        // A spiral notebook with a small doodle and a sprig on its label.
        g.shape(0, .rrect(4, 4, 76, 100, 3), 1.5)
        g.shape(-1, .rrect(20, 18, 48, 26, 1.5), 0.9)
        g.line("^26,27 ^62,27", 0.6)
        g.line("^26,35 ^52,35", 0.6)
        g.shape(1, K.leaf((44, 90), (32, 62), belly: 11), 0.75)
        g.shape(1, K.leaf((44, 90), (58, 66), belly: 11), 0.75)
        g.line("^44,92 ^44,68", 0.5)
        for y in stride(from: 12.0, through: 96.0, by: 12) {
            g.line(.ellipse(4, y, 6, 3.4), 0.65)
        }
        return g
    }

    static func donut() -> DoodleGlyph {
        var g = DoodleGlyph("donut", 0.1, 0.26, tilt: 30)
        let hole = DoodlePath.ellipse(44, 40, 13, 11)
        g.band(0, outer: .ellipse(44, 42, 44, 40), inner: hole, 1.5, innerW: 1)
        g.band(2, outer: "^4,38 8,16 26,4 44,2 62,4 80,16 84,38 ^78,50 ^68,44 ^62,60 ^50,54 ^38,64 ^28,52 ^16,58 z", inner: hole, 1.05, innerW: 1)
        let spr: [(Double, Double, Double, Int)] = [(18, 26, 30, 1), (30, 14, -30, -1), (60, 14, 40, 1), (72, 30, -20, -1), (22, 42, 70, -1), (66, 46, 10, 1), (44, 60, 50, 1)]
        for (x, y, a, s) in spr {
            g.shape(s, DoodlePath.rrect(x - 4, y - 1.4, 8, 2.8, 1.2).rotated(a, about: (x, y)), 0.45)
        }
        g.detail(0.12) { $0.gel("^12,26 ^22,12", 1) }
        return g
    }

    static func cookie() -> DoodleGlyph {
        var g = DoodleGlyph("cookie", 0.07, 0.18, tilt: 30)
        // A chipped cookie with a bite gone.
        g.shape(0, "^62,6 42,0 18,6 4,24 2,46 12,66 34,76 58,70 72,52 ^74,36 ^64,36 ^58,26 ^52,24 ^62,18 z", 1.45)
        for (x, y, r) in [(24.0, 22.0, 5.0), (42.0, 40.0, 5.6), (20.0, 50.0, 4.4), (54.0, 56.0, 4.2), (40.0, 14.0, 3.4)] {
            g.accent(.ellipse(x, y, r, r * 0.86))
        }
        g.detail(0.1) { $0.speckle(10, 12, 66, 66, n: 8, r: 0.5, seed: 101) }
        return g
    }

    static func muffin() -> DoodleGlyph {
        var g = DoodleGlyph("muffin", 0.09, 0.24, tilt: 12)
        g.shape(2, "^10,46 ^66,46 ^58,84 ^18,84 z", 1.4)
        for x in [22.0, 32.0, 44.0, 54.0] { g.line(.poly([(x, 48), (38 + (x - 38) * 0.76, 84)]), 0.5) }
        g.shape(0, "^4,46 0,28 14,12 ^38,4 62,12 76,28 ^72,46 58,52 ^38,48 18,52 z", 1.5)
        for (x, y) in [(20.0, 28.0), (38.0, 16.0), (56.0, 30.0), (34.0, 36.0), (48.0, 40.0)] {
            g.accent(.ellipse(x, y, 3.6, 3))
        }
        g.detail(0.12) { $0.gel("^10,28 ^18,18", 0.9) }
        return g
    }

    static func bagel() -> DoodleGlyph {
        var g = DoodleGlyph("bagel", 0.07, 0.18, tilt: 30)
        g.band(0, outer: .ellipse(36, 32, 36, 30), inner: .ellipse(36, 32, 10, 8), 1.45, innerW: 1)
        for (x, y, a) in [(14.0, 20.0, 20.0), (28.0, 10.0, -30.0), (48.0, 10.0, 50.0), (60.0, 26.0, -10.0), (56.0, 44.0, 30.0), (36.0, 52.0, 80.0), (16.0, 42.0, -40.0)] {
            g.shape(-1, K.leaf((x - 3, y), (x + 3, y), belly: 3).rotated(a, about: (x, y)), 0.42)
        }
        return g
    }

    static func pretzel() -> DoodleGlyph {
        var g = DoodleGlyph("pretzel", 0.08, 0.2, tilt: 30)
        // A single rope of dough, its two ends crossing in the middle and pressed onto the lower rim.
        let rope: [(Double, Double)] = [(36, 92), (46, 72), (58, 56), (74, 34), (92, 12), (112, 26), (114, 56), (92, 84), (58, 96), (24, 84), (2, 56), (4, 26), (24, 12), (42, 34), (58, 56), (70, 72), (80, 92)]
        g.shape(0, DoodlePath.taper(rope, 12, 12), 1.15)
        for (x, y) in [(10.0, 40.0), (24.0, 10.0), (38.0, 28.0), (78.0, 28.0), (92.0, 10.0), (106.0, 40.0), (30.0, 82.0), (84.0, 82.0), (58.0, 94.0)] {
            g.shape(-1, .rrect(x, y, 3.2, 3.2, 0.4), 0.42)
        }
        g.detail(0.12) { $0.gel("^8,30 ^16,20", 0.8) }
        return g
    }

    static func cinnamonRoll() -> DoodleGlyph {
        var g = DoodleGlyph("cinnamonRoll", 0.09, 0.24, tilt: 18)
        g.shape(0, "44,2 72,10 86,34 84,60 64,80 34,84 8,70 0,44 10,16 z", 1.5)
        var pts: [(Double, Double)] = []
        for i in 0...34 {
            let a = Double(i) * 20 - 40
            let r = 3 + Double(i) * 1.02
            pts.append(K.polar(43, 43, r, a))
        }
        g.line(.spline(pts), 1.05)
        // A zigzag of icing thrown across it.
        let zig: [(Double, Double)] = [(10, 26), (34, 12), (22, 36), (58, 14), (36, 52), (76, 28), (50, 68), (78, 50)]
        g.shape(-1, DoodlePath.taper(zig, 4.6, 3.4), 0.72)
        return g
    }

    static func toast() -> DoodleGlyph {
        var g = DoodleGlyph("toast", 0.08, 0.2, tilt: 18)
        g.shape(0, "^10,80 ^8,40 0,30 2,12 18,2 42,2 62,2 78,12 78,30 72,40 ^70,80 z", 1.5)
        g.shape(-1, "^18,74 ^16,38 10,28 12,16 22,10 58,10 68,16 70,28 64,38 ^62,74 z", 0.85)
        g.shape(2, DoodleFillers.heartPath(40, 40, 15), 0.8)
        g.detail(0.1) { $0.speckle(20, 16, 60, 68, n: 10, r: 0.42, seed: 111) }
        return g
    }

    static func waffle() -> DoodleGlyph {
        var g = DoodleGlyph("waffle", 0.09, 0.24, tilt: 24)
        g.shape(0, .circle(44, 44, 42), 1.5)
        func inside(_ x: Double, _ y: Double) -> Double { (max(0, 39 * 39 - (x - 44) * (x - 44))).squareRoot() + 0 * y }
        for x in stride(from: 14.0, through: 74.0, by: 12) {
            let h = inside(x, 0)
            g.line(.poly([(x, 44 - h), (x, 44 + h)]), 0.65)
        }
        for y in stride(from: 14.0, through: 74.0, by: 12) {
            let h = inside(y, 0)
            g.line(.poly([(44 - h, y), (44 + h, y)]), 0.65)
        }
        // A pat of butter and a drip of syrup.
        g.shape(-1, "^34,30 ^56,28 ^60,48 ^38,50 z", 0.95)
        g.shape(2, "^62,46 ^70,46 72,60 66,70 ^60,62 z", 0.75)
        return g
    }

    static func tart() -> DoodleGlyph {
        var g = DoodleGlyph("tart", 0.09, 0.24, tilt: 14)
        // A fluted crust seen from the side, berries piled on top, mint.
        g.shape(0, "^2,40 ^98,40 ^88,74 ^12,74 z", 1.45)
        for x in stride(from: 12.0, through: 88.0, by: 9.5) { g.line(.poly([(x, 46), (50 + (x - 50) * 0.92, 73)]), 0.5) }
        g.line("^10,46 ^90,46", 0.5)
        g.shape(-1, .ellipse(50, 38, 48, 11), 1.25)
        for (x, y, r, s) in [(20.0, 34.0, 8.0, 2), (36.0, 28.0, 8.4, 2), (54.0, 26.0, 8.0, 2), (72.0, 30.0, 8.4, 2), (84.0, 37.0, 6.4, 2), (44.0, 38.0, 6.4, 2), (62.0, 40.0, 6.4, 2)] {
            g.shape(s, .circle(x, y, r), 0.9)
            g.blot(.circle(x + 1.6, y - 2, 0.9))
        }
        g.shape(1, K.leaf((50, 22), (40, 6), belly: 9), 0.7)
        g.shape(1, K.leaf((50, 22), (62, 8), belly: 9), 0.7)
        return g
    }

    static func baguette() -> DoodleGlyph {
        var g = DoodleGlyph("baguette", 0.14, 0.38, tilt: 42)
        g.shape(0, "^4,18 26,4 76,2 124,6 ^150,18 138,30 88,36 36,36 z", 1.5)
        for (x, r) in [(30.0, 0.0), (58.0, 0.0), (86.0, 0.0), (114.0, 0.0)] {
            _ = r
            g.shape(-1, K.leaf((x - 8, 28), (x + 20, 8), belly: 9), 0.9)
        }
        g.detail(0.14) { g in
            g.speckle(20, 30, 130, 34, n: 8, r: 0.5, seed: 121)
            g.hatch("^40,31 ^130,27 ^90,35 ^44,35 z", angle: 8, gap: 2.4, w: 0.42)
        }
        return g
    }

    static func milkJug() -> DoodleGlyph {
        var g = DoodleGlyph("milkJug", 0.1, 0.26, tilt: 10)
        g.noFlip = true
        // A round-bellied steel pitcher with a real pouring lip, a looped handle and a drip about to fall.
        g.band(0, outer: "^60,20 78,16 90,28 88,46 74,60 ^62,64 ^62,54 72,48 79,38 78,28 72,26 ^60,30 z", inner: "^60,20 ^60,20 ^60,20 z", 1.25, innerW: 0)
        // Belly, then the neck sweeping up to the lip.
        g.shape(-1, "^-12,4 4,10 ^26,6 ^62,10 60,22 62,32 72,52 72,70 60,84 ^44,88 ^20,88 6,84 -6,70 -6,52 4,32 6,22 z", 1.5)
        // The milk seen through the mouth.
        g.accent("^-8,6 4,4 ^26,2 ^60,10 34,15 8,13 z")
        g.shape(-1, "^-4,6.5 8,6 ^26,5 ^52,10 34,12.5 10,11 z", 0.6)
        g.line("^4,24 30,29 ^61,24", 0.55)
        // The drip.
        g.shape(-1, "^-13,8 -16,15 -13,19 -10,15 z", 0.8)
        g.detail(0.12) { g in
            g.gel("^4,44 ^2,66", 1.1)
            g.gel("^10,72 ^16,78", 0.8)
            g.hatch("^46,36 ^64,40 ^68,70 ^48,84 z", angle: 78, gap: 2.8, w: 0.42)
        }
        return g
    }

    static func sugarBowl() -> DoodleGlyph {
        var g = DoodleGlyph("sugarBowl", 0.08, 0.2, tilt: 8)
        // A squat sugar jar with cubes showing, a pair of tongs.
        g.shape(2, "^4,26 ^64,26 66,50 54,70 ^14,70 2,50 z", 1.45)
        g.shape(-1, .rrect(14, 12, 16, 16, 1), 0.85)
        g.shape(-1, .rrect(30, 8, 16, 16, 1), 0.85)
        g.shape(-1, .rrect(44, 14, 14, 14, 1), 0.85)
        g.shape(-1, .ellipse(34, 26, 30, 4), 1)
        g.detail(0.1) { $0.gel("^10,38 ^14,54", 0.9) }
        return g
    }

    static func spoonFork() -> DoodleGlyph {
        var g = DoodleGlyph("spoonFork", 0.1, 0.28, tilt: 22)
        // A spoon and cake fork lying crossed, tied with a sage ribbon.
        g.shape(-1, .ellipse(16, 14, 11, 14), 1.25)
        g.gel("^10,8 ^12,18", 0.6)
        g.shape(-1, DoodlePath.taper([(18, 27), (46, 112)], 3.2, 4.4), 1.05)
        g.shape(-1, "^62,0 ^62,16 ^66,16 ^66,0 ^70,0 ^70,16 ^74,16 ^74,0 ^78,0 ^78,20 72,32 ^72,34 ^40,114 ^34,112 ^62,32 ^60,20 z", 1.15)
        g.shape(1, "^30,66 ^54,62 ^58,74 ^34,78 z", 0.9)
        g.shape(1, "^38,76 ^28,92 ^38,90 ^46,76 z", 0.7)
        return g
    }

    static func teabag() -> DoodleGlyph {
        var g = DoodleGlyph("teabag", 0.08, 0.22, tilt: 22)
        g.noFlip = true
        // A pyramid of a bag on a string with a heart tag.
        g.shape(-1, "^12,14 ^52,14 ^60,70 ^4,70 z", 1.35)
        g.tint(0, "^8,44 20,50 ^32,46 44,50 ^56,44 ^60,70 ^4,70 z")
        g.line("^8,44 20,50 32,46 44,50 ^56,44", 0.5)
        g.stitch("^6,64 ^58,64", dash: 1.8, gap: 1.6, w: 0.42)
        g.line("^30,14 36,-6 52,-14 ^66,-4", 0.65)
        g.shape(2, "^58,-4 ^80,-4 ^80,18 ^58,18 z", 0.9)
        g.shape(-1, DoodleFillers.heartPath(69, 7, 6), 0.5)
        return g
    }

    static func teaTin() -> DoodleGlyph {
        var g = DoodleGlyph("teaTin", 0.1, 0.26, tilt: 7)
        g.noFlip = true
        g.shape(2, .rrect(0, 0, 62, 16, 2), 1.3)
        g.shape(1, .rrect(3, 14, 56, 76, 2), 1.5)
        g.shape(-1, .rrect(10, 26, 42, 42, 1.5), 0.85)
        g.line(.circle(31, 44, 12), 0.6)
        g.shape(1, K.leaf((24, 52), (38, 36), belly: 9), 0.55)
        g.line("^16,60 ^46,60", 0.6)
        g.line("^10,76 ^52,76", 0.6)
        g.line("^10,82 ^52,82", 0.42)
        g.detail(0.12) { $0.gel("^7,20 ^7,86", 0.8) }
        return g
    }

    static func honeyJar() -> DoodleGlyph {
        var g = DoodleGlyph("honeyJar", 0.11, 0.28, tilt: 9)
        // A round jar, gingham top, and a dipper resting across it.
        g.shape(0, "^18,30 8,42 2,66 8,92 ^24,104 ^58,104 74,92 80,66 74,42 ^64,30 z", 1.5)
        g.shape(-1, .rrect(24, 56, 34, 28, 2), 0.85)
        g.shape(0, "^41,62 49,67 49,75 41,80 33,75 33,67 z", 0.6)
        g.shape(-1, "^12,30 ^70,30 ^78,18 ^4,18 z", 1.2)
        g.tint(2, "^4,18 ^20,18 ^16,30 ^12,30 z")
        g.tint(2, "^36,18 ^48,18 ^48,30 ^36,30 z")
        g.tint(2, "^64,18 ^78,18 ^70,30 ^64,30 z")
        g.line("^18,14 ^64,14", 0)
        g.line("^12,30 ^70,30", 0.9)
        // The dipper.
        g.line("^40,18 ^102,-16", 1.1)
        g.shape(0, .ellipse(108, -20, 11, 8.4, rot: -30), 1.1)
        for k in [-5.0, 0.0, 5.0] {
            let cx = 108 + k * 0.86, cy = -20 + k * 0.5
            g.line(.poly([(cx - 3.6, cy - 5.4), (cx + 3.6, cy + 5.4)]), 0.42)
        }
        g.detail(0.13) { $0.gel("^10,62 ^14,46", 1) }
        return g
    }

    static func coffeeBag() -> DoodleGlyph {
        var g = DoodleGlyph("coffeeBag", 0.13, 0.24, tilt: 9)
        g.noFlip = true
        // A kraft bag with a folded top, a tin-tie and a plain label.
        g.shape(0, "^6,12 ^76,12 ^84,110 ^-2,110 z", 1.55)
        g.shape(0, "^2,0 ^80,0 ^76,18 ^6,18 z", 1.3)
        g.shape(1, .rrect(-4, 10, 90, 4.6, 1.6), 0.85)
        g.shape(-1, .rrect(14, 34, 54, 58, 1.5), 1)
        // A bean and a couple of lines on the label.
        g.shape(2, .ellipse(41, 54, 14, 10, rot: -30), 1)
        g.line("^32,60 40,54 ^50,48", 0.8)
        g.line("^22,74 ^60,74", 1)
        g.line("^28,82 ^54,82", 0.55)
        g.detail(0.14) { g in
            g.hatch("^70,22 ^78,24 ^82,108 ^72,108 z", angle: 80, gap: 2.8, w: 0.42)
            g.line("^6,100 ^76,100", 0.42)
        }
        return g
    }

    static func scoop() -> DoodleGlyph {
        var g = DoodleGlyph("scoop", 0.07, 0.2, tilt: 30)
        // A wooden coffee scoop with a bean spill.
        g.shape(0, DoodlePath.taper([(46, 24), (102, 2)], 5, 6.4), 1.15)
        g.shape(0, .ellipse(26, 30, 26, 18, rot: -18), 1.4)
        g.accent(.ellipse(25, 27, 19, 11, rot: -18))
        g.shape(2, .ellipse(16, 26, 6, 4.4, rot: -30), 0.7)
        g.shape(2, .ellipse(28, 24, 6, 4.4, rot: 20), 0.7)
        g.shape(2, .ellipse(32, 32, 5.4, 4, rot: -40), 0.65)
        return g
    }

    static func jamJar() -> DoodleGlyph {
        var g = DoodleGlyph("jamJar", 0.09, 0.24, tilt: 10)
        g.noFlip = true
        // A cloth-topped jar with a string and a tag.
        g.shape(2, "^8,28 2,44 2,84 10,94 ^60,94 68,84 68,44 ^62,28 z", 1.5)
        g.shape(-1, "^-2,16 4,8 ^36,4 66,8 ^72,16 ^64,26 ^54,22 ^44,28 ^34,22 ^24,28 ^14,22 ^6,26 z", 1.1)
        g.line("^2,24 ^68,24", 0.9)
        g.shape(-1, .rrect(14, 44, 42, 30, 1.5), 0.85)
        g.shape(2, DoodleFillers.heartPath(35, 58, 8.6), 0.65)
        g.line("^68,24 78,30 ^84,40", 0.6)
        g.shape(1, "^78,40 ^92,40 ^92,58 ^78,58 z", 0.65)
        return g
    }

    static func catLoaf() -> DoodleGlyph {
        var g = DoodleGlyph("catLoaf", 0.13, 0.25, tilt: 7)
        // A cafe cat sat as a loaf on a stack of two books, tail hanging.
        g.shape(-1, "^6,66 2,44 10,26 ^10,2 ^24,12 ^40,12 ^54,2 ^54,24 80,22 104,34 112,54 ^106,76 ^10,76 z", 1.55)
        g.tint(0, "^54,24 80,22 104,34 112,54 ^106,76 ^72,76 64,52 z")
        g.tint(0, "^10,2 ^24,12 ^22,22 ^10,26 z")
        g.tint(0, "^40,12 ^54,2 ^54,24 ^44,24 z")
        g.line("^72,76 64,52 ^54,24", 0.6)
        // Sleepy eyes, nose, whiskers.
        g.line("^16,34 21,37 ^26,34", 0.8)
        g.line("^38,34 43,37 ^48,34", 0.8)
        g.blot("^29,42 ^35,42 ^32,46 z")
        g.line("^32,46 28,50 ^25,48", 0.5)
        g.line("^32,46 36,50 ^39,48", 0.5)
        g.line("^4,42 ^16,44", 0.42)
        g.line("^60,42 ^48,44", 0.42)
        g.detail(0.16) { g in
            g.line("^78,30 ^84,48", 0.5)
            g.line("^92,36 ^96,54", 0.5)
            g.hatch("^14,60 ^62,60 ^62,74 ^14,74 z", angle: 64, gap: 3, w: 0.42)
        }
        g.line("104,70 118,78 124,92 ^118,104", 1.3)
        g.shape(1, .rrect(-4, 76, 118, 14, 2), 1.3)
        g.shape(2, .rrect(4, 90, 104, 14, 2), 1.3)
        g.line("^10,76 ^10,90", 0.5)
        g.line("^16,90 ^16,104", 0.5)
        return g
    }

    static func deskLamp() -> DoodleGlyph {
        var g = DoodleGlyph("deskLamp", 0.15, 0.26, tilt: 6)
        // A jointed lamp with a cone shade, no rays.
        g.shape(0, "^18,0 ^36,-2 ^40,12 ^52,38 ^6,50 ^12,18 z", 1.5)
        g.shape(-1, .ellipse(30, 45, 12, 5, rot: -15), 0.85)
        g.blot(.circle(62, 34, 3.2))
        g.line("^36,10 ^62,34", 1.25)
        g.line("^62,34 ^44,88", 1.35)
        g.line("^68,34 ^50,88", 0.8)
        g.blot(.circle(46, 90, 3))
        g.line("^46,90 ^80,116", 1.35)
        g.line("^52,88 ^86,114", 0.8)
        g.shape(1, "^52,118 ^112,118 ^116,130 ^48,130 z", 1.45)
        g.line("^102,122 ^108,122", 0.5)
        return g
    }

    static func wallClock() -> DoodleGlyph {
        var g = DoodleGlyph("wallClock", 0.1, 0.26, tilt: 9)
        g.noFlip = true
        g.shape(0, .circle(46, 46, 44), 1.55)
        g.shape(-1, .circle(46, 46, 35), 1.05)
        g.detail(0.12) { g in
            for i in 0..<12 {
                let a = Double(i) * 30
                g.line(.poly([K.polar(46, 46, i % 3 == 0 ? 27 : 30, a), K.polar(46, 46, 33, a)]), i % 3 == 0 ? 0.8 : 0.45)
            }
        }
        g.line(.poly([(46, 46), (46, 20)]), 1.15)
        g.line(.poly([(46, 46), (62, 54)]), 1.25)
        g.blot(.circle(46, 46, 2.6))
        return g
    }

    static func chalkboard() -> DoodleGlyph {
        var g = DoodleGlyph("chalkboard", 0.14, 0.25, tilt: 5)
        g.noFlip = true
        g.noTuck = true
        // A sandwich board; the menu is only squiggled chalk, a cup and a heart. No words.
        g.line("^10,110 ^-2,136", 1.3)
        g.line("^86,110 ^98,136", 1.3)
        g.shape(0, .rrect(0, 0, 96, 112, 3), 1.6)
        g.accent(.rrect(6, 6, 84, 100, 1))
        g.gel("^22,18 34,14 48,18 62,14 ^74,18", 1.1)
        g.gel("^14,38 22,36 30,38 ^40,36", 0.8)
        g.gel("^62,36 ^80,36", 0.8)
        g.gel("^14,50 26,48 ^38,50", 0.8)
        g.gel("^62,48 ^80,48", 0.8)
        g.gel("^14,62 24,60 34,62 ^42,60", 0.8)
        g.gel("^62,60 ^80,60", 0.8)
        // The little cup in chalk.
        g.gel("^36,76 ^60,76 56,96 ^40,96 ^36,76", 1)
        g.gel("^60,80 68,80 66,88 ^58,90", 0.8)
        g.gel("44,72 46,68 ^44,64", 0.65)
        g.gel("52,72 54,68 ^52,64", 0.65)
        g.gel("^24,86 ^20,82 ^24,92 ^28,82 ^24,86", 0.7)
        return g
    }

    static func radio() -> DoodleGlyph {
        var g = DoodleGlyph("radio", 0.13, 0.25, tilt: 7)
        g.noFlip = true
        // A rounded mantel set: speaker cloth, dial, knobs, a thin aerial.
        g.line("^96,18 ^124,-18", 0.75)
        g.blot(.circle(125, -19, 1.6))
        g.shape(0, "^2,86 2,34 16,14 ^50,8 ^84,14 ^108,34 ^108,86 z", 1.55)
        g.shape(1, "^10,48 18,26 ^54,20 ^54,78 ^10,78 z", 1.15)
        g.detail(0.14) { g in
            for x in stride(from: 18.0, through: 50.0, by: 6) { g.line(.poly([(x, 28), (x, 76)]), 0.42) }
            for y in stride(from: 34.0, through: 72.0, by: 6) { g.line(.poly([(14, y), (52, y)]), 0.42) }
        }
        g.shape(-1, .rrect(62, 24, 38, 18, 2), 1)
        for x in stride(from: 68.0, through: 94.0, by: 6.4) { g.line(.poly([(x, 28), (x, 36)]), 0.42) }
        g.line("^80,24 ^78,42", 0.8)
        g.shape(2, .circle(70, 62, 7.6), 1.05)
        g.shape(2, .circle(92, 62, 7.6), 1.05)
        g.blot(.circle(70, 58, 1.1))
        g.blot(.circle(95, 59, 1.1))
        g.blot(.rrect(10, 86, 14, 5, 1.5))
        g.blot(.rrect(86, 86, 14, 5, 1.5))
        return g
    }

    static func bistroChair() -> DoodleGlyph {
        var g = DoodleGlyph("bistroChair", 0.15, 0.25, tilt: 6)
        // A bentwood chair, a cane seat, curved back hoop and four splayed legs.
        g.band(0, outer: "^14,70 8,34 16,10 ^40,0 64,10 72,34 ^66,70 ^60,70 66,34 60,14 ^40,6 20,14 14,34 ^20,70 z", inner: "^14,70 ^14,70 ^14,70 z", 1.25, innerW: 0)
        g.line("^24,70 20,36 28,20 ^40,16 52,20 60,36 ^56,70", 0.8)
        g.shape(0, DoodlePath.taper([(18, 78), (6, 138)], 5.4, 4), 1.1)
        g.shape(0, DoodlePath.taper([(62, 78), (74, 138)], 5.4, 4), 1.1)
        g.shape(0, DoodlePath.taper([(26, 80), (24, 130)], 4.4, 3.4), 1)
        g.shape(0, DoodlePath.taper([(54, 80), (56, 130)], 4.4, 3.4), 1)
        g.line(.ellipse(40, 106, 26, 6), 0.9)
        g.shape(1, .ellipse(40, 74, 32, 9.4), 1.45)
        g.detail(0.16) { g in
            g.line(.ellipse(40, 74, 24, 6), 0.42)
            g.line(.ellipse(40, 74, 15, 3.6), 0.42)
        }
        return g
    }

    // The marks in the gaps.

    static func coffeeBean() -> DoodleGlyph {
        var g = DoodleGlyph("coffeeBean", 0.02, 0.06, tilt: 80)
        g.shape(0, .ellipse(0, 0, 18, 13), 0.85)
        g.line("^-16,4 -6,-2 4,2 ^16,-4", 0.65)
        return g
    }

    static func crumbs() -> DoodleGlyph {
        var g = DoodleGlyph("crumbs", 0.02, 0.05, tilt: 20)
        g.blot(.circle(0, 8, 3))
        g.blot(.circle(12, 0, 2.4))
        g.blot(.circle(18, 12, 3.6))
        g.blot(.circle(30, 4, 2))
        g.blot(.circle(8, 18, 1.8))
        return g
    }

    static func sugarCube() -> DoodleGlyph {
        var g = DoodleGlyph("sugarCube", 0.018, 0.04, tilt: 24)
        g.shape(-1, "^0,6 ^12,0 ^24,6 ^24,20 ^12,26 ^0,20 z", 0.8)
        g.line("^0,6 ^12,12 ^24,6", 0.5)
        g.line("^12,12 ^12,26", 0.5)
        return g
    }

    static func tinyLeaf() -> DoodleGlyph {
        var g = DoodleGlyph("tinyLeaf", 0.02, 0.055, tilt: 80)
        g.shape(1, K.leaf((0, 0), (28, 6), belly: 13), 0.75)
        g.line("^0,0 ^22,5", 0.42)
        return g
    }

    static func steamCurl() -> DoodleGlyph {
        var g = DoodleGlyph("steamCurl", 0.03, 0.07, tilt: 10)
        g.line("8,30 16,22 8,14 16,6 ^8,-2", 0.8)
        g.line("24,30 32,22 24,14 ^32,6", 0.7)
        return g
    }

    static func tinyNote() -> DoodleGlyph {
        var g = DoodleGlyph("tinyNote", 0.025, 0.06, tilt: 16)
        g.line("^8,24 ^8,4 ^24,0 ^24,20", 0.8)
        g.blot(.ellipse(4, 25, 5, 4))
        g.blot(.ellipse(20, 21, 5, 4))
        return g
    }

    static func tinyStar() -> DoodleGlyph {
        var g = DoodleGlyph("tinyStar", 0.02, 0.045, tilt: 40)
        g.shape(0, DoodleFillers.starPath(0, 0, 20), 0.75)
        return g
    }

    static func tinyHeart() -> DoodleGlyph {
        var g = DoodleGlyph("tinyHeart", 0.018, 0.04, tilt: 30)
        g.shape(2, DoodleFillers.heartPath(0, 0, 18), 0.75)
        return g
    }
}
