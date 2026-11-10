import Foundation
import Testing
@testable import HermesHQNative

/// [perf-returns] The reconnect's short top page (docs/spec/3x-sessions.md §11.5): the merge rule, when the store reads
/// it instead of the full list, the owed full read, and the phone log's connect line.
@Suite(.serialized) struct SessionTopPageTests {
    // MARK: The merge rule

    private func row(_ id: String, _ recency: Double, profile: String = "ivy", title: String? = nil, pinned: Bool = false) -> SidebarSessionRow {
        SidebarSessionRow(id: id, profile: profile, title: title ?? "Chat \(id)", lastActive: recency, messageCount: 2, pinned: pinned)
    }

    private func ids(_ rows: [SidebarSessionRow]) -> [String] { rows.map(\.id) }

    @Test func aShortSliceIsTheWholeSlice() {
        let old = [row("a", 600), row("b", 500), row("c", 400)]
        #expect(ids(SidebarTopPage.merge(old, page: [row("b", 700)], limit: 3)) == ["b"])
        #expect(SidebarTopPage.merge(old, page: [], limit: 3).isEmpty)
    }

    @Test func insertsAndMovesUpAndKeepsTheDeepRows() {
        let old = [row("r1", 600), row("r2", 500), row("r3", 400), row("r4", 300), row("r5", 200), row("r6", 100)]
        // A new chat, and r4 moved to the top with a new title; the floor is r1's 600.
        let page = [row("new", 800), row("r4", 700, title: "Renamed"), row("r1", 600)]
        let merged = SidebarTopPage.merge(old, page: page, limit: 3)
        #expect(ids(merged) == ["new", "r4", "r1", "r2", "r3", "r5", "r6"])
        #expect(merged.first { $0.id == "r4" }?.title == "Renamed")
        #expect(merged.filter { $0.id == "r4" }.count == 1)
    }

    @Test func dropsRowsGoneFromTheTop() {
        // r2 (500) sat above the floor (r3's 400) and the page left it out: archived, deleted or moved. r4 is deeper.
        let old = [row("r1", 600), row("r2", 500), row("r3", 400), row("r4", 300)]
        let merged = SidebarTopPage.merge(old, page: [row("r1", 600), row("r3", 400)], limit: 2)
        #expect(ids(merged) == ["r1", "r3", "r4"])
        // A row exactly at the floor that the page left out goes too.
        let tie = SidebarTopPage.merge([row("x", 400), row("deep", 100)], page: [row("r1", 600), row("r3", 400)], limit: 2)
        #expect(ids(tie) == ["r1", "r3", "deep"])
    }

    @Test func pinsComeBackWithThePage() {
        // The window is x and y (floor 800); p is a pinned row past it, as the gateway back-fills pins.
        let old = [row("x", 850), row("p", 100, pinned: true), row("q", 150, pinned: true), row("deep", 120)]
        let page = [row("x", 900), row("y", 800), row("p", 100, pinned: true)]
        let merged = SidebarTopPage.merge(old, page: page, limit: 2)
        #expect(ids(merged) == ["x", "y", "q", "deep", "p"])
        #expect(merged.first { $0.id == "p" }?.pinned == true)
        #expect(merged.first { $0.id == "q" }?.pinned == false)                    // unpinned elsewhere: kept, unpinned
    }

    @Test func rowsAreKeyedByProfileToo() {
        let old = [row("a", 600, profile: "ivy"), row("a", 100, profile: "kim")]
        let merged = SidebarTopPage.merge(old, page: [row("a", 700, profile: "ivy"), row("b", 650)], limit: 2)
        #expect(merged.map { "\($0.profile)/\($0.id)" } == ["ivy/a", "ivy/b", "kim/a"])
    }

    // MARK: The store

    private func makeStore(_ client: BotsFakeGatewayClient, timing: SessionStoreTiming = .fast) -> SessionStore {
        SessionStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing)
    }

    nonisolated private static func srow(_ id: String, lastActive: Double, title: String? = nil, unread: Bool = false,
                                         pinned: Bool = false) -> JSONValue {
        ["id": .string(id), "profile": "ivy", "title": .string(title ?? "Chat \(id)"), "preview": "hi", "last_active": .number(lastActive),
         "started_at": .number(lastActive - 60), "message_count": 2, "source": "desktop", "pinned": .bool(pinned),
         "unread": .bool(unread), "hidden": false]
    }

    nonisolated private static func value(_ query: [URLQueryItem], _ name: String) -> Int? {
        query.first { $0.name == name }?.value.flatMap(Int.init)
    }

    /// A gateway that answers each limit as Hermes does: the newest N recents, plus every pinned row past them.
    nonisolated private static func answer(_ rows: [JSONValue], query: [URLQueryItem], partial: Bool = false) -> Data {
        let sorted = rows.sorted { ($0["last_active"]?.double ?? 0) > ($1["last_active"]?.double ?? 0) }
        let limit = value(query, "recents_limit") ?? 50
        let window = Array(sorted.prefix(limit)) + sorted.dropFirst(limit).filter { $0["pinned"]?.bool == true }
        var recents: [String: JSONValue] = ["sessions": .array(window)]
        if partial { recents["profiles_failed"] = true }
        let root: JSONValue = ["recents": .object(recents), "cron": ["sessions": []], "messaging": ["sessions": []]]
        return try! root.encoded()
    }

    private func reads(_ client: BotsFakeGatewayClient, limit: Int) -> Int {
        client.restCalls.filter { $0.method == "GET" && Self.value($0.query, "recents_limit") == limit }.count
    }

    private func reconnect(_ client: BotsFakeGatewayClient, _ store: SessionStore) {
        store.reconnectShare = ReconnectShare()   // a reconnect of its own, not one inside the 3 s the offline work shares
        client.emit("gateway.ready", payload: ["change_events": true])
    }

    /// 30 chats, c00 newest.
    nonisolated private static func thirty(base: Double = 1_791_000_000) -> [JSONValue] {
        (0..<30).map { srow(String(format: "c%02d", $0), lastActive: base - Double($0) * 10) }
    }

    @Test func aReconnectMergesTheTopPageAndOwesTheFullRead() async throws {
        let rows = BotsTestBox(Self.thirty())
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, query, _ in Self.answer(rows.value, query: query) }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.sessions.count == 30 && reads(client, limit: 50) == 1)
        // Away: a new chat, c25 moved to the top, c02 archived (gone from the list).
        var next = rows.value.filter { $0["id"]?.string != "c02" }
        next = next.map { $0["id"]?.string == "c25" ? Self.srow("c25", lastActive: 1_791_000_900, title: "Moved up") : $0 }
        next.append(Self.srow("new", lastActive: 1_791_001_000))
        rows.value = next
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.probeStats.top == 1 })
        #expect(reads(client, limit: 1) == 1 && reads(client, limit: 20) == 1 && reads(client, limit: 50) == 1)
        let shown = store.sessions.map(\.id)
        #expect(Array(shown.prefix(3)) == ["new", "c25", "c00"])
        #expect(!shown.contains("c02"))
        #expect(shown.contains("c29") && shown.count == 30)                          // the deep rows are kept
        #expect(store.sessions.first { $0.id == "c25" }?.title == "Moved up")
        #expect(store.fullReadOwed)
        // The list comes on screen while the last full read is fresh: no full read yet.
        store.setListVisible(true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(reads(client, limit: 50) == 1 && store.fullReadOwed)
        // Pull to refresh reads in full and settles it.
        await store.refresh()
        #expect(reads(client, limit: 50) == 2 && !store.fullReadOwed)
        // The next reconnect with nothing new: the top page's fingerprint matches the probe's, so it skips.
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.probeStats.skipped == 1 })
        store.stop()
    }

    /// [perf] The top page goes out with the probe, not after it: a differing probe costs no extra round trip, and a
    /// matching one cancels the top page unapplied.
    @Test func theTopPageStartsWithTheProbe() async throws {
        let rows = BotsTestBox(Self.thirty())
        let probeDelay = BotsTestBox(Duration.zero)
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, query, _ in
            if Self.value(query, "recents_limit") == 1 { await botsUncancellableSleep(probeDelay.value) }
            return Self.answer(rows.value, query: query)
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        // Something changed; the probe is slow. The top page is out before the probe answers.
        rows.value = rows.value + [Self.srow("new", lastActive: 1_791_001_000)]
        probeDelay.value = .milliseconds(400)
        reconnect(client, store)
        #expect(await BotsTest.waitUntil(.milliseconds(300)) { reads(client, limit: 20) == 1 })
        #expect(store.probeStats.top == 0, "not used before the probe has answered")
        #expect(await BotsTest.waitUntil { store.probeStats.top == 1 })
        #expect(store.sessions.first?.id == "new" && store.fullReadOwed)
        #expect(reads(client, limit: 1) == 1 && reads(client, limit: 50) == 1)
        // Nothing new: the probe matches, the top page is dropped (if it went out at all) and nothing is applied.
        probeDelay.value = .zero
        let topsBefore = reads(client, limit: 20)
        var changes = 0
        store.onChange = { changes += 1 }
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.probeStats.skipped == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.probeStats.top == 1 && reads(client, limit: 20) <= topsBefore + 1)
        #expect(changes == 0)
        store.stop()
    }

    /// [perf] A reconnect storm on a quiet list: once a probe has matched, the reconnects after it probe alone (the
    /// gateway answers a cancelled top page all the same). A probe that differs brings the early top page back.
    @Test func aQuietListProbesAloneAfterAMatch() async throws {
        let rows = BotsTestBox(Self.thirty())
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, query, _ in Self.answer(rows.value, query: query) }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        // The first reconnect has no match to go on: its top page goes out beside the probe, which then matches.
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.probeStats.skipped == 1 })
        try await Task.sleep(for: .milliseconds(50))
        let topsAfterFirst = reads(client, limit: 20)
        #expect(topsAfterFirst <= 1)
        for round in 2...5 {
            reconnect(client, store)
            #expect(await BotsTest.waitUntil { store.probeStats.skipped == round })
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(reads(client, limit: 20) == topsAfterFirst, "no top page while the list is quiet")
        #expect(reads(client, limit: 1) == 5 && reads(client, limit: 50) == 1)
        // Something changed: this probe differs (its top page waits for it), and the next reconnect sends one early again.
        rows.value = rows.value + [Self.srow("new", lastActive: 1_791_001_000)]
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.probeStats.top == 1 })
        #expect(store.sessions.first?.id == "new")
        let topsBefore = reads(client, limit: 20)
        rows.value = rows.value + [Self.srow("newer", lastActive: 1_791_002_000)]
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.probeStats.top == 2 })
        #expect(reads(client, limit: 20) == topsBefore + 1 && store.sessions.first?.id == "newer")
        store.stop()
    }

    /// (review) A read that finds the list moved ends the quiet; a change tick that moved nothing does not (gateways send
    /// one around a reconnect).
    @Test func aReadThatFindsTheListMovedEndsTheQuiet() async throws {
        let rows = BotsTestBox(Self.thirty())
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, query, _ in
            // The probe answers late, so a top page sent beside it is always out before it ends.
            if Self.value(query, "recents_limit") == 1 { try await Task.sleep(for: .milliseconds(150)) }
            return Self.answer(rows.value, query: query)
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.probeStats.skipped == 1 })
        func changeTick() async throws {
            let calls = client.restCalls.count
            client.emit("sessions.changed")
            #expect(await BotsTest.waitUntil { client.restCalls.count > calls })       // the tick's own pass
            try await Task.sleep(for: .milliseconds(600))
        }
        try await changeTick()                      // nothing moved
        var tops = reads(client, limit: 20)
        var skipped = store.probeStats.skipped
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.probeStats.skipped == skipped + 1 })
        #expect(reads(client, limit: 20) == tops, "still quiet: the probe goes alone")
        rows.value = rows.value + [Self.srow("new", lastActive: 1_791_001_000)]
        try await changeTick()                      // the tick's read finds the new chat
        #expect(store.sessions.first?.id == "new")
        tops = reads(client, limit: 20)
        skipped = store.probeStats.skipped
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.probeStats.skipped == skipped + 1 })
        #expect(reads(client, limit: 20) == tops + 1, "the top page went out beside the probe again")
        store.stop()
    }

    /// [perf] A probe that fails still gets the top page that went out with it (spec §11.3 "the probe fails → the top
    /// page"); a partial probe answer drops it and reads in full.
    @Test func aFailedProbeUsesTheEarlyTopPageAPartialOneReadsInFull() async throws {
        let rows = BotsTestBox(Self.thirty())
        let probeMode = BotsTestBox("ok")
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, query, _ in
            if Self.value(query, "recents_limit") == 1 {
                if probeMode.value == "throw" { throw HTTPError(status: 500, body: nil) }
                if probeMode.value == "partial" { return Self.answer(rows.value, query: query, partial: true) }
            }
            return Self.answer(rows.value, query: query)
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        rows.value = rows.value + [Self.srow("new", lastActive: 1_791_001_000)]
        probeMode.value = "throw"
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.probeStats.top == 1 })
        #expect(store.sessions.first?.id == "new" && store.loadState == .ready && reads(client, limit: 50) == 1)
        probeMode.value = "partial"
        rows.value = rows.value + [Self.srow("newer", lastActive: 1_791_002_000)]
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.probeStats.full == 2 })
        #expect(store.probeStats.top == 1 && store.sessions.first?.id == "newer")
        store.stop()
    }

    /// Build 483 crash (2026-10-30): a top page left the full read owed, the list came on screen with the gateway down,
    /// and every failed full read started the next one at once (~90,000 in 6 s) until iOS killed the app.
    @Test func aFailedOwedFullReadIsNotChasedAgain() async throws {
        var timing = SessionStoreTiming.fast
        timing.probeMaxAge = .milliseconds(400)
        let rows = BotsTestBox(Self.thirty())
        let down = BotsTestBox(false)
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, query, _ in
            if down.value, Self.value(query, "recents_limit") == 50 { throw HTTPError(status: 503, body: nil) }
            return Self.answer(rows.value, query: query)
        }
        let store = makeStore(client, timing: timing)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        rows.value = rows.value + [Self.srow("new", lastActive: 1_791_001_000)]
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.fullReadOwed && store.probeStats.top == 1 })
        try await Task.sleep(for: .milliseconds(450))                               // the last full read is old now
        down.value = true
        store.setListVisible(true)
        #expect(await BotsTest.waitUntil(.seconds(5)) { if case .failed = store.loadState { true } else { false } })
        try await Task.sleep(for: .milliseconds(300))
        #expect(reads(client, limit: 50) == 2)                                     // the first load + one try
        #expect(store.fullReadOwed && store.sessions.count == 31)
        store.stop()
    }

    @Test func onScreenWithAnOldFullReadReadsInFull() async throws {
        var timing = SessionStoreTiming.fast
        timing.probeMaxAge = .zero
        let rows = BotsTestBox(Self.thirty())
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, query, _ in Self.answer(rows.value, query: query) }
        let store = makeStore(client, timing: timing)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        store.setListVisible(true)
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.probeStats.full == 2 })
        #expect(store.probeStats.top == 0 && reads(client, limit: 20) == 0 && !store.fullReadOwed)
        store.stop()
    }

    @Test func firstLoadAndALocalWriteReadInFull() async throws {
        let rows = BotsTestBox(Self.thirty())
        let down = BotsTestBox(true)
        let client = BotsFakeGatewayClient()
        client.onREST { method, _, query, _ in
            if method == "PATCH" { return try! (["ok": true] as JSONValue).encoded() }
            if down.value { throw HTTPError(status: 500, body: nil) }
            return Self.answer(rows.value, query: query)
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil(.seconds(5)) { if case .failed = store.loadState { true } else { false } })
        // No full read yet: the reconnect reads the full list, never a probe or a top page.
        down.value = false
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.probeStats.top == 0 && store.probeStats.probes == 0 && store.sessions.count == 30)
        // A rename from this phone forgets the last read: the full read again, no top page.
        store.applyTitle(id: "c05", title: "Mine")
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.probeStats.full == 3 })
        #expect(store.probeStats.top == 0)
        store.stop()
    }

    @Test func aFailedOrPartialTopPage() async throws {
        let rows = BotsTestBox(Self.thirty())
        let topMode = BotsTestBox("ok")                                             // "ok", "fail", "partial"
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, query, _ in
            if Self.value(query, "recents_limit") == 20 {
                if topMode.value == "fail" { throw HTTPError(status: 500, body: nil) }
                if topMode.value == "partial" { return Self.answer(rows.value, query: query, partial: true) }
            }
            return Self.answer(rows.value, query: query)
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        rows.value = rows.value + [Self.srow("new", lastActive: 1_791_001_000)]
        // A top page that fails shows Retry and keeps the rows; no full read stands in for it.
        topMode.value = "fail"
        reconnect(client, store)
        #expect(await BotsTest.waitUntil(.seconds(5)) { if case .failed = store.loadState { true } else { false } })
        #expect(store.probeStats.full == 1 && store.sessions.count == 30)
        // A partial top page (a profile's store failed): the full read follows.
        topMode.value = "partial"
        reconnect(client, store)
        #expect(await BotsTest.waitUntil(.seconds(5)) { store.probeStats.full == 2 })
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.sessions.count == 31 && !store.fullReadOwed)
        store.stop()
    }

    @Test func ourUnreadWriteFencesTheTopPage() async throws {
        let rows = BotsTestBox(Self.thirty().map { $0["id"]?.string == "c00" ? Self.srow("c00", lastActive: 1_791_000_000, unread: true) : $0 })
        let release = BotsTestBox(false)
        let client = BotsFakeGatewayClient()
        client.onREST { method, _, query, _ in
            if method == "PATCH" {
                while !release.value { try await Task.sleep(for: .milliseconds(20)) }    // in the air
                return try! (["ok": true] as JSONValue).encoded()
            }
            return Self.answer(rows.value, query: query)
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        let opened = try #require(store.sessions.first { $0.id == "c00" })
        #expect(opened.unread)
        store.markOpened(opened)
        #expect(await BotsTest.waitUntil { client.restCalls.contains { $0.method == "PATCH" } })
        // Something else changed, so the probe misses; the top page still says c00 is unread.
        rows.value = rows.value + [Self.srow("new", lastActive: 1_791_001_000)]
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.probeStats.top == 1 })
        #expect(store.row(for: "c00")?.unread == false)
        #expect(store.sessions.first { $0.id == "c00" }?.unread == false)
        release.value = true
        store.stop()
    }

    @Test func anOlderGatewayReadsInFull() async throws {
        let rows = BotsTestBox(Self.thirty())
        let client = BotsFakeGatewayClient()
        client.onREST { _, path, query, _ in
            if path == "/api/profiles/sessions/sidebar" { throw HTTPError(status: 404, body: nil) }
            let limit = Self.value(query, "limit") ?? 50
            return try! (["sessions": .array(Array(rows.value.prefix(limit)))] as JSONValue).encoded()
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        rows.value = [Self.srow("new", lastActive: 1_791_001_000)] + rows.value      // the probe differs
        reconnect(client, store)
        #expect(await BotsTest.waitUntil { store.probeStats.full == 2 })
        #expect(store.probeStats.top == 0)
        #expect(!client.restCalls.contains { Self.value($0.query, "limit") == 20 })
        store.stop()
    }

    // MARK: The connect line

    @Test func connectLines() {
        var steps = ConnectSteps()
        steps.tunnel = .milliseconds(3)
        steps.ticket = .milliseconds(412)
        steps.handshake = .milliseconds(690)
        steps.total = .milliseconds(1105)
        steps.away = .seconds(312)
        steps.sinceActive = .milliseconds(1180)
        #expect(steps.line(outcome: "ok")
                == "connect: tunnel 3 ms, ticket 412 ms, handshake 690 ms, total 1105 ms (return after 312 s, active to ready 1180 ms)")
        var failed = ConnectSteps()
        failed.waited = .milliseconds(1500)
        failed.tunnel = .milliseconds(2)
        failed.ticket = .milliseconds(15003)
        failed.refreshed = true
        failed.total = .milliseconds(16505)
        failed.first = true
        #expect(failed.line(outcome: "timeout")
                == "connect failed (timeout): wait 1500 ms, tunnel 2 ms, ticket 15003 ms (auth refreshed), total 16505 ms (first)")
    }
}
