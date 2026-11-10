// End-to-end against the running performance fixture (spec 05 §A5) over a real socket. Enabled only when the run
// passes `TEST_RUNNER_HQ_PERF_FIXTURE=<base url>|<credentials json path>`, e.g.
//   TEST_RUNNER_HQ_PERF_FIXTURE="http://127.0.0.1:9717|$SCR/perf.json" scripts/build.sh test <UDID>
// Signs in once per test; all data is the fixture's synthetic chat.

import Foundation
import Testing
@testable import HermesHQNative

nonisolated enum LoopbackFixture {
    static var config: (base: URL, username: String, password: String)? {
        guard let raw = ProcessInfo.processInfo.environment["HQ_PERF_FIXTURE"], let bar = raw.firstIndex(of: "|") else { return nil }
        guard let base = URL(string: String(raw[..<bar])),
              let data = FileManager.default.contents(atPath: String(raw[raw.index(after: bar)...])),
              let creds = try? ChatJSON.parse(data), let user = creds["username"]?.string, let pass = creds["password"]?.string,
              ["127.0.0.1", "localhost", "::1"].contains(base.host() ?? "") else { return nil }
        return (base, user, pass)
    }
    static var available: Bool { config != nil }
}

@Suite("Loopback performance fixture (live socket)", .serialized, .enabled(if: LoopbackFixture.available))
@MainActor
struct LoopbackFixtureTests {
    let stored = "20260929_120000_aabbcc01"

    private func connect() async throws -> LoopbackGatewayClient {
        let config = try #require(LoopbackFixture.config)
        let client = LoopbackGatewayClient(base: config.base)
        try await client.signIn(username: config.username, password: config.password)
        try await client.connect()
        return client
    }

    private func texts(_ m: ChatMessage?) -> String {
        (m?.parts ?? []).compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
    }

    @Test func openStreamStopAndReconnect() async throws {
        let client = try await connect()
        defer { client.shutdown() }
        // A big chat (03 §11 F-b): 300 non-dense rows.
        try await client.fixture("/__fixture/history", ["profile": "default", "count": 300, "non_dense": true])

        let cache = makeTempCache()
        var changes: [ChatChange] = []
        var deliveries = 0
        let session = LiveChatSession(client: client, account: client.account, profile: "default", storedSessionId: stored,
                                      title: "Hermes", head: nil, cache: cache, resolveSessionId: nil)   // real display link
        session.onChange = { changes.append($0); deliveries += 1 }
        session.turnEndReadDelay = .milliseconds(300)
        session.start()
        #expect(await waitUntil(timeout: .seconds(10)) { session.openSettled })
        #expect(await waitUntil(timeout: .seconds(10)) { session.messages.count == 120 })
        #expect(session.messages.last?.plainText.hasPrefix("Synthetic history row 299") == true)
        #expect(session.runtimeSessionId == "5cc537d1")

        // 1. A streaming turn with tool calls (performance plan keys, spec 05 §A4).
        let words = (0..<30).map { "w\($0) " }
        try await client.fixture("/__fixture/plan", ["plans": [["chunks": .array(words.map { .string($0) }), "tools": 3, "toolBytes": 600,
                                                               "chunkDelay": 0.02]]])
        changes.removeAll()
        deliveries = 0
        session.send("Run three steps live")
        #expect(session.isRunning)
        #expect(await waitUntil(timeout: .seconds(10)) { !session.isRunning && session.messages.last?.role == .assistant })
        let reply = try #require(session.messages.last)
        let tools = reply.parts.compactMap { if case .tool(let c) = $0 { return c } else { return nil } }
        #expect(tools.count == 3)
        #expect(tools.allSatisfy { $0.state == .done && $0.title == "Ran 1 command" })
        #expect(texts(reply) == words.joined())
        #expect(session.messages.last { $0.role == .user }?.rowId != nil)          // user_row_id bound from the ack
        // Coalesced to at most one delivery per display frame (each delivery may carry a few ordered changes).
        print("live turn: \(deliveries) onChange calls, \(changes.count) changes for 30 deltas + 6 tool events")
        // Turn-end read keeps row identity.
        let ids = session.messages.suffix(2).map(\.id)
        #expect(await waitUntil(timeout: .seconds(5)) { session.lastTurnEndReadAt != nil && session.refreshTask == nil })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(session.messages.suffix(2).map(\.id) == ids)
        #expect(texts(session.messages.last) == words.joined())

        // 2. Stop mid-stream: the composer goes idle at once; late frames never change what was shown.
        try await client.fixture("/__fixture/plan", ["plans": [["chunks": .array((0..<200).map { .string("s\($0) ") }), "chunkDelay": 0.03]]])
        session.send("Write a long answer")
        #expect(await waitUntil(timeout: .seconds(10)) { texts(session.messages.last).count > 20 && session.messages.last?.role == .assistant })
        session.stop()
        #expect(!session.isRunning)
        let shown = texts(session.messages.last)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(texts(session.messages.last) == shown)
        #expect(session.messages.last?.interrupted == true)

        // 3. Socket drop mid-stream (fixture has no seq → REST refresh + re-bind); the reply still completes whole.
        let long = (0..<60).map { "r\($0) " }
        try await client.fixture("/__fixture/plan", ["plans": [["chunks": .array(long.map { .string($0) }), "chunkDelay": 0.04]]])
        session.send("Keep going")
        #expect(await waitUntil(timeout: .seconds(10)) { texts(session.messages.last).count > 15 && session.messages.last?.role == .assistant })
        try await client.reconnect()
        #expect(await waitUntil(timeout: .seconds(15)) { !session.isRunning })
        #expect(await waitUntil(timeout: .seconds(5)) { texts(session.messages.last { $0.role == .assistant }) == long.joined() })
        #expect(session.messages.filter { $0.role == .user && $0.plainText == "Keep going" }.count == 1)

        session.stopObserving()
        cache.flush()
        let cached = TranscriptCache(root: cache.root).load(account: client.account.id, profile: "default", storedId: stored)
        #expect(cached?.count == 40)
        print("live session ok: \(session.messages.count) messages, \(client.framesIn) frames in")
    }
}

// The Plaid stress gateway (spec 05 §A9): seq'd events, a replay ring and `session.events.since`. Enabled with
// `TEST_RUNNER_HQ_PLAID_FIXTURE=<base url>|<credentials json path>`.
nonisolated enum PlaidFixture {
    static var config: (base: URL, username: String, password: String)? {
        guard let raw = ProcessInfo.processInfo.environment["HQ_PLAID_FIXTURE"], let bar = raw.firstIndex(of: "|") else { return nil }
        guard let base = URL(string: String(raw[..<bar])),
              let data = FileManager.default.contents(atPath: String(raw[raw.index(after: bar)...])),
              let creds = try? ChatJSON.parse(data), let user = creds["username"]?.string, let pass = creds["password"]?.string,
              ["127.0.0.1", "localhost", "::1"].contains(base.host() ?? "") else { return nil }
        return (base, user, pass)
    }
    static var available: Bool { config != nil }
}

@Suite("Loopback Plaid gateway (live socket, replay)", .serialized, .enabled(if: PlaidFixture.available))
@MainActor
struct PlaidLoopbackTests {
    @Test func busyTurnSurvivesASocketDropByReplay() async throws {
        let config = try #require(PlaidFixture.config)
        let client = LoopbackGatewayClient(base: config.base)
        try await client.signIn(username: config.username, password: config.password)
        try await client.connect()
        defer { client.shutdown() }
        _ = try await client.rest("GET", "/__plaid/opts", query: [URLQueryItem(name: "minutes", value: "0.1"),
                                                                  URLQueryItem(name: "subagents", value: "0"),
                                                                  URLQueryItem(name: "browser", value: "0"),
                                                                  URLQueryItem(name: "vault", value: "0")], body: nil)
        let statsBefore = try ChatJSON.parse(try await client.rest("GET", "/__plaid/stats", query: [], body: nil))
        let cache = makeTempCache()
        let session = LiveChatSession(client: client, account: client.account, profile: "default",
                                      storedSessionId: "20260101_090000_aa0001aa", title: "Hermes", head: nil, cache: cache,
                                      resolveSessionId: nil)
        session.start()
        #expect(await waitUntil(timeout: .seconds(15)) { session.openSettled && session.olderTask == nil })
        let opened = session.messages.count
        #expect(opened > 10)
        #expect(session.hasOlder)

        session.send("Finish the Plaid setup.")
        #expect(await waitUntil(timeout: .seconds(20)) { (session.lastSeq ?? 0) > 20 })
        let cursor = session.lastSeq ?? 0
        try await client.reconnect()
        #expect(await waitUntil(timeout: .seconds(60)) { !session.isRunning })
        let stats = try ChatJSON.parse(try await client.rest("GET", "/__plaid/stats", query: [], body: nil))
        #expect((stats["replay_calls"]?.int ?? 0) > (statsBefore["replay_calls"]?.int ?? 0))
        #expect((session.lastSeq ?? 0) > cursor)

        let reply = try #require(session.messages.last { $0.role == .assistant })
        let text = reply.parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        let tools = reply.parts.compactMap { if case .tool(let c) = $0 { return c } else { return nil } }
        #expect(!text.isEmpty)
        #expect(!tools.isEmpty)
        #expect(tools.allSatisfy { $0.state != .running })
        #expect(reply.parts.contains { if case .reasoning = $0 { return true } else { return false } })
        // The stored final row holds every streamed delta: the replayed transcript lost nothing.
        let page = try await HistoryAPI.fetch(client: client, request: HistoryRequest(storedSessionId: "20260101_090000_aa0001aa",
                                                                                       profile: "default", limit: 1), features: nil).0
        let stored = page.rows.last?["content"]?.string ?? ""
        #expect(ChatText.flat(text) == ChatText.flat(stored))
        print("plaid replay: cursor \(cursor) → \(session.lastSeq ?? 0), \(tools.count) tools, \(text.count) chars, \(client.framesIn) frames")
        session.stopObserving()
    }
}
