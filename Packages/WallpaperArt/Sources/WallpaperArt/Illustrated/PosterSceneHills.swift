// Rolling farmland at the end of the day: three big hills laid over each other, sage, olive and ochre, the sun very low on the right,
// so everything that stands up throws a long cut shadow to the left. One farmhouse, one oak. Design space x 0...1000, y 0...2168.

import CoreGraphics
import Foundation

private typealias P = PosterP

/// One hill: a crest line read from a table, and the way down its face. `v` is 0 on the crest and 1 a full `depth` below it.
nonisolated private final class HillsShape: @unchecked Sendable {
    let table: [Double]
    let depth: Double

    init(_ crest: [P], depth: Double) {
        self.depth = depth
        table = stride(from: -80.0, through: 1080.0, by: 2.0).map { Poster.curveY(crest, $0) }
    }

    func y(_ x: Double) -> Double {
        let u = max(0, min(Double(table.count) - 1.001, (x + 80) / 2))
        let i = Int(u)
        return table[i] + (table[i + 1] - table[i]) * (u - Double(i))
    }

    func v(_ x: Double, _ y: Double) -> Double { (y - self.y(x)) / depth }
    func at(_ x: Double, _ v: Double) -> P { P(x, y(x) + depth * v) }
    var top: [P] { stride(from: -60.0, through: 1060.0, by: 8.0).map { P($0, y($0)) } }
    var outline: [P] { top + [P(1060, 2300), P(-60, 2300)] }
}

/// A shadow lying on a hill: from `root` (toward the sun) out to a point at `tip`, following the fall of the ground. `v0` is the middle of it in `v`, `spread` how far it creeps down.
nonisolated private func hillsCast(_ h: HillsShape, root: Double, tip: Double, v0: Double, spread: Double, wide: Double, swell: Double = 0.45) -> [P] {
    var up: [P] = [], down: [P] = []
    let n = 44
    for i in 0...n {
        let u = Double(i) / Double(n)
        let x = root + (tip - root) * u
        // Widest a little way out from the root, then a long taper to a point.
        let env = pow(sin(.pi * pow(u, swell)), 1.25)
        let mid = v0 + spread * u
        up.append(h.at(x, mid - wide * 0.42 * env))
        down.append(h.at(x, mid + wide * 0.58 * env))
    }
    return up + down.reversed()
}

/// A wood seen from afar: one cut mass with an uneven top, never a row of beads, lit along the edge toward the sun.
nonisolated private func hillsWood(_ g: CGContext, h: HillsShape, x0: Double, x1: Double, v: Double, tall: Double, body: PosterInk, lit: PosterInk, rng: inout SplitMix64) {
    let p1 = rng.next(0, 6), p2 = rng.next(0, 6), p3 = rng.next(0, 6)
    let l1 = tall * rng.next(1.5, 1.9), l2 = tall * rng.next(0.62, 0.8), l3 = tall * rng.next(0.27, 0.34)
    var line: [P] = []
    var x = x0
    let step = max(1.5, tall / 16)
    while x <= x1 {
        let u = (x - x0) / (x1 - x0)
        let env = pow(sin(.pi * u), 0.42)
        let hump = 0.46 + 0.34 * abs(sin(x / l1 + p1)) + 0.14 * abs(sin(x / l2 + p2)) + 0.07 * abs(sin(x / l3 + p3))
        line.append(P(x, h.at(x, v).y - tall * env * hump))
        x += step
    }
    let under = stride(from: x1, through: x0, by: -8.0).map { P($0, h.at($0, v).y + tall * 0.12) }
    let shape = line + under
    Poster.fill(g, lit, shape)
    g.saveGState()
    g.beginPath()
    Poster.poly(g, shape)
    g.clip()
    Poster.fill(g, body, shape.map { P($0.x - tall * 0.09, $0.y + tall * 0.1) })
    g.restoreGState()
}

/// A single far tree: a trunk, a loose crown of a few overlapping puffs, each lit on the side the sun is on.
nonisolated private func hillsTree(_ g: CGContext, x: Double, y: Double, r: Double, body: PosterInk, mid: PosterInk, lit: PosterInk, trunk: PosterInk, rng: inout SplitMix64) {
    let cy = y - r * 1.05
    Poster.fill(g, trunk, [P(x - r * 0.1, y), P(x - r * 0.07, cy), P(x + r * 0.07, cy), P(x + r * 0.1, y)])
    let n = 6
    var puffs: [(Double, Double, Double)] = [(0, -0.1, 0.74)]
    for i in 0..<n {
        let a = Double(i) / Double(n) * 2 * .pi + rng.next(-0.3, 0.3)
        puffs.append((cos(a) * 0.54 * rng.next(0.85, 1.1), sin(a) * 0.46 * rng.next(0.85, 1.1), rng.next(0.4, 0.56)))
    }
    g.setFillColor(Poster.cg(body))
    for p in puffs { g.fillEllipse(in: CGRect(x: x + p.0 * r - p.2 * r, y: cy + p.1 * r - p.2 * r, width: 2 * p.2 * r, height: 2 * p.2 * r)) }
    g.setFillColor(Poster.cg(mid))
    for p in puffs where p.0 - p.1 > -0.3 {
        let s = p.2 * 0.76
        g.fillEllipse(in: CGRect(x: x + (p.0 + 0.13) * r - s * r, y: cy + (p.1 - 0.15) * r - s * r, width: 2 * s * r, height: 2 * s * r))
    }
    g.setFillColor(Poster.cg(lit))
    for p in puffs where p.0 - p.1 > 0.1 {
        let s = p.2 * 0.46
        g.fillEllipse(in: CGRect(x: x + (p.0 + 0.22) * r - s * r, y: cy + (p.1 - 0.22) * r - s * r, width: 2 * s * r, height: 2 * s * r))
    }
}

nonisolated extension Poster {
    static func rollingHills(_ c: PosterCanvas, dark: Bool) {
        let lift = max(0, 2168 - c.bottomY) * 0.86
        var rng = SplitMix64(seed: 0x4111)
        let sun = P(1120, 1190)

        // The sky: an even wash from a dusty green-blue down to straw, warmer toward the sun. At night a mossy black with a little of the day left low on the right.
        let skyRamp = PosterRamp(dark
            ? [(0, hx(0x060E10)), (0.3, hx(0x0A1616)), (0.56, hx(0x10211E)), (0.78, hx(0x1A3028)), (0.92, hx(0x2A4232)), (1, hx(0x3E563C))]
            : [(0, hx(0x3A6C78)), (0.24, hx(0x5F9090)), (0.46, hx(0x97B5A0)), (0.66, hx(0xCFD3A8)), (0.84, hx(0xF2DFA6)), (1, hx(0xF9CF8E))], step: 1)
        c.pull(skyRamp, amp: dark ? 0.03 : 0.042, key: 1, rows: (0, c.row(1420))) { x, y in
            let d = hypot(x - sun.x, (y - sun.y) * 1.3)
            return Float((y - 120) / 1130 + (dark ? 0.1 : 0.24) * exp(-d / 460) - 0.04)
        }
        if dark {
            PosterSky.stars2(c, until: 900, bright: [(164, 214, 2.2), (560, 96, 1.6), (818, 372, 2.4), (372, 560, 1.7)], dots: hx(0xB8C4B4), big: hx(0xEEE8D2), count: 380, seed: 83)
        }

        // One big fair-weather cloud low on the left, its bright side to the sun, sitting behind the first hill.
        let sunL = PosterLight(0.74, -0.42, 0.52)
        let lx = sunL.x, ly = sunL.y
        let gi = 1 / (lx * lx + ly * ly).squareRoot()
        let cloudRamp = PosterRamp(dark
            ? [(0, hx(0x0C1818)), (0.3, hx(0x101E1D)), (0.58, hx(0x162824)), (0.84, hx(0x1E342C)), (1, hx(0x2C4436))]
            : [(0, hx(0x7A9C96)), (0.26, hx(0xA2B7A4)), (0.5, hx(0xD5D2AE)), (0.72, hx(0xF7E6BC)), (1, hx(0xFFFBEA))], step: 0.5)
        let shade: (Double, Double, Float, Float, Float, PosterBillow) -> Float = { x, y, ndl, form, _, b in
            let size = Float(b.ry / b.mry)
            let dxn = Float((x - b.x) / b.rx), dyn = Float((y - b.y) / b.ry)
            let away = -(dxn * lx + dyn * ly)
            let merge = 1 - sstep(0.0, 0.92, away)
            let fx = Float((x - b.mx) / b.mrx), fy = Float((y - b.my) / b.mry)
            let graze = (fx * lx + fy * ly) * gi
            let a = (0.1 + 0.3 * sstep(0.06, 0.4, size))
            let f = 0.7 * graze + 0.3 * form + a * (ndl - 0.55) * merge
            return 0.08 + sstep(-0.42, 0.66, f) * 0.92
        }
        var heap: [PosterBillow] = []
        for m: (x: Double, y: Double, rx: Double, ry: Double, inner: Int) in [
            (390, 1092, 96, 60, 7), (284, 1012, 130, 100, 9), (150, 916, 150, 130, 10), (10, 1006, 150, 110, 8), (210, 1114, 240, 66, 10)
        ] { crownHeap(&heap, x: m.x, y: m.y, rx: m.rx, ry: m.ry, inner: m.inner, rng: &rng) }
        c.billows(heap, ramp: cloudRamp, amp: 0.03, key: 14, light: sunL, base: { x in 1172 + 5 * sin(x / 70) + 3 * sin(x / 23) }, shade: shade)

        // The land's inks, far to near. Each hill has its own hue, and a tone runs down it from the lit crest into the valley.
        let hA = HillsShape([P(-60, 1262), P(80, 1216), P(240, 1192), P(420, 1218), P(620, 1284), P(820, 1336), P(1060, 1372)], depth: 430)
        let hB = HillsShape([P(-60, 1568), P(140, 1506), P(360, 1424), P(560, 1356), P(742, 1326), P(890, 1346), P(1060, 1402)], depth: 560)
        let hC = HillsShape([P(-60, 1716), P(120, 1650), P(300, 1622), P(500, 1656), P(700, 1726), P(880, 1784), P(1060, 1812)], depth: 620)

        // Far away, one low blue-green step of land.
        do {
            let far = PosterPlate(c) { g in
                fillPoly(g, PosterCut.wavyBand(y: 1218, tilt: 0.03, waves: [(9, 150, 1.6), (4, 61, 0.3)], floorY: 1500))
            }
            c.flat(dark ? hx(0x243E38) : hx(0xB9CBA2), plate: far)
        }

        // The ground's grain and how it takes the light: `lateral` warms toward the sun, stripes lie along the hill.
        struct Field { let x0: Double, x1: Double, fan: Double, count: Double, strength: Float, shift: Float }
        func stripes(_ fields: [Field], _ x: Double, _ v: Double, phase: Double) -> Float {
            for f in fields {
                let bend = 18 * sin(v * 3.3 + f.x0 / 90)
                let a = f.x0 + (f.x0 - 500) * f.fan * v + bend, b = f.x1 + (f.x1 - 500) * f.fan * v + bend
                if x >= a && x < b {
                    if f.count <= 0 { return f.shift }
                    // Rows bunch up toward the crest and open out toward us; they bow a little, like anything laid by a plough.
                    let w = v + 0.008 * sin(x / 97 + phase) + 0.004 * sin(x / 31 + phase * 2)
                    let u = pow(max(0, w), 0.72) * f.count
                    return f.shift + ((u - u.rounded(.down)) < 0.5 ? f.strength : -f.strength)
                }
            }
            return 0
        }

        let airA: PosterInk = dark ? hx(0x2A443A) : hx(0xEEDCA4)
        let rampA = PosterRamp(dark
            ? [(0, hx(0x3C5848)), (0.2, hx(0x2E4A3E)), (0.5, hx(0x223A32)), (0.8, hx(0x1A2E2A)), (1, hx(0x142420))]
            : [(0, hx(0xDFD9A0)), (0.16, hx(0xBFC794)), (0.42, hx(0x9DB388)), (0.7, hx(0x7E9C7C)), (1, hx(0x658672))], step: 0.6)
        let rampB = PosterRamp(dark
            ? [(0, hx(0x3E5A3A)), (0.18, hx(0x2E4832)), (0.5, hx(0x1E3226)), (0.8, hx(0x14241C)), (1, hx(0x0E1A16))]
            : [(0, hx(0xC7B95C)), (0.16, hx(0xA3A04A)), (0.42, hx(0x7F8840)), (0.7, hx(0x5F6E38)), (1, hx(0x465732))], step: 0.6)
        let rampC = PosterRamp(dark
            ? [(0, hx(0x565230)), (0.14, hx(0x403E26)), (0.46, hx(0x2A281A)), (0.8, hx(0x181A12)), (1, hx(0x0E100C))]
            : [(0, hx(0xF8DE98)), (0.14, hx(0xEEC56C)), (0.4, hx(0xD9A148)), (0.7, hx(0xB77E38)), (1, hx(0x8C5C30))], step: 0.6)

        let fieldsA = [Field(x0: -400, x1: 1500, fan: 0, count: 0, strength: 0, shift: 0)]
        let fieldsB = [Field(x0: -400, x1: 1500, fan: 0, count: 9, strength: 0.03, shift: 0)]
        let fieldsC = [Field(x0: -400, x1: 1500, fan: 0, count: 9, strength: 0.024, shift: 0)]

        func hill(_ h: HillsShape, ramp: PosterRamp, fields: [Field], key: Int, rowsPhase: Double, lean: Float) -> PosterPlate {
            let plate = PosterPlate(c) { g in fillPoly(g, h.outline) }
            c.pull(ramp, plate: plate, amp: 0.05, key: key) { x, y in
                let v = h.v(x, y)
                let tone = Float(0.08 + 0.92 * pow(max(0, v), 0.82)) - lean * Float((x - 500) / 1000)
                return tone + stripes(fields, x, v, phase: rowsPhase)
            }
            return plate
        }

        // The tapered lit pieces of a crest. Thick on the side that faces the sun, gone on the side that doesn't.
        func rim(_ h: HillsShape, from x0: Double, to x1: Double, ink: PosterInk, opacity: Double, thick: Double, seed: UInt64) {
            var r = SplitMix64(seed: seed)
            let p = PosterPlate(c) { g in
                var x = x0
                while x < x1 {
                    let span = r.next(70, 260)
                    let th = thick * r.next(0.7, 1.2) * (0.3 + 0.7 * dsstep(x0, x1, x + span * 0.5))
                    var upper: [P] = [], under: [P] = []
                    for i in 0...14 {
                        let u = Double(i) / 14
                        let px = x + span * u
                        upper.append(P(px, h.y(px) - 0.4))
                        under.append(P(px, h.y(px) + th * pow(sin(.pi * u), 0.8)))
                    }
                    fillPoly(g, upper + under.reversed())
                    x += span + r.next(16, 110)
                }
            }
            c.flat(ink, plate: p, opacity: opacity)
        }

        // Plough lines along a hill, on the same rows as its stripes: long tapered cuts that follow the crest, broken now and then, never a ruled wire.
        func furrows(_ h: HillsShape, x0: Double, x1: Double, rows count: Double, from: Int, to: Int, phase: Double, thick: Double, ink: PosterInk, opacity: Double, mask: PosterPlate, seed: UInt64) {
            var r = SplitMix64(seed: seed)
            let p = PosterPlate(c) { g in
                for k in from...to {
                    let v0 = pow(Double(k) / count, 1 / 0.72)
                    var x = x0 - r.next(0, 120)
                    while x < x1 {
                        let span = r.next(160, 520) * (0.6 + v0)
                        let th = thick * r.next(0.7, 1.15) * (0.4 + 2.2 * v0)
                        var upper: [P] = [], under: [P] = []
                        for i in 0...16 {
                            let u = Double(i) / 16
                            let px = x + span * u
                            let v = v0 - 0.008 * sin(px / 97 + phase) - 0.004 * sin(px / 31 + phase * 2)
                            let q = h.at(px, v)
                            upper.append(q)
                            under.append(P(q.x, q.y + th * pow(sin(.pi * u), 0.5)))
                        }
                        fillPoly(g, upper + under.reversed())
                        x += span + r.next(4, 26) * (0.5 + v0)
                    }
                }
            }
            p.intersect(mask)
            c.flat(ink, plate: p, opacity: opacity)
        }

        // Hazy air gathers in the valley behind a hill, so the next one stands clear of it.
        func valleyAir(_ on: HillsShape, next: HillsShape, ink: PosterInk, rise: Double, amount: Float, mask: PosterPlate, key: Int) {
            c.stipple(ink, plate: mask, rows: (mask.firstRow, c.row(1900)), key: key, grainMix: 0.1) { x, y in
                let foot = next.y(x)
                if y > foot + 4 { return 0 }
                return amount * Float(dsstep(foot - rise, foot, y))
            }
        }

        // The first hill.
        let shadowA: PosterInk = dark ? hx(0x0C1816) : hx(0x4F7770)
        let maskA = hill(hA, ramp: rampA, fields: fieldsA, key: 20, rowsPhase: 0.7, lean: 0.12)
        do {
            // A wood on its far shoulder and its shadow, and the shadow the middle hill throws over its lower flank.
            let woodBody: PosterInk = dark ? hx(0x0E1C1A) : hx(0x4E6F60), woodLit: PosterInk = dark ? hx(0x22362E) : hx(0xBAB880)
            let cast = PosterPlate(c) { g in
                fillPoly(g, hillsCast(hA, root: 900, tip: 300, v0: 0.04, spread: 0.1, wide: 0.1))
                fillPoly(g, hillsCast(hA, root: 600, tip: 40, v0: 0.48, spread: 0.26, wide: 0.46, swell: 0.6))
            }
            cast.intersect(maskA)
            c.flat(shadowA, plate: cast, opacity: dark ? 0.6 : 0.5)
            var r = SplitMix64(seed: 0x11)
            c.paint { g in hillsWood(g, h: hA, x0: 770, x1: 1090, v: 0.02, tall: 44, body: woodBody, lit: woodLit, rng: &r) }
        }
        rim(hA, from: 260, to: 1040, ink: dark ? hx(0x6C8C6E) : hx(0xFFF3C0), opacity: dark ? 0.7 : 0.8, thick: 3.2, seed: 0x71)
        valleyAir(hA, next: hB, ink: airA, rise: 150, amount: dark ? 0.26 : 0.34, mask: maskA, key: 21)

        // The middle hill, with the farm on its long rising back.
        let maskB = hill(hB, ramp: rampB, fields: fieldsB, key: 22, rowsPhase: 1.9, lean: 0.14)
        let houseX = 486.0, barnX = 352.0, farmV = 0.062
        let houseY = hB.at(houseX, farmV).y, barnY = hB.at(barnX, farmV).y
        do {
            let cast = PosterPlate(c) { g in
                // The farm's own long shadows, and two broad folds of the ground where the hill turns away.
                fillPoly(g, hillsCast(hB, root: houseX + 46, tip: houseX - 300, v0: farmV + 0.004, spread: 0.1, wide: 0.05))
                fillPoly(g, hillsCast(hB, root: barnX + 40, tip: barnX - 300, v0: farmV + 0.004, spread: 0.12, wide: 0.05))
                fillPoly(g, hillsCast(hB, root: 900, tip: 130, v0: 0.42, spread: 0.2, wide: 0.28, swell: 0.55))
            }
            cast.intersect(maskB)
            c.flat(dark ? hx(0x070E0C) : hx(0x34452C), plate: cast, opacity: dark ? 0.62 : 0.56)
        }
        furrows(hB, x0: -40, x1: 1040, rows: 9, from: 1, to: 6, phase: 1.9, thick: 1.0, ink: dark ? hx(0x0A1412) : hx(0x46552C), opacity: 0.55, mask: maskB, seed: 0x72)
        rim(hB, from: 500, to: 1040, ink: dark ? hx(0x688A56) : hx(0xFFEEA8), opacity: dark ? 0.8 : 0.85, thick: 4.2, seed: 0x73)

        // The farm: a house with its gable to the sun, a barn lower down the slope, trees on the crest behind them.
        do {
            let wall: PosterInk = dark ? hx(0x3E4034) : hx(0xFFF2CC), wallShade: PosterInk = dark ? hx(0x181E1A) : hx(0x8E8E66)
            let roof: PosterInk = dark ? hx(0x30221C) : hx(0xB6482A), roofShade: PosterInk = dark ? hx(0x161412) : hx(0x7C2E22)
            let barn: PosterInk = dark ? hx(0x1C1618) : hx(0x8E3A26), barnLit: PosterInk = dark ? hx(0x342420) : hx(0xC85A32)
            let glass: PosterInk = dark ? hx(0xFFD27E) : hx(0x38402C)
            let treeBody: PosterInk = dark ? hx(0x0A1412) : hx(0x34452C), treeMid: PosterInk = dark ? hx(0x12201A) : hx(0x566A32), treeLit: PosterInk = dark ? hx(0x26382C) : hx(0xC0B458), trunk: PosterInk = dark ? hx(0x080E0C) : hx(0x2C3226)
            if dark {
                // Lamplight on the ground, falling away grain by grain.
                let pools: [(x: Double, y: Double, a: Double, b: Double, d: Float)] = [(houseX - 2, houseY + 22, 150, 40, 0.8), (barnX + 62, barnY + 16, 90, 26, 0.5)]
                let lamp = PosterPlate(c) { g in fillPoly(g, hB.outline) }
                c.stipple(hx(0x8F7038), plate: lamp, rows: (c.row(houseY - 40), c.row(barnY + 120)), key: 47, grainMix: 0.18) { x, y in
                    var dens: Float = 0
                    for p in pools {
                        let dx = (x - p.x) / p.a, dy = (y - p.y) / p.b
                        dens = max(dens, p.d * Float(exp(-(dx * dx + dy * dy))))
                    }
                    return dens * 0.5
                }
            }
            var r = SplitMix64(seed: 0x99)
            c.paint { g in
                // Behind, on the crest.
                for (x, tall): (Double, Double) in [(402, 30), (442, 36), (548, 28), (572, 22)] {
                    hillsTree(g, x: x, y: hB.y(x) + 4, r: tall, body: treeBody, mid: treeMid, lit: treeLit, trunk: trunk, rng: &r)
                }
                // The barn: a plain long block, roof and wall.
                let bx = barnX - 52, by = barnY + 2
                fill(g, barn, [P(bx, by), P(bx, by - 28), P(bx + 72, by - 30), P(bx + 72, by - 2)])
                fill(g, roofShade, [P(bx - 3, by - 28), P(bx + 12, by - 50), P(bx + 76, by - 53), P(bx + 74, by - 30)])
                fill(g, barnLit, [P(bx + 72, by - 2), P(bx + 72, by - 30), P(bx + 88, by - 52), P(bx + 104, by - 32), P(bx + 104, by - 4)])
                fill(g, roof, [P(bx + 12, by - 50), P(bx + 76, by - 53), P(bx + 88, by - 55), P(bx + 24, by - 52)])
                // The house: a side in shade, a gable to the sun.
                let hx0 = houseX - 40, hy = houseY + 2, hx1 = houseX + 20, hx2 = houseX + 50
                fill(g, wallShade, [P(hx0, hy + 8), P(hx0, hy - 24), P(hx1, hy - 29), P(hx1, hy + 1)])
                fill(g, wall, [P(hx1, hy + 1), P(hx1, hy - 29), P((hx1 + hx2) / 2, hy - 50), P(hx2, hy - 31), P(hx2, hy - 4)])
                fill(g, roof, [P(hx0 - 4, hy - 22), P(hx0 + 9, hy - 45), P((hx1 + hx2) / 2, hy - 52), P(hx1 - 2, hy - 28)])
                fill(g, roofShade, [P(hx1 - 2, hy - 28), P((hx1 + hx2) / 2, hy - 52), P((hx1 + hx2) / 2 + 2, hy - 49), P(hx1 + 2, hy - 26)])
                fill(g, dark ? hx(0x121614) : hx(0x4C3A30), [P(hx0 + 16, hy - 54), P(hx0 + 25, hy - 55), P(hx0 + 25, hy - 38), P(hx0 + 16, hy - 37)])
                // Windows: lit at night, the only warm thing there is.
                for (a, b, d, e): (Double, Double, Double, Double) in [(hx0 + 9, hy - 18, hx0 + 19, hy - 5), (hx0 + 30, hy - 20, hx0 + 40, hy - 7), (hx1 + 10, hy - 22, hx1 + 20, hy - 8), (hx1 + 12, hy - 37, hx1 + 18, hy - 29)] {
                    fill(g, glass, [P(a, b), P(d, b), P(d, e), P(a, e)])
                }
                if dark { fill(g, hx(0xE9AC58), [P(bx + 82, by - 22), P(bx + 94, by - 22), P(bx + 94, by - 4), P(bx + 82, by - 3)]) }
            }
        }
        valleyAir(hB, next: hC, ink: dark ? hx(0x263822) : hx(0xE8CE80), rise: 170, amount: dark ? 0.22 : 0.3, mask: maskB, key: 23)

        // The near hill, ochre, the big warm shape of the picture.
        let maskC = hill(hC, ramp: rampC, fields: fieldsC, key: 24, rowsPhase: 3.1, lean: 0.1)
        furrows(hC, x0: -40, x1: 1040, rows: 9, from: 1, to: 8, phase: 3.1, thick: 1.3, ink: dark ? hx(0x0A0C08) : hx(0x9A6A30), opacity: dark ? 0.6 : 0.55, mask: maskC, seed: 0x74)
        let oakX = 708.0, oakV = 0.03, oakY = hC.at(oakX, oakV).y
        do {
            // The oak's shadow, the longest thing in the picture: a thin trunk line, then the crown laid out on the ground, far off to the left and down the hill.
            let cast = PosterPlate(c) { g in
                let len = 520.0
                func ground(_ s: Double) -> P { hC.at(oakX - len * s, oakV + 0.012 + 0.2 * s) }
                var up: [P] = [], dn: [P] = []
                for i in 0...16 {
                    let s = Double(i) / 16 * 0.52
                    let q = ground(s)
                    up.append(P(q.x, q.y - 4 - 6 * s))
                    dn.append(P(q.x, q.y + 4 + 8 * s))
                }
                fillPoly(g, up + dn.reversed())
                var r = SplitMix64(seed: 0x51)
                for (s, a, b): (Double, Double, Double) in [(0.52, 60, 12), (0.6, 84, 19), (0.7, 104, 25), (0.8, 116, 28), (0.9, 110, 26), (0.99, 84, 19), (1.06, 44, 9), (0.66, 62, 14), (0.86, 72, 18)] {
                    let q = ground(s)
                    let n = 30
                    let pts: [P] = (0..<n).map { (i: Int) -> P in
                        let t = Double(i) / Double(n) * 2 * .pi
                        let k = 1 + 0.08 * sin(t * 5 + s * 20) + 0.04 * r.next(-1, 1)
                        return P(q.x + cos(t) * a * k, q.y + sin(t) * b * k)
                    }
                    fillPoly(g, pts)
                }
            }
            cast.intersect(maskC)
            c.flat(dark ? hx(0x040604) : hx(0x6E4628), plate: cast, opacity: dark ? 0.7 : 0.66)
        }
        rim(hC, from: 340, to: 1040, ink: dark ? hx(0x7C7848) : hx(0xFFF0BC), opacity: dark ? 0.8 : 0.9, thick: 5, seed: 0x75)

        // The oak.
        do {
            let trunkInk: PosterInk = dark ? hx(0x050806) : hx(0x2E2A1E), trunkLit: PosterInk = dark ? hx(0x20261C) : hx(0xC2A258)
            let s = 0.82
            func o(_ dx: Double, _ dy: Double) -> P { P(oakX + dx * s, oakY + dy * s) }
            c.paint { g in
                fill(g, trunkInk, [o(-54, 16), o(-30, -6), o(-24, -70), o(-58, -150), o(-40, -158), o(-8, -104), o(-18, -190), o(10, -190), o(16, -108), o(58, -160), o(76, -148), o(28, -60), o(32, -6), o(60, 16), o(4, 8)])
                fill(g, trunkLit, [o(60, 16), o(32, -6), o(28, -60), o(76, -148), o(66, -154), o(18, -64), o(20, -8), o(36, 14)])
            }
            var r = SplitMix64(seed: 0x0A5)
            var oak: [PosterBillow] = []
            for m: (x: Double, y: Double, rx: Double, ry: Double, inner: Int) in [
                (40, -310, 110, 66, 6), (-90, -330, 110, 66, 6), (-190, -270, 90, 54, 6),
                (90, -230, 100, 62, 6), (-30, -245, 120, 72, 7), (-150, -200, 110, 62, 6), (-250, -190, 70, 42, 5),
                (60, -150, 110, 50, 6), (-70, -152, 120, 50, 6), (-190, -138, 90, 36, 5)
            ] { crownHeap(&oak, x: oakX + m.x * s + 36, y: oakY + m.y * s, rx: m.rx * s, ry: m.ry * s, inner: m.inner, rng: &r) }
            let oakRamp = PosterRamp(dark
                ? [(0, hx(0x060A08)), (0.42, hx(0x0C1610)), (0.74, hx(0x1A2A1A)), (1, hx(0x40522E))]
                : [(0, hx(0x2A321E)), (0.32, hx(0x3F4C24)), (0.58, hx(0x626E2C)), (0.82, hx(0x9D9A3E)), (1, hx(0xE3C664))], step: 0.5)
            let top = oakY - 400 * s, tall = 330 * s
            let oakShade: (Double, Double, Float, Float, Float, PosterBillow) -> Float = { x, y, ndl, form, tt, b in
                let v = shade(x, y, ndl, form, tt, b)
                let down = sstep(0.1, 1, Float((y - top) / tall))
                let across = 1 - sstep(Float(oakX - 220), Float(oakX + 160), Float(x))
                return v * (1 - 0.5 * down) * (1 - 0.34 * across)
            }
            c.billows(oak, ramp: oakRamp, amp: 0.05, key: 17, light: sunL, base: { x in oakY - 92 * s + 14 * sin(x / 34) + 8 * sin(x / 13) }, shade: oakShade)
        }

        // The foot: a bank of ground already in the evening's shade, rising to the right.
        var r3 = SplitMix64(seed: 509)
        let bank = [P(-40, 2062), P(120, 2050), P(300, 2022), P(470, 1996), P(640, 1952), P(800, 1908), P(930, 1878), P(1040, 1860)].map { P($0.x, $0.y - lift) }
        PosterForeground.ledge(c, line: bank, foot: 2168, deep: dark ? hx(0x040705) : hx(0x2A2C1A), ledge: dark ? hx(0x10160E) : hx(0x5C5A2C), rim: dark ? hx(0x3C4630) : hx(0xF2C872), ledges: 70, reach: 130, rng: &r3)

        c.finish(seed: 0x4111, tooth: 0.05, mottle: 0.018, pinholes: dark ? 0.06 : 0.16, paper: hx(0xFFF3DC))
    }
}

