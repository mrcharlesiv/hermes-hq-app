// [transcript] A status that only says "wait" shows after a grace period (docs/spec/3x-transcript.md §6.4, row
// L360). Ported from `S/status-grace.ts` (STATUS_GRACE_MS = 1000): most opens and reconnects finish sooner, and a
// word that flashes for a quarter second reads as a hitch. It clears at once; a status already showing that only
// changes its words changes at once.

import Foundation

nonisolated struct StatusGrace: Sendable {
    /// The web's STATUS_GRACE_MS.
    static let standard: Duration = .milliseconds(1000)
    /// How long a waiting word must stand before it shows. Zero: no grace (every word shows at once).
    var grace: Duration = StatusGrace.standard
    /// The waiting-only words.
    static let waitingOnly: Set<String> = ["Waking up…", "Still waking up…", "Connecting…", "Reconnecting…"]

    init(grace: Duration = StatusGrace.standard) { self.grace = grace }

    private(set) var shown: String?
    /// When the waiting word that is not shown yet first stood.
    private var waitingSince: ContinuousClock.Instant?

    /// What to show for `raw` now, and when to ask again (a waiting word that has not stood long enough).
    mutating func next(raw: String?, now: ContinuousClock.Instant) -> (shown: String?, recheckAfter: Duration?) {
        guard let raw, !raw.isEmpty else {
            shown = nil; waitingSince = nil
            return (nil, nil)
        }
        guard Self.waitingOnly.contains(raw) else {
            shown = raw; waitingSince = nil
            return (raw, nil)
        }
        if shown != nil {
            // Something shows already: only its words change.
            shown = raw; waitingSince = nil
            return (raw, nil)
        }
        let since = waitingSince ?? now
        waitingSince = since
        let waited = since.duration(to: now)
        if waited >= grace {
            shown = raw; waitingSince = nil
            return (raw, nil)
        }
        return (nil, grace - waited)
    }
}
