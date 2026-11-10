// Connection, sign-in and Hermes Cloud repairs from the build 863 audit: a transfer after the transport was let go,
// a sign-out mark that outlived its write, the replay hold's byte count, a pair with no expiry, the background task a
// late end could take, and the Portal login (one MCP session for calls made at once, a renewal the Keychain refused,
// a late 401 for a token already replaced).

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct NetAudit863Tests {
    // MARK: Transfers after a sign-out or a switch

    /// A sign-out or a gateway switch invalidates the transport while an upload or download is about to start: the
    /// transfer answers "Connection changed" (asking an invalidated URLSession for a task raises and ends the app).
    @Test func aTransferOnALetGoTransportIsConnectionChanged() async throws {
        let base = URL(string: "http://127.0.0.1:9")!
        let transport = HTTPTransport()
        let vault = Fixtures.testVault("audit863-transfer")
        defer { vault.removeAll() }
        let auth = GatewayAuth(stored: StoredAccount(url: base.absoluteString, username: "tester"), base: base, transport: transport,
                               vault: vault, verified: false, persisted: false, renewals: NousRenewals())
        transport.invalidate()
        let body = FileManager.default.temporaryDirectory.appending(path: "hqn-audit863-\(UUID().uuidString).multipart")
        try Data("B".utf8).write(to: body)
        defer { try? FileManager.default.removeItem(at: body) }
        await #expect(throws: GatewayFailure.connectionChanged) {
            _ = try await GatewayTransfer.upload(auth: auth, transport: transport, base: base, path: "/api/files/upload-stream",
                                                 query: [], contentType: "multipart/form-data; boundary=b", bodyFile: body,
                                                 timeout: 5, priority: 0.5, progress: nil)
        }
        let target = FileManager.default.temporaryDirectory.appending(path: "hqn-audit863-dl-\(UUID().uuidString)")
        await #expect(throws: GatewayFailure.connectionChanged) {
            _ = try await GatewayTransfer.download(auth: auth, transport: transport, base: base, path: "/api/fs/download",
                                                   query: [], to: target, ceiling: 1024, priority: 0.5, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: The replay hold

    /// Releasing one session's held frames lowers the bytes held by its share, so a second session still catching up
    /// is measured against what is really held (the 4 MiB budget dropped the socket early).
    @Test func releasingOneSessionLowersTheBytesHeld() {
        func event(_ session: String, _ seq: Int) -> GatewayEvent {
            GatewayEvent(type: "message.delta", sessionId: session, seq: seq, payload: [:])
        }
        var book = ReplayBook()
        _ = book.ready(epoch: "e")
        _ = book.live(event("s1", 1), size: 1)
        _ = book.live(event("s2", 1), size: 1)
        #expect(book.ready(epoch: "e").count == 2)
        #expect(!book.live(event("s1", 2), size: 3 << 20).overBudget)
        #expect(book.release("s1").map(\.seq) == [2])
        #expect(book.parkedBytes == 0 && book.parkedCount == 0 && book.isParking)
        #expect(!book.live(event("s2", 2), size: 3 << 20).overBudget, "3 MiB held, not 6")
        #expect(book.parkedBytes == 3 << 20)
        #expect(book.live(event("s2", 3), size: 2 << 20).overBudget)
        _ = book.release("s2")
        #expect(book.parkedBytes == 0 && !book.isParking)
    }

    // MARK: Renewal timing

    /// A pair with neither an issue time nor an expiry is never renewed ahead of time (spec 01 §7.1, D6); a 401 renews
    /// it. The Share extension keeps the same rule.
    @Test func aPairWithNoExpiryIsNotDue() {
        #expect(!NousTokens(accessToken: "a", refreshToken: "r", expiresAt: 0, userId: "u", obtainedAt: nil).needsRenewal(now: 10))
        #expect(!ShareNous(accessToken: "a", refreshToken: "r", expiresAt: 0, userId: "u", obtainedAt: nil).needsRenewal(now: 10))
        // An expiry without an issue time keeps the web rule.
        #expect(NousTokens(accessToken: "a", refreshToken: "r", expiresAt: 1000, userId: "u", obtainedAt: nil).needsRenewal(now: 941))
        #expect(ShareNous(accessToken: "a", refreshToken: "r", expiresAt: 1000, userId: "u", obtainedAt: nil).needsRenewal(now: 941))
    }

    // MARK: The background task

    /// Back and away again within the second the background close keeps its task for: that late end must not end the
    /// new trip's task (its grace would then run with the app frozen).
    @Test func aLateEndLeavesTheNextTripsBackgroundTask() async throws {
        let base = URL(string: "http://127.0.0.1:9")!
        let transport = HTTPTransport()
        defer { transport.invalidate() }
        let vault = Fixtures.testVault("audit863-background")
        defer { vault.removeAll() }
        let auth = GatewayAuth(stored: StoredAccount(url: base.absoluteString, username: "tester"), base: base, transport: transport,
                               vault: vault, verified: true, persisted: false, renewals: NousRenewals())
        let ends = Locked(0)
        let states = StateHub(.connecting)
        let outlets = GatewayConnection.Outlets(events: Broadcast<GatewayEvent>(), states: states, ready: Locked<JSONValue?>(nil),
                                                failure: Locked<GatewayFailure?>(nil),
                                                endBackgroundTask: { ends.set(ends.value + 1) })
        let connection = GatewayConnection(base: base, socketProfile: "default", auth: auth, transport: transport, outlets: outlets,
                                           timing: GatewayConnection.Timing(backgroundGrace: 0.2))
        await connection.handle(.enteredBackground(granted: true))
        let deadline = ContinuousClock.now + .seconds(5)
        while states.value != .offline(reason: GatewayFailure.paused.code), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(states.value == .offline(reason: GatewayFailure.paused.code))   // the grace closed the socket (flush: 1 s)
        await connection.handle(.becameActive)                                   // ends the first trip's task
        await connection.handle(.enteredBackground(granted: true))               // a new task, a new grace
        #expect(ends.value == 1)
        try await Task.sleep(for: .seconds(2.5))
        // The second grace's own close ends its task; the first close's late end did nothing.
        #expect(ends.value == 2)
        await connection.handle(.shutdown)
    }
}

/// The sign-in item's "sign-out not yet written" mark (spec 01 §2.4).
@Suite(.serialized) struct SignedOutMarkTests {
    let vault = Fixtures.testVault("audit863-signedout")

    func account(_ host: String) -> StoredAccount {
        StoredAccount(url: "https://\(host).example.com", username: "u", cookies: [SavedCookie(name: "s", value: "1", domain: "\(host).example.com")])
    }

    /// The sign-out of `c` could not be written, then a switch to `a` was: that write already drops `c`, so the mark
    /// is settled with it. Left set, the next launch would remove whoever is current then: `a`, not `c`.
    @Test func aSwitchWrittenAfterAFailedSignOutSettlesTheMark() throws {
        vault.removeAll()
        defer { vault.removeAll() }
        let a = account("a"), b = account("b"), c = account("c")
        try vault.save(a); try vault.save(b); try vault.save(c)
        UserDefaults.standard.set(true, forKey: vault.signedOutKey)
        #expect(try vault.select(a.key))
        #expect(!UserDefaults.standard.bool(forKey: vault.signedOutKey))
        let saved = try #require(try vault.load())
        #expect(saved.active?.key == a.key)
        #expect(Set(saved.accounts.map(\.key)) == [a.key, b.key])
    }

    /// A renewal of another gateway written while the mark is up: the account being signed out goes, the next most
    /// recent one is current, and it stays saved at the next launch.
    @Test func aRenewalWrittenAfterAFailedSignOutSettlesTheMark() throws {
        vault.removeAll()
        defer { vault.removeAll() }
        let a = account("a"), b = account("b")
        try vault.save(a); try vault.save(b)
        UserDefaults.standard.set(true, forKey: vault.signedOutKey)
        #expect(vault.peek() == nil)                                              // still reads as signed out
        #expect(try vault.update(a.key) { $0.cookies = [SavedCookie(name: "s", value: "2", domain: "a.example.com")] })
        #expect(!UserDefaults.standard.bool(forKey: vault.signedOutKey))
        let saved = try #require(try vault.load())
        #expect(saved.active?.key == a.key && saved.accounts.map(\.key) == [a.key])
        #expect(saved.active?.cookies?.first?.value == "2")
    }

    /// Nothing written (a renewal for the account being signed out, which is already gone from the list): the mark
    /// stays, and the next launch still removes it.
    @Test func noWriteKeepsTheMark() throws {
        vault.removeAll()
        defer { vault.removeAll() }
        let a = account("a"), b = account("b")
        try vault.save(a); try vault.save(b)
        UserDefaults.standard.set(true, forKey: vault.signedOutKey)
        #expect(try !vault.update(b.key) { $0.cookies = [] })
        #expect(UserDefaults.standard.bool(forKey: vault.signedOutKey))
        let saved = try #require(try vault.load())
        #expect(saved.active?.key == a.key && saved.accounts.map(\.key) == [a.key])
        #expect(!UserDefaults.standard.bool(forKey: vault.signedOutKey))
    }
}

/// Hermes Cloud's Portal login and MCP session (in the serialized Hermes Cloud suite: `PortalStub` is shared).
extension HermesCloudTests {
    nonisolated static let toolsAnswer: JSONValue = ["tools": [["name": "agents", "inputSchema": realAgentsSchema],
                                                               ["name": "agent", "inputSchema": realAgentSchema]]]

    /// Opening Hermes Cloud reads the agents and the create form at once: both wait for one `initialize` (each starting
    /// its own Portal session left one of them on a session Portal had replaced).
    @Test func callsMadeAtOnceShareOnePortalSession() async throws {
        let keychain = PortalKeychain(service: "tests.portal.\(UUID().uuidString)")
        defer { keychain.clear() }
        keychain.save(PortalCredentials(clientId: "mcp:c", accessToken: "tok", refreshToken: "ref", expiresAt: 0, obtainedAt: 0))
        let sessions = Locked(0)
        PortalStub.reset { _, body in
            let id = body["id"]
            switch body["method"]?.string {
            case "initialize":
                Thread.sleep(forTimeInterval: 0.2)          // the other call comes while this one is out
                sessions.set(sessions.value + 1)
                return (200, ["Content-Type": "application/json", "Mcp-Session-Id": "s\(sessions.value)"], Self.mcp(id, [:]))
            case "notifications/initialized": return (202, [:], "")
            case "tools/list": return (200, ["Content-Type": "application/json"], Self.mcp(id, Self.toolsAnswer))
            case "tools/call": return (200, ["Content-Type": "application/json"], Self.mcp(id, Self.toolText(["agents": []])))
            default: return (400, [:], "")
            }
        }
        let (client, _) = Self.client(keychain: keychain)
        async let list = client.listAgents()
        async let form = client.createFields()
        let (agents, fields) = try await (list, form)
        #expect(agents.isEmpty && !fields.isEmpty)
        #expect(PortalStub.methods.filter { $0 == "initialize" }.count == 1)
        #expect(sessions.value == 1)
    }

    /// A rotation the Keychain refused (before the first unlock after a restart) is still the login: the next renewal
    /// sends its refresh token, never the spent one the Keychain holds, and it is written once the Keychain takes it.
    @Test func aRenewalTheKeychainRefusedIsStillTheLogin() async throws {
        let refusing = Locked(true)
        var keychain = PortalKeychain(service: "tests.portal.\(UUID().uuidString)")
        defer { keychain.clear() }
        keychain.save(PortalCredentials(clientId: "mcp:c", accessToken: "old", refreshToken: "ref-1", expiresAt: 0, obtainedAt: 0))
        keychain.refusesSavesForTests = { refusing.value }
        let spent = Locked<Set<String>>([])
        PortalStub.reset { path, body in
            guard path == "/api/oauth/token", let form = body.string,
                  let refresh = form.split(separator: "&").first(where: { $0.hasPrefix("refresh_token=") })?.dropFirst(14) else { return (404, [:], "") }
            let token = String(refresh)
            guard !spent.value.contains(token) else { return (400, ["Content-Type": "application/json"], #"{"error":"invalid_grant"}"#) }
            spent.set(spent.value.union([token]))
            let n = Int(token.dropFirst(4)) ?? 0
            return (200, ["Content-Type": "application/json"], #"{"access_token":"a\#(n + 1)","refresh_token":"ref-\#(n + 1)"}"#)
        }
        let session = PortalAuth.makeSession(protocols: [PortalStub.self])
        let login = PortalLogin(keychain: keychain, auth: PortalAuth(session: session))
        #expect(try await login.accessToken(force: true) == "a2")
        #expect(keychain.read()?.refreshToken == "ref-1")                   // the Keychain still holds the spent one
        #expect(try await login.accessToken(force: true) == "a3")           // renewed from ref-2, kept in memory
        #expect(await login.isSignedIn)
        refusing.set(false)
        #expect(try await login.accessToken() == "a3")
        #expect(keychain.read()?.refreshToken == "ref-3")                   // written once the Keychain took it
        #expect(spent.value == ["ref-1", "ref-2"])
    }

    /// A 401 for a token another call has already replaced: the newer token is the answer, with no second renewal
    /// (which would spend the new refresh token for nothing, and a refused one signs the phone out of Portal).
    @Test func a401ForAReplacedTokenTakesTheNewOne() async throws {
        let keychain = PortalKeychain(service: "tests.portal.\(UUID().uuidString)")
        defer { keychain.clear() }
        keychain.save(PortalCredentials(clientId: "mcp:c", accessToken: "old", refreshToken: "ref-1", expiresAt: 0, obtainedAt: 0))
        let renewals = Locked(0)
        PortalStub.reset { path, body in
            guard path == "/api/oauth/token" else { return (404, [:], "") }
            renewals.set(renewals.value + 1)
            guard body.string?.contains("refresh_token=ref-1") == true else { return (400, [:], #"{"error":"invalid_grant"}"#) }
            return (200, ["Content-Type": "application/json"], #"{"access_token":"new","refresh_token":"ref-2","expires_in":3600}"#)
        }
        let session = PortalAuth.makeSession(protocols: [PortalStub.self])
        let login = PortalLogin(keychain: keychain, auth: PortalAuth(session: session))
        #expect(try await login.accessToken(force: true, refused: "old") == "new")
        #expect(try await login.accessToken(force: true, refused: "old") == "new")   // a late 401 from the other call
        #expect(renewals.value == 1)
        #expect(await login.isSignedIn)
        // A 401 for the token in use still renews (and a refusal of that one still signs out, as before).
        await #expect(throws: PortalError.signedOut) { _ = try await login.accessToken(force: true, refused: "new") }
        #expect(renewals.value == 2)
    }
}
