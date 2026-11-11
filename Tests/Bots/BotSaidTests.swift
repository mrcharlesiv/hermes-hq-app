import Foundation
import Testing
@testable import HermesHQNative

/// [botsaid] A Bots row previews the newest thing the bot itself said, never your message, a run or a delivery.
@Suite(.serialized) struct BotSaidTests {
    @Test func ownWordsRules() {
        let rows: [JSONValue] = [
            ["id": 1, "role": "assistant", "content": "Here is the  plan\nfor today"],
            ["id": 2, "role": "user", "content": "thanks!"],
            ["id": 3, "role": "assistant", "content": "[Cron delivery: inbox-watch]\n1 new inbound email"],
            ["id": 4, "role": "assistant", "content": " [SILENT] "],
            ["id": 5, "role": "assistant", "content": "Message from agent 'ann': the build is green"],
            ["id": 6, "role": "tool", "content": "{}"],
            ["id": 7, "role": "assistant", "content": ""],
            ["id": 8, "role": "assistant", "content": "[System note: context compacted]"],
        ]
        #expect(BotSaidRules.latest(rows) == "Here is the plan for today")
        #expect(BotSaidRules.latest([["id": 1, "role": "user", "content": "only mine"]]) == nil)
        #expect(BotSaidRules.latest([["id": 9, "role": "assistant", "content": [["type": "text", "text": "parts"]]]]) == "parts")
        #expect(!BotSaidRules.isOwnWords("Cronjob Response: morning-brief\nall quiet"))
        #expect(BotSaidRules.isOwnWords("Done — the PR is up."))
    }

    @Test func rowShowsTheBotsOwnWordsNotTheChatsNewestLine() async throws {
        let client = BotsFakeGatewayClient()
        let active = BotsTestBox(1_791_000_000.0)
        let tail = BotsTestBox<[JSONValue]>([
            ["id": 1, "role": "assistant", "content": "Your summary is ready"],
            ["id": 2, "role": "assistant", "content": "[Cron delivery: inbox-watch]\n1 new inbound email"],
        ])
        client.on("profiles.list") { _ in
            BotsTest.profilesResult([
                BotsTest.row("ivy", canonical: BotsTest.session("reg", resolved: "tip", preview: "[Cron delivery: inbox-watch] 1 new",
                                                             lastActive: active.value)),
            ])
        }
        client.onREST { _, path, _, _ in
            #expect(path == "/api/sessions/tip/messages")
            let root: JSONValue = ["messages": .array(tail.value)]
            return try root.encoded()
        }
        var timing = BotStoreTiming.fast
        timing.readsBotSaid = true
        let store = BotStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing,
                             autoStart: true)
        #expect(await BotsTest.waitUntil { store.bot(named: "ivy")?.preview == "Your summary is ready" })
        #expect(store.detail(for: try #require(store.bot(named: "ivy")))?.preview.prefix == nil)
        #expect(client.restCalls.count == 1)

        // Unchanged activity: no second read.
        await store.refresh()
        #expect(client.restCalls.count == 1)

        // Moved activity, only your message and another run since: the bot's last words stay.
        tail.value = [["id": 3, "role": "user", "content": "anything else?"],
                      ["id": 4, "role": "assistant", "content": "[Cron delivery: inbox-watch]\nnothing new"]]
        active.value += 60
        await store.refresh()
        #expect(await BotsTest.waitUntil { client.restCalls.count == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.bot(named: "ivy")?.preview == "Your summary is ready")

        // A reply seen on this device shows at once; your own message never does.
        store.noteChatActivity(profile: "ivy", sessionId: "tip", preview: "On it.", at: Date(timeIntervalSince1970: active.value + 10),
                               unseen: false)
        #expect(store.bot(named: "ivy")?.preview == "On it.")
        store.noteChatActivity(profile: "ivy", sessionId: "tip", preview: nil, at: Date(timeIntervalSince1970: active.value + 20),
                               unseen: false)
        #expect(store.bot(named: "ivy")?.preview == "On it.")
        store.stop()
        RosterDiskWriter.shared.flush()
    }

    /// A chat with nothing of the bot's in its tail shows the role line, not your message or a run.
    @Test func noOwnWordsShowsTheRole() async throws {
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in
            BotsTest.profilesResult([
                BotsTest.row("ivy", canonical: BotsTest.session("chat", preview: "hello from me", lastActive: 1_791_000_000),
                             description: "Research"),
            ])
        }
        client.onREST { _, _, _, _ in
            let root: JSONValue = ["messages": [["id": 1, "role": "user", "content": "hello from me"]]]
            return try root.encoded()
        }
        var timing = BotStoreTiming.fast
        timing.readsBotSaid = true
        let store = BotStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing,
                             autoStart: true)
        #expect(await BotsTest.waitUntil { client.restCalls.count == 1 })
        #expect(await BotsTest.waitUntil {
            guard let bot = store.bot(named: "ivy") else { return false }
            return store.secondLine(for: bot).text != "hello from me"
        })
        store.stop()
        RosterDiskWriter.shared.flush()
    }

    /// The roster's `last_active` is Hermes's activity heartbeat (about once a minute while a turn runs): the reply that
    /// ends the turn is stored after it and doesn't move it. The row is read again all the same, because the roster's
    /// newest line and count moved (owner 2026-11-10: the preview "does not match the last message in the chat from
    /// the bot").
    @Test func aReplyStoredAfterTheLastHeartbeatIsRead() async throws {
        let client = BotsFakeGatewayClient()
        let chat = BotsTestBox(BotsTest.session("reg", resolved: "tip", preview: "ship it", lastActive: 1_791_000_000, count: 10))
        let tail = BotsTestBox<[JSONValue]>([
            ["id": 1, "role": "assistant", "content": "Yesterday's answer"],
            ["id": 2, "role": "user", "content": "ship it"],
        ])
        client.on("profiles.list") { _ in BotsTest.profilesResult([BotsTest.row("ivy", canonical: chat.value)]) }
        client.onREST { _, _, _, _ in
            let root: JSONValue = ["messages": .array(tail.value)]
            return try root.encoded()
        }
        var timing = BotStoreTiming.fast
        timing.readsBotSaid = true
        let store = BotStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing,
                             autoStart: true)
        // Read while the bot was still working: its words from before.
        #expect(await BotsTest.waitUntil { store.bot(named: "ivy")?.preview == "Yesterday's answer" })
        #expect(client.restCalls.count == 1)

        // The reply is stored: the same `last_active`, a new newest line and two more rows.
        tail.value += [["id": 3, "role": "assistant", "content": "Shipped. Build 930 is live."]]
        chat.value = BotsTest.session("reg", resolved: "tip", preview: "Shipped. Build 930 is live.", lastActive: 1_791_000_000, count: 12)
        await store.refresh()
        #expect(await BotsTest.waitUntil { store.bot(named: "ivy")?.preview == "Shipped. Build 930 is live." })
        #expect(client.restCalls.count == 2)

        // Nothing moved: no third read.
        await store.refresh()
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.restCalls.count == 2)
        store.stop()
        RosterDiskWriter.shared.flush()
    }

    /// A read asked for before a reply this device then watched arrive holds the words from before it: the reply stays
    /// on the row, and the next roster reads the chat again.
    @Test func aReadThatCrossedAReplySeenHereKeepsTheReply() async throws {
        let client = BotsFakeGatewayClient()
        let chat = BotsTestBox(BotsTest.session("reg", resolved: "tip", preview: "ship it", lastActive: 1_791_000_000, count: 10))
        let tail = BotsTestBox<[JSONValue]>([["id": 1, "role": "assistant", "content": "Yesterday's answer"]])
        let hold = BotsTestBox(true)
        client.on("profiles.list") { _ in BotsTest.profilesResult([BotsTest.row("ivy", canonical: chat.value)]) }
        client.onREST { _, _, _, _ in
            let root: JSONValue = ["messages": .array(tail.value)]       // what the gateway held when it was asked
            while hold.value { try await Task.sleep(for: .milliseconds(10)) }
            return try root.encoded()
        }
        var timing = BotStoreTiming.fast
        timing.readsBotSaid = true
        let store = BotStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing,
                             autoStart: true)
        #expect(await BotsTest.waitUntil { client.restCalls.count == 1 })
        store.noteChatActivity(profile: "ivy", sessionId: "tip", preview: "Shipped. Build 930 is live.",
                               at: Date(timeIntervalSince1970: 1_791_000_030), unseen: false)
        #expect(store.bot(named: "ivy")?.preview == "Shipped. Build 930 is live.")
        hold.value = false
        try await Task.sleep(for: .milliseconds(120))
        #expect(store.bot(named: "ivy")?.preview == "Shipped. Build 930 is live.")

        // The next roster reads the chat's own tail.
        tail.value += [["id": 2, "role": "assistant", "content": "Shipped. Build 930 is live."],
                       ["id": 3, "role": "assistant", "content": "One more thing: the notes are in."]]
        chat.value = BotsTest.session("reg", resolved: "tip", preview: "One more thing: the notes are in.", lastActive: 1_791_000_000, count: 13)
        await store.refresh()
        #expect(await BotsTest.waitUntil { store.bot(named: "ivy")?.preview == "One more thing: the notes are in." })
        store.stop()
        RosterDiskWriter.shared.flush()
    }

    /// The row's time and its unread dot go by the chat's newest stored row, not the heartbeat from before the reply:
    /// a reply stored after you looked gets its dot even though `last_active` never moved.
    @Test func aReplyAfterTheHeartbeatMovesTheTimeAndGetsItsDot() async throws {
        let client = BotsFakeGatewayClient()
        let heartbeat = 1_791_000_000.0
        let chat = BotsTestBox(BotsTest.session("reg", resolved: "tip", preview: "ship it", lastActive: heartbeat, count: 10))
        let tail = BotsTestBox<[JSONValue]>([
            ["id": 1, "role": "assistant", "content": "Yesterday's answer", "timestamp": .number(heartbeat - 500)],
            ["id": 2, "role": "user", "content": "ship it", "timestamp": .number(heartbeat - 5)],
        ])
        client.on("profiles.list") { _ in BotsTest.profilesResult([BotsTest.row("ivy", canonical: chat.value)]) }
        client.onREST { _, _, _, _ in
            let root: JSONValue = ["messages": .array(tail.value)]
            return try root.encoded()
        }
        var timing = BotStoreTiming.fast
        timing.readsBotSaid = true
        let store = BotStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing,
                             autoStart: true)
        #expect(await BotsTest.waitUntil { store.bot(named: "ivy")?.preview == "Yesterday's answer" })
        #expect(store.bot(named: "ivy")?.lastActive == Date(timeIntervalSince1970: heartbeat))
        #expect(store.bot(named: "ivy")?.unread == false)

        // You looked at the chat while the bot worked, through your own message, and left.
        store.noteSeenAfterLeaving(profile: "ivy", sessionId: "tip", seenThrough: Date(timeIntervalSince1970: heartbeat + 1))

        // The reply is stored 20 s after the heartbeat, which stays where it was.
        tail.value += [["id": 3, "role": "assistant", "content": "Shipped.", "timestamp": .number(heartbeat + 20)]]
        chat.value = BotsTest.session("reg", resolved: "tip", preview: "Shipped.", lastActive: heartbeat, count: 11)
        await store.refresh()
        #expect(await BotsTest.waitUntil { store.bot(named: "ivy")?.preview == "Shipped." })
        #expect(store.bot(named: "ivy")?.lastActive == Date(timeIntervalSince1970: heartbeat + 20))
        #expect(store.bot(named: "ivy")?.unread == true)

        // The next roster still says the heartbeat: the time stays at the reply's, and nothing is read again.
        let reads = client.restCalls.count
        await store.refresh()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.bot(named: "ivy")?.lastActive == Date(timeIntervalSince1970: heartbeat + 20))
        #expect(client.restCalls.count == reads)
        store.stop()
        RosterDiskWriter.shared.flush()
    }

    /// The first time a chat's newest row is measured (the update that brought this, or a bot new to the device), a row
    /// newer than the heartbeat is not news: no dot appears for it.
    @Test func theFirstMeasureOfAChatGivesNoDot() async throws {
        let client = BotsFakeGatewayClient()
        let heartbeat = 1_791_000_000.0
        client.on("profiles.list") { _ in
            BotsTest.profilesResult([BotsTest.row("ivy", canonical: BotsTest.session("reg", resolved: "tip", preview: "Done.",
                                                                                     lastActive: heartbeat, count: 10))])
        }
        client.onREST { _, _, _, _ in
            let root: JSONValue = ["messages": [["id": 1, "role": "assistant", "content": "Done.", "timestamp": .number(heartbeat + 30)]]]
            return try root.encoded()
        }
        var timing = BotStoreTiming.fast
        timing.readsBotSaid = true
        let store = BotStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing,
                             autoStart: true)
        #expect(await BotsTest.waitUntil { store.bot(named: "ivy")?.lastActive == Date(timeIntervalSince1970: heartbeat + 30) })
        #expect(store.bot(named: "ivy")?.unread == false)
        await store.refresh()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.bot(named: "ivy")?.unread == false)
        store.stop()
        RosterDiskWriter.shared.flush()
    }
}
