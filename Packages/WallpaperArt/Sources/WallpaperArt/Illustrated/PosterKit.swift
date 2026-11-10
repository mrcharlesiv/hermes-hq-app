// A small screen-print shop in code. Every picture is a stack of inks:
//
// - Shapes are hand-placed in a 1000 x 2168 design space (`P`) and rasterised by Core Graphics into 8-bit plates.
// - Tone never blends smoothly. A tone runs through a palette ramp of flat inks, and the only way one ink turns into the
//   next is a stipple dissolve (the tone is nudged by a grain sample before the ramp is read), the way a litho or a
//   sprayed screen does it. So a gradient has grain in it and a shadow edge stays crisp.
// - Mountains and clouds get their light from `PosterRelief`: a height field built from hand-placed ridge lines (tents summed
//   over levels) or lobes. It is posterised, cast shadows included, so the facets are designed, not noise.
// - Plates print slightly out of register, and the paper shows through last.

import CoreGraphics
import Foundation

/// Small tools shared by every picture. The pictures themselves are its static members too, one per file.
nonisolated enum Poster {
    @inline(__always) static func hx(_ v: UInt32) -> PosterInk { PosterInk(hex: v) }

    @inline(__always) static func sstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    @inline(__always) static func dsstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func poly(_ g: CGContext, _ pts: [PosterP]) {
        guard let f = pts.first else { return }
        g.move(to: CGPoint(x: f.x, y: f.y))
        for p in pts.dropFirst() { g.addLine(to: CGPoint(x: p.x, y: p.y)) }
        g.closePath()
    }

    static func fillPoly(_ g: CGContext, _ pts: [PosterP]) {
        g.beginPath()
        poly(g, pts)
        g.fillPath()
    }

    /// A tapered horizontal stroke with pointed ends: the mark a printmaker cuts for water.
    static func lens(_ g: CGContext, _ cx: Double, _ cy: Double, _ len: Double, _ thick: Double, tilt: Double = 0) {
        let dx = len / 2, sl = tilt
        g.move(to: CGPoint(x: cx - dx, y: cy - dx * sl))
        g.addQuadCurve(to: CGPoint(x: cx + dx, y: cy + dx * sl), control: CGPoint(x: cx + dx * 0.15, y: cy - thick))
        g.addQuadCurve(to: CGPoint(x: cx - dx, y: cy - dx * sl), control: CGPoint(x: cx - dx * 0.15, y: cy + thick * 0.7))
        g.closePath()
    }

    /// Splits each span of a hand-placed line into angular cuts, keeping the hand-placed points where they are.
    static func cut(_ pts: [PosterP], amp: Double, minLen: Double, rng: inout SplitMix64) -> [PosterP] {
        func split(_ a: PosterP, _ b: PosterP, _ out: inout [PosterP], _ rng: inout SplitMix64) {
            let dx = b.x - a.x, dy = b.y - a.y
            let len = (dx * dx + dy * dy).squareRoot()
            if len < minLen { return }
            let t = rng.next(0.32, 0.68)
            let d = rng.next(-1, 1) * amp * len
            let m = PosterP(a.x + dx * t - dy / len * d, a.y + dy * t + dx / len * d)
            split(a, m, &out, &rng)
            out.append(m)
            split(m, b, &out, &rng)
        }
        guard var prev = pts.first else { return [] }
        var out = [prev]
        for p in pts.dropFirst() {
            split(prev, p, &out, &rng)
            out.append(p)
            prev = p
        }
        return out
    }

    /// Side ridges branching off a ridge, the way spurs leave an arete.
    static func spurs(of r: PosterRidge, count: Int, length: ClosedRange<Double>, hFrac: Double, k: Double, from: Double = 0.08, to: Double = 0.92,
                           spread: ClosedRange<Double> = 24...58, cutAmp: Double = 0.16, cutLen: Double = 22, rng: inout SplitMix64) -> [PosterRidge] {
        var out: [PosterRidge] = []
        var side = rng.next() < 0.5 ? -1.0 : 1.0
        for i in 0..<count {
            let t = from + (Double(i) + rng.next(0.1, 0.9)) / Double(count) * (to - from)
            let (o, dir) = r.locate(t)
            side = -side
            let a = side * rng.next(spread.lowerBound, spread.upperBound) * .pi / 180
            var d = PosterP(dir.x * cos(a) - dir.y * sin(a), dir.x * sin(a) + dir.y * cos(a))
            if d.y < 0.25 { // Spurs run downhill.
                d.y = 0.25
                let n = hypot(d.x, d.y)
                d = PosterP(d.x / n, d.y / n)
            }
            let len = rng.next(length.lowerBound, length.upperBound)
            let bend = rng.next(-0.28, 0.28)
            let mid = PosterP(o.x + d.x * len * 0.5 - d.y * len * bend * 0.5, o.y + d.y * len * 0.5 + d.x * len * bend * 0.5)
            // Spurs curl toward the fall line.
            let end = PosterP(o.x + d.x * len * 0.9 , o.y + d.y * len + len * 0.08)
            let pts = cut([o, mid, end], amp: cutAmp, minLen: cutLen, rng: &rng)
            out.append(PosterRidge(pts: pts, h: max(2, r.height(at: t)) * hFrac, k: k, rampIn: 0.32, fadeFrom: 0.4))
        }
        return out
    }

    /// A heap of cloud: a flat body, a crown of lobes of very unequal size along its top, and lobes over the body that only bend its shadow's edge.
    static func crownHeap(_ out: inout [PosterBillow], x: Double, y: Double, rx: Double, ry: Double, inner: Int, rng: inout SplitMix64) {
        let m = (x: x, y: y + ry * 0.12, rx: rx * 1.1, ry: ry * 1.22)
        func add(_ px: Double, _ py: Double, _ a: Double, _ b: Double, _ rng: inout SplitMix64) {
            out.append(PosterBillow(x: px, y: py, rx: a, ry: b, mx: m.x, my: m.y, mrx: m.rx, mry: m.ry, phase: rng.next(0, 6.28)))
        }
        // Crown, big lobes first: they stick out above the body.
        var th = Double.pi * 0.98
        while th > 0.02 {
            let pick = rng.next()
            let s = pick < 0.12 ? rng.next(0.3, 0.4) : (pick < 0.45 ? rng.next(0.15, 0.22) : rng.next(0.07, 0.11))
            let a = rx * s, b = a / rng.next(1.15, 1.45)
            let px = x + cos(th) * rx * 0.92, py = y - sin(th) * ry * 0.9
            add(px, py, a, b, &rng)
            // A couple of small ones on the shoulder of each large one.
            if s > 0.14 {
                for _ in 0..<4 {
                    let t = rng.next(0.15 * .pi, 0.85 * .pi)
                    let q = rng.next(0.22, 0.42)
                    add(px + cos(t) * a * 0.9, py - sin(t) * b * 0.9, a * q, b * q, &rng)
                }
            }
            th -= (a / rx) * rng.next(1.1, 1.8)
        }
        add(x, y, rx, ry, &rng)
        // Over the body: one to three large, then more of medium, many small. Upper ones first.
        var inside: [(Double, Double, Double)] = []
        for i in 0..<inner {
            let s = i == 0 ? rng.next(0.34, 0.44) : (i < 4 ? rng.next(0.17, 0.26) : rng.next(0.06, 0.12))
            // Over the upper body only: nothing floats low on a heap.
            let ang = rng.next(1.05 * .pi, 1.95 * .pi), reach = pow(rng.next(), 0.5) * 0.86
            inside.append((x + cos(ang) * rx * reach, y + sin(ang) * ry * reach * 0.9 + ry * 0.12, s))
        }
        inside.sort { $0.1 < $1.1 }
        for p in inside {
            let a = rx * p.2
            add(p.0, p.1, a, a / rng.next(1.2, 1.6), &rng)
        }
    }
}

typealias PosterInk = BackdropPreset.Ink

nonisolated struct PosterP: Sendable {
    var x: Double
    var y: Double
    @inline(__always) init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// Piecewise-bilinear lattice noise: its contours are straight with corners, so edges cut by it look chiselled, not blobby.
nonisolated struct PosterAngularNoise: Sendable {
    let seed: UInt32
    init(_ seed: UInt32) { self.seed = seed }

    @inline(__always) private func lat(_ ix: Int32, _ iy: Int32) -> Float {
        var h = (UInt32(bitPattern: ix) &* 0x8DA6_B343) ^ (UInt32(bitPattern: iy) &* 0xD816_3841) ^ seed
        h ^= h >> 13
        h = h &* 0x5BD1_E995
        h ^= h >> 15
        return Float(h & 0xFFFF) / 32767.5 - 1
    }

    @inline(__always) func value(_ x: Float, _ y: Float) -> Float {
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let ix = Int32(fx), iy = Int32(fy)
        let dx = x - fx, dy = y - fy
        let a = lat(ix, iy), b = lat(ix + 1, iy), c = lat(ix, iy + 1), d = lat(ix + 1, iy + 1)
        return a + (b - a) * dx + (c - a) * dy + (a - b - c + d) * dx * dy
    }

    @inline(__always) func two(_ x: Float, _ y: Float) -> Float { 0.67 * value(x, y) + 0.33 * value(x * 2.1 + 7.7, y * 2.1 - 3.1) }
}

/// A palette as a lookup table. `stops` are flat inks; `step` is how sharply each passes to the next (1: smooth, near 0: a
/// hard edge that the grain turns into a stipple).
nonisolated final class PosterRamp: @unchecked Sendable {
    static let size = 1024
    let lut: UnsafeMutablePointer<UInt8>

    init(_ stops: [(Double, PosterInk)], step: Double) {
        lut = .allocate(capacity: PosterRamp.size * 3)
        var s = 0
        for i in 0..<PosterRamp.size {
            let t = Double(i) / Double(PosterRamp.size - 1)
            while s < stops.count - 2, t > stops[s + 1].0 { s += 1 }
            let a = stops[s], b = stops[min(s + 1, stops.count - 1)]
            var c = a.1
            if b.0 > a.0 {
                let u = min(1, max(0, (t - a.0) / (b.0 - a.0)))
                let w = max(0.001, min(1, step))
                c = a.1.mixed(with: b.1, Poster.dsstep(0.5 - 0.5 * w, 0.5 + 0.5 * w, u))
            }
            lut[i * 3] = UInt8((min(1, max(0, c.r)) * 255).rounded())
            lut[i * 3 + 1] = UInt8((min(1, max(0, c.g)) * 255).rounded())
            lut[i * 3 + 2] = UInt8((min(1, max(0, c.b)) * 255).rounded())
        }
    }

    deinit { lut.deallocate() }
}

/// One 8-bit plate the size of the canvas.
nonisolated final class PosterPlate: @unchecked Sendable {
    let w: Int, h: Int
    let p: UnsafeMutablePointer<UInt8>
    private(set) var firstRow = 0
    private(set) var lastRow = 0

    init(_ c: PosterCanvas, value: UInt8 = 0, draw: (CGContext) -> Void) {
        w = c.w
        h = c.h
        p = .allocate(capacity: w * h)
        p.initialize(repeating: value, count: w * h)
        if let g = CGContext(data: p, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            g.translateBy(x: 0, y: CGFloat(h))
            g.scaleBy(x: 1, y: -1)
            g.concatenate(CGAffineTransform(a: c.sx, b: 0, c: 0, d: c.sx, tx: c.ox, ty: c.oy))
            g.setShouldAntialias(true)
            g.setAllowsAntialiasing(true)
            g.setFillColor(gray: 1, alpha: 1)
            g.setStrokeColor(gray: 1, alpha: 1)
            draw(g)
        }
        firstRow = h
        lastRow = 0
        for row in 0..<h {
            let line = p + row * w
            var any = false
            var x = 0
            while x < w {
                if line[x] != 0 { any = true; break }
                x += 8
            }
            if any {
                firstRow = min(firstRow, row)
                lastRow = max(lastRow, row)
            }
        }
        if firstRow > lastRow { firstRow = 0; lastRow = h - 1 }
        // Thin shapes can slip between the sampled columns: open the range by a little.
        firstRow = max(0, firstRow - 4)
        lastRow = min(h - 1, lastRow + 4)
    }

    deinit { p.deallocate() }

    @inline(__always) func at(_ x: Int, _ y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < w, y < h else { return 0 }
        return p[y * w + x]
    }
}

/// The sheet being printed.
nonisolated final class PosterCanvas: @unchecked Sendable {
    let w: Int, h: Int
    let sx: Double, ox: Double, oy: Double
    let ctx: CGContext
    let px: UnsafeMutablePointer<UInt8>
    let bpr: Int
    let tile: UnsafeMutablePointer<UInt8>
    static let tileSize = 1024
    /// 1 at a full phone screen, smaller below it.
    let res: Double
    /// Out-of-register distance, in pixels.
    let reg: Int

    init?(w: Int, h: Int, seed: UInt64, focusY: Double = 1084) {
        guard let c = BackdropCanvas.context(width: w, height: h), let d = c.data else { return nil }
        self.w = w
        self.h = h
        ctx = c
        px = d.bindMemory(to: UInt8.self, capacity: c.bytesPerRow * h)
        bpr = c.bytesPerRow
        sx = max(Double(w) / 1000, Double(h) / 2168)
        ox = (Double(w) - 1000 * sx) / 2
        // A frame wider than the design crops its height: `focusY` moves to the centre as the crop grows, and the crop never runs off the design.
        let spare = 2168 - Double(h) / sx
        let centred = (Double(h) - 2168 * sx) / 2
        let shift = (focusY - 1084) * Poster.dsstep(1, 300, spare) * sx
        oy = shift == 0 ? centred : min(0, max(Double(h) - 2168 * sx, centred - shift))
        res = min(1, Double(min(w, h)) / 1179)
        reg = max(0, Int((Double(min(w, h)) * 0.0016).rounded()))
        tile = .allocate(capacity: PosterCanvas.tileSize * PosterCanvas.tileSize)
        makeGrain(seed: seed)
    }

    deinit { tile.deallocate() }

    private func makeGrain(seed: UInt64) {
        let n = PosterCanvas.tileSize
        var rng = SplitMix64(seed: seed ^ 0xA5A5_1234)
        var white = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) { white[i] = Float(rng.next()) }
        var mixed = white
        // Grains two or three pixels across at a phone's size: printing screens clump.
        let clump: Float = res > 0.7 ? 0.35 : 0.22
        white.withUnsafeBufferPointer { wp in
            mixed.withUnsafeMutableBufferPointer { mp in
                for y in 0..<n {
                    let u = (y + n - 1) % n, d = (y + 1) % n
                    for x in 0..<n {
                        let l = (x + n - 1) % n, r = (x + 1) % n
                        let blur = (wp[y * n + x] * 4
                            + 2 * (wp[y * n + l] + wp[y * n + r] + wp[u * n + x] + wp[d * n + x])
                            + wp[u * n + l] + wp[u * n + r] + wp[d * n + l] + wp[d * n + r]) / 16
                        mp[y * n + x] = wp[y * n + x] * (1 - clump) + clump * (blur * 2.2 - 0.6)
                    }
                }
            }
        }
        // Rank-equalise, so a grain sample is uniform 0...1 and a dissolve's density is exactly its tone.
        var hist = [Int](repeating: 0, count: 4096)
        let lo = mixed.min() ?? 0, hi = mixed.max() ?? 1
        let scale = 4095 / max(0.0001, hi - lo)
        for v in mixed { hist[Int((v - lo) * scale)] += 1 }
        var cdf = [UInt8](repeating: 0, count: 4096)
        var sum = 0
        for i in 0..<4096 {
            sum += hist[i]
            cdf[i] = UInt8(min(255, sum * 256 / (n * n)))
        }
        for i in 0..<(n * n) { tile[i] = cdf[Int((mixed[i] - lo) * scale)] }
    }

    // MARK: Design space <-> pixels

    @inline(__always) func row(_ y: Double) -> Int { Int((oy + y * sx).rounded()) }
    @inline(__always) func col(_ x: Double) -> Int { Int((ox + x * sx).rounded()) }
    @inline(__always) func dx(_ col: Int) -> Double { (Double(col) + 0.5 - ox) / sx }
    @inline(__always) func dy(_ row: Int) -> Double { (Double(row) + 0.5 - oy) / sx }

    /// Runs `body` over rows in parallel.
    func rows(_ from: Int, _ to: Int, _ body: (Int) -> Void) {
        let from = max(0, from), to = min(h, to)
        guard from < to else { return }
        let chunk = 24
        let n = (to - from + chunk - 1) / chunk
        withoutActuallyEscaping(body) { b in
            nonisolated(unsafe) let run = b
            DispatchQueue.concurrentPerform(iterations: n) { i in
                let a = from + i * chunk, z = min(to, a + chunk)
                for r in a..<z { run(r) }
            }
        }
    }

    @inline(__always) func g(_ x: Int, _ y: Int, _ key: Int) -> Float {
        let n = PosterCanvas.tileSize
        return Float(tile[((y &+ key &* 131) & (n - 1)) &* n &+ ((x &+ key &* 317) & (n - 1))]) / 255
    }

    // MARK: Printing

    /// Prints an ink through a tone: `t(x, y)` in design units, read through `ramp` with `amp` of grain. `alpha(x, y)` is
    /// how much of this ink lands (also dissolved by grain when `dissolve`).
    func pull(_ ramp: PosterRamp, plate: PosterPlate? = nil, amp: Float, key: Int, offset: (Int, Int) = (0, 0), rows range: (Int, Int)? = nil,
               t: (Double, Double) -> Float) {
        let a = range?.0 ?? (plate.map { $0.firstRow - abs(offset.1) } ?? 0)
        let z = range?.1 ?? (plate.map { $0.lastRow + abs(offset.1) + 1 } ?? h)
        let lut = ramp.lut
        let top = Float(PosterRamp.size - 1)
        rows(a, z) { r in
            let y = self.dy(r)
            let line = self.px + r * self.bpr
            let mr = min(self.h - 1, max(0, r - offset.1))
            let maskLine = plate.map { $0.p + mr * self.w }
            for c in 0..<self.w {
                var cov: Int32 = 255
                if let maskLine {
                    let mc = min(self.w - 1, max(0, c - offset.0))
                    cov = Int32(maskLine[mc])
                    if cov == 0 { continue }
                }
                let tone = t(self.dx(c), y) + amp * (self.g(c, r, key) - 0.5)
                let i = Int(min(1, max(0, tone)) * top) * 3
                let o = line + c * 4
                if cov == 255 {
                    o[0] = lut[i]
                    o[1] = lut[i + 1]
                    o[2] = lut[i + 2]
                } else {
                    o[0] = UInt8(Int32(o[0]) + ((Int32(lut[i]) - Int32(o[0])) * cov) / 255)
                    o[1] = UInt8(Int32(o[1]) + ((Int32(lut[i + 1]) - Int32(o[1])) * cov) / 255)
                    o[2] = UInt8(Int32(o[2]) + ((Int32(lut[i + 2]) - Int32(o[2])) * cov) / 255)
                }
            }
        }
    }

    /// A flat ink through a plate, with `opacity`.
    func flat(_ ink: PosterInk, plate: PosterPlate, opacity: Double = 1, offset: (Int, Int) = (0, 0)) {
        let cr = Int32(ink.r * 255), cg = Int32(ink.g * 255), cb = Int32(ink.b * 255)
        let op = Int32(opacity * 256)
        rows(plate.firstRow - abs(offset.1), plate.lastRow + abs(offset.1) + 1) { r in
            let mr = min(self.h - 1, max(0, r - offset.1))
            let line = self.px + r * self.bpr
            let maskLine = plate.p + mr * self.w
            for c in 0..<self.w {
                let mc = min(self.w - 1, max(0, c - offset.0))
                let m = Int32(maskLine[mc])
                if m == 0 { continue }
                let cov = (m * op) >> 8
                let o = line + c * 4
                o[0] = UInt8(Int32(o[0]) + ((cr - Int32(o[0])) * cov) / 255)
                o[1] = UInt8(Int32(o[1]) + ((cg - Int32(o[1])) * cov) / 255)
                o[2] = UInt8(Int32(o[2]) + ((cb - Int32(o[2])) * cov) / 255)
            }
        }
    }

    /// An ink laid by density 0...1. `grainMix`: 0 is a transparent wash, 1 is hard grains; between, a wash with tooth in it.
    func stipple(_ ink: PosterInk, plate: PosterPlate? = nil, rows range: (Int, Int), key: Int, opacity: Float = 1, grainMix: Float = 1,
                 density: (Double, Double) -> Float) {
        let cr = Float(ink.r * 255), cg = Float(ink.g * 255), cb = Float(ink.b * 255)
        // Small canvases have no room for grains: lean to the wash.
        let mixG = grainMix * Float(0.25 + 0.75 * res)
        rows(range.0, range.1) { r in
            let y = self.dy(r)
            let line = self.px + r * self.bpr
            let maskLine = plate.map { $0.p + r * self.w }
            for c in 0..<self.w {
                var cov: Float = 1
                if let maskLine {
                    let m = maskLine[c]
                    if m == 0 { continue }
                    cov = Float(m) / 255
                }
                let d = min(1, density(self.dx(c), y))
                if d <= 0 { continue }
                let gr = self.g(c, r, key)
                let hard = Poster.sstep(gr - 0.05, gr + 0.05, d)
                let a = (d + (hard - d) * mixG) * opacity * cov
                if a <= 0 { continue }
                let o = line + c * 4
                o[0] = UInt8(Float(o[0]) + (cr - Float(o[0])) * a)
                o[1] = UInt8(Float(o[1]) + (cg - Float(o[1])) * a)
                o[2] = UInt8(Float(o[2]) + (cb - Float(o[2])) * a)
            }
        }
    }

    /// The last pass: paper tooth, ink density drifting across the sheet, and a few pinholes where the paper shows.
    func finish(seed: UInt64, tooth: Float, mottle: Float, pinholes: Float, paper: PosterInk) {
        let n1 = GradientNoise(seed: seed ^ 0x77)
        // Cloudy density at low resolution, read bilinearly.
        let mw = 96, mh = 208
        var cloud = [Float](repeating: 0, count: mw * mh)
        for y in 0..<mh {
            for x in 0..<mw {
                // Turned off the pixel axes and only two octaves: a third one showed as a faint woven grid in the dark skies.
                let px = Double(x) * 0.075, py = Double(y) * 0.075
                cloud[y * mw + x] = Float(n1.fbm(0.8 * px - 0.6 * py, 0.6 * px + 0.8 * py, octaves: 2))
            }
        }
        let fx = Float(mw - 1) / Float(w), fy = Float(mh - 1) / Float(h)
        let pr = Float(paper.r * 255), pg = Float(paper.g * 255), pb = Float(paper.b * 255)
        let toothAmt = tooth * Float(0.35 + 0.65 * res)
        let holeAmt = pinholes * Float(res) * 0.4
        cloud.withUnsafeBufferPointer { cl in
            nonisolated(unsafe) let cloudP = cl.baseAddress!
            rows(0, h) { r in
                let line = self.px + r * self.bpr
                let v = Float(r) * fy
                let vi = min(mh - 2, Int(v)), vf = v - Float(vi)
                for c in 0..<self.w {
                    let u = Float(c) * fx
                    let ui = min(mw - 2, Int(u)), uf = u - Float(ui)
                    let a = cloudP[vi * mw + ui], b = cloudP[vi * mw + ui + 1], cc = cloudP[(vi + 1) * mw + ui], d = cloudP[(vi + 1) * mw + ui + 1]
                    let m = a + (b - a) * uf + (cc - a) * vf + (a - b - cc + d) * uf * vf
                    let gr = self.g(c, r, 11)
                    let k = 1 + mottle * m * 2 + toothAmt * (gr - 0.5)
                    let o = line + c * 4
                    var rr = Float(o[0]) * k, gg = Float(o[1]) * k, bb = Float(o[2]) * k
                    let h2 = self.g(c &* 3 &+ r, r &* 5 &+ c, 23)
                    if holeAmt > 0, h2 > 0.9985, rr * 0.2126 + gg * 0.7152 + bb * 0.0722 > 60 {
                        rr += (pr - rr) * holeAmt
                        gg += (pg - gg) * holeAmt
                        bb += (pb - bb) * holeAmt
                    }
                    o[0] = UInt8(min(255, max(0, rr)))
                    o[1] = UInt8(min(255, max(0, gg)))
                    o[2] = UInt8(min(255, max(0, bb)))
                    o[3] = 255
                }
            }
        }
    }
}

// MARK: PosterRelief: light from hand-placed ridge lines

/// A ridge line: a tent of height `h` along `pts`, falling away at slope `k`.
nonisolated struct PosterRidge: Sendable {
    var pts: [PosterP]
    var h: Double
    var k: Double
    var rampIn = 0.10
    var fadeFrom = 0.75

    func height(at t: Double) -> Double {
        h * min(1, max(0, t) / max(0.001, rampIn)) * (1 - min(1, max(0, (t - fadeFrom) / max(0.001, 1 - fadeFrom))))
    }

    /// The point and downhill direction a fraction along the line.
    func locate(_ t: Double) -> (PosterP, PosterP) {
        var total = 0.0
        for i in 1..<pts.count { total += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
        var left = t * total
        for i in 1..<pts.count {
            let l = hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
            if left <= l || i == pts.count - 1 {
                let u = l > 0 ? left / l : 0
                let dir = PosterP((pts[i].x - pts[i - 1].x) / max(0.001, l), (pts[i].y - pts[i - 1].y) / max(0.001, l))
                return (PosterP(pts[i - 1].x + (pts[i].x - pts[i - 1].x) * u, pts[i - 1].y + (pts[i].y - pts[i - 1].y) * u), dir)
            }
            left -= l
        }
        return (pts[pts.count - 1], PosterP(0, 1))
    }
}

nonisolated final class PosterRelief: @unchecked Sendable {
    let c: PosterCanvas
    let z: UnsafeMutablePointer<Float>
    /// The protrusion of the level kept for snow: how far above its gullies each pixel stands.
    let keep: UnsafeMutablePointer<Float>
    let first: Int, last: Int

    struct Seg { var ax, ay, az, bx, by, bz, k, r: Float; var minY, maxY, minX, maxX: Float }

    init(_ c: PosterCanvas, firstRow: Int, lastRow: Int, slope: Float) {
        self.c = c
        z = .allocate(capacity: c.w * c.h)
        keep = .allocate(capacity: c.w * c.h)
        first = max(0, firstRow)
        last = min(c.h, lastRow)
        keep.initialize(repeating: 0, count: c.w * c.h)
        let zp = z
        z.initialize(repeating: 0, count: c.w * c.h)
        c.rows(first, last) { r in
            let v = slope * Float(c.dy(r))
            let line = zp + r * c.w
            for x in 0..<c.w { line[x] = v }
        }
    }

    deinit {
        z.deallocate()
        keep.deallocate()
    }

    /// Fills `keep` with the distance to the nearest ridge line. Each list has a scale: bigger means its bare rock reaches further.
    func distances(_ lists: [(ridges: [PosterRidge], scale: Float)], reach: Float) {
        struct D { var ax, ay, bx, by, ia, ib: Float; var minY, maxY, minX, maxX: Float }
        var segs: [D] = []
        for l in lists {
            let rc = reach * l.scale
            for r in l.ridges where r.pts.count > 1 {
                var total = 0.0
                for i in 1..<r.pts.count { total += hypot(r.pts[i].x - r.pts[i - 1].x, r.pts[i].y - r.pts[i - 1].y) }
                var run = 0.0
                // Rock along a line tapers to a point at both of its ends: distance reads larger there.
                func taper(_ t: Double) -> Float { Float(max(0.02, min(1, t / 0.12) * min(1, (1 - t) / 0.4))) }
                for i in 1..<r.pts.count {
                    let a = r.pts[i - 1], b = r.pts[i]
                    let ta = run / total
                    run += hypot(b.x - a.x, b.y - a.y)
                    let tb = run / total
                    segs.append(D(ax: Float(a.x), ay: Float(a.y), bx: Float(b.x), by: Float(b.y), ia: taper(ta) * l.scale, ib: taper(tb) * l.scale,
                                  minY: Float(min(a.y, b.y)) - rc, maxY: Float(max(a.y, b.y)) + rc, minX: Float(min(a.x, b.x)) - rc, maxX: Float(max(a.x, b.x)) + rc))
                }
            }
        }
        let c = self.c
        let w = c.w
        let sx = Float(c.sx), ox = Float(c.ox)
        let kp = keep
        let xp = UnsafeMutablePointer<Float>.allocate(capacity: w)
        defer { xp.deallocate() }
        for x in 0..<w { xp[x] = (Float(x) + 0.5 - ox) / sx }
        segs.withUnsafeBufferPointer { sb in
            nonisolated(unsafe) let sp = sb.baseAddress!
            let count = sb.count
            c.rows(first, last) { row in
                let y = Float(c.dy(row))
                let line = kp + row * w
                for x in 0..<w { line[x] = reach }
                for si in 0..<count {
                    let s = sp[si]
                    if y < s.minY || y > s.maxY { continue }
                    let x0 = max(0, Int((s.minX * sx + ox).rounded(.down)))
                    let x1 = min(w - 1, Int((s.maxX * sx + ox).rounded(.up)))
                    if x0 > x1 { continue }
                    let ex = s.bx - s.ax, ey = s.by - s.ay
                    let il = 1 / max(0.0001, ex * ex + ey * ey)
                    let py = y - s.ay
                    var x = x0
                    let ax4 = SIMD4<Float>(repeating: s.ax), ex4 = SIMD4<Float>(repeating: ex), ey4 = SIMD4<Float>(repeating: ey), py4 = SIMD4<Float>(repeating: py)
                    let zero4 = SIMD4<Float>(repeating: 0), one4 = SIMD4<Float>(repeating: 1)
                    let il4 = SIMD4<Float>(repeating: il), ia4 = SIMD4<Float>(repeating: s.ia), ib4 = SIMD4<Float>(repeating: s.ib - s.ia)
                    while x + 3 <= x1 {
                        let dx: SIMD4<Float> = UnsafeRawPointer(xp + x).loadUnaligned(as: SIMD4<Float>.self) - ax4
                        let along: SIMD4<Float> = dx * ex4 + py4 * ey4
                        var q: SIMD4<Float> = along * il4
                        q.replace(with: zero4, where: q .< zero4)
                        q.replace(with: one4, where: q .> one4)
                        let nx: SIMD4<Float> = dx - ex4 * q
                        let ny: SIMD4<Float> = py4 - ey4 * q
                        let len2: SIMD4<Float> = nx * nx + ny * ny
                        let scale: SIMD4<Float> = ia4 + ib4 * q
                        let d: SIMD4<Float> = len2.squareRoot() / scale
                        var cur = UnsafeRawPointer(line + x).loadUnaligned(as: SIMD4<Float>.self)
                        cur.replace(with: d, where: d .< cur)
                        UnsafeMutableRawPointer(line + x).storeBytes(of: cur, as: SIMD4<Float>.self)
                        x += 4
                    }
                    while x <= x1 {
                        let dx = xp[x] - s.ax
                        let q = min(1, max(0, (dx * ex + py * ey) * il))
                        let nx = dx - ex * q, ny = py - ey * q
                        let d = (nx * nx + ny * ny).squareRoot() / (s.ia + (s.ib - s.ia) * q)
                        if d < line[x] { line[x] = d }
                        x += 1
                    }
                }
            }
        }
    }

    /// Adds one level of tents (the tallest tent wins inside a level; levels sum), so a spur's facets tilt the big face under it.
    func add(_ ridges: [PosterRidge], weight: Float = 1, keepLevel: Bool = false) {
        var segs: [Seg] = []
        for r in ridges where r.pts.count > 1 {
            var total = 0.0
            for i in 1..<r.pts.count { total += hypot(r.pts[i].x - r.pts[i - 1].x, r.pts[i].y - r.pts[i - 1].y) }
            var run = 0.0
            for i in 1..<r.pts.count {
                let a = r.pts[i - 1], b = r.pts[i]
                let l = hypot(b.x - a.x, b.y - a.y)
                let ha = r.height(at: run / total), hb = r.height(at: (run + l) / total)
                run += l
                let reach = Float(max(ha, hb) / r.k)
                if reach < 0.5 { continue }
                segs.append(Seg(ax: Float(a.x), ay: Float(a.y), az: Float(ha), bx: Float(b.x), by: Float(b.y), bz: Float(hb), k: Float(r.k), r: reach,
                                minY: Float(min(a.y, b.y)) - reach, maxY: Float(max(a.y, b.y)) + reach,
                                minX: Float(min(a.x, b.x)) - reach, maxX: Float(max(a.x, b.x)) + reach))
            }
        }
        let c = self.c
        let w = c.w
        let sx = Float(c.sx), ox = Float(c.ox)
        let zp = z, kp = keep
        let xp = UnsafeMutablePointer<Float>.allocate(capacity: w)
        defer { xp.deallocate() }
        for x in 0..<w { xp[x] = (Float(x) + 0.5 - ox) / sx }
        segs.withUnsafeBufferPointer { sb in
            nonisolated(unsafe) let sp = sb.baseAddress!
            let count = sb.count
            c.rows(first, last) { row in
                let y = Float(c.dy(row))
                var tmp = [Float](repeating: 0, count: w)
                tmp.withUnsafeMutableBufferPointer { t in
                    for si in 0..<count {
                        let s = sp[si]
                        if y < s.minY || y > s.maxY { continue }
                        // A tent is below ground beyond its reach, so the columns outside that round end need no look.
                        let off = max(0, max(min(s.ay, s.by) - y, y - max(s.ay, s.by)))
                        let round = s.r + 1
                        let room = round * round - off * off
                        if room <= 0 { continue }
                        let half = room.squareRoot()
                        let x0 = max(0, Int(((min(s.ax, s.bx) - half) * sx + ox).rounded(.down)))
                        let x1 = min(w - 1, Int(((max(s.ax, s.bx) + half) * sx + ox).rounded(.up)))
                        if x0 > x1 { continue }
                        let ex = s.bx - s.ax, ey = s.by - s.ay
                        let il = 1 / max(0.0001, ex * ex + ey * ey)
                        let py = y - s.ay
                        var x = x0
                        let tp = t.baseAddress!
                        let ax4 = SIMD4<Float>(repeating: s.ax), ex4 = SIMD4<Float>(repeating: ex), ey4 = SIMD4<Float>(repeating: ey), py4 = SIMD4<Float>(repeating: py)
                        let zero4 = SIMD4<Float>(repeating: 0), one4 = SIMD4<Float>(repeating: 1)
                        let il4 = SIMD4<Float>(repeating: il), az4 = SIMD4<Float>(repeating: s.az), dz4 = SIMD4<Float>(repeating: s.bz - s.az), k4 = SIMD4<Float>(repeating: s.k)
                        while x + 3 <= x1 {
                            let dx: SIMD4<Float> = UnsafeRawPointer(xp + x).loadUnaligned(as: SIMD4<Float>.self) - ax4
                            let along: SIMD4<Float> = dx * ex4 + py4 * ey4
                            var q: SIMD4<Float> = along * il4
                        q.replace(with: zero4, where: q .< zero4)
                        q.replace(with: one4, where: q .> one4)
                            let nx: SIMD4<Float> = dx - ex4 * q
                            let ny: SIMD4<Float> = py4 - ey4 * q
                            let len2: SIMD4<Float> = nx * nx + ny * ny
                            let height: SIMD4<Float> = az4 + dz4 * q
                            let v: SIMD4<Float> = height - k4 * len2.squareRoot()
                            var cur = UnsafeRawPointer(tp + x).loadUnaligned(as: SIMD4<Float>.self)
                            cur.replace(with: v, where: v .> cur)
                            UnsafeMutableRawPointer(tp + x).storeBytes(of: cur, as: SIMD4<Float>.self)
                            x += 4
                        }
                        while x <= x1 {
                            let dx = xp[x] - s.ax
                            let q = min(1, max(0, (dx * ex + py * ey) * il))
                            let nx = dx - ex * q, ny = py - ey * q
                            let v = s.az + (s.bz - s.az) * q - s.k * (nx * nx + ny * ny).squareRoot()
                            if v > t[x] { t[x] = v }
                            x += 1
                        }
                    }
                    let line = zp + row * w
                    for x in 0..<w { line[x] += t[x] * weight }
                    if keepLevel {
                        let k = kp + row * w
                        for x in 0..<w { k[x] = t[x] }
                    }
                }
            }
        }
    }
}

/// How a relief is lit and how its light becomes tone.
nonisolated struct PosterLight: Sendable {
    /// Unit vector toward the light (x right, y down, z toward the viewer).
    var x: Float, y: Float, z: Float

    init(_ x: Float, _ y: Float, _ z: Float) {
        let n = (x * x + y * y + z * z).squareRoot()
        self.x = x / n
        self.y = y / n
        self.z = z / n
    }
}

// MARK: Shared drawing

nonisolated enum PosterDraw {
    /// A conifer with uneven tiers: boughs cut one by one down each side, each with a drooping tip and a sub-tip or two,
    /// some longer, some broken short. `highlights` collects the tops of the boughs for a lighter ink.
    static func conifer(_ rng: inout SplitMix64, x: Double, top: Double, base: Double, halfW: Double, tiers: Int, lean: Double = 0, trunk: Double = 0.028, fine: Bool = true) -> [PosterP] {
        var none: [[PosterP]] = []
        return conifer(&rng, x: x, top: top, base: base, halfW: halfW, tiers: tiers, lean: lean, trunk: trunk, fine: fine, highlights: &none, wantHighlights: false)
    }

    static func conifer(_ rng: inout SplitMix64, x: Double, top: Double, base: Double, halfW: Double, tiers: Int, lean: Double = 0, trunk: Double = 0.028, fine: Bool = true, highlights: inout [[PosterP]], wantHighlights: Bool = true) -> [PosterP] {
        let height = base - top
        // Uneven spacing, tighter near the top.
        var gaps: [Double] = []
        for i in 0..<tiers { gaps.append(rng.next(0.62, 1.38) * (0.45 + 0.55 * Double(i + 1) / Double(tiers))) }
        let total = gaps.reduce(0, +)
        func side(_ s: Double, _ rng: inout SplitMix64, _ hi: inout [[PosterP]]) -> [PosterP] {
            var pts: [PosterP] = []
            var run = 0.0
            for i in 0..<tiers {
                run += gaps[i]
                let t = run / total
                let yy = top + height * t * 0.95 + rng.next(-0.004, 0.004) * height
                let cx = x + lean * (1 - t) * height
                var wide = halfW * (0.03 + 0.97 * pow(t, 0.9)) * rng.next(0.68, 1.1)
                let dice = rng.next()
                if dice < 0.12 { wide *= 0.62 } else if dice > 0.9 { wide *= 1.16 }
                let droop = wide * rng.next(0.20, 0.40) + height * 0.004
                if fine && t > 0.14 {
                    // Out along the top of the bough, with a nick or two.
                    pts.append(PosterP(cx + s * wide * 0.42, yy + droop * rng.next(0.02, 0.14)))
                    pts.append(PosterP(cx + s * wide * 0.6, yy + droop * rng.next(0.3, 0.42)))
                    pts.append(PosterP(cx + s * wide * 0.56, yy + droop * rng.next(0.42, 0.5)))
                    pts.append(PosterP(cx + s * wide * 0.78, yy + droop * rng.next(0.58, 0.7)))
                    pts.append(PosterP(cx + s * wide * 0.74, yy + droop * rng.next(0.7, 0.78)))
                    pts.append(PosterP(cx + s * wide, yy + droop))
                    // Back under it in uneven tufts of needles, some hanging, some hardly there.
                    var ux = 0.97
                    while ux > 0.5 {
                        let u = (ux - 0.46) / 0.54
                        let stepBack = rng.next(0.05, 0.17)
                        let hang = rng.next() < 0.45 ? rng.next(0.02, 0.1) : rng.next(0.12, 0.36)
                        pts.append(PosterP(cx + s * wide * (ux - stepBack * 0.3), yy + droop * (0.92 * (0.74 + 0.26 * u) + hang)))
                        pts.append(PosterP(cx + s * wide * (ux - stepBack), yy + droop * (0.74 + 0.24 * u)))
                        ux -= stepBack
                    }
                } else {
                    pts.append(PosterP(cx + s * wide, yy + droop))
                }
                pts.append(PosterP(cx + s * wide * rng.next(0.22, 0.38), yy + droop * 0.74 + height * 0.002))
                if wantHighlights && t > 0.1 && s < 0 && rng.next() < 0.72 {
                    // The sun catches only the top of a bough on the side facing it: a sliver, not a slab.
                    let reach = rng.next(0.72, 0.96)
                    hi.append([PosterP(cx + s * wide * 0.36, yy + droop * 0.1), PosterP(cx + s * wide * 0.56, yy + droop * 0.28), PosterP(cx + s * wide * reach, yy + droop * 0.84),
                               PosterP(cx + s * wide * 0.58, yy + droop * 0.42), PosterP(cx + s * wide * 0.4, yy + droop * 0.22)])
                }
            }
            return pts
        }
        var pts: [PosterP] = [PosterP(x + lean * height, top)]
        pts += side(-1, &rng, &highlights)
        let tw = height * trunk * 0.5
        pts.append(PosterP(x - tw, top + height * 0.97))
        pts.append(PosterP(x - tw, base))
        pts.append(PosterP(x + tw, base))
        pts.append(PosterP(x + tw, top + height * 0.97))
        pts += side(1, &rng, &highlights).reversed()
        return pts
    }
}

// MARK: Billows

/// One lobe of an illustrated cloud. Lobes are laid like scales, later over earlier, so a cloud is built the way one is drawn:
/// a rounded silhouette, then rounder shapes overlapping inside it, each with a lit shoulder and a belly falling into shadow.
nonisolated struct PosterBillow: Sendable {
    var x: Double, y: Double, rx: Double, ry: Double
    /// The big form this lobe belongs to: decides which side of the heap it is on.
    var mx: Double = 0, my: Double = 0, mrx: Double = 1, mry: Double = 1
    /// Phase of the lobe's unevenness.
    var phase: Double = 0
}

nonisolated extension PosterCanvas {
    /// Lays billows in order. `shade(x, y, ndl, form, up, billow)` returns the tone: `ndl` is the lobe's facing to the light, `form` its heap's, `up` its facing to the sky above.
    func billows(_ list: [PosterBillow], ramp: PosterRamp, amp: Float, key: Int, light: PosterLight = PosterLight(-0.6, -0.6, 0.53), pointLight: PosterP? = nil, lightHeight: Float = 300,
                 base: ((Double) -> Double)? = nil, shade: (Double, Double, Float, Float, Float, PosterBillow) -> Float) {
        guard !list.isEmpty else { return }
        let bucket = 32
        var buckets = [[Int32]](repeating: [], count: h / bucket + 2)
        for (i, l) in list.enumerated() {
            let t = max(0, Int(((l.y - l.ry) * sx + oy) / Double(bucket)))
            let e = min(buckets.count - 1, Int(max(0, ((l.y + l.ry) * sx + oy) / Double(bucket))))
            if t <= e { for bi in t...e { buckets[bi].append(Int32(i)) } }
        }
        let lut = ramp.lut
        let top = Float(PosterRamp.size - 1)
        let w = self.w, sx = self.sx, ox = self.ox
        list.withUnsafeBufferPointer { lb in
            buckets.withUnsafeBufferPointer { bb in
                nonisolated(unsafe) let lp = lb.baseAddress!
                nonisolated(unsafe) let bp = bb.baseAddress!
                rows(0, h) { r in
                    let ids = bp[r / bucket]
                    if ids.isEmpty { return }
                    let y = self.dy(r)
                    var tones = [Float](repeating: 0, count: w)
                    var cover = [UInt8](repeating: 0, count: w)
                    // Lobe `i` lays one pixel: its tone and how much of it lands, or nothing.
                    @inline(__always) func lay(_ l: PosterBillow, col: Int, dyn0: Double, invRx: Double, edge: Double) -> (t: Float, aa: Float)? {
                        let xd = (Double(col) + 0.5 - ox) / sx
                        let dxn0 = (xd - l.x) * invRx
                        let raw2 = dxn0 * dxn0 + dyn0 * dyn0
                        if raw2 > 1.34 { return nil }
                        // Uneven in angle, at a few scales, so a lobe is never an ellipse.
                        let th = atan2(dyn0, dxn0)
                        let wob = 1 + 0.05 * sin(3 * th + l.phase) + 0.03 * sin(7 * th + l.phase * 2.3) + 0.016 * sin(13 * th + l.phase * 3.1)
                        let dxn = dxn0 * wob, dyn = dyn0 * wob
                        let d2 = dxn * dxn + dyn * dyn
                        if d2 > 1.04 { return nil }
                        let ny = Float(dyn)
                        let d = d2.squareRoot()
                        let aa = Float(min(1, max(0, (1 - d) * edge + 0.5)))
                        if aa <= 0 { return nil }
                        let nx = Float(dxn)
                        let nz = Float((1 - min(1, d2)).squareRoot())
                        var lx = light.x, ly = light.y, lz = light.z
                        if let pl = pointLight {
                            let vx = Float(pl.x - xd), vy = Float(pl.y - y), vz = lightHeight
                            let inv = 1 / (vx * vx + vy * vy + vz * vz).squareRoot()
                            lx = vx * inv
                            ly = vy * inv
                            lz = vz * inv
                        }
                        let ndl = nx * lx + ny * ly + nz * lz
                        let up = -ny * 0.7 + nz * 0.7
                        let fx = Float((xd - l.mx) / l.mrx), fy = Float((y - l.my) / l.mry)
                        let fd2 = min(1, fx * fx + fy * fy)
                        let fz = (1 - fd2).squareRoot()
                        let fi = fd2 > 1e-4 && fd2 >= 1 ? 1 / (fx * fx + fy * fy).squareRoot() : 1
                        let form = (fx * fi) * lx + (fy * fi) * ly + fz * lz
                        return (shade(xd, y, ndl, form, up, l), aa)
                    }
                    // Back from the last lobe: the first one that surely covers a pixel hides everything laid before it there, so those are never shaded.
                    var front = [Int32](repeating: -1, count: w)
                    var bi = ids.count - 1
                    while bi >= 0 {
                        let l = lp[Int(ids[bi])]
                        let dyn0 = (y - l.y) / l.ry
                        let edge = min(l.rx, l.ry) * sx
                        // `wob` is at most 1.096, so inside this radius the lobe's edge cannot reach.
                        let inner = (1 - 0.5 / edge) / 1.0961
                        let room = inner > 0 ? inner * inner - dyn0 * dyn0 : -1
                        if room > 0 {
                            let half = room.squareRoot() * l.rx
                            let x0 = max(0, Int((((l.x - half) * sx + ox - 0.5)).rounded(.up)) + 1)
                            let x1 = min(w - 1, Int((((l.x + half) * sx + ox - 0.5)).rounded(.down)) - 1)
                            if x0 <= x1 { for col in x0...x1 where front[col] < 0 { front[col] = Int32(bi) } }
                        }
                        bi -= 1
                    }
                    for (index, ii) in ids.enumerated() {
                        let l = lp[Int(ii)]
                        let dyn0 = (y - l.y) / l.ry
                        if abs(dyn0) >= 1.14 { continue }
                        let half = l.rx * 1.14
                        let x0 = max(0, Int(((l.x - half) * sx + ox).rounded(.down)) - 1)
                        let x1 = min(w - 1, Int(((l.x + half) * sx + ox).rounded(.up)) + 1)
                        if x0 > x1 { continue }
                        let invRx = 1 / l.rx
                        let edge = min(l.rx, l.ry) * sx
                        let at = Int32(index)
                        for col in x0...x1 where front[col] <= at {
                            guard let laid = lay(l, col: col, dyn0: dyn0, invRx: invRx, edge: edge) else { continue }
                            tones[col] += (laid.t - tones[col]) * laid.aa
                            let ca = UInt8(laid.aa * 255)
                            if ca > cover[col] { cover[col] = ca }
                        }
                    }
                    let line = self.px + r * self.bpr
                    for col in 0..<w {
                        var cov = Int32(cover[col])
                        if cov == 0 { continue }
                        if let base {
                            let aa = (base((Double(col) + 0.5 - ox) / sx) - y) * sx + 0.5
                            if aa <= 0 { continue }
                            if aa < 1 { cov = Int32(Double(cov) * aa) }
                        }
                        let gr = amp * (self.g(col, r, key) - 0.5)
                        var i = Int(min(1, max(0, tones[col] + gr)) * top) * 3
                        if front[col] > 0 {
                            // The skipped lobes could only move this tone by rounding. Where that could matter, right at the edge of a step in the ramp, lay them all.
                            let f = min(1, max(0, tones[col] + gr)) * top
                            let frac = f - f.rounded(.down)
                            if frac < 0.002 || frac > 0.998 {
                                var exact: Float = 0
                                for ii in ids {
                                    let l = lp[Int(ii)]
                                    let dyn0 = (y - l.y) / l.ry
                                    if abs(dyn0) >= 1.14 { continue }
                                    if let laid = lay(l, col: col, dyn0: dyn0, invRx: 1 / l.rx, edge: min(l.rx, l.ry) * sx) { exact += (laid.t - exact) * laid.aa }
                                }
                                i = Int(min(1, max(0, exact + gr)) * top) * 3
                            }
                        }
                        let o = line + col * 4
                        if cov >= 255 {
                            o[0] = lut[i]
                            o[1] = lut[i + 1]
                            o[2] = lut[i + 2]
                        } else {
                            o[0] = UInt8(Int32(o[0]) + ((Int32(lut[i]) - Int32(o[0])) * cov) / 255)
                            o[1] = UInt8(Int32(o[1]) + ((Int32(lut[i + 1]) - Int32(o[1])) * cov) / 255)
                            o[2] = UInt8(Int32(o[2]) + ((Int32(lut[i + 2]) - Int32(o[2])) * cov) / 255)
                        }
                    }
                }
            }
        }
    }
}
