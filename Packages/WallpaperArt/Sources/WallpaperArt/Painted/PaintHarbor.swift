// A small fishing harbour: cottages stacked up a hill, a stone quay, boats on their moorings and all of it again in the water. At night the quay lamps run long down the water; there is no moon.

import Foundation
import simd

nonisolated enum PaintHarborScene {
    private struct BoatLook: Sendable {
        var hull, stripe, cabin, roof, glass, rail: PaintV3
    }

    private struct Colours: Sendable {
        var water: PaintV3
        var mast, line, wood, shadow: PaintV3
        var lamp: PaintV3, lampGlow: PaintV3, lampWater: PaintV3
        var ripple: PaintV3
    }

    /// A mark on a house, kept back until the whole town is laid so that it can be dropped if a house in front covers it.
    private struct Pending: Sendable {
        var stroke: PaintAuthoredStroke
        var level: Float
    }

    private static func pend(_ list: inout [Pending], level: Float, _ x: Float, _ y: Float, _ angle: Float, _ length: Float, _ width: Float, _ color: PaintV3, alpha: Float = 1, round: Float = 0.25, feather: Float = 0.04, taper: Float = 0.1, tip: Float = 0.25, comb: Float = 0.35, thick: Float = 0.45) {
        list.append(Pending(stroke: PaintAuthoredStroke(x: x, y: y, angle: angle, length: length, width: width, color: color, alpha: alpha, load: 1, thick: thick, round: round, feather: feather, taper: taper, tipIn: tip, tipOut: tip, comb: comb), level: level))
    }

    private static func mark(_ ref: PaintSceneRef, _ x: Float, _ y: Float, _ angle: Float, _ length: Float, _ width: Float, _ color: PaintV3, alpha: Float = 1, round: Float = 0.25, feather: Float = 0.04, taper: Float = 0.1, tip: Float = 0.25, comb: Float = 0.35, thick: Float = 0.45) {
        ref.authored.append(PaintAuthoredStroke(x: x, y: y, angle: angle, length: length, width: width, color: color, alpha: alpha, load: 1, thick: thick, round: round, feather: feather, taper: taper, tipIn: tip, tipOut: tip, comb: comb))
    }

    static func scene(width: Int, height: Int, dark: Bool) -> PaintSceneRef {
        let w = min(width, 590)
        let h = Int((Float(height) * Float(w) / Float(width)).rounded())
        let ref = PaintSceneRef(w: w, h: h)
        ref.dark = dark
        ref.ground = dark ? PaintHex(14, 20, 34) : PaintHex(150, 140, 120)
        let unitPx = Float(w)
        let aspect = Float(height) / Float(width)
        let size = min(1, pow(aspect / 2.168, 0.6))
        let scaleV = aspect / 2.168
        ref.lightDir = simd_normalize(SIMD2<Float>(0.8, -0.5))
        let farEdge = aspect * 0.452
        let quayFoot = aspect * 0.512

        // Sky: morning over the town.
        let dayStops: [(Float, PaintV3)] = [(0, PaintHex(164, 192, 206)), (0.42, PaintHex(204, 218, 216)), (0.76, PaintHex(236, 232, 214)), (1, PaintHex(244, 228, 200))]
        let nightStops: [(Float, PaintV3)] = [(0, PaintHex(6, 9, 22)), (0.46, PaintHex(11, 18, 40)), (0.80, PaintHex(26, 38, 70)), (1, PaintHex(58, 64, 94))]
        PaintLaySky(ref, sky: PaintGradient(stops: dark ? nightStops : dayStops), bottom: farEdge + 0.02, veil: dark ? PaintHex(26, 38, 62) : PaintHex(246, 234, 214), veilAmount: dark ? 0.28 : 0.30,
                    low: dark ? PaintHex(58, 50, 68) : PaintHex(246, 222, 188), lowAmount: dark ? 0.5 : 0.34, lowFrom: 0.5, lowTo: 1, streakScale: 12, seed: 0xA4B1)
        PaintLayBank(ref, top: farEdge - 0.30 * scaleV, bottom: farEdge - 0.02, lit: dark ? PaintHex(34, 42, 66) : PaintHex(252, 244, 226), shade: dark ? PaintHex(22, 30, 54) : PaintHex(190, 186, 200), amount: dark ? 0.75 : 0.92, level: 4, seed: 0xA4B9)
        let air = PaintNoise(seed: 0xA4B2)
        let wa = PaintNoiseField(w: w, h: h, step: 3) { u, v in Float(air.fbm(u * 9, v * 12, octaves: 2)) }
        let patch = PaintNoiseField(w: w, h: h, step: 4) { u, v in Float(air.fbm(u * 7 + 11, v * 9 + 5, octaves: 3)) }
        let fine = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(air.fbm(u * 30 + 41, v * 40, octaves: 2)) }

        // A far headland, thin with air, and the near hill the town climbs.
        let headFar = dark ? PaintHex(18, 26, 46) : PaintHex(190, 192, 206)
        let headLow = dark ? PaintHex(22, 30, 50) : PaintHex(236, 224, 206)
        let hillLit = dark ? PaintHex(36, 52, 68) : PaintHex(184, 180, 96)
        let hillGold = dark ? PaintHex(48, 62, 76) : PaintHex(224, 200, 110)
        let hillDim = dark ? PaintHex(20, 30, 44) : PaintHex(98, 124, 88)
        @Sendable func headTop(_ u: Float) -> Float {
            farEdge - (0.030 + 0.070 * PaintSstep(0.75, 0.05, u) + 0.028 * Float(air.fbm(Double(u) * 3 + 2, 7.2, octaves: 3))) * scaleV
        }
        @Sendable func hillTop(_ u: Float) -> Float {
            let rise = pow(PaintSstep(0.22, 1.12, u), 0.62) * (0.96 + 0.04 * u)
            let lump = Float(air.fbm(Double(u) * 3.6 + 9, 3.4, octaves: 3)) * 0.05 * PaintSstep(0.2, 0.5, u)
            return quayFoot - 0.02 - rise * (aspect * 0.300) + lump
        }
        PaintPar(h) { row in
            let v = (Float(row) + 0.5) / unitPx
            if v > quayFoot + 0.02 { return }
            for col in 0..<w {
                let i = row * w + col
                let u = (Float(col) + 0.5) / unitPx
                let hill = hillTop(u)
                if v >= hill {
                    let d = v - hill
                    var c = PaintMix(hillDim, hillLit, PaintSstep(-0.16, 0.12, patch.p[i]))
                    c = PaintMix(c, hillGold, PaintSstep(0.05, 0.26, patch.p[i]) * PaintSstep(0.07, 0.0, d) * 0.9 + PaintSstep(0.12, 0.30, patch.p[i]) * 0.5)
                    c *= 1 + 0.06 * fine.p[i]
                    ref.paintLay(col, row, c, PaintTouch(level: 8, angle: -0.35 + wa.p[i] * 0.5, hold: 1.2, bend: 0.2, detail: 0.32, soft: 0.2, wet: 0.14, blend: 0.05, steady: 0.3, comb: 0.65, long: 0.7, wide: 0.8))
                } else if v >= headTop(u) && u < 0.72 {
                    let c = PaintMix(headFar, headLow, PaintSstep(0, 0.08, v - headTop(u))) * (1 + 0.03 * wa.p[i])
                    ref.paintLay(col, row, c, PaintTouch(level: 6, angle: 0.04, hold: 1.5, bend: 0.1, detail: 0.14, soft: 0.45, wet: 0.2, blend: 0.14, steady: 0.4, comb: 0.5, long: 1, wide: 0.8))
                }
            }
        }

        var rng = SplitMix64(seed: 0xA4B3)
        // The water's edge: a low mole far off on the left, the quay on the right.
        var shoreTable = [Float](repeating: 0, count: w)
        for col in 0..<w {
            let u = (Float(col) + 0.5) / unitPx
            let wander = Float(air.fbm(Double(u) * 13 + 3, 2.2, octaves: 2)) * 0.012 * PaintSstep(0.27, 0.32, u) * PaintSstep(0.42, 0.37, u)
            shoreTable[col] = (PaintLerp(farEdge + 0.012, quayFoot, pow(PaintSstep(0.29, 0.41, u), 1.4)) + wander) * unitPx
        }
        let shore = shoreTable

        let rowStep = 0.062 * scaleV * size.squareRoot()
        let quayTop = quayFoot - 0.034
        let tiers = 5
        // Woods on the hill's shoulder, behind the roofs, touch by touch.
        let treeDeep = dark ? PaintHex(9, 14, 24) : PaintHex(64, 92, 70)
        let treeMid = dark ? PaintHex(14, 22, 33) : PaintHex(98, 124, 74)
        let treeLit = dark ? PaintHex(38, 52, 66) : PaintHex(168, 164, 90)
        for index in 0..<44 {
            let u = Float(rng.next(0.36, 1.08))
            // Some on the skyline in loose groups, most down the hill's face above the roofs.
            let onLine = index % 4 == 0
            let hillAt = hillTop(u)
            let roofLine = quayTop - Float(tiers) * rowStep - 0.012
            let v = onLine ? hillAt + Float(rng.next(0.002, 0.02)) : min(roofLine, hillAt + Float(rng.next(0.03, 0.22)) * scaleV)
            if v < hillAt { continue }
            let r = Float(rng.next(0.014, 0.046)) * size
            let count = min(90, Int(r * 2600))
            for pass in 0..<3 {
                for _ in 0..<(pass == 2 ? count / 2 : count) {
                    let a = Float(rng.next(0, 6.2832)), k = sqrt(Float(rng.next()))
                    var px = cos(a) * k, py = sin(a) * k
                    if pass == 1 { px = px * 0.85 + 0.12; py = py * 0.85 - 0.12 }
                    if pass == 2 { px = px * 0.6 + 0.34; py = py * 0.6 - 0.38 }
                    let colour = (pass == 0 ? treeDeep : (pass == 1 ? PaintMix(treeDeep, treeMid, 0.8) : PaintMix(treeMid, treeLit, Float(rng.next(0.2, 0.9))))) * Float(rng.next(0.94, 1.06))
                    let length = r * Float(rng.next(0.26, 0.54))
                    mark(ref, u + px * r, v + py * r * 0.8, Float(rng.next(-1.2, 1.2)), length, length * 0.55, colour, alpha: 0.96, round: 0.55, feather: 0.06, taper: 0.3, tip: 0.6, comb: 0.8, thick: 0.6)
                }
            }
        }

        // The town, top row first so each row stands in front of the one above.
        let houseWalls: [PaintV3] = dark
            ? [PaintHex(66, 78, 100), PaintHex(60, 66, 86), PaintHex(58, 58, 78), PaintHex(52, 68, 90), PaintHex(74, 84, 104)]
            : [PaintHex(246, 236, 216), PaintHex(238, 224, 198), PaintHex(232, 200, 142), PaintHex(244, 232, 208), PaintHex(226, 184, 128), PaintHex(238, 224, 198), PaintHex(196, 128, 100), PaintHex(206, 208, 198)]
        // Roofs come in two families and they come in groups: the old town in tile, a run of slate above the chapel.
        let tileRoofs: [PaintV3] = dark ? [PaintHex(26, 26, 40), PaintHex(30, 30, 44)] : [PaintHex(172, 100, 74), PaintHex(184, 114, 82)]
        let slateRoofs: [PaintV3] = dark ? [PaintHex(20, 24, 38), PaintHex(22, 28, 42)] : [PaintHex(122, 116, 124), PaintHex(108, 106, 118)]
        let townAir = dark ? PaintHex(24, 32, 50) : PaintHex(222, 220, 208)
        let sideShade = dark ? PaintHex(20, 26, 42) : PaintHex(150, 146, 172)
        let glassDay = PaintHex(58, 66, 88)
        let glassOff = PaintHex(13, 17, 28)
        let glassLit = PaintHex(255, 196, 112)
        struct LitWindow: Sendable { var x, y: Float }
        var levelBase: Float = 40
        var litWindows: [LitWindow] = []
        var pending: [Pending] = []
        for tier in stride(from: tiers - 1, through: 0, by: -1) {
            let t = Float(tier)
            let base = quayTop - t * rowStep
            var u = 0.345 + t * 0.082 + Float(rng.next(0, 0.02))
            var index = 0
            while u < 1.10 {
                let length = (0.098 - t * 0.008) * Float(rng.next(0.86, 1.18)) * size
                let height = length * Float(rng.next(0.54, 0.76))
                let away = PaintSat(t * 0.13 + PaintSstep(0.62, 0.36, u) * 0.26) * (dark ? 0.55 : 1)
                let wall = PaintMix(houseWalls[Int(rng.next() * Double(houseWalls.count)) % houseWalls.count], townAir, away)
                let slate = Float(air.fbm(Double(u) * 2.4 + 3, Double(t) * 0.8 + 1.5, octaves: 2)) > 0.10
                let family = slate ? slateRoofs : tileRoofs
                let roof = PaintMix(family[Int(rng.next() * Double(family.count)) % family.count], townAir, away * 1.1)
                let jitter = Float(rng.next(-0.006, 0.006))
                house(ref, x: u, base: base + jitter, length: length, height: height, gableFront: index % 3 == 1, wall: wall, side: PaintMix(PaintMix(sideShade, wall, 0.42), townAir, away), roof: roof,
                      glass: dark ? glassOff : PaintMix(glassDay, wall, away), lit: glassLit, dark: dark, level: levelBase, front: tier == 0, pending: &pending, rng: &rng) { x, y in
                    litWindows.append(LitWindow(x: x, y: y))
                }
                levelBase = levelBase < 170 ? levelBase + 3 : 40
                u += length * Float(rng.next(1.26, 1.5))
                index += 1
            }
            // A small stone chapel tower rises behind the second row from the top.
            if tier == 3 {
                let tx = 0.735, tw: Float = 0.040 * size, th: Float = 0.150 * size * scaleV.squareRoot()
                let bx = Float(tx), by = base - rowStep * 0.2
                let lit = dark ? PaintHex(50, 58, 78) : PaintHex(232, 214, 184)
                let dim = dark ? PaintHex(22, 28, 44) : PaintHex(150, 142, 164)
                PaintFillPlane(ref, [SIMD2(bx - tw * 0.5, by), SIMD2(bx + tw * 0.5, by), SIMD2(bx + tw * 0.5, by - th), SIMD2(bx - tw * 0.5, by - th)], color: lit, PaintTouch(level: 190, angle: .pi / 2, hold: 2, bend: 0.1, detail: 0.74, soft: 0.05, wet: 0.05, comb: 0.5, focus: 0.4, long: 0.6, wide: 0.7))
                PaintFillPlane(ref, [SIMD2(bx - tw * 0.5, by), SIMD2(bx - tw * 0.05, by), SIMD2(bx - tw * 0.05, by - th), SIMD2(bx - tw * 0.5, by - th)], color: dim, PaintTouch(level: 191, angle: .pi / 2, hold: 2, bend: 0.1, detail: 0.74, soft: 0.05, wet: 0.05, comb: 0.5, focus: 0.4, long: 0.6, wide: 0.7))
                PaintFillPlane(ref, [SIMD2(bx - tw * 0.62, by - th), SIMD2(bx + tw * 0.62, by - th), SIMD2(bx, by - th - tw * 1.5)], color: dark ? PaintHex(26, 30, 46) : PaintHex(96, 102, 124), PaintTouch(level: 192, angle: 1.1, hold: 2, bend: 0.1, detail: 0.74, soft: 0.05, wet: 0.05, comb: 0.5, focus: 0.4, long: 0.6, wide: 0.7))
                mark(ref, bx + tw * 0.2, by - th * 0.78, .pi / 2, th * 0.14, tw * 0.22, dark ? glassOff : glassDay, round: 0.2)
            }
        }

        for item in pending {
            let col = min(w - 1, max(0, Int(item.stroke.x * unitPx))), row = min(h - 1, max(0, Int(item.stroke.y * unitPx)))
            if abs(ref.level.at(col, row) - item.level) < 0.5 { ref.authored.append(item.stroke) }
        }

        // The quay: a stone wall in courses, its top catching the light, running out of the picture to the right.
        let stoneA = dark ? PaintHex(24, 30, 44) : PaintHex(176, 162, 142)
        let stoneB = dark ? PaintHex(16, 21, 34) : PaintHex(140, 128, 118)
        let stoneTop = dark ? PaintHex(44, 52, 70) : PaintHex(236, 220, 188)
        let stoneWet = dark ? PaintHex(9, 13, 24) : PaintHex(70, 72, 76)
        let quayStart: Float = 0.315
        let quayRow = max(0, Int((quayTop - 0.008) * unitPx)), quayEnd = min(h - 1, Int(quayFoot * unitPx) + 2)
        if quayRow <= quayEnd {
            PaintPar(quayEnd - quayRow + 1) { index in
                let row = quayRow + index
                let v = (Float(row) + 0.5) / unitPx
                for col in 0..<w {
                    let u = (Float(col) + 0.5) / unitPx
                    if u < quayStart - (v - quayTop) * 0.7 { continue }
                    if Float(row) > shore[col] + 1 { continue }
                    let i = row * w + col
                    if v < quayTop {
                        ref.paintLay(col, row, stoneTop * (1 + 0.04 * fine.p[i]), PaintTouch(level: 34, angle: 0, hold: 2, bend: 0, detail: 0.8, soft: 0.04, wet: 0.02, blend: 0, steady: 0.7, comb: 0.3, long: 1.1, wide: 0.4))
                    } else {
                        var c = PaintMix(stoneB, stoneA, PaintSstep(-0.12, 0.14, patch.p[i] + fine.p[i] * 0.5))
                        c = PaintMix(c, stoneWet, PaintSstep(quayFoot - 0.012, quayFoot, v) * 0.85)
                        ref.paintLay(col, row, c, PaintTouch(level: 35, angle: 0.01, hold: 1.8, bend: 0, detail: 0.7, soft: 0.05, wet: 0.04, blend: 0.02, steady: 0.6, comb: 0.5, long: 0.7, wide: 0.5))
                    }
                }
            }
        }
        // Courses of stone, by hand.
        let courseDark = dark ? PaintHex(10, 14, 26) : PaintHex(112, 102, 100)
        let courseLit = dark ? PaintHex(34, 40, 56) : PaintHex(214, 200, 172)
        for _ in 0..<(Int(150 * size)) {
            let u = Float(rng.next(Double(quayStart), 1.04)), v = Float(rng.next(Double(quayTop + 0.003), Double(quayFoot - 0.006)))
            let colour = rng.next() < 0.6 ? courseDark : courseLit
            mark(ref, u, v, Float(rng.next(-0.03, 0.03)), Float(rng.next(0.012, 0.030)) * size, 0.0024, colour, alpha: 0.72, round: 0.3, feather: 0.1, taper: 0.3, tip: 0.5, comb: 0.5)
        }

        // The mole, far off to the left, with a little beacon at its end.
        let moleY = farEdge + 0.012
        let moleRow = max(0, Int((moleY - 0.012) * unitPx)), moleEnd = Int(moleY * unitPx) + 1
        PaintPar(max(0, min(h, moleEnd + 1) - moleRow)) { index in
            let row = moleRow + index
            let v = (Float(row) + 0.5) / unitPx
            for col in 0..<w {
                let u = (Float(col) + 0.5) / unitPx
                if u > 0.27 + (moleY - v) * 0.8 { continue }
                let c = v < moleY - 0.008 ? stoneTop * 0.92 : PaintMix(stoneB, stoneA, 0.5)
                ref.paintLay(col, row, c, PaintTouch(level: 36, angle: 0, hold: 2, bend: 0, detail: 0.5, soft: 0.3, wet: 0.1, blend: 0.05, steady: 0.5, comb: 0.5, long: 1.0, wide: 0.5))
            }
        }

        // The water: all of it again, softened, drawn out downward, going to deep green-blue toward us.
        let deep = dark ? PaintHex(10, 19, 38) : PaintHex(36, 96, 108)
        let middle = dark ? PaintHex(22, 38, 64) : PaintHex(92, 150, 152)
        let sheen = dark ? PaintHex(44, 60, 88) : PaintHex(228, 226, 206)
        let shallow = dark ? PaintHex(26, 42, 70) : PaintHex(172, 208, 198)
        let soft = ref.rgb.blurred(max(1, w / 340))
        let waterLevels = ref.level.copied()
        PaintPar(h) { row in
            for col in 0..<w {
                let sr = shore[col]
                if Float(row) < sr { continue }
                let i = row * w + col
                let depth = (Float(row) + 0.5 - sr) / unitPx
                let wobble = (wa.p[i] + fine.p[i] * 0.7) * unitPx * (0.0024 + depth * 0.0170)
                let smear = unitPx * (0.0012 + depth * 0.009)
                var mirrored = PaintV3.zero
                for k in 0..<5 {
                    mirrored += soft.sample3(Float(col) + 0.5 + wobble, 2 * sr - (Float(row) + 0.5) + (Float(k) - 2) * smear)
                }
                mirrored *= 0.2
                let value = PaintLum(mirrored)
                let toward = PaintSat(depth / max(0.1, aspect - quayFoot))
                // The town's own colours come back, a little richer for the water; they go before the hill does.
                mirrored = PaintV3(repeating: value) + (mirrored - PaintV3(repeating: value)) * (dark ? 1.0 : 1.35)
                var c = mirrored * PaintLerp(1, 0.82, PaintSstep(0.35, 0.8, value)) * (dark ? 0.92 : 0.96)
                // Through a pale aqua first, so that warm reflections don't go to grey on their way to the teal.
                c = PaintMix(c, shallow, PaintSstep(0.0, 0.16, toward) * (dark ? 0.3 : 0.26))
                c = PaintMix(c, middle, PaintSstep(0.03, 0.20, toward) * (dark ? 0.86 : 0.97))
                // Under the mole and along the shelving foot of the hill there's only sky to give back.
                let u = (Float(col) + 0.5) / unitPx
                c = PaintMix(c, shallow, PaintSstep(0.44, 0.30, u) * (dark ? 0.3 : 0.62))
                c = PaintMix(c, deep, PaintSstep(0.34, 0.92, toward) * (dark ? 0.94 : 0.86))
                let band = wa.p[i] + patch.p[i] * 0.6
                c = PaintMix(c, sheen, PaintSstep(0.14, 0.42, band) * PaintSstep(0.60, 0.05, toward) * (dark ? 0.16 : 0.24))
                let flat = PaintSstep(0.12, 0.30, toward)
                c *= 1 + flat * 0.09 * fine.p[i]
                c *= 1 - 0.28 * PaintSstep(0.008, 0.0, depth)
                ref.rgb.set3(col, row, c)
                let sourceRow = min(h - 1, max(0, Int(2 * sr - (Float(row) + 0.5))))
                let sourceCol = min(w - 1, max(0, Int(Float(col) + 0.5 + wobble)))
                let source = waterLevels.at(sourceCol, sourceRow)
                // The mirror keeps big groups only: no house has an edge of its own down here.
                ref.level.p[i] = flat + wa.p[i] * 0.5 > 0.5 ? 9 : (source >= 38 ? 230 : (source >= 30 ? 231 : (source >= 7.5 ? 232 : 233)))
                // Sky comes back as a level sheen; only solid things pull down in long strokes.
                let level = flat > 0.5 || source < 7.5
                ref.setDir(col, row, angle: level ? 0.01 : .pi / 2, strength: 4)
                ref.setBendToForm(col, row, 0)
                ref.setShape(col, row, length: level ? 1.5 : 1, width: level ? 0.62 : 1)
                ref.pullDown.p[i] = level ? 0 : 1
                ref.steady.p[i] = 0.3
                ref.comb.p[i] = 0.4
                ref.detail.p[i] = PaintLerp(0.30, 0.22, toward)
                ref.soft.p[i] = PaintSat(0.70 + 0.3 * PaintSstep(0.02, 0.30, depth))
                ref.wet.p[i] = 0.35
                ref.blend.p[i] = 0.42
                ref.focus.p[i] = 0
            }
        }
        ref.pruneLevels(minArea: Int(0.0030 * unitPx * unitPx), only: Set(200...240))

        let colours = dark
            ? Colours(water: deep, mast: PaintHex(40, 48, 64), line: PaintHex(52, 60, 78), wood: PaintHex(14, 16, 26), shadow: PaintHex(5, 9, 20), lamp: PaintHex(255, 222, 156), lampGlow: PaintHex(186, 128, 76), lampWater: PaintHex(242, 176, 96), ripple: PaintHex(44, 60, 90))
            : Colours(water: deep, mast: PaintHex(86, 74, 66), line: PaintHex(92, 84, 80), wood: PaintHex(82, 62, 50), shadow: PaintHex(24, 62, 76), lamp: PaintHex(128, 104, 84), lampGlow: PaintHex(128, 104, 84), lampWater: PaintHex(128, 104, 84), ripple: PaintHex(236, 234, 214))

        // Long flat lights on the water, between the boats.
        for _ in 0..<340 {
            let t = pow(Float(rng.next()), 1.35)
            let v = quayFoot + 0.01 + t * (aspect - quayFoot)
            let length = PaintLerp(0.018, 0.12, t) * Float(rng.next(0.6, 1.4))
            let x = Float(rng.next(-0.05, 1.05))
            // A pass of water colour or of sky, each just a thread.
            let tint = rng.next() < 0.5 ? colours.ripple : PaintMix(deep, middle, Float(rng.next(0.2, 1)))
            mark(ref, x, v, Float(rng.next(-0.01, 0.01)), length, PaintLerp(0.0016, 0.0044, t), tint, alpha: dark ? 0.30 : Float(rng.next(0.24, 0.50)), round: 0.7, feather: 0.4, taper: 0.7, tip: 0.8, comb: 0.5, thick: 0.2)
        }

        // Quay lamps and what they do to the water.
        let lampHeight = 0.060 * size
        for (index, u) in [Float(0.385), 0.515, 0.645, 0.775, 0.905, 1.015].enumerated() {
            let top = quayTop - 0.003 - lampHeight
            mark(ref, u, quayTop - 0.003 - lampHeight * 0.5, .pi / 2, lampHeight, dark ? 0.0034 : 0.0024, dark ? PaintHex(10, 12, 20) : PaintHex(122, 98, 78), alpha: dark ? 1 : 0.85, round: 0.3, feather: 0.15)
            mark(ref, u, top, 0, 0.0074 * size, 0.0074 * size, colours.lamp, round: 0.8, feather: 0.1, taper: 0, tip: 0.7, comb: 0.2)
            if dark {
                mark(ref, u, top, 0, 0.056 * size, 0.056 * size, colours.lampGlow, alpha: 0.40, round: 1, feather: 1, taper: 0, tip: 1, comb: 0.2, thick: 0.05)
                mark(ref, u, quayTop + 0.006, 0, 0.062 * size, 0.024 * size, colours.lampGlow, alpha: 0.42, round: 1, feather: 1, taper: 0, tip: 1, comb: 0.2, thick: 0.05)
                lampColumn(ref, x: u, top: quayFoot + 0.002, length: (0.30 + 0.05 * Float(index % 3)) * scaleV, colour: colours.lampWater, strength: 1, rng: &rng)
            }
        }
        if dark {
            // Windows on the lowest row send down a thinner, shorter gleam.
            for window in litWindows.prefix(10) {
                lampColumn(ref, x: window.x, top: quayFoot + 0.002, length: 0.11 * scaleV, colour: colours.lampWater * 0.85, strength: 0.42, rng: &rng)
            }
        }

        // The beacon on the mole.
        let beaconX: Float = 0.245, beaconH = 0.040 * size
        mark(ref, beaconX, moleY - 0.010 - beaconH * 0.5, .pi / 2, beaconH, 0.012 * size, dark ? PaintHex(46, 54, 74) : PaintHex(250, 244, 230), round: 0.2)
        mark(ref, beaconX - 0.003 * size, moleY - 0.010 - beaconH * 0.5, .pi / 2, beaconH, 0.005 * size, dark ? PaintHex(20, 26, 42) : PaintHex(170, 170, 190), round: 0.2)
        mark(ref, beaconX, moleY - 0.010 - beaconH - 0.004 * size, .pi / 2, 0.010 * size, 0.014 * size, dark ? PaintHex(255, 222, 156) : PaintHex(190, 82, 66), round: 0.4)
        if dark {
            mark(ref, beaconX, moleY - 0.010 - beaconH - 0.004 * size, 0, 0.040 * size, 0.040 * size, colours.lampGlow, alpha: 0.42, round: 1, feather: 1, taper: 0, tip: 1, comb: 0.2, thick: 0.05)
            lampColumn(ref, x: beaconX, top: moleY + 0.002, length: 0.16 * scaleV, colour: colours.lampWater, strength: 0.7, rng: &rng)
        }

        // The boats, far to near.
        let boats: [(u: Float, y: Float, len: Float, dir: Float, look: BoatLook, rigged: Bool, cabin: Bool)] = [
            (0.14, 0.490, 0.100, 1, look(dark, hull: PaintHex(244, 240, 226), night: PaintHex(40, 48, 66), stripe: PaintHex(70, 118, 150)), true, true),
            (0.45, 0.545, 0.120, -1, look(dark, hull: PaintHex(68, 110, 142), night: PaintHex(26, 36, 56), stripe: PaintHex(244, 236, 214)), true, true),
            (0.80, 0.575, 0.170, -1, look(dark, hull: PaintHex(200, 84, 62), night: PaintHex(38, 30, 44), stripe: PaintHex(246, 232, 200)), true, true),
            (0.27, 0.625, 0.270, 1, look(dark, hull: PaintHex(38, 110, 106), night: PaintHex(18, 32, 42), stripe: PaintHex(244, 238, 216)), true, true),
            (0.70, 0.755, 0.390, -1, look(dark, hull: PaintHex(246, 240, 224), night: PaintHex(44, 52, 72), stripe: PaintHex(44, 76, 120)), true, true),
            (0.20, 0.885, 0.330, 1, look(dark, hull: PaintHex(222, 164, 92), night: PaintHex(34, 32, 44), stripe: PaintHex(150, 72, 54)), false, false),
        ]
        for (index, boat) in boats.enumerated() {
            paintBoat(ref, x: boat.u, y: aspect * boat.y, length: boat.len * size, dir: boat.dir, look: boat.look, colours: colours, rigged: boat.rigged, cabin: boat.cabin, dark: dark, lit: index == 4 || index == 2, rng: &rng)
        }
        // Mooring buoys.
        for (u, y, colour) in [(0.60, 0.620, PaintHex(192, 116, 92)), (0.42, 0.790, PaintHex(196, 124, 98))] as [(Float, Float, PaintV3)] {
            let vy = aspect * y, r = PaintLerp(0.006, 0.017, PaintSat((y - 0.5) / 0.4)) * size
            let tone = dark ? colour * 0.32 : colour
            mark(ref, u, vy - r * 0.2, 0, r * 2, r * 1.5, tone, round: 0.9, feather: 0.05, taper: 0, tip: 0.8, comb: 0.3)
            mark(ref, u + r * 0.3, vy - r * 0.6, 0.2, r * 0.9, r * 0.5, PaintMix(tone, dark ? PaintHex(90, 100, 124) : PaintHex(255, 246, 226), 0.6), alpha: 0.9, round: 0.9, feather: 0.1, taper: 0.3, tip: 0.7, comb: 0.3)
            mark(ref, u, vy + r * 1.1, .pi / 2, r * 2.2, r * 1.2, tone * 0.72, alpha: 0.5, round: 0.9, feather: 0.4, taper: 0.4, tip: 0.8, comb: 0.5, thick: 0.1)
            mark(ref, u, vy + r * 0.62, 0, r * 2.6, r * 0.4, colours.shadow, alpha: 0.6, round: 0.9, feather: 0.4, taper: 0.5, tip: 0.8, comb: 0.5, thick: 0.1)
        }

        if dark {
            PaintAddStars(to: ref, count: 26, aspectTop: aspect * 0.22, seed: 0x5748) { x, y in y < hillTop(x) - 0.03 && y < farEdge * 0.7 }
        }
        return ref
    }

    private static func look(_ dark: Bool, hull: PaintV3, night: PaintV3, stripe: PaintV3) -> BoatLook {
        if dark {
            return BoatLook(hull: night, stripe: stripe * 0.30, cabin: PaintHex(40, 46, 62), roof: PaintHex(26, 32, 46), glass: PaintHex(255, 190, 110), rail: PaintHex(72, 84, 106))
        }
        return BoatLook(hull: hull, stripe: stripe, cabin: PaintHex(246, 238, 218), roof: PaintHex(150, 92, 66), glass: PaintHex(58, 70, 92), rail: PaintHex(252, 246, 228))
    }

    /// A light's road on rippled water: a column of short level dashes, wider and fainter as it nears us.
    private static func lampColumn(_ ref: PaintSceneRef, x: Float, top: Float, length: Float, colour: PaintV3, strength: Float, rng: inout SplitMix64) {
        let dashes = Int(22 + 44 * strength)
        for k in 0..<dashes {
            let f = (Float(k) + Float(rng.next())) / Float(dashes)
            let y = top + length * pow(f, 1.25)
            let spread = (0.0014 + 0.012 * f) * Float(rng.next(-1, 1))
            let dashLength = (0.008 + 0.040 * f) * Float(rng.next(0.5, 1.3)) * (0.6 + 0.4 * strength)
            let dim = (1 - pow(f, 0.8)) * 0.92 + 0.06
            let tint = PaintMix(colour, colour * PaintV3(0.8, 0.55, 0.5), f)
            mark(ref, x + spread, y, Float(rng.next(-0.02, 0.02)), dashLength, 0.0024 + 0.0034 * f, tint, alpha: dim * strength, round: 0.7, feather: 0.25, taper: 0.6, tip: 0.8, comb: 0.3, thick: 0.25)
        }
    }

    private static func house(_ ref: PaintSceneRef, x: Float, base: Float, length L: Float, height H: Float, gableFront: Bool, wall: PaintV3, side: PaintV3, roof: PaintV3, glass: PaintV3, lit: PaintV3, dark: Bool, level: Float, front: Bool, pending: inout [Pending], rng: inout SplitMix64, litWindow: (Float, Float) -> Void) {
        func touch(_ level: Float, _ angle: Float) -> PaintTouch {
            PaintTouch(level: level, angle: angle, hold: 2, bend: 0.1, detail: 0.62, soft: 0.14, wet: 0.08, comb: 0.6, focus: 0.3, long: 0.7, wide: 0.8)
        }
        func lost(_ level: Float, _ angle: Float) -> PaintTouch {
            PaintTouch(level: level, angle: angle, hold: 1.6, bend: 0.1, detail: 0.42, soft: 0.5, wet: 0.24, blend: 0.1, comb: 0.6, focus: 0.1, long: 0.8, wide: 0.9)
        }
        let x0 = x, x1 = x + L
        let roofDim = roof * 0.82
        if gableFront {
            // Gable to the water: a tall narrow house.
            let w1 = x0 + L * 0.72
            let apexX = (x0 + w1) * 0.5, R = L * 0.40
            let depth = L * 0.26
            PaintFillPlane(ref, [SIMD2(x0, base), SIMD2(w1, base), SIMD2(w1, base - H), SIMD2(apexX, base - H - R), SIMD2(x0, base - H)], color: wall, touch(level, 0.05))
            // The slope that runs back and to the right takes the sun.
            PaintFillPlane(ref, [SIMD2(apexX, base - H - R), SIMD2(w1 + L * 0.02, base - H + 0.002), SIMD2(w1 + depth, base - H - depth * 0.18), SIMD2(apexX + depth, base - H - R - depth * 0.18)], color: roof, color2: roofDim, touch(level + 1, 0.9))
            PaintFillPlane(ref, [SIMD2(w1, base), SIMD2(w1 + depth, base - depth * 0.18), SIMD2(w1 + depth, base - H - depth * 0.18), SIMD2(w1, base - H)], color: side, lost(level + 2, 0.05))
            // The eave's shadow on the wall.
            pend(&pending, level: level, (x0 + w1) * 0.5, base - H + L * 0.016, 0, w1 - x0, L * 0.05, wall * (dark ? 0.5 : 0.62), alpha: 0.42, round: 0.5, feather: 0.5, taper: 0.1, tip: 0.5, comb: 0.5, thick: 0.1)
            windows(x0: x0, x1: w1, base: base, height: H + R * 0.2, wall: wall, glass: glass, lit: lit, dark: dark, L: L, level: level, front: front, pending: &pending, rng: &rng, litWindow: litWindow)
        } else {
            let depth = L * 0.30, R = H * 0.60
            let FL = SIMD2<Float>(x0, base - H), FR = SIMD2<Float>(x1, base - H)
            let SB = SIMD2<Float>(x1 + depth, base - depth * 0.18), SR = SIMD2<Float>(x1 + depth, base - H - depth * 0.18)
            let apex = (FR + SR) * 0.5 + SIMD2<Float>(0, -R)
            let rear = apex + (FL - FR)
            // Wall to the water takes the sky; the gable end takes the sun.
            PaintFillPlane(ref, [SIMD2(x0, base), SIMD2(x1, base), FR, FL], color: PaintMix(wall, side, 0.34), lost(level, 0.05))
            PaintFillPlane(ref, [SIMD2(x1, base), SB, SR, apex, FR], color: PaintMix(wall, dark ? wall : PaintHex(255, 240, 210), 0.5) * (dark ? 0.72 : 1.0), touch(level + 1, -0.2))
            PaintFillPlane(ref, [FL + SIMD2(-L * 0.02, 0.0015), FR + SIMD2(L * 0.01, 0.0015), apex, rear + SIMD2(-L * 0.02, 0)], color: roof, color2: roofDim, touch(level + 2, 0.08))
            pend(&pending, level: level + 2, (apex.x + rear.x) * 0.5, apex.y + L * 0.006, 0, simd_length(apex - rear) * 1.02, L * 0.018, PaintMix(roof, dark ? PaintHex(70, 80, 100) : PaintHex(255, 216, 170), 0.55), alpha: 0.9, round: 0.2, taper: 0.1, tip: 0.3, comb: 0.3)
            // A chimney on some of them.
            if rng.next() < 0.55 {
                let c = rear + (apex - rear) * Float(rng.next(0.15, 0.8))
                mark(ref, c.x, c.y - H * 0.10, .pi / 2, H * 0.30, L * 0.058, dark ? PaintHex(24, 28, 42) : PaintHex(150, 106, 90), round: 0.1, feather: 0.02, taper: 0, tip: 0.1, comb: 0.2)
            }
            pend(&pending, level: level, (x0 + x1) * 0.5, base - H + L * 0.016, 0, x1 - x0, L * 0.05, wall * (dark ? 0.5 : 0.62), alpha: 0.42, round: 0.5, feather: 0.5, taper: 0.1, tip: 0.5, comb: 0.5, thick: 0.1)
            windows(x0: x0, x1: x1, base: base, height: H, wall: wall, glass: glass, lit: lit, dark: dark, L: L, level: level, front: front, pending: &pending, rng: &rng, litWindow: litWindow)
        }
    }

    private static func windows(x0: Float, x1: Float, base: Float, height: Float, wall: PaintV3, glass: PaintV3, lit: PaintV3, dark: Bool, L: Float, level: Float, front: Bool, pending: inout [Pending], rng: inout SplitMix64, litWindow: (Float, Float) -> Void) {
        // Each house has its own windows: tall slots, small squares, or wide ones with a shutter's worth of wall between.
        let style = rng.next()
        let paneWide = L * (style < 0.4 ? 0.050 : (style < 0.75 ? 0.070 : 0.086))
        let paneTall = height * (style < 0.4 ? 0.25 : (style < 0.75 ? 0.17 : 0.14))
        let across = max(1, Int((x1 - x0) / (L * Float(rng.next(0.30, 0.48)))))
        let skip = rng.next(0.16, 0.40)
        let doorAt = Int(rng.next(0, Double(across)))
        for floor in 0..<2 {
            let y = base - height * (floor == 0 ? 0.28 : 0.68) + height * Float(rng.next(-0.02, 0.02))
            for k in 0..<across {
                let x = x0 + (x1 - x0) * (Float(k) + 0.5) / Float(across) + L * Float(rng.next(-0.022, 0.022))
                // A front house has a door on the quay.
                if front && floor == 0 && k == doorAt && !dark {
                    pend(&pending, level: level, x, base - height * 0.20, .pi / 2, height * 0.40, L * 0.078, PaintMix(glass, wall, 0.25), round: 0.2, feather: 0.1, taper: 0, tip: 0.2, comb: 0.4, thick: 0.35)
                    continue
                }
                if rng.next() < skip { continue }
                let isLit = dark && rng.next() < 0.34
                // By day a window holds some sky and some of its wall; only a few go quite dark.
                let pane = dark ? glass : PaintMix(glass, wall, Float(rng.next(0.14, 0.50)))
                pend(&pending, level: level, x, y, .pi / 2, paneTall * Float(rng.next(0.88, 1.12)), paneWide * Float(rng.next(0.9, 1.1)), isLit ? lit : pane, round: 0.25, feather: 0.12, taper: 0, tip: 0.25, comb: 0.45, thick: 0.35)
                if isLit {
                    pend(&pending, level: level, x, y, 0, L * 0.26, L * 0.26, lit * 0.6, alpha: 0.18, round: 1, feather: 1, taper: 0, tip: 1, comb: 0.2, thick: 0.05)
                    if front { litWindow(x, y) }
                } else if !dark && rng.next() < 0.5 {
                    // A sill of light under it.
                    pend(&pending, level: level, x, y + paneTall * 0.6, 0, paneWide * 1.2, L * 0.012, PaintMix(wall, PaintHex(255, 250, 236), 0.6), alpha: 0.8, round: 0.3, feather: 0.2, taper: 0.2, tip: 0.4, comb: 0.4)
                }
            }
        }
    }

    private static func paintBoat(_ ref: PaintSceneRef, x: Float, y: Float, length L: Float, dir: Float, look: BoatLook, colours: Colours, rigged: Bool, cabin: Bool, dark: Bool, lit: Bool, rng: inout SplitMix64) {
        let unitPx = Float(ref.w)
        let H = L * (cabin ? 0.20 : 0.17)
        let rows = max(5, min(30, Int(H * unitPx / 1.3)))
        // Sheer: the top of the hull at a point along it (-0.5 stern, +0.5 bow).
        func sheer(_ s: Float) -> Float {
            let rise = s > -0.1 ? pow((s + 0.1) / 0.6, 2) : pow((s + 0.1) / 0.4, 2) * 0.14
            return 0.74 + 0.40 * rise
        }
        // What the water sees of it.
        func waterTint(_ px: Float, _ py: Float) -> PaintV3 {
            let col = min(ref.w - 1, max(0, Int(px * unitPx))), row = min(ref.h - 1, max(0, Int(py * unitPx)))
            return ref.rgb.get3(col, row)
        }
        // Reflection first, so the boat sits on it.
        let reflectRows = max(5, min(13, rows / 2))
        let reach = H * 2.3
        for k in 0..<reflectRows {
            let f = (Float(k) + 0.5) / Float(reflectRows)
            let py = y + reach * f
            // How high up the boat this row mirrors, in hull heights.
            let up = f * reach / H
            let shrink = 1 - f * 0.20
            let wobble = sin(f * 21 + x * 40) * L * 0.016 * (0.3 + f * 1.4)
            let rowHigh = reach / Float(reflectRows) * Float(rng.next(1.5, 2.2))
            if up < 1.0 {
                let tone = up < 0.52 ? look.hull : (up < 0.68 ? look.stripe : look.hull * 0.92)
                let colour = PaintMix(tone * 0.88, waterTint(x, py), 0.18 + 0.56 * f)
                // Whole while it is close under the hull; a deep hull's foot breaks only in its last rows.
                mark(ref, x + wobble, py, Float(rng.next(-0.010, 0.010)), 0.94 * shrink * L * Float(rng.next(0.97, 1.03)), rowHigh, colour, alpha: 0.88 - 0.36 * f, round: 0.7, feather: 0.4, taper: 0.35, tip: 0.8, comb: 0.5, thick: 0.12)
            } else if cabin && up < 1.72 {
                let colour = PaintMix(look.cabin * 0.86, waterTint(x, py), 0.30 + 0.50 * f)
                mark(ref, x + dir * -0.16 * L + wobble, py, Float(rng.next(-0.012, 0.012)), 0.30 * L, rowHigh, colour, alpha: 0.64 - 0.36 * f, round: 0.7, feather: 0.5, taper: 0.4, tip: 0.8, comb: 0.4, thick: 0.1)
            }
        }
        // The water's own light lies across it in a few long level passes.
        for _ in 0..<(L > 0.15 ? 5 : 2) {
            let py = y + H * 0.7 + reach * Float(rng.next(0.05, 0.62))
            mark(ref, x + L * Float(rng.next(-0.32, 0.32)), py, Float(rng.next(-0.008, 0.008)), L * Float(rng.next(0.22, 0.46)), max(0.0024, H * 0.055), colours.ripple, alpha: dark ? 0.16 : 0.34, round: 0.7, feather: 0.45, taper: 0.7, tip: 0.8, comb: 0.5, thick: 0.15)
        }
        let shadowLen = L * 1.02
        mark(ref, x, y + H * 0.05, 0, shadowLen, H * 0.20, colours.shadow, alpha: dark ? 0.8 : 0.42, round: 0.9, feather: 0.5, taper: 0.5, tip: 0.8, comb: 0.4, thick: 0.05)

        // Rigging and mast behind the cabin, thin and sure.
        let mastS: Float = cabin ? 0.08 : 0
        let mastX = x + dir * mastS * L
        let topY = y - H * sheer(mastS)
        if rigged {
            let mastH = L * 0.54
            let mx = mastX, my = topY - mastH
            mark(ref, mx, topY - mastH * 0.5, .pi / 2, mastH, max(0.0028, L * 0.012), colours.mast, round: 0.2, taper: 0.5, tip: 0.2, comb: 0.3)
            // Stays to bow and stern.
            for (sx, sy) in [(x + dir * 0.47 * L, y - H * 1.10), (x - dir * 0.46 * L, y - H * 0.80)] {
                let dx = sx - mx, dy = sy - my
                mark(ref, (sx + mx) * 0.5, (sy + my) * 0.5, atan2(dy, dx), (dx * dx + dy * dy).squareRoot(), max(0.0016, L * 0.0034), colours.line, alpha: dark ? 0.75 : 0.7, round: 0.3, taper: 0.1, tip: 0.2, comb: 0.3, thick: 0.15)
            }
            // A boom running aft with a furled sail along it.
            let boomY = topY - mastH * 0.30
            mark(ref, mx - dir * L * 0.17, boomY + L * 0.006, -0.10 * dir, L * 0.34, max(0.0024, L * 0.014), dark ? PaintHex(34, 40, 54) : PaintHex(214, 196, 168), round: 0.5, taper: 0.2, tip: 0.5, comb: 0.5)
            // Its reflection, broken up.
            for k in 0..<7 {
                let f = (Float(k) + 0.5) / 7
                let py = y + H + mastH * 0.8 * f
                mark(ref, mx + sin(f * 17 + x * 30) * L * 0.014 * (1 + f * 2), py, .pi / 2 + Float(rng.next(-0.2, 0.2)), mastH * 0.12, max(0.0022, L * 0.008), colours.mast, alpha: 0.30 * (1 - f * 0.7), round: 0.6, feather: 0.5, taper: 0.5, tip: 0.8, comb: 0.5, thick: 0.08)
            }
            if dark && lit {
                mark(ref, mx, my + 0.002, 0, 0.0085, 0.0085, colours.lamp, round: 0.9, feather: 0.1, taper: 0, tip: 0.7, comb: 0.2)
                mark(ref, mx, my + 0.002, 0, 0.05, 0.05, colours.lampGlow, alpha: 0.42, round: 1, feather: 1, taper: 0, tip: 1, comb: 0.2, thick: 0.05)
                lampColumn(ref, x: mx, top: y + H * 0.2, length: L * 0.72, colour: colours.lampWater, strength: 0.55, rng: &rng)
            }
        }

        // The wheelhouse, standing on the deck behind the mast.
        if cabin {
            let c0: Float = -0.30, c1: Float = -0.02
            let cTop = y - H * 0.74 - H * 0.92
            let bottom = y - H * 0.70
            let cx0 = x + dir * c0 * L, cx1 = x + dir * c1 * L
            let midX = (cx0 + cx1) * 0.5, wide = abs(cx1 - cx0)
            let rowsCabin = max(3, Int((bottom - cTop) * unitPx / 1.6))
            for k in 0..<rowsCabin {
                let f = (Float(k) + 0.5) / Float(rowsCabin)
                mark(ref, midX, cTop + (bottom - cTop) * f, 0, wide, (bottom - cTop) / Float(rowsCabin) * 1.8, look.cabin * (0.94 + 0.08 * f), round: 0.3, feather: 0.06, taper: 0, tip: 0.3, comb: 0.15)
            }
            // Its forward face in shade or light, by which way the boat lies.
            let faceX = dir > 0 ? cx1 - wide * 0.14 : cx1 + wide * 0.14
            mark(ref, faceX, (cTop + bottom) * 0.5, .pi / 2, bottom - cTop, wide * 0.28, look.cabin * (dir > 0 ? 1.05 : 0.72), round: 0.15, feather: 0.02, taper: 0, tip: 0.15, comb: 0.5)
            // Windows.
            let panes = 3
            for k in 0..<panes {
                let px = midX - wide * 0.34 + wide * 0.68 * Float(k) / Float(panes - 1) * 0.86
                mark(ref, px, cTop + (bottom - cTop) * 0.36, .pi / 2, (bottom - cTop) * 0.34, wide * 0.17, look.glass, round: 0.1, feather: 0, taper: 0, tip: 0.1, comb: 0.15, thick: 0.35)
            }
            mark(ref, midX, cTop, 0.0, wide * 1.2, max(0.003, H * 0.14), look.roof, round: 0.3, taper: 0.1, tip: 0.3, comb: 0.4)
            mark(ref, midX, cTop - H * 0.05, 0, wide * 1.14, max(0.0015, H * 0.035), PaintMix(look.roof, look.rail, 0.5), alpha: 0.9, round: 0.3, taper: 0.1, tip: 0.3, comb: 0.3)
            if dark && lit { mark(ref, midX, cTop + (bottom - cTop) * 0.36, 0, wide * 1.3, wide * 0.9, look.glass * 0.5, alpha: 0.18, round: 1, feather: 1, taper: 0, tip: 1, comb: 0.2, thick: 0.05) }
        }

        // The hull, row by row from the water up, so the sheer comes out by itself.
        for k in 0..<rows {
            let r = (Float(k) + 0.5) / Float(rows) * 1.14
            let py = y - H * r
            let bow = 0.44 + 0.10 * r
            let stern = -0.47 - 0.02 * r
            // Above the low part of the sheer only the bow rises this high.
            var from = stern
            if r > 0.74 {
                let need = PaintSat((r - 0.74) / 0.40).squareRoot()
                from = -0.1 + 0.6 * need
            }
            if from >= bow { continue }
            let span = bow - from
            var tone = look.hull * (0.80 + 0.26 * PaintSat(r / 0.9))
            if r < 0.14 { tone = PaintMix(tone, colours.shadow, 0.55) }
            if r > 0.52 && r < 0.66 { tone = look.stripe }
            tone *= Float(rng.next(0.95, 1.05))
            // One long pass to a row, the way a hull gets painted: no joints for the water to show through.
            mark(ref, x + dir * (from + bow) * 0.5 * L, py, Float(rng.next(-0.004, 0.004)), span * L * 1.02, H / Float(rows) * 2.4, tone, round: 0.3, feather: 0.05, taper: 0.04, tip: 0.3, comb: 0.2, thick: 0.6)
        }
        // A sweep down the bow and one down the stern close off the row ends, in the row's own colour.
        for (foot, head, wide, top) in [(Float(0.432), Float(0.532), H * 0.13, Float(1.12)), (Float(-0.462), Float(-0.482), H * 0.13, Float(0.76))] {
            let pieces = 4
            for piece in 0..<pieces {
                let r0 = top * Float(piece) / Float(pieces), r1 = top * Float(piece + 1) / Float(pieces)
                let midR = (r0 + r1) * 0.5
                let a = SIMD2<Float>(x + dir * PaintLerp(foot, head, r0 / top) * L, y - H * r0)
                let b = SIMD2<Float>(x + dir * PaintLerp(foot, head, r1 / top) * L, y - H * r1)
                let d = b - a
                var tone = look.hull * (0.80 + 0.26 * PaintSat(midR / 0.9))
                if midR < 0.14 { tone = PaintMix(tone, colours.shadow, 0.55) }
                mark(ref, (a.x + b.x) * 0.5, (a.y + b.y) * 0.5, atan2(d.y, d.x), simd_length(d) * 1.2, max(0.0030, wide), tone, round: 0.45, feather: 0.1, taper: 0.1, tip: 0.5, comb: 0.15, thick: 0.5)
            }
        }
        // A light gunwale along the sheer.
        let segments = 12
        for k in 0..<segments {
            let s0 = -0.48 + 1.0 * Float(k) / Float(segments), s1 = -0.48 + 1.0 * Float(k + 1) / Float(segments)
            let ax = x + dir * s0 * L, bx = x + dir * s1 * L
            let ay = y - H * sheer(s0), by = y - H * sheer(s1)
            let dx = bx - ax, dy = by - ay
            mark(ref, (ax + bx) * 0.5, (ay + by) * 0.5, atan2(dy, dx), (dx * dx + dy * dy).squareRoot() * 1.1, max(0.0022, H * 0.07), look.rail, alpha: dark ? 0.8 : 1, round: 0.3, taper: 0.05, tip: 0.2, comb: 0.3)
        }
        // A bow line going down into the water, and a couple of fenders.
        let bowX = x + dir * 0.50 * L, bowY = y - H * 0.95
        let fallX = x + dir * 0.555 * L
        mark(ref, (bowX + fallX) * 0.5, (bowY + y + H * 0.1) * 0.5, atan2(y + H * 0.1 - bowY, fallX - bowX), ((fallX - bowX) * (fallX - bowX) + (y + H * 0.1 - bowY) * (y + H * 0.1 - bowY)).squareRoot(), max(0.0015, L * 0.0035), colours.line, alpha: 0.75, round: 0.3, taper: 0.1, tip: 0.2, comb: 0.3, thick: 0.15)
        if L > 0.15 {
            for s in [Float(-0.18), 0.14] {
                let fx = x + dir * s * L, fy = y - H * 0.40
                mark(ref, fx, fy, .pi / 2, H * 0.34, H * 0.15, dark ? PaintHex(60, 66, 84) : PaintHex(248, 240, 220), round: 0.9, feather: 0.05, taper: 0, tip: 0.8, comb: 0.3)
            }
        }
        if !cabin {
            // An open boat: its thwarts and a pair of oars laid along it.
            for s in [Float(-0.2), 0.08] {
                mark(ref, x + dir * s * L, y - H * 0.80, 0.0, L * 0.11, H * 0.09, colours.wood, round: 0.3, taper: 0.1, tip: 0.3, comb: 0.5)
            }
            mark(ref, x - dir * L * 0.02, y - H * 0.98, -0.05 * dir, L * 0.62, max(0.0024, H * 0.07), dark ? PaintHex(40, 40, 54) : PaintHex(204, 166, 112), round: 0.4, taper: 0.2, tip: 0.3, comb: 0.5)
        }
    }
}
