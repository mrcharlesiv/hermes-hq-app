// [device-access] Motion's pure parts (App/DeviceAccess/MotionAccess.swift does the CoreMotion work): which word a
// CMMotionActivity's flags (not mutually exclusive) answer with, and merging the activity samples CoreMotion returns
// (one per change) into the periods the contract wants.

import Foundation

nonisolated extension DeviceAccess {
    /// One CMMotionActivity's flags, read as the one word the contract wants. The flags aren't exclusive (a car
    /// stopped at a sign is both stationary and automotive), so this picks the most specific one.
    static func motionActivityName(walking: Bool, running: Bool, cycling: Bool, automotive: Bool, stationary: Bool, unknown: Bool) -> String {
        if automotive { return "automotive" }
        if cycling { return "cycling" }
        if running { return "running" }
        if walking { return "walking" }
        if stationary { return "stationary" }
        return "unknown"
    }

    /// CMMotionActivityConfidence's raw value (0 low, 1 medium, 2 high), as the word the contract wants.
    static func motionConfidenceWord(_ raw: Int) -> String {
        switch raw {
        case 2: "high"
        case 1: "medium"
        default: "low"
        }
    }

    /// A `motion.activity` window that reaches the present (within 5 minutes): only then is its newest activity
    /// what the person is doing now.
    static func motionReachesNow(_ end: Date, now: Date = Date()) -> Bool { end >= now.addingTimeInterval(-300) }

    /// One merged stretch of the same activity.
    struct MotionPeriod: Equatable, Sendable {
        var activity: String
        var start: Date
        var end: Date

        var minutes: Int { max(0, Int((end.timeIntervalSince(start) / 60).rounded())) }
    }

    /// CoreMotion returns one sample per change, each a start time and the activity that began then (it may run a
    /// little before the time asked for, which is fine: it's what the state was then). This turns that into periods
    /// (each sample's end is the next one's start, or `end` for the last), merges consecutive same-activity ones, and
    /// keeps the most recent 30.
    static func mergeMotionPeriods(_ samples: [(activity: String, start: Date)], until end: Date) -> [MotionPeriod] {
        let sorted = samples.sorted { $0.start < $1.start }
        var periods: [MotionPeriod] = []
        for (index, sample) in sorted.enumerated() {
            let periodEnd = index + 1 < sorted.count ? sorted[index + 1].start : end
            guard periodEnd > sample.start else { continue }
            if let last = periods.indices.last, periods[last].activity == sample.activity {
                periods[last].end = periodEnd
            } else {
                periods.append(MotionPeriod(activity: sample.activity, start: sample.start, end: periodEnd))
            }
        }
        return Array(periods.suffix(30))
    }
}
