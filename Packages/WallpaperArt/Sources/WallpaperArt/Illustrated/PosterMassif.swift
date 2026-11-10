// A massif the way a printmaker cuts it: ridges fan out of the summit, every ridge a lit face and a shadow face, and each pixel
// picks one flat ink. Inks are chosen as indices, cleaned of slivers, then coloured, so an edge between two inks never passes
// through the colours between them on a ladder.

import CoreGraphics
import Foundation

nonisolated struct PosterAlpInks: Sendable {
    var rockDeep, rockShadow, rockMid, rockLit: PosterInk
    var snowDeep, snowShadow, snowMid, snowLit, snowTop: PosterInk
    var rim: PosterInk

    var list: [PosterInk] { [rockDeep, rockShadow, rockMid, rockLit, snowDeep, snowShadow, snowMid, snowLit, snowTop, rim] }
}

nonisolated struct PosterAlpStyle: Sendable {
    var light: PosterLight
    var inks: PosterAlpInks
    var thrLit: Float = 0.62
    var thrMid: Float = 0.36
    var thrDeep: Float = 0.10
    /// Altitude (0 foot, 1 summit) where bare rock starts on the ridges; the gullies hold their snow lower.
    var rockLine: Float = 0.62
    /// How wide the bare rock along a crest gets, per unit of altitude below `rockLine`, in design units.
    var rockWidth: Float = 150
    var rockNoise: Float = 0.7
    var castReach: Float = 240
    var grain: Float = 0.016
    var edgeNoise: Float = 0.035
}

nonisolated enum PosterAlp {
    private static let rockDeep: UInt8 = 0, rockShadow: UInt8 = 1, rockMid: UInt8 = 2, rockLit: UInt8 = 3
    private static let snowDeep: UInt8 = 4, snowShadow: UInt8 = 5, snowMid: UInt8 = 6, snowLit: UInt8 = 7, snowTop: UInt8 = 8, rimInk: UInt8 = 9

    /// Paints a massif and returns its silhouette. `rock` are extra hand-placed slivers of bare rock; `deep` the only shapes allowed
    /// the darkest ink. `warmLine(x)`: alpenglow lies above this y; the edge is a tight dissolve that follows it.
    @discardableResult
    static func paint(_ c: PosterCanvas, skyline: [PosterP], bottom: Double, top: Double, foot: Double, slope: Float, levels: [[PosterRidge]], rockRidges: [(ridges: [PosterRidge], scale: Float)], style s: PosterAlpStyle,
                      rock: [[PosterP]] = [], deep: [[PosterP]] = [], warmLine: ((Double) -> Double)? = nil, tint: PosterInk? = nil, seed: UInt32, key: Int) -> PosterPlate {
        var outline = skyline
        outline.append(PosterP(skyline.last!.x, bottom))
        outline.append(PosterP(skyline.first!.x, bottom))
        let mask = PosterPlate(c) { g in Poster.fillPoly(g, outline) }
        let wide = PosterPlate(c) { g in
            Poster.fillPoly(g, outline)
            g.setLineWidth(5)
            g.beginPath()
            Poster.poly(g, outline)
            g.strokePath()
        }
        let first = wide.firstRow, last = min(c.h, wide.lastRow + 1)
        let relief = PosterRelief(c, firstRow: first, lastRow: last, slope: slope)
        for l in levels { relief.add(l) }
        let w = c.w, h = c.h
        let zp = relief.z
        let sx = Float(c.sx)
        let light = s.light
        let lxy = (light.x * light.x + light.y * light.y).squareRoot()
        let dirX = light.x / lxy, dirY = light.y / lxy, rise = light.z / lxy

        // Distance to the crest lines: bare rock runs along them, widening downhill; snow keeps the gullies.
        relief.distances(rockRidges, reach: 200)
        let distP = relief.keep

        // Steps out along the light: fine near, coarser far, so cast edges are lines and not stairs.
        var steps: [Float] = []
        var st: Float = 2
        while st <= s.castReach {
            steps.append(st)
            st += st < 40 ? 1.5 : (st < 120 ? 3 : 6)
        }
        let ang = PosterAngularNoise(seed)
        let rockPlate = PosterPlate(c) { g in for b in rock { Poster.fillPoly(g, b) } }
        let deepPlate = PosterPlate(c) { g in for b in deep { Poster.fillPoly(g, b) } }
        let rockP = rockPlate.p, deepP = deepPlate.p, wideP = wide.p, maskP = mask.p
        let footF = Float(foot), topF = Float(top)
        let inks = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h)
        let inks2 = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h)
        inks.initialize(repeating: snowLit, count: w * h)
        inks2.initialize(repeating: snowLit, count: w * h)
        defer {
            inks.deallocate()
            inks2.deallocate()
        }
        // The march toward the light, worked out once: columns, rows and rise of each step.
        let stepCount = steps.count
        let stepCol = UnsafeMutablePointer<Int>.allocate(capacity: stepCount), stepRow = UnsafeMutablePointer<Int>.allocate(capacity: stepCount)
        let stepRise = UnsafeMutablePointer<Float>.allocate(capacity: stepCount)
        for (i, st) in steps.enumerated() {
            stepCol[i] = Int(dirX * st * sx)
            stepRow[i] = Int(dirY * st * sx)
            stepRise[i] = rise * st
        }
        // The highest ground on each row or any row above it: once the ray clears that, nothing further along can shade it.
        let highest = UnsafeMutablePointer<Float>.allocate(capacity: h)
        defer {
            stepCol.deallocate()
            stepRow.deallocate()
            stepRise.deallocate()
            highest.deallocate()
        }
        do {
            var top: Float = 0
            for r in 0..<h {
                let line = zp + r * w
                if r >= first && r < last {
                    for col in 0..<w where line[col] > top { top = line[col] }
                }
                highest[r] = top
            }
        }
        do {
            c.rows(first, last) { r in
                let y = Float(c.dy(r))
                let line = zp + r * w
                let up = zp + max(0, r - 1) * w, dn = zp + min(h - 1, r + 1) * w
                for col in 0..<w {
                    if wideP[r * w + col] == 0 { continue }
                    let z0 = line[col]
                    let zx = (line[min(w - 1, col + 1)] - line[max(0, col - 1)]) * 0.5 * sx
                    let zy = (dn[col] - up[col]) * 0.5 * sx
                    let il = 1 / (zx * zx + zy * zy + 1).squareRoot()
                    let ndl = (-zx * light.x - zy * light.y + light.z) * il
                    let x = Float(c.dx(col))
                    let alt = (footF - y) / (footF - topF)
                    let n = ang.two(x / 24, y / 64)
                    let reachW = max(0, s.rockLine - alt) * s.rockWidth * (1 + s.rockNoise * n)
                    let isRock = rockP[r * w + col] > 110 || distP[r * w + col] < reachW
                    let nn = ndl + s.edgeNoise * n
                    let isDeep = isRock && deepP[r * w + col] > 110
                    // A cast shadow only changes a face that would otherwise be in the light.
                    var shadow = false
                    if nn >= s.thrMid && !isDeep {
                        for i in 0..<stepCount {
                            let sc = col + stepCol[i], sr = r + stepRow[i]
                            if sc < 0 || sc >= w || sr < 0 || sr >= h { break }
                            let bar = z0 + stepRise[i] + 1.2
                            if highest[sr] <= bar { break }
                            if zp[sr * w + sc] > bar {
                                shadow = true
                                break
                            }
                        }
                    }
                    var ink: UInt8
                    if isRock {
                        if isDeep { ink = rockDeep }
                        else if shadow || nn < s.thrMid { ink = rockShadow }
                        else if nn < s.thrLit { ink = rockMid }
                        else { ink = rockLit }
                    } else {
                        if nn < s.thrDeep { ink = snowDeep }
                        else if shadow || nn < s.thrMid { ink = snowShadow }
                        else if nn < s.thrLit { ink = snowMid }
                        else { ink = snowLit }
                    }
                    inks[r * w + col] = ink
                }
            }
        }
        // Slivers go: each pixel takes the most common ink around it. Shapes stay cut, not shattered.
        let mr = 1
        c.rows(first, last) { r in
            var hist = [Int32](repeating: 0, count: 10)
            let up = inks + max(0, r - 1) * w, mid = inks + r * w, dn = inks + min(h - 1, r + 1) * w
            for col in 0..<w {
                if wideP[r * w + col] == 0 { continue }
                let l = max(0, col - 1), rr = min(w - 1, col + 1)
                let centre = mid[col]
                if up[l] == centre && up[col] == centre && up[rr] == centre && mid[l] == centre && mid[rr] == centre && dn[l] == centre && dn[col] == centre && dn[rr] == centre {
                    inks2[r * w + col] = centre
                    continue
                }
                for k in 0..<10 { hist[k] = 0 }
                for dy in -mr...mr {
                    let rr = max(0, min(h - 1, r + dy))
                    for dx in -mr...mr {
                        let cc = max(0, min(w - 1, col + dx))
                        hist[Int(inks[rr * w + cc])] += 1
                    }
                }
                var best: Int32 = -1
                var pick = inks[r * w + col]
                for k in 0..<10 where hist[k] > best {
                    best = hist[k]
                    pick = UInt8(k)
                }
                inks2[r * w + col] = pick
            }
        }
        // Colour, with alpenglow and rim, then a pixel-wide soften: the antialiasing of every cut.
        let table = s.inks.list
        let cr = table.map { Float($0.r * 255) }, cg = table.map { Float($0.g * 255) }, cb = table.map { Float($0.b * 255) }
        let rgb = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 3)
        rgb.initialize(repeating: 0, count: w * h * 3)
        defer { rgb.deallocate() }
        let grain = s.grain
        c.rows(first, last) { r in
            let y = c.dy(r)
            for col in 0..<w {
                if wideP[r * w + col] == 0 { continue }
                var ink = inks2[r * w + col]
                let x = c.dx(col)
                if let warmLine, ink == snowLit || ink == snowMid {
                    let line = warmLine(x) + 7 * Double(ang.value(Float(x / 40), Float(y / 40)))
                    let gr = Double(c.g(col, r, 8))
                    let a = Poster.dsstep(line - 5, line + 5, y)
                    if a < gr {
                        if ink == snowLit { ink = snowTop }
                    }
                }
                // Rim: lit crests with sky toward the sun, swelling and thinning.
                if ink == snowLit || ink == snowTop || ink == snowMid || ink == rockLit || ink == rockMid {
                    let rw = 0.8 + 2.8 * Double(0.5 + 0.5 * ang.value(Float(x / 60), Float(y / 60)))
                    let rc = col + Int((Double(dirX) * rw * c.sx).rounded(.toNearestOrAwayFromZero))
                    let rr = r + Int((Double(dirY) * rw * c.sx).rounded(.toNearestOrAwayFromZero))
                    if rc >= 0, rc < w, rr >= 0, rr < h, maskP[rr * w + rc] < 40 { ink = rimInk }
                }
                let k = 1 + grain * 2 * (c.g(col, r, key) - 0.5)
                let i = Int(ink)
                let o = (r * w + col) * 3
                rgb[o] = UInt8(min(255, cr[i] * k))
                rgb[o + 1] = UInt8(min(255, cg[i] * k))
                rgb[o + 2] = UInt8(min(255, cb[i] * k))
            }
        }
        if let tint { c.flat(tint, plate: mask, opacity: 0.55) }
        let ox = c.reg, oy = c.reg > 0 ? -1 : 0
        c.rows(first - 2, last + 2) { r in
            let mr = min(h - 1, max(0, r - oy))
            let up = max(first, min(last - 1, mr - 1)), mid = max(first, min(last - 1, mr)), dn = max(first, min(last - 1, mr + 1))
            let line = c.px + r * c.bpr
            for x in 0..<w {
                let mc = min(w - 1, max(0, x - ox))
                let cov = Int32(maskP[mr * w + mc])
                if cov == 0 { continue }
                let l = max(0, mc - 1), rr = min(w - 1, mc + 1)
                let o = line + x * 4
                for k in 0..<3 {
                    let a = Int32(rgb[(up * w + l) * 3 + k]) + 2 * Int32(rgb[(up * w + mc) * 3 + k]) + Int32(rgb[(up * w + rr) * 3 + k])
                    let b = 2 * Int32(rgb[(mid * w + l) * 3 + k]) + 4 * Int32(rgb[(mid * w + mc) * 3 + k]) + 2 * Int32(rgb[(mid * w + rr) * 3 + k])
                    let d = Int32(rgb[(dn * w + l) * 3 + k]) + 2 * Int32(rgb[(dn * w + mc) * 3 + k]) + Int32(rgb[(dn * w + rr) * 3 + k])
                    let v = (a + b + d) / 16
                    if cov == 255 {
                        o[k] = UInt8(v)
                    } else {
                        o[k] = UInt8(Int32(o[k]) + ((v - Int32(o[k])) * cov) / 255)
                    }
                }
            }
        }
        return mask
    }

    /// A ridge cut into angular runs.
    static func ridge(_ pts: [PosterP], h: Double, k: Double, amp: Double = 0.07, len: Double = 22, fade: Double = 0.7, rampIn: Double = 0.03, rng: inout SplitMix64) -> PosterRidge {
        PosterRidge(pts: Poster.cut(pts, amp: amp, minLen: len, rng: &rng), h: h, k: k, rampIn: rampIn, fadeFrom: fade)
    }
}

// MARK: PosterCut shapes

nonisolated enum PosterCut {
    /// A long flat cloud: pointed ends, lumpy top with lumps of unequal size, a nearly flat underside.
    static func spindle(x0: Double, x1: Double, y: Double, up: Double, down: Double, skew: Double = 0.42, rng: inout SplitMix64) -> [PosterP] {
        // Lumps along the top, power-law sizes.
        var lumps: [(c: Double, w: Double, a: Double)] = []
        var u = rng.next(0.02, 0.1)
        while u < 1 {
            let r = rng.next()
            let wd = r < 0.14 ? rng.next(0.16, 0.26) : (r < 0.45 ? rng.next(0.07, 0.13) : rng.next(0.025, 0.06))
            lumps.append((u + wd * 0.5, wd * 0.5, wd))
            u += wd * rng.next(0.6, 1.05)
        }
        let span = x1 - x0
        let n = max(24, Int(span / 5))
        var top: [PosterP] = [], bot: [PosterP] = []
        for i in 0...n {
            let t = Double(i) / Double(n)
            let v = t < skew ? t / skew * 0.5 : 0.5 + (t - skew) / (1 - skew) * 0.5
            let env = pow(sin(.pi * v), 0.72)
            var bump = 0.0
            for l in lumps where abs(t - l.c) < l.w {
                let d = (t - l.c) / l.w
                bump = max(bump, (1 - d * d).squareRoot() * min(1, l.a / 0.16 * 0.9 + 0.1))
            }
            let x = x0 + span * t
            top.append(PosterP(x, y - up * env * (0.28 + 0.72 * bump)))
            bot.append(PosterP(x, y + down * env * (0.7 + 0.3 * sin(t * 17 + span))))
        }
        return top + bot.reversed()
    }

    /// A band cut along a wavy top, solid down to `floorY`.
    static func wavyBand(y: Double, tilt: Double, waves: [(a: Double, l: Double, p: Double)], floorY: Double) -> [PosterP] {
        var pts: [PosterP] = []
        var x = -30.0
        while x <= 1030 {
            var s = y + tilt * (x - 500)
            for w in waves { s += w.a * sin(x / w.l + w.p) }
            pts.append(PosterP(x, s))
            x += 6
        }
        pts.append(PosterP(1030, floorY))
        pts.append(PosterP(-30, floorY))
        return pts
    }

    /// The top of a band of mist or stratus: long hand-drawn waves, unequal.
    static func wavyTop(_ waves: [(a: Double, l: Double, p: Double)]) -> (Double) -> Double {
        { x in
            var s = 0.0
            for w in waves { s += w.a * sin(x / w.l + w.p) }
            return s
        }
    }

    /// Ragged spires merged into one silhouette: clumps of three to nine trees of very different heights, with clearings between.
    static func treeline(_ g: CGContext, line: (Double) -> Double, floorY: Double, height: ClosedRange<Double>, x0: Double = -30, x1: Double = 1030, rng: inout SplitMix64) {
        var ground: [PosterP] = []
        var x = x0
        while x <= x1 {
            ground.append(PosterP(x, line(x)))
            x += 14
        }
        ground.append(PosterP(x1, floorY))
        ground.append(PosterP(x0, floorY))
        Poster.fillPoly(g, ground)
        x = x0
        while x < x1 {
            let count = Int(rng.next(3, 10))
            let tall = rng.next(height.lowerBound, height.upperBound)
            for _ in 0..<count {
                let hh = tall * rng.next(0.5, 1.12)
                let hw = hh * rng.next(0.09, 0.15)
                let by = line(x) + 8
                Poster.fillPoly(g, spire(x: x, top: by - hh, base: by + 10, halfW: hw, rng: &rng))
                x += hw * rng.next(0.8, 1.7)
            }
            // A clearing: low scrub only.
            let gap = rng.next() < 0.3 ? rng.next(26, 70) : rng.next(4, 14)
            var q = x
            while q < x + gap {
                let hh = tall * rng.next(0.1, 0.24)
                let by = line(q) + 6
                Poster.fillPoly(g, spire(x: q, top: by - hh, base: by + 8, halfW: hh * 0.3, rng: &rng))
                q += hh * rng.next(0.4, 0.9)
            }
            x += gap
        }
    }

    /// One far tree: no tiers to count, just a torn edge that widens downward.
    static func spire(x: Double, top: Double, base: Double, halfW: Double, rng: inout SplitMix64) -> [PosterP] {
        let hh = base - top
        func side(_ s: Double) -> [PosterP] {
            var pts: [PosterP] = []
            var t = rng.next(0.08, 0.16)
            while t < 1 {
                let wd = halfW * pow(t, 0.8) * rng.next(0.6, 1.15)
                pts.append(PosterP(x + s * wd, top + hh * t))
                pts.append(PosterP(x + s * wd * rng.next(0.35, 0.65), top + hh * (t + rng.next(0.015, 0.05))))
                t += rng.next(0.1, 0.24)
            }
            return pts
        }
        return [PosterP(x, top)] + side(-1) + [PosterP(x - halfW * 0.8, base), PosterP(x + halfW * 0.8, base)] + side(1).reversed()
    }
}

nonisolated extension PosterPlate {
    /// Removes `other` from this plate. Stars stay out from behind the mountains this way.
    func subtract(_ other: PosterPlate) {
        for i in 0..<(w * h) {
            let o = Int32(other.p[i])
            if o != 0 { p[i] = UInt8((Int32(p[i]) * (255 - o)) / 255) }
        }
    }

    func intersect(_ other: PosterPlate) {
        for i in 0..<(w * h) { p[i] = UInt8((Int32(p[i]) * Int32(other.p[i])) / 255) }
    }

    func union(_ other: PosterPlate) {
        for i in 0..<(w * h) where other.p[i] > p[i] { p[i] = other.p[i] }
    }
}

nonisolated extension PosterSky {
    /// Stars the way a printer pulls them: a scatter of fine dots, thinning toward the land, and very few big ones, placed by hand.
    static func stars2(_ c: PosterCanvas, until: Double, bright: [(Double, Double, Double)], behind: PosterPlate? = nil, dots: PosterInk = Poster.hx(0xBFCDE6), big: PosterInk = Poster.hx(0xF4EEDC), count: Int = 460, seed: UInt64, avoid: ((Double, Double) -> Bool)? = nil) {
        let dotP = PosterPlate(c) { g in
            var r = SplitMix64(seed: seed)
            for _ in 0..<count {
                let x = r.next(0, 1000), y = until * pow(r.next(), 1.35)
                let s = r.next(0.42, 1.0)
                if let avoid, avoid(x, y) { continue }
                g.fillEllipse(in: CGRect(x: x - s, y: y - s, width: 2 * s, height: 2 * s))
            }
        }
        let midP = PosterPlate(c) { g in
            var r = SplitMix64(seed: seed ^ 9)
            for _ in 0..<26 {
                let x = r.next(0, 1000), y = until * 0.8 * pow(r.next(), 1.2)
                let s = r.next(1.1, 1.5)
                if let avoid, avoid(x, y) { continue }
                g.fillEllipse(in: CGRect(x: x - s, y: y - s, width: 2 * s, height: 2 * s))
            }
        }
        let bigP = PosterPlate(c) { g in
            for b in bright { g.fillEllipse(in: CGRect(x: b.0 - b.2, y: b.1 - b.2, width: 2 * b.2, height: 2 * b.2)) }
        }
        if let behind {
            dotP.subtract(behind)
            midP.subtract(behind)
            bigP.subtract(behind)
        }
        c.flat(dots, plate: dotP, opacity: 0.5)
        c.flat(big, plate: midP, opacity: 0.62)
        c.flat(big, plate: bigP, opacity: 0.92)
    }
}
