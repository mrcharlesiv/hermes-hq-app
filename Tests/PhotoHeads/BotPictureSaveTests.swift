// [photoheads] Saving and removing a bot's photo on the wire (docs/spec/3x-photoheads.md §8, §11.1 item 6): the
// picture goes first and is awaited, its kind follows in the one configure, and this phone's own writes never make it
// fetch the picture back.

import Foundation
import Testing
@testable import HermesHQNative

/// A stand-in gateway with the roster, `profiles.configure` and the avatar store.
nonisolated final class PictureSaveGateway: @unchecked Sendable {
    let assets: PhotoGateway
    var client: BotsFakeGatewayClient { assets.client }
    private let lock = NSLock()
    private var meta: [String: [String: JSONValue]] = [:]
    private var revisions: [String: [String: Int]] = [:]
    private var descriptions: [String: String] = [:]
    /// `profiles.configure` failures still to hand out.
    private var configureFailures: [RPCError] = []
    /// Left out of every row: a gateway older than the asset store.
    private let noAssets: Bool

    init(_ rows: [String: [String: JSONValue]], avatars: [String: String] = [:], noAssets: Bool = false) {
        assets = PhotoGateway(avatars: avatars)
        self.noAssets = noAssets
        meta = rows.mapValues { ["hermes-bots": .object($0)] }
        revisions = rows.mapValues { _ in ["hermes-bots": 1] }
        client.on("profiles.list") { [unowned self] params in self.list(slim: params["include_sessions"]?.bool == false) }
        client.on("profiles.configure") { [unowned self] params in try self.configure(params) }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    func failNextConfigure(_ error: RPCError) { withLock { configureFailures.append(error) } }
    func bots(_ name: String) -> JSONValue? { withLock { meta[name]?["hermes-bots"] } }
    func revision(_ name: String, _ key: String) -> Int { withLock { revisions[name]?[key] ?? 0 } }

    /// Another device changes the picture and its meta (the revision moves).
    func otherDevice(_ name: String, avatar: String?) {
        assets.set(name, avatar)
        withLock { revisions[name, default: [:]]["hermes-bots", default: 0] += 1 }
    }

    private func list(slim: Bool) -> JSONValue {
        let avatars = assets.state.value.avatars
        return withLock {
            let rows: [JSONValue] = meta.keys.sorted().map { name in
                var o: [String: JSONValue] = ["name": .string(name), "is_default": .bool(name == "default"),
                                              "ui_meta_revisions": .object((revisions[name] ?? [:]).mapValues { .number(Double($0)) })]
                if !noAssets { o["has_avatar"] = .bool(avatars[name] != nil) }
                if let m = meta[name], !m.isEmpty { o["ui_meta"] = .object(m) }
                if let d = descriptions[name] { o["description"] = .string(d) }
                if !slim { o["canonical_session"] = BotsTest.session("s-\(name)", lastActive: 100) }
                return .object(o)
            }
            return BotsTest.profilesResult(rows)
        }
    }

    private func configure(_ params: JSONValue) throws -> JSONValue {
        if let failure = withLock({ configureFailures.isEmpty ? nil : configureFailures.removeFirst() }) { throw failure }
        return withLock {
            let name = params["name"]?.string ?? ""
            var applied: [String: JSONValue] = [:]
            if let incoming = params["ui_meta"]?.object {
                var revs = revisions[name] ?? [:]
                if let expected = params["ui_meta_expected_revisions"]?.object {
                    for key in incoming.keys where expected[key]?.int != (revs[key] ?? 0) {
                        let conflict: JSONValue = .object([key: ["actual": .number(Double(revs[key] ?? 0))]])
                        return ["ok": false, "applied": ["ui_meta": false, "ui_meta_conflicts": conflict]]
                    }
                }
                var current = meta[name] ?? [:]
                for (key, value) in incoming {
                    if value.isNull { current[key] = nil } else { current[key] = value }
                    revs[key, default: 0] += 1
                }
                meta[name] = current
                revisions[name] = revs
                applied["ui_meta"] = true
                applied["ui_meta_revisions"] = .object(incoming.keys.reduce(into: [:]) { $0[$1] = .number(Double(revs[$1]!)) })
            }
            if let description = params["description"]?.string {
                descriptions[name] = description
                applied["description"] = true
            }
            return ["ok": true, "applied": .object(applied)]
        }
    }
}

@MainActor @Suite(.serialized)
struct BotPictureSaveTests {
    private func makeStore(_ gateway: PictureSaveGateway) async -> BotStore {
        let store = BotStore(client: gateway.client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast,
                             photoTiming: .fast)
        await BotsTest.waitUntil { store.phase == .full }
        await BotsTest.waitUntil(.seconds(5)) { store.photos.isIdle }
        return store
    }

    private func methods(_ gateway: PictureSaveGateway, from start: Int = 0) -> [String] {
        gateway.client.calls.dropFirst(start).map(\.method).filter { $0 != "profiles.list" }
    }

    private static let work: [String: JSONValue] = ["title": "Trips", "sectionId": "sec-work", "sectionName": "Work", "created": 5]

    // MARK: §8.1 a new photo

    @Test func aNewPhotoGoesUpFirstThenItsKindInOneConfigure() async throws {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work])
        let store = await makeStore(gateway)
        #expect(store.photos.supportsAssets)
        #expect(store.photos.verdict(for: "ivy") == BotPicture.Verdict.none)
        let before = gateway.client.calls.count

        let outcome = try await store.saveEdit(name: "ivy", title: "Travel", description: "Plans trips", picture: .photo(dataURL: PhotoTest.photoA))
        #expect(outcome.pictureApplied == true && outcome.pictureKindApplied == true)
        #expect(outcome.titleApplied == true && outcome.descriptionApplied == true)
        #expect(outcome.succeeded)

        // The picture first, then one configure with everything.
        #expect(methods(gateway, from: before) == ["profiles.set_asset", "profiles.configure"])
        let upload = try #require(gateway.assets.uploads.last)
        #expect(upload.params == ["name": "ivy", "asset": "avatar", "data": .string(PhotoTest.photoA)])
        #expect(upload.timeout == .seconds(2))
        let configure = try #require(gateway.client.calls("profiles.configure").last)
        #expect(configure.params.object.map { Set($0.keys) } == ["name", "ui_meta", "description"])
        #expect(configure.params["description"] == "Plans trips")
        // The whole `hermes-bots` object: what was there, the title, and the two picture keys. Nothing local-only.
        #expect(configure.params["ui_meta"] == ["hermes-bots": ["title": "Travel", "sectionId": "sec-work", "sectionName": "Work", "created": 5,
                                                                "imageKind": "photo", "custom": true]])

        // Every face on this phone has the photo now, with no fetch.
        #expect(store.photos.hasPhoto("ivy"))
        #expect(store.profile(named: "ivy")?.raw["has_avatar"] == true)
        #expect(gateway.assets.fetches("ivy") == 0)
        // The roster that follows carries this phone's own revision: still no fetch.
        await store.refresh()
        await BotsTest.waitUntil(.seconds(5)) { store.photos.isIdle }
        try? await Task.sleep(for: .milliseconds(350))
        #expect(gateway.assets.fetches("ivy") == 0)
        #expect(store.photos.hasPhoto("ivy"))
        #expect(RosterText.trimmed(store.currentMeta("ivy")["title"]) == "Travel")
    }

    @Test func aPhotoAloneWritesOnlyItsKind() async throws {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work])
        let store = await makeStore(gateway)
        let outcome = try await store.saveEdit(name: "ivy", title: nil, description: nil, picture: .photo(dataURL: PhotoTest.photoB))
        #expect(outcome.pictureApplied == true && outcome.pictureKindApplied == true)
        #expect(outcome.titleApplied == nil && outcome.descriptionApplied == nil)
        let configure = try #require(gateway.client.calls("profiles.configure").last)
        #expect(configure.params.object.map { Set($0.keys) } == ["name", "ui_meta"])
        #expect(configure.params["ui_meta"]?["hermes-bots"]?["title"] == "Trips")
        #expect(configure.params["ui_meta"]?["hermes-bots"]?["imageKind"] == "photo")
        #expect(gateway.bots("ivy")?["custom"] == true)
    }

    @Test func noPictureIsTheOldSaveUnchanged() async throws {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work])
        let store = await makeStore(gateway)
        let outcome = try await store.saveEdit(name: "ivy", title: "Travel", description: nil, picture: nil)
        #expect(outcome.titleApplied == true && outcome.pictureApplied == nil && outcome.pictureKindApplied == nil)
        #expect(gateway.assets.uploads.isEmpty)
        #expect(gateway.bots("ivy")?["imageKind"] == nil && gateway.bots("ivy")?["custom"] == nil)
    }

    // MARK: failures

    @Test func aRefusedPhotoWritesNoKindButStillTheTitle() async throws {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work])
        gateway.assets.state.mutate { $0.uploadFailures = [4069] }
        let store = await makeStore(gateway)
        let outcome = try await store.saveEdit(name: "ivy", title: "Travel", description: "Plans trips", picture: .photo(dataURL: PhotoTest.photoA))
        #expect(outcome.pictureApplied == false)
        #expect(outcome.pictureReason == "The picture is too big for the gateway. Choose another one.")
        #expect(outcome.pictureKindApplied == nil)
        #expect(outcome.titleApplied == true && outcome.descriptionApplied == true)
        #expect(!outcome.succeeded)
        #expect(gateway.bots("ivy")?["title"] == "Travel")
        #expect(gateway.bots("ivy")?["imageKind"] == nil && gateway.bots("ivy")?["custom"] == nil)
        #expect(!store.photos.hasPhoto("ivy"))
        #expect(store.currentMeta("ivy")["imageKind"] == nil)

        // Try Again sends the picture again, and this time it lands.
        let again = try await store.saveEdit(name: "ivy", title: nil, description: nil, picture: .photo(dataURL: PhotoTest.photoA))
        #expect(again.succeeded && again.pictureApplied == true)
        #expect(gateway.assets.uploads.count == 2)
        #expect(store.photos.hasPhoto("ivy"))
    }

    @Test func aRefusedPhotoAloneSendsNoConfigure() async throws {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work])
        gateway.assets.state.mutate { $0.uploadFailures = [4070] }
        let store = await makeStore(gateway)
        let outcome = try await store.saveEdit(name: "ivy", title: nil, description: nil, picture: .photo(dataURL: PhotoTest.photoA))
        #expect(outcome.pictureApplied == false)
        #expect(outcome.pictureReason == "The gateway didn’t accept that picture. Choose another one.")
        #expect(gateway.client.calls("profiles.configure").isEmpty)
    }

    @Test func whyAPictureDidNotSaveInPlainWords() {
        #expect(BotPictureWords.failureTitle == "Couldn’t Save the Picture")
        #expect(BotPictureWords.reason(RPCError(code: -32601, message: "method not found: profiles.set_asset", data: nil))
                == "This gateway can’t store bot pictures yet. Update Hermes on the computer running Hermes, then try again.")
        #expect(BotPictureWords.reason(RPCError(code: 4000, message: "invalid params", data: nil)) == BotPictureWords.unsupported)
        #expect(BotPictureWords.reason(RPCError(code: 4069, message: "asset too large (2400000 bytes; max 2MB)", data: nil))
                == "The picture is too big for the gateway. Choose another one.")
        #expect(BotPictureWords.reason(RPCError(code: 4070, message: "unsupported image format", data: nil))
                == "The gateway didn’t accept that picture. Choose another one.")
        #expect(BotPictureWords.reason(RPCError(code: 5066, message: "disk full", data: nil)) == "disk full")
        #expect(BotPictureWords.reason(RPCError(code: 5066, message: "", data: nil)) == BotWriteError.notSavedReason)
        #expect(BotPictureWords.reason(URLError(.notConnectedToInternet)) == "The gateway didn’t answer. Check the connection and try again.")
        #expect(BotPictureWords.reason(BotWriteError(title: "", reason: BotWriteError.readOnlyReason)) == BotWriteError.readOnlyReason)
        for code in [RPCError.timeoutCode, RPCError.connectionLostCode, RPCError.notConnectedCode] {
            #expect(BotPictureWords.reason(RPCError(code: code, message: "request timed out after 30s: profiles.set_asset", data: nil))
                    == "The gateway didn’t answer. Check the connection and try again.")
        }
        for words in [BotPictureWords.failureTitle, BotPictureWords.noAnswer, BotPictureWords.unsupported, BotPictureWords.tooBig, BotPictureWords.refused,
                      PhotoPickError.title, PhotoPickError.tooBig.message, PhotoPickError.unreadable.message, HeadNote.photoText] {
            #expect(!words.lowercased().contains("dispatch"))
        }
    }

    @Test func aStoredPhotoWhoseKindWasRefusedIsNotSentAgain() async throws {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work])
        let store = await makeStore(gateway)
        gateway.failNextConfigure(RPCError(code: 5064, message: "disk full", data: nil))
        let outcome = try await store.saveEdit(name: "ivy", title: "Travel", description: nil, picture: .photo(dataURL: PhotoTest.photoA))
        #expect(outcome.pictureApplied == true)
        #expect(outcome.pictureKindApplied == false && outcome.titleApplied == false)
        #expect(outcome.reason == "disk full")
        #expect(!outcome.succeeded)
        // The picture is on the gateway and on every face here; the meta went back.
        #expect(store.photos.hasPhoto("ivy"))
        // (A key that was not there before goes back as null, the way a refused title always has.)
        #expect(store.currentMeta("ivy")["imageKind"]?.string == nil && store.currentMeta("ivy")["custom"]?.bool == nil)
        #expect(RosterText.trimmed(store.currentMeta("ivy")["title"]) == "Trips")

        // Try Again: the kind and the title only.
        let again = try await store.saveEdit(name: "ivy", title: "Travel", description: nil, picture: .kindOnly(photo: true))
        #expect(again.succeeded)
        #expect(again.pictureApplied == nil && again.pictureKindApplied == true && again.titleApplied == true)
        #expect(gateway.assets.uploads.count == 1)
        #expect(gateway.bots("ivy")?["imageKind"] == "photo" && gateway.bots("ivy")?["title"] == "Travel")
    }

    // MARK: §8.2 removing

    @Test func removingAPhotoPutsTheSavedHeadsCopyBack() async throws {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work], avatars: ["ivy": PhotoTest.photoA])
        let store = await makeStore(gateway)
        #expect(store.photos.hasPhoto("ivy"))
        let before = gateway.client.calls.count
        let outcome = try await store.saveEdit(name: "ivy", title: nil, description: nil, picture: .remove(mirror: PhotoTest.mirror))
        #expect(outcome.succeeded && outcome.pictureApplied == true && outcome.pictureKindApplied == true)
        #expect(methods(gateway, from: before) == ["profiles.set_asset", "profiles.configure"])
        #expect(gateway.assets.uploads.last?.params == ["name": "ivy", "asset": "avatar", "data": .string(PhotoTest.mirror)])
        #expect(gateway.bots("ivy")?["imageKind"] == "shape" && gateway.bots("ivy")?["custom"] == true)
        #expect(store.photos.verdict(for: "ivy") == .mirror)
        #expect(!store.photos.hasPhoto("ivy"))
        #expect(store.profile(named: "ivy")?.raw["has_avatar"] == true)
        #expect(gateway.assets.fetches("ivy") == 1)       // the first sight only
    }

    @Test func removingAPhotoFromABotWithNoSavedHeadClearsIt() async throws {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work], avatars: ["ivy": PhotoTest.photoA])
        let store = await makeStore(gateway)
        let outcome = try await store.saveEdit(name: "ivy", title: nil, description: nil, picture: .remove(mirror: nil))
        #expect(outcome.succeeded)
        #expect(gateway.assets.uploads.last?.params == ["name": "ivy", "asset": "avatar", "clear": true])
        #expect(gateway.assets.state.value.avatars["ivy"] == nil)
        #expect(gateway.bots("ivy")?["imageKind"] == "shape")
        #expect(store.photos.verdict(for: "ivy") == BotPicture.Verdict.none)
        #expect(store.profile(named: "ivy")?.raw["has_avatar"] == false)
        await store.refresh()
        await BotsTest.waitUntil(.seconds(5)) { store.photos.isIdle }
        #expect(gateway.assets.fetches("ivy") == 1)
    }

    @Test func aRemovalThatFailsKeepsThePhoto() async throws {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work], avatars: ["ivy": PhotoTest.photoA])
        gateway.assets.state.mutate { $0.uploadFailures = [5066] }
        let store = await makeStore(gateway)
        let outcome = try await store.saveEdit(name: "ivy", title: nil, description: nil, picture: .remove(mirror: nil))
        #expect(outcome.pictureApplied == false && outcome.pictureReason == "disk full")
        #expect(store.photos.hasPhoto("ivy"))
        #expect(gateway.client.calls("profiles.configure").isEmpty)
    }

    // MARK: §8.3 heads and photos

    @Test func aSavedHeadReplacesThePhotoAtOnceAndItsCopyFollows() async throws {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work], avatars: ["ivy": PhotoTest.photoA])
        let store = await makeStore(gateway)
        #expect(store.photos.hasPhoto("ivy"))
        var changed: [String] = []
        store.photos.onChange = { changed.append($0) }
        var record = HeadRecord.defaultRecord(profile: "ivy")
        record.form = "hex"
        _ = try await store.saveHead(name: "ivy", record: record.stored, revision: 0)
        // At once, before the desktop copy went anywhere.
        #expect(!store.photos.hasPhoto("ivy"))
        #expect(store.photos.verdict(for: "ivy") == .mirror)
        #expect(changed == ["ivy"])
        #expect(store.photos.awaitingMirror == ["ivy"])
        #expect(gateway.assets.uploads.isEmpty)

        await store.mirrorHead(name: "ivy", png: PhotoTest.mirror)
        #expect(gateway.assets.uploads.count == 1)
        #expect(store.photos.awaitingMirror.isEmpty)
        #expect(store.photos.verdict(for: "ivy") == .mirror)
        // The head's revision moved, by this phone: the roster that follows fetches nothing.
        await store.refresh()
        await BotsTest.waitUntil(.seconds(5)) { store.photos.isIdle }
        try? await Task.sleep(for: .milliseconds(350))
        #expect(gateway.assets.fetches("ivy") == 1)
        #expect(!store.photos.hasPhoto("ivy"))
    }

    @Test func theHeadsCopyIsTriedAgainWhenItReplacesAPhoto() async throws {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work, "ana": [:]], avatars: ["ivy": PhotoTest.photoA])
        let store = await makeStore(gateway)
        _ = try await store.saveHead(name: "ivy", record: HeadRecord.defaultRecord(profile: "ivy").stored, revision: 0)
        gateway.assets.state.mutate { $0.uploadFailures = [5066, 5066] }
        let began = ContinuousClock.now
        await store.mirrorHead(name: "ivy", png: PhotoTest.mirror)
        // Failed, 40 ms, failed, 80 ms, stored.
        #expect(gateway.assets.uploads.count == 3)
        #expect(ContinuousClock.now - began >= .milliseconds(110))
        #expect(store.photos.awaitingMirror.isEmpty)
        #expect(gateway.assets.state.value.avatars["ivy"] == PhotoTest.mirror)

        // A head saved on a bot that wore no photo: one try, as before.
        _ = try await store.saveHead(name: "ana", record: HeadRecord.defaultRecord(profile: "ana").stored, revision: 0)
        gateway.assets.state.mutate { $0.uploadFailures = [5066] }
        await store.mirrorHead(name: "ana", png: PhotoTest.mirror)
        #expect(gateway.assets.uploads.count == 4)
        #expect(store.photos.verdict(for: "ana") == BotPicture.Verdict.none)

        // Every try failed: the gateway still holds the photo, and the next look says so.
        let stuck = PictureSaveGateway(["default": [:], "ivy": Self.work], avatars: ["ivy": PhotoTest.photoA])
        let other = await makeStore(stuck)
        _ = try await other.saveHead(name: "ivy", record: HeadRecord.defaultRecord(profile: "ivy").stored, revision: 0)
        stuck.assets.state.mutate { $0.uploadFailures = [5066, 5066, 5066] }
        await other.mirrorHead(name: "ivy", png: PhotoTest.mirror)
        #expect(stuck.assets.uploads.count == 3)
        #expect(!other.photos.hasPhoto("ivy"))
        stuck.otherDevice("ivy", avatar: PhotoTest.photoA)
        await other.refresh()
        await BotsTest.waitUntil(.seconds(5)) { other.photos.hasPhoto("ivy") }
        #expect(other.photos.hasPhoto("ivy"))
    }

    @Test func resettingAHeadLeavesAPhotoAlone() async throws {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work, "ana": [:]], avatars: ["ivy": PhotoTest.photoA, "ana": PhotoTest.mirror])
        let store = await makeStore(gateway)
        _ = try await store.saveHead(name: "ivy", record: nil, revision: 0)
        #expect(store.photos.hasPhoto("ivy"))          // a reset is not a saved head: nothing is dropped
        await store.mirrorHead(name: "ivy", png: nil)
        #expect(gateway.assets.uploads.isEmpty)
        #expect(gateway.assets.state.value.avatars["ivy"] == PhotoTest.photoA)
        #expect(store.photos.hasPhoto("ivy"))

        // A bot wearing this app's own copy: the copy is removed, and the bot is known to have no picture.
        _ = try await store.saveHead(name: "ana", record: nil, revision: 0)
        await store.mirrorHead(name: "ana", png: nil)
        #expect(gateway.assets.uploads.last?.params == ["name": "ana", "asset": "avatar", "clear": true])
        #expect(store.photos.verdict(for: "ana") == BotPicture.Verdict.none)
        #expect(store.profile(named: "ana")?.raw["has_avatar"] == false)
    }

    // MARK: this phone's other writes

    @Test func aPinDoesNotFetchThePictureAgain() async throws {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work], avatars: ["ivy": PhotoTest.photoA])
        let store = await makeStore(gateway)
        #expect(gateway.assets.fetches("ivy") == 1)
        try await store.setPinned(name: "ivy", display: "Ivy", true)
        try await store.setHidden(name: "ivy", display: "Ivy", true)
        try await store.setHidden(name: "ivy", display: "Ivy", false)
        await store.refresh()
        await BotsTest.waitUntil(.seconds(5)) { store.photos.isIdle }
        try? await Task.sleep(for: .milliseconds(350))
        #expect(gateway.assets.fetches("ivy") == 1)
        #expect(gateway.revision("ivy", "hermes-bots") == 4)
        #expect(store.photos.entries["ivy"]?.bots == 4)

        // Another device's change is still seen.
        gateway.otherDevice("ivy", avatar: PhotoTest.photoB)
        await store.refresh()
        await BotsTest.waitUntil(.seconds(5)) { gateway.assets.fetches("ivy") == 2 }
        await BotsTest.waitUntil(.seconds(5)) { store.photos.isIdle }
        #expect(store.photos.fingerprint(for: "ivy") == BotPicture.fingerprint(BotPicture.bytes(of: PhotoTest.photoB)!))
    }

    @Test func aPictureSaveWaitsItsTurnBehindAnotherWriteToTheBot() async throws {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work])
        let store = await makeStore(gateway)
        let before = gateway.client.calls.count
        async let pin: Void = store.setPinned(name: "ivy", display: "Ivy", true)
        async let save = store.saveEdit(name: "ivy", title: nil, description: nil, picture: .photo(dataURL: PhotoTest.photoA))
        _ = try await (pin, save)
        // One bot, one write at a time: the pin's configure, then the picture and its configure.
        #expect(methods(gateway, from: before) == ["profiles.configure", "profiles.set_asset", "profiles.configure"])
        let final = try #require(gateway.bots("ivy"))
        #expect(final["imageKind"] == "photo" && final["sectionId"] == .string(RosterRules.pinnedSectionId))
    }

    // MARK: §5.6 older and read-only gateways

    @Test func aGatewayWithoutTheAssetStoreIsLeftAlone() async throws {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work], avatars: ["ivy": PhotoTest.photoA], noAssets: true)
        let store = await makeStore(gateway)
        #expect(!store.photos.supportsAssets)
        #expect(gateway.assets.fetches.isEmpty)
        // A head save still stores its desktop copy, and nothing is recorded about pictures.
        _ = try await store.saveHead(name: "ivy", record: HeadRecord.defaultRecord(profile: "ivy").stored, revision: 0)
        await store.mirrorHead(name: "ivy", png: PhotoTest.mirror)
        #expect(gateway.assets.uploads.count == 1)
        #expect(store.photos.entries.isEmpty)
        #expect(store.profile(named: "ivy")?.raw["has_avatar"] == nil)
        await store.mirrorHead(name: "ivy", png: nil)
        #expect(store.photos.entries.isEmpty)
    }

    @Test func aReadOnlyGatewayRefusesBeforeAnythingIsSent() async {
        let gateway = PictureSaveGateway(["default": [:], "ivy": Self.work])
        let store = await makeStore(gateway)
        store.readOnlyGateway = true
        let before = gateway.client.calls.count
        await #expect(throws: BotWriteError(title: "Couldn’t Save the Picture", reason: BotWriteError.readOnlyReason)) {
            _ = try await store.saveEdit(name: "ivy", title: nil, description: nil, picture: .photo(dataURL: PhotoTest.photoA))
        }
        #expect(gateway.client.calls.count == before)
    }
}
