// A skin's own paint for the iOS look and its own code colours, where the general rule (the desktop's chrome mix for
// the page, cards a step of ink, iOS's greys, your message the solid accent, GitHub's code colours) doesn't draw the
// theme as the theme draws itself. Rosé Pine only: the owner's mockup of 2026-11-02 (the page its base, replies on its
// surface inside a faint line, your message a soft iris box with the theme's own text, tables with only their header
// row shaded, Rosé Pine code colours).

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

    static let ownLooks: [String: SkinOwnLook.Pair] = [
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
    ]

    /// Keywords love, function names iris, constants pine, types gold (the mockup's), strings gold, comments subtle, tags
    /// foam, errors love. Pine is the light constant; it is made readable in dark with the rest.
    static let syntaxColours: [String: SyntaxColours.Pair] = [
        "rose-pine": SyntaxColours.Pair(
            light: SyntaxColours(comment: Dawn.subtle, keyword: Dawn.love, string: Dawn.gold, constant: Dawn.pine,
                                 entity: Dawn.gold, function: Dawn.iris, tag: Dawn.foam, invalid: Dawn.love),
            dark: SyntaxColours(comment: Main.subtle, keyword: Main.love, string: Main.gold, constant: Main.pine,
                                entity: Main.gold, function: Main.iris, tag: Main.foam, invalid: Main.love)),
    ]
}
