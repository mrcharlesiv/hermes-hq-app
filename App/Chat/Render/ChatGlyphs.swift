import UIKit

/// The work trail's glyphs, ported from the web's 24-unit SVG paths (spec 06 §3.1), plus the composer/arrow glyphs.
nonisolated enum ChatGlyph: Sendable, Hashable {
    case thinking, terminal, file, explore, other
    /// A finished subagent's line (a small bot).
    case subagent
    /// [groups] A message another bot delivered (a speech bubble).
    case message
    /// [transcript] A cron run's report (a clock).
    case clock
    /// A /btw answer (a speech bubble with a question mark).
    case aside
    case error
    /// One Line: a reply that finished its steps (a ticked circle).
    case worked
    /// [updates] A note in an update group ("Model changed to …"): a circled i.
    case note

    /// SVG path data in a 24-unit box (stroked, round caps and joins).
    var svg: [String] {
        switch self {
        case .thinking: return ["M8 17c-5-4-3-12 4-12s9 8 4 12M9 20h6M9 17h6"]
        case .terminal: return ["M6 5h12a3 3 0 0 1 3 3v8a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3V8a3 3 0 0 1 3-3z", "m7 9 3 3-3 3m6 0h4"]
        case .file: return ["M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z", "M14 3v5h5M9 13h6M9 17h4"]
        case .explore: return ["M17 11a6 6 0 1 1-12 0a6 6 0 1 1 12 0z", "m20 20-4.5-4.5"]
        case .other: return ["M14.7 6.3a4 4 0 0 0-5.4 5.4L4 17v3h3l5.3-5.3a4 4 0 0 0 5.4-5.4l-2.5 2.5-2.4-.6-.6-2.4z"]
        case .subagent: return ["M7 8h10a3 3 0 0 1 3 3v6a3 3 0 0 1-3 3H7a3 3 0 0 1-3-3v-6a3 3 0 0 1 3-3z", "M12 8V4", "M9.5 13.5v1m5-1v1"]
        case .message: return ["M5 5h14a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-7l-4 3v-3H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2z", "M8 10h8M8 13h5"]
        case .clock: return ["M21 12a9 9 0 1 1-18 0a9 9 0 1 1 18 0z", "M12 7.5V12l3 2"]
        case .aside: return ["M5 4h14a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-7l-4 3v-3H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z",
                             "M10 8.6a2 2 0 1 1 2.9 1.8c-.6.3-.9.8-.9 1.4v.4", "M12 14.4v.1"]
        case .error: return ["M21 12a9 9 0 1 1-18 0a9 9 0 1 1 18 0z", "M12 7v6m0 3v1"]
        case .worked: return ["M21 12a9 9 0 1 1-18 0a9 9 0 1 1 18 0z", "m8 12.5 2.8 2.8 5.2-5.6"]
        case .note: return ["M21 12a9 9 0 1 1-18 0a9 9 0 1 1 18 0z", "M12 11v5", "M12 7.9v.1"]
        }
    }

    var lineWidth: CGFloat { self == .error ? 1.8 : 1.6 }

    /// The glyph as a path scaled to `size` points.
    func path(size: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for d in svg { path.addPath(SVGPath.parse(d)) }
        var t = CGAffineTransform(scaleX: size / 24, y: size / 24)
        return path.copy(using: &t) ?? path
    }
}

/// Minimal SVG path-data parser (M/L/H/V/C/S/Q/T/A/Z, absolute and relative) → CGPath.
nonisolated enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens = Tokenizer(Array(d.utf8))
        var current = CGPoint.zero, start = CGPoint.zero, lastControl: CGPoint?
        var command: UInt8 = 0
        var lastCommand: UInt8 = 0
        while let next = tokens.peekCommandOrNumber() {
            if case .command(let c) = next { command = c; tokens.advance() } else if command == 0 { break }
            let rel = command >= 97   // lowercase
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y) }
            switch command | 0x20 {   // lowercase compare
            case UInt8(ascii: "m"):
                guard let x = tokens.number(), let y = tokens.number() else { return path }
                current = pt(x, y); start = current
                path.move(to: current)
                command = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")   // implicit lineto after moveto
                lastControl = nil
            case UInt8(ascii: "l"):
                guard let x = tokens.number(), let y = tokens.number() else { return path }
                current = pt(x, y); path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "h"):
                guard let x = tokens.number() else { return path }
                current = CGPoint(x: rel ? current.x + x : x, y: current.y); path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "v"):
                guard let y = tokens.number() else { return path }
                current = CGPoint(x: current.x, y: rel ? current.y + y : y); path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "c"):
                guard let x1 = tokens.number(), let y1 = tokens.number(), let x2 = tokens.number(), let y2 = tokens.number(),
                      let x = tokens.number(), let y = tokens.number() else { return path }
                let c1 = pt(x1, y1), c2 = pt(x2, y2), end = pt(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2; current = end
            case UInt8(ascii: "s"):
                guard let x2 = tokens.number(), let y2 = tokens.number(), let x = tokens.number(), let y = tokens.number() else { return path }
                let prevWasCurve = [UInt8(ascii: "c"), UInt8(ascii: "s")].contains(lastCommand | 0x20)
                let c1 = prevWasCurve ? CGPoint(x: 2 * current.x - (lastControl?.x ?? current.x), y: 2 * current.y - (lastControl?.y ?? current.y)) : current
                let c2 = pt(x2, y2), end = pt(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2; current = end
            case UInt8(ascii: "q"):
                guard let x1 = tokens.number(), let y1 = tokens.number(), let x = tokens.number(), let y = tokens.number() else { return path }
                let c = pt(x1, y1), end = pt(x, y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c; current = end
            case UInt8(ascii: "t"):
                guard let x = tokens.number(), let y = tokens.number() else { return path }
                let prevWasQuad = [UInt8(ascii: "q"), UInt8(ascii: "t")].contains(lastCommand | 0x20)
                let c = prevWasQuad ? CGPoint(x: 2 * current.x - (lastControl?.x ?? current.x), y: 2 * current.y - (lastControl?.y ?? current.y)) : current
                let end = pt(x, y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c; current = end
            case UInt8(ascii: "a"):
                guard let rx = tokens.number(), let ry = tokens.number(), let rot = tokens.number(),
                      let large = tokens.flag(), let sweep = tokens.flag(), let x = tokens.number(), let y = tokens.number() else { return path }
                let end = pt(x, y)
                addArc(path, from: current, to: end, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                current = end; lastControl = nil
            case UInt8(ascii: "z"):
                path.closeSubpath(); current = start; lastControl = nil
            default:
                return path
            }
            lastCommand = command
        }
        return path
    }

    /// SVG elliptical arc (endpoint parameterisation) as cubic Béziers.
    private static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                               rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy, y1p = -sinP * dx + cosP * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry, cyp = -coef * ry * x1p / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        func map(_ ux: CGFloat, _ uy: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * ux * cosP - ry * uy * sinP, y: cy + rx * ux * sinP + ry * uy * cosP)
        }
        var t = theta1
        for _ in 0..<segments {
            let t2 = t + step
            let c1 = map(cos(t) - k * sin(t), sin(t) + k * cos(t))
            let c2 = map(cos(t2) + k * sin(t2), sin(t2) - k * cos(t2))
            path.addCurve(to: map(cos(t2), sin(t2)), control1: c1, control2: c2)
            t = t2
        }
    }

    private struct Tokenizer {
        enum Token { case command(UInt8), number }
        let bytes: [UInt8]
        var i = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func skip() {
            while i < bytes.count, bytes[i] == 32 || bytes[i] == 44 || bytes[i] == 10 || bytes[i] == 9 || bytes[i] == 13 { i += 1 }
        }
        mutating func peekCommandOrNumber() -> Token? {
            skip()
            guard i < bytes.count else { return nil }
            let b = bytes[i]
            if (b >= 65 && b <= 90) || (b >= 97 && b <= 122) { return b == 101 || b == 69 ? .number : .command(b) }
            return .number
        }
        mutating func advance() { i += 1 }
        mutating func flag() -> Bool? {
            skip()
            guard i < bytes.count else { return nil }
            let b = bytes[i]; i += 1
            return b == 49
        }
        mutating func number() -> CGFloat? {
            skip()
            let startIndex = i
            if i < bytes.count, bytes[i] == 45 || bytes[i] == 43 { i += 1 }
            var sawDot = false, sawDigit = false
            while i < bytes.count {
                let b = bytes[i]
                if b >= 48 && b <= 57 { sawDigit = true; i += 1 }
                else if b == 46 && !sawDot { sawDot = true; i += 1 }
                else if (b == 101 || b == 69) && sawDigit {
                    i += 1
                    if i < bytes.count, bytes[i] == 45 || bytes[i] == 43 { i += 1 }
                } else { break }
            }
            guard sawDigit, let s = String(bytes: bytes[startIndex..<i], encoding: .ascii), let v = Double(s) else {
                i = startIndex
                return nil
            }
            return CGFloat(v)
        }
    }
}

/// Bubble outlines: one path per (size, corners, tail), cached (spec 06 §2.2).
nonisolated enum BubbleShape {
    struct Key: Hashable {
        var width: CGFloat
        var height: CGFloat
        var mine: Bool
        var joinsAbove: Bool
        var joinsBelow: Bool
        var tail: Bool

        /// [glass-bubbles] The outline glass draws: no tail, its corner as round as the others.
        var withoutTail: Key {
            var key = self
            key.tail = false
            return key
        }
    }

    nonisolated(unsafe) private static var cache: [Key: CGPath] = [:]
    /// The corner the cached paths were made with: a new one (Theme › Bubble Corners) empties the cache.
    nonisolated(unsafe) private static var cachedRadius: CGFloat = -1
    private static let lock = NSLock()

    /// The bubble rect starts at (tailRoom, 0) for a bot bubble (tail hangs to the left) and at (0, 0) for yours.
    static func path(_ key: Key) -> CGPath {
        // [desktoplook] The Desktop Look's box: no tail, never joined corners (not cached: the cache holds the standard
        // look's shapes). [desktop-corners] Its corners are the look's own Corners (the desktop's 4 pt unless another
        // was picked).
        if ThemeTable.current.state.desktopLook {
            let rect = CGRect(x: 0, y: 0, width: key.width, height: key.height).insetBy(dx: 0.5, dy: 0.5)
            let radius = min(ChatMetrics.bubbleRadius, rect.height / 2, rect.width / 2)
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        let r = ChatMetrics.bubbleRadius
        lock.lock()
        if r != cachedRadius { cache.removeAll(); cachedRadius = r }
        if let p = cache[key] { lock.unlock(); return p }
        lock.unlock()
        let p = make(key, radius: r)
        lock.lock()
        if cache.count > 2000 { cache.removeAll() }
        if r == cachedRadius { cache[key] = p }
        lock.unlock()
        return p
    }

    /// The iOS look's outline with a corner of `radius`, not cached: Theme › Bubble Corners previews it as it moves.
    static func path(_ key: Key, radius: CGFloat) -> CGPath { make(key, radius: radius) }

    private static func make(_ k: Key, radius r: CGFloat) -> CGPath {
        let rect = CGRect(x: 0, y: 0, width: k.width, height: k.height)
        // Corners: top-leading, top-trailing, bottom-trailing, bottom-leading (in screen terms). Every corner is Theme ›
        // Bubble Corners, joined to a neighbour or not (owner 2026-11-02: "Can I get them to all match?"); only the
        // tail's corner is square, where the tail grows out of it.
        var tl = r, tr = r, br = r, bl = r
        if k.tail { if k.mine { br = 0 } else { bl = 0 } }
        let maxR = min(rect.width, rect.height) / 2
        tl = min(tl, maxR); tr = min(tr, maxR); br = min(br, maxR); bl = min(bl, maxR)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 { p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr) }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 { p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br) }
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 { p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl) }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 { p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl) }
        p.closeSubpath()
        guard k.tail else { return p }
        // The 8×17 tail starts at the bubble's inner (1 pt border) edge and ends flush with its bottom
        // (web: `left:100%; bottom:-1px` against the padding box).
        let tail = SVGPath.parse(k.mine ? "M0 4H1C1 10.5 3 15.2 8 17H0Z" : "M8 4H7C7 10.5 5 15.2 0 17H8Z")
        let size = ChatMetrics.tailSize
        let originX = k.mine ? rect.maxX - 1 : rect.minX + 1 - size.width
        var t = CGAffineTransform(translationX: originX, y: rect.maxY - size.height)
        guard let moved = tail.copy(using: &t) else { return p }
        return p.union(moved)
    }
}
