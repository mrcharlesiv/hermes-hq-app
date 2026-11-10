// glass: half-height sheets sit on Liquid Glass in the iOS look (owner 2026-10-30, "utilize more liquid glass, like in
// pop-ups"), with every row on a solid card; the Desktop Look keeps them opaque, and turning it on or off switches them.

import Testing
import UIKit
@testable import HermesHQNative

private func set(look: Bool) -> ThemeSet {
    ThemeResolver.resolve(ThemeState(skinID: "nous", desktopLook: look, highContrast: false, uiScalePercent: 100))
}

private func pageSheet() -> UISheetPresentationController {
    let navigation = UINavigationController(rootViewController: UIViewController())
    navigation.modalPresentationStyle = .pageSheet
    return navigation.sheetPresentationController!
}

private func alpha(_ color: UIColor, glass: Bool, dark: Bool) -> CGFloat {
    let traits = UITraitCollection { t in
        t.userInterfaceStyle = dark ? .dark : .light
        t.userInterfaceLevel = .elevated
        t[GlassSheetTrait.self] = glass
    }
    return color.resolvedColor(with: traits).cgColor.alpha
}

@MainActor @Suite(.serialized) struct SheetGlassTests {
    // [mac-audit #27] 2026-11-02: `backgroundEffect` is unavailable on Mac Catalyst; without the guard the test bundle
    // doesn't compile for the Mac at all. These two run on the iPhone simulator.
#if !targetEnvironment(macCatalyst)
    @Test func aGlassPageHasTheSystemsGlassOffTheLookAndAnOpaquePageInIt() {
        guard #available(iOS 26.1, *) else { return }
        let sheet = pageSheet()
        ThemeTable.$testSet.withValue(set(look: false)) { sheet.hqGlassPage() }
        #expect(sheet.backgroundEffect == nil)
        ThemeTable.$testSet.withValue(set(look: true)) { SheetGlass.apply(sheet, desktop: true) }
        #expect(sheet.backgroundEffect is UIColorEffect)
        ThemeTable.$testSet.withValue(set(look: false)) { SheetGlass.apply(sheet, desktop: false) }
        #expect(sheet.backgroundEffect == nil)
    }

    @Test func anyOtherSheetIsOpaqueInTheLookAndGetsBackWhatItHad() {
        guard #available(iOS 26.1, *) else { return }
        let plain = pageSheet()   // How Voice Works: the system's glass, no effect of its own
        SheetGlass.apply(plain, desktop: true)
        #expect(plain.backgroundEffect is UIColorEffect)
        SheetGlass.apply(plain, desktop: false)
        #expect(plain.backgroundEffect == nil)

        let opaque = pageSheet()  // Webhooks: opaque at every height, in both looks
        opaque.hqOpaqueGroupedPage()
        let own = opaque.backgroundEffect
        SheetGlass.apply(opaque, desktop: true)
        #expect(opaque.backgroundEffect === own)
        SheetGlass.apply(opaque, desktop: false)
        #expect(opaque.backgroundEffect === own)
    }
#endif

    // Owner 2026-11-01: no "hard colors (grey background) on the Liquid Glass pop up": on the glass a card is a frosted
    // pane and a code block a shade; off it both are solid as they always were.
    @Test func thePageIsClearOnlyOnGlassAndTheCardIsFrostedOnlyOnGlass() {
        for dark in [false, true] {
            #expect(alpha(HQPalette.sheetPage, glass: true, dark: dark) == 0)
            #expect(alpha(HQPalette.sheetPage, glass: false, dark: dark) == 1)
            #expect(alpha(HQPalette.sheetCard, glass: true, dark: dark) < 0.6)
            #expect(alpha(HQPalette.sheetCard, glass: true, dark: dark) > 0)
            #expect(alpha(HQPalette.sheetCard, glass: false, dark: dark) == 1)
            #expect(alpha(HQPalette.solidSheetCard, glass: true, dark: dark) == 1)
            #expect(alpha(HQPalette.glassPane, glass: false, dark: dark) < 0.6, "the model panel's cards are always on glass")
            #expect(alpha(HQPalette.sheetCode, glass: true, dark: dark) < 0.5)
        }
    }

    // glass-design rule 5 (owner 2026-11-01): a solid card on the glass has a thin edge; off the glass it has none.
    @Test func theCardsEdgeShowsOnlyOnGlass() {
        for dark in [false, true] {
            #expect(alpha(HQPalette.glassEdge, glass: true, dark: dark) > 0)
            #expect(alpha(HQPalette.glassEdge, glass: false, dark: dark) == 0)
            #expect(alpha(HQPalette.cardEdge, glass: false, dark: dark) > 0, "the model panel's cards are always on glass")
        }
    }

    @Test func aHandMadeCardGetsItsEdgeOnGlassAndLosesItAtFullHeight() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.traitOverrides[GlassSheetTrait.self] = true
        let card = UIView(frame: CGRect(x: 20, y: 20, width: 300, height: 100))
        window.addSubview(card)
        window.isHidden = false
        window.layoutIfNeeded()
        ThemeTable.$testSet.withValue(set(look: false)) {
            card.hqGlassEdge()
            #expect(card.layer.borderWidth == 1)
            window.traitOverrides[GlassSheetTrait.self] = false
            window.layoutIfNeeded()
            #expect(card.layer.borderWidth == 0)
        }
        window.isHidden = true
    }
}
