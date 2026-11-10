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

    /// [density] Theme › Density (the iOS look).
    func setDensity(_ density: ListDensity) {
        store.setDensity(density)
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

    /// [top-edge] Theme › Themes › Top Edge.
    func setTopEdge(_ edge: TopEdge) {
        store.setTopEdge(edge)
        reload()
    }

    /// Reads the stored state again and repaints if it changed. One cross-dissolve, none under Reduce Motion; no
    /// screen is torn down.
    func reload(animated: Bool = true) {
        let next = store.load()
        guard next != state else { return }
        let layoutChanged = next.layoutSignature != state.layoutSignature
        let lookChanged = next.desktopLook != state.desktopLook
        let apply = { [self] in
            state = next
            generation = ThemeTable.install(ThemeResolver.resolve(next))
            if next.desktopLook { ThemeChrome.prepareSolidChrome() }
            UIView.performWithoutAnimation {
                for window in windows {
                    adopt(window)
                    window.updateTraitsIfNeeded()
                    // [mac] A UI Scale step in the iOS look (the Mac's text size) re-lays the screens too.
                    if lookChanged || next.desktopLook || layoutChanged { ThemeChrome.restyle(window, layoutChanged: layoutChanged) }
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
        UIView.transition(with: window, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) { apply() }
    }
}
