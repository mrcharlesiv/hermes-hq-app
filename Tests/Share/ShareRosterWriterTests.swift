// [share] docs/spec/3x-share.md §7.5 check 1: the app's writer keeps the sheet's roster and faces current, writes only
// what changed, and never writes for an account that is no longer the signed-in one.

import CoreGraphics
import Foundation
import os
import ImageIO
import Testing
@testable import HermesHQNative

/// The account the Keychain names as signed in, changed by the test.
nonisolated final class ShareCurrentAccount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: StoredAccount?
    private var drawn: [String] = []
    private var onFace: (@Sendable (String) -> Void)?
    init(_ stored: StoredAccount?) { self.stored = stored }
    var value: StoredAccount? { lock.withLock { stored } }
    func set(_ account: StoredAccount?) { lock.withLock { stored = account } }
    var faces: [String] { lock.withLock { drawn } }
    func whenDrawing(_ work: @escaping @Sendable (String) -> Void) { lock.withLock { onFace = work } }
    func face(_ bot: Bot) -> Data? {
        let hook = lock.withLock { () -> (@Sendable (String) -> Void)? in drawn.append(bot.id); return onFace }
        hook?(bot.id)
        return bot.id == "faceless" ? nil : Data("png-of-\(bot.id)-\(ShareRosterRows.imageKey(head: bot.head, profile: bot.id))".utf8)
    }
}

/// A blocking wait, kept in a synchronous function so a detached task may make it.
nonisolated func shareWait(_ semaphore: DispatchSemaphore) { semaphore.wait() }

@Suite(.serialized) struct ShareRosterWriterTests {
    private static let urlA = "http://127.0.0.1:9911", urlB = "http://127.0.0.1:9914"
    private static func account(_ url: String = urlA, signedIn: Bool = true) -> StoredAccount {
        StoredAccount(url: url, username: "share-fixture",
                      cookies: signedIn ? [SavedCookie(name: "hermes_session_at", value: "a", domain: "127.0.0.1")] : nil, label: "Fixture")
    }
    private static func id(_ url: String = urlA) -> String { url + "|share-fixture" }

    private func make(_ current: ShareCurrentAccount) -> (writer: ShareRosterWriter, store: ShareStore) {
        let store = ShareStore(folder: ShareTemp.folder("writer"))
        return (ShareRosterWriter(store: store, current: { current.value }, face: { current.face($0) }, delay: 30), store)
    }

    private let bots = [shareTestBot("default", name: "Hermes", session: "20260929_120000_aabbcc01", active: 100), shareTestBot("ivy", active: 200)]

    /// [settings] Settings › Largest Attachment reaches the Share sheet through the roster: a changed limit is a
    /// reason to write again, and the file carries it (docs/spec/3x-settings.md §4).
    @Test func theRosterCarriesTheAttachmentLimitAndIsRewrittenWhenItChanges() async throws {
        let current = ShareCurrentAccount(Self.account())
        let store = ShareStore(folder: ShareTemp.folder("writer-limit"))
        let megabytes = OSAllocatedUnfairLock(initialState: 5)
        let writer = ShareRosterWriter(store: store, current: { current.value }, face: { current.face($0) }, delay: 30,
                                       limit: { megabytes.withLock { $0 } * 1024 * 1024 })
        writer.schedule(bots: bots, account: Self.id())
        #expect(await writer.writeNow())
        #expect(try #require(store.roster).limitBytes == 5 * 1024 * 1024)
        writer.schedule(bots: bots, account: Self.id())
        _ = await writer.writeNow()
        let savedAt = try #require(store.roster).savedAt
        megabytes.withLock { $0 = 12 }
        writer.schedule(bots: bots, account: Self.id())
        #expect(await writer.writeNow(), "a changed limit alone is written")
        let roster = try #require(store.roster)
        #expect(roster.limitBytes == 12 * 1024 * 1024)
        #expect(roster.savedAt >= savedAt)
    }

    @Test func writesTheRosterAndItsFaces() async throws {
        let current = ShareCurrentAccount(Self.account())
        let (writer, store) = make(current)
        #expect(writer.enabled)
        writer.schedule(bots: bots, account: Self.id())
        #expect(store.roster == nil)                                   // not before the list has been quiet
        #expect(await writer.writeNow())
        let roster = try #require(store.roster)
        #expect(roster.account == "http://127.0.0.1:9911\nshare-fixture" && roster.account == Self.account().key)
        #expect(roster.url == Self.urlA && roster.username == "share-fixture")
        #expect(roster.limitBytes == 104_857_600)
        #expect(roster.bots.map(\.profile) == ["default", "ivy"] && roster.bots.map(\.name) == ["Hermes", "Ivy"])
        #expect(roster.bots.map(\.session) == ["20260929_120000_aabbcc01", "20260929_120000_aabbcc02"])
        #expect(roster.bots.map(\.lastActive) == [100, 200])
        #expect(abs(roster.savedAt - Date().timeIntervalSince1970) < 60)
        for bot in roster.bots {
            let file = try #require(store.picture(bot.avatar))
            #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).hasPrefix("png-of-\(bot.profile)-head:"))
        }
        #expect(current.faces.sorted() == ["default", "ivy"])
    }

    @Test func unchangedInputWritesNothing() async throws {
        let current = ShareCurrentAccount(Self.account())
        let (writer, store) = make(current)
        writer.schedule(bots: bots, account: Self.id())
        #expect(await writer.writeNow())
        let stamp = try store.rosterFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let saved = try #require(store.roster).savedAt
        try await Task.sleep(nanoseconds: 1_100_000_000)               // a file system's date has one-second steps at worst
        // The same list again (and with only what the sheet is never told changed): no write, no face drawn again.
        var touched = bots
        touched[1].preview = "another preview"; touched[1].unread = false; touched[1].isWorking = true
        for list in [bots, touched] {
            writer.schedule(bots: list, account: Self.id())
            #expect(await writer.writeNow() == false)
        }
        #expect(try store.rosterFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == stamp)
        #expect(store.roster?.savedAt == saved)
        #expect(current.faces.count == 2)
        // Nothing scheduled: nothing written.
        #expect(await writer.writeNow() == false)
        // A real change is written: a new time, a renamed bot, a bot gone.
        var later = bots
        later[1].lastActive = Date(timeIntervalSince1970: 300)
        writer.schedule(bots: later, account: Self.id())
        #expect(await writer.writeNow())
        #expect(store.roster?.bots.last?.lastActive == 300)
        writer.schedule(bots: [later[1]], account: Self.id())
        #expect(await writer.writeNow())
        #expect(store.roster?.bots.map(\.profile) == ["ivy"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.avatars.path).count == 1)     // Hermes' face went with it
    }

    @Test func aChangedHeadWritesANewFaceAndRemovesTheOld() async throws {
        let current = ShareCurrentAccount(Self.account())
        let (writer, store) = make(current)
        writer.schedule(bots: bots, account: Self.id())
        await writer.writeNow()
        let before = try #require(store.roster?.bots.last?.avatar)
        var changed = bots
        changed[1].head = ["theme": "robot", "color": "#ff8800"]
        writer.schedule(bots: changed, account: Self.id())
        #expect(await writer.writeNow())
        let after = try #require(store.roster?.bots.last?.avatar)
        #expect(after != before)
        #expect(store.hasPicture(after) && !store.hasPicture(before))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.avatars.path).count == 2)
        #expect(current.faces == ["default", "ivy", "ivy"])                    // only the changed one was drawn again
    }

    @Test func aFaceThatCannotBeDrawnLeavesTheInitial() async throws {
        let current = ShareCurrentAccount(Self.account())
        let (writer, store) = make(current)
        writer.schedule(bots: bots + [shareTestBot("faceless")], account: Self.id())
        #expect(await writer.writeNow())
        let roster = try #require(store.roster)
        #expect(roster.bots.map { $0.avatar != nil } == [true, true, false])
        #expect(roster.bots.allSatisfy { $0.avatar == nil || store.hasPicture($0.avatar!) })      // never a name for a file that is not there
    }

    @Test func nothingIsWrittenForAnAccountThatIsNoLongerCurrent() async throws {
        // The bots are account A's; by the time the queue runs, B is signed in.
        let current = ShareCurrentAccount(Self.account(Self.urlB))
        let (writer, store) = make(current)
        writer.schedule(bots: bots, account: Self.id(Self.urlA))
        #expect(await writer.writeNow() == false)
        #expect(store.roster == nil && current.faces.isEmpty)
        // Nobody signed in, or saved without a session.
        for nobody in [nil, Self.account(signedIn: false)] {
            current.set(nobody)
            writer.schedule(bots: bots, account: Self.id())
            #expect(await writer.writeNow() == false)
            #expect(store.roster == nil)
        }
        // The account changes while the faces are being drawn: the roster is not written.
        current.set(Self.account())
        let other = Self.account(Self.urlB)
        current.whenDrawing { _ in current.set(other) }
        writer.schedule(bots: bots, account: Self.id())
        #expect(await writer.writeNow() == false)
        #expect(store.roster == nil)
        #expect(!FileManager.default.fileExists(atPath: store.rosterFile.path))
    }

    @Test func clearLeavesTheFolderEmptyAndWinsOverAWriteInFlight() async throws {
        let current = ShareCurrentAccount(Self.account())
        let (writer, store) = make(current)
        writer.schedule(bots: bots, account: Self.id())
        await writer.writeNow()
        store.remember(choice: "ios-direct::ivy", account: Self.account().key)
        store.record(ShareSent(id: "1", account: Self.account().key, session: "s", profile: "ivy", botName: "Ivy", at: 1))
        writer.clear()
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.folder.path).isEmpty)
        // A scheduled write is dropped by clear().
        writer.schedule(bots: bots, account: Self.id())
        writer.clear()
        #expect(await writer.writeNow() == false)
        #expect(store.roster == nil)
        // A write already on the queue when the person signs out stops at its next step.
        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        current.whenDrawing { id in if id == "default" { entered.signal(); proceed.wait() } }
        writer.schedule(bots: bots, account: Self.id())
        async let wrote = writer.writeNow()
        await Task.detached { shareWait(entered) }.value
        // Sign Out now: it waits for the queue (so nothing can be written after it returns), and the write lets go a
        // moment later, from another thread.
        Task.detached { try? await Task.sleep(nanoseconds: 200_000_000); proceed.signal() }
        writer.clear()
        #expect(await wrote == false)
        #expect(store.roster == nil)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: store.folder.path))?.isEmpty ?? true)
    }

    @Test func aRosterLeftByAnotherAccountGoesAndTheOwnOneStays() async throws {
        let current = ShareCurrentAccount(Self.account())
        let (writer, store) = make(current)
        writer.schedule(bots: bots, account: Self.id())
        await writer.writeNow()
        writer.clear(unlessFor: Self.account().key)
        await writer.writeNow()                                        // lets the queue run
        #expect(store.roster != nil)
        writer.clear(unlessFor: Self.account(Self.urlB).key)
        await writer.writeNow()
        #expect(store.roster == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.folder.path).isEmpty)
    }

    // [ship, m9: share + photoheads] A bot that wears a photo is offered with that photo, as in the Bots list.

    /// A 300 × 200 picture, red on the left half and blue on the right, as a PNG file.
    private static func twoTone(_ name: String) throws -> URL {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 150, height: 200))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 150, y: 0, width: 150, height: 200))
        let image = try #require(context.makeImage())
        let url = ShareTemp.folder("writer-photo").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: y - (image.height - 1), width: image.width, height: image.height))
        return bytes
    }

    @Test func aPhotoIsDrawnAsTheSheetsSquare() throws {
        let data = try #require(ShareRosterWriter.photoPNG(at: try Self.twoTone("wide.png")))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 120 && image.height == 120)
        // Aspect fill, centred: the middle 200 of the 300 is kept, so the square is red on its left and blue on its right.
        let left = try Self.pixel(image, x: 10, y: 60), right = try Self.pixel(image, x: 110, y: 60)
        #expect(left[0] > 200 && left[2] < 50 && left[3] == 255)
        #expect(right[2] > 200 && right[0] < 50 && right[3] == 255)
        #expect(ShareRosterWriter.photoPNG(at: URL(fileURLWithPath: "/nonexistent/photo.png")) == nil)
        let junk = ShareTemp.folder("writer-photo-junk").appendingPathComponent("junk.png")
        try FileManager.default.createDirectory(at: junk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a picture".utf8).write(to: junk)
        #expect(ShareRosterWriter.photoPNG(at: junk) == nil)
    }

    @Test func aBotThatWearsAPhotoIsOfferedWithIt() async throws {
        let current = ShareCurrentAccount(Self.account())
        let store = ShareStore(folder: ShareTemp.folder("writer-photos"))
        let url = try Self.twoTone("ivy.png")
        final class Worn { var photos: [String: SharePhoto] = [:] }
        let worn = Worn()
        worn.photos["ivy"] = SharePhoto(fingerprint: "f1", url: url)
        let writer = ShareRosterWriter(store: store, current: { current.value }, face: { current.face($0) },
                                       photo: { worn.photos[$0.id] }, delay: 30)
        writer.schedule(bots: bots, account: Self.id())
        #expect(await writer.writeNow())
        var roster = try #require(store.roster)
        let key = Self.account().key
        let photoName = ShareRosterRows.avatarName(account: key, profile: "ivy", imageKey: "photo:f1")
        let headName = ShareRosterRows.avatarName(account: key, profile: "ivy", imageKey: ShareRosterRows.imageKey(head: bots[1].head, profile: "ivy"))
        #expect(roster.bots[1].avatar == photoName && photoName != headName)
        let file = try #require(store.picture(photoName))
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        #expect(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)).width == 120)
        #expect(current.faces == ["default"])                          // Ivy's head was not drawn at all
        #expect(!store.hasPicture(headName))

        // The same photo again: nothing to write.
        writer.schedule(bots: bots, account: Self.id())
        #expect(await writer.writeNow() == false)

        // Another photo: a new name, and the old picture goes.
        worn.photos["ivy"] = SharePhoto(fingerprint: "f2", url: url)
        writer.schedule(bots: bots, account: Self.id())
        #expect(await writer.writeNow())
        roster = try #require(store.roster)
        let second = ShareRosterRows.avatarName(account: key, profile: "ivy", imageKey: "photo:f2")
        #expect(roster.bots[1].avatar == second && store.hasPicture(second) && !store.hasPicture(photoName))

        // A photo that cannot be drawn (its file is not there yet): the head, under the head's own name.
        worn.photos["ivy"] = SharePhoto(fingerprint: "f3", url: URL(fileURLWithPath: "/nonexistent/ivy.png"))
        writer.schedule(bots: bots, account: Self.id())
        #expect(await writer.writeNow())
        roster = try #require(store.roster)
        #expect(roster.bots[1].avatar == headName && store.hasPicture(headName))
        #expect(!store.hasPicture(ShareRosterRows.avatarName(account: key, profile: "ivy", imageKey: "photo:f3")))

        // The photo is taken off: the head again (already there, so only the roster's check runs).
        worn.photos["ivy"] = nil
        writer.schedule(bots: bots, account: Self.id())
        #expect(await writer.writeNow() == false)
        #expect(try #require(store.roster).bots[1].avatar == headName)
    }

    @Test func theDebounceRestartsAndWritesOnce() async throws {
        let current = ShareCurrentAccount(Self.account())
        let store = ShareStore(folder: ShareTemp.folder("writer-debounce"))
        let writer = ShareRosterWriter(store: store, current: { current.value }, face: { current.face($0) }, delay: 1.0)
        for _ in 0..<5 {
            writer.schedule(bots: [bots[0]], account: Self.id())
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        writer.schedule(bots: bots, account: Self.id())
        #expect(store.roster == nil)                                   // still quiet time
        var waited = 0
        while store.roster == nil, waited < 300 { try await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
        #expect(store.roster?.bots.count == 2)                         // the latest list, written once
        #expect(current.faces.sorted() == ["default", "ivy"])
        #expect(ShareRosterWriter.debounce == 0.8)
        #expect(writer.enabled)                                        // and the writer lives until here: its timer holds it weakly
    }

    @Test func withoutAnAppGroupEveryCallIsANoOp() async {
        let writer = ShareRosterWriter(store: nil, current: { nil }, face: { _ in nil })
        #expect(!writer.enabled)
        writer.schedule(bots: bots, account: Self.id())
        #expect(await writer.writeNow() == false)
        writer.clear()
        writer.clear(unlessFor: "x")
    }

    @Test func aBotsFaceIsItsHeadAsA120PixelPNG() throws {
        for bot in [shareTestBot("ivy"), shareTestBot("default", name: "Hermes"), shareTestBot("zed", head: ["theme": "robot"])] {
            let data = try #require(ShareRosterWriter.face(for: bot))
            #expect(data.prefix(8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 120 && image.height == 120, "\(bot.id)")
            #expect(data.count < 60_000)
        }
        // Two bots wearing their default heads do not get the same picture.
        #expect(ShareRosterWriter.face(for: shareTestBot("ivy")) != ShareRosterWriter.face(for: shareTestBot("default")))
        #expect(ShareRosterWriter.face(for: shareTestBot("ivy")) == ShareRosterWriter.face(for: shareTestBot("ivy")))
    }

    @Test func twoHundredAndFiftyBotsAreWrittenAsTwoHundred() async throws {
        let current = ShareCurrentAccount(Self.account())
        let (writer, store) = make(current)
        let many = (1...250).map { shareTestBot(String(format: "load-%03d", $0), active: Double($0)) }
        writer.schedule(bots: many, account: Self.id())
        #expect(await writer.writeNow())
        #expect(store.roster?.bots.count == 200)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.avatars.path).count == 200)
        #expect(ShareItemLoader.size(store.rosterFile) < 100_000)
    }
}
