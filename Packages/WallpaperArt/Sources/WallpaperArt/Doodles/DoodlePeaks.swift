// The Peaks drawings: mountaineering. Spot colours mean something: 0 is glacier ice, 1 is slate and steel, 2 is the warm
// orange of rescue gear and alpenglow. No moon anywhere in this set.

import CoreGraphics
import Foundation

nonisolated enum DoodlePeaks {
    static func all() -> [DoodleGlyph] {
        var list = [peaks(), cableCar(), boot(), skis(), ibex(), goggles(), domeTent(), iceAxe(), alpinePack(), summitFlag(), hut(), map(), compass(), rope(),
                    helmet(), crampons(), quickdraw(), carabiner(), pitonHammer(), iceScrew(), figureEight(), headlamp(), mittens(), beanie(), marmot(), eagle(), edelweiss(), gentian(),
                    snowflake(), cairn(), chairlift(), skiBoot(), flask(), glacierGlasses(), altimeter(), blazeRock(), snowshoe(), sled(), poles(), shovel(), stove(), pennants(), snowPine(), cocoa(), liftTicket(), chough(), ropeKnot(), iceBlock(),
                    tinyFlake(), tinyPeak(), tinyBird(), bootPrints(), windCurl(), snowDrift(), tinyStone(), tinySki()]
        list += DoodleFillers.common().filter { ["dot"].contains($0.name) }
        list += extras() + littles()
        list += [DoodleForest.tinyPine()]
        for i in list.indices {
            list[i].fixed = true
            list[i].done()
        }
        return list
    }

    static func cableCar() -> DoodleGlyph {
        var g = DoodleGlyph("cableCar", 0.24, 0.44, tilt: 5)
        g.must = true
        // Two cables climbing to the right.
        g.line("^-16,36 ^146,7", 1.25)
        g.line("^-16,43 ^146,14", 0.8)
        // The truck rides the upper cable on two wheels; the hanger drops from it.
        g.shape(1, "^61,28 ^70,26 ^72,52 ^60,52 z", 1.05)
        g.shape(1, "^42,27 ^88,18.5 ^90,27 ^44,35.5 z", 1.1)
        g.shape(-1, .circle(51, 20.5, 5.2), 0.95)
        g.shape(-1, .circle(79, 15.5, 5.2), 0.95)
        g.blot(.circle(51, 20.5, 1.5))
        g.blot(.circle(79, 15.5, 1.5))
        // Skis in the rack on the outside.
        g.shape(0, "^107,60 ^112,58 ^116,112 ^110,114 z", 0.85)
        g.shape(0, "^114,60 ^119,58 ^122,110 ^116,112 z", 0.85)
        // Roof and cabin.
        g.shape(1, "^40,44 ^92,44 ^100,54 ^32,54 z", 1.15)
        g.shape(-1, "^36,54 ^96,54 102,62 105,86 101,106 ^92,116 ^40,116 31,106 27,86 30,62 z", 1.4)
        g.tint(2, "^28.5,92 ^103.5,92 101,106 ^92,116 ^40,116 31,106 z")
        g.line("^28.5,92 ^103.5,92", 0.8)
        g.line("^29,97 ^103,97", 0.5)
        // Three windows with two riders, the middle one the door.
        g.shape(0, .rrect(34, 60, 19, 26, 3.5), 0.95)
        g.shape(0, .rrect(57, 60, 18, 28, 3), 0.95)
        g.shape(0, .rrect(79, 60, 19, 26, 3.5), 0.95)
        g.accent(.circle(44, 72, 4))
        g.accent("^37,86 38,79 44,77.5 50,79 ^51,86 z")
        g.accent(.circle(88, 73, 3.6))
        g.accent("^81,86 82,80 88,78.5 94,80 ^95,86 z")
        g.line("^57,99 ^57,116", 0.7)
        g.line("^75,99 ^75,116", 0.7)
        g.detail(0.2) { g in
            g.gel("^60,84 ^68,64", 1)
            g.gel("^63,86 ^71,68", 0.6)
            g.hatch("^92,98 ^103,98 ^100,106 ^92,115 z", angle: 62, gap: 2.6, w: 0.45)
            g.blot(.circle(72, 106, 1.1))
            g.line("^40,44 ^38,54", 0.45)
            g.line("^92,44 ^94,54", 0.45)
        }
        g.shape(1, .rrect(38, 116, 56, 5.5, 2.5), 1)
        return g
    }

    static func skis() -> DoodleGlyph {
        var g = DoodleGlyph("skis", 0.24, 0.42, tilt: 8)
        g.must = true
        func pole(_ g: inout DoodleGlyph, _ top: (Double, Double), _ tip: (Double, Double)) {
            g.shape(1, DoodlePath.taper([top, tip], 3.2, 1.8), 0.8)
            let t = 0.84, bx = top.0 + (tip.0 - top.0) * t, by = top.1 + (tip.1 - top.1) * t
            g.shape(2, .ellipse(bx, by, 7.5, 3.2), 0.85)
            let dx = tip.0 - top.0, dy = tip.1 - top.1, l = hypot(dx, dy)
            let ux = dx / l, uy = dy / l
            g.shape(2, DoodlePath.taper([(top.0 - ux * 5, top.1 - uy * 5), (top.0 + ux * 12, top.1 + uy * 12)], 6, 5), 0.95)
            g.detail(0.2) { $0.line(.spline([(top.0 - ux * 4, top.1 - uy * 4), (top.0 - 8, top.1 + 5), (top.0 - 3, top.1 + 12)]), 0.55) }
        }
        pole(&g, (22, 8), (82, 138))
        pole(&g, (82, 6), (20, 140))
        func ski(_ g: inout DoodleGlyph, x: Double, rot: Double, sep: Int, band: Int) {
            func T(_ p: DoodlePath) -> DoodlePath { p.rotated(rot, about: (0, 72)).moved(x, 0) }
            g.shape(sep, T("0,0 6,6 8.5,30 6.5,72 8,122 6,139 0,143 -6,139 -8,122 -6.5,72 -8.5,30 -6,6 z"), 1.3)
            g.tint(band, T("^-7.6,16 ^7.6,16 ^8.4,32 ^-8.4,32 z"))
            g.line(T("^-7.6,16 ^7.6,16"), 0.65)
            g.line(T("^-8.4,32 ^8.4,32"), 0.65)
            g.line(T("^-7.8,112 ^7.8,112"), 0.55)
            g.tint(band, T("^-7.8,112 ^7.8,112 ^8,122 ^-8,122 z"))
            g.line(T("^-8,122 ^8,122"), 0.55)
            g.detail(0.2) { g in
                g.gel(T("-3.4,36 -3,60"), 0.8)
                g.line(T("^0,36 ^0,58"), 0.4)
                g.line(T("^0,102 ^0,110"), 0.4)
            }
            // The binding: toe piece, plate, heel piece.
            g.line(T("^-3.4,72 ^-3.4,92"), 0.7)
            g.line(T("^3.4,72 ^3.4,92"), 0.7)
            g.shape(1, T(.rrect(-9.5, 64, 19, 9, 2.4)), 1)
            g.shape(1, T(.rrect(-8.5, 90, 17, 11, 2.4)), 1)
        }
        ski(&g, x: 52, rot: 17, sep: 0, band: 2)
        ski(&g, x: 52, rot: -13, sep: 2, band: 0)
        return g
    }

    static func iceAxe() -> DoodleGlyph {
        var g = DoodleGlyph("iceAxe", 0.13, 0.36, tilt: 34)
        // The wrist loop behind the shaft.
        g.line("54,62 72,76 72,98 58,108", 1)
        g.line("54,68 66,78 66,94 58,102", 0.6)
        // Shaft, slightly tapered, with a wrapped grip and a steel spike.
        g.shape(2, "^45,20 ^56,20 ^57,126 ^44,126 z", 1.2)
        g.shape(1, "^44,126 ^57,126 ^56,138 ^50.5,152 ^45,138 z", 1.1)
        g.detail(0.14) { g in
            g.line("^44.6,132 ^56.4,132", 0.5)
            g.gel("^48.5,30 ^48.5,60", 0.8)
        }
        for y in stride(from: 92.0, through: 122.0, by: 5.0) { g.line("^44,\(y) ^57,\(y + 2.6)", 0.6) }
        // The head: a curved pick with teeth, a flat adze.
        g.shape(1, "^46,5 30,5 14,10 ^-6,26 ^-3,28 14,20 32,18 ^46,18 z", 1.3)
        g.shape(1, "^55,5 ^74,4 ^92,0 ^90,20 ^74,18 ^55,20 z", 1.3)
        g.shape(1, .rrect(43, 2, 15, 22, 2.5), 1.15)
        g.blot(.circle(50.5, 13, 2))
        g.detail(0.14) { g in
            for i in 0..<5 {
                let x = 6.0 + Double(i) * 6.4
                let y = 23.6 - Double(i) * 1.1
                g.line(.poly([(x, y), (x - 1.2, y + 3.8)]), 0.65)
            }
            g.gel("^16,13 28,9.5 ^38,8.5", 0.8)
            g.line("^64,6 ^64,18", 0.45)
        }
        return g
    }

    static func goggles() -> DoodleGlyph {
        var g = DoodleGlyph("goggles", 0.14, 0.34, tilt: 18)
        g.shape(1, "^12,16 ^-14,12 -18,26 ^-15,40 ^12,38 z", 1.05)
        g.shape(1, "^108,16 ^134,12 138,26 ^135,40 ^108,38 z", 1.05)
        g.line("^-14.5,22 ^12,24", 0.55)
        g.line("^-15.6,31 ^12,31", 0.55)
        g.line("^134.5,22 ^108,24", 0.55)
        g.line("^135.6,31 ^108,31", 0.55)
        // Frame, then the single mirrored lens.
        g.shape(2, "8,27 12,10 30,3 60,5 90,3 108,10 112,27 108,43 94,52 76,52 66,44 60,40 54,44 44,52 26,52 12,43 z", 1.4)
        let lens: DoodlePath = "15,27 18,14 32,9.5 60,11 88,9.5 102,14 105,27 102,39 92,45.5 77,45.5 68,38 60,33.5 52,38 43,45.5 28,45.5 18,39 z"
        g.shape(0, lens, 1.05)
        // A ridge reflected in it, shadow below.
        g.shade("^17,36 ^36,22 ^46,30 ^66,14 ^80,26 ^88,22 ^104,34 102,39 92,45.5 77,45.5 68,38 60,33.5 52,38 43,45.5 28,45.5 18,39 z")
        g.line("^17,36 ^36,22 ^46,30 ^66,14 ^80,26 ^88,22 ^104,34", 0.7)
        g.detail(0.16) { g in
            g.gel("24,18 33,14 47,14", 1.1)
            g.gel("^34,27 ^30,31", 0.8)
            g.gel("^66,19 ^62,26", 0.8)
            for x in [18.0, 42.0, 78.0, 102.0] { g.blot(.circle(x, x < 60 ? 6.6 : 6.6, 0.9)) }
            g.line("^52,47 ^46,53", 0.45)
            g.line("^68,47 ^74,53", 0.45)
        }
        return g
    }

    static func ibex() -> DoodleGlyph {
        var g = DoodleGlyph("ibex", 0.3, 0.44, tilt: 5)
        g.must = true
        g.whole = true
        g.noTuck = true
        // The hollow under the horn stays empty, so the head keeps its silhouette.
        g.keepClear("^34,-8 ^60,-22 ^84,-12 ^100,8 ^92,24 ^70,38 ^44,42 ^24,42 z")
        // The ledge it stands on.
        g.shape(1, "^-6,122 8,116 ^34,118 ^60,114 ^90,116 ^112,120 ^124,132 ^112,142 ^76,146 ^30,144 ^-2,138 z", 1.3)
        g.detail(0.2) { g in
            g.line("^20,126 ^36,136 ^32,144", 0.55)
            g.line("^70,124 ^60,134 ^72,145", 0.55)
            g.line("^100,126 ^94,138", 0.5)
            g.hatch("^86,126 ^116,128 ^108,140 ^80,144 z", angle: 66, gap: 3, w: 0.45)
        }
        // The far legs step the other way, in shadow.
        let farHind: DoodlePath = "^36,72 ^50,74 50,84 46,92 43,100 42,108 ^46,118 ^35,118 34,108 34,98 37,90 36,82 z"
        let farFore: DoodlePath = "^74,74 ^86,72 87,84 90,94 94,104 ^101,116 ^91,118 86,106 79,96 75,86 z"
        g.shape(1, farHind, 1)
        g.shade(farHind)
        g.shape(1, farFore, 1)
        g.shade(farFore)
        g.accent("^35,114 ^44.4,114 ^46,118 ^35,118 z")
        g.accent("^88.6,112 ^98.8,112 ^101,116 ^91,118 z")
        // Far horn.
        let farHorn = DoodlePath.taper([(99, 15), (96, 2), (86, -9), (74, -12), (64, -8)], 5, 1.6)
        g.shape(1, farHorn, 0.9)
        g.shade(farHorn)
        // A short flicked tail.
        g.shape(-1, "^15,52 8,44 5,50 ^11,60 z", 0.95)
        // The body in one line: rump, back, neck, jaw, chest, a bent near foreleg, belly, a hock that looks like a hock.
        g.shape(-1, "13,60 17,47 28,41 44,39 60,39 70,36 78,26 84,16 92,11 100,12 106,17 110,24 ^116,30 116,35 ^108,38 101,39 98,45 97,55 96,67 91,76 86,84 83,92 80,102 ^79,118 ^68,118 69,104 71,92 72,84 ^68,76 52,78 40,77 33,73 28,82 20,92 22,100 25,108 ^29,118 ^17,118 13,106 10,94 14,84 11,72 z", 1.35)
        // Coat: dark saddle and legs, pale belly.
        g.tint(1, "13,60 17,47 28,41 44,39 60,39 70,36 78,26 84,16 92,11 90,30 84,44 74,56 56,62 34,62 z")
        g.line("^14,58 34,62 56,62 74,56 ^84,44", 0.5)
        g.shade("^40,77 52,78 ^68,76 ^72,70 54,71 ^38,70 z")
        g.detail(0.2) { g in
            DoodleForest.fur(&g, rows: [[(70, 44), (66, 50), (60, 54)], [(78, 38), (74, 46), (68, 54)], [(86, 28), (82, 38), (78, 46)]], lean: (-0.6, 0.8), len: 5, seed: 5)
            DoodleForest.fur(&g, rows: [[(26, 48), (22, 56)], [(36, 46), (33, 54)], [(46, 46), (44, 54)]], lean: (-0.4, 0.9), len: 5, seed: 6)
            g.line("^71,84 ^78,88", 0.45)
            g.line("^16,88 ^23,90", 0.45)
            g.gel("^62,66 ^46,66", 0.7)
        }
        g.accent("^68,114 ^78.6,114 ^79,118 ^68,118 z")
        g.accent("^16,114 ^27.4,114 ^29,118 ^17,118 z")
        // A chin beard.
        g.shape(1, "^106,38 ^99,38 98,46 ^100,54 ^104,46 z", 0.9)
        // Ear, then the near horn sweeping back, ridged.
        g.shape(1, "^90,16 83,10 76,11 80,18 ^87,21 z", 1)
        g.shape(-1, DoodlePath.taper([(95, 14), (90, -2), (78, -14), (60, -18), (44, -12), (38, -2)], 8, 2), 1.15)
        g.detail(0.16) { g in
            for (x, y, dx, dy) in [(90.0, 4.0, 5.5, 2.4), (85.5, -3.6, 4.6, 3.4), (79, -9.6, 3.2, 4.6), (71, -13.8, 1.8, 4.8), (62, -15.6, 0.4, 4.8), (53, -15.2, -1, 4.2), (46, -11.6, -2, 3.2)] {
                g.line(.poly([(x - dx / 2, y - dy / 2), (x + dx / 2, y + dy / 2)]), 0.55)
            }
        }
        // Eye, nostril, mouth.
        g.accent(.ellipse(101, 21, 1.8, 2))
        g.line("^97,18 ^103,18", 0.5)
        g.blot("^113,28 ^116.4,30 ^115,33 z")
        g.line("^115,35 ^106,35.6", 0.55)
        return g
    }

    static func marmot() -> DoodleGlyph {
        var g = DoodleGlyph("marmot", 0.1, 0.25, tilt: 8)
        g.whole = true
        // The stone and tail behind.
        g.shape(1, "^-2,102 6,92 ^22,90 ^60,92 ^76,96 ^82,106 ^72,112 ^10,112 z", 1.15)
        g.detail(0.14) { $0.line("^12,102 ^24,108", 0.45); $0.line("^60,100 ^52,108", 0.45) }
        g.shape(2, "^52,84 64,84 74,92 72,98 ^52,96 z", 1)
        g.shape(1, .circle(29, 10, 4.6), 0.95)
        g.shape(1, .circle(53, 10, 4.6), 0.95)
        // A pear of a body standing straight up.
        g.shape(2, "32,32 28,46 21,66 21,84 30,96 46,98 58,92 63,76 58,52 52,32 z", 1.3)
        g.tint(-1, "41,48 50,56 54,72 50,88 41,94 32,88 28,72 32,56 z")
        // Head.
        g.shape(2, "25,24 27,11 41,5 55,11 57,24 53,34 41,38 29,34 z", 1.3)
        g.tint(-1, "41,22 50,26 49,33 41,36 33,33 32,26 z")
        g.accent(.ellipse(33, 20, 2, 2.2))
        g.accent(.ellipse(49, 20, 2, 2.2))
        g.accent("^38,24 ^44,24 41,27.5 z")
        g.line("^41,27 ^41,30", 0.55)
        g.line("^36,30 41,32 ^46,30", 0.55)
        g.shape(-1, .rrect(38.6, 32, 4.8, 4.2, 1), 0.5)
        g.detail(0.14) { g in
            g.line("^28,25 ^20,23", 0.4)
            g.line("^28,28 ^20,29", 0.4)
            g.line("^54,25 ^62,23", 0.4)
            g.line("^54,28 ^62,29", 0.4)
            DoodleForest.fur(&g, rows: [[(25, 62), (24, 72), (26, 82)], [(60, 60), (61, 70), (59, 80)]], lean: (0, 1), len: 5, seed: 3)
        }
        // Paws on the chest, big feet.
        g.shape(2, "25,44 18,50 20,60 29,60 35,54 ^33,46 z", 1.05)
        g.shape(2, "57,44 64,50 62,60 53,60 47,54 ^49,46 z", 1.05)
        g.shape(2, .ellipse(29, 97, 11, 4.6), 1)
        g.shape(2, .ellipse(53, 97, 11, 4.6), 1)
        return g
    }

    static func eagle() -> DoodleGlyph {
        var g = DoodleGlyph("eagle", 0.1, 0.3, tilt: 16)
        g.mirror(70) { g in
            // A soaring wing with fingered primaries.
            g.shape(1, "^68,30 54,20 36,12 16,10 ^-4,18 ^6,22 ^-2,30 ^10,30 ^4,38 ^16,36 ^12,44 ^24,40 ^30,46 ^42,42 ^56,48 ^66,48 z", 1.25)
            g.detail(0.14) { g in
                g.line("^14,14 ^6,23", 0.45)
                g.line("^24,16 ^14,30", 0.45)
                g.line("^34,18 ^24,36", 0.45)
                g.line("^44,22 ^36,40", 0.45)
                g.line("^54,26 ^50,42", 0.45)
            }
            g.tint(-1, "^68,30 54,20 36,12 16,10 ^10,14 34,20 ^62,38 z")
        }
        // Tail fan, then body, then the pale head.
        g.shape(1, "^60,54 ^54,72 ^62,70 ^66,76 ^70,70 ^74,76 ^78,70 ^86,72 ^80,54 z", 1.15)
        g.shape(1, .ellipse(70, 40, 11, 21), 1.2)
        g.shape(-1, "60,26 62,16 70,12 78,16 80,26 76,34 70,36 64,34 z", 1.1)
        g.shape(2, "^66,20 ^74,20 ^70,28 z", 0.8)
        g.accent(.circle(65.5, 19.5, 1.2))
        g.accent(.circle(74.5, 19.5, 1.2))
        g.detail(0.16) { $0.hatch("^62,40 ^78,40 ^76,56 ^64,56 z", angle: 90, gap: 3, w: 0.42) }
        return g
    }

    static func edelweiss() -> DoodleGlyph {
        var g = DoodleGlyph("edelweiss", 0.07, 0.2, tilt: 24)
        // Stem and two narrow leaves.
        g.line("44,48 46,70 42,96 ^44,112", 1.1)
        g.shape(0, DoodleKit.leaf((45, 76), (18, 92), belly: 9), 0.9)
        g.shape(0, DoodleKit.leaf((44, 88), (72, 104), belly: 9), 0.9)
        // Woolly bracts, nine of them, a little uneven.
        let lens = [34.0, 30, 35, 31, 36, 30, 34, 31, 33]
        for i in 0..<9 {
            let a = -90 + Double(i) * 40
            let tip = DoodleKit.polar(44, 40, lens[i], a), base = DoodleKit.polar(44, 40, 7, a)
            g.shape(-1, DoodleKit.leaf(base, tip, belly: 15, bias: 0.55), 1)
            g.detail(0.13) { g in
                let m = DoodleKit.polar(44, 40, lens[i] * 0.72, a)
                g.line(.poly([DoodleKit.polar(44, 40, 11, a), m]), 0.42)
            }
        }
        // The cluster of small heads.
        g.shape(2, .circle(44, 40, 9), 0.95)
        for (dx, dy) in [(-4.0, -4.0), (4.0, -3.0), (0.0, 1.0), (-5.0, 3.5), (5.0, 4.0)] {
            g.line(.circle(44 + dx, 40 + dy, 2.6), 0.6)
        }
        return g
    }

    static func gentian() -> DoodleGlyph {
        var g = DoodleGlyph("gentian", 0.07, 0.2, tilt: 20)
        for (x, y, k) in [(22.0, 16.0, 0.72), (56.0, 2.0, 1.0)] {
            func T(_ p: DoodlePath) -> DoodlePath { p.scaled(k, about: (0, 0)).moved(x, y) }
            g.shape(1, T("^-4,78 ^4,78 ^5,100 ^-5,100 z"), 0.8)
            g.shape(0, T("^-7,80 -9,66 -18,46 ^-28,24 ^-15,30 ^-11,12 ^0,26 ^11,12 ^15,30 ^28,24 18,46 9,66 ^7,80 z"), 1.25)
            g.shade(T("^-12,32 ^0,26 ^12,32 ^6,44 ^0,50 ^-6,44 z"))
            g.line(T("^-11,31 -6,42 ^0,50"), 0.5)
            g.line(T("^11,31 6,42 ^0,50"), 0.5)
            g.line(T("^-3,76 -5,62 ^-7,48"), 0.5)
            g.line(T("^3,76 5,62 ^7,48"), 0.5)
            g.line(T("^0,76 ^0,54"), 0.5)
            g.shade(T("^7,80 9,66 18,46 ^24,28 ^20,30 ^10,50 ^3,80 z"))
        }
        g.shape(1, DoodleKit.leaf((36, 104), (0, 86), belly: 11), 1)
        g.shape(1, DoodleKit.leaf((46, 104), (84, 92), belly: 11), 1)
        g.line("^10,106 ^76,106", 0.7)
        return g
    }

    static func snowflake() -> DoodleGlyph {
        var g = DoodleGlyph("snowflake", 0.06, 0.16, tilt: 30)
        for i in 0..<6 {
            let a = Double(i) * 60 - 90
            g.line(.poly([DoodleKit.polar(50, 50, 12, a), DoodleKit.polar(50, 50, 48, a)]), 1.1)
            for (r, l) in [(24.0, 11.0), (36.0, 8.0)] {
                let p = DoodleKit.polar(50, 50, r, a)
                g.line(.poly([p, DoodleKit.polar(p.0, p.1, l, a - 52)]), 0.85)
                g.line(.poly([p, DoodleKit.polar(p.0, p.1, l, a + 52)]), 0.85)
            }
            g.blot(.circle(DoodleKit.polar(50, 50, 48, a).0, DoodleKit.polar(50, 50, 48, a).1, 1.8))
        }
        g.shape(0, DoodleKit.gon(50, 50, 12, sides: 6), 1)
        g.blot(.circle(50, 50, 2))
        return g
    }

    static func cairn() -> DoodleGlyph {
        var g = DoodleGlyph("cairn", 0.09, 0.26, tilt: 6)
        g.shape(1, "^-4,104 8,92 26,88 50,90 70,88 88,94 ^100,104 z", 1.25)
        g.shape(0, "12,88 10,76 22,68 48,66 70,70 78,80 72,90 40,93 z", 1.2)
        g.shape(1, "22,68 20,58 34,50 54,50 66,56 64,68 44,72 z", 1.2)
        g.shape(-1, "28,50 28,42 38,36 52,38 58,44 54,52 40,54 z", 1.1)
        g.shape(1, "36,36 36,28 44,24 52,26 54,32 48,38 40,38 z", 1)
        g.shape(2, "42,24 41,18 46,14 51,17 51,23 46,26 z", 0.95)
        g.detail(0.13) { g in
            g.hatch("^56,72 ^76,74 ^72,88 ^52,90 z", angle: 64, gap: 2.8, w: 0.45)
            g.hatch("^52,54 ^64,58 ^62,66 ^48,68 z", angle: 64, gap: 2.6, w: 0.42)
            g.line("^22,76 ^30,84", 0.45)
            g.line("^30,58 ^36,64", 0.45)
            g.line("^10,100 ^22,98", 0.45)
            g.line("^60,98 ^80,100", 0.45)
        }
        g.line("^-8,106 ^20,105", 0.7)
        g.line("^66,105 ^104,106", 0.7)
        return g
    }

    static func chairlift() -> DoodleGlyph {
        var g = DoodleGlyph("chairlift", 0.13, 0.32, tilt: 5)
        g.line("^-14,16 ^124,0", 1.25)
        // The hanger bends over the back of the chair.
        g.line("^56,8 ^56,34 44,44 ^40,56", 1.4)
        g.line("^56,34 68,44 ^72,56", 1.1)
        g.shape(1, .rrect(47, 3, 18, 10, 3), 1.05)
        g.blot(.circle(52, 8, 1.3))
        g.blot(.circle(60, 7, 1.3))
        // Backrest, slats, seat.
        g.shape(2, "^20,48 ^92,48 ^90,78 ^22,78 z", 1.25)
        g.line("^21,58 ^91,58", 0.6)
        g.line("^21.6,68 ^90.4,68", 0.6)
        g.shape(0, "^16,78 ^96,78 ^104,92 ^8,92 z", 1.25)
        g.line("^56,78 ^56,92", 0.6)
        // Arms and the footrest bar.
        g.line("^20,62 8,64 ^6,84", 1)
        g.line("^92,62 104,64 ^106,84", 1)
        g.line("^24,92 ^24,114 ^88,114 ^88,92", 1)
        g.shape(1, .rrect(32, 112, 16, 5, 2), 0.8)
        g.shape(1, .rrect(64, 112, 16, 5, 2), 0.8)
        g.detail(0.18) { g in
            g.shade("^84,48 ^92,48 ^90,78 ^84,78 z")
            g.gel("^28,52 ^46,52", 0.8)
        }
        return g
    }

    static func skiBoot() -> DoodleGlyph {
        var g = DoodleGlyph("skiBoot", 0.12, 0.3, tilt: 14)
        // Liner sticking out at the top, the whole boot leaning into the turn.
        g.shape(-1, "^32,12 ^70,10 74,18 ^70,26 ^30,28 z", 1.05)
        g.detail(0.16) { g in
            g.line("^40,13 ^40,26", 0.42)
            g.line("^50,12 ^50,25", 0.42)
            g.line("^60,12 ^60,24", 0.42)
        }
        // The hard lower shell, then the cuff over it.
        g.shape(0, "^10,58 ^60,52 78,58 98,68 110,80 ^110,90 ^8,90 z", 1.35)
        g.shape(2, "^28,24 ^72,20 76,38 ^82,56 64,64 ^28,66 ^10,62 20,44 z", 1.35)
        g.line("^50,23 52,42 ^52,64", 0.6)
        // A power strap and three buckles.
        for (x0, y0, x1, y1) in [(23.0, 34.0, 77.0, 30.0), (16.0, 50.0, 81.0, 44.0), (40.0, 68.0, 88.0, 62.0), (68.0, 78.0, 104.0, 74.0)] {
            g.shape(1, .poly([(x0, y0), (x1, y1), (x1, y1 + 5.4), (x0, y0 + 5.4)], closed: true), 0.85)
            let mx = x1 - 12, my = y1 + (y0 - y1) * 12 / (x1 - x0)
            g.shape(-1, .rrect(mx - 4, my - 1.4, 8, 8, 1.2), 0.75)
            g.line(.poly([(mx - 2, my + 2.6), (mx + 2, my + 2.6)]), 0.5)
        }
        g.detail(0.16) { g in
            g.hatch("^12,70 ^38,70 ^38,88 ^10,88 z", angle: 62, gap: 3, w: 0.45)
            g.gel("^34,28 ^27,46", 0.9)
        }
        // A flat sole with a lip each end.
        g.accent("^4,90 ^114,90 ^118,94 ^116,102 ^80,102 ^76,98 ^38,98 ^34,102 ^4,102 ^2,94 z")
        return g
    }

    static func flask() -> DoodleGlyph {
        var g = DoodleGlyph("flask", 0.09, 0.22, tilt: 22)
        g.line(.circle(25, 3, 6), 1)
        g.shape(1, .rrect(13, 8, 24, 13, 2), 1.15)
        g.detail(0.13) { g in
            for x in stride(from: 17.0, through: 33.0, by: 4.0) { g.line("^\(x),10 ^\(x),19", 0.42) }
        }
        g.shape(-1, .rrect(17, 21, 16, 7, 1), 0.9)
        g.shape(2, "^17,28 ^33,28 42,38 44,52 ^44,108 40,114 ^10,114 6,108 ^6,52 8,38 z", 1.35)
        g.shape(-1, .rrect(11, 56, 28, 30, 2), 0.9)
        g.blot("^15,82 ^23,68 ^27,74 ^30,70 ^36,82 z")
        g.detail(0.13) { g in
            g.hatch("^34,44 ^43,50 ^43,110 ^34,110 z", angle: 66, gap: 2.8, w: 0.45)
            g.gel("^12,44 ^11,52", 1)
            g.gel("^11,92 ^11,106", 1)
        }
        return g
    }

    static func glacierGlasses() -> DoodleGlyph {
        var g = DoodleGlyph("glacierGlasses", 0.09, 0.22, tilt: 22)
        // Temple arms hooked behind.
        g.line("^4,18 -14,14 -24,18 ^-28,30", 1)
        g.line("^116,18 134,14 144,18 ^148,30", 1)
        // Leather side shields.
        g.shape(2, "^22,8 8,6 0,20 4,38 ^22,44 z", 1.1)
        g.shape(2, "^98,8 112,6 120,20 116,38 ^98,44 z", 1.1)
        g.detail(0.14) { g in
            g.stitch("^20,12 10,11 5,20 8,35 ^20,40", dash: 2, gap: 1.8, w: 0.42)
            g.stitch("^100,12 110,11 115,20 112,35 ^100,40", dash: 2, gap: 1.8, w: 0.42)
        }
        // Round dark lenses, a bridge.
        g.line("^50,20 55,14 65,14 ^70,20", 1.2)
        g.shape(1, .circle(34, 26, 20), 1.35)
        g.shape(1, .circle(86, 26, 20), 1.35)
        g.shade(.circle(34, 26, 16))
        g.shade(.circle(86, 26, 16))
        g.line(.circle(34, 26, 16.4), 0.5)
        g.line(.circle(86, 26, 16.4), 0.5)
        g.gel("24,20 28,15 ^35,13.5", 1.1)
        g.gel("76,20 80,15 ^87,13.5", 1.1)
        return g
    }

    static func altimeter() -> DoodleGlyph {
        var g = DoodleGlyph("altimeter", 0.09, 0.24, tilt: 28)
        g.noFlip = true
        g.shape(1, "^28,28 ^52,28 ^50,0 ^30,0 z", 1.1)
        g.shape(1, "^28,92 ^52,92 ^50,122 ^30,122 z", 1.1)
        g.detail(0.14) { g in
            for y in [100.0, 107.0, 114.0] { g.blot(.circle(40, y, 1.1)) }
            g.line("^33,4 ^47,4", 0.42)
            g.line("^33,10 ^47,10", 0.42)
        }
        g.shape(2, .rrect(69, 54, 7, 11, 2), 0.9)
        g.shape(0, .circle(40, 60, 34), 1.4)
        g.shape(-1, .circle(40, 60, 27), 1)
        g.detail(0.13) { g in
            for i in 0..<24 {
                let a = Double(i) * 15
                let long = i % 6 == 0
                g.line(.poly([DoodleKit.polar(40, 60, long ? 21 : 23.6, a), DoodleKit.polar(40, 60, 26, a)]), long ? 0.72 : 0.42)
            }
            g.line("^30,72 ^36,64 ^40,68 ^44,63 ^50,72", 0.6)
        }
        g.line(.poly([(40, 60), (54, 44)]), 1.15)
        g.line(.poly([(40, 60), (28, 50)]), 0.85)
        g.blot(.circle(40, 60, 2.4))
        return g
    }

    static func blazeRock() -> DoodleGlyph {
        var g = DoodleGlyph("blazeRock", 0.08, 0.2, tilt: 6)
        g.shape(1, "^-2,62 8,36 26,16 ^44,8 66,10 ^84,26 ^96,46 ^104,62 z", 1.3)
        g.shape(2, "^32,26 ^62,24 ^64,32 ^33,34 z", 0.9)
        g.shape(-1, "^33,34 ^64,32 ^65,40 ^34,42 z", 0.9)
        g.shape(2, "^34,42 ^65,40 ^66,48 ^35,50 z", 0.9)
        g.detail(0.13) { g in
            g.line("^72,20 ^82,40 ^76,56", 0.5)
            g.line("^16,40 ^24,54", 0.45)
            g.hatch("^76,30 ^92,48 ^96,60 ^78,60 z", angle: 62, gap: 3, w: 0.45)
        }
        g.line("^-6,62 ^12,63", 0.7)
        g.line("^92,63 ^110,62", 0.7)
        g.line("^4,62 ^2,52", 0.7)
        g.line("^9,62 ^10,50", 0.7)
        return g
    }

    static func hut() -> DoodleGlyph {
        var g = DoodleGlyph("hut", 0.2, 0.36, tilt: 4)
        // Smoke, chimney.
        g.line("80,14 75,6 81,-1 76,-9 ^80,-16", 0.85)
        g.shape(1, "^74,14 ^86,14 ^86,40 ^74,32 z", 1.1)
        g.shape(-1, .rrect(72, 10, 16, 5, 2.4), 0.9)
        // The walls: planks, a gable window.
        g.shape(2, "^55,18 ^98,56 ^98,104 ^12,104 ^12,56 z", 1.35)
        g.detail(0.18) { g in
            for y in [64.0, 72.0, 80.0, 88.0, 96.0] {
                g.line("^12,\(y) ^22,\(y)", 0.42)
                g.line("^40,\(y) ^46,\(y)", 0.42)
                g.line("^64,\(y) ^70,\(y)", 0.42)
                g.line("^88,\(y) ^98,\(y)", 0.42)
            }
            g.hatch("^86,50 ^97,58 ^97,102 ^86,102 z", angle: 66, gap: 3, w: 0.45)
        }
        g.shape(-1, .circle(55, 42, 6.5), 0.9)
        g.line("^48.5,42 ^61.5,42", 0.55)
        g.line("^55,35.5 ^55,48.5", 0.55)
        // Door and two shuttered windows.
        g.shape(1, .rrect(45, 68, 20, 36, 2), 1.15)
        g.blot(.circle(60, 88, 1.3))
        g.line("^49,76 ^61,76", 0.45)
        for x in [22.0, 72.0] {
            g.shape(0, .rrect(x, 66, 16, 17, 1), 0.95)
            g.line("^\(x + 8),66 ^\(x + 8),83", 0.6)
            g.line("^\(x),74.5 ^\(x + 16),74.5", 0.6)
            g.shape(1, .poly([(x - 5, 66), (x, 66), (x, 83), (x - 5, 83)], closed: true), 0.75)
            g.shape(1, .poly([(x + 16, 66), (x + 21, 66), (x + 21, 83), (x + 16, 83)], closed: true), 0.75)
        }
        // A heavy load of snow on the roof, sagging over the eaves.
        g.shape(-1, "^55,6 ^76,23 ^112,56 110,63 104,62 100,67 94,60 ^55,27 ^16,60 10,67 6,62 0,63 -2,56 ^34,23 z", 1.35)
        g.shape(1, "^55,27 ^94,60 ^98,56 ^55,18 ^12,56 ^16,60 z", 0.9)
        g.detail(0.18) { g in
            g.line("^40,18 ^52,10", 0.42)
            g.line("^70,16 ^84,28", 0.42)
        }
        // Drift against the walls.
        g.shape(-1, "^-10,110 4,100 18,104 40,102 ^44,110 z", 1)
        g.shape(-1, "^68,110 72,102 92,102 106,100 ^120,110 z", 1)
        g.line("^44,110 ^68,110", 0.8)
        return g
    }

    static func snowshoe() -> DoodleGlyph {
        var g = DoodleGlyph("snowshoe", 0.1, 0.26, tilt: 26)
        g.band(1, outer: "24,0 42,8 48,30 44,70 30,108 ^24,122 ^18,108 4,70 0,30 6,8 z", inner: "24,6 37,12 42,31 38,68 26,102 ^24,110 ^22,102 10,68 6,31 11,12 z", 1.2, innerW: 0.75)
        g.strings(24, 50, 18.5, 44, gapX: 6, gapY: 6.6, w: 0.45)
        g.shape(2, .rrect(11, 34, 26, 24, 4), 1.1)
        g.line("^11,44 ^37,44", 0.7)
        g.shape(1, .rrect(8, 26, 32, 5, 2), 0.85)
        g.shape(-1, .rrect(20, 40, 8, 8, 1.5), 0.7)
        return g
    }

    static func sled() -> DoodleGlyph {
        var g = DoodleGlyph("sled", 0.1, 0.26, tilt: 12)
        // Rope.
        g.line("112,18 124,8 136,16 ^130,30", 0.85)
        // Far runner.
        g.line("^10,50 ^88,50 104,48 112,36 ^108,24", 1)
        // Uprights.
        for x in [24.0, 54.0, 84.0] {
            g.shape(1, .poly([(x, 28), (x + 5, 28), (x + 5, 54), (x, 54)], closed: true), 0.9)
        }
        // Slats.
        g.shape(2, "^-2,16 ^104,12 ^106,20 ^0,24 z", 1.25)
        g.shape(2, "^0,24 ^106,20 ^108,28 ^2,32 z", 1.25)
        g.detail(0.14) { g in
            g.line("^10,20 ^34,19", 0.42)
            g.line("^60,24 ^88,23", 0.42)
        }
        // The near runner, a steel-shod curve.
        g.shape(1, "^-6,54 ^92,54 106,52 116,40 114,26 ^106,22 ^110,28 ^111,38 102,46 ^90,47 ^-6,47 z", 1.2)
        return g
    }

    static func poles() -> DoodleGlyph {
        var g = DoodleGlyph("poles", 0.1, 0.26, tilt: 16)
        func one(_ g: inout DoodleGlyph, _ a: (Double, Double), _ b: (Double, Double)) {
            let dx = b.0 - a.0, dy = b.1 - a.1
            func P(_ t: Double, _ o: Double = 0) -> (Double, Double) { (a.0 + dx * t + o, a.1 + dy * t) }
            g.shape(1, DoodlePath.taper([P(0.05), P(1)], 4, 1.4), 0.85)
            g.shape(0, DoodlePath.taper([P(0.3), P(0.62)], 5, 5), 0.9)
            g.shape(2, DoodlePath.taper([P(0), P(0.2)], 7.5, 6.4), 1.05)
            g.shape(-1, .ellipse(P(0.88).0, P(0.88).1, 8.5, 3.4), 0.9)
            g.line(.spline([P(0.02, -3), P(0.08, -11), P(0.2, -9), P(0.2, -3)]), 0.7)
        }
        one(&g, (18, 4), (66, 130))
        one(&g, (72, 2), (22, 132))
        return g
    }

    static func shovel() -> DoodleGlyph {
        var g = DoodleGlyph("shovel", 0.1, 0.26, tilt: 26)
        g.band(1, outer: "6,0 34,0 40,10 ^32,22 ^8,22 0,10 z", inner: "10,6 30,6 33,11 ^28,16 ^12,16 7,11 z", 1.1)
        g.shape(1, "^15,22 ^25,22 ^25,84 ^15,84 z", 1.15)
        g.detail(0.14) { g in
            g.line("^15,50 ^25,50", 0.6)
            g.line("^15,53 ^25,53", 0.45)
            g.gel("^18,26 ^18,46", 0.7)
        }
        g.shape(2, "^2,78 ^38,78 42,104 34,122 ^20,132 ^6,122 -2,104 z", 1.35)
        g.line("^20,84 ^20,120", 0.6)
        g.detail(0.14) { g in
            g.line("^9,86 ^8,112", 0.45)
            g.line("^31,86 ^32,112", 0.45)
            g.hatch("^24,84 ^38,84 ^38,104 ^24,122 z", angle: 66, gap: 3, w: 0.42)
        }
        return g
    }

    static func stove() -> DoodleGlyph {
        var g = DoodleGlyph("stove", 0.11, 0.28, tilt: 8)
        g.line("26,6 22,-2 27,-9 ^23,-17", 0.75)
        g.line("44,4 48,-3 43,-10 ^47,-16", 0.75)
        // The pot, lid, wire handle.
        g.line("^8,20 -2,8 12,6 ^22,8", 0.8)
        g.shape(1, .rrect(6, 14, 58, 36, 4), 1.35)
        g.shape(0, "^4,14 8,8 ^62,8 ^66,14 z", 1.1)
        g.shape(1, .rrect(30, 3, 10, 5, 2), 0.85)
        g.detail(0.15) { g in
            g.hatch("^48,18 ^62,18 ^62,46 ^48,46 z", angle: 66, gap: 2.8, w: 0.45)
            g.gel("^12,20 ^12,38", 0.9)
        }
        // Flame.
        g.shape(2, "^24,62 27,56 ^30,52 34,56 ^35,50 40,56 ^44,52 46,58 ^47,62 z", 0.9)
        // Pot stand and burner.
        g.line("^10,50 ^20,66", 1.1)
        g.line("^60,50 ^50,66", 1.1)
        g.shape(1, .rrect(22, 62, 26, 6, 2), 1)
        g.shape(1, .rrect(30, 68, 10, 6, 1), 0.9)
        g.line("^40,71 ^50,71 ^54,75", 0.75)
        // The gas can.
        g.shape(0, "24,74 46,74 56,82 58,92 58,108 52,114 ^18,114 12,108 12,92 14,82 z", 1.35)
        g.shape(-1, .rrect(18, 90, 34, 16, 1.5), 0.8)
        g.blot("^26,103 ^32,94 ^35,98 ^38,95 ^44,103 z")
        return g
    }

    static func pennants() -> DoodleGlyph {
        var g = DoodleGlyph("pennants", 0.11, 0.3, tilt: 14)
        let cord = [(-4.0, 4.0), (28.0, 16.0), (62.0, 20.0), (96.0, 15.0), (128.0, 3.0)]
        let flags: [(Double, Double, Int)] = [(4, 7.6, 2), (28, 16, 0), (52, 19.8, -1), (76, 18.6, 2), (100, 14, 0)]
        for (x, y, s) in flags {
            g.shape(s, .poly([(x, y), (x + 18, y + (s == 0 ? 0.6 : 0.8)), (x + 8, y + 24)], closed: true), 1.1)
            g.detail(0.16) { $0.line(.poly([(x + 5, y + 5), (x + 13, y + 5)]), 0.42) }
        }
        g.line(.spline(cord), 1)
        return g
    }

    static func snowPine() -> DoodleGlyph {
        var g = DoodleGlyph("snowPine", 0.1, 0.3, tilt: 5)
        DoodleForest.conifer(&g, cx: 40, top: 2, bottom: 100, half: 34, tiers: 4, sep: 0, w: 1, seed: 77, needles: true)
        // Snow lying on the boughs.
        g.shape(-1, "^40,1 47,12 51,20 46,18 42,23 37,18 31,21 33,13 z", 0.95)
        g.shape(-1, "^28,36 34,32 40,36 46,32 54,37 58,42 50,41 44,44 38,41 32,44 24,42 z", 0.9)
        g.shape(-1, "^22,62 30,56 40,60 50,56 60,62 66,68 54,66 46,70 38,66 28,70 16,68 z", 0.9)
        g.shape(-1, "^-4,110 10,104 30,108 56,106 72,104 ^86,110 z", 1)
        return g
    }

    static func cocoa() -> DoodleGlyph {
        var g = DoodleGlyph("cocoa", 0.09, 0.22, tilt: 14)
        g.line("30,12 26,4 31,-3 ^27,-11", 0.75)
        g.line("50,12 54,4 49,-4 ^53,-10", 0.7)
        // Handle.
        g.line("74,32 88,32 92,46 84,60 ^72,62", 1.3)
        g.line("74,38 84,38 86,46 80,54 ^72,56", 0.75)
        g.shape(2, "^8,20 ^74,20 72,76 66,84 ^16,84 10,76 z", 1.35)
        g.shape(-1, .ellipse(41, 20, 33, 8), 1.1)
        g.shape(1, .ellipse(41, 21, 27, 5.4), 0.7)
        // Two marshmallows bobbing.
        g.shape(-1, .rrect(26, 14, 13, 9, 3), 0.8)
        g.shape(-1, .rrect(44, 15, 12, 8, 3), 0.8)
        // A flake on the side, speckled enamel.
        g.detail(0.13) { g in
            g.hatch("^58,28 ^72,28 ^70,80 ^60,82 z", angle: 66, gap: 3, w: 0.45)
            g.speckle(12, 30, 56, 80, n: 14, r: 0.8, seed: 12)
        }
        g.line("^37,54 ^37,44 ^46,56 ^46,46", 0)
        g.shape(-1, DoodleKit.gon(36, 54, 11, sides: 6), 0)
        for i in 0..<3 {
            let a = Double(i) * 60
            g.line(.poly([DoodleKit.polar(36, 54, 11, a), DoodleKit.polar(36, 54, 11, a + 180)]), 0.7)
        }
        return g
    }

    static func liftTicket() -> DoodleGlyph {
        var g = DoodleGlyph("liftTicket", 0.07, 0.17, tilt: 24)
        g.noFlip = true
        g.line("^28,18 ^16,0 ^40,0 ^28,18", 0.85)
        g.shape(-1, "^6,18 ^50,18 ^50,88 ^6,88 z", 1.25)
        g.shape(2, "^6,18 ^50,18 ^50,34 ^6,34 z", 1)
        g.line(.circle(28, 25, 3.6), 0.8)
        g.blot("^14,62 ^24,44 ^30,52 ^34,47 ^43,62 z")
        for (x, w) in [(13.0, 1.0), (17.0, 0.5), (20.5, 0.8), (25.0, 0.5), (28.0, 1.0), (33.0, 0.5), (36.0, 0.8), (41.0, 0.5)] {
            g.line(.poly([(x, 68), (x, 82)]), w)
        }
        return g
    }

    static func chough() -> DoodleGlyph {
        var g = DoodleGlyph("chough", 0.07, 0.17, tilt: 10)
        g.whole = true
        g.line("^40,58 ^38,70", 0.85)
        g.line("^48,58 ^48,70", 0.85)
        g.line("^32,71 ^44,70", 0.75)
        g.line("^42,71 ^54,70", 0.75)
        g.shape(1, "^-6,36 ^20,28 ^24,42 ^6,44 z", 1.05)
        g.shape(1, "18,34 28,22 44,16 58,4 70,4 77,10 ^90,16 ^76,18 72,26 68,42 56,56 38,60 24,52 z", 1.3)
        g.shape(2, "^76,9 ^92,16 ^76,18 z", 0.9)
        g.accent(.circle(68, 10, 1.9))
        g.detail(0.12) { g in
            g.line("^30,28 ^50,44 ^64,28", 0.5)
            g.line("^36,36 ^50,50", 0.45)
            g.gel("^44,26 ^54,20", 0.7)
        }
        return g
    }

    static func ropeKnot() -> DoodleGlyph {
        var g = DoodleGlyph("ropeKnot", 0.08, 0.2, tilt: 40)
        // A figure-eight knot, the rope as a fat band.
        func strand(_ g: inout DoodleGlyph, _ p: [(Double, Double)]) {
            let line = DoodlePath.spline(p)
            g.shape(2, DoodlePath.taper(p, 9, 9), 1.15)
            g.detail(0.12) { g in
                let f = line.flattened(step: 5).ring
                for q in f { g.line(.poly([(q.x - 2, q.y - 2.4), (q.x + 2, q.y + 2.4)]), 0.42) }
            }
        }
        strand(&g, [(-8, 58), (10, 56), (34, 40), (50, 22), (68, 16), (80, 30), (70, 46), (50, 50), (36, 64), (24, 78), (30, 90), (46, 92), (54, 78), (46, 62), (26, 46), (18, 30), (28, 14), (44, 10)])
        strand(&g, [(44, 62), (62, 74), (84, 76), (106, 66)])
        return g
    }

    static func iceBlock() -> DoodleGlyph {
        var g = DoodleGlyph("iceBlock", 0.07, 0.17, tilt: 18)
        g.shape(0, "^18,18 ^44,4 ^74,14 ^86,44 ^68,76 ^30,80 ^6,52 z", 1.3)
        g.line("^44,4 ^44,34 ^18,18", 0.7)
        g.line("^44,34 ^74,14", 0.7)
        g.line("^44,34 ^48,58 ^86,44", 0.7)
        g.line("^48,58 ^30,80", 0.7)
        g.line("^48,58 ^68,76", 0.7)
        g.shade("^44,34 ^74,14 ^86,44 ^48,58 z")
        g.gel("^16,26 ^12,46", 1)
        g.gel("^34,14 ^26,20", 0.9)
        g.detail(0.12) { $0.hatch("^52,62 ^78,50 ^66,72 ^54,74 z", angle: 60, gap: 2.8, w: 0.42) }
        return g
    }

    static func tinyFlake() -> DoodleGlyph {
        var g = DoodleGlyph("tinyFlake", 0.022, 0.05, tilt: 30)
        for i in 0..<3 {
            let a = Double(i) * 60
            g.line(.poly([DoodleKit.polar(20, 20, 20, a), DoodleKit.polar(20, 20, 20, a + 180)]), 0.85)
        }
        return g
    }

    static func tinyPeak() -> DoodleGlyph {
        var g = DoodleGlyph("tinyPeak", 0.03, 0.075, tilt: 6)
        g.shape(1, "^24,0 ^50,40 ^0,40 z", 0.9)
        g.shape(-1, "^24,0 ^33,14 ^28,11 ^24,17 ^20,11 ^15,14 z", 0.7)
        return g
    }

    static func tinyBird() -> DoodleGlyph {
        var g = DoodleGlyph("tinyBird", 0.025, 0.06, tilt: 18)
        g.line("^0,8 8,1 ^16,8 24,1 ^32,8", 0.85)
        return g
    }

    static func bootPrints() -> DoodleGlyph {
        var g = DoodleGlyph("bootPrints", 0.035, 0.08, tilt: 60)
        for (x, y) in [(0.0, 20.0), (16.0, 0.0)] {
            g.blot(.ellipse(x + 6, y + 8, 6, 8))
            g.blot(.ellipse(x + 6, y + 23, 5, 4.6))
        }
        return g
    }

    static func windCurl() -> DoodleGlyph {
        var g = DoodleGlyph("windCurl", 0.04, 0.09, tilt: 16)
        g.line("^0,14 20,14 34,14 42,6 36,0 ^28,6", 0.8)
        g.line("^8,22 ^38,22", 0.7)
        return g
    }

    static func snowDrift() -> DoodleGlyph {
        var g = DoodleGlyph("snowDrift", 0.04, 0.09, tilt: 8)
        g.shape(-1, "^0,18 8,8 20,6 30,0 42,4 52,12 ^62,18 z", 0.8)
        return g
    }

    static func tinyStone() -> DoodleGlyph {
        var g = DoodleGlyph("tinyStone", 0.018, 0.04, tilt: 60)
        g.shape(0, "^2,9 ^10,1 ^22,2 ^27,10 ^20,18 ^6,17 z", 0.8)
        g.line("^10,1 ^13,9 ^27,10", 0.42)
        return g
    }

    static func tinySki() -> DoodleGlyph {
        var g = DoodleGlyph("tinySki", 0.04, 0.085, tilt: 60)
        g.line("^0,20 28,20 ^38,12", 1)
        g.line("^4,26 32,26 ^42,18", 1)
        return g
    }

    static func helmet() -> DoodleGlyph {
        var g = DoodleGlyph("helmet", 0.13, 0.3, tilt: 20)
        // The chin strap hangs loose, then the shell.
        g.line("^28,58 38,76 50,84 ^72,60", 0.95)
        g.line("^40,78 ^58,74", 0.8)
        g.shape(-1, .rrect(44, 78, 8, 6, 1), 0.65)
        g.shape(2, "^4,56 6,34 20,14 46,4 74,10 92,28 ^98,56 ^60,54 z", 1.4)
        g.shape(1, "^4,56 ^98,56 ^96,66 ^6,66 z", 1.1)
        g.detail(0.16) { g in
            g.line("^28,56 ^30,66", 0.45)
            g.line("^60,56 ^62,66", 0.45)
            g.gel("^16,30 26,18 ^40,12", 1)
            g.hatch("^76,16 ^90,30 ^96,52 ^78,52 z", angle: 62, gap: 3, w: 0.45)
        }
        // Vent slots.
        for (x, y, r) in [(34.0, 24.0, -28.0), (52.0, 18.0, -6.0), (70.0, 26.0, 22.0)] {
            g.accent(DoodlePath.ellipse(x, y, 7, 2.6, rot: r))
        }
        g.accent(DoodlePath.ellipse(46, 38, 7, 2.4, rot: -6))
        g.accent(DoodlePath.ellipse(66, 42, 7, 2.4, rot: 12))
        // The headlamp, on a strap round the rim.
        g.shape(1, .rrect(-8, 36, 18, 18, 4), 1.2)
        g.shape(-1, .circle(0, 45, 5.6), 0.9)
        g.gel("-3,43 -1,41", 0.6)
        return g
    }

    static func crampons() -> DoodleGlyph {
        var g = DoodleGlyph("crampons", 0.13, 0.32, tilt: 22)
        // Straps arching over, a buckle.
        g.line("^16,16 14,-2 30,-10 50,-2 ^46,16", 1.3)
        g.line("^86,12 86,-2 102,-10 116,-2 ^110,12", 1.3)
        g.shape(2, .rrect(93, -15, 16, 10, 2), 0.95)
        g.shape(2, .rrect(23, -15, 16, 10, 2), 0.95)
        // The teeth first, so the frame sits over their roots.
        for t in [(8.0, 34.0), (22.0, 34.0), (36.0, 34.0), (86.0, 32.0), (100.0, 32.0), (114.0, 30.0)] {
            g.shape(1, .poly([(t.0 - 6.5, t.1 - 6), (t.0 + 6.5, t.1 - 6), (t.0 + 1, t.1 + 25)], closed: true), 1.05)
        }
        // Two front points, reaching forward.
        g.shape(1, "^118,10 ^150,18 ^118,20 z", 1.05)
        g.shape(1, "^116,20 ^144,34 ^116,28 z", 1.05)
        // The frame, with a bar linking heel to toe.
        g.shape(1, "^0,14 ^42,13 ^50,22 ^72,22 ^80,10 ^120,8 ^124,18 ^118,30 ^80,32 ^72,36 ^50,36 ^42,32 ^0,32 z", 1.45)
        g.detail(0.16) { g in
            g.gel("^6,19 ^34,19", 0.9)
            g.gel("^86,15 ^112,13", 0.9)
            g.line("^54,29 ^70,29", 0.55)
            g.blot(.circle(20, 25, 1.7))
            g.blot(.circle(100, 21, 1.7))
        }
        return g
    }

    private static func biner(_ g: inout DoodleGlyph, _ T: (DoodlePath) -> DoodlePath, sep: Int) {
        g.band(sep, outer: T("22,0 44,0 58,12 56,34 46,76 34,88 16,86 6,72 ^8,20 z"), inner: T("24,10 42,10 48,16 46,32 38,70 32,78 20,76 16,68 ^18,22 z"), 1)
        g.shape(1, T("^7,26 ^17,26 ^17,60 ^7,60 z"), 0.8)
        g.line(T("^9,32 ^15,32"), 0.4)
        g.line(T("^9,38 ^15,38"), 0.4)
    }

    static func quickdraw() -> DoodleGlyph {
        var g = DoodleGlyph("quickdraw", 0.12, 0.3, tilt: 30)
        biner(&g, { $0.scaled(0.62).moved(10, 0) }, sep: 0)
        biner(&g, { $0.mirrored(about: 28).scaled(0.62).moved(10, 92) }, sep: 2)
        // A dog-bone sling between them.
        g.shape(1, "^20,40 ^38,40 ^34,50 ^34,82 ^38,96 ^20,96 ^24,82 ^24,50 z", 1.15)
        g.detail(0.14) { g in
            g.line("^24,52 ^34,52", 0.5)
            g.line("^24,56 ^34,56", 0.5)
            g.line("^24,76 ^34,76", 0.5)
            g.line("^24,80 ^34,80", 0.5)
        }
        return g
    }

    static func pitonHammer() -> DoodleGlyph {
        var g = DoodleGlyph("pitonHammer", 0.12, 0.3, tilt: 30)
        // The hammer, a long pick one side, a square face the other.
        g.shape(2, "^36,16 ^48,16 ^50,118 ^34,118 z", 1.25)
        for y in stride(from: 84.0, through: 112.0, by: 5.0) { g.line("^34,\(y) ^50,\(y + 2.4)", 0.55) }
        g.shape(1, "^24,4 ^62,4 72,8 ^92,20 ^68,18 ^62,20 ^24,20 z", 1.3)
        g.shape(1, .rrect(10, 2, 18, 20, 2), 1.3)
        g.line("^17,2 ^17,22", 0.5)
        g.detail(0.14) { $0.gel("^36,8 ^58,8", 0.9); $0.gel("^39,30 ^39,70", 0.8) }
        // A piton driven down beside it, with its eye.
        g.shape(0, "^66,50 ^84,50 ^84,66 ^78,66 ^75,112 ^73,66 ^66,66 z", 1.1)
        g.blot(.circle(75, 58, 2.6))
        g.line(.circle(75, 44, 6), 0.95)
        return g
    }

    static func iceScrew() -> DoodleGlyph {
        var g = DoodleGlyph("iceScrew", 0.09, 0.22, tilt: 34)
        // A steel tube with a deep coarse thread and cutting teeth, a hanger with its crank folded, a krab clipped on.
        g.shape(0, "^16,24 ^36,24 ^36,104 ^33,112 ^30,104 ^26,112 ^22,104 ^19,112 ^16,104 z", 1.25)
        var y = 34.0
        while y < 100 {
            g.tint(1, .poly([(16, y + 3), (36, y - 3), (36, y + 1), (16, y + 7)], closed: true))
            g.line(.poly([(12.5, y + 4), (39.5, y - 4)]), 0.85)
            y += 12
        }
        g.shape(1, "^10,14 ^42,14 ^42,26 ^10,26 z", 1.2)
        g.shape(2, "^42,14 ^62,4 ^72,12 ^66,24 ^42,26 z", 1.15)
        g.blot(.circle(60, 14, 3.4))
        // The folding crank.
        g.line("^10,16 ^-4,6 ^-6,-2", 1.05)
        g.shape(1, .circle(-6, -4, 4.4), 0.95)
        // A little krab through the hanger.
        g.band(0, outer: .rrect(58, 12, 15, 34, 7), inner: .rrect(62, 16, 7, 26, 3.5), 1.05, innerW: 0.7)
        g.line("^65,28 ^65,30", 0)
        return g
    }

    static func figureEight() -> DoodleGlyph {
        var g = DoodleGlyph("figureEight", 0.06, 0.15, tilt: 40)
        g.shape(1, "26,0 42,6 48,22 42,38 32,46 38,56 46,72 40,92 24,102 8,92 2,72 10,56 16,46 8,38 2,22 8,6 z", 1.3)
        g.shape(-1, .ellipse(25, 23, 11, 13), 1)
        g.shape(-1, .ellipse(24, 74, 13, 17), 1)
        g.detail(0.09) { $0.gel("6,16 10,8 ^18,4", 0.7) }
        return g
    }

    static func headlamp() -> DoodleGlyph {
        var g = DoodleGlyph("headlamp", 0.09, 0.22, tilt: 22)
        // The elastic loop, far side behind.
        g.band(2, outer: .ellipse(50, 36, 46, 26), inner: .ellipse(50, 36, 40, 19), 1, innerW: 0.7)
        g.detail(0.13) { g in
            for i in 0..<9 {
                let a = 30 + Double(i) * 15
                let p = DoodleKit.polar(50, 36, 43, a)
                g.line(.poly([(p.0, p.1 - 3), (p.0, p.1 + 3)]), 0.42)
            }
        }
        // The lamp on its bracket.
        g.shape(1, "^28,44 ^72,44 ^76,76 ^24,76 z", 1.35)
        g.shape(-1, .circle(50, 60, 12.5), 1.05)
        g.shape(0, .circle(50, 60, 8), 0.8)
        g.gel("45,57 47,54.5", 0.8)
        g.blot(.circle(32, 50, 1.2))
        g.blot(.circle(68, 50, 1.2))
        return g
    }

    static func mittens() -> DoodleGlyph {
        var g = DoodleGlyph("mittens", 0.13, 0.32, tilt: 14)
        func mitt(_ g: inout DoodleGlyph, sep: Int, band: Int, _ T: (DoodlePath) -> DoodlePath) {
            g.shape(sep, T("^12,74 ^48,74 52,52 52,28 44,8 30,2 16,8 10,26 ^10,36 4,28 -4,30 -6,40 2,54 ^10,62 z"), 1.3)
            g.tint(band, T("^11,32 ^52,30 ^52,42 ^10,44 z"))
            g.line(T("^11,32 ^52,30"), 0.6)
            g.line(T("^10,44 ^52,42"), 0.6)
            g.line(T("^14,54 ^26,56"), 0.5)
            g.detail(0.16) { g in
                for x in stride(from: 16.0, through: 46.0, by: 7.5) { g.blot(T(.circle(x, 37.4, 1.3))) }
            }
            g.shape(-1, T(.rrect(8, 72, 44, 15, 3.5)), 1.2)
            g.detail(0.16) { g in
                for x in stride(from: 13.0, through: 48.0, by: 5.0) { g.line(T(.poly([(x, 74), (x, 85)])), 0.5) }
            }
        }
        // The cord that joins them.
        g.line("34,88 44,106 68,108 86,90", 0.85)
        mitt(&g, sep: 2, band: 0) { $0.moved(4, 2) }
        mitt(&g, sep: 0, band: 2) { $0.mirrored(about: 30).rotated(10, about: (30, 60)).moved(62, 4) }
        return g
    }

    static func beanie() -> DoodleGlyph {
        var g = DoodleGlyph("beanie", 0.1, 0.26, tilt: 22)
        g.shape(-1, DoodleKit.puff(42, 14, 13, 13, n: 9, depth: 0.2), 1.05)
        g.shape(2, "^8,66 8,44 20,26 42,20 64,26 76,44 ^76,66 z", 1.35)
        g.tint(0, "^9,42 ^75,42 ^77,52 ^8,52 z")
        g.line("^9,42 ^75,42", 0.6)
        g.line("^8,52 ^76,52", 0.6)
        g.detail(0.15) { g in
            g.line("^42,22 ^42,40", 0.45)
            g.line("^28,26 ^24,40", 0.45)
            g.line("^56,26 ^60,40", 0.45)
            g.hatch("^62,26 ^76,44 ^76,64 ^62,64 z", angle: 66, gap: 3, w: 0.42)
        }
        g.shape(1, .rrect(3, 62, 78, 22, 6), 1.3)
        g.detail(0.13) { g in
            for x in stride(from: 10.0, through: 76.0, by: 6.6) { g.line("^\(x),65 ^\(x),81", 0.5) }
        }
        return g
    }

    static func alpinePack() -> DoodleGlyph {
        var g = DoodleGlyph("alpinePack", 0.2, 0.4, tilt: 7)
        g.must = true
        // An ice axe strapped up the side, behind the pack.
        g.shape(2, "^88,14 ^94,14 ^100,116 ^92,116 z", 1)
        g.shape(1, "^76,12 ^108,8 ^110,16 ^76,20 z", 1.1)
        // Coil of rope on the lid.
        g.shape(0, .ellipse(50, 15, 28, 8), 1.15)
        g.shape(0, .ellipse(50, 9, 28, 8), 1.15)
        g.detail(0.2) { g in
            for x in stride(from: 28.0, through: 72.0, by: 7.0) { g.line("^\(x),13 ^\(x + 2),17", 0.45) }
        }
        // Body.
        g.shape(1, "20,24 34,18 66,18 80,24 86,60 86,112 78,124 22,124 14,112 14,60 z", 1.45)
        g.detail(0.2) { g in
            g.hatch("^70,32 ^84,32 ^85,110 ^70,110 z", angle: 66, gap: 3.2, w: 0.45)
            g.line("^18,50 ^82,50", 0.5)
        }
        // The lid with its buckle straps.
        g.shape(2, "18,28 26,18 50,14 74,18 82,28 84,46 74,54 50,56 26,54 16,46 z", 1.35)
        g.line("^18,44 34,50 66,50 ^82,44", 0.55)
        g.stitch("^24,24 ^76,24", dash: 2.6, gap: 2.2, w: 0.45)
        for x in [34.0, 66.0] {
            g.shape(-1, .poly([(x - 3.5, 48), (x + 3.5, 48), (x + 3.5, 76), (x - 3.5, 76)], closed: true), 0.85)
            g.shape(1, .rrect(x - 5, 70, 10, 7, 1.2), 0.75)
        }
        // A front pocket.
        g.shape(0, "^24,84 ^76,84 78,112 70,118 ^30,118 22,112 z", 1.25)
        g.line("^24,92 ^76,92", 0.6)
        g.stitch("^27,114 ^73,114", dash: 2.4, gap: 2, w: 0.45)
        g.shape(-1, .rrect(44, 90, 12, 5, 1.5), 0.6)
        // Daisy chain.
        g.detail(0.2) { g in
            for y in [62.0, 68.0, 74.0, 80.0] { g.line("^47,\(y) ^53,\(y)", 0.5) }
            g.line("^47,58 ^47,84", 0.5)
            g.line("^53,58 ^53,84", 0.5)
        }
        return g
    }

    static func domeTent() -> DoodleGlyph {
        var g = DoodleGlyph("domeTent", 0.24, 0.42, tilt: 5)
        g.must = true
        // Guy lines.
        g.line("^16,40 ^-14,84", 0.6)
        g.line("^112,36 ^140,82", 0.6)
        g.blot("^-16,82 ^-12,82 ^-14,88 z")
        g.blot("^138,80 ^142,80 ^140,86 z")
        // The dome: three panels.
        g.shape(2, "^4,84 8,54 28,24 62,10 96,20 116,50 ^124,84 z", 1.5)
        g.tint(0, "^36,84 36,52 44,28 ^62,10 74,26 80,52 ^84,84 z")
        // Poles.
        g.line("^4,84 12,44 ^62,10 96,28 ^124,84", 0.5)
        g.line("^36,84 36,52 44,28 ^62,10", 0.8)
        g.line("^84,84 80,52 74,26 ^62,10", 0.8)
        g.line("^8,54 40,38 76,36 ^116,50", 0.7)
        // Door, unzipped and tied back.
        g.accent("^44,84 48,62 ^60,44 ^72,62 ^76,84 z")
        g.shape(-1, "^60,44 66,56 ^70,84 ^78,84 ^72,60 z", 0.95)
        g.line("^60,44 ^48,62 ^44,84", 0.8)
        g.detail(0.2) { g in
            g.stitch("^61,47 ^68,84", dash: 1.8, gap: 1.4, w: 0.45)
            g.hatch("^96,30 ^112,50 ^120,82 ^92,82 z", angle: 62, gap: 3.2, w: 0.45)
            g.gel("^14,50 26,34 ^40,24", 1)
        }
        // A stubby flag on top.
        g.line("^62,10 ^62,-4", 0.9)
        g.shape(2, "^62,-4 ^76,0 ^62,4 z", 0.85)
        // Snow banked round the skirt, a boot-trodden path.
        g.shape(-1, "^-8,92 2,82 18,86 36,82 44,86 ^46,92 z", 1.1)
        g.shape(-1, "^76,92 80,84 96,86 112,82 126,84 ^138,92 z", 1.1)
        g.line("^46,92 ^76,92", 0.85)
        return g
    }

    static func summitFlag() -> DoodleGlyph {
        var g = DoodleGlyph("summitFlag", 0.17, 0.36, tilt: 5)
        g.must = true
        // A shoulder of rock behind, and the top with its flag planted in it.
        g.shape(1, "^76,50 ^96,74 ^112,104 ^40,104 z", 1.1)
        g.shade("^76,50 ^96,74 ^112,104 ^76,104 ^84,84 z")
        g.shape(1, "^50,28 ^58,38 ^64,38 ^74,56 ^86,70 ^98,104 ^-4,104 ^10,78 ^20,68 ^28,50 ^38,44 z", 1.35)
        g.shade("^50,28 ^58,38 ^64,38 ^74,56 ^86,70 ^98,104 ^56,104 ^60,86 ^50,68 ^56,54 z")
        g.line("^50,30 ^56,54 ^50,68 ^60,86 ^56,104", 0.75)
        g.shape(-1, "^50,28 ^58,38 ^64,38 ^72,52 ^65,48 ^60,57 ^54,50 ^48,60 ^42,50 ^35,58 ^30,50 ^38,44 z", 1.05)
        g.detail(0.18) { g in
            g.line("^20,88 ^28,74 ^26,92", 0.5)
            g.line("^38,92 ^42,80 ^40,96", 0.5)
            g.gel("^43,38 ^38,46", 1)
        }
        // Pole and flag.
        g.line("^50,30 ^50,-6", 1.25)
        g.blot(.circle(50, -7, 2))
        g.shape(2, "^50,-4 66,-8 82,-1 96,-5 ^92,12 82,18 66,12 ^50,16 z", 1.25)
        g.detail(0.18) { g in
            g.line("66,-6 66,4 ^66,10", 0.42)
            g.line("82,0 82,8 ^82,16", 0.42)
            g.shade("^66,-8 82,-1 ^82,18 66,12 z")
        }
        // Two tiny climbers on a rope, coming up the ridge.
        g.line("^4,88 12,84 ^20,74", 0.6)
        g.blot(.circle(11, 77, 1.9))
        g.line("^11,79 ^10,86", 1)
        g.blot(.circle(21, 67, 1.7))
        g.line("^21,69 ^20,75", 1)
        return g
    }

    static func peaks() -> DoodleGlyph {
        var g = DoodleGlyph("peaks", 0.3, 0.46, tilt: 4)
        g.must = true
        g.noTuck = true
        // A far range, in shadow.
        let far: DoodlePath = "^86,30 ^94,22 ^100,30 ^108,18 ^118,30 ^126,42 ^142,62 ^142,84 ^64,84 z"
        g.shape(0, far, 0.9)
        g.shade(far)
        g.detail(0.22) { g in
            g.line("^104,30 ^112,44 ^108,58", 0.5)
            g.line("^122,44 ^130,62", 0.45)
        }
        // The main peak with a broken, believable ridge line.
        g.shape(0, "^56,3 ^63,11 ^68,14 ^76,28 ^84,36 ^96,54 ^118,88 ^-6,88 ^10,62 ^20,52 ^28,36 ^38,28 ^46,12 z", 1.3)
        // Its shadow side, a crisp shape following the ridge.
        g.shade("^56,3 ^63,11 ^68,14 ^76,28 ^84,36 ^96,54 ^118,88 ^62,88 ^70,70 ^60,54 ^66,38 ^56,22 z")
        g.line("^56,5 ^56,22 ^66,38 ^60,54 ^70,70 ^62,88", 0.8)
        g.detail(0.2) { g in
            // Rock strata, only where the light catches.
            g.line("^30,62 ^38,50 ^36,66", 0.6)
            g.line("^14,78 ^24,66 ^22,80", 0.6)
            g.line("^44,74 ^50,62 ^48,78", 0.6)
            g.hatch("^68,34 ^78,36 ^92,56 ^80,60 z", angle: 64, gap: 3.6, w: 0.5)
        }
        g.shape(-1, "^56,3 ^63,11 ^68,14 ^76,28 ^71,25 ^68,35 ^62,27 ^56,37 ^50,26 ^43,36 ^40,27 ^38,28 ^46,12 z", 1)
        g.shade("^56,3 ^63,11 ^68,14 ^76,28 ^71,25 ^68,35 ^62,27 ^56,37 z")
        // Light catching the snow, so it stays snow at night too.
        g.gel("^51,12 ^46,23", 1.5)
        g.gel("^46,17 ^42,27", 1.1)
        g.gel("^53,20 ^50,29", 1.1)
        // A second peak in front.
        g.shape(0, "^104,46 ^111,54 ^114,52 ^124,68 ^142,90 ^78,90 ^90,72 ^96,64 z", 1.2)
        g.shade("^104,46 ^111,54 ^114,52 ^124,68 ^142,90 ^110,90 ^114,76 ^106,64 z")
        g.shape(-1, "^104,46 ^111,54 ^114,52 ^120,62 ^114,58 ^110,65 ^105,58 ^100,66 ^96,64 z", 0.9)
        // Trees at the foot: real ones, grouped, each its own height, gaps between the groups.
        var rng = SplitMix64(seed: 41)
        for (start, count, h0) in [(-2.0, 3, 20.0), (34.0, 2, 13.0), (58.0, 4, 24.0), (112.0, 3, 18.0)] {
            var x = start
            for i in 0..<count {
                let h = h0 * rng.next(0.55, 1.0) * (i == 1 ? 1.1 : 0.85)
                DoodleForest.conifer(&g, cx: x, top: 92 - h, bottom: 92, half: h * 0.34, tiers: h > 16 ? 3 : 2, sep: 0, w: 0.72, seed: UInt64(x + 300), needles: false)
                x += h * 0.42 + rng.next(2.5, 4)
            }
        }
        // A curved foothill line, no slab.
        g.line("^-8,97 16,95 48,98 ^80,96", 0.7)
        g.line("^92,97 ^134,95.5", 0.7)
        g.detail(0.2) { g in
            g.shape(-1, "6,24 10,17 18,16 22,10 32,10 37,16 44,16 48,23 ^2,24 z", 0.85)
            g.line("^12,23 ^33,23", 0.45)
            g.line("86,8 89,5 92,8 95,5 98,8", 0.7)
            g.line("102,14 104,12 106,14 108,12 110,14", 0.6)
        }
        return g
    }

    static func boot() -> DoodleGlyph {
        var g = DoodleGlyph("boot", 0.26, 0.35, tilt: 12)
        g.must = true
        g.noFlip = false
        // Tongue and the far side of the throat.
        g.shape(2, "^47,24 49,10 57,3 66,6 69,14 ^68,24 74,34 86,46 96,54 ^110,66 ^86,68 ^58,50 z", 1.05)
        g.detail(0.22) { g in
            g.line("^52,12 55,7 ^62,7", 0.5)
            g.line("^51,18 ^65,16", 0.45)
        }
        // The upper in one piece; its top edge is the row of eyelets.
        g.shape(1, "^8,91 9,70 13,44 13,24 ^47,24 ^50,30 56,38 64,46 73,54 82,60 92,64 106,69 114,76 ^119,85 ^96,92 ^8,92 z", 1.25)
        // Heel counter and toe cap, each with its stitching.
        g.shape(0, "^8,91 9,72 11,58 ^22,57 30,66 38,78 ^44,92 ^8,92 z", 1)
        g.shape(0, "^119,85 ^98,92 ^76,92 76,80 ^88,63 92,64 106,69 114,76 z", 1)
        g.detail(0.2) { g in
            g.stitch("^14,60 ^22,60 31,69 ^40,88", dash: 2.2, gap: 1.8, w: 0.5)
            g.stitch("^79,88 79,80 ^89,67", dash: 2.2, gap: 1.8, w: 0.5)
            // A panel seam, and a gusset behind the eyelets.
            g.line("^30,34 36,46 46,58 ^62,68 70,80 ^72,91", 0.55)
            g.line("^45,32 50,42 58,50 70,60 ^80,66", 0.5)
            g.gel("93,70 104,74 112,81", 0.7)
            g.gel("13,66 14,60", 0.7)
        }
        g.shade("^8,91 9,72 ^11,60 ^14,60 13,72 ^12,91 z")
        // Sole: the same thickness all along, toe lifted, rounded, no point.
        g.shape(-1, "^6,91 ^60,91 ^96,91 108,88 118,84 122,87 120,92 110,97 ^96,99 ^6,99 z", 1.2)
        g.detail(0.2) { $0.stitch("^10,95 ^60,95 ^96,95 108,92.5 ^116,89", dash: 2.2, gap: 2, w: 0.5) }
        // The tread is one strip with lugs cut out of it, so it stays attached to the sole.
        var tread: [(Double, Double)] = [(6.5, 99), (96, 99), (108.5, 96.4), (118, 91.6)]
        var under: [(Double, Double)] = []
        for i in 0..<8 {
            let x = 7.0 + Double(i) * 13.4
            let y = i < 6 ? 100.8 : 100.8 - Double(i - 5) * 2.1
            under += [(x, y), (x + 1, y + 4.6), (x + 9.4, y + 4.6), (x + 10.4, y)]
        }
        tread += under.reversed()
        g.accent(.poly(tread, closed: true))
        // Wear: creases where the ankle bends, a stitched maker's patch, hatching in the shadow behind the heel.
        g.detail(0.2) { g in
            g.line("^15,34 21,36 ^27,35", 0.5)
            g.line("^14,40 21,42.4 ^31,41", 0.5)
            g.line("^37,36 ^41,44", 0.42)
            g.hatch("^13,44 ^19,44 ^21,57 ^12,57 z", angle: 62, gap: 2.4, w: 0.42)
            g.hatch("^48,72 ^68,70 ^74,90 ^46,90 z", angle: 58, gap: 3.2, w: 0.4)
        }
        g.detail(0.24) { g in
            g.shape(-1, .rrect(24, 46, 15, 10, 1.6), 0.6)
            g.blot("^27,54 ^31,49 ^33,52 ^34,50.5 ^37,54 z")
        }
        // The padded cuff, quilted, the opening dark behind it.
        g.shape(2, "10,28 6,20 9,12 20,7.5 34,7 46,10 51,17 50,28 38,31 22,31 z", 1.2)
        g.accent(.ellipse(29, 13.5, 16.5, 4.2))
        g.detail(0.2) { g in
            for x in [16.0, 24.0, 32.0, 40.0, 46.0] { g.line("^\(x),20 \(x + 0.5),25 ^\(x),29.5", 0.5) }
        }
        // Four pairs of laces crossing, and the eyelets they run through.
        let near: [(Double, Double)] = [(52, 32), (58.5, 40), (66, 47.5), (75, 55), (84, 61.5)]
        let far: [(Double, Double)] = [(64, 24), (71, 32), (79, 40), (88, 47.5), (98, 55)]
        for i in 0..<4 {
            g.line(.poly([near[i + 1], far[i]]), 1)
            g.line(.poly([far[i + 1], near[i]]), 1)
        }
        for p in near + far { g.blot(.circle(p.0, p.1, 1.5)) }
        // Speed hooks up the ankle.
        for (x, y) in [(47.0, 25.0), (46.0, 31.0)] {
            g.line("^\(x),\(y) \(x + 3.2),\(y - 0.6) \(x + 4),\(y + 1.4) ^\(x + 2),\(y + 2)", 0.8)
        }
        // The bow on top.
        g.line("^64,24 70,14 80,14 80,20 ^64,24", 0.85)
        g.line("^64,24 58,17 54,20 56,25 ^64,24", 0.85)
        g.line("^64,24 72,28 ^78,26", 0.75)
        return g
    }

    static func rope() -> DoodleGlyph {
        var g = DoodleGlyph("rope", 0.09, 0.18, tilt: 14)
        // A coil seen from the front: three turns and a tail.
        g.line("78,62 92,70 98,84 ^86,92", 1.2)
        g.shape(2, .ellipse(44, 62, 42, 22), 1.2)
        g.shape(2, .ellipse(44, 48, 42, 22), 1.2)
        g.shape(2, .ellipse(44, 34, 42, 22), 1.2)
        g.shape(-1, .ellipse(44, 32, 25, 11), 1)
        g.accent(.ellipse(44, 33, 18, 7))
        g.detail(0.11) { g in
            for i in 0..<9 {
                let t = Double(i) / 8
                let x = 8 + t * 72
                let y = 66 + 14 * sin(t * .pi)
                g.line(.poly([(x, y), (x + 4, y + 5)]), 0.42)
                g.line(.poly([(x, y - 14), (x + 4, y - 9)]), 0.42)
            }
        }
        // A binding round the middle.
        g.shape(1, "^38,18 ^52,18 ^54,80 ^36,80 z", 1)
        g.line("^36,40 ^53,40", 0.5)
        g.line("^36,58 ^54,58", 0.5)
        return g
    }

    static func carabiner() -> DoodleGlyph {
        var g = DoodleGlyph("carabiner", 0.05, 0.11, tilt: 50)
        g.band(2, outer: "22,0 44,0 58,12 56,34 46,76 34,88 16,86 6,72 ^8,20 z", inner: "24,10 42,10 48,16 46,32 38,70 32,78 20,76 16,68 ^18,22 z", 1)
        g.shape(1, "^7,26 ^17,26 ^17,60 ^7,60 z", 0.8)
        g.line("^9,32 ^15,32", 0.4)
        g.line("^9,38 ^15,38", 0.4)
        g.line("^9,44 ^15,44", 0.4)
        return g
    }

    static func map() -> DoodleGlyph {
        var g = DoodleGlyph("map", 0.12, 0.34, tilt: 24)
        g.shape(-1, "^4,14 ^36,6 ^68,14 ^100,6 ^100,78 ^68,86 ^36,78 ^4,86 z", 1.25)
        g.tint(0, "^36,6 ^68,14 ^68,86 ^36,78 z")
        g.line("^36,6 ^36,78", 0.75)
        g.line("^68,14 ^68,86", 0.75)
        // A lake, a range, a dotted route to an X.
        g.shape(0, "9,64 15,58 22,61 30,58 33,63 26,68 19,67 13,72 z", 0.7)
        g.line("^44,40 ^50,28 ^55,38 ^60,30 ^66,44", 0.85)
        g.detail(0.14) { g in
            g.line("^47,36 ^50,41", 0.4)
            g.line("^60,34 ^62,41", 0.4)
            g.hatch("^72,20 ^96,14 ^96,28 ^72,34 z", angle: 30, gap: 3, w: 0.42)
            g.line("^14,24 ^28,20", 0.45)
            g.line("^14,30 ^24,27", 0.45)
        }
        g.stitch("20,50 30,42 40,54 54,62 66,56 78,44 ^86,34", dash: 3, gap: 2.8, w: 0.85)
        g.line("^83,28 ^92,38", 1.25)
        g.line("^92,28 ^83,38", 1.25)
        g.blot(DoodleFillers.sparklePath(84, 68, 7, 0.2))
        return g
    }

    static func compass() -> DoodleGlyph {
        var g = DoodleGlyph("compass", 0.1, 0.3, tilt: 26)
        g.noFlip = true
        g.line(.circle(50, 3, 6.5), 0.95)
        g.shape(1, .rrect(45, 7, 10, 8, 2), 0.9)
        g.shape(1, .circle(50, 55, 43), 1.35)
        g.shape(-1, .circle(50, 55, 36), 0.95)
        g.detail(0.12) { g in
            for i in 0..<36 {
                let a = Double(i) / 36 * 2 * .pi
                let long = i % 9 == 0, mid = i % 3 == 0
                let r0 = long ? 28.0 : (mid ? 31.0 : 33.0)
                g.line(.poly([(50 + r0 * cos(a), 55 + r0 * sin(a)), (50 + 35 * cos(a), 55 + 35 * sin(a))]), long ? 0.72 : 0.42)
            }
        }
        // North, written by hand.
        g.line("^46,33 ^46,25 ^53.5,33 ^53.5,25", 0.8)
        // The rose, then a needle set a little east of north.
        g.shape(0, "^50,36 ^54,51 ^69,55 ^54,59 ^50,74 ^46,59 ^31,55 ^46,51 z", 0.65)
        g.shape(2, "^66,27 ^53.5,53 ^46.5,57 z", 0.85)
        g.shape(-1, "^34,83 ^46.5,57 ^53.5,53 z", 0.85)
        g.blot(.circle(50, 55, 2))
        g.detail(0.14) {
            $0.gel("23,40 29,29 39,23", 0.9)
            $0.hatch("^72,66 ^82,50 ^88,50 ^84,72 ^68,90 ^56,94 ^60,88 z", angle: 55, gap: 2.8, w: 0.5)
        }
        return g
    }
}
