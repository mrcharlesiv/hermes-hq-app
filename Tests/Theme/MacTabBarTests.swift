// [mac] The tab bar on the Mac (owner 2026-10-24, "I also don't like placement of the menu at the top"): the app draws
// its own bar at the bottom of the list in every look there, a glass capsule in the iOS look and the Desktop Look's
// docked bar in that look; the iPhone and iPad keep the system's bar outside the Desktop Look.

import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite struct MacTabBarTests {
    @Test func whichBarEachPlatformAndLookUses() {
        #expect(DesktopTabBar.style(desktopLook: false, mac: false) == nil)            // iPhone, iPad: the system bar
        #expect(DesktopTabBar.style(desktopLook: true, mac: false) == .desktop)
        // Owner 2026-10-25: no pills at the bottom on the Mac. The window's sidebar lists the tabs in either look.
        #expect(DesktopTabBar.style(desktopLook: false, mac: true) == .sidebar)
        #expect(DesktopTabBar.style(desktopLook: true, mac: true) == .sidebar)
        #expect(DesktopTabBar.Style.sidebar.height == 0)
        #expect(!DesktopTabBar.onMac)                                                  // the tests run on the iPhone
        #expect(DesktopTabBar.wanted == (Theme.isDesktop ? .desktop : nil))
    }

    @Test func roomChildrenKeepClear() {
        #expect(DesktopTabBar.Style.desktop.height == 50)
        #expect(DesktopTabBar.Style.glass.height == 72)                                // the system bar on macOS 27
    }

    /// The system bar on macOS 27 in a 440-wide column: a 420-wide capsule, 96-wide tabs centred 79 apart.
    @Test func glassTabsSitWhereTheSystemsDid() {
        let (pill, centres) = DesktopTabBar.Glass.layout(width: 420, count: 5)
        #expect(pill == 96)
        #expect(centres.map { $0.rounded() } == [52, 131, 210, 289, 368])
    }

    @Test func aNarrowColumnNarrowsTheTabs() {
        let (pill, centres) = DesktopTabBar.Glass.layout(width: 300, count: 5)
        #expect(pill < 96)
        #expect(centres.first! - pill / 2 >= DesktopTabBar.Glass.inset - 0.01)
        #expect(centres.last! + pill / 2 <= 300 - DesktopTabBar.Glass.inset + 0.01)
        #expect(zip(centres, centres.dropFirst()).allSatisfy { $1 - $0 >= 50 })        // "Artifacts" beside "More" still fits
        #expect(DesktopTabBar.Glass.layout(width: 420, count: 0).centres.isEmpty)
    }

    private func host() -> UITabBarController {
        let tabs = UITabBarController()
        let titles = ["Bots", "Sessions", "Jobs", "Artifacts", "More"]
        tabs.viewControllers = titles.enumerated().map { index, title in
            let navigation = UINavigationController(rootViewController: UIViewController())
            navigation.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: "circle"), tag: index)
            navigation.tabBarItem.accessibilityIdentifier = "tab-\(title.lowercased())"
            return navigation
        }
        tabs.loadViewIfNeeded()
        tabs.view.frame = CGRect(x: 0, y: 0, width: 440, height: 900)
        return tabs
    }

    private func buttons(_ bar: UIView) -> [UIControl] {
        func walk(_ view: UIView) -> [UIControl] {
            ((view as? UIControl).map { [$0] } ?? []) + view.subviews.flatMap(walk)
        }
        return walk(bar).filter { $0.accessibilityIdentifier?.hasPrefix("tab-") == true }
    }

    @Test func theGlassBarStandsInForTheSystemsAndMovesBetweenLooks() {
        let tabs = host()
        tabs.viewControllers?[1].tabBarItem.badgeValue = "3"
        let bar = DesktopTabBar(host: tabs)
        bar.sync(wanted: .glass)
        tabs.view.layoutIfNeeded()
        #expect(bar.superview === tabs.view)
        #expect(tabs.isTabBarHidden)
        #expect(bar.accessibilityIdentifier == "mac-tab-bar")
        #expect(bar.accessibilityTraits.contains(.tabBar))
        #expect(tabs.viewControllers?.allSatisfy { $0.additionalSafeAreaInsets.bottom == 72 } == true)
        let glass = buttons(bar)
        #expect(glass.map(\.accessibilityIdentifier) == ["tab-bots", "tab-sessions", "tab-jobs", "tab-artifacts", "tab-more"])
        #expect(glass[0].accessibilityTraits.contains(.selected) && !glass[1].accessibilityTraits.contains(.selected))
        #expect(glass[1].accessibilityValue == "3 new")
        #expect(glass.allSatisfy { $0.showsLargeContentViewer })
        // Only the capsule takes clicks; the list answers beside and above it.
        #expect(bar.frame.height == 72)
        #expect(!bar.point(inside: CGPoint(x: 3, y: 30), with: nil))
        #expect(bar.point(inside: CGPoint(x: 220, y: 30), with: nil))
        #expect(!bar.point(inside: CGPoint(x: 220, y: 68), with: nil))

        // The tabs follow the selection made elsewhere (⌘2), and a page that hides the bar takes the whole column.
        tabs.selectedIndex = 1
        bar.selectionChanged()
        #expect(glass[1].accessibilityTraits.contains(.selected) && !glass[0].accessibilityTraits.contains(.selected))
        let sessions = tabs.viewControllers![1] as! UINavigationController
        let chat = UIViewController()
        chat.hidesBottomBarWhenPushed = true
        sessions.pushViewController(chat, animated: false)
        bar.navigationDidShow(in: sessions)
        #expect(bar.coveredByPage)
        #expect(sessions.additionalSafeAreaInsets.bottom == 0)
        sessions.popToRootViewController(animated: false)
        bar.navigationDidShow(in: sessions)
        #expect(!bar.coveredByPage)
        #expect(sessions.additionalSafeAreaInsets.bottom == 72)

        // Desktop Look on (Settings › Appearance, live): the same bar, docked and plain.
        bar.sync(wanted: .desktop)
        tabs.view.layoutIfNeeded()
        #expect(bar.accessibilityIdentifier == "desktop-tab-bar")
        #expect(bar.frame.height == 50)
        #expect(tabs.viewControllers?.allSatisfy { $0.additionalSafeAreaInsets.bottom == 50 } == true)
        #expect(buttons(bar).count == 5)
        #expect(bar.point(inside: CGPoint(x: 3, y: 30), with: nil))

        // And back: glass again, never the system bar.
        bar.sync(wanted: .glass)
        tabs.view.layoutIfNeeded()
        #expect(tabs.isTabBarHidden)
        #expect(buttons(bar).count == 5)
        #expect(tabs.viewControllers?.allSatisfy { $0.additionalSafeAreaInsets.bottom == 72 } == true)

        // Off the Mac with the look off: the system's bar comes back.
        bar.sync(wanted: nil)
        #expect(bar.superview == nil)
        #expect(!tabs.isTabBarHidden)
        #expect(tabs.viewControllers?.allSatisfy { $0.additionalSafeAreaInsets.bottom == 0 } == true)
    }

    /// [mac] The sidebar takes the tabs: no bar of the app's own over the list, no system bar, no room kept for one.
    @Test func theSidebarLeavesTheListColumnBare() {
        let tabs = host()
        let bar = DesktopTabBar(host: tabs)
        bar.sync(wanted: .glass)
        #expect(bar.superview === tabs.view)
        bar.sync(wanted: .sidebar)
        #expect(bar.superview == nil)
        #expect(tabs.isTabBarHidden)
        #expect(tabs.viewControllers?.allSatisfy { $0.additionalSafeAreaInsets.bottom == 0 } == true)
        // A pick from the sidebar is the system bar's: the tab changes, and a second pick goes back to its root.
        #expect(DesktopTabBar.select(2, in: tabs) === tabs.viewControllers?[2])
        #expect(tabs.selectedIndex == 2)
        let jobs = tabs.viewControllers![2] as! UINavigationController
        jobs.pushViewController(UIViewController(), animated: false)
        DesktopTabBar.select(2, in: tabs, animated: false)   // a test's pop can't wait for the slide
        #expect(jobs.viewControllers.count == 1)
    }

    @Test func aNewSetOfTabsRebuildsTheBar() {
        let tabs = host()
        let bar = DesktopTabBar(host: tabs)
        bar.sync(wanted: .glass)
        tabs.viewControllers = Array(tabs.viewControllers!.prefix(3)) + [UINavigationController(rootViewController: UIViewController())]
        bar.sync(wanted: .glass)
        func controls(_ view: UIView) -> Int { (view is UIControl ? 1 : 0) + view.subviews.map(controls).reduce(0, +) }
        #expect(controls(bar) == 4)
    }

    @Test func theUndoPillSitsOverTheGlassBar() {
        let tabs = host()
        let bar = DesktopTabBar(host: tabs)
        bar.sync(wanted: .glass)
        let pill = UndoPill.show(label: "Deleted “Garden plan”", in: tabs.viewControllers?.first) {}
        tabs.view.layoutIfNeeded()
        #expect((pill?.frame.maxY ?? 900) <= bar.frame.minY - 7, "\(String(describing: pill?.frame)) vs \(bar.frame)")
        pill?.dismiss(animated: false)
    }
}
