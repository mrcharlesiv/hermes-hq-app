// Northern lights over a snowy treeline: a ribbon that folds, hanging in parallel rays. Design space x 0...1000, y 0...2168.

import CoreGraphics
import Foundation

private typealias P = PosterP

/// One run of the ribbon, already worked out per column of the sheet: where its lower edge is, how far its rays reach up, how bright they are.
nonisolated private struct AuroraRun: Sendable {
    var edge: [Float]
    var base: [Float]
    var reach: [Float]
    var ray: [Float]
    var weight: [Float]
}

nonisolated extension Poster {
    static func northernLights(_ c: PosterCanvas, dark: Bool) {
        var rng = SplitMix64(seed: 0x4A01_0001)
        let lift = max(0, 2168 - c.bottomY) * 0.86

        // The sky: real dusk, deep teal going to rose at the horizon, or by night a long deep blue going to teal over the trees.
        let skyStops: [(Double, PosterInk)] = dark
            ? [(0, hx(0x030A18)), (0.3, hx(0x06142A)), (0.72, hx(0x0A2236)), (0.91, hx(0x0E3840)), (1, hx(0x14505A))]
            : [(0, hx(0x1B4C60)), (0.3, hx(0x256072)), (0.55, hx(0x317678)), (0.72, hx(0x668488)), (0.84, hx(0xB08A8E)), (0.93, hx(0xE59C8E)), (1, hx(0xF7B694))]
        c.pull(PosterRamp(skyStops, step: 1), amp: dark ? 0.03 : 0.042, key: 1, rows: (0, c.row(1600))) { _, y in Float((y - 120) / 1320) }
        if dark {
            PosterSky.stars2(c, until: 1260, bright: [(132, 214, 2.2), (392, 150, 1.7), (706, 262, 2.4), (214, 512, 1.8), (880, 420, 1.6), (520, 340, 1.5)],
                             dots: hx(0xB8CCD8), big: hx(0xE8F2EC), count: 520, seed: 91)
        }

        // The ribbon. It comes in high on the right, sweeps down to the middle, doubles back on itself and runs out low on the left.
        let n1 = GradientNoise(seed: 811), n2 = GradientNoise(seed: 812)
        func run(_ line: [P], x0: Double, x1: Double, inFade: Double, outFade: Double, height: Double, gain: Float, shift: Double, fray: Double = 34) -> AuroraRun {
            var out = AuroraRun(edge: [], base: [], reach: [], ray: [], weight: [])
            out.edge.reserveCapacity(c.w); out.base.reserveCapacity(c.w); out.reach.reserveCapacity(c.w); out.ray.reserveCapacity(c.w); out.weight.reserveCapacity(c.w)
            for col in 0..<c.w {
                let x = c.dx(col) + shift
                let e = curveY(line, x - shift) + 8 * sin(x / 41) + 3 * sin(x / 13.3)
                let slow = n1.fbm(x / 150, 3.1, octaves: 2)
                let thin = n2.fbm(x / 30, 7.7, octaves: 2)
                let fine = n2.fbm(x / 9, 1.3, octaves: 2)
                // The rays: a few broad bands, finer ones inside them, real gaps between.
                let raw = 0.46 + 1.1 * slow + 1.3 * thin + 0.7 * fine
                let ray = 0.3 + 0.7 * Poster.dsstep(0.1, 0.8, raw)
                let tall = min(1.2, max(0.5, 0.84 + 1.2 * slow + 0.9 * thin))
                let w = Poster.dsstep(x0, x0 + inFade, x - shift) * (1 - Poster.dsstep(x1 - outFade, x1, x - shift))
                // Where a ray is weak it also starts higher up, so the lower edge frays instead of drawing a hill.
                out.edge.append(Float(e - fray * (1 - ray) * (1 - ray) - fray * 0.15 * fine))
                out.base.append(Float(e))
                out.reach.append(Float(height * tall))
                out.ray.append(Float(ray))
                out.weight.append(Float(w) * gain)
            }
            return out
        }
        let farRun = run([P(-60, 700), P(200, 650), P(460, 708), P(740, 628), P(1060, 660)], x0: -60, x1: 1060, inFade: 260, outFade: 60, height: 130, gain: 0.46, shift: 311)
        let heroA = run([P(-80, 982), P(90, 1020), P(250, 1066), P(420, 1022), P(560, 936), P(720, 906), P(880, 968), P(1060, 906)], x0: -80, x1: 1070, inFade: 10, outFade: 10, height: 300, gain: 1.0, shift: 0, fray: 96)
        let heroB = run([P(300, 1136), P(440, 1158), P(600, 1112), P(760, 1076), P(900, 1110), P(1060, 1050)], x0: 300, x1: 1070, inFade: 190, outFade: 10, height: 180, gain: 0.8, shift: 91, fray: 60)
        let heroC = run([P(-80, 812), P(120, 852), P(300, 812), P(470, 770)], x0: -80, x1: 530, inFade: 10, outFade: 250, height: 190, gain: 0.72, shift: 187)
        let runs = [farRun, heroC, heroB, heroA]
        let w = c.w, sx = c.sx, ox = c.ox
        // Tone at a point. `violet` asks instead for the thin colour at the tops of the rays.
        @Sendable func curtain(_ x: Double, _ y: Double, violet: Bool) -> Float {
            var best: Float = 0, sum: Float = 0
            let fy = Float(y)
            let calm = sstep(250, 440, fy)
            for r in runs {
                // Rays stand parallel, all with the same small lean: never a fan.
                let col = min(w - 1, max(0, Int((x + (Double(r.base[min(w - 1, max(0, Int(x * sx + ox)))]) - y) * 0.05) * sx + ox)))
                let wt = r.weight[col]
                if wt <= 0 { continue }
                let e = r.edge[col], reach = r.reach[col]
                let h = (e - fy) / reach
                if h < -0.02 || h > 1.3 { continue }
                let ray = r.ray[col]
                var b: Float
                if violet {
                    // Each ray stops at its own height, so the top frays like the lower edge and the band can't read as a hill.
                    let stop = 0.42 + 0.72 * ray * ray
                    b = sstep(0.42, 0.72, h) * (1 - sstep(stop, stop + 0.2, h)) * ray
                } else {
                    let up = max(0, 1 - h)
                    b = (0.72 * up * up * sqrt(up) + 0.36 * exp(-h * 13)) * ray * sstep(-0.02, 0.014, h)
                }
                b *= wt
                sum += b
                best = max(best, b)
            }
            return (best + 0.26 * (sum - best)) * calm
        }
        // A wide faint glow in the air around the ribbon, above and below it alike, so no edge of it can read as a shape.
        @Sendable func haze(_ x: Double, _ y: Double) -> Float {
            let col = min(w - 1, max(0, Int(x * sx + ox)))
            var best: Float = 0
            let fy = Float(y)
            for r in runs {
                let wt = r.weight[col]
                if wt <= 0 { continue }
                let reach = r.reach[col]
                let mid = r.base[col] - reach * 0.3
                let d = fy < mid ? (mid - fy) / (reach * 1.1) : (fy - mid) / (reach * 0.62)
                if d < 1 { best = max(best, (1 - d) * (1 - d) * wt) }
            }
            return best * sstep(250, 500, fy)
        }
        let top = c.row(max(c.topY, 200)), bottom = c.row(1500)
        let hazeGlaze = PosterGlaze(dark
            ? [(0, hx(0x0C3A46), 0), (0.3, hx(0x0C3A46), 0.07), (0.7, hx(0x0F4A4E), 0.16), (1, hx(0x125650), 0.24)]
            : [(0, hx(0x7FE0C0), 0), (0.3, hx(0x7FE0C0), 0.04), (0.7, hx(0x7FE0C0), 0.08), (1, hx(0x7FE0C0), 0.12)], step: 0.8)
        c.glaze(hazeGlaze, amp: 0.1, key: 20, rows: (top, bottom)) { x, y in
            let v = haze(x, y)
            return v < 0.01 ? -1 : v
        }
        let violetGlaze = PosterGlaze(dark
            ? [(0, hx(0x24306A), 0), (0.25, hx(0x24306A), 0.14), (0.6, hx(0x2E2E72), 0.34), (1, hx(0x483682), 0.52)]
            : [(0, hx(0x8C7CC8), 0), (0.25, hx(0x8C7CC8), 0.06), (0.6, hx(0x8876C8), 0.15), (1, hx(0x8070C4), 0.23)], step: 0.5)
        c.glaze(violetGlaze, amp: 0.12, key: 21, rows: (top, bottom)) { x, y in
            let v = curtain(x, y, violet: true)
            return v < 0.02 ? -1 : v
        }
        let greenGlaze = PosterGlaze(dark
            ? [(0, hx(0x0E4A50), 0), (0.08, hx(0x0E4A50), 0.1), (0.2, hx(0x0E5A58), 0.56), (0.42, hx(0x127460), 0.86), (0.66, hx(0x1A8C6A), 0.94), (0.86, hx(0x38AC88), 0.98), (1, hx(0x86E6C0), 1)]
            : [(0, hx(0x3FD6A0), 0), (0.08, hx(0x3FD6A0), 0.1), (0.2, hx(0x3FD6A0), 0.36), (0.42, hx(0x3FD6A0), 0.6), (0.66, hx(0x48DAA6), 0.78), (0.86, hx(0x6CE6BA), 0.88), (1, hx(0xC4FCE0), 0.94)], step: 0.4)
        c.glaze(greenGlaze, amp: 0.07, key: 22, rows: (top, bottom)) { x, y in
            let v = curtain(x, y, violet: false)
            return v < 0.012 ? -1 : v
        }

        // A far range, then a low snowy massif, the same way the lake's is cut: the dawn catches its top, by night the lights do.
        let far = PosterPlate(c) { g in
            var r = SplitMix64(seed: 301)
            var pts = cut([P(-30, 1372), P(70, 1334), P(160, 1366), P(248, 1322), P(340, 1372), P(470, 1394), P(620, 1376), P(760, 1344), P(860, 1300), P(940, 1336), P(1030, 1302)], amp: 0.06, minLen: 14, rng: &r)
            pts.append(P(1030, 1540)); pts.append(P(-30, 1540))
            fillPoly(g, pts)
        }
        c.pull(PosterRamp(dark ? [(0, hx(0x123642)), (1, hx(0x174650))] : [(0, hx(0x6F7E96)), (1, hx(0xD59E98))], step: 0.8), plate: far, amp: 0.05, key: 6) { _, y in Float((y - 1300) / 200) }

        func arete(_ pts: [P], h: Double, k: Double = 0.98, amp: Double = 0.07, len: Double = 22, fade: Double = 0.78, rampIn: Double = 0.03) -> PosterRidge {
            PosterAlp.ridge(pts, h: h, k: k, amp: amp, len: len, fade: fade, rampIn: rampIn, rng: &rng)
        }
        let shore = 1540.0
        let skyline = cut([P(380, 1500), P(470, 1462), P(544, 1424), P(600, 1396), P(650, 1352), P(700, 1362), P(742, 1310), P(780, 1268), P(806, 1276), P(844, 1216), P(872, 1242), P(904, 1236), P(946, 1296), P(984, 1330), P(1060, 1372)], amp: 0.06, minLen: 12, rng: &rng)
        let m1 = arete([P(844, 1216), P(812, 1294), P(760, 1362), P(700, 1430), P(640, 1540)], h: 104)
        let m2 = arete([P(844, 1216), P(862, 1310), P(846, 1400), P(880, 1540)], h: 104)
        let m3 = arete([P(650, 1352), P(610, 1420), P(550, 1470), P(470, 1540)], h: 62)
        let second = [
            arete([P(780, 1268), P(742, 1320), P(700, 1362)], h: 30, k: 1.25, rampIn: 0.22),
            arete([P(760, 1362), P(786, 1430), P(780, 1530)], h: 44, k: 1.25, rampIn: 0.22),
            arete([P(846, 1400), P(800, 1460), P(770, 1530)], h: 34, k: 1.25, rampIn: 0.22),
            arete([P(946, 1296), P(944, 1380), P(980, 1530)], h: 50, k: 1.25, rampIn: 0.22),
            arete([P(610, 1420), P(640, 1480), P(640, 1530)], h: 26, k: 1.25, rampIn: 0.22)
        ]
        var third: [PosterRidge] = []
        for r in [m1, m2, m3] { third += spurs(of: r, count: 4, length: 18...60, hFrac: 0.3, k: 1.5, from: 0.08, to: 0.82, spread: 30...56, rng: &rng) }
        for r in second { third += spurs(of: r, count: 2, length: 14...40, hFrac: 0.42, k: 1.5, from: 0.1, to: 0.8, spread: 30...56, rng: &rng) }
        let inks = dark
            ? PosterAlpInks(rockDeep: hx(0x04121C), rockShadow: hx(0x0A2430), rockMid: hx(0x10323C), rockLit: hx(0x184048),
                            snowDeep: hx(0x0D2C3A), snowShadow: hx(0x133A48), snowMid: hx(0x1E5058), snowLit: hx(0x38786E), snowTop: hx(0x4A8E7E), rim: hx(0x7CC8A8))
            : PosterAlpInks(rockDeep: hx(0x22324E), rockShadow: hx(0x384A70), rockMid: hx(0x6E668A), rockLit: hx(0xA87E8C),
                            snowDeep: hx(0x56709C), snowShadow: hx(0x7488B0), snowMid: hx(0xB8AECB), snowLit: hx(0xF6D6CC), snowTop: hx(0xFFBFA0), rim: hx(0xFFE6D8))
        let style = PosterAlpStyle(light: PosterLight(-0.74, -0.34, 0.60), inks: inks, rockLine: 0.5, rockWidth: 90)
        PosterAlp.paint(c, skyline: skyline, bottom: shore, top: 1216, foot: shore, slope: 0.5, levels: [[m1, m2, m3], second, third], rockRidges: [([m1, m2, m3], 1), (second, 0.7)], style: style,
                        warmLine: { x in 1330 - 0.2 * (x - 800) }, tint: dark ? hx(0x1E5A58) : hx(0xFFD8CC), seed: 0x2345, key: 2)
        // The air at its foot, in steps.
        do {
            let air = dark ? hx(0x10323C) : hx(0xD9A8A0)
            for (y, tilt, op, wa, wl, wp) in [(1440.0, 0.03, 0.3, 11.0, 150.0, 1.2), (1474.0, -0.02, 0.5, 8.0, 110.0, 3.0), (1500.0, 0.02, 0.76, 6.0, 90.0, 0.4)] {
                let p = PosterPlate(c) { g in fillPoly(g, PosterCut.wavyBand(y: y, tilt: tilt, waves: [(wa, wl, wp), (wa * 0.4, wl * 0.33, wp * 2)], floorY: shore + 8)) }
                c.flat(air, plate: p, opacity: op)
            }
        }

        // The forest: two torn planes opening a V onto the ice, dusted with snow on the side facing the light.
        func forest(seed: UInt64, line: @escaping (Double) -> Double, height: ClosedRange<Double>, ink: PosterInk, snow: PosterInk) {
            var r = SplitMix64(seed: seed), r2 = SplitMix64(seed: seed)
            let body = PosterPlate(c) { g in PosterCut.treeline(g, line: line, floorY: shore + 10, height: height, rng: &r) }
            let inner = PosterPlate(c) { g in
                g.saveGState()
                g.translateBy(x: 1.7, y: 2.6)
                PosterCut.treeline(g, line: line, floorY: shore + 10, height: height, rng: &r2)
                g.restoreGState()
            }
            c.flat(ink, plate: body)
            body.subtract(inner)
            c.flat(snow, plate: body, opacity: 0.86)
        }
        forest(seed: 44, line: { x in 1524 - 150 * pow(abs(x - 470) / 620, 1.8) }, height: 38...84, ink: dark ? hx(0x07202C) : hx(0x34546E), snow: dark ? hx(0x1E4A52) : hx(0xD4B4B8))
        forest(seed: 45, line: { x in 1536 - 96 * pow(abs(x - 450) / 560, 2.2) }, height: 34...96, ink: dark ? hx(0x041620) : hx(0x1E3C58), snow: dark ? hx(0x18404A) : hx(0xECC8C4))

        // The frozen lake: smooth, wind-cut, holding a smear of the lights.
        let iceTop = 1538.0
        let ice = PosterPlate(c) { g in
            fillPoly(g, [P(-30, iceTop), P(1030, iceTop), P(1030, 1800), P(-30, 1800)])
        }
        c.pull(PosterRamp(dark ? [(0, hx(0x123E48)), (0.5, hx(0x0D2C3A)), (1, hx(0x0A2130))] : [(0, hx(0xF0B6A0)), (0.45, hx(0xB8A6BC)), (1, hx(0x7E92B4))], step: 0.8), plate: ice, amp: 0.05, key: 7) { _, y in
            Float((y - iceTop) / 220)
        }
        do {
            let glow = PosterGlaze(dark
                ? [(0, hx(0x115048), 0), (0.2, hx(0x115048), 0.5), (0.6, hx(0x186C5A), 0.8), (1, hx(0x2C9A7C), 0.9)]
                : [(0, hx(0x5FDDB0), 0), (0.2, hx(0x5FDDB0), 0.36), (0.6, hx(0x5FDDB0), 0.56), (1, hx(0x9AF0CC), 0.8)], step: 0.7)
            let streak = GradientNoise(seed: 909)
            c.glaze(glow, plate: ice, amp: 0.06, key: 23, rows: (c.row(iceTop), c.row(1800))) { x, y in
                let my = iceTop - (y - iceTop) * 5.4
                let s = streak.fbm(x / 170, y / 5.5, octaves: 2)
                let v = curtain(x, my, violet: false) * Float(1.1 + 2.6 * s)
                return v < 0.03 ? -1 : v
            }
            // Wind marks on the ice.
            var r = SplitMix64(seed: 0xA5)
            let marks = PosterPlate(c) { g in
                g.beginPath()
                var y = iceTop + 6
                while y < 1790 {
                    let d = (y - iceTop) / 250
                    var x = -30 + r.next(0, 60)
                    while x < 1040 {
                        lens(g, x, y + r.next(-2, 2), r.next(30, 170) * (0.5 + d), r.next(0.8, 1.5) * (0.6 + 1.6 * d))
                        x += r.next(70, 240)
                    }
                    y += r.next(6, 14) * (0.6 + 1.4 * d)
                }
                g.fillPath()
            }
            c.flat(dark ? hx(0x1A5058) : hx(0xFFE0D4), plate: marks, opacity: dark ? 0.5 : 0.5)
        }

        // Snow in front: a far bank with a little cabin, then long drifts, each a lit shoulder and a shaded belly.
        let snowRamp = PosterRamp(dark
            ? [(0, hx(0x1C4A56)), (0.2, hx(0x163C4C)), (0.5, hx(0x102E40)), (0.8, hx(0x0B2234)), (1, hx(0x071828))]
            : [(0, hx(0xFBE0D4)), (0.2, hx(0xEEC8C8)), (0.44, hx(0xC8B4CE)), (0.74, hx(0x8C98BE)), (1, hx(0x5C72A0))], step: 0.6)
        @Sendable func snowTone(_ y: Double) -> Double { (y - 1560) / 620 }
        let bankLine: [P] = [P(-40, 1642), P(120, 1630), P(260, 1652), P(420, 1668), P(560, 1646), P(690, 1602), P(820, 1578), P(940, 1566), P(1040, 1560)]
        let bank = PosterPlate(c) { g in
            var pts: [P] = []
            var x = -40.0
            while x <= 1040 {
                pts.append(P(x, curveY(bankLine, x) + 2.4 * sin(x / 23) + 1.2 * sin(x / 7.1)))
                x += 6
            }
            pts.append(P(1040, 2200)); pts.append(P(-40, 2200))
            fillPoly(g, pts)
        }
        c.pull(snowRamp, plate: bank, amp: 0.05, key: 3) { _, y in Float(snowTone(y)) }

        // Spruces along the far bank, the near ones big enough to carry snow.
        func stand(_ list: [(x: Double, base: Double, h: Double)], seed: UInt64, body: PosterInk, litInk: PosterInk, shadeInk: PosterInk) {
            var r = SplitMix64(seed: seed)
            var bodies: [[P]] = [], lits: [[P]] = [], shades: [[P]] = []
            for t in list {
                let s = PosterDraw.snowSpruce(&r, x: t.x, top: t.base - t.h, base: t.base, halfW: t.h * r.next(0.2, 0.26), tiers: max(7, Int(t.h / 20)))
                bodies.append(s.body)
                lits += s.lit
                shades += s.shade
            }
            let bodyP = PosterPlate(c) { g in for b in bodies { fillPoly(g, b) } }
            let shadeP = PosterPlate(c) { g in for b in shades { fillPoly(g, b) } }
            let litP = PosterPlate(c) { g in for b in lits { fillPoly(g, b) } }
            // A shadow on the snow under the group, going right, away from the light.
            let shadow = PosterPlate(c) { g in
                g.beginPath()
                for t in list { lens(g, t.x + t.h * 0.3, t.base + 1, t.h * 0.86, t.h * 0.05) }
                g.fillPath()
            }
            c.flat(dark ? hx(0x06141F) : hx(0x6878A8), plate: shadow, opacity: 0.8)
            c.flat(body, plate: bodyP)
            c.flat(shadeInk, plate: shadeP)
            c.flat(litInk, plate: litP, offset: (c.reg, 0))
        }
        let midBody = dark ? hx(0x05141E) : hx(0x16304C), midLit = dark ? hx(0x2C6462) : hx(0xF6D8D0), midShade = dark ? hx(0x143644) : hx(0x8A96BC)
        stand([(872, 1590, 158), (934, 1580, 200), (984, 1576, 138), (816, 1598, 106), (770, 1612, 74), (20, 1656, 120), (74, 1650, 86), (168, 1648, 60)], seed: 71, body: midBody, litInk: midLit, shadeInk: midShade)

        // The cabin.
        var spillAt = (0.0, 0.0)
        do {
            let x = 660.0, y = 1626.0, s = 1.0
            let wall = dark ? hx(0x0E1820) : hx(0x6A4A48), wallLit = dark ? hx(0x1C2A2E) : hx(0x9A6A52), roofLit = dark ? hx(0x2F6A68) : hx(0xF8D8D0), roofShade = dark ? hx(0x143644) : hx(0x8E98BE), win = dark ? hx(0xF2B05A) : hx(0xFFC670), dim = dark ? hx(0x0A1218) : hx(0x4A3438)
            // Light from its window lying on the snow.
            spillAt = (x - 8, y + 16)
            c.paint { g in
                fill(g, wall, [P(x - 34 * s, y - 26 * s), P(x + 34 * s, y - 22 * s), P(x + 34 * s, y + 4), P(x - 34 * s, y + 6)])
                fill(g, wallLit, [P(x - 34 * s, y - 26 * s), P(x - 8 * s, y - 25 * s), P(x - 8 * s, y + 5), P(x - 34 * s, y + 6)])
                // The roof, loaded.
                fill(g, roofShade, [P(x - 42 * s, y - 24 * s), P(x - 12 * s, y - 52 * s), P(x + 40 * s, y - 48 * s), P(x + 42 * s, y - 20 * s)])
                fill(g, roofLit, [P(x - 44 * s, y - 22 * s), P(x - 40 * s, y - 28 * s), P(x - 12 * s, y - 54 * s), P(x + 16 * s, y - 52 * s), P(x - 6 * s, y - 24 * s)])
                // Chimney.
                fill(g, dim, [P(x + 18 * s, y - 62 * s), P(x + 26 * s, y - 62 * s), P(x + 26 * s, y - 44 * s), P(x + 18 * s, y - 44 * s)])
                fill(g, roofLit, [P(x + 16 * s, y - 64 * s), P(x + 28 * s, y - 64 * s), P(x + 27 * s, y - 60 * s), P(x + 17 * s, y - 60 * s)])
                // Windows.
                fill(g, win, [P(x - 26 * s, y - 16 * s), P(x - 15 * s, y - 16 * s), P(x - 15 * s, y - 5 * s), P(x - 26 * s, y - 5 * s)])
                fill(g, win, [P(x + 8 * s, y - 15 * s), P(x + 20 * s, y - 14 * s), P(x + 20 * s, y - 4 * s), P(x + 8 * s, y - 5 * s)])
                fill(g, dim, [P(x - 21 * s, y - 16 * s), P(x - 20 * s, y - 16 * s), P(x - 20 * s, y - 5 * s), P(x - 21 * s, y - 5 * s)])
                fill(g, dim, [P(x + 13.5 * s, y - 15 * s), P(x + 14.5 * s, y - 15 * s), P(x + 14.5 * s, y - 4 * s), P(x + 13.5 * s, y - 4 * s)])
            }
            // A thin rise of smoke, drifting left.
            var r = SplitMix64(seed: 77)
            var pts: [P] = [], back: [P] = []
            for i in 0...14 {
                let u = Double(i) / 14
                let sy = y - 66 - u * 92
                let sxx = x + 22 - 34 * u * u + 3 * sin(u * 6)
                let wd = 1.2 + 6 * u + r.next(-0.6, 0.6)
                pts.append(P(sxx - wd, sy)); back.append(P(sxx + wd, sy))
            }
            let smoke = PosterPlate(c) { g in fillPoly(g, pts + back.reversed()) }
            c.flat(dark ? hx(0x1A4250) : hx(0xE8C8C4), plate: smoke, opacity: dark ? 0.46 : 0.44)
            // The bank comes up around its foot.
            let drift = PosterPlate(c) { g in
                fillPoly(g, swell(x0: x - 80, x1: x + 90, y0: y + 3, y1: y + 2, a: 2, l: 19, p: 0.4, thick: 18))
            }
            c.pull(snowRamp, plate: drift, amp: 0.05, key: 3) { _, y in Float(snowTone(y)) }
        }

        // Long drifts.
        struct Drift { var x0: Double, x1: Double, y0: Double, y1: Double, a: Double, l: Double, p: Double, belly: Double }
        let drifts: [Drift] = [
            Drift(x0: 200, x1: 1100, y0: 1716, y1: 1660, a: 4, l: 96, p: 0.7, belly: 44),
            Drift(x0: -140, x1: 640, y0: 1766, y1: 1730, a: 5, l: 120, p: 2.2, belly: 56),
            Drift(x0: 330, x1: 1170, y0: 1866, y1: 1804, a: 6, l: 140, p: 4.1, belly: 74),
            Drift(x0: -160, x1: 720, y0: 1950, y1: 1900, a: 7, l: 170, p: 0.9, belly: 92),
            Drift(x0: 280, x1: 1180, y0: 2070, y1: 2000, a: 7, l: 170, p: 3.0, belly: 96)
        ]
        for d in drifts {
            let trough = PosterPlate(c) { g in fillPoly(g, swell(x0: d.x0, x1: d.x1, y0: d.y0, y1: d.y1, a: d.a, l: d.l, p: d.p, thick: d.belly)) }
            c.pull(snowRamp, plate: trough, amp: 0.06, key: 26) { _, y in Float(snowTone(y) + 0.2) }
            let lip = PosterPlate(c) { g in fillPoly(g, swell(x0: d.x0, x1: d.x1, y0: d.y0, y1: d.y1, a: d.a, l: d.l, p: d.p, thick: d.belly * 0.2)) }
            c.pull(snowRamp, plate: lip, amp: 0.05, key: 27) { _, y in Float(snowTone(y) - 0.14) }
        }

        // Lamplight on the snow in front of the cabin, in grain.
        if dark {
            let (lx, ly) = spillAt
            let pool: @Sendable (Double, Double) -> Float = { x, y in
                let dx = (x - lx) / 92, dy = (y - ly - 4) / 26
                let d = dx * dx + dy * dy
                return d > 1 ? 0 : Float((1 - d) * (1 - d))
            }
            c.glaze(PosterGlaze([(0, hx(0x7A6A4C), 0), (1, hx(0x7A6A4C), 0.34)], step: 0.5), amp: 0.04, key: 42, rows: (c.row(ly - 22), c.row(ly + 30))) { x, y in
                let v = pool(x, y)
                return v <= 0 ? -1 : v
            }
            c.stipple(hx(0x8A7A58), rows: (c.row(ly - 8), c.row(ly + 54)), key: 41, opacity: 0.45, grainMix: 0.5) { x, y in pool(x, y) * 0.5 }
        }

        // The trees' long shadows lie across the snow, away from the light.
        do {
            let sh = PosterPlate(c) { g in
                g.beginPath()
                lens(g, 330, 1812, 880, 66, tilt: 0.05)
                lens(g, 660, 2030, 1000, 60, tilt: 0.06)
                g.fillPath()
            }
            c.flat(dark ? hx(0x06161F) : hx(0x5E6FA0), plate: sh, opacity: dark ? 0.46 : 0.5)
        }

        // The frame: a heavy snow-laden spruce on the left, a smaller one on the right.
        let nearBody = dark ? hx(0x020C14) : hx(0x0E2438), nearLit = dark ? hx(0x28605E) : hx(0xF8DCD2), nearShade = dark ? hx(0x0E2C3A) : hx(0x7C8CB6)
        do {
            var r = SplitMix64(seed: 46)
            let back = PosterDraw.snowSpruce(&r, x: 208, top: 1470 - lift * 0.3, base: 2160, halfW: 126, tiers: 16)
            let bigOne = PosterDraw.snowSpruce(&r, x: 52, top: 1010, base: 2200, halfW: 216, tiers: 22, load: 1.1)
            let small = PosterDraw.snowSpruce(&r, x: 992, top: 1650 - lift * 0.3, base: 2200, halfW: 118, tiers: 14, load: 1.05)
            func lay(_ s: (body: [P], lit: [[P]], shade: [[P]]), _ b: PosterInk, _ l: PosterInk, _ sh: PosterInk) {
                let bodyP = PosterPlate(c) { g in fillPoly(g, s.body) }
                c.flat(b, plate: bodyP)
                let shadeP = PosterPlate(c) { g in for p in s.shade { fillPoly(g, p) } }
                c.flat(sh, plate: shadeP)
                let litP = PosterPlate(c) { g in for p in s.lit { fillPoly(g, p) } }
                c.flat(l, plate: litP, offset: (c.reg, 0))
            }
            lay(back, dark ? hx(0x041420) : hx(0x16304C), dark ? hx(0x1C4E54) : hx(0xEED0CC), dark ? hx(0x0C2632) : hx(0x8090B8))
            lay(bigOne, nearBody, nearLit, nearShade)
            lay(small, nearBody, nearLit, nearShade)
        }

        // A last bank of snow in shade across the foot of the sheet, with a low dark rock breaking through on the right.
        do {
            var r = SplitMix64(seed: 503)
            let line: [P] = [P(-40, 1930), P(90, 1966), P(210, 2016), P(350, 2066), P(500, 2100), P(660, 2118), P(800, 2110), P(920, 2076), P(1040, 2040)].map { P($0.x, $0.y - lift) }
            let edge = cut(line, amp: 0.025, minLen: 16, rng: &r)
            let p = PosterPlate(c) { g in fillPoly(g, edge + [P(1040, 2300), P(-40, 2300)]) }
            let lip = PosterPlate(c) { g in fillPoly(g, edge + edge.reversed().map { P($0.x + 4, $0.y + 3.4 + 2.6 * sin($0.x / 47)) }) }
            c.pull(PosterRamp(dark ? [(0, hx(0x0D2838)), (0.5, hx(0x081C2A)), (1, hx(0x04101C))] : [(0, hx(0x64749F)), (0.5, hx(0x4C5C8C)), (1, hx(0x34447A))], step: 0.6), plate: p, amp: 0.06, key: 28) { _, y in
                Float((y - 1990 + lift) / 180)
            }
            c.flat(dark ? hx(0x1E4A52) : hx(0xE0C8D4), plate: lip, opacity: dark ? 0.6 : 0.86)
        }

        c.finish(seed: 0xA4A, tooth: 0.05, mottle: 0.018, pinholes: dark ? 0.06 : 0.16, paper: hx(0xFFF6EA))
    }
}
