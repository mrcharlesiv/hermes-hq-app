// desktoplook2: the Desktop Look's layout helpers. Each test runs in its own theme through `ThemeTable.$testSet`.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

private func set(look: Bool, scale: Int = 100) -> ThemeSet {
    ThemeResolver.resolve(ThemeState(skinID: "midnight", desktopLook: look, highContrast: false, uiScalePercent: scale))
}

@MainActor @Suite struct DesktopLayoutTests {
    @Test func rowsAreSixtyWithThirtyTwoFacesAndFollowUIScale() {
        ThemeTable.$testSet.withValue(set(look: true)) {
            #expect(DesktopRows.height == 60)
            #expect(DesktopRows.face == 32)
        }
        ThemeTable.$testSet.withValue(set(look: true, scale: 150)) {
            #expect(DesktopRows.height == 90)
            #expect(DesktopRows.face == 48)
        }
    }

    @Test func aPressIsAFlatRoundedInsetBoxAndRestIsClear() {
        ThemeTable.$testSet.withValue(set(look: true)) {
            var state = UICellConfigurationState(traitCollection: UITraitCollection())
            let rest = DesktopLayout.rowBackground(state)
            #expect(rest.backgroundColor == .clear || rest.backgroundColor == nil)
            state.isHighlighted = true
            let pressed = DesktopLayout.rowBackground(state)
            #expect(pressed.cornerRadius == 4)
            #expect(pressed.backgroundInsets == NSDirectionalEdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            #expect(pressed.backgroundColor != nil && pressed.backgroundColor != .clear)
        }
    }

    @Test func theLiftHasNoShadow() {
        let parameters = DesktopLayout.liftParameters(for: CGRect(x: 0, y: 0, width: 300, height: 60))
        #expect(parameters.shadowPath?.isEmpty == true)
        #expect(parameters.visiblePath?.bounds == CGRect(x: 8, y: 0, width: 284, height: 60))
    }

    @Test func theLabelIsTrackedSemibold() {
        ThemeTable.$testSet.withValue(set(look: true)) {
            let attributes = DesktopLayout.labelAttributes(size: 11)
            let font = attributes[.font] as? UIFont
            let kern = attributes[.kern] as? CGFloat
            #expect(font != nil)
            #expect(abs((kern ?? 0) - (font?.pointSize ?? 0) * 0.08) < 0.001)
        }
    }

    @Test func uikitButtonsAreGlassWithTheLookOffAndOutlinedWithItOn() {
        ThemeTable.$testSet.withValue(set(look: false)) {
            #expect(UIButton.Configuration.hqGlass().background.strokeWidth == UIButton.Configuration.glass().background.strokeWidth)
            #expect(UIButton.Configuration.hqGlass().cornerStyle == UIButton.Configuration.glass().cornerStyle)
        }
        ThemeTable.$testSet.withValue(set(look: true)) {
            let outlined = UIButton.Configuration.hqGlass()
            #expect(outlined.background.strokeWidth == 1)
            #expect(outlined.background.cornerRadius == 4)
            #expect(UIButton.Configuration.hqProminentGlass().background.cornerRadius == 4)
        }
    }

    @Test func segmentsAreOutlinedOnlyInTheLook() {
        let control = UISegmentedControl(items: ["Head", "Upload"])
        DesktopSegments.apply(control, desktop: true)
        #expect(control.backgroundImage(for: .normal, barMetrics: .default) != nil)
        #expect(control.backgroundImage(for: .selected, barMetrics: .default) != nil)
        DesktopSegments.apply(control, desktop: false)
        #expect(control.backgroundImage(for: .normal, barMetrics: .default) == nil)
        #expect(control.dividerImage(forLeftSegmentState: .normal, rightSegmentState: .normal, barMetrics: .default) == nil)
    }

    // A skin with one look pins the windows to it and the Appearance row says so; other skins give the choice back.
    @Test func aOneLookSkinForcesTheWindowsAndTheAppearanceRowSaysSo() {
        let midnight = ThemeResolver.resolve(ThemeState(skinID: "midnight", desktopLook: true))
        ThemeTable.$testSet.withValue(midnight) {
            #expect(AppearanceSetting.forcedBySkin == .dark)
            #expect(AppearanceSetting.shown == .dark)
            for chosen in [UIUserInterfaceStyle.unspecified, .light, .dark] {
                #expect(Theme.shared.style(for: chosen) == .dark, "light or system, Midnight is dark")
            }
        }
        let github = ThemeResolver.resolve(ThemeState(skinID: "github", desktopLook: true))
        ThemeTable.$testSet.withValue(github) {
            #expect(AppearanceSetting.forcedBySkin == nil)
            #expect(Theme.shared.style(for: .light) == .light, "the person's choice comes back")
            #expect(Theme.shared.style(for: .unspecified) == .unspecified)
        }
        #expect(AppearanceSetting.forced(by: false) == .light)
    }
}
