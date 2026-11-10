import SwiftMath
import UIKit

// [transcript] Typeset formulas (docs/spec/3x-transcript.md §3.5). Tester 2026-11-09, on both the Mac and the iPhone:
// "both apps have some math rendering, but it is incomplete … environments such as aligned, cases, and matrices often
// don't render properly." `MathText.readable` turns a small TeX subset into Unicode text and shows everything else as
// its source. A formula is now set as TeX sets it (SwiftMath, Vendor/SwiftMath, in Latin Modern Math): fractions,
// roots, sums with limits, matrices, cases, aligned equations. It is measured when the reply is rendered (the
// transcript measures every row ahead of drawing) and drawn when the row draws, in the text's colour at that moment,
// so dark mode and a bubble's own ink need nothing. What SwiftMath can't set falls back to the readable text, and
// that to the source, as before.

nonisolated enum MathTypeset {
    /// Latin Modern's letters are smaller than San Francisco's at the same size: a formula is set this much larger
    /// than the words around it, so its x sits level with theirs.
    static let sizeRatio: CGFloat = 1.12
    /// A formula inside a sentence may stand this much taller than the words' line before it is set smaller.
    static let inlineHeightRatio: CGFloat = 2.4
    /// The smallest a formula is set to fit (a line's height, a bubble's width); one that needs less is left to the
    /// fallbacks (a display formula's source card scrolls sideways).
    static let smallest: CGFloat = 0.5
    /// The widest a display formula is set: a phone bubble's words, or a Mac window's narrowest chat column.
    static var blockWidth: CGFloat { ProcessInfo.processInfo.isMacCatalystApp ? 520 : 300 }

    /// TeX that only typesetting shows as written: stacked, rooted, with limits, or laid out in rows. An inline formula
    /// without any (E = mc², x₁ + x₂, α ≤ β) stays the readable text it was: words that wrap, select and are found
    /// with the sentence around them.
    static let structures = ["\\frac", "\\dfrac", "\\tfrac", "\\sqrt", "\\sum", "\\prod", "\\int", "\\oint", "\\lim", "\\binom",
                             "\\begin", "\\over", "\\under", "\\hat", "\\vec", "\\bar", "\\tilde", "\\dot", "\\mathbb",
                             "\\mathcal", "\\mathfrak", "\\left", "\\big", "\\Big", "\\substack", "\\stackrel", "\\boldsymbol", "\\bm"]

    static func needsTypesetting(_ source: String) -> Bool {
        if structures.contains(where: source.contains) { return true }
        // A script of more than one character, or a script on a script, has no Unicode small letters to stand in.
        return source.range(of: #"[\^_]\{[^{}]{2,}\}|[\^_]\{[^{}]*[\^_]"#, options: .regularExpression) != nil
    }

    /// TeX the chat models write that SwiftMath has no name for, in its own words: the numbered environments are
    /// their unnumbered bodies, and a number or a label has nowhere to show.
    static func prepared(_ source: String) -> String {
        var out = source.trimmingCharacters(in: .whitespacesAndNewlines)
        for name in ["equation*", "equation", "displaymath", "math"] {
            out = out.replacingOccurrences(of: "\\begin{\(name)}", with: "").replacingOccurrences(of: "\\end{\(name)}", with: "")
        }
        for (from, to) in [("align*", "aligned"), ("align", "aligned"), ("gather*", "gather"), ("gathered", "gather"),
                           ("multline*", "gather"), ("multline", "gather"), ("eqnarray*", "eqnarray"),
                           ("dcases", "cases"), ("pmatrix*", "pmatrix"), ("bmatrix*", "bmatrix"), ("matrix*", "matrix")] {
            out = out.replacingOccurrences(of: "\\begin{\(from)}", with: "\\begin{\(to)}")
                .replacingOccurrences(of: "\\end{\(from)}", with: "\\end{\(to)}")
        }
        // An array is a matrix without its column letters; a box and a brace have no drawing here, their content does.
        out = out.replacingOccurrences(of: #"\\begin\{array\}\s*\{[^{}]*\}"#, with: #"\\begin{matrix}"#, options: .regularExpression)
            .replacingOccurrences(of: "\\end{array}", with: "\\end{matrix}")
        for name in ["\\boxed", "\\underbrace", "\\overbrace", "\\displaystyle", "\\textstyle"] {
            out = out.replacingOccurrences(of: name, with: "")
        }
        for pattern in [#"\\label\{[^{}]*\}"#, #"\\tag\*?\{[^{}]*\}"#, #"\\(nonumber|notag)\b"#] {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        for (from, to) in [("\\dfrac", "\\frac"), ("\\tfrac", "\\frac"), ("\\dbinom", "\\binom"), ("\\tbinom", "\\binom"),
                           ("\\lVert", "\\|"), ("\\rVert", "\\|"), ("\\lvert", "|"), ("\\rvert", "|"),
                           ("\\mathds", "\\mathbb"), ("\\bigl", ""), ("\\bigr", ""), ("\\Bigl", ""), ("\\Bigr", ""),
                           ("\\biggl", ""), ("\\biggr", ""), ("\\Biggl", ""), ("\\Biggr", "")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a formula measures set at `size`: nil when SwiftMath can't read it.
    static func measure(_ latex: String, size: CGFloat, block: Bool) -> (width: CGFloat, ascent: CGFloat, descent: CGFloat)? {
        guard let display = line(latex, size: size, block: block) else { return nil }
        return (display.width, display.ascent, display.descent)
    }

    fileprivate static func line(_ latex: String, size: CGFloat, block: Bool) -> HQMathLine? {
        guard let line = HQMathLine(latex: latex, size: size, block: block),
              line.width > 0, line.width.isFinite, line.ascent.isFinite, line.descent.isFinite else { return nil }
        return line
    }

    /// The formula as an attachment at the words' size: set smaller when it is taller than `maxHeight` or wider than
    /// `maxWidth`, nil when it can't be set or would have to be set smaller than `smallest`.
    static func attachment(_ source: String, block: Bool, base: UIFont, maxHeight: CGFloat? = nil, maxWidth: CGFloat? = nil) -> MathAttachment? {
        guard source.count <= MathText.maxLength else { return nil }
        let latex = prepared(source)
        guard !latex.isEmpty else { return nil }
        var size = (base.pointSize * sizeRatio * 2).rounded() / 2
        guard var fit = measure(latex, size: size, block: block) else { return nil }
        var scale: CGFloat = 1
        if let maxHeight, fit.ascent + fit.descent > maxHeight { scale = min(scale, maxHeight / (fit.ascent + fit.descent)) }
        if let maxWidth, fit.width > maxWidth { scale = min(scale, maxWidth / fit.width) }
        if scale < 1 {
            guard scale >= smallest else { return nil }
            size = (size * scale * 2).rounded(.down) / 2
            guard let smaller = measure(latex, size: size, block: block) else { return nil }
            fit = smaller
        }
        return MathAttachment(latex: latex, block: block, size: size, width: fit.width, ascent: fit.ascent, descent: fit.descent)
    }

    /// The attachment as text: one character in the words' font and colour that copies as the formula's source.
    static func attributed(_ attachment: MathAttachment, base: UIFont, color: UIColor, copy: String?) -> NSAttributedString {
        let out = NSMutableAttributedString(attachment: attachment)
        var attrs: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: color]
        if let copy { attrs[.chatCopy] = copy }
        out.addAttributes(attrs, range: NSRange(location: 0, length: out.length))
        return out
    }
}

/// A typeset formula in a reply's text: sized when made, drawn (and kept, per colour) when its row draws.
nonisolated final class MathAttachment: NSTextAttachment, @unchecked Sendable {
    let latex: String
    let block: Bool
    let size: CGFloat
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    /// Room around the ink, so an italic's overhang isn't cut.
    static let pad: CGFloat = 1
    private let lock = NSLock()
    private var drawn: [String: UIImage] = [:]

    init(latex: String, block: Bool, size: CGFloat, width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        self.latex = latex
        self.block = block
        self.size = size
        self.width = width
        self.ascent = ascent
        self.descent = descent
        super.init(data: nil, ofType: nil)
        // Its baseline on the line's: the descent hangs below it.
        bounds = CGRect(x: 0, y: -(descent + Self.pad).rounded(.up), width: (width + 2 * Self.pad).rounded(.up),
                        height: (ascent + Self.pad).rounded(.up) + (descent + Self.pad).rounded(.up))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// TextKit 1 (the transcript's rows, `TextLayout`).
    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        let storage = textContainer?.layoutManager?.textStorage
        let color = storage.flatMap { charIndex < $0.length ? $0.attribute(.foregroundColor, at: charIndex, effectiveRange: nil) as? UIColor : nil }
        return picture(color ?? .label)
    }

    /// TextKit 2 (a label or a text view given the same text).
    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> UIImage? {
        picture(attributes[.foregroundColor] as? UIColor ?? .label)
    }

    /// The formula in `color` as it resolves now (the row draws under its own traits).
    func picture(_ color: UIColor) -> UIImage? {
        let ink = color.resolvedColor(with: UITraitCollection.current)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ink.getRed(&r, green: &g, blue: &b, alpha: &a)
        let key = "\(Int(r * 255)).\(Int(g * 255)).\(Int(b * 255)).\(Int(a * 255))"
        lock.lock()
        defer { lock.unlock() }
        if let known = drawn[key] { return known }
        guard let display = MathTypeset.line(latex, size: size, block: block) else { return nil }
        let size = bounds.size
        let floor = (descent + Self.pad).rounded(.up)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            cg.saveGState()
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            display.draw(in: cg, at: CGPoint(x: Self.pad, y: floor), color: ink)
            cg.restoreGState()
        }
        if drawn.count > 4 { drawn.removeAll() }
        drawn[key] = image
        return image
    }
}
