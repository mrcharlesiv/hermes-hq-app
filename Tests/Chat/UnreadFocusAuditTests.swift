// Unread fixes from the build 863 audit (chat logic): a chat still draining its queue off screen opened again, and a
// reply in a bot's own chat while one of its side chats is on screen.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@Suite("Unread focus (audit 863)", .serialized)
@MainActor
struct UnreadFocusAuditTests {
    /// A chat still sending its queue off screen, opened again, says its open settled again once it caught up, so the
    /// bot list counts it as on screen.
    @Test func aDrainingChatOpenedAgainSettlesItsOpenAgain() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        QueueStash.shared.purge(accountId: h.client.account.id)
        defer { QueueStash.shared.purge(accountId: h.client.account.id) }
        let s = h.make()
        s.keepQueue()
        var settled: [Bool] = []
        s.onOpenSettled = { settled.append($0) }
        #expect(await h.open())
        #expect(settled == [true])
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.resume", "session.activate": return try ChatFixtures.json("perf-resume.json")["result"]!
            default: return [:]
            }
        }
        s.redirectUnsupported = true
        s.send("long one")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Working"])])
        s.send("queued A")
        s.stopObserving()
        #expect(s.drainingAway)
        s.start()                                                               // the same chat, back on screen
        #expect(await waitUntil { settled.count == 2 })
        #expect(settled.last == true)
    }
}

@Suite("Unread dots (audit 863)", .serialized)
@MainActor
struct UnreadAuditTests {
    private func store() async -> BotStore {
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in
            BotsTest.profilesResult([
                BotsTest.row("ivy", canonical: BotsTest.session("reg", resolved: "tip", preview: "old words", lastActive: 1_791_000_000)),
            ])
        }
        let store = BotStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast,
                             autoStart: true)
        _ = await BotsTest.waitUntil { store.phase == .full }
        return store
    }

    /// A reply that ends in a bot's own chat while one of its side chats is on screen gets its dot at once.
    @Test func aReplyInTheBotsOwnChatGetsItsDotWhileASideChatIsOpen() async throws {
        let store = await store()
        defer { store.stop() }
        store.setFocusedChat(profile: "ivy", sessionId: "a-side-chat")
        store.noteChatActivity(profile: "ivy", sessionId: "tip", preview: "The new reply", at: Date(timeIntervalSince1970: 1_791_001_000),
                               unseen: true)
        #expect(store.bot(named: "ivy")?.unread == true)
    }

    /// …and none while the bot's own chat is the one on screen.
    @Test func noDotWhileTheBotsOwnChatIsOnScreen() async throws {
        let store = await store()
        defer { store.stop() }
        store.setFocusedChat(profile: "ivy", sessionId: "tip")
        store.noteChatActivity(profile: "ivy", sessionId: "tip", preview: "The new reply", at: Date(timeIntervalSince1970: 1_791_001_000),
                               unseen: true)
        #expect(store.bot(named: "ivy")?.unread == false)
    }
}
