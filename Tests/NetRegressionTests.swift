import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

// Regression tests for the review of the Net module (2026-10-09): both URLSession pools of one transport in flight
// together, the RPCError-only `call` contract, the restore budget that never waits on a renewal, one ticket per
// socket however many wake signals arrive, and the replay engine driven through the real connection.

/// Pure pieces: no gateway needed.
@Suite struct NetBoundaryTests {
    @Test func notSentErrorsCarryTheirReason() {
        let error = RPCError.notSent(.paused)
        #expect(error.isNotConnected && !error.isTimeout && !error.isConnectionLost)
        #expect(error.notSentBecause == .paused)
        #expect(error.message == GatewayFailure.paused.message)
        #expect(GatewayFailure.from(error) == .paused)
        #expect(GatewayFailure.from(RPCError.notSent(.sessionEnded)).isRejection)
        #expect(RPCError.notSent(.offline).notSentBecause == .offline)
        #expect(GatewayFailure.forCode("network") == .offline)
        #expect(ConnectionState.offline(reason: "network").userMessage == GatewayFailure.offline.message)
        // A gateway's own error is not a not-sent one.
        let answer = RPCError(code: 4001, message: "busy", data: ["reason": "paused"])
        #expect(answer.notSentBecause == nil)
        #expect(GatewayFailure.from(answer) == .gatewayError("rpc 4001"))
    }

    @Test func retryAfterSecondsAndDates() {
        #expect(RetryLater.parse("30") == 30)
        #expect(RetryLater.parse(" 2 ") == 2)
        #expect(RetryLater.parse("0") == nil && RetryLater.parse(nil) == nil && RetryLater.parse("soon") == nil)
        let now = Date(timeIntervalSince1970: 1_791_581_000)
        let wait = RetryLater.parse("Mon, 12 Oct 2026 12:03:20 GMT", now: now)
        #expect(wait.map { abs($0 - (1_791_806_600 - 1_791_581_000)) < 1 } == true)
        #expect(RetryLater.parse("Thu, 01 Jan 1970 00:00:00 GMT", now: now) == nil)
        #expect(GatewayFailure.from(RetryLater(failure: .rateLimited, after: 9)) == .rateLimited)
    }

    /// The restore budget mechanism: a step that ignores cancellation (as awaiting a shared Nous rotation does) can
    /// not hold the caller past the deadline, and still runs to its end on its own.
    @Test func deadlineNeverWaitsForWorkThatIgnoresCancellation() async {
        let finished = Locked(false)
        let stubborn = Task.detached {
            try? await Task.sleep(for: .milliseconds(1500))
            finished.set(true)
        }
        let started = ContinuousClock.now
        do {
            try await untilDeadline(.now + .milliseconds(300), late: { GatewayFailure.timeout }) {
                await stubborn.value // not cancellable: like `refreshFlight.value`
            }
            Issue.record("expected the deadline")
        } catch {
            #expect(GatewayFailure.from(error) == .timeout)
        }
        #expect(started.duration(to: .now) < .milliseconds(900))
        #expect(!finished.value)
        await stubborn.value
        #expect(finished.value)
    }

    @Test func deadlineReturnsTheWorkAndHonoursCallerCancellation() async throws {
        let value = try await untilDeadline(.now + .seconds(5), late: { GatewayFailure.timeout }) { 42 }
        #expect(value == 42)
        await #expect(throws: GatewayFailure.notHermes) {
            try await untilDeadline(.now + .seconds(5), late: { GatewayFailure.timeout }) { () async throws -> Int in throw GatewayFailure.notHermes }
        }
        let caller = Task {
            try await untilDeadline(.now + .seconds(30), late: { GatewayFailure.timeout }) { () async throws -> Int in
                try? await Task.sleep(for: .seconds(30)); return 0
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        caller.cancel()
        await #expect(throws: CancellationError.self) { _ = try await caller.value }
        #expect(started.duration(to: .now) < .seconds(1))
    }

    /// A request whose task was cancelled before it started settles at once and leaves nothing registered.
    @Test func requestCancelledBeforeItStartsSettles() async {
        let transport = HTTPTransport()
        defer { transport.invalidate() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.data(for: URLRequest(url: URL(string: "http://127.0.0.1:1/api/status")!), pool: .control, ceiling: 1024)
        }
        let outcome = await task.result
        if case .success = outcome { Issue.record("expected a cancellation") }
        #expect(transport.requestsInFlight == 0)
    }

    @Test func replayBookGapsAndForgetting() {
        var book = ReplayBook()
        _ = book.ready(epoch: "e1")
        func event(_ seq: Int, _ session: String = "s1") -> GatewayEvent {
            GatewayEvent(type: "message.delta", sessionId: session, seq: seq, payload: .null)
        }
        #expect(book.live(event(1), size: 10).deliver?.seq == 1)
        #expect(!book.hasGap(event(2)))
        #expect(book.hasGap(event(4)))
        book.park("s1")
        #expect(book.live(event(4), size: 10).deliver == nil)
        _ = book.accept(event(2)); _ = book.accept(event(3))
        #expect(book.release("s1").map(\.seq) == [4])
        _ = book.accept(event(1, "s2"))
        #expect(Set(book.forgetCursors()) == ["s1", "s2"])
        #expect(book.cursors.isEmpty)
    }
}

/// Keychain rules from the review: cookie writes are compare-and-swap, a refused throw-away check forgets nothing.
@Suite(.serialized) struct NetVaultRaceTests {
    let vault = Fixtures.testVault("races")

    func cookie(_ value: String) -> [SavedCookie] { [SavedCookie(name: "hermes_session_at", value: value, domain: "127.0.0.1")] }

    @Test func cookieWritesNeverResurrectAnEndedSession() throws {
        vault.removeAll()
        defer { vault.removeAll() }
        let account = StoredAccount(url: "http://127.0.0.1:9", username: "fleet", cookies: cookie("1"))
        try vault.save(account)
        #expect(vault.swapCookies(account.key, expected: cookie("1"), new: cookie("2")))
        #expect(vault.peek()?.cookies == cookie("2"))
        // Another writer (a new sign-in) moved on: a stale renewal is not written.
        #expect(!vault.swapCookies(account.key, expected: cookie("1"), new: cookie("3")))
        #expect(vault.peek()?.cookies == cookie("2"))
        // Refused, then a renewal queued before the refusal runs: nothing comes back.
        vault.forgetSession(account.key)
        #expect(!vault.swapCookies(account.key, expected: cookie("2"), new: cookie("4")))
        #expect(vault.peek()?.cookies == nil)
        // Signed out: nothing to write to.
        _ = try vault.clearCurrent()
        #expect(!vault.swapCookies(account.key, expected: cookie("2"), new: cookie("5")))
        #expect(try vault.load() == nil)
    }

}

/// A Nous re-sign-in whose fresh bearer is refused must not wipe the account's saved, still-valid session (the check
/// is built with `persisted: false`); an ordinary auth that is refused does forget it.
@Suite(.serialized, .enabled(if: Fixtures.nousAvailable))
struct ThrowAwayCheckTests {
    let vault = Fixtures.testVault("check")
    let url = "http://127.0.0.1:\(Fixtures.nousPort)"

    func pair(_ name: String) -> NousTokens {
        NousTokens(accessToken: "nat_bogus_\(name)", refreshToken: "nrt_bogus_\(name)", expiresAt: 2_000_000_000, userId: "u1", obtainedAt: nil)
    }

    @Test func refusedCheckForgetsNothingButARefusedSessionDoes() async throws {
        vault.removeAll()
        defer { vault.removeAll() }
        let saved = StoredAccount(url: url, username: "nous:u1", nous: pair("saved"))
        try vault.save(saved)
        let candidate = StoredAccount(url: url, username: "nous:u1", nous: pair("fresh"))
        let transport = HTTPTransport(cookies: false)
        defer { transport.invalidate() }

        let check = GatewayAuth(stored: candidate, base: URL(string: url)!, transport: transport, vault: vault, verified: false,
                                persisted: false, renewals: NousRenewals())
        await #expect(throws: GatewayFailure.sessionEnded) { try await check.verify(budget: nil) }
        #expect(vault.peek()?.nous?.accessToken == "nat_bogus_saved")

        let live = GatewayAuth(stored: saved, base: URL(string: url)!, transport: transport, vault: vault, verified: false,
                               renewals: NousRenewals())
        await #expect(throws: GatewayFailure.sessionEnded) { try await live.verify(budget: nil) }
        #expect(vault.peek()?.nous == nil && vault.peek()?.username == "nous:u1")
    }
}

/// Both pools of one transport at once against the performance fixture (unauthenticated routes: /api/auth/me
/// answers 401 there, /api/status 200), each pool's first task numbered 1 by its own URLSession.
@Suite(.serialized, .enabled(if: Fixtures.perfAvailable))
struct TransportPoolTests {
    nonisolated static let base = "http://127.0.0.1:\(Fixtures.perfPort)"

    nonisolated static func get(_ transport: HTTPTransport, _ path: String, _ pool: HTTPTransport.Pool) async throws -> (Int, String) {
        let request = URLRequest(url: URL(string: base + path)!, timeoutInterval: 5)
        let (data, response) = try await transport.data(for: request, pool: pool, ceiling: 1 << 20)
        return (response.statusCode, String(decoding: data, as: UTF8.self))
    }

    nonisolated static func expectMe(_ answer: (Int, String)) {
        #expect(answer.0 == 401 && answer.1.contains("unauthorized"), "control got \(answer)")
    }
    nonisolated static func expectStatus(_ answer: (Int, String)) {
        #expect(answer.0 == 200 && answer.1.contains("release_date"), "bulk got \(answer)")
    }

    @Test func controlAndBulkTogetherEachGetTheirOwnAnswer() async throws {
        for _ in 0..<6 {
            let transport = HTTPTransport() // fresh: both pools number their first task 1
            defer { transport.invalidate() }
            try await untilDeadline(.now + .seconds(5), late: { TimedOut(what: "both pools' first requests") }) {
                async let me = Self.get(transport, "/api/auth/me", .control)
                async let status = Self.get(transport, "/api/status", .bulk)
                let (a, b) = try await (me, status)
                Self.expectMe(a)
                Self.expectStatus(b)
            }
            #expect(transport.requestsInFlight == 0)
        }
    }

    @Test func manyRequestsOnBothPoolsAtOnce() async throws {
        let transport = HTTPTransport()
        defer { transport.invalidate() }
        try await untilDeadline(.now + .seconds(10), late: { TimedOut(what: "40 mixed requests") }) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<40 {
                    group.addTask {
                        if i % 2 == 0 { Self.expectMe(try await Self.get(transport, "/api/auth/me", .control)) }
                        else { Self.expectStatus(try await Self.get(transport, "/api/status", .bulk)) }
                    }
                }
                try await group.waitForAll()
            }
        }
        #expect(transport.requestsInFlight == 0)
    }
}

/// The connection with the performance fixture: a launch restore while the UI's first reads run, and the replay
/// engine (frames injected as if from the socket, since this fixture sends no `seq`).
@Suite(.serialized, .enabled(if: Fixtures.perfAvailable))
struct ConnectionReplayTests {
    let vault = Fixtures.testVault("replay")

    func signedIn() async throws -> StoredAccount {
        vault.removeAll()
        let creds = try #require(Fixtures.credentials("perf.json"))
        let service = SignInService(store: AccountStore(vault: vault))
        let account = try await service.signInWithPassword(address: creds.url, username: creds.username, password: creds.password)
        service.client(for: account).shutdown()
        return try #require(vault.peek())
    }

    /// The blocker's app-level shape: the restore's `/api/auth/me` (control) and the first REST reads (bulk) in flight
    /// together must all finish, and the client must reach ready.
    @Test func restoreWhileRestReadsRun() async throws {
        defer { vault.removeAll() }
        let stored = try await signedIn()
        for _ in 0..<3 {
            let client = LiveGatewayClient(stored: stored, transport: HTTPTransport(), vault: vault, verified: false, watchNetwork: false)
            defer { client.shutdown() }
            try await untilDeadline(.now + .seconds(10), late: { TimedOut(what: "restore + reads") }) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<4 {
                        group.addTask { _ = try JSONValue.parseFast(try await client.get("/api/sessions")) }
                    }
                    group.addTask { try await waitFor(client, .ready, within: 10) }
                    try await group.waitForAll()
                }
            }
            _ = try await client.call("profiles.list", [:])
        }
    }

    static func frame(_ session: String, _ seq: Int) -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"\#(session)","seq":\#(seq),"payload":{"text":"\#(seq)"}}}"#
    }
    static let marker = #"{"jsonrpc":"2.0","method":"event","params":{"type":"test.marker","session_id":"","payload":{}}}"#

    func sinceCalls(_ session: String) async throws -> [Int] {
        let state = try await Fixtures.control(Fixtures.perfPort, "/__fixture/state", method: "GET")
        return (state["rpc"]?.array ?? []).compactMap { entry -> Int? in
            guard entry["method"]?.string == "session.events.since", entry["params"]?["session_id"]?.string == session else { return nil }
            return entry["params"]?["last_seen"]?.int
        }
    }

    @Test func reconnectReplaysFromTheCursorAndGapsAreRepaired() async throws {
        defer { vault.removeAll() }
        let stored = try await signedIn()
        let transport = HTTPTransport()
        transport.installCookies(stored.cookies ?? [])
        let client = LiveGatewayClient(stored: stored, transport: transport, vault: vault, verified: true, watchNetwork: false)
        defer { client.shutdown() }
        try await waitFor(client, .ready)
        let connection = client.debugConnection
        let session = String(UUID().uuidString.prefix(8)).lowercased()

        // Duplicates never reach events().
        var events = client.events()
        for seq in [1, 2, 3, 3, 2] { await connection.debugReceive(Self.frame(session, seq)) }
        await connection.debugReceive(Self.marker)
        var seen = try await collect(events, within: 5, "marker") { $0.type == "test.marker" }
        #expect(seen.filter { $0.sessionId == session }.compactMap(\.seq) == [1, 2, 3])
        #expect(await connection.debugCursors[session] == 3)

        // A reconnect asks the gateway for what came after the cursor.
        events = client.events()
        await connection.debugDropSocket()
        _ = try await first(events, within: 10, "gateway.ready") { $0.type == "gateway.ready" }
        await client.replayDone(session: session)
        #expect(try await sinceCalls(session) == [3])
        // (The fixture answers with another epoch, "fixture": that is a gateway restart, so the cursors went.)
        #expect(await connection.debugCursors[session] == nil)

        // A live frame that skips past the cursor is held while the gap is fetched, then delivered once.
        events = client.events()
        await connection.debugReceive(Self.frame(session, 10))
        await connection.debugReceive(Self.frame(session, 12))
        await connection.debugReceive(Self.frame(session, 12))
        await client.replayDone(session: session)
        await connection.debugReceive(Self.marker)
        seen = try await collect(events, within: 5, "marker after the gap") { $0.type == "test.marker" }
        #expect(seen.filter { $0.sessionId == session }.compactMap(\.seq) == [10, 12])
        #expect(try await sinceCalls(session) == [3, 10])
        #expect(await connection.debugWaiting.barriers == 0)
        #expect(client.state == .ready)
    }

    /// Calls made while the phone has no network fail at once (never sent), and a return from the background with no
    /// network says "offline", not the silent "paused".
    @Test func knownDownFailsFastAndOfflineSurvivesForeground() async throws {
        defer { vault.removeAll() }
        let stored = try await signedIn()
        let transport = HTTPTransport()
        transport.installCookies(stored.cookies ?? [])
        let client = LiveGatewayClient(stored: stored, transport: transport, vault: vault, verified: true, watchNetwork: false)
        defer { client.shutdown() }
        try await waitFor(client, .ready)
        let connection = client.debugConnection

        await connection.handle(.enteredBackground(granted: false))
        #expect(client.state == .offline(reason: "paused"))
        await connection.handle(.path(.lost))
        await connection.handle(.becameActive)
        #expect(client.state == .offline(reason: "network"))
        let started = ContinuousClock.now
        #expect(await notSentReason { _ = try await client.call("session.list", [:], timeout: .seconds(30)) } == .offline)
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(await connection.debugWaiting.calls == 0)

        let ready = client.events()
        await connection.handle(.path(.restored))
        _ = try await first(ready, within: 10, "gateway.ready after the network came back") { $0.type == "gateway.ready" }
        _ = try await client.call("session.list", [:])
    }

    /// An inbound frame over 64 MiB closes the socket with 1009, says so once, and does not loop (spec 01 §10.3).
    @Test func oversizedFrameIsReportedOnceAndNotLooped() async throws {
        defer { vault.removeAll() }
        let stored = try await signedIn()
        let transport = HTTPTransport()
        transport.installCookies(stored.cookies ?? [])
        let client = LiveGatewayClient(stored: stored, transport: transport, vault: vault, verified: true, watchNetwork: false)
        defer { client.shutdown() }
        try await waitFor(client, .ready)
        try await Task.sleep(for: .seconds(5.2)) // a socket that stayed up: the next oversize starts a new streak
        let events = client.events()
        let huge = String(repeating: "x", count: (64 << 20) + 4096)
        try await Fixtures.control(Fixtures.perfPort, "/__fixture/event", json: ["profile": "default", "type": "message.delta",
                                                                                  "payload": ["text": huge]])
        let seen = try await collect(events, within: 20, "the oversize notice, then ready again") { $0.type == "gateway.ready" }
        let notices = seen.filter { $0.type == LocalEvent.messageTooLarge }
        #expect(notices.count == 1)
        #expect(notices.first?.payload["message"]?.string == GatewayFailure.responseTooLarge.message)
        #expect(!seen.contains { $0.type == "message.delta" })
        // The same again right away: no second notice, and the redial waits the full back-off cap instead of looping.
        let again = client.events()
        try await Fixtures.control(Fixtures.perfPort, "/__fixture/event", json: ["profile": "default", "type": "message.delta",
                                                                                  "payload": ["text": huge]])
        _ = try await first(client.connectionStates(), within: 20, "reconnecting") {
            if case .reconnecting = $0 { return true } else { return false }
        }
        #expect(client.lastFailure == .responseTooLarge)
        // Nothing at all arrives for the next 3 s: no second notice, no ready (the redial waits ~15 s).
        let later = try? await collect(again, within: 3, "anything") { _ in true }
        #expect(later == nil, "got \(later?.map(\.type) ?? [])")
        #expect(client.state != .ready)
    }

    /// Waiting callers that get the socket leave no timers or waiters behind.
    @Test func waitingCallsLeaveNothingBehind() async throws {
        defer { vault.removeAll() }
        let stored = try await signedIn()
        let transport = HTTPTransport()
        transport.installCookies(stored.cookies ?? [])
        let client = LiveGatewayClient(stored: stored, transport: transport, vault: vault, verified: true, watchNetwork: false)
        defer { client.shutdown() }
        // Calls made at once, before the first ready.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await client.call("session.list", [:], timeout: .seconds(20)) } }
            try await group.waitForAll()
        }
        #expect(await client.debugConnection.debugWaiting.calls == 0)
    }
}

/// Wake signals, a path change and waiting callers together still mint exactly one ticket for one socket (Nous
/// fixture: tickets are single-use and counted).
@Suite(.serialized, .enabled(if: Fixtures.nousAvailable))
struct TicketPerSocketTests {
    let vault = Fixtures.testVault("tickets")

    @Test func everyoneAtOnceStillMintsOneTicket() async throws {
        vault.removeAll()
        defer { vault.removeAll() }
        await NousRenewals.shared.reset()
        try await Fixtures.control(Fixtures.nousPort, "/__fixture/nous/ttl", json: ["access": 60])
        let service = SignInService(store: AccountStore(vault: vault))
        let account = try await service.signInWithNous(address: "http://127.0.0.1:\(Fixtures.nousPort)", browser: FixtureBrowser(),
                                                       relay: LoopbackRelay())
        let client = service.client(for: account)
        defer { client.shutdown() }
        try await waitFor(client, .ready)
        let connection = client.debugConnection
        let before = try await Fixtures.nousCounts()

        await connection.debugDropSocket()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = try await client.call("profiles.list", [:], timeout: .seconds(20)) } }
            group.addTask { client.reconnectNow() }
            group.addTask { await connection.handle(.path(.restored)) }
            group.addTask { await connection.handle(.reconnectNow) }
            group.addTask { client.appDidBecomeActive() }
            try await group.waitForAll()
        }
        try await waitFor(client, .ready)
        try await Task.sleep(for: .milliseconds(500)) // anything stray would have dialed by now
        let after = try await Fixtures.nousCounts()
        #expect(after["ticketsMinted", default: 0] - before["ticketsMinted", default: 0] == 1)
        #expect(after["wsOpened", default: 0] - before["wsOpened", default: 0] == 1)
        #expect(after["ticketsRejected", default: 0] == before["ticketsRejected", default: 0])
    }
}

/// Real `seq`'d events, a real replay ring and `session.events.since` (Plaid stress fixture, spec 05 A9), with a
/// network cut in the middle of a busy turn. Emulates Chat: re-resume the session on every gateway.ready.
@Suite(.serialized, .enabled(if: Fixtures.plaidAvailable))
struct PlaidReplayTests {
    let vault = Fixtures.testVault("plaid")
    static let main = "20260101_090000_aa0001aa"

    nonisolated static func ready(after index: Int, _ list: [GatewayEvent]) -> Int? {
        list.indices.first { $0 >= index && list[$0].type == "gateway.ready" }
    }

    nonisolated static func ours(_ rid: String, _ list: [GatewayEvent]) -> [GatewayEvent] {
        list.filter { $0.sessionId == rid && $0.seq != nil }
    }

    @Test func networkCutMidTurnLosesAndDuplicatesNothing() async throws {
        vault.removeAll()
        defer { vault.removeAll() }
        let creds = try #require(Fixtures.credentials("plaid.json"))
        let service = SignInService(store: AccountStore(vault: vault))
        let account = try await service.signInWithPassword(address: creds.url, username: creds.username, password: creds.password)
        let client = service.client(for: account)
        defer { client.shutdown() }
        try await waitFor(client, .ready)
        let events = client.events()
        let resumed = try await client.call("session.resume", ["session_id": .string(Self.main), "profile": "default"])
        let rid = try #require(resumed["session_id"]?.string)

        let collected = Locked<[GatewayEvent]>([])
        let consumer = Task {
            for await event in events {
                collected.mutate { $0.append(event) }
                if event.type == "gateway.ready" {
                    // Chat re-binds its open session on every ready.
                    Task { _ = try? await client.call("session.resume", ["session_id": .string(Self.main), "profile": "default"]) }
                }
            }
        }
        defer { consumer.cancel() }
        try await Fixtures.plaid("/__plaid/start?minutes=1&subagents=0&browser=0&vault=0")
        defer { Task { try? await Fixtures.plaid("/__plaid/stop") } }

        try await eventually(within: 30, "25 seq'd events") { Self.ours(rid, collected.value).count >= 25 }
        let kickedAt = collected.value.count
        // A network cut mid-turn: every socket dies and the gateway hangs requests for 3 s while the turn goes on, so
        // the events emitted meanwhile exist only in the gateway's ring.
        try await Fixtures.plaid("/__plaid/blackhole?s=3")
        try await eventually(within: 30, "a ready and 30 more events after the reset") {
            let list = collected.value
            guard let ready = Self.ready(after: kickedAt, list) else { return false }
            return Self.ours(rid, Array(list[ready...])).count >= 30
        }
        let list = collected.value
        let seqs = Self.ours(rid, list).compactMap(\.seq)
        #expect(Set(seqs).count == seqs.count, "duplicates: \(seqs)")
        #expect(seqs == seqs.sorted(), "out of order: \(seqs)")
        if let low = seqs.first, let high = seqs.last { #expect(seqs == Array(low...high), "gaps: \(seqs)") }
        // The replay asked from the cursor held when the socket died.
        let ready = try #require(Self.ready(after: kickedAt, list))
        let cursor = try #require(Self.ours(rid, Array(list[..<ready])).last?.seq)
        let log = try await Fixtures.plaid("/__plaid/log?n=600")["log"]?.array?.compactMap(\.string) ?? []
        let replayLine = log.first { $0.contains("replay rid=\(rid) last=\(cursor) ") }
        #expect(replayLine != nil, "log: \(log.filter { $0.contains("replay") })")
        // …and brought back what the cut hid (then live frames continued without a gap or a repeat, checked above).
        let replayed = replayLine.flatMap { line in line.range(of: #"-> (\d+) events"#, options: .regularExpression).map { line[$0] } }
            .flatMap { Int($0.split(separator: " ")[1]) }
        #expect((replayed ?? 0) > 0, "replay line: \(replayLine ?? "none")")
    }
}

/// The real ASWebAuthenticationSession (the system consent alert over the app) with the Nous fixture's authorize URL.
/// Its completion handler runs only when a person cancels (a programmatic `cancel()` — how the loopback relay closes
/// the sheet — dismisses it without calling the handler: seen on iOS 27), and AuthenticationServices doesn't say on
/// which queue, so the handler is @Sendable and hops to the main actor. Manual: run with TEST_RUNNER_HQN_SHEET=1 on a
/// booted simulator and tap Cancel on the alert within HQN_SHEET_SECONDS (default 60).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HQN_SHEET"] == "1" && Fixtures.nousAvailable))
struct NousSheetTests {
    @MainActor @Test func cancellingTheRealSheetReportsOnce() async throws {
        let pkce = NousPKCE.pair()
        let url = try #require(NousGatewayProtocol.authorizeURL(gateway: URL(string: "http://127.0.0.1:\(Fixtures.nousPort)")!,
                                                               challenge: pkce.challenge, redirect: "http://127.0.0.1:9/callback",
                                                               state: NousPKCE.state()))
        let browser = WebAuthBrowser(anchor: nil)
        let cancelled = Locked(0)
        let opened = browser.open(url, userCancelled: { cancelled.mutate { $0 += 1 } })
        #expect(opened)
        let wait = Double(ProcessInfo.processInfo.environment["HQN_SHEET_SECONDS"] ?? "60") ?? 60
        try await eventually(within: wait, "a person tapping Cancel") { cancelled.value >= 1 }
        browser.close() // already gone: a no-op
        try await Task.sleep(for: .milliseconds(500))
        #expect(cancelled.value == 1)
    }
}
