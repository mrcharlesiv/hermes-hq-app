// A green valley: rolling hills quilted with fields and hedges, a white farmhouse where the lane ends, low afternoon light from the right. At night the hills go blue, the fields keep their lines, and the windows are the one warm thing.

import Foundation
import simd

nonisolated enum PaintHillsScene {
    /// One hill and everything laid out on it.
    private struct Hill: Sendable {
        var base: Float      // Where its crest runs, as a fraction of the picture's height.
        var rise: Float      // Crest higher on the right (+) or on the left (-), in width units.
        var roll: Float      // How much it rolls.
        var seed: Double
        var air: Float
        var rowScale: Float, rowGrow: Float, colScale: Float, fan: Float, vanish: Float
        var hedge: Float     // Hedge half width, in width units.
        var detail: Float
        var level: Float
        var quilted: Bool
    }

    static func scene(width: Int, height: Int, dark: Bool) -> PaintSceneRef {
        let w = min(width, 590)
        let h = Int((Float(height) * Float(w) / Float(width)).rounded())
        let ref = PaintSceneRef(w: w, h: h)
        ref.dark = dark
        ref.ground = dark ? PaintHex(18, 24, 34) : PaintHex(146, 128, 84)
        let unitPx = Float(w)
        let aspect = Float(height) / Float(width)
        let size = min(1, pow(aspect / 2.168, 0.6))
        ref.lightDir = simd_normalize(SIMD2<Float>(0.8, -0.6))
        let skyline = aspect * 0.405

        let daySky: [(Float, PaintV3)] = [(0, PaintHex(88, 142, 184)), (0.42, PaintHex(136, 180, 204)), (0.78, PaintHex(204, 218, 210)), (1, PaintHex(236, 226, 196))]
        let nightSky: [(Float, PaintV3)] = [(0, PaintHex(6, 9, 22)), (0.45, PaintHex(10, 17, 38)), (0.82, PaintHex(20, 32, 60)), (1, PaintHex(40, 54, 82))]
        PaintLaySky(ref, sky: PaintGradient(stops: dark ? nightSky : daySky), bottom: skyline, veil: dark ? PaintHex(28, 40, 66) : PaintHex(232, 236, 228), veilAmount: dark ? 0.26 : 0.22,
                    low: dark ? PaintHex(52, 62, 84) : PaintHex(244, 226, 190), lowAmount: dark ? 0.55 : 0.30, lowFrom: 0.45, lowTo: 1, seed: 0x417A)
        // Weather of its own: big soft clouds going over, their shadows on the fields below.
        do {
            let airNoise = PaintNoise(seed: 0x4171)
            let cloudX = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(airNoise.fbm(u * 7, v * 7, octaves: 2)) * 0.9 }
            let cloudY = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(airNoise.fbm(u * 7 + 17, v * 7 - 9, octaves: 2)) * 0.9 }
            let cloudGrain = PaintNoiseField(w: w, h: h, step: 4) { u, v in Float(airNoise.fbm(u * 5 + 3, v * 6, octaves: 3)) }
            var heaps: [PaintPuff] = []
            var cloudRng = SplitMix64(seed: 0x4172)
            // Far and small to near and great; each a row of crowns on a loose flat base.
            let banks: [(x: Float, y: Float, r: Float, wide: Float, count: Int, air: Float, level: Float)] = [
                (0.74, 0.90, 0.058, 0.20, 6, 0.56, 200), (0.16, 0.80, 0.070, 0.24, 6, 0.44, 202),
                (0.94, 0.56, 0.120, 0.30, 5, 0.12, 204), (0.20, 0.31, 0.170, 0.46, 6, 0.0, 206),
            ]
            for bank in banks {
                for k in 0..<bank.count {
                    let f = (Float(k) + 0.5) / Float(bank.count) * 2 - 1
                    let rise = (1 - f * f)
                    let r = bank.r * (0.62 + 0.52 * rise) * Float(cloudRng.next(0.86, 1.12)) * size
                    PaintCrown(x: bank.x + f * bank.wide * size, y: skyline * bank.y - r * (0.24 + 0.56 * rise), r: r, squash: 0.74, air: bank.air, level: bank.level, generations: 2, spread: 1.05, sunkBias: 0.1, rng: &cloudRng, into: &heaps)
                }
            }
            let cloudLook = dark
                ? PaintPuffLook(shade: PaintHex(13, 20, 40), shadeDeep: PaintHex(10, 16, 34), lit: PaintHex(22, 32, 56), lit2: PaintHex(24, 34, 58), hot: PaintHex(36, 46, 72), haze: PaintHex(16, 26, 50), light: simd_normalize(PaintV3(0.66, -0.66, 0.40)), threshold: 0.30, sink: 0.42, detail: 0.08, long: 1.05, wide: 1.15)
                : PaintPuffLook(shade: PaintHex(166, 186, 206), shadeDeep: PaintHex(146, 170, 196), lit: PaintHex(238, 238, 228), lit2: PaintHex(244, 238, 218), hot: PaintHex(255, 252, 240), haze: PaintHex(206, 220, 218), light: simd_normalize(PaintV3(0.66, -0.66, 0.40)), threshold: 0.14, sink: 0.42, detail: 0.08, long: 1.05, wide: 1.15)
            PaintLayPuffs(ref, heaps, look: cloudLook, warpX: cloudX, warpY: cloudY, grain: cloudGrain)
            ref.pruneLevels(minArea: Int(0.0012 * unitPx * unitPx), only: Set(200...215))
            PaintPar(h) { row in
                for col in 0..<w {
                    let i = row * w + col
                    if ref.level.p[i] >= 200 {
                        // Soft all through: long easy strokes lying with the air, not raking round each billow.
                        ref.soft.p[i] = 0.9
                        ref.wet.p[i] = 0.5
                        ref.blend.p[i] = 0.34
                        ref.detail.p[i] = 0.03
                        ref.steady.p[i] = 0.35
                        ref.comb.p[i] = 0.5
                        ref.setDir(col, row, angle: -0.08 + cloudGrain.p[i] * 0.7, strength: 2.4)
                        ref.setBendToForm(col, row, 0.18)
                        ref.setShape(col, row, length: 1.15, width: 1.2)
                    }
                }
            }
        }

        // The hills, far to near. Each crest leans the other way from the last, so the eye goes down the valley in an S.
        let hills: [Hill] = [
            Hill(base: 0.378, rise: 0.020, roll: 0.022, seed: 3.1, air: dark ? 0.70 : 0.70, rowScale: 0, rowGrow: 0, colScale: 0, fan: 0, vanish: 0.5, hedge: 0, detail: 0.04, level: 2, quilted: false),
            Hill(base: 0.404, rise: -0.040, roll: 0.022, seed: 5.7, air: dark ? 0.50 : 0.50, rowScale: 0, rowGrow: 0, colScale: 0, fan: 0, vanish: 0.5, hedge: 0, detail: 0.05, level: 3, quilted: false),
            Hill(base: 0.436, rise: 0.040, roll: 0.022, seed: 8.3, air: dark ? 0.30 : 0.32, rowScale: 3.6, rowGrow: 16, colScale: 8.5, fan: 2.2, vanish: 0.42, hedge: 0.0016, detail: 0.30, level: 10, quilted: true),
            Hill(base: 0.486, rise: -0.070, roll: 0.030, seed: 11.9, air: dark ? 0.18 : 0.18, rowScale: 3.0, rowGrow: 11, colScale: 5.8, fan: 2.4, vanish: 0.62, hedge: 0.0022, detail: 0.28, level: 20, quilted: true),
            Hill(base: 0.566, rise: 0.082, roll: 0.034, seed: 14.3, air: dark ? 0.08 : 0.08, rowScale: 2.6, rowGrow: 7.5, colScale: 3.5, fan: 2.0, vanish: 0.40, hedge: 0.0030, detail: 0.24, level: 30, quilted: true),
            Hill(base: 0.676, rise: -0.100, roll: 0.036, seed: 18.9, air: 0.0, rowScale: 2.2, rowGrow: 4.6, colScale: 2.1, fan: 1.8, vanish: 0.72, hedge: 0.0042, detail: 0.18, level: 40, quilted: true),
            Hill(base: 0.822, rise: 0.11, roll: 0.022, seed: 23.3, air: 0.0, rowScale: 0, rowGrow: 0, colScale: 0, fan: 0, vanish: 0.5, hedge: 0, detail: 0.05, level: 50, quilted: false),
        ]
        let count = hills.count
        let shapeNoise = PaintNoise(seed: 0x417B)
        // Crests, and which way each is turned, one row of a buffer per hill.
        let crest = PaintBuf(w: w, h: count), facing = PaintBuf(w: w, h: count)
        for (k, hill) in hills.enumerated() {
            for col in 0..<w {
                let u = (Float(col) + 0.5) / unitPx
                let roll = Float(shapeNoise.fbm(Double(u) * 2.2 + hill.seed, hill.seed * 1.7, octaves: 3)) * hill.roll * 2.4
                let fine = Float(shapeNoise.fbm(Double(u) * 9 + hill.seed, hill.seed * 3.1, octaves: 2)) * hill.roll * 0.25
                let wave = sin((u * 0.95 + Float(hill.seed) * 0.37) * 6.283) * hill.roll * 0.9
                crest.p[k * w + col] = hill.base * aspect - hill.rise * (u - 0.5) * 1.5 + roll + fine + wave
            }
            let span = max(2, w / 14)
            for col in 0..<w {
                let a = crest.p[k * w + max(0, col - span)], b = crest.p[k * w + min(w - 1, col + span)]
                // A crest falling toward the sun has its slope turned to the light.
                facing.p[k * w + col] = PaintSat(0.5 + (b - a) / (Float(2 * span) / unitPx) * 4.2)
            }
        }

        let warp = PaintNoise(seed: 0x417C)
        let wa = PaintNoiseField(w: w, h: h, step: 3) { u, v in Float(warp.fbm(u * 7, v * 12, octaves: 2)) }
        let wb = PaintNoiseField(w: w, h: h, step: 3) { u, v in Float(warp.fbm(u * 6 + 9, v * 10 - 4, octaves: 2)) }
        let shadowDrift = PaintNoiseField(w: w, h: h, step: 6) { u, v in Float(warp.fbm(u * 1.9 + 21, v * 3.4 - 3, octaves: 3)) }
        let bendX = PaintNoiseField(w: w, h: h, step: 6) { u, v in Float(warp.fbm(u * 2.3 + 5, v * 3.1 + 1, octaves: 2)) }
        let bendY = PaintNoiseField(w: w, h: h, step: 6) { u, v in Float(warp.fbm(u * 2.1 - 7, v * 2.7 + 13, octaves: 2)) }
        let fine = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(warp.fbm(u * 28 + 41, v * 40, octaves: 2)) }

        // Fields: the sunlit and the cool, a family for each.
        let dayLit: [PaintV3] = [PaintHex(158, 176, 86), PaintHex(126, 162, 92), PaintHex(198, 184, 104), PaintHex(106, 152, 84), PaintHex(174, 180, 110), PaintHex(142, 170, 104)]
        let nightLit: [PaintV3] = [PaintHex(42, 70, 84), PaintHex(36, 64, 80), PaintHex(54, 76, 90), PaintHex(32, 58, 76), PaintHex(48, 72, 86), PaintHex(38, 66, 84)]
        let fieldColours = dark ? nightLit : dayLit
        let coolShade = dark ? PaintHex(13, 25, 40) : PaintHex(62, 104, 96)
        let crestLight = dark ? PaintHex(118, 138, 158) : PaintHex(226, 216, 136)
        let hedgeDark = dark ? PaintHex(6, 11, 19) : PaintHex(30, 58, 48)
        let hedgeLit = dark ? PaintHex(26, 40, 52) : PaintHex(78, 110, 62)
        let haze = dark ? PaintHex(34, 48, 74) : PaintHex(206, 208, 188)
        let farHill = dark ? PaintHex(24, 36, 56) : PaintHex(120, 146, 150)
        let nearDark = dark ? PaintHex(9, 18, 28) : PaintHex(52, 96, 62)
        let nearLit = dark ? PaintHex(30, 50, 60) : PaintHex(120, 156, 74)

        let sunIsRight: Float = 1
        let farmU: Float = 0.60
        let farmV = crest.p[4 * w + Int(farmU * unitPx)] + 0.052 * size
        let hillList = hills
        PaintPar(h) { row in
            let v = (Float(row) + 0.5) / unitPx
            for col in 0..<w {
                // The nearest hill whose crest is above here.
                var k = count - 1
                while k >= 0 && v < crest.p[k * w + col] { k -= 1 }
                if k < 0 { continue }
                let hill = hillList[k]
                let i = row * w + col
                let u = (Float(col) + 0.5) / unitPx
                let c0 = crest.p[k * w + col]
                let s = v - c0
                let front = k + 1 < count ? crest.p[(k + 1) * w + col] : aspect + 0.03
                let depth = PaintSat(s / max(0.01, front - c0))
                let turned = facing.p[k * w + col]
                // Cloud shadow goes over the fields, but the farm stands in a pocket of sun.
                let toFarm = simd_length(SIMD2<Float>(u - farmU, (v - farmV) * 1.3))
                let cloud = PaintSstep(0.02, 0.26, shadowDrift.p[i]) * PaintSstep(0.10, 0.26, toFarm)
                var c: PaintV3
                var touch = PaintTouch(level: hill.level)
                let slope = (crest.p[k * w + min(w - 1, col + 4)] - crest.p[k * w + max(0, col - 4)]) * unitPx / 8
                let contour = atan(slope)
                touch.angle = contour
                touch.detail = hill.detail
                if !hill.quilted {
                    if k < 2 {
                        // Far ridges, thin with air.
                        c = PaintMix(farHill, haze, hill.air * PaintLerp(0.6, 1.25, PaintSstep(0, 0.09, s)))
                        touch.soft = 0.8
                        touch.wet = 0.5
                        touch.blend = 0.3
                        touch.long = 1.1
                    } else {
                        // The near swell under us: one long quiet passage, strokes running with the ground.
                        let light = PaintSat(0.25 + 0.75 * turned) * PaintLerp(1, 0.25, PaintSstep(0.0, 0.42, s))
                        c = PaintMix(nearDark, nearLit, light)
                        c *= 1 + 0.10 * fine.p[i] + 0.06 * wa.p[i]
                        c = PaintMix(c, crestLight, PaintSstep(0.014, 0.0, s) * 0.45 * turned)
                        touch.soft = s < 0.01 ? 0.14 : 0.62
                        touch.wet = 0.36
                        touch.blend = 0.34
                        touch.long = 1.3
                        touch.wide = 1.05
                        touch.comb = 0.55
                        touch.bend = 0.1
                        touch.hold = 1.5
                    }
                    ref.paintLay(col, row, c, touch)
                    continue
                }
                // Lay the quilt out on the slope: rows parallel with the crest and growing toward us, hedge lines fanning from up the hill.
                let growth = 1 + s * hill.rowGrow
                let gyPlain = log(growth) * hill.rowScale
                let gy = gyPlain + gyPlain * 0.0 + wb.p[i] * 0.14 + bendY.p[i] * 0.62 + 0.26 * sin(gyPlain * 2.3 + Float(k))
                let iy = gy.rounded(.down), fy = gy - iy
                let row32 = Int32(iy)
                let shift = PaintCellHash(row32, Int32(k), 7) * 7.3
                let widen = 1 + s * hill.fan
                let colWide = hill.colScale * (0.72 + 0.56 * PaintCellHash(row32, Int32(k), 3)) / widen
                let gx = (u - hill.vanish) * colWide + shift + wa.p[i] * 0.16 + bendX.p[i] * 0.70
                let ix = gx.rounded(.down), fx = gx - ix
                let col32 = Int32(ix)
                let pick = PaintCellHash(col32, row32, Int32(k))
                let family = min(fieldColours.count - 1, Int(pick * Float(fieldColours.count)))
                // The field: its colour, turned to the light or away, a touch of its own.
                let own = PaintCellHash(col32, row32, Int32(k) + 40)
                var field = fieldColours[family] * PaintLerp(0.93, 1.07, own)
                let light = PaintLerp(0.42, 1.14, turned) * PaintLerp(1.10, 0.84, depth)
                field = PaintMix(coolShade, field, PaintSat(light * PaintLerp(1, 0.50, cloud)))
                // Rows in a cut field: slight, and only in some.
                if own > 0.55 {
                    let rows = sin((fy + gx * 0.03) * (5 + 8 * own) * 6.283) * 0.5 + 0.5
                    field *= 1 + (rows - 0.5) * 0.10
                }
                field *= 1 + 0.05 * fine.p[i]
                // The crest catches the light.
                field = PaintMix(field, crestLight, PaintSstep(dark ? 0.016 : 0.012, 0.0, s) * (dark ? 0.72 * max(0.45, turned) : 0.5 * turned))
                // Air settles in the valley behind the next hill.
                field = PaintMix(field, haze, hill.air + PaintSstep(0.50, 1.0, depth) * (dark ? 0.12 : 0.22) * (1 - hill.air))
                c = field
                let hx = colWide, hy = hill.rowScale * hill.rowGrow / growth
                let toSideX = min(fx, 1 - fx) / hx, toSideY = min(fy, 1 - fy) / hy
                // Hedges: some lines have one, some only a change of colour. They thicken toward us.
                let widthHere = hill.hedge * widen * size * (1.0 + 0.55 * fine.p[i] + 0.5 * wa.p[i])
                let sideRight = fx > 0.5
                let hasSide = PaintCellHash(col32 + (sideRight ? 1 : 0), row32, Int32(k) + 80) > 0.2
                let hasAcross = PaintCellHash(Int32(((u - hill.vanish) * hill.colScale * 0.42 + 40).rounded(.down)), row32 + (fy > 0.5 ? 1 : 0), Int32(k) + 90) > 0.26
                let inSide = hasSide && toSideX < widthHere
                let inAcross = hasAcross && toSideY < widthHere * 0.9
                touch.level = hill.level + Float(family)
                touch.detail = hill.detail
                touch.soft = 0.30
                touch.wet = 0.14
                touch.comb = 0.72
                touch.bend = 0.05
                touch.hold = 1.5
                touch.angle = own > 0.5 ? contour + (own - 0.75) * 0.5 : contour + (own - 0.25) * 0.8
                touch.long = 0.95
                if inSide || inAcross {
                    // Lit on the side toward the sun, dark on the other.
                    let across = inSide ? (sideRight ? (1 - fx) / hx : fx / hx) : 0
                    let sunSide = inSide ? ((sideRight ? -1 : 1) * sunIsRight * across / max(0.0001, widthHere)) : -0.2
                    var hedge = PaintMix(hedgeDark, hedgeLit, PaintSat(0.45 + 0.55 * sunSide + 0.8 * fine.p[i]))
                    hedge = PaintMix(hedge, haze, hill.air)
                    c = hedge
                    touch.level = hill.level + 8
                    touch.detail = 0.72
                    touch.soft = 0.08
                    touch.wet = 0.06
                    touch.comb = 0.4
                    touch.long = 0.55
                    touch.wide = 0.7
                    touch.angle = inSide ? atan2(1, (u - hill.vanish) * hill.fan / widen) : contour
                } else {
                    // A thin shadow thrown away from the sun, beside a hedge.
                    if hasSide && sideRight && toSideX < widthHere * 2.6 { c *= 0.76 }
                    if hasAcross && fy < 0.5 && toSideY < widthHere * 1.8 { c *= 0.86 }
                }
                ref.paintLay(col, row, c, touch)
            }
        }
        // Scraps too small to hold a mark go to what's around them.
        ref.pruneLevels(minArea: Int(0.00016 * unitPx * unitPx))

        // The lane: over the near swell, out of sight, up again to the door.
        let laneLight = dark ? PaintHex(86, 98, 114) : PaintHex(226, 206, 156)
        let laneShade = dark ? PaintHex(52, 62, 78) : PaintHex(178, 158, 118)
        let grassStrip = dark ? PaintHex(16, 28, 36) : PaintHex(112, 142, 76)
        let houseU: Float = 0.60
        let houseCrest = crest.p[4 * w + Int(houseU * unitPx)]
        let houseV = houseCrest + 0.052 * size
        @Sendable func crestV(_ k: Int, _ u: Float) -> Float { crest.p[k * w + min(w - 1, max(0, Int(u * unitPx)))] }
        // Each stretch: which hill, where it comes up from under the nearer hill, where it stops.
        let stretches: [(k: Int, fromU: Float, fromV: Float, toU: Float, toV: Float, fromHalf: Float, toHalf: Float, swing: Float)] = [
            (6, 0.17, aspect + 0.02, 0.55, crestV(6, 0.55) + 0.001, 0.070, 0.016, -0.12),
            (5, 0.55, crestV(6, 0.55) + 0.002, 0.665, crestV(5, 0.665) + 0.001, 0.016, 0.0065, 0.018),
            (4, 0.665, crestV(5, 0.665) + 0.002, houseU - 0.012 * size, houseV + 0.004, 0.0065, 0.0028, -0.022),
        ]
        for lane in stretches {
            let rowA = max(0, Int(lane.toV * unitPx)), rowB = min(h - 1, Int(lane.fromV * unitPx))
            if rowA >= rowB { continue }
            PaintPar(rowB - rowA + 1) { index in
                let row = rowA + index
                let v = (Float(row) + 0.5) / unitPx
                let t = PaintSat((v - lane.toV) / (lane.fromV - lane.toV))
                let ease = t * t * (3 - 2 * t)
                let centre = PaintLerp(lane.toU, lane.fromU, ease) + sin(t * .pi) * lane.swing
                let half = PaintLerp(lane.toHalf, lane.fromHalf, t * t) * size
                let along = atan2(lane.fromV - lane.toV, lane.fromU - lane.toU + cos(t * .pi) * .pi * lane.swing)
                let left = max(0, Int((centre - half) * unitPx)), right = min(w - 1, Int((centre + half) * unitPx))
                if left > right { return }
                for col in left...right {
                    // Only on its own hill: the nearer hill hides the rest.
                    if lane.k + 1 < count && v >= crest.p[(lane.k + 1) * w + col] { continue }
                    if v < crest.p[lane.k * w + col] { continue }
                    let u = (Float(col) + 0.5) / unitPx
                    let x = (u - centre) / max(0.0001, half)
                    var c = PaintMix(laneLight, laneShade, PaintSstep(0.2, -0.9, x))
                    c *= 1 + 0.08 * fine.p[row * w + col]
                    // Grass down the middle where it's wide enough to see.
                    let strip = half > 0.012 ? PaintSstep(0.20, 0.08, abs(x + wa.p[row * w + col] * 0.3)) : 0
                    c = PaintMix(c, grassStrip, strip * 0.8)
                    ref.paintLay(col, row, c, PaintTouch(level: 8, angle: along, hold: 1.4, bend: 0.1, detail: 0.46, soft: abs(x) > 0.8 ? 0.12 : 0.3, wet: 0.12, comb: 0.6, long: 0.8, wide: 0.8))
                }
            }
        }

        // Trees: along the hedges and in small stands, each a crown on a cast shadow. Far to near.
        var rng = SplitMix64(seed: 0x417D)
        var puffs: [PaintPuff] = []
        var trunks: [(x: Float, top: Float, bottom: Float, wide: Float)] = []
        var shadows: [(x: Float, y: Float, rx: Float, ry: Float)] = []
        func tree(_ u: Float, _ base: Float, _ r: Float, air: Float, tint: Float, level: Float, shaded: Float = 0) {
            let crownY = base - r * 1.02
            if r > 0.022 {
                PaintOak(x: u, base: base, r: r, air: air, tint: tint, level: level, shaded: shaded, rng: &rng, into: &puffs)
                trunks.append((u, crownY + r * 0.3, base + r * 0.04, max(0.0030, r * 0.12)))
            } else {
                PaintCrown(x: u, y: crownY, r: r, air: air, tint: tint, level: level, generations: 2, sunkBias: shaded, rng: &rng, into: &puffs)
            }
            shadows.append((u - r * 1.25, base + r * 0.04, r * 1.4, r * 0.18))
        }
        // Where a hedge line runs at a place on a hill.
        @Sendable func hedgeNear(_ k: Int, _ u: Float, _ s: Float) -> Float {
            let hill = hills[k]
            let widen = 1 + s * hill.fan
            let row = (log(1 + s * hill.rowGrow) * hill.rowScale).rounded(.down)
            let wide = hill.colScale * (0.72 + 0.56 * PaintCellHash(Int32(row), Int32(k), 3)) / widen
            let shift = PaintCellHash(Int32(row), Int32(k), 7) * 7.3
            let v = (crestV(k, u) + s), i = min(h - 1, max(0, Int(v * unitPx))) * w + min(w - 1, max(0, Int(u * unitPx)))
            let off = shift + wa.p[i] * 0.16 + bendX.p[i] * 0.70
            let gx = (u - hill.vanish) * wide + off
            return hill.vanish + (gx.rounded() - off) / wide
        }
        let treeCounts = [0, 0, 14, 16, 12, 7, 0]
        for k in 2..<count - 1 {
            let hill = hills[k]
            for _ in 0..<treeCounts[k] {
                let u0 = Float(rng.next(0.02, 0.98))
                let room0 = crestV(k + 1, u0) - crestV(k, u0)
                if room0 < 0.02 { continue }
                let s0 = Float(rng.next(0.08, 0.72)) * room0
                let u = hedgeNear(k, u0, s0)
                if u < 0 || u > 1 { continue }
                let c0 = crestV(k, u), front = crestV(k + 1, u)
                let room = front - c0
                if room < 0.02 { continue }
                let s = min(s0, room * 0.9)
                // Nothing grows in the lane.
                let baseRow = min(h - 1, Int((c0 + s) * unitPx)), baseCol = min(w - 1, max(0, Int(u * unitPx)))
                var onLane = false
                for off in stride(from: -Int(0.022 * unitPx), through: Int(0.022 * unitPx), by: 2) where ref.level.at(min(w - 1, max(0, baseCol + off)), baseRow) == 8 { onLane = true }
                if onLane { continue }
                let r = 0.0078 * (1 + s * hill.fan) * size * Float(rng.next(0.8, 1.35)) * (k == 5 ? 2.5 : (k == 4 ? 1.9 : (k == 3 ? 1.4 : 1.1)))
                tree(u, c0 + s, r, air: hill.air, tint: Float(rng.next(0, 1)), level: 70 + Float(k * 2), shaded: k < 5 ? 0.30 : 0.1)
            }
        }
        // Hedges near us aren't lines: they're rows of bushes, each lit on top. Wherever the study has hedge, a bush now and then.
        var scan = SplitMix64(seed: 0x417E)
        struct HedgeBush: Sendable { var x, y, r, air, along: Float }
        var hedgeBushes: [HedgeBush] = []
        for row in stride(from: 0, to: h, by: 2) {
            for col in stride(from: 0, to: w, by: 2) {
                let l = Int(ref.level.at(col, row))
                if l != 38 && l != 48 { continue }
                let k = l / 10 + 0
                let hill = hills[k == 2 ? 3 : (k == 3 ? 4 : 5)]
                let c = hill.level == 20 ? 3 : (hill.level == 30 ? 4 : 5)
                let v = (Float(row) + 0.5) / unitPx
                let s = v - crest.p[c * w + col]
                let half = hill.hedge * (1 + s * hill.fan) * size
                // One bush every width or so along a line two half widths thick.
                let chance = 1.6 / (2 * half * unitPx * half * unitPx * 0.85)
                if Float(scan.next()) > chance { continue }
                // Uneven: a hedge is a run of big and little growth, with thin places.
                let r = half * (scan.next() < 0.2 ? Float(scan.next(2.0, 3.0)) : Float(scan.next(0.9, 1.7)))
                let x = (Float(col) + 0.5) / unitPx
                let y = v - r * 0.35
                // Which way the hedge runs here: the direction its own level goes on longest.
                var along: Float = 0, longest = -1
                for turn in 0..<8 {
                    let a = Float(turn) / 8 * .pi
                    var run = 0
                    for reach in 1...6 {
                        let far = Float(reach) * 1.5
                        if Int(ref.level.at(min(w - 1, max(0, col + Int(cos(a) * far))), min(h - 1, max(0, row + Int(sin(a) * far))))) == l { run += 1 }
                        if Int(ref.level.at(min(w - 1, max(0, col - Int(cos(a) * far))), min(h - 1, max(0, row - Int(sin(a) * far))))) == l { run += 1 }
                    }
                    if run > longest { longest = run; along = a }
                }
                hedgeBushes.append(HedgeBush(x: x, y: y, r: r, air: hill.air, along: along))
            }
        }
        // The oaks standing round the farm, close behind and to the side of it.
        let farmLevel: Float = 84
        tree(houseU + 0.135 * size, houseV + 0.006, 0.056 * size, air: 0.03, tint: 0.3, level: farmLevel)
        tree(houseU + 0.205 * size, houseV + 0.012, 0.042 * size, air: 0.03, tint: 0.7, level: farmLevel)
        tree(houseU - 0.115 * size, houseV - 0.004, 0.046 * size, air: 0.04, tint: 0.2, level: farmLevel)
        tree(houseU - 0.190 * size, houseV + 0.003, 0.036 * size, air: 0.04, tint: 0.8, level: farmLevel)
        // One big old tree near us, off to the left, to look past.
        let bigU: Float = 0.11, bigBase = crestV(5, 0.11) + 0.085
        tree(bigU, bigBase, 0.140 * size, air: 0, tint: 0.45, level: 88)
        // Its shadow has to lie in the picture to stand it on the ground.
        shadows[shadows.count - 1] = (bigU - 0.140 * size * 0.40, bigBase + 0.006, 0.140 * size * 1.05, 0.140 * size * 0.16)
        puffs.sort { $0.y + $0.r < $1.y + $1.r }
        let shadowTint = dark ? PaintHex(8, 14, 24) : PaintHex(52, 84, 62)
        for s in shadows {
            let rowA = max(0, Int((s.y - s.ry) * unitPx)), rowB = min(h - 1, Int((s.y + s.ry) * unitPx))
            let colA = max(0, Int((s.x - s.rx) * unitPx)), colB = min(w - 1, Int((s.x + s.rx) * unitPx))
            if rowA > rowB || colA > colB { continue }
            for row in rowA...rowB {
                for col in colA...colB {
                    let dx = ((Float(col) + 0.5) / unitPx - s.x) / s.rx, dy = ((Float(row) + 0.5) / unitPx - s.y) / s.ry
                    let d = dx * dx + dy * dy
                    if d < 1 && ref.rgb.get3(col, row).y < 0.99 {
                        ref.rgb.set3(col, row, PaintMix(ref.rgb.get3(col, row), shadowTint, 0.55 * PaintSstep(1, 0.6, d)))
                    }
                }
            }
        }
        for t in trunks {
            let dark1 = dark ? PaintHex(6, 10, 16) : PaintHex(58, 50, 44)
            PaintFillPlane(ref, [SIMD2(t.x - t.wide * 0.5, t.top), SIMD2(t.x + t.wide * 0.5, t.top), SIMD2(t.x + t.wide * 0.8, t.bottom), SIMD2(t.x - t.wide * 0.9, t.bottom)], color: dark1, PaintTouch(level: 69, angle: .pi / 2, hold: 2, bend: 0.2, detail: 0.7, soft: 0.1, wet: 0.1, long: 0.7, wide: 0.7))
            // A big trunk is round: bark strokes going up it, lit on the sun's side, spreading at the root.
            if t.wide > 0.008 {
                let barkLit = dark ? PaintHex(26, 34, 44) : PaintHex(146, 116, 84)
                let barkMid = dark ? PaintHex(14, 20, 28) : PaintHex(96, 78, 62)
                let span = t.bottom - t.top
                for (k, across) in [(0, Float(0.30)), (1, Float(0.08)), (2, Float(0.30)), (3, Float(-0.12))] {
                    ref.authored.append(PaintAuthoredStroke(x: t.x + t.wide * across, y: t.top + span * (k < 2 ? 0.42 : 0.70), angle: .pi / 2 + across * 0.1, length: span * (k < 2 ? 0.74 : 0.46), width: t.wide * (k == 0 ? 0.30 : 0.22), color: k == 0 || k == 2 ? barkLit : barkMid, alpha: 0.92, load: 0.9, thick: 0.5, round: 0.5, feather: 0.12, taper: 0.4, tipIn: 0.5, tipOut: 0.8, comb: 0.85))
                }
                for (off, lean) in [(Float(-0.8), Float(0.62)), (0.7, -0.5), (-0.2, 0.08)] {
                    ref.authored.append(PaintAuthoredStroke(x: t.x + t.wide * off, y: t.bottom - span * 0.03, angle: .pi / 2 + lean, length: span * 0.22, width: t.wide * 0.34, color: barkMid, alpha: 0.9, load: 0.9, thick: 0.4, round: 0.5, feather: 0.2, taper: 0.7, tipIn: 0.5, tipOut: 1, comb: 0.8))
                }
            }
        }
        let leaves = dark
            ? PaintPuffLook(shade: PaintHex(9, 16, 25), shadeDeep: PaintHex(6, 11, 18), lit: PaintHex(20, 31, 38), lit2: PaintHex(18, 29, 38), hot: PaintHex(32, 42, 52), haze: haze, light: simd_normalize(PaintV3(0.72, -0.58, 0.38)), threshold: 0.36, sink: 0.46, detail: 0.5)
            : PaintPuffLook(shade: PaintHex(38, 72, 60), shadeDeep: PaintHex(26, 54, 52), lit: PaintHex(112, 148, 66), lit2: PaintHex(94, 138, 72), hot: PaintHex(198, 196, 104), haze: haze, light: simd_normalize(PaintV3(0.72, -0.58, 0.38)), threshold: 0.18, sink: 0.46, detail: 0.5)
        PaintLayPuffs(ref, puffs, look: leaves, warpX: wa, warpY: wb, grain: fine)

        // The farmhouse.
        paintFarm(into: ref, u: houseU, v: houseV, size: size, dark: dark)

        // Growth by touch: the hedges, and a skin of leaf on each crown so that its edge breaks up.
        let touchDeep = dark ? PaintHex(6, 11, 18) : PaintHex(36, 66, 56)
        let touchMid = dark ? PaintHex(14, 22, 31) : PaintHex(78, 116, 64)
        let touchLit = dark ? PaintHex(20, 30, 37) : PaintHex(132, 158, 72)
        let touchHot = dark ? PaintHex(32, 42, 52) : PaintHex(202, 196, 104)
        hedgeBushes.sort { $0.y < $1.y }
        var growth = SplitMix64(seed: 0x417F)
        func leafTouch(_ x: Float, _ y: Float, _ long: Float, _ colour: PaintV3) {
            ref.authored.append(PaintAuthoredStroke(x: x, y: y, angle: Float(growth.next(-1.4, 1.4)), length: long, width: long * Float(growth.next(0.45, 0.7)), color: colour, alpha: 0.95, load: 0.92, thick: 0.6, round: 0.6, feather: 0.06, taper: 0.3, tipIn: 0.55, tipOut: 0.9, comb: 0.8))
        }
        for bush in hedgeBushes {
            let col = min(w - 1, max(0, Int(bush.x * unitPx))), row = min(h - 1, max(0, Int(bush.y * unitPx)))
            let l = ref.level.at(col, row)
            if l >= 60 { continue }
            let n = max(3, min(13, Int(bush.r * unitPx * 0.55)))
            let ca = cos(bush.along), sa = sin(bush.along)
            for pass in 0..<3 {
                for _ in 0..<(pass == 2 ? n / 2 : n) {
                    let a = Float(growth.next(0, 6.283)), k = Float(growth.next()).squareRoot()
                    // Laid along the hedge: a long low heap, never a bead.
                    let across = sin(a) * k * 0.55, down = cos(a) * k * 1.9
                    var px = ca * down - sa * across, py = sa * down + ca * across
                    if pass == 1 { px = px * 0.85 + 0.10; py = py * 0.85 - 0.14 }
                    if pass == 2 { px = px * 0.7 + 0.24; py = py * 0.7 - 0.34 }
                    var colour = pass == 0 ? touchDeep : (pass == 1 ? touchMid : PaintMix(touchLit, touchHot, Float(growth.next(0, 0.55))))
                    colour = PaintMix(colour, haze, bush.air)
                    let long = max(0.0030, bush.r * Float(growth.next(0.5, 0.9)))
                    ref.authored.append(PaintAuthoredStroke(x: bush.x + px * bush.r, y: bush.y + py * bush.r * 0.85, angle: bush.along + Float(growth.next(-0.35, 0.35)), length: long, width: long * Float(growth.next(0.42, 0.62)), color: colour, alpha: 0.95, load: 0.92, thick: 0.5, round: 0.6, feather: 0.12, taper: 0.35, tipIn: 0.6, tipOut: 0.9, comb: 0.8))
                }
            }
        }
        for puff in puffs where puff.r > 0.0085 {
            let n = max(8, min(puff.level == 88 ? 320 : 170, Int(puff.r * puff.r * (puff.level == 88 ? 90000 : 36000))))
            for _ in 0..<n {
                let a = Float(growth.next(0, 6.283)), k = Float(growth.next()).squareRoot() * 1.08
                let px = cos(a) * k, py = sin(a) * k
                let x = puff.x + px * puff.r, y = puff.y + py * puff.r * puff.squash
                let col = min(w - 1, max(0, Int(x * unitPx))), row = min(h - 1, max(0, Int(y * unitPx)))
                let l = ref.level.at(col, row)
                if l >= 89 && l <= 95 { continue }
                let toLight = PaintSat(0.5 + px * 0.42 - py * 0.46 + Float(growth.next(-0.14, 0.14)))
                // Even the lit side has gaps in it, or it reads as one pad of paint.
                let gap = growth.next() < 0.30
                var colour = toLight > 0.72 && !gap ? PaintMix(touchLit, touchHot, Float(growth.next(0, 0.7))) : (toLight > 0.42 ? PaintMix(touchMid, touchLit, Float(growth.next(0, gap ? 0.3 : 1))) : PaintMix(touchDeep, touchMid, Float(growth.next(0, 1))))
                colour = PaintMix(colour, haze, puff.air)
                leafTouch(x, y, max(0.0028, min(0.026, puff.r * Float(growth.next(0.20, 0.36))) * Float(growth.next(0.6, 1))), colour)
            }
        }

        if dark {
            PaintAddStars(to: ref, count: 26, aspectTop: skyline * 0.72, seed: 0x5744) { x, y in
                y < skyline * 0.70 && ref.level.at(min(w - 1, max(0, Int(x * unitPx))), min(h - 1, max(0, Int(y * unitPx)))) < 200
            }
        }
        return ref
    }

    private static func paintFarm(into ref: PaintSceneRef, u: Float, v: Float, size: Float, dark: Bool) {
        // Long wall toward us and to the left, gable end to the right catching the sun.
        let L = 0.115 * size
        let H = L * 0.42
        let A = SIMD2<Float>(u - L * 0.62, v - L * 0.015)
        let B = SIMD2<Float>(u + L * 0.14, v + L * 0.045)
        let C = SIMD2<Float>(u + L * 0.50, v - L * 0.025)
        let up = SIMD2<Float>(0, -H)
        let Ap = A + up, Bp = B + up, Cp = C + up
        let apex = (Bp + Cp) * 0.5 + SIMD2<Float>(0, -H * 0.72)
        let rearApex = apex + (Ap - Bp)
        let eave = (Ap - Bp) * 0.05
        let dropA = SIMD2<Float>(0, H * 0.06)
        // The house's shadow lies away from the sun, on the grass: it stands on the ground.
        let shadowGround = dark ? PaintHex(8, 14, 24) : PaintHex(70, 104, 76)
        PaintFillPlane(ref, [A + SIMD2(L * 0.02, L * 0.02), B + SIMD2(0, L * 0.022), B + SIMD2(-L * 0.20, L * 0.075), A + SIMD2(-L * 0.42, L * 0.05)], color: shadowGround, PaintTouch(level: 89, angle: 0.08, hold: 1.5, detail: 0.7, soft: 0.2, wet: 0.2, long: 0.7, wide: 0.8))
        // A barn behind, to the left, darker.
        let bL = L * 0.72
        let bA = SIMD2<Float>(u - L * 1.10, v - L * 0.14), bB = SIMD2<Float>(bA.x + bL, bA.y + L * 0.03)
        let bH = H * 0.92
        let barnWall = dark ? PaintHex(20, 26, 38) : PaintHex(176, 112, 86)
        let barnRoof = dark ? PaintHex(26, 34, 50) : PaintHex(92, 92, 104)
        func touch(_ level: Float, _ angle: Float, detail: Float = 0.74) -> PaintTouch {
            PaintTouch(level: level, angle: angle, hold: 2, bend: 0.1, detail: detail, soft: 0.05, wet: 0.05, comb: 0.5, focus: 0.4, long: 0.6, wide: 0.7)
        }
        PaintFillPlane(ref, [bA, bB, bB + SIMD2(0, -bH), bA + SIMD2(0, -bH)], color: barnWall, touch(90, 0.05))
        PaintFillPlane(ref, [bA + SIMD2(-bL * 0.04, -bH), bB + SIMD2(bL * 0.04, -bH), SIMD2(bB.x - bL * 0.05, bB.y - bH * 1.62), SIMD2(bA.x + bL * 0.05, bA.y - bH * 1.62)], color: barnRoof, touch(91, 0.05))
        // White walls, warm on the sun's side, lavender on the other.
        let gable = dark ? PaintHex(66, 80, 100) : PaintHex(250, 240, 214)
        let wall = dark ? PaintHex(34, 44, 60) : PaintHex(192, 186, 200)
        let roofLit = dark ? PaintHex(40, 44, 58) : PaintHex(204, 112, 72)
        let roofDim = dark ? PaintHex(26, 30, 42) : PaintHex(164, 86, 64)
        PaintFillPlane(ref, [A, B, Bp, Ap], color: wall, color2: wall * 1.02, touch(92, 0.08))
        PaintFillPlane(ref, [B, C, Cp, apex, Bp], color: gable, touch(93, -0.2))
        // The roof, lapping past the walls.
        PaintFillPlane(ref, [Ap + eave + dropA, Bp - eave * 0.6 + dropA, apex - eave * 0.6, rearApex + eave], color: roofLit, color2: roofDim, touch(94, 0.08))
        // Chimney on the ridge.
        let chimneyAt = apex + (rearApex - apex) * 0.70 + SIMD2<Float>(0, H * 0.10)
        let cw = L * 0.052, ch = H * 0.40
        PaintFillPlane(ref, [chimneyAt + SIMD2(-cw, 0.002), chimneyAt + SIMD2(cw, 0.002), chimneyAt + SIMD2(cw, -ch), chimneyAt + SIMD2(-cw, -ch)], color: dark ? PaintHex(30, 36, 48) : PaintHex(150, 112, 96), touch(95, .pi / 2))
        // Windows and a door, by hand. At night two of them are lit: the only warm thing for miles.
        let glass = dark ? PaintHex(255, 196, 112) : PaintHex(58, 62, 84)
        let glassDim = dark ? PaintHex(255, 170, 88) : PaintHex(70, 72, 92)
        for (f, lit) in [(Float(0.20), true), (0.48, false), (0.76, true)] {
            let p = A + (B - A) * f + SIMD2(0, -H * 0.56)
            let col = dark && !lit ? PaintHex(14, 18, 28) : glassDim
            ref.authored.append(PaintAuthoredStroke(x: p.x, y: p.y, angle: .pi / 2 + 0.02, length: H * 0.34, width: L * 0.058, color: col, load: 1.1, thick: 0.4, round: 0.1, feather: 0, taper: 0, tipIn: 0.1, tipOut: 0.1, comb: 0.15))
        }
        let g = (B + C) * 0.5 + SIMD2(0, -H * 0.62)
        ref.authored.append(PaintAuthoredStroke(x: g.x, y: g.y, angle: .pi / 2, length: H * 0.34, width: L * 0.060, color: glass, load: 1.1, thick: 0.4, round: 0.1, feather: 0, taper: 0, tipIn: 0.1, tipOut: 0.1, comb: 0.15))
        let d = A + (B - A) * 0.62 + SIMD2(0, -H * 0.17)
        ref.authored.append(PaintAuthoredStroke(x: d.x, y: d.y, angle: .pi / 2, length: H * 0.36, width: L * 0.066, color: dark ? PaintHex(12, 14, 22) : PaintHex(92, 74, 66), load: 1.1, thick: 0.4, round: 0.1, feather: 0, taper: 0, tipIn: 0.1, tipOut: 0.1, comb: 0.15))
        // The line of the ridge and the eave, sure of itself.
        let ridgeMid = (apex + rearApex) * 0.5
        ref.authored.append(PaintAuthoredStroke(x: ridgeMid.x, y: ridgeMid.y, angle: atan2(rearApex.y - apex.y, rearApex.x - apex.x), length: simd_length(rearApex - apex) * 1.02, width: L * 0.022, color: dark ? PaintHex(64, 70, 86) : PaintHex(232, 150, 96), alpha: 0.9, load: 1, thick: 0.4, round: 0.2, taper: 0.1, tipIn: 0.3, tipOut: 0.3, comb: 0.3))
        if dark {
            // A breath of the window's light on the ground and the wall.
            let spill = (B + C) * 0.5 + SIMD2(L * 0.05, L * 0.05)
            ref.authored.append(PaintAuthoredStroke(x: spill.x, y: spill.y, angle: 0.1, length: L * 0.5, width: L * 0.09, color: PaintHex(120, 90, 66), alpha: 0.32, load: 0.9, thick: 0.1, round: 0.8, feather: 1, taper: 0.6, tipIn: 1, tipOut: 1, comb: 0.3))
        }
    }
}
