// A small SVG path-data reader (M L H V C Q A Z, absolute and relative), so the heads' and icons' markup can be
// carried over verbatim from the web renderer instead of being re-drawn by hand.

import CoreGraphics
import Foundation

nonisolated enum SVGPathData {
    /// Builds a CGPath from SVG path data. Unknown commands end the parse (what was read so far is kept).
    static func path(_ d: String, transform: CGAffineTransform = .identity) -> CGPath {
        let path = CGMutablePath()
        var t = transform
        var scanner = Tokens(d)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var command: Character = "M"
        var lastCommand: Character = " "
        while true {
            if let next = scanner.command() { command = next } else if scanner.atEnd { break }
            else if lastCommand == " " || command == "Z" || command == "z" { break }   // stray numbers: stop
            let relative = command.isLowercase
            let base = relative ? current : .zero
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: base.x + x, y: base.y + y) }
            switch command {
            case "M", "m":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = pt(x, y); start = current
                path.move(to: current, transform: t)
                // Further pairs are implicit line-tos.
                command = relative ? "l" : "L"
            case "L", "l":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = pt(x, y)
                path.addLine(to: current, transform: t)
            case "H", "h":
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current, transform: t)
            case "V", "v":
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current, transform: t)
            case "C", "c":
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x2 = scanner.number(),
                      let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = pt(x1, y1), c2 = pt(x2, y2)
                current = pt(x, y)
                path.addCurve(to: current, control1: c1, control2: c2, transform: t)
            case "Q", "q":
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x = scanner.number(),
                      let y = scanner.number() else { return path }
                let c = pt(x1, y1)
                current = pt(x, y)
                path.addQuadCurve(to: current, control: c, transform: t)
            case "A", "a":
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let x = scanner.number(),
                      let y = scanner.number() else { return path }
                let end = pt(x, y)
                addArc(to: path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large,
                       sweep: sweep, transform: &t)
                current = end
            case "Z", "z":
                path.closeSubpath()
                current = start
            default:
                return path
            }
            lastCommand = command
        }
        return path
    }

    /// SVG elliptical arc (endpoint form), converted to centre form (SVG 1.1 appendix F.6.5).
    private static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rx0: Double, ry ry0: Double,
                               rotation: Double, large: Bool, sweep: Bool, transform: inout CGAffineTransform) {
        var rx = abs(rx0), ry = abs(ry0)
        if p0 == p1 { return }
        if rx == 0 || ry == 0 { path.addLine(to: p1, transform: transform); return }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy, y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : max(0, num / den).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry, cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let unit = CGAffineTransform(scaleX: rx, y: ry)
            .concatenating(CGAffineTransform(rotationAngle: phi))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
            .concatenating(transform)
        path.addRelativeArc(center: .zero, radius: 1, startAngle: theta1, delta: delta, transform: unit)
    }

    /// Tokenizer: commands are letters; numbers follow SVG's compact grammar ("-42-9", ".5.5", "1e-3").
    private struct Tokens {
        let chars: [Character]
        var i = 0
        init(_ text: String) { chars = Array(text) }
        var atEnd: Bool { mutating get { skip(); return i >= chars.count } }
        mutating func skip() { while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" { i += 1 } }
        mutating func command() -> Character? {
            skip()
            guard i < chars.count, chars[i].isLetter, chars[i] != "e", chars[i] != "E" else { return nil }
            defer { i += 1 }
            return chars[i]
        }
        mutating func flag() -> Bool? {
            skip()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            defer { i += 1 }
            return chars[i] == "1"
        }
        mutating func number() -> Double? {
            skip()
            let begin = i
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
            var digits = false, dot = false
            while i < chars.count {
                let c = chars[i]
                if c.isASCII, c.isNumber { digits = true; i += 1 }
                else if c == ".", !dot { dot = true; i += 1 }
                else { break }
            }
            if digits, i < chars.count, chars[i] == "e" || chars[i] == "E" {
                var j = i + 1
                if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
                if j < chars.count, chars[j].isASCII, chars[j].isNumber {
                    i = j
                    while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
                }
            }
            guard digits else { i = begin; return nil }
            return Double(String(chars[begin..<i]))
        }
    }
}
