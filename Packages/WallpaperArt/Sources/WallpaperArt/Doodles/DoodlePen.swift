// The hand: how a drawing is authored and how it is inked.
//
// A drawing (`DoodleGlyph`) is written in a small sketch language in its own coordinates, y down: a path is a list of points
// the curve passes through ("12,30 24,18 ^40,22 z": `^` makes a sharp corner, `z` closes it). A `shape` paints its spot
// colour, knocks out the ink underneath it (so nearer parts hide further parts, as in a real drawing) and outlines
// itself; `line` is plain ink; `hatch` is shading; `blot` is solid ink; `gel` is a light pen on top.
//
// The ink is not a CGContext stroke. Every line becomes a filled ribbon, one for each stretch between corners, the way a
// hand lifts at a corner: it wanders a little, its weight follows the direction of travel like a broad nib, it lands and
// leaves with some taper, and it runs a touch past the corner.

import CoreGraphics
import Foundation

// MARK: Paths

nonisolated struct DoodlePath: ExpressibleByStringInterpolation, Sendable {
    struct Node: Sendable {
        var x, y: Double
        var corner: Bool
    }

    var nodes: [Node]
    var closed: Bool

    init(nodes: [Node], closed: Bool) {
        self.nodes = nodes
        self.closed = closed
    }

    init(stringLiteral s: String) {
        var nodes: [Node] = []
        var closed = false
        for token in s.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            if token == "z" {
                closed = true
                continue
            }
            let corner = token.first == "^"
            let body = corner ? token.dropFirst() : token[...]
            guard let comma = body.firstIndex(of: ","),
                  let x = Double(body[..<comma]), let y = Double(body[body.index(after: comma)...]) else { continue }
            nodes.append(Node(x: x, y: y, corner: corner))
        }
        self.init(nodes: nodes, closed: closed)
    }

    /// Straight lines between `points` (`closed`: and back to the start).
    static func poly(_ points: [(Double, Double)], closed: Bool = false) -> DoodlePath {
        DoodlePath(nodes: points.map { Node(x: $0.0, y: $0.1, corner: true) }, closed: closed)
    }

    /// A curve through `points`.
    static func spline(_ points: [(Double, Double)], closed: Bool = false) -> DoodlePath {
        DoodlePath(nodes: points.map { Node(x: $0.0, y: $0.1, corner: false) }, closed: closed)
    }

    static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, rot: Double = 0, count: Int = 10) -> DoodlePath {
        let c = cos(rot * .pi / 180), s = sin(rot * .pi / 180)
        var nodes: [Node] = []
        for i in 0..<count {
            let a = Double(i) / Double(count) * 2 * .pi
            let x = rx * cos(a), y = ry * sin(a)
            nodes.append(Node(x: cx + c * x - s * y, y: cy + s * x + c * y, corner: false))
        }
        return DoodlePath(nodes: nodes, closed: true)
    }

    static func circle(_ cx: Double, _ cy: Double, _ r: Double) -> DoodlePath { ellipse(cx, cy, r, r, count: r < 3 ? 6 : 10) }

    /// A rounded rectangle, one closed sweep of the pen.
    static func rrect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> DoodlePath {
        let k = r * 0.3
        let p: [(Double, Double)] = [
            (x + r, y), (x + w - r, y), (x + w - k, y + k), (x + w, y + r), (x + w, y + h - r), (x + w - k, y + h - k),
            (x + w - r, y + h), (x + r, y + h), (x + k, y + h - k), (x, y + h - r), (x, y + r), (x + k, y + k),
        ]
        return spline(p, closed: true)
    }

    /// A tapering limb along the curve through `pts`: `w0` wide at the start, `w1` at the tip. For antlers and stems.
    static func taper(_ pts: [(Double, Double)], _ w0: Double, _ w1: Double) -> DoodlePath {
        let line = DoodlePath.spline(pts).flattened(step: 2.2).ring
        guard line.count >= 2 else { return DoodlePath(nodes: [], closed: true) }
        var left: [Node] = [], right: [Node] = []
        for i in line.indices {
            let a = line[max(0, i - 1)], b = line[min(line.count - 1, i + 1)]
            let dx = b.x - a.x, dy = b.y - a.y, l = max(1e-6, hypot(dx, dy))
            let t = Double(i) / Double(line.count - 1)
            let w = (w0 + (w1 - w0) * t) / 2
            left.append(Node(x: line[i].x - dy / l * w, y: line[i].y + dx / l * w, corner: i == 0 || i == line.count - 1))
            right.append(Node(x: line[i].x + dy / l * w, y: line[i].y - dx / l * w, corner: i == 0 || i == line.count - 1))
        }
        return DoodlePath(nodes: left + right.reversed(), closed: true)
    }

    /// Nodes along a run of `n` even scallops from `a` to `b`, bulging to the left of the direction of travel by `depth`,
    /// with a corner between each. Not including `a`.
    static func scallops(_ a: (Double, Double), _ b: (Double, Double), n: Int, depth: Double) -> [Node] {
        var out: [Node] = []
        let dx = b.0 - a.0, dy = b.1 - a.1, l = max(1e-6, hypot(dx, dy))
        let nx = dy / l, ny = -dx / l
        for i in 0..<n {
            let t0 = Double(i) / Double(n), t1 = Double(i + 1) / Double(n), m = (t0 + t1) / 2
            out.append(Node(x: a.0 + dx * m + nx * depth, y: a.1 + dy * m + ny * depth, corner: false))
            out.append(Node(x: a.0 + dx * t1, y: a.1 + dy * t1, corner: true))
        }
        return out
    }

    func moved(_ dx: Double, _ dy: Double) -> DoodlePath {
        DoodlePath(nodes: nodes.map { Node(x: $0.x + dx, y: $0.y + dy, corner: $0.corner) }, closed: closed)
    }

    func scaled(_ k: Double, about c: (Double, Double) = (0, 0)) -> DoodlePath {
        DoodlePath(nodes: nodes.map { Node(x: c.0 + ($0.x - c.0) * k, y: c.1 + ($0.y - c.1) * k, corner: $0.corner) }, closed: closed)
    }

    func rotated(_ degrees: Double, about c: (Double, Double) = (0, 0)) -> DoodlePath {
        let a = degrees * .pi / 180, cs = cos(a), sn = sin(a)
        return DoodlePath(nodes: nodes.map {
            let x = $0.x - c.0, y = $0.y - c.1
            return Node(x: c.0 + cs * x - sn * y, y: c.1 + sn * x + cs * y, corner: $0.corner)
        }, closed: closed)
    }

    func mirrored(about axis: Double) -> DoodlePath {
        DoodlePath(nodes: nodes.map { Node(x: 2 * axis - $0.x, y: $0.y, corner: $0.corner) }, closed: closed)
    }

    /// Runs (one pen stroke per stretch between corners) and the flattened outline.
    func flattened(step: Double = 1.1) -> (ring: [CGPoint], runs: [DoodleRun]) {
        var nodes = nodes
        let n = nodes.count
        guard n >= 2 else { return ([], []) }
        // A closed path with a corner starts at one, so no run is split across the seam.
        if closed, let first = nodes.firstIndex(where: \.corner), first > 0 {
            nodes = Array(nodes[first...]) + Array(nodes[..<first])
        }
        func tangent(_ i: Int) -> (Double, Double) {
            let a = closed || i > 0 ? nodes[(i - 1 + n) % n] : nodes[i]
            let b = closed || i < n - 1 ? nodes[(i + 1) % n] : nodes[i]
            let dx = b.x - a.x, dy = b.y - a.y, l = max(1e-6, hypot(dx, dy))
            return (dx / l, dy / l)
        }
        let segments = closed ? n : n - 1
        var ring: [CGPoint] = [CGPoint(x: nodes[0].x, y: nodes[0].y)]
        var runs: [DoodleRun] = []
        var run: [CGPoint] = ring
        let anyCorner = nodes.contains(where: \.corner)
        for i in 0..<segments {
            let a = nodes[i], b = nodes[(i + 1) % n]
            let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
            let chord = (dx / max(1e-6, len), dy / max(1e-6, len))
            let aFree = a.corner || (!closed && i == 0), bFree = b.corner || (!closed && i + 1 == n - 1)
            if aFree && bFree {
                let p = CGPoint(x: b.x, y: b.y)
                ring.append(p)
                run.append(p)
            } else {
                let t0 = aFree ? chord : tangent(i)
                let t1 = bFree ? chord : tangent((i + 1) % n)
                let c1 = (a.x + t0.0 * len / 3, a.y + t0.1 * len / 3)
                let c2 = (b.x - t1.0 * len / 3, b.y - t1.1 * len / 3)
                let m = max(2, Int((len / step).rounded(.up)))
                for j in 1...m {
                    let t = Double(j) / Double(m), u = 1 - t
                    let x = u * u * u * a.x + 3 * u * u * t * c1.0 + 3 * u * t * t * c2.0 + t * t * t * b.x
                    let y = u * u * u * a.y + 3 * u * u * t * c1.1 + 3 * u * t * t * c2.1 + t * t * t * b.y
                    let p = CGPoint(x: x, y: y)
                    ring.append(p)
                    run.append(p)
                }
            }
            if b.corner && i + 1 < segments {
                runs.append(DoodleRun(pts: run, closed: false, over: true))
                run = [CGPoint(x: b.x, y: b.y)]
            }
        }
        if closed && !anyCorner {
            run.removeLast()
            ring.removeLast()
            runs.append(DoodleRun(pts: run, closed: true, over: false))
        } else {
            runs.append(DoodleRun(pts: run, closed: false, over: anyCorner))
            if closed { ring.removeLast() }
        }
        return (ring, runs)
    }
}

nonisolated struct DoodleRun: Sendable {
    var pts: [CGPoint]
    var closed: Bool
    var over: Bool
}

// MARK: A drawing

nonisolated enum DoodleOp: Sendable {
    case shape(ring: [CGPoint], sep: Int)
    case tint(ring: [CGPoint], sep: Int)
    case ink(runs: [DoodleRun], weight: Double)
    case blot(ring: [CGPoint])
    case gel(runs: [DoodleRun], weight: Double)
    /// A second pass of whatever colour is under it, darker, with a crisp edge and no line: a far leg, a shadow side.
    case shade(ring: [CGPoint])
    /// A deliberate block of the darkest tone: a tent door, a coin slot. Dark in both the Light and the Dark picture.
    case accent(ring: [CGPoint])
}

nonisolated struct DoodleStep: Sendable {
    var op: DoodleOp
    var lod: Double
}

/// One drawing. `minSize`…`maxSize` is how long its longest side may be, in units of the picture's short side.
nonisolated struct DoodleGlyph: @unchecked Sendable {
    var name: String
    var minSize: Double
    var maxSize: Double
    /// How far it may lean, in degrees. Trees and tents stay near upright, dice go anywhere.
    var tilt: Double
    /// True: its spot colours mean something (a flame is warm), so a copy never swaps them.
    var fixed = false
    /// True: a `fixed` drawing whose main colour may still change between copies (a sage bow, a butter flower).
    var recolor = false
    /// True: has writing or a set handedness, so a copy is never mirrored.
    var noFlip = false
    /// True: the picture is about this one, so a big copy always appears.
    var must = false
    /// A drawing the set cannot go without: if the heroes left it out, it gets the first holes after them, once.
    var key = false
    /// An animal or a figure: the edge may not cut it so that only a rump is left.
    var whole = false
    /// Nothing tucks under it and it tucks under nothing: a drawing that turns to mud when something overlaps it.
    var noTuck = false
    /// How readily the packer takes it. Round marks fill any hole perfectly and would crowd everything else out.
    var weight = 1.0
    /// The most copies in one picture; nil is the default (5 for a filler mark, 3 for a drawing).
    var cap: Int?
    /// Where it may sit as a hero, as a share of the picture's height.
    var zone: ClosedRange<Double> = 0...1
    var steps: [DoodleStep] = []
    /// Later steps only show when the drawing is at least this long (a small copy loses its fine detail).
    var lod = 0.0
    private var rng: SplitMix64

    // Finished by `done()`.
    var bbox = CGRect.zero
    var samples: [SIMD2<Float>] = []
    var mask: [UInt8] = []
    /// Only the filled shapes, a touch fattened: what a smaller drawing may tuck behind. Lines do not hide anything.
    var solid: [UInt8] = []
    var coverage = 0.5
    static let maskSide = 72

    init(_ name: String, _ minSize: Double, _ maxSize: Double, tilt: Double = 28, fixed: Bool = false) {
        self.name = name
        self.minSize = minSize
        self.maxSize = maxSize
        self.tilt = tilt
        self.fixed = fixed
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        rng = SplitMix64(seed: h)
    }

    /// A filled, outlined part: spot colour `sep` (0, 1, 2; -1 for bare paper), hiding whatever is under it.
    mutating func shape(_ sep: Int, _ p: DoodlePath, _ w: Double = 1) {
        let f = p.flattened()
        steps.append(DoodleStep(op: .shape(ring: f.ring, sep: sep), lod: lod))
        if w > 0 { steps.append(DoodleStep(op: .ink(runs: f.runs, weight: w), lod: lod)) }
    }

    /// A band: `outer` minus `inner`, filled, and both edges outlined.
    mutating func band(_ sep: Int, outer: DoodlePath, inner: DoodlePath, _ w: Double = 1, innerW: Double? = nil) {
        let a = outer.flattened(), b = inner.flattened()
        let ring = a.ring + [a.ring[0]] + b.ring.reversed() + [b.ring[b.ring.count - 1]]
        steps.append(DoodleStep(op: .shape(ring: ring, sep: sep), lod: lod))
        if w > 0 {
            steps.append(DoodleStep(op: .ink(runs: a.runs, weight: w), lod: lod))
            steps.append(DoodleStep(op: .ink(runs: b.runs, weight: innerW ?? w), lod: lod))
        }
    }

    /// Colour only, no outline, no knocking out.
    mutating func tint(_ sep: Int, _ p: DoodlePath) {
        steps.append(DoodleStep(op: .tint(ring: p.flattened().ring, sep: sep), lod: lod))
    }

    /// Paints nothing, but counts as part of the drawing, so nothing gets packed in here (under a bear's belly, say).
    mutating func keepClear(_ p: DoodlePath) {
        steps.append(DoodleStep(op: .tint(ring: p.flattened().ring, sep: -2), lod: lod))
    }

    mutating func line(_ p: DoodlePath, _ w: Double = 1) {
        steps.append(DoodleStep(op: .ink(runs: p.flattened().runs, weight: w), lod: lod))
    }

    mutating func blot(_ p: DoodlePath) {
        steps.append(DoodleStep(op: .blot(ring: p.flattened().ring), lod: lod))
    }

    mutating func gel(_ p: DoodlePath, _ w: Double = 0.9) {
        steps.append(DoodleStep(op: .gel(runs: p.flattened().runs, weight: w), lod: lod))
    }

    /// The same colour again, darker, no line.
    mutating func shade(_ p: DoodlePath) {
        steps.append(DoodleStep(op: .shade(ring: p.flattened().ring), lod: lod))
    }

    /// A solid block of the darkest tone.
    mutating func accent(_ p: DoodlePath) {
        steps.append(DoodleStep(op: .accent(ring: p.flattened().ring), lod: lod))
    }

    mutating func detail(_ size: Double, _ body: (inout DoodleGlyph) -> Void) {
        let old = lod
        lod = max(lod, size)
        body(&self)
        lod = old
    }

    /// Whatever `body` draws, and then again reflected about x = `axis`.
    mutating func mirror(_ axis: Double, _ body: (inout DoodleGlyph) -> Void) {
        let before = steps.count
        body(&self)
        let added = Array(steps[before...])
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: 2 * axis - p.x, y: p.y) }
        func mr(_ runs: [DoodleRun]) -> [DoodleRun] { runs.map { DoodleRun(pts: $0.pts.map(m), closed: $0.closed, over: $0.over) } }
        for step in added {
            switch step.op {
            case let .shape(ring, sep): steps.append(DoodleStep(op: .shape(ring: ring.map(m), sep: sep), lod: step.lod))
            case let .tint(ring, sep): steps.append(DoodleStep(op: .tint(ring: ring.map(m), sep: sep), lod: step.lod))
            case let .ink(runs, w): steps.append(DoodleStep(op: .ink(runs: mr(runs), weight: w), lod: step.lod))
            case let .blot(ring): steps.append(DoodleStep(op: .blot(ring: ring.map(m)), lod: step.lod))
            case let .gel(runs, w): steps.append(DoodleStep(op: .gel(runs: mr(runs), weight: w), lod: step.lod))
            case let .shade(ring): steps.append(DoodleStep(op: .shade(ring: ring.map(m)), lod: step.lod))
            case let .accent(ring): steps.append(DoodleStep(op: .accent(ring: ring.map(m)), lod: step.lod))
            }
        }
    }

    /// Parallel strokes across the region `p`, `angle` degrees from level, `gap` apart.
    mutating func hatch(_ p: DoodlePath, angle: Double, gap: Double, w: Double = 0.62) {
        let ring = p.flattened(step: 2).ring
        guard ring.count >= 3 else { return }
        let a = angle * .pi / 180, c = cos(a), s = sin(a)
        // Into hatch space, where the strokes run along x.
        let q = ring.map { CGPoint(x: c * $0.x + s * $0.y, y: -s * $0.x + c * $0.y) }
        let lo = q.map(\.y).min() ?? 0, hi = q.map(\.y).max() ?? 0
        var y = lo + gap * 0.5
        var runs: [DoodleRun] = []
        while y < hi {
            var xs: [Double] = []
            for i in q.indices {
                let u = q[i], v = q[(i + 1) % q.count]
                if (u.y <= y) != (v.y <= y) { xs.append(u.x + (y - u.y) / (v.y - u.y) * (v.x - u.x)) }
            }
            xs.sort()
            var i = 0
            while i + 1 < xs.count {
                let inset = gap * 0.15
                var x0 = xs[i] + inset, x1 = xs[i + 1] - inset
                let l = x1 - x0
                if l > gap * 0.5 {
                    // A hand does not stop on the edge every time.
                    x0 += l * rng.next(0, 0.1)
                    x1 -= l * rng.next(0, 0.22)
                    let yy = y + rng.next(-0.12, 0.12) * gap
                    let a0 = CGPoint(x: c * x0 - s * yy, y: s * x0 + c * yy)
                    let a1 = CGPoint(x: c * x1 - s * yy, y: s * x1 + c * yy)
                    runs.append(DoodleRun(pts: [a0, a1], closed: false, over: false))
                }
                i += 2
            }
            y += gap * rng.next(0.85, 1.15)
        }
        steps.append(DoodleStep(op: .ink(runs: runs, weight: w), lod: lod))
    }

    /// Short dashes along `p`, a line of stitches.
    mutating func stitch(_ p: DoodlePath, dash: Double = 3, gap: Double = 2.6, w: Double = 0.6) {
        let pts = p.flattened(step: 0.8).ring
        guard pts.count >= 2 else { return }
        var runs: [DoodleRun] = []
        var cur: [CGPoint] = [pts[0]]
        var travelled = 0.0, drawing = true, limit = dash
        for i in 1..<pts.count {
            let d = hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
            travelled += d
            if drawing { cur.append(pts[i]) }
            if travelled >= limit {
                travelled = 0
                if drawing {
                    runs.append(DoodleRun(pts: cur, closed: false, over: false))
                    cur = []
                    drawing = false
                    limit = gap
                } else {
                    cur = [pts[i]]
                    drawing = true
                    limit = dash
                }
            }
        }
        if drawing, cur.count > 1 { runs.append(DoodleRun(pts: cur, closed: false, over: false)) }
        steps.append(DoodleStep(op: .ink(runs: runs, weight: w), lod: lod))
    }

    /// Finds the drawing's box and what it covers, for packing.
    mutating func done() {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func grow(_ p: CGPoint) {
            minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        for step in steps {
            switch step.op {
            case let .shape(ring, _), let .tint(ring, _), let .blot(ring), let .shade(ring), let .accent(ring): ring.forEach(grow)
            case let .ink(runs, _), let .gel(runs, _): runs.forEach { $0.pts.forEach(grow) }
            }
        }
        bbox = CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
        // The silhouette on a small square, longest side nearly filling it.
        let side = Self.maskSide
        let longest = max(bbox.width, bbox.height)
        let k = Double(side - 6) / longest
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue), let data = ctx.data else { return }
        ctx.setAllowsAntialiasing(false)
        ctx.setShouldAntialias(false)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -bbox.midX, y: -bbox.midY)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setLineWidth(max(1.2, 2.2 / k))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for step in steps where step.lod == 0 {
            switch step.op {
            case let .shape(ring, _), let .tint(ring, _), let .blot(ring), let .accent(ring):
                ctx.addLines(between: ring)
                ctx.closePath()
                ctx.fillPath()
            case let .ink(runs, _), let .gel(runs, _):
                for run in runs {
                    ctx.addLines(between: run.pts)
                    ctx.strokePath()
                }
            case .shade:
                break
            }
        }
        let raw = data.bindMemory(to: UInt8.self, capacity: side * side)
        mask = Array(UnsafeBufferPointer(start: raw, count: side * side))
        // The filled shapes alone, fattened by one cell, so a tucked drawing can pass under its own outline.
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: bbox.midX - Double(side) / k, y: bbox.midY - Double(side) / k, width: 2 * Double(side) / k, height: 2 * Double(side) / k))
        ctx.setFillColor(gray: 1, alpha: 1)
        for step in steps where step.lod == 0 {
            if case let .shape(ring, _) = step.op {
                ctx.addLines(between: ring)
                ctx.closePath()
                ctx.fillPath()
            }
        }
        var fat = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side where raw[y * side + x] > 127 {
                for yy in max(0, y - 1)...min(side - 1, y + 1) {
                    for xx in max(0, x - 1)...min(side - 1, x + 1) { fat[yy * side + xx] = 255 }
                }
            }
        }
        solid = fat
        // Sample points: the outline first (what collides), then a sparse interior, in a shuffled order so a misfit is
        // usually found quickly. In units where the longest side is 1, centred.
        var edge: [SIMD2<Float>] = [], inner: [SIMD2<Float>] = []
        var filled = 0
        for y in 0..<side {
            for x in 0..<side where mask[y * side + x] > 127 {
                filled += 1
                let isEdge = x == 0 || y == 0 || x == side - 1 || y == side - 1 || mask[y * side + x - 1] < 128 || mask[y * side + x + 1] < 128
                    || mask[(y - 1) * side + x] < 128 || mask[(y + 1) * side + x] < 128
                let p = SIMD2<Float>(Float((Double(x) + 0.5 - Double(side) / 2) / (k * longest)), Float((Double(y) + 0.5 - Double(side) / 2) / (k * longest)))
                if isEdge {
                    if (x + y) % 2 == 0 { edge.append(p) }
                } else if x % 4 == 0 && y % 4 == 0 {
                    inner.append(p)
                }
            }
        }
        var order = SplitMix64(seed: 0x51ED)
        samples = edge + inner
        if samples.count > 1 {
            for i in stride(from: samples.count - 1, to: 0, by: -1) {
                samples.swapAt(i, Int(order.next() * Double(i + 1)))
            }
        }
        coverage = Double(filled) / (Double(side - 6) * Double(side - 6))
    }
}

// MARK: The pen

nonisolated enum DoodlePen {
    /// A smooth wander along a line, roughly -1…1.
    @inline(__always) static func wander(_ x: Double, _ seed: UInt64) -> Double {
        let f = x.rounded(.down)
        let t = x - f
        let i = Int64(f)
        @inline(__always) func h(_ i: Int64) -> Double {
            var z = (UInt64(bitPattern: i) &* 0x9E37_79B9_7F4A_7C15) ^ seed
            z = (z ^ (z >> 29)) &* 0xBF58_476D_1CE4_E5B9
            z ^= z >> 32
            return Double(z >> 11) * (2.0 / 9007199254740992.0) - 1
        }
        let u = t * t * (3 - 2 * t)
        return h(i) * (1 - u) + h(i + 1) * u
    }

    /// `pts` (in picture pixels) as a filled ribbon of ink. `px` is one reference pixel (a 1179 wide phone's) in picture
    /// pixels, `base` the pen's width in reference pixels.
    static func ribbon(_ pts: [CGPoint], closed: Bool, over: Bool, base: Double, px: Double, rng: inout SplitMix64, into path: CGMutablePath,
                       wobble: Double = 1) {
        guard pts.count >= 2 else { return }
        var cum = [Double](repeating: 0, count: pts.count + (closed ? 1 : 0))
        for i in 1..<cum.count {
            let a = pts[i - 1], b = pts[i % pts.count]
            cum[i] = cum[i - 1] + hypot(b.x - a.x, b.y - a.y)
        }
        let total = cum[cum.count - 1]
        guard total > 0.4 * px else { return }
        let ds = max(0.9, 3.0 * px)
        let overlap = closed ? min(total * 0.12, 11 * px) : 0
        let startAt = closed ? rng.next(0, total) : 0
        let length = total + overlap
        let n = max(3, min(1400, Int(length / ds) + 2))
        var xs = [Double](repeating: 0, count: n), ys = xs
        var seg = 0
        for i in 0..<n {
            var s = startAt + length * Double(i) / Double(n - 1)
            if closed {
                s = s.truncatingRemainder(dividingBy: total)
                if i == 0 || s < cum[seg] { seg = 0 }
            }
            while seg + 2 < cum.count && cum[seg + 1] < s { seg += 1 }
            let a = pts[seg], b = pts[(seg + 1) % pts.count]
            let span = max(1e-9, cum[seg + 1] - cum[seg])
            let t = min(1, max(0, (s - cum[seg]) / span))
            xs[i] = a.x + (b.x - a.x) * t
            ys[i] = a.y + (b.y - a.y) * t
        }
        let s1 = rng.nextUInt64(), s2 = rng.nextUInt64(), s3 = rng.nextUInt64()
        let lenRef = length / px
        let w0 = base * px
        if over {
            // Run a touch past the corner, the way a confident hand does.
            let e0 = rng.next(0.1, 0.8) * w0, e1 = rng.next(0.1, 0.8) * w0
            let d0 = max(1e-6, hypot(xs[1] - xs[0], ys[1] - ys[0])), d1 = max(1e-6, hypot(xs[n - 1] - xs[n - 2], ys[n - 1] - ys[n - 2]))
            let tx0 = (xs[1] - xs[0]) / d0, ty0 = (ys[1] - ys[0]) / d0
            let tx1 = (xs[n - 1] - xs[n - 2]) / d1, ty1 = (ys[n - 1] - ys[n - 2]) / d1
            xs[0] -= tx0 * e0; ys[0] -= ty0 * e0
            xs[n - 1] += tx1 * e1; ys[n - 1] += ty1 * e1
        }
        let shortFade = min(1, lenRef / 26)
        var left = [CGPoint](repeating: .zero, count: n), right = left
        for i in 0..<n {
            let a = i == 0 ? 0 : i - 1, b = i == n - 1 ? n - 1 : i + 1
            var tx = xs[b] - xs[a], ty = ys[b] - ys[a]
            let tl = max(1e-6, hypot(tx, ty))
            tx /= tl; ty /= tl
            let nx = -ty, ny = tx
            let sRef = lenRef * Double(i) / Double(n - 1), toEnd = lenRef - sRef
            // A broad nib held at a steady angle: lines along it are thin, lines across it are full.
            let across = abs(tx * 0.5736 + ty * 0.8192)
            let nib = 0.74 + 0.40 * across
            var press = 1.0
            if closed {
                press = 0.96 * (0.55 + 0.45 * min(1, sRef / 9)) * (0.4 + 0.6 * min(1, toEnd / 9))
                press = max(press, 0.5)
            } else if over {
                press = (0.82 + 0.18 * min(1, sRef / 8)) * (0.72 + 0.28 * min(1, toEnd / 12))
            } else {
                let a = min(1, sRef / 11), b = min(1, toEnd / 18)
                press = (0.5 + 0.5 * a * (2 - a)) * (0.22 + 0.78 * b * (2 - b))
            }
            let w = w0 * nib * press * (1 + 0.15 * wander(sRef / 36, s3)) * 0.5
            let anchor = over ? 0.35 + 0.65 * min(1, min(sRef, toEnd) / 14) : 1
            let drift = wobble * shortFade * anchor * px * (1.15 * wander(sRef / 62, s1) + 0.34 * wander(sRef / 14, s2))
            let x = xs[i] + nx * drift, y = ys[i] + ny * drift
            left[i] = CGPoint(x: x + nx * w, y: y + ny * w)
            right[i] = CGPoint(x: x - nx * w, y: y - ny * w)
        }
        path.move(to: left[0])
        for i in 1..<n { path.addLine(to: left[i]) }
        // Round the tip.
        let tipX = xs[n - 1] + (xs[n - 1] - xs[n - 2]) / max(1e-6, hypot(xs[n - 1] - xs[n - 2], ys[n - 1] - ys[n - 2])) * w0 * 0.2
        let tipY = ys[n - 1] + (ys[n - 1] - ys[n - 2]) / max(1e-6, hypot(xs[n - 1] - xs[n - 2], ys[n - 1] - ys[n - 2])) * w0 * 0.2
        path.addLine(to: CGPoint(x: tipX, y: tipY))
        for i in stride(from: n - 1, through: 0, by: -1) { path.addLine(to: right[i]) }
        path.closeSubpath()
    }
}
