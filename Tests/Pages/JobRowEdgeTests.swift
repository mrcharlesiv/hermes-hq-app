// [jobs-edge] Owner 2026-11-10 (design pick 1): a job row says when it runs next at its trailing edge, and its second
// line is the schedule alone.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct JobRowEdgeTests {
    /// Sunday 2026-09-27 10:04 in Chicago is the stored next run.
    private func job(state: String? = nil, next: String? = "2026-09-27T10:04:00-05:00") -> CronJob {
        var job = CronJob(id: "j")
        job.state = state
        job.schedule = CronSchedule(kind: "interval", display: "Every 30 minutes", minutes: 30)
        job.nextRunAt = next
        return job
    }

    private func edge(_ job: CronJob, _ now: Date, running: Bool = false) -> JobWords.RowEdge? {
        JobWords.rowEdge(job, now: now, calendar: Chicago.calendar, running: running)
    }

    @Test func theNextRunReadsAsATimeADayOrADate() {
        #expect(edge(job(), Chicago.date(2026, 8, 27, 9, 52))?.text == "in 12 min")
        #expect(edge(job(), Chicago.date(2026, 8, 27, 7))?.text == "10:04 AM", "later today: the clock time")
        #expect(edge(job(), Chicago.date(2026, 8, 26, 12))?.text == "Tomorrow")
        #expect(edge(job(), Chicago.date(2026, 8, 23, 12))?.text == "Sun", "within the week: the day")
        #expect(edge(job(), Chicago.date(2026, 8, 1, 12))?.text == "Sep 27")
        #expect(edge(job(), Chicago.date(2025, 8, 1, 12))?.text == "Sep 27, 2026")
        #expect(edge(job(), Chicago.date(2026, 8, 26, 12))?.tone == .plain)
        #expect(edge(job(), Chicago.date(2026, 8, 26, 12))?.spoken == "next Tomorrow")
        #expect(edge(job(), Chicago.date(2026, 8, 27, 7))?.spoken == "next today at 10:04 AM")
    }

    @Test func aDueRunSaysNowAndALateOneHowLate() {
        #expect(edge(job(), Chicago.date(2026, 8, 27, 10, 9))?.text == "Now", "inside the scheduler's grace")
        let late = edge(job(), Chicago.date(2026, 8, 27, 12, 4))
        #expect(late?.text == "2h late")
        #expect(late?.tone == .late)
        #expect(late?.spoken == "2 hours late")
        #expect(edge(job(), Chicago.date(2026, 8, 27, 10, 34))?.text == "30m late")
        #expect(edge(job(), Chicago.date(2026, 8, 30, 10, 4))?.text == "3d late")
    }

    @Test func aRunningJobSaysHowLongItHasBeenOut() {
        var running = job()
        running.latestRunClaimedAt = "2026-09-27T10:00:00-05:00"
        let out = edge(running, Chicago.date(2026, 8, 27, 10, 4), running: true)
        #expect(out?.text == "4m so far")
        #expect(out?.tone == .running)
        #expect(edge(job(), Chicago.date(2026, 8, 27, 10, 4), running: true) == nil, "no claim time: nothing to say")
        #expect(edge(running, Chicago.date(2026, 8, 29, 10, 4), running: true) == nil, "a claim days old is not this run's")
    }

    @Test func pausedAndUnknownRowsHaveNoEdgeAndACompletedOneItsLastDay() {
        #expect(edge(job(state: "paused"), Chicago.date(2026, 8, 26, 12)) == nil)
        #expect(edge(job(next: nil), Chicago.date(2026, 8, 26, 12)) == nil)
        var done = job(state: "completed")
        done.lastRunAt = "2026-09-26T09:00:00-05:00"
        #expect(edge(done, Chicago.date(2026, 8, 27, 12))?.text == "Yesterday")
        #expect(edge(done, Chicago.date(2026, 8, 27, 12))?.spoken == "last ran Yesterday")
    }

    /// The second line no longer ends in the next run: the edge has it.
    @Test func theSecondLineIsTheScheduleAlone() {
        let now = Chicago.date(2026, 8, 26, 12)
        let schedule = JobWords.scheduleWords(job(), now: now, calendar: Chicago.calendar)
        #expect(JobWords.rowSchedule(job(), now: now, calendar: Chicago.calendar) == schedule)
        var failed = job()
        failed.lastError = "RuntimeError: boom"
        #expect(JobWords.rowSchedule(failed, now: Chicago.date(2026, 8, 27, 12), calendar: Chicago.calendar) == schedule,
                "a failed, overdue row is two lines too: its lead and its edge say the rest")
    }

    @Test func shortSpans() {
        #expect(JobWords.shortSpan(20) == "1m")
        #expect(JobWords.shortSpan(59 * 60) == "59m")
        #expect(JobWords.shortSpan(3600) == "1h")
        #expect(JobWords.shortSpan(47 * 3600) == "47h")
        #expect(JobWords.shortSpan(72 * 3600) == "3d")
    }
}
