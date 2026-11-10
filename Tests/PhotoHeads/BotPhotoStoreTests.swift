// [photoheads] When a bot's picture is fetched, what is kept, and what never causes a call
// (docs/spec/3x-photoheads.md §4.2–4.4, §11.1 item 4).

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
struct BotPhotoStoreTests {
    private let folder = BotsTest.tempDirectory()

    private func makeStore(_ gateway: PhotoGateway, account: GatewayAccount = .botsTestAccount, start: Bool = true) -> BotPhotoStore {
        let store = BotPhotoStore(client: gateway.client, account: account, cacheDirectory: folder, timing: .fast)
        if start { store.start() }
        return store
    }

    private func rows(_ profiles: RosterProfile..., to store: BotPhotoStore, issuedAt: Date = Date()) {
        store.rowsArrived(profiles, order: profiles.map(\.name), issuedAt: issuedAt)
    }

    private func settle(_ store: BotPhotoStore, _ timeout: Duration = .seconds(5)) async {
        await BotsTest.waitUntil(timeout) { store.isIdle }
        BotPhotoDisk.shared.flush()
    }

    private func exists(_ store: BotPhotoStore, _ profile: String) -> Bool {
        FileManager.default.fileExists(atPath: BotPhotoStore.fileURL(store.folder, profile).path)
    }

    private static let other = GatewayAccount(id: "http://127.0.0.1:9716|someone-else", baseURL: URL(string: "http://127.0.0.1:9716")!,
                                              kind: .password, username: "someone-else", label: "127.0.0.1")

    // MARK: §4.3, row by row

    @Test func aGatewayWithoutTheAssetStoreIsNeverAsked() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("ivy", hasAvatar: nil), PhotoGateway.profile("default", hasAvatar: nil), to: store)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(gateway.fetches.isEmpty)
        #expect(!store.supportsAssets)
        #expect(store.verdict(for: "ivy") == nil)
        store.refresh("ivy")
        store.refreshAll()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(gateway.fetches.isEmpty)
    }

    @Test func whetherTheGatewayStoresPicturesIsKnownFromTheFirstFrameOfTheNextLaunch() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let first = makeStore(gateway)
        var told = 0
        first.onSupportChange = { told += 1 }
        #expect(!first.supportsAssets)       // a gateway never seen before: not known until its roster answers
        rows(PhotoGateway.profile("ivy"), to: first)
        #expect(first.supportsAssets && told == 1)
        rows(PhotoGateway.profile("ivy"), to: first)
        #expect(told == 1)       // the same answer again tells nobody
        await settle(first)
        first.stop()

        // The next launch: known before any roster answer, so Edit Bot's Picture section is right at once.
        let second = makeStore(gateway)
        var toldAgain = 0
        second.onSupportChange = { toldAgain += 1 }
        #expect(second.supportsAssets)
        rows(PhotoGateway.profile("ivy"), to: second)
        #expect(toldAgain == 0)
        // The gateway was replaced by an older one (no `has_avatar` anywhere): that is said once, and kept too.
        rows(PhotoGateway.profile("ivy", hasAvatar: nil), to: second)
        #expect(!second.supportsAssets && toldAgain == 1)
        rows(PhotoGateway.profile("ivy", hasAvatar: nil), to: second)
        #expect(toldAgain == 1)
        await settle(second)
        second.stop()
        #expect(!makeStore(gateway, start: false).supportsAssets)
    }

    @Test func theRegistryIsToldWhenTheGatewayTurnsOutToStorePictures() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let store = makeStore(gateway)
        let faces = BotFaces()
        faces.use(store)
        #expect(!faces.supportsPictures)
        let before = faces.version
        rows(PhotoGateway.profile("ivy"), to: store)
        #expect(faces.supportsPictures)
        #expect(faces.version != before)
        // A store that is no longer the one in use tells nobody.
        faces.use(nil)
        let after = faces.version
        rows(PhotoGateway.profile("ivy", hasAvatar: nil), to: store)
        #expect(faces.version == after)
        store.stop()
    }

    @Test func aPhoneThatCannotKeepTheFileStopsAskingForIt() async throws {
        // No storage: the cache directory is under a plain file, so nothing can be written there.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("photoheads-nodisk-\(UUID().uuidString)")
        try Data("not a folder".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let store = BotPhotoStore(client: gateway.client, account: .botsTestAccount, cacheDirectory: blocker.appendingPathComponent("lists"), timing: .fast)
        store.start()
        let faces = BotFaces()
        faces.use(store)
        rows(PhotoGateway.profile("ivy"), to: store)
        // Each read comes back as a photo that cannot be kept: after the first try and two more, it stops.
        await BotsTest.waitUntil(.seconds(8)) { gateway.fetches("ivy") == 1 + BotPhotoStore.discardLimit && store.isIdle && !store.hasPhoto("ivy") }
        try? await Task.sleep(for: .milliseconds(500))
        #expect(gateway.fetches("ivy") == 1 + BotPhotoStore.discardLimit)
        #expect(faces.photo(for: "ivy") == nil && !faces.showsPhoto("ivy"))
        // The same roster again asks nothing more.
        rows(PhotoGateway.profile("ivy"), to: store)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(gateway.fetches("ivy") == 1 + BotPhotoStore.discardLimit)
        store.stop()
    }

    @Test func theUploadWaitIsThirtySeconds() {
        // The UI test of "no gateway on Save" runs with a shorter wait (`-HQDebugUploadTimeout`); this pins the real one.
        #expect(BotPhotoTiming().uploadTimeout == .seconds(30))
        #expect(BotPhotoTiming.standard.uploadTimeout == .seconds(30))
        #expect(BotPhotoTiming().fetchTimeout == .seconds(30))
    }

    @Test func noAvatarIsTheHeadAtOnceWithNoCall() async {
        let gateway = PhotoGateway()
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("notes", hasAvatar: false), to: store)
        #expect(store.supportsAssets)
        #expect(store.verdict(for: "notes") == BotPicture.Verdict.none)
        #expect(!store.hasPhoto("notes"))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(gateway.fetches.isEmpty)
    }

    @Test func aFirstSightFetchesOnceAndDecidesWhatItIs() async throws {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA, "default": PhotoTest.mirror, "inbox": PhotoTest.backfill,
                                             "broken": PhotoTest.brokenPNG])
        let store = makeStore(gateway)
        var changed: [String] = []
        store.onChange = { changed.append($0) }
        rows(PhotoGateway.profile("default"), PhotoGateway.profile("ivy"), PhotoGateway.profile("inbox"), PhotoGateway.profile("broken"),
             PhotoGateway.profile("notes", hasAvatar: false), to: store)
        await settle(store)
        #expect(store.verdict(for: "ivy") == .photo)
        #expect(store.verdict(for: "default") == .mirror)
        #expect(store.verdict(for: "inbox") == .backfill)
        #expect(store.verdict(for: "broken") == .unreadable)
        #expect(store.verdict(for: "notes") == BotPicture.Verdict.none)
        #expect(gateway.fetches.sorted() == ["broken", "default", "inbox", "ivy"])
        // Exact params: nothing but `name` and `asset` (the gateway refuses any other key).
        for call in gateway.client.calls("profiles.get_asset") {
            #expect(Set(call.params.object?.keys.map { $0 } ?? []) == ["name", "asset"])
            #expect(call.params["asset"]?.string == "avatar")
            #expect(call.timeout == .seconds(2))
        }
        // Only the photo keeps bytes, and it is the bot the faces are told about first of all.
        #expect(exists(store, "ivy"))
        #expect(!exists(store, "default") && !exists(store, "inbox") && !exists(store, "broken"))
        #expect(changed.contains("ivy"))
        #expect(store.fingerprint(for: "ivy") == BotPicture.fingerprint(try #require(BotPicture.bytes(of: PhotoTest.photoA))))
        #expect(store.fingerprint(for: "default") == nil)
        let entry = try #require(store.entries["ivy"])
        #expect(entry.w == 256 && entry.h == 256 && entry.bots == 1 && entry.head == 0)
        let data = try #require(await store.photoData(for: "ivy"))
        #expect(PhotoTest.ihdr(data)?.width == 256)

        // The same rows again: nothing.
        rows(PhotoGateway.profile("default"), PhotoGateway.profile("ivy"), PhotoGateway.profile("inbox"), PhotoGateway.profile("broken"),
             PhotoGateway.profile("notes", hasAvatar: false), to: store)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(gateway.fetches.count == 4)
    }

    @Test func aMovedRevisionFetchesAfterTheDelayAndOnceMoreWhenThePictureIsTheSame() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("ivy", bots: 1), to: store)
        await settle(store)
        #expect(gateway.fetches("ivy") == 1)

        let moved = ContinuousClock.now
        rows(PhotoGateway.profile("ivy", bots: 2), to: store)
        // Not at once: the other device's upload is given time.
        try? await Task.sleep(for: .milliseconds(30))
        #expect(gateway.fetches("ivy") == 1)
        await BotsTest.waitUntil { gateway.fetches("ivy") == 2 }
        #expect(ContinuousClock.now - moved >= .milliseconds(75))
        // A roster in between changes nothing: the second look is already planned.
        rows(PhotoGateway.profile("ivy", bots: 2), to: store)
        await settle(store)
        #expect(gateway.fetches("ivy") == 3)
        #expect(ContinuousClock.now - moved >= .milliseconds(270))
        #expect(store.entries["ivy"]?.bots == 2)
        // Recorded: the same revision again is not a signal.
        rows(PhotoGateway.profile("ivy", bots: 2), to: store)
        try? await Task.sleep(for: .milliseconds(350))
        #expect(gateway.fetches("ivy") == 3)
    }

    @Test func aMovedRevisionWithANewPictureIsTakenAtOnce() async throws {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("ivy", bots: 1, head: 1), to: store)
        await settle(store)
        var changed: [String] = []
        store.onChange = { changed.append($0) }

        gateway.set("ivy", PhotoTest.photoB)
        rows(PhotoGateway.profile("ivy", bots: 2, head: 1), to: store)
        await settle(store)
        #expect(gateway.fetches("ivy") == 2)
        #expect(store.fingerprint(for: "ivy") == BotPicture.fingerprint(try #require(BotPicture.bytes(of: PhotoTest.photoB))))
        #expect(changed == ["ivy"])
        #expect(store.entries["ivy"]?.bots == 2 && store.entries["ivy"]?.head == 1)

        // The head's revision moving is a signal too: a head saved elsewhere replaced the photo with its copy.
        gateway.set("ivy", PhotoTest.mirror)
        rows(PhotoGateway.profile("ivy", bots: 2, head: 2), to: store)
        await settle(store)
        #expect(gateway.fetches("ivy") == 3)
        #expect(store.verdict(for: "ivy") == .mirror)
        #expect(!exists(store, "ivy"))
        #expect(changed == ["ivy", "ivy"])
    }

    @Test func anAvatarThatGoesAwayIsTheHeadAtOnce() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("ivy"), to: store)
        await settle(store)
        var changed: [String] = []
        store.onChange = { changed.append($0) }

        gateway.set("ivy", nil)
        rows(PhotoGateway.profile("ivy", hasAvatar: false), to: store)
        #expect(store.verdict(for: "ivy") == BotPicture.Verdict.none)
        #expect(changed == ["ivy"])
        BotPhotoDisk.shared.flush()
        #expect(!exists(store, "ivy"))
        #expect(gateway.fetches("ivy") == 1)

        // Back again: exactly one fetch for the flip, and no loop when the rows keep flipping.
        gateway.set("ivy", PhotoTest.photoB)
        for flip in 0..<6 {
            rows(PhotoGateway.profile("ivy", hasAvatar: flip % 2 == 0), to: store)
            await settle(store)
        }
        #expect(gateway.fetches("ivy") == 1 + 3)
    }

    // MARK: the queue

    @Test func oneFetchAtATimeInListOrderWithTheOpenChatFirst() async {
        let names = ["a", "b", "c", "d", "e", "f"]
        let gateway = PhotoGateway(avatars: Dictionary(uniqueKeysWithValues: names.map { ($0, PhotoTest.photoA) }))
        gateway.state.mutate { $0.delay = .milliseconds(25) }
        let store = makeStore(gateway)
        store.setFocus("d")
        store.rowsArrived(names.map { PhotoGateway.profile($0) }, order: names, issuedAt: Date())
        await settle(store)
        #expect(gateway.state.value.maxInFlight == 1)
        #expect(gateway.fetches == ["d", "a", "b", "c", "e", "f"])
        #expect(store.fetchCount == 6)
        // Spaced out: never closer than the gap.
        let times = gateway.client.calls("profiles.get_asset").map(\.at)
        for (earlier, later) in zip(times, times.dropFirst()) { #expect(later - earlier >= .milliseconds(25 + 10)) }
    }

    @Test func nothingIsFetchedWhileTheSocketIsDownOrTheAppIsAway() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA, "ana": PhotoTest.photoB], connection: .connecting)
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("ivy"), to: store)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(gateway.fetches.isEmpty)
        gateway.client.setState(.ready)
        await BotsTest.waitUntil { gateway.fetches("ivy") == 1 }
        await settle(store)
        #expect(store.verdict(for: "ivy") == .photo)

        store.appDidEnterBackground()
        rows(PhotoGateway.profile("ivy"), PhotoGateway.profile("ana"), to: store)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(gateway.fetches("ana") == 0)
        store.appDidBecomeActive()
        await settle(store)
        #expect(gateway.fetches("ana") == 1)
    }

    @Test func aFailureIsSilentAndRetriedUpTheLadderThenOnReconnect() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        gateway.state.mutate { $0.failures["ivy"] = 100 }
        let store = makeStore(gateway)
        var changed: [String] = []
        store.onChange = { changed.append($0) }
        let began = ContinuousClock.now
        rows(PhotoGateway.profile("ivy"), to: store)
        // One try, then three more on the ladder (60, 120, 180 ms), then nothing.
        await BotsTest.waitUntil { gateway.fetches("ivy") == 4 }
        #expect(ContinuousClock.now - began >= .milliseconds(340))
        await settle(store)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(gateway.fetches("ivy") == 4)
        #expect(store.verdict(for: "ivy") == nil)       // unknown: the head keeps showing
        #expect(changed.isEmpty)
        // A roster in between does not start it over.
        rows(PhotoGateway.profile("ivy"), to: store)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(gateway.fetches("ivy") == 4)

        // The ladder starts over on reconnect.
        gateway.state.mutate { $0.failures["ivy"] = 1 }
        gateway.client.setState(.connecting)
        try? await Task.sleep(for: .milliseconds(30))
        gateway.client.setState(.ready)
        await BotsTest.waitUntil { gateway.fetches("ivy") == 6 }
        await settle(store)
        #expect(store.verdict(for: "ivy") == .photo)
        #expect(changed == ["ivy"])
    }

    @Test func aFailingBotDoesNotHoldUpTheOthers() async {
        let gateway = PhotoGateway(avatars: ["a": PhotoTest.photoA, "b": PhotoTest.photoB, "c": PhotoTest.mirror])
        gateway.state.mutate { $0.failures["a"] = 1 }
        // The first retry is five seconds away, so the order asserted below does not depend on how fast this Mac decodes
        // b and c (repair round 1: under heavy load a 60 ms retry came due before c had been read).
        var timing = BotPhotoTiming.fast
        timing.retryLadder = [.seconds(5), .seconds(6), .seconds(7)]
        let store = BotPhotoStore(client: gateway.client, account: .botsTestAccount, cacheDirectory: folder, timing: timing)
        store.start()
        store.rowsArrived(["a", "b", "c"].map { PhotoGateway.profile($0) }, order: ["a", "b", "c"], issuedAt: Date())
        await BotsTest.waitUntil(.seconds(40)) { gateway.fetches.count >= 4 }
        await settle(store, .seconds(20))
        #expect(gateway.fetches == ["a", "b", "c", "a"])
        #expect(store.verdict(for: "a") == .photo && store.verdict(for: "b") == .photo && store.verdict(for: "c") == .mirror)
    }

    // MARK: this phone's own writes

    @Test func adoptChangesTheFaceAndCausesNoCall() async throws {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("ivy", bots: 4), to: store)
        await settle(store)
        var changed: [String] = []
        store.onChange = { changed.append($0) }

        gateway.set("ivy", PhotoTest.photoB)
        await store.adopt("ivy", dataURL: PhotoTest.photoB)
        #expect(store.fingerprint(for: "ivy") == BotPicture.fingerprint(try #require(BotPicture.bytes(of: PhotoTest.photoB))))
        #expect(changed == ["ivy"])
        // The configure that follows the upload moves the revision; this phone made it, so it is not a signal.
        store.noteMetaWrite("ivy", key: BotStore.botsKey, revision: 5)
        #expect(store.entries["ivy"]?.bots == 5)
        // A roster read sent before the write still carries revision 4; one sent after carries 5. Neither fetches.
        rows(PhotoGateway.profile("ivy", bots: 4), to: store, issuedAt: Date().addingTimeInterval(-5))
        rows(PhotoGateway.profile("ivy", bots: 5), to: store)
        await settle(store)
        try? await Task.sleep(for: .milliseconds(350))
        #expect(gateway.fetches("ivy") == 1)
        BotPhotoDisk.shared.flush()
        let bytes = try #require(await store.photoData(for: "ivy"))
        let kept = try #require(PhotoTest.decode(bytes))
        #expect(PhotoTest.pixel(kept, 100, 100).near(PhotoTest.blue))
    }

    @Test func aStaleRosterDoesNotTakeAJustUploadedPhotoAway() async {
        let gateway = PhotoGateway()
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("notes", hasAvatar: false, bots: 0), to: store)
        let sent = Date().addingTimeInterval(-1)       // a read that was already out when the photo was saved
        await store.adopt("notes", dataURL: PhotoTest.photoA)
        #expect(store.hasPhoto("notes"))
        rows(PhotoGateway.profile("notes", hasAvatar: false, bots: 0), to: store, issuedAt: sent)
        #expect(store.hasPhoto("notes"))
        #expect(gateway.fetches.isEmpty)
    }

    @Test func aWriteFromElsewhereInBetweenIsStillNoticed() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("ivy", bots: 4), to: store)
        await settle(store)
        // This phone's write came back as revision 6: someone else wrote 5.
        store.noteMetaWrite("ivy", key: BotStore.botsKey, revision: 6)
        #expect(store.entries["ivy"]?.bots == 4)
        gateway.set("ivy", PhotoTest.photoB)
        rows(PhotoGateway.profile("ivy", bots: 6), to: store)
        await settle(store)
        #expect(gateway.fetches("ivy") == 2)
        #expect(store.entries["ivy"]?.bots == 6)
    }

    @Test func adoptingNothingRemovesThePicture() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("ivy"), to: store)
        await settle(store)
        var changed: [String] = []
        store.onChange = { changed.append($0) }
        await store.adopt("ivy", dataURL: nil)
        #expect(store.verdict(for: "ivy") == BotPicture.Verdict.none)
        #expect(changed == ["ivy"])
        BotPhotoDisk.shared.flush()
        #expect(!exists(store, "ivy"))
        #expect(gateway.fetches("ivy") == 1)
    }

    @Test func aSavedHeadDropsThePhotoAtOnce() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA, "default": PhotoTest.mirror])
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("ivy"), PhotoGateway.profile("default"), to: store)
        await settle(store)
        var changed: [String] = []
        store.onChange = { changed.append($0) }

        #expect(store.headSaved("ivy"))
        #expect(store.verdict(for: "ivy") == .mirror)
        #expect(!store.hasPhoto("ivy"))
        #expect(store.awaitingMirror == ["ivy"])
        #expect(changed == ["ivy"])
        // A bot that wore no photo: nothing to drop, nothing to wait for.
        #expect(!store.headSaved("default"))
        #expect(store.awaitingMirror == ["ivy"])
        // The head's desktop copy landing settles it.
        await store.adopt("ivy", dataURL: PhotoTest.mirror)
        #expect(store.awaitingMirror.isEmpty)
        #expect(store.verdict(for: "ivy") == .mirror)
        BotPhotoDisk.shared.flush()
        #expect(!exists(store, "ivy"))
        #expect(gateway.fetches("ivy") == 1)
    }

    @Test func anAnswerOlderThanThisPhonesWriteIsDropped() async throws {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        gateway.state.mutate { $0.delay = .milliseconds(150) }
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("ivy"), to: store)
        await BotsTest.waitUntil { gateway.fetches("ivy") == 1 }
        // While that fetch is out, this phone stores photo B.
        await store.adopt("ivy", dataURL: PhotoTest.photoB)
        await settle(store)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(store.fingerprint(for: "ivy") == BotPicture.fingerprint(try #require(BotPicture.bytes(of: PhotoTest.photoB))))
    }

    // MARK: asked for

    @Test func aRefreshIsSkippedWithinTheGuard() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("ivy"), PhotoGateway.profile("notes", hasAvatar: false), to: store)
        await settle(store)
        store.refresh("ivy")
        store.refreshAll()
        store.refresh("notes")
        store.refresh("nobody")
        await settle(store)
        #expect(gateway.fetches == ["ivy"])
        try? await Task.sleep(for: .milliseconds(450))
        gateway.set("ivy", PhotoTest.photoB)
        store.refresh("ivy")
        store.refresh("ivy")
        await settle(store)
        #expect(gateway.fetches == ["ivy", "ivy"])
        #expect(store.entries["ivy"]?.fingerprint == BotPicture.fingerprint(BotPicture.bytes(of: PhotoTest.photoB)!))
    }

    /// Stress round 1: a bot waiting on the retry ladder ignored pull to refresh and Bot Info.
    @Test func aRefreshBringsAWaitingRetryForward() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        gateway.state.mutate { $0.failures["ivy"] = 1 }
        var timing = BotPhotoTiming.fast
        timing.retryLadder = [.seconds(30), .seconds(120), .seconds(600)]       // the real waits: nothing comes due by itself
        timing.refreshGuard = .seconds(60)
        let store = BotPhotoStore(client: gateway.client, account: .botsTestAccount, cacheDirectory: folder, timing: timing)
        store.start()
        rows(PhotoGateway.profile("ivy"), to: store)
        await BotsTest.waitUntil { gateway.fetches("ivy") == 1 }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(gateway.fetches("ivy") == 1)       // failed once; the next try is 30 s away
        #expect(store.verdict(for: "ivy") == nil)
        store.refresh("ivy")
        store.refresh("ivy")       // asking twice is still one fetch
        await BotsTest.waitUntil { gateway.fetches("ivy") == 2 }
        await settle(store)
        #expect(gateway.fetches("ivy") == 2)
        #expect(store.verdict(for: "ivy") == .photo)

        // Pull to refresh does the same for every waiting bot, and a failure after it goes on up the ladder.
        gateway.set("ana", PhotoTest.photoB)
        gateway.state.mutate { $0.failures["ana"] = 2 }
        rows(PhotoGateway.profile("ivy"), PhotoGateway.profile("ana"), to: store)
        await BotsTest.waitUntil { gateway.fetches("ana") == 1 }
        try? await Task.sleep(for: .milliseconds(200))
        store.refreshAll()
        await BotsTest.waitUntil { gateway.fetches("ana") == 2 }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(gateway.fetches("ana") == 2)       // failed again: waiting on the ladder, not hammering
        #expect(gateway.fetches("ivy") == 2)       // ivy was checked a moment ago
        store.refreshAll()
        await BotsTest.waitUntil { gateway.fetches("ana") == 3 }
        await settle(store)
        #expect(store.verdict(for: "ana") == .photo)
        store.stop()
    }

    /// The same for a row that says the picture moved while its retry waits; the same row again starts nothing.
    @Test func aMovedRevisionBringsAWaitingRetryForward() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        var timing = BotPhotoTiming.fast
        timing.retryLadder = [.seconds(30), .seconds(120), .seconds(600)]
        let store = BotPhotoStore(client: gateway.client, account: .botsTestAccount, cacheDirectory: folder, timing: timing)
        store.start()
        rows(PhotoGateway.profile("ivy", bots: 1), to: store)
        await settle(store)
        #expect(gateway.fetches("ivy") == 1)
        // Another device changes the picture; this phone's read of it fails.
        gateway.set("ivy", PhotoTest.photoB)
        gateway.state.mutate { $0.failures["ivy"] = 1 }
        rows(PhotoGateway.profile("ivy", bots: 2), to: store)
        await BotsTest.waitUntil { gateway.fetches("ivy") == 2 }
        try? await Task.sleep(for: .milliseconds(200))
        rows(PhotoGateway.profile("ivy", bots: 2), to: store)       // the same row: still waiting
        try? await Task.sleep(for: .milliseconds(300))
        #expect(gateway.fetches("ivy") == 2)
        rows(PhotoGateway.profile("ivy", bots: 3), to: store)       // it moved again
        await BotsTest.waitUntil { gateway.fetches("ivy") >= 3 }
        await settle(store)
        #expect(store.entries["ivy"]?.fingerprint == BotPicture.fingerprint(BotPicture.bytes(of: PhotoTest.photoB)!))
        store.stop()
    }

    // MARK: odd answers

    @Test func foundWithoutDataAndGarbageShowTheHeadAndAreNotAskedAgain() async {
        let gateway = PhotoGateway(avatars: ["a": PhotoTest.photoA, "b": PhotoTest.photoA])
        gateway.state.mutate {
            $0.oddAnswers["a"] = ["found": true]
            $0.oddAnswers["b"] = ["found": true, "mime": "image/png", "size": 12, "data": "data:image/png;base64,@@@ not base64 @@@"]
        }
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("a"), PhotoGateway.profile("b"), to: store)
        await settle(store)
        #expect(store.verdict(for: "a") == BotPicture.Verdict.none)
        #expect(store.verdict(for: "b") == .unreadable)
        for _ in 0..<3 { rows(PhotoGateway.profile("a"), PhotoGateway.profile("b"), to: store) }
        await settle(store)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(gateway.fetches.sorted() == ["a", "b"])
    }

    @Test func aBigPictureFromAnotherClientIsKeptSmall() async throws {
        let big = PhotoTest.dataURL(PhotoTest.encode(PhotoTest.quadrants(4000, 3000), type: .jpeg), mime: "image/jpeg")
        let gateway = PhotoGateway(avatars: ["huge": big])
        // The real fetch wait, and time to decode 12 megapixels on a busy Mac (repair round 1: 5 s was not enough).
        var timing = BotPhotoTiming.fast
        timing.fetchTimeout = .seconds(30)
        let store = BotPhotoStore(client: gateway.client, account: .botsTestAccount, cacheDirectory: folder, timing: timing)
        store.start()
        rows(PhotoGateway.profile("huge"), to: store)
        await settle(store, .seconds(60))
        #expect(store.verdict(for: "huge") == .photo)
        let data = try #require(await store.photoData(for: "huge"))
        #expect(data.count < 400_000)
        #expect(PhotoTest.ihdr(data)?.width == 256 && PhotoTest.ihdr(data)?.height == 192)
        #expect(store.entries["huge"]?.w == 256 && store.entries["huge"]?.h == 192)
    }

    // MARK: disk

    @Test func verdictsSurviveARelaunchWithoutACall() async throws {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA, "default": PhotoTest.mirror])
        let first = makeStore(gateway)
        first.rowsArrived([PhotoGateway.profile("default", bots: 3, head: 2), PhotoGateway.profile("ivy")], order: ["default", "ivy"], issuedAt: Date())
        await settle(first)
        first.stop()
        BotPhotoDisk.shared.flush()

        let index = try Data(contentsOf: first.folder.appendingPathComponent("index.json"))
        let file = try JSONDecoder().decode(BotPhotoIndexFile.self, from: index)
        #expect(file.entries["ivy"]?.verdict == .photo && file.entries["default"]?.verdict == .mirror)
        #expect(file.order == ["default", "ivy"])
        #expect(first.folder.lastPathComponent == "botphotos-" + RosterDisk.accountKey(.botsTestAccount))
        // The index is plain JSON a person can read: verdict, fingerprint, the two revisions, the time, the size.
        let raw = try JSONValue.parse(index)
        #expect(raw["entries"]?["default"]?["bots"]?.int == 3 && raw["entries"]?["default"]?["head"]?.int == 2)
        #expect(raw["entries"]?["ivy"]?["w"]?.int == 256 && raw["entries"]?["ivy"]?["fingerprint"]?.string?.count == 16)

        let later = PhotoGateway(avatars: ["ivy": PhotoTest.photoA, "default": PhotoTest.mirror])
        let second = makeStore(later)
        // Before any roster: the photo is already known (an offline launch shows it).
        #expect(second.hasPhoto("ivy"))
        #expect(second.verdict(for: "default") == .mirror)
        #expect(second.order == ["default", "ivy"])
        second.rowsArrived([PhotoGateway.profile("default", bots: 3, head: 2), PhotoGateway.profile("ivy")], order: ["default", "ivy"], issuedAt: Date())
        await settle(second)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(later.fetches.isEmpty)
    }

    @Test func aDamagedIndexLoadsAsEmptyAndIsFetchedAgain() async throws {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let first = makeStore(gateway)
        rows(PhotoGateway.profile("ivy"), to: first)
        await settle(first)
        first.stop()
        BotPhotoDisk.shared.flush()
        let index = first.folder.appendingPathComponent("index.json")
        for damage in [Data("{\"version\":1,\"entries\":{\"ivy\":{\"verd".utf8), Data(), Data("[]".utf8),
                       Data("{\"version\":1,\"entries\":{\"ivy\":{\"verdict\":\"hologram\",\"fingerprint\":\"\",\"bots\":0,\"head\":0,\"at\":0,\"w\":0,\"h\":0}},\"order\":[]}".utf8)] {
            try damage.write(to: index)
            let reopened = makeStore(PhotoGateway(), start: false)
            #expect(reopened.entries.isEmpty)
            #expect(!reopened.hasPhoto("ivy"))
        }
        let again = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let store = makeStore(again)
        rows(PhotoGateway.profile("ivy"), to: store)
        await settle(store)
        #expect(again.fetches == ["ivy"])
        #expect(store.hasPhoto("ivy"))
    }

    @Test func aPhotoWhoseFileIsGoneIsFetchedAgain() async throws {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let first = makeStore(gateway)
        rows(PhotoGateway.profile("ivy"), to: first)
        await settle(first)
        first.stop()
        BotPhotoDisk.shared.flush()
        try FileManager.default.removeItem(at: BotPhotoStore.fileURL(first.folder, "ivy"))

        let again = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let store = makeStore(again)
        #expect(!store.hasPhoto("ivy"))
        rows(PhotoGateway.profile("ivy"), to: store)
        await settle(store)
        #expect(again.fetches == ["ivy"])
        #expect(store.hasPhoto("ivy") && exists(store, "ivy"))

        // A file that is there but cannot be drawn: the faces say so, and it is fetched again.
        var changed: [String] = []
        store.onChange = { changed.append($0) }
        store.discardUnreadable("ivy")
        #expect(!store.hasPhoto("ivy"))
        #expect(changed == ["ivy"])
        await settle(store)
        #expect(again.fetches == ["ivy", "ivy"])
        #expect(store.hasPhoto("ivy"))
    }

    @Test func removingTheCachedDataEmptiesTheFolder() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA, "ana": PhotoTest.photoB])
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("ivy"), PhotoGateway.profile("ana"), to: store)
        await settle(store)
        #expect(FileManager.default.fileExists(atPath: store.folder.path))
        var changed: [String] = []
        store.onChange = { changed.append($0) }
        store.stop()
        store.removeCachedData()
        BotPhotoDisk.shared.flush()
        #expect(!FileManager.default.fileExists(atPath: store.folder.path))
        #expect(store.entries.isEmpty && !store.hasPhoto("ivy"))
        #expect(changed.sorted() == ["ana", "ivy"])
    }

    @Test func aRemovedGatewaysFolderIsPurgedWithoutAStore() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let store = makeStore(gateway, account: Self.other)
        rows(PhotoGateway.profile("ivy"), to: store)
        await settle(store)
        store.stop()
        #expect(FileManager.default.fileExists(atPath: store.folder.path))
        BotPhotoStore.purge(cacheDirectory: folder, account: Self.other)
        BotPhotoDisk.shared.flush()
        #expect(!FileManager.default.fileExists(atPath: store.folder.path))
    }

    @Test func twoAccountsWithTheSameBotNameDoNotShareAVerdict() async {
        let alpha = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        let beta = PhotoGateway(account: Self.other, avatars: ["ivy": PhotoTest.mirror])
        let a = makeStore(alpha), b = makeStore(beta, account: Self.other)
        #expect(a.folder != b.folder)
        rows(PhotoGateway.profile("ivy"), to: a)
        await settle(a)
        #expect(a.hasPhoto("ivy"))
        #expect(b.verdict(for: "ivy") == nil)
        rows(PhotoGateway.profile("ivy"), to: b)
        await settle(b)
        #expect(b.verdict(for: "ivy") == .mirror)
        #expect(a.hasPhoto("ivy"))
        // A fresh store for the second account, same folder: still its own verdict.
        b.stop()
        BotPhotoDisk.shared.flush()
        let reopened = makeStore(PhotoGateway(account: Self.other), account: Self.other, start: false)
        #expect(reopened.verdict(for: "ivy") == .mirror && !reopened.hasPhoto("ivy"))
    }

    @Test func aBotThatIsGoneTakesItsPictureAlong() async {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA, "ana": PhotoTest.photoB])
        let store = makeStore(gateway)
        rows(PhotoGateway.profile("ivy"), PhotoGateway.profile("ana"), to: store)
        await settle(store)
        rows(PhotoGateway.profile("ana"), to: store)
        BotPhotoDisk.shared.flush()
        #expect(store.entries["ivy"] == nil && !exists(store, "ivy"))
        #expect(store.hasPhoto("ana") && exists(store, "ana"))
        // An empty answer (a failed read) forgets nothing.
        store.rowsArrived([], order: [], issuedAt: Date())
        #expect(store.hasPhoto("ana"))
    }

    @Test(arguments: ["ivy", "two words", "🤖 robot", String(repeating: "long-name-", count: 20), "../../etc/passwd", "a/b", ""])
    func anyProfileNameMakesASafeFileName(_ name: String) {
        let file = BotPhotoStore.fileName(name)
        #expect(file.count == 20 && file.hasSuffix(".png"))
        #expect(file.dropLast(4).allSatisfy { "0123456789abcdef".contains($0) })
        #expect(BotPhotoStore.fileURL(folder, name).deletingLastPathComponent().path == folder.path)
        #expect(BotPhotoStore.fileName(name) == BotPhotoStore.fileName(name))
    }

    @Test func oddProfileNamesKeepTheirPhotos() async {
        let names = ["two words", "🤖 robot", String(repeating: "long-name-", count: 20)]
        let gateway = PhotoGateway(avatars: Dictionary(uniqueKeysWithValues: names.map { ($0, PhotoTest.photoA) }))
        let store = makeStore(gateway)
        store.rowsArrived(names.map { PhotoGateway.profile($0) }, order: names, issuedAt: Date())
        await settle(store)
        for name in names { #expect(store.hasPhoto(name) && exists(store, name), "\(name)") }
        #expect(BotPhotoStore.isFolder(store.folder.lastPathComponent))
        #expect(!BotPhotoStore.isFolder("roster-0123456789abcdef01234567.json") && !BotPhotoStore.isFolder("botphotos-short"))
    }

    @Test func stoppingDropsWhatIsQueuedAndIgnoresALateAnswer() async {
        let gateway = PhotoGateway(avatars: ["a": PhotoTest.photoA, "b": PhotoTest.photoB])
        gateway.state.mutate { $0.delay = .milliseconds(120) }
        let store = makeStore(gateway)
        store.rowsArrived([PhotoGateway.profile("a"), PhotoGateway.profile("b")], order: ["a", "b"], issuedAt: Date())
        await BotsTest.waitUntil { gateway.fetches.count == 1 }
        store.stop()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(gateway.fetches == ["a"])
        #expect(store.entries.isEmpty)
        #expect(store.pendingCount == 0)
    }
}
