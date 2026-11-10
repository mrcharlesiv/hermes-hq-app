// Tools the later pictures share: ink laid straight onto the sheet in painter's order, glazes (a ramp that also says how much of
// each ink lands), the view of the design a cropped frame shows, and small drawn things like trees that carry snow.

import CoreGraphics
import Foundation

/// A ramp with coverage: a tone picks an ink and how much of it lands. Used where a layer must let the sky show through.
nonisolated final class PosterGlaze: @unchecked Sendable {
    static let size = 1024
    let lut: UnsafeMutablePointer<UInt8>

    init(_ stops: [(Double, PosterInk, Double)], step: Double) {
        lut = .allocate(capacity: PosterGlaze.size * 4)
        var s = 0
        for i in 0..<PosterGlaze.size {
            let t = Double(i) / Double(PosterGlaze.size - 1)
            while s < stops.count - 2, t > stops[s + 1].0 { s += 1 }
            let a = stops[s], b = stops[min(s + 1, stops.count - 1)]
            var c = a.1
            var o = a.2
            if t < stops[0].0 {
                o = stops[0].2
            } else if b.0 > a.0 {
                let u = min(1, max(0, (t - a.0) / (b.0 - a.0)))
                let w = max(0.001, min(1, step))
                let k = Poster.dsstep(0.5 - 0.5 * w, 0.5 + 0.5 * w, u)
                c = a.1.mixed(with: b.1, k)
                o = a.2 + (b.2 - a.2) * k
            }
            lut[i * 4] = UInt8((min(1, max(0, c.r)) * 255).rounded())
            lut[i * 4 + 1] = UInt8((min(1, max(0, c.g)) * 255).rounded())
            lut[i * 4 + 2] = UInt8((min(1, max(0, c.b)) * 255).rounded())
            lut[i * 4 + 3] = UInt8((min(1, max(0, o)) * 255).rounded())
        }
    }

    deinit { lut.deallocate() }
}

nonisolated extension PosterCanvas {
    /// The part of the design this frame shows.
    var topY: Double { -oy / sx }
    var bottomY: Double { (Double(h) - oy) / sx }

    /// Draws straight onto the sheet, in design units, later shapes over earlier ones.
    func paint(_ draw: (CGContext) -> Void) {
        ctx.saveGState()
        ctx.concatenate(CGAffineTransform(a: sx, b: 0, c: 0, d: sx, tx: ox, ty: oy))
        ctx.setShouldAntialias(true)
        draw(ctx)
        ctx.restoreGState()
    }

    /// Prints a glaze over what is already on the sheet. `t` returns the tone; a negative tone skips the pixel.
    func glaze(_ glaze: PosterGlaze, plate: PosterPlate? = nil, amp: Float, key: Int, rows range: (Int, Int), t: (Double, Double) -> Float) {
        let lut = glaze.lut
        let top = Float(PosterGlaze.size - 1)
        rows(range.0, range.1) { r in
            let y = self.dy(r)
            let line = self.px + r * self.bpr
            let maskLine = plate.map { $0.p + r * self.w }
            for c in 0..<self.w {
                var cov: Int32 = 255
                if let maskLine {
                    cov = Int32(maskLine[c])
                    if cov == 0 { continue }
                }
                let v = t(self.dx(c), y)
                if v < 0 { continue }
                let tone = v + amp * (self.g(c, r, key) - 0.5)
                let i = Int(min(1, max(0, tone)) * top) * 4
                let a = (Int32(lut[i + 3]) * cov) / 255
                if a == 0 { continue }
                let o = line + c * 4
                o[0] = UInt8(Int32(o[0]) + ((Int32(lut[i]) - Int32(o[0])) * a) / 255)
                o[1] = UInt8(Int32(o[1]) + ((Int32(lut[i + 1]) - Int32(o[1])) * a) / 255)
                o[2] = UInt8(Int32(o[2]) + ((Int32(lut[i + 2]) - Int32(o[2])) * a) / 255)
            }
        }
    }
}

nonisolated extension Poster {
    /// A flat ink for `PosterCanvas.paint`.
    static func cg(_ ink: PosterInk) -> CGColor {
        CGColor(colorSpace: BackdropCanvas.space, components: [CGFloat(ink.r), CGFloat(ink.g), CGFloat(ink.b), 1]) ?? CGColor(gray: 0, alpha: 1)
    }

    static func fill(_ g: CGContext, _ ink: PosterInk, _ pts: [PosterP]) {
        g.setFillColor(cg(ink))
        fillPoly(g, pts)
    }

    /// A line of points run through a list of sine waves.
    static func waves(_ x: Double, _ list: [(a: Double, l: Double, p: Double)]) -> Double {
        var s = 0.0
        for w in list { s += w.a * sin(x / w.l + w.p) }
        return s
    }
}

nonisolated extension PosterDraw {
    /// A juniper grown on nothing: a twisted trunk, a few thick limbs that go sideways before they go up, angular pads of foliage at their ends.
    static func juniper(_ rng: inout SplitMix64, x: Double, base: Double, height: Double, lean: Double) -> (wood: [[PosterP]], leaves: [[PosterP]], lit: [[PosterP]]) {
        var wood: [[PosterP]] = [], leaves: [[PosterP]] = [], lit: [[PosterP]] = []
        func pad(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ r: inout SplitMix64) {
            // A pad is a flattened, torn tuft; its underside is cut straighter than its top.
            var o: [PosterP] = []
            let n = 19
            for i in 0..<n {
                let a = Double(i) / Double(n) * 2 * .pi
                let up = sin(a) < 0
                let k = (i % 2 == 0 ? r.next(0.82, 1.18) : r.next(0.5, 0.8)) * (up ? 1 : 0.6)
                o.append(PosterP(cx + cos(a) * rx * k, cy + sin(a) * ry * k))
            }
            leaves.append(o)
            // Only slivers along the top left of a pad have the light.
            for _ in 0..<3 {
                let u = r.next(-0.8, 0.3), w = r.next(0.18, 0.34)
                let y0 = cy - ry * (0.2 + 0.5 * r.next())
                lit.append([PosterP(cx + rx * (u - w), y0 + ry * 0.12), PosterP(cx + rx * u, y0 - ry * r.next(0.12, 0.26)), PosterP(cx + rx * (u + w), y0 + ry * 0.06), PosterP(cx + rx * u, y0 + ry * r.next(0.08, 0.2))])
            }
        }
        func limb(_ px: Double, _ py: Double, _ angle: Double, _ len: Double, _ w: Double, _ depth: Int, _ r: inout SplitMix64) {
            var left: [PosterP] = [], right: [PosterP] = []
            var a = angle, cx = px, cy = py
            let n = 5
            for i in 0...n {
                let u = Double(i) / Double(n)
                let tw = w * (1 - 0.56 * u) * r.next(0.86, 1.14)
                let nx = cos(a + .pi / 2), ny = sin(a + .pi / 2)
                left.append(PosterP(cx + nx * tw * 0.5, cy + ny * tw * 0.5))
                right.append(PosterP(cx - nx * tw * 0.5, cy - ny * tw * 0.5))
                if i < n {
                    a += r.next(-0.42, 0.42)
                    cx += cos(a) * len / Double(n)
                    cy += sin(a) * len / Double(n)
                }
            }
            wood.append(left + right.reversed())
            if depth <= 0 {
                for _ in 0..<6 {
                    let s = height * r.next(0.036, 0.066)
                    pad(cx + r.next(-1.7, 1.7) * s, cy + r.next(-1.1, 0.6) * s, s * 1.4, s * 0.8, &r)
                }
                return
            }
            let kids = depth == 3 ? 3 : (r.next() < 0.5 ? 2 : 3)
            for k in 0..<kids {
                let spread = (Double(k) - Double(kids - 1) * 0.5) * r.next(0.46, 0.84)
                limb(cx, cy, a + spread, len * r.next(0.58, 0.82), w * 0.56, depth - 1, &r)
            }
            if depth < 3 {
                let s = height * r.next(0.04, 0.07)
                pad(cx + r.next(-16, 16), cy - r.next(0, 14), s * 1.5, s * 0.7, &r)
            }
        }
        limb(x, base, -.pi / 2 + lean, height * 0.3, height * 0.07, 3, &rng)
        return (wood, leaves, lit)
    }

    /// An agave: stiff tapering blades from a low heart, each with a lit edge.
    static func agave(_ g: CGContext, x: Double, y: Double, size: Double, dark: PosterInk, lit: PosterInk, rng: inout SplitMix64) {
        let n = 13
        var order = Array(0..<n)
        order.sort { abs(Double($0) - 6) > abs(Double($1) - 6) }
        for i in order {
            let u = Double(i) / Double(n - 1) * 2 - 1
            let a = -.pi / 2 + u * 1.18 + rng.next(-0.05, 0.05)
            let len = size * (1 - 0.3 * abs(u)) * rng.next(0.84, 1.12)
            let w = size * 0.1 * rng.next(0.84, 1.14)
            let tip = PosterP(x + cos(a) * len, y + sin(a) * len + len * 0.1 * abs(u))
            let mid = PosterP(x + cos(a) * len * 0.42, y + sin(a) * len * 0.42)
            let nx = cos(a + .pi / 2), ny = sin(a + .pi / 2)
            Poster.fill(g, dark, [PosterP(x - nx * w * 0.6, y - ny * w * 0.6), PosterP(mid.x - nx * w, mid.y - ny * w), tip, PosterP(mid.x + nx * w, mid.y + ny * w), PosterP(x + nx * w * 0.6, y + ny * w * 0.6)])
            let side = u < 0.3 ? 1.0 : -1.0
            Poster.fill(g, lit, [PosterP(mid.x - nx * w * 0.2 * side, mid.y - ny * w * 0.2 * side), tip, PosterP(mid.x - nx * w * 0.86 * side, mid.y - ny * w * 0.86 * side)])
        }
    }
}

nonisolated extension PosterDraw {
    /// A spruce carrying snow: a dark torn body, and on every bough a load of snow that sits on top, sags with the bough and hangs over its tip.
    /// The side facing the light gets lit loads; the other side gets shaded loads with a thin lit crest.
    static func snowSpruce(_ rng: inout SplitMix64, x: Double, top: Double, base: Double, halfW: Double, tiers: Int, load: Double = 1, lean: Double = 0) -> (body: [PosterP], lit: [[PosterP]], shade: [[PosterP]]) {
        let height = base - top
        var gaps: [Double] = []
        for i in 0..<tiers { gaps.append((rng.next() < 0.3 ? rng.next(1.3, 1.9) : rng.next(0.55, 1.15)) * (0.42 + 0.58 * Double(i + 1) / Double(tiers))) }
        let total = gaps.reduce(0, +)
        var lit: [[PosterP]] = [], shade: [[PosterP]] = []
        func side(_ s: Double, _ r: inout SplitMix64) -> [PosterP] {
            var pts: [PosterP] = []
            var run = 0.0
            for i in 0..<tiers {
                run += gaps[i]
                let t = run / total
                let yy = top + height * t * 0.95
                let cx = x + lean * (1 - t) * height
                let wide = halfW * (0.05 + 0.95 * pow(t, 0.92)) * r.next(0.72, 1.08)
                let droop = wide * r.next(0.2, 0.36) + height * 0.004
                pts.append(PosterP(cx + s * wide * 0.56, yy + droop * 0.42))
                pts.append(PosterP(cx + s * wide, yy + droop))
                var ux = 0.94
                while ux > 0.46 {
                    let back = r.next(0.08, 0.2)
                    pts.append(PosterP(cx + s * wide * (ux - back * 0.3), yy + droop * (0.86 + r.next(0.04, 0.3))))
                    pts.append(PosterP(cx + s * wide * (ux - back), yy + droop * r.next(0.72, 0.9)))
                    ux -= back
                }
                pts.append(PosterP(cx + s * wide * r.next(0.2, 0.34), yy + droop * 0.78))
                // The load.
                // Not every bough carries its share: snow lies in patches, with bare boughs between, so the tree stays a dark form and never a ladder.
                if r.next() < 0.42 { continue }
                let th = (wide * 0.12 + height * 0.003) * load * (r.next() < 0.3 ? r.next(1.2, 1.7) : r.next(0.55, 1.05))
                let n = max(4, min(12, Int(wide / max(3, th * 0.8))))
                let lumps = r.next(1.6, 3.2), phase = r.next(0, 6.28)
                var upper: [PosterP] = [], lower: [PosterP] = [], crest: [PosterP] = []
                for j in 0...n {
                    let u = Double(j) / Double(n)
                    let px = cx + s * wide * (-0.1 + 1.11 * u)
                    let on = yy + droop * pow(u, 1.35) - droop * 0.1
                    let bump = abs(sin(u * .pi * lumps + phase))
                    let env = pow(sin(.pi * min(1, u * 0.96 + 0.02)), 0.46)
                    upper.append(PosterP(px, on - th * (0.62 + 0.62 * bump) * env))
                    lower.append(PosterP(px, on + th * (0.16 + 0.42 * abs(sin(u * .pi * (lumps + 1.3) + phase * 0.7))) * env))
                    crest.append(PosterP(px, on - th * (0.18 + 0.5 * bump) * env))
                }
                let cap = upper + lower.reversed()
                if s < 0 {
                    lit.append(cap)
                } else {
                    shade.append(cap)
                    lit.append(upper + crest.reversed())
                }
            }
            return pts
        }
        var body: [PosterP] = [PosterP(x + lean * height, top)]
        body += side(-1, &rng)
        let tw = height * 0.014
        body.append(PosterP(x - tw, top + height * 0.97))
        body.append(PosterP(x - tw * 1.3, base))
        body.append(PosterP(x + tw * 1.3, base))
        body.append(PosterP(x + tw, top + height * 0.97))
        body += side(1, &rng).reversed()
        return (body, lit, shade)
    }
}

nonisolated extension Poster {
    /// y on a curve through hand-placed points, sorted by x. Smooth, passes through each.
    static func curveY(_ pts: [PosterP], _ x: Double) -> Double {
        if x <= pts[0].x { return pts[0].y }
        if x >= pts[pts.count - 1].x { return pts[pts.count - 1].y }
        var i = 0
        while i < pts.count - 2, x > pts[i + 1].x { i += 1 }
        let a = pts[max(0, i - 1)], b = pts[i], d = pts[i + 1], e = pts[min(pts.count - 1, i + 2)]
        let t = (x - b.x) / max(0.001, d.x - b.x)
        let m0 = (d.y - a.y) / max(0.001, d.x - a.x) * (d.x - b.x), m1 = (e.y - b.y) / max(0.001, e.x - b.x) * (d.x - b.x)
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * b.y + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * d.y + (t3 - t2) * m1
    }

    /// A low swell of ground as a closed shape: its top line and a belly under it.
    static func swell(x0: Double, x1: Double, y0: Double, y1: Double, a: Double, l: Double, p: Double, thick: Double) -> [PosterP] {
        var top: [PosterP] = [], under: [PosterP] = []
        var u = 0.0
        while u <= 1.0001 {
            let x = x0 + (x1 - x0) * u
            let cy = y0 + (y1 - y0) * u + a * sin(x / l + p) + a * 0.4 * sin(x / (l * 0.37) + p * 2.3)
            top.append(PosterP(x, cy))
            under.append(PosterP(x, cy + thick * pow(sin(.pi * pow(u, 0.8)), 1.5)))
            u += 0.012
        }
        return top + under.reversed()
    }
}

nonisolated extension PosterCanvas {
    /// A group of snow-carrying spruces with their shadows on the snow, printed in order: shadow, bodies, shaded loads, lit loads.
    func spruces(_ list: [(x: Double, base: Double, h: Double)], seed: UInt64, body: PosterInk, lit: PosterInk, shade: PosterInk, shadow: PosterInk, shadowOpacity: Double = 0.8, width: ClosedRange<Double> = 0.2...0.26) {
        var r = SplitMix64(seed: seed)
        var bodies: [[PosterP]] = [], lits: [[PosterP]] = [], shades: [[PosterP]] = []
        for t in list {
            let s = PosterDraw.snowSpruce(&r, x: t.x, top: t.base - t.h, base: t.base, halfW: t.h * r.next(width.lowerBound, width.upperBound), tiers: max(6, Int(t.h / 20)))
            bodies.append(s.body)
            lits += s.lit
            shades += s.shade
        }
        let shadowP = PosterPlate(self) { g in
            g.beginPath()
            for t in list { Poster.lens(g, t.x + t.h * 0.3, t.base + 1, t.h * 0.86, t.h * 0.05) }
            g.fillPath()
        }
        flat(shadow, plate: shadowP, opacity: shadowOpacity)
        let bodyP = PosterPlate(self) { g in for b in bodies { Poster.fillPoly(g, b) } }
        flat(body, plate: bodyP)
        let shadeP = PosterPlate(self) { g in for b in shades { Poster.fillPoly(g, b) } }
        flat(shade, plate: shadeP)
        let litP = PosterPlate(self) { g in for b in lits { Poster.fillPoly(g, b) } }
        flat(lit, plate: litP, offset: (reg, 0))
    }

    /// A thin curl of smoke rising from a chimney and drifting left.
    func smoke(_ tops: [(x: Double, y: Double, s: Double)], ink: PosterInk, opacity: Double, seed: UInt64) {
        var r = SplitMix64(seed: seed)
        let p = PosterPlate(self) { g in
            for t in tops {
                var a: [PosterP] = [], b: [PosterP] = []
                let tall = 74 * t.s * r.next(0.8, 1.3), phase = r.next(0, 6)
                for i in 0...12 {
                    let u = Double(i) / 12
                    let sy = t.y - u * tall
                    let sx = t.x - 30 * t.s * u * u + 2.4 * t.s * sin(u * 6 + phase)
                    let w = t.s * (0.9 + 4.6 * u)
                    a.append(PosterP(sx - w, sy))
                    b.append(PosterP(sx + w, sy))
                }
                Poster.fillPoly(g, a + b.reversed())
            }
        }
        flat(ink, plate: p, opacity: opacity)
    }
}

nonisolated extension Poster {
    /// Both banks of a winding band through hand-placed points of a spine, each with its half width.
    static func ribbon(_ spine: [(x: Double, y: Double, w: Double)], steps: Int = 14) -> (left: [PosterP], right: [PosterP]) {
        var l: [PosterP] = [], r: [PosterP] = []
        for i in 0..<(spine.count - 1) {
            let a = spine[max(0, i - 1)], b = spine[i], d = spine[i + 1], e = spine[min(spine.count - 1, i + 2)]
            for s in 0..<steps {
                let t = Double(s) / Double(steps), t2 = t * t, t3 = t2 * t
                let x = 0.5 * (2 * b.x + (d.x - a.x) * t + (2 * a.x - 5 * b.x + 4 * d.x - e.x) * t2 + (3 * b.x - a.x - 3 * d.x + e.x) * t3)
                let y = 0.5 * (2 * b.y + (d.y - a.y) * t + (2 * a.y - 5 * b.y + 4 * d.y - e.y) * t2 + (3 * b.y - a.y - 3 * d.y + e.y) * t3)
                let w = b.w + (d.w - b.w) * t
                let wob = 1 + 0.14 * sin(y / 23) + 0.08 * sin(y / 9.1 + x / 40)
                l.append(PosterP(x - w * wob, y))
                r.append(PosterP(x + w * wob * 0.94, y))
            }
        }
        return (l, r)
    }
}

