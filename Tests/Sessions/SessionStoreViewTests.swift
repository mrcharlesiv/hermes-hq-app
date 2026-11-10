import Foundation
import Testing
@testable import HermesHQNative

/// [sessions-m9] The Sessions store's side of Filter and Sort (docs/spec/3x-sessions.md §3, §5.6, §9.4, §11): choices
/// kept per account, the deeper read while a filter is on, Mark All as Read, a row's status inputs, the reconnect probe.
@Suite(.serialized) struct SessionStoreViewTests {
    private func makeStore(_ client: BotsFakeGatewayClient, dir: URL = BotsTest.tempDirectory(), timing: SessionStoreTiming = .fast,
                           autoStart: Bool = true) -> SessionStore {
        SessionStore(client: client, account: .botsTestAccount, cacheDirectory: dir, timing: timing, autoStart: autoStart)
    }

    nonisolated private static func sidebar(_ recents: [JSONValue]) -> Data {
        let root: JSONValue = ["recents": ["sessions": .array(recents)], "cron": ["sessions": []], "messaging": ["sessions": []]]
        return try! root.encoded()
    }

    nonisolated private static func srow(_ id: String, profile: String = "ivy", lastActive: Double = 1_791_000_000, count: Int = 2,
                                         pinned: Bool = false, unread: Bool = false, active: Bool = false) -> JSONValue {
        ["id": .string(id), "profile": .string(profile), "title": .string("Chat \(id)"), "preview": "hi", "last_active": .number(lastActive),
         "started_at": .number(lastActive - 60), "message_count": .number(Double(count)), "source": "desktop",
         "pinned": .bool(pinned), "unread": .bool(unread), "hidden": false, "is_active": .bool(active)]
    }

    nonisolated private static func limit(_ query: [URLQueryItem]) -> String? { query.first { $0.name == "recents_limit" }?.value }

    private func reads(_ client: BotsFakeGatewayClient, limit: String) -> Int {
        client.restCalls.filter { $0.method == "GET" && Self.limit($0.query) == limit }.count
    }

    // MARK: Choices

    @Test func choicesAreKeptPerAccountAndTheChipIsNot() async throws {
        let dir = BotsTest.tempDirectory()
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.sidebar([Self.srow("a")]) }
        let store = makeStore(client, dir: dir)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        var changes = 0
        store.onChange = { changes += 1 }
        store.setView { $0.sortBy = .tokens; $0.groupBy = .status; $0.rowDetail = [.tokens, .cost]; $0.statusFilter = [.unread, .working] }
        #expect(changes == 1)
        store.setView { $0.sortBy = .tokens }                                  // nothing new: no redraw
        #expect(changes == 1)
        store.setBotFilter("ivy")
        #expect(changes == 2 && store.botFilter == "ivy")
        store.stop()
        RosterDiskWriter.shared.flush()

        let again = makeStore(BotsFakeGatewayClient(), dir: dir, autoStart: false)
        #expect(again.view.sortBy == .tokens && again.view.groupBy == .status)
        #expect(again.view.rowDetail == [.tokens, .cost] && again.view.statusFilter == [.unread, .working])
        #expect(again.botFilter == nil)                                         // every launch opens on All
        // Another gateway account has its own choices.
        var other = GatewayAccount.botsTestAccount
        other.id = "another-account"
        let theirs = SessionStore(client: BotsFakeGatewayClient(), account: other, cacheDirectory: dir, timing: .fast, autoStart: false)
        #expect(theirs.view == SessionsViewPrefs())
    }

    /// A tester (2026-11-03): with a bot picked, Filter › Project lists only that bot's projects, and another bot's
    /// project left checked narrows nothing.
    @Test func aPickedBotListsOnlyItsOwnProjects() {
        let store = makeStore(BotsFakeGatewayClient(), autoStart: false)
        store.projectsByProfile = ["ivy": [SessionProject(id: "1", label: "Site", root: "/w/site", paths: ["/w/site"])],
                                   "kit": [SessionProject(id: "2", label: "Books", root: "/w/books", paths: ["/w/books"])]]
        #expect(store.filterState(order: ["ivy", "kit"], botCount: 2).projects.map(\.label) == ["Books", "Site", "Home"])
        store.setView { $0.projectFilter = ["/w/books"] }
        #expect(store.effectiveProjects == ["/w/books"])
        store.setBotFilter("ivy")
        #expect(store.filterState(order: ["ivy", "kit"], botCount: 2).projects.map(\.label) == ["Site", "Home"])
        #expect(store.effectiveProjects.isEmpty)
        store.setBotFilter("nobody")
        #expect(store.filterState(order: ["ivy", "kit"], botCount: 2).projects.isEmpty)
    }

    /// Tester ivy (2026-10-26): a closed group stays closed across launches, for the chip's bot it was closed under;
    /// Show More lasts for the launch.
    @Test func closedGroupsAreKeptPerBotAcrossLaunches() async throws {
        let dir = BotsTest.tempDirectory()
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.sidebar([Self.srow("a", pinned: true), Self.srow("b")]) }
        let store = makeStore(client, dir: dir)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.listGroups().first { $0.id == "pinned" }?.collapsed == false)    // [sessions-fresh] Recent's Pinned never folds
        store.setView { $0.groupBy = .status }
        var changes = 0
        store.onChange = { changes += 1 }
        store.setGroupCollapsed("pinned", true)
        #expect(changes == 1 && store.collapsedGroups == ["pinned"])
        store.setGroupCollapsed("pinned", true)                              // already closed: no redraw
        #expect(changes == 1)
        #expect(store.listGroups().first { $0.id == "pinned" }?.collapsed == true)
        store.setBotFilter("ivy")
        #expect(store.collapsedGroups.isEmpty)                                // the chip's bot has its own
        #expect(store.listGroups().first { $0.id == "pinned" }?.sessions.map(\.id) == ["a"])
        store.setGroupCollapsed("today", true)
        store.setGroupExpanded("project-home", true)
        #expect(store.expandedGroups["ivy"] == ["project-home"])
        store.setBotFilter(nil)
        #expect(store.collapsedGroups == ["pinned"])
        store.stop()
        RosterDiskWriter.shared.flush()

        let again = makeStore(BotsFakeGatewayClient(), dir: dir, autoStart: false)
        #expect(again.collapsedGroups == ["pinned"])
        #expect(again.device.collapsedGroups["ivy"] == ["today"])
        #expect(again.expandedGroups.isEmpty)                                 // Show More is for the launch
        again.setGroupCollapsed("pinned", false)
        #expect(again.collapsedGroups.isEmpty && again.device.collapsedGroups["*"] == nil)
    }

    /// [sessions-layout] A project opened from its summary row stays open across launches, for the chip's bot it was
    /// opened under; folding it again forgets it.
    @Test func openedProjectsAreKeptPerBotAcrossLaunches() async throws {
        let dir = BotsTest.tempDirectory()
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.sidebar([Self.srow("a"), Self.srow("b")]) }
        let store = makeStore(client, dir: dir)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        store.setView { $0.groupBy = .project }
        #expect(store.listGroups().first { $0.id == "project-home" }?.collapsed == true)       // folded until opened
        var changes = 0
        store.onChange = { changes += 1 }
        store.setGroupCollapsed("project-home", false)
        #expect(changes == 1 && store.openGroups == ["project-home"] && store.collapsedGroups.isEmpty)
        store.setGroupCollapsed("project-home", false)                       // already open: no redraw
        #expect(changes == 1)
        #expect(store.listGroups().first { $0.id == "project-home" }?.sessions.count == 2)
        store.setBotFilter("ivy")
        #expect(store.openGroups.isEmpty)                                     // the chip's bot has its own
        store.setBotFilter(nil)
        store.stop()
        RosterDiskWriter.shared.flush()

        let again = makeStore(BotsFakeGatewayClient(), dir: dir, autoStart: false)
        #expect(again.openGroups == ["project-home"])
        again.setGroupCollapsed("project-home", true)
        #expect(again.openGroups.isEmpty && again.device.openGroups["*"] == nil)
    }

    /// [sessions-layout] A chat read from New for You stays there until the page is left; then it moves back.
    @Test func newForYouKeepsReadChatsUntilThePageIsLeft() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.sidebar([Self.srow("a", unread: true), Self.srow("b")]) }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        store.setView { $0.groupBy = .status }                                // [sessions-fresh] not under Group By Recent
        store.holdNew()
        let key = SessionListPipeline.key(store.sessions.first { $0.id == "a" }!)
        #expect(store.keepNew == [key])
        #expect(store.releaseNew() == false)                                  // still unread: nothing moves
        store.holdNew()
        store.setUnread(store.sessions.first { $0.id == "a" }!, false)
        #expect(store.sessions.first { $0.id == "a" }?.unread == false)
        #expect(store.listGroups().first?.id == SessionListPipeline.newId)  // read, still kept
        #expect(store.releaseNew() == true && store.keepNew.isEmpty)
        #expect(store.listGroups().first?.id != SessionListPipeline.newId)
    }

    @Test func olderAndNewerStateFilesRead() throws {
        // A file from before Filter and Sort: the unread state and Background Runs stay, the choices are the defaults.
        let dir = BotsTest.tempDirectory()
        let url = RosterDisk.url(dir, RosterDisk.sessionStateKind, .botsTestAccount)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"showBackgroundRuns":true,"colors":{"a":2}}"#.utf8).write(to: url)
        let old = makeStore(BotsFakeGatewayClient(), dir: dir, autoStart: false)
        #expect(old.view == SessionsViewPrefs() && old.showBackgroundRuns)
        // A file from a newer build: what this one does not know reads as that field's default.
        let dir2 = BotsTest.tempDirectory()
        let url2 = RosterDisk.url(dir2, RosterDisk.sessionStateKind, .botsTestAccount)
        try FileManager.default.createDirectory(at: url2.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"view":{"sortBy":"shuffle","groupBy":"mood","rowDetail":["updated","sparkles"],"statusFilter":["unread","zzz"],"projectFilter":["ivy\u001fp1"],"showArchived":true,"later":1}}"#.utf8).write(to: url2)
        let newer = makeStore(BotsFakeGatewayClient(), dir: dir2, autoStart: false)
        #expect(newer.view.sortBy == .updated && newer.view.groupBy == .date)
        #expect(newer.view.rowDetail == [.time] && newer.view.statusFilter == [.unread] && newer.view.showArchived)
        #expect(newer.view.projectFilter == ["ivy\u{1F}p1"])
        #expect(newer.effectiveProjects.isEmpty)                                // a project the list does not have narrows nothing
        #expect(newer.wantsDeepRead)                                            // the status filter still asks for the deeper page
    }

    // MARK: The deeper read (§3.6)

    @Test func aFilterReadsThreeHundredOnce() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.sidebar([Self.srow("a"), Self.srow("b", profile: "inbox")]) }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(reads(client, limit: "50") == 1 && reads(client, limit: "300") == 0)
        store.setView { $0.sortBy = .created; $0.groupBy = .status; $0.rowDetail = [.tokens] }      // not filters
        try await Task.sleep(for: .milliseconds(80))
        #expect(reads(client, limit: "300") == 0)
        store.setView { $0.statusFilter = [.unread] }
        #expect(await BotsTest.waitUntil { reads(client, limit: "300") == 1 })
        store.setBotFilter("inbox")                                                                 // already deep
        store.setView { $0.statusFilter = [.unread, .idle] }
        try await Task.sleep(for: .milliseconds(80))
        #expect(reads(client, limit: "300") == 1)
        await store.refresh()                                                                       // stays deep while one is on
        #expect(reads(client, limit: "300") == 2 && reads(client, limit: "50") == 1)
        store.setView { $0.statusFilter = [] }
        store.setBotFilter(nil)
        await store.refresh()
        #expect(reads(client, limit: "50") == 2)
        // A chip alone also deepens.
        store.setBotFilter("ivy")
        #expect(await BotsTest.waitUntil { reads(client, limit: "300") == 3 })
        store.stop()
    }

    // MARK: Mark All as Read (§5.6)

    @Test func markAllReadWritesFourAtATime() async throws {
        let rows = (0..<200).map { Self.srow("s\($0)", profile: $0 % 2 == 0 ? "ivy" : "inbox", lastActive: 1_791_000_000 - Double($0), unread: true) }
            + [Self.srow("read", lastActive: 1_790_000_000)]
        let inFlight = BotsTestBox(0), peak = BotsTestBox(0)
        let client = BotsFakeGatewayClient()
        client.onREST { method, _, _, _ in
            guard method == "PATCH" else { return Self.sidebar(rows) }
            let now = inFlight.mutate { $0 += 1; return $0 }
            peak.mutate { $0 = max($0, now) }
            try? await Task.sleep(for: .milliseconds(3))
            inFlight.mutate { $0 -= 1 }
            return try! (["ok": true, "unread": false] as JSONValue).encoded()
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.anyUnread && store.unreadCount == 200)
        let started = ContinuousClock.now
        let failures = await store.markAllRead()
        let took = ContinuousClock.now - started
        #expect(failures.isEmpty)
        let patches = client.restCalls.filter { $0.method == "PATCH" }
        #expect(patches.count == 200 && Set(patches.map(\.path)).count == 200)          // one per server-unread chat, none twice
        #expect(!patches.contains { $0.path == "/api/sessions/read" })
        #expect(peak.value == SessionStore.markAllWindow)
        // Four go out at once, so which reaches the server first is the scheduler's call: look s0's up by name.
        let first = try #require(patches.first { $0.path == "/api/sessions/s0" })
        #expect(try JSONValue.parse(first.body ?? Data()) == ["unread": false, "profile": "ivy"])
        #expect(first.query == [URLQueryItem(name: "profile", value: "ivy")])
        #expect(patches.prefix(SessionStore.markAllWindow).contains { $0.path == "/api/sessions/s0" })   // still in the first window
        #expect(!store.anyUnread && store.unreadCount == 0)
        #expect(took < .seconds(10))
        // A second run has nothing to write.
        #expect(await store.markAllRead().isEmpty)
        #expect(client.restCalls.filter { $0.method == "PATCH" }.count == 200)
        store.stop()
    }

    @Test func markAllReadClearsDeviceMarksWithoutAWrite() async throws {
        let rows = BotsTestBox([Self.srow("a", count: 2), Self.srow("b", count: 2)])
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.sidebar(rows.value) }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        rows.value = [Self.srow("a", count: 5), Self.srow("b", count: 6)]                // new messages past the watermark
        await store.refresh()
        #expect(store.unreadCount == 2)
        #expect(await store.markAllRead().isEmpty)
        #expect(store.unreadCount == 0 && client.restCalls.allSatisfy { $0.method == "GET" })
        store.stop()
    }

    /// [n20-sessions B3] test28's case: a device-only dot (new messages past the watermark) and a server-unread chat.
    /// After Mark All as Read the next reads (the gateway now agreeing, the counts unchanged) bring neither dot back,
    /// so the tab's count stays at zero. A later message does bring its dot back, as it should.
    @Test func markAllReadStaysReadAcrossLaterReads() async throws {
        let rows = BotsTestBox([Self.srow("seen", count: 2), Self.srow("flag", count: 2, unread: true)])
        let client = BotsFakeGatewayClient()
        client.onREST { method, path, _, _ in
            guard method == "PATCH" else { return Self.sidebar(rows.value) }
            if path == "/api/sessions/flag" { rows.value = [rows.value[0], Self.srow("flag", count: 2)] }
            return try! (["ok": true, "unread": false] as JSONValue).encoded()
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        rows.value = [Self.srow("seen", count: 9), rows.value[1]]
        await store.refresh()
        #expect(Set(store.sessions.filter(\.unread).map(\.id)) == ["seen", "flag"] && store.unreadCount == 2)
        #expect(await store.markAllRead().isEmpty)
        #expect(store.unreadCount == 0)
        for _ in 0..<3 { await store.refresh() }
        #expect(store.unreadCount == 0 && !store.anyUnread, "no dot comes back (\(store.sessions.filter(\.unread).map(\.id)))")
        rows.value = [Self.srow("seen", count: 11), rows.value[1]]
        await store.refresh()
        #expect(store.sessions.filter(\.unread).map(\.id) == ["seen"])
        store.stop()
    }

    @Test func failedWritesRollBackAndTryAgainSendsOnlyThose() async throws {
        let failing = BotsTestBox<Set<String>>(["/api/sessions/b", "/api/sessions/d"])
        let client = BotsFakeGatewayClient()
        client.onREST { method, path, _, _ in
            guard method == "PATCH" else {
                return Self.sidebar(["a", "b", "c", "d"].enumerated().map { Self.srow($1, lastActive: 1_791_000_000 - Double($0), unread: true) })
            }
            if failing.value.contains(path) { throw HTTPError(status: 500, body: nil) }
            return try! (["ok": true, "unread": false] as JSONValue).encoded()
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        let failures = await store.markAllRead()
        #expect(failures.map(\.id) == ["b", "d"] && failures.allSatisfy { $0.profile == "ivy" && !$0.reason.isEmpty })
        #expect(SessionWriteFailure.alertReason(failures) == "2 chats: \(failures[0].reason)")
        #expect(SessionWriteFailure.alertReason(Array(failures.prefix(1))) == failures[0].reason)
        #expect(store.sessions.filter(\.unread).map(\.id) == ["b", "d"])                 // those keep their dot
        #expect(client.restCalls.filter { $0.method == "PATCH" }.count == 4)
        failing.value = ["/api/sessions/d"]
        let again = await store.markAllRead(only: failures)
        #expect(again.map(\.id) == ["d"])
        #expect(client.restCalls.filter { $0.method == "PATCH" }.map(\.path).suffix(2).sorted() == ["/api/sessions/b", "/api/sessions/d"])
        #expect(store.sessions.filter(\.unread).map(\.id) == ["d"])
        store.stop()
    }

    @Test func readOnlyGatewayGetsNoWrite() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { method, _, _, _ in
            if method != "GET" { Issue.record("a read-only gateway must not be written") }
            return Self.sidebar([Self.srow("a", unread: true), Self.srow("b", unread: true)])
        }
        let store = makeStore(client)
        store.readOnlyGateway = true
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.unreadCount == 2)
        #expect(await store.markAllRead().isEmpty)
        #expect(store.unreadCount == 0)
        await store.refresh()
        #expect(store.unreadCount == 0)                                                  // cleared on this device
        store.stop()
    }

    // MARK: A row's status (§9.4)

    @Test func statusFollowsItsInputs() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in
            // `is_active` (a chat loaded on the gateway) is not a running turn: only the app's own live chats say Working.
            Self.sidebar([Self.srow("ask", lastActive: 500, active: true), Self.srow("busy", lastActive: 400),
                          Self.srow("new", lastActive: 300, unread: true), Self.srow("typed", lastActive: 200), Self.srow("quiet", lastActive: 100)])
        }
        let store = makeStore(client)
        let pending = BotsTestBox<[String: SessionPending]>([:])
        store.pendingLine = { _, id in pending.value[id] }
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        func status(_ id: String) -> SessionStatus? { store.sessions.first { $0.id == id }?.status }
        #expect(status("ask") == .idle && status("busy") == .idle)
        store.setRunning(["ask", "busy"])
        #expect(status("ask") == .working && status("busy") == .working && status("new") == .unread && status("quiet") == .idle)
        store.setNeedsInput(["ask"])
        #expect(status("ask") == .needsInput && status("busy") == .working)
        pending.value = ["typed": SessionPending(failed: false, text: "half a thought"), "new": SessionPending(failed: true, text: "lost words")]
        #expect(status("typed") == .idle)                                                // not read again until told
        store.refreshPending()
        #expect(status("typed") == .draft && store.sessions.first { $0.id == "typed" }?.pending?.prefix == "Draft:")
        #expect(status("new") == .unread && store.sessions.first { $0.id == "new" }?.pending?.prefix == "Not Delivered:")
        // The list's filter and sort read the same statuses.
        store.setView { $0.statusFilter = [.needsInput, .draft] }
        #expect(store.listGroups().flatMap(\.sessions).map(\.id) == ["ask", "typed"])
        store.setView { $0.statusFilter = []; $0.sortBy = .status; $0.groupBy = .status }
        // [sessions-layout] The chat waiting on you and the unread one sit in New for You, above the status groups.
        #expect(store.listGroups().map(\.title) == [SessionListPipeline.newTitle, "Working", "Done"])
        #expect(store.listGroups().flatMap(\.sessions).map(\.id) == ["ask", "new", "busy", "typed", "quiet"])
        store.setNeedsInput([])
        #expect(status("ask") == .working)
        store.setRunning([])                                                             // the turn ended: Done, once
        #expect(store.listGroups().map(\.title) == [SessionListPipeline.newTitle, "Done"] && status("ask") == .idle)
        store.stop()
    }

    // MARK: The reconnect probe (§11)

    @Test func probeCountersAndRules() async throws {
        let stamp = BotsTestBox(1_791_000_000.0)
        let unhealthy = BotsTestBox(false)
        let client = BotsFakeGatewayClient()
        client.onREST { method, _, query, _ in
            if method == "PATCH" { return try! (["ok": true] as JSONValue).encoded() }
            if unhealthy.value, Self.limit(query) == "1" {
                return try! (["recents": ["sessions": [], "profiles_failed": true], "cron": ["sessions": []], "messaging": ["sessions": []]] as JSONValue).encoded()
            }
            return Self.sidebar([Self.srow("a", lastActive: stamp.value, unread: true)])
        }
        let store = makeStore(client)
        var told: [String] = []
        store.onProbeStats = { told.append($0.text) }
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.probeStats == SidebarProbeStats(probes: 0, skipped: 0, full: 1))
        // A reconnect with nothing new: one limit-1 probe, no full read.
        store.reconnectShare = ReconnectShare()   // a reconnect of its own, not one inside the 3 s the offline work shares
        client.emit("gateway.ready", payload: ["change_events": true])
        #expect(await BotsTest.waitUntil { store.probeStats.skipped == 1 })
        #expect(store.probeStats == SidebarProbeStats(probes: 1, skipped: 1, full: 1))
        #expect(reads(client, limit: "1") == 1 && reads(client, limit: "50") == 1)
        // [perf] The top page starts with the probe; a matching probe cancels it (it may or may not have gone out).
        let topsAfterSkip = reads(client, limit: "20")
        #expect(topsAfterSkip <= 1)
        // Something changed: the probe differs, then the top page (§11.5), not the full read.
        stamp.value = 1_791_000_500
        store.reconnectShare = ReconnectShare()   // a reconnect of its own, not one inside the 3 s the offline work shares
        client.emit("gateway.ready", payload: ["change_events": true])
        #expect(await BotsTest.waitUntil { store.probeStats.top == 1 })
        #expect(store.probeStats == SidebarProbeStats(probes: 2, skipped: 1, full: 1, top: 1))
        #expect(reads(client, limit: "20") == topsAfterSkip + 1 && reads(client, limit: "50") == 1)
        // An answer where a profile's scan failed never counts as "nothing new", and goes straight to the full read.
        unhealthy.value = true
        store.reconnectShare = ReconnectShare()   // a reconnect of its own, not one inside the 3 s the offline work shares
        client.emit("gateway.ready", payload: ["change_events": true])
        #expect(await BotsTest.waitUntil { store.probeStats.full == 2 })
        #expect(store.probeStats == SidebarProbeStats(probes: 3, skipped: 1, full: 2, top: 1))
        unhealthy.value = false
        // A write that only sets unread keeps the fingerprint: the next reconnect still probes and skips.
        store.markOpened(store.sessions[0])
        #expect(await BotsTest.waitUntil { client.restCalls.contains { $0.method == "PATCH" } })
        store.reconnectShare = ReconnectShare()   // a reconnect of its own, not one inside the 3 s the offline work shares
        client.emit("gateway.ready", payload: ["change_events": true])
        #expect(await BotsTest.waitUntil { store.probeStats.probes == 4 })
        #expect(await BotsTest.waitUntil { store.probeStats.skipped == 2 })
        #expect(store.probeStats.full == 2)
        // A pin forgets the last read: the next reconnect reads in full without a probe (nor a top page).
        store.updateRow(id: "a", profile: "ivy") { $0.pinned = true }
        store.reconnectShare = ReconnectShare()   // a reconnect of its own, not one inside the 3 s the offline work shares
        client.emit("gateway.ready", payload: ["change_events": true])
        #expect(await BotsTest.waitUntil { store.probeStats.full == 3 })
        #expect(store.probeStats == SidebarProbeStats(probes: 4, skipped: 2, full: 3, top: 1))
        #expect(told.last == "probes=4 skipped=2 full=3 top=1" && told.count == Set(told).count)
        store.stop()
    }

    @Test func aStaleReadIsNeverSkipped() async throws {
        var timing = SessionStoreTiming.fast
        timing.probeMaxAge = .zero
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.sidebar([Self.srow("a")]) }
        let store = makeStore(client, timing: timing)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        client.emit("gateway.ready", payload: ["change_events": true])
        // [perf-returns] §11.5: an old read is never skipped; off screen it reads the top page and owes the full read.
        #expect(await BotsTest.waitUntil { store.probeStats.top == 1 })
        #expect(store.probeStats.probes == 0 && store.probeStats.skipped == 0 && reads(client, limit: "1") == 0)
        #expect(store.probeStats.full == 1 && store.fullReadOwed)
        // The list comes on screen with the last full read past probeMaxAge: the owed full read runs.
        store.setListVisible(true)
        #expect(await BotsTest.waitUntil { store.probeStats.full == 2 })
        #expect(await BotsTest.waitUntil { !store.fullReadOwed })
        store.stop()
    }
}
