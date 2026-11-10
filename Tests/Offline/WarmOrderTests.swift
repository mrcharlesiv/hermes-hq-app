import Foundation
import Testing
@testable import HermesHQNative

/// [offline] Caches on the first frame (docs/spec/3x-offline.md §6.10): the order chat tails are read ahead in, the
/// Capabilities warm-up's timing, the 30-minute keep, and the Jobs list's size cap.
@MainActor @Suite struct WarmOrderTests {
    typealias Clock = ReadFlightTests.FakeClock

    private func bot(_ id: String, chat: String?, minutesAgo: Double, pinned: Bool = false, order: Int? = nil, hidden: Bool = false) -> Bot {
        Bot(id: id, name: id.capitalized, role: nil, preview: nil, lastActive: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
            isWorking: false, unread: false, pinned: pinned, pinOrder: order, sectionName: nil, hidden: hidden,
            canonicalSessionId: chat, head: nil)
    }

    private func row(_ id: String, _ profile: String, minutesAgo: Double) -> SessionSummary {
        SessionSummary(id: id, profile: profile, title: id, preview: nil, lastActive: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
                       source: nil, unread: false, isRunning: false)
    }

    @Test func lastChatThenPinnedThenBotsNewestFirstThenSessionsThenHidden() {
        let bots = [bot("old", chat: "c-old", minutesAgo: 90), bot("new", chat: "c-new", minutesAgo: 1),
                    bot("pinB", chat: "c-pinB", minutesAgo: 500, pinned: true, order: 2), bot("pinA", chat: "c-pinA", minutesAgo: 600, pinned: true, order: 1),
                    bot("ghost", chat: "c-ghost", minutesAgo: 0, hidden: true), bot("nochat", chat: nil, minutesAgo: 0)]
        let sessions = [row("s-1", "new", minutesAgo: 2), row("s-2", "old", minutesAgo: 3)]
        let order = WarmOrder.order(lastChat: WarmOrder.LastChat(profile: "old", storedId: "s-2"), bots: bots, sessions: sessions)
        #expect(order.map(\.target.storedId) == ["s-2", "c-pinA", "c-pinB", "c-new", "c-old", "s-1", "c-ghost"])
        #expect(order.first?.lastActive == sessions[1].lastActive, "the remembered chat's own activity decides its staleness")
    }

    @Test func aRememberedBotChatIsItsBotsCurrentChat() {
        let bots = [bot("a", chat: "c-a", minutesAgo: 5), bot("b", chat: "c-b", minutesAgo: 1)]
        let order = WarmOrder.order(lastChat: WarmOrder.LastChat(profile: "a", storedId: nil), bots: bots, sessions: [])
        #expect(order.map(\.target) == [WarmOrder.Target(profile: "a", storedId: "c-a"), WarmOrder.Target(profile: "b", storedId: "c-b")])
        #expect(order.first?.lastActive == bots[0].lastActive)
    }

    @Test func oneEntryPerChatAndOnlyFifteenSessionRows() {
        let bots = [bot("a", chat: "c-a", minutesAgo: 1)]
        var sessions = (1...40).map { row("s-\($0)", "a", minutesAgo: Double($0)) }
        sessions.insert(row("c-a", "a", minutesAgo: 1), at: 0)      // a list that also names the bot's chat
        let order = WarmOrder.order(lastChat: nil, bots: bots, sessions: sessions)
        #expect(order.count == 15, "the bot's chat once, then the next 14 of the first 15 rows")
        #expect(order.map(\.target.storedId).prefix(3) == ["c-a", "s-1", "s-2"])
        #expect(Set(order.map(\.target)).count == order.count)
    }

    @Test func nothingToReadIsAnEmptyList() {
        #expect(WarmOrder.order(lastChat: nil, bots: [], sessions: []).isEmpty)
        #expect(WarmOrder.order(lastChat: WarmOrder.LastChat(profile: "gone", storedId: nil), bots: [], sessions: []).isEmpty)
        #expect(WarmOrder.order(lastChat: nil, bots: [bot("a", chat: "", minutesAgo: 1)], sessions: []).isEmpty)
    }

    // MARK: Capabilities warm-up

    final class Probe {
        var ready = true
        var moving = false
        var warms = 0
    }

    private func warm(_ probe: Probe, clock: Clock) -> PageDataWarm {
        PageDataWarm(clock: clock, ready: { probe.ready }, moving: { probe.moving }, warm: { probe.warms += 1 })
    }

    @Test func runsSixHundredMillisecondsAfterTheRosterHasRows() async {
        let clock = Clock(), probe = Probe()
        let warmUp = warm(probe, clock: clock)
        warmUp.activated()
        await clock.advance(2)
        #expect(probe.warms == 0, "nothing before the list has rows")
        warmUp.rosterHasRows()
        await clock.advance(0.59)
        #expect(probe.warms == 0)
        await clock.advance(0.02)
        #expect(probe.warms == 1)
        warmUp.rosterHasRows()
        await clock.advance(20)
        #expect(probe.warms == 1, "once per activation: the 8 s fallback does not run it again")
        #expect(clock.pending == 0)
    }

    @Test func theFallbackRunsItAtEightSeconds() async {
        let clock = Clock(), probe = Probe()
        let warmUp = warm(probe, clock: clock)
        warmUp.activated()
        await clock.advance(7.9)
        #expect(probe.warms == 0)
        await clock.advance(0.2)
        #expect(probe.warms == 1)
    }

    @Test func waitsOutANavigationTransition() async {
        let clock = Clock(), probe = Probe()
        let warmUp = warm(probe, clock: clock)
        probe.moving = true
        warmUp.rosterHasRows()
        await clock.advance(0.6)
        #expect(probe.warms == 0)
        await clock.advance(0.5)                       // two retries, still moving
        #expect(probe.warms == 0)
        probe.moving = false
        await clock.advance(0.25)
        #expect(probe.warms == 1)
    }

    @Test func heldWhileNotConnectedOrInTheBackgroundThenRunsWhenThatChanges() async {
        let clock = Clock(), probe = Probe()
        let warmUp = warm(probe, clock: clock)
        probe.ready = false
        warmUp.activated()
        warmUp.rosterHasRows()
        await clock.advance(30)
        #expect(probe.warms == 0)
        #expect(clock.pending == 0, "no timer spins while it waits")
        warmUp.conditionsChanged()
        #expect(probe.warms == 0, "still not ready")
        probe.ready = true
        warmUp.conditionsChanged()
        await clock.advance(0)
        #expect(probe.warms == 1)
        warmUp.conditionsChanged()
        await clock.advance(1)
        #expect(probe.warms == 1)
    }

    @Test func stopCancelsIt() async {
        let clock = Clock(), probe = Probe()
        let warmUp = warm(probe, clock: clock)
        warmUp.activated()
        warmUp.rosterHasRows()
        warmUp.stop()
        await clock.advance(30)
        #expect(probe.warms == 0 && clock.pending == 0)
    }

    @Test func answersAreKeptThirtyMinutesPerAccountAndBot() {
        var now = Date(timeIntervalSince1970: 5_000)
        let cache = CapabilitiesWarmCache(now: { now })
        let skill = SkillInfo(name: "garden-notes", description: "Keeps the planting calendar.", category: nil, enabled: true, usage: 0, provenance: nil)
        cache.store(skills: [skill], official: nil, account: "acct-1", profile: "default")
        #expect(cache.entry(account: "acct-1", profile: "default")?.skills.map(\.name) == ["garden-notes"])
        #expect(cache.entry(account: "acct-1", profile: "research") == nil)
        #expect(cache.entry(account: "acct-2", profile: "default") == nil)
        now += 30 * 60
        #expect(cache.entry(account: "acct-1", profile: "default") != nil, "30 minutes exactly is still kept")
        now += 1
        #expect(cache.entry(account: "acct-1", profile: "default") == nil)
        cache.store(skills: [skill], official: [], account: "acct-1", profile: "default")
        cache.store(skills: [skill], official: [], account: "acct-10", profile: "default")
        cache.forget(account: "acct-1")
        #expect(cache.entry(account: "acct-1", profile: "default") == nil)
        #expect(cache.entry(account: "acct-10", profile: "default") != nil, "another account whose id starts the same is untouched")
    }

    // MARK: Jobs list cap

    @Test func aJobsListOverTheLimitIsNotSaved() async throws {
        let small = try #require(CronJob(json: ["id": "a", "name": "Job a", "profile": "inbox", "enabled": true, "state": "scheduled"]))
        #expect(JobsStore.fitsCache(PagesCached(at: 1, value: [small])))
        let big = try #require(CronJob(json: ["id": "b", "name": .string(String(repeating: "x", count: 310_000)), "profile": "inbox",
                                              "enabled": true, "state": "scheduled"]))
        #expect(!JobsStore.fitsCache(PagesCached(at: 1, value: [big])))
        #expect(JobsStore.cacheLimit == 300_000)
        // A saved list is replaced by nothing when the fresh one is too large: the next cold start reads fresh.
        let dir = FileManager.default.temporaryDirectory.appending(path: "offline-jobs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = PagesFakeClient { _ in JobsStoreTests.jobs(["a"]) }
        let store = JobsStore(client: client, account: client.account, directory: dir)
        await store.refresh()
        PagesCache.flush()
        #expect(JobsStore(client: client, account: client.account, directory: dir).hasList, "a normal list is kept")
        client.respond { _ in
            .array([["id": "b", "name": .string(String(repeating: "x", count: 310_000)), "profile": "inbox", "enabled": true, "state": "scheduled"]])
        }
        await store.refresh()
        #expect(store.jobs.map(\.id) == ["b"], "the big list is still shown")
        PagesCache.flush()
        #expect(!JobsStore(client: client, account: client.account, directory: dir).hasList, "but not kept, and the older copy is gone")
    }
}
