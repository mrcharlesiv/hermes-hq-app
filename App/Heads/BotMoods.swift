// [moods] What each bot is up to now, for its face to act out (BotMood): worked out from the gateway's turn events,
// which AppModel hands in with the bot each belongs to, and from "waits for your answer". Faces that follow a bot (its
// row, its tile, its chat's header) register here and are told when its mood changes, so nothing is rebuilt: the
// face swaps its act.
//
// A step's mood is held at least `BotMood.dwell` (most steps end in under a second); the end of a turn plays "done"
// or "failed" once. Events a reconnect replays are old news: only an ending counts, and quietly.

import UIKit

@MainActor final class BotMoods {
    static let shared = BotMoods()

    /// How long a working mood lasts with no word from its turn (a missed ending; a long command sends nothing while it
    /// runs, so this is generous). The turn's own end (`settle`) clears it sooner.
    static let stale: TimeInterval = 20 * 60

    private struct State {
        var mood: BotMood
        /// When this mood began (a step's dwell counts from here).
        var since: CFTimeInterval
        /// The newest event behind it.
        var heard: CFTimeInterval
        /// A mood waiting for the dwell to end.
        var next: BotMood?
    }
    private var states: [String: State] = [:]
    private var asking: Set<String> = []
    private var timers: [String: Timer] = [:]
    private var views: [String: NSHashTable<HeadView>] = [:]
    /// Tests: the clock and whether timers are made (a test moves `clock` and calls `tick`).
    var clock: () -> CFTimeInterval = CACurrentMediaTime
    var usesTimers = true

    /// What `profile`'s face acts out now: waiting for you first, then its turn's step, else nothing.
    func mood(for profile: String) -> BotMood? {
        if asking.contains(profile) { return .asking }
        return states[profile]?.mood
    }

    /// When `profile`'s mood began: an act plays from there, so a face shown later (a row scrolled in, the chat opened)
    /// joins in step. nil while it asks.
    func since(_ profile: String) -> CFTimeInterval? { asking.contains(profile) ? nil : states[profile]?.since }

    // MARK: In

    /// A gateway event of `profile`'s (nil: nobody's we know).
    func handle(_ event: GatewayEvent, profile: String?) {
        guard let profile, !profile.isEmpty else { return }
        if event.replayed {
            if event.type == "message.complete" || event.type == "error" { clear(profile) }
            return
        }
        switch event.type {
        case "message.start", "thinking.delta", "reasoning.delta", "reasoning.available", "tool.complete":
            set(profile, .thinking)
        case "tool.start", "tool.generating":
            if let mood = BotMood(tool: event.payload["name"]?.string) { set(profile, mood) }
        case "message.delta":
            set(profile, .replying)
        case "message.complete":
            let status = event.payload["status"]?.string ?? ""
            if status == "interrupted" { clear(profile) } else { once(profile, status.contains("error") ? .failed : .done) }
        case "error":
            once(profile, .failed)
        case "session.interrupt":
            clear(profile)
        default:
            break
        }
    }

    /// `profile`'s chat waits for an answer or an approval (or no longer does).
    func setAsking(_ profile: String, _ on: Bool) {
        let before = mood(for: profile)
        if on { asking.insert(profile) } else { asking.remove(profile) }
        if mood(for: profile) != before { tell(profile) }
    }

    /// A turn of `profile`'s started: thinking, unless its events already said more.
    func started(_ profile: String) {
        guard states[profile] == nil else { return }
        set(profile, .thinking)
    }

    /// None of `profile`'s turns runs any more: a working mood goes (a "done" or "failed" plays out).
    func settle(_ profile: String) {
        guard let state = states[profile], !state.mood.once else { return }
        clear(profile)
    }

    /// Sign-out or another gateway: every mood goes.
    func reset() {
        let profiles = Set(states.keys).union(asking)
        states = [:]
        asking = []
        for timer in timers.values { timer.invalidate() }
        timers = [:]
        for profile in profiles { tell(profile) }
    }

    #if DEBUG
    /// DEBUG (`-HQDemoFaces`): `profile` is in `mood` now, as if its events said so.
    func show(_ mood: BotMood, for profile: String) {
        let now = clock()
        states[profile] = State(mood: mood, since: now, heard: now)
        changed(profile)
    }
    #endif

    // MARK: Faces

    func register(_ view: HeadView, profile: String) {
        let table = views[profile] ?? {
            let made = NSHashTable<HeadView>.weakObjects()
            views[profile] = made
            return made
        }()
        table.add(view)
    }

    func unregister(_ view: HeadView, profile: String) {
        views[profile]?.remove(view)
    }

    private func tell(_ profile: String) {
        for view in views[profile]?.allObjects ?? [] { view.moodChanged() }
    }

    // MARK: Rules

    private func set(_ profile: String, _ mood: BotMood) {
        let now = clock()
        guard var state = states[profile] else {
            states[profile] = State(mood: mood, since: now, heard: now)
            changed(profile)
            return
        }
        state.heard = now
        if state.mood == mood {
            state.next = nil
            states[profile] = state
            plan(profile)
            return
        }
        // A step shows its whole dwell before the next; a "done" still playing from an earlier turn gives way at once.
        if !state.mood.once, state.mood != .thinking || mood == .thinking, now - state.since < BotMood.dwell {
            state.next = mood
            states[profile] = state
            plan(profile)
            return
        }
        states[profile] = State(mood: mood, since: now, heard: now)
        changed(profile)
    }

    private func once(_ profile: String, _ mood: BotMood) {
        let now = clock()
        states[profile] = State(mood: mood, since: now, heard: now)
        changed(profile)
    }

    private func clear(_ profile: String) {
        guard states.removeValue(forKey: profile) != nil else { return }
        timers.removeValue(forKey: profile)?.invalidate()
        tell(profile)
    }

    private func changed(_ profile: String) {
        plan(profile)
        tell(profile)
    }

    /// When `profile` next changes by itself: a held mood after its dwell, a once-only mood's end, a stale mood's end.
    private func due(_ state: State) -> CFTimeInterval {
        if state.mood.once { return state.since + state.mood.length }
        if state.next != nil { return state.since + BotMood.dwell }
        return state.heard + Self.stale
    }

    private func plan(_ profile: String) {
        timers.removeValue(forKey: profile)?.invalidate()
        guard usesTimers, let state = states[profile] else { return }
        let wait = max(0.01, due(state) - clock())
        let timer = Timer(timeInterval: wait, repeats: false) { _ in
            MainActor.assumeIsolated { BotMoods.shared.tick(profile) }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        timers[profile] = timer
    }

    /// Time has passed for `profile`: a held mood takes over, a once-only or stale mood ends.
    func tick(_ profile: String) {
        timers[profile] = nil
        guard let state = states[profile] else { return }
        let now = clock()
        guard now >= due(state) - 0.02 else { plan(profile); return }
        if let next = state.next {
            states[profile] = State(mood: next, since: now, heard: state.heard)
            changed(profile)
        } else {
            clear(profile)
        }
    }
}
