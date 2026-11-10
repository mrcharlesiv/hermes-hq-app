// Audit 14-5: the media store's LRU (256 MiB) and file previews (up to 512 MB). A big preview open in Quick Look is
// neither deleted under it nor the reason everything else goes; one left behind after its time goes first.

import Foundation
import Testing
@testable import HermesHQNative

struct MediaStoreTrimTests {
    private func file(_ url: URL, size: Int64, date: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))   // sparse: the size without the bytes
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func anOpenBigPreviewStaysAndSparesTheRest() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "media-trim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = MediaStore(accountId: "trim", base: base)
        let now = Date()
        let photo = store.originalURL("g|a|p|photo.jpg")
        try file(photo, size: 1 << 20, date: now.addingTimeInterval(-3600))
        let big = store.fileURL("g|a|p|big.mov", name: "big.mov")
        try file(big, size: 300 << 20, date: now)

        store.trim(to: MediaStore.byteLimit, now: now)
        #expect(FileManager.default.fileExists(atPath: big.path), "the preview open now")
        #expect(FileManager.default.fileExists(atPath: photo.path), "not pushed out by the preview")

        // An hour on, its preview never said it closed: it goes, and only it.
        store.trim(to: MediaStore.byteLimit, now: now.addingTimeInterval(3600))
        #expect(!FileManager.default.fileExists(atPath: big.path))
        #expect(FileManager.default.fileExists(atPath: photo.path))
    }
}
