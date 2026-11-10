// desktoplook: the one place fonts are made (spec 3x-desktoplook §3.4, §5.1, §7). With the Desktop Look off every
// call returns exactly the system font it replaced. With it on: the desktop's sizes × the Dynamic Type ratio × UI Scale,
// in the skin's typeface.

import SwiftUI
import UIKit

nonisolated enum HQFont {
    /// iOS's largest text setting over its default (AX5 body 53 pt / 17 pt): Dynamic Type × UI Scale never goes past it.
    static let ratioCap: CGFloat = 53.0 / 17.0

    /// The desktop's size and weight for a text style (phone-ui-desktop.css:67-113).
    static func desktopSpec(_ style: UIFont.TextStyle) -> (size: CGFloat, weight: UIFont.Weight) {
        switch style {
        case .largeTitle, .extraLargeTitle, .extraLargeTitle2: (22, .semibold)
        case .title1: (20, .semibold)
        case .title2: (18, .semibold)
        case .title3: (16, .semibold)
        case .headline: (15, .semibold)
        case .body: (15, .regular)
        case .callout: (14, .regular)
        case .subheadline: (13.5, .regular)
        case .footnote: (12.5, .regular)
        case .caption1: (12, .regular)
        case .caption2: (11, .regular)
        default: (15, .regular)
        }
    }

    /// Dynamic Type's ratio (the web's `--ios-s`): body at this size over body at the default size.
    static func dynamicRatio(_ traits: UITraitCollection?) -> CGFloat {
        UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize / 17
    }

    /// Dynamic Type × UI Scale, capped (§7 DECISION).
    static func factor(_ traits: UITraitCollection?, state: ThemeState = ThemeTable.current.state) -> CGFloat {
        min(dynamicRatio(traits) * CGFloat(state.scale), max(ratioCap, dynamicRatio(traits)))
    }

    /// [density] The iOS look's UI Scale over a system font Dynamic Type already sized: capped like `factor`, so
    /// iOS's largest text at 150 % stays iOS's largest text.
    static func iosFactor(_ traits: UITraitCollection?, state: ThemeState = ThemeTable.current.state) -> CGFloat {
        min(CGFloat(state.scale), max(1, ratioCap / dynamicRatio(traits)))
    }

    /// UI Scale alone, for sizes that Dynamic Type already scaled (`UIFontMetrics`) and for faces and icons.
    static var scale: CGFloat { CGFloat(ThemeTable.current.state.scale) }

    /// [mac] The Mac draws the app at 77 % (Catalyst's iPad scaling), so a caption's 11 pt came out at 8.5 pt on its
    /// screen. There no text style is smaller than Footnote's 13 pt, 10 pt on the Mac (owner 2026-10-23: "no text
    /// under about 10 pt"). Captions take Footnote's style rather than a fixed size, so they still follow the text size.
    static let macSmallest: CGFloat = 13

    static func legibleStyle(_ style: UIFont.TextStyle) -> UIFont.TextStyle {
        #if targetEnvironment(macCatalyst)
        style == .caption1 || style == .caption2 ? .footnote : style
        #else
        style
        #endif
    }

    /// A size made from a text style, kept at the Mac's smallest.
    static func legible(_ size: CGFloat) -> CGFloat {
        #if targetEnvironment(macCatalyst)
        max(size, macSmallest)
        #else
        size
        #endif
    }

    /// [mac] The tab bar's labels (`MacWindow.tabLabels`): the Mac has no text size setting for bars.
    static let macTabLabel = UIFont.systemFont(ofSize: macSmallest, weight: .medium)

    static func face(size: CGFloat, weight: UIFont.Weight, family: String?) -> UIFont {
        guard let family else { return UIFont.systemFont(ofSize: size, weight: weight) }
        let bold = weight.rawValue >= UIFont.Weight.semibold.rawValue
        var descriptor = UIFontDescriptor(fontAttributes: [.family: family])
        if bold, let heavier = descriptor.withSymbolicTraits(.traitBold) { descriptor = heavier }
        let font = UIFont(descriptor: descriptor, size: size)
        return font.familyName == family ? font : UIFont.systemFont(ofSize: size, weight: weight)
    }

    /// `UIFont.preferredFont(forTextStyle:compatibleWith:)` when the look is off.
    static func preferred(_ style: UIFont.TextStyle, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        let state = ThemeTable.current.state
        guard state.desktopLook else {
            let font = UIFont.preferredFont(forTextStyle: legibleStyle(style), compatibleWith: traits)
            // UI Scale in the iOS look too: the Mac's text size, and [density] on the iPhone and iPad on top of iOS's.
            let factor = iosFactor(traits, state: state)
            return factor == 1 ? font : font.withSize((font.pointSize * factor * 2).rounded() / 2)
        }
        let spec = desktopSpec(style)
        return face(size: legible((spec.size * factor(traits, state: state) * 2).rounded() / 2), weight: spec.weight,
                    family: state.skin.sansFamily)
    }

    /// [page-tabs] What a UISegmentedControl draws its titles in when none is set: 13 pt, the chosen one semibold (the
    /// widest). Neither UI Scale nor the text size changes it, so segments are measured in it as drawn.
    static let segmentedDefault = UIFont.systemFont(ofSize: 13, weight: .semibold)   // a11y-font-ok: measures iOS's own segments

    /// `UIFont.systemFont(ofSize:weight:)` when the look is off; × UI Scale in the skin's typeface when it is on.
    static func system(ofSize size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let state = ThemeTable.current.state
        guard state.desktopLook else { return UIFont.systemFont(ofSize: size * CGFloat(state.scale), weight: weight) }
        let capped = weight.rawValue > UIFont.Weight.semibold.rawValue ? UIFont.Weight.semibold : weight
        return face(size: size * CGFloat(state.scale), weight: capped, family: state.skin.sansFamily)
    }

    /// Code stays the system monospace in every skin (§3.4 DECISION); it follows UI Scale.
    static func mono(ofSize size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size * scale, weight: weight)
    }

    static func monoDigit(ofSize size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let state = ThemeTable.current.state
        guard state.desktopLook, state.skin.sansFamily != nil else {
            return UIFont.monospacedDigitSystemFont(ofSize: size * CGFloat(state.scale), weight: weight)
        }
        return face(size: size * CGFloat(state.scale), weight: weight, family: state.skin.sansFamily)
    }

    // Sizes read back from a font this file already made (`HQFont.preferred(...).pointSize` and anything derived
    // from it) carry Dynamic Type and UI Scale already: these three apply the skin's typeface and nothing else.
    // `system` / `mono` / `monoDigit` are for literal sizes only.
    static func face(ofSize size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let state = ThemeTable.current.state
        guard state.desktopLook else { return UIFont.systemFont(ofSize: size, weight: weight) }
        let capped = weight.rawValue > UIFont.Weight.semibold.rawValue ? UIFont.Weight.semibold : weight
        return face(size: size, weight: capped, family: state.skin.sansFamily)
    }

    static func monoFace(ofSize size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func monoDigitFace(ofSize size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let state = ThemeTable.current.state
        guard state.desktopLook, state.skin.sansFamily != nil else {
            return UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        }
        return face(size: size, weight: weight, family: state.skin.sansFamily)
    }

    /// A length that follows UI Scale (faces, icons, the roster's row height). Gutters, hairlines and radii do not.
    static func scaled(_ length: CGFloat) -> CGFloat { (length * scale * 2).rounded() / 2 }
}

extension Font {
    private static func uiStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }

    /// [mac] Captions take Footnote's style on the Mac (`HQFont.legibleStyle`).
    private static func legible(_ style: Font.TextStyle) -> Font.TextStyle {
        #if targetEnvironment(macCatalyst)
        style == .caption || style == .caption2 ? .footnote : style
        #else
        style
        #endif
    }

    private static func plain(_ style: Font.TextStyle) -> Font {
        switch legible(style) {
        case .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        default: .body
        }
    }

    /// `.font(.body)` when the Desktop Look is off (the very same font); the desktop's size, the skin's typeface and
    /// UI Scale when it is on.
    static func hq(_ style: Font.TextStyle) -> Font {
        Theme.touch()
        let state = ThemeTable.current.state
        guard state.desktopLook else {
            // [mac] The iOS look at a UI Scale (the Mac's text size): the very font UIKit text gets.
            return state.scale == 1 ? plain(style) : Font(HQFont.preferred(uiStyle(style)) as CTFont)
        }
        let spec = HQFont.desktopSpec(uiStyle(style))
        let size = HQFont.legible((spec.size * HQFont.factor(nil, state: state) * 2).rounded() / 2)
        let weight: Font.Weight = spec.weight == .semibold ? .semibold : .regular
        if let family = state.skin.sansFamily { return Font.custom(family, fixedSize: size).weight(weight) }
        return Font.system(size: size, weight: weight)
    }

    /// `.font(.system(size:weight:design:))` when the look is off; × UI Scale when it is on.
    static func hqSystem(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        Theme.touch()
        let state = ThemeTable.current.state
        guard state.desktopLook else { return Font.system(size: size * CGFloat(state.scale), weight: weight, design: design) }
        if design == .default, let family = state.skin.sansFamily {
            return Font.custom(family, fixedSize: size * CGFloat(state.scale)).weight(weight)
        }
        return Font.system(size: size * CGFloat(state.scale), weight: weight, design: design)
    }

    static func hqSystem(_ style: Font.TextStyle, design: Font.Design? = nil, weight: Font.Weight? = nil) -> Font {
        Theme.touch()
        let state = ThemeTable.current.state
        guard state.desktopLook else {
            guard state.scale != 1 else { return Font.system(legible(style), design: design, weight: weight) }
            // [mac] The iOS look at a UI Scale: the style's own size, scaled.
            let size = HQFont.preferred(uiStyle(style)).pointSize
            return Font.system(size: size, weight: weight ?? (style == .headline ? .semibold : .regular), design: design ?? .default)
        }
        let spec = HQFont.desktopSpec(uiStyle(style))
        let size = HQFont.legible((spec.size * HQFont.factor(nil, state: state) * 2).rounded() / 2)
        return Font.system(size: size, weight: weight ?? (spec.weight == .semibold ? .semibold : .regular), design: design ?? .default)
    }
}

/// [ui-sizing 2026-11-09] A SwiftUI list's own texts on the iPhone and iPad when the page's default font is set
/// (`HQScaledRoot`): iOS's header and footer at the UI Scale in use, so they don't take the rows' body size.
@MainActor enum HQListText {
    /// The page's default font is the scaled body: the Desktop Look, or the iOS look at a UI Scale other than 100 %.
    static var scaledRoot: Bool {
        Theme.touch()
        let state = ThemeTable.current.state
        return state.desktopLook || state.scale != 1
    }

    /// iOS's list header and footer, × UI Scale (the iOS look; nil when nothing is set and iOS draws its own).
    static var header: Font? { iosLook(UIListContentConfiguration.header().textProperties.font) }
    static var footer: Font? { iosLook(UIListContentConfiguration.footer().textProperties.font) }

    private static func iosLook(_ font: UIFont) -> Font? {
        guard scaledRoot, !Theme.isDesktop else { return nil }
        let scale = HQFont.iosFactor(nil)
        return Font(font.withSize((font.pointSize * scale * 2).rounded() / 2) as CTFont)
    }
}

/// [mac] The root of a hosted SwiftUI page. Text that names no font of its own (a Form row's label) is the system's
/// body, which carries no UI Scale, the Mac's text size: such rows came out smaller than the scaled text beside them
/// (stress test 2026-10-28: Settings and More pages at 150 %). On the Mac the page's default font is the scaled body;
/// elsewhere the content is as it was. Members read and write through, so `rootView.router` keeps working.
@dynamicMemberLookup
struct HQScaledRoot<Content: View>: View {
    var content: Content
    /// [mac-layout] The page's soft top edge only once it's scrolled (Settings window pages; sweep 2026-11-03). Mac polish
    /// #2: every Mac page by default; the pages that left it out (Device Access, Notifications, Theme, Gateway, About,
    /// Capabilities, Tool Calls) opened with a frosted band over their first rows.
    var softEdgeOnlyScrolled = DeviceWord.isMac

    init(_ content: Content, softEdgeOnlyScrolled: Bool = DeviceWord.isMac) {
        self.content = content
        self.softEdgeOnlyScrolled = softEdgeOnlyScrolled
    }

    var body: some View {
        #if targetEnvironment(macCatalyst)
        content.font(.hq(.body)).modifier(SoftEdgeOnlyScrolled(on: softEdgeOnlyScrolled))
        #else
        // [ui-sizing 2026-11-09] The iPhone and iPad too, now that UI Scale reaches the iOS look there: at 150 % a row's
        // own title stayed 17 pt under a 25 pt subtitle (Providers, Bot Info, Settings), and in the Desktop Look it was
        // 17 pt beside the look's 15. At 100 % in the iOS look nothing is set, so every page is as it was.
        content.font(HQListText.scaledRoot ? .hq(.body) : nil)
        #endif
    }

    subscript<T>(dynamicMember path: KeyPath<Content, T>) -> T { content[keyPath: path] }

    subscript<T>(dynamicMember path: WritableKeyPath<Content, T>) -> T {
        get { content[keyPath: path] }
        set { content[keyPath: path] = newValue }
    }
}

extension UIListContentConfiguration {
    /// [mac] A list row's own fonts are the system's, with no UI Scale, so More's rows came out smaller than the card
    /// above them (stress test 2026-10-28). Scaled like the rest of the text; [density] on the iPhone and iPad too
    /// since UI Scale reaches the iOS look there (capped as `HQFont.iosFactor`). Fonts a row sets afterwards (`HQFont`)
    /// are already scaled.
    func hqScaled() -> UIListContentConfiguration {
        let scale = HQFont.iosFactor(nil)
        guard scale != 1 else { return self }
        var copy = self
        let text = copy.textProperties.font, secondary = copy.secondaryTextProperties.font
        copy.textProperties.font = text.withSize((text.pointSize * scale * 2).rounded() / 2)
        copy.secondaryTextProperties.font = secondary.withSize((secondary.pointSize * scale * 2).rounded() / 2)
        return copy
    }
}

extension UIContentUnavailableConfiguration {
    /// [mac] An empty or error state's own fonts carry no UI Scale (see `UIListContentConfiguration.hqScaled`).
    /// [mac] Stress test 2026-10-28 #9, #52: every empty, error and loading state on the Mac takes the same title,
    /// line and symbol sizes (`MacType`) and sits `MacInset.emptyLift` above the middle of its space, in both looks.
    @MainActor func hqScaled() -> UIContentUnavailableConfiguration {
        #if targetEnvironment(macCatalyst)
        var copy = self
        copy.textProperties.font = MacType.emptyTitle
        copy.secondaryTextProperties.font = MacType.emptyBody
        copy.imageProperties.preferredSymbolConfiguration = MacType.emptySymbol
        // [mac] Stress test 2026-10-31: the look's own label greys, as the SwiftUI states draw theirs; these kept the
        // system's, a different grey from the SwiftUI pages' under the Desktop Look.
        copy.textProperties.color = HQPalette.label
        copy.secondaryTextProperties.color = HQPalette.label2
        copy.imageProperties.tintColor = HQPalette.label2
        copy.imageProperties.maximumSize = CGSize(width: 0, height: MacType.emptySymbolHeight)   // [mac] Stress test 2026-10-28 round 9: one symbol height
        copy.imageToTextPadding = 14
        copy.textToSecondaryTextPadding = 6
        copy.directionalLayoutMargins.bottom += 2 * MacInset.emptyLift
        return copy
        #else
        return self
        #endif
    }
}

extension View {
    /// [mac] A font for text whose container picks its own (ContentUnavailableView), on the Mac only, where that
    /// font carries no UI Scale; elsewhere the view as it was.
    @ViewBuilder func hqMacFont(_ font: @autoclosure () -> Font) -> some View {
        #if targetEnvironment(macCatalyst)
        self.font(font())
        #else
        self
        #endif
    }
}
