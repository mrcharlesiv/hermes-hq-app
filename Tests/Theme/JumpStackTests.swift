// desktop-frost: the chat's jump to latest keeps the trailing edge in both looks (the Desktop Look's flat round button,
// the iOS look's glass circle) and never meets what is docked over the composer: the centred tucked-prompt chip
// ("Password requested", spec 1x-questions Q14), the queue card, the memo notice, the activity shelf.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
private final class StillChat: ChatSessionModel {
    let title = "Still"
    let profile = "still"
    let head: JSONValue? = nil
    var messages: [ChatMessage] = [ChatMessage(id: "u", role: .user, parts: [.text("hi")], timestamp: Date(), rowId: 1)]
    var isRunning = false
    var hasOlder = false
    var isLoadingOlder = false
    var connection: ConnectionState = .ready
    var statusText: String? = nil
    var onChange: ((ChatChange) -> Void)?
    func start() {}
    func stopObserving() {}
    func loadOlder() {}
    func send(_ text: String) {}
    func stop() {}
}

private func set(look: Bool) -> ThemeSet {
    ThemeResolver.resolve(ThemeState(skinID: "slate", desktopLook: look, highContrast: false, uiScalePercent: 100))
}

/// A chip as wide as the prompts controller lets it be (256 pt), centred like it.
private final class WidestChip: UIView {
    override var intrinsicContentSize: CGSize { CGSize(width: 256, height: 34) }
}

@MainActor @Suite(.serialized) struct JumpStackTests {
    @Test(arguments: [true, false]) func theJumpNeverMeetsTheChipQueueNoticeOrShelf(look: Bool) throws {
        try ThemeTable.$testSet.withValue(set(look: look)) {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let chat = ChatViewController(session: StillChat())
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = UINavigationController(rootViewController: chat)
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            chat.installPromptChip(WidestChip())
            chat.promptChipChanged()
            chat.view.layoutIfNeeded()
            let jump = chat.jumpFrameForTests
            #expect(jump.width == ChatMetrics.jumpSize && jump.height == ChatMetrics.jumpSize)
            #expect(jump.maxX > chat.view.bounds.width - ChatMetrics.jumpTrailing - 1, "at the trailing edge, not centred")
            let neighbours = chat.jumpNeighboursForTests
            #expect(neighbours["chip"] != nil, "the chip is up")
            for (name, frame) in neighbours {
                #expect(!jump.intersects(frame), "the jump \(jump) meets the \(name) \(frame)")
            }
        }
    }
}
