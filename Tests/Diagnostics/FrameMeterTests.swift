import Foundation
import Testing
@testable import HermesHQNative

/// [diagnostics] Build 293: the hitch math, the buckets and records `FrameMeter` sends, the Diagnostics rows and the
/// MetricKit daily event.
@Suite struct FrameMeterTests {
    private func tally(_ deltas: [Double], interval: Double) -> FrameMath.Tally {
        var t = FrameMath.Tally()
        for d in deltas { t.add(deltaMs: d, intervalMs: interval) }
        return t
    }

    private func field(_ record: FrameBook.Record, _ key: String) -> Any? { record.fields.first { $0.0 == key }?.1 }

    @Test func aSteady120HzMomentHasNoHitches() {
        let t = tally(Array(repeating: 8.333, count: 120), interval: 8.333)
        #expect(t.frames == 120 && t.expected == 120 && t.missed == 0)
        #expect(t.hitchMs == 0 && t.hitchRatio == 0)
        #expect(t.topHz == 120)
        #expect(abs(t.worstMs - 8.333) < 0.001)
    }

    @Test func jitterUnderHalfAFrameIsNotAHitch() {
        let t = tally([8.3, 12.0, 8.3], interval: 8.333)
        #expect(t.hitchMs == 0)
    }

    @Test func aLateFrameCountsItsLatenessAndMissedFrames() {
        // 1 s at 60 Hz with one frame taking 100 ms: 5 frames missed, 83.3 ms of hitch.
        let deltas = Array(repeating: 16.667, count: 54) + [100]
        let t = tally(deltas, interval: 16.667)
        #expect(t.frames == 55)
        #expect(t.expected == 60)
        #expect(t.missed == 5)
        #expect(abs(t.hitchMs - 83.333) < 0.01)
        #expect(abs(t.durationMs - 1000.018) < 0.01)
        #expect(abs(t.hitchRatio - 83.33) < 0.1)
        #expect(t.worstMs == 100)
        #expect(t.topHz == 60)
    }

    @Test func nonsenseFramesAreIgnored() {
        let t = tally([0, -5], interval: 8.3)
        #expect(t.frames == 0)
        #expect(!FrameMath.counts(t))
        #expect(!FrameMath.counts(tally([8.3, 8.3], interval: 8.3)))
        #expect(FrameMath.counts(tally([16.7, 16.7, 16.7], interval: 16.7)))
    }

    @Test func shortNumbersAndQuantiles() {
        #expect(FrameMath.short(0) == "0")
        #expect(FrameMath.short(3.24) == "3.2")
        #expect(FrameMath.short(3.0) == "3")
        #expect(FrameMath.short(12.96) == "13")
        #expect(FrameMath.short(150.4) == "150")
        #expect(FrameMath.short(5000) == "999")
        #expect(FrameMath.median([]) == 0)
        #expect(FrameMath.median([5, 1, 3]) == 3)
        #expect(FrameMath.quantile(Array(1...10).map(Double.init), 0.9) == 9)
        #expect(FrameMath.quantile([7], 0.9) == 7)
    }

    @Test func aBucketIsSentAfterTwentyMoments() {
        var book = FrameBook()
        let now = Date(timeIntervalSince1970: 1000)
        let smooth = tally(Array(repeating: 8.333, count: 30), interval: 8.333)
        for i in 0..<19 { #expect(book.add(kind: "scroll", screen: "open chat", tally: smooth, now: now.addingTimeInterval(Double(i))).isEmpty) }
        let out = book.add(kind: "scroll", screen: "open chat", tally: smooth, now: now.addingTimeInterval(19))
        #expect(out.count == 1)
        let record = out[0]
        #expect(record.kind == "frames")
        #expect(field(record, "kd") as? String == "scroll")
        #expect(field(record, "scr") as? String == "open chat")
        #expect(field(record, "n") as? Int == 20)
        #expect(field(record, "dur") as? Int == 5000)
        #expect(field(record, "b") as? Int == 0)
        #expect(field(record, "hz") as? Int == 120)
        #expect(field(record, "rs") as? String == Array(repeating: "0", count: 20).joined(separator: ","))
        #expect(book.buckets.isEmpty)
        #expect(book.totals["scroll"]?.moments == 20)
        // The event fits the uploader's limits.
        #expect(LogUploader.event(record.kind, record.fields) != nil)
    }

    @Test func aBucketIsSentWhenFiveMinutesOldOrOnLeaving() {
        var book = FrameBook()
        let now = Date(timeIntervalSince1970: 1000)
        let t = tally(Array(repeating: 16.7, count: 10), interval: 16.7)
        #expect(book.add(kind: "push", screen: "tab 0", tally: t, now: now).isEmpty)
        #expect(book.add(kind: "keyboard", screen: "tab 0", tally: t, now: now.addingTimeInterval(10)).isEmpty)
        let late = book.add(kind: "push", screen: "tab 0", tally: t, now: now.addingTimeInterval(301))
        #expect(late.map(\.kind) == ["frames"])
        #expect(field(late[0], "kd") as? String == "push" && field(late[0], "n") as? Int == 2)
        let rest = book.flush(now: now.addingTimeInterval(302), all: true)
        #expect(rest.count == 1 && field(rest[0], "kd") as? String == "keyboard")
        #expect(book.flush(now: now.addingTimeInterval(303), all: true).isEmpty)
    }

    @Test func badMomentsAreSentOnTheirOwnAtMostOncePerFiveSeconds() {
        var book = FrameBook()
        let now = Date(timeIntervalSince1970: 1000)
        let bad = tally(Array(repeating: 8.333, count: 20) + [250], interval: 8.333)
        let first = book.add(kind: "chat.open", screen: "show ChatViewController", tally: bad, now: now)
        #expect(first.map(\.kind) == ["frames.bad"])
        #expect(field(first[0], "wf") as? Int == 250)
        #expect(field(first[0], "fr") as? Int == 21)
        #expect(LogUploader.event(first[0].kind, first[0].fields) != nil)
        #expect(book.add(kind: "chat.open", screen: "show ChatViewController", tally: bad, now: now.addingTimeInterval(2)).isEmpty)
        #expect(book.badSkipped == 1)
        #expect(book.add(kind: "chat.open", screen: "show ChatViewController", tally: bad, now: now.addingTimeInterval(6)).map(\.kind) == ["frames.bad"])
        let flushed = book.flush(now: now.addingTimeInterval(7), all: true)
        #expect(field(flushed[0], "b") as? Int == 3)
        #expect(field(flushed[0], "wf") as? Int == 250)
        #expect(book.totals["chat.open"]?.bad == 3)
    }

    @Test func decimalsAreWrittenShort() throws {
        let line = try #require(LogUploader.event("frames", [("hit", FrameMath.decimal1(66.900000000000006)), ("hr", FrameMath.decimal1(3.04))]))
        #expect(line.contains("\"hit\":66.9") && line.contains("\"hr\":3"))
        #expect(!line.contains("0000"))
    }

    @Test func genericScreensAreNamedByWhatTheyHold() {
        #expect(DiagnosticsTimeline.fixedName("show SettingsPageController<DiagnosticsView> (depth 3)") == "show DiagnosticsView")
        #expect(DiagnosticsTimeline.fixedName("show Wrapper<HermesHQNative.Inner<Deep>, Other>") == "show Inner")
        #expect(DiagnosticsTimeline.fixedName("show ChatViewController (depth 2)") == "show ChatViewController")
        #expect(DiagnosticsTimeline.fixedName("tab 0: BotsViewController") == "tab 0")
        #expect(DiagnosticsTimeline.fixedName("open chat (12 messages)") == "open chat")
        #expect(DiagnosticsTimeline.fixedName("") == "")
    }

    @Test func tinyMomentsAreDropped() {
        var book = FrameBook()
        #expect(book.add(kind: "scroll", screen: "x", tally: tally([8.3], interval: 8.3), now: Date()).isEmpty)
        #expect(book.totals.isEmpty)
        #expect(book.flush(now: Date(), all: true).isEmpty)
    }

    @Test func diagnosticsRows() {
        #expect(DiagnosticsReport.smoothnessRows([]) == [.init("Measured", "Nothing yet", "frames")])
        let rows = DiagnosticsReport.smoothnessRows([
            FrameBook.Total(kind: "keyboard", moments: 2, hitchRatios: [0, 4], worstMs: 17.2, bad: 0),
            FrameBook.Total(kind: "scroll", moments: 3, hitchRatios: [1, 2.5, 30], worstMs: 120.4, bad: 1),
        ])
        #expect(rows == [.init("Scrolling", "3 · 2.5 ms/s, 90% under 30 · worst 120 ms", "frames.scroll"),
                         .init("Keyboard", "2 · 0 ms/s, 90% under 4 · worst 17 ms", "frames.keyboard")])
    }

    @Test func metricKitDayEvent() {
        let values: [String: Double] = ["windowSeconds": 86_400, "scrollHitchMsPerSecond": 2.345, "hangCount": 2, "hangSeconds": 1.26,
                                        "launch.firstDraw.under500ms": 3, "launch.firstDraw.1000to2000ms": 1, "cpuSeconds": 411.6,
                                        "peakMemoryBytes": 210 * 1_048_576]
        let fields = MetricsReceiver.dayFields(values, day: "2026-10-14", build: "293")
        let map = Dictionary(uniqueKeysWithValues: fields.map { ($0.0, "\($0.1)") })
        #expect(map == ["day": "2026-10-14", "bld": "293", "sh": "2.3", "hc": "2", "hs": "1.3", "fd": "3/0/1/0/0",
                        "cpu": "412", "pk": "210", "win": "24"])
        #expect(LogUploader.event("mk.day", fields) != nil)
    }
}
