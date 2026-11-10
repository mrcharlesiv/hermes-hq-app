// The Gaming drawings. Original objects, no consoles or characters from any real game.

import CoreGraphics
import Foundation

nonisolated extension DoodleGlyph {
    /// Ink-outlined pixel art. `rows`: '.' is empty, 0/1/2 a spot colour, 'b' bare paper, 'x' solid ink.
    mutating func pixels(_ rows: [String], x: Double, y: Double, cell: Double, w: Double = 0.8) {
        let grid = rows.map { Array($0) }
        let h = grid.count, wd = grid.map(\.count).max() ?? 0
        func at(_ c: Int, _ r: Int) -> Character { r >= 0 && r < h && c >= 0 && c < grid[r].count ? grid[r][c] : "." }
        for r in 0..<h {
            var c = 0
            while c < wd {
                let v = at(c, r)
                if v == "." {
                    c += 1
                    continue
                }
                var e = c + 1
                while at(e, r) == v { e += 1 }
                let box: DoodlePath = .poly([(x + Double(c) * cell, y + Double(r) * cell), (x + Double(e) * cell, y + Double(r) * cell),
                                        (x + Double(e) * cell, y + Double(r + 1) * cell), (x + Double(c) * cell, y + Double(r + 1) * cell)], closed: true)
                switch v {
                case "x": blot(box)
                case "0", "1", "2": shape(Int(String(v))!, box, 0)
                default: shape(-1, box, 0)
                }
                c = e
            }
        }
        // The outline, one stroke per straight stretch.
        var runs: [DoodleRun] = []
        for r in 0...h {
            var c = 0
            while c < wd {
                let edge = (at(c, r - 1) == ".") != (at(c, r) == ".")
                if !edge {
                    c += 1
                    continue
                }
                var e = c + 1
                while e < wd, (at(e, r - 1) == ".") != (at(e, r) == ".") { e += 1 }
                runs.append(DoodleRun(pts: [CGPoint(x: x + Double(c) * cell, y: y + Double(r) * cell), CGPoint(x: x + Double(e) * cell, y: y + Double(r) * cell)], closed: false, over: true))
                c = e
            }
        }
        for c in 0...wd {
            var r = 0
            while r < h {
                let edge = (at(c - 1, r) == ".") != (at(c, r) == ".")
                if !edge {
                    r += 1
                    continue
                }
                var e = r + 1
                while e < h, (at(c - 1, e) == ".") != (at(c, e) == ".") { e += 1 }
                runs.append(DoodleRun(pts: [CGPoint(x: x + Double(c) * cell, y: y + Double(r) * cell), CGPoint(x: x + Double(c) * cell, y: y + Double(e) * cell)], closed: false, over: true))
                r = e
            }
        }
        steps.append(DoodleStep(op: .ink(runs: runs, weight: w), lod: lod))
    }
}

nonisolated enum DoodleGaming {
    static func all() -> [DoodleGlyph] {
        var list = [pad(), phones(), dice(), d20(), fightStick(), keyboard(), handheld(), cabinet(), cartridge(), mouse(), health(), joystick(), floppy(),
                    swordShield(), potion(), chest(), coins(), trophy(), visor(), crt(), bomb(), pizza(), soda(), padSmall(),
                    retroStick(), arrowKeys(), memoryCard(), usbStick(), tickets(), oldKey(), scroll(), crown(), wizardHat(), rocket(), slimeDrop(), pixelSword(), crystal(),
                    battery(), paddleCtl(), cassette(), wheel(), blaster(), chips(), speaker(), ufo(), planet(), hourglass(), diceBag(), cards(), webcam()]
        list += DoodleFillers.common().filter { ["dot"].contains($0.name) }
        list += [DoodleFillers.bolt(), DoodleFillers.pixelHeart(), DoodleFillers.dpad(), starCoin(), pixelStar(), pixelPlus(), cursorMark(), note(), pixelDiamond(), tinyKey(), chevrons(), xp(),
                 tinyGem(), tinyFlask(), roundButton(), plusOne(), pixelArrow(), levelBars(), tinySword(), cableSquiggle()]
        for i in list.indices { list[i].done() }
        return list
    }

    static func pad() -> DoodleGlyph {
        var g = DoodleGlyph("pad", 0.26, 0.42, tilt: 26)
        g.must = true
        g.fixed = true
        // The cable leaves the top, throws one loop and runs to its plug.
        g.line("60,26 61,14 70,3 84,3 91,11 85,19 75,15 74,5 84,-7 100,-11 110,-7", 1)
        g.shape(-1, "^108,-11 ^118,-8 ^115.5,0 ^105.5,-3 z", 0.9)
        g.shape(1, "^116,-8.5 ^122,-6.5 ^120,-0.5 ^114,-2.5 z", 0.7)
        // Shoulder buttons sit behind the body.
        g.shape(1, "^19,34 20,24 27,17 40,16 ^51,27 z")
        g.shape(1, "^101,34 100,24 93,17 80,16 ^69,27 z")
        g.shape(2, "30,27 44,24 60,26 76,24 90,27 104,33 112,51 118,74 115,88 105,92 95,84 85,71 72,67 60,66 48,67 35,71 25,84 15,92 5,88 2,74 8,51 16,33 z", 1.3)
        g.detail(0.2) { g in
            g.gel("23,36 33,31 46,29.5")
            g.gel("97,36 91,33")
            g.shade("^5,78 ^10,64 ^24,80 ^15,91 ^6,88 z")
            g.shade("^115,78 ^110,64 ^96,80 ^105,91 ^114,88 z")
            g.line(.circle(14, 70, 1.5), 0.6)
            g.line(.circle(106, 70, 1.5), 0.6)
        }
        // D-pad in its dish.
        g.line(.circle(30, 46, 14.5), 0.55)
        g.shape(0, "^26,34 ^34,34 ^34,42 ^42,42 ^42,50 ^34,50 ^34,58 ^26,58 ^26,50 ^18,50 ^18,42 ^26,42 z", 0.9)
        g.detail(0.22) { g in
            g.blot("^30,36.5 ^32,39.5 ^28,39.5 z")
            g.blot("^30,55.5 ^32,52.5 ^28,52.5 z")
            g.blot("^20.5,46 ^23.5,44 ^23.5,48 z")
            g.blot("^39.5,46 ^36.5,44 ^36.5,48 z")
            g.line(.circle(30, 46, 2.1), 0.5)
        }
        // Face buttons.
        g.line(.circle(90, 46, 16.5), 0.55)
        for (x, y, s) in [(90.0, 36.0, 1), (100.0, 46.0, 0), (90.0, 56.0, 1), (80.0, 46.0, 0)] {
            g.shape(s, .circle(x, y, 5), 0.9)
            g.detail(0.22) { $0.gel("\(x - 2.6),\(y - 1) \(x - 1.6),\(y - 2.8) \(x + 0.2),\(y - 3.1)", 0.6) }
        }
        // Thumbsticks.
        for x in [47.0, 73.0] {
            g.shape(-1, .circle(x, 54, 9.6), 0.85)
            g.shape(1, .circle(x, 53, 6.8), 0.9)
            g.detail(0.22) { $0.line(.circle(x, 53, 3.8), 0.5) }
        }
        // Middle of the face.
        g.shape(-1, .rrect(49.5, 35, 7, 3.8, 1.8), 0.7)
        g.shape(-1, .rrect(63.5, 35, 7, 3.8, 1.8), 0.7)
        g.shape(1, .circle(60, 32, 3.2), 0.75)
        g.detail(0.26) { g in
            for i in 0..<4 { g.blot(.circle(53.2 + Double(i) * 4.5, 43, 0.85)) }
        }
        return g
    }

    static func padSmall() -> DoodleGlyph {
        // A chunky old pad with a short tail: the small cousin, drawn to read at a small size.
        var g = DoodleGlyph("padSmall", 0.11, 0.2, tilt: 40)
        g.line("50,14 50,4 60,-4 72,-2 76,-10", 1)
        g.shape(0, "20,14 50,12 80,14 94,22 98,40 92,54 80,52 68,42 50,40 32,42 20,52 8,54 2,40 6,22 z", 1.1)
        g.shape(2, "^20,20 ^26,20 ^26,26 ^32,26 ^32,32 ^26,32 ^26,38 ^20,38 ^20,32 ^14,32 ^14,26 ^20,26 z", 0.85)
        g.shape(1, .circle(70, 32, 5), 0.85)
        g.shape(1, .circle(82, 24, 5), 0.85)
        g.line("^44,27 ^56,27", 0.9)
        return g
    }

    /// A die: `o` is the near top corner, `a` and `b` the top edges running away, `c` straight down.
    static func cube(_ g: inout DoodleGlyph, o: (Double, Double), a: (Double, Double), b: (Double, Double), c: (Double, Double),
                     pips: (Int, Int, Int), seps: (Int, Int, Int), shade: Bool = true) {
        func add(_ p: (Double, Double), _ q: (Double, Double)) -> (Double, Double) { (p.0 + q.0, p.1 + q.1) }
        let oa = add(o, a), ob = add(o, b), oab = add(oa, b), oc = add(o, c), oac = add(oa, c), obc = add(ob, c)
        let top = DoodlePath.poly([o, oa, oab, ob], closed: true), right = DoodlePath.poly([o, oa, oac, oc], closed: true), left = DoodlePath.poly([o, ob, obc, oc], closed: true)
        g.shape(seps.0, top, 1)
        g.shape(seps.1, right, 1)
        g.shape(seps.2, left, 1)
        func spots(_ n: Int) -> [(Double, Double)] {
            let l = 0.25, m = 0.5, h = 0.75
            switch n {
            case 1: return [(m, m)]
            case 2: return [(l, l), (h, h)]
            case 3: return [(l, l), (m, m), (h, h)]
            case 4: return [(l, l), (h, l), (l, h), (h, h)]
            case 5: return [(l, l), (h, l), (m, m), (l, h), (h, h)]
            default: return [(l, l), (h, l), (l, m), (h, m), (l, h), (h, h)]
            }
        }
        func pipsOn(_ origin: (Double, Double), _ u: (Double, Double), _ v: (Double, Double), _ n: Int) {
            for (s, t) in spots(n) {
                var nodes: [DoodlePath.Node] = []
                for i in 0..<8 {
                    let k = Double(i) / 8 * 2 * .pi
                    let ps = s + 0.095 * cos(k), pt = t + 0.095 * sin(k)
                    nodes.append(.init(x: origin.0 + u.0 * ps + v.0 * pt, y: origin.1 + u.1 * ps + v.1 * pt, corner: false))
                }
                g.blot(DoodlePath(nodes: nodes, closed: true))
            }
        }
        pipsOn(o, a, b, pips.0)
        pipsOn(o, a, c, pips.1)
        pipsOn(o, b, c, pips.2)
        if shade {
            // The shadow side: a strip along its lower edge, well clear of the pips.
            let a0 = (oc.0 - c.0 * 0.14, oc.1 - c.1 * 0.14), a1 = (oac.0 - c.0 * 0.14, oac.1 - c.1 * 0.14)
            g.detail(0.14) { g in
                g.hatch(.poly([a0, a1, oac, oc], closed: true), angle: 72, gap: 2.5, w: 0.45)
            }
        }
    }

    static func dice() -> DoodleGlyph {
        var g = DoodleGlyph("dice", 0.14, 0.32, tilt: 40)
        g.must = true
        cube(&g, o: (30, 34), a: (24, -10), b: (-22, -12), c: (2, 28), pips: (5, 3, 6), seps: (-1, 0, 1))
        cube(&g, o: (82, 60), a: (22, 8), b: (-8, -22)  , c: (-6, 26), pips: (4, 2, 1), seps: (-1, 2, 0))
        // Rolling marks.
        g.line("^62,14 ^68,8", 0.7)
        g.line("^70,20 ^78,17", 0.7)
        g.line("^56,8 ^58,1", 0.7)
        return g
    }

    static func d20() -> DoodleGlyph {
        var g = DoodleGlyph("d20", 0.1, 0.26, tilt: 45)
        g.noFlip = true
        let cx = 50.0, cy = 50.0, r = 44.0
        var hex: [(Double, Double)] = []
        for i in 0..<6 {
            let a = Double(i) * .pi / 3 - .pi / 2
            hex.append((cx + r * cos(a), cy + r * sin(a)))
        }
        // The inner face points up, its corners a little in from the outline.
        let tri: [(Double, Double)] = [(50, 25), (75, 64), (25, 64)]
        g.shape(0, .poly(hex, closed: true), 1.1)
        // Lower faces take a second colour.
        g.tint(1, .poly([hex[3], tri[2], tri[1]], closed: true))
        g.tint(2, .poly([hex[5], tri[0], tri[2]], closed: true))
        g.shape(-1, .poly(tri, closed: true), 0.95)
        // Edges from the inner triangle out to the corners.
        for (a, b) in [(0, 0), (0, 1), (0, 5), (1, 1), (1, 2), (1, 3), (2, 3), (2, 4), (2, 5)] {
            g.line(.poly([tri[a], hex[b]]), 0.75)
        }
        g.line("^38,44.5 ^38,44.5", 0)
        // The number, written by hand.
        g.line("43,47 45,43 50,42 52,45 50,49 ^44,56 ^53,55", 0.95)
        g.line(.ellipse(58, 49, 3.6, 6.2), 0.9)
        g.detail(0.16) { g in
            g.hatch(.poly([hex[3], tri[1], hex[2]], closed: true), angle: 40, gap: 3.2)
            g.hatch(.poly([hex[1], hex[2], tri[1]], closed: true), angle: 40, gap: 3.2)
        }
        return g
    }

    static func fightStick() -> DoodleGlyph {
        var g = DoodleGlyph("fightStick", 0.2, 0.42, tilt: 24)
        g.must = true
        // The cable out the back.
        g.line("86,34 96,26 108,28 112,38 104,44 98,38 104,28 116,18", 1)
        // Front wall under the top deck.
        g.shape(1, "^2,72 ^110,72 110,76 ^108,92 ^4,92 2,76 z", 1.1)
        // Top deck, leaning away.
        g.shape(0, "^18,34 ^92,34 ^110,72 ^2,72 z", 1.15)
        g.detail(0.22) { g in
            g.hatch("^6,82 ^106,82 ^107,91 ^5,91 z", angle: 75, gap: 3.2)
            g.line(.circle(8, 78, 1.2), 0.5)
            g.line(.circle(104, 78, 1.2), 0.5)
        }
        g.shape(-1, .rrect(45, 75.5, 9, 4, 2), 0.6)
        g.shape(2, .rrect(58, 75.5, 9, 4, 2), 0.6)
        // Stick: washer, shaft, ball.
        g.shape(2, .ellipse(30, 54, 13, 6), 0.9)
        g.line(.ellipse(30, 53.6, 7, 3), 0.55)
        g.shape(-1, "^28,16 ^33,16 ^33.5,54 ^27,54 z", 0.9)
        g.shape(1, .circle(30.5, 13, 11), 1.05)
        g.gel("24,10 26,6.5 30,5", 0.95)
        g.detail(0.2) { $0.hatch("31,23.5 38,20 41,13 ^41,20 ^34,25 z", angle: 30, gap: 2.4) }
        // Six buttons in two arcs, each with a rim below it.
        for (x, y, rx, ry, s) in [(55.0, 45.0, 6.0, 3.4, 1), (70.0, 43.5, 6.0, 3.4, 2), (85.0, 45.0, 6.0, 3.4, 1), (53.0, 59.0, 7.0, 4.0, 2), (70.0, 57.5, 7.0, 4.0, 1), (87.0, 59.0, 7.0, 4.0, 2)] {
            g.shape(-1, .ellipse(x, y + 1.7, rx + 1.2, ry + 1.1), 0.75)
            g.shape(s, .ellipse(x, y, rx, ry), 0.85)
            g.detail(0.26) { $0.gel("\(x - rx * 0.55),\(y - 0.4) \(x - rx * 0.1),\(y - ry * 0.6)", 0.5) }
        }
        return g
    }

    static func keyboard() -> DoodleGlyph {
        var g = DoodleGlyph("keyboard", 0.22, 0.44, tilt: 22)
        g.must = true
        let shear = -0.34, sy = 0.74
        func P(_ x: Double, _ y: Double) -> (Double, Double) { (x + shear * y + 22, y * sy) }
        func key(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double = 1.4) -> DoodlePath {
            let q: [(Double, Double)] = [(x + r, y), (x + w - r, y), (x + w, y + r), (x + w, y + h - r), (x + w - r, y + h), (x + r, y + h), (x, y + h - r), (x, y + r)]
            return .spline(q.map { P($0.0, $0.1) }, closed: true)
        }
        // Coiled cable off the back edge.
        var coil: [(Double, Double)] = []
        for i in 0...32 {
            let t = Double(i) / 32
            coil.append((96 + t * 30 + 2.8 * sin(t * 44), -8 - t * 14 + 3.2 * cos(t * 44)))
        }
        g.line("86,0 92,-6 96,-8", 0.95)
        g.line(.spline(coil), 0.72)
        // Lip of the frame, then the frame.
        let lipA = P(0, 74), lipB = P(136, 74)
        g.shape(1, .poly([lipA, lipB, (lipB.0, lipB.1 + 8), (lipA.0, lipA.1 + 8)], closed: true), 1.05)
        g.shape(0, key(0, 0, 136, 74, 4), 1.15)
        g.detail(0.26) { $0.hatch(.poly([(lipA.0, lipA.1 + 2), (lipB.0, lipB.1 + 2), (lipB.0, lipB.1 + 7), (lipA.0, lipA.1 + 7)], closed: true), angle: 78, gap: 3.4) }
        let pitch = 12.6
        let rows: [(start: Double, n: Int)] = [(4.5, 10), (7.5, 10), (10.5, 9), (15, 9)]
        for (r, row) in rows.enumerated() {
            for c in 0..<row.n {
                let x = row.start + Double(c) * pitch, y = 4.5 + Double(r) * pitch
                let isMove = (r == 1 && c == 1) || (r == 2 && (c == 0 || c == 1 || c == 2))
                g.shape(isMove ? 1 : -1, key(x, y, 11, 11), 0.72)
                g.detail(0.3) { $0.line(key(x + 2.4, y + 1.8, 6.2, 5.8, 1), 0.4) }
            }
        }
        // Bottom row: modifiers and a long space bar.
        g.shape(-1, key(4.5, 55, 14, 11), 0.72)
        g.shape(-1, key(20, 55, 14, 11), 0.72)
        g.shape(2, key(35.5, 55, 62, 11), 0.72)
        g.shape(-1, key(99, 55, 14, 11), 0.72)
        g.shape(-1, key(114.5, 55, 14, 11), 0.72)
        return g
    }

    static func handheld() -> DoodleGlyph {
        var g = DoodleGlyph("handheld", 0.18, 0.38, tilt: 28)
        // Shoulder lips behind the body.
        g.shape(1, "^10,14 14,6 ^34,6 ^38,14 z", 0.9)
        g.shape(1, "^110,14 106,6 ^86,6 ^82,14 z", 0.9)
        g.shape(0, "18,10 60,9 102,10 112,14 118,28 118,58 112,72 100,76 60,76 20,76 8,72 2,58 2,28 8,14 z", 1.15)
        // Screen bezel and screen with a tiny world.
        g.shape(-1, .rrect(32, 15, 56, 44, 4), 0.95)
        g.shape(1, .rrect(37, 20, 46, 34, 2), 0.8)
        g.pixels(["...........", "....x......", "...xxx.....", "..xxxxx..x.", ".xxxxxxxxxx", "xxxxxxxxxxx"], x: 40.5, y: 30, cell: 3.6, w: 0)
        g.detail(0.2) { g in
            g.blot(.rrect(68, 24, 8, 2.4, 1))
            g.blot(.rrect(64, 27.5, 6, 2, 1))
        }
        // Thumbs.
        g.shape(2, "^15,28 ^21,28 ^21,36 ^28,36 ^28,42 ^21,42 ^21,50 ^15,50 ^15,42 ^8,42 ^8,36 ^15,36 z", 0.85)
        g.shape(2, .circle(100, 44, 6), 0.9)
        g.shape(1, .circle(110, 32, 6), 0.9)
        g.detail(0.22) { g in
            g.gel("96.5,43 97.5,40.5 100,39.5", 0.6)
            g.gel("106.5,31 107.5,28.5 110,27.5", 0.6)
            for i in 0..<3 { g.line("^\(44 + Double(i) * 5),68 ^\(46 + Double(i) * 5),72", 0.7) }
            for i in 0..<3 { g.line("^\(70 + Double(i) * 5),68 ^\(72 + Double(i) * 5),72", 0.7) }
            g.hatch("^4,58 ^20,60 ^28,76 ^12,74 z", angle: 60, gap: 3.1)
        }
        return g
    }

    static func cabinet() -> DoodleGlyph {
        var g = DoodleGlyph("cabinet", 0.18, 0.46, tilt: 12)
        // Side panel behind, its profile showing past the front.
        g.shape(1, "^72,4 ^92,8 ^94,24 ^84,30 ^86,58 ^98,66 ^98,70 ^92,74 ^92,122 ^78,124 ^78,4 z", 1.1)
        g.detail(0.3) { g in
            g.hatch("^80,76 ^90,74 ^90,120 ^80,122 z", angle: 68, gap: 3.4)
        }
        // Base.
        g.shape(0, "^16,70 ^78,70 ^78,124 ^16,124 z", 1.15)
        // A coin door, off to one side, and speaker slots on the other.
        g.shape(-1, .rrect(24, 82, 24, 32, 2), 0.85)
        g.shape(2, .rrect(29, 87, 6, 11, 1), 0.7)
        g.accent("^30.4,88.6 ^33.6,88.6 ^33.6,96.4 ^30.4,96.4 z")
        g.accent("^26,108.6 ^46,108.6 ^46,113 ^26,113 z")
        g.blot(.circle(41, 92, 1.6))
        g.line("^29,104 ^43,104", 0.6)
        g.line("^29,108 ^43,108", 0.6)
        g.detail(0.3) { g in
            for y in [86.0, 91.0, 96.0, 101.0, 106.0, 111.0] { g.line("^56,\(y) ^72,\(y)", 0.5) }
        }
        g.line("^16,118 ^78,118", 0.55)
        // Control deck.
        g.shape(0, "^22,50 ^72,50 ^80,68 ^80,73 ^14,73 ^14,68 z", 1.1)
        g.line("^14,68 ^80,68", 0.7)
        g.shape(2, .ellipse(32, 60, 6, 3), 0.7)
        g.shape(-1, "^31,50 ^33.4,50 ^33.4,60 ^31,60 z", 0.7)
        g.shape(1, .circle(32, 47.5, 4.2), 0.85)
        for (x, s) in [(50.0, 1), (60.0, 2), (70.0, 1)] {
            g.shape(s, .ellipse(x, 60, 4, 2.4), 0.75)
        }
        // Screen hood.
        g.shape(0, "^20,20 ^76,20 ^72,52 ^24,52 z", 1.1)
        g.shape(1, .rrect(27, 24, 42, 26, 4), 0.9)
        g.pixels(["....xxx....", "..xxxxxxx..", ".xxxxxxxxx.", ".xxx.xxx.x.", "xxxx.xxx.xx", "xxxxxxxxxxx", "xxxx...xxxx", "xxxxxxxxxxx", ".xxxxxxxxx."], x: 35.5, y: 26.5, cell: 2.3, w: 0)
        g.detail(0.3) { g in
            for (x, y) in [(31.0, 29.0), (65.0, 30.0)] { g.blot(.circle(x, y, 0.8)) }
            g.line("^35,48 ^43,48", 0.5)
            g.line("^47,48 ^61,48", 0.5)
        }
        // Marquee with a lit panel.
        g.shape(0, "^14,4 ^78,4 ^76,20 ^16,20 z", 1.15)
        g.shape(2, .rrect(21, 7.5, 50, 9, 2), 0.8)
        g.detail(0.28) { g in
            for x in [28.0, 37.0, 46.0, 55.0, 64.0] { g.blot(DoodleFillers.starPath(x, 12, 2.8)) }
        }
        return g
    }

    static func cartridge() -> DoodleGlyph {
        var g = DoodleGlyph("cartridge", 0.11, 0.26, tilt: 40)
        g.shape(0, "^6,3 ^74,3 ^74,84 ^68,92 ^12,92 ^6,84 z", 1.15)
        g.line("^12,3 ^12,12 ^68,12 ^68,3", 0.7)
        g.shape(1, .rrect(14, 20, 52, 48, 2.4), 0.9)
        // Label: a hill, a star, two lines of writing.
        g.line("^17,58 29,42 ^37,52 44,44 ^63,60", 0.8)
        g.blot(DoodleFillers.starPath(52, 31, 5.6))
        g.detail(0.15) { g in
            g.line("^20,31 ^38,31", 0.65)
            g.line("^20,36 ^34,36", 0.65)
            g.hatch("^20,58 ^29,45 ^34,58 z", angle: 55, gap: 2.4)
        }
        g.blot("^40,88 ^33,78 ^47,78 z")
        g.detail(0.15) { g in
            for y in [16.0, 18.0] { g.line("^16,\(y) ^64,\(y)", 0.35) }
            for y in [72.0, 76.0, 80.0, 84.0] {
                g.line("^6,\(y) ^10,\(y)", 0.6)
                g.line("^70,\(y) ^74,\(y)", 0.6)
            }
        }
        return g
    }

    static func mouse() -> DoodleGlyph {
        var g = DoodleGlyph("mouse", 0.13, 0.3, tilt: 34)
        // The cable leaves the nose and wanders off.
        g.line("40,6 40,-8 48,-18 62,-16 70,-24 66,-36 ^56,-40", 1)
        g.shape(0, "40,6 55,8 66,18 71,38 73,60 69,82 57,97 40,102 23,97 11,82 7,60 9,38 14,18 25,8 z", 1.2)
        // Soft rubber sides.
        g.shape(1, "^8,50 ^13,50 14,68 20,84 ^30,95 21,93 12,81 8,66 z", 0.8)
        g.shape(1, "^72,50 ^67,50 66,68 60,84 ^50,95 59,93 68,81 72,66 z", 0.8)
        // The split between the buttons, the wheel, the line across the palm.
        g.line("40,6 ^40,20", 0.9)
        g.line("^40,44 ^40,50", 0.9)
        g.line("^8,44 22,50 40,52 58,50 ^72,44", 0.85)
        g.shape(2, "^8,28 ^14,26 ^13,36 ^7,38 z", 0.7)
        g.shape(2, "^7,39 ^13,37 ^13,47 ^7,48 z", 0.7)
        g.shape(-1, .rrect(36, 55, 8, 13, 2), 0.7)
        g.shape(-1, .rrect(33, 20, 14, 25, 6), 0.75)
        g.shape(1, .rrect(35.5, 22, 9, 20, 4.5), 0.9)
        g.detail(0.16) { g in
            for y in [26.0, 30.0, 34.0, 38.0] { g.line("^37.5,\(y) ^42.5,\(y)", 0.55) }
        }
        g.detail(0.2) { g in
            g.gel("18,26 24,17 32,13", 0.75)
            g.hatch("^46,92 ^58,84 ^65,66 ^62,86 ^52,96 z", angle: 60, gap: 3.1)
            g.line("^30,70 ^50,70", 0.45)
            g.line("^33,74 ^47,74", 0.45)
        }
        return g
    }

    static func health() -> DoodleGlyph {
        var g = DoodleGlyph("health", 0.14, 0.32, tilt: 22, fixed: true)
        let full = [".11.11.", "1111111", "1111111", ".11111.", "..111..", "...1..."]
        let half = [".11.bb.", "111bbbb", "111bbbb", ".11bbb.", "..1bb..", "...b..."]
        let gone = [".bb.bb.", "bbbbbbb", "bbbbbbb", ".bbbbb.", "..bbb..", "...b..."]
        g.pixels(full, x: 0, y: 0, cell: 5, w: 0.85)
        g.pixels(half, x: 42, y: 0, cell: 5, w: 0.85)
        g.pixels(gone, x: 84, y: 0, cell: 5, w: 0.85)
        g.detail(0.16) { g in
            g.gel("^6,6 ^10,6", 0.7)
            g.gel("^48,6 ^52,6", 0.7)
        }
        // Experience bar under them.
        g.shape(-1, .rrect(0, 37, 119, 12, 3), 0.95)
        g.shape(2, .rrect(3, 40, 74, 6, 2), 0.6)
        g.detail(0.2) { g in
            for x in [20.0, 40.0, 60.0, 80.0, 100.0] { g.line("^\(x),38.5 ^\(x),47.5", 0.45) }
        }
        return g
    }

    static func joystick() -> DoodleGlyph {
        var g = DoodleGlyph("mic", 0.13, 0.32, tilt: 18)
        // Weighted base, stem, and a lead running off to one side.
        g.line("^58,126 72,124 84,114 ^92,116", 0.8)
        g.shape(1, .ellipse(40, 124, 30, 7), 1.2)
        g.detail(0.16) { $0.hatch(.ellipse(50, 126, 18, 4), angle: 70, gap: 2.8, w: 0.45) }
        g.shape(-1, "^37,86 ^43,86 ^43,120 ^37,120 z", 1)
        g.shape(1, .rrect(34, 96, 12, 6, 2), 0.8)
        // Yoke around the body.
        g.line("10,50 10,70 20,84 40,88 60,84 70,70 ^70,50", 1.15)
        g.line("14,50 14,69 23,80 40,84 57,80 66,69 ^66,50", 0.6)
        g.shape(1, .circle(12, 50, 4), 0.85)
        g.shape(1, .circle(68, 50, 4), 0.85)
        // The capsule: grille, a band, the body.
        g.shape(0, "^20,14 26,3 40,0 54,3 ^60,14 ^60,40 ^20,40 z", 1.3)
        g.detail(0.16) { g in
            g.hatch("^22,12 ^58,12 ^58,38 ^22,38 z", angle: 45, gap: 5, w: 0.45)
            g.hatch("^22,12 ^58,12 ^58,38 ^22,38 z", angle: 135, gap: 5, w: 0.45)
            g.gel("^26,10 ^25,20", 0.8)
        }
        g.shape(2, .rrect(17, 40, 46, 8, 2), 1.05)
        g.shape(1, "^20,48 ^60,48 ^60,70 54,78 ^26,78 20,70 z", 1.3)
        g.shape(-1, .rrect(33, 54, 14, 9, 2), 0.7)
        g.blot(.circle(40, 58.5, 1.6))
        g.detail(0.16) { g in
            g.hatch("^50,52 ^59,52 ^59,70 ^52,76 z", angle: 66, gap: 3, w: 0.5)
            for (x, y) in [(28.0, 68.0), (40.0, 72.0), (34.0, 70.0), (46.0, 70.0)] { g.blot(.circle(x, y, 0.8)) }
        }
        return g
    }

    static func floppy() -> DoodleGlyph {
        var g = DoodleGlyph("floppy", 0.09, 0.24, tilt: 40)
        g.shape(0, "^6,6 ^76,6 ^88,18 ^88,88 ^6,88 z", 1.15)
        g.shape(1, "^26,6 ^66,6 ^66,32 ^26,32 z", 0.95)
        g.blot("^50,11 ^59,11 ^59,27 ^50,27 z")
        g.shape(2, "^16,46 ^78,46 ^78,88 ^16,88 z", 0.95)
        g.detail(0.14) { g in
            g.line("23,57 27,54 31,58 35,54 39,58 43,54 47,57", 0.7)
            g.line("^23,66 ^70,66", 0.45)
            g.line("^23,74 ^70,74", 0.45)
            g.line("^23,82 ^70,82", 0.45)
            g.blot(.rrect(9, 10, 5, 5, 1))
        }
        return g
    }

    static func swordShield() -> DoodleGlyph {
        var g = DoodleGlyph("swordShield", 0.2, 0.42, tilt: 18)
        // The sword lies behind the shield, its tip and hilt showing.
        g.shape(1, "^104,-8 ^108,6 ^16,104 ^6,94 z", 1.05)
        g.line("^102,2 ^22,88", 0.5)
        // Guard, grip with wrap, pommel, on the near end.
        g.shape(0, "^-2,74 ^3,70 ^28,96 ^24,101 z", 0.95)
        g.shape(2, "^8,88 ^15,95 ^3,108 ^-4,101 z", 0.9)
        g.line("^7,93 ^12,98", 0.6)
        g.line("^4,97 ^9,102", 0.6)
        g.shape(1, .circle(-5, 109, 5.2), 0.9)
        // Shield.
        g.shape(0, "^16,20 34,18 ^52,10 70,18 ^88,20 88,48 76,72 ^52,92 28,72 16,48 z", 1.2)
        g.shape(2, "^23,27 37,25 ^52,18 67,25 ^81,27 81,47 70,68 ^52,83 34,68 23,47 z", 0.8)
        g.shape(-1, "^23,44 ^52,60 ^81,44 ^81,54 ^52,72 ^23,54 z", 0.8)
        g.shape(-1, DoodleFillers.starPath(52, 38, 10), 0.75)
        g.detail(0.22) { g in
            for (x, y) in [(52.0, 13.5), (20.0, 24.0), (84.0, 24.0), (20.0, 46.0), (84.0, 46.0), (52.0, 87.0), (29.0, 65.0), (75.0, 65.0)] { g.blot(.circle(x, y, 1.1)) }
            g.hatch("^56,72 ^72,62 ^66,70 ^54,80 z", angle: 55, gap: 2.8)
        }
        return g
    }

    static func potion() -> DoodleGlyph {
        var g = DoodleGlyph("potion", 0.11, 0.3, tilt: 26)
        g.shape(-1, .circle(50, 62, 33), 1.15)
        // Liquid with a wavy surface.
        g.shape(1, "^18,58 28,54 38,58 50,54 62,58 72,54 ^82,58 82,70 72,86 50,94.5 28,86 18,70 z", 0)
        g.line("18,58 28,54 38,58 50,54 62,58 72,54 82,58", 0.8)
        g.line(.circle(50, 62, 33), 1.15)
        // Neck, lip, cork.
        g.shape(-1, "^40,14 ^60,14 ^60,31 ^40,31 z", 1)
        g.tint(-1, "^41,28 ^59,28 ^60,34 ^40,34 z")
        g.shape(0, .rrect(36, 10, 28, 7, 3), 1)
        g.shape(2, "^41,10 39,1 ^61,1 ^59,10 z", 0.95)
        g.detail(0.14) { g in
            g.line(.circle(40, 74, 3.6), 0.65)
            g.line(.circle(56, 80, 2.4), 0.6)
            g.line(.circle(62, 66, 2), 0.55)
            g.gel("28,42 34,36 41,33", 1.1)
            g.gel("24,50 25,47", 1.1)
            g.hatch("^62,88 ^76,78 ^82,62 ^82,70 72,86 ^60,92 z", angle: 55, gap: 3)
            g.line(.circle(47, 3.5, 0.9), 0.4)
            g.line(.circle(54, 6, 0.9), 0.4)
        }
        // A tag on a string.
        g.detail(0.18) { g in
            g.line("60,24 70,28 76,36", 0.6)
            g.shape(2, "^74,36 ^84,33 ^90,46 ^80,50 z", 0.75)
            g.blot(.circle(82, 42, 1.4))
        }
        return g
    }

    static func chest() -> DoodleGlyph {
        var g = DoodleGlyph("chest", 0.17, 0.36, tilt: 18)
        g.whole = true
        // Body.
        g.shape(0, "^8,42 ^92,42 ^92,84 ^8,84 z", 1.2)
        g.detail(0.2) { g in
            g.line("^8,56 ^92,56", 0.6)
            g.line("^8,70 ^92,70", 0.6)
            g.hatch("^60,72 ^90,72 ^90,83 ^60,83 z", angle: 65, gap: 3)
        }
        // Lid, an arch.
        g.shape(0, "^8,42 7,26 18,12 ^82,12 93,26 ^92,42 z", 1.2)
        g.detail(0.2) { g in
            g.line("^14,22 ^86,22", 0.55)
            g.line("^9,32 ^91,32", 0.55)
            g.gel("24,16 40,15", 0.8)
        }
        // Iron bands and corners.
        for x in [18.0, 72.0] {
            g.shape(1, "^\(x),12 ^\(x + 10),12 ^\(x + 10),84 ^\(x),84 z", 0.95)
            g.detail(0.2) { g in
                for y in [18.0, 36.0, 50.0, 64.0, 78.0] { g.blot(.circle(x + 5, y, 1.1)) }
            }
        }
        g.line("^8,42 ^92,42", 1.1)
        // Lock.
        g.shape(2, "^41,35 ^59,35 ^59,53 50,60 ^41,53 z", 1)
        g.blot(.circle(50, 44, 2.6))
        g.blot("^48.8,45 ^51.2,45 ^52,52 ^48,52 z")
        // Feet and spilled coins.
        g.shape(1, "^10,84 ^22,84 ^20,90 ^12,90 z", 0.9)
        g.shape(1, "^78,84 ^90,84 ^88,90 ^80,90 z", 0.9)
        g.shape(2, .ellipse(101, 86, 9, 3.6), 0.85)
        g.shape(2, .ellipse(101, 82.5, 9, 3.6), 0.85)
        g.shape(2, .ellipse(100, 79, 9, 3.6), 0.85)
        g.shape(2, .circle(112, 68, 6.6), 0.85)
        g.line(.circle(112, 68, 4), 0.42)
        return g
    }

    static func coins() -> DoodleGlyph {
        var g = DoodleGlyph("coins", 0.08, 0.24, tilt: 30)
        // A stack behind, one big in front.
        for (i, y) in [78.0, 70.0, 62.0, 54.0, 46.0].enumerated() {
            g.shape(1, .ellipse(84, y, 19, 7), 1.0)
            if i == 4 { g.line(.ellipse(84, y, 13, 4.2), 0.5) }
            g.detail(0.12) { g in
                for x in [70.0, 76.0, 84.0, 92.0, 98.0] { g.line("^\(x),\(y + 5.2) ^\(x),\(y + 8)", 0.42) }
            }
        }
        g.shape(0, .circle(44, 52, 36), 1.2)
        g.line(.circle(44, 52, 28.5), 0.8)
        g.detail(0.12) { g in
            for i in 0..<30 {
                let a = Double(i) / 30 * 2 * .pi
                g.line(.poly([(44 + 30.2 * cos(a), 52 + 30.2 * sin(a)), (44 + 34.2 * cos(a), 52 + 34.2 * sin(a))]), 0.42)
            }
        }
        g.shape(2, DoodleFillers.starPath(44, 52, 20), 0.95)
        g.detail(0.14) { g in
            g.gel("18,44 21,34 28,27", 1)
            g.hatch("^60,70 ^68,58 ^71,50 70,66 58,80 ^48,86 z", angle: 50, gap: 2.8)
        }
        return g
    }

    static func trophy() -> DoodleGlyph {
        var g = DoodleGlyph("trophy", 0.12, 0.3, tilt: 22)
        g.line("26,12 12,12 8,22 14,36 ^32,44", 1.1)
        g.line("26,18 17,18 15,24 19,32 ^29,38", 0.7)
        g.line("74,12 88,12 92,22 86,36 ^68,44", 1.1)
        g.line("74,18 83,18 85,24 81,32 ^71,38", 0.7)
        g.shape(-1, "^47,50 ^53,50 ^54,68 ^46,68 z", 0.9)
        g.shape(1, "^40,68 ^60,68 ^66,76 ^34,76 z", 1)
        g.shape(0, "^24,6 ^76,6 76,26 68,46 ^56,56 ^44,56 32,46 24,26 z", 1.2)
        g.shape(1, .ellipse(50, 6, 26, 4.6), 0.95)
        g.shape(2, DoodleFillers.starPath(50, 29, 11), 0.9)
        g.shape(2, .rrect(30, 76, 40, 13, 2), 1.05)
        g.detail(0.16) { g in
            g.shape(-1, .rrect(38, 79.5, 24, 6, 1), 0.55)
            g.gel("31,14 32,26 37,38", 1.1)
            g.hatch("^60,14 ^74,14 74,26 66,44 ^56,52 z", angle: 62, gap: 3)
        }
        return g
    }

    static func bomb() -> DoodleGlyph {
        var g = DoodleGlyph("bomb", 0.09, 0.2, tilt: 34, fixed: true)
        g.line("66,30 72,16 84,14 92,6", 1.05)
        g.detail(0.1) { g in
            g.line("^96,-2 ^97,-8", 0.75)
            g.line("^102,3 ^108,1", 0.75)
            g.line("^102,10 ^107,12", 0.75)
        }
        g.shape(1, DoodleFillers.starPath(95, 4, 8), 0.8)
        g.shape(2, "^56,24 ^74,34 ^68,44 ^50,34 z", 1)
        g.shape(0, .circle(42, 58, 33), 1.25)
        g.detail(0.12) { g in
            g.gel("18,50 22,38 32,31", 1.2)
            g.gel("16,58 16.5,55", 1.2)
            g.hatch("^56,82 ^68,70 ^74,54 72,72 58,86 ^46,90 z", angle: 50, gap: 2.9)
            // An iron band with rivets, the way an old bomb is made.
            g.line("10,66 24,74 44,77 62,73 ^74,64", 0.6)
            g.line("10,60 24,68 44,71 62,67 ^75,58", 0.6)
            for (x, y) in [(20.0, 69.0), (32.0, 72.5), (44.0, 74.0), (56.0, 72.0), (66.0, 66.5)] { g.blot(.circle(x, y, 0.9)) }
        }
        return g
    }

    static func pizza() -> DoodleGlyph {
        var g = DoodleGlyph("pizza", 0.1, 0.26, tilt: 34, fixed: true)
        // Cheese with drips along its sides, then the crust over the top.
        g.shape(0, "^11,24 ^87,24 76,48 ^68,64 66,74 61,74 59,68 ^50,88 49,99 ^46,102 43,99 ^41,86 ^32,62 30,70 25,70 24,60 ^11,24 z", 1.1)
        g.shape(1, "^6,18 22,8 48,4 72,8 ^92,18 90,28 68,23 48,21 28,23 ^8,28 z", 1.15)
        g.detail(0.12) { g in
            g.line("18,14 22,12", 0.6)
            g.line("44,9 52,9", 0.6)
            g.line("74,13 78,15", 0.6)
        }
        // Slices thrown on anyhow, of different sizes, so they are never a face.
        g.shape(2, "22,35 28,31 34,34 35,41 30,46 23,44 z", 0.85)
        g.shape(2, "46,30 53,29 57,34 54,40 47,40 44,35 z", 0.85)
        g.shape(2, "62,44 68,42 72,46 69,52 63,52 60,48 z", 0.85)
        g.shape(2, "38,56 45,53 51,57 50,65 43,68 37,63 z", 0.85)
        g.detail(0.14) { g in
            g.blot(.circle(28, 38, 0.9))
            g.blot(.circle(31, 41, 0.7))
            g.blot(.circle(52, 34, 0.8))
            g.blot(.circle(44, 60, 0.9))
            g.blot(.circle(47, 62, 0.7))
            g.line("^41,32 ^38,36", 0.5)
            g.line("^56,50 ^54,55", 0.5)
            g.line("^30,50 ^33,54", 0.5)
            g.line("^60,30 ^64,33", 0.5)
        }
        return g
    }

    static func soda() -> DoodleGlyph {
        var g = DoodleGlyph("soda", 0.09, 0.25, tilt: 28)
        // A straw at an angle.
        g.shape(1, "^50,8 ^64,-14 ^69,-11 ^56,11 z", 0.9)
        g.shape(0, "^20,16 ^68,16 ^74,26 ^74,84 ^66,94 ^22,94 ^14,84 ^14,26 z", 1.2)
        g.shape(-1, .ellipse(44, 15, 24, 5.4), 1)
        g.line(.ellipse(44, 15, 19, 3.6), 0.55)
        g.shape(1, "^24,40 ^64,34 ^64,70 ^24,76 z", 0.8)
        g.shape(2, "^50,38 ^34,60 ^44,60 ^38,74 ^56,50 ^46,50 z", 0.9)
        g.detail(0.14) { g in
            g.gel("20,32 20,50", 1)
            g.hatch("^64,28 ^73,28 ^73,84 ^64,92 z", angle: 65, gap: 3)
            g.line("^14,84 ^74,84", 0.6)
        }
        return g
    }
}
