// A skin's own paint for the iOS look and its own code colours, where the general rule (the desktop's chrome mix for
// the page, cards a step of ink, iOS's greys, your message the solid accent, GitHub's code colours) doesn't draw the
// theme as the theme draws itself. Rosé Pine: the owner's mockup of 2026-11-02 (the page its base, replies on its
// surface inside a faint line, your message a soft iris box with the theme's own text, tables with only their header
// row shaded, Rosé Pine code colours). Paper (owner 2026-11-16): Claude's ivory page exactly, not pulled toward grey,
// warm greys in place of iOS's cool ones, replies on the page with no bubble and your message a soft paper box, as
// Claude draws them.

import Foundation

/// One mode of a skin's own iOS look. Colours from the theme's own palette; nothing here is mixed at run time.
nonisolated struct SkinOwnLook: Sendable, Hashable {
    /// The chat's page and every page's background (instead of `ThemeResolver.chrome`).
    var page: RGBA
    /// Replies, cards, sheets' cards and the composer's box.
    var card: RGBA
    /// A row while pressed.
    var pressed: RGBA
    /// Your message's box; its words are the theme's text.
    var meBubble: RGBA
    /// A code card, opaque, in a reply.
    var codeFill: RGBA
    /// The grey of iOS's fills (120,120,128), separators and search fields, in the theme's own hue. Its alpha is
    /// ignored: the fills keep iOS's own shares.
    var grey: RGBA
    var fillAlphas: [Double]
    var separator: RGBA
    /// The faint line round a reply's bubble, as round its code and tables (owner 2026-11-02: "the chat bubbles have
    /// like a little faint line around them").
    var replyEdge: RGBA
    /// A table's header row; its other rows are the bubble's own colour.
    var tableHead: RGBA
    /// How much of the reply's colour lies over glass (replies otherwise take 55 %, which lifted Main's surface a step
    /// toward grey).
    var replyGlassTint: Double
    /// Secondary and tertiary words.
    var subtle: RGBA
    var muted: RGBA
    /// A reply's bubble, where it isn't `card`: Paper's replies lie on the page itself, as Claude's do.
    var reply: RGBA? = nil
    /// Explicit grouped canvas background behind grouped cards when the seed sidebar equals the page (e.g. Everforest).
    var grouped: RGBA? = nil
    /// Explicit text color on `meBubble` (nil uses the theme's `label`, as Paper and Rosé Pine do).
    var meText: RGBA? = nil
    /// [paper-icons] The tile behind a Settings or More row's glyph, the glyph in the theme's own text, instead of iOS's
    /// coloured tiles with white glyphs (owner 2026-11-16, Paper "needs a lot of work"). nil: iOS's tiles.
    var iconTile: RGBA? = nil
    /// True for skins that draw bare monochrome glyphs without a tile (Paper); false draws harmonized `iconTile` pills.
    var plainIcons = false
    /// [paper-pills] Pills and chips on pages (Sessions' bots, Tasks' views, Tiles' pages, Kanban's statuses, New Job's
    /// picks) are drawn flat in this skin: unpicked on the card with a hairline, picked in the solid accent with its own
    /// ink, the same on every page. Otherwise iOS's Liquid Glass.
    var flatPills = false
    /// [Mac AAA 2026-11-16] What the Mac's chosen row is tinted with (`ThemeTokens.chosenRow`, drawn see-through by
    /// `MacSelection.accent`), where the skin's accent would shout: Paper's accent is its ink, so in dark the chosen row
    /// (sidebar, Settings' column, every list) was a light grey slab. nil: the accent, as every other skin.
    var chosenRow: RGBA? = nil

    nonisolated struct Pair: Sendable, Hashable {
        var light: SkinOwnLook
        var dark: SkinOwnLook
        func pick(_ dark: Bool) -> SkinOwnLook { dark ? self.dark : light }
    }
}

/// A skin's code colours by highlighter kind (`SyntaxPalette`), before they are made readable on the code card.
nonisolated struct SyntaxColours: Sendable, Hashable {
    var comment: RGBA
    var keyword: RGBA
    var string: RGBA
    var constant: RGBA
    var entity: RGBA
    var function: RGBA
    var tag: RGBA
    var invalid: RGBA

    func map(_ change: (RGBA) -> RGBA) -> SyntaxColours {
        SyntaxColours(comment: change(comment), keyword: change(keyword), string: change(string), constant: change(constant),
                      entity: change(entity), function: change(function), tag: change(tag), invalid: change(invalid))
    }

    nonisolated struct Pair: Sendable, Hashable {
        var light: SyntaxColours
        var dark: SyntaxColours
        func pick(_ dark: Bool) -> SyntaxColours { dark ? self.dark : light }
    }
}

nonisolated extension SkinCatalog {
    /// Rosé Pine's palettes (rosepinetheme.com/en/palette): Dawn and Main.
    private enum Dawn {
        static let base = RGBA(hex: 0xFAF4ED), surface = RGBA(hex: 0xFFFAF3), overlay = RGBA(hex: 0xF2E9E1)
        static let muted = RGBA(hex: 0x9893A5), subtle = RGBA(hex: 0x797593)
        static let love = RGBA(hex: 0xB4637A), gold = RGBA(hex: 0xEA9D34), pine = RGBA(hex: 0x286983)
        static let foam = RGBA(hex: 0x56949F), iris = RGBA(hex: 0x907AA9)
    }
    private enum Main {
        static let base = RGBA(hex: 0x191724), surface = RGBA(hex: 0x1F1D2E), overlay = RGBA(hex: 0x26233A)
        static let muted = RGBA(hex: 0x6E6A86), subtle = RGBA(hex: 0x908CAA)
        static let love = RGBA(hex: 0xEB6F92), gold = RGBA(hex: 0xF6C177), pine = RGBA(hex: 0x31748F)
        static let foam = RGBA(hex: 0x9CCFD8), iris = RGBA(hex: 0xC4A7E7)
    }

    /// Paper's palettes: Claude's ivory (sampled from the owner's screenshots), and black with warm greys in dark.
    private enum Ivory {
        static let page = RGBA(hex: 0xF8F9F3), card = RGBA(hex: 0xFDFDFA), drawer = RGBA(hex: 0xF2F3EE)
        static let selected = RGBA(hex: 0xE4E5DD), box = RGBA(hex: 0xE9EAE2)
        static let grey = RGBA(hex: 0x86857B), subtle = RGBA(hex: 0x4A4A47), muted = RGBA(hex: 0x8A897F)
    }
    private enum Charcoal {
        /// (page, card, code, pressed row, your message's box) by darkness. Black (owner 2026-11-16, picked from these four
        /// after the charcoal: "I don't like the dark mode background"). DEBUG builds draw another with
        /// `-HQDebugPaperDark charcoal|deep|night|black`, to compare.
        private static let steps: [String: [UInt32]] = [
            "charcoal": [0x262624, 0x30302D, 0x1F1E1D, 0x3A3A37, 0x3D3C38],
            "deep": [0x1C1B19, 0x262523, 0x151413, 0x302F2C, 0x33322F],
            "night": [0x121211, 0x1C1C1A, 0x0B0B0A, 0x262624, 0x2A2A27],
            "black": [0x000000, 0x161615, 0x0E0E0D, 0x1E1E1C, 0x242422],
        ]
        private static let chosen: [UInt32] = {
            #if DEBUG
            if let pick = UserDefaults.standard.string(forKey: "HQDebugPaperDark"), let step = steps[pick] { return step }
            #endif
            return steps["black"]!
        }()
        static let page = RGBA(hex: chosen[0]), card = RGBA(hex: chosen[1]), deep = RGBA(hex: chosen[2])
        static let selected = RGBA(hex: chosen[3]), box = RGBA(hex: chosen[4])
        static let grey = RGBA(hex: 0x8E8D84), subtle = RGBA(hex: 0xB7B5AC), muted = RGBA(hex: 0x8A8980)
    }

    static let ownLooks: [String: SkinOwnLook.Pair] = [
        "paper": SkinOwnLook.Pair(
            light: SkinOwnLook(page: Ivory.page, card: Ivory.card, pressed: Ivory.selected, meBubble: Ivory.box,
                               codeFill: Ivory.drawer, grey: Ivory.grey, fillAlphas: [0.2, 0.16, 0.12, 0.08],
                               separator: Ivory.grey.alpha(0.3), replyEdge: RGBA(unit: 0, 0, 0, 0), tableHead: Ivory.drawer,
                               replyGlassTint: 0.85, subtle: Ivory.subtle, muted: Ivory.muted, reply: Ivory.page,
                               iconTile: Ivory.selected, plainIcons: true, flatPills: true, chosenRow: Ivory.grey),
            dark: SkinOwnLook(page: Charcoal.page, card: Charcoal.card, pressed: Charcoal.selected, meBubble: Charcoal.box,
                              codeFill: Charcoal.deep, grey: Charcoal.grey, fillAlphas: [0.36, 0.32, 0.24, 0.12],
                              separator: Charcoal.grey.alpha(0.3), replyEdge: RGBA(unit: 0, 0, 0, 0),
                              tableHead: Charcoal.grey.alpha(0.2), replyGlassTint: 0.85, subtle: Charcoal.subtle,
                              muted: Charcoal.muted, reply: Charcoal.page, iconTile: Charcoal.selected, plainIcons: true,
                              flatPills: true, chosenRow: Charcoal.grey)),
        "rose-pine": SkinOwnLook.Pair(
            // Your box: the mockup's lavender, iris leaning to love.
            light: SkinOwnLook(page: Dawn.base, card: Dawn.surface, pressed: Dawn.overlay, meBubble: RGBA(hex: 0xEADCEF),
                               codeFill: Dawn.overlay, grey: Dawn.muted, fillAlphas: [0.2, 0.16, 0.12, 0.08],
                               separator: Dawn.muted.alpha(0.35), replyEdge: Dawn.muted.alpha(0.35), tableHead: Dawn.overlay,
                               replyGlassTint: 0.85, subtle: Dawn.subtle, muted: Dawn.muted),
            // Code on the page's base, a shade under the reply, as in the mockup; lines and the table's header a fifth
            // to a third of the grey (iOS's strengths drew them a step brighter than the mockup).
            dark: SkinOwnLook(page: Main.base, card: Main.surface, pressed: Main.overlay, meBubble: RGBA(hex: 0x4D3357),
                              codeFill: Main.base, grey: Main.muted, fillAlphas: [0.36, 0.32, 0.24, 0.12],
                              separator: Main.muted.alpha(0.3), replyEdge: Main.muted.alpha(0.3), tableHead: Main.muted.alpha(0.2),
                              replyGlassTint: 0.85, subtle: Main.subtle, muted: Main.muted)),
        "everforest": SkinOwnLook.Pair(
            // Warm sage neutrals, crisp ivory card lift off a warm grouped canvas, and harmonized sage row tiles.
            light: SkinOwnLook(page: RGBA(hex: 0xFDF6E3), card: RGBA(hex: 0xFFFDF5), pressed: RGBA(hex: 0xEAE3CD),
                               meBubble: RGBA(hex: 0x586B35), codeFill: RGBA(hex: 0xEBE4CE), grey: RGBA(hex: 0x829181),
                               fillAlphas: [0.20, 0.16, 0.12, 0.08], separator: RGBA(hex: 0x829181).alpha(0.28),
                               replyEdge: RGBA(hex: 0x939F91).alpha(0.32), tableHead: RGBA(hex: 0x829181).alpha(0.16),
                               replyGlassTint: 0.85, subtle: RGBA(hex: 0x5C6A72), muted: RGBA(hex: 0x829181),
                               reply: RGBA(hex: 0xF4EEDB), grouped: RGBA(hex: 0xF4ECD8), meText: .white,
                               iconTile: RGBA(hex: 0xE6E1CB)),
            dark: SkinOwnLook(page: RGBA(hex: 0x2D353B), card: RGBA(hex: 0x343F44), pressed: RGBA(hex: 0x3D484D),
                              meBubble: RGBA(hex: 0x475843), codeFill: RGBA(hex: 0x272E33), grey: RGBA(hex: 0x859289),
                              fillAlphas: [0.34, 0.28, 0.22, 0.14], separator: RGBA(hex: 0x859289).alpha(0.30),
                              replyEdge: RGBA(hex: 0x859289).alpha(0.28), tableHead: RGBA(hex: 0x859289).alpha(0.18),
                              replyGlassTint: 0.85, subtle: RGBA(hex: 0x9DA9A0), muted: RGBA(hex: 0x7A8478),
                              reply: RGBA(hex: 0x343F44), grouped: RGBA(hex: 0x232A2E), meText: RGBA(hex: 0xE8DEC8),
                              iconTile: RGBA(hex: 0x3D484D))),
        "mono": {
            let look = SkinOwnLook(page: RGBA(hex: 0x0D0D0D), card: RGBA(hex: 0x181818), pressed: RGBA(hex: 0x262626),
                                   meBubble: RGBA(hex: 0x333333), codeFill: RGBA(hex: 0x131313), grey: RGBA(hex: 0x8E8E8E),
                                   fillAlphas: [0.32, 0.26, 0.20, 0.12], separator: RGBA(hex: 0x8E8E8E).alpha(0.28),
                                   replyEdge: RGBA(hex: 0x8E8E8E).alpha(0.22), tableHead: RGBA(hex: 0x8E8E8E).alpha(0.16),
                                   replyGlassTint: 0.85, subtle: RGBA(hex: 0xA3A3A3), muted: RGBA(hex: 0x737373),
                                   reply: RGBA(hex: 0x1B1B1B), grouped: RGBA(hex: 0x090909), meText: RGBA(hex: 0xF5F5F5),
                                   iconTile: RGBA(hex: 0x242424), chosenRow: RGBA(hex: 0x8E8E8E))
            return SkinOwnLook.Pair(light: look, dark: look)
        }(),
        "cyberpunk": {
            let look = SkinOwnLook(page: RGBA(hex: 0x000A00), card: RGBA(hex: 0x021704), pressed: RGBA(hex: 0x042808),
                                   meBubble: RGBA(hex: 0x063B18), codeFill: RGBA(hex: 0x011202), grey: RGBA(hex: 0x1A8A30),
                                   fillAlphas: [0.32, 0.26, 0.20, 0.12], separator: RGBA(hex: 0x1A8A30).alpha(0.38),
                                   replyEdge: RGBA(hex: 0x1A8A30).alpha(0.34), tableHead: RGBA(hex: 0x1A8A30).alpha(0.18),
                                   replyGlassTint: 0.85, subtle: RGBA(hex: 0x38B852), muted: RGBA(hex: 0x1A8A30),
                                   reply: RGBA(hex: 0x031B06), grouped: RGBA(hex: 0x000600), meText: RGBA(hex: 0xA6FFC0),
                                   iconTile: RGBA(hex: 0x042808))
            return SkinOwnLook.Pair(light: look, dark: look)
        }(),
        "vercel": SkinOwnLook.Pair(
            // Pure white in light and true OLED black in dark, keeping crisp neutral elevation and electric blue bubbles.
            light: SkinOwnLook(page: RGBA(hex: 0xFFFFFF), card: RGBA(hex: 0xF4F4F5), pressed: RGBA(hex: 0xE6E6E8),
                               meBubble: RGBA(hex: 0x006AFF), codeFill: RGBA(hex: 0xEFEFF1), grey: RGBA(hex: 0x737373),
                               fillAlphas: [0.20, 0.16, 0.12, 0.08], separator: RGBA(hex: 0x737373).alpha(0.32),
                               replyEdge: RGBA(hex: 0x737373).alpha(0.24), tableHead: RGBA(hex: 0xEAEAEC),
                               replyGlassTint: 0.85, subtle: RGBA(hex: 0x555555), muted: RGBA(hex: 0x737373),
                               reply: RGBA(hex: 0xF4F4F5), grouped: RGBA(hex: 0xF5F5F6), meText: .white),
            dark: SkinOwnLook(page: RGBA(hex: 0x000000), card: RGBA(hex: 0x141414), pressed: RGBA(hex: 0x222222),
                              meBubble: RGBA(hex: 0x005CE0), codeFill: RGBA(hex: 0x0C0C0C), grey: RGBA(hex: 0x888888),
                              fillAlphas: [0.34, 0.28, 0.22, 0.14], separator: RGBA(hex: 0x888888).alpha(0.32),
                              replyEdge: RGBA(hex: 0x888888).alpha(0.24), tableHead: RGBA(hex: 0x1A1A1A),
                              replyGlassTint: 0.85, subtle: RGBA(hex: 0xA1A1A1), muted: RGBA(hex: 0x737373),
                              reply: RGBA(hex: 0x141414), grouped: RGBA(hex: 0x0A0A0A), meText: .white)),
    ]

    /// Skin-matched code syntax palettes; each colour is checked against the skin's code surface for 4.5:1 readability
    /// in `ThemeResolver.syntax`. Nous, GitHub, and iOS System intentionally remain on GitHub's syntax palette.
    static let syntaxColours: [String: SyntaxColours.Pair] = [
        // [paper-code] Paper's code (owner 2026-11-16, "needs a lot of work"): muted and warm in place of GitHub's bright
        // blue, purple and red. Keywords terracotta, strings olive, constants and types amber-brown, functions the ink,
        // comments the warm grey. Each is taken just far enough to read at 4.5:1 on the code card (`ThemeTokens.syntax`).
        "paper": SyntaxColours.Pair(
            light: SyntaxColours(comment: RGBA(hex: 0x8A897F), keyword: RGBA(hex: 0x9C4A2E), string: RGBA(hex: 0x5C6B2F),
                                 constant: RGBA(hex: 0x8A5A00), entity: RGBA(hex: 0x7A5230), function: RGBA(hex: 0x3D3A35),
                                 tag: RGBA(hex: 0x9C4A2E), invalid: RGBA(hex: 0xB42318)),
            dark: SyntaxColours(comment: RGBA(hex: 0x8A8980), keyword: RGBA(hex: 0xD99A7A), string: RGBA(hex: 0xB5C28A),
                                constant: RGBA(hex: 0xD8B46A), entity: RGBA(hex: 0xC9A98A), function: RGBA(hex: 0xECEBE4),
                                tag: RGBA(hex: 0xD99A7A), invalid: RGBA(hex: 0xF07167))),
        "rose-pine": SyntaxColours.Pair(
            light: SyntaxColours(comment: Dawn.subtle, keyword: Dawn.love, string: Dawn.gold, constant: Dawn.pine,
                                 entity: Dawn.gold, function: Dawn.iris, tag: Dawn.foam, invalid: Dawn.love),
            dark: SyntaxColours(comment: Main.subtle, keyword: Main.love, string: Main.gold, constant: Main.pine,
                                entity: Main.gold, function: Main.iris, tag: Main.foam, invalid: Main.love)),
        "everforest": SyntaxColours.Pair(
            light: SyntaxColours(comment: RGBA(hex: 0x7A8478), keyword: RGBA(hex: 0xB85651), string: RGBA(hex: 0x7F8A3A),
                                 constant: RGBA(hex: 0x9E6B30), entity: RGBA(hex: 0x9E6B30), function: RGBA(hex: 0x5E7C3A),
                                 tag: RGBA(hex: 0x358268), invalid: RGBA(hex: 0xC04444)),
            dark: SyntaxColours(comment: RGBA(hex: 0x859289), keyword: RGBA(hex: 0xE67E80), string: RGBA(hex: 0xA7C080),
                                constant: RGBA(hex: 0xD699B6), entity: RGBA(hex: 0xDBBC7F), function: RGBA(hex: 0x83C092),
                                tag: RGBA(hex: 0x7FBBB3), invalid: RGBA(hex: 0xE67E80))),
        "catppuccin": SyntaxColours.Pair(
            light: SyntaxColours(comment: RGBA(hex: 0x6C6F85), keyword: RGBA(hex: 0x8839EF), string: RGBA(hex: 0x40A02B),
                                 constant: RGBA(hex: 0xFE640B), entity: RGBA(hex: 0xDF8E1D), function: RGBA(hex: 0x1E66F5),
                                 tag: RGBA(hex: 0x179299), invalid: RGBA(hex: 0xD20F39)),
            dark: SyntaxColours(comment: RGBA(hex: 0x9399B2), keyword: RGBA(hex: 0xCBA6F7), string: RGBA(hex: 0xA6E3A1),
                                constant: RGBA(hex: 0xFAB387), entity: RGBA(hex: 0xF9E2AF), function: RGBA(hex: 0x89B4FA),
                                tag: RGBA(hex: 0x94E2D5), invalid: RGBA(hex: 0xF38BA8))),
        "solarized": SyntaxColours.Pair(
            light: SyntaxColours(comment: RGBA(hex: 0x657B83), keyword: RGBA(hex: 0x859900), string: RGBA(hex: 0x2AA198),
                                 constant: RGBA(hex: 0xCB4B16), entity: RGBA(hex: 0xB58900), function: RGBA(hex: 0x268BD2),
                                 tag: RGBA(hex: 0x6C71C4), invalid: RGBA(hex: 0xDC322F)),
            dark: SyntaxColours(comment: RGBA(hex: 0x839496), keyword: RGBA(hex: 0x859900), string: RGBA(hex: 0x2AA198),
                                constant: RGBA(hex: 0xCB4B16), entity: RGBA(hex: 0xB58900), function: RGBA(hex: 0x268BD2),
                                tag: RGBA(hex: 0x6C71C4), invalid: RGBA(hex: 0xDC322F))),
        "mono": {
            let s = SyntaxColours(comment: RGBA(hex: 0x828282), keyword: RGBA(hex: 0xFFFFFF), string: RGBA(hex: 0xC8C8C8),
                                  constant: RGBA(hex: 0xB2B2B2), entity: RGBA(hex: 0xDCDCDC), function: RGBA(hex: 0xEDEDED),
                                  tag: RGBA(hex: 0xBDBDBD), invalid: RGBA(hex: 0xE08080))
            return SyntaxColours.Pair(light: s, dark: s)
        }(),
        "cyberpunk": {
            let s = SyntaxColours(comment: RGBA(hex: 0x359648), keyword: RGBA(hex: 0x00FF66), string: RGBA(hex: 0xB8FF70),
                                  constant: RGBA(hex: 0xFFB84D), entity: RGBA(hex: 0xFFC966), function: RGBA(hex: 0x5CFFD6),
                                  tag: RGBA(hex: 0x4DFF88), invalid: RGBA(hex: 0xFF4D79))
            return SyntaxColours.Pair(light: s, dark: s)
        }(),
        "midnight": {
            let s = SyntaxColours(comment: RGBA(hex: 0x7C7AB0), keyword: RGBA(hex: 0xB4A7FF), string: RGBA(hex: 0x8AD8E6),
                                  constant: RGBA(hex: 0xE2A6FF), entity: RGBA(hex: 0x9BB8FF), function: RGBA(hex: 0xC8C0FF),
                                  tag: RGBA(hex: 0x7EC8E3), invalid: RGBA(hex: 0xF0719B))
            return SyntaxColours.Pair(light: s, dark: s)
        }(),
        "ember": {
            let s = SyntaxColours(comment: RGBA(hex: 0xAA7A56), keyword: RGBA(hex: 0xFF9E57), string: RGBA(hex: 0xF5D08A),
                                  constant: RGBA(hex: 0xFF7B54), entity: RGBA(hex: 0xFFC278), function: RGBA(hex: 0xFFE0B2),
                                  tag: RGBA(hex: 0xE69F6B), invalid: RGBA(hex: 0xFF6B57))
            return SyntaxColours.Pair(light: s, dark: s)
        }(),
        "slate": {
            let s = SyntaxColours(comment: RGBA(hex: 0x8B949E), keyword: RGBA(hex: 0x79C0FF), string: RGBA(hex: 0xA5D6FF),
                                  constant: RGBA(hex: 0xD2A8FF), entity: RGBA(hex: 0xFFA657), function: RGBA(hex: 0x9ECBFF),
                                  tag: RGBA(hex: 0x7EE787), invalid: RGBA(hex: 0xFF7B72))
            return SyntaxColours.Pair(light: s, dark: s)
        }(),
        "nous-alt": SyntaxColours.Pair(
            light: SyntaxColours(comment: RGBA(hex: 0x666678), keyword: RGBA(hex: 0x0040CC), string: RGBA(hex: 0x166534),
                                 constant: RGBA(hex: 0x6D28D9), entity: RGBA(hex: 0x9A3412), function: RGBA(hex: 0x1D4ED8),
                                 tag: RGBA(hex: 0x0F766E), invalid: RGBA(hex: 0xBE123C)),
            dark: SyntaxColours(comment: RGBA(hex: 0xB5C7F3), keyword: RGBA(hex: 0xFFE6CB), string: RGBA(hex: 0x9FE3D8),
                                constant: RGBA(hex: 0xF7C59F), entity: RGBA(hex: 0xFFD6A5), function: RGBA(hex: 0xC8DCFF),
                                tag: RGBA(hex: 0x96D6FF), invalid: RGBA(hex: 0xFF8A80))),
        "codex": SyntaxColours.Pair(
            light: SyntaxColours(comment: RGBA(hex: 0x636369), keyword: RGBA(hex: 0x751ED9), string: RGBA(hex: 0x008A36),
                                 constant: RGBA(hex: 0x0169CC), entity: RGBA(hex: 0x9A5000), function: RGBA(hex: 0x0169CC),
                                 tag: RGBA(hex: 0x0F766E), invalid: RGBA(hex: 0xE02E2A)),
            dark: SyntaxColours(comment: RGBA(hex: 0x8E8E93), keyword: RGBA(hex: 0xB06DFF), string: RGBA(hex: 0x4ADE80),
                                constant: RGBA(hex: 0x52A8FF), entity: RGBA(hex: 0xF5B44A), function: RGBA(hex: 0x52A8FF),
                                tag: RGBA(hex: 0x5EEAD4), invalid: RGBA(hex: 0xFF6B6B))),
        "notion": SyntaxColours.Pair(
            light: SyntaxColours(comment: RGBA(hex: 0x787774), keyword: RGBA(hex: 0x6940A5), string: RGBA(hex: 0x0F7B6C),
                                 constant: RGBA(hex: 0xB85C00), entity: RGBA(hex: 0x9A4B26), function: RGBA(hex: 0x266EB8),
                                 tag: RGBA(hex: 0x0F7B6C), invalid: RGBA(hex: 0xA31515)),
            dark: SyntaxColours(comment: RGBA(hex: 0x9B9A97), keyword: RGBA(hex: 0xB088E6), string: RGBA(hex: 0x4EC9B0),
                                constant: RGBA(hex: 0xE5A760), entity: RGBA(hex: 0xE6A17C), function: RGBA(hex: 0x63A8EE),
                                tag: RGBA(hex: 0x4EC9B0), invalid: RGBA(hex: 0xFA6B68))),
        "vercel": SyntaxColours.Pair(
            light: SyntaxColours(comment: RGBA(hex: 0x666666), keyword: RGBA(hex: 0xA100F8), string: RGBA(hex: 0x1D8236),
                                 constant: RGBA(hex: 0x006AFF), entity: RGBA(hex: 0xB45309), function: RGBA(hex: 0x006AFF),
                                 tag: RGBA(hex: 0x0E7490), invalid: RGBA(hex: 0xEB001D)),
            dark: SyntaxColours(comment: RGBA(hex: 0x888888), keyword: RGBA(hex: 0xC084FC), string: RGBA(hex: 0x46D369),
                                constant: RGBA(hex: 0x52A8FF), entity: RGBA(hex: 0xF5A623), function: RGBA(hex: 0x52A8FF),
                                tag: RGBA(hex: 0x5EEAD4), invalid: RGBA(hex: 0xFF6166))),
        "night-owl": {
            let s = SyntaxColours(comment: RGBA(hex: 0x7E97AC), keyword: RGBA(hex: 0xC792EA), string: RGBA(hex: 0xECC48D),
                                  constant: RGBA(hex: 0xF78C6C), entity: RGBA(hex: 0xFFCB8B), function: RGBA(hex: 0x82AAFF),
                                  tag: RGBA(hex: 0x7FDBCA), invalid: RGBA(hex: 0xEF5350))
            return SyntaxColours.Pair(light: s, dark: s)
        }(),
        "lobster": {
            let s = SyntaxColours(comment: RGBA(hex: 0x94A3B8), keyword: RGBA(hex: 0xFF7373), string: RGBA(hex: 0x4ADE80),
                                  constant: RGBA(hex: 0xFBBF24), entity: RGBA(hex: 0xFB923C), function: RGBA(hex: 0x60A5FA),
                                  tag: RGBA(hex: 0x38BDF8), invalid: RGBA(hex: 0xFF5C5C))
            return SyntaxColours.Pair(light: s, dark: s)
        }(),
    ]
}
