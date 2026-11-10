// Capabilities speed and reliability fixes: tab reads gated like the other tabs, reads that run side by side, the
// sweep's resume rule, the managed-apps join and its reconnect reads, catalog logos, and Connect Apps' opening read.

import Foundation
import Observation
import Synchronization
import Testing
import UIKit
@testable import HermesHQNative

/// Just enough of the app for a Capabilities page: a store over a scripted gateway.
@MainActor final class CapabilitiesFakeServices: AppServices, SettingsServices {
    var account: GatewayAccount? = .botsTestAccount
    var bots: [Bot] = []
    var sessions: [SessionSummary] = []
    var connection: ConnectionState = .ready
    var onBotsChange: (() -> Void)?
    var onSessionsChange: (() -> Void)?
    var onConnectionChange: (() -> Void)?
    func refreshBots() {}
    func refreshSessions() {}
    func chat(for bot: Bot) -> ChatSessionModel { UnavailableChat(title: bot.name, profile: bot.id, head: nil) }
    func chat(for session: SessionSummary) -> ChatSessionModel { UnavailableChat(title: session.title, profile: session.profile, head: nil) }
    func markRead(_ bot: Bot) {}
    func signOut() {}

    let capabilities: (any CapabilitiesService)?
    init(_ store: CapabilitiesStore) { capabilities = store }
    var botEditing: (any BotEditing)? { nil }
    var gateways: any GatewayAccounts { fatalError("not used") }
    var botLayout: RosterLayout? { nil }
    var gatewayVersion: String? { nil }
    func refreshGatewayVersion(force: Bool) {}
    var rosterCount: Int { 0 }
    func adoptSignedInAccount(_ account: GatewayAccount) {}
    func makeSignInDriver() -> SignInServiceDriver { fatalError("not used") }
    func startIntro(in chat: any ChatSessionModel, result: NewBotResult) {}
    func markUnread(_ bot: Bot) {}
}

/// A flag a scripted handler can wait on.
nonisolated final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    func open() { lock.withLock { isOpen = true } }
    var opened: Bool { lock.withLock { isOpen } }
    /// Waits up to `limit` for the gate; true when it opened.
    func wait(_ limit: Duration = .seconds(3)) async -> Bool {
        let end = ContinuousClock.now + limit
        while !opened, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        return opened
    }
}

@MainActor func eventually(_ limit: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let end = ContinuousClock.now + limit
    while !condition(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
    return condition()
}

@Suite(.serialized) @MainActor struct CapabilitiesSpeedTests {
    nonisolated static let skillsJSON = #"[{"name":"notes","description":"Take notes","enabled":true}]"#
    nonisolated static let officialJSON = #"{"skills":[{"name":"maps","identifier":"official/maps","description":"Maps","installed":false}]}"#

    /// A gateway with one connector, a catalog, skills and the official hub; managed apps are unavailable.
    /// The hub answers each bot with its own catalog ("maps" for ivy, "kim-maps" for kim).
    func script(_ client: BotsFakeGatewayClient = BotsFakeGatewayClient(), official: Gate? = nil) -> BotsFakeGatewayClient {
        client.on("mcp.servers.list") { _ in ["servers": [["name": "files", "transport": "http"]]] }
        client.on("mcp.servers.status") { _ in ["servers": [["name": "files", "status": "connected", "tools": 3]]] }
        client.onREST { _, path, query, _ in
            switch path {
            case "/api/skills": return Data(Self.skillsJSON.utf8)
            case "/api/skills/hub/official":
                if let official { _ = await official.wait() }
                let profile = query.first { $0.name == "profile" }?.value ?? ""
                return Data(Self.officialJSON.replacingOccurrences(of: "\"maps\"", with: profile == "ivy" ? "\"maps\"" : "\"\(profile)-maps\"").utf8)
            case "/api/mcp/catalog": return Data(#"{"entries":[{"name":"github","title":"GitHub"}]}"#.utf8)
            default: throw HTTPError(status: 404, body: "Not Found")
            }
        }
        return client
    }

    func model(_ client: BotsFakeGatewayClient, tab: CapabilitiesTab) -> CapabilitiesModel {
        CapabilitiesModel(services: CapabilitiesFakeServices(CapabilitiesStore(client: client)), profile: "ivy", tab: tab)
    }

    func catalogReads(_ client: BotsFakeGatewayClient) -> Int { client.restCalls.filter { $0.path == "/api/mcp/catalog" }.count }

    // MARK: #17 Connectors gated like the other tabs

    @Test func connectorsAreNotReadAgainWithin30Seconds() async {
        let client = script()
        let model = model(client, tab: .connectors)
        model.load()
        #expect(await eventually { model.servers != nil && model.catalog != nil && model.fresh("servers") && model.fresh("catalog") })
        model.load()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(client.calls("mcp.servers.list").count == 1)
        #expect(catalogReads(client) == 1)
        #expect(model.servers?.first?.status == "connected")
    }

    @Test func aServerTheEarlyStatusMissedIsReadAgain() async {
        // Recovery re-adds a connector after the status read went out: the status is asked once more.
        let client = script()
        client.on("mcp.servers.list") { _ in ["servers": [["name": "files", "transport": "http"], ["name": "github", "transport": "http"]]] }
        let reads = Mutex(0)
        client.on("mcp.servers.status") { _ in
            let first = reads.withLock { n in defer { n += 1 }; return n == 0 }
            return first ? ["servers": [["name": "files", "status": "connected", "tools": 3]]]
                : ["servers": [["name": "files", "status": "connected", "tools": 3], ["name": "github", "status": "connected", "tools": 5]]]
        }
        let model = model(client, tab: .connectors)
        await model.reloadServers()
        #expect(client.calls("mcp.servers.status").count == 2)
        #expect(model.servers?.first { $0.name == "github" }?.status == "connected")
    }

    @Test func aStatusThatCoversTheListIsReadOnce() async {
        let client = script()
        let model = model(client, tab: .connectors)
        await model.reloadServers()
        #expect(client.calls("mcp.servers.status").count == 1)
    }

    @Test func aFailedServersReadIsNotStamped() async {
        let client = script()
        client.on("mcp.servers.list") { _ in throw RPCError(code: 5000, message: "boom", data: nil) }
        let model = model(client, tab: .connectors)
        await model.reloadServers()
        #expect(!model.fresh("servers"))
        let before = client.calls("mcp.servers.list").count
        model.load()
        #expect(await eventually { client.calls("mcp.servers.list").count > before })
    }

    @Test func anUnchangedStatusPollLeavesTheListAlone() async {
        let client = script()
        let model = model(client, tab: .connectors)
        await model.reloadServers()
        #expect(model.servers != nil)
        let changed = Gate()
        withObservationTracking { _ = model.servers } onChange: { changed.open() }
        await model.refreshStatus()
        #expect(!changed.opened)
        // A status that did change still lands.
        client.on("mcp.servers.status") { _ in ["servers": [["name": "files", "status": "failed", "tools": 0]]] }
        await model.refreshStatus()
        #expect(changed.opened && model.servers?.first?.status == "failed")
    }

    @Test func aFailureThatLastsStillBecomesAnIssueOnEqualPolls() async {
        // The poll must keep reporting while nothing changes: the issue needs two failed reads 10 s apart.
        let client = script()
        client.on("mcp.servers.status") { _ in ["servers": [["name": "files", "status": "failed", "tools": 0]]] }
        let issues = ServerIssues.shared
        let clock = issues.now
        defer { issues.now = clock; issues.forget(profile: "ivy") }
        let start = Date()
        issues.now = { start }
        let model = model(client, tab: .connectors)
        await model.reloadServers()
        #expect(!issues.issues.contains { $0.profile == "ivy" })
        issues.now = { start.addingTimeInterval(ServerIssues.debounce + 1) }
        await model.refreshStatus()
        #expect(issues.issues.contains { $0.profile == "ivy" && $0.name == "files" && $0.kind == .error })
    }

    @Test func refreshReadsTheConnectorsTabTogether() async {
        let client = BotsFakeGatewayClient()
        let both = Gate()
        _ = script(client)
        // The list waits until the catalog has been asked for: in series this would time out.
        client.on("mcp.servers.list") { _ in
            _ = await both.wait(.seconds(2))
            return ["servers": [["name": "files", "transport": "http"]]]
        }
        client.onREST { _, path, _, _ in
            if path == "/api/mcp/catalog" { both.open(); return Data(#"{"entries":[]}"#.utf8) }
            throw HTTPError(status: 404, body: "Not Found")
        }
        let model = model(client, tab: .connectors)
        let start = ContinuousClock.now
        await model.refresh()
        #expect(both.opened)
        #expect(ContinuousClock.now - start < .seconds(1.5))
    }

    // MARK: #53 / #66 Skills and status read side by side

    @Test func installedSkillsShowBeforeTheCatalogLands() async {
        let official = Gate()
        let client = script(official: official)
        let model = model(client, tab: .skills)
        let run = Task { await model.reloadSkills() }
        #expect(await eventually { model.skills != nil })
        #expect(model.skills?.map(\.name) == ["notes"] && model.skillsError == nil && model.official == nil)
        #expect(client.restCalls.contains { $0.path == "/api/skills/hub/official" }, "the catalog was asked for alongside")
        official.open()
        await run.value
        #expect(model.official?.map(\.name) == ["maps"])
        #expect(model.available.map(\.name) == ["maps"])
    }

    @Test func aBotSwitchDropsTheOldBotsCatalog() async {
        let official = Gate()
        let client = script(official: official)
        let model = model(client, tab: .skills)
        let run = Task { await model.reloadSkills() }
        #expect(await eventually { model.skills != nil })
        model.profile = "kim"
        official.open()
        await run.value
        try? await Task.sleep(for: .milliseconds(200))   // kim's own read, started by the switch, lands too
        #expect(model.profile == "kim")
        #expect(model.official?.map(\.name) != ["maps"], "ivy's catalog is never assigned to kim")
    }

    @Test func aFailingCatalogKeepsTheInstalledList() async {
        let client = script()
        client.onREST { _, path, _, _ in
            if path == "/api/skills" { return Data(Self.skillsJSON.utf8) }
            throw HTTPError(status: 500, body: nil)
        }
        let model = model(client, tab: .skills)
        await model.reloadSkills()
        #expect(model.skills?.map(\.name) == ["notes"] && model.skillsError == nil && model.official == nil)
    }

    @Test func statusIsAskedForBeforeTheListAnswers() async {
        let client = script()
        let asked = Gate()
        client.on("mcp.servers.status") { _ in
            asked.open()
            return ["servers": [["name": "files", "status": "connected", "tools": 3]]]
        }
        client.on("mcp.servers.list") { _ in
            #expect(await asked.wait(.seconds(2)), "status runs alongside the list")
            return ["servers": [["name": "files", "transport": "http"]]]
        }
        let model = model(client, tab: .connectors)
        await model.reloadServers()
        #expect(model.servers?.first?.status == "connected" && model.servers?.first?.tools == 3)
    }

    @Test func offMainDecodersMatchTheOldParser() async throws {
        let skills = #"[{"name":" notes ","description":"N","category":"Writing","enabled":false,"usage":{"count":4}},{"name":""},{"name":"maps"}]"#
        let decoded = try await CapabilitiesStore.decodeSkills(Data(skills.utf8))
        let old = (try JSONValue.parse(Data(skills.utf8)).array ?? []).compactMap(CapabilitiesStore.skill)
        #expect(decoded == old)
        #expect(decoded.map(\.enabled) == [false, true])
        let official = #"{"skills":[{"name":"maps","identifier":"o/maps","installed":true},{"name":"x"},{"name":"web","identifier":"o/web","installed":1}]}"#
        let catalog = try await CapabilitiesStore.decodeOfficial(Data(official.utf8))
        #expect(catalog.map(\.identifier) == ["o/maps", "o/web"])
        #expect(catalog.map(\.installed) == [true, false], "a number is not a bool, as before")
        #expect(await CapabilitiesStore.decodeCatalog(Data("<html>".utf8)) == nil)
        #expect(await CapabilitiesStore.decodeCatalog(Data(#"{"entries":[{"name":"github"}]}"#.utf8))?.map(\.name) == ["github"])
    }

    // MARK: #21 The sweep's resume rule

    @Test func aResumeSweepsOnlyWhenTheLastSweepIsOld() {
        let now = Date()
        let fresh = now.addingTimeInterval(-60), old = now.addingTimeInterval(-600)
        func due(wasConnected: Bool = false, roster: Bool = false, last: Date?, second: Bool = false, resumed: Bool) -> Bool {
            ServerIssueSweep.isDue(wasConnected: wasConnected, rosterChanged: roster, lastSweep: last, secondPass: second, resumed: resumed, now: now)
        }
        #expect(!due(last: fresh, resumed: true))
        #expect(due(last: old, resumed: true))
        #expect(due(last: fresh, resumed: false), "a drop while in the foreground sweeps")
        #expect(due(roster: true, last: fresh, resumed: true))
        #expect(due(wasConnected: true, last: now.addingTimeInterval(-(ServerIssues.debounce + 3)), second: true, resumed: true))
        #expect(due(wasConnected: true, last: nil, resumed: true))
        #expect(!due(wasConnected: true, last: fresh, resumed: false))
    }

    // MARK: #54 The managed join

    func row(_ slug: String, name: String? = nil) -> ConnectorCatalogRow {
        ConnectorCatalogRow(slug: slug, name: name ?? slug, description: "", category: "", logoURL: nil)
    }
    func listed(_ slug: String, status: String) -> ConnectorListRow {
        ConnectorListRow(connector: slug, enabled: true, connected: true, connectionStatus: status, statusReason: nil, gatewayDisabledTools: [])
    }
    func account(_ slug: String, _ label: String, active: Bool, at: String) -> ConnectorAccountRow {
        ConnectorAccountRow(connectionId: label, connector: slug, status: "active", statusReason: nil, label: label, alias: nil,
                            active: active, createdAt: at, updatedAt: at)
    }
    let policy = ConnectorPolicyView(member: nil, others: [])

    @Test func theJoinKeepsItsFirstMatchRules() {
        let apps = ManagedJoin.apps(catalog: [row("gmail"), row("slack")],
                                    list: [listed("slack", status: "expired"), listed("slack", status: "active"), listed("zoom", status: "active"),
                                           listed("box", status: "active"), listed("zoom", status: "failed")],
                                    accounts: [account("gmail", "newer-off", active: false, at: "2026-10-02"),
                                               account("gmail", "older-on", active: true, at: "2026-10-01"),
                                               account("slack", "a", active: true, at: "2026-10-01"),
                                               account("slack", "b", active: true, at: "2026-10-03"),
                                               account("nowhere", "x", active: true, at: "2026-10-03")],
                                    policy: policy, rulesReadable: true)
        #expect(apps.map(\.slug) == ["gmail", "slack", "zoom", "box"], "catalog first, then list-only apps in list order")
        let by = Dictionary(uniqueKeysWithValues: apps.map { ($0.slug, $0) })
        #expect(by["gmail"]?.accountLabel == "older-on", "an active account wins over a newer inactive one")
        #expect(by["slack"]?.accountLabel == "b", "the newest of two active accounts")
        #expect(by["slack"]?.connected == true)
        #expect(by["zoom"]?.connectionStatus == "active", "the first list row of a connector wins")
        #expect(by["box"]?.inCatalog == false)
    }

    @Test func aLargeCatalogKeepsOrderAndCount() {
        let catalog = (0..<2000).map { row("app\($0)") }
        let list = (1990..<2010).map { listed("app\($0)", status: "active") }
        let apps = ManagedJoin.apps(catalog: catalog, list: list, accounts: [], policy: policy, rulesReadable: true)
        #expect(apps.count == 2010)
        #expect(apps.map(\.slug) == (0..<2010).map { "app\($0)" })
    }

    // MARK: #54 / #55 The managed model

    func managedScript() -> BotsFakeGatewayClient {
        let client = BotsFakeGatewayClient()
        client.on("connectors.list") { _ in ["available": true, "connectors": [["connector": "gmail", "connected": true, "connection_status": "active"]]] }
        client.on("connectors.catalog") { _ in ["connectors": [["slug": "gmail", "name": "Gmail"], ["slug": "slack", "name": "Slack"]]] }
        client.on("connectors.accounts") { _ in ["accounts": []] }
        client.on("connectors.policy.get") { _ in ["layers": []] }
        return client
    }

    @Test func storedAppsFollowEveryInput() async {
        let client = managedScript()
        let managed = ManagedAppsModel(client: client, profile: "ivy")
        #expect(managed.apps.isEmpty)
        await managed.reload()
        #expect(managed.phase == .ready)
        #expect(managed.apps.map(\.slug) == ["gmail", "slack"])
        #expect(managed.app("slack")?.name == "Slack" && managed.app("nope") == nil)
        for app in managed.apps { #expect(managed.app(app.slug) == managed.apps.first { $0.slug == app.slug }) }
        managed.accounts = [ConnectorAccountRow(connectionId: "c", connector: "slack", status: "pending", statusReason: nil, label: "", alias: nil,
                                                active: false, createdAt: "", updatedAt: "")]
        #expect(managed.app("slack")?.state == .connecting)
        managed.abandoned = ["slack"]
        #expect(managed.app("slack")?.state == .available)
        managed.phase = .signedOut
        #expect(managed.apps.isEmpty && managed.app("gmail") == nil)
    }

    @Test func aReconnectOffScreenWaitsForTheNextAppearance() async {
        let client = managedScript()
        let managed = ManagedAppsModel(client: client, profile: "ivy")
        await managed.reload()
        managed.connectorsShowing = true   // no presenter in a window: off screen
        let before = client.calls("connectors.list").count
        client.emit("gateway.ready")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(client.calls("connectors.list").count == before)
        managed.load()   // the next appearance reads, though the last read is under 30 s old
        #expect(await eventually { client.calls("connectors.list").count == before + 1 })
    }

    @Test func aReconnectOnScreenReadsAgain() async {
        let client = managedScript()
        let managed = ManagedAppsModel(client: client, profile: "ivy")
        await managed.reload()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let page = UIViewController()
        window.rootViewController = page
        window.isHidden = false
        page.loadViewIfNeeded()
        managed.presenter = page
        managed.connectorsShowing = true
        let before = client.calls("connectors.list").count
        client.emit("gateway.ready")
        #expect(await eventually { client.calls("connectors.list").count == before + 1 })
        // Another tab showing: no read.
        managed.connectorsShowing = false
        try? await Task.sleep(for: .milliseconds(100))
        let after = client.calls("connectors.list").count
        client.emit("gateway.ready")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(client.calls("connectors.list").count == after)
        window.isHidden = true
    }

    @Test func aReconnectWhileLoadingReadsNothing() async {
        let client = managedScript()
        let managed = ManagedAppsModel(client: client, profile: "ivy")
        #expect(managed.phase == .loading)
        managed.connectorsShowing = true
        client.emit("gateway.ready")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(client.calls("connectors.list").isEmpty)
    }
}

// MARK: - #58 Catalog logos

/// Answers logo requests from a script; `nil` is a transport failure. Process-wide, so its suite is serialized.
nonisolated final class LogoStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var seen: [URL] = []
    nonisolated(unsafe) static var answer: @Sendable (URL) -> (Int, String, Data)? = { _ in nil }
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let reply = Self.lock.withLock { Self.seen.append(url); return Self.answer(url) }
        guard let (status, type, data) = reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func reset(_ answer: @escaping @Sendable (URL) -> (Int, String, Data)?) { lock.withLock { seen = []; self.answer = answer } }
    static func count(_ path: String) -> Int { lock.withLock { seen.filter { $0.path == path }.count } }
}

@Suite(.serialized) @MainActor struct CatalogLogoStoreTests {
    nonisolated static let grey = Data("grey".utf8)
    nonisolated static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
        UIColor.systemRed.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    }

    func store() -> CatalogLogoStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LogoStub.self]
        return CatalogLogoStore(session: URLSession(configuration: config))
    }

    @Test func withoutAPlaceholderAGreyAnswerIsNotTakenForTheLogo() async {
        LogoStub.reset { url in
            if url.path.hasSuffix("hq-no-such-app-0") { return nil }   // the placeholder can't be read
            return (200, "image/png", Self.png)                           // would be the grey placeholder for an unknown slug
        }
        let store = store()
        #expect(await store.image(key: "a", slugs: ["unknown"], site: nil) == nil)
        #expect(LogoStub.count("/api/unknown") == 0, "no composio answer is used when it can't be compared")
    }

    @Test func manyRowsShareOnePlaceholderRead() async {
        LogoStub.reset { url in url.path.hasSuffix("hq-no-such-app-0") ? (200, "image/svg+xml", Self.grey) : (200, "image/png", Self.png) }
        let store = store()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 { group.addTask { _ = await store.image(key: "k\(i)", slugs: ["app\(i)"], site: nil) } }
        }
        #expect(LogoStub.count("/api/hq-no-such-app-0") == 1)
    }

    @Test func aTransportFailureIsTriedAgain() async {
        let online = Gate()
        LogoStub.reset { url in
            if url.path.hasSuffix("hq-no-such-app-0") { return (200, "image/svg+xml", Self.grey) }
            return online.opened ? (200, "image/png", Self.png) : nil
        }
        let store = store()
        store.retryGap = 0
        #expect(await store.image(key: "gmail", slugs: ["gmail"], site: nil) == nil)
        online.open()
        #expect(await store.image(key: "gmail", slugs: ["gmail"], site: nil) != nil)
    }

    @Test func anOfflineRowIsNotAskedAgainOnEveryReappearance() async {
        LogoStub.reset { _ in nil }   // offline: every request fails
        let store = store()
        let site = URL(string: "https://example.com")!
        #expect(await store.image(key: "gmail", slugs: ["gmail"], site: site) == nil)
        let asked = LogoStub.count("/apple-touch-icon.png") + LogoStub.count("/favicon.ico") + LogoStub.count("/api/gmail")
        #expect(asked > 0)
        #expect(await store.image(key: "gmail", slugs: ["gmail"], site: site) == nil)
        #expect(LogoStub.count("/apple-touch-icon.png") + LogoStub.count("/favicon.ico") + LogoStub.count("/api/gmail") == asked,
                "the row waits before asking again")
    }

    @Test func aPlaceholderMatchIsRemembered() async {
        LogoStub.reset { _ in (200, "image/svg+xml", Self.grey) }
        let store = store()
        #expect(await store.image(key: "x", slugs: ["unknown"], site: nil) == nil)
        let asked = LogoStub.count("/api/unknown")
        #expect(await store.image(key: "x", slugs: ["unknown"], site: nil) == nil)
        #expect(LogoStub.count("/api/unknown") == asked, "a definite miss is not asked again")
    }
}

// MARK: - #60 Connect Apps opening

extension ComposioTests {
    func composioModel(record: JSONValue?, ready: Gate? = nil) -> (ComposioModel, ComposioKeychain, BotsFakeGatewayClient) {
        let gateway = BotsFakeGatewayClient()
        gateway.on("profiles.list") { _ in
            if let ready { _ = await ready.wait(.seconds(2)) }
            return ["profiles": [["name": "default", "ui_meta": record.map { [ComposioRecord.key: $0] } ?? [:]]]]
        }
        let services = CapabilitiesFakeServices(CapabilitiesStore(client: gateway))
        let keys = keychain()
        try? keys.save("ak_mock_dispatch")
        let model = ComposioModel(services: services, keys: keys, client: client(keys))
        UserDefaults.standard.set(["userId": "dispatch-aabbcc", "sessionId": "trs_1"], forKey: "connectapps.session.\(GatewayAccount.botsTestAccount.id)")
        return (model, keys, gateway)
    }

    @Test func aKeptSessionIsReadWhileTheRecordIs() async {
        let readSeen = Gate()
        ComposioStub.reset { request in
            if request.url?.path.hasSuffix("/tool_router/session/trs_1") == true { readSeen.open() }
            let path = request.url?.path ?? ""
            if path.hasSuffix("/tool_router/session/trs_1") { return (200, Self.session) }
            return (200, #"{"items":[]}"#)
        }
        let (model, keys, _) = composioModel(record: ["userId": "dispatch-aabbcc", "sessionId": "trs_1"], ready: readSeen)
        defer { keys.clear(); UserDefaults.standard.removeObject(forKey: "connectapps.session.\(GatewayAccount.botsTestAccount.id)") }
        await model.start()
        #expect(readSeen.opened, "the session read did not wait for the record")
        #expect(model.phase == .ready && model.session?.id == "trs_1")
        #expect(ComposioStub.seen.filter { $0.url?.path.hasSuffix("/tool_router/session/trs_1") == true }.count == 1)
    }

    @Test func aRecordNamingAnotherSessionWins() async {
        ComposioStub.reset { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/tool_router/session/trs_1") { return (200, Self.session) }
            if path.hasSuffix("/tool_router/session/trs_2") { return (200, Self.session.replacingOccurrences(of: "trs_1", with: "trs_2")) }
            return (200, #"{"items":[]}"#)
        }
        let (model, keys, _) = composioModel(record: ["userId": "dispatch-aabbcc", "sessionId": "trs_2"])
        defer { keys.clear(); UserDefaults.standard.removeObject(forKey: "connectapps.session.\(GatewayAccount.botsTestAccount.id)") }
        await model.start()
        #expect(model.phase == .ready && model.session?.id == "trs_2")
    }

    @Test func aKeptSessionComposioForgotMakesANewOne() async {
        ComposioStub.reset { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/tool_router/session/trs_1") { return (404, #"{"error":{"message":"not found"}}"#) }
            if request.httpMethod == "POST", path.hasSuffix("/tool_router/session") { return (201, Self.session.replacingOccurrences(of: "trs_1", with: "trs_3")) }
            return (200, #"{"items":[]}"#)
        }
        let (model, keys, _) = composioModel(record: ["userId": "dispatch-aabbcc", "sessionId": "trs_1"])
        defer { keys.clear(); UserDefaults.standard.removeObject(forKey: "connectapps.session.\(GatewayAccount.botsTestAccount.id)") }
        await model.start()
        #expect(model.phase == .ready && model.session?.id == "trs_3")
        #expect(ComposioStub.seen.contains { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/tool_router/session") == true })
    }
}
