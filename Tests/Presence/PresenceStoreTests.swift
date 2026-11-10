// [presence] Unit tests for the store side (docs/spec/3x-presence.md §13, 6–8): the per-bot "Alert When It Uses Its
// Computer" flag (`screenAutoOpen` in ui_meta["hermes-bots"]) and the presence map on the roster.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
private func makeStore(_ gateway: MetaGateway) async -> BotStore {
    let store = BotStore(client: gateway.client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast)
    await BotsTest.waitUntil { store.phase == .full }
    return store
}

@MainActor @Suite(.serialized) struct PresenceStoreTests {
    // MARK: 6. Reading the flag

    @Test func noticeIsOnUnlessTheFlagIsExactlyFalse() async {
        let gateway = MetaGateway([
            "absent": ["display_name": "Absent"],
            "yes": ["screenAutoOpen": true],
            "nothing": ["screenAutoOpen": .null],
            "words": ["screenAutoOpen": "false"],
            "zero": ["screenAutoOpen": 0],
            "no": ["screenAutoOpen": false],
        ])
        let store = await makeStore(gateway)
        for name in ["absent", "yes", "nothing", "words", "zero"] { #expect(store.screenNoticeOn(name), "\(name)") }
        #expect(!store.screenNoticeOn("no"))
        #expect(store.screenNoticeOn("not-a-bot"))                 // nothing stored: the default
        // Reading the default writes nothing.
        #expect(gateway.client.calls("profiles.configure").isEmpty)
    }

    // MARK: 7. Writing the flag

    @Test func turningItOffWritesTheWholeObjectPlusTheFlag() async throws {
        let gateway = MetaGateway(["ivy": ["display_name": "Ivy", "pinned": true, "created": 1790000000001], "default": [:]])
        let store = await makeStore(gateway)
        try await store.setScreenNotice(name: "ivy", false)
        let configure = gateway.client.calls("profiles.configure")
        #expect(configure.count == 1)
        #expect(configure[0].params == ["name": "ivy", "ui_meta": ["hermes-bots": [
            "display_name": "Ivy", "pinned": true, "created": 1790000000001, "screenAutoOpen": false]]])
        // The fresh read went first (read, merge, write).
        let order = gateway.client.calls.map(\.method).filter { $0 == "profiles.list" || $0 == "profiles.configure" }
        #expect(order.suffix(2) == ["profiles.list", "profiles.configure"])
        #expect(gateway.client.calls("profiles.list").last?.params == ["include_sessions": false])
        #expect(!store.screenNoticeOn("ivy"))
        #expect(store.screenNoticeOn("default"))                    // the other bot is untouched
        #expect(gateway.withLock { gateway.meta["default"]?["hermes-bots"]?["screenAutoOpen"] } == nil)

        // Already off: nothing is sent.
        try await store.setScreenNotice(name: "ivy", false)
        #expect(gateway.client.calls("profiles.configure").count == 1)

        // On again: an explicit true.
        try await store.setScreenNotice(name: "ivy", true)
        #expect(gateway.client.calls("profiles.configure").count == 2)
        #expect(gateway.client.calls("profiles.configure")[1].params["ui_meta"]?["hermes-bots"]?["screenAutoOpen"] == true)
        #expect(store.screenNoticeOn("ivy"))
        // Already on: nothing is sent.
        try await store.setScreenNotice(name: "ivy", true)
        #expect(gateway.client.calls("profiles.configure").count == 2)
    }

    /// The default (no stored flag) is on, so turning it "on" writes nothing: the Mac's opt-in stays as it was.
    @Test func turningOnWhatIsOnByDefaultWritesNothing() async throws {
        let gateway = MetaGateway(["ivy": ["display_name": "Ivy"]])
        let store = await makeStore(gateway)
        try await store.setScreenNotice(name: "ivy", true)
        #expect(gateway.client.calls("profiles.configure").isEmpty)
        #expect(gateway.withLock { gateway.meta["ivy"]?["hermes-bots"]?["screenAutoOpen"] } == nil)
    }

    /// Refused: the switch's value goes back here at once, and the best-effort undo puts back what was stored (no value
    /// when there was none), never an explicit true the Mac would read as its opt-in (DECISION D18).
    @Test func aRefusedFlipGoesBackAndTheUndoRestoresWhatWasStored() async throws {
        let gateway = MetaGateway(["ivy": ["display_name": "Ivy"]])
        let store = await makeStore(gateway)
        gateway.withLock { gateway.scripted = [{ ["ok": false, "applied": ["ui_meta": false]] }] }
        do {
            try await store.setScreenNotice(name: "ivy", false)
            Issue.record("should fail")
        } catch let error as BotWriteError {
            #expect(error.title == "Couldn’t Change the Alert" && error.reason == BotWriteError.notSavedReason)
        }
        #expect(store.screenNoticeOn("ivy"))
        #expect(await BotsTest.waitUntil { gateway.client.calls("profiles.configure").count == 2 })
        let undo = gateway.client.calls("profiles.configure")[1].params["ui_meta"]?["hermes-bots"]
        #expect(undo?["screenAutoOpen"] == .null && undo?["display_name"] == "Ivy")
        #expect(await BotsTest.waitUntil { store.editing.inFlight.isEmpty })
        #expect(store.screenNoticeOn("ivy"))
    }

    @Test func anOlderGatewayAndAReadOnlyBuildSayTheirWords() async throws {
        let gateway = MetaGateway(["ivy": ["screenAutoOpen": false]])
        let store = await makeStore(gateway)
        gateway.withLock { gateway.scripted = [{ ["ok": true] }] }
        do {
            try await store.setScreenNotice(name: "ivy", true)
            Issue.record("should fail")
        } catch let error as BotWriteError {
            #expect(error.reason == BotWriteError.unsupportedReason)
        }
        #expect(!store.screenNoticeOn("ivy"))
        // The undo puts the stored false back.
        #expect(await BotsTest.waitUntil { gateway.client.calls("profiles.configure").count == 2 })
        #expect(gateway.client.calls("profiles.configure")[1].params["ui_meta"]?["hermes-bots"]?["screenAutoOpen"] == false)
        #expect(await BotsTest.waitUntil { store.editing.inFlight.isEmpty })

        store.readOnlyGateway = true
        let before = gateway.client.calls.count
        do {
            try await store.setScreenNotice(name: "ivy", true)
            Issue.record("should fail")
        } catch let error as BotWriteError {
            #expect(error.reason == BotWriteError.readOnlyReason)
        }
        #expect(gateway.client.calls.count == before)
    }

    /// Quick flips land in order and the last one wins (S4).
    @Test func quickFlipsLandInOrder() async throws {
        let gateway = MetaGateway(["ivy": [:]])
        let store = await makeStore(gateway)
        var flips: [Task<Void, Error>] = []
        for i in 0..<8 {
            let on = i % 2 == 1
            flips.append(Task { try await store.setScreenNotice(name: "ivy", on) })
        }
        for flip in flips { try await flip.value }
        let sent = gateway.client.calls("profiles.configure").compactMap { $0.params["ui_meta"]?["hermes-bots"]?["screenAutoOpen"]?.bool }
        #expect(sent == [false, true, false, true, false, true, false, true])
        #expect(store.screenNoticeOn("ivy"))
        #expect(gateway.withLock { gateway.meta["ivy"]?["hermes-bots"]?["screenAutoOpen"] } == true)
    }

    // MARK: 8. The presence map

    @Test func setPresenceRebuildsOnlyWhenTheMapChanges() async {
        let gateway = MetaGateway(["ivy": ["display_name": "Ivy"], "default": [:]])
        let store = await makeStore(gateway)
        var changes = 0
        store.onChange = { changes += 1 }
        let before = store.presenceRebuilds
        store.setPresence(["ivy": BotPresence(browserLine: "Browsing example.test")])
        #expect(changes == 1 && store.presenceRebuilds == before + 1)
        #expect(store.bot(named: "ivy")?.presence?.browserLine == "Browsing example.test")
        #expect(store.bot(named: "default")?.presence == nil)
        // The same map again: no rebuild, no change callback.
        store.setPresence(["ivy": BotPresence(browserLine: "Browsing example.test")])
        #expect(changes == 1 && store.presenceRebuilds == before + 1)
        // Empty entries count as absent.
        store.setPresence(["ivy": BotPresence(browserLine: "Browsing example.test"), "default": BotPresence()])
        #expect(changes == 1 && store.presenceRebuilds == before + 1)
        store.setPresence(["ivy": BotPresence(usingComputer: true)])
        #expect(changes == 2 && store.bot(named: "ivy")?.presence == BotPresence(usingComputer: true))
        store.setPresence([:])
        #expect(changes == 3 && store.bot(named: "ivy")?.presence == nil)
        store.setPresence([:])
        #expect(changes == 3)
    }
}
