// [jobs-badge] The Jobs tab's count: the jobs under Needs Attention (a failed last run, an overdue run or the error
// state; `JobWords.section`). A paused job never counts: its own section wins over a failure from an older run. Settings
// › Appearance › Tabs › Jobs Badge chooses when the count clears: when the jobs are fixed, or once the Jobs list has
// been seen (a job that needs attention again, for a new reason, counts again).

import Foundation

/// When the Jobs tab's count clears.
nonisolated enum JobsBadgeClear: String, CaseIterable, Identifiable, Sendable {
    /// While a job needs attention it counts: the count goes when the job runs fine, is paused, edited or deleted.
    case whenFixed
    /// A job counts until the Jobs list has shown it; a new failure or a new overdue run counts again.
    case whenSeen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whenFixed: "When Fixed"
        case .whenSeen: "When Seen"
        }
    }
}

nonisolated enum JobsBadge {
    /// Where an account's seen marks are kept on this device (gone at sign-out with the page's other choices).
    static func seenKey(_ account: GatewayAccount) -> String { "pages.jobsBadge.seen.\(account.id)" }

    /// At most this many seen marks are kept per account; the oldest go first.
    static let seenLimit = 500

    /// What a job needs attention for, as one string, or nil when it doesn't: its key, its state, the run that failed
    /// and the run that is overdue. A later failure or a new overdue run reads differently, so "When Seen" counts it again.
    static func mark(_ job: CronJob, now: Date) -> String? {
        guard JobWords.section(job, now: now) == .needsAttention else { return nil }
        var parts = [job.key, JobWords.jobState(job)]
        if JobWords.lastRunFailed(job) { parts.append("failed " + (job.lastRunAt ?? "")) }
        if JobWords.nextRunOverdue(job, now: now) != nil { parts.append("overdue " + (job.nextRunAt ?? "")) }
        return parts.joined(separator: "|")
    }

    static func marks(_ jobs: [CronJob], now: Date) -> Set<String> { Set(jobs.compactMap { mark($0, now: now) }) }

    /// The tab's count: every job under Needs Attention, or with "When Seen" those the list hasn't shown yet.
    static func count(_ jobs: [CronJob], now: Date, clear: JobsBadgeClear, seen: Set<String>) -> Int {
        let marks = jobs.compactMap { mark($0, now: now) }
        return clear == .whenSeen ? marks.count(where: { !seen.contains($0) }) : marks.count
    }

    /// The next moment a job turns overdue with no read to say so (its next run plus the grace), or nil: the count is
    /// asked again then.
    static func nextChange(_ jobs: [CronJob], now: Date) -> Date? {
        jobs.compactMap { job -> Date? in
            guard JobWords.section(job, now: now) != .needsAttention,
                  !["paused", "completed", "disabled"].contains(JobWords.jobState(job)),
                  let next = PagesDate.parse(job.nextRunAt) else { return nil }
            // `nextRunOverdue` says overdue only past the grace: a second after it.
            let at = next.addingTimeInterval(JobWords.overdueGrace + 1)
            return at > now ? at : nil
        }.min()
    }
}
