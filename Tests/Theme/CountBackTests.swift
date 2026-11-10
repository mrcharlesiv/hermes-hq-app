// 2026-10-30 (owner: the "‹ 2" Back had "too much padding inside it"): a count's Back is a fitted button in both looks;
// a named Back, or none, stays the system's.

import Testing
import UIKit
@testable import HermesHQNative

private func set(look: Bool) -> ThemeSet {
    ThemeResolver.resolve(ThemeState(skinID: "ios", desktopLook: look, highContrast: false, uiScalePercent: 100))
}

@MainActor private func stack(back title: String?) -> (UINavigationController, UIViewController) {
    DesktopBars.install()
    let root = UIViewController()
    root.title = "Bots"
    root.navigationItem.backButtonTitle = title
    let page = UIViewController()
    let navigation = UINavigationController(rootViewController: root)
    navigation.pushViewController(page, animated: false)
    return (navigation, page)
}

@MainActor @Suite struct CountBackTests {
    @Test func aCountIsAFittedButtonOnTheGlass() {
        let (navigation, page) = stack(back: "2")
        ThemeTable.$testSet.withValue(set(look: false)) {
            DesktopBack.applyBacks(navigation.navigationBar)
            let back = DesktopBack.standIn(of: page.navigationItem)
            let button = back?.customView as? CountBackButton
            #expect(button?.configuration?.title == "2")
            #expect(back?.hidesSharedBackground == false, "the iOS look's glass")
            #expect(page.navigationItem.hidesBackButton, "the system Back is hidden under it")
            #expect(back?.accessibilityLabel == "Back, 2")
            #expect(button?.menu != nil, "a long press lists the pages under it")
            let width = button?.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width ?? 0
            #expect(width < 60, "fitted: the system's was 82 pt with its glass")
        }
    }

    @Test func theCountGoingAwayGivesTheSystemBackBack() {
        let (navigation, page) = stack(back: "3")
        ThemeTable.$testSet.withValue(set(look: false)) {
            DesktopBack.applyBacks(navigation.navigationBar)
            #expect(DesktopBack.standIn(of: page.navigationItem) != nil)
            navigation.viewControllers[0].navigationItem.backButtonTitle = nil
            DesktopBack.applyBacks(navigation.navigationBar)
            #expect(DesktopBack.standIn(of: page.navigationItem) == nil)
            #expect(page.navigationItem.leftBarButtonItems?.isEmpty ?? true)
            #expect(!page.navigationItem.hidesBackButton)
        }
    }

    @Test func aNamedBackStaysTheSystems() {
        let (navigation, page) = stack(back: "Sessions")
        ThemeTable.$testSet.withValue(set(look: false)) {
            DesktopBack.applyBacks(navigation.navigationBar)
            #expect(DesktopBack.standIn(of: page.navigationItem) == nil)
        }
    }

    @Test func theDesktopLookShowsTheCountFlat() {
        let (navigation, page) = stack(back: "12")
        ThemeTable.$testSet.withValue(set(look: true)) {
            DesktopBars.apply(navigation.navigationBar, desktop: true)
            let back = DesktopBack.standIn(of: page.navigationItem)
            #expect((back?.customView as? CountBackButton)?.configuration?.title == "12", "the look drew no count before")
            #expect(back?.hidesSharedBackground == true)
        }
        ThemeTable.$testSet.withValue(set(look: false)) {
            DesktopBars.apply(navigation.navigationBar, desktop: false)
            #expect(DesktopBack.standIn(of: page.navigationItem)?.hidesSharedBackground == false, "glass again off the look")
        }
    }

    @Test func onlyCountsCount() {
        #expect(DesktopBack.isCount("2"))
        #expect(DesktopBack.isCount("99+"))
        #expect(!DesktopBack.isCount("Bots"))
        #expect(!DesktopBack.isCount(""))
        #expect(!DesktopBack.isCount(nil))
    }
}
