// [photoheads] The registry every face asks: a photo when the bot wears one, the head otherwise, never another
// account's picture (docs/spec/3x-photoheads.md §4.5, §4.6, §11.1 item 5).

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite(.serialized)
struct BotFacesTests {
    private let folder = BotsTest.tempDirectory()

    private static let other = GatewayAccount(id: "http://127.0.0.1:9717|faces-other", baseURL: URL(string: "http://127.0.0.1:9717")!,
                                              kind: .password, username: "faces-other", label: "127.0.0.1")

    /// A started store that has seen these bots and finished fetching.
    private func loadedStore(_ avatars: [String: String], account: GatewayAccount = .botsTestAccount,
                             plain: [String] = []) async -> (BotPhotoStore, PhotoGateway) {
        let gateway = PhotoGateway(account: account, avatars: avatars)
        let store = BotPhotoStore(client: gateway.client, account: account, cacheDirectory: folder, timing: .fast)
        store.start()
        let names = avatars.keys.sorted()
        store.rowsArrived(names.map { PhotoGateway.profile($0) } + plain.map { PhotoGateway.profile($0, hasAvatar: false) },
                          order: names + plain, issuedAt: Date())
        await BotsTest.waitUntil(.seconds(5)) { store.isIdle }
        BotPhotoDisk.shared.flush()
        return (store, gateway)
    }

    private func pixel(_ image: UIImage, _ x: Int, _ y: Int) -> PhotoTest.RGBA? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = c.data else { return nil }
        c.clear(CGRect(x: 0, y: 0, width: w, height: h))
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.assumingMemoryBound(to: UInt8.self) + (y * w + x) * 4
        return PhotoTest.RGBA(r: Int(p[0]), g: Int(p[1]), b: Int(p[2]), a: Int(p[3]))
    }

    // MARK: photo or head

    @Test func withoutAStoreEveryFaceIsTheHead() {
        let faces = BotFaces()
        #expect(faces.photo(for: "ivy") == nil)
        #expect(!faces.showsPhoto("ivy"))
        #expect(!faces.supportsPictures)
        #expect(faces.faceKey(profile: "ivy", raw: nil).hasPrefix("head:"))
        let face = faces.faceImage(profile: "ivy", raw: nil, side: 40, scale: 2, dark: false, shape: .appIcon)
        #expect(face.size == CGSize(width: 40, height: 40))
    }

    @Test func aPhotoIsOnTheFirstFrameAfterTheStoreIsSet() async {
        let (store, _) = await loadedStore(["ivy": PhotoTest.photoA, "default": PhotoTest.mirror], plain: ["notes"])
        let faces = BotFaces()
        let before = faces.version
        faces.use(store)
        // No await between `use` and these: the top of the list is decoded on the spot.
        #expect(faces.version != before)
        #expect(faces.isUsing(store))
        #expect(faces.supportsPictures)
        let photo = faces.photo(for: "ivy")
        #expect(photo != nil)
        #expect(photo?.size == CGSize(width: 256, height: 256))
        #expect(faces.showsPhoto("ivy"))
        // The head's own copy, a bot with no picture, and a bot nobody has heard of: the head.
        #expect(faces.photo(for: "default") == nil && !faces.showsPhoto("default"))
        #expect(faces.photo(for: "notes") == nil)
        #expect(faces.photo(for: "nobody") == nil)
        store.stop()
    }

    @Test func aPhotoThatArrivesLaterIsToldToTheFaces() async throws {
        let gateway = PhotoGateway(avatars: ["ivy": PhotoTest.photoA])
        gateway.state.mutate { $0.delay = .milliseconds(60) }
        let store = BotPhotoStore(client: gateway.client, account: .botsTestAccount, cacheDirectory: folder, timing: .fast)
        let faces = BotFaces()
        faces.use(store)
        store.start()
        store.rowsArrived([PhotoGateway.profile("ivy")], order: ["ivy"], issuedAt: Date())
        #expect(faces.photo(for: "ivy") == nil)       // the head shows while the picture is fetched
        let before = faces.version
        // Wait for the picture, not the counter: the faces are told once it can be drawn.
        await BotsTest.waitUntil(.seconds(5)) { faces.photo(for: "ivy") != nil }
        #expect(faces.version != before)
        // Replaced by another photo: the old one keeps showing until the new one is decoded, then the new one shows.
        let old = try #require(faces.photo(for: "ivy"))
        await store.adopt("ivy", dataURL: PhotoTest.photoB)
        #expect(faces.photo(for: "ivy") != nil)
        await BotsTest.waitUntil(.seconds(5)) { faces.photo(for: "ivy") !== old }
        let now = faces.photo(for: "ivy")
        #expect(now != nil && now !== old)
        if let now { #expect(pixel(now, 128, 128)?.near(PhotoTest.blue) == true) }
        // Removed: the head, at once.
        await store.adopt("ivy", dataURL: nil)
        #expect(faces.photo(for: "ivy") == nil && !faces.showsPhoto("ivy"))
        store.stop()
    }

    @Test func theFacesAreToldOnlyWhenThePictureCanBeDrawn() async throws {
        // The verdict lands first and the picture's file a moment later: nobody is told in between, so nothing that
        // keeps a copy of the face (the pushed-alert picture) can take the head for the photo.
        let (store, _) = await loadedStore(["default": PhotoTest.mirror])
        let faces = BotFaces()
        faces.use(store)
        var told = 0
        var sawPhotoWhenTold = true
        faces.onFacesChanged = {
            told += 1
            if faces.showsPhoto("default"), faces.cachedPhoto("default") == nil { sawPhotoWhenTold = false }
        }
        let before = faces.version
        await store.adopt("default", dataURL: PhotoTest.photoA)
        // Straight after the store took the photo: the bot wears it, it is not decoded, and no face was told.
        #expect(faces.showsPhoto("default"))
        #expect(faces.cachedPhoto("default") == nil)
        #expect(faces.version == before)
        await BotsTest.waitUntil(.seconds(5)) { faces.cachedPhoto("default") != nil }
        #expect(faces.version != before)
        await BotsTest.waitUntil(.seconds(3)) { told > 0 }
        #expect(told == 1)
        #expect(sawPhotoWhenTold)
        store.stop()
    }

    // MARK: accounts

    @Test func anotherGatewaysPhotoIsNeverDrawnForABotOfTheSameName() async {
        let (alpha, _) = await loadedStore(["ivy": PhotoTest.photoA])
        let (beta, _) = await loadedStore(["ivy": PhotoTest.mirror, "ana": PhotoTest.photoB], account: Self.other)
        let faces = BotFaces()
        faces.use(alpha)
        #expect(faces.photo(for: "ivy") != nil)
        faces.use(beta)
        // Synchronously after the switch: Alpha's photo is gone from every face.
        #expect(faces.photo(for: "ivy") == nil)
        #expect(!faces.showsPhoto("ivy"))
        #expect(faces.photo(for: "ana") != nil)
        #expect(alpha.onChange == nil)
        faces.use(nil)
        #expect(faces.photo(for: "ana") == nil && !faces.supportsPictures)
        #expect(beta.onChange == nil)
        // And back: Alpha's photo again, with no fetch.
        faces.use(alpha)
        #expect(faces.photo(for: "ivy") != nil)
        alpha.stop(); beta.stop()
    }

    @Test func aStoreThatIsNoLongerUsedCannotChangeAFace() async {
        let (alpha, _) = await loadedStore(["ivy": PhotoTest.photoA])
        let (beta, _) = await loadedStore(["ivy": PhotoTest.mirror], account: Self.other)
        let faces = BotFaces()
        faces.use(alpha)
        faces.use(beta)
        let version = faces.version
        await alpha.adopt("ivy", dataURL: PhotoTest.photoB)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(faces.version == version)
        #expect(faces.photo(for: "ivy") == nil)
        alpha.stop(); beta.stop()
    }

    // MARK: faces handed out as pictures

    @Test func theFaceKeyFollowsThePhotoThenTheHead() async throws {
        let (store, _) = await loadedStore(["ivy": PhotoTest.photoA, "default": PhotoTest.mirror])
        let faces = BotFaces()
        faces.use(store)
        let fingerprint = BotPicture.fingerprint(try #require(BotPicture.bytes(of: PhotoTest.photoA)))
        #expect(faces.faceKey(profile: "ivy", raw: nil) == "photo:" + fingerprint)
        // The head does not matter while a photo shows.
        #expect(faces.faceKey(profile: "ivy", raw: ["shape": 3]) == "photo:" + fingerprint)
        let plain = faces.faceKey(profile: "default", raw: nil)
        #expect(plain == "head:none:shape")
        #expect(faces.faceKey(profile: "default", raw: nil) == plain)
        #expect(faces.faceKey(profile: "default", raw: ["shape": 3]) != plain)
        await store.adopt("ivy", dataURL: PhotoTest.photoB)
        #expect(faces.faceKey(profile: "ivy", raw: nil) == "photo:" + BotPicture.fingerprint(try #require(BotPicture.bytes(of: PhotoTest.photoB))))
        await store.adopt("ivy", dataURL: nil)
        #expect(faces.faceKey(profile: "ivy", raw: nil).hasPrefix("head:"))
        store.stop()
    }

    @Test func aHeadsKeyIsTheSameOnEveryLaunch() {
        // Whoever keeps faces between launches (the Share sheet's roster) compares this key with the one it stored, so
        // it is a digest of the record written with its keys in order, never a per-launch hash.
        #expect(BotFaces.headKey(nil) == "head:none:shape")
        #expect(BotFaces.headKey(.null) == "head:none:shape")
        #expect(BotFaces.headKey(["shape": 3, "face": "pill"]) == "head:3a040875b9b856d0")
        #expect(BotFaces.headKey(["face": "pill", "shape": 3]) == "head:3a040875b9b856d0")
        #expect(BotFaces.headKey(["face": "pill", "shape": 3, "eyes": ["size": 1.5, "kind": "dot"]]) == "head:c675759d053d9960")
        #expect(BotFaces.headKey(["face": "pill", "shape": 4]) != "head:3a040875b9b856d0")
        #expect(BotFaces().faceKey(profile: "ivy", raw: ["shape": 3, "face": "pill"]) == "head:3a040875b9b856d0")
    }

    @Test func aPhotoThatCannotBeDrawnYetIsNeverHandedOutAsAPhoto() async throws {
        let (store, _) = await loadedStore(["ivy": PhotoTest.photoA])
        // The verdict is there and the file is not (as in the moment between a fetch and its write).
        try FileManager.default.removeItem(at: try #require(store.photoURL(for: "ivy")))
        let faces = BotFaces()
        faces.use(store)
        #expect(faces.showsPhoto("ivy"))
        #expect(faces.cachedPhoto("ivy") == nil)
        #expect(faces.readyFace(profile: "ivy", raw: nil, side: 40, scale: 3, dark: false, shape: .appIcon) == nil)
        // The picture-only call still answers with something to draw: the head.
        let face = faces.faceImage(profile: "ivy", raw: nil, side: 40, scale: 3, dark: false, shape: .appIcon)
        #expect(face.size == CGSize(width: 40, height: 40))
        // A head says it is a head; a photo that is ready says it is a photo.
        let head = try #require(faces.readyFace(profile: "nobody", raw: nil, side: 40, scale: 3, dark: false, shape: .appIcon))
        #expect(!head.isPhoto)
        let (other, _) = await loadedStore(["ana": PhotoTest.photoB], account: Self.other)
        faces.use(other)
        let photo = try #require(faces.readyFace(profile: "ana", raw: nil, side: 40, scale: 3, dark: false, shape: .appIcon))
        #expect(photo.isPhoto)
        #expect(try #require(pixel(photo.image, 60, 60)).near(PhotoTest.blue))
        store.stop(); other.stop()
    }

    // MARK: the picture kept for pushed alerts

    private func bot(_ id: String, head: JSONValue? = nil) -> Bot {
        Bot(id: id, name: id.capitalized, role: nil, preview: nil, lastActive: nil, isWorking: false, unread: false, pinned: false,
            pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: nil, head: head)
    }

    /// The middle of the picture the notification extension would read for this bot.
    private func pushedFace(_ account: String, _ profile: String) -> PhotoTest.RGBA? {
        guard let data = PushFaces.face(account: account, profile: profile), let image = UIImage(data: data) else { return nil }
        return pixel(image, 60, 60)
    }

    @Test func thePushedAlertFaceIsThePhotoThenTheHead() async throws {
        let (store, _) = await loadedStore(["ivy": PhotoTest.photoA, "ana": PhotoTest.photoB, "default": PhotoTest.mirror])
        let faces = BotFaces()
        faces.use(store)
        let account = "photoheads-test-\(UUID().uuidString)"
        defer { PushFaces.remove(account: account) }
        let hub = NotificationHub()
        let saver = PushFaceSaver(hub: hub, faces: faces, currentAccount: { account })
        let bots = [bot("ivy"), bot("ana"), bot("default")]

        // Ivy's photo is in memory (the top of the list is decoded at once); Ana's is not: it is decoded off the main
        // actor and saved when ready, and is not kept in memory for that.
        faces.dropDecoded()
        _ = try #require(faces.readyFace(profile: "ivy", raw: nil, side: 40, scale: 3, dark: false, shape: .appIcon))
        #expect(faces.cachedPhoto("ivy") != nil && faces.cachedPhoto("ana") == nil)
        saver.save(bots, account: account)
        #expect(try #require(pushedFace(account, "ivy")).near(PhotoTest.red))
        #expect(PushFaces.face(account: account, profile: "ana") == nil)
        // The head's own 288 px copy is not a photo: the head, at once.
        let head = try #require(NotificationHub.roundPNG(faces.headImage(profile: "default", raw: nil, side: 120, scale: 1, dark: false)))
        #expect(PushFaces.face(account: account, profile: "default") == head)
        await BotsTest.waitUntil(.seconds(5)) { saver.isIdle }
        #expect(try #require(pushedFace(account, "ana")).near(PhotoTest.blue))
        #expect(faces.cachedPhoto("ana") == nil)
        // The saved picture is a 120 px circle: its corner is clear.
        let kept = try #require(PushFaces.face(account: account, profile: "ivy"))
        let saved = try #require(UIImage(data: kept))
        #expect(saved.cgImage?.width == 120 && saved.cgImage?.height == 120)
        #expect(try #require(pixel(saved, 2, 2)).a == 0)

        // Saved once: the same roster again draws and writes nothing.
        #expect(!hub.needsFace(profile: "ivy", signature: PushFaceSaver.signature(faces.faceKey(profile: "ivy", raw: nil)), account: account))

        // A new photo, then no photo: the kept face follows, as the app does it (told when the face is ready).
        faces.onFacesChanged = { saver.save(bots, account: account) }
        await store.adopt("ivy", dataURL: PhotoTest.photoB)
        await BotsTest.waitUntil(.seconds(5)) { self.pushedFace(account, "ivy")?.near(PhotoTest.blue) == true }
        #expect(try #require(pushedFace(account, "ivy")).near(PhotoTest.blue))
        await store.adopt("ivy", dataURL: nil)
        let ivyHead = try #require(NotificationHub.roundPNG(faces.headImage(profile: "ivy", raw: nil, side: 120, scale: 1, dark: false)))
        await BotsTest.waitUntil(.seconds(5)) { PushFaces.face(account: account, profile: "ivy") == ivyHead }
        #expect(PushFaces.face(account: account, profile: "ivy") == ivyHead)
        store.stop()
    }

    @Test func aPhotoWhoseFileIsMissingIsNeverKeptAsAHeadUnderThePhotosName() async throws {
        let (store, gateway) = await loadedStore(["ivy": PhotoTest.photoA])
        try FileManager.default.removeItem(at: try #require(store.photoURL(for: "ivy")))
        let faces = BotFaces()
        faces.use(store)
        let account = "photoheads-test-\(UUID().uuidString)"
        defer { PushFaces.remove(account: account) }
        let hub = NotificationHub()
        let saver = PushFaceSaver(hub: hub, faces: faces, currentAccount: { account })
        let bots = [bot("ivy")]
        faces.onFacesChanged = { saver.save(bots, account: account) }
        let fetched = gateway.fetches("ivy")
        saver.save(bots, account: account)
        // Nothing is saved on the spot: the bot wears a photo and there is no picture to save yet.
        #expect(PushFaces.face(account: account, profile: "ivy") == nil)
        #expect(hub.needsFace(profile: "ivy", signature: PushFaceSaver.signature(faces.faceKey(profile: "ivy", raw: nil)), account: account))
        // The missing file is noticed, the picture is fetched again, and the photo is what ends up kept.
        await BotsTest.waitUntil(.seconds(8)) { self.pushedFace(account, "ivy")?.near(PhotoTest.red) == true }
        #expect(try #require(pushedFace(account, "ivy")).near(PhotoTest.red))
        #expect(gateway.fetches("ivy") == fetched + 1)
        #expect(faces.showsPhoto("ivy"))
        store.stop()
    }

    @Test func aFaceIsNotKeptForAnAccountThatIsNoLongerSignedIn() async throws {
        let (store, _) = await loadedStore(["ivy": PhotoTest.photoA])
        let faces = BotFaces()
        faces.use(store)
        faces.dropDecoded()
        let account = "photoheads-test-\(UUID().uuidString)"
        defer { PushFaces.remove(account: account) }
        var current: String? = account
        let saver = PushFaceSaver(hub: NotificationHub(), faces: faces, currentAccount: { current })
        saver.save([bot("ivy")], account: account)
        current = "someone-else"       // the gateway was switched while the picture was being decoded
        await BotsTest.waitUntil(.seconds(5)) { saver.isIdle }
        #expect(PushFaces.face(account: account, profile: "ivy") == nil)
        store.stop()
    }

    @Test func aPhotoFaceIsAnAppIconTileOrASquare() async throws {
        let wide = PhotoTest.dataURL(PhotoTest.encode(PhotoTest.quadrants(640, 320), type: .png))
        let (store, _) = await loadedStore(["ivy": PhotoTest.photoA, "wide": wide])
        let faces = BotFaces()
        faces.use(store)

        let icon = faces.faceImage(profile: "ivy", raw: nil, side: 40, scale: 3, dark: false, shape: .appIcon)
        #expect(icon.size == CGSize(width: 40, height: 40) && icon.scale == 3)
        #expect(icon.cgImage?.width == 120)
        // Rounded like an app icon: the very corner is clear, the middle is the photo, and it is not a circle
        // (a circle would be clear 14 % in from the corner along the diagonal; the tile is not).
        #expect(try #require(pixel(icon, 0, 0)).a == 0)
        #expect(try #require(pixel(icon, 119, 119)).a == 0)
        #expect(try #require(pixel(icon, 60, 60)).near(PhotoTest.red))
        #expect(try #require(pixel(icon, 13, 13)).a == 255)
        #expect(try #require(pixel(icon, 60, 1)).a == 255)

        let square = faces.faceImage(profile: "ivy", raw: nil, side: 120, scale: 1, dark: false, shape: .square)
        #expect(square.cgImage?.width == 120 && square.cgImage?.height == 120)
        #expect(try #require(pixel(square, 0, 0)).near(PhotoTest.red))
        #expect(try #require(pixel(square, 119, 119)).near(PhotoTest.red))

        // A picture that is not square is aspect-filled and centred: the sides are cropped, the middle stays.
        let filled = faces.faceImage(profile: "wide", raw: nil, side: 100, scale: 1, dark: false, shape: .square)
        #expect(filled.cgImage?.width == 100 && filled.cgImage?.height == 100)
        #expect(try #require(pixel(filled, 10, 10)).near(PhotoTest.red, within: 12))
        #expect(try #require(pixel(filled, 90, 10)).near(PhotoTest.green, within: 12))
        #expect(try #require(pixel(filled, 10, 90)).near(PhotoTest.blue, within: 12))
        #expect(try #require(pixel(filled, 90, 90)).near(PhotoTest.yellow, within: 12))

        // A bot with no photo: its head, at the size asked for.
        let head = faces.faceImage(profile: "nobody", raw: nil, side: 40, scale: 3, dark: true, shape: .appIcon)
        #expect(head.size == CGSize(width: 40, height: 40))
        store.stop()
    }

    @Test func fillRectIsObjectFitCover() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(BotFaces.fillRect(CGSize(width: 200, height: 100), in: box) == CGRect(x: -50, y: 0, width: 200, height: 100))
        #expect(BotFaces.fillRect(CGSize(width: 50, height: 200), in: box) == CGRect(x: 0, y: -150, width: 100, height: 400))
        #expect(BotFaces.fillRect(CGSize(width: 256, height: 256), in: box) == box)
        #expect(BotFaces.fillRect(.zero, in: box) == box)
        #expect(BotFaces.cornerShare == 0.2237)
    }

    // MARK: the view (uses the app's shared registry)

    @Test func aHeadViewShowsThePhotoOnlyThroughTheProfileEntryPoint() async {
        let (store, _) = await loadedStore(["ivy": PhotoTest.photoA, "default": PhotoTest.mirror])
        BotFaces.shared.use(store)
        defer { BotFaces.shared.use(nil) }

        let view = HeadView(side: 44)
        view.configure(raw: nil, profile: "ivy")
        view.layoutIfNeeded()
        #expect(view.showsPhoto)
        #expect(view.faceProfile == "ivy")
        let photo = view.subviews.compactMap { $0 as? UIImageView }.first
        #expect(photo?.frame == CGRect(x: 0, y: 0, width: 44, height: 44))
        #expect(photo?.contentMode == .scaleAspectFill && photo?.clipsToBounds == true)
        #expect(photo?.layer.cornerCurve == .continuous)
        // An app-icon corner (22.37 % of 44 = 9.84), not a circle (22).
        #expect(abs((photo?.layer.cornerRadius ?? 0) - 44 * 0.2237) < 0.01)
        #expect(photo?.accessibilityIgnoresInvertColors == true)

        // Resized (the same view in a bigger row): the corner follows the width.
        view.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        view.layoutIfNeeded()
        #expect(abs((photo?.layer.cornerRadius ?? 0) - 72 * 0.2237) < 0.01)

        // A row reused for a bot that wears its head: the photo goes.
        view.configure(raw: nil, profile: "default")
        #expect(!view.showsPhoto)
        view.configure(raw: nil, profile: "ivy")
        #expect(view.showsPhoto)
        // The entry point that takes a head never shows a photo (Edit Head's preview, New Bot).
        view.configure(head: Head.defaultHead(profile: "ivy"))
        #expect(!view.showsPhoto)
        #expect(view.faceProfile == nil)

        // The photo goes away under a view on screen: the head comes back without anyone configuring it again.
        view.configure(raw: nil, profile: "ivy")
        #expect(view.showsPhoto)
        await store.adopt("ivy", dataURL: nil)
        #expect(!view.showsPhoto)
        // And a new one arrives.
        await store.adopt("ivy", dataURL: PhotoTest.photoB)
        await BotsTest.waitUntil(.seconds(5)) { view.showsPhoto }
        #expect(view.showsPhoto)
        // Signing out: every face is its head again.
        BotFaces.shared.use(nil)
        #expect(!view.showsPhoto)
        store.stop()
    }

    @Test func aHeadViewThatWentAwayIsNotKeptAlive() async {
        let (store, _) = await loadedStore(["ivy": PhotoTest.photoA])
        BotFaces.shared.use(store)
        defer { BotFaces.shared.use(nil) }
        weak var gone: HeadView?
        do {
            let view = HeadView(side: 44)
            view.configure(raw: nil, profile: "ivy")
            #expect(view.showsPhoto)
            gone = view
        }
        await Task.yield()
        #expect(gone == nil)
        // Telling the faces about a change with no view left is harmless.
        await store.adopt("ivy", dataURL: nil)
        store.stop()
    }
}
