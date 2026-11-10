// desktoplook3: no Liquid Glass in the Desktop Look. Back is a flat stand-in that respects the page's own wish to
// hide it, the search field leaves the floating glass toolbar, bar items set later are flattened, and the look going
// off puts every one of them back.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

private func set(look: Bool) -> ThemeSet {
    ThemeResolver.resolve(ThemeState(skinID: "midnight", desktopLook: look, highContrast: false, uiScalePercent: 100))
}

@MainActor private func stack() -> (UINavigationController, UIViewController) {
    DesktopBars.install()
    let root = UIViewController()
    root.title = "Bots"
    let page = UIViewController()
    let navigation = UINavigationController(rootViewController: root)
    navigation.pushViewController(page, animated: false)
    return (navigation, page)
}

@MainActor @Suite struct DesktopGlassTests {
    @Test func backIsAFlatStandInInTheLookAndTheSystemsOwnOffIt() {
        let (navigation, page) = stack()
        let item = page.navigationItem
        ThemeTable.$testSet.withValue(set(look: true)) {
            DesktopBars.apply(navigation.navigationBar, desktop: true)
            let back = DesktopBack.standIn(of: item)
            #expect(back != nil)
            #expect(item.leftBarButtonItems?.first === back)
            #expect(back?.hidesSharedBackground == true, "no glass circle")
            #expect(back?.accessibilityIdentifier == "BackButton")
            #expect(back?.accessibilityLabel == "Bots")
            #expect(back?.menu != nil, "a long press lists the pages under it")
            #expect(item.hidesBackButton, "the system Back is hidden under it")
            #expect(DesktopBack.standIn(of: navigation.viewControllers[0].navigationItem) == nil, "the root has no Back")
        }
        ThemeTable.$testSet.withValue(set(look: false)) {
            DesktopBars.apply(navigation.navigationBar, desktop: false)
            #expect(DesktopBack.standIn(of: item) == nil)
            #expect(item.leftBarButtonItems?.isEmpty ?? true)
            #expect(!item.hidesBackButton, "the system Back is back")
        }
    }

    /// A page's own back action (unsaved changes ask first) made the Mac draw the system Back beside the stand-in:
    /// in the look the action moves to the stand-in, off it the page has it again.
    @Test func aPagesOwnBackActionMovesToTheStandIn() {
        let (navigation, page) = stack()
        let item = page.navigationItem
        var taps = 0
        item.backAction = UIAction { _ in taps += 1 }
        ThemeTable.$testSet.withValue(set(look: true)) {
            DesktopBars.apply(navigation.navigationBar, desktop: true)
            let back = DesktopBack.standIn(of: item)
            #expect(item.backAction == nil, "no system Back beside the stand-in")
            back?.primaryAction?.performWithSender(nil, target: nil)
            #expect(taps == 1, "a tap on the stand-in runs the page's own action")
            DesktopBars.apply(navigation.navigationBar, desktop: true)
            #expect(item.backAction == nil)
            back?.primaryAction?.performWithSender(nil, target: nil)
            #expect(taps == 2)
        }
        ThemeTable.$testSet.withValue(set(look: false)) {
            DesktopBars.apply(navigation.navigationBar, desktop: false)
            #expect(DesktopBack.standIn(of: item) == nil)
            item.backAction?.performWithSender(nil, target: nil)
            #expect(taps == 3, "the page has its action again")
        }
    }

    @Test func aPageThatHidesBackKeepsItHidden() {
        let (navigation, page) = stack()
        let item = page.navigationItem
        ThemeTable.$testSet.withValue(set(look: true)) {
            DesktopBars.apply(navigation.navigationBar, desktop: true)
            #expect(DesktopBack.standIn(of: item) != nil)
            item.setHidesBackButton(true, animated: false)             // an edit mode
            #expect(DesktopBack.intendedHidesBackButton(item))
            DesktopBars.apply(navigation.navigationBar, desktop: true)
            #expect(DesktopBack.standIn(of: item) == nil, "no Back while the page hides it")
            #expect(item.hidesBackButton)
            item.hidesBackButton = false                               // the edit ends
            #expect(!DesktopBack.intendedHidesBackButton(item))
            DesktopBars.apply(navigation.navigationBar, desktop: true)
            #expect(DesktopBack.standIn(of: item) != nil, "Back returns")
        }
        ThemeTable.$testSet.withValue(set(look: false)) {
            DesktopBars.apply(navigation.navigationBar, desktop: false)
            #expect(!item.hidesBackButton)
        }
    }

    @Test func leadingItemsThatReplaceBackGetNoStandIn() {
        let (navigation, page) = stack()
        let item = page.navigationItem
        let cancel = UIBarButtonItem(systemItem: .cancel)
        item.leftBarButtonItems = [cancel]
        ThemeTable.$testSet.withValue(set(look: true)) {
            DesktopBars.apply(navigation.navigationBar, desktop: true)
            #expect(DesktopBack.standIn(of: item) == nil)
            #expect(item.leftBarButtonItems?.count == 1)
            #expect(cancel.hidesSharedBackground, "the page's own item is flat")
            item.leftItemsSupplementBackButton = true
            DesktopBars.apply(navigation.navigationBar, desktop: true)
            #expect(item.leftBarButtonItems?.first === DesktopBack.standIn(of: item), "Back leads the page's items")
            #expect(item.leftBarButtonItems?.last === cancel)
        }
        ThemeTable.$testSet.withValue(set(look: false)) {
            DesktopBars.apply(navigation.navigationBar, desktop: false)
            #expect(item.leftBarButtonItems?.count == 1 && item.leftBarButtonItems?.first === cancel)
            #expect(!cancel.hidesSharedBackground, "and has its glass again")
        }
    }

    @Test func itemsSetLaterAreFlatInTheLookOnly() {
        DesktopBars.install()
        let item = UINavigationItem(title: "Settings")
        ThemeTable.$testSet.withValue(set(look: true)) {
            item.leftBarButtonItem = UIBarButtonItem(systemItem: .close)
            #expect(item.leftBarButtonItem?.hidesSharedBackground == true)
        }
        ThemeTable.$testSet.withValue(set(look: false)) {
            item.rightBarButtonItem = UIBarButtonItem(systemItem: .done)
            #expect(item.rightBarButtonItem?.hidesSharedBackground == false)
        }
    }

    @Test func searchLeavesTheFloatingToolbarInTheLookAndReturnsOffIt() {
        let item = UINavigationItem(title: "Settings")
        let search = UISearchController(searchResultsController: nil)
        item.searchController = search
        #expect(item.searchBarPlacementAllowsToolbarIntegration)
        ThemeTable.$testSet.withValue(set(look: true)) {
            DesktopBars.flattenSearch(item, desktop: true)
            #expect(!item.searchBarPlacementAllowsToolbarIntegration)
            #expect(search.searchBar.searchTextField.layer.borderWidth == 1)
            #expect(search.searchBar.searchTextField.layer.cornerRadius == 4)
        }
        ThemeTable.$testSet.withValue(set(look: false)) {
            DesktopBars.flattenSearch(item, desktop: false)
            #expect(item.searchBarPlacementAllowsToolbarIntegration)
            #expect(search.searchBar.searchTextField.layer.borderWidth == 0)
        }
    }

    /// The Filter is a UIButton in the bar (its menu stays live; Bots and Sessions draw the same one), Search and Compose
    /// beside it plain bar items: the Filter's glyph is a plain item's size off the look, in it, and off it again (owner
    /// 2026-10-24: "They're different sizes").
    @Test func theFilterDrawsAPlainItemsSize() {
        DesktopBars.install()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let page = UIViewController()
        let navigation = UINavigationController(rootViewController: page)
        let plain = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease"), menu: UIMenu(children: []))
        page.navigationItem.rightBarButtonItems = [plain]
        let capsule = PageBarCapsule(host: page, configuration: .init(page: "sessions", filterMenu: { [] }))
        capsule.install()
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func redraw() {
            plain.image = UIImage(systemName: "line.3.horizontal.decrease")
            capsule.setFilterActive(false, token: nil)
        }
        func glyphs() -> (button: CGSize?, item: CGSize?) {
            navigation.view.layoutIfNeeded()
            navigation.navigationBar.setNeedsLayout()
            navigation.navigationBar.layoutIfNeeded()
            capsule.filterButton?.layoutIfNeeded()
            var item: CGSize?
            func walk(_ view: UIView) {
                if let glyph = view as? UIImageView, glyph.image?.isSymbolImage == true,
                   capsule.filterButton.map({ !glyph.isDescendant(of: $0) }) ?? true { item = glyph.bounds.size }
                view.subviews.forEach(walk)
            }
            walk(navigation.navigationBar)
            return (capsule.filterButton?.imageView?.bounds.size, item)
        }
        func expectSame(_ glyphs: (button: CGSize?, item: CGSize?), _ when: String) {
            guard let button = glyphs.button, let item = glyphs.item else { Issue.record("no glyphs \(when)"); return }
            #expect(abs(button.width - item.width) < 0.1 && abs(button.height - item.height) < 0.1, "\(when): \(button) vs \(item)")
        }
        var off: CGSize?
        ThemeTable.$testSet.withValue(set(look: false)) {
            redraw()
            let sizes = glyphs()
            expectSame(sizes, "off the look")
            off = sizes.button
        }
        ThemeTable.$testSet.withValue(set(look: true)) {
            DesktopBars.flattenButtons(of: page.navigationItem, desktop: true)
            redraw()
            let small = UIImage(systemName: "line.3.horizontal.decrease")?
                .applyingSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: DesktopBars.glyphSize, weight: .regular))
            #expect(plain.image?.size == small?.size, "a plain item's new image is made smaller at once, not at the bar's next layout")
            let sizes = glyphs()
            expectSame(sizes, "in the look")
            if let button = sizes.button, let off { #expect(button.width < off.width, "the look's glyph is the smaller one") }
        }
        ThemeTable.$testSet.withValue(set(look: false)) {
            DesktopBars.flattenButtons(of: page.navigationItem, desktop: false)
            redraw()
            let sizes = glyphs()
            expectSame(sizes, "off the look again")
            #expect(sizes.button == off, "the button's own size is put back")
        }
    }

    /// The Filter takes the room a plain item would, so its capsule is as wide as Bots' was with a plain Filter and the
    /// glyph sits in the same place (owner 2026-10-24: it moved a little between Bots and Sessions; the bar gave the bare
    /// button 5 pt less). Off the look and in it, at three text sizes, plain and filled.
    @Test func theFilterSitsWhereAPlainItemWould() {
        DesktopBars.install()
        let lines = "line.3.horizontal.decrease", filled = "line.3.horizontal.decrease.circle.fill"
        func page(_ text: UIContentSizeCategory, plain: Bool) -> (UIWindow, UINavigationController, PageBarCapsule?, UIBarButtonItem?) {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            window.traitOverrides.preferredContentSizeCategory = text
            let page = UIViewController()
            page.title = "Bots"
            let navigation = UINavigationController(rootViewController: page)
            navigation.navigationBar.prefersLargeTitles = true
            var capsule: PageBarCapsule?, item: UIBarButtonItem?
            if plain {                       // Filter · Search · Compose, all plain items (Bots before)
                let filter = UIBarButtonItem(image: UIImage(systemName: lines), menu: UIMenu(children: []))
                page.navigationItem.rightBarButtonItems = [
                    UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), primaryAction: UIAction { _ in }),
                    UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), primaryAction: UIAction { _ in }), filter,
                ]
                item = filter
            } else {
                capsule = PageBarCapsule(host: page, configuration: .init(
                    page: "bots", filterMenu: { [] }, search: UISearchController(searchResultsController: nil), compose: .action({})))
                capsule?.install()
            }
            window.rootViewController = navigation
            window.makeKeyAndVisible()
            return (window, navigation, capsule, item)
        }
        /// The leading glyph in the bar, in the window.
        func filterGlyph(_ navigation: UINavigationController) -> CGRect? {
            navigation.view.layoutIfNeeded()
            navigation.navigationBar.layoutIfNeeded()
            var found: CGRect?
            func walk(_ view: UIView) {
                if let glyph = view as? UIImageView, glyph.image?.isSymbolImage == true {
                    let frame = glyph.convert(glyph.bounds, to: nil)
                    if frame.minX < found?.minX ?? .infinity { found = frame }
                }
                view.subviews.forEach(walk)
            }
            walk(navigation.navigationBar)
            return found
        }
        for text in [UIContentSizeCategory.large, .extraLarge, .accessibilityExtraExtraExtraLarge] {
            let plain = page(text, plain: true), ours = page(text, plain: false)
            defer { plain.0.isHidden = true; ours.0.isHidden = true }
            for look in [false, true] {
                ThemeTable.$testSet.withValue(set(look: look)) {
                    for active in [false, true] {
                        DesktopBars.apply(plain.1.navigationBar, desktop: look)
                        DesktopBars.apply(ours.1.navigationBar, desktop: look)
                        plain.3?.image = UIImage(systemName: active ? filled : lines)
                        ours.2?.setFilterActive(active, token: active ? "Archived" : nil)
                        let when = "\(text.rawValue), look \(look), filled \(active)"
                        guard let want = filterGlyph(plain.1), let got = filterGlyph(ours.1) else { Issue.record("no glyph: \(when)"); continue }
                        // UIButton and the bar's own item round a half pixel differently: one pixel (⅓ pt) at most.
                        #expect(abs(got.width - want.width) < 0.34 && abs(got.height - want.height) < 0.34, "size, \(when): \(got) vs \(want)")
                        #expect(abs(got.minX - want.minX) < 0.34, "across, \(when): \(got) vs \(want)")
                        #expect(abs(got.minY - want.minY) < 0.34, "down, \(when): \(got) vs \(want)")
                    }
                }
            }
        }
    }

    // a11y: the look's smaller bar glyph still grows with the text size (15 pt at the default, as the owner approved).
    @Test func theLooksBarGlyphGrowsWithTheTextSize() {
        let large = UITraitCollection(preferredContentSizeCategory: .large)
        let huge = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraLarge)
        #expect(DesktopBars.pointSize(large) == DesktopBars.glyphSize)
        #expect(DesktopBars.pointSize(huge) > DesktopBars.glyphSize + 10)
        let item = UINavigationItem()
        let button = UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), style: .plain, target: nil, action: nil)
        item.rightBarButtonItems = [button]
        ThemeTable.$testSet.withValue(set(look: true)) {
            DesktopBars.flattenButtons(of: item, desktop: true, traits: large)
            let small = button.image?.size ?? .zero
            DesktopBars.flattenButtons(of: item, desktop: true, traits: huge)
            let big = button.image?.size ?? .zero
            #expect(big.width > small.width && big.height > small.height, "\(small) then \(big)")
            DesktopBars.flattenButtons(of: item, desktop: true, traits: large)
            #expect(button.image?.size == small, "back to the default size")
            DesktopBars.flattenButtons(of: item, desktop: false)
        }
        DesktopBars.flattenButtons(of: UINavigationItem(), desktop: true, traits: large)
    }

    // desktoplook4: a glass piece inside a glass container (the shelf's chips) is flattened, and comes back off the look.
    @Test func glassInsideAContainerIsFlattenedInTheLook() {
        let container = UIVisualEffectView(effect: UIGlassContainerEffect())
        let piece = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        container.contentView.addSubview(piece)
        ThemeTable.$testSet.withValue(set(look: true)) {
            ThemeChrome.restyleGlass(in: container)
            #expect(piece.effect == nil, "no glass left on the piece")
            #expect(piece.layer.borderWidth == HQShape.hairline)
        }
        ThemeTable.$testSet.withValue(set(look: false)) {
            ThemeChrome.restyleGlass(in: container)
            #expect(piece.effect is UIGlassEffect)
            #expect(piece.layer.borderWidth == 0)
        }
    }
}
