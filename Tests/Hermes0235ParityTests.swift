// Hermes Agent v0.23.0–v0.23.5 parity tests:
// client identity & activity, 300 s profile creation timeout, Google/Solstice env keys, Cloud webapp status,
// sandbox folder/website approvals + approval.received + Deny reason, plugin cards + content_refused + tool.output_risk,
// messaging live-apply + catalog install + signature, skills updates + lock, teammate waits, and hosted group controls.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

/// Minimal fake GatewayClient + ServerRequestAnswering for parity tests.
nonisolated final class ParityFakeClient: GatewayClient, ServerRequestAnswering, @unchecked Sendable {
    let account = GatewayAccount(id: "parity", baseURL: URL(string: "https://example.com")!, kind: .password, username: "demo", label: "Demo")
    private let lock = NSLock()
    private let eventHub = Broadcast<GatewayEvent>()
    var restHandler: (@Sendable (String, String, [URLQueryItem], Data?) throws -> Data)?
    var rpcHandler: (@Sendable (String, JSONValue) throws -> JSONValue)?
    var calls: [(method: String, params: JSONValue)] = []
    var restLog: [(method: String, path: String, query: [URLQueryItem], body: Data?)] = []
    var responses: [(id: String, result: JSONValue)] = []
    var failures: [(id: String, code: Int, message: String)] = []
    var declinesNotShown: Bool { true }

    func emit(_ event: GatewayEvent) { eventHub.yield(event) }

    func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        let handler: (@Sendable (String, String, [URLQueryItem], Data?) throws -> Data)? = lock.withLock {
            restLog.append((method, path, query, body))
            return restHandler
        }
        if let handler { return try handler(method, path, query, body) }
        return Data("{}".utf8)
    }

    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        let handler: (@Sendable (String, JSONValue) throws -> JSONValue)? = lock.withLock {
            calls.append((method, params))
            return rpcHandler
        }
        if let handler { return try handler(method, params) }
        return .object(["ok": true])
    }

    func respond(serverRequest id: String, result: JSONValue) async throws -> Int {
        lock.withLock { responses.append((id, result)) }
        return 1
    }

    func fail(serverRequest id: String, code: Int, message: String) async throws -> Int {
        lock.withLock { failures.append((id, code, message)) }
        return 1
    }

    func events() -> AsyncStream<GatewayEvent> { eventHub.subscribe() }
    func connectionStates() -> AsyncStream<ConnectionState> { AsyncStream { $0.yield(.ready); $0.finish() } }
    var latestReady: JSONValue? { nil }
    func appDidBecomeActive() {}
    func appDidEnterBackground() {}
    func shutdown() { eventHub.finish() }
}

struct Hermes0235ProtocolTests {
    @Test func clientIdentityAndActivityFormatMatchesOpenRPC() {
        let id = ClientIdentity.current()
        #expect(id.name == "hermes-hq-ios" || id.name == "hermes-hq-mac")
        #expect(id.kind == "mobile" || id.kind == "desktop")
        #expect(ClientIdentity.sanitizedVersion("1.2.3+45") == "1.2.3+45")
        #expect(ClientIdentity.sanitizedVersion("bad version with space") == nil)

        let report = ClientActivityReport(sessions: ["sess-1", ""], idleSeconds: -5, basis: .page, canAlert: true, away: false)
        #expect(report.json["sessions"] == .array([.string("sess-1")]))
        #expect(report.json["idle_seconds"] == .number(0))
        #expect(report.json["basis"] == .string("page"))
        #expect(report.json["can_alert"] == .bool(true))
        #expect(report.json["away"] == .bool(false))
    }

    @Test func clientActivityAggregatorTracksMultiplePanesIdleTimeAndAway() {
        let t0 = ContinuousClock.now
        var agg = ClientActivityAggregator(now: t0)
        let paneA = UUID()
        let paneB = UUID()
        agg.setSession("sess-a", token: paneA, now: t0)
        agg.setSession("sess-b", token: paneB, now: t0 + .seconds(2))
        let both = agg.report(now: t0 + .seconds(12))
        #expect(both.sessions == ["sess-a", "sess-b"])
        #expect(!both.away)
        #expect(both.canAlert)
        #expect(both.idleSeconds == 10)

        // Closing one pane keeps the other visible and does NOT mark the connection away.
        agg.setSession(nil, token: paneA, now: t0 + .seconds(15))
        let oneLeft = agg.report(now: t0 + .seconds(20))
        #expect(oneLeft.sessions == ["sess-b"])
        #expect(!oneLeft.away)
        #expect(oneLeft.canAlert)

        // App backgrounding sends away:true with empty sessions; returning restores visible sessions.
        agg.setAway(true, now: t0 + .seconds(25))
        let away = agg.report(now: t0 + .seconds(30))
        #expect(away.away)
        #expect(!away.canAlert)
        #expect(away.sessions.isEmpty)

        agg.setAway(false, now: t0 + .seconds(40))
        let back = agg.report(now: t0 + .seconds(40))
        #expect(!back.away)
        #expect(back.sessions == ["sess-b"])
        #expect(back.idleSeconds == 0)
    }

    @Test func contentRefusedReplacesOptimisticUserBubbleWithoutDuplicating() {
        let localUser = ChatMessage(id: "local-user-1", role: .user, parts: [.text("blocked input")], timestamp: Date(), rowId: nil)
        let folded = Hydration.fold([
            ["id": 10, "role": "user", "content": "blocked input", "display_kind": "content_refused",
             "display_metadata": ["content_refused": ["notice": "Safety filter refused this prompt"]]],
        ])
        let grafted = TranscriptMerge.graft(fresh: folded.messages, freshMeta: folded.meta, onto: [localUser], previousMeta: [:], aliases: [:], replaceAll: false)
        #expect(grafted.messages.count == 1)
        #expect(grafted.messages[0].role == .system)
        #expect(grafted.messages[0].contentRefusedNotice == "Safety filter refused this prompt")
        #expect(grafted.messages[0].parts == [.text("blocked input")])
    }

    @Test func hostedRoomLogParsesRoomContextSetAndBoundedActivityStrictDiscussionId() {
        let applied = HostedRoomLog.read([
            ["event_id": "evt-ctx", "kind": "room.context_set",
             "payload": ["purpose": "Ship v0.23.5", "notes": "Keep green", "routing": "lead", "lead_member_id": "ivy"]],
            ["event_id": "evt-act-no-disc", "kind": "room.activity", "payload": ["status": "bounded"]],
        ], members: [GroupMember(name: "ivy")])
        #expect(applied.updatedContext?.purpose == "Ship v0.23.5")
        #expect(applied.updatedContext?.routing == "lead")
        #expect(applied.updatedContext?.leadMemberId == "ivy")
        // Without `discussion_event_id`, must NOT fall back to `event_id`.
        #expect(applied.boundedPause == nil)

        let withDisc = HostedRoomLog.read([
            ["event_id": "evt-act-2", "kind": "room.activity",
             "payload": ["status": "bounded", "discussion_event_id": "disc-42", "thread_id": "t-1"]],
        ], members: [])
        #expect(withDisc.boundedPause == HostedRoomPause(discussionEventId: "disc-42", threadId: "t-1"))
    }

    @Test func solsticeKeysGroupUnderGemini() {
        let grouped = EnvKeys.groupedProviders([
            EnvVarInfo(key: "SOLSTICE_API_KEY", description: "", category: "provider", isPassword: true, isSet: false),
            EnvVarInfo(key: "GEMINI_API_KEY", description: "", category: "provider", isPassword: true, isSet: true),
        ])
        #expect(grouped.count == 1)
        #expect(grouped[0].name == "Gemini")
        #expect(grouped[0].keys.map(\.key).sorted() == ["GEMINI_API_KEY", "SOLSTICE_API_KEY"])
    }

    @Test func cloudWebappStatusValidatesStateAndUrl() {
        let agent = URL(string: "https://agent-1.agents.nousresearch.com")!
        let ready = CloudWebappStatus(status: ["webapp_state": "ready", "webapp_url": "https://agent-1.agents.nousresearch.com/app"], agentHost: agent.host)
        #expect(ready?.state == .ready)
        #expect(ready?.url?.absoluteString == "https://agent-1.agents.nousresearch.com/app")
        #expect(CloudDesktopWeb.address(agent, webapp: ready)?.absoluteString == "https://agent-1.agents.nousresearch.com/app")

        // Untrusted URL is rejected while state is preserved.
        let blocked = CloudWebappStatus(status: ["webapp_state": "not_available", "webapp_url": "http://evil.example.org/phish"], agentHost: agent.host)
        #expect(blocked?.state == .notAvailable)
        #expect(blocked?.url == nil)
    }

    @Test func hydrationHandlesPluginCardAndContentRefused() throws {
        let rows: [JSONValue] = [
            ["id": 10, "role": "user", "content": "blocked input", "display_kind": "content_refused",
             "display_metadata": ["content_refused": ["notice": "Safety filter refused this prompt"]]],
            ["id": 11, "role": "assistant", "display_kind": "plugin_card",
             "display_metadata": ["plugin_card": ["plugin_id": "weather", "card_id": "card-1"], "display_text": "72°F Sunny"]],
        ]
        let messages = Hydration.fold(rows).messages
        #expect(messages.count == 2)
        #expect(messages[0].role == .system)
        #expect(messages[0].contentRefusedNotice == "Safety filter refused this prompt")
        #expect(messages[0].parts == [.text("blocked input")])
        #expect(messages[1].pluginCard?.pluginId == "weather")
        #expect(messages[1].pluginCard?.cardId == "card-1")
        #expect(messages[1].parts == [.text("72°F Sunny")])
    }

    @Test func messagingLiveApplyCatalogAndSignature() async throws {
        let client = ParityFakeClient()
        client.restHandler = { method, path, _, _ in
            switch (method, path) {
            case ("GET", "/api/messaging/platforms"):
                return Data("""
                {"platforms":[{"id":"telegram","name":"Telegram","configured":true,"enabled":true,"gateway_running":true,"state":"connected"}],
                 "available":[{"name":"matrix","title":"Matrix","summary":"Federated messaging","badge":"official","disclosure":"Installs Matrix plugin","blocked":"","blocked_reason":"","install_command":"hermes plugins install matrix"}],
                 "signature":"sig-1"}
                """.utf8)
            case ("GET", "/api/messaging/platforms/signature"):
                return Data(#"{"signature":"sig-2"}"#.utf8)
            case ("POST", "/api/messaging/catalog/matrix/install"):
                return Data(#"{"ok":true,"plugin_name":"matrix","platforms":["matrix"],"warnings":[]}"#.utf8)
            case ("PUT", "/api/messaging/platforms/telegram"):
                return Data(#"{"ok":true,"platform":"telegram","hot_served":false,"live":{"applied":false,"state":"not_configured","detail":"Missing token"}}"#.utf8)
            default:
                return Data("{}".utf8)
            }
        }
        let api = MessagingAPI(client: client)
        let page = try await api.platformsPage(profile: "otto")
        #expect(page.platforms.count == 1)
        #expect(page.available.count == 1)
        #expect(page.available[0].badgeWord == "Official")
        #expect(page.signature == "sig-1")
        #expect(try await api.signature(profile: "otto") == "sig-2")

        let install = try await api.installCatalog("matrix", profile: "otto")
        #expect(install.ok)
        #expect(install.platforms == ["matrix"])

        let updated = try await api.updateWithLive("telegram", body: MessagingBodies.enabled(true), profile: "otto")
        #expect(updated.needsCredentials)
        #expect(!updated.appliedLive)
        #expect(updated.restartDetail == "Missing token")
    }

    @Test func teammateWaitsListAndUnsupported() async throws {
        let client = ParityFakeClient()
        client.rpcHandler = { method, params in
            #expect(method == "bot_delivery.list")
            #expect(params["profile"]?.string == "otto")
            return [
                "sender": "otto",
                "deliveries": [
                    ["delivery_id": "d1", "target": "ivy", "target_handle": "ivy", "state": "waiting_on_you",
                     "since": 1_700_000_000, "preview": "Review PR", "waiting_on": "approval"],
                    ["delivery_id": "d2", "target": "wren", "target_handle": "wren", "state": "failed",
                     "since": 1_700_000_000, "preview": "Ship release", "reason": "unknown_outcome"],
                ],
            ]
        }
        let outcome = try await TeammateWaitsAPI.list(client: client, profile: "otto")
        guard case .rows(let rows) = outcome else { Issue.record("Expected rows"); return }
        #expect(rows.count == 2)
        #expect(rows[0].statusLine == "Waiting on you — approve or deny")
        #expect(rows[1].isUnknownOutcome)

        client.rpcHandler = { _, _ in throw RPCError(code: -32601, message: "method not found") }
        let old = try await TeammateWaitsAPI.list(client: client, profile: "otto")
        #expect(old == .unsupported)
    }
}

@MainActor
struct Hermes0235MainActorTests {
    @Test func profileCreateTimeoutIs300Seconds() {
        let client = ParityFakeClient()
        let store = BotStore(client: client, account: client.account, cacheDirectory: FileManager.default.temporaryDirectory)
        #expect(store.editing.createTimeout == .seconds(300))
    }

    @Test func sandboxApprovalsValidateAndSendApprovalReceivedAndDenyReason() async throws {
        let client = ParityFakeClient()
        client.rpcHandler = { method, _ in
            if method == "approval.pending" { return ["approvals": []] }
            return ["ok": true]
        }
        var timing = ServerRequestCenter.Timing.standard
        timing.leaving = .milliseconds(5)
        let center = ServerRequestCenter(client: client, timing: timing, autoStart: true, enabled: true)

        func deliver(_ id: String, _ params: JSONValue) {
            center.receive(GatewayEvent(
                type: LocalEvent.serverRequest,
                sessionId: "s1",
                seq: nil,
                payload: ["id": .string(id), "method": "approval", "params": params, "replayed": false, "epoch": 1]
            ))
        }

        // Missing path on access approval -> -32602
        deliver("srq-bad-1", ["kind": "access", "session_id": "s1"])
        try? await Task.sleep(for: .milliseconds(30))
        #expect(client.failures.contains { $0.id == "srq-bad-1" && $0.code == -32602 })

        // Valid network approval -> parsed + approval.received + Deny with reason (allowSession forced false even if choices lists session)
        deliver("srq-net-1", [
            "kind": "network", "request_id": "req-n1", "session_id": "s1",
            "host": "api.example.com", "label": "Allow HTTPS", "risk": "external",
            "choices": ["once", "session", "always", "deny"],
            "description": "Allow HTTPS request",
        ])

        let prompts = center.prompts(for: ["s1"])
        #expect(prompts.approvals.count == 1)
        let prompt = prompts.approvals[0]
        #expect(prompt.kind == .network)
        #expect(prompt.host == "api.example.com")
        #expect(prompt.label == "Allow HTTPS")
        #expect(prompt.risk == "external")
        #expect(!prompt.allowSession)
        #expect(!prompt.showsDescription)

        center.markApprovalDisplayed("srq-net-1")
        center.markApprovalDisplayed("srq-net-1") // deduped
        try? await Task.sleep(for: .milliseconds(30))
        let receivedCalls = client.calls.filter { $0.method == "approval.received" }
        #expect(receivedCalls.count == 1)
        #expect(receivedCalls[0].params["request_id"]?.string == "req-n1")

        try await center.answerApproval("srq-net-1", .deny, reason: "Blocked by policy")
        let answer = try #require(client.responses.first { $0.id == "srq-net-1" })
        #expect(answer.result["choice"]?.string == "deny")
        #expect(answer.result["reason"]?.string == "Blocked by policy")
    }

    @Test func capabilitiesStoreSkillUpdatesAndLock() async throws {
        let client = ParityFakeClient()
        client.restHandler = { method, path, _, _ in
            switch (method, path) {
            case ("GET", "/api/skills"):
                return Data(#"[{"name":"deploy","description":"Deploy helper","enabled":true,"locked":true}]"#.utf8)
            case ("GET", "/api/skills/hub/updates"):
                return Data(#"{"updates":[{"name":"deploy","identifier":"nous/deploy","source":"official"}]}"#.utf8)
            case ("PUT", "/api/skills/lock"):
                return Data(#"{"ok":true,"name":"deploy","locked":false}"#.utf8)
            default:
                return Data("{}".utf8)
            }
        }
        let store = CapabilitiesStore(client: client)
        let skills = try await store.skills("otto")
        #expect(skills.count == 1 && skills[0].locked && skills[0].supportsLock)

        // Older gateways omitting `locked` hide the lock toggle (`supportsLock == false`).
        let legacySkill = CapabilitiesStore.skill(["name": "legacy", "description": "Old", "enabled": true])
        #expect(legacySkill?.locked == false)
        #expect(legacySkill?.supportsLock == false)

        let updates = try await store.skillUpdates("otto")
        #expect(updates.count == 1 && updates[0].identifier == "nous/deploy")

        try await store.setSkillLocked("deploy", locked: false, profile: "otto")
        #expect(client.restLog.contains { $0.method == "PUT" && $0.path == "/api/skills/lock" })
    }

    @Test func hostedRoomsApproveContinueContextAndPerProfileApprovalMode() async throws {
        let client = ParityFakeClient()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parity-hosted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = GroupStore(account: client.account, directory: dir, bots: nil)
        let hosted = HostedRooms(store: store, client: client)
        defer { hosted.shutdown(); store.close() }

        var room = GroupRoom(name: "Launch", roomId: "room-1")
        room.hosted = HostedRoomRef(owner: "default", roomId: "room-1")
        room.members = [GroupMember(name: "ivy"), GroupMember(name: "otto")]
        store.upsertHosted(room)

        client.rpcHandler = { method, params in
            switch method {
            case "groups.state":
                return ["room": ["room_id": "room-1", "name": "Launch", "members": []], "driver_status": ["working": false, "pending_actions": []]]
            case "groups.log":
                return ["events": [], "cursor": 0, "latest_seq": 0, "has_more": false]
            case "groups.context":
                return ["context": ["purpose": params["purpose"] ?? "", "notes": params["notes"] ?? "", "routing": "lead", "lead_member_id": "ivy"]]
            case "config.get":
                return ["value": "smart"]
            case "config.set":
                return ["value": params["value"] ?? "manual"]
            default:
                return ["ok": true]
            }
        }

        let action = HostedPendingAction(kind: "approval", memberId: "ivy", taskId: "t1", executionGeneration: 1,
                                         requestId: "req-1", command: "ls -la", description: nil, choices: [])
        // Group approvals only accept .once or .deny even when `choices` is empty.
        await #expect(throws: BotWriteError.self) {
            try await hosted.approve(room.key, action: action, choice: .session)
        }
        try await hosted.approve(room.key, action: action, choice: .once)
        #expect(client.calls.contains { $0.method == "groups.approve" && $0.params["request_id"]?.string == "req-1" })

        try await hosted.continueDiscussion(room.key, discussionEventId: "evt-1")
        #expect(client.calls.contains { $0.method == "groups.continue" && $0.params["discussion_event_id"]?.string == "evt-1" })

        // Unrelated room_ids broadcast must NOT trigger a forced `groups.list`.
        let listCallsBefore = client.calls.filter { $0.method == "groups.list" }.count
        hosted.handleGroupsChanged(["broadcast_id": "b-other", "room_ids": ["unknown-room"]])
        #expect(client.calls.filter { $0.method == "groups.list" }.count == listCallsBefore)

        try await hosted.setContext(room.key, purpose: "  Ship   v0.23.5  ", notes: "Keep green", routing: "lead", leadMemberId: "ivy")
        #expect(store.room(room.key)?.hostedContext?.purpose == "Ship v0.23.5")
        #expect(store.room(room.key)?.hostedContext?.leadMemberId == "ivy")

        // Approval mode section is hidden in local (non-hosted) rooms, shown in hosted rooms.
        var localRoom = GroupRoom(name: "Local", roomId: "local-1")
        localRoom.members = [GroupMember(name: "ivy")]
        #expect(!GroupInfoModel.showsApprovalModes(for: localRoom, hasHostedRooms: true))
        #expect(GroupInfoModel.showsApprovalModes(for: room, hasHostedRooms: true))

        #expect(try await hosted.approvalMode(forProfile: "ivy") == "smart")
        #expect(try await hosted.setApprovalMode("manual", forProfile: "ivy") == "manual")
        #expect(client.calls.contains { $0.method == "config.set" && $0.params["profile"]?.string == "ivy" && $0.params["key"]?.string == "approvals.mode" })
    }
}
