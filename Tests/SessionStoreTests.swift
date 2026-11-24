import Foundation
import Observation
import Testing
@testable import HermesHQNative

/// The Sessions list: sidebar decoding, filters, row words, unread and the open-time PATCH, change throttles.
@Suite(.serialized) struct SessionStoreTests {
    private func makeStore(_ client: BotsFakeGatewayClient, dir: URL = BotsTest.tempDirectory(), autoStart: Bool = true) -> SessionStore {
        SessionStore(client: client, account: .botsTestAccount, cacheDirectory: dir, timing: .fast, autoStart: autoStart)
    }

    nonisolated private static func sidebar(_ recents: [JSONValue], cron: [JSONValue] = [], messaging: [JSONValue] = []) -> Data {
        let root: JSONValue = ["recents": ["sessions": .array(recents)], "cron": ["sessions": .array(cron)],
                               "messaging": ["sessions": .array(messaging)]]
        return try! root.encoded()
    }

    nonisolated private static func srow(_ id: String, profile: String = "ivy", title: JSONValue = "Chat", preview: String = "hi",
                             lastActive: Double = 1_791_000_000, count: Int = 2, source: String = "desktop",
                             pinned: Bool = false, unread: Bool = false, hidden: Bool = false) -> JSONValue {
        ["id": .string(id), "profile": .string(profile), "title": title, "preview": .string(preview), "last_active": .number(lastActive),
         "started_at": .number(lastActive - 60), "message_count": .number(Double(count)), "source": .string(source),
         "pinned": .bool(pinned), "unread": .bool(unread), "hidden": .bool(hidden), "is_active": false]
    }

    private func fullReads(_ client: BotsFakeGatewayClient) -> Int {
        client.restCalls.filter { $0.method == "GET" && $0.query.contains(URLQueryItem(name: "recents_limit", value: "50")) }.count
    }

    /// [perf-returns] Top-page reads (docs/spec/3x-sessions.md §11.5).
    private func topReads(_ client: BotsFakeGatewayClient) -> Int {
        client.restCalls.filter { $0.method == "GET" && $0.query.contains(URLQueryItem(name: "recents_limit", value: "20")) }.count
    }

    /// Pull request status reads (a first answer also asks once for the linked repositories: not counted here).
    private func prChecks(_ client: BotsFakeGatewayClient) -> Int {
        client.restCalls.filter { $0.path.hasSuffix("/sessions/pr-status") }.count
    }

    private func probes(_ client: BotsFakeGatewayClient) -> Int {
        client.restCalls.filter { $0.method == "GET" && $0.query.contains(URLQueryItem(name: "recents_limit", value: "1")) }.count
    }

    // MARK: Decoding and the list

    @Test func pullRequestsAreChunkedAndKeyedByProfile() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { method, path, _, body in
            #expect(method == "POST" && path == "/api/plugins/hermes-hq-push/sessions/pr-status")
            let request = try JSONValue.parse(#require(body))
            let sessions = try #require(request["sessions"]?.array)
            #expect(sessions.count <= 32)
            let result: JSONValue = ["sessions": .array(sessions.map { row in
                ["profile": row["profile"] ?? .null, "id": row["id"] ?? .null,
                 "state": row["profile"]?.string == "other" ? "none" : "open",
                 "number": 42, "url": "https://github.com/example/repo/pull/42",
                 "manual": row["profile"]?.string == "other" ? .null : true]
            })]
            return try result.encoded()
        }
        let store = makeStore(client, autoStart: false)
        let rows = (0..<65).map { SessionSummary(id: "\($0)", profile: "ivy", title: "", preview: nil,
                                                 lastActive: nil, source: nil, unread: false, isRunning: false) }
        var other = rows[0]; other.profile = "other"
        await store.refreshPullRequests(for: rows + [other, rows[0]])
        #expect(prChecks(client) == 3)
        #expect(store.pullRequest(profile: "ivy", id: "0")?.state == .open)
        #expect(store.pullRequest(profile: "other", id: "0")?.state == SessionPRStatus.State.none)
        #expect(store.pullRequest(profile: "ivy", id: "0")?.label == "Open #42")
        #expect(store.pullRequest(profile: "ivy", id: "0")?.url?.host == "github.com")
        #expect(store.pullRequest(profile: "ivy", id: "0")?.manual == true)
        #expect(store.pullRequest(profile: "other", id: "0")?.manual == false)
        let second = makeStore(BotsFakeGatewayClient(), autoStart: false)
        #expect(second.pullRequest(profile: "ivy", id: "0") == nil)
    }

    @Test func pullRequestsHandleOmissionsFailuresAndUnsupportedGateways() async throws {
        let sidebar = Self.sidebar([Self.srow("same", profile: "ivy"), Self.srow("same", profile: "other")])
        let client = BotsFakeGatewayClient()
        client.onREST { method, _, _, _ in
            if method == "GET" { return sidebar }
            return Data("{\"sessions\":[{\"profile\":\"ivy\",\"id\":\"same\",\"state\":\"none\",\"repo\":\"owner/repo\",\"url\":\"https://github.com/owner/repo/pull/42\"},{\"profile\":\"other\",\"id\":\"same\",\"state\":\"unknown\"}]}".utf8)
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.sessions.count == 2 })
        #expect(!client.restCalls.contains { $0.path.hasSuffix("pr-status") })
        store.setListVisible(true)
        let rows = store.sessions
        await store.refreshPullRequests(for: rows)
        #expect(store.pullRequest(profile: "other", id: "same")?.label == "PR status unknown")
        // [pr-instant] No answer this time (Hermes restarting, offline): what it last said stays.
        client.onREST { _, _, _, _ in throw HTTPError(status: 503, body: nil) }
        await store.refreshPullRequests(for: rows, force: true)
        let failed = try #require(store.pullRequest(profile: "ivy", id: "same"))
        #expect(failed.state == SessionPRStatus.State.none && failed.repo == "owner/repo")
        let missing = SessionSummary(id: "missing", profile: "ivy", title: "", preview: nil, lastActive: nil,
                                     source: nil, unread: false, isRunning: false)
        await store.refreshPullRequests(for: [missing], force: true)
        #expect(store.pullRequest(profile: "ivy", id: "missing")?.state == .unknown)
        client.onREST { _, _, _, _ in Data("{\"sessions\":[]}".utf8) }
        await store.refreshPullRequests(for: rows, force: true)
        #expect(store.pullRequest(profile: "ivy", id: "same")?.state == .unknown)
        #expect(store.sessions.allSatisfy { $0.pullRequest == nil })
        store.stop()

        let old = BotsFakeGatewayClient()
        old.onREST { _, _, _, _ in throw HTTPError(status: 404, body: nil) }
        let oldStore = makeStore(old, autoStart: false)
        await oldStore.refreshPullRequests(for: rows)
        await oldStore.refreshPullRequests(for: [missing], force: true)
        #expect(prChecks(old) == 1)
        #expect(oldStore.pullRequest(profile: "ivy", id: "same")?.state == .unknown)
        // The add-on can be updated while the app runs: after the wait the route is asked again.
        oldStore.prRouteRetry = .milliseconds(50)
        try await Task.sleep(for: .milliseconds(120))
        old.onREST { _, _, _, _ in Data("{\"sessions\":[{\"profile\":\"ivy\",\"id\":\"same\",\"state\":\"draft\",\"number\":7}]}".utf8) }
        await oldStore.refreshPullRequests(for: rows, force: true)
        #expect(prChecks(old) == 2)
        #expect(oldStore.pullRequest(profile: "ivy", id: "same")?.state == .draft)
        oldStore.stop()
    }

    @Test func codingRowsStartUnknownAndUseOnlyFetchedStates() async throws {
        let client = BotsFakeGatewayClient()
        func row(_ id: String) -> JSONValue {
            var value = Self.srow(id).object!
            value["cwd"] = "/code/repo"
            return .object(value)
        }
        let sidebar = Self.sidebar([row("new"), row("draft"), row("omitted")])
        client.onREST { method, _, _, _ in
            if method == "GET" { return sidebar }
            return Data("{\"sessions\":[{\"profile\":\"ivy\",\"id\":\"new\",\"state\":\"none\"},{\"profile\":\"ivy\",\"id\":\"draft\",\"state\":\"draft\",\"number\":7}]}".utf8)
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.sessions.count == 3 })
        store.projectsByProfile["ivy"] = [SessionProject(id: "p", label: "Code", root: "/code/repo", paths: ["/code/repo"])]
        store.setCodingProject("/code/repo", true)
        #expect(store.sessions.allSatisfy { $0.pullRequest?.state == .unknown })
        await store.refreshPullRequests(for: store.sessions)
        #expect(store.sessions.first { $0.id == "new" }?.pullRequest?.state == SessionPRStatus.State.none)
        #expect(store.sessions.first { $0.id == "draft" }?.pullRequest?.state == .draft)
        #expect(store.sessions.first { $0.id == "omitted" }?.pullRequest?.state == .unknown)
        store.stop()
    }

    /// [pr-manage] The owner's links and marks: hidden until the gateway's list of repositories is read (and for good
    /// without the routes), a link replaces the project's own, a 422 names why, and a mark reads the chat's status again.
    @Test func repositoriesAreLinkedAndChatsMarkedClosed() async throws {
        let client = BotsFakeGatewayClient()
        let sidebar = Self.sidebar([Self.srow("a")])
        let repos = Self.prReposPath, mark = Self.prMarkPath
        client.onREST { method, path, _, body in
            if method == "GET", path == repos { return Data("{\"repos\":[{\"project\":null,\"path\":\"/by/hand\",\"main\":\"main\",\"public_repo\":null,\"mirror\":false}]}".utf8) }
            if method == "PUT", path == repos {
                let sent = try JSONValue.parse(body ?? Data())
                if sent["path"]?.string?.contains("nope") == true { throw HTTPError(status: 422, body: "{\"detail\":\"not_a_repository\"}") }
                if sent["public_repo"]?.string == "bad" { throw HTTPError(status: 422, body: "{\"detail\":\"invalid_public_repo\"}") }
                let answer: JSONValue = ["repo": ["project": sent["project"] ?? .null, "path": sent["path"] ?? .null, "main": "main",
                                                  "public_repo": sent["public_repo"] ?? .null, "mirror": .bool(sent["public_repo"]?.string != nil)]]
                return try answer.encoded()
            }
            if method == "DELETE", path == repos { return Data("{\"ok\":true}".utf8) }
            if method == "PUT", path == mark { return Data("{\"ok\":true,\"closed\":true}".utf8) }
            if method == "POST" { return Data("{\"sessions\":[{\"profile\":\"ivy\",\"id\":\"a\",\"state\":\"closed\",\"manual\":true}]}".utf8) }
            return sidebar
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.sessions.count == 1 })
        #expect(!store.prManage && store.prRepos == nil)
        #expect(!client.restCalls.contains { $0.path == repos })          // not asked with no coding project on screen
        await store.loadPRRepos()
        #expect(store.prManage)
        #expect(store.prRepos?.map(\.path) == ["/by/hand"] && store.prRepo(forProject: "/code/app") == nil)

        let linked = try await store.linkPRRepo(project: "/code/app", path: " /code/app ", publicRepo: "  ")
        #expect(linked.path == "/code/app" && linked.publicRepo == nil && !linked.mirror)
        let put = try #require(client.restCalls.last { $0.method == "PUT" && $0.path == repos })
        let sent = try JSONValue.parse(put.body ?? Data())
        #expect(sent["project"]?.string == "/code/app" && sent["path"]?.string == "/code/app" && sent["public_repo"] == .null)
        #expect(store.prRepo(forProject: "/code/app")?.path == "/code/app" && store.prRepos?.count == 2)
        let again = try await store.linkPRRepo(project: "/code/app", path: "/code/other", publicRepo: "owner/public")
        #expect(again.mirror && again.publicRepo == "owner/public" && store.prRepos?.count == 2)   // replaced, not added
        await #expect(throws: SessionPRRepoError.notARepository) { try await store.linkPRRepo(project: "/code/app", path: "/nope", publicRepo: nil) }
        await #expect(throws: SessionPRRepoError.invalidPublicRepo) { try await store.linkPRRepo(project: "/code/app", path: "/x", publicRepo: "bad") }
        #expect(store.prRepo(forProject: "/code/app")?.path == "/code/other")                      // a refused link changes nothing
        try await store.unlinkPRRepo(project: "/code/app")
        let deleted = try #require(client.restCalls.last { $0.method == "DELETE" })
        #expect(deleted.query == [URLQueryItem(name: "project", value: "/code/app")] && store.prRepo(forProject: "/code/app") == nil)

        let before = client.restCalls.filter { $0.path.hasSuffix("pr-status") }.count
        try await store.setPRClosed(store.sessions[0], true)
        let marked = try JSONValue.parse(try #require(client.restCalls.last { $0.path == mark }).body ?? Data())
        #expect(marked["profile"]?.string == "ivy" && marked["id"]?.string == "a" && marked["closed"] == .bool(true))
        #expect(client.restCalls.filter { $0.path.hasSuffix("pr-status") }.count == before + 1)      // read again at once
        #expect(store.pullRequest(profile: "ivy", id: "a")?.manual == true)
        store.stop()

        // A gateway without the routes: the list is never known, so nothing of this shows and nothing links itself.
        let old = BotsFakeGatewayClient()
        old.onREST { method, path, _, _ in
            if path == repos { throw HTTPError(status: 404, body: nil) }
            return sidebar
        }
        let oldStore = makeStore(old)
        #expect(await BotsTest.waitUntil { oldStore.sessions.count == 1 })
        await oldStore.loadPRRepos()
        #expect(old.restCalls.contains { $0.path == repos })
        oldStore.linkOwnFolderIfUnlinked("/code/app")
        try await Task.sleep(for: .milliseconds(80))
        #expect(!oldStore.prManage && !old.restCalls.contains { $0.method == "PUT" })
        oldStore.stop()
    }

    /// [repo-pickers] The Repository… page's choices: this project's repositories first (the linked one leading, its own
    /// folder when Hermes found none), every other one known by name, and the public names already linked.
    @Test func repositoryPageOffersKnownRepositories() async throws {
        let client = BotsFakeGatewayClient()
        let sidebar = Self.sidebar([Self.srow("a")])
        let repos = Self.prReposPath
        client.onREST { method, path, _, _ in
            if method == "GET", path == repos {
                return Data("""
                {"repos":[{"project":"/code/app","path":"/code/app-src","main":"main","public_repo":"me/app-public","mirror":true},
                {"project":null,"path":"/code/zeta","main":"main","public_repo":"me/zeta","mirror":false},
                {"project":null,"path":"/code/bad","main":"main","public_repo":"not a repo","mirror":false}]}
                """.utf8)
            }
            return sidebar
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.sessions.count == 1 })
        store.projectsByProfile = [
            "ivy": [SessionProject(id: "p1", label: "App", root: "/code/app", paths: ["/code/app"], repos: ["/code/app/", "/code/app-tools"]),
                    SessionProject(id: "p2", label: "Site", root: "/code/site", paths: ["/code/site"], repos: ["/code/site"])],
            "otto": [SessionProject(id: "p3", label: "Notes", root: "/code/notes", paths: ["/code/notes"]),
                     SessionProject(id: "p4", label: "Blog", root: "/code/Blog", paths: ["/code/Blog"], repos: ["/code/Blog", "/code/app-tools"])],
        ]
        var choices = store.repositoryFolderChoices(forProject: "/code/app")
        #expect(choices.here == ["/code/app", "/code/app-tools"] && choices.elsewhere == ["/code/Blog", "/code/site"])
        await store.loadPRRepos()
        choices = store.repositoryFolderChoices(forProject: "/code/app")
        #expect(choices.here == ["/code/app-src", "/code/app", "/code/app-tools"])
        #expect(choices.elsewhere == ["/code/bad", "/code/Blog", "/code/site", "/code/zeta"])
        #expect(store.repositoryFolderChoices(forProject: "/code/notes").here == ["/code/notes"])   // no repos found: its own folder
        #expect(store.repositoryFolderChoices(forProject: "id:ivy/x").here.isEmpty)
        #expect(store.publicRepoChoices() == ["me/app-public", "me/zeta"])
        store.stop()
    }

    @Test func publicRepositoryIsReadOutOfALink() {
        #expect(SessionStore.ownerRepo(from: " https://github.com/me/app ") == "me/app")
        #expect(SessionStore.ownerRepo(from: "https://github.com/me/app/pull/12") == "me/app")
        #expect(SessionStore.ownerRepo(from: "git@github.com:me/app.git") == "me/app")
        #expect(SessionStore.ownerRepo(from: "github.com/me/app.git") == "me/app")
        #expect(SessionStore.ownerRepo(from: "me/app") == "me/app")
        #expect(SessionStore.isOwnerRepo("me/app") && !SessionStore.isOwnerRepo("me app") && !SessionStore.isOwnerRepo("/code/app"))
        #expect(SessionStore.folderName("/code/app/") == "app" && SessionStore.tidyFolder(" /code/app// ") == "/code/app")
    }

    nonisolated private static let prReposPath = "/api/plugins/hermes-hq-push/sessions/pr-repos"
    nonisolated private static let prMarkPath = "/api/plugins/hermes-hq-push/sessions/pr-mark"

    /// [pr-instant] The marks are there the moment the app opens: the last answers are kept on disk and drawn before
    /// anything is asked; a chat whose status wasn't known isn't kept; chunks are asked for together.
    @Test func marksAreDrawnAtLaunchFromTheLastAnswers() async throws {
        let dir = BotsTest.tempDirectory()
        func row(_ id: String) -> JSONValue {
            var value = Self.srow(id).object!
            value["cwd"] = "/code/repo"
            return .object(value)
        }
        let sidebar = Self.sidebar([row("merged"), row("draft"), row("unknown")])
        let client = BotsFakeGatewayClient()
        client.onREST { method, _, _, _ in
            if method == "GET" { return sidebar }
            return Data("{\"sessions\":[{\"profile\":\"ivy\",\"id\":\"merged\",\"state\":\"merged\",\"number\":7,\"url\":\"https://github.com/o/r/pull/7\"},{\"profile\":\"ivy\",\"id\":\"draft\",\"state\":\"draft\",\"branch\":\"feat/x\",\"manual\":false},{\"profile\":\"ivy\",\"id\":\"unknown\",\"state\":\"unknown\"}]}".utf8)
        }
        let store = makeStore(client, dir: dir)
        #expect(await BotsTest.waitUntil { store.sessions.count == 3 })
        store.projectsByProfile["ivy"] = [SessionProject(id: "p", label: "Code", root: "/code/repo", paths: ["/code/repo"])]
        store.setCodingProject("/code/repo", true)
        await store.refreshPullRequests(for: store.sessions, force: true)
        #expect(store.pullRequest(profile: "ivy", id: "merged")?.state == .merged)
        store.stop()
        RosterDiskWriter.shared.flush()

        // The next launch, with a gateway that hasn't answered anything yet.
        let quiet = BotsFakeGatewayClient()
        quiet.onREST { _, _, _, _ in try await Task.sleep(for: .seconds(30)); return Data() }
        let next = makeStore(quiet, dir: dir, autoStart: false)
        let merged = try #require(next.pullRequest(profile: "ivy", id: "merged"))
        #expect(merged.state == .merged && merged.number == 7 && merged.url?.host == "github.com")
        #expect(next.pullRequest(profile: "ivy", id: "draft")?.branch == "feat/x")
        #expect(next.pullRequest(profile: "ivy", id: "unknown") == nil)          // never a kept "?"
        #expect(prChecks(quiet) == 0)
        next.stop()

        // 70 chats: three requests in flight together, not one after another.
        let wide = BotsFakeGatewayClient()
        wide.onREST { _, _, _, _ in try await Task.sleep(for: .milliseconds(300)); return Data("{\"sessions\":[]}".utf8) }
        let wideStore = makeStore(wide, autoStart: false)
        let rows = (0..<70).map { SessionSummary(id: "\($0)", profile: "ivy", title: "", preview: nil, lastActive: nil,
                                                 source: nil, unread: false, isRunning: false) }
        let asking = Task { await wideStore.refreshPullRequests(for: rows) }
        #expect(await BotsTest.waitUntil(.milliseconds(250)) { prChecks(wide) == 3 })
        await asking.value
        wideStore.stop()
    }

    @Test func pullRequestDiscoveryIsScopedAndCached() async throws {
        let client = BotsFakeGatewayClient()
        func row(_ id: String, _ cwd: String) -> JSONValue {
            var value = Self.srow(id).object!
            value["cwd"] = .string(cwd)
            return .object(value)
        }
        let sidebar = Self.sidebar([row("a", "/code/repo"), row("b", "/lanes/work"), row("c", "/code/repo/nested")])
        client.on("projects.tree") { _ in
            ["projects": [["id": "p", "path": "/code/repo", "repos": [["path": "/lanes"]]],
                          ["id": "nested", "path": "/code/repo/nested"]]]
        }
        client.onREST { method, _, _, body in
            if method == "GET" { return sidebar }
            let data = try #require(body)
            let rows = try #require(JSONValue.parse(data)["sessions"]?.array)
            return try JSONValue.object(["sessions": .array(rows.map { ["profile": $0["profile"] ?? .null,
                "id": $0["id"] ?? .null, "state": "open"] })]).encoded()
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.sessions.count == 3 })
        let project = SessionProject(id: "p", label: "Code", root: "/code/repo", paths: ["/code/repo", "/lanes"])
        let nested = SessionProject(id: "nested", label: "Nested", root: "/code/repo/nested", paths: ["/code/repo/nested"])
        store.projectsByProfile["ivy"] = [project, nested]
        store.setFocusedSession("a")
        store.setChatFocused(true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!client.restCalls.contains { $0.path.hasSuffix("pr-status") })
        store.setCodingProject("/code/repo", true)
        #expect(await BotsTest.waitUntil { store.pullRequest(profile: "ivy", id: "a") != nil })
        #expect(store.pullRequest(profile: "ivy", id: "b") == nil)
        store.setChatFocused(false)
        store.setListVisible(true)
        #expect(await BotsTest.waitUntil { store.pullRequest(profile: "ivy", id: "b") != nil })
        #expect(store.pullRequest(profile: "ivy", id: "c") == nil)
        let calls = client.restCalls.filter { $0.path.hasSuffix("pr-status") }.count
        await store.refreshPullRequests(for: store.sessions)
        #expect(client.restCalls.filter { $0.path.hasSuffix("pr-status") }.count == calls + 1) // explicit API includes c
        store.setCodingProject("/code/repo", false)
        #expect(store.pullRequest(profile: "ivy", id: "a") == nil)
        #expect(store.sessions.allSatisfy { $0.pullRequest == nil })
        let stoppedCalls = client.restCalls.filter { $0.path.hasSuffix("pr-status") }.count
        store.setListVisible(false); store.setListVisible(true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.restCalls.filter { $0.path.hasSuffix("pr-status") }.count == stoppedCalls)
        store.stop()
    }

    @Test func overlappingPullRequestChecksCoalesce() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in
            try await Task.sleep(for: .milliseconds(100))
            return Data("{\"sessions\":[{\"profile\":\"ivy\",\"id\":\"a\",\"state\":\"open\"}]}".utf8)
        }
        let store = makeStore(client, autoStart: false)
        let row = SessionSummary(id: "a", profile: "ivy", title: "", preview: nil, lastActive: nil,
                                 source: nil, unread: false, isRunning: false)
        let first = Task { await store.refreshPullRequests(for: [row]) }
        #expect(await BotsTest.waitUntil { prChecks(client) == 1 })
        await store.refreshPullRequests(for: [row])
        await first.value
        #expect(prChecks(client) == 1)
        #expect(store.pullRequest(profile: "ivy", id: "a")?.state == .open)
    }

    @Test func disablingCodingProjectDiscardsInFlightDiscovery() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in
            try await Task.sleep(for: .milliseconds(150))
            return Data("{\"sessions\":[{\"profile\":\"ivy\",\"id\":\"a\",\"state\":\"open\"}]}".utf8)
        }
        let store = makeStore(client, autoStart: false)
        store.projectsByProfile["ivy"] = [SessionProject(id: "p", label: "Code", root: "/code", paths: ["/code"])]
        store.setCodingProject("/code", true)
        var row = SessionSummary(id: "a", profile: "ivy", title: "", preview: nil, lastActive: nil,
                                 source: nil, unread: false, isRunning: false)
        row.cwd = "/code/work"
        let request = Task { await store.refreshCodingPullRequest(for: row) }
        #expect(await BotsTest.waitUntil { prChecks(client) == 1 })
        store.setCodingProject("/code", false)
        await request.value
        #expect(store.pullRequest(profile: "ivy", id: "a") == nil)
        #expect(!store.isCodingSession(profile: "ivy", cwd: row.cwd))
    }

    @Test func pullRequestLinksRequireExactGitHubPullPath() async throws {
        let urls = ["https://github.com/owner/repo/pull/42", "http://github.com/owner/repo/pull/42",
                    "https://github.com.evil.test/owner/repo/pull/42", "https://github.com/owner/repo/issues/42",
                    "https://github.com/owner/repo/pull/0", "https://github.com/owner/repo/pull/42/extra",
                    "https://user@github.com/owner/repo/pull/42", "https://github.com/owner/repo/pull/42?x=1"]
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, body in
            let data = try #require(body)
            let rows = try #require(JSONValue.parse(data)["sessions"]?.array)
            let results: [JSONValue] = rows.map { row in
                let id = row["id"]?.string ?? "0"
                return ["profile": "ivy", "id": .string(id), "state": "open", "url": .string(urls[Int(id)!])]
            }
            return try JSONValue.object(["sessions": .array(results)]).encoded()
        }
        let store = makeStore(client, autoStart: false)
        let rows = urls.indices.map { SessionSummary(id: "\($0)", profile: "ivy", title: "", preview: nil,
                                                      lastActive: nil, source: nil, unread: false, isRunning: false) }
        await store.refreshPullRequests(for: rows)
        #expect(store.pullRequest(profile: "ivy", id: "0")?.url != nil)
        for index in urls.indices.dropFirst() { #expect(store.pullRequest(profile: "ivy", id: "\(index)")?.url == nil) }
        #expect(SessionPRStatus(state: .none).label == "No PR yet")
        #expect(SessionPRStatus(state: .unknown).label == "PR status unknown")
    }

    @Test func scopedInvalidationPreservesOtherProjectsAndTransientFailuresRetryImmediately() async throws {
        let client = BotsFakeGatewayClient()
        func row(_ id: String, _ cwd: String) -> JSONValue {
            var value = Self.srow(id).object!
            value["cwd"] = .string(cwd)
            return .object(value)
        }
        let sidebar = Self.sidebar([row("a", "/code/a"), row("b", "/code/b")])
        @Sendable func okHandler(_ method: String, _ path: String, _: [URLQueryItem], _ body: Data?) async throws -> Data {
            if method == "GET", path.contains("sidebar") { return sidebar }
            if path.hasSuffix("pr-repos") { return Data("{\"repos\":[]}".utf8) }
            let data = try #require(body)
            let rows = try #require(JSONValue.parse(data)["sessions"]?.array)
            return try JSONValue.object(["sessions": .array(rows.map {
                ["profile": $0["profile"] ?? .null, "id": $0["id"] ?? .null, "state": "open", "number": 10]
            })]).encoded()
        }
        client.onREST(okHandler)
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.sessions.count == 2 })
        store.projectsByProfile["ivy"] = [
            SessionProject(id: "pa", label: "A", root: "/code/a", paths: ["/code/a"]),
            SessionProject(id: "pb", label: "B", root: "/code/b", paths: ["/code/b"])
        ]
        store.setCodingProject("/code/a", true)
        store.setCodingProject("/code/b", true)
        await store.refreshPullRequests(for: store.sessions, force: true)
        #expect(store.pullRequest(profile: "ivy", id: "a")?.state == .open)
        #expect(store.pullRequest(profile: "ivy", id: "b")?.state == .open)

        // Turning off project B drops B's marks without wiping project A's marks!
        store.setCodingProject("/code/b", false)
        #expect(store.pullRequest(profile: "ivy", id: "a")?.state == .open)
        #expect(store.pullRequest(profile: "ivy", id: "b") == nil)

        // Updating projectsByProfile keeps project A's cached mark (stale-while-revalidate).
        store.projectsByProfile["otto"] = [SessionProject(id: "pc", label: "C", root: "/code/c", paths: ["/code/c"])]
        #expect(store.pullRequest(profile: "ivy", id: "a")?.state == .open)

        // Transient failure on a new row must NOT poison its 60s cooldown.
        client.onREST { _, _, _, _ in throw HTTPError(status: 503, body: nil) }
        let fresh = SessionSummary(id: "new-row", profile: "ivy", title: "New", preview: nil, lastActive: nil,
                                   source: nil, unread: false, isRunning: false)
        await store.refreshPullRequests(for: [fresh], force: false)
        #expect(store.pullRequest(profile: "ivy", id: "new-row")?.unknownReason == .unavailable)
        client.onREST(okHandler)
        await store.refreshPullRequests(for: [fresh], force: false)
        #expect(store.pullRequest(profile: "ivy", id: "new-row")?.state == .open)
        store.stop()
    }

    @Test func forcedRefreshIsNotDroppedOrOverwrittenByInFlightBackgroundPoll() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, body in
            let req = try JSONValue.parse(#require(body))
            let isFresh = req["fresh"]?.bool == true
            if !isFresh {
                try await Task.sleep(for: .milliseconds(200))
                return Data("{\"sessions\":[{\"profile\":\"ivy\",\"id\":\"a\",\"state\":\"open\",\"number\":12}]}".utf8)
            }
            return Data("{\"sessions\":[{\"profile\":\"ivy\",\"id\":\"a\",\"state\":\"merged\",\"number\":12}]}".utf8)
        }
        let store = makeStore(client, autoStart: false)
        let row = SessionSummary(id: "a", profile: "ivy", title: "A", preview: nil, lastActive: nil,
                                 source: nil, unread: false, isRunning: false)
        let poll = Task { await store.refreshPullRequests(for: [row], force: false) }
        #expect(await BotsTest.waitUntil { prChecks(client) == 1 })
        // While background poll is still in flight, an explicit forced check runs immediately and wins.
        await store.refreshPullRequests(for: [row], force: true)
        #expect(store.pullRequest(profile: "ivy", id: "a")?.state == .merged)
        await poll.value
        #expect(store.pullRequest(profile: "ivy", id: "a")?.state == .merged)
        store.stop()
    }

    @Test func firstCodingToggleAwaitsPRReposAndAutoLinksWithoutRace() async throws {
        let client = BotsFakeGatewayClient()
        let repos = Self.prReposPath
        client.onREST { method, path, _, body in
            if method == "GET", path == repos {
                try await Task.sleep(for: .milliseconds(60))
                return Data("{\"repos\":[]}".utf8)
            }
            if method == "PUT", path == repos {
                let sent = try JSONValue.parse(body ?? Data())
                if sent["path"]?.string == "/not-a-repo" {
                    throw HTTPError(status: 422, body: "{\"detail\":\"not_a_repository\"}")
                }
                let answer: JSONValue = ["repo": ["project": sent["project"] ?? .null, "path": sent["path"] ?? .null,
                                                  "main": "main", "public_repo": "example/app", "mirror": false]]
                return try answer.encoded()
            }
            return Self.sidebar([])
        }
        let store = makeStore(client, autoStart: false)
        #expect(store.prRepos == nil && store.prReposState == .unknown)
        store.setCodingProject("/code/app", true)
        #expect(await BotsTest.waitUntil(.seconds(2)) { store.prRepo(forProject: "/code/app")?.path == "/code/app" })

        // A folder that isn't a git repo records itself in prAutoLinkFailed instead of failing silently.
        store.setCodingProject("/not-a-repo", true)
        #expect(await BotsTest.waitUntil(.seconds(2)) { store.prAutoLinkFailed.contains("/not-a-repo") })
        store.stop()
    }

    @Test func multiBotSessionInSharedRepoResolvesToCodingProject() {
        let store = makeStore(BotsFakeGatewayClient(), autoStart: false)
        store.projectsByProfile["ivy"] = [SessionProject(id: "p1", label: "App", root: "/code/app", paths: ["/code/app", "/worktrees/app-1"])]
        store.setCodingProject("/code/app", true)
        // Bot "otto" doesn't have /code/app in its own projectsByProfile yet, but works in its worktree.
        #expect(store.isCodingSession(profile: "otto", cwd: "/worktrees/app-1/sub"))
        #expect(!store.isCodingSession(profile: "otto", cwd: "/unrelated/folder"))
        store.stop()
    }

    @Test func demoSidebarDecodes() throws {
        let payload = try SidebarPayload.decode(BotsFixture.json("demo-sidebar"))
        #expect(payload.recents.rows?.count == 7)
        #expect(payload.cron.rows?.isEmpty == true && payload.messaging.rows?.isEmpty == true)
        #expect(payload.fingerprint != nil)
        let first = try #require(payload.recents.rows?.first)
        #expect(first.id == "20261001_084000_bb000001" && first.profile == "deploys" && first.pinned == true)
        #expect(first.messageCount == 2 && first.toolCallCount == 0)
        // The empty fixture answer (spec 02 §9.1).
        let empty = try SidebarPayload.decode(BotsFixture.json("perf-sidebar"))
        #expect(empty.recents.rows == [] && !empty.recents.failed)
    }

    @Test func loadsOrdersAndNamesRows() async throws {
        let data = try BotsFixture.data("demo-sidebar")
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in data }
        let dir = BotsTest.tempDirectory()
        let store = makeStore(client, dir: dir)
        store.profileDisplayNames = ["deploys": "Deploys"]
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.sessions.map(\.title) == ["Cut the 2.4 branch", "Notes on open planning", "Push the release tag",
                                                "Q3 reconciliation", "Frost plan", "Pump quotes compared", "Weekly review"])
        let pinned = store.sessions[0]
        #expect(store.ownerName(for: pinned) == "Deploys")
        #expect(store.ownerName(for: store.sessions[1]) == "Research")
        #expect(store.detailLine(for: pinned).hasPrefix("Deploys · The 2.4 branch is cut"))
        // [toolnow] A running chat names its step; a chat that isn't running ignores one.
        store.setSteps([pinned.id: "running npm test"])
        #expect(store.sessions[0].step == nil)
        store.setRunning([pinned.id])
        #expect(store.sessions[0].step == "running npm test")
        #expect(store.detailLine(for: store.sessions[0]) == "Deploys · Running npm test…")
        store.setSteps([:])
        #expect(store.detailLine(for: store.sessions[0]) == "Deploys · Working…")
        store.setRunning([])
        #expect(store.sessions.allSatisfy { !$0.unread })                  // fresh install: watermarks seeded
        let sections = store.sections()
        #expect(sections.first?.title == "Pinned" && sections.first?.sessions.map(\.id) == [pinned.id])
        #expect(sections.dropFirst().flatMap(\.sessions).count == 6)
        let query = try #require(client.restCalls.first)
        #expect(query.path == "/api/profiles/sessions/sidebar")
        #expect(query.query.contains(URLQueryItem(name: "recents_profile", value: "all")))
        #expect(query.query.contains(URLQueryItem(name: "cron_limit", value: "50")))
        #expect(query.query.contains(URLQueryItem(name: "messaging_limit", value: "100")))
        #expect(query.query.contains(URLQueryItem(name: "profile", value: "default")))
        #expect(query.query.contains(URLQueryItem(name: "recents_exclude", value: SessionStore.recentsExclude)))
        store.stop()
        RosterDiskWriter.shared.flush()

        // Next launch paints from the cache synchronously.
        let again = makeStore(BotsFakeGatewayClient(), dir: dir, autoStart: false)
        #expect(again.sessions.map(\.id) == store.sessions.map(\.id))
    }

    @Test func hidesBackgroundRunsAndBotChats() async throws {
        let data = Self.sidebar([
            Self.srow("chat", lastActive: 100),
            Self.srow("tool", lastActive: 200, source: "tool"),
            Self.srow("sub", lastActive: 300, source: "subagent"),
            Self.srow("pinned-kanban", lastActive: 50, source: "kanban", pinned: true),
            Self.srow("botchat", title: "Bot Chat", lastActive: 400, hidden: true),
            Self.srow("untitled", title: .null, preview: "", lastActive: 90),
            Self.srow("markup", title: "<codex_open>{\"x\":1}</codex_open>", preview: "Real words", lastActive: 80),
            Self.srow("switch", title: .null, preview: "[System: The active model for this chat has changed to m2.]", lastActive: 70),
        ], messaging: [Self.srow("oneoff", lastActive: 10, source: "oneshot"), Self.srow("tg", lastActive: 20, source: "telegram")])
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in data }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.sessions.map(\.id) == ["pinned-kanban", "chat", "untitled", "markup", "switch"])
        #expect(store.sessions.map(\.title) == ["Chat", "Chat", "Untitled Chat", "Real words", "Model changed to m2"])
        #expect(store.messagingSessions.map(\.id) == ["tg"])
        store.showBackgroundRuns = true
        #expect(store.sessions.map(\.id) == ["pinned-kanban", "sub", "tool", "chat", "untitled", "markup", "switch"])
        #expect(store.messagingSessions.map(\.id) == ["tg", "oneoff"])
        store.stop()
    }

    @Test func outsideChatsGetAnOtherAppsRowOnceTurnedOn() async throws {
        let data = Self.sidebar([Self.srow("chat", lastActive: 100)],
                                messaging: [Self.srow("tg", lastActive: 200, source: "telegram"),
                                            Self.srow("tg2", lastActive: 150, source: "telegram"),
                                            Self.srow("api", lastActive: 50, source: "api_server"),
                                            Self.srow("oneoff", lastActive: 10, source: "oneshot")])
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in data }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(!store.showOutsideChats && store.liveRows.map(\.id) == ["chat"])
        #expect(!store.listGroups().contains { $0.id == SessionListPipeline.otherAppsId })
        store.showOutsideChats = true
        #expect(Set(store.liveRows.map(\.id)) == ["chat", "tg", "tg2", "api"])           // search reaches them
        #expect(store.liveRows.first { $0.id == "tg" }?.origin == "telegram" && store.liveRows.first { $0.id == "chat" }?.origin == nil)
        let groups = store.listGroups()
        let apps = groups.first { $0.id == SessionListPipeline.otherAppsId }
        #expect(groups.first?.id == SessionListPipeline.otherAppsId)                       // first: nothing pinned
        #expect(apps?.platforms == ["telegram", "api_server"] && apps?.total == 3)          // newest platform first
        #expect(groups.allSatisfy { $0.source == nil })
        let sections = store.appSections()
        #expect(sections.map(\.title) == ["Telegram", "API"] && sections.first?.sessions.map(\.id) == ["tg", "tg2"])
        store.showOutsideChats = false
        #expect(store.liveRows.map(\.id) == ["chat"] && !store.listGroups().contains { $0.id == SessionListPipeline.otherAppsId })
        store.stop()
    }

    /// One-off runs (`oneshot`: a script's "Reply with exactly OK" probe) come in the messaging slice; with
    /// Show › Background Runs they get a "One-off Runs" section on the Other Apps page, Outside Chats on or off.
    @Test func oneOffRunsGetASectionWithBackgroundRuns() async throws {
        let data = Self.sidebar([Self.srow("chat", lastActive: 100)],
                                messaging: [Self.srow("tg", lastActive: 200, source: "telegram"),
                                            Self.srow("ok", title: "Reply with exactly OK", lastActive: 300, source: "oneshot")])
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in data }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        store.showOutsideChats = true
        #expect(store.appSections().map(\.title) == ["Telegram"])                          // runs stay hidden by default
        store.showBackgroundRuns = true
        var apps = store.listGroups().first { $0.id == SessionListPipeline.otherAppsId }
        #expect(apps?.platforms == ["oneshot", "telegram"] && apps?.total == 2)
        var sections = store.appSections()
        #expect(sections.map(\.title) == ["One-off Runs", "Telegram"] && sections.first?.sessions.map(\.id) == ["ok"])
        #expect(Set(store.liveRows.map(\.id)) == ["chat", "tg", "ok"])                     // search reaches it
        #expect(store.liveRows.first { $0.id == "ok" }?.unread == false)
        // Outside Chats off: the row stays for the runs alone.
        store.showOutsideChats = false
        apps = store.listGroups().first { $0.id == SessionListPipeline.otherAppsId }
        #expect(apps?.platforms == ["oneshot"] && apps?.total == 1)
        sections = store.appSections()
        #expect(sections.map(\.title) == ["One-off Runs"])
        store.showBackgroundRuns = false
        #expect(!store.listGroups().contains { $0.id == SessionListPipeline.otherAppsId })
        store.stop()
    }

    /// [n20-sessions F1] Scheduled job runs (the cron slice, `source = "cron"`) get a "Scheduled Runs" section on the
    /// Other Apps page with Show › Background Runs, beside the one-off runs; never in the dated list, never unread, never
    /// on the tab's badge; hidden by default.
    @Test func scheduledRunsGetASectionWithBackgroundRuns() async throws {
        let data = Self.sidebar([Self.srow("chat", lastActive: 100)],
                                cron: [Self.srow("cron_daily_1", title: "Daily standup", lastActive: 400, source: "cron", unread: true),
                                       Self.srow("cron_daily_0", title: "Daily standup", lastActive: 50, source: "cron")],
                                messaging: [Self.srow("ok", title: "Reply with exactly OK", lastActive: 300, source: "oneshot")])
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in data }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.sessions.map(\.id) == ["chat"])
        #expect(!store.listGroups().contains { $0.id == SessionListPipeline.otherAppsId })   // hidden by default
        #expect(store.appSections().isEmpty)
        store.showOutsideChats = true
        #expect(store.appSections().isEmpty, "Outside Chats alone does not bring scheduled runs")
        store.showBackgroundRuns = true
        let apps = store.listGroups().first { $0.id == SessionListPipeline.otherAppsId }
        #expect(apps?.platforms == ["cron", "oneshot"] && apps?.total == 3)
        let sections = store.appSections()
        #expect(sections.map(\.title) == ["Scheduled Runs", "One-off Runs"])
        #expect(sections.first?.sessions.map(\.id) == ["cron_daily_1", "cron_daily_0"])
        #expect(store.sessions.map(\.id) == ["chat"], "never among the dated rows")
        #expect(Set(store.liveRows.map(\.id)) == ["chat", "ok", "cron_daily_1", "cron_daily_0"])   // search reaches them
        #expect(store.liveRows.filter { $0.source == "cron" }.allSatisfy { !$0.unread })
        #expect(store.unreadCount == 0, "a run never adds to the badge")
        store.showBackgroundRuns = false
        #expect(!store.listGroups().contains { $0.id == SessionListPipeline.otherAppsId })
        store.stop()
    }

    @Test func failedScanKeepsRowsAndAsksForRetry() async throws {
        let healthy = Self.sidebar([Self.srow("a")])
        let broken = try! (["recents": ["failed": true, "retry": true], "cron": ["sessions": []], "messaging": ["sessions": []]] as JSONValue).encoded()
        let body = BotsTestBox(healthy)
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in body.value }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        body.value = broken
        await store.refresh()
        #expect(store.sessions.map(\.id) == ["a"])
        if case .failed = store.loadState {} else { Issue.record("expected a failed state, got \(store.loadState)") }
        store.stop()
    }

    // MARK: Unread (§9.3)

    @Test func unreadWatermarksAndTheOpenTimePatch() async throws {
        let rows = BotsTestBox([Self.srow("quiet", count: 2), Self.srow("srv", profile: "inbox", count: 5)])
        let client = BotsFakeGatewayClient()
        client.onREST { method, _, _, _ in
            if method == "PATCH" {
                // The gateway stamps last_read_at: its next pages say read.
                rows.mutate { $0 = $0.map { row in row["id"] == "srv" ? Self.srow("srv", profile: "inbox", count: 5, unread: false) : row } }
                return try! (["ok": true, "unread": false] as JSONValue).encoded()
            }
            return Self.sidebar(rows.value)
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.sessions.allSatisfy { !$0.unread })

        // New messages past the seen watermark, and a server-side unread flag.
        rows.value = [Self.srow("quiet", count: 4), Self.srow("srv", profile: "inbox", count: 5, unread: true)]
        await store.refresh()
        #expect(store.sessions.first { $0.id == "quiet" }?.unread == true)
        #expect(store.sessions.first { $0.id == "srv" }?.unread == true)
        #expect(store.unreadCount == 2)

        // Opening a row the server does not call unread clears it here, and ([read-sync]) the read is written all the
        // same: the gateway has no watermark for the chat yet, and the person's other device shows the same dot.
        store.markOpened(store.sessions.first { $0.id == "quiet" }!)
        #expect(store.sessions.first { $0.id == "quiet" }?.unread == false)
        #expect(await BotsTest.waitUntil { client.restCalls.contains { $0.method == "PATCH" && $0.path == "/api/sessions/quiet" } })

        // Opening the server-unread row sends exactly the web's PATCH, optimistically.
        store.markOpened(store.sessions.first { $0.id == "srv" }!)
        #expect(store.sessions.first { $0.id == "srv" }?.unread == false)
        #expect(await BotsTest.waitUntil { client.restCalls.contains { $0.method == "PATCH" && $0.path == "/api/sessions/srv" } })
        let patch = try #require(client.restCalls.first { $0.method == "PATCH" && $0.path == "/api/sessions/srv" })
        #expect(patch.path == "/api/sessions/srv")
        #expect(patch.query == [URLQueryItem(name: "profile", value: "inbox")])
        #expect(try JSONValue.parse(patch.body ?? Data()) == ["unread": false, "profile": "inbox"])
        await store.refresh()
        #expect(store.sessions.first { $0.id == "srv" }?.unread == false)
        store.stop()

        // A failed write rolls the dot back.
        let client2 = BotsFakeGatewayClient()
        client2.onREST { method, _, _, _ in
            if method == "PATCH" { throw HTTPError(status: 500, body: nil) }
            return Self.sidebar([Self.srow("srv", profile: "inbox", count: 5, unread: true)])
        }
        let other = makeStore(client2)
        #expect(await BotsTest.waitUntil { other.loadState == .ready })
        other.markOpened(other.sessions[0])
        #expect(await BotsTest.waitUntil { other.sessions.first?.unread == true })
        other.stop()
    }

    /// [unread-working] A chat still at work is not New for You for what its own turn stored (steps, helpers' results,
    /// notes): the dot comes with the reply, when the turn ends. A tester's chats sat under New and Working at once.
    @Test func aWorkingChatIsUnreadOnlyOnceItsTurnEnds() async throws {
        let rows = BotsTestBox([Self.srow("busy", count: 2), Self.srow("flagged", count: 3), Self.srow("marked", count: 4)])
        let client = BotsFakeGatewayClient()
        client.onREST { method, _, _, _ in
            method == "PATCH" ? try! (["ok": true, "unread": true] as JSONValue).encoded() : Self.sidebar(rows.value)
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        store.setRunning(["busy", "flagged", "marked"])
        // Rows stored mid-turn move the count, and the gateway's own flag with it.
        rows.value = [Self.srow("busy", count: 9), Self.srow("flagged", count: 7, unread: true), Self.srow("marked", count: 4)]
        await store.refresh()
        #expect(store.sessions.count == 3)
        #expect(store.sessions.allSatisfy { !$0.unread && $0.isRunning })
        #expect(store.unreadCount == 0)
        #expect(!store.anyUnread)

        // Mark as Unread is the person's own word: it shows on a working chat too.
        store.setUnread(store.sessions.first { $0.id == "marked" }!, true)
        #expect(store.sessions.first { $0.id == "marked" }?.unread == true)
        #expect(store.sessions.first { $0.id == "busy" }?.unread == false)

        // The turns end: the replies are there to read.
        store.setRunning([])
        #expect(store.sessions.allSatisfy { $0.unread && !$0.isRunning })
        #expect(store.unreadCount == 3)
        store.stop()
    }

    @Test func unopenedCompactedChatFollowsTheRunningTurn() async throws {
        var tip = try #require(Self.srow("tip", unread: true).object)
        tip["_lineage_root_id"] = "root"
        tip["_lineage_ids"] = ["root", "middle", "tip"]
        var fork = try #require(Self.srow("fork").object)
        fork["parent_session_id"] = "root"
        let data = Self.sidebar([.object(tip), .object(fork)])
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in data }
        let store = makeStore(client)
        defer { store.stop() }
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        for id in ["root", "middle", "tip"] {
            store.setRunning([id])
            store.setSteps([id: "Reading files"])
            let row = try #require(store.sessions.first { $0.id == "tip" })
            #expect(row.isRunning && row.status == .working && !row.unread)
            #expect(row.step == "Reading files")
            store.setNeedsInput([id])
            #expect(store.sessions.first { $0.id == "tip" }?.status == .needsInput)
            #expect(store.sessions.first { $0.id == "fork" }?.status == .idle)
            store.setNeedsInput([])
        }
        store.setRunning([])
        #expect(store.sessions.first { $0.id == "tip" }?.status == .unread)
    }

    /// [unread-working] The gateway lists a chat it compacted under its newest part's id, with that part's short count.
    /// The chat on screen stays the selected one through that, so its next stored row is seen, not a dot.
    @Test func theSelectedChatStaysReadThroughACompaction() async throws {
        func part(_ id: String, count: Int) -> JSONValue {
            guard case .object(var row) = Self.srow(id, count: count) else { return .null }
            row["_lineage_root_id"] = "open"
            return .object(row)
        }
        let rows = BotsTestBox([Self.srow("open", count: 40), Self.srow("other", count: 2)])
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.sidebar(rows.value) }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        store.setFocusedSession("open")

        rows.value = [part("open-2", count: 3), Self.srow("other", count: 2)]
        await store.refresh()
        rows.value = [part("open-2", count: 6), Self.srow("other", count: 2)]
        await store.refresh()
        #expect(store.sessions.first { $0.id == "open-2" }?.unread == false)
        // A second compaction, from the part the selection moved to.
        rows.value = [part("open-3", count: 2), Self.srow("other", count: 2)]
        await store.refresh()
        rows.value = [part("open-3", count: 5), Self.srow("other", count: 2)]
        await store.refresh()
        #expect(store.sessions.first { $0.id == "open-3" }?.unread == false)

        // Another chat takes the selection: the compacted one is an ordinary chat again.
        store.setFocusedSession("other")
        rows.value = [part("open-3", count: 8), Self.srow("other", count: 2)]
        await store.refresh()
        #expect(store.sessions.first { $0.id == "open-3" }?.unread == true)
        store.stop()
    }

    @Test func readOnlyGatewayClearsLocallyWithoutWriting() async throws {
        let rows = BotsTestBox([Self.srow("srv", count: 5, unread: true)])
        let client = BotsFakeGatewayClient()
        client.onREST { method, _, _, _ in
            if method == "PATCH" { Issue.record("read-only gateway must not be written") }
            return Self.sidebar(rows.value)
        }
        let store = makeStore(client)
        store.readOnlyGateway = true
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.sessions[0].unread)
        store.markOpened(store.sessions[0])
        #expect(!store.sessions[0].unread)
        await store.refresh()
        #expect(!store.sessions[0].unread)
        // The session moves on: the server's dot shows again.
        rows.value = [Self.srow("srv", lastActive: 1_791_000_500, count: 7, unread: true)]
        await store.refresh()
        #expect(store.sessions[0].unread)
        #expect(client.restCalls.allSatisfy { $0.method == "GET" })
        store.stop()
    }

    // MARK: Change broadcasts (spec 03 §7.7)

    @Test func changeTicksAreThrottledOnScreen() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.sidebar([Self.srow("a")]) }
        let store = makeStore(client)
        store.setListVisible(true)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        for _ in 0..<5 { client.emit("sessions.changed") }
        #expect(await BotsTest.waitUntil { probes(client) == 1 })         // leading edge
        try await Task.sleep(for: .milliseconds(700))
        #expect(probes(client) == 2)                                      // one trailing pass, never stacked
        // [log review 2026-11-18] On screen too a pass is the probe first: the same answer costs no full read.
        #expect(fullReads(client) == 1)
        store.stop()
    }

    @Test func offScreenTicksProbeFirst() async throws {
        let differs = BotsTestBox(false)
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, query, _ in
            let probe = query.contains(URLQueryItem(name: "recents_limit", value: "1"))
            return Self.sidebar([Self.srow("a", lastActive: probe && differs.value ? 1_791_000_999 : 1_791_000_000)])
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        client.emit("sessions.changed")
        #expect(await BotsTest.waitUntil { probes(client) == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(fullReads(client) == 1)                                   // same fingerprint: no full read
        // [perf] The top page starts with the probe; the matching probe cancelled it (it may have gone out).
        let topsAfterSkip = topReads(client)
        #expect(topsAfterSkip <= 1 && store.probeStats.top == 0)
        differs.value = true
        try await Task.sleep(for: .milliseconds(350))                     // past the gap
        client.emit("sessions.changed")
        // [perf-returns] §11.5: off screen the probe's miss reads the top page; the full read waits for the list.
        #expect(await BotsTest.waitUntil { topReads(client) == topsAfterSkip + 1 && store.probeStats.top == 1 })
        #expect(await BotsTest.waitUntil { store.fullReadOwed })
        #expect(fullReads(client) == 1 && store.fullReadOwed)
        // A reconnect also probes first.
        differs.value = false
        let before = probes(client)
        client.emit("gateway.ready", payload: ["change_events": true])
        #expect(await BotsTest.waitUntil { probes(client) == before + 1 })
        store.stop()
    }

    @Test func nothingWhileBackgroundedCatchUpOnReturn() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.sidebar([Self.srow("a")]) }
        let store = makeStore(client)
        store.setListVisible(true)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        store.appDidEnterBackground()
        client.emit("sessions.changed")
        try await Task.sleep(for: .milliseconds(400))
        #expect(fullReads(client) == 1 && probes(client) == 0)
        store.appDidBecomeActive()
        #expect(await BotsTest.waitUntil { fullReads(client) == 2 || probes(client) == 1 })
        store.stop()
    }

    /// [perf] While a chat is on screen the off-screen list reads at the longer gap; leaving the chat lets a held-back
    /// pass run at the normal one.
    @Test func aFocusedChatStretchesTheOffScreenGap() async throws {
        let stamp = BotsTestBox(1_791_000_000.0)
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.sidebar([Self.srow("a", lastActive: stamp.value)]) }
        var timing = SessionStoreTiming.fast
        timing.focusedChatGap = .seconds(30)
        let store = SessionStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        store.setChatFocused(true)
        client.emit("sessions.changed")
        #expect(await BotsTest.waitUntil { probes(client) == 1 })            // leading edge
        try await Task.sleep(for: .milliseconds(400))                       // past the normal off-screen gap
        for _ in 0..<3 { stamp.value += 10; client.emit("sessions.changed") }
        try await Task.sleep(for: .milliseconds(500))
        #expect(probes(client) == 1, "held back by the focused-chat gap")
        store.setChatFocused(false)
        #expect(await BotsTest.waitUntil(.seconds(1)) { probes(client) == 2 })
        store.stop()
    }

    /// [perf] An answer identical to the rows on hand notifies nobody.
    @Test func anIdenticalAnswerDoesNotNotify() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.sidebar([Self.srow("a")]) }
        let store = makeStore(client)
        store.setListVisible(true)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        try await Task.sleep(for: .milliseconds(50))
        var changes = 0
        store.onChange = { changes += 1 }
        client.emit("sessions.changed")
        #expect(await BotsTest.waitUntil { probes(client) == 1 })
        #expect(await BotsTest.waitUntil { !store.isRefreshing })
        #expect(changes == 0 && store.loadState == .ready)
        store.stop()
    }

    /// [perf] A pull always notifies, even when the answer matches the rows on hand: that notify ends the spinner.
    @Test func aPullWithAnIdenticalAnswerStillNotifies() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.sidebar([Self.srow("a")]) }
        let store = makeStore(client)
        store.setListVisible(true)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        try await Task.sleep(for: .milliseconds(50))
        var changes = 0
        store.onChange = { changes += 1 }
        await store.refresh()
        #expect(changes >= 1)
        // Only the pull is forced: a change-event read with the same answer after it stays quiet.
        let afterPull = changes
        client.emit("sessions.changed")
        #expect(await BotsTest.waitUntil { probes(client) == 1 })
        #expect(await BotsTest.waitUntil { !store.isRefreshing })
        #expect(changes == afterPull)
        store.stop()
    }

    /// [reliability] A reconnect after a trip to the background doesn't join a read from before it (that read was
    /// suspended with the app): it starts a fresh one, and the old one's late end changes nothing.
    @Test func aReconnectAfterBackgroundSupersedesAnOlderRead() async throws {
        let calls = BotsTestBox(0)
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in
            let n = calls.mutate { $0 += 1; return $0 }
            if n == 1 {
                await botsUncancellableSleep(.milliseconds(800))
                return Self.sidebar([Self.srow("old")])
            }
            return Self.sidebar([Self.srow("new")])
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { calls.value == 1 })
        store.appDidEnterBackground()
        store.appDidBecomeActive()
        client.emit("gateway.ready", payload: ["change_events": true])
        #expect(await BotsTest.waitUntil { calls.value == 2 })
        #expect(await BotsTest.waitUntil { store.sessions.map(\.id) == ["new"] && store.loadState == .ready })
        try await Task.sleep(for: .milliseconds(900))                         // the old read has ended
        #expect(store.sessions.map(\.id) == ["new"] && store.loadState == .ready)
        // The share was not given back by the old read: a socket reopening within 3 s still shares it.
        client.emit("gateway.ready", payload: ["change_events": true])
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls.value == 2)
        store.stop()
    }

    /// Without a trip to the background a reconnect joins the read in flight, as before.
    @Test func aReconnectWithoutBackgroundStillJoins() async throws {
        let calls = BotsTestBox(0)
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in
            let n = calls.mutate { $0 += 1; return $0 }
            if n == 1 { await botsUncancellableSleep(.milliseconds(400)) }
            return Self.sidebar([Self.srow("a")])
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { calls.value == 1 })
        client.emit("gateway.ready", payload: ["change_events": true])
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.value == 1)
        store.stop()
    }

    /// [phone-logs] A cold launch: its read starts before the app's first active. That active is no return, so the
    /// connect's reconnect joins the launch's read instead of cancelling it (every launch logged a failed read).
    @Test func aColdLaunchsFirstActiveDoesNotSupersedeTheLaunchRead() async throws {
        let calls = BotsTestBox(0)
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in
            let n = calls.mutate { $0 += 1; return $0 }
            if n == 1 { await botsUncancellableSleep(.milliseconds(400)) }
            return Self.sidebar([Self.srow("a")])
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { calls.value == 1 })
        store.appDidBecomeActive()
        client.emit("gateway.ready", payload: ["change_events": true])
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.value == 1)
        store.stop()
    }

    /// [reliability] A reconnect read that a network change started during the background grace was suspended with the
    /// app too: a reconnect after the return starts a fresh read instead of joining it.
    @Test func aReconnectReadFromTheGraceIsSupersededOnReturn() async throws {
        let calls = BotsTestBox(0)
        let slow = BotsTestBox(false)
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in
            calls.mutate { $0 += 1 }
            if slow.value { await botsUncancellableSleep(.milliseconds(800)) }
            return Self.sidebar([Self.srow("a")])
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready && !store.isRefreshing })
        store.appDidEnterBackground()
        slow.value = true
        store.refreshAfterReconnect()                                       // Wi-Fi to cellular in the grace
        #expect(await BotsTest.waitUntil { store.isRefreshing })
        try await Task.sleep(for: .milliseconds(50))
        let inGrace = calls.value
        slow.value = false
        store.appDidBecomeActive()
        store.refreshAfterReconnect()
        #expect(await BotsTest.waitUntil(.milliseconds(400)) { calls.value > inGrace }, "a fresh read, not the frozen one")
        store.stop()
    }

    // MARK: Review round 2

    /// The open-time clear rewrites the row: a list page read before the gateway acknowledged the write cannot bring
    /// the dot back, and no later rebuild does either (no timer).
    @Test func openClearIsFencedNotTimed() async throws {
        let serverUnread = BotsTestBox(true)
        let slowGET = BotsTestBox(false)
        let client = BotsFakeGatewayClient()
        client.onREST { method, path, _, _ in
            // A gateway before the revision fence: the write goes without a snapshot read.
            if path.hasSuffix("/mutation-snapshot") { throw HTTPError(status: 404, body: nil) }
            if method == "PATCH" {
                try await Task.sleep(for: .milliseconds(50))
                serverUnread.value = false
                return try! (["ok": true, "unread": false] as JSONValue).encoded()
            }
            // A page computed before the write lands, delivered after it.
            let unread = serverUnread.value
            if slowGET.value { await botsUncancellableSleep(.milliseconds(300)) }
            return Self.sidebar([Self.srow("srv", count: 5, unread: unread), Self.srow("other")])
        }
        var timing = SessionStoreTiming.fast
        timing.onScreenGap = .zero
        let store = SessionStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(),
                                 timing: timing)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.sessions.first { $0.id == "srv" }?.unread == true)

        slowGET.value = true
        let stale = Task { await store.refresh() }                     // its read starts before the write
        try await Task.sleep(for: .milliseconds(50))
        store.markOpened(store.sessions.first { $0.id == "srv" }!)
        #expect(store.sessions.first { $0.id == "srv" }?.unread == false)
        await stale.value
        #expect(store.sessions.first { $0.id == "srv" }?.unread == false)    // fenced, not overwritten
        slowGET.value = false

        // Long after any guard window, an unrelated rebuild keeps it clear.
        store.setFocusedSession("other")
        store.setRunning(["other"])
        store.setRunning([])
        #expect(store.sessions.first { $0.id == "srv" }?.unread == false)
        #expect(store.unreadCount == 0)
        // An honest page read after the acknowledgement settles it.
        await store.refresh()
        #expect(store.sessions.first { $0.id == "srv" }?.unread == false)
        #expect(client.restCalls.filter { $0.method == "PATCH" }.count == 1)
        store.stop()
    }

    /// The chat the user just used does not come back unread once they leave it (sticky selection, web parity).
    @Test func leavingAChatLeavesNoDot() async throws {
        let counts = BotsTestBox(["a": 2, "b": 2])
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in
            Self.sidebar(counts.value.sorted { $0.key < $1.key }.map { Self.srow($0.key, count: $0.value) })
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        store.markOpened(store.sessions.first { $0.id == "a" }!)
        store.setFocusedSession("a")
        counts.mutate { $0["a"] = 6 }                                    // the user's exchange, no read meanwhile
        store.setFocusedSession(nil)                                     // back to the list
        await store.refresh()
        #expect(store.sessions.first { $0.id == "a" }?.unread == false)
        #expect(store.unreadCount == 0)
        // Another chat focused: new messages in "a" show again.
        store.setFocusedSession("b")
        counts.mutate { $0["a"] = 8 }
        await store.refresh()
        #expect(store.sessions.first { $0.id == "a" }?.unread == true)
        #expect(store.sessions.first { $0.id == "b" }?.unread == false)
        store.stop()
    }

    /// Spec 02 §9.1: an older gateway 404s the batched route; three per-slice reads stand in, and later reads go
    /// straight to them.
    @Test func olderGatewayGetsThePerSliceReads() async throws {
        let client = BotsFakeGatewayClient()
        let sidebarPath = SessionStore.sidebarPath, messagingExclude = SessionStore.messagingExclude
        client.onREST { _, path, query, _ in
            if path == sidebarPath { throw HTTPError(status: 404, body: "No such API endpoint") }
            let value = { (name: String) in query.first { $0.name == name }?.value }
            if value("source") == "cron" { return try! (["sessions": [Self.srow("cron_1", source: "cron")], "total": 1] as JSONValue).encoded() }
            if value("exclude_sources") == messagingExclude {
                return try! (["sessions": [Self.srow("tg", source: "telegram")]] as JSONValue).encoded()
            }
            return try! (["sessions": [Self.srow("chat", lastActive: 200), Self.srow("older", lastActive: 100)]] as JSONValue).encoded()
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.sessions.map(\.id) == ["chat", "older"])
        #expect(store.cronSessions.map(\.id) == ["cron_1"])
        #expect(store.messagingSessions.map(\.id) == ["tg"])
        let legacy = client.restCalls.filter { $0.path == SessionStore.legacyPath }
        #expect(legacy.count == 3)
        let recents = try #require(legacy.first { $0.query.contains(URLQueryItem(name: "exclude_sources", value: SessionStore.recentsExclude)) })
        for item in [("limit", "50"), ("offset", "0"), ("min_messages", "1"), ("archived", "exclude"), ("order", "recent"), ("profile", "all")] {
            #expect(recents.query.contains(URLQueryItem(name: item.0, value: item.1)))
        }
        await store.refresh()
        #expect(client.restCalls.filter { $0.path == SessionStore.sidebarPath }.count == 1)
        #expect(client.restCalls.filter { $0.path == SessionStore.legacyPath }.count == 6)
        store.stop()
    }

    /// Pull to refresh after a probe-first read in flight still reads in full.
    @Test func pullToRefreshAfterAProbeReadsInFull() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, query, _ in
            if query.contains(URLQueryItem(name: "recents_limit", value: "1")) { try await Task.sleep(for: .milliseconds(150)) }
            return Self.sidebar([Self.srow("a")])
        }
        let store = makeStore(client)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        client.emit("sessions.changed")                                   // off screen: probe first
        #expect(await BotsTest.waitUntil { probes(client) == 1 })
        await store.refresh()
        #expect(fullReads(client) == 2)
        store.stop()
    }

    /// A read whose answer arrives after stop() changes nothing, on screen or on disk.
    @Test func answerAfterStopIsDropped() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in
            await botsUncancellableSleep(.milliseconds(200))
            return Self.sidebar([Self.srow("a")])
        }
        let dir = BotsTest.tempDirectory()
        let store = makeStore(client, dir: dir)
        try await Task.sleep(for: .milliseconds(50))
        store.stop()
        store.removeCachedData()
        try await Task.sleep(for: .milliseconds(300))
        RosterDiskWriter.shared.flush()
        #expect(store.sessions.isEmpty)
        #expect(store.loadState != .ready)
        if case .failed = store.loadState { Issue.record("a cancelled read must not read as failed") }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)
    }

    /// The Background Runs toggle is observable and persisted per account.
    @Test func showBackgroundRunsIsObservableAndPersisted() async throws {
        let dir = BotsTest.tempDirectory()
        let store = makeStore(BotsFakeGatewayClient(), dir: dir, autoStart: false)
        let fired = BotsTestBox(false)
        withObservationTracking { _ = store.showBackgroundRuns } onChange: { fired.value = true }
        store.showBackgroundRuns = true
        #expect(fired.value)
        RosterDiskWriter.shared.flush()
        #expect(makeStore(BotsFakeGatewayClient(), dir: dir, autoStart: false).showBackgroundRuns)
    }

    // MARK: Date groups

    @Test func dateGroupsLabelEveryRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1                                         // Sunday, as en_US
        let locale = Locale(identifier: "en_US")
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Double {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!.timeIntervalSince1970
        }
        let now = Date(timeIntervalSince1970: at(2026, 10, 29, 12))         // Thursday
        func label(_ seconds: Double) -> String { SessionDateGroups.bucket(seconds: seconds, now: now, calendar: calendar, locale: locale).label }
        #expect(label(at(2026, 10, 29, 9)) == "Earlier today")
        #expect(label(at(2026, 10, 29, 2)) == "Yesterday")                  // before 4 AM: the evening before
        #expect(label(at(2026, 10, 28, 12)) == "Yesterday")
        #expect(label(at(2026, 10, 26)) == "Earlier this week")
        #expect(label(at(2026, 10, 20)) == "Last week")
        #expect(label(at(2026, 10, 5)) == "Earlier this month")
        #expect(label(at(2026, 9, 10)) == "September")
        #expect(label(at(2025, 8, 1)) == "August 2025")
        let groups = SessionDateGroups.group([at(2026, 10, 29, 9), at(2026, 10, 29, 8), at(2026, 10, 26), at(2026, 9, 10)],
                                             seconds: { $0 }, now: now, calendar: calendar, locale: locale)
        #expect(groups.map(\.bucket.label) == ["Earlier today", "Earlier this week", "September"])
        #expect(groups.map(\.items.count) == [2, 1, 1])
    }
}
