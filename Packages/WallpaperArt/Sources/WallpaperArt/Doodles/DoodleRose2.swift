// The Rose drawings redrawn after review, and the wider cast around them.

import CoreGraphics
import Foundation

nonisolated extension DoodleRose {
    static func butterfly() -> DoodleGlyph {
        var g = DoodleGlyph("butterfly", 0.24, 0.44, tilt: 30)
        g.must = true
        g.mirror(60) { g in
            // The hind wing goes under the fore wing, its hem in even scallops.
            let hind: [DoodlePath.Node] = [.init(x: 58, y: 50, corner: true), .init(x: 42, y: 47, corner: false), .init(x: 26, y: 52, corner: false), .init(x: 14, y: 62, corner: true)]
                + DoodlePath.scallops((14, 62), (24, 92), n: 3, depth: -3.6) + DoodlePath.scallops((24, 92), (46, 92), n: 2, depth: -3.4)
                + [.init(x: 52, y: 78, corner: false), .init(x: 57, y: 62, corner: true)]
            g.shape(2, DoodlePath(nodes: hind, closed: true), 1.2)
            g.shape(-1, "^55,56 44,53 31,57 24,66 25,77 34,84 45,78 ^54,62 z", 0.7)
            g.detail(0.2) { g in
                g.line("^55,58 46,60 ^40,62", 0.42)
                g.line("^56,62 50,70 ^46,76", 0.42)
            }
            // The eyespot, ringed.
            g.shape(1, .circle(34, 69, 7), 0.75)
            g.shape(0, .circle(34, 69, 4.4), 0.6)
            g.blot(.circle(34, 69, 2.4))
            g.gel("^33,67.8 ^33.6,67.4", 0.5)
            // The fore wing: a clean leading edge, a scalloped outer one.
            let fore: [DoodlePath.Node] = [.init(x: 58, y: 44, corner: true), .init(x: 46, y: 28, corner: false), .init(x: 28, y: 12, corner: false), .init(x: 8, y: 5, corner: false), .init(x: -7, y: 7, corner: true)]
                + DoodlePath.scallops((-7, 7), (1, 46), n: 4, depth: -3.2)
                + [.init(x: 16, y: 53, corner: false), .init(x: 34, y: 55, corner: false), .init(x: 56, y: 50, corner: true)]
            g.shape(0, DoodlePath(nodes: fore, closed: true), 1.3)
            g.shape(-1, "^54,44 42,31 26,20 12,16 ^4,18 ^4,26 ^7,33 ^10,40 18,44 34,47 ^53,47 z", 0.7)
            g.detail(0.2) { g in
                g.line("^54,44 36,28 ^20,20", 0.45)
                g.line("^54,45 32,34 ^12,27", 0.45)
                g.line("^54,46 28,40 ^12,36", 0.45)
                g.line("^54,47 34,46 ^20,44", 0.45)
            }
            g.shape(2, "^34,24 26,24 18,28 18,36 26,37 z", 0.7)
            for (x, y) in [(-1.0, 13.0), (-1.0, 24.0), (10.0, 10.0), (2.0, 35.0)] { g.blot(.circle(x, y, 1.5)) }
            // Antenna with its club.
            g.line("59,31 52,16 46,7 ^40,3", 0.75)
            g.blot(.ellipse(39, 2.4, 2.2, 1.6, rot: 30))
        }
        // A slim body: head, thorax, a tapered abdomen.
        g.shape(1, DoodlePath.taper([(60, 50), (60, 66), (60, 84)], 5.4, 1.4), 1)
        g.detail(0.2) { g in
            for y in [56.0, 61.0, 66.0, 71.0, 76.0] { g.line("^\(58),\(y) ^\(62),\(y)", 0.42) }
        }
        g.shape(1, .ellipse(60, 42, 3.8, 9), 1.1)
        g.blot(.circle(60, 31.5, 2.6))
        return g
    }

    static func heel() -> DoodleGlyph {
        var g = DoodleGlyph("heel", 0.14, 0.34, tilt: 20)
        g.fixed = true
        // The stiletto, tapering to almost nothing.
        g.shape(2, "^8,30 ^24,36 16,56 ^14,90 ^8,90 8,60 z", 1.1)
        g.accent("^7.4,86 ^14.2,86 ^14,90.5 ^8,90.5 z")
        // The far rim of the opening, then the dark inside.
        g.shape(0, "^12,4 34,8 54,24 ^70,44 50,36 30,22 z", 1)
        g.accent("^16,7.4 33,11 50,25 ^64,41 50,33 30,19.6 z")
        // The shoe: heel counter, the low topline, the vamp, a round toe box, the arch.
        g.shape(0, "^12,4 30,20 50,34 ^70,44 86,50 102,56 113,63 118,70 ^114,76 ^86,76 68,68 46,52 28,40 ^10,36 6,20 z", 1.35)
        g.shade("^114,76 ^86,76 68,68 ^50,56 70,62 92,67 ^116,72 z")
        g.line("^86,76 ^114,76", 0.8)
        // A small bow on the vamp.
        g.shape(1, "^72,46 62,37 56,42 60,50 ^72,49 z", 0.9)
        g.shape(1, "^74,46 84,38 90,44 86,52 ^74,50 z", 0.9)
        g.shape(1, .ellipse(73, 47.5, 3.4, 3.8), 0.85)
        g.detail(0.16) { g in
            g.line("^14,12 30,27 ^46,38", 0.45)
            g.gel("92,59 102,62", 0.7)
            g.stitch("^12,28 ^28,36", dash: 2, gap: 1.8, w: 0.42)
        }
        return g
    }

    static func tulip() -> DoodleGlyph {
        var g = DoodleGlyph("tulip", 0.12, 0.3, tilt: 20)
        g.fixed = true
        g.recolor = true
        // Stem and two long blades.
        g.line("^41,66 ^39,140", 1.25)
        g.line("^43,70 ^41,132", 0.5)
        g.shape(1, "^40,132 24,112 10,84 ^6,62 22,76 34,100 ^42,122 z", 1.05)
        g.shape(1, "^40,132 54,116 68,100 ^80,76 72,108 ^46,136 z", 1.05)
        g.detail(0.14) { g in
            g.line("^38,126 22,96 ^12,74", 0.45)
            g.line("^46,128 62,110 ^74,88", 0.45)
        }
        // Three clear petals: the middle one behind, a point in the middle.
        g.shape(0, "^40,0 52,18 56,40 50,62 40,70 30,62 24,40 28,18 z", 1.1)
        g.line("^40,8 ^40,30", 0.45)
        g.shape(0, "^10,8 26,20 37,42 42,70 30,72 14,60 5,36 z", 1.3)
        g.shape(0, "^70,8 75,36 66,60 50,72 38,70 43,42 54,20 z", 1.3)
        g.shade("^70,8 75,36 66,60 50,72 ^58,54 66,32 z")
        g.detail(0.14) { g in
            g.line("^16,24 24,44 ^32,62", 0.45)
            g.line("^11,32 16,48 ^24,60", 0.42)
            g.line("^62,26 56,44 ^48,62", 0.45)
        }
        return g
    }

    static func feather() -> DoodleGlyph {
        var g = DoodleGlyph("feather", 0.08, 0.3, tilt: 44)
        g.fixed = true
        g.recolor = true
        // One outline, with two clean splits in the vane.
        g.shape(0, "^64,4 70,20 72,38 ^66,50 ^54,50 66,56 62,70 ^54,80 ^40,74 50,84 40,94 24,100 ^14,98 12,84 14,68 ^22,58 ^30,60 20,46 26,30 38,16 z", 1.15)
        // The quill runs through it and out.
        g.line("^2,128 12,102 26,68 44,34 ^64,4", 1.05)
        g.line("^4,127 ^12,103", 1.3)
        g.detail(0.12) { g in
            for (a, b, c, d) in [(50.0, 25.0, 66.0, 18.0), (45.0, 33.0, 68.0, 32.0), (41.0, 40.0, 64.0, 44.0), (34.0, 52.0, 58.0, 62.0), (30.0, 60.0, 54.0, 70.0), (24.0, 70.0, 44.0, 84.0), (20.0, 80.0, 34.0, 92.0)] {
                g.line(.poly([(a, b), (c, d)]), 0.42)
            }
            for (a, b, c, d) in [(43.0, 34.0, 30.0, 28.0), (38.0, 43.0, 25.0, 40.0), (21.0, 76.0, 16.0, 72.0), (18.0, 84.0, 15.0, 84.0)] {
                g.line(.poly([(a, b), (c, d)]), 0.42)
            }
        }
        return g
    }

    // MARK: The wider cast

    static func bee() -> DoodleGlyph {
        var g = DoodleGlyph("bee", 0.05, 0.11, tilt: 40)
        g.shape(-1, "^30,24 22,6 30,-2 40,6 ^38,24 z", 0.85)
        g.shape(-1, "^38,24 46,4 58,0 62,10 ^44,28 z", 0.85)
        g.shape(2, "10,36 20,24 38,22 54,26 62,36 54,46 38,50 20,48 z", 1.1)
        g.accent("^26,23.6 ^34,22.2 ^34,49.6 ^26,49 z")
        g.accent("^42,23 ^50,24.8 ^50,47 ^42,49 z")
        g.line("^10,36 ^2,36", 1.1)
        g.line("^60,30 ^68,22", 0.7)
        g.line("^62,34 ^72,30", 0.7)
        g.detail(0.07) { $0.stitch("^-14,20 -6,30 ^-14,42", dash: 2.5, gap: 3, w: 0.6) }
        return g
    }

    static func macaron() -> DoodleGlyph {
        var g = DoodleGlyph("macaron", 0.07, 0.15, tilt: 24)
        g.recolor = true
        // Bottom shell, filling, top shell: both shells low, each with its ruffled foot.
        g.shape(0, "4,58 8,52 50,50 92,52 96,58 90,68 50,70 10,68 z", 1.2)
        let foot: [DoodlePath.Node] = [.init(x: 6, y: 42, corner: true)] + DoodlePath.scallops((6, 42), (94, 42), n: 1, depth: 0)
            + DoodlePath.scallops((94, 42), (6, 42), n: 13, depth: 3)
        g.shape(0, DoodlePath(nodes: foot, closed: true), 0.85)
        g.shape(2, "^8,44 28,41 50,47 72,41 ^92,44 92,50 72,48 50,52 28,48 ^8,50 z", 0.9)
        g.shape(0, "4,38 10,22 30,14 70,14 90,22 96,38 88,43 50,44 12,43 z", 1.25)
        g.detail(0.09) { g in
            g.gel("18,28 26,20 40,17.5", 0.9)
            g.shade("^60,60 ^92,56 ^90,66 ^50,69 z")
        }
        return g
    }

    static func hairClip() -> DoodleGlyph {
        var g = DoodleGlyph("hairClip", 0.07, 0.16, tilt: 40)
        g.line("^10,60 ^108,44", 1)
        g.shape(2, "4,56 16,46 60,40 104,34 116,40 110,48 62,56 16,66 z", 1.15)
        g.detail(0.09) { g in
            g.gel("^20,52 ^60,46", 0.7)
        }
        roseHead(&g, cx: 46, cy: 30, r: 24, w: 0.9)
        leafShape(&g, tipX: 88, tipY: 18, baseX: 66, baseY: 32, fat: 0.3, w: 0.85)
        return g
    }

    static func comb() -> DoodleGlyph {
        var g = DoodleGlyph("comb", 0.08, 0.17, tilt: 44)
        // Back first, teeth hanging from it.
        var teeth: [DoodlePath.Node] = [.init(x: 2, y: 26, corner: true)]
        for i in 0..<13 {
            let x = 2 + Double(i) * 8
            teeth.append(.init(x: x + 1.5, y: 60, corner: true))
            teeth.append(.init(x: x + 5, y: 60, corner: true))
            teeth.append(.init(x: x + 6, y: 28, corner: true))
            teeth.append(.init(x: x + 8, y: 28, corner: true))
        }
        teeth.append(.init(x: 106, y: 26, corner: true))
        g.shape(2, DoodlePath(nodes: teeth, closed: true), 0.85)
        g.shape(2, "^2,28 8,10 30,2 54,0 78,2 100,10 ^106,28 z", 1.25)
        g.blot(DoodleFillers.heartPath(54, 16, 6))
        g.detail(0.1) { g in
            g.gel("^22,12 ^36,8", 0.8)
            g.blot(.circle(32, 18, 1.4))
            g.blot(.circle(76, 18, 1.4))
        }
        return g
    }

    static func nailPolish() -> DoodleGlyph {
        var g = DoodleGlyph("nailPolish", 0.08, 0.17, tilt: 20)
        g.whole = true
        g.shape(2, "^22,0 ^40,0 ^42,36 ^20,36 z", 1.15)
        g.detail(0.1) { g in
            g.line("^27,3 ^27,34", 0.45)
            g.line("^34,3 ^34,34", 0.45)
        }
        g.shape(-1, .rrect(18, 34, 26, 9, 2), 1)
        g.shape(0, "^14,42 ^48,42 58,54 60,76 54,92 ^8,92 2,76 4,54 z", 1.25)
        g.gel("^12,54 ^10,80", 1.05)
        g.shade("^46,48 ^56,56 58,76 52,90 ^44,90 50,74 z")
        g.line("^8,84 ^54,84", 0.45)
        return g
    }

    static func earring() -> DoodleGlyph {
        var g = DoodleGlyph("earring", 0.06, 0.13, tilt: 22)
        g.line("^30,16 34,4 26,-6 16,0 ^16,10", 1)
        g.shape(2, .circle(30, 22, 7), 1)
        g.line("^30,29 ^30,36", 0.9)
        g.shape(2, "^30,36 ^48,50 ^30,88 ^12,50 z", 1.2)
        g.shape(0, "^30,44 ^40,52 ^30,74 ^20,52 z", 0.8)
        g.line("^12,50 ^48,50", 0.5)
        g.blot(.circle(30, 94, 2.4))
        return g
    }

    static func compact() -> DoodleGlyph {
        var g = DoodleGlyph("compact", 0.1, 0.22, tilt: 24)
        // Hinged open: the mirror lid up, the powder pan below.
        g.shape(2, .ellipse(50, 34, 44, 34), 1.25)
        g.shape(-1, .ellipse(50, 34, 36, 27), 0.85)
        g.detail(0.12) { g in
            g.gel("^28,20 ^42,40", 0.9)
            g.gel("^38,16 ^52,34", 0.6)
        }
        g.shape(2, "^38,64 ^62,64 ^64,72 ^36,72 z", 0.9)
        g.shape(2, "4,92 12,76 50,70 88,76 96,92 88,106 50,112 12,106 z", 1.25)
        g.shape(0, "12,90 20,80 50,76 80,80 88,90 80,100 50,104 20,100 z", 0.85)
        g.tint(-1, "^40,84 50,82 60,84 64,90 56,96 44,96 36,90 z")
        g.line("^40,84 50,82 60,84 64,90 56,96 44,96 36,90 z", 0.4)
        g.detail(0.12) { g in
            g.blot(DoodleFillers.sparklePath(104, 12, 7, 0.18))
        }
        return g
    }

    static func roseKey() -> DoodleGlyph {
        var g = DoodleGlyph("roseKey", 0.08, 0.18, tilt: 50)
        g.shape(2, "^34,24 ^94,24 ^94,32 ^34,32 z", 1.05)
        g.shape(2, "^78,32 ^84,32 ^84,44 ^78,44 z", 0.9)
        g.shape(2, "^88,32 ^94,32 ^94,50 ^88,50 z", 0.9)
        // A bow in the shape of a heart.
        g.band(0, outer: DoodleFillers.heartPath(20, 30, 22).rotated(90, about: (20, 30)), inner: DoodleFillers.heartPath(21, 30, 12).rotated(90, about: (21, 30)), 1.15)
        g.shape(2, "^40,20 ^46,20 ^46,36 ^40,36 z", 0.9)
        g.line("^56,24 ^56,32", 0.45)
        g.line("^62,24 ^62,32", 0.45)
        return g
    }

    static func candle() -> DoodleGlyph {
        var g = DoodleGlyph("candle", 0.1, 0.22, tilt: 10)
        // A flame, the wick, a pillar with wax running.
        g.shape(2, "^30,0 40,14 40,24 30,32 20,24 20,14 z", 1.05)
        g.shape(-1, "^30,12 34,20 30,28 26,20 z", 0.6)
        g.line("^30,30 ^30,38", 1)
        g.shape(-1, "^14,38 22,42 30,40 38,44 ^46,38 ^46,110 ^14,110 z", 1.2)
        g.tint(0, "^14,38 22,42 30,40 38,44 ^46,38 ^46,50 42,62 38,50 32,52 26,74 20,50 ^14,48 z")
        g.line("^14,48 20,50 26,74 32,52 38,50 42,62 ^46,50", 0.65)
        g.shade("^38,70 ^46,70 ^46,110 ^38,110 z")
        // A saucer with a ring handle.
        g.shape(2, "^0,108 ^60,108 54,120 ^6,120 z", 1.2)
        g.line(.circle(66, 112, 7), 0.95)
        return g
    }

    static func fan() -> DoodleGlyph {
        var g = DoodleGlyph("fan", 0.12, 0.26, tilt: 22)
        g.fixed = true
        g.recolor = true
        // A folding fan: ribs fan out from the pin.
        let n = 9
        var outer: [(Double, Double)] = [], inner: [(Double, Double)] = []
        for i in 0...n {
            let a = (200 + 140 * Double(i) / Double(n)) * .pi / 180
            outer.append((70 + 70 * cos(a), 76 + 70 * sin(a)))
            inner.append((70 + 26 * cos(a), 76 + 26 * sin(a)))
        }
        var nodes: [DoodlePath.Node] = []
        for (i, p) in outer.enumerated() {
            nodes.append(.init(x: p.0, y: p.1, corner: true))
            if i < n {
                let a = (200 + 140 * (Double(i) + 0.5) / Double(n)) * .pi / 180
                nodes.append(.init(x: 70 + 74 * cos(a), y: 76 + 74 * sin(a), corner: false))
            }
        }
        for p in inner.reversed() { nodes.append(.init(x: p.0, y: p.1, corner: true)) }
        g.shape(0, DoodlePath(nodes: nodes, closed: true), 1.25)
        for i in 0...n {
            g.line(.poly([inner[i], outer[i]]), i % 2 == 0 ? 0.65 : 0.45)
        }
        // A band of flowers along the top.
        g.detail(0.14) { g in
            for i in stride(from: 1, to: n, by: 2) {
                let a = (200 + 140 * (Double(i) + 0.5) / Double(n)) * .pi / 180
                g.blot(DoodleFillers.heartPath(70 + 54 * cos(a), 76 + 54 * sin(a), 3.2))
            }
        }
        // The sticks and the pin.
        for i in 0...n {
            g.line(.poly([inner[i], (70, 76)]), 0.8)
        }
        g.shape(2, .circle(70, 76, 4.6), 1)
        g.line("^70,81 66,92 72,98 ^68,106", 0.75)
        g.blot(.circle(68, 108, 2.2))
        return g
    }

    static func starFlower() -> DoodleGlyph {
        var g = DoodleGlyph("starFlower", 0.04, 0.09, tilt: 40)
        g.recolor = true
        for i in 0..<5 {
            let a = Double(i) / 5 * 360 - 90
            let petal: DoodlePath = "^30,30 20,20 20,8 ^30,0 40,8 40,20 z"
            g.shape(0, petal.rotated(a + 90, about: (30, 30)), 0.95)
        }
        g.shape(2, .circle(30, 30, 6), 0.8)
        g.blot(.circle(30, 30, 1.6))
        return g
    }

    static func drop() -> DoodleGlyph {
        var g = DoodleGlyph("drop", 0.02, 0.05, tilt: 40)
        g.shape(0, "^20,0 34,26 34,38 20,50 6,38 6,26 z", 0.9)
        g.gel("12,32 13,38", 0.6)
        return g
    }

    static func brush() -> DoodleGlyph {
        var g = DoodleGlyph("brush", 0.09, 0.2, tilt: 50)
        // A soft powder brush.
        g.shape(2, "^16,68 ^44,68 ^40,142 34,148 26,148 ^20,142 z", 1.15)
        g.shape(-1, "^14,54 ^46,54 ^44,70 ^16,70 z", 1.05)
        g.line("^15,60 ^45,60", 0.45)
        g.shape(0, "^14,56 4,38 8,16 30,0 52,16 56,38 ^46,56 z", 1.25)
        g.detail(0.1) { g in
            g.line("^22,52 18,32 ^24,12", 0.42)
            g.line("^30,52 ^30,8", 0.42)
            g.line("^38,52 42,32 ^36,12", 0.42)
        }
        g.gel("^26,100 ^26,134", 0.8)
        return g
    }

    static func hatbox() -> DoodleGlyph {
        var g = DoodleGlyph("hatbox", 0.12, 0.25, tilt: 12)
        g.whole = true
        g.fixed = true
        g.recolor = true
        g.shape(0, "^4,34 ^100,34 ^100,92 92,98 52,102 12,98 ^4,92 z", 1.3)
        // Stripes round the box.
        for x in stride(from: 12.0, through: 84.0, by: 18) {
            g.tint(-1, .poly([(x, 40), (x + 8, 40), (x + 8, 99 + (x > 50 ? -1 : 1)), (x, 99)], closed: true))
        }
        g.shape(2, .ellipse(52, 26, 54, 16), 1.3)
        g.shape(2, "^-2,26 2,38 20,44 52,46 84,44 102,38 ^106,26 84,36 52,38 20,36 z", 0.9)
        // The ribbon, crossing and tied on top.
        g.tint(1, "^44,44 ^60,44 ^60,102 ^44,102 z")
        g.line("^44,44 ^44,102", 0.8)
        g.line("^60,44 ^60,102", 0.8)
        g.shape(1, "^52,20 36,6 24,12 28,24 ^52,24 z", 1)
        g.shape(1, "^52,20 68,6 80,12 76,24 ^52,24 z", 1)
        g.shape(1, .ellipse(52, 22, 5, 4.4), 0.9)
        g.detail(0.14) { $0.shade("^80,40 ^100,36 ^100,92 92,98 ^80,100 z") }
        return g
    }

    static func spool() -> DoodleGlyph {
        var g = DoodleGlyph("spool", 0.07, 0.15, tilt: 30)
        g.recolor = true
        g.shape(2, "^6,0 ^62,0 ^62,10 ^6,10 z", 1.15)
        g.shape(2, "^6,70 ^62,70 ^62,80 ^6,80 z", 1.15)
        g.shape(0, "^12,10 ^56,10 ^56,70 ^12,70 z", 1.1)
        g.detail(0.09) { g in
            for y in stride(from: 16.0, through: 64.0, by: 7) { g.line("^13,\(y + 2) ^55,\(y)", 0.45) }
            g.shade("^44,11 ^55,11 ^55,69 ^44,69 z")
        }
        // A thread running away, with a needle.
        g.line("^56,40 72,44 78,62 ^94,70", 0.7)
        g.line("^88,48 ^104,84", 1)
        g.line("^89,52 ^91,56", 0.42)
        return g
    }

    static func scissors() -> DoodleGlyph {
        var g = DoodleGlyph("scissors", 0.09, 0.19, tilt: 60)
        g.shape(-1, "^36,62 ^58,0 ^60,6 ^46,70 z", 1)
        g.shape(-1, "^52,62 ^26,0 ^24,6 ^42,70 z", 1)
        g.band(2, outer: .ellipse(26, 90, 17, 21, rot: 14), inner: .ellipse(26, 90, 8, 12, rot: 14), 1.1)
        g.band(2, outer: .ellipse(62, 90, 17, 21, rot: -14), inner: .ellipse(62, 90, 8, 12, rot: -14), 1.1)
        g.blot(.circle(44, 60, 2.4))
        return g
    }

    static func songbird() -> DoodleGlyph {
        var g = DoodleGlyph("songbird", 0.09, 0.2, tilt: 14)
        g.whole = true
        g.fixed = true
        g.recolor = true
        // On a sprig, singing.
        g.line("^0,76 30,70 60,74 ^104,62", 1.1)
        leafShape(&g, tipX: 112, tipY: 44, baseX: 90, baseY: 66, fat: 0.3, w: 0.85)
        leafShape(&g, tipX: -8, tipY: 60, baseX: 14, baseY: 74, fat: 0.3, w: 0.85)
        // Tail, then the round body and head.
        g.shape(2, "^26,52 ^0,44 ^2,54 ^24,64 z", 1)
        g.shape(0, "22,54 30,36 44,26 52,12 64,6 76,12 ^86,18 ^76,22 76,30 72,48 58,64 40,68 26,64 z", 1.3)
        g.tint(2, "76,30 72,48 58,64 46,66 54,52 60,36 ^66,24 ^76,26 z")
        g.accent("^76,12 ^86,18 ^76,22 z")
        g.shape(1, "^34,40 48,36 58,44 50,54 ^26,60 z", 1)
        g.detail(0.11) { g in
            g.line("^38,44 ^50,42", 0.42)
            g.line("^36,50 ^48,48", 0.42)
        }
        g.blot(.circle(68, 14, 2))
        g.line("^46,68 ^46,74", 0.8)
        g.line("^56,64 ^56,72", 0.8)
        g.detail(0.12) { g in
            g.line("^92,6 96,2 ^100,6", 0.6)
            g.blot(.ellipse(96, 8, 1.6, 1.2))
        }
        return g
    }

    static func peach() -> DoodleGlyph {
        var g = DoodleGlyph("peach", 0.08, 0.17, tilt: 24)
        g.fixed = true
        g.line("^46,14 ^50,0", 1.05)
        leafShape(&g, tipX: 88, tipY: 2, baseX: 50, baseY: 12, fat: 0.26, w: 0.95)
        g.shape(0, "48,16 62,12 80,20 88,40 84,62 66,80 46,84 26,80 8,62 4,40 12,20 32,12 z", 1.3)
        g.tint(2, "^50,20 54,44 ^48,80 26,78 10,60 6,40 14,22 32,14 z")
        g.line("^48,16 56,40 52,60 ^46,82", 0.65)
        g.detail(0.1) { g in
            g.gel("18,34 24,24 34,20", 0.9)
            for (x, y) in [(70.0, 36.0), (74.0, 46.0), (66.0, 56.0)] { g.line("^\(x),\(y) ^\(x - 2.4),\(y + 2.4)", 0.42) }
        }
        return g
    }

    static func stamp() -> DoodleGlyph {
        var g = DoodleGlyph("stamp", 0.07, 0.15, tilt: 26)
        g.noFlip = true
        // Perforated edge.
        var nodes: [DoodlePath.Node] = []
        func edge(_ a: (Double, Double), _ b: (Double, Double), _ n: Int) {
            nodes += DoodlePath.scallops(a, b, n: n, depth: -2)
        }
        nodes.append(.init(x: 0, y: 0, corner: true))
        edge((0, 0), (66, 0), 8)
        edge((66, 0), (66, 82), 10)
        edge((66, 82), (0, 82), 8)
        edge((0, 82), (0, 0), 10)
        g.shape(-1, DoodlePath(nodes: nodes, closed: true), 1)
        g.shape(0, .rrect(8, 9, 50, 64, 2), 0.85)
        g.tint(1, "^8,50 22,44 40,52 ^58,46 ^58,71 ^8,71 z")
        g.blot(DoodleFillers.heartPath(33, 30, 11))
        g.line("^8,50 22,44 40,52 ^58,46", 0.5)
        return g
    }

    static func ringBox() -> DoodleGlyph {
        var g = DoodleGlyph("ringBox", 0.09, 0.19, tilt: 18)
        g.whole = true
        g.fixed = true
        // Lid thrown back, silk inside, a ring standing in the cushion.
        g.shape(0, "^6,8 ^94,8 ^88,44 ^12,44 z", 1.2)
        g.shape(-1, "^14,14 ^86,14 ^82,40 ^18,40 z", 0.75)
        g.shape(0, "^4,50 ^96,50 ^96,96 ^4,96 z", 1.3)
        g.shape(-1, "^10,50 ^90,50 ^86,68 ^14,68 z", 0.8)
        g.accent("^40,50 ^60,50 ^58,57 ^42,57 z")
        g.band(2, outer: .circle(50, 44, 13), inner: .circle(50, 44, 9), 0.95)
        g.shape(1, "^44,27 ^56,27 ^60,20 ^50,6 ^40,20 z", 1)
        g.line("^40,20 ^60,20", 0.5)
        g.line("^46,27 ^44,20 ^50,6 ^56,20 ^54,27", 0.42)
        g.accent("^44,44 ^56,44 ^54,50 ^46,50 z")
        g.shape(2, "^44,72 ^56,72 ^56,82 ^44,82 z", 0.8)
        g.detail(0.12) { g in
            g.shade("^78,70 ^96,70 ^96,96 ^78,96 z")
        }
        return g
    }

    static func pansy() -> DoodleGlyph {
        var g = DoodleGlyph("pansy", 0.07, 0.17, tilt: 40)
        g.recolor = true
        // Two big petals behind, two at the sides, one broad one in front.
        g.shape(0, "^50,50 38,42 22,30 22,12 38,4 50,12 z", 1.1)
        g.shape(0, "^50,50 62,42 78,30 78,12 62,4 50,12 z", 1.1)
        g.shape(2, "^50,50 30,42 12,44 4,56 12,68 34,66 z", 1.1)
        g.shape(2, "^50,50 70,42 88,44 96,56 88,68 66,66 z", 1.1)
        g.shape(0, "^50,48 34,58 22,72 28,90 50,98 72,90 78,72 66,58 z", 1.25)
        g.detail(0.1) { g in
            for (a, b, c, d) in [(50.0, 64.0, 50.0, 84.0), (45.0, 62.0, 36.0, 80.0), (55.0, 62.0, 64.0, 80.0), (42.0, 58.0, 30.0, 72.0), (58.0, 58.0, 70.0, 72.0)] {
                g.line(.poly([(a, b), (c, d)]), 0.5)
            }
            g.line("^42,34 ^34,20", 0.42)
            g.line("^58,34 ^66,20", 0.42)
        }
        g.shape(1, .circle(50, 54, 5.4), 0.85)
        g.blot(.circle(50, 54, 2))
        return g
    }

    static func shell() -> DoodleGlyph {
        var g = DoodleGlyph("shell", 0.07, 0.15, tilt: 34)
        g.recolor = true
        // A scallop: a fan of ribs from the hinge, the edge rippling over them.
        let n = 9
        func rim(_ t: Double, _ r: Double) -> (Double, Double) {
            let a = (205 + 130 * t) * .pi / 180
            return (50 + r * cos(a), 84 + r * sin(a))
        }
        var nodes: [DoodlePath.Node] = [.init(x: 50, y: 84, corner: true)]
        for i in 0..<n {
            let p0 = rim(Double(i) / Double(n), 72), pm = rim((Double(i) + 0.5) / Double(n), 77)
            nodes.append(.init(x: p0.0, y: p0.1, corner: true))
            nodes.append(.init(x: pm.0, y: pm.1, corner: false))
        }
        let last = rim(1, 72)
        nodes.append(.init(x: last.0, y: last.1, corner: true))
        g.shape(0, DoodlePath(nodes: nodes, closed: true), 1.2)
        for i in 1..<n {
            let p = rim(Double(i) / Double(n), 72)
            g.line(.poly([(50, 80), p]), 0.55)
        }
        g.detail(0.1) { g in
            g.line(.spline((0...8).map { rim(Double($0) / 8, 54) }), 0.4)
            g.line(.spline((0...8).map { rim(Double($0) / 8, 36) }), 0.4)
        }
        g.shape(2, "^38,82 ^62,82 ^66,94 ^34,94 z", 1)
        return g
    }

    static func threeDots() -> DoodleGlyph {
        var g = DoodleGlyph("sprinkle", 0.025, 0.055, tilt: 90)
        g.line("^0,12 ^10,4", 1.3)
        g.line("^20,22 ^30,28", 1.3)
        g.line("^26,4 ^30,12", 1.3)
        return g
    }

    static func tinyLeaf() -> DoodleGlyph {
        var g = DoodleGlyph("tinyLeaf", 0.03, 0.07, tilt: 90)
        leafShape(&g, tipX: 56, tipY: 6, baseX: 8, baseY: 40, fat: 0.34, w: 1)
        return g
    }
}
