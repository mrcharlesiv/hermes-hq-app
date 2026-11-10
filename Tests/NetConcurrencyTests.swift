import Foundation
import Synchronization
import Testing
import UIKit
@testable import HermesHQNative

/// A counter several tasks touch.
nonisolated final class Tally: Sendable {
    private let state = Mutex((now: 0, peak: 0, total: 0, order: [Int]()))
    func enter(_ tag: Int) {
        state.withLock { s in s.now += 1; s.total += 1; s.peak = max(s.peak, s.now); s.order.append(tag) }
    }
    func leave() { state.withLock { $0.now -= 1 } }
    var peak: Int { state.withLock { $0.peak } }
    var total: Int { state.withLock { $0.total } }
    var order: [Int] { state.withLock { $0.order } }
}

@Suite struct TicketLaneTests {
    /// One ws-ticket request in flight at a time; later dials wait their turn in FIFO order (spec 01 §9.2).
    @Test func oneTicketInFlightInArrivalOrder() async throws {
        let lane = AsyncLane()
        let tally = Tally()
        await lane.enter() // the first dial holds the lane
        var tasks: [Task<Void, Never>] = []
        for tag in 1...6 {
            tasks.append(Task.detached {
                await lane.enter()
                tally.enter(tag)
                try? await Task.sleep(for: .milliseconds(15))
                tally.leave()
                lane.leave()
            })
            // Let this waiter queue up before the next one arrives.
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tally.total == 0)
        lane.leave()
        for task in tasks { await task.value }
        #expect(tally.peak == 1)
        #expect(tally.order == [1, 2, 3, 4, 5, 6])
        #expect(!lane.isBusy)
    }

    @Test func manyConcurrentMintsNeverOverlap() async {
        let lane = AsyncLane()
        let tally = Tally()
        await withTaskGroup(of: Void.self) { group in
            for tag in 0..<40 {
                group.addTask {
                    await lane.enter()
                    tally.enter(tag)
                    await Task.yield()
                    tally.leave()
                    lane.leave()
                }
            }
        }
        #expect(tally.peak == 1 && tally.total == 40)
    }
}

@Suite struct RefreshSingleFlightTests {
    func pair(_ n: Int, user: String = "u1") -> NousTokens {
        NousTokens(accessToken: "at\(n)", refreshToken: "rt\(n)", expiresAt: 2_000_000_000, userId: user, obtainedAt: 1_999_999_000)
    }

    /// Concurrent askers share one rotation: Portal sees the refresh token exactly once (spec 01 §7.3 rule 1).
    @Test func concurrentRenewalsPostOnce() async {
        let renewals = NousRenewals()
        let posts = Tally()
        let kept = Tally()
        let first = pair(1), second = pair(2)
        let outcomes = await withTaskGroup(of: NousRenewals.Outcome.self, returning: [NousRenewals.Outcome].self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await renewals.renew("k", first, post: { sent in
                        posts.enter(0)
                        try? await Task.sleep(for: .milliseconds(50))
                        return sent.refreshToken == "rt1" ? .tokens(second) : .refused
                    }, keep: { _, _ in kept.enter(0); return true })
                }
            }
            var all: [NousRenewals.Outcome] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        #expect(posts.total == 1)
        #expect(kept.total == 1)
        for outcome in outcomes {
            guard case .tokens(let tokens) = outcome else { Issue.record("not tokens: \(outcome)"); continue }
            #expect(tokens.samePair(second))
        }
    }

    /// A caller still holding a spent pair gets its successor and sends nothing (rules 2–3: never replay).
    @Test func spentPairIsNeverSentAgain() async {
        let renewals = NousRenewals()
        let posts = Tally()
        let post: @Sendable (NousTokens) async -> NousRenewals.Outcome = { sent in
            posts.enter(0)
            let n = Int(sent.refreshToken.dropFirst(2))!
            return .tokens(NousTokens(accessToken: "at\(n + 1)", refreshToken: "rt\(n + 1)", expiresAt: 2_000_000_000, userId: "u1", obtainedAt: 0))
        }
        _ = await renewals.renew("k", pair(1), post: post, keep: { _, _ in true })
        _ = await renewals.renew("k", pair(2), post: post, keep: { _, _ in true })
        #expect(posts.total == 2)
        // A reader that saw pair 1 (an old Keychain copy) asks again: it is handed pair 3, no request.
        let stale = await renewals.renew("k", pair(1), post: post, keep: { _, _ in true })
        guard case .tokens(let live) = stale else { Issue.record("no tokens"); return }
        #expect(live.refreshToken == "rt3")
        #expect(posts.total == 2)
        #expect(await renewals.isSpent(pair(1)))
        #expect(await renewals.latest(pair(1)).refreshToken == "rt3")
    }

    /// [phone-logs] A caller holding a spent pair whose successor has itself expired gets that successor renewed (its
    /// unspent refresh token, once), not the expired successor: that was a 401 and a second renewal on every news check.
    @Test func anExpiredSuccessorIsRenewedNotHandedOver() async {
        let renewals = NousRenewals(hold: { _ in { } })
        let posted = Locked<[String]>([])
        let now = Date().timeIntervalSince1970
        let expired = NousTokens(accessToken: "at2", refreshToken: "rt2", expiresAt: now - 60, userId: "u1", obtainedAt: now - 960)
        let fresh = NousTokens(accessToken: "at3", refreshToken: "rt3", expiresAt: now + 900, userId: "u1", obtainedAt: now)
        let post: @Sendable (NousTokens) async -> NousRenewals.Outcome = { sent in
            posted.mutate { $0.append(sent.refreshToken) }
            return .tokens(sent.refreshToken == "rt1" ? expired : fresh)
        }
        _ = await renewals.renew("k", pair(1), post: post, keep: { _, _ in true })     // rt1 → the pair that later expires
        let outcome = await renewals.renew("k", pair(1), post: post, keep: { _, _ in true })
        guard case .tokens(let live) = outcome else { Issue.record("no tokens"); return }
        #expect(live.samePair(fresh))
        #expect(posted.value == ["rt1", "rt2"], "rt1 is never sent twice; the successor's rt2 once")
    }

    /// A rotation Keychain couldn't take is kept and written on the next background transition (rule 5).
    @Test func unsavedRotationsAreRetried() async {
        let renewals = NousRenewals()
        let second = pair(2)
        _ = await renewals.renew("k", pair(1), post: { _ in .tokens(second) }, keep: { _, _ in false })
        let written = Tally()
        await renewals.retryUnsaved { key, sent, renewed in
            #expect(key == "k" && sent.refreshToken == "rt1" && renewed.refreshToken == "rt2")
            written.enter(0)
            return true
        }
        await renewals.retryUnsaved { _, _, _ in written.enter(1); return true }
        #expect(written.total == 1)
    }

    /// A rotation made while locked is written by its own `keep` once the device unlocks (a Mac renewing in a dark
    /// wake, then relaunched by an update more than 5 minutes later, was signed out with the spent pair).
    @Test func unsavedRotationIsWrittenOnUnlock() async {
        let renewals = NousRenewals()
        let locked = Tally(), written = Tally()
        let unlocked = Locked(false), second = pair(2)
        _ = await renewals.renew("k", pair(1), post: { _ in .tokens(second) }, keep: { sent, renewed in
            guard unlocked.value else { locked.enter(0); return false }
            #expect(sent.refreshToken == "rt1" && renewed.refreshToken == "rt2")
            written.enter(0)
            return true
        })
        #expect(locked.total == 1 && written.total == 0)
        await renewals.retryUnsaved()
        #expect(locked.total == 2 && written.total == 0)
        unlocked.set(true)
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        for _ in 0..<100 where written.total == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(written.total == 1)
        await renewals.retryUnsaved()
        #expect(written.total == 1)
    }

    /// Another account's tokens in a rotation are never adopted.
    @Test func otherUsersTokensAreNotRemembered() async {
        let renewals = NousRenewals()
        let intruder = pair(9, user: "intruder")
        let outcome = await renewals.renew("k", pair(1), post: { _ in .tokens(intruder) }, keep: { _, _ in true })
        guard case .tokens = outcome else { Issue.record("expected the raw outcome"); return }
        #expect(!(await renewals.isSpent(pair(1))))
    }
}

@Suite struct BroadcastTests {
    @Test func everySubscriberGetsEveryEventInOrder() async {
        let hub = Broadcast<Int>()
        let a = hub.subscribe(), b = hub.subscribe()
        for n in 1...5 { hub.yield(n) }
        hub.finish()
        var seenA: [Int] = [], seenB: [Int] = []
        for await n in a { seenA.append(n) }
        for await n in b { seenB.append(n) }
        #expect(seenA == [1, 2, 3, 4, 5] && seenB == seenA)
        // Subscribing after finish ends at once.
        var late = 0
        for await _ in hub.subscribe() { late += 1 }
        #expect(late == 0)
    }

    @Test func stateHubYieldsTheCurrentStateFirstAndSkipsRepeats() async {
        let hub = StateHub(.connecting)
        #expect(hub.set(.ready))
        #expect(!hub.set(.ready))
        let stream = hub.subscribe()
        hub.set(.reconnecting(attempt: 1))
        hub.set(.ready)
        hub.finish()
        var seen: [ConnectionState] = []
        for await state in stream { seen.append(state) }
        #expect(seen == [.ready, .reconnecting(attempt: 1), .ready])
    }

    @Test func droppedSubscribersAreForgotten() async throws {
        let hub = Broadcast<Int>()
        var stream: AsyncStream<Int>? = hub.subscribe()
        #expect(hub.subscriberCount == 1)
        let task = Task { [stream] in for await _ in stream! {} }
        task.cancel()
        _ = await task.value
        stream = nil
        try await Task.sleep(for: .milliseconds(50))
        #expect(hub.subscriberCount == 0)
    }

    @Test func aFilteredSubscriberGetsOnlyWhatItWantsInOrder() async throws {
        let hub = Broadcast<Int>()
        let evens = hub.subscribe(where: { $0 % 2 == 0 }), all = hub.subscribe()
        for n in 1...8 { hub.yield(n) }
        hub.finish()
        var seenEvens: [Int] = [], seenAll: [Int] = []
        for await n in evens { seenEvens.append(n) }
        for await n in all { seenAll.append(n) }
        #expect(seenEvens == [2, 4, 6, 8])
        #expect(seenAll == Array(1...8))

        let other = Broadcast<Int>()
        var filtered: AsyncStream<Int>? = other.subscribe(where: { $0 > 0 })
        #expect(other.subscriberCount == 1)
        let task = Task { [filtered] in for await _ in filtered! {} }
        task.cancel()
        _ = await task.value
        filtered = nil
        try await Task.sleep(for: .milliseconds(50))
        #expect(other.subscriberCount == 0)
    }

    @Test func aFakeClientsMatchingStreamFiltersItsEvents() async {
        let client = BotsFakeGatewayClient()
        let stream = client.events(matching: ["display.status"])
        #expect(await BotsTest.waitUntil { client.subscriberCount == 1 })
        client.emit("message.delta")
        client.emit("display.status", payload: ["n": 1])
        client.emit("tool.complete")
        client.emit("display.status", payload: ["n": 2])
        var seen: [Double] = []
        for await event in stream {
            seen.append(event.payload["n"]?.double ?? -1)
            if seen.count == 2 { break }
        }
        #expect(seen == [1, 2])
    }
}

// MARK: - [renew-alongside] A valid Nous token past half its lifetime renews beside the request, not before it

/// Against `LoopbackHTTP` (127.0.0.1, an OS-assigned port, this process only). The refresh answer can be held so the
/// ticket's timing shows whether it waited (spec 01 §7.1, rules 7.3).
@Suite("Nous renewal alongside the request", .serialized)
nonisolated struct RenewAlongsideTests {
    static let ticketPath = "/api/auth/ws-ticket", refreshPath = "/auth/native/refresh"

    static func renewedBody(_ name: String, user: String = "u1") -> Data {
        let now = Date().timeIntervalSince1970
        return try! JSONSerialization.data(withJSONObject: ["access_token": "at-\(name)", "refresh_token": "rt-\(name)",
                                                            "user_id": user, "provider": "nous", "expires_at": now + 900])
    }

    /// A saved Nous account whose access token has `left` seconds of a `lifetime` (phone clock).
    func rig(_ name: String, port: UInt16, left: Double, lifetime: Double = 900) throws -> (GatewayAuth, AccountVault, HTTPTransport) {
        let now = Date().timeIntervalSince1970
        let tokens = NousTokens(accessToken: "at-old", refreshToken: "rt-old", expiresAt: now + left, userId: "u1",
                                obtainedAt: now + left - lifetime)
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: StoredAccount.nousUsername(userId: "u1"), nous: tokens)
        let vault = Fixtures.testVault("renew-alongside-\(name)")
        vault.removeAll()
        try vault.save(stored)
        let transport = HTTPTransport()
        let auth = GatewayAuth(stored: stored, base: URL(string: stored.url)!, transport: transport, vault: vault,
                               verified: true, renewals: NousRenewals())
        return (auth, vault, transport)
    }

    @Test func aValidButDueTokenSendsAtOnceAndRenewsAlongside() async throws {
        let server = try LoopbackHTTP(delay: { $0.path == Self.refreshPath ? 3 : 0 }) { request in
            switch request.path {
            case Self.ticketPath: return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            case Self.refreshPath: return (200, Self.renewedBody("new"))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        // 300 s of 900 left: past half its lifetime, well before its last minute.
        let (auth, vault, transport) = try rig("due", port: port, left: 300)
        defer { transport.invalidate(); vault.removeAll() }
        let began = ContinuousClock.now
        let ticket = try await auth.mintTicket(timeout: .seconds(8))
        #expect(ticket == "t-1")
        // (Well under the refresh's 3 s: a busy simulator's Keychain can hold this actor for a moment.)
        #expect(began.duration(to: .now) < .seconds(2), "the ticket waited for the renewal")
        #expect(await auth.refreshesRun == 0)
        #expect(await auth.renewalsAlongside == 1)
        #expect(server.requests.first { $0.path == Self.ticketPath }?.authorization == "Bearer at-old")
        // A transfer meanwhile joins nothing and waits for nothing either.
        let (_, sentAccess) = try await auth.prepareTransfer(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/files/x")!))
        #expect(sentAccess == "at-old")
        #expect(await auth.renewalsAlongside == 1, "a second renewal started while one was in flight")
        // The rotation lands, is persisted (rule 3) and carries the next request.
        try await eventually(within: 8, "the renewed pair") { vault.peek()?.nous?.accessToken == "at-new" }
        for _ in 0..<50 where await auth.stored.nous?.accessToken != "at-new" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await auth.stored.nous?.accessToken == "at-new")
        _ = try await auth.mintTicket(timeout: .seconds(8))
        #expect(server.requests.filter { $0.path == Self.ticketPath }.last?.authorization == "Bearer at-new")
        #expect(server.requests.filter { $0.path == Self.refreshPath }.count == 1)
        #expect(await auth.renewalsAlongside == 1, "a fresh pair renewed again")
    }

    @Test func aTokenInItsLastMinuteStillWaitsForTheRenewal() async throws {
        let server = try LoopbackHTTP(delay: { $0.path == Self.refreshPath ? 0.5 : 0 }) { request in
            switch request.path {
            case Self.ticketPath: return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            case Self.refreshPath: return (200, Self.renewedBody("new"))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        for (name, left) in [("last-minute", 30.0), ("expired", -10.0)] {
            let (auth, vault, transport) = try rig(name, port: port, left: left)
            defer { transport.invalidate(); vault.removeAll() }
            let before = server.requests.count
            let began = ContinuousClock.now
            _ = try await auth.mintTicket(timeout: .seconds(8))
            #expect(began.duration(to: .now) >= .milliseconds(450), "\(name): the ticket did not wait")
            #expect(await auth.refreshesRun == 1)
            #expect(await auth.renewalsAlongside == 0)
            let mine = server.requests.dropFirst(before).map { "\($0.path) \($0.authorization ?? "-")" }
            #expect(mine == ["\(Self.refreshPath) -", "\(Self.ticketPath) Bearer at-new"], "\(name)")
        }
    }

    /// [ticket-deadline] An expired token whose renewal failed (not refused) is not sent: the gateway could only answer
    /// 401 and start a second renewal. The caller's ladder asks again.
    @Test func anExpiredTokenWhoseRenewalFailedSendsNoTicket() async throws {
        let server = try LoopbackHTTP { request in
            switch request.path {
            case Self.ticketPath: return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            case Self.refreshPath: return (503, Data(#"{"error":"unavailable"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (auth, vault, transport) = try rig("expired-fails", port: port, left: -10)
        defer { transport.invalidate(); vault.removeAll() }
        await #expect(throws: (any Error).self) { _ = try await auth.mintTicket(timeout: .seconds(8)) }
        #expect(!server.requests.contains { $0.path == Self.ticketPath })
        #expect(server.requests.filter { $0.path == Self.refreshPath }.count == 1)
        #expect(await auth.rejection == nil)
    }

    /// Log study 2026-10-28, 1:24 PM: Nous was down, the dial asked for a ticket every 3 s, and each ask spent the same
    /// expired pair on a refresh (503, 503, 503, then 401 session_expired: signed out). An unfinished refresh now rests
    /// that pair, longer after each miss; asks in between fail at once without reaching the gateway.
    @Test func anUnfinishedRefreshRestsThePairBeforeTryingAgain() async throws {
        let server = try LoopbackHTTP { request in
            switch request.path {
            case Self.ticketPath: return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            case Self.refreshPath: return (503, Data(#"{"error":"refused","detail":"Auth provider 'nous' unreachable"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (auth, vault, transport) = try rig("unfinished-rests", port: port, left: -10)
        defer { transport.invalidate(); vault.removeAll() }
        for _ in 0..<4 {
            await #expect(throws: GatewayFailure.unavailable) { _ = try await auth.mintTicket(timeout: .seconds(8)) }
        }
        #expect(server.requests.filter { $0.path == Self.refreshPath }.count == 1, "asks inside the rest reached the gateway")
        #expect(!server.requests.contains { $0.path == Self.ticketPath })
        #expect(await auth.rejection == nil)
        #expect(vault.peek()?.nous?.refreshToken == "rt-old")
    }

    /// Hermes's `refresh_pending` 503 (Portal still rotating) says when to ask again: the same pair rests that long, not
    /// the ladder's 5 s, and then goes out again and gets the rotated pair the gateway kept for it.
    @Test func aRefreshPendingRetryAfterSetsTheRest() async throws {
        let refreshes = Tally()
        let server = try LoopbackHTTP(headers: { $0.path == Self.refreshPath && refreshes.total == 1 ? ["Retry-After": "1"] : [:] }) { request in
            switch request.path {
            case Self.ticketPath: return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            case Self.refreshPath:
                refreshes.enter(0)
                return refreshes.total == 1 ? (503, Data(#"{"error":"refresh_pending","retry_after":1}"#.utf8)) : (200, Self.renewedBody("new"))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (auth, vault, transport) = try rig("pending-retry-after", port: port, left: -10)
        defer { transport.invalidate(); vault.removeAll() }
        await #expect(throws: GatewayFailure.unavailable) { _ = try await auth.mintTicket(timeout: .seconds(8)) }
        await #expect(throws: GatewayFailure.unavailable) { _ = try await auth.mintTicket(timeout: .seconds(8)) }
        #expect(refreshes.total == 1, "an ask inside the rest reached the gateway")
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(try await auth.mintTicket(timeout: .seconds(8)) == "t-1")
        #expect(refreshes.total == 2)
        #expect(await auth.rejection == nil)
        #expect(vault.peek()?.nous?.refreshToken == "rt-new")
    }

    /// …but a token in its last minute still has time: it goes out (the deliberate behaviour).
    @Test func aLastMinuteTokenWhoseRenewalFailedStillSends() async throws {
        let server = try LoopbackHTTP { request in
            switch request.path {
            case Self.ticketPath: return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            case Self.refreshPath: return (503, Data(#"{"error":"unavailable"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (auth, vault, transport) = try rig("last-minute-fails", port: port, left: 30)
        defer { transport.invalidate(); vault.removeAll() }
        #expect(try await auth.mintTicket(timeout: .seconds(8)) == "t-1")
        #expect(server.requests.first { $0.path == Self.ticketPath }?.authorization == "Bearer at-old")
    }

    /// …even with seconds left: the phone's clock may run ahead of Portal's, so only a token past the margin is dropped.
    @Test func aTokenWithSecondsLeftWhoseRenewalFailedStillSends() async throws {
        let server = try LoopbackHTTP { request in
            switch request.path {
            case Self.ticketPath: return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            case Self.refreshPath: return (503, Data(#"{"error":"unavailable"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (auth, vault, transport) = try rig("seconds-left-fails", port: port, left: 3)
        defer { transport.invalidate(); vault.removeAll() }
        #expect(try await auth.mintTicket(timeout: .seconds(8)) == "t-1")
        #expect(server.requests.first { $0.path == Self.ticketPath }?.authorization == "Bearer at-old")
    }

    @Test func a401WhileRenewingAlongsideJoinsThatRenewal() async throws {
        let server = try LoopbackHTTP(delay: { $0.path == Self.refreshPath ? 1.0 : 0 }) { request in
            switch request.path {
            case Self.ticketPath:
                return request.authorization == "Bearer at-new" ? (200, Data(#"{"ticket":"t-2"}"#.utf8))
                                                                 : (401, Data(#"{"detail":"Not authenticated"}"#.utf8))
            case Self.refreshPath: return (200, Self.renewedBody("new"))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (auth, vault, transport) = try rig("join", port: port, left: 300)
        defer { transport.invalidate(); vault.removeAll() }
        let ticket = try await auth.mintTicket(timeout: .seconds(8))
        #expect(ticket == "t-2")
        #expect(server.requests.filter { $0.path == Self.refreshPath }.count == 1, "a second rotation started")
        #expect(server.requests.filter { $0.path == Self.ticketPath }.map { $0.authorization ?? "-" } == ["Bearer at-old", "Bearer at-new"])
        #expect(await auth.refreshesRun == 1)                 // the 401 waited for the renewal it joined
        #expect(await auth.rejection == nil)
        #expect(vault.peek()?.nous?.accessToken == "at-new")
    }

    @Test(arguments: [503, 429])
    func aFailedRenewalAlongsideKeepsTheValidToken(status: Int) async throws {
        let server = try LoopbackHTTP { request in
            switch request.path {
            case Self.ticketPath: return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            case Self.refreshPath: return (status, Data(#"{"error":"rate_limited"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (auth, vault, transport) = try rig("fails-\(status)", port: port, left: 300)
        defer { transport.invalidate(); vault.removeAll() }
        _ = try await auth.mintTicket(timeout: .seconds(8))
        try await eventually(within: 5, "the renewal's answer") { server.requests.contains { $0.path == Self.refreshPath } }
        try await Task.sleep(for: .milliseconds(200))
        for _ in 0..<3 { #expect(try await auth.mintTicket(timeout: .seconds(8)) == "t-1") }
        // One attempt, then a rest: a failing renewal is not retried on every request (the edge's 20 a minute).
        #expect(server.requests.filter { $0.path == Self.refreshPath }.count == 1)
        #expect(server.requests.filter { $0.path == Self.ticketPath }.allSatisfy { $0.authorization == "Bearer at-old" })
        #expect(await auth.rejection == nil)
        #expect(vault.peek()?.nous?.accessToken == "at-old")
    }

    /// 2026-10-23 (build 356 launch): a refusal right after another process (the Share extension) spent the same pair
    /// and saved its successor is a race, not an ended session. The Keychain is read once more and its newer pair used:
    /// as it is when still fresh, renewed when due. A pair that is refused too still signs out (the test above).
    @Test func aRefusalRacingAnotherProcessesRotationUsesThePairItSaved() async throws {
        for (name, shareLeft) in [("fresh", 600.0), ("due", -5.0)] {
            let vaultBox = Mutex<AccountVault?>(nil)
            let server = try LoopbackHTTP { request in
                switch request.path {
                case Self.ticketPath: return (200, Data(#"{"ticket":"t-1"}"#.utf8))
                case Self.refreshPath:
                    let body = String(decoding: request.body, as: UTF8.self)
                    guard body.contains("rt-old") else { return (200, Self.renewedBody("after-share")) }
                    // The other process rotated rt-old first and saved its pair; ours arrives second and is refused.
                    if let vault = vaultBox.withLock({ $0 }) {
                        let now = Date().timeIntervalSince1970
                        let theirs = NousTokens(accessToken: "at-share", refreshToken: "rt-share", expiresAt: now + shareLeft,
                                                userId: "u1", obtainedAt: now + shareLeft - 900)
                        _ = try? vault.update(vault.peek()!.key) { $0.nous = theirs }
                    }
                    return (401, Data(#"{"error":"session_expired"}"#.utf8))
                default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
                }
            }
            let port = try await server.start()
            defer { server.stop() }
            let (auth, vault, transport) = try rig("share-race-\(name)", port: port, left: -10)
            vaultBox.withLock { $0 = vault }
            defer { transport.invalidate(); vault.removeAll() }
            #expect(try await auth.mintTicket(timeout: .seconds(8)) == "t-1", "\(name)")
            #expect(await auth.rejection == nil, "\(name)")
            let expected = name == "fresh" ? "at-share" : "at-after-share"
            #expect(server.requests.filter { $0.path == Self.ticketPath }.last?.authorization == "Bearer \(expected)", "\(name)")
            #expect(server.requests.filter { $0.path == Self.refreshPath }.count == (name == "fresh" ? 1 : 2), "\(name)")
            #expect(vault.peek()?.nous?.accessToken == expected, "\(name)")
        }
    }

    @Test func aRefusedRenewalAlongsideSignsOut() async throws {
        let server = try LoopbackHTTP(delay: { $0.path == Self.refreshPath ? 0.3 : 0 }) { request in
            switch request.path {
            case Self.ticketPath: return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            case Self.refreshPath: return (401, Data(#"{"error":"session_expired"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (auth, vault, transport) = try rig("refused", port: port, left: 300)
        defer { transport.invalidate(); vault.removeAll() }
        let told = Mutex<GatewayFailure?>(nil)
        await auth.setRejectionHandler { failure in told.withLock { $0 = failure } }
        #expect(try await auth.mintTicket(timeout: .seconds(8)) == "t-1")   // sent at once with the still-valid token
        try await eventually(within: 5, "the refusal") { told.withLock { $0 } == .sessionEnded }
        #expect(await auth.rejection == .sessionEnded)
        #expect(vault.peek()?.nous == nil && vault.peek()?.username == "nous:u1")
        await #expect(throws: GatewayFailure.sessionEnded) { _ = try await auth.mintTicket(timeout: .seconds(8)) }
    }

    /// [reliability] B16: the Share extension holds the renewal lease for this account: the app waits for the pair it
    /// saves instead of sending the same refresh token (a replay would end the session).
    @Test func theAppWaitsForTheShareExtensionsRenewal() async throws {
        let server = try LoopbackHTTP { request in
            switch request.path {
            case Self.ticketPath: return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            case Self.refreshPath: return (401, Data(#"{"error":"replayed"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (auth, vault, transport) = try rig("lease", port: port, left: 5)
        defer { transport.invalidate(); vault.removeAll() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lease-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        await auth.useLeaseDirectory(dir)
        let stored = try #require(vault.peek())
        let share = try #require(NousRenewalLease.acquire(account: stored.key, in: dir))
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            var renewed = stored
            let now = Date().timeIntervalSince1970
            renewed.nous = NousTokens(accessToken: "at-share", refreshToken: "rt-share", expiresAt: now + 900, userId: "u1", obtainedAt: now)
            try? vault.save(renewed)
            share.release()
        }
        #expect(try await auth.mintTicket(timeout: .seconds(12)) == "t-1")
        #expect(!server.requests.contains { $0.path == Self.refreshPath }, "the app never replayed the pair")
        #expect(server.requests.first { $0.path == Self.ticketPath }?.authorization == "Bearer at-share")
        #expect(await auth.rejection == nil)
    }

    /// [renewal-cancel] Log 2026-11-02: the news check for a second Hermes Cloud gateway read a chat, which started a
    /// renewal alongside; the read finished first and the probe closed its transport, cancelling the refresh ~1 s in.
    /// Portal had rotated the pair, so the successor was lost and the next use was refused (signed out). Closing now
    /// lets the renewal land in the vault first.
    @Test func closingAProbeLetsItsRenewalAlongsideLand() async throws {
        let server = try LoopbackHTTP(delay: { $0.path == Self.refreshPath ? 1.5 : 0 }) { request in
            switch request.path {
            case Self.refreshPath: return (200, Self.renewedBody("new"))
            case let path where path.hasPrefix("/api/sessions/"): return (200, Data(#"{"id":"s1","messages":[]}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let now = Date().timeIntervalSince1970
        let tokens = NousTokens(accessToken: "at-old", refreshToken: "rt-old", expiresAt: now + 300, userId: "u1", obtainedAt: now - 600)
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: StoredAccount.nousUsername(userId: "u1"), nous: tokens)
        let vault = Fixtures.testVault("renew-alongside-probe-close")
        vault.removeAll()
        defer { vault.removeAll() }
        try vault.save(stored)
        let probe = AccountProbe(stored: stored, vault: vault)
        let began = ContinuousClock.now
        guard case .session = try await probe.session(id: "s1", profile: nil) else { Issue.record("no session answer"); return }
        #expect(began.duration(to: .now) < .seconds(1), "the read waited for the renewal")
        probe.close()
        try await eventually(within: 8, "the renewed pair saved") { vault.peek()?.nous?.accessToken == "at-new" }
        #expect(server.requests.filter { $0.path == Self.refreshPath }.count == 1)
    }
}
