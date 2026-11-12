// desktoplook: the trait every themed colour keys on (spec 3x-desktoplook §3.3). It affects colour appearance, so
// UIKit re-resolves dynamic colours (views, layers drawn in draw(_:), attributed strings) when it changes.

import UIKit
import os

nonisolated struct ThemeGenerationTrait: UITraitDefinition {
    static let defaultValue = 0
    static let affectsColorAppearance = true
    static let name = "hqThemeGeneration"
    static let identifier = "com.charlesmcdowell.hermeshq.themeGeneration"
}

/// [bot-colour] The colour a chat paints your messages with over the theme's (`BotMessageColour`): set on a chat's
/// screen, so everything drawn in it (bubbles, their text, memos, reactions) resolves to it. nil: the theme's.
/// The value is a plain number (0: none), as the theme's generation is: a named colour's place in its list, or a
/// custom colour's `RRGGBB` with bit 32 set.
nonisolated struct ChatColourTrait: UITraitDefinition {
    static let defaultValue: UInt64 = 0
    static let affectsColorAppearance = true
    static let name = "hqChatColour"
    static let identifier = "com.charlesmcdowell.hermeshq.chatColour"

    static func code(_ colour: MessageColour?) -> UInt64 {
        switch colour {
        case .preset(let preset)?: UInt64((MessageColour.Preset.allCases.firstIndex(of: preset) ?? 0) + 1)
        case .custom(let hex)?: 1 << 32 | UInt64(hex & 0xFFFFFF)
        case .theme?, .botFace?, nil: 0
        }
    }

    static func colour(_ code: UInt64) -> MessageColour? {
        if code == 0 { return nil }
        if code & (1 << 32) != 0 { return .custom(UInt32(code & 0xFFFFFF)) }
        let presets = MessageColour.Preset.allCases
        return code <= UInt64(presets.count) ? .preset(presets[Int(code) - 1]) : nil
    }

    /// Sets or clears the override on a view or a screen; false where it already said so. Reading an override that
    /// was never set is an error in UIKit (it took the Mac app down a few seconds after a chat opened), so this asks
    /// `contains` first.
    @MainActor static func set(_ colour: MessageColour?, on overrides: inout UITraitOverrides) -> Bool {
        let next = code(colour)
        let now = overrides.contains(ChatColourTrait.self) ? overrides[ChatColourTrait.self] : 0
        guard now != next else { return false }
        if next == 0 { overrides.remove(ChatColourTrait.self) } else { overrides[ChatColourTrait.self] = next }
        return true
    }

    /// The tokens a message colour changes (`ThemeResolver.paintMessage`).
    static func paints(_ token: KeyPath<ThemeTokens, RGBA>) -> Bool {
        token == \ThemeTokens.meBubble || token == \ThemeTokens.meText || token == \ThemeTokens.meTime || token == \ThemeTokens.chosenRow
    }
}

/// [bot-colour] A theme's tokens with a chat's own message colour painted over them, kept by theme generation, mode
/// and colour (a chat resolves these for every bubble).
nonisolated enum ChatColours {
    private struct Key: Hashable {
        var generation: Int
        var dark: Bool
        var high: Bool
        var colour: MessageColour
    }
    private static let cache = OSAllocatedUnfairLock(initialState: [Key: ThemeTokens]())

    static func tokens(generation: Int, dark: Bool, high: Bool, colour: MessageColour) -> ThemeTokens {
        let key = Key(generation: generation, dark: dark, high: high, colour: colour)
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let set = ThemeTable.set(generation: generation)
        var tokens = set.isStandardLook && high
            ? (dark ? ThemedColor.increasedDark : ThemedColor.increasedLight)
            : set.tokens(dark: dark, increaseContrast: high)
        // The Desktop Look keeps its own boxes. A skin with one look is painted in the mode its page is.
        if !set.state.desktopLook { ThemeResolver.paintMessage(&tokens, colour, dark: tokens.page.labL < 50) }
        let painted = tokens
        cache.withLock { cache in
            if cache.count > 64 { cache.removeAll() }
            cache[key] = painted
        }
        return painted
    }
}

nonisolated extension RGBA {
    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
}

nonisolated enum ThemedColor {
    /// A dynamic colour that reads one token of the theme its trait collection belongs to. `@Sendable`: SwiftUI
    /// resolves colours off the main thread.
    static func make(_ token: KeyPath<ThemeTokens, RGBA> & Sendable) -> UIColor {
        let painted = ChatColourTrait.paints(token)
        return UIColor { @Sendable traits in
            let dark = traits.userInterfaceStyle == .dark
            // [a11y] Increase Contrast (spec 3x-a11y §5.2): the standard look has its own stronger values; the Desktop
            // Look draws its High Contrast mixes (ThemeContrast). A picked skin keeps its own (the Theme page says so).
            let high = traits.accessibilityContrast == .high || HQAccessibility.overrides.contrast
            // [bot-colour] In a chat with a colour of its own, your messages are that colour.
            if painted, let colour = ChatColourTrait.colour(traits[ChatColourTrait.self]) {
                return ChatColours.tokens(generation: traits[ThemeGenerationTrait.self], dark: dark, high: high, colour: colour)[keyPath: token].uiColor
            }
            // [perf] Only the one RGBA leaves the lock, not a copy of the whole set per resolve (nil: the standard
            // look under Increase Contrast, read outside the lock).
            let rgba: RGBA? = ThemeTable.withSet(generation: traits[ThemeGenerationTrait.self]) { set in
                set.isStandardLook && high ? nil : set.tokens(dark: dark, increaseContrast: high)[keyPath: token]
            }
            return (rgba ?? (dark ? increasedDark : increasedLight)[keyPath: token]).uiColor
        }
    }

    /// [a11y] The standard look under Increase Contrast, light and dark (the web's `ios-high-contrast` class,
    /// phone-ios-tokens.css:158-176). `HQPaletteContrastTests` polices the ratios.
    static let increasedLight = increased(dark: false)
    static let increasedDark = increased(dark: true)

    private static func increased(dark: Bool) -> ThemeTokens {
        func pick(_ light: RGBA, _ darkValue: RGBA) -> RGBA { dark ? darkValue : light }
        var tokens = ThemeResolver.base(dark: dark)
        let ink = pick(RGBA(hex: 0x1F2328), RGBA(hex: 0xE6EDF3))
        tokens.label = ink
        tokens.label2 = ink.alpha(0.85)
        tokens.label3 = ink.alpha(0.6)
        tokens.tint = pick(RGBA(hex: 0x0040DD), RGBA(hex: 0x409CFF))
        tokens.tintText = pick(RGBA(hex: 0x0033B8), RGBA(hex: 0x409CFF))
        // Opaque, and 3:1 against the page and a card (darker than the system's #C6C6C8, which measures 1.7:1 on
        // this skin's near-white page).
        tokens.separator = pick(RGBA(hex: 0x85858A), RGBA(hex: 0x6C6C70))
        tokens.fill3 = pick(RGBA(118, 118, 128, 0.2), RGBA(118, 118, 128, 0.32))
        tokens.orange = pick(RGBA(hex: 0xA82A00), RGBA(hex: 0xFFB340))
        tokens.red = pick(RGBA(hex: 0xB00012), RGBA(hex: 0xFF6961))
        tokens.meTime = .white
        return tokens
    }

    /// The page behind grouped lists. iOS's own grouped grey (at the level of the screen: a sheet's is the raised
    /// one) in the standard look and the iOS System skin, so those screens are exactly what they were; the skin's
    /// own grouped colour otherwise.
    static func makeGroupedPage() -> UIColor {
        UIColor { @Sendable traits in
            let set = ThemeTable.set(generation: traits[ThemeGenerationTrait.self])
            if let mac = macDarkGrouped(set, traits) { return mac.page.uiColor }
            if set.groupedPageIsSystem { return UIColor.systemGroupedBackground.resolvedColor(with: traits) }
            let high = traits.accessibilityContrast == .high || HQAccessibility.overrides.contrast
            return set.tokens(dark: traits.userInterfaceStyle == .dark, increaseContrast: high).grouped.uiColor
        }
    }

    /// A card on that page: iOS's own raised card (`secondarySystemGroupedBackground`) wherever the page is iOS's, the
    /// theme's card (in the page's own hue) otherwise. Use it instead of the system colour, which stayed neutral grey on
    /// a coloured skin (owner 2026-11-01).
    static func makeGroupedCard() -> UIColor {
        UIColor { @Sendable traits in
            let set = ThemeTable.set(generation: traits[ThemeGenerationTrait.self])
            if let mac = macDarkGrouped(set, traits) { return mac.card.uiColor }
            if set.groupedPageIsSystem { return UIColor.secondarySystemGroupedBackground.resolvedColor(with: traits) }
            let high = traits.accessibilityContrast == .high || HQAccessibility.overrides.contrast
            return set.tokens(dark: traits.userInterfaceStyle == .dark, increaseContrast: high).groupedCard.uiColor
        }
    }

    /// [mac-audit] Owner 2026-11-02 #8: on the Mac, dark, where the page would be iOS's own (the standard look, the iOS
    /// System skin), the grouped page is the look's own page and its cards that page raised a step in its own hue, as a
    /// coloured skin's are (`ThemeResolver.ios`). The Mac's system grouped colours are neutral greys (#1E1E1E, cards
    /// #323232), not the iPhone's black, so More and every Settings page turned grey beside the navy of Bots, Sessions,
    /// Jobs and the chats: the window changed tone with each tab. nil (iOS's own colours, or the skin's) everywhere else;
    /// the iPhone and the Mac in light are unchanged.
    static func macDarkGrouped(_ set: ThemeSet, _ traits: UITraitCollection) -> (page: RGBA, card: RGBA)? {
        #if targetEnvironment(macCatalyst)
        guard set.groupedPageIsSystem, traits.userInterfaceStyle == .dark else { return nil }
        let high = traits.accessibilityContrast == .high || HQAccessibility.overrides.contrast
        let tokens = set.isStandardLook && high ? increasedDark : set.tokens(dark: true, increaseContrast: high)
        return (tokens.page, tokens.page.mix(91, tokens.label.alpha(1)))
        #else
        return nil
        #endif
    }

    /// Whether this view's grouped page and cards are the theme's own colours (a skin's, the Desktop Look's, or the
    /// Mac's dark page: `macDarkGrouped`), not iOS's.
    static func paintsGroupedPage(_ traits: UITraitCollection) -> Bool {
        let set = ThemeTable.set(generation: traits[ThemeGenerationTrait.self])
        return !set.groupedPageIsSystem || macDarkGrouped(set, traits) != nil
    }
}
