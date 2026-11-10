// [connect-fast] The launch/restore dial as the desktop makes it (apps/desktop use-gateway-boot.ts): the ticket is the
// session check, no `/api/auth/me` first; a refused session still signs out (ticket 401 → one refresh → 401/403); an
// address that isn't Hermes fails at the ticket. Plus the tunnel re-check and the chat's quiet "Reconnecting…".
// Against `LoopbackHTTP` (127.0.0.1, an OS-assigned port, this process only): no socket ever opens there.

import Foundation
import Network
import Synchronization
import Testing
@testable import HermesHQNative

@Suite("Connect fast: the restore dial", .serialized)
struct ConnectFastDialTests {
    private func restored(_ port: UInt16, _ name: String) -> (LiveGatewayClient, AccountVault) {
        let vault = Fixtures.testVault(name)
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: "tester")
        let client = LiveGatewayClient(stored: stored, transport: HTTPTransport(), vault: vault, verified: false, watchNetwork: false)
        return (client, vault)
    }

    @Test func aRestoreAsksForATicketFirstAndNeverForAuthMe() async throws {
        let server = try LoopbackHTTP { request in
            switch (request.method, request.path) {
            case ("POST", "/api/auth/ws-ticket"): return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            case ("GET", "/api/auth/me"): return (200, Data(#"{"user":"tester"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (client, vault) = restored(port, "connect-fast-ticket")
        defer { client.shutdown(); vault.removeAll() }
        // The loopback server speaks no websocket: the upgrade fails after the ticket, which is all this needs.
        for _ in 0..<50 where !server.requests.contains(where: { $0.path == "/api/ws" }) { try await Task.sleep(for: .milliseconds(100)) }
        let paths = server.requests.map { "\($0.method) \($0.path)" }
        #expect(paths.first == "POST /api/auth/ws-ticket")
        #expect(!paths.contains("GET /api/auth/me"))
        #expect(paths.contains("GET /api/ws"))
    }

    @Test(arguments: [401, 403])
    func aRefusedTicketStillSignsOut(status: Int) async throws {
        let server = try LoopbackHTTP { request in
            switch (request.method, request.path) {
            case ("POST", "/api/auth/ws-ticket"): return (status, Data(#"{"detail":"Not authenticated"}"#.utf8))
            case ("GET", "/api/auth/me"): return (401, Data(#"{"detail":"Not authenticated"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (client, vault) = restored(port, "connect-fast-refused-\(status)")
        defer { client.shutdown(); vault.removeAll() }
        try await waitFor(client, .signedOut(reason: GatewayFailure.sessionEnded.code), within: 10)
        let paths = server.requests.map { "\($0.method) \($0.path)" }
        #expect(paths.first == "POST /api/auth/ws-ticket")
        // 401: one refresh (a password session asks /api/auth/me once), never a second ticket. 403: no refresh.
        #expect(paths.filter { $0 == "POST /api/auth/ws-ticket" }.count == 1)
        #expect(paths.filter { $0 == "GET /api/auth/me" }.count == (status == 401 ? 1 : 0))
    }

    @Test func anAddressThatIsNotHermesFailsAtTheTicket() async throws {
        let server = try LoopbackHTTP { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"): return (200, Data("<!doctype html><p>It works.</p>".utf8))
            default: return (404, Data("<!doctype html><p>Not Found</p>".utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (client, vault) = restored(port, "connect-fast-not-hermes")
        defer { client.shutdown(); vault.removeAll() }
        try await waitFor(client, .offline(reason: GatewayFailure.notHermes.code), within: 10)
        #expect(server.requests.map { "\($0.method) \($0.path)" }.prefix(2) == ["POST /api/auth/ws-ticket", "GET /api/status"])
    }

    @Test func aHermesFromBeforeGatewaySignInReadsOutdated() async throws {
        let server = try LoopbackHTTP { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"): return (200, Data(#"{"version":"0.9.0"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (client, vault) = restored(port, "connect-fast-outdated")
        defer { client.shutdown(); vault.removeAll() }
        try await waitFor(client, .offline(reason: GatewayFailure.gatewayOutdated.code), within: 10)
    }
}

@Suite("Connect fast: the tunnel re-check")
struct ConnectFastTunnelTests {
    @Test func upAtOnceAsksOnce() async {
        let asks = Mutex(0)
        #expect(await tunnelComesUp { asks.withLock { $0 += 1 }; return true })
        #expect(asks.withLock { $0 } == 1)
    }

    @Test func aTunnelThatComesUpAfterABeatIsUp() async {
        let asks = Mutex(0)
        let started = ContinuousClock.now
        let up = await tunnelComesUp(within: .seconds(3), every: .milliseconds(50)) { asks.withLock { $0 += 1; return $0 >= 4 } }
        #expect(up)
        #expect(asks.withLock { $0 } == 4)
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test func aTunnelThatStaysOffIsOffAfterTheWait() async {
        let asks = Mutex(0)
        let started = ContinuousClock.now
        let up = await tunnelComesUp(within: .milliseconds(600), every: .milliseconds(100)) { asks.withLock { $0 += 1 }; return false }
        let took = started.duration(to: .now)
        #expect(!up)
        #expect(took >= .milliseconds(600) && took < .seconds(2))
        #expect((5...8).contains(asks.withLock { $0 }))   // the first ask, then one every 100 ms
    }

    @Test func theStandardWaitIsThreeSecondsAskingEvery300ms() {
        #expect(GatewayConnection.Timing.standard.tunnelWait == .seconds(3))
        #expect(GatewayConnection.Timing.standard.backgroundGrace == 25)
    }
}

@Suite("Connect fast: the chat's quiet reconnect")
struct ConnectFastQuietTests {
    @Test func reconnectingWordsWaitTwoSeconds() {
        var gate = ReconnectWordsGate()
        let start = Date(timeIntervalSince1970: 1_000)
        let first = gate.note(reconnecting: true, now: start)
        #expect(!first.show && first.recheckIn == 2)
        let mid = gate.note(reconnecting: true, now: start + 1.5)
        #expect(!mid.show && abs((mid.recheckIn ?? 0) - 0.5) < 0.001)
        #expect(gate.note(reconnecting: true, now: start + 2).show)
        #expect(gate.note(reconnecting: true, now: start + 30).show)
    }

    @Test func aQuickReconnectShowsNothingAndTheNextOneWaitsAgain() {
        var gate = ReconnectWordsGate()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(!gate.note(reconnecting: true, now: start).show)
        let back = gate.note(reconnecting: false, now: start + 0.8)          // ready inside the wait: never shown
        #expect(!back.show && back.recheckIn == nil && gate.since == nil)
        let again = gate.note(reconnecting: true, now: start + 10)
        #expect(!again.show && again.recheckIn == 2)                         // a new run waits its own 2 s
    }
}

// MARK: - [net-ready] One quick redial while the network settles (spec 01 §13.4, build 295)

@Suite("Connect fast: net-ready quick redial rule")
struct NetSettleRuleTests {
    private let t0 = ContinuousClock.now

    private func settled(at moment: Duration = .zero) -> NetSettle {
        var settle = NetSettle()
        settle.settling(at: t0 + moment)
        return settle
    }

    @Test func aFastUnreachableJustAfterActivationGetsTheShortFloorOnce() {
        var settle = settled()
        let quick = settle.quickRedial(after: .unreachable, began: t0 + .milliseconds(5), now: t0 + .milliseconds(93))
        #expect(quick == NetSettle.floor)
        #expect(NetSettle.floor < .seconds(ReconnectBackoff.minRedialSeconds))
        // The second failure (the quick redial's own) takes the normal floor and ladder.
        #expect(settle.quickRedial(after: .unreachable, began: t0 + .milliseconds(300), now: t0 + .milliseconds(350)) == nil)
    }

    @Test(arguments: [GatewayFailure.timeout, .unavailable, .rateLimited, .gatewayError("HTTP 500"), .tls,
                      .tailscaleOff, .sessionEnded, .notHermes, .socketDead])
    func everyOtherFailureKeepsTheFloor(failure: GatewayFailure) {
        var settle = settled()
        #expect(settle.quickRedial(after: failure, began: t0, now: t0 + .milliseconds(80)) == nil)
        #expect(!settle.spent)        // not spent: an unreachable after it may still get one
    }

    @Test func aSlowUnreachableOrALateDialKeepsTheFloor() {
        var slow = settled()
        #expect(slow.quickRedial(after: .unreachable, began: t0, now: t0 + .milliseconds(1200)) == nil)
        var late = settled()
        #expect(late.quickRedial(after: .unreachable, began: t0 + .seconds(4), now: t0 + .milliseconds(4050)) == nil)
        var never = NetSettle()        // no activation, start or path change seen
        #expect(never.quickRedial(after: .unreachable, began: t0, now: t0 + .milliseconds(50)) == nil)
    }

    @Test func aNewActivationOrPathChangeGivesOneMore() {
        var settle = settled()
        #expect(settle.quickRedial(after: .unreachable, began: t0, now: t0 + .milliseconds(60)) != nil)
        #expect(settle.quickRedial(after: .unreachable, began: t0 + .milliseconds(300), now: t0 + .milliseconds(360)) == nil)
        settle.settling(at: t0 + .seconds(10))
        #expect(settle.quickRedial(after: .unreachable, began: t0 + .seconds(10), now: t0 + .milliseconds(10_070)) != nil)
    }

    @Test func theRuleIsOneExtraAskInThreeSecondsAtMost() {
        #expect(NetSettle.floor == .milliseconds(200))
        #expect(NetSettle.window == .seconds(3))
        #expect(NetSettle.failedWithin == .seconds(1))
    }
}

/// Every TCP connection a dial opens, timed; each is dropped at once (the ticket request then fails "unreachable"
/// within milliseconds, as on a phone whose radio is not carrying yet) or answered with `status`.
/// 127.0.0.1, an OS-assigned port, this process only.
nonisolated final class DialLedger: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "hqn.tests.dial-ledger")
    private let times = Mutex<[ContinuousClock.Instant]>([])
    private let status: Int?

    /// `status` nil: drop every connection; else answer every request with it.
    init(status: Int? = nil) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.status = status
    }

    var dials: [ContinuousClock.Instant] { times.withLock { $0 } }

    func start() async throws -> UInt16 {
        let once = Mutex(false)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [listener] state in
                let first = once.withLock { done -> Bool in
                    guard !done else { return false }
                    switch state { case .ready, .failed, .cancelled: done = true; return true; default: return false }
                }
                guard first else { return }
                switch state {
                case .ready: continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): continuation.resume(throwing: error)
                default: continuation.resume(throwing: CancellationError())
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        times.withLock { $0.append(.now) }
        connection.start(queue: queue)
        guard let status else { return connection.cancel() }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { _, _, _, _ in
            let body = Data(#"{"detail":"down"}"#.utf8)
            let head = "HTTP/1.1 \(status) Error\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@Suite("Connect fast: net-ready quick redial", .serialized)
struct NetReadyRedialTests {
    private func restored(_ port: UInt16, _ name: String) -> (LiveGatewayClient, AccountVault) {
        let vault = Fixtures.testVault(name)
        vault.removeAll()
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: "tester",
                                   cookies: [SavedCookie(name: "hermes_session_rt", value: "keep-me", domain: "127.0.0.1")])
        let client = LiveGatewayClient(stored: stored, transport: HTTPTransport(), vault: vault, verified: false, watchNetwork: false)
        return (client, vault)
    }

    private func dials(_ ledger: DialLedger, atLeast count: Int, within seconds: Double) async throws -> [ContinuousClock.Instant] {
        try await eventually(within: seconds, "\(count) dials") { ledger.dials.count >= count }
        return ledger.dials
    }

    private func ms(_ d: Duration) -> Int { ConnectSteps.ms(d) }

    /// The phone's case: the first dial fails "unreachable" in milliseconds; the second follows after ~200 ms, not
    /// after the 1 s floor (and before the first ready, not after the ladder's 3 s); a second failure is the ladder's.
    @Test func aFastUnreachableAtStartRedialsWithoutTheOneSecondFloor() async throws {
        let ledger = try DialLedger()
        let port = try await ledger.start()
        defer { ledger.stop() }
        let (client, vault) = restored(port, "net-ready-start")
        defer { client.shutdown(); vault.removeAll() }
        let seen = try await dials(ledger, atLeast: 2, within: 5)
        let gap = seen[0].duration(to: seen[1])
        #expect(gap >= .milliseconds(150) && gap < .milliseconds(700), "quick redial after \(ms(gap)) ms")
        #expect(client.state == .connecting || client.lastFailure == .unreachable)
        // The quick one failed too: the ladder's first rung (3 s, shown as the offline screen's countdown).
        try await waitFor(client, .offline(reason: GatewayFailure.unreachable.code), within: 5)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(ledger.dials.count == 2, "no third dial inside the 3 s rung: \(ledger.dials.count)")
        let third = try await dials(ledger, atLeast: 3, within: 6)
        let rung = seen[1].duration(to: third[2])
        #expect(rung >= .milliseconds(2500), "the second failure waits the ladder: \(ms(rung)) ms")
    }

    /// A return to the app is a new moment: one more quick redial, then the ladder again (never a storm).
    @Test func aReturnToTheAppGivesOneMoreQuickRedial() async throws {
        let ledger = try DialLedger()
        let port = try await ledger.start()
        defer { ledger.stop() }
        let (client, vault) = restored(port, "net-ready-return")
        defer { client.shutdown(); vault.removeAll() }
        _ = try await dials(ledger, atLeast: 2, within: 5)
        try await Task.sleep(for: .milliseconds(1200))          // past the 1 s floor, inside the 3 s rung
        #expect(ledger.dials.count == 2)
        client.appDidBecomeActive()
        let seen = try await dials(ledger, atLeast: 4, within: 3)
        let gap = seen[2].duration(to: seen[3])
        #expect(gap >= .milliseconds(150) && gap < .milliseconds(700), "quick redial after the return: \(ms(gap)) ms")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(ledger.dials.count == 4, "then the ladder, no fifth dial yet: \(ledger.dials.count)")
    }

    /// A gateway that answers 503 gets no quick redial: the wait is the ladder's (and never under the 1 s floor).
    @Test func aDownGatewaysAnswerKeepsTheFloorAndTheLadder() async throws {
        let ledger = try DialLedger(status: 503)
        let port = try await ledger.start()
        defer { ledger.stop() }
        let (client, vault) = restored(port, "net-ready-503")
        defer { client.shutdown(); vault.removeAll() }
        try await waitFor(client, .offline(reason: GatewayFailure.unavailable.code), within: 5)
        let first = ledger.dials.count
        try await Task.sleep(for: .milliseconds(1500))
        #expect(ledger.dials.count == first, "no quick redial after a 503: \(first) → \(ledger.dials.count)")
    }

    /// No network: the quick redial does not dial; the state says offline as before.
    @Test func noNetworkPathStaysOffline() async throws {
        let ledger = try DialLedger()
        let port = try await ledger.start()
        defer { ledger.stop() }
        let (client, vault) = restored(port, "net-ready-offline")
        defer { client.shutdown(); vault.removeAll() }
        _ = try await dials(ledger, atLeast: 1, within: 5)
        await client.debugConnection.handle(.path(.lost))
        #expect(client.state == .offline(reason: GatewayFailure.offline.code))
        let count = ledger.dials.count
        try await Task.sleep(for: .milliseconds(1200))
        #expect(ledger.dials.count == count, "no dial without a path")
        #expect(client.state == .offline(reason: GatewayFailure.offline.code))
    }
}

/// [frozen-dial] iOS launched the app in the background and froze it with the ticket request out (owner's phone,
/// 2026-10-17): coming forward drops a dial older than any of its steps allows and dials again at once, instead of
/// waiting for the frozen request to time out.
@Suite("Connect fast: a frozen dial", .serialized)
struct FrozenDialTests {
    /// The first ticket request is held 30 s (the frozen one); every later one is answered at once.
    private func server() throws -> LoopbackHTTP {
        let tickets = Mutex(0)
        return try LoopbackHTTP(delay: { request in
            guard request.path == "/api/auth/ws-ticket" else { return 0 }
            return tickets.withLock { n in n += 1; return n == 1 ? 30 : 0 }
        }) { request in
            switch (request.method, request.path) {
            case ("POST", "/api/auth/ws-ticket"): return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
    }

    private func restored(_ port: UInt16, _ name: String) -> (LiveGatewayClient, AccountVault) {
        let vault = Fixtures.testVault(name)
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: "tester")
        var timing = GatewayConnection.Timing()
        timing.frozenDial = .milliseconds(600)
        let client = LiveGatewayClient(stored: stored, transport: HTTPTransport(), vault: vault, verified: false,
                                       watchNetwork: false, timing: timing)
        return (client, vault)
    }

    nonisolated private static func tickets(_ server: LoopbackHTTP) -> Int { server.requests.filter { $0.path == "/api/auth/ws-ticket" }.count }

    @Test func comingForwardDropsAFrozenDialAndDialsAgain() async throws {
        let server = try server()
        let port = try await server.start()
        defer { server.stop() }
        let (client, vault) = restored(port, "frozen-dial-drop")
        defer { client.shutdown(); vault.removeAll() }
        try await eventually(within: 5, "the first ticket request") { Self.tickets(server) == 1 }
        try await Task.sleep(for: .milliseconds(900))     // past `frozenDial`
        let forward = ContinuousClock.now
        client.appDidBecomeActive()
        try await eventually(within: 3, "a second ticket request") { Self.tickets(server) >= 2 }
        #expect(forward.duration(to: .now) < .seconds(2), "dialed again at once, not after the frozen request's 8 s")
        try await eventually(within: 3, "the socket upgrade") { server.requests.contains { $0.path == "/api/ws" } }
    }

    /// The frozen request's deadline can fire on the thaw before the return drops the dial: a dial that fails after
    /// running past `frozenDial` ends quietly too (no timeout failure, no reconnecting wait) and dials again at once.
    @Test func aFrozenDialThatTimesOutFirstDialsAgainQuietly() async throws {
        let server = try server()
        let port = try await server.start()
        defer { server.stop() }
        let (client, vault) = restored(port, "frozen-dial-timeout")
        defer { client.shutdown(); vault.removeAll() }
        try await eventually(within: 5, "the first ticket request") { Self.tickets(server) == 1 }
        try await eventually(within: 12, "a second ticket request after the held one's 8 s") { Self.tickets(server) >= 2 }
        #expect(client.lastFailure != .timeout)
        try await eventually(within: 3, "the socket upgrade") { server.requests.contains { $0.path == "/api/ws" } }
    }

    /// [stale-dial] A replaced path abandons the dial on the old one: the next ticket goes at once, not after the held
    /// request's 8 s timeout, and nothing is counted as a failure.
    @Test func pathReplacedAbandonsTheDialInFlight() async throws {
        let server = try server()
        let port = try await server.start()
        defer { server.stop() }
        let (client, vault) = restored(port, "stale-dial-replaced")
        defer { client.shutdown(); vault.removeAll() }
        try await eventually(within: 5, "the first ticket request") { Self.tickets(server) == 1 }
        let moved = ContinuousClock.now
        await client.debugConnection.handle(.path(.replaced))
        try await eventually(within: 3, "a second ticket request") { Self.tickets(server) >= 2 }
        #expect(moved.duration(to: .now) < .seconds(2), "dialed again at once, not after the held request's 8 s")
        try await eventually(within: 3, "the socket upgrade") { server.requests.contains { $0.path == "/api/ws" } }
        #expect(client.lastFailure != .timeout)
    }

    @Test func pathLostThenRestoredDialsAtOnce() async throws {
        let server = try server()
        let port = try await server.start()
        defer { server.stop() }
        let (client, vault) = restored(port, "stale-dial-lost")
        defer { client.shutdown(); vault.removeAll() }
        try await eventually(within: 5, "the first ticket request") { Self.tickets(server) == 1 }
        await client.debugConnection.handle(.path(.lost))
        let back = ContinuousClock.now
        await client.debugConnection.handle(.path(.restored))
        try await eventually(within: 3, "a second ticket request") { Self.tickets(server) >= 2 }
        #expect(back.duration(to: .now) < .seconds(2), "dialed again at once, not after the held request's 8 s")
    }

    @Test func backgroundCloseAbandonsTheDial() async throws {
        let server = try server()
        let port = try await server.start()
        defer { server.stop() }
        let (client, vault) = restored(port, "stale-dial-background")
        defer { client.shutdown(); vault.removeAll() }
        try await eventually(within: 5, "the first ticket request") { Self.tickets(server) == 1 }
        await client.debugConnection.handle(.enteredBackground(granted: false))   // closes at once
        try await eventually(within: 3, "paused") { client.state == .offline(reason: GatewayFailure.paused.code) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.tickets(server) == 1, "no dial while closed for the background")
        let forward = ContinuousClock.now
        client.appDidBecomeActive()
        try await eventually(within: 3, "a second ticket request") { Self.tickets(server) >= 2 }
        #expect(forward.duration(to: .now) < .seconds(2), "the return dialed at once")
    }

    @Test func aYoungDialIsLeftToFinish() async throws {
        let server = try server()
        let port = try await server.start()
        defer { server.stop() }
        let (client, vault) = restored(port, "frozen-dial-young")
        defer { client.shutdown(); vault.removeAll() }
        try await eventually(within: 5, "the first ticket request") { Self.tickets(server) == 1 }
        client.appDidBecomeActive()                        // well inside `frozenDial`
        try await Task.sleep(for: .milliseconds(1500))
        #expect(Self.tickets(server) == 1, "one dial at a time; a young one is not dropped")
    }
}

/// [ticket-deadline] The ticket step's rung is its whole budget, a Nous renewal it waits on included (the renewal used
/// to add up to 15 s on top). 8 s rung + 1 s slack, against a renewal held 30 s.
@Suite("Connect fast: the ticket step's deadline", .serialized)
struct TicketDeadlineTests {
    @Test func aRenewalThatHangsCannotHoldTheTicketPastItsRung() async throws {
        let server = try LoopbackHTTP(delay: { $0.path == "/auth/native/refresh" ? 30 : 0 }) { request in
            switch request.path {
            case "/api/auth/ws-ticket": return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let now = Date().timeIntervalSince1970
        // In its last minute: the ticket waits for the renewal.
        let tokens = NousTokens(accessToken: "at-old", refreshToken: "rt-old", expiresAt: now + 30, userId: "u1", obtainedAt: now - 870)
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: StoredAccount.nousUsername(userId: "u1"), nous: tokens)
        let vault = Fixtures.testVault("ticket-deadline")
        vault.removeAll()
        try vault.save(stored)
        let began = ContinuousClock.now
        let client = LiveGatewayClient(stored: stored, transport: HTTPTransport(), vault: vault, verified: true, watchNetwork: false)
        defer { client.shutdown(); vault.removeAll() }
        try await eventually(within: 15, "the ticket step's timeout") { client.lastFailure == .timeout }
        let took = began.duration(to: .now)
        #expect(took < .milliseconds(10_500), "the ticket step took \(ConnectSteps.ms(took)) ms")
        #expect(!server.requests.contains { $0.path == "/api/auth/ws-ticket" }, "the ticket never went out")
    }
}

/// Answers the first request and keeps its connection alive, then resets every connection a request comes on: the
/// pooled connection died while the app was away, and the radio isn't carrying yet (URLSession sends a request that
/// lost a pooled connection again on a fresh one first on some systems; that fails too). 127.0.0.1, this process only.
nonisolated final class StalePoolServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "hqn.tests.stale-pool")
    private let opened = Mutex(0)
    private var answered = false     // on `queue`

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    var connections: Int { opened.withLock { $0 } }

    func start() async throws -> UInt16 {
        let once = Mutex(false)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [listener] state in
                let first = once.withLock { done -> Bool in
                    guard !done else { return false }
                    switch state { case .ready, .failed, .cancelled: done = true; return true; default: return false }
                }
                guard first else { return }
                switch state {
                case .ready: continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): continuation.resume(throwing: error)
                default: continuation.resume(throwing: CancellationError())
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        opened.withLock { $0 += 1 }
        connection.start(queue: queue)
        read(connection)
    }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self, let data, error == nil, !done else { return connection.cancel() }
            // A request starts with its method; anything else is the rest of the last one (its body).
            guard ["GET ", "POST "].contains(where: { data.starts(with: Data($0.utf8)) }) else { return self.read(connection) }
            guard !self.answered else { return connection.forceCancel() }   // a reset, as a dead tunnel answers
            self.answered = true
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\n"
            connection.send(content: Data((head + "{}").utf8), completion: .contentProcessed { _ in self.read(connection) })
        }
    }
}

@Suite("Connect fast: a stale pooled connection", .serialized)
struct StalePoolTests {
    private func post(_ port: UInt16, _ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        return request
    }

    /// The ticket's retry at once is for this: a kept-alive connection that died answers -1005, marked as pooled.
    @Test func aLostPooledConnectionSaysItWasReused() async throws {
        let server = try StalePoolServer()
        let port = try await server.start()
        defer { server.stop() }
        let transport = HTTPTransport()
        defer { transport.invalidate() }
        _ = try await transport.data(for: post(port, "/first"), pool: .bulk, ceiling: 1 << 16)
        do {
            _ = try await transport.data(for: post(port, "/second"), pool: .bulk, ceiling: 1 << 16)
            Issue.record("the second request on the kept-alive connection was answered")
        } catch let lost as URLError {
            #expect(lost.code == .networkConnectionLost, "\(lost.code.rawValue)")
            #expect(lost.onReusedConnection)
        }
        #expect(server.connections <= 2, "the pooled one, and at most URLSession's own second try")
    }

    /// A fresh connection the gateway drops at once is its answer: not marked, so the ticket goes to the redial rules.
    @Test func aFreshConnectionDroppedAtOnceIsNotMarked() async throws {
        let ledger = try DialLedger()
        let port = try await ledger.start()
        defer { ledger.stop() }
        let transport = HTTPTransport()
        defer { transport.invalidate() }
        do {
            _ = try await transport.data(for: post(port, "/api/auth/ws-ticket"), pool: .bulk, ceiling: 1 << 16)
            Issue.record("a dropped connection was answered")
        } catch let lost as URLError {
            #expect(lost.code == .networkConnectionLost, "\(lost.code.rawValue)")
            #expect(!lost.onReusedConnection)
        }
        #expect(ledger.dials.count == 1)
    }
}
