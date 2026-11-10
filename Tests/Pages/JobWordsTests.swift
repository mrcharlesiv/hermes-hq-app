// P-U1 / P-U2: the Jobs words and sections, ported from the web's tests (docs/spec/1x-pages.md §10.1) with the same
// inputs and the tests' zone (America/Chicago).

import Foundation
import Testing
@testable import HermesHQNative

enum Chicago {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()
    /// `new Date(y, m0, d, h, min)` in the tests' zone (month is 0-based like JS).
    static func date(_ y: Int, _ m0: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m0 + 1, day: d, hour: h, minute: min, second: s))!
    }
    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    static func parse(_ iso: String) -> Date { PagesDate.parse(iso, calendar: calendar)! }
}

struct JobWordsScheduleTests {
    let c = Chicago.calendar

    @Test func describesCommonCronLines() {
        #expect(JobWords.describeCron("15 8 * * 1-5") == "Weekdays at 8:15 AM")
        #expect(JobWords.describeCron("0 9 * * *") == "Every day at 9:00 AM")
        #expect(JobWords.describeCron("0 8,18 * * *") == "Every day at 8:00 AM and 6:00 PM")
        #expect(JobWords.describeCron("30 7 * * 1") == "Every Monday at 7:30 AM")
        #expect(JobWords.describeCron("0 10 * * 1,3,5") == "Mon, Wed and Fri at 10:00 AM")
        #expect(JobWords.describeCron("0 9 1 * *") == "Monthly on day 1 at 9:00 AM")
        #expect(JobWords.describeCron("*/15 * * * *") == "Every 15 minutes")
        #expect(JobWords.describeCron("*/30 9-17 * * 1-5") == "Every 30 minutes, 9:00 AM–5:59 PM (weekdays)")
        #expect(JobWords.describeCron("0 * * * *") == "Every hour, on the hour")
        #expect(JobWords.describeCron("5 */2 * * *") == "Every 2 hours at :05")
        #expect(JobWords.describeCron("0 9 * 1 *") == nil)
        #expect(JobWords.describeCron("weekdays at 9am") == nil)
    }

    @Test func readsIntervalAndOneOffSchedules() {
        #expect(JobWords.describeSchedule("every 30m", calendar: c) == "Every 30 minutes")
        #expect(JobWords.describeSchedule("every 1440m", calendar: c) == "Every day")
        #expect(JobWords.describeSchedule("every 120m", calendar: c) == "Every 2 hours")
        #expect(JobWords.describeSchedule("15 8 * * 1-5", calendar: c) == "Weekdays at 8:15 AM")
    }

    @Test func readsTheSchedulersOneOffDisplay() {
        let now = Chicago.date(2026, 8, 27, 10)
        let said = JobWords.describeSchedule("once at 2026-09-30 09:00", now: now, calendar: c)
        #expect(said == "Once on Wed, Sep 30 at 9:00 AM")
        let iso = JobWords.describeSchedule("2026-10-02T08:00:00-05:00", now: now, calendar: c) ?? ""
        #expect(RX(#"^Once on \w{3}, Oct \d{1,2}(, 2026)? at \d{1,2}:\d{2} [AP]M$"#).test(iso), "\(iso)")
        #expect(JobWords.describeSchedule("once at 2026-13-45 09:00", now: now, calendar: c) == nil)
        // Another year names it.
        #expect(JobWords.describeSchedule("once at 2027-01-04 09:00", now: now, calendar: c) == "Once on Mon, Jan 4, 2027 at 9:00 AM")
    }

    /// `writtenAhead`: an ISO time written at `wall` in a zone `shift` minutes ahead of the phone's.
    func writtenAhead(_ wall: String, _ shift: Int) -> String {
        let date = String(wall.prefix(10)), time = String(wall.dropFirst(11))
        let parts = date.split(separator: "-").compactMap { Int($0) }
        let noon = Chicago.date(parts[0], parts[1] - 1, parts[2], 12)
        let offset = Chicago.calendar.timeZone.secondsFromGMT(for: noon) / 60 + shift
        let abs = Swift.abs(offset)
        return "\(date)T\(time):00\(offset < 0 ? "-" : "+")\(String(format: "%02d", abs / 60)):\(String(format: "%02d", abs % 60))"
    }

    @Test func saysAWeeklyJobRunInAnotherZoneAtThePhonesTime() {
        let next = writtenAhead("2026-09-28T06:00", 300)
        #expect(c.component(.hour, from: Chicago.parse(next)) == 1)
        #expect(JobWords.localCronSchedule("0 6 * * 1", nextRunAt: next, calendar: c) == "Every Monday at 1:00 AM")
        #expect(JobWords.localCronSchedule("0 6 * * *", nextRunAt: next, calendar: c) == "Every day at 1:00 AM")
        let named = JobWords.localCronSchedule("0 6 * * 1-5", nextRunAt: next, calendar: c) ?? ""
        #expect(RX(#"^Weekdays at 6:00 AM UTC([+−]\d+(:\d{2})?)?$"#).test(named), "\(named)")
    }

    @Test func staysQuietWhenTheCronAndThePhoneAgree() {
        #expect(JobWords.localCronSchedule("0 6 * * 1", nextRunAt: writtenAhead("2026-09-28T06:00", 0), calendar: c) == nil)
        #expect(JobWords.localCronSchedule("0 6 * * 1", nextRunAt: writtenAhead("2026-09-28T07:00", 300), calendar: c) == nil)
        #expect(JobWords.localCronSchedule("*/15 * * * *", nextRunAt: writtenAhead("2026-09-28T06:15", 300), calendar: c) == nil)
        #expect(JobWords.localCronSchedule("0 6 * * 1", nextRunAt: nil, calendar: c) == nil)
        #expect(JobWords.localCronSchedule("0 6 * * 1", nextRunAt: "2026-09-28T06:00:00", calendar: c) == nil)
    }

    @Test func prefersAZoneFixThenAOneOffsOwnTimeThenTheSummary() {
        let now = Chicago.date(2026, 8, 27, 10)
        let next = writtenAhead("2026-09-28T06:00", 300)
        let local = JobWords.clock(Chicago.parse(next), calendar: c)
        #expect(JobWords.jobScheduleWords(expr: "0 6 * * 1", display: "0 6 * * 1", runAt: "", nextRunAt: next,
                                          known: "Every Monday at 6:00 AM", now: now, calendar: c) == "Every Monday at \(local)")
        #expect(JobWords.jobScheduleWords(expr: "0 6 * * 1", display: "0 6 * * 1", runAt: "", nextRunAt: writtenAhead("2026-09-28T06:00", 0),
                                          known: "Every Monday at 6:00 AM", now: now, calendar: c) == "Every Monday at 6:00 AM")
        let once = JobWords.jobScheduleWords(expr: "once at 2026-09-30 09:00", display: "once at 2026-09-30 09:00",
                                             runAt: "2026-09-30T09:00:00-05:00", nextRunAt: "2026-09-30T09:00:00-05:00", now: now, calendar: c)
        #expect(once.hasPrefix("Once on Wed, Sep 30 at "))
        #expect(JobWords.jobScheduleWords(expr: "once at 2026-09-30 09:00", display: "once at 2026-09-30 09:00", runAt: "",
                                          nextRunAt: nil, now: now, calendar: c).hasPrefix("Once on Wed, Sep 30"))
        #expect(JobWords.jobScheduleWords(expr: "every day at 10am", display: "every day at 10am", runAt: "", nextRunAt: nil,
                                          now: now, calendar: c) == "every day at 10am")
    }
}

struct JobWordsNextRunTests {
    let c = Chicago.calendar
    let mon9pm = Chicago.parse("2026-09-28T21:05:00-05:00")

    func cron(_ expr: String, _ next: String?, _ state: String = "scheduled", _ words: String, now: Date? = nil) -> String {
        JobWords.jobNextWords(state: state, schedule: CronSchedule(kind: "cron", expr: expr), nextRunAt: next,
                              scheduleWords: words, now: now ?? mon9pm, calendar: c)
    }

    func every(_ minutes: Double, _ next: String, _ words: String) -> String {
        JobWords.jobNextWords(state: "scheduled", schedule: CronSchedule(kind: "interval", minutes: minutes), nextRunAt: next,
                              scheduleWords: words, now: mon9pm, calendar: c)
    }

    @Test func nextCronFireReadsWeekdaysListsRangesAndSteps() {
        func fire(_ expr: String, _ after: Date, _ offset: Int?) -> Date? { JobWords.nextCronFire(expr, after: after, offset: offset, calendar: c) }
        #expect(fire("0 13 * * 1-5", mon9pm, -300) == Chicago.parse("2026-09-29T13:00:00-05:00"))
        #expect(fire("0 18 * * 0", mon9pm, -300) == Chicago.parse("2026-10-04T18:00:00-05:00"))
        #expect(fire("*/30 9-19 * * *", mon9pm, -300) == Chicago.parse("2026-09-29T09:00:00-05:00"))
        #expect(fire("0 9,13,17 * * *", Chicago.parse("2026-09-29T13:00:00-05:00"), -300) == Chicago.parse("2026-09-29T17:00:00-05:00"))
        #expect(fire("0 13 * * 1-5", Chicago.parse("2026-10-02T18:00:00-05:00"), -300) == Chicago.parse("2026-10-05T13:00:00-05:00"))
        #expect(fire("0 6 * * 7", mon9pm, -300) == Chicago.parse("2026-10-04T06:00:00-05:00"))
        #expect(fire("0 13 * * 1-5", mon9pm, -420) == Chicago.parse("2026-09-29T13:00:00-07:00"))
        #expect(fire("30 8 * * *", Chicago.date(2026, 8, 28, 21, 5), nil) == Chicago.date(2026, 8, 29, 8, 30))
        #expect(fire("every 30m", Date(), nil) == nil)
        #expect(fire("61 * * * *", Date(), nil) == nil)
        #expect(fire("0 0 31 2 *", Date(), nil) == nil)
    }

    @Test func readsTheWrittenOffset() {
        #expect(JobWords.writtenOffset("2026-10-05T13:00:00-05:00") == -300)
        #expect(JobWords.writtenOffset("2026-10-05T13:00:00Z") == 0)
        #expect(JobWords.writtenOffset("2026-10-05T13:00:00+0530") == 330)
        #expect(JobWords.writtenOffset("2026-10-05T13:00:00") == nil)
    }

    @Test func saysASkippedWeekPlainly() {
        #expect(cron("0 13 * * 1-5", "2026-10-05T13:00:00-05:00", "scheduled", "Weekdays at 1:00 PM") == "Skipped until Mon, Oct 5")
    }

    @Test func doesNotCallARunSkippedAcrossADaylightSavingChange() {
        let sat = Chicago.parse("2026-10-31T09:30:00-05:00")
        #expect(!cron("0 9 * * *", "2026-11-01T09:00:00-06:00", "scheduled", "Daily at 9:00 AM", now: sat).hasPrefix("Skipped"))
        #expect(cron("0 9 * * *", "2026-11-01T09:00:00-06:00", "scheduled", "Daily at 9:00 AM",
                     now: Chicago.parse("2026-10-31T08:30:00-05:00")).hasPrefix("Skipped"))
        #expect(cron("0 9 * * *", "2026-11-03T09:00:00-06:00", "scheduled", "Daily at 9:00 AM", now: sat).hasPrefix("Skipped"))
    }

    @Test func namesTheDayWhenTheScheduleAlreadyNamesTheTime() {
        #expect(cron("0 13 * * 1-5", "2026-09-29T13:00:00-05:00", "scheduled", "Weekdays at 1:00 PM") == "Next tomorrow")
        #expect(cron("0 18 * * 0", "2026-10-04T18:00:00-05:00", "scheduled", "Every Sunday at 6:00 PM") == "Next Sunday")
        #expect(cron("0 22 * * *", "2026-09-28T22:00:00-05:00", "scheduled", "Every day at 10:00 PM",
                     now: Chicago.parse("2026-09-28T20:00:00-05:00")) == "Next today")
    }

    @Test func keepsTheTimeWhenTheScheduleDoesNotSayIt() {
        #expect(every(360, "2026-09-28T23:11:00-05:00", "Every 6 hours") == "Next 11:11 PM")
        #expect(every(360, "2026-09-29T05:12:00-05:00", "Every 6 hours") == "Next tomorrow 5:12 AM")
        #expect(cron("0 9,13,17 * * *", "2026-09-29T09:00:00-05:00", "scheduled", "Every day at 9:00 AM, 1:00 PM and 5:00 PM") == "Next tomorrow 9:00 AM")
        #expect(cron("*/30 9-19 * * *", "2026-09-29T09:00:00-05:00", "scheduled", "Every 30 minutes, 9:00 AM–7:59 PM") == "Next tomorrow 9:00 AM")
    }

    @Test func countsMinutesInsideTheHour() {
        #expect(every(30, "2026-09-28T21:17:00-05:00", "Every 30 minutes") == "Next in 12 min")
        #expect(every(30, "2026-09-28T21:05:20-05:00", "Every 30 minutes") == "Next in 1 min")
    }

    @Test func usesTheSchedulerGraceTheSectionsUse() {
        #expect(every(30, "2026-09-28T21:04:00-05:00", "Every 30 minutes") == "Due now")
        #expect(every(30, "2026-09-28T20:51:00-05:00", "Every 30 minutes") == "Due now")
        #expect(every(30, "2026-09-28T20:49:00-05:00", "Every 30 minutes") == "Overdue")
    }

    @Test func saysNothingForJobsThatWillNotRunOrOneOffs() {
        #expect(cron("0 16 * * 5", "2026-10-02T16:00:00-05:00", "paused", "Every Friday at 4:00 PM") == "")
        #expect(JobWords.jobNextWords(state: "scheduled", schedule: CronSchedule(kind: "once"), nextRunAt: "2026-10-02T08:00:00-05:00",
                                      scheduleWords: "Once on Fri, Oct 2 at 8:00 AM", now: mon9pm, calendar: c) == "")
        #expect(cron("0 9 * * *", nil, "scheduled", "Every day at 9:00 AM") == "")
    }

    @Test func datesRunsAWeekOrMoreOut() {
        #expect(cron("0 6 1 * *", "2026-10-01T06:00:00-05:00", "scheduled", "Monthly on day 1 at 6:00 AM",
                     now: Chicago.parse("2026-09-20T12:00:00-05:00")) == "Next Thu, Oct 1")
        #expect(every(20160, "2026-10-06T06:00:00-05:00", "Every 14 days") == "Next Tue, Oct 6, 6:00 AM")
    }
}

struct JobWordsLabelTests {
    let c = Chicago.calendar

    @Test func titlesARunByItsTimeAndSkipsTheInjectedPrefix() {
        #expect(JobWords.runPreview("[IMPORTANT: You are running as a scheduled cron job. DELIVER...") == "")
        #expect(JobWords.runPreview("[IMPORTANT: quiet] Morning note sent") == "Morning note sent")
        var run = CronRun(id: "r1")
        run.startedAt = Chicago.parse("2026-06-01T15:17:00Z").timeIntervalSince1970
        run.messageCount = 4
        run.title = "[IMPORTANT: You are running as a sch…"
        let label = JobWords.cronRunLabel(run, calendar: c)
        #expect(label.title.contains("Jun 1"))
        #expect(label.title == "Mon, Jun 1, 10:17 AM")
        #expect(label.detail == "4 messages")
        var weekly = CronRun(id: "r2")
        weekly.startedAt = 1
        weekly.messageCount = 6
        weekly.title = "alex-weekly-review · Sep 20 18:00"
        weekly.preview = "Weekly review sent"
        #expect(JobWords.cronRunLabel(weekly, calendar: c).detail == "6 messages · Weekly review sent")
        weekly.preview = nil
        #expect(JobWords.cronRunLabel(weekly, calendar: c).detail == "6 messages")
    }

    @Test func saysAScriptRunsOutcome() {
        var doc = CronRun(id: "cron_output:j-script:2026-10-09_08-00-00")
        doc.source = "cron_output"
        doc.title = "COMPLETED · Disk 71% used"
        #expect(JobWords.cronRunLabel(doc, calendar: c).detail == "Completed")
        #expect(doc.opens == .document(stem: "2026-10-09_08-00-00"))
        var exec = CronRun(id: "cron_output:j-script:exec:3")
        exec.source = "cron_output"
        exec.title = "FAILED · PermissionError: Permission denied"
        #expect(JobWords.cronRunLabel(exec, calendar: c).detail == "Failed · Permission denied")
        #expect(exec.opens == .nothing)
        var latest = CronRun(id: "cron_output:j-script:latest")
        latest.source = "cron_output"
        #expect(latest.opens == .nothing)
        #expect(CronRun(id: "cron_j_20261009_080000").opens == .chat)
        var header = CronRun(id: "cron_output:x:y")
        header.source = "cron_output"
        header.title = "# Cron Job: x (FAILED)"
        #expect(JobWords.cronRunLabel(header, calendar: c).detail == "Failed")
    }

    @Test func saysWhereAJobDeliversInWords() {
        let dm = CronOrigin(platform: "telegram", chatId: "100000001", chatName: "Alex Rivera", threadId: "None")
        let group = CronOrigin(platform: "telegram", chatId: "-1003745705383", chatName: "Hermes Projects", threadId: "13822")
        let labels = ["local": "Keep in Hermes (no message)", "telegram": "Telegram"]
        #expect(JobWords.humanDeliver("origin", origin: dm, labels: labels) == "Where it was created · Telegram · Alex Rivera")
        #expect(JobWords.humanDeliver("origin", origin: nil, labels: labels) == "Where it was created")
        #expect(JobWords.humanDeliver("telegram:-1003745705383:28549", origin: group, labels: labels) == "Telegram · Hermes Projects (topic 28549)")
        #expect(JobWords.humanDeliver("telegram:-1003994007489:24", origin: dm, labels: labels) == "Telegram · group …7489 (topic 24)")
        #expect(JobWords.humanDeliver("telegram:555", origin: nil, labels: labels) == "Telegram · chat 555")
        #expect(JobWords.humanDeliver("email:ops@example.com", origin: nil, labels: labels) == "Email · ops@example.com")
        #expect(JobWords.humanDeliver("telegram:-1001111111111,telegram:-1002222222222", origin: dm, labels: labels)
                == "Telegram · group …1111 + Telegram · group …2222")
        #expect(JobWords.humanDeliver("telegram:-1001111111111,telegram:-1009999991111", origin: dm, labels: labels)
                == "Telegram · group 1111111111 + Telegram · group 9999991111")
        #expect(JobWords.humanDeliver("telegram", origin: dm, labels: labels) == "Telegram")
        #expect(JobWords.humanDeliver("local", origin: dm, labels: labels) == "Keep in Hermes (no message)")
        #expect(JobWords.humanDeliver("local,telegram", origin: dm, labels: labels) == "Telegram", "local beside a place adds nothing")
        #expect(JobWords.humanDeliver("") == "Keep in Hermes (no message)")
        #expect(JobWords.humanDeliverTarget("homeassistant") == "Home Assistant")
        #expect(JobWords.humanDeliverTarget("groupme") == "GroupMe")
        #expect(JobWords.humanDeliverTarget("bluebubbles") == "BlueBubbles")
        #expect(JobWords.humanDeliverTarget("groupme:12345") == "GroupMe · chat …2345")
        #expect(JobWords.humanDeliverTarget("my_bridge") == "My Bridge")
    }

    @Test func namesAChatByWhatAnyJobKnowsAboutIt() {
        var a = CronJob(id: "a")
        a.origin = CronOrigin(platform: "telegram", chatId: "-1003791915383", chatName: "Hermes Projects", threadId: "28549")
        let names = JobWords.knownChatNames([a, CronJob(id: "b"), CronJob(id: "c")])
        #expect(names == ["telegram:-1003791915383": "Hermes Projects"])
        #expect(JobWords.humanDeliver("telegram:-1003791915383:28549", names: names) == "Telegram · Hermes Projects (topic 28549)")
        #expect(JobWords.humanDeliver("telegram:-1003791915383:28549") == "Telegram · group …5383 (topic 28549)")
        #expect(JobWords.humanDeliverTarget("telegram:-1003791915383", origin: CronOrigin(platform: "telegram", chatId: "-1003791915383",
                                                                                          chatName: "Own name"), names: names) == "Telegram · Own name")
    }

    @Test func namesADeliveryTargetByItsProfile() {
        #expect(JobWords.readableTargetName("Bot Chat (maple-revenue-operator)") == "Bot Chat (Maple Revenue Operator)")
        #expect(JobWords.readableTargetName("Bot Chat (ivy)", profiles: ["ivy": "Ivy the Scheduler"]) == "Bot Chat (Ivy the Scheduler)")
        #expect(JobWords.readableTargetName("Bot Chat (default)") == "Bot Chat (Hermes)")
        #expect(JobWords.readableTargetName("Telegram") == "Telegram")
    }

    @Test func saysOneTimeTheSameWayOnEveryPage() {
        let now = Chicago.date(2026, 8, 27, 10)
        func say(_ d: Date?) -> String { JobWords.relativeDateTime(d, now: now, calendar: c) }
        #expect(say(Chicago.date(2026, 8, 27, 9, 5)) == "Today at 9:05 AM")
        #expect(say(Chicago.date(2026, 8, 26, 16, 7)) == "Yesterday at 4:07 PM")
        #expect(say(Chicago.date(2026, 8, 28, 6, 0)) == "Tomorrow at 6:00 AM")
        #expect(say(Chicago.date(2026, 8, 23, 6, 1)) == "Wed at 6:01 AM")
        #expect(say(Chicago.date(2026, 9, 1, 6, 0)) == "Thu at 6:00 AM")
        #expect(say(Chicago.date(2026, 8, 12, 16, 7)) == "Sep 12 at 4:07 PM")
        #expect(say(Chicago.date(2025, 11, 31, 23, 0)) == "Dec 31, 2025 at 11:00 PM")
        #expect(say(nil) == "")
        #expect(JobWords.relativeDateTime("soon", now: now, calendar: c) == "")
    }

    @Test func asksBeforeRunNowNamingTheJobAndWhereItsResultGoes() {
        let labels = ["local": "Run History Only", "telegram": "Telegram"]
        let local = JobWords.runNowCopy("Weekly review", deliver: "local", labels: labels)
        #expect(local.title == "Run “Weekly review” now?")
        #expect(local.description == "Its result is kept in its Run History. Its schedule does not change.")
        #expect(JobWords.runAlertTitle(local.title) == "Run “Weekly review” Now?")
        #expect(JobWords.runNowCopy("Weekly review", deliver: "origin", origin: CronOrigin(platform: "telegram", chatId: "42", chatName: "Alex Rivera"),
                                    labels: labels).description == "It delivers to Alex Rivera on Telegram. Its schedule does not change.")
        #expect(JobWords.runNowCopy("Digest", deliver: "telegram,discord:-1001234567890", labels: labels,
                                    names: ["discord:-1001234567890": "Ops"]).description == "It delivers to Telegram and Ops on Discord. Its schedule does not change.")
        #expect(JobWords.runNowCopy("Digest", deliver: "origin", labels: labels).description == "It delivers to the chat it came from. Its schedule does not change.")
    }

    @Test func readsSlugNamesAsWordsAndLeavesRealTitlesAlone() {
        let casing = JobWords.knownWordCasing(["GBrain automatic updater", "Daily NHB+ new call notes publisher", "FLOP testnet launch watcher",
                                               "gbrain-daily-update-check-local"])
        #expect(JobWords.humanJobTitle("alex-midday-filtered-alert") == "Alex midday filtered alert")
        #expect(JobWords.humanJobTitle("gbrain-daily-update-check-local", casing: casing) == "GBrain daily update check local")
        #expect(JobWords.humanJobTitle("northwind-shipstation-check") == "Northwind shipstation check")
        #expect(JobWords.humanJobTitle("ios_build_pr_watch") == "iOS build PR watch")
        #expect(JobWords.humanJobTitle("nhb-weekly-sync", casing: casing) == "NHB weekly sync")
        #expect(JobWords.humanJobTitle("Crypto Scout shadow-mode signal collection") == "Crypto Scout shadow-mode signal collection")
        #expect(JobWords.humanJobTitle("backup") == "backup")
        #expect(JobWords.humanJobTitle("KPI-Weekly") == "KPI-Weekly")
    }

    @Test func scriptJobsAndErrorSummaries() {
        var job = CronJob(id: "s")
        job.noAgent = true
        job.script = "echo hi"
        #expect(JobWords.jobIsScriptOnly(job))
        job.noAgent = false
        #expect(!JobWords.jobIsScriptOnly(job))
        job.noAgent = true
        job.script = ""
        #expect(!JobWords.jobIsScriptOnly(job))
        var d = CronJob(id: "d")
        d.prompt = "Summarize mail"; d.script = "sync.sh"
        #expect(JobWords.jobDescription(d) == "Summarize mail")
        d.prompt = ""; d.script = "sync_quillreach_cron.sh"
        #expect(JobWords.jobDescription(d) == "sync_quillreach_cron.sh")
        let raw = "RuntimeError: Cron job 'x' has no model configured (job.model=None, HERMES_MODEL=''). Set a per-job model via `hermes cron edit x --model <name>`."
        #expect(JobWords.lastErrorSummary(raw) == "Cron job 'x' has no model configured (job.model=None, HERMES_MODEL='').")
        #expect(JobWords.lastErrorSummary("[blocked_config:silent] ⚠️ ValueError: bad schedule\nDetails follow") == "bad schedule")
        let long = JobWords.lastErrorSummary("HTTPStatusError: " + String(repeating: "x", count: 400))
        #expect(long.count <= 200 && long.hasSuffix("…"))
        #expect(JobWords.lastErrorSummary(nil) == "")
        #expect(JobWords.lastErrorSummary("   ") == "")
    }

    @Test func jobStateTitleAndLastRun() {
        var job = CronJob(id: "j")
        #expect(JobWords.jobState(job) == "scheduled")
        job.enabled = false
        #expect(JobWords.jobState(job) == "disabled")
        job.state = "paused"
        #expect(JobWords.jobState(job) == "paused")
        #expect(JobWords.jobTitle(job) == "j")
        job.prompt = String(repeating: "a", count: 70)
        #expect(JobWords.jobTitle(job) == String(repeating: "a", count: 60) + "…")
        var failed = CronJob(id: "f")
        failed.lastStatus = "error"
        #expect(JobWords.lastRunFailed(failed))
        failed.state = "paused"
        #expect(!JobWords.lastRunFailed(failed))
        var ran = CronJob(id: "r")
        ran.lastRunAt = "2026-09-27T09:05:00-05:00"
        ran.lastStatus = "ok"
        #expect(JobWords.lastRunNote(ran, now: Chicago.date(2026, 8, 27, 10), calendar: c) == "Last ran today at 9:05 AM · OK")
        ran.lastError = "boom"
        #expect(JobWords.lastRunNote(ran, now: Chicago.date(2026, 8, 28, 10), calendar: c) == "Last ran yesterday at 9:05 AM · Failed")
    }
}

/// P-U2: completed > paused/disabled > running > (error|failed|overdue) > scheduled.
struct JobSectionsTests {
    @Test func explicitInactiveStatesWin() {
        #expect(JobWords.jobSection(state: "completed", overdue: 1000, failed: true) == .completed)
        #expect(JobWords.jobSection(state: "paused", overdue: 1000, failed: true) == .paused)
        #expect(JobWords.jobSection(state: "disabled", overdue: nil, failed: false) == .paused)
        #expect(JobWords.jobSection(state: "running", overdue: 1000, failed: true) == .running)
        #expect(JobWords.jobSection(state: "error", overdue: nil, failed: false) == .needsAttention)
        #expect(JobWords.jobSection(state: "scheduled", overdue: nil, failed: true) == .needsAttention)
        #expect(JobWords.jobSection(state: "scheduled", overdue: 60, failed: false) == .needsAttention)
        #expect(JobWords.jobSection(state: "scheduled", overdue: nil, failed: false) == .scheduled)
        #expect(JobWords.Section.allCases.map(\.rawValue) == ["Needs Attention", "Running", "Scheduled", "Paused", "Completed"])
    }

    @Test func overdueUsesTheFifteenMinuteGrace() {
        let now = Date()
        var job = CronJob(id: "late")
        job.nextRunAt = Chicago.iso(now.addingTimeInterval(-14 * 60))
        #expect(JobWords.nextRunOverdue(job, now: now) == nil)
        job.nextRunAt = Chicago.iso(now.addingTimeInterval(-20 * 60))
        #expect(JobWords.nextRunOverdue(job, now: now) != nil)
        #expect(JobWords.section(job, now: now) == .needsAttention)
        job.state = "paused"
        #expect(JobWords.nextRunOverdue(job, now: now) == nil)
    }

    /// Hermes never stores "running": a run the scheduler started shows through the job's latest attempt.
    @MainActor @Test func aRunTheSchedulerStartedIsRunning() throws {
        let json = try JSONValue.parse(Data(#"""
        {"id":"r1","name":"midday-alert","enabled":true,"state":"scheduled",
         "schedule":{"kind":"cron","expr":"0 13 * * 1-5"},"next_run_at":"2026-10-26T13:00:00-05:00",
         "last_run_at":"2026-10-24T13:00:41.502113-05:00","last_status":"error","last_error":"RuntimeError: boom",
         "latest_execution":{"id":"e9","job_id":"r1","status":"running","claimed_at":"2026-10-25T13:00:00.031870-05:00",
                             "started_at":"2026-10-25T13:00:00.120044-05:00","finished_at":null}}
        """#.utf8))
        var job = try #require(CronJob(json: json))
        #expect(job.latestRunStatus == "running")
        #expect(JobWords.runIsOut(job))
        #expect(JobWords.jobState(job) == "running")
        #expect(JobWords.section(job) == .running)
        #expect(JobWords.statusWord(job) == "Running")   // over the earlier failure
        #expect(JobWords.rowSubtitle(job) == JobWords.scheduleWords(job))   // no next-run words while it runs

        job.latestRunStatus = "claimed"
        #expect(JobWords.isRunning(job))
        // Marked run after the claim: the attempt is about to close, so it is over.
        job.lastRunAt = "2026-10-25T13:04:10-05:00"
        #expect(!JobWords.runIsOut(job))
        #expect(JobWords.jobState(job) == "scheduled")
        job.lastRunAt = nil
        #expect(JobWords.runIsOut(job))
        for done in ["completed", "failed", "unknown", ""] {
            job.latestRunStatus = done
            #expect(!JobWords.isRunning(job))
        }

        // A paused job's run (Run Now from another device): its row says Running, its section stays Paused.
        job.latestRunStatus = "running"
        job.enabled = false
        job.state = "paused"
        #expect(JobWords.jobState(job) == "paused")
        #expect(JobWords.section(job) == .paused)
        #expect(JobWords.isRunning(job))
        #expect(JobActions.isPaused(job))

        // An older gateway sends no attempt: nothing changes.
        let old = try JSONValue.parse(Data(#"{"id":"o","enabled":true,"state":"scheduled"}"#.utf8))
        #expect(try #require(CronJob(json: old)).latestRunStatus == nil)
        #expect(JobWords.jobState(try #require(CronJob(json: old))) == "scheduled")
    }

    /// A Bot Chat job's run closes at the handoff; the bot still working on its output (the add-on's word) is Running too.
    @MainActor @Test func aBotStillOnTheOutputIsRunning() throws {
        var job = try #require(CronJob(json: try JSONValue.parse(Data(#"""
        {"id":"b1","name":"morning brief","enabled":true,"state":"scheduled","deliver":"bot-chat",
         "schedule":{"kind":"cron","expr":"0 7 * * *"},"next_run_at":"2026-10-26T07:00:00-05:00",
         "last_run_at":"2026-10-25T07:01:12-05:00","last_status":"ok",
         "latest_execution":{"id":"e1","status":"completed","claimed_at":"2026-10-25T07:00:00-05:00"}}
        """#.utf8))))
        #expect(job.botWorking == nil, "Hermes's list never says it")
        #expect(!JobWords.isRunning(job))
        for status in ["claimed", "queued"] {
            job.botWorking = status
            #expect(JobWords.workIsOut(job) && !JobWords.runIsOut(job))
            #expect(JobWords.jobState(job) == "running" && JobWords.section(job) == .running)
            #expect(JobWords.statusWord(job) == "Running")
            #expect(JobWords.rowSubtitle(job) == JobWords.scheduleWords(job))
        }
        job.enabled = false
        job.state = "paused"
        #expect(JobWords.section(job) == .paused && JobWords.isRunning(job))

        // A list saved before 374 decodes without it.
        var saved = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        saved["botWorking"] = nil
        let old = try JSONDecoder().decode(CronJob.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(old.botWorking == nil && old.id == "b1")
    }

    @Test func decodesTheGatewaysJobRecord() throws {
        let json = try JSONValue.parse(Data(#"""
        {"id":"a1b2c3","name":"alex-midday-filtered-alert","prompt":"…","skills":[],"script":null,"no_agent":false,
         "schedule":{"kind":"cron","expr":"0 13 * * 1-5","display":"0 13 * * 1-5"},
         "schedule_display":"0 13 * * 1-5","enabled":true,"state":"scheduled",
         "next_run_at":"2026-10-12T13:00:00-05:00","last_run_at":"2026-10-09T13:00:04-05:00",
         "last_status":"ok","last_error":null,"deliver":"origin",
         "origin":{"platform":"telegram","chat_id":100000001,"chat_name":"Alex Rivera","thread_id":null},
         "model":null,"provider":null,"profile":"inbox","profile_name":"inbox","hermes_home":"/Users/x/.hermes/profiles/inbox",
         "is_default_profile":false,"scheduler_heartbeat_age_s":12.4}
        """#.utf8))
        let job = try #require(CronJob(json: json))
        #expect(job.key == "inbox|a1b2c3")
        #expect(job.origin?.chatId == "100000001")
        #expect(job.schedule?.expr == "0 13 * * 1-5")
        #expect(JobWords.humanDeliver(job.deliver ?? "", origin: job.origin) == "Where it was created · Telegram · Alex Rivera")
        // The demo's record lacks origin/hermes_home/profile_name: still a job.
        let demo = try JSONValue.parse(Data(#"{"id":"j1","name":"Morning inbox triage","profile":"inbox","enabled":true,"state":"scheduled"}"#.utf8))
        #expect(CronJob(json: demo)?.owner == "inbox")
    }
}
