// [live] When a Live Activity starts, changes and ends (docs/spec/3x-presence.md §17, docs/spec/3x-jobs.md §12).
// Pure rules: `LiveActivityPlanner` takes what the app saw (the bots, the app leaving, a Run Now, a Jobs read) and
// answers with commands; App/Live/LiveActivityCenter.swift hands them to ActivityKit. Nothing here knows ActivityKit,
// so the unit tests (Tests/Live) check every rule with a clock of their own.

import Foundation

/// A chat as the rules see it: a bot's Bot Chat (`id` is the bot's profile) or one of its other chats while it runs a
/// turn (`id` is `LiveBot.sideId`), whether a turn runs on it, and the link that opens it.
nonisolated struct LiveBot: Equatable, Sendable {
    var id: String
    var name: String
    var isWorking: Bool
    var link: String?
    /// [live-steps] Its running step in a few words (`Bot.step`, LiveSteps); nil between steps.
    var step: String? = nil
    /// Its stored id: the gateway's add-on matches pushed steps to the turn by it.
    var session: String? = nil
    /// The bot's profile: `id` for a Bot Chat.
    var profile: String? = nil
    /// [live-chats] A side chat's title, drawn after the bot's name on its card; nil for a Bot Chat.
    var chat: String? = nil

    var botProfile: String { profile ?? id }

    /// [live-chats] A side chat's subject id: its bot and its stored id, so two chats of one bot get a card each
    /// (a tester, 2026-11-05: a reply in a chat started from Sessions never showed on the Lock Screen).
    static func sideId(profile: String, session: String) -> String { "\(profile)/\(session)" }
}

/// A followed job after a Jobs read: still out (a Run Now in flight, a run the gateway has out, a bot on its output),
/// finished well, finished with an error, or no longer in the list.
nonisolated enum LiveJobState: Equatable, Sendable { case running, done, failed, gone }

/// How Run Now answered, in the rules' words (`JobsStore.RunResult`).
nonisolated enum LiveRunAnswer: Equatable, Sendable {
    /// The run ended (`.started`) or outlived the wait (`.stillRunning`): the next Jobs read says how it went.
    case answered
    /// The run never began (refused while read-only, already running elsewhere).
    case notStarted
    /// The run failed.
    case failed
}

nonisolated struct LiveActivityStart: Equatable, Sendable {
    var subject: LiveActivitySubject
    var botName: String
    /// A job's title; a side chat's title (nil for a Bot Chat's turn).
    var detail: String?
    var link: String?
    var content: LiveActivityContent
    /// Stored session id (for turns) so grouped cards can match background `turnDone` pushes to the exact row.
    var session: String? = nil
}

nonisolated enum LiveActivityDismissal: Equatable, Sendable {
    case immediate
    case after(Date)
}

nonisolated enum LiveActivityCommand: Equatable, Sendable {
    case start(LiveActivityStart)
    case update(LiveActivitySubject, LiveActivityContent)
    /// `content` nil: it ends as it was (it never really began, or it is taken away).
    case end(LiveActivitySubject, LiveActivityContent?, LiveActivityDismissal)
    /// [live-grouped] Single grouped Live Activity commands.
    case startGroup(LiveGroupedContent)
    case updateGroup(LiveGroupedContent)
    case endGroup(LiveGroupedContent?, LiveActivityDismissal)
}

nonisolated struct LiveActivityPlanner: Sendable {
    /// A turn shows on the Lock Screen once it has run this long when the app is left: any turn still going (owner,
    /// 2026-11-01: a message sent and the phone locked at once showed no card, and iOS lets the app start one only while
    /// it is in front). It was 20 s; a quick one's Done now goes after a minute instead (`LiveActivityTiming.linger`).
    static let defaultTurnThreshold: TimeInterval = 0
    /// At most this many separate cards at once when ungrouped (iOS allows a few per app; more would crowd the Lock Screen).
    static let maxActivities = 4
    /// A finished one stays on the Lock Screen this long when the app is away, then goes. Shared with
    /// NotificationService.swift (LiveKit's `LiveActivityTiming`, which has no HermesKit to borrow this from).
    static let doneLinger = LiveActivityTiming.doneLinger

    /// A running one the app has not touched for this long is marked stale ("· Open to check"): once the app is suspended
    /// it no longer hears the turn or the run end by itself. A finished reply's push can end a turn's sooner (best effort:
    /// docs/spec/3x-presence.md §17.4); nothing pushes a job's, so this is still its only way out while the app is away.
    static let staleAfter = LiveActivityTiming.staleAfter

    /// When `content` goes stale: `staleAfter` from now while it runs, never once it is over.
    static func staleDate(_ content: LiveActivityContent, now: Date) -> Date? {
        content.isOver ? nil : now.addingTimeInterval(staleAfter)
    }

    /// When a grouped card goes stale: `staleAfter` from now while any item is active, never once all are over.
    static func staleDate(_ content: LiveGroupedContent, now: Date) -> Date? {
        content.isOver ? nil : now.addingTimeInterval(staleAfter)
    }

    /// `defaultTurnThreshold`; a UI test shortens it (`-HQDebugLiveThreshold`, Debug builds only).
    var turnThreshold = LiveActivityPlanner.defaultTurnThreshold
    /// Settings › Notifications › Show Progress on Lock Screen (on unless turned off).
    private(set) var enabled = true
    /// [live-grouped] Settings › Notifications › Group Into One Card (on by default in the app; defaults to false here
    /// so individual-mode rule unit tests exercise separate cards unless grouped is passed).
    private(set) var grouped = false
    /// This build can show them: the widget extension is in the app and the person allows Live Activities for it.
    var available = true
    /// Bot id → when the app first saw its turn running.
    private(set) var workingSince: [String: Date] = [:]
    /// [live-steps] Bot id → its running turn's steps so far, followed from the turn's start so a card that starts
    /// later already names the ones before it.
    private(set) var trails: [String: LiveStepTrail] = [:]
    /// What is on show now (active turns and jobs in both individual and grouped modes).
    private(set) var live: [LiveActivitySubject: LiveActivityStart] = [:]
    /// [live-grouped] Whether a grouped Live Activity is currently on show.
    private(set) var groupShowing = false
    /// [live-grouped] Finished rows lingering underneath active rows in the currently-shown grouped card while away.
    private(set) var groupFinished: [LiveActivitySubject: LiveGroupedItem] = [:]
    private var lastGroupContent: LiveGroupedContent?
    /// Most recent ended subject + phase (for the DEBUG `debug.live` probe in both individual and grouped modes).
    private(set) var lastEndedDescription: String?

    init(enabled: Bool = true, available: Bool = true, grouped: Bool = false) {
        self.enabled = enabled
        self.available = available
        self.grouped = grouped
    }

    private var canStart: Bool { enabled && available }
    private var activityCap: Int { grouped ? LiveGroupedContent.maxItems : Self.maxActivities }

    // MARK: Turns

    /// Every roster change. A turn that ends ends its activity with "Done"; a turn that begins starts its clock; a turn
    /// on show whose step changed updates its card ("Running npm test…", the steps before it).
    mutating func bots(_ bots: [LiveBot], now: Date, appActive: Bool) -> [LiveActivityCommand] {
        var out: [LiveActivityCommand] = []
        let working = Set(bots.filter(\.isWorking).map(\.id))
        for id in working where workingSince[id] == nil { workingSince[id] = now }
        for id in workingSince.keys where !working.contains(id) { workingSince[id] = nil }
        for bot in bots where bot.isWorking { trails[bot.id, default: LiveStepTrail()].follow(bot.step) }
        for (subject, shown) in live.sorted(by: { $0.key.id < $1.key.id }) where subject.kind == .turn && !working.contains(subject.id) {
            if let cmd = finish(subject, shown, phase: .done, now: now, appActive: appActive) {
                out.append(cmd)
            }
        }
        for id in trails.keys where !working.contains(id) { trails[id] = nil }
        for (subject, shown) in live.sorted(by: { $0.key.id < $1.key.id }) where subject.kind == .turn {
            guard let trail = trails[subject.id], trail != shown.content.trail else { continue }
            var content = shown.content
            content.trail = trail
            live[subject]?.content = content
            if !grouped { out.append(.update(subject, content)) }
        }
        if grouped { return syncGroup(now: now, appActive: appActive) }
        return out
    }

    /// The app is being left: each turn that has run at least `turnThreshold` (any running one) gets its activity (iOS
    /// starts one only while the app is in front, so this is the last moment), the longest-running first. `talking`: the
    /// stored id of the chat a voice conversation runs in. Its turn gets no card of its own: the conversation's card
    /// already shows it (Thinking…, Speaking), and a second one stayed behind as "Done".
    mutating func leaving(_ bots: [LiveBot], now: Date, talking: String? = nil) -> [LiveActivityCommand] {
        guard canStart else { return [] }
        var out: [LiveActivityCommand] = []
        let candidates = bots.filter { bot in
            if let talking, bot.session == talking { return false }
            guard bot.isWorking, let since = workingSince[bot.id] else { return false }
            return now.timeIntervalSince(since) >= turnThreshold && live[LiveActivitySubject(kind: .turn, id: bot.id)] == nil
        }.sorted { (workingSince[$0.id] ?? now) < (workingSince[$1.id] ?? now) }
        for bot in candidates where live.count < activityCap {
            let subject = LiveActivitySubject(kind: .turn, id: bot.id)
            var content = LiveActivityContent(phase: .working, startedAt: workingSince[bot.id] ?? now)
            content.trail = trails[bot.id] ?? LiveStepTrail()
            let start = LiveActivityStart(subject: subject, botName: bot.name, detail: bot.chat, link: bot.link,
                                          content: content, session: bot.session)
            live[subject] = start
            groupFinished[subject] = nil
            if !grouped { out.append(.start(start)) }
        }
        if grouped { return syncGroup(now: now, appActive: false) }
        return out
    }

    // MARK: Jobs

    /// Run Now was tapped (and confirmed): the job shows as Running at once, so locking the phone straight after works.
    mutating func jobStarted(key: String, title: String, botName: String, link: String?, now: Date) -> [LiveActivityCommand] {
        let subject = LiveActivitySubject(kind: .job, id: key)
        guard canStart, live[subject] == nil, live.count < activityCap else { return [] }
        let start = LiveActivityStart(subject: subject, botName: botName, detail: title, link: link,
                                      content: LiveActivityContent(phase: .running, startedAt: now))
        live[subject] = start
        groupFinished[subject] = nil
        if grouped { return syncGroup(now: now, appActive: false) }
        return [.start(start)]
    }

    /// Run Now's own answer. A run that ended waits for the Jobs read that follows it (a Bot Chat job's bot may still be
    /// working on its output, which only that read can say).
    mutating func jobAnswered(key: String, _ answer: LiveRunAnswer, now: Date, appActive: Bool) -> [LiveActivityCommand] {
        let subject = LiveActivitySubject(kind: .job, id: key)
        guard let shown = live[subject] else { return [] }
        switch answer {
        case .answered: return []
        case .notStarted:
            live[subject] = nil
            recordEnded(subject, phase: nil)
            if grouped { return syncGroup(now: now, appActive: appActive) }
            return [.end(subject, nil, .immediate)]
        case .failed:
            let cmd = finish(subject, shown, phase: .failed, now: now, appActive: appActive)
            if grouped { return syncGroup(now: now, appActive: appActive) }
            return cmd.map { [$0] } ?? []
        }
    }

    /// A Jobs read: each followed job that is no longer out ends, "Done" or "Failed"; one that left the list goes.
    mutating func jobs(_ states: [String: LiveJobState], now: Date, appActive: Bool) -> [LiveActivityCommand] {
        var out: [LiveActivityCommand] = []
        for (subject, shown) in live.sorted(by: { $0.key.id < $1.key.id }) where subject.kind == .job {
            switch states[subject.id] ?? .gone {
            case .running: continue
            case .done:
                if let cmd = finish(subject, shown, phase: .done, now: now, appActive: appActive) { out.append(cmd) }
            case .failed:
                if let cmd = finish(subject, shown, phase: .failed, now: now, appActive: appActive) { out.append(cmd) }
            case .gone:
                live[subject] = nil
                recordEnded(subject, phase: nil)
                if !grouped { out.append(.end(subject, nil, .immediate)) }
            }
        }
        if grouped { return syncGroup(now: now, appActive: appActive) }
        return out
    }

    /// The jobs this planner follows (their keys), so the caller can say how each is.
    var followedJobs: [String] { live.keys.filter { $0.kind == .job }.map(\.id).sorted() }

    // MARK: The switch, grouping, sign-out, failures

    /// Settings' switch. Off takes every activity away at once.
    mutating func setEnabled(_ on: Bool) -> [LiveActivityCommand] {
        enabled = on
        return on ? [] : endAll()
    }

    /// [live-grouped] Settings › Notifications › Group Into One Card. Switching reconciles any currently-shown cards.
    mutating func setGrouped(_ on: Bool, now: Date) -> [LiveActivityCommand] {
        guard on != grouped else { return [] }
        grouped = on
        if on {
            let ends = live.keys.sorted { $0.id < $1.id }.map { LiveActivityCommand.end($0, nil, .immediate) }
            guard !live.isEmpty else { return ends }
            let content = buildGroupedContent(now: now)
            groupShowing = true
            lastGroupContent = content
            return ends + [.startGroup(content)]
        } else {
            var out: [LiveActivityCommand] = []
            if groupShowing {
                out.append(.endGroup(nil, .immediate))
                groupShowing = false
                groupFinished = [:]
                lastGroupContent = nil
            }
            let sorted = live.values.sorted {
                if $0.content.startedAt != $1.content.startedAt { return $0.content.startedAt < $1.content.startedAt }
                return $0.subject.id < $1.subject.id
            }
            let kept = Array(sorted.prefix(Self.maxActivities))
            live = Dictionary(uniqueKeysWithValues: kept.map { ($0.subject, $0) })
            out.append(contentsOf: kept.map { .start($0) })
            return out
        }
    }

    /// User returned to the app: clears any lingering Done/Failed rows inside an active grouped card.
    mutating func clearFinished(now: Date) -> [LiveActivityCommand] {
        guard grouped, !groupFinished.isEmpty else { return [] }
        groupFinished = [:]
        return syncGroup(now: now, appActive: true)
    }

    /// Sign-out, a gateway switch, or the switch turned off: everything goes at once.
    mutating func endAll() -> [LiveActivityCommand] {
        if grouped {
            let hadGroup = groupShowing
            live = [:]
            groupFinished = [:]
            groupShowing = false
            lastGroupContent = nil
            return hadGroup ? [.endGroup(nil, .immediate)] : []
        }
        let out = live.keys.sorted { $0.id < $1.id }.map { LiveActivityCommand.end($0, nil, .immediate) }
        live = [:]
        return out
    }

    /// iOS refused an individual start (Live Activities off for the app, too many): it is not on show.
    mutating func startFailed(_ subject: LiveActivitySubject) { live[subject] = nil }

    /// iOS refused the grouped activity start: drop tracked live items so nothing lingers.
    mutating func groupStartFailed() {
        live = [:]
        groupFinished = [:]
        groupShowing = false
        lastGroupContent = nil
    }

    private mutating func recordEnded(_ subject: LiveActivitySubject, phase: LiveActivityContent.Phase?) {
        lastEndedDescription = "\(subject.kind.rawValue):\(subject.id)=\(phase?.rawValue ?? "removed")"
    }

    private mutating func finish(_ subject: LiveActivitySubject, _ shown: LiveActivityStart, phase: LiveActivityContent.Phase,
                                 now: Date, appActive: Bool) -> LiveActivityCommand? {
        live[subject] = nil
        recordEnded(subject, phase: phase)
        var content = shown.content
        content.phase = phase
        content.endedAt = now
        content.trail = content.trail.settled()     // [live-steps] the step it was on is done too
        if grouped {
            if !appActive {
                groupFinished[subject] = LiveGroupedItem.from(subject: subject, botName: shown.botName, detail: shown.detail,
                                                              link: shown.link, session: shown.session, content: content)
            }
            return nil
        }
        // In the app the person sees the result there: nothing lingers. Away, the Lock Screen keeps it a while: a
        // minute after a quick reply (its alert says the rest), else `doneLinger`.
        let linger = subject.kind == .turn ? LiveActivityTiming.linger(ran: now.timeIntervalSince(content.startedAt)) : Self.doneLinger
        return .end(subject, content, appActive ? .immediate : .after(now.addingTimeInterval(linger)))
    }

    private mutating func pruneFinished(now: Date) {
        for (subject, item) in groupFinished {
            if live[subject] != nil {
                groupFinished[subject] = nil
            } else if let ended = item.endedAt, now.timeIntervalSince(ended) >= Self.doneLinger {
                groupFinished[subject] = nil
            }
        }
    }

    private mutating func buildGroupedContent(now: Date) -> LiveGroupedContent {
        pruneFinished(now: now)
        var all: [LiveGroupedItem] = live.values.map { start in
            LiveGroupedItem.from(subject: start.subject, botName: start.botName, detail: start.detail,
                                 link: start.link, session: start.session, content: start.content)
        }
        all.append(contentsOf: groupFinished.values)
        let sorted = LiveGroupedContent.sorted(all)
        let kept = Array(sorted.prefix(LiveGroupedContent.maxItems))
        let extra = max(0, sorted.count - kept.count)
        return LiveGroupedContent(items: kept, extraCount: extra)
    }

    private mutating func syncGroup(now: Date, appActive: Bool) -> [LiveActivityCommand] {
        if !live.isEmpty {
            let content = buildGroupedContent(now: now)
            if !groupShowing {
                groupShowing = true
                lastGroupContent = content
                return [.startGroup(content)]
            }
            guard content != lastGroupContent else { return [] }
            lastGroupContent = content
            return [.updateGroup(content)]
        }
        guard groupShowing else {
            groupFinished = [:]
            lastGroupContent = nil
            return []
        }
        groupShowing = false
        lastGroupContent = nil
        if appActive || groupFinished.isEmpty {
            groupFinished = [:]
            return [.endGroup(nil, .immediate)]
        }
        let finalContent = buildGroupedContent(now: now)
        let linger = finalContent.dismissalLinger(now: now)
        groupFinished = [:]
        return [.endGroup(finalContent, .after(now.addingTimeInterval(linger)))]
    }
}

/// The words around Settings' switch.
nonisolated enum LiveActivityWords {
    /// The footer under Show Progress on Lock Screen; `island` on an iPhone (the iPad has no Dynamic Island). Says
    /// plainly that this is about a reply's or a job's progress only — Talk's own Lock Screen controls (its Mute and
    /// End buttons, docs/spec/3x-talk-background.md) are a different activity and keep working either way.
    static func footer(island: Bool) -> String {
        footer(island: island, grouped: false)
    }

    static func footer(island: Bool, grouped: Bool) -> String {
        if grouped {
            return "Combines active replies and jobs into a single Lock Screen card"
                + (island ? " and Dynamic Island pill" : "")
                + ". Tap any row to jump straight to that chat or job. Your voice chat’s own Lock Screen controls aren’t affected."
        }
        return "A bot’s reply that’s still going when you leave the app, or a job you run from Jobs, shows on the Lock Screen"
            + (island ? " and in the Dynamic Island" : "")
            + " until it’s done. Your voice chat’s own Lock Screen controls aren’t affected."
    }
}
