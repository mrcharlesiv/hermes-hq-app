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
#endif
