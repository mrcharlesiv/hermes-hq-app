// The Gaming drawings redrawn after review, and the wider cast around them.

import CoreGraphics
import Foundation

nonisolated extension DoodleGaming {
    static func phones() -> DoodleGlyph {
        var g = DoodleGlyph("phones", 0.24, 0.42, tilt: 24)
        g.must = true
        g.fixed = true
        // Cable from the right cup: a curl, a jack.
        g.line("86,104 90,114 82,124 68,122 64,114 72,109 80,116 88,128 104,132", 1)
        g.shape(1, "^103,128 ^114,132 ^112,138 ^101,134 z", 0.85)
        g.line("^113,132 ^120,135", 0.9)
        // Boom mic behind the left cup.
        g.line("8,96 2,110 12,122 30,123", 1.25)
        g.line("10,100 6,110 14,118 30,119", 0.5)
        g.shape(2, .ellipse(36, 121, 8, 5.2, rot: -4), 0.95)
        g.detail(0.22) { g in
            g.line("^33,117.5 ^33,124.5", 0.45)
            g.line("^37,117 ^37,125", 0.45)
            g.line("^41,118 ^41,124", 0.45)
        }
        // Headband: outer and inner edge, one closed shape.
        g.shape(0, "^10,62 8,36 22,14 50,3 78,14 92,36 ^90,62 ^81,62 81,38 69,22 50,14 31,22 19,38 ^19,62 z", 1.2)
        g.detail(0.22) { $0.stitch("14,44 25,23 50,9 75,23 86,44", dash: 3.4, gap: 2.8, w: 0.5) }
        // A thin pad following the band's inside curve.
        g.shape(1, "^28,25 37,18 50,14 63,18 ^72,25 ^69,30 60,23.5 50,20 40,23.5 ^31,30 z", 0.95)
        g.detail(0.22) { g in
            for (a, b, c, d) in [(37.5, 20.0, 40.0, 25.0), (43.5, 17.0, 45.0, 22.0), (50.0, 15.0, 50.0, 20.5), (56.5, 17.0, 55.0, 22.0), (62.5, 20.0, 60.0, 25.0)] {
                g.line(.poly([(a, b), (c, d)]), 0.42)
            }
        }
        // Both cups are the same cup.
        g.mirror(50) { g in
            // Slider.
            g.shape(-1, .rrect(9, 56, 11, 14, 2), 0.9)
            g.line("^11.5,60 ^17.5,60", 0.42)
            g.line("^11.5,64 ^17.5,64", 0.42)
            // Cushion on the inside, shell on the outside.
            g.shape(2, .ellipse(21, 86, 8, 22), 1)
            g.shape(0, .ellipse(13, 86, 13, 24), 1.25)
            g.shape(1, .ellipse(11, 86, 8, 16), 0.9)
            // The back of the cup is a vented plate, not a dark centre: those read as eyes.
            g.detail(0.2) { g in
                g.line(.ellipse(11, 86, 4.6, 10), 0.5)
                for dy in [-5.0, -1.7, 1.7, 5.0] { g.line("^8.8,\(86 + dy) ^13.2,\(86 + dy)", 0.5) }
                g.gel("6,75 8,71 11,70", 0.7)
                g.shade("^3,98 ^12,104 ^22,96 ^20,104 ^12,110 ^5,104 z")
            }
        }
        return g
    }

    static func visor() -> DoodleGlyph {
        var g = DoodleGlyph("visor", 0.14, 0.36, tilt: 18)
        g.whole = true
        g.fixed = true
        // The strap over the head and the side straps with their buckles, behind.
        g.shape(1, "^28,30 34,12 54,3 74,12 ^80,30 ^71,30 66,16 54,10 42,16 ^37,30 z", 1.1)
        g.detail(0.2) { $0.stitch("32,24 38,11 54,6.5 70,11 ^76,24", dash: 2.6, gap: 2.2, w: 0.45) }
        g.shape(1, "^6,36 ^-16,38 ^-16,52 ^6,54 z", 1)
        g.shape(1, "^102,36 ^124,38 ^124,52 ^102,54 z", 1)
        g.detail(0.2) { g in
            g.line("^-9,38 ^-9,52", 0.5)
            g.line("^-5,38 ^-5,52", 0.5)
            g.line("^113,38 ^113,52", 0.5)
            g.line("^117,38 ^117,52", 0.5)
        }
        // Foam round the face, under the housing, with the nose gap in it.
        let foam: [DoodlePath.Node] = [.init(x: 8, y: 58, corner: true), .init(x: 100, y: 58, corner: true), .init(x: 102, y: 66, corner: true)]
            + DoodlePath.scallops((102, 66), (68, 82), n: 5, depth: 3)
            + [.init(x: 54, y: 69, corner: true), .init(x: 40, y: 82, corner: true)]
            + DoodlePath.scallops((40, 82), (6, 66), n: 5, depth: 3)
        g.shape(1, DoodlePath(nodes: foam, closed: true), 1)
        // The housing: a deep rounded box, no lenses to be seen from outside.
        g.shape(2, .rrect(1, 20, 106, 52, 17), 1.35)
        g.shade("^90,23 100,27 106,38 106,56 100,66 ^90,70 96,58 97,36 z")
        // The glossy front panel, with its tracking cameras in the corners.
        g.shape(0, .rrect(9, 27, 88, 38, 12), 1)
        g.gel("17,36 20,32 28,30.5", 0.9)
        for (x, y) in [(20.0, 54.0), (86.0, 54.0), (86.0, 37.0)] {
            g.shape(1, .circle(x, y, 3.8), 0.75)
            g.accent(.circle(x, y, 1.9))
        }
        // A status light and the small mark in the middle.
        g.blot(.circle(53, 34, 1.5))
        g.shape(1, "^53,41 ^56,47 ^62,48 ^58,52 ^59,58 ^53,55 ^47,58 ^48,52 ^44,48 ^50,47 z", 0.7)
        g.detail(0.2) { g in
            g.hatch("^70,29 ^92,29 ^95,50 ^76,62 z", angle: 62, gap: 3.4, w: 0.42)
            // Vents along the underside, a volume rocker on the top edge.
            for x in [30.0, 36.0, 42.0, 66.0, 72.0, 78.0] { g.line("^\(x),67 ^\(x),70", 0.5) }
            g.line("^60,20 ^76,20", 0.9)
        }
        return g
    }

    static func crt() -> DoodleGlyph {
        var g = DoodleGlyph("crt", 0.14, 0.34, tilt: 16)
        g.whole = true
        g.fixed = true
        g.line("^48,22 ^28,3", 0.9)
        g.line("^52,22 ^74,1", 0.9)
        g.blot(.circle(28, 3, 2))
        g.blot(.circle(74, 1, 2))
        g.shape(1, "^38,24 40,18 ^62,18 ^64,24 z", 0.95)
        g.shape(0, .rrect(4, 23, 92, 64, 7), 1.2)
        g.shape(1, "^16,87 ^28,87 ^26,93 ^18,93 z", 0.85)
        g.shape(1, "^72,87 ^84,87 ^82,93 ^74,93 z", 0.85)
        // Curved glass showing a test pattern.
        g.shape(-1, .rrect(10, 29, 62, 52, 10), 0.95)
        let bars: [Int] = [-1, 2, 0, 1, 2, 1]
        for (i, s) in bars.enumerated() {
            let x = 16.0 + Double(i) * 8.4
            g.shape(s, .poly([(x, 36), (x + 8.4, 36), (x + 8.4, 62), (x, 62)], closed: true), 0)
        }
        g.accent("^16,62 ^41,62 ^41,70 ^16,70 z")
        g.shape(-1, "^41,62 ^58,62 ^58,70 ^41,70 z", 0)
        g.accent("^58,62 ^66.4,62 ^66.4,70 ^58,70 z")
        g.line("^16,36 ^66.4,36 ^66.4,74 ^16,74 z", 0.55)
        g.detail(0.2) { g in
            g.gel("15,48 15.5,38", 0.8)
        }
        // Dials and speaker.
        for y in [38.0, 54.0] {
            g.shape(1, .circle(84, y, 6.2), 0.9)
            g.detail(0.16) { $0.line("^84,\(y) ^87,\(y - 4)", 0.7) }
        }
        g.line("^78,68 ^90,68", 0.7)
        g.line("^78,73 ^90,73", 0.7)
        g.line("^78,78 ^90,78", 0.7)
        return g
    }

    // MARK: The wider cast

    static func retroStick() -> DoodleGlyph {
        var g = DoodleGlyph("retroStick", 0.13, 0.28, tilt: 18)
        g.fixed = true
        g.line("82,76 98,82 106,94 100,104 ^84,106", 1)
        g.shape(0, "^12,54 ^72,48 ^94,62 ^30,70 z", 1.15)
        g.shape(1, "^12,54 ^30,70 ^30,94 ^12,78 z", 1.15)
        g.shade("^12,54 ^30,70 ^30,94 ^12,78 z")
        g.shape(2, "^30,70 ^94,62 ^94,86 ^30,94 z", 1.2)
        g.detail(0.16) { g in
            g.line("^36,76 ^88,69.5", 0.45)
            g.line("^36,88 ^88,81.5", 0.45)
            g.blot(.circle(34, 90, 0.9))
            g.blot(.circle(90, 82, 0.9))
        }
        g.shape(1, .ellipse(74, 57, 7, 3.4), 0.9)
        g.shape(-1, .ellipse(50, 59, 12, 5), 0.9)
        g.shape(-1, "^47,12 ^53,12 ^54,59 ^46,59 z", 1)
        g.line("^51,18 ^51.5,54", 0.42)
        g.shape(1, .circle(50, 11, 11.5), 1.2)
        g.gel("43,8 45,4.5 49,3.6", 0.8)
        g.shade("^52,20.5 58,17 61,10 60.5,16 56,21 z")
        return g
    }

    static func arrowKeys() -> DoodleGlyph {
        var g = DoodleGlyph("arrowKeys", 0.11, 0.24, tilt: 24)
        func key(_ g: inout DoodleGlyph, _ x: Double, _ y: Double, _ arrow: DoodlePath, _ sep: Int) {
            g.shape(sep, .rrect(x, y, 34, 34, 6), 1.15)
            g.shape(-1, .rrect(x + 4, y + 3, 26, 24, 5), 0.75)
            g.blot(arrow)
            g.detail(0.14) { g in
                g.line(.poly([(x + 5, y + 31), (x + 29, y + 31)]), 0.45)
            }
        }
        key(&g, 38, 2, "^55,10 ^62,20 ^48,20 z", 2)
        key(&g, 2, 40, "^11,55 ^22,48 ^22,62 z", 0)
        key(&g, 38, 40, "^55,65 ^48,55 ^62,55 z", 1)
        key(&g, 74, 40, "^99,55 ^88,48 ^88,62 z", 0)
        return g
    }

    static func memoryCard() -> DoodleGlyph {
        var g = DoodleGlyph("memoryCard", 0.08, 0.17, tilt: 30)
        g.shape(0, "^4,4 ^52,4 ^68,20 ^68,92 ^4,92 z", 1.2)
        // Contacts along the top.
        for i in 0..<5 {
            let x = 10.0 + Double(i) * 8.2
            g.shape(2, .poly([(x, 8), (x + 5.2, 8), (x + 5.2, 22), (x, 22)], closed: true), 0.55)
        }
        // A sticker with a small sprite.
        g.shape(-1, .rrect(11, 32, 50, 48, 3), 0.9)
        g.pixels(["x.......x", "xx.....xx", "xxxxxxxxx", "xx.xxx.xx", "xxxxxxxxx", "xxx.x.xxx", ".xxxxxxx."], x: 19, y: 37, cell: 3.8, w: 0)
        g.detail(0.1) { g in
            g.line("^17,70 ^54,70", 0.45)
            g.line("^17,75 ^42,75", 0.45)
        }
        return g
    }

    static func usbStick() -> DoodleGlyph {
        var g = DoodleGlyph("usbStick", 0.07, 0.15, tilt: 44)
        g.line("14,70 4,84 12,98 26,96 30,84 ^22,72", 0.8)
        g.shape(-1, "^14,-14 ^38,-14 ^38,12 ^14,12 z", 1)
        g.accent("^19,-8 ^24,-8 ^24,-3 ^19,-3 z")
        g.accent("^28,-8 ^33,-8 ^33,-3 ^28,-3 z")
        g.shape(1, "^8,10 ^44,10 ^46,16 ^46,68 ^38,76 ^14,76 ^6,68 ^6,16 z", 1.2)
        g.shape(0, "^12,30 ^40,30 ^40,58 ^12,58 z", 0.8)
        g.detail(0.09) { g in
            g.blot(DoodleFillers.starPath(26, 44, 8))
            g.line("^12,20 ^40,20", 0.45)
            g.gel("^10,34 ^10,56", 0.6)
        }
        return g
    }

    static func tickets() -> DoodleGlyph {
        var g = DoodleGlyph("tickets", 0.1, 0.22, tilt: 34)
        g.noFlip = false
        // A strip of three, folding as it falls.
        func ticket(_ g: inout DoodleGlyph, _ a: (Double, Double), _ u: (Double, Double), _ v: (Double, Double), _ sep: Int) {
            func p(_ s: Double, _ t: Double) -> (Double, Double) { (a.0 + u.0 * s + v.0 * t, a.1 + u.1 * s + v.1 * t) }
            var nodes: [DoodlePath.Node] = []
            nodes.append(.init(x: p(0, 0).0, y: p(0, 0).1, corner: true))
            nodes.append(.init(x: p(1, 0).0, y: p(1, 0).1, corner: true))
            nodes.append(.init(x: p(1, 0.34).0, y: p(1, 0.34).1, corner: true))
            nodes.append(.init(x: p(0.94, 0.5).0, y: p(0.94, 0.5).1, corner: false))
            nodes.append(.init(x: p(1, 0.66).0, y: p(1, 0.66).1, corner: true))
            nodes.append(.init(x: p(1, 1).0, y: p(1, 1).1, corner: true))
            nodes.append(.init(x: p(0, 1).0, y: p(0, 1).1, corner: true))
            nodes.append(.init(x: p(0, 0.66).0, y: p(0, 0.66).1, corner: true))
            nodes.append(.init(x: p(0.06, 0.5).0, y: p(0.06, 0.5).1, corner: false))
            nodes.append(.init(x: p(0, 0.34).0, y: p(0, 0.34).1, corner: true))
            g.shape(sep, DoodlePath(nodes: nodes, closed: true), 1)
            let c = p(0.5, 0.5)
            g.blot(DoodleFillers.starPath(c.0, c.1, min(hypot(u.0, u.1), hypot(v.0, v.1)) * 0.3))
            g.detail(0.13) { g in
                g.stitch(.poly([p(0.2, 0.08), p(0.2, 0.92)]), dash: 2, gap: 2, w: 0.45)
                g.stitch(.poly([p(0.8, 0.08), p(0.8, 0.92)]), dash: 2, gap: 2, w: 0.45)
            }
        }
        ticket(&g, (52, 44), (40, 20), (-14, 28), 2)
        ticket(&g, (18, 28), (38, 12), (-8, 30), 0)
        ticket(&g, (0, 4), (38, -4), (6, 28), 1)
        return g
    }

    static func oldKey() -> DoodleGlyph {
        var g = DoodleGlyph("oldKey", 0.08, 0.18, tilt: 50)
        g.shape(2, "^36,28 ^84,28 ^84,36 ^36,36 z", 1.05)
        g.shape(2, "^72,36 ^78,36 ^78,50 ^72,50 z", 0.9)
        g.shape(2, "^84,28 ^90,28 ^90,52 ^84,52 z", 0.95)
        g.band(1, outer: "24,8 38,14 42,32 36,50 20,56 6,50 0,32 6,14 z", inner: "21,20 28,24 30,32 27,40 20,44 14,40 11,32 14,24 z", 1.15)
        g.shape(0, "^40,24 ^46,24 ^46,40 ^40,40 z", 0.9)
        g.detail(0.1) { g in
            g.gel("^52,31 ^76,31", 0.6)
        }
        return g
    }

    static func scroll() -> DoodleGlyph {
        var g = DoodleGlyph("scroll", 0.1, 0.22, tilt: 26)
        g.shape(-1, "^22,14 ^84,8 ^86,84 ^24,92 z", 1.15)
        g.shape(2, .rrect(12, 4, 82, 13, 6), 1.15)
        g.shape(2, .rrect(14, 84, 82, 13, 6), 1.15)
        g.blot(.circle(12, 10.5, 1.8))
        g.blot(.circle(96, 90.5, 1.8))
        // A few lines of writing and a seal.
        g.detail(0.12) { g in
            g.line("^33,28 ^74,25", 0.6)
            g.line("^33,35 ^60,33", 0.6)
            g.line("^65,32.6 ^75,32", 0.6)
            g.line("^33,42 ^50,41", 0.6)
            g.line("^55,40.6 ^75,39.4", 0.6)
            g.line("^34,49 ^68,47", 0.6)
        }
        g.shape(1, DoodleFillers.starPath(54, 66, 10), 0.8)
        g.line("^24,92 ^86,84", 0.5)
        return g
    }

    static func crown() -> DoodleGlyph {
        var g = DoodleGlyph("crown", 0.08, 0.18, tilt: 28)
        g.shape(2, "^8,62 ^2,18 ^26,38 ^50,6 ^74,38 ^98,18 ^92,62 z", 1.25)
        g.shape(1, "^8,60 ^92,60 ^90,76 ^10,76 z", 1.1)
        g.shape(0, .circle(2, 16, 5), 0.9)
        g.shape(0, .circle(50, 6, 6), 0.9)
        g.shape(0, .circle(98, 16, 5), 0.9)
        g.blot(DoodleFillers.heartPath(50, 68, 4.4))
        g.shape(-1, "^24,64 ^30,68 ^24,72 ^18,68 z", 0.65)
        g.shape(-1, "^76,64 ^82,68 ^76,72 ^70,68 z", 0.65)
        g.detail(0.1) { g in
            g.shade("^70,40 ^74,38 ^92,26 ^90,58 ^76,58 z")
            g.gel("^14,34 ^17,54", 0.6)
        }
        return g
    }

    static func wizardHat() -> DoodleGlyph {
        var g = DoodleGlyph("wizardHat", 0.1, 0.22, tilt: 22)
        g.shape(1, "2,84 24,74 60,72 96,74 118,84 96,94 60,98 24,94 z", 1.2)
        g.shape(0, "^26,80 36,50 46,28 58,14 74,6 88,10 ^92,18 80,18 72,28 74,50 ^92,80 60,86 z", 1.25)
        g.shape(2, "^26,80 ^92,80 ^86,66 60,72 ^32,66 z", 1)
        g.shape(1, .rrect(52, 66, 14, 13, 2), 0.8)
        g.line(.rrect(55.5, 69.5, 7, 6, 1), 0.5)
        g.blot(DoodleFillers.starPath(58, 40, 6))
        g.blot(DoodleFillers.sparklePath(44, 56, 4.5))
        g.detail(0.12) { g in
            g.blot(DoodleFillers.sparklePath(70, 50, 4))
            g.blot(.circle(74, 15, 1.5))
            g.shade("^74,50 ^92,80 ^74,84 ^62,50 ^66,26 ^72,28 z")
            g.line("^14,84 40,91 ^70,92", 0.45)
        }
        return g
    }

    static func rocket() -> DoodleGlyph {
        var g = DoodleGlyph("rocket", 0.1, 0.24, tilt: 40)
        g.fixed = true
        // Flame out of the tail.
        g.shape(1, "^28,104 ^52,104 50,118 44,128 ^40,138 ^35,126 30,118 z", 0.95)
        g.shape(-1, "^34,104 ^46,104 44,114 ^40,122 36,114 z", 0.6)
        // Fins behind the body.
        g.shape(1, "^22,70 ^4,92 ^6,108 ^24,96 z", 1.1)
        g.shape(1, "^58,70 ^76,92 ^74,108 ^56,96 z", 1.1)
        g.shape(0, "40,0 52,12 60,36 62,60 58,84 ^54,102 ^26,102 ^22,84 18,60 20,36 28,12 z", 1.25)
        // Nose and bands.
        g.shape(1, "40,0 52,12 ^57,26 ^23,26 28,12 z", 1.05)
        g.line("^21,88 ^59,88", 0.65)
        g.shape(2, .circle(40, 48, 11), 1.1)
        g.line(.circle(40, 48, 8), 0.5)
        g.gel("35,45 37,42 40,41", 0.7)
        g.shade("^50,28 ^57,28 62,60 ^56,88 ^50,88 54,60 z")
        g.detail(0.14) { g in
            for y in stride(from: 32.0, through: 34.0, by: 6) { g.line("^24,\(y) ^56,\(y)", 0.4) }
            g.blot(.circle(26, 70, 1))
            g.blot(.circle(54, 70, 1))
        }
        return g
    }

    /// An original pixel monster: a round, shiny slime with a flat smile.
    static func slimeDrop() -> DoodleGlyph {
        var g = DoodleGlyph("slimeDrop", 0.07, 0.15, tilt: 14)
        g.pixels(["....222....", "..2222222..", ".2b2222222.", ".2b2x222x2.", "2222x222x22", "22222222222", "2222xxx2222", "22222222222", ".222222222."], x: 0, y: 0, cell: 8, w: 1)
        return g
    }

    static func pixelSword() -> DoodleGlyph {
        var g = DoodleGlyph("pixelSword", 0.07, 0.17, tilt: 40)
        g.pixels(["........222", ".......2222", "......2222.", ".....2222..", "....2222...", ".1.2222....", "..1222.....", "..11.......", ".1..1......", "1.........."], x: 0, y: 0, cell: 8, w: 1)
        return g
    }

    static func crystal() -> DoodleGlyph {
        var g = DoodleGlyph("crystal", 0.07, 0.16, tilt: 30)
        g.shape(2, "^30,0 ^60,28 ^30,96 ^0,28 z", 1.2)
        g.shape(0, "^16,14 ^44,14 ^60,28 ^0,28 z", 0.9)
        g.line("^30,0 ^16,14", 0.6)
        g.line("^30,0 ^44,14", 0.6)
        g.line("^16,28 ^30,96 ^44,28", 0.7)
        g.shade("^44,28 ^60,28 ^30,96 z")
        g.gel("^8,32 ^18,54", 0.7)
        g.detail(0.09) { g in
            g.blot(DoodleFillers.sparklePath(70, 8, 6))
        }
        return g
    }

    static func battery() -> DoodleGlyph {
        var g = DoodleGlyph("battery", 0.08, 0.18, tilt: 34)
        g.shape(1, .rrect(96, 14, 10, 20, 2.5), 1.05)
        g.shape(-1, .rrect(0, 2, 98, 44, 8), 1.25)
        for (i, s) in [2, 2, 2, 1].enumerated() {
            let x = 7.0 + Double(i) * 21.5
            g.shape(s, .rrect(x, 9, 18, 30, 2.5), 0.8)
        }
        g.blot("^52,6 ^40,26 ^48,26 ^44,42 ^58,20 ^50,20 z")
        return g
    }

    static func paddleCtl() -> DoodleGlyph {
        var g = DoodleGlyph("paddleCtl", 0.1, 0.22, tilt: 26)
        g.line("60,8 64,-6 78,-10 88,-20 ^84,-30", 1)
        g.shape(1, "^6,18 ^90,6 ^100,14 ^102,76 ^18,92 ^8,84 z", 1.25)
        g.shape(0, "^6,18 ^90,6 ^102,14 ^16,26 z", 0.9)
        g.line("^16,26 ^18,92", 0.8)
        // The big dial.
        g.shape(2, .circle(54, 50, 24), 1.25)
        g.shape(-1, .circle(54, 50, 16), 0.85)
        g.line("^54,50 ^62,38", 1.2)
        g.detail(0.13) { g in
            for i in 0..<16 {
                let a = Double(i) / 16 * 2 * .pi
                g.line(.poly([(54 + 20 * cos(a), 50 + 20 * sin(a)), (54 + 23.4 * cos(a), 50 + 23.4 * sin(a))]), 0.42)
            }
            g.gel("44,44 46,40 50,38", 0.6)
        }
        g.shape(0, .ellipse(90, 34, 6, 7), 0.9)
        return g
    }

    static func cassette() -> DoodleGlyph {
        var g = DoodleGlyph("cassette", 0.1, 0.22, tilt: 26)
        g.shape(0, .rrect(0, 2, 118, 74, 6), 1.25)
        g.shape(-1, .rrect(8, 9, 102, 44, 3), 0.9)
        g.shape(1, "^8,9 ^110,9 ^110,20 ^8,20 z", 0.7)
        // The window and its two reels.
        g.shape(-1, .rrect(32, 26, 54, 20, 9), 0.85)
        g.accent(.circle(42, 36, 7))
        g.accent(.circle(76, 36, 7))
        g.line(.circle(42, 36, 3.5), 0.4)
        g.line("^52,31 ^66,31", 0.45)
        g.line("^52,41 ^66,41", 0.45)
        // The bevel at the bottom.
        g.shape(2, "^22,76 ^28,58 ^90,58 ^96,76 z", 1)
        for x in [36.0, 59.0, 82.0] { g.blot(.circle(x, 68, 2)) }
        g.detail(0.13) { g in
            for x in [4.0, 114.0] {
                g.blot(.circle(x, 6, 1))
                g.blot(.circle(x, 72, 1))
            }
            g.line("^14,14.5 ^60,14.5", 0.5)
        }
        return g
    }

    static func wheel() -> DoodleGlyph {
        var g = DoodleGlyph("wheel", 0.14, 0.26, tilt: 20)
        // Shift paddles behind the rim.
        g.shape(1, "^20,28 ^4,16 ^2,28 ^14,40 z", 0.95)
        g.shape(1, "^84,28 ^100,16 ^102,28 ^90,40 z", 0.95)
        g.band(0, outer: .circle(52, 54, 48), inner: .circle(52, 54, 36), 1.25)
        g.detail(0.16) { g in
            for i in 0..<28 where i % 7 != 0 {
                let a = Double(i) / 28 * 2 * .pi
                g.line(.poly([(52 + 40 * cos(a), 54 + 40 * sin(a)), (52 + 45 * cos(a), 54 + 45 * sin(a))]), 0.42)
            }
        }
        // A marker at twelve o'clock, the spokes, the hub with its buttons.
        g.shape(2, "^47,6 ^57,6 ^57,18 ^47,18 z", 0.9)
        g.shape(1, "^17,48 ^36,44 ^68,44 ^87,48 ^87,60 ^66,64 ^38,64 ^17,60 z", 1.1)
        g.shape(1, "^42,62 ^62,62 ^58,91 ^46,91 z", 1.1)
        g.shape(2, .rrect(36, 40, 32, 26, 8), 1.1)
        g.blot(DoodleFillers.starPath(52, 53, 8))
        g.blot(.circle(26, 54, 1.6))
        g.blot(.circle(78, 54, 1.6))
        g.gel("20,28 28,20 ^38,14", 0.8)
        return g
    }

    static func blaster() -> DoodleGlyph {
        var g = DoodleGlyph("blaster", 0.12, 0.26, tilt: 20)
        g.fixed = true
        // A toy ray gun with a fin, nothing you could buy.
        g.shape(0, "^2,18 ^48,10 ^52,4 ^62,4 ^66,10 ^106,16 118,24 ^106,32 ^56,36 ^44,84 ^18,84 ^28,38 ^2,34 z", 1.3)
        g.shape(1, "^106,16 118,24 ^106,32 z", 1)
        g.shape(1, "^52,4 ^62,4 ^66,10 ^48,10 z", 0.9)
        g.shape(2, .ellipse(72, 24, 12, 7), 1)
        g.line("^60,24 ^84,24", 0.5)
        g.shape(1, "^32,46 ^48,46 ^46,56 ^30,56 z", 0.8)
        // Trigger and guard.
        g.line("^56,36 58,50 50,54 ^44,52", 1.05)
        g.line("^52,38 ^48,46", 1)
        g.detail(0.15) { g in
            for y in [62.0, 68.0, 74.0] { g.line("^\(26.0 + (74 - y) * 0.2),\(y) ^\(44.0 - (y - 62) * 0.1),\(y)", 0.45) }
            g.line("^10,24 ^44,20", 0.5)
            g.gel("^92,20 ^102,21", 0.7)
            g.shade("^2,30 ^28,34 ^56,32 ^106,28 ^106,32 ^56,36 ^28,38 ^2,34 z")
            g.line("^122,16 ^130,12", 0.7)
            g.line("^124,24 ^134,24", 0.7)
            g.line("^122,32 ^130,36", 0.7)
        }
        return g
    }

    static func chips() -> DoodleGlyph {
        var g = DoodleGlyph("chips", 0.09, 0.2, tilt: 22)
        var top: [DoodlePath.Node] = [.init(x: 8, y: 8, corner: true)]
        for i in 0..<9 { top.append(.init(x: 8 + Double(i) * 7.5 + 3.75, y: i % 2 == 0 ? 3 : 8, corner: true)) }
        top.append(.init(x: 80, y: 8, corner: true))
        top += [.init(x: 78, y: 24, corner: false), .init(x: 84, y: 56, corner: false), .init(x: 78, y: 92, corner: false), .init(x: 80, y: 108, corner: true)]
        for i in 0..<9 { top.append(.init(x: 80 - Double(i) * 8 - 4, y: i % 2 == 0 ? 113 : 108, corner: true)) }
        top += [.init(x: 8, y: 108, corner: true), .init(x: 10, y: 92, corner: false), .init(x: 4, y: 56, corner: false), .init(x: 10, y: 24, corner: false)]
        g.shape(1, DoodlePath(nodes: top, closed: true), 1.2)
        g.line("^8,16 ^80,16", 0.55)
        g.line("^8,100 ^80,100", 0.55)
        g.shape(-1, .ellipse(44, 54, 26, 28), 0.9)
        g.shape(2, "^26,48 44,36 62,50 56,66 38,70 z", 0.85)
        g.blot(.circle(40, 50, 1.4))
        g.blot(.circle(50, 56, 1.4))
        g.blot(.circle(42, 62, 1.2))
        g.detail(0.11) { g in
            g.blot(DoodleFillers.starPath(18, 90, 4))
            g.blot(DoodleFillers.starPath(70, 28, 4))
            g.gel("^14,30 ^12,60", 0.8)
            g.shade("^68,24 ^76,24 ^82,56 ^76,92 ^68,92 ^74,56 z")
        }
        return g
    }

    static func speaker() -> DoodleGlyph {
        var g = DoodleGlyph("speaker", 0.1, 0.22, tilt: 14)
        g.shape(1, "^60,4 ^76,10 ^76,110 ^60,116 z", 1.1)
        g.shade("^60,4 ^76,10 ^76,110 ^60,116 z")
        g.shape(0, .rrect(2, 4, 60, 112, 5), 1.25)
        g.shape(-1, .circle(32, 28, 12), 0.95)
        g.accent(.circle(32, 28, 5))
        g.shape(2, .circle(32, 76, 24), 1.15)
        g.shape(-1, .circle(32, 76, 15), 0.85)
        g.accent(.circle(32, 76, 7))
        g.gel("24,70 26,67 29,66", 0.6)
        g.detail(0.13) { g in
            for (x, y) in [(8.0, 10.0), (56.0, 10.0), (8.0, 110.0), (56.0, 110.0)] { g.blot(.circle(x, y, 1)) }
            g.line("^88,40 94,56 ^88,72", 0.7)
            g.line("^96,30 104,56 ^96,82", 0.7)
        }
        return g
    }

    static func ufo() -> DoodleGlyph {
        var g = DoodleGlyph("ufo", 0.08, 0.17, tilt: 26)
        g.shape(-1, "28,30 32,12 50,4 68,12 72,30 z", 1.1)
        g.gel("38,20 41,14 47,11", 0.7)
        g.shape(0, "2,40 18,30 50,26 82,30 98,40 82,50 50,54 18,50 z", 1.25)
        g.shape(1, "^34,50 50,52 ^66,50 ^62,62 ^38,62 z", 1)
        for (x, y) in [(16.0, 41.0), (33.0, 43.0), (50.0, 44.0), (67.0, 43.0), (84.0, 41.0)] { g.shape(2, .circle(x, y, 3.4), 0.7) }
        return g
    }

    static func planet() -> DoodleGlyph {
        var g = DoodleGlyph("planet", 0.08, 0.17, tilt: 30)
        // The ring behind, the world, its bands, the ring in front.
        func ring(_ rx: Double, _ ry: Double, _ t: Double) -> (Double, Double) {
            let a = -18.0 * .pi / 180
            let x = rx * cos(t), y = ry * sin(t)
            return (50 + x * cos(a) - y * sin(a), 50 + x * sin(a) + y * cos(a))
        }
        g.line(.spline((0...16).map { ring(48, 13, Double.pi + Double($0) / 16 * .pi) }), 1)
        g.shape(1, .circle(50, 50, 31), 1.25)
        func band(_ y0: Double, _ y1: Double) -> DoodlePath {
            let r = 30.0
            func half(_ y: Double) -> Double { sqrt(max(0, r * r - (y - 50) * (y - 50))) }
            let steps = 6
            var left: [(Double, Double)] = [], right: [(Double, Double)] = []
            for i in 0...steps {
                let y = y0 + (y1 - y0) * Double(i) / Double(steps)
                right.append((50 + half(y), y))
                left.append((50 - half(y), y))
            }
            return .poly(right + left.reversed(), closed: true)
        }
        g.tint(2, band(32, 39))
        g.tint(0, band(45, 50))
        g.tint(2, band(68, 74))
        g.shade("^60,21 72,30 80,48 76,66 62,78 ^52,80 66,66 72,50 68,32 z")
        g.gel("30,32 36,27 44,24.5", 0.8)
        let outer = (0...16).map { ring(52, 16, Double($0) / 16 * .pi) }
        let inner = (0...16).map { ring(38, 8, Double(16 - $0) / 16 * .pi) }
        let ringNodes = outer.map { DoodlePath.Node(x: $0.0, y: $0.1, corner: false) } + inner.map { DoodlePath.Node(x: $0.0, y: $0.1, corner: false) }
        g.shape(0, DoodlePath(nodes: ringNodes, closed: true), 1.05)
        return g
    }

    static func hourglass() -> DoodleGlyph {
        var g = DoodleGlyph("hourglass", 0.07, 0.15, tilt: 34)
        g.shape(-1, "^12,10 ^68,10 66,28 48,48 66,70 ^68,90 ^12,90 14,70 32,48 14,28 z", 1.15)
        g.shape(2, "^20,26 ^60,26 46,44 ^40,50 ^34,44 z", 0.6)
        g.shape(2, "^40,66 58,80 ^60,88 ^20,88 22,80 z", 0.6)
        g.line("^40,50 ^40,66", 0.6)
        g.shape(1, .rrect(4, 2, 72, 10, 3), 1.15)
        g.shape(1, .rrect(4, 88, 72, 10, 3), 1.15)
        return g
    }

    static func diceBag() -> DoodleGlyph {
        var g = DoodleGlyph("diceBag", 0.09, 0.2, tilt: 18)
        g.fixed = true
        g.shape(1, "^26,28 ^62,28 72,40 84,66 80,90 62,100 ^26,100 8,90 4,66 16,40 z", 1.25)
        g.shape(2, "^26,28 18,12 ^30,16 36,4 ^44,14 52,4 ^58,16 70,12 ^62,28 z", 1)
        g.line("^24,28 44,33 ^64,28", 1.25)
        g.line("^64,28 74,24 ^82,30", 0.9)
        g.blot(.circle(84, 31, 2.4))
        // A d20 on its side, stitched on.
        g.shape(0, "^44,48 ^62,58 ^62,78 ^44,88 ^26,78 ^26,58 z", 0.95)
        g.line("^44,48 ^34,72 ^54,72 z", 0.55)
        g.line("^26,58 ^34,72 ^26,78", 0.5)
        g.line("^62,58 ^54,72 ^62,78", 0.5)
        g.line("^34,72 ^44,88 ^54,72", 0.5)
        g.detail(0.12) { g in
            g.line("^18,46 ^14,70", 0.45)
            g.line("^74,48 ^78,72", 0.45)
            g.shade("^62,98 78,86 ^82,68 ^74,62 ^72,84 ^52,100 z")
        }
        return g
    }

    static func cards() -> DoodleGlyph {
        var g = DoodleGlyph("cards", 0.1, 0.22, tilt: 26)
        g.fixed = true
        func card(_ g: inout DoodleGlyph, _ deg: Double, _ pip: DoodlePath, _ sep: Int) {
            let r: DoodlePath = DoodlePath.rrect(0, 0, 54, 76, 5).moved(34, 8).rotated(deg, about: (50, 90))
            g.shape(sep, r, 1.1)
            g.blot(pip.moved(61, 46).rotated(deg, about: (50, 90)))
        }
        card(&g, -26, DoodleFillers.heartPath(0, 0, 10), 0)
        card(&g, 0, DoodleFillers.starPath(0, 0, 13), 1)
        card(&g, 26, DoodleFillers.heartPath(0, 0, 10), -1)
        return g
    }

    static func webcam() -> DoodleGlyph {
        var g = DoodleGlyph("webcam", 0.07, 0.15, tilt: 22)
        g.shape(1, "^26,62 ^46,62 ^50,74 ^22,74 z", 1)
        g.shape(1, "^10,74 ^62,74 ^66,84 ^6,84 z", 1.1)
        g.shape(0, .circle(36, 34, 30), 1.25)
        g.shape(-1, .circle(36, 34, 18), 0.95)
        g.accent(.circle(36, 34, 9))
        g.gel("31,30 33,28 36,27", 0.6)
        g.blot(.circle(58, 14, 1.8))
        g.detail(0.1) { $0.line(.circle(36, 34, 13), 0.42) }
        return g
    }

    // MARK: Marks for the gaps

    static func pixelStar() -> DoodleGlyph {
        var g = DoodleGlyph("pixelStar", 0.03, 0.065, tilt: 16)
        g.pixels(["...1...", "...1...", "..111..", "1111111", ".11111.", "..111..", ".11.11.", ".1...1."], x: 0, y: 0, cell: 7, w: 0.9)
        return g
    }

    static func pixelPlus() -> DoodleGlyph {
        var g = DoodleGlyph("pixelPlus", 0.02, 0.04, tilt: 10)
        g.cap = 2
        g.pixels([".2.", "222", ".2."], x: 0, y: 0, cell: 12, w: 0.9)
        return g
    }

    static func cursorMark() -> DoodleGlyph {
        var g = DoodleGlyph("cursorMark", 0.03, 0.06, tilt: 18)
        g.shape(-1, "^0,0 ^0,50 ^12,38 ^20,56 ^29,52 ^21,35 ^38,34 z", 1)
        return g
    }

    static func note() -> DoodleGlyph {
        var g = DoodleGlyph("note", 0.03, 0.065, tilt: 24)
        g.blot(.ellipse(10, 46, 9, 7, rot: -20))
        g.blot(.ellipse(42, 40, 9, 7, rot: -20))
        g.line("^18,44 ^17,8", 1.2)
        g.line("^50,38 ^49,2", 1.2)
        g.shape(1, "^17,8 ^49,2 ^49,12 ^17,18 z", 0.8)
        return g
    }

    static func pixelDiamond() -> DoodleGlyph {
        var g = DoodleGlyph("pixelDiamond", 0.025, 0.055, tilt: 14)
        g.pixels(["..2..", ".222.", "22b22", ".222.", "..2.."], x: 0, y: 0, cell: 9, w: 0.9)
        return g
    }

    static func tinyKey() -> DoodleGlyph {
        var g = DoodleGlyph("tinyKey", 0.03, 0.06, tilt: 60)
        g.line(.circle(12, 12, 10), 1.05)
        g.line("^22,14 ^56,14", 1.05)
        g.line("^46,14 ^46,24", 1)
        g.line("^54,14 ^54,24", 1)
        return g
    }

    static func starCoin() -> DoodleGlyph {
        var g = DoodleGlyph("starCoin", 0.03, 0.07, tilt: 30)
        g.shape(2, .circle(30, 30, 25), 1.1)
        g.line(.circle(30, 30, 19), 0.5)
        g.blot(DoodleFillers.starPath(30, 30.5, 12))
        return g
    }

    static func chevrons() -> DoodleGlyph {
        var g = DoodleGlyph("chevrons", 0.025, 0.055, tilt: 40)
        g.line("^0,0 ^12,12 ^0,24", 1.1)
        g.line("^14,0 ^26,12 ^14,24", 1.1)
        g.line("^28,0 ^40,12 ^28,24", 1.1)
        return g
    }

    static func xp() -> DoodleGlyph {
        // A little bar of pips.
        var g = DoodleGlyph("pips", 0.03, 0.07, tilt: 30)
        for i in 0..<5 {
            let x = Double(i) * 12
            if i < 3 { g.shape(1, .rrect(x, 0, 9, 16, 1.5), 0.8) } else { g.line(.rrect(x, 0, 9, 16, 1.5), 0.7) }
        }
        return g
    }
}
