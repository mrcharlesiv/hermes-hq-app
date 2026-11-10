// Ocean: open sea under a cloud-filled sky, the sun or the moon between two heaps. Design space x 0...1000, y 0...2168.

import CoreGraphics
import Foundation

private typealias P = PosterP

nonisolated extension Poster {
    static func ocean(_ c: PosterCanvas, dark: Bool) {
        let horizon = 1440.0
        let glade = dark ? 262.0 : 330.0
        let light = dark ? P(262, 560) : P(330, 1370)
        var rng = SplitMix64(seed: 0x0CEA_0002)

        // The sky: one value for its top sixth, then indigo through rose to apricot; at night a violet of its own.
        let skyRamp = PosterRamp(dark
            ? [(0, hx(0x07061A)), (0.25, hx(0x0B0924)), (0.5, hx(0x120E34)), (0.75, hx(0x1E1648)), (1, hx(0x33265F))]
            : [(0, hx(0x233A6B)), (0.2, hx(0x3F4D86)), (0.38, hx(0x75588F)), (0.54, hx(0xBB6582)), (0.68, hx(0xEB8C6C)), (0.84, hx(0xFBBF7A)), (1, hx(0xFFE6AE))], step: 1)
        c.pull(skyRamp, amp: dark ? 0.03 : 0.045, key: 1, rows: (0, c.row(horizon) + 2)) { x, y in
            let t = max(0, (y - 330) / (horizon - 330))
            if dark { return Float(0.76 * pow(t, 1.15)) }
            let dd = hypot(x - light.x, (y - light.y) * 0.85)
            return Float(0.09 + 0.63 * t + 0.13 * exp(-dd / 520))
        }

        // Stars go down before anything can stand in front of them, and keep off the moon's air.
        if dark {
            PosterSky.stars2(c, until: 1120, bright: [(116, 214, 2.1), (438, 92, 1.6), (726, 268, 2.4), (604, 612, 1.5), (72, 742, 1.6)],
                       dots: hx(0xC4BEDC), big: hx(0xF2EADC), seed: 41, avoid: { x, y in hypot(x - light.x, y - light.y) < 270 })
        }

        // Halo: rings cut flat with a tight dissolve, never a glow that fades for hundreds of points.
        func ring(_ ink: PosterInk, _ radius: Double, _ opacity: Float, key: Int, squash: Double) {
            let top = c.row(light.y - radius - 14), bottom = min(c.row(horizon) + 1, c.row(light.y + radius + 14))
            let ph = Double(key) * 1.7
            c.stipple(ink, rows: (max(0, top), bottom), key: key, opacity: opacity, grainMix: 0.4) { x, y in
                let dx = x - light.x, dy = (y - light.y) * squash
                let d = hypot(dx, dy)
                // PosterCut by hand: the ring's edge wanders a little, so it never reads as a target.
                let th = atan2(dy, dx)
                let edge = radius * (1 + 0.035 * sin(2 * th + ph) + 0.022 * sin(5 * th + ph * 2.1) + 0.012 * sin(11 * th + ph * 0.7))
                return Float(1 - dsstep(edge - 12, edge + 12, d))
            }
        }
        if dark {
            ring(hx(0x100D2E), 232, 0.42, key: 4, squash: 1)
            ring(hx(0x171340), 152, 0.5, key: 5, squash: 1)
            ring(hx(0x282158), 94, 0.6, key: 6, squash: 1)
            let r = 60.0
            let disc = PosterPlate(c) { g in g.fillEllipse(in: CGRect(x: light.x - r, y: light.y - r, width: 2 * r, height: 2 * r)) }
            c.flat(hx(0xEFE7D2), plate: disc)
            // Three hand-cut seas of low contrast, each printed twice so its edge is soft.
            func blob(_ g: CGContext, _ pts: [(Double, Double)], grow: Double) {
                let cx = pts.reduce(0) { $0 + $1.0 } / Double(pts.count), cy = pts.reduce(0) { $0 + $1.1 } / Double(pts.count)
                let scaled = pts.map { P(light.x + (cx + ($0.0 - cx) * grow) * r / 56, light.y + (cy + ($0.1 - cy) * grow) * r / 56) }
                let n = scaled.count
                g.beginPath()
                g.move(to: CGPoint(x: (scaled[n - 1].x + scaled[0].x) / 2, y: (scaled[n - 1].y + scaled[0].y) / 2))
                for i in 0..<n {
                    let a = scaled[i], b = scaled[(i + 1) % n]
                    g.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: CGPoint(x: a.x, y: a.y))
                }
                g.closePath()
                g.fillPath()
            }
            let seas: [[(Double, Double)]] = [
                [(-34, -30), (-6, -42), (14, -26), (6, -8), (-14, -2), (-38, -12)],
                [(8, 2), (36, -8), (46, 14), (28, 34), (6, 24)],
                [(-34, 16), (-14, 12), (-6, 30), (-20, 44), (-38, 34)]
            ]
            for grow in [1.12, 0.86] {
                let p = PosterPlate(c) { g in for s in seas { blob(g, s, grow: grow) } }
                p.intersect(disc)
                c.flat(hx(0xC9C0B4), plate: p, opacity: 0.2)
            }
        } else {
            ring(hx(0xF7AE74), 306, 0.3, key: 4, squash: 1.1)
            ring(hx(0xFBC284), 208, 0.42, key: 5, squash: 1.1)
            ring(hx(0xFFDA9C), 134, 0.7, key: 6, squash: 1.1)
            let r = 90.0
            let disc = PosterPlate(c) { g in g.fillEllipse(in: CGRect(x: light.x - r, y: light.y - r, width: 2 * r, height: 2 * r)) }
            c.flat(hx(0xFFF6DC), plate: disc)
        }

        // High streaks: a few long groups stepping down a diagonal toward the tower. The top of the frame stays clear.
        do {
            var r = SplitMix64(seed: 0x57E4)
            let groups: [(Double, Double, Double, Double, Double)] = dark
                ? [(370, 830, 410, 34, 13), (540, 960, 456, 22, 8), (450, 660, 492, 13, 5),
                   (470, 780, 742, 22, 8), (590, 760, 782, 12, 4), (-140, 150, 836, 24, 9), (-80, 240, 880, 14, 5)]
                : [(-160, 330, 384, 40, 15), (50, 500, 436, 25, 9), (-90, 190, 476, 15, 6),
                   (210, 690, 566, 36, 13), (420, 780, 618, 22, 8), (280, 490, 656, 12, 5),
                   (420, 800, 772, 22, 8), (510, 720, 812, 12, 4)]
            var bodies: [[P]] = []
            for g in groups { bodies.append(PosterCut.spindle(x0: g.0, x1: g.1, y: g.2, up: g.3, down: g.4, skew: 0.56, rng: &r)) }
            let body = PosterPlate(c) { g in for b in bodies { fillPoly(g, b) } }
            let lit = PosterPlate(c) { g in
                for b in bodies {
                    g.saveGState()
                    g.beginPath()
                    poly(g, b)
                    g.clip()
                    fillPoly(g, b.map { dark ? P($0.x - 12, $0.y - 8) : P($0.x - 14, $0.y + 12) })
                    g.restoreGState()
                }
            }
            c.pull(PosterRamp(dark ? [(0, hx(0x171240)), (1, hx(0x1C1648))] : [(0, hx(0x2E3470)), (0.6, hx(0x483C7C)), (1, hx(0x6A4484))], step: 1), plate: body, amp: 0.03, key: 11) { _, y in
                Float((y - 340) / 480)
            }
            c.pull(PosterRamp(dark ? [(0, hx(0x2E2760)), (1, hx(0x3A3070))] : [(0, hx(0x8A5A92)), (0.5, hx(0xC06A84)), (1, hx(0xEC8C6E))], step: 1), plate: lit, amp: 0.03, key: 12, offset: (c.reg, 0)) { _, y in
                Float((y - 340) / 480)
            }
        }

        // Clouds. A tone ladder from the deep side to the edge that faces the light.
        let cloudRamp = PosterRamp(dark
            ? [(0, hx(0x0A0922)), (0.1, hx(0x100D2E)), (0.28, hx(0x191440)), (0.5, hx(0x2A2358)), (0.72, hx(0x4C4580)), (0.9, hx(0x8C84B4)), (1, hx(0xC4BCD8))]
            : [(0, hx(0x2A2C60)), (0.18, hx(0x483C78)), (0.36, hx(0x7A4C88)), (0.52, hx(0xB65C80)), (0.68, hx(0xEC8862)), (0.84, hx(0xFBC074)), (1, hx(0xFFEDC4))], step: 0.5)

        let lp = light
        func shader(_ l: PosterLight) -> (Double, Double, Float, Float, Float, PosterBillow) -> Float {
            let lx = l.x, ly = l.y
            let gi = 1 / (lx * lx + ly * ly).squareRoot()
            return { x, y, ndl, form, _, b in
                let size = Float(b.ry / b.mry)
                let dxn = Float((x - b.x) / b.rx), dyn = Float((y - b.y) / b.ry)
                // A lobe is a bulge: only the side toward the light has an edge, its far rim sinks back into the heap.
                let away = -(dxn * lx + dyn * ly)
                let merge = 1 - sstep(0.0, 0.92, away)
                let d = Float(hypot(x - lp.x, (y - lp.y) * 0.9))
                if dark {
                    let prox = min(0.62, exp(-d / 800))
                    // Moonlight grazes: the heap's edge toward the moon is its lightest part, with no plateau facing the viewer.
                    let fx = Float((x - b.mx) / b.mrx), fy = Float((y - b.my) / b.mry)
                    let graze = (fx * lx + fy * ly) * gi
                    let hold = 1 - 0.75 * sstep(0.2, 0.8, graze)
                    let a = (0.05 + 0.2 * sstep(0.06, 0.4, size)) * hold
                    let f = 0.66 * graze + 0.34 * form + a * (ndl - 0.55) * merge
                    let body = sstep(-0.34, 0.66, f)
                    let rim = sstep(0.5, 0.94, f)
                    return 0.06 + body * (0.06 + 0.3 * prox) + rim * (0.05 + 0.62 * prox)
                }
                let prox = exp(-d / 900)
                // The hot zones keep large shapes: little lobes get no say in the two lightest inks.
                let hold = 1 - 0.8 * sstep(0.42, 0.92, form)
                let a = (0.12 + 0.46 * sstep(0.06, 0.4, size)) * hold
                let f = form + a * (ndl - 0.55) * merge
                let big = sstep(-0.24, 0.92, f)
                return 0.08 + 0.4 * prox + big * (0.12 + 0.62 * prox)
            }
        }

        // One flat step of air behind the tower's foot.
        var far: [PosterBillow] = []
        for h: (Double, Double, Double, Double) in [(610, 1176, 150, 56), (790, 1150, 180, 70), (960, 1120, 150, 90), (-30, 1204, 150, 50), (120, 1232, 96, 26)] {
            crownHeap(&far, x: h.0, y: h.1, rx: h.2, ry: h.3, inner: 0, rng: &rng)
        }
        c.billows(far.sorted { $0.y < $1.y }, ramp: cloudRamp, amp: 0.02, key: 13, light: PosterLight(-0.5, -0.2, 0.8),
                  base: { x in 1276 + 4 * sin(x / 80) + 2 * sin(x / 27) }) { x, y, _, form, _, _ in
            dark ? 0.2 + 0.03 * sstep(0.3, 0.9, form) : 0.5 + 0.06 * sstep(0.3, 0.9, form)
        }

        // The tower: a few tall masses, stacked back to front, cropped by the frame.
        let towerMasses: [(x: Double, y: Double, rx: Double, ry: Double, inner: Int)] = [
            (950, 400, 128, 118, 8), (1020, 560, 170, 160, 8), (856, 640, 118, 132, 8), (965, 806, 216, 186, 12),
            (776, 902, 124, 128, 9), (906, 1042, 250, 160, 14), (694, 1124, 150, 76, 9), (900, 1170, 280, 56, 10)
        ]
        var tower: [PosterBillow] = []
        for m in towerMasses { crownHeap(&tower, x: m.x, y: m.y, rx: m.rx, ry: m.ry, inner: m.inner, rng: &rng) }
        let towerLight = dark ? PosterLight(-0.74, -0.56, 0.48) : PosterLight(-0.84, 0.1, 0.54)
        c.billows(tower, ramp: cloudRamp, amp: 0.03, key: 14, light: towerLight,
                  base: { x in 1232 + 5 * sin(x / 70) + 3 * sin(x / 23) }, shade: shader(towerLight))

        // A lower heap on the left closes the V.
        let leftMasses: [(x: Double, y: Double, rx: Double, ry: Double, inner: Int)] = [
            (-30, 1000, 136, 112, 8), (64, 1118, 172, 110, 11), (196, 1214, 126, 44, 7)
        ]
        var left: [PosterBillow] = []
        for m in leftMasses { crownHeap(&left, x: m.x, y: m.y, rx: m.rx, ry: m.ry, inner: m.inner, rng: &rng) }
        let leftLight = dark ? PosterLight(0.52, -0.7, 0.48) : PosterLight(0.84, 0.1, 0.54)
        c.billows(left, ramp: cloudRamp, amp: 0.03, key: 15, light: leftLight,
                  base: { x in 1262 + 4 * sin(x / 60) + 2 * sin(x / 19) }, shade: shader(leftLight))

        // Low bars: few, long, tapered, of unequal length. One crosses the sun.
        do {
            var r = SplitMix64(seed: 0xBA45)
            let bars: [(Double, Double, Double, Double, Double, PosterInk, PosterInk)] = dark
                ? [(520, 1110, 1298, 10, 4, hx(0x1A1544), hx(0x2C2560)), (-110, 300, 1336, 8, 3, hx(0x1F1850), hx(0x31286A))]
                : [(440, 1130, 1288, 12, 5, hx(0x6A4A86), hx(0xD87C78)), (-130, 240, 1322, 9, 4, hx(0x7C4E88), hx(0xE08A72)),
                   (150, 640, 1384, 7, 4, hx(0xC4667C), hx(0xE8876C)), (590, 1080, 1356, 7, 3, hx(0x9A5488), hx(0xE48A70)), (690, 1040, 1414, 4, 2, hx(0xD07876), hx(0xF09E70))]
            for b in bars {
                let pts = PosterCut.spindle(x0: b.0, x1: b.1, y: b.2, up: b.3, down: b.4, skew: 0.5, rng: &r)
                let body = PosterPlate(c) { g in fillPoly(g, pts) }
                c.flat(b.5, plate: body)
                let lit = PosterPlate(c) { g in
                    g.beginPath()
                    poly(g, pts)
                    g.clip()
                    fillPoly(g, pts.map { dark ? P($0.x - 6, $0.y - 4) : P($0.x - 6, $0.y + 4) })
                }
                c.flat(b.6, plate: lit, offset: (c.reg, 0))
            }
        }

        // The sea: hundreds of cut shapes in perspective, on a ramp that carries the sky's colours toward the viewer and deepens at his feet.
        let seaRamp = PosterRamp(dark
            ? [(0, hx(0x07061A)), (0.2, hx(0x0C0A26)), (0.4, hx(0x120F33)), (0.6, hx(0x1B1642)), (0.78, hx(0x282056)), (1, hx(0x3C306E))]
            : [(0, hx(0x0E2F4C)), (0.16, hx(0x1C3F68)), (0.32, hx(0x3A4780)), (0.48, hx(0x72508A)), (0.62, hx(0xB76284)), (0.78, hx(0xEC8C6C)), (1, hx(0xFBCB8E))], step: 0.5)
        let hRow = c.row(horizon)
        let seaN = GradientNoise(seed: 88)
        @Sendable func seaBase(_ x: Double, _ y: Double) -> Double {
            let d = max(0, (y - horizon) / 728)
            let wide = 54 + 380 * d
            let near = exp(-pow(abs(x - glade) / wide, 2))
            return dark ? 0.76 - 0.6 * pow(d, 0.5) + 0.1 * near : 0.92 - 0.8 * pow(d, 0.6) + 0.14 * near
        }
        c.pull(seaRamp, amp: 0.04, key: 2, rows: (hRow, c.h)) { x, y in Float(seaBase(x, y)) }

        // One cut mark on the water: a crescent or a chevron, its thick part off centre, its underside arched so it never closes to a lozenge.
        func mark(_ g: CGContext, _ x0: Double, _ y: Double, _ len: Double, _ th: Double, _ r: inout SplitMix64) {
            let peak = r.next(0.22, 0.78), tilt = r.next(-0.014, 0.014) * len
            let chevron = r.next() < 0.4
            let arch = r.next(0.25, 0.6)
            var top: [P] = [], under: [P] = []
            for i in 0...10 {
                let u = Double(i) / 10
                let v = u < peak ? u / peak : (1 - u) / (1 - peak)
                let s = chevron ? v : pow(sin(.pi / 2 * v), 0.85)
                let base = y + tilt * (u - 0.5)
                let px = x0 + len * u
                top.append(P(px, base - th * s))
                under.append(P(px, base - th * arch * s + th * 0.1 * s))
            }
            fillPoly(g, top + under.reversed())
        }
        // Marks go in clumps, so the wind writes on the water rather than the dice. Their scale eases off toward the viewer.
        var lists: [[(x: Double, y: Double, l: Double, t: Double)]] = [[], [], []]
        do {
            var r = SplitMix64(seed: 601)
            var y = horizon + 3.0
            while y < 2190 {
                let d = (y - horizon) / 728
                let dd = d < 0.35 ? d : 0.35 + (d - 0.35) * 0.5
                var x = -300 + r.next(0, 200)
                while x < 1100 {
                    let len = (24 + 500 * dd) * r.next(0.45, 1.5)
                    let th = (0.8 + 15 * dd) * r.next(0.6, 1.25)
                    let n = seaN.fbm((x + len / 2) / (140 + 700 * d), y / (22 + 180 * d), octaves: 2)
                    let pick = n + r.next(-0.14, 0.14)
                    if pick < 0.44 { lists[0].append((x, y, len, th)) }
                    else if pick > 0.6 { lists[2].append((x, y, len, th * 0.8)) }
                    else if pick > 0.5 { lists[1].append((x, y, len, th)) }
                    x += len * r.next(0.7, 1.5)
                }
                y += (1.7 + 28 * pow(dd, 1.25)) * r.next(0.8, 1.2)
            }
        }

        // Long swells under the marks: broad and barely there.
        struct Swell { var x0: Double, x1: Double, y0: Double, y1: Double, a: Double, l: Double, p: Double, belly: Double }
        let swells: [Swell] = [
            Swell(x0: 250, x1: 1140, y0: 1760, y1: 1742, a: 4, l: 120, p: 1.0, belly: 42),
            Swell(x0: -120, x1: 560, y0: 1846, y1: 1830, a: 5, l: 100, p: 2.5, belly: 52),
            Swell(x0: 430, x1: 1160, y0: 1912, y1: 1886, a: 7, l: 150, p: 3.6, belly: 70),
            Swell(x0: -130, x1: 760, y0: 2000, y1: 2034, a: 8, l: 190, p: 4.4, belly: 88),
            Swell(x0: 560, x1: 1180, y0: 2096, y1: 2062, a: 6, l: 140, p: 0.6, belly: 90)
        ]
        func swellPts(_ s: Swell, thick: Double) -> [P] {
            var top: [P] = [], under: [P] = []
            var u = 0.0
            while u <= 1.0001 {
                let x = s.x0 + (s.x1 - s.x0) * u
                let cy = s.y0 + (s.y1 - s.y0) * u + s.a * sin(x / s.l + s.p) + s.a * 0.4 * sin(x / (s.l * 0.37) + s.p * 2.3)
                top.append(P(x, cy))
                under.append(P(x, cy + thick * pow(sin(.pi * pow(u, 0.8)), 1.5)))
                u += 0.012
            }
            return top + under.reversed()
        }
        for s in swells {
            let trough = PosterPlate(c) { g in fillPoly(g, swellPts(s, thick: s.belly)) }
            let shift: Double = dark ? -0.03 : -0.032
            c.pull(seaRamp, plate: trough, amp: 0.04, key: 26) { x, y in Float(seaBase(x, y) + shift) }
            let shoulder = PosterPlate(c) { g in fillPoly(g, swellPts(s, thick: s.belly * 0.34)) }
            let lift: Double = dark ? 0.03 : 0.035
            c.pull(seaRamp, plate: shoulder, amp: 0.04, key: 27) { x, y in Float(seaBase(x, y) + lift) }
        }

        for (i, list) in lists.enumerated() {
            let plate = PosterPlate(c) { g in
                var r = SplitMix64(seed: 620 + UInt64(i))
                for w in list { mark(g, w.x, w.y, w.l, w.t, &r) }
            }
            let shift: Double = [-0.1, 0.075, 0.15][i]
            let scale = dark ? 0.82 : 1.0
            c.pull(seaRamp, plate: plate, amp: 0.05, key: 22 + i, offset: i == 0 ? (0, 0) : (c.reg, 0)) { x, y in
                let d = max(0, (y - horizon) / 728)
                return Float(seaBase(x, y) + shift * scale * (0.55 + 0.5 * d))
            }
        }

        // The middle scale of water: short marks of low contrast riding on the near sea, between the ripple and the swell.
        do {
            let plate = PosterPlate(c) { g in
                var r = SplitMix64(seed: 655)
                var y = horizon + 180
                while y < 2190 {
                    let d = (y - horizon) / 728
                    var x = -60 + r.next(0, 60)
                    while x < 1060 {
                        let keep = seaN.fbm(x / 240, y / 90, octaves: 2)
                        if keep + r.next(-0.1, 0.1) > 0.46 {
                            mark(g, x, y, r.next(26, 90) * (0.5 + 0.8 * d), r.next(1.2, 2.4) * (0.5 + 1.3 * d), &r)
                        }
                        x += r.next(40, 110) * (0.5 + 0.8 * d)
                    }
                    y += r.next(4.5, 8) * (0.5 + 1.1 * d)
                }
            }
            c.pull(seaRamp, plate: plate, amp: 0.04, key: 28, offset: (c.reg, 0)) { x, y in Float(seaBase(x, y) + (dark ? 0.045 : 0.07)) }
        }

        // The light on the water. Rows in clusters with gaps; pitch that varies; thin toward the viewer; cream at the heart only, dissolving through two inks.
        var hearts: [(Double, Double, Double, Double)] = [], mids: [(Double, Double, Double, Double)] = [], rims: [(Double, Double, Double, Double)] = []
        do {
            var r = SplitMix64(seed: 72)
            var y = horizon + 4
            while y < 2190 {
                let dc = (y - horizon) / 730
                let pitch = 3.0 + 22 * dc
                // One cluster: some rows close together, then open water.
                let rows = Int(r.next(3, 8))
                for _ in 0..<rows {
                    let d = (y - horizon) / 730
                    let n = 4 + Int(d * 15)
                    // A row leans to one side or the other, so the path wanders.
                    let drift = r.next(-0.26, 0.26)
                    for _ in 0..<n {
                        let halfW = (dark ? 36.0 : 46.0) + 216 * d
                        let u = (r.next(-1, 1) + r.next(-1, 1)) * 0.5 + drift * 0.5
                        let along = min(1, abs(u))
                        if r.next() < pow(along, 1.5) * 0.65 { continue }
                        let l = r.next(16, 66) * (0.62 + 1.5 * d) * (1 - 0.5 * along)
                        let th = r.next(0.8, 1.5) * (0.7 + 3 * d) * (1 - 0.35 * along)
                        let g = (glade + u * halfW - l / 2, y + r.next(-1, 1) * (2.5 + 11 * d), l, th)
                        if along < 0.3 { hearts.append(g) } else if along < 0.62 { mids.append(g) } else { rims.append(g) }
                    }
                    y += pitch * r.next(0.4, 1.8)
                    if y > 2190 { break }
                }
                y += pitch * r.next(1.2, 3.0)
            }
        }
        func glints(_ list: [(Double, Double, Double, Double)], ramp: PosterRamp, seed: UInt64, key: Int) {
            let plate = PosterPlate(c) { g in
                var r = SplitMix64(seed: seed)
                for w in list { mark(g, w.0, w.1, w.2, w.3, &r) }
            }
            c.pull(ramp, plate: plate, amp: 0.05, key: key) { _, y in Float((y - horizon) / 730) }
        }
        glints(rims, ramp: PosterRamp(dark ? [(0, hx(0x6C68A4)), (0.5, hx(0x3F3C78)), (1, hx(0x2A2654))] : [(0, hx(0xF09A70)), (0.5, hx(0xD8787C)), (1, hx(0x96588C))], step: 1), seed: 74, key: 9)
        glints(mids, ramp: PosterRamp(dark ? [(0, hx(0xA49ED0)), (0.5, hx(0x64609C)), (1, hx(0x383568))] : [(0, hx(0xFBC47C)), (0.5, hx(0xF4A072)), (1, hx(0xDE8078))], step: 1), seed: 75, key: 10)
        glints(hearts, ramp: PosterRamp(dark ? [(0, hx(0xE2DCF0)), (0.5, hx(0x9C96C8)), (1, hx(0x4C4E80))] : [(0, hx(0xFFF2C8)), (0.5, hx(0xFFDD9E)), (1, hx(0xF8BC80))], step: 1), seed: 76, key: 16)

        // The line where they meet: only under the light, thinning to nothing toward the edges.
        let sliver = PosterPlate(c) { g in
            let x0 = glade - 560, x1 = glade + 640
            var top: [P] = [], bot: [P] = []
            for i in 0...40 {
                let u = Double(i) / 40
                let v = pow(sin(.pi * u), 0.8)
                top.append(P(x0 + (x1 - x0) * u, horizon - 1.2 * v))
                bot.append(P(x0 + (x1 - x0) * u, horizon + 2.4 * v))
            }
            fillPoly(g, top + bot.reversed())
        }
        c.flat(dark ? hx(0x4A4288) : hx(0xFFDFA4), plate: sliver, opacity: 0.8)

        c.finish(seed: 0xB0C, tooth: dark ? 0.05 : 0.05, mottle: 0.018, pinholes: dark ? 0.06 : 0.16, paper: hx(0xFFF3DC))
    }
}
