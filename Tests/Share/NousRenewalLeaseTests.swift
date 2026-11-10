// [reliability] B16: one Nous renewal at a time across the app and the Share extension (ShareKit/NousRenewalLease.swift),
// and the share using the app's pair after a refusal that was a race.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

nonisolated func leaseFolder(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lease-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite(.serialized) struct NousRenewalLeaseTests {
    @Test func oneProcessAtATimeAndAStaleLeaseIsTakenOver() throws {
        let dir = leaseFolder("basics")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try #require(NousRenewalLease.acquire(account: "a", in: dir))
        #expect(NousRenewalLease.acquire(account: "a", in: dir)?.token == nil, "a second taker waits")
        #expect(NousRenewalLease.acquire(account: "b", in: dir)?.token != nil, "another account is not held up")
        // A lease whose process went away mid-renewal is ignored after 20 s.
        #expect(NousRenewalLease.acquire(account: "a", in: dir, now: Date().addingTimeInterval(25))?.token != nil)
        // The first lease no longer owns the file: its release leaves the newer one alone.
        first.release()
        #expect(NousRenewalLease.acquire(account: "a", in: dir)?.token == nil)
        // Without an App Group there is no one to wait for.
        #expect(NousRenewalLease.acquire(account: "a", in: nil)?.token != nil)
    }

    @Test func aWaiterUsesTheOtherProcesssPairOrTakesOverAfterItsWait() async throws {
        let dir = leaseFolder("wait")
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = try #require(NousRenewalLease.acquire(account: "a", in: dir))
        let landed = Mutex(false)
        Task { try? await Task.sleep(for: .milliseconds(400)); landed.withLock { $0 = true }; other.release() }
        let began = Date()
        let (lease, adopted) = await NousRenewalLease.acquireOrWait(account: "a", in: dir) { landed.withLock { $0 } }
        #expect(adopted && lease?.token == nil)
        #expect(Date().timeIntervalSince(began) < 3)
        // Nothing lands: after the longest wait the waiter goes ahead anyway.
        let stuck = try #require(NousRenewalLease.acquire(account: "a", in: dir))
        defer { stuck.release() }
        let (late, never) = await NousRenewalLease.acquireOrWait(account: "a", in: dir, longestWait: 0.6) { false }
        #expect(!never && late?.token != nil)
    }
}

@Suite(.serialized) struct ShareRenewalRaceTests {
    @Test func aShareWaitsForTheAppsRenewalInsteadOfReplayingThePair() async throws {
        let dir = leaseFolder("share-waits")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = ShareStubGateway()
        let now = Date().timeIntervalSince1970
        let keychain = gateway.keychain(nous: ShareSamples.nous(expiresAt: now + 5, user: "u1", obtainedAt: now - 3600), username: "nous:u1")
        gateway.onHTTP { seen in seen.path == "/auth/native/refresh" ? .status(401) : nil }       // a replay would be fatal
        // The app is renewing this pair: it holds the lease, and its new pair reaches the Keychain a moment later.
        let key = ShareRules.accountKey(url: gateway.url, username: "nous:u1")
        let app = try #require(NousRenewalLease.acquire(account: key, in: dir))
        let fresh = ShareSamples.item(url: gateway.url, username: "nous:u1", cookies: nil, nous: ShareSamples.nous(access: "nat_app", refresh: "nrt_app", user: "u1"))
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            keychain.set(json: fresh)
            app.release()
        }
        let sender = gateway.sender(keychain)
        sender.leaseDirectory = dir
        _ = try await sender.send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: gateway.roster(username: "nous:u1"))
        #expect(gateway.count("POST /auth/native/refresh") == 0, "the share never sent the pair the app was spending")
        #expect(gateway.event("GET /api/auth/me")?.headers["Authorization"] == "Bearer nat_app")
    }

    @Test func aRefusalThatWasARaceUsesTheAppsPair() async throws {
        // Outside the lease (an older app build): the app spent the pair while the share's renewal was out, and its
        // successor is in the Keychain when the refusal comes back.
        let gateway = ShareStubGateway()
        let now = Date().timeIntervalSince1970
        let keychain = gateway.keychain(nous: ShareSamples.nous(expiresAt: now + 5, user: "u1", obtainedAt: now - 3600), username: "nous:u1")
        gateway.onHTTP { seen in seen.path == "/auth/native/refresh" ? .status(401) : nil }
        let fresh = ShareSamples.item(url: gateway.url, username: "nous:u1", cookies: nil, nous: ShareSamples.nous(access: "nat_app", refresh: "nrt_app", user: "u1"))
        let swapping = SwappingKeychain(keychain, after: 2, with: fresh)
        let sender = ShareSender(keychain: swapping, interfaces: { [] }, protocols: [ShareStubProtocol.self], connect: gateway.connect)
        sender.leaseDirectory = nil
        _ = try await sender.send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: gateway.roster(username: "nous:u1"))
        #expect(gateway.count("POST /auth/native/refresh") == 1)
        #expect(gateway.event("GET /api/auth/me")?.headers["Authorization"] == "Bearer nat_app")
        #expect(keychain.counts.updates == 0, "the app's pair is left as the app wrote it")
    }
}

/// [reliability] B16 with [n20 B1]: a renewal held because the phone is locked never takes or waits on the lease, so
/// the Share extension can renew meanwhile; once unlocked, the app waits for the extension's lease and uses its pair.
/// No refresh token is sent by the app at any point.
@Suite("Locked phone and the share's renewal", .serialized)
nonisolated struct LockedRenewalWithShareTests {
    @Test func aLockedAppLeavesTheLeaseFreeAndThenUsesTheSharesPair() async throws {
        let signOut = SignOutAfterUpdateTests()
        let http = try signOut.server()
        let port = try await http.start()
        defer { http.stop() }
        let locked = Locked(true)
        let (auth, vault, transport) = try signOut.rig("lease-locked", port: port, left: 40, locked: locked)
        defer { transport.invalidate(); vault.removeAll() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lease-locked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        await auth.useLeaseDirectory(dir)
        let stored = try #require(vault.peek())
        let refreshes = { http.requests.filter { $0.path == SignOutAfterUpdateTests.refreshPath }.count }

        // Locked, with the share holding the lease: the app neither renews nor waits out the lease's 16 s.
        let share = try #require(NousRenewalLease.acquire(account: stored.key, in: dir))
        let began = ContinuousClock.now
        #expect(try await auth.mintTicket(timeout: .seconds(8)) == "t-1")
        #expect(began.duration(to: .now) < .seconds(5), "the locked hold doesn't wait on the lease")
        #expect(refreshes() == 0)
        #expect(http.requests.first { $0.path == SignOutAfterUpdateTests.ticketPath }?.authorization == "Bearer at-old")

        // The share's renewal lands while the app is still waiting for the lease; then the phone is unlocked.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            var renewed = stored
            let now = Date().timeIntervalSince1970
            renewed.nous = NousTokens(accessToken: "at-share", refreshToken: "rt-share", expiresAt: now + 900, userId: "u1", obtainedAt: now)
            try? vault.save(renewed)
            share.release()
        }
        locked.set(false)
        #expect(try await auth.mintTicket(timeout: .seconds(12)) == "t-1")
        #expect(refreshes() == 0, "the app never sent the pair the share spent")
        #expect(http.requests.filter { $0.path == SignOutAfterUpdateTests.ticketPath }.last?.authorization == "Bearer at-share")
        #expect(vault.peek()?.nous?.refreshToken == "rt-share")
        #expect(await auth.rejection == nil)
        // The lease is free again for whoever renews next.
        #expect(NousRenewalLease.acquire(account: stored.key, in: dir) != nil)
    }
}
