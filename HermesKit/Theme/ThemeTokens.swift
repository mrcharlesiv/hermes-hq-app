// desktoplook: one resolved colour set per mode, and the resolver that makes it from the theme state
// (spec 3x-desktoplook §4.3, §5.1, §5.5, §6). Pure and nonisolated; unit tested.

import Foundation

nonisolated struct ThemeTokens: Sendable, Hashable {
    var page: RGBA
    var label: RGBA
    var label2: RGBA
    var label3: RGBA
    var tint: RGBA
    var tintText: RGBA
    var onTint: RGBA
    var separator: RGBA
    var fill1: RGBA
    var fill2: RGBA
    var fill2OnPage: RGBA
    var fill3: RGBA
    var fill4: RGBA
    var cellPressed: RGBA
    var groupedCard: RGBA
    var lifted: RGBA
    var searchFill: RGBA
    var orange: RGBA
    var red: RGBA
    var alertRed: RGBA
    var green: RGBA
    var muted: RGBA
    var botBubble: RGBA
    var meBubble: RGBA
    var meText: RGBA
    var meTime: RGBA
    var codeFill: RGBA
    var codeFillOnBubble: RGBA
    var codeText: RGBA
    var grouped: RGBA
    var statusWorking: RGBA
    // Only drawn in the Desktop Look (the iOS look gives them sensible values so nothing reads an unset colour).
    /// Cards, the message bar, code: the desktop's editor surface.
    var editor: RGBA
    /// Floating panels and the docked tab bar in dark.
    var elevated: RGBA
    /// Sheets' page and the docked tab bar in light.
    var sidebar: RGBA
    var strokePrimary: RGBA
    var strokeSecondary: RGBA
    var strokeTertiary: RGBA
    /// Outline of your message box.
    var meBorder: RGBA
    /// Outline of the message bar (the Desktop Look's, while you type; at rest it takes strokeSecondary).
    var composerBorder: RGBA
    /// The message bar's ☰, + and mic glyphs: label-2, the desktop's tertiary text in the Desktop Look.
    var composerGlyph: RGBA
    /// The message field's caret: the tint, the text colour in the Desktop Look (a desktop textarea's own caret).
    var caret: RGBA
    /// A tab that is not picked.
    var tabIdle: RGBA
    /// A skin's own code colours, readable on its code card (nil: the GitHub colours, `SyntaxPalette`).
    var syntax: SyntaxColours? = nil
    /// A skin's own iOS look (`SkinOwnLook`), nil for the general rules and in the Desktop Look.
    var ownLook: SkinOwnLook? = nil

    /// A table card: Fill 4, with its header row Fill 4 again over it, unless a skin shades the header alone.
    var tableBody: RGBA { ownLook == nil ? fill4 : RGBA(unit: 0, 0, 0, 0) }
    var tableHead: RGBA { ownLook?.tableHead ?? fill4 }
    /// The line round a reply's bubble in the iOS look: none unless a skin draws one.
    var replyEdge: RGBA { ownLook?.replyEdge ?? RGBA(unit: 0, 0, 0, 0) }
}

/// Light and dark tokens plus what is not colour.
nonisolated struct ThemeSet: Sendable, Hashable {
    var state: ThemeState
    var light: ThemeTokens
    var dark: ThemeTokens
    /// The skin has one look, drawn in both modes; `forcedDark` says which iOS appearance matches it.
    var forcedDark: Bool?
    /// [a11y] The Desktop Look's High Contrast mixes, for iOS Increase Contrast while the switch is off (nil otherwise:
    /// the switch already draws them, or the look is off).
    var systemContrastLight: ThemeTokens?
    var systemContrastDark: ThemeTokens?

    func tokens(dark wantsDark: Bool) -> ThemeTokens { wantsDark ? dark : light }

    /// The tokens to draw with: iOS Increase Contrast turns the Desktop Look's High Contrast on.
    func tokens(dark wantsDark: Bool, increaseContrast: Bool) -> ThemeTokens {
        guard increaseContrast, let strong = wantsDark ? systemContrastDark : systemContrastLight else { return tokens(dark: wantsDark) }
        return strong
    }

    /// The page behind grouped lists (More, Settings, forms, sheets) is iOS's own grouped grey: true for the app's
    /// standard look and the iOS System skin, which are exactly iOS there. Any other skin, and the Desktop Look,
    /// paint it themselves (`ThemeTokens.grouped`; the web's --ios-bg-grouped, phone-ios-tokens.css:18).
    /// The app's standard look: no skin picked and the Desktop Look off (the Nous values of `ThemeResolver.base`).
    var isStandardLook: Bool { !state.desktopLook && state.skinID == SkinCatalog.defaultID }

    var groupedPageIsSystem: Bool {
        !state.desktopLook && (state.skinID == SkinCatalog.defaultID || state.skinID == SkinCatalog.iosID)
    }
}

nonisolated enum ThemeResolver {
    static func resolve(_ state: ThemeState) -> ThemeSet {
        let skin = state.skin
        func tokens(_ wantsDark: Bool, contrast: Bool) -> ThemeTokens {
            let seeds = skin.seeds(dark: wantsDark)
            // A palette is painted in the mode its own background says (`renderedModeFor`): a dark-only skin stays
            // dark when Light is asked for.
            let dark = skin.id == SkinCatalog.defaultID && !state.desktopLook ? wantsDark : seeds.rendersDark
            var t = state.desktopLook ? desktop(seeds, dark: dark, contrast: contrast) : ios(skin, seeds, dark: dark)
            if let own = skin.syntax?.pick(dark) { t.syntax = syntax(own, on: t.codeFillOnBubble.over(t.botBubble.over(t.page.over(.white))), dark: dark) }
            return t
        }
        let forced: Bool? = skin.hasOneLook ? skin.light.rendersDark : nil
        var set = ThemeSet(state: state, light: tokens(false, contrast: state.highContrast), dark: tokens(true, contrast: state.highContrast),
                           forcedDark: forced)
        if ThemeContrast.followsSystem(state) {
            set.systemContrastLight = tokens(false, contrast: true)
            set.systemContrastDark = tokens(true, contrast: true)
        }
        return set
    }

    // MARK: The iOS look

    /// The Nous palette the app shipped with (spec 06 §1.2): the literals of HQPalette.swift and ChatPalette.swift.
    static func base(dark: Bool) -> ThemeTokens {
        func pick(_ light: RGBA, _ darkValue: RGBA) -> RGBA { dark ? darkValue : light }
        let ink = pick(RGBA(hex: 0x1F2328), RGBA(hex: 0xE6EDF3))
        let page = pick(RGBA(hex: 0xFEFEFE), RGBA(hex: 0x0D1015))
        let separator = pick(RGBA(60, 60, 67, 0.29), RGBA(84, 84, 88, 0.6))
        let groupedCard = pick(RGBA(hex: 0xF2F2F7), RGBA(hex: 0x1C1C1E))
        let tint = pick(RGBA(hex: 0x0053FD), RGBA(hex: 0x4A84FE))
        return ThemeTokens(
            page: page, label: ink.alpha(0.94), label2: ink.alpha(0.74), label3: ink.alpha(0.36),
            tint: tint, tintText: pick(RGBA(hex: 0x0040DD), RGBA(hex: 0x0A84FF)), onTint: .white,
            separator: separator,
            fill1: pick(RGBA(120, 120, 128, 0.2), RGBA(120, 120, 128, 0.36)),
            fill2: pick(RGBA(120, 120, 128, 0.16), RGBA(120, 120, 128, 0.32)),
            fill2OnPage: pick(RGBA(232.6, 232.6, 233.8), RGBA(47.2, 49.3, 55.2)),
            fill3: pick(RGBA(118, 118, 128, 0.12), RGBA(118, 118, 128, 0.24)),
            fill4: pick(RGBA(116, 116, 128, 0.08), RGBA(118, 118, 128, 0.18)),
            cellPressed: pick(RGBA(hex: 0xD1D1D6), RGBA(hex: 0x2C2C2E)),
            groupedCard: groupedCard, lifted: pick(RGBA(hex: 0xFFFFFF), RGBA(hex: 0x1C1C1E)),
            searchFill: RGBA(118, 118, 128, 0.12),
            orange: pick(RGBA(hex: 0xC93400), RGBA(hex: 0xFF9F0A)), red: pick(RGBA(hex: 0xD70015), RGBA(hex: 0xFF453A)),
            alertRed: pick(RGBA(hex: 0xFF3B30), RGBA(hex: 0xFF453A)),
            green: pick(RGBA(hex: 0x248A3D), RGBA(hex: 0x30D158)), muted: RGBA(hex: 0x8E8E93),
            botBubble: pick(RGBA(hex: 0xE9E9EB), RGBA(hex: 0x26282C)),
            meBubble: pick(RGBA(hex: 0x0053FD), RGBA(hex: 0x3863BF)), meText: .white,
            meTime: pick(RGBA.white.alpha(0.85), RGBA.white.alpha(0.88)),
            codeFill: pick(RGBA(116, 116, 128, 0.08), RGBA(hex: 0x1F2023)),
            codeFillOnBubble: pick(RGBA(223.6, 223.6, 226.4), RGBA(hex: 0x1F2023)),
            codeText: pick(RGBA(hex: 0x1F2328), RGBA(hex: 0xA1ABB5)),
            grouped: pick(RGBA(hex: 0xF6F8FA), RGBA(hex: 0x010409)),
            statusWorking: pick(RGBA(hex: 0x0040DD), RGBA(hex: 0xE6EDF3, alpha: 0.94)),
            editor: groupedCard, elevated: groupedCard, sidebar: pick(RGBA(hex: 0xF6F8FA), RGBA(hex: 0x010409)),
            strokePrimary: separator, strokeSecondary: separator, strokeTertiary: separator,
            meBorder: RGBA(unit: 0, 0, 0, 0), composerBorder: separator, composerGlyph: ink.alpha(0.74), caret: tint,
            tabIdle: ink.alpha(0.36))
    }

    /// The desktop's chat surface (`--ui-bg-chrome`): the skin's background pulled toward a neutral
    /// (styles.css:297-301, context.tsx:210-216).
    static func chrome(_ seeds: SkinSeeds, dark: Bool) -> RGBA {
        seeds.background.mix(dark ? 74 : 92, dark ? RGBA(hex: 0x0D0D0E) : RGBA(hex: 0xF3F3F3))
    }

    /// A skin in the iOS look: it gives the page, the text and the accent; cells, fills, separators and the bot
    /// bubble stay the phone's own palette (phone-ui-desktop.css:3-4).
    static func ios(_ skin: Skin, _ seeds: SkinSeeds, dark: Bool) -> ThemeTokens {
        var t = base(dark: dark)
        guard skin.id != SkinCatalog.defaultID else { return t }
        let ink = seeds.foreground
        if skin.id == SkinCatalog.iosID {
            // The iOS System skin: exact iOS values (phone-ios-tokens.css:137-153).
            t.page = dark ? .black : .white
            t.label = dark ? .white : .black
            t.label2 = dark ? RGBA(235, 235, 245, 0.6) : RGBA(60, 60, 67, 0.6)
            t.label3 = dark ? RGBA(235, 235, 245, 0.3) : RGBA(60, 60, 67, 0.3)
            t.tint = dark ? RGBA(hex: 0x0A84FF) : RGBA(hex: 0x007AFF)
            t.tintText = dark ? RGBA(hex: 0x0A84FF) : RGBA(hex: 0x0040DD)
            t.cellPressed = dark ? RGBA(hex: 0x3A3A3C) : RGBA(hex: 0xD1D1D6)
            t.grouped = dark ? .black : RGBA(hex: 0xF2F2F7)
            t.codeFill = dark ? RGBA(hex: 0x1C1C1E) : RGBA(hex: 0xF2F2F7)
        } else {
            let own = skin.ownLook?.pick(dark)
            t.page = own?.page ?? chrome(seeds, dark: dark)
            t.label = ink.alpha(0.94)
            t.label2 = ThemeMath.readable(own?.subtle ?? ink.alpha(0.74), text: ink.alpha(0.94), on: t.page)
            t.label3 = own?.muted ?? ink.alpha(0.36)
            // In dark an accent is brightened to CIELAB L 57, as iOS brightens its tints (phone-ios-tokens.css:109).
            t.tint = dark ? seeds.brand.raisingL(to: 57) : seeds.brand
            t.tintText = ThemeMath.readable(t.tint, text: t.label, on: t.page)
            t.grouped = seeds.sidebarBackground ?? seeds.background
            t.codeText = dark ? ink.mix(72, t.page) : ink
            // Cards and panels are the page raised a step in its own hue: iOS's neutral #1C1C1E read as a grey patch
            // on a coloured page (owner 2026-11-01, the question box on a navy skin: "the grey in there looks off").
            let card = t.page.mix(dark ? 91 : 95, ink)
            t.groupedCard = card
            t.lifted = dark ? card : t.page.mix(40, .white)
            t.editor = card; t.elevated = card
            t.cellPressed = t.page.mix(dark ? 83 : 88, ink)
            // The bot's bubble too (owner 2026-11-01: "the grey doesn't seem like it fits"), and the code card in it.
            t.botBubble = t.page.mix(dark ? 87 : 91, ink)
            if dark {
                t.codeFill = t.page.mix(95, ink)
                t.codeFillOnBubble = t.codeFill
            } else {
                t.codeFillOnBubble = t.codeFill.over(t.botBubble)
            }
            if let own {
                paint(&t, own, ink: ink)
                t.ownLook = own
            }
        }
        t.onTint = t.tint.labL >= 60 ? .black : .white
        if let own = skin.ownLook?.pick(dark) {
            // Your message is the theme's own soft box with the theme's text, not white on the accent.
            t.meBubble = own.meBubble
            t.meText = t.label
            t.meTime = ThemeMath.readable(own.subtle, text: t.label, on: own.meBubble.over(t.page), ratio: 3)
        } else {
            t.meBubble = dark ? t.tint.mix(75, .black) : t.tint
            // White, as iOS writes on its own blue; black only where a skin's accent is too light for white to read.
            // An accent white nearly reads on (3:1 or better) is deepened just enough for white to reach 4.5:1, instead
            // of turning the text black (owner 2026-10-17: a mid blue bubble had dark text; it should be white).
            if skin.id != SkinCatalog.iosID, RGBA.white.contrast(with: t.meBubble.over(t.page)) >= 3 {
                let accent = t.meBubble
                var keep = 100.0
                while keep > 60, RGBA.white.contrast(with: t.meBubble.over(t.page)) < 4.5 {
                    keep -= 2
                    t.meBubble = accent.mix(keep, .black)
                }
            }
            let meGround = t.meBubble.over(t.page)
            let whiteReads = RGBA.white.contrast(with: meGround) >= 4.5 || skin.id == SkinCatalog.iosID
            let meInk: RGBA = whiteReads || RGBA.white.contrast(with: meGround) >= RGBA.black.contrast(with: meGround) ? .white : .black
            t.meText = meInk
            t.meTime = meInk.alpha(dark ? 0.88 : 0.85)
        }
        t.statusWorking = dark ? t.label : t.tintText
        t.fill2OnPage = t.fill2.over(t.page)
        t.sidebar = t.grouped
        t.tabIdle = t.label3
        return t
    }

    /// A skin's own iOS look (`SkinOwnLook`) over what the general rule made: its surfaces, its greys, its code card.
    private static func paint(_ t: inout ThemeTokens, _ own: SkinOwnLook, ink: RGBA) {
        t.groupedCard = own.card; t.lifted = own.card; t.editor = own.card; t.elevated = own.card
        t.botBubble = own.card
        t.cellPressed = own.pressed
        t.codeFill = own.codeFill; t.codeFillOnBubble = own.codeFill
        t.codeText = ink
        let fills = own.fillAlphas.map { own.grey.alpha($0) }
        t.fill1 = fills[0]; t.fill2 = fills[1]; t.fill3 = fills[2]; t.fill4 = fills[3]
        t.searchFill = own.grey.alpha(0.12)
        t.separator = own.separator
        t.muted = own.muted
    }

    /// A skin's code colours, each taken toward black (light) or white (dark) until it reads at 4.5:1 on the code card:
    /// Rosé Pine Dawn's gold is 1.9:1 there as published.
    static func syntax(_ colours: SyntaxColours, on ground: RGBA, dark: Bool) -> SyntaxColours {
        colours.map { ThemeMath.readable($0, text: dark ? .white : .black, on: ground) }
    }

    // MARK: The Desktop Look

    /// The desktop's own mixes (styles.css:297-399) mapped to the app's tokens (phone-ui-desktop.css:16-58), then
    /// High Contrast on top (phone-ui-contrast.css:10-49).
    static func desktop(_ seeds: SkinSeeds, dark: Bool, contrast: Bool) -> ThemeTokens {
        var t = base(dark: dark)
        let ink = seeds.foreground, accent = seeds.brand
        let neutralCard = dark ? RGBA(hex: 0x161618) : RGBA(hex: 0xFCFCFC)
        let page = chrome(seeds, dark: dark)
        var editor = seeds.card.mix(dark ? 38 : 22, neutralCard)
        let elevated = seeds.popover.mix(dark ? 46 : 28, neutralCard)
        let sidebar = seeds.sidebarBackground ?? seeds.background
        let textPrimary = ink.alpha(0.94), textSecondary = ink.alpha(0.74), textTertiary = ink.alpha(0.54)
        let textQuaternary = ink.alpha(0.36)
        func tinted(_ accentShare: Double, _ inkShare: Double) -> RGBA { accent.mix(accentShare, ink.faded(inkShare)) }
        var strokePrimary = tinted(24, 10), strokeSecondary = tinted(16, 7), strokeTertiary = tinted(10, 5)
        let bgTertiary = tinted(8, 5), bgQuaternary = tinted(5, 4)
        var bgCard = tinted(4, 4)
        var rowActive = tinted(8, 5)
        var meBubble = (seeds.userBubble ?? seeds.popover).mix(dark ? 46 : 0, neutralCard)
        var meBorder = seeds.userBubbleBorder ?? seeds.border
        // Legible colours (desktop-look.ts:64-128): the accent as text and the secondary text, each mixed toward the
        // text colour until it reads at 4.5:1 on the page.
        let accentText = ThemeMath.legible(source: accent, text: textPrimary, page: page)
        var label2 = ThemeMath.legible(source: textSecondary, text: textPrimary, page: page)
        var label3 = textTertiary
        var separator = strokeSecondary
        var fill1 = bgQuaternary
        var composerBorder = strokePrimary
        var tabIdle = textTertiary
        if contrast {
            strokePrimary = textPrimary.faded(18); strokeSecondary = textPrimary.faded(13); strokeTertiary = textPrimary.faded(10)
            separator = strokeTertiary
            label2 = label2.mixOklab(65, textPrimary)
            label3 = textTertiary.mixOklab(70, textPrimary)
            let solidInk = textPrimary.over(page)
            editor = solidInk.mixOklab(dark ? 10 : 5, page)
            bgCard = editor
            fill1 = solidInk.mixOklab(12, page)
            rowActive = accent.mixOklab(dark ? 22 : 14, page)
            meBubble = accent.mixOklab(dark ? 28 : 13, page)
            meBorder = accent.mixOklab(dark ? 75 : 65, page)
            composerBorder = textPrimary.faded(50)
            tabIdle = label2
        }
        t.page = page
        t.label = textPrimary; t.label2 = label2; t.label3 = label3
        t.tint = accentText; t.tintText = accentText
        t.onTint = accentText.over(page).labL >= 60 ? .black : .white
        t.separator = separator
        t.fill1 = fill1; t.fill2 = bgTertiary; t.fill3 = bgTertiary; t.fill4 = bgCard
        t.fill2OnPage = bgTertiary.over(page)
        t.cellPressed = rowActive.over(page)
        t.groupedCard = editor; t.lifted = editor
        t.searchFill = bgTertiary
        t.muted = textQuaternary.over(page)
        t.botBubble = editor
        // Your message is text on a box. Where a skin's box is too close to its text, the text goes toward plain
        // black or white until it reads (the web leaves it; Solarized dark is 4.4:1 there).
        let meGround = meBubble.over(page.over(.white))
        let strongest: RGBA = RGBA.white.contrast(with: meGround) >= RGBA.black.contrast(with: meGround) ? .white : .black
        var meInk = textPrimary
        for keep in stride(from: 100.0, through: 0, by: -10) {
            meInk = textPrimary.mixOklab(keep, strongest)
            if meInk.over(meGround).contrast(with: meGround) >= 4.5 { break }
        }
        t.meBubble = meBubble; t.meText = meInk; t.meTime = textTertiary
        t.codeFill = editor; t.codeFillOnBubble = editor
        t.codeText = ink.alpha(0.86).over(editor)
        t.grouped = page
        t.statusWorking = dark ? textPrimary : accentText
        t.editor = editor; t.elevated = elevated; t.sidebar = sidebar
        t.strokePrimary = strokePrimary; t.strokeSecondary = strokeSecondary; t.strokeTertiary = strokeTertiary
        t.meBorder = meBorder; t.composerBorder = composerBorder; t.tabIdle = tabIdle
        t.composerGlyph = label3; t.caret = textPrimary
        // Status colours keep iOS's own (a Failed job, an error), in the shade that reads on this page.
        t.red = ThemeMath.readable(t.red, text: textPrimary, on: page, ratio: 4.5)
        t.orange = ThemeMath.readable(t.orange, text: textPrimary, on: page, ratio: 4.5)
        t.green = ThemeMath.readable(t.green, text: textPrimary, on: page, ratio: 4.5)
        return t
    }
}
