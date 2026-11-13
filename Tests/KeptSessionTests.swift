// [kept-session] A 400/401/403 ends the saved sign-in only when Hermes wrote it (`GatewayRefusal`). The same status
// from whatever stands in front of Hermes (a reverse proxy, Cloudflare, the network's own filter) keeps the sign-in:
// the connection reads "blocked" and keeps trying (public issue #39: signed out whenever the gateway could not be
// reached for a while). Against `LoopbackHTTP` (127.0.0.1, this process only).

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@Suite("Kept session: who wrote the refusal")
nonisolated struct GatewayRefusalTests {
    @Test func hermesRefusesWithAJSONObject() {
        for body in [#"{"error":"session_expired","detail":"Unauthorized","reason":"invalid_or_expired_session","login_url":"/login"}"#,
                     #"{"error":"unauthenticated"}"#, #"{"error":"not_authorized"}"#, #"{"detail":"Unauthorized"}"#,
                     #"{"detail":"Not authenticated"}"#, #"{"detail":[{"loc":["body"],"msg":"field required"}]}"#] {
            #expect(GatewayRefusal.isHermes(Data(body.utf8)), "\(body)")
        }
    }

    @Test func anythingElseIsNotHermes() {
        for body in ["", "Forbidden", "<!doctype html><title>Just a moment...</title>", "<html><h1>403 Forbidden</h1><hr>nginx</html>",
                     "error code: 1020", "[]", "\"Unauthorized\"", "{}", #"{"message":"Forbidden"}"#,
                     #"{"cloudflare_error":true,"error_code":1020,"detail":"Access denied","title":"Error 1020"}"#] {
            #expect(!GatewayRefusal.isHermes(Data(body.utf8)), "\(body)")
        }
    }

    @Test func aRefreshAnswerNotFromHermesIsNotARefusal() {
        let page = Data("<html>403 Forbidden</html>".utf8)
        for status in [400, 401, 403] {
            #expect(NousGatewayProtocol.answer(status: status, body: page) == .unavailable(status))
            #expect(NousGatewayProtocol.answer(status: status, body: Data()) == .unavailable(status))
        }
        #expect(NousGatewayProtocol.answer(status: 401, body: Data(#"{"error":"session_expired"}"#.utf8)) == .refused("session_expired"))
        #expect(NousGatewayProtocol.answer(status: 400, body: Data(#"{"detail":"refresh_token required"}"#.utf8)) == .refused("session_expired"))
        #expect(NousGatewayProtocol.answer(status: 403, body: Data(#"{"detail":"no"}"#.utf8)) == .refused("not_authorized"))
    }

    @Test func blockedIsNotARejectionAndHasItsOwnWords() {
        #expect(!GatewayFailure.blocked.isRejection)
        #expect(GatewayFailure.forCode("blocked") == .blocked)
        #expect(ConnectionState.offline(reason: "blocked").userMessage == GatewayFailure.blocked.message)
        #expect(GatewayFailure.blocked.message.contains("still signed in"))
        let screen = OfflineCopy.screen(reason: "blocked", hasAddress: true)
        #expect(screen.title == "Something Is Blocking Hermes" && screen.recovery.contains("still signed in"))
    }
}

@Suite("Kept session: the sign-in survives a refusal Hermes did not write", .serialized)
nonisolated struct KeptSessionTests {
    static let ticketPath = "/api/auth/ws-ticket", refreshPath = "/auth/native/refresh", mePath = "/api/auth/me"
    static let page = Data("<!doctype html><html><title>Just a moment...</title><body>Checking your browser</body></html>".utf8)

    static func renewedBody() -> Data {
        let now = Date().timeIntervalSince1970
        return try! JSONSerialization.data(withJSONObject: ["access_token": "at-new", "refresh_token": "rt-new", "user_id": "u1",
                                                            "provider": "nous", "expires_at": now + 900])
    }

    /// A saved Nous account whose access token has `left` seconds of a 900 s lifetime.
    func nous(_ name: String, port: UInt16, left: Double) throws -> (GatewayAuth, AccountVault, HTTPTransport) {
        let now = Date().timeIntervalSince1970
        let tokens = NousTokens(accessToken: "at-old", refreshToken: "rt-old", expiresAt: now + left, userId: "u1", obtainedAt: now + left - 900)
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: StoredAccount.nousUsername(userId: "u1"), nous: tokens)
        let vault = Fixtures.testVault("kept-session-\(name)")
        vault.removeAll()
        try vault.save(stored)
        let transport = HTTPTransport()
        let auth = GatewayAuth(stored: stored, base: URL(string: stored.url)!, transport: transport, vault: vault, verified: true,
                               renewals: NousRenewals())
        return (auth, vault, transport)
    }

    /// The ticket answered by a wall in front of Hermes: no refresh is sent to it, nothing is forgotten, and the same
    /// auth mints a ticket as soon as Hermes answers again.
    @Test(arguments: [401, 403])
    func aTicketRefusedBySomethingElseKeepsTheSession(status: Int) async throws {
        let walled = Mutex(true)
        let server = try LoopbackHTTP { request in
            if walled.withLock({ $0 }) { return (status, Self.page) }
            switch request.path {
            case Self.ticketPath: return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (auth, vault, transport) = try nous("ticket-\(status)", port: port, left: 800)
        defer { transport.invalidate(); vault.removeAll() }
        await auth.useLeaseDirectory(nil)
        let told = Mutex<GatewayFailure?>(nil)
        await auth.setRejectionHandler { failure in told.withLock { $0 = failure } }
        await #expect(throws: GatewayFailure.blocked) { _ = try await auth.mintTicket(timeout: .seconds(8)) }
        #expect(await auth.rejection == nil)
        #expect(told.withLock { $0 } == nil)
        #expect(vault.peek()?.nous?.refreshToken == "rt-old")
        #expect(!server.requests.contains { $0.path == Self.refreshPath })       // the refresh token never met the wall
        walled.withLock { $0 = false }
        #expect(try await auth.mintTicket(timeout: .seconds(8)) == "t-1")
    }

    /// The token is due, so the refresh goes first, and the wall answers it: the pair was never spent and is kept.
    @Test(arguments: [400, 401, 403])
    func aRefreshRefusedBySomethingElseKeepsThePair(status: Int) async throws {
        let server = try LoopbackHTTP { request in
            switch request.path {
            case Self.refreshPath: return (status, Self.page)
            case Self.ticketPath: return (401, Self.page)
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (auth, vault, transport) = try nous("refresh-\(status)", port: port, left: -10)
        defer { transport.invalidate(); vault.removeAll() }
        await auth.useLeaseDirectory(nil)
        await #expect(throws: GatewayFailure.blocked) { _ = try await auth.mintTicket(timeout: .seconds(8)) }
        #expect(await auth.rejection == nil)
        #expect(vault.peek()?.nous?.refreshToken == "rt-old")
        // The same pair rests: a second ask right away fails the same way without another request.
        let posted = server.requests.filter { $0.path == Self.refreshPath }.count
        await #expect(throws: GatewayFailure.blocked) { _ = try await auth.mintTicket(timeout: .seconds(8)) }
        #expect(server.requests.filter { $0.path == Self.refreshPath }.count == posted)
    }

    /// Hermes's own answer still ends the session, as before.
    @Test func hermesOwnRefusalStillSignsOut() async throws {
        let server = try LoopbackHTTP { request in
            switch request.path {
            case Self.refreshPath: return (401, Data(#"{"error":"session_expired","detail":"Refresh token expired or invalid; start a new sign-in."}"#.utf8))
            case Self.ticketPath: return (401, Data(#"{"error":"session_expired","detail":"Unauthorized"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (auth, vault, transport) = try nous("hermes-refusal", port: port, left: 800)
        defer { transport.invalidate(); vault.removeAll() }
        await auth.useLeaseDirectory(nil)
        await #expect(throws: GatewayFailure.sessionEnded) { _ = try await auth.mintTicket(timeout: .seconds(8)) }
        #expect(await auth.rejection == .sessionEnded)
        #expect(vault.peek()?.nous == nil)
    }

    /// A password session's check (`/api/auth/me`) met by the wall: not a refusal either.
    @Test func aSessionCheckRefusedBySomethingElseIsBlocked() async throws {
        let server = try LoopbackHTTP { _ in (403, Self.page) }
        let port = try await server.start()
        defer { server.stop() }
        let vault = Fixtures.testVault("kept-session-me")
        vault.removeAll()
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: "tester",
                                   cookies: [SavedCookie(name: "hermes_session_rt", value: "keep-me", domain: "127.0.0.1")])
        try vault.save(stored)
        let transport = HTTPTransport()
        defer { transport.invalidate(); vault.removeAll() }
        let auth = GatewayAuth(stored: stored, base: URL(string: stored.url)!, transport: transport, vault: vault, verified: false)
        await #expect(throws: GatewayFailure.blocked) { try await auth.verify(budget: nil) }
        #expect(await auth.rejection == nil)
        #expect(vault.peek()?.cookies?.first?.value == "keep-me")
    }

    /// The whole connection: blocked reads as offline with its reason, never signed out, and it dials on by itself
    /// once the wall is gone.
    @Test func theConnectionStaysSignedInAndComesBack() async throws {
        let walled = Mutex(true)
        let server = try LoopbackHTTP { request in
            if walled.withLock({ $0 }) { return (403, Self.page) }
            switch (request.method, request.path) {
            case ("POST", Self.ticketPath): return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let vault = Fixtures.testVault("kept-session-connection")
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: "tester")
        let client = LiveGatewayClient(stored: stored, transport: HTTPTransport(), vault: vault, verified: false, watchNetwork: false)
        defer { client.shutdown(); vault.removeAll() }
        try await waitFor(client, .offline(reason: GatewayFailure.blocked.code), within: 10)
        #expect(!server.requests.contains { $0.path == Self.mePath })
        walled.withLock { $0 = false }
        // The loopback server speaks no websocket: reaching the upgrade is the proof that the ladder dialed on.
        try await eventually(within: 15, "the dial after the wall went") { server.requests.contains { $0.path == "/api/ws" } }
    }
}
