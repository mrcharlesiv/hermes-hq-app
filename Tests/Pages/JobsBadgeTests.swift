// [jobs-badge] The Jobs tab's red count: every job under Needs Attention (a failed run, an overdue run, the error
// state), never a paused one, cleared when the jobs are fixed or, with "When Seen", once the Jobs list has shown them.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct JobsBadgeTests {
    /// Noon on 2026-11-20 in UTC.
    private let now = PagesDate.parse("2026-11-20T12:00:00Z")!

    /// A scheduled job that last ran fine an hour ago and runs next in an hour.
    private func job(_ id: String, state: String? = nil, lastStatus: String? = "ok", lastRunAt: String? = "2026-11-20T11:00:00Z",
                     next: String? = "2026-11-20T13:00:00Z") -> CronJob {
        var job = CronJob(id: id)
        job.state = state
        job.lastStatus = lastStatus
        job.lastRunAt = lastRunAt
        job.nextRunAt = next
        return job
    }

    private func failed(_ id: String, state: String? = nil, at: String = "2026-11-20T11:00:00Z") -> CronJob {
        job(id, state: state, lastStatus: "error", lastRunAt: at)
    }

    /// An hour past its next run (the grace is 15 minutes).
    private func overdue(_ id: String, state: String? = nil, next: String = "2026-11-20T11:00:00Z") -> CronJob {
        job(id, state: state, next: next)
    }

    @Test func everyJobUnderNeedsAttentionCounts() {
        var withError = job("e")
        withError.lastStatus = nil
        withError.lastError = "RuntimeError: the model timed out"
        let jobs = [job("fine"), failed("f"), overdue("o"), job("s", state: "error"), withError]
        #expect(jobs.map { JobWords.section($0, now: now) } == [.scheduled, .needsAttention, .needsAttention, .needsAttention, .needsAttention])
        #expect(JobsBadge.count(jobs, now: now, clear: .whenFixed, seen: []) == 4)
        #expect(JobsBadge.count([job("fine")], now: now, clear: .whenFixed, seen: []) == 0)
        #expect(JobsBadge.count([], now: now, clear: .whenSeen, seen: []) == 0)
    }

    @Test func pausedJobsNeverCount() {
        let jobs = [failed("pf", state: "paused"), overdue("po", state: "paused"), failed("df", state: "disabled"),
                    failed("cf", state: "completed")]
        #expect(JobsBadge.count(jobs, now: now, clear: .whenFixed, seen: []) == 0)
        #expect(JobsBadge.count(jobs, now: now, clear: .whenSeen, seen: []) == 0)
        var off = failed("off")
        off.enabled = false   // no state: an enabled false job is "disabled"
        #expect(JobsBadge.mark(off, now: now) == nil)
    }

    @Test func aJobRunningAgainIsUnderRunningNotNeedsAttention() {
        var retry = failed("r")
        retry.latestRunStatus = "running"
        #expect(JobWords.section(retry, now: now) == .running)
        #expect(JobsBadge.count([retry], now: now, clear: .whenFixed, seen: []) == 0)
    }

    @Test func overdueCountsOnlyPastTheGrace() {
        let inGrace = overdue("g", next: "2026-11-20T11:50:00Z")   // 10 minutes late
        #expect(JobsBadge.count([inGrace], now: now, clear: .whenFixed, seen: []) == 0)
        #expect(JobsBadge.count([inGrace], now: now.addingTimeInterval(6 * 60), clear: .whenFixed, seen: []) == 1)
    }

    @Test func whenSeenSkipsWhatTheListShowedAndCountsANewProblemAgain() {
        let jobs = [failed("a"), overdue("b"), job("fine")]
        let seen = JobsBadge.marks(jobs, now: now)
        #expect(seen.count == 2, "only the jobs under Needs Attention are marked")
        #expect(JobsBadge.count(jobs, now: now, clear: .whenSeen, seen: seen) == 0)
        #expect(JobsBadge.count(jobs, now: now, clear: .whenFixed, seen: seen) == 2, "When Fixed ignores what was seen")

        // "a" failed again on a later run, "b" missed a later run, and "fine" failed for the first time.
        let later = now.addingTimeInterval(3 * 3600)
        let next = [failed("a", at: "2026-11-20T14:00:00Z"), overdue("b", next: "2026-11-20T13:30:00Z"), failed("fine", at: "2026-11-20T14:00:00Z")]
        #expect(JobsBadge.count(next, now: later, clear: .whenSeen, seen: seen) == 3)

        // The same failure read again (another list read) stays seen.
        #expect(JobsBadge.count([failed("a")], now: now.addingTimeInterval(60), clear: .whenSeen, seen: seen) == 0)
    }

    @Test func aFixedJobLeavesTheCount() {
        let seen = JobsBadge.marks([failed("a")], now: now)
        let fixed = job("a", lastRunAt: "2026-11-20T11:30:00Z")
        #expect(JobsBadge.count([fixed], now: now, clear: .whenFixed, seen: seen) == 0)
        #expect(JobsBadge.count([fixed], now: now, clear: .whenSeen, seen: seen) == 0)
    }

    @Test func theSameIdUnderTwoProfilesCountsTwice() {
        var one = failed("same"), two = failed("same")
        one.profile = "default"
        two.profile = "research"
        #expect(JobsBadge.count([one, two], now: now, clear: .whenFixed, seen: []) == 2)
        #expect(JobsBadge.count([one, two], now: now, clear: .whenSeen, seen: JobsBadge.marks([one], now: now)) == 1)
    }

    @Test func theNextChangeIsTheSoonestJobTurningOverdue() {
        let soon = job("soon", next: "2026-11-20T12:30:00Z"), later = job("later", next: "2026-11-20T18:00:00Z")
        let expected = PagesDate.parse("2026-11-20T12:30:00Z")!.addingTimeInterval(JobWords.overdueGrace + 1)
        #expect(JobsBadge.nextChange([later, soon], now: now) == expected)
        #expect(JobsBadge.count([soon], now: expected, clear: .whenFixed, seen: []) == 1, "overdue at that moment")
        #expect(JobsBadge.count([soon], now: expected.addingTimeInterval(-2), clear: .whenFixed, seen: []) == 0, "not before")
        // Paused, already counted, or with no next run: nothing to wait for.
        #expect(JobsBadge.nextChange([job("p", state: "paused", next: "2026-11-20T12:30:00Z"), overdue("o"), job("n", next: nil)], now: now) == nil)
        // In its grace now: overdue once the grace is up.
        let inGrace = job("g", next: "2026-11-20T11:50:00Z")
        #expect(JobsBadge.nextChange([inGrace], now: now) == PagesDate.parse("2026-11-20T11:50:00Z")!.addingTimeInterval(JobWords.overdueGrace + 1))
    }

    @Test func theFooterSaysWhatCountsAndWhenItClears() {
        #expect(SettingsWords.jobsBadgeFooter(.whenFixed) == SettingsWords.jobsBadgeLead
                + " When Fixed: a job counts until it runs without a problem, or you pause or delete it.")
        #expect(SettingsWords.jobsBadgeFooter(.whenSeen) == SettingsWords.jobsBadgeLead
                + " When Seen: the number clears once you open Jobs, and a job counts again if it fails or runs late again.")
        #expect(SettingsWords.jobsBadgeLead.contains("Paused jobs never count."))
        #expect(JobsBadgeClear.allCases.map(\.title) == ["When Fixed", "When Seen"])
    }

    // MARK: The store

    private static func list() -> JSONValue {
        .array([
            ["id": "a", "name": "Morning digest", "profile": "default", "enabled": true, "state": "scheduled",
             "last_status": "error", "last_run_at": "2026-11-20T11:00:00Z", "next_run_at": "2026-11-21T09:00:00Z"],
            ["id": "b", "name": "Weekly cleanup", "profile": "default", "enabled": true, "state": "paused",
             "last_status": "error", "last_run_at": "2026-11-20T10:00:00Z", "next_run_at": "2026-11-27T09:00:00Z"],
            ["id": "c", "name": "Inbox check", "profile": "default", "enabled": true, "state": "scheduled",
             "last_status": "ok", "last_run_at": "2026-11-20T11:30:00Z", "next_run_at": "2026-11-20T12:30:00Z"],
        ])
    }

    @Test func theStoreRemembersWhatTheListShowedForEachAccount() async {
        let account = GatewayAccount(id: "http://127.0.0.1:9735|badge-\(UUID().uuidString)", baseURL: URL(string: "http://127.0.0.1:9735")!,
                                     kind: .password, username: "badge", label: "badge fixture")
        let other = GatewayAccount(id: "http://127.0.0.1:9735|badge-\(UUID().uuidString)", baseURL: URL(string: "http://127.0.0.1:9735")!,
                                   kind: .password, username: "badge", label: "badge fixture")
        defer { for a in [account, other] { UserDefaults.standard.removeObject(forKey: JobsBadge.seenKey(a)) } }
        let client = PagesFakeClient { request in request.path == JobsStore.listPath ? Self.list() : .object([:]) }

        let store = JobsStore(client: client, account: account, directory: nil)
        await store.refresh()
        #expect(store.jobs.count == 3)
        #expect(store.attentionCount(clear: .whenFixed, now: now) == 1, "the failed job; the paused one doesn't count")
        #expect(store.attentionCount(clear: .whenSeen, now: now) == 1)
        store.markAttentionSeen(now: now)
        #expect(store.attentionCount(clear: .whenSeen, now: now) == 0)
        #expect(store.attentionCount(clear: .whenFixed, now: now) == 1)
        #expect(UserDefaults.standard.stringArray(forKey: JobsBadge.seenKey(account))?.count == 1)

        let again = JobsStore(client: client, account: account, directory: nil)
        await again.refresh()
        #expect(again.attentionCount(clear: .whenSeen, now: now) == 0, "a relaunch remembers what was seen")
        let elsewhere = JobsStore(client: client, account: other, directory: nil)
        await elsewhere.refresh()
        #expect(elsewhere.attentionCount(clear: .whenSeen, now: now) == 1, "another account's list hasn't been seen")

        again.reset()
        #expect(again.attentionSeen.isEmpty, "sign-out forgets it")
    }

    @Test func theStoreKeepsTheNewestSeenMarksOnly() async {
        let account = GatewayAccount(id: "http://127.0.0.1:9735|badge-\(UUID().uuidString)", baseURL: URL(string: "http://127.0.0.1:9735")!,
                                     kind: .password, username: "badge", label: "badge fixture")
        defer { UserDefaults.standard.removeObject(forKey: JobsBadge.seenKey(account)) }
        let old = (0..<JobsBadge.seenLimit).map { "old-\($0)" }
        UserDefaults.standard.set(old, forKey: JobsBadge.seenKey(account))
        let client = PagesFakeClient { request in request.path == JobsStore.listPath ? Self.list() : .object([:]) }
        let store = JobsStore(client: client, account: account, directory: nil)
        await store.refresh()
        store.markAttentionSeen(now: now)
        let kept = UserDefaults.standard.stringArray(forKey: JobsBadge.seenKey(account)) ?? []
        #expect(kept.count == JobsBadge.seenLimit)
        #expect(kept.first == "old-1", "the oldest went first")
        #expect(store.attentionCount(clear: .whenSeen, now: now) == 0)
        #expect(store.attentionSeen.count == JobsBadge.seenLimit)
    }
}
