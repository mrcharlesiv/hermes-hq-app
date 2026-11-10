import Testing
import UIKit
@testable import HermesHQNative

/// Verification round 2: bubble lines were 24.7 pt apart (TextKit 1 adds the font's leading under each fixed-height
/// line); the web's Body is 17 pt at line-height 1.3 (spec 06 §2.1).
@Suite("Line pitch")
struct LinePitchTests {
    private func lines(_ text: NSAttributedString, width: CGFloat = 300) -> [CGRect] {
        let layout = TextKitLayout(text, width: width)
        var rects: [CGRect] = []
        layout.manager.enumerateLineFragments(forGlyphRange: layout.manager.glyphRange(for: layout.container)) { rect, _, _, _, _ in
            rects.append(rect)
        }
        return rects
    }

    @Test func bodyLinesSitOnTheirLineHeight() {
        for category in [UIContentSizeCategory.large, .extraExtraLarge, .accessibilityLarge] {
            let style = ChatStyleCache.shared.style(for: category)
            let words = String(repeating: "word ", count: 80)
            let rendered = MarkdownRenderer.render(words, style: style)
            guard case .text(let text)? = rendered.blocks.first else { Issue.record("no paragraph"); continue }
            let rects = lines(text)
            #expect(rects.count > 3)
            for r in rects.dropLast() { #expect(abs(r.height - style.bodyLineHeight) < 0.01, "\(category.rawValue) \(r.height)") }
            // Glyphs centred in the line (CSS half-leading).
            let layout = TextKitLayout(text, width: 300)
            let baseline = layout.manager.location(forGlyphAt: 0).y
            // The glyph's drawn baseline (TextKit reports it with a raised baseline offset applied).
            let top = baseline - style.body.ascender
            let wanted = (style.bodyLineHeight - (style.body.ascender - style.body.descender)) / 2
            #expect(abs(top - wanted) < 0.4, "\(category.rawValue) top \(top) wanted \(wanted) size \(style.body.pointSize)")
            let mine = MarkdownRenderer.plain(words, style: style, theme: .me)
            for r in lines(mine).dropLast() { #expect(abs(r.height - style.bodyLineHeight) < 0.01) }
        }
    }
}
