// Haptics at the places the 2026-11-11 pass filled in (owner: "We don't have Taptic feedback in every place that it
// needs to be"). Each test is synchronous on the main actor, so no other test's cue can land in its sink.

import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite struct HapticsPlacesTests {
    /// Runs `body` with the switch on and every cue recorded; gives back what played.
    private func heard(_ body: () -> Void) -> [Haptics.Kind] {
        let before = UserDefaults.standard.object(forKey: Haptics.key)
        let oldSink = Haptics.sink
        defer {
            Haptics.sink = oldSink
            if let before { UserDefaults.standard.set(before, forKey: Haptics.key) } else { UserDefaults.standard.removeObject(forKey: Haptics.key) }
        }
        UserDefaults.standard.removeObject(forKey: Haptics.key)
        var cues: [Haptics.Kind] = []
        Haptics.sink = { cues.append($0) }
        body()
        return cues
    }

    private func buttons(in view: UIView) -> [UIButton] {
        if let button = view as? UIButton { return [button] }
        return view.subviews.flatMap(buttons)
    }

    /// The Undo pill's Undo: a light tap once, then nothing for a second press while it fades.
    @Test func undoTapsOnce() {
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var undone = 0
        let cues = heard {
            let pill = UndoPill.show(label: "Hidden", in: host) { undone += 1 }
            let undo = pill.flatMap { buttons(in: $0).first { !$0.isHidden } }
            #expect(undo != nil)
            undo?.sendActions(for: .primaryActionTriggered)
            undo?.sendActions(for: .primaryActionTriggered)
        }
        #expect(undone == 1)
        #expect(cues == [.light])
    }

    /// A tile held over the Dashboard's page names: one tick each time a new name lights, none as it goes dark.
    @Test func pageNamesTickAsATileCrossesThem() {
        let bar = DashboardPagesBar(frame: .zero)
        let cues = heard {
            bar.highlight("home")
            bar.highlight("home")   // the finger moved within the same name
            bar.highlight(nil)
            bar.highlight("work")
            bar.highlight(nil)
        }
        #expect(cues == [.selection, .selection])
    }

    /// The tab bar at the foot (owner 2026-11-11): every tap ticks once, a second tap of the tab on show too. The system
    /// bar's tick plays only while it is the bar on show, so a pick on the app's own bar never ticks twice.
    @Test func tabBarTapsTickOnce() {
        #expect(MainTabController.systemBarTicks(barHidden: false, ownBar: false))
        #expect(!MainTabController.systemBarTicks(barHidden: true, ownBar: false), "the app's own bar plays its own")
        #expect(!MainTabController.systemBarTicks(barHidden: false, ownBar: true))
        let host = UITabBarController()
        host.viewControllers = [UIViewController(), UIViewController(), UIViewController()]
        host.selectedIndex = 0
        let cues = heard {
            DesktopTabBar.select(1, in: host, animated: false)   // another tab
            DesktopTabBar.select(1, in: host, animated: false)   // the same tab again (back to its top)
        }
        #expect(host.selectedIndex == 1)
        #expect(cues == [.selection, .selection])
    }

    /// Every way a Connect Apps sign-in fails gives the error tap with its red line, once.
    @Test func aFailedConnectTapsAnError() {
        let connect = ComposioConnect()
        let cues = heard {
            connect.outcome = nil
            connect.outcome = .failed("The sign-in was declined.")
            connect.outcome = .failed("The sign-in was declined.")   // the same line set again: no second tap
            connect.outcome = .unfinished
            connect.outcome = .connected   // success plays its own where the account turns active
        }
        #expect(cues == [.error])
    }
}
