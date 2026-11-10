// [botslist] Unit tests for the m9 Bots-list stream (docs/spec/3x-botslist.md): the Undo pill's clock, the switcher's
// VoiceOver sentence, the standing-problem classifier, the row's status order, "Not Delivered:" ahead of "Draft:",
// "Waking up…" after a second, the pinned reconcile's writes, and Bot Info's status line.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct BotsListTests {
    // MARK: L237 the Undo pill's clock

    @Test func undoClockRunsFourSecondsAndEightAtAccessibilitySizes() {
        let start = Date(timeIntervalSince1970: 1_000)
        var clock = UndoPillClock(duration: 4, accessibilitySize: false)
        #expect(clock.resume(now: start) == 4)
        #expect(clock.isRunning)
        #expect(abs(clock.left(now: start.addingTimeInterval(1.5)) - 2.5) < 0.001)
        var large = UndoPillClock(duration: 4, accessibilitySize: true)
        #expect(large.resume(now: start) == 8)
        var long = UndoPillClock(duration: 10, accessibilitySize: true)
        #expect(long.resume(now: start) == 10)
    }

    @Test func undoClockPausesAndResumesWithWhatWasLeft() {
        let start = Date(timeIntervalSince1970: 1_000)
        var clock = UndoPillClock(duration: 4, accessibilitySize: false)
        _ = clock.resume(now: start)
        clock.hold(.finger, now: start.addingTimeInterval(1))
        #expect(!clock.isRunning)
        // Held for a minute: nothing is lost, and it does not start over.
        let left = clock.release(.finger, now: start.addingTimeInterval(61))
        #expect(left.map { abs($0 - 3) < 0.001 } == true)
        #expect(abs(clock.left(now: start.addingTimeInterval(62)) - 2) < 0.001)
    }

    @Test func undoClockWaitsForEveryHold() {
        let start = Date(timeIntervalSince1970: 1_000)
        var clock = UndoPillClock(duration: 4, accessibilitySize: false)
        clock.hold(.away, now: start)
        #expect(clock.resume(now: start) == nil)                       // made while the away pill shows: never starts
        clock.hold(.voiceOver, now: start.addingTimeInterval(1))
        #expect(clock.release(.away, now: start.addingTimeInterval(5)) == nil)
        #expect(clock.release(.voiceOver, now: start.addingTimeInterval(9)) == 4)
        // A second resume while running keeps the first start.
        #expect(clock.resume(now: start.addingTimeInterval(10)).map { abs($0 - 3) < 0.001 } == true)
        #expect(clock.left(now: start.addingTimeInterval(100)) == 0)
    }

    // MARK: L128 the switcher's VoiceOver sentence

    @Test func switcherSentence() {
        let label = { (page: String?, switching: String?, link: String?, news: Int) in
            GatewayNews.switcherLabel(page: page, gateway: "Studio", switchingTo: switching, link: link, otherNews: news)
        }
        #expect(label(nil, nil, nil, 0) == "On Studio")
        #expect(label("Bots", nil, nil, 2) == "Bots, on Studio, 2 new on other gateways")
        #expect(label(nil, nil, nil, 12) == "On Studio, more than 9 new on other gateways")
        #expect(label(nil, nil, "Offline", 1) == "On Studio, offline, 1 new on other gateways")
        #expect(label(nil, nil, "Reconnecting…", 0) == "On Studio, reconnecting")
        #expect(label("Bots", "Beta", "Offline", 3) == "Bots, switching to Beta")
        #expect(label(nil, "Beta", nil, 0) == "Switching to Beta")
        #expect(!label("Bots", nil, nil, 2).contains("Dispatch"))
    }

    // MARK: L185 the classifier

    @Test func standingProblemsAreNamedAndPassingOnesAreNot() {
        let cases: [(String, Attention?)] = [
            ("HTTP 401 Unauthorized", .providerAuthOrAccess),
            ("403 Forbidden: this key cannot use the model", .providerAuthOrAccess),
            ("Authentication failed for provider anthropic", .providerAuthOrAccess),
            ("invalid api key", .providerAuthOrAccess),
            ("Invalid_API_Key supplied", .providerAuthOrAccess),
            ("Your credentials are expired", .providerAuthOrAccess),
            ("credential invalid", .providerAuthOrAccess),
            ("You exceeded your current quota", .providerQuotaLimit),
            ("Out of funds", .providerQuotaLimit),
            ("insufficient credits to run this request", .providerQuotaLimit),
            ("Insufficient balance", .providerQuotaLimit),
            ("402 Payment Required", .providerQuotaLimit),
            ("Check your billing details", .providerQuotaLimit),
            ("No LLM provider configured", .missingConfig),
            ("No access token for provider", .missingConfig),
            ("provider is not configured", .missingConfig),
            ("No API key found for openai", .missingConfig),
            ("Missing API key", .missingConfig),
            ("The agent is blocked on a tool", .agentBlocked),
            ("Rate limit reached", nil),
            ("rate-limited, slow down", nil),
            ("429 Too Many Requests", nil),
            ("Too many requests", nil),
            ("500 Internal Server Error", nil),
            ("503 Service Unavailable", nil),
            ("server error", nil),
            ("The model is overloaded", nil),
            ("Request timed out", nil),
            ("timeout waiting for the provider", nil),
            ("Temporary failure, 401 will clear", nil),            // a passing failure wins over the words after it
            ("Something else went wrong", nil),
            ("", nil),
        ]
        for (message, expected) in cases {
            #expect(Attention.reason(from: message) == expected, "\(message)")
        }
        #expect(Attention.reason(from: nil) == nil)
        // The gateway's own reason wins over the message.
        #expect(Attention.reason(from: "rate limit", reason: "provider_quota_limit") == .providerQuotaLimit)
        #expect(Attention.reason(from: "401", reason: "something_new") == .providerAuthOrAccess)
        for kind in Attention.allCases {
            #expect(!kind.words.isEmpty)
            #expect(!kind.words.contains("Dispatch") && !kind.words.lowercased().contains("profile"))
        }
    }

    // MARK: L184 / L185 / L189 the row

    private func bot(_ edit: (inout RosterBuilder.Input) -> Void = { _ in }) -> Bot {
        var input = RosterBuilder.Input(profiles: [
            RosterProfile(json: BotsTest.row("ivy", canonical: BotsTest.session("c-ivy", preview: "see you at noon", lastActive: 100)))!,
        ])
        edit(&input)
        return RosterBuilder.build(input).layout.flat.first { $0.id == "ivy" }!
    }

    @Test func rowStatusOrder() {
        #expect(BotList.rowStatus(bot()) == .idle)
        #expect(BotList.secondLine(bot()).text == "see you at noon")
        let working = bot { $0.working = ["ivy"] }
        #expect(BotList.rowStatus(working) == .working)
        let waking = bot { $0.working = ["ivy"]; $0.waking = ["ivy"] }
        #expect(BotList.rowStatus(waking) == .waking)
        #expect(BotList.secondLine(waking).text == "Waking up…")
        #expect(BotList.secondLine(waking).tone == .secondary)
        let failed = bot { $0.working = ["ivy"]; $0.attention = ["ivy": Attention.providerQuotaLimit.words] }
        #expect(BotList.rowStatus(failed) == .attention)
        #expect(BotList.secondLine(failed).text == "Quota or balance exhausted")
        #expect(BotList.secondLine(failed).tone == .attention)
        // While the chat is opening the row says so, and the problem comes back after.
        let both = bot { $0.waking = ["ivy"]; $0.attention = ["ivy": Attention.missingConfig.words] }
        #expect(BotList.rowStatus(both) == .waking)
    }

    @Test func notDeliveredComesBeforeDraft() {
        let draft = bot { $0.drafts = ["ivy": "Half a thought"] }
        #expect(draft.previewPrefix == "Draft:")
        #expect(draft.preview?.hasSuffix("Half a thought") == true, "\(String(describing: draft.preview))")
        let lost = bot { $0.drafts = ["ivy": "Half a thought"]; $0.lost = ["ivy": "Did this arrive"] }
        #expect(lost.previewPrefix == "Not Delivered:")
        #expect(lost.previewPrefix == RosterPreview.notDeliveredPrefix)
        #expect(lost.preview?.hasSuffix("Did this arrive") == true, "\(String(describing: lost.preview))")
        #expect(lost.preview?.contains("Half a thought") == false)
        let only = bot { $0.lost = ["ivy": "Did this arrive"] }
        #expect(only.previewPrefix == "Not Delivered:")
    }

    // MARK: The store

    private func store(_ gateway: MetaGateway, reconcile: Bool = false,
                       prepare: (BotStore) -> Void = { _ in }) async -> BotStore {
        let store = BotStore(client: gateway.client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast)
        store.reconcilesPinned = reconcile
        prepare(store)
        await BotsTest.waitUntil { store.phase == .full }
        return store
    }

    @Test func wakingShowsOnlyAfterTheGraceAndEndsWithTheOpen() async throws {
        let store = await store(MetaGateway(["ivy": [:]]))
        store.wakingGrace = .milliseconds(150)
        store.noteBotOpening("ivy", true)
        #expect(store.bot(named: "ivy")?.waking == false)               // a fast open never says it
        store.noteBotOpening("ivy", false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.bot(named: "ivy")?.waking == false)

        store.noteBotOpening("ivy", true)
        #expect(await BotsTest.waitUntil { store.bot(named: "ivy")?.waking == true })
        #expect(store.isWaking("ivy"))
        store.noteBotOpening("ivy", false)
        #expect(store.bot(named: "ivy")?.waking == false)
        store.stop()
    }

    @Test func aStandingFailureStaysUntilTheNextGoodTurn() async throws {
        let store = await store(MetaGateway(["ivy": [:], "ada": [:]]))
        store.noteTurnFailed(profile: "ivy", message: "429 Too Many Requests")
        #expect(store.bot(named: "ivy")?.attention == nil)
        store.noteTurnFailed(profile: "ivy", message: "401 Unauthorized")
        #expect(store.bot(named: "ivy")?.attention == "Sign in again for this bot")
        #expect(store.bot(named: "ada")?.attention == nil)
        store.noteTurnFailed(profile: "ivy", message: "Request timed out")       // a passing failure keeps the standing one
        #expect(store.bot(named: "ivy")?.attention == "Sign in again for this bot")
        store.noteTurnFailed(profile: "ivy", message: "out of funds")            // the latest standing one wins
        #expect(store.bot(named: "ivy")?.attention == "Quota or balance exhausted")
        store.noteTurnSucceeded(profile: "ivy")
        #expect(store.bot(named: "ivy")?.attention == nil)
        store.stop()
    }

    @Test func lostWordsReachTheRowAheadOfADraft() async throws {
        let store = await store(MetaGateway(["ivy": [:]]))
        store.draftWords = { _, _ in "typing" }
        store.refreshDrafts()
        #expect(store.bot(named: "ivy")?.previewPrefix == "Draft:")
        nonisolated(unsafe) var asked: [String] = []
        store.lostWords = { profile, ids in asked = ids; return profile == "ivy" ? "Never arrived" : nil }
        store.refreshDrafts()
        #expect(store.bot(named: "ivy")?.previewPrefix == "Not Delivered:")
        #expect(store.bot(named: "ivy")?.preview?.hasSuffix("Never arrived") == true)
        #expect(asked.contains("s-ivy"))
        store.lostWords = { _, _ in nil }
        store.refreshDrafts()
        #expect(store.bot(named: "ivy")?.previewPrefix == "Draft:")
        store.stop()
    }

    // MARK: L147 pinned reconcile

    private func metaWrites(_ gateway: MetaGateway) -> [JSONValue] {
        gateway.client.calls("profiles.configure").compactMap { $0.params["ui_meta"]?["hermes-bots"] }
    }

    @Test func aDesktopPinIsFiledUnderPinnedWithOneWrite() async throws {
        // The desktop set the flag only: the bot still sits in Office.
        let gateway = MetaGateway(["ivy": ["pinned": true, "sectionId": "s1", "sectionName": "Office"], "ada": [:]])
        let store = await store(gateway, reconcile: true)
        #expect(await BotsTest.waitUntil { gateway.withLock { gateway.meta["ivy"]?["hermes-bots"]?["sectionId"]?.string } == PinnedSection.id })
        let saved = gateway.withLock { gateway.meta["ivy"]?["hermes-bots"] }
        #expect(saved?["sectionName"]?.string == "Pinned")
        #expect(saved?["pinned"]?.bool == true)
        #expect(saved?[PinnedSection.homeKey]?["id"]?.string == "s1")
        #expect(saved?[PinnedSection.homeKey]?["name"]?.string == "Office")
        // The next rosters agree: nothing more is written, and never for the bot that was right all along.
        await store.refresh()
        await store.refresh()
        try await Task.sleep(for: .milliseconds(200))
        #expect(metaWrites(gateway).count == 1)
        #expect(gateway.client.calls("profiles.configure").allSatisfy { $0.params["name"]?.string == "ivy" })
        store.stop()
    }

    @Test func aDesktopUnpinGoesHome() async throws {
        let gateway = MetaGateway(["ivy": ["pinned": false, "sectionId": .string(PinnedSection.id), "sectionName": "Pinned",
                                           PinnedSection.homeKey: ["id": "gone", "name": "Office"]]])
        let store = await store(gateway, reconcile: true)
        #expect(await BotsTest.waitUntil { self.metaWrites(gateway).count == 1 })
        let home = gateway.withLock { gateway.meta["ivy"]?["hermes-bots"] }
        #expect(home?["sectionId"]?.string == nil, "\(String(describing: home))")
        #expect(home?[PinnedSection.homeKey]?.bool == false)
        await store.refresh()
        try await Task.sleep(for: .milliseconds(200))
        #expect(metaWrites(gateway).count == 1)
        store.stop()
    }

    @Test func aFailedReconcileWaitsAMinuteAndSaysNothing() async throws {
        let gateway = MetaGateway(["ivy": ["pinned": true, "sectionId": "s1", "sectionName": "Office"]])
        gateway.withLock {
            gateway.scripted = Array(repeating: { throw RPCError(code: 5064, message: "disk full", data: nil) }, count: 1)
        }
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 10_000)
        let store = await store(gateway, reconcile: true) { $0.pinnedClock = { now } }
        #expect(await BotsTest.waitUntil { gateway.client.calls("profiles.configure").count >= 1 })
        try await Task.sleep(for: .milliseconds(300))
        let after = gateway.client.calls("profiles.configure").count
        await store.refresh()
        await store.refresh()
        try await Task.sleep(for: .milliseconds(300))
        #expect(gateway.client.calls("profiles.configure").count == after)          // not again inside the minute
        #expect(gateway.withLock { gateway.meta["ivy"]?["hermes-bots"]?["sectionId"]?.string } == "s1")
        now = now.addingTimeInterval(61)
        await store.refresh()
        #expect(await BotsTest.waitUntil { gateway.withLock { gateway.meta["ivy"]?["hermes-bots"]?["sectionId"]?.string } == PinnedSection.id })
        store.stop()
    }

    @Test func reconcileIsOffUnlessTurnedOn() async throws {
        let gateway = MetaGateway(["ivy": ["pinned": true, "sectionId": "s1", "sectionName": "Office"]])
        let store = await store(gateway)
        await store.refresh()
        try await Task.sleep(for: .milliseconds(200))
        #expect(gateway.client.calls("profiles.configure").isEmpty)
        store.stop()
    }

    // MARK: L213 Bot Info's status line

    @Test func infoStatusLine() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)            // 2027-01-15 08:00 UTC
        let at = { (ago: TimeInterval) -> String? in
            var b = self.bot()
            b.lastActive = now.addingTimeInterval(-ago)
            return BotList.infoStatus(b, now: now, calendar: calendar)?.text
        }
        #expect(at(20) == "Active now")
        #expect(at(5 * 60) == "Active 5 min ago")
        #expect(at(3 * 3600) == "Active 3 hr ago")
        #expect(at(30 * 3600) == "Active yesterday")
        #expect(at(4 * 86_400) == "Active 4 days ago")
        var never = bot()
        never.lastActive = nil
        #expect(BotList.infoStatus(never, now: now, calendar: calendar) == nil)
        // A live status wins, in the row's own words.
        let working = bot { $0.working = ["ivy"] }
        #expect(BotList.infoStatus(working, now: now, calendar: calendar)?.text == "Working…")
        let failed = bot { $0.attention = ["ivy": "Provider not set up"] }
        #expect(BotList.infoStatus(failed, now: now, calendar: calendar)?.tone == .attention)
    }
}
