// A brush engine for computed oil paintings.
//
// A picture is made in two steps. A scene first computes a small "reference": colour, the way strokes should run there
// and how much attention the place deserves. The engine below then paints that reference: a toned ground, big block-in
// strokes, then smaller and smaller ones where the reference asks for them.
//
// - Each stroke is a real mark: a slightly bent ribbon with its own bristles, a colour that changes along it, a load of
//   paint that runs out toward its end (so it breaks up over the canvas weave) and a ridge of thickness.
// - Strokes are laid in a fixed order, but rows of the canvas are painted in parallel: a pixel only depends on the
//   strokes crossing it, in order, so every band of rows can run through its strokes alone.
// - Thickness is kept in the canvas's fourth channel and lit once at the end, which is what makes it read as paint.

import CoreGraphics
import Foundation

typealias PaintV3 = SIMD3<Float>

@inline(__always) nonisolated func PaintSat(_ x: Float) -> Float { min(1, max(0, x)) }
@inline(__always) nonisolated func PaintSstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = PaintSat((x - a) / (b - a))
    return t * t * (3 - 2 * t)
}
@inline(__always) nonisolated func PaintLerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) nonisolated func PaintMix(_ a: PaintV3, _ b: PaintV3, _ t: Float) -> PaintV3 { a + (b - a) * t }
@inline(__always) nonisolated func PaintLum(_ c: PaintV3) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
@inline(__always) nonisolated func PaintHex(_ r: Int, _ g: Int, _ b: Int) -> PaintV3 { PaintV3(Float(r), Float(g), Float(b)) / 255 }

nonisolated func PaintPar(_ n: Int, _ body: @Sendable (Int) -> Void) {
    // Past a dozen workers the threads only queue for page faults: more CPU time and no better picture.
    let chunks = min(n, 12)
    if chunks <= 1 {
        for i in 0..<n { body(i) }
        return
    }
    DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
        for i in (n * chunk / chunks)..<(n * (chunk + 1) / chunks) { body(i) }
    }
}

/// Anonymous pages straight from the system, handed back the moment they're released. A picture passes through many short-lived
/// buffers; the allocator's caches would otherwise keep every one of them on the books until the process ends.
nonisolated enum PaintPages {
    /// Below this the allocator keeps what it reuses, and saves a page fault each time.
    private static let direct = 3 << 20

    /// Zeroed.
    static func take(_ bytes: Int) -> UnsafeMutableRawPointer {
        let size = max(1, bytes)
        if size < direct { return calloc(size, 1)! }
        let made = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard let made, made != UnsafeMutableRawPointer(bitPattern: -1) else { fatalError("out of memory") }
        return made
    }

    static func give(_ pointer: UnsafeMutableRawPointer, _ bytes: Int) {
        let size = max(1, bytes)
        if size < direct { free(pointer) } else { munmap(pointer, size) }
    }
}

/// A plain block of floats, rows of `c` channels.
nonisolated final class PaintBuf: @unchecked Sendable {
    let w: Int, h: Int, c: Int
    let p: UnsafeMutablePointer<Float>

    init(w: Int, h: Int, c: Int = 1, fill: Float = 0) {
        self.w = w
        self.h = h
        self.c = c
        let count = max(1, w * h * c)
        p = PaintPages.take(count * MemoryLayout<Float>.size).bindMemory(to: Float.self, capacity: count)
        if fill != 0 { p.initialize(repeating: fill, count: count) }
    }

    deinit { PaintPages.give(UnsafeMutableRawPointer(p), max(1, w * h * c) * MemoryLayout<Float>.size) }

    @inline(__always) func get3(_ x: Int, _ y: Int) -> PaintV3 {
        let i = (y * w + x) * c
        return PaintV3(p[i], p[i + 1], p[i + 2])
    }

    @inline(__always) func set3(_ x: Int, _ y: Int, _ v: PaintV3) {
        let i = (y * w + x) * c
        p[i] = v.x
        p[i + 1] = v.y
        p[i + 2] = v.z
    }

    @inline(__always) func at(_ x: Int, _ y: Int, _ ch: Int = 0) -> Float { p[(y * w + x) * c + ch] }

    /// Bilinear, clamped at the edges. `x`, `y` in this buffer's pixels (pixel centres at +0.5).
    @inline(__always) func sample3(_ x: Float, _ y: Float) -> PaintV3 {
        let fx = min(Float(w) - 1.001, max(0, x - 0.5)), fy = min(Float(h) - 1.001, max(0, y - 0.5))
        let ix = Int(fx), iy = Int(fy)
        let tx = fx - Float(ix), ty = fy - Float(iy)
        let a = get3(ix, iy), b = get3(ix + 1, iy), d = get3(ix, iy + 1), e = get3(ix + 1, iy + 1)
        return PaintMix(PaintMix(a, b, tx), PaintMix(d, e, tx), ty)
    }

    @inline(__always) func sample(_ x: Float, _ y: Float, _ ch: Int = 0) -> Float {
        let fx = min(Float(w) - 1.001, max(0, x - 0.5)), fy = min(Float(h) - 1.001, max(0, y - 0.5))
        let ix = Int(fx), iy = Int(fy)
        let tx = fx - Float(ix), ty = fy - Float(iy)
        let a = at(ix, iy, ch), b = at(ix + 1, iy, ch), d = at(ix, iy + 1, ch), e = at(ix + 1, iy + 1, ch)
        return PaintLerp(PaintLerp(a, b, tx), PaintLerp(d, e, tx), ty)
    }

    /// Half size, box averaged.
    func halved() -> PaintBuf {
        let nw = max(1, w / 2), nh = max(1, h / 2)
        let out = PaintBuf(w: nw, h: nh, c: c)
        let src = self
        PaintPar(nh) { y in
            for x in 0..<nw {
                let x0 = min(w - 1, x * 2), x1 = min(w - 1, x * 2 + 1), y0 = min(h - 1, y * 2), y1 = min(h - 1, y * 2 + 1)
                for ch in 0..<c {
                    out.p[(y * nw + x) * c + ch] = 0.25 * (src.at(x0, y0, ch) + src.at(x1, y0, ch) + src.at(x0, y1, ch) + src.at(x1, y1, ch))
                }
            }
        }
        return out
    }

    /// Two passes of a box blur, radius `r`, each channel, into a new buffer.
    func blurred(_ r: Int) -> PaintBuf {
        guard r > 0 else { return self }
        let out = PaintBuf(w: w, h: h, c: c)
        memcpy(out.p, p, w * h * c * MemoryLayout<Float>.size)
        out.blur(r)
        return out
    }

    /// Two passes of a box blur, radius `r`, each channel, in place: running sums across each row, then running sums down a run of columns at a time.
    func blur(_ r: Int) {
        guard r > 0 else { return }
        let w = self.w, h = self.h, c = self.c
        let scale = 1 / Float(2 * r + 1)
        let lineLength = w * c
        // Columns are taken a cache's worth at a time, each run keeping its own sums and the rows it still has to subtract.
        let runLength = min(lineLength, 256 * c)
        let runs = (lineLength + runLength - 1) / runLength
        for _ in 0..<2 {
            PaintPar(h) { y in
                withUnsafeTemporaryAllocation(of: Float.self, capacity: lineLength) { copy in
                    let line = copy.baseAddress!, into = self.p + y * lineLength
                    memcpy(line, into, lineLength * MemoryLayout<Float>.size)
                    for ch in 0..<c {
                        var sum: Float = 0
                        for i in -r...r { sum += line[min(w - 1, max(0, i)) * c + ch] }
                        var at = ch
                        for x in 0..<w {
                            into[at] = sum * scale
                            sum += line[min(w - 1, x + r + 1) * c + ch] - line[max(0, x - r) * c + ch]
                            at += c
                        }
                    }
                }
            }
            PaintPar(runs) { run in
                let first = run * runLength, count = min(runLength, lineLength - first)
                let slots = r + 1
                withUnsafeTemporaryAllocation(of: Float.self, capacity: count * (slots + 1)) { scratch in
                    let sum = scratch.baseAddress!, ring = sum + count
                    for k in 0..<count { sum[k] = 0 }
                    let base = self.p + first
                    for i in -r...r {
                        let line = base + min(h - 1, max(0, i)) * lineLength
                        for k in 0..<count { sum[k] += line[k] }
                    }
                    for y in 0..<h {
                        let into = base + y * lineLength
                        let kept = ring + (y % slots) * count
                        for k in 0..<count {
                            kept[k] = into[k]
                            into[k] = sum[k] * scale
                        }
                        // The row entering is still untouched; the row leaving has been kept.
                        let enter = y + r + 1
                        let add: UnsafeMutablePointer<Float> = enter < h ? base + enter * lineLength : (h - 1 > y ? base + (h - 1) * lineLength : ring + ((h - 1) % slots) * count)
                        let drop = ring + (max(0, y - r) % slots) * count
                        for k in 0..<count { sum[k] += add[k] - drop[k] }
                    }
                }
            }
        }
    }
}

/// The same lattice and the same values as the app's GradientNoise, without a branch per corner: a coin-flip switch is most of what noise costs.
nonisolated struct PaintNoise: @unchecked Sendable {
    private let seed: UInt32
    private let gradients: UnsafePointer<SIMD2<Double>>

    init(seed: UInt64) {
        self.seed = UInt32(truncatingIfNeeded: seed ^ (seed >> 29))
        gradients = PaintNoise.table
    }

    @inline(__always) private func corner(_ ix: Int, _ iy: Int, _ dx: Double, _ dy: Double) -> Double {
        var h = (UInt32(truncatingIfNeeded: ix) &* 0x8DA6_B343) ^ (UInt32(truncatingIfNeeded: iy) &* 0xD816_3841) ^ seed
        h ^= h >> 13
        h = h &* 0x5BD1_E995
        h ^= h >> 15
        let g = gradients[Int(h & 7)]
        return g.x * dx + g.y * dy
    }

    /// Never freed, never written after it's made.
    nonisolated(unsafe) private static let table: UnsafePointer<SIMD2<Double>> = {
        let t = UnsafeMutablePointer<SIMD2<Double>>.allocate(capacity: 8)
        let values: [SIMD2<Double>] = [SIMD2(1, 1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(-1, -1), SIMD2(1.4, 0), SIMD2(-1.4, 0), SIMD2(0, 1.4), SIMD2(0, -1.4)]
        for (i, v) in values.enumerated() { t[i] = v }
        return UnsafePointer(t)
    }()

    /// Roughly -1…1, about one feature per unit step.
    @inline(__always) func value(_ x: Double, _ y: Double) -> Double {
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let ix = Int(fx), iy = Int(fy)
        let dx = x - fx, dy = y - fy
        let u = dx * dx * dx * (dx * (dx * 6 - 15) + 10), v = dy * dy * dy * (dy * (dy * 6 - 15) + 10)
        let a = corner(ix, iy, dx, dy), b = corner(ix + 1, iy, dx - 1, dy)
        let c = corner(ix, iy + 1, dx, dy - 1), d = corner(ix + 1, iy + 1, dx - 1, dy - 1)
        return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
    }

    /// Octaves of `value`, each twice as fine and half as strong.
    func fbm(_ x: Double, _ y: Double, octaves: Int) -> Double {
        var sum = 0.0, amp = 1.0, freq = 1.0, norm = 0.0
        for o in 0..<octaves {
            sum += amp * value(x * freq + Double(o) * 17.3, y * freq - Double(o) * 9.1)
            norm += amp
            amp *= 0.5
            freq *= 2.03
        }
        return sum / norm
    }
}

/// A plain block of small numbers: what a study holds per place that doesn't need a float. Written and read as floats.
nonisolated final class PaintByteBuf: @unchecked Sendable {
    nonisolated struct Access {
        fileprivate let bytes: UnsafeMutablePointer<UInt8>
        fileprivate let scale: Float

        @inline(__always) subscript(i: Int) -> Float {
            get { Float(bytes[i]) / scale }
            nonmutating set { bytes[i] = UInt8(max(0, min(255, newValue * scale + 0.5))) }
        }
    }

    let w: Int, h: Int, c: Int
    let bytes: UnsafeMutablePointer<UInt8>
    let scale: Float

    /// `scale`: what 1.0 is stored as.
    init(w: Int, h: Int, c: Int = 1, fill: Float = 0, scale: Float = 255) {
        self.w = w
        self.h = h
        self.c = c
        self.scale = scale
        let count = max(1, w * h * c)
        bytes = PaintPages.take(count).bindMemory(to: UInt8.self, capacity: count)
        if fill != 0 { bytes.initialize(repeating: UInt8(max(0, min(255, fill * scale + 0.5))), count: count) }
    }

    deinit { PaintPages.give(UnsafeMutableRawPointer(bytes), max(1, w * h * c)) }

    /// A private copy, for reading what was here while the original is rewritten on several threads.
    func copied() -> PaintByteBuf {
        let out = PaintByteBuf(w: w, h: h, c: c, scale: scale)
        out.bytes.update(from: bytes, count: max(1, w * h * c))
        return out
    }

    @inline(__always) var p: Access { Access(bytes: bytes, scale: scale) }

    @inline(__always) func at(_ x: Int, _ y: Int, _ ch: Int = 0) -> Float { Float(bytes[(y * w + x) * c + ch]) / scale }

    @inline(__always) func sample(_ x: Float, _ y: Float, _ ch: Int = 0) -> Float {
        let fx = min(Float(w) - 1.001, max(0, x - 0.5)), fy = min(Float(h) - 1.001, max(0, y - 0.5))
        let ix = Int(fx), iy = Int(fy)
        let tx = fx - Float(ix), ty = fy - Float(iy)
        let a = at(ix, iy, ch), b = at(ix + 1, iy, ch), d = at(ix, iy + 1, ch), e = at(ix + 1, iy + 1, ch)
        return PaintLerp(PaintLerp(a, b, tx), PaintLerp(d, e, tx), ty)
    }
}

/// One mark a scene asks for by hand: a tree's tip, a star, the moon, a glint on the water. In units of the short side.
nonisolated struct PaintAuthoredStroke {
    var x, y, angle, length, width: Float
    var color: PaintV3
    var color2: PaintV3? = nil
    var alpha: Float = 1
    var load: Float = 1
    var thick: Float = 1
    var bend: Float = 0
    var round: Float = 1
    /// When set, the colour isn't chosen in advance: the brush picks it up off the wet canvas this far away (units), the way
    /// a painter drags the neighbouring passage over an edge to trim it.
    var pick: SIMD2<Float>? = nil
    var feather: Float = 0
    /// Multiplies a picked-up colour, a touch lighter or darker than the passage it came from.
    var pickTint = PaintV3(repeating: 1)
    var taper: Float = 0.25
    var tipIn: Float = 0.5
    var tipOut: Float = 0.5
    var comb: Float = 1
}

nonisolated struct PaintFloatsRef: @unchecked Sendable { let p: UnsafeMutablePointer<Float> }

/// A sun or moon: one round touch of thick paint, found on the side the light is and lost on the other. Laid before the marks placed by hand.
nonisolated struct PaintDisc {
    var x, y, r: Float
    var lit: PaintV3, shade: PaintV3
    /// The way the lit side faces, radians.
    var angle: Float
    /// Width of the edge as a fraction of the radius, on the lit side and away from it.
    var softLit: Float, softShade: Float
}

/// A slow noise worked out on a coarse grid and opened up to the whole study: one value per place, at a fraction of the cost. `at(u, v)` is in width units.
nonisolated func PaintNoiseField(w: Int, h: Int, step: Int, _ at: @Sendable (Double, Double) -> Float) -> PaintBuf {
    let out = PaintBuf(w: w, h: h)
    let gw = w / step + 2, gh = h / step + 2
    let grid = PaintBuf(w: gw, h: gh)
    let unit = Double(w)
    let s = Double(step)
    PaintPar(gh) { gy in
        let v = Double(gy) * s / unit
        for gx in 0..<gw { grid.p[gy * gw + gx] = at(Double(gx) * s / unit, v) }
    }
    let inv = 1 / Float(step)
    PaintPar(h) { y in
        let gy = y / step
        let fy = Float(y - gy * step) * inv
        let a = grid.p + gy * gw, b = grid.p + (gy + 1) * gw
        let o = out.p + y * w
        for x in 0..<w {
            let gx = x / step
            let fx = Float(x - gx * step) * inv
            let top = a[gx] + (a[gx + 1] - a[gx]) * fx
            let bottom = b[gx] + (b[gx + 1] - b[gx]) * fx
            o[x] = top + (bottom - top) * fy
        }
    }
    return out
}

/// What a scene hands the painter.
nonisolated final class PaintSceneRef: @unchecked Sendable {
    let w: Int, h: Int
    /// Display-referred colour.
    let rgb: PaintBuf
    /// The way strokes should run here: cos 2θ, sin 2θ scaled by how much the scene cares.
    let dir: PaintBuf
    /// 0: broad masses only, 1: the finest strokes are wanted here.
    let detail: PaintByteBuf
    /// 0: found edges, strokes stop at colour changes; 1: lost edges, strokes run across them.
    let soft: PaintByteBuf
    /// Stroke length multiplier, stroke width multiplier here.
    let shape: PaintByteBuf
    let formWeight: PaintByteBuf
    /// How much a stroke may wander off the field here, 0…1: still water keeps dead level.
    let steady: PaintByteBuf
    /// 1 where the first layers are pulled straight down whatever the field says (a mirrored image in still water).
    let pullDown: PaintByteBuf
    /// Where the painter finishes by finding edges again: a thin, sure line of paint along each change of plane. 0 almost everywhere.
    let focus: PaintByteBuf
    /// Wet into wet: 0, a mark keeps its crisp edge; 1, its edges melt into what's under it. Clouds want this; rock doesn't.
    let wet: PaintByteBuf
    /// 1: the bristles show as a comb of hairlines; 0: a flat, even mark (a mirror in still water is laid in with no comb).
    let comb: PaintByteBuf
    /// A last wet blend: paint here is dragged along the flow and flattened, so a shadow mass rests the eye. 0 almost everywhere.
    let blend: PaintByteBuf
    /// Which shape each place belongs to: the sky, a lit plane, a shadow plane, the water. A stroke only ever paints its own shape,
    /// except where the scene says the edge is soft: this is what makes a big brush cut a clean silhouette.
    let level: PaintByteBuf
    /// Toward the light, in picture coordinates (x right, y down): what lights the thickness of the paint at the end.
    var lightDir = SIMD2<Float>(-0.707, -0.707)
    var authored: [PaintAuthoredStroke] = []
    var discs: [PaintDisc] = []
    /// The toned canvas under the paint.
    var ground = PaintV3(0.42, 0.30, 0.2)
    var dark = false
    /// How strongly the marks are lit at the end, 1 is normal.
    var relief: Float = 1
    /// Colour jitter per stroke, 1 is normal.
    var breakup: Float = 1

    init(w: Int, h: Int) {
        self.w = w
        self.h = h
        rgb = PaintBuf(w: w, h: h, c: 3)
        dir = PaintBuf(w: w, h: h, c: 2)
        detail = PaintByteBuf(w: w, h: h)
        soft = PaintByteBuf(w: w, h: h)
        // Stroke length and width multipliers stay well under 2.5.
        shape = PaintByteBuf(w: w, h: h, c: 2, fill: 1, scale: 100)
        formWeight = PaintByteBuf(w: w, h: h, fill: 1)
        steady = PaintByteBuf(w: w, h: h, fill: 1)
        pullDown = PaintByteBuf(w: w, h: h)
        focus = PaintByteBuf(w: w, h: h)
        wet = PaintByteBuf(w: w, h: h)
        comb = PaintByteBuf(w: w, h: h, fill: 1)
        blend = PaintByteBuf(w: w, h: h)
        level = PaintByteBuf(w: w, h: h, fill: 1, scale: 1)
    }

    /// Islands of a shape too small to hold a real mark are given to whatever surrounds them: no stray dabs of light in a shadow mass.
    func pruneLevels(minArea: Int, only: Set<Int>? = nil, scale: (@Sendable (Int) -> Float)? = nil) {
        let w = self.w, h = self.h
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int32] = []
        var members: [Int32] = []
        let levels = level.p
        for start in 0..<(w * h) where !seen[start] {
            let value = levels[start]
            stack.removeAll(keepingCapacity: true)
            members.removeAll(keepingCapacity: true)
            stack.append(Int32(start))
            seen[start] = true
            var other: Float = -1
            while let top = stack.popLast() {
                let i = Int(top)
                members.append(top)
                let x = i % w, y = i / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let j = ny * w + nx
                    if levels[j] == value {
                        if !seen[j] {
                            seen[j] = true
                            stack.append(Int32(j))
                        }
                    } else {
                        other = levels[j]
                    }
                }
            }
            let limit = scale.map { Int(Float(minArea) * $0(start / w)) } ?? minArea
            if let only, !only.contains(Int(value)) { continue }
            if members.count < limit && other >= 0 {
                // It goes to what surrounds it, colour and all, so nothing of it is left under the paint.
                var around = PaintV3.zero
                var aroundN: Float = 0
                let rgbNow = rgb
                for m in members {
                    let i = Int(m), x = i % w, y = i / w
                    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                        if levels[ny * w + nx] != value {
                            around += rgbNow.get3(nx, ny)
                            aroundN += 1
                        }
                    }
                }
                for m in members {
                    let i = Int(m)
                    levels[i] = other
                    if aroundN > 0 { rgbNow.set3(i % w, i / w, around / aroundN) }
                }
            }
        }
    }

    @inline(__always) func setShape(_ x: Int, _ y: Int, length: Float, width: Float) {
        let i = (y * w + x) * 2
        shape.p[i] = length
        shape.p[i + 1] = width
    }

    /// A painter squints: small changes inside a passage go, the edges between passages stay. (A Kuwahara filter built
    /// from blurs.) `keep(x, y)` says how much of the original to leave.
    func simplify(radius: Int, keep: @Sendable (Int, Int) -> Float = { _, _ in 0 }) {
        guard radius > 0 else { return }
        let w = self.w, h = self.h
        let stats = PaintBuf(w: w, h: h, c: 5)
        let rgb = self.rgb
        PaintPar(h) { y in
            for x in 0..<w {
                let c = rgb.get3(x, y), l = PaintLum(c)
                let i = (y * w + x) * 5
                stats.p[i] = c.x
                stats.p[i + 1] = c.y
                stats.p[i + 2] = c.z
                stats.p[i + 3] = l
                stats.p[i + 4] = l * l
            }
        }
        stats.blur(max(1, radius * 2 / 3))
        let blurred = stats
        let out = PaintBuf(w: w, h: h, c: 3)
        // Eight samples round the point, each weighted by how flat its patch is: a smooth choice between them, so the
        // result keeps planes and edges without the staircase a hard pick leaves.
        let o = Float(radius)
        let offsets: [(Int, Int)] = (0..<8).map { k in
            let a = Float(k) * .pi / 4 + .pi / 8
            return (Int((cos(a) * o).rounded()), Int((sin(a) * o).rounded()))
        }
        PaintPar(h) { y in
            for x in 0..<w {
                var sum = PaintV3.zero
                var weight: Float = 0
                for (dx, dy) in offsets {
                    let sx = min(w - 1, max(0, x + dx)), sy = min(h - 1, max(0, y + dy))
                    let i = (sy * w + sx) * 5
                    let m = blurred.p[i + 3]
                    let variance = max(0, blurred.p[i + 4] - m * m)
                    let q = 1 / (0.00004 + variance)
                    let g = q * q * q
                    sum += PaintV3(blurred.p[i], blurred.p[i + 1], blurred.p[i + 2]) * g
                    weight += g
                }
                out.set3(x, y, PaintMix(sum / weight, rgb.get3(x, y), keep(x, y)))
            }
        }
        memcpy(rgb.p, out.p, w * h * 3 * MemoryLayout<Float>.size)
    }

    /// The painter's last pass round a summit: the sky's own colour cut in against the silhouette with a small flat brush,
    /// so the focal edge is found while everything else stays loose. `skyline` is the first land row per column (reference pixels).
    func cutIn(skyline: [Float], around summitU: Float, reach: Float, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let unitPx = Float(w)
        var col = Float(0)
        while col < Float(w - 3) {
            let i = Int(col)
            let u = (col + 0.5) / unitPx
            let near = PaintSstep(reach, reach * 0.35, abs(u - summitU))
            let step = 0.0085 * unitPx * Float(rng.next(0.7, 1.3))
            defer { col += step }
            if near <= 0.02 || skyline[i] >= Float(h - 2) { continue }
            let j = min(w - 1, i + Int(max(1, 0.012 * unitPx)))
            let dy = skyline[j] - skyline[i], dx = Float(j - i)
            if abs(dy) > dx * 5 { continue }
            let angle = atan2(dy, dx)
            let across = 0.0045 + 0.0035 * Float(rng.next())
            let rowAbove = max(0, Int(skyline[i] - across * 1.6 * unitPx - 0.02 * unitPx))
            let colour = rgb.get3(i, rowAbove)
            let nx = sin(angle), ny = -cos(angle)
            // Picked off the sky right beside the stroke, so it trims the silhouette without drawing a line round it.
            let reachOut = across * 1.5 + 0.007
            authored.append(PaintAuthoredStroke(x: u + nx * across * 0.5, y: (skyline[i] + 0.5) / unitPx + ny * across * 0.5, angle: angle + Float(rng.next(-0.06, 0.06)),
                                           length: Float(rng.next(0.018, 0.034)), width: across * 1.15, color: colour, alpha: 0.92 * near, load: 1.1, thick: 0.25, round: 0.4,
                                           pick: SIMD2(nx * reachOut, ny * reachOut)))
        }
    }

    /// How strongly the structure of the picture itself bends strokes here, 0…1. (Skies shouldn't swirl.)
    @inline(__always) func setBendToForm(_ x: Int, _ y: Int, _ amount: Float) { formWeight.p[y * w + x] = amount }

    @inline(__always) func setDir(_ x: Int, _ y: Int, angle: Float, strength: Float = 1) {
        let i = (y * w + x) * 2
        dir.p[i] = cos(2 * angle) * strength
        dir.p[i + 1] = sin(2 * angle) * strength
    }
}

/// One brush mark, in canvas pixels.
nonisolated struct PaintStroke {
    var cx: Float, cy: Float, cosT: Float, sinT: Float
    var halfLen: Float, halfWid: Float, bend: Float
    var c0: PaintV3, c1: PaintV3, dirty: PaintV3
    var alpha: Float, load: Float, thick: Float
    var texU: Float, texV: Float, pitch: Float
    var dry: Float
    /// 0: blunt ends, 1: a rounded dab.
    var round: Float = 0
    /// How far its edges melt into the wet paint under it.
    var feather: Float = 0
    /// How much narrower the tail is than the belly, 0…1.
    var taper: Float = 0.25
    /// 0: a flat touch-down, 1: a soft rounded start.
    var tipIn: Float = 0.5
    /// 0: a blunt lift, 1: a long point.
    var tipOut: Float = 0.5
    /// How much bristle texture shows.
    var comb: Float = 1
    /// The shape this mark belongs to and may paint on; 255: anywhere.
    var level: UInt8 = 255
    /// Started on a firm shape: it stays on that shape, and never strays into a passage whose edges are left open.
    var firm = false
    /// Each mark meets a border in its own place, so a shape's edge is made of the ends of marks and never cut by one knife.
    var borderX: Int32 = 0
    var borderY: Int32 = 0
}

/// How many colours a brush carries across its width, at its start and at its end.
nonisolated let PaintStripWidth = 5

/// A tile of bristle marks: how much each bristle holds and which way its colour leans, varying slowly along the stroke.
nonisolated final class PaintBrushTex: @unchecked Sendable {
    static let sizeU = 512, sizeV = 256
    /// density, colour lean, height, per texel.
    let t: UnsafeMutablePointer<SIMD3<Float>>
    /// Where each column of bristles starts and stops, 0…1.
    let ends: UnsafeMutablePointer<SIMD2<Float>>

    init(seed: UInt64) {
        let su = PaintBrushTex.sizeU, sv = PaintBrushTex.sizeV
        t = .allocate(capacity: su * sv)
        ends = .allocate(capacity: su)
        let noise = PaintNoise(seed: seed)
        var rng = SplitMix64(seed: seed ^ 0xABCDEF)
        // Bristles are 2 texels wide; clumps of them lean together.
        let bristles = su / 2
        var base = [Float](repeating: 0, count: bristles)
        var lean = [Float](repeating: 0, count: bristles)
        var startEnd = [SIMD2<Float>](repeating: .zero, count: bristles)
        for i in 0..<bristles {
            let clump = Float(noise.value(Double(i) * 0.09, 3.3))
            let fine = Float(rng.next())
            base[i] = PaintSat(0.62 + 0.5 * clump + 0.5 * (fine - 0.5))
            lean[i] = Float(noise.value(Double(i) * 0.05, 7.7)) * 1.3 + (Float(rng.next()) - 0.5) * 0.7
            let stick = Float(noise.value(Double(i) * 0.17, 11.1))
            startEnd[i] = SIMD2(PaintSat(0.5 + 0.9 * stick + 0.4 * (Float(rng.next()) - 0.5)), PaintSat(0.5 - 0.8 * stick + 0.5 * (Float(rng.next()) - 0.5)))
        }
        let endsTable = ends
        let table = PaintV3sRef(p: t)
        let baseCopy = base, leanCopy = lean, startEndCopy = startEnd
        PaintPar(sv) { j in
            let along = Double(j) / Double(sv) * 6.28
            let cosAlong = cos(along), sinAlong = sin(along)
            var n: Float = 0
            for i in 0..<su {
                let fb = Float(i) * 0.5
                let b0 = Int(fb) % bristles, b1 = (b0 + 1) % bristles
                let f = fb - Float(Int(fb))
                // Tiling along the stroke: walk a circle through the noise.
                if i & 1 == 0 { n = Float(noise.fbm(Double(b0) * 0.61 + 3 * cosAlong, 3 * sinAlong + Double(b0 % 7) * 1.9, octaves: 2)) }
                let d = PaintSat(PaintLerp(baseCopy[b0], baseCopy[b1], f) + n * 0.6)
                let l = PaintLerp(leanCopy[b0], leanCopy[b1], f) + 0.45 * n
                let g = d
                table.p[j * su + i] = SIMD3(d, l, g)
            }
        }
        for i in 0..<su { endsTable[i] = startEndCopy[(i / 2) % bristles] }
    }

    deinit {
        t.deallocate()
        ends.deallocate()
    }
}

/// The canvas's tooth: 0…1, high on top of the threads, tiling.
nonisolated final class PaintToothTex: @unchecked Sendable {
    /// A power of two; no bigger than the picture can show.
    let size: Int
    let t: UnsafeMutablePointer<Float>
    let visible: Float

    init(unit: Int, seed: UInt64) {
        let s = unit < 420 ? 256 : 512
        size = s
        t = .allocate(capacity: s * s)
        let target = Float(unit) / 300
        // Below two and a half pixels per thread the weave can't be drawn, only noise can.
        visible = PaintSstep(1.5, 2.8, target)
        let threads = max(8, Int((Float(s) / max(1, target)).rounded()))
        let pitch = Float(s) / Float(threads)
        var rng = SplitMix64(seed: seed ^ 0x77FF)
        var warp = [Float](repeating: 0, count: threads), weft = warp
        for i in 0..<threads {
            warp[i] = 0.82 + 0.36 * Float(rng.next())
            weft[i] = 0.82 + 0.36 * Float(rng.next())
        }
        let noise = PaintNoise(seed: seed ^ 0x1357)
        let table = PaintFloatsRef(p: t), warpCopy = warp, weftCopy = weft, vis = visible
        PaintPar(s) { y in
            let fy = (Float(y) + 0.5) / pitch
            let iy = min(threads - 1, Int(fy))
            let ty = fy - Float(iy) - 0.5
            for x in 0..<s {
                let fx = (Float(x) + 0.5) / pitch
                let ix = min(threads - 1, Int(fx))
                let tx = fx - Float(ix) - 0.5
                // A plain weave: warp on top in one checker square, weft in the other, each a little bump.
                let over = (ix + iy) & 1 == 0
                let along = over ? ty : tx, across = over ? tx : ty
                let k = over ? warpCopy[ix] : weftCopy[iy]
                let bump = k * (1 - across * across * 3.2) * (0.72 + 0.28 * cos(along * .pi * 2))
                let grit = Float(noise.fbm(Double(x) * 0.11, Double(y) * 0.11, octaves: 4))
                table.p[y * s + x] = PaintSat(PaintLerp(0.5 + 0.6 * grit, PaintSat(bump * 0.62 + 0.25 + 0.75 * grit), vis))
            }
        }
    }

    deinit { t.deallocate() }
}

/// One pass of strokes of about one size. Sizes in units of the short side.
nonisolated struct PaintLayer {
    var width: Float
    var lenMin: Float, lenMax: Float
    /// Area painted, in multiples of the picture, if every place wanted this layer.
    var coverage: Float
    var alpha: Float
    /// How far a stroke may wander off the field's direction, radians.
    var wander: Float
    var value: Float
    /// How far apart two colours may be before a stroke stops at the change. Huge: it doesn't.
    var stop: Float
    var load: Float
    var thick: Float
    /// How `detail` and edges turn into the chance of a stroke here. Zero: always.
    var want: Float = 0
    var dirtyAmount: Float = 0.12
}

nonisolated enum PaintEngine {
    // Two broad layers everywhere; below them the brush only comes out where the study asks. Marks get longer as they get smaller,
    // relative to their width: a fine mark is a drawn line, never a dab.
    static let standardLayers: [PaintLayer] = [
        PaintLayer(width: 0.150, lenMin: 0.30, lenMax: 0.56, coverage: 3.0, alpha: 0.96, wander: 0.50, value: 0.012, stop: 9, load: 1.0, thick: 0.30),
        PaintLayer(width: 0.080, lenMin: 0.20, lenMax: 0.38, coverage: 3.0, alpha: 0.93, wander: 0.38, value: 0.015, stop: 0.42, load: 0.95, thick: 0.45),
        PaintLayer(width: 0.042, lenMin: 0.13, lenMax: 0.26, coverage: 3.2, alpha: 0.92, wander: 0.28, value: 0.015, stop: 0.42, load: 0.88, thick: 0.60, want: 0.03),
        PaintLayer(width: 0.022, lenMin: 0.090, lenMax: 0.17, coverage: 2.4, alpha: 0.92, wander: 0.22, value: 0.012, stop: 0.34, load: 0.86, thick: 0.75, want: 0.20),
        PaintLayer(width: 0.011, lenMin: 0.050, lenMax: 0.10, coverage: 1.3, alpha: 0.94, wander: 0.18, value: 0.010, stop: 0.26, load: 0.88, thick: 0.85, want: 0.54),
        PaintLayer(width: 0.0055, lenMin: 0.028, lenMax: 0.06, coverage: 0.6, alpha: 0.96, wander: 0.14, value: 0.008, stop: 0.20, load: 1.0, thick: 1.0, want: 0.78),
    ]

    /// Stepping back from the easel: what the painting lacks against the study, gone over at decreasing size.
    static let stepBackRounds: [PaintLayer] = [
        PaintLayer(width: 0.056, lenMin: 0.17, lenMax: 0.30, coverage: 1.5, alpha: 0.90, wander: 0.22, value: 0.010, stop: 0.30, load: 0.9, thick: 0.55),
        PaintLayer(width: 0.028, lenMin: 0.11, lenMax: 0.20, coverage: 1.4, alpha: 0.90, wander: 0.18, value: 0.010, stop: 0.22, load: 0.9, thick: 0.70),
        PaintLayer(width: 0.015, lenMin: 0.064, lenMax: 0.12, coverage: 0.8, alpha: 0.92, wander: 0.14, value: 0.009, stop: 0.16, load: 0.9, thick: 0.80),
    ]

    /// Paints `ref` `width`×`height` pixels.
    static func paint(ref: PaintSceneRef, width: Int, height: Int, seed: UInt64, layers: [PaintLayer] = standardLayers) -> CGImage? {
        let unit = Float(min(width, height))
        // Reference pixels per canvas pixel.
        let toRef = Float(ref.w) / Float(width)
        let field = PaintStrokeField(ref: ref)
        var rng = SplitMix64(seed: seed ^ 0xB5AD_4ECE_DA1C_E2A9)
        let canvasBytes = width * height * MemoryLayout<PaintCanvasPixel>.stride
        let canvas = PaintPages.take(canvasBytes).bindMemory(to: PaintCanvasPixel.self, capacity: width * height)
        defer { PaintPages.give(UnsafeMutableRawPointer(canvas), canvasBytes) }
        let brush = PaintBrushTex(seed: seed ^ 0xB12)
        let tooth = PaintToothTex(unit: Int(unit), seed: seed)
        let surface = PaintCanvasRef(p: canvas)
        layWash(field: field, ref: ref, width: width, height: height, unit: unit, seed: seed, surface: surface)
        let levels = PaintLevelMap(ref: ref, width: width, height: height, unit: unit, seed: seed)

        // Block-in: the two broad layers and the middle brush. These are what the eye rests on.
        var strokes: [PaintStroke] = []
        var strips: [PaintV3] = []
        strokes.reserveCapacity(20_000)
        strips.reserveCapacity(200_000)
        var layerIndex = 0
        for layer in layers where layer.width >= 0.04 {
            if layer.width * unit >= 1.4 {
                var deltas: [Float] = []
                buildLayer(layer, index: layerIndex, field: field, canvasW: width, canvasH: height, unit: unit, toRef: toRef, rng: &rng, into: &strokes, strips: &strips, deltas: &deltas)
            }
            layerIndex += 1
        }
        draw(strokes, strips, canvas: surface, width: width, height: height, brush: brush, tooth: tooth, levels: levels)
        strokes = []
        strips = []

        // The canvas as it stands, at half the study's size: the fine marks are judged against this, not against what was meant. Every
        // judgement is over a radius of several of the study's cells, so nothing is lost and the sums go four times as fast.
        let judgedW = max(1, ref.w / 2), judgedH = max(1, ref.h / 2)
        let judgedScale = Float(judgedW) / Float(ref.w)
        let canvasSmall = PaintBuf(w: judgedW, h: judgedH, c: 3)
        func readCanvas() {
            PaintPar(judgedH) { ry in
                let y0 = ry * height / judgedH, y1 = max(y0 + 1, (ry + 1) * height / judgedH)
                for rx in 0..<judgedW {
                    let x0 = rx * width / judgedW, x1 = max(x0 + 1, (rx + 1) * width / judgedW)
                    var sum = SIMD4<UInt32>.zero
                    var n: UInt32 = 0
                    for y in y0..<min(height, y1) {
                        let line = surface.p + y * width
                        for x in x0..<min(width, x1) {
                            sum &+= SIMD4<UInt32>(truncatingIfNeeded: line[x])
                            n &+= 1
                        }
                    }
                    canvasSmall.set3(rx, ry, PaintV3(Float(sum.x), Float(sum.y), Float(sum.z)) / (max(1, Float(n)) * PaintCanvas.colour))
                }
            }
        }
        readCanvas()
        /// A blur of `radius` of the study's cells, on the judged grid.
        @inline(__always) func judgedRadius(_ radius: Int) -> Int { max(1, radius / 2) }

        // Finer marks. Each one is checked against the paint around it; a stray that belongs to no shape is never laid.
        var fine: [PaintStroke] = []
        var fineStrips: [PaintV3] = []
        var fineDeltas: [Float] = []
        for layer in layers where layer.width < 0.04 {
            if layer.width * unit >= 1.4 {
                let gate = canvasSmall.blurred(judgedRadius(Int(layer.width * 1.5 * Float(ref.w))))
                buildLayer(layer, index: layerIndex, field: field, canvasW: width, canvasH: height, unit: unit, toRef: toRef, rng: &rng, into: &fine, strips: &fineStrips, deltas: &fineDeltas, gate: gate, gateScale: judgedScale)
            }
            layerIndex += 1
        }
        _ = pruneStrays(strokes: &fine, strips: &fineStrips, deltas: fineDeltas, unit: unit, dark: ref.dark)
        draw(fine, fineStrips, canvas: surface, width: width, height: height, brush: brush, tooth: tooth, levels: levels)
        fine = []
        fineStrips = []
        fineDeltas = []

        // Step back from the easel: wherever the painting has drifted from the study at a given size, go in again at that size.
        // Each round looks at the actual paint, so it mends what the strokes broke and leaves alone what already works.
        let tolerance: Float = ref.dark ? 0.020 : 0.040
        let studySmall = field.mips.count > 1 ? field.mips[1] : ref.rgb
        for (roundIndex, layer) in stepBackRounds.enumerated() where layer.width * unit >= 1.8 {
            readCanvas()
            let radius = judgedRadius(max(1, Int(layer.width * unit * Float(ref.w) / Float(width) * 0.42)))
            let lacking = studySmall.blurred(radius)
            do {
                let paintBlur = canvasSmall.blurred(radius)
                let cells = judgedW * judgedH * 3
                for i in 0..<cells { lacking.p[i] -= paintBlur.p[i] }
            }
            var extra: [PaintStroke] = []
            var extraStrips: [PaintV3] = []
            var extraDeltas: [Float] = []
            let gate = layer.width <= 0.03 ? canvasSmall.blurred(judgedRadius(Int(layer.width * 1.5 * Float(ref.w)))) : nil
            buildLayer(layer, index: 3 + roundIndex, field: field, canvasW: width, canvasH: height, unit: unit, toRef: toRef, rng: &rng, into: &extra, strips: &extraStrips, deltas: &extraDeltas, correction: lacking, tolerance: tolerance, gate: gate, gateScale: judgedScale)
            if layer.width <= 0.03 { _ = pruneStrays(strokes: &extra, strips: &extraStrips, deltas: extraDeltas, unit: unit, dark: ref.dark) }
            if extra.isEmpty { continue }
            draw(extra, extraStrips, canvas: surface, width: width, height: height, brush: brush, tooth: tooth, levels: levels)
        }
        var edgeMarks: [PaintStroke] = []
        var edgeStrips: [PaintV3] = []
        findEdges(field: field, width: width, height: height, unit: unit, toRef: toRef, rng: &rng, into: &edgeMarks, strips: &edgeStrips)
        draw(edgeMarks, edgeStrips, canvas: surface, width: width, height: height, brush: brush, tooth: tooth, levels: levels)
        edgeMarks = []
        edgeStrips = []

        // The shadow masses are melted together along their flow.
        wetBlend(field: field, ref: ref, width: width, height: height, unit: unit, surface: surface)

        // Marks and discs are placed in units of the picture's width, whichever way round it is.
        let placed = Float(width)
        // The sun or moon, per pixel: nothing else makes a clean round touch of paint with one edge found and the other lost.
        for disc in ref.discs {
            let cx = disc.x * placed, cy = disc.y * placed, radius = disc.r * placed
            let wobbleNoise = PaintNoise(seed: seed ^ 0xD15C)
            let reach = Int(radius * (1 + disc.softShade) + 3)
            let y0 = max(0, Int(cy) - reach), y1 = min(height - 1, Int(cy) + reach)
            if y0 > y1 { continue }
            let dirX = cos(disc.angle), dirY = sin(disc.angle)
            PaintPar(y1 - y0 + 1) { index in
                let y = y0 + index
                let row = surface.p + y * width
                for x in max(0, Int(cx) - reach)...min(width - 1, Int(cx) + reach) {
                    let dx = (Float(x) + 0.5 - cx) / radius, dy = (Float(y) + 0.5 - cy) / radius
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d > 1 + disc.softShade + 0.04 { continue }
                    let facing = d > 0.0001 ? (dx * dirX + dy * dirY) / d : 0
                    let edge = PaintLerp(disc.softShade, disc.softLit, PaintSstep(-0.5, 0.6, facing))
                    let wander = Float(wobbleNoise.fbm(Double(dx) * 2.2, Double(dy) * 2.2, octaves: 2)) * 0.022
                    let cover = PaintSstep(1 + edge * 0.5 + wander, 1 - edge * 0.5 + wander, d)
                    if cover <= 0 { continue }
                    // Bristle marks run across the touch, faintly.
                    let across = Double(dx * dirY - dy * dirX) * 16, along = Double(dx * dirX + dy * dirY) * 1.8
                    let bristle = Float(wobbleNoise.fbm(along + 9, across, octaves: 2)) * 0.022
                    let shadeAmount = PaintSstep(0.5, -0.7, (dx * dirX + dy * dirY))
                    let colour = PaintMix(disc.lit, disc.shade, shadeAmount) * (1 + bristle)
                    let old = PaintCanvas.colour(row[x])
                    let mixed = PaintMix(old, colour, cover)
                    row[x] = PaintCanvas.pixel(mixed, height: max(PaintCanvas.height(row[x]), cover * 0.35))
                }
            }
        }

        // Marks placed by hand go on last, over everything: the disc, the glints, the stars. Those that take their colour
        // off the canvas look now, once everything under them is there.
        var finalMarks: [PaintStroke] = []
        var finalStrips: [PaintV3] = []
        finalMarks.reserveCapacity(ref.authored.count)
        let pickRadius = max(1, Int(unit * 0.004))
        func grab(_ x: Float, _ y: Float) -> PaintV3 {
            let cx = min(width - 1, max(0, Int(x))), cy = min(height - 1, max(0, Int(y)))
            var sum = PaintV3.zero
            var n: Float = 0
            for yy in max(0, cy - pickRadius)...min(height - 1, cy + pickRadius) {
                let line = canvas + yy * width
                for xx in max(0, cx - pickRadius)...min(width - 1, cx + pickRadius) {
                    sum += PaintCanvas.colour(line[xx])
                    n += 1
                }
            }
            return sum / max(1, n)
        }
        for a in ref.authored {
            var s = authored(a, unit: unit, placed: placed, rng: &rng)
            var c0 = a.color, c1 = a.color2 ?? a.color
            if let pick = a.pick {
                let ox = pick.x * placed, oy = pick.y * placed
                c0 = grab(s.cx - s.cosT * s.halfLen + ox, s.cy - s.sinT * s.halfLen + oy) * a.pickTint
                c1 = grab(s.cx + s.cosT * s.halfLen + ox, s.cy + s.sinT * s.halfLen + oy) * a.pickTint
                s.c0 = c0
                s.c1 = c1
                s.dirty = (c0 + c1) * 0.5
            }
            finalMarks.append(s)
            for _ in 0..<PaintStripWidth { finalStrips.append(c0) }
            for _ in 0..<PaintStripWidth { finalStrips.append(c1) }
        }
        draw(finalMarks, finalStrips, canvas: surface, width: width, height: height, brush: brush, tooth: tooth, levels: levels)

        return finish(canvas: canvas, ref: ref, width: width, height: height, unit: unit, tooth: tooth, seed: seed)
    }

    private static func layWash(field: PaintStrokeField, ref: PaintSceneRef, width: Int, height: Int, unit: Float, seed: UInt64, surface: PaintCanvasRef) {
        let ground = ref.ground
        // A thin first wash over the toned canvas, so gaps between strokes show something related to the picture.
        let wash = field.mips[0]
        let washScale = Float(wash.w) / Float(width)
        let washMix: Float = 0.92
        // The ground's tone varies slowly: a coarse grid of it is all anyone can see through the wash.
        let groundNoise = PaintNoise(seed: seed ^ 0x6D)
        let gridStep: Float = max(4, unit / 64)
        let gridW = Int(Float(width) / gridStep) + 2, gridH = Int(Float(height) / gridStep) + 2
        let grid = PaintBuf(w: gridW, h: gridH)
        PaintPar(gridH) { gy in
            for gx in 0..<gridW {
                grid.p[gy * gridW + gx] = Float(groundNoise.value(Double(Float(gx) * gridStep / unit) * 5, Double(Float(gy) * gridStep / unit) * 5))
            }
        }
        PaintPar(height) { y in
            let row = surface.p + y * width
            let fy = Float(y) / gridStep
            let iy = min(gridH - 2, Int(fy)), ty = fy - Float(iy)
            for x in 0..<width {
                let fx = Float(x) / gridStep
                let ix = min(gridW - 2, Int(fx)), tx = fx - Float(ix)
                let n = PaintLerp(PaintLerp(grid.at(ix, iy), grid.at(ix + 1, iy), tx), PaintLerp(grid.at(ix, iy + 1), grid.at(ix + 1, iy + 1), tx), ty)
                let c = PaintMix(ground + PaintV3(0.05, 0.04, 0.03) * n, wash.sample3((Float(x) + 0.5) * washScale, (Float(y) + 0.5) * washScale), washMix)
                row[x] = PaintCanvas.pixel(c, height: 0)
            }
        }
    }

    /// Lays `strokes` in order. Bands of rows run in parallel: a pixel depends only on the strokes crossing it, in order.
    private static func draw(_ strokes: [PaintStroke], _ strips: [PaintV3], canvas: PaintCanvasRef, width: Int, height: Int, brush: PaintBrushTex, tooth: PaintToothTex, levels: PaintLevelMap) {
        if strokes.isEmpty { return }
        let bandHeight = max(8, height / 96)
        let bands = height / bandHeight + 1
        var buckets = [[Int32]](repeating: [], count: bands)
        for (i, s) in strokes.enumerated() {
            let reachY = abs(s.sinT) * s.halfLen + abs(s.cosT) * (s.halfWid + abs(s.bend)) + 2
            let y0 = max(0, Int(s.cy - reachY)), y1 = min(height - 1, Int(s.cy + reachY))
            if y1 < y0 { continue }
            for b in (y0 / bandHeight)...(y1 / bandHeight) { buckets[b].append(Int32(i)) }
        }
        let bucketCopy = buckets
        strokes.withUnsafeBufferPointer { strokeBuffer in
            strips.withUnsafeBufferPointer { stripBuffer in
                let list = PaintStrokesRef(p: strokeBuffer.baseAddress!)
                let colours = PaintColoursRef(p: stripBuffer.baseAddress!)
                PaintPar(bands) { b in
                    let y0 = b * bandHeight, y1 = min(height, (b + 1) * bandHeight)
                    guard y0 < y1 else { return }
                    for index in bucketCopy[b] {
                        drawStroke(list.p[Int(index)], strip: colours.p + Int(index) * PaintStripWidth * 2, y0: y0, y1: y1, width: width, height: height, canvas: canvas.p, brush: brush, tooth: tooth, levels: levels)
                    }
                }
            }
        }
    }

    /// A light or dark mark must belong to something: a same-signed mark within one stroke length. Those that don't are never painted.
    /// `deltas`: stroke value minus the value of the paint around it.
    private static func pruneStrays(strokes: inout [PaintStroke], strips: inout [PaintV3], deltas: [Float], unit: Float, dark: Bool) -> Int {
        guard !strokes.isEmpty else { return 0 }
        let notable: Float = dark ? 0.030 : 0.060
        let cell = max(8, unit * 0.05)
        var grid: [Int64: [Int32]] = [:]
        @inline(__always) func key(_ x: Float, _ y: Float) -> Int64 { Int64(x / cell) &* 65536 &+ Int64(y / cell) }
        for (i, d) in deltas.enumerated() where abs(d) > notable * 0.6 {
            grid[key(strokes[i].cx, strokes[i].cy), default: []].append(Int32(i))
        }
        var keep = [Bool](repeating: true, count: strokes.count)
        var dropped = 0
        for i in strokes.indices where abs(deltas[i]) > notable {
            let s = strokes[i]
            let reach = s.halfLen * 2.0 + s.halfWid
            let span = Int(reach / cell) + 1
            let gx = Int64(s.cx / cell), gy = Int64(s.cy / cell)
            var friends = 0
            search: for ox in -Int64(span)...Int64(span) {
                for oy in -Int64(span)...Int64(span) {
                    guard let list = grid[(gx + ox) &* 65536 &+ (gy + oy)] else { continue }
                    for j in list where Int(j) != i && deltas[Int(j)] * deltas[i] > 0 {
                        let o = strokes[Int(j)]
                        let dx = o.cx - s.cx, dy = o.cy - s.cy
                        if dx * dx + dy * dy < reach * reach {
                            friends += 1
                            if friends >= 2 { break search }
                        }
                    }
                }
            }
            if friends < 2 {
                keep[i] = false
                dropped += 1
            }
        }
        if dropped == 0 { return 0 }
        var outS: [PaintStroke] = []
        var outC: [PaintV3] = []
        outS.reserveCapacity(strokes.count - dropped)
        outC.reserveCapacity((strokes.count - dropped) * PaintStripWidth * 2)
        for i in strokes.indices where keep[i] {
            outS.append(strokes[i])
            outC.append(contentsOf: strips[(i * PaintStripWidth * 2)..<((i + 1) * PaintStripWidth * 2)])
        }
        strokes = outS
        strips = outC
        return dropped
    }

    /// Drags wet paint along the flow where the scene says, and knocks its thickness back: passages with no marks to read.
    private static func wetBlend(field: PaintStrokeField, ref: PaintSceneRef, width: Int, height: Int, unit: Float, surface: PaintCanvasRef) {
        let copyBytes = width * height * MemoryLayout<PaintCanvasPixel>.stride
        let copy = PaintPages.take(copyBytes).bindMemory(to: PaintCanvasPixel.self, capacity: width * height)
        defer { PaintPages.give(UnsafeMutableRawPointer(copy), copyBytes) }
        memcpy(copy, surface.p, copyBytes)
        let source = PaintCanvasRef(p: copy)
        let toRef = Float(ref.w) / Float(width)
        let reach = max(1.0, unit * 0.0052)
        let blendBuf = ref.blend
        let taps = 5
        PaintPar(height) { y in
            let row = surface.p + y * width
            for x in 0..<width {
                let rx = (Float(x) + 0.5) * toRef, ry = (Float(y) + 0.5) * toRef
                let m = blendBuf.sample(rx, ry)
                if m < 0.02 { continue }
                let angle = field.angle(rx, ry)
                let dx = cos(angle) * reach * m, dy = sin(angle) * reach * m
                var sum = SIMD4<UInt32>.zero
                for k in -taps...taps {
                    let t = Float(k) / Float(taps)
                    // Bent along a stroke's length, so it doesn't read as a linear blur.
                    let sx = min(width - 1, max(0, Int(Float(x) + dx * t + 0.5))), sy = min(height - 1, max(0, Int(Float(y) + dy * t + 0.5)))
                    sum &+= SIMD4<UInt32>(truncatingIfNeeded: source.p[sy * width + sx])
                }
                let taken = 1 / Float(2 * taps + 1)
                let old = row[x]
                let oldColour = SIMD3(Float(old.x), Float(old.y), Float(old.z))
                let colour = oldColour + (SIMD3(Float(sum.x), Float(sum.y), Float(sum.z)) * taken - oldColour) * min(1, m * 1.5)
                let thick = PaintLerp(Float(old.w), Float(sum.w) * taken * 0.5, m)
                row[x] = SIMD4(UInt16(max(0, min(65535, colour.x + 0.5))), UInt16(max(0, min(65535, colour.y + 0.5))), UInt16(max(0, min(65535, colour.z + 0.5))), UInt16(max(0, min(65535, thick + 0.5))))
            }
        }
    }

    private static func authored(_ a: PaintAuthoredStroke, unit: Float, placed: Float, rng: inout SplitMix64) -> PaintStroke {
        let unit = placed
        let w = a.width * unit
        // A mark too small for the pixels here dims rather than growing: at a tile's size a star stays a star.
        let fit = min(1, w / 1.4) * min(1, a.length * unit / 1.4)
        return PaintStroke(cx: a.x * unit, cy: a.y * unit, cosT: cos(a.angle), sinT: sin(a.angle), halfLen: max(0.8, a.length * unit * 0.5), halfWid: max(0.7, w * 0.5),
                           bend: a.bend * unit, c0: a.color, c1: a.color2 ?? a.color, dirty: a.color, alpha: a.alpha * fit, load: a.load, thick: a.thick,
                           texU: Float(rng.next()) * 4096, texV: Float(rng.next()) * 4096, pitch: max(0.9, w * 0.05), dry: 0.5, round: a.round, feather: a.feather,
                           taper: a.taper, tipIn: a.tipIn, tipOut: a.tipOut, comb: a.comb)
    }

    /// `correction`: what the canvas still lacks against the reference at this size (signed colour), when stepping back to fix it.
    /// `gate`: the blurred canvas this mark is judged against; a mark that jumps too far from it without an edge to justify it isn't made.
    private static func buildLayer(_ layer: PaintLayer, index: Int, field: PaintStrokeField, canvasW: Int, canvasH: Int, unit: Float, toRef: Float,
                                   rng: inout SplitMix64, into strokes: inout [PaintStroke], strips: inout [PaintV3], deltas: inout [Float],
                                   correction: PaintBuf? = nil, tolerance: Float = 0, gate: PaintBuf? = nil, gateScale: Float = 1) {
        let w = layer.width * unit
        let meanLen = (layer.lenMin + layer.lenMax) * 0.5 * unit
        let spacing = sqrt(w * meanLen / layer.coverage)
        let cols = Int((Float(canvasW) + 2 * w) / spacing) + 1, rows = Int((Float(canvasH) + 2 * w) / spacing) + 1
        var order = [Int32](repeating: 0, count: cols * rows)
        for i in order.indices { order[i] = Int32(i) }
        // A shuffle so that no stroke knows it's in a grid; deterministic.
        if order.count > 1 {
            for i in stride(from: order.count - 1, to: 0, by: -1) {
                let j = Int(rng.nextUInt64() % UInt64(i + 1))
                order.swapAt(i, j)
            }
        }
        let ref = field.ref
        let mipLevel = max(0, min(field.mips.count - 1, Int((log2(max(1, w * toRef * 0.55))).rounded())))
        let mip = field.mips[mipLevel], mipScale = Float(mip.w) / Float(ref.w)
        let sharpLevel = max(0, min(2, mipLevel - 1)), sharp = field.mips[sharpLevel], sharpScale = Float(sharp.w) / Float(ref.w)
        // How long a mark must be against its width before it's a mark and not a chip.
        let minAspect: Float = index == 0 ? 1.5 : (layer.width <= 0.03 ? 4 : 3)
        let gateTolerance: Float = ref.dark ? 0.060 : 0.120
        for cell in order {
            let gx = Int(cell) % cols, gy = Int(cell) / cols
            let px = (Float(gx) + Float(rng.next())) * spacing - w, py = (Float(gy) + Float(rng.next())) * spacing - w
            let rx = px * toRef, ry = py * toRef
            let cxr = min(Float(ref.w) - 0.5, max(0.5, rx)), cyr = min(Float(ref.h) - 0.5, max(0.5, ry))
            let detail = ref.detail.sample(cxr, cyr)
            var lacking = PaintV3.zero
            let mirrored = ref.pullDown.sample(cxr, cyr) > 0.5
            if let correction {
                // Still water is only ever corrected with the broad brush, or it plaids.
                if mirrored && layer.width < 0.04 { continue }
                lacking = correction.sample3(cxr * gateScale, cyr * gateScale)
                let softHere = ref.soft.sample(cxr, cyr)
                let allow = tolerance * (1 + softHere * 3.2)
                var p = PaintSstep(allow * 0.7, allow * 1.5, PaintLength(lacking))
                // Only the broadest correction goes into a passage meant to stay loose: small ones there read as flecks.
                if index > 3 { p *= PaintSstep(0.85, 0.6, softHere) }
                if index > 4 { p *= PaintSstep(0.12, 0.34, detail) }
                if Float(rng.next()) > p { continue }
            } else if layer.want > 0 {
                let edge = field.edge.sample(cxr, cyr)
                // A lost edge invites no fuss: where the scene says soft, edges don't call for small marks.
                let softHere = ref.soft.sample(cxr, cyr)
                let wantHere = max(detail, 0) * 0.86 + edge * 0.34 * (1 - softHere)
                let p = PaintSstep(layer.want - 0.16, layer.want + 0.16, wantHere)
                if Float(rng.next()) > p { continue }
            }
            let soft = ref.soft.sample(cxr, cyr)
            let seedLevel = ref.level.at(min(ref.w - 1, Int(cxr)), min(ref.h - 1, Int(cyr)))
            // Colour only from this shape: a brush doesn't pick up the sky when it's painting the mountain.
            let radiusRef = max(1, w * toRef * 0.5)
            var gathered = PaintV3.zero
            var gatheredN: Float = 0
            for k in 0..<16 {
                let sx = cxr + field.discX[k] * radiusRef, sy = cyr + field.discY[k] * radiusRef
                let ix = Int(sx), iy = Int(sy)
                if ix < 0 || iy < 0 || ix >= ref.w || iy >= ref.h { continue }
                if ref.level.at(ix, iy) != seedLevel { continue }
                gathered += ref.rgb.get3(ix, iy)
                gatheredN += 1
            }
            let own = gatheredN > 0 ? gathered / gatheredN : ref.rgb.sample3(cxr, cyr)
            let start = sharp.sample3(cxr * sharpScale, cyr * sharpScale)
            // Trace along the field both ways, stopping at a found edge.
            let shapeLength = ref.shape.sample(cxr, cyr, 0), shapeWidth = ref.shape.sample(cxr, cyr, 1)
            let pulled = layer.width >= 0.04 && mirrored
            let lenScale = pulled ? 1 : shapeLength
            var widScale = pulled ? 1 : shapeWidth
            let len = (layer.lenMin + Float(rng.next()) * (layer.lenMax - layer.lenMin)) * unit * lenScale
            let stop = (layer.stop + soft * layer.stop * 2.2) * (ref.dark ? 0.46 : 1)
            // Where the study says the brush doesn't follow any form, the mark is a straight pull at exactly the angle asked for here,
            // whatever the neighbouring shapes are doing: no swirl around a mountain in the sky, no curl where a reflection meets the water.
            let cellX = min(ref.w - 1, Int(cxr)), cellY = min(ref.h - 1, Int(cyr))
            let rigid = ref.formWeight.at(cellX, cellY) < 0.08
            let dirAt = (cellY * ref.w + cellX) * 2
            let fieldAngle = pulled ? Float.pi / 2 : (rigid ? 0.5 * atan2(ref.dir.p[dirAt + 1], ref.dir.p[dirAt]) : field.angle(cxr, cyr))
            let base = fieldAngle + (Float(rng.next()) - 0.5) * 2 * (pulled ? 0.08 : layer.wander) * ref.steady.sample(cxr, cyr)
            let wanderBias = base - fieldAngle
            let steps = 5
            let stepLen = len * 0.5 / Float(steps)
            // A sky isn't painted around a mountain: the brush carries on behind it and only paints where it's sky.
            // Only a passage that's soft where the mark actually starts: a tree beside the mist doesn't drag itself across it.
            let passesBehind = ref.soft.at(cellX, cellY) > 0.7
            @inline(__always) func levelAt(_ x: Float, _ y: Float) -> Float {
                let ix = Int(x * toRef), iy = Int(y * toRef)
                if ix < 0 || iy < 0 || ix >= ref.w || iy >= ref.h { return seedLevel }
                return ref.level.at(ix, iy)
            }
            @inline(__always) func trace(_ first: Float, _ followEdge: Bool) -> (Float, Float, Float, Float) {
                var ax = px, ay = py, bx = px, by = py
                var dax = cos(first), day = sin(first)
                var dbx = -dax, dby = -day
                for _ in 0..<steps {
                    let nx = ax + dax * stepLen, ny = ay + day * stepLen
                    if levelAt(nx, ny) != seedLevel {
                        if !passesBehind { break }
                    } else if PaintLength(sharp.sample3(nx * toRef * sharpScale, ny * toRef * sharpScale) - start) > stop {
                        break
                    }
                    ax = nx
                    ay = ny
                    if rigid && !followEdge { continue }
                    let t = pulled ? Float.pi / 2 : (followEdge ? field.edgeAngle(nx * toRef, ny * toRef) : field.angle(nx * toRef, ny * toRef) + wanderBias)
                    var ndx = cos(t), ndy = sin(t)
                    if ndx * dax + ndy * day < 0 {
                        ndx = -ndx
                        ndy = -ndy
                    }
                    dax = ndx
                    day = ndy
                }
                for _ in 0..<steps {
                    let nx = bx + dbx * stepLen, ny = by + dby * stepLen
                    if levelAt(nx, ny) != seedLevel {
                        if !passesBehind { break }
                    } else if PaintLength(sharp.sample3(nx * toRef * sharpScale, ny * toRef * sharpScale) - start) > stop {
                        break
                    }
                    bx = nx
                    by = ny
                    if rigid && !followEdge { continue }
                    let t = pulled ? Float.pi / 2 : (followEdge ? field.edgeAngle(nx * toRef, ny * toRef) : field.angle(nx * toRef, ny * toRef) + wanderBias)
                    var ndx = cos(t), ndy = sin(t)
                    if ndx * dbx + ndy * dby < 0 {
                        ndx = -ndx
                        ndy = -ndy
                    }
                    dbx = ndx
                    dby = ndy
                }
                return (ax, ay, bx, by)
            }
            var (ax, ay, bx, by) = trace(base, false)
            var chordX = ax - bx, chordY = ay - by
            var chord = sqrt(chordX * chordX + chordY * chordY)
            let wantMin = w * widScale * minAspect
            if chord < wantMin && !passesBehind && ref.formWeight.sample(cxr, cyr) > 0.15 {
                // Boxed in across an edge: try lying along the edge instead.
                let along = field.edgeAngle(cxr, cyr)
                let (a2x, a2y, b2x, b2y) = trace(along, true)
                let cx2 = a2x - b2x, cy2 = a2y - b2y
                let chord2 = sqrt(cx2 * cx2 + cy2 * cy2)
                if chord2 > chord {
                    ax = a2x
                    ay = a2y
                    bx = b2x
                    by = b2y
                    chordX = cx2
                    chordY = cy2
                    chord = chord2
                }
            }
            if chord < wantMin {
                // Still boxed in: a smaller brush, or none. A stub is never drawn.
                let fits = chord / (w * minAspect)
                if fits < 0.42 {
                    if index > 0 { continue }
                    let mx = (ax + bx) * 0.5, my = (ay + by) * 0.5, cc = cos(base), ss = sin(base)
                    ax = mx + cc * wantMin * 0.5
                    ay = my + ss * wantMin * 0.5
                    bx = mx - cc * wantMin * 0.5
                    by = my - ss * wantMin * 0.5
                    chordX = ax - bx
                    chordY = ay - by
                    chord = wantMin
                } else {
                    widScale = min(widScale, fits)
                }
            }
            // Painters work from one side: most strokes run one way along a line, not at random.
            var fromX = bx, fromY = by
            if (chordY < 0) != (Float(rng.next()) < 0.2) {
                fromX = ax
                fromY = ay
                chordX = -chordX
                chordY = -chordY
            }
            let ct = chordX / chord, st = chordY / chord
            var mx = (ax + bx) * 0.5, my = (ay + by) * 0.5
            // The wrist turns a little over a long stroke; a short one is straight, or it reads as a worm.
            let bendCap = chord * PaintLerp(0.05, 0.20, PaintSstep(2.5, 7, chord / w)) * (rigid ? 0.3 : 1)
            let bend = max(-bendCap, min(bendCap, -(px - mx) * st + (py - my) * ct))
            // Colour: what the reference holds at this size, from the same side of any edge as the stroke's centre.
            let mcx = cxr * mipScale, mcy = cyr * mipScale
            let bestColor = own
            // The two ends of the mark, within the shape if they fall inside it.
            @inline(__always) func endColour(_ x: Float, _ y: Float) -> PaintV3 {
                let ex = x * toRef, ey = y * toRef
                let ix = Int(ex), iy = Int(ey)
                if ix >= 0, iy >= 0, ix < ref.w, iy < ref.h, ref.level.at(ix, iy) == seedLevel {
                    return ref.rgb.sample3(ex, ey)
                }
                return own
            }
            let endA = endColour(fromX, fromY)
            let endB = endColour(fromX + chordX, fromY + chordY)
            // Broken colour: paint on the brush from nearby, and a little personal drift in value and temperature.
            // Loose passages stay quiet: the variety goes where the eye is meant to stop.
            let quiet = PaintLerp(1, 0.6, PaintSstep(0.5, 0.9, soft))
            let tone = PaintLum(bestColor)
            // Drift in proportion to the paint's own value: on a near-black the same warm nudge shows as a brown patch.
            let toneScale = ref.dark ? PaintSat(tone * 2.6) * 0.75 + 0.05 : PaintSat(tone * 1.5 + 0.25)
            let vJit = (Float(rng.next()) - 0.5) * 2 * layer.value * 2.4 * ref.breakup * quiet * toneScale
            let tJit = (Float(rng.next()) - 0.5) * 2 * layer.value * 1.5 * ref.breakup * quiet * toneScale
            let warmth = field.warmth.sample(cxr * Float(field.warmth.w) / Float(ref.w), cyr * Float(field.warmth.h) / Float(ref.h))
            let steadyHere = ref.steady.sample(cxr, cyr)
            // Still water takes no temperature drift at all.
            let drift = warmth * toneScale * PaintSat(steadyHere * 2.5)
            let shift = PaintV3(vJit + tJit + drift * 0.018, vJit, vJit - tJit - drift * 0.022)
            // Stepping back: a correcting stroke leans a little past the colour, the way you'd knock back a passage gone wrong.
            let lean = lacking * 0.35
            let c0 = PaintMix(bestColor, endA, 0.45) + shift + lean
            let c1 = PaintMix(bestColor, endB, 0.45) + shift + lean
            // The eye reads a small mark against what's around it: one that jumps out with no edge to explain it is confetti.
            var delta: Float = 0
            if let gate {
                let around = PaintLum(gate.sample3(cxr * gateScale, cyr * gateScale))
                delta = PaintLum((c0 + c1) * 0.5) - around
                if abs(delta) > gateTolerance {
                    let edgeHere = field.edgeFine.sample(cxr, cyr)
                    if edgeHere < 0.32 { continue }
                }
            }
            let dirtyDist = Float(0.05 + 0.13 * rng.next()) * unit * toRef * mipScale
            let dirtyAngle = Float(rng.next()) * 6.283
            let dirty = mip.sample3(mcx + cos(dirtyAngle) * dirtyDist, mcy + sin(dirtyAngle) * dirtyDist)
            var widthHere = w * widScale * (0.78 + 0.44 * Float(rng.next()))
            // A brush stays inside its shape: where its width would cross a found edge it turns edge-on and moves in off it.
            let guarded = soft < 0.7 && index >= 2
            if guarded {
                let sideX = -st, sideY = ct
                let sideScale = toRef * sharpScale
                var shift: Float = 0
                for _ in 0..<3 {
                    let reach = widthHere * 0.5
                    let l = sharp.sample3((mx + sideX * (shift + reach)) * sideScale, (my + sideY * (shift + reach)) * sideScale)
                    let r = sharp.sample3((mx + sideX * (shift - reach)) * sideScale, (my + sideY * (shift - reach)) * sideScale)
                    let crossesL = PaintLength(l - start) > stop * 1.3, crossesR = PaintLength(r - start) > stop * 1.3
                    if !crossesL && !crossesR { break }
                    if crossesL != crossesR { shift += (crossesL ? -1 : 1) * reach * 0.45 }
                    widthHere *= 0.70
                }
                mx += sideX * shift
                my += sideY * shift
                fromX += sideX * shift
                fromY += sideY * shift
            }
            // A sliver isn't a mark either.
            if chord < widthHere * 1.2 { continue }
            let load = layer.load * (0.86 + 0.28 * Float(rng.next()))
            let mixedDirty = PaintMix(c0, dirty, layer.dirtyAmount * 3 * steadyHere)
            // The brush carries what it passed: colours across its width, from the start of the mark and from its end.
            let acrossX = -st, acrossY = ct
            let keep = PaintLerp(0.62, 0.86, Float(index) / 5)
            for k in 0..<PaintStripWidth {
                let off = (Float(k) / Float(PaintStripWidth - 1) - 0.5) * widthHere * 0.95
                let sample = ref.rgb.sample3((fromX + acrossX * off) * toRef, (fromY + acrossY * off) * toRef)
                let sx0 = (fromX + acrossX * off) * toRef, sy0 = (fromY + acrossY * off) * toRef
                let same0 = Int(sx0) >= 0 && Int(sy0) >= 0 && Int(sx0) < ref.w && Int(sy0) < ref.h && ref.level.at(Int(sx0), Int(sy0)) == seedLevel
                strips.append((guarded && PaintLength(sample - start) > stop) || !same0 ? c0 : PaintMix(c0, sample + shift + lean, keep))
            }
            for k in 0..<PaintStripWidth {
                let off = (Float(k) / Float(PaintStripWidth - 1) - 0.5) * widthHere * 0.95
                let sample = ref.rgb.sample3((fromX + chordX + acrossX * off) * toRef, (fromY + chordY + acrossY * off) * toRef)
                let sx1 = (fromX + chordX + acrossX * off) * toRef, sy1 = (fromY + chordY + acrossY * off) * toRef
                let same1 = Int(sx1) >= 0 && Int(sy1) >= 0 && Int(sx1) < ref.w && Int(sy1) < ref.h && ref.level.at(Int(sx1), Int(sy1)) == seedLevel
                strips.append((guarded && PaintLength(sample - start) > stop) || !same1 ? c1 : PaintMix(c1, sample + shift + lean, keep))
            }
            let wetHere = ref.wet.sample(cxr, cyr)
            strokes.append(PaintStroke(cx: mx, cy: my, cosT: ct, sinT: st, halfLen: chord * 0.5 + widthHere * 0.12, halfWid: widthHere * 0.5,
                                       bend: bend, c0: c0, c1: c1, dirty: mixedDirty,
                                       alpha: layer.alpha * (1 - 0.22 * wetHere), load: load, thick: layer.thick * (0.8 + 0.4 * Float(rng.next())) * PaintLerp(0.62, 1.22, PaintSat(PaintLum(c0) * 1.25)),
                                       texU: Float(rng.next()) * 4096, texV: Float(rng.next()) * 4096,
                                       pitch: max(0.9, widthHere * 0.028), dry: 0.55 + 0.45 * Float(rng.next()),
                                       round: steadyHere < 0.3 ? 0.6 : PaintSat(2.6 - (chord / widthHere) * 0.50) * 0.7,
                                       feather: wetHere,
                                       taper: Float(rng.next(0.15, 0.55)), tipIn: Float(rng.next(0.2, 1.0)), tipOut: Float(rng.next(0.25, 1.0)),
                                       comb: ref.comb.sample(cxr, cyr), level: UInt8(max(0, min(254, seedLevel))), firm: ref.soft.at(cellX, cellY) < 0.3,
                                       borderX: Int32(Float(rng.next(-1, 1)) * min(w * 0.05, unit * 0.0018)), borderY: Int32(Float(rng.next(-1, 1)) * min(w * 0.05, unit * 0.0018))))
            deltas.append(delta)
        }
    }

    /// The last thing before the hand-placed marks: thin strokes laid along the edges in the focal passages, each in the colour of
    /// the side it starts on, so a plane change that the broad work blurred is found again. Nothing else in the picture sharpens.
    private static func findEdges(field: PaintStrokeField, width: Int, height: Int, unit: Float, toRef: Float, rng: inout SplitMix64, into strokes: inout [PaintStroke], strips: inout [PaintV3]) {
        let ref = field.ref
        // Two sizes: a planted line, and a finer one where the edge is sharpest. Sizes in units of the short side.
        let passes: [(width: Float, length: Float, threshold: Float)] = [(0.0090, 0.090, 0.30), (0.0050, 0.060, 0.46)]
        let colour = field.mips[0]
        for pass in passes {
            let w = max(1.5, pass.width * unit)
            if pass.width * unit < 1.8 { continue }
            let spacing = max(2.5, w * 1.1)
            let cols = Int(Float(width) / spacing) + 1, rows = Int(Float(height) / spacing) + 1
            var order = [Int32](repeating: 0, count: cols * rows)
            for i in order.indices { order[i] = Int32(i) }
            if order.count > 1 {
                for i in stride(from: order.count - 1, to: 0, by: -1) {
                    let j = Int(rng.nextUInt64() % UInt64(i + 1))
                    order.swapAt(i, j)
                }
            }
            let stop: Float = ref.dark ? 0.05 : 0.10
            for cell in order {
                let gx = Int(cell) % cols, gy = Int(cell) / cols
                let px = (Float(gx) + Float(rng.next())) * spacing, py = (Float(gy) + Float(rng.next())) * spacing
                let cxr = min(Float(ref.w) - 0.5, max(0.5, px * toRef)), cyr = min(Float(ref.h) - 0.5, max(0.5, py * toRef))
                let focus = ref.focus.sample(cxr, cyr)
                if focus < 0.02 { continue }
                let sharpness = field.edgeFine.sample(cxr, cyr)
                let p = focus * PaintSstep(pass.threshold * 0.6, pass.threshold * 1.4, sharpness) * 0.45
                if Float(rng.next()) > p { continue }
                let start = colour.sample3(cxr, cyr)
                let seedLevel = ref.level.at(min(ref.w - 1, Int(cxr)), min(ref.h - 1, Int(cyr)))
                let length = pass.length * unit * Float(rng.next(0.7, 1.3))
                let stepLen = length * 0.5 / 5
                // Walk along the edge both ways, staying on this side of it.
                var ax = px, ay = py, bx = px, by = py
                let first = field.edgeAngle(cxr, cyr)
                var dax = cos(first), day = sin(first)
                var dbx = -dax, dby = -day
                for _ in 0..<5 {
                    let nx = ax + dax * stepLen, ny = ay + day * stepLen
                    if PaintLength(colour.sample3(nx * toRef, ny * toRef) - start) > stop { break }
                    ax = nx
                    ay = ny
                    let t = field.edgeAngle(nx * toRef, ny * toRef)
                    var tx = cos(t), ty = sin(t)
                    if tx * dax + ty * day < 0 {
                        tx = -tx
                        ty = -ty
                    }
                    dax = tx
                    day = ty
                }
                for _ in 0..<5 {
                    let nx = bx + dbx * stepLen, ny = by + dby * stepLen
                    if PaintLength(colour.sample3(nx * toRef, ny * toRef) - start) > stop { break }
                    bx = nx
                    by = ny
                    let t = field.edgeAngle(nx * toRef, ny * toRef)
                    var tx = cos(t), ty = sin(t)
                    if tx * dbx + ty * dby < 0 {
                        tx = -tx
                        ty = -ty
                    }
                    dbx = tx
                    dby = ty
                }
                var chordX = ax - bx, chordY = ay - by
                let chord = (chordX * chordX + chordY * chordY).squareRoot()
                // A found edge is a drawn line, or nothing.
                if chord < w * 5 { continue }
                chordX /= chord
                chordY /= chord
                let mx = (ax + bx) * 0.5, my = (ay + by) * 0.5
                let bend = max(-0.14 * chord, min(0.14 * chord, -(px - mx) * chordY + (py - my) * chordX))
                let endA = colour.sample3(bx * toRef, by * toRef), endB = colour.sample3(ax * toRef, ay * toRef)
                let toneScale = PaintSat(PaintLum(start) * 1.6)
                let jitter = (Float(rng.next()) - 0.5) * 0.016 * toneScale
                let c0 = PaintMix(start, endA, 0.4) + PaintV3(repeating: jitter), c1 = PaintMix(start, endB, 0.4) + PaintV3(repeating: jitter)
                let wide = w * Float(rng.next(0.8, 1.15))
                for _ in 0..<PaintStripWidth { strips.append(c0) }
                for _ in 0..<PaintStripWidth { strips.append(c1) }
                strokes.append(PaintStroke(cx: mx, cy: my, cosT: chordX, sinT: chordY, halfLen: chord * 0.5, halfWid: wide * 0.5, bend: bend, c0: c0, c1: c1, dirty: c0,
                                           alpha: 0.90, load: Float(rng.next(0.95, 1.2)), thick: 0.9 * PaintLerp(0.6, 1.25, PaintLum(c0)),
                                           texU: Float(rng.next()) * 4096, texV: Float(rng.next()) * 4096, pitch: max(0.9, wide * 0.05), dry: Float(rng.next(0.3, 0.7)), round: 0.25,
                                           taper: Float(rng.next(0.25, 0.6)), tipIn: Float(rng.next(0.4, 1.0)), tipOut: Float(rng.next(0.5, 1.0)), level: UInt8(max(0, min(254, seedLevel))), firm: ref.soft.sample(cxr, cyr) < 0.3))
            }
        }
    }

    /// The hot loop: one stroke over rows `y0..<y1`.
    @inline(__always)
    private static func drawStroke(_ s: PaintStroke, strip: UnsafePointer<PaintV3>, y0: Int, y1: Int, width: Int, height: Int, canvas: UnsafeMutablePointer<PaintCanvasPixel>, brush: PaintBrushTex, tooth: PaintToothTex, levels: PaintLevelMap) {
        let reachA = s.halfLen + 1.5, reachB = s.halfWid + abs(s.bend) + 1.5
        let c = s.cosT, n = s.sinT
        let reachY = abs(n) * reachA + abs(c) * reachB
        let rowStart = max(y0, Int(s.cy - reachY)), rowEnd = min(y1 - 1, Int(s.cy + reachY) + 1)
        guard rowStart <= rowEnd else { return }
        let toothSize = tooth.size, toothMask = toothSize - 1
        let su = PaintBrushTex.sizeU, sv = PaintBrushTex.sizeV
        let invLen = 1 / s.halfLen
        let invPitch = 1 / s.pitch
        let invPitchV = invPitch * 0.06 * Float(sv) / 16
        let texture = brush.t, ends = brush.ends, teeth = tooth.t
        let lean = s.dirty - (s.c0 + s.c1) * 0.5
        // Warm and cool in the bristles in proportion to the paint's own value: on near-black it would read as brown.
        let warmLean = PaintV3(0.018, 0.002, -0.018) * PaintSat(PaintLum((s.c0 + s.c1) * 0.5) * 2.2)
        let sideSharp = 7 - 5.4 * s.feather
        let startSharp = PaintLerp(20, 7, s.tipIn) * (1 - 0.72 * s.feather), endSharp = PaintLerp(12, 5, s.tipOut) * (1 - 0.72 * s.feather)
        // A flat brush touches down on an arc, not a ruled line, and lifts on one. In units of the stroke's length.
        let arc = min(0.4, s.halfWid / s.halfLen * 0.5)
        let arcIn = arc * s.tipIn, arcOut = arc * s.tipOut
        let tipInSpan = 0.05 + 0.20 * s.tipIn, tipOutSpan = 0.06 + 0.42 * s.tipOut
        let comb = s.comb
        let own = s.level, free: UInt8 = 255, firm = s.firm
        let levelTable = levels.map, levelOther = levels.other, levelAmount = levels.amount
        let bx = Int(s.borderX), by = Int(s.borderY)
        for y in rowStart...rowEnd {
            let dy = Float(y) + 0.5 - s.cy
            // The span of this row inside the stroke's bounding rectangle.
            var lo: Float = -1e6, hi: Float = 1e6
            if abs(c) > 1e-4 {
                let a = (-reachA - dy * n) / c, b = (reachA - dy * n) / c
                lo = max(lo, min(a, b))
                hi = min(hi, max(a, b))
            } else if abs(dy * n) > reachA { continue }
            if abs(n) > 1e-4 {
                let a = (dy * c - reachB) / n, b = (dy * c + reachB) / n
                lo = max(lo, min(a, b))
                hi = min(hi, max(a, b))
            } else if abs(dy * c) > reachB { continue }
            let xStart = max(0, Int(s.cx + lo)), xEnd = min(width - 1, Int(s.cx + hi) + 1)
            guard xStart <= xEnd else { continue }
            let row = canvas + y * width
            let toothRow = teeth + (y & toothMask) * toothSize
            var dx = Float(xStart) + 0.5 - s.cx
            for x in xStart...xEnd {
                defer { dx += 1 }
                let along = (dx * c + dy * n) * invLen
                if along <= -1 || along >= 1 { continue }
                let middle = 1 - along * along
                let side = -dx * n + dy * c - s.bend * middle
                let vv = (along + 1) * 0.5
                // The ribbon: narrow where it touches down, full in the belly, drawn out into the lift at its tail.
                let inT = PaintSat(vv / tipInSpan), outT = PaintSat((1 - vv) / tipOutSpan)
                let profile = (0.66 + 0.34 * inT * (2 - inT)) * (1 - s.taper * vv * vv) * (0.34 + 0.66 * outT * (2 - outT))
                let round = sqrt(PaintSat(middle * 1.6))
                let shape = profile * (1 - s.round * (1 - round))
                let halfHere = max(0.35, s.halfWid * shape)
                let uu = side / halfHere
                if uu <= -1 || uu >= 1 { continue }
                var borderCover: Float = 1
                if own != free {
                    let at = min(height - 1, max(0, y + by)) * width + min(width - 1, max(0, x + bx))
                    let here = levelTable[at]
                    if here != free {
                        if here == own {
                            borderCover = Float(levelAmount[at]) / 255
                        } else if levelOther[at] == own {
                            borderCover = 1 - Float(levelAmount[at]) / 255
                        } else {
                            continue
                        }
                    } else if firm {
                        continue
                    }
                }
                let iu = Int(side * invPitch * 2 + s.texU) & (su - 1)
                let iv = Int((along * s.halfLen) * invPitchV + s.texV) & (sv - 1)
                let tex = texture[iv * su + iu]
                let d = 0.6 + (tex.x - 0.6) * comb, leanHere = tex.y * comb, g = 0.62 + (tex.z - 0.62) * comb
                let e = ends[iu]
                // Bristles touch down and lift off at their own moments.
                let uu2 = uu * uu
                let aStart = PaintSat((vv - arcIn * uu2 - e.x * 0.11 * comb) * startSharp)
                let aEnd = PaintSat((1 - vv - arcOut * uu2 - e.y * 0.24 * s.dry * comb) * endSharp)
                let aSide = PaintSat((1 - abs(uu)) * sideSharp + (d - 0.6) * 1.4)
                // The load runs out along the stroke; what's left catches the tops of the threads.
                let holds = s.load * (1 - vv * vv * vv * 0.72 * s.dry) + (d - 0.55) * 0.62
                let t = toothRow[x & toothMask]
                let cover = PaintSat((holds - (0.62 - t * 0.62) * 0.72) * 4.2 + 0.1)
                let a = s.alpha * aStart * aEnd * aSide * cover * borderCover
                if a <= 0.002 { continue }
                let fu = (uu + 1) * 0.5 * Float(PaintStripWidth - 1)
                let ku = min(PaintStripWidth - 2, Int(fu))
                let tu = fu - Float(ku)
                let startColor = strip[ku] + (strip[ku + 1] - strip[ku]) * tu
                let endColor = strip[PaintStripWidth + ku] + (strip[PaintStripWidth + ku + 1] - strip[PaintStripWidth + ku]) * tu
                let base = startColor + (endColor - startColor) * vv
                let colour = base + lean * PaintSat(leanHere * 0.75) + warmLean * leanHere + base * (0.05 * (d - 0.6))
                // A little ridge along each side and where the tail lifted.
                let ridge = 1 + 0.5 * PaintSstep(0.7, 0.96, abs(uu)) + 0.25 * PaintSstep(0.7, 0.95, vv)
                let heightNew = s.thick * g * ridge * (0.55 + 0.45 * s.load) * PaintCanvas.thickness
                let px = row[x]
                let r0 = Float(px.x), g0 = Float(px.y), b0 = Float(px.z), h0 = Float(px.w)
                let target = colour * PaintCanvas.colour
                row[x] = SIMD4(UInt16(max(0, min(65535, r0 + (target.x - r0) * a + 0.5))), UInt16(max(0, min(65535, g0 + (target.y - g0) * a + 0.5))),
                               UInt16(max(0, min(65535, b0 + (target.z - b0) * a + 0.5))), UInt16(max(0, min(65535, h0 + (heightNew - h0 * 0.72) * a + 0.5))))
            }
        }
    }

    /// Lights the thickness, lays the weave on what's thin, and writes the picture.
    private static func finish(canvas: UnsafeMutablePointer<PaintCanvasPixel>, ref: PaintSceneRef, width: Int, height: Int, unit: Float, tooth: PaintToothTex, seed: UInt64) -> CGImage? {
        guard let ctx = BackdropCanvas.context(width: width, height: height), let data = ctx.data else { return nil }
        let bytesPerRow = ctx.bytesPerRow
        let bytes = PaintBytesRef(p: data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height))
        let source = PaintCanvasRef(p: canvas)
        // Marks read at the scale of the picture, so at a tile's size they're lit more gently (there's less to see).
        let scale = PaintSat(unit / 700) * 0.72 + 0.28
        let strength = (ref.dark ? 0.085 : 0.105) * ref.relief * scale
        let sheen = (ref.dark ? 0.018 : 0.03) * ref.relief * scale
        let weave = (ref.dark ? 0.012 : 0.020) * tooth.visible
        let teeth = PaintFloatsRef(p: tooth.t)
        let toothSize = tooth.size, toothMask = toothSize - 1
        let lx = ref.lightDir.x, ly = ref.lightDir.y
        PaintPar(height) { y in
            let up = source.p + max(0, y - 1) * width
            let down = source.p + min(height - 1, y + 1) * width
            let row = source.p + y * width
            let out = bytes.p + y * bytesPerRow
            let toothRow = teeth.p + (y & toothMask) * toothSize
            let toothUp = teeth.p + ((y + toothSize - 1) & toothMask) * toothSize
            var s0 = UInt32(truncatingIfNeeded: seed) ^ (UInt32(y) &* 0x9E37_79B9) | 1
            for x in 0..<width {
                let xl = max(0, x - 1), xr = min(width - 1, x + 1)
                let px = row[x]
                // A slope is lit if the paint climbs away from the scene's own light.
                @inline(__always) func thick(_ p: PaintCanvasPixel) -> Float { Float(p.w) }
                let gx = (thick(row[xr]) - thick(row[xl])) + 0.5 * (thick(up[xr]) - thick(up[xl]) + thick(down[xr]) - thick(down[xl]))
                let gy = (thick(down[x]) - thick(up[x])) + 0.5 * (thick(down[xl]) - thick(up[xl]) + thick(down[xr]) - thick(up[xr]))
                let slope = -(gx * lx + gy * ly) / (2.2 * PaintCanvas.thickness)
                let k = 1 + strength * max(-1.4, min(1.4, slope * 2.1))
                let t = toothRow[x & toothMask] - toothUp[(x + 1) & toothMask]
                var c = PaintCanvas.colour(px)
                let thin = 1 - PaintSat(Float(px.w) / PaintCanvas.thickness * 1.1)
                c *= k + weave * t * (0.35 + 0.65 * thin)
                let spec = max(0, slope * 2.1 - 0.35)
                c += PaintV3(repeating: sheen * spec * spec)
                // A hair of dither so nothing bands on an 8-bit screen.
                s0 ^= s0 << 13
                s0 ^= s0 >> 17
                s0 ^= s0 << 5
                let dither = (Float(s0 & 0xFF) / 255 - 0.5) * 1.0
                let i = x * 4
                out[i] = UInt8(max(0, min(255, c.x * 255 + dither + 0.5)))
                out[i + 1] = UInt8(max(0, min(255, c.y * 255 + dither + 0.5)))
                out[i + 2] = UInt8(max(0, min(255, c.z * 255 + dither + 0.5)))
                out[i + 3] = 255
            }
        }
        return ctx.makeImage()
    }
}

nonisolated struct PaintV3sRef: @unchecked Sendable { let p: UnsafeMutablePointer<SIMD3<Float>> }
nonisolated struct PaintColoursRef: @unchecked Sendable { let p: UnsafePointer<PaintV3> }
nonisolated struct PaintStrokesRef: @unchecked Sendable { let p: UnsafePointer<PaintStroke> }
nonisolated struct PaintCanvasRef: @unchecked Sendable { let p: UnsafeMutablePointer<PaintCanvasPixel> }

/// A pixel of wet paint: colour and thickness, as sixteen-bit numbers. Half the memory of floats, and finer than the eight bits it ends in.
typealias PaintCanvasPixel = SIMD4<UInt16>

nonisolated enum PaintCanvas {
    /// What a colour of 1 is stored as.
    @inline(__always) static var colour: Float { 65535 }
    /// What a thickness of 1 is stored as; paint never builds much past 3.5.
    @inline(__always) static var thickness: Float { 16383 }

    @inline(__always) static func colour(_ p: PaintCanvasPixel) -> PaintV3 { PaintV3(Float(p.x), Float(p.y), Float(p.z)) / colour }
    @inline(__always) static func height(_ p: PaintCanvasPixel) -> Float { Float(p.w) / thickness }

    @inline(__always) static func pixel(_ c: PaintV3, height: Float) -> PaintCanvasPixel {
        let v = c * colour
        return SIMD4(UInt16(max(0, min(65535, v.x + 0.5))), UInt16(max(0, min(65535, v.y + 0.5))), UInt16(max(0, min(65535, v.z + 0.5))), UInt16(max(0, min(65535, height * thickness + 0.5))))
    }
}
nonisolated struct PaintBytesRef: @unchecked Sendable { let p: UnsafeMutablePointer<UInt8> }

/// The shapes at the canvas's size, their borders roughened a little so nothing looks cut with a knife, and left open where the edge is meant to be lost.
nonisolated final class PaintLevelMap: @unchecked Sendable {
    let map: UnsafeMutablePointer<UInt8>
    let other: UnsafeMutablePointer<UInt8>
    let amount: UnsafeMutablePointer<UInt8>

    init(ref: PaintSceneRef, width: Int, height: Int, unit: Float, seed: UInt64) {
        map = .allocate(capacity: width * height)
        other = .allocate(capacity: width * height)
        amount = .allocate(capacity: width * height)
        let w = ref.w, h = ref.h
        // Where an edge between shapes lies in a soft passage, a band around it is open to both.
        let boundary = PaintBuf(w: w, h: h)
        PaintPar(h) { y in
            for x in 0..<w {
                let l = ref.level.at(x, y), softHere = ref.soft.at(x, y)
                var lost: Float = 0
                if x > 0 && ref.level.at(x - 1, y) != l { lost = max(lost, min(softHere, ref.soft.at(x - 1, y))) }
                if x < w - 1 && ref.level.at(x + 1, y) != l { lost = max(lost, min(softHere, ref.soft.at(x + 1, y))) }
                if y > 0 && ref.level.at(x, y - 1) != l { lost = max(lost, min(softHere, ref.soft.at(x, y - 1))) }
                if y < h - 1 && ref.level.at(x, y + 1) != l { lost = max(lost, min(softHere, ref.soft.at(x, y + 1))) }
                boundary.p[y * w + x] = PaintSstep(0.45, 0.85, lost)
            }
        }
        let band = boundary.blurred(max(1, Int(0.008 * Float(w))))
        // A tile of roughness: a slow wander and a fine fray.
        let tile = unit < 420 ? 128 : 512
        let warp = UnsafeMutablePointer<SIMD2<Float>>.allocate(capacity: tile * tile)
        defer { warp.deallocate() }
        let noise = PaintNoise(seed: seed ^ 0x90A7)
        let table = PaintWarpRef(p: warp)
        let slow = Double(unit) * 0.0035, fine = Double(unit) * 0.0012
        PaintPar(tile) { y in
            for x in 0..<tile {
                let fx = Double(x), fy = Double(y)
                let a = noise.fbm(fx * 0.018, fy * 0.018, octaves: 2) * slow + noise.fbm(fx * 0.14, fy * 0.14, octaves: 2) * fine
                let b = noise.fbm(fx * 0.018 + 31, fy * 0.018 - 7, octaves: 2) * slow + noise.fbm(fx * 0.14 + 11, fy * 0.14 + 5, octaves: 2) * fine
                table.p[y * tile + x] = SIMD2(Float(a), Float(b))
            }
        }
        let outMap = PaintBytesRef(p: map), outOther = PaintBytesRef(p: other), outAmount = PaintBytesRef(p: amount)
        let toRef = Float(w) / Float(width)
        let mask = tile - 1
        // Which of the study's cells have one shape in all of the six by six around them: the great majority, and they need no thought.
        let mixedCell = PaintByteBuf(w: w, h: h, scale: 1)
        let across = PaintByteBuf(w: w, h: h, scale: 1)
        PaintPar(h) { y in
            let yn = min(h - 1, y + 1)
            var count = 0
            // A cell changes if it differs from the one to its right or below; a running count over six columns (x-3...x+2) finds any change near it.
            @inline(__always) func changes(_ x: Int) -> Int {
                guard x >= 0, x < w else { return 0 }
                let l = ref.level.bytes[y * w + x]
                return l != ref.level.bytes[y * w + min(w - 1, x + 1)] || l != ref.level.bytes[yn * w + x] ? 1 : 0
            }
            for x in -3...2 { count += changes(x) }
            for x in 0..<w {
                across.bytes[y * w + x] = count > 0 ? 1 : 0
                count += changes(x + 3) - changes(x - 3)
            }
        }
        PaintPar(w) { x in
            var count = 0
            @inline(__always) func flag(_ y: Int) -> Int { y >= 0 && y < h ? Int(across.bytes[y * w + x]) : 0 }
            for y in -3...2 { count += flag(y) }
            for y in 0..<h {
                mixedCell.bytes[y * w + x] = count > 0 ? 1 : 0
                count += flag(y + 3) - flag(y - 3)
            }
        }
        // The sharpness of a border, in canvas pixels' worth of the study's cell: about one pixel wide however big the canvas.
        let edgeWidth = max(0.05, min(0.5, 0.11 * toRef / 0.5))
        PaintPar(height) { y in
            for x in 0..<width {
                let at = y * width + x
                let d = table.p[(y & mask) * tile + (x & mask)]
                let rx = (Float(x) + 0.5 + d.x) * toRef - 0.5, ry = (Float(y) + 0.5 + d.y) * toRef - 0.5
                let x0 = min(w - 1, max(0, Int(rx))), y0 = min(h - 1, max(0, Int(ry)))
                // A firm shape keeps its own cells, whatever lost edge is happening next door. The line between firm and open is smooth, never a staircase of cells.
                let x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
                let fx = PaintSat(rx - Float(x0)), fy = PaintSat(ry - Float(y0))
                let openHere = PaintLerp(PaintLerp(band.at(x0, y0), band.at(x1, y0), fx), PaintLerp(band.at(x0, y1), band.at(x1, y1), fx), fy)
                if openHere > 0.018 && PaintLerp(PaintLerp(ref.soft.at(x0, y0), ref.soft.at(x1, y0), fx), PaintLerp(ref.soft.at(x0, y1), ref.soft.at(x1, y1), fx), fy) >= 0.3 {
                    outMap.p[at] = 255
                    outOther.p[at] = 255
                    outAmount.p[at] = 255
                    continue
                }
                // Fast out in the middle of a shape.
                let l00 = ref.level.at(x0, y0)
                if mixedCell.bytes[y0 * w + x0] == 0 {
                    let l = UInt8(max(0, min(254, l00)))
                    outMap.p[at] = l
                    outOther.p[at] = l
                    outAmount.p[at] = 255
                    continue
                }
                // The study holds its shapes in cells; a border is a smooth line through them, never a staircase.
                var labels = SIMD8<Float>(repeating: -1), sums = SIMD8<Float>(repeating: 0)
                for j in stride(from: -2, through: 3, by: 1) {
                    let yy = min(h - 1, max(0, y0 + j))
                    let dy = Float(y0 + j) - ry
                    for i in stride(from: -2, through: 3, by: 1) {
                        let dx = Float(x0 + i) - rx
                        let q = 1 - (dx * dx + dy * dy) / 5.3
                        if q <= 0 { continue }
                        let weight = q * q
                        let l = ref.level.at(min(w - 1, max(0, x0 + i)), yy)
                        for k in 0..<8 {
                            if labels[k] == l {
                                sums[k] += weight
                                break
                            }
                            if labels[k] < 0 {
                                labels[k] = l
                                sums[k] = weight
                                break
                            }
                        }
                    }
                }
                var first: Float = l00, firstW: Float = -1, second: Float = l00, secondW: Float = -1
                for k in 0..<8 where labels[k] >= 0 {
                    if sums[k] > firstW {
                        second = first
                        secondW = firstW
                        first = labels[k]
                        firstW = sums[k]
                    } else if sums[k] > secondW {
                        second = labels[k]
                        secondW = sums[k]
                    }
                }
                let share = firstW / max(0.0001, firstW + max(0, secondW))
                let mine = PaintSstep(0.5 - edgeWidth, 0.5 + edgeWidth, share)
                outMap.p[at] = UInt8(max(0, min(254, first)))
                outOther.p[at] = UInt8(max(0, min(254, second)))
                outAmount.p[at] = UInt8(mine * 255)
            }
        }
    }

    deinit {
        map.deallocate()
        other.deallocate()
        amount.deallocate()
    }
}

nonisolated struct PaintWarpRef: @unchecked Sendable { let p: UnsafeMutablePointer<SIMD2<Float>> }

@inline(__always) nonisolated func PaintLength(_ v: PaintV3) -> Float { (v * v).sum().squareRoot() }

/// Everything strokes read from: colour at every size, the direction field, the edges.
nonisolated final class PaintStrokeField: @unchecked Sendable {
    let ref: PaintSceneRef
    var mips: [PaintBuf] = []
    /// The way strokes run here, radians, modulo π.
    let flow: PaintBuf
    /// How strong a colour edge is here, at a couple of scales, 0…1.
    let edge: PaintBuf
    /// A slow drift of warm and cool across the picture, -1…1.
    let warmth: PaintBuf
    /// The way the edges themselves run, radians, modulo π, and how sharp they are at the smallest size.
    let edgeFlow: PaintBuf
    let edgeFine: PaintBuf
    /// Sixteen points spread over a unit disc: where a brush gathers its colour.
    var discX = [Float](repeating: 0, count: 16), discY = [Float](repeating: 0, count: 16)

    init(ref: PaintSceneRef) {
        self.ref = ref
        for k in 0..<16 {
            let r = ((Float(k) + 0.5) / 16).squareRoot(), a = Float(k) * 2.39996
            discX[k] = r * cos(a)
            discY[k] = r * sin(a)
        }
        mips = [ref.rgb]
        while let last = mips.last, last.w > 12, mips.count < 7 { mips.append(last.halved()) }
        let w = ref.w, h = ref.h
        // Structure tensor of the value, so that strokes run along edges where there are edges.
        let edgeRaw = PaintBuf(w: w, h: h)
        let rgb = ref.rgb
        let smooth: PaintBuf
        do {
            let tensor = PaintBuf(w: w, h: h, c: 3)
            PaintPar(h) { y in
                let ym = max(0, y - 1), yp = min(h - 1, y + 1)
                for x in 0..<w {
                    let xm = max(0, x - 1), xp = min(w - 1, x + 1)
                    let gxC = rgb.get3(xp, y) - rgb.get3(xm, y) + 0.5 * (rgb.get3(xp, ym) - rgb.get3(xm, ym) + rgb.get3(xp, yp) - rgb.get3(xm, yp))
                    let gyC = rgb.get3(x, yp) - rgb.get3(x, ym) + 0.5 * (rgb.get3(xm, yp) - rgb.get3(xm, ym) + rgb.get3(xp, yp) - rgb.get3(xp, ym))
                    let gx = PaintLum(gxC), gy = PaintLum(gyC)
                    let i = (y * w + x) * 3
                    tensor.p[i] = gx * gx
                    tensor.p[i + 1] = gy * gy
                    tensor.p[i + 2] = gx * gy
                    edgeRaw.p[y * w + x] = PaintSat(((gxC * gxC).sum() + (gyC * gyC).sum()).squareRoot() * (ref.dark ? 8 : 3.2))
                }
            }
            tensor.blur(max(1, w / 90))
            smooth = tensor
        }
        // Edge strength at two scales, the fine one kept close, the broad one spread so strokes gather around it.
        let edgeOut = PaintBuf(w: w, h: h)
        do {
            let edgeWide = edgeRaw.blurred(max(1, w / 110))
            PaintPar(h) { y in
                for x in 0..<w {
                    let i = y * w + x
                    edgeOut.p[i] = PaintSat(max(edgeRaw.p[i] * 0.7, edgeWide.p[i] * 1.7))
                }
            }
        }
        edge = edgeOut
        edgeFine = edgeRaw
        let flowRaw = PaintBuf(w: w, h: h, c: 2)
        let tangentRaw = PaintBuf(w: w, h: h, c: 2)
        let dir = ref.dir
        PaintPar(h) { y in
            for x in 0..<w {
                let i = y * w + x
                let a = smooth.p[i * 3], b = smooth.p[i * 3 + 1], c = smooth.p[i * 3 + 2]
                // Double-angle of the gradient; tangent is its opposite.
                let dx = a - b, dy = 2 * c
                let m = (dx * dx + dy * dy).squareRoot()
                let coherent = PaintSstep(0.0004, 0.006, m) * ref.formWeight.p[i]
                let tx = m > 1e-6 ? -dx / m : 0, ty = m > 1e-6 ? -dy / m : 0
                flowRaw.p[i * 2] = dir.p[i * 2] + tx * coherent * 0.9
                flowRaw.p[i * 2 + 1] = dir.p[i * 2 + 1] + ty * coherent * 0.9
                tangentRaw.p[i * 2] = dx * -1
                tangentRaw.p[i * 2 + 1] = dy * -1
            }
        }
        // Worked out once per place: a stroke asks at every step, and the wet blend asks at every pixel.
        @Sendable func angles(_ doubled: PaintBuf) -> PaintBuf {
            let out = PaintBuf(w: w, h: h)
            PaintPar(h) { y in
                for x in 0..<w {
                    let i = y * w + x
                    out.p[i] = 0.5 * atan2(doubled.p[i * 2 + 1], doubled.p[i * 2])
                }
            }
            return out
        }
        tangentRaw.blur(max(1, w / 300))
        flowRaw.blur(max(1, w / 200))
        edgeFlow = angles(tangentRaw)
        flow = angles(flowRaw)
        let warm = PaintBuf(w: 64, h: 64 * h / max(1, w))
        let noise = PaintNoise(seed: 0xF00D)
        for y in 0..<warm.h {
            for x in 0..<warm.w {
                warm.p[y * warm.w + x] = Float(noise.fbm(Double(x) / 64 * 3.2, Double(y) / 64 * 3.2, octaves: 3)) * 1.8
            }
        }
        warmth = warm
    }

    /// The way the edge runs at reference pixel `x`, `y`, radians, modulo π.
    @inline(__always) func edgeAngle(_ x: Float, _ y: Float) -> Float {
        let fx = min(Float(edgeFlow.w) - 1, max(0, x)), fy = min(Float(edgeFlow.h) - 1, max(0, y))
        return edgeFlow.p[Int(fy) * edgeFlow.w + Int(fx)]
    }

    /// Direction at reference pixel `x`, `y`, radians, modulo π.
    @inline(__always) func angle(_ x: Float, _ y: Float) -> Float {
        let fx = min(Float(flow.w) - 1, max(0, x)), fy = min(Float(flow.h) - 1, max(0, y))
        return flow.p[Int(fy) * flow.w + Int(fx)]
    }
}
