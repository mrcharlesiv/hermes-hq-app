// desktoplook: what the person chose (spec 3x-desktoplook §4.4, §5.6, §6, §7). Kept on this device only
// (`UserDefaults`), never sent anywhere.

import Foundation

nonisolated struct ThemeState: Sendable, Hashable {
    /// The stored skin id resolved against the catalog.
    var skinID: String = SkinCatalog.defaultID
    var desktopLook = false
    /// The stored choice; it only draws while the Desktop Look is on.
    var highContrast = false
    /// The stored choice (percent), in both looks ([density] on the iPhone and iPad too since 2026-11-09; the Mac's
    /// iOS look had it already).
    var uiScalePercent = 100
    /// The stored choice (points); it only applies with the Desktop Look off (the look has `desktopCorners`).
    var bubbleCorners = ThemeState.defaultBubbleCorners
    /// [desktop-corners] The Desktop Look's own corner for your messages and its text box (owner 2026-11-08: "I want to
    /// be able to still control the radius of the chat bubbles"). The desktop's 4 pt unless another was picked, so the
    /// look's boxes stay as they were for whoever never moves the slider.
    var desktopCorners = ThemeState.defaultDesktopCorners
    /// [desktop-composer] The Desktop Look's text box: the iOS look's Liquid Glass bar (the default, owner 2026-11-08:
    /// "the text input could default to the liquid glass one"), its corners following `desktopCorners`, or the
    /// desktop's one flat box.
    var desktopComposer = DesktopComposer.glass
    /// [glass-bubbles] [tinted-bubbles] The stored choice: Liquid Glass tinted with the skin's own bubble colour (owner
    /// 2026-11-01: "the tinted glass kind of wins everywhere"), the solid fill, or the bubble's colour over a soft copy
    /// of the Chat Background (owner 2026-11-01, Telegram's bubbles). Only with the Desktop Look off; Solid unless
    /// another was picked (owner 2026-11-02: "Make the solid chat bubble type the default").
    var bubbleStyle = BubbleStyle.solid
    /// [top-edge] How rows meet the top bar where they scroll under it (Theme › Look › Top Edge): the soft fade, or a
    /// frosted band with a straight bottom (owner 2026-11-03, Claude's app: "straight across in a rectangle"). Hard
    /// unless Soft was picked (owner 2026-11-04, after build 732: "I like the hard top edge", then Hard as the default).
    var topEdge = TopEdge.hard
    /// [density] Theme › Density: Standard, or Compact's smaller faces and shorter rows on the Bots and Sessions pages
    /// (a tester 2026-11-08: "everything a lot more compact", who used the Desktop Look at 90 % for it; owner: the same
    /// choice in the iOS look). Only with the Desktop Look off: the look keeps its own rows.
    var density = ListDensity.standard
    /// [message-colour] Chat Bubbles › Colour: the colour of your own messages. The theme's own unless another was
    /// picked (owner 2026-11-11: "keep the blue but make an option for Mac and iOS where you can change the color").
    /// Only with the Desktop Look off: the look keeps its own boxes.
    var messageColour = MessageColour.theme

    static let `default` = ThemeState()
    static let scalePresets = [90, 100, 110, 125, 150]
    /// The chat bubbles' corner in the iOS look (spec 06 §2.2), and how far the slider on the Theme page goes.
    static let defaultBubbleCorners = 12
    static let bubbleCornerRange = 0...24
    /// [desktop-corners] The desktop's own box corner (phone-ui-desktop.css:59-66), on the same slider.
    static let defaultDesktopCorners = 4

    var skin: Skin { SkinCatalog.resolved(skinID) }
    var contrastApplies: Bool { desktopLook && highContrast }
    /// [density] Compact draws only in the iOS look.
    var compact: Bool { !desktopLook && density == .compact }

    /// [mac] What 100 % is on the Mac, per look: Grok Bot's Mac app's sizes (owner 2026-10-27: "mimic that closely
    /// while sticking to our brand"). The Mac draws the iPad layout at 77 %, so the Desktop Look's 15 pt body came out
    /// at 11.5 pt on the screen and the iOS look's 17 at 13. × 1.3 and × 1.15 put both on Grok's 15 pt chat text;
    /// faces, rows and icons grow with it.
    static func macBase(desktopLook: Bool) -> Double {
        #if targetEnvironment(macCatalyst)
        desktopLook ? 1.3 : 1.15
        #else
        1
        #endif
    }

    /// UI Scale × the look's own 100 % on the Mac. [density] Both looks, everywhere: the web's `appliedUIScale`
    /// (ui-scale.ts:21) kept the iOS look at 100 %, and so did the iPhone until 2026-11-09 (the Mac stopped in October,
    /// as its text size).
    var scale: Double { Double(uiScalePercent) / 100 * Self.macBase(desktopLook: desktopLook) }
    /// The corner bubbles are drawn with: the look in use's own (`bubbleCorners`, `desktopCorners`).
    var appliedBubbleCorners: Int { desktopLook ? desktopCorners : bubbleCorners }
    /// [desktop-composer] The desktop's one flat box draws the text box (and Talk's bar in its place); otherwise the
    /// iOS look's glass bar does, in both looks. [mac] The Mac's Desktop Look always has the box (its own message box
    /// in either look, owner 2026-11-08), so Text Box isn't offered there.
    var boxComposer: Bool { desktopLook && (desktopComposer == .box || Self.textBoxIsFixed) }
    /// [mac] No Text Box choice: the Mac keeps its own message box.
    static var textBoxIsFixed: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }
    /// [glass-bubbles] The Glass style (the switch the Theme page had before Tinted joined it).
    var glassBubbles: Bool {
        get { bubbleStyle == .glass }
        set { bubbleStyle = newValue ? .glass : .solid }
    }
    /// [glass-bubbles] The Desktop Look keeps its own boxes. Colours only: a glass or tinted bubble has the solid one's
    /// frame.
    var appliedBubbleStyle: BubbleStyle { desktopLook ? .solid : bubbleStyle }
    var appliedGlassBubbles: Bool { appliedBubbleStyle == .glass }
    var appliedTintedBubbles: Bool { appliedBubbleStyle == .tinted }
    /// [message-colour] The Desktop Look keeps its skin's own box for your messages.
    var appliedMessageColour: MessageColour { desktopLook ? .theme : messageColour }
    /// Everything a layout depends on (the mode is colours only; High Contrast boxes the look's replies, which then
    /// keep a bubble's padding).
    var layoutSignature: Int {
        var hasher = Hasher()
        hasher.combine(desktopLook)
        hasher.combine(contrastApplies)
        hasher.combine(uiScalePercent)
        hasher.combine(compact)
        hasher.combine(desktopLook ? skin.sansFamily : nil)
        // Photo albums and voice memos inside a bubble keep its corner in their layouts.
        hasher.combine(appliedBubbleCorners)
        return hasher.finalize()
    }
}

/// [density] How much a list fits on a screen in the iOS look (Theme › Density).
nonisolated enum ListDensity: String, Sendable, Hashable, CaseIterable {
    /// The iOS look's own rows: 50 pt faces, two-line bot rows.
    case standard
    /// Smaller faces and type, shorter rows, one line of preview.
    case compact
}

/// [message-colour] The colour of your own messages in the iOS look (Chat Bubbles › Colour): the theme's, one of nine
/// named ones, or any colour picked from the system's colour panel. Stored as nothing, the name, or `#RRGGBB`.
nonisolated enum MessageColour: Sendable, Hashable {
    case theme
    /// [bot-colour] Each bot's chat in the colour of its face (owner 2026-11-11). The theme's own where there is no
    /// one bot (a group chat, the page's preview): the chat itself asks for the face's colour (`BotMessageColour`).
    case botFace
    case preset(Preset)
    case custom(UInt32)

    enum Preset: String, Sendable, Hashable, CaseIterable {
        case blue, indigo, purple, pink, red, orange, green, teal, graphite

        /// The bubble in light and in dark: each already deep enough for white text. Graphite has none: it is the
        /// page's own grey (`ThemeResolver.paintMessage`).
        func seed(dark: Bool) -> RGBA? {
            func pick(_ light: UInt32, _ darkValue: UInt32) -> RGBA { RGBA(hex: dark ? darkValue : light) }
            return switch self {
            case .blue: pick(0x0053FD, 0x3863BF)      // the app's own blue (`ThemeResolver.base`)
            case .indigo: pick(0x5856D6, 0x625BBF)
            case .purple: pick(0x9A45D6, 0x8A49B8)
            case .pink: pick(0xCE3F71, 0xAF3A62)
            case .red: pick(0xD9342B, 0xB5392D)
            case .orange: pick(0xBF5509, 0xA54B0A)
            case .green: pick(0x1D883C, 0x257538)
            case .teal: pick(0x0D8282, 0x1E7272)
            case .graphite: nil
            }
        }
    }

    /// A stored value that is not a known name or a six-digit `#RRGGBB` is the theme's own.
    init(stored: Any?) {
        guard let text = stored as? String else { self = .theme; return }
        if text == "botFace" {
            self = .botFace
        } else if let preset = Preset(rawValue: text) {
            self = .preset(preset)
        } else if text.hasPrefix("#"), text.count == 7, let hex = UInt32(text.dropFirst(), radix: 16) {
            self = .custom(hex)
        } else {
            self = .theme
        }
    }

    /// What is stored: nothing for the theme's own.
    var stored: String? {
        switch self {
        case .theme: nil
        case .botFace: "botFace"
        case .preset(let preset): preset.rawValue
        case .custom(let hex): String(format: "#%06X", hex & 0xFFFFFF)
        }
    }
}

/// [glass-bubbles] [tinted-bubbles] How chat bubbles are filled in the iOS look (Theme › Chats › Chat Bubbles › Style).
nonisolated enum BubbleStyle: String, Sendable, Hashable, CaseIterable {
    /// The skin's bubble colour.
    case solid
    /// Liquid Glass tinted with it (`GlassBubbles`; not on the Mac).
    case glass
    /// It over a soft copy of the Chat Background lined up with the screen (`TintedBubbles`).
    case tinted
}

/// [desktop-composer] How the Desktop Look draws the text box at the foot of a chat (Theme › Text Box).
nonisolated enum DesktopComposer: String, Sendable, Hashable, CaseIterable {
    /// The iOS look's Liquid Glass bar, its corners following the look's Corners.
    case glass
    /// The desktop's one bordered box on the editor surface.
    case box
}

/// [top-edge] The system's scroll edge effect at the top of tabs and chats (`UIScrollEdgeEffect.Style`).
nonisolated enum TopEdge: String, Sendable, Hashable, CaseIterable {
    /// The blur fades out going down, so the bar has no visible bottom.
    case soft
    /// A frosted band the height of the bar, cut off on a straight line.
    case hard
}

/// Reads and writes the fourteen `hqn.theme.*` keys.
nonisolated struct ThemeStore: @unchecked Sendable {
    enum Key {
        static let skin = "hqn.theme.skin"
        static let chosen = "hqn.theme.chosen"
        static let desktopLook = "hqn.theme.desktopLook"
        static let skinBeforeLook = "hqn.theme.skinBeforeLook"
        static let highContrast = "hqn.theme.highContrast"
        static let uiScale = "hqn.theme.uiScale"
        static let bubbleCorners = "hqn.theme.bubbleCorners"
        /// [glass-bubbles] Stored only when off (`false`): kept beside `bubbleStyle`, so a build from before Tinted
        /// draws solid bubbles rather than glass for Solid and Tinted. No longer read.
        static let glassBubbles = "hqn.theme.glassBubbles"
        /// [tinted-bubbles] `BubbleStyle`'s raw value, stored only when it isn't Solid.
        static let bubbleStyle = "hqn.theme.bubbleStyle"
        /// [top-edge] `TopEdge`'s raw value, stored only when it isn't Hard (the default since build 734; 732 and 733
        /// stored Hard and nothing for Soft).
        static let topEdge = "hqn.theme.topEdge"
        /// [desktop-corners] Stored only when it isn't the desktop's 4 pt.
        static let desktopCorners = "hqn.theme.desktopCorners"
        /// [desktop-composer] `DesktopComposer`'s raw value, stored only when it isn't Glass.
        static let desktopComposer = "hqn.theme.desktopComposer"
        /// [density] `ListDensity`'s raw value, stored only when it isn't Standard.
        static let density = "hqn.theme.density"
        /// [message-colour] `MessageColour.stored`, stored only when it isn't the theme's own.
        static let messageColour = "hqn.theme.messageColour"
        static let all = [skin, chosen, desktopLook, skinBeforeLook, highContrast, uiScale, bubbleCorners, glassBubbles, bubbleStyle, topEdge,
                          desktopCorners, desktopComposer, density, messageColour]
    }

    var defaults: UserDefaults = .standard
    /// False where the Desktop Look is not offered (`ThemeFeature`): a stored switch then reads as off and cannot be set.
    var lookAllowed = true

    /// A stored value that is not a real Bool (a string, a number other than 0/1 written by hand) reads as off.
    private func flag(_ key: String) -> Bool {
        guard let value = defaults.object(forKey: key) else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    /// `DispatchUIScale.clamped`: outside 0.8…1.6 or not a number is 100 %. Inside the range a non-preset is kept.
    static func clampedScale(_ value: Any?) -> Int {
        guard let number = value as? NSNumber, !(value is String) else { return 100 }
        let percent = number.doubleValue
        guard percent.isFinite, percent >= 80, percent <= 160 else { return 100 }
        return Int(percent.rounded())
    }

    /// Outside `bubbleCornerRange` or not a number is the standard (12 pt, or the Desktop Look's 4).
    static func clampedBubbleCorners(_ value: Any?, standard: Int = ThemeState.defaultBubbleCorners) -> Int {
        guard let number = value as? NSNumber, !(value is String) else { return standard }
        let points = number.doubleValue.rounded()
        let range = ThemeState.bubbleCornerRange
        guard points.isFinite, points >= Double(range.lowerBound), points <= Double(range.upperBound) else { return standard }
        return Int(points)
    }

    func load() -> ThemeState {
        var state = ThemeState()
        // A skin stored as anything but a known id (a number, a retired name) draws as the default, not overwritten.
        state.skinID = SkinCatalog.resolved(defaults.object(forKey: Key.skin) as? String).id
        state.desktopLook = lookAllowed && flag(Key.desktopLook)
        state.highContrast = flag(Key.highContrast)
        let stored = defaults.object(forKey: Key.uiScale)
        state.uiScalePercent = stored == nil ? Self.defaultScale : ThemeStore.clampedScale(stored)
        state.bubbleCorners = ThemeStore.clampedBubbleCorners(defaults.object(forKey: Key.bubbleCorners))
        state.desktopCorners = ThemeStore.clampedBubbleCorners(defaults.object(forKey: Key.desktopCorners), standard: ThemeState.defaultDesktopCorners)
        if let composer = (defaults.object(forKey: Key.desktopComposer) as? String).flatMap(DesktopComposer.init(rawValue:)) {
            state.desktopComposer = composer
        }
        // [tinted-bubbles] A style stored as anything but a known name is Solid. Glass used to be stored as nothing,
        // so whoever had it without picking it again now has Solid, the new default (owner 2026-11-02).
        if let style = (defaults.object(forKey: Key.bubbleStyle) as? String).flatMap(BubbleStyle.init(rawValue:)) {
            state.bubbleStyle = style
        }
        if let edge = (defaults.object(forKey: Key.topEdge) as? String).flatMap(TopEdge.init(rawValue:)) { state.topEdge = edge }
        if let density = (defaults.object(forKey: Key.density) as? String).flatMap(ListDensity.init(rawValue:)) { state.density = density }
        state.messageColour = MessageColour(stored: defaults.object(forKey: Key.messageColour))
        return state
    }

    /// Port of `migrateUnchosenSkin` (ios-theme.ts:46-62): someone who never picked a skin and sits on the old default
    /// follows a new default; an explicit pick is left alone. With `defaultID == oldDefaultID` nothing visible changes.
    func migrate(defaultID: String = SkinCatalog.defaultID, oldDefaultID: String = SkinCatalog.oldDefaultID) {
        guard defaults.object(forKey: Key.chosen) == nil else { return }
        let stored = defaults.object(forKey: Key.skin) as? String
        if stored == nil || stored == oldDefaultID {
            if defaultID != oldDefaultID { defaults.removeObject(forKey: Key.skin) }
            defaults.set("migrated", forKey: Key.chosen)
        }
    }

    /// The person picked a skin (`markSkinChosen`).
    func pick(skin id: String) {
        defaults.set(id, forKey: Key.skin)
        defaults.set("picked", forKey: Key.chosen)
    }

    /// The Nous hand-off (desktop-look-row.tsx:10-25): iOS System has no desktop counterpart, so turning the look on
    /// moves it to Nous, and back when the look goes off if nothing else was picked meanwhile.
    func setDesktopLook(_ on: Bool) {
        guard lookAllowed || !on else { return }
        let skin = SkinCatalog.resolved(defaults.object(forKey: Key.skin) as? String).id
        if on {
            if skin == SkinCatalog.iosID {
                defaults.set(SkinCatalog.iosID, forKey: Key.skinBeforeLook)
                defaults.set(SkinCatalog.desktopDefaultID, forKey: Key.skin)
            }
            defaults.set(true, forKey: Key.desktopLook)
        } else {
            if defaults.string(forKey: Key.skinBeforeLook) == SkinCatalog.iosID, skin == SkinCatalog.desktopDefaultID {
                defaults.set(SkinCatalog.iosID, forKey: Key.skin)
            }
            defaults.removeObject(forKey: Key.skinBeforeLook)
            defaults.removeObject(forKey: Key.desktopLook)
        }
    }

    func setHighContrast(_ on: Bool) {
        if on { defaults.set(true, forKey: Key.highContrast) } else { defaults.removeObject(forKey: Key.highContrast) }
    }

    /// [mac] 100 % on the Mac too: `ThemeState.macBase` makes it Grok Bot's sizes (2026-10-27). Before, the Mac started
    /// at 110 % (body 14.5 pt on the screen) after the owner found 100 % "too small" (2026-10-25).
    static var defaultScale: Int { 100 }

    /// Stored only when it is not the default (ui-scale.ts:31-33).
    func setUIScale(_ percent: Int) {
        if percent == Self.defaultScale { defaults.removeObject(forKey: Key.uiScale) } else { defaults.set(percent, forKey: Key.uiScale) }
    }

    /// Stored only when it is not the standard 12 pt. [desktop-corners] `desktop`: the Desktop Look's own corner,
    /// stored only when it is not its 4 pt.
    func setBubbleCorners(_ points: Int, desktop: Bool = false) {
        let points = min(max(points, ThemeState.bubbleCornerRange.lowerBound), ThemeState.bubbleCornerRange.upperBound)
        let key = desktop ? Key.desktopCorners : Key.bubbleCorners
        let standard = desktop ? ThemeState.defaultDesktopCorners : ThemeState.defaultBubbleCorners
        if points == standard { defaults.removeObject(forKey: key) } else { defaults.set(points, forKey: key) }
    }

    /// [desktop-composer] Glass, the default, is stored as nothing.
    func setDesktopComposer(_ composer: DesktopComposer) {
        if composer == .glass { defaults.removeObject(forKey: Key.desktopComposer) } else { defaults.set(composer.rawValue, forKey: Key.desktopComposer) }
    }

    /// [glass-bubbles] Stored only when off.
    func setGlassBubbles(_ on: Bool) { setBubbleStyle(on ? .glass : .solid) }

    /// [tinted-bubbles] Solid is stored as nothing, the others as their name. The Glass switch stays off except for
    /// Glass, so a build from before this default (which read nothing as Glass) draws what was picked.
    func setBubbleStyle(_ style: BubbleStyle) {
        if style == .solid { defaults.removeObject(forKey: Key.bubbleStyle) } else { defaults.set(style.rawValue, forKey: Key.bubbleStyle) }
        if style == .glass { defaults.removeObject(forKey: Key.glassBubbles) } else { defaults.set(false, forKey: Key.glassBubbles) }
    }

    /// [top-edge] Hard, the default, is stored as nothing.
    func setTopEdge(_ edge: TopEdge) {
        if edge == .hard { defaults.removeObject(forKey: Key.topEdge) } else { defaults.set(edge.rawValue, forKey: Key.topEdge) }
    }

    /// [density] Standard, the default, is stored as nothing.
    func setDensity(_ density: ListDensity) {
        if density == .standard { defaults.removeObject(forKey: Key.density) } else { defaults.set(density.rawValue, forKey: Key.density) }
    }

    /// [message-colour] The theme's own, the default, is stored as nothing.
    func setMessageColour(_ colour: MessageColour) {
        if let stored = colour.stored { defaults.set(stored, forKey: Key.messageColour) } else { defaults.removeObject(forKey: Key.messageColour) }
    }

    func reset() { Key.all.forEach(defaults.removeObject(forKey:)) }
}

/// What of the theme layer people can reach. DECISION: on 2026-10-13 the owner asked to see the Desktop Look (with
/// High Contrast and UI Scale) in TestFlight now, as an early version, while its layout pass is built.
nonisolated enum ThemeFeature {
    static var desktopLook: Bool { true }
}

