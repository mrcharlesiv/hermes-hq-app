// The ways into a conversation that have no screen of their own (docs/spec/3x-talk.md §5.1, §5.5): a Talk tile whose
// chat never opened says so (row L163), and VoiceOver reaches the voice options from the Talk circle (row L531).

import Testing
import UIKit
@testable import HermesHQNative

@Suite("Talk entries", .serialized)
@MainActor
struct TalkWiringTests {
    /// A list on screen in a window of its own (the app in the test host keeps its own window).
    private func onScreen() throws -> (UIWindow, UINavigationController, UIViewController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let list = UIViewController()
        let navigation = UINavigationController(rootViewController: list)
        window.rootViewController = navigation
        window.isHidden = false
        navigation.view.layoutIfNeeded()
        return (window, navigation, list)
    }

    @Test("A Talk tile whose chat never opens answers once, with no chat, and the alert says whose chat did not open")
    func aChatThatNeverOpens() async throws {
        let (window, navigation, list) = try onScreen()
        defer { window.isHidden = true }
        var answers: [Bool] = []
        TalkWiring.settle(on: navigation, attempts: 3, seen: false) { answers.append($0 != nil) }
        try await Task.sleep(for: .milliseconds(900))
        #expect(answers == [false], "one answer, and it is \"no chat\"")

        TalkWiring.showStartFailed(name: "Ivy", over: list, animated: false)
        let alert = try #require(list.presentedViewController as? UIAlertController)
        #expect(alert.title == "Couldn’t Start Talking")
        #expect(alert.message == "Ivy’s chat didn’t open.")
        #expect(alert.actions.map(\.title) == ["OK"])
        #expect(alert.view.accessibilityIdentifier == "talk.start-failed")
        // A second failure while one is showing adds nothing.
        TalkWiring.showStartFailed(name: "Riley", over: list, animated: false)
        #expect((list.presentedViewController as? UIAlertController)?.message == "Ivy’s chat didn’t open.")
        alert.dismiss(animated: false)
    }

    @Test("A screen that is not a chat, left before the wait ends, is never answered as a chat")
    func somethingElseOnTop() async throws {
        let (window, navigation, _) = try onScreen()
        defer { window.isHidden = true }
        navigation.pushViewController(UIViewController(), animated: false)
        var chats = 0, nothing = 0
        TalkWiring.settle(on: navigation, attempts: 2, seen: false) { if $0 != nil { chats += 1 } else { nothing += 1 } }
        try await Task.sleep(for: .milliseconds(700))
        #expect(chats == 0 && nothing == 1)
    }

    @Test("VoiceOver reaches the voice options from Talk, and only from Talk")
    func voiceOptionsAction() {
        let button = PrimaryButton()
        button.talkName = "Ivy"
        var opened = 0
        button.onOptions = { opened += 1 }
        button.set(.talk, animated: false)
        #expect(button.accessibilityLabel == "Talk with Ivy" && button.accessibilityIdentifier == "composer.talk")
        let actions = button.accessibilityCustomActions ?? []
        #expect(actions.map(\.name) == ["Voice options"])
        #expect(actions.first?.actionHandler?(actions[0]) == true)
        #expect(opened == 1, "the action opens the options")
        for other in [ComposerView.Primary.send, .stop, .stopDictation, .disabled] {
            button.set(other, animated: false)
            #expect(button.accessibilityCustomActions == nil, "\(other)")
            #expect(!button.isContextMenuInteractionEnabled)
        }
        button.set(.talk, animated: false)
        #expect(button.accessibilityCustomActions?.count == 1)
        #expect(!button.isContextMenuInteractionEnabled, "no hold menu without a menu to show")
        button.menuProvider = { UIMenu(children: []) }
        #expect(button.isContextMenuInteractionEnabled)
    }
}
