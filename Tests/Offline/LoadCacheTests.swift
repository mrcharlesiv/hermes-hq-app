// [load-cache] What the launch keeps so it doesn't ask the gateway again: each bot's add-on list (PluginListCache and
// the add-on check), one shared `GET /api/config` (SharedConfigReads), the Capabilities page's saved answer
// (CapabilitiesWarmCache on disk), and a deleted chat's or bot's saved tails going with it (TranscriptCache).

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@MainActor @Suite("Load cache", .serialized) struct LoadCacheTests {
    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "load-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func plugin(_ name: String, _ version: String, enabled: Bool = true) -> PluginInfo {
        PluginInfo(name: name, key: nil, version: version, description: "", source: "catalog", enabled: enabled, hasDesktopHalf: false,
                   servers: [], updateAvailable: false, catalogVersion: nil, catalogSha: nil, schema: [])
    }

    private static func bot(_ id: String) -> Bot {
        Bot(id: id, name: id.capitalized, role: nil, preview: nil, lastActive: nil, isWorking: false, unread: false,
            pinned: false, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: nil, head: nil)
    }

    private static let account = GatewayAccount(id: "http://127.0.0.1:9811|cache", baseURL: URL(string: "http://127.0.0.1:9811")!,
                                                kind: .password, username: "cache", label: "load cache")

    // MARK: PluginListCache

    @Test func pluginListsAreKeptSixHoursAndOnDisk() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_000_000)
        let cache = PluginListCache(root: root, now: { now })
        #expect(cache.entry(account: Self.account, profile: "inbox") == nil)
        cache.store([Self.plugin(PushPolicy.pluginName, "0.9.18"), Self.plugin("kanban", "1.0", enabled: false)],
                    account: Self.account, profile: "inbox")
        let kept = try #require(cache.entry(account: Self.account, profile: "inbox"))
        #expect(kept.plugins == [.init(name: PushPolicy.pluginName, version: "0.9.18", enabled: true),
                                 .init(name: "kanban", version: "1.0", enabled: false)])
        #expect(cache.entry(account: Self.account, profile: "otto") == nil)

        // A relaunch reads the file.
        PagesCache.flush()
        let relaunch = PluginListCache(root: root, now: { now })
        #expect(relaunch.entry(account: Self.account, profile: "inbox") == kept)
        let other = GatewayAccount(id: "http://127.0.0.1:9812|cache", baseURL: URL(string: "http://127.0.0.1:9812")!,
                                   kind: .password, username: "cache", label: "other")
        #expect(relaunch.entry(account: other, profile: "inbox") == nil, "another gateway's lists are its own")

        // Just under six hours: kept. Six hours: asked again.
        now += PluginListCache.keep - 1
        #expect(relaunch.entry(account: Self.account, profile: "inbox") != nil)
        now += 1
        #expect(relaunch.entry(account: Self.account, profile: "inbox") == nil)

        // Read "in the future" (the clock went back): not trusted.
        now = Date(timeIntervalSince1970: 1_000_000 - 60)
        #expect(relaunch.entry(account: Self.account, profile: "inbox") == nil)
    }

    @Test func aChangedListIsForgottenOnDiskToo() {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PluginListCache(root: root)
        cache.store([Self.plugin(PushPolicy.pluginName, "0.9.18")], account: Self.account, profile: "inbox")
        cache.store([Self.plugin(PushPolicy.pluginName, "0.9.18")], account: Self.account, profile: "otto")
        cache.forget(account: Self.account, profile: "inbox")
        #expect(cache.entry(account: Self.account, profile: "inbox") == nil)
        PagesCache.flush()
        let relaunch = PluginListCache(root: root)
        #expect(relaunch.entry(account: Self.account, profile: "inbox") == nil)
        #expect(relaunch.entry(account: Self.account, profile: "otto") != nil)
        // Sign-out forgets memory (PagesCache.purge removes the file).
        relaunch.forget(account: Self.account)
        try? FileManager.default.removeItem(at: PagesCache.directory(for: Self.account, root: root))
        #expect(relaunch.entry(account: Self.account, profile: "otto") == nil)
    }

    @Test func keptListFollowsTheSameRuleAsAFreshOne() {
        func entry(_ plugins: [PluginInfo]) -> PluginListCache.Entry {
            .init(at: 0, plugins: plugins.map { .init(name: $0.name, version: $0.version, enabled: $0.enabled) })
        }
        for list in [[Self.plugin(PushPolicy.pluginName, PushPolicy.everyBotVersion)],
                     [Self.plugin(PushPolicy.pluginName, "0.9.1")],
                     [Self.plugin(PushPolicy.pluginName, PushPolicy.everyBotVersion, enabled: false)],
                     [Self.plugin("kanban", "9.9")], []] {
            #expect(PushPolicy.botHasPlugin(entry(list)) == PushPolicy.botHasPlugin(list))
        }
    }

    // MARK: The add-on check

    /// A gateway answering `plugins.manage list` per bot, counting how many are out at once.
    private nonisolated final class AddOnGateway: Sendable {
        private nonisolated final class Tally: Sendable {
            let state = Mutex((out: 0, most: 0, lists: [String: [JSONValue]](), failing: Set<String>()))
        }
        let client = FakeGatewayClient()
        private let tally = Tally()

        init(_ lists: [String: [JSONValue]], failing: Set<String> = []) {
            tally.state.withLock { $0.lists = lists; $0.failing = failing }
            client.onCall { [tally] method, params in
                guard method == "plugins.manage", params["action"]?.string == "list", let profile = params["profile"]?.string else {
                    return .object(["ok": true])
                }
                let failing = tally.state.withLock { s -> Bool in s.out += 1; s.most = max(s.most, s.out); return s.failing.contains(profile) }
                try? await Task.sleep(for: .milliseconds(20))
                let rows = tally.state.withLock { s -> [JSONValue] in s.out -= 1; return s.lists[profile] ?? [] }
                if failing { throw URLError(.timedOut) }
                return .object(["plugins": .array(rows)])
            }
        }

        var most: Int { tally.state.withLock { $0.most } }
        var asked: [String] { client.calls("plugins.manage").compactMap { $0.params["profile"]?.string }.sorted() }
    }

    private static func row(_ version: String, enabled: Bool = true) -> JSONValue {
        .object(["name": .string(PushPolicy.pluginName), "version": .string(version), "status": .string(enabled ? "enabled" : "disabled")])
    }

    @Test func launchCheckSkipsBotsKnownToHaveTheAddOn() async {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = PushPolicy.everyBotVersion
        let gateway = AddOnGateway(["a": [Self.row(current)], "b": [], "c": [Self.row("0.1.0")], "d": [Self.row(current)],
                                    "e": [Self.row(current, enabled: false)]])
        let store = CapabilitiesStore(client: gateway.client)
        store.pluginLists = PluginListCache(root: root)
        let bots = ["default", "a", "b", "c", "d", "e"].map(Self.bot)

        // First launch: every bot but the main one is asked, two at a time.
        let first = await PushSetupOffer.botsWithout(store: store, bots: bots, fresh: false)
        #expect(first.map(\.id) == ["b", "c", "e"])
        #expect(gateway.asked == ["a", "b", "c", "d", "e"])
        #expect(gateway.most <= PushSetupOffer.listReadWidth)

        // Next launch: the bots that had it are taken as read; the ones without it are asked again (the main bot may
        // have installed it from its terminal since).
        let second = await PushSetupOffer.botsWithout(store: store, bots: bots, fresh: false)
        #expect(second.map(\.id) == ["b", "c", "e"])
        #expect(gateway.asked == ["a", "b", "b", "c", "c", "d", "e", "e"])

        // From Settings: every bot is asked.
        _ = await PushSetupOffer.botsWithout(store: store, bots: bots, fresh: true)
        #expect(gateway.client.calls("plugins.manage").count == 13)
    }

    @Test func aBotWhoseListFailsIsNotCountedOrKept() async {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = AddOnGateway(["a": [], "b": []], failing: ["b"])
        let store = CapabilitiesStore(client: gateway.client)
        store.pluginLists = PluginListCache(root: root)
        let without = await PushSetupOffer.botsWithout(store: store, bots: ["default", "a", "b"].map(Self.bot), fresh: false)
        #expect(without.map(\.id) == ["a"], "no offer on a guess")
        #expect(store.pluginLists.entry(account: gateway.client.account, profile: "b") == nil)
        #expect(store.pluginLists.entry(account: gateway.client.account, profile: "a") != nil)
    }

    @Test func anAddOnActionForgetsThatBotsList() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = AddOnGateway(["a": [Self.row(PushPolicy.everyBotVersion)], "b": [Self.row(PushPolicy.everyBotVersion)]])
        let store = CapabilitiesStore(client: gateway.client)
        store.pluginLists = PluginListCache(root: root)
        _ = try await store.plugins("a")
        _ = try await store.plugins("b")
        _ = try? await store.plugin(.toggle(key: PushPolicy.pluginName, enable: false), profile: "a")
        #expect(store.pluginLists.entry(account: gateway.client.account, profile: "a") == nil)
        #expect(store.pluginLists.entry(account: gateway.client.account, profile: "b") != nil)
    }

    // MARK: SharedConfigReads

    /// A read that waits until let go.
    private actor Gate {
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() { open = true; waiting.forEach { $0.resume() }; waiting = [] }
    }

    /// Reads made so far, shared with the read closures.
    private nonisolated final class Counter: Sendable {
        private let n = Mutex(0)
        func next() -> Int { n.withLock { $0 += 1; return $0 } }
        var value: Int { n.withLock { $0 } }
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func readersJoinOneReadAndReuseItBriefly() async throws {
        let reads = SharedConfigReads(), gate = Gate()
        let count = Counter()
        let read: @Sendable () async throws -> Data = {
            let n = count.next()
            await gate.wait()
            return Data("config \(n)".utf8)
        }
        async let one = reads.data([], read: read)
        async let two = reads.data([], read: read)
        async let three = reads.data([], maxAge: 0, read: read)         // joins too: only a kept answer is refused
        await Self.waitUntil { count.value > 0 }
        try await Task.sleep(for: .milliseconds(20))
        await gate.release()
        let answers = try await [one, two, three]
        #expect(Set(answers) == [Data("config 1".utf8)])
        #expect(reads.readsStarted == 1)

        // Kept for the next reader within its age; a reader who wants it fresh reads again.
        #expect(try await reads.data([], read: read) == Data("config 1".utf8))
        #expect(reads.readsStarted == 1)
        #expect(try await reads.data([], maxAge: 0, read: read) == Data("config 2".utf8))
        #expect(reads.readsStarted == 2)

        // Another query is its own read.
        #expect(try await reads.data([URLQueryItem(name: "profile", value: "inbox")], read: read) == Data("config 3".utf8))
        #expect(reads.readsStarted == 3)
    }

    @Test func aKeptAnswerExpires() async throws {
        let reads = SharedConfigReads()
        let count = Counter()
        let read: @Sendable () async throws -> Data = { Data("\(count.next())".utf8) }
        _ = try await reads.data([], maxAge: 0.05, read: read)
        _ = try await reads.data([], maxAge: 0.05, read: read)
        #expect(reads.readsStarted == 1)
        try await Task.sleep(for: .milliseconds(80))
        _ = try await reads.data([], maxAge: 0.05, read: read)
        #expect(reads.readsStarted == 2)
    }

    @Test func aWriteDropsWhatIsKeptAndWhatIsInFlight() async throws {
        let reads = SharedConfigReads(), gate = Gate()
        let count = Counter()
        let read: @Sendable () async throws -> Data = {
            let n = count.next()
            if n == 1 { await gate.wait() }
            return Data("config \(n)".utf8)
        }
        // A read is out when the write is made: its caller still gets it, but nobody after the write does.
        async let before = reads.data([], read: read)
        await Self.waitUntil { count.value == 1 }
        reads.invalidate()
        #expect(try await reads.data([], read: read) == Data("config 2".utf8), "a reader after the write doesn't join the old read")
        await gate.release()
        #expect(try await before == Data("config 1".utf8))
        #expect(try await reads.data([], read: read) == Data("config 2".utf8), "the old read's late answer isn't kept over the new one")

        reads.invalidate()
        #expect(try await reads.data([], read: read) == Data("config 3".utf8))
        #expect(SharedConfigReads.writes(rpc: "config.set"))
        #expect(!SharedConfigReads.writes(rpc: "session.resume"))
    }

    @Test func aFailedReadIsNotKept() async throws {
        let reads = SharedConfigReads()
        let count = Counter()
        let read: @Sendable () async throws -> Data = {
            if count.next() == 1 { throw URLError(.timedOut) }
            return Data("ok".utf8)
        }
        await #expect(throws: URLError.self) { try await reads.data([], read: read) }
        #expect(try await reads.data([], read: read) == Data("ok".utf8))
        #expect(reads.readsStarted == 2)
    }

    @Test func theClientsDefaultReadsDirectly() async throws {
        let client = FakeGatewayClient()
        client.onRest { _, _ in Data("{\"display\":{}}".utf8) }
        _ = try await client.configData([])
        _ = try await client.configData([])
        #expect(client.restLog.filter { $0.path == "/api/config" }.count == 2, "fakes and stand-ins keep reading every time")
    }

    // MARK: Capabilities on disk

    @Test func capabilitiesAnswerIsSavedForTheNextLaunch() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 2_000_000)
        let skill = SkillInfo(name: "garden-notes", description: "Keeps the planting calendar.", category: nil, enabled: true, usage: 0, provenance: nil)
        CapabilitiesWarmCache(root: root, now: { now }).store(skills: [skill], official: [], account: "acct", profile: "inbox")
        PagesCache.flush()

        let relaunch = CapabilitiesWarmCache(root: root, now: { now })
        #expect(relaunch.entry(account: "acct", profile: "inbox")?.skills.map(\.name) == ["garden-notes"])
        #expect(relaunch.entry(account: "acct", profile: "otto") == nil)
        #expect(CapabilitiesWarmCache(root: root, now: { now }).entry(account: "other", profile: "inbox") == nil)

        // Past 30 minutes: the warm-up reads again, but the page still paints it while it does, for a week.
        now += CapabilitiesWarmCache.keep + 1
        #expect(relaunch.entry(account: "acct", profile: "inbox") == nil)
        #expect(relaunch.seed(account: "acct", profile: "inbox") != nil)
        now += CapabilitiesWarmCache.seedFor
        #expect(relaunch.seed(account: "acct", profile: "inbox") == nil)
        now = Date(timeIntervalSince1970: 2_000_000 - 60)
        #expect(relaunch.seed(account: "acct", profile: "inbox") == nil, "an answer from ahead of the clock isn't trusted")
    }

    @Test func theWarmUpReadsTheFileAheadOfAsking() async {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = SkillInfo(name: "garden-notes", description: "", category: nil, enabled: true, usage: 0, provenance: nil)
        CapabilitiesWarmCache(root: root).store(skills: [skill], official: nil, account: "acct", profile: "inbox")
        PagesCache.flush()
        let relaunch = CapabilitiesWarmCache(root: root)
        await relaunch.preload(account: "acct", profile: "inbox")
        await relaunch.preload(account: "acct", profile: "otto")
        try? FileManager.default.removeItem(at: root)
        #expect(relaunch.entry(account: "acct", profile: "inbox")?.skills.map(\.name) == ["garden-notes"], "read into memory")
        #expect(relaunch.entry(account: "acct", profile: "otto") == nil)
        relaunch.forget(account: "acct")
        #expect(relaunch.seed(account: "acct", profile: "inbox") == nil)
    }

    @Test func aHugeCapabilitiesAnswerIsNotSaved() {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = SkillInfo(name: "big", description: String(repeating: "x", count: CapabilitiesWarmCache.fileLimit), category: nil,
                            enabled: true, usage: 0, provenance: nil)
        let cache = CapabilitiesWarmCache(root: root)
        cache.store(skills: [big], official: nil, account: "acct", profile: "inbox")
        #expect(cache.entry(account: "acct", profile: "inbox") != nil, "this run still has it")
        PagesCache.flush()
        #expect(CapabilitiesWarmCache(root: root).seed(account: "acct", profile: "inbox") == nil)
    }

    // MARK: Deleted chats and bots

    private static func messages(_ text: String) -> [ChatMessage] {
        [ChatMessage(id: "u", role: .user, parts: [.text(text)], timestamp: Date(timeIntervalSince1970: 100), rowId: 1),
         ChatMessage(id: "a", role: .assistant, parts: [.text("ok")], timestamp: Date(timeIntervalSince1970: 101), rowId: 2)]
    }

    private static func files(_ root: URL) -> [String] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "hqt" }.map(\.lastPathComponent).sorted()
    }

    @Test func aDeletedChatsTailGoesAndStaysGone() {
        let cache = makeTempCache()
        defer { try? FileManager.default.removeItem(at: cache.root) }
        cache.save(Self.messages("hi"), meta: [:], account: "acct", profile: "inbox", storedId: "s1")
        cache.save(Self.messages("hi"), meta: [:], account: "acct", profile: "inbox", storedId: "s2")
        cache.flush()
        #expect(Self.files(cache.root) == ["s1.hqt", "s2.hqt"])

        cache.removeEverywhere(account: "acct", storedId: "s1")
        // The chat deleted from its own screen saves as it closes: nothing comes back.
        cache.save(Self.messages("closing"), meta: [:], account: "acct", profile: "inbox", storedId: "s1")
        cache.flush()
        #expect(cache.load(account: "acct", profile: "inbox", storedId: "s1") == nil)
        #expect(Self.files(cache.root) == ["s2.hqt"])
        #expect(TranscriptCache(root: cache.root).load(account: "acct", profile: "inbox", storedId: "s1") == nil)
        // Another account's chat with the same id is its own.
        cache.save(Self.messages("hi"), meta: [:], account: "acct-2", profile: "inbox", storedId: "s1")
        #expect(cache.load(account: "acct-2", profile: "inbox", storedId: "s1") != nil)
    }

    @Test func aWriteUnderWayWhenTheChatIsDeletedDoesNotLand() {
        // Writes wait 100 ms; a delete in between drops the pending one.
        let cache = makeTempCache()
        defer { try? FileManager.default.removeItem(at: cache.root) }
        cache.save(Self.messages("hi"), meta: [:], account: "acct", profile: "inbox", storedId: "s1")
        cache.removeEverywhere(account: "acct", storedId: "s1")
        cache.flush()
        #expect(Self.files(cache.root).isEmpty)
        #expect(cache.diskBytes == 0)
    }

    @Test func aDeletedBotsTailsGoButItsNameCanComeBack() {
        let cache = makeTempCache()
        defer { try? FileManager.default.removeItem(at: cache.root) }
        cache.save(Self.messages("hi"), meta: [:], account: "acct", profile: "inbox", storedId: "s1")
        cache.save(Self.messages("hi"), meta: [:], account: "acct", profile: "inbox", storedId: "s2")
        cache.save(Self.messages("hi"), meta: [:], account: "acct", profile: "otto", storedId: "s3")
        cache.flush()
        cache.removeProfile(account: "acct", profile: "inbox")
        cache.flush()
        #expect(Self.files(cache.root) == ["s3.hqt"])
        #expect(cache.load(account: "acct", profile: "inbox", storedId: "s1") == nil)
        #expect(cache.load(account: "acct", profile: "otto", storedId: "s3") != nil)
        // A new bot with the same name saves as usual.
        cache.save(Self.messages("new"), meta: [:], account: "acct", profile: "inbox", storedId: "s9")
        cache.flush()
        #expect(Self.files(cache.root) == ["s3.hqt", "s9.hqt"])
    }
}
