// PaintOceanScene sunset: open sea under a great cloud lit from a sun low on the water. At night, the moon behind the edge of the same cloud and its road on the sea.

import Foundation
import simd

nonisolated enum PaintOceanScene {
    /// One round heap of cloud. `sunk`: how far down in the mass it sits, so how little of it reaches the light. `domeX`, `domeY`: the middle of the big billow it belongs to, which a brush turns around.
    private struct Puff { var x, y, r, sunk, domeX, domeY, domeR: Float }

    /// One cloud: heaps of billows on a flat underside, lit on whichever side faces the light.
    private struct Mass {
        var puffs: [Puff]
        var base: Float
        var level: Int
        /// How far out it is: further, paler and with less contrast.
        var air: Float
        var rim: Float
        /// Low banks are flatter than they are tall.
        var squash: Float = 1
    }

    /// A cumulus: wide over its flat base, pulling in by shoulders to a crown. Big billows stand on one another, each carrying smaller ones along its upper side, so the outline is round everywhere and never a straight edge.
    private static func heap(cx: Float, base: Float, width: Float, height: Float, lean: Float, size: Float, squash: Float = 1, seed: UInt64) -> [Puff] {
        var rng = SplitMix64(seed: seed)
        let outline = PaintNoise(seed: seed &+ 11)
        var out: [Puff] = []
        let rows = max(2, Int(height / (size * squash * 0.78)))
        let generations = size < 0.05 ? 2 : 3
        for i in 0..<rows {
            let t = Float(i) / Float(rows - 1)
            let y = base - height * t - size * 0.1
            // Shoulders: the width comes in by steps, so the side of the cloud is a stack of bulges.
            let shoulder = 1 - 0.72 * pow(t, 1.25)
            let step = 0.90 + 0.34 * Float(outline.fbm(Double(t) * 4.6, 2.4, octaves: 2))
            let half = width * 0.5 * shoulder * step
            let r0 = size * PaintLerp(1, 0.72, t)
            let count = max(1, Int(2 * half / (r0 * 1.0)))
            for j in 0..<count {
                let x = cx + lean * t * height + PaintLerp(-half, half, (Float(j) + 0.5) / Float(count)) + Float(rng.next(-0.42, 0.42)) * r0
                let r = r0 * Float(rng.next(0.84, 1.22))
                let cy = y + Float(rng.next(-0.28, 0.28)) * r0
                var family: [(Float, Float, Float, Float)] = [(x, cy, r, 0)]
                for g in 1..<generations {
                    var next: [(Float, Float, Float, Float)] = []
                    for parent in family {
                        for _ in 0..<(g == 1 ? 6 : 4) {
                            let a = Float(rng.next(-Double.pi * 1.04, Double.pi * 0.04))
                            let rr = parent.2 * Float(rng.next(0.40, 0.60))
                            let reach = parent.2 * Float(rng.next(0.66, 0.96))
                            next.append((parent.0 + cos(a) * reach, parent.1 + sin(a) * reach * 0.9 * squash, rr, Float(g)))
                        }
                    }
                    family += next
                }
                for f in family {
                    out.append(Puff(x: f.0, y: f.1, r: f.2, sunk: PaintSat((f.1 - cy + r * 0.6 * squash) / (r * 1.5 * squash)), domeX: x, domeY: cy, domeR: r * 1.25))
                }
            }
        }
        out.sort { $0.y < $1.y }
        return out
    }

    static func scene(width: Int, height: Int, dark: Bool) -> PaintSceneRef {
        let w = min(width, 590)
        let h = Int((Float(height) * Float(w) / Float(width)).rounded())
        let ref = PaintSceneRef(w: w, h: h)
        ref.dark = dark
        ref.ground = dark ? PaintHex(18, 22, 36) : PaintHex(160, 104, 78)
        let unitPx = Float(w)
        let aspect = Float(height) / Float(width)
        let horizon = aspect * 0.665
        // Where the light is, on the picture: a sun low on the water, or a moon up behind the cloud's edge.
        let lightU: Float = dark ? 0.70 : 0.70
        let lightV: Float = dark ? aspect * 0.215 : horizon - 0.064
        let discR: Float = dark ? 0.040 : 0.040
        ref.lightDir = simd_normalize(SIMD2<Float>(0.7, dark ? -0.7 : -0.3))

        let lightSky: [(Float, PaintV3)] = [(0, PaintHex(38, 70, 124)), (0.24, PaintHex(64, 108, 158)), (0.46, PaintHex(128, 160, 176)), (0.64, PaintHex(214, 186, 150)), (0.82, PaintHex(246, 170, 104)), (0.95, PaintHex(252, 150, 80)), (1, PaintHex(255, 172, 90))]
        let darkSky: [(Float, PaintV3)] = [(0, PaintHex(5, 8, 20)), (0.30, PaintHex(8, 13, 32)), (0.62, PaintHex(12, 21, 46)), (0.90, PaintHex(19, 31, 58)), (1, PaintHex(24, 36, 62))]
        let sky = PaintGradient(stops: dark ? darkSky : lightSky)
        let glowColor = dark ? PaintHex(58, 76, 114) : PaintHex(255, 208, 128)
        let coreColor = dark ? PaintHex(124, 140, 170) : PaintHex(255, 226, 158)

        // Sky: a gradient, a glow that isn't rays, cirrus dragged across the top. Broad, and laid on one slant.
        let cn = PaintNoise(seed: 0x0CEA)
        PaintPar(h) { row in
            let v = (Float(row) + 0.5) / unitPx
            if v > horizon + 0.02 { return }
            for col in 0..<w {
                let u = (Float(col) + 0.5) / unitPx
                let i = row * w + col
                let drift = Float(cn.fbm(Double(u) * 2.1, Double(v) * 3.1, octaves: 3))
                var c = sky.at(min(1, (v + drift * 0.05) / horizon))
                let dx = u - lightU, dy = (v - lightV) * (dark ? 1 : 1.7)
                let d2 = dx * dx + dy * dy
                c = PaintMix(c, glowColor, exp(-d2 / (dark ? 0.09 : 0.20)) * (dark ? 0.55 : 0.74))
                c = PaintMix(c, coreColor, exp(-d2 / (dark ? 0.010 : 0.010)) * (dark ? 0.70 : 0.92))
                let su = Double(u + v * 0.35), sv = Double(v - u * 0.20)
                let streak = Float(cn.fbm(su * 3.2, sv * 19, octaves: 4))
                let veil = PaintSstep(0.04, 0.38, streak) * PaintSstep(horizon * 0.72, horizon * 0.22, v)
                c = PaintMix(c, dark ? PaintHex(28, 40, 70) : PaintHex(238, 194, 170), veil * (dark ? 0.45 : 0.50))
                ref.rgb.set3(col, row, c)
                ref.setDir(col, row, angle: -0.30 + 0.45 * Float(cn.value(Double(u) * 1.6, Double(v) * 1.2)), strength: 2.2)
                ref.setBendToForm(col, row, 0.05)
                ref.soft.p[i] = 0.9
                ref.steady.p[i] = 0.5
                ref.detail.p[i] = 0.10 + 0.20 * PaintSat(veil)
            }
        }

        // The clouds. A great tower on the left against the gold, banks low on the horizon, far scraps.
        let scaleV = aspect / 2.168
        let cloudBase = horizon - 0.205
        var masses: [Mass] = []
        // Far off to the right of the sun, a small bank; a high cloud catching the light on its underside.
        masses.append(Mass(puffs: heap(cx: 1.10, base: horizon - 0.018, width: 0.46, height: 0.045, lean: 0, size: 0.034, squash: 0.62, seed: 81), base: horizon - 0.010, level: 30, air: 0.56, rim: 0.7, squash: 0.62))
        masses.append(Mass(puffs: heap(cx: 0.96, base: dark ? lightV + 0.30 : 0.60 * scaleV, width: 0.56, height: 0.070, lean: -0.2, size: 0.052, squash: 0.74, seed: 82), base: dark ? lightV + 0.31 : 0.61 * scaleV, level: 32, air: dark ? 0.55 : 0.34, rim: dark ? 0.6 : 1.3, squash: 0.74))
        // The great cloud, on its flat dark base.
        masses.append(Mass(puffs: heap(cx: 0.13, base: cloudBase - 0.03, width: 1.06, height: cloudBase - 0.03 - 0.47 * scaleV, lean: 0.10, size: 0.150, seed: 83), base: cloudBase + 0.012, level: 20, air: 0.0, rim: dark ? 0.86 : 1))
        // And a low bank under it that stops short of the sun.
        masses.append(Mass(puffs: heap(cx: 0.08, base: horizon - 0.016, width: 0.84, height: 0.050, lean: 0.06, size: 0.044, squash: 0.56, seed: 84), base: horizon - 0.006, level: 24, air: 0.40, rim: 0.9, squash: 0.56))
        let warpNoise = PaintNoise(seed: 0xDEC7)
        let wx = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(warpNoise.fbm(u * 22, v * 22, octaves: 3)) }
        let wy = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(warpNoise.fbm(u * 22 + 17, v * 22 - 9, octaves: 3)) }
        let grain = PaintNoiseField(w: w, h: h, step: 4) { u, v in Float(warpNoise.fbm(u * 4.4 + 3, v * 5.1, octaves: 3)) }
        let shadowDeep = dark ? PaintHex(14, 19, 37) : PaintHex(62, 66, 96)
        let shadowHigh = dark ? PaintHex(19, 27, 48) : PaintHex(104, 108, 140)
        let shadowWarm = dark ? PaintHex(26, 36, 60) : PaintHex(150, 104, 108)
        // Lit billows: rose where the light has come far, peach and gold close to the sun.
        let litFar = dark ? PaintHex(34, 46, 72) : PaintHex(190, 146, 150)
        let litNear = dark ? PaintHex(70, 86, 118) : PaintHex(244, 170, 122)
        let litHot = dark ? PaintHex(126, 140, 168) : PaintHex(255, 220, 160)
        let airColor = dark ? PaintHex(22, 32, 56) : PaintHex(232, 170, 128)
        for mass in masses {
            let puffs = mass.puffs
            let bands = 48, rowsPerBand = h / bands + 1
            let level20Foot = mass.level == 20
            let baseNoise = PaintNoise(seed: UInt64(mass.level) + 400)
            // A flat underside.
            var limits = [Float](repeating: 0, count: w)
            for col in 0..<w {
                let u = (Float(col) + 0.5) / unitPx
                var under = Float(baseNoise.fbm(Double(u) * 6, 1.2, octaves: 3)) * (mass.level == 20 ? 0.030 : 0.012)
                if mass.level == 20 {
                    // The great cloud's belly is round: three slow bulges, and it comes up to meet its own side instead of running out to a point.
                    for (at, reach, drop) in [(Float(0.10), Float(0.13), Float(0.026)), (0.34, 0.11, 0.034), (0.55, 0.08, 0.018)] {
                        let d = (u - at) / reach
                        under += drop * exp(-d * d)
                    }
                    let tip = PaintSstep(0.52, 0.74, u)
                    under -= 0.050 * tip * tip
                }
                limits[col] = (mass.base + under) * unitPx
            }
            let baseLimit = limits
            let air = mass.air, massBase = mass.base, levelShade = Float(mass.level), squash = mass.squash, rim = mass.rim
            PaintPar(bands) { band in
                let r0 = band * rowsPerBand, r1 = min(h, r0 + rowsPerBand)
                if r0 >= h { return }
                let done = UnsafeMutablePointer<Bool>.allocate(capacity: (r1 - r0) * w)
                done.initialize(repeating: false, count: (r1 - r0) * w)
                defer { done.deallocate() }
                // From the front back: what's lower stands in front, and a place once painted is done.
                for index in stride(from: puffs.count - 1, through: 0, by: -1) {
                    let puff = puffs[index]
                    let reach = puff.r * 1.3 * unitPx
                    let cy = puff.y * unitPx, cx = puff.x * unitPx
                    let top = max(r0, Int(cy - reach * squash)), bottom = min(r1 - 1, Int(cy + reach * squash))
                    let left = max(0, Int(cx - reach)), right = min(w - 1, Int(cx + reach))
                    if top > bottom || left > right { continue }
                    let inv = 1 / (puff.r * unitPx), invY = inv / squash, domeInv = 1 / (puff.domeR * unitPx), domeInvY = domeInv / squash, wobble = min(puff.r * 0.30, 0.012) * unitPx
                    // Each billow looks toward the light from where it is: a sun low on the water lights sides and shoulders, never a straight underside.
                    let lx = lightU - puff.x, ly = lightV - puff.y
                    let toLight = dark ? simd_normalize(PaintV3(lx, ly, 0.42)) : simd_normalize(PaintV3(lx + 0.34, ly * 0.34 - 0.20, 0.34))
                    let dist = (lx * lx + ly * ly * (dark ? 1 : 0.7)).squareRoot()
                    let warm = exp(-dist * dist / (dark ? 0.14 : 0.42))
                    // Deep in the mass and lower down, less of a billow reaches the light.
                    // By moonlight the crown would part from the body at its neck, so the light carries across there.
                    let neckX = puff.x - 0.34, neckY = puff.y - 0.452 * scaleV
                    let neck = dark && mass.level == 20 ? PaintSstep(0.13, 0.04, (neckX * neckX + neckY * neckY).squareRoot()) : 0
                    let threshold = (dark ? 0.34 : 0.22) + 0.42 * PaintSstep(0.25, 1.0, puff.sunk) + (dark ? 0.38 : 0.05) * PaintSstep(dark ? 0.32 : 0.7, dark ? 0.9 : 1.3, dist) - 0.42 * neck
                    let domeX = puff.domeX * unitPx, domeY = puff.domeY * unitPx
                    for row in top...bottom {
                        let v = (Float(row) + 0.5) / unitPx
                        let doneRow = (row - r0) * w
                        let altitude = PaintSat((massBase - v) / 0.9)
                        let baseShade = PaintMix(shadowDeep, shadowHigh, PaintSstep(0.0, 0.5, altitude))
                        // The cloud's belly is all shadow, and so is its flat base: no caves of light under it.
                        let foot = level20Foot ? PaintSstep(0.05, 0.17, massBase - v) : PaintSstep(0.0, 0.03, massBase - v)
                        for col in left...right {
                            if done[doneRow + col] { continue }
                            let i = row * w + col
                            if Float(row) >= baseLimit[col] { continue }
                            let px = Float(col) + 0.5 + wx.p[i] * wobble, py = Float(row) + 0.5 + wy.p[i] * wobble
                            let dx = (px - cx) * inv, dy = (py - cy) * invY
                            let d2 = dx * dx + dy * dy
                            if d2 >= 1 { continue }
                            done[doneRow + col] = true
                            let n = PaintV3(dx, dy, (1 - d2).squareRoot())
                            let g = grain.p[i]
                            // Small bumps only move the edge of the light: the big billow they belong to decides which side is lit.
                            let bx = PaintSat(((px - domeX) * domeInv + 1) * 0.5) * 2 - 1, by = PaintSat(((py - domeY) * domeInvY + 1) * 0.5) * 2 - 1
                            let big = simd_dot(PaintV3(bx, by, max(0, 1 - bx * bx - by * by).squareRoot()), toLight)
                            let ndl = PaintLerp(simd_dot(n, toLight), big, 0.52)
                            let lit = (ndl + g * 0.14 - threshold) * foot - (1 - foot) * 0.2
                            let family = PaintSstep(-0.10, 0.14, lit) * rim
                            // The shadow is one quiet family that warms toward the light and lifts where it turns toward it.
                            var shade = PaintMix(baseShade, shadowWarm, warm * (dark ? 0.5 : 0.62))
                            shade *= PaintLerp(0.92, 1.12, PaintSat(0.5 + 0.7 * ndl)) + 0.05 * g
                            var bright = PaintMix(litFar, litNear, warm)
                            bright = PaintMix(bright, litHot, PaintSstep(0.20, 0.80, lit) * PaintSat(warm * 1.5))
                            var c = PaintMix(shade, bright, PaintSat(family))
                            c = PaintMix(c, airColor, air)
                            ref.rgb.set3(col, row, c)
                            // A brush turns round the big billow.
                            let turn = atan2(py - domeY, px - domeX) + .pi / 2
                            if lit > 0 {
                                ref.level.p[i] = levelShade + 1
                                ref.setDir(col, row, angle: turn, strength: 1.1)
                                ref.setBendToForm(col, row, 0.3)
                                ref.detail.p[i] = PaintLerp(0.34, 0.20, PaintSat(dist)) * (1 - air * 0.5)
                                ref.soft.p[i] = lit < 0.12 ? 0.76 : 0.14
                                ref.wet.p[i] = 0.16
                                ref.blend.p[i] = 0
                                ref.steady.p[i] = 0.5
                                ref.setShape(col, row, length: 0.8, width: 0.9)
                            } else {
                                ref.level.p[i] = levelShade
                                ref.setDir(col, row, angle: turn, strength: 0.8)
                                ref.setBendToForm(col, row, 0.25)
                                ref.detail.p[i] = 0.07
                                ref.soft.p[i] = lit > -0.10 ? 0.78 : 0.62
                                ref.wet.p[i] = 0.45
                                ref.blend.p[i] = 0.42
                                ref.steady.p[i] = 0.45
                                ref.setShape(col, row, length: 0.9, width: 1)
                            }
                            ref.comb.p[i] = 0.6
                        }
                    }
                }
            }
        }

        // The sea.
        let wave = PaintNoise(seed: 0x5EA5)
        let farCool = dark ? PaintHex(24, 34, 58) : PaintHex(168, 124, 118)
        let farWarm = dark ? PaintHex(44, 56, 84) : PaintHex(240, 178, 122)
        let midSea = dark ? PaintHex(12, 20, 38) : PaintHex(74, 100, 118)
        let nearSea = dark ? PaintHex(6, 10, 22) : PaintHex(24, 48, 74)
        let roadFar = dark ? PaintHex(150, 158, 170) : PaintHex(255, 228, 170)
        let roadNear = dark ? PaintHex(96, 108, 130) : PaintHex(232, 170, 110)
        let glowOnWater = dark ? PaintHex(40, 52, 78) : PaintHex(214, 142, 92)
        let span = aspect - horizon
        PaintPar(h) { row in
            let v = (Float(row) + 0.5) / unitPx
            if v < horizon { return }
            for col in 0..<w {
                let u = (Float(col) + 0.5) / unitPx
                let i = row * w + col
                let t = PaintSat((v - horizon) / span)
                let dx = u - lightU
                // Far water holds the sky; the slide into the deep is long, a good part of the picture's height.
                let warmth = exp(-dx * dx / 0.20)
                var c = PaintMix(farCool, farWarm, warmth)
                c = PaintMix(c, midSea, PaintSstep(0.0, 0.46, t))
                c = PaintMix(c, nearSea, PaintSstep(0.22, 1.0, t))
                let xw = Double(dx) / Double(t + 0.07), yw = log(Double(t) + 0.025)
                let swell = Float(wave.fbm(xw * 0.9 + 4, yw * 9.5, octaves: 3))
                // Waves are hardly different from each other near the horizon, a little more further in, and rest again at the bottom.
                let gap = PaintLerp(0.10, 0.20, PaintSstep(0.0, 0.4, t)) * PaintLerp(1, 0.42, PaintSstep(0.55, 1.0, t))
                c *= 1 + swell * gap
                // The road: a soft glow first, right under the light and widening toward us, then long level dashes over it that die out to the sides.
                let roadWidth = 0.040 + 0.26 * t
                let glow = exp(-dx * dx / (roadWidth * roadWidth))
                c = PaintMix(c, glowOnWater, glow * PaintLerp(0.74, 0.22, PaintSstep(0.0, 0.85, t)))
                let wander = Float(wave.fbm(xw * 0.8 + 11, yw * 22, octaves: 2))
                let dash = PaintSstep(-0.05, 0.30, Float(wave.fbm(xw * 0.55 + 31, yw * 30, octaves: 3)) + wander * 0.2)
                let road = dash * exp(-dx * dx / (roadWidth * roadWidth * (0.7 + 2.2 * PaintSat(0.5 + wander * 1.4)))) * PaintSstep(1.0, 0.0, t)
                let level: Float = 7
                c = PaintMix(c, PaintMix(roadFar, roadNear, PaintSstep(0.0, 0.7, t)), PaintSat(road * 1.2) * PaintLerp(0.95, 0.42, PaintSstep(0, 0.8, t)))
                // A firm line where the sea meets the sky.
                c *= 1 - 0.14 * PaintSstep(0.005, 0.0, v - horizon)
                ref.rgb.set3(col, row, c)
                ref.level.p[i] = level
                ref.setDir(col, row, angle: 0.004, strength: 4)
                ref.setBendToForm(col, row, 0)
                // Long, thin and level near the horizon; long and broad toward us.
                ref.setShape(col, row, length: PaintLerp(1.9, 1.5, t), width: PaintLerp(0.34, 0.85, PaintSstep(0.0, 0.6, t)))
                ref.steady.p[i] = 0.10
                ref.comb.p[i] = 0.62
                ref.detail.p[i] = PaintLerp(0.34, 0.02, PaintSstep(0, 0.65, t))
                ref.soft.p[i] = t < 0.012 ? 0.2 : 0.68
                ref.wet.p[i] = PaintLerp(0.1, 0.5, t)
                ref.blend.p[i] = PaintSstep(0.45, 0.9, t) * 0.5
                ref.focus.p[i] = 0
            }
        }
        // Long level marks of pure paint on the road, by hand: thin and close together far away, broad and spaced toward us. Never brighter than most of the disc.
        var hand = SplitMix64(seed: 0x60AD)
        let marks = 92
        for k in 0..<marks {
            let f = (Float(k) + Float(hand.next(0.1, 0.9))) / Float(marks)
            let t = pow(f, 1.9) * 0.74
            let y = horizon + 0.004 + t * span
            let spread = 0.030 + 0.21 * t
            let gauss = (Float(hand.next(-1, 1)) + Float(hand.next(-1, 1))) * 0.62
            let x = lightU + gauss * spread
            let centred = exp(-gauss * gauss * 0.9)
            let length = (0.05 + 0.40 * t) * Float(hand.next(0.6, 1.4)) * PaintLerp(0.6, 1, centred)
            let wid = (0.0032 + 0.015 * t) * Float(hand.next(0.7, 1.25))
            let colour = PaintMix(PaintMix(roadFar, roadNear, PaintSstep(0.0, 0.62, t)), glowOnWater, (1 - centred) * 0.45)
            ref.authored.append(PaintAuthoredStroke(x: x, y: y, angle: Float(hand.next(-0.008, 0.008)), length: length, width: wid, color: colour, alpha: PaintLerp(0.86, 0.16, pow(t / 0.74, 1.3)), load: 0.92, thick: 0.45,
                                               round: 0.5, feather: 0.2, taper: 0.55, tipIn: 1, tipOut: 1, comb: 0.5))
        }
        // The disc goes on by hand over the finished glow, one loaded touch of the brush: cream, not white, and never outlined.
        if dark {
            ref.discs.append(PaintDisc(x: lightU, y: lightV, r: discR, lit: PaintHex(232, 232, 222), shade: PaintHex(204, 208, 208), angle: -0.75, softLit: 0.05, softShade: 0.36))
            // A thin bank of cloud drifting across its lower part, carrying the colour of the sky around it, the same slant as the sky's marks.
            var veil = SplitMix64(seed: 0x7E11)
            for k in 0..<6 {
                let f = Float(k) / 5
                let y = lightV + PaintLerp(0.008, 0.058, f)
                let x = lightU + Float(veil.next(-0.03, 0.03))
                ref.authored.append(PaintAuthoredStroke(x: x, y: y, angle: -0.20 + Float(veil.next(-0.03, 0.03)), length: Float(veil.next(0.16, 0.30)), width: PaintLerp(0.010, 0.026, f) * Float(veil.next(0.8, 1.2)), color: .zero, alpha: PaintLerp(0.30, 0.78, f), load: 0.9, thick: 0.1,
                                                   round: 0.6, pick: SIMD2(0, 0.10), feather: 1, pickTint: PaintV3(repeating: 0.92), taper: 0.8, tipIn: 1, tipOut: 1, comb: 0.3))
            }
        } else {
            ref.discs.append(PaintDisc(x: lightU, y: lightV, r: discR, lit: PaintHex(255, 244, 202), shade: PaintHex(255, 220, 150), angle: -.pi / 2, softLit: 0.07, softShade: 0.34))
            // Its foot goes into the haze.
            var haze = SplitMix64(seed: 0x7E12)
            for k in 0..<4 {
                let f = Float(k) / 3
                ref.authored.append(PaintAuthoredStroke(x: lightU + Float(haze.next(-0.02, 0.02)), y: lightV + PaintLerp(0.016, 0.042, f), angle: Float(haze.next(-0.02, 0.02)), length: Float(haze.next(0.14, 0.24)), width: PaintLerp(0.006, 0.014, f), color: .zero, alpha: PaintLerp(0.35, 0.8, f), load: 0.9, thick: 0.1,
                                                   round: 0.6, pick: SIMD2(0.11, 0), feather: 1, taper: 0.8, tipIn: 1, tipOut: 1, comb: 0.3))
            }
        }
        // Scraps of light too small to be a billow go back to the shadow they sit in.
        ref.pruneLevels(minArea: Int(0.0011 * unitPx * unitPx), only: [20, 21, 24, 25, 30, 31, 32, 33])
        // Far away a dash can be a hairline; near us a scrap is a stray.
        let horizonRow = horizon * unitPx, spanRows = span * unitPx
        ref.pruneLevels(minArea: Int(0.00022 * unitPx * unitPx)) { row in
            let t = PaintSat((Float(row) - horizonRow) / spanRows)
            return 1 + 24 * t * t
        }

        if dark {
            let moonX = lightU, moonY = lightV
            PaintAddStars(to: ref, count: 20, aspectTop: lightV * 0.95, seed: 0x5743) { x, y in
                let dx = x - moonX, dy = y - moonY
                if dx * dx + dy * dy < 0.05 || y > horizon * 0.34 { return false }
                for k in 0..<9 {
                    let a = Float(k) * 0.785, reach: Float = k == 8 ? 0 : 0.13
                    let c = min(w - 1, max(0, Int((x + cos(a) * reach) * unitPx))), r = min(h - 1, max(0, Int((y + sin(a) * reach) * unitPx)))
                    if ref.level.at(c, r) != 1 { return false }
                }
                return true
            }
        }
        return ref
    }
}
