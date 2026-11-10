import Foundation
import Testing
@testable import HermesHQNative

// Against the stand-in gateways (docs/spec/05-fixtures-release.md A5, A6), started with the commands in that spec:
//   performance fixture on 127.0.0.1:9711, credentials in build/fixtures/perf.json
//   Nous fixture on 127.0.0.1:9713 (+ fake Portal on 9714), password in build/fixtures/nous.json
// Each suite skips itself when its port is closed. Every sign-in below is a single attempt (never looped).

@Suite(.serialized, .enabled(if: Fixtures.perfAvailable))
struct PerformanceFixtureTests {
    let vault = Fixtures.testVault("perf")

    @Test func passwordSignInListsBotsStreamsAndReconnects() async throws {
        vault.removeAll()
        defer { vault.removeAll() }
        let creds = try #require(Fixtures.credentials("perf.json"))
        let service = SignInService(store: AccountStore(vault: vault))

        // The perf fixture's /api/status lists no providers: show both ways in.
        #expect(await service.probe(creds.url) == .unknown)

        let account = try await service.signInWithPassword(address: creds.url, username: creds.username, password: creds.password)
        #expect(account.kind == .password && account.username == creds.username)
        #expect(account.baseURL.absoluteString == creds.url)
        let saved = try #require(vault.peek())
        #expect(saved.cookies?.isEmpty == false && saved.provider == "fake")

        let client = service.client(for: account)
        try await waitFor(client, .ready)
        let ready = try #require(client.latestReady)
        #expect(ready["heartbeat"]?.bool == true && ready["replay_epoch"]?.string == "build47")

        // profiles.list returns the bots.
        let profiles = try await client.call("profiles.list", [:])
        let names = profiles["profiles"]?.array?.compactMap { $0["name"]?.string } ?? []
        #expect(names.contains("default") && names.contains("ivy"))

        // REST with the session.
        let sessions = try JSONValue.parseFast(try await client.get("/api/sessions", [URLQueryItem(name: "profile", value: "default")]))
        #expect((sessions["sessions"]?.array?.count ?? 0) >= 1)
        #expect(await client.compatibility() == .compatible)

        // A reply streams in as events.
        try await Fixtures.control(Fixtures.perfPort, "/__fixture/plan",
                                   json: ["plans": [["chunks": ["Hel", "lo ", "there."], "chunkDelay": 0.02, "replyDelay": 0.05]]])
        let events = client.events()
        let ack = try await client.call("prompt.submit", ["session_id": "5cc537d1", "text": "hi there", "profile": "default"],
                                        timeout: .seconds(60))
        #expect(ack["status"]?.string == "streaming")
        let turn = try await collect(events, within: 10, "message.complete") { $0.type == "message.complete" }
        #expect(turn.first?.type == "message.start")
        #expect(turn.filter { $0.type == "message.delta" }.compactMap { $0.payload["text"]?.string }.joined() == "Hello there.")
        #expect(turn.last?.payload["text"]?.string == "Hello there.")
        #expect(turn.allSatisfy { $0.sessionId == "5cc537d1" })

        // A dropped socket comes back by itself with a fresh ticket, and says gateway.ready again.
        let again = client.events()
        await client.debugConnection.debugDropSocket()
        _ = try await first(again, within: 10, "gateway.ready after reconnect") { $0.type == "gateway.ready" }
        #expect(client.state == .ready)
        _ = try await client.call("session.list", ["limit": 1])

        // Background past the grace (here: no background time granted) pauses; returning reconnects.
        await client.debugConnection.handle(.enteredBackground(granted: false))
        #expect(client.state == .offline(reason: "paused"))
        #expect(await notSentReason { _ = try await client.call("session.list", [:]) } == .paused)
        client.appDidBecomeActive()
        try await waitFor(client, .ready)

        // The launch path: a new client from the saved cookies verifies with /api/auth/me and connects.
        #expect(await service.restore()?.id == account.id)
        client.shutdown()
        let restored = LiveGatewayClient(stored: try #require(vault.peek()), transport: HTTPTransport(), vault: vault, verified: false)
        try await waitFor(restored, .ready)
        _ = try await restored.call("profiles.list", [:])
        restored.shutdown()
        #expect(await notSentReason { _ = try await restored.call("profiles.list", [:]) } == .connectionChanged)

        // Sign-out empties the saved list.
        #expect(service.signOut() == nil)
        #expect(vault.peek() == nil)
        #expect(await service.restore() == nil)
    }

    @Test func wrongPasswordIsRefusedOnce() async throws {
        vault.removeAll()
        defer { vault.removeAll() }
        let creds = try #require(Fixtures.credentials("perf.json"))
        let service = SignInService(store: AccountStore(vault: vault))
        await #expect(throws: GatewayFailure.authRejected) {
            _ = try await service.signInWithPassword(address: creds.url, username: creds.username, password: creds.password + "x")
        }
        await #expect(throws: GatewayFailure.missingFields) {
            _ = try await service.signInWithPassword(address: creds.url, username: " ", password: "x")
        }
        #expect(vault.peek() == nil)
    }

    @Test func callsTimeOutPerCall() async throws {
        vault.removeAll()
        defer { vault.removeAll() }
        let creds = try #require(Fixtures.credentials("perf.json"))
        let service = SignInService(store: AccountStore(vault: vault))
        let account = try await service.signInWithPassword(address: creds.url, username: creds.username, password: creds.password)
        let client = service.client(for: account)
        defer { client.shutdown() }
        try await waitFor(client, .ready)
        // The fixture never acks a dropAck prompt: the call times out on our side, the socket stays.
        try await Fixtures.control(Fixtures.perfPort, "/__fixture/plan", json: ["plans": [["dropAck": true]]])
        do {
            _ = try await client.call("prompt.submit", ["session_id": "bf611b3e", "text": "never acked"], timeout: .milliseconds(800))
            Issue.record("expected a timeout")
        } catch let error as RPCError {
            #expect(error.isTimeout)
            #expect(error.message == "request timed out after 1s: prompt.submit")
        }
        #expect(client.state == .ready)
        _ = try await client.call("session.interrupt", ["session_id": "bf611b3e"])
    }
}

@Suite(.serialized, .enabled(if: Fixtures.nousAvailable))
struct NousFixtureTests {
    let vault = Fixtures.testVault("nous")
    var address: String { "http://127.0.0.1:\(Fixtures.nousPort)" }

    func signIn(ttl: Int, service: SignInService) async throws -> GatewayAccount {
        try await Fixtures.control(Fixtures.nousPort, "/__fixture/nous/ttl", json: ["access": ttl])
        let browser = FixtureBrowser()
        let relay = LoopbackRelay()
        let account = try await service.signInWithNous(address: address, browser: browser, relay: relay)
        #expect(browser.steps == ["authorize 302", "portal", "callback 302", "loopback 200"])
        #expect(browser.closed)
        #expect(relay.liveListeners == 0)
        return account
    }

    @Test func signInWithNousThroughTheLoopbackRelay() async throws {
        vault.removeAll()
        defer { vault.removeAll() }
        await NousRenewals.shared.reset()
        let service = SignInService(store: AccountStore(vault: vault))
        let probe = await service.probe(address)
        #expect(probe == ProbeResult(known: true, nous: true, password: true))

        let before = try await Fixtures.nousCounts()
        let account = try await signIn(ttl: 30, service: service)
        #expect(account.kind == .nous && account.username == nil)
        #expect(account.id == address + "|nous:user_owner_fixture")
        let saved = try #require(vault.peek())
        let tokens = try #require(saved.nous)
        #expect(tokens.userId == "user_owner_fixture" && tokens.obtainedAt != nil)
        #expect(abs((tokens.lifetime ?? 0) - 30) <= 2)
        #expect(saved.cookies == nil)

        let client = service.client(for: account)
        defer { client.shutdown() }
        try await waitFor(client, .ready)
        let profiles = try await client.call("profiles.list", [:])
        #expect((profiles["profiles"]?.array?.count ?? 0) >= 2)
        _ = try await client.get("/api/sessions") // REST is gated on this fixture: the bearer works.

        // One ticket per socket, each used once; a reconnect mints a new one.
        await client.debugConnection.debugDropSocket()
        try await waitFor(client, .ready)
        let after = try await Fixtures.nousCounts()
        #expect(after["token", default: 0] - before["token", default: 0] == 1)
        #expect(after["ticketsMinted", default: 0] - before["ticketsMinted", default: 0] == 2)
        #expect(after["wsOpened", default: 0] - before["wsOpened", default: 0] == 2)
        #expect(after["ticketsRejected", default: 0] == before["ticketsRejected", default: 0])
        #expect(after["refresh", default: 0] == before["refresh", default: 0]) // 30 s tokens: no renewal yet (D6)
    }

    @Test func concurrentRequestsShareOneProactiveRenewal() async throws {
        vault.removeAll()
        defer { vault.removeAll() }
        await NousRenewals.shared.reset()
        let service = SignInService(store: AccountStore(vault: vault))
        let account = try await signIn(ttl: 4, service: service)
        let client = service.client(for: account)
        defer { client.shutdown() }
        try await waitFor(client, .ready)
        let before = try await Fixtures.nousCounts()
        try await Task.sleep(for: .milliseconds(2300)) // past half of the 4 s lifetime (D6)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = try await client.get("/api/sessions") } }
            try await group.waitForAll()
        }
        let after = try await Fixtures.nousCounts()
        #expect(after["refresh", default: 0] - before["refresh", default: 0] == 1)
        #expect(after["refreshReplayed", default: 0] == before["refreshReplayed", default: 0])
        // The rotated pair was kept in Keychain before use.
        let live = try #require(await client.debugAuth.stored.nous)
        #expect(vault.peek()?.nous?.samePair(live) == true)
    }

    @Test func expiredBearerRefreshesOnceThenRetries() async throws {
        vault.removeAll()
        defer { vault.removeAll() }
        await NousRenewals.shared.reset()
        let service = SignInService(store: AccountStore(vault: vault))
        let account = try await signIn(ttl: 2, service: service)
        service.client(for: account).shutdown()
        // Claim a long life so no proactive renewal runs: the gateway's 401 must drive the refresh.
        var stored = try #require(vault.peek())
        let now = Date().timeIntervalSince1970
        stored.nous?.expiresAt = now + 3600
        stored.nous?.obtainedAt = now
        try vault.save(stored)
        let client = LiveGatewayClient(stored: stored, transport: HTTPTransport(cookies: false), vault: vault, verified: true, watchNetwork: false)
        defer { client.shutdown() }
        try await waitFor(client, .ready)
        try await Task.sleep(for: .milliseconds(2600)) // the access token lapses on the gateway
        let before = try await Fixtures.nousCounts()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 { group.addTask { _ = try await client.get("/api/sessions") } }
            try await group.waitForAll()
        }
        let after = try await Fixtures.nousCounts()
        #expect(after["refresh", default: 0] - before["refresh", default: 0] == 1)
        #expect(after["refreshReplayed", default: 0] == before["refreshReplayed", default: 0])
        #expect(after["bearerRejected", default: 0] > before["bearerRejected", default: 0])
        #expect(client.state == .ready)
    }

    @Test func revokedNousSessionSignsOut() async throws {
        vault.removeAll()
        defer { vault.removeAll() }
        await NousRenewals.shared.reset()
        let service = SignInService(store: AccountStore(vault: vault))
        let account = try await signIn(ttl: 30, service: service)
        let client = service.client(for: account)
        defer { client.shutdown() }
        try await waitFor(client, .ready)
        let states = client.connectionStates()
        try await Fixtures.control(Fixtures.nousPort, "/__fixture/nous/revoke", json: [:])
        await #expect(throws: GatewayFailure.sessionEnded) { _ = try await client.get("/api/sessions") }
        _ = try await first(states, within: 5, "signedOut") { $0 == .signedOut(reason: "session-ended") }
        // The Keychain keeps the address and username only; restore says signed out with a prefill.
        let saved = try #require(vault.peek())
        #expect(saved.nous == nil && saved.username == "nous:user_owner_fixture")
        #expect(await service.restore() == nil)
        #expect(await service.restoreState() == .signedOut(prefill: .init(address: address, username: nil)))
        #expect(await notSentReason { _ = try await client.call("profiles.list", [:]) } == .sessionEnded)
    }

    @Test(.enabled(if: Fixtures.nousPasswordAvailable))
    func passwordCookiesRenewAndPersistThenEnd() async throws {
        vault.removeAll()
        defer { vault.removeAll() }
        let creds = try #require(Fixtures.credentials("nous.json"))
        let service = SignInService(store: AccountStore(vault: vault))
        let account = try await service.signInWithPassword(address: creds.url, username: creds.username, password: creds.password)
        let client = service.client(for: account)
        defer { client.shutdown() }
        try await waitFor(client, .ready)
        let initial = try #require(vault.peek()?.cookies)
        #expect(Set(initial.map(\.name)) == ["hermes_session_at", "hermes_session_rt"])

        // The gateway renews a lapsed access cookie from the refresh cookie on any request; the jar's new cookies
        // reach Keychain.
        try await Fixtures.control(Fixtures.nousPort, "/__fixture/expire-access", json: [:])
        _ = try await client.get("/api/sessions")
        try await Task.sleep(for: .milliseconds(300))
        let renewed = try #require(vault.peek()?.cookies)
        #expect(!SavedCookie.same(initial, renewed))

        // A revoked session ends: /api/auth/me refuses, the Keychain copy is the same, so it is over.
        let states = client.connectionStates()
        try await Fixtures.control(Fixtures.nousPort, "/__fixture/revoke", json: [:])
        await #expect(throws: GatewayFailure.sessionEnded) { _ = try await client.get("/api/sessions") }
        _ = try await first(states, within: 5, "signedOut") { $0 == .signedOut(reason: "session-ended") }
        let after = try #require(vault.peek())
        #expect(after.cookies == nil && after.username == creds.username && after.provider == "fake")
        #expect(await service.restoreState() == .signedOut(prefill: .init(address: creds.url, username: creds.username)))
    }
}

/// Heartbeat, liveness and the background grace with shortened intervals (performance fixture).
@Suite(.serialized, .enabled(if: Fixtures.perfAvailable))
struct ConnectionLifecycleTests {
    let vault = Fixtures.testVault("lifecycle")

    func connect(_ timing: GatewayConnection.Timing) async throws -> LiveGatewayClient {
        vault.removeAll()
        let creds = try #require(Fixtures.credentials("perf.json"))
        let service = SignInService(store: AccountStore(vault: vault))
        let account = try await service.signInWithPassword(address: creds.url, username: creds.username, password: creds.password)
        service.client(for: account).shutdown()
        let stored = try #require(vault.peek())
        let transport = HTTPTransport()
        transport.installCookies(stored.cookies ?? [])
        let client = LiveGatewayClient(stored: stored, transport: transport, vault: vault, verified: true, watchNetwork: false, timing: timing)
        try await waitFor(client, .ready)
        return client
    }

    func methodsSeen() async throws -> [String] {
        let state = try await Fixtures.control(Fixtures.perfPort, "/__fixture/state", method: "GET")
        return state["rpc"]?.array?.compactMap { $0["method"]?.string } ?? []
    }

    @Test func heartbeatPingsAndAdvertisesCapabilities() async throws {
        defer { vault.removeAll() }
        var timing = GatewayConnection.Timing()
        timing.heartbeatInterval = .milliseconds(500)
        let before = try await methodsSeen().filter { $0 == "gateway.ping" }.count
        let client = try await connect(timing)
        defer { client.shutdown() }
        try await Task.sleep(for: .milliseconds(3200))
        let methods = try await methodsSeen()
        #expect(methods.filter { $0 == "gateway.ping" }.count - before >= 2)
        #expect(methods.contains("client.capabilities")) // [questions] spec 1x §2.1 replaces D1
        #expect(client.state == .ready)
    }

    @Test func silenceDropsTheSocketAndItComesBack() async throws {
        defer { vault.removeAll() }
        var timing = GatewayConnection.Timing()
        timing.heartbeatInterval = .seconds(3600) // never ping, so the gateway stays quiet
        timing.heartbeatSilence = .milliseconds(1500)
        let client = try await connect(timing)
        defer { client.shutdown() }
        let epoch = await client.debugConnection.debugSocketEpoch
        let events = client.events()
        _ = try await first(events, within: 8, "gateway.ready after the silent socket was dropped") { $0.type == "gateway.ready" }
        #expect(await client.debugConnection.debugSocketEpoch > epoch)
    }

    @Test func backInsideTheGraceKeepsTheSocket() async throws {
        defer { vault.removeAll() }
        var timing = GatewayConnection.Timing()
        timing.backgroundGrace = 3
        let client = try await connect(timing)
        defer { client.shutdown() }
        let epoch = await client.debugConnection.debugSocketEpoch
        await client.debugConnection.handle(.enteredBackground(granted: true))
        try await Task.sleep(for: .milliseconds(300))
        await client.debugConnection.handle(.becameActive)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await client.debugConnection.debugSocketEpoch == epoch)
        #expect(client.state == .ready)
        #expect(try await methodsSeen().last == "ping") // the wake probe proved the socket
        try await Task.sleep(for: .seconds(3)) // the cancelled grace timer must not fire
        #expect(client.state == .ready)
    }

    @Test func pastTheGraceClosesThenReturnsReconnects() async throws {
        defer { vault.removeAll() }
        var timing = GatewayConnection.Timing()
        timing.backgroundGrace = 0.6
        let client = try await connect(timing)
        defer { client.shutdown() }
        let states = client.connectionStates()
        client.appDidEnterBackground() // the real path: a UIKit background task, then the grace timer
        _ = try await first(states, within: 5, "paused") { $0 == .offline(reason: "paused") }
        #expect(await notSentReason { _ = try await client.call("session.list", [:]) } == .paused)
        let ready = client.events()
        client.appDidBecomeActive()
        _ = try await first(ready, within: 10, "gateway.ready after return") { $0.type == "gateway.ready" }
        _ = try await client.call("session.list", [:])
    }

    /// [talk-background] A conversation holds the socket: leaving the app starts no grace, and the socket still answers.
    @Test func heldThroughTheBackgroundKeepsTheSocket() async throws {
        defer { vault.removeAll() }
        var timing = GatewayConnection.Timing()
        timing.backgroundGrace = 0.6
        let client = try await connect(timing)
        defer { client.shutdown() }
        let epoch = await client.debugConnection.debugSocketEpoch
        await client.debugConnection.handle(.holdOpen)
        await client.debugConnection.handle(.enteredBackground(granted: true))
        try await Task.sleep(for: .seconds(1.5))
        #expect(client.state == .ready)
        #expect(await client.debugConnection.debugSocketEpoch == epoch)
        _ = try await client.call("session.list", [:])
    }

    /// [talk-background] The conversation ended with the app away: the socket gets the grace it would have had.
    @Test func releasingTheHoldAwayStartsTheGrace() async throws {
        defer { vault.removeAll() }
        var timing = GatewayConnection.Timing()
        timing.backgroundGrace = 0.6
        let client = try await connect(timing)
        defer { client.shutdown() }
        let states = client.connectionStates()
        await client.debugConnection.handle(.holdOpen)
        await client.debugConnection.handle(.enteredBackground(granted: true))
        try await Task.sleep(for: .seconds(1))
        #expect(client.state == .ready)
        await client.debugConnection.handle(.releaseHold(granted: true))
        _ = try await first(states, within: 5, "paused") { $0 == .offline(reason: "paused") }
        let ready = client.events()
        await client.debugConnection.handle(.becameActive)
        _ = try await first(ready, within: 10, "gateway.ready after return") { $0.type == "gateway.ready" }
    }

    /// [talk-background] A hold taken after leaving the app (inside the grace) calls the grace off.
    @Test func holdingInsideTheGraceCallsItOff() async throws {
        defer { vault.removeAll() }
        var timing = GatewayConnection.Timing()
        timing.backgroundGrace = 0.6
        let client = try await connect(timing)
        defer { client.shutdown() }
        await client.debugConnection.handle(.enteredBackground(granted: true))
        await client.debugConnection.handle(.holdOpen)
        try await Task.sleep(for: .seconds(1.5))
        #expect(client.state == .ready)
    }

    @Test func lostNetworkWaitsThenRestoredReconnects() async throws {
        defer { vault.removeAll() }
        let client = try await connect(.standard)
        defer { client.shutdown() }
        let states = client.connectionStates()
        await client.debugConnection.handle(.path(.lost))
        _ = try await first(states, within: 5, "offline") { $0 == .offline(reason: "network") }
        let ready = client.events()
        await client.debugConnection.handle(.path(.restored))
        _ = try await first(ready, within: 10, "gateway.ready after the network came back") { $0.type == "gateway.ready" }
        #expect(client.state == .ready)
    }
}

/// No gateway at all (port 1 on loopback refuses at once): a restore stays offline with a reason, keeps the saved
/// session (an unreachable gateway is not a refusal), and calls fail within their wait.
@Suite struct UnreachableGatewayTests {
    @Test func restoreAgainstNothingIsOfflineNotSignedOut() async throws {
        let vault = Fixtures.testVault("unreachable")
        vault.removeAll()
        defer { vault.removeAll() }
        let stored = StoredAccount(url: "http://127.0.0.1:1", username: "fleet",
                                   cookies: [SavedCookie(name: "hermes_session_rt", value: "keep-me", domain: "127.0.0.1")])
        try vault.save(stored)
        let client = LiveGatewayClient(stored: stored, transport: HTTPTransport(), vault: vault, verified: false, watchNetwork: false)
        defer { client.shutdown() }
        // The launch check gets 7 s in all (spec 01 §5.2), even while the control pool waits for a path.
        let started = ContinuousClock.now
        let state = try await first(client.connectionStates(), within: 12, "offline") {
            if case .offline = $0 { return true } else { return false }
        }
        #expect(started.duration(to: .now) < .seconds(9))
        #expect(state == .offline(reason: "unreachable") || state == .offline(reason: "timeout"))
        #expect(client.lastFailure == .unreachable || client.lastFailure == .timeout)
        #expect(vault.peek()?.cookies?.first?.value == "keep-me") // not a refusal: the session stays
        let reason = await notSentReason { _ = try await client.call("profiles.list", [:], timeout: .seconds(1)) }
        #expect(reason == .unreachable || reason == .timeout)
    }

    /// [offline] (review) Before the first ready a Try Again that fails keeps the retry ladder's place: the automatic
    /// wait after it is the rung the ladder was on (3 s here), not the next one up. Three impatient taps must not turn
    /// 3 s into 30 s. The automatic retries themselves still climb (3, then 6 s).
    @Test func aFailedTryAgainDoesNotClimbTheLadder() async throws {
        let vault = Fixtures.testVault("unreachable-ladder")
        vault.removeAll()
        defer { vault.removeAll() }
        let stored = StoredAccount(url: "http://127.0.0.1:1", username: "fleet",
                                   cookies: [SavedCookie(name: "hermes_session_rt", value: "keep-me", domain: "127.0.0.1")])
        try vault.save(stored)
        let client = LiveGatewayClient(stored: stored, transport: HTTPTransport(), vault: vault, verified: false, watchNetwork: false)
        defer { client.shutdown() }
        /// The next wait the connection schedules, in seconds (a due date further than `after`).
        func nextWait(after earlier: Date?) async throws -> TimeInterval {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if let due = client.nextRetry, earlier.map({ due.timeIntervalSince($0) > 0.5 }) ?? true {
                    return due.timeIntervalSinceNow
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("no retry was scheduled within 20 s")
            return -1
        }
        let first = try await nextWait(after: nil)
        #expect(abs(first - 3) < 0.6, "the first automatic wait is 3 s: \(first)")
        var due = client.nextRetry
        for tap in 1...3 {
            try await Task.sleep(for: .milliseconds(300))
            client.reconnectNow()
            let wait = try await nextWait(after: due)
            #expect(abs(wait - 3) < 0.6, "after Try Again number \(tap) the wait is still 3 s: \(wait)")
            due = client.nextRetry
        }
        // Left alone, the retry that fires by itself climbs to the next rung.
        let climbed = try await nextWait(after: due)
        #expect(abs(climbed - 6) < 0.8, "the automatic retry after that waits 6 s: \(climbed)")
    }
}
