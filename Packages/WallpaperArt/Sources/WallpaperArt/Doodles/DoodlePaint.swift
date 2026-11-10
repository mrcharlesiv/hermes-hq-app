// The print: a quiet ground, spot colours laid a hair out of register, and the ink over them.
//
// Ink and spot colours are rasterised as masks at full size (bands on separate threads, each writing its own rows), then
// every pixel is composed from the masks, the ground, and the paper's tooth. Colours come from small canvases of soft
// noise that are interpolated up, so the ink's colour drifts across the picture along with the ground.

import CoreGraphics
import Foundation

nonisolated struct DoodleStyle: Sendable {
    typealias Ink = BackdropPreset.Ink
    struct Anchor: Sendable {
        var x, y: Double
        var c: Ink
        var r: Double
    }

    var ground: [Anchor]
    var ink: [Anchor]
    var spots: [Ink]
    var spotAlpha: [Double]
    /// The tone of a drawing's bare parts, laid over the ground.
    var paper: Ink
    var paperAlpha: Double
    var gel: Ink
    var gelAlpha: Double
    /// Mottling of the ground, 0…1.
    var mottle: Double
    var inkAlpha: Double = 1
    /// How much the spot colours pool at their edges.
    var pool: Double = 0.3
    /// Fine lines and small marks are inked lighter than a drawing's outline, so they stay out of the way of text.
    var detailAlpha: Double = 0.58
    /// A second pass of colour, for shadow sides and far legs.
    var shade: Ink = Ink(r: 0.2, g: 0.2, b: 0.3)
    var shadeAlpha: Double = 0.22
    /// The darkest tone, for a few deliberate solid blocks.
    var accent: Ink = Ink(r: 0.1, g: 0.1, b: 0.15)
    var accentAlpha: Double = 0.9
    /// The spot colours on the few drawings picked to stand forward. Nil: they stay as they are.
    var lifted: [Ink]? = nil
    /// How many of the largest drawings stand forward.
    var liftCount: Int = 0
    /// The bare paper of a drawing that stands forward, so a pale drawing stays a pale drawing in the Dark picture.
    var liftedPaper: Ink? = nil
    var liftedPaperAlpha: Double = 0.8
    /// No channel goes brighter than this. A Dark picture keeps white text at 3:1 even on the thinnest highlight.
    var ceiling: Float = 1
}

nonisolated enum DoodleColor {
    typealias Ink = BackdropPreset.Ink
    @inline(__always) static func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    @inline(__always) static func gam(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(max(0, c), 1 / 2.4) - 0.055 }

    /// sRGB to OKLab.
    static func lab(_ c: Ink) -> SIMD3<Double> {
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// OKLab to sRGB.
    @inline(__always) static func rgb(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = v.x + 0.3963377774 * v.y + 0.2158037573 * v.z
        let m = v.x - 0.1055613458 * v.y - 0.0638541728 * v.z
        let s = v.x - 0.0894841775 * v.y - 1.2914855480 * v.z
        let ll = l * l * l, mm = m * m * m, ss = s * s * s
        let r = 4.0767416621 * ll - 3.3077115913 * mm + 0.2309699292 * ss
        let g = -1.2684380046 * ll + 2.6097574011 * mm - 0.3413193965 * ss
        let b = -0.0041960863 * ll - 0.7034186147 * mm + 1.7076147010 * ss
        return SIMD3(gam(min(1, max(0, r))), gam(min(1, max(0, g))), gam(min(1, max(0, b))))
    }

    static func hex(_ v: UInt32) -> Ink {
        Ink(r: Double((v >> 16) & 255) / 255, g: Double((v >> 8) & 255) / 255, b: Double(v & 255) / 255)
    }
}

/// Holds pointers and paths across `concurrentPerform`; every thread writes only its own rows or slots.
nonisolated struct DoodleShare<T>: @unchecked Sendable {
    let value: T
}

nonisolated enum DoodlePainter {
    /// Small pictures stay on the calling thread: waking every core for a picker tile costs more than the tile.
    @inline(__always) private static func each(_ n: Int, parallel: Bool, _ body: @Sendable (Int) -> Void) {
        if parallel {
            DispatchQueue.concurrentPerform(iterations: n, execute: body)
        } else {
            for i in 0..<n { body(i) }
        }
    }

    struct Drawn {
        // kind: 0 ink, 1 knock out, 2 gel, 3 solid ink, 4 fine ink, 5 accent, 6 shade, 7 stands forward.
        var ink: [(kind: Int, path: CGPath)] = []
        var fill: [(sep: Int, path: CGPath)] = []
        var box = CGRect.null
    }

    /// One drawing, inked at its place in the picture.
    static func ink(_ g: DoodleGlyph, _ item: DoodleItem, unit: Double, px: Double) -> Drawn {
        var rng = SplitMix64(seed: item.seed)
        let longest = max(g.bbox.width, g.bbox.height)
        let k = item.size * unit / longest
        let t = CGAffineTransform(translationX: item.x * unit, y: item.y * unit)
            .rotated(by: item.rot)
            .scaledBy(x: item.flip ? -k : k, y: k)
            .translatedBy(x: -g.bbox.midX, y: -g.bbox.midY)
        // A big drawing is made with the same pen as a small one, only a little fuller: small ones must not clot.
        let s = min(1, max(0, (item.size - 0.07) / 0.2))
        let base = (3.1 + 1.25 * s) * 1.0
        var map = [0, 1, 2]
        if !g.fixed {
            let shift = Int(rng.next() * 3)
            map = [shift % 3, (shift + 1) % 3, (shift + 2) % 3]
        } else if g.recolor, rng.next() < 0.42 {
            // The same drawing in another of the set's colours.
            map[0] = rng.next() < 0.6 ? 2 : 1
        }
        let mis = CGAffineTransform(translationX: -1.7 * px, y: 1.9 * px).concatenating(.identity)
        // No two copies are quite the same drawing: each is a little wider or narrower and leans its own way.
        let aspect = rng.next(-0.028, 0.028)
        let a1 = rng.next(0.004, 0.009) * longest, a2 = rng.next(0.004, 0.009) * longest
        let p1 = rng.next(0, 6.283), p2 = rng.next(0, 6.283), f1 = rng.next(4.0, 7.0), f2 = rng.next(4.0, 7.0)
        let mx = g.bbox.midX, my = g.bbox.midY
        @inline(__always) func warp(_ p: CGPoint) -> CGPoint {
            let nx = (p.x - mx) / longest, ny = (p.y - my) / longest
            return CGPoint(x: mx + (p.x - mx) * (1 + aspect) + a1 * sin(f1 * ny + p1) + 0.4 * a1 * sin(2.3 * f2 * ny + p2),
                           y: my + (p.y - my) * (1 - aspect) + a2 * sin(f2 * nx + p2) + 0.4 * a2 * sin(2.3 * f1 * nx + p1))
        }
        var out = Drawn()
        var current = CGMutablePath(), fine = CGMutablePath()
        func flush() {
            if !current.isEmpty {
                out.ink.append((0, current))
                current = CGMutablePath()
            }
            if !fine.isEmpty {
                out.ink.append((4, fine))
                fine = CGMutablePath()
            }
        }
        @inline(__always) func mapped(_ pts: [CGPoint]) -> [CGPoint] { pts.map { warp($0).applying(t) } }
        func polygon(_ ring: [CGPoint], offset: Bool) -> CGPath {
            let p = CGMutablePath()
            let q = mapped(ring)
            if offset {
                p.addLines(between: q.map { $0.applying(mis) })
            } else {
                p.addLines(between: q)
            }
            p.closeSubpath()
            return p
        }
        let seenSize = item.size * pow(min(1, px), 0.3)
        // A small mark is all fine ink; a drawing keeps its outline strong and its detail light.
        let isMark = item.size < 0.08
        let pen = rng.next(0.93, 1.08)
        for step in g.steps where seenSize >= step.lod {
            switch step.op {
            case let .shape(ring, sep):
                flush()
                out.ink.append((1, polygon(ring, offset: false)))
                out.fill.append((sep < 0 ? -1 : map[sep], polygon(ring, offset: true)))
                if item.lift { out.ink.append((7, polygon(ring, offset: true))) }
            case let .tint(ring, sep):
                // -2 is `keepClear`: it only speaks to the packer.
                if sep != -2 {
                    out.fill.append((sep < 0 ? -1 : map[sep], polygon(ring, offset: true)))
                    if item.lift { out.ink.append((7, polygon(ring, offset: true))) }
                }
            case let .ink(runs, w):
                let light = isMark || step.lod > 0 || w <= 0.62
                for run in runs {
                    // One hand does not make the same hatch twice: now and then a stroke is left out.
                    if light, run.pts.count == 2, !run.over, rng.next() < 0.07 { continue }
                    DoodlePen.ribbon(mapped(run.pts), closed: run.closed, over: run.over, base: base * w * pen, px: px, rng: &rng, into: light ? fine : current)
                }
            case let .blot(ring):
                flush()
                out.ink.append((isMark ? 4 : 3, polygon(ring, offset: false)))
            case let .gel(runs, w):
                flush()
                let p = CGMutablePath()
                for run in runs {
                    DoodlePen.ribbon(mapped(run.pts), closed: run.closed, over: run.over, base: base * w, px: px, rng: &rng, into: p)
                }
                out.ink.append((2, p))
            case let .shade(ring):
                flush()
                out.ink.append((6, polygon(ring, offset: true)))
            case let .accent(ring):
                flush()
                out.ink.append((5, polygon(ring, offset: false)))
            }
        }
        flush()
        // A generous box: only used to pick which bands to draw into.
        let reach = item.size * unit * 0.76 + 8
        out.box = CGRect(x: item.x * unit - reach, y: item.y * unit - reach, width: reach * 2, height: reach * 2)
        return out
    }

    static func paint(_ lib: [DoodleGlyph], _ items: [DoodleItem], style: DoodleStyle, width: Int, height: Int, seed: UInt64, unitOverride: Double? = nil) -> CGImage? {
        let unit = unitOverride ?? Double(min(width, height))
        let px = unit / 1179
        let wide = width * height > 400_000
        // Written byte by byte below, with no alpha to carry: the finished picture is flagged opaque.
        guard let out = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: BackdropCanvas.space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let outData = out.data else { return nil }
        let bpr = width * 4

        // Every drawing's ribbons.
        let drawnSlots = UnsafeMutablePointer<Drawn>.allocate(capacity: items.count)
        drawnSlots.initialize(repeating: Drawn(), count: items.count)
        defer {
            drawnSlots.deinitialize(count: items.count)
            drawnSlots.deallocate()
        }
        let slots = DoodleShare(value: drawnSlots)
        let libShare = DoodleShare(value: lib), itemShare = DoodleShare(value: items)
        each(items.count, parallel: wide) { i in
            let item = itemShare.value[i]
            slots.value[i] = ink(libShare.value[item.glyph], item, unit: unit, px: px)
        }

        // The ground and the ink's colour on small canvases.
        let cw = max(48, min(240, width / 5)), ch = max(48, Int(Double(cw) * Double(height) / Double(width)))
        let noise = GradientNoise(seed: seed), noise2 = GradientNoise(seed: seed ^ 0xABCDEF)
        var groundR = [Float](repeating: 0, count: cw * ch), groundG = groundR, groundB = groundR
        var inkR = groundR, inkG = groundR, inkB = groundR, mott = groundR
        let wu = Double(width) / unit, hu = Double(height) / unit
        let groundLab = style.ground.map { (x: $0.x, y: $0.y, r: $0.r, c: DoodleColor.lab($0.c)) }
        let inkLab = style.ink.map { (x: $0.x, y: $0.y, r: $0.r, c: DoodleColor.lab($0.c)) }
        groundR.withUnsafeMutableBufferPointer { gr in
            groundG.withUnsafeMutableBufferPointer { gg in
                groundB.withUnsafeMutableBufferPointer { gb in
                    inkR.withUnsafeMutableBufferPointer { ir in
                        inkG.withUnsafeMutableBufferPointer { ig in
                            inkB.withUnsafeMutableBufferPointer { ib in
                                mott.withUnsafeMutableBufferPointer { mo in
                                    let share = DoodleShare(value: (gr.baseAddress!, gg.baseAddress!, gb.baseAddress!, ir.baseAddress!, ig.baseAddress!, ib.baseAddress!, mo.baseAddress!))
                                    let m = style.mottle
                                    each(ch, parallel: wide) { row in
                                        let v = (Double(row) + 0.5) / Double(ch)
                                        let p = share.value
                                        for col in 0..<cw {
                                            let u = (Double(col) + 0.5) / Double(cw)
                                            let ux = u * wu, vy = v * hu
                                            // Where the colours meet is bent by noise, so nothing reads as a round blob.
                                            let wx = u + 0.16 * noise.fbm(ux * 1.1, vy * 1.1, octaves: 3)
                                            let wy = v + 0.09 * noise.fbm(ux * 1.1 + 7.3, vy * 1.1 + 3.1, octaves: 3)
                                            var sum = SIMD3<Double>(0, 0, 0), total = 0.0
                                            for a in groundLab {
                                                let dx = (wx - a.x) * 0.6, dy = wy - a.y
                                                let w = exp(-(dx * dx + dy * dy) / (a.r * a.r))
                                                sum += a.c * w
                                                total += w
                                            }
                                            var c = sum / max(1e-6, total)
                                            // Pigment settling: a broad cloud, finer flecks in it.
                                            let cloud = noise2.fbm(ux * 3.2, vy * 3.2, octaves: 4)
                                            let fleck = noise2.fbm(ux * 14 + 3.3, vy * 14 + 8.1, octaves: 2)
                                            let settle = cloud * 0.75 + fleck * 0.25
                                            c.x *= 1 + m * 0.11 * settle
                                            let col3 = DoodleColor.rgb(c)
                                            let i = row * cw + col
                                            p.0[i] = Float(col3.x)
                                            p.1[i] = Float(col3.y)
                                            p.2[i] = Float(col3.z)
                                            p.6[i] = Float(fleck * 0.6 + cloud * 0.4)
                                            sum = SIMD3<Double>(0, 0, 0)
                                            total = 0
                                            for a in inkLab {
                                                let dx = (wx - a.x) * 0.6, dy = wy - a.y
                                                let w = exp(-(dx * dx + dy * dy) / (a.r * a.r))
                                                sum += a.c * w
                                                total += w
                                            }
                                            let inkC = DoodleColor.rgb(sum / max(1e-6, total))
                                            p.3[i] = Float(inkC.x)
                                            p.4[i] = Float(inkC.y)
                                            p.5[i] = Float(inkC.z)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // The paper's tooth: a tile of soft noise, smoothed the same way in every direction.
        let toothSide = 256
        var tooth = [Float](repeating: 0, count: toothSide * toothSide)
        do {
            var rng = SplitMix64(seed: seed ^ 0x7007)
            var raw = [Float](repeating: 0, count: toothSide * toothSide)
            for i in raw.indices { raw[i] = Float(rng.next()) * 2 - 1 }
            let m = toothSide - 1
            for y in 0..<toothSide {
                for x in 0..<toothSide {
                    @inline(__always) func at(_ dx: Int, _ dy: Int) -> Float { raw[((y + dy) & m) * toothSide + ((x + dx) & m)] }
                    let edge = at(1, 0) + at(-1, 0) + at(0, 1) + at(0, -1)
                    let corner = at(1, 1) + at(-1, 1) + at(1, -1) + at(-1, -1)
                    tooth[y * toothSide + x] = (at(0, 0) * 0.62 + edge * 0.17 + corner * 0.07) * 1.3
                }
            }
        }

        // Everything together.
        let spots = style.spots.map { SIMD3<Float>(Float($0.r), Float($0.g), Float($0.b)) }
        let spotAlpha = style.spotAlpha.map { Float($0) }
        let paperC = SIMD3<Float>(Float(style.paper.r), Float(style.paper.g), Float(style.paper.b))
        let paperA = Float(style.paperAlpha)
        let gelC = SIMD3<Float>(Float(style.gel.r), Float(style.gel.g), Float(style.gel.b))
        let gelA = Float(style.gelAlpha), inkA = Float(style.inkAlpha), pool = Float(style.pool)
        let ceiling = style.ceiling
        let detailA = Float(style.detailAlpha), shadeA = Float(style.shadeAlpha), accentA = Float(style.accentAlpha)
        let shadeC = SIMD3<Float>(Float(style.shade.r), Float(style.shade.g), Float(style.shade.b))
        let accentC = SIMD3<Float>(Float(style.accent.r), Float(style.accent.g), Float(style.accent.b))
        let lifted = (style.lifted ?? style.spots).map { SIMD3<Float>(Float($0.r), Float($0.g), Float($0.b)) }
        let toothAmount = Float(0.011)
        let hasGrain = true
        let liftedPaperC = style.liftedPaper.map { SIMD3<Float>(Float($0.r), Float($0.g), Float($0.b)) } ?? paperC
        let liftedPaperA = style.liftedPaper == nil ? paperA : Float(style.liftedPaperAlpha)
        let arrays = DoodleShare(value: (groundR, groundG, groundB, inkR, inkG, inkB, mott, tooth))
        let dest = DoodleShare(value: outData.assumingMemoryBound(to: UInt8.self))
        let destBpr = out.bytesPerRow
        let slotCount = items.count
        let qw = max(1, width / 4)
        // The masks are 12 bytes a pixel, so they are only ever held for a strip of the picture: a big iPad stays as cheap as a phone.
        // Each strip carries a few spare rows, so the pooling near its edge sees what is over the edge.
        let radius = max(1, Int(5.0 * px / 4))
        let spare = 4 * (2 * radius + 2)
        let strips = wide ? max(1, Int((Double(width * height) / 1_100_000).rounded(.up))) : 1
        let stripH = (height + strips - 1) / strips
        let maskRows = min(height, stripH + 2 * spare + 4)
        let inkBuf = UnsafeMutableRawPointer.allocate(byteCount: bpr * maskRows, alignment: 16)
        let fillBuf = UnsafeMutableRawPointer.allocate(byteCount: bpr * maskRows, alignment: 16)
        let toneBuf = UnsafeMutableRawPointer.allocate(byteCount: bpr * maskRows, alignment: 16)
        defer {
            inkBuf.deallocate()
            fillBuf.deallocate()
            toneBuf.deallocate()
        }
        let softRows = maskRows / 4 + 2
        let softBuf = UnsafeMutablePointer<Float>.allocate(capacity: qw * softRows * 3)
        let softTmp = UnsafeMutablePointer<Float>.allocate(capacity: qw * softRows * 3)
        defer {
            softBuf.deallocate()
            softTmp.deallocate()
        }
        let inkShare = DoodleShare(value: inkBuf), fillShare = DoodleShare(value: fillBuf), toneShare = DoodleShare(value: toneBuf)
        for strip in 0..<strips {
            let rowA = strip * stripH, rowB = min(height, rowA + stripH)
            guard rowA < rowB else { break }
            // The pooling grid stays on multiples of four, so strips join without a seam.
            let top = max(0, rowA - spare) & ~3, bottom = min(height, rowB + spare)
            let rows = bottom - top
            memset(inkBuf, 0, bpr * rows)
            memset(fillBuf, 0, bpr * rows)
            memset(toneBuf, 0, bpr * rows)

            // Rasterise, a band of rows per thread.
            let bands = wide ? max(4, 32 / strips) : 1
            let bandH = max(1, rows / bands + 1)
            each(bands, parallel: wide) { b in
                let y0 = b * bandH
                guard y0 < rows else { return }
                let h = min(bandH, rows - y0)
                let space = BackdropCanvas.space
                guard let ic = CGContext(data: inkShare.value + y0 * bpr, width: width, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                    let fc = CGContext(data: fillShare.value + y0 * bpr, width: width, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                    let tc = CGContext(data: toneShare.value + y0 * bpr, width: width, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                let pictureY0 = top + y0
                for c in [ic, fc, tc] {
                    c.translateBy(x: 0, y: CGFloat(h))
                    c.scaleBy(x: 1, y: -1)
                    c.translateBy(x: 0, y: -CGFloat(pictureY0))
                    c.setShouldAntialias(true)
                }
                tc.setBlendMode(.plusLighter)
                let rect = CGRect(x: 0, y: Double(pictureY0), width: Double(width), height: Double(h))
                for i in 0..<slotCount {
                    let drawn = slots.value[i]
                    guard drawn.box.intersects(rect) else { continue }
                    for f in drawn.fill {
                        switch f.sep {
                        case 0: fc.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
                        case 1: fc.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
                        case 2: fc.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
                        default: fc.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
                        }
                        fc.addPath(f.path)
                        fc.fillPath()
                    }
                    for op in drawn.ink {
                        switch op.kind {
                        case 1:
                            ic.setBlendMode(.clear)
                            ic.addPath(op.path)
                            ic.fillPath()
                            ic.setBlendMode(.normal)
                            tc.setBlendMode(.clear)
                            tc.addPath(op.path)
                            tc.fillPath()
                            tc.setBlendMode(.plusLighter)
                        case 2:
                            ic.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
                            ic.addPath(op.path)
                            ic.fillPath()
                        case 4:
                            ic.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
                            ic.addPath(op.path)
                            ic.fillPath()
                        case 5:
                            tc.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
                            tc.addPath(op.path)
                            tc.fillPath()
                        case 6:
                            tc.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
                            tc.addPath(op.path)
                            tc.fillPath()
                        case 7:
                            tc.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
                            tc.addPath(op.path)
                            tc.fillPath()
                        default:
                            ic.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
                            ic.addPath(op.path)
                            ic.fillPath()
                        }
                    }
                }
            }

            // Spot colours pool at their edges: a blurred copy of their mask, at quarter size, says how far inside a pixel is.
            let qh = max(1, rows / 4)
            let sp = DoodleShare(value: softBuf), tp = DoodleShare(value: softTmp)
            do {
                let src = DoodleShare(value: fillBuf.assumingMemoryBound(to: UInt8.self))
                each(qh, parallel: wide) { y in
                    for x in 0..<qw {
                        var a: Float = 0, b: Float = 0, c: Float = 0
                        for dy in 0..<4 {
                            let row = min(rows - 1, y * 4 + dy) * bpr
                            for dx in 0..<4 {
                                let i = row + min(width - 1, x * 4 + dx) * 4
                                a += Float(src.value[i])
                                b += Float(src.value[i + 1])
                                c += Float(src.value[i + 2])
                            }
                        }
                        let k = 1 / (16 * 255 as Float)
                        let o = (y * qw + x) * 3
                        sp.value[o] = a * k
                        sp.value[o + 1] = b * k
                        sp.value[o + 2] = c * k
                    }
                }
                // Two box passes, each way.
                for _ in 0..<2 {
                    each(qh, parallel: wide) { y in
                        for ch in 0..<3 {
                            var sum: Float = 0
                            let row = y * qw
                            for x in -radius...radius { sum += sp.value[(row + min(qw - 1, max(0, x))) * 3 + ch] }
                            let k = 1 / Float(2 * radius + 1)
                            for x in 0..<qw {
                                tp.value[(row + x) * 3 + ch] = sum * k
                                sum += sp.value[(row + min(qw - 1, x + radius + 1)) * 3 + ch] - sp.value[(row + max(0, x - radius)) * 3 + ch]
                            }
                        }
                    }
                    each(qw, parallel: wide) { x in
                        for ch in 0..<3 {
                            var sum: Float = 0
                            for y in -radius...radius { sum += tp.value[(min(qh - 1, max(0, y)) * qw + x) * 3 + ch] }
                            let k = 1 / Float(2 * radius + 1)
                            for y in 0..<qh {
                                sp.value[(y * qw + x) * 3 + ch] = sum * k
                                sum += tp.value[(min(qh - 1, y + radius + 1) * qw + x) * 3 + ch] - tp.value[(max(0, y - radius) * qw + x) * 3 + ch]
                            }
                        }
                    }
                }
            }

            // Everything together, for this strip's own rows.
            let so = UnsafeBufferPointer(start: softBuf, count: qw * qh * 3)
            let soShare = DoodleShare(value: so)
            let inkBytes = DoodleShare(value: inkBuf.assumingMemoryBound(to: UInt8.self))
            let fillBytes = DoodleShare(value: fillBuf.assumingMemoryBound(to: UInt8.self))
            let toneBytes = DoodleShare(value: toneBuf.assumingMemoryBound(to: UInt8.self))
            each(rowB - rowA, parallel: wide) { rowIndex in
                let y = rowA + rowIndex
                let so = soShare.value
                let (gR, gG, gB, iR, iG, iB, mo, te) = arrays.value
                let fy = (Float(y) + 0.5) / Float(height) * Float(ch) - 0.5
                let ry0 = max(0, min(ch - 1, Int(fy.rounded(.down)))), ry1 = min(ch - 1, ry0 + 1)
                let ty = max(0, min(1, fy - Float(ry0)))
                let sy = (Float(y - top) + 0.5) / 4 - 0.5
                let sy0 = max(0, min(qh - 1, Int(sy.rounded(.down)))), sy1 = min(qh - 1, sy0 + 1)
                let tsy = max(0, min(1, sy - Float(sy0)))
                let ink = inkBytes.value + (y - top) * bpr, fill = fillBytes.value + (y - top) * bpr, tone = toneBytes.value + (y - top) * bpr
                let line = dest.value + y * destBpr
                let tm = toothSide - 1
                let tileRow = y >> 8
                let fyy = Float(y)
                let invFill: Float = 1 / 255
                gR.withUnsafeBufferPointer { gR in gG.withUnsafeBufferPointer { gG in gB.withUnsafeBufferPointer { gB in
                iR.withUnsafeBufferPointer { iR in iG.withUnsafeBufferPointer { iG in iB.withUnsafeBufferPointer { iB in
                mo.withUnsafeBufferPointer { mo in te.withUnsafeBufferPointer { te in
                    for x in 0..<width {
                        let fx = (Float(x) + 0.5) / Float(width) * Float(cw) - 0.5
                        let cx0 = max(0, min(cw - 1, Int(fx.rounded(.down)))), cx1 = min(cw - 1, cx0 + 1)
                        let tx = max(0, min(1, fx - Float(cx0)))
                        @inline(__always) func bi(_ a: UnsafeBufferPointer<Float>) -> Float {
                            let p = a[ry0 * cw + cx0] + (a[ry0 * cw + cx1] - a[ry0 * cw + cx0]) * tx
                            let q = a[ry1 * cw + cx0] + (a[ry1 * cw + cx1] - a[ry1 * cw + cx0]) * tx
                            return p + (q - p) * ty
                        }
                        var c = SIMD3<Float>(bi(gR), bi(gG), bi(gB))
                        // The fine tooth is shifted by a different step for each tile, so its repeat never lines up.
                        let t1 = te[((y &+ (x >> 8) &* 89) & tm) * toothSide + ((x &+ tileRow &* 157) & tm)]
                        // The coarse tooth runs at a slant, at a scale that shares nothing with the tile, and is sampled smoothly.
                        let u2 = (Float(x) * 0.809 + fyy * 0.588) * 0.37 + 37.3, v2 = (fyy * 0.809 - Float(x) * 0.588) * 0.37 + 91.7
                        let ufl = u2.rounded(.down), vfl = v2.rounded(.down)
                        let fu = u2 - ufl, fv = v2 - vfl
                        let iu = Int(ufl) & tm, iv = Int(vfl) & tm, iu1 = (iu + 1) & tm, iv1 = (iv + 1) & tm
                        let t2a = te[iv * toothSide + iu] + (te[iv * toothSide + iu1] - te[iv * toothSide + iu]) * fu
                        let t2b = te[iv1 * toothSide + iu] + (te[iv1 * toothSide + iu1] - te[iv1 * toothSide + iu]) * fu
                        let t2 = (t2a + (t2b - t2a) * fv) * 1.5
                        let i4 = x * 4
                        let fa = fill[i4 + 3]
                        if fa > 0 {
                            let m = bi(mo)
                            let sil = Float(fa) * invFill
                            let l = Float(tone[i4 + 1]) * invFill
                            let pc = paperC + (liftedPaperC - paperC) * l
                            c += (pc - c) * (sil * (paperA + (liftedPaperA - paperA) * l) * (1 + 0.3 * m))
                            let a = Float(fill[i4]) * invFill, b = Float(fill[i4 + 1]) * invFill, d = Float(fill[i4 + 2]) * invFill
                            if a + b + d > 0 {
                                let sx = (Float(x) + 0.5) / 4 - 0.5
                                let sx0 = max(0, min(qw - 1, Int(sx.rounded(.down)))), sx1 = min(qw - 1, sx0 + 1)
                                let tsx = max(0, min(1, sx - Float(sx0)))
                                @inline(__always) func sb(_ ch: Int) -> Float {
                                    let p = so[(sy0 * qw + sx0) * 3 + ch] + (so[(sy0 * qw + sx1) * 3 + ch] - so[(sy0 * qw + sx0) * 3 + ch]) * tsx
                                    let q = so[(sy1 * qw + sx0) * 3 + ch] + (so[(sy1 * qw + sx1) * 3 + ch] - so[(sy1 * qw + sx0) * 3 + ch]) * tsx
                                    return p + (q - p) * tsy
                                }
                                // Pigment: mottled inside, gathered where the wash stops.
                                let lay = 0.86 + 0.42 * m + t2 * 0.10
                                if a > 0 {
                                    let e = 1 + pool * max(0, 1 - sb(0)) * 2.2
                                    c += (spots[0] + (lifted[0] - spots[0]) * l - c) * min(1, a * spotAlpha[0] * lay * e)
                                }
                                if b > 0 {
                                    let e = 1 + pool * max(0, 1 - sb(1)) * 2.2
                                    c += (spots[1] + (lifted[1] - spots[1]) * l - c) * min(1, b * spotAlpha[1] * lay * e)
                                }
                                if d > 0 {
                                    let e = 1 + pool * max(0, 1 - sb(2)) * 2.2
                                    c += (spots[2] + (lifted[2] - spots[2]) * l - c) * min(1, d * spotAlpha[2] * lay * e)
                                }
                            }
                        }
                        let sh = tone[i4], ac = tone[i4 + 2]
                        if sh > 0 { c += (shadeC - c) * (Float(sh) * invFill * shadeA) }
                        if ac > 0 { c += (accentC - c) * (Float(ac) * invFill * accentA) }
                        let ia = ink[i4], ga = ink[i4 + 1], da = ink[i4 + 2]
                        if ia > 0 {
                            let cov = Float(ia) * invFill
                            // Ink on tooth: it takes a little less evenly at its edge and in its body.
                            let take = max(0, min(1, inkA * (0.93 + t1 * 0.10 + t2 * 0.05)))
                            let inkC = SIMD3<Float>(bi(iR), bi(iG), bi(iB))
                            c += (inkC - c) * (cov * take)
                        }
                        if da > 0 {
                            let cov = Float(da) * invFill
                            let take = max(0, min(1, detailA * (0.93 + t1 * 0.10 + t2 * 0.05)))
                            let inkC = SIMD3<Float>(bi(iR), bi(iG), bi(iB))
                            c += (inkC - c) * (cov * take)
                        }
                        if ga > 0 {
                            let cov = Float(ga) * invFill
                            c += (gelC - c) * (cov * gelA)
                        }
                        if hasGrain {
                            let g = (t1 * 0.7 + t2 * 0.6) * toothAmount
                            c += SIMD3<Float>(g, g, g)
                        }
                        let brightest = max(c.x, c.y, c.z)
                        if brightest > ceiling { c *= ceiling / brightest }
                        line[i4] = UInt8(max(0, min(255, c.x * 255 + 0.5)))
                        line[i4 + 1] = UInt8(max(0, min(255, c.y * 255 + 0.5)))
                        line[i4 + 2] = UInt8(max(0, min(255, c.z * 255 + 0.5)))
                        line[i4 + 3] = 255
                    }
                } } } } } } } }
            }
        }
        return out.makeImage()
    }
}

nonisolated extension DoodlePainter {
    /// The same print, with the picture's `unit` given, for sheets of drawings at their real size.
    static func paintSheet(_ lib: [DoodleGlyph], _ items: [DoodleItem], style: DoodleStyle, width: Int, height: Int, unit: Double, seed: UInt64) -> CGImage? {
        paint(lib, items, style: style, width: width, height: height, seed: seed, unitOverride: unit)
    }
}
