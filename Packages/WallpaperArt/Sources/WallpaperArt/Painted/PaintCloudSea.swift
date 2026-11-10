// Sea of clouds: looking out over a cloud deck from high up, peaks breaking through, low light across the tops.
// The deck is banks of billows, tiny at the horizon and huge under the viewer, each one a cluster of lobes turned from lit crown to flat shadow.

import Foundation
import simd

nonisolated enum PaintCloudSeaScene {
    private struct Lobe {
        var x, y, r: Float
        /// Which bank, and how far toward the viewer it is, 0…1.
        var bank: Int32
        var p: Float
        /// How far down inside its bank: low lobes sit in the bank's shadow.
        var sunk: Float
        /// Looked at from high and far, a billow is a flat ellipse; under the viewer it's round.
        var squash: Float
        /// The dome this lobe is part of: strokes go over the dome, not around each bump on it.
        var domeX: Float
        var domeY: Float
    }

    static func scene(width: Int, height: Int, dark: Bool) -> PaintSceneRef {
        let w = min(width, 590)
        let h = Int((Float(height) * Float(w) / Float(width)).rounded())
        let ref = PaintSceneRef(w: w, h: h)
        ref.dark = dark
        ref.ground = dark ? PaintHex(20, 26, 42) : PaintHex(176, 136, 128)
        let unitPx = Float(w)
        let aspect = Float(height) / Float(width)
        let deckTop = aspect * 0.515
        let summitV = aspect * 0.232
        let sun = simd_normalize(dark ? PaintV3(-0.78, 0.44, 0.44) : PaintV3(0.80, 0.34, 0.50))
        ref.lightDir = simd_normalize(SIMD2<Float>(sun.x, -sun.y))

        // Sky: blue overhead, going to peach where the light is low. At night a deep navy, and one thin teal glow along the deck.
        let lightSky: [(Float, PaintV3)] = [(0, PaintHex(58, 96, 156)), (0.40, PaintHex(106, 150, 196)), (0.70, PaintHex(198, 200, 202)), (0.88, PaintHex(250, 212, 168)), (1, PaintHex(255, 196, 142))]
        let darkSky: [(Float, PaintV3)] = [(0, PaintHex(5, 8, 20)), (0.46, PaintHex(8, 14, 32)), (0.78, PaintHex(12, 24, 44)), (0.94, PaintHex(16, 40, 58)), (1, PaintHex(26, 62, 74))]
        let sky = PaintGradient(stops: dark ? darkSky : lightSky)
        let warmSide = dark ? PaintHex(30, 74, 84) : PaintHex(255, 180, 126)
        let cn = PaintNoise(seed: 0xC70D)
        PaintPar(h) { row in
            let v = (Float(row) + 0.5) / unitPx
            for col in 0..<w {
                let u = (Float(col) + 0.5) / unitPx
                let i = row * w + col
                let drift = Float(cn.fbm(Double(u) * 2.1, Double(v) * 3.1, octaves: 3))
                var c = sky.at(min(1, (v + drift * 0.05) / deckTop))
                let toward = dark ? (1 - u) * 0.4 + 0.6 * u : u
                c = PaintMix(c, warmSide, toward * PaintSstep(deckTop * 0.5, deckTop, v) * (dark ? 0.40 : 0.60))
                let su = Double(u - v * 0.28), sv = Double(v + u * 0.12)
                let streak = Float(cn.fbm(su * 2.8, sv * 15, octaves: 4))
                let veil = PaintSstep(0.06, 0.40, streak) * PaintSstep(deckTop * 0.08, deckTop * 0.40, v) * PaintSstep(deckTop, deckTop * 0.70, v)
                c = PaintMix(c, dark ? PaintHex(26, 40, 66) : PaintHex(252, 226, 208), veil * (dark ? 0.30 : 0.55))
                ref.rgb.set3(col, row, c)
                ref.setDir(col, row, angle: -0.20 + 0.32 * Float(cn.value(Double(u) * 1.6, Double(v) * 1.2)), strength: 2.2)
                ref.setBendToForm(col, row, 0.05)
                ref.soft.p[i] = 0.95
                ref.steady.p[i] = 0.3
                ref.setShape(col, row, length: 1.2, width: 0.95)
            }
        }

        // The mountains: a great peak left of centre and a long ridge running out to a lesser one.
        let look = dark
            ? PaintMassifLook(sun: sun, snowLit: PaintHex(150, 166, 192), snowGlow: PaintHex(88, 104, 134), snowShade: PaintHex(22, 30, 50), snowDeep: PaintHex(12, 17, 32),
                         rockLit: PaintHex(58, 68, 86), rockShade: PaintHex(11, 15, 26), haze: PaintHex(24, 38, 60), litLow: 0.40, litHigh: 0.52)
            : PaintMassifLook(sun: sun, snowLit: PaintHex(250, 236, 214), snowGlow: PaintHex(244, 212, 182), snowShade: PaintHex(138, 146, 178), snowDeep: PaintHex(106, 114, 150),
                         rockLit: PaintHex(150, 118, 100), rockShade: PaintHex(90, 92, 118), haze: PaintHex(236, 206, 184))
        var rng = SplitMix64(seed: 0xC10D5)
        let far = PaintMassif(w: w, h: h)
        let farPoints: [(Float, Float)] = [(-0.1, 0.46), (0.10, 0.34), (0.24, 0.40), (0.55, 0.34), (0.72, 0.28), (0.96, 0.36), (1.12, 0.32)]
        // Never squashed past half height: on a wide canvas the flanks go under the deck sooner, and it stays a mountain.
        let scaleV = max(aspect / 2.168, 0.5)
        let farCrest: [SIMD2<Float>] = farPoints.map { SIMD2($0.0, summitV + $0.1 * scaleV) }
        far.setCrest(PaintMassif.jagged(farCrest, rough: 0.16, levels: 4, rng: &rng))
        for node in farCrest {
            far.spur(from: node, angle: Float(rng.next(1.2, 1.9)), length: 0.26, e: 0.06, kL: 0.8, kR: 0.8, maxLevel: 1, rng: &rng)
        }
        far.build(tilt: 0.6, spread: 0.1, axis: 0.5, sun: sun, seed: 0xFA3)
        PaintLakeScene.paintFar(far, into: ref, look: look, dark: dark, base: deckTop)

        // At night the moon's on the other side, and the range is the other way round: the lit face still reads first.
        let mirror = dark
        func at(_ x: Float, _ dy: Float) -> SIMD2<Float> { SIMD2(mirror ? 1 - x : x, summitV + dy * scaleV) }
        func heading(_ a: Float) -> Float { mirror ? .pi - a : a }
        let s = at(0.385, 0)
        var crestNodes: [SIMD2<Float>] = [
            at(-0.14, 0.56), at(0.02, 0.42), at(0.12, 0.30), at(0.19, 0.24), at(0.27, 0.11), at(0.33, 0.055),
            s, at(0.44, 0.075), at(0.49, 0.06), at(0.56, 0.20), at(0.63, 0.30), at(0.71, 0.27), at(0.79, 0.20), at(0.845, 0.235), at(0.92, 0.34), at(1.14, 0.50),
        ]
        if mirror { crestNodes.reverse() }
        let m = PaintMassif(w: w, h: h)
        m.setCrest(PaintMassif.jagged(crestNodes, rough: 0.12, levels: 4, rng: &rng))
        m.spur(from: s, angle: heading(1.78), length: 0.60, e: 0.21, kL: mirror ? 0.72 : 0.66, kR: mirror ? 0.66 : 0.72, rng: &rng)
        // Worked out and painted out again: the seed stays where it is for everything after, but this shoulder is one clean shadow plane.
        let beforeShoulder = m.segments.count
        m.spur(from: at(0.19, 0.24), angle: heading(1.86), length: 0.42, e: 0.13, kL: 0.8, kR: 0.8, rng: &rng)
        m.segments.removeSubrange(beforeShoulder...)
        m.spur(from: at(0.49, 0.06), angle: heading(1.26), length: mirror ? 0.40 : 0.52, e: mirror ? 0.08 : 0.15, kL: mirror ? 0.8 : 0.72, kR: mirror ? 0.72 : 0.8, rng: &rng)
        m.spur(from: at(0.79, 0.20), angle: heading(1.62), length: 0.40, e: 0.13, kL: mirror ? 0.8 : 0.72, kR: mirror ? 0.72 : 0.8, rng: &rng)
        m.build(tilt: 0.72, spread: 0.30, axis: mirror ? 0.58 : 0.42, sun: sun, seed: 0x51A9)
        PaintLakeScene.paintMassif(m, into: ref, look: look, dark: dark, summit: s, base: deckTop + 0.05, sky: sky, arete: heading(1.78))
        let apexX = s.x * unitPx, apexY = s.y * unitPx, apexReach = 0.14 * unitPx
        ref.simplify(radius: max(1, w / 220)) { x, y in
            let dx = Float(x) - apexX, dy = Float(y) - apexY
            return PaintSstep(apexReach, apexReach * 0.4, (dx * dx + dy * dy).squareRoot())
        }

        // The mountains go down into mist before they reach the deck, so the deck doesn't sit on them like a hem.
        let mistNoise = PaintNoise(seed: 0x3158)
        let mist = dark ? PaintHex(26, 44, 66) : PaintHex(240, 214, 194)
        // On a wide canvas the mountain is short, so the mist is too, or it eats the mountain. Portrait canvases are not touched.
        let mistSpan = min(1, aspect / 1.2)
        PaintPar(h) { row in
            let v = (Float(row) + 0.5) / unitPx
            let d = deckTop - v
            if d < -0.1 || d > 0.34 { return }
            for col in 0..<w {
                let i = row * w + col
                if ref.level.p[i] == 1 && d > 0.2 { continue }
                let u = (Float(col) + 0.5) / unitPx
                let wander = (Float(mistNoise.fbm(Double(u) * 3.0, 2.4, octaves: 3)) * 0.07 + Float(mistNoise.fbm(Double(u) * 11, Double(v) * 26, octaves: 2)) * 0.014) * mistSpan
                let amount = PaintSstep((0.21 * mistSpan) + wander, (0.04 * mistSpan) + wander, d)
                if amount <= 0 { continue }
                ref.rgb.set3(col, row, PaintMix(ref.rgb.get3(col, row), mist, amount * 0.92))
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
        paintDeck(into: ref, dark: dark, deckTop: deckTop, aspect: aspect)
        // Far away a crown can be tiny; under the viewer a little scrap of shadow is only a hole in the cloud.
        let deckAt = deckTop * unitPx, deckSpan = (aspect - deckTop) * unitPx
        ref.pruneLevels(minArea: Int(0.0050 * unitPx * unitPx), only: [8, 9])
        ref.pruneLevels(minArea: Int(0.00045 * unitPx * unitPx)) { row in
            let p = PaintSat((Float(row) - deckAt) / deckSpan)
            return (dark ? 3 : 1) + (dark ? 220 : 70) * p * p
        }

        if dark {
            let land = m.land.blurred(max(2, Int(unitPx * 0.062)))
            PaintAddStars(to: ref, count: 20, aspectTop: summitV * 0.95, seed: 0x5744) { x, y in
                let c = min(w - 1, Int(x * unitPx)), r = min(h - 1, Int(y * unitPx))
                return land.at(c, r) < 0.01 && y < deckTop * 0.40
            }
        }
        return ref
    }

    private static func paintDeck(into ref: PaintSceneRef, dark: Bool, deckTop: Float, aspect: Float) {
        let w = ref.w, h = ref.h
        let unitPx = Float(w)
        // Light on a lobe: from upper right by day, upper left at night (the moon's off the frame).
        let light = simd_normalize(dark ? PaintV3(-0.74, -0.50, 0.40) : PaintV3(0.72, -0.52, 0.42))
        let litHot = dark ? PaintHex(98, 116, 146) : PaintHex(252, 238, 214)
        let litWarm = dark ? PaintHex(52, 66, 94) : PaintHex(246, 216, 190)
        let litCool = dark ? PaintHex(40, 52, 78) : PaintHex(226, 208, 212)
        let shadeNear = dark ? PaintHex(20, 26, 43) : PaintHex(196, 186, 198)
        let shadeFar = dark ? PaintHex(18, 27, 46) : PaintHex(178, 176, 188)
        let haze = dark ? PaintHex(26, 48, 66) : PaintHex(246, 214, 190)

        // Where every lobe goes. Far banks are many and small, near ones few and huge.
        var lobes: [Lobe] = []
        let bankCount = 17
        var rng = SplitMix64(seed: 0xDEC4)
        let layout = PaintNoise(seed: 0xDEC5)
        var baselines = [[Float]](repeating: [], count: bankCount)
        for k in 0..<bankCount {
            let p = Float(k) / Float(bankCount - 1)
            let y = deckTop + (aspect + 0.14 - deckTop) * pow(p, 1.65)
            let R = PaintLerp(0.020, 0.30, p * p)
            let squash = PaintLerp(0.48, 0.90, PaintSstep(0, 0.8, p))
            @inline(__always) func swell(_ x: Float) -> Float {
                // The deck rolls: long swells, far bigger than any lobe, so the banks never read as rows.
                (Float(layout.fbm(Double(x) * 2.4 + Double(k) * 0.35, Double(k) * 0.55, octaves: 2)) * 1.1 + Float(layout.fbm(Double(x) * Double(0.55 / R), Double(k) * 7.3, octaves: 2)) * 0.4) * R * 2.6
            }
            var line = [Float](repeating: 0, count: w)
            for col in 0..<w { line[col] = y + swell((Float(col) + 0.5) / unitPx) }
            baselines[k] = line
            var bank: [Lobe] = []
            let generations = R < 0.03 ? 2 : (R < 0.08 ? 3 : 4)
            var x = Float(-R) * 1.2
            while x < 1 + R * 1.2 {
                let clump = PaintSat(0.5 + 1.7 * Float(layout.fbm(Double(x) * Double(0.42 / R), Double(k) * 3.1 + 40, octaves: 2)))
                defer { x += R * Float(rng.next(0.8, 1.35)) }
                if clump < 0.2 { continue }
                let r = R * Float(rng.next(0.8, 1.1)) * (0.60 + 0.85 * clump)
                let cy = y + swell(x) + r * 0.5 * squash - clump * R * 0.55 * squash
                var family = [(x, cy, r, Float(0))]
                for g in 1..<generations {
                    var next: [(Float, Float, Float, Float)] = []
                    for parent in family {
                        for _ in 0..<(g == 1 ? 6 : (g == 2 ? 4 : 3)) {
                            // Along the upper part of the parent, a bias toward the crown and out to the sides.
                            let a = Float(rng.next(-Double.pi * 0.98, -Double.pi * 0.02))
                            let rr = parent.2 * Float(rng.next(0.40, 0.62))
                            let reach = parent.2 * Float(rng.next(0.62, 0.95))
                            next.append((parent.0 + cos(a) * reach, parent.1 + sin(a) * reach * squash * 0.86, rr, Float(g)))
                        }
                    }
                    family += next
                }
                for f in family {
                    bank.append(Lobe(x: f.0, y: f.1, r: f.2, bank: Int32(k), p: p, sunk: PaintSat((f.1 - y - swell(f.0)) / max(0.004, R * 1.1 * squash)), squash: squash, domeX: x, domeY: cy))
                }
            }
            // Higher lobes first, so what's lower comes in front of them.
            bank.sort { $0.y < $1.y }
            lobes += bank
        }
        // Up around the feet of the peaks, the deck climbs in wide flat tongues that melt into the mist.
        var tongues: [Lobe] = []
        for _ in 0..<26 {
            let u = Float(rng.next(-0.05, 1.05))
            let climb = PaintSat(0.5 + 1.8 * Float(layout.fbm(Double(u) * 3.4, 12.5, octaves: 2)))
            let r = Float(rng.next(0.05, 0.085)) * (0.7 + 0.8 * climb)
            let cy = deckTop - climb * 0.085 + Float(rng.next(0.01, 0.05))
            var family = [(u, cy, r)]
            for parent in family {
                for _ in 0..<6 {
                    let a = Float(rng.next(-Double.pi, 0))
                    family.append((parent.0 + cos(a) * parent.2 * 0.8, parent.1 + sin(a) * parent.2 * 0.34, parent.2 * Float(rng.next(0.36, 0.55))))
                }
            }
            for f in family { tongues.append(Lobe(x: f.0, y: f.1, r: f.2, bank: -1, p: 0.1, sunk: 0.1, squash: 0.42, domeX: u, domeY: cy)) }
        }
        tongues.sort { $0.y < $1.y }
        let ordered = tongues + lobes

        // A wander on each circle so no lobe is ever round: a slow one for the big ones, quick for the small.
        let warpNoise = PaintNoise(seed: 0xDEC6)
        let wx = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(warpNoise.fbm(u * 26, v * 26, octaves: 3)) }
        let wy = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(warpNoise.fbm(u * 26 + 17, v * 26 - 9, octaves: 3)) }
        let grain = PaintNoiseField(w: w, h: h, step: 4) { u, v in Float(warpNoise.fbm(u * 4.2 + 3, v * 7.1, octaves: 3)) }
        let sx = PaintNoiseField(w: w, h: h, step: 4) { u, v in Float(warpNoise.fbm(u * 6.5 + 31, v * 6.5 + 5, octaves: 2)) }
        let sy = PaintNoiseField(w: w, h: h, step: 4) { u, v in Float(warpNoise.fbm(u * 6.5 - 13, v * 6.5 + 41, octaves: 2)) }
        let shadeMid = dark ? PaintHex(25, 34, 56) : PaintHex(146, 154, 182)
        let quietLit = PaintHex(214, 196, 196)

        // Each row band runs through the lobes from the front back, and a place once painted is done: what's lower and nearer hides what's behind it.
        let bands = 48
        let rowsPerBand = h / bands + 1
        let lobeList = ordered
        let baseLines = baselines
        let topBank = Int(ordered.last?.bank ?? -1)
        PaintPar(bands) { band in
            let r0 = band * rowsPerBand, r1 = min(h, r0 + rowsPerBand)
            if r0 >= h { return }
            let done = UnsafeMutablePointer<Bool>.allocate(capacity: (r1 - r0) * w)
            done.initialize(repeating: false, count: (r1 - r0) * w)
            defer { done.deallocate() }
            // The flat shadow a bank sits in goes behind all of its lobes and over everything further back.
            func fillBank(_ k: Int) {
                let line = baseLines[k]
                let p = Float(k) / Float(baseLines.count - 1)
                let fill = deckColour(family: 0, ndl: 0, p: p, u: 0.5, grain: 0, litHot: litHot, litWarm: litWarm, litCool: litCool, shadeNear: shadeNear, shadeFar: shadeFar, shadeMid: shadeMid, quietLit: quietLit, haze: haze, dark: dark)
                for row in r0..<r1 {
                    let v = (Float(row) + 0.5) / unitPx
                    for col in 0..<w where v > line[col] {
                        let n = (row - r0) * w + col
                        if done[n] { continue }
                        done[n] = true
                        let i = row * w + col
                        ref.rgb.set3(col, row, fill)
                        ref.level.p[i] = Float(20 + 2 * k)
                        writeShadow(ref, col, row, i, p)
                    }
                }
            }
            var bankNow = topBank
            for index in stride(from: lobeList.count - 1, through: 0, by: -1) {
                let lobe = lobeList[index]
                while bankNow > Int(lobe.bank) {
                    fillBank(bankNow)
                    bankNow -= 1
                }
                let reach = lobe.r * 1.3 * unitPx
                let cyPx = lobe.y * unitPx
                let top = max(r0, Int(cyPx - reach * lobe.squash)), bottom = min(r1 - 1, Int(cyPx + reach * lobe.squash))
                if top > bottom { continue }
                let cxPx = lobe.x * unitPx
                let left = max(0, Int(cxPx - reach)), right = min(w - 1, Int(cxPx + reach))
                if left > right { continue }
                let invR = 1 / (lobe.r * unitPx), invRY = invR / lobe.squash
                let quiet = 0.50 + PaintSstep(0.25, 0.80, lobe.p) * 0.42
                let wobble = min(lobe.r * 0.36, 0.011) * unitPx
                let slow = lobe.r * unitPx * 0.30
                let isTongue = lobe.bank < 0
                let levelShade = isTongue ? Float(18) : Float(20 + 2 * Int(lobe.bank))
                // Lower in the bank, less of a lobe reaches the light.
                let threshold = (dark ? 0.27 : 0.20) + 0.44 * PaintSstep(0.1, 1.1, lobe.sunk)
                for row in top...bottom {
                    let doneRow = (row - r0) * w
                    for col in left...right {
                        if done[doneRow + col] { continue }
                        let i = row * w + col
                        let px = Float(col) + 0.5 + wx.p[i] * wobble + sx.p[i] * slow, py = Float(row) + 0.5 + wy.p[i] * wobble + sy.p[i] * slow
                        let dx = (px - cxPx) * invR, dy = (py - cyPx) * invRY
                        let d2 = dx * dx + dy * dy
                        if d2 >= 1 { continue }
                        done[doneRow + col] = true
                        let nz = (1 - d2).squareRoot()
                        let n = PaintV3(dx, dy, nz)
                        let g = grain.p[i]
                        let ndl = simd_dot(n, light)
                        let lit = ndl + g * 0.14 - threshold
                        let family = PaintSstep(-0.02, 0.05, lit)
                        let u = (Float(col) + 0.5) / unitPx
                        var c = deckColour(family: family, ndl: ndl, p: lobe.p, u: u, grain: g, litHot: litHot, litWarm: litWarm, litCool: litCool, shadeNear: shadeNear, shadeFar: shadeFar, shadeMid: shadeMid, quietLit: quietLit, haze: haze, dark: dark)
                        if isTongue { c = PaintMix(c, haze, 0.34) }
                        ref.rgb.set3(col, row, c)
                        if lit > 0 {
                            ref.level.p[i] = levelShade + 1
                            // Round the lobe near its lit crown; a turn of the wrist.
                            let turn = 2 * (atan2((py - lobe.domeY * unitPx) / lobe.squash, px - lobe.domeX * unitPx) + .pi / 2)
                            let fx = cos(turn) * (1 - quiet) + 0.99 * quiet, fy = sin(turn) * (1 - quiet) - 0.08 * quiet
                            ref.setDir(col, row, angle: atan2(fy, fx) * 0.5, strength: 0.9)
                            ref.setBendToForm(col, row, 0.1)
                            ref.setShape(col, row, length: 0.85, width: 0.9)
                            ref.detail.p[i] = PaintLerp(0.30, 0.06, PaintSstep(0.05, 0.6, lobe.p))
                            // A terminator melts; a crown against what's behind it is found.
                            ref.soft.p[i] = isTongue ? 0.8 : (lit < 0.10 ? 0.62 : PaintLerp(0.12, 0.74, PaintSstep(dark ? 0.24 : 0.34, dark ? 0.60 : 0.72, lobe.p)))
                            ref.comb.p[i] = 0.42
                            ref.wet.p[i] = 0.14
                            ref.blend.p[i] = 0
                            ref.steady.p[i] = 0.5
                            ref.focus.p[i] = 0
                        } else {
                            ref.level.p[i] = levelShade
                            writeShadow(ref, col, row, i, lobe.p)
                        }
                    }
                }
            }
            while bankNow >= 0 {
                fillBank(bankNow)
                bankNow -= 1
            }
        }
        turnUnder(ref, dark: dark, deckTop: deckTop, aspect: aspect, shadeNear: shadeNear, shadeFar: shadeFar)
    }

    /// A lit crown is only crisp where it meets what's behind it. Underneath, and on the side away from the light, it turns gradually into its shadow:
    /// this is the difference between a billow and a plate.
    private static func turnUnder(_ ref: PaintSceneRef, dark: Bool, deckTop: Float, aspect: Float, shadeNear: PaintV3, shadeFar: PaintV3) {
        let w = ref.w, h = ref.h
        let unitPx = Float(w)
        @Sendable @inline(__always) func depth(_ row: Int) -> Float { PaintSat(((Float(row) + 0.5) / unitPx - deckTop) / (aspect - deckTop)) }
        let down = PaintBuf(w: w, h: h), across = PaintBuf(w: w, h: h)
        PaintPar(w) { col in
            var gap: Float = 1e9
            var row = h - 1
            while row >= 0 {
                defer { row -= 1 }
                let i = row * w + col
                let l = Int(ref.level.p[i])
                if l < 18 {
                    gap = 1e9
                    continue
                }
                if l & 1 == 0 {
                    gap = 0
                    continue
                }
                gap += 1
                let p = depth(row)
                let t = gap / (unitPx * (dark ? PaintLerp(0.030, 0.17, pow(p, 1.2)) : PaintLerp(0.012, 0.13, p * p)))
                if t < 1 { down.p[i] = 1 - PaintSstep(0, 1, t) }
            }
        }
        PaintPar(h) { row in
            let p = depth(row)
            let reach = unitPx * PaintLerp(0.016, 0.10, p * p)
            var gap: Float = 1e9
            for k in 0..<w {
                let col = dark ? w - 1 - k : k
                let i = row * w + col
                let l = Int(ref.level.p[i])
                if l < 18 {
                    gap = 1e9
                    continue
                }
                if l & 1 == 0 {
                    gap = 0
                    continue
                }
                gap += 1
                let t = gap / reach
                if t < 1 { across.p[i] = 1 - PaintSstep(0, 1, t) }
            }
        }
        // The two are scanned by column and by row; softened, so the scan never shows.
        let downSoft = down.blurred(max(1, w / 110)), acrossSoft = across.blurred(max(1, w / 110))
        PaintPar(h) { row in
            let p = depth(row)
            let under = shadeAt(p, far: shadeFar, near: shadeNear, mid: dark ? PaintHex(25, 34, 56) : PaintHex(146, 154, 182))
            for col in 0..<w {
                let i = row * w + col
                let l = Int(ref.level.p[i])
                if l < 18 || l & 1 == 0 { continue }
                let c = ref.rgb.get3(col, row)
                let a = max(downSoft.p[i] * (dark ? 0.94 : 0.58), acrossSoft.p[i] * (dark ? 0.62 : 0.45))
                ref.rgb.set3(col, row, PaintMix(c, under, a))
                if downSoft.p[i] > 0.45 { ref.soft.p[i] = max(ref.soft.p[i], 0.7) }
            }
        }
    }

    /// Shadows are bluest in the middle distance. Far off the air takes them; under the viewer they've come up nearly to the lit cloud, so nothing punches a hole in the bottom of the picture.
    @inline(__always) private static func shadeAt(_ p: Float, far: PaintV3, near: PaintV3, mid: PaintV3) -> PaintV3 {
        return p < 0.32 ? PaintMix(far, mid, p / 0.32) : PaintMix(mid, near, PaintSstep(0.32, 0.86, p))
    }

    /// A shadow in the deck: laid flat and level with a loaded brush, no curls, nothing small.
    @inline(__always) private static func writeShadow(_ ref: PaintSceneRef, _ col: Int, _ row: Int, _ i: Int, _ p: Float) {
        ref.setDir(col, row, angle: -0.05, strength: 1.3)
        ref.setBendToForm(col, row, 0.02)
        ref.setShape(col, row, length: 1.15, width: 1)
        ref.detail.p[i] = 0.05
        ref.soft.p[i] = 0.62
        ref.wet.p[i] = 0.42
        ref.blend.p[i] = 0.55
        ref.steady.p[i] = 0.35
        ref.focus.p[i] = 0
        ref.comb.p[i] = 0.5
    }

    @inline(__always) private static func deckColour(family: Float, ndl: Float, p: Float, u: Float, grain: Float, litHot: PaintV3, litWarm: PaintV3, litCool: PaintV3, shadeNear: PaintV3, shadeFar: PaintV3, shadeMid: PaintV3, quietLit: PaintV3, haze: PaintV3, dark: Bool) -> PaintV3 {
        // Nearer the source the crowns warm; away from it they cool.
        let towardLight = dark ? 1 - u : u
        let warmth = PaintSat(towardLight * 0.8 + 0.2)
        let lit = PaintMix(PaintMix(litCool, litWarm, warmth), litHot, PaintSstep(0.30, 0.86, ndl) * (0.45 + 0.55 * warmth))
        let shade = shadeAt(p, far: shadeFar, near: shadeNear, mid: shadeMid) * (1 + 0.05 * grain)
        var c = PaintMix(shade, lit, family)
        // Under the viewer the light has gone: the bottom of the picture is quiet, a few values apart.
        let quiet = PaintSstep(dark ? 0.24 : 0.35, dark ? 0.92 : 1.0, p) * (dark ? 0.88 : 0.66)
        c = PaintMix(c, dark ? shade * 1.15 : quietLit, quiet * family)
        // Toward the horizon everything dissolves into the air.
        c = PaintMix(c, haze, pow(1 - p, 4) * 0.52)
        return c
    }
}
