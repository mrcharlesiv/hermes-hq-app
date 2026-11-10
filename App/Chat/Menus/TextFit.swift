// [model-panel] Words that always fit their box, whatever the model or provider is called (owner 2026-10-31: "We need
// to guarantee this works no matter the model and provider someone uses"). A model id can be anything a provider or a
// person typed, so nothing here assumes a length: the words take one line when they fit, shrink a little to stay on
// one, then wrap between words onto as many lines as the box allows, and only then shrink until every line and every
// word sits inside. Nothing is ever cut short or ends in "…" ("We do not allow that here").

import UIKit

enum TextFit {
    struct Result: Equatable {
        /// What the words are drawn at, against their own size (1 = as set).
        var scale: CGFloat
        var lines: Int
        /// A run with no break in it (an id with no spaces) wraps between letters rather than shrink past reading.
        var anywhere = false
        /// Big enough to read as the size it was set at; a box whose words fall under this should give them more room.
        var comfortable: Bool { scale >= TextFit.comfortable }
    }

    static let comfortable: CGFloat = 0.8
    /// How far one line may shrink before the words wrap instead.
    static let oneLineFloor: CGFloat = 0.86

    /// The largest scale (at most 1) at which `text` fits `width` within `maxLines` lines and `maxHeight`, breaking only
    /// between words.
    static func fit(_ text: NSAttributedString, width: CGFloat, maxLines: Int = 1, maxHeight: CGFloat = .greatestFiniteMagnitude) -> Result {
        guard text.length > 0, width > 0 else { return Result(scale: 1, lines: text.length > 0 ? 1 : 0) }
        let lines = max(1, maxLines)
        func fitsOneLine(_ s: CGFloat) -> Bool {
            let t = scaled(text, by: s)
            return oneLineWidth(t) <= width && lineHeight(t) <= maxHeight
        }
        if fitsOneLine(1) { return Result(scale: 1, lines: 1) }
        // One line, a little smaller.
        let natural = oneLineWidth(text)
        var guess = min(1, width / natural)
        if lines == 1 || guess >= oneLineFloor {
            while guess > 0.05 && !fitsOneLine(guess) { guess *= 0.985 }
            if lines == 1 || guess >= oneLineFloor { return Result(scale: max(0.05, guess), lines: 1) }
        }
        // Wrapped: the largest scale where the widest word fits and the lines stay within the box.
        func wrapped(_ s: CGFloat) -> Int? {
            let t = scaled(text, by: s)
            guard widestWord(t) <= width else { return nil }
            let height = wrappedHeight(t, width: width)
            let count = max(1, Int((height / lineHeight(t)).rounded()))
            return count <= lines && height <= maxHeight ? count : nil
        }
        if let count = wrapped(1) { return Result(scale: 1, lines: count) }
        let byWord = largest { wrapped($0) != nil }
        // Too small only because one run (an id with no spaces) is wider than the box at a readable size: let it break
        // between letters, if that keeps the words bigger. Names with spaces always break between words.
        guard byWord < comfortable, widestWord(scaled(text, by: comfortable)) > width else {
            return Result(scale: byWord, lines: wrapped(byWord) ?? lines)
        }
        func anywhere(_ s: CGFloat) -> Int? {
            let t = scaled(text, by: s)
            let height = wrappedHeight(t, width: width, anywhere: true)
            let count = max(1, Int((height / lineHeight(t)).rounded()))
            return count <= lines && height <= maxHeight ? count : nil
        }
        let byLetter = largest { anywhere($0) != nil }
        if byLetter > byWord + 0.02 { return Result(scale: byLetter, lines: anywhere(byLetter) ?? lines, anywhere: true) }
        return Result(scale: byWord, lines: wrapped(byWord) ?? lines)
    }

    /// The largest scale in (0.05, 1] for which `fits` holds (it holds at the small end and fails at the large).
    private static func largest(_ fits: (CGFloat) -> Bool) -> CGFloat {
        var low: CGFloat = 0.05, high: CGFloat = 1
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
        }
        return low
    }

    /// `text` with every font scaled by `scale`.
    static func scaled(_ text: NSAttributedString, by scale: CGFloat) -> NSAttributedString {
        guard scale != 1 else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        out.enumerateAttribute(.font, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let font = value as? UIFont else { return }
            out.addAttribute(.font, value: font.withSize(font.pointSize * scale), range: range)
        }
        return out
    }

    static func oneLineWidth(_ text: NSAttributedString) -> CGFloat {
        ceil(text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin], context: nil).width)
    }

    static func wrappedHeight(_ text: NSAttributedString, width: CGFloat, anywhere: Bool = false) -> CGFloat {
        ceil(wrapping(text, anywhere: anywhere).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                             options: [.usesLineFragmentOrigin], context: nil).height)
    }

    /// The tallest line the fonts in `text` make.
    static func lineHeight(_ text: NSAttributedString) -> CGFloat {
        var tallest: CGFloat = 0
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            tallest = max(tallest, (value as? UIFont)?.lineHeight ?? 0)
        }
        return ceil(tallest > 0 ? tallest : HQFont.preferred(.body, compatibleWith: UITraitCollection.current).lineHeight)
    }

    /// Where a line may break: spaces (not the no-break ones) and the zero-width space `breakable` adds.
    private static let breaks: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.remove(charactersIn: "\u{00A0}\u{2007}\u{202F}")
        set.insert(charactersIn: "\u{200B}")
        return set
    }()

    /// `text` with a zero-width space after each `_`, `/` and `:`, so an id with no spaces ("my_lab_model_v2",
    /// "Coder:32B") can wrap there rather than shrink to nothing.
    static func breakable(_ text: NSAttributedString) -> NSAttributedString {
        let string = text.string as NSString
        guard string.rangeOfCharacter(from: CharacterSet(charactersIn: "_/:")).location != NSNotFound else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        for i in stride(from: string.length - 1, through: 0, by: -1) where "_/:".utf16.contains(string.character(at: i)) && i < string.length - 1 {
            out.insert(NSAttributedString(string: "\u{200B}", attributes: out.attributes(at: i, effectiveRange: nil)), at: i + 1)
        }
        return out
    }

    /// The widest run between breaks: the words can only break there, so each must fit the width whole. (A hyphen
    /// may break a line too, but isn't counted as one, so a hyphenated run is held to fit whole; it only shrinks more.)
    static func widestWord(_ text: NSAttributedString) -> CGFloat {
        let string = text.string as NSString
        var widest: CGFloat = 0
        var start = 0
        for i in 0...string.length {
            let space = i == string.length || (UnicodeScalar(string.character(at: i)).map { breaks.contains($0) } ?? false)
            guard space else { continue }
            if i > start { widest = max(widest, oneLineWidth(text.attributedSubstring(from: NSRange(location: start, length: i - start)))) }
            start = i + 1
        }
        return widest
    }

    /// `text` set to wrap between words (or `anywhere`, between letters), keeping its alignment.
    static func wrapping(_ text: NSAttributedString, alignment: NSTextAlignment? = nil, anywhere: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let range = NSRange(location: 0, length: out.length)
        let base = (text.length > 0 ? text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil) ?? .default
        let style = (base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.lineBreakMode = anywhere ? .byCharWrapping : .byWordWrapping
        if let alignment { style.alignment = alignment }
        out.addAttribute(.paragraphStyle, value: style, range: range)
        return out
    }
}

/// A label whose words always fit (`TextFit`): one line by default, up to `maxLines` when it may wrap. Set it as any
/// label; the frame it is given decides the size the words are drawn at. `fittedHeight(width:)` says how tall to make it.
final class FitLabel: UILabel {
    /// The most lines the words may wrap to before they shrink further.
    var maxLines = 1 { didSet { if maxLines != oldValue { setNeedsDisplay() } } }
    /// The tallest the words may be drawn (the box's height when it is fixed, as the bubble's is).
    var maxTextHeight: CGFloat = .greatestFiniteMagnitude { didSet { if maxTextHeight != oldValue { setNeedsDisplay() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 1
        lineBreakMode = .byClipping
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The words as set, with the label's alignment.
    private var source: NSAttributedString? {
        guard let text = attributedText, text.length > 0 else { return nil }
        return TextFit.wrapping(maxLines > 1 ? TextFit.breakable(text) : text, alignment: textAlignment)
    }

    /// How the words sit in `width`.
    func fit(width: CGFloat) -> TextFit.Result {
        guard let source else { return TextFit.Result(scale: 1, lines: 0) }
        return TextFit.fit(source, width: width, maxLines: maxLines, maxHeight: maxTextHeight)
    }

    /// How wide the words are drawn in `width` on one line (their own width when they fit).
    func fittedWidth(width: CGFloat) -> CGFloat {
        guard let source else { return 0 }
        let result = TextFit.fit(source, width: width, maxLines: 1, maxHeight: maxTextHeight)
        return min(width, TextFit.oneLineWidth(TextFit.scaled(source, by: result.scale)))
    }

    /// One line keeps its full line height (rows line up whatever shrinks); wrapped words take what they need.
    func fittedHeight(width: CGFloat) -> CGFloat {
        let oneLine = ceil((font ?? HQFont.preferred(.body, compatibleWith: UITraitCollection.current)).lineHeight)
        guard let source else { return oneLine }
        let result = TextFit.fit(source, width: width, maxLines: maxLines, maxHeight: maxTextHeight)
        guard result.lines > 1 else { return max(oneLine, TextFit.lineHeight(TextFit.scaled(source, by: result.scale))) }
        return TextFit.wrappedHeight(TextFit.scaled(source, by: result.scale), width: width, anywhere: result.anywhere)
    }

    override func drawText(in rect: CGRect) {
        guard let source else { return }
        let result = TextFit.fit(source, width: rect.width, maxLines: maxLines, maxHeight: maxTextHeight)
        let text = TextFit.scaled(source, by: result.scale)
        if result.lines <= 1 {
            // One line, drawn without a width so it can never wrap on a rounding error.
            let width = TextFit.oneLineWidth(text), height = TextFit.lineHeight(text)
            let x: CGFloat
            switch effectiveAlignment {
            case .center: x = rect.minX + (rect.width - width) / 2
            case .right: x = rect.maxX - width
            default: x = rect.minX
            }
            text.draw(at: CGPoint(x: x, y: rect.minY + ((rect.height - height) / 2).rounded()))
        } else {
            let height = TextFit.wrappedHeight(text, width: rect.width, anywhere: result.anywhere)
            TextFit.wrapping(text, anywhere: result.anywhere).draw(with: CGRect(x: rect.minX, y: rect.minY + ((rect.height - height) / 2).rounded(), width: rect.width, height: height),
                      options: [.usesLineFragmentOrigin], context: nil)
        }
    }

    private var effectiveAlignment: NSTextAlignment {
        switch textAlignment {
        case .natural: effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
        default: textAlignment
        }
    }

    #if DEBUG
    /// Tests: whether every line and word sits inside the frame as drawn now.
    var debugFitsFrame: Bool {
        guard let source else { return true }
        let result = fit(width: bounds.width)
        let text = TextFit.scaled(source, by: result.scale)
        if result.lines <= 1 { return TextFit.oneLineWidth(text) <= bounds.width + 0.5 && TextFit.lineHeight(text) <= bounds.height + 0.5 }
        return (result.anywhere || TextFit.widestWord(text) <= bounds.width + 0.5)
            && TextFit.wrappedHeight(text, width: bounds.width, anywhere: result.anywhere) <= bounds.height + 0.5
    }
    #endif
}
