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

    // MARK: A reply written to another bot is never the preview (owner, 2026-11-12)

    private static let seats = [
        DeliveryMessages.Seat(profile: "default", name: "Hermes", head: nil),
        DeliveryMessages.Seat(profile: "otto", name: "Otto", head: nil),
        DeliveryMessages.Seat(profile: "herald", name: "Herald", head: nil),
    ]
    private static let herald = seats[2]

    private static func call(_ id: Int) -> JSONValue {
        ["id": .number(Double(id)), "role": "assistant", "content": "", "finish_reason": "tool_calls",
         "tool_calls": [["id": .string("c\(id)"), "type": "function", "function": ["name": "terminal", "arguments": "{\"command\":\"ls\"}"]]]]
    }
    private static func result(_ id: Int, of call: Int) -> JSONValue {
        ["id": .number(Double(id)), "role": "tool", "tool_call_id": .string("c\(call)"), "content": "{\"output\":\"ok\"}"]
    }

    /// Otto asks Herald to check a door and then to close it; Herald answers Otto both times. The chat folds all of it
    /// into "With Otto"; the row keeps Herald's last words to you.
    private static var askedByOtto: [JSONValue] {
        [
            ["id": 1, "role": "user", "content": "Are the porch lights on a timer?"],
            ["id": 2, "role": "assistant", "content": "**Yes, the porch lights are on a timer again.** They go off at eleven."],
            ["id": 3, "role": "user", "display_kind": "internal_notification",
             "content": "Message from 🤖 otto (@otto): Your morning report flagged the side door as open. Please check it now."],
            call(4), result(5, of: 4),
            ["id": 6, "role": "assistant", "content": "**The side door is still open.** It was last moved at four."],
            ["id": 7, "role": "user", "display_kind": "internal_notification",
             "content": "Message from 🤖 otto (@otto): The owner approved closing it. Please close it and confirm."],
            call(8), result(9, of: 8),
            ["id": 10, "role": "assistant", "content": "**The side door is closed:** position 0, confirmed just now."],
        ]
    }

    @Test func aReplyWrittenToAnotherBotIsNotThePreview() {
        let rows = Self.askedByOtto
        #expect(BotSaidRules.latest(rows, own: Self.herald, seats: Self.seats)
                == "**Yes, the porch lights are on a timer again.** They go off at eleven.")
        // Given in the gateway's newest-first order, the same.
        #expect(BotSaidRules.latest(rows.reversed(), own: Self.herald, seats: Self.seats)
                == "**Yes, the porch lights are on a timer again.** They go off at eleven.")
        // The talk alone: nothing of Herald's to you, and nothing settled.
        let talk = BotSaidRules.shown(rows: Array(rows.dropFirst(2)), own: Self.herald, seats: Self.seats)
        #expect(talk.text == nil && !talk.settled)
        // Your next message and its answer: that answer.
        let after = rows + [["id": 11, "role": "user", "content": "Thanks. Lock it too."],
                            ["id": 12, "role": "assistant", "content": "Locked."]]
        let shown = BotSaidRules.shown(rows: after, own: Self.herald, seats: Self.seats)
        #expect(shown.text == "Locked." && shown.settled)
    }

    /// A reply to a bot's answer to what this bot asked it is news for you ("Otto confirmed…"): it stays the preview,
    /// as it stays a bubble.
    @Test func newsABotBroughtBackStaysThePreview() {
        let rows: [JSONValue] = [
            ["id": 1, "role": "user", "content": "Ask Otto whether the build is green."],
            ["id": 2, "role": "assistant", "content": "", "finish_reason": "tool_calls",
             "tool_calls": [["id": "m1", "type": "function",
                             "function": ["name": "message_agent", "arguments": "{\"target\":\"otto\",\"message\":\"Is the build green?\"}"]]]],
            ["id": 3, "role": "tool", "tool_call_id": "m1", "content": "{\"status\":\"queued\"}"],
            ["id": 4, "role": "assistant", "content": "I've asked Otto."],
            ["id": 5, "role": "user", "display_kind": "internal_notification",
             "content": "Message from 🤖 otto (@otto): Green since nine."],
            ["id": 6, "role": "assistant", "content": "The build has been green since nine, Otto says."],
        ]
        #expect(BotSaidRules.latest(rows, own: Self.herald, seats: Self.seats) == "The build has been green since nine, Otto says.")
    }

    /// A long turn's request sits before the first tail: the chat is read further back once, and the reply that
    /// answers another bot gives way to the bot's last words to you.
    @Test func aLongTurnIsReadBackToWhatItAnswers() async throws {
        let client = BotsFakeGatewayClient()
        var rows: [JSONValue] = [
            ["id": 1, "role": "user", "content": "How many came in?"],
            ["id": 2, "role": "assistant", "content": "Twelve came in today."],
            ["id": 3, "role": "user", "display_kind": "internal_notification",
             "content": "Message from 🤖 otto (@otto): Please finish the source study and report back to me."],
        ]
        var id = 4
        for _ in 0..<20 { rows += [Self.call(id), Self.result(id + 1, of: id)]; id += 2 }
        rows.append(["id": .number(Double(id)), "role": "assistant", "content": "Work completed under the agreed key; I keep ownership."])
        let all = rows
        client.on("profiles.list") { _ in
            BotsTest.profilesResult([BotsTest.row("herald", canonical: BotsTest.session("reg", resolved: "tip", preview: "Work completed",
                                                                                        lastActive: 1_791_000_000))])
        }
        client.onREST { _, _, query, _ in
            let limit = query.first { $0.name == "limit" }?.value.flatMap(Int.init) ?? 0
            let root: JSONValue = ["messages": .array(Array(all.suffix(limit).reversed()))]
            return try root.encoded()
        }
        DeliveryRoster.set(Self.seats)
        defer { DeliveryRoster.set([]) }
        var timing = BotStoreTiming.fast
        timing.readsBotSaid = true
        let store = BotStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing,
                             autoStart: true)
        #expect(await BotsTest.waitUntil { store.bot(named: "herald")?.preview == "Twelve came in today." })
        #expect(client.restCalls.count == 2)
        store.stop()
        RosterDiskWriter.shared.flush()
    }

    /// A reply that landed off screen is known only by its words: the row reads the chat instead of showing them.
    @Test func aReplyThatLandedOffScreenIsReadNotTrusted() async throws {
        let client = BotsFakeGatewayClient()
        let tail = BotsTestBox<[JSONValue]>(Array(Self.askedByOtto.prefix(2)))
        client.on("profiles.list") { _ in
            BotsTest.profilesResult([BotsTest.row("herald", canonical: BotsTest.session("reg", resolved: "tip", preview: "Yes",
                                                                                        lastActive: 1_791_000_000))])
        }
        client.onREST { _, _, _, _ in
            let root: JSONValue = ["messages": .array(tail.value)]
            return try root.encoded()
        }
        DeliveryRoster.set(Self.seats)
        defer { DeliveryRoster.set([]) }
        var timing = BotStoreTiming.fast
        timing.readsBotSaid = true
        let store = BotStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing,
                             autoStart: true)
        let words = "Yes, the porch lights are on a timer again. They go off at eleven."   // as the row draws them
        #expect(await BotsTest.waitUntil { store.bot(named: "herald")?.preview == words })
        #expect(client.restCalls.count == 1)

        tail.value = Self.askedByOtto
        store.noteChatActivity(profile: "herald", sessionId: "tip", preview: "**The side door is closed:** position 0, confirmed just now.",
                               at: Date(timeIntervalSince1970: 1_791_000_100), unseen: true, said: false)
        #expect(await BotsTest.waitUntil { client.restCalls.count == 2 })
        try await Task.sleep(for: .milliseconds(80))
        #expect(store.bot(named: "herald")?.preview == words)
        store.stop()
        RosterDiskWriter.shared.flush()
    }
}
