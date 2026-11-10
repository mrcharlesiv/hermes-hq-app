// Mountain lake: a big snowy massif over still water. Design space x 0...1000, y 0...2168.

import CoreGraphics
import Foundation

private typealias P = PosterP

nonisolated extension Poster {
    static func lake(_ c: PosterCanvas, dark: Bool) {
        let shore = 1318.0
        var rng = SplitMix64(seed: 0x51A7_E000)

        // PosterSky: one long dissolve from the zenith to the warm air behind the peak. Blue-green at night: this picture's own colour.
        let skyStops: [(Double, PosterInk)] = dark
            ? [(0, hx(0x030E16)), (0.3, hx(0x05161F)), (0.55, hx(0x08222C)), (0.78, hx(0x0E3039)), (1, hx(0x1A4347))]
            : [(0, hx(0x1E6A8C)), (0.22, hx(0x3A8CA4)), (0.42, hx(0x6AAFB5)), (0.6, hx(0xA6D0C2)), (0.76, hx(0xDCE4C4)), (0.9, hx(0xF8E8C2)), (1, hx(0xFCD9A6))]
        c.pull(PosterRamp(skyStops, step: 1), amp: 0.042, key: 1, rows: (0, c.row(shore) + 2)) { _, y in Float((y + 40) / 1240) }

        // Two long flat clouds behind the massif, low, so the top of the screen stays calm.
        do {
            var r = SplitMix64(seed: 0x1AC7)
            var bodies: [[P]] = [], lit: [[P]] = []
            for (x0, x1, y, up, dn): (Double, Double, Double, Double, Double) in [(-120, 300, 792, 13, 5), (-60, 190, 852, 7, 3), (690, 1130, 590, 9, 4), (760, 1090, 634, 6, 2.5)] {
                let s = PosterCut.spindle(x0: x0, x1: x1, y: y, up: up, down: dn, skew: 0.56, rng: &r)
                bodies.append(s)
                lit.append(s.map { P($0.x + 2, $0.y - (dn * 0.5)) })
            }
            let body = PosterPlate(c) { g in for b in bodies { fillPoly(g, b) } }
            let top = PosterPlate(c) { g in
                g.saveGState()
                for (i, b) in lit.enumerated() {
                    g.saveGState()
                    g.beginPath()
                    poly(g, bodies[i])
                    g.clip()
                    fillPoly(g, b)
                    g.restoreGState()
                }
                g.restoreGState()
            }
            c.flat(dark ? hx(0x0E2C36) : hx(0x8FBEBC), plate: body)
            c.flat(dark ? hx(0x1E464C) : hx(0xFFF4DA), plate: top)
        }

        // A far, pale range: the first step of air.
        let farRange = PosterPlate(c) { g in
            var r = SplitMix64(seed: 300)
            var pts = cut([P(-30, 930), P(52, 836), P(110, 868), P(186, 760), P(246, 812), P(318, 716), P(392, 790), P(470, 720), P(760, 720), P(838, 742), P(910, 668), P(968, 712), P(1030, 690)],
                          amp: 0.08, minLen: 16, rng: &r)
            pts.append(P(1030, 1340))
            pts.append(P(-30, 1340))
            fillPoly(g, pts)
        }
        c.pull(PosterRamp(dark ? [(0, hx(0x123640)), (1, hx(0x173F47))] : [(0, hx(0x8DBDBB)), (1, hx(0xD6E2C8))], step: 0.8), plate: farRange, amp: 0.05, key: 6) { _, y in
            Float((y - 700) / 400)
        }

        // The massif. Ridges fan out of the summit and end far apart at the shore; each is a lit face and a shadow face.
        let skyline = cut([
            P(-60, 1072), P(58, 1002), P(108, 952), P(168, 906), P(214, 838), P(250, 852), P(298, 790), P(348, 692), P(384, 702), P(428, 660), P(468, 576), P(504, 586),
            P(538, 520), P(572, 432), P(600, 442), P(640, 370), P(664, 410), P(688, 396), P(716, 480), P(748, 562), P(770, 622), P(800, 672), P(836, 652), P(872, 610),
            P(902, 658), P(936, 722), P(976, 782), P(1060, 852)
        ], amp: 0.06, minLen: 13, rng: &rng)
        func arete(_ pts: [P], h: Double, k: Double, amp: Double = 0.07, len: Double = 24, fade: Double = 0.78, rampIn: Double = 0.03) -> PosterRidge {
            PosterAlp.ridge(pts, h: h, k: k, amp: amp, len: len, fade: fade, rampIn: rampIn, rng: &rng)
        }
        let m1 = arete([P(640, 370), P(604, 486), P(566, 590), P(516, 716), P(446, 866), P(372, 1010), P(290, 1150), P(240, 1340)], h: 300, k: 0.98)
        let m2 = arete([P(640, 370), P(650, 500), P(636, 640), P(664, 800), P(640, 950), P(690, 1110), P(716, 1340)], h: 300, k: 0.98)
        let m3 = arete([P(468, 576), P(420, 690), P(348, 820), P(268, 930), P(170, 1070), P(40, 1240), P(-60, 1340)], h: 190, k: 0.98)
        let m4 = arete([P(872, 610), P(860, 720), P(884, 850), P(858, 990), P(910, 1150), P(1040, 1340)], h: 190, k: 0.98)
        let m5 = arete([P(872, 610), P(832, 740), P(792, 866), P(768, 1010), P(806, 1190), P(838, 1340)], h: 150, k: 0.98)
        let second = [
            arete([P(566, 590), P(508, 660), P(462, 716), P(402, 770)], h: 72, k: 1.25, rampIn: 0.22),
            arete([P(446, 866), P(492, 976), P(486, 1090), P(516, 1320)], h: 110, k: 1.25, rampIn: 0.22),
            arete([P(636, 640), P(590, 762), P(566, 896), P(586, 1040), P(556, 1300)], h: 120, k: 1.25, rampIn: 0.22),
            arete([P(348, 820), P(364, 930), P(332, 1060), P(362, 1290)], h: 84, k: 1.25, rampIn: 0.22),
            arete([P(664, 800), P(716, 908), P(728, 1040), P(772, 1250)], h: 80, k: 1.25, rampIn: 0.22),
            arete([P(372, 1010), P(306, 1050), P(226, 1090), P(150, 1200)], h: 60, k: 1.25, rampIn: 0.22),
            arete([P(884, 850), P(944, 940), P(994, 1050)], h: 70, k: 1.25, rampIn: 0.22),
            arete([P(832, 740), P(868, 840), P(862, 930)], h: 44, k: 1.25, rampIn: 0.22),
            arete([P(270, 930), P(240, 1010), P(186, 1140)], h: 44, k: 1.25, rampIn: 0.22),
            // Ribs falling from the bumps of the west skyline: this is what breaks up the big lit face.
            arete([P(428, 660), P(424, 730), P(390, 800), P(372, 880)], h: 50, k: 1.2, fade: 0.3, rampIn: 0.22),
            arete([P(348, 692), P(340, 770), P(304, 846), P(276, 900)], h: 44, k: 1.2, fade: 0.3, rampIn: 0.22),
            arete([P(214, 838), P(214, 900), P(186, 980), P(150, 1050)], h: 44, k: 1.2, fade: 0.3, rampIn: 0.22),
            arete([P(108, 952), P(112, 1010), P(80, 1090)], h: 34, k: 1.2, fade: 0.3, rampIn: 0.22),
            arete([P(538, 520), P(526, 590), P(500, 640)], h: 40, k: 1.2, fade: 0.3, rampIn: 0.22)
        ]
        var third: [PosterRidge] = []
        for r in [m1, m2, m3, m4, m5] {
            let l = hypot(r.pts.last!.x - r.pts[0].x, r.pts.last!.y - r.pts[0].y)
            third += spurs(of: r, count: Int(l / 86), length: 44...150, hFrac: 0.26, k: 1.5, from: 0.05, to: 0.82, spread: 30...56, rng: &rng)
        }
        // The great shadow planes right of the summit and the east top stay clean: no lit chips on them.
        third.removeAll { $0.pts.last!.x > $0.pts[0].x + 6 && $0.pts[0].y < 860 && $0.pts[0].x > 610 }
        for r in second { third += spurs(of: r, count: 3, length: 30...84, hFrac: 0.42, k: 1.5, from: 0.1, to: 0.8, spread: 30...56, rng: &rng) }
        var fourth: [PosterRidge] = []
        for r in third where r.pts[0].y < 880 { fourth += spurs(of: r, count: 1, length: 20...52, hFrac: 0.42, k: 1.6, cutLen: 14, rng: &rng) }

        // Bare rock is mostly decided by altitude and form; these few shapes are placed by hand, on the shadow side of the two big ribs.
        let rockInks = dark
            ? PosterAlpInks(rockDeep: hx(0x03101A), rockShadow: hx(0x0A232D), rockMid: hx(0x14373F), rockLit: hx(0x224A4F),
                      snowDeep: hx(0x0F2C39), snowShadow: hx(0x173E4B), snowMid: hx(0x2A5862), snowLit: hx(0x4E8488), snowTop: hx(0x689A9A), rim: hx(0x8CB9B4))
            : PosterAlpInks(rockDeep: hx(0x1F2F58), rockShadow: hx(0x34497C), rockMid: hx(0x6E5D84), rockLit: hx(0xA27F8A),
                      snowDeep: hx(0x3C5C91), snowShadow: hx(0x5B80AF), snowMid: hx(0xA7BCD6), snowLit: hx(0xFFF6E2), snowTop: hx(0xFBDDB2), rim: hx(0xFFFAEE))
        let style = PosterAlpStyle(light: PosterLight(-0.74, -0.34, 0.60), inks: rockInks, rockLine: 0.44, rockWidth: 150)
        let warm: (Double) -> Double = { x in 560 - 0.42 * (x - 560) }
        PosterAlp.paint(c, skyline: skyline, bottom: shore + 6, top: 370, foot: shore, slope: 0.5, levels: [[m1, m2, m3, m4, m5], second, third, fourth], rockRidges: [([m1, m2, m3, m4, m5], 1), (second, 0.7)], style: style,
                  warmLine: warm, tint: dark ? hx(0x24525A) : hx(0xFFF3D8), seed: 0x1234, key: 2)

        // The air thickens at the foot in steps, then mist: thin wisps across the rock and solid bands with long uneven waves, each paler than the one behind it.
        do {
            var r = SplitMix64(seed: 0x3157)
            let air = dark ? hx(0x10303A) : hx(0x9DC2C2)
            let inkA = dark ? hx(0x0F2D36) : hx(0xA9C8C4), inkB = dark ? hx(0x11333B) : hx(0xBDD6CC), inkC = dark ? hx(0x133840) : hx(0xCFE1D2), inkD = dark ? hx(0x153C43) : hx(0xDEE9D5)
            let step1 = PosterPlate(c) { g in fillPoly(g, PosterCut.wavyBand(y: 1020, tilt: 0.05, waves: [(22, 210, 1.1), (9, 74, 2.6)], floorY: shore + 6)) }
            c.flat(air, plate: step1, opacity: 0.22)
            let step2 = PosterPlate(c) { g in fillPoly(g, PosterCut.wavyBand(y: 1090, tilt: -0.04, waves: [(18, 170, 3.1), (8, 66, 0.6)], floorY: shore + 6)) }
            c.flat(air, plate: step2, opacity: 0.34)
            let a = PosterPlate(c) { g in fillPoly(g, PosterCut.wavyBand(y: 1170, tilt: -0.05, waves: [(15, 230, 0.4), (7, 83, 2.0), (2.5, 29, 1.0)], floorY: shore + 6)) }
            c.flat(inkA, plate: a)
            let wisps = PosterPlate(c) { g in
                fillPoly(g, PosterCut.spindle(x0: 490, x1: 1040, y: 1132, up: 11, down: 5, skew: 0.4, rng: &r))
                fillPoly(g, PosterCut.spindle(x0: -90, x1: 300, y: 1118, up: 10, down: 5, skew: 0.5, rng: &r))
            }
            c.flat(inkA, plate: wisps)
            let b = PosterPlate(c) { g in fillPoly(g, PosterCut.wavyBand(y: 1208, tilt: 0.05, waves: [(13, 190, 2.2), (6, 67, 0.3), (2.5, 23, 4.0)], floorY: shore + 6)) }
            c.flat(inkB, plate: b)
            let cc = PosterPlate(c) { g in fillPoly(g, PosterCut.wavyBand(y: 1244, tilt: -0.03, waves: [(10, 210, 4.0), (5, 57, 1.0)], floorY: shore + 6)) }
            c.flat(inkC, plate: cc)
            let d = PosterPlate(c) { g in fillPoly(g, PosterCut.wavyBand(y: 1276, tilt: 0.02, waves: [(8, 160, 1.5), (3, 47, 2.4)], floorY: shore + 6)) }
            c.flat(inkD, plate: d)
        }

        // Forest climbs both sides of the valley in two planes, opening a V onto the water: one torn silhouette, not a row of icons.
        let farF = PosterPlate(c) { g in
            var r = SplitMix64(seed: 77)
            PosterCut.treeline(g, line: { x in shore - 22 - 130 * pow(abs(x - 560) / 620, 1.7) }, floorY: shore + 6, height: 40...92, rng: &r)
        }
        c.pull(PosterRamp(dark ? [(0, hx(0x0C2A30)), (1, hx(0x113238))] : [(0, hx(0x3F7C80)), (1, hx(0x6A9E97))], step: 0.8), plate: farF, amp: 0.05, key: 7) { _, y in
            Float((y - 1120) / 200)
        }
        let nearF = PosterPlate(c) { g in
            var r = SplitMix64(seed: 78)
            PosterCut.treeline(g, line: { x in shore - 6 - 96 * pow(abs(x - 520) / 560, 2.1) }, floorY: shore + 6, height: 34...104, rng: &r)
        }
        c.flat(dark ? hx(0x071B21) : hx(0x1C4A50), plate: nearF, offset: (c.reg, 0))

        // The lake: the world turned over, softened, compressed a little, tinted, deepening toward the viewer.
        let shoreRow = max(1, min(c.h - 1, c.row(shore)))
        let w = c.w, h = c.h
        // A soft copy of everything above the shore: the grain must not be seen twice.
        let soft = UnsafeMutablePointer<UInt8>.allocate(capacity: w * (shoreRow + 1) * 3)
        defer { soft.deallocate() }
        c.rows(0, shoreRow + 1) { r in
            let a = c.px + max(0, r - 1) * c.bpr, b = c.px + r * c.bpr, d = c.px + min(shoreRow, r + 1) * c.bpr
            for x in 0..<w {
                let l = max(0, x - 1) * 4, m = x * 4, rr = min(w - 1, x + 1) * 4
                for k in 0..<3 {
                    let v = Int32(a[l + k]) + 2 * Int32(a[m + k]) + Int32(a[rr + k]) + 2 * Int32(b[l + k]) + 4 * Int32(b[m + k]) + 2 * Int32(b[rr + k]) + Int32(d[l + k]) + 2 * Int32(d[m + k]) + Int32(d[rr + k])
                    soft[(r * w + x) * 3 + k] = UInt8(v / 16)
                }
            }
        }
        let water = dark ? hx(0x07212B) : hx(0x2A7690)
        let deep = dark ? hx(0x03121A) : hx(0x134A66)
        let wr = Float(water.r * 255), wg = Float(water.g * 255), wb = Float(water.b * 255)
        let dr = Float(deep.r * 255), dg = Float(deep.g * 255), db = Float(deep.b * 255)
        let band = PosterAngularNoise(5)
        let mixTop: Float = dark ? 0.62 : 0.34
        let mixBot: Float = dark ? 0.94 : 0.86
        // The water deepens in cut steps, along long hand-drawn lines, each edge a tight dissolve.
        let stepDefs: [(y: Double, w: (Double) -> Double)] = [
            (1610, PosterCut.wavyTop([(13, 240, 2.1), (6, 90, 0.2)])), (1880, PosterCut.wavyTop([(18, 260, 1.2), (8, 100, 3.1)]))
        ]
        let stepN = stepDefs.count
        let stepTable = UnsafeMutablePointer<Float>.allocate(capacity: w * stepN)
        defer { stepTable.deallocate() }
        for (k, d) in stepDefs.enumerated() {
            for x in 0..<w { stepTable[k * w + x] = Float(d.y + d.w(c.dx(x))) }
        }
        let sxv = c.sx
        c.rows(shoreRow, h) { r in
            let d = Double(r - shoreRow)
            let dNorm = Float(d / Double(h - shoreRow))
            // Narrow rows of water slide sideways, most of all toward the viewer; a row's slide changes along its length, so nothing is ruled.
            let bandH = (2.2 + 15 * Double(dNorm)) * sxv / 1.179
            let idx = Float((d / bandH).rounded(.down))
            let ruffle = 0.5 + 0.5 * band.value(idx * 0.13, 7.5)
            let amp = Float(sxv) * (0.8 + 9 * dNorm) * (0.4 + 2.4 * ruffle * ruffle)
            let radius = (1.4 + 6.5 * Double(dNorm)) * sxv / 1.179
            let line = c.px + r * c.bpr
            let ydF = Float(c.dy(r))
            let tone = sstep(0, 0.9, dNorm)
            for x in 0..<w {
                let shift = Int(band.value(Float(x) / Float(sxv * 92), idx * 0.71) * amp)
                let sxp = min(w - 1, max(0, x + shift))
                var sr: Float = 0, sg: Float = 0, sb: Float = 0
                for tap in -2...2 {
                    let srcF = Double(shoreRow) - 1 - (d + Double(tap) * radius * 0.5) / 0.88
                    let src = min(shoreRow, max(0, Int(srcF)))
                    let i = (src * w + sxp) * 3
                    sr += Float(soft[i])
                    sg += Float(soft[i + 1])
                    sb += Float(soft[i + 2])
                }
                sr *= 0.2
                sg *= 0.2
                sb *= 0.2
                let gr = c.g(x, r, 5)
                var steps: Float = 0
                for k in 0..<stepN {
                    let e = stepTable[k * w + x]
                    if ydF > e + 7 { steps += 1 } else if ydF > e - 7, sstep(e - 7, e + 7, ydF) > gr { steps += 1 }
                }
                let m = 0.72 * tone + 0.28 * steps / Float(stepN)
                let mixA = mixTop + (mixBot - mixTop) * tone
                let tr = wr + (dr - wr) * m, tg = wg + (dg - wg) * m, tb = wb + (db - wb) * m
                let o = line + x * 4
                o[0] = UInt8(sr + (tr - sr) * mixA)
                o[1] = UInt8(sg + (tg - sg) * mixA)
                o[2] = UInt8(sb + (tb - sb) * mixA)
                o[3] = 255
            }
        }

        // Stars go on after the water is baked, so the lake holds none of them, and stay clear of the land.
        if dark {
            let behind = PosterPlate(c) { g in
                var outline = skyline
                outline.append(P(1060, shore + 40))
                outline.append(P(-60, shore + 40))
                fillPoly(g, outline)
                g.setLineWidth(26)
                g.beginPath()
                poly(g, outline)
                g.strokePath()
            }
            behind.union(farRange)
            PosterSky.stars2(c, until: 1000, bright: [(118, 212, 2.3), (336, 118, 1.7), (842, 266, 2.5), (214, 548, 1.8)], behind: behind, dots: hx(0xB8D2D4), big: hx(0xEAF2E6), seed: 31)
        }

        // Where the far shore meets the water: a pale line in a few pieces.
        let sliver = PosterPlate(c) { g in
            for (x, l, t): (Double, Double, Double) in [(250, 190, 2.0), (516, 130, 1.5), (760, 84, 1.4)] {
                g.beginPath()
                lens(g, x, shore + 2.4, l, t)
                g.fillPath()
            }
        }
        c.flat(dark ? hx(0x2A5A62) : hx(0xD8E8D2), plate: sliver, opacity: 0.5)
        // A very few short ripples, close to the water's own tone.
        let ripples = PosterPlate(c) { g in
            for (x, y, l, t): (Double, Double, Double, Double) in [(412, 1412, 66, 2.2), (640, 1478, 96, 2.6), (300, 1566, 84, 3.0), (560, 1652, 136, 4.0), (452, 1772, 116, 4.8), (700, 1826, 170, 5.8), (386, 1936, 150, 6.8), (610, 2020, 190, 7.6)] {
                g.beginPath()
                lens(g, x, y, l, t)
                g.fillPath()
            }
        }
        c.flat(dark ? hx(0x041820) : hx(0x175571), plate: ripples, opacity: dark ? 0.45 : 0.28)

        // The night's water lifts one step, so the trees stand against something.
        if dark {
            let water = PosterPlate(c) { g in fillPoly(g, [P(-20, shore + 3), P(1020, shore + 3), P(1020, 2200), P(-20, 2200)]) }
            c.flat(hx(0x123A44), plate: water, opacity: 0.1)
        }

        // The foreground frames it, weighted to the left: a tall conifer and its neighbours, one smaller stand on the right.
        let treeInk = dark ? hx(0x020A10) : hx(0x0B2A31)
        let boughInk = dark ? hx(0x0A2228) : hx(0x1B4A50)
        let backTrees = PosterPlate(c) { g in
            var r = SplitMix64(seed: 44)
            for spec: (Double, Double, Double, Double, Int) in [(196, 1466, 2100, 84, 22), (122, 1620, 2080, 58, 17), (914, 1720, 2110, 56, 15)] {
                fillPoly(g, PosterDraw.conifer(&r, x: spec.0, top: spec.1, base: spec.2, halfW: spec.3, tiers: spec.4))
            }
        }
        c.flat(dark ? hx(0x041318) : hx(0x153C43), plate: backTrees)
        var hi: [[P]] = []
        var rTrees = SplitMix64(seed: 45)
        let bigTree = PosterDraw.conifer(&rTrees, x: 58, top: 930, base: 2168, halfW: 176, tiers: 44, highlights: &hi)
        let smallTree = PosterDraw.conifer(&rTrees, x: 996, top: 1386, base: 2168, halfW: 122, tiers: 30, highlights: &hi)
        let frontTrees = PosterPlate(c) { g in
            fillPoly(g, bigTree)
            fillPoly(g, smallTree)
        }
        let boughs = PosterPlate(c) { g in for h in hi { fillPoly(g, h) } }
        c.flat(treeInk, plate: frontTrees)
        c.flat(boughInk, plate: boughs)
        // At night a thin rim on the side of each near tree that faces the open sky, dying away down the trunk: it keeps them off the dark water.
        if dark {
            let rim = PosterPlate(c) { g in
                fillPoly(g, bigTree)
                fillPoly(g, smallTree)
            }
            let inner = PosterPlate(c) { g in
                fillPoly(g, bigTree.map { P($0.x - 2.6, $0.y + 0.8) })
                fillPoly(g, smallTree.map { P($0.x + 2.4, $0.y + 0.8) })
            }
            rim.subtract(inner)
            c.pull(PosterRamp([(0, hx(0x2E6468)), (0.5, hx(0x17404A)), (1, treeInk)], step: 1), plate: rim, amp: 0.02, key: 71) { _, y in
                Float((y - 960) / 780)
            }
        }

        var r3 = SplitMix64(seed: 501)
        PosterForeground.ledge(c, line: [P(-40, 1930), P(44, 1912), P(120, 1936), P(176, 1984), P(270, 2010), P(350, 2062), P(470, 2096), P(610, 2122), P(760, 2124), P(868, 2092), P(950, 2036), P(1040, 2010)],
                         foot: 2168, deep: dark ? hx(0x020B10) : hx(0x08262C), ledge: dark ? hx(0x0E2A2F) : hx(0x2A5C60), rim: dark ? hx(0x20474B) : hx(0x79998A), ledges: 70, reach: 120, rng: &r3)

        c.finish(seed: 0xABC, tooth: dark ? 0.05 : 0.05, mottle: 0.018, pinholes: dark ? 0.08 : 0.2, paper: hx(0xFFF6E2))
    }
}
