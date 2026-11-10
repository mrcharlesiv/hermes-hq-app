// More of the woodland: animals and camp things that took over from the climbing gear, drawn in the same hand as DoodleForest.
// Spots keep their meaning: 0 foliage, 1 wood and earth, 2 warm accent.

import CoreGraphics
import Foundation

nonisolated extension DoodleForest {
    /// A bushy tail along the curve through `center`: its outline, tufted on the outer side, and a way to cut bands across it.
    static func plume(_ center: [(Double, Double)], widths: [Double], tuft: Double, seed: UInt64) -> (outline: DoodlePath, band: (Double, Double) -> DoodlePath) {
        let line = DoodlePath.spline(center).flattened(step: 1.4).ring
        let n = line.count
        func width(_ t: Double) -> Double {
            let f = min(0.9999, max(0, t)) * Double(widths.count - 1)
            let i = Int(f)
            return widths[i] + (widths[i + 1] - widths[i]) * (f - Double(i))
        }
        func point(_ t: Double, _ side: Double) -> (Double, Double) {
            let f = min(Double(n - 1), max(0, t * Double(n - 1)))
            let i = Int(f), j = min(n - 1, i + 1)
            let x = line[i].x + (line[j].x - line[i].x) * (f - Double(i)), y = line[i].y + (line[j].y - line[i].y) * (f - Double(i))
            let a = line[max(0, i - 1)], b = line[min(n - 1, i + 2)]
            let dx = b.x - a.x, dy = b.y - a.y, l = max(1e-6, hypot(dx, dy))
            let w = width(t) / 2 * side
            return (x + dy / l * w, y - dx / l * w)
        }
        var rng = SplitMix64(seed: seed)
        var nodes: [DoodlePath.Node] = []
        // Up the outer edge in soft tufts, each one lying along the fur.
        var t = 0.0
        let first = point(0, 1)
        nodes.append(.init(x: first.0, y: first.1, corner: true))
        while t < 0.98 {
            let step = 0.075 * rng.next(0.8, 1.25)
            let mid = point(t + step * 0.55, 1), tip = point(min(1, t + step), 1 + tuft * rng.next(0.45, 1.25) / max(4, width(t)))
            nodes.append(.init(x: mid.0, y: mid.1, corner: false))
            nodes.append(.init(x: tip.0, y: tip.1, corner: true))
            t += step
        }
        // Back down the inner edge, smooth.
        for i in stride(from: 20, through: 0, by: -1) {
            let p = point(Double(i) / 20, -1)
            nodes.append(.init(x: p.0, y: p.1, corner: i == 0))
        }
        // A band across the tail, its edges swept forward along the fur.
        let band: (Double, Double) -> DoodlePath = { a, b in
            let sweep = (b - a) * 0.7
            func edge(_ t: Double) -> [(Double, Double)] { [point(t, 0.96), point(t + sweep * 0.55, 0.5), point(t + sweep, 0), point(t + sweep * 0.55, -0.5), point(t, -0.96)] }
            let front = edge(b), back = edge(a).reversed()
            var nodes: [DoodlePath.Node] = []
            for (i, p) in front.enumerated() { nodes.append(.init(x: p.0, y: p.1, corner: i == 0 || i == front.count - 1)) }
            for (i, p) in back.enumerated() { nodes.append(.init(x: p.0, y: p.1, corner: i == 0 || i == front.count - 1)) }
            return DoodlePath(nodes: nodes, closed: true)
        }
        return (DoodlePath(nodes: nodes, closed: true), band)
    }

    static func squirrel() -> DoodleGlyph {
        var g = DoodleGlyph("squirrel", 0.16, 0.28, tilt: 6)
        g.whole = true
        g.noTuck = true
        // The tail, a plume curling up behind and over, fur at its edge and darker bands across it.
        let tail = plume([(38, 98), (22, 92), (6, 72), (3, 46), (12, 22), (32, 9), (50, 13), (56, 28), (48, 36)], widths: [10, 24, 28, 30, 30, 28, 22, 14, 5], tuft: 5.5, seed: 31)
        g.shape(1, tail.outline, 1.3)
        for (a, b) in [(0.16, 0.22), (0.38, 0.44), (0.6, 0.65), (0.81, 0.85)] { g.shade(tail.band(a, b)) }
        g.detail(0.16) { g in
            fur(&g, rows: [[(7, 58), (10, 42), (17, 28)], [(14, 68), (17, 50), (24, 34)]], lean: (0.34, -0.9), len: 5.2, w: 0.45, seed: 33)
        }
        // Back, chest and head in one line, sitting up.
        g.shape(2, "46,104 34,96 30,80 34,62 44,46 48,34 52,22 ^55,8 ^62,15 69,14 ^77,6 ^79,18 87,27 ^93,34 89,39 79,43 74,47 77,60 82,76 82,92 74,102 60,105 z", 1.45)
        // A pale front.
        g.tint(1, "^74,46 77,60 82,76 82,92 ^70,100 64,80 63,58 z")
        g.line("^73,46 63,58 63,78 ^70,98", 0.5)
        // The haunch, and the foot coming out from under it.
        g.shape(2, "44,104 34,94 36,78 48,70 60,76 66,90 62,102 54,106 z", 0.95)
        g.shape(1, "50,105 58,100 72,100 84,103 ^90,108 70,110 ^52,110 z", 1)
        g.line("^78,104 ^80,108", 0.45)
        g.line("^84,104 ^86,108", 0.45)
        // The arm, the paws and the acorn held up at the chest.
        g.shape(2, "^62,56 72,56 82,62 ^88,66 84,72 74,70 ^62,66 z", 0.95)
        g.shape(1, "^80,52 87,47 96,47 ^102,52 ^80,52 z", 0.85)
        g.shape(2, "^82,53 ^100,53 98,63 ^91,73 84,63 z", 0.9)
        g.line("^91,47 ^92,43", 0.8)
        g.detail(0.16) { g in
            g.hatch("^84,53 ^98,53 96,60 ^86,60 z", angle: 60, gap: 3, w: 0.38)
        }
        // Face.
        g.accent(.ellipse(75, 25, 2.3, 2.7))
        g.gel(.circle(75.6, 24, 0.6), 0.5)
        g.accent("^90,32 ^94,34 ^90.5,37.5 z")
        g.line("^88,37 ^81,39", 0.5)
        g.line("^57,14 ^59,20", 0.5)
        g.line("^74,13 ^73,19", 0.5)
        g.line("^86,38 ^80,35", 0.35)
        g.detail(0.16) { g in
            g.gel("^41,52 ^36,66", 0.8)
            g.hatch("^42,82 ^58,80 ^60,98 ^46,100 z", angle: 66, gap: 3, w: 0.4)
        }
        g.line("^38,112 ^60,113", 0.5)
        g.line("^68,113 ^98,112", 0.5)
        return g
    }

    static func hedgehog() -> DoodleGlyph {
        var g = DoodleGlyph("hedgehog", 0.14, 0.32, tilt: 6)
        g.whole = true
        // A pointed face and a hump of spines, every row a little more ragged.
        var nodes: [DoodlePath.Node] = [.init(x: 2, y: 68, corner: true)]
        let n = 17
        for i in 0..<n {
            let t = Double(i) / Double(n - 1)
            let a = 180 + t * 150
            let p = DoodleKit.polar(52, 62, 50, a)
            let q = DoodleKit.polar(52, 62, 56, a + 4)
            nodes.append(.init(x: p.0, y: p.1, corner: true))
            nodes.append(.init(x: q.0, y: q.1, corner: true))
        }
        nodes.append(.init(x: 96, y: 56, corner: true))
        nodes.append(.init(x: 74, y: 72, corner: true))
        g.shape(1, DoodlePath(nodes: nodes, closed: true), 1.4)
        g.detail(0.14) { g in
            for r in [38.0, 28.0, 18.0] {
                for a in stride(from: 186.0, through: 322.0, by: 12) {
                    let p = DoodleKit.polar(50, 66, r, a + r)
                    let q = DoodleKit.polar(50, 66, r + 7, a + r + 5)
                    g.line(.poly([p, q]), 0.55)
                }
            }
        }
        g.shape(2, "^62,74 70,50 88,44 108,58 ^122,68 ^118,74 104,80 ^76,82 z", 1.3)
        g.accent("^116,64 ^124,68 ^119,73 z")
        g.accent(.circle(95, 58, 2.2))
        g.shape(1, .ellipse(80, 48, 6.4, 7.4), 0.9)
        g.line("^108,76 ^100,74", 0.5)
        // Little feet under.
        g.shape(2, "^20,68 ^38,70 ^37,84 ^16,84 z", 0.9)
        g.shape(2, "^76,78 ^94,78 ^96,84 ^76,84 z", 0.9)
        g.line("^-4,85 ^130,85", 0.8)
        return g
    }

    static func raccoon() -> DoodleGlyph {
        var g = DoodleGlyph("raccoon", 0.17, 0.28, tilt: 5)
        g.whole = true
        g.noTuck = true
        // Low to the ground and humped, walking to the right, nose down. The tail hangs behind in a thick ringed curve.
        let tail = plume([(38, 44), (22, 40), (6, 46), (-8, 58), (-16, 72)], widths: [12, 20, 24, 24, 15], tuft: 3.4, seed: 37)
        g.shape(1, tail.outline, 1.25)
        for (a, b) in [(0.2, 0.3), (0.46, 0.56), (0.72, 0.82)] { g.accent(tail.band(a, b)) }
        g.accent(tail.band(0.93, 1.0))
        // The far legs, set back and darker: one foot planted, one just lifting.
        let farHind: DoodlePath = "^52,62 ^72,60 74,68 68,74 ^78,84 ^76,88 ^60,88 58,80 54,72 z"
        let farFore: DoodlePath = "^88,60 ^104,60 102,68 92,74 ^88,80 ^84,84 ^72,82 ^78,76 84,70 z"
        g.shape(1, farHind, 1)
        g.shade(farHind)
        g.shape(1, farFore, 1)
        g.shade(farFore)
        // The body: a high round rump, the arched back falling to the shoulder, the bent near legs.
        g.shape(1, "30,56 30,40 38,26 52,17 70,16 88,22 102,32 112,44 114,56 ^112,64 116,72 ^122,80 ^130,88 ^104,88 102,80 98,72 92,66 76,68 60,66 50,70 44,78 ^52,88 ^24,88 24,80 30,72 34,66 z", 1.45)
        g.detail(0.16) { g in
            fur(&g, rows: [[(38, 38), (36, 48), (38, 58)], [(50, 26), (48, 36), (48, 48)], [(66, 22), (66, 30)], [(84, 27), (88, 36), (92, 46)]], lean: (-0.3, 0.95), len: 5.4, w: 0.48, seed: 38)
            g.hatch("^56,58 ^84,58 ^84,66 ^60,66 z", angle: 66, gap: 3, w: 0.4)
        }
        // Dark paws.
        g.accent("^26,88 ^51,88 ^46,83 ^28,83 z")
        g.accent("^105,88 ^129,88 ^123,82 ^106,83 z")
        // The ears, behind the skull.
        g.shape(1, .ellipse(118, 25, 7, 8, rot: -14), 1.1)
        g.shape(-1, .ellipse(118, 26, 3.8, 4.6, rot: -14), 0.5)
        g.shape(1, .ellipse(138, 26, 6.4, 7.4, rot: 18), 1.1)
        g.shape(-1, .ellipse(138, 27, 3.4, 4.2, rot: 18), 0.5)
        // The head, low and wedge shaped.
        g.shape(1, "^106,44 110,34 120,28 132,28 142,35 ^148,44 ^164,56 ^160,62 146,66 128,68 114,62 z", 1.45)
        // The pale face: brow over the mask, then cheek and muzzle under it.
        g.shape(-1, "^112,40 122,33 132,33 ^146,42 ^138,42 ^130,39 ^128,40 ^122,39 ^114,44 z", 0.5)
        g.shape(-1, "^116,52 ^128,48 ^132,52 ^148,47 ^164,56 ^160,62 146,66 128,68 118,63 z", 0.8)
        g.accent("^110,44 ^122,39 ^128,42 ^138,42 ^148,46 ^142,52 ^132,52 ^127,48 ^118,53 ^112,52 z")
        g.shape(-1, .circle(121, 45, 3.3), 0.4)
        g.blot(.circle(121.6, 45.2, 1.6))
        g.shape(-1, .circle(137, 46, 3), 0.4)
        g.blot(.circle(137.6, 46.2, 1.5))
        g.accent("^158,54 ^165,56 ^161,61 z")
        g.line("^160,61 ^152,62 ^146,60", 0.5)
        g.line("^130,40 ^130,48", 0.4)
        g.line("^4,90 ^48,90", 0.5)
        g.line("^56,90 ^80,90", 0.45)
        g.line("^102,90 ^134,90", 0.55)
        return g
    }

    static func beaver() -> DoodleGlyph {
        var g = DoodleGlyph("beaver", 0.18, 0.36, tilt: 5)
        g.whole = true
        // Upright beside its gnawed post: flat crosshatched tail, big front teeth.
        g.shape(1, "^-14,86 -4,74 18,72 ^38,80 ^36,94 14,98 ^-8,96 z", 1.3)
        g.detail(0.16) { g in
            g.hatch("^-8,82 ^30,80 ^30,92 ^-6,94 z", angle: 45, gap: 3.4, w: 0.42)
            g.hatch("^-8,82 ^30,80 ^30,92 ^-6,94 z", angle: -45, gap: 3.4, w: 0.42)
        }
        g.shape(2, "^26,96 18,72 22,44 34,28 ^40,14 ^46,8 ^52,14 64,14 ^70,8 ^76,16 ^84,30 ^92,38 ^84,50 ^74,50 78,70 74,90 ^78,98 z", 1.5)
        g.tint(1, "^74,50 78,70 74,90 ^62,94 56,70 58,52 z")
        g.line("^74,50 58,52 56,70 ^62,94", 0.55)
        // The arm and hand.
        g.line("^44,60 56,70 ^72,66", 1)
        g.shape(1, "^24,98 ^54,98 ^56,106 ^22,106 z", 1)
        g.shape(1, "^58,98 ^84,98 ^88,106 ^58,106 z", 1)
        // Face and teeth.
        g.accent(.circle(68, 26, 2.4))
        g.accent("^84,30 ^92,32 ^88,38 z")
        g.shape(-1, "^80,41 ^89,38 ^89,48 ^81,50 z", 0.8)
        g.line("^84.5,40 ^85,49", 0.5)
        g.detail(0.16) { g in
            g.line("^88,40 ^96,44", 0.42)
            g.gel("^28,48 ^26,68", 0.9)
            fur(&g, rows: [[(30, 50), (28, 62), (28, 74)], [(38, 44), (36, 56), (36, 68)]], lean: (-0.3, 0.95), len: 5, seed: 41)
        }
        // A gnawed post, waisted where the teeth have been.
        g.shape(1, "^96,18 ^116,16 ^120,36 110,50 ^108,58 ^112,66 ^118,86 ^122,106 ^92,106 ^96,86 ^102,66 ^104,58 ^102,50 92,36 z", 1.3)
        g.shape(2, .ellipse(106, 18, 10, 3.6), 0.7)
        g.line("^106,44 ^112,50", 0.5)
        g.line("^104,70 ^116,70", 0.5)
        g.speckle(84, 100, 128, 108, n: 7, r: 1, seed: 43)
        g.line("^-16,108 ^134,108", 0.8)
        return g
    }

    static func frog() -> DoodleGlyph {
        var g = DoodleGlyph("frog", 0.13, 0.3, tilt: 6)
        g.whole = true
        // A frog sitting side on, on a lily pad a shade darker than it is.
        let pad: DoodlePath = "^64,84 ^98,74 112,82 106,92 80,100 44,102 14,96 2,86 12,76 ^40,74 z"
        g.shape(0, pad, 1.25)
        g.shade(pad)
        g.detail(0.14) { g in
            for (x, y) in [(14.0, 86.0), (34.0, 94.0), (62.0, 97.0), (88.0, 93.0), (100.0, 84.0)] {
                g.line(.poly([(64, 84), (x, y)]), 0.42)
            }
        }
        // The far eye, then the body in one line: hump of the back, flat head, wide jaw, belly.
        g.shape(0, .circle(84, 22, 7.6), 1.15)
        g.shape(-1, .circle(85, 21.4, 4.8), 0.5)
        g.blot(.circle(86, 21.4, 2.3))
        g.shape(0, "22,70 15,54 22,40 38,31 54,26 ^60,22 76,24 92,30 104,42 ^108,50 100,60 88,66 76,72 ^44,74 z", 1.4)
        // The pale throat and belly, under the mouth.
        g.shape(-1, "^108,50 100,60 88,66 76,72 ^62,73 64,62 76,58 92,56 z", 0)
        g.line("^108,50 92,56 76,57 ^63,50", 0.85)
        // The near eye.
        g.shape(0, .circle(68, 21, 9.4), 1.2)
        g.shape(-1, .circle(69, 20, 6.4), 0.55)
        g.blot(.circle(70.4, 20, 3.1))
        g.gel(.circle(68.8, 18.4, 0.8), 0.5)
        g.line("^102,41 ^105,43", 0.5)
        // The great folded back leg, and the long foot out in front of it.
        g.shape(0, "^28,74 15,66 12,52 20,40 34,38 48,46 54,58 52,68 ^44,74 z", 1.25)
        g.shape(0, "^24,74 ^54,72 ^64,76 ^70,80 ^62,80 ^60,82 ^52,80 ^48,82 ^22,80 z", 1.1)
        // The front leg.
        g.shape(0, "^68,58 ^78,60 78,70 ^86,76 ^92,78 ^86,80 ^84,82 ^78,80 ^74,82 ^66,78 70,68 z", 1.1)
        g.detail(0.14) { g in
            for (x, y, r) in [(30.0, 48.0, 2.4), (40.0, 54.0, 1.7), (26.0, 58.0, 1.5), (46.0, 36.0, 2), (56.0, 42.0, 1.4)] { g.blot(.circle(x, y, r)) }
            g.gel("^20,54 24,46 ^31,42", 0.7)
        }
        return g
    }

    static func woodpecker() -> DoodleGlyph {
        var g = DoodleGlyph("woodpecker", 0.16, 0.36, tilt: 3)
        g.noFlip = true
        g.whole = true
        // Clinging to a trunk, a red cap, a long tail braced against the bark.
        g.shape(1, "^0,-8 ^32,-8 ^34,136 ^-2,136 z", 1.4)
        g.detail(0.16) { g in
            g.line("^8,4 6,28 ^10,50", 0.65)
            g.line("^20,40 22,60 ^18,84", 0.65)
            g.line("^8,88 6,104 ^10,128", 0.65)
            g.line(.ellipse(20, 16, 4, 6), 0.65)
        }
        g.shape(-1, "^62,24 56,12 44,10 ^42,12 ^30,16 ^44,22 ^42,34 38,52 44,74 56,88 ^68,86 76,62 ^76,40 70,28 z", 1.45)
        g.shape(1, "^52,46 72,36 86,54 ^90,86 ^100,128 ^88,122 ^78,104 ^62,88 50,66 z", 1.35)
        g.detail(0.16) { g in
            for y in [52.0, 62.0, 72.0, 82.0] { g.line(.poly([(60 + (y - 52) * 0.4, y), (80 + (y - 52) * 0.3, y + 2)]), 0.5) }
            g.stitch("^90,96 ^96,120", dash: 2, gap: 1.8, w: 0.5)
        }
        g.shape(2, "^44,10 56,4 66,12 ^70,24 ^58,18 ^46,16 z", 1)
        g.shape(1, "^44,14 ^20,20 ^44,22 z", 0.95)
        g.accent(.circle(52, 16, 1.8))
        g.line("^44,68 ^32,62", 0.9)
        g.line("^52,80 ^32,86", 0.9)
        return g
    }

    static func cookPot() -> DoodleGlyph {
        var g = DoodleGlyph("cookPot", 0.15, 0.38, tilt: 5)
        g.must = false
        // A pot on a pole tripod, stew bubbling, small flames underneath.
        g.line("^60,-6 ^4,116", 1.3)
        g.line("^60,-6 ^116,116", 1.3)
        g.line("^60,-6 ^60,112", 1.05)
        g.line("^54,-2 66,-2 ^60,6", 0.9)
        g.line("^60,6 ^60,34", 0.75)
        g.line("^32,48 44,30 60,26 76,30 ^88,48", 0.85)
        g.shape(1, "^26,48 ^94,48 92,76 80,92 ^40,92 28,76 z", 1.55)
        g.shape(2, .ellipse(60, 48, 34, 7), 1.05)
        g.shape(-1, .circle(48, 46, 3), 0.5)
        g.shape(-1, .circle(66, 49, 2.4), 0.5)
        g.shape(-1, .circle(76, 45, 2), 0.5)
        g.detail(0.18) { g in
            g.hatch("^72,56 ^90,54 ^88,76 ^76,88 z", angle: 66, gap: 3, w: 0.42)
            g.gel("^34,56 ^38,76", 1)
        }
        g.shape(2, "^36,116 42,98 ^50,106 58,92 ^66,106 ^76,96 ^84,116 z", 1.2)
        g.line("^22,118 ^98,112", 1.5)
        g.line("^22,112 ^98,118", 1.5)
        return g
    }

    static func hammock() -> DoodleGlyph {
        var g = DoodleGlyph("hammock", 0.18, 0.44, tilt: 4)
        g.noFlip = true
        // Slung between two trunks with a book left in it.
        conifer(&g, cx: 14, top: -14, bottom: 96, half: 24, tiers: 4, seed: 51, needles: false)
        conifer(&g, cx: 148, top: -22, bottom: 96, half: 26, tiers: 4, seed: 52, needles: false)
        g.line("^16,52 ^30,62", 0.75)
        g.line("^146,52 ^132,62", 0.75)
        g.shape(2, "^28,60 58,84 82,88 106,84 ^134,60 ^132,70 106,98 82,102 58,98 ^30,70 z", 1.4)
        g.tint(-1, "^40,70 ^58,84 ^82,88 ^106,84 ^122,70 ^120,80 106,92 82,96 58,92 ^42,80 z")
        g.line("^40,70 58,84 82,88 106,84 ^122,70", 0.55)
        g.line("^42,80 58,92 82,96 106,92 ^120,80", 0.55)
        g.shape(1, "^72,72 ^84,76 ^96,72 ^96,84 ^84,88 ^72,84 z", 0.95)
        g.line("^84,76 ^84,88", 0.5)
        g.line("^-14,108 ^176,108", 0.8)
        for (x, c) in [(44.0, -3.0), (56.0, 3.0), (108.0, -2.0), (120.0, 3.0)] { g.line(.poly([(x, 108), (x + c, 100)]), 0.55) }
        return g
    }

    static func campChair() -> DoodleGlyph {
        var g = DoodleGlyph("campChair", 0.13, 0.3, tilt: 7)
        g.noTuck = true
        // A folding chair with its canvas sagging under its own weight, seen a little from the side.
        // The far legs and posts.
        g.line("^78,22 ^82,70", 1)
        g.line("^34,70 ^92,116", 1)
        // The back: canvas slung between two posts.
        g.shape(0, "^26,10 44,15 ^76,8 ^80,42 54,47 ^30,44 z", 1.3)
        g.detail(0.14) { g in
            g.stitch("^29,16 ^30,40", dash: 2, gap: 1.4, w: 0.4)
            g.stitch("^75,14 ^77,38", dash: 2, gap: 1.4, w: 0.4)
            g.hatch("^60,18 ^74,14 ^77,38 ^60,42 z", angle: 70, gap: 3.2, w: 0.38)
        }
        g.line("^25,4 ^30,74", 1.15)
        g.line("^76,3 ^79,50", 1.15)
        // The arms.
        g.shape(1, "^12,48 ^34,44 ^36,50 ^14,55 z", 1)
        g.shape(1, "^72,42 ^94,38 ^96,44 ^74,49 z", 1)
        // The seat, its front dipping.
        g.shape(0, "^24,66 50,70 ^82,62 ^92,72 58,84 ^14,76 z", 1.3)
        g.shade("^14,76 ^58,84 ^92,72 ^90,70 58,80 ^17,73 z")
        // The near legs, crossing.
        g.line("^16,78 ^80,120", 1.25)
        g.line("^88,76 ^20,122", 1.25)
        g.blot(.circle(52, 100, 1.8))
        g.line("^10,122 ^30,122", 0.9)
        g.line("^70,121 ^90,120", 0.9)
        // A mug in the cup holder.
        g.shape(-1, "^78,27 ^91,26 ^90,40 ^79,41 z", 0.95)
        g.line("^91,29 97,30 97,35 ^90,36", 0.75)
        return g
    }

    static func woodpile() -> DoodleGlyph {
        var g = DoodleGlyph("woodpile", 0.12, 0.3, tilt: 4)
        g.noFlip = true
        // Split logs stacked in a pyramid, an axe sunk in the last.
        for (x, y, r) in [(16.0, 70.0, 14.0), (42.0, 72.0, 14.0), (68.0, 70.0, 14.0), (94.0, 72.0, 14.0), (28.0, 46.0, 13.0), (55.0, 46.0, 13.0), (82.0, 47.0, 13.0), (42.0, 22.0, 12.5), (68.0, 23.0, 12.5)] {
            g.shape(1, .ellipse(x, y, r, r * 0.96), 1.15)
            g.line(.ellipse(x, y, r * 0.58, r * 0.56), 0.5)
            g.line(.ellipse(x, y, r * 0.22, r * 0.22), 0.45)
        }
        g.line("^-4,86 ^114,86", 0.9)
        return g
    }

    static func guitar() -> DoodleGlyph {
        var g = DoodleGlyph("guitar", 0.16, 0.38, tilt: 32)
        g.noTuck = true
        // A campfire guitar: round body, soundhole, frets, tuning pegs.
        g.shape(1, "30,70 16,78 6,96 12,116 ^30,130 ^48,130 66,116 72,96 62,78 48,70 54,56 48,44 ^44,44 ^34,44 30,44 24,56 z", 1.5)
        g.accent(.circle(39, 92, 9.6))
        g.shape(2, .rrect(26, 112, 26, 5, 1.5), 0.8)
        g.shape(1, .rrect(34, -2, 10, 48, 1), 1.15)
        g.shape(2, "^30,-22 ^48,-22 ^46,-2 ^32,-2 z", 1.15)
        for y in [-18.0, -12.0, -6.0] {
            g.blot(.circle(26, y, 2))
            g.blot(.circle(52, y, 2))
        }
        for y in stride(from: 6.0, through: 40.0, by: 8) { g.line(.poly([(34, y), (44, y)]), 0.5) }
        for x in [37.0, 39.0, 41.0] { g.line(.poly([(x, -2), (x, 114)]), 0.42) }
        g.detail(0.18) { g in
            g.gel("^14,92 ^20,80", 1)
            g.hatch("^56,84 ^68,94 ^62,116 ^48,126 z", angle: 62, gap: 3, w: 0.42)
        }
        return g
    }

    // Woodland marks in place of the generic ones.

    static func pawPrints() -> DoodleGlyph {
        var g = DoodleGlyph("pawPrints", 0.03, 0.08, tilt: 30)
        for (x, y) in [(0.0, 26.0), (22.0, 8.0)] {
            g.blot(.ellipse(x + 6, y + 10, 5, 4.4))
            g.blot(.circle(x, y + 3, 2))
            g.blot(.circle(x + 6, y, 2))
            g.blot(.circle(x + 12, y + 3, 2))
        }
        return g
    }

    static func tinyAcorn() -> DoodleGlyph {
        var g = DoodleGlyph("tinyAcorn", 0.025, 0.055, tilt: 40)
        g.shape(1, "^4,10 ^24,10 24,18 ^14,30 4,18 z", 0.8)
        g.shape(0, "^2,10 6,2 ^14,0 22,2 ^26,10 z", 0.72)
        return g
    }

    static func tinySprig() -> DoodleGlyph {
        var g = DoodleGlyph("tinySprig", 0.03, 0.07, tilt: 40)
        g.line("^0,28 ^28,4", 0.7)
        for t in [0.3, 0.55, 0.8] {
            let x = t * 28, y = 28 - t * 24
            g.line(.poly([(x, y), (x + 1, y - 9)]), 0.55)
            g.line(.poly([(x, y), (x + 9, y + 1)]), 0.55)
        }
        return g
    }

    static func tinyFeather() -> DoodleGlyph {
        var g = DoodleGlyph("tinyFeather", 0.025, 0.06, tilt: 60)
        g.shape(2, DoodleKit.leaf((0, 0), (30, 6), belly: 10), 0.7)
        g.line("^-5,-1 ^26,5", 0.5)
        return g
    }

    static func tinyTwigs() -> DoodleGlyph {
        var g = DoodleGlyph("tinyTwigs", 0.02, 0.05, tilt: 30)
        g.line("^0,14 ^26,4", 0.85)
        g.line("^4,4 ^28,16", 0.85)
        return g
    }
}
