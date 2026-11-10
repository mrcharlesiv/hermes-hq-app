// desktop-glass-sweep: no scroll edge blur in the Desktop Look (App/Theme/DesktopEdges.swift). A list's edges are
// hidden as it joins a window, stay hidden when UIKit or SwiftUI shows them again, and come back with the look off;
// a list whose screen sets its own edges (the chat) is left to it.

import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct DesktopEdgesTests {
    private func edges(_ scroll: UIScrollView) -> [Bool] {
        [scroll.topEdgeEffect, scroll.bottomEdgeEffect, scroll.leftEdgeEffect, scroll.rightEdgeEffect].map(\.isHidden)
    }

    private func windowed(_ scroll: UIScrollView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        scroll.frame = window.bounds
        window.addSubview(scroll)
        return window
    }

    @Test func aListJoiningAWindowInTheLookHasNoEdgesAndKeepsNone() {
        DesktopEdges.install()
        defer { DesktopEdges.on = false }
        let scroll = UIScrollView()
        let window = windowed(scroll)
        #expect(edges(scroll) == [true, true, true, true])
        scroll.topEdgeEffect.isHidden = false                  // the bars (or SwiftUI) show it again
        #expect(scroll.topEdgeEffect.isHidden, "held hidden while the look is on")
        DesktopEdges.apply(in: window, desktop: false)
        #expect(edges(scroll) == [false, false, false, false], "the look off: the system's edges again")
        scroll.topEdgeEffect.isHidden = true                   // the look off: the app's own choices stand
        scroll.topEdgeEffect.isHidden = false
        #expect(!scroll.topEdgeEffect.isHidden)
    }

    @Test func aListAlreadyUpIsJudgedWhenItLaysOut() {
        DesktopEdges.on = false
        let scroll = UIScrollView()
        let window = windowed(scroll)
        #expect(edges(scroll) == [false, false, false, false], "joined before the look")
        DesktopEdges.install()
        defer { DesktopEdges.on = false }
        scroll.setNeedsLayout()
        scroll.layoutIfNeeded()
        #expect(edges(scroll) == [true, true, true, true])
        DesktopEdges.apply(in: window, desktop: false)
    }

    @Test func aListThatSetsItsOwnEdgesIsLeftAlone() {
        DesktopEdges.install()
        defer { DesktopEdges.on = false }
        let scroll = UIScrollView()
        DesktopEdges.leaveAlone(scroll)
        let window = windowed(scroll)
        #expect(edges(scroll) == [false, false, false, false])
        DesktopEdges.apply(in: window, desktop: true)
        #expect(edges(scroll) == [false, false, false, false])
        DesktopEdges.apply(in: window, desktop: false)
    }
}
