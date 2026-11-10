// desktoplook: chrome in the Desktop Look (spec 3x-desktoplook §5.2). No glass and no imitation of it: bars are the
// page colour, panels are opaque fills with a 1 pt stroke. With the look off nothing here runs and the app keeps its
// native Liquid Glass untouched.

import ObjectiveC
import SwiftUI
import UIKit

/// [desktop-composer] A view that keeps its Liquid Glass in the Desktop Look while `holdsOwnGlass` (the composer's
/// glass bar, Talk's bar in its place): the look neither flattens the glass inside it nor boxes it, and puts back what
/// it flattened there before (Text Box › Desktop, then Liquid Glass again).
@MainActor protocol HoldsOwnGlass: UIView {
    var holdsOwnGlass: Bool { get }
}

enum ThemeChrome {
    // MARK: Navigation bars

    /// The look's bar: see-through like the normal look (owner 2026-10-13: the solid band across the top should be
    /// transparent "similar to the normal theming"), no hairline (owner 2026-10-03: "lines at top/bottom/above composer
    /// removed"). `solid` gives the page colour, for a list bar once rows scroll under its title. [desktop-frost]
    /// `frosted`: a page or sheet bar in every state, the content showing through a blur under the page colour
    /// (owner, build 321: the bars "are no longer transparent like they were"; never Liquid Glass).
    static func solidBar(solid: Bool = false, frosted: Bool = false) -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        if solid {
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = HQPalette.page
        } else if frosted {
            DesktopFrost.barAppearance(appearance, color: HQPalette.page)
        } else {
            appearance.configureWithTransparentBackground()
        }
        appearance.shadowColor = .clear
        // [mac] Stress test 2026-10-28 #52: on the Mac the page-title token (the look's Headline, following UI Scale);
        // the web's fixed 14 pt drew titles smaller than the rows under them.
        let title = DeviceWord.isMac ? MacType.pageTitle : HQFont.system(ofSize: 14 * HQFont.dynamicRatio(nil), weight: .semibold)
        appearance.titleTextAttributes = [.font: title, .foregroundColor: HQPalette.label]
        // A tab root's title: the desktop label (12 pt semibold, uppercase, tracked, secondary colour).
        let label = HQFont.system(ofSize: 12 * HQFont.dynamicRatio(nil), weight: .semibold)
        appearance.largeTitleTextAttributes = [.font: label, .foregroundColor: HQPalette.label2, .kern: 12 * 0.08]
        return appearance
    }

    /// What a bar (or the appearance proxy) had before the look: put back exactly when the look goes off, so a bar
    /// appearance or tint another screen set is never replaced by a fresh default.
    private final class BarStash: NSObject {
        var standard: UINavigationBarAppearance?
        var scrollEdge: UINavigationBarAppearance?
        var compact: UINavigationBarAppearance?
        var compactScrollEdge: UINavigationBarAppearance?
        var tint: UIColor?
    }
    private static let barStashKey = malloc(1)!
    private static var proxyStash: BarStash?

    private static func snapshot(_ bar: UINavigationBar) -> BarStash {
        let stash = BarStash()
        stash.standard = bar.standardAppearance
        stash.scrollEdge = bar.scrollEdgeAppearance
        stash.compact = bar.compactAppearance
        stash.compactScrollEdge = bar.compactScrollEdgeAppearance
        return stash
    }

    private static func restore(_ stash: BarStash, to bar: UINavigationBar) {
        bar.standardAppearance = stash.standard ?? UINavigationBarAppearance()
        bar.scrollEdgeAppearance = stash.scrollEdge
        bar.compactAppearance = stash.compact
        bar.compactScrollEdgeAppearance = stash.compactScrollEdge
    }

    /// [desktop-frost] A bar that joined after the last theme change (a sheet's: the appearance proxy did not reach
    /// it, so it kept a bare iOS 26 background and the How Kanban Works text ran under its title) takes the look as it
    /// lays out (DesktopBars' layout hook).
    static func adoptLook(_ bar: UINavigationBar) {
        guard objc_getAssociatedObject(bar, barStashKey) == nil else { return }
        apply(to: bar, desktop: true)
    }

    private static func apply(to bar: UINavigationBar, desktop: Bool) {
        let stash = objc_getAssociatedObject(bar, barStashKey) as? BarStash
        if desktop {
            if stash == nil {
                let saved = snapshot(bar)
                // The bar's own tint only (an inherited one must stay inherited): the look's tint is set below.
                saved.tint = bar.hqOwnTint
                objc_setAssociatedObject(bar, barStashKey, saved, .OBJC_ASSOCIATION_RETAIN)
            }
            // [desktop-frost] Frosted in every state: with the soft scroll edges gone (DesktopEdges) nothing else is
            // behind a bar, and a bar that never learns its page scrolled (a sheet's) stayed clear over the text (owner,
            // build 321, How Kanban Works). Over the page at rest the frost reads as the page itself.
            let frosted = solidBar(frosted: true)
            // A sheet's bar at rest is the sheet's own page colour, opaque (UX study #122: over the sheet the frost read
            // as a lighter band on top of it); it frosts once content scrolls under it. Opaque, never clear, so a
            // sheet that does not tell its bar it scrolled still never shows text through (the build-321 note above).
            // [desktop-top-bar] Owner 2026-11-05 (Messaging): a pushed page's bar at rest is clear, as the page under
            // it whatever its colour (plain or grouped, any skin). The frost at rest drew the same lighter band over the
            // page as over a sheet, and the first card sat against its edge. It frosts once content scrolls under it.
            let rest = isSheetBar(bar) ? solidBar(solid: true) : solidBar()
            bar.standardAppearance = frosted
            bar.scrollEdgeAppearance = rest
            bar.compactAppearance = frosted
            bar.compactScrollEdgeAppearance = rest
            bar.tintColor = HQPalette.label2
        } else if let stash {
            restore(stash, to: bar)
            bar.tintColor = stash.tint
            objc_setAssociatedObject(bar, barStashKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    /// The bar of a stack shown as a sheet (Settings, Bot Info): its stack, or a page holding it, is presented as one.
    private static func isSheetBar(_ bar: UINavigationBar) -> Bool {
        guard let navigation = bar.delegate as? UINavigationController else { return false }
        return sequence(first: navigation as UIViewController, next: \.parent).contains {
            $0.presentingViewController != nil && $0.sheetPresentationController != nil
        }
    }

    // MARK: The whole window

    /// Walks the window after a theme change: bars, list headers, sheets, and every glass panel the app made.
    static func restyle(_ window: UIWindow, layoutChanged: Bool = true) {
        let desktop = Theme.isDesktop
        // Bars made after this (a new sheet's stack) start in the look.
        let proxy = UINavigationBar.appearance()
        if desktop {
            if proxyStash == nil { proxyStash = snapshot(proxy) }
            proxy.standardAppearance = solidBar(frosted: true)
            proxy.scrollEdgeAppearance = solidBar(frosted: true)
            proxy.compactAppearance = solidBar(frosted: true)
        } else if let stash = proxyStash {
            proxy.standardAppearance = stash.standard ?? UINavigationBarAppearance()
            proxy.scrollEdgeAppearance = stash.scrollEdge
            proxy.compactAppearance = stash.compact
            proxyStash = nil
        }
        var seen = Set<ObjectIdentifier>()
        func visit(_ controller: UIViewController?) {
            guard let controller, seen.insert(ObjectIdentifier(controller)).inserted else { return }
            if let navigation = controller as? UINavigationController {
                apply(to: navigation.navigationBar, desktop: desktop)
                // [mac-audit #5] Not a chat: it sets its own bar (`ChatViewController.applyChatLook`, on the same
                // theme change), which this replaced with a list's.
                for page in navigation.viewControllers where page.navigationItem.standardAppearance != nil
                    && page.navigationItem.largeTitleDisplayMode == .inline && !(page is ChatViewController) {
                    ListBarAppearance.apply(to: page.navigationItem)
                }
                #if targetEnvironment(macCatalyst)
                // [mac] Pages that took the page-coloured bar give it up in the look and take it back after.
                navigation.viewControllers.forEach { MacWindow.pageBar($0) }
                #endif
            }
            if let sheet = controller.presentationController as? UISheetPresentationController, controller.presentingViewController != nil {
                styleSheet(sheet, of: controller, desktop: desktop)
            }
            // [look-off-every-tab] A page not on screen (another tab, a page under the top one) is walked too.
            if controller.isViewLoaded, controller.view.window == nil { offscreen.append(controller.view) }
            controller.children.forEach(visit)
            visit(controller.presentedViewController)
        }
        var offscreen: [UIView] = []
        visit(window.rootViewController)
        // [look-off-every-tab] Turning the look off only put back what was in the window: Bots, left on another tab,
        // kept the look's flat grey bar buttons (owner 2026-11-02). Each off-screen page is walked once, at its top.
        let roots: [UIView] = [window] + offscreen.filter { view in !offscreen.contains { $0 !== view && view.isDescendant(of: $0) } }
        for root in roots {
            restyleGlass(in: root)
            // Colours follow the trait by themselves; rows are made again only when sizes or the typeface changed.
            if layoutChanged { reloadLists(in: root) }
            DesktopListOutliner.refreshAll(in: root)      // [desktoplook2] outlined sections follow (or go)
            DesktopBars.flatten(root, desktop: desktop)    // [desktoplook2] bar buttons without glass capsules
        }
    }

    /// A list the app made: its class, its data source or its delegate is the app's own. SwiftUI's lists (their
    /// private collection view, data source and delegate are all SwiftUI's) and the system's are left alone.
    static func isAppList(_ list: UIView, dataSource: AnyObject?, delegate: AnyObject?) -> Bool {
        if Bundle(for: type(of: list)) == .main { return true }
        for owner in [dataSource, delegate] {
            if let owner, Bundle(for: type(of: owner)) == .main { return true }
        }
        return false
    }

    /// Lists build their rows' fonts and sizes when a cell is made: make the visible ones again. The chat lays itself
    /// out (ChatViewController watches `Theme.didChange`).
    private static func reloadLists(in root: UIView) {
        if let list = root as? UICollectionView {
            if isAppList(list, dataSource: list.dataSource, delegate: list.delegate) {
                list.collectionViewLayout.invalidateLayout()
                list.reloadData()
            }
        } else if let table = root as? UITableView, !(table.delegate is ChatViewController) {
            if isAppList(table, dataSource: table.dataSource, delegate: table.delegate) { table.reloadData() }
        }
        for child in root.subviews { reloadLists(in: child) }
    }

    private static let sheetRadiusKey = malloc(1)!
    static func styleSheet(_ sheet: UISheetPresentationController, of controller: UIViewController, desktop: Bool) {
        SheetGlass.apply(sheet, desktop: desktop)   // [glass] no sheet glass in the look; back to glass after
        if desktop {
            if objc_getAssociatedObject(sheet, sheetRadiusKey) == nil {
                objc_setAssociatedObject(sheet, sheetRadiusKey, NSNumber(value: Double(sheet.preferredCornerRadius ?? -1)), .OBJC_ASSOCIATION_RETAIN)
            }
            sheet.preferredCornerRadius = HQShape.desktopRadius(.sheet)
        } else if let stored = objc_getAssociatedObject(sheet, sheetRadiusKey) as? NSNumber {
            sheet.preferredCornerRadius = stored.doubleValue < 0 ? nil : CGFloat(stored.doubleValue)
            objc_setAssociatedObject(sheet, sheetRadiusKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    /// [owner 2026-10-26, Choose a Bot] The look's 8 pt corners stay on top; a phone's sheet floats a few points above
    /// the screen's rounded corners, so 8 pt at the bottom put its bottom corners off the screen. Its bottom corners
    /// follow the screen's instead, as the system's own sheet does. The system splits the sheet's corners between its
    /// frame and two clipping views (top pair, bottom pair) and sets them again as it lays out, so this runs after
    /// every layout of the sheet.
    static func roundSheetBottom(_ sheet: UISheetPresentationController) {
        guard onBottomEdge(sheet), sheet.preferredCornerRadius == HQShape.desktopRadius(.sheet),
              let frame = sheet.presentedView, let page = sheet.presentedViewController.viewIfLoaded else { return }
        let top = UICornerRadius.fixed(HQShape.desktopRadius(.sheet))
        let bottom = UICornerRadius.containerConcentric(minimum: HQShape.desktopRadius(.sheet))
        let whole = UICornerConfiguration.uniformTopRadius(top, bottomLeftRadius: bottom, bottomRightRadius: bottom)
        if frame.cornerConfiguration != whole { frame.cornerConfiguration = whole }
        let lower = UICornerConfiguration.corners(topLeftRadius: nil, topRightRadius: nil, bottomLeftRadius: bottom, bottomRightRadius: bottom)
        var view = page.superview
        while let clip = view, clip !== frame {
            if clip.layer.maskedCorners == [.layerMinXMaxYCorner, .layerMaxXMaxYCorner], clip.cornerConfiguration != lower {
                clip.cornerConfiguration = lower
            } else if clip.clipsToBounds, NSStringFromClass(type(of: clip)).hasSuffix("ClippingView"), clip.cornerConfiguration != whole {
                // [sheet-fit] Owner 2026-11-08 (iOS 27): one clipping view holds all four corners at the look's 8 pt,
                // so the frame's rounder bottom corners were cut square again and the screen's own corners hid them.
                clip.cornerConfiguration = whole
            }
            view = clip.superview
        }
    }

    /// A phone's sheet, or an iPad's in a compact window: the system's bottom sheet, not a card in the window. [duo] An
    /// unfolded iPhone Duo is regular width, where a form sheet is a card as on an iPad.
    private static func onBottomEdge(_ sheet: UISheetPresentationController) -> Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        if UIDevice.current.userInterfaceIdiom == .phone,
           !AppRoot.foldable || sheet.presentingViewController.traitCollection.horizontalSizeClass == .compact { return true }
        return sheet.presentedViewController.modalPresentationStyle != .formSheet
            && sheet.presentingViewController.traitCollection.horizontalSizeClass == .compact
        #endif
    }

    // MARK: Glass panels

    private final class Stash: NSObject {
        var effect: UIVisualEffect?
        var background: UIColor?
        var radius: CGFloat = 0
        var borderWidth: CGFloat = 0
        var borderColor: CGColor?
        var masks = false
        var isPanel = false
        var corners: UICornerConfiguration?
    }
    static let stashKey = malloc(1)!   // [glass-census] was private
    static var hookInstalled = false   // [glass-census] was private

    /// The app's glass panels are found when they join a window (they are made in ~25 places and by other streams'
    /// screens). The hook is installed the first time the Desktop Look is turned on, never for someone who leaves it
    /// off, and it only touches `UIVisualEffectView`'s public `didMoveToWindow`.
    static func prepareSolidChrome() {
        DesktopBars.install()                              // [desktoplook2]
        guard !hookInstalled else { return }
        hookInstalled = true
        let type: AnyClass = UIVisualEffectView.self
        let selector = #selector(UIView.didMoveToWindow)
        let hook = #selector(UIVisualEffectView.hqThemeDidMoveToWindow)
        guard let original = class_getInstanceMethod(type, selector), let replacement = class_getInstanceMethod(type, hook) else { return }
        // Added on UIVisualEffectView itself first, so UIView's own method is never swapped for every view.
        if class_addMethod(type, selector, method_getImplementation(replacement), method_getTypeEncoding(replacement)) {
            class_replaceMethod(type, hook, method_getImplementation(original), method_getTypeEncoding(original))
        } else if let own = class_getInstanceMethod(type, selector) {
            method_exchangeImplementations(own, replacement)
        }
        // A panel whose owner gives it glass again while the look is on (a state change) is made solid again.
        // `effect`'s setter is UIVisualEffectView's own public method, so the two implementations are simply swapped.
        if let setter = class_getInstanceMethod(type, #selector(setter: UIVisualEffectView.effect)),
           let themed = class_getInstanceMethod(type, #selector(UIVisualEffectView.hqThemeSetEffect(_:))) {
            method_exchangeImplementations(setter, themed)
        }
    }

    private static let passThrough: Set<String> = ["_UIParallaxDimmingView", "_UIVisualEffectContentView"]

    /// [desktop-corners] Marks a holder of the cards docked on the text box (the queued message, the voice notice, the
    /// tips and problems above it): in the Desktop Look their boxes take the look's Corners, not its 4 pt.
    static func followCorners(_ view: UIView) {
        objc_setAssociatedObject(view, cornersKey, true, .OBJC_ASSOCIATION_RETAIN)
    }
    private static let cornersKey = malloc(1)!

    private static func insideCornersDock(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let next = current {
            if (objc_getAssociatedObject(next, cornersKey) as? Bool) == true { return true }
            current = next.superview
        }
        return false
    }

    /// [desktop-composer] Inside a view that keeps its own glass just now (`HoldsOwnGlass`).
    static func insideOwnGlass(_ view: UIView) -> Bool {
        var parent = view.superview
        while let current = parent {
            if let holder = current as? any HoldsOwnGlass { return holder.holdsOwnGlass }
            parent = current.superview
        }
        return false
    }

    /// Only panels the app made: never the system's bars, search fields, keyboard or menus.
    static func isOurs(_ view: UIVisualEffectView) -> Bool {   // [glass-census] was private
        guard Bundle(for: type(of: view)) == .main || type(of: view) == UIVisualEffectView.self else { return false }
        if DesktopLayout.keepsOwnLook(view) { return false }      // [desktoplook2] draws its own look (chat title)
        var parent = view.superview
        while let current = parent {
            if current is UINavigationBar || current is UITabBar || current is UIToolbar || current is UISearchBar { return false }
            let name = NSStringFromClass(type(of: current))
            // A push's dimming wrapper (a chat's overlays join the window inside it, mid-push) and a glass container's
            // own content view (the shelf's chips) are only holders: the walk goes on above them.
            if passThrough.contains(name) { parent = current.superview; continue }
            if name.hasPrefix("_UI") || name.hasPrefix("UIInput") || name.hasPrefix("UIKeyboard") || name.hasPrefix("UIRemote") { return false }
            parent = current.superview
        }
        return true
    }

    static func restyleGlass(in root: UIView) {
        if let panel = root as? UIVisualEffectView { solidify(panel) }
        for child in root.subviews { restyleGlass(in: child) }
    }

    static func solidify(_ view: UIVisualEffectView) {
        let desktop = Theme.isDesktop && !insideOwnGlass(view)
        let stash = objc_getAssociatedObject(view, stashKey) as? Stash
        if desktop {
            if view.effect is UIGlassEffect || view.effect is UIGlassContainerEffect, isOurs(view) {
                let saved = stash ?? Stash()
                if stash == nil {
                    saved.background = view.backgroundColor
                    saved.radius = view.layer.cornerRadius
                    saved.borderWidth = view.layer.borderWidth
                    saved.borderColor = view.layer.borderColor
                    saved.masks = view.layer.masksToBounds
                    saved.corners = view.cornerConfiguration
                }
                saved.effect = view.effect
                saved.isPanel = view.effect is UIGlassEffect
                objc_setAssociatedObject(view, stashKey, saved, .OBJC_ASSOCIATION_RETAIN)
                view.effect = nil
            }
            // Mac polish #66: a panel that has since taken on its own look (the message bar's field flattens itself
            // into the bar's one box) is not boxed again: a later pass drew a second, lighter box inside the group
            // chat's empty bar until a keystroke laid the bar out.
            guard let saved = objc_getAssociatedObject(view, stashKey) as? Stash, saved.isPanel,
                  !DesktopLayout.keepsOwnLook(view) else { return }
            view.backgroundColor = ChatPalette.editor
            view.layer.borderWidth = HQShape.hairline
            view.layer.borderColor = ChatPalette.strokeSecondary.resolvedColor(with: view.traitCollection).cgColor
            // [desktop-corners] The cards docked on the text box round as your messages and the text box do.
            let radius = insideCornersDock(view) ? ChatMetrics.bubbleRadius : 4
            view.layer.cornerRadius = min(saved.radius > 0 ? saved.radius : radius, radius)
            view.layer.masksToBounds = true
            view.cornerConfiguration = .corners(radius: .fixed(radius))
        } else if let stash {
            // Mac polish #79: an effect its owner set as the look went off is newer than the stash (the Talk disc's
            // tinted glass); putting the stashed one back turned the blue disc grey.
            if view.effect == nil { view.effect = stash.effect }
            if let corners = stash.corners { view.cornerConfiguration = corners }
            view.backgroundColor = stash.background
            view.layer.borderWidth = stash.borderWidth
            view.layer.borderColor = stash.borderColor
            view.layer.cornerRadius = stash.radius
            view.layer.masksToBounds = stash.masks
            objc_setAssociatedObject(view, stashKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}

extension UIVisualEffectView {
    @objc dynamic func hqThemeSetEffect(_ effect: UIVisualEffect?) {
        hqThemeSetEffect(effect)          // the original (the implementations were exchanged)
        guard effect is UIGlassEffect || effect is UIGlassContainerEffect, window != nil, Theme.isDesktop else { return }
        ThemeChrome.solidify(self)
    }

    @objc dynamic func hqThemeDidMoveToWindow() {
        hqThemeDidMoveToWindow()          // the original (the implementations were exchanged)
        guard window != nil, Theme.isDesktop else { return }
        // After the caller finished setting the panel up (its effect, its corners).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            #if DEBUG
            GlassCensus.noteMove(self)        // [glass-census]
            #endif
            ThemeChrome.solidify(self)
        }
    }
}

private extension UINavigationBar {
    /// The tint set on this bar itself, nil when it only inherits one.
    var hqOwnTint: UIColor? {
        guard let superview else { return nil }
        return tintColor == superview.tintColor ? nil : tintColor
    }
}
