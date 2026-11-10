// [a11y] iOS Increase Contrast under the Desktop Look and picked skins (UX study 2026-10-19 #95). The standard look has
// its own stronger values (ThemedColor.increased); the Desktop Look takes its High Contrast mixes, unchanged; a picked
// skin keeps its own colours and the Theme page says so.

import Foundation

nonisolated enum ThemeContrast {
    /// The set carries the High Contrast mixes for iOS Increase Contrast: the Desktop Look with its switch off.
    static func followsSystem(_ state: ThemeState) -> Bool { state.desktopLook && !state.highContrast }

    /// The Theme page's High Contrast switch reads on when it is, or when iOS Increase Contrast turns it on.
    static func switchOn(_ state: ThemeState, increaseContrast: Bool) -> Bool { state.highContrast || increaseContrast }

    #if targetEnvironment(macCatalyst)
    static let systemNote = "On while Increase Contrast is on in System Settings › Accessibility › Display."   // [mac]
    #else
    static let systemNote = "On while Increase Contrast is on in iOS Settings › Accessibility › Display & Text Size."
    #endif
    static let skinNote = "This theme keeps its own colours when Increase Contrast is on in \(DeviceWord.settingsApp)."

    /// What the High Contrast switch's note adds: why it is on, when iOS turned it on.
    static func switchNote(_ state: ThemeState, increaseContrast: Bool) -> String? {
        increaseContrast && !state.highContrast ? systemNote : nil
    }

    /// What the skin grid's note adds in the iOS look: a picked skin does not follow Increase Contrast.
    static func skinGridNote(_ state: ThemeState, increaseContrast: Bool) -> String? {
        increaseContrast && !state.desktopLook && state.skinID != SkinCatalog.defaultID ? skinNote : nil
    }
}
