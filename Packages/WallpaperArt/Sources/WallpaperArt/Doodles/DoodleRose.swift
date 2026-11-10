// The Rose drawings: butterflies, flowers, bows, gems, perfume, ribbons. Spot 0 is petal and silk, 1 is leaf, 2 is a warm
// metal and honey colour; -1 leaves the paper bare.

import CoreGraphics
import Foundation

nonisolated enum DoodleRose {
    static func all() -> [DoodleGlyph] {
        var list = [butterfly(), rose(), bow(), perfume(), gem(), peony(), butterflySide(), ribbon(), flacon(), tulip(), lily(), blossom(), heartGem(), emerald(), lipstick(), mirror(), ring(),
                    pearls(), letter(), locket(), teacup(), cherries(), strawberry(), heel(), handbag(), tiara(), cupcake(), feather(), daisy(), sprig(), bud(), moth(), petal(), tinyFlower(), tinyHeart(), tinyBow(),
                    bee(), macaron(), hairClip(), comb(), nailPolish(), earring(), compact(), roseKey(), candle(), fan(), starFlower(), drop(), brush(), hatbox(), spool(), scissors(), songbird(), peach(), stamp(),
                    ringBox(), pansy(), shell(), threeDots(), tinyLeaf()]
        list += DoodleFillers.common().filter { !["star", "plus", "squiggle", "ring", "cross"].contains($0.name) }
        // The same drawing may come back in butter or sage, so pink never has the picture to itself.
        let recolored: Set<String> = ["bow", "blossom", "daisy", "peony", "ribbon", "heartGem", "gem", "tinyBow", "tinyFlower", "handbag", "bud", "petal", "butterflySide", "moth"]
        for i in list.indices {
            list[i].fixed = true
            if recolored.contains(list[i].name) { list[i].recolor = true }
            list[i].done()
        }
        return list
    }

    static func butterflySide() -> DoodleGlyph {
        var g = DoodleGlyph("butterflySide", 0.1, 0.32, tilt: 28)
        // It stands on a twig with a leaf.
        g.line("^10,80 34,74 ^70,86", 1.05)
        leafShape(&g, tipX: 96, tipY: 72, baseX: 62, baseY: 84, fat: 0.26, w: 0.9)
        leafShape(&g, tipX: -10, tipY: 66, baseX: 16, baseY: 78, fat: 0.26, w: 0.9)
        // Back wing, front wing, folded together above the body.
        g.shape(2, "^42,52 66,62 82,54 84,42 ^78,42 80,30 ^70,34 ^62,28 ^52,38 z", 1.1)
        g.shape(0, "^40,52 34,32 38,12 50,0 ^60,4 66,0 ^72,8 ^80,8 78,24 68,40 ^50,50 z", 1.3)
        g.shape(-1, "^43,48 40,32 43,17 52,8 ^60,11 ^66,8 ^71,14 72,24 64,36 ^50,46 z", 0.7)
        g.detail(0.14) { g in
            g.line("^43,48 45,30 ^52,12", 0.42)
            g.line("^44,48 52,30 ^62,12", 0.42)
            g.line("^45,48 58,34 ^70,18", 0.42)
            g.line("^46,48 62,40 ^70,30", 0.42)
            g.line("^52,50 62,52 ^76,50", 0.42)
        }
        // A drop of colour on the wing, not a ring: a ring with a dot in it stares back.
        g.shape(2, "^50,32 54,22 ^64,16 63,27 z", 0.6)
        // Body, head, antennae, proboscis.
        g.shape(1, "^24,52 30,46 42,48 56,56 ^64,62 54,62 38,60 28,58 z", 1.1)
        g.detail(0.14) { g in
            g.line("^40,49 ^39,60", 0.45)
            g.line("^46,51 ^45,61", 0.45)
            g.line("^52,55 ^51,61", 0.45)
        }
        g.line("26,47 18,36 ^12,32", 0.7)
        g.line("29,46 26,32 ^20,24", 0.7)
        g.blot(.circle(12, 32, 1.4))
        g.blot(.circle(20, 24, 1.4))
        g.line("24,54 18,60 19,66 ^24,68", 0.65)
        g.line("^34,59 ^32,72", 0.6)
        g.line("^40,60 ^40,74", 0.6)
        return g
    }

    /// A rose head seen from slightly above: rings of crescent petals, the outside first, each ring turned so that its
    /// joints fall behind the middle of the petals before it, closing on a small whorl set off centre.
    static func roseHead(_ g: inout DoodleGlyph, cx: Double, cy: Double, r: Double, w: Double = 1) {
        func polar(_ a: Double, _ rr: Double, _ ox: Double = 0, _ oy: Double = 0) -> (Double, Double) {
            (cx + (ox + rr * cos(a)) * r / 50, cy + (oy + rr * sin(a) * 0.93) * r / 50)
        }
        func crescent(_ a0: Double, _ a1: Double, _ inner: Double, _ outer: Double, _ ox: Double, _ oy: Double, _ lip: Double, _ weight: Double) {
            let d = a1 - a0
            let pts = [polar(a0, inner * 1.08, ox, oy), polar(a0 + d * 0.16, outer * 0.92, ox, oy), polar(a0 + d * 0.5, outer * lip, ox, oy), polar(a0 + d * 0.84, outer * 0.93, ox, oy),
                       polar(a1, inner * 1.08, ox, oy), polar(a0 + d * 0.5, inner * 0.98, ox, oy)]
            var nodes = pts.map { DoodlePath.Node(x: $0.0, y: $0.1, corner: false) }
            nodes[0].corner = true
            nodes[4].corner = true
            g.shape(0, DoodlePath(nodes: nodes, closed: true), weight)
        }
        // The whole head, so nothing shows through.
        g.shape(0, .ellipse(cx, cy, r * 0.9, r * 0.84), 0)
        // Outer guard petals: five, a little uneven, some with a turned lip.
        let tau = 2 * Double.pi
        var a = -2.3
        for (i, span) in [1.46, 1.3, 1.5, 1.22, 1.3].enumerated() {
            crescent(a - 0.2, a + span + 0.12, 27, 50, 0, 0, 1.03 + 0.03 * Double(i % 2), w * 1.25)
            a += span
        }
        g.detail(0.17) { g in
            for t in [-2.0, -1.2, -0.45, 0.4, 1.1, 1.9, 2.7] {
                let u = polar(t, 44), v = polar(t + 0.03, 36)
                g.line(.poly([u, v]), 0.42)
            }
        }
        // Middle petals: four, pushed slightly down and left of the centre of the flower.
        a = -1.5
        for span in [1.72, 1.45, 1.75, 1.36] {
            crescent(a - 0.22, a + span + 0.14, 14.5, 33, -1, 0.5, 1.03, w * 1.05)
            a += span
        }
        // Inner petals, three, then the tight whorl.
        a = -0.4
        for span in [2.3, 1.9, tau - 4.2] {
            crescent(a - 0.25, a + span + 0.12, 6.5, 19.5, -2, 0, 1.02, w * 0.95)
            a += span
        }
        let whorl = [polar(0.5, 7.8, -2, 0), polar(-0.7, 7.6, -2, 0), polar(-2.1, 7.1, -2, 0), polar(-3.4, 5.8, -2, 0), polar(-4.6, 3.8, -2, 0), polar(-5.8, 2.8, -2, 0), polar(-7, 2, -2, 0), polar(-8.2, 0.9, -2, 0)]
        g.line(.spline(whorl), w * 0.8)
    }

    static func leafShape(_ g: inout DoodleGlyph, tipX: Double, tipY: Double, baseX: Double, baseY: Double, fat: Double, w: Double = 1) {
        let dx = tipX - baseX, dy = tipY - baseY
        let nx = -dy, ny = dx
        func q(_ t: Double, _ s: Double) -> (Double, Double) { (baseX + dx * t + nx * s, baseY + dy * t + ny * s) }
        let a = q(0.3, fat), b = q(0.65, fat * 0.8), c = q(0.65, -fat * 0.8), d = q(0.3, -fat)
        g.shape(1, DoodlePath(nodes: [.init(x: baseX, y: baseY, corner: true), .init(x: a.0, y: a.1, corner: false), .init(x: b.0, y: b.1, corner: false), .init(x: tipX, y: tipY, corner: true),
                                 .init(x: c.0, y: c.1, corner: false), .init(x: d.0, y: d.1, corner: false)], closed: true), w)
        g.line(.spline([(baseX, baseY), q(0.5, 0.02), q(0.88, 0)]), 0.5)
        g.detail(0.13) { g in
            for t in [0.25, 0.45, 0.65] {
                let m = q(t, 0)
                let u = q(t + 0.18, fat * 0.72 * (1 - t * 0.4)), v = q(t + 0.18, -fat * 0.72 * (1 - t * 0.4))
                g.line(.poly([m, u]), 0.38)
                g.line(.poly([m, v]), 0.38)
            }
        }
    }

    static func rose() -> DoodleGlyph {
        var g = DoodleGlyph("rose", 0.18, 0.46, tilt: 26)
        g.must = true
        // Stem with thorns, leaves.
        g.line("54,74 56,96 50,120 ^56,150", 1.25)
        g.line("56,76 58,96 52,120 ^58,150", 0.6)
        g.line("^56,106 ^62,104", 0.9)
        g.line("^52,128 ^46,126", 0.9)
        leafShape(&g, tipX: 96, tipY: 94, baseX: 57, baseY: 110, fat: 0.26)
        leafShape(&g, tipX: 14, tipY: 118, baseX: 52, baseY: 124, fat: 0.26)
        leafShape(&g, tipX: 90, tipY: 132, baseX: 54, baseY: 140, fat: 0.22)
        // Sepals peel down under the head.
        g.shape(1, "^38,66 36,82 ^28,92 44,84 ^54,74 z", 0.95)
        g.shape(1, "^72,66 76,82 ^84,90 68,84 ^56,74 z", 0.95)
        g.shape(1, "^46,70 50,84 ^55,96 60,84 ^66,70 z", 0.95)
        roseHead(&g, cx: 55, cy: 36, r: 44)
        return g
    }

    static func bud() -> DoodleGlyph {
        var g = DoodleGlyph("bud", 0.05, 0.18, tilt: 40)
        g.line("30,50 28,70 ^34,92", 1)
        leafShape(&g, tipX: 56, tipY: 66, baseX: 30, baseY: 74, fat: 0.26, w: 0.85)
        g.shape(1, "^16,34 18,48 30,58 42,48 ^44,34 30,42 z", 1)
        g.shape(0, "^30,0 18,10 13,24 18,38 30,44 42,38 47,24 42,10 z", 1.2)
        g.line("^30,0 24,14 30,28 ^42,38", 0.7)
        g.line("^38,8 32,22 ^22,38", 0.65)
        return g
    }

    static func peony() -> DoodleGlyph {
        var g = DoodleGlyph("peony", 0.13, 0.4, tilt: 180)
        var rng = SplitMix64(seed: 17)
        // Leaves from behind.
        for (a, l) in [(28.0, 62.0), (152.0, 60.0)] {
            let r = a * .pi / 180
            leafShape(&g, tipX: 50 + l * cos(r), tipY: 50 + l * sin(r), baseX: 50 + 20 * cos(r), baseY: 50 + 20 * sin(r), fat: 0.3, w: 0.95)
        }
        // Three rings of ruffled petals, the outside first.
        for (ring, spec) in [(0, (r: 44.0, n: 8, wd: 0.62)), (1, (r: 31.0, n: 7, wd: 0.66)), (2, (r: 19.0, n: 5, wd: 0.72))] {
            let off = rng.next(0, 1)
            for i in 0..<spec.n {
                let a = (Double(i) + off) / Double(spec.n) * 2 * .pi
                let s = 2 * .pi / Double(spec.n) * spec.wd
                let r0 = spec.r * 0.34, r1 = spec.r * rng.next(0.96, 1.05)
                var pts: [(Double, Double)] = []
                func at(_ da: Double, _ rr: Double) -> (Double, Double) { (50 + rr * cos(a + da), 50 + rr * sin(a + da)) }
                pts.append(at(0, r0))
                pts.append(at(-s * 0.86, r1 * 0.72))
                pts.append(at(-s * 0.62, r1 * 0.96))
                pts.append(at(-s * 0.2, r1 * 0.98))
                pts.append(at(0, r1 * 0.92))
                pts.append(at(s * 0.26, r1 * 1.0))
                pts.append(at(s * 0.62, r1 * 0.95))
                pts.append(at(s * 0.86, r1 * 0.72))
                var nodes = pts.map { DoodlePath.Node(x: $0.0, y: $0.1, corner: false) }
                nodes[0].corner = true
                nodes[4].corner = true
                g.shape(ring == 1 ? -1 : 0, DoodlePath(nodes: nodes, closed: true), ring == 0 ? 1.2 : 0.95)
                if ring < 2 {
                    g.detail(0.16) { g in
                        for da in [-0.3, 0.3] {
                            let u = at(da * s, r1 * 0.62), v = at(da * s * 1.3, r1 * 0.88)
                            g.line(.poly([u, v]), 0.42)
                        }
                    }
                }
            }
        }
        // The heart: stamens.
        g.shape(2, .circle(50, 50, 9.5), 0.95)
        for i in 0..<9 {
            let a = Double(i) / 9 * 2 * .pi + 0.2
            g.blot(.circle(50 + 6.2 * cos(a), 50 + 6.2 * sin(a), 1.25))
        }
        g.blot(.circle(50, 50, 2))
        return g
    }

    static func lily() -> DoodleGlyph {
        var g = DoodleGlyph("lily", 0.12, 0.33, tilt: 18)
        // Two broad leaves.
        g.shape(1, "^52,122 30,102 22,70 28,40 ^36,22 46,50 50,84 z", 1.05)
        g.shape(1, "^54,122 74,104 86,78 ^92,44 72,62 58,92 z", 1.05)
        g.detail(0.14) { g in
            g.line("^50,114 36,80 ^34,34", 0.42)
            g.line("^56,114 72,88 ^88,52", 0.42)
            g.line("^44,104 32,76 ^30,50", 0.36)
            g.line("^46,96 40,70 ^36,44", 0.36)
            g.line("^60,110 76,84 ^88,58", 0.36)
            g.line("^64,104 80,80 ^90,62", 0.36)
        }
        // The arching stem and its nodding bells.
        g.line("54,122 58,74 72,34 96,14 ^120,14", 1.1)
        var bells: [(Double, Double, Double)] = [(66, 44, 9.6), (78, 26, 8.8), (92, 16, 8), (106, 13, 6.8), (118, 14, 5.2)]
        bells = bells.map { $0 }
        for (x, y, r) in bells {
            g.line(.spline([(x, y), (x + r * 0.42, y + r * 0.42), (x + r * 0.46, y + r * 0.92)]), 0.7)
            let cx = x + r * 0.46, cy = y + r * 0.92
            g.shape(-1, "^\(cx - r * 0.1),\(cy) \(cx - r * 0.75),\(cy + r * 0.34) \(cx - r * 0.84),\(cy + r * 1.1) ^\(cx - r * 1.08),\(cy + r * 1.62) \(cx - r * 0.55),\(cy + r * 1.42) ^\(cx - r * 0.3),\(cy + r * 1.78) \(cx + r * 0.05),\(cy + r * 1.42) ^\(cx + r * 0.32),\(cy + r * 1.78) \(cx + r * 0.6),\(cy + r * 1.42) ^\(cx + r * 1.1),\(cy + r * 1.6) \(cx + r * 0.84),\(cy + r * 1.1) \(cx + r * 0.7),\(cy + r * 0.34) z", 0.95)
        }
        return g
    }

    static func blossom() -> DoodleGlyph {
        var g = DoodleGlyph("blossom", 0.08, 0.3, tilt: 180)
        for i in 0..<5 {
            let a = Double(i) / 5 * 2 * .pi - .pi / 2
            let s = 0.5
            func at(_ da: Double, _ r: Double) -> (Double, Double) { (50 + r * cos(a + da), 50 + r * sin(a + da)) }
            let pts = [at(0, 6), at(-s * 0.74, 22), at(-s * 0.92, 36), at(-s * 0.56, 47), at(-s * 0.12, 48), at(0, 42), at(s * 0.12, 48), at(s * 0.56, 47), at(s * 0.92, 36), at(s * 0.74, 22)]
            var nodes = pts.map { DoodlePath.Node(x: $0.0, y: $0.1, corner: false) }
            nodes[0].corner = true
            nodes[5].corner = true
            g.shape(0, DoodlePath(nodes: nodes, closed: true), 1.15)
            g.detail(0.11) { g in
                g.line(.poly([at(0, 12), at(0, 34)]), 0.42)
                g.line(.poly([at(-0.18, 14), at(-0.26, 30)]), 0.38)
                g.line(.poly([at(0.18, 14), at(0.26, 30)]), 0.38)
            }
        }
        g.shape(2, .circle(50, 50, 7), 0.8)
        for i in 0..<9 {
            let a = Double(i) / 9 * 2 * .pi + 0.3
            let r = 13.0 + Double(i % 2) * 3
            g.line(.poly([(50 + 4 * cos(a), 50 + 4 * sin(a)), (50 + r * cos(a), 50 + r * sin(a))]), 0.5)
            g.blot(.circle(50 + r * cos(a), 50 + r * sin(a), 1.25))
        }
        return g
    }

    static func daisy() -> DoodleGlyph {
        var g = DoodleGlyph("daisy", 0.07, 0.24, tilt: 30)
        g.line("50,50 54,84 ^48,122", 1.1)
        leafShape(&g, tipX: 86, tipY: 92, baseX: 54, baseY: 102, fat: 0.26, w: 0.9)
        let n = 13
        for pass in 0..<2 {
            for i in 0..<n where i % 2 == pass {
                let a = Double(i) / Double(n) * 2 * .pi
                func at(_ da: Double, _ r: Double) -> (Double, Double) { (50 + r * cos(a + da), 50 + r * sin(a + da)) }
                let len = 48.0 - Double(i % 3)
                g.shape(-1, .spline([at(0, 8), at(-0.2, 24), at(-0.12, len - 4), at(0, len), at(0.12, len - 4), at(0.2, 24)], closed: true), 0.9)
                g.detail(0.1) { $0.line(.poly([at(0, 18), at(0, len - 12)]), 0.38) }
            }
        }
        g.shape(2, .circle(50, 50, 13), 1.05)
        g.detail(0.09) { g in
            for i in 0..<16 {
                let a = Double(i) * 2.4
                let r = 2.2 * sqrt(Double(i + 1))
                g.blot(.circle(50 + r * cos(a), 50 + r * sin(a), 0.75))
            }
        }
        return g
    }

    static func bow() -> DoodleGlyph {
        var g = DoodleGlyph("bow", 0.14, 0.42, tilt: 18)
        g.must = true
        // Tails.
        g.shape(0, "^62,50 52,72 40,96 ^20,122 ^30,122 ^37,114 ^46,124 56,100 68,74 ^70,54 z", 1.2)
        g.shape(0, "^78,50 88,72 100,94 ^122,116 ^110,120 ^106,110 ^94,122 84,100 74,76 ^70,54 z", 1.2)
        g.detail(0.16) { g in
            g.line("^63,62 52,84 ^40,104", 0.45)
            g.line("^77,62 86,84 ^100,104", 0.45)
            g.stitch("^56,66 44,92 ^32,110", dash: 2, gap: 1.8, w: 0.4)
            g.stitch("^84,66 96,90 ^108,108", dash: 2, gap: 1.8, w: 0.4)
        }
        // Inside of the loops.
        g.tint(2, "^64,28 46,20 30,14 14,14 7,26 14,38 30,42 50,48 ^64,46 z")
        g.tint(2, "^76,28 94,20 110,14 126,14 133,26 126,38 110,42 90,48 ^76,46 z")
        g.detail(0.16) { g in
            g.hatch("^30,20 ^56,28 ^58,42 ^40,38 ^20,30 z", angle: 66, gap: 3.2, w: 0.42)
            g.hatch("^110,20 ^84,28 ^82,42 ^100,38 ^120,30 z", angle: 114, gap: 3.2, w: 0.42)
        }
        // The two loops.
        g.shape(0, "^62,28 44,12 22,4 6,8 0,26 4,48 16,62 36,58 ^62,46 50,44 32,38 18,34 12,26 18,18 32,20 ^46,26 z", 1.3)
        g.shape(0, "^78,28 96,12 118,4 134,8 140,26 136,48 124,62 104,58 ^78,46 90,44 108,38 122,34 128,26 122,18 108,20 ^94,26 z", 1.3)
        g.detail(0.16) { g in
            // Creases drawn to the knot, and a row of dots along the silk.
            g.line("^60,36 44,40 ^30,46", 0.5)
            g.line("^60,42 48,48 ^34,52", 0.5)
            g.line("^80,36 96,40 ^110,46", 0.5)
            g.line("^80,42 92,48 ^106,52", 0.5)
            g.hatch("^6,30 ^14,36 ^28,46 ^22,56 ^12,52 z", angle: 64, gap: 2.8, w: 0.45)
            g.hatch("^112,48 ^128,38 ^134,30 ^130,46 ^120,56 z", angle: 64, gap: 2.8, w: 0.45)
            for (x, y) in [(14.0, 12.0), (30.0, 10.0), (44.0, 18.0), (6.0, 38.0)] { g.blot(.circle(x, y, 1.5)) }
            for (x, y) in [(126.0, 12.0), (110.0, 10.0), (96.0, 18.0), (134.0, 38.0)] { g.blot(.circle(x, y, 1.5)) }
        }
        // The deep folds either side of the knot.
        g.accent("^62,28 ^55,24 ^52,27 ^60,34 z")
        g.accent("^78,28 ^85,24 ^88,27 ^80,34 z")
        g.accent("^62,46 ^52,44 ^52,48 ^60,50 z")
        g.accent("^78,46 ^88,44 ^88,48 ^80,50 z")
        // Knot.
        g.shape(0, "^60,27 70,24 80,27 83,38 80,50 70,54 60,50 57,38 z", 1.3)
        g.detail(0.14) { g in
            g.line("^63,30 61,38 ^63,48", 0.5)
            g.line("^77,30 79,38 ^77,48", 0.5)
            g.line("^70,28 69,38 ^70,50", 0.45)
        }
        return g
    }

    static func tinyBow() -> DoodleGlyph {
        var g = DoodleGlyph("tinyBow", 0.035, 0.09, tilt: 26)
        g.shape(0, "^40,22 22,8 6,8 4,26 8,42 ^40,30 z", 1)
        g.shape(0, "^44,22 62,8 78,8 80,26 76,42 ^44,30 z", 1)
        g.shape(0, "^40,20 44,20 48,24 46,32 42,34 37,32 36,24 z", 1)
        g.line("^38,32 30,48 ^22,60", 0.9)
        g.line("^46,32 54,48 ^62,60", 0.9)
        return g
    }

    static func ribbon() -> DoodleGlyph {
        var g = DoodleGlyph("ribbon", 0.15, 0.42, tilt: 40)
        g.must = true
        // A length of silk in three runs: a swallowtail, a loop and a free end.
        g.shape(2, "^4,84 ^-14,100 ^-2,102 ^-6,118 ^14,110 ^26,100 z", 1.15)
        g.shape(2, "^114,50 ^136,38 ^124,32 ^130,14 ^108,22 ^94,30 z", 1.15)
        // The back of the fold, in shadow.
        g.shape(1, "^24,92 ^18,74 ^44,58 ^50,76 z", 0.95)
        g.shape(1, "^98,44 ^102,62 ^76,74 ^70,56 z", 0.95)
        g.detail(0.16) { g in
            g.hatch("^24,88 ^20,76 ^44,60 ^48,74 z", angle: 30, gap: 2.8, w: 0.45)
            g.hatch("^98,48 ^101,60 ^77,72 ^72,58 z", angle: 30, gap: 2.8, w: 0.45)
        }
        // The long face that crosses the middle, with two ribs along it.
        g.shape(0, "^4,84 24,68 46,62 70,62 94,46 ^112,30 ^120,50 102,68 76,84 50,84 30,88 ^14,102 z", 1.3)
        g.detail(0.16) { g in
            g.line("^12,88 28,76 50,70 72,72 96,56 ^114,40", 0.42)
            g.line("^14,96 30,82 52,78 74,78 100,62 ^118,46", 0.42)
            for (x, y, r) in [(34.0, 79.0, 2.0), (52.0, 74.5, 2.2), (70.0, 76.0, 2.2), (88.0, 66.0, 2.0)] {
                g.blot(DoodleFillers.heartPath(x, y, r))
            }
        }
        return g
    }

    static func facetGem(_ g: inout DoodleGlyph, sep: Int = 0, w: Double = 1) {
        // Outline: table on top, girdle, down to the culet.
        let tl = (24.0, 6.0), tr = (76.0, 6.0), gl = (0.0, 34.0), gr = (100.0, 34.0), cul = (50.0, 96.0)
        g.shape(-1, .poly([tl, tr, gr, cul, gl], closed: true), 1.4 * w)
        // Spot-colour facets, every other one.
        let crown: [(Double, Double)] = [(0, 34), (18, 34), (34, 34), (50, 34), (66, 34), (82, 34), (100, 34)]
        g.tint(sep, .poly([(24, 6), (34, 34), (18, 34), (0, 34)], closed: true))
        g.tint(sep, .poly([(50, 6), (66, 34), (34, 34)], closed: true))
        g.tint(sep, .poly([(76, 6), (100, 34), (82, 34), (66, 34)], closed: true))
        g.tint(sep, .poly([(0, 34), (18, 34), (50, 96)], closed: true))
        g.tint(sep, .poly([(34, 34), (50, 34), (50, 96)], closed: true))
        g.tint(sep, .poly([(66, 34), (82, 34), (50, 96)], closed: true))
        _ = crown
        g.line(.poly([gl, gr]), 0.9 * w)
        // Crown facets, zigzag.
        g.line(.poly([tl, (34, 34), (50, 6), (66, 34), tr]), 0.72 * w)
        g.line(.poly([tl, (18, 34)]), 0.5 * w)
        g.line(.poly([tr, (82, 34)]), 0.5 * w)
        // Pavilion.
        for x in [18.0, 34.0, 50.0, 66.0, 82.0] { g.line(.poly([(x, 34), cul]), x == 50 ? 0.5 : 0.62) }
        g.detail(0.12) { g in
            g.hatch(.poly([(66, 34), (82, 34), (50, 96)], closed: true), angle: 68, gap: 2.6, w: 0.42)
            g.hatch(.poly([(82, 34), (100, 34), (50, 96)], closed: true), angle: 112, gap: 3.4, w: 0.38)
        }
        g.gel(.poly([(30, 10), (24, 22)]), 0.8)
        g.gel(.poly([(20, 42), (32, 62)]), 0.7)
    }

    static func gem() -> DoodleGlyph {
        var g = DoodleGlyph("gem", 0.1, 0.31, tilt: 26)
        g.must = true
        g.whole = true
        facetGem(&g)
        g.blot(DoodleFillers.sparklePath(106, 2, 8, 0.18))
        g.blot(DoodleFillers.sparklePath(-6, 72, 5.5, 0.18))
        g.line("^92,74 ^97,70", 0.7)
        g.line("^88,86 ^95,84", 0.7)
        return g
    }

    static func heartGem() -> DoodleGlyph {
        var g = DoodleGlyph("heartGem", 0.08, 0.28, tilt: 28)
        g.whole = true
        g.shape(0, "^50,22 ^34,4 ^12,6 ^0,22 ^2,42 ^50,98 ^98,42 ^100,22 ^88,6 ^66,4 z", 1.4)
        g.shape(-1, "^50,32 ^36,18 ^20,20 ^14,30 ^20,42 ^50,58 ^80,42 ^86,30 ^80,20 ^64,18 z", 0.85)
        for (a, b) in [((50.0, 22.0), (50.0, 32.0)), ((34.0, 4.0), (36.0, 18.0)), ((12.0, 6.0), (20.0, 20.0)), ((0.0, 22.0), (14.0, 30.0)), ((2.0, 42.0), (20.0, 42.0)),
                       ((66.0, 4.0), (64.0, 18.0)), ((88.0, 6.0), (80.0, 20.0)), ((100.0, 22.0), (86.0, 30.0)), ((98.0, 42.0), (80.0, 42.0)), ((50.0, 98.0), (50.0, 58.0)),
                       ((50.0, 98.0), (20.0, 42.0)), ((50.0, 98.0), (80.0, 42.0))] {
            g.line(.poly([a, b]), 0.6)
        }
        g.detail(0.1) { g in
            g.hatch(.poly([(50, 98), (80, 42), (50, 58)], closed: true), angle: 66, gap: 2.8, w: 0.42)
            g.gel(.poly([(26, 26), (32, 24), (38, 30)]), 0.7)
        }
        return g
    }

    static func emerald() -> DoodleGlyph {
        var g = DoodleGlyph("emerald", 0.07, 0.24, tilt: 34)
        g.shape(1, "^16,0 ^64,0 ^80,16 ^80,84 ^64,100 ^16,100 ^0,84 ^0,16 z", 1.35)
        g.shape(-1, "^22,12 ^58,12 ^68,22 ^68,78 ^58,88 ^22,88 ^12,78 ^12,22 z", 0.8)
        g.shape(1, "^28,24 ^52,24 ^56,28 ^56,72 ^52,76 ^28,76 ^24,72 ^24,28 z", 0.8)
        for (a, b, c) in [((16.0, 0.0), (22.0, 12.0), (28.0, 24.0)), ((64.0, 0.0), (58.0, 12.0), (52.0, 24.0)), ((80.0, 16.0), (68.0, 22.0), (56.0, 28.0)), ((80.0, 84.0), (68.0, 78.0), (56.0, 72.0)),
                          ((64.0, 100.0), (58.0, 88.0), (52.0, 76.0)), ((16.0, 100.0), (22.0, 88.0), (28.0, 76.0)), ((0.0, 84.0), (12.0, 78.0), (24.0, 72.0)), ((0.0, 16.0), (12.0, 22.0), (24.0, 28.0))] {
            g.line(.poly([a, b, c]), 0.55)
        }
        g.detail(0.09) { g in
            g.gel(.poly([(30, 30), (30, 46)]), 0.8)
            g.hatch(.poly([(44, 26), (54, 26), (54, 74), (44, 74)], closed: true), angle: 64, gap: 2.8, w: 0.42)
        }
        return g
    }

    static func perfume() -> DoodleGlyph {
        var g = DoodleGlyph("perfume", 0.15, 0.44, tilt: 12)
        g.must = true
        // A thick tube, a small ribbed bulb close to the bottle, a short tassel.
        g.shape(2, DoodlePath.taper([(54, 22), (64, 16), (76, 20)], 5, 5), 0.95)
        g.shape(0, .ellipse(88, 26, 13, 14), 1.25)
        g.detail(0.16) { g in
            g.line("^81,15 79,26 ^82,38", 0.45)
            g.line("^88,12.6 87,26 ^88,39.6", 0.45)
            g.line("^95,15 96.5,26 ^94,38", 0.45)
        }
        g.line("^88,40 ^88,44", 0.8)
        g.shape(2, "^85,44 ^91,44 ^92,52 ^90.5,51 ^88,53 ^85.5,51 ^84,52 z", 0.75)
        // Collar and atomizer head.
        g.shape(2, .rrect(38, 15, 18, 15, 3), 1.05)
        g.shape(2, .rrect(41, 6, 12, 9, 2), 0.9)
        g.line("^41,10 ^32,10", 0.9)
        g.blot(.circle(30.8, 10, 1.4))
        g.detail(0.15) { g in
            g.line("^42,16 ^42,29", 0.42)
            g.line("^47,16 ^47,29", 0.42)
            g.line("^52,16 ^52,29", 0.42)
            // Three puffs of scent.
            g.blot(.circle(23, 8, 1.2))
            g.blot(.circle(17, 4, 1))
            g.blot(.circle(16, 12, 1))
            g.blot(.circle(10, 8, 0.8))
        }
        g.shape(-1, .rrect(36, 28, 22, 10, 2), 0.95)
        // The cut-glass body, shoulders faceted.
        g.shape(-1, "^28,38 ^66,38 ^80,50 ^84,66 ^84,114 ^72,126 ^22,126 ^10,114 ^10,66 ^14,50 z", 1.4)
        // Scent inside, with a meniscus.
        g.tint(0, "^14,64 30,62 47,65 64,62 ^80,64 ^80,112 ^70,122 ^24,122 ^14,112 z")
        g.line("^14,64 30,62 47,65 64,62 ^80,64", 0.6)
        // Dip tube.
        g.line("^47,38 ^47,108", 0.5)
        // Facets.
        g.line("^14,50 ^80,50", 0.6)
        g.line("^28,38 ^22,50", 0.5)
        g.line("^66,38 ^72,50", 0.5)
        g.line("^10,66 ^14,50", 0.5)
        g.line("^84,66 ^80,50", 0.5)
        g.line("^22,126 ^24,118 ^70,118 ^72,126", 0.55)
        // A label with a little flower, no name.
        g.shape(-1, .rrect(27, 76, 40, 30, 3), 0.9)
        g.line(.rrect(30, 79, 34, 24, 2), 0.42)
        g.blot(DoodleFillers.heartPath(47, 90, 5.4))
        g.detail(0.15) { g in
            g.gel("^18,56 ^18,108", 1)
            g.gel("^24,54 ^24,70", 0.6)
            g.hatch("^70,68 ^80,66 ^80,112 ^70,120 z", angle: 66, gap: 2.8, w: 0.45)
        }
        return g
    }

    static func flacon() -> DoodleGlyph {
        var g = DoodleGlyph("flacon", 0.1, 0.34, tilt: 16)
        // Stopper, a faceted ball, and a bow around the neck.
        g.shape(-1, .ellipse(40, 14, 13, 14), 1.25)
        g.line("^28,12 ^52,12", 0.5)
        g.line("^33,3 ^28,12 ^40,27 ^52,12 ^47,3", 0.5)
        g.line("^40,0 ^40,12", 0.4)
        g.shape(2, .rrect(30, 28, 20, 8, 2), 0.95)
        g.shape(2, .rrect(33, 36, 14, 10, 1), 0.9)
        // A heart-shaped flask.
        g.shape(0, "^40,56 52,42 70,42 82,56 82,76 66,100 ^40,124 14,100 -2,76 -2,56 10,42 28,42 z", 1.4)
        g.shape(-1, "^40,64 52,52 66,52 74,60 73,75 60,94 ^40,112 20,94 7,75 6,60 14,52 28,52 z", 0.75)
        g.tint(0, "^8,78 40,76 ^72,78 60,94 ^40,112 20,94 z")
        g.line("^8,78 24,75 40,78 56,75 ^72,78", 0.55)
        g.detail(0.13) { g in
            g.gel("14,60 12,68 ^17,80", 1)
            g.hatch("^58,84 ^70,76 62,94 ^44,108 z", angle: 66, gap: 2.8, w: 0.45)
        }
        // Ribbon tied at the neck.
        g.shape(1, "^38,40 26,32 14,34 14,44 26,46 ^38,42 z", 0.95)
        g.shape(1, "^42,40 54,32 66,34 66,44 54,46 ^42,42 z", 0.95)
        g.shape(1, .rrect(36, 37, 8, 8, 2), 0.95)
        g.line("^36,44 ^26,62", 0.8)
        g.line("^44,44 ^54,62", 0.8)
        return g
    }

    static func lipstick() -> DoodleGlyph {
        var g = DoodleGlyph("lipstick", 0.09, 0.32, tilt: 26)
        g.whole = true
        // Bullet, slanted.
        g.shape(0, "^16,44 ^16,18 22,6 ^38,0 40,12 ^40,44 z", 1.25)
        g.line("^16,18 26,10 ^38,1", 0.55)
        g.gel("^21,26 ^21,40", 0.8)
        g.detail(0.12) { $0.hatch("^31,16 ^39,10 ^39,44 ^31,44 z", angle: 66, gap: 2.6, w: 0.42) }
        // Metal sleeve.
        g.shape(2, .rrect(12, 44, 32, 24, 1.5), 1.25)
        g.line("^12,50 ^44,50", 0.5)
        g.detail(0.12) { g in
            g.gel("^18,54 ^18,64", 0.9)
            for x in [34.0, 37.5, 41.0] { g.line("^\(x),51 ^\(x),67", 0.42) }
        }
        // Base with a quilted pattern.
        g.shape(0, .rrect(6, 68, 44, 52, 2), 1.35)
        g.shape(2, .rrect(4, 68, 48, 7, 1.5), 0.95)
        g.detail(0.1) { g in
            g.hatch("^8,78 ^48,78 ^48,118 ^8,118 z", angle: 45, gap: 8.4, w: 0.42)
            g.hatch("^8,78 ^48,78 ^48,118 ^8,118 z", angle: 135, gap: 8.4, w: 0.42)
        }
        return g
    }

    static func mirror() -> DoodleGlyph {
        var g = DoodleGlyph("mirror", 0.1, 0.34, tilt: 34)
        // Handle.
        g.shape(2, "^34,84 ^46,84 47,100 44,118 ^48,130 40,136 ^32,130 36,118 33,100 z", 1.25)
        g.line("^34,94 ^46,94", 0.5)
        g.line("^36,114 ^44,114", 0.5)
        g.blot(.circle(40, 125, 1.6))
        // The frame: a ring with scallops.
        var pts: [DoodlePath.Node] = []
        let n = 18
        for i in 0..<n {
            let a = Double(i) / Double(n) * 2 * .pi
            let r = i % 2 == 0 ? 40.5 : 44.0
            pts.append(.init(x: 40 + r * 0.92 * cos(a), y: 44 + r * sin(a), corner: i % 2 == 0))
        }
        g.shape(0, DoodlePath(nodes: pts, closed: true), 1.3)
        g.detail(0.12) { g in
            for i in 0..<n where i % 2 == 1 {
                let a = Double(i) / Double(n) * 2 * .pi
                g.blot(.circle(40 + 37.5 * 0.92 * cos(a), 44 + 37.5 * sin(a), 1.2))
            }
        }
        g.shape(-1, .ellipse(40, 44, 31.4, 34.4), 1.05)
        // Glass: diagonal gleams, a heart caught in it.
        g.gel("^22,26 ^16,48", 1.1)
        g.gel("^28,20 ^24,30", 0.9)
        g.line("^40,18 ^12,58", 0.45)
        g.line("^50,20 ^16,68", 0.45)
        g.line("^70,44 ^48,74", 0.45)
        g.line("^68,54 ^56,72", 0.45)
        g.tint(0, DoodleFillers.heartPath(46, 46, 10))
        g.line(DoodleFillers.heartPath(46, 46, 10), 0.6)
        return g
    }

    static func ring() -> DoodleGlyph {
        var g = DoodleGlyph("ring", 0.08, 0.26, tilt: 26)
        g.keepClear(.ellipse(44, 66, 28, 29))
        // The band, thick at the bottom.
        g.band(2, outer: .ellipse(44, 68, 37, 37), inner: .ellipse(44, 66, 28, 29), 1.3, innerW: 1)
        g.detail(0.1) { g in
            g.hatch("^56,88 ^72,76 ^78,66 ^74,84 ^56,102 z", angle: 66, gap: 2.8, w: 0.42)
            g.gel("^14,74 18,86 ^26,94", 0.9)
        }
        // Setting: claws holding a stone.
        g.shape(2, "^24,36 ^64,36 ^56,46 ^32,46 z", 1)
        g.line("^38,38 ^38,46", 0.45)
        g.line("^50,38 ^50,46", 0.45)
        g.shape(-1, "^28,6 ^60,6 ^74,22 ^44,40 ^14,22 z", 1.3)
        g.tint(0, "^28,6 ^36,22 ^14,22 z")
        g.tint(0, "^44,6 ^52,22 ^36,22 z")
        g.tint(0, "^60,6 ^74,22 ^52,22 z")
        g.tint(0, "^36,22 ^44,40 ^14,22 z")
        g.line("^14,22 ^74,22", 0.65)
        g.line("^28,6 ^36,22 ^44,6 ^52,22 ^60,6", 0.55)
        g.line("^36,22 ^44,40 ^52,22", 0.5)
        g.blot(DoodleFillers.sparklePath(82, 8, 7, 0.18))
        g.blot(DoodleFillers.sparklePath(5, 8, 4.5, 0.18))
        return g
    }

    static func pearls() -> DoodleGlyph {
        var g = DoodleGlyph("pearls", 0.14, 0.38, tilt: 16)
        // A drape of pearls with a drop, tied in a bow at the clasp.
        let n = 19
        var mid = (0.0, 0.0)
        for i in stride(from: 0, to: n, by: 1) {
            let t = Double(i) / Double(n - 1)
            let a = .pi * (0.02 + 0.96 * t)
            let x = 56 - 54 * cos(a), y = 6 + 62 * pow(sin(a), 1.0) + 6 * sin(t * 12)
            let r = 4.8 + 2.0 * sin(a)
            g.shape(-1, .circle(x, y, r), 0.95)
            g.detail(0.14) { $0.gel(.circle(x - r * 0.35, y - r * 0.35, r * 0.2), 0.4) }
            if i == n / 2 { mid = (x, y) }
        }
        // The drop.
        g.shape(2, .rrect(mid.0 - 3.5, mid.1 + 6, 7, 6, 1.5), 0.85)
        g.shape(0, "\(mid.0),\(mid.1 + 11) \(mid.0 + 7),\(mid.1 + 22) \(mid.0 + 8),\(mid.1 + 30) \(mid.0),\(mid.1 + 37) \(mid.0 - 8),\(mid.1 + 30) \(mid.0 - 7),\(mid.1 + 22) z", 1.15)
        g.gel("\(mid.0 - 3),\(mid.1 + 22) \(mid.0 - 4),\(mid.1 + 30)", 0.8)
        // A clasp where the strand ends.
        g.line("2,8 4,-6 ^10,-12", 0.7)
        g.line("110,8 108,-6 ^102,-12", 0.7)
        g.shape(2, .ellipse(56, -14, 6, 3.4), 0.85)
        g.line("10,-12 30,-18 ^50,-15", 0.5)
        g.line("102,-12 82,-18 ^62,-15", 0.5)
        return g
    }

    static func letter() -> DoodleGlyph {
        var g = DoodleGlyph("letter", 0.1, 0.32, tilt: 28)
        // A note slips out of it.
        g.shape(-1, "^18,-14 ^86,-22 ^92,28 ^20,34 z", 1.05)
        g.line("^28,-4 50,-6 ^74,-10", 0.6)
        g.line("^29,4 60,0 ^76,-2", 0.6)
        g.line("^30,12 ^54,9", 0.6)
        // Envelope.
        g.shape(0, "^2,18 ^104,18 ^104,84 ^2,84 z", 1.35)
        g.tint(-1, "^2,84 ^40,52 ^66,52 ^104,84 z")
        g.line("^2,84 ^40,50", 0.85)
        g.line("^104,84 ^66,50", 0.85)
        g.shape(-1, "^2,18 ^104,18 ^53,62 z", 1.2)
        g.detail(0.12) { g in
            g.stitch("^8,22 ^53,57 ^98,22", dash: 2.2, gap: 1.8, w: 0.42)
            g.hatch("^76,62 ^102,40 ^102,82 ^92,82 z", angle: 66, gap: 3, w: 0.42)
        }
        // Wax seal: a blob with a heart in it.
        g.shape(2, "53,46 60,48 66,46 68,54 72,60 66,66 66,72 59,72 53,76 47,72 40,72 40,66 34,60 38,54 40,46 46,48 z", 1.15)
        g.blot(DoodleFillers.heartPath(53, 60, 6.4))
        return g
    }

    static func locket() -> DoodleGlyph {
        var g = DoodleGlyph("locket", 0.08, 0.28, tilt: 22)
        // Chain: little links down to the bail.
        for i in 0..<7 {
            let t = Double(i) / 6
            let y = -6 + t * 34
            let lx = 50 - 40 * (1 - t) * (1 - t) * 1.0
            let rx = 50 + 40 * (1 - t) * (1 - t) * 1.0
            g.line(.ellipse(lx, y, 3, 2, rot: 40 * (1 - t), count: 6), 0.55)
            g.line(.ellipse(rx, y, 3, 2, rot: -40 * (1 - t), count: 6), 0.55)
        }
        g.shape(2, .rrect(46, 26, 8, 9, 3), 0.95)
        // A heart with a raised rim and engraving.
        g.shape(2, DoodleFillers.heartPath(50, 66, 34), 1.4)
        g.shape(0, DoodleFillers.heartPath(50, 66, 26), 0.8)
        g.detail(0.1) { g in
            for i in 0..<5 {
                let a = Double(i) / 5 * 2 * .pi - .pi / 2
                g.line(.ellipse(50 + 7.4 * cos(a), 62 + 7.4 * sin(a), 4.8, 4.8), 0.5)
            }
            g.blot(.circle(50, 62, 2.4))
            g.gel("^28,50 32,46", 0.8)
            g.hatch("^56,74 ^70,62 ^60,78 ^50,90 z", angle: 66, gap: 2.6, w: 0.42)
        }
        g.line("^83,64 ^86,66 ^83,68", 0.7)
        return g
    }

    static func teacup() -> DoodleGlyph {
        var g = DoodleGlyph("teacup", 0.11, 0.34, tilt: 12)
        // Steam in two thin curls.
        g.line("36,8 32,0 36,-8 32,-16", 0.7)
        g.line("54,10 58,2 54,-6 58,-14", 0.7)
        // Saucer behind.
        g.shape(-1, "^-10,70 18,76 46,78 74,76 ^102,70 92,84 62,90 30,90 0,84 z", 1.2)
        g.detail(0.13) { g in
            g.line("^0,76 28,84 62,84 ^92,76", 0.42)
            g.stitch("^2,79 30,87 62,87 ^90,79", dash: 2, gap: 2, w: 0.42)
        }
        // Handle.
        g.line("86,30 102,28 108,40 100,54 ^78,62", 1.3)
        g.line("86,36 98,35 101,42 95,50 ^80,56", 0.8)
        // The cup: a low, flared bowl.
        g.shape(-1, "^2,24 ^90,24 88,46 78,66 ^62,78 ^30,78 14,66 4,46 z", 1.35)
        g.shape(0, .ellipse(46, 24, 44, 8.6), 1.15)
        g.shape(2, .ellipse(46, 25, 37, 5.4), 0.7)
        // A wreath around it.
        for (x, y, r) in [(26.0, 52.0, 8.0), (50.0, 58.0, 9.0), (70.0, 50.0, 7.0)] {
            g.shape(0, .circle(x, y, r), 0.75)
            g.line(.spline([(x - r * 0.4, y), (x, y - r * 0.4), (x + r * 0.4, y), (x, y + r * 0.3), (x - r * 0.1, y)]), 0.5)
        }
        g.detail(0.13) { g in
            g.shape(1, "^36,46 40,40 ^46,40 44,47 z", 0.55)
            g.shape(1, "^60,48 62,42 ^68,38 66,46 z", 0.55)
            g.shape(1, "^38,62 34,68 ^28,68 32,62 z", 0.55)
            g.hatch("^72,34 ^86,32 ^82,52 ^72,70 ^66,72 z", angle: 66, gap: 3, w: 0.42)
            g.gel("^12,34 ^16,50", 0.9)
        }
        g.shape(0, .ellipse(46, 79, 16, 3.2), 0.9)
        return g
    }

    static func cherries() -> DoodleGlyph {
        var g = DoodleGlyph("cherries", 0.07, 0.26, tilt: 26)
        g.line("26,60 30,36 48,12 ^56,2", 1.1)
        g.line("72,66 68,38 60,16 ^56,2", 1.1)
        leafShape(&g, tipX: 100, tipY: 14, baseX: 56, baseY: 3, fat: 0.26)
        g.shape(0, "24,60 34,58 44,64 48,76 44,90 32,98 18,96 6,86 4,72 12,62 z", 1.35)
        g.shape(0, "70,66 82,62 92,68 98,82 92,96 80,104 66,102 54,92 52,78 60,68 z", 1.35)
        g.line("16,66 24,62 ^30,64", 0.75)
        g.line("64,72 72,68 ^78,70", 0.75)
        g.gel("12,76 14,84 ^18,88", 1.1)
        g.gel("60,82 62,90 ^66,94", 1.1)
        g.detail(0.1) { g in
            g.hatch("^36,70 ^46,70 ^42,88 ^30,96 z", angle: 66, gap: 2.8, w: 0.42)
            g.hatch("^82,76 ^94,76 ^90,94 ^76,102 z", angle: 66, gap: 2.8, w: 0.42)
        }
        return g
    }

    static func strawberry() -> DoodleGlyph {
        var g = DoodleGlyph("strawberry", 0.06, 0.24, tilt: 34)
        g.shape(0, "^40,18 56,14 72,20 78,36 74,56 62,78 ^40,96 22,80 8,56 2,36 8,20 24,14 z", 1.35)
        g.detail(0.08) { g in
            var y = 28.0
            var row = 0
            while y < 88 {
                let half = 34.0 * (1 - pow((y - 22) / 76, 2.2))
                var x = 40 - half + (row % 2 == 0 ? 0 : 6.5)
                while x < 40 + half {
                    g.line(.poly([(x, y), (x + 0.6, y + 4)]), 0.72)
                    x += 13
                }
                y += 11
                row += 1
            }
            g.gel("10,32 11,44 ^15,54", 1.1)
        }
        g.shape(1, "^40,20 28,28 ^26,18 12,20 ^18,8 ^10,0 26,2 ^38,8 ^38,-4 ^44,-4 ^44,8 54,2 ^70,0 ^62,8 ^68,20 ^54,18 ^52,28 z", 1.1)
        return g
    }

    static func handbag() -> DoodleGlyph {
        var g = DoodleGlyph("handbag", 0.13, 0.38, tilt: 16)
        // Chain handle, a run of links.
        var i = 0
        while i <= 14 {
            let t = Double(i) / 14
            let a = .pi * t
            let x = 50 - 36 * cos(a), y = 44 - 42 * sin(a)
            g.line(.ellipse(x, y, i % 2 == 0 ? 3.2 : 2, i % 2 == 0 ? 2 : 3.2, rot: t * 180 - 90, count: 6), 0.6)
            i += 1
        }
        // Body, quilted.
        g.shape(0, "^6,42 ^94,42 100,62 ^100,108 94,114 ^6,114 0,108 ^0,62 z", 1.4)
        g.detail(0.14) { g in
            g.hatch("^2,60 ^98,60 ^98,112 ^2,112 z", angle: 45, gap: 11.5, w: 0.5)
            g.hatch("^2,60 ^98,60 ^98,112 ^2,112 z", angle: 135, gap: 11.5, w: 0.5)
            g.stitch("^3,110 ^97,110", dash: 2, gap: 1.8, w: 0.4)
        }
        // Flap.
        g.shape(0, "^6,42 ^94,42 96,60 ^84,70 50,78 ^16,70 4,60 z", 1.25)
        g.detail(0.14) { g in
            g.stitch("^10,46 ^90,46 91,58 ^81,66 50,73 ^19,66 9,58 z", dash: 2, gap: 1.8, w: 0.42)
            g.gel("^14,50 ^30,50", 0.8)
            for (x, y) in [(24.0, 56.0), (50.0, 56.0), (76.0, 56.0)] {
                g.line("^\(x - 3),\(y) ^\(x + 3),\(y)", 0.5)
                g.line("^\(x),\(y - 3) ^\(x),\(y + 3)", 0.5)
            }
        }
        // Clasp: a plain turn-lock.
        g.shape(2, .rrect(41, 68, 18, 16, 3), 1.05)
        g.shape(-1, .ellipse(50, 76, 4.2, 5), 0.7)
        return g
    }

    static func tiara() -> DoodleGlyph {
        var g = DoodleGlyph("tiara", 0.1, 0.34, tilt: 20)
        g.shape(2, "^0,74 ^10,40 ^26,62 ^34,22 ^50,48 ^60,4 ^70,48 ^86,22 ^94,62 ^110,40 ^120,74 95,84 60,88 25,84 z", 1.35)
        g.line("^4,70 25,78 60,82 95,78 ^116,70", 0.6)
        g.detail(0.12) { g in
            for x in stride(from: 18.0, through: 102.0, by: 12.0) {
                let y = 68 + 12 * (1 - pow((x - 60) / 58, 2))
                g.blot(.circle(x, y - 3, 1.4))
            }
            g.line("^24,66 ^22,50", 0.42)
            g.line("^94,66 ^96,50", 0.42)
            g.line("^52,60 ^56,38", 0.42)
            g.line("^68,60 ^64,38", 0.42)
        }
        // Jewels at each point and a big drop in the middle.
        g.shape(-1, .circle(60, 8, 6), 1)
        g.shape(-1, .circle(34, 26, 4.8), 0.9)
        g.shape(-1, .circle(86, 26, 4.8), 0.9)
        g.shape(-1, .circle(10, 42, 3.8), 0.85)
        g.shape(-1, .circle(110, 42, 3.8), 0.85)
        g.shape(0, "60,34 67,48 65,60 60,66 55,60 53,48 z", 1.05)
        g.line("^60,34 ^60,66", 0.42)
        g.line("^53,50 ^67,50", 0.42)
        g.gel(.circle(58, 6, 1), 0.5)
        return g
    }

    static func cupcake() -> DoodleGlyph {
        var g = DoodleGlyph("cupcake", 0.09, 0.3, tilt: 20)
        // Wrapper, pleated.
        g.shape(2, "^12,56 ^88,56 ^78,108 ^22,108 z", 1.3)
        g.detail(0.1) { g in
            for i in 0..<8 {
                let t = (Double(i) + 0.5) / 8
                g.line(.poly([(12 + 76 * t, 56), (22 + 56 * t, 108)]), 0.55)
            }
        }
        // Three tiers of frosting.
        g.shape(-1, "^6,52 10,40 26,36 50,34 74,36 90,40 94,52 88,62 76,58 66,64 54,58 44,64 32,58 22,64 12,60 z", 1.3)
        g.shape(-1, "^18,36 20,26 34,20 50,18 66,20 80,26 82,36 70,44 50,40 30,44 z", 1.2)
        g.shape(0, "^30,20 34,12 50,6 66,12 70,20 56,26 44,26 z", 1.1)
        g.detail(0.1) { g in
            g.line("^20,46 40,50 ^62,46", 0.45)
            g.line("^34,30 54,32 ^70,28", 0.45)
            for (x, y, a) in [(14.0, 48.0, 20.0), (28.0, 52.0, -30.0), (46.0, 44.0, 60.0), (66.0, 52.0, -10.0), (82.0, 48.0, 40.0), (26.0, 30.0, 10.0), (60.0, 30.0, -40.0), (74.0, 34.0, 70.0)] {
                let r = a * .pi / 180
                g.line(.poly([(x - 2.6 * cos(r), y - 2.6 * sin(r)), (x + 2.6 * cos(r), y + 2.6 * sin(r))]), 0.85)
            }
        }
        // A cherry on it.
        g.shape(0, .circle(50, -2, 9), 1.15)
        g.line("50,-10 54,-20 ^62,-24", 0.85)
        g.gel("^45,-6 ^44,-1", 0.8)
        return g
    }

    static func sprig() -> DoodleGlyph {
        var g = DoodleGlyph("sprig", 0.05, 0.2, tilt: 70)
        g.line("10,86 22,62 36,40 ^56,10", 0.95)
        for (bx, by, tx, ty) in [(20.0, 66.0, 0.0, 46.0), (26.0, 56.0, 50.0, 56.0), (32.0, 46.0, 14.0, 22.0), (38.0, 38.0, 64.0, 34.0), (46.0, 25.0, 34.0, 0.0), (56.0, 10.0, 70.0, 0.0)] {
            leafShape(&g, tipX: tx, tipY: ty, baseX: bx, baseY: by, fat: 0.28, w: 0.85)
        }
        return g
    }

    static func moth() -> DoodleGlyph {
        var g = DoodleGlyph("moth", 0.05, 0.14, tilt: 40)
        g.mirror(40) { g in
            g.shape(0, "^38,28 22,14 6,12 2,26 12,38 ^36,36 z", 1)
            g.shape(2, "^38,36 20,40 12,50 20,62 32,58 ^38,44 z", 0.9)
            g.line("39,20 34,8 ^28,4", 0.7)
        }
        g.shape(1, .ellipse(40, 36, 3, 16), 0.95)
        return g
    }

    static func petal() -> DoodleGlyph {
        var g = DoodleGlyph("petal", 0.022, 0.06, tilt: 90)
        g.shape(0, "^10,30 0,18 4,4 14,0 20,8 22,20 z", 0.85)
        g.line("^10,26 ^12,10", 0.45)
        return g
    }

    static func tinyFlower() -> DoodleGlyph {
        var g = DoodleGlyph("tinyFlower", 0.03, 0.08, tilt: 40)
        for i in 0..<5 {
            let a = Double(i) / 5 * 2 * .pi - .pi / 2
            g.shape(-1, .ellipse(20 + 11 * cos(a), 20 + 11 * sin(a), 7.5, 7.5), 0.85)
        }
        g.shape(2, .circle(20, 20, 4.6), 0.8)
        return g
    }

    static func tinyHeart() -> DoodleGlyph {
        var g = DoodleGlyph("tinyHeart", 0.022, 0.06, tilt: 26)
        g.shape(0, DoodleFillers.heartPath(0, 0, 20), 0.85)
        return g
    }
}
