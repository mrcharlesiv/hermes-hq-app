import UIKit

/// Fonts and text metrics for one Dynamic Type size. Built once per content size category (on any thread) and handed
/// to the off-main layout code; UIFont and UIColor are thread-safe.
nonisolated struct ChatStyle: @unchecked Sendable {
    let category: UIContentSizeCategory
    let isAccessibilitySize: Bool
    /// [a11y] Bold Text: the transcript is drawn by the app, so its weights step up here (HQFont.drawn), but only
    /// when the system has not already handed out heavier fonts (`HQAccessibility.stepsDrawnWeights`): on a real
    /// phone with Bold Text on, `systemFont` and `preferredFont` are already heavier and a second step would double up.
    let bold: Bool

    let body: UIFont
    let bodyBold: UIFont
    let bodyItalic: UIFont
    let bodyBoldItalic: UIFont
    /// Body line height (line-height 1.3).
    let bodyLineHeight: CGFloat
    /// "Stopped before <Bot> replied" (13 pt at the default size).
    let stoppedLine: UIFont
    let inlineCode: UIFont
    let code: UIFont
    let codeLineHeight: CGFloat
    let codeLabel: UIFont
    let table: UIFont
    let tableBold: UIFont
    let tableLineHeight: CGFloat
    let headings: [UIFont]          // h1, h2, h3 (h4–h6 reuse h3's size)
    let time: UIFont
    /// "Show More" under a clamped message: the time's size, semibold.
    let timeBold: UIFont
    let timeLineHeight: CGFloat
    let day: UIFont
    let tool: UIFont
    let toolMeta: UIFont
    let notice: UIFont
    let caption: UIFont
    let errorTitle: UIFont
    let errorBody: UIFont
    let paragraphGap: CGFloat
    let listIndent: CGFloat
    /// The tool row's glyph and chevron: 18 / 14 pt at the default size, growing with the row's text (spec 06 §10).
    let toolGlyph: CGFloat
    let toolChevron: CGFloat

    static func make(category: UIContentSizeCategory, bold: Bool = HQAccessibility.stepsDrawnWeights) -> ChatStyle {
        ChatStyle(category: category, bold: bold)
    }

    private init(category: UIContentSizeCategory, bold: Bool) {
        self.category = category
        self.bold = bold
        func w(_ weight: UIFont.Weight) -> UIFont.Weight { HQFont.drawn(weight, bold: bold) }
        isAccessibilitySize = category.isAccessibilityCategory
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        func font(_ style: UIFont.TextStyle) -> UIFont {
            let preferred = HQFont.preferred(style, compatibleWith: traits)
            guard bold else { return preferred }
            let heavy = style == .headline ? UIFont.Weight.bold : .semibold
            return HQFont.face(ofSize: preferred.pointSize, weight: heavy)
        }
        func capped(_ style: UIFont.TextStyle, _ cap: CGFloat, weight: UIFont.Weight = .regular, tabular: Bool = false) -> UIFont {
            let size = min(font(style).pointSize, cap)
            var f = HQFont.face(ofSize: size, weight: w(weight))
            if tabular {
                let d = f.fontDescriptor.addingAttributes([.featureSettings: [[
                    UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                    UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
                ]]])
                f = UIFont(descriptor: d, size: f.pointSize)
            }
            return f
        }
        func withTraits(_ f: UIFont, _ t: UIFontDescriptor.SymbolicTraits) -> UIFont {
            guard let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(t)) else { return f }
            return UIFont(descriptor: d, size: f.pointSize)
        }

        let body = font(.body)
        self.body = body
        bodyBold = bold ? HQFont.face(ofSize: body.pointSize, weight: .heavy) : withTraits(body, .traitBold)
        bodyItalic = withTraits(body, .traitItalic)
        bodyBoldItalic = withTraits(bodyBold, .traitItalic)
        // [mac] Grok Bot's 22 pt lines for 15 pt text: the Mac reads at arm's length, with room to spare.
        bodyLineHeight = (body.pointSize * (DeviceWord.isMac ? 1.45 : 1.3)).rounded(.up)
        inlineCode = HQFont.monoFace(ofSize: (body.pointSize * 0.9).rounded(), weight: w(.regular))
        let footnote = font(.footnote)
        code = HQFont.monoFace(ofSize: footnote.pointSize, weight: w(.regular))
        codeLineHeight = (footnote.pointSize * 1.5).rounded(.up)
        codeLabel = capped(.caption1, 20, weight: .medium)
        table = HQFont.face(ofSize: footnote.pointSize, weight: w(.regular))
        tableBold = HQFont.face(ofSize: footnote.pointSize, weight: w(.semibold))
        tableLineHeight = (footnote.pointSize * 1.4).rounded(.up)
        headings = [1.25, 1.125, 1.0625].map { HQFont.face(ofSize: (body.pointSize * $0).rounded(), weight: w(.semibold)) }
        time = capped(.caption2, 20, tabular: true)
        timeBold = capped(.caption2, 20, weight: .semibold)
        timeLineHeight = (time.pointSize * 1.15).rounded(.up)
        day = capped(.caption1, 22, tabular: true)
        tool = font(.subheadline)
        toolGlyph = max(18, min(36, (tool.pointSize * 1.2).rounded()))
        toolChevron = max(14, min(26, (tool.pointSize * 0.93).rounded()))
        toolMeta = HQFont.monoDigitFace(ofSize: footnote.pointSize, weight: w(.regular))
        notice = font(.footnote)
        stoppedLine = font(.footnote)
        caption = capped(.caption1, 22)
        errorTitle = font(.headline)
        errorBody = font(.subheadline)
        paragraphGap = (11.2 * body.pointSize / 17).rounded()
        // The web's `min(1.625em, 30px)`: its 30 px cap is for a page whose text doesn't grow, so here the cap grows
        // with the text (at Large, 28 pt, the same as the web); a marker wider than this widens its own list.
        listIndent = min((1.625 * body.pointSize).rounded(), (30 * body.pointSize / 17).rounded())
    }
}

/// Process-wide cache of styles per Dynamic Type size (thread-safe).
nonisolated final class ChatStyleCache: @unchecked Sendable {
    static let shared = ChatStyleCache()
    private let lock = NSLock()
    private var styles: [String: ChatStyle] = [:]

    func style(for category: UIContentSizeCategory) -> ChatStyle {
        lock.lock(); defer { lock.unlock() }
        // [desktoplook] One style per size and theme layout (the look, UI Scale, the skin's typeface).
        // [a11y] Bold Text is part of the key: bold text is wider, so it is a different style. The system's own
        // bolding changes every font too, so it is part of the key as well.
        let bold = HQAccessibility.stepsDrawnWeights
        let key = category.rawValue + ThemeTable.layoutTag + (bold ? "|bold" : "") + (HQAccessibility.systemBoldsFonts ? "|system-bold" : "")
        if let s = styles[key] { return s }
        let s = ChatStyle.make(category: category, bold: bold)
        styles[key] = s
        return s
    }
}
