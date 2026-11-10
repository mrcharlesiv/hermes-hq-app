// [a11y] Scaled fonts for the places that cannot use a text style directly (spec 3x-a11y §2.3): a custom size at the
// default text size that still follows Dynamic Type, with an optional cap for text that sits in a fixed place.

import SwiftUI
import UIKit

// The type itself is the theme's font factory (App/Theme/ThemeFonts.swift); `scale` there is the theme's UI Scale
// (in both looks: [density]), so every size made here follows it.
nonisolated extension HQFont {
    /// A system font of `size` at the default text size, scaled like `style`, never above `cap`.
    static func scaled(_ size: CGFloat, weight: UIFont.Weight = .regular, like style: UIFont.TextStyle,
                                   cap: CGFloat? = nil, design: UIFontDescriptor.SystemDesign = .default,
                                   category: UIContentSizeCategory? = nil) -> UIFont {
        let size = legible(size)   // [mac] never under 10 pt on the Mac's screen (ThemeFonts.swift)
        var base = UIFont.systemFont(ofSize: size * scale, weight: weight)
        if design != .default, let descriptor = base.fontDescriptor.withDesign(design) {
            base = UIFont(descriptor: descriptor, size: size * scale)
        }
        return metricScaled(base, like: style, cap: cap, category: category)
    }

    static func mono(_ size: CGFloat, weight: UIFont.Weight = .regular, like style: UIFont.TextStyle,
                                 cap: CGFloat? = nil, category: UIContentSizeCategory? = nil) -> UIFont {
        metricScaled(.monospacedSystemFont(ofSize: legible(size) * scale, weight: weight), like: style, cap: cap, category: category)
    }

    /// Digits that do not jiggle (counters, timers).
    static func digits(_ size: CGFloat, weight: UIFont.Weight = .regular, like style: UIFont.TextStyle,
                                   cap: CGFloat? = nil, category: UIContentSizeCategory? = nil) -> UIFont {
        metricScaled(.monospacedDigitSystemFont(ofSize: legible(size) * scale, weight: weight), like: style, cap: cap, category: category)
    }

    /// The system's own style, capped.
    static func style(_ style: UIFont.TextStyle, weight: UIFont.Weight? = nil, cap: CGFloat? = nil,
                                  category: UIContentSizeCategory? = nil) -> UIFont {
        let traits = category.map { UITraitCollection(preferredContentSizeCategory: $0) }
        let preferred = UIFont.preferredFont(forTextStyle: legibleStyle(style), compatibleWith: traits)
        let size = min(preferred.pointSize, cap ?? .greatestFiniteMagnitude) * scale
        guard let weight else { return cap == nil && scale == 1 ? preferred : preferred.withSize(size) }
        return .systemFont(ofSize: size, weight: weight)
    }

    private static func metricScaled(_ base: UIFont, like style: UIFont.TextStyle, cap: CGFloat?,
                                          category: UIContentSizeCategory?) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: style)
        let traits = category.map { UITraitCollection(preferredContentSizeCategory: $0) }
        let scaled = cap.map { metrics.scaledFont(for: base, maximumPointSize: max($0, base.pointSize), compatibleWith: traits) }
            ?? metrics.scaledFont(for: base, compatibleWith: traits)
        // Small text never drops under 11 pt at the smallest sizes (the system's own smallest style is 11 pt).
        // Only the sizes below the default can go under it; there the floor is itself a scaled font (capped at the
        // floor), so a label that adjusts for the text size grows again when the size comes back up.
        let floor = min(11, base.pointSize)
        guard scaled.pointSize < floor, scaled.pointSize > 0 else { return scaled }
        let lifted = base.withSize(floor * base.pointSize / scaled.pointSize)
        let again = metrics.scaledFont(for: lifted, compatibleWith: traits)
        return again.pointSize < floor - 0.01 ? metrics.scaledFont(for: base.withSize(floor), maximumPointSize: floor, compatibleWith: traits).withSize(floor) : again
    }

    /// The weight to really draw with: one step heavier when Bold Text is on AND the text is drawn by the app itself
    /// (CoreText / TextKit in `draw(_:)`), where UIKit does not do it. The web's one-step rule
    /// (phone-ios-tokens.css:134): regular and medium become semibold, semibold bold, bold heavy.
    static func drawn(_ weight: UIFont.Weight, bold: Bool = HQAccessibility.stepsDrawnWeights) -> UIFont.Weight {
        guard bold else { return weight }
        if weight.rawValue <= UIFont.Weight.medium.rawValue { return .semibold }
        if weight.rawValue <= UIFont.Weight.semibold.rawValue { return .bold }
        if weight.rawValue <= UIFont.Weight.bold.rawValue { return .heavy }
        return .black
    }

    /// A symbol's point size beside text: `size` at the default text size, growing with `style`, never above `cap`.
    /// [ui-sizing 2026-11-09] × UI Scale on the iPhone and iPad (the cap too), as the text beside it: at 150 % glyphs
    /// stayed their 100 % size under 1.5× text. The Mac keeps its own glyph sizes (`MacIcon`).
    static func symbolSize(_ size: CGFloat, like style: UIFont.TextStyle = .body, cap: CGFloat,
                                       category: UIContentSizeCategory? = nil) -> CGFloat {
        let traits = category.map { UITraitCollection(preferredContentSizeCategory: $0) }
        return min(cap, UIFontMetrics(forTextStyle: style).scaledValue(for: size, compatibleWith: traits)) * glyphScale
    }

    /// [ui-sizing] UI Scale for glyphs and other lengths beside text on the iPhone and iPad; 1 on the Mac.
    static var glyphScale: CGFloat {
        #if targetEnvironment(macCatalyst)
        1
        #else
        HQFont.scale
        #endif
    }
}

extension View {
    /// A symbol sized like `size` pt at the default text size that grows with the text, up to `cap`.
    func hqSymbolFont(_ size: CGFloat, weight: Font.Weight = .regular, cap: CGFloat) -> some View {
        modifier(HQSymbolFont(size: size, weight: weight, cap: cap))
    }
}

private struct HQSymbolFont: ViewModifier {
    @ScaledMetric private var scaled: CGFloat
    let weight: Font.Weight
    let cap: CGFloat
    init(size: CGFloat, weight: Font.Weight, cap: CGFloat) {
        _scaled = ScaledMetric(wrappedValue: size, relativeTo: .body)
        self.weight = weight
        self.cap = cap
    }
    // [ui-sizing] × UI Scale on the iPhone and iPad, as `symbolSize`.
    func body(content: Content) -> some View {
        let _ = Theme.touch()
        return content.font(.system(size: min(scaled, cap) * HQFont.glyphScale, weight: weight)) // a11y-font-ok: scaled metric
    }
}
