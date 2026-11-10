// [sync] Two devices on one gateway (owner 2026-11-03: tiles pinned on the iPhone weren't on the Mac): pins, removed
// artifacts and settings written by one are taken by the other, both devices' changes survive a race, and a
// compare-and-swap conflict is read again and written once more.

import Foundation
import Testing
@testable import HermesHQNative

/// The default bot's `ui_meta` with per-key revisions, as `profiles.list` / `profiles.configure` keep it.
nonisolated final class SyncFakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var meta: [String: JSONValue] = [:]
    private var revisions: [String: Int] = [:]
    /// Runs once just before the next write is applied (another device writing in between).
    var beforeNextWrite: (@Sendable () -> Void)?
    private(set) var writes = 0

    var row: JSONValue {
        lock.withLock {
            ["name": "default", "is_default": true, "ui_meta": .object(meta),
             "ui_meta_revisions": .object(revisions.mapValues { .number(Double($0)) })]
        }
    }

    func value(_ key: String) -> JSONValue? { lock.withLock { meta[key] } }

    /// Another device's write, straight to the store.
    func put(_ key: String, _ value: JSONValue) {
        lock.withLock { meta[key] = value; revisions[key, default: 0] += 1 }
    }

    func handle(_ method: String, _ params: JSONValue) -> JSONValue {
        switch method {
        case "profiles.list": return ["profiles": [row]]
        case "profiles.configure":
            if let hook = lock.withLock({ () -> (@Sendable () -> Void)? in let h = beforeNextWrite; beforeNextWrite = nil; return h }) { hook() }
            return lock.withLock {
                let incoming = params["ui_meta"]?.object ?? [:]
                if let expected = params["ui_meta_expected_revisions"]?.object {
                    for key in incoming.keys where expected[key]?.int != revisions[key, default: 0] {
                        return ["applied": ["ui_meta": false, "ui_meta_conflicts": [key: true]]]
                    }
                }
                var applied: [String: JSONValue] = [:]
                for (key, value) in incoming {
                    meta[key] = value
                    revisions[key, default: 0] += 1
                    applied[key] = .number(Double(revisions[key]!))
                }
                writes += 1
                return ["applied": ["ui_meta": true, "ui_meta_revisions": .object(applied)]]
            }
        default: return .object([:])
        }
    }
}

@MainActor
struct GatewaySyncTests {
    /// One device: its own disk state, its own documents, the shared server.
    @MainActor final class Device {
        let sync: GatewaySync
        let pins = ArtifactPins(fileURL: nil)
        let hidden = ArtifactHidden(fileURL: nil)
        let defaults: UserDefaults
        let settings: SettingsSync
        let library: SettingsSync
        let accountId: String
        var clock: Double = 1_000_000

        init(_ name: String, server: SyncFakeServer, accountId: String = "http://gw|me") {
            self.accountId = accountId
            let suite = "hq.sync.test.\(name).\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            let client = FakeGatewayClient()
            client.onCall { method, params in server.handle(method, params) }
            let dir = FileManager.default.temporaryDirectory.appending(path: "sync-test-\(UUID().uuidString)")
            sync = GatewaySync(client: client, accountId: accountId, deviceName: name, defaults: defaults, knownDirectory: dir,
                               defaultRow: { RosterProfile(json: server.row) })
            sync.debounceNanoseconds = 1_000_000_000_000   // nothing goes by itself: the tests flush
            sync.backoffUnit = 0.001
            settings = SettingsSync(library: false, accountId: accountId, defaults: defaults)
            library = SettingsSync(library: true, accountId: accountId, defaults: defaults)
            let clockRead: () -> Double = { [unowned self] in self.clock }
            sync.now = clockRead
            settings.now = clockRead
            library.now = clockRead
            pins.syncChanged = { [weak sync] in sync?.changed("pins") }
            hidden.syncChanged = { [weak sync] in sync?.changed("hidden") }
            settings.syncChanged = { [weak sync, settings] in sync?.changed(settings.syncName) }
            library.syncChanged = { [weak sync, library] in sync?.changed(library.syncName) }
        }

        func start() {
            for document in [pins, hidden, settings, library] as [GatewaySynced] { sync.register(document) }
        }

        func round() async {
            sync.pulled()
            await sync.flushNow()
            sync.pulled()
        }

        func pin(_ value: String, profile: String = "default") {
            pins.pin(ArtifactPin(kind: .file, value: value, label: "", profile: profile, sessionId: "s", sessionTitle: "Chat"))
        }

        var pinned: [String] { pins.pins.map(\.value) }
    }

    @Test func aTilePinnedOnThePhoneIsOnTheMac() async {
        let server = SyncFakeServer()
        let phone = Device("iPhone", server: server), mac = Device("Mac", server: server)
        phone.start(); mac.start()
        await phone.round(); await mac.round()
        phone.pin("/home/h/dashboard.html")
        phone.pins.setSize(.large, id: phone.pins.pins[0].id)
        await phone.round()
        await mac.round()
        #expect(mac.pinned == ["/home/h/dashboard.html"])
        #expect(mac.pins.pins.first?.tileSize == .large)
        mac.pins.unpin(id: mac.pins.pins[0].id)
        await mac.round()
        await phone.round()
        #expect(phone.pinned.isEmpty, "unpinned on the Mac is unpinned on the phone")
    }

    @Test func tilesPagesTravelButTheShownPageIsEachDevicesOwn() async {
        let server = SyncFakeServer()
        let phone = Device("iPhone", server: server), mac = Device("Mac", server: server)
        phone.start(); mac.start()
        await phone.round(); await mac.round()
        let page = phone.pins.addPage(named: "Health")
        phone.pin("/x/meals.html")
        await phone.round(); await mac.round()
        #expect(mac.pins.pages.map(\.name) == ["Main", "Health"])
        #expect(mac.pins.pins.first?.page == page.id)
        #expect(mac.pins.currentPage == DashboardPage.mainId, "the Mac stays on the page it shows")
    }

    @Test func pinsMadeOnBothBeforeTheyMetAreJoined() async {
        let server = SyncFakeServer()
        let phone = Device("iPhone", server: server), mac = Device("Mac", server: server)
        phone.pin("/x/a.html"); mac.pin("/x/b.html")
        phone.start(); mac.start()
        await phone.round()
        await mac.round()
        await phone.round()
        #expect(Set(phone.pinned) == ["/x/a.html", "/x/b.html"])
        #expect(Set(mac.pinned) == ["/x/a.html", "/x/b.html"])
    }

    @Test func bothDevicesChangingAtOnceKeepsBothChanges() async {
        let server = SyncFakeServer()
        let phone = Device("iPhone", server: server), mac = Device("Mac", server: server)
        phone.start(); mac.start()
        phone.pin("/x/old.html")
        await phone.round(); await mac.round()
        #expect(mac.pinned == ["/x/old.html"])
        // Offline at the same time: the phone pins one, the Mac pins another and unpins the old one.
        phone.pin("/x/phone.html")
        mac.pin("/x/mac.html")
        mac.pins.unpin(profile: "default", value: "/x/old.html")
        await mac.round()                       // the Mac reaches the gateway first
        await phone.round()                     // the phone's write meets the Mac's
        await mac.round()
        #expect(Set(phone.pinned) == ["/x/phone.html", "/x/mac.html"])
        #expect(Set(mac.pinned) == ["/x/phone.html", "/x/mac.html"])
    }

    @Test func aConflictIsReadAgainAndWrittenOnceMore() async {
        let server = SyncFakeServer()
        let phone = Device("iPhone", server: server), mac = Device("Mac", server: server)
        phone.start(); mac.start()
        await phone.round(); await mac.round()
        mac.pin("/x/mac.html")
        // The phone writes between the Mac's read and its write.
        phone.pin("/x/phone.html")
        await phone.round()
        let phoneCopy = server.value("hermes-hq-sync.pins")!
        server.beforeNextWrite = { server.put("hermes-hq-sync.pins", phoneCopy) }   // a revision the Mac's read did not see
        await mac.sync.flushNow()                                    // refused, tried again after the back-off
        try? await Task.sleep(nanoseconds: 50_000_000)
        await mac.sync.flushNow()
        await phone.round()
        #expect(Set(mac.pinned) == ["/x/phone.html", "/x/mac.html"])
        #expect(Set(phone.pinned) == ["/x/phone.html", "/x/mac.html"])
    }

    // [main-e2e] A gateway that can't take the write (an older Hermes without `profiles.configure`) is tried once, not
    // six times with a roster read before each (the offline UI test's stand-in has none: Control Center looked guilty).
    @Test func aGatewayThatCantTakeTheWriteIsNotTriedAgain() async {
        let server = SyncFakeServer()
        let client = FakeGatewayClient()
        client.onCall { method, params in
            if method == "profiles.configure" { throw RPCError(code: -32601, message: "Method not found: profiles.configure") }
            return server.handle(method, params)
        }
        let defaults = UserDefaults(suiteName: "hq.sync.test.old.\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory.appending(path: "sync-test-\(UUID().uuidString)")
        let sync = GatewaySync(client: client, accountId: "a", deviceName: "iPhone", defaults: defaults, knownDirectory: dir,
                               defaultRow: { RosterProfile(json: server.row) })
        sync.debounceNanoseconds = 1_000_000
        sync.backoffUnit = 0.001
        let pins = ArtifactPins(fileURL: nil)
        pins.syncChanged = { [weak sync] in sync?.changed("pins") }
        sync.register(pins)                       // nothing on the gateway yet: this device's copy goes up
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.calls("profiles.configure").count == 1, "tried once")
        #expect(client.calls("profiles.list").count == 1, "with one roster read")
        await sync.flushNow()                     // the app going to the background
        #expect(client.calls("profiles.list").count == 1, "nor on going to the background")
        pins.pin(ArtifactPin(kind: .file, value: "/x/a.html", label: "", profile: "default", sessionId: "s", sessionTitle: "Chat"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.calls("profiles.configure").count == 2, "the next change tries again, once")
    }

    // A gateway that answers the write without saying it kept `ui_meta` (the sessions UI test's stand-in answers {}) is
    // as one that refuses it: tried once, and a save whose synced part is the same (a Sessions pill tap) is no change.
    @Test func aGatewayThatAnswersWithoutKeepingIsNotTriedAgainForTheSameValue() async {
        let server = SyncFakeServer()
        let client = FakeGatewayClient()
        client.onCall { method, params in
            if method == "profiles.configure" { return .object([:]) }
            return server.handle(method, params)
        }
        let defaults = UserDefaults(suiteName: "hq.sync.test.mute.\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory.appending(path: "sync-test-\(UUID().uuidString)")
        let sync = GatewaySync(client: client, accountId: "a", deviceName: "iPhone", defaults: defaults, knownDirectory: dir,
                               defaultRow: { RosterProfile(json: server.row) })
        sync.debounceNanoseconds = 1_000_000
        sync.backoffUnit = 0.001
        let pins = ArtifactPins(fileURL: nil)
        pins.syncChanged = { [weak sync] in sync?.changed("pins") }
        sync.register(pins)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.calls("profiles.configure").count == 1, "tried once, not six times")
        sync.changed("pins")                      // a save with nothing new in it
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.calls("profiles.configure").count == 1, "the same value is no change")
        #expect(client.calls("profiles.list").count == 1)
        pins.pin(ArtifactPin(kind: .file, value: "/x/a.html", label: "", profile: "default", sessionId: "s", sessionTitle: "Chat"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.calls("profiles.configure").count == 2, "a real change tries again, once")
    }

    // After six refused tries, a save with the same value doesn't start them again.
    @Test func afterGivingUpTheSameValueIsNoChange() async {
        let server = SyncFakeServer()
        let client = FakeGatewayClient()
        client.onCall { method, params in
            if method == "profiles.configure" { return ["applied": ["ui_meta": false]] }
            return server.handle(method, params)
        }
        let defaults = UserDefaults(suiteName: "hq.sync.test.refuse.\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory.appending(path: "sync-test-\(UUID().uuidString)")
        let sync = GatewaySync(client: client, accountId: "a", deviceName: "iPhone", defaults: defaults, knownDirectory: dir,
                               defaultRow: { RosterProfile(json: server.row) })
        sync.debounceNanoseconds = 1_000_000
        sync.backoffUnit = 0.001
        let pins = ArtifactPins(fileURL: nil)
        pins.syncChanged = { [weak sync] in sync?.changed("pins") }
        sync.register(pins)
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(client.calls("profiles.configure").count == GatewaySync.maxTries)
        sync.changed("pins")
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.calls("profiles.configure").count == GatewaySync.maxTries, "the same value is no change")
    }

    @Test func aChangeMadeBeforeTheAppQuitStillGoes() async {
        let server = SyncFakeServer()
        let dir = FileManager.default.temporaryDirectory.appending(path: "sync-test-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "hq.sync.test.relaunch.\(UUID().uuidString)")!
        let client = FakeGatewayClient()
        client.onCall { method, params in server.handle(method, params) }
        func launch(_ pins: ArtifactPins) -> GatewaySync {
            let sync = GatewaySync(client: client, accountId: "a", deviceName: "iPhone", defaults: defaults, knownDirectory: dir,
                                   defaultRow: { RosterProfile(json: server.row) })
            sync.debounceNanoseconds = 1_000_000_000_000
            pins.syncChanged = { [weak sync] in sync?.changed("pins") }
            sync.register(pins)
            return sync
        }
        let pins = ArtifactPins(fileURL: nil)
        var sync = launch(pins)
        await sync.flushNow()
        sync.shutdown()
        // Pinned while no sync listened (offline, then quit before the write).
        pins.syncChanged = nil
        pins.pin(ArtifactPin(kind: .file, value: "/x/late.html", label: "", profile: nil, sessionId: "s", sessionTitle: ""))
        sync = launch(pins)
        await sync.flushNow()
        let data = server.value("hermes-hq-sync.pins")?["data"]?["pins"]?.array ?? []
        #expect(data.compactMap { $0["value"]?.string } == ["/x/late.html"])
    }

    @Test func removedArtifactsJoin() async {
        let server = SyncFakeServer()
        let phone = Device("iPhone", server: server), mac = Device("Mac", server: server)
        phone.start(); mac.start()
        await phone.round(); await mac.round()
        phone.hidden.hide(profile: nil, value: "/x/footer.png")
        mac.hidden.hide(profile: nil, value: "/x/logo.png")
        await phone.round(); await mac.round(); await phone.round()
        #expect(phone.hidden.keys == mac.hidden.keys)
        #expect(phone.hidden.keys.count == 2)
    }

    @Test func eachSettingKeepsItsNewestCopy() async {
        let server = SyncFakeServer()
        let phone = Device("iPhone", server: server), mac = Device("Mac", server: server)
        phone.start(); mac.start()
        await phone.round(); await mac.round()
        phone.clock += 10
        phone.defaults.set("rosePine", forKey: "hqn.theme.skin")
        phone.settings.defaultsChanged()
        mac.clock += 20
        mac.defaults.set(true, forKey: "hq.chat.fewerTimestamps")
        mac.settings.defaultsChanged()
        await phone.round(); await mac.round(); await phone.round()
        #expect(mac.defaults.string(forKey: "hqn.theme.skin") == "rosePine")
        #expect(phone.defaults.object(forKey: "hq.chat.fewerTimestamps") as? Bool == true, "a Bool stays a Bool")
        // A newer change on the Mac wins; turning it back off (removed) travels too.
        mac.clock += 100
        mac.defaults.removeObject(forKey: "hq.chat.fewerTimestamps")
        mac.settings.defaultsChanged()
        await mac.round(); await phone.round()
        #expect(phone.defaults.object(forKey: "hq.chat.fewerTimestamps") == nil)
    }

    @Test func savedPromptsTravelAndDeviceThingsDont() async {
        let server = SyncFakeServer()
        let phone = Device("iPhone", server: server), mac = Device("Mac", server: server)
        phone.start(); mac.start()
        await phone.round(); await mac.round()
        let prompt = Data(#"[{"id":"1","title":"Standup","text":"What changed?"}]"#.utf8)
        phone.defaults.set(prompt, forKey: PromptLibrary.defaultsKey)
        phone.defaults.set(1.3, forKey: "hqn.theme.uiScale")
        phone.defaults.set("secret", forKey: "hq.voice.apiKey")
        phone.library.defaultsChanged(); phone.settings.defaultsChanged()
        await phone.round(); await mac.round()
        #expect(mac.defaults.data(forKey: PromptLibrary.defaultsKey) == prompt)
        #expect(mac.defaults.object(forKey: "hqn.theme.uiScale") == nil, "each device keeps its own text size")
        #expect(mac.defaults.object(forKey: "hq.voice.apiKey") == nil)
    }

    @Test func perAccountSettingsLandOnTheOtherDevicesAccount() async {
        let server = SyncFakeServer()
        // The phone signed in with the Tailscale name, the Mac with a local address: same gateway, two ids.
        let phone = Device("iPhone", server: server, accountId: "https://hermes.tail.ts.net|me")
        let mac = Device("Mac", server: server, accountId: "http://127.0.0.1:9119|me")
        phone.start(); mac.start()
        await phone.round(); await mac.round()
        phone.defaults.set(["/model", "/compact"], forKey: "hq.favorite-commands|https://hermes.tail.ts.net|me")
        phone.settings.defaultsChanged()
        await phone.round(); await mac.round()
        #expect(mac.defaults.stringArray(forKey: "hq.favorite-commands|http://127.0.0.1:9119|me") == ["/model", "/compact"])
        #expect(mac.defaults.object(forKey: "hq.favorite-commands|https://hermes.tail.ts.net|me") == nil)
    }

    @Test func settingsMadeBeforeSyncTakeTheFirstDevicesCopy() async {
        let server = SyncFakeServer()
        let phone = Device("iPhone", server: server), mac = Device("Mac", server: server)
        phone.settings.close(); mac.settings.close()
        // Set by builds before sync: no times on them.
        phone.defaults.set("catppuccin", forKey: "hqn.theme.skin")
        mac.defaults.set("ink", forKey: "hqn.theme.skin")
        let phoneSettings = SettingsSync(library: false, accountId: phone.accountId, defaults: phone.defaults)
        let macSettings = SettingsSync(library: false, accountId: mac.accountId, defaults: mac.defaults)
        phone.sync.register(phoneSettings)
        mac.sync.register(macSettings)
        await phone.round()
        await mac.round()
        await phone.round()
        #expect(mac.defaults.string(forKey: "hqn.theme.skin") == "catppuccin", "the first device up sets the start")
        #expect(phone.defaults.string(forKey: "hqn.theme.skin") == "catppuccin")
    }

    // [hang-watch] A write off the main thread never waits for main. It used to: HangWatch counted a stall in
    // StabilityCounts under a lock the main thread was waiting on, the write waited for main, and the app froze for good.
    @Test func aWriteOffTheMainThreadDoesNotWaitForMain() async {
        let suite = "sync-offmain-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsSync(library: false, accountId: "me", defaults: defaults)
        defer { settings.close() }
        var noticed = 0
        settings.syncChanged = { noticed += 1 }
        func writeWhileMainIsBusy() -> Bool {
            let written = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defaults.set("ink", forKey: "hqn.theme.skin")
                written.signal()
            }
            return written.wait(timeout: .now() + 3) == .success   // the main thread waits here meanwhile
        }
        #expect(writeWhileMainIsBusy(), "the write went through with the main thread busy")
        try? await Task.sleep(nanoseconds: 800_000_000)
        #expect(noticed == 1, "and the change was still taken in, on main")
    }

    @Test func threeWayMergeOfLists() {
        struct Item: Identifiable, Equatable { var id: String; var size = 0 }
        let base = [Item(id: "a"), Item(id: "b"), Item(id: "c")]
        let local = [Item(id: "new"), Item(id: "a", size: 2), Item(id: "c")]          // added new, resized a, dropped b
        let remote = [Item(id: "c"), Item(id: "b"), Item(id: "a"), Item(id: "theirs")]  // reordered, added theirs
        let out = ArtifactPins.merged(remote, local: local, base: base)
        #expect(out.map(\.id) == ["new", "c", "a", "theirs"])
        #expect(out.first { $0.id == "a" }?.size == 2)
    }
}
