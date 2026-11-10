// Settings › Appearance (spec 1x-settings §3.5): System (default), Light or Dark for the whole app, on this device.
// Applied to every window before the first frame and at once on change.

import UIKit

enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "hqn.appearance"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var style: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    static var current: AppearanceSetting {
        get { UserDefaults.standard.string(forKey: key).flatMap(AppearanceSetting.init(rawValue:)) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            applyEverywhere()
        }
    }

    /// [desktoplook2] The look a one-look skin (Midnight, Ember, Mono, Slate, Cyberpunk) draws in both modes, or nil
    /// when the skin has Light and Dark. While it is set the windows take it, whatever the person picked; their own
    /// choice is kept and comes back with the next skin that has both looks.
    static var forcedBySkin: AppearanceSetting? { forced(by: ThemeTable.current.forcedDark) }

    static func forced(by forcedDark: Bool?) -> AppearanceSetting? {
        guard let forcedDark else { return nil }
        return forcedDark ? .dark : .light
    }

    /// What the Appearance row shows: the forced look while a one-look skin is picked, else the person's choice.
    static var shown: AppearanceSetting { forcedBySkin ?? current }

    static func apply(to window: UIWindow?) {
        window?.overrideUserInterfaceStyle = Theme.shared.style(for: current.style)   // [desktoplook] a one-look skin
    }

    static func applyEverywhere() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = Theme.shared.style(for: current.style) }
        }
    }
}
