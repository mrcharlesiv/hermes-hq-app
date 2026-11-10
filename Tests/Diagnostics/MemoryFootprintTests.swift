// [diagnostics] The footprint on mem.trim / main.hang / frames.bad / mk.day and the day's high mark
// (HermesKit/Diagnostics/MemoryFootprint.swift).

import Foundation
import Testing
@testable import HermesHQNative

struct MemoryFootprintTests {
    @Test func aSampleReadsTheFootprintAndThisRunsPeak() throws {
        let sample = try #require(MemoryFootprint.sample())
        #expect(sample.mb > 0 && sample.peakMB >= sample.mb)
        let fields = MemoryFootprint.fields(sample)
        #expect(fields.map(\.0) == ["fp", "fpk"])
    }

    @Test func highMarksStartAt250AndStepBy50() {
        let decisions = MemoryFootprint.highDecisions([(120, "a"), (123, "a"), (126, "a"), (126, "b"), (251, "c"), (280, "c"),
                                                       (300, "c"), (410, "d")])
        #expect(decisions.map(\.high) == [false, false, false, false, true, false, true, true])
        // The day's high is saved when it grows by 5 MB, or grows at all on another screen.
        #expect(decisions.map(\.saveDay) == [true, false, true, false, true, true, true, true])
    }

    @Test func theDaysHighComesBackForItsDailySummary() throws {
        let suite = "hq.tests.memory-footprint.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        MemoryFootprint.reset()
        MemoryFootprint.observe(screen: "show ChatViewController", now: now, defaults: defaults)
        let fields = MemoryFootprint.dayHighFields(day: FieldHistory.day(now), defaults: defaults)
        #expect(fields.map(\.0) == ["hi", "hiOn"])
        #expect((fields.first?.1 as? Int ?? 0) > 0)
        #expect(MemoryFootprint.dayHighFields(day: "2001-01-01", defaults: defaults).isEmpty)
    }
}
