// [jobs] The job editor's schedule (docs/spec/3x-jobs.md §6.5, §6.7, §6.10): presets ↔ expressions, what opens as
// Custom, composing, keeping the time across a preset switch, the summary sentences and what a pasted schedule is sent as.

import Foundation
import Testing
@testable import HermesHQNative

struct JobScheduleTests {
    @Test func everyPresetRoundTripsItsExpression() {
        let expected: [JobFrequency: String] = [.daily: "0 9 * * *", .weekdays: "0 9 * * 1-5", .weekly: "0 9 * * 1", .monthly: "0 9 1 * *",
                                                .hourly: "0 * * * *", .every15: "*/15 * * * *"]
        for (frequency, expr) in expected {
            #expect(frequency.presetExpr == expr)
            #expect(JobSchedule.frequency(for: expr) == frequency)
        }
        #expect(JobFrequency.custom.presetExpr == nil)
        #expect(JobFrequency.allCases.map(\.title) == ["Daily", "Weekdays", "Weekly", "Monthly", "Hourly", "Every 15 minutes", "Custom"])
    }

    @Test func aTimedExpressionOpensOnItsPreset() {
        #expect(JobSchedule.frequency(for: "15 7 * * *") == .daily)
        #expect(JobSchedule.frequency(for: "30 18 * * 1-5") == .weekdays)
        #expect(JobSchedule.frequency(for: "30 18 * * 3") == .weekly)
        #expect(JobSchedule.frequency(for: "0 9 * * 7") == .weekly)
        #expect(JobSchedule.frequency(for: "0 6 31 * *") == .monthly)
        #expect(JobSchedule.frequency(for: "25 * * * *") == .hourly)
        #expect(JobSchedule.frequency(for: "  0   9 * *   * ") == .daily)
    }

    @Test func anythingElseOpensAsCustomNeverSimplified() {
        for odd in ["0 9 * * 1-3", "*/10 * * * *", "0 9-17 * * *", "0 6,18 * * *", "0 9 1 1 *", "0 9 1 * 1", "every 30m", "in 2h",
                    "weekdays at 9am", "2026-02-03T14:00:00", "", "0 9 * * * *", "0 9 * *", "0 9 L * *", "@daily",
                    // Audit 863 (08c-9): a number out of its range stays as written, not 9:00 / day 1.
                    "0 25 * * *", "61 9 * * *", "0 9 32 * *", "0 9 0 * *", "75 * * * *", "0 24 * * 1-5"] {
            #expect(JobSchedule.frequency(for: odd) == .custom, "\(odd)")
        }
    }

    @Test func fieldsReadOnlyPlainNumbers() {
        #expect(JobSchedule.fields("30 18 * * 3") == JobTimeFields(hour: 18, minute: 30, weekday: 3, day: 1))
        #expect(JobSchedule.fields("0 9 * * 7").weekday == 0, "7 is Sunday")
        #expect(JobSchedule.fields("5 6 31 * *") == JobTimeFields(hour: 6, minute: 5, weekday: 1, day: 31))
        #expect(JobSchedule.fields("*/15 * * * *") == JobTimeFields())
        #expect(JobSchedule.fields("99 25 40 * 9") == JobTimeFields(), "out of range keeps the defaults")
        #expect(JobSchedule.fields("every 30m") == JobTimeFields())
    }

    @Test func composeWritesTheWebsLines() {
        let fields = JobTimeFields(hour: 18, minute: 30, weekday: 3, day: 31)
        #expect(JobSchedule.compose(.daily, fields) == "30 18 * * *")
        #expect(JobSchedule.compose(.weekdays, fields) == "30 18 * * 1-5")
        #expect(JobSchedule.compose(.weekly, fields) == "30 18 * * 3")
        #expect(JobSchedule.compose(.monthly, fields) == "30 18 31 * *")
        #expect(JobSchedule.compose(.hourly, fields) == "30 * * * *")
        #expect(JobSchedule.compose(.every15, fields) == "*/15 * * * *")
        #expect(JobSchedule.compose(.custom, fields) == "")
    }

    @Test func aPresetSwitchKeepsTheTimeAndGoingToCustomKeepsTheLine() {
        #expect(JobSchedule.expression(for: .weekly, keeping: "15 7 * * *") == "15 7 * * 1")
        #expect(JobSchedule.expression(for: .monthly, keeping: "15 7 * * 3") == "15 7 1 * *")
        #expect(JobSchedule.expression(for: .daily, keeping: "30 18 31 * *") == "30 18 * * *")
        #expect(JobSchedule.expression(for: .hourly, keeping: "25 7 * * *") == "25 * * * *")
        #expect(JobSchedule.expression(for: .every15, keeping: "15 7 * * *") == "*/15 * * * *")
        #expect(JobSchedule.expression(for: .custom, keeping: "15 7 * * *") == "15 7 * * *")
        #expect(JobSchedule.expression(for: .daily, keeping: "every 30m") == "0 9 * * *", "nothing to keep: the preset's own")
        #expect(JobSchedule.expression(for: .daily, keeping: "*/15 * * * *") == "0 9 * * *")
    }

    @Test func summariesIn12And24Hours() {
        #expect(JobSchedule.summary(.daily, expr: "0 9 * * *") == "Every day at 9:00 AM")
        #expect(JobSchedule.summary(.daily, expr: "0 9 * * *", uses24Hour: true) == "Every day at 09:00")
        #expect(JobSchedule.summary(.weekdays, expr: "5 0 * * 1-5") == "Weekdays at 12:05 AM")
        #expect(JobSchedule.summary(.weekly, expr: "30 18 * * 3") == "Every Wednesday at 6:30 PM")
        #expect(JobSchedule.summary(.weekly, expr: "30 18 * * 3", uses24Hour: true) == "Every Wednesday at 18:30")
        #expect(JobSchedule.summary(.weekly, expr: "0 12 * * 7") == "Every Sunday at 12:00 PM")
        #expect(JobSchedule.summary(.monthly, expr: "0 9 31 * *") == "Monthly on day 31 at 9:00 AM")
        #expect(JobSchedule.summary(.hourly, expr: "0 * * * *") == "At the top of every hour")
        #expect(JobSchedule.summary(.hourly, expr: "25 * * * *") == "Every hour at :25")
        #expect(JobSchedule.summary(.hourly, expr: "5 * * * *") == "Every hour at :05")
        #expect(JobSchedule.summary(.every15, expr: "*/15 * * * *") == "Every 15 minutes")
        #expect(JobSchedule.summary(.custom, expr: "0 9 * * *") == "")
    }

    @Test func skipNoteOnlyAboveDay28() {
        #expect(JobSchedule.skipNote(.monthly, JobTimeFields(day: 31)) == "Months without day 31 skip this run.")
        #expect(JobSchedule.skipNote(.monthly, JobTimeFields(day: 29)) == "Months without day 29 skip this run.")
        #expect(JobSchedule.skipNote(.monthly, JobTimeFields(day: 28)) == nil)
        #expect(JobSchedule.skipNote(.weekly, JobTimeFields(day: 31)) == nil)
    }

    @Test func minuteChoicesKeepAnOffGridMinute() {
        #expect(JobSchedule.minuteChoices(current: 25) == [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55])
        #expect(JobSchedule.minuteChoices(current: 7) == [0, 5, 7, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55])
    }

    @Test func aPastedScheduleIsCleanedBeforeItIsSent() {
        #expect(JobSchedule.cleanCustom("  0 9 * * 1-5 \n") == "0 9 * * 1-5")
        #expect(JobSchedule.cleanCustom("0\t9\n*\u{00A0}*\u{202F}1\u{2013}5") == "0 9 * * 1-5")
        #expect(JobSchedule.cleanCustom("\u{201C}every 2h\u{201D}") == "\"every 2h\"")
        #expect(JobSchedule.cleanCustom("\u{FF10} \u{FF19} * * *") == "0 9 * * *")
        #expect(JobSchedule.cleanCustom(" \n\t ") == "")
        #expect(JobSchedule.cleanCustom("weekdays at 9am") == "weekdays at 9am")
    }

    @Test func customPreviewOnlyForAFiveFieldLine() {
        #expect(JobSchedule.customPreview("every 2h") == nil)
        #expect(JobSchedule.customPreview("") == nil)
        #expect(JobSchedule.customPreview("0 9 * * 1-5") == JobWords.describeCron("0 9 * * 1-5"))
    }

    // MARK: Weekly on several days (redesign 2026-10-31)

    @Test func weeklyTakesAListOfDays() {
        #expect(JobSchedule.frequency(for: "0 7 * * 1,3,5") == .weekly)
        #expect(JobSchedule.frequency(for: "0 7 * * 5,1,3,7") == .weekly)
        #expect(JobSchedule.frequency(for: "0 7 * * 1-3") == .custom, "a range other than 1-5 stays Custom")
        #expect(JobSchedule.frequency(for: "0 7 * * 1,8") == .custom)
        #expect(JobSchedule.fields("0 7 * * 5,1,3,7").weekdays == [0, 1, 3, 5], "sorted, 7 is Sunday")
        #expect(JobSchedule.fields("0 7 * * 1-5").weekdays == [1], "Weekdays' range keeps the base day")
        #expect(JobSchedule.compose(.weekly, JobTimeFields(hour: 7, minute: 0, weekdays: [5, 1, 3])) == "0 7 * * 1,3,5")
        #expect(JobSchedule.expression(for: .weekly, keeping: "0 9 * * 1-5") == "0 9 * * 1", "a switch from Weekdays starts on Monday")
        var fields = JobTimeFields(weekdays: [])
        #expect(fields.weekdays == [1], "never no day")
        fields.weekday = 4
        #expect(fields.weekdays == [4])
    }

    @Test func weeklySummarySaysTheDays() {
        #expect(JobSchedule.summary(.weekly, expr: "0 7 * * 1,3,5") == "Every Mon, Wed and Fri at 7:00 AM")
        #expect(JobSchedule.summary(.weekly, expr: "0 7 * * 0,6") == "Weekends at 7:00 AM")
        #expect(JobSchedule.summary(.weekly, expr: "0 7 * * 1,2,3,4,5") == "Weekdays at 7:00 AM")
        #expect(JobSchedule.summary(.weekly, expr: "0 7 * * 0,1,2,3,4,5,6") == "Every day at 7:00 AM")
        #expect(JobSchedule.summary(.weekly, expr: "0 7 * * 0,2") == "Every Tue and Sun at 7:00 AM", "Monday first")
    }

    @Test func nextRunFollowsTheGatewaysClock() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        // Saturday 2026-10-31 04:50 CDT; daylight saving ends on Sunday.
        let now = PagesDate.parse("2026-10-31T04:50:00-05:00")!
        let monday = JobSchedule.nextRun("0 7 * * 1,3,5", hostOffset: nil, now: now, calendar: calendar)!
        #expect(JobWords.relativeDateTime(monday, now: now, calendar: calendar) == "Mon at 7:00 AM", "the phone's zone follows the change")
        let utc = JobSchedule.nextRun("0 7 * * 1,3,5", hostOffset: 0, now: now, calendar: calendar)!
        #expect(JobWords.relativeDateTime(utc, now: now, calendar: calendar) == "Mon at 1:00 AM")
        #expect(JobSchedule.nextRun("every 2h", hostOffset: nil, now: now, calendar: calendar) == nil)
    }
}
