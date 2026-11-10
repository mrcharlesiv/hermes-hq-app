// What the valley, the wood, the mesas, the peaks and the harbor share: how paint is laid at a place, a laid-in sky, flat planes, and round heaps of leaves.

import Foundation
import simd

/// How paint is laid at a place: everything a scene says about a mark, in one value.
nonisolated struct PaintTouch: Sendable {
    var level: Float
    var angle: Float = 0
    var hold: Float = 1
    var bend: Float = 0.2
    var detail: Float = 0.1
    var soft: Float = 0.5
    var wet: Float = 0.2
    var blend: Float = 0
    var steady: Float = 0.4
    var comb: Float = 0.6
    var focus: Float = 0
    var long: Float = 1
    var wide: Float = 1
}

nonisolated extension PaintSceneRef {
    @inline(__always) func paintLay(_ col: Int, _ row: Int, _ c: PaintV3, _ t: PaintTouch) {
        rgb.set3(col, row, c)
        paintLayMarks(col, row, t)
    }

    @inline(__always) func paintLayMarks(_ col: Int, _ row: Int, _ t: PaintTouch) {
        let i = row * w + col
        level.p[i] = t.level
        setDir(col, row, angle: t.angle, strength: t.hold)
        formWeight.p[i] = t.bend
        detail.p[i] = t.detail
        soft.p[i] = t.soft
        wet.p[i] = t.wet
        blend.p[i] = t.blend
        steady.p[i] = t.steady
        comb.p[i] = t.comb
        focus.p[i] = t.focus
        setShape(col, row, length: t.long, width: t.wide)
    }
}

/// A number from 0 to 1 for a cell of a grid: the same cell, the same number.
@inline(__always) nonisolated func PaintCellHash(_ a: Int32, _ b: Int32, _ c: Int32 = 0) -> Float {
    var h = UInt32(truncatingIfNeeded: a) &* 0x8DA6_B343 &+ UInt32(truncatingIfNeeded: b) &* 0xD816_3841 &+ UInt32(truncatingIfNeeded: c) &* 0xCB1A_B31F &+ 0x9E37_79B9
    h ^= h >> 15
    h = h &* 0x2C1B_3C6D
    h ^= h >> 12
    h = h &* 0x297A_2D39
    h ^= h >> 15
    return Float(h >> 8) / Float(1 << 24)
}

/// The sky, laid level and broad: a gradient down to `bottom`, a warm band low on one side, a few long streaks of high cloud. It rests the eye.
nonisolated func PaintLaySky(_ ref: PaintSceneRef, sky: PaintGradient, bottom: Float, veil: PaintV3, veilAmount: Float, low: PaintV3, lowAmount: Float, lowFrom: Float, lowTo: Float, tilt: Float = -0.05, streakScale: Double = 15, seed: UInt64) {
    let w = ref.w, h = ref.h
    let unitPx = Float(w)
    let n = PaintNoise(seed: seed)
    let drift = PaintNoiseField(w: w, h: h, step: 4) { u, v in Float(n.fbm(u * 1.7, v * 2.3, octaves: 3)) }
    let streak = PaintNoiseField(w: w, h: h, step: 2) { u, v in Float(n.fbm((u - v * 0.05) * 1.6, v * streakScale, octaves: 4)) }
    let turn = PaintNoiseField(w: w, h: h, step: 8) { u, v in Float(n.value(u * 1.2, v * 0.9)) }
    let lastRow = min(h, Int((bottom + 0.02) * unitPx) + 2)
    PaintPar(lastRow) { row in
        let v = (Float(row) + 0.5) / unitPx
        let topEase = PaintSstep(bottom * 0.04, bottom * 0.26, v)
        let band = PaintSstep(0.84, 1.0, v / bottom)
        for col in 0..<w {
            let i = row * w + col
            let u = (Float(col) + 0.5) / unitPx
            var c = sky.at(min(1, (v + drift.p[i] * 0.05) / bottom))
            c = PaintMix(c, low, band * PaintLerp(lowFrom, lowTo, min(1, u)) * lowAmount)
            let cover = PaintSstep(0.04, 0.42, streak.p[i]) * topEase
            c = PaintMix(c, veil, cover * veilAmount)
            ref.rgb.set3(col, row, c)
            ref.setDir(col, row, angle: tilt + 0.05 * turn.p[i], strength: 2.2)
            ref.formWeight.p[i] = 0.05
            ref.steady.p[i] = 0.22
            ref.detail.p[i] = 0
            ref.soft.p[i] = 0.95
            ref.setShape(col, row, length: 1.25, width: 0.95)
        }
    }
}

/// A sky of high cirrus on one slant: the marks and the streaks both run at `angle`, and `sweep` bends them across the picture.
nonisolated func PaintLayCirrus(_ ref: PaintSceneRef, sky: PaintGradient, bottom: Float, veil: PaintV3, veilAmount: Float, low: PaintV3, lowAmount: Float, lowFrom: Float, lowTo: Float, angle: Float, sweep: Float = 0, along: Double = 2.2, across: Double = 9, clearBelow: Float = 0.74, seed: UInt64) {
    let w = ref.w, h = ref.h
    let unitPx = Float(w)
    let n = PaintNoise(seed: seed)
    let slope = tan(angle)
    let drift = PaintNoiseField(w: w, h: h, step: 4) { u, v in Float(n.fbm(u * 2.1, v * 3.1, octaves: 3)) }
    let streak = PaintNoiseField(w: w, h: h, step: 2) { u, v in
        let bent = Float(v) - Float(u) * slope - sweep * sin(Float(u) * 2.6 + Float(v) * 1.1)
        return Float(n.fbm((u + v * 0.35) * along, Double(bent) * across, octaves: 3))
    }
    let turn = PaintNoiseField(w: w, h: h, step: 8) { u, v in Float(n.value(u * 1.6, v * 1.2)) }
    let lastRow = min(h, Int((bottom + 0.02) * unitPx) + 2)
    PaintPar(lastRow) { row in
        let v = (Float(row) + 0.5) / unitPx
        let band = PaintSstep(0.84, 1.0, v / bottom)
        let reach = PaintSstep(bottom * clearBelow, bottom * 0.24, v)
        for col in 0..<w {
            let i = row * w + col
            let u = (Float(col) + 0.5) / unitPx
            var c = sky.at(min(1, (v + drift.p[i] * 0.05) / bottom))
            c = PaintMix(c, low, band * PaintLerp(lowFrom, lowTo, min(1, u)) * lowAmount)
            let cover = PaintSstep(0.10, 0.42, streak.p[i]) * reach
            c = PaintMix(c, veil, cover * veilAmount)
            ref.rgb.set3(col, row, c)
            let bend = atan(slope + sweep * 2.6 * cos(u * 2.6 + v * 1.1))
            ref.setDir(col, row, angle: bend + 0.16 * turn.p[i], strength: 2.2)
            ref.formWeight.p[i] = 0.05
            ref.steady.p[i] = 0.3
            ref.detail.p[i] = 0
            ref.comb.p[i] = 0.55
            ref.soft.p[i] = 0.92
            ref.wet.p[i] = 0.4
            ref.setShape(col, row, length: 1.25, width: 1.0)
        }
    }
}

/// A flat plane of paint, its corners in width units.
nonisolated func PaintFillPlane(_ ref: PaintSceneRef, _ corners: [SIMD2<Float>], color: PaintV3, color2: PaintV3? = nil, _ t: PaintTouch) {
    let w = ref.w, h = ref.h
    let unitPx = Float(w)
    var top = Float.greatestFiniteMagnitude, bottom = -Float.greatestFiniteMagnitude
    for p in corners {
        top = min(top, p.y)
        bottom = max(bottom, p.y)
    }
    let rowA = max(0, Int(top * unitPx)), rowB = min(h - 1, Int(bottom * unitPx))
    if rowA > rowB { return }
    let span = max(0.0001, bottom - top)
    var crossings: [Float] = []
    for row in rowA...rowB {
        let v = (Float(row) + 0.5) / unitPx
        crossings.removeAll(keepingCapacity: true)
        for k in 0..<corners.count {
            let a = corners[k], b = corners[(k + 1) % corners.count]
            if (a.y <= v) != (b.y <= v) { crossings.append(a.x + (v - a.y) / (b.y - a.y) * (b.x - a.x)) }
        }
        crossings.sort()
        var k = 0
        let c = color2.map { PaintMix(color, $0, (v - top) / span) } ?? color
        while k + 1 < crossings.count {
            let from = max(0, Int((crossings[k] * unitPx).rounded())), to = min(w - 1, Int((crossings[k + 1] * unitPx).rounded()) - 1)
            if from <= to {
                for col in from...to { ref.paintLay(col, row, c, t) }
            }
            k += 2
        }
    }
}

/// One round heap of leaves or cloud. `sunk`: how far down it sits in its mass, so how little reaches the light. The dome is the big form it belongs to.
nonisolated struct PaintPuff: Sendable {
    var x, y, r: Float
    var squash: Float = 1
    var sunk: Float = 0
    var domeX, domeY, domeR: Float
    /// How far out it is, how much air stands in front of it.
    var air: Float = 0
    /// How much of the second leaf colour it has.
    var tint: Float = 0
    var level: Float
}

/// The colours and manners of a family of heaps.
nonisolated struct PaintPuffLook: Sendable {
    var shade: PaintV3, shadeDeep: PaintV3
    var lit: PaintV3, lit2: PaintV3, hot: PaintV3
    var haze: PaintV3
    /// Toward the light: x right, y down, z toward us.
    var light: PaintV3
    var threshold: Float = 0.2
    var sink: Float = 0.5
    /// Marks: finer where the study wants finer.
    var detail: Float = 0.42
    var long: Float = 0.7
    var wide: Float = 1
    /// Levels: shadow at `level`, light at `level + 1`.
}

/// A round crown: a few big forms, each carrying smaller ones, more toward the top. Appended back to front.
nonisolated func PaintCrown(x: Float, y: Float, r: Float, squash: Float = 0.92, air: Float = 0, tint: Float = 0, level: Float, generations: Int = 3, spread: Float = 1, sunkBias: Float = 0, rng: inout SplitMix64, into out: inout [PaintPuff]) {
    var mine: [PaintPuff] = []
    var family: [(Float, Float, Float)] = [(x, y, r * 0.8)]
    for g in 1..<max(2, generations) {
        var next: [(Float, Float, Float)] = []
        for parent in family {
            for _ in 0..<(g == 1 ? 7 : 4) {
                let a = Float(rng.next(-Double.pi * 1.12, Double.pi * 0.12))
                let rr = parent.2 * Float(rng.next(0.42, 0.62))
                let reach = parent.2 * Float(rng.next(0.60, 1.0)) * spread
                next.append((parent.0 + cos(a) * reach, parent.1 + sin(a) * reach * squash, rr))
            }
        }
        family += next
    }
    let t = tint + Float(rng.next(-0.15, 0.15))
    for f in family {
        mine.append(PaintPuff(x: f.0, y: f.1, r: f.2, squash: squash, sunk: PaintSat((f.1 - y + r * 0.55 * squash) / (r * 1.5 * squash) + sunkBias), domeX: x, domeY: y, domeR: r * 1.3, air: air, tint: PaintSat(t), level: level))
    }
    mine.sort { $0.y < $1.y }
    out += mine
}

/// A big old tree: several crowns massed together, the low ones in shadow.
nonisolated func PaintOak(x: Float, base: Float, r: Float, air: Float, tint: Float, level: Float, shaded: Float = 0, rng: inout SplitMix64, into out: inout [PaintPuff]) {
    let crownY = base - r * 1.02
    var spots: [(Float, Float, Float)] = [(x, crownY, r * 0.56)]
    let around = r > 0.08 ? 9 : 6
    for k in 0..<around {
        let a = Float(k) / Float(around) * 6.283 + Float(rng.next(-0.3, 0.3))
        let d = Float(rng.next(0.58, 0.82))
        spots.append((x + cos(a) * d * r * 0.86, crownY + sin(a) * d * r * 0.70, r * Float(rng.next(0.36, 0.50))))
    }
    spots.sort { $0.1 < $1.1 }
    for s in spots {
        PaintCrown(x: s.0, y: s.1, r: s.2, squash: 0.86, air: air, tint: tint, level: level, generations: r > 0.05 ? 3 : 2, sunkBias: shaded + (s.1 - crownY) / r * 0.42, rng: &rng, into: &out)
    }
}

/// Heaps, given back to front, painted from the front back: a place once painted is done.
nonisolated func PaintLayPuffs(_ ref: PaintSceneRef, _ puffs: [PaintPuff], look: PaintPuffLook, warpX: PaintBuf, warpY: PaintBuf, grain: PaintBuf) {
    let w = ref.w, h = ref.h
    if puffs.isEmpty { return }
    let unitPx = Float(w)
    var lowest: Float = 0, highest: Float = .greatestFiniteMagnitude
    for p in puffs {
        lowest = max(lowest, p.y + p.r * 1.3)
        highest = min(highest, p.y - p.r * 1.3)
    }
    let firstRow = max(0, Int(highest * unitPx)), lastRow = min(h - 1, Int(lowest * unitPx))
    if firstRow > lastRow { return }
    let rowsPerBand = max(8, (lastRow - firstRow + 1) / 24 + 1)
    let bands = (lastRow - firstRow) / rowsPerBand + 1
    PaintPar(bands) { band in
        let r0 = firstRow + band * rowsPerBand, r1 = min(lastRow + 1, r0 + rowsPerBand)
        if r0 >= r1 { return }
        let done = UnsafeMutablePointer<Bool>.allocate(capacity: (r1 - r0) * w)
        done.initialize(repeating: false, count: (r1 - r0) * w)
        defer { done.deallocate() }
        for index in stride(from: puffs.count - 1, through: 0, by: -1) {
            let puff = puffs[index]
            let reach = puff.r * 1.3 * unitPx
            let cy = puff.y * unitPx, cx = puff.x * unitPx
            let top = max(r0, Int(cy - reach * puff.squash)), bottom = min(r1 - 1, Int(cy + reach * puff.squash))
            let left = max(0, Int(cx - reach)), right = min(w - 1, Int(cx + reach))
            if top > bottom || left > right { continue }
            let inv = 1 / (puff.r * unitPx), invY = inv / puff.squash
            let domeInv = 1 / (puff.domeR * unitPx), domeInvY = domeInv / puff.squash
            let wobble = min(puff.r * 0.34, 0.010) * unitPx
            let threshold = look.threshold + look.sink * PaintSstep(0.25, 1.0, puff.sunk)
            let domeX = puff.domeX * unitPx, domeY = puff.domeY * unitPx
            let litHere = PaintMix(look.lit, look.lit2, puff.tint)
            let shadeHere = PaintMix(look.shade, look.shadeDeep, PaintSstep(0.3, 1.0, puff.sunk))
            // A small heap needs a small brush, in its shadow as much as in its light.
            let small = PaintSstep(0.045, 0.012, puff.r)
            let detail = max(look.detail * (1 - puff.air * 0.5), 0.86 * small)
            let shadeDetail = max(detail * 0.5, 0.86 * small)
            for row in top...bottom {
                let doneRow = (row - r0) * w
                for col in left...right {
                    if done[doneRow + col] { continue }
                    let i = row * w + col
                    let px = Float(col) + 0.5 + warpX.p[i] * wobble, py = Float(row) + 0.5 + warpY.p[i] * wobble
                    let dx = (px - cx) * inv, dy = (py - cy) * invY
                    let d2 = dx * dx + dy * dy
                    if d2 >= 1 { continue }
                    done[doneRow + col] = true
                    let n = PaintV3(dx, dy, (1 - d2).squareRoot())
                    let g = grain.p[i]
                    let bx = max(-1, min(1, (px - domeX) * domeInv)), by = max(-1, min(1, (py - domeY) * domeInvY))
                    let big = simd_dot(PaintV3(bx, by, max(0, 1 - bx * bx - by * by).squareRoot()), look.light)
                    let ndl = PaintLerp(simd_dot(n, look.light), big, 0.42)
                    let litness = ndl + g * 0.16 - threshold
                    let family = PaintSstep(-0.07, 0.10, litness)
                    var bright = litHere
                    bright = PaintMix(bright, look.hot, 0.8 * PaintSstep(0.20, 0.66, litness))
                    var c = PaintMix(shadeHere * (1 + 0.10 * g), bright, family)
                    c = PaintMix(c, look.haze, puff.air)
                    ref.rgb.set3(col, row, c)
                    // Short touches that turn loosely round the form: leaves, not a swirl.
                    let turn = atan2(dy, dx) + .pi / 2 + g * 2.4
                    ref.level.p[i] = litness > 0 ? puff.level + 1 : puff.level
                    ref.setDir(col, row, angle: turn, strength: 0.55)
                    ref.formWeight.p[i] = 0.12
                    ref.detail.p[i] = litness > 0 ? detail : shadeDetail
                    ref.soft.p[i] = small > 0.5 ? 0.12 : (litness > 0 ? (litness < 0.08 ? 0.72 : 0.12) : (litness > -0.07 ? 0.72 : 0.42))
                    ref.wet.p[i] = litness > 0 ? 0.12 : 0.3
                    ref.blend.p[i] = litness > 0 ? 0 : 0.2
                    ref.steady.p[i] = 0.6
                    ref.comb.p[i] = 0.55
                    ref.focus.p[i] = 0
                    ref.setShape(col, row, length: look.long, width: look.wide)
                }
            }
        }
    }
}


/// A low bank of cloud lying along the horizon: a pale lobed top going down into the air it sits in. It has no edge underneath.
nonisolated func PaintLayBank(_ ref: PaintSceneRef, top: Float, bottom: Float, lit: PaintV3, shade: PaintV3, amount: Float, level: Float, seed: UInt64) {
    let w = ref.w, h = ref.h
    let unitPx = Float(w)
    let n = PaintNoise(seed: seed)
    let span = max(0.001, bottom - top)
    let rowA = max(0, Int(top * unitPx)), rowB = min(h - 1, Int(bottom * unitPx))
    if rowA > rowB { return }
    var edge = [Float](repeating: 0, count: w)
    for col in 0..<w {
        let u = Double((Float(col) + 0.5) / unitPx)
        let big = Float(n.fbm(u * 1.8 + 3, 1.7, octaves: 2))
        // Round-topped lobes, broad, one behind another.
        let lobes = abs(sin(Float(u) * 7.3 + big * 5)) * 0.6 + abs(sin(Float(u) * 3.1 + 1.2)) * 0.4
        edge[col] = top + span * PaintSat(0.62 - big * 0.8 - lobes * 0.42)
    }
    let edges = edge
    let drift = PaintNoiseField(w: w, h: h, step: 3) { u, v in Float(n.fbm(u * 4.2 + 7, v * 16 + 2, octaves: 3)) }
    PaintPar(rowB - rowA + 1) { index in
        let row = rowA + index
        let v = (Float(row) + 0.5) / unitPx
        for col in 0..<w {
            let i = row * w + col
            let t = (v - edges[col] + drift.p[i] * 0.012) / max(0.001, bottom - edges[col])
            if t <= 0 || t >= 1 { continue }
            let cover = PaintSstep(0, 0.34, t) * PaintSstep(1, 0.52, t) * amount
            var c = PaintMix(lit, shade, PaintSstep(0.20, 0.72, t + drift.p[i] * 0.5))
            c = PaintMix(ref.rgb.get3(col, row), c, cover)
            // The sky's own level: it is air, with no edge for a stroke to stop at.
            ref.paintLay(col, row, c, PaintTouch(level: ref.level.p[i], angle: 0.02 + drift.p[i] * 0.2, hold: 1.6, bend: 0.1, detail: 0.02, soft: 0.92, wet: 0.5, blend: 0.34, steady: 0.3, comb: 0.5, long: 1.3, wide: 1))
        }
    }
}
