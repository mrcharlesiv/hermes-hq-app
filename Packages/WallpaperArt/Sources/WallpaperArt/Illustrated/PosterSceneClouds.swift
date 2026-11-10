// Sea of clouds: a cloud deck, peaks breaking through, a dark bank and conifers close by. Design space x 0...1000, y 0...2168.

import CoreGraphics
import Foundation

private typealias P = PosterP

nonisolated extension Poster {
    static func clouds(_ c: PosterCanvas, dark: Bool) {
        let horizon = 1110.0
        let glow = P(250, 1100)
        var rng = SplitMix64(seed: 0xC10D_0001)

        // The night's own colour is an ember along the whole horizon, behind the peaks.
        let skyRamp = PosterRamp(dark
            ? [(0, hx(0x050817)), (0.25, hx(0x0B0F2A)), (0.5, hx(0x141838)), (0.7, hx(0x211C42)), (0.85, hx(0x402444)), (1, hx(0x7A4034))]
            : [(0, hx(0x2B3A78)), (0.2, hx(0x4C4F92)), (0.4, hx(0x8665A4)), (0.56, hx(0xC8789C)), (0.72, hx(0xF2A07E)), (0.88, hx(0xFBCB94)), (1, hx(0xFFE9BE))], step: 1)
        c.pull(skyRamp, amp: 0.04, key: 1, rows: (0, c.row(horizon) + 90)) { x, y in
            if dark { return Float(0.86 * pow(y / horizon, 1.15)) + 0.14 * Float(dsstep(900, 1190, y)) }
            let dd = hypot(x - glow.x, (y - glow.y) * 0.9)
            return Float(0.7 * y / horizon + 0.42 * exp(-dd / 560))
        }

        // Long flat clouds low in the sky, cut with tapered ends: the only thing up there.
        do {
            var r = SplitMix64(seed: 0xBA27)
            var bodies: [[P]] = []
            for (x0, x1, y, up, dn): (Double, Double, Double, Double, Double) in [(-140, 420, 806, 15, 6), (610, 1150, 742, 11, 5), (-90, 210, 886, 9, 4), (690, 1130, 860, 13, 5), (-60, 360, 962, 14, 6)] {
                bodies.append(PosterCut.spindle(x0: x0, x1: x1, y: y, up: up, down: dn, skew: 0.56, rng: &r))
            }
            let body = PosterPlate(c) { g in for b in bodies { fillPoly(g, b) } }
            c.flat(dark ? hx(0x141632) : hx(0x8A5F9E), plate: body, opacity: dark ? 0.9 : 0.85)
            let lit = PosterPlate(c) { g in
                for b in bodies {
                    g.saveGState()
                    g.beginPath()
                    poly(g, b)
                    g.clip()
                    fillPoly(g, b.map { P($0.x - 8, $0.y + 5) })
                    g.restoreGState()
                }
            }
            c.flat(dark ? hx(0x271D3A) : hx(0xF0A07C), plate: lit, opacity: dark ? 0.8 : 0.8)
        }

        // Far range, flat: the first step of air.
        let farPts = cut([P(-30, 1110), P(70, 1040), P(150, 1062), P(250, 1010), P(320, 1044), P(420, 1020), P(520, 1060), P(640, 1020), P(760, 1040), P(860, 990), P(950, 1020), P(1030, 1000), P(1030, 1220), P(-30, 1220)], amp: 0.08, minLen: 16, rng: &rng)
        let farP = PosterPlate(c) { g in fillPoly(g, farPts) }
        c.flat(dark ? hx(0x241A38) : hx(0xD79AA6), plate: farP)

        let inks = dark
            ? PosterAlpInks(rockDeep: hx(0x040715), rockShadow: hx(0x070B1E), rockMid: hx(0x15163A), rockLit: hx(0x2E2340),
                      snowDeep: hx(0x080C24), snowShadow: hx(0x0C1130), snowMid: hx(0x28315C), snowLit: hx(0x4E5A88), snowTop: hx(0x7E5C6E), rim: hx(0x9E7A74))
            : PosterAlpInks(rockDeep: hx(0x2A2B6A), rockShadow: hx(0x3B3A82), rockMid: hx(0x7C5C94), rockLit: hx(0xB57F9C),
                      snowDeep: hx(0x45448A), snowShadow: hx(0x6E63A4), snowMid: hx(0xC68DAE), snowLit: hx(0xFFEDCF), snowTop: hx(0xFBBE8E), rim: hx(0xFFF4DC))
        let style = PosterAlpStyle(light: PosterLight(-0.78, -0.3, 0.56), inks: inks, rockLine: 0.40, rockWidth: 130)
        func arete(_ pts: [P], h: Double, k: Double, fade: Double = 0.78, rampIn: Double = 0.03) -> PosterRidge {
            PosterAlp.ridge(pts, h: h, k: k, amp: 0.07, len: 22, fade: fade, rampIn: rampIn, rng: &rng)
        }
        func peak(skyline: [P], top: Double, foot: Double, mains: [PosterRidge], second: [PosterRidge], spurEvery: Double, warm: @escaping (Double) -> Double, haze: PosterInk, hazeOp: Double, seed: UInt32, key: Int) {
            let line = cut(skyline, amp: 0.05, minLen: 12, rng: &rng)
            var third: [PosterRidge] = []
            for r in mains {
                let l = hypot(r.pts.last!.x - r.pts[0].x, r.pts.last!.y - r.pts[0].y)
                third += spurs(of: r, count: Int(l / spurEvery), length: 36...120, hFrac: 0.26, k: 1.5, from: 0.05, to: 0.82, spread: 30...56, rng: &rng)
            }
            third.removeAll { $0.pts.last!.x > $0.pts[0].x + 6 && $0.pts[0].y < foot - (foot - top) * 0.42 && $0.pts[0].x > mains[0].pts[0].x - 20 }
            for r in second { third += spurs(of: r, count: 2, length: 24...70, hFrac: 0.42, k: 1.5, from: 0.1, to: 0.8, spread: 30...56, rng: &rng) }
            let mask = PosterAlp.paint(c, skyline: line, bottom: foot + 40, top: top, foot: foot, slope: 0.5, levels: [mains, second, third], rockRidges: [(mains, 1), (second, 0.7)], style: style,
                                 warmLine: warm, tint: dark ? hx(0x2A2C50) : hx(0xFFE8CC), seed: seed, key: key)
            // The air steps in over the foot: two cut bands, not a smooth fog.
            if hazeOp > 0 {
                let b = PosterPlate(c) { g in fillPoly(g, PosterCut.wavyBand(y: foot - (foot - top) * 0.18, tilt: -0.05, waves: [(22, 140, Double(key) * 1.7), (8, 53, 2.2), (3, 19, 0.4)], floorY: foot + 50)) }
                b.intersect(mask)
                c.flat(haze, plate: b, opacity: hazeOp * 0.4)
            }
        }

        // Back peaks at very different scales, both cropped by the frame and overlapped by the hero, each with its own alpenglow line.
        peak(skyline: [P(-60, 1000), P(-10, 930), P(34, 882), P(70, 806), P(96, 826), P(132, 894), P(176, 940), P(240, 1030), P(330, 1170)], top: 806, foot: 1190,
             mains: [arete([P(70, 806), P(46, 892), P(0, 980), P(-50, 1190)], h: 90, k: 0.98), arete([P(70, 806), P(86, 900), P(126, 990), P(150, 1190)], h: 90, k: 0.98)],
             second: [], spurEvery: 70, warm: { x in 880 - 0.5 * (x - 70) }, haze: dark ? hx(0x161631) : hx(0xE6AAA8), hazeOp: 0.85, seed: 92, key: 42)
        peak(skyline: [P(600, 1190), P(690, 1040), P(756, 930), P(796, 866), P(832, 760), P(884, 634), P(914, 672), P(946, 742), P(990, 800), P(1060, 890)], top: 634, foot: 1190,
             mains: [arete([P(884, 634), P(866, 740), P(830, 860), P(796, 990), P(776, 1190)], h: 150, k: 0.98), arete([P(884, 634), P(906, 760), P(952, 880), P(1010, 1190)], h: 150, k: 0.98)],
             second: [arete([P(830, 860), P(866, 950), P(876, 1060)], h: 54, k: 1.25, rampIn: 0.22)], spurEvery: 84, warm: { x in 746 + 0.34 * (x - 884) }, haze: dark ? hx(0x161631) : hx(0xE2A4AC), hazeOp: 0.8, seed: 91, key: 40)

        // The hero: one dominant point, a long lit west shoulder, a clean shadow plane to the east.
        let hm1 = arete([P(590, 462), P(562, 580), P(520, 700), P(478, 820), P(400, 960), P(316, 1100), P(250, 1300)], h: 320, k: 0.98)
        let hm2 = arete([P(590, 462), P(606, 590), P(590, 730), P(628, 880), P(604, 1030), P(660, 1180), P(690, 1320)], h: 320, k: 0.98)
        let hm3 = arete([P(436, 760), P(376, 870), P(296, 980), P(190, 1110), P(60, 1300)], h: 190, k: 0.98, rampIn: 0.1)
        let hm4 = arete([P(800, 790), P(786, 880), P(822, 990), P(796, 1110), P(860, 1320)], h: 160, k: 0.98, rampIn: 0.1)
        let hSecond = [
            arete([P(520, 700), P(458, 770), P(404, 824), P(350, 880)], h: 66, k: 1.25, rampIn: 0.22),
            arete([P(478, 820), P(516, 930), P(500, 1050), P(530, 1300)], h: 104, k: 1.25, rampIn: 0.22),
            arete([P(590, 730), P(546, 846), P(560, 980), P(540, 1280)], h: 110, k: 1.25, rampIn: 0.22),
            arete([P(628, 880), P(700, 980), P(722, 1100), P(770, 1300)], h: 84, k: 1.25, rampIn: 0.22),
            arete([P(306, 980), P(304, 1050), P(272, 1120)], h: 44, k: 1.2, fade: 0.3, rampIn: 0.22),
            arete([P(170, 1100), P(170, 1160), P(140, 1230)], h: 36, k: 1.2, fade: 0.3, rampIn: 0.22),
            arete([P(398, 880), P(392, 960), P(356, 1030)], h: 46, k: 1.2, fade: 0.3, rampIn: 0.22),
            arete([P(822, 990), P(884, 1060), P(930, 1180)], h: 54, k: 1.25, rampIn: 0.22)
        ]
        peak(skyline: [P(-30, 1290), P(70, 1190), P(130, 1130), P(170, 1100), P(206, 1106), P(262, 1020), P(306, 980), P(344, 990), P(398, 880), P(436, 760), P(462, 772), P(504, 656), P(556, 528), P(590, 462), P(622, 540), P(650, 590), P(690, 680), P(726, 724), P(762, 800), P(800, 790), P(848, 862), P(910, 960), P(990, 1090), P(1060, 1180)],
             top: 462, foot: 1330, mains: [hm1, hm2, hm3, hm4], second: hSecond, spurEvery: 78, warm: { x in 590 - 0.36 * (x - 590) }, haze: dark ? hx(0x13183A) : hx(0xEDB6B0), hazeOp: 0.85, seed: 93, key: 44)

        // A thin stratus crosses in front of the hero's foot, and stepped mist lies behind the deck's first row.
        do {
            var r = SplitMix64(seed: 0x57A7)
            let thin = PosterPlate(c) { g in
                fillPoly(g, PosterCut.spindle(x0: 200, x1: 640, y: 1090, up: 13, down: 5, skew: 0.38, rng: &r))
                fillPoly(g, PosterCut.spindle(x0: 600, x1: 1010, y: 1102, up: 11, down: 4, skew: 0.6, rng: &r))
            }
            c.flat(dark ? hx(0x1C1F44) : hx(0xF2BCA6), plate: thin)
        }

        // The deck, far to near. Each plane has its own scale and value; lobes only bend the edges of the big shapes.
        let sun = P(150, 1000)
        let planes: [(y: Double, size: Double, aspect: Double, warm: Double, inner: Int)] = [
            (1150, 12, 3.0, 1.0, 3), (1172, 17, 3.0, 1.0, 3), (1202, 24, 2.8, 1.0, 4), (1242, 34, 2.6, 0.96, 5), (1298, 50, 2.3, 0.9, 6),
            (1380, 72, 2.1, 0.8, 9), (1488, 100, 2.0, 0.68, 11), (1630, 136, 1.9, 0.54, 13),
            (1810, 182, 1.8, 0.42, 16), (2030, 240, 1.75, 0.3, 18)
        ]
        // The hero's shadow on the deck: cut by hand, from its foot out to the lower right, a core and a penumbra.
        @inline(__always) func wedgeAt(_ x: Double, _ y: Double) -> Float {
            let t = y - 1180
            if t < 0 { return 0 }
            let centre = 690 + 0.56 * t
            let half = 110 + 0.27 * t
            let d = abs(x - centre)
            if d < half * 0.68 { return 1 }
            if d < half { return 0.5 }
            return 0
        }
        let count = planes.count
        for (pi, pl) in planes.enumerated() {
            let depth = Double(pi) / Double(count - 1)
            var heaps: [(x: Double, y: Double, rx: Double, ry: Double)] = []
            var x = -pl.size * 1.2 + rng.next(0, pl.size)
            while x < 1000 + pl.size * 1.4 {
                let pick = rng.next()
                let s = pl.size * (pick < 0.16 ? rng.next(1.25, 1.6) : (pick < 0.55 ? rng.next(0.85, 1.15) : rng.next(0.5, 0.75)))
                let rx = s * pl.aspect * 0.62, ry = rx / pl.aspect
                heaps.append((x, pl.y - ry * 0.25 + rng.next(-0.24, 0.24) * pl.size, rx, ry))
                x += rx * rng.next(1.05, 1.5)
            }
            // Mounds climb the valleys and the hero's foot, so the deck has no ruled edge.
            if pi == 0 { heaps += [(40, 1116, 92, 22), (178, 1132, 70, 15), (344, 1130, 84, 17), (470, 1116, 110, 24), (640, 1122, 86, 19), (780, 1110, 124, 26), (930, 1128, 80, 18), (1010, 1100, 96, 24), (734, 1134, 96, 20), (444, 1146, 88, 16)] }
            if pi == 1 { heaps += [(100, 1144, 90, 20), (270, 1148, 84, 18), (420, 1160, 90, 16), (560, 1146, 110, 20), (730, 1156, 90, 18), (880, 1144, 104, 22)] }
            if pi == 8 { heaps += [(460, 1892, 270, 112), (700, 1926, 210, 92)] }
            heaps.sort { $0.y < $1.y }
            var list: [PosterBillow] = []
            for h in heaps { crownHeap(&list, x: h.x, y: h.y, rx: h.rx, ry: h.ry, inner: pl.inner, rng: &rng) }
            let warm = pl.warm
            let farFlat = Float(0.6 * (1 - dsstep(0.2, 0.62, depth)))
            let ramp = PosterRamp(dark
                ? [(0, hx(0x0C1028).mixed(with: hx(0x050818), depth)), (0.3, hx(0x161A3C).mixed(with: hx(0x070B1E), depth)), (0.6, hx(0x262A50).mixed(with: hx(0x0B1028), depth)), (0.85, hx(0x423F62).mixed(with: hx(0x141A38), depth)), (1, hx(0x74586A).mixed(with: hx(0x262C50), depth))]
                : [(0, hx(0x4C4890).mixed(with: hx(0xA87AA8), warm * 0.8)), (0.22, hx(0x6E5AA2).mixed(with: hx(0xCC8AA2), warm * 0.8)), (0.46, hx(0x9A70AE).mixed(with: hx(0xEC9E8E), warm * 0.85)), (0.68, hx(0xD48C9E).mixed(with: hx(0xF9BE8C), warm)), (0.86, hx(0xF9BC8C).mixed(with: hx(0xFDD8A2), warm)), (1, hx(0xFFEAC8))], step: 0.5)
            // Gaps between heaps fall into the plane's darkest ink; only the near valleys reach indigo.
            let backTop = pl.y + pl.size * 0.2 + (pi == 0 ? 8 : 0)
            let backing = PosterPlate(c) { g in fillPoly(g, [P(-40, backTop), P(1040, backTop), P(1040, 2300), P(-40, 2300)]) }
            let valley = dark ? hx(0x070B1E) : hx(0x8A70AC).mixed(with: hx(0x3A3478), pow(depth, 2.2))
            c.flat(valley, plate: backing)
            c.billows(list, ramp: ramp, amp: 0.03, key: 60 + pi, pointLight: sun, lightHeight: 340) { x, y, ndl, form, up, b in
                let prox = Float(exp(-hypot(b.mx - sun.x, (b.my - sun.y) * 0.8) / 1000))
                let size = Float(b.ry / b.mry)
                // A lobe shifts the edge of the big form's light; it makes no shadow of its own.
                let a = 0.2 + 0.5 * sstep(0.06, 0.4, size)
                // A lobe is a bulge, not a disc: its far rim sinks back into the surface, only the side toward the sun has an edge.
                let dxn = Float((x - b.x) / b.rx), dyn = Float((y - b.y) / b.ry)
                let tox = Float(sun.x - b.x), toy = Float(sun.y - b.y)
                let il = 1 / (tox * tox + toy * toy + 1).squareRoot()
                let away = -(dxn * tox + dyn * toy) * il
                let merge = 1 - sstep(0.0, 0.92, away)
                let f = form + a * (ndl - 0.55) * merge
                // The hero's shadow bends over the lobes too.
                let wedge = wedgeAt(x + Double(ndl - 0.55) * b.rx * 0.5, y)
                if dark {
                    // Night light grazes from the ember side: each heap's upper edge carries it, its body falls away and its foot goes into the mist.
                    let fx = Float((x - b.mx) / b.mrx), fy = Float((y - b.my) / b.mry)
                    let hx0 = Float(sun.x - b.mx), hy0 = Float(sun.y - b.my)
                    let hi = 1 / (hx0 * hx0 + hy0 * hy0 + 1).squareRoot()
                    let graze = (fx * hx0 + fy * hy0) * hi
                    let hold = 1 - 0.75 * sstep(0.2, 0.8, graze)
                    let g2 = 0.7 * graze + 0.3 * form + a * 0.6 * hold * (ndl - 0.55) * merge
                    let body = sstep(-0.34, 0.66, g2)
                    let rimT = sstep(0.5, 0.94, g2)
                    return (0.1 + body * 0.26 + rimT * 0.56) * (1 - 0.3 * wedge)
                }
                // Far planes flatten: air takes the shadow out of them, so they stop reading as rows of rolls.
                let big = sstep(-0.32, 1.0, f)
                let held = big + (0.74 - big) * farFlat
                return 0.05 + held * (0.26 + 0.72 * prox) * (1 - 0.6 * wedge)
            }
            // Mist settles low in each plane, so the next one stands clear of it.
            if pi < count - 1 {
                let mistTop = pl.y - pl.size * 0.3, mistBottom = planes[pi + 1].y
                let mist = dark ? hx(0x12183A).mixed(with: hx(0x0A0F28), depth) : hx(0xF3B9A0).mixed(with: hx(0xFCD8A8), warm)
                c.stipple(mist, rows: (max(0, c.row(mistTop)), min(c.h, c.row(mistBottom) + 1)), key: 80 + pi, grainMix: 0.03) { _, y in
                    Float(dsstep(mistTop, mistBottom, y)) * (dark ? 0.55 : 0.34)
                }
            }
        }

        // The foreground: a rock spur falling from the left corner, two conifers and a sapling.
        var r2 = SplitMix64(seed: 700)
        let fg = dark ? hx(0x030612) : hx(0x1E1C4A)
        let treeP = PosterPlate(c) { g in
            fillPoly(g, PosterDraw.conifer(&r2, x: 112, top: 1170, base: 1830, halfW: 130, tiers: 26, lean: 0.05))
            fillPoly(g, PosterDraw.conifer(&r2, x: 14, top: 1380, base: 1830, halfW: 92, tiers: 18, lean: 0.04))
            fillPoly(g, PosterDraw.conifer(&r2, x: 262, top: 1712, base: 1880, halfW: 34, tiers: 8, lean: 0.03))
        }
        c.flat(fg, plate: treeP)
        PosterForeground.ledge(c, line: [P(-40, 1790), P(60, 1772), P(136, 1796), P(210, 1830), P(286, 1846), P(352, 1908), P(452, 1946), P(530, 2008), P(640, 2040), P(760, 2096), P(880, 2112), P(1040, 2150)],
                         foot: 2168, deep: dark ? hx(0x030612) : hx(0x1C1A4A), ledge: dark ? hx(0x0E1430) : hx(0x46397E), rim: dark ? hx(0x3A3550) : hx(0xF9B48E), rng: &r2)

        // Stars last, kept off everything that is not sky.
        if dark {
            let behind = PosterPlate(c) { g in
                fillPoly(g, [P(-40, 1020), P(1040, 1020), P(1040, 2200), P(-40, 2200)])
                g.setLineWidth(40)
                var o = [P(-30, 1290), P(70, 1190), P(170, 1100), P(262, 1020), P(306, 980), P(398, 880), P(436, 760), P(504, 656), P(556, 528), P(590, 462), P(622, 540), P(690, 680), P(762, 800), P(832, 760), P(884, 634), P(914, 672), P(946, 742), P(990, 800), P(1060, 890), P(1060, 2200), P(-30, 2200)]
                fillPoly(g, o)
                g.beginPath()
                poly(g, o)
                g.strokePath()
                o = [P(-60, 1000), P(-10, 930), P(34, 882), P(70, 806), P(96, 826), P(132, 894), P(176, 940), P(240, 1030), P(240, 2200), P(-60, 2200)]
                fillPoly(g, o)
                g.beginPath()
                poly(g, o)
                g.strokePath()
            }
            PosterSky.stars2(c, until: 980, bright: [(170, 240, 2.2), (428, 96, 1.6), (792, 330, 2.5), (262, 610, 1.7)], behind: behind, dots: hx(0xC8C4D8), big: hx(0xF4E8DA), seed: 51)
        }

        c.finish(seed: 0xC0C, tooth: dark ? 0.05 : 0.05, mottle: 0.018, pinholes: dark ? 0.06 : 0.16, paper: hx(0xFFF3DC))
    }
}
