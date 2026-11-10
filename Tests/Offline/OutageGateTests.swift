import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

/// [offline] The outage gate (docs/spec/3x-offline.md §6.1): the web app's `connection-reachability.test.ts` and
/// `connection-reachability-stall.test.ts` cases, plus the window ladder.
@Suite struct OutageGateTests {
    private final class Clock: Sendable {
        let now = Mutex<TimeInterval>(1_000)
        func advance(_ seconds: TimeInterval) { now.withLock { $0 += seconds } }
    }

    private func gate() -> (OutageGate, Clock) {
        let clock = Clock()
        return (OutageGate(now: { clock.now.withLock { $0 } }), clock)
    }

    @Test func outageStartsWhileTheSocketIsDown() {
        let (gate, clock) = gate()
        #expect(gate.admit())
        gate.unreachable()
        #expect(gate.state.down)
        #expect(!gate.admit())                 // reads fail at once
        clock.advance(2)
        #expect(gate.admit())                  // the probe
        #expect(!gate.admit())                 // the next one waits out a longer window
        #expect(gate.heldFailure == .heldUnreachable)
    }

    @Test func probeWindowsDoubleToThirtySeconds() {
        let (gate, clock) = gate()
        gate.unreachable()
        var windows: [TimeInterval] = []
        for _ in 0..<7 {
            let wait = gate.state.probeIn
            windows.append(wait)
            clock.advance(wait - 0.001)
            #expect(!gate.admit())
            clock.advance(0.001)
            #expect(gate.admit())
        }
        #expect(windows.map { ($0 * 10).rounded() / 10 } == [2, 4, 8, 16, 30, 30, 30])
    }

    @Test func aTimeoutWithTheSocketOpenIsABusyGatewayNotAnOutage() {
        let (gate, _) = gate()
        gate.socket(open: true)
        gate.timeout()
        #expect(!gate.state.down)
        #expect(gate.admit())
        gate.unreachable()                     // one read's word against an open socket
        #expect(!gate.state.down)
        #expect(gate.admit())
    }

    @Test func endsWithTheSocketOpeningAnAnswerOrAReturn() {
        let (gate, clock) = gate()
        gate.timeout()                          // socket down: a timeout is an outage
        #expect(!gate.admit())
        gate.socket(open: true)
        #expect(!gate.state.down)
        #expect(gate.admit())
        gate.socket(open: false); gate.timeout(); clock.advance(0.01)
        #expect(!gate.admit())
        gate.reached()
        #expect(gate.admit())
        gate.timeout(); clock.advance(0.01)
        #expect(!gate.admit())
        gate.wake()
        #expect(gate.admit())
    }

    @Test func recoveryResetsTheDoubling() {
        let (gate, clock) = gate()
        gate.unreachable()
        for _ in 0..<4 { clock.advance(gate.state.probeIn); _ = gate.admit() }
        #expect(gate.state.probeIn == 30)
        gate.reached()
        #expect(gate.state == .init(down: false, stalled: false, probeIn: 0, socketOpen: false))
        gate.unreachable()
        #expect(gate.state.probeIn == 2)
    }

    @Test func stallAfterThreeTimeoutsWithTheSocketOpen() {
        let (gate, clock) = gate()
        gate.socket(open: true)
        gate.timeout(); gate.timeout()
        #expect(gate.admit())
        #expect(!gate.state.stalled)
        gate.timeout()
        #expect(gate.state.stalled)
        #expect(gate.heldFailure == .heldTimeout)
        #expect(!gate.admit())
        clock.advance(2)
        #expect(gate.admit())
        #expect(!gate.admit())
        gate.wake()
        #expect(gate.admit())
        gate.reached()
        #expect(!gate.state.stalled)
        #expect(gate.admit())
    }

    @Test func anAnswerBetweenTimeoutsStartsTheCountAgain() {
        let (gate, _) = gate()
        gate.socket(open: true)
        gate.timeout(); gate.timeout(); gate.reached(); gate.timeout(); gate.timeout()
        #expect(!gate.state.stalled)
    }

    @Test func noLongerStalledOnceTheSocketClosesOrReopens() {
        let (gate, _) = gate()
        gate.socket(open: true)
        for _ in 0..<3 { gate.timeout() }
        #expect(gate.state.stalled)
        gate.socket(open: false)
        #expect(gate.state == .init(down: false, stalled: false, probeIn: 0, socketOpen: false))
        #expect(gate.admit())
        gate.socket(open: true)
        for _ in 0..<3 { gate.timeout() }
        gate.socket(open: true)
        #expect(!gate.state.stalled)
    }

    @Test func theSecondFailedDialInARowStartsTheOutage() {
        let (gate, _) = gate()
        gate.dialFailed()
        #expect(!gate.state.down)
        gate.dialFailed()
        #expect(gate.state.down)
        #expect(!gate.admit())
        gate.socket(open: true)                 // an opened socket clears the count
        gate.socket(open: false)
        gate.dialFailed()
        #expect(!gate.state.down)
    }

    @Test func statusesAndFailuresReport() {
        let (gate, _) = gate()
        for status in [502, 503, 504, 520, 521, 522, 523, 524, 525, 526, 530] {
            gate.reached()
            gate.note(status: status)
            #expect(gate.state.down, "\(status)")
        }
        for status in [200, 204, 401, 404, 429, 500] {
            gate.unreachable()
            gate.note(status: status)
            #expect(!gate.state.down, "\(status)")
        }
        gate.note(failure: .tls)
        #expect(!gate.state.down)
        gate.note(failure: .unreachable)
        #expect(gate.state.down)
        gate.reached()
        gate.note(failure: .timeout)
        #expect(gate.state.down)
    }

    @Test func heldFailuresReadAsWordsWithTheStableCodes() {
        #expect(GatewayFailure.heldUnreachable.code == "unreachable")
        #expect(GatewayFailure.heldUnreachable.message == "Can’t reach the computer running Hermes right now. Try again.")
        #expect(GatewayFailure.heldTimeout.code == "timeout")
        #expect(GatewayFailure.heldTimeout.message == "The computer running Hermes isn’t answering right now. Try again in a moment.")
        #expect(GatewayFailure.heldTimeout.isHeld && GatewayFailure.heldUnreachable.isHeld)
        #expect(!GatewayFailure.timeout.isHeld && !GatewayFailure.unreachable.isHeld)
        // The stable codes still name the ordinary failures.
        #expect(GatewayFailure.forCode("unreachable") == .unreachable)
        #expect(GatewayFailure.forCode("timeout") == .timeout)
    }

    /// Many pollers at once: only one probe per window gets through.
    @Test func oneProbePerWindowUnderConcurrentReads() async {
        let (gate, clock) = gate()
        gate.unreachable()
        clock.advance(2)
        let admitted = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<200 { group.addTask { gate.admit() } }
            var count = 0
            for await value in group where value { count += 1 }
            return count
        }
        #expect(admitted == 1)
    }
}

@Suite struct QueryRetryTests {
    @Test func neverAfterATimeout() {
        #expect(!QueryRetry.shouldRetry(failureCount: 0, error: GatewayFailure.timeout))
        #expect(!QueryRetry.shouldRetry(failureCount: 0, error: GatewayFailure.heldTimeout))
        #expect(!QueryRetry.shouldRetry(failureCount: 0, error: URLError(.timedOut)))
        #expect(!QueryRetry.shouldRetry(failureCount: 0, error: RPCError.timedOut("profiles.list", after: .seconds(30))))
        #expect(!QueryRetry.shouldRetry(failureCount: 0, error: RPCError(code: -32000, message: "request timed out after 30s: projects.tree", data: nil)))
        #expect(QueryRetry.timedOut(RPCError(code: -32000, message: "request timed out after 5s", data: nil)))
        #expect(!QueryRetry.timedOut(RPCError(code: -32000, message: "the request timed out after 5s", data: nil)))
    }

    @Test func neverWhileTheGatewayIsUnreachable() {
        for failure in [GatewayFailure.unreachable, .heldUnreachable, .unavailable, .tailscaleOff, .offline, .paused] {
            #expect(!QueryRetry.shouldRetry(failureCount: 0, error: failure), "\(failure.code)")
        }
        for status in [502, 503, 504, 521, 530] {
            #expect(!QueryRetry.shouldRetry(failureCount: 0, error: HTTPError(status: status, body: nil)), "\(status)")
        }
        #expect(!QueryRetry.shouldRetry(failureCount: 0, error: URLError(.cannotConnectToHost)))
        #expect(!QueryRetry.shouldRetry(failureCount: 0, error: URLError(.notConnectedToInternet)))
        #expect(!QueryRetry.shouldRetry(failureCount: 0, error: RPCError.notSent(.socketDead)))
        #expect(!QueryRetry.shouldRetry(failureCount: 0, error: RPCError.connectionLost("profiles.list")))
    }

    @Test func neverAfterACancel() {
        #expect(!QueryRetry.shouldRetry(failureCount: 0, error: CancellationError()))
        #expect(!QueryRetry.shouldRetry(failureCount: 0, error: URLError(.cancelled)))
    }

    @Test func oneQuickRetryForAnythingElse() {
        let others: [any Error] = [HTTPError(status: 500, body: nil), HTTPError(status: 404, body: nil),
                                   RPCError(code: -32000, message: "boom", data: nil), GatewayFailure.gatewayError("x"),
                                   GatewayFailure.tls, URLError(.badServerResponse), URLError(.networkConnectionLost)]
        for (index, error) in others.enumerated() {
            // A dropped connection (-1005) maps to unreachable: the reconnect re-reads.
            let expected = !((error as? URLError)?.code == .networkConnectionLost)
            #expect(QueryRetry.shouldRetry(failureCount: 0, error: error) == expected, "#\(index)")
            #expect(!QueryRetry.shouldRetry(failureCount: 1, error: error), "#\(index) asked a third time")
        }
    }

    @MainActor @Test func readRetriesOnceAfterTheDelay() async throws {
        var calls = 0
        let value = try await QueryRetry.read(delay: .milliseconds(10)) { () async throws -> Int in
            calls += 1
            if calls == 1 { throw HTTPError(status: 500, body: nil) }
            return 7
        }
        #expect(value == 7 && calls == 2)
    }

    @MainActor @Test func readDoesNotRetryATimeoutOrADownGateway() async {
        for error in [GatewayFailure.timeout as any Error, HTTPError(status: 503, body: nil), GatewayFailure.heldUnreachable] {
            var calls = 0
            await #expect(throws: (any Error).self) {
                _ = try await QueryRetry.read(delay: .milliseconds(10)) { () async throws -> Int in
                    calls += 1
                    throw error
                }
            }
            #expect(calls == 1)
        }
    }

    @MainActor @Test func readGivesUpAfterTheOneRetry() async {
        var calls = 0
        await #expect(throws: HTTPError.self) {
            _ = try await QueryRetry.read(delay: .milliseconds(10)) { () async throws -> Int in
                calls += 1
                throw HTTPError(status: 500, body: nil)
            }
        }
        #expect(calls == 2)
    }
}

@Suite struct ReturnGateTests {
    @Test func theFirstActivationIsAReturn() {
        var gate = ReturnGate()
        let first = gate.becameActive()
        #expect(first)
    }

    @Test func aMomentInactiveIsNotAReturn() {
        var gate = ReturnGate()
        _ = gate.becameActive()
        // Control Center, the notification shade, a permission alert: resign-active only.
        for _ in 0..<5 {
            gate.resignedActive(at: Date())
            let returned = gate.becameActive(at: Date().addingTimeInterval(0.2))
            #expect(!returned)
        }
    }

    @Test func howeverLongInactiveWithoutTheBackgroundItIsNotAReturn() {
        var gate = ReturnGate()
        _ = gate.becameActive()
        gate.resignedActive(at: Date())
        let returned = gate.becameActive(at: Date().addingTimeInterval(600))
        #expect(!returned)
    }

    @Test func afterTheBackgroundItIsAReturnOnce() {
        var gate = ReturnGate()
        _ = gate.becameActive()
        gate.resignedActive(); gate.enteredBackground()
        let back = gate.becameActive()
        #expect(back)
        gate.resignedActive()
        let again = gate.becameActive()
        #expect(!again)
        gate.resignedActive(); gate.enteredBackground()
        let third = gate.becameActive()
        #expect(third)
    }
}

/// The gate where it stands: in front of the client's reads (`LiveGatewayClient.send`, §6.1). Nothing listens on
/// port 1 of loopback, so a read that reaches the network fails as unreachable; one the gate turns away fails as held.
@Suite struct OutageGateWiringTests {
    @Test func theClientHoldsReadsWhileTheGatewayIsUnreachableAndLetsOneProbeThroughPerWindow() async throws {
        let vault = Fixtures.testVault("offline-gate")
        vault.removeAll()
        defer { vault.removeAll() }
        let stored = StoredAccount(url: "http://127.0.0.1:1", username: "fleet",
                                   cookies: [SavedCookie(name: "hermes_session_rt", value: "keep-me", domain: "127.0.0.1")])
        try vault.save(stored)
        let client = LiveGatewayClient(stored: stored, transport: HTTPTransport(), vault: vault, verified: false, watchNetwork: false)
        defer { client.shutdown() }
        func read() async -> GatewayFailure? {
            do {
                _ = try await client.get("/api/status", [])
                return nil
            } catch {
                return (error as? GatewayFailure) ?? GatewayFailure.from(error)
            }
        }
        // Reads until one is held: the first meets the network (or the failed launch dials already started the outage).
        var met: [GatewayFailure?] = []
        for _ in 0..<3 {
            let failure = await read()
            met.append(failure)
            if failure?.isHeld == true { break }
        }
        #expect(met.last??.isHeld == true, "a read is turned away once the gateway is known to be unreachable: \(met)")
        #expect(met.allSatisfy { $0 != nil }, "nothing answers there")
        // While the window is shut every read is turned away at once, without touching the network.
        let started = ContinuousClock.now
        var held: [GatewayFailure?] = []
        for _ in 0..<20 { held.append(await read()) }
        let heldCount = held.filter { $0?.isHeld == true }.count
        #expect(heldCount >= 19, "at most one of twenty reads is a probe: \(heldCount) held")
        #expect(started.duration(to: .now) < .seconds(2), "and they fail at once")
        #expect(held.allSatisfy { $0 == .heldUnreachable || $0?.isHeld == false }, "with the unreachable words: \(held)")
        // A window later one probe is let through to the network, and the next read is held again.
        try await Task.sleep(for: .seconds(4.2))
        let probe = await read()
        #expect(probe != nil && probe?.isHeld == false, "one probe after the window: \(String(describing: probe))")
        #expect(await read()?.isHeld == true, "and held again")
    }
}
