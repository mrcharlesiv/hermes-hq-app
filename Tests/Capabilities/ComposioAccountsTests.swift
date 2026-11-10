// Connect Apps: a second account of an app (docs/spec/3x-capabilities.md §10.11). The request bodies and routes, the
// account list and names, the multi-account decision, and the move of an older session's bots to a multi-account one
// (including a move that stopped half way and is run again).

import Foundation
import Testing
@testable import HermesHQNative

extension ComposioTests {
    nonisolated static func session(_ id: String, multi: Bool?) -> String {
        let flag = multi.map { #","multi_account":{"enable":\#($0)}"# } ?? ""
        return #"{"session_id":"\#(id)","mcp":{"type":"http","url":"https://backend.composio.dev/tool_router/v3/\#(id)/mcp"},"config":{"user_id":"dispatch-aabbcc"\#(flag)}}"#
    }

    @Test func newSessionsAreMultiAccountAndNamedLinksUseTheAliasRoute() async throws {
        let keys = keychain()
        defer { keys.clear() }
        try keys.save("ak_mock_dispatch")
        ComposioStub.reset { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/link") { return (201, #"{"redirect_url":"https://connect.composio.dev/link/lk_1","connected_account_id":"ca_2"}"#) }
            if path == "/api/v3.1/connected_accounts" {
                return (200, #"{"items":[{"id":"ca_3","status":"ACTIVE","created_at":"2026-10-20T10:00:00Z","alias":"work","word_id":"googledrive_ab12"},{"id":"ca_1","status":"ACTIVE","created_at":"2026-09-29T20:00:00Z","alias":null,"word_id":null},{"id":"ca_9","status":"INITIATED","created_at":"2026-10-21T10:00:00Z"},{"id":"ca_4","status":"EXPIRED","created_at":"2026-10-22T10:00:00Z","word_id":"googledrive_cd34"}],"next_cursor":null}"#)
            }
            if request.httpMethod == "PATCH" { return (200, #"{"id":"ca_1","status":"ACTIVE","alias":"home"}"#) }
            return (201, Self.session("trs_1", multi: true))
        }
        let client = client(keys)
        let made = try await client.createSession(userID: "dispatch-aabbcc")
        #expect(made.multiAccount == true)
        _ = try await client.link(session: "trs_1", toolkit: "googledrive", callback: "hermes://composio/callback")
        _ = try await client.link(session: "trs_1", toolkit: "googledrive", alias: "work", callback: "hermes://composio/callback")
        let accounts = try await client.accounts(user: "dispatch-aabbcc", toolkit: "googledrive")
        try await client.rename("ca_1", alias: "home")

        let seen = ComposioStub.seen, bodies = ComposioStub.bodies
        #expect(seen.count == 5)
        // 1. Create: the same user, manage_connections, and multi-account with the bots naming the account.
        #expect(bodies[0]["user_id"] == "dispatch-aabbcc" && bodies[0]["manage_connections"]?["enable"] == true)
        #expect(bodies[0]["multi_account"] == ["enable": true, "max_accounts_per_toolkit": 5, "require_explicit_selection": false])
        // 2. A first account: the route and body as before (v3, no alias).
        #expect(seen[1].url?.path == "/api/v3/tool_router/session/trs_1/link")
        #expect(bodies[1] == ["toolkit": "googledrive", "callback_url": "hermes://composio/callback"])
        // 3. Another account: v3.1 with the alias.
        #expect(seen[2].httpMethod == "POST" && seen[2].url?.path == "/api/v3.1/tool_router/session/trs_1/link")
        #expect(bodies[2] == ["toolkit": "googledrive", "alias": "work", "callback_url": "hermes://composio/callback"])
        // 4. The list: this user and this app only.
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: seen[3].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(seen[3].httpMethod == "GET" && query["user_ids"] == "dispatch-aabbcc" && query["toolkit_slugs"] == "googledrive")
        // Oldest first, a sign-in never finished left out; names: the alias, else "Account <n>".
        #expect(accounts.map(\.id) == ["ca_1", "ca_3", "ca_4"])
        #expect(accounts.enumerated().map { $1.title(number: $0 + 1) } == ["Account 1", "Work", "Account 3"])
        #expect(accounts[2].wordID == "googledrive_cd34")
        #expect(accounts[2].needsSignIn)
        // 5. Naming: PATCH v3.1 with the alias only.
        #expect(seen[4].httpMethod == "PATCH" && seen[4].url?.path == "/api/v3.1/connected_accounts/ca_1" && bodies[4] == ["alias": "home"])
        for request in seen { #expect(request.url?.host == "backend.composio.dev" && request.value(forHTTPHeaderField: "x-api-key") == "ak_mock_dispatch") }
    }

    @Test func aliasesFollowComposiosRule() {
        #expect(ComposioAlias.normalized("Work") == "work")
        #expect(ComposioAlias.normalized("  Work Drive ") == "work-drive")
        #expect(ComposioAlias.normalized("wes_ley--2") == "wes-ley-2")
        #expect(ComposioAlias.normalized("Café!") == "caf")
        #expect(ComposioAlias.normalized("—  ") == nil && ComposioAlias.normalized("") == nil && ComposioAlias.normalized("ü") == nil)
        #expect(ComposioAlias.normalized(String(repeating: "a", count: 31) + " bcd")?.count == 31, "no dash left at the cut")
        #expect(ComposioAlias.shown("work") == "Work" && ComposioAlias.shown("work-drive") == "Work Drive")
    }

    @Test func whetherASessionCanHoldASecondAccount() {
        #expect(ComposioSession.read(try! JSONValue.parse(Data(Self.session("trs_1", multi: true).utf8)))?.multiAccount == true)
        #expect(ComposioSession.read(try! JSONValue.parse(Data(Self.session("trs_1", multi: false).utf8)))?.multiAccount == false)
        let unknown = ComposioSession.read(try! JSONValue.parse(Data(Self.session("trs_1", multi: nil).utf8)))!
        #expect(unknown.multiAccount == nil)
        // Composio's own answer wins; when it doesn't say, only a session this app made multi-account counts.
        #expect(!ComposioSession.isMultiAccount(unknown, known: []))
        #expect(ComposioSession.isMultiAccount(unknown, known: ["trs_1"]))
        var no = unknown; no.multiAccount = false
        #expect(!ComposioSession.isMultiAccount(no, known: ["trs_1"]))
        var yes = unknown; yes.multiAccount = true
        #expect(ComposioSession.isMultiAccount(yes, known: []))
        // Bots to move: any composio server not already on the new session.
        let servers: [(profile: String, url: String?)] = [("ivy", "https://backend.composio.dev/tool_router/v3/trs_1/mcp"),
                                                          ("inbox", "https://backend.composio.dev/tool_router/v3/trs_9/mcp"), ("odd", nil)]
        #expect(ComposioModel.botsToMove(servers, to: "trs_9") == ["ivy", "odd"])
    }

    // MARK: The move to a multi-account session

    func movingModel(configureFailures: Int) -> (ComposioModel, ComposioKeychain, BotsFakeGatewayClient, () -> Void) {
        let gateway = BotsFakeGatewayClient()
        let servers = ServerBox(["ivy": "https://backend.composio.dev/tool_router/v3/trs_1/mcp", "inbox": "https://backend.composio.dev/tool_router/v3/trs_1/mcp"])
        let failures = ServerBox([:]); failures.set("left", "\(configureFailures)")
        gateway.on("profiles.list") { _ in
            let session = servers.get("record") ?? "trs_1"
            return ["profiles": [["name": "default", "ui_meta": [ComposioRecord.key: ["userId": "dispatch-aabbcc", "sessionId": .string(session), "allBots": false]]]]]
        }
        gateway.on("mcp.servers.list") { params in
            let profile = RosterText.text(params["profile"])
            guard let url = servers.get(profile) else { return ["servers": []] }
            return ["servers": [["name": "composio", "transport": "http", "url": .string(url)]]]
        }
        gateway.on("mcp.servers.remove") { params in servers.set(RosterText.text(params["profile"]), nil); return [:] }
        gateway.on("mcp.servers.add") { params in
            servers.set(RosterText.text(params["profile"]), RosterText.text(params["config"]?["url"])); return [:]
        }
        gateway.on("reload.mcp") { _ in [:] }
        gateway.on("profiles.configure") { params in
            let left = Int(failures.get("left") ?? "0") ?? 0
            if left > 0 { failures.set("left", "\(left - 1)"); return ["applied": ["ui_meta": false]] }
            servers.set("record", RosterText.text(params["ui_meta"]?[ComposioRecord.key]?["sessionId"]))
            return ["applied": ["ui_meta": true]]
        }
        gateway.onREST { _, _, _, _ in Data("{}".utf8) }
        let services = CapabilitiesFakeServices(CapabilitiesStore(client: gateway))
        func bot(_ id: String, hidden: Bool = false) -> Bot {
            Bot(id: id, name: id.capitalized, role: nil, preview: nil, lastActive: nil, isWorking: false, unread: false,
                pinned: false, pinOrder: nil, sectionName: nil, hidden: hidden, canonicalSessionId: nil, head: nil)
        }
        services.bots = [bot("default"), bot("ivy"), bot("inbox", hidden: true)]
        let keys = keychain()
        try? keys.save("ak_mock_dispatch")
        let model = ComposioModel(services: services, keys: keys, client: client(keys))
        let account = GatewayAccount.botsTestAccount.id
        let clear = {
            keys.clear()
            for key in ["session", "multi", "moving"] { UserDefaults.standard.removeObject(forKey: "connectapps.\(key).\(account)") }
        }
        clear()
        try? keys.save("ak_mock_dispatch")
        model.session = ComposioSession.read(try! JSONValue.parse(Data(Self.session("trs_1", multi: nil).utf8)))
        return (model, keys, gateway, { clear(); _ = servers })
    }

    @Test func anOlderSessionIsReplacedAndEveryBotMoves() async throws {
        let made = Counter()
        ComposioStub.reset { request in
            if request.httpMethod == "POST" { made.bump(); return (201, Self.session("trs_9", multi: true)) }
            return (200, Self.session("trs_9", multi: true))
        }
        let (model, _, gateway, clear) = movingModel(configureFailures: 0)
        defer { clear() }
        let next = try await model.multiAccountSession()
        #expect(next.id == "trs_9" && model.session?.id == "trs_9" && model.record?.sessionId == "trs_9")
        #expect(made.value == 1)
        #expect(ComposioStub.bodies.first?["user_id"] == "dispatch-aabbcc", "the same user, so the accounts carry over")
        let added = gateway.calls("mcp.servers.add").map { RosterText.text($0.params["profile"]) }.sorted()
        #expect(added == ["inbox", "ivy"], "every bot with Composio, hidden ones too; none for a bot without it")
        #expect(gateway.calls("mcp.servers.add").allSatisfy { RosterText.text($0.params["config"]?["url"]).contains("/trs_9/mcp") })
        // The bots move before the record names the new session.
        let lastAdd = gateway.calls("mcp.servers.add").map(\.at).max()!, write = gateway.calls("profiles.configure").last!.at
        #expect(lastAdd < write)
        // Once multi-account, nothing more happens.
        _ = try await model.multiAccountSession()
        #expect(made.value == 1 && gateway.calls("mcp.servers.add").count == 2)
    }

    @Test func aMoveThatStoppedHalfWayFinishesOnTheSameNewSession() async throws {
        let made = Counter()
        ComposioStub.reset { request in
            if request.httpMethod == "POST" { made.bump(); return (201, Self.session("trs_9", multi: true)) }
            return (200, Self.session(request.url?.path.hasSuffix("trs_9") == true ? "trs_9" : "trs_1", multi: request.url?.path.hasSuffix("trs_9") == true ? true : nil))
        }
        let (model, _, gateway, clear) = movingModel(configureFailures: 1)
        defer { clear() }
        await #expect(throws: (any Error).self) { _ = try await model.multiAccountSession() }
        #expect(model.session?.id == "trs_1", "the record still names the old session, so the app keeps it")
        #expect(gateway.calls("mcp.servers.add").count == 2)
        // Run again: the kept session is reused (no second create) and bots already on it are left alone.
        let next = try await model.multiAccountSession()
        #expect(next.id == "trs_9" && model.record?.sessionId == "trs_9")
        #expect(made.value == 1)
        #expect(gateway.calls("mcp.servers.add").count == 2)
        #expect(UserDefaults.standard.dictionary(forKey: "connectapps.moving.\(GatewayAccount.botsTestAccount.id)") == nil)
    }

    @Test func aReadOnlyGatewayIsNotMoved() async {
        ComposioStub.reset { _ in (201, Self.session("trs_9", multi: true)) }
        let (model, _, gateway, clear) = movingModel(configureFailures: 0)
        defer { clear() }
        model.store?.readOnlyGateway = true
        await #expect(throws: ComposioError.self) { _ = try await model.multiAccountSession() }
        #expect(ComposioStub.seen.isEmpty && gateway.calls("mcp.servers.add").isEmpty)
    }
}

nonisolated private final class ServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: String]
    init(_ map: [String: String]) { self.map = map }
    func get(_ key: String) -> String? { lock.withLock { map[key] } }
    func set(_ key: String, _ value: String?) { lock.withLock { map[key] = value } }
}

nonisolated private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}
