// Siri, Shortcuts and quick actions: the stored values and their rules (docs/spec/3x-intents.md §13 A6–A8, A10, A12,
// A21, A24, A34, A35, A43–A45, A50). The request-store, catalog-policy and legacy-id cases are the web app's own
// checks (W:scripts/native-shortcuts/main.swift), run against the native ports.

import AppIntents
import Foundation
import Intents
import Testing
import UIKit
@testable import HermesHQNative

/// (`Thread.isMainThread` cannot be read in an async function.)
nonisolated private func intentsOnMainThread() -> Bool { Thread.isMainThread }

@Suite struct VoiceBotCatalogTests {
    // A6
    @Test func readsWhatBuild240WroteAndWritesWhatItReads() throws {
        let box = IntentsDefaults()
        // The §3.2 example, byte for byte.
        let account = "http://127.0.0.1:9920\nvoice-fixture"
        let id = "aHR0cDovLzEyNy4wLjAuMTo5OTIwCnZvaWNlLWZpeHR1cmUKaW9zLWRpcmVjdDo6aXZ5"
        #expect(VoiceBotCatalog.account(url: "http://127.0.0.1:9920", username: "voice-fixture") == account)
        #expect(VoiceBotCatalog.key(profile: "ivy") == "ios-direct::ivy")
        #expect(VoiceBotCatalog.id(account: account, key: "ios-direct::ivy") == id)
        // Build 240's JSONEncoder output for [VoiceNoteBot] (keys in declaration order, "\n" escaped).
        let literal = #"[{"id":"\#(id)","name":"Ivy","key":"ios-direct::ivy","account":"http:\/\/127.0.0.1:9920\nvoice-fixture"}]"#
        box.defaults.set(Data(literal.utf8), forKey: "dispatch.voice.bots")
        #expect(VoiceBotCatalog.bots(box.defaults) == [VoiceBotRecord(id: id, name: "Ivy", key: "ios-direct::ivy", account: account)])
        // What native writes has the same four keys and nothing else.
        #expect(VoiceBotCatalog.store([IntentsFixture.record("ivy")], box.defaults))
        let stored = try #require(box.defaults.data(forKey: "dispatch.voice.bots"))
        let rows = try #require(try JSONSerialization.jsonObject(with: stored) as? [[String: String]])
        #expect(rows.count == 1 && Set(rows[0].keys) == ["id", "name", "key", "account"])
        #expect(rows[0]["key"] == "ios-direct::ivy" && rows[0]["account"] == IntentsFixture.account)
        #expect(!VoiceBotCatalog.store([IntentsFixture.record("ivy")], box.defaults), "the same bots are not written twice")
    }

    // A7
    @Test func resolvesAnIdHoweverItsAddressWasWritten() {
        let box = IntentsDefaults()
        VoiceBotCatalog.store([IntentsFixture.record("default", name: "Hermes"), IntentsFixture.record("ivy")], box.defaults)
        let exact = IntentsFixture.record("ivy").id
        #expect(VoiceBotCatalog.resolve(id: exact, box.defaults) == IntentsFixture.record("ivy"))
        func id(_ url: String, _ username: String = "qa", _ key: String = "ios-direct::ivy") -> String {
            VoiceBotCatalog.id(account: VoiceBotCatalog.account(url: url, username: username), key: key)
        }
        for other in [id("https://fixture.invalid/"), id("https://FIXTURE.invalid"), id("HTTPS://Fixture.Invalid/")] {
            let hit = VoiceBotCatalog.resolve(id: other, box.defaults)
            #expect(hit?.key == "ios-direct::ivy" && hit?.name == "Ivy")
            #expect(hit?.id == other, "the entity keeps the id the shortcut stored")
        }
        #expect(VoiceBotCatalog.resolve(id: id("https://fixture.invalid", "someone"), box.defaults) == nil)
        #expect(VoiceBotCatalog.resolve(id: id("https://fixture.invalid", "qa", "ios-direct::gone"), box.defaults) == nil)
        #expect(VoiceBotCatalog.resolve(id: id("https://other.invalid"), box.defaults) == nil)
        #expect(VoiceBotCatalog.resolve(id: "not base64 at all!", box.defaults) == nil)
    }

    // S17
    @Test func idsThatAreNobodysAnswerNil() {
        let box = IntentsDefaults()
        VoiceBotCatalog.store([IntentsFixture.record("ivy")], box.defaults)
        let oneLine = Data("only one line".utf8).base64EncodedString()
        let twoLines = Data("https://fixture.invalid\nqa".utf8).base64EncodedString()
        let otherAccount = VoiceBotCatalog.id(account: "https://elsewhere.invalid\nqa", key: "ios-direct::ivy")
        for id in ["", String(repeating: "A", count: 10_000), "%%%", oneLine, twoLines, otherAccount, "\n\n", "ios-direct::ivy"] {
            #expect(VoiceBotCatalog.resolve(id: id, box.defaults) == nil)
            #expect(ShortcutPolicy.legacyBot(id: id, box.defaults) == nil)
        }
    }

    // S16, S22
    @Test func namesAreStoredAsOneReadableLine() {
        #expect(VoiceBotCatalog.clean("  Ivy \n the   bot\t") == "Ivy the bot")
        #expect(VoiceBotCatalog.clean(String(repeating: "a", count: 300)).count == 160)
        #expect(VoiceBotCatalog.clean("   \n ") == "")
        #expect(VoiceBotCatalog.clean("🤖 Robo") == "🤖 Robo")
        #expect(VoiceBotCatalog.clean("سام") == "سام")
        #expect(ShortcutCatalogBuilder.displayName(IntentsFixture.bot("default", name: "  ")) == "Hermes")
        #expect(ShortcutCatalogBuilder.displayName(IntentsFixture.bot("ops", name: "")) == "ops")
        #expect(QuickActions.plan([ShortcutTarget(id: "e:bot:k", name: VoiceBotCatalog.clean(String(repeating: "é", count: 200)), kind: "bot", botKey: "k")])
            .first?.title == "New Voice Memo for " + String(repeating: "é", count: 160))
        // Two bots with one display name: both listed, told apart by their keys.
        let twins = ShortcutCatalogBuilder.botRecords(bots: [IntentsFixture.bot("ivy", name: "Ivy"), IntentsFixture.bot("ivy2", name: "Ivy")],
                                                      account: IntentsFixture.account)
        #expect(twins.map(\.name) == ["Ivy", "Ivy"] && twins[0].id != twins[1].id && twins.map(\.key) == ["ios-direct::ivy", "ios-direct::ivy2"])
    }

    // S3 (the read the system's pickers make)
    @Test func fiveHundredBotsAreReadQuickly() {
        let box = IntentsDefaults()
        let bots = (1...500).map { IntentsFixture.bot(String(format: "bot-%03d", $0), name: String(format: "Bot %03d", $0)) }
        VoiceBotCatalog.store(ShortcutCatalogBuilder.botRecords(bots: bots, account: IntentsFixture.account), box.defaults)
        var best = Double.infinity
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            let entities = VoiceBotCatalog.bots(box.defaults).map(VoiceNoteBot.init)
            best = min(best, (CFAbsoluteTimeGetCurrent() - start) * 1000)
            #expect(entities.count == 500)
        }
        #expect(best < 20, "500 bots read in \(best) ms")
    }
}

@Suite struct IntentsCatalogSyncTests {
    private func rig(interval: TimeInterval = 0) -> (IntentsDefaults, IntentsCatalogSync, () -> Int) {
        let box = IntentsDefaults()
        final class Count { var value = 0 }
        let count = Count()
        let sync = IntentsCatalogSync(defaults: box.defaults, interval: interval, refresh: { count.value += 1 })
        return (box, sync, { count.value })
    }

    // A8
    @Test func writesAndRefreshesOnlyWhenTheBotsChanged() {
        let (box, sync, refreshed) = rig()
        let account = IntentsFixture.account
        #expect(!sync.sync(bots: [], account: account, answered: false), "nothing is written while the roster loads")
        #expect(box.defaults.object(forKey: VoiceBotCatalog.botsKey) == nil && refreshed() == 0)
        #expect(!sync.sync(bots: [IntentsFixture.bot("ivy")], account: nil, answered: true), "signed out: nothing")

        let roster = [IntentsFixture.bot("default"), IntentsFixture.bot("ivy")]
        #expect(sync.sync(bots: roster, account: account, answered: true))
        #expect(!sync.sync(bots: roster, account: account, answered: true))
        #expect(sync.writes == 1 && refreshed() == 1)
        #expect(VoiceBotCatalog.bots(box.defaults).map(\.name) == ["Hermes", "Ivy"])

        #expect(sync.sync(bots: [IntentsFixture.bot("default"), IntentsFixture.bot("ivy", name: "Samantha")], account: account, answered: true))
        #expect(sync.writes == 2 && refreshed() == 2 && VoiceBotCatalog.bots(box.defaults).map(\.name) == ["Hermes", "Samantha"])
        #expect(sync.sync(bots: roster + [IntentsFixture.bot("ops")], account: account, answered: true))
        #expect(sync.writes == 3 && refreshed() == 3 && VoiceBotCatalog.bots(box.defaults).count == 3)
        #expect(sync.sync(bots: [IntentsFixture.bot("default")], account: account, answered: true))
        #expect(sync.writes == 4 && refreshed() == 4 && VoiceBotCatalog.bots(box.defaults).map(\.key) == ["ios-direct::default"])
        // The gateway answered with no bots at all: the pickers list none.
        #expect(sync.sync(bots: [], account: account, answered: true))
        #expect(VoiceBotCatalog.bots(box.defaults).isEmpty && refreshed() == 5)
    }

    // The Bots list is ordered by activity. A roster that only changed its order is no change for the pickers: nothing
    // is written and the system (which rations parameter refreshes) is not told.
    @Test func aRosterThatOnlyChangedItsOrderIsNotAChange() {
        let (box, sync, refreshed) = rig()
        let account = IntentsFixture.account
        let hermes = IntentsFixture.bot("default"), ivy = IntentsFixture.bot("ivy"), ops = IntentsFixture.bot("ops")
        #expect(sync.sync(bots: [hermes, ivy, ops], account: account, answered: true))
        #expect(!sync.sync(bots: [ivy, hermes, ops], account: account, answered: true))
        #expect(!sync.sync(bots: [ops, ivy, hermes], account: account, answered: true))
        #expect(sync.writes == 1 && refreshed() == 1)
        #expect(VoiceBotCatalog.bots(box.defaults).map(\.name) == ["Hermes", "Ivy", "Ops"], "the stored order stays")
        // A new run of the app (nothing remembered) with the roster in another order: still no write.
        let next = IntentsCatalogSync(defaults: box.defaults, interval: 0, refresh: { Issue.record("the system was told about a reorder") })
        #expect(!next.sync(bots: [ivy, ops, hermes], account: account, answered: true))
        #expect(next.writes == 0)
        // A rename in a reordered roster is a change, stored in the roster's order.
        #expect(sync.sync(bots: [IntentsFixture.bot("ivy", name: "Samantha"), hermes, ops], account: account, answered: true))
        #expect(sync.writes == 2 && refreshed() == 2)
        #expect(VoiceBotCatalog.bots(box.defaults).map(\.name) == ["Samantha", "Hermes", "Ops"])
        // Another account's bots with the same profiles are a change (the ids carry the account).
        #expect(sync.sync(bots: [hermes, ivy, ops], account: "https://other.invalid\nqa", answered: true))
        #expect(refreshed() == 3)
    }

    @Test func capsTheBotsAndTheirNames() {
        let (box, sync, _) = rig()
        let many = (0..<600).map { IntentsFixture.bot("bot\($0)", name: $0 == 0 ? String(repeating: "n", count: 300) : "Bot \($0)") }
        #expect(sync.sync(bots: many, account: IntentsFixture.account, answered: true))
        let stored = VoiceBotCatalog.bots(box.defaults)
        #expect(stored.count == 512 && stored[0].name.count == 160)
    }

    @Test func emptyingClearsOnceAndTellsTheSystem() {
        let (box, sync, refreshed) = rig()
        sync.empty()
        #expect(refreshed() == 0, "nothing stored, nothing to tell")
        sync.sync(bots: [IntentsFixture.bot("ivy")], account: IntentsFixture.account, answered: true)
        sync.empty()
        #expect(box.defaults.object(forKey: VoiceBotCatalog.botsKey) == nil && refreshed() == 2)
        // The same roster after an empty is written again (another account's sign-in, or signing back in).
        #expect(sync.sync(bots: [IntentsFixture.bot("ivy")], account: IntentsFixture.account, answered: true))
    }

    // S4: a hundred roster changes in a burst cost a handful of parameter refreshes, and the last name is what is stored.
    @Test func aBurstOfChangesRefreshesAtMostOncePerInterval() async throws {
        let (box, sync, refreshed) = rig(interval: 0.25)
        let start = Date()
        for index in 1...100 {
            sync.sync(bots: [IntentsFixture.bot("ivy", name: "Ivy \(index)")], account: IntentsFixture.account, answered: true)
            if index % 10 == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let burst = Date().timeIntervalSince(start)
        try await Task.sleep(nanoseconds: 600_000_000)                  // the trailing refresh
        #expect(sync.writes == 100)
        #expect(VoiceBotCatalog.bots(box.defaults).map(\.name) == ["Ivy 100"])
        let allowed = Int((burst + 0.6) / 0.25) + 2
        #expect(refreshed() >= 2 && refreshed() <= allowed, "\(refreshed()) refreshes for 100 changes in \(burst) s")
        let settled = refreshed()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(refreshed() == settled, "no refresh without a change")
    }
}

/// These read and write the app's own UserDefaults (the system's entity queries take no arguments), so they run one at
/// a time and put back what they found.
@Suite(.serialized) struct VoiceNoteQueryTests {
    private func withStoredBots<T>(_ records: [VoiceBotRecord], _ body: () async throws -> T) async rethrows -> T {
        let defaults = UserDefaults.standard
        let before = defaults.data(forKey: VoiceBotCatalog.botsKey)
        VoiceBotCatalog.store(records, defaults)
        defer {
            if let before { defaults.set(before, forKey: VoiceBotCatalog.botsKey) } else { defaults.removeObject(forKey: VoiceBotCatalog.botsKey) }
        }
        return try await body()
    }

    // A10
    @Test func theQueriesAnswerFromTheStoredCatalogOffTheMainThread() async throws {
        let records = [IntentsFixture.record("default", name: "Hermes"), IntentsFixture.record("ivy")]
        try await withStoredBots(records) {
            let wanted = records[1].id
            let result = try await Task.detached { () -> (suggested: [String], found: [String], missing: Int, onMain: Bool) in
                let query = VoiceNoteBotQuery()
                let suggested = try await query.suggestedEntities()
                let found = try await query.entities(for: [wanted, "nobody"])
                let missing = try await query.entities(for: [""]).count
                return (suggested.map(\.name), found.map(\.id), missing, intentsOnMainThread())
            }.value
            #expect(result.suggested == ["Hermes", "Ivy"])
            #expect(result.found == [wanted])
            #expect(result.missing == 0)
            #expect(!result.onMain)
        }
    }

    @Test func theEntityShowsTheBotsNameAndNothingElse() async {
        let entity = VoiceNoteBot(IntentsFixture.record("ivy", name: "Samantha"))
        #expect(String(localized: entity.displayRepresentation.title) == "Samantha")
        #expect(String(localized: VoiceNoteBot.typeDisplayRepresentation.name) == "Bot")
        #expect(String(localized: DispatchBotEntity.typeDisplayRepresentation.name) == "Bot")
    }

    @Test func theLegacyQueryListsThisSignInsBotsOnly() async throws {
        let defaults = UserDefaults.standard
        let keys = [ShortcutPolicy.accountKey, ShortcutPolicy.epochKey, ShortcutPolicy.catalogKey]
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        try await withStoredBots([IntentsFixture.record("default", name: "Hermes"), IntentsFixture.record("ivy")]) {
            defaults.set(ShortcutPolicy.accountDigest(url: IntentsFixture.url, username: IntentsFixture.username), forKey: ShortcutPolicy.accountKey)
            defaults.set("EPOCH-A", forKey: ShortcutPolicy.epochKey)
            let listed = try await Task.detached { try await DispatchBotQuery().suggestedEntities().map(\.id) }.value
            #expect(listed == ["EPOCH-A:bot:ios-direct::default", "EPOCH-A:bot:ios-direct::ivy"])
            let matched = try await DispatchBotQuery().entities(matching: "iv").map(\.name)
            #expect(matched == ["Ivy"])
            let stale = try await DispatchBotQuery().entities(for: ["EPOCH-B:bot:ios-direct::ivy", "EPOCH-A:bot:ios-direct::ivy"]).map(\.id)
            #expect(stale == ["EPOCH-A:bot:ios-direct::ivy"])
            // Another account signed in since: nothing resolves.
            defaults.set(ShortcutPolicy.accountDigest(url: "https://other.invalid", username: "qa"), forKey: ShortcutPolicy.accountKey)
            #expect(try await DispatchBotQuery().suggestedEntities().isEmpty)
        }
    }
}

@Suite struct VoiceNoteRequestStoreTests {
    // A12 (W:scripts/native-shortcuts/main.swift, checkVoiceNoteRequests)
    @Test func theRequestQueueOfBuild240() {
        let box = IntentsDefaults()
        final class Clock { var now = 1_000_000.0 }
        let clock = Clock()
        let store = VoiceNoteRequestStore(defaults: box.defaults, now: { clock.now })
        #expect(store.pending == nil)
        let first = store.enqueue(account: "fixture-account", key: "conn::scribe", name: "Scribe")
        #expect(first.expiresAt == clock.now + 60_000)
        #expect(first.account == "fixture-account" && first.key == "conn::scribe" && first.name == "Scribe")
        #expect(store.pending == first)
        // Another instance: the intent and the app are set up on different launches.
        let reopened = VoiceNoteRequestStore(defaults: UserDefaults(suiteName: box.name) ?? box.defaults, now: { clock.now })
        #expect(reopened.pending == first)
        reopened.acknowledge("other-request")
        #expect(reopened.pending == first)
        let second = store.enqueue(account: "fixture-account", key: "conn::other", name: "Other")
        #expect(second.id != first.id)
        reopened.acknowledge(first.id)
        #expect(reopened.pending == second)
        reopened.acknowledge(second.id)
        #expect(store.pending == nil)
        #expect(box.defaults.data(forKey: "dispatch.voice.request") == nil)
        let expiring = store.enqueue(account: "fixture-account", key: "conn::scribe", name: "Scribe")
        clock.now = expiring.expiresAt - 1
        #expect(reopened.pending == expiring)
        clock.now += 1
        #expect(reopened.pending == nil)
        #expect(box.defaults.data(forKey: "dispatch.voice.request") == nil)
        _ = store.enqueue(account: "other-account", key: "conn::scribe", name: "Scribe")
        clock.now += 3_600_000
        #expect(reopened.pending == nil)
        _ = store.enqueue(account: "fixture-account", key: "conn::scribe", name: "Scribe")
        store.clear()
        #expect(reopened.pending == nil)
    }

    @Test func theStoredJSONIsBuild240s() throws {
        let box = IntentsDefaults()
        let store = VoiceNoteRequestStore(defaults: box.defaults, now: { 5_000 })
        let request = store.enqueue(account: "a\nb", key: "ios-direct::ivy", name: "Ivy")
        let data = try #require(box.defaults.data(forKey: "dispatch.voice.request"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["id", "account", "key", "name", "expiresAt"])
        #expect(json["expiresAt"] as? Double == 65_000 && json["id"] as? String == request.id)
        // A value the web app wrote is read back.
        let literal = #"{"id":"R1","account":"a\nb","key":"ios-direct::ivy","name":"Ivy","expiresAt":64000}"#
        box.defaults.set(Data(literal.utf8), forKey: "dispatch.voice.request")
        #expect(store.pending == VoiceNoteRequest(id: "R1", account: "a\nb", key: "ios-direct::ivy", name: "Ivy", expiresAt: 64_000))
    }

    // DECISION I16, S18
    @Test func aRequestThatCouldNotHaveBeenWrittenIsCleared() {
        let box = IntentsDefaults()
        let store = VoiceNoteRequestStore(defaults: box.defaults, now: { 1_000_000 })
        func put(_ expires: String) {
            box.defaults.set(Data(#"{"id":"R","account":"a\nb","key":"ios-direct::ivy","name":"Ivy","expiresAt":\#(expires)}"#.utf8),
                             forKey: VoiceNoteRequestStore.storageKey)
        }
        for expires in ["4600000", "0", "-5", "\"soon\"", "1000000", "1060001", "null", "1e400"] {
            put(expires)
            #expect(store.pending == nil, "expiresAt \(expires)")
            #expect(box.defaults.object(forKey: VoiceNoteRequestStore.storageKey) == nil, "cleared for \(expires)")
        }
        put("1060000")
        #expect(store.pending?.id == "R", "exactly a minute away is the furthest a request can be")
        box.defaults.set("a string, not data", forKey: VoiceNoteRequestStore.storageKey)
        #expect(store.pending == nil && box.defaults.object(forKey: VoiceNoteRequestStore.storageKey) == nil)
        box.defaults.set(Data(#"{"id":"","account":"a","key":"k","name":"n","expiresAt":1000500}"#.utf8), forKey: VoiceNoteRequestStore.storageKey)
        #expect(store.pending == nil, "an empty id is nobody's request")
    }
}

@Suite struct ShortcutPolicyTests {
    private func target(_ id: String, _ kind: String = "bot", name: String = "Ivy") -> ShortcutTarget {
        ShortcutTarget(id: id, name: name, kind: kind, sessionId: kind == "session" ? id : nil, botKey: kind == "bot" ? id : nil,
                       group: kind == "room" ? id : nil)
    }

    // A34 (W:scripts/native-shortcuts/main.swift)
    @Test func theCatalogAndWhatItPermits() {
        let rows = [target("ivy"), target("ivy"), target("room", "room"), target("valid", "session"), target("bad", "session"),
                    target("bad", "other"), target(""), target("long", name: String(repeating: "a", count: 161))]
        let a = ShortcutPolicy.catalog(rows, epoch: "A", validSession: { $0 == "valid" })
        let b = ShortcutPolicy.catalog(rows, epoch: "B", validSession: { $0 == "valid" })
        #expect(a.map(\.id) == ["A:ivy", "A:room", "A:valid"])
        #expect(b.first?.id == "B:ivy")
        #expect(ShortcutPolicy.catalog(rows, epoch: "", validSession: { _ in true }).isEmpty)
        #expect(ShortcutPolicy.catalog((0..<200).map { target(String($0)) }, epoch: "A", validSession: { _ in true }).count == 128)
        #expect(ShortcutPolicy.catalog([target(String(repeating: "i", count: 513))], epoch: "A", validSession: { _ in true }).isEmpty)
        func allowed(_ action: String, _ id: String, epoch: String? = "A", current: String? = "A", targets: [ShortcutTarget]? = nil) -> Bool {
            ShortcutPolicy.permits(action, id: id, epoch: epoch, current: current, targets: targets ?? a)
        }
        #expect(allowed("open", "A:ivy")); #expect(allowed("memo", "A:ivy")); #expect(allowed("open", "A:room"))
        #expect(!allowed("memo", "A:room")); #expect(!allowed("memo", "A:valid"))
        #expect(!allowed("open", "A:missing")); #expect(!allowed("live-voice", "A:ivy")); #expect(!allowed("send", "A:ivy"))
        #expect(!allowed("open", "A:ivy", epoch: "B")); #expect(!allowed("open", "A:ivy", epoch: nil, current: "B", targets: b))
        #expect(!allowed("open", "A:ivy", epoch: nil, current: "B", targets: a))
        #expect(!allowed("search", "", epoch: nil, current: nil)); #expect(!allowed("search", "", epoch: ""))
        #expect(allowed("search", "", epoch: nil)); #expect(allowed("open", "A:ivy", epoch: nil))
    }

    // A21 (W:scripts/native-shortcuts/main.swift)
    @Test func aLegacyMemoIdResolvesOnlyInItsOwnSignIn() {
        let account = "https://fixture.invalid\nqa"
        let digest = ShortcutPolicy.accountDigest(url: "https://fixture.invalid", username: "qa")
        func key(_ id: String, epoch: String? = "A", account: String = account, digest: String? = digest) -> String? {
            ShortcutPolicy.legacyMemoBotKey(id: id, epoch: epoch, botAccount: account, currentAccountDigest: digest)
        }
        #expect(key("A:bot:ios-direct::scribe") == "ios-direct::scribe")
        #expect(key("A:bot:remote::scribe") == "remote::scribe")
        #expect(key("A:bot:ios-direct::scribe", epoch: "B") == nil)
        #expect(key("A:bot:ios-direct::scribe", epoch: nil) == nil)
        #expect(key("A:bot:ios-direct::scribe", epoch: "") == nil)
        #expect(key("A:bot:ios-direct::scribe", account: "https://other.invalid\nqa") == nil)
        #expect(key("A:bot:ios-direct::scribe", account: "https://fixture.invalid\nother") == nil)
        #expect(key("A:bot:ios-direct::scribe", account: "malformed") == nil)
        #expect(key("A:bot:ios-direct::scribe", digest: nil) == nil)
        #expect(key("A:session:ios-direct::scribe") == nil)
        #expect(key("A:room:ios-direct::scribe") == nil)
        #expect(key("A:bot:") == nil)
        #expect(key("A:bot:" + String(repeating: "a", count: 513)) == nil)
        #expect(key("A:bot:ios-direct::scribe", digest: ShortcutPolicy.accountDigest(url: "https://fixture.invalid", username: "qa\nother")) == nil)
        // A display name where the key belongs is nobody's bot.
        let box = IntentsDefaults()
        VoiceBotCatalog.store([IntentsFixture.record("ivy")], box.defaults)
        #expect(ShortcutPolicy.activate(url: IntentsFixture.url, username: IntentsFixture.username, box.defaults) == .first)
        let epoch = ShortcutPolicy.epoch(box.defaults) ?? ""
        #expect(ShortcutPolicy.legacyBot(id: epoch + ":bot:ios-direct::ivy", box.defaults)?.name == "Ivy")
        #expect(ShortcutPolicy.legacyBot(id: epoch + ":bot:Ivy", box.defaults) == nil)
        #expect(ShortcutPolicy.legacyBot(id: "OLD:bot:ios-direct::ivy", box.defaults) == nil)
        #expect(ShortcutPolicy.legacyEntities(box.defaults).map(\.id) == [epoch + ":bot:ios-direct::ivy"])
    }

    @Test func theSignInEpochChangesOnlyWithTheAccount() {
        let box = IntentsDefaults()
        #expect(ShortcutPolicy.epoch(box.defaults) == nil && ShortcutPolicy.digest(box.defaults) == nil)
        #expect(ShortcutPolicy.activate(url: "https://hq.example.com", username: "owner", box.defaults) == .first)
        let epoch = ShortcutPolicy.epoch(box.defaults)
        #expect(epoch != nil && ShortcutPolicy.digest(box.defaults) == ShortcutPolicy.accountDigest(url: "https://hq.example.com", username: "owner"))
        // The same account, its address written the other ways a build may have stored it: the epoch stays.
        for url in ["https://hq.example.com", "https://hq.example.com/", "https://HQ.Example.com", "HTTPS://hq.example.com/"] {
            #expect(ShortcutPolicy.activate(url: url, username: "owner", box.defaults) == .same)
            #expect(ShortcutPolicy.epoch(box.defaults) == epoch)
        }
        box.defaults.set(Data("[]".utf8), forKey: ShortcutPolicy.catalogKey)
        #expect(ShortcutPolicy.activate(url: "https://hq.example.com", username: "someone", box.defaults) == .changed)
        #expect(ShortcutPolicy.epoch(box.defaults) != epoch && box.defaults.object(forKey: ShortcutPolicy.catalogKey) == nil)
        #expect(ShortcutPolicy.activate(url: "https://other.example.com", username: "someone", box.defaults) == .changed)
        ShortcutPolicy.clear(box.defaults)
        #expect(ShortcutPolicy.epoch(box.defaults) == nil && ShortcutPolicy.digest(box.defaults) == nil)
    }

    @Test func theStoredCatalogIsBuild240sAndBounded() throws {
        let box = IntentsDefaults()
        let safe = ShortcutPolicy.catalog([target("ios-direct::ivy"), target("20261003_101500_ab12cd", "session", name: "Notes")], epoch: "E",
                                          validSession: NotificationRules.valid)
        let data = try #require(ShortcutPolicy.encoded(safe, box.defaults))
        box.defaults.set(data, forKey: ShortcutPolicy.catalogKey)
        #expect(ShortcutPolicy.encoded(safe, box.defaults) == nil, "the same catalog is not written twice")
        #expect(ShortcutPolicy.targets(box.defaults) == safe)
        // Build 240's own encoding (optional fields left out) decodes.
        let literal = #"[{"id":"E:bot:ios-direct::ivy","name":"Ivy","kind":"bot","botKey":"ios-direct::ivy"}]"#
        box.defaults.set(Data(literal.utf8), forKey: ShortcutPolicy.catalogKey)
        #expect(ShortcutPolicy.targets(box.defaults) == [ShortcutTarget(id: "E:bot:ios-direct::ivy", name: "Ivy", kind: "bot", botKey: "ios-direct::ivy")])
        // 128 targets with the longest names and ids allowed stay under the size limit.
        let wide = (0..<200).map { ShortcutTarget(id: "session:" + String(repeating: "s", count: 150) + "\($0)", name: String(repeating: "n", count: 160),
                                                  kind: "session", sessionId: String(repeating: "s", count: 150) + "\($0)") }
        let big = ShortcutPolicy.catalog(wide, epoch: UUID().uuidString, validSession: NotificationRules.valid)
        let encoded = try #require(ShortcutPolicy.encoded(big, box.defaults))
        #expect(big.count == 128 && encoded.count < 128 * 1024, "\(encoded.count) bytes")
    }
}

@Suite struct ShortcutCatalogBuilderTests {
    // A35
    @Test func botsThenListedChatsNewestFirst() {
        let bots = [IntentsFixture.bot("default", chat: "c_default", active: 100), IntentsFixture.bot("ivy", chat: "c_ivy", active: 300)]
        let sessions = [IntentsFixture.session("c_ivy", title: "Bot Chat", active: 900), IntentsFixture.session("s1", title: "Trip plan", active: 200),
                        IntentsFixture.session("s2", title: "  ", active: 50), IntentsFixture.session("s3", title: "Old", active: 400, archived: true)]
        let targets = ShortcutCatalogBuilder.targets(bots: bots, sessions: sessions, visits: [:])
        #expect(targets.map(\.id) == ["bot:ios-direct::ivy", "session:s1", "bot:ios-direct::default", "session:s2"],
                "a bot's own chat is not listed a second time, and an archived chat is not listed")
        #expect(targets.map(\.name) == ["Ivy", "Trip plan", "Hermes", "Chat"])
        #expect(targets[0].botKey == "ios-direct::ivy" && targets[1].sessionId == "s1" && targets[1].kind == "session")
        // A visit moves a target to the front.
        let visited = ShortcutCatalogBuilder.targets(bots: bots, sessions: sessions, visits: ["session:s2": 1000])
        #expect(visited.first?.id == "session:s2")
        // Equally recent rows keep the order they came in.
        let level = ShortcutCatalogBuilder.targets(bots: [IntentsFixture.bot("a"), IntentsFixture.bot("b"), IntentsFixture.bot("c")], sessions: [], visits: [:])
        #expect(level.map(\.id) == ["bot:ios-direct::a", "bot:ios-direct::b", "bot:ios-direct::c"])
    }

    @Test func twoHundredTargetsGiveTheNewest128() {
        let sessions = (0..<200).map { IntentsFixture.session("s\($0)", title: "Chat \($0)", active: Double($0)) }
        let targets = ShortcutCatalogBuilder.targets(bots: [IntentsFixture.bot("default", active: 1000)], sessions: sessions, visits: [:])
        #expect(targets.count == 128 && targets[0].id == "bot:ios-direct::default" && targets[1].id == "session:s199" && targets[127].id == "session:s73")
    }

    @Test func roomsRideAlongWhenAnotherStreamFeedsThem() {
        let room = ShortcutTarget(id: "room:ops", name: "Ops room", kind: "room", group: "ops")
        let targets = ShortcutCatalogBuilder.targets(bots: [IntentsFixture.bot("ivy", active: 10)], sessions: [], visits: [:], extra: [room],
                                                     extraActivity: ["room:ops": 50])
        #expect(targets.map(\.id) == ["room:ops", "bot:ios-direct::ivy"])
    }

    @Test func thePickersListEveryBotOnceInRosterOrder() {
        let records = ShortcutCatalogBuilder.botRecords(bots: [IntentsFixture.bot("ivy"), IntentsFixture.bot("default"), IntentsFixture.bot("ivy"),
                                                               IntentsFixture.bot("quiet", hidden: true), IntentsFixture.bot("")],
                                                        account: IntentsFixture.account)
        #expect(records.map(\.key) == ["ios-direct::ivy", "ios-direct::default", "ios-direct::quiet"])
        #expect(records.allSatisfy { $0.account == IntentsFixture.account && $0.id == VoiceBotCatalog.id(account: $0.account, key: $0.key) })
    }
}

@Suite struct QuickActionPlanTests {
    private let safe = [ShortcutTarget(id: "E:session:s1", name: "Trip plan", kind: "session", sessionId: "s1"),
                        ShortcutTarget(id: "E:bot:ios-direct::ivy", name: "Ivy", kind: "bot", botKey: "ios-direct::ivy"),
                        ShortcutTarget(id: "E:bot:ios-direct::default", name: "Hermes", kind: "bot", botKey: "ios-direct::default")]

    @Test func memoToTheMostRecentBotTheTwoMostRecentChatsThenSearch() {
        let plan = QuickActions.plan(safe, enabled: true)
        #expect(plan.map(\.title) == ["New Voice Memo for Ivy", "Open Trip plan", "Open Ivy", "Search Chats"])
        #expect(plan.map(\.symbol) == ["mic", "bubble.left", "bubble.left", "magnifyingglass"])
        #expect(plan.map(\.type) == ["dispatch.memo", "dispatch.open", "dispatch.open", "dispatch.search"])
        #expect(plan.map(\.id) == ["E:bot:ios-direct::ivy", "E:session:s1", "E:bot:ios-direct::ivy", nil])
    }

    @Test func noBotsNoMemoAndNeverALoneSearch() {
        #expect(QuickActions.plan([safe[0]], enabled: true).map(\.title) == ["Open Trip plan", "Search Chats"])
        #expect(QuickActions.plan([], enabled: true).isEmpty)
    }

    // A43
    @Test func switchedOffThereAreNoItems() {
        #expect(QuickActions.plan(safe, enabled: false).isEmpty)
        #expect(QuickActions.enabled, "DECISION I5: on")
    }

    // S20: an item that is not from this sign-in is refused before anything opens.
    @Test func itemsFromElsewhereAreRefused() {
        let box = IntentsDefaults()
        ShortcutPolicy.activate(url: IntentsFixture.url, username: IntentsFixture.username, box.defaults)
        let epoch = ShortcutPolicy.epoch(box.defaults) ?? ""
        let stored = ShortcutPolicy.catalog([ShortcutTarget(id: "bot:ios-direct::ivy", name: "Ivy", kind: "bot", botKey: "ios-direct::ivy"),
                                             ShortcutTarget(id: "session:s1", name: "Notes", kind: "session", sessionId: "s1")], epoch: epoch,
                                            validSession: NotificationRules.valid)
        box.defaults.set(ShortcutPolicy.encoded(stored, box.defaults), forKey: ShortcutPolicy.catalogKey)
        let id = epoch + ":bot:ios-direct::ivy"
        #expect(!QuickActions.perform(action: "open", id: id, epoch: "ANOTHER-EPOCH", defaults: box.defaults))
        #expect(!QuickActions.perform(action: "open", id: epoch + ":bot:ios-direct::gone", epoch: epoch, defaults: box.defaults))
        #expect(!QuickActions.perform(action: "open", id: String(repeating: "x", count: 600), epoch: epoch, defaults: box.defaults))
        #expect(!QuickActions.perform(action: "open", id: "", epoch: epoch, defaults: box.defaults), "an item with no userInfo")
        #expect(!QuickActions.perform(action: "memo", id: epoch + ":session:s1", epoch: epoch, defaults: box.defaults))
        #expect(!QuickActions.perform(action: "send", id: id, epoch: epoch, defaults: box.defaults))
        #expect(!QuickActions.openBot(legacyId: "OLD:bot:ios-direct::ivy", defaults: box.defaults))
        #expect(ShortcutPolicy.permits("open", id: id, epoch: epoch, current: epoch, targets: stored), "and the real one is allowed")
        let foreign = UIApplicationShortcutItem(type: "com.example.other", localizedTitle: "Other")
        #expect(!QuickActions.perform(foreign))
        // Signed out: nothing is ours.
        ShortcutPolicy.clear(box.defaults)
        #expect(!QuickActions.perform(action: "search", id: "", epoch: nil, defaults: box.defaults))
    }
}

@Suite struct LegacyNoteFileTests {
    private func write(_ url: URL, bytes: Int) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: bytes))
    }

    // A24, S19
    @Test func onlyAFileOfOursResolves() throws {
        let container = IntentsFixture.container()
        defer { try? FileManager.default.removeItem(at: container) }
        let support = container.appending(path: "Library/Application Support/HermesAttachments", directoryHint: .isDirectory)
        let caches = container.appending(path: "Library/Caches/HermesAttachments", directoryHint: .isDirectory)
        let roots = [support, caches]
        let uuid = "6F0C0E3B-4E67-4E0A-9A55-0C7D0C1B2A3F"
        let file = support.appending(path: uuid + "/Voice note.m4a")
        write(file, bytes: 2048)
        // The path build 240 stored, from a container iOS has since moved.
        let old = "/private/var/mobile/Containers/Data/Application/OLD-CONTAINER/Library/Application Support/HermesAttachments/\(uuid)/Voice note.m4a"
        #expect(LegacyNoteFile.resolve(old, roots: roots)?.path == file.path)
        #expect(LegacyNoteFile.resolve(file.path, roots: roots)?.path == file.path)
        // Stored under Caches, found under Application Support (the other folder is tried second).
        let cached = "/old/Library/Caches/HermesAttachments/\(uuid)/Voice note.m4a"
        #expect(LegacyNoteFile.resolve(cached, roots: roots)?.path == file.path)

        let outside = container.appending(path: "outside.m4a")
        write(outside, bytes: 100)
        try FileManager.default.createSymbolicLink(at: support.appending(path: "link.m4a"), withDestinationURL: outside)
        write(support.appending(path: "empty.m4a"), bytes: 0)
        let huge = support.appending(path: "huge.m4a")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(33 * 1024 * 1024))
        try handle.close()
        let prefix = "/old/Library/Application Support/HermesAttachments/"
        for bad in [prefix + "../../outside.m4a", "Library/Application Support/HermesAttachments/\(uuid)/Voice note.m4a", outside.path, "/etc/passwd",
                    "../../x", prefix + "link.m4a", prefix + "missing.m4a", prefix + "empty.m4a", prefix + "huge.m4a", prefix + uuid, prefix + uuid + "/",
                    prefix, "/var/mobile/Containers/Data/Application/OTHER-APP/Documents/secret.m4a", "", prefix + String(repeating: "a", count: 5000)] {
            #expect(LegacyNoteFile.resolve(bad, roots: roots) == nil, "\(bad.prefix(90))")
        }
        #expect(FileManager.default.fileExists(atPath: outside.path), "nothing outside was touched")
    }

    @Test func removingTakesTheRecordingAndItsEmptyFolderOnly() {
        let container = IntentsFixture.container()
        defer { try? FileManager.default.removeItem(at: container) }
        let support = container.appending(path: "Library/Application Support/HermesAttachments", directoryHint: .isDirectory)
        let roots = [support, container.appending(path: "Library/Caches/HermesAttachments", directoryHint: .isDirectory)]
        let folder = support.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = folder.appending(path: "Voice note.wav")
        write(file, bytes: 10)
        LegacyNoteFile.remove(file, roots: roots)
        #expect(!FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: support.path), "the attachments folder itself stays")
        // A folder that holds something else stays.
        let shared = support.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        write(shared.appending(path: "Voice note.wav"), bytes: 10)
        write(shared.appending(path: "other.txt"), bytes: 10)
        LegacyNoteFile.remove(shared.appending(path: "Voice note.wav"), roots: roots)
        #expect(FileManager.default.fileExists(atPath: shared.appending(path: "other.txt").path))
        // A file outside the app's folders is never deleted.
        let outside = container.appending(path: "keep.wav")
        write(outside, bytes: 10)
        LegacyNoteFile.remove(outside, roots: roots)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func aSavedNoteThatIsNotOneIsCleared() {
        let box = IntentsDefaults()
        #expect(VoiceBotCatalog.pendingNote(box.defaults) == nil)
        // What build 240 wrote.
        let literal = #"{"id":"N1","bot":{"id":"x","name":"Ivy","key":"ios-direct::ivy","account":"https:\/\/fixture.invalid\nqa"},"path":"\/a\/b.m4a"}"#
        box.defaults.set(Data(literal.utf8), forKey: VoiceBotCatalog.pendingKey)
        let note = VoiceBotCatalog.pendingNote(box.defaults)
        #expect(note?.id == "N1" && note?.bot.key == "ios-direct::ivy" && note?.path == "/a/b.m4a")
        for junk in [Data("not json".utf8), Data("[]".utf8), Data(#"{"id":"","bot":{"id":"x","name":"n","key":"k","account":"a"},"path":"/p"}"#.utf8),
                     Data(count: 70 * 1024)] {
            box.defaults.set(junk, forKey: VoiceBotCatalog.pendingKey)
            #expect(VoiceBotCatalog.pendingNote(box.defaults) == nil)
            #expect(box.defaults.object(forKey: VoiceBotCatalog.pendingKey) == nil)
        }
        box.defaults.set("text", forKey: VoiceBotCatalog.pendingKey)
        #expect(VoiceBotCatalog.pendingNote(box.defaults) == nil && box.defaults.object(forKey: VoiceBotCatalog.pendingKey) == nil)
    }
}

@Suite struct BadStoredValuesTests {
    // S15: each of the six keys holding something that is not ours reads as absent, and nothing crashes.
    @Test func everyKeySurvivesJunk() {
        let keys = [VoiceBotCatalog.botsKey, VoiceNoteRequestStore.storageKey, VoiceBotCatalog.pendingKey, ShortcutPolicy.catalogKey,
                    ShortcutPolicy.accountKey, ShortcutPolicy.epochKey]
        var random = SystemRandomNumberGenerator()
        let junk: [Any] = [Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &random) }), Data(#"{"shape":"wrong","n":[1,2,3]}"#.utf8),
                           Data(#"[{"id":1,"name":false}]"#.utf8), String(repeating: "z", count: 2 * 1024 * 1024),
                           Data(String(repeating: "z", count: 2 * 1024 * 1024).utf8), [Any](), Data("[]".utf8), 42, ["a": 1]]
        for value in junk {
            let box = IntentsDefaults()
            for key in keys { box.defaults.set(value, forKey: key) }
            #expect(VoiceBotCatalog.bots(box.defaults).isEmpty)
            #expect(VoiceNoteRequestStore(defaults: box.defaults).pending == nil)
            #expect(VoiceBotCatalog.pendingNote(box.defaults) == nil)
            #expect(ShortcutPolicy.targets(box.defaults).isEmpty)
            #expect(ShortcutPolicy.epoch(box.defaults) == nil)
            #expect(ShortcutPolicy.digest(box.defaults) == nil)
            #expect(ShortcutPolicy.legacyEntities(box.defaults).isEmpty)
            #expect(VoiceBotCatalog.resolve(id: "anything", box.defaults) == nil)
            #expect(!QuickActions.perform(action: "open", id: "x", epoch: nil, defaults: box.defaults))
            // The live lists rebuild what the pickers offer over the junk.
            let sync = IntentsCatalogSync(defaults: box.defaults, interval: 0, refresh: {})
            #expect(sync.sync(bots: [IntentsFixture.bot("ivy")], account: IntentsFixture.account, answered: true))
            #expect(VoiceBotCatalog.bots(box.defaults).map(\.name) == ["Ivy"])
            // And the account's activation replaces a digest and epoch that are not ones.
            ShortcutPolicy.activate(url: IntentsFixture.url, username: IntentsFixture.username, box.defaults)
            #expect(ShortcutPolicy.epoch(box.defaults).flatMap(UUID.init(uuidString:)) != nil)
        }
    }
}

@Suite struct ConversationDonationTests {
    // A44
    @Test func theDonationNamesTheChatAndCarriesNoText() throws {
        let interaction = try #require(PushFaces.donation(sender: "Ivy", handle: "ivy", face: nil, chat: "Trip plan", conversation: "20261003_101500_ab12cd"))
        #expect(interaction.direction == .incoming)
        let intent = try #require(interaction.intent as? INSendMessageIntent)
        #expect(intent.content == nil)
        #expect(intent.conversationIdentifier == "20261003_101500_ab12cd")
        #expect(intent.sender?.customIdentifier == "ivy" && intent.sender?.displayName == "Ivy")
        #expect(intent.speakableGroupName?.spokenPhrase == "Trip plan")
        #expect(PushFaces.donation(sender: "", handle: "ivy", face: nil, chat: "Trip plan", conversation: "abc") == nil)
        for bad in ["", "has space", "a/b", String(repeating: "a", count: 161), "semi;colon"] {
            #expect(PushFaces.donation(sender: "Ivy", handle: "ivy", face: nil, chat: "", conversation: bad) == nil, "\(bad.prefix(20))")
        }
        #expect(PushFaces.donation(sender: "Ivy", handle: "ivy", face: nil, chat: "", conversation: String(repeating: "a", count: 160)) != nil)
    }

    // A45, S21
    @Test func onlyAMessageConversationWithAnIdAnAlertMayNameComesBack() {
        func interaction(_ id: String?) -> INInteraction {
            INInteraction(intent: PushFaces.sendIntent(body: nil, sender: "Ivy", handle: "ivy", face: nil, chat: "", conversation: id ?? ""), response: nil)
        }
        #expect(IntentsRouting.conversation(interaction("20261003_101500_ab12cd")) == "20261003_101500_ab12cd")
        for bad in ["a/b", "has space", String(repeating: "a", count: 161), "", "new\nline"] {
            #expect(IntentsRouting.conversation(interaction(bad)) == nil, "\(bad.prefix(20))")
        }
        #expect(IntentsRouting.conversation(nil) == nil)
        let call = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown, destinationType: .unknown, contacts: nil,
                                     callCapability: .audioCall)
        #expect(IntentsRouting.conversation(INInteraction(intent: call, response: nil)) == nil)
    }
}

@Suite struct IntentsWordingTests {
    // A50
    @Test func nothingTheOwnerReadsSaysDispatch() {
        for app in ["Hermes HQ", "HQ Native", AppIdentity.current.displayName] {
            for sentence in IntentsText.table(app: app, bot: "Ivy") {
                #expect(!sentence.localizedCaseInsensitiveContains("dispatch"), "\(sentence)")
                #expect(!sentence.isEmpty)
            }
        }
        var shown = [String(localized: RecordVoiceNoteIntent.title), String(localized: DispatchMemoIntent.title), String(localized: DispatchOpenBotIntent.title),
                     String(localized: VoiceNoteBot.typeDisplayRepresentation.name), String(localized: DispatchBotEntity.typeDisplayRepresentation.name),
                     String(localized: VoiceNoteError.unavailableBot.localizedStringResource),
                     String(localized: DispatchShortcutError.unavailable.localizedStringResource),
                     VoiceNoteError.unavailableBot.errorDescription ?? "", DispatchShortcutError.unavailable.errorDescription ?? ""]
        shown += QuickActions.plan([ShortcutTarget(id: "e:bot:k", name: "Ivy", kind: "bot", botKey: "k")], enabled: true).map(\.title)
        for alert in [IntentsNoticeContent.voiceNote(IntentsText.finishCurrent), .savedNote(bot: "Ivy"), .recovery(IntentsText.noteNotSaved, retry: true),
                      .shortcut(nil), .shortcut(IntentsText.previousSignIn)] {
            shown += [alert.title, alert.message ?? ""] + alert.buttons.map(\.title)
        }
        for text in shown { #expect(!text.localizedCaseInsensitiveContains("dispatch"), "\(text)") }
        #expect(shown.contains("Record Voice Memo") && shown.contains("Send a Memo to Bot") && shown.contains("Open Bot"))
    }

    @Test func theWordsAreTheWebApps() {
        #expect(IntentsText.refreshBots(app: "Hermes HQ") == "Open Hermes HQ to refresh your bots, then choose a bot in this shortcut.")
        #expect(IntentsText.legacyUnavailable(app: "Hermes HQ") == "Open Hermes HQ and choose the bot again. This shortcut is no longer available.")
        #expect(IntentsText.botUnavailable("Ivy") == "“Ivy” is unavailable. Reconnect to the computer running Hermes and try again.")
        #expect(IntentsText.savedNoteWaiting("Ivy") == "Your memo for Ivy is waiting to be added to its chat.")
        #expect(IntentsText.chatGone(app: "Hermes HQ") == "That chat is no longer available. Open Hermes HQ and choose it again.")
        #expect(IntentsText.openAppFirst(app: "Hermes HQ") == "Open Hermes HQ to use this shortcut.")
        let saved = IntentsNoticeContent.savedNote(bot: "Ivy")
        #expect(saved.title == "Saved Voice Memo" && saved.buttons.map(\.title) == ["Open Chat", "Discard and Record", "Cancel"])
        #expect(saved.buttons.map(\.role) == [.preferred, .destructive, .cancel])
        let failed = IntentsNoticeContent.voiceNote(IntentsText.finishCurrent)
        #expect(failed.title == "Couldn’t Start the Voice Memo" && failed.buttons.map(\.title) == ["OK"])
        #expect(IntentsNoticeContent.recovery(IntentsText.noteNotSaved, retry: true).buttons.map(\.title) == ["Recover Recording", "Discard Recording", "Cancel"])   // "Discard Recording" is this build's own (DECISION F3)
        #expect(IntentsNoticeContent.recovery(IntentsText.noteOtherAccount, retry: false).buttons.map(\.title) == ["OK"])
        #expect(IntentsNoticeContent.shortcut(nil).title == "That shortcut is unavailable." && IntentsNoticeContent.shortcut("x").title == "Shortcut Unavailable")
    }
}
