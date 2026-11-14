import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

/// [diagnostics] Tester 2026-11-14 (kwojt, Mac 970): a main-thread layout loop grew the app to 111 GB over 90 minutes.
/// The Mac's guard stops the app once the main thread has been silent 30 s while its memory grew 1.5 GB.
@Suite struct RunawayGuardTests {
    /// What the hand-driven guard reads and records.
    final class Box: Sendable {
        let mb = Mutex(500)
        let answers = Mutex<[@Sendable () -> Void]>([])
        let stops = Mutex<[(TimeInterval, Int, Int)]>([])
    }

    /// A guard driven by hand: the footprint is whatever the test sets, the main thread's answer whatever it holds back.
    struct Rig {
        let box = Box()
        let guardian: RunawayGuard
        init() {
            let box = self.box
            guardian = RunawayGuard(footprintMB: { box.mb.withLock { $0 } },
                                    stop: { waited, from, now in box.stops.withLock { $0.append((waited, from, now)) } })
        }
        func tick(_ at: Date) { guardian.tick(now: at, ask: { [box] answer in box.answers.withLock { $0.append(answer) } }) }
        func answerAll() {
            let pending = box.answers.withLock { list in defer { list.removeAll() }; return list }
            pending.forEach { $0() }
        }
        var stopCount: Int { box.stops.withLock { $0.count } }
    }

    @Test func theRule() {
        #expect(!RunawayJudge.stops(waited: 29.9, fromMB: 500, nowMB: 50_000))      // not silent long enough
        #expect(!RunawayJudge.stops(waited: 600, fromMB: 500, nowMB: 2_000))         // stuck, but memory holds steady
        #expect(RunawayJudge.stops(waited: 30, fromMB: 500, nowMB: 2_036))
        #expect(RunawayJudge.stops(waited: 90, fromMB: 800, nowMB: 111_000))         // kwojt's
    }

    @Test func aStuckMainThreadWhoseMemoryRunsAwayStopsTheApp() {
        let rig = Rig()
        let start = Date()
        rig.tick(start)                                  // asks; the main thread never answers
        for second in 1...29 {
            rig.box.mb.withLock { $0 = 500 + second * 100 }  // 100 MB a second
            rig.tick(start + TimeInterval(second))
        }
        #expect(rig.stopCount == 0)                      // 29 s: not yet
        rig.box.mb.withLock { $0 = 3_600 }
        rig.tick(start + 30)
        #expect(rig.stopCount == 1)
        #expect(rig.box.stops.withLock { $0.first?.1 } == 500)
        #expect(rig.guardian.fired)
        rig.tick(start + 31)
        #expect(rig.stopCount == 1)                      // once
    }

    @Test func aMainThreadThatAnswersIsNeverStopped() {
        let rig = Rig()
        let start = Date()
        for second in 0...120 {
            rig.box.mb.withLock { $0 = 500 + second * 100 }  // memory grows, but the main thread keeps answering
            rig.tick(start + TimeInterval(second))
            rig.answerAll()
        }
        #expect(rig.stopCount == 0)
    }

    @Test func aStallThatHoldsItsMemoryIsLeftAlone() {
        let rig = Rig()
        let start = Date()
        for second in 0...300 { rig.tick(start + TimeInterval(second)) }   // stuck five minutes at 500 MB
        #expect(rig.stopCount == 0)
    }

    @Test func aProcessHeldBackAsAWholeStartsTheQuestionAgain() {
        let rig = Rig()
        let start = Date()
        rig.tick(start)
        rig.box.mb.withLock { $0 = 5_000 }
        rig.tick(start + 40)                             // the timer itself came 40 s late (sleep, App Nap)
        #expect(rig.stopCount == 0)
        rig.tick(start + 41)
        #expect(rig.stopCount == 0)                      // asked again at 5,000 MB: no growth since
    }
}
