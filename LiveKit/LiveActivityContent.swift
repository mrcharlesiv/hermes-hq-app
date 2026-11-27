// [live] Lock Screen and Dynamic Island progress (a Live Activity) for a long bot turn or a job run from Jobs
// (docs/spec/3x-presence.md §17, docs/spec/3x-jobs.md §12; docs/owner-todo/live-activity.md).
//
// LiveKit is compiled into the app, the shared widget extension (HermesHQTalkActivity, which already draws Talk's own
// Live Activity — this reuses it through a second `Widget` in its `WidgetBundle` rather than a target of its own) AND
// the notification extension (best-effort: see NotificationService.swift). It is self-contained on purpose: Foundation
// and ActivityKit only, no UIKit, no HermesKit. Every declaration is `nonisolated`, so it means the same everywhere.

import Foundation
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// What a Live Activity says: the phase and when it began (the elapsed time counts itself from `startedAt`, so it moves
/// on while the app is suspended), and when it ended. A turn's also names its steps (owner, 2026-10-31: "Right now it
/// just shows working… it needs to show the live tool calls"): the app's own updates carry them in `step`, `recent` and
/// `steps`; a push from the gateway's add-on (hermes-hq-push 0.9.22+, once iOS has suspended the app) carries the same
/// three sealed with this phone's push key in `seal`, so the relay and Apple see no words (Shared/LiveStepsSeal.swift
/// opens it in the widget). All four are optional, so an activity saved by an older build still decodes.
nonisolated struct LiveActivityContent: Codable, Hashable, Sendable {
    nonisolated enum Phase: String, Codable, Hashable, Sendable {
        case working   // a bot turn
        case running   // a job
        case done
        case failed
    }

    var phase: Phase
    var startedAt: Date
    var endedAt: Date?
    /// [live-steps] The running step in a few words ("running npm test"); nil before the first, or while the reply writes.
    var step: String? = nil
    /// Earlier steps, newest first (at most `LiveStepTrail.recentLimit`).
    var recent: [String]? = nil
    /// How many steps so far.
    var steps: Int? = nil
    /// A pushed update's trail, sealed (see above). Encoded as the add-on sends it: `{"v": 1, "kid": …, "box": …}`.
    var seal: LiveSeal? = nil

    var isOver: Bool { phase == .done || phase == .failed }

    /// The app's own trail. Setting an empty one clears all three fields, so a turn with no steps encodes as before.
    var trail: LiveStepTrail {
        get { LiveStepTrail(step: step, recent: recent ?? [], steps: steps ?? 0) }
        set {
            step = newValue.step
            recent = newValue.recent.isEmpty ? nil : newValue.recent
            steps = newValue.steps == 0 ? nil : newValue.steps
        }
    }

    /// "Working…", "Running", "Done", "Failed": the words the Lock Screen shows.
    var words: String {
        switch phase {
        case .working: return "Working…"
        case .running: return "Running"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    /// "3 min" / "45 s" / "1 h 5 min": how long a finished one took (a running one shows a live timer instead).
    static func took(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        if whole < 60 { return "\(whole) s" }
        let minutes = whole / 60
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// [island-fit] The same in the Dynamic Island's small view, where every point counts: "45s", "16m", "1h 5m".
    static func tookShort(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        if whole < 60 { return "\(whole)s" }
        let minutes = whole / 60
        if minutes < 60 { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
    }

    /// [island-fit] Ultra-compact fallback when another Live Activity squeezes the Dynamic Island's trailing slot:
    /// drops trailing minutes past an hour ("12h", "1h") so finished durations stay full-height instead of shrinking
    /// or truncating.
    static func tookTiny(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        if whole < 60 { return "\(whole)s" }
        let minutes = whole / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}

/// [live-steps] A turn's steps as its Lock Screen card names them: the running one, the two before it, how many.
nonisolated struct LiveStepTrail: Codable, Hashable, Sendable {
    static let recentLimit = 2
    /// The longest a step's words are drawn (the app's phrases cut subjects at 36; a pushed one is cut here too).
    static let wordsLimit = 60

    var step: String?
    var recent: [String] = []
    var steps = 0

    var isEmpty: Bool { step == nil && recent.isEmpty && steps == 0 }

    /// The bot's step is now `words` (nil: between steps, its reply writing). The one it was on moves to `recent`; a
    /// new one counts.
    mutating func follow(_ words: String?) {
        guard words != step else { return }
        if let step {
            recent.insert(step, at: 0)
            if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        }
        step = words
        if words != nil { steps += 1 }
    }

    /// The turn is over: the step it was on is a finished one too.
    func settled() -> LiveStepTrail {
        var out = self
        if let step = out.step {
            out.recent = Array(([step] + out.recent).prefix(Self.recentLimit))
            out.step = nil
        }
        return out
    }

    /// A pushed trail's words made safe to draw: one line, at most `wordsLimit`, blanks dropped.
    func cleaned() -> LiveStepTrail {
        LiveStepTrail(step: step.flatMap(Self.clean), recent: recent.compactMap(Self.clean).prefix(Self.recentLimit).map { $0 },
                      steps: max(0, steps))
    }

    static func clean(_ words: String) -> String? {
        let line = words.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return line.count > wordsLimit ? String(line.prefix(wordsLimit - 1)) + "…" : line
    }

    /// "Running npm test…": the running step as the card's line (the Bots row's own words, LiveSteps.line).
    static func running(_ words: String) -> String { capitalized(words) + "…" }

    /// "Reading package.json": a finished step.
    static func finished(_ words: String) -> String { capitalized(words) }

    private static func capitalized(_ words: String) -> String { words.prefix(1).uppercased() + words.dropFirst() }

    /// "1 step", "7 steps".
    static func count(_ steps: Int) -> String { steps == 1 ? "1 step" : "\(steps) steps" }
}

/// A pushed trail, sealed with this phone's push key (Shared/PushSeal.swift's box: AES-256-GCM, the same `kid`).
nonisolated struct LiveSeal: Codable, Hashable, Sendable {
    var v: Int
    var kid: String
    var box: String
}

/// What a Live Activity is about: a bot's turn (`id` = its profile) or a job (`id` = its key, "owner|id").
nonisolated struct LiveActivitySubject: Codable, Hashable, Sendable {
    nonisolated enum Kind: String, Codable, Hashable, Sendable { case turn, job }
    var kind: Kind
    var id: String
}

/// [island-fit] How far a running timer's text counts. A timer is as wide as the longest value in its range, so one
/// running to `distantFuture` wants endless room and needed a fixed box — which the Dynamic Island cut off whenever it
/// offered less (owner, 2026-11-11: "16:0…" beside another app's activity). The range ends where the next digit would
/// appear ("59:59", "9:59:59", "99:59:59"), picked so the timer can't reach it before it is drawn again: every update
/// redraws it, and one not heard from goes stale (and stops counting) well inside `reach`.
nonisolated enum LiveTimerSpan {
    /// Just past `LiveActivityTiming.staleAfter` (30 min): any unupdated reply card goes stale and stops counting
    /// before reaching the end of its range, while staying at `"00:00"` width until 29 min instead of jumping to
    /// `"0:00:00"` at 20 min.
    static let reach: TimeInterval = 31 * 60
    /// Talk renews every 4 min and goes stale at 10 min, so it keeps `"00:00"` width until 49 min.
    static let talkReach: TimeInterval = 11 * 60
    static let limits: [TimeInterval] = [3_599, 35_999, 359_999]   // 59:59, 9:59:59, 99:59:59

    /// The widest thing a timer with that range can say, in digits of one width: what sizes its place in the island.
    /// A live timer takes all the room it is offered, however short its range, and the Dynamic Island offers a lot:
    /// left to itself it stretched the island across the clock and the status icons (owner, 2026-11-11, build 948:
    /// "Should this really be that large?").
    static func widest(startedAt: Date, now: Date, reach: TimeInterval = LiveTimerSpan.reach) -> String {
        switch end(startedAt: startedAt, now: now, reach: reach).timeIntervalSince(startedAt) {
        case ..<3_600: return "00:00"
        case ..<36_000: return "0:00:00"
        case ..<360_000: return "00:00:00"
        default: return "000:00:00"
        }
    }

    /// A stopped clock as a timer writes it: "0:42", "16:10", "1:02:05".
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        let rest = String(format: "%02d", whole % 60)
        if whole < 3_600 { return "\(whole / 60):\(rest)" }
        return "\(whole / 3_600):" + String(format: "%02d", whole % 3_600 / 60) + ":\(rest)"
    }

    /// Where a timer that began at `startedAt`, drawn at `now`, stops counting.
    static func end(startedAt: Date, now: Date, reach: TimeInterval = LiveTimerSpan.reach) -> Date {
        let farthest = max(0, now.timeIntervalSince(startedAt)) + reach
        return startedAt.addingTimeInterval(limits.first { farthest < $0 } ?? 3_599_999)
    }
}

/// How long a Live Activity lingers once it is over (shared with NotificationService.swift, which has no access to
/// HermesKit's `LiveActivityPlanner` — that one forwards its own `doneLinger`/`staleAfter` to these).
nonisolated enum LiveActivityTiming {
    /// A finished one stays on the Lock Screen this long when the app is away, then goes.
    static let doneLinger: TimeInterval = 15 * 60
    /// A reply that ran under `quickTurn` stays only `quickLinger` once Done: any reply still going when the phone is
    /// left gets a card now, and a quick one's alert says the rest (the add-on's pushed end does the same, 0.9.24).
    static let quickTurn: TimeInterval = 60
    static let quickLinger: TimeInterval = 60

    /// How long a reply's card that ran `ran` stays once Done.
    static func linger(ran: TimeInterval) -> TimeInterval { ran >= 0 && ran < quickTurn ? quickLinger : doneLinger }
    /// A running one the app has not touched for this long is marked stale ("· Open to check").
    static let staleAfter: TimeInterval = 30 * 60
}

/// Whether this build carries the widget extension that draws a reply's or a job's Live Activity: the same
/// `HermesHQTalkActivity` that already draws Talk's (docs/spec/3x-talk-background.md), embedded only in the original
/// identity's build (project-original.yml). Reusing it is the point: its bundle ID is already registered and already
/// ships, so this needs no App ID of its own and nothing new to turn on (docs/owner-todo/live-activity.md). Never the Mac.
nonisolated enum LiveActivityBuild {
    static let extensionName = "HermesHQTalkActivity.appex"
    static let extensionEmbedded: Bool = {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        guard let plugIns = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugIns.appending(path: extensionName).path)
        #endif
    }()
}

/// [live-grouped] One row inside the grouped Live Activity card: a bot chat turn, a side chat turn, or a job run.
nonisolated struct LiveGroupedItem: Codable, Hashable, Sendable, Identifiable {
    var id: String { "\(subject.kind.rawValue):\(subject.id)" }
    var subject: LiveActivitySubject
    /// Primary bold title on the left: side chat title, job title, or bot name (for a main bot chat).
    var title: String
    /// Muted secondary context beside the title: bot name (for side chats and jobs) or live step / step count (main bot chats).
    var subtitle: String?
    var phase: LiveActivityContent.Phase
    var startedAt: Date
    var endedAt: Date?
    /// Per-row deep link (`<scheme>://session/<id>` or `<scheme>://job/<key>`) opened when this row is tapped.
    var link: String?
    /// Stored session id (for turns) so NotificationService can match a `turnDone` push to the exact row.
    var session: String? = nil
    /// Bot display name (preserved for adaptive 1-item layout on side chats and jobs).
    var botName: String? = nil
    /// Side-chat or job title (nil for main bot chats; preserved for adaptive 1-item layout).
    var detail: String? = nil
    /// Live step trail for turns (preserved for adaptive 1-item layout).
    var trail: LiveStepTrail? = nil

    var isOver: Bool { phase == .done || phase == .failed }

    /// True when `subtitle` carries a live step/step-count for a main bot chat (so `title` keeps priority and `subtitle`
    /// fills the remaining width), false when `subtitle` is a short bot tag beside a side-chat or job title.
    var subtitleIsStep: Bool {
        subject.kind == .turn && (detail == nil || detail?.isEmpty == true)
    }

    /// Short status word on the trailing column ("Working", "Running", "Done", "Failed").
    var statusWord: String {
        switch phase {
        case .working: return "Working"
        case .running: return "Running"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    /// Reconstructs `LiveActivityContent` for rendering the rich single-item view when this is the sole item in the card.
    var singleContent: LiveActivityContent {
        var content = LiveActivityContent(phase: phase, startedAt: startedAt, endedAt: endedAt)
        if let trail { content.trail = trail }
        return content
    }

    /// Build a row from a subject's start info and current content.
    static func from(subject: LiveActivitySubject, botName: String, detail: String?, link: String?, session: String?,
                     content: LiveActivityContent) -> LiveGroupedItem {
        let title: String
        let subtitle: String?
        switch subject.kind {
        case .job:
            if let detail, !detail.isEmpty {
                title = detail
                subtitle = botName == detail ? nil : botName
            } else {
                title = botName
                subtitle = nil
            }
        case .turn:
            if let detail, !detail.isEmpty {
                title = detail
                subtitle = botName
            } else {
                title = botName
                let trail = content.trail
                if content.isOver {
                    subtitle = trail.steps > 0 ? LiveStepTrail.count(trail.steps) : nil
                } else if let step = trail.step {
                    subtitle = LiveStepTrail.running(step)
                } else if trail.steps > 0 {
                    subtitle = "Writing…"
                } else {
                    subtitle = nil
                }
            }
        }
        let storedTrail: LiveStepTrail? = (subject.kind == .turn && !content.trail.isEmpty) ? content.trail : nil
        return LiveGroupedItem(subject: subject, title: title, subtitle: subtitle, phase: content.phase,
                               startedAt: content.startedAt, endedAt: content.endedAt, link: link, session: session,
                               botName: botName, detail: detail, trail: storedTrail)
    }
}

/// [live-grouped] State of the single grouped Live Activity card carrying multiple active turns and jobs.
nonisolated struct LiveGroupedContent: Codable, Hashable, Sendable {
    /// Maximum rows carried in ActivityKit content state (stays well under the 4 KB payload cap).
    static let maxItems = 12
    /// Maximum rows drawn on the Lock Screen (fits cleanly inside iOS's 160 pt height ceiling).
    static let lockScreenLimit = 5
    /// Maximum rows drawn in the expanded Dynamic Island.
    static let expandedLimit = 4

    var items: [LiveGroupedItem]
    /// Any additional active items beyond `maxItems`.
    var extraCount: Int = 0

    var activeCount: Int { items.filter { !$0.isOver }.count + extraCount }
    var totalCount: Int { items.count + extraCount }
    var isOver: Bool { activeCount == 0 }
    var hasFailed: Bool { items.contains { $0.phase == .failed } }

    /// The sole item when only 1 item is tracked: renders with the rich single-item layout and live timer instead of
    /// a sparse 1-row table.
    var soleItem: LiveGroupedItem? {
        items.count == 1 && extraCount == 0 ? items[0] : nil
    }

    /// Header summary ("3 active", "All done", "Done", "Failed").
    var summary: String {
        if activeCount > 0 { return "\(activeCount) active" }
        let failed = items.filter { $0.phase == .failed }.count
        if failed > 0 { return failed == 1 && items.count == 1 ? "Failed" : "\(failed) failed" }
        return items.count == 1 ? "Done" : "All done"
    }

    /// Compact Dynamic Island trailing label ("3 active", "Done", "Failed").
    var compactLabel: String {
        if activeCount > 0 { return "\(activeCount) active" }
        return hasFailed ? "Failed" : "Done"
    }

    /// Active rows first (longest-running at the top), then recently finished rows (most recently ended first).
    static func sorted(_ items: [LiveGroupedItem]) -> [LiveGroupedItem] {
        items.sorted { a, b in
            if a.isOver != b.isOver { return !a.isOver }
            if !a.isOver {
                if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
                return a.id < b.id
            } else {
                let aEnd = a.endedAt ?? a.startedAt
                let bEnd = b.endedAt ?? b.startedAt
                if aEnd != bEnd { return aEnd > bEnd }
                return a.id < b.id
            }
        }
    }

    /// Visible rows and overflow count for a display surface.
    /// When `reserveOverflowRow` is true and total exceeds `limit`, keeps the last slot for `"+N more"` so total lines
    /// never exceed `limit`.
    func visible(limit: Int, reserveOverflowRow: Bool = false) -> (rows: [LiveGroupedItem], overflow: Int) {
        let total = totalCount
        guard total > limit else { return (items, 0) }
        let shownCount = reserveOverflowRow ? max(1, limit - 1) : limit
        let rows = Array(items.prefix(shownCount))
        return (rows, total - rows.count)
    }

    /// How long the grouped card lingers once all items are over: 60 s if every item was a quick turn, else 15 min.
    func dismissalLinger(now: Date) -> TimeInterval {
        guard !items.isEmpty else { return LiveActivityTiming.doneLinger }
        let allQuickTurns = items.allSatisfy { item in
            item.subject.kind == .turn &&
            LiveActivityTiming.linger(ran: (item.endedAt ?? now).timeIntervalSince(item.startedAt)) == LiveActivityTiming.quickLinger
        }
        return allQuickTurns ? LiveActivityTiming.quickLinger : LiveActivityTiming.doneLinger
    }

    /// Mark a matching active turn row as Done (used by `NotificationService` on a `turnDone` push while suspended).
    /// Returns nil when no active row matches.
    func markingTurnDone(profile: String, session: String?, now: Date) -> LiveGroupedContent? {
        let index: Int? = if let session, !session.isEmpty {
            items.firstIndex { !$0.isOver && $0.subject.kind == .turn && ($0.session == session || $0.subject.id == "\(profile)/\(session)") }
                ?? items.firstIndex { !$0.isOver && $0.subject.kind == .turn && $0.subject.id == profile }
        } else {
            items.firstIndex { !$0.isOver && $0.subject.kind == .turn && $0.subject.id == profile }
        }
        guard let index else { return nil }
        var updated = items
        updated[index].phase = .done
        updated[index].endedAt = now
        if let settled = updated[index].trail?.settled() {
            updated[index].trail = settled
            if updated[index].subtitleIsStep {
                updated[index].subtitle = settled.steps > 0 ? LiveStepTrail.count(settled.steps) : nil
            }
        } else if updated[index].subtitleIsStep {
            updated[index].subtitle = nil
        }
        return LiveGroupedContent(items: Self.sorted(updated), extraCount: extraCount)
    }
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
/// The Live Activity's fixed part. `link` is the app's own link (`<scheme>://session/<id>`, `<scheme>://job/<key>`),
/// built by the app so the widget never needs to know which identity it is in.
nonisolated struct HQLiveAttributes: ActivityAttributes {
    typealias ContentState = LiveActivityContent
    var subject: LiveActivitySubject
    /// The bot's name ("Hermes", "Otto").
    var botName: String
    /// A job's title; a side chat's title for a turn (nil for a Bot Chat's).
    var detail: String?
    var link: String?
    /// The app's accent (its theme's tint as a dark card draws it), red green blue 0…1: the extension has no theme of
    /// its own, so `.accentColor` drew system blue whatever theme the app wore.
    var accent: [Double]? = nil
}

/// [live-grouped] Fixed attributes for the single grouped Live Activity combining active turns and jobs.
nonisolated struct HQGroupedLiveAttributes: ActivityAttributes {
    typealias ContentState = LiveGroupedContent
    /// Display name shown in the card header ("Hermes HQ").
    var appName: String
    /// Default link when tapping the card header/background (`<scheme>://`).
    var link: String?
    /// The app's accent (RGB 0...1) for dark Lock Screen / Dynamic Island surfaces.
    var accent: [Double]? = nil
}
#endif
