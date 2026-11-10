// [app-icons] Settings › Appearance › App Icon (iPhone and iPad; on the Mac the Dock's icon, `MacDockIcon`): the
// icons the app can wear. This list is the one place an icon is added or taken away: each entry is an icon set of the
// same name in App/Resources/Assets.xcassets (`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS` makes every set there
// an alternate), and `AppIconTests` fails when the two disagree. The drawn ones (`Art.shapes`, `.matrix`, `.robot`)
// are painted by the app's own head code (`AppIconArt`) and written into their sets by
// `TEST_RUNNER_HQ_WRITE_APP_ICONS=1` (AppIconTests.testWriteDrawnIcons); `.picture` sets hold artwork made elsewhere
// (an alternate one also has an "<id>-Preview" image set for the picker).
// [icon-look] Each icon also comes pinned to one look, "<id>-Light" and "<id>-Dark" (scripts/make-pinned-icons.py), for
// Settings › App Icon › Look.

import SwiftUI
import UIKit

nonisolated struct AppIconChoice: Identifiable, Hashable, Sendable {
    /// What the icon is drawn from.
    enum Art: String, Hashable, Sendable {
        /// Artwork made outside the app (Hermes, the feathers): its set's PNGs are the source.
        case picture
        /// The plain Shapes head, the main bot's colour, two slit eyes.
        case shapes
        /// The dot-matrix head, 20 LEDs across.
        case matrix
        /// The original ink robot (the web app's first icon), eyes only.
        case robot
    }

    /// The icon set's name in the asset catalog ("AppIcon" is the app's own icon).
    let id: String
    /// The picker's caption.
    let title: String
    let art: Art

    static let primary = "AppIcon"

    /// The name iOS knows the icon by (`setAlternateIconName`); nil for the app's own icon.
    var alternateName: String? { id == Self.primary ? nil : id }

    /// Every icon, in the picker's order. Add or remove one here and in the asset catalog, nowhere else.
    static let all: [AppIconChoice] = [
        // Hermes in profile, winged cap, black-and-white ink (the owner's own picture, 2026-11-01: "Add this one"; then
        // "I want the default icon to be the Hermes guy").
        AppIconChoice(id: primary, title: "Hermes", art: .picture),
        // The ink feather, the app's own icon until Hermes took its place.
        AppIconChoice(id: "AppIcon-Feather", title: "Feather", art: .picture),
        // The first feather (hermes-ios 653ef6c1, 2026-10-04): three pearl blades on near-black (owner: "the OG
        // feather icon we had").
        AppIconChoice(id: "AppIcon-Pearl", title: "Original", art: .picture),
        // The black-and-white feather the owner is choosing between (artifacts/manga-feather v2.py, draft D): kept or
        // dropped with that pick.
        AppIconChoice(id: "AppIcon-BlackWhite", title: "Black & White", art: .picture),
        AppIconChoice(id: "AppIcon-Shapes", title: "Shapes", art: .shapes),
        AppIconChoice(id: "AppIcon-Matrix", title: "Matrix", art: .matrix),
        AppIconChoice(id: "AppIcon-Robot", title: "Robot", art: .robot),
    ]

    /// The name iOS knows the icon by in `look`: "AppIcon-Feather-Dark" for the feather pinned dark.
    func alternateName(_ look: AppIconLook) -> String? { look == .automatic ? alternateName : id + look.suffix }

    /// Every icon set the catalog holds: each icon in each look.
    static var allSetNames: [String] { all.flatMap { choice in AppIconLook.allCases.map { choice.id + $0.suffix } } }

    /// The icon and look an icon name stands for (nil: the app's own icon, automatic). A name an older build had is
    /// the app's own icon.
    static func worn(named name: String?) -> (choice: AppIconChoice, look: AppIconLook) {
        guard let name else { return (all[0], .automatic) }
        for look in [AppIconLook.light, .dark] where name.hasSuffix(look.suffix) {
            if let choice = all.first(where: { $0.id == name.dropLast(look.suffix.count) }) { return (choice, look) }
        }
        return (all.first { $0.id == name } ?? all[0], .automatic)
    }

    static func choice(named name: String?) -> AppIconChoice { worn(named: name).choice }
}

/// [icon-look] Whether the icon follows the Home Screen between light and dark, or keeps one look whatever the phone
/// does. Owner 2026-11-02: "I'd like for the users to be able to choose if they want to let the icon change with their
/// phone going from light mode to dark mode and for them to be able to pin one of the options so that it doesn't
/// change." Tinted Home Screens still tint a pinned icon (that is a look of its own).
nonisolated enum AppIconLook: String, CaseIterable, Identifiable, Hashable, Sendable {
    case automatic, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "System"   // as Appearance calls following the phone (it said Automatic)
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The pinned set's name ends in this.
    var suffix: String {
        switch self {
        case .automatic: ""
        case .light: "-Light"
        case .dark: "-Dark"
        }
    }

    /// Whether the icon is dark, given whether the page (or the Mac) is: a pinned look ignores it.
    func isDark(onDark dark: Bool) -> Bool {
        switch self {
        case .automatic: dark
        case .light: false
        case .dark: true
        }
    }
}

/// The icon the app wears now, and changing it.
@MainActor enum AppIcons {
    /// Whether this device can change the icon. The Mac has no alternate icons; there it is the Dock's (`MacDockIcon`).
    static var canChange: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return UIApplication.shared.supportsAlternateIcons
        #endif
    }

    static var current: AppIconChoice { worn.choice }

    /// The icon worn now and its look.
    static var worn: (choice: AppIconChoice, look: AppIconLook) { AppIconChoice.worn(named: wornName) }

    /// Settings' App Icon row: "Hermes", or "Hermes, Dark" when pinned.
    static var wornTitle: String {
        let (choice, look) = worn
        return look == .automatic ? choice.title : "\(choice.title), \(look.title)"
    }

    private static var wornName: String? {
        #if targetEnvironment(macCatalyst)
        return MacDockIcon.chosen
        #else
        return UIApplication.shared.alternateIconName
        #endif
    }

    /// Asks iOS for `choice` in `look` (it shows its own "You have changed the icon" alert); the error, if any. On the
    /// Mac the Dock takes it at once, with no alert.
    static func use(_ choice: AppIconChoice, look: AppIconLook) async -> Error? {
        let name = choice.alternateName(look)
        guard canChange, name != wornName else { return nil }
        #if targetEnvironment(macCatalyst)
        MacDockIcon.chosen = name
        MacDockIcon.apply()
        NotificationCenter.default.post(name: changed, object: nil)
        return nil
        #else
        do {
            try await UIApplication.shared.setAlternateIconName(name)
            AppLog.note("settings", "app icon \(choice.id) \(look.rawValue)")
            NotificationCenter.default.post(name: changed, object: nil)
            return nil
        } catch {
            AppLog.note("settings", "app icon \(choice.id) \(look.rawValue) refused: \(error.localizedDescription)")
            return error
        }
        #endif
    }

    /// A tester 2026-11-02: with another icon chosen, opening the app still showed the Hermes head first. The system
    /// launch screen lost its icon in 38f18904, but iOS keeps the picture it took of the old one (Library/SplashBoard)
    /// across an update until the phone restarts. Once per build, that picture is thrown away so iOS takes a new one
    /// (the page colour alone) the next time the app opens.
    static func dropStaleLaunchPicture() {
        #if !targetEnvironment(macCatalyst)
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let key = "HQLaunchPictureDroppedBuild"
        guard UserDefaults.standard.string(forKey: key) != build else { return }
        UserDefaults.standard.set(build, forKey: key)
        let splash = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/SplashBoard")
        guard FileManager.default.fileExists(atPath: splash.path) else { return }
        do {
            try FileManager.default.removeItem(at: splash)
            AppLog.note("settings", "launch picture dropped (build \(build))")
        } catch {
            AppLog.note("settings", "launch picture kept: \(error.localizedDescription)")
        }
        #endif
    }

    /// The icon as the Home Screen shows it, `pixels` square, in the page's look. iOS keeps an alternate icon's
    /// pictures to itself (they are icon renditions in the compiled catalog, not images), so: a drawn face drawn here
    /// by the same code that drew its icon, and artwork from its "<id>-Preview" image set, light and dark
    /// (scripts/make-light-icons.py writes both; AppIconTests checks each has them).
    static func picture(_ choice: AppIconChoice, dark: Bool, pixels: Int) -> UIImage? {
        let key = "\(choice.id)|\(dark)|\(pixels)"
        if let made = previews[key] { return made }
        var made: UIImage?
        switch choice.art {
        case .picture:
            // Owner 2026-11-02: "Every icon that we have for people to use needs dark mode and light mode options."
            // The look is fixed here (a bare catalog image would pick its own again from wherever it is drawn).
            let look = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            made = UIImage(named: choice.id + "-Preview", in: nil, compatibleWith: look)?.cgImage.map { UIImage(cgImage: $0) }
        case .shapes, .matrix, .robot:
            made = AppIconArt.image(choice.art, variant: dark ? .dark : .light, pixels: pixels).map { UIImage(cgImage: $0) }
        }
        previews[key] = made
        return made
    }

    private static var previews: [String: UIImage] = [:]

    /// Posted after the icon changes, so the pictures of it inside the app follow at once.
    static let changed = Notification.Name("HQAppIconChanged")

    /// The picture of the icon the app wears, for the places inside the app that show it (the launch screen, Settings'
    /// gateway card, Welcome, Sign In, Offline, Update Hermes). Tester 2026-11-02: the icon changed on the
    /// Home Screen only, and every one of those kept the Hermes head. Nil for the app's own icon (automatic): those
    /// places then draw "LaunchIcon", already cut to the icon's shape, exactly as before. Any other icon is a full
    /// square, so it is drawn as the picker draws it (`AppIconPreview`, `roundedIcon`), in its pinned look if it has one.
    static func wornPicture(dark: Bool, pixels: Int) -> UIImage? {
        let (choice, look) = worn
        guard choice.alternateName(look) != nil else { return nil }
        return picture(choice, dark: look.isDark(onDark: dark), pixels: pixels)
    }
}

/// The icon the app wears, `side` points square: "LaunchIcon" for the app's own icon, otherwise the chosen icon as the
/// icon picker draws it. Follows a change made in Settings while it is on screen.
struct WornAppIcon: View {
    let side: CGFloat
    @State private var worn = AppIcons.worn

    var body: some View {
        Group {
            if worn.choice.alternateName(worn.look) == nil {
                Image("LaunchIcon")
                    .resizable()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous))
            } else {
                AppIconPreview(choice: worn.choice, side: side, look: worn.look)
            }
        }
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: AppIcons.changed)) { _ in worn = AppIcons.worn }
    }
}
