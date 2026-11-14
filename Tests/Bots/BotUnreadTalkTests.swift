import Foundation
import Testing
@testable import HermesHQNative

/// [botunread] A bot's unread dot is for something written to you. A chat that only moved because another bot wrote
/// to this one and it answered that bot gets none (a tester, 2026-11-14: one bot wrote to all the others and every one
/// of them showed as unread).
@Suite(.serialized) struct BotUnreadTalkTests {
    private static let seats = [
        DeliveryMessages.Seat(profile: "default", name: "Hermes", head: nil),
        DeliveryMessages.Seat(profile: "otto", name: "Otto", head: nil),
        DeliveryMessages.Seat(profile: "herald", name: "Herald", head: nil),
    ]
    private static let herald = seats[2]
    private static let t0 = 1_791_000_000.0

    private static func call(_ id: Int, at: Double) -> JSONValue {
        ["id": .number(Double(id)), "role": "assistant", "content": "", "finish_reason": "tool_calls", "timestamp": .number(at),
         "tool_calls": [["id": .string("c\(id)"), "type": "function", "function": ["name": "terminal", "arguments": "{\"command\":\"ls\"}"]]]]
    }
    private static func result(_ id: Int, of call: Int, at: Double) -> JSONValue {
        ["id": .number(Double(id)), "role": "tool", "tool_call_id": .string("c\(call)"), "content": "{\"output\":\"ok\"}",
         "timestamp": .number(at)]
    }

    /// You asked about the porch lights and got an answer (seen). Later Otto asks Herald to check a door; Herald looks
    /// and answers Otto.
    private static var seen: [JSONValue] {
        [
            ["id": 1, "role": "user", "content": "Are the porch lights on a timer?", "timestamp": .number(t0 - 600)],
            ["id": 2, "role": "assistant", "content": "**Yes, the porch lights are on a timer again.** They go off at eleven.",
             "timestamp": .number(t0 - 590)],
        ]
    }
    private static var talk: [JSONValue] {
        [
            ["id": 3, "role": "user", "display_kind": "internal_notification", "timestamp": .number(t0 + 10),
             "content": "Message from 🤖 otto (@otto): Your morning report flagged the side door as open. Please check it now."],
            call(4, at: t0 + 12), result(5, of: 4, at: t0 + 14),
            ["id": 6, "role": "assistant", "content": "**The side door is still open.** It was last moved at four.",
             "timestamp": .number(t0 + 20)],
        ]
    }

    private static func news(_ rows: [JSONValue], since: Double, whole: Bool = false) -> Bool {
        BotSaidRules.newsForYou(rows: rows, since: since, own: herald, seats: seats, whole: whole)
    }

    @Test func aTalkBetweenBotsIsNotNewsForYou() {
        // Another bot's request, the work it took and the answer written back to that bot.
        #expect(!Self.news(Self.seen + Self.talk, since: Self.t0))
        // The same in the gateway's newest-first order.
        #expect(!Self.news((Self.seen + Self.talk).reversed(), since: Self.t0))
        // While the bot is still working on the request (no answer stored yet).
        #expect(!Self.news(Self.seen + Array(Self.talk.prefix(3)), since: Self.t0))
        // Nothing newer than what you saw.
        #expect(!Self.news(Self.seen, since: Self.t0))
    }

    @Test func whatIsWrittenToYouIsNews() {
        // The answer to your own question, unseen.
        #expect(Self.news(Self.seen, since: Self.t0 - 595))
        // A reply to you after the bots' talk.
        let after = Self.seen + Self.talk + [
            ["id": 7, "role": "user", "content": "Thanks. Lock it too.", "timestamp": .number(Self.t0 + 60)],
            ["id": 8, "role": "assistant", "content": "Locked.", "timestamp": .number(Self.t0 + 70)],
        ]
        #expect(Self.news(after, since: Self.t0))
        #expect(!Self.news(after, since: Self.t0 + 70))
        // A scheduled job's report.
        let job = Self.seen + [["id": 3, "role": "assistant", "content": "[Cron delivery: inbox-watch]\n1 new inbound email",
                                "timestamp": .number(Self.t0 + 5)]]
        #expect(Self.news(job, since: Self.t0))
        // A turn that began before you looked and ended after: its reply's own row is the new one.
        let long: [JSONValue] = Self.seen + [
            ["id": 3, "role": "user", "content": "Ship it.", "timestamp": .number(Self.t0 - 30)],
            Self.call(4, at: Self.t0 - 20), Self.result(5, of: 4, at: Self.t0 - 10),
            ["id": 6, "role": "assistant", "content": "Shipped.", "timestamp": .number(Self.t0 + 15)],
        ]
        #expect(Self.news(long, since: Self.t0))
    }

    @Test func whatCannotBeToldIsNews() {
        // No times on the rows.
        #expect(Self.news([["id": 1, "role": "assistant", "content": "Done."]], since: Self.t0))
        // Every row read is new, so older new rows may sit behind them: a dot, unless this is the whole chat.
        #expect(Self.news(Self.talk, since: Self.t0))
        #expect(!Self.news(Self.talk, since: Self.t0, whole: true))
        #expect(!Self.news([], since: Self.t0))
    }

    // MARK: The row's dot

    private static func store(_ client: BotsFakeGatewayClient) -> BotStore {
        var timing = BotStoreTiming.fast
        timing.readsBotSaid = true
        return BotStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing,
                        autoStart: true)
    }

    @Test func aBotThatOnlyAnsweredAnotherBotGetsNoDot() async throws {
        let client = BotsFakeGatewayClient()
        let chat = BotsTestBox(BotsTest.session("reg", resolved: "tip", preview: "They go off at eleven.", lastActive: Self.t0 - 590, count: 2))
        let tail = BotsTestBox<[JSONValue]>(Self.seen)
        client.on("profiles.list") { _ in BotsTest.profilesResult([BotsTest.row("herald", canonical: chat.value)]) }
        client.onREST { _, _, _, _ in
            let root: JSONValue = ["messages": .array(tail.value)]
            return try root.encoded()
        }
        let store = Self.store(client)
        #expect(await BotsTest.waitUntil { store.bot(named: "herald")?.preview?.contains("porch lights") == true })
        #expect(store.bot(named: "herald")?.unread == false)

        // Otto writes to Herald and Herald answers Otto: the chat moved, with nothing in it for you.
        tail.value += Self.talk
        chat.value = BotsTest.session("reg", resolved: "tip", preview: "The side door is still open.", lastActive: Self.t0 + 15, count: 6)
        let reads = client.restCalls.count
        await store.refresh()
        #expect(await BotsTest.waitUntil { client.restCalls.count > reads })
        try await Task.sleep(for: .milliseconds(80))
        #expect(store.bot(named: "herald")?.unread == false)

        // You ask Herald something from your Mac and it answers you: the dot.
        tail.value += [["id": 7, "role": "user", "content": "Is the side door shut now?", "timestamp": .number(Self.t0 + 280)],
                       ["id": 8, "role": "assistant", "content": "Not yet. It has been open all day.",
                        "timestamp": .number(Self.t0 + 300)]]
        chat.value = BotsTest.session("reg", resolved: "tip", preview: "Not yet.", lastActive: Self.t0 + 290, count: 8)
        await store.refresh()
        #expect(await BotsTest.waitUntil { store.bot(named: "herald")?.unread == true })
        store.stop()
        RosterDiskWriter.shared.flush()
    }

    @Test func aChatThatCannotBeReadKeepsItsDot() async throws {
        let client = BotsFakeGatewayClient()
        let chat = BotsTestBox(BotsTest.session("reg", resolved: "tip", preview: "They go off at eleven.", lastActive: Self.t0 - 590, count: 2))
        let fails = BotsTestBox(false)
        let seen = Self.seen
        client.on("profiles.list") { _ in BotsTest.profilesResult([BotsTest.row("herald", canonical: chat.value)]) }
        client.onREST { _, _, _, _ in
            if fails.value { throw URLError(.timedOut) }
            let root: JSONValue = ["messages": .array(seen)]
            return try root.encoded()
        }
        let store = Self.store(client)
        #expect(await BotsTest.waitUntil { store.bot(named: "herald")?.preview?.contains("porch lights") == true })
        #expect(store.bot(named: "herald")?.unread == false)

        fails.value = true
        chat.value = BotsTest.session("reg", resolved: "tip", preview: "The side door is still open.", lastActive: Self.t0 + 15, count: 6)
        await store.refresh()
        #expect(await BotsTest.waitUntil { store.bot(named: "herald")?.unread == true })
        store.stop()
        RosterDiskWriter.shared.flush()
    }

    // MARK: The waiting state

    private static func bot(stamp: Double) -> RosterProfile {
        RosterProfile(json: BotsTest.row("ivy", canonical: BotsTest.session("reg", resolved: "tip", preview: "hi", lastActive: stamp, count: 3)))!
    }

    @Test func aHeldBotWaitsForItsRead() {
        var state = BotUnreadState()
        state.reconcile([Self.bot(stamp: 100)]) { _ in false }
        state.reconcile([Self.bot(stamp: 150)], isVisible: { _ in false }, holds: { _ in true })
        #expect(!state.isUnread(Self.bot(stamp: 150)) && state.held("ivy") == 100)
        // It moves again before the read: still judged from where the wait began.
        state.reconcile([Self.bot(stamp: 180)], isVisible: { _ in false }, holds: { _ in true })
        #expect(state.held("ivy") == 100 && state.baselines["ivy"] == 180)
        // Only bot talk: no dot, and the wait is over.
        state.settle(Self.bot(stamp: 180), forYou: false)
        #expect(!state.isUnread(Self.bot(stamp: 180)) && state.held("ivy") == nil)
        // Something for you: the dot.
        state.reconcile([Self.bot(stamp: 200)], isVisible: { _ in false }, holds: { _ in true })
        state.settle(Self.bot(stamp: 200), forYou: true)
        #expect(state.isUnread(Self.bot(stamp: 200)) && state.held("ivy") == nil)
        // Settling a bot that isn't waiting marks nothing.
        var quiet = BotUnreadState()
        quiet.reconcile([Self.bot(stamp: 100)]) { _ in false }
        quiet.settle(Self.bot(stamp: 100), forYou: true)
        #expect(!quiet.isUnread(Self.bot(stamp: 100)))
    }

    @Test func openingTheChatEndsTheWait() {
        var state = BotUnreadState()
        state.reconcile([Self.bot(stamp: 100)]) { _ in false }
        state.reconcile([Self.bot(stamp: 150)], isVisible: { _ in false }, holds: { _ in true })
        state.reconcile([Self.bot(stamp: 160)], isVisible: { _ in true }, holds: { _ in true })
        #expect(state.held("ivy") == nil && !state.isUnread(Self.bot(stamp: 160)))
        // Leaving a chat seen through 170 moves a wait's baseline up to there.
        state.reconcile([Self.bot(stamp: 165)], isVisible: { _ in false }, holds: { _ in true })
        state.left("ivy", seenThrough: 170)
        #expect(state.held("ivy") == 172)
        // A state saved by an older build has no waits.
        let old = try? JSONDecoder().decode(BotUnreadState.self, from: Data(#"{"baselines":{"ivy":5},"markers":{}}"#.utf8))
        #expect(old?.baselines["ivy"] == 5 && old?.held("ivy") == nil)
    }
}
