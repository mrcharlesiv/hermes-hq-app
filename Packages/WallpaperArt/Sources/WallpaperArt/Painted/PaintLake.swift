// Mountain lake: a big snowy massif over a still alpine lake and its reflection, forest at the shore, low light from the right.

import Foundation
import simd

@inline(__always) nonisolated func PaintMix1(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

nonisolated enum PaintLakeScene {
    static func scene(width: Int, height: Int, dark: Bool) -> PaintSceneRef {
        let w = min(width, 590)
        let h = Int((Float(height) * Float(w) / Float(width)).rounded())
        let ref = PaintSceneRef(w: w, h: h)
        ref.dark = dark
        ref.ground = dark ? PaintHex(22, 26, 40) : PaintHex(150, 116, 84)
        let unitPx = Float(w)
        let aspect = Float(height) / Float(width)
        // Where the water starts, as a fraction of the height: everything hangs off this and the summit.
        let waterline = aspect * 0.579
        let summitV = aspect * 0.274
        let sun = simd_normalize(dark ? PaintV3(0.80, 0.42, 0.42) : PaintV3(0.76, 0.40, 0.50))
        ref.lightDir = simd_normalize(SIMD2<Float>(sun.x, -sun.y))

        // Palette: one for each hour.
        let nightStops: [(Float, PaintV3)] = [(0, PaintHex(6, 9, 22)), (0.45, PaintHex(9, 15, 34)), (0.82, PaintHex(15, 26, 50)), (1, PaintHex(26, 40, 66))]
        let dayStops: [(Float, PaintV3)] = [(0, PaintHex(92, 128, 158)), (0.42, PaintHex(136, 168, 180)), (0.74, PaintHex(208, 206, 182)), (0.92, PaintHex(238, 212, 164)), (1, PaintHex(244, 202, 148))]
        let sky = PaintGradient(stops: dark ? nightStops : dayStops)
        // A last warmth low behind the range at night: the single warm note in a cold picture.
        let ember = dark ? PaintHex(74, 54, 62) : PaintHex(250, 196, 140)
        let look = dark
            ? PaintMassifLook(sun: sun, snowLit: PaintHex(152, 168, 196), snowGlow: PaintHex(92, 108, 140), snowShade: PaintHex(26, 34, 58), snowDeep: PaintHex(14, 19, 36),
                         rockLit: PaintHex(62, 72, 92), rockShade: PaintHex(12, 16, 28), haze: PaintHex(30, 44, 70), litLow: 0.40, litHigh: 0.52)
            : PaintMassifLook(sun: sun, snowLit: PaintHex(252, 238, 214), snowGlow: PaintHex(240, 206, 172), snowShade: PaintHex(132, 142, 178), snowDeep: PaintHex(98, 106, 146),
                         rockLit: PaintHex(160, 118, 90), rockShade: PaintHex(88, 88, 116), haze: PaintHex(226, 206, 180))

        // Sky: laid level and broad, a low warm band, a few long streaks of high cloud. It should rest the eye.
        let cn = PaintNoise(seed: 0xC10D)
        PaintPar(h) { row in
            let v = (Float(row) + 0.5) / unitPx
            for col in 0..<w {
                let u = (Float(col) + 0.5) / unitPx
                let drift = Float(cn.fbm(Double(u) * 1.7, Double(v) * 2.3, octaves: 3))
                var c = sky.at(min(1, (v + drift * 0.05) / waterline))
                // The warm low light comes from the right.
                let warmSide = PaintSstep(0.9, 1.0, v / waterline + 0.1) * (dark ? (1 - u) : (0.35 + 0.65 * u))
                c = PaintMix(c, ember, warmSide * (dark ? 0.8 : 0.5))
                let streak = Float(cn.fbm(Double(u - v * 0.05) * 1.6, Double(v) * 15, octaves: 4))
                let veil = PaintSstep(0.04, 0.42, streak) * PaintSstep(aspect * 0.02, aspect * 0.14, v)
                c = PaintMix(c, dark ? PaintHex(28, 40, 66) : PaintHex(236, 222, 200), veil * (dark ? 0.30 : 0.46))
                ref.rgb.set3(col, row, c)
                ref.setDir(col, row, angle: -0.05 + 0.05 * Float(cn.value(Double(u) * 1.2, Double(v) * 0.9)), strength: 2.2)
                ref.setBendToForm(col, row, 0.05)
                ref.steady.p[row * w + col] = 0.22
                ref.detail.p[row * w + col] = 0
                ref.soft.p[row * w + col] = 0.95
                ref.setShape(col, row, length: 1.25, width: 0.95)
            }
        }

        // A far range behind, thin with air.
        var rng = SplitMix64(seed: 0x51E2)
        let far = PaintMassif(w: w, h: h)
        let farPoints: [(Float, Float)] = [(-0.1, 1.05), (0.08, 0.98), (0.2, 1.03), (0.34, 0.96), (0.48, 1.04), (0.8, 0.98), (0.94, 0.92), (1.1, 1.02)]
        let farCrest: [SIMD2<Float>] = farPoints.map { SIMD2($0.0, $0.1 * (aspect / 2.168)) }
        far.setCrest(PaintMassif.jagged(farCrest, rough: 0.16, levels: 4, rng: &rng))
        for node in farCrest {
            far.spur(from: node, angle: Float(rng.next(1.2, 1.9)), length: 0.24, e: 0.05, kL: 0.8, kR: 0.8, maxLevel: 1, rng: &rng)
        }
        far.build(tilt: 0.6, spread: 0.1, axis: 0.5, sun: sun, seed: 0xFA2)
        paintFar(far, into: ref, look: look, dark: dark, base: waterline)

        // The massif. The summit sits right of centre, a long shoulder running out to the left.
        let scaleV = aspect / 2.168
        let s = SIMD2<Float>(0.615, summitV)
        func at(_ x: Float, _ dy: Float) -> SIMD2<Float> { SIMD2(x, summitV + dy * scaleV) }
        let crestNodes: [SIMD2<Float>] = [
            at(-0.12, 0.47), at(0.05, 0.40), at(0.16, 0.335), at(0.25, 0.39), at(0.325, 0.41), at(0.40, 0.31), at(0.47, 0.215), at(0.525, 0.150),
            s, at(0.655, 0.055), at(0.70, 0.125), at(0.755, 0.105), at(0.83, 0.215), at(0.915, 0.275), at(1.12, 0.385),
        ]
        let m = PaintMassif(w: w, h: h)
        m.setCrest(PaintMassif.jagged(crestNodes, rough: 0.13, levels: 4, rng: &rng))
        // The ridges, biggest first. The arête off the summit divides the mountain into a lit face and a shadow face.
        m.spur(from: s, angle: 1.72, length: 0.56, e: 0.20, kL: 0.62, kR: 0.74, rng: &rng)
        m.spur(from: at(0.47, 0.215), angle: 1.92, length: 0.44, e: 0.13, kL: 0.8, kR: 0.8, rng: &rng)
        m.spur(from: at(0.80, 0.17), angle: 1.30, length: 0.36, e: 0.11, kL: 0.76, kR: 0.8, rng: &rng)
        m.spur(from: at(0.16, 0.335), angle: 1.75, length: 0.30, e: 0.10, kL: 0.8, kR: 0.9, rng: &rng)
        m.spur(from: at(0.915, 0.275), angle: 1.42, length: 0.34, e: 0.10, kL: 0.8, kR: 0.9, rng: &rng)
        m.spur(from: at(0.325, 0.41), angle: 1.5, length: 0.20, e: 0.07, kL: 0.9, kR: 0.9, rng: &rng)
        // Thin ribs on the lit face, each throwing a narrow shadow: the big snowfield has structure, not a blank.
        m.spur(from: at(0.665, 0.13), angle: 1.66, length: 0.26, e: 0.050, kL: 1.0, kR: 1.0, maxLevel: 1, rng: &rng)
        m.spur(from: at(0.745, 0.20), angle: 1.50, length: 0.22, e: 0.045, kL: 1.0, kR: 1.0, maxLevel: 1, rng: &rng)
        m.build(tilt: 0.72, spread: 0.30, axis: 0.60, sun: sun, seed: 0x51A7)
        paintMassif(m, into: ref, look: look, dark: dark, summit: s, base: waterline, sky: sky, arete: 1.72)
        let apexX = s.x * unitPx, apexY = s.y * unitPx, apexReach = 0.14 * unitPx
        ref.simplify(radius: max(1, w / 220)) { x, y in
            let dx = Float(x) - apexX, dy = Float(y) - apexY
            return PaintSstep(apexReach, apexReach * 0.4, (dx * dx + dy * dy).squareRoot())
        }
        ref.pruneLevels(minArea: Int(0.0009 * unitPx * unitPx))
        ref.pruneLevels(minArea: Int(0.0030 * unitPx * unitPx), only: [8, 9])

        // The shore: a far low line, with a wooded point coming toward us from the left.
        let shoreNoise = PaintNoise(seed: 0x2E)
        var shoreRows = [Float](repeating: 0, count: w)
        for col in 0..<w {
            let u = (Float(col) + 0.5) / unitPx
            let wobble = Float(shoreNoise.fbm(Double(u) * 4, 2.2, octaves: 3)) * 0.008
            let point = 0.12 * pow(PaintSstep(0.50, 0.0, u), 1.5)
            shoreRows[col] = (waterline + wobble + point) * unitPx
        }
        paintForest(into: ref, shore: shoreRows, look: look, dark: dark, waterline: waterline)
        ref.pruneLevels(minArea: Int(0.0024 * unitPx * unitPx), only: [1, 2, 3, 4, 5, 8, 9])

        // The lake mirrors everything above its edge.
        paintWater(into: ref, shore: shoreRows, dark: dark, aspect: aspect, waterline: waterline)
        ref.pruneLevels(minArea: Int(0.0045 * unitPx * unitPx), only: Set(11...19))

        if dark {
            let land = m.land.blurred(max(2, Int(unitPx * 0.062)))
            PaintAddStars(to: ref, count: 22, aspectTop: summitV * 0.9, seed: 0x5742) { x, y in
                let c = min(w - 1, Int(x * unitPx)), r = min(h - 1, Int(y * unitPx))
                return land.at(c, r) < 0.01 && y < waterline * 0.42
            }
        }
        return ref
    }

    static func paintFar(_ m: PaintMassif, into ref: PaintSceneRef, look: PaintMassifLook, dark: Bool, base: Float) {
        let w = ref.w, h = ref.h
        let unitPx = Float(w)
        let sun = look.sun
        PaintPar(h) { row in
            let v = (Float(row) + 0.5) / unitPx
            for col in 0..<w {
                let i = row * w + col
                let cover = m.land.p[i]
                if cover <= 0 { continue }
                let xm = max(0, col - 1), xp = min(w - 1, col + 1), ym = max(0, row - 1), yp = min(h - 1, row + 1)
                let zu = (max(m.z.at(xp, row), -1) - max(m.z.at(xm, row), -1)) * unitPx / Float(xp - xm)
                let zv = (max(m.z.at(col, yp), -1) - max(m.z.at(col, ym), -1)) * unitPx / Float(yp - ym)
                let n = simd_normalize(PaintV3(-zu, zv, 1))
                let ndl = max(0, simd_dot(n, sun)) * m.clear.p[i]
                let family = PaintSstep(0.34, 0.5, ndl)
                let c0 = PaintMix(look.snowShade, look.snowGlow, family)
                let air: Float = dark ? 0.58 : 0.62
                let foot = PaintSstep(base - 0.20, base - 0.02, v)
                let c = PaintMix(c0, look.haze, PaintSat(air + foot * 0.3))
                ref.rgb.set3(col, row, PaintMix(ref.rgb.get3(col, row), c, cover))
                if cover > 0.5 {
                    ref.level.p[i] = 2
                    ref.setDir(col, row, angle: m.info.at(col, row, 2), strength: 0.6)
                    ref.setBendToForm(col, row, 0.5)
                    ref.detail.p[i] = 0.05
                    ref.soft.p[i] = 0.8
                    ref.wet.p[i] = 0.5
                    ref.setShape(col, row, length: 0.8, width: 0.9)
                    ref.steady.p[i] = 0.5
                }
            }
        }
    }

    static func paintMassif(_ m: PaintMassif, into ref: PaintSceneRef, look: PaintMassifLook, dark: Bool, summit: SIMD2<Float>, base: Float, sky: PaintGradient, arete: Float) {
        let w = ref.w, h = ref.h
        let unitPx = Float(w)
        let sun = look.sun
        let rock = PaintNoise(seed: 0x4043)
        let span = base - summit.y
        let blurred = m.z.blurred(max(1, w / 400))
        PaintPar(h) { row in
            let v = (Float(row) + 0.5) / unitPx
            for col in 0..<w {
                let i = row * w + col
                let cover = m.land.p[i]
                if cover <= 0 { continue }
                let u = (Float(col) + 0.5) / unitPx
                let xm = max(0, col - 1), xp = min(w - 1, col + 1), ym = max(0, row - 1), yp = min(h - 1, row + 1)
                let zu = (max(blurred.at(xp, row), -1) - max(blurred.at(xm, row), -1)) * unitPx / Float(xp - xm)
                let zv = (max(blurred.at(col, yp), -1) - max(blurred.at(col, ym), -1)) * unitPx / Float(yp - ym)
                let n = simd_normalize(PaintV3(-zu, zv, 1))
                let altitude = PaintSat((base - v) / span)
                let along = m.info.at(col, row, 0), off = m.info.at(col, row, 1), tangent = m.info.at(col, row, 2), reach = m.info.at(col, row, 3)
                let ndl = max(0, simd_dot(n, sun))
                // Right at the summit nothing casts a shadow: one lit side, one shadow side, and a clean line between.
                let toApex = ((u - summit.x) * (u - summit.x) + (v - summit.y) * (v - summit.y)).squareRoot()
                let vis = max(m.clear.p[i], PaintSstep(0.17, 0.09, toApex))
                // And the top of the mountain is one clean plane each side of its arete: sharp, with nothing wrapped over it.
                let slant = cos(arete) / sin(arete)
                let side = (u - (summit.x + (v - summit.y) * slant)) * (sun.x > 0 ? 1 : -1)
                var litness = PaintMix1(ndl * vis, side > 0 ? 0.80 : 0.12, PaintSstep(0.135, 0.075, toApex))
                // A slope that climbs away from the light is in shadow right up to the skyline: no lit hem running round the top of a shadow, which reads as an arch.
                let colL = max(0, col - w / 18), colR = min(w - 1, col + w / 18)
                let skylineSlope = (m.crest[colR] - m.crest[colL]) * unitPx / Float(max(1, colR - colL)) * (sun.x > 0 ? 1 : -1)
                let away = PaintSstep(0.16, 0.44, -skylineSlope) * PaintSstep(0.10, 0.045, v - m.crest[col])
                litness = PaintMix1(litness, min(litness, 0.14), away)
                let family = PaintSstep(look.litLow, look.litHigh, litness)
                // Rock shows along the crests of the ribs and in streaks running with them, more of it lower down; snow lies in the hollows.
                let streak = Float(rock.fbm(Double(along) * 5, Double(off) * 26, octaves: 3))
                let patch = Float(rock.fbm(Double(u) * 5.5, Double(v) * 4, octaves: 3))
                let crestRock = PaintSstep(0.42, 0.04, reach)
                var exposed = crestRock * 0.42 + streak * 0.55 + patch * 0.34 + (0.46 - altitude) * 1.5 - 0.36
                // Near the top only the steepest faces hold no snow.
                let steep = PaintSstep(0.55, 0.95, abs(zu))
                exposed -= PaintSstep(0.80, 0.94, altitude) * (0.9 - 0.7 * steep * (1 - family))
                let snow = PaintSstep(0.05, -0.02, exposed)
                // Snow: two families and very little inside each.
                var snowLight = PaintMix(look.snowGlow, look.snowLit, PaintSstep(look.litHigh, 0.92, litness))
                // At night the silver is on the top of the mountain; the moon's light dies going down it.
                if dark { snowLight *= PaintLerp(0.62, 1.0, PaintSstep(0.22, 0.92, altitude)) }
                let fill = PaintSat(0.42 + 0.72 * n.y + 0.12 * patch)
                let snowDark = PaintMix(look.snowDeep, look.snowShade, fill)
                let snowColor = PaintMix(snowDark, snowLight, family)
                let rockColor = PaintMix(PaintMix(look.rockShade * 0.8, look.rockShade, fill), look.rockLit, family)
                var c = PaintMix(rockColor, snowColor, snow)
                // Air gathers lower down; the foot goes into the haze.
                let hazeUp = PaintSstep(0.34, 0.02, altitude + 0.05 * patch)
                c = PaintMix(c, look.haze, hazeUp * (dark ? 0.44 : 0.62))
                let distant: Float = dark ? 0.04 : 0.10
                c = PaintMix(c, look.haze, distant)
                ref.rgb.set3(col, row, PaintMix(ref.rgb.get3(col, row), c, cover))
                if cover < 0.5 { continue }
                ref.level.p[i] = snow > 0.5 ? (family > 0.5 ? 4 : 3) : (family > 0.5 ? 8 : 9)
                ref.comb.p[i] = 0.5
                // Strokes run down the fall of the slope with the ribs, never across it. The mist in front is its own passage, scrubbed level.
                let misty = PaintSat(hazeUp * 1.3)
                ref.setDir(col, row, angle: min(Float.pi / 2 + 0.62, max(Float.pi / 2 - 0.62, tangent)), strength: 1.0)
                ref.setBendToForm(col, row, 0.6 * (1 - misty))
                ref.steady.p[i] = 0.45
                ref.setShape(col, row, length: 0.85, width: 0.95)
                let dx = u - summit.x, dy = v - (summit.y + span * 0.20)
                let focal = PaintSstep(0.42, 0.10, (dx * dx + dy * dy * 0.42).squareRoot())
                // Attention: around the summit, on what's lit, and not at all in the shadow mass.
                ref.detail.p[i] = focal * PaintLerp(0.40, 0.56, family)
                ref.soft.p[i] = PaintSat(PaintLerp(0.44, 0.10, family) + misty * 0.8)
                ref.focus.p[i] = focal * PaintLerp(0.15, 1, family) * (1 - misty)
                ref.wet.p[i] = PaintLerp(0.60, 0.10, family) * (1 - snow * 0.3) + misty * 0.4
                ref.blend.p[i] = (1 - family) * PaintSstep(0.1, 0.5, 1 - focal) * 0.8 + misty * 0.6 * (1 - family)
            }
        }
        // The arete is the one line in the picture that has to be sure of itself, and the study only holds it in cells: one long
        // pull down it from the summit, dragged off the lit snow, its dark edge laid exactly on the line.
        let litSign: Float = sun.x > 0 ? 1 : -1
        let along = SIMD2<Float>(cos(arete), sin(arete))
        let across = SIMD2<Float>(sin(arete), -cos(arete)) * litSign
        let pull: Float = 0.105, breadth: Float = 0.012
        let middle = summit + along * (pull * 0.5 + 0.003) + across * (breadth * 0.5 - 1.2 / unitPx)
        let onSnow = middle + across * 0.016
        let snowHere = ref.rgb.get3(min(w - 1, Int(onSnow.x * unitPx)), min(h - 1, Int(onSnow.y * unitPx)))
        ref.authored.append(PaintAuthoredStroke(x: middle.x, y: middle.y, angle: arete, length: pull, width: breadth, color: snowHere, alpha: 0.96, load: 1.0, thick: 0.3,
                                           round: 0.2, feather: 0, taper: 0.5, tipIn: 0.6, tipOut: 1, comb: 0.35))
    }

    private static func paintForest(into ref: PaintSceneRef, shore: [Float], look: PaintMassifLook, dark: Bool, waterline: Float) {
        let w = ref.w, h = ref.h
        let unitPx = Float(w)
        var rng = SplitMix64(seed: 0x7EE5)
        let treeDark = dark ? PaintHex(7, 11, 19) : PaintHex(24, 40, 44)
        let treeMid = dark ? PaintHex(11, 18, 28) : PaintHex(34, 54, 52)
        let treeLit = dark ? PaintHex(40, 54, 72) : PaintHex(146, 134, 84)
        // Mist behind them, so the skyline of the trees reads: pale and cool by day, a lifted blue at night. Its top wanders.
        let mistColor = dark ? PaintHex(58, 76, 108) : PaintHex(222, 216, 208)
        let mistNoise = PaintNoise(seed: 0x3157)
        PaintPar(h) { row in
            let v = (Float(row) + 0.5) / unitPx
            let d = waterline - v
            if d < -0.1 || d > 0.26 { return }
            for col in 0..<w {
                let u = (Float(col) + 0.5) / unitPx
                let wander = Float(mistNoise.fbm(Double(u) * 3.2, 1.7, octaves: 3)) * 0.05 + Float(mistNoise.fbm(Double(u) * 11, Double(v) * 26, octaves: 2)) * 0.012
                let amount = PaintSstep(0.175 + wander, 0.045 + wander, d)
                if amount <= 0 { continue }
                let i = row * w + col
                ref.rgb.set3(col, row, PaintMix(ref.rgb.get3(col, row), mistColor, amount * (dark ? 0.86 : 0.92)))
                if amount > 0.42 {
                    ref.level.p[i] = 5
                    ref.detail.p[i] = 0.05
                    ref.focus.p[i] = 0
                    ref.setDir(col, row, angle: 0.02, strength: 1.5)
                    ref.setBendToForm(col, row, 0.05)
                    ref.setShape(col, row, length: 1.1, width: 0.8)
                }
                if amount > 0.03 { ref.soft.p[i] = max(ref.soft.p[i], 0.92) }
                ref.wet.p[i] = max(ref.wet.p[i], amount * 0.8)
                ref.blend.p[i] = max(ref.blend.p[i], amount * 0.9)
            }
        }
        struct Tree { var u, base, height, width: Float; var tone: Float }
        var trees: [Tree] = []
        // One dark mass with a jagged top: a band of many low trees all along the shore.
        let crowd = PaintNoise(seed: 0x7EE8)
        for _ in 0..<300 {
            let u = Float(rng.next(-0.05, 1.05))
            let col = min(w - 1, max(0, Int(u * unitPx)))
            let onPoint = PaintSstep(0.62, 0.05, u)
            let base = shore[col] / unitPx - Float(rng.next(0.002, 0.012)) - onPoint * Float(rng.next(0, 0.05))
            // Stands and gaps: taller groups and low places, never an even row.
            let stand = PaintSat(0.5 + 1.6 * Float(crowd.fbm(Double(u) * 7, 0.4, octaves: 2)))
            let hgt = Float(rng.next(0.018, 0.040)) * (0.6 + 1.5 * stand) * (1 + 1.3 * onPoint) * (rng.next() < 0.1 ? 1.45 : 1)
            trees.append(Tree(u: u, base: base, height: hgt, width: hgt * Float(rng.next(0.20, 0.30)), tone: Float(rng.next(0, 0.5))))
        }
        // And a handful of distinct spires on the point, each with room around it.
        let spires: [(Float, Float)] = [(0.035, 0.235), (0.105, 0.300), (0.165, 0.205), (0.235, 0.255), (0.30, 0.165), (0.365, 0.190), (0.445, 0.120), (0.53, 0.095)]
        for (u, height) in spires {
            let col = min(w - 1, max(0, Int(u * unitPx)))
            let hgt = height * Float(rng.next(0.92, 1.08))
            trees.append(Tree(u: u, base: shore[col] / unitPx - 0.004, height: hgt, width: hgt * Float(rng.next(0.135, 0.17)), tone: 0.9))
        }
        // Bank under the trees, so nothing shows through.
        for col in 0..<w {
            let u = (Float(col) + 0.5) / unitPx
            let bankTop = Int(shore[col] - (0.018 + 0.09 * PaintSstep(0.62, 0.05, u)) * unitPx)
            for row in max(0, bankTop)..<min(h, Int(shore[col]) + 1) {
                ref.rgb.set3(col, row, treeDark)
                ref.level.p[row * w + col] = 6
                ref.setDir(col, row, angle: 0.02, strength: 1.4)
                ref.detail.p[row * w + col] = 0.34
                ref.soft.p[row * w + col] = 0.2
                ref.wet.p[row * w + col] = 0.4
                ref.blend.p[row * w + col] = 0.8
            }
        }
        let noise = PaintNoise(seed: 0x7EE6)
        for tree in trees {
            let topRow = Int((tree.base - tree.height) * unitPx), bottomRow = Int(tree.base * unitPx)
            let cu = tree.u * unitPx
            if topRow >= h || bottomRow < 0 { continue }
            let tall = tree.tone > 0.8
            for row in max(0, topRow)...min(h - 1, bottomRow) {
                let t = (Float(row) - Float(topRow)) / max(1, Float(bottomRow - topRow))
                let tier = 0.72 + 0.28 * abs(sin(t * (tall ? 13 : 7) + tree.u * 40))
                let half = max(0.6, tree.width * unitPx * pow(t, 0.92) * tier + Float(noise.value(Double(row) * 0.3, Double(tree.u) * 90)) * 0.8)
                let lo = max(0, Int(cu - half)), hi = min(w - 1, Int(cu + half))
                if lo > hi { continue }
                for col in lo...hi {
                    let s = (Float(col) + 0.5 - cu) / half
                    var c = PaintMix(treeDark, treeMid, PaintSstep(-0.3, 0.5, s) * tree.tone)
                    // Only the tall ones catch a little light, on the sun's side, near the top.
                    if tall { c = PaintMix(c, treeLit, PaintSstep(0.45, 1.0, s) * PaintSstep(0.85, 0.15, t) * 0.40) }
                    ref.rgb.set3(col, row, c)
                    let i = row * w + col
                    ref.level.p[i] = 6
                    ref.setDir(col, row, angle: .pi / 2, strength: 2)
                    ref.setBendToForm(col, row, 0.6)
                    ref.detail.p[i] = tall ? 0.72 : 0.60
                    ref.soft.p[i] = 0.08
                    ref.wet.p[i] = tall ? 0.1 : 0.2
                    ref.blend.p[i] = tall ? 0.15 : 0.3
                    ref.focus.p[i] = tall ? 0.35 : 0
                    ref.setShape(col, row, length: 0.75, width: 0.7)
                }
            }
            if tall {
                // A spine up each spire: one drawn line, and no more than a few boughs.
                ref.authored.append(PaintAuthoredStroke(x: tree.u, y: tree.base - tree.height * 0.55, angle: .pi / 2, length: tree.height * 0.92, width: tree.width * 0.34,
                                                   color: treeDark, load: 1.3, thick: 0.7, round: 0.2, taper: 0, tipIn: 1, tipOut: 0.2))
                let boughs = Int(tree.height * 28)
                for _ in 0..<boughs {
                    let t = Float(rng.next(0.2, 0.92))
                    let side: Float = rng.next() < 0.5 ? -1 : 1
                    let reach = tree.width * pow(t, 0.9) * Float(rng.next(0.85, 1.25))
                    ref.authored.append(PaintAuthoredStroke(x: tree.u + side * reach * 0.48, y: tree.base - tree.height * (1 - t) + reach * 0.24, angle: side > 0 ? 0.5 : Float.pi - 0.5,
                                                       length: reach * 1.05, width: tree.height * 0.030 + 0.0014, color: PaintMix(treeDark, treeMid, Float(rng.next(0, 0.7))), load: 1.05, thick: 0.5, round: 0.6, taper: 0.6, tipIn: 0.4, tipOut: 1))
                }
            }
        }
    }

    private static func paintWater(into ref: PaintSceneRef, shore: [Float], dark: Bool, aspect: Float, waterline: Float) {
        let w = ref.w, h = ref.h
        let unitPx = Float(w)
        let water = PaintNoise(seed: 0x7A7E)
        let deep = dark ? PaintHex(9, 18, 34) : PaintHex(44, 86, 104)
        let sheenColor = dark ? PaintHex(30, 44, 72) : PaintHex(214, 216, 200)
        // The mirror is painted from a softened copy: a reflection has no edges finer than the water allows.
        let soft = ref.rgb.blurred(max(1, w / 340))
        let sourceLevels = ref.level.copied()
        PaintPar(h) { row in
            for col in 0..<w {
                let sr = shore[col]
                if Float(row) < sr { continue }
                let depth = (Float(row) + 0.5 - sr) / unitPx
                let u = (Float(col) + 0.5) / unitPx
                let wobble = Float(water.fbm(Double(u) * 5, Double(depth) * 24 + 3, octaves: 2)) * unitPx * 0.0016 * (0.4 + depth * 2)
                // Drawn out downward, more the nearer the water.
                let smear = unitPx * (0.0012 + depth * 0.020)
                var mirrored = PaintV3.zero
                for k in 0..<7 {
                    let at = 2 * sr - (Float(row) + 0.5) + (Float(k) - 3) * smear
                    mirrored += soft.sample3(Float(col) + 0.5 + wobble, at)
                }
                mirrored *= 1 / 7
                // Water darkens what it mirrors: the snow comes back as one soft shape at three quarters of its value.
                let value = PaintLum(mirrored)
                let toward = PaintSat(depth / max(0.1, aspect - waterline))
                var c = mirrored * PaintLerp(1, 0.76, PaintSstep(0.35, 0.8, value)) * (dark ? 0.94 : 0.92)
                // Looking down into it near us, you see less sky and more lake.
                c = PaintMix(c, deep, PaintSstep(0.28, 0.68, toward) * (dark ? 0.94 : 0.70))
                // A band of breeze far off, the only thing level in the mirror.
                let band = Float(water.fbm(Double(u) * 1.3 + 5, Double(depth) * 18, octaves: 2))
                let wind = PaintSstep(0.16, 0.42, band) * PaintSstep(0.52, 0.04, depth)
                c = PaintMix(c, sheenColor, wind * (dark ? 0.20 : 0.26))
                // Toward us the mirror gives way to the surface: long level passes, hardly different from each other.
                let flat = PaintSstep(0.40, 0.70, toward)
                c *= 1 + flat * 0.07 * Float(water.fbm(Double(u) * 1.1 + 2, Double(depth) * 26, octaves: 3))
                // A dark line where water meets land.
                c *= 1 - 0.20 * PaintSstep(0.010, 0.0, depth)
                ref.rgb.set3(col, row, c)
                // Laid in with big flat strokes pulled straight down; no comb, no fine marks.
                let i = row * w + col
                // The mirror keeps the shapes of what it mirrors while it's near; further out they run together.
                let sourceRow = min(h - 1, max(0, Int(2 * sr - (Float(row) + 0.5))))
                let source = sourceLevels.at(min(w - 1, max(0, Int(Float(col) + 0.5 + wobble))), sourceRow)
                ref.level.p[i] = 10 + source
                ref.setDir(col, row, angle: flat > 0.5 ? 0.01 : .pi / 2, strength: 4.0)
                ref.setBendToForm(col, row, 0.0)
                ref.setShape(col, row, length: flat > 0.5 ? 1.5 : 1.0, width: flat > 0.5 ? 0.7 : 1.0)
                ref.pullDown.p[i] = flat > 0.5 ? 0 : 1
                ref.steady.p[i] = 0.3
                ref.comb.p[i] = 0.34
                ref.detail.p[i] = PaintLerp(0.30, 0.20, toward)
                ref.soft.p[i] = PaintSat(0.56 + 0.4 * PaintSstep(0.02, 0.30, depth))
                ref.wet.p[i] = 0.35
                ref.blend.p[i] = 0.28
                ref.focus.p[i] = 0
            }
        }
    }
}
