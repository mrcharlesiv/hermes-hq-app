import Foundation
import Testing
@testable import HermesHQNative

/// [sessions-m9] The chat's side of a send that may never have arrived (docs/spec/3x-sessions.md §9.4): kept for its
/// Sessions row, cleared when the mark clears, and put back as the marked bubble when the chat opens again.
@Suite("Lost sends and the chat", .serialized)
@MainActor
struct LostSendsChatTests {
    private let rows: [JSONValue] = [
        ["role": "user", "content": "first", "row_id": 10, "timestamp": 1_791_590_000],
        ["role": "assistant", "content": "an answer", "row_id": 11, "timestamp": 1_791_590_001],
    ]

    private func harness(_ store: LostSends?, rows: [JSONValue]) throws -> (ChatHarness, LiveChatSession) {
        let h = try ChatHarness()
        h.setPage("24", rows: rows)
        let s = h.make()
        s.lostSends = store
        return (h, s)
    }

    private func losePrompts(_ h: ChatHarness) throws {
        let resume = try ChatFixtures.json("perf-resume.json")["result"] ?? .null
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": throw RPCError.connectionLost("prompt.submit")
            case "session.resume", "session.activate": return resume
            default: return [:]
            }
        }
    }

    @Test func aLostSendIsKeptComesBackAndGoesWithItsBubble() async throws {
        let store = LostSends(base: BotsTest.tempDirectory())
        var changes = 0
        store.onChange = { changes += 1 }
        let (h, s) = try harness(store, rows: rows)
        #expect(await h.open())
        try losePrompts(h)
        s.send("  call the plumber ")
        #expect(await waitUntil { h.lastUser?.error == LiveChatSession.unconfirmedMark })
        let account = h.client.account.id
        let kept = store.entries(accountId: account, profile: "default", chatId: h.stored)
        #expect(kept.map(\.text) == ["call the plumber"] && kept.first?.id == h.lastUser?.id && kept.first?.after == 11)
        #expect(changes == 1)

        // The chat is opened again (another screen, or the next launch): the bubble is back, marked, once.
        let (h2, s2) = try harness(store, rows: rows)
        #expect(await h2.open())
        let back = s2.messages.filter { $0.role == .user && $0.error == LiveChatSession.unconfirmedMark }
        #expect(back.map(\.plainText) == ["call the plumber"] && s2.messages.last?.id == back.first?.id)
        #expect(back.first?.id.hasPrefix("local-user-lost-") == true && back.first?.isLocal == true)
        #expect(store.entries(accountId: account, profile: "default", chatId: h.stored).map(\.id) == back.map(\.id))
        s2.refresh()
        try await Task.sleep(for: .milliseconds(300))
        s2.flushChanges()
        #expect(s2.messages.filter { $0.error == LiveChatSession.unconfirmedMark }.count == 1)       // never twice
        #expect(store.entries(accountId: account, profile: "default", chatId: h.stored).count == 1)

        // Delete takes the bubble and the row's words.
        s2.deleteUndelivered(try #require(back.first?.id))
        #expect(!s2.messages.contains { $0.error != nil })
        #expect(store.first(accountId: account, profile: "default", chatId: h.stored) == nil)
        let (h3, s3) = try harness(store, rows: rows)
        #expect(await h3.open())
        #expect(s3.messages.map(\.plainText) == ["first", "an answer"])
    }

    /// Review finding: a restored bubble goes back where it was said. The chat went on from another device after the
    /// send was lost (rows 12 and 13): the bubble sits after the rows the chat knew (10, 11), before the later ones.
    @Test func aRestoredBubbleGoesBackWhereItWasSaid() async throws {
        let store = LostSends(base: BotsTest.tempDirectory())
        let (h, s) = try harness(store, rows: rows)
        #expect(await h.open())
        try losePrompts(h)
        s.send("call the plumber")
        #expect(await waitUntil { h.lastUser?.error == LiveChatSession.unconfirmedMark })
        let later: [JSONValue] = rows + [
            ["role": "user", "content": "something else", "row_id": 12, "timestamp": 1_791_590_900],
            ["role": "assistant", "content": "a later answer", "row_id": 13, "timestamp": 1_791_590_901],
        ]
        let (h2, s2) = try harness(store, rows: later)
        #expect(await h2.open())
        #expect(s2.messages.map(\.plainText) == ["first", "an answer", "call the plumber", "something else", "a later answer"])
        #expect(s2.messages[2].error == LiveChatSession.unconfirmedMark)
        // Without the row number (an older entry), the saved time places it; with neither, the end.
        let old = LostSends.Entry(id: "x", text: "t", at: Date(timeIntervalSince1970: 1_791_590_000.5))
        #expect(s2.lostSendPlace(old) == 1)
        #expect(s2.lostSendPlace(LostSends.Entry(id: "y", text: "t", at: Date(timeIntervalSince1970: 1_800_000_000))) == s2.messages.count)
    }

    @Test func aSendThatArrivedGoesQuietly() async throws {
        let store = LostSends(base: BotsTest.tempDirectory())
        let (h, s) = try harness(store, rows: rows)
        #expect(await h.open())
        try losePrompts(h)
        s.send("did this arrive")
        #expect(await waitUntil { h.lastUser?.error == LiveChatSession.unconfirmedMark })
        let account = h.client.account.id
        #expect(store.entries(accountId: account, profile: "default", chatId: h.stored).count == 1)
        // The gateway did store it (its clock an hour behind the phone's): the next open shows the stored row, no marked twin.
        let arrived = rows + [["role": "user", "content": "did this arrive", "row_id": 12, "timestamp": 1_791_590_002],
                              ["role": "assistant", "content": "It did.", "row_id": 13, "timestamp": 1_791_590_003]]
        let (h2, s2) = try harness(store, rows: arrived)
        #expect(await h2.open())
        #expect(s2.messages.map(\.plainText) == ["first", "an answer", "did this arrive", "It did."])
        #expect(!s2.messages.contains { $0.error != nil })
        #expect(store.entries(accountId: account, profile: "default", chatId: h.stored).isEmpty)
        // The same words from before the send are not proof: the bubble returns.
        s.send("first")
        #expect(await waitUntil { s.messages.last?.error == LiveChatSession.unconfirmedMark })
        let (h3, s3) = try harness(store, rows: rows)
        #expect(await h3.open())
        #expect(s3.messages.map(\.plainText) == ["first", "an answer", "first"] && s3.messages.last?.error == LiveChatSession.unconfirmedMark)
    }

    @Test func checkAndSendAgainClearTheRowsWords() async throws {
        let store = LostSends(base: BotsTest.tempDirectory())
        let (h, s) = try harness(store, rows: rows)
        #expect(await h.open())
        try losePrompts(h)
        s.send("one")
        #expect(await waitUntil { h.lastUser?.error == LiveChatSession.unconfirmedMark })
        let account = h.client.account.id
        let id = try #require(h.lastUser?.id)
        // Check finds it in the stored chat: the mark and the entry go.
        h.setPage("24", rows: rows + [["role": "user", "content": "one", "row_id": 12, "timestamp": 1_791_590_002]])
        #expect(await s.checkDelivery(id) == true)
        #expect(store.entries(accountId: account, profile: "default", chatId: h.stored).isEmpty)
        // Send Again replaces the entry with the new send's (which is lost again here).
        s.send("two")
        #expect(await waitUntil { s.messages.last?.plainText == "two" && s.messages.last?.error == LiveChatSession.unconfirmedMark })
        let second = try #require(s.messages.last?.id)
        s.sendAgain(second)
        #expect(await waitUntil { s.messages.last?.plainText == "two" && s.messages.last?.error == LiveChatSession.unconfirmedMark
            && s.messages.last?.id != second })
        let kept = store.entries(accountId: account, profile: "default", chatId: h.stored)
        #expect(kept.map(\.text) == ["two"] && kept.first?.id == s.messages.last?.id)
    }

    @Test func aChatWithoutTheStoreKeepsNothing() async throws {
        let (h, s) = try harness(nil, rows: rows)
        LostSends.shared.purge(accountId: h.client.account.id)        // nothing of an earlier run in the test host's folder
        #expect(await h.open())
        try losePrompts(h)
        s.send("nobody is told")
        #expect(await waitUntil { h.lastUser?.error == LiveChatSession.unconfirmedMark })
        #expect(LostSends.shared.entries(accountId: h.client.account.id, profile: "default", chatId: h.stored).isEmpty)
    }
}
