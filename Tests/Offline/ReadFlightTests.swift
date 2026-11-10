import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

/// [offline] Background reads one at a time (docs/spec/3x-offline.md §6.7): the web app's `rpc-flight.test.ts`
/// "r2-02 single-flight background reads" cases with a hand-driven clock.
@MainActor @Suite struct ReadFlightTests {
    final class FakeClock: FlightClock {
        final class Timer: FlightTimer {
            let at: TimeInterval
            let run: @MainActor () -> Void
            var cancelled = false
            init(at: TimeInterval, run: @escaping @MainActor () -> Void) { self.at = at; self.run = run }
            func cancel() { cancelled = true }
        }
        var time: TimeInterval = 0
        var timers: [Timer] = []
        func now() -> TimeInterval { time }
        func schedule(after seconds: TimeInterval, _ run: @escaping @MainActor () -> Void) -> any FlightTimer {
            let timer = Timer(at: time + seconds, run: run)
            timers.append(timer)
            return timer
        }
        var pending: Int { timers.filter { !$0.cancelled }.count }
        func advance(_ seconds: TimeInterval) async {
            let until = time + seconds
            while let due = timers.filter({ !$0.cancelled && $0.at <= until }).min(by: { $0.at < $1.at }) {
                time = due.at
                due.cancelled = true
                due.run()
                await flush()
            }
            time = until
            await flush()
        }
    }

    /// A request the test answers by hand, as a busy gateway would.
    final class Gateway {
        var calls = 0
        var answers: [CheckedContinuation<Void, Never>] = []
        func task() async {
            calls += 1
            await withCheckedContinuation { answers.append($0) }
        }
        func answer() async {
            if !answers.isEmpty { answers.removeFirst().resume() }
            await flush()
        }
        var outstanding: Int { answers.count }
    }

    private func make(_ gateway: Gateway, clock: FakeClock, gap: Duration = .zero, slowAfter: Duration? = nil, quietFor: Duration = .zero,
                      active: @escaping @MainActor () -> Bool = { true }) -> ReadFlight {
        ReadFlight(gap: { gap }, slowAfter: slowAfter, quietFor: quietFor, isActive: active, clock: clock) { await gateway.task() }
    }

    @Test func neverOverlapsCallersShareOneTrailingRun() async {
        let clock = FakeClock(), gateway = Gateway()
        let flight = make(gateway, clock: clock)
        flight.ask()
        flight.ask(background: true); flight.ask(); flight.ask(background: true)
        await flush()
        #expect(gateway.calls == 1 && gateway.outstanding == 1)
        #expect(flight.state == .init(running: true, trailing: true, scheduled: false, owed: false))
        await gateway.answer()
        // The trailing run starts only once the first is answered, and it is one run for all three.
        #expect(gateway.calls == 2 && gateway.outstanding == 1)
        await gateway.answer()
        #expect(gateway.calls == 2)
        #expect(flight.state == .init(running: false, trailing: false, scheduled: false, owed: false))
    }

    @Test func oneRequestPerTickBurstWhileUnanswered() async {
        let clock = FakeClock(), gateway = Gateway()
        let flight = make(gateway, clock: clock, gap: .seconds(15))
        var second = 0
        while second <= 100 {
            flight.ask(background: true)
            await clock.advance(13)
            second += 13
        }
        #expect(gateway.calls == 1 && gateway.outstanding == 1)
    }

    @Test func backgroundCallersWaitOutTheGapOnceAndAForegroundCallRunsAtOnce() async {
        let clock = FakeClock(), gateway = Gateway()
        let flight = make(gateway, clock: clock, gap: .seconds(15))
        flight.ask(background: true); await flush(); await gateway.answer()
        #expect(gateway.calls == 1)
        await clock.advance(5)
        flight.ask(background: true); flight.ask(background: true)
        #expect(gateway.calls == 1)
        #expect(clock.pending == 1)
        await clock.advance(9.999)
        #expect(gateway.calls == 1)
        await clock.advance(0.001)
        #expect(gateway.calls == 2)
        await gateway.answer()
        // A user action does not wait for the gap, and takes over a scheduled tick.
        await clock.advance(1)
        flight.ask(background: true)
        #expect(clock.pending == 1)
        flight.ask()
        await flush()
        #expect(gateway.calls == 3)
        #expect(clock.pending == 0)
        await gateway.answer()
        #expect(flight.state == .init(running: false, trailing: false, scheduled: false, owed: false))
    }

    @Test func backsOffAfterASlowRequest() async {
        let clock = FakeClock(), gateway = Gateway()
        let flight = make(gateway, clock: clock, slowAfter: .seconds(25), quietFor: .seconds(60))
        flight.ask(background: true); await flush()
        await clock.advance(30); await gateway.answer()
        flight.ask(background: true)
        await clock.advance(59)
        #expect(gateway.calls == 1)
        await clock.advance(1)
        #expect(gateway.calls == 2)
    }

    @Test func nothingWhileNotActiveAndOneCatchUpRun() async {
        let clock = FakeClock(), gateway = Gateway()
        let app = Gateway()                       // `calls` stands for "the app is active" here: a flag in a box
        let flight = make(gateway, clock: clock, active: { app.calls > 0 })
        await flight.request(background: true)
        await flight.request()
        #expect(gateway.calls == 0)
        #expect(flight.state.owed)
        app.calls = 1
        flight.becameActive(); await flush()
        #expect(gateway.calls == 1)
        await gateway.answer()
        flight.becameActive(); await flush()
        #expect(gateway.calls == 1)
    }

    @Test func aForegroundCallPromotesATrailingBackgroundRun() async {
        let clock = FakeClock(), gateway = Gateway()
        let flight = make(gateway, clock: clock, gap: .seconds(15))
        flight.ask(); await flush()
        flight.ask(background: true)          // trailing, would wait out the gap
        flight.ask()                          // …but someone is waiting on screen now
        await gateway.answer()
        #expect(gateway.calls == 2)           // at once, no gap
        #expect(clock.pending == 0)
        await gateway.answer()
    }

    @Test func aTrailingBackgroundRunWaitsOutTheGap() async {
        let clock = FakeClock(), gateway = Gateway()
        let flight = make(gateway, clock: clock, gap: .seconds(15))
        flight.ask(); await flush()
        flight.ask(background: true)
        await clock.advance(4)
        await gateway.answer()
        #expect(gateway.calls == 1)
        #expect(clock.pending == 1)
        await clock.advance(11)
        #expect(gateway.calls == 2)
        await gateway.answer()
    }

    @Test func requestReturnsOnlyWhenACoveringRunHasFinished() async {
        let clock = FakeClock(), gateway = Gateway()
        let flight = make(gateway, clock: clock)
        var finished = 0
        let first = Task { await flight.request(); finished += 1 }
        await flush()
        let second = Task { await flight.request(background: true); finished += 1 }
        await flush()
        #expect(finished == 0)
        await gateway.answer()
        #expect(finished == 1)                 // the first caller only
        await gateway.answer()
        await first.value; await second.value
        #expect(finished == 2 && gateway.calls == 2)
    }

    /// Ten ticks a second against a 5 s read for a minute: never two reads at once (spec §9 item 4).
    @Test func tickStormNeverOverlaps() async {
        let clock = FakeClock(), gateway = Gateway()
        let flight = make(gateway, clock: clock)
        var maxOutstanding = 0
        var sinceAnswer = 0.0
        for _ in 0..<600 {
            flight.ask(background: true)
            await clock.advance(0.1)
            sinceAnswer += 0.1
            maxOutstanding = max(maxOutstanding, gateway.outstanding)
            if sinceAnswer >= 5, gateway.outstanding > 0 { await gateway.answer(); sinceAnswer = 0 }
        }
        #expect(maxOutstanding == 1)
        #expect(gateway.calls <= 13)
    }

    @Test func cancelForgetsWhatIsScheduledAndOwed() async {
        let clock = FakeClock(), gateway = Gateway()
        let flight = make(gateway, clock: clock, gap: .seconds(15))
        flight.ask(); await flush(); await gateway.answer()
        flight.ask(background: true)
        #expect(flight.state.scheduled)
        flight.cancel()
        #expect(flight.state == .init(running: false, trailing: false, scheduled: false, owed: false))
        await clock.advance(30)
        #expect(gateway.calls == 1)
    }
}

@MainActor fileprivate func flush() async { for _ in 0..<40 { await Task.yield() } }

@Suite struct PowerPollsTests {
    @Test func periodMaths() {
        #expect(PowerPolls.period(.seconds(30), saving: false) == .seconds(30))
        #expect(PowerPolls.period(.seconds(30), saving: true) == .seconds(90))
        // Floored on the phone, then stretched.
        #expect(PowerPolls.period(.seconds(2), saving: false) == .seconds(5))
        #expect(PowerPolls.period(.seconds(2), saving: true) == .seconds(15))
        #expect(PowerPolls.period(.milliseconds(1200), floor: .zero, saving: false) == .milliseconds(1200))
        // The cap bounds the stretch only.
        #expect(PowerPolls.period(.seconds(30), cap: .seconds(60), saving: true) == .seconds(60))
        #expect(PowerPolls.period(.seconds(30), cap: .seconds(60), saving: false) == .seconds(30))
        #expect(PowerPolls.period(.seconds(30), cap: .seconds(10), saving: true) == .seconds(30))
    }

    @Test func scheduleRearmsOnAPowerChange() {
        var schedule = PowerPolls.Schedule(base: .seconds(30), floor: .seconds(5), cap: nil, lastRun: 100)
        #expect(schedule.wait(now: 100, saving: false) == 30)
        #expect(schedule.wait(now: 110, saving: false) == 20)
        // Saving starts 10 s in: the same poll now waits out the stretched period, not a fresh one.
        #expect(schedule.wait(now: 110, saving: true) == 80)
        // Leaving saver 50 s in: the normal period is already spent, so it runs at once…
        #expect(schedule.wait(now: 150, saving: false) == 0)
        // …and after that run the next is one normal period away (no double run).
        schedule.lastRun = 150
        #expect(schedule.wait(now: 150, saving: false) == 30)
    }

    @MainActor @Test func loopStretchesAndCatchesUp() async {
        let power = PowerState()                    // the test's own: no other test's poll is slowed
        var runs = 0
        let loop = PowerPolls.loop(every: .milliseconds(120), floor: .zero, power: power) { runs += 1 }
        defer { loop.cancel() }
        try? await Task.sleep(for: .milliseconds(420))
        let normal = runs
        #expect(normal >= 2 && normal <= 4, "ran \(normal) times in 420 ms at 120 ms")
        power.override = true                       // three times slower from here
        try? await Task.sleep(for: .milliseconds(300))
        #expect(runs - normal <= 1, "ran \(runs - normal) more times in 300 ms at 360 ms")
        let slow = runs
        try? await Task.sleep(for: .milliseconds(200))
        power.override = false                      // overdue on the normal schedule: runs at once
        try? await Task.sleep(for: .milliseconds(60))
        #expect(runs > slow)
    }

    @MainActor @Test func oneWaitStretchesWhileSavingAndEndsEarlyOnLeaving() async {
        let power = PowerState()
        let clock = ContinuousClock()
        var began = clock.now
        await PowerPolls.wait(.milliseconds(100), floor: .zero, power: power)
        let normal = clock.now - began
        #expect(normal >= .milliseconds(90) && normal < .milliseconds(280), "a normal wait took \(normal)")
        power.override = true
        began = clock.now
        await PowerPolls.wait(.milliseconds(100), floor: .zero, power: power)
        let slow = clock.now - began
        #expect(slow >= .milliseconds(280), "a saving wait took \(slow)")
        // Leaving saver part-way through a stretched wait: the normal period is spent, so it ends at once.
        began = clock.now
        let leave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            power.override = false
        }
        await PowerPolls.wait(.milliseconds(400), floor: .zero, power: power)
        let cut = clock.now - began
        _ = await leave.value
        #expect(cut >= .milliseconds(430) && cut < .milliseconds(1000), "a wait cut short by leaving saver took \(cut)")
        // Entering saver part-way through stretches the same wait (it is not started again from zero).
        began = clock.now
        let enter = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            power.override = true
        }
        await PowerPolls.wait(.milliseconds(100), floor: .zero, power: power)
        let stretched = clock.now - began
        _ = await enter.value
        #expect(stretched >= .milliseconds(280) && stretched < .milliseconds(700), "a wait stretched part-way took \(stretched)")
    }

    @MainActor @Test func aCancelledWaitReturns() async {
        let power = PowerState()
        let waiter = Task { @MainActor in await PowerPolls.wait(.seconds(30), floor: .zero, power: power) }
        try? await Task.sleep(for: .milliseconds(40))
        waiter.cancel()
        let clock = ContinuousClock(), began = clock.now
        await waiter.value
        #expect(clock.now - began < .milliseconds(500))
    }

    @MainActor @Test func aCancelledLoopStops() async {
        var runs = 0
        let loop = PowerPolls.loop(every: .milliseconds(30), floor: .zero) { runs += 1 }
        try? await Task.sleep(for: .milliseconds(100))
        loop.cancel()
        try? await Task.sleep(for: .milliseconds(40))
        let stopped = runs
        try? await Task.sleep(for: .milliseconds(150))
        #expect(runs == stopped && stopped >= 1)
    }
}

/// [offline] §6.2 and §6.7 on the Kanban board (review round): its failed read is asked once more and no more, and its
/// poll, which keeps its own shape instead of a `ReadFlight`, meets the same rule: one read at a time, none while the
/// page is hidden or the app is away, one catch-up on return.
@MainActor @Suite struct KanbanReadRulesTests {
    nonisolated private static let boardPath = "/api/plugins/kanban/board"

    private func timing(poll: Duration = .seconds(3600)) -> KanbanStoreTiming {
        var timing = KanbanStoreTiming()
        timing.poll = poll
        timing.retryDelay = .milliseconds(20)
        return timing
    }

    private func boardReads(_ client: PagesFakeClient) -> Int { client.log.filter { $0.path == Self.boardPath }.count }

    @Test func aFailedBoardReadIsAskedOnceMore() async {
        let failures = Mutex(1)
        let client = PagesFakeClient { request in
            if request.path == Self.boardPath, failures.withLock({ left in defer { left -= 1 }; return left > 0 }) {
                throw httpError(500, "a moment of trouble")
            }
            return KanbanStoreTests.boardJSON([("t_a", "A", "todo")])
        }
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil, timing: timing())
        await store.readBoard()
        #expect(boardReads(client) == 2, "the failure and one retry")
        #expect(store.boardError == nil && store.board?.task("t_a") != nil, "the retry's board is on show")
    }

    @Test func aBoardThatKeepsFailingIsAskedTwiceThenSaysSo() async {
        let client = PagesFakeClient { request in
            if request.path == Self.boardPath { throw httpError(500, "still broken") }
            return .object([:])
        }
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil, timing: timing())
        await store.readBoard()
        #expect(boardReads(client) == 2, "one retry, never a loop")
        #expect(store.boardError != nil)
    }

    @Test func anUnreachableGatewayOrATimeoutIsNotAskedAgain() async {
        for error in [httpError(503, "down") as any Error, URLError(.timedOut), GatewayFailure.unreachable] {
            let client = PagesFakeClient { request in
                if request.path == Self.boardPath { throw error }
                return .object([:])
            }
            let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil, timing: timing())
            await store.readBoard()
            #expect(boardReads(client) == 1, "\(error): the page says so at once")
            #expect(store.boardError != nil)
        }
    }

    @Test func thePollReadsNothingWhileHiddenOrAwayAndOnceOnReturn() async throws {
        let client = PagesFakeClient { request in
            request.path == Self.boardPath ? KanbanStoreTests.boardJSON([("t_a", "A", "todo")]) : .object([:])
        }
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil, timing: timing(poll: .milliseconds(600)))
        store.setVisible(true)
        try await Task.sleep(for: .milliseconds(1600))
        let shown = boardReads(client)
        #expect(shown >= 2, "on show: the first read and the poll: \(shown)")
        // Away: nothing is asked.
        store.appDidEnterBackground()
        try await Task.sleep(for: .milliseconds(100))        // a read in flight ends
        let away = boardReads(client)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(boardReads(client) == away, "nothing while the app is away")
        // Back: one catch-up read at once, then the poll again.
        store.appDidBecomeActive()
        try await Task.sleep(for: .milliseconds(200))
        #expect(boardReads(client) == away + 1, "one catch-up read on return")
        // Hidden: nothing.
        store.setVisible(false)
        try await Task.sleep(for: .milliseconds(100))
        let hidden = boardReads(client)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(boardReads(client) == hidden, "nothing while the page is hidden")
        store.stop()
    }

    nonisolated private static let boardsPath = KanbanAPI.base + "/boards"
    nonisolated private static let profilesPath = KanbanAPI.base + "/profiles"

    @Test func gatewayReadyRightAfterAReturnReadsNothingTwice() async throws {
        // The board answers at once; the lists are still on their way when gateway.ready comes.
        let client = PagesFakeClient { request in
            if request.path == Self.boardPath { return KanbanStoreTests.boardJSON([("t_a", "A", "todo")]) }
            try await Task.sleep(for: .milliseconds(150))
            return .object([:])
        }
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil, timing: timing())
        store.setVisible(true)
        try await Task.sleep(for: .milliseconds(40))
        store.gatewayReady()
        try await Task.sleep(for: .milliseconds(300))
        #expect(boardReads(client) == 1, "the return's board read is fresh: \(client.logLines)")
        #expect(client.log.filter { $0.path == Self.boardsPath }.count == 1, "boards in flight is not asked again")
        #expect(client.log.filter { $0.path == Self.profilesPath }.count == 1, "bots in flight are not asked again")
        store.stop()
    }

    @Test func gatewayReadyReadsAgainAfterAReturnReadThatFailed() async throws {
        let failures = Mutex(1)
        let client = PagesFakeClient { request in
            if request.path == Self.boardPath, failures.withLock({ left in defer { left -= 1 }; return left > 0 }) {
                throw GatewayFailure.unreachable
            }
            return request.path == Self.boardPath ? KanbanStoreTests.boardJSON([("t_a", "A", "todo")]) : .object([:])
        }
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil, timing: timing())
        store.setVisible(true)
        try await Task.sleep(for: .milliseconds(60))
        #expect(store.boardError != nil, "sent before the network was up")
        store.gatewayReady()
        try await Task.sleep(for: .milliseconds(100))
        #expect(boardReads(client) == 2)
        #expect(store.boardError == nil && store.board?.task("t_a") != nil)
        store.stop()
    }

    @Test func gatewayReadyReadsAgainWhenALaterReadFailedAfterASuccess() async throws {
        // (A board pick writes the shared slug default, which other tests read, so a failed follow-up read stands in.)
        let broken = Mutex(false)
        let client = PagesFakeClient { request in
            if request.path == Self.boardPath, broken.withLock({ $0 }) { throw GatewayFailure.unreachable }
            return request.path == Self.boardPath ? KanbanStoreTests.boardJSON([("t_a", "A", "todo")]) : .object([:])
        }
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil, timing: timing())
        store.setVisible(true)
        try await Task.sleep(for: .milliseconds(60))
        #expect(store.boardError == nil, "the first read landed")
        broken.withLock { $0 = true }
        await store.readBoard()
        #expect(store.boardError != nil, "the later read failed")
        broken.withLock { $0 = false }
        store.gatewayReady()
        try await Task.sleep(for: .milliseconds(100))
        #expect(boardReads(client) == 3)
        #expect(store.boardError == nil)
        store.stop()
    }

    @Test func gatewayReadyReadsABoardThatIsNoLongerFresh() async throws {
        let client = PagesFakeClient { request in
            request.path == Self.boardPath ? KanbanStoreTests.boardJSON([("t_a", "A", "todo")]) : .object([:])
        }
        var timing = timing()
        timing.boardFresh = 0.1
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil, timing: timing)
        store.setVisible(true)
        try await Task.sleep(for: .milliseconds(200))
        store.gatewayReady()
        try await Task.sleep(for: .milliseconds(100))
        #expect(boardReads(client) == 2)
        store.stop()
    }
}

/// [offline] §6.2 on the last two pages (review round): the Artifacts listing and the Settings record are asked once
/// more after a failure that is neither a timeout nor an unreachable gateway.
@MainActor @Suite struct PageQueryRetryTests {
    @Test func aFailedArtifactsListingIsAskedOnceMore() async throws {
        let failures = Mutex(1)
        let client = PagesFakeClient { request in
            if request.path == ArtifactsStore.sessionsPath, failures.withLock({ left in defer { left -= 1 }; return left > 0 }) {
                throw httpError(500, "a moment of trouble")
            }
            return ["sessions": []]
        }
        let store = ArtifactsStore(client: client, account: client.account, directory: nil)
        store.retryDelay = .milliseconds(20)
        store.pageShown()
        for _ in 0..<300 where client.log.filter({ $0.path == ArtifactsStore.sessionsPath }).count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.log.filter { $0.path == ArtifactsStore.sessionsPath }.count == 2, "the failure and one retry, no more")
    }

    @Test func anUnreachableGatewayIsNotAskedAgainForArtifacts() async throws {
        let client = PagesFakeClient { request in
            if request.path == ArtifactsStore.sessionsPath { throw httpError(503, "down") }
            return ["sessions": []]
        }
        let store = ArtifactsStore(client: client, account: client.account, directory: nil)
        store.retryDelay = .milliseconds(20)
        store.pageShown()
        try await Task.sleep(for: .milliseconds(400))
        #expect(client.log.filter { $0.path == ArtifactsStore.sessionsPath }.count == 1)
    }

    @Test func aFailedSettingsRecordIsAskedOnceMoreThenShown() async {
        let failures = Mutex(1)
        let client = PagesFakeClient { request in
            switch (request.method, request.path) {
            case ("GET", "/api/config"):
                if failures.withLock({ left in defer { left -= 1 }; return left > 0 }) { throw httpError(500, "a moment of trouble") }
                return ["approvals": ["mode": "manual"]]
            case ("GET", "/api/config/schema"): return ["fields": ["approvals.mode": ["type": "string"]]]
            default: return .object([:])
            }
        }
        let store = GatewayConfigStore(api: GatewaySettingsAPI(client: client), readOnly: false)
        store.retryDelay = .milliseconds(20)
        await store.load()
        #expect(store.phase == .loaded, "the retry's record is on show")
        #expect(client.log.filter { $0.path == "/api/config" }.count == 2)
    }

    @Test func aSettingsRecordThatTimesOutSaysSoAtOnce() async {
        let client = PagesFakeClient { request in
            if request.path == "/api/config" { throw URLError(.timedOut) }
            return ["fields": [:]]
        }
        let store = GatewayConfigStore(api: GatewaySettingsAPI(client: client), readOnly: false)
        store.retryDelay = .milliseconds(20)
        await store.load()
        #expect(client.log.filter { $0.path == "/api/config" }.count == 1)
        if case .failed = store.phase {} else { Issue.record("the page says it could not load: \(store.phase)") }
    }
}
