// [a11y] Repairs after stress round 1 (docs/briefs/m9/a11y-report.md, "Repair after stress round 1").

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct A11yRepairRoundOneTests {
    private func hostedChat() -> (UIWindow, UINavigationController, ChatViewController)? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return nil }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let chat = ChatViewController(session: SpyChatSession())
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(chat, animated: false)
        window.rootViewController = nav
        window.isHidden = false
        window.layoutIfNeeded()
        return (window, nav, chat)
    }

    /// Lets the main queue run (a nested run loop would not: the test is itself a main-queue job).
    private func turn(_ seconds: TimeInterval = 0.05) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func wait(_ seconds: TimeInterval = 5, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { await turn(0.02) }
    }

    /// The crash: one Text Size step between Large and Extra Large with a chat open. The title view used to be
    /// pulled out of the bar and put back from inside the bar's own constraint pass.
    @Test func theChatTitleIsNeverPulledFromTheBarDuringASizeChange() async throws {
        guard let (window, _, chat) = hostedChat() else { return }
        defer { window.isHidden = true }
        await turn()
        #expect(chat.navigationItem.titleView is ChatTitleView)

        // A changed size is installed on a later turn of the run loop, once, not inside the caller.
        let before = chat.titleReinstalls
        chat.titleAccessoryView = UIView(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
        chat.titleAccessoryView = nil
        chat.titleAccessoryView = UIView(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
        #expect(chat.titleReinstalls == before, "nothing is installed again inside the call")
        #expect(chat.navigationItem.titleView is ChatTitleView, "the title stays in the bar meanwhile")
        await wait { chat.titleReinstalls > before }
        #expect(chat.titleReinstalls == before + 1, "three changes in one turn are one install")
        await turn(0.2)
        #expect(chat.titleReinstalls == before + 1, "and an unchanged size is not installed again")

        // Every one-notch step up and down the whole range, with the bar laid out inside each step.
        let sizes: [UIContentSizeCategory] = [
            .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
            .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge, .accessibilityExtraExtraLarge,
            .accessibilityExtraExtraExtraLarge,
        ]
        let walk = [.large, .extraLarge, .large, .extraLarge, .large] + sizes + sizes.reversed()
        for size in walk {
            let count = chat.titleReinstalls
            window.traitOverrides.preferredContentSizeCategory = size
            window.updateTraitsIfNeeded()
            window.layoutIfNeeded()
            #expect(chat.titleReinstalls == count, "\(size.rawValue): no install inside the layout pass")
            #expect(chat.navigationItem.titleView is ChatTitleView, "\(size.rawValue): the title stays in the bar")
            await turn(0.02)
            window.layoutIfNeeded()
        }
        #expect(chat.navigationItem.titleView?.window === window, "the title is still in the bar at the end")
    }
}
