// A city at dusk over water. Every building is drawn for itself: its lights are strips, patches and single floors, not a window grid. Design space x 0...1000, y 0...2168.

import CoreGraphics
import Foundation

private typealias P = PosterP

nonisolated private struct CityPainter {
    let g: CGContext
    let dark: Bool
    let glow: PosterInk, cool: PosterInk
    var rng: SplitMix64

    func rect(_ ink: PosterInk, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
        Poster.fill(g, ink, [P(x0, y0), P(x1, y0), P(x1, y1), P(x0, y1)])
    }

    /// A box seen from below and a little to one side: a lit face to the left of its edge, a shaded one to the right.
    func box(_ x0: Double, _ x1: Double, top: Double, bottom: Double, edge: Double, lit: PosterInk, shade: PosterInk, slope: Double = 0.1) {
        Poster.fill(g, lit, [P(x0, top + (edge - x0) * slope), P(edge, top), P(edge, bottom), P(x0, bottom)])
        Poster.fill(g, shade, [P(edge, top), P(x1, top + (x1 - edge) * slope), P(x1, bottom), P(edge, bottom)])
    }

    /// Vertical lines running up a face.
    func flutes(_ x0: Double, _ x1: Double, top: Double, bottom: Double, step: Double, width: Double, ink: PosterInk) {
        var x = x0 + step
        g.setFillColor(Poster.cg(ink))
        g.beginPath()
        while x < x1 - step * 0.4 {
            g.addRect(CGRect(x: x - width / 2, y: top, width: width, height: bottom - top))
            x += step
        }
        g.fillPath()
    }

    /// Lights as broken vertical strips between a face's piers.
    mutating func strips(_ x0: Double, _ x1: Double, top: Double, bottom: Double, step: Double, width: Double, on: Double, ink: PosterInk, runs: ClosedRange<Double> = 14...70) {
        g.setFillColor(Poster.cg(ink))
        g.beginPath()
        var x = x0 + step / 2
        while x < x1 {
            var y = top + rng.next(0, 18)
            while y < bottom {
                let run = rng.next(runs.lowerBound, runs.upperBound)
                if rng.next() < on { g.addRect(CGRect(x: x - width / 2, y: y, width: width, height: min(run, bottom - y))) }
                y += run + rng.next(4, 26)
            }
            x += step
        }
        g.fillPath()
    }

    /// Lights as whole or part floors.
    mutating func floors(_ x0: Double, _ x1: Double, top: Double, bottom: Double, step: Double, thick: Double, on: Double, ink: PosterInk) {
        g.setFillColor(Poster.cg(ink))
        g.beginPath()
        var y = top + step / 2
        let w = x1 - x0
        while y < bottom {
            if rng.next() < on {
                let a = x0 + w * (rng.next() < 0.5 ? 0 : rng.next(0, 0.5))
                let b = rng.next() < 0.4 ? x1 : a + w * rng.next(0.16, 0.6)
                g.addRect(CGRect(x: a, y: y, width: min(b, x1) - a, height: thick))
            }
            y += step
        }
        g.fillPath()
    }

    /// Lights as patches: a few offices awake on one part of a floor plate, a little block of rooms, the rest dark.
    mutating func patches(_ x0: Double, _ x1: Double, top: Double, bottom: Double, dx: Double, dy: Double, w: Double, h: Double, count: Int, ink: PosterInk) {
        g.setFillColor(Poster.cg(ink))
        g.beginPath()
        let cols = max(1, Int((x1 - x0) / dx)), rows = max(1, Int((bottom - top) / dy))
        for _ in 0..<count {
            let c0 = Int(rng.next(0, Double(cols))), r0 = Int(rng.next(0, Double(rows)))
            let cn = Int(rng.next(1, 5)), rn = Int(rng.next(1, 4))
            for cc in c0..<min(cols, c0 + cn) {
                for rr in r0..<min(rows, r0 + rn) where rng.next() < 0.76 {
                    g.addRect(CGRect(x: x0 + Double(cc) * dx + (dx - w) / 2, y: top + Double(rr) * dy + (dy - h) / 2, width: w, height: h))
                }
            }
        }
        g.fillPath()
    }

    /// A pointed window.
    func lancet(_ x: Double, _ y0: Double, _ w: Double, _ h: Double, _ ink: PosterInk) {
        Poster.fill(g, ink, [P(x, y0), P(x + w, y0), P(x + w, y0 - h + w * 0.8), P(x + w / 2, y0 - h), P(x, y0 - h + w * 0.8)])
    }
}

nonisolated extension Poster {
    static func cityDusk(_ c: PosterCanvas, dark: Bool) {
        var rng = SplitMix64(seed: 0xC17_0001)
        let lift = max(0, 2168 - c.bottomY) * 0.86
        let shore = 1490.0

        // The sky: the last of the day low down, going up through rose and violet into evening blue. At night, the same order, nearly gone.
        let skyStops: [(Double, PosterInk)] = dark
            ? [(0, hx(0x050814)), (0.36, hx(0x0A1230)), (0.6, hx(0x15204A)), (0.8, hx(0x2A2A58)), (0.93, hx(0x53305A)), (1, hx(0x7E4458))]
            : [(0, hx(0x2C4F84)), (0.24, hx(0x54709E)), (0.46, hx(0x8F86AE)), (0.64, hx(0xD29AA4)), (0.82, hx(0xF4B48C)), (1, hx(0xFFDBA4))]
        c.pull(PosterRamp(skyStops, step: 1), amp: dark ? 0.03 : 0.042, key: 1, rows: (0, c.row(shore + 4))) { _, y in Float((y - 180) / 1240) }
        if dark {
            PosterSky.stars2(c, until: 760, bright: [(148, 220, 2.2), (620, 130, 1.7), (850, 300, 2.3), (226, 470, 1.7)], dots: hx(0xB8BEDC), big: hx(0xF4E8DC), count: 360, seed: 75)
        }

        // A cloud bank behind the buildings on the right, the sun still under its lower left. Flat clouds across.
        let sunL = dark ? PosterLight(-0.62, 0.3, 0.5) : PosterLight(-0.8, 0.3, 0.5)
        let lx = sunL.x, ly = sunL.y
        let gi = 1 / (lx * lx + ly * ly).squareRoot()
        let cloudRamp = PosterRamp(dark
            ? [(0, hx(0x10143A)), (0.3, hx(0x1A1A46)), (0.6, hx(0x2E2450)), (0.86, hx(0x302650)), (1, hx(0x3A2A58))]
            : [(0, hx(0x7C78A6)), (0.28, hx(0xA88AAA)), (0.5, hx(0xDC9EA2)), (0.72, hx(0xF7BE96)), (1, hx(0xFFE8BE))], step: 0.5)
        let shade: (Double, Double, Float, Float, Float, PosterBillow) -> Float = { x, y, ndl, form, _, b in
            let size = Float(b.ry / b.mry)
            let dxn = Float((x - b.x) / b.rx), dyn = Float((y - b.y) / b.ry)
            let away = -(dxn * lx + dyn * ly)
            let merge = 1 - sstep(0.0, 0.92, away)
            let fx = Float((x - b.mx) / b.mrx), fy = Float((y - b.my) / b.mry)
            let graze = (fx * lx + fy * ly) * gi
            let a = (0.1 + 0.3 * sstep(0.06, 0.4, size))
            let f = 0.7 * graze + 0.3 * form + a * (ndl - 0.55) * merge
            return 0.08 + sstep(-0.36, 0.72, f) * 0.92
        }
        var bank: [PosterBillow] = []
        let masses: [(x: Double, y: Double, rx: Double, ry: Double, inner: Int)] = [
            (700, 930, 110, 76, 8), (830, 880, 150, 110, 9), (960, 960, 150, 110, 8), (610, 1010, 110, 56, 7), (780, 1010, 210, 76, 10), (980, 1060, 170, 70, 7)
        ]
        for m in masses { crownHeap(&bank, x: m.x, y: m.y, rx: m.rx, ry: m.ry, inner: m.inner, rng: &rng) }
        c.billows(bank, ramp: cloudRamp, amp: 0.03, key: 14, light: sunL, base: { x in 1092 + 5 * sin(x / 70) + 3 * sin(x / 23) }, shade: shade)
        do {
            var r = SplitMix64(seed: 0x57E8)
            let groups: [(Double, Double, Double, Double, Double)] = [
                (-160, 340, 690, 13, 6), (40, 300, 730, 8, 3), (-120, 180, 1000, 10, 4), (60, 420, 1046, 12, 4), (540, 1120, 548, 12, 5), (700, 1100, 590, 8, 3)
            ]
            var bodies: [[P]] = []
            for g in groups { bodies.append(PosterCut.spindle(x0: g.0, x1: g.1, y: g.2, up: g.3, down: g.4, skew: 0.56, rng: &r)) }
            let body = PosterPlate(c) { g in for b in bodies { fillPoly(g, b) } }
            c.flat(dark ? hx(0x201E4C) : hx(0xB48AA8), plate: body, opacity: 0.86)
            let lit = PosterPlate(c) { g in
                for b in bodies {
                    g.saveGState()
                    g.beginPath()
                    poly(g, b)
                    g.clip()
                    fillPoly(g, b.map { P($0.x - 8, $0.y + 3.5) })
                    g.restoreGState()
                }
            }
            c.flat(dark ? hx(0x3C2A58) : hx(0xFFD6B0), plate: lit, opacity: 0.92)
        }

        // Two far skylines, each paler than the one in front of it: the first steps of air.
        func farCity(_ pts: [P], top: PosterInk, bottom: PosterInk, from: Double, span: Double, key: Int) {
            let p = PosterPlate(c) { g in fillPoly(g, pts + [P(1040, shore + 4), P(-40, shore + 4)]) }
            c.pull(PosterRamp([(0, top), (1, bottom)], step: 0.9), plate: p, amp: 0.05, key: key) { _, y in Float((y - from) / span) }
        }
        farCity([P(-40, 1230), P(30, 1230), P(30, 1170), P(62, 1170), P(62, 1120), P(70, 1096), P(78, 1120), P(78, 1190), P(130, 1190), P(130, 1138), P(178, 1138), P(178, 1214), P(240, 1214), P(240, 1110), P(258, 1090), P(276, 1110), P(276, 1220), P(340, 1220), P(340, 1150), P(380, 1150), P(380, 1240), P(460, 1240), P(460, 1160), P(494, 1160), P(494, 1100), P(530, 1100), P(530, 1210), P(600, 1210), P(600, 1130), P(610, 1070), P(620, 1130), P(620, 1200), P(700, 1200), P(700, 1150), P(760, 1150), P(760, 1090), P(800, 1090), P(800, 1210), P(860, 1210), P(860, 1120), P(910, 1120), P(910, 1040), P(918, 1000), P(926, 1040), P(926, 1180), P(1040, 1180)],
                top: dark ? hx(0x282A5A) : hx(0xC8A0AC), bottom: dark ? hx(0x48305C) : hx(0xF4BE9A), from: 1000, span: 440, key: 6)
        farCity([P(-40, 1300), P(40, 1300), P(40, 1240), P(100, 1240), P(100, 1290), P(190, 1290), P(190, 1200), P(232, 1200), P(232, 1280), P(330, 1280), P(330, 1226), P(420, 1226), P(420, 1300), P(520, 1300), P(520, 1238), P(574, 1238), P(574, 1180), P(586, 1148), P(598, 1180), P(598, 1290), P(690, 1290), P(690, 1216), P(762, 1216), P(762, 1300), P(880, 1300), P(880, 1212), P(944, 1212), P(944, 1272), P(1040, 1272)],
                top: dark ? hx(0x1E2050) : hx(0xA886A4), bottom: dark ? hx(0x3C2A58) : hx(0xEBAE92), from: 1150, span: 340, key: 7)

        // The city.
        func mixed(_ a: UInt32, _ b: UInt32, _ t: Double) -> PosterInk { hx(a).mixed(with: hx(b), t) }
        // Depth 0 far, 1 near. Lit faces catch the last of the sun on the left.
        func lit(_ d: Double) -> PosterInk { dark ? mixed(0x2E2C5C, 0x1E2244, d) : mixed(0xF0AE90, 0xC9644C, d) }
        func shadeInk(_ d: Double) -> PosterInk { dark ? mixed(0x1E1E4C, 0x0C102C, d) : mixed(0xA888A8, 0x4A3A6E, d) }
        func deep(_ d: Double) -> PosterInk { dark ? mixed(0x161840, 0x060A1E, d) : mixed(0x8E7098, 0x342A58, d) }
        func rim(_ d: Double) -> PosterInk { dark ? mixed(0x6A4A6A, 0x4A3858, d) : mixed(0xFFE0C0, 0xFFC898, d) }
        let glow: PosterInk = dark ? hx(0xD9A35C) : hx(0xFFE29A), cool: PosterInk = dark ? hx(0xBFD8E6) : hx(0xFFF4D0)
        let copperLit: PosterInk = dark ? hx(0x28505A) : hx(0x7DBFAE), copperShade: PosterInk = dark ? hx(0x10283C) : hx(0x2F6C78)
        let on = dark ? 0.7 : 0.46

        c.paint { g in
            var b = CityPainter(g: g, dark: dark, glow: glow, cool: cool, rng: SplitMix64(seed: 0xB111))

            // A slab at far left with a lattice mast.
            do {
                let d = 0.3
                b.box(14, 92, top: 1010, bottom: 1500, edge: 34, lit: lit(d), shade: shadeInk(d))
                b.flutes(36, 92, top: 1014, bottom: 1500, step: 14, width: 1.2, ink: deep(d))
                b.floors(36, 92, top: 1030, bottom: 1320, step: 13, thick: 2.6, on: 0.46 * on, ink: glow)
                fill(g, deep(d), [P(50, 1012), P(53, 900), P(55, 900), P(58, 1012)])
                fill(g, deep(d), [P(40, 1012), P(40, 996), P(68, 996), P(68, 1012)])
                for y in [930.0, 950.0, 970.0] { b.rect(deep(d), 48, y, 60, y + 1.6) }
            }

            // The glass slab: its roof cut on a long diagonal, the sky lying in it in bands.
            do {
                let d = 0.32
                let x0 = 760.0, e = 784.0, x1 = 872.0
                let rise: (Double) -> Double = { x in 776 - (x - x0) * 1.16 }
                let glassA: PosterInk = dark ? hx(0x1C2454) : hx(0x8E8CB8), glassB: PosterInk = dark ? hx(0x2C2C60) : hx(0xD8A2AE), glassC: PosterInk = dark ? hx(0x46305E) : hx(0xFAC49C)
                fill(g, lit(d), [P(x0, rise(x0)), P(e, rise(e)), P(e, 1500), P(x0, 1500)])
                fill(g, glassA, [P(e, rise(e)), P(x1, rise(x1)), P(x1, 1500), P(e, 1500)])
                // Bands of sky running down the glass on the same diagonal.
                func band(_ y: Double, _ h: Double, _ ink: PosterInk) {
                    fill(g, ink, [P(e, y), P(x1, y - (x1 - e) * 0.62), P(x1, y - (x1 - e) * 0.62 + h), P(e, y + h)])
                }
                band(900, 90, glassB)
                band(1010, 34, glassB)
                band(1100, 150, glassC)
                band(1290, 46, glassC)
                band(1370, 120, glassB)
                g.saveGState()
                g.beginPath()
                poly(g, [P(e, rise(e)), P(x1, rise(x1)), P(x1, 1500), P(e, 1500)])
                g.clip()
                b.flutes(e, x1, top: 640, bottom: 1500, step: 11, width: 0.9, ink: deep(d))
                g.restoreGState()
                b.patches(e, x1, top: 900, bottom: 1320, dx: 11, dy: 9, w: 6.8, h: 4.4, count: dark ? 8 : 4, ink: cool)
                // The cut edge catches the light.
                fill(g, rim(d), [P(x0, rise(x0)), P(x1, rise(x1)), P(x1, rise(x1) + 3), P(x0, rise(x0) + 3)])
            }

            // A pencil of a tower, all balconies, far right.
            do {
                let d = 0.36
                b.box(918, 958, top: 790, bottom: 1500, edge: 930, lit: lit(d), shade: shadeInk(d), slope: 0.2)
                fill(g, deep(d), [P(918, 794), P(938, 730), P(958, 794)])
                fill(g, rim(d), [P(918, 794), P(938, 730), P(932, 794)])
                var y = 806.0
                g.setFillColor(cg(deep(d)))
                g.beginPath()
                while y < 1500 {
                    g.addRect(CGRect(x: 918, y: y, width: 40, height: 2.2))
                    y += 8.4
                }
                g.fillPath()
                b.floors(932, 958, top: 820, bottom: 1320, step: 8.4, thick: 3.4, on: 0.34 * on, ink: glow)
            }

            // Twin slabs and the bridge between them.
            do {
                let d = 0.42
                b.box(668, 716, top: 918, bottom: 1500, edge: 680, lit: lit(d), shade: shadeInk(d))
                b.box(726, 776, top: 948, bottom: 1500, edge: 738, lit: lit(d), shade: shadeInk(d))
                for (x0, x1) in [(680.0, 716.0), (738.0, 776.0)] {
                    var y = 930.0
                    g.setFillColor(cg(deep(d)))
                    g.beginPath()
                    while y < 1500 {
                        g.addRect(CGRect(x: x0, y: y, width: x1 - x0, height: 3.6))
                        y += 11
                    }
                    g.fillPath()
                    b.floors(x0, x1, top: 960, bottom: 1320, step: 11, thick: 2.4, on: 0.5 * on, ink: glow)
                }
                b.rect(shadeInk(d), 716, 1070, 726, 1096)
                b.rect(glow, 717, 1076, 725, 1080)
                b.rect(deep(d), 690, 900, 694, 918)
                b.rect(deep(d), 752, 932, 756, 948)
            }

            // The tall one: a stepped tower with fluted piers, a chevron crown and a needle.
            do {
                let d = 0.5
                let cx = 380.0
                let tiers: [(w: Double, top: Double, bottom: Double)] = [(164, 1046, 1500), (126, 888, 1046), (92, 752, 888), (58, 654, 752)]
                let edgeF = 0.34
                // The needle first.
                fill(g, deep(d), [P(cx - 2.2, 600), P(cx, 450), P(cx + 2.2, 600)])
                fill(g, rim(d), [P(cx - 2.2, 600), P(cx, 450), P(cx - 0.2, 600)])
                // The crown.
                let cw = 29.0, ctop = 566.0, cbot = 654.0
                let ce = cx - cw + 2 * cw * edgeF
                fill(g, lit(d), [P(cx - cw, cbot + 4), P(ce, ctop), P(ce, cbot)])
                fill(g, shadeInk(d), [P(ce, ctop), P(cx + cw, cbot + 4), P(ce, cbot)])
                for i in 0..<5 {
                    let t = Double(i) * 0.2 + 0.08
                    let y = ctop + (cbot - ctop) * t
                    let wl = (ce - (cx - cw)) * t, wr = (cx + cw - ce) * t
                    fill(g, rim(d), [P(ce - wl, y + 1.4 + 4 * t), P(ce, y - 6), P(ce, y - 2.6), P(ce - wl, y + 4.8 + 4 * t)])
                    fill(g, dark ? hx(0x4A4068) : hx(0xE8A890), [P(ce, y - 6), P(ce + wr, y + 1.4 + 4 * t), P(ce + wr, y + 4.8 + 4 * t), P(ce, y - 2.6)])
                }
                for (i, t) in tiers.enumerated() {
                    let x0 = cx - t.w / 2, x1 = cx + t.w / 2, e = x0 + t.w * edgeF
                    b.box(x0, x1, top: t.top, bottom: t.bottom, edge: e, lit: lit(d), shade: shadeInk(d), slope: 0.05)
                    // Piers: dark grooves on both faces, narrow lights between them higher up, floors of it lower down.
                    b.flutes(x0, e, top: t.top + 10, bottom: t.bottom, step: 8, width: 1.4, ink: dark ? hx(0x161C40) : hx(0xA24C48))
                    b.flutes(e, x1, top: t.top + 10, bottom: t.bottom, step: 9, width: 1.6, ink: deep(d))
                    if i < 3 {
                        b.strips(e, x1, top: t.top + 16, bottom: min(t.bottom - 4, 1320), step: 9, width: 3.0, on: 0.5 * on, ink: glow)
                        b.strips(x0, e, top: t.top + 16, bottom: min(t.bottom - 4, 1320), step: 8, width: 2.2, on: 0.12 * on, ink: glow)
                    } else {
                        b.strips(e, x1, top: t.top + 14, bottom: t.bottom - 2, step: 9, width: 3.0, on: 0.74 * on, ink: cool, runs: 40...90)
                    }
                    // The ledge at each setback, and its shadow under it.
                    fill(g, rim(d), [P(x0 - 2, t.top + (e - x0) * 0.05), P(e, t.top - 1.6), P(e, t.top + 3), P(x0 - 2, t.top + (e - x0) * 0.05 + 3.6)])
                    fill(g, dark ? hx(0x3A3058) : hx(0xD08A78), [P(e, t.top - 1.6), P(x1 + 2, t.top + (x1 - e) * 0.05), P(x1 + 2, t.top + (x1 - e) * 0.05 + 3.6), P(e, t.top + 3)])
                    b.rect(deep(d), e, t.top + 3, x1, t.top + 8)
                    // Little stepped shoulders at the corners of the setback.
                    if i > 0 {
                        let up = tiers[i - 1].top
                        b.box(x0 - 7, x0 + 7, top: t.bottom - 18, bottom: up, edge: x0 - 2, lit: lit(d), shade: shadeInk(d))
                        b.box(x1 - 7, x1 + 7, top: t.bottom - 18, bottom: up, edge: x1 - 2, lit: lit(d), shade: shadeInk(d))
                    }
                }
            }

            // The old insurance building: tall lancets and a steep green-copper roof with turrets.
            do {
                let d = 0.56
                let x0 = 536.0, x1 = 644.0, e = 568.0, top = 872.0
                // The roof.
                fill(g, copperLit, [P(x0 + 2, top + 2), P(e + 18, 736), P(e, top + 2)])
                fill(g, copperShade, [P(e + 18, 736), P(x1 - 2, top + 2), P(e, top + 2)])
                // Dormers on the roof, one row, lit.
                for (x, y) in [(590.0, 846.0), (612.0, 850.0), (586.0, 808.0)] {
                    b.lancet(x, y + 16, 8, 20, dark ? hx(0x10283C) : hx(0x24505C))
                    b.lancet(x + 1.6, y + 14, 4.8, 14, glow)
                }
                // Ridge.
                fill(g, dark ? hx(0x7A9CA0) : hx(0xCFEADC), [P(e + 17.2, 736), P(e + 18.8, 736), P(e + 19, 716), P(e + 17, 716)])
                b.box(x0, x1, top: top, bottom: 1500, edge: e, lit: lit(d), shade: shadeInk(d), slope: 0.04)
                // Turrets at the corners.
                for x in [x0 + 3, e, x1 - 3] {
                    fill(g, copperLit, [P(x - 6, top + 6), P(x, top - 42), P(x, top + 6)])
                    fill(g, copperShade, [P(x, top - 42), P(x + 6, top + 6), P(x, top + 6)])
                    b.rect(lit(d), x - 6, top + 6, x + 6, top + 24)
                    b.rect(shadeInk(d), x, top + 6, x + 6, top + 24)
                }
                // Tall pointed windows under the eaves, then long piers.
                var x = e + 6
                while x < x1 - 8 {
                    b.lancet(x, top + 84, 8, 54, deep(d))
                    b.lancet(x + 1.2, top + 82, 5.6, 48, glow)
                    x += 14
                }
                x = x0 + 5
                while x < e - 6 {
                    b.lancet(x, top + 84, 6, 52, dark ? hx(0x161C40) : hx(0x9A4C4C))
                    x += 10
                }
                b.flutes(e, x1, top: top + 92, bottom: 1500, step: 14, width: 2, ink: deep(d))
                b.flutes(x0, e, top: top + 92, bottom: 1500, step: 10, width: 1.6, ink: dark ? hx(0x161C40) : hx(0xA24C48))
                b.strips(e, x1, top: top + 100, bottom: 1320, step: 14, width: 4.6, on: 0.5 * on, ink: glow, runs: 8...46)
                b.rect(rim(d), x0, top + 88, e, top + 91)
                b.rect(deep(d), e, top + 88, x1, top + 91)
            }

            // A ribbed cylinder, its floors curving round.
            do {
                let d = 0.62
                let x0 = 104.0, x1 = 222.0, top = 894.0
                let cxx = (x0 + x1) / 2, rx = (x1 - x0) / 2, ry = 9.0
                // The body in strips, sun on the left of the curve.
                let bands: [(Double, Double)] = [(-1, 0.1), (-0.86, 0.0), (-0.62, 0.06), (-0.3, 0.3), (0.0, 0.56), (0.32, 0.76), (0.62, 0.9), (0.86, 1.0)]
                for (i, s) in bands.enumerated() {
                    let a = cxx + rx * s.0, z = i + 1 < bands.count ? cxx + rx * bands[i + 1].0 : x1
                    let ink = lit(d).mixed(with: shadeInk(d), s.1)
                    let t0 = top + ry * sqrt(max(0, 1 - s.0 * s.0)), t1 = top + ry * sqrt(max(0, 1 - pow(i + 1 < bands.count ? bands[i + 1].0 : 1, 2)))
                    fill(g, ink, [P(a, t0), P(z, t1), P(z, 1500), P(a, 1500)])
                }
                // Curved floors.
                func arc(_ y: Double, _ thick: Double, from: Double, to: Double, ink: PosterInk) {
                    var up: [P] = [], down: [P] = []
                    for i in 0...16 {
                        let u = from + (to - from) * Double(i) / 16
                        let px = cxx + rx * u, py = y + ry * sqrt(max(0, 1 - u * u))
                        up.append(P(px, py)); down.append(P(px, py + thick))
                    }
                    fill(g, ink, up + down.reversed())
                }
                var y = top + 12
                while y < 1500 {
                    arc(y, 2.2, from: -1, to: 1, ink: deep(d))
                    y += 15
                }
                y = top + 30
                while y < 1330 {
                    if b.rng.next() < 0.5 * on {
                        let a = b.rng.next(-0.7, 0.4)
                        arc(y + 5, 4.2, from: a, to: min(0.96, a + b.rng.next(0.2, 0.9)), ink: glow)
                    }
                    y += 15
                }
                // Rim, cap and a thin mast.
                fill(g, rim(d), (0...20).map { (i: Int) -> P in
                    let a = Double(i) / 20 * 2 * .pi
                    return P(cxx + rx * cos(a), top + ry * sin(a))
                })
                fill(g, deep(d), (0...20).map { (i: Int) -> P in
                    let a = Double(i) / 20 * 2 * .pi
                    return P(cxx + rx * 0.84 * cos(a), top - 2 + ry * 0.7 * sin(a))
                })
                fill(g, shadeInk(d), [P(cxx - 18, top - 3), P(cxx - 16, top - 24), P(cxx + 16, top - 24), P(cxx + 18, top - 3)])
                fill(g, lit(d), [P(cxx - 18, top - 3), P(cxx - 16, top - 24), P(cxx - 8, top - 24), P(cxx - 8, top - 3)])
                fill(g, deep(d), [P(cxx - 1.4, top - 24), P(cxx - 0.6, top - 96), P(cxx + 0.6, top - 96), P(cxx + 1.4, top - 24)])
            }

            // A heavy brown block with a stepped rooftop plant.
            do {
                let d = 0.66
                b.box(836, 924, top: 1058, bottom: 1500, edge: 856, lit: lit(d), shade: shadeInk(d))
                b.box(858, 904, top: 1022, bottom: 1060, edge: 868, lit: lit(d), shade: shadeInk(d))
                b.box(872, 892, top: 1000, bottom: 1024, edge: 878, lit: lit(d), shade: deep(d))
                b.floors(858, 924, top: 1080, bottom: 1300, step: 13, thick: 3.2, on: 0.36 * on, ink: glow)
                b.patches(838, 856, top: 1076, bottom: 1320, dx: 6.6, dy: 12, w: 3.6, h: 7, count: dark ? 5 : 3, ink: glow)
            }

            // A stepped ziggurat with a lantern on it.
            do {
                let d = 0.7
                for (x0, x1, top, e) in [(478.0, 530.0, 1034.0, 494.0), (464.0, 544.0, 1078.0, 486.0), (448.0, 560.0, 1136.0, 478.0), (434.0, 576.0, 1214.0, 470.0)] {
                    b.box(x0, x1, top: top, bottom: 1500, edge: e, lit: lit(d), shade: shadeInk(d), slope: 0.06)
                    b.rect(rim(d), x0, top + (e - x0) * 0.06 - 1, e, top + (e - x0) * 0.06 + 2)
                    b.flutes(e, x1, top: top + 8, bottom: 1500, step: 10, width: 1.5, ink: deep(d))
                    b.flutes(x0, e, top: top + 8, bottom: 1500, step: 7, width: 1.1, ink: dark ? hx(0x161C40) : hx(0xA24C48))
                    b.strips(e, x1, top: top + 12, bottom: min(1320, top + 130), step: 10, width: 3, on: 0.4 * on, ink: glow, runs: 8...40)
                }
                b.rect(lit(d), 496, 1002, 502, 1036)
                b.rect(shadeInk(d), 502, 1002, 512, 1038)
                b.rect(glow, 498, 1008, 510, 1028)
                b.flutes(498, 510, top: 1008, bottom: 1028, step: 4, width: 1, ink: deep(d))
                fill(g, deep(d), [P(492, 1004), P(504, 980), P(516, 1004)])
                fill(g, rim(d), [P(492, 1004), P(504, 980), P(500, 1004)])
            }

            // A hotel in the old manner: stone, a mansard with dormers, a flag.
            do {
                let d = 0.8
                let x0 = 196.0, x1 = 340.0, e = 226.0, top = 1176.0
                // Flag.
                b.rect(deep(d), 268, 1076, 269.6, 1132)
                fill(g, dark ? hx(0x6A3048) : hx(0xD8503C), [P(269.6, 1078), P(298, 1084), P(290, 1089), P(297, 1096), P(269.6, 1094)])
                // Mansard.
                fill(g, deep(d), [P(x0 + 2, top), P(x0 + 16, 1130), P(x1 - 14, 1130), P(x1 - 2, top)])
                fill(g, dark ? hx(0x2A2C54) : hx(0x8E5C70), [P(x0 + 2, top), P(x0 + 16, 1130), P(e + 8, 1130), P(e, top)])
                var x = e + 10
                while x < x1 - 12 {
                    b.rect(rim(d), x - 1.6, 1152, x + 9.6, 1173)
                    fill(g, rim(d), [P(x - 2.6, 1153), P(x + 4, 1145), P(x + 10.6, 1153)])
                    b.rect(b.rng.next() < 0.6 * on ? glow : deep(d), x, 1155, x + 8, 1172)
                    x += 19
                }
                // The wall.
                b.box(x0, x1, top: top, bottom: 1500, edge: e, lit: lit(d), shade: shadeInk(d), slope: 0.02)
                b.rect(rim(d), x0 - 3, top - 2, e, top + 3)
                b.rect(dark ? hx(0x3C3460) : hx(0xD08A78), e, top - 2, x1 + 3, top + 3)
                b.rect(deep(d), e, top + 3, x1, top + 8)
                // Rooms: tall windows in groups of three, some awake.
                var y = top + 16
                while y < 1340 {
                    var q = e + 6
                    while q < x1 - 6 {
                        let isOn = b.rng.next() < 0.42 * on
                        b.rect(isOn ? glow : deep(d), q, y, q + 5.6, y + 13)
                        q += 10.6
                        if Int(q) % 3 == 0 { q += 3 }
                    }
                    q = x0 + 4
                    while q < e - 3 {
                        b.rect(dark ? hx(0x12163A) : hx(0x8E4240), q, y, q + 3.8, y + 13)
                        q += 7.4
                    }
                    y += 22
                }
            }

            // A little stone clock tower on the civic square.
            do {
                let d = 0.84
                b.box(422, 470, top: 1236, bottom: 1500, edge: 436, lit: lit(d), shade: shadeInk(d), slope: 0.04)
                fill(g, deep(d), [P(418, 1240), P(442, 1166), P(474, 1240)])
                fill(g, dark ? hx(0x34345C) : hx(0xA26870), [P(418, 1240), P(442, 1166), P(437, 1240)])
                fill(g, rim(d), [P(418, 1240), P(474, 1240), P(474, 1243), P(418, 1243)])
                g.setFillColor(cg(deep(d)))
                g.fillEllipse(in: CGRect(x: 438, y: 1254, width: 28, height: 28))
                g.setFillColor(cg(dark ? hx(0xFFE2A6) : hx(0xFFF4DC)))
                g.fillEllipse(in: CGRect(x: 440.4, y: 1256.4, width: 23.2, height: 23.2))
                b.rect(deep(d), 451.2, 1261, 452.8, 1268.8)
                fill(g, deep(d), [P(452, 1268), P(458, 1272), P(457.2, 1273.2), P(451.2, 1269.4)])
                b.lancet(442, 1320, 7, 26, deep(d))
                b.lancet(454, 1320, 7, 26, deep(d))
            }

            // The civic dome, copper, on a drum and a row of columns.
            do {
                let d = 0.86
                let cx = 662.0, r = 54.0, y0 = 1282.0
                fill(g, deep(d), (0...22).map { (i: Int) -> P in
                    let a = .pi + Double(i) / 22 * .pi
                    return P(cx + r * cos(a), y0 + r * 1.06 * sin(a))
                })
                // Ribs and light on the curve.
                let shadesOf: [(Double, Double, PosterInk)] = [(-1, -0.66, copperLit), (-0.66, -0.14, copperLit.mixed(with: copperShade, 0.34)), (-0.14, 0.42, copperShade), (0.42, 1, deep(d))]
                for s in shadesOf {
                    var pts: [P] = []
                    for i in 0...10 {
                        let u = s.0 + (s.1 - s.0) * Double(i) / 10
                        pts.append(P(cx + r * u, y0 - r * 1.06 * sqrt(max(0, 1 - u * u))))
                    }
                    pts.append(P(cx + r * s.1, y0))
                    pts.append(P(cx + r * s.0, y0))
                    fill(g, s.2, pts)
                }
                for u in [-0.72, -0.4, -0.1, 0.2, 0.5, 0.78] {
                    var pts: [P] = [], back: [P] = []
                    for i in 0...10 {
                        let v = Double(i) / 10
                        let wide = sqrt(max(0, 1 - v * v))
                        pts.append(P(cx + r * u * wide - 0.6, y0 - r * 1.06 * v))
                        back.append(P(cx + r * u * wide + 0.6, y0 - r * 1.06 * v))
                    }
                    fill(g, deep(d), pts + back.reversed())
                }
                // Lantern.
                b.rect(rim(d), cx - 10, y0 - r * 1.06 - 16, cx + 10, y0 - r * 1.06 + 2)
                b.rect(glow, cx - 7, y0 - r * 1.06 - 13, cx + 7, y0 - r * 1.06 - 1)
                b.flutes(cx - 7, cx + 7, top: y0 - r * 1.06 - 13, bottom: y0 - r * 1.06 - 1, step: 4.6, width: 1.2, ink: deep(d))
                fill(g, copperShade, [P(cx - 12, y0 - r * 1.06 - 16), P(cx, y0 - r * 1.06 - 36), P(cx + 12, y0 - r * 1.06 - 16)])
                fill(g, copperLit, [P(cx - 12, y0 - r * 1.06 - 16), P(cx, y0 - r * 1.06 - 36), P(cx - 2, y0 - r * 1.06 - 16)])
                // Drum.
                b.box(cx - r - 2, cx + r + 2, top: y0 - 2, bottom: y0 + 40, edge: cx - 22, lit: lit(d), shade: shadeInk(d), slope: 0.02)
                b.flutes(cx - r - 2, cx + r + 2, top: y0 + 8, bottom: y0 + 40, step: 11, width: 5, ink: deep(d))
                b.rect(rim(d), cx - r - 6, y0 - 4, cx - 22, y0 + 1)
                // Portico below.
                b.box(cx - r - 40, cx + r + 40, top: y0 + 40, bottom: 1500, edge: cx - 62, lit: lit(d), shade: shadeInk(d), slope: 0.01)
                b.rect(rim(d), cx - r - 44, y0 + 37, cx - 62, y0 + 42)
                b.rect(dark ? hx(0x3C3460) : hx(0xD08A78), cx - 62, y0 + 37, cx + r + 44, y0 + 42)
                var x = cx - r - 34
                while x < cx + r + 30 {
                    b.rect(x < cx - 62 ? (dark ? hx(0x12163A) : hx(0x8E4240)) : deep(d), x, y0 + 50, x + 7, y0 + 94)
                    if dark || x > cx { if b.rng.next() < 0.6 * on { b.rect(glow, x + 1.2, y0 + 54, x + 5.8, y0 + 92) } }
                    x += 13
                }
            }

            // Brick lofts on the left, with a water tank on legs.
            do {
                let d = 0.9
                let brick: PosterInk = dark ? hx(0x24203C) : hx(0xA84B3A), brickShade: PosterInk = dark ? hx(0x0E0E28) : hx(0x5E3248)
                // The tank.
                let tx = 58.0, ty = 1224.0
                for u in [-13.0, 0, 13] { fill(g, deep(1), [P(tx + u - 1.2, ty + 26), P(tx + u * 1.3 - 1, ty + 56), P(tx + u * 1.3 + 1, ty + 56), P(tx + u + 1.2, ty + 26)]) }
                b.rect(deep(1), tx - 16, ty + 40, tx + 16, ty + 41.6)
                fill(g, dark ? hx(0x2A2440) : hx(0x8A5A44), [P(tx - 16, ty), P(tx - 4, ty), P(tx - 4, ty + 28), P(tx - 16, ty + 28)])
                fill(g, deep(1), [P(tx - 4, ty), P(tx + 16, ty), P(tx + 16, ty + 28), P(tx - 4, ty + 28)])
                fill(g, deep(1), [P(tx - 19, ty + 1), P(tx, ty - 14), P(tx + 19, ty + 1)])
                fill(g, rim(d), [P(tx - 19, ty + 1), P(tx, ty - 14), P(tx - 5, ty + 1)])
                b.box(-10, 176, top: 1280, bottom: 1500, edge: 28, lit: brick, shade: brickShade, slope: 0.02)
                b.rect(rim(d), -10, 1277, 28, 1281)
                b.rect(deep(1), 28, 1279, 176, 1283)
                var y = 1296.0
                while y < 1400 {
                    var x = 36.0
                    while x < 170 {
                        let isOn = b.rng.next() < 0.3 * on
                        b.lancet(x, y + 16, 9, 18, deep(1))
                        if isOn { b.lancet(x + 1.2, y + 15, 6.6, 15, glow) }
                        x += 15.4
                    }
                    y += 28
                }
                // A painted sign wall on the lit end, faded to nothing but its bands.
                b.rect(dark ? hx(0x2C2848) : hx(0xD08A6C), -10, 1300, 28, 1312)
                b.rect(dark ? hx(0x2C2848) : hx(0xD08A6C), -10, 1320, 28, 1326)
            }
        }

        // The air over the waterfront, thickening in steps, then the docks crisp in front of it.
        do {
            let air = dark ? hx(0x4A2E58) : hx(0xFFC89A)
            for (y, op, wa, wl, wp) in [(1246.0, 0.14, 7.0, 170.0, 1.0), (1290.0, 0.32, 6.0, 150.0, 2.2), (1332.0, 0.58, 6.0, 140.0, 3.0), (1372.0, 0.9, 5.0, 120.0, 0.4)] {
                let p = PosterPlate(c) { g in fillPoly(g, PosterCut.wavyBand(y: y, tilt: 0.01, waves: [(wa, wl, wp), (wa * 0.4, wl * 0.33, wp * 2)], floorY: shore + 4)) }
                c.flat(air, plate: p, opacity: op)
            }
        }

        c.paint { g in
            var b = CityPainter(g: g, dark: dark, glow: glow, cool: cool, rng: SplitMix64(seed: 0xB222))
            let wall: PosterInk = dark ? hx(0x10122E) : hx(0x5A4070), wallLit: PosterInk = dark ? hx(0x20203E) : hx(0xB65C4C), dk: PosterInk = dark ? hx(0x060A1E) : hx(0x2E2650), roof: PosterInk = dark ? hx(0x181A3A) : hx(0x7A4E70), edge: PosterInk = dark ? hx(0x5A3C5C) : hx(0xFFC498)
            // Sawtooth sheds on the right, their glass facing the last of the sky, one long clerestory to a bay.
            let awningA: PosterInk = dark ? hx(0x3A2A4C) : hx(0xE9D6B4), awningB: PosterInk = dark ? hx(0x2A2040) : hx(0xC9543F)
            var x = 760.0
            while x < 1040 {
                let w = 46.0
                fill(g, roof, [P(x, 1416), P(x + w, 1386), P(x + w, 1416)])
                fill(g, edge, [P(x, 1416), P(x + w, 1386), P(x + w, 1389), P(x + 2, 1417)])
                fill(g, dark ? glow : hx(0xFFD8A0), [P(x + w - 2.6, 1390), P(x + w - 0.6, 1389), P(x + w - 0.6, 1414), P(x + w - 2.6, 1414)])
                x += w
            }
            b.rect(wall, 760, 1416, 1040, 1500)
            b.rect(dk, 760, 1414, 1040, 1420)
            x = 760
            while x < 1040 {
                b.rect(dk, x + 44, 1420, x + 46, 1490)
                if b.rng.next() < 0.5 + 0.2 * on {
                    b.rect(b.rng.next() < 0.66 * on ? glow : dk, x + 7, 1432, x + 38, 1441)
                    b.rect(wall, x + 22, 1432, x + 23.2, 1441)
                }
                x += 46
            }
            // A big sliding door, half open and lit.
            b.rect(dk, 852, 1456, 898, 1492)
            b.rect(glow, 852, 1458, 872, 1492)
            // Warehouses on the left, one with a pitched roof and a hoist beam.
            fill(g, roof, [P(120, 1420), P(176, 1386), P(232, 1420)])
            fill(g, edge, [P(120, 1420), P(176, 1386), P(176, 1390), P(126, 1420)])
            b.box(124, 228, top: 1420, bottom: 1500, edge: 150, lit: wallLit, shade: wall, slope: 0.0)
            b.rect(dk, 170, 1402, 196, 1405)
            b.rect(dk, 194, 1405, 195.4, 1432)
            for (ax, ay, onIt) in [(160.0, 1438.0, true), (186.0, 1438.0, false), (212.0, 1438.0, true), (160.0, 1466.0, false), (186.0, 1466.0, true), (212.0, 1466.0, false)] {
                b.lancet(ax, ay + 18, 11, 19, dk)
                if onIt && b.rng.next() < 0.9 * on { b.lancet(ax + 1.6, ay + 17, 7.8, 15, glow) }
            }
            b.box(-10, 124, top: 1438, bottom: 1500, edge: 8, lit: wallLit, shade: wall, slope: 0.0)
            b.rect(edge, -10, 1436, 124, 1439)
            b.rect(glow, 18, 1454, 84, 1458)
            b.rect(dk, 40, 1454, 42, 1458)
            b.rect(dk, 62, 1454, 64, 1458)
            // The quay: a run of small buildings, no two alike.
            // A corner shop with a striped awning.
            b.box(232, 300, top: 1446, bottom: 1500, edge: 244, lit: wallLit, shade: wall, slope: 0)
            b.rect(edge, 232, 1444, 244, 1447)
            b.rect(dk, 244, 1445, 300, 1448)
            b.rect(glow, 250, 1472, 294, 1488)
            b.rect(dk, 271, 1472, 272.6, 1488)
            for i in 0..<6 {
                fill(g, i % 2 == 0 ? awningA : awningB, [P(248 + Double(i) * 8, 1464), P(256 + Double(i) * 8, 1464), P(256.4 + Double(i) * 8, 1474), P(248.4 + Double(i) * 8, 1474)])
            }
            b.rect(on > 0.7 ? glow : dk, 256, 1452, 264, 1460)
            // A stepped gable with a round window.
            let gable: [P] = [P(300, 1500), P(300, 1452), P(310, 1452), P(310, 1442), P(320, 1442), P(320, 1432), P(330, 1432), P(330, 1424), P(342, 1424), P(342, 1432), P(352, 1432), P(352, 1442), P(362, 1442), P(362, 1452), P(372, 1452), P(372, 1500)]
            fill(g, wall, gable)
            fill(g, wallLit, [P(300, 1500), P(300, 1452), P(310, 1452), P(310, 1442), P(320, 1442), P(320, 1432), P(324, 1432), P(324, 1500)])
            g.setFillColor(cg(glow))
            g.fillEllipse(in: CGRect(x: 331, y: 1436, width: 11, height: 11))
            b.rect(dk, 330, 1460, 342, 1490)
            b.rect(glow, 332, 1462, 340, 1490)
            b.rect(dk, 350, 1464, 362, 1478)
            // A low arcade, its arches awake.
            b.box(372, 448, top: 1460, bottom: 1500, edge: 380, lit: wallLit, shade: wall, slope: 0)
            b.rect(edge, 372, 1458, 380, 1461)
            b.rect(dk, 380, 1459, 448, 1462)
            var q = 384.0
            while q < 440 {
                b.lancet(q, 1492, 10, 22, dk)
                if b.rng.next() < 0.5 + 0.4 * on { b.lancet(q + 1.6, 1492, 6.8, 18, glow) }
                q += 14
            }
            // A pitched house with a chimney.
            fill(g, dk, [P(492, 1426), P(492, 1412), P(500, 1412), P(500, 1426)])
            fill(g, roof, [P(446, 1444), P(484, 1416), P(522, 1444)])
            fill(g, edge, [P(446, 1444), P(484, 1416), P(484, 1419), P(452, 1444)])
            b.box(450, 518, top: 1444, bottom: 1500, edge: 464, lit: wallLit, shade: wall, slope: 0)
            b.rect(on > 0.7 ? glow : dk, 472, 1454, 482, 1466)
            b.rect(glow, 496, 1454, 506, 1466)
            b.rect(glow, 472, 1474, 506, 1488)
            b.rect(dk, 488, 1474, 490, 1488)
            // A long flat one with a sign band.
            b.box(518, 600, top: 1452, bottom: 1500, edge: 528, lit: wallLit, shade: wall, slope: 0)
            b.rect(edge, 518, 1450, 528, 1453)
            b.rect(dk, 528, 1451, 600, 1454)
            b.rect(dk, 534, 1458, 594, 1468)
            b.rect(awningA, 538, 1461, 590, 1465)
            b.rect(dk, 534, 1476, 594, 1490)
            b.rect(glow, 536, 1478, 560, 1490)
            // The ferry shed with its clock gable.
            fill(g, roof, [P(592, 1432), P(650, 1398), P(708, 1432)])
            fill(g, edge, [P(592, 1432), P(650, 1398), P(650, 1401), P(598, 1432)])
            b.box(600, 700, top: 1432, bottom: 1500, edge: 616, lit: wallLit, shade: wall, slope: 0)
            g.setFillColor(cg(dark ? hx(0xFFE2A6) : hx(0xFFF4DC)))
            g.fillEllipse(in: CGRect(x: 642, y: 1408, width: 16, height: 16))
            b.rect(dk, 626, 1448, 692, 1492)
            b.rect(glow, 630, 1452, 688, 1492)
            b.flutes(630, 688, top: 1452, bottom: 1492, step: 9.6, width: 1.6, ink: dk)
            // A little round-topped kiosk.
            let kx = 730.0
            fill(g, wall, (0...12).map { (i: Int) -> P in
                let a = .pi + Double(i) / 12 * .pi
                return P(kx + 28 * cos(a), 1466 + 22 * sin(a))
            })
            fill(g, edge, (0...6).map { (i: Int) -> P in
                let a = .pi + Double(i) / 12 * .pi
                return P(kx + 28 * cos(a), 1466 + 22 * sin(a))
            } + [P(kx, 1447), P(kx - 26, 1466)])
            b.box(700, 760, top: 1466, bottom: 1500, edge: 708, lit: wallLit, shade: wall, slope: 0)
            b.rect(glow, 716, 1472, 750, 1486)
            // Small lamps along the quay.
            g.setFillColor(cg(dark ? hx(0xFFD48A) : hx(0xFFF0CC)))
            for lx in [112.0, 238, 368, 444, 604, 766, 846, 960] {
                g.fillEllipse(in: CGRect(x: lx - 1.7, y: 1478, width: 3.4, height: 3.4))
            }
            // The sea wall.
            b.rect(dk, -10, 1486, 1010, shore + 4)
            g.setFillColor(cg(edge))
            g.beginPath()
            lens(g, 360, shore - 4, 420, 2)
            lens(g, 800, shore - 4, 280, 2)
            g.fillPath()
        }

        // The water.
        let waterPlate = PosterPlate(c) { g in fillPoly(g, [P(-40, shore), P(1040, shore), P(1040, 2240), P(-40, 2240)]) }
        c.pull(PosterRamp(dark
            ? [(0, hx(0x2A2048)), (0.12, hx(0x18183E)), (0.4, hx(0x0C1230)), (1, hx(0x040818))]
            : [(0, hx(0xE8B4A0)), (0.12, hx(0xC89AA8)), (0.35, hx(0x9084AC)), (0.7, hx(0x5A6498)), (1, hx(0x2F4480))], step: 0.7), plate: waterPlate, amp: 0.05, key: 16) { _, y in Float((y - shore) / 680) }

        // Only the great masses lie in the water, as flat cut plates broken into slivers that come apart toward us. The windows are not in it: the columns of light below carry all of that.
        do {
            let k = 0.52
            // x0, x1, top, and where its lit face ends.
            let masses: [(Double, Double, Double, Double)] = [
                (14, 92, 1010, 34), (104, 222, 894, 140), (196, 340, 1176, 226),
                (298, 462, 1046, 354), (317, 443, 888, 360), (334, 426, 752, 365), (351, 409, 654, 371),
                (434, 576, 1214, 470), (478, 530, 1034, 494), (536, 644, 872, 568),
                (668, 716, 918, 680), (726, 776, 948, 738), (760, 872, 840, 784), (836, 924, 1058, 856), (918, 958, 790, 930)
            ]
            var r = SplitMix64(seed: 0xD10)
            var shadeBars: [[P]] = [], litBars: [[P]] = []
            func bar(_ x0: Double, _ x1: Double, _ y: Double, _ bh: Double) -> [P] {
                let tip = min(bh * 1.1, (x1 - x0) * 0.3)
                return [P(x0, y + bh * 0.55), P(x0 + tip, y), P(x1 - tip, y + bh * 0.1), P(x1, y + bh * 0.5), P(x1 - tip * 0.6, y + bh), P(x0 + tip * 0.4, y + bh * 0.92)]
            }
            for m in masses {
                var y = shore + 4
                let end = shore + (shore - m.2) * k
                while y < end {
                    let d = (y - shore) / 680
                    let u = (y - shore) / max(1, end - shore)
                    let bh = (2 + 5 * d) * r.next(0.5, 1.9)
                    let wob = 1.5 + 16 * d
                    // Near the shore a sliver spans the mass; farther on it is one or two pieces of it, and those fall away.
                    let span = m.1 - m.0
                    let pieces = u < 0.3 ? 1 : (r.next() < 0.5 ? 1 : 2)
                    for q in 0..<pieces {
                        if r.next() < 0.03 + 0.6 * u * u + 0.3 * d { continue }
                        let keep = u < 0.3 ? 1 : r.next(0.34, 0.9) / Double(pieces)
                        let room = span * (1 - keep) / Double(pieces)
                        let a = m.0 + span * Double(q) / Double(pieces) + r.next(0, room) + r.next(-wob, wob)
                        let e = a + span * keep + r.next(-wob, wob) * 0.6
                        if e - a < 60 { continue }
                        shadeBars.append(bar(a, e, y, bh))
                        let litEnd = min(e, m.3 + (a - m.0))
                        if litEnd - a > 14 && u < 0.6 && r.next() > 0.1 + d { litBars.append(bar(a, litEnd, y, bh)) }
                    }
                    y += bh + r.next(0.2, 1.1) + 12 * u * r.next(0, 1)
                }
            }
            let shadeP = PosterPlate(c) { g in for b in shadeBars { fillPoly(g, b) } }
            let litP = PosterPlate(c) { g in for b in litBars { fillPoly(g, b) } }
            c.flat(dark ? hx(0x050920) : hx(0x46396C), plate: shadeP, opacity: dark ? 0.62 : 0.4)
            c.flat(dark ? hx(0x2A2854) : hx(0xF0AE90), plate: litP, opacity: dark ? 0.5 : 0.42)
        }

        // Lights lying on the water in long columns of short marks, widening toward us.
        do {
            var r = SplitMix64(seed: 0xD11)
            let cols: [(x: Double, w: Double, reach: Double)] = dark
                ? [(150, 16, 330), (280, 20, 260), (400, 28, 470), (505, 12, 240), (600, 26, 380), (662, 22, 300), (810, 26, 400), (880, 16, 300), (936, 12, 240)]
                : [(400, 26, 300), (810, 30, 340), (600, 20, 220)]
            let marks = PosterPlate(c) { g in
                g.beginPath()
                for col in cols {
                    var y = shore + 8
                    while y < shore + col.reach {
                        let d = (y - shore) / col.reach
                        let wide = col.w * (0.7 + 1.4 * d)
                        if r.next() < 1 - d * 0.7 {
                            lens(g, col.x + r.next(-wide, wide), y, r.next(10, 44) * (0.6 + 1.4 * d), r.next(1, 2) * (0.7 + 1.4 * d))
                        }
                        y += r.next(5, 10) * (0.7 + 2.0 * d)
                    }
                }
                g.fillPath()
            }
            c.flat(dark ? hx(0xC8904E) : hx(0xFFE6B8), plate: marks, opacity: dark ? 0.66 : 0.74)
            // And plain ripple marks everywhere, the water's own colour, so nothing is ruled.
            let ripple = PosterPlate(c) { g in
                g.beginPath()
                var y = shore + 18
                while y < 2200 {
                    let d = (y - shore) / 680
                    var x = -40 + r.next(0, 90)
                    while x < 1040 {
                        if r.next() < 0.55 { lens(g, x, y + r.next(-3, 3), r.next(30, 150) * (0.5 + 1.5 * d), r.next(1, 1.8) * (0.6 + 2.6 * d)) }
                        x += r.next(70, 240) * (0.6 + 1.3 * d)
                    }
                    y += r.next(12, 26) * (0.7 + 2.4 * d)
                }
                g.fillPath()
            }
            c.flat(dark ? hx(0x060B26) : hx(0x34457E), plate: ripple, opacity: dark ? 0.5 : 0.34)
        }

        // A small working boat out on the water, its lamp lit.
        do {
            let bx = 808.0, by = 1716.0, s = 1.2
            c.paint { g in
                let hull: PosterInk = dark ? hx(0x060A1E) : hx(0x2A2A58), hullLit: PosterInk = dark ? hx(0x1E2044) : hx(0xC45A48), cabin: PosterInk = dark ? hx(0x14163A) : hx(0xF0D0B4), cabinShade: PosterInk = dark ? hx(0x0A0C28) : hx(0x8A6E8C)
                // Mast and rigging.
                fill(g, hull, [P(bx + 6 * s, by - 18 * s), P(bx + 7 * s, by - 76 * s), P(bx + 8.4 * s, by - 76 * s), P(bx + 9 * s, by - 18 * s)])
                // Hull.
                fill(g, hull, [P(bx - 62 * s, by - 14 * s), P(bx + 58 * s, by - 8 * s), P(bx + 44 * s, by + 4 * s), P(bx - 48 * s, by + 4 * s)])
                fill(g, hullLit, [P(bx - 62 * s, by - 14 * s), P(bx + 58 * s, by - 8 * s), P(bx + 56 * s, by - 5.4 * s), P(bx - 58 * s, by - 9.4 * s)])
                // Wheelhouse.
                fill(g, cabinShade, [P(bx - 22 * s, by - 12 * s), P(bx - 22 * s, by - 34 * s), P(bx + 16 * s, by - 34 * s), P(bx + 16 * s, by - 10 * s)])
                fill(g, cabin, [P(bx - 22 * s, by - 12 * s), P(bx - 22 * s, by - 34 * s), P(bx - 8 * s, by - 34 * s), P(bx - 8 * s, by - 12 * s)])
                fill(g, hull, [P(bx - 25 * s, by - 34 * s), P(bx + 19 * s, by - 34 * s), P(bx + 16 * s, by - 38 * s), P(bx - 22 * s, by - 38 * s)])
                fill(g, glow, [P(bx - 4 * s, by - 29 * s), P(bx + 12 * s, by - 29 * s), P(bx + 12 * s, by - 20 * s), P(bx - 4 * s, by - 20 * s)])
                fill(g, hull, [P(bx + 3.4 * s, by - 29 * s), P(bx + 4.6 * s, by - 29 * s), P(bx + 4.6 * s, by - 20 * s), P(bx + 3.4 * s, by - 20 * s)])
            }
            let shadow = PosterPlate(c) { g in
                g.beginPath()
                lens(g, bx, by + 7 * s, 130 * s, 7 * s)
                lens(g, bx - 8, by + 18 * s, 90 * s, 3 * s)
                lens(g, bx + 16, by + 28 * s, 70 * s, 2.4 * s)
                g.fillPath()
            }
            c.flat(dark ? hx(0x03061A) : hx(0x262E68), plate: shadow, opacity: 0.8)
            if dark {
                let spark = PosterPlate(c) { g in
                    g.beginPath()
                    lens(g, bx + 4 * s, by + 12 * s, 26 * s, 1.4 * s)
                    lens(g, bx + 2 * s, by + 21 * s, 18 * s, 1.2 * s)
                    g.fillPath()
                }
                c.flat(hx(0xC8904E), plate: spark, opacity: 0.8)
            }
        }

        // The near pier, coming out from the bottom left toward the city: planks, pilings, one lamp.
        do {
            let y0 = 1900 - lift
            let top: (Double) -> Double = { x in y0 + 44 - (x + 40) * 0.176 }
            let face: (Double) -> Double = { x in 62 - (x + 40) * 0.08 }
            let depth: (Double) -> Double = { x in 30 - (x + 40) * 0.042 }
            let endX = 540.0
            let ink: PosterInk = dark ? hx(0x03061A) : hx(0x1E1E4C), plank: PosterInk = dark ? hx(0x161834) : hx(0x6A5478), litEdge: PosterInk = dark ? hx(0x4A3A58) : hx(0xF0A47E)
            // Marks on the water where the posts stand.
            let feet = PosterPlate(c) { g in
                g.beginPath()
                for (x, h, w): (Double, Double, Double) in [(508, 66, 7), (420, 94, 9), (316, 130, 12), (196, 180, 16)] {
                    lens(g, x + w * 2, top(x) + h, w * 9, 3 + w * 0.2)
                }
                g.fillPath()
            }
            c.flat(dark ? hx(0x03061A) : hx(0x262E68), plate: feet, opacity: 0.7)
            c.paint { g in
                // The deck: the top seen from above, then its long fascia.
                fill(g, plank, [P(-40, top(-40)), P(endX, top(endX)), P(endX, top(endX) - depth(endX)), P(-40, top(-40) - depth(-40))])
                g.setFillColor(cg(ink))
                g.beginPath()
                var x = -30.0
                while x < endX {
                    let t = top(x), dp = depth(x)
                    g.move(to: CGPoint(x: x, y: t))
                    g.addLine(to: CGPoint(x: x + 1.3, y: t))
                    g.addLine(to: CGPoint(x: x + 8 + 1.3, y: t - dp))
                    g.addLine(to: CGPoint(x: x + 8, y: t - dp))
                    g.closePath()
                    x += 8 + (540 - x) * 0.022
                }
                g.fillPath()
                fill(g, ink, [P(-40, top(-40)), P(endX, top(endX)), P(endX, top(endX) + face(endX)), P(-40, top(-40) + face(-40))])
                fill(g, litEdge, [P(-40, top(-40) - 1), P(endX, top(endX) - 0.6), P(endX, top(endX) + 1.6), P(-40, top(-40) + 2.4)])
                // Posts stand in front of the fascia and rise above it.
                for (x, h, w): (Double, Double, Double) in [(508, 66, 7), (420, 94, 9), (316, 130, 12), (196, 180, 16), (60, 270, 22)] {
                    let t = top(x) - w * 1.2
                    fill(g, ink, [P(x - w, t + 2), P(x - w * 0.5, t - 2), P(x + w * 0.5, t - 2), P(x + w, t + 2), P(x + w * 1.06, top(x) + h), P(x - w * 1.06, top(x) + h)])
                    fill(g, plank, [P(x - w, t + 2), P(x - w * 0.5, t - 2), P(x - w * 0.2, t - 2), P(x - w * 0.34, top(x) + h), P(x - w * 1.06, top(x) + h)])
                    fill(g, litEdge, [P(x - w, t + 2), P(x - w * 0.5, t - 2), P(x + w * 0.5, t - 2), P(x + w, t + 2), P(x + w * 0.5, t + 0.6), P(x - w * 0.5, t + 0.6)])
                }
                // The rail along the back edge.
                let railX: [Double] = [-20, 48, 112, 168, 218, 262, 300]
                let rh: (Double) -> Double = { x in 74 - (x + 40) * 0.092 }
                func back(_ x: Double) -> Double { top(x) - depth(x) }
                for rx in railX {
                    let w = 1.6 + (300 - rx) * 0.004
                    fill(g, ink, [P(rx - w, back(rx)), P(rx + w, back(rx)), P(rx + w, back(rx) - rh(rx)), P(rx - w, back(rx) - rh(rx))])
                }
                let rail = { (u: Double) -> [P] in
                    [P(-40, back(-40) - rh(-40) * u), P(300, back(300) - rh(300) * u), P(300, back(300) - rh(300) * u + 2), P(-40, back(-40) - rh(-40) * u + 4)]
                }
                fill(g, ink, rail(1))
                fill(g, ink, rail(0.55))
                // The lamp.
                let lx = 132.0, ly = back(132)
                let pole = 286.0
                fill(g, ink, [P(lx - 7, ly + 2), P(lx - 3.4, ly - 30), P(lx - 2, ly - pole), P(lx + 2, ly - pole), P(lx + 3.4, ly - 30), P(lx + 7, ly + 2)])
                fill(g, ink, [P(lx - 8, ly - pole), P(lx + 8, ly - pole), P(lx + 6, ly - pole - 6), P(lx - 6, ly - pole - 6)])
                fill(g, ink, [P(lx - 14, ly - pole + 34), P(lx + 14, ly - pole + 34), P(lx + 14, ly - pole + 37), P(lx - 14, ly - pole + 37)])
                fill(g, dark ? hx(0xFFD48A) : hx(0xFFEEC8), [P(lx - 8, ly - pole - 6), P(lx + 8, ly - pole - 6), P(lx + 11, ly - pole - 32), P(lx - 11, ly - pole - 32)])
                fill(g, ink, [P(lx - 0.9, ly - pole - 6), P(lx + 0.9, ly - pole - 6), P(lx + 1.2, ly - pole - 32), P(lx - 1.2, ly - pole - 32)])
                fill(g, ink, [P(lx - 14, ly - pole - 32), P(lx + 14, ly - pole - 32), P(lx + 2, ly - pole - 46), P(lx - 2, ly - pole - 46)])
                fill(g, ink, [P(lx - 1, ly - pole - 46), P(lx + 1, ly - pole - 46), P(lx + 0.5, ly - pole - 56), P(lx - 0.5, ly - pole - 56)])
            }
            // A low soft ring of air around the lamp, in grain: no rays.
            let lampX = 132.0, lampY = top(132) - depth(132) - 286 - 19
            c.stipple(dark ? hx(0xA87448) : hx(0xFFE8C0), rows: (c.row(lampY - 70), c.row(lampY + 70)), key: 44, opacity: dark ? 0.4 : 0.34, grainMix: 0.3) { x, y in
                let dx = (x - lampX) / 68, dy = (y - lampY) / 68
                let d = dx * dx + dy * dy
                return d > 1 ? 0 : Float((1 - d) * (1 - d)) * 0.6
            }
            // The near bank closes the frame.
            var r = SplitMix64(seed: 505)
            let shelf = [P(-40, y0 + 134), P(100, y0 + 156), P(240, y0 + 194), P(420, y0 + 230), P(620, y0 + 250), P(820, y0 + 244), P(1040, y0 + 206)]
            PosterForeground.ledge(c, line: shelf, foot: 2168, deep: dark ? hx(0x03061A) : hx(0x1E1E4C), ledge: dark ? hx(0x10122C) : hx(0x4C3F6E), rim: dark ? hx(0x3C2C4C) : hx(0xD08A78), ledges: 40, reach: 90, rng: &r)
        }

        c.finish(seed: 0xC17, tooth: 0.05, mottle: 0.018, pinholes: dark ? 0.06 : 0.16, paper: hx(0xFFF3DC))
    }
}
