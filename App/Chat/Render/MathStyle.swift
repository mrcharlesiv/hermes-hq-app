import UIKit

// [transcript] F17 (docs/spec/3x-transcript.md §3.5, §12.3): how a readable formula (`MathText.readable`) is drawn. The
// system serif (New York) at the surrounding text's size, so it follows Dynamic Type; letters are italic (variables),
// the names TeX sets upright ("sin", "lim"), longer words (a `\text{…}`) and every digit and operator upright. The
// colour is the text's own dynamic colour, so dark mode needs nothing. Pure and thread-safe (the renderer runs off the
// main thread).

nonisolated enum MathStyle {
    /// Room above and below a display formula, on top of the paragraph gap.
    static let blockGap: CGFloat = 8

    /// A big operator's limit (`MathText.limitBelowOpen`/`limitAboveOpen` … `limitClose`): drawn at this fraction of
    /// the surrounding text's size, with a real baseline offset — not squeezed into tiny Unicode sub/superscript
    /// glyphs, which read as a cramped smear next to a tall glyph like ∑ (screenshot review of the n20
    /// revisit, 2026-10-31).
    static let limitScale: CGFloat = 0.72
    /// Fraction of the base font's point size the limit moves down (below) or up (above) the baseline.
    static let limitBelowOffset: CGFloat = -0.22
    static let limitAboveOffset: CGFloat = 0.40

    /// An italic letter's glyph often runs past its own advance width (the serif's slanted "a" leans into whatever
    /// draws next); a raised or lowered character, or a fraction's slash, right after it with no extra room touches
    /// it (screenshot review of the n20 revisit, 2026-10-31: the "2" in mc² touched the c, and "a/b"'s slash
    /// overlapped the italic a). This fraction of the base font's size is kerned in after an italic run ends there.
    static let italicCorrection: CGFloat = 0.06
    /// A slash after an italic letter needs more: the serif's slash leans the same way as the letter, into it.
    static let italicSlashCorrection: CGFloat = 0.14

    static func attributed(_ readable: String, base: UIFont, color: UIColor, copy: String?) -> NSAttributedString {
        let (upright, italic) = fonts(for: base)
        let out = NSMutableAttributedString()
        var run = ""
        var runItalic = false
        func flush() {
            guard !run.isEmpty else { return }
            var attrs: [NSAttributedString.Key: Any] = [.font: runItalic ? italic : upright, .foregroundColor: color]
            if let copy { attrs[.chatCopy] = copy }
            out.append(NSAttributedString(string: run, attributes: attrs))
            run = ""
        }
        /// A reduced-size, offset copy of a big operator's limit — its own letters still get the same styling, kern
        /// and all, since it is drawn by a recursive call.
        func limitPiece(_ inner: String, below: Bool) -> NSMutableAttributedString {
            let small = base.withSize((base.pointSize * limitScale).rounded())
            let piece = NSMutableAttributedString(attributedString: attributed(inner, base: small, color: color, copy: copy))
            let full = NSRange(location: 0, length: piece.length)
            // A delta, not the final offset: `appendParagraph` adds this on top of the paragraph's own line-centring
            // baseline offset (which would otherwise overwrite a `.baselineOffset` set here directly).
            piece.addAttribute(.mathLimitOffset, value: (base.pointSize * (below ? limitBelowOffset : limitAboveOffset)).rounded(), range: full)
            return piece
        }
        let chars = Array(readable)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            // A big operator's limit: drawn separately (recursively, at a reduced size) with a real baseline offset.
            if c == MathText.limitBelowOpen || c == MathText.limitAboveOpen {
                flush()
                let firstBelow = c == MathText.limitBelowOpen
                var j = i + 1
                while j < chars.count, chars[j] != MathText.limitClose { j += 1 }
                let firstInner = String(chars[(i + 1)..<min(j, chars.count)])
                var k = j < chars.count ? j + 1 : chars.count
                // A sum's two limits (`\sum_{i=1}^{n}`, in either order) sit back to back with nothing between them
                // in `readable`: stack the second directly over the first, both starting at the same x, the way a
                // real sum's limits sit — not one after another (screenshot review of the n20 revisit,
                // 2026-10-31: "the Σ limits sit side by side").
                var secondBelow: Bool?
                var secondInner: String?
                if k < chars.count, chars[k] == MathText.limitBelowOpen || chars[k] == MathText.limitAboveOpen {
                    secondBelow = chars[k] == MathText.limitBelowOpen
                    var m = k + 1
                    while m < chars.count, chars[m] != MathText.limitClose { m += 1 }
                    secondInner = String(chars[(k + 1)..<min(m, chars.count)])
                    k = m < chars.count ? m + 1 : chars.count
                }
                let firstPiece = limitPiece(firstInner, below: firstBelow)
                if let secondBelow, let secondInner {
                    out.append(stacked(firstPiece, limitPiece(secondInner, below: secondBelow)))
                } else {
                    out.append(firstPiece)
                }
                i = k
                continue
            }
            if c == MathText.limitClose { i += 1; continue }   // a stray close (shouldn't happen): skip, draw nothing
            // A run of letters is variables (italic, `mc` in E = mc²) unless it is a name TeX sets upright (`sin`) or
            // a word of four letters or more (a `\\text{…}`). Raised and lowered characters stay as they are.
            if chars[i].isLetter, !MathText.scriptCharacters.contains(chars[i]) {
                var j = i
                while j < chars.count, chars[j].isLetter, !MathText.scriptCharacters.contains(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                let isItalic = !MathText.uprightNames.contains(word) && word.count < 4
                if isItalic != runItalic { flush(); runItalic = isItalic }
                run += word
                i = j
                continue
            }
            let wasItalic = runItalic
            if runItalic { flush(); runItalic = false }
            if wasItalic, out.length > 0, MathText.scriptCharacters.contains(c) || c == "/" || c == "⁄" {
                let correction = c == "/" || c == "⁄" ? italicSlashCorrection : italicCorrection
                out.addAttribute(.kern, value: (base.pointSize * correction).rounded(), range: NSRange(location: out.length - 1, length: 1))
            }
            run.append(c)
            i += 1
        }
        flush()
        return out
    }

    /// Two limits stacked at one x, the text after them picking up past the wider. TextKit never moves its pen back
    /// (a glyph's advance and kern together stop at 0), so a kern of minus the first limit's width after it only took
    /// its last glyph back: the "n" sat over the "1" of "i=1", and the pad after it left a wide gap (Mac polish #72).
    /// Instead the two limits' characters go in the order they sit from left to right, each kerned onto the next one's
    /// place; at a tie the narrower limit's goes first, so a one-character limit leaves the other one whole ("n", then
    /// "i=1"). A formula reads aloud and copies as its source, so the order of the drawn characters is only for drawing.
    static func stacked(_ first: NSAttributedString, _ second: NSAttributedString) -> NSAttributedString {
        func unjoined(_ piece: NSAttributedString) -> NSMutableAttributedString {
            // No ligatures: every character is a glyph of its own to place.
            let copy = NSMutableAttributedString(attributedString: piece)
            copy.addAttribute(.ligature, value: 0, range: NSRange(location: 0, length: copy.length))
            return copy
        }
        let a = unjoined(first), b = unjoined(second)
        let (aStarts, aWidth) = starts(a), (bStarts, bWidth) = starts(b)
        let narrowerFirst = bWidth <= aWidth
        var places: [(piece: NSAttributedString, range: NSRange, x: CGFloat, order: Int)] = []
        for (range, x) in aStarts { places.append((a, range, x, narrowerFirst ? 1 : 0)) }
        for (range, x) in bStarts { places.append((b, range, x, narrowerFirst ? 0 : 1)) }
        places = places.enumerated().sorted { ($0.element.x, $0.element.order, $0.offset) < ($1.element.x, $1.element.order, $1.offset) }
            .map(\.element)
        let end = max(aWidth, bWidth)
        let out = NSMutableAttributedString()
        for (n, place) in places.enumerated() {
            let character = NSMutableAttributedString(attributedString: place.piece.attributedSubstring(from: place.range))
            let whole = NSRange(location: 0, length: character.length)
            character.removeAttribute(.kern, range: whole)
            let next = n + 1 < places.count ? places[n + 1].x : end
            character.addAttribute(.kern, value: next - place.x - character.size().width, range: NSRange(location: whole.length - 1, length: 1))
            out.append(character)
        }
        return out
    }

    /// Where each character of `piece` starts, as TextKit lays it out (its own kerns included), and where the pen ends.
    private static func starts(_ piece: NSAttributedString) -> (starts: [(NSRange, CGFloat)], width: CGFloat) {
        guard piece.length > 0 else { return ([], 0) }
        // A character after the piece marks where it ends (its last kern included).
        let probe = NSMutableAttributedString(attributedString: piece)
        var tail = piece.attributes(at: piece.length - 1, effectiveRange: nil)
        tail[.kern] = nil
        probe.append(NSAttributedString(string: "|", attributes: tail))
        let storage = NSTextStorage(attributedString: probe)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 100_000, height: 100_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        func x(_ character: Int) -> CGFloat { manager.location(forGlyphAt: manager.glyphIndexForCharacter(at: character)).x }
        let string = piece.string as NSString
        var out: [(NSRange, CGFloat)] = []
        var at = 0
        while at < string.length {
            let range = string.rangeOfComposedCharacterSequence(at: at)
            out.append((range, x(range.location)))
            at = range.location + range.length
        }
        return (out, x(piece.length))
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (UIFont, UIFont)] = [:]

    /// The serif upright and italic at `base`'s size (and weight: a formula in a heading stays bold).
    static func fonts(for base: UIFont) -> (upright: UIFont, italic: UIFont) {
        let key = "\(base.fontName)|\(base.pointSize)"
        lock.lock()
        if let known = cache[key] { lock.unlock(); return known }
        lock.unlock()
        let bold = base.fontDescriptor.symbolicTraits.contains(.traitBold)
        var descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body).withDesign(.serif)
            ?? base.fontDescriptor
        if bold, let d = descriptor.withSymbolicTraits(.traitBold) { descriptor = d }
        let upright = UIFont(descriptor: descriptor, size: base.pointSize)
        let italicDescriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) ?? descriptor
        let italic = UIFont(descriptor: italicDescriptor, size: base.pointSize)
        lock.lock()
        if cache.count > 64 { cache.removeAll() }
        cache[key] = (upright, italic)
        lock.unlock()
        return (upright, italic)
    }
}
