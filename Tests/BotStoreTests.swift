import Foundation
import Testing
@testable import HermesHQNative

/// The roster pipeline, unread across rosters, and the Bot Chat lookup with a scripted gateway.
@Suite(.serialized) struct BotStoreTests {
    private func makeStore(_ client: BotsFakeGatewayClient, dir: URL = BotsTest.tempDirectory(), timing: BotStoreTiming = .fast,
                           autoStart: Bool = true) -> BotStore {
        BotStore(client: client, account: .botsTestAccount, cacheDirectory: dir, timing: timing, autoStart: autoStart)
    }

    // MARK: Pipeline (§3)

    @Test func paintsSlimThenFullThenCachesForNextLaunch() async throws {
        let full = try BotsFixture.json("demo-profiles-list")
        let slim = BotsTest.slimmed(full)
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { params in
            if params["include_sessions"]?.bool == false { return slim }
            try await Task.sleep(for: .milliseconds(200))
            return full
        }
        let dir = BotsTest.tempDirectory()
        var changes = 0
        let store = makeStore(client, dir: dir)
        store.onChange = { changes += 1 }
        #expect(store.phase == .none && store.bots.isEmpty)
        #expect(await BotsTest.waitUntil { store.phase == .slim })
        #expect(store.bots.count == 9)
        #expect(store.bots.allSatisfy { $0.preview == nil })          // the slim answer has no sessions yet
        // …but its rows carry their sections: a first sign-in paints sectioned (verification round 2).
        #expect(store.layout.sections.map(\.name) == ["Work", "Home"])
        #expect(await BotsTest.waitUntil { store.phase == .full })
        #expect(store.loadState == .ready)
        #expect(store.layout.tiles.map(\.id) == ["default", "deploys", "research"])
        #expect(store.layout.sections.map(\.name) == ["Work", "Home"])
        #expect(client.calls("profiles.list").map(\.timeout) == [.seconds(30), .seconds(120)])
        #expect(changes >= 2)
        store.stop()
        RosterDiskWriter.shared.flush()

        // Next launch: the last full roster paints synchronously in init, before any network.
        let offline = BotsFakeGatewayClient()
        let again = makeStore(offline, dir: dir, autoStart: false)
        #expect(again.phase == .cache)
        #expect(again.bots.map(\.id) == store.bots.map(\.id))
        #expect(again.bots.first { $0.id == "deploys" }?.preview?.hasPrefix("One overlap") == true)
        #expect(again.layout.sections.map(\.name) == ["Work", "Home"])
        #expect(offline.calls.isEmpty)
    }

    @Test func slimKeepsCachedPreviewsUntilTheFullAnswer() async throws {
        let full = try BotsFixture.json("demo-profiles-list")
        let dir = BotsTest.tempDirectory()
        let first = BotsFakeGatewayClient()
        first.on("profiles.list") { _ in full }
        let seed = makeStore(first, dir: dir)
        #expect(await BotsTest.waitUntil { seed.phase == .full })
        seed.stop()
        RosterDiskWriter.shared.flush()

        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { params in
            if params["include_sessions"]?.bool == false { return BotsTest.slimmed(full) }
            try await Task.sleep(for: .seconds(30))
            return full
        }
        let store = makeStore(client, dir: dir)
        #expect(store.phase == .cache)
        #expect(await BotsTest.waitUntil { store.phase == .slim })
        #expect(store.bots.first { $0.id == "inbox" }?.preview?.hasPrefix("14 new overnight") == true)
        #expect(store.bots.allSatisfy { $0.canonicalSessionId != nil })
        store.stop()
    }

    @Test func timeoutIsNotRetriedAndReadsAsBusy() async throws {
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { params in
            if params["include_sessions"]?.bool == false { throw RPCError(code: -1, message: "request timed out after 30s: profiles.list", data: nil) }
            throw RPCError(code: -1, message: "request timed out after 120s: profiles.list", data: nil)
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil {
            if case .failed(let failure) = store.loadState { return failure.busy } else { return false }
        })
        try await Task.sleep(for: .milliseconds(200))
        #expect(client.calls("profiles.list").filter { $0.params["include_sessions"] == nil }.count == 1)
        #expect(store.phase == .none)
        store.stop()
    }

    @Test func otherErrorsRetryTwiceThenWaitForThePoll() async throws {
        let full = BotsTest.profilesResult([BotsTest.row("ivy", canonical: BotsTest.session("c", lastActive: 1))])
        let attempts = BotsTestBox(0)
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { params in
            if params["include_sessions"]?.bool == false { return BotsTest.slimmed(full) }
            let n = attempts.mutate { $0 += 1; return $0 }
            if n < 3 { throw RPCError(code: 5061, message: "state.db is locked", data: nil) }
            return full
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        #expect(attempts.value == 3)
        #expect(store.loadState == .ready)
        store.stop()

        let failing = BotsFakeGatewayClient()
        failing.on("profiles.list") { _ in throw RPCError(code: 5061, message: "boom", data: nil) }
        let broken = makeStore(failing)
        #expect(await BotsTest.waitUntil { if case .failed(let f) = broken.loadState { return !f.busy } else { return false } })
        #expect(failing.calls("profiles.list").filter { $0.params["include_sessions"] == nil }.count == 3)
        broken.stop()
    }

    @Test func makesNoGatewayWrites() async throws {
        let full = try BotsFixture.json("demo-profiles-list")
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in full }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        await store.refresh()
        #expect(Set(client.calls.map(\.method)) == ["profiles.list"])
        #expect(client.restCalls.isEmpty)
        store.stop()
    }

    /// [perf] A poll whose answer matches the last one notifies nobody; a details-only change (the chat's message
    /// count) still does, and a pull always does (it ends the spinner).
    @Test func anIdenticalPollStaysQuietButChangesAndPullsNotify() async throws {
        let count = BotsTestBox(4)
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in
            BotsTest.profilesResult([BotsTest.row("ivy", canonical: BotsTest.session("c", lastActive: 1, count: count.value))])
        }
        func fullReads() -> Int { client.calls("profiles.list").filter { $0.params["include_sessions"] == nil }.count }
        var timing = BotStoreTiming.fast
        timing.onListPoll = .milliseconds(120)
        timing.offListPoll = .milliseconds(120)
        timing.pollCostFactor = 0
        let store = makeStore(client, timing: timing)
        var changes = 0
        store.onChange = { changes += 1 }
        #expect(await BotsTest.waitUntil { store.phase == .full && fullReads() == 1 })
        let settled = changes
        #expect(await BotsTest.waitUntil { fullReads() >= 3 })
        #expect(changes == settled, "identical polls notify nobody")
        count.value = 5                                                   // only the row's details move
        #expect(await BotsTest.waitUntil { changes > settled })
        let afterChange = changes
        await store.refresh()                                             // a pull with the same answer
        #expect(changes > afterChange)
        store.stop()
    }

    /// [perf] A local row edit the next poll confirms still reaches the roster cache: that poll's answer matches the
    /// patched rows, but an offline launch must not paint the old description.
    @Test func aLocalEditThePollConfirmsIsCached() async throws {
        let description = BotsTestBox("old")
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in
            BotsTest.profilesResult([BotsTest.row("ivy", canonical: BotsTest.session("c", lastActive: 1), description: description.value)])
        }
        func fullReads() -> Int { client.calls("profiles.list").filter { $0.params["include_sessions"] == nil }.count }
        var timing = BotStoreTiming.fast
        timing.onListPoll = .milliseconds(120)
        timing.offListPoll = .milliseconds(120)
        timing.pollCostFactor = 0
        let dir = BotsTest.tempDirectory()
        let store = makeStore(client, dir: dir, timing: timing)
        #expect(await BotsTest.waitUntil { store.phase == .full && fullReads() == 1 })
        description.value = "new"                                        // the save lands on the gateway…
        store.patchRow("ivy") { $0["description"] = "new" }              // …and on the held row
        let confirmed = fullReads()
        #expect(await BotsTest.waitUntil { fullReads() > confirmed })
        try await Task.sleep(for: .milliseconds(50))
        store.stop()
        RosterDiskWriter.shared.flush()

        let again = makeStore(BotsFakeGatewayClient(), dir: dir, autoStart: false)
        #expect(again.phase == .cache)
        #expect(again.rawRows.first?["description"]?.string == "new")
    }

    /// [perf] A read that fails and then returns the same rows still notifies: the stale card must clear.
    @Test func recoveryWithIdenticalRowsNotifies() async throws {
        let full = BotsTest.profilesResult([BotsTest.row("ivy", canonical: BotsTest.session("c", lastActive: 1))])
        let failing = BotsTestBox(false)
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in
            if failing.value { throw RPCError(code: 5061, message: "boom", data: nil) }
            return full
        }
        var timing = BotStoreTiming.fast
        timing.onListPoll = .milliseconds(120)
        timing.offListPoll = .milliseconds(120)
        timing.pollCostFactor = 0
        let store = makeStore(client, timing: timing)
        var changes = 0
        store.onChange = { changes += 1 }
        #expect(await BotsTest.waitUntil { store.phase == .full })
        failing.value = true
        #expect(await BotsTest.waitUntil { if case .failed = store.loadState { return true } else { return false } })
        let failed = changes
        failing.value = false
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(changes > failed)
        store.stop()
    }

    @Test func pollsOnTheListAndPausesInBackground() async throws {
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in BotsTest.profilesResult([BotsTest.row("ivy")]) }
        var timing = BotStoreTiming.fast
        timing.onListPoll = .milliseconds(80)
        let store = makeStore(client, timing: timing)
        store.setListVisible(true)
        func fullReads() -> Int { client.calls("profiles.list").filter { $0.params["include_sessions"] == nil }.count }
        #expect(await BotsTest.waitUntil { fullReads() >= 4 })
        store.appDidEnterBackground()
        try await Task.sleep(for: .milliseconds(50))
        let paused = fullReads()
        try await Task.sleep(for: .milliseconds(400))
        #expect(fullReads() <= paused + 1)
        store.appDidBecomeActive()
        #expect(await BotsTest.waitUntil { fullReads() > paused + 1 })
        store.stop()
    }

    @Test func pullToRefreshJoinsTheReadInFlight() async throws {
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in
            try await Task.sleep(for: .milliseconds(150))
            return BotsTest.profilesResult([BotsTest.row("ivy")])
        }
        let store = makeStore(client, autoStart: false)
        store.start()
        try await Task.sleep(for: .milliseconds(120))               // slim wait over; the full read is out
        async let one: Void = store.refresh()
        async let two: Void = store.refresh()
        _ = await (one, two)
        #expect(client.calls("profiles.list").filter { $0.params["include_sessions"] == nil }.count == 1)
        store.stop()
    }

    // MARK: Unread (§6.7)

    @Test func unreadAcrossRostersMarkReadAndPersistence() async throws {
        let stamp = BotsTestBox(100.0)
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in
            BotsTest.profilesResult([BotsTest.row("ivy", canonical: BotsTest.session("reg", resolved: "tip", lastActive: stamp.value)),
                                     BotsTest.row("idle", canonical: BotsTest.session("i", lastActive: 50))])
        }
        let dir = BotsTest.tempDirectory()
        let store = makeStore(client, dir: dir)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        #expect(store.bots.allSatisfy { !$0.unread })                // first sight: baseline only

        stamp.value = 200
        await store.refresh()
        #expect(store.bot(named: "ivy")?.unread == true)
        #expect(store.bot(named: "idle")?.unread == false)
        #expect(store.unreadCount == 1)

        store.markRead(store.bot(named: "ivy")!)
        #expect(store.bot(named: "ivy")?.unread == false)
        await store.refresh()
        #expect(store.bot(named: "ivy")?.unread == false)            // unchanged poll stays read

        // A bot taken before newer activity arrived is not marked read by it.
        stamp.value = 300
        await store.refresh()
        let stale = store.bot(named: "ivy")!
        stamp.value = 400
        await store.refresh()
        store.markRead(stale)
        #expect(store.bot(named: "ivy")?.unread == true)
        store.markRead(store.bot(named: "ivy")!)
        #expect(store.bot(named: "ivy")?.unread == false)

        // The chat on screen is acknowledged by the roster instead of marked.
        store.setFocusedChat(profile: "ivy", sessionId: "tip")
        stamp.value = 500
        await store.refresh()
        #expect(store.bot(named: "ivy")?.unread == false)
        store.setFocusedChat(profile: nil, sessionId: nil)

        // Mark as Unread is device-local and survives a relaunch.
        store.markUnread(store.bot(named: "ivy")!)
        #expect(store.unreadCount == 1)
        store.stop()
        RosterDiskWriter.shared.flush()
        let again = makeStore(BotsFakeGatewayClient(), dir: dir, autoStart: false)
        #expect(again.bot(named: "ivy")?.unread == true)
        #expect(Set(client.calls.map(\.method)) == ["profiles.list"])
    }

    @Test func hiddenBotsAreNotCounted() async throws {
        let stamp = BotsTestBox(100.0)
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in
            BotsTest.profilesResult([BotsTest.row("ghosty", canonical: BotsTest.session("g", lastActive: stamp.value), meta: ["hidden": true])])
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        stamp.value = 200
        await store.refresh()
        #expect(store.bot(named: "ghosty")?.unread == true)
        #expect(store.unreadCount == 0)
        #expect(store.layout.hidden.map(\.id) == ["ghosty"])
        store.stop()
    }

    @Test func workingStatusComesFromTheChatEngine() async throws {
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in BotsTest.profilesResult([BotsTest.row("ivy", canonical: BotsTest.session("c", preview: "Done", lastActive: 1))]) }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        let bot = store.bot(named: "ivy")!
        #expect(store.secondLine(for: bot).text == "Done")
        store.setWorkingChats("ivy", ["c"])
        #expect(store.bot(named: "ivy")?.isWorking == true)
        #expect(store.secondLine(for: store.bot(named: "ivy")!).text == "Working…")
        store.setWorkingChats("ivy", [])
        #expect(store.bot(named: "ivy")?.isWorking == false)
        store.stop()
    }

    /// [toolnow] A working bot's row names its Bot Chat's step; a side chat's step stays on its Sessions row.
    @Test func workingRowNamesItsStep() async throws {
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in BotsTest.profilesResult([BotsTest.row("ivy", canonical: BotsTest.session("c", preview: "Done", lastActive: 1))]) }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        store.setSteps(["ivy": ["c": "reading package.json"]])
        #expect(store.bot(named: "ivy")?.step == nil)                       // not working: no step
        store.setWorkingChats("ivy", ["c"])
        #expect(store.bot(named: "ivy")?.step == "reading package.json")
        #expect(store.secondLine(for: store.bot(named: "ivy")!).text == "Reading package.json…")
        store.setSteps(["ivy": ["side": "running npm test"]])
        #expect(store.bot(named: "ivy")?.step == nil)
        #expect(store.secondLine(for: store.bot(named: "ivy")!).text == "Working…")
        store.setSteps(["ivy": ["": "running npm test"]])                   // a Bot Chat not stored yet
        #expect(store.bot(named: "ivy")?.step == "running npm test")
        store.setWorkingChats("ivy", [])
        #expect(store.bot(named: "ivy")?.step == nil)
        #expect(store.secondLine(for: store.bot(named: "ivy")!).text == "Done")
        store.stop()
    }

    /// Like the desktop: a busy side chat says so on its Sessions row, not on the bot (owner, build 275: Hermes
    /// looked busy while his Bot Chat sat idle and a Pokémon chat worked).
    @Test func onlyTheBotChatMakesTheBotWork() async throws {
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in BotsTest.profilesResult([BotsTest.row("ivy", canonical: BotsTest.session("c", preview: "Done", lastActive: 1))]) }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        store.setWorkingChats("ivy", ["side"])
        #expect(store.bot(named: "ivy")?.isWorking == false)
        #expect(store.secondLine(for: store.bot(named: "ivy")!).text == "Done")
        store.setWorkingChats("ivy", ["side", "c"])
        #expect(store.bot(named: "ivy")?.isWorking == true)
        store.setWorkingChats("ivy", ["side"])
        #expect(store.bot(named: "ivy")?.isWorking == false)
        store.setWorkingChats("ivy", [""])          // a Bot Chat being made has no stored id yet
        #expect(store.bot(named: "ivy")?.isWorking == true)
        store.stop()
    }

    // MARK: Opening a bot (§8)

    private func storeWith(_ rows: [JSONValue], _ client: BotsFakeGatewayClient) async -> BotStore {
        client.on("profiles.list") { _ in BotsTest.profilesResult(rows) }
        let store = makeStore(client)
        _ = await BotsTest.waitUntil { store.phase == .full }
        return store
    }

    @Test func knownChatOpensAtOnceWithItsTip() async throws {
        let client = BotsFakeGatewayClient()
        let store = await storeWith([BotsTest.row("ivy", canonical: BotsTest.session("reg", resolved: "tip", lastActive: 1))], client)
        let id = try await store.chatSessionId(for: store.bot(named: "ivy")!)
        #expect(id == "tip")
        #expect(store.bot(named: "ivy")?.canonicalSessionId == "tip")
        #expect(client.calls("session.list").isEmpty && client.calls("session.create").isEmpty)
        store.stop()
    }

    @Test func noCanonicalLooksUpFirst() async throws {
        let client = BotsFakeGatewayClient()
        client.on("session.list") { _ in
            ["sessions": [["id": "side", "title": "Planning"], ["id": "reg", "resolved_id": "tip", "title": "Bot Chat"]]]
        }
        let store = await storeWith([BotsTest.row("ivy")], client)
        let id = try await store.chatSessionId(for: store.bot(named: "ivy")!)
        #expect(id == "tip")
        let params = try #require(client.calls("session.list").first?.params)
        #expect(params == ["profile": "ivy", "title": "Bot Chat", "limit": 200, "include_hidden": true])
        #expect(client.calls("session.create").isEmpty)
        store.stop()
    }

    @Test func confirmedAbsenceMintsOnceAndTitlesTheRow() async throws {
        let client = BotsFakeGatewayClient()
        client.on("session.list") { _ in ["sessions": []] }
        client.on("session.create") { _ in
            try await Task.sleep(for: .milliseconds(50))
            return ["session_id": "ab12cd34", "stored_session_id": "20261009_120000_new", "message_count": 0, "messages": []]
        }
        client.on("session.title") { _ in ["title": "Bot Chat"] }
        let store = await storeWith([BotsTest.row("ivy")], client)
        let bot = store.bot(named: "ivy")!
        async let a = store.chatSessionId(for: bot)
        async let b = store.chatSessionId(for: bot)
        let (first, second) = try await (a, b)
        #expect(first == "20261009_120000_new" && second == first)
        #expect(client.calls("session.create").count == 1)
        #expect(client.calls("session.create").first?.params == ["profile": "ivy", "title": "Bot Chat", "hidden": true, "follow_profile_config": true, "source": "desktop"])
        #expect(client.calls("session.title").first?.params == ["session_id": "ab12cd34", "title": "Bot Chat", "profile": "ivy"])
        #expect(store.bot(named: "ivy")?.canonicalSessionId == "20261009_120000_new")
        // The next tap reuses it without asking again.
        let creates = client.calls("session.create").count, lookups = client.calls("session.list").count
        #expect(try await store.chatSessionId(for: store.bot(named: "ivy")!) == first)
        #expect(client.calls("session.create").count == creates && client.calls("session.list").count == lookups)
        store.stop()
    }

    @Test func titleClashAdoptsTheWinner() async throws {
        let lookups = BotsTestBox(0)
        let client = BotsFakeGatewayClient()
        client.on("session.list") { _ in
            // Empty for the tap's lookup and the adopt-before-mint lookup; the other device's chat shows after the clash.
            let n = lookups.mutate { $0 += 1; return $0 }
            return n <= 2 ? ["sessions": []] : ["sessions": [["id": "winner", "resolved_id": "winner-tip", "title": "Bot Chat"]]]
        }
        client.on("session.create") { _ in ["session_id": "ab12cd34", "stored_session_id": "mine"] }
        client.on("session.title") { _ in throw RPCError(code: 4009, message: "Title 'Bot Chat' is already in use", data: nil) }
        let store = await storeWith([BotsTest.row("ivy")], client)
        #expect(try await store.chatSessionId(for: store.bot(named: "ivy")!) == "winner-tip")
        #expect(client.calls("session.create").count == 1 && client.calls("session.title").count == 1)
        #expect(lookups.value == 3)
        store.stop()
    }

    @Test func lookupFailsClosed() async throws {
        let client = BotsFakeGatewayClient()
        client.on("session.list") { _ in ["sessions": []] }
        let store = await storeWith([BotsTest.row("ivy", canonical: BotsTest.session("reg", lastActive: 1)),
                                     BotsTest.row("pip")], client)
        // The roster named a Bot Chat but the registry answered empty: unconfirmed, never mint.
        await #expect(throws: BotChatError.registryUnconfirmed(bot: "Ivy")) {
            try await store.lookupChatSessionId(for: store.bot(named: "ivy")!)
        }
        // An RPC error is never read as "no Bot Chat".
        client.on("session.list") { _ in throw RPCError(code: 5006, message: "profile backend restarting", data: nil) }
        await #expect(throws: BotChatError.registryCheckFailed(bot: "Pip", detail: "profile backend restarting")) {
            try await store.chatSessionId(for: store.bot(named: "pip")!)
        }
        #expect(client.calls("session.create").isEmpty)
        #expect(BotChatError.registryUnconfirmed(bot: "Ivy").localizedDescription == "Couldn’t confirm Ivy's Bot Chat registry — not starting a new chat")
        store.stop()
    }

    @Test func registryReplacementOnlyForADifferentRow() async throws {
        let answer = BotsTestBox<JSONValue>(["sessions": [["id": "other", "resolved_id": "other-tip", "title": "Bot Chat"]]])
        let client = BotsFakeGatewayClient()
        client.on("session.list") { _ in answer.value }
        let store = await storeWith([BotsTest.row("ivy", canonical: BotsTest.session("reg", resolved: "tip", lastActive: 1))], client)
        let bot = store.bot(named: "ivy")!
        #expect(await store.registryReplacement(for: bot, openedId: "tip") == "other-tip")
        answer.value = ["sessions": [["id": "reg", "resolved_id": "newer-tip", "root_title": "Bot Chat", "title": "Bot Chat (2)"]]]
        #expect(await store.registryReplacement(for: bot, openedId: "tip") == nil)
        answer.value = ["sessions": []]
        #expect(await store.registryReplacement(for: bot, openedId: "tip") == nil)
        store.stop()
    }

    /// Instant first draw: a 60-bot roster with heads paints from disk inside init.
    @Test func cachedPaintOfABigRosterIsFast() async throws {
        let head: JSONValue = ["v": 6, "theme": "shape", "form": "blob", "look": "slits", "color": "coral", "seed": 17]
        let rows: [JSONValue] = (0..<60).map { i in
            var o = BotsTest.row("bot-\(i)", display: "Bot \(i)",
                                 canonical: BotsTest.session("c\(i)", resolved: "t\(i)", preview: "**Done** with item \(i): see `notes.md`",
                                                             lastActive: 1_791_000_000 + Double(i)),
                                 meta: ["pinned": .bool(i < 4), "sectionId": .string("sec-\(i % 5)"), "sectionName": .string("Section \(i % 5)")],
                                 description: "Role \(i)").object!
            o["ui_meta"] = ["hermes-bots": o["ui_meta"]!["hermes-bots"]!, "dispatch-head": head]
            return .object(o)
        }
        let dir = BotsTest.tempDirectory()
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in BotsTest.profilesResult(rows) }
        let seed = makeStore(client, dir: dir)
        #expect(await BotsTest.waitUntil { seed.phase == .full })
        seed.stop()
        RosterDiskWriter.shared.flush()
        let started = ContinuousClock.now
        let store = makeStore(BotsFakeGatewayClient(), dir: dir, autoStart: false)
        let elapsed = ContinuousClock.now - started
        print("cached paint of 60 bots in init: \(elapsed)")
        #expect(store.bots.count == 60 && store.layout.tiles.count == 4 && store.layout.sections.count == 5)
        #expect(elapsed < .milliseconds(30))
    }

    // MARK: Review round 2: writes, confirmation, settle, lifecycle

    /// Spec 02 §12.5: the read-only switch refuses the mint too.
    @Test func readOnlyGatewayNeverMints() async throws {
        let client = BotsFakeGatewayClient()
        client.on("session.list") { _ in ["sessions": []] }
        client.on("session.create") { _ in Issue.record("read-only gateway must not be written"); return [:] }
        client.on("session.title") { _ in Issue.record("read-only gateway must not be written"); return [:] }
        let store = await storeWith([BotsTest.row("ivy")], client)
        store.readOnlyGateway = true
        await #expect(throws: BotChatError.readOnly(bot: "Ivy")) {
            try await store.chatSessionId(for: store.bot(named: "ivy")!)
        }
        #expect(client.calls("session.create").isEmpty && client.calls("session.title").isEmpty)
        // A Bot Chat the registry knows still opens.
        client.on("session.list") { _ in ["sessions": [["id": "reg", "title": "Bot Chat"]]] }
        #expect(try await store.chatSessionId(for: store.bot(named: "ivy")!) == "reg")
        store.stop()
    }

    /// A cached or slim row carries no sessions: an empty lookup during those phases never mints by itself.
    @Test func slimOnlyRowNeverMintsUnconfirmed() async throws {
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { params in
            if params["include_sessions"]?.bool == false { return BotsTest.profilesResult([BotsTest.row("ivy")]) }
            try await Task.sleep(for: .seconds(30))                    // the owner's 18–107 s full read
            return BotsTest.profilesResult([BotsTest.row("ivy")])
        }
        client.on("session.list") { _ in ["sessions": []] }              // e.g. a backend mid-restart
        client.on("session.create") { _ in ["session_id": "ab12cd34", "stored_session_id": "forked"] }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.phase == .slim })
        await #expect(throws: BotChatError.registryUnconfirmed(bot: "Ivy")) {
            try await store.chatSessionId(for: store.bot(named: "ivy")!)
        }
        await #expect(throws: BotChatError.registryUnconfirmed(bot: "Ivy")) {
            try await store.lookupChatSessionId(for: store.bot(named: "ivy")!)
        }
        #expect(client.calls("session.create").isEmpty)
        // Only one full read was ever asked for (the tap joined the one in flight).
        #expect(client.calls("profiles.list").filter { $0.params["include_sessions"] == nil }.count == 1)
        store.stop()
    }

    /// The tap waits for the full answer: it names the Bot Chat (open it) or confirms there is none (mint).
    @Test func slimTapWaitsForTheFullAnswer() async throws {
        for named in [true, false] {
            let client = BotsFakeGatewayClient()
            let canonical = named ? BotsTest.session("reg", resolved: "tip", lastActive: 5) : nil
            client.on("profiles.list") { params in
                if params["include_sessions"]?.bool == false { return BotsTest.profilesResult([BotsTest.row("ivy")]) }
                try await Task.sleep(for: .milliseconds(150))
                return BotsTest.profilesResult([BotsTest.row("ivy", canonical: canonical)])
            }
            client.on("session.list") { _ in ["sessions": []] }
            client.on("session.create") { _ in ["session_id": "ab12cd34", "stored_session_id": "new-chat"] }
            client.on("session.title") { _ in ["title": "Bot Chat"] }
            let store = makeStore(client)
            #expect(await BotsTest.waitUntil { store.phase >= .slim })
            let id = try await store.chatSessionId(for: store.bot(named: "ivy")!)
            #expect(id == (named ? "tip" : "new-chat"))
            #expect(client.calls("session.create").count == (named ? 0 : 1))
            store.stop()
        }
    }

    /// §3 step 3: a full read that starts while the socket is still connecting waits for it to open, then 2 s more.
    @Test func fullReadSettlesAfterTheSocketOpens() async throws {
        let client = BotsFakeGatewayClient(state: .connecting)
        client.on("profiles.list") { _ in BotsTest.profilesResult([BotsTest.row("ivy")]) }
        var timing = BotStoreTiming.fast
        timing.settle = .milliseconds(300)
        let store = makeStore(client, timing: timing)
        #expect(await BotsTest.waitUntil { store.phase == .slim })
        try await Task.sleep(for: .milliseconds(150))
        #expect(client.calls("profiles.list").filter { $0.params["include_sessions"] == nil }.isEmpty)
        let opened = ContinuousClock.now
        client.setState(.ready)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        let full = try #require(client.calls("profiles.list").first { $0.params["include_sessions"] == nil })
        #expect(full.at - opened >= .milliseconds(300))
        // A reconnect re-arms the settle.
        client.setState(.reconnecting(attempt: 1))
        try await Task.sleep(for: .milliseconds(30))
        let reopened = ContinuousClock.now
        client.setState(.ready)
        await store.refresh()
        let second = try #require(client.calls("profiles.list").filter { $0.params["include_sessions"] == nil }.last)
        #expect(second.at - reopened >= .milliseconds(300))
        store.stop()
    }

    /// §3 step 4: a read that falls due while a chat is opening waits for it (at most `openWait`).
    @Test func fullReadWaitsForAnOpeningChat() async throws {
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in BotsTest.profilesResult([BotsTest.row("ivy")]) }
        var timing = BotStoreTiming.fast
        timing.openWait = .milliseconds(400)
        let store = makeStore(client, timing: timing)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        func fullReads() -> [BotsFakeGatewayClient.Call] { client.calls("profiles.list").filter { $0.params["include_sessions"] == nil } }

        // The open finishes first: the read goes right after it.
        store.noteChatOpening(true)
        let asked = ContinuousClock.now
        let refresh = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(fullReads().count == 1)
        store.noteChatOpening(false)
        await refresh.value
        let afterOpen = try #require(fullReads().last).at - asked
        #expect(afterOpen >= .milliseconds(150) && afterOpen < .milliseconds(380))

        // An open that never reports back holds the read for `openWait` only.
        store.noteChatOpening(true)
        let asked2 = ContinuousClock.now
        await store.refresh()
        #expect(try #require(fullReads().last).at - asked2 >= .milliseconds(400))
        store.noteChatOpening(false)
        store.stop()
    }

    /// A gateway that comes back after a failed load is read at once, not at the next poll.
    @Test func gatewayReadyRefreshesAfterAFailure() async throws {
        let healthy = BotsTestBox(false)
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { params in
            guard healthy.value else { throw RPCError(code: 5061, message: "gateway unavailable", data: nil) }
            return BotsTest.profilesResult([BotsTest.row("ivy")])
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { if case .failed = store.loadState { return true } else { return false } })
        healthy.value = true
        client.emit("gateway.ready", payload: ["change_events": true])
        #expect(await BotsTest.waitUntil { store.phase == .full && store.loadState == .ready })
        store.stop()
    }

    /// A cancelled read that finishes late must not clear its successor's single-flight slot (§2.1.1 rule 2).
    @Test func stopThenStartKeepsOneFullReadInFlight() async throws {
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { params in
            if params["include_sessions"]?.bool == false { return BotsTest.profilesResult([BotsTest.row("ivy")]) }
            await botsUncancellableSleep(.milliseconds(600))
            return BotsTest.profilesResult([BotsTest.row("ivy")])
        }
        func fullReads() -> Int { client.calls("profiles.list").filter { $0.params["include_sessions"] == nil }.count }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { fullReads() == 1 })
        try await Task.sleep(for: .milliseconds(200))
        store.stop()
        store.start()
        #expect(await BotsTest.waitUntil { fullReads() == 2 })
        try await Task.sleep(for: .milliseconds(500))                     // the first read has ended (cancelled); the second has not
        #expect(store.isRefreshing)
        await store.refresh()                                            // joins the second read
        #expect(fullReads() == 2)
        #expect(store.phase == .full)
        store.stop()
    }

    /// The user's own exchange is not read as unseen activity once they leave the chat.
    @Test func leavingAChatLeavesNoDot() async throws {
        let stamp = BotsTestBox(1_791_000_000.0)
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in
            BotsTest.profilesResult([BotsTest.row("ivy", canonical: BotsTest.session("reg", resolved: "tip", lastActive: stamp.value))])
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        store.setFocusedChat(profile: "ivy", sessionId: "tip")
        // Messages go back and forth with no roster read while the chat is on screen.
        stamp.value = 1_791_000_100
        store.setFocusedChat(profile: nil, sessionId: nil, seenThrough: Date(timeIntervalSince1970: 1_791_000_099.5))
        await store.refresh()                                            // back on the list
        #expect(store.bot(named: "ivy")?.unread == false)
        #expect(store.unreadCount == 0)
        // A reply after the user left still lights the dot.
        stamp.value = 1_791_000_200
        await store.refresh()
        #expect(store.bot(named: "ivy")?.unread == true)
        // A side chat of the bot does not move its Bot Chat's baseline.
        store.markRead(store.bot(named: "ivy")!)
        store.setFocusedChat(profile: "ivy", sessionId: "side-chat")
        stamp.value = 1_791_000_300
        store.setFocusedChat(profile: nil, sessionId: nil, seenThrough: Date(timeIntervalSince1970: 1_791_000_400))
        await store.refresh()
        #expect(store.bot(named: "ivy")?.unread == true)
        store.stop()
    }

    /// A pin made on another device shows from the cached/slim row's own meta before the full answer lands.
    @Test func rowMetaBeatsTheDeviceSnapshotBeforeTheFullAnswer() async throws {
        let dir = BotsTest.tempDirectory()
        let seedClient = BotsFakeGatewayClient()
        seedClient.on("profiles.list") { _ in BotsTest.profilesResult([BotsTest.row("ivy", meta: ["pinned": false, "title": "Ivy"])]) }
        let seed = makeStore(seedClient, dir: dir)
        #expect(await BotsTest.waitUntil { seed.phase == .full })
        seed.stop()
        RosterDiskWriter.shared.flush()

        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { params in
            if params["include_sessions"]?.bool == false { return BotsTest.profilesResult([BotsTest.row("ivy", meta: ["pinned": true, "title": "Ivy"])]) }
            try await Task.sleep(for: .seconds(30))
            return BotsTest.profilesResult([])
        }
        let store = makeStore(client, dir: dir)
        #expect(store.bot(named: "ivy")?.pinned == false)
        #expect(await BotsTest.waitUntil { store.phase == .slim })
        #expect(store.bot(named: "ivy")?.pinned == true)
        #expect(store.layout.tiles.map(\.id) == ["ivy"])
        store.stop()
    }

    /// A rebuild for a working/unread flip reuses the worked-out previews.
    @Test func rebuildsReuseThePreviews() async throws {
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in
            BotsTest.profilesResult([BotsTest.row("ivy", canonical: BotsTest.session("c", preview: "**Done** with `x`", lastActive: 1))])
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        let before = store.secondLine(for: store.bot(named: "ivy")!)
        store.setWorkingChats("ivy", ["c"])
        store.setWorkingChats("ivy", [])
        #expect(store.secondLine(for: store.bot(named: "ivy")!) == before)
        #expect(before.text == "Done with x")
        // A new model label recomputes them.
        store.modelLabel = { "Label(\($0))" }
        #expect(store.secondLine(for: store.bot(named: "ivy")!).text == "Done with x")
        store.stop()
    }

    @Test func stopEndsSubscriptions() async throws {
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in BotsTest.profilesResult([BotsTest.row("ivy")]) }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.phase == .full && client.subscriberCount == 1 })
        store.stop()
        #expect(await BotsTest.waitUntil { client.subscriberCount == 0 })
    }
}
