// [photoheads] The files a pick makes for itself never outlive it (docs/spec/3x-photoheads.md §6, §12.6): the photo
// picker's copy and the Files browser's copy live in `tmp/bot-photo-picks` and go when the load ends, is cancelled, is
// let go without either, or (after the app was closed in the middle) at the next launch or the next pick.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
@Suite(.serialized)
struct PhotoPickFilesTests {
    /// A picture in the picks folder, as a pick would leave it.
    private func plant(_ name: String = UUID().uuidString + ".png", modified: Date? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: PickedFile.folder, withIntermediateDirectories: true)
        let url = PickedFile.folder.appendingPathComponent(name)
        try PhotoTest.png(64, 48, PhotoTest.green).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func aPickedFileGoesWhenItsHolderLetsGo() throws {
        let url = try plant()
        var held: PickedFile? = PickedFile(url)
        #expect(exists(url))
        #expect(held?.url == url)
        held = nil
        #expect(!exists(url))
    }

    @Test func aCopyAndAMoveLandInThePicksFolder() throws {
        let source = PhotoTest.temporaryFile(PhotoTest.png(32, 32), name: "source.heic")
        let copy = try #require(PickedFile.copy(of: source))
        #expect(copy.deletingLastPathComponent().lastPathComponent == PickedFile.folderName)
        #expect(copy.pathExtension == "heic" && exists(copy) && exists(source))
        let moved = try #require(PickedFile.move(source))
        #expect(moved.deletingLastPathComponent().lastPathComponent == PickedFile.folderName)
        #expect(exists(moved) && !exists(source))
        #expect(PickedFile.copy(of: source) == nil)       // nothing there any more
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.removeItem(at: moved)
    }

    @Test func whatAnEarlierRunLeftGoesAndAPickUnderWayStays() throws {
        let old = try plant(modified: Date().addingTimeInterval(-3600))
        let fresh = try plant()
        // The launch sweep: only what was there before the app came up.
        PickedFile.removeLeftovers(before: Date().addingTimeInterval(-60))
        #expect(!exists(old))
        #expect(exists(fresh))
        // The sweep before a new pick: everything (no pick is under way then).
        PickedFile.removeLeftovers(before: Date().addingTimeInterval(60))
        #expect(!exists(fresh))
        // A folder that is not there is not an error.
        try? FileManager.default.removeItem(at: PickedFile.folder)
        PickedFile.removeLeftovers()
    }

    @Test func aLoadThatFinishesRemovesItsFile() async throws {
        let url = try plant()
        let load = PhotoLoad(file: url, owned: true)
        await BotsTest.waitUntil(.seconds(5)) { load.result != nil }
        guard case .success(let photo) = try #require(load.result) else {
            Issue.record("the picture was not read")
            return
        }
        #expect(photo.size == CGSize(width: 64, height: 48))
        #expect(!exists(url))
    }

    @Test func aLoadThatIsCancelledRemovesItsFile() throws {
        let url = try plant()
        let load = PhotoLoad(file: url, owned: true, delay: .seconds(5))
        load.cancel()
        #expect(!exists(url))
        #expect(load.result == nil)
    }

    @Test func aLoadThatIsLetGoWithoutEndingRemovesItsFile() async throws {
        let url = try plant()
        var load: PhotoLoad? = PhotoLoad(file: url, owned: true, delay: .seconds(5))
        #expect(load != nil && exists(url))
        load = nil
        await BotsTest.waitUntil(.seconds(3)) { !self.exists(url) }
        #expect(!exists(url))
    }

    @Test func aFileThatIsNotTheLoadsOwnIsLeftAlone() async throws {
        let url = PhotoTest.temporaryFile(PhotoTest.png(40, 40), name: "theirs.png")
        let load = PhotoLoad(file: url, owned: false)
        await BotsTest.waitUntil(.seconds(5)) { load.result != nil }
        #expect(exists(url))
        try? FileManager.default.removeItem(at: url)
    }
}
