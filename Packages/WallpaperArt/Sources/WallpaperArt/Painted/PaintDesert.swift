// Mesas in warm low light: flat caps, terraced cliffs, talus skirts, long violet shadows on the sand, sage scrub near us. At night, plum and navy under the stars, a silver edge on whatever faces the sky's last light.

import Foundation
import simd

nonisolated enum PaintDesertScene {
    private struct Mesa: Sendable {
        var centre: Float     // Across the picture.
        var half: Float       // Half width of the cap.
        var top, foot: Float
        var air: Float
        var level: Float
        var seed: Double
        var skew: Float       // Skirt reaches further on one side.
        var ribWide: Float
        var flare: Float = 1
        var shadeAt: Float = 0.30   // Where the sun's edge falls across the wall.
    }

    private struct Palette: Sendable {
        var lit, litPale, cap, shade, shadeDeep, talusLit, talusShade, haze: PaintV3
    }

    static func scene(width: Int, height: Int, dark: Bool) -> PaintSceneRef {
        let w = min(width, 590)
        let h = Int((Float(height) * Float(w) / Float(width)).rounded())
        let ref = PaintSceneRef(w: w, h: h)
        ref.dark = dark
        ref.ground = dark ? PaintHex(20, 20, 36) : PaintHex(176, 112, 78)
        let unitPx = Float(w)
        let aspect = Float(height) / Float(width)
        let size = min(1, pow(aspect / 2.168, 0.6))
        ref.lightDir = simd_normalize(SIMD2<Float>(0.8, -0.6))
        let horizon = aspect * 0.525

        // A bleached sky: the sun has taken the colour out of it. High cirrus on a long slant, as in the great heat.
        let daySky: [(Float, PaintV3)] = [(0, PaintHex(116, 164, 196)), (0.34, PaintHex(170, 200, 212)), (0.66, PaintHex(226, 226, 208)), (0.88, PaintHex(250, 226, 184)), (1, PaintHex(252, 206, 150))]
        let nightSky: [(Float, PaintV3)] = [(0, PaintHex(6, 9, 22)), (0.42, PaintHex(10, 15, 36)), (0.78, PaintHex(20, 27, 54)), (1, PaintHex(44, 42, 72))]
        PaintLayCirrus(ref, sky: PaintGradient(stops: dark ? nightSky : daySky), bottom: horizon, veil: dark ? PaintHex(30, 38, 66) : PaintHex(250, 244, 226), veilAmount: dark ? 0.34 : 0.56,
                       low: dark ? PaintHex(92, 66, 80) : PaintHex(252, 180, 122), lowAmount: dark ? 0.70 : 0.40, lowFrom: 0.25, lowTo: 1, angle: 0.30, seed: 0xDE5A)

        let warp = PaintNoise(seed: 0xDE5B)
        let wa = PaintNoiseField(w: w, h: h, step: 3) { u, v in Float(warp.fbm(u * 9, v * 11, octaves: 2)) }
        let wb = PaintNoiseField(w: w, h: h, step: 3) { u, v in Float(warp.fbm(u * 8 + 9, v * 7 - 4, octaves: 2)) }
        let slow = PaintNoiseField(w: w, h: h, step: 6) { u, v in Float(warp.fbm(u * 2.4 + 21, v * 3.2 - 3, octaves: 3)) }
        let fine = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(warp.fbm(u * 26 + 41, v * 36, octaves: 2)) }

        // Sand: long low swells going back, warm where they turn to the sun.
        let sandLit = dark ? PaintHex(44, 44, 64) : PaintHex(246, 198, 134)
        let sandMid = dark ? PaintHex(26, 28, 46) : PaintHex(220, 156, 104)
        let sandNear = dark ? PaintHex(13, 15, 28) : PaintHex(150, 96, 74)
        let sandFar = dark ? PaintHex(36, 38, 62) : PaintHex(242, 188, 146)
        let shadowFar = dark ? PaintHex(17, 19, 38) : PaintHex(168, 122, 138)
        let shadowNear = dark ? PaintHex(8, 11, 22) : PaintHex(96, 70, 100)
        let sandSpan = aspect - horizon
        // Long swells, each with a cool lee just under its crest.
        struct Swell: Sendable { var y, amp: Float; var freq, phase: Float; var lee: Float; var fall: Float; var tilt: Float }
        // Two small swells far off, then one great dune crossing the picture on a long diagonal, and the near ground. The great one is the form that holds the empty sand together.
        let swells: [Swell] = [
            Swell(y: horizon + sandSpan * 0.13, amp: 0.005, freq: 5.0, phase: 0.4, lee: 0.30, fall: 0.026, tilt: 0.01),
            Swell(y: horizon + sandSpan * 0.24, amp: 0.008, freq: 3.4, phase: 2.6, lee: 0.40, fall: 0.042, tilt: -0.02),
            Swell(y: horizon + sandSpan * 0.48, amp: 0.020, freq: 1.7, phase: 4.8, lee: 0.92, fall: 0.135, tilt: 0.26),
            Swell(y: horizon + sandSpan * 0.82, amp: 0.034, freq: 2.1, phase: 0.9, lee: 0.72, fall: 0.150, tilt: -0.05),
        ]
        var crestTable = [Float](repeating: 0, count: swells.count * w)
        for (index, swell) in swells.enumerated() {
            for col in 0..<w {
                let u = (Float(col) + 0.5) / unitPx
                crestTable[index * w + col] = swell.y + swell.amp * (sin(u * swell.freq * 2 + swell.phase) + 0.45 * sin(u * swell.freq * 4.6 + swell.phase * 1.7) + 0.30 * sin(u * swell.freq * 10.3 + swell.phase * 2.3)) + (0.5 - u) * swell.tilt
            }
        }
        let crests = crestTable
        let swellList = swells
        PaintPar(h) { row in
            let v = (Float(row) + 0.5) / unitPx
            if v < horizon - 0.01 { return }
            let t = PaintSat((v - horizon) / sandSpan)
            for col in 0..<w {
                let i = row * w + col
                let swell = PaintSstep(-0.16, 0.20, slow.p[i] + wb.p[i] * 0.18)
                var c = PaintMix(sandMid, sandLit, swell)
                c = PaintMix(sandFar, c, PaintSstep(0.0, 0.30, t))
                c = PaintMix(c, sandNear, PaintSstep(0.50, 1.0, t) * 0.8)
                var lee: Float = 0
                var slope: Float = 0.015
                let jitter = wa.p[i] * 0.012
                for index in (0..<swellList.count).reversed() {
                    let d = v + jitter - crests[index * w + col]
                    if d >= 0 {
                        lee = swellList[index].lee * (1 - PaintSstep(swellList[index].fall * 0.12, swellList[index].fall, d))
                        // The crest catches light, a moment above its lee.
                        slope = 0.05 + 0.12 * lee
                        break
                    }
                    let above = -d
                    if above < swellList[index].fall * 0.30 { c = PaintMix(c, sandLit, 0.46 * (1 - above / (swellList[index].fall * 0.30))) }
                }
                c = PaintMix(c, PaintMix(shadowFar, shadowNear, PaintSstep(0.1, 0.9, t)), lee)
                c *= 1 + 0.06 * fine.p[i]
                ref.paintLay(col, row, c, PaintTouch(level: 5, angle: slope + wa.p[i] * 0.10 * (0.3 + t), hold: 2.2, bend: 0.05, detail: PaintLerp(0.16, 0.06, t), soft: 0.55, wet: 0.3, blend: 0.14, steady: 0.25, comb: 0.65, long: 1.25, wide: PaintLerp(0.5, 1, PaintSstep(0, 0.6, t))))
            }
        }

        // The mesas, far to near.
        let mesas: [Mesa] = [
            Mesa(centre: 0.80, half: 0.17, top: aspect * 0.468, foot: horizon + 0.004, air: dark ? 0.56 : 0.66, level: 10, seed: 3.1, skew: 0.5, ribWide: 0.040),
            Mesa(centre: 0.34, half: 0.12, top: aspect * 0.485, foot: horizon + 0.006, air: dark ? 0.58 : 0.70, level: 20, seed: 5.3, skew: -0.3, ribWide: 0.040),
            Mesa(centre: 1.02, half: 0.16, top: aspect * 0.405, foot: horizon + 0.020, air: dark ? 0.34 : 0.40, level: 30, seed: 8.7, skew: -0.4, ribWide: 0.046),
            Mesa(centre: 0.585, half: 0.052, top: aspect * 0.420, foot: horizon + 0.024, air: dark ? 0.24 : 0.30, level: 40, seed: 11.1, skew: 0.2, ribWide: 0.028, flare: 2.0),
            Mesa(centre: 0.175, half: 0.255, top: aspect * 0.270, foot: horizon + 0.068, air: 0.05, level: 50, seed: 14.9, skew: 0.35, ribWide: 0.056, flare: 0.9, shadeAt: 0.44),
        ]
        let hues = dark
            ? Palette(lit: PaintHex(60, 56, 86), litPale: PaintHex(78, 74, 104), cap: PaintHex(70, 70, 102), shade: PaintHex(20, 21, 42), shadeDeep: PaintHex(12, 13, 30), talusLit: PaintHex(44, 42, 66), talusShade: PaintHex(17, 18, 36), haze: PaintHex(32, 36, 64))
            : Palette(lit: PaintHex(224, 116, 66), litPale: PaintHex(244, 168, 106), cap: PaintHex(250, 212, 158), shade: PaintHex(126, 84, 116), shadeDeep: PaintHex(86, 66, 112), talusLit: PaintHex(230, 154, 100), talusShade: PaintHex(140, 100, 120), haze: PaintHex(246, 198, 164))

        // Long shadows on the sand first, thrown away from the sun: to the left, and a little toward us.
        for mesa in mesas {
            let tall = mesa.foot - mesa.top
            let near = mesa.air < 0.2
            let depth = tall * (near ? 0.34 : 0.14)
            let rowA = max(0, Int((mesa.foot - 0.004) * unitPx)), rowB = min(h - 1, Int((mesa.foot + depth) * unitPx))
            if rowA > rowB { continue }
            let footRight = mesa.centre + mesa.half * (near ? 1.28 : 0.7)
            let run = near ? tall * 1.15 : mesa.half * 2.4
            PaintPar(rowB - rowA + 1) { index in
                let row = rowA + index
                let v = (Float(row) + 0.5) / unitPx
                let t = PaintSat((v - mesa.foot) / depth)
                let nearT = PaintSat((v - horizon) / sandSpan)
                let rightEnd = footRight - pow(t, 0.75) * run
                let leftEnd = mesa.centre - mesa.half * 2.2 - run * (0.3 + 0.7 * t)
                for col in 0..<w {
                    let i = row * w + col
                    let u = (Float(col) + 0.5) / unitPx
                    // The edge wanders a little at two scales, so it is a brushed line and not a ruled one.
                    let edge = wa.p[i] * 0.05 + fine.p[i] * 0.009
                    if u > rightEnd + edge || u < leftEnd + edge { continue }
                    let shadow = PaintMix(shadowFar, shadowNear, PaintSstep(0.0, 0.6, nearT))
                    let c = PaintMix(ref.rgb.get3(col, row), shadow, PaintLerp(0.92, 0.70, t) * (1 - mesa.air * 0.55))
                    ref.paintLay(col, row, c, PaintTouch(level: 6, angle: 0.03 + t * 0.2, hold: 2.2, bend: 0.05, detail: 0.06, soft: 0.30, wet: 0.36, blend: 0.3, steady: 0.25, comb: 0.5, long: 1.3, wide: 0.8))
                }
            }
        }

        for mesa in mesas { paintMesa(mesa, into: ref, hues: hues, dark: dark, wa: wa, wb: wb, fine: fine, slow: slow) }
        ref.pruneLevels(minArea: Int(0.00018 * unitPx * unitPx), only: Set(10...59))

        // Sage and rabbitbrush, all small touches, thickening toward us. Far ones first, so near ones overlap them.
        var rng = SplitMix64(seed: 0xDE5C)
        struct Bush: Sendable { var x, y, r: Float; var gold: Bool }
        var bushes: [Bush] = []
        for _ in 0..<420 {
            let t = pow(Float(rng.next()), 0.72)
            let v = horizon + 0.045 + t * (sandSpan - 0.015)
            let u = Float(rng.next(-0.04, 1.04))
            let r = PaintLerp(0.0030, 0.046, t * t) * Float(rng.next(0.6, 1.35)) * size
            // Nothing small enough to read as a speck.
            if r < 0.0105 { continue }
            let col = min(w - 1, max(0, Int(u * unitPx))), row = min(h - 1, Int(v * unitPx))
            let l = Int(ref.level.at(col, row))
            if l != 5 && l != 6 && l != 7 { continue }
            // Loose drifts, not a sprinkle.
            let drift = Float(warp.fbm(Double(u) * 4.4, Double(v) * 7 + 3, octaves: 2))
            if drift < 0.07 - t * 0.12 { continue }
            bushes.append(Bush(x: u, y: v, r: r, gold: rng.next() < 0.13))
        }
        bushes.sort { $0.y < $1.y }
        let sageLit = dark ? PaintHex(30, 38, 54) : PaintHex(164, 170, 118)
        let sageHot = dark ? PaintHex(44, 54, 70) : PaintHex(214, 208, 142)
        let sageMid = dark ? PaintHex(24, 32, 46) : PaintHex(112, 124, 96)
        let sageDeep = dark ? PaintHex(10, 13, 24) : PaintHex(70, 76, 80)
        let goldTip = dark ? PaintHex(82, 84, 92) : PaintHex(232, 192, 104)
        let groundShadow = dark ? PaintHex(7, 9, 20) : PaintHex(112, 80, 96)
        // A big bush near us is a heap like any other in the set: laid in as a mass, its shadow under it on the sand. Touches go on after, only where it meets the light.
        let leafX = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(warp.fbm(u * 26 + 3, v * 26 + 17, octaves: 2)) * 2.2 }
        let leafY = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(warp.fbm(u * 26 - 11, v * 26 + 5, octaves: 2)) * 2.2 }
        var heaps: [PaintPuff] = []
        for bush in bushes where bush.r >= 0.0105 {
            let r = bush.r
            let rx = r * 2.1, ry = r * 0.30
            let sx = bush.x - r * 1.35, sy = bush.y - r * 0.04
            let rowA = max(0, Int((sy - ry) * unitPx)), rowB = min(h - 1, Int((sy + ry) * unitPx))
            let colA = max(0, Int((sx - rx) * unitPx)), colB = min(w - 1, Int((sx + rx) * unitPx))
            if rowA <= rowB && colA <= colB {
                for row in rowA...rowB {
                    for col in colA...colB {
                        let dx = ((Float(col) + 0.5) / unitPx - sx) / rx, dy = ((Float(row) + 0.5) / unitPx - sy) / ry
                        if dx * dx + dy * dy < 1 {
                            ref.rgb.set3(col, row, PaintMix(ref.rgb.get3(col, row), groundShadow, 0.62))
                            ref.level.p[row * w + col] = 7
                        }
                    }
                }
            }
            PaintCrown(x: bush.x, y: bush.y - r * 0.55, r: r * 1.12, squash: 0.74, tint: Float(rng.next(0, 1)), level: 60, generations: r > 0.024 ? 3 : 2, rng: &rng, into: &heaps)
        }
        heaps.sort { $0.y < $1.y }
        let sageLook = dark
            ? PaintPuffLook(shade: PaintHex(13, 17, 30), shadeDeep: PaintHex(9, 12, 24), lit: PaintHex(28, 36, 50), lit2: PaintHex(30, 38, 52), hot: PaintHex(46, 56, 70), haze: hues.haze, light: simd_normalize(PaintV3(0.72, -0.60, 0.36)), threshold: 0.16, sink: 0.36, detail: 0.36, long: 0.72, wide: 1)
            : PaintPuffLook(shade: PaintHex(84, 96, 88), shadeDeep: PaintHex(68, 76, 84), lit: PaintHex(150, 160, 108), lit2: PaintHex(166, 168, 112), hot: PaintHex(216, 208, 142), haze: hues.haze, light: simd_normalize(PaintV3(0.72, -0.60, 0.36)), threshold: 0.12, sink: 0.36, detail: 0.36, long: 0.72, wide: 1)
        PaintLayPuffs(ref, heaps, look: sageLook, warpX: leafX, warpY: leafY, grain: fine)
        for bush in bushes {
            let r = bush.r
            let big = r >= 0.0105
            // A small one's shadow falls away from the sun, long and low.
            if !big {
                ref.authored.append(PaintAuthoredStroke(x: bush.x - r * 1.5, y: bush.y - r * 0.10, angle: 0.05, length: r * 3.2, width: r * 0.54, color: groundShadow, alpha: 0.5, load: 0.9, thick: 0.05, round: 0.9, feather: 0.5, taper: 0.6, tipIn: 0.9, tipOut: 1, comb: 0.4))
            }
            let count = big ? min(48, Int(10 + r * 900)) : min(150, Int(10 + r * 3000))
            for pass in (big ? 1 : 0)..<3 {
                let passCount = pass == 0 ? count * 2 / 5 : (pass == 1 ? count * 2 / 5 : count / 4)
                for _ in 0..<passCount {
                    let a = Float(rng.next(0, 6.2832))
                    let k = sqrt(Float(rng.next()))
                    var px = cos(a) * k
                    var py = sin(a) * k
                    // Each pass sits on its side of the dome.
                    if pass == 1 { px = px * 0.85 + 0.12; py = py * 0.85 - 0.14 }
                    if pass == 2 { px = px * 0.62 + 0.34; py = py * 0.62 - 0.42 }
                    let x = bush.x + px * r * 1.25
                    let y = bush.y - r * 0.62 + py * r * 0.72
                    let length = max(0.0030, r * Float(rng.next(0.20, 0.42)))
                    let lean = px * 0.75 + Float(rng.next(-0.4, 0.4))
                    let lit = PaintSat(0.5 + px * 0.34 - py * 0.42)
                    var colour: PaintV3
                    switch pass {
                    case 0: colour = PaintMix(sageDeep, sageMid, lit)
                    case 1: colour = PaintMix(sageMid, sageLit, lit)
                    default: colour = PaintMix(sageLit, sageHot, lit)
                    }
                    if bush.gold && pass == 2 { colour = PaintMix(colour, goldTip, 0.68) }
                    colour *= Float(rng.next(0.93, 1.07))
                    ref.authored.append(PaintAuthoredStroke(x: x, y: y, angle: -Float.pi / 2 + lean, length: length, width: length * Float(rng.next(0.42, 0.66)), color: colour, alpha: 0.92, load: 0.92, thick: 0.6, round: 0.65, feather: 0.1, taper: 0.2, tipIn: 0.6, tipOut: 0.8, comb: 0.8))
                }
            }
        }

        if dark {
            PaintAddStars(to: ref, count: 30, aspectTop: aspect * 0.22, seed: 0x5745) { _, y in y < aspect * 0.235 }
        }
        return ref
    }

    /// A band of rock in the wall: its own colour, how far it stands proud of the silhouette, where the shadow's edge falls on it.
    private struct Stratum: Sendable {
        var from, to: Float
        var proud: Float
        var tone: Float
        var hard: Bool
        var shadeEdge: Float
    }

    private static func paintMesa(_ m: Mesa, into ref: PaintSceneRef, hues: Palette, dark: Bool, wa: PaintBuf, wb: PaintBuf, fine: PaintBuf, slow: PaintBuf) {
        let w = ref.w, h = ref.h
        let unitPx = Float(w)
        let noise = PaintNoise(seed: UInt64(m.seed * 100))
        let span = m.foot - m.top
        let far = m.air > 0.3
        let capLine: Float = 0.078, notchLine: Float = 0.090, wallEnd: Float = 0.66
        // The wall is its strata: five to seven of them, uneven, three if it's far off. Hard beds stand proud and catch the light; soft ones fall back under them.
        let id = Int32(m.seed * 7)
        let bedCount = far ? 3 : 5 + Int(PaintCellHash(id, 3) * 2.99)
        var weights: [Float] = []
        for k in 0..<bedCount { weights.append(0.45 + 1.25 * PaintCellHash(id, Int32(k), 11)) }
        let total = weights.reduce(0, +)
        var beds: [Stratum] = []
        var at = notchLine
        for k in 0..<bedCount {
            let to = at + weights[k] / total * (wallEnd - notchLine)
            let hard = k % 2 == (id % 2 == 0 ? 0 : 1)
            beds.append(Stratum(from: at, to: to, proud: (hard ? 1 : -1) * (0.0028 + 0.0052 * PaintCellHash(id, Int32(k), 13)) * (m.half / 0.2 + 0.35), tone: hard ? 0.40 + 0.40 * PaintCellHash(id, Int32(k), 17) : 0.22 * PaintCellHash(id, Int32(k), 19), hard: hard, shadeEdge: m.shadeAt - 0.05 + 0.10 * PaintCellHash(id, Int32(k), 23)))
            at = to
        }
        let strata = beds
        @Sendable func bedIndex(_ t: Float) -> Int {
            for k in 0..<strata.count where t < strata[k].to { return k }
            return strata.count - 1
        }
        @Sendable func widen(_ t: Float) -> Float {
            if t < wallEnd { return 1 + 0.20 * pow(PaintSat(t / wallEnd), 1.3) }
            let s = (t - wallEnd) / (1 - wallEnd)
            return 1.20 + (0.95 * m.flare) * pow(s, 1.8)
        }
        let rowTop = max(0, Int((m.top - 0.02) * unitPx)), rowBottom = min(h - 1, Int(m.foot * unitPx))
        if rowTop > rowBottom { return }
        let lit = PaintMix(hues.lit, hues.haze, m.air)
        let litPale = PaintMix(hues.litPale, hues.haze, m.air)
        // The cap is only the top bed: paler, and of the same rock.
        let cap = PaintMix(PaintMix(hues.cap, hues.lit, 0.45), hues.haze, m.air)
        let shade = PaintMix(hues.shade, hues.haze, m.air)
        let deep = PaintMix(hues.shadeDeep, hues.haze, m.air)
        let talusLit = PaintMix(hues.talusLit, hues.haze, m.air)
        let talusShade = PaintMix(hues.talusShade, hues.haze, m.air)
        let detailBase = PaintLerp(0.42, 0.12, PaintSat(m.air * 1.6))
        let cellWide = m.ribWide * 2.2
        PaintPar(rowBottom - rowTop + 1) { index in
            let row = rowTop + index
            let v = (Float(row) + 0.5) / unitPx
            let t = PaintSat((v - m.top) / span)
            let wid = widen(t) * m.half
            let edgeL = Float(noise.fbm(Double(t) * 9 + m.seed, 1.3, octaves: 3)) * 0.020 * (0.3 + t * 1.2) * (m.half / 0.2 + 0.4)
            let edgeR = Float(noise.fbm(Double(t) * 9 + m.seed, 5.7, octaves: 3)) * 0.020 * (0.3 + t * 1.2) * (m.half / 0.2 + 0.4)
            let skirt = PaintSstep(wallEnd, 1, t)
            // The beds step the silhouette in and out, with a short slope at each change.
            var proud: Float = 0
            if t >= notchLine && t < wallEnd {
                let k = bedIndex(t)
                let f = (t - strata[k].from) / max(0.001, strata[k].to - strata[k].from)
                let above = k > 0 ? strata[k - 1].proud : 0.012
                proud = PaintLerp(above, strata[k].proud, PaintSstep(0, 0.16, f))
            }
            let capIn: Float = t < capLine ? -0.012 * (m.half / 0.2 + 0.3) : 0
            let left = m.centre - wid * (1 + m.skew * 0.4 * skirt) + edgeL - proud - capIn
            let right = m.centre + wid * (1 - m.skew * 0.4 * skirt) + edgeR + proud * 0.8 + capIn * 0.7
            let colA = max(0, Int(left * unitPx)), colB = min(w - 1, Int(right * unitPx))
            if colA > colB { return }
            for col in colA...colB {
                let i = row * w + col
                let u = (Float(col) + 0.5) / unitPx
                // The top of the mesa is broken rock, in short lengths at their own heights, never a ruled line.
                let length = (u * 11 + Float(m.seed)).rounded(.down)
                let topStep = (PaintCellHash(Int32(length), id, 29) - 0.5) * 0.015 * (m.half / 0.2 + 0.4)
                let topWander = Float(noise.fbm(Double(u) * 11 + m.seed, 9.1, octaves: 2)) * 0.020 + topStep
                if v < m.top + topWander { continue }
                let x = PaintSat((u - left) / max(0.001, right - left))
                let wob = wa.p[i] * 0.05
                // Bed lines run level but aren't ruled.
                let tw = t + wb.p[i] * 0.010 + Float(noise.fbm(Double(u) * 7 + m.seed, 3.3, octaves: 2)) * 0.016
                var c: PaintV3
                var touch = PaintTouch(level: m.level)
                touch.hold = 1.8
                touch.detail = detailBase
                touch.soft = 0.08
                touch.steady = 0.55
                touch.comb = 0.62
                touch.long = 0.85
                touch.wide = 0.8
                touch.angle = 0.03 + wa.p[i] * 0.05
                if tw < capLine {
                    // The cap, level.
                    let capLit = x + wob * 0.6 > m.shadeAt * 0.8
                    c = capLit ? cap : PaintMix(shade, cap, 0.30)
                    c *= 1 + 0.06 * fine.p[i]
                    touch.level = m.level + (capLit ? 2 : 3)
                    touch.long = 0.9
                } else if tw < notchLine {
                    // The cap's own shadow, under its lip.
                    c = x + wob * 0.6 > m.shadeAt * 0.8 ? PaintMix(deep, lit, 0.50) : deep
                    touch.level = m.level + 4
                    touch.detail = max(0.42, detailBase)
                } else if tw < wallEnd {
                    let k = bedIndex(tw)
                    let bed = strata[k]
                    let f = (tw - bed.from) / max(0.001, bed.to - bed.from)
                    let sunSide = x + wob + Float(noise.value(Double(v) * 14, m.seed)) * 0.05 > bed.shadeEdge
                    // A few clefts, each cut down through a bed or three from a ledge, narrowing as it goes. Most of the wall has none, and a far wall has none at all.
                    var inCleft = false
                    if !far {
                        let cellCoord = (u + wa.p[i] * 0.010) / cellWide
                        let cell = cellCoord.rounded(.down), inCell = cellCoord - cell
                        let cellID = Int32(cell)
                        if PaintCellHash(cellID, id, 31) > 0.72 {
                            let first = Int(PaintCellHash(cellID, id, 37) * Float(strata.count))
                            let last = min(strata.count - 1, first + Int(PaintCellHash(cellID, id, 41) * 2.5))
                            if k >= first && k <= last {
                                let drop = PaintSat((tw - strata[first].from) / max(0.001, strata[last].to - strata[first].from))
                                let half = (0.035 + 0.06 * PaintCellHash(cellID, id, 43)) * (1 - drop * 0.70)
                                inCleft = abs(inCell - 0.5 + (PaintCellHash(cellID, id, 47) - 0.5) * 0.5) < half
                            }
                        }
                    }
                    // Under a bed that stands proud, the shadow it throws.
                    let overhang = k > 0 && strata[k - 1].proud > bed.proud
                    let under = overhang && f < 0.05 + 0.10 * PaintCellHash(Int32(k), id, 53) + wa.p[i] * 0.05 && Float(noise.fbm(Double(u) * 6 + Double(k), m.seed, octaves: 2)) > -0.12
                    if sunSide && !inCleft && !under {
                        c = PaintMix(lit, litPale, bed.tone)
                        // Each bed goes down a little in value toward its foot; the burnt side of the wall is hotter.
                        c *= PaintLerp(1.05, 0.92, f)
                        c = PaintMix(c, litPale, PaintSstep(0.70, 1.0, x) * 0.40)
                        // Old stains come down the wall across the beds.
                        c *= 1 + 0.07 * Float(noise.fbm(Double(u) * 5 + m.seed, Double(k) * 3.1, octaves: 2)) + 0.10 * Float(noise.fbm(Double(u) * 16 + m.seed, Double(tw) * 1.6, octaves: 2))
                        touch.level = m.level + (bed.hard ? 8 : 1)
                    } else if sunSide {
                        // Shadow in the sunny wall takes warmth from the rock around it.
                        c = PaintMix(PaintMix(deep, shade, 0.6), lit, under ? 0.52 : 0.40)
                        touch.level = m.level + 7
                        touch.detail = max(0.42, detailBase)
                    } else {
                        // The shadow side: a few cool values, a whisper of the same beds.
                        c = PaintMix(deep, shade, PaintSat(0.40 + 0.9 * x + (bed.hard ? 0.18 : -0.12)))
                        // Sand throws a little warm light back up under the wall.
                        c = PaintMix(c, talusLit, PaintSstep(0.40, wallEnd, tw) * 0.20)
                        touch.level = m.level
                        touch.soft = 0.40
                        touch.wet = 0.36
                        touch.blend = 0.30
                        touch.detail = detailBase * 0.42
                    }
                    c *= 1 + 0.05 * fine.p[i]
                } else {
                    // The skirt: broken stone running down the fall of the slope.
                    let fall = (u - m.centre) / (0.35 + (tw - wallEnd) * 1.5)
                    let lump = Float(noise.fbm(Double(fall) * 5 + m.seed, Double(tw) * 3.4, octaves: 2))
                    let gully = PaintSstep(-0.04, 0.14, lump)
                    let side = PaintSstep(0.20, 0.34, x + wob * 2)
                    let skirtLit = side * (0.50 + 0.50 * gully)
                    c = PaintMix(talusShade, talusLit, skirtLit)
                    c *= 1 + 0.05 * fine.p[i]
                    // Its foot goes into the sand.
                    let intoSand = PaintSstep(0.84, 1.0, tw)
                    let sand = ref.rgb.get3(col, min(h - 1, rowBottom + 2))
                    c = PaintMix(c, sand, intoSand * 0.75)
                    touch.level = m.level + (side > 0.5 ? 6 : 5)
                    touch.angle = atan2(1, fall * 0.55)
                    touch.detail = detailBase * 0.34
                    touch.soft = intoSand > 0.5 ? 0.82 : 0.30
                    touch.wet = 0.3
                    touch.blend = 0.2
                    touch.bend = 0.2
                    touch.long = 0.72
                    touch.wide = 1
                }
                ref.paintLay(col, row, c, touch)
            }
        }
    }
}
