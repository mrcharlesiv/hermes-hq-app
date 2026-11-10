// [offline] The Capabilities page's data read ahead of its first open (docs/spec/3x-offline.md §6.10, the web app's
// `src/page-data-warm.ts`): 600 ms after the Bots list first has rows (8 s after the account became active at the
// latest), never while a navigation transition runs, and only while connected with the app active. Answers are kept
// 30 minutes per account and bot; the page shows them in its first frame and refreshes behind them as before.
// [load-cache] Every answer (the warm-up's and the page's own) is also saved in Application Support/pages/<account
// key>/capabilities-<bot>.json (PagesCache: removed on sign-out and gateway removal), so after a relaunch the page's
// first frame has rows up to a week old while it reads fresh ones, and a warm-up within 30 minutes of the last answer
// doesn't read at all (skills ~3 s and the hub catalog ~2 s on a busy gateway, on every launch before).

import Foundation

/// What the warm-up read, kept for the Capabilities page's first frame.
@MainActor final class CapabilitiesWarmCache {
    static let shared = CapabilitiesWarmCache(root: PagesCache.root)
    nonisolated static let keep: TimeInterval = 30 * 60
    /// [load-cache] How old a kept answer may be and still fill the page's first frame (it reads fresh behind it).
    nonisolated static let seedFor: TimeInterval = 7 * 24 * 3600
    /// [load-cache] A bot's answer over this is not saved (and an older saved one goes).
    nonisolated static let fileLimit = 1_000_000

    struct Entry {
        var skills: [SkillInfo]
        var official: [OfficialSkill]?
        var at: Date
    }

    /// [load-cache] The file's contents.
    nonisolated struct Saved: Codable, Sendable {
        var skills: [SkillInfo]
        var official: [OfficialSkill]?
    }

    private var entries: [String: Entry] = [:]
    /// [load-cache] Keys whose file was looked for (found or not), so a miss reads the disk once.
    private var looked: Set<String> = []
    /// [load-cache] Bumped by `forget`: a file read that was out when the account was forgotten is dropped.
    private var generation = 0
    /// nil: memory only (tests).
    private let root: URL?
    private let now: () -> Date

    init(root: URL? = nil, now: @escaping () -> Date = { Date() }) {
        self.root = root
        self.now = now
    }

    private func key(_ account: String, _ profile: String) -> String { account + "\u{1F}" + profile }

    private func url(_ account: String, _ profile: String) -> URL? {
        root?.appending(path: RosterDisk.accountKey(id: account), directoryHint: .isDirectory)
            .appending(path: "capabilities-\(PagesCache.safeName(profile)).json")
    }

    func store(skills: [SkillInfo], official: [OfficialSkill]?, account: String, profile: String) {
        let at = now()
        entries[key(account, profile)] = Entry(skills: skills, official: official, at: at)
        looked.insert(key(account, profile))
        if let url = url(account, profile) {
            PagesCache.write(PagesCached(at: (at.timeIntervalSince1970 * 1000).rounded(), value: Saved(skills: skills, official: official)),
                             to: url, maxBytes: Self.fileLimit)
        }
    }

    /// The kept answer (memory, else this bot's file), whatever its age.
    private func kept(_ account: String, _ profile: String) -> Entry? {
        let key = key(account, profile)
        if let entry = entries[key] { return entry }
        guard !looked.contains(key) else { return nil }
        looked.insert(key)
        guard let url = url(account, profile), let saved = PagesCache.read(PagesCached<Saved>.self, url) else { return nil }
        let entry = Self.entry(saved)
        entries[key] = entry
        return entry
    }

    private static func entry(_ saved: PagesCached<Saved>) -> Entry {
        Entry(skills: saved.value.skills, official: saved.value.official, at: Date(timeIntervalSince1970: saved.at / 1000))
    }

    /// [load-cache] Reads this bot's file off the main thread (the launch warm-up: the file can be most of a megabyte),
    /// so the `entry` or `seed` after it finds the answer in memory.
    func preload(account: String, profile: String) async {
        let key = key(account, profile)
        guard entries[key] == nil, !looked.contains(key), let url = url(account, profile) else { return }
        let started = generation
        let saved = await Self.readFile(url)
        // A store, a synchronous read or a forget while it was out: theirs stands.
        guard generation == started, entries[key] == nil, !looked.contains(key) else { return }
        looked.insert(key)
        if let saved { entries[key] = Self.entry(saved) }
    }

    @concurrent private static func readFile(_ url: URL) async -> PagesCached<Saved>? {
        PagesCache.read(PagesCached<Saved>.self, url)
    }

    private func age(_ entry: Entry) -> TimeInterval { now().timeIntervalSince(entry.at) }

    /// The kept answer, nil when there is none or it is older than 30 minutes (or from ahead of the clock).
    func entry(account: String, profile: String) -> Entry? {
        guard let entry = kept(account, profile), age(entry) >= 0, age(entry) <= Self.keep else { return nil }
        return entry
    }

    /// [load-cache] The kept answer for the page's first frame: up to `seedFor` old.
    func seed(account: String, profile: String) -> Entry? {
        guard let entry = kept(account, profile), age(entry) >= 0, age(entry) <= Self.seedFor else { return nil }
        return entry
    }

    /// Memory only: the files go with PagesCache.purge.
    func forget(account: String) {
        entries = entries.filter { !$0.key.hasPrefix(account + "\u{1F}") }
        looked = looked.filter { !$0.hasPrefix(account + "\u{1F}") }
        generation += 1
    }

    func forgetAll() { entries = [:]; looked = []; generation += 1 }
}

/// When the warm-up runs. One run per activation.
@MainActor final class PageDataWarm {
    nonisolated static let afterRoster: TimeInterval = 0.6
    nonisolated static let fallback: TimeInterval = 8
    nonisolated static let transitionRetry: TimeInterval = 0.25

    private let clock: any FlightClock
    /// Connected, and the app is active.
    private let ready: @MainActor () -> Bool
    /// A navigation transition is running.
    private let moving: @MainActor () -> Bool
    private let warm: @MainActor () async -> Void

    private var fallbackTimer: (any FlightTimer)?
    private var rosterTimer: (any FlightTimer)?
    private var retryTimer: (any FlightTimer)?
    private var sawRoster = false
    /// The moment came while not connected or in the background: it runs when that changes.
    private var due = false
    private(set) var started = false
    private var stopped = false

    init(clock: (any FlightClock)? = nil, ready: @escaping @MainActor () -> Bool, moving: @escaping @MainActor () -> Bool,
         warm: @escaping @MainActor () async -> Void) {
        self.clock = clock ?? LiveFlightClock.shared
        self.ready = ready
        self.moving = moving
        self.warm = warm
    }

    /// The account became active: the 8 s fallback starts.
    func activated() {
        guard fallbackTimer == nil, !started, !stopped else { return }
        fallbackTimer = clock.schedule(after: Self.fallback) { [weak self] in
            self?.fallbackTimer = nil
            self?.fire()
        }
    }

    /// The Bots list has rows (the first time counts): 600 ms later.
    func rosterHasRows() {
        guard !sawRoster, !started, !stopped else { return }
        sawRoster = true
        rosterTimer = clock.schedule(after: Self.afterRoster) { [weak self] in
            self?.rosterTimer = nil
            self?.fire()
        }
    }

    /// The connection opened or the app became active: a warm-up that was held runs now.
    func conditionsChanged() { if due { fire() } }

    func stop() {
        stopped = true
        for timer in [fallbackTimer, rosterTimer, retryTimer] { timer?.cancel() }
        fallbackTimer = nil; rosterTimer = nil; retryTimer = nil
    }

    private func fire() {
        guard !started, !stopped else { return }
        guard ready() else { due = true; return }
        if moving() {
            guard retryTimer == nil else { return }
            retryTimer = clock.schedule(after: Self.transitionRetry) { [weak self] in
                self?.retryTimer = nil
                self?.fire()
            }
            return
        }
        started = true
        due = false
        for timer in [fallbackTimer, rosterTimer, retryTimer] { timer?.cancel() }
        fallbackTimer = nil; rosterTimer = nil; retryTimer = nil
        AppLog.trace("store", "capabilities warm-up: started (sawRoster=\(sawRoster))")
        Task { @MainActor [warm] in await warm() }
    }
}
