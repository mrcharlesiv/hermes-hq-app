import Foundation
import Testing
@testable import HermesHQNative

/// UX study 2026-10-19 #95: iOS Increase Contrast turns the Desktop Look's High Contrast on; a picked skin says it keeps
/// its own colours; with the setting off nothing changes.
@Suite struct ThemeContrastTests {
    private func state(look: Bool, contrast: Bool = false, skin: String = "midnight") -> ThemeState {
        ThemeState(skinID: skin, desktopLook: look, highContrast: contrast, uiScalePercent: 100)
    }

    @Test func theLookCarriesItsHighContrastMixesForIncreaseContrast() {
        let off = ThemeResolver.resolve(state(look: true))
        let on = ThemeResolver.resolve(state(look: true, contrast: true))
        for dark in [false, true] {
            #expect(off.tokens(dark: dark, increaseContrast: true) == on.tokens(dark: dark))
            // Increase Contrast off: the owner-tuned colours, unchanged.
            #expect(off.tokens(dark: dark, increaseContrast: false) == off.tokens(dark: dark))
        }
        // The switch on already draws them; the iOS look carries none (the standard look has its own values).
        #expect(on.systemContrastLight == nil && on.systemContrastDark == nil)
        let ios = ThemeResolver.resolve(state(look: false))
        #expect(ios.systemContrastLight == nil && ios.tokens(dark: false, increaseContrast: true) == ios.tokens(dark: false))
    }

    @Test func theSwitchShowsWhyItIsOn() {
        let look = state(look: true)
        #expect(!ThemeContrast.switchOn(look, increaseContrast: false))
        #expect(ThemeContrast.switchOn(look, increaseContrast: true))
        #expect(ThemeContrast.switchNote(look, increaseContrast: true) == ThemeContrast.systemNote)
        #expect(ThemeContrast.switchNote(look, increaseContrast: false) == nil)
        #expect(ThemeContrast.switchNote(state(look: true, contrast: true), increaseContrast: true) == nil)
    }

    @Test func aPickedSkinSaysItKeepsItsColours() {
        #expect(ThemeContrast.skinGridNote(state(look: false), increaseContrast: true) == ThemeContrast.skinNote)
        #expect(ThemeContrast.skinGridNote(state(look: false), increaseContrast: false) == nil)
        #expect(ThemeContrast.skinGridNote(state(look: false, skin: SkinCatalog.defaultID), increaseContrast: true) == nil)
        #expect(ThemeContrast.skinGridNote(state(look: true), increaseContrast: true) == nil)
    }
}
