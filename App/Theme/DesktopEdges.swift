// desktop-glass-sweep: the last Liquid Glass the Desktop Look can take away (owner, 2026-10-17: "all of the liquid
// glass removed that we can on the desktop theming").
// - Scroll edge effects: iOS 26 blurs and fades a list's content where it runs under the top bar and the tab bar (a
//   backdrop layer per edge). The bars are solid in the look, so the content simply ends at them, as on the desktop.
//   Every scroll view the app shows (UIKit and SwiftUI lists, sheets, text views, code blocks) has its edges hidden when
//   it joins a window (`UIScrollView.didMoveToWindow`, exchanged on UIScrollView itself, installed the first time the
//   look is turned on, as ThemeChrome's glass hook is). UIKit and SwiftUI show a list's edges again after that (as the
//   bars adopt it), so they are hidden again when it lays out, with the verdict on whose list it is kept from the
//   join. SwiftUI's lists show theirs again on each update without laying out, so an edge this file hid is also held
//   hidden at its own setter (`UIScrollEdgeEffect.isHidden`, exchanged on that class) while the look is on. Only edges
//   this file hid are shown again when the look goes off.
// - Sheets: a sheet presented after the look was turned on kept iOS's round corners (ThemeChrome only restyles sheets
//   already up when the theme changes): its corners are set as it is presented
//   (`UISheetPresentationController.presentationTransitionWillBegin`).
// Menus, alerts and the keyboard are the system's and are left alone.

import ObjectiveC
import UIKit

enum DesktopEdges {
    private static var installed = false
    private static let hiddenKey = malloc(1)!
    private static let ownKey = malloc(1)!
    private static let oursKey = malloc(1)!
    static let heldKey = malloc(1)!

    /// The look, as last applied: read on every layout, so a plain flag rather than the theme table's lock.
    nonisolated(unsafe) static var on = false

    static func install() {
        on = true                      // installed only as the look is turned on
        guard !installed else { return }
        installed = true
        exchange(UIScrollView.self, #selector(UIView.didMoveToWindow), #selector(UIScrollView.hqDesktopDidMoveToWindow))
        exchange(UIScrollView.self, #selector(UIView.layoutSubviews), #selector(UIScrollView.hqDesktopLayoutSubviews))
        exchange(UIScrollEdgeEffect.self, #selector(setter: UIScrollEdgeEffect.isHidden), #selector(UIScrollEdgeEffect.hqDesktopSetHidden(_:)))
        exchange(UISheetPresentationController.self, #selector(UIPresentationController.presentationTransitionWillBegin),
                 #selector(UISheetPresentationController.hqDesktopPresentationTransitionWillBegin))
        exchange(UISheetPresentationController.self, #selector(UIPresentationController.containerViewDidLayoutSubviews),
                 #selector(UISheetPresentationController.hqDesktopContainerViewDidLayoutSubviews))
    }

    private static func exchange(_ type: AnyClass, _ selector: Selector, _ hook: Selector) {
        guard let original = class_getInstanceMethod(type, selector), let replacement = class_getInstanceMethod(type, hook) else { return }
        // Added on the class itself first, so a superclass's method is never swapped for every subclass.
        if class_addMethod(type, selector, method_getImplementation(replacement), method_getTypeEncoding(replacement)) {
            class_replaceMethod(type, hook, method_getImplementation(original), method_getTypeEncoding(original))
        } else if let own = class_getInstanceMethod(type, selector) {
            method_exchangeImplementations(own, replacement)
        }
    }

    /// A scroll view whose screen sets its own edges for the look (the chat's edge host).
    static func leaveAlone(_ scroll: UIScrollView) {
        objc_setAssociatedObject(scroll, ownKey, true, .OBJC_ASSOCIATION_RETAIN)
    }

    /// Every scroll view in the window, after the look changed.
    static func apply(in root: UIView, desktop: Bool) {
        on = desktop
        // [look-off-every-tab] A list off screen (another tab) is judged when it joins a window, not here: off the
        // window it would be marked "not ours" for good.
        if let scroll = root as? UIScrollView {
            if !desktop { apply(scroll, desktop: false) } else if scroll.window != nil { joined(scroll) }
        }
        for child in root.subviews { apply(in: child, desktop: desktop) }
    }

    private static let systemHolders = ["Menu", "Alert", "Keyboard", "UIInput", "Popover", "TextEffects", "Remote"]

    /// The app's own screens: not the system's menus, alerts or keyboard.
    static func isOurs(_ scroll: UIScrollView) -> Bool {
        if objc_getAssociatedObject(scroll, ownKey) != nil { return false }
        guard let window = scroll.window else { return false }
        let windowName = NSStringFromClass(type(of: window))
        if systemHolders.contains(where: windowName.contains) { return false }
        var current: UIView? = scroll
        while let view = current {
            let name = NSStringFromClass(type(of: view))
            if name.hasPrefix("_UI") || name.hasPrefix("UI"), systemHolders.contains(where: name.contains) { return false }
            current = view.superview
        }
        return true
    }

    /// On joining a window: whose list it is, kept for its layouts.
    static func joined(_ scroll: UIScrollView) {
        let ours = isOurs(scroll)
        objc_setAssociatedObject(scroll, oursKey, ours, .OBJC_ASSOCIATION_RETAIN)
        if ours { apply(scroll, desktop: true) }
    }

    /// On each layout (it runs as the list scrolls): four flags read, nothing more, while the edges stay hidden.
    static func laidOut(_ scroll: UIScrollView) {
        // A list that joined its window before the look was loaded is judged on its first layout in the look.
        let known = objc_getAssociatedObject(scroll, oursKey) as? Bool
        if known == nil, scroll.window != nil { joined(scroll); return }
        guard known == true else { return }
        if scroll.topEdgeEffect.isHidden, scroll.bottomEdgeEffect.isHidden, scroll.leftEdgeEffect.isHidden,
           scroll.rightEdgeEffect.isHidden { return }
        apply(scroll, desktop: true)
    }

    static func apply(_ scroll: UIScrollView, desktop: Bool) {
        let edges = [scroll.topEdgeEffect, scroll.bottomEdgeEffect, scroll.leftEdgeEffect, scroll.rightEdgeEffect]
        if desktop {
            guard isOurs(scroll) else { return }
            var hid = (objc_getAssociatedObject(scroll, hiddenKey) as? Int) ?? 0
            for (index, edge) in edges.enumerated() where !edge.isHidden {
                edge.isHidden = true
                objc_setAssociatedObject(edge, heldKey, true, .OBJC_ASSOCIATION_RETAIN)
                hid |= 1 << index
            }
            if hid != 0 { objc_setAssociatedObject(scroll, hiddenKey, hid, .OBJC_ASSOCIATION_RETAIN) }
        } else if let hid = objc_getAssociatedObject(scroll, hiddenKey) as? Int {
            for (index, edge) in edges.enumerated() where hid & (1 << index) != 0 {
                objc_setAssociatedObject(edge, heldKey, nil, .OBJC_ASSOCIATION_RETAIN)
                edge.isHidden = false
            }
            objc_setAssociatedObject(scroll, hiddenKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}

extension UIScrollView {
    @objc dynamic func hqDesktopDidMoveToWindow() {
        hqDesktopDidMoveToWindow()        // the original (the implementations were exchanged)
        guard window != nil, DesktopEdges.on else { return }
        DesktopEdges.joined(self)
    }

    @objc dynamic func hqDesktopLayoutSubviews() {
        hqDesktopLayoutSubviews()         // the original (the implementations were exchanged)
        if DesktopEdges.on { DesktopEdges.laidOut(self) }
    }
}

extension UIScrollEdgeEffect {
    @objc dynamic func hqDesktopSetHidden(_ hidden: Bool) {
        // An edge this file hid stays hidden while the look is on, whoever shows it again.
        let held = !hidden && DesktopEdges.on && objc_getAssociatedObject(self, DesktopEdges.heldKey) != nil
        hqDesktopSetHidden(held ? true : hidden)     // the original (the implementations were exchanged)
    }
}

extension UISheetPresentationController {
    @objc dynamic func hqDesktopPresentationTransitionWillBegin() {
        if Theme.isDesktop { ThemeChrome.styleSheet(self, of: presentedViewController, desktop: true) }
        hqDesktopPresentationTransitionWillBegin()   // the original (the implementations were exchanged)
    }

    @objc dynamic func hqDesktopContainerViewDidLayoutSubviews() {
        hqDesktopContainerViewDidLayoutSubviews()    // the original (the implementations were exchanged)
        if Theme.isDesktop { ThemeChrome.roundSheetBottom(self) }
    }
}
