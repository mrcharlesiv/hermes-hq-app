// [cf-access] A Cloudflare Access service token saved with a gateway (public issue #37): its two headers ride every
// request to that gateway, from the first probe of the sign-in form to the socket's ticket; the pair lives in the
// sign-in's Keychain item, outlives an ended session, and the Share extension reads it from there. Against
// `LoopbackHTTP` standing in for Cloudflare Access in front of Hermes (127.0.0.1, this process only).

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@Suite("Cloudflare Access: the token")
nonisolated struct CloudflareAccessTokenTests {
    @Test func bothPartsOrNothing() {
        #expect(CloudflareAccess(clientId: " abc.access ", clientSecret: "\nsecret\n")?.headers
                == ["CF-Access-Client-Id": "abc.access", "CF-Access-Client-Secret": "secret"])
        #expect(CloudflareAccess(clientId: "abc.access", clientSecret: "  ") == nil)
        #expect(CloudflareAccess(clientId: nil, clientSecret: "secret") == nil)
    }

    @Test func accessAsksForSignInWithARedirectToItsLoginPage() {
        #expect(CloudflareAccess.asksForSignIn(status: 302, location: "https://team.cloudflareaccess.com/cdn-cgi/access/login/hermes.example.com?kid=1"))
        #expect(CloudflareAccess.asksForSignIn(status: 302, location: "/cdn-cgi/access/login?x=1"))
        #expect(!CloudflareAccess.asksForSignIn(status: 302, location: "/login"))
        #expect(!CloudflareAccess.asksForSignIn(status: 200, location: "https://team.cloudflareaccess.com/"))
        #expect(!CloudflareAccess.asksForSignIn(status: 302, location: nil))
    }

    @Test func itIsSavedWithTheGatewayAndOutlivesAnEndedSession() throws {
        let token = CloudflareAccess(clientId: "abc.access", clientSecret: "s3")!
        let stored = StoredAccount(url: "https://hermes.example.com", username: "me",
                                   cookies: [SavedCookie(name: "hermes_session_rt", value: "v", domain: "hermes.example.com")], access: token)
        let list = SavedAccounts(current: stored.key, accounts: [stored])
        let back = try #require(SavedAccounts.decode(try list.encoded()))
        #expect(back.active?.access == token)
        #expect(stored.withoutSession.access == token && !stored.withoutSession.hasSession)
        #expect(stored.accessHeaders == token.headers)
        // An item written before this field reads as no token.
        let old = Data(#"{"current":"k","accounts":[{"url":"https://hermes.example.com","username":"me"}]}"#.utf8)
        #expect(SavedAccounts.decode(old)?.accounts.first?.access == nil)
        #expect(StoredAccount(url: "https://hermes.example.com", username: "me").accessHeaders.isEmpty)
    }

    @Test func theShareExtensionReadsItFromTheSameItem() throws {
        let token = CloudflareAccess(clientId: "abc.access", clientSecret: "s3")!
        let stored = StoredAccount(url: "https://hermes.example.com", username: "me", access: token)
        let item = try SavedAccounts(current: stored.key, accounts: [stored]).encoded()
        #expect(ShareAccounts.current(in: item)?.access == token)
        let plain = try SavedAccounts(current: stored.key, accounts: [StoredAccount(url: stored.url, username: "me")]).encoded()
        #expect(ShareAccounts.current(in: plain)?.access == nil)
    }
}

@Suite("Cloudflare Access: on the wire", .serialized)
struct CloudflareAccessWireTests {
    nonisolated static let token = CloudflareAccess(clientId: "abc.access", clientSecret: "s3cret")!

    /// Cloudflare Access in front of a Hermes with password sign-in: without the token's headers every path answers
    /// with the redirect to Access's login page; with them Hermes answers.
    nonisolated static func walled() throws -> LoopbackHTTP {
        try LoopbackHTTP(headers: { request in
            Self.carries(request) ? [:] : ["Location": "https://team.cloudflareaccess.com/cdn-cgi/access/login/hermes.example.com"]
        }) { request in
            guard Self.carries(request) else { return (302, Data()) }
            switch (request.method, request.path) {
            case ("GET", "/api/status"): return (200, Data(#"{"version":"1.0.0","auth_required":true,"auth_providers":["basic"],"auth_flows":[]}"#.utf8))
            case ("GET", "/api/auth/providers"): return (200, Data(#"{"providers":[{"name":"basic","supports_password":true}]}"#.utf8))
            case ("POST", "/auth/password-login"): return (200, Data(#"{"ok":true}"#.utf8))
            case ("GET", "/api/auth/me"): return (200, Data(#"{"user":"tester"}"#.utf8))
            case ("POST", "/api/auth/ws-ticket"): return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
    }

    nonisolated static func carries(_ request: LoopbackHTTP.Request) -> Bool {
        request.headers["cf-access-client-id"] == token.clientId && request.headers["cf-access-client-secret"] == token.clientSecret
    }

    @Test func theProbeSaysTheAddressIsBehindAccessUntilItHasTheToken() async throws {
        let server = try Self.walled()
        let port = try await server.start()
        defer { server.stop() }
        let address = "http://127.0.0.1:\(port)"
        let bare = await SignInFlows.probe(address)
        #expect(bare.behindAccess && !bare.known)
        let wrong = await SignInFlows.probe(address, access: CloudflareAccess(clientId: "abc.access", clientSecret: "nope"))
        #expect(wrong.behindAccess && !wrong.known)
        let right = await SignInFlows.probe(address, access: Self.token)
        #expect(right.known && right.password && !right.behindAccess)
    }

    /// A sign-in through Access: every request of it carries the token, the saved gateway keeps it, and the
    /// connection that follows (the ticket, then the socket's handshake) carries it too.
    @Test func aSignInCarriesTheTokenAndSavesItWithTheGateway() async throws {
        let server = try Self.walled()
        let port = try await server.start()
        defer { server.stop() }
        let vault = Fixtures.testVault("cf-access-sign-in")
        vault.removeAll()
        defer { vault.removeAll() }
        let service = SignInService(store: AccountStore(vault: vault))
        let address = "http://127.0.0.1:\(port)"
        await #expect(throws: GatewayFailure.self) {
            _ = try await service.signInWithPassword(address: address, username: "tester", password: "pw")
        }
        #expect(vault.peek() == nil)
        let account = try await service.signInWithPassword(address: address, username: "tester", password: "pw", access: Self.token)
        defer { service.signOut() }
        #expect(vault.peek()?.access == Self.token)
        #expect(service.savedAccess(for: address) == Self.token)
        try await eventually(within: 10, "the socket's handshake") { server.requests.contains { $0.path == "/api/ws" } }
        let after = server.requests.drop { !Self.carries($0) }
        #expect(!after.isEmpty && after.allSatisfy(Self.carries))
        #expect(after.contains { $0.path == "/api/auth/ws-ticket" })
        // Cleared in Settings: the gateway's next client is made without it.
        #expect(try service.setAccess(nil, for: account))
        #expect(vault.peek()?.access == nil && service.savedAccess(for: address) == nil)
    }

    /// The token stopped working (revoked, or the policy changed): Access's redirect at the ticket reads "blocked",
    /// and the sign-in is kept.
    @Test func accessTurningTheTicketAwayKeepsTheSession() async throws {
        let server = try Self.walled()
        let port = try await server.start()
        defer { server.stop() }
        let vault = Fixtures.testVault("cf-access-blocked")
        vault.removeAll()
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: "tester",
                                   cookies: [SavedCookie(name: "hermes_session_rt", value: "keep-me", domain: "127.0.0.1")],
                                   access: CloudflareAccess(clientId: "abc.access", clientSecret: "revoked"))
        try vault.save(stored)
        let transport = HTTPTransport(headers: stored.accessHeaders)
        defer { transport.invalidate(); vault.removeAll() }
        let auth = GatewayAuth(stored: stored, base: URL(string: stored.url)!, transport: transport, vault: vault, verified: true)
        await #expect(throws: GatewayFailure.blocked) { _ = try await auth.mintTicket(timeout: .seconds(8)) }
        #expect(await auth.rejection == nil)
        #expect(vault.peek()?.cookies?.first?.value == "keep-me")
    }
}

/// The form's part: the token's fields open by themselves when Access answers, and the driver gets the token before
/// the address is asked about again.
@Suite("Cloudflare Access: the sign-in form")
struct CloudflareAccessFormTests {
    final class Driver: SignInDriving {
        var saved: CloudflareAccess?
        var used: [CloudflareAccess?] = []
        var probes = 0
        func useAccess(_ access: CloudflareAccess?) { used.append(access) }
        func savedAccess(for address: String) -> CloudflareAccess? { saved }
        func probe(_ address: String) async -> SignInOptions {
            probes += 1
            guard used.last ?? nil != nil else { return SignInOptions(reachable: false, offersNous: false, offersPassword: false, behindAccess: true) }
            return SignInOptions(reachable: true, offersNous: false, offersPassword: true)
        }
        func signInWithPassword(address: String, username: String, password: String) async throws {}
        func signInWithNous(address: String) async throws {}
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    @Test func accessAnsweringOpensTheFieldsAndTheTokenAsksAgain() async {
        let driver = Driver()
        let model = SignInModel(driver: driver, onSignedIn: {})
        model.delay = .milliseconds(1)
        #expect(!model.accessOpen)
        model.address = "hermes.example.com"
        #expect(await until { model.behindAccess })
        #expect(model.accessOpen && model.note == SignInCopy.Access.needed)
        model.accessId = "abc.access"
        model.accessSecret = "s3"
        #expect(await until { !model.behindAccess && model.ways == .password })
        #expect(model.note == nil && driver.used.last == CloudflareAccess(clientId: "abc.access", clientSecret: "s3"))
    }

    @Test func aGatewaySavedAtTheAddressFillsItsToken() async {
        let driver = Driver()
        driver.saved = CloudflareAccess(clientId: "abc.access", clientSecret: "s3")
        let model = SignInModel(driver: driver, address: "hermes.example.com", onSignedIn: {})
        #expect(await until { model.ways == .password })
        #expect(model.accessOpen && model.accessId == "abc.access" && model.accessSecret == "s3")
        #expect(driver.probes == 1)              // filling it in did not ask twice
    }
}
