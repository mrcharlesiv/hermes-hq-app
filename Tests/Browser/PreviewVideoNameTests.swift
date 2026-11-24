// A video a bot opens with a label (`desktop_preview` with label "Demo video") or pins under a title: the copy on the
// phone keeps the file's own type, so Quick Look plays it. Before, it was kept as "Demo video" with no type, Quick Look
// refused it and the share sheet came up instead of the video.

import AVFoundation
import Foundation
import Testing
@testable import HermesHQNative

@MainActor
struct PreviewVideoNameTests {
    @Test func keptNameCarriesThePathsType() {
        #expect(MediaStore.fileName("Demo video", path: "/Users/bot/out/demo.mp4") == "Demo video.mp4")
        #expect(MediaStore.fileName("Clip.MP4", path: "/Users/bot/clip.mp4") == "Clip.MP4")
        #expect(MediaStore.fileName("demo.mp4", path: "/Users/bot/demo.mp4") == "demo.mp4")
        #expect(MediaStore.fileName("Report v1.2", path: "~/report.md") == "Report v1.2.md")
        #expect(MediaStore.fileName("", path: "/Users/bot/demo.mov") == "demo.mov")
        #expect(MediaStore.fileName("  ", path: "/Users/bot/demo.mov") == "demo.mov")
        // A path with no type: the name stands as given.
        #expect(MediaStore.fileName("Notes", path: "/Users/bot/README") == "Notes")
    }

    @Test func labelledVideoPreviews() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "preview-video-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let movie = base.appending(path: "source.mov")
        try ShareTestMedia.movie(at: movie, location: nil)

        let store = MediaStore(accountId: "preview-video", base: base)
        let path = "/Users/bot/out/demo.mov"
        let key = MediaStore.gatewayKey(accountId: "preview-video", profile: "default", path: path)
        // What a download under the bot's label lands as.
        let kept = try #require(store.seedFile(key, name: MediaStore.fileName("Demo video", path: path), from: movie))
        #expect(kept.lastPathComponent == "Demo video.mov")
        #expect(MediaKinds.kind(ofName: kept.lastPathComponent) == .video)
        #expect(await FilePreviewPresenter.canPreview(kept))

        // The old name: no type, no preview (the share sheet came up).
        let bare = try #require(store.seedFile(key + "|bare", name: "Demo video", from: movie))
        #expect(await FilePreviewPresenter.canPreview(bare) == false)
    }
}
