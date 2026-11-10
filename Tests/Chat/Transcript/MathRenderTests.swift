// [transcript] F17: formulas drawn as maths (docs/spec/3x-transcript.md §3.5, §12.3). Formulas come out of a reply
// before Markdown sees it (`MathText.extract`), are drawn in the serif (a single letter italic), centred on their own
// lines when they had their own lines, and shown as their TeX source when they use anything outside the subset. A big
// operator's limit (`\sum_{i=1}^{n}`) is drawn at a reduced size with a real baseline offset, not squeezed into tiny
// Unicode sub/superscript glyphs (2026-10-31 n20 revisit: "the Σ limits were tiny and cramped").

import Testing
import UIKit
@testable import HermesHQNative

@Suite struct MathExtractTests {
    @Test func formulasBecomeTokensAndComeBackAsWritten() {
        let text = "Energy: $E = mc^2$, and \\(a_1 + b_2\\)."
        let taken = MathText.extract(text)
        #expect(taken.formulas.map(\.source) == ["E = mc^2", "a_1 + b_2"])
        #expect(!taken.text.contains("$") && !taken.text.contains("_"), "Markdown never sees the formula's `_`")
        #expect(MathText.restore(taken.text, taken.formulas) == text)
    }

    @Test func codeIsLeftAlone() {
        let text = "Run `echo $HOME_DIR=$x^2$` then\n```\n$$x^2$$\n```\nand $y^2$"
        let taken = MathText.extract(text)
        #expect(taken.formulas.map(\.source) == ["y^2"])
        #expect(taken.text.contains("`echo $HOME_DIR=$x^2$`"))
        #expect(taken.text.contains("```\n$$x^2$$\n```"))
    }

    @Test func aDisplayFormulaOnItsOwnLinesIsItsOwnParagraph() {
        let own = MathText.extract("Here:\n$$\n\\frac{a}{b}\n$$\nDone.")
        #expect(own.formulas.first?.ownParagraph == true)
        #expect(own.text.contains("\n\n\u{E002}0\u{E001}\n\n"))
        let inSentence = MathText.extract("So $$x^2$$ grows.")
        #expect(inSentence.formulas.first?.ownParagraph == false)
        #expect(inSentence.text == "So \u{E000}0\u{E001} grows.")
    }

    @Test func pricesAndUnclosedDelimitersStayText() {
        #expect(MathText.extract("It costs $5 and $10.").formulas.isEmpty)
        #expect(MathText.extract("Streaming: $$\\frac{a}{").formulas.isEmpty)
    }

    @Test func voiceOverReadsTheSource() {
        #expect(MathText.spoken("So $E = mc^2$ holds") == "So Formula: E = mc^2 holds")
        #expect(SpokenMarkdown.plain("So $E = mc^2$ holds").contains("Formula: E = mc^2"))
    }
}

@Suite struct MathRenderTests {
    private let style = ChatStyleCache.shared.style(for: .large)

    private func prose(_ markdown: String, filePaths: Bool = false) -> NSAttributedString? {
        for block in MarkdownRenderer.render(markdown, style: style, filePaths: filePaths).blocks {
            if case .text(let t) = block { return t }
        }
        return nil
    }

    /// Where the typeset formulas (`MathAttachment`) sit in a rendered text.
    private func formulaSpots(in text: NSAttributedString) -> [Int] {
        var out: [Int] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value is MathAttachment { out.append(range.location) }
        }
        return out
    }

    /// Where `needle` sits in a rendered formula: an inline formula carries a word joiner (U+2060) after every
    /// character so it never breaks across lines, so the search lets one sit between any two of the needle's.
    private func locate(in text: NSAttributedString, _ needle: String) -> NSRange {
        let pattern = needle.map { $0 == " " ? "[ \u{A0}]" : NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\u{2060}?")
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.firstMatch(in: text.string, range: NSRange(location: 0, length: (text.string as NSString).length))?.range
            ?? NSRange(location: NSNotFound, length: 0)
    }

    /// The text as it reads: without the formulas' word joiners, their non-breaking spaces as plain ones.
    private func shown(_ text: NSAttributedString) -> String {
        text.string.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{A0}", with: " ")
    }

    private func font(of needle: String, in text: NSAttributedString) -> UIFont? {
        let at = locate(in: text, needle)
        guard at.location != NSNotFound else { return nil }
        return text.attribute(.font, at: at.location, effectiveRange: nil) as? UIFont
    }

    private func isSerif(_ font: UIFont?) -> Bool {
        font?.fontDescriptor.fontAttributes[.family].map { "\($0)" }?.contains("New York") == true
            || font?.fontName.lowercased().contains("newyork") == true || font?.familyName.contains("New York") == true
    }

    @Test func anInlineFormulaReadsAsMaths() throws {
        let text = try #require(prose("Einstein wrote $E = mc^2$ in 1905."))
        #expect(shown(text) == "Einstein wrote E = mc² in 1905.")
        let e = try #require(font(of: "E =", in: text))
        #expect(e.fontDescriptor.symbolicTraits.contains(.traitItalic), "a variable is italic")
        #expect(isSerif(e), "in the serif: \(e.fontName)")
        #expect(text.attribute(.chatCopy, at: locate(in: text, "E =").location, effectiveRange: nil) as? String == "E = mc^2",
                "a tap copies the formula's TeX")
        let body = try #require(font(of: "Einstein", in: text))
        #expect(e.pointSize == body.pointSize, "the formula follows the text size")
    }

    @Test func lettersAreVariablesAndNamesUpright() throws {
        let text = try #require(prose("So $E = mc^2$ and $\\sin x$ and $x_i$."))
        let mc = try #require(font(of: "mc", in: text))
        #expect(mc.fontDescriptor.symbolicTraits.contains(.traitItalic), "m and c are variables")
        let sin = try #require(font(of: "sin", in: text))
        #expect(!sin.fontDescriptor.symbolicTraits.contains(.traitItalic), "sin is a name")
        let sub = try #require(font(of: "ᵢ", in: text))
        #expect(!sub.fontDescriptor.symbolicTraits.contains(.traitItalic), "a lowered letter is drawn as it is")
    }

    @Test func underscoresAndBackslashesSurviveMarkdown() throws {
        let text = try #require(prose("Take \\(x_1 + x_2\\) and $\\alpha_i$."))
        #expect(shown(text) == "Take x₁ + x₂ and αᵢ.")
    }

    /// A display formula is typeset (`MathTypeset`, 2026-11-09): one attachment on its own centred line.
    @Test func aDisplayFormulaIsCentred() throws {
        let rendered = MarkdownRenderer.render("Here is the ratio:\n\n$$\n\\frac{a}{b}\n$$\n\nThat is all.", style: style)
        let text = try #require(rendered.blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.first)
        let at = try #require(formulaSpots(in: text).first, "\(text.string)")
        #expect(text.attribute(.attachment, at: at, effectiveRange: nil) is MathAttachment)
        let para = try #require(text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)
        #expect(para.alignment == .center)
        let first = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(first.alignment != .center, "the words around it are not centred")
        #expect(rendered.plainText.contains("\\frac{a}{b}"), "Copy keeps the source")
    }

    /// What the typesetter can't set (a command it has no name for) shows as its source, never half-converted. The
    /// environments a tester named on 2026-11-09 (aligned, cases, matrices) are set, not shown as source.
    @Test func aFormulaOutsideTheSubsetShowsItsSource() throws {
        let rendered = MarkdownRenderer.render("$$\n\\notacommand{a} &= b\n$$", style: style)
        guard case .code(let label, let code, _, _)? = rendered.blocks.first else { Issue.record("\(rendered.blocks)"); return }
        #expect(code == "\\notacommand{a} &= b")
        #expect(label == nil, "no language label on a formula's source")
        let inline = try #require(prose("See $\\notacommand{L}_x$ here."))
        #expect(inline.string == "See $\\notacommand{L}_x$ here.", "never a half-converted mix")
        let mono = try #require(font(of: "$\\notacommand", in: inline))
        #expect(mono.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        let aligned = try #require(prose("$$\n\\begin{aligned} a &= b \\end{aligned}\n$$"))
        #expect(formulaSpots(in: aligned).count == 1, "aligned is typeset")
    }

    /// 2026-10-25 n20 screenshot: the fallback card cut its text off ("\end{aligned" clipped). The fallback must build
    /// the exact same `.code` block that fenced code does (`appendCode`), so it gets the same sideways-scrolling card
    /// (`BlockView`'s `UIScrollView`, TextLayout.swift) instead of a one-off box of its own.
    @Test func theFallbackCardIsTheSameCodeBlockFencedCodeUses() throws {
        let fenced = MarkdownRenderer.render("```\nplain code\n```", style: style)
        let formula = MarkdownRenderer.render("$$\n\\notacommand{a} &= b\n$$", style: style)
        guard case .code(_, _, let fencedText, _)? = fenced.blocks.first,
              case .code(_, _, let formulaText, _)? = formula.blocks.first else {
            Issue.record("expected .code blocks"); return
        }
        // Same font, same line-break behaviour (no wrap: the card scrolls sideways, TextLayout.swift §12.3).
        let fencedFont = try #require(fencedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let formulaFont = try #require(formulaText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(fencedFont == formulaFont)
        let fencedPara = try #require(fencedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let formulaPara = try #require(formulaText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(fencedPara.lineBreakMode == formulaPara.lineBreakMode)
    }

    /// 2026-10-25 n20 screenshot: Σ's limits (`i=1` below, `n` above) were tiny, squeezed Unicode glyphs sitting right
    /// against the operator. They now draw as real characters at a reduced size with a baseline offset, not the
    /// cramped `superscripts`/`subscripts` tables (which a plain `x_i` subscript still uses, unaffected).
    @Test func sumLimitsAreReadableNotCramped() throws {
        // 2026-11-09: a sum is typeset, its limits set by the maths font; "ᵢ₌₁" never appears.
        let text = try #require(prose("The sum: $\\sum_{i=1}^{n} i$ holds."))
        #expect(!shown(text).contains("ᵢ₌₁"), "\(text.string)")
        #expect(formulaSpots(in: text).count == 1, "\(text.string)")
        #expect(shown(text).hasPrefix("The sum: ") && shown(text).hasSuffix(" holds."))
    }

    /// A formula's readable text can contain something that reads exactly like an absolute path (`\text{…}` keeps its
    /// argument verbatim): never treated as a bare file path even when `filePaths` is on for the bubble (`.mathFormula`
    /// shields it from `linkBarePaths`, which would otherwise link "/Users/me" — a root FileLinks recognises).
    @Test func aFormulasTextIsNeverReadAsAPath() throws {
        let text = try #require(prose("See $\\text{/Users/me}$ here.", filePaths: true))
        let at = locate(in: text, "/Users/me")
        #expect(at.location != NSNotFound)
        #expect(text.attribute(.chatLink, at: at.location, effectiveRange: nil) == nil, "never linked as a path")
    }

    /// A fraction's readable text can also contain a real "/" (`(a+b)/c`): the same shield applies inline.
    @Test func aFractionIsNeverReadAsAPath() throws {
        let text = try #require(prose("So $a/b + /Users/me$ here.", filePaths: true))
        let at = locate(in: text, "/Users/me")
        #expect(at.location != NSNotFound)
        #expect(text.attribute(.chatLink, at: at.location, effectiveRange: nil) == nil, "never linked as a path")
    }

    /// An inline formula never breaks inside itself (owner review 2026-10-31: "n(n+1)/" ended a line, "2." began the
    /// next): a word joiner follows every character, the slash included, and no plain space is left in it.
    @Test func anInlineFormulaNeverBreaksInside() throws {
        let text = try #require(prose("The sum is $i = n(n+1)/2$ here."))
        #expect(text.string.contains("/\u{2060}2"), "no break after the slash")
        let formula = (text.string as NSString).substring(with: locate(in: text, "n(n+1)/2"))
        #expect(!formula.contains(" "), "no ordinary space inside")
        #expect(shown(text).hasPrefix("The sum is "), "the sentence around it breaks as usual")
        // A typeset one is a single attachment, which can't break at all.
        let set = try #require(prose("The sum is $\\sum_{i=1}^n i = \\frac{n(n+1)}{2}$ here."))
        #expect(formulaSpots(in: set).count == 1)
    }

    @Test func pricesAreText() throws {
        #expect(try #require(prose("It costs $5 and $10.")).string == "It costs $5 and $10.")
    }

    @Test func aFormulaFollowsExtraLargeText() throws {
        let big = ChatStyleCache.shared.style(for: .accessibilityExtraLarge)
        var text: NSAttributedString?
        for block in MarkdownRenderer.render("So $x^2$.", style: big).blocks { if case .text(let t) = block { text = t } }
        let rendered = try #require(text)
        let x = try #require(font(of: "x²", in: rendered))
        #expect(x.pointSize == big.body.pointSize)
    }

    @Test func darkModeUsesTheTextsOwnColour() throws {
        let text = try #require(prose("So $x^2$."))
        let at = locate(in: text, "x²").location
        let colour = try #require(text.attribute(.foregroundColor, at: at, effectiveRange: nil) as? UIColor)
        let dark = colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let light = colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        #expect(dark != light, "a dynamic colour")
        #expect(colour == MarkdownTheme.bot.text)
    }
}
