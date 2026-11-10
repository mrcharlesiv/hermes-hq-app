// Golden peaks in the last sun, a meadow running toward us, a stream winding through it. At night: silver snow under stars, the stream a thin bright line, no moon.

import Foundation
import simd

nonisolated enum PaintPeaksScene {
    static func scene(width: Int, height: Int, dark: Bool) -> PaintSceneRef {
        let w = min(width, 590)
        let h = Int((Float(height) * Float(w) / Float(width)).rounded())
        let ref = PaintSceneRef(w: w, h: h)
        ref.dark = dark
        ref.ground = dark ? PaintHex(18, 24, 36) : PaintHex(150, 120, 74)
        let unitPx = Float(w)
        let aspect = Float(height) / Float(width)
        let size = min(1, pow(aspect / 2.168, 0.6))
        let meadowTop = aspect * 0.515
        let summitV = aspect * 0.196
        let scaleV = aspect / 2.168
        // The light comes from the left, so this range never repeats the lake's.
        let sun = simd_normalize(dark ? PaintV3(-0.80, 0.42, 0.42) : PaintV3(-0.76, 0.38, 0.52))
        ref.lightDir = simd_normalize(SIMD2<Float>(sun.x, -sun.y))

        let nightStops: [(Float, PaintV3)] = [(0, PaintHex(6, 9, 22)), (0.45, PaintHex(9, 15, 34)), (0.82, PaintHex(16, 26, 52)), (1, PaintHex(30, 42, 70))]
        let dayStops: [(Float, PaintV3)] = [(0, PaintHex(52, 96, 154)), (0.42, PaintHex(96, 146, 188)), (0.72, PaintHex(204, 208, 192)), (0.90, PaintHex(248, 208, 152)), (1, PaintHex(250, 190, 130))]
        let sky = PaintGradient(stops: dark ? nightStops : dayStops)
        let look = dark
            ? PaintMassifLook(sun: sun, snowLit: PaintHex(132, 146, 174), snowGlow: PaintHex(82, 94, 126), snowShade: PaintHex(26, 34, 60), snowDeep: PaintHex(14, 19, 38),
                              rockLit: PaintHex(62, 72, 94), rockShade: PaintHex(21, 27, 46), haze: PaintHex(30, 44, 72), litLow: 0.40, litHigh: 0.52)
            : PaintMassifLook(sun: sun, snowLit: PaintHex(255, 230, 172), snowGlow: PaintHex(250, 186, 112), snowShade: PaintHex(126, 128, 164), snowDeep: PaintHex(92, 96, 134),
                              rockLit: PaintHex(204, 150, 104), rockShade: PaintHex(118, 114, 142), haze: PaintHex(240, 208, 168))

        // A deep sky with a few high wisps swept up from the left by the wind off the range.
        PaintLayCirrus(ref, sky: sky, bottom: meadowTop, veil: dark ? PaintHex(26, 38, 64) : PaintHex(236, 234, 226), veilAmount: dark ? 0.26 : 0.44,
                       low: dark ? PaintHex(70, 54, 66) : PaintHex(250, 190, 128), lowAmount: dark ? 0.7 : 0.5, lowFrom: 0.5, lowTo: 1, angle: -0.24, sweep: 0.14, along: 1.7, across: 8, clearBelow: 0.62, seed: 0x9EA1)

        var rng = SplitMix64(seed: 0x9EA2)
        let far = PaintMassif(w: w, h: h)
        let farPoints: [(Float, Float)] = [(-0.1, 0.98), (0.10, 0.90), (0.26, 0.97), (0.46, 0.84), (0.60, 0.90), (0.78, 0.80), (0.92, 0.86), (1.1, 0.94)]
        let farCrest: [SIMD2<Float>] = farPoints.map { SIMD2($0.0, $0.1 * scaleV) }
        far.setCrest(PaintMassif.jagged(farCrest, rough: 0.16, levels: 4, rng: &rng))
        for node in farCrest {
            far.spur(from: node, angle: Float(rng.next(1.2, 1.9)), length: 0.24, e: 0.05, kL: 0.8, kR: 0.8, maxLevel: 1, rng: &rng)
        }
        far.build(tilt: 0.6, spread: 0.1, axis: 0.5, sun: sun, seed: 0x9EA3)
        PaintLakeScene.paintFar(far, into: ref, look: look, dark: dark, base: meadowTop)

        // Two summits: a tall one left of centre and a sharp lesser one on the right, a saddle between.
        let s = SIMD2<Float>(0.355, summitV)
        func at(_ x: Float, _ dy: Float) -> SIMD2<Float> { SIMD2(x, summitV + dy * scaleV) }
        let crestNodes: [SIMD2<Float>] = [
            at(-0.12, 0.31), at(0.02, 0.26), at(0.10, 0.195), at(0.17, 0.215), at(0.24, 0.125), at(0.30, 0.060),
            s, at(0.415, 0.075), at(0.47, 0.165), at(0.535, 0.230), at(0.60, 0.205), at(0.69, 0.170), at(0.775, 0.125), at(0.845, 0.185), at(0.93, 0.245), at(1.12, 0.335),
        ]
        let m = PaintMassif(w: w, h: h)
        m.setCrest(PaintMassif.jagged(crestNodes, rough: 0.13, levels: 4, rng: &rng))
        m.spur(from: s, angle: 1.42, length: 0.54, e: 0.20, kL: 0.74, kR: 0.62, rng: &rng)
        m.spur(from: at(0.775, 0.125), angle: 1.58, length: 0.38, e: 0.13, kL: 0.76, kR: 0.68, rng: &rng)
        m.spur(from: at(0.24, 0.125), angle: 1.84, length: 0.36, e: 0.11, kL: 0.8, kR: 0.76, rng: &rng)
        m.spur(from: at(0.10, 0.195), angle: 1.72, length: 0.30, e: 0.10, kL: 0.9, kR: 0.8, rng: &rng)
        m.spur(from: at(0.535, 0.230), angle: 1.5, length: 0.24, e: 0.08, kL: 0.9, kR: 0.9, rng: &rng)
        m.spur(from: at(0.30, 0.13), angle: 1.60, length: 0.26, e: 0.050, kL: 1.0, kR: 1.0, maxLevel: 1, rng: &rng)
        m.spur(from: at(0.20, 0.21), angle: 1.68, length: 0.22, e: 0.045, kL: 1.0, kR: 1.0, maxLevel: 1, rng: &rng)
        m.spur(from: at(0.69, 0.20), angle: 1.66, length: 0.20, e: 0.045, kL: 1.0, kR: 1.0, maxLevel: 1, rng: &rng)
        m.build(tilt: 0.72, spread: 0.30, axis: 0.42, sun: sun, seed: 0x9EA7)
        PaintLakeScene.paintMassif(m, into: ref, look: look, dark: dark, summit: s, base: meadowTop, sky: sky, arete: 1.42)
        let apexX = s.x * unitPx, apexY = s.y * unitPx, apexReach = 0.14 * unitPx
        ref.simplify(radius: max(1, w / 220)) { x, y in
            let dx = Float(x) - apexX, dy = Float(y) - apexY
            return PaintSstep(apexReach, apexReach * 0.4, (dx * dx + dy * dy).squareRoot())
        }
        ref.pruneLevels(minArea: Int(0.0009 * unitPx * unitPx))
        ref.pruneLevels(minArea: Int(0.0030 * unitPx * unitPx), only: [8, 9])

        let warp = PaintNoise(seed: 0x9EA4)
        let wa = PaintNoiseField(w: w, h: h, step: 3) { u, v in Float(warp.fbm(u * 9, v * 12, octaves: 2)) }
        let slow = PaintNoiseField(w: w, h: h, step: 6) { u, v in Float(warp.fbm(u * 2.6 + 21, v * 4.4 - 3, octaves: 3)) }
        let patch = PaintNoiseField(w: w, h: h, step: 4) { u, v in Float(warp.fbm(u * 7 + 11, v * 13 + 5, octaves: 3)) }
        let fine = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(warp.fbm(u * 30 + 41, v * 44, octaves: 2)) }

        // Warm air pools at the foot of the range.
        let hazeTint = dark ? PaintHex(40, 54, 84) : PaintHex(246, 212, 160)
        let hazeRows = max(0, Int((meadowTop - 0.20) * unitPx))
        PaintPar(h - hazeRows) { index in
            let row = hazeRows + index
            let v = (Float(row) + 0.5) / unitPx
            let d = meadowTop - v
            if d < -0.02 { return }
            for col in 0..<w {
                let i = row * w + col
                let wander = wa.p[i] * 0.03 + slow.p[i] * 0.05
                let amount = PaintSstep(0.17 + wander, 0.02 + wander, d)
                if amount <= 0 { continue }
                ref.rgb.set3(col, row, PaintMix(ref.rgb.get3(col, row), hazeTint, amount * (dark ? 0.70 : 0.78)))
                if amount > 0.03 { ref.soft.p[i] = max(ref.soft.p[i], 0.86) }
                ref.wet.p[i] = max(ref.wet.p[i], amount * 0.7)
                ref.blend.p[i] = max(ref.blend.p[i], amount * 0.8)
                // In the haze the strokes lie level: nothing runs down a slope it can no longer see.
                if amount > 0.25 {
                    ref.setDir(col, row, angle: 0.02 + wa.p[i] * 0.12, strength: 3)
                    ref.setBendToForm(col, row, 0)
                }
                if amount > 0.5 {
                    ref.detail.p[i] = min(ref.detail.p[i], 0.1)
                    ref.level.p[i] = 5
                }
            }
        }

        // One hazy foothill between the range and the meadow, so the air has something to stand in front of.
        let hillFar = dark ? PaintHex(20, 30, 50) : PaintHex(190, 160, 152)
        let hillNear = dark ? PaintHex(16, 25, 42) : PaintHex(150, 142, 128)
        let hillRow = max(0, Int((meadowTop - 0.15) * unitPx))
        PaintPar(max(0, min(h, Int(meadowTop * unitPx) + 2) - hillRow)) { index in
            let row = hillRow + index
            let v = (Float(row) + 0.5) / unitPx
            for col in 0..<w {
                let i = row * w + col
                let u = (Float(col) + 0.5) / unitPx
                let top = meadowTop - 0.060 - 0.050 * PaintSat(0.5 + Float(warp.fbm(Double(u) * 2.8 + 6, 1.3, octaves: 3)) * 1.9)
                if v < top { continue }
                let c = PaintMix(hillFar, hillNear, PaintSstep(0, 0.09, v - top)) * (1 + 0.05 * wa.p[i])
                ref.paintLay(col, row, c, PaintTouch(level: 34, angle: 0.04, hold: 1.4, bend: 0.1, detail: 0.22, soft: 0.28, wet: 0.2, blend: 0.12, steady: 0.4, comb: 0.5, long: 0.8, wide: 0.7))
            }
        }

        // The stream's course: tight bends far off, slow ones near.
        let span = aspect - meadowTop
        let rowTop = max(0, Int(meadowTop * unitPx))
        var centreRows = [Float](repeating: 0, count: h)
        var halfRows = [Float](repeating: 0, count: h)
        for row in rowTop..<h {
            let t = PaintSat((Float(row) + 0.5 - Float(rowTop)) / max(1, Float(h - rowTop)))
            // On the ground the bends are all alike; distance squeezes them.
            let z = 1 / (t + 0.02)
            centreRows[row] = 0.52 + 0.24 * pow(t, 0.92) * sin(1.1 * z + 2.06) + 1.6 * t * t
        }
        for row in rowTop..<h {
            let t = PaintSat((Float(row) + 0.5 - Float(rowTop)) / max(1, Float(h - rowTop)))
            let z = 1 / (t + 0.02)
            let up = centreRows[max(rowTop, row - 2)], down = centreRows[min(h - 1, row + 2)]
            let run = (down - up) / max(1, Float(min(h - 1, row + 2) - max(rowTop, row - 2))) * unitPx
            let stretch = min(3.5, (1 + run * run).squareRoot())
            let swell = 1 + 0.75 * Float(warp.fbm(Double(t) * 8 + 3, 3.3, octaves: 2))
            halfRows[row] = (0.0010 + 0.050 * pow(t, 1.15)) * (1 + 0.22 * sin(z * 2.3)) * stretch * max(0.45, swell) * size
        }
        let streamCentre = centreRows, streamHalf = halfRows

        // Meadow: low swells, gold where the sun lies, green-blue in the shadow of a cloud.
        let farGrass = dark ? PaintHex(30, 42, 60) : PaintHex(236, 202, 120)
        let gold = dark ? PaintHex(28, 38, 50) : PaintHex(226, 190, 88)
        let goldHot = dark ? PaintHex(38, 50, 62) : PaintHex(246, 214, 110)
        let green = dark ? PaintHex(17, 26, 36) : PaintHex(150, 158, 74)
        let shadowGrass = dark ? PaintHex(11, 17, 27) : PaintHex(84, 112, 76)
        let nearGrass = dark ? PaintHex(10, 15, 25) : PaintHex(112, 128, 62)
        let bank = dark ? PaintHex(9, 13, 22) : PaintHex(108, 110, 60)
        let bankLit = dark ? PaintHex(26, 32, 46) : PaintHex(190, 158, 92)
        let waterFar = dark ? PaintHex(92, 110, 146) : PaintHex(255, 232, 182)
        let waterMid = dark ? PaintHex(40, 54, 84) : PaintHex(150, 176, 178)
        let waterNear = dark ? PaintHex(22, 33, 58) : PaintHex(74, 118, 154)
        let waterDark = dark ? PaintHex(12, 20, 38) : PaintHex(58, 90, 112)
        let rangeInWater = dark ? PaintHex(58, 70, 100) : PaintHex(244, 200, 140)
        PaintPar(h - rowTop) { index in
            let row = rowTop + index
            let v = (Float(row) + 0.5) / unitPx
            let t = PaintSat((v - meadowTop) / span)
            let centre = streamCentre[row], half = streamHalf[row]
            let bankWidth = half * 0.12 * PaintSstep(0.06, 0.3, t)
            for col in 0..<w {
                let i = row * w + col
                let u = (Float(col) + 0.5) / unitPx
                let edge = (wa.p[i] + fine.p[i] * 0.6) * (0.0008 + half * 0.50)
                let d = abs(u - centre + edge)
                if d < half {
                    // Water: the sky's gold far off, its blue near us, dark under the sunward bank.
                    var c = PaintMix(waterFar, waterMid, PaintSstep(0.05, 0.22, t))
                    c = PaintMix(c, waterNear, PaintSstep(0.18, 0.46, t))
                    let across = (u - centre + edge) / max(0.0005, half)
                    c = PaintMix(c, waterDark, PaintSstep(-0.40, -1.02, across) * PaintSstep(0.12, 0.5, t) * 0.62)
                    let ripple = Float(warp.value(Double(u) * 12, Double(v) * 120))
                    c = PaintMix(c, PaintMix(waterFar, waterMid, 0.3), PaintSstep(0.62, 0.84, ripple) * 0.25 * PaintSstep(0.1, 0.5, t))
                    // The range lies in it, broken by the current.
                    let broken = PaintSstep(-0.02, 0.22, patch.p[i] + Float(warp.value(Double(u) * 7 + 5, Double(v) * 46)) * 0.25 - 0.1)
                    c = PaintMix(c, rangeInWater, broken * PaintSstep(0.60, 0.10, t) * 0.62)
                    ref.paintLay(col, row, c, PaintTouch(level: 30, angle: 0.01, hold: 1.8, bend: 0.03, detail: PaintLerp(0.75, 0.30, PaintSstep(0.1, 0.5, t)), soft: 0.34, wet: 0.3, blend: 0.14, steady: 0.4, comb: 0.5, long: 1.1, wide: 0.5))
                    continue
                }
                if d < half + bankWidth {
                    let sunward = u < centre
                    let c = sunward ? bank : PaintMix(bank, bankLit, 0.65)
                    ref.paintLay(col, row, c, PaintTouch(level: sunward ? 31 : 32, angle: 0.1, hold: 1.5, bend: 0.1, detail: PaintLerp(0.7, 0.34, t), soft: 0.12, wet: 0.1, blend: 0.04, steady: 0.5, comb: 0.5, long: 0.8, wide: 0.6))
                    continue
                }
                let sunny = PaintSstep(-0.22, 0.10, slow.p[i] + patch.p[i] * 0.20)
                var c = PaintMix(green, gold, PaintSstep(-0.14, 0.18, patch.p[i] + slow.p[i] * 0.2))
                c = PaintMix(c, goldHot, PaintSstep(0.12, 0.34, patch.p[i]) * 0.7)
                c = PaintMix(shadowGrass, c, 0.22 + 0.78 * sunny)
                c = PaintMix(farGrass, c, PaintSstep(0.0, 0.30, t))
                c = PaintMix(c, nearGrass, PaintSstep(0.55, 1.0, t) * 0.75)
                c *= 1 + 0.07 * fine.p[i]
                ref.paintLay(col, row, c, PaintTouch(level: 40, angle: 0.03 + wa.p[i] * 0.3 * (0.3 + t), hold: PaintLerp(2.0, 1.1, t), bend: 0.05, detail: PaintLerp(0.16, 0.08, t), soft: 0.55, wet: 0.24, blend: 0.1, steady: 0.25, comb: 0.7, long: PaintLerp(1.2, 0.8, t), wide: PaintLerp(0.5, 1, PaintSstep(0, 0.5, t))))
            }
        }
        ref.pruneLevels(minArea: Int(0.00004 * unitPx * unitPx), only: [31, 32])

        // A dark belt of forest at the foot of the range, its top broken by the trees that stand on it.
        let beltFar = dark ? PaintHex(12, 19, 32) : PaintHex(92, 104, 88)
        let beltNear = dark ? PaintHex(9, 15, 25) : PaintHex(62, 82, 66)
        let beltTopRow = max(0, Int((meadowTop - 0.06) * unitPx))
        PaintPar(min(h, rowTop + Int(0.03 * unitPx)) - beltTopRow) { index in
            let row = beltTopRow + index
            let v = (Float(row) + 0.5) / unitPx
            for col in 0..<w {
                let i = row * w + col
                let u = (Float(col) + 0.5) / unitPx
                let top = meadowTop - 0.022 - 0.022 * PaintSat(0.5 + Float(warp.fbm(Double(u) * 5, 4.1, octaves: 2)) * 2) * (0.5 + abs(u - 0.5) * 1.6)
                let bottom = meadowTop + 0.006 + 0.010 * Float(warp.fbm(Double(u) * 9, 8.3, octaves: 2))
                if v < top || v > bottom { continue }
                let c = PaintMix(beltFar, beltNear, PaintSat((v - top) / (bottom - top))) * (1 + 0.10 * wa.p[i])
                ref.paintLay(col, row, c, PaintTouch(level: 33, angle: Float.pi / 2, hold: 1.2, bend: 0.1, detail: 0.5, soft: 0.2, wet: 0.1, blend: 0.05, steady: 0.5, comb: 0.5, long: 0.6, wide: 0.5))
            }
        }

        // Dark conifers in stands at the meadow's far edge and up its sides.
        let treeDark = dark ? PaintHex(7, 11, 20) : PaintHex(30, 46, 46)
        let treeMid = dark ? PaintHex(12, 19, 30) : PaintHex(46, 66, 54)
        let treeLit = dark ? PaintHex(38, 52, 72) : PaintHex(176, 160, 88)
        struct Conifer: Sendable { var x, base, height: Float }
        var conifers: [Conifer] = []
        for _ in 0..<300 {
            let u = Float(rng.next(-0.04, 1.04))
            let base = meadowTop + Float(rng.next(-0.002, 0.010))
            let stand = PaintSat(0.5 + 1.7 * Float(warp.fbm(Double(u) * 6, 2.2, octaves: 2)))
            conifers.append(Conifer(x: u, base: base, height: Float(rng.next(0.020, 0.036)) * (0.6 + 1.1 * stand) * size))
        }
        let stands: [(x: Float, y: Float, n: Int, tall: Float, spread: Float)] = [
            (0.04, 0.040, 16, 0.125, 0.13), (0.93, 0.050, 16, 0.135, 0.13), (0.24, 0.018, 8, 0.060, 0.06), (0.80, 0.020, 6, 0.060, 0.05), (1.01, 0.115, 9, 0.215, 0.07), (-0.015, 0.095, 8, 0.190, 0.06),
        ]
        for stand in stands {
            for _ in 0..<stand.n {
                let dx = Float(rng.next(-1, 1))
                let height = stand.tall * Float(rng.next(0.55, 1.05)) * (1 - abs(dx) * 0.4) * size
                let base = meadowTop + stand.y * scaleV + Float(rng.next(-0.012, 0.016)) * (0.3 + stand.y * 6)
                conifers.append(Conifer(x: stand.x + dx * stand.spread, base: base, height: height))
            }
        }
        conifers.sort { $0.base < $1.base }
        for tree in conifers {
            let tiers = max(8, min(46, Int(tree.height * 300)))
            let breadth = tree.height * 0.27
            // Ground shadow, thrown away from the sun.
            ref.authored.append(PaintAuthoredStroke(x: tree.x + tree.height * 0.40, y: tree.base + breadth * 0.03, angle: 0.03, length: tree.height * 0.86, width: breadth * 0.30, color: shadowGrass * 0.82, alpha: 0.6, load: 0.9, thick: 0.05, round: 0.9, feather: 0.5, taper: 0.6, tipIn: 0.9, tipOut: 1, comb: 0.4))
            ref.authored.append(PaintAuthoredStroke(x: tree.x, y: tree.base - tree.height * 0.49, angle: -Float.pi / 2, length: tree.height * 0.98, width: breadth * 0.16, color: treeDark, alpha: 1, load: 1, thick: 0.4, round: 0.4, feather: 0.05, taper: 0.8, tipIn: 0.2, tipOut: 1, comb: 0.3))
            for pass in 0..<2 {
                for tier in 0..<tiers {
                    let k = (Float(tier) + Float(rng.next())) / Float(tiers)
                    let y = tree.base - tree.height * 0.97 + tree.height * 0.90 * k
                    let reach = breadth * (0.08 + 0.92 * pow(k, 0.9)) * Float(rng.next(0.70, 1.15))
                    for side in [-1 as Float, 1] {
                        let sunSide = side < 0
                        if pass == 1 && !sunSide { continue }
                        if pass == 1 && rng.next() < 0.40 { continue }
                        let drop = Float(rng.next(0.26, 0.60))
                        let length = pass == 0 ? reach : reach * Float(rng.next(0.4, 0.7))
                        let start = pass == 0 ? 0 : reach * Float(rng.next(0.2, 0.55))
                        // A mark is placed by its middle.
                        let cx = tree.x + side * cos(drop) * (start + length * 0.5)
                        let cy = y + sin(drop) * (start + length * 0.5)
                        let angle = side < 0 ? Float.pi - drop : drop
                        let colour: PaintV3
                        if pass == 0 { colour = PaintMix(treeDark, treeMid, sunSide ? 1 : 0.15) } else { colour = PaintMix(treeMid, treeLit, Float(rng.next(0.25, 0.8))) }
                        ref.authored.append(PaintAuthoredStroke(x: cx, y: cy, angle: angle, length: length, width: max(0.0016, tree.height * (pass == 0 ? 0.050 : 0.030)), color: colour, alpha: 1, load: 0.95, thick: 0.45, round: 0.4, feather: 0.05, taper: 0.5, tipIn: 0.35, tipOut: 0.95, comb: 0.6))
                    }
                }
            }
        }

        // Grass, from far to near, with flowers among it. Everything small here is a touch of the brush.
        struct Touch: Sendable { var y: Float; var stroke: PaintAuthoredStroke }
        var near: [Touch] = []
        let bladeDeep = dark ? PaintHex(9, 14, 24) : PaintHex(88, 108, 60)
        let bladeMid = dark ? PaintHex(16, 25, 34) : PaintHex(128, 140, 62)
        let bladeLit = dark ? PaintHex(28, 38, 48) : PaintHex(208, 192, 92)
        let bloom: [PaintV3] = dark
            ? [PaintHex(78, 88, 110), PaintHex(66, 72, 104), PaintHex(84, 92, 104)]
            : [PaintHex(254, 244, 214), PaintHex(250, 210, 80), PaintHex(226, 112, 118), PaintHex(160, 120, 200), PaintHex(248, 150, 70)]
        for _ in 0..<900 {
            let t = pow(Float(rng.next()), 0.62)
            let v = meadowTop + 0.012 + t * span
            let u = Float(rng.next(-0.05, 1.05))
            let row = min(h - 1, Int(v * unitPx))
            // Stay out of the stream, though grass may lean over its bank.
            if abs(u - streamCentre[row]) < streamHalf[row] * 1.06 { continue }
            let clump = Float(warp.fbm(Double(u) * 6, Double(v) * 12 + 7, octaves: 2))
            let scale = PaintLerp(0.005, 0.052, t * t) * Float(rng.next(0.7, 1.3)) * size
            let blades = 3 + Int(t * 5)
            let tone = PaintSat(0.5 + clump * 2.6 + Float(rng.next(-0.2, 0.2)))
            for _ in 0..<blades {
                let x = u + Float(rng.next(-0.6, 0.6)) * scale
                let lean = (x - u) / scale * 0.6 + Float(rng.next(-0.22, 0.22))
                let length = scale * Float(rng.next(0.65, 1.3))
                let colour = rng.next() < 0.35 ? PaintMix(bladeMid, bladeLit, tone) : PaintMix(bladeDeep, bladeMid, tone)
                near.append(Touch(y: v, stroke: PaintAuthoredStroke(x: x + sin(lean) * length * 0.5, y: v - cos(lean) * length * 0.5, angle: -Float.pi / 2 + lean, length: length, width: max(0.0018, scale * 0.14), color: colour, alpha: 0.9, load: 0.9, thick: 0.3, round: 0.6, feather: 0.22, taper: 0.6, tipIn: 0.4, tipOut: 0.95, comb: 0.85)))
            }
        }
        for _ in 0..<500 {
            let t = pow(Float(rng.next()), 0.8)
            let v = meadowTop + 0.02 + t * span
            let u = Float(rng.next(-0.05, 1.05))
            let row = min(h - 1, Int(v * unitPx))
            if abs(u - streamCentre[row]) < streamHalf[row] * 1.2 { continue }
            let drift = Float(warp.fbm(Double(u) * 5 + 3, Double(v) * 10 - 2, octaves: 3))
            if drift < 0.18 { continue }
            // Flowers belong to the grass they stand in.
            let colour = PaintMix(bloom[Int(rng.next() * Double(bloom.count)) % bloom.count], PaintMix(bladeMid, bladeLit, 0.5), 0.35)
            let r = PaintLerp(0.0016, 0.0074, t * t) * Float(rng.next(0.7, 1.3)) * size
            let lift = PaintLerp(0.002, 0.03, t * t)
            near.append(Touch(y: v + 0.001, stroke: PaintAuthoredStroke(x: u, y: v - lift, angle: Float(rng.next(-0.5, 0.5)), length: r * 1.8, width: r * 1.2, color: colour, alpha: 0.9, load: 0.95, thick: 0.5, round: 0.8, feather: 0.22, taper: 0.2, tipIn: 0.7, tipOut: 0.8, comb: 0.5)))
        }
        // Grass leans in over both banks, so the stream's edge is never a line.
        for _ in 0..<240 {
            let t = pow(Float(rng.next()), 0.8) * 0.72
            let row = min(h - 1, rowTop + Int(t * Float(h - rowTop - 1)))
            let v = (Float(row) + 0.5) / unitPx
            let side: Float = rng.next() < 0.5 ? -1 : 1
            let u = streamCentre[row] + side * streamHalf[row] * Float(rng.next(0.92, 1.22))
            let scale = PaintLerp(0.006, 0.040, t * 1.3) * Float(rng.next(0.7, 1.3)) * size
            for _ in 0..<(3 + Int(t * 5)) {
                let x = u + Float(rng.next(-0.7, 0.7)) * scale
                let lean = -side * Float(rng.next(0.1, 0.5))
                let length = scale * Float(rng.next(0.6, 1.2))
                let colour = rng.next() < 0.35 ? PaintMix(bladeMid, bladeLit, 0.5) : PaintMix(bladeDeep, bladeMid, 0.6)
                near.append(Touch(y: v, stroke: PaintAuthoredStroke(x: x + sin(lean) * length * 0.5, y: v - cos(lean) * length * 0.5, angle: -Float.pi / 2 + lean, length: length, width: max(0.0018, scale * 0.15), color: colour, alpha: 0.9, load: 0.9, thick: 0.3, round: 0.6, feather: 0.2, taper: 0.6, tipIn: 0.4, tipOut: 0.95, comb: 0.85)))
            }
        }
        near.sort { $0.y < $1.y }
        for touch in near { ref.authored.append(touch.stroke) }

        if dark {
            let land = m.land.blurred(max(2, Int(unitPx * 0.062)))
            PaintAddStars(to: ref, count: 26, aspectTop: summitV * 0.95, seed: 0x5746) { x, y in
                let c = min(w - 1, Int(x * unitPx)), r = min(h - 1, Int(y * unitPx))
                return land.at(c, r) < 0.01 && y < meadowTop * 0.42
            }
        }
        return ref
    }
}
