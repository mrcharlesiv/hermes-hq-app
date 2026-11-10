// The Forest and Mountains drawings. Spot colours mean something here: 0 is foliage, 1 is wood and earth, 2 is a warm
// accent, so nothing swaps them.

import CoreGraphics
import Foundation

nonisolated enum DoodleForest {
    static func all() -> [DoodleGlyph] {
        var list = [tent(), pine(), pines(), deer(), fire(), axe(), pack(), bear(), raccoon(), squirrel(), owl(), lantern(), mushrooms(), cone(), mug(), fish(), canoe(), hammock(), cookPot(), beaver(), hedgehog(), frog(), woodpecker(), campChair(), woodpile(), guitar(),
                    binoculars(), stump(), fox(), fern(), oak(), acorn(), kettle(), signpost(), cloud(), birds(), paw(), tinyPine(), rocks(),
                    matchbox(), knife(), thermos(), log(), beetle(), snail(), rabbit(), dragonfly(), bee(), marshmallow(), flashlight(), whistle(), mapleLeaf(),
                    clover(), tinyShroom(), twig(), quill(), skillet(), ladybug(), saw(), beans(), sleepingBag(), paddle(), tuftGrass(), flint(), sparkTrio(),
                    pawPrints(), tinyAcorn(), tinySprig(), tinyFeather(), tinyTwigs()]
        list += DoodleFillers.common().filter { ["dot"].contains($0.name) }
        list += [DoodleFillers.leaf(), DoodleFillers.tuft(), DoodleFillers.pebble(), DoodleFillers.berries(), DoodleFillers.seed()]
        for i in list.indices {
            list[i].fixed = true
            list[i].done()
        }
        return list
    }

    /// A conifer: skirts of boughs, the lowest first, each with a toothed hem and each overlapping the one below.
    static func conifer(_ g: inout DoodleGlyph, cx: Double, top: Double, bottom: Double, half: Double, tiers: Int, sep: Int = 0, w: Double = 1, seed: UInt64, needles: Bool = true) {
        var rng = SplitMix64(seed: seed)
        let h = bottom - top
        // Trunk.
        let tw = max(2, half * 0.14)
        g.shape(1, .poly([(cx - tw, bottom - h * 0.06), (cx + tw, bottom - h * 0.06), (cx + tw * 1.25, bottom + h * 0.1), (cx - tw * 1.25, bottom + h * 0.1)], closed: true), w)
        if needles {
            g.detail(0.2) { $0.line(.poly([(cx + tw * 0.3, bottom), (cx + tw * 0.2, bottom + h * 0.08)]), 0.5) }
        }
        for i in stride(from: tiers - 1, through: 0, by: -1) {
            let f0 = Double(i) / Double(tiers), f1 = Double(i + 1) / Double(tiers)
            let apexY = top + h * (i == 0 ? 0 : f0 * 0.86 - 0.02)
            let baseY = top + h * f1
            let hw = half * (0.3 + 0.7 * f1) * rng.next(0.94, 1.04)
            let teeth = 3 + i + (tiers > 4 && i >= 3 ? 1 : 0)
            var nodes: [DoodlePath.Node] = [.init(x: cx, y: apexY, corner: true)]
            nodes.append(.init(x: cx + hw * 0.5, y: apexY + (baseY - apexY) * 0.62, corner: false))
            let tipLift = rng.next(0.0, 0.02) * h
            nodes.append(.init(x: cx + hw, y: baseY - tipLift, corner: true))
            // The hem, right to left.
            let step = 2 * hw / Double(teeth)
            for t in 0..<teeth {
                let x0 = cx + hw - step * (Double(t) + 0.32)
                let x1 = cx + hw - step * (Double(t) + 1)
                let hem = (1 - pow((x1 - cx) / hw, 2)) * h * 0.022
                if t < teeth - 1 {
                    nodes.append(.init(x: x0, y: baseY - h * 0.045 + rng.next(-0.006, 0.006) * h + hem * 0.4, corner: true))
                    nodes.append(.init(x: x1, y: baseY + hem + rng.next(-0.01, 0.012) * h, corner: true))
                } else {
                    nodes.append(.init(x: x0, y: baseY - h * 0.045 + hem * 0.4, corner: true))
                }
            }
            nodes.append(.init(x: cx - hw, y: baseY - tipLift * 0.5, corner: true))
            nodes.append(.init(x: cx - hw * 0.5, y: apexY + (baseY - apexY) * 0.62, corner: false))
            g.shape(sep, DoodlePath(nodes: nodes, closed: true), w)
            // About one tier in three carries a little hatching on its shaded side.
            if rng.next(0, 1) < 0.34, half >= 14 {
                let d = baseY - apexY
                let shadow: [(Double, Double)] = [(cx + hw * 0.16, apexY + d * 0.5), (cx + hw * 0.5, apexY + d * 0.66), (cx + hw * 0.84, baseY - h * 0.05), (cx + hw * 0.22, baseY - h * 0.06)]
                g.detail(0.2) { $0.hatch(.poly(shadow, closed: true), angle: 66, gap: 3.2, w: 0.5) }
            }
            if needles {
                // Needle ticks fall from under the tier above, thicker on the shaded right.
                g.detail(0.17) { g in
                    let count = 2 + i * 2
                    for n in 0..<count {
                        let u = (Double(n) + 0.5) / Double(count) * 2 - 1
                        let x = cx + u * hw * 0.72
                        let y = apexY + (baseY - apexY) * (0.55 + 0.25 * (1 - abs(u))) + rng.next(-1, 1)
                        let len = (baseY - apexY) * rng.next(0.14, 0.24)
                        g.line(.poly([(x, y), (x + u * len * 0.3, y + len)]), u > 0 ? 0.62 : 0.42)
                    }
                }
            }
        }
    }

    static func pine() -> DoodleGlyph {
        var g = DoodleGlyph("pine", 0.14, 0.44, tilt: 7)
        conifer(&g, cx: 40, top: 0, bottom: 118, half: 38, tiers: 5, seed: 11)
        g.detail(0.16) { g in
            g.line("^20,132 ^24,126 ^26,132", 0.7)
            g.line("^54,132 ^57,127 ^60,132", 0.7)
            g.line("^6,134 30,131 58,133 ^78,131", 0.75)
        }
        return g
    }

    static func axe() -> DoodleGlyph {
        var g = DoodleGlyph("axe", 0.13, 0.36, tilt: 26)
        g.must = true
        // Haft: a long S.
        g.shape(1, "^47,17 ^57,18 53,42 46,70 42,92 45,108 ^36,114 ^27,108 31,88 37,62 44,38 z", 1.15)
        g.detail(0.16) { g in
            g.line("50,30 46,50 ^41,68", 0.45)
            g.line("44,62 41,76 ^38,88", 0.45)
            g.line("51,42 49,50", 0.4)
        }
        // Leather wrap and a thong.
        g.shape(2, "^32,84 ^43,87 ^39,104 ^28,101 z", 0.95)
        g.detail(0.16) { g in
            g.line("^31,90 ^42,92", 0.55)
            g.line("^30,95 ^41,97", 0.55)
        }
        g.line("33,113 30,122 36,128 42,122 ^37,114", 0.75)
        // Head: poll on the left, the blade flaring to a curved edge.
        g.shape(0, "^38,2 ^62,1 74,-6 ^92,-18 100,4 96,26 ^86,46 ^76,30 ^62,23 ^40,23 z", 1.25)
        g.shape(-1, "^86,-12 93,5 90,24 ^84,38 ^80,29 ^84,5 ^81,-9 z", 0.8)
        g.detail(0.16) { g in
            g.line("^44,6 ^60,5", 0.5)
            g.line("^44,18 ^58,18", 0.5)
            g.hatch("^62,21 ^76,28 ^78,18 ^74,6 ^62,8 z", angle: 62, gap: 2.6, w: 0.5)
            g.gel("^88,-8 94,6 ^92,18", 0.7)
        }
        return g
    }

    static func fire() -> DoodleGlyph {
        var g = DoodleGlyph("fire", 0.16, 0.4, tilt: 6)
        g.must = true
        // Flames behind the logs.
        g.shape(2, "^50,-2 56,12 66,20 74,34 72,50 ^64,72 ^36,72 26,52 26,38 33,28 ^36,40 42,28 44,14 z", 1.2)
        g.shape(-1, "^51,20 56,32 62,42 60,56 ^56,72 ^42,72 38,56 40,44 ^45,50 48,36 z", 0.85)
        g.shape(2, "^50,42 54,52 53,62 ^50,72 ^47,72 45,60 z", 0.6)
        // Two logs crossed, end grain showing.
        g.shape(1, "^12,62 ^80,76 ^76,92 ^8,78 z", 1.15)
        g.shape(-1, .ellipse(10, 70, 4.6, 8.6, rot: 12), 0.9)
        g.shape(1, "^88,60 ^20,76 ^24,92 ^92,76 z", 1.15)
        g.shape(-1, .ellipse(90, 68, 4.6, 8.6, rot: -12), 0.9)
        g.detail(0.18) { g in
            g.line(.ellipse(90, 68, 2, 4.2, rot: -12), 0.45)
            g.line(.ellipse(10, 70, 2, 4.2, rot: 12), 0.45)
            g.line("^34,78 ^52,74", 0.5)
            g.line("^42,84 ^62,79", 0.5)
            g.line("^70,70 ^78,68", 0.5)
            g.hatch("^26,86 ^88,74 ^89,76 ^25,91 z", angle: 80, gap: 3, w: 0.5)
        }
        // Stones around it.
        for (x, y, rx, ry) in [(-4.0, 88.0, 8.0, 6.0), (10.0, 94.0, 9.0, 6.0), (30.0, 98.0, 10.0, 6.0), (52.0, 100.0, 10.0, 6.0), (72.0, 98.0, 10.0, 6.0), (90.0, 94.0, 9.0, 6.0), (104.0, 88.0, 8.0, 6.0)] {
            g.shape(-1, .ellipse(x, y, rx, ry), 0.95)
            g.detail(0.2) { $0.hatch(.ellipse(x + rx * 0.4, y + ry * 0.2, rx * 0.5, ry * 0.65), angle: 60, gap: 2.4, w: 0.42) }
        }
        // Sparks.
        g.blot(.circle(22, 10, 1.6))
        g.blot(.circle(82, 6, 1.3))
        g.blot(.circle(72, -6, 1))
        g.line("^16,24 ^13,20", 0.7)
        g.line("^88,22 ^92,18", 0.7)
        return g
    }

    static func pack() -> DoodleGlyph {
        var g = DoodleGlyph("pack", 0.2, 0.42, tilt: 12)
        g.whole = true
        // Rolled mat on top, under the lid straps.
        g.shape(2, .rrect(12, 0, 76, 16, 8), 1.15)
        g.detail(0.2) { g in
            g.line(.spline([(82, 8), (84, 5.5), (86, 8), (84, 11), (81, 9)]), 0.55)
            g.line("^20,3.5 ^70,3.5", 0.4)
            g.line("^20,12.5 ^70,12.5", 0.4)
        }
        // Side pockets with a bottle in one.
        g.shape(-1, .rrect(2, 44, 12, 14, 3), 0.85)
        g.shape(1, "^-2,56 ^16,54 ^16,92 ^2,92 z", 1.05)
        g.shape(1, "^84,56 ^102,56 ^98,92 ^84,92 z", 1.05)
        // Body.
        g.shape(0, "22,26 50,22 78,26 86,42 86,90 78,102 50,104 22,102 14,90 14,42 z", 1.3)
        // Front pocket with a zip.
        g.shape(1, .rrect(25, 60, 50, 36, 6), 1.05)
        g.line("29,70 50,73 ^71,70", 0.95)
        g.detail(0.2) { g in
            g.stitch("29,72.5 50,75.5 ^71,72.5", dash: 1.4, gap: 1.2, w: 0.42)
            g.stitch(.rrect(28, 63, 44, 30, 5), dash: 2, gap: 1.6, w: 0.42)
            g.hatch("^58,76 ^72,74 ^72,90 ^60,94 z", angle: 62, gap: 2.8, w: 0.5)
        }
        g.line("^71,70 ^71,78", 0.8)
        g.shape(2, .rrect(68.8, 77.5, 4.4, 6, 1.2), 0.65)
        // Lid with two straps and buckles.
        g.shape(1, "^20,30 24,17 50,12 76,17 ^80,30 66,37 50,38 34,37 z", 1.2)
        for x in [33.0, 67.0] {
            g.shape(-1, "^\(x - 3),14 ^\(x + 3),13 ^\(x + 3),54 ^\(x - 3),54 z", 0.8)
            g.shape(2, .rrect(x - 4.6, 40, 9.2, 7, 1.4), 0.75)
        }
        // Haul loop, a carabiner with a tin cup.
        g.line("44,14 46,5 54,5 ^56,14", 0.9)
        g.line(.ellipse(92, 60, 3, 5), 0.75)
        g.shape(-1, "^86,66 ^100,66 ^99,80 ^88,80 z", 0.85)
        g.line("100,69 104,70 104,76 ^99,77", 0.65)
        g.detail(0.2) { g in
            g.line("^20,50 ^20,86", 0.45)
            g.line("^80,50 ^80,86", 0.45)
            g.line("^0,66 ^15,65", 0.5)
            g.line("^86,74 ^100,74", 0.4)
            g.stitch("^24,36 34,41 ^50,42", dash: 2, gap: 1.6, w: 0.4)
            g.hatch("^16,80 ^24,88 ^24,100 ^16,92 z", angle: 62, gap: 2.8, w: 0.5)
        }
        return g
    }

    static func owl() -> DoodleGlyph {
        var g = DoodleGlyph("owl", 0.14, 0.38, tilt: 12)
        g.whole = true
        // Branch through the feet.
        g.shape(1, "^-8,88 30,84 70,85 ^108,80 ^109,86 72,92 30,91 ^-7,95 z", 1.1)
        g.detail(0.16) { g in
            g.line("^10,89 ^24,88", 0.4)
            g.line("^82,86 ^98,84", 0.4)
        }
        g.shape(0, "^98,80 106,66 118,66 ^116,78 z", 0.95)
        g.detail(0.16) { $0.line("^99,79 ^113,68", 0.45) }
        // Body with ear tufts.
        g.shape(1, "^22,6 32,14 50,16 68,14 ^78,6 80,20 86,44 84,68 72,86 50,90 28,86 16,68 14,44 20,20 z", 1.3)
        // Chest of scalloped feathers.
        g.shape(-1, "28,50 50,44 72,50 74,66 64,82 50,85 36,82 26,66 z", 0)
        g.detail(0.13) { g in
            for r in 0..<4 {
                let y = 50.0 + Double(r) * 8.5
                let n = r == 3 ? 3 : 5 - (r == 2 ? 1 : 0)
                let x0 = 50 - Double(n - 1) * 5.6 + 0
                for i in 0..<n {
                    let x = x0 + Double(i) * 11.2
                    g.line("^\(x - 4.8),\(y) \(x - 3),\(y + 4) \(x),\(y + 5.6) \(x + 3),\(y + 4) ^\(x + 4.8),\(y)", 0.6)
                }
            }
        }
        // Wings.
        g.shape(0, "^16,40 8,60 12,80 ^24,84 28,66 ^26,44 z", 1.05)
        g.shape(0, "^84,40 92,60 88,80 ^76,84 72,66 ^74,44 z", 1.05)
        g.detail(0.16) { g in
            g.line("14,60 ^22,62", 0.45)
            g.line("15,70 ^24,72", 0.45)
            g.line("86,60 ^78,62", 0.45)
            g.line("85,70 ^76,72", 0.45)
        }
        // Face.
        g.shape(-1, .circle(34, 34, 16.5), 1.0)
        g.shape(-1, .circle(66, 34, 16.5), 1.0)
        g.detail(0.16) { g in
            for c in [34.0, 66.0] {
                for i in 0..<16 {
                    let a = Double(i) / 16 * 2 * .pi
                    g.line(.poly([(c + 11.4 * cos(a), 34 + 11.4 * sin(a)), (c + 14.6 * cos(a), 34 + 14.6 * sin(a))]), 0.4)
                }
            }
        }
        for c in [34.0, 66.0] {
            g.shape(2, .circle(c, 34, 9), 0.95)
            g.blot(.circle(c, 34, 5))
            g.gel(.circle(c - 1.6, 32, 1), 0.5)
        }
        g.shape(2, "^50,38 ^56,46 ^50,56 ^44,46 z", 0.95)
        // Talons.
        for x in [36.0, 42.0, 48.0, 54.0, 60.0, 66.0] {
            g.line("^\(x),84 ^\(x + 0.5),90", 1.0)
        }
        return g
    }

    static func lantern() -> DoodleGlyph {
        var g = DoodleGlyph("lantern", 0.11, 0.32, tilt: 14)
        g.whole = true
        g.line("35,22 28,4 50,-8 72,4 65,22", 1.1)
        g.line(.circle(50, -9, 2.6), 0.7)
        g.shape(1, "^32,24 38,13 ^62,13 ^68,24 z", 1.15)
        g.shape(1, .rrect(44, 7, 12, 6, 1.5), 0.85)
        // Globe with a flame.
        g.shape(2, "36,25 29,46 32,64 ^40,74 ^60,74 68,64 71,46 64,25 z", 1.15)
        g.shape(-1, "50,38 56,50 54,60 50,63 46,60 44,50 z", 0.8)
        g.shape(1, .ellipse(50, 56, 2.4, 4.8), 0)
        g.blot(.rrect(47.5, 63, 5, 7, 1))
        // Cage.
        g.line("39,25 33,48 ^38,72", 0.75)
        g.line("61,25 67,48 ^62,72", 0.75)
        g.line("29,46 50,49 ^71,46", 0.7)
        g.detail(0.14) {
            $0.gel("38,34 35,44", 0.8)
        }
        // Tank, ribs, a wick wheel.
        g.shape(1, "^34,74 ^66,74 72,86 ^68,94 ^32,94 28,86 z", 1.25)
        g.detail(0.14) { g in
            g.line("^31,82 ^69,82", 0.45)
            g.line("^29,88 ^71,88", 0.45)
            g.hatch("^56,76 ^66,76 ^70,92 ^58,92 z", angle: 64, gap: 2.6, w: 0.5)
        }
        g.accent("^31,94 ^69,94 ^70,97.5 ^30,97.5 z")
        g.shape(-1, .circle(78, 80, 4.2), 0.8)
        g.line("^72,80 ^74,80", 0.7)
        // Glow, a few soft marks and no more.
        g.detail(0.18) { g in
            g.line("^16,42 ^22,44", 0.55)
            g.line("^18,58 ^24,57", 0.55)
            g.line("^84,42 ^78,44", 0.55)
            g.line("^82,58 ^76,57", 0.55)
        }
        return g
    }

    static func mushrooms() -> DoodleGlyph {
        var g = DoodleGlyph("mushrooms", 0.1, 0.33, tilt: 10)
        g.must = true
        // The little one behind.
        g.shape(-1, "^80,76 78,88 ^76,100 ^92,100 90,88 ^88,76 z", 1)
        g.shape(2, "^64,76 66,62 76,54 86,54 96,62 ^102,76 92,80 74,80 z", 1.1)
        g.blot(.circle(82, 63, 2.3))
        g.blot(.circle(73, 68, 1.6))
        // The big one.
        g.shape(-1, "^38,48 36,70 ^28,100 ^62,100 56,70 ^54,48 z", 1.2)
        g.shape(-1, "6,46 26,56 46,58 66,56 86,46 z", 0.9)
        g.detail(0.13) { g in
            for x in [16.0, 24.0, 32.0, 40.0, 48.0, 56.0, 64.0, 72.0] { g.line("^\(x),50 ^\((x + 46) / 2),57", 0.42) }
        }
        g.shape(2, "^4,46 6,28 24,8 46,2 68,8 86,28 ^90,46 70,50 46,52 24,50 z", 1.35)
        // Skin spots, each a loose ring.
        for (x, y, r) in [(46.0, 16.0, 7.0), (24.0, 30.0, 5.6), (68.0, 30.0, 6.2), (47.0, 38.0, 4.6), (14.0, 43.0, 2.8), (80.0, 43.0, 2.8)] {
            g.shape(-1, .ellipse(x, y, r, r * 0.84), 0.75)
        }
        g.line("36,64 46,70 ^56,64", 0.85)
        g.detail(0.14) { g in
            g.line("38,66 ^38,70", 0.4)
            g.line("44,68 ^44,73", 0.4)
            g.line("50,68 ^50,73", 0.4)
            g.hatch("^48,74 ^55,72 ^60,98 ^50,98 z", angle: 66, gap: 2.8, w: 0.5)
        }
        // Grass at the foot.
        g.line("^18,104 ^14,92 ^24,102", 0.75)
        g.line("^66,104 ^68,94 ^72,104", 0.7)
        g.line("^8,105 40,104 ^100,105", 0.7)
        return g
    }

    static func cone() -> DoodleGlyph {
        var g = DoodleGlyph("cone", 0.08, 0.22, tilt: 40)
        // A sprig of needles.
        for i in 0..<9 {
            let a = -160.0 + Double(i) * 18
            let r = i % 2 == 0 ? 24.0 : 18.0
            g.line(.poly([(40, 12), (40 + r * cos(a * .pi / 180), 12 + r * sin(a * .pi / 180))]), 0.7)
        }
        g.line("^40,18 ^40,6", 1)
        // Scales, top rows first so lower ones lie over them.
        let rows = 7
        for r in stride(from: rows - 1, through: 0, by: -1) {
            let f = Double(r) / Double(rows - 1)
            let y = 18 + f * 72
            let half = 28 * sin(.pi * (0.16 + 0.74 * f))
            let n = r % 2 == 0 ? 4 : 3
            let wScale = 2 * half / Double(n)
            for i in 0..<n {
                let x = 40 - half + wScale * (Double(i) + 0.5)
                let sw = wScale * 0.62, sh = 12.5
                g.shape(0, "^\(x - sw),\(y - 3) \(x - sw * 0.72),\(y + sh * 0.6) ^\(x),\(y + sh) \(x + sw * 0.72),\(y + sh * 0.6) ^\(x + sw),\(y - 3) z", 0.8)
                g.detail(0.11) { $0.line("^\(x),\(y + sh * 0.2) ^\(x),\(y + sh * 0.78)", 0.45) }
            }
        }
        return g
    }

    static func mug() -> DoodleGlyph {
        var g = DoodleGlyph("mug", 0.09, 0.26, tilt: 14)
        g.whole = true
        g.line("26,4 30,-2 26,-8 30,-14", 0.8)
        g.line("44,6 48,0 44,-6 48,-12 44,-18", 0.8)
        g.line("88,30 106,30 110,44 104,60 ^88,64", 1.25)
        g.line("88,38 100,38 102,46 98,54 ^88,56", 0.8)
        g.shape(-1, "^12,16 ^88,16 88,70 80,82 ^20,82 12,70 z", 1.3)
        g.shape(1, .ellipse(50, 16, 38, 7.5), 1.1)
        g.shape(2, .ellipse(50, 16, 31, 4.6), 0.75)
        // Blue-rim enamel with a little range on its side.
        g.blot("^28,58 ^40,38 ^46,48 ^52,42 ^70,58 z")
        g.gel("^40,42 ^36,48 ^41,46 ^44,49", 0.55)
        g.detail(0.12) { g in
            g.hatch("^72,22 ^87,20 ^87,70 ^78,80 ^72,80 z", angle: 64, gap: 2.9, w: 0.5)
            g.line(.circle(24, 72, 1.3), 0.5)
            g.line(.circle(30, 76, 0.8), 0.4)
            g.gel("20,26 20,42", 0.9)
            g.line("^14,72 20,80 ^60,81", 0.4)
        }
        return g
    }

    static func canoe() -> DoodleGlyph {
        var g = DoodleGlyph("canoe", 0.22, 0.44, tilt: 8)
        // Paddle leaning across it.
        g.line("^92,-12 ^70,30", 1)
        g.line(.circle(93, -14, 2), 0.7)
        // Hull.
        g.shape(1, "^-2,8 ^4,4 8,14 30,20 70,22 104,20 124,12 ^128,2 ^134,6 130,20 116,36 86,46 50,46 22,38 6,24 z", 1.3)
        g.shape(0, "^6,12 30,20 70,22 104,20 ^126,10 120,17 104,25 70,28 34,26 14,20 z", 0.9)
        g.detail(0.22) { g in
            g.stitch("10,20 34,29 70,32 ^122,20", dash: 2.6, gap: 2, w: 0.42)
            g.hatch("^70,34 ^108,30 ^122,24 ^112,36 86,45 ^70,46 z", angle: 66, gap: 3, w: 0.5)
            for x in [30.0, 44.0, 58.0] { g.line("^\(x),30 ^\(x - 1),42", 0.4) }
        }
        // Thwart bands, a pack in the bow.
        g.shape(2, "^-1,12 ^6,10 12,28 ^7,28 z", 0.8)
        g.shape(2, "^133,9 ^127,6 122,26 ^127,24 z", 0.8)
        // Paddle blade, near the water.
        g.shape(2, "^72,26 ^66,28 58,42 56,54 62,56 ^68,44 z", 1)
        // Water.
        g.line("-8,54 4,51 16,54 28,51 40,54 ^48,53", 0.75)
        g.line("76,56 88,53 100,56 112,53 124,56 ^136,54", 0.75)
        g.line("20,61 32,58 44,61 56,58 68,61 ^78,60", 0.7)
        g.line("100,63 110,61 120,63", 0.6)
        return g
    }

    static func binoculars() -> DoodleGlyph {
        var g = DoodleGlyph("binoculars", 0.11, 0.3, tilt: 26)
        g.line("10,38 -6,28 -10,50 2,72", 0.8)
        g.line("90,38 106,28 110,50 98,72", 0.8)
        // Bridge between them.
        g.shape(1, .rrect(38, 24, 24, 22, 3), 1.05)
        g.shape(-1, .rrect(44, 18, 12, 10, 2), 0.85)
        g.detail(0.14) { g in
            for x in [46.5, 50.0, 53.5] { g.line("^\(x),19.5 ^\(x),26.5", 0.42) }
        }
        for c in [24.0, 76.0] {
            // Eyepiece.
            g.shape(1, "^\(c - 10),6 ^\(c + 10),6 ^\(c + 12),24 ^\(c - 12),24 z", 1.1)
            g.shape(-1, .ellipse(c, 6, 10, 3.2), 0.85)
            // Barrel.
            g.shape(0, "^\(c - 12),24 ^\(c + 12),24 ^\(c + 17),84 ^\(c - 17),84 z", 1.25)
            g.shape(1, "^\(c - 14.4),54 ^\(c + 14.4),54 ^\(c + 15.4),64 ^\(c - 15.4),64 z", 0.8)
            g.shape(2, .ellipse(c, 84, 17, 6), 1.05)
            g.blot(.ellipse(c, 84.6, 11, 3.6))
            g.detail(0.15) { g in
                g.gel("\(c - 8),30 \(c - 10.5),50", 0.8)
                g.hatch(.poly([(c + 2, 26), (c + 11, 26), (c + 14, 52), (c + 3, 52)], closed: true), angle: 64, gap: 2.6, w: 0.5)
                g.line("^\(c - 13),75 ^\(c + 13),75", 0.42)
            }
        }
        return g
    }

    static func stump() -> DoodleGlyph {
        var g = DoodleGlyph("stump", 0.11, 0.3, tilt: 6)
        // Bark and roots.
        g.shape(1, "^6,28 ^94,28 94,60 104,78 ^112,86 88,82 72,88 ^62,84 ^44,90 30,82 ^8,88 ^-6,88 6,70 z", 1.25)
        g.detail(0.13) { g in
            g.line("^16,40 ^14,68", 0.55)
            g.line("^28,44 ^29,76", 0.55)
            g.line("^44,42 ^44,74", 0.55)
            g.line("^60,44 ^62,74", 0.55)
            g.line("^76,42 ^78,74", 0.55)
            g.line("^88,44 ^92,68", 0.55)
            g.hatch("^68,40 ^92,38 ^94,62 ^100,76 ^76,80 z", angle: 66, gap: 3.4, w: 0.45)
        }
        // End grain.
        g.shape(-1, .ellipse(50, 26, 45, 16), 1.25)
        g.line(.ellipse(50, 26, 34, 11.6), 0.55)
        g.line(.ellipse(51, 26, 23, 7.6), 0.55)
        g.line(.ellipse(50, 26, 12, 4), 0.55)
        g.line(.ellipse(50, 26, 4, 1.4), 0.5)
        g.line("^52,26 ^66,18 ^72,12", 0.65)
        // A sprout on the side.
        g.line("100,34 102,22 ^100,10", 0.8)
        g.shape(0, "^100,12 92,6 88,-2 96,-2 ^101,8 z", 0.75)
        g.shape(0, "^101,14 108,6 116,6 112,14 ^102,18 z", 0.75)
        return g
    }

    static func fox() -> DoodleGlyph {
        var g = DoodleGlyph("fox", 0.1, 0.25, tilt: 14)
        g.whole = true
        // Ears.
        g.shape(2, "^14,36 8,6 ^38,20 z", 1.15)
        g.shape(2, "^86,36 92,6 ^62,20 z", 1.15)
        g.shape(-1, "^17,28 13,14 ^30,22 z", 0.6)
        g.shape(-1, "^83,28 87,14 ^70,22 z", 0.6)
        g.detail(0.16) { g in
            g.line("^18,25 ^16,18", 0.42)
            g.line("^23,25 ^21,19", 0.42)
            g.line("^82,25 ^84,18", 0.42)
            g.line("^77,25 ^79,19", 0.42)
        }
        // Head.
        g.shape(2, "^4,46 14,30 34,20 50,18 66,20 86,30 ^96,46 82,60 66,76 ^50,92 34,76 18,60 z", 1.3)
        // White of the cheeks and muzzle.
        g.shape(-1, "^4,46 18,50 36,56 ^50,72 ^64,56 82,50 ^96,46 82,60 66,76 ^50,92 34,76 18,60 z", 0.8)
        g.accent("^44,84 ^56,84 54,90 ^50,93 46,90 z")
        g.accent(.ellipse(32, 44, 3, 3.6))
        g.accent(.ellipse(68, 44, 3, 3.6))
        g.gel(.circle(31, 43, 0.8), 0.45)
        g.gel(.circle(67, 43, 0.8), 0.45)
        g.detail(0.13) { g in
            g.line("^50,24 ^50,36", 0.5)
            g.line("^44,26 ^46,34", 0.45)
            g.line("^56,26 ^54,34", 0.45)
            g.line("^12,54 ^18,56", 0.5)
            g.line("^88,54 ^82,56", 0.5)
            g.line("^20,64 ^26,64", 0.5)
            g.line("^80,64 ^74,64", 0.5)
        }
        g.detail(0.17) { g in
            // Brow, the bridge of the nose, fur along the crown and down the cheeks.
            g.line("24,37 30,35 ^38,38", 0.5)
            g.line("76,37 70,35 ^62,38", 0.5)
            g.line("^42,52 46,62 ^48,70", 0.42)
            g.line("^58,52 54,62 ^52,70", 0.42)
            for (x, y, dx, dy) in [(28.0, 28.0, -1.0, 4.0), (36.0, 25.0, -0.6, 4.0), (64.0, 25.0, 0.6, 4.0), (72.0, 28.0, 1.0, 4.0),
                                   (14.0, 42.0, 1.0, 3.6), (86.0, 42.0, -1.0, 3.6), (22.0, 46.0, 0.8, 3.2), (78.0, 46.0, -0.8, 3.2)] {
                g.line(.poly([(x, y), (x + dx, y + dy)]), 0.42)
            }
            g.blot(.circle(38, 70, 0.8))
            g.blot(.circle(42, 75, 0.8))
            g.blot(.circle(62, 70, 0.8))
            g.blot(.circle(58, 75, 0.8))
        }
        return g
    }

    static func fern() -> DoodleGlyph {
        var g = DoodleGlyph("fern", 0.1, 0.32, tilt: 40)
        // A frond: leaflets in pairs along a bending stem, shrinking toward the tip.
        var stem: [(Double, Double)] = []
        let n = 13
        for i in 0...n {
            let t = Double(i) / Double(n)
            stem.append((30 * sin(t * 1.5) * t * 1.2, 100 - t * 104))
        }
        for i in 1...n {
            let t = Double(i) / Double(n)
            let (x, y) = stem[i]
            let (px, py) = stem[i - 1]
            let a = atan2(y - py, x - px)
            let len = 26 * pow(1 - t, 0.7) + 3.4
            for side in [-1.0, 1.0] {
                let b = a + side * (1.05 - t * 0.2)
                let tip = (x + len * cos(b), y + len * sin(b))
                let nx = -sin(b) * len * 0.2, ny = cos(b) * len * 0.2
                let m = (x + len * 0.45 * cos(b), y + len * 0.45 * sin(b))
                g.shape(0, "^\(x),\(y) \(m.0 + nx),\(m.1 + ny) ^\(tip.0),\(tip.1) \(m.0 - nx),\(m.1 - ny) z", 0.65)
            }
        }
        g.line(.spline(stem), 0.9)
        return g
    }

    static func oak() -> DoodleGlyph {
        var g = DoodleGlyph("oak", 0.06, 0.2, tilt: 90)
        g.shape(0, "^50,4 60,10 62,20 ^56,24 70,24 76,34 ^66,42 ^78,46 80,58 ^66,62 ^72,72 ^60,78 ^52,76 ^50,92 ^48,76 ^40,78 ^28,72 ^34,62 ^20,58 22,46 ^34,42 ^24,34 30,24 ^44,24 38,20 40,10 z", 1.05)
        g.line("^50,10 ^50,104", 0.8)
        g.line("^50,32 ^66,28", 0.5)
        g.line("^50,46 ^70,50", 0.5)
        g.line("^50,60 ^64,70", 0.5)
        g.line("^50,32 ^34,28", 0.5)
        g.line("^50,46 ^30,50", 0.5)
        g.line("^50,60 ^36,70", 0.5)
        return g
    }

    static func acorn() -> DoodleGlyph {
        var g = DoodleGlyph("acorn", 0.05, 0.16, tilt: 60)
        g.shape(1, "^14,32 16,58 32,84 ^40,92 ^48,84 64,58 ^66,32 z", 1.15)
        g.detail(0.09) {
            $0.gel("23,42 25,58 ^31,70", 0.8)
            $0.hatch("^52,44 ^64,40 58,62 ^46,80 z", angle: 64, gap: 2.8, w: 0.5)
        }
        g.line("^40,8 44,0 ^52,-4", 1.05)
        g.shape(0, "^8,30 12,16 28,8 52,8 68,16 ^72,30 56,35 40,36 24,35 z", 1.2)
        g.detail(0.09) { g in
            g.hatch("^12,14 ^68,14 ^70,32 ^10,32 z", angle: 45, gap: 5, w: 0.42)
            g.hatch("^12,14 ^68,14 ^70,32 ^10,32 z", angle: 135, gap: 5, w: 0.42)
        }
        return g
    }

    static func kettle() -> DoodleGlyph {
        var g = DoodleGlyph("kettle", 0.1, 0.32, tilt: 12)
        // Steam from the spout, wire bail over the top.
        g.line("^18,14 14,6 19,-2 ^15,-10", 0.7)
        g.line("^26,16 24,10 ^28,3", 0.6)
        g.line("^40,24 36,4 56,-6 76,4 ^72,24", 1)
        g.blot(.circle(40, 24, 1.7))
        g.blot(.circle(72, 24, 1.7))
        // Spout, handle.
        g.shape(1, "^36,40 26,28 ^16,18 ^24,14 36,24 ^44,30 z", 1.1)
        g.line("88,34 104,36 106,54 96,72 ^84,76", 1.3)
        g.line("88,40 99,41 100,54 92,66 ^84,69", 0.75)
        // A speckled enamel body flaring to the base.
        g.shape(0, "^38,28 ^74,28 80,44 90,76 ^92,96 ^20,96 ^22,76 32,44 z", 1.35)
        g.shape(-1, .ellipse(56, 28, 18.5, 4.8), 1)
        g.shape(1, .ellipse(56, 26, 15, 3.8), 0.85)
        g.shape(1, .circle(56, 19, 3.8), 0.9)
        g.line("^22,86 ^90,86", 0.7)
        g.detail(0.13) { g in
            g.hatch("^70,34 ^76,34 ^88,84 ^72,84 z", angle: 66, gap: 3, w: 0.5)
            g.gel("^36,44 ^30,68", 1)
            var rng = SplitMix64(seed: 31)
            for _ in 0..<26 {
                let y = rng.next(36, 84)
                let half = 18 + (y - 30) * 0.42
                let x = 56 + rng.next(-1, 0.4) * half
                g.blot(.circle(x, y, rng.next(0.55, 0.95)))
            }
        }
        // Ashes and a stone or two.
        g.shape(-1, .ellipse(10, 98, 9, 5), 0.85)
        g.shape(-1, .ellipse(102, 98, 9, 5), 0.85)
        g.line("^-4,104 56,102 ^116,104", 0.65)
        return g
    }

    static func signpost() -> DoodleGlyph {
        var g = DoodleGlyph("signpost", 0.1, 0.34, tilt: 8)
        // A post, driven in among the grass.
        g.shape(1, "^38,2 ^50,0 ^50,120 ^38,120 z", 1.2)
        g.detail(0.14) { g in
            g.line("^42,12 41,50 ^43,84", 0.42)
            g.line("^47,28 48,70 ^46,108", 0.42)
        }
        // Three boards, pointing their own ways, each with a little trail mark and no words.
        g.shape(-1, "^24,10 ^78,6 ^94,20 ^80,34 ^24,36 z", 1.15)
        g.shape(0, "^66,40 ^6,38 ^-10,54 ^6,68 ^66,68 z", 1.15)
        g.shape(-1, "^22,74 ^72,74 ^86,86 ^72,98 ^22,98 z", 1.1)
        g.blot("^36,28 ^44,16 ^50,24 ^55,18 ^62,28 z")
        g.gel("^44,20 ^42,23 ^45,22 ^46,24", 0.45)
        conifer(&g, cx: 22, top: 42, bottom: 62, half: 8, tiers: 2, w: 0.65, seed: 7, needles: false)
        g.stitch("^34,54 ^60,52", dash: 2.6, gap: 2.4, w: 0.8)
        g.line("^30,86 40,82 ^46,88 52,84 ^62,86", 0.75)
        g.detail(0.14) { g in
            for (x, y) in [(30.0, 13.0), (70.0, 10.0), (12.0, 44.0), (58.0, 44.0), (28.0, 78.0), (68.0, 78.0)] { g.blot(.circle(x, y, 1)) }
            g.line("^70,14 ^72,30", 0.4)
            g.line("^28,60 ^56,62", 0.4)
        }
        g.line("^44,120 ^26,120", 0.8)
        g.line("^20,124 ^18,114 ^25,122", 0.75)
        g.line("^62,124 ^66,112 ^68,122", 0.75)
        g.line("^10,126 44,124 ^86,126", 0.75)
        return g
    }

    static func cloud() -> DoodleGlyph {
        var g = DoodleGlyph("cloud", 0.06, 0.2, tilt: 8)
        g.shape(-1, "8,44 2,34 8,24 20,22 24,12 38,6 52,10 60,18 72,16 84,24 88,36 82,44 z", 1.05)
        g.line("26,26 34,22 40,28", 0.6)
        g.line("58,32 66,28 72,32", 0.55)
        g.line("^18,50 ^44,50", 0.55)
        g.line("^50,54 ^70,54", 0.5)
        return g
    }

    static func birds() -> DoodleGlyph {
        var g = DoodleGlyph("birds", 0.05, 0.14, tilt: 18)
        g.line("0,10 8,3 ^14,10 22,3 ^30,8", 0.9)
        g.line("36,24 42,18 ^47,24 54,18 ^60,22", 0.8)
        g.line("10,30 15,25 ^19,30 24,25 ^28,29", 0.7)
        return g
    }

    static func paw() -> DoodleGlyph {
        var g = DoodleGlyph("paw", 0.03, 0.065, tilt: 40)
        g.shape(1, "30,40 42,44 50,58 42,68 30,64 18,68 10,58 18,44 z", 0.9)
        g.shape(1, .ellipse(10, 34, 6.6, 9, rot: -24), 0.8)
        g.shape(1, .ellipse(24, 22, 6.8, 9.4, rot: -8), 0.8)
        g.shape(1, .ellipse(39, 22, 6.8, 9.4, rot: 8), 0.8)
        g.shape(1, .ellipse(52, 34, 6.6, 9, rot: 24), 0.8)
        return g
    }

    static func tinyPine() -> DoodleGlyph {
        var g = DoodleGlyph("tinyPine", 0.04, 0.12, tilt: 8)
        conifer(&g, cx: 20, top: 0, bottom: 56, half: 18, tiers: 3, w: 0.85, seed: 90, needles: false)
        return g
    }

    static func rocks() -> DoodleGlyph {
        var g = DoodleGlyph("rocks", 0.05, 0.16, tilt: 5)
        g.shape(1, "^4,44 10,22 28,8 46,14 ^58,44 z", 1.05)
        g.shape(-1, "^44,44 50,28 66,22 80,32 ^86,44 z", 1)
        g.line("^28,8 ^26,24 ^36,34", 0.55)
        g.detail(0.08) {
            $0.hatch("^34,20 ^46,18 ^56,42 ^38,42 z", angle: 62, gap: 2.8, w: 0.5)
        }
        g.line("^-4,46 40,45 ^92,46", 0.7)
        return g
    }
}
