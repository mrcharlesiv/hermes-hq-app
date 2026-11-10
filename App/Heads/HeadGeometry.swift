// Shapes head geometry (spec 02 §10.4), ported from the web app's `src/ui-heads/shapes.ts` and `parts.ts`.
// Everything here is in the icon's 1024×1024 space and is pure, so it can be unit-tested against the web
// renderer's output (spec 02 §10.4.9) and computed off the main thread.

import CoreGraphics
import Foundation

// MARK: - Marks: what the renderer draws

/// An sRGB colour as 0xRRGGBB.
nonisolated struct HeadRGB: Hashable, Sendable, CustomStringConvertible {
    var hex: UInt32
    init(_ hex: UInt32) { self.hex = hex }
    var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    var blue: Double { Double(hex & 0xFF) / 255 }
    var description: String { String(format: "#%06X", hex) }
}

nonisolated enum HeadPrimitive: Hashable, Sendable {
    case path(String)                                                    // SVG path data, local coordinates
    case rect(x: Double, y: Double, width: Double, height: Double, rx: Double)
    case circle(cx: Double, cy: Double, r: Double)
    case ellipse(cx: Double, cy: Double, rx: Double, ry: Double)
}

/// One step of an SVG transform list, applied in order (as `transform="translate(…) scale(…) rotate(…)"`).
nonisolated enum HeadTransformStep: Hashable, Sendable {
    case translate(Double, Double)
    case scale(Double)
    case rotate(Double, cx: Double, cy: Double)                          // degrees about a point
}

nonisolated struct HeadStyle: Hashable, Sendable {
    var fill: HeadRGB?
    var fillOpacity: Double = 1
    var stroke: HeadRGB?
    var strokeWidth: Double = 0
    var strokeOpacity: Double = 1
    var opacity: Double = 1
    var roundCap = false
    var roundJoin = false
    static func filled(_ c: HeadRGB) -> HeadStyle { HeadStyle(fill: c) }
    static func stroked(_ c: HeadRGB, _ width: Double, cap: Bool = true, join: Bool = false) -> HeadStyle {
        HeadStyle(fill: nil, stroke: c, strokeWidth: width, roundCap: cap, roundJoin: join)
    }
}

nonisolated struct HeadMark: Hashable, Sendable {
    var primitive: HeadPrimitive
    var transform: [HeadTransformStep] = []
    var style: HeadStyle
}

/// `matrix(k 0 0 k tx ty)` that places the drawn head in the picture, rounded as the web writes it.
nonisolated struct HeadPlacement: Hashable, Sendable {
    var k: Double
    var tx: Double
    var ty: Double
}

/// Everything needed to draw one Shapes head, in 1024 space.
nonisolated struct ShapeHeadLayout: Hashable, Sendable {
    var outline: [CGPoint]            // spline points in 1024 space (unrounded)
    var outlinePath: String           // the outline as the web writes it ("M512 212C528 212 …Z")
    var fill: HeadRGB
    var rim: HeadRGB?                 // 14-unit stroke round a white/black bare shape
    var eyeColor: HeadRGB
    var placement: HeadPlacement?     // nil = drawn as is
    var under: [HeadMark]             // blush, mouth, clear glasses: they stay put
    var face: [HeadMark]              // the eyes (or dark glasses): the part that moves
    var board: (frame: HeadRGB, panel: HeadRGB)?
    var faceCentre: CGPoint           // between the eyes, 1024 space before placement

    static func == (a: ShapeHeadLayout, b: ShapeHeadLayout) -> Bool {
        a.outlinePath == b.outlinePath && a.fill == b.fill && a.rim == b.rim && a.eyeColor == b.eyeColor
            && a.placement == b.placement && a.under == b.under && a.face == b.face
            && a.board?.frame == b.board?.frame && a.board?.panel == b.board?.panel
    }
    func hash(into hasher: inout Hasher) { hasher.combine(outlinePath); hasher.combine(face) }
}

// MARK: - Colours (`robot.ts` TONES, `shapes.ts:113-133`)

nonisolated enum HeadTones {
    static let ink = HeadRGB(0x0A0A0A)
    static func accent(_ c: Head.ColorName) -> HeadRGB { HeadRGB(tones[c]!.accent) }
    static func panel(_ c: Head.ColorName) -> HeadRGB { HeadRGB(tones[c]!.panel) }
    static let tones: [Head.ColorName: (panel: UInt32, accent: UInt32)] = [
        .ink: (0xF7F5F0, 0x2EC4B6), .mint: (0xBDEEDF, 0x1FCFA5), .teal: (0xAEE6EE, 0x22BCD8),
        .sky: (0xBCD9FF, 0x4A93FF), .lilac: (0xD7CCFF, 0x9479FF), .pink: (0xFFC7E1, 0xFF66AD),
        .coral: (0xFFC4B6, 0xFF7057), .peach: (0xFFDAB6, 0xFFA043), .butter: (0xFBE69C, 0xFFCE2E),
        .lime: (0xD6F1A6, 0x96DB3C), .paper: (0xE7E1D3, 0xEFE9DB), .red: (0xF9B8B7, 0xEF3B36),
        .grass: (0xB3E8C6, 0x2DBE60), .forest: (0xB0CEBF, 0x23784E), .cobalt: (0xB4C4FF, 0x2E5BFF),
        .denim: (0xB8C4E0, 0x3A5BA8), .grape: (0xD0B8F9, 0x7C3AED), .plum: (0xD5BAD9, 0x8A3F96),
        .magenta: (0xF4AFD5, 0xE0218A), .rose: (0xFFE2EB, 0xFFAFC8), .wine: (0xE3B4C2, 0xB03055),
        .caramel: (0xECD5C2, 0xC98A55), .cocoa: (0xD5C2B7, 0x8A5638), .slate: (0xCACED4, 0x6B7688),
    ]
}

// MARK: - Geometry

nonisolated enum HeadGeometry {
    static let unit = 300.0
    static let tau = Double.pi * 2

    /// JavaScript's Math.round (halves go up, also for negatives).
    static func jsRound(_ v: Double) -> Double { (v + 0.5).rounded(.down) }
    /// `n` in shapes.ts: one decimal.
    static func n1(_ v: Double) -> Double { jsRound(v * 10) / 10 }
    /// Three decimals (place() and placement scales).
    static func n3(_ v: Double) -> Double { jsRound(v * 1000) / 1000 }

    /// A number as JavaScript prints it ("14.1", "-54", "0").
    static func js(_ v: Double) -> String {
        if v == 0 { return "0" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }

    // ---- parts.ts helpers
    static func around(_ count: Int, _ at: (Double) -> CGPoint) -> [CGPoint] {
        (0..<count).map { at(Double($0) / Double(count) * tau - .pi / 2) }
    }
    static func sampled(_ count: Int, _ at: (Double) -> CGPoint) -> [CGPoint] {
        (0..<count).map { at(Double($0) / Double(count) * tau) }
    }
    static func ring(_ count: Int, dy: Double = 0, _ reach: (Int) -> Double) -> [CGPoint] {
        (0..<count).map { i in
            let a = -Double.pi / 2 + Double(i) * tau / Double(count)
            return CGPoint(x: cos(a) * reach(i), y: sin(a) * reach(i) + dy)
        }
    }
    static func rounded(_ corners: [CGPoint], _ cut: Double) -> [CGPoint] {
        corners.indices.flatMap { i -> [CGPoint] in
            let p = corners[i], a = corners[(i + corners.count - 1) % corners.count], b = corners[(i + 1) % corners.count]
            return [CGPoint(x: p.x + (a.x - p.x) * cut, y: p.y + (a.y - p.y) * cut),
                    CGPoint(x: p.x + (b.x - p.x) * cut, y: p.y + (b.y - p.y) * cut)]
        }
    }
    static func sign(_ v: Double) -> Double { v > 0 ? 1 : v < 0 ? -1 : 0 }
    static func superellipse(_ w: Double, _ h: Double, _ power: Double, _ count: Int = 40) -> [CGPoint] {
        around(count) { t in
            let c = cos(t), s = sin(t)
            return CGPoint(x: sign(c) * pow(abs(c), power) * w, y: sign(s) * pow(abs(s), power) * h)
        }
    }
    static func wobble(_ points: [CGPoint], seed: Int, amount: Double) -> [CGPoint] {
        let a = Double(seed % 997) / 997 * tau, b = Double(seed % 613) / 613 * tau
        return points.map { p in
            let t = atan2(p.y, p.x), k = 1 + amount * (sin(3 * t + a) * 0.6 + sin(5 * t + b) * 0.4)
            return CGPoint(x: p.x * k, y: p.y * k)
        }
    }
    static func cloud() -> [CGPoint] {
        let puffs: [(Double, Double, Double)] = [(-0.58, -0.02, 0.44), (-0.14, -0.36, 0.5), (0.4, -0.26, 0.44), (0.72, 0.08, 0.36)]
        let origin = CGPoint(x: 0, y: 0.12)
        return around(72) { t in
            let d = (cos(t), sin(t))
            var reach = 1 / ((d.0 / 0.98) * (d.0 / 0.98) + (d.1 / 0.4) * (d.1 / 0.4)).squareRoot()
            for (cx, cy, r) in puffs {
                let x = cx - origin.x, y = cy - origin.y, b = d.0 * x + d.1 * y, q = b * b - (x * x + y * y - r * r)
                if q >= 0 { reach = max(reach, b + q.squareRoot()) }
            }
            return CGPoint(x: origin.x + d.0 * reach, y: origin.y + d.1 * reach)
        }
    }

    /// A closed Catmull-Rom spline through the points: the cubic segments, its path data as the web writes it
    /// (integer coordinates) and a dense outline (6 samples per segment).
    static func spline(_ p: [CGPoint]) -> (segments: [(c1: CGPoint, c2: CGPoint, to: CGPoint)], d: String, dense: [CGPoint]) {
        let count = p.count
        var segments: [(CGPoint, CGPoint, CGPoint)] = []
        var dense: [CGPoint] = []
        func r(_ v: Double) -> String { js(jsRound(v)) }
        var d = "M\(r(p[0].x)) \(r(p[0].y))"
        for i in 0..<count {
            let p0 = p[(i - 1 + count) % count], p1 = p[i], p2 = p[(i + 1) % count], p3 = p[(i + 2) % count]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            d += "C\(r(c1.x)) \(r(c1.y)) \(r(c2.x)) \(r(c2.y)) \(r(p2.x)) \(r(p2.y))"
            segments.append((c1, c2, p2))
            for step in 0..<6 {
                let t = Double(step) / 6, u = 1 - t
                let x = u * u * u * p1.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p2.x
                let y = u * u * u * p1.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p2.y
                dense.append(CGPoint(x: x, y: y))
            }
        }
        return (segments, d + "Z", dense)
    }

    /// Each form's outline in unit space and where its face sits `(x, y, size)` (`shapes.ts:26-41`).
    static func form(_ form: Head.Form, seed: Int) -> (outline: [CGPoint], face: (x: Double, y: Double, size: Double)) {
        switch form {
        case .round: return (around(40) { CGPoint(x: cos($0), y: sin($0)) }, (0, -0.04, 1))
        case .blob:
            return (wobble(around(40) { CGPoint(x: cos($0) * 1.05, y: sin($0) * 0.9 + 0.03) }, seed: seed, amount: 0.08),
                    (0, -0.04, 1))
        case .square: return (superellipse(0.93, 0.93, 0.3, 48), (0, -0.04, 1))
        case .pill:
            let points = [-1.0, 1.0].flatMap { side in
                (0...12).map { i -> CGPoint in
                    let a = side * .pi / 2 + Double(i) * .pi / 12
                    return CGPoint(x: -side * 0.42 + cos(a) * 0.66, y: sin(a) * 0.66)
                }
            }
            return (points, (0, -0.02, 0.92))
        case .triangle:
            return (rounded([CGPoint(x: 0, y: -1.04), CGPoint(x: 1.06, y: 0.78), CGPoint(x: -1.06, y: 0.78)], 0.24), (0, 0.3, 0.86))
        case .hex: return (rounded(ring(6) { _ in 1 }, 0.2), (0, -0.02, 1))
        case .cloud: return (cloud().map { CGPoint(x: $0.x * 1.04 - 0.06, y: $0.y * 1.04 + 0.14) }, (-0.02, 0.1, 0.92))
        case .drop:
            return (sampled(48) { t in CGPoint(x: 1.04 * sin(t) * pow(sin(t / 2), 0.8), y: -cos(t) * 1.06 - 0.08) }, (0, 0.34, 0.9))
        case .star: return (rounded(ring(10, dy: 0.08) { $0 % 2 == 1 ? 0.58 : 1.08 }, 0.18), (0, 0.12, 0.78))
        case .heart:
            return (sampled(48) { t in
                let s = sin(t)
                return CGPoint(x: s * s * s * 1.02,
                               y: -(13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)) / 16 - 0.12)
            }, (-0.04, 0.08, 0.9))
        }
    }

    static func pose(_ state: HeadState) -> (at: (x: Double, y: Double), lean: (Double, Double)) {
        switch state {
        case .idle: return ((0.3, -0.28), (-20, -20))
        case .thinking, .speaking: return ((0, 0.02), (0, 0))
        case .done: return ((0, -0.08), (24, -24))
        case .offline: return ((0, 0.1), (90, 90))
        }
    }

    // ---- hats (placement only: hats are never drawn, owner 2026-10-08)
    static let hatBox: [Head.Hat: (Double, Double, Double)] = [
        .crown: (-186, -197, 163), .halo: (-179, -154, 179), .sprout: (-131, -178, 154), .party: (-114, -307, 178),
        .bow: (-59, -64, 206),
    ]
    static func hatSeat(_ head: Head, points: [CGPoint]) -> (x: Double, y: Double, stretch: Double) {
        let fx = form(head.form, seed: head.seed).face.x
        let near = points.filter { abs($0.x - fx) < 0.35 }
        let pool = near.isEmpty ? points : near
        let top = pool.dropFirst().reduce(pool[0]) { $1.y < $0.y ? $1 : $0 }
        let below = points.filter { abs($0.y - (top.y + 0.3)) < 0.12 }
        let half = below.isEmpty ? 160 : below.map { abs($0.x - top.x) }.max()! * unit
        let x = 512 + top.x * unit + (head.hat == .bow ? half * 0.45 - 74 : 0)
        return (x, 512 + top.y * unit, jsRound(max(130, min(190, half)) / 1.6) / 100)
    }

    /// `placing` (`shapes.ts:86-99`): how the head fills the picture. `withHat` only for the test vectors.
    static func placement(_ head: Head, points: [CGPoint], withHat: Bool) -> HeadPlacement? {
        let hat = withHat ? head.hat : .none
        if head.tile != .none { return hat == .none ? nil : HeadPlacement(k: 0.8, tx: 102.4, ty: 160) }
        var drawn = spline(points).dense.map { CGPoint(x: 512 + $0.x * unit, y: 512 + $0.y * unit) }
        if hat != .none {
            let seat = hatSeat(head, points: points)
            let box = hat == .beanie ? (-170 * seat.stretch, -136, 170 * seat.stretch) : hatBox[hat]!
            drawn.append(CGPoint(x: seat.x + box.0, y: seat.y + box.1))
            drawn.append(CGPoint(x: seat.x + box.2, y: seat.y))
        }
        let xs = drawn.map(\.x), ys = drawn.map(\.y)
        let left = xs.min()!, right = xs.max()!, top = ys.min()!, bottom = ys.max()!
        let k = min(984 / (right - left), 984 / (bottom - top))
        return HeadPlacement(k: n3(k), tx: n1(512 - k * (left + right) / 2), ty: n1(512 - k * (top + bottom) / 2))
    }

    // ---- constant markup (`shapes.ts:55-56,102-164`)
    static let star: String = pathData((0..<10).map { i -> CGPoint in
        let a = -Double.pi / 2 + Double(i) * .pi / 5, r = i % 2 == 1 ? 24.0 : 54.0
        return CGPoint(x: cos(a) * r, y: sin(a) * r)
    })
    static let heart: String = pathData(sampled(28) { t in
        let s = sin(t)
        return CGPoint(x: s * s * s * 51, y: 3 - (13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)) / 16 * 51)
    })
    static func pathData(_ points: [CGPoint]) -> String {
        "M" + points.map { "\(js(n1($0.x))) \(js(n1($0.y)))" }.joined(separator: "L") + "Z"
    }
    static let gold = HeadRGB(0xF5C542)
    static let white = HeadRGB(0xFFFFFF)
    static let darkEye = HeadRGB(0x1A1A1A)

    /// Whether inverting the head's light-page picture gives its dark-page one: a black Shapes head with no backdrop
    /// (white on a dark page, its eyes dark) and nothing on it in a colour of its own (pink hearts or cheeks, googly
    /// whites, tinted or gold glasses), which an inversion would turn wrong.
    static func invertsOnDarkPage(_ head: Head) -> Bool {
        // A black dot-matrix head drawn for a light page is black LEDs with gaps for eyes: inverted, white ones.
        if head.theme == .matrix { return head.color == .ink && !head.blush }
        return head.themed == nil && head.color == .ink && head.tile == .none && !head.blush
            && head.look != .hearts && head.look != .googly && (head.specs == .none || head.specs == .round)
    }

    /// The whole layout of a Shapes head: outline, colours, placement and every mark (spec 02 §10.4).
    /// - Parameters:
    ///   - darkPage: the page mode (nil = unknown, as for a desktop mirror).
    ///   - compact: a small picture (side < 64 pt) draws bolder eyes.
    ///   - withHatPlacement: only for the test vectors; drawn heads never wear hats.
    static func layout(_ head: Head, state: HeadState = .idle, compact: Bool, darkPage: Bool?,
                       withHatPlacement: Bool = false) -> ShapeHeadLayout {
        let dark = head.tile == .dark, bare = head.tile == .none
        let panel: HeadRGB = dark ? HeadRGB(0x1C1C1E) : head.tile == .color ? HeadTones.panel(head.color) : HeadRGB(0xF7F5F0)
        let fill: HeadRGB
        switch head.color {
        case .ink: fill = dark || (bare && darkPage == true) ? HeadRGB(0xF4F4F2) : HeadTones.ink
        case .paper: fill = dark || bare ? HeadRGB(0xEFE9DB) : head.tile == .color ? HeadRGB(0xFFFDF8) : HeadRGB(0xD9D0BD)
        default: fill = HeadTones.accent(head.color)
        }
        let rim: HeadRGB? = bare && (head.color == .paper || (head.color == .ink && darkPage == nil))
            ? (head.color == .ink ? HeadRGB(0x636366) : HeadRGB(0xB8AD95)) : nil
        let shape = form(head.form, seed: head.seed)
        let (fx, fy, size) = shape.face
        let points = shape.outline
        let mapped = points.map { CGPoint(x: 512 + $0.x * unit, y: 512 + $0.y * unit) }
        let outlineD = spline(mapped).d

        let p = pose(state), flat = state == .offline
        let look: Head.Look = flat ? .slits : head.look
        let narrow = state == .thinking || state == .speaking ? 0.86 : 1
        let bold = compact ? 1.2 : 1, s = unit * size, googly = look == .googly, glasses = head.specs != .none
        let gap = (glasses ? 0.26 : googly ? 0.24 : 0.2) * s
        let cx = 512 + (fx + p.at.x * size) * unit, cy = 512 + (fy + p.at.y * size) * unit
        let ink = darkPage == true || head.color == .paper || fill == HeadRGB(0xF4F4F2) ? darkEye : white

        /// place(): translate, scale, optional rotate, as `<g transform>` around a body.
        func place(_ x: Double, _ y: Double, _ k: Double, turn: Double = 0, _ body: [HeadMark]) -> [HeadMark] {
            var steps: [HeadTransformStep] = [.translate(n1(x), n1(y)), .scale(n3(k))]
            if turn != 0 { steps.append(.rotate(n1(turn), cx: 0, cy: 0)) }
            return body.map { HeadMark(primitive: $0.primitive, transform: steps + $0.transform, style: $0.style) }
        }
        func eye(_ side: Double) -> [HeadMark] {
            let x = n1(cx + side * gap), y = n1(cy), lean = side < 0 ? p.lean.0 : p.lean.1
            let w = 0.15 * s * bold, h = (flat ? 0.28 : 0.38 * narrow) * s
            switch look {
            case .dots:
                return [HeadMark(primitive: .circle(cx: x, cy: y, r: n1(0.11 * s * bold)), style: .filled(ink))]
            case .ovals:
                return [HeadMark(primitive: .ellipse(cx: x, cy: y, rx: n1(0.11 * s * bold), ry: n1(0.19 * s * narrow)),
                                 transform: [.rotate(lean / 2, cx: x, cy: y)], style: .filled(ink))]
            case .googly:
                var ring = HeadStyle.filled(white); ring.stroke = ink; ring.strokeWidth = 9 * bold
                return place(x, y, size, [
                    HeadMark(primitive: .circle(cx: 0, cy: 0, r: 51), style: ring),
                    HeadMark(primitive: .circle(cx: n1(p.at.x * 60), cy: n1(p.at.y * 60), r: n1(25.5 * bold)),
                             style: .filled(darkEye)),
                ])
            case .happy:
                return place(x, y, size * bold, [HeadMark(primitive: .path("M-39 15Q0-48 39 15"), style: .stroked(ink, 24))])
            case .sleepy:
                return place(x, y, size * bold, [HeadMark(primitive: .path("M-42-9A42 33 0 0 0 42-9Z"), style: .filled(ink))])
            case .stars:
                return place(x, y, size * bold, turn: lean / 2, [HeadMark(primitive: .path(star), style: .filled(ink))])
            case .hearts:
                return place(x, y, size * bold, [HeadMark(primitive: .path(heart), style: .filled(HeadRGB(0xFF4D8D)))])
            case .slits:
                return [HeadMark(primitive: .rect(x: n1(x - w / 2), y: n1(y - h / 2), width: n1(w), height: n1(h), rx: n1(w / 2)),
                                 transform: [.rotate(lean, cx: x, cy: y)], style: .filled(ink))]
            }
        }
        func bridge(_ c: HeadRGB) -> HeadMark {
            var st = HeadStyle.stroked(c, 16.5); st.fill = nil
            return HeadMark(primitive: .path("M-18-30Q0-48 18-30"), style: st)
        }
        // Dark glasses take the eyes' place and move with them.
        let face: [HeadMark]
        switch head.specs {
        case .shades:
            var glint = HeadStyle.stroked(white, 12); glint.strokeOpacity = 0.6
            face = place(cx, cy, size, [
                HeadMark(primitive: .path("M-144-45H-12V6Q-12 51-63 51H-93Q-144 51-144 6ZM12-45H144V6Q144 51 93 51H63Q12 51 12 6Z"),
                         style: .filled(HeadRGB(0x111318))),
                HeadMark(primitive: .path("M-117-18l24-16.5M39-18l24-16.5"), style: glint),
                bridge(HeadRGB(0x111318)),
            ])
        case .aviators:
            var lens = HeadStyle.filled(HeadRGB(0x26323F)); lens.stroke = gold; lens.strokeWidth = 10.5; lens.roundJoin = true
            var glint = HeadStyle.stroked(white, 10.5); glint.strokeOpacity = 0.5
            face = place(cx, cy, size, [
                HeadMark(primitive: .path("M18-42H138Q147 36 87 57Q21 51 18-42ZM-18-42H-138Q-147 36-87 57Q-21 51-18-42Z"), style: lens),
                HeadMark(primitive: .path("M-48-21l-18-12M48-21l18-12"), style: glint),
                bridge(gold),
            ])
        default:
            face = eye(-1) + eye(1)
        }
        // Clear glasses stay on the face, outside the moving eyes.
        func lensRing(_ x: Double, _ c: HeadRGB) -> HeadMark {
            var st = HeadStyle.filled(white); st.fillOpacity = 0.18; st.stroke = c; st.strokeWidth = 15
            return HeadMark(primitive: .circle(cx: x, cy: 0, r: 66), style: st)
        }
        var clear: [HeadMark] = []
        if head.specs == .round {
            clear = place(cx, cy, size, [lensRing(-78, ink), lensRing(78, ink),
                                          HeadMark(primitive: .path("M-15-30Q0-48 15-30"), style: .stroked(ink, 15))])
        } else if head.specs == .monocle {
            clear = place(cx, cy, size, [lensRing(78, gold),
                                          HeadMark(primitive: .path("M123 48q42 78 6 144"), style: .stroked(gold, 7.5, cap: false))])
        }
        var mouth: [HeadMark] = []
        if head.mouth != .none {
            let line = HeadStyle.stroked(ink, n1(19.5 * bold), cap: true, join: true)
            let body: HeadMark
            switch head.mouth {
            case .smile: body = HeadMark(primitive: .path("M-48 0Q0 48 48 0"), style: line)
            case .open: body = HeadMark(primitive: .ellipse(cx: 0, cy: 9, rx: 22.5, ry: 27), style: .filled(ink))
            case .cat: body = HeadMark(primitive: .path("M-48 0Q-24 30 0 0Q24 30 48 0"), style: line)
            default: body = HeadMark(primitive: .path("M-30 6h60"), style: line)
            }
            mouth = place(cx, cy + (googly || glasses ? 0.36 : 0.32) * s, size, [body])
        }
        var blush: [HeadMark] = []
        if head.blush {
            let cheek = n1(gap / size + 42)
            var st = HeadStyle.filled(HeadRGB(0xFF7FA8)); st.opacity = 0.8
            blush = place(cx, cy, size, [HeadMark(primitive: .ellipse(cx: -cheek, cy: 66, rx: 30, ry: 18), style: st),
                                         HeadMark(primitive: .ellipse(cx: cheek, cy: 66, rx: 30, ry: 18), style: st)])
        }
        return ShapeHeadLayout(
            outline: mapped, outlinePath: outlineD, fill: fill, rim: rim, eyeColor: ink,
            placement: placement(head, points: points, withHat: withHatPlacement),
            under: blush + mouth + clear, face: face,
            board: bare ? nil : (frame: dark ? HeadRGB(0x000000) : HeadTones.ink, panel: panel),
            faceCentre: CGPoint(x: cx, y: cy))
    }

    /// How a head moves (`shapeMotion`, `shapes.ts:65-70`): blinks, glance share (0…1).
    static func motion(_ head: Head) -> (blinks: Bool, glance: Double) {
        if head.specs == .round || head.specs == .monocle { return (true, 0) }
        let dark = head.specs == .shades || head.specs == .aviators
        return (!dark && head.look != .happy && head.look != .sleepy, dark || head.mouth != .none ? 0.4 : 1)
    }

    // ---- the icon's board (`parts.ts:8-9`)
    static let frame = "M350 0h324c101 0 151 0 205 17 60 22 106 68 128 128 17 54 17 104 17 205v324c0 101 0 151-17 205-22 60-68 106-128 128-54 17-104 17-205 17h-324c-101 0-151 0-205-17-60-22-106-68-128-128-17-54-17-104-17-205v-324c0-101 0-151 17-205 22-60 68-106 128-128 54-17 104-17 205-17z"
    static let panel = "M322 54h380c77 0 116 0 157 13 46 17 81 52 98 98 13 41 13 80 13 157v380c0 77 0 116-13 157-17 46-52 81-98 98-41 13-80 13-157 13h-380c-77 0-116 0-157-13-46-17-81-52-98-98-13-41-13-80-13-157v-380c0-77 0-116 13-157 17-46 52-81 98-98 41-13 80-13 157-13z"
}
