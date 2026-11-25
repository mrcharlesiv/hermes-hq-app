// desktoplook: the live theme (spec 3x-desktoplook §3.3). One object on the main actor: it holds what the person
// chose, hands every window the theme's generation number (colours follow by themselves), and tells the screens that
// lay out by hand to rebuild (`Theme.didChange`).

import SwiftUI
import UIKit

@MainActor @Observable
final class Theme {
    static let shared = Theme()
    /// Posted on main after a change has been applied to every window.
    static let didChange = Notification.Name("hqn.theme.didChange")

    private(set) var state: ThemeState
    private(set) var generation: Int
    /// Bumped when iOS's text size changes: SwiftUI text in the look is drawn at fixed sizes worked out from it.
    private(set) var textSizeTick = 0
    @ObservationIgnored private let store: ThemeStore
    @ObservationIgnored private var textSizeWatch: NSObjectProtocol?
    @ObservationIgnored private var watchedWindows = Set<ObjectIdentifier>()

    init(store: ThemeStore = ThemeStore(lookAllowed: ThemeFeature.desktopLook)) {
        self.store = store
        store.migrate()
        let loaded = store.load()
        state = loaded
        generation = ThemeTable.install(ThemeResolver.resolve(loaded))
        if loaded.desktopLook { ThemeChrome.prepareSolidChrome() }
        if Self.solidChrome { ThemeChrome.preparePanelHook() }   // [paper-solid]
        textSizeWatch = NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // [density] The iOS look at a UI Scale makes its fonts at a fixed size too (`HQFont.preferred`).
                guard let self, self.state.desktopLook || self.state.scale != 1 else { return }
                self.textSizeTick &+= 1
            }
        }
    }

    /// Whether this state is the app as it was before themes: no skin picked, the look off. Nothing is overridden then.
    static func isStandard(_ state: ThemeState) -> Bool { state.skinID == SkinCatalog.defaultID && !state.desktopLook }

    /// [perf] A plain Bool beside the table's set: read per item by the list layouts and cell handlers.
    static var isDesktop: Bool { ThemeTable.desktopLook }
    /// [desktop-composer] The text box (and Talk's bar in its place) is the desktop's flat box: the Desktop Look with
    /// Text Box › Desktop picked. Otherwise it is the iOS look's glass bar, in either look.
    static var boxComposer: Bool { ThemeTable.current.state.boxComposer }

    /// [paper-icons] How a skin with ink icons (Paper) draws Settings' and More's row icons in the iOS look: the glyph
    /// alone in the theme's text (`plain`, the owner's pick of 2026-11-16 over ink on a soft tile, "most like Claude"),
    /// or on a tile of the theme's own (`tiles`). nil: iOS's coloured tiles (every other skin, and the Desktop Look,
    /// which draws its own glyphs). A DEBUG build draws the other with `-HQDebugInkIcons tiles`, to compare.
    enum InkIcons { case tiles, plain }

    /// [paper-ink] A switch that is on, in a monochrome ink skin (Paper): the ink in light; in dark a warm mid grey,
    /// since iOS's white thumb vanished on the ivory ink (2026-11-16 audit, Connectors). nil: every other skin keeps its own.
    static var inkSwitch: UIColor? {
        guard !isDesktop, ThemeTable.current.light.ownLook?.plainIcons == true else { return nil }
        return UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x9C / 255, green: 0x9B / 255, blue: 0x93 / 255, alpha: 1)
                : HQPalette.tintText.resolvedColor(with: traits)
        }
    }

    /// [paper-ink] A swipe action's or status colour that is only a hue (iOS's indigo, blue): in Paper the theme's
    /// graphite instead, a warm grey white reads on in both modes (7:1). Red and orange keep their meaning.
    static func inkSwipe(_ colour: UIColor) -> UIColor {
        !isDesktop && ThemeTable.current.light.ownLook?.plainIcons == true
            ? UIColor(red: 0x5A / 255, green: 0x59 / 255, blue: 0x55 / 255, alpha: 1)
            : colour
    }

    /// [paper-pills] How a flat-pill skin (`SkinOwnLook.flatPills`, Paper) draws the pills on pages in the iOS look.
    /// `outlined`: every pill on the card with a hairline, the picked one the solid ink. `solid`: no outlines, the picked
    /// one the solid ink. `soft`: no outlines, the picked one a soft grey pill with the ink's words (as Claude's filters).
    /// `glass`: iOS's Liquid Glass, as every other skin. nil: not a flat-pill skin, or the Desktop Look. A DEBUG build
    /// draws another with `-HQDebugPaperPills outlined|solid|soft|glass` (owner 2026-11-16: "Show me all options").
    enum PaperPills: String { case outlined, solid, soft, glass }
    static var paperPills: PaperPills? {
        guard !isDesktop, ThemeTable.current.light.ownLook?.flatPills == true else { return nil }
        #if DEBUG
        if let pick = UserDefaults.standard.string(forKey: "HQDebugPaperPills").flatMap(PaperPills.init(rawValue:)) { return pick }
        #endif
        // Owner 2026-11-17 ("The pills do [need to be glass]… TOO much like paper and not like a Claude mimic"): glass, as
        // Claude's own app. The flat styles stay for comparison in a DEBUG build.
        return .glass
    }
    /// [paper-solid] Paper without Liquid Glass of its own: plain bar glyphs and Back, solid sheets, a solid tab bar and
    /// text box. Off: build 1051 shipped it and the owner rejected it the next morning (2026-11-17: "We ruined the paper
    /// theme… The text input needs to be glass. The pills do, too… TOO much like paper and not like a Claude mimic").
    /// Claude's own app keeps iOS's glass chrome, so Paper does too. A DEBUG build still shows it with
    /// `-HQDebugPaperSolid YES`, to compare.
    static var solidChrome: Bool {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "HQDebugPaperSolid") else { return false }
        return !isDesktop && !DeviceWord.isMac && ThemeTable.current.light.ownLook?.flatPills == true
        #else
        return false
        #endif
    }
    /// The pills are drawn flat, not on glass.
    static var flatPills: Bool { paperPills.map { $0 != .glass } ?? false }
    /// A picked pill's words: the ink's own on a soft pill, the on-accent ink on the solid accent.
    static var pickedPillInk: Color { paperPills == .soft ? .hqLabel : .hqOnTint }
    static var inkIcons: InkIcons? {
        guard !isDesktop, let own = ThemeTable.current.light.ownLook, own.iconTile != nil else { return nil }
        #if DEBUG
        if UserDefaults.standard.string(forKey: "HQDebugInkIcons") == "tiles" { return .tiles }
        #endif
        return own.plainIcons ? .plain : .tiles
    }

    /// SwiftUI bodies that pick a font, a shape or a colour call this (through `Font.hq`, `Color.hq…`), so they run
    /// again when the theme changes.
    static func touch() { _ = shared.generation; _ = shared.textSizeTick }

    // MARK: Windows

    /// Every window gets the generation and, for a skin with one look, the matching iOS appearance (so the keyboard,
    /// menus and the status bar agree with it). Called for the first window before its first frame.
    func adopt(_ window: UIWindow?) {
        guard let window else { return }
        window.traitOverrides[ThemeGenerationTrait.self] = generation
        window.overrideUserInterfaceStyle = style(for: AppearanceSetting.current.style)
        // The standard app never set a window tint (system blue on the system's own controls): leave it inherited.
        window.tintColor = Theme.isStandard(state) ? nil : HQPalette.tint
        // [desktoplook] The look's outlines and borders are layer colours, resolved when drawn: light/dark or Increase
        // Contrast changing on its own (not through `reload`) repaints them too.
        if watchedWindows.insert(ObjectIdentifier(window)).inserted {
            window.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (window: UIWindow, _) in
                if Theme.isDesktop { ThemeChrome.restyle(window, layoutChanged: false) }
            }
        }
    }

    /// The appearance the windows take: the person's own choice unless the skin has one look.
    func style(for chosen: UIUserInterfaceStyle) -> UIUserInterfaceStyle {
        guard let forced = ThemeTable.current.forcedDark else { return chosen }
        return forced ? .dark : .light
    }

    private var windows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }

    // MARK: Changes

    func pick(skin id: String) {
        store.pick(skin: id)
        reload()
    }

    func setDesktopLook(_ on: Bool) {
        store.setDesktopLook(on)
        reload()
    }

    func setHighContrast(_ on: Bool) {
        store.setHighContrast(on)
        reload()
    }

    func setUIScale(_ percent: Int) {
        store.setUIScale(percent)
        reload()
    }

    /// [density] Theme › Density. [desktop-density] The look in use's own: each look keeps the one picked in it.
    func setDensity(_ density: ListDensity) {
        store.setDensity(density, desktop: state.desktopLook)
        reload()
    }

    /// Theme › Bubble Corners: set once the slider is let go, so a drag doesn't lay every chat out again.
    /// [desktop-corners] The look in use's own corner: each look keeps the one picked in it.
    func setBubbleCorners(_ points: Int) {
        store.setBubbleCorners(points, desktop: state.desktopLook)
        reload()
    }

    /// [desktop-composer] Theme › Text Box (the Desktop Look).
    func setDesktopComposer(_ composer: DesktopComposer) {
        store.setDesktopComposer(composer)
        reload()
    }

    /// [glass-bubbles] Theme › Chat Bubbles › Glass (the iOS look).
    func setGlassBubbles(_ on: Bool) {
        store.setGlassBubbles(on)
        reload()
    }

    /// [tinted-bubbles] Theme › Chat Bubbles › Style (the iOS look).
    func setBubbleStyle(_ style: BubbleStyle) {
        store.setBubbleStyle(style)
        reload()
    }

    /// [message-colour] Chat Bubbles › Colour (the iOS look).
    func setMessageColour(_ colour: MessageColour) {
        store.setMessageColour(colour)
        reload()
    }

    /// [plain-replies] Chat Bubbles › Reply Bubbles (the iOS look, and High Contrast in the Desktop Look).
    func setPlainReplies(_ on: Bool) {
        store.setPlainReplies(on)
        reload()
    }

    /// [top-edge] Theme › Themes › Top Edge.
    func setTopEdge(_ edge: TopEdge) {
        store.setTopEdge(edge)
        reload()
    }

    /// Resets every on-device appearance setting (theme, look, scale, bubbles, backgrounds, working ring, light/dark)
    /// back to the shipped defaults.
    func resetAppearance() {
        store.reset()
        AppearanceSetting.current = .system
        Backdrop.app.reset()
        Backdrop.chats.reset()
        WorkingRing.isOn = false
        reload()
    }

    /// Reads the stored state again and repaints if it changed. One cross-dissolve, none under Reduce Motion; no
    /// screen is torn down.
    func reload(animated: Bool = true) {
        let next = store.load()
        guard next != state else { return }
        let layoutChanged = next.layoutSignature != state.layoutSignature
        let lookChanged = next.desktopLook != state.desktopLook
        let solidBefore = Self.solidChrome   // [paper-solid] Paper's solid chrome came or went: restyle as a look change
        let apply = { [self] in
            state = next
            generation = ThemeTable.install(ThemeResolver.resolve(next))
            if next.desktopLook { ThemeChrome.prepareSolidChrome() }
            let solidChanged = Self.solidChrome != solidBefore
            if Self.solidChrome { ThemeChrome.preparePanelHook() }
            UIView.performWithoutAnimation {
                for window in windows {
                    adopt(window)
                    window.updateTraitsIfNeeded()
                    // [mac] A UI Scale step in the iOS look (the Mac's text size) re-lays the screens too.
                    if lookChanged || next.desktopLook || layoutChanged || solidChanged { ThemeChrome.restyle(window, layoutChanged: layoutChanged) }
                }
                NotificationCenter.default.post(name: Theme.didChange, object: self,
                                                userInfo: ["layout": layoutChanged, "look": lookChanged])
                for window in windows { window.layoutIfNeeded() }
            }
            ListTrail.themeChanged(windows)   // [diagnostics] Mac 479: a List looped on Settings › Theme after a change
        }
        let live = windows.filter { !$0.isHidden }
        guard animated, !HQMotion.reduced, let window = live.first(where: \.isKeyWindow) ?? live.first else {
            apply()
            return
        }
        UIView.transition(with: window, duration: HQMotion.fade, options: [.transitionCrossDissolve, .allowUserInteraction]) { apply() }
    }
}
