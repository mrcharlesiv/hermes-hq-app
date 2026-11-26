// PR #525: a fresh chat opened via AppModel.openNewChat (/new, locked-chat card, New Chat buttons) focuses its field as
// it appears, and sets focusesOnAppear before setViewControllers so synchronous appearance never misses or leaks it.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
private final class NewChatFocusStubSession: ChatSessionModel {
    let title = "New Chat"
    let profile = "otto"
    let head: JSONValue? = nil
    var messages: [ChatMessage] = []
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

@MainActor
private final class ObservingNavigationController: UINavigationController {
    var observedFocusesOnAppear: Bool?
    var observedDraftText: String?

    override func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        if let chat = viewControllers.last as? ChatViewController {
            observedFocusesOnAppear = chat.focusesOnAppear
            observedDraftText = chat.isViewLoaded ? chat.composer.text : nil
        }
        super.setViewControllers(viewControllers, animated: animated)
    }
}

@MainActor
@Suite("New chat focus on appear", .serialized)
struct NewChatFocusTests {
    private func host(_ navigation: UINavigationController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ check: @MainActor () -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while !check() {
            if ContinuousClock.now >= end { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func setsFocusAndDraftBeforeSetViewControllers() {
        let root = UIViewController()
        let oldChat = ChatViewController(session: NewChatFocusStubSession())
        let navigation = ObservingNavigationController(rootViewController: root)
        navigation.setViewControllers([root, oldChat], animated: false)

        let next = ChatViewController(session: NewChatFocusStubSession())
        let count = AppModel.placeNewChat(next, on: navigation, stack: [root, next], draft: "  follow up  ")

        #expect(count == "follow up".count)
        #expect(navigation.observedFocusesOnAppear == true)
        #expect(navigation.observedDraftText == "follow up")
    }

    @Test func synchronousReplacementFocusesComposerAndConsumesFlag() async throws {
        let root = UIViewController()
        let oldChat = ChatViewController(session: NewChatFocusStubSession())
        let navigation = UINavigationController(rootViewController: root)
        navigation.setViewControllers([root, oldChat], animated: false)
        let window = try host(navigation)
        defer { window.isHidden = true; window.rootViewController = nil }

        oldChat.focusComposer()
        _ = await waitUntil { oldChat.composer.textView.isFirstResponder }

        let next = ChatViewController(session: NewChatFocusStubSession())
        UIView.performWithoutAnimation {
            AppModel.placeNewChat(next, on: navigation, stack: [root, next], draft: "hello")
            window.layoutIfNeeded()
        }

        #expect(await waitUntil { next.composer.textView.isFirstResponder })
        #expect(next.focusesOnAppear == false)
        #expect(next.composer.text == "hello")
    }

    @Test func animatedReplacementKeepsComposerFocusedWithoutDraft() async throws {
        let root = UIViewController()
        let oldChat = ChatViewController(session: NewChatFocusStubSession())
        let navigation = UINavigationController(rootViewController: root)
        navigation.setViewControllers([root, oldChat], animated: false)
        let window = try host(navigation)
        defer { window.isHidden = true; window.rootViewController = nil }

        oldChat.focusComposer()
        _ = await waitUntil { oldChat.composer.textView.isFirstResponder }

        let next = ChatViewController(session: NewChatFocusStubSession())
        let count = AppModel.placeNewChat(next, on: navigation, stack: [root, next], draft: "")

        #expect(count == 0)
        #expect(await waitUntil { next.composer.textView.isFirstResponder })
        #expect(next.focusesOnAppear == false)
        #expect(next.composer.text.isEmpty)
    }
}
