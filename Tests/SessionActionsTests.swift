import Foundation
import Testing
@testable import HermesHQNative

/// Sessions search (snippets, ranking, merging) and the row actions' writes (SessionSearch.swift,
/// SessionStore+Actions.swift).
@Suite struct SessionSearchTests {
    // MARK: Snippets (the web's search-snippet.test.ts)

    @Test func cleansToolJSON() {
        #expect(SessionSearch.cleanSnippet(#"{"output": "test/output/python3-xterm.out\n    python3 test/"}"#) == "test/output/python3-xterm.out python3 test/")
        #expect(SessionSearch.cleanSnippet(#"...3, "./tests/gateway/test_unknown_command.py": 20, "./tests/gateway/"#)
                == "3, ./tests/gateway/test_unknown_command.py 20, ./tests/gateway/")
        #expect(SessionSearch.cleanSnippet(#"  [{"id": "call_JH5", "call_id": "call_JH5", "re"#) == "call_JH5 re")
        #expect(SessionSearch.cleanSnippet(#"...null\n    },\n    {\n      "url": "https://community.heyg"#) == "https://community.heyg")
        #expect(SessionSearch.cleanSnippet(#"{"ok": true, "error": null}"#) == "")
        #expect(SessionSearch.cleanSnippet("That is true, and null is a word.") == "That is true, and null is a word.")
        #expect(SessionSearch.cleanSnippet(#"...152, "matches": [{"path": "/Users/bots/notes/plan.md", "line": 5, "content": "Treat podcasts as **deep extraction**, not summaries."}"#)
                == "plan.md Treat podcasts as deep extraction, not summaries.")
        #expect(SessionSearch.cleanSnippet(#"I paid 3, then 4, on "Friday": ok"#) == "I paid then on ok")
        #expect(SessionSearch.cleanSnippet(#"Deploy the site: "staging" first, then prod."#) == "Deploy the site: staging first, then prod.")
        #expect(SessionSearch.cleanSnippet(String(repeating: "x", count: 200), max: 20) == String(repeating: "x", count: 19) + "…")
        #expect(SessionSearch.cleanSnippet(#"{"": ""}"#) == "")
    }

    @Test func dropsToolNoiseAndReadsMarkdown() {
        #expect(SessionSearch.cleanSnippet("ok search_files ok search_files ok search_files") == "ok search_files")
        #expect(SessionSearch.cleanSnippet("prin pass BAT8_OK None…") == "prin pass BAT8_OK…")
        #expect(SessionSearch.cleanSnippet("   24| const a = 1\n   25→ return a") == "const a = 1 return a")
        #expect(SessionSearch.cleanSnippet("None of these were True for me.") == "None of these were True for me.")
        #expect(SessionSearch.cleanSnippet("> quoted line\n> - nested bullet\n* star item") == "quoted line nested bullet star item")
        #expect(SessionSearch.cleanSnippet("See [the docs](https://x.y/z) for more") == "See the docs for more")
        #expect(SessionSearch.cleanSnippet("notes/facts.md:14:## Sanitized facts") == "notes/facts.md Sanitized facts")
        #expect(SessionSearch.cleanSnippet("Step 2: pack the shoes at 10:30 - then go") == "Step 2: pack the shoes at 10:30 - then go")
    }

    @Test func windowsAndMarksTheMatch() {
        let raw = "129 24| https://www.notion.so/36c37a45b1d2c3e4f5 Content ideas for the podcast launch week and then >>>Hormozi<<< episode 1000 field notes"
        let shown = SessionSearch.matchSnippet(raw, query: "hormozi")
        #expect(shown.hasPrefix("…"))
        #expect(!shown.contains("24|"))
        let parts = SessionSearch.parts(shown)
        #expect(parts.map(\.text) == ["…launch week and then ", "Hormozi", " episode 1000 field notes"])
        #expect(parts.map(\.match) == [false, true, false])
        // No FTS marks (a local title match): the typed word is marked where it first appears.
        let local = SessionSearch.parts(SessionSearch.matchSnippet("Notes from the Hormozi call", query: "hormozi"))
        #expect(local.map(\.text) == ["Notes from the ", "Hormozi", " call"] && local[1].match)
        #expect(SessionSearch.matchSnippet("Ship >>>it<<< today", query: "it") == "Ship \u{E000}it\u{E001} today")
        // A long tail is cut, never inside the marks.
        let words = (0..<60).map { "w\($0)" }.joined(separator: " ")
        let long = SessionSearch.matchSnippet(">>>ok<<< " + words, query: "ok", max: 40)
        #expect(long.hasSuffix("…"))
        #expect(SessionSearch.plain(long).count <= 40)
        let cut = SessionSearch.matchSnippet(String(repeating: "a ", count: 30) + ">>>" + String(repeating: "z", count: 80) + "<<<", query: "z", max: 40)
        #expect(cut.lastIndex(of: SessionSearch.markClose)! > cut.lastIndex(of: SessionSearch.markOpen)!)
    }

    @Test func pathsReadByTheMatchedFolder() {
        let shown = SessionSearch.matchSnippet(#"{"output": "178 /Users/bots/brain/sources/podcasts/episodes/>>>hormozi<<<-4-ways-ai-business/cleaned-notes.md\n  25 /Users/bots/notes/plan.md"}"#, query: "hormozi")
        #expect(SessionSearch.plain(shown) == "178 hormozi-4-ways-ai-business/cleaned-notes.md 25 plan.md")
        #expect(SessionSearch.parts(shown).filter(\.match).map(\.text) == ["hormozi"])
    }

    @Test func markdownListingsReadAsProse() {
        let handoff = #"{"content": "1|# >>>Website<<< Workstream Handoff — Example Bikes\n2|\n3|**Owner:** Bike Shop Hermes profile  \n4|**Canonical working directory:** ..."#
        #expect(SessionSearch.plain(SessionSearch.matchSnippet(handoff, query: "website"))
                == "Website Workstream Handoff — Example Bikes Owner: Bike Shop Hermes profile Canonical working directory: ...")
    }

    @Test func namesHitsByTitleThenFirstMessage() {
        #expect(SessionSearch.resultName(title: "Home Assistant Access Setup", firstMessage: "[Alex] hi", source: "telegram") == "Home Assistant Access Setup")
        #expect(SessionSearch.resultName(title: "  ", firstMessage: "[Alex Rivera] Open Cloudflare", source: "telegram") == "[Alex Rivera] Open Cloudflare")
        #expect(SessionSearch.resultName(title: "", firstMessage: "[SYSTEM: You are running as a scheduled cron job.", source: "cron") == "Scheduled job run")
        #expect(SessionSearch.resultName(title: nil, firstMessage: "[Note: model was just switched", source: "telegram") == nil)
        #expect(SessionSearch.resultName(title: nil, firstMessage: nil, source: nil) == nil)
    }

    // MARK: Ranking and merging

    private func hit(_ id: String, _ profile: String = "default", title: String? = nil, snippet: String = "") -> SessionSearchHit {
        SessionSearchHit(sessionId: id, profile: profile, title: title, snippet: snippet)
    }

    @Test func ranksByFitKeepingTheGatewaysOrder() {
        // "four are closed": every non-stopword term first ("are" is one), then some, then none.
        let hits = [hit("a", snippet: "the doors are open"), hit("b", snippet: "four doors"), hit("c", title: "Four closed", snippet: "x"),
                    hit("d", snippet: "Fourwheel closed"), hit("e", snippet: "four and closed")]
        #expect(SessionSearch.rank(hits, query: "four are closed").map(\.sessionId) == ["c", "e", "b", "d", "a"])
        // Only stopwords: the order stands.
        #expect(SessionSearch.rank(hits, query: "the are").map(\.sessionId) == ["a", "b", "c", "d", "e"])
    }

    @Test func mergesProfilesRoundRobinAndHidesBotChats() {
        let merged = SessionSearch.merge([[hit("1", "a"), hit("2", "a"), hit("3", "a")], [hit("x", "b")], [hit("1", "a"), hit("y", "c")]])
        #expect(merged.map(\.sessionId) == ["1", "x", "2", "y", "3"])
        #expect(SessionSearch.isHidden(hit("bc", title: "Bot Chat")))
        #expect(SessionSearch.isHidden(hit("g", title: "Group: Launch")))
        #expect(!SessionSearch.isHidden(hit("t", title: "Trip")))
        #expect(SessionSearch.order(local: ["a", "b"], server: ["c", "a", "d"], id: { $0 }) == ["a", "b", "c", "d"])
    }

    @Test func localMatchLooksAtTitlePreviewIdFolderAndSource() {
        let session = SessionSummary(id: "20261001_x", profile: "default", title: "Garden plan", preview: "Tomatoes by the fence",
                                     lastActive: nil, source: "telegram", unread: false, isRunning: false)
        #expect(SessionSearch.matches(session, query: " garden "))
        #expect(SessionSearch.matches(session, query: "TOMATO"))
        #expect(SessionSearch.matches(session, query: "1001_x"))
        #expect(SessionSearch.matches(session, query: "site", cwd: "/home/hermes/site"))
        #expect(SessionSearch.matches(session, query: "telegram"))
        #expect(!SessionSearch.matches(session, query: "lisbon"))
    }

    // MARK: Colours, export names, projects

    @Test func twelveNamedSwatches() {
        #expect(SessionColors.count == 12 && SessionColors.name(8) == "Blue" && SessionColors.name(nil) == nil && SessionColors.name(12) == nil)
        let red = SessionColors.rgb(0)
        // hsl(0 68% 58%) = rgb(221, 75, 75)
        #expect(abs(red.red * 255 - 221) < 1 && abs(red.green * 255 - 75) < 1 && abs(red.blue * 255 - 75) < 1)
        let blue = SessionColors.rgb(7)    // hsl(210 68% 58%) = rgb(75, 148, 221)
        #expect(abs(blue.red * 255 - 75) < 1 && abs(blue.green * 255 - 148) < 1 && abs(blue.blue * 255 - 221) < 1)
        #expect(SessionColors.css(3) == "hsl(90 68% 58%)")
    }

    @Test func exportFilenames() {
        #expect(SessionActionText.exportFilename(sessionId: "20261001_084000_bb000001", title: "Garden plan!") == "garden-plan-20261001.json")
        #expect(SessionActionText.exportFilename(sessionId: "s-garden", title: nil) == "session-s-garden.json")
        #expect(SessionActionText.exportFilename(sessionId: "x", title: "   ") == "session-x.json")
    }

    @Test func projectTreeDecodesAndFindsTheOwner() {
        let tree: JSONValue = ["projects": [
            ["id": "p_site", "label": "Website", "path": "/h/site", "repos": []],
            ["id": "auto", "label": "repo", "path": .null, "repos": [["path": "/h/repo", "groups": [["path": "/h/repo-retry"]]]]],
            ["id": "home", "label": "Home", "path": .null, "isNoProject": true, "repos": []],
            ["id": "empty", "label": "No folder", "path": .null, "repos": []],
        ]]
        let projects = SessionProject.decodeTree(tree)
        #expect(projects.map(\.id) == ["p_site", "auto"])
        #expect(projects[1].root == "/h/repo")
        #expect(SessionProject.owner(of: "/h/site/src", in: projects) == "p_site")
        #expect(SessionProject.owner(of: "/h/repo-retry", in: projects) == "auto")
        #expect(SessionProject.owner(of: "/h/sites", in: projects) == nil)
        #expect(SessionProject.owner(of: nil, in: projects) == nil)
    }

    @Test func hitDecodes() throws {
        let data = try (["results": [["session_id": "s1", "snippet": ">>>a<<<", "title": .null, "source": "cron", "last_active": 10, "session_started": 5]]] as JSONValue).encoded()
        let hits = try SessionSearchHit.decode(data, profile: "ivy")
        #expect(hits.count == 1 && hits[0].profile == "ivy" && hits[0].title == nil && hits[0].lastActive == 10 && hits[0].started == 5)
    }
}

@Suite(.serialized) struct SessionActionsTests {
    nonisolated private static func srow(_ id: String, profile: String = "ivy", title: String = "Chat", pinned: Bool = false,
                                         unread: Bool = false, archived: Bool = false, cwd: String = "/h/app", lastActive: Double = 1_791_000_000,
                                         source: String = "desktop", userId: String? = nil) -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(id), "profile": .string(profile), "title": .string(title), "preview": "hi", "last_active": .number(lastActive),
            "started_at": .number(lastActive - 60), "message_count": 2, "source": .string(source), "pinned": .bool(pinned), "unread": .bool(unread),
            "archived": .bool(archived), "hidden": false, "cwd": .string(cwd)]
        if let userId { row["user_id"] = .string(userId) }
        return .object(row)
    }

    nonisolated private static func sidebar(_ rows: [JSONValue]) -> Data {
        try! (["recents": ["sessions": .array(rows)], "cron": ["sessions": []], "messaging": ["sessions": []]] as JSONValue).encoded()
    }

    /// Records every write; answers the sidebar with `rows`, writes with `{"ok":true}` (or fails `failing` paths).
    nonisolated final class Gateway: @unchecked Sendable {
        let client = BotsFakeGatewayClient()
        let lock = NSLock()
        var rows: [JSONValue]
        /// What the archived read answers.
        var archived: [JSONValue] = [SessionActionsTests.srow("old", archived: true)]
        var failing: Set<String> = []
        var owned = false   // a gateway owns the profile: Hermes before 0.22.3 refuses every edit (SessionWrite)
        init(_ rows: [JSONValue]) {
            self.rows = rows
            client.onREST { [unowned self] method, path, query, body in
                if path == "/api/profiles/sessions/sidebar" { return SessionActionsTests.sidebar(self.lock.withLock { self.rows }) }
                if self.lock.withLock({ self.failing.contains(method + " " + path) }) { throw HTTPError(status: 500, body: #"{"detail":"disk full"}"#) }
                if method == "PATCH" || method == "DELETE", self.lock.withLock({ self.owned }) { throw SessionWriteTests.refusal }
                if path == "/api/profiles/sessions" {
                    return try (["sessions": .array(self.lock.withLock { self.archived })] as JSONValue).encoded()
                }
                if path == "/api/sessions/search" {
                    let profile = query.first { $0.name == "profile" }?.value ?? ""
                    let results: [JSONValue] = profile == "ivy"
                        ? [["session_id": "a1", "snippet": "four >>>teams<<<", "title": "Teams"], ["session_id": "bc", "title": "Bot Chat", "snippet": "x"]]
                        : [["session_id": "b1", "snippet": "the >>>teams<<< budget for four", "title": "Budget"]]
                    return try (["results": .array(results)] as JSONValue).encoded()
                }
                if method == "PATCH", let body, let json = try? JSONValue.parse(body), let title = json["title"]?.string {
                    return try (["ok": true, "title": .string(title + "!")] as JSONValue).encoded()
                }
                return try (["ok": true] as JSONValue).encoded()
            }
        }
        func writes(_ method: String) -> [(path: String, query: [URLQueryItem], body: JSONValue?)] {
            client.restCalls.filter { $0.method == method }.map { ($0.path, $0.query, $0.body.flatMap { try? JSONValue.parse($0) }) }
        }
    }

    private func store(_ gateway: Gateway, dir: URL = BotsTest.tempDirectory()) async -> SessionStore {
        let store = SessionStore(client: gateway.client, account: .botsTestAccount, cacheDirectory: dir, timing: .fast)
        _ = await BotsTest.waitUntil { store.loadState == .ready }
        return store
    }

    private func summary(_ store: SessionStore, _ id: String) -> SessionSummary? {
        (store.sessions + store.archivedSessions).first { $0.id == id }
    }

    @Test func pinWritesTheOwnerAndRollsBackOnFailure() async throws {
        let gateway = Gateway([Self.srow("a"), Self.srow("b", lastActive: 1_791_000_100)])
        let store = await store(gateway)
        let a = try #require(summary(store, "a"))
        try await store.setPinned(a, true)
        #expect(summary(store, "a")?.pinned == true)
        #expect(store.sessions.first?.id == "a", "pinned first")
        let patch = try #require(gateway.writes("PATCH").last)
        #expect(patch.path == "/api/sessions/a" && patch.query.contains(URLQueryItem(name: "profile", value: "ivy")))
        #expect(patch.body?["pinned"]?.bool == true && patch.body?["profile"]?.string == "ivy")

        gateway.lock.withLock { gateway.failing = ["PATCH /api/sessions/b"] }
        let b = try #require(summary(store, "b"))
        await #expect(throws: HTTPError.self) { try await store.setPinned(b, true) }
        #expect(summary(store, "b")?.pinned == false, "rolled back")
        store.stop()
    }

    @Test func aPinTheGatewayRefusesStaysOnThisDeviceUntilTheGatewayAgrees() async throws {
        let gateway = Gateway([Self.srow("a"), Self.srow("b", lastActive: 1_791_000_100)])
        gateway.owned = true
        let dir = BotsTest.tempDirectory()
        let store = await store(gateway, dir: dir)
        try await store.setPinned(try #require(summary(store, "a")), true)
        #expect(summary(store, "a")?.pinned == true && store.sessions.first?.id == "a")
        await store.refresh()
        #expect(summary(store, "a")?.pinned == true, "a page that still says unpinned doesn't undo it")
        store.stop()
        RosterDiskWriter.shared.flush()

        let again = await self.store(gateway, dir: dir)
        #expect(summary(again, "a")?.pinned == true, "kept across launches")
        gateway.lock.withLock { gateway.rows = [Self.srow("a", pinned: true), Self.srow("b", lastActive: 1_791_000_100)] }
        await again.refresh()
        #expect(again.device.pins.isEmpty, "the gateway agrees: the device copy is done")
        gateway.lock.withLock { gateway.rows = [Self.srow("a"), Self.srow("b", lastActive: 1_791_000_100)] }
        await again.refresh()
        #expect(summary(again, "a")?.pinned == false, "a later unpin elsewhere shows")
        again.stop()
    }

    @Test func readAndUnreadTheGatewayRefusesStayOnThisDevice() async throws {
        let gateway = Gateway([Self.srow("a", unread: true), Self.srow("b")])
        gateway.owned = true
        let store = await store(gateway)
        store.setUnread(try #require(summary(store, "a")), false)
        #expect(await BotsTest.waitUntil { gateway.writes("PATCH").contains { $0.body?["unread"]?.bool == false } })
        await store.refresh()
        #expect(summary(store, "a")?.unread == false, "read stays read though the gateway still says unread")
        store.setUnread(try #require(summary(store, "b")), true)
        #expect(await BotsTest.waitUntil { gateway.writes("PATCH").contains { $0.body?["unread"]?.bool == true } })
        await store.refresh()
        #expect(summary(store, "b")?.unread == true)
        store.stop()
    }

    @Test func archiveLeavesAtOnceAndUnarchiveBringsItBack() async throws {
        let gateway = Gateway([Self.srow("a"), Self.srow("b")])
        let store = await store(gateway)
        let a = try #require(summary(store, "a"))
        let task = Task { try await store.setArchived(a, true) }
        #expect(await BotsTest.waitUntil { !store.sessions.contains { $0.id == "a" } }, "the row leaves before the answer")
        try await task.value
        #expect(store.archivedSessions.map(\.id) == ["a"] && store.archivedSessions.first?.archived == true)
        #expect(gateway.writes("PATCH").last?.body?["archived"]?.bool == true)
        let archived = try #require(store.archivedSessions.first)
        try await store.setArchived(archived, false)
        #expect(store.sessions.contains { $0.id == "a" } && store.archivedSessions.isEmpty)
        #expect(gateway.writes("PATCH").last?.body?["archived"]?.bool == false)

        gateway.lock.withLock { gateway.failing = ["PATCH /api/sessions/b"] }
        let b = try #require(summary(store, "b"))
        await #expect(throws: HTTPError.self) { try await store.setArchived(b, true) }
        #expect(store.sessions.contains { $0.id == "b" }, "a failed archive puts the row back")
        #expect(SessionActionText.reason(HTTPError(status: 500, body: #"{"detail":"disk full"}"#)) == "disk full")
        #expect(SessionActionText.reason(HTTPError(status: 403, body: #"{"detail":"permission_denied"}"#)) == SessionActionText.refused,
                "Hermes's bare refusal points at the add-on update (hermes-hq-push 0.9.1)")
        #expect(SessionActionText.plain(" permission_denied ") == SessionActionText.refused && SessionActionText.plain("permission denied by policy") == "permission denied by policy")
        // Stress round 1: a call that never answered says so in plain words; the transport's line is the detail.
        let late = RPCError.timedOut("projects.create", after: .seconds(30))
        #expect(SessionActionText.reason(late) == "Your gateway didn’t answer in time. Try again in a moment.")
        #expect(SessionActionText.detail(late) == "request timed out after 30s: projects.create")
        let dropped = RPCError.connectionLost("projects.create")
        #expect(SessionActionText.reason(dropped) == SessionActionText.connectionLost && !SessionActionText.reason(dropped).contains("projects.create"))
        #expect(SessionActionText.detail(dropped)?.contains("projects.create") == true)
        let refused = RPCError(code: -32001, message: "That folder is not on this computer.", data: nil)
        #expect(SessionActionText.reason(refused) == "That folder is not on this computer." && SessionActionText.detail(refused) == nil)
        #expect(SessionActionText.detail(HTTPError(status: 500, body: nil)) == nil)
        store.stop()
    }

    /// [n20-sessions F1] An archived scheduled run follows Background Runs, as the live ones (not Outside Chats alone).
    @Test func archivedScheduledRunFollowsBackgroundRuns() async throws {
        let gateway = Gateway([Self.srow("a")])
        gateway.lock.withLock { gateway.archived = [Self.srow("cron_old", archived: true, source: "cron")] }
        let store = await store(gateway)
        await store.loadArchived()
        #expect(store.archivedSessions.isEmpty)
        store.showOutsideChats = true
        #expect(store.archivedSessions.isEmpty, "Outside Chats alone does not bring a scheduled run")
        store.showBackgroundRuns = true
        #expect(store.archivedSessions.map(\.id) == ["cron_old"] && store.archivedSessions.first?.unread == false)
        store.stop()
    }

    /// [n20-sessions B3] Mark as Read on an archived chat (Show › Archived) clears its dot at once: the server flag is
    /// rewritten in the archived rows too, not only in the slices.
    @Test func markReadClearsAnArchivedChatsDot() async throws {
        let gateway = Gateway([Self.srow("a")])
        gateway.lock.withLock {
            gateway.archived = [Self.srow("old", unread: true, archived: true), Self.srow("old2", unread: true, archived: true)]
        }
        let store = await store(gateway)
        defer { store.stop(); withExtendedLifetime(gateway) {} }
        await store.loadArchived()
        let old = try #require(store.archivedSessions.first { $0.id == "old" })
        #expect(old.unread)
        store.setUnread(old, false)
        #expect(store.archivedSessions.first { $0.id == "old" }?.unread == false, "the dot goes with the tap")
        #expect(await BotsTest.waitUntil { gateway.client.restCalls.contains { $0.method == "PATCH" && $0.path == "/api/sessions/old" } })
        #expect(await BotsTest.waitUntil { store.archivedSessions.first { $0.id == "old" }?.unread == false }, "and stays once the gateway answers")
        // Opening it does the same.
        let old2 = try #require(store.archivedSessions.first { $0.id == "old2" })
        #expect(old2.unread)
        store.markOpened(old2)
        #expect(store.archivedSessions.first { $0.id == "old2" }?.unread == false)
        #expect(await BotsTest.waitUntil { gateway.client.restCalls.contains { $0.method == "PATCH" && $0.path == "/api/sessions/old2" } })
        #expect(await BotsTest.waitUntil { store.archivedSessions.first { $0.id == "old2" }?.unread == false })
    }

    /// A chat the old password sign-in made (`user_id` "basic:<username>", 2026-10-25): the row carries its stamp, and
    /// Hermes's bare refusal on it says whose it is and what to do, not "update the add-on" alone.
    @Test func aPasswordChatsRefusalSaysWhoseItIs() async throws {
        let stamped = Self.srow("pw", userId: "basic:fleet")
        let mine = Self.srow("mine", lastActive: 1_791_000_100, userId: "nous:u1")
        let gateway = Gateway([stamped, mine, Self.srow("plain", lastActive: 1_791_000_200)])
        let store = await store(gateway)
        #expect(summary(store, "pw")?.owner == "basic:fleet" && summary(store, "mine")?.owner == "nous:u1")
        #expect(summary(store, "plain")?.owner == nil, "a gateway that leaves user_id out reads as unknown")
        let refusal = HTTPError(status: 403, body: #"{"detail":"permission_denied"}"#)
        #expect(SessionActionText.reason(refusal, owner: "basic:fleet") == SessionActionText.refusedPasswordChat)
        #expect(SessionActionText.reason(refusal, owner: "nous:u1") == SessionActionText.refused)
        #expect(SessionActionText.reason(refusal) == SessionActionText.refused)
        #expect(SessionActionText.plain("permission_denied", owner: "basic:fleet") == SessionActionText.refusedPasswordChat)
        #expect(SessionActionText.plain("disk full", owner: "basic:fleet") == "disk full", "only the refusal changes")
        #expect(SessionActionText.reason(RPCError(code: -32001, message: "permission_denied", data: nil), owner: "basic:x")
                == SessionActionText.refusedPasswordChat)
        let words = SessionActionText.refusedPasswordChat
        #expect(words.contains("old password sign-in") && words.contains("Settings › Notifications") && !words.contains("Dispatch"))
        #expect(words.count <= 160, "the alert shows it whole, not cut (FailureAlert.twoLines)")
        store.stop()
    }

    @Test func aRowsStampDecodesAndAnOlderCacheStillLoads() throws {
        let row = try #require(SidebarSessionRow(json: ["id": "s", "profile": "ivy", "user_id": " basic:fleet "]))
        #expect(row.userId == "basic:fleet")
        #expect(SidebarSessionRow(json: ["id": "s", "profile": "ivy", "user_id": .null])?.userId == nil)
        let old = Data(#"{"id":"s","profile":"ivy"}"#.utf8)
        #expect(try JSONDecoder().decode(SidebarSessionRow.self, from: old).userId == nil)
    }

    @Test func archivedViewReadsOnlyArchived() async throws {
        let gateway = Gateway([Self.srow("a")])
        let store = await store(gateway)
        await store.loadArchived()
        #expect(store.archivedSessions.map(\.id) == ["old"])
        let read = try #require(gateway.client.restCalls.last { $0.path == "/api/profiles/sessions" })
        #expect(read.query.contains(URLQueryItem(name: "archived", value: "only")))
        #expect(read.query.contains(URLQueryItem(name: "profile", value: "all")))
        #expect(read.query.contains(URLQueryItem(name: "limit", value: "200")))
        store.stop()
    }

    /// Show › Archived adds the archived chats to the list, so they keep Show's other rules (2026-10-24): a run only
    /// with Background Runs (or pinned), a chat from outside the recents only with Outside Chats.
    @Test func archivedRowsKeepShowsOtherRules() async throws {
        let gateway = Gateway([Self.srow("a")])
        gateway.lock.withLock {
            gateway.archived = [Self.srow("old", archived: true), Self.srow("run", archived: true, source: "subagent"),
                                Self.srow("tg", archived: true, source: "telegram"),
                                Self.srow("pinnedrun", pinned: true, archived: true, source: "tool")]
        }
        let store = await store(gateway)
        await store.loadArchived()
        #expect(Set(store.archivedSessions.map(\.id)) == ["old", "pinnedrun"])
        store.showBackgroundRuns = true
        #expect(Set(store.archivedSessions.map(\.id)) == ["old", "pinnedrun", "run"])
        store.showOutsideChats = true
        #expect(Set(store.archivedSessions.map(\.id)) == ["old", "pinnedrun", "run", "tg"])
        #expect(store.archivedSessions.allSatisfy { $0.archived })
        #expect(store.archivedSessions.first { $0.id == "tg" }?.outside == true && store.archivedSessions.first { $0.id == "old" }?.outside == false)
        store.stop()
    }

    @Test func deleteSendsTheOwnerAndDropsTheRow() async throws {
        let gateway = Gateway([Self.srow("a", profile: "research"), Self.srow("b")])
        let store = await store(gateway)
        let a = try #require(summary(store, "a"))
        try await store.delete(a)
        #expect(!store.sessions.contains { $0.id == "a" })
        let delete = try #require(gateway.writes("DELETE").last)
        #expect(delete.path == "/api/sessions/a" && delete.query == [URLQueryItem(name: "profile", value: "research")] && delete.body == nil)
        store.stop()
    }

    @Test func renameShowsAtOnceThenTheStoredTitle() async throws {
        let gateway = Gateway([Self.srow("a", title: "Old")])
        let store = await store(gateway)
        let a = try #require(summary(store, "a"))
        let stored = try await store.rename(a, to: "  New  ")
        #expect(stored == "New!" && summary(store, "a")?.title == "New!")
        #expect(gateway.writes("PATCH").last?.body?["title"]?.string == "New")
        gateway.lock.withLock { gateway.failing = ["PATCH /api/sessions/a"] }
        let renamed = try #require(summary(store, "a"))
        await #expect(throws: HTTPError.self) { try await store.rename(renamed, to: "Other") }
        #expect(summary(store, "a")?.title == "New!", "the old title comes back")
        store.stop()
    }

    @Test func markUnreadAndReadWriteTheServerFlag() async throws {
        let gateway = Gateway([Self.srow("a")])
        let store = await store(gateway)
        let a = try #require(summary(store, "a"))
        #expect(!a.unread)
        store.setUnread(a, true)
        #expect(summary(store, "a")?.unread == true && store.unreadCount == 1)
        #expect(await BotsTest.waitUntil { gateway.writes("PATCH").last?.body?["unread"]?.bool == true })
        let unread = try #require(summary(store, "a"))
        store.setUnread(unread, false)
        #expect(summary(store, "a")?.unread == false)
        #expect(await BotsTest.waitUntil { gateway.writes("PATCH").last?.body?["unread"]?.bool == false })
        store.stop()
    }

    @Test func colourIsDeviceLocalAndSurvivesARelaunch() async throws {
        let dir = BotsTest.tempDirectory()
        let gateway = Gateway([Self.srow("a")])
        let store = await store(gateway, dir: dir)
        let a = try #require(summary(store, "a"))
        store.setColor(a, 8)
        #expect(summary(store, "a")?.color == 8)
        #expect(gateway.writes("PATCH").isEmpty, "no gateway write")
        store.stop()
        RosterDiskWriter.shared.flush()
        let other = Gateway([Self.srow("a")])
        let again = SessionStore(client: other.client, account: .botsTestAccount, cacheDirectory: dir, timing: .fast, autoStart: false)
        #expect(again.sessions.first?.color == 8)
        again.setColor(try #require(again.sessions.first), nil)
        #expect(again.sessions.first?.color == nil)
    }

    @Test func olderDeviceStateStillDecodes() throws {
        let old = #"{"unread":{"seen":{"ivy":{"a":3}},"markers":{},"localReads":{}},"showBackgroundRuns":true}"#
        let state = try JSONDecoder().decode(SessionsDeviceState.self, from: Data(old.utf8))
        #expect(state.showBackgroundRuns && state.unread.seen["ivy"]?["a"] == 3 && state.colors.isEmpty)
    }

    @Test func searchAsksEveryProfileMergesAndRanks() async throws {
        let gateway = Gateway([Self.srow("a")])
        let store = await store(gateway)
        let hits = await store.search("four teams", profiles: ["ivy", "default", "ivy"])
        // Round-robin (default's b1 first: profiles sorted), Bot Chat hidden, then ranked: both have "four" and "teams".
        #expect(hits.map(\.sessionId) == ["b1", "a1"])
        let asked = gateway.client.restCalls.filter { $0.path == "/api/sessions/search" }
        #expect(asked.count == 2)
        #expect(Set(asked.compactMap { $0.query.first { $0.name == "profile" }?.value }) == ["ivy", "default"])
        #expect(asked.allSatisfy { $0.query.contains(URLQueryItem(name: "q", value: "four teams")) })
        store.stop()
    }

    /// UX study 2026-10-19 #28: a search whose request failed says so, so the list doesn't read "No Results".
    @Test func searchReportsAFailedProfile() async throws {
        let gateway = Gateway([Self.srow("a")])
        let store = await store(gateway)
        let answered = await store.searchReporting("four teams", profiles: ["ivy"])
        #expect(!answered.failed && answered.hits.map(\.sessionId) == ["a1"])
        gateway.lock.withLock { gateway.failing = ["GET /api/sessions/search"] }
        let failed = await store.searchReporting("four teams", profiles: ["ivy", "default"])
        #expect(failed.failed && failed.hits.isEmpty)
        store.stop()
    }

    @Test func projectsMoveAndBranchUseTheirRPCs() async throws {
        let gateway = Gateway([Self.srow("a", cwd: "/h/app")])
        gateway.client.on("projects.tree") { _ in
            ["projects": [["id": "p_app", "label": "App", "path": "/h/app", "repos": []], ["id": "p_site", "label": "Website", "path": "/h/site", "repos": []]]]
        }
        gateway.client.on("session.workspace.move") { params in ["cwd": params["cwd"] ?? .null] }
        gateway.client.on("projects.create") { params in ["project": ["id": "p_new", "name": params["name"] ?? .null, "primary_path": "/h/new"]] }
        gateway.client.on("session.branch_stored") { _ in ["session_id": "abcd1234", "stored_session_id": "a-branch"] }
        let store = await store(gateway)
        let a = try #require(summary(store, "a"))
        let projects = try await store.projects(for: "ivy")
        #expect(projects.count == 2)
        #expect(store.moveTargets(for: a)?.map(\.label) == ["Website"], "not the chat's own project")
        let tree = try #require(gateway.client.calls("projects.tree").last)
        #expect(tree.params["profile"]?.string == "ivy")
        try await store.move(a, to: projects[1])
        let move = try #require(gateway.client.calls("session.workspace.move").last)
        #expect(move.params["cwd"]?.string == "/h/site" && move.params["session_key"]?.string == "a" && move.params["profile"]?.string == "ivy")
        #expect(store.storedRow(a)?.cwd == "/h/site")
        let made = try await store.createProject(name: " New ", folder: "/h/new ", profile: "ivy")
        #expect(made.root == "/h/new" && made.label == "New")
        let create = try #require(gateway.client.calls("projects.create").last)
        #expect(create.params["folders"] == ["/h/new"] && create.params["name"]?.string == "New" && create.params["use"]?.bool == false)
        let branch = try await store.branch(a)
        #expect(branch == SessionBranch(storedId: "a-branch", profile: "ivy"))
        let asked = try #require(gateway.client.calls("session.branch_stored").last)
        #expect(asked.params["parent_session_id"]?.string == "a" && asked.params["profile"]?.string == "ivy" && asked.params["cwd"]?.string == "/h/site")
        store.stop()
    }

    @Test func newProjectWithNoFolderMakesOneNamedAfterIt() async throws {
        let gateway = Gateway([Self.srow("a")])
        gateway.client.onREST { _, path, _, body in
            guard path == "/api/files/mkdir" else { throw HTTPError(status: 404, body: nil) }
            let asked = try JSONValue.parse(body ?? Data())["path"]?.string ?? ""
            return try JSONValue.object(["ok": true, "path": .string(asked.replacingOccurrences(of: "~", with: "/h"))]).encoded()
        }
        gateway.client.on("projects.create") { params in
            let path = params["folders"]?[0]?.string ?? ""
            if path == "/h/Projects/my-site" {
                throw RPCError(code: 5063, message: "folder already belongs to project 'my-site' (p_old); switch to it instead of creating a duplicate", data: nil)
            }
            return ["project": ["id": "p_new", "name": params["name"] ?? .null, "primary_path": .string(path)]]
        }
        let store = await store(gateway)
        let made = try await store.createProject(name: " My Site! ", folder: "  ", profile: "ivy")
        #expect(made.root == "/h/Projects/my-site-2" && made.label == "My Site!")
        #expect(gateway.client.restCalls.map(\.path).filter { $0 == "/api/files/mkdir" }.count == 2)
        #expect(gateway.client.calls("projects.create").map { $0.params["folders"] } == [["/h/Projects/my-site"], ["/h/Projects/my-site-2"]])
        #expect(SessionProject.autoFolder(name: "日本") == "~/Projects/project")
        store.stop()
    }

    @Test func newProjectFolderTheGatewayCantMakeSaysTypeOne() async throws {
        let gateway = Gateway([Self.srow("a")])
        gateway.client.onREST { _, path, _, _ in
            guard path == "/api/files/mkdir" else { throw HTTPError(status: 404, body: nil) }
            throw HTTPError(status: 403, body: #"{"detail":"Path outside managed files root"}"#) }
        let store = await store(gateway)
        await #expect(throws: BotWriteError(title: "", reason: "Couldn’t make the folder ~/Projects/site. Path outside managed files root. Type a folder to use instead.")) {
            try await store.createProject(name: "Site", folder: "", profile: "ivy")
        }
        #expect(gateway.client.calls("projects.create").isEmpty)
        store.stop()
    }

    @Test func renameProjectUpdatesEveryBotHoldingIt() async throws {
        let gateway = Gateway([Self.srow("a", cwd: "/h/app")])
        gateway.client.on("projects.tree") { params in
            params["profile"]?.string == "ivy"
                ? ["projects": [["id": "p_app", "label": "App", "path": "/h/app", "repos": []]]]
                : ["projects": [["id": "/h/app", "label": "app", "path": "/h/app", "isAuto": true, "repos": []]]]
        }
        gateway.client.on("projects.update") { params in
            guard params["id"]?.string == "p_app" else { throw RPCError(code: 5062, message: "no such project", data: nil) }
            return ["project": ["id": "p_app", "name": params["name"] ?? .null]]
        }
        gateway.client.on("projects.create") { params in
            ["project": ["id": "p_auto", "name": params["name"] ?? .null, "primary_path": params["folders"]?[0] ?? .null]]
        }
        let store = await store(gateway)
        _ = try await store.projects(for: "ivy")
        _ = try await store.projects(for: "research")
        try await store.renameProject(key: "/h/app", to: "  Mobile App ")
        let updates = gateway.client.calls("projects.update").map { [$0.params["profile"]?.string, $0.params["name"]?.string] }
        #expect(updates == [["ivy", "Mobile App"], ["research", "Mobile App"]])
        let made = try #require(gateway.client.calls("projects.create").last, "the auto project becomes a saved one")
        #expect(made.params["folders"] == ["/h/app"] && made.params["profile"]?.string == "research")
        #expect(store.projectHolders(key: "/h/app").map(\.project.label) == ["Mobile App", "Mobile App"])
        store.stop()
    }

    @Test func renameAndDeleteProjectSkipABotSinceDeleted() async throws {
        let gateway = Gateway([Self.srow("a", cwd: "/h/app")])
        let gone = RPCError(code: 4064, message: "Profile 'book-club' does not exist.", data: nil)
        gateway.client.on("projects.tree") { params in
            if params["profile"]?.string == "book-club" { throw gone }
            return ["projects": [["id": "p_app", "label": "App", "path": "/h/app", "repos": []]]]
        }
        gateway.client.on("projects.update") { params in
            if params["profile"]?.string == "book-club" { throw gone }
            return ["project": ["id": "p_app", "name": params["name"] ?? .null]]
        }
        gateway.client.on("projects.delete") { params in
            if params["profile"]?.string == "book-club" { throw gone }
            return ["projects": [], "active_id": .null]
        }
        let store = await store(gateway)
        _ = try await store.projects(for: "ivy")
        // Kept from an earlier launch: a bot deleted since.
        store.projectsByProfile["book-club"] = [SessionProject(id: "p_old", label: "App", root: "/h/app", paths: ["/h/app"])]
        try await store.renameProject(key: "/h/app", to: "Mobile App")
        let updates = gateway.client.calls("projects.update").map { $0.params["profile"]?.string }
        #expect(updates == ["ivy"], "the gone bot is read first, found gone, and left out")
        #expect(store.projectsByProfile["book-club"] == nil, "and dropped from the kept projects")
        store.projectsByProfile["book-club"] = [SessionProject(id: "p_old", label: "App", root: "/h/app", paths: ["/h/app"])]
        try await store.deleteProject(key: "/h/app")
        #expect(gateway.client.calls("projects.delete").map { $0.params["profile"]?.string } == ["ivy"])
        #expect(store.projectsByProfile["book-club"] == nil)
        store.stop()
    }

    @Test func deleteProjectDeletesOnlySavedOnes() async throws {
        let gateway = Gateway([Self.srow("a", cwd: "/h/app")])
        gateway.client.on("projects.tree") { params in
            params["profile"]?.string == "ivy"
                ? ["projects": [["id": "p_app", "label": "App", "path": "/h/app", "repos": []],
                                ["id": "/h/docs", "label": "docs", "path": "/h/docs", "isAuto": true, "repos": []]]]
                : ["projects": [["id": "/h/app", "label": "app", "path": "/h/app", "isAuto": true, "repos": []]]]
        }
        gateway.client.on("projects.delete") { _ in ["projects": [], "active_id": .null] }
        let store = await store(gateway)
        _ = try await store.projects(for: "ivy")
        _ = try await store.projects(for: "research")
        #expect(store.canDeleteProject(key: "/h/app"))
        #expect(!store.canDeleteProject(key: "/h/docs"), "Hermes found it itself: nothing saved to delete")
        try await store.deleteProject(key: "/h/app")
        let deletes = gateway.client.calls("projects.delete").map { [$0.params["profile"]?.string, $0.params["id"]?.string] }
        #expect(deletes == [["ivy", "p_app"]])
        #expect(store.projectsByProfile["ivy"]?.map(\.id) == ["/h/docs"])
        #expect(store.projectsByProfile["research"]?.map(\.id) == ["/h/app"])
        store.stop()
    }

    @Test func newChatCreatesInTheProfile() async throws {
        let gateway = Gateway([Self.srow("a")])
        gateway.client.on("session.create") { _ in ["session_id": "abcd1234", "stored_session_id": "n1"] }
        let store = await store(gateway)
        let made = try await store.newChat(profile: "research")
        #expect(made == SessionBranch(storedId: "n1", profile: "research"))
        let create = try #require(gateway.client.calls("session.create").last)
        #expect(create.params["profile"]?.string == "research" && create.params["follow_profile_config"]?.bool == true)
        store.stop()
    }

    @Test func newChatInAProjectStartsInItsFolder() async throws {
        let gateway = Gateway([Self.srow("a")])
        gateway.client.on("session.create") { _ in ["session_id": "abcd1234", "stored_session_id": "n2"] }
        let store = await store(gateway)
        _ = try await store.newChat(profile: "research", folder: "/h/site")
        let create = try #require(gateway.client.calls("session.create").last)
        #expect(create.params["cwd"]?.string == "/h/site" && create.params["cwd_explicit"]?.bool == true)
        store.projectsByProfile = ["ivy": [SessionProject(id: "p1", label: "Site", root: "/h/site/", paths: ["/h/site/"])],
                                   "research": [SessionProject(id: "p9", label: "Site", root: "/h/site", paths: ["/h/site"])],
                                   "other": [SessionProject(id: "p2", label: "Blog", root: "/h/blog", paths: ["/h/blog"])]]
        #expect(store.projectHolders(key: "/h/site").map(\.profile) == ["ivy", "research"], "each bot with the folder")
        #expect(store.projectHolders(key: "/h/none").isEmpty)
        store.stop()
    }

    @Test func branchOnAnOldGatewaySaysSo() async throws {
        let gateway = Gateway([Self.srow("a")])
        let store = await store(gateway)
        let a = try #require(summary(store, "a"))
        await #expect(throws: BotWriteError(title: "", reason: SessionActionText.branchUnsupported)) { try await store.branch(a) }
        store.stop()
    }

    @Test func readOnlyGatewayRefusesWrites() async throws {
        let gateway = Gateway([Self.srow("a")])
        let store = await store(gateway)
        store.readOnlyGateway = true
        let a = try #require(summary(store, "a"))
        await #expect(throws: BotWriteError.self) { try await store.setPinned(a, true) }
        await #expect(throws: BotWriteError.self) { try await store.delete(a) }
        #expect(gateway.writes("PATCH").isEmpty && gateway.writes("DELETE").isEmpty)
        store.stop()
    }

    @Test func exportJSONHoldsEveryStoredRow() async throws {
        let gateway = Gateway([Self.srow("a", title: "Garden")])
        let store = await store(gateway)
        gateway.client.onREST { method, path, query, _ in
            if path == "/api/profiles/sessions/sidebar" { return SessionActionsTests.sidebar([SessionActionsTests.srow("a", title: "Garden")]) }
            let rows: [JSONValue] = [["id": 1, "role": "user", "content": "hi"], ["id": 2, "role": "assistant", "content": "hello"]]
            return try (["session_id": "a", "messages": .array(rows), "pagination": ["limit": 500, "offset": 0]] as JSONValue).encoded()
        }
        let a = try #require(summary(store, "a"))
        let data = try await store.exportJSON(a)
        let json = try JSONValue.parse(data)
        #expect(json["session_id"]?.string == "a" && json["title"]?.string == "Garden" && json["message_count"]?.int == 2)
        #expect(json["messages"]?[1]?["content"]?.string == "hello")
        let read = try #require(gateway.client.restCalls.last { $0.path.hasSuffix("/messages") })
        #expect(read.query.contains(URLQueryItem(name: "order", value: "oldest")) && read.query.contains(URLQueryItem(name: "profile", value: "ivy")))
        store.stop()
    }
}
