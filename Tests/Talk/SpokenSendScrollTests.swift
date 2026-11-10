// [talk] A spoken request reaches the session past the composer; during a conversation its bubble brings the chat to
// the end and following again, as a typed send does (owner, build 409: "it isn't scrolling down to show all of what i
// said"). Outside a conversation a new row leaves the reader's place alone.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
private final class SpokenChat: ChatSessionModel, ChatVoiceTurns {
    let title = "Spoken"
    let profile = "ivy"
    let head: JSONValue? = nil
    var messages: [ChatMessage] = (0..<40).map { i in
        ChatMessage(id: "m\(i)", role: i % 2 == 0 ? .user : .assistant,
                    parts: [.text(String(repeating: "A long line of words for row \(i). ", count: 12))],
                    timestamp: Date(), rowId: i + 1)
    }
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
    // ChatVoiceTurns
    var allowsTalk = true
    var memoScope = "acct|ivy|20260929_120000_aabbcc02"
    var newestReply: SpokenReply?
    var onVoiceChange: (() -> Void)?
    var voiceHold = false
    var storedSessionId: String? = "20260929_120000_aabbcc02"
    var canReopen = true
    let voiceClient: any GatewayClient = FakeGatewayClient()
    func sendSpoken(_ text: String, interrupted: Bool) {}
    func spokenText(messageId: String) -> SpokenReply? { nil }

    /// What `sendDelegated` does in the live session: an optimistic bubble of ours at the end.
    func ownBubble(_ text: String) {
        let id = "local-\(messages.count)"
        messages.append(ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: Date(), isPending: true))
        onChange?(.appended(ids: [id]))
    }
}

@MainActor @Suite(.serialized) struct SpokenSendScrollTests {
    private func settle(_ chat: ChatViewController, until done: () -> Bool) {
        let end = Date().addingTimeInterval(3)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        chat.view.layoutIfNeeded()
    }

    private func open(_ session: SpokenChat) throws -> (ChatViewController, UIWindow) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let chat = ChatViewController(session: session)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UINavigationController(rootViewController: chat)
        window.makeKeyAndVisible()
        chat.view.layoutIfNeeded()
        settle(chat) { chat.isAtBottomForTests }
        return (chat, window)
    }

    @Test func aSpokenRequestDuringAConversationBringsTheChatToTheEnd() throws {
        let session = SpokenChat()
        let (chat, window) = try open(session)
        defer { window.isHidden = true; window.rootViewController = nil }
        chat.debugScroll(by: 1200)
        #expect(!chat.isAtBottomForTests && !chat.followingForTests)
        session.voiceHold = true
        session.ownBubble("Sure, don't send anything to Melissa though, just do it and send it to me.")
        settle(chat) { chat.isAtBottomForTests }
        #expect(chat.isAtBottomForTests, "the spoken bubble is on screen")
        #expect(chat.followingForTests, "the reply and its tool rows follow")
    }

    @Test func outsideAConversationANewRowKeepsTheReadersPlace() throws {
        let session = SpokenChat()
        let (chat, window) = try open(session)
        defer { window.isHidden = true; window.rootViewController = nil }
        chat.debugScroll(by: 1200)
        session.ownBubble("typed elsewhere")
        settle(chat) { false }
        #expect(!chat.isAtBottomForTests && !chat.followingForTests)
    }
}
