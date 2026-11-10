// desktop-frost: the Desktop Look's bars and bands are see-through again (owner, build 321), without Liquid Glass. With
// the soft scroll edges hidden in the look (DesktopEdges), a bar must carry its own background: one with neither ran
// the How Kanban Works text under its title.

import Testing
import UIKit
@testable import HermesHQNative

private func set(look: Bool) -> ThemeSet {
    ThemeResolver.resolve(ThemeState(skinID: "slate", desktopLook: look, highContrast: false, uiScalePercent: 100))
}

/// A background that softens what runs under it: a non-glass blur under a part-alpha colour.
private func isFrosted(_ appearance: UINavigationBarAppearance?) -> Bool {
    guard let appearance, let effect = appearance.backgroundEffect else { return false }
    guard effect is UIBlurEffect, !(effect is UIGlassEffect) else { return false }
    let alpha = appearance.backgroundColor?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).cgColor.alpha ?? 0
    return alpha > 0 && alpha < 1
}

/// What the bar draws behind its title in each state.
private func appearances(_ bar: UINavigationBar) -> [UINavigationBarAppearance?] {
    [bar.standardAppearance, bar.scrollEdgeAppearance, bar.compactAppearance, bar.compactScrollEdgeAppearance]
}

@MainActor @Suite(.serialized) struct DesktopFrostTests {
    @Test func aBarThatJoinsInTheLookIsNeverBare() {
        DesktopBars.install()
        ThemeTable.$testSet.withValue(set(look: true)) {
            // A sheet's stack made after the last theme change: only the bar's own layout reaches it.
            let page = UIViewController()
            let navigation = UINavigationController(rootViewController: page)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
            window.rootViewController = navigation
            window.isHidden = false
            navigation.navigationBar.setNeedsLayout()
            navigation.navigationBar.layoutIfNeeded()
            let bar = navigation.navigationBar
            for appearance in [bar.standardAppearance, bar.compactAppearance] {
                // Neither a background nor a scroll edge effect behind the title: text runs under it.
                #expect(isFrosted(appearance), "a bar in the look is frosted once content runs under it")
            }
            // [desktop-top-bar] Owner 2026-11-05 (Messaging): a pushed page's bar at rest is clear, the page itself; the
            // frost there drew a lighter band with the first card against it. (A sheet's stays opaque: ThemeChromeSheetTests.)
            for appearance in [bar.scrollEdgeAppearance, bar.compactScrollEdgeAppearance] {
                let color = appearance?.backgroundColor?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
                #expect(appearance?.backgroundEffect == nil && (color?.cgColor.alpha ?? 0) == 0, "clear at rest")
            }
            window.isHidden = true
        }
    }

    @Test func theFrostIsABlurNotGlassAndStaysThroughTheGlassSweep() {
        ThemeTable.$testSet.withValue(set(look: true)) {
            let band = DesktopFrostView(frame: CGRect(x: 0, y: 0, width: 400, height: 120))
            band.color = ChatPalette.page
            band.fade = .bottom
            band.layoutIfNeeded()
            #expect(band.effectView.effect is UIBlurEffect)
            #expect(!(band.effectView.effect is UIGlassEffect))
            ThemeChrome.restyleGlass(in: band)
            #expect(band.effectView.effect is UIBlurEffect, "the glass sweep leaves a plain blur alone")
            let tint = band.subviews.first { $0 !== band.effectView }?.backgroundColor?
                .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor.alpha ?? 1
            #expect(tint > 0 && tint < 1, "translucent: the content shows through")
            #expect(band.layer.mask != nil, "fades toward the content")
        }
    }

    @Test func theJumpIsAFlatRoundButtonInTheLookAndTheGlassCircleOffIt() {
        let jump = JumpButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        ThemeTable.$testSet.withValue(set(look: true)) {
            jump.applyLook()
            #expect(jump.preferredWidth == ChatMetrics.jumpSize && jump.preferredHeight == ChatMetrics.jumpSize, "44 pt tap area")
            jump.layoutIfNeeded()
            let circle = jump.flatCircleFrame
            #expect(circle.width == JumpButton.desktopDiameter && circle.height == JumpButton.desktopDiameter)
            #expect(abs(circle.midX - 22) < 0.5 && abs(circle.midY - 22) < 0.5, "centred in the tap area")
            #expect(!Self.hasGlass(jump), "no Liquid Glass showing in the look")
            jump.setApproval(true)
            #expect(jump.accessibilityLabel == "Approval needed")
            #expect(jump.preferredWidth > ChatMetrics.jumpSize, "a flat capsule around \"Approval needed\"")
            jump.frame.size.width = jump.preferredWidth
            jump.layoutIfNeeded()
            #expect(jump.flatCircleFrame.width > JumpButton.desktopDiameter && jump.flatCircleFrame.height == JumpButton.desktopDiameter)
            #expect(!Self.hasGlass(jump), "still no Liquid Glass")
            jump.setApproval(false)
            #expect(jump.preferredWidth == ChatMetrics.jumpSize, "the plain jump is the round button again")
        }
        ThemeTable.$testSet.withValue(set(look: false)) {
            jump.applyLook()
            #expect(jump.preferredWidth == ChatMetrics.jumpSize)
            #expect(Self.hasGlass(jump), "the glass circle off the look")
        }
    }

    /// A shown glass panel inside the view.
    private static func hasGlass(_ view: UIView) -> Bool {
        if let fx = view as? UIVisualEffectView, fx.effect is UIGlassEffect, !fx.isHidden { return true }
        return view.subviews.contains { !$0.isHidden && hasGlass($0) }
    }
}
