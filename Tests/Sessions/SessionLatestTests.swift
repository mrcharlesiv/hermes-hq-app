import Foundation
import Testing
@testable import HermesHQNative

/// The Sessions row's second line is the chat's newest message, not the sidebar's first-message preview.
@Suite(.serialized) struct SessionLatestTests {
    nonisolated private static func row(_ id: String, lastActive: Double) -> JSONValue {
        ["id": .string(id), "profile": "ivy", "title": "Chat", "preview": "first thing I asked", "last_active": .number(lastActive),
         "started_at": .number(lastActive - 60), "message_count": 4, "source": "desktop", "is_active": false]
    }

    nonisolated private static func sidebar(_ lastActive: Double) -> Data {
        let root: JSONValue = ["recents": ["sessions": [row("s1", lastActive: lastActive)]], "cron": ["sessions": []],
                               "messaging": ["sessions": []]]
        return try! root.encoded()
    }

    @Test func newestMessageRules() {
        let rows: [JSONValue] = [
            ["id": 1, "role": "user", "content": "first"],
            ["id": 2, "role": "assistant", "content": "the  real\nanswer"],
            ["id": 3, "role": "tool", "content": "{}"],
            ["id": 4, "role": "assistant", "content": " [SILENT] "],
            ["id": 5, "role": "assistant", "content": ""],
        ]
        #expect(SessionLatestRules.latest(rows) == "the real answer")
        #expect(SessionLatestRules.latest([["id": 9, "role": "user", "content": [["type": "text", "text": "parts"]]]]) == "parts")
        #expect(SessionLatestRules.latest([]) == nil)
    }

    @Test func rowShowsNewestMessageAndRereadsWhenActivityMoves() async throws {
        let client = BotsFakeGatewayClient()
        let active = LockedBox(1_791_000_000.0)
        let reply = LockedBox("latest reply")
        client.onREST { _, path, _, _ in
            if path.hasSuffix("/messages") {
                let rows: JSONValue = ["messages": [["id": 1, "role": "user", "content": "first thing I asked"],
                                                    ["id": 7, "role": "assistant", "content": .string(reply.value)]]]
                return try rows.encoded()
            }
            return Self.sidebar(active.value)
        }
        var timing = SessionStoreTiming.fast
        timing.readsLatest = true
        let store = SessionStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing)
        #expect(await BotsTest.waitUntil { store.sessions.first?.preview == "latest reply" })
        #expect(store.sessions.first?.title == "Chat")
        let reads = client.restCalls.filter { $0.path.hasSuffix("/messages") }.count
        #expect(reads == 1)

        // Unchanged activity: no second read. Moved activity: read again.
        await store.refresh()
        #expect(client.restCalls.filter { $0.path.hasSuffix("/messages") }.count == 1)
        reply.value = "newer reply"
        active.value += 30
        await store.refresh()
        #expect(await BotsTest.waitUntil { store.sessions.first?.preview == "newer reply" })

        // A chat just left updates its row at once.
        store.noteLatest(profile: "ivy", sessionId: "s1", text: "seen just now")
        #expect(store.sessions.first?.preview == "seen just now")
        store.stop()
        RosterDiskWriter.shared.flush()
    }

    /// Show › Archived lists archived chats beside live ones: theirs show the newest message too, not the first.
    @Test func archivedRowsShowTheirNewestMessage() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, path, query, _ in
            if path.hasSuffix("/messages") {
                let rows: JSONValue = ["messages": [["id": 1, "role": "user", "content": "first thing I asked"],
                                                    ["id": 7, "role": "assistant", "content": "archived answer"]]]
                return try rows.encoded()
            }
            if query.contains(URLQueryItem(name: "archived", value: "only")) {
                let old: JSONValue = ["id": "old", "profile": "ivy", "title": "Old", "preview": "first thing I asked",
                                      "last_active": 1_790_000_000, "started_at": 1_789_999_000, "message_count": 4,
                                      "source": "desktop", "is_active": false, "archived": true]
                let root: JSONValue = ["sessions": [old]]
                return try root.encoded()
            }
            let root: JSONValue = ["recents": ["sessions": []], "cron": ["sessions": []], "messaging": ["sessions": []]]
            return try root.encoded()
        }
        var timing = SessionStoreTiming.fast
        timing.readsLatest = true
        let store = SessionStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        store.setView { $0.showArchived = true }
        #expect(await BotsTest.waitUntil { store.archivedSessions.first?.preview == "archived answer" })
        #expect(client.restCalls.filter { $0.path.hasSuffix("/messages") }.count == 1)
        store.stop()
        RosterDiskWriter.shared.flush()
    }

    @Test func replyStoredAfterHeartbeatMovesMessageCountAndRereads() async throws {
        let client = BotsFakeGatewayClient()
        let count = LockedBox(4)
        let reply = LockedBox("before reply")
        client.onREST { _, path, query, _ in
            if path.hasSuffix("/messages") {
                #expect(query.contains(URLQueryItem(name: "inline_images", value: "false")))
                let rows: JSONValue = ["messages": [["id": 1, "role": "user", "content": "first thing I asked"],
                                                    ["id": 2, "role": "assistant", "content": .string(reply.value)]]]
                return try rows.encoded()
            }
            let row: JSONValue = ["id": "s1", "profile": "ivy", "title": "Chat", "preview": "first thing I asked",
                                  "last_active": 1_791_000_000, "started_at": 1_790_999_940, "message_count": .number(Double(count.value)),
                                  "source": "desktop", "is_active": false]
            let root: JSONValue = ["recents": ["sessions": [row]], "cron": ["sessions": []], "messaging": ["sessions": []]]
            return try root.encoded()
        }
        var timing = SessionStoreTiming.fast
        timing.readsLatest = true
        let store = SessionStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing)
        #expect(await BotsTest.waitUntil { store.sessions.first?.preview == "before reply" })
        #expect(client.restCalls.filter { $0.path.hasSuffix("/messages") }.count == 1)

        // Reply lands without moving `last_active` (same heartbeat), only incrementing `message_count`.
        reply.value = "after heartbeat reply"
        count.value = 5
        await store.refresh()
        #expect(await BotsTest.waitUntil { store.sessions.first?.preview == "after heartbeat reply" })
        #expect(client.restCalls.filter { $0.path.hasSuffix("/messages") }.count == 2)
        store.stop()
        RosterDiskWriter.shared.flush()
    }

    @Test func runningToIdleImmediatelyRereadsLatest() async throws {
        let client = BotsFakeGatewayClient()
        let reply = LockedBox("old reply")
        client.onREST { _, path, _, _ in
            if path.hasSuffix("/messages") {
                let rows: JSONValue = ["messages": [["id": 1, "role": "assistant", "content": .string(reply.value)]]]
                return try rows.encoded()
            }
            return Self.sidebar(1_791_000_000)
        }
        var timing = SessionStoreTiming.fast
        timing.readsLatest = true
        let store = SessionStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing)
        #expect(await BotsTest.waitUntil { store.sessions.first?.preview == "old reply" })
        #expect(client.restCalls.filter { $0.path.hasSuffix("/messages") }.count == 1)

        // Working -> idle triggers an immediate tail re-read without waiting for a sidebar refresh.
        store.setRunning(["s1"])
        reply.value = "finished reply"
        store.setRunning([])
        #expect(await BotsTest.waitUntil { store.sessions.first?.preview == "finished reply" })
        #expect(client.restCalls.filter { $0.path.hasSuffix("/messages") }.count == 2)

        // When on screen, working -> idle skips the redundant tail read.
        store.setSessionOnScreen("s1")
        store.setRunning(["s1"])
        store.setRunning([])
        try await Task.sleep(for: .milliseconds(80))
        #expect(client.restCalls.filter { $0.path.hasSuffix("/messages") }.count == 2)
        store.stop()
        RosterDiskWriter.shared.flush()
    }

    @Test func fastLatestReadFlushesWithoutWaitingForSlowSibling() async throws {
        let client = BotsFakeGatewayClient()
        let holdSlow = LockedBox(true)
        client.onREST { _, path, _, _ in
            if path.contains("slow-s") {
                while holdSlow.value { try await Task.sleep(for: .milliseconds(10)) }
                let rows: JSONValue = ["messages": [["id": 1, "role": "assistant", "content": "slow answer"]]]
                return try rows.encoded()
            }
            if path.contains("fast-s") {
                let rows: JSONValue = ["messages": [["id": 1, "role": "assistant", "content": "fast answer"]]]
                return try rows.encoded()
            }
            let root: JSONValue = [
                "recents": ["sessions": [Self.row("fast-s", lastActive: 1_791_000_100),
                                         Self.row("slow-s", lastActive: 1_791_000_050)]],
                "cron": ["sessions": []], "messaging": ["sessions": []],
            ]
            return try root.encoded()
        }
        var timing = SessionStoreTiming.fast
        timing.readsLatest = true
        let store = SessionStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing)
        #expect(await BotsTest.waitUntil(.seconds(1)) { store.sessions.first { $0.id == "fast-s" }?.preview == "fast answer" })
        #expect(store.sessions.first { $0.id == "slow-s" }?.preview != "slow answer")
        holdSlow.value = false
        #expect(await BotsTest.waitUntil { store.sessions.first { $0.id == "slow-s" }?.preview == "slow answer" })
        store.stop()
        RosterDiskWriter.shared.flush()
    }

    @Test func appModelLatestSessionPreviewSkipsNoise() {
        let messages: [ChatMessage] = [
            ChatMessage(id: "1", role: .user, parts: [.text("hello there")]),
            ChatMessage(id: "2", role: .assistant, parts: [.text("Here is the  final\nanswer.")]),
            ChatMessage(id: "3", role: .assistant, parts: [.text(" [SILENT] ")]),
            ChatMessage(id: "4", role: .assistant, parts: [.text("")], isStreaming: true),
            ChatMessage(id: "5", role: .system, parts: [.text("compacted")]),
        ]
        let picked = AppModel.latestSessionPreview(in: messages)
        #expect(picked?.text == "Here is the final answer.")
        #expect(picked?.role == "assistant")
    }
}

nonisolated private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
