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
}
