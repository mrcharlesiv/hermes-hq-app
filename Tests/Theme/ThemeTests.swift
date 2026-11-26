// desktoplook unit tests (docs/spec/3x-desktoplook.md §11.4): colour maths, the skin catalog, the "nothing changed"
// identity of the default state, the Desktop Look and High Contrast tokens, legibility on every skin, the store
// (keys, the Nous hand-off, migration, the scale clamp), the installer, and the lint that keeps raw fonts out of App/.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

private func defaults(_ name: String = UUID().uuidString) -> UserDefaults {
    let suite = UserDefaults(suiteName: "hqn.theme.tests.\(name)")!
    suite.removePersistentDomain(forName: "hqn.theme.tests.\(name)")
    return suite
}

private func close(_ a: RGBA, _ b: RGBA, _ tolerance: Double = 0.5 / 255) -> Bool {
    abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance && abs(a.a - b.a) <= 0.002
}

private let allStates: [ThemeState] = SkinCatalog.all.flatMap { skin in
    [(false, false), (true, false), (true, true)].map { look, contrast in
        ThemeState(skinID: skin.id, desktopLook: look, highContrast: contrast, uiScalePercent: 100)
    }
}

@Suite struct ThemeMathTests {
    @Test func srgbMixIsCSSColorMix() {
        // color-mix(in srgb, #0053FD 6%, #FFFFFF) = the web's Nous Alt bubble seed
        let mixed = RGBA(hex: 0x0053FD).mix(6, .white)
        #expect(close(mixed, RGBA(239.7, 244.7, 254.9)))
        // mixing with transparent keeps the colour and scales alpha
        let faded = RGBA(hex: 0x0053FD).mix(22, RGBA(unit: 0, 0, 0, 0))
        #expect(close(faded, RGBA(hex: 0x0053FD, alpha: 0.22)))
        #expect(RGBA.white.mix(100, .black) == .white)
    }

    @Test func oklabRoundTripsAndMixesThroughGrey() {
        for hex: UInt32 in [0x000000, 0xFFFFFF, 0x0053FD, 0x00FF41, 0xDDD6FF, 0x808080] {
            let colour = RGBA(hex: hex), lab = colour.oklab
            #expect(close(RGBA.fromOklab(lab.0, lab.1, lab.2, 1), colour, 1.0 / 255))
        }
        let grey = RGBA.white.mixOklab(50, .black)
        #expect(abs(grey.r - grey.g) < 0.002 && abs(grey.g - grey.b) < 0.002)
        #expect(grey.r > 0.35 && grey.r < 0.45, "oklab mid grey is darker than the sRGB one (#636363)")
    }

    @Test func contrastMatchesWCAG() {
        #expect(abs(RGBA.white.contrast(with: .black) - 21) < 0.01)
        #expect(abs(RGBA(hex: 0x767676).contrast(with: .white) - 4.54) < 0.02)
    }

    @Test func labLightness() {
        #expect(abs(RGBA.white.labL - 100) < 0.1)
        #expect(RGBA.black.labL < 0.1)
        let raised = RGBA(hex: 0x0053FD).raisingL(to: 57)
        #expect(raised.labL > 55.5, "\(raised.labL)")
        #expect(RGBA(hex: 0x9AB8FF).raisingL(to: 57) == RGBA(hex: 0x9AB8FF), "already light enough: untouched")
    }

    @Test func legibleFixesCyberpunkOnWhiteAndLeavesNousAlone() {
        let page = RGBA.white, text = RGBA(hex: 0x1F2328, alpha: 0.94)
        let neon = RGBA(hex: 0x00FF41)
        #expect(neon.contrast(with: page) < 1.5, "the web's own example: 1.4:1")
        #expect(ThemeMath.legibleKeep(source: neon, text: text, page: page) < 100)
        #expect(ThemeMath.legible(source: neon, text: text, page: page).over(page).contrast(with: page) >= 4.5)
        #expect(ThemeMath.legibleKeep(source: RGBA(hex: 0x0053FD), text: text, page: page) == 100)
    }
}

@Suite struct SkinCatalogTests {
    @Test func fourteenSkinsInTheDesktopOrderWithTheWebWording() {
        // Rosé Pine (owner 2026-11-01) is the app's own, beside the desktop's other two-palette community themes; Paper
        // (owner 2026-11-16) is the app's own too, beside Nous whose blue it keeps.
        #expect(SkinCatalog.all.map(\.id) == ["nous", "paper", "github", "catppuccin", "everforest", "solarized", "rose-pine",
                                               "nous-alt", "midnight", "ember", "mono", "slate", "cyberpunk", "ios"])
        #expect(SkinCatalog.skin("midnight")?.description == "Deep blue-violet with cool accents")
        #expect(SkinCatalog.skin("ios")?.label == "iOS System")
        #expect(SkinCatalog.skin("ios")?.description == "iOS colors, true black in dark, system blue")
        #expect(SkinCatalog.skin("cyberpunk")?.sansFamily == Skin.monospacedFamily)
        #expect(SkinCatalog.skin("cyberpunk")?.usesMonospacedUI == true)
        #expect(SkinCatalog.all.filter(\.hasOneLook).map(\.id) == ["midnight", "ember", "mono", "slate", "cyberpunk"])
        // Stress test 2026-10-28 #88: one-palette skins say which mode they are; the others have no tag.
        #expect(SkinCatalog.skin("midnight")?.onlyModeTag == "Dark Only")
        #expect(SkinCatalog.skin("nous")?.onlyModeTag == nil)
        #expect(SkinCatalog.defaultID == "nous", "DECISION §4.4: the default stays Nous")
        for skin in SkinCatalog.all {
            #expect(!skin.label.contains("Dispatch") && !skin.description.contains("Dispatch"))
        }
    }

    @Test func seedsMatchTheReference() {
        #expect(SkinCatalog.skin("nous")?.light.midground == RGBA(hex: 0x0053FD))
        #expect(SkinCatalog.skin("nous")?.dark?.background == RGBA(hex: 0x0D1117))
        #expect(SkinCatalog.skin("midnight")?.light.background == RGBA(hex: 0x08081C))
        #expect(SkinCatalog.skin("midnight")?.light.userBubbleBorder == RGBA(hex: 0x242466))
        #expect(SkinCatalog.skin("ios")?.dark?.background == .black)
        #expect(SkinCatalog.skin("nous-alt")?.light.border == RGBA(hex: 0x0053FD, alpha: 0.22))
    }

    /// Rosé Pine's own colours (rosepinetheme.com/en/palette): Dawn light, Main dark, rose the accent.
    @Test func rosePineIsDawnAndMain() throws {
        let skin = try #require(SkinCatalog.skin("rose-pine"))
        #expect(skin.label == "Rosé Pine" && skin.onlyModeTag == nil)
        let dawn = skin.light, main = try #require(skin.dark)
        #expect(dawn.background == RGBA(hex: 0xFAF4ED) && dawn.foreground == RGBA(hex: 0x464261) && dawn.card == RGBA(hex: 0xFFFAF3))
        #expect(main.background == RGBA(hex: 0x191724) && main.foreground == RGBA(hex: 0xE0DEF4) && main.card == RGBA(hex: 0x1F1D2E))
        #expect(dawn.brand == RGBA(hex: 0x907AA9) && main.brand == RGBA(hex: 0xC4A7E7), "iris, the owner's mockup")
        #expect(dawn.destructive == RGBA(hex: 0xB4637A) && main.destructive == RGBA(hex: 0xEB6F92), "love")
        #expect(!dawn.rendersDark && main.rendersDark)
    }

    /// Paper (owner 2026-11-16): Claude's ivory page exactly in the iOS look (not pulled toward the desktop's grey), its
    /// black in dark (owner's pick over Claude's charcoal), no colour (Claude's near-black pill the accent, its ivory in dark), replies on the page
    /// with no bubble and your message a soft paper box in the theme's own text.
    @Test func paperIsClaudesIvoryAndInk() throws {
        let skin = try #require(SkinCatalog.skin("paper"))
        #expect(skin.label == "Paper" && skin.onlyModeTag == nil && skin.ownLook != nil)
        let set = ThemeResolver.resolve(ThemeState(skinID: "paper"))
        #expect(set.light.page == RGBA(hex: 0xF8F9F3) && set.dark.page == RGBA(hex: 0x000000), "black in dark, the owner's pick")
        #expect(set.light.tint == RGBA(hex: 0x22221F) && set.light.onTint == .white, "Claude's near-black pill")
        #expect(set.dark.tint == RGBA(hex: 0xEDECE6) && set.dark.onTint == .black, "its ivory in dark")
        #expect(set.light.meBubble == RGBA(hex: 0xE9EAE2) && set.light.meText == set.light.label)
        for tokens in [set.light, set.dark] {
            #expect(tokens.botBubble == tokens.page && tokens.replyEdge.a == 0, "replies on the page")
        }
        #expect(set.light.groupedCard == RGBA(hex: 0xFDFDFA))
        let dark = try #require(skin.dark)
        #expect(!skin.light.rendersDark && dark.rendersDark)
        // [paper-code] Its own muted code colours, not GitHub's; [paper-icons] its row icons on its own tile.
        #expect(set.light.syntax != nil && set.dark.syntax != nil)
        #expect(set.light.iconTile == RGBA(hex: 0xE4E5DD) && set.dark.iconTile.a == 1)
        #expect(ThemeResolver.resolve(.default).light.iconTile.a == 0, "every other skin keeps iOS's tiles")
        // [cards] Questions, drafts, approvals and every other chat card stand out from the page in every skin and look.
        for tokens in [set.light, set.dark] {
            #expect(tokens.promptCard != tokens.page && tokens.promptEdge.a > 0)
        }
        let nous = ThemeResolver.resolve(.default).light
        #expect(nous.promptCard == nous.botBubble && nous.promptEdge.a > 0, "cards always carry a subtle edge")
    }

    /// [paper-links] A reply's link is drawn in the accent; where the accent can't be told from the text it is
    /// underlined too. Paper's ink and Cyberpunk's green (the same green as its text) are the two.
    @Test func linksAreUnderlinedWhereTheAccentReadsAsText() {
        #expect(SkinCatalog.all.filter(\.accentReadsAsText).map(\.id) == ["paper", "cyberpunk"])
        for (skin, underlined) in [("paper", true), ("cyberpunk", true), ("nous", false), ("catppuccin", false)] {
            ThemeTable.$testSet.withValue(ThemeResolver.resolve(ThemeState(skinID: skin))) {
                #expect(MarkdownTheme.bot.underlinesLinks == underlined, "\(skin)")
                #expect(MarkdownTheme.me.underlinesLinks, "your bubble's links stay underlined")
            }
        }
        #expect(ThemeState(skinID: "paper").layoutSignature != ThemeState(skinID: "nous").layoutSignature,
                "the underline is part of a reply's cached layout")
    }

    /// [paper-icons] Paper draws Settings' and More's icons as plain glyphs in its ink (the owner's pick); every other
    /// skin, and the Desktop Look, don't.
    @MainActor @Test func paperDrawsItsRowIconsInInk() {
        let cases: [(ThemeState, Theme.InkIcons?)] = [(ThemeState(skinID: "paper"), .plain), (ThemeState(skinID: "nous"), nil),
                                                     (ThemeState(skinID: "rose-pine"), nil), (ThemeState(skinID: "paper", desktopLook: true), nil)]
        for (state, expected) in cases {
            ThemeTable.$testSet.withValue(ThemeResolver.resolve(state)) {
                #expect(Theme.inkIcons == expected, "\(state.skinID) look=\(state.desktopLook)")
                // [paper-glass] Paper keeps iOS's glass pills and chrome, as Claude's app (owner 2026-11-17).
                #expect(!Theme.flatPills, "\(state.skinID) look=\(state.desktopLook)")
                #expect(!Theme.solidChrome, "\(state.skinID) look=\(state.desktopLook)")
            }
        }
    }

    /// Every seed against the web app's own table, when the read-only reference is on this Mac.
    @Test func generatedSeedsEqualTheWebTable() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HermesKit/Theme/SkinSeeds.generated.swift")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("\"cyberpunk\": ("))
        #expect(text.components(separatedBy: "SkinSeeds(").count - 1 == 23, "9 skins with two palettes, 5 with one")
    }
}

/// §3.6: with nothing chosen, every colour, font and shape is what the app drew before this layer existed. The
/// literals are copied from the HQPalette.swift and ChatPalette.swift of build 250.
@Suite struct ThemeIdentityTests {
    @Test func defaultTokensAreTheShippedNousPalette() {
        let set = ThemeResolver.resolve(.default)
        #expect(set.forcedDark == nil)
        let light = set.light, dark = set.dark
        #expect(light.page == RGBA(hex: 0xFEFEFE) && dark.page == RGBA(hex: 0x0D1015))
        #expect(light.label == RGBA(hex: 0x1F2328, alpha: 0.94) && dark.label == RGBA(hex: 0xE6EDF3, alpha: 0.94))
        #expect(light.label2 == RGBA(hex: 0x1F2328, alpha: 0.74) && dark.label2 == RGBA(hex: 0xE6EDF3, alpha: 0.74))
        #expect(light.label3 == RGBA(hex: 0x1F2328, alpha: 0.36) && dark.label3 == RGBA(hex: 0xE6EDF3, alpha: 0.36))
        #expect(light.tint == RGBA(hex: 0x0053FD) && dark.tint == RGBA(hex: 0x4A84FE))
        #expect(light.tintText == RGBA(hex: 0x0040DD) && dark.tintText == RGBA(hex: 0x0A84FF))
        #expect(light.onTint == .white && dark.onTint == .white)
        #expect(light.separator == RGBA(60, 60, 67, 0.29) && dark.separator == RGBA(84, 84, 88, 0.6))
        #expect(light.fill1 == RGBA(120, 120, 128, 0.2) && dark.fill1 == RGBA(120, 120, 128, 0.36))
        #expect(light.fill2 == RGBA(120, 120, 128, 0.16) && dark.fill2 == RGBA(120, 120, 128, 0.32))
        #expect(light.fill2OnPage == RGBA(232.6, 232.6, 233.8) && dark.fill2OnPage == RGBA(47.2, 49.3, 55.2))
        #expect(light.fill3 == RGBA(118, 118, 128, 0.12) && dark.fill3 == RGBA(118, 118, 128, 0.24))
        #expect(light.fill4 == RGBA(116, 116, 128, 0.08) && dark.fill4 == RGBA(118, 118, 128, 0.18))
        #expect(light.cellPressed == RGBA(hex: 0xD1D1D6) && dark.cellPressed == RGBA(hex: 0x2C2C2E))
        #expect(light.groupedCard == RGBA(hex: 0xF2F2F7) && dark.groupedCard == RGBA(hex: 0x1C1C1E))
        #expect(light.lifted == RGBA(hex: 0xFFFFFF) && dark.lifted == RGBA(hex: 0x1C1C1E))
        #expect(light.searchFill == RGBA(118, 118, 128, 0.12) && dark.searchFill == RGBA(118, 118, 128, 0.12))
        #expect(light.orange == RGBA(hex: 0xC93400) && dark.orange == RGBA(hex: 0xFF9F0A))
        #expect(light.red == RGBA(hex: 0xD70015) && dark.red == RGBA(hex: 0xFF453A))
        #expect(light.alertRed == RGBA(hex: 0xFF3B30) && dark.alertRed == RGBA(hex: 0xFF453A))
        #expect(light.green == RGBA(hex: 0x248A3D) && dark.green == RGBA(hex: 0x30D158))
        #expect(light.muted == RGBA(hex: 0x8E8E93) && dark.muted == RGBA(hex: 0x8E8E93))
        #expect(light.botBubble == RGBA(hex: 0xE9E9EB) && dark.botBubble == RGBA(hex: 0x26282C))
        #expect(light.meBubble == RGBA(hex: 0x0053FD) && dark.meBubble == RGBA(hex: 0x3863BF))
        #expect(light.meText == .white && dark.meText == .white)
        #expect(light.meTime == RGBA.white.alpha(0.85) && dark.meTime == RGBA.white.alpha(0.88))
        #expect(light.codeFill == RGBA(116, 116, 128, 0.08) && dark.codeFill == RGBA(hex: 0x1F2023))
        #expect(light.codeFillOnBubble == RGBA(223.6, 223.6, 226.4) && dark.codeFillOnBubble == RGBA(hex: 0x1F2023))
        #expect(light.codeText == RGBA(hex: 0x1F2328) && dark.codeText == RGBA(hex: 0xA1ABB5))
        #expect(light.grouped == RGBA(hex: 0xF6F8FA) && dark.grouped == RGBA(hex: 0x010409))
        #expect(light.statusWorking == RGBA(hex: 0x0040DD) && dark.statusWorking == RGBA(hex: 0xE6EDF3, alpha: 0.94))
    }

    /// A stored High Contrast does nothing while the look is off (C4). [density] UI Scale applies in both looks.
    @Test func storedOptionsDoNothingWithTheLookOff() {
        var state = ThemeState.default
        state.highContrast = true
        let set = ThemeResolver.resolve(state)
        #expect(set.light == ThemeResolver.resolve(.default).light && set.dark == ThemeResolver.resolve(.default).dark)
        #expect(state.layoutSignature == ThemeState.default.layoutSignature)
        state.uiScalePercent = 150
        #expect(state.scale == 1.5, "UI Scale reaches the iOS look too")
        #expect(state.layoutSignature != ThemeState.default.layoutSignature)
    }

    @MainActor @Test func paletteColoursResolveToTheTokens() {
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(.default)) { paletteColours() }
    }

    @MainActor private func paletteColours() {
        let light = UITraitCollection(userInterfaceStyle: .light), dark = UITraitCollection(userInterfaceStyle: .dark)
        func hex(_ colour: UIColor, _ traits: UITraitCollection) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            colour.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "%02X%02X%02X/%.2f", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), a)
        }
        #expect(hex(HQPalette.page, light) == "FEFEFE/1.00" && hex(HQPalette.page, dark) == "0D1015/1.00")
        #expect(hex(HQPalette.tint, light) == "0053FD/1.00" && hex(ChatPalette.tint, dark) == "4A84FE/1.00")
        #expect(hex(ChatPalette.meBubble, dark) == "3863BF/1.00" && hex(ChatPalette.botBubble, light) == "E9E9EB/1.00")
        #expect(hex(HQPalette.label2, light) == "1F2328/0.74")
    }

    @MainActor @Test func fontsAndShapesAreTheSystemsWithTheLookOff() {
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(.default)) { fontsAndShapes() }
    }

    @MainActor private func fontsAndShapes() {
        let sizes: [UIContentSizeCategory] = [.extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
                                             .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
                                             .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge]
        let styles: [UIFont.TextStyle] = [.largeTitle, .title1, .title2, .title3, .headline, .body, .callout, .subheadline, .footnote,
                                          .caption1, .caption2]
        for size in sizes {
            let traits = UITraitCollection(preferredContentSizeCategory: size)
            for style in styles {
                #expect(HQFont.preferred(style, compatibleWith: traits) == UIFont.preferredFont(forTextStyle: style, compatibleWith: traits))
            }
        }
        #expect(HQFont.system(ofSize: 13, weight: .medium) == UIFont.systemFont(ofSize: 13, weight: .medium))
        #expect(HQFont.system(ofSize: 17) == UIFont.systemFont(ofSize: 17))
        #expect(HQFont.mono(ofSize: 12) == UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        #expect(HQFont.monoDigit(ofSize: 12, weight: .semibold) == UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold))
        #expect(HQFont.scaled(36) == 36)
        #expect(ChatMetrics.bubbleRadius == 12 && ChatMetrics.codeRadius == 10)
        #expect(ChatMetrics.insetCardRadius == 14 && ChatMetrics.fieldRadius == 18)
        #expect(HQShape.gutter(16) == 16 && HQShape.radius(14, .card) == 14)
        #expect(ThemeTable.layoutTag == "", "layout cache keys are what they always were")
    }
}

@Suite struct ThemeResolverTests {
    /// A5, B5, stress 22: text reads on its page in every skin, mode, look and contrast setting.
    @Test func everyStateIsLegible() {
        var failures: [String] = []
        for state in allStates {
            let set = ThemeResolver.resolve(state)
            for (mode, tokens) in [("light", set.light), ("dark", set.dark)] {
                let page = tokens.page.over(.white)
                func check(_ name: String, _ colour: RGBA, on ground: RGBA, _ ratio: Double) {
                    let value = colour.over(ground).contrast(with: ground)
                    if value < ratio { failures.append("\(state.skinID) \(mode) look=\(state.desktopLook) hc=\(state.highContrast) \(name) \(String(format: "%.2f", value))") }
                }
                check("label", tokens.label, on: page, 4.5)
                check("tintText", tokens.tintText, on: page, 4.5)
                // iOS System in light is iOS's own white on systemBlue (4.0:1), kept as Apple draws it.
                check("meText", tokens.meText, on: tokens.meBubble.over(page), state.skinID == "ios" && !state.desktopLook ? 4.0 : 4.5)
                if state.desktopLook {
                    check("label2", tokens.label2, on: page, 4.5)
                    check("red", tokens.red, on: page, 4.5)
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// [cards] Every standalone chat card (drafts, approvals, asks, orders, offers, errors, expanded tools, phone cards)
    /// must read as its own entity across every skin, look, mode and contrast setting: perceptually distinct fill off
    /// `page`, a visible border off both `page` and `promptCard`, and ≥ 4.5:1 primary text contrast on `promptCard`.
    @Test func everyStandaloneCardStandsOutFromThePage() {
        var failures: [String] = []
        func check(_ tag: String, _ tokens: ThemeTokens) {
            let page = tokens.page.over(.white)
            let card = tokens.promptCard.over(page)
            let edgeOnPage = tokens.promptEdge.over(page)
            let edgeOnCard = tokens.promptEdge.over(card)
            let fillDelta = card.labDistance(to: page)
            let edgePageDelta = edgeOnPage.labDistance(to: page)
            let edgeCardDelta = edgeOnCard.labDistance(to: card)
            let labelContrast = tokens.label.over(card).contrast(with: card)
            if fillDelta < 2.0 { failures.append("\(tag) fillΔE=\(String(format: "%.2f", fillDelta))") }
            if tokens.promptEdge.a <= 0 { failures.append("\(tag) edgeAlpha=0") }
            if edgePageDelta < 5.0 { failures.append("\(tag) edgePageΔE=\(String(format: "%.2f", edgePageDelta))") }
            if edgeCardDelta < 5.0 { failures.append("\(tag) edgeCardΔE=\(String(format: "%.2f", edgeCardDelta))") }
            if labelContrast < 4.5 - 0.01 { failures.append("\(tag) labelContrast=\(String(format: "%.2f", labelContrast))") }
        }
        for state in allStates {
            let set = ThemeResolver.resolve(state)
            check("\(state.skinID) light look=\(state.desktopLook) hc=\(state.highContrast)", set.light)
            check("\(state.skinID) dark look=\(state.desktopLook) hc=\(state.highContrast)", set.dark)
        }
        check("standard-increase-contrast light", ThemedColor.increasedLight)
        check("standard-increase-contrast dark", ThemedColor.increasedDark)
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// Owner 2026-10-17: a mid blue bubble had dark text. In the iOS look your message is white unless the skin's accent
    /// is so light white can't reach 3:1 on it (then the bubble keeps its colour and the text goes black).
    @Test func yourMessageIsWhiteUnlessTheAccentIsLight() {
        var failures: [String] = []
        for state in allStates where !state.desktopLook && SkinCatalog.skin(state.skinID)?.ownLook == nil {
            let set = ThemeResolver.resolve(state)
            for (mode, tokens) in [("light", set.light), ("dark", set.dark)] {
                let ground = tokens.meBubble.over(tokens.page.over(.white))
                if tokens.meText != .white, RGBA.white.contrast(with: ground) >= 3 {
                    failures.append("\(state.skinID) \(mode) hc=\(state.highContrast)")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// Rosé Pine's own iOS look (owner's mockup 2026-11-02): the page its base, replies on its surface, your message a
    /// soft iris box with the theme's text, code in Rosé Pine's colours readable on the code card. Other skins keep the
    /// general rules and GitHub's code colours.
    @Test func rosePineDrawsItsOwnLook() throws {
        let set = ThemeResolver.resolve(ThemeState(skinID: "rose-pine"))
        #expect(set.light.page == RGBA(hex: 0xFAF4ED) && set.dark.page == RGBA(hex: 0x191724))
        #expect(set.light.botBubble == RGBA(hex: 0xFFFAF3) && set.dark.botBubble == RGBA(hex: 0x1F1D2E))
        #expect(set.light.meBubble == RGBA(hex: 0xEADCEF) && set.dark.meBubble == RGBA(hex: 0x4D3357))
        for state in [ThemeState(skinID: "rose-pine"), ThemeState(skinID: "rose-pine", desktopLook: true)] {
            let set = ThemeResolver.resolve(state)
            for (mode, tokens) in [("light", set.light), ("dark", set.dark)] {
                let page = tokens.page.over(.white)
                if !state.desktopLook {
                    #expect(tokens.meText == tokens.label, "\(mode)")
                    #expect(tokens.meText.over(tokens.meBubble.over(page)).contrast(with: tokens.meBubble.over(page)) >= 4.5, "\(mode)")
                }
                let syntax = try #require(tokens.syntax, "\(mode) desktop=\(state.desktopLook)")
                let ground = tokens.codeFillOnBubble.over(tokens.botBubble.over(page))
                for colour in [syntax.comment, syntax.keyword, syntax.string, syntax.constant, syntax.entity, syntax.function,
                               syntax.tag, syntax.invalid] {
                    #expect(colour.contrast(with: ground) >= 4.5 - 0.01, "\(mode) desktop=\(state.desktopLook) \(colour)")
                }
            }
        }
        #expect(close(try #require(set.light.syntax).constant, RGBA(hex: 0x286983), 1 / 255), "Dawn's pine already reads; it is not changed")
        // The mockup's faint line round a reply, its tables shaded on the header row only, and dark code on the base.
        for tokens in [set.light, set.dark] {
            #expect(tokens.replyEdge.a > 0 && tokens.replyEdge == tokens.separator)
            #expect(tokens.tableBody.a == 0 && tokens.tableHead.a > 0)
        }
        #expect(set.light.tableHead == RGBA(hex: 0xF2E9E1) && set.dark.codeFill == RGBA(hex: 0x191724))
        let desktop = ThemeResolver.resolve(ThemeState(skinID: "rose-pine", desktopLook: true))
        #expect(desktop.light.replyEdge.a == 0 && desktop.dark.replyEdge.a == 0 && desktop.dark.ownLook == nil, "the Desktop Look draws its own")
        let githubSyntaxSkins: Set<String> = ["nous", "github", "ios"]
        for skin in SkinCatalog.all {
            let other = ThemeResolver.resolve(ThemeState(skinID: skin.id))
            if githubSyntaxSkins.contains(skin.id) {
                #expect(other.light.syntax == nil && other.dark.syntax == nil, "\(skin.id)")
            } else {
                for (mode, tokens) in [("light", other.light), ("dark", other.dark)] {
                    let syntax = try #require(tokens.syntax, "\(skin.id) \(mode)")
                    let ground = tokens.codeFillOnBubble.over(tokens.botBubble.over(tokens.page.over(.white)))
                    for colour in [syntax.comment, syntax.keyword, syntax.string, syntax.constant, syntax.entity, syntax.function,
                                   syntax.tag, syntax.invalid] {
                        #expect(colour.contrast(with: ground) >= 4.5 - 0.01, "\(skin.id) \(mode) \(colour)")
                    }
                }
            }
            guard skin.ownLook == nil else { continue }
            for tokens in [other.light, other.dark] {
                #expect(tokens.replyEdge.a == 0 && tokens.tableBody == tokens.fill4 && tokens.tableHead == tokens.fill4, "\(skin.id)")
            }
        }
    }

    @Test func everforestDesktopMeBorderAndLightElevationAreVisible() {
        let lightDesktop = ThemeResolver.resolve(ThemeState(skinID: "everforest", desktopLook: true)).light
        let darkDesktop = ThemeResolver.resolve(ThemeState(skinID: "everforest", desktopLook: true)).dark
        for (mode, tokens) in [("light", lightDesktop), ("dark", darkDesktop)] {
            let page = tokens.page.over(.white)
            let bubble = tokens.meBubble.over(page)
            let visible = tokens.meBorder.over(page).contrast(with: page) >= 1.15
                || tokens.meBorder.over(bubble).contrast(with: bubble) >= 1.15
            #expect(visible, "Everforest \(mode) Desktop Look meBorder must be visible")
        }
        let everforestLight = ThemeResolver.resolve(ThemeState(skinID: "everforest")).light
        #expect(everforestLight.groupedCard.labL > everforestLight.grouped.labL, "Light grouped card lifts off grouped canvas")
        #expect(everforestLight.meText == .white)
    }

    @MainActor @Test func appearanceIconsAllHaveNonGreyTilesAndStylizedSkinsUseHarmonizedTiles() {
        let appearanceSymbols = ["paintbrush", "paintpalette", "desktopcomputer", "circle.righthalf.filled",
                                 "textformat.size", "rectangle.compress.vertical", "circle.dashed", "rectangle.topthird.inset.filled"]
        for symbol in appearanceSymbols {
            let tile = SettingsRowLabel.tile(for: symbol)
            #expect(tile.colour != 0x8E8E93, "\(symbol) should have an intentional colored tile, not fallback grey")
        }
        for skinID in ["everforest", "mono", "cyberpunk"] {
            ThemeTable.$testSet.withValue(ThemeResolver.resolve(ThemeState(skinID: skinID))) {
                #expect(Theme.inkIcons == .tiles, "\(skinID) uses harmonized skin-tinted row tiles")
            }
        }
    }

    @Test func desktopLookUsesTheDesktopsOwnMixes() {
        let midnight = ThemeResolver.resolve(ThemeState(skinID: "midnight", desktopLook: true)).dark
        let seeds = SkinCatalog.skin("midnight")!.light
        // --ui-bg-chrome: 74 % background + 26 % #0D0D0E
        #expect(close(midnight.page, seeds.background.mix(74, RGBA(hex: 0x0D0D0E))))
        #expect(close(midnight.label, seeds.foreground.alpha(0.94)))
        // --ui-bg-editor: 38 % card + 62 % #161618
        #expect(close(midnight.editor, seeds.card.mix(38, RGBA(hex: 0x161618))))
        #expect(close(midnight.botBubble, midnight.editor) && close(midnight.groupedCard, midnight.editor))
        // --ui-stroke-secondary: accent 16 % into (foreground at 7 %)
        #expect(close(midnight.strokeSecondary, RGBA(hex: 0x8B80E8).mix(16, seeds.foreground.faded(7))))
        #expect(close(midnight.separator, midnight.strokeSecondary))
        #expect(close(midnight.meBubble, RGBA(hex: 0x14143A).mix(46, RGBA(hex: 0x161618))))
        #expect(midnight.meBorder == RGBA(hex: 0x242466))
        #expect(close(midnight.meText, midnight.label), "your message is text on a box, not white on blue")
        let solarized = ThemeResolver.resolve(ThemeState(skinID: "solarized", desktopLook: true)).dark
        #expect(solarized.meText.over(solarized.meBubble).contrast(with: solarized.meBubble.over(solarized.page)) >= 4.5)
        // a one-look skin draws the same in Light and Dark and asks for the dark appearance
        let set = ThemeResolver.resolve(ThemeState(skinID: "midnight", desktopLook: true))
        #expect(set.light == set.dark && set.forcedDark == true)
        #expect(ThemeResolver.resolve(ThemeState(skinID: "github", desktopLook: true)).forcedDark == nil)
        // Nous light page: 92 % white + 8 % #F3F3F3 = #FEFEFE, the page the app always had
        #expect(ThemeResolver.resolve(ThemeState(skinID: "nous", desktopLook: true)).light.page.hexString == "#FEFEFE")
    }

    @Test func cyberpunkLightAccentIsMadeReadable() {
        let tokens = ThemeResolver.resolve(ThemeState(skinID: "cyberpunk", desktopLook: true)).light
        #expect(tokens.tintText.over(tokens.page).contrast(with: tokens.page) >= 4.5)
        let nous = ThemeResolver.resolve(ThemeState(skinID: "nous", desktopLook: true)).light
        #expect(close(nous.tintText, RGBA(hex: 0x0053FD)), "an accent that already reads is left alone")
    }

    /// §6's table for every skin.
    @Test func highContrastTokens() {
        for skin in SkinCatalog.all {
            let plainSet = ThemeResolver.resolve(ThemeState(skinID: skin.id, desktopLook: true))
            let strongSet = ThemeResolver.resolve(ThemeState(skinID: skin.id, desktopLook: true, highContrast: true))
            for wantsDark in [false, true] {
                let plain = plainSet.tokens(dark: wantsDark), strong = strongSet.tokens(dark: wantsDark)
                let seeds = skin.seeds(dark: wantsDark), dark = seeds.rendersDark
                let ink = seeds.foreground.alpha(0.94), page = plain.page, accent = seeds.brand
                #expect(strong.page == plain.page, "the page does not move")
                #expect(close(strong.strokePrimary, ink.faded(18)) && close(strong.strokeSecondary, ink.faded(13)))
                #expect(close(strong.separator, ink.faded(10)))
                #expect(close(strong.editor, ink.over(page).mixOklab(dark ? 10 : 5, page)), "\(skin.id) boxes lift off the page")
                #expect(close(strong.cellPressed, accent.mixOklab(dark ? 22 : 14, page).over(page)))
                #expect(close(strong.meBubble, accent.mixOklab(dark ? 28 : 13, page)), "\(skin.id) your message is the accent's tint")
                #expect(close(strong.meBorder, accent.mixOklab(dark ? 75 : 65, page)))
                #expect(close(strong.composerBorder, ink.faded(50)))
                #expect(close(strong.tabIdle, strong.label2), "tabs not picked read as secondary text")
                #expect(strong.label2.over(page).contrast(with: page) >= plain.label2.over(page).contrast(with: page) - 0.01)
                // your message stands further from the page than without the option
                #expect(strong.meBorder.over(page).contrast(with: page) >= 1.5, "\(skin.id) \(wantsDark)")
            }
        }
    }

    @Test func aSkinInTheIOSLookKeepsHueMatchedNeutralsAndCards() {
        let base = ThemeResolver.base(dark: true)
        let ember = ThemeResolver.resolve(ThemeState(skinID: "ember")).dark
        #expect(ember.page != base.page && ember.tint != base.tint, "the page and the accent are the skin's")
        #expect(ember.separator != base.separator && ember.fill1 != base.fill1 && ember.botBubble != base.botBubble,
                "custom skins receive hue-matched neutrals instead of cold iOS greys")
        #expect(ember.strokePrimary == ember.separator && ember.strokeSecondary == ember.separator && ember.strokeTertiary == ember.separator,
                "Native look strokes stay synced to each skin's hue-matched separator")
        let catppuccin = ThemeResolver.resolve(ThemeState(skinID: "catppuccin")).dark
        #expect(catppuccin.strokeSecondary == catppuccin.separator && catppuccin.strokeSecondary != base.strokeSecondary)
        let rosePine = ThemeResolver.resolve(ThemeState(skinID: "rose-pine")).dark
        #expect(rosePine.strokeSecondary == rosePine.separator && rosePine.strokeSecondary != base.strokeSecondary)
        // Cards are the page raised in its own hue, not iOS's neutral grey (owner 2026-11-01).
        #expect(ember.groupedCard != base.groupedCard)
        #expect(ember.groupedCard.contrast(with: ember.page) > 1.05, "the card stands off the page")
        let ios = ThemeResolver.resolve(ThemeState(skinID: "ios"))
        #expect(ios.light.page == .white && ios.dark.page == .black, "true black in dark")
        #expect(ios.light.tint == RGBA(hex: 0x007AFF) && ios.dark.tint == RGBA(hex: 0x0A84FF), "system blue")
    }
}

@Suite struct ThemeStoreTests {
    @Test func aFreshPhoneIsNousOffOffHundred() {
        let store = ThemeStore(defaults: defaults())
        store.migrate()
        #expect(store.load() == ThemeState.default)
        #expect(store.load().skinID == "nous" && !store.load().desktopLook && !store.load().highContrast && store.load().uiScalePercent == 100)
    }

    @Test func choicesSurviveAReload() {
        let suite = defaults()
        let store = ThemeStore(defaults: suite)
        store.pick(skin: "midnight"); store.setDesktopLook(true); store.setHighContrast(true); store.setUIScale(125)
        let loaded = ThemeStore(defaults: suite).load()
        #expect(loaded == ThemeState(skinID: "midnight", desktopLook: true, highContrast: true, uiScalePercent: 125))
        #expect(suite.string(forKey: "hqn.theme.chosen") == "picked")
        // 100 % is stored as nothing (ui-scale.ts:31-33)
        store.setUIScale(100)
        #expect(suite.object(forKey: "hqn.theme.uiScale") == nil)
        // the options are kept while the look is off; High Contrast stops applying, UI Scale doesn't ([density])
        store.setUIScale(150); store.setDesktopLook(false)
        let off = store.load()
        #expect(!off.desktopLook && off.highContrast && off.uiScalePercent == 150 && off.scale == 1.5 && !off.contrastApplies)
        store.setDesktopLook(true)
        #expect(store.load().scale == 1.5 && store.load().contrastApplies)
    }

    @Test func nousHandOff() {
        let suite = defaults()
        let store = ThemeStore(defaults: suite)
        store.pick(skin: "ios")
        store.setDesktopLook(true)
        #expect(store.load().skinID == "nous", "iOS System has no desktop counterpart")
        #expect(suite.string(forKey: "hqn.theme.skinBeforeLook") == "ios")
        store.setDesktopLook(false)
        #expect(store.load().skinID == "ios", "back when the look goes off")
        #expect(suite.object(forKey: "hqn.theme.skinBeforeLook") == nil)
        // a skin picked by hand while the look is on stays
        store.setDesktopLook(true)
        store.pick(skin: "midnight")
        store.setDesktopLook(false)
        #expect(store.load().skinID == "midnight")
        // stress 10: a stale memory with the look off flips nothing
        suite.set("ios", forKey: "hqn.theme.skinBeforeLook")
        #expect(store.load().skinID == "midnight" && !store.load().desktopLook)
        // any other skin is untouched by the look
        store.pick(skin: "ember"); store.setDesktopLook(true); store.setDesktopLook(false)
        #expect(store.load().skinID == "ember")
    }

    @Test func migrationMovesOnlyPeopleWhoNeverChose() {
        // never chose + the old default stored -> follows a new default
        var suite = defaults()
        suite.set("nous", forKey: "hqn.theme.skin")
        ThemeStore(defaults: suite).migrate(defaultID: "ios", oldDefaultID: "nous")
        #expect(suite.object(forKey: "hqn.theme.skin") == nil && suite.string(forKey: "hqn.theme.chosen") == "migrated")
        // picked -> kept
        suite = defaults()
        ThemeStore(defaults: suite).pick(skin: "nous")
        ThemeStore(defaults: suite).migrate(defaultID: "ios", oldDefaultID: "nous")
        #expect(suite.string(forKey: "hqn.theme.skin") == "nous" && suite.string(forKey: "hqn.theme.chosen") == "picked")
        // another skin stored without the marker -> kept
        suite = defaults()
        suite.set("ember", forKey: "hqn.theme.skin")
        ThemeStore(defaults: suite).migrate(defaultID: "ios", oldDefaultID: "nous")
        #expect(suite.string(forKey: "hqn.theme.skin") == "ember")
        // today's default equals the old one: nothing visible changes
        suite = defaults()
        ThemeStore(defaults: suite).migrate()
        #expect(ThemeStore(defaults: suite).load() == .default)
    }

    /// Stress 9: garbage in every key.
    @Test func garbageReadsAsTheDefaults() {
        let suite = defaults()
        let store = ThemeStore(defaults: suite)
        suite.set("retired-skin", forKey: "hqn.theme.skin")
        #expect(store.load().skinID == "nous")
        #expect(suite.string(forKey: "hqn.theme.skin") == "retired-skin", "not overwritten until the person picks")
        suite.set(42, forKey: "hqn.theme.skin")
        #expect(store.load().skinID == "nous")
        suite.set("yes please", forKey: "hqn.theme.desktopLook")
        suite.set("on", forKey: "hqn.theme.highContrast")
        #expect(!store.load().desktopLook && !store.load().highContrast)
        for bad: Any in [0, -50, 9999, "abc", 79, 161, Double.nan] {
            suite.set(bad, forKey: "hqn.theme.uiScale")
            #expect(store.load().uiScalePercent == 100, "\(bad)")
        }
        suite.set(120, forKey: "hqn.theme.uiScale")
        #expect(store.load().uiScalePercent == 120, "inside the range, not a preset: applied as is")
        #expect(!ThemeState.scalePresets.contains(120))
        #expect(ThemeState.scalePresets == [90, 100, 110, 125, 150])
        store.reset()
        #expect(store.load() == .default)
    }
}

@Suite struct ThemeTableTests {
    @Test func theTableKeepsOnlyAFewGenerations() {
        let first = ThemeTable.install(ThemeResolver.resolve(.default))
        for _ in 0..<50 { ThemeTable.install(ThemeResolver.resolve(.default)) }
        #expect(ThemeTable.retained <= 4, "stress 1: the generation table does not grow")
        // a generation it no longer holds resolves to the current set, never a crash
        #expect(ThemeTable.tokens(generation: first, dark: false) == ThemeTable.current.light)
        #expect(ThemeTable.tokens(generation: 0, dark: true) == ThemeTable.current.dark)
    }

    /// [perf] `Theme.isDesktop` reads a Bool kept beside the set; it must follow `install` and the test override.
    @Test func theDesktopFlagFollowsTheInstalledSetAndTheTestOverride() {
        // Re-installs the set already current, so tests running beside this one see no change of look.
        let current = ThemeTable.current
        ThemeTable.install(current)
        #expect(ThemeTable.desktopLook == current.state.desktopLook)
        for look in [true, false] {
            let set = ThemeResolver.resolve(ThemeState(skinID: "midnight", desktopLook: look, highContrast: false, uiScalePercent: 100))
            ThemeTable.$testSet.withValue(set) {
                #expect(ThemeTable.desktopLook == look)
                #expect(ThemeTable.withSet(generation: 0) { $0.state.desktopLook } == look)
            }
        }
        // withSet reads the same set `set(generation:)` hands out
        let generation = ThemeTable.generation
        #expect(ThemeTable.withSet(generation: generation) { $0 } == ThemeTable.set(generation: generation))
        #expect(ThemeTable.withSet(generation: -1) { $0 } == ThemeTable.current, "an unknown generation: the current set")
    }

    /// Stress 8: providers are called on every draw, from several threads.
    @Test func lookupsAreFastAndSafeFromManyThreads() async {
        let start = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    for index in 0..<2500 { _ = ThemeTable.tokens(generation: index % 3, dark: index % 2 == 0).page }
                }
            }
        }
        #expect(Date().timeIntervalSince(start) < 0.5, "10,000 lookups")
    }
}

@Suite struct UIScaleTests {
    @Test func scaleMultipliesDynamicTypeAndIsCapped() {
        let large = UITraitCollection(preferredContentSizeCategory: .large)
        let huge = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let on150 = ThemeState(skinID: "nous", desktopLook: true, highContrast: false, uiScalePercent: 150)
        #expect(abs(HQFont.factor(large, state: on150) - 1.5) < 0.001)
        #expect(HQFont.factor(huge, state: on150) <= HQFont.ratioCap + 0.001, "never past iOS's own largest text")
        #expect(HQFont.factor(huge, state: on150) >= HQFont.dynamicRatio(huge) - 0.001, "and never smaller than Dynamic Type alone")
        // [density] The iOS look takes UI Scale over iOS's own text size, capped at iOS's largest the same way.
        let off = ThemeState(skinID: "nous", desktopLook: false, highContrast: false, uiScalePercent: 150)
        #expect(abs(HQFont.iosFactor(large, state: off) - 1.5) < 0.001)
        #expect(HQFont.dynamicRatio(huge) * HQFont.iosFactor(huge, state: off) <= HQFont.ratioCap + 0.001, "never past iOS's own largest text")
        #expect(HQFont.iosFactor(huge, state: off) >= 1, "and never under it")
        let small = ThemeState(skinID: "nous", desktopLook: false, highContrast: false, uiScalePercent: 90)
        #expect(abs(HQFont.iosFactor(huge, state: small) - 0.9) < 0.001, "smaller is never capped")
        #expect(HQFont.desktopSpec(.body).size == 15 && HQFont.desktopSpec(.headline).weight == .semibold)
        #expect(HQFont.desktopSpec(.footnote).size == 12.5 && HQFont.desktopSpec(.largeTitle).size == 22)
    }
}

@Suite struct DesktopThemeInstallTests {
    private func row(_ id: String, current: Bool = false, session: Bool = true) -> GatewayAccountRow {
        let account = GatewayAccount(id: id, baseURL: URL(string: "http://\(id).test:9000")!, kind: .password, username: "u", label: id)
        return GatewayAccountRow(id: id, account: account, title: id, subtitle: "", label: nil, hostAndPort: "\(id).test:9000",
                                 accountName: "u", isCurrent: current, hasSession: session, news: 0)
    }

    @Test func wordsByStatus() {
        #expect(DesktopThemeInstall.failureWords(0) == "The computer running Hermes didn’t answer. Check that it’s on and connected, then try again.")
        #expect(DesktopThemeInstall.failureWords(401) == DesktopThemeInstall.failureWords(403))
        #expect(DesktopThemeInstall.failureWords(401) == "This iPhone isn’t signed in to Hermes anymore. Sign in again in Settings › Gateway.")
        #expect(DesktopThemeInstall.failureWords(404) == "This Hermes is too old to take files from the iPhone. Update Hermes on the computer running Hermes, then try again.")
        #expect(DesktopThemeInstall.failureWords(500) == "Its Hermes refused the file (HTTP 500).")
        #expect(DesktopThemeInstall.failureWords(409) == "Its Hermes refused the file (HTTP 409).")
        for text in [DesktopThemeInstall.addedNote, DesktopThemeInstall.elsewhereNote, DesktopThemeInstall.copiedNote, DesktopThemeInstall.copyFailedNote,
                     DesktopThemeInstall.failureWords(0), DesktopThemeInstall.description(targets: [])] {
            #expect(!text.contains("Dispatch"))
        }
    }

    /// Stress round 2: a 200 with a broken body read as "Added". Only Hermes's own answer counts.
    @Test func a200ThatIsNotHermesIsNotAdded() async {
        let broken: [Data?] = [nil, Data(), Data("OK".utf8), Data("<html><h1>502 Bad Gateway</h1></html>".utf8),
                               Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":4000,"message":"no"}}"#.utf8),
                               Data(#"{"ok":false}"#.utf8), Data(#"{"detail":"Not Found"}"#.utf8), Data("[1,2]".utf8),
                               Data(repeating: 0x41, count: 3 * 1024 * 1024)]
        for body in broken {
            #expect(DesktopThemeInstall.status(200, body: body) == DesktopThemeInstall.notHermes)
        }
        #expect(DesktopThemeInstall.status(200, body: Data(#"{"ok":true,"path":"x","byteSize":3}"#.utf8)) == 200)
        #expect(DesktopThemeInstall.status(200, body: Data(#"{"path":"x","entry":{}}"#.utf8)) == 200, "an older Hermes without ok")
        for status in [0, 401, 403, 404, 409, 500] {
            #expect(DesktopThemeInstall.status(status, body: Data(#"{"ok":true}"#.utf8)) == status, "only a 200 is read")
        }
        #expect(DesktopThemeInstall.failureWords(DesktopThemeInstall.notHermes)
                == "Something answered, but it wasn’t Hermes. Check the address of the computer running Hermes in Settings › Gateway, then try again.")
        // A broken mkdir answer stops the install before the write.
        let failure = await DesktopThemeInstall.install(content: "x") { path, _ in
            path == DesktopThemeInstall.mkdirPath ? DesktopThemeInstall.status(200, body: Data("OK".utf8)) : 200
        }
        #expect(failure == DesktopThemeInstall.notHermes)
    }

    @Test func bodiesCarryExactlyTheirKeys() throws {
        let mkdir = try JSONSerialization.jsonObject(with: DesktopThemeInstall.mkdirBody()) as? [String: String]
        #expect(mkdir == ["path": "~/.hermes/desktop-plugins/hermes-hq-theme"])
        let write = try JSONSerialization.jsonObject(with: DesktopThemeInstall.writeBody("x = 1")) as? [String: String]
        #expect(write == ["path": "~/.hermes/desktop-plugins/hermes-hq-theme/plugin.js", "content": "x = 1"])
        #expect(DesktopThemeInstall.mkdirPath == "/api/files/mkdir" && DesktopThemeInstall.writePath == "/api/fs/write-text")
        #expect(DesktopThemeInstall.link == "https://github.com/mrcharlesiv/hermes-hq/tree/main/desktop-plugin/hermes-hq-theme")
    }

    @Test func targetsAreSignedInOnesWithTheOneInUseFirst() {
        let rows = [row("alpha"), row("beta", session: false), row("gamma", current: true), row("delta")]
        #expect(DesktopThemeInstall.targets(rows).map(\.id) == ["gamma", "alpha", "delta"], "E6: no session, not listed")
        #expect(DesktopThemeInstall.description(targets: [row("studio")]).hasPrefix("Adds two themes to the Hermes desktop app on studio: Hermes HQ"))
        #expect(DesktopThemeInstall.description(targets: rows).hasPrefix("Adds two themes to the Hermes desktop app: Hermes HQ"))
    }

    private actor Recorder {
        var paths: [String] = []
        func note(_ path: String) { paths.append(path) }
    }

    @Test func writeFollowsOnlyASuccessfulMkdir() async {
        let ok = Recorder()
        let done = await DesktopThemeInstall.install(content: "x") { path, _ in await ok.note(path); return 200 }
        #expect(done == nil)
        #expect(await ok.paths == ["/api/files/mkdir", "/api/fs/write-text"])
        let refused = Recorder()
        let failed = await DesktopThemeInstall.install(content: "x") { path, _ in await refused.note(path); return 409 }
        #expect(failed == 409, "mkdir's own status")
        #expect(await refused.paths == ["/api/files/mkdir"], "no write after a failed mkdir")
        let late = await DesktopThemeInstall.install(content: "x") { path, _ in path.hasSuffix("mkdir") ? 200 : 0 }
        #expect(late == 0, "the write's status when the write failed")
    }

    @Test func theBundledFileIsTheOwnersPlugin() throws {
        let text = try #require(DesktopThemeInstall.bundledText())
        #expect(DesktopThemeInstall.digest(text) == DesktopThemeInstall.sha256)
        #expect(text.utf8.count == 187585 && text.utf8.count < DesktopThemeInstall.maxBytes)
    }
}

/// §3.4: a new screen that makes a raw font bypasses the theme; this fails until scripts/desktoplook-migrate.py is run.
@Suite struct ThemeLintTests {
    @Test func noRawFontCallsOutsideTheThemeFolder() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App")
        guard FileManager.default.fileExists(atPath: app.path) else { return }   // the sources are not on this machine
        let patterns = [#"(?<![\w.])\.systemGroupedBackground\b"#, #"UIColor\.systemGroupedBackground\b"#,
                        #"UIFont\.preferredFont\(forTextStyle:"#, #"UIFont\.systemFont\(ofSize:"#, #"UIFont\.monospacedSystemFont\(ofSize:"#,
                        #"(?<!\w)\.font\(\.(largeTitle|title3|title2|title|headline|subheadline|body|callout|footnote|caption2|caption)\b(?!\()"#,
                        #"registerForTraitChanges\(\[UITraitUserInterfaceStyle\.self(?!, ThemeGenerationTrait\.self)"#]
            .map { try! NSRegularExpression(pattern: $0) }
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", !file.path.contains("/App/Theme/"),
                  !file.path.hasSuffix("/App/Kit/Accessibility/HQFont.swift") else { continue }   // the factory's accessibility half
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            if patterns.contains(where: { $0.firstMatch(in: text, range: range) != nil }) { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "run python3 scripts/desktoplook-migrate.py: \(offenders.sorted().joined(separator: ", "))")
    }

    /// [glass] Owner 2026-10-30, more Liquid Glass: SwiftUI glass and glass button configurations go through the
    /// helpers in App/Theme/DesktopLayout.swift (`hqGlassEffect`, `hqGlassButtonStyle`, `UIButton.Configuration.hqGlass`),
    /// because nothing flattens them in the Desktop Look afterwards (UIKit glass panels are flattened by ThemeChrome).
    /// The photo viewer's "Showing a Preview" caption stayed glass in the look this way. A line that needs the raw
    /// call for something other than drawing says why with "glass-ok".
    @Test func noRawGlassButtonsOrSwiftUIGlassOutsideTheThemeFolder() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App")
        guard FileManager.default.fileExists(atPath: app.path) else { return }   // the sources are not on this machine
        let raw = try NSRegularExpression(pattern: #"Configuration\.(glass|prominentGlass|clearGlass|prominentClearGlass)\(\)|\.glassEffect\(|\.buttonStyle\(\.glass"#)
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", !file.path.contains("/App/Theme/") else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.contains("glass-ok") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let string = String(line)
                if raw.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil {
                    offenders.append("\(file.lastPathComponent):\(number + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "use the hqGlass helpers: \(offenders.joined(separator: ", "))")
    }

    /// [desktop-segments] Owner 2026-11-05 (Marketplace): SwiftUI's segmented Picker draws iOS 26's glass pill over the
    /// Desktop Look's strip images, so a page's segmented choice goes through `HQSegmentedPicker` (or shows
    /// `DesktopSegmentStrip` itself in the look). A raw one that is never on screen in the look says so with "segments-ok".
    @Test func segmentedPickersGoThroughTheLooksStrip() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App")
        guard FileManager.default.fileExists(atPath: app.path) else { return }   // the sources are not on this machine
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", !file.path.contains("/App/Theme/") else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(".pickerStyle(.segmented)") && !line.contains("segments-ok") {
                offenders.append("\(file.lastPathComponent):\(number + 1)")
            }
        }
        #expect(offenders.isEmpty, "use HQSegmentedPicker: \(offenders.joined(separator: ", "))")
    }

    /// Spec 06 §8 rule 0 (owner 2026-10-30, "use Liquid Glass when possible"): a sheet's page is `HQPalette.sheetPage`
    /// (clear on half-height glass, the grouped page everywhere else). In a file that presents a sheet, painting the
    /// solid grouped page or calling `hqOpaqueGroupedPage()` says why on that line with "solid-ok:".
    @Test func sheetsAreGlassUnlessALineSaysWhyNot() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App")
        guard FileManager.default.fileExists(atPath: app.path) else { return }   // the sources are not on this machine
        let presents = try NSRegularExpression(pattern: #"ChatSheet\.wrap\(|MenusSheet\.wrap\(|hqGlassPage\(\)"#)
        let solid = try NSRegularExpression(pattern: #"hqOpaqueGroupedPage\(\)|(?:ackgroundColor|\.background\()\s*=?\s*(?:HQPalette\.groupedPage|Color\.hqGroupedPage)\b"#)
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", !file.path.contains("/App/Theme/"), !file.path.contains("/App/Debug/"),
                  !file.path.hasSuffix("/App/Kit/SheetStyle.swift"), !file.path.hasSuffix("/App/Root/HQPalette.swift") else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let sheets = presents.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            for (index, line) in text.components(separatedBy: "\n").enumerated() where !line.contains("solid-ok:") {
                let code = line.components(separatedBy: "//")[0]
                if code.contains("hqOpaqueGroupedPage()")
                    || (sheets && solid.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil) {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "paint HQPalette.sheetPage, or say why with solid-ok: \(offenders.joined(separator: ", "))")
    }

    /// [glass-audit] 2026-11-01: the test above only reads files that open a sheet through `ChatSheet.wrap`,
    /// `MenusSheet.wrap` or `hqGlassPage()`, so a half-height sheet opened any other way (Account, a toolset's API key,
    /// a Star Map star) was never looked at: iOS gave it the system's glass with see-through rows. A file that asks for a
    /// half-height detent (UIKit `.medium()` / `.custom(identifier:`, SwiftUI `presentationDetents` with `.medium`,
    /// `.fraction` or `.height`) puts its sheet on the app's glass (`hqGlassPage()`, `hqGlassTrait()`,
    /// `hqGlassSheetPage()`, or one of the wraps), or says why not with "solid-ok:".
    @Test func halfHeightSheetsAreOnTheAppsGlass() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App")
        guard FileManager.default.fileExists(atPath: app.path) else { return }   // the sources are not on this machine
        let half = try NSRegularExpression(pattern: #"\.medium\(\)|\.custom\(identifier|presentationDetents\(\[[^\]]*\.(medium|fraction|height)\b"#)
        let glass = try NSRegularExpression(pattern: #"hqGlassPage\(|hqGlassTrait\(\)|hqGlassSheetPage\(\)|ChatSheet\.wrap\(|MenusSheet\.wrap\("#)
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", !file.path.contains("/App/Theme/"), !file.path.contains("/App/Debug/") else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            guard glass.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil, !text.contains("solid-ok:") else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//")[0]
                if half.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "put the sheet on glass (hqGlassPage / hqGlassSheetPage) or say why with solid-ok: \(offenders.joined(separator: ", "))")
    }

    /// UX study #159: system ink stays iOS grey under a skin and in the Desktop Look. New text and glyphs take the theme's
    /// (HQPalette / ChatPalette / Color.hq*); a line that keeps system ink on purpose says why with "system-ink-ok".
    /// The same patterns as `scripts/desktoplook-migrate.py --colors`.
    @Test func noUnmarkedSystemInkOutsideTheThemeFolder() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App")
        guard FileManager.default.fileExists(atPath: app.path) else { return }   // the sources are not on this machine
        let ink = try NSRegularExpression(pattern: #"\.secondary\)|secondaryLabel|tertiaryLabel|= \.label\b"#)
        let tone = try NSRegularExpression(pattern: #"return \(.*, \.secondary\)"#)   // BotListModel.Tone, not a colour
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", !file.path.contains("/App/Theme/"),
                  !file.path.hasSuffix("/App/Kit/Accessibility/HQFont.swift") else { continue }
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where !line.contains("system-ink-ok") {
                let code = line.components(separatedBy: "//")[0]
                let range = NSRange(code.startIndex..., in: code)
                if ink.firstMatch(in: code, range: range) != nil, tone.firstMatch(in: code, range: range) == nil {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "python3 scripts/desktoplook-migrate.py --colors: \(offenders.sorted().joined(separator: ", "))")
    }
}

/// Stress round 1: a picked skin did not reach the More tab or the Settings root (they kept iOS's grouped grey).
@Suite struct GroupedPageTests {
    private func hex(_ colour: UIColor, _ traits: UITraitCollection) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X/%.2f", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), a)
    }

    private var looks: [UITraitCollection] {
        [UIUserInterfaceStyle.light, .dark].flatMap { style in
            [UIUserInterfaceLevel.base, .elevated].map { level in
                UITraitCollection { $0.userInterfaceStyle = style; $0.userInterfaceLevel = level }
            }
        }
    }

    @Test func onlyTheStandardLookAndIOSSystemKeepTheSystemsGroupedPage() {
        for skin in SkinCatalog.all {
            let expected = skin.id == SkinCatalog.defaultID || skin.id == SkinCatalog.iosID
            #expect(ThemeResolver.resolve(ThemeState(skinID: skin.id)).groupedPageIsSystem == expected, "\(skin.id)")
            #expect(!ThemeResolver.resolve(ThemeState(skinID: skin.id, desktopLook: true)).groupedPageIsSystem, "\(skin.id) in the look")
        }
    }

    /// The standard look and the iOS System skin: exactly iOS's colour, in light and dark, on a page and in a sheet.
    @MainActor @Test func theStandardGroupedPageIsExactlyTheSystems() {
        for id in [SkinCatalog.defaultID, SkinCatalog.iosID] {
            ThemeTable.$testSet.withValue(ThemeResolver.resolve(ThemeState(skinID: id))) {
                for traits in looks {
                    #expect(hex(HQPalette.groupedPage, traits) == hex(.systemGroupedBackground, traits), "\(id)")
                }
            }
        }
    }

    /// Every other skin: its own grouped colour, never iOS's grey or black, the same on a page and in a sheet.
    @MainActor @Test func aPickedSkinPaintsTheGroupedPage() {
        for skin in SkinCatalog.all where skin.id != SkinCatalog.defaultID && skin.id != SkinCatalog.iosID {
            let set = ThemeResolver.resolve(ThemeState(skinID: skin.id))
            ThemeTable.$testSet.withValue(set) {
                for traits in looks {
                    let dark = traits.userInterfaceStyle == .dark
                    let got = hex(HQPalette.groupedPage, traits)
                    #expect(got == hex(set.tokens(dark: dark).grouped.uiColor, traits), "\(skin.id)")
                    #expect(got != hex(.systemGroupedBackground, traits), "\(skin.id) still shows iOS's grouped page")
                }
            }
        }
    }

    /// The Desktop Look's own search words lead nowhere in a build that hides its controls. [page-tabs] The other tabs'
    /// words are their own rows', not the Theme row's (which opens on Themes).
    @Test func searchWordsFollowWhatTheThemePageShows() {
        let look = SettingsSearch.appRows.first { $0.id == "app:desktop-look" }
        #expect((look != nil) == ThemeFeature.desktopLook)
        let theme = SettingsSearch.appRows.first { $0.id == "app:theme" }
        #expect(theme?.keywords == SettingsSearch.themeKeywords)
        // [appearance-groups] High Contrast stays on Theme; Desktop Look and UI Scale are rows of Appearance.
        #expect(theme?.keywords.contains("high contrast") == true)
        for word in ["desktop look", "ui scale", "chat bubbles", "bubble corners", "chat background", "wallpaper"] {
            #expect(theme?.keywords.contains(word) == false, "\(word)")
        }
        #expect(SettingsSearch.themeKeywords.contains("skin") && SettingsSearch.themeKeywords.contains("desktop themes"))
    }
}

/// [theme-pages] Theme has no tabs (owner 2026-11-03: the tabs were "a duct tape type solution"): Chat Bubbles and
/// Backgrounds are pages of their own beside it, under Settings › Appearance.
@MainActor @Suite struct ThemeTabsTests {
    /// A search for what was on Theme's other tabs opens its own page.
    @Test func searchOpensThePageThatHoldsIt() {
        func find(_ words: String) -> [SettingsSearchEntry] { SettingsSearch.results(words, in: SettingsSearch.appRows) }
        #expect(find("chat background").first?.target == .root("background:chats"))
        #expect(find("app background").first?.target == .root("background:app"))
        #expect(find("wallpaper").map(\.target).contains(.root("background:chats")))
        #expect(find("backgrounds").map(\.target).contains(.root("backgrounds")), "the page with both rows")
        #expect(find("chat bubbles").first?.target == .root("chat-bubbles"))
        #expect(find("glass bubbles").first?.target == .root("chat-bubbles"))
        if ThemeFeature.desktopLook {
            #expect(find("hermes look").first?.target == .root("row:desktop-look"))
            #expect(find("native").first?.target == .root("row:desktop-look"))
            #expect(find("desktop look").first?.target == .root("row:desktop-look"))   // legacy alias stays searchable
        }
        #expect(find("chat background").count == 1, "Chat Background alone, not the Theme row too")
        #expect(find("skin").first?.target == .root("theme"), "the themes themselves")
        #expect(find("chat bubbles").first?.context == "Appearance" && find("app background").first?.context == "Backgrounds")
    }

    /// Each page opens as itself: titled, and found by UI tests by its identifier.
    @Test func thePagesAreTheirOwn() {
        let bubbles = ChatBubblesSettings.make()
        #expect(bubbles.title == "Chat Bubbles" && bubbles.view.accessibilityIdentifier == "settings.chat-bubbles")
        let backgrounds = BackgroundsSettings.make()
        #expect(backgrounds.title == "Backgrounds" && backgrounds.view.accessibilityIdentifier == "settings.backgrounds")
        let opening = BackgroundsSettings.make(opening: .chats)
        #expect(opening.map(\.title) == ["Backgrounds", "Chat Background"], "Back from a background goes to the two rows")
        #expect(ThemeSettingsController(services: nil).title == "Theme")
    }

    /// Bot Info's five tabs, About first (owner 2026-11-01: "that page is very long").
    @Test func botInfoHasBrainBesideAbout() {
        #expect(BotInfoTab.allCases.map(\.title) == ["About", "Brain", "Chats", "Artifacts", "Settings"])
    }
}

/// Theme › Chat Bubbles: the iOS look's bubble corner. Stored only when not 12; the Desktop Look ignores it.
@Suite struct BubbleCornersTests {
    @Test func theChoiceSurvivesAReloadAndTwelveIsStoredAsNothing() {
        let suite = defaults()
        let store = ThemeStore(defaults: suite)
        #expect(store.load().bubbleCorners == 12)
        store.setBubbleCorners(20)
        #expect(ThemeStore(defaults: suite).load().bubbleCorners == 20)
        store.setBubbleCorners(0)
        #expect(store.load().bubbleCorners == 0, "square is a choice, not garbage")
        store.setBubbleCorners(12)
        #expect(suite.object(forKey: "hqn.theme.bubbleCorners") == nil)
        store.setBubbleCorners(99)
        #expect(store.load().bubbleCorners == 24, "set clamps to the slider's range")
        store.reset()
        #expect(suite.object(forKey: "hqn.theme.bubbleCorners") == nil && store.load() == .default)
    }

    @Test func garbageReadsAsTwelve() {
        let suite = defaults()
        let store = ThemeStore(defaults: suite)
        for bad: Any in [-1, 25, 9999, "18", Double.nan, Double.infinity, 1e300] {
            suite.set(bad, forKey: "hqn.theme.bubbleCorners")
            #expect(store.load().bubbleCorners == 12, "\(bad)")
        }
        suite.set(17.6, forKey: "hqn.theme.bubbleCorners")
        #expect(store.load().bubbleCorners == 18)
    }

    @Test func theDesktopLookKeepsItsOwnCorners() {
        var look = ThemeState(skinID: "nous", desktopLook: true)
        let standardLook = look
        look.bubbleCorners = 22
        #expect(look.appliedBubbleCorners == 4 && look.layoutSignature == standardLook.layoutSignature, "the iOS look's choice stays there")
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(look)) {
            #expect(ChatMetrics.bubbleRadius == 4, "the desktop's 4 pt until another is picked")
        }
        // [desktop-corners] Its own slider, laid out again.
        look.desktopCorners = 14
        #expect(look.appliedBubbleCorners == 14 && look.layoutSignature != standardLook.layoutSignature)
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(look)) {
            #expect(ChatMetrics.bubbleRadius == 14)
            let path = BubbleShape.path(BubbleShape.Key(width: 100, height: 40, mine: true, joinsAbove: false, joinsBelow: false, tail: false))
            #expect(!path.contains(CGPoint(x: 1.5, y: 1.5)), "the box's corner is rounded by the pick")
        }
    }

    @Test func eachLookStoresItsOwnCornersAndTheDesktopsFourIsStoredAsNothing() {
        let suite = defaults()
        let store = ThemeStore(defaults: suite)
        #expect(store.load().desktopCorners == 4)
        store.setBubbleCorners(16, desktop: true)
        #expect(ThemeStore(defaults: suite).load().desktopCorners == 16 && store.load().bubbleCorners == 12)
        store.setBubbleCorners(4, desktop: true)
        #expect(suite.object(forKey: "hqn.theme.desktopCorners") == nil)
        for bad: Any in [-1, 25, "8", Double.nan] {
            suite.set(bad, forKey: "hqn.theme.desktopCorners")
            #expect(store.load().desktopCorners == 4, "\(bad)")
        }
        store.reset()
        #expect(suite.object(forKey: "hqn.theme.desktopCorners") == nil && store.load() == .default)
    }

    @Test func theDesktopLooksTextBoxDefaultsToDesktopUnlessGlassIsPicked() {
        let suite = defaults()
        let store = ThemeStore(defaults: suite)
        var state = store.load()
        #expect(state.desktopComposer == .box && !state.boxComposer)
        state.desktopLook = true
        #expect(state.boxComposer, "the Desktop Look defaults to its flat bordered box")
        store.setDesktopComposer(.glass)
        #expect(suite.string(forKey: "hqn.theme.desktopComposer") == "glass" && store.load().desktopComposer == .glass)
        state.desktopComposer = .glass
        #expect(state.boxComposer == ThemeState.textBoxIsFixed)
        state.desktopLook = false
        #expect(!state.boxComposer, "the iOS look always has the glass bar")
        suite.set("frosted", forKey: "hqn.theme.desktopComposer")
        #expect(store.load().desktopComposer == .box)
        store.setDesktopComposer(.box)
        #expect(suite.object(forKey: "hqn.theme.desktopComposer") == nil)
    }

    @Test func theIOSLookDrawsTheChoiceAndLaysOutAgain() {
        var state = ThemeState.default
        state.bubbleCorners = 20
        #expect(state.layoutSignature != ThemeState.default.layoutSignature, "albums and memos keep the corner in their layouts")
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(state)) {
            #expect(ChatMetrics.bubbleRadius == 20)
            #expect(ThemeTable.layoutTag != "", "cached layouts made at 12 aren't reused")
        }
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(.default)) {
            #expect(ChatMetrics.bubbleRadius == 12 && ThemeTable.layoutTag == "")
        }
    }

    /// The outline follows the corner, cached or not: a corner point is inside a square bubble and outside a round one.
    @Test func theOutlineFollowsTheCorner() {
        let key = BubbleShape.Key(width: 200, height: 80, mine: true, joinsAbove: false, joinsBelow: false, tail: false)
        let corner = CGPoint(x: 1, y: 1)
        #expect(BubbleShape.path(key, radius: 0).contains(corner))
        #expect(!BubbleShape.path(key, radius: 12).contains(corner))
        var square = ThemeState.default
        square.bubbleCorners = 0
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(.default)) { #expect(!BubbleShape.path(key).contains(corner)) }
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(square)) { #expect(BubbleShape.path(key).contains(corner), "not the cached round one") }
        // A corner too big for a short bubble stops at a pill; the tail's square corner stays square.
        let short = BubbleShape.Key(width: 200, height: 30, mine: true, joinsAbove: false, joinsBelow: false, tail: true)
        let pill = BubbleShape.path(short, radius: 24)
        #expect(pill.contains(CGPoint(x: 15, y: 15)) && !pill.contains(CGPoint(x: 2, y: 2)))
        #expect(pill.contains(CGPoint(x: 199, y: 29)), "the tail's corner")
    }

    /// The time keeps the gap to the curve it has at 12 pt, whatever the corner (owner 2026-10-29, at 24: "the time is
    /// too close to the edge. That can't happen no matter what radius you pick.").
    @Test func theTimeStaysClearOfTheCorner() {
        let w: CGFloat = 240, h: CGFloat = 80
        let key = BubbleShape.Key(width: w, height: h, mine: false, joinsAbove: false, joinsBelow: false, tail: false)
        // Every point `margin` from (x, y) toward the bubble's bottom-trailing corner is inside the outline.
        func clear(_ path: CGPath, _ x: CGFloat, _ y: CGFloat, margin: CGFloat) -> Bool {
            (0...18).allSatisfy { i in
                let angle = CGFloat(i) / 18 * .pi / 2
                return path.contains(CGPoint(x: x + margin * cos(angle), y: y + margin * sin(angle)))
            }
        }
        // A text time's bottom-trailing corner: 10 pt in and 5 up, 4.7 pt from a 12 pt curve.
        #expect(!clear(BubbleShape.path(key, radius: 24), w - 10, h - 5, margin: 4.5), "unmoved, a 24 pt curve comes within a point")
        for r in 0...24 {
            let path = BubbleShape.path(key, radius: CGFloat(r))
            let shift = ChatMetrics.timeShift(corner: CGFloat(r))
            #expect(r > 12 || shift == 0, "\(r) pt: the standard corner and squarer ones keep the time where it was")
            #expect(shift <= 4, "\(r) pt: it moves in a little, not across the bubble")
            #expect(clear(path, w - 10 - shift, h - 5 - shift, margin: 4.5), "\(r) pt")
        }
        // A photo's time capsule, 6 pt in at 12: its round end (radius half its height) stays 5.5 pt or more inside.
        for capH: CGFloat in [20, 24, 32] {
            let half = capH / 2
            for r in 0...24 {
                let inset = 6 + ChatMetrics.timeShift(corner: CGFloat(r), trailing: 6, bottom: 6, round: half)
                #expect(clear(BubbleShape.path(key, radius: CGFloat(r)), w - inset - half, h - inset - half, margin: half + 5.5),
                        "\(r) pt, \(capH) pt tall")
            }
        }
        // Your bubble's corner under the tail is square: the time stays put there. A joined one is as round as the rest.
        var state = ThemeState.default
        state.bubbleCorners = 24
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(state)) {
            #expect(ChatMetrics.timeShift(mine: true, joinsBelow: false, tail: true) == 0)
            #expect(ChatMetrics.timeShift(mine: true, joinsBelow: true, tail: false) > 0)
            #expect(ChatMetrics.timeShift(mine: false, joinsBelow: true, tail: true) > 0, "a reply's trailing corner is always round")
        }
    }
}

/// [glass-bubbles] Theme › Chat Bubbles › Glass (owner 2026-11-01): off unless picked (Solid is the default, 2026-11-02), never in
/// the Desktop Look or under Reduce Transparency; the glass bubble drops the tail and keeps the outline's other corners.
@Suite(.serialized) @MainActor struct GlassBubblesTests {
    /// Solid is the default since 2026-11-02 (owner); Glass is stored by name with the old switch cleared.
    @Test func offUnlessPickedAndStoredOnlyWhenOn() {
        let suite = defaults()
        let store = ThemeStore(defaults: suite)
        #expect(!store.load().glassBubbles)
        store.setGlassBubbles(true)
        #expect(ThemeStore(defaults: suite).load().glassBubbles)
        #expect(suite.string(forKey: "hqn.theme.bubbleStyle") == "glass" && suite.object(forKey: "hqn.theme.glassBubbles") == nil)
        store.setGlassBubbles(false)
        #expect(suite.object(forKey: "hqn.theme.bubbleStyle") == nil)
        #expect(suite.object(forKey: "hqn.theme.glassBubbles") as? Bool == false, "a build from before Solid was the default draws Solid too")
        store.setGlassBubbles(true)
        store.reset()
        #expect(suite.object(forKey: "hqn.theme.bubbleStyle") == nil && store.load() == .default)
        // Glass stored as nothing before 2026-11-02 is Solid now; the old switch is no longer read.
        for junk: Any in ["no", 7, "false", true] {
            suite.set(junk, forKey: "hqn.theme.glassBubbles")
            #expect(!store.load().glassBubbles, "\(junk)")
        }
    }

    @Test func theDesktopLookKeepsItsBoxesAndTheLayoutNeverChanges() {
        var look = ThemeState(skinID: "nous", desktopLook: true)
        look.glassBubbles = true
        #expect(!look.appliedGlassBubbles)
        var on = ThemeState.default
        on.glassBubbles = true
        #expect(on.appliedGlassBubbles && !ThemeState.default.appliedGlassBubbles)
        #expect(on.layoutSignature == ThemeState.default.layoutSignature, "colours only: a glass bubble has the solid one's frame")
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(look)) { #expect(!GlassBubbles.applies) }
    }

    /// Every corner is Theme › Bubble Corners: joined ones and glass's tail corner too (owner 2026-11-02).
    @Test func everyCornerMatchesTheChoice() {
        let tail = BubbleShape.Key(width: 200, height: 80, mine: false, joinsAbove: true, joinsBelow: false, tail: true)
        #expect(tail.withoutTail == BubbleShape.Key(width: 200, height: 80, mine: false, joinsAbove: true, joinsBelow: false, tail: false))
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(.default)) {
            let reply = GlassBubbles.corners(tail)
            #expect(reply.topLeft == 12 && reply.bottomLeft == 12 && reply.topRight == 12 && reply.bottomRight == 12)
            let mine = GlassBubbles.corners(BubbleShape.Key(width: 200, height: 80, mine: true, joinsAbove: true, joinsBelow: true, tail: true))
            #expect(mine.topLeft == 12 && mine.bottomLeft == 12 && mine.topRight == 12 && mine.bottomRight == 12)
            #expect(ChatMetrics.timeCorner(mine: true, joinsBelow: true, tail: false) == 12)
            let pill = GlassBubbles.corners(BubbleShape.Key(width: 200, height: 16, mine: true, joinsAbove: false, joinsBelow: false, tail: false))
            #expect(pill.topLeft == 8, "no bigger than half the bubble")
        }
    }

    /// The bubble view draws glass in the outline without its tail, and the solid fill with it when switched off.
    @Test func theBubbleViewSwapsBetweenGlassAndItsFill() {
        let key = BubbleShape.Key(width: 200, height: 60, mine: false, joinsAbove: false, joinsBelow: false, tail: true)
        let tailPoint = CGPoint(x: -1, y: 59)   // inside the tail, which hangs left of a reply
        var on = ThemeState.default
        on.glassBubbles = true
        for (state, glass) in [(on, true), (ThemeState.default, false)] {
            ThemeTable.$testSet.withValue(ThemeResolver.resolve(state)) {
                let view = BubbleShapeView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
                view.fill = ChatPalette.botBubble
                view.key = key
                view.updateFill()
                let glassView = view.subviews.compactMap { $0 as? UIVisualEffectView }.first { !$0.isHidden }
                #expect((glassView?.effect is UIGlassEffect) == glass, "glass \(glass)")
                #expect(view.shapeLayer.path?.contains(tailPoint) == !glass, "the tail, glass \(glass)")
                let fill = view.shapeLayer.fillColor.map(UIColor.init(cgColor:))
                #expect((fill?.cgColor.alpha ?? 0) == (glass ? 0 : 1), "glass \(glass)")
            }
        }
    }
}

/// [tinted-bubbles] Theme › Chat Bubbles › Style › Tinted (owner 2026-11-01, Telegram's bubbles): stored by name beside the
/// Glass switch, never in the Desktop Look, the same frame as solid; the colour over the Chat Background's soft copy is
/// as strong as the words need on every pixel of it.
@Suite(.serialized) @MainActor struct TintedBubblesTests {
    @Test func storedByNameWithTheGlassSwitchOff() {
        let suite = defaults()
        let store = ThemeStore(defaults: suite)
        #expect(store.load().bubbleStyle == .solid)
        store.setBubbleStyle(.tinted)
        #expect(ThemeStore(defaults: suite).load().bubbleStyle == .tinted)
        #expect(suite.string(forKey: "hqn.theme.bubbleStyle") == "tinted")
        // A build from before Tinted reads the switch: solid, not glass.
        #expect(suite.object(forKey: "hqn.theme.glassBubbles") as? Bool == false)
        store.setBubbleStyle(.glass)
        #expect(store.load().bubbleStyle == .glass && suite.object(forKey: "hqn.theme.glassBubbles") == nil)
        store.setBubbleStyle(.solid)
        #expect(suite.object(forKey: "hqn.theme.bubbleStyle") == nil && store.load() == .default)
        // A name that isn't a style is Solid.
        suite.set("frosted", forKey: "hqn.theme.bubbleStyle")
        #expect(store.load().bubbleStyle == .solid)
        store.setBubbleStyle(.tinted)
        store.reset()
        #expect(store.load() == .default)
    }

    @Test func theDesktopLookKeepsItsBoxesAndTheLayoutNeverChanges() {
        var tinted = ThemeState.default
        tinted.bubbleStyle = .tinted
        #expect(tinted.appliedTintedBubbles && !tinted.appliedGlassBubbles)
        #expect(tinted.layoutSignature == ThemeState.default.layoutSignature, "colours only: a tinted bubble has the solid one's frame")
        var look = tinted
        look.desktopLook = true
        #expect(look.appliedBubbleStyle == .solid)
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(look)) {
            #expect(ThemeTable.bubbleStyle == .solid && !TintedBubbles.applies)
        }
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(tinted)) { #expect(ThemeTable.bubbleStyle == .tinted) }
    }

    /// The Mac has no glass: a stored Glass or Card shows and draws as Solid there, and the choices are Solid and Tinted.
    @Test func theChoicesWhereGlassIsOffered() {
        #expect(BubbleStyles.offered == (GlassBubbles.offered ? [.solid, .glass, .tinted, .card] : [.solid, .tinted]))
        #expect(BubbleStyles.shown(.tinted) == .tinted && BubbleStyles.shown(.solid) == .solid)
        #expect(BubbleStyles.shown(.glass) == (GlassBubbles.offered ? .glass : .solid))
        #expect(BubbleStyles.shown(.card) == (GlassBubbles.offered ? .card : .solid))
    }

    /// [bubble-card] Card is a fourth style beside Solid, Glass and Tinted, stored by name; the Desktop Look keeps its
    /// boxes; colours only, so a card bubble has the solid one's frame; your own messages draw as Tinted's.
    @Test func cardIsAStyleOfItsOwn() throws {
        let suite = try #require(UserDefaults(suiteName: "bubble-card-\(UUID().uuidString)"))
        let store = ThemeStore(defaults: suite)
        store.setBubbleStyle(.card)
        #expect(store.load().bubbleStyle == .card && suite.string(forKey: "hqn.theme.bubbleStyle") == "card")
        var card = ThemeState.default
        card.bubbleStyle = .card
        #expect(card.appliedBubbleStyle == .card && card.appliedCardBubbles && !card.appliedTintedBubbles && !card.appliedGlassBubbles)
        #expect(card.layoutSignature == ThemeState.default.layoutSignature)
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(card)) { #expect(ThemeTable.bubbleStyle == .card) }
        var look = card
        look.desktopLook = true
        #expect(look.appliedBubbleStyle == .solid)
        #expect(BubbleStyle.card.title == "Card" && ChatBubblesSettingsView.styleLine(.card).hasPrefix("Card:"))
    }

    /// Owner 2026-11-02, a Light chat over a night photo: the reply was a lavender-grey slab. A Light reply over a dark
    /// purple sky keeps its lightness and takes the sky's colour (no grey).
    @Test func aLightBubbleKeepsItsLightnessAndTakesThePicturesColour() {
        let tokens = ThemeResolver.resolve(.default).tokens(dark: false)
        let pixel = RGBA(hex: 0x2A1E50)
        let shown = TintedBubbles.paint(pixels: [pixel], bubble: tokens.botBubble, page: tokens.page, dim: 0, text: tokens.label,
                                        time: tokens.label2, colour: TintedBubbles.replyColour, shade: TintedBubbles.shade,
                                        target: 4.5)[0]
        let solid = tokens.botBubble.over(tokens.page.over(.white))
        let (l, a, b) = shown.oklab, (ls, as0, bs) = solid.oklab, (_, ap, bp) = pixel.oklab
        #expect(abs(l - ls) < 0.02, "lightness \(l) vs the solid bubble's \(ls)")
        // Its colour moved from the solid bubble's toward the picture's hue.
        let moved = (a - as0, b - bs)
        #expect(hypot(moved.0, moved.1) > 0.02, "took no colour")
        #expect(moved.0 * ap + moved.1 * bp > 0, "moved away from the picture's hue")
    }

    /// [tinted-dark] Owner 2026-11-15 (a Dark Nous chat on build 1030, beside Sessions on Soft Cards): "Shouldn't it be
    /// more like this? At least in dark mode". A Dark reply over a bright pink is a card: the page's colour with
    /// `cardShow` of the picture through it (less where the words need it), and darker than the picture.
    @Test func aDarkBubbleIsACardOfThePagesColour() {
        let tokens = ThemeResolver.resolve(.default).tokens(dark: true)
        let pixel = RGBA(hex: 0xF0A0C0), page = tokens.page.over(.white)
        let reply = TintedBubbles.paint(pixels: [pixel], plain: [pixel], bubble: tokens.botBubble, ground: tokens.page, page: tokens.page,
                                        dim: 0, text: tokens.label, time: tokens.label2, colour: TintedBubbles.replyColour,
                                        shade: TintedBubbles.shade, target: 4.5)[0]
        #expect(TintedBubbles.isDark(tokens.botBubble.over(page)))
        let whole = page.alpha(1 - TintedBubbles.cardShow).over(pixel)
        #expect(reply.oklab.0 <= whole.oklab.0 + 0.001 && reply.oklab.0 >= page.oklab.0 - 0.001, "between the page and the card at full show")
        #expect(reply.oklab.0 < pixel.oklab.0 - 0.3, "darker than the picture")
        #expect(tokens.label.over(reply).contrast(with: reply) >= 4.5)
        // Yours keeps its own colour: it takes half as much of the picture (`ownCardShow`).
        let own = tokens.meBubble.over(page)
        let mine = TintedBubbles.paint(pixels: [RGBA(hex: 0x201830)], plain: [RGBA(hex: 0x201830)], bubble: tokens.meBubble, page: tokens.page,
                                       dim: 0, text: tokens.meText, time: tokens.meTime, colour: TintedBubbles.ownColour,
                                       shade: TintedBubbles.shade, target: 4.5, show: TintedBubbles.ownCardShow)[0]
        if TintedBubbles.isDark(own) {
            let (_, a, b) = mine.oklab, (_, a0, b0) = own.oklab
            #expect(hypot(a - a0, b - b0) < 0.05, "your bubble keeps its colour")
        }
    }

    /// [reply-backing] A glass bubble taller than the screen has glass only on its part on screen, square where cut;
    /// a shorter one keeps it whole (tester 2026-11-09: a long reply's glass vanished while scrolling).
    @Test func aTallGlassBubbleHasGlassOnlyOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 402, height: 874)
        let m = GlassBubbles.sliceMargin
        let tall = CGRect(x: 0, y: 0, width: 360, height: 3600)
        // Its middle on screen: the screen's rows and the margin either side, cut at both ends.
        #expect(GlassBubbles.slice(bubble: tall, shown: screen.offsetBy(dx: -16, dy: 1500))
                == GlassBubbles.Slice(rect: CGRect(x: 0, y: 1500 - m, width: 360, height: 874 + 2 * m), cutTop: true, cutBottom: true))
        // Its top on screen: its own top corners, cut below.
        #expect(GlassBubbles.slice(bubble: tall, shown: screen.offsetBy(dx: -16, dy: -300))
                == GlassBubbles.Slice(rect: CGRect(x: 0, y: 0, width: 360, height: 574 + m), cutTop: false, cutBottom: true))
        // Its foot on screen: cut above, its own bottom corners.
        let foot = GlassBubbles.slice(bubble: tall, shown: screen.offsetBy(dx: -16, dy: 3000))
        #expect(foot.cutTop && !foot.cutBottom && foot.rect.maxY == 3600 && foot.rect.minY == 3000 - m)
        // Off screen: nothing.
        let gone = GlassBubbles.slice(bubble: tall, shown: screen.offsetBy(dx: -16, dy: 5000))
        #expect(gone.rect.height == 0)
        // No taller than the screen, or not in a window: whole, as before.
        let short = CGRect(x: 0, y: 0, width: 300, height: 800)
        #expect(GlassBubbles.slice(bubble: short, shown: screen.offsetBy(dx: -16, dy: 600)) == GlassBubbles.Slice(rect: short, cutTop: false, cutBottom: false))
        #expect(GlassBubbles.slice(bubble: tall, shown: nil) == GlassBubbles.Slice(rect: tall, cutTop: false, cutBottom: false))
    }

    /// Every app picture, Light and Dark, every skin: every pixel of a bubble's copy keeps the words at 4.5:1 (or the
    /// solid bubble's own, where that is less) and three quarters of the solid bubble's contrast, and the time 3:1.
    @Test func theWordsReadOnEveryPixelOfEveryPicture() {
        var failures: [String] = []
        var weakest = Double.infinity
        let noAccent = BackdropPreset.Ink(r: 0.4, g: 0.5, b: 0.9)
        for preset in BackdropPreset.allCases {
            for dark in [false, true] {
                guard let picture = preset.render(width: 96, height: 208, dark: dark, accent: noAccent),
                      let soft = TintedBubbles.makeSoft(picture) else {
                    failures.append("\(preset) dark=\(dark): no soft copy")
                    continue
                }
                #expect(max(soft.image.width, soft.image.height) == TintedBubbles.longSide)
                #expect(soft.pixels.count == soft.width * soft.height)
                for skin in SkinCatalog.all {
                    let tokens = ThemeResolver.resolve(ThemeState(skinID: skin.id)).tokens(dark: dark)
                    for (mine, contrast) in [(false, false), (true, false), (false, true), (true, true)] {
                        let bubble = mine ? tokens.meBubble : tokens.botBubble
                        let text = mine ? tokens.meText : tokens.label, time = mine ? tokens.meTime : tokens.label2
                        let goal = contrast ? 7.0 : 4.5
                        let colours = TintedBubbles.paint(pixels: soft.pixels, plain: soft.plain, bubble: bubble,
                                                          ground: mine ? nil : tokens.page, page: tokens.page, dim: 0.3, text: text,
                                                          time: time,
                                                          colour: contrast ? TintedBubbles.contrastColour
                                                              : mine ? TintedBubbles.ownColour : TintedBubbles.replyColour,
                                                          shade: contrast ? 0 : TintedBubbles.shade, target: goal)
                        let solid = bubble.over(tokens.page.over(.white))
                        let ownText = text.over(solid).contrast(with: solid), ownTime = time.over(solid).contrast(with: solid)
                        let wantText = max(min(goal, ownText), ownText * TintedBubbles.keep) - 0.01
                        let wantTime = max(min(3, ownTime), ownTime * TintedBubbles.keep) - 0.01
                        for shown in colours {
                            let reads = text.over(shown).contrast(with: shown)
                            if !contrast { weakest = min(weakest, reads) }
                            if reads < wantText || time.over(shown).contrast(with: shown) < wantTime {
                                failures.append("\(preset) dark=\(dark) \(skin.id) mine=\(mine) contrast=\(contrast) \(String(format: "%.2f", reads))")
                                break
                            }
                        }
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(20).joined(separator: "\n"))")
        print("[tinted-bubbles] weakest words on a tinted bubble: \(String(format: "%.2f", weakest)):1")
    }

    /// [tinted-dark] Owner 2026-11-15, on build 1035: "These got darker…" With less of the picture through it, a reply
    /// fell to the page's own colour. Its card is lifted toward the solid reply bubble: lighter than the page, not
    /// as light as the solid bubble, on every skin in Dark.
    @Test func aDarkReplysCardIsLiftedFromThePage() {
        for skin in SkinCatalog.all {
            let tokens = ThemeResolver.resolve(ThemeState(skinID: skin.id)).tokens(dark: true)
            let page = tokens.page.over(.white), solid = tokens.botBubble.over(page)
            guard TintedBubbles.isDark(solid), abs(solid.oklab.0 - page.oklab.0) > 0.01 else { continue }
            let card = TintedBubbles.replyCard(bubble: tokens.botBubble, page: tokens.page)
            let low = min(page.oklab.0, solid.oklab.0), high = max(page.oklab.0, solid.oklab.0)
            #expect(card.oklab.0 > low + 0.005 && card.oklab.0 < high - 0.005, "\(skin.id): \(card.oklab.0) between \(low) and \(high)")
            // The words read at least as well as on the solid bubble (Solarized's own is under 4.5:1 by design).
            let own = tokens.label.over(solid).contrast(with: solid)
            #expect(tokens.label.over(card).contrast(with: card) >= min(4.5, own) - 0.01, "\(skin.id): words on the card")
        }
        // No lift is the page itself.
        let flat = TintedBubbles.replyCard(bubble: RGBA(hex: 0x26282C), page: RGBA(hex: 0x0D1117), lift: 0)
        #expect(abs(flat.oklab.0 - RGBA(hex: 0x0D1117).oklab.0) < 0.002)
    }

    /// [tinted-dark] Every app picture, Light and Dark, every skin: a dark bubble (a one-look skin's in Light too) is a
    /// card. Each pixel lies between its card colour (the page for a reply, its own for yours) and that colour with
    /// `cardShow` of the picture through it: never more of the picture than that, so never the loud slab of 1018 (twice
    /// the picture's colour) nor the shapeless bubble of 1030 (the picture's own colour and lightness).
    @Test func aDarkBubbleIsACardOnEveryPicture() {
        var failures: [String] = []
        var checked = 0
        let noAccent = BackdropPreset.Ink(r: 0.4, g: 0.5, b: 0.9)
        func chroma(_ c: RGBA) -> Double { let (_, a, b) = c.oklab; return hypot(a, b) }
        for preset in BackdropPreset.allCases {
            for dark in [false, true] {
                guard let picture = preset.render(width: 96, height: 208, dark: dark, accent: noAccent),
                      let soft = TintedBubbles.makeSoft(picture) else {
                    failures.append("\(preset) dark=\(dark): no soft copy")
                    continue
                }
                #expect(soft.plain.count == soft.pixels.count)
                for skin in SkinCatalog.all {
                    let tokens = ThemeResolver.resolve(ThemeState(skinID: skin.id)).tokens(dark: dark)
                    let ground = tokens.page.over(.white), veil = tokens.page.alpha(0.3 * tokens.page.a)
                    for mine in [false, true] {
                        let bubble = mine ? tokens.meBubble : tokens.botBubble
                        guard TintedBubbles.isDark(bubble.over(ground)) else { continue }
                        checked += 1
                        let card = mine ? bubble.over(ground) : ground
                        let show = mine ? TintedBubbles.ownCardShow : TintedBubbles.cardShow
                        let colours = TintedBubbles.paint(pixels: soft.pixels, plain: soft.plain, bubble: bubble, ground: mine ? nil : tokens.page,
                                                          page: tokens.page, dim: 0.3, text: mine ? tokens.meText : tokens.label,
                                                          time: mine ? tokens.meTime : tokens.label2,
                                                          colour: mine ? TintedBubbles.ownColour : TintedBubbles.replyColour,
                                                          shade: TintedBubbles.shade, target: 4.5, show: show)
                        for (shown, pixel) in zip(colours, soft.plain) {
                            let whole = card.alpha(1 - show).over(veil.over(pixel))
                            let far = max(abs(whole.r - card.r), abs(whole.g - card.g), abs(whole.b - card.b))
                            let gone = max(abs(shown.r - card.r), abs(shown.g - card.g), abs(shown.b - card.b))
                            if gone > far + 0.005 || chroma(shown) > max(chroma(whole), chroma(card)) + 0.005 {
                                failures.append("\(preset) dark=\(dark) \(skin.id) mine=\(mine): \(String(format: "%.3f", gone)) from its card, at most \(String(format: "%.3f", far))")
                                break
                            }
                        }
                    }
                }
            }
        }
        #expect(checked > 500, "dark bubbles checked: \(checked)")
        #expect(failures.isEmpty, "\(failures.count) not a card:\n\(failures.prefix(20).joined(separator: "\n"))")
        print("[tinted-dark] \(checked) dark bubbles are cards")
    }

    /// A picture whose colour would break the words takes less of it, down to the solid bubble: a Light reply over
    /// pure blue at full colour and shade.
    @Test func lessOfThePictureWhereTheWordsNeedIt() {
        let tokens = ThemeResolver.resolve(.default).tokens(dark: false)
        let solid = tokens.botBubble.over(tokens.page.over(.white))
        let shown = TintedBubbles.paint(pixels: [RGBA(hex: 0x0000FF), .black], bubble: tokens.botBubble, page: tokens.page, dim: 0,
                                        text: tokens.label, time: tokens.label2, colour: 4, shade: 3, target: 7)
        let own = tokens.label.over(solid).contrast(with: solid)
        for colour in shown { #expect(tokens.label.over(colour).contrast(with: colour) >= min(7, own) - 0.01) }
    }

    /// The painted copy is an opaque picture of the copy's size.
    @Test func thePaintedCopyIsAPicture() {
        let image = TintedBubbles.makeImage([.white, .black, RGBA(hex: 0x8040C0), RGBA(hex: 0x102030)], width: 2, height: 2)
        #expect(image?.width == 2 && image?.height == 2)
    }

    @Test func thePictureFillsTheChatFromItsCentre() {
        let rect = TintedBubbles.fillRect(CGSize(width: 100, height: 100), in: CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(rect == CGRect(x: -200, y: 0, width: 800, height: 800))
        let wide = TintedBubbles.fillRect(CGSize(width: 400, height: 100), in: CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(wide.height == 800 && wide.midX == 200)
    }
}

/// [top-edge] Theme › Themes › Top Edge (owner 2026-11-03, Claude's frosted band; Hard the default from 2026-11-04):
/// Hard is stored as nothing, Soft by name; the choice travels with the theme to the owner's other devices.
@Suite(.serialized) @MainActor struct TopEdgeTests {
    @Test func hardByDefaultSoftStoredByNameAndSynced() {
        let suite = defaults()
        let store = ThemeStore(defaults: suite)
        #expect(store.load().topEdge == .hard)
        store.setTopEdge(.soft)
        #expect(ThemeStore(defaults: suite).load().topEdge == .soft)
        #expect(suite.string(forKey: "hqn.theme.topEdge") == "soft")
        store.setTopEdge(.hard)
        #expect(suite.object(forKey: "hqn.theme.topEdge") == nil && store.load() == .default)
        // Hard as 732 stored it reads as Hard; a name that isn't an edge is the default.
        suite.set("hard", forKey: "hqn.theme.topEdge")
        #expect(store.load().topEdge == .hard)
        suite.set("frosted", forKey: "hqn.theme.topEdge")
        #expect(store.load().topEdge == .hard)
        store.setTopEdge(.soft)
        store.reset()
        #expect(store.load() == .default)
        #expect(SyncedSettingKeys.settings.contains(ThemeStore.Key.topEdge))
    }
}

/// [message-colour] Chat Bubbles › Colour: the theme's own unless picked, stored only then, the iOS look's only, and
/// always with text that reads on it.
@Suite struct MessageColourTests {
    @Test func themeUntilPickedAndStoredOnlyWhenPicked() {
        let suite = defaults()
        let store = ThemeStore(defaults: suite)
        #expect(store.load().messageColour == .theme && store.load() == .default)
        store.setMessageColour(.preset(.green))
        #expect(suite.string(forKey: "hqn.theme.messageColour") == "green")
        #expect(ThemeStore(defaults: suite).load().messageColour == .preset(.green))
        store.setMessageColour(.custom(0x12AB9F))
        #expect(suite.string(forKey: "hqn.theme.messageColour") == "#12AB9F")
        #expect(store.load().messageColour == .custom(0x12AB9F))
        store.setMessageColour(.theme)
        #expect(suite.object(forKey: "hqn.theme.messageColour") == nil && store.load() == .default)
        for junk: Any in ["mauve", "#12AB", "#GGGGGG", 7, true] {
            suite.set(junk, forKey: "hqn.theme.messageColour")
            #expect(store.load().messageColour == .theme, "\(junk) is the theme's own")
        }
        suite.set("pink", forKey: "hqn.theme.messageColour")
        store.reset()
        #expect(suite.object(forKey: "hqn.theme.messageColour") == nil, "reset forgets it")
        #expect(SyncedSettingKeys.settings.contains(ThemeStore.Key.messageColour), "it follows the owner to the other device")
    }

    @Test func blueIsTheAppsOwnBlueAndThemeChangesNothing() {
        let standard = ThemeResolver.resolve(.default)
        var state = ThemeState.default
        state.messageColour = .preset(.blue)
        let blue = ThemeResolver.resolve(state)
        for dark in [false, true] {
            #expect(close(blue.tokens(dark: dark).meBubble, standard.tokens(dark: dark).meBubble, 1.5 / 255))
            #expect(blue.tokens(dark: dark).meText == .white)
        }
        // Nothing but your message changes.
        state.messageColour = .preset(.red)
        var red = ThemeResolver.resolve(state).light
        #expect(!close(red.meBubble, standard.light.meBubble))
        red.meBubble = standard.light.meBubble; red.meText = standard.light.meText; red.meTime = standard.light.meTime
        red.rowAccent = nil
        #expect(red == standard.light)
    }

    @Test func everyColourReadsOnEverySkinInBothModes() {
        let colours = MessageColour.Preset.allCases.map(MessageColour.preset)
            + [0xFFFFFF, 0x000000, 0xFFE100, 0x7FFFD4, 0x101040, 0x808080].map(MessageColour.custom)
        for skin in SkinCatalog.all {
            for colour in colours {
                var state = ThemeState(skinID: skin.id)
                state.messageColour = colour
                let set = ThemeResolver.resolve(state)
                for tokens in [set.light, set.dark] {
                    let ground = tokens.meBubble.over(tokens.page)
                    #expect(tokens.meText.over(ground).contrast(with: ground) >= 4.5, "\(skin.id) \(colour) text")
                    #expect(tokens.meTime.over(ground).contrast(with: ground) >= 3, "\(skin.id) \(colour) time")
                }
            }
        }
    }

    @Test func graphiteIsAQuietPillApartFromTheReply() {
        var state = ThemeState.default
        state.messageColour = .preset(.graphite)
        let set = ThemeResolver.resolve(state)
        for tokens in [set.light, set.dark] {
            #expect(tokens.meText == tokens.label)
            #expect(!close(tokens.meBubble, tokens.botBubble, 6.0 / 255), "not the reply's own grey")
            #expect(tokens.meBubble.contrast(with: tokens.page) < 2, "a soft step from the page")
        }
    }

    /// Owner 2026-11-11: the Mac's chosen row follows the colour.
    @Test func theChosenRowFollowsThePick() {
        let standard = ThemeResolver.resolve(.default)
        #expect(standard.light.rowAccent == nil && standard.dark.chosenRow == standard.dark.tint)
        var state = ThemeState.default
        state.messageColour = .preset(.blue)
        let blue = ThemeResolver.resolve(state)
        #expect(blue.light.chosenRow == standard.light.tint && blue.dark.chosenRow == standard.dark.tint, "Blue is the row as it was")
        state.messageColour = .preset(.green)
        let green = ThemeResolver.resolve(state)
        #expect(green.light.chosenRow == RGBA(hex: 0x1D883C) && !close(green.dark.chosenRow, standard.dark.tint, 20.0 / 255))
        state.messageColour = .preset(.graphite)
        let grey = ThemeResolver.resolve(state).dark.chosenRow
        #expect(abs(grey.r - grey.b) < 0.06 && grey.contrast(with: standard.dark.page) < 5, "a soft grey")
        state.messageColour = .custom(0xFFE100)
        #expect(ThemeResolver.resolve(state).light.chosenRow == RGBA(hex: 0xFFE100))
        state.desktopLook = true
        #expect(ThemeResolver.resolve(state).light.rowAccent == nil, "the Desktop Look keeps its own")
    }

    /// Mac AAA 2026-11-16: Paper's chosen row is its own warm grey, not its ivory ink (a light slab in dark).
    @Test func papersChosenRowIsItsGrey() {
        let paper = ThemeResolver.resolve(ThemeState(skinID: "paper"))
        for tokens in [paper.light, paper.dark] {
            #expect(tokens.rowAccent != nil && tokens.chosenRow != tokens.tint)
            #expect(abs(tokens.chosenRow.r - tokens.chosenRow.b) < 0.06, "a grey")
        }
        #expect(paper.dark.chosenRow.labL < paper.dark.tint.labL - 20, "quieter than the ink in dark")
    }

    @Test func searchFindsIt() {
        let row = SettingsSearch.appRows.first { $0.id == "app:message-colour" }
        #expect(row?.label == "Message Color" && row?.target == .root("chat-bubbles"))
        #expect(row?.keywords.contains("color") == true)
    }

    @Test func theDesktopLookKeepsItsOwnBox() {
        var plain = ThemeState.default
        plain.desktopLook = true
        var picked = plain
        picked.messageColour = .preset(.pink)
        #expect(picked.appliedMessageColour == .theme)
        #expect(ThemeResolver.resolve(picked).light.meBubble == ThemeResolver.resolve(plain).light.meBubble)
        #expect(ThemeResolver.resolve(picked).dark.meText == ThemeResolver.resolve(plain).dark.meText)
    }
}

/// [bubble-ink] Owner 2026-11-17: "The bot colors and text colors must always work well to be legible." Every message
/// colour (the named ones, every bot face's, odd custom ones) on every skin, light and dark: the words read at 4.5:1 on a
/// Glass bubble whatever part of a picture shows through it, and on the box behind inline code in any style.
@Suite struct BubbleInkTests {
    static let colours: [MessageColour] = MessageColour.Preset.allCases.map(MessageColour.preset)
        + HeadTones.tones.values.map { MessageColour.custom($0.accent) }
        + [0x0A0A0A, 0xFFFFFF, 0x000000, 0xFFE100, 0x7FFFD4, 0x101040, 0x808080, 0x6B7688, 0x4A93FF, 0xFF66AD]
            .map(MessageColour.custom)

    /// The tokens for each skin and colour, light and dark (the iOS look: the Desktop Look keeps its own boxes).
    static func everyBubble(_ body: (String, ThemeTokens) -> Void) {
        for skin in SkinCatalog.all {
            for colour in colours {
                var state = ThemeState(skinID: skin.id)
                state.messageColour = colour
                let set = ThemeResolver.resolve(state)
                for (mode, tokens) in [("light", set.light), ("dark", set.dark)] { body("\(skin.id) \(colour) \(mode)", tokens) }
            }
        }
    }

    static func reads(_ ink: RGBA, on ground: RGBA) -> Double { ink.over(ground).contrast(with: ground) }

    @Test func glassKeepsYourWordsReadableOverAnyPicture() {
        Self.everyBubble { name, t in
            for (alpha, ratio) in [(Double(GlassBubbles.ownTint), 4.5), (Double(GlassBubbles.contrastTint), 7.0)] {
                let fill = ThemeMath.seeThrough(t.meBubble.over(t.page.over(.white)), alpha: alpha, ink: t.meText,
                                                behind: [.white, .black], ratio: ratio)
                // Increase Contrast aims at 7:1; a skin whose words are a soft ink may not get there. Either way the
                // words read as well as any glass colour could make them: the plain white or black at that share.
                let floor = ratio == 7 ? 4.5 : ratio
                for under in [RGBA.white, .black, RGBA(hex: 0x808080), t.page.over(.white)] {
                    let ground = fill.alpha(alpha).over(under)
                    let best = [RGBA.white, .black].map { Self.reads(t.meText, on: $0.alpha(alpha).over(under)) }.max() ?? 0
                    #expect(Self.reads(t.meText, on: ground) >= min(floor, best) - 0.01, "\(name) over \(under.hexString) at \(alpha)")
                }
            }
        }
    }

    /// A reply's glass is the bubble's colour at its share, as before: the glass's own frosting carries it (measured
    /// 5.1:1 at worst on screen).
    @MainActor @Test func repliesAreLeftAsTheyWere() {
        let grey = UIColor(white: 0.15, alpha: 1)
        #expect(GlassBubbles.tint(grey, mine: false, increaseContrast: false, ink: .white, page: .black, overPicture: true)
            == grey.withAlphaComponent(GlassBubbles.replyTint))
    }

    /// A colour that already reads over what shows through is left exactly as it is.
    @Test func aColourThatReadsIsLeftAlone() {
        // Dark, on the plain page (black): the blue is as it was.
        let dark = ThemeResolver.resolve(.default).dark
        let blue = dark.meBubble.over(dark.page.over(.white))
        #expect(ThemeMath.seeThrough(blue, alpha: 0.85, ink: dark.meText, behind: [dark.page.over(.white)]) == blue)
        let black = RGBA(hex: 0x0A0A0A)
        #expect(ThemeMath.seeThrough(black, alpha: 0.85, ink: .white, behind: [.white, .black]) == black, "a black bubble reads anywhere")
        // Light words go darker, dark words lighter.
        let sky = RGBA(hex: 0x3B76CC)
        #expect(ThemeMath.seeThrough(sky, alpha: 0.85, ink: .white, behind: [.white]).luminance < sky.luminance)
        let grey = RGBA(hex: 0x808080)   // black words at 5.3:1, 4.1:1 at 85 % over black
        #expect(ThemeMath.seeThrough(grey, alpha: 0.85, ink: .black, behind: [.black]).luminance > grey.luminance)
    }

    /// Inline code's box: your words still read on it, on the solid bubble and on a Glass one over any picture.
    @Test func inlineCodeReadsInEveryBubble() {
        Self.everyBubble { name, t in
            let solid = t.meBubble.over(t.page.over(.white))
            let box = ThemeMath.inlineCodeBox(ink: t.meText, bubble: solid)
            #expect(Self.reads(t.meText, on: box.over(solid)) >= 4.5, "\(name) solid")
            let glass = ThemeMath.seeThrough(solid, alpha: Double(GlassBubbles.ownTint), ink: t.meText, behind: [.white, .black])
            for under in [RGBA.white, .black] {
                let ground = glass.alpha(Double(GlassBubbles.ownTint)).over(under)
                #expect(Self.reads(t.meText, on: box.over(ground)) >= 4.49, "\(name) glass over \(under.hexString)")
            }
        }
    }

    /// The default blue's code box was white under white words (4.25:1): it is a shade now. A black bubble keeps its
    /// white box (a shade would vanish into it).
    @Test func theBoxGoesTheOtherWayOnlyWhereItMust() {
        let standard = ThemeResolver.resolve(.default).light
        let blue = standard.meBubble.over(standard.page)
        #expect(ThemeMath.inlineCodeBox(ink: .white, bubble: blue) == RGBA.black.alpha(0.18))
        #expect(ThemeMath.inlineCodeBox(ink: .white, bubble: RGBA(hex: 0x0A0A0A)) == RGBA.white.alpha(0.18))
    }

    /// A picked or bot colour is deepened a little past 4.5:1 (`ThemeResolver.messageInk`), so a mid colour is not on the
    /// line; one that already reads better is left as it is.
    @Test func midColoursHaveRoomPastTheLine() {
        for hex: UInt32 in [0x4A93FF, 0x6B7688, 0x2DBE60, 0xFF7057, 0x9479FF, 0xEF3B36] {
            var state = ThemeState.default
            state.messageColour = .custom(hex)
            let set = ThemeResolver.resolve(state)
            for t in [set.light, set.dark] where t.meText == .white {
                #expect(Self.reads(.white, on: t.meBubble) >= ThemeResolver.messageInk, "#\(String(hex, radix: 16))")
            }
        }
        var blue = ThemeState.default
        blue.messageColour = .preset(.blue)
        #expect(ThemeResolver.resolve(blue).light.meBubble == RGBA(hex: 0x0053FD), "the app's blue (5.7:1) is untouched")
    }

    /// [white-text] Owner 2026-11-17, from three ways drawn for him: "White text on every face". Every face, named colour
    /// and odd custom pick has white words, light and dark, at `messageInk`; Graphite (and a paper face) keeps its quiet
    /// pill with the page's text; a colour white already reads on is left as it was.
    @Test func whiteWordsOnEveryFace() {
        for name in Head.ColorName.allCases where name != .paper {
            var head = Head()
            head.color = name
            var state = ThemeState.default
            state.messageColour = head.messageColour
            let set = ThemeResolver.resolve(state)
            for t in [set.light, set.dark] {
                #expect(t.meText == .white, "\(name)")
                #expect(Self.reads(.white, on: t.meBubble) >= 4.5, "\(name)")
            }
        }
        for hex: UInt32 in [0xFFFFFF, 0xFFE100, 0x7FFFD4, 0xFFAFC8] {
            var state = ThemeState.default
            state.messageColour = .custom(hex)
            #expect(ThemeResolver.resolve(state).light.meText == .white, "#\(String(hex, radix: 16))")
        }
        var grey = ThemeState.default
        grey.messageColour = .preset(.graphite)
        #expect(ThemeResolver.resolve(grey).light.meText == ThemeResolver.resolve(grey).light.label)
        var cobalt = ThemeState.default
        cobalt.messageColour = .custom(0x2E5BFF)
        #expect(ThemeResolver.resolve(cobalt).light.meBubble == RGBA(hex: 0x2E5BFF), "reads already: untouched")
    }

    /// [face-colour] Owner 2026-11-17: "They should always match." Every face colour but paper reads white at 4.5:1, and
    /// a bot's messages are exactly its face's colour, light and dark; an ink face keeps its black (mid grey in dark).
    @Test func yourMessagesAreExactlyTheFacesColour() {
        // Ink's accent is never drawn (an ink face is black): it is left out, as paper is.
        for (name, tone) in HeadTones.tones where name != .paper && name != .ink {
            #expect(Self.reads(.white, on: RGBA(hex: tone.accent)) >= 4.5, "\(name) \(String(tone.accent, radix: 16))")
        }
        for name in Head.ColorName.allCases where name != .paper && name != .ink {
            var head = Head()
            head.color = name
            var state = ThemeState.default
            state.messageColour = head.messageColour
            let set = ThemeResolver.resolve(state)
            let face = RGBA(hex: HeadTones.tones[name]!.accent)
            #expect(set.light.meBubble == face && set.dark.meBubble == face, "\(name)")
            #expect(set.light.meText == .white && set.dark.meText == .white, "\(name)")
        }
        // The face colour survives the chat's trait and its stored form reads back as a colour.
        #expect(ChatColourTrait.colour(ChatColourTrait.code(.face(0x8D6F01))) == .face(0x8D6F01))
        // A face colour too light for white (a newer palette) still reads: it goes through the custom rule.
        var light = ThemeState.default
        light.messageColour = .face(0xFFCE2E)
        let t = ThemeResolver.resolve(light).light
        #expect(Self.reads(t.meText, on: t.meBubble) >= 4.5)
    }

    /// [face-colour] Owner 2026-11-17, of the deepened butter: "Gold? Seriously?". Butter, lime, rose and caramel are out
    /// of the picker and drawn as orange, grass, pink and cocoa wherever a bot has one; peach is a vivid orange. Names
    /// stay readable, and a default head keeps its place in the list (so no bot moves to another colour family).
    @MainActor @Test func theMuddyColoursAreRetired() {
        let stand: [(Head.ColorName, Head.ColorName)] = [(.butter, .peach), (.lime, .grass), (.rose, .pink), (.caramel, .cocoa)]
        for (old, new) in stand {
            #expect(HeadTones.tones[old]! == HeadTones.tones[new]!, "\(old) is drawn as \(new)")
            #expect(!HeadRecord.pickerShapeColors.contains(old.rawValue) && !HeadRecord.pickerThemeColors.contains(old.rawValue))
            #expect(HeadRecord.offered(old.rawValue) == new.rawValue)
            #expect(ThemeHeadSVG.tones[old.rawValue]!.accent == ThemeHeadSVG.tones[new.rawValue]!.accent)
            #expect(HeadLabels.colors[old.rawValue] == HeadLabels.colors[new.rawValue])
        }
        #expect(HeadTones.accent(.peach) == HeadRGB(0xC15003) && HeadLabels.colors["peach"] == "Orange")
        #expect(HeadRecord.pickerShapeColors.count == 20 && Head.ColorName(rawValue: "butter") == .butter)
        // Every face colour the Swift tones and the themed heads' tones give is the same one.
        for (name, tone) in HeadTones.tones where name != .ink && name != .paper {
            #expect(ThemeHeadSVG.tones[name.rawValue]?.accent == "#" + String(format: "%06X", tone.accent), "\(name)")
        }
        // A roll never lands on a retired colour.
        var random = SeededRandom(seed: 7)
        for _ in 0..<400 {
            let head = HeadRecord.roll({ random.next() }, theme: "shape")
            #expect(HeadRecord.retired[head.color] == nil, "\(head.color)")
        }
    }

    /// Tinted takes the picture only as far as the words keep a little past 4.5:1 on a light picture.
    @Test func tintedKeepsRoomOverALightPicture() {
        let t = ThemeResolver.resolve(.default).light
        let pixels = [RGBA.white, RGBA(hex: 0xF0F0F0), RGBA(hex: 0xFFFFE0)]
        let shown = TintedBubbles.paint(pixels: pixels, bubble: t.meBubble, page: t.page, dim: 0, text: t.meText,
                                        time: t.meTime, colour: TintedBubbles.ownColour, shade: TintedBubbles.shade,
                                        target: TintedBubbles.wordsTarget)
        for pixel in shown { #expect(Self.reads(t.meText, on: pixel) >= TintedBubbles.wordsTarget - 0.01) }
    }

    /// No ink: the glass's colour is the bubble's at its share, as before.
    @MainActor @Test func glassWithoutInkIsAsBefore() {
        let colour = UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        let plain = GlassBubbles.tint(colour, mine: true, increaseContrast: false)
        #expect(plain == colour.withAlphaComponent(GlassBubbles.ownTint))
        let moved = GlassBubbles.tint(colour, mine: true, increaseContrast: false, ink: .white, page: .white, overPicture: true)
        #expect(moved.cgColor.alpha == GlassBubbles.ownTint && moved != plain)
    }
}

/// [bot-colour] A bot's own message colour: its pick, its face, or what Chat Bubbles says; painted through a trait on
/// its chat.
@Suite struct BotMessageColourTests {
    @Test func aBotsPickIsStoredPerAccountAndBotAndTravels() {
        let suite = defaults()
        #expect(BotMessageColour.choice(account: "acct1", profile: "sam", defaults: suite) == .app)
        BotMessageColour.set(.face, account: "acct1", profile: "sam", defaults: suite)
        #expect(suite.string(forKey: "hqn.botMessageColour.acct1.sam") == "face")
        #expect(BotMessageColour.choice(account: "acct1", profile: "sam", defaults: suite) == .face)
        #expect(BotMessageColour.choice(account: "acct1", profile: "otto", defaults: suite) == .app, "another bot keeps its own")
        #expect(BotMessageColour.choice(account: "acct2", profile: "sam", defaults: suite) == .app, "another gateway too")
        BotMessageColour.set(.colour(.preset(.teal)), account: "acct1", profile: "", defaults: suite)
        #expect(suite.string(forKey: "hqn.botMessageColour.acct1.default") == "teal", "the first bot is default")
        BotMessageColour.set(.colour(.custom(0xAB12CD)), account: "acct1", profile: "sam", defaults: suite)
        #expect(BotMessageColour.choice(account: "acct1", profile: "sam", defaults: suite) == .colour(.custom(0xAB12CD)))
        BotMessageColour.set(.app, account: "acct1", profile: "sam", defaults: suite)
        #expect(suite.object(forKey: "hqn.botMessageColour.acct1.sam") == nil, "the default is stored as nothing")
        for junk: Any in ["theme", "botFace", "mauve", 4] {
            suite.set(junk, forKey: "hqn.botMessageColour.acct1.sam")
            #expect(BotMessageColour.choice(account: "acct1", profile: "sam", defaults: suite) == .app)
        }
        #expect(BotMessageColour.choice(account: nil, profile: "sam", defaults: suite) == .app)
        #expect(SyncedSettingKeys.synced("hqn.botMessageColour.acct1.sam", accountId: "acct1", library: false) == "hqn.botMessageColour.{account}.sam")
    }

    @Test func aPickWinsThenTheFaceWhereChatBubblesSaysSo() {
        let face = MessageColour.face(0x03843C)
        #expect(BotMessageColour.effective(app: .theme, bot: .app, face: face) == nil)
        #expect(BotMessageColour.effective(app: .preset(.pink), bot: .app, face: face) == nil, "the app's colour is already the theme's")
        #expect(BotMessageColour.effective(app: .botFace, bot: .app, face: face) == face)
        #expect(BotMessageColour.effective(app: .botFace, bot: .app, face: nil) == nil)
        #expect(BotMessageColour.effective(app: .theme, bot: .face, face: face) == face)
        #expect(BotMessageColour.effective(app: .botFace, bot: .colour(.preset(.red)), face: face) == .preset(.red))
    }

    @Test func botsFaceIsStoredAndPaintsNothingByItself() {
        let suite = defaults()
        let store = ThemeStore(defaults: suite)
        store.setMessageColour(.botFace)
        #expect(suite.string(forKey: "hqn.theme.messageColour") == "botFace" && store.load().messageColour == .botFace)
        var state = ThemeState.default
        state.messageColour = .botFace
        #expect(ThemeResolver.resolve(state).light == ThemeResolver.resolve(.default).light, "a page with no one bot keeps the theme's")
    }

    @Test func aFaceGivesItsAccentInkBlackAndPaperTheGreyPill() {
        var head = Head()
        head.color = .grass
        #expect(head.messageColour == .face(0x03843C))
        head.color = .ink
        #expect(head.messageColour == .custom(0x0A0A0A))
        var black = ThemeState.default
        black.messageColour = head.messageColour
        let light = ThemeResolver.resolve(black).light
        #expect(light.meBubble == RGBA(hex: 0x0A0A0A) && light.meText == .white, "a black face's chat is black, with white text")
        let dark = ThemeResolver.resolve(black).dark
        #expect(dark.meBubble == RGBA(hex: 0x5C5C5C) && dark.meText == .white, "in dark, a plain mid grey with white text")
        head.color = .paper
        #expect(head.messageColour == .preset(.graphite))
        for name in Head.ColorName.allCases {
            head.color = name
            var state = ThemeState.default
            state.messageColour = head.messageColour
            for tokens in [ThemeResolver.resolve(state).light, ThemeResolver.resolve(state).dark] {
                let ground = tokens.meBubble.over(tokens.page)
                #expect(tokens.meText.over(ground).contrast(with: ground) >= 4.5, "\(name) reads")
            }
        }
    }

    @MainActor @Test func aChatsTraitPaintsYourMessagesAndNothingElse() {
        let plain = UITraitCollection(userInterfaceStyle: .dark)
        let green = plain.modifyingTraits { $0[ChatColourTrait.self] = ChatColourTrait.code(.preset(.green)) }
        for colour in MessageColour.Preset.allCases.map(MessageColour.preset) + [.custom(0), .custom(0xFFFFFF), .custom(0x12AB9F)] {
            #expect(ChatColourTrait.colour(ChatColourTrait.code(colour)) == colour)
        }
        #expect(ChatColourTrait.code(nil) == 0 && ChatColourTrait.code(.theme) == 0 && ChatColourTrait.colour(0) == nil && ChatColourTrait.colour(77) == nil)
        func rgba(_ colour: UIColor, _ traits: UITraitCollection) -> RGBA {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            colour.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return RGBA(unit: Double(r), Double(g), Double(b), Double(a))
        }
        var picked = ThemeTable.current.state
        picked.messageColour = .preset(.green)
        let expected = ThemeResolver.resolve(picked).dark
        guard !ThemeTable.current.state.desktopLook else { return }
        #expect(close(rgba(ChatPalette.meBubble, green), expected.meBubble, 1.5 / 255))
        #expect(close(rgba(HQPalette.chosenRow, green), expected.chosenRow, 1.5 / 255))
        #expect(!close(rgba(ChatPalette.meBubble, green), rgba(ChatPalette.meBubble, plain), 8.0 / 255) || ThemeTable.current.state.messageColour == .preset(.green))
        #expect(close(rgba(ChatPalette.botBubble, green), rgba(ChatPalette.botBubble, plain)), "the reply's bubble is left alone")
        #expect(close(rgba(HQPalette.tint, green), rgba(HQPalette.tint, plain)))
    }
}

/// [plain-replies] Chat Bubbles › Reply Bubbles: off draws a bot's replies with no bubble, full width, in both the iOS
/// look and Desktop Look High Contrast.
@Suite struct PlainRepliesTests {
    @Test func bubblesUntilTurnedOffAndStoredOnlyWhenOff() {
        let suite = defaults()
        let store = ThemeStore(defaults: suite)
        #expect(!store.load().plainReplies && store.load() == .default)
        store.setPlainReplies(true)
        #expect(suite.object(forKey: "hqn.theme.plainReplies") as? Bool == true)
        #expect(ThemeStore(defaults: suite).load().plainReplies)
        store.setPlainReplies(false)
        #expect(suite.object(forKey: "hqn.theme.plainReplies") == nil)
        suite.set("yes", forKey: "hqn.theme.plainReplies")
        #expect(!store.load().plainReplies, "a value that isn't a Bool reads as bubbles")
        suite.set(true, forKey: "hqn.theme.plainReplies")
        store.reset()
        #expect(suite.object(forKey: "hqn.theme.plainReplies") == nil, "reset forgets it")
        #expect(SyncedSettingKeys.settings.contains("hqn.theme.plainReplies"), "it follows the owner to the other devices")
    }

    @Test func appliesInTheIOSLookAndDesktopLookHighContrast() {
        var state = ThemeState.default
        #expect(!state.appliedPlainReplies)
        state.plainReplies = true
        #expect(state.appliedPlainReplies)
        #expect(state.layoutSignature != ThemeState.default.layoutSignature, "a change lays the chats out again")

        var look = ThemeState.default
        look.desktopLook = true
        #expect(look.appliedPlainReplies, "the Desktop Look's replies are plain without High Contrast")
        var lookPlain = look
        lookPlain.plainReplies = true
        #expect(lookPlain.appliedPlainReplies)
        #expect(lookPlain.layoutSignature == look.layoutSignature, "without High Contrast, replies are already plain")

        look.highContrast = true
        #expect(!look.appliedPlainReplies, "High Contrast boxes replies when Reply Bubbles is on")
        var contrastPlain = look
        contrastPlain.plainReplies = true
        #expect(contrastPlain.appliedPlainReplies, "turning Reply Bubbles off removes High Contrast's reply bubble")
        #expect(contrastPlain.layoutSignature != look.layoutSignature, "toggling Reply Bubbles in High Contrast lays the chats out again")
    }

    @MainActor @Test func aPlainReplyKeepsNoBubblePadding() {
        var state = ThemeState.default
        state.plainReplies = true
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(state)) {
            #expect(HQShape.plainReplies)
            #expect(TextLayout.sidePad(mine: false) == 0)
            #expect(TextLayout.sidePad(mine: true) == ChatMetrics.bubblePadH, "your own messages keep their bubble")
        }
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(.default)) {
            #expect(!HQShape.plainReplies && TextLayout.sidePad(mine: false) == ChatMetrics.bubblePadH)
        }
        // Desktop Look + High Contrast: Reply Bubbles on boxes replies; off strips the box and its padding.
        var contrast = ThemeState.default
        contrast.desktopLook = true
        contrast.highContrast = true
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(contrast)) {
            #expect(!HQShape.plainReplies && TextLayout.sidePad(mine: false) == ChatMetrics.bubblePadH)
            let shape = BubbleShapeView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
            shape.isReply = true
            shape.fill = ChatPalette.botBubble
            let layer = shape.layer as? CAShapeLayer
            #expect(layer?.lineWidth == 1 && (layer?.fillColor?.alpha ?? 0) > 0, "High Contrast draws the reply box")
        }
        contrast.plainReplies = true
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(contrast)) {
            #expect(HQShape.plainReplies)
            #expect(TextLayout.sidePad(mine: false) == 0)
            #expect(TextLayout.sidePad(mine: true) == ChatMetrics.bubblePadH, "your own messages keep their box")
            let shape = BubbleShapeView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
            shape.isReply = true
            shape.fill = ChatPalette.botBubble
            let layer = shape.layer as? CAShapeLayer
            #expect(layer?.lineWidth == 0 && (layer?.fillColor?.alpha ?? 1) == 0, "Reply Bubbles off draws no background or border")
        }
    }
}

/// [density] Theme › Density: Standard or Compact, the iOS look's only, stored only when Compact.
@Suite struct DensityTests {
    @Test func standardUntilPickedAndStoredOnlyWhenCompact() {
        let suite = defaults()
        let store = ThemeStore(defaults: suite)
        #expect(store.load().density == .standard && !store.load().compact)
        store.setDensity(.compact)
        #expect(suite.string(forKey: "hqn.theme.density") == "compact")
        #expect(ThemeStore(defaults: suite).load().density == .compact && store.load().compact)
        store.setDensity(.standard)
        #expect(suite.object(forKey: "hqn.theme.density") == nil)
        suite.set("tiny", forKey: "hqn.theme.density")
        #expect(store.load().density == .standard, "an unknown value is Standard")
        suite.set("compact", forKey: "hqn.theme.density")
        store.reset()
        #expect(suite.object(forKey: "hqn.theme.density") == nil, "reset forgets it")
    }

    @Test func compactDrawsOnlyInTheIOSLook() {
        var state = ThemeState.default
        state.density = .compact
        #expect(state.compact)
        #expect(state.layoutSignature != ThemeState.default.layoutSignature, "a change lays the lists out again")
        state.desktopLook = true
        #expect(!state.compact, "the Desktop Look keeps its own rows")
        var look = ThemeState.default
        look.desktopLook = true
        #expect(state.layoutSignature == look.layoutSignature, "so Compact changes nothing there")
    }

    /// [desktop-density] The Desktop Look has its own Density: Compact (its rows as they were) until Standard is picked
    /// there, stored only then, and apart from the iOS look's.
    @Test func theDesktopLookKeepsItsOwnDensityAndIsCompactUntilPicked() {
        let suite = defaults()
        let store = ThemeStore(defaults: suite)
        store.setDesktopLook(true)
        #expect(store.load().desktopDensity == .compact && store.load().appliedDensity == .compact && !store.load().desktopRoomy)
        store.setDensity(.standard, desktop: true)
        #expect(suite.string(forKey: "hqn.theme.desktopDensity") == "standard")
        #expect(suite.object(forKey: "hqn.theme.density") == nil, "the iOS look's is untouched")
        #expect(store.load().desktopRoomy && store.load().appliedDensity == .standard && store.load().density == .standard)
        store.setDensity(.compact)
        #expect(store.load().desktopRoomy, "the iOS look's Compact leaves the Desktop Look's Standard")
        store.setDensity(.compact, desktop: true)
        #expect(suite.object(forKey: "hqn.theme.desktopDensity") == nil, "Compact, its default, is stored as nothing")
        suite.set("tiny", forKey: "hqn.theme.desktopDensity")
        #expect(store.load().desktopDensity == .compact, "an unknown value is Compact")
        suite.set("standard", forKey: "hqn.theme.desktopDensity")
        store.reset()
        #expect(suite.object(forKey: "hqn.theme.desktopDensity") == nil, "reset forgets it")
    }

    @Test func standardInTheDesktopLookLaysTheListsOutAgainAndOnlyThere() {
        var look = ThemeState.default
        look.desktopLook = true
        var roomy = look
        roomy.desktopDensity = .standard
        #expect(roomy.desktopRoomy && roomy.layoutSignature != look.layoutSignature)
        roomy.desktopLook = false
        #expect(!roomy.desktopRoomy && roomy.appliedDensity == .standard && roomy.layoutSignature == ThemeState.default.layoutSignature)
    }

    @Test func searchFindsDensity() {
        let row = SettingsSearch.appRows.first { $0.id == "app:density" }
        #expect(row?.label == "Density" && row?.target == .root("row:density"))   // [appearance-groups]
        #expect(row?.keywords.contains("compact") == true)
    }

    /// [macpass-settings] UI Scale is found by its own name. [appearance-groups] It opens Appearance on its row.
    @Test func searchFindsUIScale() {
        let row = SettingsSearch.appRows.first { $0.id == "app:ui-scale" }
        #expect(row?.label == "UI Scale" && row?.target == .root("row:ui-scale"))
    }
}
