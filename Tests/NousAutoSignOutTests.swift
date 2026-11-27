// Regression tests for Nous cloud gateways getting auto signed out:
// - Stale AccountStore tokens walked past the former 16-hop cap in NousRenewals.latest, replaying a spent refresh token
//   and triggering Portal reuse detection on parked gateways probed every 3 minutes.
// - Stale probes failing to adopt another process's Keychain rotation after an in-process rotation.
// - Multiple unsaved rotations while locked overwriting the original Keychain CAS baseline.
// - 503 refresh_pending stranding a rotated pair when a probe closes or the app goes idle.
// - Launch restore budget cutting off /auth/native/refresh mid-flight.
// - Transfer 401s from a proxy/Cloudflare wall triggering unnecessary refreshes.
// - Idle parked Nous gateways (or backgrounded apps) letting 24 h rotating refresh tokens expire.
// - Portal OAuth / MCP proxy walls wiping PortalKeychain, and PortalLogin missing a background-time hold.
// - Share extension abandoning 503 refresh_pending rotations.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@Suite("Nous auto sign-out regressions", .serialized)
nonisolated struct NousAutoSignOutTests {
    static let refreshPath = "/auth/native/refresh"
    static let sessionPath = "/api/sessions/s1"
    static let mePath = "/api/auth/me"

    static func tokenPair(_ n: Int, expiresIn: Double = 900, obtainedAgo: Double = 0, user: String = "u1") -> NousTokens {
        let now = Date().timeIntervalSince1970
        return NousTokens(accessToken: "at-\(n)", refreshToken: "rt-\(n)", expiresAt: now + expiresIn, userId: user,
                          obtainedAt: now - obtainedAgo)
    }

    static func refreshPayload(_ n: Int, expiresIn: Double = 900, user: String = "u1") -> Data {
        let now = Date().timeIntervalSince1970
        return try! JSONSerialization.data(withJSONObject: [
            "access_token": "at-\(n)", "refresh_token": "rt-\(n)", "user_id": user,
            "provider": "nous", "expires_at": now + expiresIn,
        ])
    }

    /// Strict reuse-detection server: any refresh token sent twice revokes the entire session permanently.
    /// Twenty-five sequential probes, every one built from the stale launch-time pair (`rt-0`), must walk past the
    /// former 16-hop limit without ever replaying a spent token, and a 26th probe against a fresh successor must not
    /// refresh at all.
    @Test func longRotationChainPastSixteenNeverReplaysSpentToken() async throws {
        struct ServerState {
            var current = 0
            var expiredStep = 0
            var spent: Set<String> = []
            var revoked = false
            var postedTokens: [String] = []
        }
        let state = Mutex(ServerState())
        let server = try LoopbackHTTP { request in
            switch request.path {
            case Self.refreshPath:
                let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
                let rt = json?["refresh_token"] as? String ?? ""
                return state.withLock { s in
                    s.postedTokens.append(rt)
                    if s.revoked || s.spent.contains(rt) || rt != "rt-\(s.current)" {
                        s.revoked = true
                        return (401, Data(#"{"error":"session_expired","detail":"Refresh token reused or invalid."}"#.utf8))
                    }
                    s.spent.insert(rt)
                    s.current += 1
                    return (200, Self.refreshPayload(s.current, expiresIn: 900))
                }
            case Self.sessionPath:
                let auth = request.authorization ?? ""
                return state.withLock { s in
                    // Simulate access-token expiry before each of the 25 rotations so every probe rotates the refresh
                    // token once; once `current == 25`, the access token stays valid.
                    if auth == "Bearer at-\(s.current)", s.current == s.expiredStep, s.current < 25 {
                        return (401, Data(#"{"error":"session_expired","detail":"Access token expired"}"#.utf8))
                    }
                    guard auth == "Bearer at-\(s.current)" else {
                        return (401, Data(#"{"error":"session_expired","detail":"Unauthorized"}"#.utf8))
                    }
                    return (200, Data(#"{"id":"s1","last_active":100,"message_count":2}"#.utf8))
                }
            default:
                return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }

        let vault = Fixtures.testVault("nous-chain-25")
        vault.removeAll()
        defer { vault.removeAll() }
        // Launch-time snapshot: never updated in the caller (mirroring AccountStore.stored).
        let launchStored = StoredAccount(url: "http://127.0.0.1:\(port)", username: StoredAccount.nousUsername(userId: "u1"),
                                         nous: Self.tokenPair(0, expiresIn: 900, obtainedAgo: 0))
        try vault.save(launchStored)
        let renewals = NousRenewals(hold: { _ in { } })

        for step in 1...25 {
            state.withLock { $0.expiredStep = step - 1 }
            let probe = AccountProbe(stored: launchStored, vault: vault, renewals: renewals)
            let answer = try await probe.session(id: "s1", profile: nil)
            probe.close()
            guard case .session = answer else {
                Issue.record("probe #\(step) failed with \(answer)")
                return
            }
            #expect(vault.peek()?.nous?.refreshToken == "rt-\(step)", "vault missed rotation #\(step)")
        }

        // Rotation 25 issued a fresh 900 s pair: another probe built from stale `launchStored` must adopt `rt-25`
        // in memory and read the session without posting `/auth/native/refresh` again.
        let freshProbe = AccountProbe(stored: launchStored, vault: vault, renewals: renewals)
        let answer = try await freshProbe.session(id: "s1", profile: nil)
        freshProbe.close()
        guard case .session = answer else { Issue.record("fresh probe failed: \(answer)"); return }

        let snapshot = state.withLock { $0 }
        #expect(!snapshot.revoked, "a spent refresh token was replayed and revoked the session")
        #expect(snapshot.postedTokens == (0..<25).map { "rt-\($0)" })
        #expect(vault.peek()?.nous?.refreshToken == "rt-25")
    }

    /// A stale probe holding `rt-0` after this process rotated `rt-0 -> rt-1` and another process (Share extension)
    /// then rotated `rt-1 -> rt-2` in Keychain must adopt `rt-2` instead of replaying `rt-1`.
    @Test func staleProbeAdoptsExternalRotationAfterInProcessRotation() async throws {
        let server = try LoopbackHTTP { request in
            switch request.path {
            case Self.refreshPath:
                let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
                let rt = json?["refresh_token"] as? String ?? ""
                if rt == "rt-0" {
                    // Return an expired pair so the next probe would want to renew if it didn't see Keychain's rt-2.
                    return (200, Self.refreshPayload(1, expiresIn: -10))
                }
                return (401, Data(#"{"error":"session_expired","detail":"Replayed rt-1"}"#.utf8))
            case Self.sessionPath:
                if request.authorization == "Bearer at-2" {
                    return (200, Data(#"{"id":"s1","last_active":200,"message_count":3}"#.utf8))
                }
                return (401, Data(#"{"error":"session_expired","detail":"Unauthorized"}"#.utf8))
            default:
                return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }

        let vault = Fixtures.testVault("nous-external-after-inproc")
        vault.removeAll()
        defer { vault.removeAll() }
        let launchStored = StoredAccount(url: "http://127.0.0.1:\(port)", username: StoredAccount.nousUsername(userId: "u1"),
                                         nous: Self.tokenPair(0, expiresIn: -10, obtainedAgo: 910))
        try vault.save(launchStored)
        let renewals = NousRenewals(hold: { _ in { } })

        // First rotation in-process: rt-0 -> rt-1 (saved to Keychain).
        let first = await renewals.renew(launchStored.key, launchStored.nous!,
                                         post: { _ in .tokens(Self.tokenPair(1, expiresIn: -10, obtainedAgo: 910)) },
                                         keep: { sent, renewed in vault.renewNous(launchStored.key, sent: sent, renewed: renewed) })
        guard case .tokens = first else { Issue.record("first rotation failed"); return }
        #expect(vault.peek()?.nous?.refreshToken == "rt-1")

        // Another process (Share extension) rotates rt-1 -> rt-2 in Keychain (fresh).
        let external = Self.tokenPair(2, expiresIn: 900, obtainedAgo: 0)
        #expect(vault.renewNous(launchStored.key, sent: Self.tokenPair(1), renewed: external))

        // A probe created from the stale launch snapshot (`rt-0`) must advance to `rt-1`, see `rt-2` in Keychain,
        // adopt `rt-2`, and never post `rt-0` or `rt-1` to `/auth/native/refresh`.
        let probe = AccountProbe(stored: launchStored, vault: vault, renewals: renewals)
        let answer = try await probe.session(id: "s1", profile: nil)
        probe.close()
        guard case .session = answer else { Issue.record("expected adopted session, got \(answer)"); return }
        #expect(server.requests.filter { $0.path == Self.refreshPath }.isEmpty, "replayed a spent token instead of adopting Keychain's pair")
        #expect(vault.peek()?.nous?.refreshToken == "rt-2")
    }

    /// Two rotations while Keychain refuses writes must preserve the original Keychain pair (`rt-0`) as the CAS
    /// baseline so unlocking writes `rt-2` straight over `rt-0` instead of failing CAS against `rt-1`.
    @Test func multipleUnsavedRotationsPreserveOriginalVaultBaseline() async throws {
        let vault = Fixtures.testVault("nous-unsaved-chain")
        vault.removeAll()
        defer { vault.removeAll() }
        let p0 = Self.tokenPair(0, expiresIn: -10, obtainedAgo: 910)
        let p1 = Self.tokenPair(1, expiresIn: -10, obtainedAgo: 910)
        let p2 = Self.tokenPair(2, expiresIn: 900, obtainedAgo: 0)
        let stored = StoredAccount(url: "https://cloud.example.com", username: StoredAccount.nousUsername(userId: "u1"), nous: p0)
        try vault.save(stored)

        let canWrite = Locked(false)
        let renewals = NousRenewals(hold: { _ in { } })
        let keep: NousRenewals.Keep = { sent, renewed in
            guard canWrite.value else { return false }
            return vault.renewNous(stored.key, sent: sent, renewed: renewed)
        }

        _ = await renewals.renew(stored.key, p0, post: { _ in .tokens(p1) }, keep: keep)
        _ = await renewals.renew(stored.key, p1, post: { _ in .tokens(p2) }, keep: keep)
        #expect(vault.peek()?.nous?.refreshToken == "rt-0")

        // Unlock: retryUnsaved must CAS `rt-0 -> rt-2` and succeed.
        canWrite.set(true)
        await renewals.retryUnsaved()
        #expect(vault.peek()?.nous?.refreshToken == "rt-2")
    }

    /// When an alongside renewal receives `503 refresh_pending` right as a probe closes, `settleRenewal()` waits for
    /// the follow-up collector to retrieve and persist the rotated pair before invalidating the transport.
    @Test func refreshPendingCollectsRotatedPairBeforeProbeCloses() async throws {
        let attempts = Tally()
        let server = try LoopbackHTTP(headers: { $0.path == Self.refreshPath && attempts.total == 1 ? ["Retry-After": "1"] : [:] }) { request in
            switch request.path {
            case Self.sessionPath:
                return (200, Data(#"{"id":"s1","last_active":100,"message_count":1}"#.utf8))
            case Self.refreshPath:
                attempts.enter(0)
                if attempts.total == 1 {
                    return (503, Data(#"{"error":"refresh_pending","detail":"Sign-in renewal is still in progress; retry with the same refresh token.","retry_after":1}"#.utf8))
                }
                return (200, Self.refreshPayload(2, expiresIn: 900))
            default:
                return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }

        let vault = Fixtures.testVault("nous-refresh-pending-close")
        vault.removeAll()
        defer { vault.removeAll() }
        // 300 s of 900 s left: triggers an alongside renewal while GET /api/sessions/s1 succeeds immediately.
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: StoredAccount.nousUsername(userId: "u1"),
                                   nous: Self.tokenPair(1, expiresIn: 300, obtainedAgo: 600))
        try vault.save(stored)
        let renewals = NousRenewals(hold: { _ in { } })
        let probe = AccountProbe(stored: stored, vault: vault, renewals: renewals)

        guard case .session = try await probe.session(id: "s1", profile: nil) else {
            Issue.record("session read failed")
            return
        }
        probe.close()

        // Even though probe.close() was called immediately, the pending collector must finish and save rt-2.
        try await eventually(within: 8, "refresh_pending collected and persisted") {
            vault.peek()?.nous?.refreshToken == "rt-2"
        }
        #expect(attempts.total == 2)
    }

    /// A short launch restore budget (`verify(budget:)`) times out the caller on schedule without cancelling the
    /// underlying `/auth/native/refresh` POST, so the rotated pair still lands in Keychain.
    @Test func restoreBudgetDoesNotCancelRefreshPostMidFlight() async throws {
        let server = try LoopbackHTTP(delay: { $0.path == Self.refreshPath ? 1.0 : 0 }) { request in
            switch request.path {
            case Self.refreshPath: return (200, Self.refreshPayload(2, expiresIn: 900))
            case Self.mePath: return (200, Data(#"{"user_id":"u1"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }

        let vault = Fixtures.testVault("nous-restore-budget")
        vault.removeAll()
        defer { vault.removeAll() }
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: StoredAccount.nousUsername(userId: "u1"),
                                   nous: Self.tokenPair(1, expiresIn: -10, obtainedAgo: 910))
        try vault.save(stored)
        let transport = HTTPTransport(cookies: false)
        defer { transport.invalidate() }
        let auth = GatewayAuth(stored: stored, base: URL(string: stored.url)!, transport: transport, vault: vault,
                               verified: false, renewals: NousRenewals(hold: { _ in { } }))
        await auth.useLeaseDirectory(nil)

        await #expect(throws: GatewayFailure.timeout) {
            try await auth.verify(budget: .milliseconds(550))
        }
        try await eventually(within: 5, "rotation finishes and persists past restore budget") {
            vault.peek()?.nous?.refreshToken == "rt-2"
        }
        #expect(await auth.rejection == nil)
    }

    /// A 401 on an upload/download written by a proxy or Cloudflare wall (HTML, not Hermes JSON) must not trigger a
    /// refresh or sign out the session.
    @Test func transfer401FromProxyWallDoesNotRefresh() async throws {
        let server = try LoopbackHTTP { request in
            switch request.path {
            case Self.refreshPath: return (401, Data(#"{"error":"session_expired"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }

        let vault = Fixtures.testVault("nous-transfer-wall")
        vault.removeAll()
        defer { vault.removeAll() }
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: StoredAccount.nousUsername(userId: "u1"),
                                   nous: Self.tokenPair(1, expiresIn: 800, obtainedAgo: 100))
        try vault.save(stored)
        let transport = HTTPTransport(cookies: false)
        defer { transport.invalidate() }
        let auth = GatewayAuth(stored: stored, base: URL(string: stored.url)!, transport: transport, vault: vault,
                               verified: true, renewals: NousRenewals(hold: { _ in { } }))
        let url = URL(string: "http://127.0.0.1:\(port)/api/fs/download")!
        let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
        let wall = Data("<!doctype html><html><title>Checking your browser</title></html>".utf8)
        let shouldRetry = try await auth.finishTransfer(response, body: wall, request: URLRequest(url: url),
                                                        sentAccess: "at-1", retried: false)
        #expect(!shouldRetry)
        #expect(server.requests.isEmpty)
        #expect(await auth.rejection == nil)
        #expect(vault.peek()?.nous?.refreshToken == "rt-1")
    }

    /// `NousSessionKeepAlive` renews saved Nous sessions whose pair has sat untouched for ≥ 4 h (preventing Portal's
    /// 24 h idle refresh-token expiry), skips fresh sessions, and never touches Keychain while locked.
    @Test func keepAliveRenewsIdleNousSessionsAndSkipsFreshOrLocked() async throws {
        let server = try LoopbackHTTP { request in
            switch request.path {
            case Self.refreshPath: return (200, Self.refreshPayload(2, expiresIn: 900))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }

        let locked = Locked(false)
        var vault = Fixtures.testVault("nous-keepalive")
        vault.removeAll()
        defer { vault.removeAll() }
        vault.lockedForTests = { locked.value }

        let idle = StoredAccount(url: "http://127.0.0.1:\(port)", username: StoredAccount.nousUsername(userId: "u1"),
                                 nous: Self.tokenPair(1, expiresIn: -14_000, obtainedAgo: 5 * 3600))
        let fresh = StoredAccount(url: "http://127.0.0.1:\(port)", username: StoredAccount.nousUsername(userId: "u2"),
                                  nous: Self.tokenPair(10, expiresIn: 600, obtainedAgo: 300, user: "u2"))
        try vault.save(idle)
        try vault.save(fresh)

        let renewals = NousRenewals(hold: { _ in { } })
        // Locked: never spends anything.
        locked.set(true)
        let whileLocked = await NousSessionKeepAlive.refreshDue(vault: vault, renewals: renewals)
        #expect(whileLocked == 0)
        #expect(server.requests.isEmpty)

        // Unlocked: only the 5 h idle account renews; the 5 min fresh one is untouched.
        locked.set(false)
        let count = await NousSessionKeepAlive.refreshDue(vault: vault, renewals: renewals)
        #expect(count == 1)
        #expect(server.requests.filter { $0.path == Self.refreshPath }.count == 1)
        #expect(vault.peek(idle.key)?.nous?.refreshToken == "rt-2")
        #expect(vault.peek(fresh.key)?.nous?.refreshToken == "rt-10")
    }

    /// A parked Nous gateway with no cached chats still runs keep-alive when its pair is ≥ 4 h old, so switching back
    /// after a day never finds it signed out.
    @MainActor @Test func switcherKeepsIdleParkedNousGatewayAliveWithNoChats() async throws {
        let vault = Fixtures.testVault("switcher-nous-keepalive")
        vault.removeAll()
        defer { vault.removeAll() }
        let store = AccountStore(vault: vault)
        let current = StoredAccount(url: "http://127.0.0.1:9750", username: "qa",
                                    cookies: [SavedCookie(name: "s", value: "1", domain: "127.0.0.1")])
        let idleNous = StoredAccount(url: "http://127.0.0.1:9751", username: StoredAccount.nousUsername(userId: "u1"),
                                     nous: Self.tokenPair(1, expiresIn: -14_000, obtainedAgo: 5 * 3600))
        try store.save(idleNous)
        try store.save(current)

        let directory = BotsTest.tempDirectory()
        let model = GatewaySwitcherModel(store: store, directory: directory)
        model.currentId = { current.gatewayAccount?.id }
        let keepAlives = Tally()
        nonisolated final class KeepAliveProbe: ParkedAccountReading {
            let tally: Tally
            init(tally: Tally) { self.tally = tally }
            func read(id: String, profile: String?) async throws -> AccountProbe.Answer { .missing }
            func keepAlive(olderThan age: TimeInterval) async throws -> AccountProbe.Answer {
                tally.enter(0)
                return .session(.null)
            }
            func finish() {}
        }
        model.makeProbe = { _ in KeepAliveProbe(tally: keepAlives) }
        await model.check()
        #expect(keepAlives.total == 1)
        #expect(model.hasUsableSession(idleNous.gatewayAccount!))
    }

    /// ShareSender retries `503 refresh_pending` and persists the rotated pair instead of stranding it.
    @Test func shareSenderRetriesRefreshPending() async throws {
        let gateway = ShareStubGateway()
        let now = Date().timeIntervalSince1970
        let keychain = gateway.keychain(nous: ShareSamples.nous(expiresAt: now - 10, user: "u1", obtainedAt: now - 910), username: "nous:u1")
        let attempts = Tally()
        gateway.onHTTP { seen in
            guard seen.path == Self.refreshPath else { return nil }
            attempts.enter(0)
            if attempts.total == 1 {
                return ShareStubProtocol.Reply(status: 503,
                                               headers: ["Content-Type": "application/json", "Retry-After": "1"],
                                               body: Data(#"{"error":"refresh_pending","retry_after":1}"#.utf8))
            }
            return nousRefreshAnswer()
        }
        let sender = gateway.sender(keychain)
        sender.leaseDirectory = nil
        let result = try await sender.send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: gateway.roster(username: "nous:u1"))
        #expect(result.renewedCookies)
        #expect(attempts.total == 2)
    }
}

/// Portal OAuth / MCP proxy-wall protection and background-time hold (in the serialized `HermesCloudTests` suite
/// because `PortalStub` is shared).
extension HermesCloudTests {
    @Test func portalLoginSurvivesCloudflareAndProxyWallsAndHoldsBackgroundTime() async throws {
        let keychain = PortalKeychain(service: "tests.portal.wall.\(UUID().uuidString)")
        defer { keychain.clear() }
        keychain.save(PortalCredentials(clientId: "mcp:c", accessToken: "old", refreshToken: "ref-1", expiresAt: 0, obtainedAt: 0))

        // 1. HTML 403 on /api/oauth/token is NOT a Portal refusal: credentials stay in Keychain.
        let events = Locked<[String]>([])
        let session = PortalAuth.makeSession(protocols: [PortalStub.self])
        let login = PortalLogin(keychain: keychain, auth: PortalAuth(session: session), hold: { name in
            events.mutate { $0.append("hold:\(name)") }
            return { events.mutate { $0.append("release") } }
        })
        PortalStub.reset { path, _ in
            if path == "/api/oauth/token" {
                return (403, ["Content-Type": "text/html"], "<!doctype html><html><title>Just a moment...</title></html>")
            }
            return (401, ["Content-Type": "text/html"], "<!doctype html><html><title>Blocked</title></html>")
        }
        await #expect(throws: PortalError.problem) {
            _ = try await login.accessToken(force: true)
        }
        #expect(await login.isSignedIn, "an HTML 403 wiped the Portal login")
        #expect(keychain.read()?.refreshToken == "ref-1")
        #expect(events.value == ["hold:Hermes HQ Portal renewal", "release"])

        // 2. HTML 401 wall on /mcp keeps the Portal login intact (doesn't call login.signOut()).
        let client = HermesCloudClient(login: login, session: session)
        await #expect(throws: PortalError.problem) {
            _ = try await client.listAgents()
        }
        #expect(await login.isSignedIn, "an HTML 401 wall on /mcp signed out of Portal")
        #expect(keychain.read()?.refreshToken == "ref-1")
    }
}
