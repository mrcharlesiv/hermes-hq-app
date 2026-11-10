// UX study 2026-10-19, the Jobs and More batch: the words chosen from state (job row leads and subtitles, the empty
// Skills card, the Messaging row's issue count, Review's plain change words and symbols, the badge's meaning).

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct MorePagesStudyTests {
    private func job(state: String? = nil) -> CronJob {
        var job = CronJob(id: "j")
        job.state = state
        job.schedule = CronSchedule(kind: "interval", display: "Every 30 minutes", minutes: 30)
        job.nextRunAt = "2026-09-27T10:04:00-05:00"
        return job
    }

    /// #37: a running job (the gateway says so, or a Run Now is out) says when it runs next no more.
    @Test func aRunningJobDropsItsNextRun() {
        let now = Chicago.date(2026, 8, 27, 10)
        let schedule = JobWords.scheduleWords(job(), now: now, calendar: Chicago.calendar)
        let scheduled = JobWords.rowSubtitle(job(), now: now, calendar: Chicago.calendar)
        #expect(scheduled.hasPrefix(schedule) && scheduled != schedule, "\(scheduled)")
        #expect(JobWords.rowSubtitle(job(state: "running"), now: now, calendar: Chicago.calendar) == schedule)
        #expect(JobWords.rowSubtitle(job(), now: now, calendar: Chicago.calendar, running: true) == schedule)
    }

    /// #37, #42: running wins, then a failed last run, then paused (said in words, not by dimming).
    @Test func rowLeads() {
        #expect(JobWords.rowLead(running: true, failed: true, paused: false) == .running)
        #expect(JobWords.rowLead(running: false, failed: true, paused: false) == .failed)
        #expect(JobWords.rowLead(running: false, failed: false, paused: true) == .paused)
        #expect(JobWords.rowLead(running: false, failed: false, paused: false) == .none)
        #expect(JobWords.RowLead.paused.rawValue == "Paused · ")
        #expect(JobWords.RowLead.none.rawValue.isEmpty)
        // #87: the running lead has the others' separator.
        #expect(JobWords.RowLead.running.rawValue == "Running · ")
        // #80: overdue leads after a failed run, before nothing.
        #expect(JobWords.rowLead(running: false, failed: true, overdue: true, paused: false) == .failed)
        #expect(JobWords.rowLead(running: false, failed: false, overdue: true, paused: false) == .overdue)
        #expect(JobWords.RowLead.overdue.rawValue == "Overdue · ")
    }

    /// #80, #86: an overdue row's lead says Overdue, so its subtitle no longer ends in it; the dot before the next-run
    /// words keeps to the schedule (a no-break space).
    @Test func overdueRowSubtitle() {
        let now = Chicago.date(2026, 8, 27, 11)
        let schedule = JobWords.scheduleWords(job(), now: now, calendar: Chicago.calendar)
        #expect(JobWords.rowSubtitle(job(), now: now, calendar: Chicago.calendar) == schedule)
        var failed = job()
        failed.lastError = "RuntimeError: boom"
        #expect(JobWords.rowSubtitle(failed, now: now, calendar: Chicago.calendar) == "\(schedule)\u{00A0}· Overdue")
    }

    /// #55: the empty Skills card says how skills get added.
    @Test func emptySkillsWords() {
        let offered = SkillsEmptyWords.make(botName: "Hermes", hasAvailable: true)
        #expect(offered.title == "No Skills Installed")
        #expect(offered.text == "Install one from the list below, or ask Hermes in a chat to make one.")
        #expect(offered.action == "Search Skills")
        // Nothing left to install: no search button that could only find nothing.
        let none = SkillsEmptyWords.make(botName: "Scout", hasAvailable: false)
        #expect(none.text == "Ask Scout in a chat to make one.")
        #expect(none.action == nil)
    }

    /// #118: only red statuses count as issues, and VoiceOver hears which.
    @Test func messagingIssues() {
        let ok = MessagingPlatform(id: "telegram", name: "Telegram", configured: true, enabled: true, gatewayRunning: true, state: "connected")
        let setup = MessagingPlatform(id: "slack", name: "Slack", configured: false)
        let refused = MessagingPlatform(id: "discord", name: "Discord", configured: true, enabled: true, gatewayRunning: true,
                                        state: "fatal", errorMessage: "bot token was refused")
        #expect(MessagingIssues.rowWords([ok, setup]) == nil)
        #expect(MessagingIssues.rowWords([ok, refused]) == .init(text: "1 Issue", spoken: "Discord: bot token was refused"))
        var second = refused
        second.id = "matrix"; second.name = "Matrix"
        #expect(MessagingIssues.rowWords([refused, second])?.text == "2 Issues")
    }

    /// #116: Review in plain words, with symbols in place of git's letters.
    @Test func reviewWordsAndSymbols() {
        #expect(WorkspaceChange(path: "a", added: 1, removed: 0, status: "M", staged: false).statusName == "Changed")
        #expect(WorkspaceChange(path: "a", added: 1, removed: 0, status: "?", staged: false).statusName == "New file")
        #expect(MoreWorkspaceRoot.statusSymbol("?") == "plus.square.fill")
        #expect(MoreWorkspaceRoot.statusSymbol("D") == "minus.square.fill")
        #expect(MoreWorkspaceRoot.statusSymbol("weird") == "pencil.circle.fill")
    }

    /// #50: Bot Profiles says what its count counts. Item 4: no "installed", no zero wrapping across lines.
    @MainActor @Test func profileSkillCount() {
        #expect(ProfilesModel.skills(0) == "No skills")
        #expect(ProfilesModel.skills(1) == "1 skill")
        #expect(ProfilesModel.skills(12) == "12 skills")
    }
}
