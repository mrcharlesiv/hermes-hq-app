// [sync] 13-1: signing out and back in to the same gateway used to write the fresh, empty Sessions and Bots arrangement
// over every device's (the colours, favourite projects, orders and sort choices). The bookkeeping of what this device
// last synced outlived the lists it was about, so the empty store looked like a change made here.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
struct GatewaySyncSignOutTests {
    /// A document whose local copy a sign-out deletes (as the Sessions and Bots lists' device state).
    @MainActor final class ListDocument: GatewaySynced {
        let syncName = "lists"
        var value: JSONValue
        var syncStartedEmpty = false
        init(_ value: JSONValue) { self.value = value }
        func syncValue() -> JSONValue { value }
        func adoptSynced(_ value: JSONValue, merge: GatewaySyncMerge, base: JSONValue?) {
            if merge != .rebase { self.value = value }
        }
    }

    private static let arranged: JSONValue = ["order": ["b", "a"], "colors": ["s1": 3]]
    private static let empty: JSONValue = ["order": [], "colors": [:]]

    private func makeSync(_ server: SyncFakeServer, defaults: UserDefaults, dir: URL, accountId: String = "http://gw|me") -> GatewaySync {
        let client = FakeGatewayClient()
        client.onCall { method, params in server.handle(method, params) }
        let sync = GatewaySync(client: client, accountId: accountId, deviceName: "iPhone", defaults: defaults, knownDirectory: dir,
                               defaultRow: { RosterProfile(json: server.row) })
        sync.debounceNanoseconds = 1_000_000_000_000   // nothing goes by itself: the tests flush
        return sync
    }

    private func round(_ sync: GatewaySync) async {
        sync.pulled()
        await sync.flushNow()
        sync.pulled()
    }

    /// Signed in, arranged, synced: what a sign-out then leaves behind.
    private func signedInAndSynced(_ server: SyncFakeServer, defaults: UserDefaults, dir: URL) async {
        let document = ListDocument(Self.empty)
        let sync = makeSync(server, defaults: defaults, dir: dir)
        sync.register(document)
        document.value = Self.arranged
        sync.changed("lists")
        await round(sync)
        #expect(server.value("hermes-hq-sync.lists")?["data"] == Self.arranged)
        sync.shutdown()
    }

    @Test func signingOutForgetsWhatWasSyncedSoTheNextSignInTakesTheGatewaysCopy() async {
        let server = SyncFakeServer()
        let defaults = UserDefaults(suiteName: "hq.sync.test.signout.\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory.appending(path: "sync-test-\(UUID().uuidString)")
        await signedInAndSynced(server, defaults: defaults, dir: dir)
        // Sign Out: the list's state is deleted, and with it what this device knew of syncing it.
        GatewaySync.forget(accountId: "http://gw|me", documents: ["lists"], defaults: defaults, knownDirectory: dir)
        // Signed in again: the store starts empty.
        let document = ListDocument(Self.empty)
        let sync = makeSync(server, defaults: defaults, dir: dir)
        sync.register(document)
        await round(sync)
        #expect(server.value("hermes-hq-sync.lists")?["data"] == Self.arranged, "the other devices keep their arrangement")
        #expect(document.value == Self.arranged, "and this one takes it")
        #expect(server.writes == 1, "nothing was written over it")
    }

    // A sign-out on a build that kept the bookkeeping: the store itself says it started with nothing.
    @Test func aStoreThatStartedEmptyTakesTheGatewaysCopyEvenWithOldBookkeeping() async {
        let server = SyncFakeServer()
        let defaults = UserDefaults(suiteName: "hq.sync.test.empty.\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory.appending(path: "sync-test-\(UUID().uuidString)")
        await signedInAndSynced(server, defaults: defaults, dir: dir)
        let document = ListDocument(Self.empty)
        document.syncStartedEmpty = true
        let sync = makeSync(server, defaults: defaults, dir: dir)
        sync.register(document)
        await round(sync)
        #expect(server.value("hermes-hq-sync.lists")?["data"] == Self.arranged)
        #expect(document.value == Self.arranged)
        #expect(server.writes == 1)
    }

    @Test func forgettingOneDocumentKeepsTheOthersAndOtherAccounts() async {
        let server = SyncFakeServer()
        let defaults = UserDefaults(suiteName: "hq.sync.test.forget.\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory.appending(path: "sync-test-\(UUID().uuidString)")
        let pins = ArtifactPins(fileURL: nil)
        let list = ListDocument(Self.arranged)
        let sync = makeSync(server, defaults: defaults, dir: dir)
        pins.syncChanged = { [weak sync] in sync?.changed("pins") }
        sync.register(pins); sync.register(list)
        await round(sync)
        sync.shutdown()
        let writes = server.writes
        GatewaySync.forget(accountId: "http://gw|me", documents: ["lists"], defaults: defaults, knownDirectory: dir)
        GatewaySync.forget(accountId: "http://other|me", documents: ["pins", "lists"], defaults: defaults, knownDirectory: dir)
        // The pins (kept on the device through a sign-out) are still known as synced: no write on the next sign-in.
        let again = makeSync(server, defaults: defaults, dir: dir)
        again.register(pins); again.register(ListDocument(Self.arranged))
        await round(again)
        #expect(server.writes == writes, "the pins' copy is the gateway's, the list takes the gateway's equal copy")
    }

    // The real Sessions list: a fresh store (nothing on disk) says so.
    @Test func sessionsAndBotsStoresSayWhenTheyStartedEmpty() {
        let dir = BotsTest.tempDirectory()
        let sessions = SessionStore(client: BotsFakeGatewayClient(), account: .botsTestAccount, cacheDirectory: dir, timing: .fast, autoStart: false)
        let bots = BotStore(client: BotsFakeGatewayClient(), account: .botsTestAccount, cacheDirectory: dir, timing: .fast, autoStart: false)
        #expect(sessions.syncStartedEmpty)
        #expect(bots.syncStartedEmpty)
        sessions.device.colors["s1"] = 3
        sessions.persistState()
        bots.persistState()
        RosterDiskWriter.shared.flush()
        let sessionsAgain = SessionStore(client: BotsFakeGatewayClient(), account: .botsTestAccount, cacheDirectory: dir, timing: .fast, autoStart: false)
        let botsAgain = BotStore(client: BotsFakeGatewayClient(), account: .botsTestAccount, cacheDirectory: dir, timing: .fast, autoStart: false)
        #expect(!sessionsAgain.syncStartedEmpty)
        #expect(!botsAgain.syncStartedEmpty)
    }
}
