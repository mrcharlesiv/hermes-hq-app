// [device-access] Motion: DeviceAccess+Motion's pure parts (activity naming, confidence words, period merging), and
// what MotionAccess.answer says on devices with no motion data (every Simulator).

import CoreMotion
import Foundation
import Testing
@testable import HermesHQNative

@MainActor struct DeviceAccessMotionTests {
    private let id = String(repeating: "a", count: 32)

    @Test func activityNamePicksTheMostSpecificFlag() {
        #expect(DeviceAccess.motionActivityName(walking: false, running: false, cycling: false, automotive: true, stationary: true, unknown: false) == "automotive")
        #expect(DeviceAccess.motionActivityName(walking: true, running: false, cycling: false, automotive: false, stationary: false, unknown: false) == "walking")
        #expect(DeviceAccess.motionActivityName(walking: false, running: false, cycling: false, automotive: false, stationary: true, unknown: false) == "stationary")
        #expect(DeviceAccess.motionActivityName(walking: false, running: false, cycling: false, automotive: false, stationary: false, unknown: false) == "unknown")
        #expect(DeviceAccess.motionActivityName(walking: false, running: true, cycling: true, automotive: false, stationary: false, unknown: false) == "cycling")
    }

    @Test func confidenceWords() {
        #expect(DeviceAccess.motionConfidenceWord(0) == "low")
        #expect(DeviceAccess.motionConfidenceWord(1) == "medium")
        #expect(DeviceAccess.motionConfidenceWord(2) == "high")
        #expect(DeviceAccess.motionConfidenceWord(99) == "low")
    }

    @Test func periodsMergeConsecutiveSameActivityAndKeepTheLast30() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples: [(activity: String, start: Date)] = [
            ("walking", base),
            ("walking", base.addingTimeInterval(300)),
            ("stationary", base.addingTimeInterval(600)),
            ("walking", base.addingTimeInterval(900)),
        ]
        let periods = DeviceAccess.mergeMotionPeriods(samples, until: base.addingTimeInterval(1200))
        #expect(periods.count == 3)
        #expect(periods[0].activity == "walking" && periods[0].start == base && periods[0].end == base.addingTimeInterval(600))
        #expect(periods[0].minutes == 10)
        #expect(periods[1].activity == "stationary")
        #expect(periods[2].activity == "walking" && periods[2].end == base.addingTimeInterval(1200))

        let many = (0..<40).map { (activity: $0 % 2 == 0 ? "walking" : "running", start: base.addingTimeInterval(Double($0) * 60)) }
        let merged = DeviceAccess.mergeMotionPeriods(many, until: base.addingTimeInterval(40 * 60))
        #expect(merged.count == 30, "kept the most recent 30")
        #expect(merged.first?.start == many[10].start, "the oldest 10 were dropped")
    }

    /// Audit 09-27: "now" only for a window that reaches the present.
    @Test func onlyAWindowEndingNowHasANow() {
        let now = Date()
        #expect(DeviceAccess.motionReachesNow(now, now: now))
        #expect(DeviceAccess.motionReachesNow(now.addingTimeInterval(-60), now: now))
        #expect(!DeviceAccess.motionReachesNow(now.addingTimeInterval(-3600), now: now))
    }

    /// True on every Simulator (no motion coprocessor): the one path this can verify without a real device.
    @Test func noMotionDataOnTheSimulatorSaysSo() async throws {
        guard !CMMotionActivityManager.isActivityAvailable() else { return }
        let request = DeviceAccess.Request(id: id, op: "motion.activity")
        let answer = await MotionAccess.answer(request, scopes: ["activity"])
        #expect(answer == .unavailable("This device has no motion data."))
    }
}
