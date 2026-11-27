import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite struct TabBadgeLayoutTests {
    /// Exhaustive sweep across every phone width (SE/mini through Pro Max), 1–5 tabs, narrow through wide icons
    /// (More, Tasks, Bots, Sessions), and 1–3+ digit badges ("1", "12", "99+"). Every badge must stay clear of
    /// neighbouring selection pills, inside its own selection pill when selected, and inside the outer capsule.
    @Test func geometryClearsAdjacentPillsAndFitsOwnPillAcrossAllScenarios() {
        let screenWidths: [CGFloat] = [375, 390, 393, 402, 430, 440]
        let tabCounts = [1, 2, 3, 4, 5]
        let iconWidths: [CGFloat] = [22, 26, 29, 35]
        let badgeWidths: [CGFloat] = [18, 23, 30]   // "1", "12", "99+"

        for screenWidth in screenWidths {
            let capsuleWidth = screenWidth - 42
            let capsule = CGRect(x: 21, y: 0, width: capsuleWidth, height: 62)
            let room = capsuleWidth - 8
            for count in tabCounts {
                let pillWidth = min(96, room / CGFloat(count) + 8)
                let step: CGFloat = count > 1 ? (room - pillWidth) / CGFloat(count - 1) : 0
                let pills = (0..<count).map { index -> CGRect in
                    let centre = count > 1 ? 21 + 4 + pillWidth / 2 + step * CGFloat(index) : 21 + capsuleWidth / 2
                    return CGRect(x: centre - pillWidth / 2, y: 4, width: pillWidth, height: 54)
                }

                for index in 0..<count {
                    let pill = pills[index]
                    let prev = index > 0 ? pills[index - 1] : nil
                    let next = index + 1 < count ? pills[index + 1] : nil
                    for iconWidth in iconWidths {
                        let icon = CGRect(x: pill.midX - iconWidth / 2, y: pill.minY + 8, width: iconWidth, height: 24)
                        let slot = TabBadgeLayout.Slot(icon: icon, pill: pill, prevPill: prev, nextPill: next, capsule: capsule)
                        for badgeWidth in badgeWidths {
                            let badge = TabBadgeLayout.frame(for: slot, badgeSize: CGSize(width: badgeWidth, height: TabBadgeLayout.badgeHeight))

                            // Must stay strictly inside its own selection pill with at least ownPillInset clearance.
                            let ownInset = TabBadgeLayout.inset(of: badge, inside: pill)
                            #expect(
                                ownInset >= TabBadgeLayout.ownPillInset - 0.05,
                                "screen=\(screenWidth) tabs=\(count) i=\(index) iconW=\(iconWidth) badgeW=\(badgeWidth): ownInset=\(ownInset)"
                            )

                            // Must stay strictly inside the outer bar capsule.
                            let capInset = TabBadgeLayout.inset(of: badge, inside: capsule)
                            #expect(
                                capInset >= TabBadgeLayout.capsuleInset - 0.05,
                                "screen=\(screenWidth) tabs=\(count) i=\(index) iconW=\(iconWidth) badgeW=\(badgeWidth): capInset=\(capInset)"
                            )

                            // Must stay at least neighborGap clear of the right neighbour's selection pill.
                            if let next {
                                let clearRight = TabBadgeLayout.clearance(of: badge, fromRightPill: next)
                                #expect(
                                    clearRight >= TabBadgeLayout.neighborGap - 0.05,
                                    "screen=\(screenWidth) tabs=\(count) i=\(index) iconW=\(iconWidth) badgeW=\(badgeWidth): clearRight=\(clearRight)"
                                )
                            }

                            // Must stay at least neighborGap clear of the left neighbour's selection pill.
                            if let prev {
                                // Mirror horizontally around x = 0 to reuse clearance(fromRightPill:).
                                let mirroredBadge = CGRect(x: -badge.maxX, y: badge.minY, width: badge.width, height: badge.height)
                                let mirroredPrev = CGRect(x: -prev.maxX, y: prev.minY, width: prev.width, height: prev.height)
                                let clearLeft = TabBadgeLayout.clearance(of: mirroredBadge, fromRightPill: mirroredPrev)
                                #expect(
                                    clearLeft >= TabBadgeLayout.neighborGap - 0.05,
                                    "screen=\(screenWidth) tabs=\(count) i=\(index) iconW=\(iconWidth) badgeW=\(badgeWidth): clearLeft=\(clearLeft)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// Multi-digit badges on a wide icon next to a selected tab grow inward (leftward) rather than spilling into the
    /// neighbouring tab's selection pill.
    @Test func wideBadgesGrowInwardInsteadOfCrossingIntoNeighborPill() {
        let capsule = CGRect(x: 21, y: 0, width: 360, height: 62)
        let pill1 = CGRect(x: 93, y: 4, width: 78, height: 54)
        let pill2 = CGRect(x: 161.5, y: 4, width: 78, height: 54)
        let sessionsIcon = CGRect(x: pill1.midX - 17.5, y: pill1.minY + 8, width: 35, height: 26)
        let slot = TabBadgeLayout.Slot(icon: sessionsIcon, pill: pill1, prevPill: nil, nextPill: pill2, capsule: capsule)

        let one = TabBadgeLayout.frame(for: slot, badgeSize: CGSize(width: 18, height: 18))
        let twelve = TabBadgeLayout.frame(for: slot, badgeSize: CGSize(width: 23, height: 18))
        let ninetyNinePlus = TabBadgeLayout.frame(for: slot, badgeSize: CGSize(width: 30, height: 18))

        // Right edge stays clamped at the safe boundary; left edge expands inward.
        #expect(abs(one.maxX - twelve.maxX) < 0.05)
        #expect(abs(twelve.maxX - ninetyNinePlus.maxX) < 0.05)
        #expect(ninetyNinePlus.minX < twelve.minX && twelve.minX < one.minX)
        #expect(TabBadgeLayout.clearance(of: ninetyNinePlus, fromRightPill: pill2) >= TabBadgeLayout.neighborGap - 0.05)
    }

    /// Real `UITabBar` + `TabBadgeOverlay` in a live `UIWindow` across narrow and standard phone widths, 5 tabs, and
    /// 1 / 2 / 3-char badges, verifying actual UIKit button & icon rects match our clearances.
    @Test func liveSystemTabBarOverlayClearsNeighborSelectionPill() throws {
        for screenWidth in [375, 390, 402, 440] as [CGFloat] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: screenWidth, height: 852))
            let tabs = UITabBarController()
            let specs: [(String, UIImage?)] = [
                ("Bots", TabIcons.bot),
                ("Sessions", TabIcons.barSymbol("bubble.left.and.bubble.right")),
                ("Tasks", TabIcons.barSymbol("checklist")),
                ("Tiles", TabIcons.barSymbol("square.grid.2x2")),
                ("More", TabIcons.barSymbol("ellipsis.circle", outline: "ellipsis")),
            ]
            tabs.viewControllers = specs.enumerated().map { index, spec in
                let vc = UIViewController()
                vc.tabBarItem = UITabBarItem(title: spec.0, image: spec.1, tag: index)
                return vc
            }
            tabs.selectedIndex = 2   // Tasks selected, right beside Sessions
            let overlay = TabBadgeOverlay(bar: tabs.tabBar)
            tabs.tabBar.addSubview(overlay)
            window.rootViewController = tabs
            window.isHidden = false
            window.layoutIfNeeded()
            tabs.tabBar.layoutIfNeeded()
            overlay.refresh()

            defer {
                window.rootViewController = nil
                window.isHidden = true
            }

            // Dump real measured slots so test output records UIKit's exact geometry.
            #expect(overlay.slots.count == 5, "width=\(screenWidth): expected 5 measured slots, got \(overlay.slots.count)")

            for badgeText in ["1", "12", "99+"] {
                tabs.viewControllers?[0].tabBarItem.badgeValue = badgeText
                tabs.viewControllers?[1].tabBarItem.badgeValue = badgeText
                tabs.viewControllers?[4].tabBarItem.badgeValue = badgeText
                overlay.refresh()

                let frames = overlay.badgeFramesForTests
                for index in [0, 1, 4] {
                    let frame = try #require(frames[index], "width=\(screenWidth) text=\(badgeText) tab=\(index) missing badge")
                    let slot = overlay.slots[index]
                    #expect(
                        TabBadgeLayout.inset(of: frame, inside: slot.pill) >= TabBadgeLayout.ownPillInset - 0.1,
                        "width=\(screenWidth) text=\(badgeText) tab=\(index): frame=\(frame) pill=\(slot.pill)"
                    )
                    if let nextPill = slot.nextPill {
                        #expect(
                            TabBadgeLayout.clearance(of: frame, fromRightPill: nextPill) >= TabBadgeLayout.neighborGap - 0.1,
                            "width=\(screenWidth) text=\(badgeText) tab=\(index): frame=\(frame) nextPill=\(nextPill)"
                        )
                    }
                }
            }
        }
    }

    /// `DesktopTabBar` in `.glass` mode (e.g. PaperSolid on iPhone and narrow columns) clamps badges clear of
    /// neighbouring pills too.
    @Test func desktopTabBarGlassBadgesClearNeighborPills() throws {
        for width in [375, 402, 440] as [CGFloat] {
            let tabs = UITabBarController()
            let icons: [(String, UIImage?)] = [
                ("Bots", TabIcons.bot),
                ("Sessions", TabIcons.barSymbol("bubble.left.and.bubble.right")),
                ("Tasks", TabIcons.barSymbol("checklist")),
                ("Tiles", TabIcons.barSymbol("square.grid.2x2")),
                ("More", TabIcons.barSymbol("ellipsis.circle", outline: "ellipsis")),
            ]
            tabs.viewControllers = icons.enumerated().map { index, spec in
                let nav = UINavigationController(rootViewController: UIViewController())
                nav.tabBarItem = UITabBarItem(title: spec.0, image: spec.1, tag: index)
                return nav
            }
            tabs.selectedIndex = 2
            tabs.loadViewIfNeeded()
            tabs.view.frame = CGRect(x: 0, y: 0, width: width, height: 852)
            let bar = DesktopTabBar(host: tabs)
            bar.sync(wanted: .glass)

            for text in ["1", "12", "99+"] {
                tabs.viewControllers?[1].tabBarItem.badgeValue = text
                tabs.view.setNeedsLayout()
                tabs.view.layoutIfNeeded()
                bar.setNeedsLayout()
                bar.layoutIfNeeded()

                let capsuleWidth = width - DesktopTabBar.Glass.margin * 2
                let (pillWidth, centres) = DesktopTabBar.Glass.layout(width: capsuleWidth, count: 5)
                let tasksPill = CGRect(
                    x: DesktopTabBar.Glass.margin + centres[2] - pillWidth / 2,
                    y: DesktopTabBar.Glass.inset,
                    width: pillWidth,
                    height: DesktopTabBar.Glass.buttonHeight
                )
                let sessionsPill = CGRect(
                    x: DesktopTabBar.Glass.margin + centres[1] - pillWidth / 2,
                    y: DesktopTabBar.Glass.inset,
                    width: pillWidth,
                    height: DesktopTabBar.Glass.buttonHeight
                )
                let badgeLabel = try #require(findLabel(withText: text, in: bar), "width=\(width) text=\(text)")
                let badgeInBar = badgeLabel.convert(badgeLabel.bounds, to: bar)
                #expect(
                    TabBadgeLayout.clearance(of: badgeInBar, fromRightPill: tasksPill) >= TabBadgeLayout.neighborGap - 0.1,
                    "glass bar width=\(width) text=\(text): badge=\(badgeInBar) tasksPill=\(tasksPill)"
                )
                #expect(
                    TabBadgeLayout.inset(of: badgeInBar, inside: sessionsPill) >= TabBadgeLayout.ownPillInset - 0.1,
                    "glass bar width=\(width) text=\(text): badge=\(badgeInBar) sessionsPill=\(sessionsPill)"
                )
            }
        }
    }

    /// `DesktopTabBar` in `.desktop` (docked) mode keeps wide badges ("99+") at least 4 pt inside each tab slot even
    /// on narrow 375 pt 5-tab screens.
    @Test func desktopTabBarDockedBadgesStayInsideSlotBounds() throws {
        let tabs = UITabBarController()
        let icons: [(String, UIImage?)] = [
            ("Bots", TabIcons.bot),
            ("Sessions", TabIcons.barSymbol("bubble.left.and.bubble.right")),
            ("Tasks", TabIcons.barSymbol("checklist")),
            ("Tiles", TabIcons.barSymbol("square.grid.2x2")),
            ("More", TabIcons.barSymbol("ellipsis.circle", outline: "ellipsis")),
        ]
        tabs.viewControllers = icons.enumerated().map { index, spec in
            let nav = UINavigationController(rootViewController: UIViewController())
            nav.tabBarItem = UITabBarItem(title: spec.0, image: spec.1, tag: index)
            return nav
        }
        tabs.loadViewIfNeeded()
        tabs.view.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        let bar = DesktopTabBar(host: tabs)
        bar.sync(wanted: .desktop)
        tabs.viewControllers?[1].tabBarItem.badgeValue = "99+"
        tabs.viewControllers?[4].tabBarItem.badgeValue = "99+"
        tabs.view.layoutIfNeeded()
        bar.layoutIfNeeded()

        let controls = allControls(in: bar)
        #expect(controls.count == 5)
        for index in [1, 4] {
            let button = controls[index]
            let badge = try #require(findLabel(withText: "99+", in: button), "tab \(index) missing docked badge")
            #expect(badge.frame.minX >= 3.9, "tab \(index) docked badge left overflow: \(badge.frame) in \(button.bounds)")
            #expect(badge.frame.maxX <= button.bounds.width - 3.9, "tab \(index) docked badge right overflow: \(badge.frame) in \(button.bounds)")
        }
    }

    private func allControls(in view: UIView) -> [UIControl] {
        ((view as? UIControl).map { [$0] } ?? []) + view.subviews.flatMap(allControls(in:))
    }

    private func findLabel(withText text: String, in view: UIView) -> UILabel? {
        if let label = view as? UILabel, !label.isHidden, label.text == text { return label }
        for child in view.subviews {
            if let found = findLabel(withText: text, in: child) { return found }
        }
        return nil
    }
}
