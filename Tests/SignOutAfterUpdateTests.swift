// [n20 B1] Signed out after updating. Portal's refresh tokens rotate with reuse detection: a spent one sent again ends
// the whole session. The iPhone's sign-out of 2026-10-23 (build 355 → 356) followed a renewal Portal answered while the
// app was in the background (21:48:57, the token's last minute, one second after the app woke) and the next launch
// sending a refresh token Portal refused (all_providers_rejected_rt). A successor that can't reach Keychain (the phone
// locked: the sign-in item is readable only `AfterFirstUnlockThisDeviceOnly`), or never arrives (the app suspended
// mid-request), lives only in memory and is lost when iOS ends the app for the update. These tests pin the rules that
// keep the saved copy from going stale.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Sign-out after updating: a renewal never spends what it can't save", .serialized)
nonisolated struct SignOutAfterUpdateTests {
    static let ticketPath = RenewAlongsideTests.ticketPath, refreshPath = RenewAlongsideTests.refreshPath

    /// A saved Nous account with `left` seconds of a 900 s token, on a vault whose lock state the test sets.
    func rig(_ name: String, port: UInt16, left: Double, locked: Locked<Bool>) throws -> (GatewayAuth, AccountVault, HTTPTransport) {
        let now = Date().timeIntervalSince1970
        let tokens = NousTokens(accessToken: "at-old", refreshToken: "rt-old", expiresAt: now + left, userId: "u1",
                                obtainedAt: now + left - 900)
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: StoredAccount.nousUsername(userId: "u1"), nous: tokens)
        var vault = Fixtures.testVault("signout-after-update-\(name)")
        vault.removeAll()
        try vault.save(stored)
        vault.lockedForTests = { locked.value }
        let transport = HTTPTransport()
        let auth = GatewayAuth(stored: stored, base: URL(string: stored.url)!, transport: transport, vault: vault,
                               verified: true, renewals: NousRenewals(hold: { _ in { } }))
        return (auth, vault, transport)
    }

    func server() throws -> LoopbackHTTP {
        try LoopbackHTTP { request in
            switch request.path {
            case Self.ticketPath: return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            case Self.refreshPath: return (200, RenewAlongsideTests.renewedBody("new"))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
    }

    /// The cause, reproduced: a renewal due while the phone is locked used to post the refresh token and keep the
    /// successor only in memory. Now nothing is posted, the current (still valid) token carries the request, the saved
    /// pair stays the live one, and the renewal runs once the phone is unlocked.
    @Test func aLockedPhoneDoesNotSpendTheRefreshToken() async throws {
        let http = try server()
        let port = try await http.start()
        defer { http.stop() }
        let locked = Locked(true)
        // 40 s of 900 left: in the token's last minute, so the request would wait for a renewal ("due").
        let (auth, vault, transport) = try rig("locked", port: port, left: 40, locked: locked)
        defer { transport.invalidate(); vault.removeAll() }

        let ticket = try await auth.mintTicket(timeout: .seconds(8))
        #expect(ticket == "t-1")
        #expect(http.requests.filter { $0.path == Self.refreshPath }.isEmpty, "a refresh token was spent while Keychain was locked")
        #expect(http.requests.first { $0.path == Self.ticketPath }?.authorization == "Bearer at-old")
        #expect(await auth.rejection == nil)
        #expect(vault.peek()?.nous?.refreshToken == "rt-old", "the saved pair is still the live one")

        // Unlocked: the next request renews, and the successor is saved before it is used.
        locked.set(false)
        _ = try await auth.mintTicket(timeout: .seconds(8))
        #expect(http.requests.filter { $0.path == Self.refreshPath }.count == 1)
        #expect(vault.peek()?.nous?.refreshToken == "rt-new")
        #expect(http.requests.filter { $0.path == Self.ticketPath }.last?.authorization == "Bearer at-new")
    }

    /// A token past its expiry while locked fails as `keychain-locked` (not a sign-out): the connection's ladder asks
    /// again, and the session survives.
    @Test func anExpiredTokenWhileLockedIsNotASignOut() async throws {
        let http = try server()
        let port = try await http.start()
        defer { http.stop() }
        let locked = Locked(true)
        let (auth, vault, transport) = try rig("expired", port: port, left: -30, locked: locked)
        defer { transport.invalidate(); vault.removeAll() }

        await #expect(throws: GatewayFailure.keychainLocked) { _ = try await auth.mintTicket(timeout: .seconds(8)) }
        #expect(!GatewayFailure.keychainLocked.isRejection)
        #expect(await auth.rejection == nil)
        #expect(http.requests.isEmpty)
        #expect(vault.peek()?.nous?.refreshToken == "rt-old")
    }

    /// The rotation holds the app awake (iOS background time) from before the request until the successor is written,
    /// so a suspension can't fall between Portal's answer and Keychain.
    @Test func theRotationIsHeldAwakeUntilItIsWritten() async {
        let events = Locked<[String]>([])
        let renewals = NousRenewals(hold: { name in
            events.mutate { $0.append("hold \(name)") }
            return { events.mutate { $0.append("release") } }
        })
        let first = NousTokens(accessToken: "at1", refreshToken: "rt1", expiresAt: 2_000_000_000, userId: "u1", obtainedAt: 0)
        let second = NousTokens(accessToken: "at2", refreshToken: "rt2", expiresAt: 2_000_000_000, userId: "u1", obtainedAt: 0)
        _ = await renewals.renew("k", first, post: { _ in
            events.mutate { $0.append("post") }
            return .tokens(second)
        }, keep: { _, _ in
            events.mutate { $0.append("keep") }
            return true
        })
        #expect(events.value == ["hold Hermes HQ sign-in renewal", "post", "keep", "release"])

        // A refused or failed rotation lets go too.
        events.set([])
        let other = NousTokens(accessToken: "at3", refreshToken: "rt3", expiresAt: 2_000_000_000, userId: "u1", obtainedAt: 0)
        _ = await renewals.renew("k2", other, post: { _ in .refused }, keep: { _, _ in true })
        #expect(events.value == ["hold Hermes HQ sign-in renewal", "release"])
    }

    /// Why a rotation was not written, for the log: only the odd cases say anything, and never a token.
    @Test func aSkippedRenewalSaysWhyWithoutTokens() {
        let now = Date().timeIntervalSince1970
        let sent = NousTokens(accessToken: "at-sent", refreshToken: "rt-sent", expiresAt: now + 100, userId: "u1", obtainedAt: now - 800)
        let renewed = NousTokens(accessToken: "at-new", refreshToken: "rt-new", expiresAt: now + 900, userId: "u1", obtainedAt: now)
        let other = NousTokens(accessToken: "at-other", refreshToken: "rt-other", expiresAt: now - 3600, userId: "u1", obtainedAt: now - 4500)
        #expect(AccountVault.skippedRenewalNote(held: renewed, sent: sent, renewed: renewed) == nil)
        #expect(AccountVault.skippedRenewalNote(held: sent, sent: sent, renewed: renewed) == nil)
        let gone = AccountVault.skippedRenewalNote(held: nil, sent: sent, renewed: renewed)
        #expect(gone?.contains("no saved sign-in") == true)
        let another = AccountVault.skippedRenewalNote(held: other, sent: sent, renewed: renewed) ?? ""
        #expect(another.contains("another pair") && another.contains("expired"))
        for secret in ["at-", "rt-"] { #expect(!another.contains(secret) && !(gone ?? "").contains(secret)) }
    }

    /// The saved pair's age at launch: the line that would have shown a launch reading a pair already due 47 s after
    /// the last run renewed it (a stale copy in Keychain).
    @Test func thePairsAgeReadsPlainly() {
        let now = 1_800_000_000.0
        func pair(age: Double, life: Double = 900) -> NousTokens {
            NousTokens(accessToken: "secret-at", refreshToken: "secret-rt", expiresAt: now - age + life, userId: "u1", obtainedAt: now - age)
        }
        #expect(pair(age: 47).ageNote(now: now) == "47 s old of 900 s, fresh")
        #expect(pair(age: 600).ageNote(now: now) == "10 min old of 900 s, renews alongside")
        #expect(pair(age: 860).ageNote(now: now) == "14 min old of 900 s, renewal due")
        #expect(pair(age: 7 * 3600).ageNote(now: now) == "7 h old of 900 s, expired")
        #expect(pair(age: 3 * 86_400).ageNote(now: now) == "3 d old of 900 s, expired")
        var bare = pair(age: 10)
        bare.obtainedAt = nil
        #expect(bare.ageNote(now: now) == "no issue time")
        #expect(!pair(age: 47).ageNote(now: now).contains("secret"))
    }
}
