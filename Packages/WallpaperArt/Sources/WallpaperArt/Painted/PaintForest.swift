// A birch wood: pale trunks in depth, a path winding back to a bright opening, great masses of leaf overhead, long shadows thrown toward us and pools of sun between them. At night the birches are silver on deep blue and the moon comes through in faint patches.

import Foundation
import simd

nonisolated enum PaintForestScene {
    private struct Trunk: Sendable {
        var x, base, width, lean: Float
        var depth: Float        // 0 far, 1 near.
        var level: Float
        var seed: Int32
        var bow: Float
        var reach: Float        // How far its shadow runs toward us.
    }

    static func scene(width: Int, height: Int, dark: Bool) -> PaintSceneRef {
        let w = min(width, 590)
        let h = Int((Float(height) * Float(w) / Float(width)).rounded())
        let ref = PaintSceneRef(w: w, h: h)
        ref.dark = dark
        ref.ground = dark ? PaintHex(14, 20, 34) : PaintHex(126, 118, 78)
        let unitPx = Float(w)
        let aspect = Float(height) / Float(width)
        let size = min(1, pow(aspect / 2.168, 0.6))
        // The light comes from up the path, ahead and to the right.
        ref.lightDir = simd_normalize(SIMD2<Float>(0.5, -0.86))
        let openU: Float = 0.545, openV = aspect * 0.535
        let groundLine = aspect * 0.585
        let floorSpan = aspect - groundLine

        let warp = PaintNoise(seed: 0xB1C4)
        let wa = PaintNoiseField(w: w, h: h, step: 3) { u, v in Float(warp.fbm(u * 8, v * 8, octaves: 2)) }
        let wb = PaintNoiseField(w: w, h: h, step: 3) { u, v in Float(warp.fbm(u * 8 + 9, v * 8 - 4, octaves: 2)) }
        let slow = PaintNoiseField(w: w, h: h, step: 6) { u, v in Float(warp.fbm(u * 2.2 + 21, v * 2.0 - 3, octaves: 3)) }
        let fine = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(warp.fbm(u * 30 + 41, v * 30, octaves: 2)) }
        // Leaf edges break up on this, where a smooth warp would leave round balloons.
        let leafX = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(warp.fbm(u * 24 + 3, v * 24 + 17, octaves: 2)) * 2.6 + Float(warp.fbm(u * 8, v * 8, octaves: 2)) * 0.7 }
        let leafY = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(warp.fbm(u * 24 - 11, v * 24 + 5, octaves: 2)) * 2.6 + Float(warp.fbm(u * 8 + 9, v * 8 - 4, octaves: 2)) * 0.7 }
        // Pools of sun, laid out on the ground itself: small and flat far off, big near us.
        let pools = PaintNoiseField(w: w, h: h, step: 2) { u, v in
            let t = max(0, (Float(v) - groundLine) / floorSpan)
            let s = 0.11 + t * 0.74
            return Float(warp.fbm(Double((Float(u) - openU) / s) * 1.5 + 5, Double(1 / s) * 5.2 + 7, octaves: 2))
        }

        // Behind everything: the glow of the clearing, going off into leaf shade. No shafts: the light is air, and patches on the ground.
        let glowHot = dark ? PaintHex(64, 84, 112) : PaintHex(250, 236, 186)
        let glowMid = dark ? PaintHex(34, 50, 76) : PaintHex(224, 218, 150)
        let glowFar = dark ? PaintHex(16, 26, 46) : PaintHex(148, 170, 122)
        let canopyTop = dark ? PaintHex(9, 14, 28) : PaintHex(104, 136, 110)
        PaintPar(h) { row in
            let v = (Float(row) + 0.5) / unitPx
            for col in 0..<w {
                let i = row * w + col
                let u = (Float(col) + 0.5) / unitPx
                let dx = u - openU, dy = (v - openV) * 0.62
                let d = (dx * dx + dy * dy).squareRoot() + slow.p[i] * 0.09
                var c = PaintMix(glowHot, glowMid, PaintSstep(0.04, 0.26, d))
                c = PaintMix(c, glowFar, PaintSstep(0.22, 0.56, d))
                c = PaintMix(c, canopyTop, PaintSstep(aspect * 0.34, aspect * 0.04, v) * 0.85)
                ref.rgb.set3(col, row, c)
                ref.setDir(col, row, angle: -0.12 + slow.p[i] * 1.1, strength: 0.7)
                ref.formWeight.p[i] = 0.05
                ref.detail.p[i] = 0
                ref.soft.p[i] = 0.95
                ref.wet.p[i] = 0.7
                ref.blend.p[i] = 0.5
                ref.steady.p[i] = 0.8
                ref.level.p[i] = 1
                ref.setShape(col, row, length: 0.7, width: 1.15)
            }
        }

        var rng = SplitMix64(seed: 0xB1C5)

        // The trees, far to near. Each leans its own way; no two stand quite parallel.
        var farTrunks: [Trunk] = [], midTrunks: [Trunk] = [], nearTrunks: [Trunk] = []
        for k in 0..<11 {
            let u = Float(k) / 10 * 1.1 - 0.05 + Float(rng.next(-0.03, 0.03))
            if abs(u - openU) < 0.06 { continue }
            farTrunks.append(Trunk(x: u, base: groundLine + Float(rng.next(-0.002, 0.014)), width: Float(rng.next(0.0085, 0.0125)) * size, lean: Float(rng.next(-0.032, 0.032)), depth: 0.0, level: 30, seed: Int32(k), bow: Float(rng.next(-0.012, 0.012)), reach: 0))
        }
        for k in 0..<7 {
            let u = Float(k) / 6 * 1.08 - 0.04 + Float(rng.next(-0.035, 0.035))
            if abs(u - openU) < 0.085 { continue }
            farTrunks.append(Trunk(x: u, base: groundLine + 0.030 + Float(rng.next(0, 0.04)), width: Float(rng.next(0.015, 0.021)) * size, lean: Float(rng.next(-0.052, 0.052)), depth: 0.3, level: 34, seed: 30 + Int32(k), bow: Float(rng.next(-0.024, 0.024)), reach: Float(rng.next(0.10, 0.20))))
        }
        // Middle ground: real trees either side of the path, some growing as a pair from one foot.
        let middle: [(Float, Float, Float, Float, Float, Float)] = [(0.205, 0.100, 0.025, -0.060, -0.024, 0.42), (0.238, 0.104, 0.019, 0.050, 0.024, 0.26), (0.355, 0.056, 0.019, 0.036, 0.018, 0.34), (0.715, 0.066, 0.020, -0.048, 0.020, 0.30), (0.812, 0.122, 0.028, 0.066, -0.030, 0.46), (0.848, 0.126, 0.020, -0.040, 0.026, 0.22), (0.110, 0.170, 0.033, 0.040, 0.030, 0.52)]
        for (k, m) in middle.enumerated() {
            midTrunks.append(Trunk(x: m.0, base: groundLine + m.1, width: m.2 * size, lean: m.3, depth: 0.62, level: 38, seed: 60 + Int32(k), bow: m.4, reach: m.5 * aspect / 2.168))
        }
        // Near: a big birch each side, off the frame at the top, feet in the moss.
        nearTrunks.append(Trunk(x: -0.004, base: aspect * 0.925, width: 0.098 * size, lean: 0.090, depth: 1, level: 44, seed: 90, bow: 0.030, reach: 0.30))
        nearTrunks.append(Trunk(x: 0.945, base: aspect * 0.860, width: 0.070 * size, lean: -0.075, depth: 0.9, level: 42, seed: 91, bow: -0.026, reach: 0.40))

        // Their shadows, thrown toward us. Each spreads a little as it comes, and runs out on the moss.
        let shadow = PaintBuf(w: w, h: h)
        for trunk in farTrunks.filter({ $0.depth > 0.2 }) + midTrunks + nearTrunks {
            let spread = max(-0.62, min(0.62, (trunk.x - openU) * 1.1))
            let rowA = max(0, Int(trunk.base * unitPx)), rowB = min(h - 1, Int((trunk.base + trunk.reach) * unitPx))
            if rowA >= rowB { continue }
            let t0 = trunk
            PaintPar(rowB - rowA + 1) { index in
                let row = rowA + index
                let v = (Float(row) + 0.5) / unitPx
                let along = (v - t0.base) / t0.reach
                let centre = t0.x + spread * (v - t0.base)
                let half = t0.width * (0.46 + 0.62 * along)
                let left = max(0, Int((centre - half * 1.5 - 0.02) * unitPx)), right = min(w - 1, Int((centre + half * 1.5 + 0.02) * unitPx))
                if left > right { return }
                for col in left...right {
                    let i = row * w + col
                    let u = (Float(col) + 0.5) / unitPx
                    let x = (u - centre + wa.p[i] * 0.022 * (0.3 + along)) / half
                    // The far end breaks up into the moss.
                    let keep = PaintSstep(1.0, 0.72, along + wb.p[i] * 0.34)
                    let cover = PaintSstep(1.06, 0.86, abs(x)) * keep
                    if cover > shadow.p[i] { shadow.p[i] = cover }
                }
            }
        }

        // The floor of the wood, in two values only: sun and shade, moss and path. Everything else about it is brushwork.
        let mossShadeFar = dark ? PaintHex(19, 31, 43) : PaintHex(122, 146, 92)
        let mossShadeMid = dark ? PaintHex(13, 23, 33) : PaintHex(76, 114, 78)
        let mossShadeNear = dark ? PaintHex(8, 14, 24) : PaintHex(46, 80, 62)
        let mossLitFar = dark ? PaintHex(44, 58, 74) : PaintHex(232, 224, 138)
        let mossLitMid = dark ? PaintHex(31, 45, 59) : PaintHex(170, 180, 86)
        let mossLitNear = dark ? PaintHex(21, 33, 45) : PaintHex(122, 148, 72)
        let pathShadeFar = dark ? PaintHex(33, 44, 58) : PaintHex(196, 176, 128)
        let pathShadeMid = dark ? PaintHex(22, 30, 42) : PaintHex(144, 122, 94)
        let pathShadeNear = dark ? PaintHex(14, 20, 32) : PaintHex(112, 96, 80)
        let pathLitFar = dark ? PaintHex(66, 80, 98) : PaintHex(248, 232, 174)
        let pathLitMid = dark ? PaintHex(46, 58, 74) : PaintHex(226, 196, 134)
        let pathLitNear = dark ? PaintHex(31, 41, 55) : PaintHex(192, 158, 108)
        @Sendable func three(_ a: PaintV3, _ b: PaintV3, _ c: PaintV3, _ t: Float) -> PaintV3 {
            t < 0.42 ? PaintMix(a, b, t / 0.42) : PaintMix(b, c, (t - 0.42) / 0.58)
        }
        // Where the path runs: in from the bottom, swinging left, right, and away into the light.
        @Sendable func pathCentre(_ t: Float) -> Float {
            // t: 0 at the opening, 1 at the bottom of the picture.
            let swing = sin(t * 5.2 + 0.2) * 0.17 * PaintSstep(0.0, 0.7, t)
            return openU + (0.42 - openU) * t + swing
        }
        @Sendable func pathHalf(_ t: Float) -> Float { (0.012 + 0.21 * pow(t, 1.5)) * size }
        PaintPar(h) { row in
            let v = (Float(row) + 0.5) / unitPx
            if v < groundLine - 0.03 { return }
            let t = PaintSat((v - groundLine) / floorSpan)
            let centre = pathCentre(t)
            let half = pathHalf(t)
            let mossShade = three(mossShadeFar, mossShadeMid, mossShadeNear, t)
            let mossLit = three(mossLitFar, mossLitMid, mossLitNear, t)
            let pathShade = three(pathShadeFar, pathShadeMid, pathShadeNear, t)
            let pathLit = three(pathLitFar, pathLitMid, pathLitNear, t)
            // More of the floor is in the sun going back toward the opening, and the corners under us are in shade.
            let bias = PaintLerp(0.30, -0.15, PaintSstep(0.12, 0.86, t))
            for col in 0..<w {
                let i = row * w + col
                let u = (Float(col) + 0.5) / unitPx
                // The far edge of the floor wanders behind the trunks.
                if v < groundLine + slow.p[i] * 0.03 { continue }
                let toEdge = abs(u - 0.5) * 2
                let pool = pools.p[i] + bias - 0.10 * PaintSstep(0.5, 1.0, toEdge) * t + wa.p[i] * 0.03
                let shade = shadow.p[i]
                let lit = PaintSstep(-0.015, 0.015, pool) * (1 - PaintSstep(0.34, 0.60, shade))
                let isLit = lit > 0.5
                let x = (u - centre + wa.p[i] * 0.016 * (0.4 + t)) / half
                let inPath = abs(x) < 1
                // Found in places, lost in others.
                let hard = PaintSstep(-0.06, 0.10, slow.p[i] + wb.p[i] * 0.3)
                var c = inPath ? PaintMix(pathShade, pathLit, lit) : PaintMix(mossShade, mossLit, lit)
                c *= 1 + (inPath ? 0.07 : 0.10) * slow.p[i] + 0.05 * fine.p[i]
                let dx = u - openU
                c = PaintMix(c, glowHot, exp(-(dx * dx) / 0.05) * PaintSstep(0.42, 0.0, t) * 0.62)
                let level: Float = inPath ? (isLit ? 4 : 3) : (isLit ? 6 : 5)
                let edgeSoft: Float = inPath && abs(x) > 0.86 ? PaintLerp(0.55, 0.06, hard) : (isLit ? 0.22 : 0.46)
                ref.paintLay(col, row, c, PaintTouch(level: level, angle: 0.02 + wa.p[i] * 0.22, hold: 1.5, bend: 0.1, detail: 0.13, soft: edgeSoft, wet: isLit ? 0.16 : 0.34, blend: isLit ? 0.06 : 0.22, steady: 0.5, comb: 0.65, long: 1.15, wide: PaintLerp(0.62, 1.05, t)))
            }
        }
        ref.pruneLevels(minArea: Int(0.00028 * unitPx * unitPx), only: [3, 4, 5, 6])

        let haze = dark ? PaintHex(34, 50, 76) : PaintHex(222, 224, 166)
        let lightDir = simd_normalize(PaintV3(0.26, -0.70, 0.46))
        let leaves = dark
            ? PaintPuffLook(shade: PaintHex(10, 16, 29), shadeDeep: PaintHex(7, 12, 24), lit: PaintHex(18, 29, 43), lit2: PaintHex(16, 27, 42), hot: PaintHex(34, 46, 62), haze: haze, light: lightDir, threshold: 0.26, sink: 0.42, detail: 0.30, long: 0.8, wide: 1.1)
            : PaintPuffLook(shade: PaintHex(84, 122, 84), shadeDeep: PaintHex(66, 106, 80), lit: PaintHex(142, 164, 86), lit2: PaintHex(118, 152, 88), hot: PaintHex(216, 208, 122), haze: haze, light: lightDir, threshold: 0.12, sink: 0.42, detail: 0.30, long: 0.8, wide: 1.1)

        // One great mass of leaf. First its body, solid and in shade, with a scalloped edge all the way round; then heaps of lit leaf on it, all answering to the one big form, so it turns from the light as a whole.
        func mass(_ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float, crowns: Int, r: Float, air: Float, level: Float, into out: inout [PaintPuff]) {
            let start = out.count
            let domeX = cx + rx * 0.10, domeY = cy - ry * 0.10, domeR = max(rx, ry) * 1.12
            let bodyCount = Int(min(420, max(40, rx * ry / (r * r) * 26)))
            var body: [PaintPuff] = []
            for _ in 0..<bodyCount {
                let a = Float(rng.next(0, 6.2832)), d = Float(rng.next()).squareRoot()
                let lobes = 1 + 0.16 * sin(a * 3 + cx * 19) + 0.10 * sin(a * 7 + cy * 13)
                let x = cx + cos(a) * d * rx * lobes, y = cy + sin(a) * d * ry * lobes
                let away = abs(x - openU)
                if y > aspect * (0.345 + 0.25 * away) && away < 0.30 { continue }
                body.append(PaintPuff(x: x, y: y, r: r * Float(rng.next(0.26, 0.62)), squash: 0.86, sunk: 1, domeX: domeX, domeY: domeY, domeR: domeR, air: air, tint: Float(rng.next(0, 1)), level: level))
            }
            body.sort { $0.y < $1.y }
            out += body
            let lumpStart = out.count
            for _ in 0..<crowns {
                let a = Float(rng.next(0, 6.2832)), d = Float(rng.next()).squareRoot() * 0.86
                let x = cx + cos(a) * d * rx, y = cy + sin(a) * d * ry - ry * 0.10
                // Nothing hangs in the way of the opening.
                let away = abs(x - openU)
                if y > aspect * (0.320 + 0.25 * away) && away < 0.30 { continue }
                PaintCrown(x: x, y: y, r: r * Float(rng.next(0.70, 1.20)), squash: 0.84, air: air, tint: Float(rng.next(0, 1)), level: level, generations: 3, sunkBias: (y - cy) / ry * 0.46, rng: &rng, into: &out)
            }
            for k in lumpStart..<out.count {
                out[k].domeX = domeX
                out[k].domeY = domeY
                out[k].domeR = domeR
            }
            out[lumpStart...].sort { $0.y < $1.y }
            _ = start
        }

        // The farthest leaves first, thin with air, behind every tree.
        var farLeaves: [PaintPuff] = []
        mass(-0.04, aspect * 0.20, 0.46, aspect * 0.215, crowns: 16, r: 0.064 * size, air: dark ? 0.46 : 0.56, level: 10, into: &farLeaves)
        mass(1.04, aspect * 0.18, 0.44, aspect * 0.205, crowns: 16, r: 0.064 * size, air: dark ? 0.46 : 0.56, level: 10, into: &farLeaves)
        mass(0.52, aspect * 0.06, 0.60, aspect * 0.145, crowns: 18, r: 0.066 * size, air: dark ? 0.42 : 0.50, level: 10, into: &farLeaves)
        PaintLayPuffs(ref, farLeaves, look: leaves, warpX: leafX, warpY: leafY, grain: fine)

        // Soft understorey along the far edge of the floor, where the trunks' feet and the glow meet.
        var under: [PaintPuff] = []
        for _ in 0..<54 {
            let u = Float(rng.next(-0.05, 1.05))
            let away = abs(u - openU)
            if away < 0.05 { continue }
            PaintCrown(x: u, y: groundLine - Float(rng.next(-0.012, 0.03)) * PaintSstep(0.03, 0.2, away), r: Float(rng.next(0.020, 0.044)) * size, squash: 0.62, air: dark ? 0.40 : 0.46, tint: Float(rng.next(0, 1)), level: 8, generations: 2, rng: &rng, into: &under)
        }
        under.sort { $0.y < $1.y }
        PaintLayPuffs(ref, under, look: leaves, warpX: wa, warpY: wb, grain: fine)

        // Trunks: pale and slight far off, big and running out of the frame near us. Lit on the side toward the clearing.
        let creamLit = dark ? PaintHex(116, 132, 158) : PaintHex(250, 242, 220)
        let creamMid = dark ? PaintHex(62, 76, 102) : PaintHex(216, 210, 196)
        let lavender = dark ? PaintHex(26, 36, 56) : PaintHex(158, 156, 164)
        let lavenderDeep = dark ? PaintHex(15, 21, 36) : PaintHex(112, 112, 124)
        let mist = dark ? PaintHex(34, 48, 74) : PaintHex(226, 226, 184)
        let barkDark = dark ? PaintHex(8, 11, 20) : PaintHex(46, 44, 50)
        
        func paintTrunks(_ list: [Trunk]) {
            for trunk in list {
                let up = -0.05 - trunk.base  // Trunks run well off the top.
                // Below the foot, room for the roots.
                let rowBottom = min(h - 1, Int((trunk.base + trunk.width * 0.40) * unitPx))
                if rowBottom < 0 { continue }
                let rootPhase = Float(trunk.seed) * 1.7
                let airHere = PaintLerp(dark ? 0.42 : 0.62, 0, PaintSstep(0, 0.62, trunk.depth))
                PaintPar(rowBottom + 1) { row in
                    let v = (Float(row) + 0.5) / unitPx
                    let t = PaintSat((v - trunk.base) / up)   // 0 at the foot, 1 at the top.
                    let centreU = trunk.x + trunk.lean * t + sin(t * 3.1) * trunk.bow
                    // Birches taper as they go up, and flare where they meet the ground.
                    let halfW = trunk.width * 0.5 * (1 - 0.56 * t) * (1 + 0.55 * PaintSstep(0.05, 0, t))
                    let cx = centreU * unitPx, halfPx = max(1.0, halfW * unitPx)
                    let colA = max(0, Int(cx - halfPx - 2)), colB = min(w - 1, Int(cx + halfPx + 2))
                    if colA > colB { return }
                    // Which side the light is on: toward the clearing.
                    let litSide: Float = centreU < openU ? 1 : -1
                    // Under the leaves the bark goes into their shade; at night it all but goes out.
                    let overhead = PaintSstep(aspect * 0.46, aspect * 0.10, v) * (dark ? 0.70 : 0.42)
                    for col in colA...colB {
                        let i = row * w + col
                        let x = ((Float(col) + 0.5 - cx) / halfPx) + fine.p[i] * 0.07
                        if abs(x) > 1 { continue }
                        // The trunk doesn't end on a ruled line: it goes in over its roots.
                        if v > trunk.base + trunk.width * (0.10 + 0.22 * (1 - x * x) + 0.09 * sin(x * 7.3 + rootPhase)) { continue }
                        let facing = x * litSide
                        // Passing light on the bark: stretches of sun and stretches of leaf shade.
                        let passing = PaintSstep(-0.10, 0.12, slow.p[i] + Float(trunk.seed) * 0.0007 + wb.p[i] * 0.2)
                        let form = PaintSstep(-0.52, 0.16, facing)
                        var c = PaintMix(lavender, creamMid, form)
                        c = PaintMix(c, creamLit, PaintSstep(0.20, 0.72, facing) * PaintLerp(0.25, 1, passing))
                        c = PaintMix(c, lavenderDeep, PaintSstep(-0.52, -0.95, facing))
                        c *= 1 + 0.05 * fine.p[i]
                        c = PaintMix(c, lavender, overhead)
                        // The foot goes dark into the moss.
                        c = PaintMix(c, lavenderDeep, PaintSstep(0.045, 0.0, t) * 0.7)
                        c = PaintMix(c, mist, airHere)
                        ref.paintLay(col, row, c, PaintTouch(level: trunk.level + (form > 0.5 ? 1 : 0), angle: .pi / 2 - trunk.lean, hold: 2.2, bend: 0.5, detail: 0.86, soft: 0.05, wet: 0.08, blend: 0, steady: 0.7, comb: 0.5, focus: trunk.depth > 0.6 ? 0.25 : 0, long: 0.72, wide: 0.74))
                    }
                }
                if trunk.depth < 0.28 { continue }
                // Black marks of the bark, by hand: short and level, gathered near old branch scars, more toward the foot.
                let marks = Int(PaintLerp(12, 46, trunk.depth))
                let litSideNow: Float = trunk.x < openU ? 1 : -1
                for _ in 0..<marks {
                    let t = pow(Float(rng.next()), 1.5) * 0.98 + 0.01
                    let v = trunk.base + up * t
                    if v < -0.02 || v > aspect { continue }
                    let cu = trunk.x + trunk.lean * t + sin(t * 3.1) * trunk.bow
                    let half = trunk.width * 0.5 * (1 - 0.56 * t)
                    let side = Float(rng.next(-0.95, 0.75)) * litSideNow
                    let long = half * Float(rng.next(0.22, 0.95))
                    if abs(side) * half + long * 0.5 > half * 1.08 { continue }
                    let tone = Float(rng.next(0, 0.55))
                    let colour = PaintMix(barkDark, lavenderDeep, tone)
                    ref.authored.append(PaintAuthoredStroke(x: cu + side * half, y: v, angle: Float(rng.next(-0.14, 0.14)) - side * 0.20 * litSideNow, length: long, width: max(0.0020, half * Float(rng.next(0.07, 0.20))), color: colour, alpha: PaintLerp(0.55, 0.92, trunk.depth) * (dark ? PaintLerp(0.45, 1, PaintSstep(aspect * 0.15, aspect * 0.5, v)) : 1), load: 1.05, thick: 0.45, bend: Float(rng.next(-0.002, 0.002)), round: 0.5, feather: 0.1, taper: 0.5, tipIn: 0.5, tipOut: 0.8, comb: 0.3))
                }
                // A few great scars where boughs came off, no two the same.
                let scars = trunk.depth > 0.8 ? 3 : 1
                for _ in 0..<scars {
                    let t = Float(rng.next(0.08, 0.60))
                    let v = trunk.base + up * t
                    let cu = trunk.x + trunk.lean * t + sin(t * 3.1) * trunk.bow
                    let half = trunk.width * 0.5 * (1 - 0.56 * t)
                    let off = Float(rng.next(-0.45, 0.35)) * litSideNow
                    let spreadA = Float(rng.next(0.20, 0.60)), spreadB = Float(rng.next(0.25, 0.75))
                    let longA = half * Float(rng.next(0.30, 0.72)), longB = half * Float(rng.next(0.16, 0.48))
                    ref.authored.append(PaintAuthoredStroke(x: cu + (off - 0.20) * half, y: v - half * 0.08, angle: -spreadA, length: longA, width: half * Float(rng.next(0.09, 0.16)), color: barkDark, alpha: 0.92, load: 1.1, thick: 0.5, round: 0.4, taper: 0.6, tipIn: 0.4, tipOut: 0.9, comb: 0.3))
                    if Float(rng.next()) < 0.6 {
                        ref.authored.append(PaintAuthoredStroke(x: cu + (off + 0.20) * half, y: v - half * 0.08, angle: spreadB, length: longB, width: half * Float(rng.next(0.07, 0.13)), color: barkDark, alpha: 0.92, load: 1.1, thick: 0.5, round: 0.4, taper: 0.6, tipIn: 0.4, tipOut: 0.9, comb: 0.3))
                    }
                }
            }
        }
        paintTrunks(farTrunks)

        // Leaves in the middle air, between the far trees and the near.
        var midLeaves: [PaintPuff] = []
        mass(0.10, aspect * 0.235, 0.26, aspect * 0.135, crowns: 13, r: 0.070 * size, air: dark ? 0.14 : 0.20, level: 12, into: &midLeaves)
        mass(0.92, aspect * 0.215, 0.24, aspect * 0.130, crowns: 12, r: 0.068 * size, air: dark ? 0.14 : 0.20, level: 12, into: &midLeaves)
        mass(0.50, aspect * 0.035, 0.32, aspect * 0.075, crowns: 10, r: 0.070 * size, air: dark ? 0.12 : 0.18, level: 12, into: &midLeaves)
        PaintLayPuffs(ref, midLeaves, look: leaves, warpX: leafX, warpY: leafY, grain: fine)
        paintTrunks(midTrunks)

        // The nearest leaves hang in front of the middle trees, off the top corners, and the big birches stand in front of them.
        var nearLeaves: [PaintPuff] = []
        mass(0.03, aspect * 0.075, 0.27, aspect * 0.105, crowns: 11, r: 0.086 * size, air: 0, level: 14, into: &nearLeaves)
        mass(0.92, aspect * 0.040, 0.25, aspect * 0.090, crowns: 10, r: 0.082 * size, air: 0, level: 14, into: &nearLeaves)
        PaintLayPuffs(ref, nearLeaves, look: leaves, warpX: leafX, warpY: leafY, grain: fine)
        paintTrunks(nearTrunks)

        // Touches of leaf: only on the skirts of the masses, to break their edges, and never many.
        let leafDeep = dark ? PaintHex(9, 15, 28) : PaintHex(56, 90, 74)
        let leafMid = dark ? PaintHex(15, 25, 39) : PaintHex(100, 132, 82)
        let leafLit = dark ? PaintHex(22, 34, 48) : PaintHex(156, 170, 90)
        let leafHot = dark ? PaintHex(34, 46, 62) : PaintHex(218, 210, 126)
        func skirt(_ list: [PaintPuff], every: Float, scale: Float, ownLevel: Float) {
            for puff in list where puff.r < 0.05 && Float(rng.next()) < every {
                let a = Float(rng.next(0, 6.2832))
                let x = puff.x + cos(a) * puff.r * 1.02, y = puff.y + sin(a) * puff.r * puff.squash * 1.02
                let col = min(w - 1, max(0, Int(x * unitPx))), row = min(h - 1, max(0, Int(y * unitPx)))
                // On the edge of the mass, not in its body, and not across anything that stands in front of it.
                if ref.level.at(col, row) >= ownLevel { continue }
                let toLight = PaintSat(0.5 - sin(a) * 0.5 + cos(a) * 0.18 - puff.sunk * 0.4 + Float(rng.next(-0.12, 0.12)))
                var colour = toLight > 0.66 ? PaintMix(leafLit, leafHot, Float(rng.next(0, 0.6))) : (toLight > 0.36 ? PaintMix(leafMid, leafLit, Float(rng.next(0, 1))) : PaintMix(leafDeep, leafMid, Float(rng.next(0, 1))))
                colour = PaintMix(colour, haze, puff.air)
                let long = Float(rng.next(0.012, 0.024)) * scale * size
                ref.authored.append(PaintAuthoredStroke(x: x, y: y, angle: Float(rng.next(-1.5, 1.5)), length: long, width: long * Float(rng.next(0.5, 0.8)), color: colour, alpha: dark ? 0.7 : 0.9, load: 0.92, thick: 0.55, round: 0.7, feather: 0.14, taper: 0.14, tipIn: 0.7, tipOut: 0.7, comb: 0.7))
            }
        }
        skirt(farLeaves, every: 0.18, scale: 0.8, ownLevel: 10)
        skirt(midLeaves, every: 0.26, scale: 1.0, ownLevel: 12)
        skirt(nearLeaves, every: 0.34, scale: 1.35, ownLevel: 14)

        // Low growth in the corners under us, in the same manner as the leaves overhead. The trees just stand in the moss.
        let lowLeaves = dark
            ? PaintPuffLook(shade: PaintHex(8, 13, 24), shadeDeep: PaintHex(6, 10, 20), lit: PaintHex(16, 28, 38), lit2: PaintHex(14, 26, 38), hot: PaintHex(26, 38, 50), haze: haze, light: lightDir, threshold: 0.20, sink: 0.42, detail: 0.34, long: 0.74, wide: 1)
            : PaintPuffLook(shade: PaintHex(44, 80, 62), shadeDeep: PaintHex(34, 66, 56), lit: PaintHex(104, 138, 72), lit2: PaintHex(88, 128, 74), hot: PaintHex(168, 178, 92), haze: haze, light: lightDir, threshold: 0.16, sink: 0.42, detail: 0.34, long: 0.74, wide: 1)
        var low: [PaintPuff] = []
        for (u, r) in [(Float(0.02), Float(0.150)), (0.17, 0.092), (0.98, 0.135), (0.84, 0.080)] {
            PaintCrown(x: u, y: aspect + 0.010 - r * 0.24, r: r * size, squash: 0.56, tint: Float(rng.next(0, 1)), level: 52, generations: 3, sunkBias: 0.15, rng: &rng, into: &low)
        }
        low.sort { $0.y < $1.y }
        PaintLayPuffs(ref, low, look: lowLeaves, warpX: leafX, warpY: leafY, grain: fine)

        // Moss and grass over each foot, so it stands in the ground. Broad and quiet: a little more at some, hardly any at others.
        for (k, trunk) in (farTrunks.filter({ $0.depth > 0.2 }) + midTrunks + nearTrunks).enumerated() {
            let touches = Int(PaintLerp(4, 26, trunk.depth)) * (k % 3 == 1 ? 1 : 2) / 2
            for _ in 0..<touches {
                let x = trunk.x + Float(rng.next(-1, 1)) * trunk.width * 0.95
                let t = PaintSat((trunk.base - groundLine) / floorSpan)
                let colour = PaintMix(three(mossShadeFar, mossShadeMid, mossShadeNear, t), three(mossLitFar, mossLitMid, mossLitNear, t), Float(rng.next(0, 0.7)))
                let long = Float(rng.next(0.012, 0.030)) * PaintLerp(0.6, 1.7, trunk.depth) * size
                ref.authored.append(PaintAuthoredStroke(x: x, y: trunk.base + trunk.width * Float(rng.next(0.12, 0.42)), angle: .pi / 2 + Float(rng.next(-0.7, 0.7)), length: long, width: long * Float(rng.next(0.28, 0.5)), color: colour, alpha: 0.9, load: 0.92, thick: 0.5, round: 0.6, feather: 0.1, taper: 0.4, tipIn: 0.5, tipOut: 0.9, comb: 0.7))
            }
        }

        // A few blades where the path's edge wants finding, hardly different from the moss.
        for _ in 0..<26 {
            let t = pow(Float(rng.next()), 0.6)
            let v = groundLine + t * floorSpan
            let side: Float = rng.next() < 0.5 ? -1 : 1
            let u = pathCentre(t) + side * pathHalf(t) * Float(rng.next(0.94, 1.14))
            let scale = PaintLerp(0.45, 1.4, t) * size
            for _ in 0..<Int(PaintLerp(2, 6, t)) {
                let colour = PaintMix(leafDeep, PaintMix(mossShadeMid, leafLit, 0.4), Float(rng.next(0.3, 1)))
                ref.authored.append(PaintAuthoredStroke(x: u + Float(rng.next(-1, 1)) * 0.014 * scale, y: v + Float(rng.next(-0.5, 0.3)) * 0.008 * scale, angle: .pi / 2 + Float(rng.next(-0.5, 0.5)), length: Float(rng.next(0.018, 0.034)) * scale, width: Float(rng.next(0.0034, 0.0060)) * scale, color: colour, alpha: 0.8, load: 0.92, thick: 0.5, round: 0.6, feather: 0.08, taper: 0.4, tipIn: 0.5, tipOut: 0.9, comb: 0.7))
            }
        }
        return ref
    }
}
