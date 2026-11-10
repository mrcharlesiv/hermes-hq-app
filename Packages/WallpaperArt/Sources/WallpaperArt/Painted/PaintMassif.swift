// A mountain the way a painter blocks one in: a skyline, and a tree of ridges coming down off it toward us. Each ridge throws flat
// planes to either side, one catching the light and one in shade, with clean creases where neighbouring planes meet. All of it
// lives in the picture plane, so the shapes are designed, not found.

import Foundation
import simd

nonisolated struct PaintMassifLook: Sendable {
    /// Toward the light: x right, y up, z toward us.
    var sun: PaintV3
    var snowLit: PaintV3, snowGlow: PaintV3, snowShade: PaintV3, snowDeep: PaintV3
    var rockLit: PaintV3, rockShade: PaintV3
    var haze: PaintV3
    var litLow: Float = 0.30, litHigh: Float = 0.44
}

nonisolated final class PaintMassif: @unchecked Sendable {
    struct Segment {
        var ax, ay, bx, by: Float
        var ea, eb: Float
        var kL, kR: Float
        var sa, sb: Float
        var id: Float
    }

    let w: Int, h: Int
    let unit: Float
    /// How far the surface comes toward us.
    let z: PaintBuf
    /// Along the ridge, signed distance off it, the way the ridge runs, how far out on its flank (0 at the crest, 1 where the flank gives out).
    let info: PaintBuf
    /// 1 below the skyline.
    let land: PaintBuf
    /// 0: in cast shadow, 1: clear.
    let clear: PaintBuf
    /// The skyline's row per column, in units.
    var crest: [Float]
    var segments: [Segment] = []
    /// Keeps the bumps of the skyline apart from the bumps of the land: every ridge also knows its own scale.
    private var nextId: Float = 0

    init(w: Int, h: Int) {
        self.w = w
        self.h = h
        unit = Float(w)
        z = PaintBuf(w: w, h: h)
        info = PaintBuf(w: w, h: h, c: 4)
        land = PaintBuf(w: w, h: h)
        clear = PaintBuf(w: w, h: h, fill: 1)
        crest = [Float](repeating: 1e6, count: w)
    }

    /// Midpoint displacement between hand-placed points, keeping them where they are.
    static func jagged(_ nodes: [SIMD2<Float>], rough: Float, levels: Int, rng: inout SplitMix64) -> [SIMD2<Float>] {
        var line = nodes
        for level in 0..<levels {
            var next: [SIMD2<Float>] = []
            next.reserveCapacity(line.count * 2)
            for i in 0..<(line.count - 1) {
                let a = line[i], b = line[i + 1]
                next.append(a)
                let span = b.x - a.x
                let shift = Float(rng.next(-1, 1)) * span * rough * (level == 0 ? 1.0 : 1.15)
                let along = Float(rng.next(0.36, 0.64))
                next.append(SIMD2(a.x + span * along, PaintLerp(a.y, b.y, along) + shift))
            }
            next.append(line[line.count - 1])
            line = next
        }
        return line
    }

    /// Sets the skyline from left to right.
    func setCrest(_ line: [SIMD2<Float>]) {
        var seg = 0
        for col in 0..<w {
            let u = (Float(col) + 0.5) / unit
            while seg < line.count - 2 && line[seg + 1].x < u { seg += 1 }
            let a = line[seg], b = line[seg + 1]
            let t = PaintSat((u - a.x) / max(1e-5, b.x - a.x))
            crest[col] = PaintLerp(a.y, b.y, t)
        }
    }

    /// A ridge coming down the mountain from `from`, heading `angle` (0 right, π/2 straight down), throwing smaller ribs as it goes.
    func spur(from: SIMD2<Float>, angle: Float, length: Float, e: Float, kL: Float, kR: Float, level: Int = 0, maxLevel: Int = 2, kinks: Float = 0.34, rng: inout SplitMix64) {
        let stepSize: Float = level == 0 ? 0.042 : 0.030
        let steps = max(2, Int(length / stepSize))
        nextId += 1
        let id = nextId
        var pos = from
        var a = angle
        var s = Float(rng.next(0, 20))
        var eHere = level == 0 ? 0 : e
        for i in 0..<steps {
            let t1 = Float(i + 1) / Float(steps)
            a = PaintLerp(a + Float(rng.next(-Double(kinks), Double(kinks))), angle, 0.40)
            let step = length / Float(steps) * Float(rng.next(0.8, 1.2))
            let next = pos + SIMD2(cos(a), sin(a)) * step
            let eNext: Float
            if level == 0 {
                eNext = e * pow(PaintSat(t1 / 0.22), 0.7) * (1 - 0.92 * t1 * t1 * t1)
            } else {
                eNext = e * pow(1 - t1, 0.85)
            }
            segments.append(Segment(ax: pos.x, ay: pos.y, bx: next.x, by: next.y, ea: eHere, eb: eNext, kL: kL, kR: kR, sa: s, sb: s + step, id: id))
            if level < maxLevel, i >= 1, i < steps - 1, rng.next() < (level == 0 ? 0.62 : 0.34) {
                let side: Float = rng.next() < 0.5 ? -1 : 1
                let turn = a + side * Float(rng.next(0.45, 0.95))
                let clamped = min(Float.pi * 0.90, max(Float.pi * 0.10, turn))
                spur(from: next, angle: clamped, length: length * Float(rng.next(0.32, 0.55)), e: eNext * Float(rng.next(0.55, 0.85)),
                     kL: kL * Float(rng.next(0.95, 1.25)), kR: kR * Float(rng.next(0.95, 1.25)), level: level + 1, maxLevel: maxLevel, kinks: kinks, rng: &rng)
            }
            pos = next
            s += step
            eHere = eNext
        }
    }

    /// Builds the surface. `tilt`: how far it leans back; `spread`: how far it turns away from its axis at `axis` either side.
    func build(tilt: Float, spread: Float, axis: Float, sun: PaintV3, seed: UInt64) {
        let w = self.w, h = self.h, unit = self.unit
        let segs = segments
        let crestCopy = crest
        let noise = PaintNoise(seed: seed)
        let bandHeight = max(4, h / 96)
        let bands = h / bandHeight + 1
        var lists = [[Int32]](repeating: [], count: bands)
        for (i, s) in segs.enumerated() {
            let reach = max(s.ea, s.eb) / min(s.kL, s.kR) + 0.03
            let y0 = Int((min(s.ay, s.by) - reach) * unit), y1 = Int((max(s.ay, s.by) + reach) * unit)
            let b0 = max(0, y0 / bandHeight), b1 = min(bands - 1, max(0, y1) / bandHeight)
            if b0 <= b1 { for b in b0...b1 { lists[b].append(Int32(i)) } }
        }
        let bandLists = lists
        let z = self.z, info = self.info, land = self.land
        let floorValue: Float = -0.015
        PaintPar(h) { row in
            let v = (Float(row) + 0.5) / unit
            let list = bandLists[row / bandHeight]
            for col in 0..<w {
                let u = (Float(col) + 0.5) / unit
                let top = crestCopy[col]
                let i = row * w + col
                if v < top - 3 / unit {
                    z.p[i] = -9
                    continue
                }
                land.p[i] = PaintSat((v - top) * unit + 0.5)
                // A little wander, so planes aren't ruled.
                let wx = u + 0.006 * Float(noise.fbm(Double(u) * 9, Double(v) * 9, octaves: 2))
                let wy = v + 0.006 * Float(noise.fbm(Double(u) * 9 + 7, Double(v) * 9 - 3, octaves: 2))
                var best = floorValue
                var bestS: Float = Float(noise.fbm(Double(u) * 3, Double(v) * 3, octaves: 2)) * 4
                var bestD: Float = 0.2
                var bestAngle: Float = .pi / 2
                var bestReach: Float = 1
                var found = false
                for index in list {
                    let s = segs[Int(index)]
                    let dx = s.bx - s.ax, dy = s.by - s.ay
                    let len2 = dx * dx + dy * dy
                    let t = PaintSat(((wx - s.ax) * dx + (wy - s.ay) * dy) / len2)
                    let px = wx - (s.ax + dx * t), py = wy - (s.ay + dy * t)
                    let d = (px * px + py * py).squareRoot()
                    let cross = dx * py - dy * px
                    let k = cross >= 0 ? s.kR : s.kL
                    let e = s.ea + (s.eb - s.ea) * t
                    let roof = e - k * d
                    if roof > best {
                        best = roof
                        bestS = s.sa + (s.sb - s.sa) * t + s.id * 3.7
                        bestD = cross >= 0 ? d : -d
                        bestAngle = atan2(dy, dx)
                        bestReach = PaintSat(d * k / max(0.001, e - floorValue))
                        found = true
                    }
                }
                let around = abs(u - axis)
                let cone = (around * around + 0.01).squareRoot() - 0.1
                z.p[i] = tilt * v - spread * cone + best
                let j = i * 4
                info.p[j] = bestS
                info.p[j + 1] = bestD
                info.p[j + 2] = bestAngle
                info.p[j + 3] = found ? bestReach : 1
            }
        }
        // Cast shadows: walk toward the light across the surface.
        let flat = (sun.x * sun.x + sun.y * sun.y).squareRoot()
        let dirX = sun.x / flat, dirY = -sun.y / flat, rise = sun.z / flat
        let clearBuf = clear
        PaintPar(h) { row in
            for col in 0..<w {
                let i = row * w + col
                let z0 = z.p[i]
                if z0 < -8 { continue }
                var walk: Float = 0.012
                var lowest: Float = 1
                for _ in 0..<14 {
                    let qx = (Float(col) + 0.5) / unit + dirX * walk, qy = (Float(row) + 0.5) / unit + dirY * walk
                    let cx = Int(qx * unit), cy = Int(qy * unit)
                    if cx < 0 || cy < 0 || cx >= w || cy >= h { break }
                    let there = z.p[cy * w + cx]
                    if there > -8 {
                        let over = (z0 + rise * walk) - there
                        lowest = min(lowest, over / (0.006 + walk * 0.05))
                    }
                    walk *= 1.34
                }
                clearBuf.p[i] = PaintSat(lowest)
            }
        }
    }
}

/// A few stars, gathered in loose clusters high up and kept well away from any silhouette. `open(col,row)`: is this sky far from anything?
nonisolated func PaintAddStars(to ref: PaintSceneRef, count: Int, aspectTop: Float, seed: UInt64, open: (Float, Float) -> Bool) {
    var s = SplitMix64(seed: seed)
    var centres: [SIMD2<Float>] = []
    for _ in 0..<3 { centres.append(SIMD2(Float(s.next(0.08, 0.92)), Float(s.next(0.04, 0.85)) * aspectTop)) }
    var placed = 0, tries = 0
    while placed < count && tries < count * 40 {
        tries += 1
        let c = centres[Int(s.nextUInt64() % 3)]
        let gx = Float(s.next() + s.next() + s.next() - 1.5) * 0.30, gy = Float(s.next() + s.next() + s.next() - 1.5) * 0.22
        let x = c.x + gx, y = c.y + gy
        if x < 0.02 || x > 0.98 || y < 0.02 || y > aspectTop { continue }
        if !open(x, y) { continue }
        placed += 1
        let bright = pow(Float(s.next()), 2.2)
        let warmth = Float(s.next())
        let cold = PaintMix(PaintHex(120, 138, 172), PaintHex(214, 222, 236), bright)
        let warm = PaintMix(PaintHex(138, 128, 118), PaintHex(232, 218, 196), bright)
        let size = 0.0020 + bright * 0.0034
        ref.authored.append(PaintAuthoredStroke(x: x, y: y, angle: Float(s.next()) * 3.1, length: size * 1.15, width: size, color: PaintMix(cold, warm, warmth > 0.8 ? 1 : 0), alpha: 0.55 + 0.45 * bright,
                                           load: 1.3, thick: 0.2, round: 1, feather: 0.75, taper: 0, tipIn: 1, tipOut: 0.2, comb: 0))
    }
}
