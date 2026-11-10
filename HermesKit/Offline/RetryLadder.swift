// [offline] The wait before each automatic retry while the app has never been connected (docs/spec/3x-offline.md
// §3.6): 3, 6, 12, 24, then 30 s for good (`OFFLINE_RETRY_S`, the web app's `src/main.ts:289`). The connection's
// pre-ready back-off IS this ladder, so the countdown the offline screen shows is the real timer. Pure.

import Foundation

nonisolated enum RetryLadder {
    static let steps: [TimeInterval] = [3, 6, 12, 24, 30]
    /// A gateway's `Retry-After` stretches a wait, never past this.
    static let ceiling: TimeInterval = 120

    /// The wait before retry number `attempt` (0 = the first retry after the first failure). A 429's `Retry-After`
    /// stretches it, capped at `ceiling`, so the countdown never promises a dial the gateway asked us not to make.
    /// **DECISION** (spec §3.6): a `Retry-After` that is not a positive number of seconds is ignored.
    static func wait(attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        let step = steps[min(max(attempt, 0), steps.count - 1)]
        guard let retryAfter, retryAfter.isFinite, retryAfter > 0 else { return step }
        return min(ceiling, max(step, retryAfter))
    }

    /// Seconds left until `due`, for the status line: recomputed from the clock on every tick (never a decrementing
    /// counter, so a paused run loop cannot make it lie), and never below 0.
    static func remaining(until due: Date, now: Date = Date()) -> TimeInterval {
        max(0, due.timeIntervalSince(now))
    }
}
