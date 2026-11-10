// desktoplook: the bundled theme skins (spec 3x-desktoplook §4.2). Labels, descriptions and order are the desktop's
// (`themes/presets.ts:66-415`), plus Rosé Pine, the app's own; the palettes live in SkinSeeds.generated.swift.

import Foundation

/// One palette of a skin: the slots of `ThemePresetColors` the phone uses.
nonisolated struct SkinSeeds: Sendable, Hashable {
    var background: RGBA
    var foreground: RGBA
    var card: RGBA
    var muted: RGBA
    var mutedForeground: RGBA
    var popover: RGBA
    var primary: RGBA
    var secondary: RGBA
    var accent: RGBA
    var border: RGBA
    var input: RGBA
    var ring: RGBA
    var midground: RGBA?
    var composerRing: RGBA?
    var destructive: RGBA
    var sidebarBackground: RGBA?
    var sidebarBorder: RGBA?
    var userBubble: RGBA?
    var userBubbleBorder: RGBA?

    /// The brand accent (`c.midground ?? c.ring`, context.tsx).
    var brand: RGBA { midground ?? ring }
    /// What the desktop paints for this palette whatever mode was asked (`renderedModeFor`, context.tsx:185-201).
    var rendersDark: Bool { 0.2126 * background.r + 0.7152 * background.g + 0.0722 * background.b <= 0.5 }
}

nonisolated struct Skin: Sendable, Hashable, Identifiable {
    var id: String
    var label: String
    var description: String
    /// A typeface iOS ships, or nil for the system font.
    var sansFamily: String?
    var light: SkinSeeds
    var dark: SkinSeeds?
    /// Its own iOS look and code colours (SkinOwnLooks.swift), nil for the general rules.
    var ownLook: SkinOwnLook.Pair? = nil
    var syntax: SyntaxColours.Pair? = nil

    /// One palette only (Midnight, Ember, Mono, Slate, Cyberpunk): Light and Dark draw the same.
    var hasOneLook: Bool { dark == nil }
    /// The theme card's tag for a one-palette skin: "Dark Only" / "Light Only" (stress test 2026-10-28 #88), nil otherwise.
    var onlyModeTag: String? { hasOneLook ? (light.rendersDark ? "Dark Only" : "Light Only") : nil }

    func seeds(dark wantsDark: Bool) -> SkinSeeds { wantsDark ? (dark ?? light) : light }
}

nonisolated enum SkinCatalog {
    static let defaultID = "nous"
    /// The default before this layer existed (the migration compares against it, §4.4).
    static let oldDefaultID = "nous"
    static let iosID = "ios"
    /// The desktop's default skin: what the Desktop Look hands iOS System over to (§5.6).
    static let desktopDefaultID = "nous"

    private static let meta: [(String, String, String, String?)] = [
        ("nous", "Nous", "Neutral greys with Nous blue", nil),   // UX study #70: was "GitHub chrome, Nous blue accent"
        ("github", "GitHub", "GitHub Light Default and Dark Default", nil),
        ("catppuccin", "Catppuccin", "Soothing pastels — Latte and Mocha", nil),
        ("everforest", "Everforest", "Warm, low-contrast forest greens", nil),
        ("solarized", "Solarized", "Fixed-contrast light and dark", nil),
        // Not a desktop skin (owner 2026-11-01): its palettes are desktop-tokens.py's APP_ONLY table.
        ("rose-pine", "Rosé Pine", "Muted pine, rosé and iris — Dawn and Main", nil),
        ("nous-alt", "Nous Alt", "Glass neutrals, cream on mission-blue", nil),
        ("midnight", "Midnight", "Deep blue-violet with cool accents", nil),
        ("ember", "Ember", "Warm crimson and bronze — forge vibes", nil),
        ("mono", "Mono", "Clean grayscale — minimal and focused", nil),
        ("slate", "Slate", "Cool slate blue — focused developer theme", nil),
        ("cyberpunk", "Cyberpunk", "Neon green on black — matrix terminal", "Courier New"),
        // [mac] Stress test 2026-10-28 #27: on a Mac the same colours are the Mac's own system colours too.
        ("ios", DeviceWord.isMac ? "Apple System" : "iOS System",
         DeviceWord.isMac ? "Apple’s system colours, true black in dark, system blue" : "iOS colours, true black in dark, system blue", nil),
    ]

    static let all: [Skin] = meta.compactMap { id, label, description, sans in
        guard let pair = seeds[id] else { return nil }
        return Skin(id: id, label: label, description: description, sansFamily: sans, light: pair.light, dark: pair.dark,
                    ownLook: ownLooks[id], syntax: syntaxColours[id])
    }

    static func skin(_ id: String) -> Skin? { all.first { $0.id == id } }
    /// A stored id that is not in the catalog (retired, corrupt) draws as the default.
    static func resolved(_ id: String?) -> Skin { id.flatMap(skin) ?? skin(defaultID) ?? all[0] }
}
